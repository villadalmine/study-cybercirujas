# Guided Exercises — Topic 364.4: Network High Availability

> **Scope of this lab.** These exercises build a two-node highly available network front-end using **keepalived**. You will configure a floating VIP with **VRRP**, add service health tracking, drive the kernel's **LVS/IPVS** load balancer directly from keepalived, and finally compare it with **ldirectord**. Every objective term is exercised at least once: `keepalived`, `keepalived.conf`, `vrrp_instance`, `vrrp_script`, `virtual_server`, `real_server`, `VRRP`, and `ldirectord`.
>
> **Reference:** LPI Exam 306 Objectives, 364.4 — https://www.lpi.org/our-certifications/exam-306-objectives/

## Lab topology

| Role | Host | Real IP | Notes |
|---|---|---|---|
| Director / Load balancer (primary) | `lb1` | `192.0.2.11` | keepalived MASTER |
| Director / Load balancer (secondary) | `lb2` | `192.0.2.12` | keepalived BACKUP |
| Real server A | `rs1` | `192.0.2.21` | HTTP backend |
| Real server B | `rs2` | `192.0.2.22` | HTTP backend |
| **Floating VIP** | — | `192.0.2.100` | Service address, owned by whichever director is MASTER |

Addresses use the `192.0.2.0/24` documentation range (RFC 5737). Run everything in disposable VMs or network namespaces — VRRP claims a real IP on the segment and moving it around a shared LAN will disrupt other hosts.

**Prerequisites on both `lb1` and `lb2`:** a Debian/Ubuntu or RHEL-family system with root, `iproute2`, and outbound package access. The `eth0` interface below is the shared LAN NIC — substitute your predictable name (`ens3`, `enp1s0`, …) throughout.

---

## Exercise 1 — Install keepalived and prepare the kernel

Run every step on **both** `lb1` and `lb2` unless told otherwise.

1. Install keepalived and the IPVS administration tool:

   ```bash
   # Debian / Ubuntu
   sudo apt-get update && sudo apt-get install -y keepalived ipvsadm

   # RHEL / Rocky / Alma
   sudo dnf install -y keepalived ipvsadm
   ```

2. Confirm the IPVS kernel module is available and load it:

   ```bash
   sudo modprobe ip_vs
   lsmod | grep -E '^ip_vs'
   ```

   Expected:

   ```
   ip_vs                 172032  0
   nf_conntrack          172032  1 ip_vs
   ```

3. Enable the routing and binding sysctls the director needs. Create `/etc/sysctl.d/99-lvs.conf`:

   ```ini
   net.ipv4.ip_forward = 1
   net.ipv4.ip_nonlocal_bind = 1
   ```

   Apply and verify:

   ```bash
   sudo sysctl --system
   sysctl net.ipv4.ip_forward net.ipv4.ip_nonlocal_bind
   ```

   Expected:

   ```
   net.ipv4.ip_forward = 1
   net.ipv4.ip_nonlocal_bind = 1
   ```

4. Confirm the empty IPVS table and the keepalived binary version:

   ```bash
   sudo ipvsadm -Ln
   keepalived --version 2>&1 | head -n 1
   ```

   Expected:

   ```
   IP Virtual Server version 1.2.1 (size=4096)
   Prot LocalAddress:Port Scheduler Flags
     -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
   Keepalived v2.2.8 (04/04,2023)
   ```

**Comprehension check**

- **Q1.1** — keepalived bundles three logically distinct daemons/frameworks. Name them and say which one is exercised purely by owning the VIP.
- **Q1.2** — Why is `net.ipv4.ip_nonlocal_bind = 1` useful on a load balancer even though the VIP may live on the *other* node right now?
- **Q1.3** — `ip_vs` is a *kernel* module, yet `keepalived` is a *userspace* daemon. What is the division of labour between them for a `virtual_server`?

---

## Exercise 2 — A floating VIP with VRRP (active/passive)

1. On **`lb1`** write `/etc/keepalived/keepalived.conf`:

   ```
   global_defs {
       router_id LB1
       enable_script_security
       script_user root
   }

   vrrp_instance VI_1 {
       state MASTER
       interface eth0
       virtual_router_id 51
       priority 150
       advert_int 1

       authentication {
           auth_type PASS
           auth_pass Str0ngPass
       }

       virtual_ipaddress {
           192.0.2.100/24 dev eth0
       }
   }
   ```

2. On **`lb2`** write the same file, changing only the three node-specific lines:

   ```
   global_defs {
       router_id LB2
       enable_script_security
       script_user root
   }

   vrrp_instance VI_1 {
       state BACKUP
       interface eth0
       virtual_router_id 51
       priority 100
       advert_int 1

       authentication {
           auth_type PASS
           auth_pass Str0ngPass
       }

       virtual_ipaddress {
           192.0.2.100/24 dev eth0
       }
   }
   ```

3. Validate the syntax before starting (keepalived ≥ 2.0.7):

   ```bash
   sudo keepalived -t -f /etc/keepalived/keepalived.conf && echo "config OK"
   ```

4. Start and enable the service on both nodes, then watch the state machine on `lb1`:

   ```bash
   sudo systemctl enable --now keepalived
   sudo journalctl -u keepalived -f
   ```

   Expected on `lb1`:

   ```
   Keepalived_vrrp[1234]: (VI_1) Entering MASTER STATE
   Keepalived_vrrp[1234]: (VI_1) setting VIPs.
   ```

   Expected on `lb2`:

   ```
   Keepalived_vrrp[1250]: (VI_1) Entering BACKUP STATE
   ```

5. Confirm the VIP is present **only** on `lb1`:

   ```bash
   ip -brief addr show eth0
   ```

   Expected on `lb1`:

   ```
   eth0   UP   192.0.2.11/24 192.0.2.100/24
   ```

   Expected on `lb2` (no VIP):

   ```
   eth0   UP   192.0.2.12/24
   ```

6. Trigger a failover by stopping keepalived on the master:

   ```bash
   # on lb1
   sudo systemctl stop keepalived
   ```

   Within ~`3 × advert_int` seconds, confirm `lb2` claimed the VIP:

   ```bash
   # on lb2
   ip -brief addr show eth0
   journalctl -u keepalived -n 3 --no-pager
   ```

   Expected on `lb2`:

   ```
   eth0   UP   192.0.2.12/24 192.0.2.100/24
   (VI_1) Entering MASTER STATE
   ```

7. Restart keepalived on `lb1` and observe that it **preempts** (reclaims MASTER because its priority is higher):

   ```bash
   sudo systemctl start keepalived   # on lb1
   ```

**Comprehension check**

- **Q2.1** — Two independent VRRP clusters share one LAN segment. What single directive *must* differ between them, and what breaks if it collides?
- **Q2.2** — The backup declared `priority 100` and `state BACKUP`. If you set `state BACKUP` on *both* nodes but kept the 150/100 priorities, would the correct node still become MASTER? Why?
- **Q2.3** — Roughly how long was the VIP unreachable during step 6, and which directive controls that window?
- **Q2.4** — In step 7 `lb1` took the VIP back automatically. Which VRRP behaviour is that, and which directive disables it? Give one reason you'd disable it in production.
- **Q2.5** — The VIP is written `192.0.2.100/24 dev eth0`. What does keepalived send on the wire the instant it becomes MASTER so that switches and peers update their forwarding tables?

---

## Exercise 3 — Health-tracked VRRP with `vrrp_script` (service-aware failover)

A director that still owns the VIP after its front-end service has crashed is a black hole. Here keepalived tracks a local service and *demotes itself* when the service is down. We track `haproxy` as the representative front-end (install it or substitute any service you can stop).

1. On **both** nodes add a tracking script and bind it to the instance. Edit `/etc/keepalived/keepalived.conf`, inserting the `vrrp_script` block above `vrrp_instance` and a `track_script` block inside it:

   ```
   vrrp_script chk_haproxy {
       script "/usr/bin/killall -0 haproxy"   # exit 0 if the process exists
       interval 2                              # run every 2 s
       timeout 3
       fall 2                                  # 2 failures ⇒ KO
       rise 2                                  # 2 successes ⇒ OK
       weight -60                              # subtract 60 from priority on KO
   }

   vrrp_instance VI_1 {
       state MASTER            # BACKUP on lb2
       interface eth0
       virtual_router_id 51
       priority 150            # 100 on lb2
       advert_int 1

       authentication {
           auth_type PASS
           auth_pass Str0ngPass
       }

       virtual_ipaddress {
           192.0.2.100/24 dev eth0
       }

       track_script {
           chk_haproxy
       }
   }
   ```

2. Reload keepalived (no need to restart) and confirm the script is registered:

   ```bash
   sudo systemctl reload keepalived
   journalctl -u keepalived -n 5 --no-pager
   ```

   Expected (script starts in the correct state):

   ```
   Keepalived_vrrp[1234]: (VI_1) Entering MASTER STATE
   Keepalived_vrrp[1234]: VRRP_Script(chk_haproxy) succeeded
   ```

3. On `lb1`, ensure `lb1` currently holds the VIP, then **kill the tracked service** and watch the priority collapse:

   ```bash
   sudo systemctl stop haproxy        # or: sudo killall haproxy
   sudo journalctl -u keepalived -f
   ```

   Expected on `lb1`:

   ```
   VRRP_Script(chk_haproxy) failed
   (VI_1) Changing effective priority from 150 to 90
   (VI_1) Master received advert from 192.0.2.12 with higher priority 100, ours 90
   (VI_1) Entering BACKUP STATE
   ```

4. Confirm the VIP migrated to `lb2` even though keepalived is still *running* on `lb1`:

   ```bash
   ip -brief addr show eth0   # on lb1: VIP gone; on lb2: VIP present
   ```

5. Recover the service on `lb1` and confirm the VIP returns:

   ```bash
   sudo systemctl start haproxy
   ```

   Expected: `chk_haproxy` rises, effective priority returns to 150, `lb1` preempts back to MASTER.

**Comprehension check**

- **Q3.1** — Base priorities are 150 (`lb1`) and 100 (`lb2`), and the gap is 50. Explain precisely why a `weight` of `-60` forces a failover but `weight -20` would *not*.
- **Q3.2** — What is the difference in behaviour between `weight 0` (the default) and a non-zero `weight` when the script fails?
- **Q3.3** — `killall -0 haproxy` only proves the *process exists*. Name a failure mode this check misses, and describe a better `script` for it.
- **Q3.4** — What do `fall 2` / `rise 2` protect against, and what is the trade-off of raising them?
- **Q3.5** — Why does `enable_script_security` matter here, and what does keepalived refuse to do if the script file is group- or world-writable?

---

## Exercise 4 — Driving LVS/IPVS from keepalived (`virtual_server` / `real_server`)

Now keepalived programs the kernel's IPVS table directly and health-checks the backends. This replaces the "track a local HAProxy" model with a Layer-4 director. Prepare `rs1`/`rs2` to serve HTTP on port 80 (e.g. `python3 -m http.server 80` behind a `/` that returns 200), then configure the directors.

1. On **both** directors, append a `virtual_server` block to `/etc/keepalived/keepalived.conf`:

   ```
   virtual_server 192.0.2.100 80 {
       delay_loop 6
       lb_algo wrr
       lb_kind DR
       persistence_timeout 50
       protocol TCP

       real_server 192.0.2.21 80 {
           weight 3
           HTTP_GET {
               url {
                   path /health
                   status_code 200
               }
               connect_timeout 3
               retry 3
               delay_before_retry 3
           }
       }

       real_server 192.0.2.22 80 {
           weight 1
           TCP_CHECK {
               connect_timeout 3
               connect_port 80
           }
       }
   }
   ```

2. Reload and confirm keepalived populated the IPVS table **on the current MASTER only**:

   ```bash
   sudo systemctl reload keepalived
   sudo ipvsadm -Ln
   ```

   Expected on the MASTER:

   ```
   IP Virtual Server version 1.2.1 (size=4096)
   Prot LocalAddress:Port Scheduler Flags
     -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
   TCP  192.0.2.100:80 wrr persistent 50
     -> 192.0.2.21:80                Route   3      0          0
     -> 192.0.2.22:80                Route   1      0          0
   ```

3. Generate traffic from a client and watch the connection table and scheduling:

   ```bash
   for i in $(seq 1 8); do curl -s http://192.0.2.100/ >/dev/null; done
   sudo ipvsadm -Lnc          # per-connection state
   sudo ipvsadm -Ln --stats   # aggregate counters
   ```

4. Take one backend out of service and confirm keepalived **ejects it from the IPVS table**:

   ```bash
   # on rs1
   sudo systemctl stop http-backend      # or kill the listener
   # on the director
   sudo journalctl -u keepalived -n 5 --no-pager
   sudo ipvsadm -Ln
   ```

   Expected on the director:

   ```
   Keepalived_healthcheckers: Health check for [192.0.2.21]:80 failed. Removing from server pool.
   TCP  192.0.2.100:80 wrr persistent 50
     -> 192.0.2.22:80                Route   1      0          0
   ```

5. Bring `rs1` back and confirm it is re-added automatically once the `HTTP_GET` check passes again.

**Comprehension check**

- **Q4.1** — The `Forward` column reads `Route`. What `lb_kind` produced that, and what would the column show for the other two forwarding methods?
- **Q4.2** — In step 2 the IPVS table appeared on the MASTER but *not* the BACKUP, even though both configs are identical. Why? What ties the `virtual_server` lifecycle to VRRP state?
- **Q4.3** — With `lb_algo wrr` and weights 3/1, how are ten new connections distributed? How would `lc` differ?
- **Q4.4** — `persistence_timeout 50` appears as `persistent 50`. What client property does it pin to a backend, and name one application that breaks without it and one problem it can cause.
- **Q4.5** — For `lb_kind DR`, what two things must be configured on **each real server** for direct routing to work at all? (Hint: the VIP and ARP.)
- **Q4.6** — A real server was healthy but is now missing from `ipvsadm -Ln`. Give the ordered command sequence you'd run on the director *and* the backend to distinguish "backend down" from "health-check misconfigured."

---

## Exercise 5 — Notification scripts and state observability

Operators need to *know* when a node changes role. keepalived runs a hook on every transition.

1. On both nodes create `/etc/keepalived/notify.sh` (mode `0750`, owned by root):

   ```bash
   #!/bin/bash
   # $1 = "INSTANCE"/"GROUP", $2 = name, $3 = state (MASTER|BACKUP|FAULT), $4 = priority
   TYPE=$1; NAME=$2; STATE=$3
   logger -t keepalived-notify "VRRP ${TYPE} ${NAME} -> ${STATE}"
   case "$STATE" in
       MASTER) logger -t keepalived-notify "Now MASTER: starting VIP-bound duties" ;;
       BACKUP) logger -t keepalived-notify "Now BACKUP: standing down" ;;
       FAULT)  logger -t keepalived-notify "FAULT: local checks failing" ;;
   esac
   ```

   ```bash
   sudo chown root:root /etc/keepalived/notify.sh
   sudo chmod 0750 /etc/keepalived/notify.sh
   ```

2. Reference the scripts inside `vrrp_instance VI_1` (add these lines and reload):

   ```
       notify_master "/etc/keepalived/notify.sh INSTANCE VI_1 MASTER"
       notify_backup "/etc/keepalived/notify.sh INSTANCE VI_1 BACKUP"
       notify_fault  "/etc/keepalived/notify.sh INSTANCE VI_1 FAULT"
       notify        "/etc/keepalived/notify.sh"
   ```

3. Force a transition (stop keepalived on the master) and read the messages back:

   ```bash
   sudo journalctl -t keepalived-notify -n 10 --no-pager
   ```

   Expected on the promoted backup:

   ```
   keepalived-notify: VRRP INSTANCE VI_1 -> MASTER
   keepalived-notify: Now MASTER: starting VIP-bound duties
   ```

**Comprehension check**

- **Q5.1** — Distinguish `notify_master`, `notify_backup`, and `notify_fault`. Which fires when a `track_script` with `weight 0` fails?
- **Q5.2** — A notify script that takes 30 s to return is dangerous. What is the risk to the VRRP state machine, and how should long-running actions be launched instead?
- **Q5.3** — You want the *backup* to keep HAProxy stopped and only start it on promotion (true active/passive for a service that can't run twice). Sketch how `notify_master`/`notify_backup` implement that.

---

## Exercise 6 — ldirectord as an alternative real-server health checker

Before keepalived absorbed LVS management, the classic Linux-HA stack paired **ldirectord** (from `resource-agents`) with Heartbeat/Pacemaker to maintain the IPVS table. You should recognise its configuration.

1. Install ldirectord (package `ldirectord` on Debian; part of `resource-agents` on RHEL):

   ```bash
   sudo apt-get install -y ldirectord      # Debian/Ubuntu
   ```

2. Create `/etc/ha.d/ldirectord.cf`:

   ```
   checktimeout=3
   checkinterval=5
   autoreload=yes
   quiescent=no
   logfile="/var/log/ldirectord.log"

   virtual=192.0.2.100:80
       real=192.0.2.21:80 gate 3
       real=192.0.2.22:80 gate 1
       service=http
       request="/health"
       receive="OK"
       scheduler=wrr
       protocol=tcp
       checktype=negotiate
   ```

3. Run it in the foreground to program IPVS, then inspect the table:

   ```bash
   sudo ldirectord -d /etc/ha.d/ldirectord.cf start
   sudo ipvsadm -Ln
   ```

   Expected: the same `192.0.2.100:80 wrr` table, `gate` meaning direct-routing (the `Route` forwarder).

> **Do not run ldirectord and a keepalived `virtual_server` against the same VIP at once** — both write the IPVS table and will fight. Stop keepalived's virtual_server (or run this on an isolated node).

**Comprehension check**

- **Q6.1** — Map these ldirectord keywords to their keepalived equivalents: `gate`, `checktype=negotiate`, `request`/`receive`, `quiescent=yes`, `scheduler=wrr`.
- **Q6.2** — `quiescent=yes` vs `quiescent=no`: what does each do to a failed real server in the IPVS table, and why does `quiescent=yes` help long-lived connections?
- **Q6.3** — Architecturally, what does ldirectord *not* provide that keepalived does, forcing ldirectord to be paired with Heartbeat/Pacemaker for a complete HA solution?

---

<details>
<summary><strong>Answer key</strong></summary>

### Exercise 1

**A1.1** — keepalived contains (1) a **VRRP framework** for IP failover, (2) a **health-checking framework** (`checkers`) that probes real servers, and (3) an **IPVS control layer** that programs the kernel's LVS table. Owning a floating VIP with `vrrp_instance` exercises only the **VRRP framework** — no health checkers or IPVS are needed for a bare VIP.

**A1.2** — With `ip_nonlocal_bind = 1`, a userspace service (HAProxy, nginx) may `bind()` to the VIP even when that address is *not currently* on any local interface — i.e. while the node is BACKUP. Without it the service fails to start on the backup and can't be pre-warmed, and in active/active designs a node couldn't bind a VIP that lives on its peer.

**A1.3** — The **kernel `ip_vs` module does the actual packet forwarding/scheduling** at Layer 4 (matches VIP:port, picks a real server by the scheduler, rewrites/encapsulates/routes the packet). **keepalived (userspace) only manages the table**: it adds/removes `virtual_server`/`real_server` entries and runs the health checks that decide membership. keepalived never sees the data-plane packets.

### Exercise 2

**A2.1** — `virtual_router_id` (the VRID) must be unique per VRRP domain on a segment. If two clusters share the same VRID *and* interface, their advertisements are mutually interpreted as belonging to one virtual router; the wrong nodes participate in the same election, causing split-brain or a flapping VIP. (`auth_pass` differing is not enough — modern VRRPv3 ignores authentication.)

**A2.2** — Yes. `state` is only the **initial** state a node advertises at startup; the steady-state MASTER is decided by the **election**, which the higher `priority` (150) wins regardless of the declared `state`. `state MASTER` merely lets that node assume the role immediately instead of waiting to hear a lower-priority peer.

**A2.3** — Roughly **3 × `advert_int` ≈ 3 seconds** (the master-down interval: the backup declares the master dead after it misses ~3 advertisement periods). It's governed by `advert_int` (default 1 s). Lowering it speeds failover but risks false failovers on a congested LAN.

**A2.4** — That is **preemption** (the default): a higher-priority node reclaims MASTER when it returns. Disable it with `nopreempt` (and set `state BACKUP` on that node). You disable it to avoid a **second, unnecessary outage** — when the recovered node preempts, the VIP moves again and connections/persistence tables reset, so many operators prefer the current MASTER to keep serving.

**A2.5** — A **gratuitous ARP** (GARP) for the VIP (and unsolicited NDP for IPv6). It updates the CAM/ARP tables of switches and neighbours so frames for `192.0.2.100` now go to the new MASTER's MAC.

### Exercise 3

**A3.1** — keepalived computes an **effective priority = base priority + weight-adjustment**. A negative `weight` is added (i.e. subtracted) **only when the script is KO**. So on failure `lb1` becomes `150 − 60 = 90`, which is **below** `lb2`'s 100 → failover. With `weight -20`, `lb1` on failure is `150 − 20 = 130`, still **above** 100 → no failover. The magnitude of the (negative) weight must exceed the base-priority gap of 50 to cross the peer.

**A3.2** — With `weight 0` (default), a failing `track_script` drives the whole `vrrp_instance` straight into **FAULT** state (it relinquishes MASTER unconditionally). With a non-zero `weight`, the failure instead **adjusts the effective priority** and lets the normal election decide — so a demotion happens only if the adjusted priority actually falls below a healthy peer.

**A3.3** — `killall -0` only signals that a process with that name exists; it misses a **hung/deadlocked service that is listening but not serving** (accepts no requests, returns errors, or wrong content). A better check actually exercises the service, e.g. `script "/usr/bin/curl -fsS -o /dev/null http://127.0.0.1/health"` (non-zero exit on any non-2xx/timeout).

**A3.4** — `fall`/`rise` require **N consecutive results before a state change**, damping **flapping** from a transient blip (one slow probe won't trigger failover; one lucky probe won't declare recovery). The trade-off: higher values add latency — `fall N × interval` extra seconds before a genuinely dead service triggers failover.

**A3.5** — `enable_script_security` makes keepalived **refuse to run any script that is writable by non-root** (or located in a writable path) when it would otherwise run as root, closing a privilege-escalation hole. If `notify.sh` / the check script is group- or world-writable, keepalived logs a security error and **skips executing it** (or drops privileges), because a lower-privileged user could otherwise inject commands run as root.

### Exercise 4

**A4.1** — `Route` is produced by **`lb_kind DR`** (direct routing). The others: `lb_kind NAT` → **`Masq`**, `lb_kind TUN` → **`Tunnel`** (IP-IP encapsulation).

**A4.2** — keepalived only programs the IPVS `virtual_server` while the associated `vrrp_instance` is **MASTER**; on a BACKUP node it withdraws the entries (or never installs them). This avoids two directors owning the same IPVS table for one VIP. (When `virtual_server` isn't explicitly bound to an instance, keepalived still ties the LVS table to VRRP mastership for the VIP it serves.)

**A4.3** — `wrr` (weighted round robin) with weights 3:1 hands out connections in a **3-to-1 ratio** regardless of load — roughly `rs1, rs1, rs1, rs2, rs1, rs1, rs1, rs2, …` (≈7 to `rs1`, ≈3 to `rs2` over ten). `lc`/`wlc` (weighted least-connections) instead sends each new connection to the backend with the **fewest active connections** (scaled by weight), adapting to real load and long-lived sessions rather than a fixed cadence.

**A4.4** — It pins by **client source IP** (all connections from one client go to the same real server for the timeout window). Applications needing it: anything with **server-side session state not shared across backends** (e.g. a stateful shopping cart, some FTP-data setups). Downside: it **defeats even load distribution** — a large NAT/proxy behind one source IP lands entirely on one backend, and rebalancing after a backend returns is delayed.

**A4.5** — On each real server: (1) the **VIP must be configured on a non-ARPing interface** (typically the loopback, `lo`, as `192.0.2.100/32`) so it can accept packets addressed to the VIP, and (2) **ARP suppression** for the VIP (`arp_ignore=1`, `arp_announce=2` on the relevant interfaces) so the real servers do **not** answer ARP for the VIP and steal it from the director.

**A4.6** — On the director: `ipvsadm -Ln` (confirm it's gone), then `journalctl -u keepalived | grep 192.0.2.21` (was it a check failure or removed for another reason?). Reproduce the exact keepalived check **from the director** against the backend — `curl -fsS http://192.0.2.21:80/health` (for `HTTP_GET`) or `nc -zv 192.0.2.21 80` (for `TCP_CHECK`). On the backend: `ss -ltnp | grep :80` (is it listening?) and `curl -fsS http://127.0.0.1/health`. If the local curl works but the director's fails → network/firewall or a wrong `path`/`status_code` in the check config; if the local curl also fails → backend genuinely down.

### Exercise 5

**A5.1** — `notify_master` runs when the instance **becomes MASTER**, `notify_backup` when it **transitions to BACKUP**, `notify_fault` when it enters **FAULT** (local check/interface failure). A `track_script` with `weight 0` failing drives the instance to **FAULT**, so **`notify_fault`** fires (not `notify_backup`).

**A5.2** — keepalived runs notify hooks in a way that can **stall the VRRP state machine / delay processing of advertisements**, so a 30 s script can cause missed adverts, false transitions, or split-brain. Long-running actions must be **backgrounded** (fork/`&`, `systemd-run`, or enqueue a job) so the hook returns in milliseconds.

**A5.3** — Keep HAProxy **disabled/stopped** by default so BACKUP nodes don't run it. In `notify_master`, `systemctl start haproxy`; in `notify_backup` (and `notify_fault`), `systemctl stop haproxy`. Result: exactly the node holding the VIP runs the service — genuine active/passive for a service that must not run in two places.

### Exercise 6

**A6.1** — `gate` → `lb_kind DR`; `checktype=negotiate` → an application-layer check like `HTTP_GET` (fetch and validate content) rather than a bare `TCP_CHECK` (`checktype=connect`); `request`/`receive` → keepalived's `url { path … }` plus expected `status_code`/`digest`; `quiescent=yes` → keepalived's `inhibit_on_failure` (set weight 0 instead of removing); `scheduler=wrr` → `lb_algo wrr`.

**A6.2** — `quiescent=no` **removes** a failed real server from the IPVS table (its entry disappears). `quiescent=yes` **keeps the entry but sets its weight to 0**, so no *new* connections are scheduled to it while **existing established connections survive** — better for long-lived sessions, which a hard removal would drop.

**A6.3** — ldirectord manages only the **IPVS table and real-server health**; it provides **no VIP failover between directors** (no VRRP/heartbeat of its own). It must be paired with **Heartbeat/Pacemaker** to move the VIP and start/stop ldirectord on the surviving node. keepalived bundles that VRRP layer itself, so a single daemon covers both director failover and backend health checking.

</details>

**Sources**
- LPI Exam 306 Objectives (364.4 Network High Availability) — https://www.lpi.org/our-certifications/exam-306-objectives/
- keepalived — configuration & man pages: https://keepalived.readthedocs.io/en/latest/ and https://www.keepalived.org/manpage.html
- Linux Virtual Server / `ipvsadm`: http://www.linuxvirtualserver.org/ (`man 8 ipvsadm`)
- VRRP v3 — RFC 5798: https://www.rfc-editor.org/rfc/rfc5798
- ldirectord — ClusterLabs `resource-agents`: https://github.com/ClusterLabs/resource-agents (`man 8 ldirectord`)