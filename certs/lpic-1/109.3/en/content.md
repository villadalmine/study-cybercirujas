# LPIC-1 · Topic 109.3 — Basic Network Troubleshooting

**Exam:** 102-500 · **Topic block:** 109 Networking Fundamentals · **Version:** 5.0
**Profile:** Principal Platform Architect / Senior SRE

---

## 1. Motivation: the architectural problem

In a production platform, "the network is broken" is almost never a statement about the network. It is a statement about an *unresolved ambiguity*: some request did not complete, and the operator does not yet know **which layer of the stack consumed it**. The same user-visible symptom — a 30-second hang followed by a 504 — is produced by at least seven mutually exclusive root causes:

| Root cause | Layer | Who is responsible | Time-to-detect if you guess |
|---|---|---|---|
| NIC negotiated 100 Mb/s half-duplex on a 10 G port | L1/L2 | Datacenter / cabling | hours |
| ARP cache poisoned by a duplicate IP after a failover | L2 | Orchestrator / IPAM | hours |
| Default route missing on one of three interfaces | L3 | Config management | minutes |
| `rp_filter=1` dropping asymmetrically routed replies | L3 | Kernel tuning | days |
| PMTU blackhole: ICMP `frag-needed` filtered by a firewall | L3/L4 | Security | days |
| `somaxconn` backlog overflow, SYNs silently dropped | L4 | Application | hours |
| `search` domain expansion producing 5 NXDOMAIN round-trips per lookup | L7 | Resolver config | days |

The engineering answer is **not** more tools. It is a *disciplined bisection over the layer stack*, where each command is chosen because it isolates exactly one layer and produces a falsifiable result. That discipline is what LPIC-1 109.3 codifies, and it is identical whether the host is a bare-metal hypervisor, an EC2 instance, or a container sharing a network namespace with a Kubernetes Pod sandbox.

The rule that organises everything below:

> **Never test a layer whose lower layer you have not proven.**
> A `curl` failure tells you nothing until `ip route get` has proven L3 and `ss -lnt` has proven the listener exists.

---

## 2. The bisection model

```
                    ┌───────────────────────────────────┐
                    │  Symptom: request does not complete│
                    └──────────────┬────────────────────┘
                                   │
        ┌──────────────────────────▼──────────────────────────┐
        │ L1/L2  Is the link up and is the peer reachable      │
        │        on the wire?                                  │
        │        ip -s link · ethtool · ip neigh · arping      │
        └──────────────────────────┬──────────────────────────┘
                                   │ proven
        ┌──────────────────────────▼──────────────────────────┐
        │ L3     Do I have an address, and which route/source  │
        │        will the kernel pick for this destination?    │
        │        ip addr · ip route get · ping · traceroute    │
        └──────────────────────────┬──────────────────────────┘
                                   │ proven
        ┌──────────────────────────▼──────────────────────────┐
        │ L4     Is a socket listening, is the handshake       │
        │        completing, is the queue overflowing?         │
        │        ss -tulpn · ss -ti · nc -zv · nstat           │
        └──────────────────────────┬──────────────────────────┘
                                   │ proven
        ┌──────────────────────────▼──────────────────────────┐
        │ L7-name Does the *name* resolve, and through which   │
        │        resolution path (NSS, not just DNS)?          │
        │        getent hosts · resolvectl · dig · host        │
        └──────────────────────────┬──────────────────────────┘
                                   │ proven
        ┌──────────────────────────▼──────────────────────────┐
        │ Ground truth: capture the packets. tcpdump           │
        └─────────────────────────────────────────────────────┘
```

Each downward step is only taken after the step above returns a *positive* result. Each step has a command that produces evidence, not an impression.

---

## 3. Toolchain: `net-tools` versus `iproute2`

The `net-tools` package (`ifconfig`, `route`, `netstat`, `arp`, `iwconfig`) parses `/proc/net/*` text files. It has been unmaintained in most distributions since ~2001, cannot represent multiple addresses per interface correctly, is blind to policy routing, network namespaces, and most modern kernel state. LPIC-1 v5.0 still lists the legacy commands as *deprecated but recognisable*; production runbooks must use `iproute2`.

| Legacy (`net-tools`) | Modern (`iproute2` / other) | Why the legacy tool is wrong |
|---|---|---|
| `ifconfig` | `ip addr` / `ip link` | Shows only the first address per interface; hides secondaries, scopes, and IPv6 lifetime |
| `ifconfig eth0 up` | `ip link set dev eth0 up` | — |
| `route -n` | `ip route show` | Cannot show non-`main` tables, policy rules, or nexthop groups |
| `route add default gw …` | `ip route add default via …` | — |
| `arp -an` | `ip neigh show` | No IPv6 NDP; no state machine (`REACHABLE`/`STALE`/`FAILED`) |
| `netstat -tulpn` | `ss -tulpn` | Reads `/proc` line-by-line; O(n²) on hosts with >10 k sockets, can take minutes |
| `netstat -rn` | `ip route show` | Same table limitation |
| `netstat -i` | `ip -s link` | Fewer counters, no per-queue detail |
| `hostname -i` | `getent hosts $(hostname)` | `hostname -i` resolves via a single lookup and lies on multi-homed hosts |
| `iwconfig` | `iw dev` | Legacy Wireless Extensions API, removed for `cfg80211` drivers |

Performance is not a theoretical point. On a busy ingress node:

```
$ time netstat -tan | wc -l
118472

real    1m47.310s
user    0m9.884s
sys     1m36.021s

$ time ss -tan | wc -l
118468

real    0m0.412s
user    0m0.121s
sys     0m0.288s
```

`ss` uses the `NETLINK_SOCK_DIAG` netlink family and asks the kernel for the socket table in one round trip. This is the difference between a diagnostic tool and an incident amplifier.

---

## 4. Layer 1–2: is the wire real?

### 4.1 Link state and error counters

```
$ ip -s link show dev eth0
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP mode DEFAULT group default qlen 1000
    link/ether 06:3f:1a:9c:2e:44 brd ff:ff:ff:ff:ff:ff
    RX:  bytes packets errors dropped  missed   mcast
    482913772934 391827441      0    1204       0  118293
    TX:  bytes packets errors dropped carrier collsns
    318402993110 288109334      0       0       0       0
```

Read this in a fixed order:

1. **`UP`** — administrative state. Set by you or by the network manager.
2. **`LOWER_UP`** — carrier detected by the driver. *This is the physical link.* `UP` without `LOWER_UP` means unplugged cable, dead SFP, or disabled switch port.
3. **`state UP`** — the operational state (`operstate`), the resolved combination.
4. **`errors`** — CRC/frame errors ⇒ cabling, optics, or duplex mismatch.
5. **`dropped`** on RX ⇒ typically the kernel had no buffer (ring exhaustion) or the packet was for an unjoined multicast group.
6. **`carrier`** on TX ⇒ link flapping during transmission.

A cheaper form when you only need administrative/carrier state:

```
$ cat /sys/class/net/eth0/operstate
up
$ cat /sys/class/net/eth0/carrier
1
```

### 4.2 Negotiation, duplex, and the classic 100 Mb/s trap

```
$ sudo ethtool eth0
Settings for eth0:
	Supported ports: [ FIBRE ]
	Supported link modes:   1000baseT/Full
	                        10000baseT/Full
	Supported pause frame use: Symmetric
	Supports auto-negotiation: Yes
	Advertised link modes:  1000baseT/Full
	                        10000baseT/Full
	Advertised auto-negotiation: Yes
	Speed: 10000Mb/s
	Duplex: Full
	Port: FIBRE
	PHYAD: 0
	Transceiver: internal
	Auto-negotiation: on
	Current message level: 0x00000007 (7)
			       drv probe link
	Link detected: yes
```

`Speed: 100Mb/s` or `Duplex: Half` on a server port is an incident, not a configuration. Half duplex produces late collisions that manifest at L7 as *intermittent, size-dependent* stalls — small responses succeed, large ones do not.

Driver-level statistics expose what `ip -s link` aggregates away:

```
$ sudo ethtool -S eth0 | grep -Ei 'drop|err|miss|no_buf|discard' | grep -v ': 0$'
     rx_missed_errors: 4471
     rx_no_buffer_count: 1204
     tx_deferred_ok: 32
```

`rx_missed_errors` rising is a **receive ring or CPU saturation** problem, not a network problem. The fix is `ethtool -G eth0 rx 4096` or IRQ affinity, not a firewall change.

### 4.3 The neighbour table (ARP / NDP)

```
$ ip neigh show
192.168.178.1 dev eth0 lladdr 3c:37:86:1f:22:9d REACHABLE
192.168.178.42 dev eth0 lladdr 06:3f:1a:9c:2e:44 STALE
192.168.178.77 dev eth0  FAILED
fe80::3e37:86ff:fe1f:229d dev eth0 lladdr 3c:37:86:1f:22:9d router REACHABLE
```

| State | Meaning | Operational reading |
|---|---|---|
| `REACHABLE` | Confirmed within `base_reachable_time` | Healthy |
| `STALE` | Entry valid but unconfirmed | Normal; will be probed on next use |
| `DELAY` / `PROBE` | Actively re-validating | Transient |
| `FAILED` | ARP/NDP resolution got no answer | **L2 unreachable** — wrong VLAN, wrong subnet mask, host down, or port-security drop |
| `INCOMPLETE` | Resolution in progress, no reply yet | Same as above, earlier in the timeline |
| `PERMANENT` | Static entry | Someone pinned it; audit why |

`FAILED` is the single most decisive early signal: it proves the destination is believed to be **on-link** and did not answer at layer 2. That eliminates every routing, firewall, and DNS hypothesis in one command.

Duplicate-IP detection — the failure mode that survives every L3 test because both hosts *are* reachable, alternately:

```
$ sudo arping -D -I eth0 -c 3 192.168.178.42
ARPING 192.168.178.42 from 0.0.0.0 eth0
Unicast reply from 192.168.178.42 [06:3F:1A:9C:2E:44]  0.712ms
Unicast reply from 192.168.178.42 [AA:BB:CC:11:22:33]  0.844ms
Sent 3 probes (3 broadcast(s))
Received 2 response(s)
```

Two distinct MACs for one IP ⇒ duplicate address. Expect ~50 % packet loss and TCP resets that look like a load-balancer bug.

To force revalidation after a failover (the correct action after a VIP moves):

```
$ sudo ip neigh flush dev eth0
$ sudo arping -U -I eth0 -c 3 192.168.178.10      # gratuitous ARP, announce the new owner
```

---

## 5. Layer 3: addressing and routing

### 5.1 Addresses

```
$ ip -brief addr show
lo               UNKNOWN        127.0.0.1/8 ::1/128
eth0             UP             192.168.178.24/24 fe80::43f:1aff:fe9c:2e44/64
eth1             UP             10.20.0.24/16 fe80::43f:1aff:fe9c:2e45/64
cni0             UP             10.42.0.1/24 fe80::e8a3:2fff:fe11:9b02/64
docker0          DOWN           172.17.0.1/16
```

`ip -brief` is the form to use in runbooks: one line per interface, greppable, stable across versions. The full form matters when lifetimes are relevant:

```
$ ip addr show dev eth0
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
    link/ether 06:3f:1a:9c:2e:44 brd ff:ff:ff:ff:ff:ff
    inet 192.168.178.24/24 brd 192.168.178.255 scope global dynamic noprefixroute eth0
       valid_lft 41893sec preferred_lft 41893sec
    inet6 fe80::43f:1aff:fe9c:2e44/64 scope link noprefixroute
       valid_lft forever preferred_lft forever
```

`valid_lft` counting down toward zero on a host that is losing connectivity every ~12 hours is a DHCP renewal failure, and no amount of routing analysis will find it.

**The netmask is the second most common L3 fault.** `/24` where the network is `/22` means the host believes four fifths of its own subnet is off-link and sends that traffic to the gateway — which may or may not hairpin it. Symptom: some peers in "the same subnet" work, others do not, and the working set correlates with the third octet.

### 5.2 Routing, and the only routing command that matters

```
$ ip route show
default via 192.168.178.1 dev eth0 proto dhcp src 192.168.178.24 metric 100
10.20.0.0/16 dev eth1 proto kernel scope link src 10.20.0.24 metric 101
10.42.0.0/24 dev cni0 proto kernel scope link src 10.42.0.1
169.254.0.0/16 dev eth0 scope link metric 1000
192.168.178.0/24 dev eth0 proto kernel scope link src 192.168.178.24 metric 100
```

Reading a routing table by eye is an error-prone simulation of longest-prefix match combined with metric comparison combined with policy rules. Do not do it. Ask the kernel:

```
$ ip route get 10.42.7.19
10.42.7.19 dev cni0 src 10.42.0.1 uid 1000
    cache

$ ip route get 8.8.8.8
8.8.8.8 via 192.168.178.1 dev eth0 src 192.168.178.24 uid 1000
    cache

$ ip route get 10.99.0.5
RTNETLINK answers: Network is unreachable
```

`ip route get` is the highest-value command in this entire topic. It returns the **exact** egress interface, nexthop, and — critically — the **source address** the kernel will stamp on the packet. Wrong source address is the cause of the majority of "asymmetric routing" incidents: the reply comes back on a different interface, and `rp_filter` eats it.

To check whether policy routing is redirecting your traffic:

```
$ ip rule show
0:	from all lookup local
32764:	from all fwmark 0x2000/0x2000 lookup 200
32765:	from 10.20.0.24 lookup vpn
32766:	from all lookup main
32767:	from all lookup default

$ ip route show table vpn
default via 10.20.0.1 dev eth1
```

Multi-homed hosts, WireGuard, Cilium, Calico, and any service mesh with transparent redirection install rules here. `ip route show` alone shows only `main` and will confidently mislead you.

### 5.3 Reverse-path filtering

```
$ sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.eth1.rp_filter
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.eth1.rp_filter = 1
```

| Value | Behaviour | When it breaks production |
|---|---|---|
| `0` | No check | Never; but permits spoofing |
| `1` | **Strict** (RFC 3704): drop if the reverse route for the source does not use the *same* interface | Any asymmetric path — dual-homed servers, DSR load balancers, VRRP, multi-NIC Kubernetes nodes |
| `2` | **Loose**: drop only if the source is unreachable via *any* interface | Safe default for multi-homed hosts |

The kernel takes `max(all, <iface>)`, so setting `net.ipv4.conf.eth1.rp_filter=2` alone does nothing while `all` is `1`. Drops are counted, not logged:

```
$ nstat -az | grep -i martian
IpExtInNoRoutes                 0                  0.0
IpReversePathFilter             38412              0.0
```

A non-zero, *increasing* `IpReversePathFilter` is proof, not inference.

### 5.4 Reachability: `ping`

```
$ ping -c 4 -i 0.2 192.168.178.1
PING 192.168.178.1 (192.168.178.1) 56(84) bytes of data.
64 bytes from 192.168.178.1: icmp_seq=1 ttl=64 time=0.681 ms
64 bytes from 192.168.178.1: icmp_seq=2 ttl=64 time=0.594 ms
64 bytes from 192.168.178.1: icmp_seq=3 ttl=64 time=0.612 ms
64 bytes from 192.168.178.1: icmp_seq=4 ttl=64 time=0.577 ms

--- 192.168.178.1 ping statistics ---
4 packets transmitted, 4 received, 0% packet loss, time 604ms
rtt min/avg/max/mdev = 0.577/0.616/0.681/0.039 ms
```

Options that carry diagnostic weight:

| Option | Purpose | Diagnostic use |
|---|---|---|
| `-c N` | Stop after N | Never run unbounded `ping` in a script |
| `-i S` | Interval (sub-second needs root) | Sampling rate for loss estimation |
| `-W S` | Per-reply timeout | Distinguish "slow" from "lost" |
| `-I <if\|addr>` | Force source interface/address | **Prove multi-homing behaviour** |
| `-s N` | Payload size | MTU probing (see §7) |
| `-M do` | Set DF, never fragment | PMTU blackhole detection |
| `-n` | No reverse DNS | Removes a DNS dependency from an L3 test |
| `-f` | Flood | Load-testing only; requires root |
| `-4` / `-6` | Force family | Dual-stack disambiguation |

Interpreting the *error* replies is where the value is:

| Reply | ICMP type/code | Meaning |
|---|---|---|
| `Destination Host Unreachable` **from the source itself** | 3/1 generated locally | ARP failed — L2, on-link |
| `Destination Host Unreachable` **from a router** | 3/1 | The last-hop router could not ARP the target |
| `Destination Net Unreachable` | 3/0 | A router has no route |
| `Destination Port Unreachable` | 3/3 | Only from UDP probes; means the host is alive |
| `Communication prohibited by filter` | 3/13 | An **administrative** firewall reject — you have found the policy |
| `Frag needed and DF set (mtu = 1400)` | 3/4 | PMTU signal; see §7 |
| `Time to live exceeded` | 11/0 | Routing loop |
| Nothing at all | — | Silent `DROP`, or the host is off |

The distinction between **silence** and **`prohibited by filter`** is the distinction between `DROP` and `REJECT` in the firewall. `DROP` is what you will meet in cloud security groups; it is also what makes a firewall problem look like a dead host.

**`ping` failing does not mean unreachable.** ICMP echo is routinely blocked while TCP/443 is open. Never conclude "host down" from `ping` alone — escalate to §6.4.

IPv6 uses the same binary on modern distributions (`ping -6`); `ping6` remains as a compatibility symlink and is what the exam objectives name. Link-local addresses **require** a zone index:

```
$ ping -6 -c 2 fe80::3e37:86ff:fe1f:229d%eth0
PING fe80::3e37:86ff:fe1f:229d%eth0 (fe80::3e37:86ff:fe1f:229d%eth0) 56 data bytes
64 bytes from fe80::3e37:86ff:fe1f:229d%eth0: icmp_seq=1 ttl=64 time=0.489 ms
64 bytes from fe80::3e37:86ff:fe1f:229d%eth0: icmp_seq=2 ttl=64 time=0.451 ms
```

---

## 6. Path and transport

### 6.1 `traceroute`, `tracepath`, `mtr` — choosing the probe

All three exploit TTL expiry: send with TTL=1, collect the ICMP `time exceeded` from hop 1, increment, repeat. They differ in the probe protocol, which determines **what the firewalls in the path will do to them**.

| Tool | Default probe | Root required | PMTU discovery | Continuous | Best for |
|---|---|---|---|---|---|
| `traceroute` | UDP, dst ports 33434+ | No (Linux, unpriv UDP) | No | No | Generic path mapping |
| `traceroute -I` | ICMP echo | Yes (raw socket) | No | No | Paths where UDP is filtered |
| `traceroute -T -p 443` | **TCP SYN** | Yes | No | No | **Paths where only the service port is allowed** |
| `traceroute -U -p 53` | UDP to a chosen port | No | No | No | Targeting a specific UDP service |
| `tracepath` | UDP, unprivileged | **No** | **Yes** | No | MTU blackhole hunting, unprivileged hosts |
| `mtr` | ICMP (`-T` for TCP, `-u` for UDP) | Yes for ICMP | No | **Yes** | **Intermittent loss and jitter** |

```
$ traceroute -n -q 1 -w 2 1.1.1.1
traceroute to 1.1.1.1 (1.1.1.1), 30 hops max, 60 byte packets
 1  192.168.178.1  0.694 ms
 2  100.64.12.1  8.112 ms
 3  10.250.4.9  8.884 ms
 4  * 
 5  62.115.120.14  11.203 ms
 6  62.115.136.207  11.917 ms
 7  1.1.1.1  11.402 ms
```

**Hop 4 showing `*` is almost never the fault.** Routers are permitted to rate-limit or suppress ICMP `time exceeded` while forwarding transit traffic perfectly. The only meaningful reading of a traceroute is:

- Loss that **starts at hop N and persists through the final hop** ⇒ a real problem at or after hop N.
- Loss at hop N that **disappears at hop N+1** ⇒ ICMP rate limiting at hop N. Ignore it.
- The trace **stops entirely** and never reaches the target ⇒ real; the last responding hop is the boundary.
- **Asymmetric latency jumps** are frequently the return path, which traceroute cannot see.

`mtr` is what converts a suspicion into a number, because it keeps probing:

```
$ mtr --report --report-cycles 100 --no-dns 1.1.1.1
Start: 2026-08-27T14:02:11+0000
HOST: ingress-03                  Loss%   Snt   Last   Avg  Best  Wrst StDev
  1.|-- 192.168.178.1              0.0%   100    0.7   0.7   0.6   1.9   0.2
  2.|-- 100.64.12.1                0.0%   100    8.1   8.4   7.9  22.4   1.6
  3.|-- 10.250.4.9                42.0%   100    8.9   9.1   8.6  19.8   1.4
  4.|-- ???                       100.0%   100    0.0   0.0   0.0   0.0   0.0
  5.|-- 62.115.120.14              0.0%   100   11.2  11.6  11.0  28.7   2.1
  6.|-- 62.115.136.207             0.0%   100   11.9  12.1  11.6  24.0   1.3
  7.|-- 1.1.1.1                    0.0%   100   11.4  11.7  11.2  25.9   1.5
```

Textbook reading: hops 3 and 4 show loss, hop 7 shows **0.0 %**. Therefore transit is clean and both are control-plane ICMP rate limiting. No escalation warranted. Had hop 7 shown 42 %, hop 3 would be the boundary to escalate.

### 6.2 `ss` — the socket table

```
$ ss -tulpn
Netid State  Recv-Q Send-Q     Local Address:Port    Peer Address:Port Process
udp   UNCONN 0      0          127.0.0.53%lo:53           0.0.0.0:*     users:(("systemd-resolve",pid=812,fd=13))
udp   UNCONN 0      0                0.0.0.0:68           0.0.0.0:*     users:(("dhclient",pid=1104,fd=7))
tcp   LISTEN 0      4096       127.0.0.53%lo:53           0.0.0.0:*     users:(("systemd-resolve",pid=812,fd=14))
tcp   LISTEN 0      128              0.0.0.0:22           0.0.0.0:*     users:(("sshd",pid=1391,fd=3))
tcp   LISTEN 0      511            127.0.0.1:8080         0.0.0.0:*     users:(("gunicorn",pid=2244,fd=5))
tcp   LISTEN 0      4096                   *:443                *:*     users:(("envoy",pid=3018,fd=41))
```

Flag decomposition: `-t` TCP, `-u` UDP, `-l` listening, `-p` owning process (needs privilege), `-n` numeric, `-a` all, `-4`/`-6` family, `-s` summary, `-i` internal TCP info, `-e` extended, `-m` memory, `-o` timers.

Two readings you must internalise:

1. **`127.0.0.1:8080` versus `0.0.0.0:8080`.** A service bound to loopback is unreachable from any other host, and no firewall change will fix it. This is the single most common "the port is open but I can't connect" cause. `*:443` / `[::]:443` means all addresses, both families (when `net.ipv6.bindv6only=0`).

2. **On a `LISTEN` socket, `Recv-Q` and `Send-Q` do not mean what they mean elsewhere.** `Recv-Q` is the current number of established-but-not-yet-`accept()`ed connections; `Send-Q` is the configured backlog maximum. `Recv-Q` approaching `Send-Q` means the application is not calling `accept()` fast enough and the kernel is dropping SYNs — which the client experiences as an unexplained connection timeout.

```
$ ss -lnt 'sport = :8080'
State  Recv-Q Send-Q  Local Address:Port  Peer Address:Port
LISTEN 511    511         127.0.0.1:8080        0.0.0.0:*
```

Confirm the drops instead of guessing:

```
$ nstat -az | grep -E 'ListenDrops|ListenOverflows|SynRetrans'
TcpExtListenOverflows           14822              0.0
TcpExtListenDrops               14822              0.0
TcpExtTCPSynRetrans             983                0.0
```

`ListenOverflows` == `ListenDrops` and both climbing ⇒ backlog exhaustion, definitively. The fix is `net.core.somaxconn` **and** the application's `listen()` backlog argument — raising only the sysctl changes nothing.

Summary and state filtering:

```
$ ss -s
Total: 1892
TCP:   1204 (estab 618, closed 402, orphaned 3, timewait 398)

Transport Total     IP        IPv6
RAW	  1         0         1
UDP	  14        9         5
TCP	  802       688       114
INET	  817       697       120
FRAG	  0         0         0

$ ss -tan state time-wait | wc -l
399

$ ss -tan state syn-sent
State   Recv-Q Send-Q  Local Address:Port    Peer Address:Port
SYN-SENT 0     1      192.168.178.24:52104   10.20.7.9:5432
```

A socket stuck in `SYN-SENT` is unambiguous: **the SYN left and nothing came back.** That is a firewall silently dropping, a blackhole route, or a dead host — never a TLS, auth, or application problem.

Per-connection transport telemetry, for the "it's slow" class of ticket:

```
$ ss -tin dst 10.20.7.9
State Recv-Q Send-Q    Local Address:Port     Peer Address:Port
ESTAB 0      0        192.168.178.24:52180      10.20.7.9:5432
	 cubic wscale:7,7 rto:236 rtt:34.812/2.104 ato:40 mss:1348 pmtu:1400
	 rcvmss:536 advmss:1448 cwnd:10 ssthresh:7 bytes_sent:184219
	 bytes_retrans:29104 bytes_acked:155115 segs_out:412 segs_in:388
	 send 3.1Mbps lastsnd:12 lastrcv:8 pacing_rate 6.2Mbps
	 delivery_rate 2.9Mbps retrans:0/61 rcv_rtt:36 rcv_space:14480 minrtt:33.9
```

Three fields decide the case: `retrans:0/61` (61 cumulative retransmissions on a short-lived connection = lossy path), `cwnd:10` pinned at the initial window with `ssthresh:7` (congestion control has collapsed), and `mss:1348` against `advmss:1448` (**the path MTU is 1400, not 1500** — proceed to §7).

### 6.3 `netcat` — the transport-layer probe

`nc` establishes whether a TCP handshake completes or a UDP datagram elicits a response, without involving the application protocol. It is the L4 counterpart to `ping`.

```
$ nc -zv -w 3 10.20.7.9 5432
Connection to 10.20.7.9 5432 port [tcp/postgresql] succeeded!

$ nc -zv -w 3 10.20.7.9 6379
nc: connect to 10.20.7.9 port 6379 (tcp) failed: Connection refused

$ nc -zv -w 3 10.20.7.9 9200
nc: connect to 10.20.7.9 port 9200 (tcp) timed out: Operation now in progress
```

The three outcomes are three different root causes and must never be conflated:

| Outcome | Wire event | Root cause | Next action |
|---|---|---|---|
| `succeeded` | SYN → SYN/ACK | L3 + L4 + listener all proven | Move to L7 |
| `Connection refused` (`ECONNREFUSED`) | SYN → RST | **Reached the host**; nothing listening, or a `REJECT` rule | `ss -lnt` on the target |
| `timed out` (`ETIMEDOUT`) | SYN → silence | Firewall `DROP`, blackhole route, wrong host | `tcpdump` on both ends |
| `No route to host` (`EHOSTUNREACH`) | ARP failed / ICMP 3/1 | L2 or last-hop routing | `ip neigh`, §4.3 |
| `Network is unreachable` (`ENETUNREACH`) | No route in FIB | **Local** routing table | `ip route get` |

`Connection refused` is a *good* result during an incident: it proves every layer below the application. Beginners read it as failure; it is the strongest positive signal short of success.

Portable flags: `-z` scan without sending data, `-v` verbose, `-w N` timeout, `-u` UDP, `-l` listen, `-p` source port, `-n` no DNS, `-4`/`-6` family.

Bidirectional path validation — run the listener on the target, the probe on the client:

```
# on 10.20.7.9
$ nc -l 9999
hello from ingress-03

# on the client
$ echo "hello from ingress-03" | nc -N 10.20.7.9 9999
```

This is the definitive test of "is this port allowed end to end", independent of any application.

UDP probing is fundamentally weaker and must be understood as such: with no handshake, `nc -zu` reports success whenever the datagram was *sent*, and only reports failure if an ICMP port-unreachable arrives — which firewalls usually suppress.

```
$ nc -zvu -w 3 10.20.7.9 53
Connection to 10.20.7.9 53 port [udp/domain] succeeded!
```

That output is nearly meaningless for UDP. For a UDP service, probe with the real protocol: `dig @10.20.7.9`, `ntpdate -q`, `snmpget`.

Transferring a file, the canonical `nc` demonstration (receiver first):

```
# receiver
$ nc -l 9000 > payload.tar.gz

# sender
$ nc -N 10.20.7.9 9000 < payload.tar.gz
```

`-N` (openbsd variant) shuts down the socket on EOF; without it the receiver hangs forever waiting for a close. Note the obvious: this is plaintext with no authentication and no integrity check. It is a diagnostic tool, not a transport.

### 6.4 Packet-level ground truth: `tcpdump`

When the layers disagree, capture. `tcpdump` answers "did the packet arrive" and "did anything leave", which no counter can dispute.

```
$ sudo tcpdump -ni eth0 -c 20 'tcp port 5432 and host 10.20.7.9'
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
14:11:02.418822 IP 192.168.178.24.52190 > 10.20.7.9.5432: Flags [S], seq 2841932011, win 62727, options [mss 1460,sackOK,TS val 1029384 ecr 0,nop,wscale 7], length 0
14:11:03.441093 IP 192.168.178.24.52190 > 10.20.7.9.5432: Flags [S], seq 2841932011, win 62727, options [mss 1460,sackOK,TS val 1030407 ecr 0,nop,wscale 7], length 0
14:11:05.489100 IP 192.168.178.24.52190 > 10.20.7.9.5432: Flags [S], seq 2841932011, win 62727, options [mss 1460,sackOK,TS val 1032455 ecr 0,nop,wscale 7], length 0
^C
3 packets captured
```

Three SYNs at 1 s, 2 s, 4 s exponential backoff with no SYN/ACK: the packet left this host. Capture on the *target* to bisect further — if it arrives there, the drop is on the return path or in the target's `INPUT` chain; if it does not, the drop is in transit.

Essential invocation:

| Flag | Effect |
|---|---|
| `-n` | No name resolution (**always** — DNS during a network incident hangs the capture) |
| `-nn` | Also no port-name resolution |
| `-i <if>` / `-i any` | Interface; `any` is a cooked capture across all |
| `-c N` | Stop after N packets |
| `-s0` | Full packet (default snaplen is already 262144 on modern versions) |
| `-w file.pcap` | Write raw, for Wireshark |
| `-r file.pcap` | Read back |
| `-e` | Show Ethernet headers — needed for MAC-level and VLAN questions |
| `-vvv` | Full decode |
| `-A` / `-X` | ASCII / hex payload |
| `-Q in\|out` | Direction filter |

BPF filter idioms worth memorising:

```
'host 10.20.7.9'                          # either direction
'src net 10.42.0.0/16'
'tcp port 443 or tcp port 80'
'tcp[tcpflags] & (tcp-syn|tcp-rst) != 0'  # handshake starts and resets only
'icmp[icmptype] == icmp-unreach'          # every ICMP unreachable, incl. frag-needed
'arp'
'udp port 53'
'vlan and host 10.20.7.9'
'not port 22'                             # never capture your own SSH session
```

Two operational rules: always bound the capture (`-c`, `timeout`, or `-W`/`-G` rotation) — an unbounded `tcpdump -w` on an ingress node fills the root filesystem and turns a network incident into an outage — and always add `not port 22` when capturing on the interface carrying your session, or the capture will record itself recursively.

---

## 7. MTU and the PMTU blackhole

This is the failure mode that defeats every basic test, and it is endemic to overlay networks (VXLAN, IPsec, WireGuard, GRE) — that is, to essentially all container platforms.

Mechanism: TCP negotiates an MSS from the *local* interface MTU. A tunnel later in the path has a smaller MTU. A router sends ICMP type 3 code 4 (`fragmentation needed, DF set`) carrying the correct MTU. If a firewall drops that ICMP, the sender never learns and retransmits the oversized segment forever.

The signature is diagnostic on its own: **the handshake succeeds, small requests succeed, large requests hang.** `ping` works (84 bytes). `nc -z` works (SYN only). `curl` retrieves the headers and then stalls.

| Encapsulation | Overhead | MTU inside a 1500 B path |
|---|---|---|
| None (Ethernet) | 0 | 1500 |
| 802.1Q VLAN | 4 | 1496 |
| PPPoE | 8 | 1492 |
| GRE | 24 | 1476 |
| VXLAN (IPv4) | 50 | 1450 |
| VXLAN (IPv6) | 70 | 1430 |
| WireGuard (IPv4) | 60 | 1440 |
| IPsec ESP (tunnel, AES-GCM) | ~73 | ~1427 |
| VXLAN over an AWS 9001 B jumbo path | 50 | 8951 |

Probing the real path MTU, from the top down. `-M do` sets DF; `-s` is the **payload**, so total IPv4 packet = payload + 8 (ICMP) + 20 (IP):

```
$ ping -M do -s 1472 -c 1 10.20.7.9
PING 10.20.7.9 (10.20.7.9) 1472(1500) bytes of data.
ping: local error: message too long, mtu=1450

$ ping -M do -s 1422 -c 1 10.20.7.9
PING 10.20.7.9 (10.20.7.9) 1422(1450) bytes of data.
1430 bytes from 10.20.7.9: icmp_seq=1 ttl=63 time=1.204 ms

--- 10.20.7.9 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
```

Path MTU = 1450. `tracepath` finds it automatically and identifies the hop where it changes:

```
$ tracepath -n 10.20.7.9
 1?: [LOCALHOST]                      pmtu 1500
 1:  192.168.178.1                     0.712ms
 2:  100.64.12.1                       8.201ms
 3:  10.250.4.9                        8.884ms asymm  4
 3:  10.250.4.9                        8.902ms pmtu 1450
 4:  10.20.7.9                         9.412ms reached
     Resume: pmtu 1450 hops 4 back 4
```

`tracepath` requires no privilege and reports both PMTU and asymmetry — which is why it belongs in the first-response kit ahead of `traceroute`.

Mitigations, in order of correctness:

1. **Fix the ICMP filter.** Allow ICMP type 3 code 4 inbound. Everything else is a workaround.
2. **Set the interface MTU correctly** on the tunnel and on the workloads riding it.
3. **MSS clamping** at the edge — rewrite the MSS option in transiting SYNs:
   ```
   $ sudo nft add rule inet filter forward tcp flags syn tcp option maxseg size set rt mtu
   ```
4. **`tcp_mtu_probing`** — let TCP binary-search the MTU when retransmissions stall:
   ```
   $ sudo sysctl -w net.ipv4.tcp_mtu_probing=1
   ```
   `0` off, `1` enable on ICMP blackhole detection, `2` always on starting from `tcp_base_mss`.

---

## 8. Name resolution: NSS is not DNS

The most persistent conceptual error in this topic is treating `dig` as a test of "does the name resolve". `dig` and `host` speak DNS directly to a server; **applications do not**. Applications call `getaddrinfo(3)`, which consults the Name Service Switch.

| Tool | Path exercised | Reads `/etc/hosts`? | Reads `/etc/nsswitch.conf`? | Uses `systemd-resolved` stub? | Use it to answer |
|---|---|---|---|---|---|
| `getent hosts <name>` | **Full NSS** | Yes | Yes | Yes | *"What will my application get?"* |
| `getent ahostsv4` / `ahostsv6` | Full NSS, family-forced | Yes | Yes | Yes | Dual-stack ordering |
| `resolvectl query <name>` | `systemd-resolved` | Yes | Partially | Yes | Per-link resolver routing |
| `host <name>` | DNS only | **No** | **No** | Via `/etc/resolv.conf` only | *"What does DNS say?"* — quick |
| `dig <name>` | DNS only | **No** | **No** | Via `/etc/resolv.conf` only | Full DNS forensics |
| `nslookup` | DNS only | No | No | Via `/etc/resolv.conf` | Legacy; avoid, output is ambiguous |

**A working `dig` with a failing application is normal and expected** when `nsswitch.conf` is misordered, `/etc/hosts` holds a stale entry, or `systemd-resolved` routes that domain to a different link.

### 8.1 `/etc/nsswitch.conf`

```
$ grep -E '^(hosts|networks):' /etc/nsswitch.conf
hosts:          files mdns4_minimal [NOTFOUND=return] dns myhostname
networks:       files
```

Sources are tried left to right. The action syntax `[STATUS=action]` short-circuits: `[NOTFOUND=return]` after `mdns4_minimal` means an authoritative "no such `.local` name" **stops the lookup and never reaches `dns`**. A host named `printer.local` in an internal DNS zone therefore fails to resolve while `dig printer.local` succeeds — a reproducible, entirely non-obvious incident.

Common modules: `files` (`/etc/hosts`), `dns` (`/etc/resolv.conf`), `myhostname` (own hostname, `localhost`, `_gateway`), `resolve` (`systemd-resolved` via D-Bus), `mymachines` (`systemd-machined` containers), `mdns4_minimal` (Avahi).

### 8.2 `/etc/hosts`

```
$ cat /etc/hosts
127.0.0.1       localhost
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters

192.168.178.24  ingress-03.prod.example.com ingress-03
10.20.7.9       db-primary.prod.example.com db-primary
```

Format: `<address> <canonical-name> [aliases…]`. Checked before DNS wherever `files` precedes `dns`, which is nearly always. That is exactly why a stale `/etc/hosts` entry survives every DNS fix, every TTL expiry, and every cache flush. **Read `/etc/hosts` before believing any DNS hypothesis.**

The FQDN must precede short aliases on the line; several tools take the second field as the canonical name and will return a bare short name for `hostname -f` otherwise.

### 8.3 `/etc/resolv.conf`

```
$ cat /etc/resolv.conf
nameserver 10.20.0.10
nameserver 10.20.0.11
search prod.example.com example.com
options timeout:1 attempts:2 rotate ndots:2 single-request-reopen
```

| Directive | Semantics | Production consequence |
|---|---|---|
| `nameserver` | Up to **3** are honoured; extras silently ignored | Listing five gives you three |
| `search` | Suffixes appended to short names | Each miss is a full round trip |
| `domain` | Single suffix; **mutually exclusive** with `search` (last one wins) | Legacy; use `search` |
| `options ndots:N` | Names with ≥ N dots are tried absolute first | The Kubernetes latency classic |
| `options timeout:N` | Seconds per server (default 5) | Default means a dead resolver costs 5 s |
| `options attempts:N` | Rounds over the whole list (default 2) | Worst case = `timeout × attempts × servers` |
| `options rotate` | Round-robin instead of strictly-in-order | Distributes load; hides a dead first server |
| `options single-request-reopen` | Separate sockets for the A and AAAA queries | Works around broken middleboxes that drop one of a parallel pair |

The failover arithmetic matters: with the defaults and three nameservers, a first-server outage costs `5 s × 2 attempts` before the second is tried. Applications time out long before the resolver gives up. `timeout:1 attempts:2` is the correct production setting.

`ndots:5` — the Kubernetes default — means `api.example.com` (2 dots < 5) is treated as relative and tried against **every** `search` entry first. With four search domains that is 8 wasted queries (A + AAAA each) before the correct absolute lookup. Visible immediately:

```
$ dig +short +search api.example.com > /dev/null
$ sudo tcpdump -ni any -c 12 'udp port 53'
14:22:31.100 IP 10.42.0.7.41522 > 10.43.0.10.53: 1+ A? api.example.com.default.svc.cluster.local. (59)
14:22:31.100 IP 10.42.0.7.41522 > 10.43.0.10.53: 2+ AAAA? api.example.com.default.svc.cluster.local. (59)
14:22:31.101 IP 10.43.0.10.53 > 10.42.0.7.41522: 1 NXDomain 0/1/0 (152)
14:22:31.101 IP 10.43.0.10.53 > 10.42.0.7.41522: 2 NXDomain 0/1/0 (152)
14:22:31.102 IP 10.42.0.7.41529 > 10.43.0.10.53: 3+ A? api.example.com.svc.cluster.local. (51)
...
```

The trailing dot — `dig api.example.com.` — makes the name absolute and skips search expansion entirely. That is the fix, applied in the application's configuration.

**`/etc/resolv.conf` is generated on most modern systems.** Editing it directly is overwritten on the next DHCP lease or link change:

```
$ ls -l /etc/resolv.conf
lrwxrwxrwx 1 root root 39 Jun  2 09:11 /etc/resolv.conf -> ../run/systemd/resolve/stub-resolv.conf
```

A symlink into `/run/systemd/` means the authority is `systemd-resolved`; edit the unit or the NetworkManager profile, never the file.

### 8.4 `systemd-resolved`

```
$ resolvectl status
Global
       Protocols: LLMNR=resolve -mDNS -DNSOverTLS DNSSEC=no/unsupported
resolv.conf mode: stub

Link 2 (eth0)
    Current Scopes: DNS LLMNR/IPv4
         Protocols: +DefaultRoute +LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
Current DNS Server: 10.20.0.10
       DNS Servers: 10.20.0.10 10.20.0.11
        DNS Domain: prod.example.com

Link 3 (wg0)
    Current Scopes: DNS
         Protocols: -DefaultRoute -LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
Current DNS Server: 10.99.0.53
       DNS Servers: 10.99.0.53
        DNS Domain: ~corp.internal
```

`~corp.internal` is a **routing-only domain**: queries for `*.corp.internal` go exclusively to the VPN resolver; everything else goes to `eth0`'s. `-DefaultRoute` on `wg0` prevents it from receiving unrelated queries. This split-horizon behaviour is invisible to `dig`, which talks to `127.0.0.53` and sees only the merged result — another reason `dig` alone cannot clear a resolution incident on a systemd host.

```
$ resolvectl query db-primary.prod.example.com
db-primary.prod.example.com: 10.20.7.9                        -- link: eth0

-- Information acquired via protocol DNS in 4.1ms.
-- Data is authenticated: no; Data was acquired via local or encrypted transport: no
-- Data from: network

$ resolvectl statistics
DNSSEC Verdicts
Secure: 0    Insecure: 0    Bogus: 0    Indeterminate: 0

Transactions
Current Transactions: 0
  Total Transactions: 84129

Cache
  Current Cache Size: 412
          Cache Hits: 71204
        Cache Misses: 12925

$ sudo resolvectl flush-caches
```

A high hit ratio with users reporting stale records means the cache is honouring a long TTL; flush and fix the zone TTL.

### 8.5 `host` and `dig`

```
$ host db-primary.prod.example.com
db-primary.prod.example.com has address 10.20.7.9

$ host -t MX example.com
example.com mail is handled by 10 mail1.example.com.
example.com mail is handled by 20 mail2.example.com.

$ host 10.20.7.9
9.7.20.10.in-addr.arpa domain name pointer db-primary.prod.example.com.

$ host -v -t NS example.com 10.20.0.11        # query a specific server
```

`dig` for anything requiring evidence:

```
$ dig db-primary.prod.example.com

; <<>> DiG 9.18.24 <<>> db-primary.prod.example.com
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 41207
;; flags: qr rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 1232
;; QUESTION SECTION:
;db-primary.prod.example.com.	IN	A

;; ANSWER SECTION:
db-primary.prod.example.com. 300 IN	A	10.20.7.9

;; Query time: 4 msec
;; SERVER: 127.0.0.53#53(127.0.0.53) (UDP)
;; WHEN: Thu Aug 27 14:31:02 UTC 2026
;; MSG SIZE  rcvd: 83
```

The header is the forensic payload:

| Field | Reading |
|---|---|
| `status: NOERROR` + `ANSWER: 0` | The name exists but has **no record of that type** — NODATA, not NXDOMAIN |
| `status: NXDOMAIN` | The name does not exist |
| `status: SERVFAIL` | Resolver failure — upstream unreachable or DNSSEC validation failed |
| `status: REFUSED` | The server declines to answer you (ACL) |
| `flags: aa` | Authoritative answer |
| `flags: ra` absent | The server does not offer recursion |
| `flags: tc` | Truncated — the client must retry over TCP |
| `SERVER:` | **Which resolver actually answered** — verify this before anything else |

```
$ dig +short @10.20.0.11 db-primary.prod.example.com A
10.20.7.9

$ dig +trace example.com                 # full delegation chain from the root
$ dig +norecurse @ns1.example.com example.com    # is this server authoritative?
$ dig +tcp example.com                   # force TCP — proves 53/tcp is open
$ dig -x 10.20.7.9 +short                # reverse
$ dig SOA prod.example.com +short        # serial: are the secondaries in sync?
```

Confirming the NSS-vs-DNS split in two commands:

```
$ dig +short db-primary.prod.example.com
10.20.7.9
$ getent hosts db-primary.prod.example.com
10.20.99.99     db-primary.prod.example.com
```

Different answers ⇒ the divergence is in `/etc/hosts` or `nsswitch.conf`, and DNS is not the problem.

### 8.6 `hostname` and the supporting files

```
$ hostname
ingress-03
$ hostname -f
ingress-03.prod.example.com
$ hostname -d
prod.example.com
$ hostname -I
192.168.178.24 10.20.0.24 10.42.0.1
$ hostnamectl status
 Static hostname: ingress-03
       Icon name: computer-vm
         Chassis: vm
      Machine ID: 4a1f9c2e88b64f0d9a7b3e1c5d2f8a06
         Boot ID: 9e2c17a4b3d84f1e8c5a0b6d7f3e2914
  Virtualization: kvm
Operating System: Debian GNU/Linux 12 (bookworm)
          Kernel: Linux 6.1.0-18-amd64
    Architecture: x86-64
```

`hostname -f` requires that the FQDN be resolvable — through `/etc/hosts` or DNS. If it returns the short name, `/etc/hosts` has the fields in the wrong order. Set the hostname persistently with `hostnamectl set-hostname`, never with `hostname` alone (which is lost at reboot) and never by editing `/etc/hostname` without also updating `/etc/hosts`.

`hostname -i` is a trap on multi-homed hosts: it returns whatever a single lookup produces, often `127.0.1.1`. `hostname -I` (capital) reads the interfaces directly and is correct.

Two remaining files from the objectives:

```
$ grep -E '^(https|postgres|domain)' /etc/services
domain          53/tcp
domain          53/udp
https           443/tcp
https           443/udp
postgresql      5432/tcp   postgres
postgresql      5432/udp   postgres

$ cat /etc/networks
default         0.0.0.0
loopback        127.0.0.0
link-local      169.254.0.0
prod-backend    10.20.0.0
```

`/etc/services` is what makes `ss` print `[tcp/postgresql]` and what `nc -z` uses for symbolic port names. `/etc/networks` maps names to network addresses for `route`/`netstat`; it is largely vestigial and is a frequent cause of confusing `netstat -r` output when it contains stale entries.

---

## 9. Complete, deployable configurations

### 9.1 Netplan (Ubuntu) — dual-homed host with policy routing and explicit MTU

`/etc/netplan/01-prod.yaml`

```yaml
# Dual-homed ingress node.
#   eth0 -> public/edge network, holds the default route
#   eth1 -> backend network, reached only via table 200 to avoid asymmetry
# Applied with:  sudo netplan generate && sudo netplan apply
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      match:
        macaddress: "06:3f:1a:9c:2e:44"
      set-name: eth0
      addresses:
        - 192.168.178.24/24
        - "2001:db8:178::24/64"
      routes:
        - to: default
          via: 192.168.178.1
          metric: 100
          on-link: false
        - to: "::/0"
          via: "2001:db8:178::1"
          metric: 100
      nameservers:
        search:
          - prod.example.com
          - example.com
        addresses:
          - 10.20.0.10
          - 10.20.0.11
      mtu: 1500
      accept-ra: false
      dhcp4: false
      dhcp6: false
      optional: false

    eth1:
      match:
        macaddress: "06:3f:1a:9c:2e:45"
      set-name: eth1
      addresses:
        - 10.20.0.24/16
      mtu: 9000
      dhcp4: false
      dhcp6: false
      accept-ra: false
      # Backend traffic must leave and return on eth1. Without these two
      # stanzas, replies to backend-initiated flows would follow the eth0
      # default route and be discarded by rp_filter on the far side.
      routing-policy:
        - from: 10.20.0.24/32
          table: 200
          priority: 32765
      routes:
        - to: 10.20.0.0/16
          scope: link
          table: 200
        - to: default
          via: 10.20.0.1
          table: 200
          metric: 100
```

Verification after apply — never trust `netplan apply` output alone:

```
$ sudo netplan generate && sudo netplan apply
$ ip -brief addr show
$ ip rule show
0:	from all lookup local
32765:	from 10.20.0.24 lookup 200
32766:	from all lookup main
32767:	from all lookup default
$ ip route show table 200
default via 10.20.0.1 dev eth1 metric 100
10.20.0.0/16 dev eth1 scope link
$ ip route get 10.20.7.9 from 10.20.0.24
10.20.7.9 from 10.20.0.24 dev eth1 table 200 uid 0
    cache
```

### 9.2 `systemd-networkd` — the same host without Netplan

`/etc/systemd/network/10-eth0.network`

```ini
[Match]
MACAddress=06:3f:1a:9c:2e:44

[Link]
MTUBytes=1500
RequiredForOnline=routable

[Network]
Address=192.168.178.24/24
Address=2001:db8:178::24/64
DNS=10.20.0.10
DNS=10.20.0.11
Domains=prod.example.com example.com
IPv6AcceptRA=no
LinkLocalAddressing=ipv6
IPForward=no

[Route]
Gateway=192.168.178.1
Destination=0.0.0.0/0
Metric=100

[Route]
Gateway=2001:db8:178::1
Destination=::/0
Metric=100
```

`/etc/systemd/network/20-eth1.network`

```ini
[Match]
MACAddress=06:3f:1a:9c:2e:45

[Link]
MTUBytes=9000
RequiredForOnline=routable

[Network]
Address=10.20.0.24/16
IPv6AcceptRA=no
LinkLocalAddressing=no

[Route]
Destination=10.20.0.0/16
Scope=link
Table=200

[Route]
Gateway=10.20.0.1
Destination=0.0.0.0/0
Table=200
Metric=100

[RoutingPolicyRule]
From=10.20.0.24/32
Table=200
Priority=32765
```

```
$ sudo systemctl restart systemd-networkd
$ networkctl status eth1
● 3: eth1
                   Link File: /usr/lib/systemd/network/99-default.link
                Network File: /etc/systemd/network/20-eth1.network
                       State: routable (configured)
                Online state: online
                        Type: ether
                        Path: pci-0000:00:06.0
                      Driver: virtio_net
                      Vendor: Red Hat, Inc.
                       Model: Virtio network device
                  HW Address: 06:3f:1a:9c:2e:45
                         MTU: 9000 (min: 68, max: 65535)
                       QDisc: mq
Number of Queues (Tx/Rx): 4/4
                     Address: 10.20.0.24
```

`State: routable (configured)` is the assertion to check. `degraded` means the link is up but has no routable address; `configuring` means it never converged.

### 9.3 NetworkManager keyfile — RHEL/Fedora equivalent

`/etc/NetworkManager/system-connections/backend-eth1.nmconnection` (mode `0600`, or NM refuses to load it)

```ini
[connection]
id=backend-eth1
uuid=8f2c1a94-6b3d-4e7f-9a02-1c5d8e3b7f40
type=ethernet
interface-name=eth1
autoconnect=true
autoconnect-priority=10

[ethernet]
mtu=9000

[ipv4]
method=manual
address1=10.20.0.24/16
# never-default: this profile must not install a default route in table main
never-default=true
dns-priority=200
route-table=200
route1=0.0.0.0/0,10.20.0.1
route1_options=table=200
routing-rule1=priority 32765 from 10.20.0.24/32 table 200
may-fail=false

[ipv6]
method=disabled

[proxy]
```

```
$ sudo chmod 600 /etc/NetworkManager/system-connections/backend-eth1.nmconnection
$ sudo nmcli connection reload
$ sudo nmcli connection up backend-eth1
Connection successfully activated (D-Bus active path: /org/freedesktop/NetworkManager/ActiveConnection/7)
$ nmcli -f IP4.ADDRESS,IP4.GATEWAY,IP4.ROUTE,GENERAL.STATE connection show backend-eth1
IP4.ADDRESS[1]:                         10.20.0.24/16
IP4.GATEWAY:                            --
IP4.ROUTE[1]:                           dst = 0.0.0.0/0, nh = 10.20.0.1, mt = 0, table=200
GENERAL.STATE:                          activated
$ nmcli device status
DEVICE  TYPE      STATE                   CONNECTION
eth0    ethernet  connected               edge-eth0
eth1    ethernet  connected               backend-eth1
lo      loopback  connected (externally)  lo
```

### 9.4 `nftables` — a ruleset that does not create blackholes

`/etc/nftables.conf`

```
#!/usr/sbin/nft -f
# Diagnostic-safe host firewall.
# Design rules:
#   1. ICMP frag-needed (type 3 code 4) is ALWAYS accepted -> no PMTU blackhole.
#   2. Echo request is rate-limited, not dropped -> ping stays usable.
#   3. Denied TCP is REJECTed with tcp-reset on trusted networks, so operators
#      get ECONNREFUSED (fast, diagnosable) instead of a 130 s timeout.
#   4. Counters on every terminal rule, so `nft list ruleset` is evidence.

flush ruleset

table inet filter {
    set trusted_v4 {
        type ipv4_addr
        flags interval
        elements = { 10.20.0.0/16, 192.168.178.0/24 }
    }

    chain input {
        type filter hook input priority filter; policy drop;

        iif lo accept comment "loopback"

        ct state established,related accept
        ct state invalid counter drop comment "malformed / out-of-window"

        # --- ICMPv4: never break path MTU discovery ---
        ip protocol icmp icmp type destination-unreachable accept \
            comment "includes type 3 code 4 frag-needed - required for PMTUD"
        ip protocol icmp icmp type time-exceeded accept comment "traceroute replies"
        ip protocol icmp icmp type parameter-problem accept
        ip protocol icmp icmp type echo-request limit rate 10/second burst 20 packets accept
        ip protocol icmp icmp type echo-reply accept

        # --- ICMPv6: mandatory, IPv6 does not work without it ---
        icmpv6 type { destination-unreachable, packet-too-big, time-exceeded,
                      parameter-problem, echo-request, echo-reply } accept
        icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert,
                      nd-router-solicit, nd-router-advert } ip6 hoplimit 255 accept

        # --- services ---
        tcp dport 22 ip saddr @trusted_v4 ct state new limit rate 6/minute burst 10 packets \
            counter accept comment "ssh, brute-force limited"
        tcp dport { 80, 443 } ct state new counter accept
        tcp dport 5432 ip saddr @trusted_v4 ct state new counter accept

        udp dport 68 accept comment "dhcp client"

        # Trusted networks get an explicit reject: fast failure beats a timeout.
        ip saddr @trusted_v4 tcp flags syn counter reject with tcp reset
        ip saddr @trusted_v4 counter reject with icmp type admin-prohibited

        # Everything else is dropped silently, with a sampled log for forensics.
        limit rate 5/minute burst 10 packets log prefix "nft-input-drop: " level info
        counter drop
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state established,related accept
        # Clamp MSS to the real path MTU: protects tunnels from oversized segments
        # even when an upstream device eats the frag-needed ICMP.
        tcp flags syn tcp option maxseg size set rt mtu
        iifname "cni0" oifname "eth0" counter accept
        iifname "eth0" oifname "cni0" ct state established,related counter accept
        counter drop
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
```

```
$ sudo nft -c -f /etc/nftables.conf && echo "syntax OK"
syntax OK
$ sudo systemctl enable --now nftables
$ sudo nft list ruleset | grep -A2 'dport 5432'
		tcp dport 5432 ip saddr @trusted_v4 ct state new counter packets 8412 bytes 504720 accept
$ sudo nft list counters
table inet filter {
	...
}
```

The counters are the point. `counter packets 0` on the rule you believe is allowing traffic proves the packets never reached that rule — usually because an earlier rule matched, or because they never arrived at all.

### 9.5 Ansible — an idempotent verification play

`playbooks/network-verify.yml`

```yaml
---
# Fleet-wide L1->L7 assertion sweep. Read-only: changes nothing, fails loudly.
#   ansible-playbook -i inventory/prod playbooks/network-verify.yml
- name: Verify host network health from link to name resolution
  hosts: prod_linux
  gather_facts: true
  become: false
  vars:
    expected_mtu: 1500
    expected_default_gw: "192.168.178.1"
    required_resolvers:
      - "10.20.0.10"
      - "10.20.0.11"
    reachability_targets:
      - { host: "10.20.7.9", port: 5432, name: "postgres-primary" }
      - { host: "10.20.0.10", port: 53, name: "dns-primary" }
      - { host: "10.43.0.1", port: 443, name: "kube-apiserver" }
    resolve_targets:
      - "db-primary.prod.example.com"
      - "api.prod.example.com"

  tasks:
    - name: L1/L2 - primary interface carrier is up
      ansible.builtin.slurp:
        src: "/sys/class/net/{{ ansible_default_ipv4.interface }}/carrier"
      register: carrier_state

    - name: L1/L2 - assert carrier detected
      ansible.builtin.assert:
        that:
          - (carrier_state.content | b64decode | trim) == "1"
        fail_msg: >-
          No carrier on {{ ansible_default_ipv4.interface }} -
          physical link down (cable, SFP, or switch port).
        success_msg: "carrier OK on {{ ansible_default_ipv4.interface }}"

    - name: L1/L2 - assert MTU matches the design
      ansible.builtin.assert:
        that:
          - ansible_default_ipv4.mtu | int == expected_mtu | int
        fail_msg: >-
          MTU is {{ ansible_default_ipv4.mtu }}, expected {{ expected_mtu }}.
          Mismatched MTU produces size-dependent stalls, not clean failures.

    - name: L3 - assert the default gateway is the designed one
      ansible.builtin.assert:
        that:
          - ansible_default_ipv4.gateway == expected_default_gw
        fail_msg: >-
          Default gateway is {{ ansible_default_ipv4.gateway | default('ABSENT') }},
          expected {{ expected_default_gw }}.

    - name: L3 - resolve the egress decision for each target
      ansible.builtin.command:
        argv: ["ip", "route", "get", "{{ item.host }}"]
      loop: "{{ reachability_targets }}"
      loop_control:
        label: "{{ item.name }}"
      register: route_get
      changed_when: false
      failed_when: route_get.rc != 0

    - name: L3 - report the chosen source address and interface
      ansible.builtin.debug:
        msg: "{{ item.item.name }} -> {{ item.stdout_lines[0] }}"
      loop: "{{ route_get.results }}"
      loop_control:
        label: "{{ item.item.name }}"

    - name: L3 - reverse path filter must not be strict on multi-homed hosts
      ansible.builtin.command:
        argv: ["sysctl", "-n", "net.ipv4.conf.all.rp_filter"]
      register: rp_filter
      changed_when: false

    - name: L3 - assert rp_filter is loose or off when more than one NIC is routed
      ansible.builtin.assert:
        that:
          - (ansible_interfaces | reject('match', '^(lo|docker|veth|cni)') | list | length) < 2
            or rp_filter.stdout | int != 1
        fail_msg: >-
          rp_filter=1 (strict) on a multi-homed host. Asymmetric replies will be
          dropped silently; check `nstat -az IpReversePathFilter`.

    - name: L4 - TCP handshake must complete for every dependency
      ansible.builtin.wait_for:
        host: "{{ item.host }}"
        port: "{{ item.port }}"
        timeout: 5
        state: started
      loop: "{{ reachability_targets }}"
      loop_control:
        label: "{{ item.name }} ({{ item.host }}:{{ item.port }})"

    - name: L4 - listen backlog must not be saturated
      ansible.builtin.shell:
        cmd: >-
          set -o pipefail;
          ss -lnt | awk 'NR>1 && $2 > ($3 * 0.8) {print $0}'
        executable: /bin/bash
      register: backlog
      changed_when: false
      failed_when: false

    - name: L4 - assert no listener is above 80 percent of its backlog
      ansible.builtin.assert:
        that:
          - backlog.stdout | length == 0
        fail_msg: >-
          Listener accept queue near capacity; SYNs are being dropped:
          {{ backlog.stdout }}

    - name: L7 - names must resolve through the full NSS path, not just DNS
      ansible.builtin.command:
        argv: ["getent", "hosts", "{{ item }}"]
      loop: "{{ resolve_targets }}"
      register: nss_lookup
      changed_when: false
      failed_when: nss_lookup.rc != 0

    - name: L7 - every configured resolver must answer independently
      ansible.builtin.command:
        argv: ["dig", "+short", "+time=2", "+tries=1", "@{{ item.0 }}", "{{ item.1 }}"]
      loop: "{{ required_resolvers | product(resolve_targets) | list }}"
      loop_control:
        label: "{{ item.0 }} <- {{ item.1 }}"
      register: per_resolver
      changed_when: false
      failed_when: per_resolver.stdout | trim | length == 0

    - name: L7 - resolv.conf must not use the 5 second default timeout
      ansible.builtin.command:
        argv: ["grep", "-E", "^options .*timeout:[1-2]([^0-9]|$)", "/etc/resolv.conf"]
      register: resolv_timeout
      changed_when: false
      failed_when: resolv_timeout.rc != 0
```

```
$ ansible-playbook -i inventory/prod playbooks/network-verify.yml

PLAY [Verify host network health from link to name resolution] *****************

TASK [L1/L2 - assert carrier detected] *****************************************
ok: [ingress-03] => {"changed": false, "msg": "carrier OK on eth0"}

TASK [L3 - report the chosen source address and interface] *********************
ok: [ingress-03] => (item=postgres-primary) => {
    "msg": "postgres-primary -> 10.20.7.9 dev eth1 src 10.20.0.24 uid 0"
}

TASK [L3 - assert rp_filter is loose or off when more than one NIC is routed] ***
fatal: [ingress-07]: FAILED! => {"assertion": "...", "changed": false,
  "evaluated_to": false, "msg": "rp_filter=1 (strict) on a multi-homed host.
  Asymmetric replies will be dropped silently; check `nstat -az IpReversePathFilter`."}

PLAY RECAP *********************************************************************
ingress-03   : ok=12   changed=0    unreachable=0    failed=0
ingress-07   : ok=5    changed=0    unreachable=0    failed=1
```

### 9.6 The same primitives inside a container network namespace

Everything above is namespace-local. A Pod that "cannot reach the database" is a host with its own interfaces, routes, `resolv.conf`, and socket table — none of which are visible from the node's default namespace.

`manifests/netshoot-debug.yaml`

```yaml
---
apiVersion: v1
kind: Pod
metadata:
  name: netshoot-debug
  namespace: prod
  labels:
    app.kubernetes.io/name: netshoot-debug
    app.kubernetes.io/component: diagnostics
  annotations:
    kubernetes.io/description: >-
      Ephemeral L1-L7 diagnostic shell. Delete after use; NET_RAW and NET_ADMIN
      are granted only so tcpdump and ip can operate inside the namespace.
spec:
  # hostNetwork: false is the default and is what you want first: diagnose the
  # Pod's namespace. Flip to true only to compare against the node's view.
  hostNetwork: false
  dnsPolicy: ClusterFirst
  restartPolicy: Never
  terminationGracePeriodSeconds: 5
  containers:
    - name: netshoot
      image: nicolaka/netshoot:v0.13
      imagePullPolicy: IfNotPresent
      command: ["/bin/bash", "-c", "sleep 3600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: false
        runAsNonRoot: false
        runAsUser: 0
        capabilities:
          drop: ["ALL"]
          add: ["NET_RAW", "NET_ADMIN"]
      resources:
        requests:
          cpu: "50m"
          memory: "64Mi"
        limits:
          cpu: "500m"
          memory: "256Mi"
  tolerations:
    - operator: "Exists"
      effect: "NoSchedule"
```

```
$ kubectl apply -f manifests/netshoot-debug.yaml
pod/netshoot-debug created

$ kubectl exec -n prod netshoot-debug -- ip -brief addr show
lo               UNKNOWN        127.0.0.1/8 ::1/128
eth0@if142       UP             10.42.3.17/32

$ kubectl exec -n prod netshoot-debug -- ip route get 10.20.7.9
10.20.7.9 via 169.254.1.1 dev eth0 src 10.42.3.17 uid 0
    cache

$ kubectl exec -n prod netshoot-debug -- cat /etc/resolv.conf
search prod.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.43.0.10
options ndots:5

$ kubectl exec -n prod netshoot-debug -- getent hosts db-primary.prod.svc.cluster.local
10.43.7.9       db-primary.prod.svc.cluster.local

$ kubectl exec -n prod netshoot-debug -- nc -zv -w3 db-primary.prod.svc.cluster.local 5432
Connection to db-primary.prod.svc.cluster.local (10.43.7.9) 5432 port [tcp/postgresql] succeeded!
```

From the node itself, to enter a container's namespace without any in-container tooling:

```
$ CID=$(sudo crictl ps --name api-server -q | head -1)
$ PID=$(sudo crictl inspect "$CID" | jq -r '.info.pid')
$ sudo nsenter -t "$PID" -n ip -brief addr show
lo               UNKNOWN        127.0.0.1/8 ::1/128
eth0@if211       UP             10.42.3.22/32
$ sudo nsenter -t "$PID" -n ss -tulpn
$ sudo nsenter -t "$PID" -n tcpdump -nni eth0 -c 20 'tcp port 5432'
```

Note that containers do **not** appear in `ip netns list` — that command lists only namespaces bind-mounted under `/var/run/netns`. `nsenter -t <pid> -n` is the correct entry point. To make a container namespace visible to `ip netns`:

```
$ sudo mkdir -p /var/run/netns
$ sudo ln -sf /proc/$PID/ns/net /var/run/netns/api-server
$ sudo ip netns exec api-server ss -tan
```

---

## 10. Verification and failure-diagnosis guide

### 10.1 Symptom → layer → first command

| Symptom | Most probable layer | First command | Decisive evidence |
|---|---|---|---|
| No traffic at all, any destination | L1 | `ip -s link show` | `LOWER_UP` absent |
| Some peers in "the same subnet" work | L3 | `ip addr show` | Wrong prefix length |
| `Network is unreachable` | L3 local | `ip route get <dst>` | No matching FIB entry |
| `No route to host` | L2 | `ip neigh show` | `FAILED` / `INCOMPLETE` |
| `Connection refused` | L4 target | `ss -lnt` on target | Bound to `127.0.0.1` |
| `Connection timed out` | L3/L4 filter | `tcpdump` both ends | SYN leaves, never arrives |
| Handshake OK, large payloads hang | PMTU | `tracepath -n <dst>` | `pmtu` drop mid-path |
| Intermittent loss / jitter | Path | `mtr --report -c 100` | Loss persists to the last hop |
| Works by IP, fails by name | NSS | `getent hosts` vs `dig +short` | Answers differ |
| ~5 s stall before every connect | Resolver | `cat /etc/resolv.conf` | Default `timeout:5`, dead first server |
| Many short-lived requests are slow | `ndots` | `tcpdump -ni any udp port 53` | NXDOMAIN storm from search expansion |
| Connections drop under load only | L4 queue | `nstat -az \| grep Listen` | `ListenOverflows` climbing |
| Traffic works one way only | rp_filter | `nstat -az \| grep -i reverse` | `IpReversePathFilter` climbing |
| Roughly 50 % loss to one host | L2 | `arping -D -I eth0 <ip>` | Two MACs answer |
| Everything broke after a failover | ARP cache | `ip neigh show` | Stale `lladdr` for the VIP |
| Speed capped at ~94 Mb/s | L1 | `ethtool eth0` | `Speed: 100Mb/s` |

### 10.2 The ordered runbook

```bash
#!/usr/bin/env bash
# net-triage.sh <destination-host> [port]
# Read-only L1->L7 bisection. Every step prints the evidence it used.
set -uo pipefail

DST="${1:?usage: net-triage.sh <host> [port]}"
PORT="${2:-443}"
IFACE="$(ip route show default | awk '/default/ {print $5; exit}')"

section() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

section "L1/L2  link state on ${IFACE}"
ip -s link show dev "$IFACE"
[ -r "/sys/class/net/${IFACE}/carrier" ] && \
  echo "carrier=$(cat "/sys/class/net/${IFACE}/carrier")"
command -v ethtool >/dev/null && sudo ethtool "$IFACE" 2>/dev/null | \
  grep -E 'Speed|Duplex|Link detected'

section "L1/L2  neighbour table"
ip neigh show dev "$IFACE"

section "L3  addresses"
ip -brief addr show

section "L3  routing decision for ${DST}"
# Resolve the name first so `ip route get` receives an address, not a name.
DST_IP="$(getent ahostsv4 "$DST" 2>/dev/null | awk 'NR==1{print $1}')"
DST_IP="${DST_IP:-$DST}"
echo "resolved ${DST} -> ${DST_IP}"
ip route get "$DST_IP" || echo "!! no route: check 'ip route show' and 'ip rule show'"
ip rule show

section "L3  reverse path filter"
sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf."${IFACE}".rp_filter
nstat -az 2>/dev/null | grep -Ei 'reversepath|martian|noroutes' || true

section "L3  ICMP reachability (absence proves nothing)"
ping -n -c 3 -W 2 "$DST_IP" || echo "!! no echo reply - ICMP may simply be filtered"

section "L3  path and PMTU"
command -v tracepath >/dev/null && tracepath -n -m 15 "$DST_IP"

section "L4  TCP handshake to ${DST_IP}:${PORT}"
if command -v nc >/dev/null; then
  nc -zv -w 3 "$DST_IP" "$PORT" 2>&1
else
  timeout 3 bash -c "cat < /dev/null > /dev/tcp/${DST_IP}/${PORT}" \
    && echo "open" || echo "closed or filtered"
fi

section "L4  local socket health"
ss -s
ss -tan state syn-sent
nstat -az 2>/dev/null | grep -E 'ListenDrops|ListenOverflows|SynRetrans|RetransSegs' || true

section "L7  name resolution paths"
echo "--- NSS (what the application sees) ---"
getent hosts "$DST" || echo "!! NSS lookup FAILED"
echo "--- nsswitch hosts line ---"
grep -E '^hosts:' /etc/nsswitch.conf
echo "--- /etc/hosts matches ---"
grep -F -- "$DST" /etc/hosts || echo "(none)"
echo "--- resolv.conf ---"
cat /etc/resolv.conf
echo "--- DNS directly ---"
command -v dig >/dev/null && dig +short +time=2 +tries=1 "$DST"
command -v resolvectl >/dev/null && resolvectl query "$DST" 2>&1 | head -5

section "done"
echo "If every layer above passed and the application still fails,"
echo "capture: sudo tcpdump -nni ${IFACE} -c 100 'host ${DST_IP} and port ${PORT}'"
```

```
$ ./net-triage.sh db-primary.prod.example.com 5432

== L1/L2  link state on eth0 ==
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP mode DEFAULT group default qlen 1000
    link/ether 06:3f:1a:9c:2e:44 brd ff:ff:ff:ff:ff:ff
    ...
carrier=1
	Speed: 10000Mb/s
	Duplex: Full
	Link detected: yes

== L3  routing decision for db-primary.prod.example.com ==
resolved db-primary.prod.example.com -> 10.20.7.9
10.20.7.9 via 10.20.0.1 dev eth1 table 200 src 10.20.0.24 uid 1000
    cache

== L4  TCP handshake to 10.20.7.9:5432 ==
Connection to 10.20.7.9 5432 port [tcp/postgresql] succeeded!

== L7  name resolution paths ==
--- NSS (what the application sees) ---
10.20.7.9       db-primary.prod.example.com
```

### 10.3 Two worked failures

**Case A — "the database is down" that was a stale `/etc/hosts` entry.**

```
$ nc -zv -w3 db-primary.prod.example.com 5432
nc: connect to db-primary.prod.example.com port 5432 (tcp) timed out: Operation now in progress

$ dig +short db-primary.prod.example.com
10.20.7.9

$ getent hosts db-primary.prod.example.com
10.20.99.14     db-primary.prod.example.com

$ grep db-primary /etc/hosts
10.20.99.14     db-primary.prod.example.com db-primary

$ nc -zv -w3 10.20.7.9 5432
Connection to 10.20.7.9 5432 port [tcp/postgresql] succeeded!
```

DNS was correct throughout. An `/etc/hosts` entry added during a migration eight months earlier overrode it, because `nsswitch.conf` puts `files` before `dns`. Every DNS-focused investigation would have concluded "DNS is fine" and stopped.

**Case B — successful handshake, hung transfer.**

```
$ curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' https://api.partner.example.com/health
200 0.142

$ curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' https://api.partner.example.com/v1/bulk-export
curl: (28) Operation timed out after 30001 milliseconds with 0 bytes received

$ ping -M do -s 1472 -c1 api.partner.example.com
PING api.partner.example.com (203.0.113.44) 1472(1500) bytes of data.
^C
--- api.partner.example.com ping statistics ---
3 packets transmitted, 0 received, 100% packet loss, time 2043ms

$ ping -M do -s 1372 -c1 api.partner.example.com
PING api.partner.example.com (203.0.113.44) 1372(1400) bytes of data.
1380 bytes from 203.0.113.44: icmp_seq=1 ttl=52 time=41.2 ms

$ ss -tin dst 203.0.113.44 | grep -o 'mss:[0-9]*\|pmtu:[0-9]*\|retrans:[0-9/]*'
mss:1448
pmtu:1500
retrans:0/94
```

The kernel still believes `pmtu:1500` and is advertising `mss:1448` while the real path MTU is 1400 — the `frag-needed` ICMP is being filtered upstream. Small responses fit; the bulk export does not. Immediate mitigation, then the real fix upstream:

```
$ sudo sysctl -w net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_mtu_probing = 1
$ curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' https://api.partner.example.com/v1/bulk-export
200 3.884
```

---

## 11. Exam-focused recall

**Commands (109.3, v5.0):** `ip`, `hostname`, `ss`, `ping`, `ping6`, `traceroute`, `traceroute6`, `tracepath`, `tracepath6`, `netcat`, `ifconfig`, `netstat`, `route`, `mtr`, `host`, `dig`.

**Files:** `/etc/resolv.conf`, `/etc/hosts`, `/etc/nsswitch.conf`, `/etc/services`, `/etc/networks`.

Facts that are examined literally and are easy to lose:

- `/etc/resolv.conf` honours a maximum of **three** `nameserver` lines; defaults are `timeout:5`, `attempts:2`, `ndots:1`.
- `domain` and `search` in `/etc/resolv.conf` are mutually exclusive; the last directive read wins.
- `files` before `dns` in `nsswitch.conf` is why `/etc/hosts` overrides DNS.
- On a `LISTEN` socket, `ss` shows current accept-queue depth in `Recv-Q` and the backlog maximum in `Send-Q`.
- `traceroute` sends **UDP** to high ports by default; `-I` for ICMP, `-T` for TCP; `tracepath` needs no privilege and reports the PMTU.
- `ping -s N` sets the **payload**; the IPv4 packet is `N + 28` bytes.
- `nc -z` scans without sending data; `-w` sets the timeout; `-u` selects UDP; `-l` listens.
- `hostname -I` (capital i) lists all addresses from the interfaces; `hostname -i` performs a lookup and misleads on multi-homed hosts.
- IPv6 link-local addresses require a zone index (`fe80::1%eth0`).
- `ip route get <dst>` reports the interface, nexthop **and source address** the kernel will actually use.

---

## 12. Referencias

**Official certification objectives**

- LPI — Exam 102-500 Objectives (LPIC-1 v5.0), Topic 109.3 *Basic network troubleshooting*: <https://www.lpi.org/our-certifications/exam-102-objectives/>
- LPI — Exam 101-500 Objectives (LPIC-1 v5.0): <https://www.lpi.org/our-certifications/exam-101-objectives/>
- LPI — LPIC-1 Linux Administrator certification overview: <https://www.lpi.org/our-certifications/lpic-1-overview/>

**iproute2 and kernel networking**

- `ip(8)` manual page — iproute2: <https://man7.org/linux/man-pages/man8/ip.8.html>
- `ip-route(8)`: <https://man7.org/linux/man-pages/man8/ip-route.8.html>
- `ip-neighbour(8)`: <https://man7.org/linux/man-pages/man8/ip-neighbour.8.html>
- `ss(8)`: <https://man7.org/linux/man-pages/man8/ss.8.html>
- Linux kernel documentation — IP sysctl parameters (`rp_filter`, `tcp_mtu_probing`, `somaxconn`): <https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html>
- iproute2 project page: <https://wiki.linuxfoundation.org/networking/iproute2>

**Diagnostic tools**

- `ping(8)` — iputils: <https://man7.org/linux/man-pages/man8/ping.8.html>
- `tracepath(8)` — iputils: <https://man7.org/linux/man-pages/man8/tracepath.8.html>
- `traceroute(8)`: <https://man7.org/linux/man-pages/man8/traceroute.8.html>
- iputils project: <https://github.com/iputils/iputils>
- `mtr` — Matt's traceroute: <https://www.bitwizard.nl/mtr/>
- `nc(1)` — OpenBSD netcat: <https://man.openbsd.org/nc.1>
- `tcpdump(1)` and `pcap-filter(7)`: <https://www.tcpdump.org/manpages/tcpdump.1.html> · <https://www.tcpdump.org/manpages/pcap-filter.7.html>
- `ethtool(8)`: <https://man7.org/linux/man-pages/man8/ethtool.8.html>
- `nsenter(1)`: <https://man7.org/linux/man-pages/man1/nsenter.1.html>

**Name resolution**

- `nsswitch.conf(5)`: <https://man7.org/linux/man-pages/man5/nsswitch.conf.5.html>
- `resolv.conf(5)`: <https://man7.org/linux/man-pages/man5/resolv.conf.5.html>
- `hosts(5)`: <https://man7.org/linux/man-pages/man5/hosts.5.html>
- `getaddrinfo(3)`: <https://man7.org/linux/man-pages/man3/getaddrinfo.3.html>
- `systemd-resolved.service(8)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd-resolved.service.html>
- `resolvectl(1)`: <https://www.freedesktop.org/software/systemd/man/latest/resolvectl.html>
- ISC BIND `dig` documentation: <https://bind9.readthedocs.io/en/latest/manpages.html#dig-dns-lookup-utility>

**Configuration frameworks**

- `systemd.network(5)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.network.html>
- `networkctl(1)`: <https://www.freedesktop.org/software/systemd/man/latest/networkctl.html>
- Netplan reference: <https://netplan.readthedocs.io/en/stable/netplan-yaml/>
- NetworkManager `nm-settings-keyfile(5)`: <https://networkmanager.dev/docs/api/latest/nm-settings-keyfile.html>
- `nmcli(1)`: <https://networkmanager.dev/docs/api/latest/nmcli.html>
- nftables wiki: <https://wiki.nftables.org/wiki-nftables/index.php/Main_Page>

**Standards**

- RFC 1122 — Requirements for Internet Hosts, Communication Layers: <https://www.rfc-editor.org/rfc/rfc1122>
- RFC 1191 — Path MTU Discovery: <https://www.rfc-editor.org/rfc/rfc1191>
- RFC 4821 — Packetization Layer Path MTU Discovery: <https://www.rfc-editor.org/rfc/rfc4821>
- RFC 3704 — Ingress Filtering for Multihomed Networks (`rp_filter` semantics): <https://www.rfc-editor.org/rfc/rfc3704>
- RFC 4861 — Neighbor Discovery for IPv6: <https://www.rfc-editor.org/rfc/rfc4861>
- RFC 792 — Internet Control Message Protocol: <https://www.rfc-editor.org/rfc/rfc792>
- RFC 6335 — Service Name and Transport Protocol Port Number Registry: <https://www.rfc-editor.org/rfc/rfc6335>

**Container networking context**

- Kubernetes — Debug Services: <https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/>
- Kubernetes — DNS for Services and Pods: <https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/>
- Kubernetes — Debugging DNS Resolution: <https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/>