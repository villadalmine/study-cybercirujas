# 109.1 — Fundamentals of Internet Protocols

**LPIC-1, Exam 102-500 (v5.0) · Topic 109: Networking Fundamentals**

> Key knowledge areas: network masks and CIDR notation · private vs. public dotted-quad addresses · common TCP and UDP ports and services · differences and major features of UDP, TCP and ICMP · major differences between IPv4 and IPv6 · basic features of IPv6.
> Terms and utilities: `/etc/services`, IPv4, IPv6, subnetting, TCP, UDP, ICMP.

---

## 1. The production problem this objective actually solves

Every incident that begins with *"the service is down"* resolves into one of four questions, and all four live in this objective:

1. **Is the address plan sane?** Does the machine hold an address in the subnet it thinks it does, and does the mask agree with the router's mask?
2. **Is there a path?** Layer-3 reachability, MTU along that path, and the ICMP that makes both observable.
3. **Is the transport doing what you assumed?** TCP's connection semantics, backlog and retransmission behaviour are not the same failure surface as UDP's fire-and-forget.
4. **Is the port the one you think it is?** A listener bound to `127.0.0.1:5432` and a listener bound to `0.0.0.0:5432` are indistinguishable in a `ps` output and completely different in a postmortem.

The architectural failure that costs the most in real infrastructure is **address-space collision**. It is not exotic: it is the single most common cause of "the VPN works but half the cluster is unreachable". A concrete, repeated pattern:

- The corporate LAN uses `10.0.0.0/8` because someone typed the shortest thing that worked in 2014.
- A Kubernetes cluster is installed with the Flannel default `podSubnet: 10.244.0.0/16` — inside the LAN's `/8`.
- A site-to-site VPN then advertises `10.0.0.0/8` to the node.
- The node now has two routes covering `10.244.x.x`. Longest-prefix match saves you *only* while the pod CIDR route is the more specific one. The day the VPN pushes `10.244.0.0/16` explicitly, half the pod traffic goes down the tunnel and disappears.

The fix is not a command — it is an **address plan written before the first `ip addr add`**, and the ability to read a prefix and know instantly whether two ranges overlap. That skill is what section 2 builds.

The second recurring architectural failure is **blocking ICMP "because security"**. In IPv4 this degrades Path MTU Discovery into a silent black hole: TCP handshakes complete, small requests work, and the first response larger than the smallest link MTU hangs forever. In IPv6 it is worse — ICMPv6 carries Neighbor Discovery, so filtering it does not degrade the network, it *deletes* it. Section 4 covers the mechanics; section 6 shows the firewall rules that are correct rather than superstitious.

---

## 2. IPv4 addressing: masks, CIDR, and subnetting

### 2.1 The address is a 32-bit integer with a marked boundary

An IPv4 address is 32 bits, conventionally written as four decimal octets (the "dotted quad"). A **network mask** marks a boundary: the leading bits are the *network* portion, the trailing bits the *host* portion. CIDR notation (RFC 4632) writes the count of leading one-bits after a slash — `/26` means 26 network bits, 6 host bits.

Only *contiguous* masks are legal in modern routing. `255.255.255.192` (`/26`) is valid; `255.255.0.255` is not representable in CIDR and is rejected by the Linux stack.

```
10.42.7.23/26

Address    10.42.7.23        00001010.00101010.00000111.00|010111
Netmask    255.255.255.192   11111111.11111111.11111111.11|000000
Wildcard   0.0.0.63          00000000.00000000.00000000.00|111111
                                                          ^ boundary at bit 26

Network    10.42.7.0/26      ...00|000000   (host bits all 0)
First host 10.42.7.1
Last host  10.42.7.62
Broadcast  10.42.7.63        ...00|111111   (host bits all 1)
```

The three derived values follow mechanically:

- **Network address** = address AND netmask (host bits zeroed).
- **Broadcast address** = address OR wildcard (host bits set).
- **Usable hosts** = 2^(32−prefix) − 2, because the network and broadcast addresses are not assignable to interfaces.

Verify with `ipcalc`, which prints exactly this decomposition:

```
$ ipcalc 10.42.7.23/26
Address:   10.42.7.23           00001010.00101010.00000111.00 010111
Netmask:   255.255.255.192 = 26 11111111.11111111.11111111.11 000000
Wildcard:  0.0.0.63             00000000.00000000.00000000.00 111111
=>
Network:   10.42.7.0/26         00001010.00101010.00000111.00 000000
HostMin:   10.42.7.1            00001010.00101010.00000111.00 000001
HostMax:   10.42.7.62           00001010.00101010.00000111.00 111110
Broadcast: 10.42.7.63           00001010.00101010.00000111.00 111111
Hosts/Net: 62                    Class A, Private Internet
```

> **Exam trap.** `ipcalc` still prints "Class A". Classful addressing (A/B/C/D/E, fixed masks derived from the first octet) was superseded by CIDR in 1993. The class label tells you nothing about the mask in use; `10.42.7.23/26` is a `/26` regardless of the fact that `10.0.0.0` once had an implied `/8`. Know the classes for the exam vocabulary, never for a design decision.

### 2.2 The prefix table you must be able to reproduce from memory

| CIDR | Netmask | Wildcard | Addresses | Usable hosts | /24s covered | Typical production use |
|---|---|---|---|---|---|---|
| `/8`  | 255.0.0.0       | 0.255.255.255 | 16 777 216 | 16 777 214 | 65 536 | RFC 1918 supernet; never a broadcast domain |
| `/12` | 255.240.0.0     | 0.15.255.255  | 1 048 576  | 1 048 574  | 4 096  | `172.16.0.0/12` allocation block |
| `/16` | 255.255.0.0     | 0.0.255.255   | 65 536     | 65 534     | 256    | Region / VPC allocation, pod CIDR |
| `/20` | 255.255.240.0   | 0.0.15.255    | 4 096      | 4 094      | 16     | Availability-zone slice |
| `/21` | 255.255.248.0   | 0.0.7.255     | 2 048      | 2 046      | 8      | Large tenant subnet |
| `/22` | 255.255.252.0   | 0.0.3.255     | 1 024      | 1 022      | 4      | Node subnet in a large cluster |
| `/23` | 255.255.254.0   | 0.0.1.255     | 512        | 510        | 2      | Server VLAN |
| `/24` | 255.255.255.0   | 0.0.0.255     | 256        | 254        | 1      | Default VLAN unit |
| `/25` | 255.255.255.128 | 0.0.0.127     | 128        | 126        | ½      | Split VLAN |
| `/26` | 255.255.255.192 | 0.0.0.63      | 64         | 62         | ¼      | Rack / management segment |
| `/27` | 255.255.255.224 | 0.0.0.31      | 32         | 30         | ⅛      | Small DMZ, load-balancer pool |
| `/28` | 255.255.255.240 | 0.0.0.15      | 16         | 14         | 1/16   | Appliance segment |
| `/29` | 255.255.255.248 | 0.0.0.7       | 8          | 6          | 1/32   | Transit with spares |
| `/30` | 255.255.255.252 | 0.0.0.3       | 4          | 2          | 1/64   | Classic point-to-point link |
| `/31` | 255.255.255.254 | 0.0.0.1       | 2          | **2**      | 1/128  | Point-to-point, RFC 3021 (no net/bcast) |
| `/32` | 255.255.255.255 | 0.0.0.0       | 1          | 1          | —      | Host route, loopback VIP, anycast service IP |

Two entries break the "−2" rule and both matter in production:

- **`/31` (RFC 3021)** — on a point-to-point link there is nobody to broadcast to, so both addresses are usable. This halves the transit-link address consumption of a large fabric. Linux supports it natively.
- **`/32`** — a host route. Every anycast VIP, every `lo`-bound service address in a BGP-to-the-host design, and every `ip route add <ip>/32 dev ...` entry is one of these.

### 2.3 Subnetting worked end to end

**Requirement.** You are given `192.168.40.0/24` for one datacentre row and must carve: 100 servers, 50 servers, 25 servers, 10 servers, and two point-to-point uplinks. Allocate largest-first (VLSM) so the blocks stay aligned.

| Need | Hosts required | Smallest prefix | Block size | Assignment | Range | Broadcast |
|---|---|---|---|---|---|---|
| Compute A | 100 | `/25` (126) | 128 | `192.168.40.0/25` | .1 – .126 | .127 |
| Compute B | 50 | `/26` (62) | 64 | `192.168.40.128/26` | .129 – .190 | .191 |
| Storage | 25 | `/27` (30) | 32 | `192.168.40.192/27` | .193 – .222 | .223 |
| Management | 10 | `/28` (14) | 16 | `192.168.40.224/28` | .225 – .238 | .239 |
| Uplink 1 | 2 | `/30` | 4 | `192.168.40.240/30` | .241 – .242 | .243 |
| Uplink 2 | 2 | `/30` | 4 | `192.168.40.244/30` | .245 – .246 | .247 |
| *Reserved* | — | — | 8 | `192.168.40.248/29` | .249 – .254 | .255 |

The alignment rule that makes this work: **a block of size `N` must start at a multiple of `N`.** `192.168.40.128/26` is legal because 128 is a multiple of 64. `192.168.40.100/26` is not a network address at all — it is a host inside `192.168.40.64/26`.

The complementary skill is **supernetting** (route aggregation). Four adjacent, aligned `/24`s collapse into one `/22`:

```
192.168.40.0/24   11000000.10101000.00101000.00000000
192.168.41.0/24   11000000.10101000.00101001.00000000
192.168.42.0/24   11000000.10101000.00101010.00000000
192.168.43.0/24   11000000.10101000.00101011.00000000
                  ^--------- 22 bits identical --------^
                  => 192.168.40.0/22
```

This is why a routing table on a border device is 40 lines instead of 4 000 — and why an address plan that allocates blocks non-contiguously is a permanent operational tax.

### 2.4 Private, public and the special-purpose ranges

A **public** address is globally unique and routable across the Internet; allocation flows IANA → RIR (LACNIC, RIPE NCC, ARIN, APNIC, AFRINIC) → LIR/ISP → you. A **private** address is guaranteed *never* to be routed on the public Internet, so it can be reused inside every organisation independently — at the cost of requiring NAT to reach the outside.

| Range | CIDR | Size | RFC | Behaviour and production meaning |
|---|---|---|---|---|
| Private class-A block | `10.0.0.0/8` | 16.7 M | 1918 | The default for datacentre and cloud VPCs. Never allocate the whole `/8` to one routing domain. |
| Private class-B block | `172.16.0.0/12` | 1 M | 1918 | Spans `172.16.0.0`–`172.31.255.255`. **`172.32.0.0` is public.** Docker's default bridge pool lives here. |
| Private class-C block | `192.168.0.0/16` | 65 k | 1918 | Home/SOHO and lab default; avoid in a DC because every VPN client's home router collides with it. |
| Carrier-grade NAT | `100.64.0.0/10` | 4 M | 6598 | ISP-side NAT444. Reused by cloud providers for internal fabric. Do **not** assume it is yours. |
| Link-local (APIPA) | `169.254.0.0/16` | 65 k | 3927 | Self-assigned when DHCP fails. Also the cloud metadata endpoint `169.254.169.254`. Never routed. |
| Loopback | `127.0.0.0/8` | 16.7 M | 1122 | Entire `/8`, not just `127.0.0.1`. `127.0.0.53` is `systemd-resolved`'s stub listener. |
| Multicast | `224.0.0.0/4` | 268 M | 5771 | `224.0.0.1` all hosts, `224.0.0.2` all routers, `224.0.0.5/6` OSPF, `224.0.0.251` mDNS. |
| Reserved / future | `240.0.0.0/4` | 268 M | 1112 | Historically unusable; some stacks now accept it internally. Not Internet-routable. |
| Limited broadcast | `255.255.255.255/32` | 1 | 919 | Never forwarded by a router. DHCP DISCOVER uses it. |
| Documentation | `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24` | 3×256 | 5737 | TEST-NET-1/2/3. Use these in every runbook and diagram — never a real customer address. |
| Benchmarking | `198.18.0.0/15` | 131 k | 2544 | Device-testing range. Occasionally leaked by appliances. |
| Unspecified | `0.0.0.0/32` | 1 | 1122 | "This host". As a *bind* address it means **every** local address. |
| Default route | `0.0.0.0/0` | all | — | Prefix length zero matches everything; always loses longest-prefix match to anything more specific. |

> **Design rule.** Pick your RFC 1918 space from a region of `10.0.0.0/8` that nobody's home router and no vendor default occupies. `10.0.0.0/24`, `192.168.0.0/24`, `192.168.1.0/24` and `172.17.0.0/16` (Docker's default bridge) are the four most collision-prone prefixes in existence. Allocating `10.183.0.0/16` costs exactly the same and will not collide with a contractor's laptop.

NAT is the consequence of private addressing, and it is worth being precise about what it costs: it breaks end-to-end addressability, requires connection state on a middlebox (a failure domain and a table that can fill), complicates any protocol that carries addresses in its payload (FTP active mode, SIP), and makes inbound connections require explicit port forwarding. IPv6 exists to remove that entire category of problem.

---

## 3. IPv6: the fundamentals that change operational behaviour

### 3.1 Notation and compression

An IPv6 address is **128 bits**, written as eight groups of four hexadecimal digits separated by colons. Two compression rules apply, and RFC 5952 makes the canonical form mandatory for tooling:

1. Leading zeros in a group are omitted: `0db8` → `db8`, `0000` → `0`.
2. **One** run of consecutive all-zero groups is replaced by `::`. Only one, otherwise the expansion is ambiguous. Prefer the longest run; on a tie, the leftmost.

```
2001:0db8:0042:0007:0000:0000:0000:0023
2001:db8:42:7:0:0:0:23        (rule 1)
2001:db8:42:7::23             (rule 2)   <- canonical
```

Canonical form also requires lowercase hex. `2001:DB8::23` and `2001:db8::23` are the same address; only the second is canonical, and string-comparing non-canonical forms is a real bug source in ACL tooling.

In a URL the address is bracketed so the colons do not collide with the port separator: `https://[2001:db8:42:7::23]:8443/healthz`.

### 3.2 Address structure and scope

A typical global address decomposes as:

```
2001:db8:42:7:5054:ff:fe1a:2b3c
|________________|_______________|
   64-bit prefix    64-bit Interface ID
 |_______|________|
  /48 site  subnet
  from RIR   ID (16 bits => 65 536 subnets)
```

The `/64` boundary is effectively architectural law: SLAAC, Neighbor Discovery's solicited-node multicast and privacy addressing all assume a 64-bit Interface ID. Subnetting *below* `/64` on a LAN breaks autoconfiguration. You subnet by carving the /48 into /64s, not by borrowing host bits.

| Prefix | Name | Scope | Notes |
|---|---|---|---|
| `2000::/3` | Global unicast (GUA) | Global | Everything currently delegated by RIRs. |
| `fc00::/7` | Unique local (ULA) | Site | In practice `fd00::/8` — the L bit is set for locally-assigned, and the following 40 bits must be **randomly** generated. The IPv6 analogue of RFC 1918, without NAT. |
| `fe80::/10` | Link-local (LLA) | Link | Auto-configured on **every** IPv6 interface, always present. Carries NDP, and is the next-hop of essentially every IPv6 route. Requires a zone index: `fe80::1%enp1s0`. |
| `ff00::/8` | Multicast | varies | Replaces broadcast entirely. `ff02::1` all-nodes, `ff02::2` all-routers, `ff02::1:2` DHCPv6 relay agents/servers, `ff02::1:ffXX:XXXX` solicited-node. |
| `::1/128` | Loopback | Host | One address, not a `/8`. |
| `::/128` | Unspecified | — | Source address during DAD. As a bind address, all local addresses. |
| `::ffff:0:0/96` | IPv4-mapped | — | `::ffff:10.42.7.23` — how a dual-stack `AF_INET6` socket reports an IPv4 peer. |
| `2001:db8::/32` | Documentation | — | RFC 3849. Use it everywhere in docs. |
| `64:ff9b::/96` | NAT64 well-known | — | RFC 6052 translation prefix. |

**There is no broadcast in IPv6.** Anything that was broadcast is now a scoped multicast group, which means a NIC filters it in hardware and uninterested hosts never wake their CPU. This is a measurable power and interrupt-rate win on a dense L2 segment.

### 3.3 Interface ID: EUI-64, privacy addresses, stable addresses

Modified EUI-64 derives a 64-bit Interface ID from a 48-bit MAC:

```
MAC              52:54:00:1a:2b:3c
1) split, insert ff:fe in the middle:
                 52:54:00 : ff:fe : 1a:2b:3c
2) flip the Universal/Local bit (bit 7 of the first octet):
   0x52 = 0101 0010  ->  0101 0000 = 0x50
=> Interface ID     5054:00ff:fe1a:2b3c
=> canonical        5054:ff:fe1a:2b3c

Full address with prefix 2001:db8:42:7::/64:
   2001:db8:42:7:5054:ff:fe1a:2b3c
Its solicited-node multicast group (ff02::1:ff + low 24 bits):
   ff02::1:ff1a:2b3c
```

EUI-64 leaks the MAC — and therefore the hardware identity — into every packet the host sends worldwide. Two mitigations, both standard on modern Linux:

- **Privacy extensions (RFC 8981)** — a random, periodically rotated *temporary* address used for outbound connections, alongside a stable address for inbound. Controlled by `net.ipv6.conf.<if>.use_tempaddr` (`2` = prefer temporary for source selection).
- **Stable-privacy addresses (RFC 7217)** — a stable-per-prefix but non-MAC-derived Interface ID. This is what NetworkManager's `addr-gen-mode=stable-privacy` and `systemd-networkd`'s `IPv6LinkLocalAddressGenerationMode=stable-privacy` produce, and it is the correct default for servers: stable enough to firewall, opaque enough not to leak hardware identity.

### 3.4 Address assignment: SLAAC, DHCPv6, and the RA flags

IPv6 has three coexisting mechanisms, and which one runs is decided by **flag bits in the Router Advertisement**, not by the client:

| RA flags | Client behaviour | Address source | Where DNS comes from |
|---|---|---|---|
| `M=0 A=1 O=0` | Pure SLAAC | Host builds its own address from the RA prefix | RDNSS option in the RA (RFC 8106) |
| `M=0 A=1 O=1` | SLAAC + stateless DHCPv6 | Host builds its own address | DHCPv6 (other config only) |
| `M=1 A=0` | Stateful DHCPv6 | DHCPv6 server assigns and tracks | DHCPv6 |
| No RA at all | Link-local only | `fe80::/64` only | nothing |

Critical operational consequences:

- **A host cannot obtain a default route from DHCPv6.** There is no "router" option in DHCPv6; the default gateway *only* arrives via Router Advertisement. A network where RAs are filtered but DHCPv6 works produces hosts with global addresses and no way off the link.
- **Duplicate Address Detection (DAD)** runs before any address becomes usable — the host sends a Neighbor Solicitation for its own tentative address from `::`. If DAD fails the address is marked `dadfailed` and never used.
- Addresses carry **lifetimes** (`valid_lft` / `preferred_lft`). A "preferred" address is used for new connections; a "deprecated" one keeps existing connections alive but is no longer chosen as a source. This is native, graceful renumbering — IPv4 has no equivalent.

### 3.5 Neighbor Discovery replaces ARP — and it is ICMPv6

| Function | IPv4 mechanism | IPv6 mechanism | ICMPv6 type |
|---|---|---|---|
| L3 → L2 resolution | ARP (EtherType 0x0806, separate protocol) | Neighbor Solicitation / Advertisement | 135 / 136 |
| Router discovery | ICMP Router Discovery (rare) or DHCP option 3 | Router Solicitation / Advertisement | 133 / 134 |
| Better-path notification | ICMP Redirect (type 5) | Redirect | 137 |
| Duplicate detection | gratuitous ARP (advisory) | DAD (mandatory, part of NS) | 135 |
| Address autoconfiguration | DHCP only | SLAAC via RA prefix | 134 |

Because all of it is ICMPv6, **a firewall that drops ICMPv6 destroys the link**. RFC 4890 specifies exactly what must be permitted; section 6.4 implements it.

### 3.6 IPv4 vs IPv6 — the comparison table to memorise

| Dimension | IPv4 | IPv6 | Operational consequence |
|---|---|---|---|
| Address size | 32 bit (~4.3×10⁹) | 128 bit (~3.4×10³⁸) | End-to-end addressing without NAT |
| Notation | dotted decimal `10.42.7.23` | colon hex `2001:db8:42:7::23` | Bracket in URLs; canonicalise before comparing |
| Header | 20–60 bytes, **variable** (options, IHL field) | **40 bytes fixed** + extension header chain | Fixed header enables cheaper hardware forwarding |
| Header checksum | present, recomputed at every hop | **removed** | Router forwarding path is cheaper; integrity delegated to L2 and L4 |
| L4 checksum | optional for UDP | **mandatory** for UDP | A UDP/IPv6 datagram with checksum 0 is dropped |
| Fragmentation | by source *and* by routers | **source only**, via Fragment extension header | Routers return ICMPv6 type 2 instead; PMTUD is not optional |
| Minimum MTU | 576 | **1280** | Any tunnel must deliver ≥1280 or IPv6 breaks |
| Broadcast | yes (`255.255.255.255`, subnet bcast) | **none** — multicast only | Lower NIC interrupt load on large L2 |
| L2 resolution | ARP | NDP over ICMPv6 | Cannot filter ICMPv6 wholesale |
| Autoconfiguration | DHCP (or APIPA fallback) | SLAAC, DHCPv6, or both | Default route only via RA |
| Addresses per interface | typically one | **many by design** (LLA + GUA + ULA + temporary) | Source-address selection (RFC 6724) is a real subsystem |
| IPsec | optional bolt-on | originally mandatory-to-implement | In practice: use WireGuard/TLS either way |
| QoS field | ToS / DSCP | Traffic Class + 20-bit **Flow Label** | Flow Label enables stateless ECMP hashing on encrypted flows |
| NAT | ubiquitous necessity | NPTv6 exists, discouraged | Firewalling replaces NAT as the security boundary |
| Loopback | `127.0.0.0/8` | `::1/128` | An entire `/8` vs. exactly one address |
| Private space | RFC 1918 | ULA `fd00::/8` | ULA is randomly generated, not chosen |

**Dual stack** is the practical deployment mode: the interface holds both families, DNS returns both `A` and `AAAA`, and the client uses **Happy Eyeballs v2 (RFC 8305)** — start the AAAA connection, race an A connection ~250 ms later, keep whichever completes first. This means a broken IPv6 path shows up as *latency*, not failure, which is precisely why it stays broken for months. Section 7 shows how to prove which family a connection actually used.

---

## 4. Transport and control: TCP, UDP, ICMP

### 4.1 The layered model in one table

| Layer (TCP/IP) | OSI equivalent | PDU | Addressing | Linux artefacts |
|---|---|---|---|---|
| Application | 5–7 | message | URI, service name | `/etc/services`, listener config |
| Transport | 4 | segment (TCP) / datagram (UDP) | port (16 bit) | `ss`, `net.ipv4.tcp_*` sysctls |
| Internet | 3 | packet | IP address | `ip route`, `ip addr`, ICMP |
| Link | 1–2 | frame | MAC | `ip link`, `ip neigh`, `ethtool` |

### 4.2 TCP — reliable, ordered, connection-oriented

TCP (RFC 9293, consolidating RFC 793) provides a reliable byte stream: sequence numbers order and detect loss, cumulative ACKs (plus SACK) confirm delivery, retransmission recovers loss, sliding windows provide flow control, and congestion control (`cubic` by default on Linux, `bbr` where deployed) provides network fairness.

**Connection establishment — the three-way handshake:**

```
Client                                         Server
  |  SYN   seq=x                                  |   server socket: LISTEN
  |---------------------------------------------->|   -> SYN-RECEIVED (SYN queue)
  |  SYN,ACK  seq=y ack=x+1                       |
  |<----------------------------------------------|
  |  ACK   seq=x+1 ack=y+1                        |   -> ESTABLISHED (accept queue)
  |---------------------------------------------->|
  |                  ESTABLISHED                  |
```

**Teardown — four-way, with the asymmetry that matters:**

```
  |  FIN                --> |  ESTABLISHED -> CLOSE-WAIT
  |  <-- ACK                |
  |  <-- FIN                |  CLOSE-WAIT -> LAST-ACK
  |  ACK                --> |  -> CLOSED
  FIN-WAIT-1/2 -> TIME-WAIT (2×MSL, 60 s on Linux) -> CLOSED
```

The eleven states, and what each one means when you see it in `ss`:

| State | Meaning | What a pile of them tells you |
|---|---|---|
| `LISTEN` | Passive socket awaiting connections | Normal. Check the bind address, not just the port. |
| `SYN-SENT` | Client sent SYN, no reply | Firewall dropping (not rejecting), or wrong address |
| `SYN-RECV` | Half-open on the server | SYN flood, or accept() starvation |
| `ESTABLISHED` | Data may flow | Normal |
| `FIN-WAIT-1` / `FIN-WAIT-2` | Local close sent; peer has not closed | Peer application not calling `close()` |
| `CLOSE-WAIT` | **Peer closed; local app has not** | Almost always an application bug — a leaked file descriptor. Kernel cannot fix it. |
| `LAST-ACK` | Local close sent after peer's | Transient |
| `TIME-WAIT` | Waiting 2×MSL to absorb stray segments | Normal on the side that closes first; only pathological in the tens of thousands |
| `CLOSING` | Simultaneous close | Rare |
| `CLOSED` | No connection | — |

**Header fields that appear in real diagnosis:** source/destination port (16 bit each), 32-bit sequence and acknowledgement numbers, data offset, flags (`SYN` `ACK` `FIN` `RST` `PSH` `URG` `ECE` `CWR`), 16-bit window (scaled by the window-scale option up to 1 GB), checksum, urgent pointer. Options negotiated in the SYN: **MSS** (Maximum Segment Size), **window scale**, **SACK permitted**, **timestamps**.

**MSS vs MTU** — the relationship that causes half of all "slow network" tickets:

```
MSS(IPv4) = MTU − 20 (IP header) − 20 (TCP header) = 1500 − 40 = 1460
MSS(IPv6) = MTU − 40 (IP header) − 20 (TCP header) = 1500 − 60 = 1440
Over a WireGuard tunnel (MTU 1420): MSS = 1380 / 1360
```

### 4.3 UDP — connectionless datagrams

UDP (RFC 768) is an 8-byte header over IP: source port, destination port, length, checksum. No handshake, no ordering, no retransmission, no flow or congestion control. What it gives you is **the absence of head-of-line blocking and the absence of state** — which is exactly what DNS, NTP, SNMP, syslog, VXLAN, WireGuard and QUIC want.

The two UDP facts most often gotten wrong:

- **Checksum is optional in IPv4** (a zero checksum means "not computed") **and mandatory in IPv6**, because IPv6 removed the network-layer checksum.
- **UDP has no MSS negotiation**, so a datagram larger than the path MTU is fragmented at the IP layer. If any middlebox drops fragments — extremely common — large DNS responses (DNSSEC, big `TXT`) vanish while small ones work. This is why EDNS0 buffer sizes were reduced to 1232 bytes and why DNS falls back to TCP.

### 4.4 ICMP — the control plane of IP

ICMP (RFC 792 for IPv4, RFC 4443 for ICMPv6) is **not** a transport protocol: it carries no ports and no application payload. It is IP's own signalling channel — error reporting and diagnostics.

| Purpose | ICMPv4 type/code | ICMPv6 type/code | Why you must not block it |
|---|---|---|---|
| Echo request / reply | 8 / 0 | 128 / 129 | Basic reachability |
| Destination unreachable — net | 3/0 | 1/0 | Routing failure is reported, not silent |
| Destination unreachable — host | 3/1 | 1/3 | — |
| Destination unreachable — port | 3/3 | 1/4 | How `traceroute` and UDP scans terminate |
| **Fragmentation needed, DF set** | **3/4** | — | **Path MTU Discovery in IPv4** |
| **Packet Too Big** | — | **2** | **Path MTU Discovery in IPv6 — mandatory** |
| Time exceeded (TTL/hop limit) | 11/0 | 3/0 | How `traceroute` works at all |
| Parameter problem | 12 | 4 | Malformed header reporting |
| Redirect | 5 | 137 | Better first-hop notification |
| Neighbor/Router Discovery | *(ARP, separate)* | **133–137** | **Without these IPv6 does not function** |

**The PMTU black hole**, in full, because it is the highest-value diagnostic in this objective:

1. A host sends a 1500-byte TCP segment with the **DF (Don't Fragment)** bit set — Linux sets DF by default (`net.ipv4.ip_no_pmtu_disc=0`).
2. A mid-path link (GRE tunnel, PPPoE, IPsec, WireGuard) has MTU 1400.
3. The router **must** drop the packet and return **ICMP type 3 code 4** carrying the next-hop MTU.
4. A firewall blocks that ICMP.
5. The sender never learns. TCP retransmits the same oversize segment forever.

Symptom signature: the handshake succeeds, `curl -I` (small response) works, `curl` of the full page hangs, `ssh` connects and then freezes at the banner. Diagnosis in section 7.4.

### 4.5 TCP vs UDP vs ICMP trade-offs

| Property | TCP | UDP | ICMP |
|---|---|---|---|
| IP protocol number | 6 | 17 | 1 (v4) / 58 (v6) |
| Connection | connection-oriented (3-way handshake) | connectionless | connectionless |
| Header size | 20–60 bytes | **8 bytes** | 8 bytes + payload copy |
| Ports | yes | yes | **no** |
| Reliability | guaranteed delivery + ordering | none | none |
| Ordering | yes (sequence numbers) | none | none |
| Flow control | sliding window | none | none |
| Congestion control | yes (cubic/bbr) | none — app's responsibility | rate-limited by kernel |
| Multicast / broadcast | **no** (unicast only) | yes | yes (v6 multicast) |
| Head-of-line blocking | yes (one stream) | no | n/a |
| Handshake latency | 1 RTT (+2 for TLS 1.2, +1 for TLS 1.3) | 0 RTT | 0 RTT |
| Overhead per small message | high | minimal | minimal |
| NAT/firewall traversal | easy (state is explicit) | harder (pseudo-state, short timeouts) | frequently blocked |
| Kernel state per flow | full TCB, TIME-WAIT after close | none | none |
| Typical use | HTTP/1.1–2, SSH, SMTP, LDAP, DB | DNS, NTP, SNMP, syslog, VXLAN, QUIC/HTTP-3, VoIP | ping, traceroute, PMTUD, NDP |
| Failure mode when the path is bad | slow (retransmit + backoff) | silent loss | invisible — and it breaks the other two |

> **The QUIC caveat.** HTTP/3 runs over **UDP port 443** and rebuilds reliability, ordering, congestion control and TLS in userspace. Firewall rules that permit `tcp dport 443` and nothing else silently force every modern client back to HTTP/2 — again a latency regression, not an outage, and therefore invisible for months.

---

## 5. Ports and `/etc/services`

### 5.1 Port ranges

A port is a 16-bit unsigned integer: 0–65535. IANA divides the space:

| Range | Name | Binding privilege | Notes |
|---|---|---|---|
| 0–1023 | Well-known / System | Requires `CAP_NET_BIND_SERVICE` (historically root) | Assigned by IANA. Port 0 means "kernel, pick one". |
| 1024–49151 | Registered / User | unprivileged | Registered with IANA but not privileged |
| 49152–65535 | Dynamic / Private / Ephemeral | unprivileged | IANA's suggested ephemeral range |

Linux does **not** use IANA's ephemeral range by default:

```
$ sysctl net.ipv4.ip_local_port_range
net.ipv4.ip_local_port_range = 32768	60999
```

That is 28 231 outbound ports **per (source IP, destination IP, destination port) tuple**. A busy reverse proxy talking to a single upstream can exhaust it; symptoms are `EADDRNOTAVAIL` and connect failures under load. The fixes, in order of preference: add upstream addresses, enable connection reuse/keep-alive, widen the range, then `net.ipv4.tcp_tw_reuse=1` (safe for outbound with timestamps enabled — unlike the long-removed `tcp_tw_recycle`, which was never safe behind NAT).

Modern kernels grant `CAP_NET_BIND_SERVICE` per-service via systemd (`AmbientCapabilities=`), or you can lower the threshold globally:

```
$ sysctl net.ipv4.ip_unprivileged_port_start
net.ipv4.ip_unprivileged_port_start = 1024
```

### 5.2 The port table the exam requires

| Port | Proto | Service | `/etc/services` name | Production note |
|---|---|---|---|---|
| **20** | TCP | FTP data | `ftp-data` | Active mode: **server** initiates from :20 back to the client. This is why active FTP dies behind NAT. |
| **21** | TCP | FTP control | `ftp` | Cleartext credentials. Passive mode uses a high dynamic port for data. |
| **22** | TCP | SSH | `ssh` | Also SFTP and SCP — one port, no separate data channel. |
| **23** | TCP | Telnet | `telnet` | Cleartext, including the password. Should not exist on a production network. |
| **25** | TCP | SMTP | `smtp` | MTA-to-MTA relay. Commonly blocked outbound by cloud providers and residential ISPs. |
| **53** | **TCP + UDP** | DNS | `domain` | UDP for queries; **TCP for zone transfers (AXFR) and any response exceeding the UDP buffer**. Blocking TCP/53 breaks DNSSEC. |
| **80** | TCP | HTTP | `http` | Cleartext. Keep only for ACME `http-01` and a 301 to HTTPS. |
| **110** | TCP | POP3 | `pop3` | Cleartext; downloads and typically deletes. |
| **123** | UDP | NTP | `ntp` | Time sync. An open NTP server with `monlist` is a DDoS amplifier — restrict it. |
| **139** | TCP | NetBIOS Session Service | `netbios-ssn` | Legacy SMB transport. Modern SMB is 445 (`microsoft-ds`). |
| **143** | TCP | IMAP | `imap` | Cleartext; server-side mailbox state. |
| **161** | UDP | SNMP | `snmp` | Polling. v1/v2c community strings are cleartext — use v3. |
| **162** | UDP | SNMP trap | `snmptrap` | Agent→manager notifications. Opposite direction from 161. |
| **389** | TCP + UDP | LDAP | `ldap` | Cleartext, or TLS via **STARTTLS on the same port**. |
| **443** | **TCP + UDP** | HTTPS | `https` | TCP for HTTP/1.1 and HTTP/2; **UDP for HTTP/3 (QUIC)**. |
| **465** | TCP | SMTPS / submissions | `submissions`, `urd`, `smtps` | Implicit TLS mail submission (RFC 8314). Historically deprecated, then re-blessed. Compare 587 = STARTTLS submission. |
| **514** | **UDP** (syslog) / TCP (`shell`) | syslog / rsh | `syslog` (udp), `shell` (tcp) | Classic remote logging is UDP — lossy by design. TCP/514 is the legacy `rsh`. Modern: TCP/6514 syslog-over-TLS. |
| **636** | TCP | LDAPS | `ldaps` | Implicit TLS LDAP. |
| **993** | TCP | IMAPS | `imaps` | Implicit TLS IMAP. |
| **995** | TCP | POP3S | `pop3s` | Implicit TLS POP3. |

Worth knowing beyond the required list, because they appear in every real deployment:

| Port | Proto | Service | Note |
|---|---|---|---|
| 67 / 68 | UDP | DHCP server / client | 546/547 for DHCPv6 |
| 69 | UDP | TFTP | PXE boot |
| 179 | TCP | BGP | Present on every leaf/spine and in Calico/MetalLB |
| 445 | TCP | SMB over TCP | The modern replacement for 139 |
| 587 | TCP | Mail submission (STARTTLS) | Contrast with 465 |
| 3306 / 5432 | TCP | MySQL / PostgreSQL | Never expose to the Internet |
| 6443 | TCP | Kubernetes API server | |
| 2379 / 2380 | TCP | etcd client / peer | |
| 51820 | UDP | WireGuard | Default; user-selected in practice |

### 5.3 What `/etc/services` is — and is not

`/etc/services` is the local database mapping **service names to port/protocol pairs**. It is consulted through the NSS `services` database, so a directory service can extend or replace it:

```
$ grep -E '^(services|hosts):' /etc/nsswitch.conf
hosts:          files mdns4_minimal [NOTFOUND=return] dns myhostname
services:       files
```

Format: `name  port/protocol  [aliases...]  # comment`

```
$ grep -E '^(ssh|domain|https|imaps|submissions|syslog|snmptrap)\b' /etc/services
ssh		22/tcp				# SSH Remote Login Protocol
domain		53/tcp
domain		53/udp
https		443/tcp
https		443/udp				# HTTP/3
imaps		993/tcp				# IMAP over SSL
submissions	465/tcp		ssmtp smtps urd	# Submission over TLS [RFC8314]
syslog		514/udp
snmptrap	162/udp		snmp-trap
```

Query it through the library rather than by grepping the file — this respects NSS and gets the protocol right:

```
$ getent services 993/tcp
imaps                 993/tcp

$ getent services ldaps
ldaps                 636/tcp

$ getent services 514/udp
syslog                514/udp
```

**What it is not:** editing `/etc/services` does not open a port, close a port, start a daemon, or change what any running process is bound to. It is a *naming* table. It affects:

- The symbolic names `ss`, `netstat`, `lsof` and `nmap` print (which is why you use `ss -n` when you want the truth).
- Programs that call `getservbyname()`/`getaddrinfo()` with a service string — including `nc host imaps` and some `xinetd`/socket-activated setups.

```
$ ss -tln | head -4
State   Recv-Q  Send-Q   Local Address:Port    Peer Address:Port
LISTEN  0       4096     127.0.0.53%lo:domain      0.0.0.0:*
LISTEN  0       128            0.0.0.0:ssh         0.0.0.0:*
LISTEN  0       511                  *:https             *:*

$ ss -tln -n | head -4          # -n: never resolve names, show real numbers
State   Recv-Q  Send-Q   Local Address:Port    Peer Address:Port
LISTEN  0       4096     127.0.0.53%lo:53          0.0.0.0:*
LISTEN  0       128            0.0.0.0:22          0.0.0.0:*
LISTEN  0       511                  *:443               *:*
```

> **Read the bind address, not just the port.** `127.0.0.53%lo:53` is reachable only from the host. `0.0.0.0:22` is every IPv4 address on the box. `*:443` with `*` in both columns is a dual-stack IPv6 socket accepting IPv4 via `::ffff:` mapping (`net.ipv6.bindv6only=0`). Confusing these three is the most common false "the firewall is broken" report.

---

## 6. Complete production configurations

Everything below is deployable as written. Addresses use RFC 5737 / RFC 3849 documentation ranges.

### 6.1 Netplan — dual-stack server with static IPv4 and SLAAC-plus-static IPv6

`/etc/netplan/01-datacentre.yaml` (mode `0600`, or netplan warns):

```yaml
# /etc/netplan/01-datacentre.yaml
# Dual-stack production host. Apply with:  netplan try  (auto-reverts in 120 s)
network:
  version: 2
  renderer: networkd

  ethernets:
    enp1s0:
      match:
        macaddress: "52:54:00:1a:2b:3c"
      set-name: enp1s0
      dhcp4: false
      dhcp6: false
      accept-ra: true              # default route + prefix arrive via RA, never via DHCPv6
      ipv6-privacy: false          # servers keep stable addresses; clients set true
      link-local: [ipv6]
      mtu: 1500
      addresses:
        - 198.51.100.23/26
        - "2001:db8:42:7::23/64"
      nameservers:
        addresses:
          - 198.51.100.5
          - 198.51.100.6
          - "2001:db8:42:7::5"
        search:
          - dc1.example.net
          - example.net
      routes:
        - to: default
          via: 198.51.100.1
          metric: 100
          on-link: true
        - to: "default"
          via: "2001:db8:42:7::1"
          metric: 100
        # Storage network reachable only through the ToR's secondary address
        - to: 10.183.64.0/20
          via: 198.51.100.2
          metric: 200

    enp2s0:
      dhcp4: false
      dhcp6: false
      accept-ra: false
      mtu: 9000                    # jumbo frames on the storage fabric
      addresses:
        - 10.183.64.23/24
      routes:
        - to: 10.183.0.0/16
          via: 10.183.64.1
          metric: 50

  bonds:
    bond0:
      interfaces: [enp3s0, enp4s0]
      parameters:
        mode: 802.3ad
        lacp-rate: fast
        mii-monitor-interval: 100
        transmit-hash-policy: layer3+4
      dhcp4: false
      dhcp6: false
      accept-ra: false

  vlans:
    bond0.310:
      id: 310
      link: bond0
      addresses:
        - 203.0.113.23/28
        - "2001:db8:42:310::23/64"
      accept-ra: false
      routes:
        - to: 0.0.0.0/0
          via: 203.0.113.17
          metric: 300
          table: 310
      routing-policy:
        - from: 203.0.113.23/32
          table: 310
          priority: 32000
```

```
$ sudo netplan generate && sudo netplan try
Do you want to keep these settings?

Press ENTER before the timeout to accept the new configuration

Changes will revert in 120 seconds
Configuration accepted.
```

### 6.2 systemd-networkd — the same host without Netplan

```ini
# /etc/systemd/network/10-enp1s0.network
[Match]
Name=enp1s0

[Link]
MTUBytes=1500
RequiredForOnline=routable

[Network]
Description=Front-end dual-stack interface
DHCP=no
IPv6AcceptRA=yes
LinkLocalAddressing=ipv6
IPv6LinkLocalAddressGenerationMode=stable-privacy
IPv6PrivacyExtensions=no
IPForward=no
DNS=198.51.100.5
DNS=2001:db8:42:7::5
Domains=dc1.example.net example.net

[Address]
Address=198.51.100.23/26

[Address]
Address=2001:db8:42:7::23/64

[Route]
Gateway=198.51.100.1
Destination=0.0.0.0/0
Metric=100

[Route]
Gateway=2001:db8:42:7::1
Destination=::/0
Metric=100

[IPv6AcceptRA]
UseDNS=yes
UseDomains=yes
DHCPv6Client=always
```

```
$ sudo systemctl restart systemd-networkd
$ networkctl status enp1s0
● 2: enp1s0
                   Link File: /usr/lib/systemd/network/99-default.link
                Network File: /etc/systemd/network/10-enp1s0.network
                       State: routable (configured)
                Online state: online
                        Type: ether
                        Path: pci-0000:00:01.0
                      Driver: virtio_net
                      Vendor: Red Hat, Inc.
                  HW Address: 52:54:00:1a:2b:3c
                         MTU: 1500 (min: 68, max: 65535)
                     Address: 198.51.100.23
                              2001:db8:42:7::23
                              2001:db8:42:7:5054:ff:fe1a:2b3c
                              fe80::9c4e:1f7a:2b19:64d3
                     Gateway: 198.51.100.1
                              2001:db8:42:7::1 (Cisco Systems)
                         DNS: 198.51.100.5
                              2001:db8:42:7::5
              Search Domains: dc1.example.net
                              example.net
```

### 6.3 Kernel tuning — the sysctls that belong to this objective

```ini
# /etc/sysctl.d/60-network-baseline.conf
# Apply: sysctl --system   Verify: sysctl -a --pattern 'net\.(ipv4|ipv6|core)'

#### Forwarding — enable ONLY on a router/NAT gateway/Kubernetes node
net.ipv4.ip_forward                     = 0
net.ipv6.conf.all.forwarding            = 0

#### Anti-spoofing: strict reverse-path filter (RFC 3704). Use 2 (loose)
#### on multihomed or asymmetric-routing hosts, never 0.
net.ipv4.conf.all.rp_filter             = 1
net.ipv4.conf.default.rp_filter         = 1

#### Never accept source routing or ICMP redirects on a server
net.ipv4.conf.all.accept_source_route   = 0
net.ipv6.conf.all.accept_source_route   = 0
net.ipv4.conf.all.accept_redirects      = 0
net.ipv6.conf.all.accept_redirects      = 0
net.ipv4.conf.all.send_redirects        = 0
net.ipv4.conf.all.log_martians          = 1

#### ICMP: answer echo (do NOT set icmp_echo_ignore_all — it blinds your NOC),
#### but ignore broadcast echo so the host cannot be a smurf amplifier.
net.ipv4.icmp_echo_ignore_all           = 0
net.ipv4.icmp_echo_ignore_broadcasts    = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

#### TCP connection setup
net.ipv4.tcp_syncookies                 = 1      # survive SYN floods
net.ipv4.tcp_max_syn_backlog            = 8192   # SYN queue (half-open)
net.core.somaxconn                      = 4096   # accept-queue ceiling; app must
                                                 # still pass a matching listen(2) backlog
net.ipv4.tcp_abort_on_overflow          = 0      # drop, let the client retry

#### Ephemeral ports and TIME-WAIT reuse (outbound-heavy proxies)
net.ipv4.ip_local_port_range            = 16384 65535
net.ipv4.tcp_tw_reuse                   = 1      # safe for OUTBOUND with timestamps
net.ipv4.tcp_fin_timeout                = 30
net.ipv4.tcp_timestamps                 = 1

#### Path MTU Discovery: probe around ICMP black holes instead of hanging
net.ipv4.tcp_mtu_probing                = 1
net.ipv4.ip_no_pmtu_disc                = 0

#### Buffers and congestion control
net.core.rmem_max                       = 16777216
net.core.wmem_max                       = 16777216
net.ipv4.tcp_rmem                       = 4096 131072 16777216
net.ipv4.tcp_wmem                       = 4096  16384 16777216
net.ipv4.tcp_congestion_control         = bbr
net.core.default_qdisc                  = fq

#### IPv6: keep it on. Disabling it is not a security control, it is a
#### guarantee that the day it is needed nothing works.
net.ipv6.conf.all.disable_ipv6          = 0
net.ipv6.conf.all.accept_ra             = 1
net.ipv6.conf.default.accept_ra         = 1
net.ipv6.conf.all.accept_ra_defrtr      = 1
net.ipv6.conf.all.use_tempaddr          = 0      # 2 on workstations
net.ipv6.conf.all.addr_gen_mode         = 3      # stable-privacy (RFC 7217)
net.ipv6.conf.all.dad_transmits         = 1
```

```
$ sudo sysctl --system
* Applying /etc/sysctl.d/60-network-baseline.conf ...
net.ipv4.ip_forward = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.core.somaxconn = 4096
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_congestion_control = bbr
...
* Applying /etc/sysctl.conf ...

$ sysctl net.ipv4.tcp_congestion_control net.core.somaxconn
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 4096
```

### 6.4 nftables — a correct dual-stack ruleset, including the ICMP that must pass

```nft
#!/usr/sbin/nft -f
# /etc/nftables.conf
# Load: nft -f /etc/nftables.conf     Persist: systemctl enable --now nftables

flush ruleset

table inet filter {

    # ---- named sets: edit these, not the rules -------------------------
    set admin_v4 {
        type ipv4_addr
        flags interval
        elements = { 198.51.100.0/26, 10.183.0.0/16 }
    }
    set admin_v6 {
        type ipv6_addr
        flags interval
        elements = { 2001:db8:42::/48 }
    }
    set public_tcp {
        type inet_service
        elements = { 80, 443 }          # http, https
    }
    set monitoring_v4 {
        type ipv4_addr
        flags interval
        elements = { 198.51.100.64/28 }
    }

    chain input {
        type filter hook input priority filter; policy drop;

        # 1. Fast path for known flows
        ct state established,related accept
        ct state invalid drop comment "no state, no service"

        # 2. Loopback is trusted; anything claiming to be lo from elsewhere is spoofed
        iif lo accept
        iif != lo ip  daddr 127.0.0.0/8 drop
        iif != lo ip6 daddr ::1/128     drop

        # 3. ICMPv4: keep PMTUD and diagnostics alive
        ip protocol icmp icmp type {
            echo-request,
            destination-unreachable,     # includes 3/4 frag-needed => PMTUD
            time-exceeded,
            parameter-problem
        } limit rate 20/second burst 40 packets accept

        # 4. ICMPv6 per RFC 4890. Dropping this BREAKS IPv6 — it is not optional.
        #    NDP messages must be accepted with hop limit 255 (link-local only).
        ip6 nexthdr icmpv6 icmpv6 type {
            nd-neighbor-solicit,
            nd-neighbor-advert,
            nd-router-solicit,
            nd-router-advert
        } ip6 hoplimit 255 accept

        ip6 nexthdr icmpv6 icmpv6 type {
            destination-unreachable,
            packet-too-big,             # PMTUD for IPv6 — mandatory
            time-exceeded,
            parameter-problem
        } accept

        ip6 nexthdr icmpv6 icmpv6 type echo-request \
            limit rate 20/second burst 40 packets accept

        # Multicast Listener Discovery
        ip6 nexthdr icmpv6 icmpv6 type {
            mld-listener-query,
            mld-listener-report,
            mld-listener-done
        } ip6 saddr fe80::/10 accept

        # 5. DHCPv6 client replies (server -> client)
        ip6 saddr fe80::/10 udp sport 547 udp dport 546 accept

        # 6. SSH — administrative networks only, with brute-force damping
        tcp dport 22 ip  saddr @admin_v4 ct state new \
            limit rate 6/minute burst 6 packets accept
        tcp dport 22 ip6 saddr @admin_v6 ct state new \
            limit rate 6/minute burst 6 packets accept

        # 7. Public services: HTTP/HTTPS over TCP *and* HTTP/3 over UDP/443
        tcp dport @public_tcp accept
        udp dport 443 accept comment "HTTP/3 QUIC — omit this and clients silently downgrade"

        # 8. SNMP polling and syslog, from the monitoring range only
        udp dport 161 ip saddr @monitoring_v4 accept comment "snmp"
        udp dport 514 ip saddr @monitoring_v4 accept comment "syslog"

        # 9. Log the remainder at a low rate, then the policy drops it
        limit rate 5/minute burst 10 packets \
            log prefix "nft-input-drop: " level info counter
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state established,related accept
        ct state invalid drop

        # Clamp TCP MSS to the real path MTU. This is the single rule that
        # prevents "handshake works, transfer hangs" over tunnels.
        tcp flags syn tcp option maxseg size set rt mtu
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
```

```
$ sudo nft -f /etc/nftables.conf && sudo nft list ruleset | head -20
table inet filter {
	set admin_v4 {
		type ipv4_addr
		flags interval
		elements = { 10.183.0.0/16, 198.51.100.0/26 }
	}
	...
	chain input {
		type filter hook input priority filter; policy drop;
		ct state established,related accept
		ct state invalid drop comment "no state, no service"
		iif "lo" accept
		...
	}
}

$ sudo nft list ruleset | grep -c 'icmpv6'
4
```

### 6.5 Kubernetes — an address plan that does not collide, plus dual stack

```yaml
# kubeadm-dualstack.yaml
# kubeadm init --config kubeadm-dualstack.yaml --upload-certs
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.31.0
clusterName: dc1-prod
controlPlaneEndpoint: "api.dc1.example.net:6443"
networking:
  # IPv4 chosen deliberately OUTSIDE 10.0.0.0/16, 172.17.0.0/16 and
  # 192.168.0.0/16 so it cannot collide with the corporate VPN,
  # Docker's default bridge, or any employee's home router.
  podSubnet: "10.183.128.0/17,fd00:dc1:244::/56"
  serviceSubnet: "10.183.96.0/20,fd00:dc1:96::/112"
  dnsDomain: cluster.local
apiServer:
  certSANs:
    - api.dc1.example.net
    - 198.51.100.10
    - "2001:db8:42:7::10"
  extraArgs:
    - name: service-cluster-ip-range
      value: "10.183.96.0/20,fd00:dc1:96::/112"
    - name: secure-port
      value: "6443"
controllerManager:
  extraArgs:
    - name: node-cidr-mask-size-ipv4
      value: "24"           # 128 pods-worth of /24 per node out of the /17
    - name: node-cidr-mask-size-ipv6
      value: "64"
    - name: allocate-node-cidrs
      value: "true"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "198.51.100.23"
  bindPort: 6443
nodeRegistration:
  kubeletExtraArgs:
    - name: node-ip
      value: "198.51.100.23,2001:db8:42:7::23"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
clusterDNS:
  - "10.183.96.10"
  - "fd00:dc1:96::a"
```

A Service that names its ports after `/etc/services` entries, and a NetworkPolicy that encodes the transport distinctions from section 4:

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: edge-gateway
  namespace: edge
  labels:
    app.kubernetes.io/name: edge-gateway
spec:
  type: LoadBalancer
  ipFamilyPolicy: RequireDualStack
  ipFamilies:
    - IPv4
    - IPv6
  externalTrafficPolicy: Local     # preserves the client source IP
  selector:
    app.kubernetes.io/name: edge-gateway
  ports:
    - name: http                   # 80/tcp
      protocol: TCP
      port: 80
      targetPort: http
    - name: https                  # 443/tcp  — HTTP/1.1 and HTTP/2
      protocol: TCP
      port: 443
      targetPort: https
    - name: https-quic             # 443/udp  — HTTP/3. Same number, different protocol.
      protocol: UDP
      port: 443
      targetPort: quic
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: edge-gateway-policy
  namespace: edge
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: edge-gateway
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from: []                     # from anywhere: this is the public edge
      ports:
        - protocol: TCP
          port: 80
        - protocol: TCP
          port: 443
        - protocol: UDP
          port: 443
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: 9090
  egress:
    # DNS needs BOTH transports: UDP for normal queries, TCP for large
    # or DNSSEC-signed responses. Allowing only UDP is a classic outage.
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: backend-api
      ports:
        - protocol: TCP
          port: 8443
    # NTP to the datacentre time servers only
    - to:
        - ipBlock:
            cidr: 198.51.100.0/26
      ports:
        - protocol: UDP
          port: 123
    # Public egress, minus every RFC 1918 and special-purpose range
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
              - 169.254.0.0/16     # blocks cloud metadata SSRF
              - 100.64.0.0/10
      ports:
        - protocol: TCP
          port: 443
```

### 6.6 Ansible — assert the address plan instead of trusting it

```yaml
---
# playbooks/verify-network-contract.yml
# ansible-playbook -i inventories/dc1 playbooks/verify-network-contract.yml
- name: Verify the layer-3 contract on every datacentre host
  hosts: dc1
  gather_facts: true
  become: false

  vars:
    expected_v4_supernet: "198.51.100.0/24"
    expected_v6_supernet: "2001:db8:42::/48"
    forbidden_overlaps:
      - "10.0.0.0/16"
      - "172.17.0.0/16"
      - "192.168.0.0/16"
    required_listeners:
      - { port: 22,   proto: tcp, name: ssh }
      - { port: 443,  proto: tcp, name: https }
      - { port: 9100, proto: tcp, name: node_exporter }

  tasks:
    - name: Primary IPv4 address must live inside the allocated supernet
      ansible.builtin.assert:
        that:
          - ansible_default_ipv4.address | ansible.utils.ipaddr(expected_v4_supernet)
        fail_msg: >-
          {{ inventory_hostname }} holds {{ ansible_default_ipv4.address }},
          which is outside {{ expected_v4_supernet }}. The address plan is violated.
        success_msg: "{{ ansible_default_ipv4.address }} is inside {{ expected_v4_supernet }}"

    - name: Netmask must match the documented /26
      ansible.builtin.assert:
        that:
          - ansible_default_ipv4.netmask == '255.255.255.192'
        fail_msg: >-
          Mask is {{ ansible_default_ipv4.netmask }}, expected 255.255.255.192 (/26).
          A mask mismatch makes half the segment unreachable in one direction only.

    - name: A global IPv6 address must be present and inside the /48
      ansible.builtin.assert:
        that:
          - ansible_default_ipv6.address is defined
          - ansible_default_ipv6.address | ansible.utils.ipaddr(expected_v6_supernet)
        fail_msg: "No global IPv6 inside {{ expected_v6_supernet }} — dual stack is broken."

    - name: No configured route may overlap a forbidden prefix
      ansible.builtin.command:
        argv: [ip, -json, route, show]
      register: routes
      changed_when: false

    - name: Fail on address-plan collisions
      ansible.builtin.assert:
        that:
          - (routes.stdout | from_json
             | map(attribute='dst') | select('match', '^[0-9]')
             | select('ansible.utils.ipaddr', item) | list | length) == 0
        fail_msg: "Route table overlaps forbidden prefix {{ item }} — collision risk."
      loop: "{{ forbidden_overlaps }}"

    - name: Collect listening sockets
      ansible.builtin.command:
        argv: [ss, -Hltnup]
      register: sockets
      changed_when: false

    - name: Every required listener must be bound
      ansible.builtin.assert:
        that:
          - sockets.stdout is search(':' ~ item.port ~ '\\s')
        fail_msg: "{{ item.name }} is not listening on {{ item.proto }}/{{ item.port }}"
      loop: "{{ required_listeners }}"
      loop_control:
        label: "{{ item.name }} {{ item.proto }}/{{ item.port }}"

    - name: PMTU to the default gateway must be the full 1500
      ansible.builtin.command:
        argv: [ping, -M, do, -s, "1472", -c, "2", -W, "2",
               "{{ ansible_default_ipv4.gateway }}"]
      register: pmtu
      changed_when: false
      failed_when: pmtu.rc != 0
```

```
$ ansible-playbook -i inventories/dc1 playbooks/verify-network-contract.yml

PLAY [Verify the layer-3 contract on every datacentre host] ********************

TASK [Primary IPv4 address must live inside the allocated supernet] ************
ok: [node-01] => {"msg": "198.51.100.23 is inside 198.51.100.0/24"}
ok: [node-02] => {"msg": "198.51.100.24 is inside 198.51.100.0/24"}
fatal: [node-07]: FAILED! => {"msg": "node-07 holds 10.0.0.51, which is outside 198.51.100.0/24. The address plan is violated."}

PLAY RECAP *********************************************************************
node-01   : ok=7    changed=0    unreachable=0    failed=0
node-02   : ok=7    changed=0    unreachable=0    failed=0
node-07   : ok=1    changed=0    unreachable=0    failed=1
```

---

## 7. Verification and failure diagnosis

Work the ladder bottom-up. Never skip a rung: a `curl` failure at rung 6 tells you nothing if rung 2 was already broken.

### 7.1 Rung 1–2 — link and address

```
$ ip -brief link show
lo               UNKNOWN        00:00:00:00:00:00 <LOOPBACK,UP,LOWER_UP>
enp1s0           UP             52:54:00:1a:2b:3c <BROADCAST,MULTICAST,UP,LOWER_UP>
enp2s0           DOWN           52:54:00:1a:2b:3d <BROADCAST,MULTICAST>

$ ip -brief address show
lo               UNKNOWN        127.0.0.1/8 ::1/128
enp1s0           UP             198.51.100.23/26 2001:db8:42:7::23/64 2001:db8:42:7:5054:ff:fe1a:2b3c/64 fe80::5054:ff:fe1a:2b3c/64
enp2s0           DOWN
```

`LOWER_UP` means carrier is present; `UP` alone with no `LOWER_UP` is a cable, SFP or switch-port problem, not a configuration problem.

Full IPv6 detail, including lifetimes and flags:

```
$ ip -6 addr show dev enp1s0
2: enp1s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP qlen 1000
    inet6 2001:db8:42:7::23/64 scope global
       valid_lft forever preferred_lft forever
    inet6 2001:db8:42:7:5054:ff:fe1a:2b3c/64 scope global dynamic mngtmpaddr noprefixroute
       valid_lft 2591923sec preferred_lft 604723sec
    inet6 fe80::5054:ff:fe1a:2b3c/64 scope link noprefixroute
       valid_lft forever preferred_lft forever
```

Read the flags: `dynamic` = learned from an RA, `mngtmpaddr` = temporary addresses may be generated from this prefix, and finite `valid_lft`/`preferred_lft` = it will expire if the RAs stop. A `tentative` flag that never clears, or `dadfailed`, means Duplicate Address Detection found a conflict.

**The 169.254 tell.** If `ip -br a` shows `169.254.x.y/16` on IPv4, DHCP failed — the host self-assigned. Do not debug the application; debug DHCP.

### 7.2 Rung 3 — routing and next hop

```
$ ip route show
default via 198.51.100.1 dev enp1s0 proto static metric 100
10.183.64.0/20 via 198.51.100.2 dev enp1s0 proto static metric 200
198.51.100.0/26 dev enp1s0 proto kernel scope link src 198.51.100.23 metric 100

$ ip -6 route show
2001:db8:42:7::/64 dev enp1s0 proto ra metric 100 pref medium
fe80::/64 dev enp1s0 proto kernel metric 256 pref medium
default via fe80::1 dev enp1s0 proto ra metric 100 expires 1723sec pref medium
```

Note the IPv6 default: the next hop is a **link-local** address, and it `expires`. If the RAs stop, the default route disappears and the host loses IPv6 connectivity with the global address still configured — a state that looks fine in `ip addr` and is completely broken.

Ask the kernel which route and source address it would actually pick — this settles arguments faster than reading tables:

```
$ ip route get 203.0.113.10
203.0.113.10 via 198.51.100.1 dev enp1s0 src 198.51.100.23 uid 1000
    cache

$ ip route get 2606:4700:4700::1111
2606:4700:4700::1111 via fe80::1 dev enp1s0 src 2001:db8:42:7:5054:ff:fe1a:2b3c metric 100 pref medium

$ ip route get 10.183.64.5
10.183.64.5 via 198.51.100.2 dev enp1s0 src 198.51.100.23 uid 1000
    cache
```

The `src` field is the RFC 6724 source-address selection result — it is why a firewall on the far side sometimes sees a different address than you expect.

Neighbour tables (ARP for IPv4, NDP for IPv6):

```
$ ip neigh show
198.51.100.1 dev enp1s0 lladdr 00:1a:2b:3c:4d:5e REACHABLE
198.51.100.2 dev enp1s0 lladdr 00:1a:2b:3c:4d:5f STALE
198.51.100.40 dev enp1s0  FAILED

$ ip -6 neigh show
fe80::1 dev enp1s0 lladdr 00:1a:2b:3c:4d:5e router REACHABLE
2001:db8:42:7::5 dev enp1s0 lladdr 00:1a:2b:3c:4d:60 STALE
```

`FAILED` means the address did not answer ARP/NS — the host is off, or you are on the wrong VLAN. `INCOMPLETE` means resolution is in progress. `router` on an IPv6 entry marks the neighbour as an advertising router.

### 7.3 Rung 4 — reachability, ICMP, and the path

```
$ ping -c 4 198.51.100.1
PING 198.51.100.1 (198.51.100.1) 56(84) bytes of data.
64 bytes from 198.51.100.1: icmp_seq=1 ttl=64 time=0.387 ms
64 bytes from 198.51.100.1: icmp_seq=2 ttl=64 time=0.402 ms
64 bytes from 198.51.100.1: icmp_seq=3 ttl=64 time=0.361 ms
64 bytes from 198.51.100.1: icmp_seq=4 ttl=64 time=0.398 ms

--- 198.51.100.1 ping statistics ---
4 packets transmitted, 4 received, 0% packet loss, time 3054ms
rtt min/avg/max/mdev = 0.361/0.387/0.402/0.016 ms
```

The returned **TTL** is a fingerprint of hop count: Linux starts at 64, Windows at 128, many network devices at 255. A reply with `ttl=57` from a Linux host means seven routers in between.

```
$ ping -6 -c 3 2001:db8:42:7::5
PING 2001:db8:42:7::5 (2001:db8:42:7::5) 56 data bytes
64 bytes from 2001:db8:42:7::5: icmp_seq=1 ttl=64 time=0.441 ms
64 bytes from 2001:db8:42:7::5: icmp_seq=2 ttl=64 time=0.398 ms
64 bytes from 2001:db8:42:7::5: icmp_seq=3 ttl=64 time=0.412 ms

--- 2001:db8:42:7::5 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2031ms
rtt min/avg/max/mdev = 0.398/0.417/0.441/0.017 ms
```

Pinging an IPv6 link-local address **requires** the zone index, because `fe80::/10` is ambiguous across interfaces:

```
$ ping -c 2 fe80::1
ping: connect: Invalid argument

$ ping -c 2 fe80::1%enp1s0
PING fe80::1%enp1s0 (fe80::1%enp1s0) 56 data bytes
64 bytes from fe80::1%enp1s0: icmp_seq=1 ttl=64 time=0.372 ms
64 bytes from fe80::1%enp1s0: icmp_seq=2 ttl=64 time=0.351 ms
```

Distinguishing a **drop** from a **reject** is the single most useful ICMP reading:

```
$ ping -c 2 -W 2 198.51.100.99
PING 198.51.100.99 (198.51.100.99) 56(84) bytes of data.

--- 198.51.100.99 ping statistics ---
2 packets transmitted, 0 received, 100% packet loss, time 1023ms
                    ^ silence: a DROP rule, or the host is down

$ ping -c 2 198.51.100.98
PING 198.51.100.98 (198.51.100.98) 56(84) bytes of data.
From 198.51.100.1 icmp_seq=1 Destination Host Unreachable
From 198.51.100.1 icmp_seq=2 Destination Host Unreachable
                    ^ ICMP 3/1: a router answered — L3 works, the target does not
```

Path tracing — three tools, three mechanisms:

```
$ traceroute -n 203.0.113.10
traceroute to 203.0.113.10 (203.0.113.10), 30 hops max, 60 byte packets
 1  198.51.100.1  0.412 ms  0.398 ms  0.441 ms
 2  198.51.100.254  1.204 ms  1.187 ms  1.233 ms
 3  * * *
 4  198.18.7.9  8.331 ms  8.402 ms  8.298 ms
 5  203.0.113.1  12.118 ms  12.204 ms  12.087 ms
 6  203.0.113.10  12.331 ms  12.298 ms  12.402 ms
```

`* * *` is a hop that does not send ICMP Time Exceeded (or rate-limits it). It is **not** a broken hop — traffic still passes through. Only a `* * *` that continues to the destination indicates a real break.

```
$ mtr -rwc 20 -n 203.0.113.10
Start: 2026-08-27T10:14:02+0000
HOST: node-01                     Loss%   Snt   Last   Avg  Best  Wrst StDev
  1.|-- 198.51.100.1               0.0%    20    0.4   0.4   0.3   0.6   0.1
  2.|-- 198.51.100.254             0.0%    20    1.2   1.2   1.1   1.5   0.1
  3.|-- ???                       100.0%    20    0.0   0.0   0.0   0.0   0.0
  4.|-- 198.18.7.9                 0.0%    20    8.3   8.4   8.2   9.1   0.2
  5.|-- 203.0.113.1                5.0%    20   12.1  12.3  12.0  14.8   0.6
  6.|-- 203.0.113.10               0.0%    20   12.3  12.4  12.2  13.1   0.2
```

Read `mtr` correctly: loss at an intermediate hop that **does not persist to the destination** is ICMP rate-limiting on that router's control plane, not packet loss. Only loss that continues to the final line is real.

### 7.4 Rung 5 — the Path MTU black hole, diagnosed

Force the DF bit and walk the size down. The `-s` value is the **payload**; add 28 bytes (20 IP + 8 ICMP) for the wire size:

```
$ ping -M do -s 1472 -c 2 203.0.113.10
PING 203.0.113.10 (203.0.113.10) 1472(1500) bytes of data.
From 198.51.100.254 icmp_seq=1 Frag needed and DF set (mtu = 1400)
From 198.51.100.254 icmp_seq=2 Frag needed and DF set (mtu = 1400)

--- 203.0.113.10 ping statistics ---
0 packets transmitted, 0 received, +2 errors

$ ping -M do -s 1372 -c 2 203.0.113.10
PING 203.0.113.10 (203.0.113.10) 1372(1400) bytes of data.
1380 bytes from 203.0.113.10: icmp_seq=1 ttl=58 time=12.4 ms
1380 bytes from 203.0.113.10: icmp_seq=2 ttl=58 time=12.3 ms
```

That is the **good** case: the router told you. The black hole is when it does not:

```
$ ping -M do -s 1472 -c 3 -W 2 203.0.113.20
PING 203.0.113.20 (203.0.113.20) 1472(1500) bytes of data.

--- 203.0.113.20 ping statistics ---
3 packets transmitted, 0 received, 100% packet loss, time 2045ms

$ ping -M do -s 1372 -c 3 203.0.113.20
PING 203.0.113.20 (203.0.113.20) 1372(1400) bytes of data.
1380 bytes from 203.0.113.20: icmp_seq=1 ttl=57 time=14.1 ms
...
--- 203.0.113.20 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss
```

Small works, large is silent, and no ICMP arrives: somebody is filtering type 3 code 4. `tracepath` maps the whole path's MTU without needing root:

```
$ tracepath -n 203.0.113.20
 1?: [LOCALHOST]                      pmtu 1500
 1:  198.51.100.1                                          0.412ms
 1:  198.51.100.1                                          0.387ms
 2:  198.51.100.254                                        1.204ms
 3:  198.18.7.1                                            4.118ms pmtu 1400
 3:  198.18.7.9                                            8.331ms
 4:  203.0.113.1                                          12.118ms
 5:  203.0.113.20                                         14.102ms reached
     Resume: pmtu 1400 hops 5 back 5
```

And confirm what the kernel cached for that destination:

```
$ ip route get 203.0.113.20
203.0.113.20 via 198.51.100.1 dev enp1s0 src 198.51.100.23 uid 1000
    cache expires 597sec mtu 1400
```

Remediations, in order: fix the filtering device (correct); enable `net.ipv4.tcp_mtu_probing=1` so TCP probes downward instead of hanging (good mitigation); clamp MSS at the tunnel edge with the `nft` rule in §6.4 (necessary on any tunnel); lower the interface MTU (blunt, last resort).

### 7.5 Rung 6 — sockets, ports, and listeners

```
$ ss -tulnp
Netid State  Recv-Q Send-Q   Local Address:Port    Peer Address:Port Process
udp   UNCONN 0      0        127.0.0.53%lo:53           0.0.0.0:*     users:(("systemd-resolve",pid=712,fd=13))
udp   UNCONN 0      0              0.0.0.0:123          0.0.0.0:*     users:(("chronyd",pid=804,fd=5))
udp   UNCONN 0      0                 [::]:123             [::]:*     users:(("chronyd",pid=804,fd=6))
udp   UNCONN 0      0              0.0.0.0:161          0.0.0.0:*     users:(("snmpd",pid=901,fd=7))
tcp   LISTEN 0      4096     127.0.0.53%lo:53           0.0.0.0:*     users:(("systemd-resolve",pid=712,fd=14))
tcp   LISTEN 0      128            0.0.0.0:22           0.0.0.0:*     users:(("sshd",pid=1043,fd=3))
tcp   LISTEN 0      128               [::]:22              [::]:*     users:(("sshd",pid=1043,fd=4))
tcp   LISTEN 0      511                  *:80                 *:*     users:(("nginx",pid=1580,fd=6),("nginx",pid=1579,fd=6))
tcp   LISTEN 0      511                  *:443                *:*     users:(("nginx",pid=1580,fd=7),("nginx",pid=1579,fd=7))
tcp   LISTEN 0      4096         127.0.0.1:5432         0.0.0.0:*     users:(("postgres",pid=1201,fd=5))
```

Everything you need is in that output:

- `postgres` is on `127.0.0.1:5432` — **local only**. Every remote connection will fail regardless of firewall rules. This is the single most common "the firewall is blocking us" false report.
- `sshd` has two rows (`0.0.0.0` and `[::]`) — two separate sockets, because `net.ipv6.bindv6only` or the daemon's config split them.
- `nginx` shows `*:443` with two worker PIDs sharing the socket via `SO_REUSEPORT`.
- `Send-Q` on a `LISTEN` row is the **accept-queue limit** (the effective `listen()` backlog). `Recv-Q` is how many completed connections are waiting for `accept()`. A persistently non-zero `Recv-Q` on a LISTEN socket means the application is not accepting fast enough — that is an application problem, and raising `somaxconn` only postpones it.

Connection-state census, and the TCP internals of a live flow:

```
$ ss -s
Total: 428
TCP:   1284 (estab 312, closed 894, orphaned 4, timewait 891)

Transport Total     IP        IPv6
RAW	  1         0         1
UDP	  8         5         3
TCP	  390       341       49
INET	  399       346       53
FRAG	  0         0         0

$ ss -tan state time-wait | wc -l
892

$ ss -tin dst 203.0.113.10
State  Recv-Q Send-Q      Local Address:Port    Peer Address:Port
ESTAB  0      0          198.51.100.23:51234   203.0.113.10:443
	 cubic wscale:7,9 rto:212 rtt:11.847/0.523 ato:40 mss:1360 pmtu:1400
	 rcvmss:1360 advmss:1448 cwnd:24 bytes_sent:184320 bytes_acked:184320
	 bytes_received:1048576 segs_out:143 segs_in:812 data_segs_out:128
	 data_segs_in:790 send 22.0Mbps lastsnd:12 lastrcv:8 pacing_rate 44.1Mbps
	 delivery_rate 18.7Mbps delivered:129 busy:1408ms rcv_space:14480
	 rcv_ssthresh:64088 minrtt:11.204
```

`mss:1360` against `advmss:1448` is the MSS-clamp from §6.4 doing its job; `pmtu:1400` confirms the discovered path MTU. A non-zero `retrans:` field would indicate real loss.

Counters that expose accept-queue and SYN-flood behaviour:

```
$ nstat -az | grep -E 'ListenOverflows|ListenDrops|SyncookiesSent|TCPSynRetrans|OutNoRoutes'
TcpExtSyncookiesSent            0                  0.0
TcpExtListenOverflows           14872              0.0
TcpExtListenDrops               14872              0.0
TcpExtTCPSynRetrans             203                0.0
IpExtOutNoRoutes                0                  0.0
```

`ListenOverflows` climbing means completed connections are being discarded because the accept queue is full — clients see the handshake succeed then the connection reset or stall.

Prove a port is open, without `nmap`:

```
$ nc -zv 203.0.113.10 443
Connection to 203.0.113.10 443 port [tcp/https] succeeded!

$ nc -zv 203.0.113.10 25
nc: connect to 203.0.113.10 port 25 (tcp) failed: Connection timed out
                                              ^ DROP: the packet vanished

$ nc -zv 203.0.113.10 8080
nc: connect to 203.0.113.10 port 8080 (tcp) failed: Connection refused
                                              ^ RST: reachable, nothing listening

$ nc -zvu 198.51.100.5 123
Connection to 198.51.100.5 123 port [udp/ntp] succeeded!
```

> **UDP caveat.** `nc -zu` reports "succeeded" whenever no ICMP port-unreachable came back within the timeout. Because a firewall that drops ICMP produces exactly the same result as an open port, UDP checks must be made with a protocol-aware client (`dig`, `chronyc`, `snmpwalk`) — never with a bare port probe.

Protocol-aware verification of the ports in §5.2:

```
$ dig +short @198.51.100.5 www.example.net A
203.0.113.10

$ dig +tcp @198.51.100.5 example.net SOA +noall +answer
example.net.  3600  IN  SOA  ns1.example.net. hostmaster.example.net. 2026082701 7200 3600 1209600 3600

$ chronyc -n sources
MS Name/IP address         Stratum Poll Reach LastRx Last sample
===============================================================================
^* 198.51.100.5                  2   6   377    41   -132us[ -148us] +/-   11ms
^+ 198.51.100.6                  2   6   377    38   +204us[ +204us] +/-   13ms

$ openssl s_client -connect mail.example.net:993 -servername mail.example.net -brief
CONNECTION ESTABLISHED
Protocol version: TLSv1.3
Ciphersuite: TLS_AES_256_GCM_SHA384
Peer certificate: CN = mail.example.net
Verification: OK

$ ldapsearch -x -H ldaps://ldap.example.net:636 -b '' -s base namingContexts
# extended LDIF
#
dn:
namingContexts: dc=example,dc=net

# numResponses: 2
```

Which address family did the connection actually use? Happy Eyeballs hides this:

```
$ curl -sS -o /dev/null -w 'family=%{remote_ip}  http=%{http_version}  connect=%{time_connect}s  total=%{time_total}s\n' https://www.example.net/
family=2001:db8:42:100::10  http=3  connect=0.014s  total=0.089s

$ curl -4 -sS -o /dev/null -w 'family=%{remote_ip}  total=%{time_total}s\n' https://www.example.net/
family=203.0.113.10  total=0.093s

$ curl -6 -sS -o /dev/null -w 'family=%{remote_ip}  total=%{time_total}s\n' https://www.example.net/
family=2001:db8:42:100::10  total=0.088s
```

If `-6` hangs while the unforced call succeeds instantly, IPv6 is broken and Happy Eyeballs has been masking it.

### 7.6 Rung 7 — packet capture, the ground truth

```
$ sudo tcpdump -ni enp1s0 -c 6 'tcp port 443 and host 203.0.113.10'
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on enp1s0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
10:14:02.118934 IP 198.51.100.23.51234 > 203.0.113.10.443: Flags [S], seq 1829384756, win 64240, options [mss 1460,sackOK,TS val 3921847 ecr 0,nop,wscale 7], length 0
10:14:02.130712 IP 203.0.113.10.443 > 198.51.100.23.51234: Flags [S.], seq 2938475610, ack 1829384757, win 65535, options [mss 1400,sackOK,TS val 118293 ecr 3921847,nop,wscale 9], length 0
10:14:02.130791 IP 198.51.100.23.51234 > 203.0.113.10.443: Flags [.], ack 1, win 502, options [nop,nop,TS val 3921859 ecr 118293], length 0
10:14:02.131044 IP 198.51.100.23.51234 > 203.0.113.10.443: Flags [P.], seq 1:518, ack 1, win 502, options [nop,nop,TS val 3921859 ecr 118293], length 517
10:14:02.143201 IP 203.0.113.10.443 > 198.51.100.23.51234: Flags [.], ack 518, win 130, options [nop,nop,TS val 118305 ecr 3921859], length 0
10:14:02.144877 IP 203.0.113.10.443 > 198.51.100.23.51234: Flags [P.], seq 1:3841, ack 518, win 130, options [nop,nop,TS val 118305 ecr 3921859], length 3840
6 packets captured
```

Flag notation: `[S]` SYN, `[S.]` SYN+ACK (the dot is ACK), `[.]` bare ACK, `[P.]` PSH+ACK (data), `[F.]` FIN+ACK, `[R]` RST. The peer advertised `mss 1400`, which is where the clamped MSS in §7.5 came from.

A rejected connection looks like this — one SYN, one RST, no retries:

```
$ sudo tcpdump -ni enp1s0 -c 2 'tcp port 8080 and host 203.0.113.10'
10:15:31.204118 IP 198.51.100.23.51288 > 203.0.113.10.8080: Flags [S], seq 3821094, win 64240, options [mss 1460,sackOK,TS val 4011203 ecr 0,nop,wscale 7], length 0
10:15:31.216402 IP 203.0.113.10.8080 > 198.51.100.23.51288: Flags [R.], seq 1, ack 3821095, win 0, length 0
```

A **dropped** connection looks entirely different — repeated SYNs with exponential backoff and no answer at all:

```
$ sudo tcpdump -ni enp1s0 'tcp port 25 and host 203.0.113.10'
10:16:02.118934 IP 198.51.100.23.51301 > 203.0.113.10.25: Flags [S], seq 918273, win 64240, length 0
10:16:03.134201 IP 198.51.100.23.51301 > 203.0.113.10.25: Flags [S], seq 918273, win 64240, length 0
10:16:05.166113 IP 198.51.100.23.51301 > 203.0.113.10.25: Flags [S], seq 918273, win 64240, length 0
10:16:09.230447 IP 198.51.100.23.51301 > 203.0.113.10.25: Flags [S], seq 918273, win 64240, length 0
```

Watching ICMP and DNS specifically:

```
$ sudo tcpdump -ni enp1s0 -v 'icmp or icmp6'
10:17:41.887201 IP (tos 0x0, ttl 63, id 0, offset 0, flags [none], proto ICMP (1), length 576)
    198.51.100.254 > 198.51.100.23: ICMP 203.0.113.20 unreachable - need to frag (mtu 1400), length 556
10:17:44.102338 IP6 (hlim 64, next-header ICMPv6 (58) payload length: 24)
    fe80::1 > ff02::1: [icmp6 sum ok] ICMP6, router advertisement, length 24
	hop limit 64, Flags [other stateful], pref medium, router lifetime 1800s, reachable time 0ms, retrans timer 0ms

$ sudo tcpdump -ni enp1s0 -c 2 'udp port 53'
10:18:03.441028 IP 198.51.100.23.44192 > 198.51.100.5.53: 32918+ [1au] A? www.example.net. (56)
10:18:03.443881 IP 198.51.100.5.53 > 198.51.100.23.44192: 32918 1/0/1 A 203.0.113.10 (74)
```

Neighbor Discovery in action — this is what a firewall that blocks ICMPv6 destroys:

```
$ sudo tcpdump -ni enp1s0 -c 4 'icmp6 and ip6[40] >= 133 and ip6[40] <= 137'
10:19:12.114208 IP6 fe80::5054:ff:fe1a:2b3c > ff02::1:ff00:5: ICMP6, neighbor solicitation, who has 2001:db8:42:7::5, length 32
10:19:12.114887 IP6 fe80::20c:29ff:fe4d:1a60 > fe80::5054:ff:fe1a:2b3c: ICMP6, neighbor advertisement, tgt is 2001:db8:42:7::5, length 32
10:19:14.220114 IP6 fe80::5054:ff:fe1a:2b3c > ff02::2: ICMP6, router solicitation, length 16
10:19:14.221008 IP6 fe80::1 > ff02::1: ICMP6, router advertisement, length 88
```

Note the destination of the first packet: `ff02::1:ff00:5` — the **solicited-node multicast group** derived from the last 24 bits of the target, exactly as computed in §3.3. Only the one host that owns that address processes the frame; in IPv4, every host on the segment would have been interrupted by the ARP broadcast.

### 7.7 Failure catalogue

| Symptom | Most likely cause | Command that confirms it | Fix |
|---|---|---|---|
| `169.254.x.y` on the interface | DHCP failed; host self-assigned | `ip -br a`; `journalctl -u systemd-networkd -n 50` | Fix DHCP reachability or configure statically |
| Local subnet reachable, everything else is not | No default route | `ip route show \| grep ^default` | `ip route add default via <gw>` / fix Netplan |
| Ping to gateway fails, others on the VLAN respond | Mask mismatch — the peer thinks you are off-net | `ipcalc <ip>/<mask>` on both ends | Align the prefix on host *and* switch/router |
| Handshake works, transfer hangs at ~1 kB | PMTU black hole (ICMP 3/4 filtered) | `ping -M do -s 1472`; `tracepath -n` | Unblock ICMP; `tcp_mtu_probing=1`; MSS clamp |
| `Connection refused` | Nothing listening, or bound to `127.0.0.1` | `ss -tlnp \| grep :<port>` | Bind to the right address; start the service |
| `Connection timed out` | Silent DROP, or wrong route | `tcpdump` shows SYN with no reply | Firewall rule; verify with `ip route get` |
| Thousands of `CLOSE_WAIT` | The **application** never calls `close()` | `ss -tan state close-wait \| wc -l` | Fix the app / leaked file descriptors; no sysctl helps |
| Thousands of `TIME_WAIT` on a proxy | Normal for the side that closes first | `ss -s` | Enable keep-alive; `tcp_tw_reuse=1`; widen port range |
| `cannot assign requested address` under load | Ephemeral port exhaustion | `sysctl net.ipv4.ip_local_port_range`; `ss -s` | Widen range, add upstream IPs, reuse connections |
| Clients see connect then stall; `ListenOverflows` rising | Accept queue full | `nstat -az \| grep ListenOverflows` | Raise `somaxconn` **and** the app's `listen()` backlog; fix accept loop |
| IPv6 address present, no IPv6 connectivity | RAs stopped; default route expired | `ip -6 route show \| grep default` | Restore RA; check `accept_ra`; verify ICMPv6 is permitted |
| IPv6 address stuck `tentative` / `dadfailed` | Duplicate address on the link | `ip -6 addr show \| grep -E 'tentative\|dadfailed'` | Resolve the conflict; re-add the address |
| IPv6 broken but nobody notices | Happy Eyeballs falls back to IPv4 | `curl -6 -v https://host/` | Fix IPv6; do not disable it |
| DNS works for small answers, fails for DNSSEC | TCP/53 blocked or UDP fragments dropped | `dig +tcp`; `dig +bufsize=1232` | Open TCP/53; cap EDNS0 buffer |
| Site "slower than it should be" over HTTP/3 | UDP/443 not permitted; silent downgrade to HTTP/2 | `curl -w '%{http_version}'` | Allow `udp dport 443` |
| Asymmetric traffic silently dropped | `rp_filter=1` on a multihomed host | `sysctl net.ipv4.conf.all.rp_filter`; `log_martians` output | Set `rp_filter=2` (loose) or fix routing symmetry |
| VPN up, half the cluster unreachable | Overlapping CIDRs | `ip route get <pod-ip>` shows the tunnel | Renumber; the address plan is the real fix |
| `ss` shows a service name you do not expect | `/etc/services` mapping, not the real port | `ss -tln -n` | Always use `-n` when reading ports |

---

## 8. Exam-focused summary

- **CIDR is arithmetic, not lookup.** Usable hosts = 2^(32−prefix) − 2, with `/31` and `/32` as the documented exceptions. Be able to produce network, first host, last host and broadcast from any address/prefix pair without a tool.
- **Private ranges**: `10.0.0.0/8`, `172.16.0.0/12` (through `172.31.255.255` — `172.32.x.x` is public), `192.168.0.0/16`. Recognise `169.254.0.0/16` as "DHCP failed" and `127.0.0.0/8` as the whole loopback block.
- **TCP** = connection-oriented, reliable, ordered, flow- and congestion-controlled, unicast only, 20-byte minimum header. **UDP** = connectionless, unreliable, unordered, 8-byte header, supports multicast/broadcast. **ICMP** = neither — no ports, control and error signalling for IP itself.
- **ICMP is not optional.** Type 3 code 4 (IPv4) and type 2 (IPv6) carry Path MTU Discovery; ICMPv6 types 133–137 *are* Neighbor Discovery.
- **IPv6**: 128 bits, 40-byte fixed header, **no header checksum**, **no broadcast**, **no router fragmentation**, minimum MTU 1280, `/64` LANs, link-local `fe80::/10` always present, default route only from an RA.
- **`/etc/services`** maps names to `port/protocol`. It documents; it does not open, close or bind anything. Query it with `getent services`; read real port numbers with `ss -n`.
- **Memorise the port table in §5.2 cold.** The pairings that get missed most often: 20/21 FTP data vs. control, 110/995 POP3 vs. POP3S, 143/993 IMAP vs. IMAPS, 389/636 LDAP vs. LDAPS, 161/162 SNMP poll vs. trap, 514 syslog over **UDP**, 465 SMTPS, and 53 over **both** TCP and UDP.

---

## 9. References

**Official LPI certification objectives**

- LPI — Exam 102-500 objectives (Topic 109, where objective 109.1 lives): <https://www.lpi.org/our-certifications/exam-102-objectives/>
- LPI — Exam 101-500 objectives: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- LPI — LPIC-1 certification overview: <https://www.lpi.org/our-certifications/lpic-1-overview/>

**IETF standards**

- RFC 791 — Internet Protocol (IPv4): <https://www.rfc-editor.org/rfc/rfc791.html>
- RFC 792 — Internet Control Message Protocol (ICMP): <https://www.rfc-editor.org/rfc/rfc792.html>
- RFC 768 — User Datagram Protocol: <https://www.rfc-editor.org/rfc/rfc768.html>
- RFC 9293 — Transmission Control Protocol (obsoletes RFC 793): <https://www.rfc-editor.org/rfc/rfc9293.html>
- RFC 1918 — Address Allocation for Private Internets: <https://www.rfc-editor.org/rfc/rfc1918.html>
- RFC 4632 — CIDR: The Internet Address Assignment and Aggregation Plan: <https://www.rfc-editor.org/rfc/rfc4632.html>
- RFC 3021 — Using 31-Bit Prefixes on IPv4 Point-to-Point Links: <https://www.rfc-editor.org/rfc/rfc3021.html>
- RFC 3927 — Dynamic Configuration of IPv4 Link-Local Addresses: <https://www.rfc-editor.org/rfc/rfc3927.html>
- RFC 5737 — IPv4 Address Blocks Reserved for Documentation: <https://www.rfc-editor.org/rfc/rfc5737.html>
- RFC 6598 — IANA-Reserved IPv4 Prefix for Shared Address Space: <https://www.rfc-editor.org/rfc/rfc6598.html>
- RFC 8200 — Internet Protocol, Version 6 (IPv6) Specification: <https://www.rfc-editor.org/rfc/rfc8200.html>
- RFC 4291 — IP Version 6 Addressing Architecture: <https://www.rfc-editor.org/rfc/rfc4291.html>
- RFC 4443 — ICMPv6 for the IPv6 Specification: <https://www.rfc-editor.org/rfc/rfc4443.html>
- RFC 4861 — Neighbor Discovery for IPv6: <https://www.rfc-editor.org/rfc/rfc4861.html>
- RFC 4862 — IPv6 Stateless Address Autoconfiguration (SLAAC): <https://www.rfc-editor.org/rfc/rfc4862.html>
- RFC 4193 — Unique Local IPv6 Unicast Addresses: <https://www.rfc-editor.org/rfc/rfc4193.html>
- RFC 5952 — A Recommendation for IPv6 Address Text Representation: <https://www.rfc-editor.org/rfc/rfc5952.html>
- RFC 6724 — Default Address Selection for IPv6: <https://www.rfc-editor.org/rfc/rfc6724.html>
- RFC 7217 — Semantically Opaque Interface Identifiers (stable-privacy): <https://www.rfc-editor.org/rfc/rfc7217.html>
- RFC 8981 — Temporary Address Extensions for SLAAC: <https://www.rfc-editor.org/rfc/rfc8981.html>
- RFC 8106 — IPv6 RA Options for DNS Configuration: <https://www.rfc-editor.org/rfc/rfc8106.html>
- RFC 8415 — DHCP for IPv6 (DHCPv6): <https://www.rfc-editor.org/rfc/rfc8415.html>
- RFC 4890 — Recommendations for Filtering ICMPv6 Messages in Firewalls: <https://www.rfc-editor.org/rfc/rfc4890.html>
- RFC 1191 — Path MTU Discovery: <https://www.rfc-editor.org/rfc/rfc1191.html>
- RFC 8201 — Path MTU Discovery for IPv6: <https://www.rfc-editor.org/rfc/rfc8201.html>
- RFC 8305 — Happy Eyeballs Version 2: <https://www.rfc-editor.org/rfc/rfc8305.html>
- RFC 9000 — QUIC: A UDP-Based Multiplexed and Secure Transport: <https://www.rfc-editor.org/rfc/rfc9000.html>
- RFC 9114 — HTTP/3: <https://www.rfc-editor.org/rfc/rfc9114.html>
- RFC 8314 — Cleartext Considered Obsolete: TLS for Email Submission and Access: <https://www.rfc-editor.org/rfc/rfc8314.html>
- RFC 6335 — IANA Procedures for Service Name and Transport Protocol Port Number Registry: <https://www.rfc-editor.org/rfc/rfc6335.html>
- RFC 3704 — Ingress Filtering for Multihomed Networks: <https://www.rfc-editor.org/rfc/rfc3704.html>

**IANA registries**

- Service Name and Transport Protocol Port Number Registry: <https://www.iana.org/assignments/service-names-port-numbers/service-names-port-numbers.xhtml>
- IPv4 Special-Purpose Address Registry: <https://www.iana.org/assignments/iana-ipv4-special-registry/iana-ipv4-special-registry.xhtml>
- IPv6 Special-Purpose Address Registry: <https://www.iana.org/assignments/iana-ipv6-special-registry/iana-ipv6-special-registry.xhtml>
- ICMP Type Numbers: <https://www.iana.org/assignments/icmp-parameters/icmp-parameters.xhtml>
- ICMPv6 Parameters: <https://www.iana.org/assignments/icmpv6-parameters/icmpv6-parameters.xhtml>
- Protocol Numbers: <https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml>

**Linux documentation**

- Kernel networking sysctl reference (`ip-sysctl`): <https://docs.kernel.org/networking/ip-sysctl.html>
- `ip(8)` — iproute2: <https://man7.org/linux/man-pages/man8/ip.8.html>
- `ip-address(8)`: <https://man7.org/linux/man-pages/man8/ip-address.8.html>
- `ip-route(8)`: <https://man7.org/linux/man-pages/man8/ip-route.8.html>
- `ss(8)`: <https://man7.org/linux/man-pages/man8/ss.8.html>
- `services(5)`: <https://man7.org/linux/man-pages/man5/services.5.html>
- `getent(1)`: <https://man7.org/linux/man-pages/man1/getent.1.html>
- `nsswitch.conf(5)`: <https://man7.org/linux/man-pages/man5/nsswitch.conf.5.html>
- `ping(8)`: <https://man7.org/linux/man-pages/man8/ping.8.html>
- `tracepath(8)`: <https://man7.org/linux/man-pages/man8/tracepath.8.html>
- `tcpdump(8)` and `pcap-filter(7)`: <https://www.tcpdump.org/manpages/tcpdump.1.html> · <https://www.tcpdump.org/manpages/pcap-filter.7.html>
- `tcp(7)`, `udp(7)`, `ip(7)`, `ipv6(7)`: <https://man7.org/linux/man-pages/man7/tcp.7.html> · <https://man7.org/linux/man-pages/man7/udp.7.html> · <https://man7.org/linux/man-pages/man7/ip.7.html> · <https://man7.org/linux/man-pages/man7/ipv6.7.html>
- systemd `systemd.network(5)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.network.html>
- `networkctl(1)`: <https://www.freedesktop.org/software/systemd/man/latest/networkctl.html>
- nftables wiki: <https://wiki.nftables.org/wiki-nftables/index.php/Main_Page>
- Netplan reference: <https://netplan.readthedocs.io/en/stable/netplan-yaml/>

**Kubernetes**

- Cluster networking concepts: <https://kubernetes.io/docs/concepts/cluster-administration/networking/>
- IPv4/IPv6 dual-stack: <https://kubernetes.io/docs/concepts/services-networking/dual-stack/>
- Service: <https://kubernetes.io/docs/concepts/services-networking/service/>
- Network Policies: <https://kubernetes.io/docs/concepts/services-networking/network-policies/>
- kubeadm `ClusterConfiguration` (v1beta4): <https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/>