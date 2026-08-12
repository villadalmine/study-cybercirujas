# Network High Availability

**LPIC-3 306 — Exam 306-300 (v3.0) · Topic 364.4 · Exam weight ≈ 8.33**

---

## 1. The architectural problem: the network is a stack of single points of failure

A server can be triple-redundant in power, disk (RAID), and CPU, sit inside a Pacemaker failover cluster, and still be *offline* because the one cable feeding its access switch was unplugged, or because the default gateway it points at rebooted. High availability is only ever as strong as the **least redundant hop in the path**, and the network path is where most of the un-redundant hops actually live.

The mistake production teams repeat is scoping HA to the *node* ("we have two app servers") while leaving the *path* to that node singular. Availability is multiplicative along a series path: two 99.9 % nodes behind a single 99.9 % gateway and a single switch yield `0.999³ ≈ 99.7 %` — the redundant compute bought nothing because the failure domain was never the compute.

Map every hop and its failure mode before choosing a tool:

| Layer | Component | Failure mode | Blast radius | Redundancy technique |
|---|---|---|---|---|
| L1 | Cable / SFP / NIC port | Cut, unseated, laser death | One host's uplink | **Link aggregation** (bonding/teaming) across ≥2 NICs |
| L2 | Access / ToR switch | Reboot, PSU, firmware bug | Every host on that switch | Dual-homed bonds to **two** switches (MLAG/vPC) |
| L2→L3 | Default gateway | Router reboot, config push | Every host in the subnet | **VRRP** virtual router (keepalived) |
| L3 | Upstream path / transit | Link flap, BGP withdrawal | A whole prefix | **ECMP + dynamic routing** (OSPF/BGP) |
| L3 | Service front-end IP | LB node down | The service | **Anycast** (/32 advertised from N nodes) |
| L4/L7 | Load balancer | Process crash, kernel panic | All connections through it | **LB pair** + VRRP/conntrackd (see 361.1) |
| — | Connection *state* | Failover resets every TCP flow | Every active session | **conntrackd** state replication |

The recurring lesson: redundancy at layer *N* is worthless if layer *N−1* underneath it is singular. This unit builds the stack bottom-up — link, gateway, path, state — because that is the order a failure propagates and the order you must audit.

Two orthogonal design axes govern every choice below:

- **Failure-detection latency vs. false positives.** Sub-second failover (aggressive `advert_int`, `lacp_rate fast`, BFD) catches real failures quickly but converts every transient blip into a flap. Slow timers are stable but expose users to seconds of blackhole.
- **L2 redundancy vs. L3 redundancy.** L2 (VRRP, bonding) is transparent to clients and needs no routing changes, but it is confined to a single broadcast domain and relies on gratuitous ARP / switch CAM behavior. L3 (ECMP, anycast, BGP) scales across subnets and datacenters and fails over by *routing convergence*, but requires cooperating routers and correct reverse-path handling.

---

## 2. Link-layer redundancy: bonding and teaming

### 2.1 What the kernel bonding driver actually does

The `bonding` driver presents `bondN` as one logical interface over ≥2 physical slaves. Its behavior is entirely determined by **mode** and by the **link monitor** (how it decides a slave is dead).

| Mode | Name | Needs switch config | Load-balances TX | Fault tolerance | Typical use |
|---|---|---|---|---|---|
| 0 | `balance-rr` | LAG (static) | Yes (per-packet) | Yes | Rarely — packet reordering hurts TCP |
| 1 | `active-backup` | **No** | No | Yes | Dual-switch resilience, zero switch cooperation |
| 2 | `balance-xor` | LAG (static) | Yes (hash) | Yes | Static aggregation |
| 3 | `broadcast` | — | No (duplicates) | Yes | Ultra-low-loss niche |
| 4 | `802.3ad` (LACP) | **LAG + LACP** | Yes (hash) | Yes | Standard datacenter aggregation |
| 5 | `balance-tlb` | No | Yes (TX only) | Yes | Switch-agnostic outbound balancing |
| 6 | `balance-alb` | No | Yes (TX+RX) | Yes | Switch-agnostic full balancing (ARP tricks) |

**Two decisions dominate:**

1. **Do you need switch cooperation?** `active-backup` (mode 1) is the only mode that survives a *switch* failure with no switch-side config — plug the two slaves into two independent switches and the bond fails over transparently. `802.3ad` (mode 4) gives you aggregate bandwidth *and* redundancy but requires both slaves on the **same** LACP-capable switch (or an MLAG/vPC pair presenting one logical LACP peer).

2. **How is TX traffic hashed across slaves?** `xmit_hash_policy` decides which flow leaves which slave. `layer2` (MACs only) collapses to one slave when everyone talks through a single router MAC; `layer3+4` (IP + port) spreads flows well but is not strictly 802.3ad-compliant (a fragmented flow can reorder). For a server behind one gateway, use `layer3+4`.

**Link monitoring** is what makes a bond *highly available* rather than merely aggregated:

- `miimon=100` — poll the driver's carrier every 100 ms. Fast, but only detects *local* carrier loss; a dead switch that keeps the light on is invisible.
- `arp_interval` + `arp_ip_target` — actively ARP a known IP; detects end-to-end reachability, not just carrier. Do **not** combine ARP monitoring with 802.3ad.
- `downdelay` / `updelay` — debounce flapping links (wait N ms of stable state before acting).

### 2.2 Bonding — full configuration (NetworkManager / RHEL 9)

```bash
$ sudo nmcli connection add type bond con-name bond0 ifname bond0 \
    ipv4.method manual ipv4.addresses 192.168.10.20/24 ipv4.gateway 192.168.10.1 \
    bond.options "mode=802.3ad,miimon=100,lacp_rate=fast,xmit_hash_policy=layer3+4,updelay=200,downdelay=200"
Connection 'bond0' (7c3e...) successfully added.

$ sudo nmcli connection add type ethernet con-name bond0-p1 ifname enp1s0 master bond0
$ sudo nmcli connection add type ethernet con-name bond0-p2 ifname enp2s0 master bond0

$ sudo nmcli connection up bond0
Connection successfully activated (master waiting for slaves)
```

Verify the aggregation actually negotiated (the single most important check — a bond can come "up" with LACP *not* forming and silently run on one link):

```bash
$ cat /proc/net/bonding/bond0
Ethernet Channel Bonding Driver: v6.9.9

Bonding Mode: IEEE 802.3ad Dynamic link aggregation
Transmit Hash Policy: layer3+4 (1)
MII Status: up
MII Polling Interval (ms): 100
Up Delay (ms): 200
Down Delay (ms): 200

802.3ad info
LACP active: on
LACP rate: fast
Min links: 0
Aggregator selection policy (ad_select): stable
System priority: 65535
System MAC address: 52:54:00:aa:bb:cc
Active Aggregator Info:
        Aggregator ID: 1
        Number of ports: 2
        Actor Key: 15
        Partner Key: 32773
        Partner Mac Address: 00:23:04:ee:be:cf     <-- real switch MAC = LACP formed

Slave Interface: enp1s0
MII Status: up
Speed: 10000 Mbps
Duplex: full
Aggregator ID: 1
Partner Churn State: none       <-- "monitoring" here = LACP not converging
Actor Churned Count: 0

Slave Interface: enp2s0
MII Status: up
Speed: 10000 Mbps
Duplex: full
Aggregator ID: 1                <-- both slaves share Aggregator ID = one LAG. Good.
```

Diagnostic rules of thumb: **Partner MAC = `00:00:00:00:00:00`** or **Churn State ≠ `none`** means the switch side isn't running LACP (no port-channel, or `passive`/`on` mismatch). Two **different Aggregator IDs** means the two slaves landed on two switches that are *not* an MLAG pair — LACP can't span them, so you get two half-bonds instead of one.

### 2.3 Bonding via `systemd-networkd` (immutable / minimal images)

```ini
# /etc/systemd/network/10-bond0.netdev
[NetDev]
Name=bond0
Kind=bond

[Bond]
Mode=802.3ad
TransmitHashPolicy=layer3+4
LACPTransmitRate=fast
MIIMonitorSec=100ms
UpDelaySec=200ms
DownDelaySec=200ms
```

```ini
# /etc/systemd/network/11-bond0-members.network
[Match]
Name=enp1s0 enp2s0

[Network]
Bond=bond0
```

```ini
# /etc/systemd/network/12-bond0.network
[Match]
Name=bond0

[Network]
Address=192.168.10.20/24
Gateway=192.168.10.1
```

```bash
$ sudo networkctl reload
$ networkctl status bond0
● 5: bond0
       State: routable (configured)
        Type: bond
    Hardware: 802.3ad
     Address: 192.168.10.20
     Gateway: 192.168.10.1 (Cisco Systems)
```

### 2.4 Teaming (libteam / `teamd`) — and why it's the losing bet

Network *teaming* implements the same idea in userspace (`teamd`) with a JSON config and pluggable "runners":

```json
// /etc/systemd/network is not used; via NM keyfile team.config or teamd -f
{
  "device": "team0",
  "runner": { "name": "lacp", "active": true, "fast_rate": true,
              "tx_hash": ["eth", "ipv4", "ipv6"] },
  "link_watch": { "name": "ethtool" },
  "ports": { "enp1s0": {}, "enp2s0": {} }
}
```

```bash
$ sudo teamd -g -f /etc/teamd/team0.conf -d
$ sudo teamdctl team0 state
setup:
  runner: lacp
ports:
  enp1s0
    link watches:
      link summary: up
    runner:
      aggregator ID: 5, Selected
      selected: yes
      state: current
  enp2s0
    link watches:
      link summary: up
    runner:
      aggregator ID: 5, Selected
```

| | Bonding (`bonding` driver) | Teaming (`libteam`/`teamd`) |
|---|---|---|
| Location | In-kernel | Userspace daemon + small kernel module |
| Config | sysfs / `bond.options` / netlink | JSON, `teamdctl` runtime API |
| Runners/modes | 7 fixed modes | Pluggable runners (broadcast, roundrobin, activebackup, loadbalance, lacp) |
| LACP tuning | Kernel params | JSON, richer runtime introspection |
| **Vendor direction** | **Preferred / actively maintained** | **Deprecated in RHEL 9+** |

For the exam and for production, **default to bonding.** Teaming's cleaner runtime API never overcame the fact that bonding is in-kernel, universally supported, and the path Red Hat now steers everyone back onto. Know teaming exists and how to read `teamdctl`, but do not build new infrastructure on it.

---

## 3. Gateway redundancy: VRRP with keepalived

### 3.1 VRRP mechanics you must be able to reason about

The **Virtual Router Redundancy Protocol** (RFC 3768 = v2, **RFC 5798** = v3 with IPv6) lets N routers share one **virtual IP (VIP)** and one **virtual MAC** (`00:00:5e:00:01:{VRID}`). Clients point their default route at the VIP and never know which physical box owns it.

- **Election** is by **priority** (0–255). `255` is reserved for the *address owner* (a router whose real interface IP equals the VIP). `100` is the keepalived default. Highest priority wins; ties break on highest primary IP. Priority `0` is a special "I resign" advertisement that triggers *immediate* failover.
- The **MASTER** multicasts VRRP advertisements to `224.0.0.18` (IPv4) / `ff02::12` (IPv6), **IP protocol 112**, every `advert_int` (default 1 s).
- A BACKUP declares the master dead after **Master_Down_Interval = 3 × advert_int + skew**, where `skew = (256 − priority)/256`. Lower priority → longer skew → deterministic, staggered takeover with no thundering herd.
- On promotion, the new master **broadcasts gratuitous ARP** for the VIP so switch CAM tables and client ARP caches relearn the port/MAC. *If those GARPs are dropped, the VIP moves but traffic keeps going to the dead box* — this is the #1 cause of "failover happened but nothing recovered."
- **`preempt` vs `nopreempt`:** by default a higher-priority node that returns *takes back* mastership (one extra outage). `nopreempt` keeps the current master until it actually fails — usually what you want, to avoid a flapping primary bouncing the VIP.
- **VRID (`virtual_router_id`)** must match between peers and be **unique per L2 segment** (two clusters with the same VRID on one VLAN corrupt each other's virtual MACs).
- **Authentication** (`auth_type PASS`) exists **only in VRRPv2**; RFC 5798 removed it. If you set `vrrp_version 3` *and* an `authentication` block, keepalived warns and ignores it — don't rely on it as a security control (it never was; it's an accidental-misconfig guard at best).

### 3.2 keepalived — full MASTER/BACKUP configuration

Both nodes run keepalived; the config is symmetric except `state`, `priority`, and (for unicast) the peer addresses.

```conf
# /etc/keepalived/keepalived.conf  —  NODE lb01 (MASTER)
global_defs {
    router_id lb01
    vrrp_version 3
    enable_script_security          # refuse to run tracking scripts as root if writable by others
    script_user keepalived_script
    vrrp_garp_master_delay 1        # (re)send GARP 1s after taking master, to fight lossy switches
    vrrp_garp_master_refresh 60     # periodic GARP refresh so CAM tables never age out the VIP
}

# Health check: is HAProxy actually alive? If not, shed priority so the peer wins.
vrrp_script chk_haproxy {
    script "/usr/bin/killall -0 haproxy"   # signal 0 = "does the process exist?"
    interval 2                              # run every 2s
    timeout 3
    fall 2                                  # 2 consecutive failures => DOWN
    rise 2                                  # 2 consecutive successes => UP
    weight -40                              # subtract 40 from priority while DOWN
}

vrrp_instance VI_PUBLIC {
    state MASTER
    interface enp3s0
    virtual_router_id 51
    priority 150
    advert_int 1
    nopreempt                               # don't steal mastership back on recovery

    # Cloud / firewalled fabrics block multicast — use unicast VRRP:
    unicast_src_ip 10.0.0.11
    unicast_peer {
        10.0.0.12
    }

    authentication {                        # ignored under vrrp_version 3; kept for v2 fallback
        auth_type PASS
        auth_pass s3cr3t42
    }

    virtual_ipaddress {
        203.0.113.10/24 dev enp3s0
    }
    virtual_routes {
        default via 203.0.113.1 dev enp3s0
    }

    track_script {
        chk_haproxy
    }

    # Effective priority = 150 - 40 = 110 while HAProxy is down; peer at 120 then wins.
    notify_master "/etc/keepalived/notify.sh MASTER"
    notify_backup "/etc/keepalived/notify.sh BACKUP"
    notify_fault  "/etc/keepalived/notify.sh FAULT"
}
```

The BACKUP node is identical except:

```conf
    state BACKUP
    priority 120
    unicast_src_ip 10.0.0.12
    unicast_peer { 10.0.0.11 }
```

> **Design note on `weight`:** the math must guarantee the *right* winner. Master starts at 150; a HAProxy failure drops it to 110, which is below the backup's 120 → clean failover. If you'd set `weight -20`, master would fall only to 130 (still > 120) and the VIP would stay on the box whose service is dead. Always verify: `master_priority + weight < backup_priority`.

Grouping instances so a public VIP and a private VIP fail over **together** (never half-and-half):

```conf
vrrp_sync_group PUBLIC_PRIVATE {
    group {
        VI_PUBLIC
        VI_PRIVATE
    }
    notify_master "/etc/keepalived/promote.sh"
}
```

### 3.3 The notify script — where failover becomes an *action*, not just an IP move

```bash
#!/bin/bash
# /etc/keepalived/notify.sh  — owned by keepalived_script, mode 0750
STATE="$1"
logger -t keepalived-notify "transition to ${STATE}"

case "$STATE" in
  MASTER)
    # Take over the connection-tracking state so established TCP flows survive:
    /usr/sbin/conntrackd -c        # commit external cache into the kernel table
    /usr/sbin/conntrackd -f        # flush internal & external caches
    /usr/sbin/conntrackd -R        # resync internal cache with the kernel
    /usr/sbin/conntrackd -B        # push a bulk update to the peer
    systemctl start haproxy
    ;;
  BACKUP|FAULT)
    /usr/sbin/conntrackd -t        # flush the kernel conntrack table (we no longer own the VIP)
    /usr/sbin/conntrackd -n        # request a resync from the new master
    ;;
esac
```

### 3.4 Stateful failover: conntrackd

Moving a VIP moves *packets*, not *connections*. Without state replication, every established TCP session resets at failover — catastrophic for long-lived flows (database connections, streams, NAT sessions on a firewall). **conntrackd** replicates the kernel conntrack table between the pair so the new master already knows about in-flight connections. It runs in **primary-backup** mode, driven by keepalived's notify hooks above:

```conf
# /etc/conntrackd/conntrackd.conf (primary-backup, unicast)
Sync {
    Mode FTFW { }                       # fault-tolerant, reliable resync
    UDP {
        IPv4_address 10.0.0.11
        IPv4_Destination_Address 10.0.0.12
        Port 3780
        Interface enp1s0
    }
}
General {
    Systemd on
    Filter From Userspace {
        Protocol Accept { TCP UDP ICMP }
        Address Ignore { IPv4_address 127.0.0.1 }
    }
}
```

```bash
$ sudo conntrackd -s
cache internal:   14231 entries
cache external:   14180 entries
traffic processed: ...
UDP traffic (active device=enp1s0):  sent 4.1 MB  recv 4.0 MB
message tracking:  malformed 0  lost 0     <-- "lost" climbing => sync link saturated/dropping
```

### 3.5 Verifying and diagnosing VRRP

```bash
# Which node owns the VIP right now?
$ ip -br addr show enp3s0
enp3s0  UP  10.0.0.11/24 203.0.113.10/24     <-- VIP present = this box is MASTER

# Watch the protocol on the wire (proto 112). One MASTER should advertise; silence from the other.
$ sudo tcpdump -ni enp3s0 vrrp
14:22:01.114 IP 10.0.0.11 > 224.0.0.18: VRRPv3, Advertisement, vrid 51, prio 150, intvl 100cs
14:22:02.114 IP 10.0.0.11 > 224.0.0.18: VRRPv3, Advertisement, vrid 51, prio 150, intvl 100cs

# State transitions and the reason for them:
$ journalctl -u keepalived -f
Aug 12 14:25:07 lb01 Keepalived_vrrp[981]: (VI_PUBLIC) Entering FAULT STATE
Aug 12 14:25:07 lb01 Keepalived_vrrp[981]: VRRP_Script(chk_haproxy) failed (exited with status 1)
Aug 12 14:25:07 lb01 Keepalived_vrrp[981]: (VI_PUBLIC) Changing effective priority from 150 to 110
```

| Symptom | Root cause | Confirm | Fix |
|---|---|---|---|
| **Both nodes are MASTER (split-brain)** | Advertisements not reaching the peer | `tcpdump vrrp` shows nothing arriving | Open proto 112 in firewall; if multicast is blocked (cloud), switch to `unicast_peer` |
| Same as above | VRID mismatch or different `auth_pass` (v2) | Compare configs | Align `virtual_router_id` and auth |
| **Failover happens but traffic still dead** | Gratuitous ARP dropped; switch CAM/clients keep old MAC | `arping`/`tcpdump arp` shows no GARP relearned | `vrrp_garp_master_refresh`; verify switch port security/DAI isn't dropping GARP |
| **VIP flaps constantly** | `preempt` + aggressive timers + a marginal link | Repeated MASTER↔BACKUP in journal | `nopreempt`; raise `fall`/`rise`; add `downdelay` on the underlying bond |
| **Service dead but VIP won't move** | `weight` too small: `master_prio + weight` still > backup | Effective priority in journal | Re-tune `weight` so effective master priority drops below backup |
| **Established connections reset at failover** | No state replication | `conntrackd -s` shows empty external cache | Deploy conntrackd + wire the notify hooks |
| keepalived refuses to run the script | `enable_script_security` + world-writable script | Log: "script ... is insecure" | `chown keepalived_script`, mode `0750` |

> **Cloud caveat:** on AWS/Azure/GCP the L2 fabric is virtual — gratuitous ARP and multicast usually don't work. VRRP still elects a master, but the *notify_master* script must call the cloud API to reassign the Elastic/floating IP or rewrite a route-table entry pointing the /32 at the new instance. The election is keepalived's job; moving the address is the cloud provider's.

---

## 4. Path redundancy: dynamic routing, ECMP, and anycast

VRRP is an **L2 technique** — it only works within one broadcast domain and only protects the *first hop*. It cannot survive the loss of an entire site, cannot spread load across paths, and cannot advertise a service to the wider network. For those, HA moves up to **L3 routing**.

### 4.1 ECMP — many equal paths, hashed per flow

Equal-Cost Multi-Path installs several next-hops for one destination; the kernel hashes each *flow* to one of them (per-flow, so a TCP connection never reorders):

```bash
$ sudo ip route add 203.0.113.0/24 \
      nexthop via 10.0.0.1 dev enp1s0 weight 1 \
      nexthop via 10.0.0.2 dev enp2s0 weight 1

$ ip route show 203.0.113.0/24
203.0.113.0/24
        nexthop via 10.0.0.1 dev enp1s0 weight 1
        nexthop via 10.0.0.2 dev enp2s0 weight 1

# Control the hash: 0 = L3 (src/dst IP), 1 = L3+L4 (adds ports), 2 = inner header for tunnels
$ sudo sysctl -w net.ipv4.fib_multipath_hash_policy=1
net.ipv4.fib_multipath_hash_policy = 1

# Show which next-hop a specific flow will actually take:
$ ip route get 203.0.113.55 from 10.0.0.20 ipproto tcp sport 34512 dport 443
203.0.113.55 from 10.0.0.20 via 10.0.0.2 dev enp2s0 ...
```

ECMP alone is not HA — a dead next-hop still gets its share of the hash and blackholes those flows. You need something to **withdraw** the failed path: a link monitor, a dynamic routing protocol, or **BFD** (Bidirectional Forwarding Detection) for sub-second next-hop liveness.

### 4.2 Anycast with FRRouting: advertise one /32 from many nodes

**Anycast** is the L3 counterpart of a VIP: every service node advertises the *same* address (a `/32` loopback) into the routing fabric via BGP or OSPF. Routers ECMP toward all of them; if a node dies, it stops advertising and the route converges away — failover is *routing convergence*, and it works across subnets, racks, and datacenters.

```bash
$ sudo ip address add 203.0.113.10/32 dev lo    # the anycast service address, on loopback
```

**FRRouting** (`frr`, the maintained successor to Quagga) speaks BGP to the top-of-rack router:

```conf
! /etc/frr/frr.conf  — anycast node #1 (AS 65001), ToR is AS 65000
frr version 8.5
frr defaults datacenter
hostname anycast-node1
log syslog informational
!
router bgp 65001
 bgp router-id 10.0.0.11
 no bgp ebgp-requires-policy
 neighbor 10.0.0.254 remote-as 65000
 neighbor 10.0.0.254 bfd                 ! sub-second failure detection via BFD
 !
 address-family ipv4 unicast
  ! Only advertise the anycast /32 when it is actually present on lo.
  ! A health script adds/removes 203.0.113.10/32 => BGP advertises/withdraws automatically.
  redistribute connected route-map ANYCAST-ONLY
 exit-address-family
!
ip prefix-list ANYCAST seq 5 permit 203.0.113.10/32
route-map ANYCAST-ONLY permit 10
 match ip address prefix-list ANYCAST
!
```

The crucial production pattern is **health-gated advertisement**: FRR has no built-in service check, so pair it with a small watcher that *removes the `/32` from `lo` when the service is unhealthy*. `redistribute connected` then stops originating the route and BGP withdraws it — the router reconverges onto the surviving nodes:

```bash
#!/bin/bash
# /usr/local/bin/anycast-health.sh  (run from a systemd timer or a loop)
VIP=203.0.113.10/32
if curl -fsS --max-time 2 http://127.0.0.1:8080/healthz >/dev/null; then
    ip address show dev lo | grep -q "$VIP" || ip address add "$VIP" dev lo
else
    ip address show dev lo | grep -q "$VIP" && ip address del "$VIP" dev lo
fi
```

Verify BGP and the withdrawal behavior:

```bash
$ sudo vtysh -c "show bgp ipv4 unicast summary"
Neighbor        V     AS   MsgRcvd MsgSent  Up/Down  State/PfxRcd
10.0.0.254      4  65000     14201   14198  2d03h12m       417

$ sudo vtysh -c "show bgp ipv4 unicast 203.0.113.10/32"
BGP routing table entry for 203.0.113.10/32
  Local, best, valid
  10.0.0.254 from 10.0.0.254 (10.0.0.254)   <-- advertised while healthy

# Kill the service; the /32 is pulled from lo; within a BGP/BFD cycle:
$ sudo vtysh -c "show bgp ipv4 unicast 203.0.113.10/32"
% Network not in table                       <-- withdrawn; router now ECMPs to healthy nodes
```

### 4.3 The reverse-path trap: `rp_filter` and asymmetric routing

The failure that silently eats *half* of a multipath deployment is **reverse-path filtering**. With `net.ipv4.conf.*.rp_filter=1` (strict), the kernel drops any packet whose source would not be routed back out the interface it arrived on. In an ECMP/anycast fabric — or an LVS Direct Routing setup — traffic is legitimately asymmetric, so strict rp_filter blackholes it and every diagnostic (link up, BGP established, bond healthy) looks green.

```bash
$ sysctl net.ipv4.conf.all.rp_filter
net.ipv4.conf.all.rp_filter = 1        # strict — drops asymmetric flows

# Loose mode: accept if the source is reachable via ANY interface (RFC 3704 loose):
$ sudo sysctl -w net.ipv4.conf.all.rp_filter=2
$ sudo sysctl -w net.ipv4.conf.enp1s0.rp_filter=2

# Watch the drops accumulate before you fix it:
$ nstat -az | grep -i rpfilter
IpReversePathFilter        18422    0.0
```

For **LVS Direct Routing** and any host that must hold a VIP on `lo` without answering ARP for it, the companion sysctls are equally load-bearing:

```bash
$ sudo sysctl -w net.ipv4.conf.all.arp_ignore=1   # only reply to ARP for IPs on the receiving iface
$ sudo sysctl -w net.ipv4.conf.all.arp_announce=2 # announce the best local source, not the VIP
```

### 4.4 Choosing the layer: VRRP vs. anycast/BGP

| | VRRP (keepalived) | Anycast + BGP/ECMP (FRR) |
|---|---|---|
| OSI layer | L2/L3, single subnet | L3, routed, multi-subnet / multi-site |
| Active nodes | 1 active, N−1 idle | **All active** (load spread by ECMP hash) |
| Failover mechanism | Gratuitous ARP + priority election | Route withdrawal + routing convergence (BFD ⇒ sub-second) |
| Failover time | ~3 × advert_int (default ~3 s; tunable to sub-second) | BGP/BFD convergence, tens of ms–seconds |
| Scope limit | One broadcast domain | Wherever the routes reach |
| Client impact | Transparent (same VIP, same MAC) | Transparent (same anycast IP) |
| Requires | Just the two hosts + L2 reachability | Cooperating routers, an AS/peering plan |
| Capacity ceiling | One node's throughput | Sum of all nodes |
| Classic failure | Split-brain, dropped GARP | Asymmetric routing / `rp_filter`, flapping BGP |
| Fits | First-hop gateway, LB pair, on-prem VLAN | Global service front-ends, DC-scale, capacity + HA together |

**Rule of thumb:** VRRP for the *gateway* and small LB pairs where an idle standby is acceptable and everything lives on one VLAN. Anycast/BGP when you need *all* nodes serving, cross-subnet or cross-site reach, and failover measured by routing convergence rather than ARP. They compose: VRRP for the north-south gateway inside a rack, anycast for the service address the rest of the world resolves.

---

## 5. Consolidated verification & diagnosis runbook

```bash
# --- Link layer ---
cat /proc/net/bonding/bond0        # mode, aggregator IDs, Partner MAC, churn state
teamdctl team0 state               # (teaming) runner + per-port aggregator selection
ethtool enp1s0                     # negotiated speed/duplex — a mode-4 slave at wrong speed drops out
ip -s link show bond0              # per-interface error/drop counters

# --- Gateway (VRRP) ---
ip -br addr show enp3s0            # is the VIP here? (who is MASTER)
tcpdump -ni enp3s0 vrrp           # exactly one advertiser; proto 112 reaching the peer?
journalctl -u keepalived -f        # transitions + WHY (script fail, priority change)
conntrackd -s                      # internal/external cache size; "lost" counter

# --- Path (routing / anycast) ---
ip route show 203.0.113.0/24       # ECMP next-hops present?
ip route get <dst> from <src> ipproto tcp sport <p> dport <p>   # which next-hop this flow takes
vtysh -c "show bgp ipv4 unicast summary"     # BGP sessions Established? PfxRcd sane?
vtysh -c "show bgp ipv4 unicast <vip>/32"    # is the anycast route advertised right now?
bfdd / vtysh -c "show bfd peers"             # sub-second liveness up?

# --- The silent killers ---
sysctl net.ipv4.conf.all.rp_filter           # 1 (strict) blackholes asymmetric/multipath
nstat -az | grep -iE 'rpfilter|drop'          # proof the kernel is dropping, and why
sysctl net.ipv4.fib_multipath_hash_policy     # 0=L3, 1=L3+L4 hashing for ECMP
```

**The end-to-end failure test that catches what green dashboards miss:** don't test by killing a *process* — pull a *cable*. Physically down one bond slave (`ip link set enp1s0 down`), confirm the bond stays up on the survivor with no packet loss to a running `ping`; then down the whole master node and confirm the VIP moves *and* a pre-existing SSH/TCP session survives (proving conntrackd), *and* that anycast withdrew within your SLO. A setup that survives `systemctl stop` but not `ip link set down` has untested link-layer HA — which is exactly where the real outages come from.

---

## 6. References

- LPI — LPIC-3 Exam 306 Objectives (306-300, v3.0): <https://www.lpi.org/our-certifications/exam-306-objectives/>
- RFC 5798 — Virtual Router Redundancy Protocol (VRRP) Version 3 for IPv4 and IPv6: <https://datatracker.ietf.org/doc/html/rfc5798>
- RFC 3768 — Virtual Router Redundancy Protocol (VRRP) v2: <https://datatracker.ietf.org/doc/html/rfc3768>
- RFC 3704 — Ingress Filtering for Multihomed Networks (reverse-path filtering): <https://datatracker.ietf.org/doc/html/rfc3704>
- keepalived — official documentation and `keepalived.conf(5)` man page: <https://keepalived.readthedocs.io/> and <https://www.keepalived.org/manpage.html>
- Linux kernel — Bonding driver documentation (modes, `xmit_hash_policy`, `miimon`, 802.3ad): <https://www.kernel.org/doc/Documentation/networking/bonding.rst>
- libteam / teamd — project documentation and `teamd.conf(5)`: <https://github.com/jpirko/libteam/wiki>
- Red Hat — Configuring and Managing Networking (RHEL 9): bonding, and the deprecation of network teaming: <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_managing_networking/index>
- conntrack-tools / conntrackd — documentation and man page (state replication, primary-backup): <https://conntrack-tools.netfilter.org/manual.html>
- FRRouting — user guide (BGP, OSPF, BFD, ECMP): <https://docs.frrouting.org/>
- Linux Advanced Routing & Traffic Control (LARTC) — policy routing and multipath: <https://lartc.org/howto/>
- `systemd-networkd` — `systemd.netdev(5)` (Bond/`[Bond]`) and `systemd.network(5)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.netdev.html>