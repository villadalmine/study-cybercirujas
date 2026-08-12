# Load Balanced Clusters — Guided Exercises (LPIC-3 306, Topic 361.2)

> **Exam objective 361.2 — Weight 13.34.** These labs cover the two load-balancing stacks the exam tests directly: **LVS/IPVS** (kernel L4 balancer driven by `ipvsadm`, `keepalived`, and `ldirectord`) and **HAProxy** (userspace L4/L7 balancer). You will build each forwarding method (NAT, Direct Routing, Tunneling), drive the connection scheduler by hand, wire health-checked failover with VRRP, and read the runtime state the way an on-call SRE does.
>
> **Reference:** LPI Exam 306 Objectives — https://www.lpi.org/our-certifications/exam-306-objectives/

## Lab topology

All exercises assume this three-node layout on a lab network. Adjust the addresses to your environment, but keep the roles.

```
                         client 192.168.10.50
                                  │
                                  ▼
                        VIP 192.168.10.100
                     ┌────────────────────────┐
                     │  director / lb1         │  eth0 192.168.10.10  (public)
                     │  (LVS or HAProxy)       │  eth1 10.0.0.1/24    (backend)
                     └────────────────────────┘
                          │                 │
              ┌───────────┘                 └───────────┐
              ▼                                          ▼
     rs1 10.0.0.11/24                          rs2 10.0.0.12/24
     nginx/apache :80                          nginx/apache :80
```

- **director / lb1** — the load balancer. Second node `lb2` (same public subnet) is introduced in Exercise 4 for failover.
- **rs1 / rs2** — real servers, each running an HTTP server that returns a distinguishable body. Prepare them once:

```bash
# On rs1 and rs2 (Debian/Ubuntu):
apt-get install -y nginx
echo "Served by $(hostname) — $(hostname -I | awk '{print $1}')" > /var/www/html/index.html
printf 'OK' > /var/www/html/healthz
systemctl enable --now nginx
```

Run every step as `root` (or with `sudo`). Commands are for a modern systemd distro; the `ipvsadm`/`keepalived`/`haproxy` syntax is distribution-agnostic.

---

## Exercise 1 — LVS-NAT with `ipvsadm`

**Goal:** build a Layer-4 virtual service by hand, forward with **NAT (masquerading)**, and read the IPVS runtime table.

1. Install the IPVS administration tool and confirm the kernel module is loadable:

   ```bash
   apt-get install -y ipvsadm      # or: dnf install ipvsadm
   modprobe ip_vs
   lsmod | grep ip_vs
   ```

   Expected (the scheduler modules load on demand):

   ```
   ip_vs                 176128  0
   nf_conntrack          172032  1 ip_vs
   ```

2. IPVS is a *router*: with NAT the director rewrites the destination on the way in and the source on the way out, so the kernel must forward packets between interfaces. Enable it:

   ```bash
   sysctl -w net.ipv4.ip_forward=1
   ```

3. Create the **virtual service** on the VIP with the round-robin scheduler, then attach both real servers in **masquerading** mode:

   ```bash
   ipvsadm -A -t 192.168.10.100:80 -s rr
   ipvsadm -a -t 192.168.10.100:80 -r 10.0.0.11:80 -m -w 1
   ipvsadm -a -t 192.168.10.100:80 -r 10.0.0.12:80 -m -w 1
   ```

   Decode: `-A` add virtual service · `-t` TCP service `VIP:port` · `-s rr` scheduler · `-a` add real server · `-r` real server `IP:port` · `-m` masquerading (NAT) · `-w` weight.

4. Inspect the table:

   ```bash
   ipvsadm -L -n
   ```

   Expected:

   ```
   IP Virtual Server version 1.2.1 (size=4096)
   Prot LocalAddress:Port Scheduler Flags
     -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
   TCP  192.168.10.100:80 rr
     -> 10.0.0.11:80                 Masq    1      0          0
     -> 10.0.0.12:80                 Masq    1      0          0
   ```

5. The return path is the subtle part of NAT. Because the director rewrote the source address of the inbound packet, the reply from a real server must come *back through the director* to be un-NATed. **On each real server, set the director's backend IP as the default gateway:**

   ```bash
   # On rs1 and rs2:
   ip route replace default via 10.0.0.1
   ```

6. From the client, drive traffic and watch it alternate:

   ```bash
   # On the client:
   for i in $(seq 1 6); do curl -s http://192.168.10.100/; done
   ```

   Expected:

   ```
   Served by rs1 — 10.0.0.11
   Served by rs2 — 10.0.0.12
   Served by rs1 — 10.0.0.11
   Served by rs2 — 10.0.0.12
   Served by rs1 — 10.0.0.11
   Served by rs2 — 10.0.0.12
   ```

7. Read the counters and the live connection table:

   ```bash
   ipvsadm -L -n --stats
   ipvsadm -L -n --rate
   ipvsadm -L -n -c            # active connection entries with TCP state
   ```

   `--stats` shows cumulative `Conns / InPkts / OutPkts / InBytes / OutBytes`; `--rate` shows the per-second `CPS / InPPS / OutPPS / InBPS / OutBPS`. `-c` lists individual entries, e.g.:

   ```
   TCP 00:57  FIN_WAIT     192.168.10.50:41522 192.168.10.100:80  10.0.0.11:80
   ```

**Checkpoint 1**

- **Q1.1** Why must `net.ipv4.ip_forward` be `1` for LVS-NAT but conceptually *not* required for LVS-DR (Exercise 2)?
- **Q1.2** In step 5, what breaks if a real server keeps its own router as the default gateway instead of `10.0.0.1`? Trace the packet's source/destination through the return path.
- **Q1.3** In `ipvsadm -L -n`, what is the difference between `ActiveConn` and `InActConn`, and which one would a connection in `FIN_WAIT` land in?

---

## Exercise 2 — LVS Direct Routing (LVS-DR) and the ARP problem

**Goal:** switch the same service to **Direct Routing**, where the director rewrites only the destination MAC and real servers answer the client directly. This is the highest-throughput LVS method and the one with the notorious ARP trap.

1. Rebuild the service in gatewaying mode. `-C` clears everything first:

   ```bash
   ipvsadm -C
   ipvsadm -A -t 192.168.10.100:80 -s wrr
   ipvsadm -a -t 192.168.10.100:80 -r 10.0.0.11:80 -g -w 3
   ipvsadm -a -t 192.168.10.100:80 -r 10.0.0.12:80 -g -w 1
   ```

   `-g` = gatewaying (Direct Routing). Note the `Forward` column now reads `Route`:

   ```bash
   ipvsadm -L -n
   ```

   ```
   TCP  192.168.10.100:80 wrr
     -> 10.0.0.11:80                 Route   3      0          0
     -> 10.0.0.12:80                 Route   1      0          0
   ```

2. In DR the packet that reaches a real server still has **destination IP = VIP** (only the MAC was rewritten). The real server must therefore *own* the VIP to accept the packet — but it must **never ARP for it**, or it will fight the director for ownership on the LAN. Configure the VIP on the loopback and harden the ARP behaviour **on each real server**:

   ```bash
   # On rs1 and rs2:
   ip addr add 192.168.10.100/32 dev lo
   sysctl -w net.ipv4.conf.all.arp_ignore=1
   sysctl -w net.ipv4.conf.all.arp_announce=2
   sysctl -w net.ipv4.conf.lo.arp_ignore=1
   sysctl -w net.ipv4.conf.lo.arp_announce=2
   ```

   - `arp_ignore=1` — reply to an ARP request only if the target IP is configured on the interface the request arrived on. The VIP lives on `lo`, so the real interface stays silent about it.
   - `arp_announce=2` — always source ARP announcements from the best *real* interface address, never the loopback VIP.

3. Because real servers now answer the client directly (bypassing the director on egress), they need a normal route to the client — the director is **not** in the return path:

   ```bash
   # On rs1 and rs2, ensure the public/client network is reachable directly:
   ip route get 192.168.10.50
   ```

4. Drive traffic and confirm the weighted 3:1 split:

   ```bash
   # On the client:
   for i in $(seq 1 8); do curl -s http://192.168.10.100/; done | sort | uniq -c
   ```

   Expected (rs1 gets ~3× rs2's share):

   ```
         6 Served by rs1 — 10.0.0.11
         2 Served by rs2 — 10.0.0.12
   ```

5. Prove the return traffic skips the director. On the director, watch outbound bytes stay near zero even under load:

   ```bash
   ipvsadm -L -n --stats
   ```

   `OutPkts` / `OutBytes` remain 0 (or tiny) because replies never traverse the director in DR mode.

**Checkpoint 2**

- **Q2.1** Explain precisely what the director rewrites in a DR packet vs. a NAT packet.
- **Q2.2** You forgot `arp_ignore`/`arp_announce` on the real servers. Describe the failure symptom the client sees, and why it is often *intermittent*.
- **Q2.3** Why does DR require the real servers to be on the **same physical segment / L2 domain** as the director, while Tunneling (`-i`, IPIP) does not?
- **Q2.4** Why is `OutBytes` on the director ~0 in DR but large in NAT?

---

## Exercise 3 — Connection scheduling algorithms

**Goal:** feel the difference between the schedulers the exam names, and change them without tearing down the service.

1. List the schedulers your kernel supports (each is a module `ip_vs_<algo>`):

   ```bash
   ls /lib/modules/$(uname -r)/kernel/net/netfilter/ipvs/ | grep ip_vs_
   ```

   Expected includes: `ip_vs_rr` (round-robin), `ip_vs_wrr` (weighted RR), `ip_vs_lc` (least-connection), `ip_vs_wlc` (weighted LC), `ip_vs_sh` (source hashing), `ip_vs_dh`, `ip_vs_sed`, `ip_vs_nq`.

2. Change the scheduler **in place** with `-E` (edit virtual service) — connections already tracked are preserved:

   ```bash
   ipvsadm -E -t 192.168.10.100:80 -s lc      # least-connection
   ipvsadm -L -n | head -5
   ```

3. Compare distribution under a slow, concurrent load so connection counts actually differ. Give rs1 a deliberate delay to simulate a slower node, then switch between `rr` and `lc`:

   ```bash
   # On the client, 20 concurrent slow requests:
   ipvsadm -E -t 192.168.10.100:80 -s rr
   seq 1 20 | xargs -P20 -I{} curl -s -m 5 http://192.168.10.100/ >/dev/null &
   watch -n1 'ipvsadm -L -n'      # observe ActiveConn per real server
   ```

   Under `rr` the two servers get an equal *count* of connections regardless of how busy each is. Repeat with `-s lc` and note that new connections steer toward whichever server currently holds fewer `ActiveConn`.

4. Turn on **source hashing** to pin a client to one server (a persistence mechanism that needs no state table):

   ```bash
   ipvsadm -E -t 192.168.10.100:80 -s sh
   # On the client, every request now hits the SAME real server:
   for i in $(seq 1 5); do curl -s http://192.168.10.100/; done
   ```

5. Alternatively, keep a stateful scheduler but add **persistence** so a client sticks for a timeout window:

   ```bash
   ipvsadm -E -t 192.168.10.100:80 -s wlc -p 600
   ipvsadm -L -n            # note the "persistent 600" flag on the service line
   ```

**Checkpoint 3**

- **Q3.1** Under identical weights, when do `lc` and `wlc` behave identically, and when do they diverge?
- **Q3.2** A backend has one 32-core node and one 8-core node. Which scheduler + parameter expresses that, and how?
- **Q3.3** Contrast two ways to make a client always reach the same real server: the `sh` scheduler vs. `-p <timeout>` persistence. What happens to each when a real server is removed?
- **Q3.4** `sed` (shortest expected delay) and `nq` (never queue) both exist. In one sentence each, when would you prefer them over `wlc`?

---

## Exercise 4 — Health-checked failover with `keepalived` (VRRP + IPVS)

**Goal:** replace the hand-built IPVS table with a declarative config that keepalived **programs into IPVS for you**, adds **health checks** that pull dead real servers out automatically, and floats the VIP between two directors with **VRRP**.

1. Install keepalived on **both** `lb1` and `lb2`:

   ```bash
   apt-get install -y keepalived ipvsadm
   ```

2. On **lb1 (MASTER)**, write `/etc/keepalived/keepalived.conf`:

   ```conf
   global_defs {
       router_id LB1
       enable_script_security
   }

   # ---- VRRP: floats the VIP between lb1 and lb2 ----
   vrrp_instance VI_1 {
       state MASTER
       interface eth0
       virtual_router_id 51
       priority 150
       advert_int 1
       authentication {
           auth_type PASS
           auth_pass s3cr3tvr
       }
       virtual_ipaddress {
           192.168.10.100/24 dev eth0
       }
   }

   # ---- IPVS: keepalived programs this into the kernel ----
   virtual_server 192.168.10.100 80 {
       delay_loop 6
       lb_algo wrr
       lb_kind NAT
       protocol TCP

       real_server 10.0.0.11 80 {
           weight 3
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
           TCP_CHECK {
               connect_timeout 3
               connect_port 80
           }
       }
   }
   ```

3. On **lb2 (BACKUP)**, use the *same* file but change three lines — everything else must match:

   ```conf
   global_defs { router_id LB2 }
   vrrp_instance VI_1 {
       state BACKUP
       priority 100
       # interface, virtual_router_id, auth_pass, virtual_ipaddress IDENTICAL to lb1
       ...
   }
   ```

4. Start keepalived on both and confirm the VIP lands on the MASTER:

   ```bash
   systemctl enable --now keepalived
   # On lb1:
   ip -brief addr show eth0 | grep 192.168.10.100      # VIP present
   journalctl -u keepalived -n 20 --no-pager           # "Entering MASTER STATE"
   # On lb2:
   ip -brief addr show eth0 | grep 192.168.10.100      # VIP ABSENT (backup)
   ```

5. Confirm keepalived populated IPVS **without you touching `ipvsadm`**:

   ```bash
   # On lb1:
   ipvsadm -L -n
   ```

   ```
   TCP  192.168.10.100:80 wrr
     -> 10.0.0.11:80                 Masq    3      0          0
     -> 10.0.0.12:80                 Masq    1      0          0
   ```

6. **Trigger a health-check eviction.** Break rs1's health endpoint and watch keepalived remove it from the pool:

   ```bash
   # On rs1:
   mv /var/www/html/healthz /var/www/html/healthz.bak     # /healthz now 404
   ```

   ```bash
   # On lb1, within ~delay_loop*retry seconds:
   journalctl -u keepalived -f
   # ... "Health check failed ... Removing service 10.0.0.11:80"
   ipvsadm -L -n        # rs1 is GONE; all traffic now to rs2
   ```

   Restore it and watch rs1 come back automatically:

   ```bash
   # On rs1:
   mv /var/www/html/healthz.bak /var/www/html/healthz
   # On lb1: "Health check succeeded ... Adding service 10.0.0.11:80"
   ```

7. **Trigger a director failover.** Stop keepalived on lb1 and confirm lb2 seizes the VIP:

   ```bash
   # On lb1:
   systemctl stop keepalived
   # On lb2, within ~3× advert_int:
   ip -brief addr show eth0 | grep 192.168.10.100      # VIP now HERE
   journalctl -u keepalived -n 10 --no-pager           # "Entering MASTER STATE"
   ```

   The client's `curl http://192.168.10.100/` keeps working across the failover.

8. (Reference) For the older `HTTP_GET`/`SSL_GET` **digest** matcher, keepalived compares an MD5 of the fetched page produced by `genhash`:

   ```bash
   genhash -s 10.0.0.11 -p 80 -u /healthz
   # MD5SUM = 0a4d55a8d778e5022fab701977c5d840   (paste into a `digest` line under url {})
   ```

**Checkpoint 4**

- **Q4.1** `virtual_router_id`, `auth_pass`, and the `virtual_ipaddress` must be identical on both nodes, but `priority` and `state` differ. Why each?
- **Q4.2** With `priority 150` (lb1) vs `100` (lb2) and default preemption, what happens to the VIP when lb1 recovers after a failover? How does adding `nopreempt` change it, and why would you want that?
- **Q4.3** Two directors both declare `state MASTER` for the same `virtual_router_id` but with a **firewall dropping VRRP multicast (224.0.0.18)** between them. What is the resulting failure mode called, and what does the client observe?
- **Q4.4** Compare `TCP_CHECK` and `HTTP_GET` for a web backend: what real failure does `HTTP_GET path /healthz status_code 200` catch that `TCP_CHECK` silently passes?
- **Q4.5** keepalived programmed IPVS entirely from config. What did that buy you over the hand-built `ipvsadm` table in Exercises 1–3?

---

## Exercise 5 — HAProxy: L4 and L7 load balancing

**Goal:** stand up the userspace balancer the exam pairs with LVS. You get L7 routing, application-aware health checks, cookie persistence, a stats page, and hitless reloads — at the cost of terminating the connection on the proxy.

1. Install HAProxy on lb1 (stop keepalived's IPVS service first to free port 80 / the VIP, or bind HAProxy to a different address):

   ```bash
   apt-get install -y haproxy socat
   haproxy -v      # confirm 2.x+
   ```

2. Write `/etc/haproxy/haproxy.cfg`:

   ```conf
   global
       log /dev/log local0
       maxconn 20000
       user  haproxy
       group haproxy
       daemon
       stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners

   defaults
       mode    http
       log     global
       option  httplog
       option  dontlognull
       timeout connect 5s
       timeout client  50s
       timeout server  50s
       retries 3

   frontend web_front
       bind *:80
       default_backend web_back

   backend web_back
       balance roundrobin
       option httpchk GET /healthz
       http-check expect status 200
       cookie SRVID insert indirect nocache
       server web1 10.0.0.11:80 check cookie web1 weight 3
       server web2 10.0.0.12:80 check cookie web2 weight 1

   listen stats
       bind *:8404
       stats enable
       stats uri /stats
       stats refresh 10s
       stats admin if TRUE
   ```

3. **Validate the config before loading it** — a syntax error here takes the proxy down:

   ```bash
   haproxy -c -f /etc/haproxy/haproxy.cfg
   ```

   Expected:

   ```
   Configuration file is valid
   ```

4. Start and drive traffic:

   ```bash
   systemctl enable --now haproxy
   for i in $(seq 1 8); do curl -s http://192.168.10.10/; done | sort | uniq -c
   ```

   Weighted 3:1 as configured:

   ```
         6 Served by rs1 — 10.0.0.11
         2 Served by rs2 — 10.0.0.12
   ```

5. **Cookie persistence.** With `cookie SRVID insert`, HAProxy stamps the chosen server into a cookie so the browser sticks. Observe it and prove stickiness with `-c cookies.txt`:

   ```bash
   curl -sI http://192.168.10.10/ | grep -i set-cookie
   # Set-Cookie: SRVID=web1; path=/
   for i in 1 2 3; do curl -s -b "SRVID=web2" http://192.168.10.10/; done
   # All three land on rs2, overriding the roundrobin balance.
   ```

6. **Read runtime state** two ways — the HTML stats page and the admin socket:

   ```bash
   curl -s "http://192.168.10.10:8404/stats;csv" | cut -d, -f1,2,18 | column -s, -t | head
   echo "show stat" | socat stdio /run/haproxy/admin.sock | cut -d, -f1,2,18 | head
   ```

   Column 18 is `status` (`UP`/`DOWN`). You can also drain a server live without editing config:

   ```bash
   echo "set server web_back/web1 state drain" | socat stdio /run/haproxy/admin.sock
   echo "set server web_back/web1 state ready" | socat stdio /run/haproxy/admin.sock
   ```

7. **Trigger the app-layer health check.** Break rs1's `/healthz` and watch HAProxy mark it `DOWN`:

   ```bash
   # On rs1:
   mv /var/www/html/healthz /var/www/html/healthz.bak
   # On lb1:
   watch -n1 'echo "show stat" | socat stdio /run/haproxy/admin.sock | grep web1'
   journalctl -u haproxy -n 5 --no-pager     # "Server web_back/web1 is DOWN"
   ```

8. **Hitless reload.** Change `balance roundrobin` to `balance leastconn`, validate, then reload — established connections are *not* dropped:

   ```bash
   sed -i 's/balance roundrobin/balance leastconn/' /etc/haproxy/haproxy.cfg
   haproxy -c -f /etc/haproxy/haproxy.cfg && systemctl reload haproxy
   journalctl -u haproxy -n 5 --no-pager     # new worker takes over listeners
   ```

9. (L4 mode) To run HAProxy as a pure TCP balancer — e.g. for a database or non-HTTP protocol — switch a listen block to `mode tcp`:

   ```conf
   listen pgsql
       bind *:5432
       mode tcp
       balance leastconn
       option tcp-check
       server db1 10.0.0.21:5432 check
       server db2 10.0.0.22:5432 check backup
   ```

**Checkpoint 5**

- **Q5.1** Architecturally, how does HAProxy's data path differ from LVS-DR? Name one thing HAProxy can do *because* it terminates the connection, and one cost of that termination.
- **Q5.2** With `cookie SRVID insert indirect nocache`, explain what `insert`, `indirect`, and `nocache` each contribute.
- **Q5.3** `option httpchk GET /healthz` + `http-check expect status 200` vs. a plain L4 `check`: what failure class does the HTTP check catch that the L4 check misses? (Same idea as Q4.4 — state it in HAProxy's terms.)
- **Q5.4** Why is `haproxy -c -f ...` a mandatory step before `systemctl reload`, and what specifically makes the reload "hitless"?
- **Q5.5** When would you choose `balance source` over `leastconn`, and what is the failure mode of `balance source` when the server pool size changes?

---

## Exercise 6 — `ldirectord`: the classic LVS health-checker

**Goal:** recognise the tool the exam still lists — `ldirectord` monitors real servers and edits the IPVS table, historically driven by Heartbeat/Pacemaker. keepalived is the modern equivalent; know the config shape.

1. Install and write `/etc/ldirectord.cf`:

   ```bash
   apt-get install -y ldirectord ipvsadm
   ```

   ```conf
   checktimeout=3
   checkinterval=5
   autoreload=yes
   quiescent=yes
   logfile="/var/log/ldirectord.log"

   virtual=192.168.10.100:80
       real=10.0.0.11:80 masq 3
       real=10.0.0.12:80 masq 1
       service=http
       request="/healthz"
       receive="OK"
       scheduler=wrr
       protocol=tcp
       checktype=negotiate
   ```

2. Start it and confirm it programmed IPVS:

   ```bash
   systemctl enable --now ldirectord
   ipvsadm -L -n
   ```

3. Break rs1's `/healthz` (so the body is no longer `OK`) and watch the difference `quiescent` makes:

   ```bash
   # On rs1:
   echo "MAINTENANCE" > /var/www/html/healthz
   # On lb1, with quiescent=yes the server's WEIGHT drops to 0 (kept in table);
   # with quiescent=no it would be REMOVED entirely.
   ipvsadm -L -n
   ```

**Checkpoint 6**

- **Q6.1** With `checktype=negotiate`, what two things must both be true for rs1 to count as healthy, given `request="/healthz"` and `receive="OK"`?
- **Q6.2** Contrast `quiescent=yes` vs `quiescent=no` when a real server fails. Which one avoids resetting the persistence/connection state of *healthy* servers, and why does that matter under load?
- **Q6.3** In one sentence, what is the functional overlap between `ldirectord` and keepalived's `virtual_server` block?

---

## Answers

<details>
<summary>Click to reveal answers</summary>

**Checkpoint 1 — LVS-NAT**

- **A1.1** In NAT the director receives a packet on the public interface and must emit it (after rewriting the destination) on the backend interface — that is *routing between interfaces*, which the kernel refuses unless `ip_forward=1`. In DR the director rewrites only the destination MAC and re-emits the frame on the **same** L2 segment; it is bridging/redirecting at L2 rather than routing between IP subnets, so `ip_forward` is not the gate (though enabling it is harmless and often still set).
- **A1.2** The inbound packet arriving at the real server has `src = client 192.168.10.50`, `dst = rs 10.0.0.11` (destination was DNAT'd by the director; source is untouched). The reply is `src = 10.0.0.11`, `dst = 192.168.10.50`. If the real server sends that reply via some other router, the director never sees it and never rewrites the source back to the VIP. The client then receives a reply from `10.0.0.11:80` for a connection it opened to `192.168.10.100:80`, so its kernel drops it as an out-of-connection packet — the connection hangs and times out. Forcing the default gateway to `10.0.0.1` (the director) puts the reply back through IPVS, which un-NATs the source to the VIP.
- **A1.3** `ActiveConn` counts connections in the ESTABLISHED state (actively passing data); `InActConn` counts connections IPVS is still tracking but that are not established — SYN_RECV, and the various teardown states like FIN_WAIT/TIME_WAIT. A connection in `FIN_WAIT` is counted under **InActConn**.

**Checkpoint 2 — LVS-DR**

- **A2.1** NAT rewrites the packet's **destination IP** on ingress (VIP → real-server IP) and the **source IP** on egress (real-server IP → VIP); the packet is modified at L3 in both directions and must traverse the director both ways. DR rewrites only the **destination MAC address** (director's MAC → real server's MAC); the L3 header, including `dst = VIP`, is left untouched, and the reply never returns through the director.
- **A2.2** Without `arp_ignore`/`arp_announce`, every real server ARP-replies for the VIP that it holds on `lo`. The client/switch's ARP cache is then a race: sometimes the VIP resolves to the director's MAC (works), sometimes to a real server's MAC (traffic bypasses the balancer or breaks). The symptom is intermittent — some connections load-balance correctly, others go straight to one node or fail — and it flips whenever an ARP entry ages out and is re-resolved.
- **A2.3** DR delivers packets by rewriting the L2 destination MAC, which only works if the director can address the real server's MAC directly — i.e. they share a broadcast/L2 domain. Tunneling (`-i`, IPIP) instead **encapsulates** the original packet inside a new IP packet addressed to the real server's routable IP, so the real server can be anywhere reachable by IP (different subnet, different site); it decapsulates and, like DR, replies directly to the client.
- **A2.4** In DR the real servers answer the client directly, so return traffic — which is the bulk of bytes for typical web responses — never passes through the director; `OutBytes` stays ~0. In NAT every reply is un-NATed by the director, so all response bytes traverse it and `OutBytes` grows with the payload, making the director a bandwidth bottleneck.

**Checkpoint 3 — Schedulers**

- **A3.1** With identical weights on all real servers, `wlc` reduces exactly to `lc` — both pick the server with the fewest active connections and the weight term is a constant multiplier. They diverge only when weights differ: `wlc` picks the server minimising `active_conns / weight`, so a higher-weight server is allowed proportionally more connections before it is skipped.
- **A3.2** Weighted schedulers with a 4:1 weight ratio, e.g. `ipvsadm -a ... -r <32core> -w 4` and `-w 1` on the 8-core node (`wrr` or `wlc`). `wrr` distributes new connections in that ratio regardless of load; `wlc` targets the same ratio while also reacting to current active-connection counts.
- **A3.3** `sh` (source hashing) maps `hash(client IP)` to a server deterministically — no per-connection state, and it survives director failover because it is pure computation, but when a real server is added/removed the hash bucketing shifts and many clients get **rehashed to a different server** (stickiness breaks for a large fraction). `-p <timeout>` persistence keeps a per-client template entry in IPVS state so the client sticks for the timeout window across *different* ports/connections; on removal of that client's server the persistence entry is invalidated and the client is rescheduled, affecting only clients pinned to the failed node. Summary: `sh` is stateless but disruptive on pool changes; `-p` is stateful, finer-grained, but costs a state table and doesn't survive a director failover unless synced.
- **A3.4** `sed` (shortest expected delay) minimises `(active+1)/weight`, so it never assigns the very first connection to an idle-but-lower-weight server the way `wlc` might — prefer it when you want new connections biased toward the fastest node even at low load. `nq` (never queue) sends a connection immediately to any server with zero active connections before applying `sed` logic — prefer it to avoid ever letting an idle server sit unused while another queues.

**Checkpoint 4 — keepalived / VRRP**

- **A4.1** `virtual_router_id`, `auth_pass`, and the `virtual_ipaddress` define the shared VRRP group and the resource it protects — both routers must agree on them or they form separate groups / reject each other's adverts / float different addresses. `priority` and `state` are *per-node* role hints: the higher `priority` node becomes MASTER and owns the VIP; `state MASTER`/`BACKUP` only sets the initial role at startup — the election by priority is what actually decides ownership.
- **A4.2** With default preemption, when lb1 (priority 150) recovers it sends adverts, out-priorities lb2 (100), and **takes the VIP back** — causing a second, avoidable failover (a brief blip) just because the higher-priority node returned. `nopreempt` (set on the higher-priority node, which must start in `state BACKUP`) tells it to *not* reclaim the VIP while a healthy MASTER already holds it; the VIP stays on lb2 until lb2 itself fails. You want this to avoid a needless second interruption every time a director reboots.
- **A4.3** With both sides seeing `state MASTER` for the same VRID but VRRP adverts blocked between them, each believes the peer is dead and both claim the VIP → **split brain**. Two hosts answer ARP for the VIP; the client's traffic is delivered inconsistently (duplicate IP, flapping MAC), producing intermittent connectivity, reset connections, and duplicated packets.
- **A4.4** `TCP_CHECK` only opens a TCP connection to port 80 and closes it — it passes as long as the web server *accepts sockets*, even if every request returns 500, serves a stale error page, or the app behind it is deadlocked. `HTTP_GET` with `path /healthz status_code 200` actually issues a request and requires a 200, so it catches an application that accepts connections but can no longer serve valid responses.
- **A4.5** keepalived gave declarative, self-healing management: it programs the whole IPVS table from config (no manual `ipvsadm`), continuously health-checks each real server and adds/removes it automatically, and floats the VIP across two directors via VRRP — turning the static hand-built table into an HA, self-repairing service.

**Checkpoint 5 — HAProxy**

- **A5.1** LVS-DR is a *packet* balancer: it forwards L3/L4 packets by MAC rewriting and never terminates the TCP connection, so it cannot see or act on L7. HAProxy **terminates** the client TCP connection and opens its own to the backend (proxy). Because it terminates, it can do L7 work — route on Host/path, inject/inspect cookies and headers, do HTTP health checks, retries, TLS termination. The cost: every byte flows through HAProxy in both directions (it is on the return path, unlike DR), adding a CPU/latency/throughput bottleneck and a second connection to manage.
- **A5.2** `insert` — HAProxy generates and adds its own `Set-Cookie` naming the chosen server (rather than learning an app cookie). `indirect` — it strips that server cookie from the request before forwarding to the backend, so the application never sees HAProxy's bookkeeping cookie. `nocache` — it adds `Cache-control: private` / prevents a shared cache from storing the personalised `Set-Cookie`, which would otherwise pin *all* cache users to one server.
- **A5.3** A plain L4 `check` only confirms the TCP port accepts a connection; it passes even if the app returns 5xx or a broken page. `option httpchk GET /healthz` + `http-check expect status 200` issues a real HTTP request and requires a 200, catching an application that is listening but unhealthy (deadlocked, dependency down, serving errors). Same failure class as Q4.4, expressed in HAProxy's check syntax.
- **A5.4** `haproxy -c -f` parses and validates the full config; a syntax or semantic error caught here is a safe no-op, whereas the same error discovered *during* a reload can leave the proxy failing to start and drop the service. The reload is "hitless" because HAProxy starts a **new worker** that takes over the listening sockets (via the shared stats socket / `expose-fd listeners` / SO_REUSEPORT), while the old worker keeps serving its established connections until they drain — so no in-flight connection is reset.
- **A5.5** Choose `balance source` (hash of client IP) when you need session stickiness for a protocol/app that has **no cookie** and you can't insert one (e.g. plain TCP, or clients that ignore cookies). Its failure mode: the hash is computed over the current server count, so adding or removing a server **re-hashes a large fraction of clients** to different servers, breaking stickiness for many sessions at once (mitigable with `hash-type consistent`).

**Checkpoint 6 — ldirectord**

- **A6.1** With `checktype=negotiate`, ldirectord performs an actual protocol request: it must (1) successfully fetch the `request` URL (`/healthz`) — connection + response — and (2) find the `receive` string (`OK`) in the returned body. Both the successful fetch **and** the content match are required; a 200 with the wrong body fails.
- **A6.2** With `quiescent=no`, a failed real server is **deleted** from the IPVS table; deleting/re-adding entries can perturb the scheduler and drop the state IPVS holds. With `quiescent=yes`, the failed server is instead set to **weight 0** — kept in the table but assigned no new connections — so existing persistence templates and the connection state of the *healthy* servers are left untouched, and recovery is just a weight bump. Under load, `quiescent=yes` avoids churn and preserves stickiness for clients pinned to the still-healthy nodes.
- **A6.3** Both continuously health-check real servers and program/prune the kernel IPVS table accordingly (`request`/`receive`/`checktype` in ldirectord ≈ `HTTP_GET`/`TCP_CHECK` inside keepalived's `virtual_server` block); keepalived additionally bundles VRRP-based VIP failover, whereas ldirectord relies on Heartbeat/Pacemaker for that.

</details>