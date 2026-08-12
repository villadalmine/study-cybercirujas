# Topic 361.2 — Load Balanced Clusters

**LPIC-3 306 · Exam 306-300 · v3.0 · Weight 13.34**

This objective covers the layer that turns a fleet of identical servers into a single, resilient service address. It has three pillars, and the exam tests all three at implementation depth: **LVS/IPVS** (the in‑kernel L4 balancer), **keepalived** (VRRP for balancer HA plus health‑checked control of IPVS), and **HAProxy** (the userspace L4/L7 balancer with ACLs and stick tables). The material below builds each pillar from its packet‑level mechanics up to full, deployable configuration and a diagnostic runbook.

---

## 1. The production problem

A single web server has a hard ceiling — CPU, connection table, NIC queue depth — and it is a single point of failure. Horizontal scaling answers the ceiling: put N identical backends behind one **Virtual IP (VIP)** and spread requests across them. But that immediately creates two new problems the exam objective is built around:

1. **How does one IP distribute traffic to N real servers, and where does the return traffic go?** This is the *forwarding method* question, and it is the difference between a director that saturates at 1 Gbit/s (NAT) and one that pushes 40 Gbit/s (Direct Routing), because in the second case the director never touches a single reply packet.

2. **What happens when the load balancer itself dies?** The VIP is now the single point of failure you just concentrated all traffic through. This is the *VIP failover* question, solved with **VRRP** (via keepalived) so a standby director claims the VIP within one advertisement interval.

There is a third, orthogonal axis: **at what OSI layer do you make the balancing decision?**

- **Layer 4 (transport):** the balancer picks a backend per *connection*, based only on IP/port. It never parses payload, so it is cheap, fast, and protocol‑agnostic (works for TCP, and with UDP for DNS/QUIC/game traffic). This is LVS/IPVS, and HAProxy in `mode tcp`.
- **Layer 7 (application):** the balancer terminates the connection, parses HTTP, and can route on Host header, URL path, cookies, or method; rewrite headers; terminate TLS; retry idempotent requests. This is HAProxy in `mode http`. It costs CPU and memory per connection and it is protocol‑specific, but it enables content‑based routing, canary releases, and observability that L4 cannot provide.

A production edge is very often **both**: an L4 tier (IPVS + keepalived) for raw VIP HA and throughput, fronting an L7 tier (HAProxy) for routing and TLS. Understanding when each layer earns its cost is the core competency this objective measures.

```
                         ┌──────────────────────────────┐
                         │      VIP 203.0.113.10         │
                         │  (owned by keepalived/VRRP)   │
                         └───────────────┬──────────────┘
             VRRP (proto 112) advert     │
   ┌──────────────────────┐        ┌─────┴──────────────────┐
   │  Director A (MASTER)  │◀──────▶│  Director B (BACKUP)   │
   │  keepalived + IPVS    │  sync  │  keepalived + IPVS     │
   │  prio 150             │  daemon│  prio 100              │
   └───────────┬───────────┘        └────────────────────────┘
               │  L4 forward (DR / NAT / TUN)
      ┌────────┼─────────┬──────────────┐
      ▼        ▼         ▼              ▼
  ┌───────┐┌───────┐ ┌───────┐     ┌───────┐
  │ RS 1  ││ RS 2  │ │ RS 3  │ ... │ RS N  │   real servers
  └───────┘└───────┘ └───────┘     └───────┘
```

---

## 2. The landscape and where each tool fits

| Property | **LVS / IPVS** | **HAProxy** | **keepalived** |
|---|---|---|---|
| Runs in | Linux kernel (netfilter/IPVS) | Userspace, event‑driven | Userspace daemon |
| OSI layer | L4 only (TCP/UDP/SCTP) | L4 (`tcp`) and L7 (`http`) | Control plane, not a data plane |
| Role | Data‑plane balancer | Data‑plane balancer + proxy | VRRP failover + health checks + programs IPVS |
| Terminates connection? | No (transparent) | Yes | N/A |
| Sees reply traffic? | Only in NAT mode | Always (it is a proxy) | N/A |
| TLS termination | No | Yes | No |
| Content routing (path/host/cookie) | No | Yes (ACLs) | No |
| Peak throughput | Very high (line rate in DR) | High, bounded by CPU/TLS | N/A |
| Per‑connection cost | ~1 hash‑table entry | Full socket + buffers | N/A |
| Configures itself? | No (needs `ipvsadm` or keepalived) | Yes (`haproxy.cfg`) | Yes; can drive IPVS |

Key mental model: **IPVS is a mechanism, keepalived is the control plane that usually drives it.** You *can* program IPVS by hand with `ipvsadm`, but in production the `virtual_server`/`real_server` stanzas in `keepalived.conf` do it for you *and* add health checking *and* handle VIP failover. HAProxy is a self‑contained alternative that replaces the *balancer* role but still needs keepalived (or an equivalent) for **VIP** high availability — HAProxy has no built‑in VRRP.

---

## 3. LVS / IPVS

### 3.1 Architecture

IPVS lives in the kernel as a netfilter hook on the `INPUT`/`LOCAL_IN` path. When a packet arrives for a registered *virtual service* (VIP:port/protocol), IPVS:

1. Looks up an existing entry in its **connection hash table** keyed by (client IP:port, VIP:port, protocol). If found, the packet goes to the same real server — this is what makes a stateless L4 balancer keep TCP connections pinned to one backend.
2. If it is a new connection (SYN), it runs the configured **scheduler** to pick a real server, records the mapping, and forwards according to the configured **forwarding method**.

IPVS maintains its own connection state independent of `nf_conntrack`; the table size is a power of two set at module load (`conn_tab_bits`, default 12 → 4096 buckets, tunable up to `20`).

Required modules: the core `ip_vs` plus one scheduler module per algorithm in use.

```
$ sudo modprobe ip_vs
$ sudo modprobe ip_vs_wlc
$ lsmod | grep ip_vs
ip_vs_wlc              16384  1
ip_vs                 176128  3 ip_vs_wlc
nf_conntrack          172032  1 ip_vs
nf_defrag_ipv6         24576  2 nf_conntrack,ip_vs
libcrc32c              16384  3 nf_conntrack,xfs,ip_vs
```

Persist across reboots:

```
$ cat /etc/modules-load.d/ipvs.conf
ip_vs
ip_vs_wlc
ip_vs_rr
ip_vs_sh
nf_conntrack
```

### 3.2 Forwarding methods — the central design decision

This is the single most‑tested concept in 361.2. Three methods, each rewriting a different part of the packet and each imposing a different constraint on the real servers.

| | **NAT (`-m`, masq)** | **Direct Routing (`-g`, gatewaying)** | **Tunneling (`-i`, ipip)** |
|---|---|---|---|
| What the director rewrites | Destination IP (in), source IP (out) | Destination **MAC** only; IPs untouched | Encapsulates original packet in an outer IP‑in‑IP header |
| Return path | **Back through the director** (it must un‑NAT) | Real server → **directly to client** | Real server → **directly to client** |
| Real server network | Private; **default gateway must be the director** | **Same L2 segment** as the director | **Any network / remote** (routed) |
| VIP on real server | No | Yes, on `lo` with ARP suppression | Yes, on `tunl0` with ARP suppression |
| Real server OS | Any (it never sees the VIP) | Must support `lo` alias + `arp_ignore` | Must support IP‑in‑IP tunneling |
| Port remapping | Yes (VIP:80 → RS:8080) | No (port preserved) | No |
| MTU concern | None | None | Yes — 20‑byte outer header shrinks payload |
| Director is bottleneck | **Yes** (both directions) | No (ingress only) | No (ingress only) |
| Typical scale | ~10–20 real servers | ~100+ real servers | ~100+, geo‑distributed |

**NAT** is the simplest and works with any backend, but every reply flows back through the director, so the director's uplink bounds total throughput. Requires `net.ipv4.ip_forward=1`.

**Direct Routing (DR)** is the workhorse of high‑throughput production. The director only rewrites the destination MAC to a real server's MAC; the destination IP stays the VIP. The real server therefore must **own the VIP** (on `lo`) to accept the packet, and must respond **directly** to the client with source IP = VIP. Because multiple hosts now carry the same VIP on the same L2 segment, you must stop the real servers from answering ARP for it — otherwise clients ARP‑resolve the VIP to a random real server and bypass the director. This is **the ARP problem**, solved with `arp_ignore=1` / `arp_announce=2`.

**Tunneling (TUN)** wraps the original packet in an outer IP‑in‑IP header addressed to the real server, which decapsulates, sees the VIP inside, and replies directly. This lets real servers live on entirely different networks (even different data centres). The cost is a 20‑byte encapsulation overhead that can trigger fragmentation or PMTU black‑holes if not accounted for.

### 3.3 Scheduling algorithms

| Scheduler | Meaning | Decision basis | State | Best for |
|---|---|---|---|---|
| `rr` | Round Robin | strict rotation | stateless | homogeneous backends, short conns |
| `wrr` | Weighted RR | rotation ∝ weight | stateless | heterogeneous capacity |
| `lc` | Least‑Connection | fewest active conns | dynamic | long‑lived connections |
| `wlc` | Weighted LC **(default)** | minimise `active/weight` | dynamic | mixed capacity + long conns |
| `lblc` | Locality‑Based LC | dest IP → server, LC on overload | dynamic | transparent cache/proxy farms |
| `lblcr` | LBLC + Replication | dest IP → server **set** | dynamic | cache farms with hot keys |
| `dh` | Destination Hash | `hash(dest IP)` | stateless | transparent proxies |
| `sh` | Source Hash | `hash(src IP)` | stateless | persistence with no state table |
| `sed` | Shortest Expected Delay | minimise `(active+1)/weight` | dynamic | small farms, short conns |
| `nq` | Never Queue | idle server first, else SED | dynamic | avoid queueing latency |
| `fo` | Weighted Failover | highest‑weight available only | stateless | active/passive backends |
| `ovf` | Weighted Overflow | saturate highest weight, then spill | dynamic | overflow / burst scaling |
| `mh` | Maglev Hashing | consistent hashing | stateless | minimal remap on membership change |

`wlc` is the default and the safe general choice. Use `sh` when you need client‑to‑server stickiness without a persistence table; use `mh` (kernel ≥ 4.18) when you need consistent hashing that barely disturbs existing flows when a backend is added or removed.

### 3.4 Manual programming with `ipvsadm` (DR example)

Director:

```
# 1. VIP on the director's public interface
$ sudo ip addr add 203.0.113.10/32 dev eth0

# 2. Virtual service: TCP VIP:80, weighted least-connection
$ sudo ipvsadm -A -t 203.0.113.10:80 -s wlc

# 3. Real servers via Direct Routing (-g = gatewaying)
$ sudo ipvsadm -a -t 203.0.113.10:80 -r 10.0.0.11:80 -g -w 1
$ sudo ipvsadm -a -t 203.0.113.10:80 -r 10.0.0.12:80 -g -w 1

# 4. Inspect
$ sudo ipvsadm -Ln
IP Virtual Server version 1.2.1 (size=4096)
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
TCP  203.0.113.10:80 wlc
  -> 10.0.0.11:80                 Route   1      842        231
  -> 10.0.0.12:80                 Route   1      839        228
```

The `Forward` column decodes the method: **`Route`** = Direct Routing, **`Masq`** = NAT, **`Tunnel`** = TUN, **`Local`** = terminated locally.

Every real server in DR/TUN needs the VIP on a non‑ARPing interface:

```
# On each real server — DR: VIP on loopback, ARP fully suppressed
$ sudo ip addr add 203.0.113.10/32 dev lo
$ sudo tee /etc/sysctl.d/99-lvs-realserver.conf >/dev/null <<'EOF'
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.lo.arp_ignore = 1
net.ipv4.conf.lo.arp_announce = 2
EOF
$ sudo sysctl --system
```

`arp_ignore=1` → reply to ARP only if the target IP is configured on the *incoming* interface (so `lo`'s VIP is never advertised on `eth0`). `arp_announce=2` → always use the best *primary* address of the outgoing interface as ARP source, never the VIP. Skipping this is the classic DR failure: clients resolve the VIP to a real server's MAC and traffic bypasses the director entirely.

Save/restore and counters:

```
$ sudo ipvsadm -S -n > /etc/ipvsadm.rules      # dump rules
$ sudo ipvsadm -R < /etc/ipvsadm.rules          # restore
$ sudo ipvsadm -Z                               # zero all counters
```

### 3.5 Connection synchronization (stateful failover)

By default, when the MASTER director dies the BACKUP has an empty connection table, so every in‑flight TCP connection breaks. The **IPVS sync daemon** replicates the connection table from master to backup so failover is *stateful* — established connections survive.

```
# On the master director
$ sudo ipvsadm --start-daemon master --mcast-interface eth1 --syncid 51
# On the backup director
$ sudo ipvsadm --start-daemon backup --mcast-interface eth1 --syncid 51

$ sudo ipvsadm -Ln --daemon
IPVS connection sync daemon (master mcast=eth1 syncid=51)
```

In practice keepalived starts this for you (see `lvs_sync_daemon` below), keyed to the VRRP instance so the *sync* role follows the *VRRP* role.

---

## 4. keepalived — VRRP failover + health‑checked IPVS

keepalived does two jobs that are often conflated:

1. **VRRP** — elects one director as MASTER and floats the VIP to it; on failure the BACKUP takes over.
2. **IPVS director** — the `virtual_server`/`real_server` blocks program IPVS *and* health‑check each real server, pulling failed backends out of the pool automatically.

### 4.1 VRRP mechanics

VRRP (RFC 5798 for v3, RFC 3768 for v2) runs directly over IP as **protocol 112**, sent to multicast `224.0.0.18` (or unicast to explicit peers). Each participating router shares a **virtual_router_id (VRID)** and a **priority** (0–255). The highest‑priority node becomes MASTER and answers ARP for the VIP with a virtual MAC (`00:00:5e:00:01:<VRID>`). MASTER sends advertisements every `advert_int`; if a BACKUP misses ~3 intervals (the *master down interval*), it promotes itself, assigns the VIP, and broadcasts **gratuitous ARP** so switches relearn the MAC. `priority 0` is a special "I am leaving" message that triggers immediate takeover.

| Term | Meaning |
|---|---|
| VRID | Shared group id; must match on all peers, unique per L2 segment |
| priority | Higher wins MASTER; 255 = address owner, 0 = resign |
| advert_int | Advertisement period (s); MASTER‑down ≈ 3 × advert_int |
| preempt | Higher‑priority node reclaims MASTER when it returns |
| GARP | Gratuitous ARP sent on transition to steer L2 to the new MASTER |
| unicast_peer | Send adverts unicast (needed where multicast is filtered, e.g. many clouds) |

### 4.2 Full `keepalived.conf` — HA director pair driving LVS‑DR

This is a complete, deployable configuration for the **MASTER** director. The **BACKUP** is identical except `state BACKUP` and `priority 100`.

```
# /etc/keepalived/keepalived.conf  —  MASTER director
global_defs {
    router_id LVS_DIRECTOR_A
    enable_script_security          # refuse to run scripts owned by non-root/world-writable
    script_user keepalived_script
    vrrp_garp_master_delay 1
    vrrp_garp_master_refresh 60     # periodically re-send GARP to fight stale switch tables
}

# Health of the local IPVS data plane; if IPVS is broken, hand the VIP over.
vrrp_script chk_ipvs {
    script "/usr/bin/test -e /proc/net/ip_vs"
    interval 2
    fall 2                          # 2 consecutive failures = DOWN
    rise 2                          # 2 consecutive successes = UP
    weight -40                      # subtract 40 from priority while failing
}

vrrp_instance VI_WEB {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 150
    advert_int 1
    preempt_delay 5                 # wait 5s after recovery before reclaiming MASTER

    authentication {
        auth_type PASS
        auth_pass S3cr3t-VRRP       # 8-char shared secret (VRRPv2)
    }

    # Unicast is mandatory on clouds/segments where multicast 224.0.0.18 is dropped
    unicast_src_ip 203.0.113.2
    unicast_peer {
        203.0.113.3
    }

    virtual_ipaddress {
        203.0.113.10/32 dev eth0
    }

    track_script {
        chk_ipvs
    }

    notify_master "/etc/keepalived/notify.sh MASTER VI_WEB"
    notify_backup "/etc/keepalived/notify.sh BACKUP VI_WEB"
    notify_fault  "/etc/keepalived/notify.sh FAULT  VI_WEB"
}

# Stateful failover: replicate the IPVS connection table, tied to VI_WEB.
lvs_sync_daemon eth1 VI_WEB id 51

# ---- LVS virtual service: keepalived programs IPVS AND health-checks backends ----
virtual_server 203.0.113.10 80 {
    delay_loop 6                    # health-check every 6s
    lb_algo wlc                     # weighted least-connection
    lb_kind DR                      # Direct Routing
    protocol TCP
    persistence_timeout 0           # no client stickiness (set >0 to pin by source IP)

    real_server 10.0.0.11 80 {
        weight 1
        HTTP_GET {
            url {
                path /healthz
                status_code 200
            }
            connect_timeout 3
            retry 3
            delay_before_retry 3
        }
    }

    real_server 10.0.0.12 80 {
        weight 1
        HTTP_GET {
            url {
                path /healthz
                status_code 200
            }
            connect_timeout 3
            retry 3
            delay_before_retry 3
        }
    }
}
```

`notify.sh` (must be root‑owned and non‑world‑writable, per `enable_script_security`):

```
#!/usr/bin/env bash
# /etc/keepalived/notify.sh  <STATE> <INSTANCE>
set -euo pipefail
STATE="$1"; INSTANCE="$2"
logger -t keepalived "transition: instance=${INSTANCE} state=${STATE}"
case "$STATE" in
    MASTER) ;;   # VIP arrived — nothing extra needed for pure LVS-DR
    BACKUP|FAULT)
        # Example hook: drain local caches, page on FAULT, etc.
        ;;
esac
```

The design intent: `track_script chk_ipvs` with `weight -40` means that if the local IPVS engine breaks on the MASTER, its effective priority drops to `110`, which is *still* above the BACKUP's `100` — so a single soft fault does not flap the VIP. Make the weight larger than the peer gap (e.g. `-60`) if you *do* want a local data‑plane fault to force failover. When co‑locating **HAProxy** on the same nodes, you instead track a `killall -0 haproxy` script so the VIP follows a healthy HAProxy.

Health‑check types available inside `real_server`: `TCP_CHECK` (connect only), `HTTP_GET`/`SSL_GET` (fetch a URL, match status/digest), `SMTP_CHECK`, `MISC_CHECK` (run an arbitrary script; exit 0 = healthy), `PING_CHECK`. `HTTP_GET` against a real `/healthz` endpoint is strongly preferred over `TCP_CHECK`, which only proves the port is open, not that the app can serve.

### 4.3 keepalived verification

```
$ sudo systemctl status keepalived --no-pager
● keepalived.service - Keepalive Daemon (LVS and VRRP)
     Active: active (running) since Wed 2026-08-12 09:14:02 UTC; 3h ago

$ sudo journalctl -u keepalived -n 5 --no-pager
keepalived[8123]: (VI_WEB) Entering MASTER STATE
keepalived[8123]: (VI_WEB) setting VIPs.
keepalived[8123]: Sending gratuitous ARP on eth0 for 203.0.113.10

# VIP present ONLY on the MASTER:
$ ip -br addr show dev eth0 | grep 203.0.113.10
eth0   UP   203.0.113.2/24 203.0.113.10/32

# On the BACKUP the same grep returns nothing — that is correct.
```

---

## 5. HAProxy — L4/L7 proxy with ACLs

HAProxy is a userspace, event‑driven proxy. Unlike IPVS it *terminates* the client connection and opens a fresh one to the backend, which is exactly what lets it work at L7: parse HTTP, route on content, terminate TLS, rewrite headers, and retry. Modern HAProxy is multithreaded (`nbthread`), replacing the older multiprocess `nbproc` model.

### 5.1 Configuration structure

- `global` — process‑wide: user/group, `maxconn`, threads, TLS defaults, stats socket, logging.
- `defaults` — inherited settings for the sections below it (timeouts, mode, options).
- `frontend` — a bind address/port and the routing rules (`acl` + `use_backend`).
- `backend` — a pool of `server` lines plus the `balance` algorithm and health checks.
- `listen` — a frontend+backend fused into one block (handy for the stats page or simple TCP proxies).

### 5.2 Load‑balancing algorithms

| `balance` | Layer | Behaviour | Sticky? |
|---|---|---|---|
| `roundrobin` | — | rotate; dynamic weights; ~4095 active servers/backend | no |
| `static-rr` | — | rotate; static weights (no runtime change); unlimited servers | no |
| `leastconn` | — | fewest active connections | no |
| `first` | — | fill lowest‑id server to `maxconn`, then next (power saving) | no |
| `source` | L3 | `hash(source IP)` | yes |
| `uri` | L7 | `hash(request URI)` | cache affinity |
| `url_param` | L7 | `hash(named query param)` | app‑defined |
| `hdr(<name>)` | L7 | `hash(header value)`, e.g. `hdr(Host)` | per‑header |
| `random` / `random(2)` | — | random; `random(2)` = power‑of‑two‑choices | no |
| `rdp-cookie` | L7 | RDP session cookie | yes |

`leastconn` for long‑lived connections (WebSocket, DB), `roundrobin` for short stateless HTTP, `source` when you need cheap client stickiness without cookies, `uri` for cache tiers.

### 5.3 Full `haproxy.cfg` — L7 routing, TLS, health checks, ACLs, stats

```
# /etc/haproxy/haproxy.cfg
global
    log         /dev/log local0
    chroot      /var/lib/haproxy
    user        haproxy
    group       haproxy
    daemon
    maxconn     100000
    nbthread    4
    cpu-map     auto:1/1-4 0-3

    # Runtime API for hitless reloads, live stats, dynamic server state
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s

    # Modern, safe TLS baseline
    ssl-default-bind-ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256
    ssl-default-bind-ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384
    ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    option  http-server-close
    option  forwardfor          except 127.0.0.0/8   # inject X-Forwarded-For
    retries 3
    timeout connect 5s
    timeout client  50s
    timeout server  50s
    timeout http-request 10s
    timeout http-keep-alive 15s
    timeout queue   30s
    default-server inter 3s fall 3 rise 2 slowstart 20s

# ---------------- FRONTEND: TLS termination + content routing ----------------
frontend fe_https
    bind :80
    bind :443 ssl crt /etc/haproxy/certs/ alpn h2,http/1.1
    http-request redirect scheme https code 301 unless { ssl_fc }

    # Security headers
    http-response set-header Strict-Transport-Security "max-age=63072000; includeSubDomains"

    # ---- ACLs: match on path, host, method ----
    acl is_api        path_beg /api/
    acl is_static     path_end .css .js .png .jpg .svg .woff2
    acl is_admin      path_beg /admin
    acl host_media    hdr(host) -i media.example.com
    acl trusted_admin src 10.0.0.0/8 192.168.0.0/16

    # ---- Rate limit abusive clients using a stick-table ----
    stick-table type ip size 1m expire 10m store http_req_rate(10s)
    http-request track-sc0 src
    http-request deny deny_status 429 if { sc_http_req_rate(0) gt 100 }

    # ---- Routing decisions (first match wins) ----
    http-request deny deny_status 403 if is_admin !trusted_admin
    use_backend be_static  if is_static
    use_backend be_media   if host_media
    use_backend be_api     if is_api
    default_backend be_web

# ---------------- BACKENDS ----------------
backend be_web
    balance roundrobin
    option httpchk GET /healthz HTTP/1.1\r\nHost:\ health.local
    http-check expect status 200
    cookie SRVID insert indirect nocache            # L7 session stickiness
    server web1 10.0.0.11:8080 check cookie web1
    server web2 10.0.0.12:8080 check cookie web2
    server web3 10.0.0.13:8080 check cookie web3 backup   # only used if all primaries down

backend be_api
    balance leastconn
    option httpchk GET /api/health
    http-check expect status 200
    server api1 10.0.0.21:9000 check maxconn 500
    server api2 10.0.0.22:9000 check maxconn 500

backend be_static
    balance uri
    hash-type consistent                            # minimal remap when a cache node changes
    server cache1 10.0.0.31:80 check
    server cache2 10.0.0.32:80 check

backend be_media
    balance leastconn
    server media1 10.0.0.41:80 check

# ---------------- STATS PAGE ----------------
listen stats
    bind 127.0.0.1:8404
    stats enable
    stats uri /
    stats refresh 5s
    stats admin if TRUE
```

Notes that matter in production:

- **`cookie SRVID insert indirect`** gives L7 stickiness that survives backend restarts more gracefully than IP hashing behind carrier‑grade NAT (where thousands of clients share one source IP).
- **`server ... backup`** marks a cold‑standby that only receives traffic when all primaries are down.
- **`slowstart 20s`** ramps a freshly‑`UP` server's weight from 0 to full over 20 s so a just‑restarted JVM isn't hit with full load before its caches warm.
- **`hash-type consistent`** on the cache tier means adding/removing a cache node remaps only ~1/N of keys instead of reshuffling everything.
- **`expose-fd listeners`** on the stats socket is what enables **hitless reloads**: on `reload`, the new process retrieves the old listening sockets over the socket, so no connection is dropped and no SYN is refused.

### 5.4 HAProxy operations

```
# Validate before touching the running service — never reload a bad config
$ haproxy -c -f /etc/haproxy/haproxy.cfg
Configuration file is valid

# Seamless reload (new workers inherit sockets, old workers drain then exit)
$ sudo systemctl reload haproxy

# Confirm the drain of old workers
$ ps -o pid,cmd -C haproxy
    PID CMD
   9001 /usr/sbin/haproxy -Ws -f /etc/haproxy/haproxy.cfg -p /run/haproxy.pid -sf 8800
```

systemd unit that performs a config check on every reload (Debian/RHEL ship a close equivalent):

```
# /etc/systemd/system/haproxy.service.d/override.conf
[Service]
ExecReload=/usr/sbin/haproxy -Ws -f /etc/haproxy/haproxy.cfg -c -q
ExecReload=/bin/kill -USR2 $MAINPID
```

---

## 6. Verification and failure diagnosis

### 6.1 IPVS — is traffic actually being distributed?

```
$ sudo ipvsadm -Ln --stats
IP Virtual Server version 1.2.1 (size=4096)
Prot LocalAddress:Port               Conns   InPkts  OutPkts  InBytes OutBytes
  -> RemoteAddress:Port
TCP  203.0.113.10:80                 1451233 48937112 0       12G      0
  -> 10.0.0.11:80                    725841  24476201 0       6G       0
  -> 10.0.0.12:80                    725392  24460911 0       6G       0
```

**Diagnostic gold:** `OutPkts` and `OutBytes` are **0**. In DR and TUN modes the replies never traverse the director, so 0 is *correct and expected*. If you see non‑zero OutPkts on a DR service, either you are actually in NAT mode or return traffic is being misrouted through the director — investigate. Conversely, if `Conns` is climbing but a backend's `ActiveConn` stays at 0, that backend is up in the table but not receiving traffic (often a health check quietly removed it, or an ARP problem).

Live connection table and per‑backend rate:

```
$ sudo ipvsadm -Lnc | head
IPVS connection entries
pro expire state       source             virtual            destination
TCP 14:55  ESTABLISHED 198.51.100.7:51922 203.0.113.10:80    10.0.0.11:80
TCP 00:42  FIN_WAIT    198.51.100.9:40113 203.0.113.10:80    10.0.0.12:80
TCP 01:58  TIME_WAIT   198.51.100.3:33555 203.0.113.10:80    10.0.0.11:80

$ sudo ipvsadm -Ln --rate
Prot LocalAddress:Port                 CPS    InPPS   OutPPS    InBPS   OutBPS
  -> RemoteAddress:Port
TCP  203.0.113.10:80                    412    18320    0        14M      0
  -> 10.0.0.11:80                       205    9140     0        7M       0
  -> 10.0.0.12:80                       207    9180     0        7M       0
```

**The DR ARP problem — how to catch it.** Symptom: intermittent failures, or a subset of clients hitting one real server directly and never load‑balancing. From a client segment, resolve the VIP and check *who* answers ARP:

```
$ arping -c 3 -I eth0 203.0.113.10
ARPING 203.0.113.10 from 198.51.100.1 eth0
Unicast reply from 203.0.113.10 [00:16:3e:aa:11:11]   0.6ms   # real server MAC — BUG
Unicast reply from 203.0.113.10 [00:16:3e:bb:22:22]   0.7ms   # another RS — BUG
```

Two different MACs answering for the VIP means the real servers are ARPing for the VIP on `lo` — `arp_ignore`/`arp_announce` are unset or were reset. Fix and re‑verify:

```
$ sysctl net.ipv4.conf.all.arp_ignore net.ipv4.conf.all.arp_announce
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
```

**TUN MTU black‑hole.** Symptom: small requests work, large POSTs/downloads hang. The 20‑byte IP‑in‑IP header pushed a full‑MTU packet over the wire limit and PMTU discovery is being filtered. Confirm with a do‑not‑fragment ping sweep and lower the tunnel/backend MTU (e.g. 1480) or clamp MSS.

### 6.2 VRRP — split brain and flapping

```
# Watch VRRP adverts on the wire (multicast form)
$ sudo tcpdump -n -i eth0 vrrp
12:00:01.001 IP 203.0.113.2 > 224.0.0.18: VRRPv2, Advertisement, vrid 51, prio 150, authtype simple, intvl 1s, length 20
12:00:02.002 IP 203.0.113.2 > 224.0.0.18: VRRPv2, Advertisement, vrid 51, prio 150, authtype simple, intvl 1s, length 20
```

**Split brain (both nodes MASTER, VIP on both):** the two directors cannot see each other's adverts — a firewall dropping protocol 112, a blocked multicast group `224.0.0.18`, or a mismatched `virtual_router_id`/`auth_pass`. Detect it directly:

```
# Run on BOTH directors; the VIP must appear on exactly ONE.
$ ip -br addr | grep 203.0.113.10
# nodeA: eth0  UP  203.0.113.2/24 203.0.113.10/32
# nodeB: eth0  UP  203.0.113.3/24 203.0.113.10/32     <-- BOTH have it: SPLIT BRAIN
```

Root‑cause checklist:
- `sudo iptables -L -n | grep -i vrrp` / allow proto 112 — many cloud SGs and host firewalls silently drop it.
- Multicast filtered? Switch to `unicast_peer` (as in the config above) — this is the standard fix on clouds and many enterprise fabrics.
- `virtual_router_id` and `auth_pass` **identical** on both nodes, and the VRID unique within the L2 segment (a colliding VRID from an unrelated cluster causes bizarre elections).

**Flapping (VIP bouncing every few seconds):** usually `advert_int` too aggressive for a loaded/lossy link, or a `track_script` whose `weight` drop crosses the peer priority on transient failures. Raise `fall`, add `preempt_delay`, or reduce the `weight` magnitude.

Failover timing test — kill keepalived on the MASTER and time the takeover:

```
# On MASTER:
$ sudo systemctl stop keepalived
# On BACKUP, watch it promote (should be ~3× advert_int):
$ sudo journalctl -u keepalived -f
keepalived[7710]: (VI_WEB) Backup received priority 0 advertisement
keepalived[7710]: (VI_WEB) Entering MASTER STATE
keepalived[7710]: Sending gratuitous ARP on eth0 for 203.0.113.10
```

The `priority 0` advertisement is keepalived's graceful‑shutdown signal, which is why a clean `stop` fails over faster than a hard power‑off (the latter waits the full master‑down interval).

### 6.3 HAProxy — the runtime API

The stats socket is the operational nerve centre; drive it with `socat`.

```
$ echo "show stat" | sudo socat stdio /run/haproxy/admin.sock \
    | cut -d, -f1,2,18,5,8,37
# pxname,svname,status,scur,stot,rate
fe_https,FRONTEND,OPEN,1842,9930451,412
be_web,web1,UP,614,3310112,138
be_web,web2,UP,610,3298004,140
be_web,web3,UP,0,0,0            # backup server, no traffic — correct
be_web,BACKEND,UP,1224,6608116,278

# Why is a server down? show its check detail:
$ echo "show servers state be_api" | sudo socat stdio /run/haproxy/admin.sock
1
# be_id be_name srv_id srv_name srv_addr srv_op_state ...
6 be_api 1 api1 10.0.0.21 2 0 1 1 20 3 0 ...
6 be_api 2 api2 10.0.0.22 0 0 1 1 42 1 0 ...   # op_state 0 = DOWN

# Inspect the rate-limit / stickiness table:
$ echo "show table fe_https" | sudo socat stdio /run/haproxy/admin.sock
# table: fe_https, type: ip, size:1048576, used:3
0x7f...: key=198.51.100.7 use=0 exp=598000 http_req_rate(10000)=143   # over the 100 cap → 429

# Administratively drain a backend before maintenance (finish in-flight, take no new):
$ echo "set server be_web/web2 state drain" | sudo socat stdio /run/haproxy/admin.sock
$ echo "set server be_web/web2 state ready" | sudo socat stdio /run/haproxy/admin.sock
```

`srv_op_state 2 = UP`, `0 = DOWN`, `1 = STOPPING/draining`. Correlate a `DOWN` server with `option httpchk` — the commonest cause is the health URL returning a non‑200 (a `/healthz` behind auth, or a wrong `Host` header), not the backend actually being dead. Reproduce the exact check by hand:

```
$ curl -sS -o /dev/null -w '%{http_code}\n' -H 'Host: health.local' http://10.0.0.22:9000/api/health
503                    # <-- the app, not HAProxy, is unhealthy
```

### 6.4 Failure‑mode quick reference

| Symptom | Likely cause | Confirm with |
|---|---|---|
| DR traffic bypasses director; erratic backend | Real servers ARPing for VIP | `arping -I eth0 <VIP>` → multiple MACs |
| IPVS `OutPkts` non‑zero on a "DR" service | Actually NAT, or asymmetric routing | `ipvsadm -Ln` → `Forward` column |
| Both nodes hold the VIP | VRRP not exchanged (fw/multicast/VRID/auth) | `ip -br addr` on both; `tcpdump vrrp` |
| VIP flaps every few seconds | `advert_int` too low / track weight too big | `journalctl -u keepalived -f` |
| Failover breaks in‑flight connections | No IPVS connection sync | `ipvsadm -Ln --daemon` empty |
| Large TUN transfers hang, small work | MTU / encapsulation black‑hole | DF ping sweep; lower MTU/MSS |
| HAProxy backend `DOWN` but app is up | Health‑check URL/Host/status mismatch | replay `curl` with same Host/path |
| Reload drops connections / refuses SYNs | Old‑style hard restart, no socket transfer | ensure `-sf` + `expose-fd listeners` |
| One source IP overloads one backend | `source`/`sh` hashing behind CGNAT | switch to cookie or `leastconn` |

---

## 7. References

- LPI — Exam 306 Objectives (306‑300, v3.0), Topic 361.2: https://www.lpi.org/our-certifications/exam-306-objectives/
- The Linux Virtual Server Project (LVS) — forwarding methods, scheduling, HOWTOs: http://www.linuxvirtualserver.org/
- LVS‑DR ARP problem and configuration: http://www.linuxvirtualserver.org/docs/arp.html
- Linux kernel IPVS documentation and sysctls: https://docs.kernel.org/networking/ipvs-sysctl.html
- `ipvsadm(8)` manual page: https://man7.org/linux/man-pages/man8/ipvsadm.8.html
- keepalived — official site and documentation: https://www.keepalived.org/
- `keepalived.conf(5)` reference: https://www.keepalived.org/manpage.html
- HAProxy — official site: https://www.haproxy.org/
- HAProxy Configuration Manual: https://docs.haproxy.org/
- HAProxy Management Guide (runtime API / stats socket): https://docs.haproxy.org/2.8/management.html
- RFC 5798 — Virtual Router Redundancy Protocol (VRRP) v3: https://datatracker.ietf.org/doc/html/rfc5798
- RFC 3768 — VRRP v2: https://datatracker.ietf.org/doc/html/rfc3768
- Linux `arp` sysctl (`arp_ignore`, `arp_announce`): https://docs.kernel.org/networking/ip-sysctl.html