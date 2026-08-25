# 334.3 — Packet Filtering

**LPIC-3 303 (Security), exam 303-300 v3.0.0 — Topic 334: Network Security**
**Weight: 8.33** — one of the heaviest single objectives in the exam, and the one with the widest gap between "passes the exam" and "survives production".

---

## 0. Scope map: what the objective actually demands

| Knowledge area (LPI) | Where it is covered here | Production stake |
|---|---|---|
| Common firewall architectures, incl. DMZ | §10 | Blast-radius containment |
| netfilter, iptables, ip6tables — modules, matches, targets | §2, §3 | The exam's core |
| Packet filtering for IPv4 **and** IPv6 | §3.6 | ICMPv6 mistakes break the network silently |
| Connection tracking and NAT | §4, §5 | The #1 source of firewall outages |
| Define IP sets and use them in netfilter rules | §6 | O(1) vs O(N) rule evaluation |
| Basic knowledge of nftables and `nft` | §7 | Already the default on RHEL 9+/Debian 11+ |
| Basic knowledge of `ebtables` | §8 | KVM/libvirt/Docker bridge plane |
| Awareness of `conntrackd` | §9 | Stateful HA failover |

**Terms and utilities:** `iptables`, `ip6tables`, `iptables-save`, `iptables-restore`, `ip6tables-save`, `ip6tables-restore`, `ipset`, `nft`, `ebtables`.

---

## 1. The architectural problem

A packet filter is not "a list of allow/deny rules". In a production platform it is a **stateful, distributed, single-point-of-failure control plane that sits in the datapath of every byte your business moves**. Three properties collide:

1. **It is in the hot path.** Every rule you add costs CPU cycles per packet. A 3 000-rule linear chain at 1 Mpps is not a policy problem, it is a capacity problem.
2. **It holds state.** Connection tracking means the firewall is *not* idempotent across restarts, and *not* stateless across HA failover. A flushed conntrack table drops every established connection on the box.
3. **It is edited by more than one owner.** On a modern node the ruleset is co-authored by you, `firewalld`, `dockerd`, `kube-proxy`, `cilium`, `fail2ban`, and your configuration-management tool. All of them write to the same kernel object.

The failure modes that actually page an SRE at 03:00 are almost never "the wrong port was open". They are:

| Failure mode | Symptom | Root cause |
|---|---|---|
| conntrack table full | Random connection resets, `nf_conntrack: table full, dropping packet` in `dmesg` | `nf_conntrack_max` sized for 2 GB RAM on a 128 GB box |
| Asymmetric routing + `INVALID` drop | Long-lived TCP flows die after ~seconds, short ones work | Return path bypasses the firewall; conntrack sees only half the stream |
| ICMPv6 blanket drop | IPv6 "works" then hangs on large transfers | PMTUD blackhole (`packet-too-big` filtered), NDP broken |
| SNAT port exhaustion | `insert_failed` climbing, intermittent connect timeouts | Single SNAT source IP, ~64 k tuple ceiling per destination |
| Non-atomic rule reload | 200 ms window where policy is `DROP` with no `ACCEPT` rules | `iptables -F` followed by a loop of `iptables -A` |
| Ruleset clobbered by an agent | Policy reverts after a container restart | Rules written to `FORWARD` instead of `DOCKER-USER` |

Everything below is organised around preventing those six.

---

## 2. Netfilter architecture: the packet path

### 2.1 The five hooks

Netfilter is a set of **hook points** in the kernel's L3 stack. Every framework — `iptables`, `nftables`, `ipvs`, `conntrack`, `ebtables` — is a consumer registering callbacks at these hooks with a numeric **priority** (lower runs first).

```
                         ┌──────────────────┐
   NIC ──▶ [netdev/ingress] ──▶ PREROUTING ──▶│ routing decision │
                                              └────────┬─────────┘
                                       ┌───────────────┴───────────────┐
                                       ▼                               ▼
                                 (for this host)                 (for elsewhere)
                                    INPUT                          FORWARD
                                       │                               │
                                       ▼                               │
                                 local process                         │
                                       │                               │
                                       ▼                               │
                                    OUTPUT                             │
                                       │                               │
                                       └──────────┬────────────────────┘
                                                  ▼
                                            POSTROUTING ──▶ [netdev/egress] ──▶ NIC
```

### 2.2 Table priorities — the traversal order you must be able to recite

| Priority | Symbolic name | iptables table | nftables name | Hooks |
|---:|---|---|---|---|
| −400 | `NF_IP_PRI_RAW_BEFORE_DEFRAG` | — | `raw -300 -100` | — |
| −400 | — | — | — | defrag runs here |
| −300 | `NF_IP_PRI_RAW` | `raw` | `raw` | PREROUTING, OUTPUT |
| −200 | `NF_IP_PRI_CONNTRACK` | *(conntrack)* | — | PREROUTING, OUTPUT |
| −150 | `NF_IP_PRI_MANGLE` | `mangle` | `mangle` | all five |
| −100 | `NF_IP_PRI_NAT_DST` | `nat` (DNAT) | `dstnat` | PREROUTING, OUTPUT |
| 0 | `NF_IP_PRI_FILTER` | `filter` | `filter` | INPUT, FORWARD, OUTPUT |
| 50 | `NF_IP_PRI_SECURITY` | `security` | `security` | INPUT, FORWARD, OUTPUT |
| 100 | `NF_IP_PRI_NAT_SRC` | `nat` (SNAT) | `srcnat` | POSTROUTING, INPUT |
| `INT_MAX`−1 | `NF_IP_PRI_CONNTRACK_CONFIRM` | *(conntrack)* | — | POSTROUTING, INPUT |

Four consequences that the exam and production both test:

1. **`raw` is the only place you can act before conntrack.** That is why `NOTRACK` and `CT --helper` live there.
2. **DNAT happens before the routing decision** (PREROUTING, −100 < routing), so a DNAT'd packet is routed to its *new* destination. **SNAT happens after** (POSTROUTING), so `filter/FORWARD` still sees the original source.
3. **NAT is evaluated only on the first packet of a flow** (`ctstate NEW`). Every subsequent packet is transformed by conntrack from the stored tuple. Adding a NAT rule does *not* affect flows already established.
4. **Conntrack "confirms" the entry at the very end.** A conntrack entry created in PREROUTING is not visible to `conntrack -L` until the packet survives to POSTROUTING/INPUT.

### 2.3 Where `tcpdump` taps — and why it lies to you

`AF_PACKET` (tcpdump) attaches at the **device layer**:

* **Ingress:** after the driver, **before** all netfilter L3 hooks (but after `tc`/`netdev` ingress).
* **Egress:** after POSTROUTING, immediately before the driver.

Therefore: **a packet dropped in `INPUT` still appears in `tcpdump -i eth0`.** Seeing the SYN arrive proves the wire is fine and proves nothing about your ruleset. Conversely, an egress `tcpdump` showing the post-SNAT address is expected.

```console
$ tcpdump -ni eth0 -c 4 'tcp port 22 and host 198.51.100.7'
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
14:22:03.114512 IP 198.51.100.7.41234 > 203.0.113.10.22: Flags [S], seq 2847193021, win 64240, options [mss 1460,sackOK,TS val 91827364 ecr 0,nop,wscale 7], length 0
14:22:04.118903 IP 198.51.100.7.41234 > 203.0.113.10.22: Flags [S], seq 2847193021, win 64240, options [mss 1460,sackOK,TS val 91828368 ecr 0,nop,wscale 7], length 0
14:22:06.134201 IP 198.51.100.7.41234 > 203.0.113.10.22: Flags [S], seq 2847193021, win 64240, options [mss 1460,sackOK,TS val 91830384 ecr 0,nop,wscale 7], length 0
14:22:10.166437 IP 198.51.100.7.41234 > 203.0.113.10.22: Flags [S], seq 2847193021, win 64240, options [mss 1460,sackOK,TS val 91834416 ecr 0,nop,wscale 7], length 0
4 packets captured
```

Retransmitted SYN with no RST and no SYN-ACK = **silent DROP**, either by your filter or upstream. An RST would mean `REJECT --reject-with tcp-reset` or a closed port. This distinction is the first branch of the troubleshooting tree in §13.

---

## 3. `iptables` / `ip6tables`

### 3.1 The two backends — check this first, always

Since iptables 1.8, the `iptables` binary you type may be either the legacy `x_tables` frontend or `iptables-nft`, which translates to the nftables kernel API. They write to **different kernel objects that do not see each other**.

```console
$ iptables --version
iptables v1.8.10 (nf_tables)

$ update-alternatives --display iptables
iptables - auto mode
  link best version is /usr/sbin/iptables-nft
  link currently points to /usr/sbin/iptables-nft
  link iptables is /usr/sbin/iptables
/usr/sbin/iptables-legacy - priority 10
/usr/sbin/iptables-nft - priority 20

$ iptables-legacy -S | head -3
-P INPUT ACCEPT
-P FORWARD ACCEPT
-P OUTPUT ACCEPT
```

**Production hazard:** a node with rules in *both* backends evaluates both, with the legacy hooks and the nft hooks at the same priority — the effective policy is the intersection of the ACCEPTs. If `iptables -S` looks empty but traffic is blocked, check `iptables-legacy -S` and `nft list ruleset`.

### 3.2 Anatomy of a rule

```
iptables [-t table] {-A|-I|-D|-R|-C} CHAIN [rule-spec] -j TARGET
                    │
                    └─ -A append, -I insert (default position 1), -D delete,
                       -R replace, -C check (exit 0 if present — use in scripts)
```

Core selectors:

| Selector | Meaning | Note |
|---|---|---|
| `-p tcp\|udp\|icmp\|icmpv6\|esp\|ah\|58\|all` | L4 protocol | numeric protocol also valid |
| `-s` / `-d` | source / destination CIDR | `!` negates |
| `-i` / `-o` | in / out interface | `+` wildcard: `eth+`; `-o` invalid in INPUT/PREROUTING |
| `-f` | second-and-later IPv4 fragment | rarely matches — conntrack defragments first |
| `-m <module>` | load a match extension | see below |
| `-j` / `-g` | jump to target/chain / goto (no return) | |

### 3.3 Match extensions worth memorising

| Module | Key options | Production use |
|---|---|---|
| `conntrack` | `--ctstate NEW,ESTABLISHED,RELATED,INVALID,UNTRACKED,SNAT,DNAT`, `--ctdir`, `--ctstatus`, `--ctproto` | Replaces the deprecated `-m state` |
| `multiport` | `--dports 80,443,8080:8090` | Up to 15 ports/ranges in one rule |
| `limit` | `--limit 5/min --limit-burst 10` | Token bucket, **global to the rule** — for logging |
| `hashlimit` | `--hashlimit-mode srcip --hashlimit-above 20/sec --hashlimit-burst 40 --hashlimit-name ssh` | Per-source rate limiting — the correct DoS tool |
| `recent` | `--set`, `--update --seconds 60 --hitcount 4 --name SSH --rsource` | Stateful blocklists without ipset |
| `connlimit` | `--connlimit-above 50 --connlimit-mask 32` | Concurrent-connection cap per client |
| `set` | `--match-set NAME src[,dst]` | ipset lookup, O(1) |
| `mark` / `connmark` | `--mark 0x10/0xff` | Policy routing, QoS classification |
| `tcp` | `--syn`, `--tcp-flags SYN,ACK,FIN,RST SYN`, `--tcp-option` | `--syn` ≡ `--tcp-flags FIN,SYN,RST,ACK SYN` |
| `addrtype` | `--dst-type LOCAL,BROADCAST,MULTICAST` | Detect traffic to a local address |
| `rpfilter` | `--validate-mark`, `--loose`, `--invert` | Anti-spoofing that works for IPv6 |
| `policy` | `--dir in --pol ipsec --proto esp` | "Only accept if it came out of the IPsec SA" |
| `physdev` | `--physdev-in vnet0`, `--physdev-is-bridged` | Bridged/virt traffic in `FORWARD` |
| `comment` | `--comment "JIRA-4471 payments egress"` | **Mandatory in production.** Rules without provenance are never deleted |
| `owner` | `--uid-owner`, `--gid-owner`, `--cgroup` | OUTPUT chain only — egress policy per service account |
| `tcpmss` | `--mss 1400:1536` | Diagnosing PMTUD blackholes |

### 3.4 Targets

| Target | Terminating? | Notes |
|---|---|---|
| `ACCEPT` | yes (this table/hook) | Does not skip later tables at higher priority |
| `DROP` | yes | Silent — costs the client a full TCP timeout |
| `REJECT --reject-with icmp-admin-prohibited\|tcp-reset\|icmp6-adm-prohibited` | yes | Use on internal segments; fail fast beats hanging |
| `RETURN` | for the current chain | Falls back to the calling chain's next rule / policy |
| `LOG --log-prefix "FW-DROP-IN: " --log-level 4 --log-uid` | no | Goes to the kernel ring buffer — **always rate-limit it** |
| `NFLOG --nflog-group 1 --nflog-prefix ...` | no | Netlink to `ulogd2`; structured, does not flood `dmesg` |
| `NFQUEUE --queue-num 0 --queue-bypass` | yes | Hand to userspace (IDS/IPS); `--queue-bypass` = fail-open |
| `SNAT`, `DNAT`, `MASQUERADE`, `REDIRECT`, `NETMAP` | yes | `nat` table only, `NEW` packets only |
| `MARK`, `CONNMARK`, `SECMARK`, `CONNSECMARK` | no | `mangle` table |
| `TCPMSS --clamp-mss-to-pmtu` | no | `mangle/FORWARD`, on `--tcp-flags SYN,RST SYN` |
| `CT --notrack \| --helper ftp \| --zone N` | no | `raw` table only |
| `SYNPROXY --sack-perm --timestamp --wscale 7 --mss 1460` | yes | Kernel-side SYN cookie proxy for forwarded/local flows |
| `TRACE` | no | `raw` table; enables per-rule tracing |
| `AUDIT --type drop` | no | Emits to `auditd` — compliance evidence |

### 3.5 A complete, defensible IPv4 edge ruleset

```bash
#!/usr/bin/env bash
# /usr/local/sbin/fw-build-v4.sh — builds the ruleset into a restore file.
# NEVER apply rules with a loop of `iptables -A`; build a file and restore it atomically.
set -euo pipefail

WAN=eth0; LAN=eth1; DMZ=eth2
LAN_NET=10.20.0.0/16
DMZ_NET=192.0.2.0/24
VIP=203.0.113.10
WEB=192.0.2.20
MTA=192.0.2.30

cat <<'EOF'
*raw
:PREROUTING ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
# Do not track loopback or the conntrack sync link: pure overhead, and tracking
# the sync link creates a feedback loop with conntrackd.
-A PREROUTING -i lo -j CT --notrack
-A OUTPUT -o lo -j CT --notrack
-A PREROUTING -i eth3 -j CT --notrack
-A OUTPUT -o eth3 -j CT --notrack
# Automatic helper assignment is OFF kernel-wide (nf_conntrack_helper=0).
# Enable the FTP helper ONLY for the one server that needs it.
-A PREROUTING -i eth0 -p tcp -d 192.0.2.40 --dport 21 -j CT --helper ftp
COMMIT

*mangle
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
# Clamp MSS on forwarded SYNs. Without this, any downstream tunnel (IPsec,
# WireGuard, PPPoE) turns into a PMTUD blackhole for clients behind broken
# ICMP filters.
-A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
COMMIT

*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
EOF

cat <<EOF
# --- DNAT: published services on the VIP -------------------------------------
-A PREROUTING -i ${WAN} -d ${VIP}/32 -p tcp --dport 443 -j DNAT --to-destination ${WEB}:443
-A PREROUTING -i ${WAN} -d ${VIP}/32 -p tcp --dport 80  -j DNAT --to-destination ${WEB}:80
-A PREROUTING -i ${WAN} -d ${VIP}/32 -p tcp --dport 25  -j DNAT --to-destination ${MTA}:25

# --- Hairpin / NAT-loopback ---------------------------------------------------
# A LAN client resolving the public name reaches the VIP, gets DNAT'd to the DMZ
# host, which would answer directly to the LAN client with the DMZ source IP ->
# the client drops it as an unsolicited packet. Masquerade the LAN side so the
# reply comes back through us.
-A PREROUTING -i ${LAN} -d ${VIP}/32 -p tcp --dport 443 -j DNAT --to-destination ${WEB}:443
-A POSTROUTING -s ${LAN_NET} -d ${WEB}/32 -p tcp --dport 443 -j SNAT --to-source 192.0.2.1

# --- Egress SNAT --------------------------------------------------------------
# --random-fully randomises source-port selection. Without it, the kernel walks
# ports sequentially and collides under load: insert_failed climbs and
# connections fail intermittently for no visible reason.
-A POSTROUTING -s ${LAN_NET} -o ${WAN} -j SNAT --to-source ${VIP} --random-fully
-A POSTROUTING -s ${DMZ_NET} -o ${WAN} -j SNAT --to-source 203.0.113.11 --random-fully
COMMIT
EOF

cat <<EOF
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
:LOGDROP - [0:0]
:INBOUND_WAN - [0:0]
:LAN_TO_DMZ - [0:0]
:LAN_TO_WAN - [0:0]

# --- Fast path: one conntrack lookup short-circuits the whole ruleset ---------
# This MUST be rule #1 in every chain. Everything below it is evaluated only for
# the first packet of a connection, i.e. a few hundred pps, not a few Mpps.
-A INPUT   -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A OUTPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# --- Drop INVALID early -------------------------------------------------------
# INVALID = conntrack cannot associate this packet with any flow (out-of-window
# TCP, ICMP error for an unknown tuple, asymmetric routing). Never ACCEPT it:
# INVALID packets bypass NAT and can be used to inject into an existing flow.
-A INPUT   -m conntrack --ctstate INVALID -j LOGDROP
-A FORWARD -m conntrack --ctstate INVALID -j LOGDROP

-A INPUT -i lo -j ACCEPT
-A OUTPUT -o lo -j ACCEPT

# --- Anti-spoofing ------------------------------------------------------------
# -m rpfilter is stateless and honours policy routing marks; net.ipv4.conf.*.rp_filter=1
# is strict RPF and WILL break asymmetric multi-homed designs. Prefer this.
-A INPUT   -m rpfilter --validate-mark --invert -j LOGDROP
-A FORWARD -i ${WAN} -s ${LAN_NET} -j LOGDROP
-A FORWARD -i ${WAN} -s ${DMZ_NET} -j LOGDROP
-A INPUT   -i ${WAN} -m set --match-set bogons4 src -j DROP

# --- Threat feed / fail2ban (ipset, O(1)) ------------------------------------
-A INPUT   -m set --match-set blocklist4 src -j DROP
-A FORWARD -m set --match-set blocklist4 src -j DROP

# --- ICMP: required for a working IPv4 network, rate-limited -----------------
-A INPUT -p icmp --icmp-type echo-request -m hashlimit --hashlimit-mode srcip \\
    --hashlimit-above 5/sec --hashlimit-burst 10 --hashlimit-name icmp4 -j DROP
-A INPUT -p icmp --icmp-type echo-request -j ACCEPT
-A INPUT -p icmp --icmp-type destination-unreachable -j ACCEPT
-A INPUT -p icmp --icmp-type time-exceeded -j ACCEPT
-A INPUT -p icmp --icmp-type parameter-problem -j ACCEPT

# --- Dispatch -----------------------------------------------------------------
-A INPUT -i ${WAN} -j INBOUND_WAN
-A INPUT -i ${LAN} -p tcp --dport 22 -m set --match-set mgmt_bastions src -j ACCEPT
-A INPUT -i eth3 -p udp --dport 3780 -s 10.99.0.0/30 -j ACCEPT
-A INPUT -i ${LAN} -p vrrp -j ACCEPT
-A INPUT -j LOGDROP

-A INBOUND_WAN -p tcp --dport 22 -m set --match-set mgmt_bastions src \\
    -m hashlimit --hashlimit-mode srcip --hashlimit-above 4/min \\
    --hashlimit-burst 4 --hashlimit-name sshbf -j LOGDROP
-A INBOUND_WAN -p tcp --dport 22 -m set --match-set mgmt_bastions src -j ACCEPT
-A INBOUND_WAN -j RETURN

-A FORWARD -i ${LAN} -o ${DMZ} -j LAN_TO_DMZ
-A FORWARD -i ${LAN} -o ${WAN} -j LAN_TO_WAN
-A FORWARD -i ${WAN} -o ${DMZ} -m conntrack --ctstate DNAT -j ACCEPT
# The DMZ is assumed compromised. It initiates NOTHING except explicit egress.
-A FORWARD -i ${DMZ} -o ${WAN} -p tcp -m multiport --dports 80,443 -j ACCEPT
-A FORWARD -i ${DMZ} -o ${WAN} -p udp --dport 123 -j ACCEPT
-A FORWARD -i ${DMZ} -o ${LAN} -j LOGDROP
-A FORWARD -j LOGDROP

-A LAN_TO_DMZ -p tcp -m multiport --dports 80,443,22 -m comment --comment "JIRA-4471 ops access" -j ACCEPT
-A LAN_TO_DMZ -j RETURN
-A LAN_TO_WAN -p tcp -m multiport --dports 80,443,587,993 -j ACCEPT
-A LAN_TO_WAN -p udp -m multiport --dports 53,123,443 -j ACCEPT
-A LAN_TO_WAN -j RETURN

# --- Terminal logging chain ---------------------------------------------------
# -m limit here is deliberate and non-negotiable: an unlimited LOG target is a
# self-inflicted DoS (kernel ring buffer + journald + disk I/O in the datapath).
-A LOGDROP -m limit --limit 6/min --limit-burst 12 -j LOG --log-prefix "FW4-DROP: " --log-level 4
-A LOGDROP -j DROP
COMMIT
EOF
```

Apply it — **atomically**:

```console
$ /usr/local/sbin/fw-build-v4.sh > /etc/iptables/rules.v4.new
$ iptables-restore --test < /etc/iptables/rules.v4.new && echo "syntax OK"
syntax OK
$ mv /etc/iptables/rules.v4.new /etc/iptables/rules.v4
$ iptables-restore -w 10 < /etc/iptables/rules.v4
$ echo $?
0
```

Three flags that matter:

* `--test` (`-t`) parses and validates without committing. Put it in CI.
* `-w 10` takes the `xtables` lock with a 10 s timeout. Without it, a concurrent `fail2ban` or `dockerd` write fails with `Another app is currently holding the xtables lock`.
* **No `-n`** → the restore *replaces* each table wholesale, atomically, per `COMMIT`. With `-n` (noflush) it appends. `iptables -F` + a shell loop leaves a window with policy `DROP` and zero accept rules; on a remote box that window locks you out.

### 3.6 IPv6: `ip6tables` and the ICMPv6 problem

IPv6 is not "IPv4 with longer addresses" for a firewall. **ICMPv6 is load-bearing.** Blanket-dropping it breaks address resolution (NDP replaces ARP), router discovery, multicast group membership, and Path MTU Discovery — and IPv6 routers do **not** fragment, so a filtered `packet-too-big` is a hard blackhole for any transfer above the smallest link MTU.

RFC 4890 specifies what must pass. The minimum set:

```bash
cat <<'EOF' > /etc/iptables/rules.v6
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
:ICMPV6 - [0:0]
:LOGDROP6 - [0:0]

-A INPUT   -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT   -m conntrack --ctstate INVALID -j LOGDROP6
-A FORWARD -m conntrack --ctstate INVALID -j LOGDROP6
-A INPUT -i lo -j ACCEPT

-A INPUT   -p ipv6-icmp -j ICMPV6
-A FORWARD -p ipv6-icmp -j ICMPV6

# --- MUST NOT be filtered: error messages (RFC 4890 §4.3.1) -------------------
-A ICMPV6 -p ipv6-icmp --icmpv6-type destination-unreachable -j ACCEPT
-A ICMPV6 -p ipv6-icmp --icmpv6-type packet-too-big          -j ACCEPT
-A ICMPV6 -p ipv6-icmp --icmpv6-type time-exceeded           -j ACCEPT
-A ICMPV6 -p ipv6-icmp --icmpv6-type parameter-problem       -j ACCEPT

# --- NDP. Hop limit 255 is the link-local security check: a packet that
# --- crossed a router cannot have HL=255, so this blocks off-link spoofing.
-A ICMPV6 -p ipv6-icmp --icmpv6-type router-solicitation     -m hl --hl-eq 255 -j ACCEPT
-A ICMPV6 -p ipv6-icmp --icmpv6-type router-advertisement    -m hl --hl-eq 255 -j ACCEPT
-A ICMPV6 -p ipv6-icmp --icmpv6-type neighbour-solicitation  -m hl --hl-eq 255 -j ACCEPT
-A ICMPV6 -p ipv6-icmp --icmpv6-type neighbour-advertisement -m hl --hl-eq 255 -j ACCEPT
-A ICMPV6 -p ipv6-icmp --icmpv6-type redirect                -m hl --hl-eq 255 -j ACCEPT

# --- MLD: link-local scope only ----------------------------------------------
-A ICMPV6 -p ipv6-icmp -s fe80::/10 --icmpv6-type 130 -j ACCEPT
-A ICMPV6 -p ipv6-icmp -s fe80::/10 --icmpv6-type 131 -j ACCEPT
-A ICMPV6 -p ipv6-icmp -s fe80::/10 --icmpv6-type 132 -j ACCEPT
-A ICMPV6 -p ipv6-icmp -s fe80::/10 --icmpv6-type 143 -j ACCEPT

-A ICMPV6 -p ipv6-icmp --icmpv6-type echo-request -m hashlimit --hashlimit-mode srcip \
    --hashlimit-above 5/sec --hashlimit-burst 10 --hashlimit-name icmp6 -j DROP
-A ICMPV6 -p ipv6-icmp --icmpv6-type echo-request -j ACCEPT
-A ICMPV6 -p ipv6-icmp --icmpv6-type echo-reply   -j ACCEPT
-A ICMPV6 -j LOGDROP6

# --- DHCPv6 client ------------------------------------------------------------
-A INPUT -p udp --dport 546 -d fe80::/10 -j ACCEPT

# --- Routing Header type 0 is deprecated and an amplification vector ----------
-A INPUT   -m rt --rt-type 0 -j DROP
-A FORWARD -m rt --rt-type 0 -j DROP

# --- IPv6 has no NAT to hide behind: every host is globally addressable. -----
-A FORWARD -d 2001:db8:2::/64 -p tcp -m multiport --dports 80,443 -j ACCEPT
-A FORWARD -i eth2 -o eth1 -j LOGDROP6
-A FORWARD -j LOGDROP6

-A LOGDROP6 -m limit --limit 6/min --limit-burst 12 -j LOG --log-prefix "FW6-DROP: " --log-level 4
-A LOGDROP6 -j DROP
COMMIT
EOF

ip6tables-restore --test < /etc/iptables/rules.v6 && ip6tables-restore -w 10 < /etc/iptables/rules.v6
```

| IPv4 construct | IPv6 equivalent | Trap |
|---|---|---|
| `-p icmp --icmp-type` | `-p ipv6-icmp --icmpv6-type` (`-m icmp6`) | `-p icmp` in `ip6tables` is an error |
| `-m ttl --ttl-eq` | `-m hl --hl-eq` | Different module name |
| `-f` (fragment) | `-m frag --fragfirst/--fragmore/--fragid` | IPv6 fragments are an extension header |
| ARP | NDP = ICMPv6 133–137 | Filtering it kills L2 reachability |
| RFC1918 + NAT | GUA + firewall only | No "private by accident" |
| — | `-m rt --rt-type 0` | Must be dropped explicitly |
| MASQUERADE | `MASQUERADE` exists (NAT66, ≥ 3.7) | Available but almost never correct |

**Dual-stack rule:** any change to `rules.v4` that is not mirrored in `rules.v6` is a bug. Enforce it in CI (§11.3).

---

## 4. Connection tracking

### 4.1 What conntrack stores

One entry per **flow**, keyed by two tuples (original and reply). `~320 bytes` each, plus the hash bucket.

```console
$ conntrack -L -p tcp --dport 443 2>/dev/null | head -3
tcp      6 431987 ESTABLISHED src=10.20.4.51 dst=93.184.216.34 sport=51244 dport=443 src=93.184.216.34 dst=203.0.113.10 sport=443 dport=51244 [ASSURED] mark=0 use=1
tcp      6 119 TIME_WAIT src=10.20.4.51 dst=140.82.121.4 sport=49882 dport=443 src=140.82.121.4 dst=203.0.113.10 sport=443 dport=49882 [ASSURED] mark=0 use=1
tcp      6 59 SYN_SENT src=10.20.9.7 dst=203.0.113.99 sport=44120 dport=443 [UNREPLIED] src=203.0.113.99 dst=203.0.113.10 sport=443 dport=44120 mark=0 use=1
conntrack v1.4.7 (conntrack-tools): 3 flow entries have been shown.
```

Read the fields:

* `tcp 6` — protocol name and number.
* `431987` — seconds remaining on the entry timer.
* `ESTABLISHED` — **the TCP state machine's** state, *not* the `ctstate` your rules match.
* First tuple = original direction; second = reply direction. **The reply tuple shows the NAT translation**: here `src=93.184.216.34 dst=203.0.113.10` proves SNAT to `203.0.113.10` was applied.
* `[UNREPLIED]` — nothing came back yet. A table full of `SYN_SENT [UNREPLIED]` = you are being scanned, or your egress is broken.
* `[ASSURED]` — the flow completed a bidirectional exchange. **Only non-`ASSURED` entries are evicted by early-drop when the table fills.** This is why a SYN flood of unreplied entries can still push out real connections once it fills the table.

### 4.2 `ctstate` vs TCP state — the classic confusion

| `--ctstate` | Means |
|---|---|
| `NEW` | First packet netfilter has seen for this tuple. **Not necessarily a SYN** — with `nf_conntrack_tcp_loose=1` (default), a mid-stream ACK also creates a `NEW` entry, so the firewall can pick up flows after a restart |
| `ESTABLISHED` | A packet belonging to a flow that has seen traffic in both directions |
| `RELATED` | A *new* flow that a helper or ICMP-error handling associated with an existing one (FTP data channel, ICMP `dest-unreachable` for a tracked flow) |
| `INVALID` | Cannot be classified. Drop it |
| `UNTRACKED` | `raw`-table `NOTRACK` was applied |
| `SNAT` / `DNAT` | Virtual states: the reply/original tuple was translated |

**Hardening note:** `-p tcp -m conntrack --ctstate NEW ! --syn -j DROP` closes the `tcp_loose` hole, at the cost of breaking flow pickup after a conntrack flush. On an HA pair with `conntrackd` you want this rule; on a standalone box you probably do not.

### 4.3 Sizing and tuning — the outage you can prevent with three sysctls

```console
$ sysctl net.netfilter.nf_conntrack_max net.netfilter.nf_conntrack_count
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_count = 194883

$ cat /sys/module/nf_conntrack/parameters/hashsize
65536

$ conntrack -S
cpu=0   found=0 invalid=1204 insert=0 insert_failed=118 drop=118 early_drop=0 error=0 search_restart=9214 clash_resolve=41 chaintoolong=0
cpu=1   found=0 invalid=987  insert=0 insert_failed=96  drop=96  early_drop=0 error=0 search_restart=8877 clash_resolve=38 chaintoolong=0
```

`insert_failed` climbing on a NAT box is **SNAT tuple exhaustion**, not table exhaustion. Fix with `--random-fully` and more source addresses, not a bigger table.

```ini
# /etc/sysctl.d/80-conntrack.conf
#
# Sizing: entries × ~320 B. 1 048 576 entries ≈ 336 MB resident.
# Rule of thumb for a NAT gateway: nf_conntrack_max = 4 × nf_conntrack_buckets,
# and buckets sized so the average chain length stays ≈ 4.
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_expect_max = 8192

# Default established timeout is 432000 s = 5 DAYS. On a busy NAT box this is
# the single biggest cause of table growth: dead flows squat for five days.
# 24 h still outlives any sane keepalive; pair it with TCP keepalives on hosts.
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 30
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 120
net.netfilter.nf_conntrack_icmp_timeout = 15
net.netfilter.nf_conntrack_generic_timeout = 120

# Strict window tracking. Set to 1 ONLY if you have documented asymmetric
# routing you cannot fix; it disables the out-of-window check and weakens
# sequence-number validation.
net.netfilter.nf_conntrack_tcp_be_liberal = 0

# Do not pick up mid-stream flows. Requires conntrackd for HA failover.
net.netfilter.nf_conntrack_tcp_loose = 0

# Automatic helper assignment is a known attack surface: an attacker who can
# reach a port a helper attaches to can open RELATED pinholes. Kernels >= 4.7
# default this to 0. Assign helpers explicitly with -j CT --helper.
net.netfilter.nf_conntrack_helper = 0

net.netfilter.nf_conntrack_log_invalid = 0
net.netfilter.nf_conntrack_acct = 1
net.netfilter.nf_conntrack_timestamp = 1

net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
# accept_ra=2 keeps SLAAC working on an interface that also forwards.
net.ipv6.conf.eth0.accept_ra = 2
net.ipv4.conf.all.log_martians = 1
net.ipv4.tcp_syncookies = 1
```

The hash bucket count is a **module parameter**, not a sysctl, and must be set at load time:

```console
$ echo 'options nf_conntrack hashsize=262144' > /etc/modprobe.d/nf_conntrack.conf
$ sysctl --system >/dev/null && systemctl restart systemd-modules-load
$ cat /sys/module/nf_conntrack/parameters/hashsize
262144
```

`hashsize` can also be written live (`echo 262144 > /sys/module/nf_conntrack/parameters/hashsize`) — this rehashes the whole table and briefly stalls the datapath. Do it in a maintenance window.

### 4.4 Alerting

Do not alert on `nf_conntrack_count` absolute value. Alert on **utilisation ratio** and on the `insert_failed`/`drop` deltas:

```console
$ awk -v c="$(cat /proc/sys/net/netfilter/nf_conntrack_count)" \
      -v m="$(cat /proc/sys/net/netfilter/nf_conntrack_max)" \
      'BEGIN{printf "conntrack utilisation: %.1f%% (%d/%d)\n", c/m*100, c, m}'
conntrack utilisation: 74.3% (194883/262144)
```

Page at 80 %. The kernel starts early-dropping non-`ASSURED` entries before it starts logging `table full`, so by the time `dmesg` complains you have already been silently dropping new connections.

### 4.5 Selective bypass with `NOTRACK`

For a flow class where you genuinely do not need state — an authoritative DNS server at 500 kpps, a stateless L3 load-balancer tier — conntrack is pure cost.

```bash
iptables -t raw -A PREROUTING -i eth0 -p udp --dport 53 -d 203.0.113.53 -j CT --notrack
iptables -t raw -A OUTPUT     -o eth0 -p udp --sport 53 -s 203.0.113.53 -j CT --notrack
# UNTRACKED packets never match ESTABLISHED, so the fast-path rule will not
# accept them: you MUST write explicit stateless accepts for both directions.
iptables -A INPUT  -p udp --dport 53 -d 203.0.113.53 -m conntrack --ctstate UNTRACKED -j ACCEPT
iptables -A OUTPUT -p udp --sport 53 -s 203.0.113.53 -m conntrack --ctstate UNTRACKED -j ACCEPT
```

---

## 5. NAT

### 5.1 Target selection

| Target | Table/chain | Rewrites | Use when |
|---|---|---|---|
| `SNAT --to-source A[:p1-p2]` | `nat`/POSTROUTING | source | Egress IP is **static** — cheaper, survives link flap |
| `MASQUERADE` | `nat`/POSTROUTING | source = outgoing iface's primary IP | Egress IP is **dynamic** (DHCP/PPPoE). Flushes conntrack on link down |
| `DNAT --to-destination B[:port]` | `nat`/PREROUTING, OUTPUT | destination | Publishing a service |
| `REDIRECT --to-ports N` | `nat`/PREROUTING, OUTPUT | destination = local box | Transparent proxy on the same host |
| `NETMAP --to CIDR` | `nat`/both | 1:1 network prefix | Overlapping-subnet interconnect, VPN peering |
| `TPROXY --on-port N --tproxy-mark` | `mangle`/PREROUTING | none (socket steering) | Transparent proxy preserving the original destination |

`MASQUERADE` recomputes the source address per packet and registers a notifier to drop conntrack entries when the interface goes down. `SNAT` does neither. On a box with a static WAN address, `SNAT` is measurably cheaper and does not tear down flows on an unrelated interface event.

### 5.2 The rules that are non-obvious

1. **NAT is first-packet-only.** `iptables -t nat -vnL` counters show *connections*, not packets. A DNAT rule with `pkts=48` handled 48 connections.
2. **A `nat` chain with no matching rule is `ACCEPT` by policy** — but conntrack still records "no NAT" for that flow. Adding a NAT rule afterwards will not retro-apply.
3. **DNAT'd traffic in `FORWARD` carries the *post*-DNAT destination** (DNAT is at −100, filter at 0). Write `-d 192.0.2.20`, not `-d 203.0.113.10`.
4. **SNAT'd traffic in `FORWARD` carries the *pre*-SNAT source** (SNAT at +100). Write `-s 10.20.0.0/16`.
5. **`-m conntrack --ctstate DNAT`** is the clean way to say "anything that was port-forwarded", without duplicating the address list.

### 5.3 Verifying a NAT path end to end

```console
$ iptables -t nat -vnL PREROUTING --line-numbers
Chain PREROUTING (policy ACCEPT 8214 packets, 512K bytes)
num   pkts bytes target     prot opt in     out     source               destination
1      481 28860 DNAT       tcp  --  eth0   *       0.0.0.0/0            203.0.113.10         tcp dpt:443 to:192.0.2.20:443
2       12   720 DNAT       tcp  --  eth0   *       0.0.0.0/0            203.0.113.10         tcp dpt:25 to:192.0.2.30:25

$ conntrack -L -d 203.0.113.10 -p tcp --dport 443 2>/dev/null | head -1
tcp      6 431994 ESTABLISHED src=198.51.100.7 dst=203.0.113.10 sport=52310 dport=443 src=192.0.2.20 dst=198.51.100.7 sport=443 dport=52310 [ASSURED] mark=0 use=1
```

The reply tuple `src=192.0.2.20` is the proof the DNAT took effect. If the reply tuple still reads `src=203.0.113.10`, the rule did not match — check interface, direction, and whether an earlier rule in `nat/PREROUTING` already terminated.

```console
$ conntrack -E -e NEW -p tcp --dport 443 --any-nat
    [NEW] tcp      6 120 SYN_SENT src=198.51.100.7 dst=203.0.113.10 sport=52444 dport=443 [UNREPLIED] src=192.0.2.20 dst=198.51.100.7 sport=443 dport=52444
```

Live event streaming is the fastest way to answer "is my NAT rule matching at all?" — it needs no counter resets and no log rules.

### 5.4 SNAT port exhaustion

A single SNAT source address gives you ~64 000 tuples **per destination IP:port pair**. Against one busy upstream (an S3 endpoint, a payments API) that ceiling is real.

```bash
# Spread across a pool. --persistent keeps a given client on a given source IP,
# which some upstreams' session affinity requires.
iptables -t nat -A POSTROUTING -s 10.20.0.0/16 -o eth0 \
    -j SNAT --to-source 203.0.113.10-203.0.113.14 --random-fully --persistent
```

| Symptom | Metric | Fix |
|---|---|---|
| Intermittent `connect: Cannot assign requested address` | `insert_failed` rising | Larger SNAT pool, `--random-fully` |
| Table full, `count` at `max` | `nf_conntrack_count` ≈ `nf_conntrack_max` | Raise `max` **and** lower `tcp_timeout_established` |
| Works for a while after restart, then fails | `TIME_WAIT` entries dominating | Lower `tcp_timeout_time_wait` to 30–60 s |

---

## 6. `ipset`

### 6.1 Why it exists

A linear chain of 5 000 `-s <cidr> -j DROP` rules is O(N) **per packet**. An `ipset` is a kernel hash/bitmap looked up in O(1), matched with one rule, and updatable **without touching the ruleset at all** — which means threat-feed updates never take the `xtables` lock and never risk a bad restore.

### 6.2 Types

| Type | Key | Typical use |
|---|---|---|
| `hash:ip` | address | fail2ban, per-host blocklist |
| `hash:net` | CIDR (interval) | Threat feeds, bogons, geo-blocks |
| `hash:ip,port` | address + proto/port | Per-host service ACL |
| `hash:net,port` | CIDR + proto/port | Segment-level ACL |
| `hash:ip,port,ip` | client + service + server | Three-tuple micro-segmentation |
| `hash:net,iface` | CIDR + interface | Multi-tenant edge |
| `hash:mac`, `hash:ip,mac` | MAC | L2 admission control (with `ebtables`/bridge) |
| `bitmap:port` | port range ≤ 65536 | Densest possible port set |
| `list:set` | set of sets | Compose feeds; evaluated in order, supports `nomatch` |

Options: `timeout` (per-element TTL), `counters`, `comment`, `skbinfo` (carry mark/prio/queue), `hashsize`, `maxelem`, `family inet|inet6`, `nomatch` (per-element exception inside a `hash:net`).

**Hard constraint:** a set has exactly **one** family. You need `blocklist4` *and* `blocklist6`. There is no dual-stack set.

### 6.3 Creating and using

```console
$ ipset create blocklist4 hash:net family inet hashsize 4096 maxelem 262144 timeout 86400 counters comment
$ ipset create blocklist6 hash:net family inet6 hashsize 1024 maxelem 65536 timeout 86400 counters comment
$ ipset create mgmt_bastions hash:ip family inet comment
$ ipset add mgmt_bastions 10.20.0.10 comment "bastion-a"
$ ipset add mgmt_bastions 10.20.0.11 comment "bastion-b"

$ ipset add blocklist4 185.220.101.0/24 timeout 604800 comment "tor-exit feed 2026-08-20"
$ ipset add blocklist4 203.0.113.0/24 comment "corp range - permanent"
# Punch an exception INSIDE a blocked prefix. Only valid on hash:net.
$ ipset add blocklist4 203.0.113.77 nomatch comment "partner VPN endpoint"

$ ipset list blocklist4 -t
Name: blocklist4
Type: hash:net
Revision: 7
Header: family inet hashsize 4096 maxelem 262144 timeout 86400 counters comment bucketsize 12 initval 0x7f3a92c1
Size in memory: 452608
References: 2
Number of entries: 8421

$ ipset test blocklist4 185.220.101.44
185.220.101.44 is in set blocklist4
$ ipset test blocklist4 203.0.113.77
203.0.113.77 is NOT in set blocklist4
$ echo $?
1
```

Reference it from exactly one rule per chain:

```bash
iptables  -I INPUT   1 -m set --match-set blocklist4 src -j DROP
iptables  -I FORWARD 1 -m set --match-set blocklist4 src -j DROP
ip6tables -I INPUT   1 -m set --match-set blocklist6 src -j DROP
ip6tables -I FORWARD 1 -m set --match-set blocklist6 src -j DROP

# Two-dimensional match: source IP AND destination port, in one lookup.
ipset create db_clients hash:ip,port family inet
ipset add db_clients 10.20.4.0,tcp:5432   # hash:ip accepts a /24 only in hash:net
iptables -A FORWARD -m set --match-set db_clients src,dst -j ACCEPT
```

`src,dst` reads left-to-right against the set's dimensions: first dimension ← source, second ← destination.

### 6.4 Atomic feed updates — the `swap` idiom

Never `ipset flush` a live set: that is a window with zero entries.

```bash
#!/usr/bin/env bash
# /usr/local/sbin/refresh-blocklist.sh
set -euo pipefail
FEED_URL="https://internal.example.net/feeds/threat-v4.txt"
TMP=blocklist4_tmp

curl -fsS --max-time 30 "$FEED_URL" > /run/feed4.txt
# Sanity gate: a truncated feed must not become an empty firewall.
lines=$(grep -cE '^[0-9]+\.' /run/feed4.txt || true)
[ "$lines" -ge 100 ] || { echo "feed too small ($lines), aborting" >&2; exit 1; }

ipset destroy "$TMP" 2>/dev/null || true
ipset create "$TMP" hash:net family inet hashsize 4096 maxelem 262144 timeout 86400 counters comment
{
  while read -r cidr; do
    printf 'add %s %s timeout 86400 comment "feed %s"\n' "$TMP" "$cidr" "$(date -I)"
  done < <(grep -E '^[0-9]+\.' /run/feed4.txt)
} | ipset restore -exist

# swap is atomic in the kernel: the rule referencing blocklist4 never sees a gap.
ipset swap "$TMP" blocklist4
ipset destroy "$TMP"
ipset save > /etc/ipset.conf
logger -t fw "blocklist4 refreshed: $(ipset list blocklist4 -t | awk '/Number of entries/{print $4}') entries"
```

```console
$ /usr/local/sbin/refresh-blocklist.sh
$ ipset list blocklist4 -t | grep -E 'Number|References'
References: 2
Number of entries: 9137
```

**`References: 2`** means two live netfilter rules point at it. `ipset destroy` on a set with `References > 0` fails with `Set cannot be destroyed: it is in use by a kernel component` — that reference count is what makes the swap safe.

### 6.5 Persistence

```console
$ ipset save > /etc/ipset.conf
$ head -4 /etc/ipset.conf
create blocklist4 hash:net family inet hashsize 4096 maxelem 262144 timeout 86400 counters comment bucketsize 12 initval 0x7f3a92c1
add blocklist4 185.220.101.0/24 timeout 601233 comment "tor-exit feed 2026-08-20"
add blocklist4 203.0.113.0/24 comment "corp range - permanent"
add blocklist4 203.0.113.77 nomatch comment "partner VPN endpoint"
```

**Boot ordering is a real trap:** `iptables-restore` fails hard if a referenced set does not exist yet (`Set blocklist4 doesn't exist`). The sets must be restored **before** the ruleset — see the systemd units in §11.2.

---

## 7. `nftables`

The exam asks for "basic knowledge". Production asks for fluency: nftables is the default backend on RHEL 9+, Debian 11+, SUSE 15+, and `firewalld`'s only backend since 1.0.

### 7.1 What actually changed

| Dimension | iptables (`x_tables`) | nftables |
|---|---|---|
| Kernel/user boundary | One match/target = one kernel module | One generic VM (`nf_tables`) + bytecode |
| Address families | Separate binaries: `iptables`, `ip6tables`, `arptables`, `ebtables` | One tool; families `ip`, `ip6`, `inet`, `arp`, `bridge`, `netdev` |
| Dual-stack | Two rulesets, kept in sync by hand | `table inet` — **one rule covers both** |
| Tables/chains | Fixed, built-in, always present | User-defined; a chain exists only if you create it |
| Rule update | Per-rule syscall; full ruleset via `restore` | **Atomic transactions** — the whole batch commits or none of it |
| Sets | External (`ipset`) | Native, first-class, typed, with intervals and concatenations |
| Maps / verdict maps | none | `dnat to tcp dport map {...}`, `jump vmap {...}` |
| Counters | Implicit on every rule | Explicit — rules without `counter` are cheaper |
| Multiple actions per rule | No (one `-j`) | Yes: `counter log accept` |
| Flow offload | none | `flowtable` (software and hardware) |
| Tracing | `TRACE` → `dmesg` | `nft monitor trace`, structured |

### 7.2 Syntax essentials

```console
$ nft add table inet fw
$ nft add chain inet fw input '{ type filter hook input priority filter; policy drop; }'
$ nft add rule inet fw input ct state established,related accept
$ nft list ruleset
table inet fw {
	chain input {
		type filter hook input priority filter; policy drop;
		ct state established,related accept
	}
}

$ nft -a list chain inet fw input
table inet fw {
	chain input { # handle 1
		type filter hook input priority filter; policy drop;
		ct state established,related accept # handle 4
	}
}
$ nft delete rule inet fw input handle 4
```

Rules are addressed by **handle**, not index. `nft -a` prints them. `nft insert` prepends; `nft add` appends; `nft replace rule ... handle N ...` swaps in place.

Named chain priorities: `raw` (−300), `mangle` (−150), `dstnat` (−100), `filter` (0), `security` (50), `srcnat` (100). Use the names, not the numbers.

### 7.3 A complete production ruleset — three-legged DMZ, dual-stack, HA

```nft
#!/usr/sbin/nft -f
# /etc/nftables.conf
# Dual-stack, three-legged DMZ edge firewall. Applied atomically:
#   nft -c -f /etc/nftables.conf   (check)
#   nft -f /etc/nftables.conf      (commit — flush+load in ONE transaction)

flush ruleset

define WAN  = "eth0"
define LAN  = "eth1"
define DMZ  = "eth2"
define SYNC = "eth3"

define LAN4 = 10.20.0.0/16
define DMZ4 = 192.0.2.0/24
define LAN6 = 2001:db8:20::/48
define DMZ6 = 2001:db8:2::/64

define VIP4 = 203.0.113.10
define WEB4 = 192.0.2.20
define MTA4 = 192.0.2.30
define WEB6 = 2001:db8:2::20

table inet fw {

    # ---- Sets: O(1)/O(log n) lookups, updatable without touching rules ------
    set blocklist4 {
        type ipv4_addr
        flags interval, timeout
        auto-merge
        timeout 24h
        gc-interval 10m
    }

    set blocklist6 {
        type ipv6_addr
        flags interval, timeout
        auto-merge
        timeout 24h
        gc-interval 10m
    }

    set bastions4 {
        type ipv4_addr
        elements = { 10.20.0.10, 10.20.0.11 }
    }

    set martians4 {
        type ipv4_addr
        flags interval
        elements = {
            0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8,
            169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24,
            192.168.0.0/16, 198.18.0.0/15, 198.51.100.0/24,
            203.0.113.0/24, 224.0.0.0/4, 240.0.0.0/4
        }
    }

    # Per-source SYN rate limiting, stateful, in-kernel, self-expiring.
    set ssh_flood {
        type ipv4_addr
        flags dynamic, timeout
        timeout 10m
        size 65536
    }

    # ---- Maps: policy as data ------------------------------------------------
    map dmz_services4 {
        type inet_service : ipv4_addr
        elements = { 443 : 192.0.2.20, 80 : 192.0.2.20, 25 : 192.0.2.30 }
    }

    # ---- Flowtable: software fast path ---------------------------------------
    # After a flow is ESTABLISHED it is offloaded and skips the whole forward
    # chain per packet. Add `flags offload` only if every listed NIC supports
    # hardware offload (check: ethtool -k <dev> | grep hw-tc-offload).
    flowtable ft {
        hook ingress priority filter
        devices = { eth0, eth1, eth2 }
        counter
    }

    # ---- Reusable chains ------------------------------------------------------
    chain logdrop {
        limit rate 6/minute burst 12 packets \
            log prefix "FW-DROP: " level warn flags all
        counter drop
    }

    chain icmp_ok {
        # IPv4
        icmp type { destination-unreachable, time-exceeded, parameter-problem } accept
        icmp type echo-request limit rate over 5/second burst 10 packets drop
        icmp type echo-request accept

        # IPv6 error messages: MUST pass (RFC 4890 §4.3.1).
        icmpv6 type { destination-unreachable, packet-too-big,
                      time-exceeded, parameter-problem } accept

        # NDP: hop limit 255 proves the packet did not cross a router.
        icmpv6 type { nd-router-solicit, nd-router-advert,
                      nd-neighbor-solicit, nd-neighbor-advert,
                      nd-redirect } ip6 hoplimit 255 accept

        # MLD: link-local scope only.
        ip6 saddr fe80::/10 icmpv6 type { mld-listener-query,
                                          mld-listener-report,
                                          mld-listener-done,
                                          mld2-listener-report } accept

        icmpv6 type echo-request limit rate over 5/second burst 10 packets drop
        icmpv6 type { echo-request, echo-reply } accept
        return
    }

    chain lan_to_wan {
        tcp dport { 80, 443, 587, 993 } counter accept \
            comment "JIRA-4471 baseline user egress"
        udp dport { 53, 123, 443 } counter accept
        return
    }

    chain lan_to_dmz {
        tcp dport { 22, 80, 443 } counter accept comment "ops access"
        return
    }

    chain dmz_to_wan {
        # The DMZ is assumed compromised. Explicit egress only: this is the
        # rule that turns a web-shell into a dead end instead of a beachhead.
        tcp dport { 80, 443 } counter accept comment "package + API egress"
        udp dport 123 counter accept comment "NTP"
        return
    }

    # ---- Base chains -----------------------------------------------------------
    chain prerouting_raw {
        type filter hook prerouting priority raw; policy accept;
        iifname { "lo", $SYNC } notrack
        # Bogon/martian ingress filter, before conntrack allocates an entry.
        iifname $WAN ip saddr @martians4 counter drop
        iifname $WAN ip6 saddr { ::/128, ::1/128, ::ffff:0:0/96, 2001:db8::/32 } counter drop
    }

    chain input {
        type filter hook input priority filter; policy drop;

        # Fast path first: one conntrack lookup, then done.
        ct state vmap { established : accept, related : accept, invalid : drop }

        iifname "lo" accept

        ip  saddr @blocklist4 counter drop
        ip6 saddr @blocklist6 counter drop

        # Stateless anti-spoofing that honours policy-routing marks.
        fib saddr . mark . iif oif missing counter jump logdrop

        meta l4proto { icmp, ipv6-icmp } jump icmp_ok

        # SSH: rate-limit per source into a dynamic set, then drop repeat offenders.
        iifname { $WAN, $LAN } tcp dport 22 ct state new \
            add @ssh_flood { ip saddr limit rate 4/minute burst 4 packets } \
            ip saddr @bastions4 accept
        iifname { $WAN, $LAN } tcp dport 22 ct state new counter jump logdrop

        # HA plane.
        iifname $LAN ip protocol vrrp accept
        iifname $SYNC ip saddr 10.99.0.0/30 udp dport 3780 accept

        # Node exporter, from monitoring only.
        iifname $LAN ip saddr 10.20.9.0/24 tcp dport 9100 accept

        counter jump logdrop
    }

    chain forward {
        type filter hook forward priority filter; policy drop;

        # Offload established flows to the flowtable fast path.
        meta l4proto { tcp, udp } ct state established flow add @ft counter

        ct state vmap { established : accept, related : accept, invalid : drop }

        ip  saddr @blocklist4 counter drop
        ip6 saddr @blocklist6 counter drop

        # Ingress spoofing: WAN must never carry our internal sources.
        iifname $WAN ip  saddr { $LAN4, $DMZ4 } counter jump logdrop
        iifname $WAN ip6 saddr { $LAN6, $DMZ6 } counter jump logdrop

        meta l4proto { icmp, ipv6-icmp } jump icmp_ok

        # Published DMZ services. ct status dnat covers the v4 port-forwards
        # without restating the address list; IPv6 is routed, not NAT'd.
        iifname $WAN oifname $DMZ ct status dnat counter accept
        iifname $WAN oifname $DMZ ip6 daddr $WEB6 tcp dport { 80, 443 } counter accept

        iifname $LAN oifname $WAN jump lan_to_wan
        iifname $LAN oifname $DMZ jump lan_to_dmz
        iifname $DMZ oifname $WAN jump dmz_to_wan

        # The rule the whole DMZ design exists for.
        iifname $DMZ oifname $LAN counter jump logdrop \
            comment "DMZ must never initiate into the trusted zone"

        counter jump logdrop
    }

    chain output {
        type filter hook output priority filter; policy accept;
        ct state invalid counter drop
    }

    chain forward_mangle {
        type filter hook forward priority mangle; policy accept;
        tcp flags syn / syn,rst tcp option maxseg size set rt mtu \
            comment "MSS clamp - prevents PMTUD blackholes downstream"
    }

    # ---- NAT ------------------------------------------------------------------
    chain prerouting_nat {
        type nat hook prerouting priority dstnat; policy accept;
        iifname $WAN ip daddr $VIP4 tcp dport { 443, 80, 25 } \
            counter dnat ip to tcp dport map @dmz_services4
        # Hairpin: LAN clients resolving the public name.
        iifname $LAN ip daddr $VIP4 tcp dport { 443, 80 } \
            counter dnat ip to tcp dport map @dmz_services4
    }

    chain postrouting_nat {
        type nat hook postrouting priority srcnat; policy accept;
        # Hairpin return path.
        ip saddr $LAN4 ip daddr $WEB4 tcp dport { 443, 80 } counter snat ip to 192.0.2.1
        # Egress. fully-random avoids sequential source-port collisions.
        oifname $WAN ip saddr $LAN4 counter snat ip to $VIP4 fully-random
        oifname $WAN ip saddr $DMZ4 counter snat ip to 203.0.113.11 fully-random
        # No IPv6 NAT: DMZ and LAN hold globally routable prefixes, filtered above.
    }
}
```

```console
$ nft -c -f /etc/nftables.conf && echo "ruleset valid"
ruleset valid
$ nft -f /etc/nftables.conf
$ nft list table inet fw | head -12
table inet fw {
	set blocklist4 {
		type ipv4_addr
		flags interval,timeout
		timeout 1d
		gc-interval 10m
		auto-merge
	}
...
```

**`flush ruleset` inside the file is safe**, unlike `iptables -F` on the command line: the flush and the reload are one atomic transaction. There is no window.

### 7.4 Set manipulation at runtime

```console
$ nft add element inet fw blocklist4 '{ 185.220.101.0/24 timeout 7d }'
$ nft add element inet fw blocklist4 '{ 45.155.205.0/24 }'
$ nft list set inet fw blocklist4
table inet fw {
	set blocklist4 {
		type ipv4_addr
		flags interval,timeout
		timeout 1d
		gc-interval 10m
		auto-merge
		elements = { 45.155.205.0/24 expires 23h58m12s,
			     185.220.101.0/24 timeout 7d expires 6d23h58m4s }
	}
}
$ nft delete element inet fw blocklist4 '{ 45.155.205.0/24 }'
$ nft list set inet fw ssh_flood
table inet fw {
	set ssh_flood {
		type ipv4_addr
		size 65536
		flags dynamic,timeout
		timeout 10m
		elements = { 198.51.100.44 expires 9m12s }
	}
}
```

`auto-merge` coalesces adjacent/overlapping intervals automatically — the feed can be sloppy and the kernel set stays minimal.

### 7.5 Migration path from iptables

```console
$ iptables-translate -A INPUT -p tcp --dport 443 -m conntrack --ctstate NEW -j ACCEPT
nft 'add rule ip filter INPUT tcp dport 443 ct state new counter accept'

$ iptables-save > /tmp/rules.v4
$ iptables-restore-translate -f /tmp/rules.v4 > /tmp/ruleset.nft
$ head -6 /tmp/ruleset.nft
# Translated by iptables-restore-translate v1.8.10 on Tue Aug 25 09:14:02 2026
add table ip filter
add chain ip filter INPUT { type filter hook input priority 0; policy drop; }
add chain ip filter FORWARD { type filter hook forward priority 0; policy drop; }
add chain ip filter OUTPUT { type filter hook output priority 0; policy accept; }
add rule ip filter INPUT ct state related,established counter accept
```

The translation is **mechanical and correct but not idiomatic**: it produces `table ip` + `table ip6` instead of `table inet`, keeps linear chains instead of sets and maps, and emits `counter` on every rule. Use it to bootstrap, then rewrite by hand into the `inet` family with sets. That rewrite is where the real gain is.

### 7.6 Performance model

| Mechanism | Per-packet cost | Ruleset update | Notes |
|---|---|---|---|
| iptables linear chain, N rules | O(N) match evaluations | Non-atomic per rule; atomic per table via restore | N=3000 is a measurable CPU floor |
| iptables + `ipset` | O(1) hash lookup | Set updates need no ruleset change | The classic scaling fix |
| nftables set (hash) | O(1) | Atomic transaction | Native, typed, with timeouts |
| nftables set (interval) | O(log n) | Atomic | `flags interval`, red-black tree |
| nftables verdict map | O(1)/O(log n) dispatch | Atomic | Replaces a chain of jumps |
| nftables `flowtable` (software) | Bypasses the forward chain after handshake | — | Requires `ct state established` |
| `flowtable flags offload` | In NIC hardware | — | Needs driver support; flows become invisible to counters |
| XDP/eBPF | Pre-`skb`, at the driver | Program reload | Outside the exam, but where the industry is going |

Two consequences for design:

1. **The `ct state established,related accept` rule must be first in every base chain.** It converts an O(N) ruleset into an O(1) lookup for 99.9 % of packets.
2. **Flowtable offload makes packets invisible to your filter and your counters.** That is the point, and it is also why you must not put per-packet security logic downstream of it.

---

## 8. `ebtables` and the bridge/netdev planes

### 8.1 Why L2 filtering exists

On any hypervisor, container host, or Kubernetes node, guest traffic crosses a **software bridge**, not a router. L3 hooks may never see it. `ebtables` (and the nftables `bridge` family) filter Ethernet frames: MAC addresses, ARP, VLAN tags, 802.1x, and non-IP protocols entirely.

The canonical production use is **anti-spoofing for untrusted guests**: preventing one tenant VM from claiming another's IP via gratuitous ARP, or from spoofing the gateway's MAC.

### 8.2 Structure

| Table | Chains | Purpose |
|---|---|---|
| `filter` | `INPUT`, `OUTPUT`, `FORWARD` | Accept/drop frames |
| `nat` | `PREROUTING`, `OUTPUT`, `POSTROUTING` | MAC rewriting (`dnat`, `snat`, `arpreply`) |
| `broute` | `BROUTING` | Decide **route vs bridge** per frame — a "brouter" |

```console
$ ebtables -L --Lc
Bridge table: filter

Bridge chain: INPUT, entries: 0, policy: ACCEPT

Bridge chain: FORWARD, entries: 3, policy: DROP
-p ARP -i vnet0 --arp-ip-src 10.20.7.51 --arp-mac-src 52:54:00:a1:b2:c3 -j ACCEPT , pcnt = 412 -- bcnt = 17304
-p IPv4 -i vnet0 --ip-src 10.20.7.51 -j ACCEPT , pcnt = 88401 -- bcnt = 91205118
-i vnet0 -j LOG --log-prefix "L2-SPOOF: " --log-level 4 --log-arp , pcnt = 3 -- bcnt = 126

Bridge chain: OUTPUT, entries: 0, policy: ACCEPT
```

```bash
# Anti-spoofing for guest vnet0 = 52:54:00:a1:b2:c3 / 10.20.7.51
ebtables -P FORWARD DROP
ebtables -A FORWARD -i vnet0 -p ARP --arp-ip-src 10.20.7.51 \
         --arp-mac-src 52:54:00:a1:b2:c3 -j ACCEPT
ebtables -A FORWARD -i vnet0 -p IPv4 -s 52:54:00:a1:b2:c3 --ip-src 10.20.7.51 -j ACCEPT
ebtables -A FORWARD -i vnet0 -j LOG --log-prefix "L2-SPOOF: " --log-arp
ebtables -A FORWARD -o vnet0 -p ARP --arp-ip-dst 10.20.7.51 -j ACCEPT
ebtables -A FORWARD -o vnet0 -p IPv4 --ip-dst 10.20.7.51 -j ACCEPT

ebtables-save > /etc/ebtables.conf
```

Same policy in the nftables `bridge` family — one tool, one transaction:

```nft
table bridge guests {
    chain forward {
        type filter hook forward priority filter; policy drop;
        iifname "vnet0" arp saddr ip 10.20.7.51 arp saddr ether 52:54:00:a1:b2:c3 accept
        iifname "vnet0" ether saddr 52:54:00:a1:b2:c3 ip saddr 10.20.7.51 accept
        iifname "vnet0" limit rate 6/minute log prefix "L2-SPOOF: " drop
        oifname "vnet0" ip daddr 10.20.7.51 accept
        oifname "vnet0" arp daddr ip 10.20.7.51 accept
    }
}
```

### 8.3 `br_netfilter`: bridged frames hitting `iptables`

```console
$ modprobe br_netfilter
$ sysctl -a 2>/dev/null | grep bridge-nf-call
net.bridge.bridge-nf-call-arptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
```

With these at `1`, bridged IPv4/IPv6 frames traverse the **L3** `iptables` `FORWARD` chain. This is required by `kube-proxy` in iptables mode (`bridge-nf-call-iptables=1` is a documented Kubernetes prerequisite), and it is simultaneously a common source of surprise: a "pure L2" bridge suddenly subject to L3 policy. Use `-m physdev --physdev-in vnet0 --physdev-is-bridged` to write rules that only match bridged traffic.

### 8.4 The `netdev` family

nftables adds a family with no iptables counterpart: `netdev`, hooked at **ingress**, before `PREROUTING` and before conntrack allocates anything. It is the cheapest place to drop a flood.

```nft
table netdev ddos {
    chain ingress_eth0 {
        type filter hook ingress device "eth0" priority -500; policy accept;
        # Drop before conntrack, before routing, before allocation.
        ip saddr @blocklist4 counter drop
        ip frag-off & 0x1fff != 0 counter drop comment "no IPv4 fragments at the edge"
        tcp flags & (fin|syn|rst|psh|ack|urg) == 0 counter drop comment "NULL scan"
        tcp flags & (fin|syn) == (fin|syn) counter drop comment "SYN/FIN"
        tcp flags & (fin|rst) == (fin|rst) counter drop comment "FIN/RST"
    }
}
```

---

## 9. `conntrackd`: stateful HA

### 9.1 The problem it solves

Two firewalls, VRRP, a floating VIP. The primary fails; the backup takes the VIP in ~1 second. Routing converges. And **every established TCP connection dies**, because the backup's conntrack table is empty and its ruleset drops everything that is not `ESTABLISHED`.

`conntrackd` replicates the conntrack table between nodes over a dedicated link so failover is transparent to flows.

### 9.2 Sync modes

| Mode | Mechanism | Trade-off |
|---|---|---|
| `alarm` | Periodic full resync of the cache | Simple, high bandwidth, bounded staleness |
| `ftfw` | **F**ault-**t**olerant **f**ire**w**all: reliable protocol with ACKs and retransmission over the sync link | Recommended default; consistent, moderate bandwidth |
| `notrack` | No replication protocol; relies on the kernel event API only | Lowest overhead, weakest guarantees |

### 9.3 Full configuration

```ini
# /etc/conntrackd/conntrackd.conf
Sync {
    Mode FTFW {
        # How long a committed entry survives on the backup without refresh.
        DisableExternalCache Off
        # Resend window and timeouts for the reliable protocol.
        ResendQueueSize 131072
        ACKWindowSize 300
        CommitTimeout 180
        PurgeTimeout 60
    }

    # Dedicated L2 sync segment. NEVER share it with data traffic:
    # replicating the replication traffic is a feedback loop.
    UDP {
        IPv4_address 10.99.0.1
        IPv4_Destination_Address 10.99.0.2
        Port 3780
        Interface eth3
        SndSocketBuffer 24985600
        RcvSocketBuffer 24985600
        Checksum on
    }

    # Do not replicate the sync link's own flows, nor loopback.
    Options {
        TCPWindowTracking Off
        ExpectationSync Off
    }
}

General {
    Systemd on
    HashSize 65536
    HashLimit 1048576
    LogFile /var/log/conntrackd.log
    Syslog on
    LockFile /var/lock/conntrack.lock

    UNIX {
        Path /var/run/conntrackd.ctl
        Backlog 20
    }

    NetlinkBufferSize 2097152
    NetlinkBufferSizeMaxGrowth 8388608
    # Drop netlink events rather than stall the kernel if userspace lags.
    NetlinkOverrunResync On
    NetlinkEventsReliable Off

    # Only replicate what matters. Never replicate ICMP or the sync link.
    Filter From Userspace {
        Protocol Accept {
            TCP
            UDP
        }
        Address Ignore {
            IPv4_address 127.0.0.1
            IPv4_address 10.99.0.0/30
            IPv6_address ::1
        }
    }
}
```

```ini
# /etc/keepalived/keepalived.conf
global_defs {
    router_id fw-edge-a
    enable_script_security
    script_user root
}

vrrp_script chk_ruleset {
    script "/usr/local/sbin/fw-healthcheck.sh"
    interval 5
    timeout 3
    rise 2
    fall 2
    weight -40
}

vrrp_instance VI_WAN {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 150
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass __REDACTED__
    }
    virtual_ipaddress {
        203.0.113.10/28 dev eth0
        2001:db8:1::10/64 dev eth0
    }
    track_script { chk_ruleset }
    notify_master "/etc/conntrackd/primary-backup.sh primary"
    notify_backup "/etc/conntrackd/primary-backup.sh backup"
    notify_fault  "/etc/conntrackd/primary-backup.sh fault"
}

vrrp_instance VI_LAN {
    state MASTER
    interface eth1
    virtual_router_id 52
    priority 150
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass __REDACTED__
    }
    virtual_ipaddress {
        10.20.0.1/16 dev eth1
    }
    track_script { chk_ruleset }
}
```

```bash
#!/usr/bin/env bash
# /etc/conntrackd/primary-backup.sh
# Shipped with conntrack-tools; this is the operational core.
CONNTRACKD_BIN=/usr/sbin/conntrackd
CONNTRACKD_LOCK=/var/lock/conntrack.lock

case "$1" in
  primary)
    # Commit the external cache (peer's state) into THIS kernel, then flush the
    # cache and resync. Without this commit, every replicated flow is lost.
    $CONNTRACKD_BIN -C $CONNTRACKD_CONF -c   # commit external cache -> kernel
    $CONNTRACKD_BIN -f internal              # flush internal cache
    $CONNTRACKD_BIN -R                       # resync with kernel table
    $CONNTRACKD_BIN -B                       # send a bulk update to the peer
    logger -t conntrackd "transition to PRIMARY: external cache committed"
    ;;
  backup)
    $CONNTRACKD_BIN -t                       # shorten kernel timers
    $CONNTRACKD_BIN -n                       # request a full resync from peer
    logger -t conntrackd "transition to BACKUP: requested resync"
    ;;
  fault)
    $CONNTRACKD_BIN -t
    $CONNTRACKD_BIN -n
    logger -t conntrackd "transition to FAULT"
    ;;
esac
```

### 9.4 Verifying replication

```console
$ conntrackd -s
cache internal:
current active connections:               42817
connections created:                     918442    failed:            0
connections updated:                    2114093    failed:            0
connections destroyed:                   875625    failed:            0

cache external:
current active connections:               41902
connections created:                     902114    failed:            0
connections updated:                          0    failed:            0
connections destroyed:                   860212    failed:            0

traffic processed:
                   0 Bytes                         0 Pckts

UDP traffic (active device=eth3):
           418829104 Bytes sent                 2914 Bytes recv
              914022 Pckts sent                    41 Pckts recv
                   0 Error send                    0 Error recv

message tracking:
                   0 Malformed msgs                 2 Lost msgs
```

Read it:

* **internal** = flows this node owns. **external** = flows replicated from the peer.
* `internal ≈ external` on a healthy pair — the two nodes converge. A large gap means replication is lagging or the sync link is saturated.
* `Lost msgs` climbing = tune `NetlinkBufferSize` and `ResendQueueSize`, or the sync link is undersized.
* On the **backup**, `traffic processed` should be ~0. If it is not, both nodes are forwarding — split brain.

```console
$ conntrackd -e         # dump the external cache
$ conntrackd -i         # dump the internal cache
$ conntrackd -n         # request a resync from the peer
$ conntrackd -c         # commit external cache into the kernel (failover)
```

**Prerequisite that is easy to miss:** `nf_conntrack_tcp_loose=0` (§4.3) plus `conntrackd` is the correct combination. `tcp_loose=1` *without* `conntrackd` also "works" — the backup picks up mid-stream flows — but it does so by accepting any mid-stream ACK from anyone, which is exactly the state-injection hole you built a stateful firewall to close.

---

## 10. Firewall architectures

### 10.1 Topology comparison

| Architecture | Description | Compromise of the public service means | Cost | Failure domain |
|---|---|---|---|---|
| **Single-homed bastion** | One host, filtering + services | Full internal exposure | Lowest | Everything |
| **Screened host** | Router filters, bastion serves | Router ACL is the only barrier | Low | Router + bastion |
| **Three-legged DMZ** | One firewall, three interfaces: WAN / LAN / DMZ | Attacker is inside the DMZ, still filtered from LAN by the *same* firewall | Medium | One firewall — one bug, one bypass |
| **Back-to-back / dual firewall** | Two firewalls, **different vendors/implementations**, DMZ between them | Attacker must defeat two independent implementations | High | Independent |
| **Collapsed DMZ (VLAN)** | Zones as VLANs on shared switching, firewall on a trunk | VLAN hopping / switch misconfig collapses the boundary | Low | Switching fabric |
| **Micro-segmentation** | Per-workload policy (host firewall, `NetworkPolicy`, service mesh) | Blast radius ≈ one workload | Highest ops cost | Per workload |

**Architect's judgement:** the three-legged DMZ is the correct default for a single-site platform. Back-to-back is worth its cost only when the compliance regime demands implementation diversity (PCI-DSS segmentation for a CDE, for example) — otherwise the second firewall is a second thing to misconfigure. Micro-segmentation is not an alternative to a perimeter; it is the layer that limits what a perimeter breach reaches.

### 10.2 Three-legged reference topology

```
                    Internet
                       │
                  203.0.113.0/28
                       │
                    ┌──┴───┐  eth0 (WAN)  VIP 203.0.113.10
                    │  fw-a├──────┐
                    │  fw-b│      │ eth3 10.99.0.0/30  ← conntrackd sync (dedicated)
                    └──┬───┘      │
              eth2     │     eth1 │
        192.0.2.1/24   │   10.20.0.1/16
                       │          │
        ┌──────────────┴──┐    ┌──┴───────────────┐
        │      DMZ        │    │      LAN         │
        │  192.0.2.0/24   │    │  10.20.0.0/16    │
        │  2001:db8:2::/64│    │  2001:db8:20::/48│
        │                 │    │                  │
        │  web 192.0.2.20 │    │  bastion .0.10   │
        │  mta 192.0.2.30 │    │  db      .5.0/24 │
        └─────────────────┘    └──────────────────┘

Policy invariants (these are the design, the rules are the implementation):
  WAN → DMZ : published ports only, DNAT'd
  WAN → LAN : DENY (no exceptions)
  LAN → DMZ : explicit ops ports
  LAN → WAN : explicit egress allowlist
  DMZ → WAN : explicit egress allowlist (updates, APIs, NTP)
  DMZ → LAN : DENY  ← the reason the DMZ exists
```

The last line is the only one that matters. Every other rule is convenience; `DMZ → LAN : DENY` is what converts "we were breached" into "we lost a web server".

---

## 11. Complete infrastructure

### 11.1 Ansible role

```yaml
# roles/netfilter/defaults/main.yml
---
netfilter_backend: nftables        # nftables | iptables
netfilter_wan_iface: eth0
netfilter_lan_iface: eth1
netfilter_dmz_iface: eth2
netfilter_sync_iface: eth3

netfilter_lan_v4: 10.20.0.0/16
netfilter_dmz_v4: 192.0.2.0/24
netfilter_lan_v6: "2001:db8:20::/48"
netfilter_dmz_v6: "2001:db8:2::/64"
netfilter_vip_v4: 203.0.113.10

netfilter_conntrack_max: 1048576
netfilter_conntrack_hashsize: 262144
netfilter_conntrack_tcp_established: 86400

netfilter_bastions:
  - 10.20.0.10
  - 10.20.0.11

netfilter_egress_lan:
  - { proto: tcp, ports: [80, 443, 587, 993], comment: "JIRA-4471 user baseline" }
  - { proto: udp, ports: [53, 123, 443],      comment: "DNS, NTP, QUIC" }

netfilter_egress_dmz:
  - { proto: tcp, ports: [80, 443], comment: "package repos + partner APIs" }
  - { proto: udp, ports: [123],     comment: "NTP" }

netfilter_published:
  - { port: 443, backend: 192.0.2.20, comment: "www" }
  - { port: 80,  backend: 192.0.2.20, comment: "www redirect" }
  - { port: 25,  backend: 192.0.2.30, comment: "inbound mail" }

netfilter_ha_enabled: true
netfilter_sync_local: 10.99.0.1
netfilter_sync_peer: 10.99.0.2
```

```yaml
# roles/netfilter/tasks/main.yml
---
- name: Install packet-filtering toolchain
  ansible.builtin.package:
    name:
      - nftables
      - iptables
      - ipset
      - conntrack
      - conntrack-tools
      - ebtables
      - ulogd2
    state: present

- name: Ensure firewalld is not competing for the ruleset
  ansible.builtin.systemd:
    name: firewalld
    state: stopped
    enabled: false
    masked: true
  failed_when: false

- name: Deploy conntrack and forwarding sysctls
  ansible.builtin.template:
    src: 80-conntrack.conf.j2
    dest: /etc/sysctl.d/80-conntrack.conf
    owner: root
    group: root
    mode: "0644"
  notify: reload sysctl

- name: Pin the conntrack hash bucket count at module load
  ansible.builtin.copy:
    content: "options nf_conntrack hashsize={{ netfilter_conntrack_hashsize }}\n"
    dest: /etc/modprobe.d/nf_conntrack.conf
    owner: root
    group: root
    mode: "0644"

- name: Deploy ipset definitions
  ansible.builtin.template:
    src: ipset.conf.j2
    dest: /etc/ipset.conf
    owner: root
    group: root
    mode: "0600"
    validate: "/bin/sh -c 'ipset restore -f %s -t'"
  notify: restore ipsets

- name: Deploy nftables ruleset
  ansible.builtin.template:
    src: nftables.conf.j2
    dest: /etc/nftables.conf
    owner: root
    group: root
    mode: "0600"
    # -c is a dry-run parse+semantic check. A template typo can never reach
    # the kernel: the task fails at validate time, before the file is written.
    validate: "/usr/sbin/nft -c -f %s"
  when: netfilter_backend == 'nftables'
  notify: reload nftables

- name: Deploy iptables/ip6tables rulesets
  ansible.builtin.template:
    src: "rules.{{ item.family }}.j2"
    dest: "/etc/iptables/rules.{{ item.family }}"
    owner: root
    group: root
    mode: "0600"
    validate: "{{ item.validator }} --test"
  loop:
    - { family: v4, validator: /usr/sbin/iptables-restore }
    - { family: v6, validator: /usr/sbin/ip6tables-restore }
  when: netfilter_backend == 'iptables'
  notify: reload iptables

- name: Deploy conntrackd configuration
  ansible.builtin.template:
    src: conntrackd.conf.j2
    dest: /etc/conntrackd/conntrackd.conf
    owner: root
    group: root
    mode: "0600"
  when: netfilter_ha_enabled | bool
  notify: restart conntrackd

- name: Deploy the failover transition script
  ansible.builtin.copy:
    src: primary-backup.sh
    dest: /etc/conntrackd/primary-backup.sh
    owner: root
    group: root
    mode: "0750"
  when: netfilter_ha_enabled | bool

- name: Enable persistence and HA units
  ansible.builtin.systemd:
    name: "{{ item }}"
    enabled: true
    state: started
    daemon_reload: true
  loop: "{{ netfilter_units }}"

- name: Assert the policy invariants actually hold
  ansible.builtin.include_tasks: verify.yml
  tags: [verify]
```

```yaml
# roles/netfilter/tasks/verify.yml
---
# These are not smoke tests; they are the policy expressed as assertions.
# If a refactor of the ruleset breaks an invariant, this fails the play.

- name: Read the live ruleset
  ansible.builtin.command: nft list ruleset
  register: nft_live
  changed_when: false
  when: netfilter_backend == 'nftables'

- name: Assert every base chain has a restrictive default policy
  ansible.builtin.assert:
    that:
      - "'hook input priority filter; policy drop;' in nft_live.stdout"
      - "'hook forward priority filter; policy drop;' in nft_live.stdout"
    fail_msg: "A base chain defaults to accept - this is a fail-open ruleset."
  when: netfilter_backend == 'nftables'

- name: Assert the DMZ cannot initiate into the LAN
  ansible.builtin.assert:
    that:
      - "'iifname \"' ~ netfilter_dmz_iface ~ '\" oifname \"' ~ netfilter_lan_iface ~ '\" counter packets' in nft_live.stdout"
    fail_msg: "The DMZ->LAN deny rule is missing. The DMZ is not a DMZ."
  when: netfilter_backend == 'nftables'

- name: Assert IPv6 error messages are not filtered
  ansible.builtin.assert:
    that:
      - "'packet-too-big' in nft_live.stdout"
      - "'nd-neighbor-solicit' in nft_live.stdout"
    fail_msg: "ICMPv6 is over-filtered: expect PMTUD blackholes and broken NDP."
  when: netfilter_backend == 'nftables'

- name: Read conntrack utilisation
  ansible.builtin.shell: |
    set -o pipefail
    c=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
    m=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
    awk -v c="$c" -v m="$m" 'BEGIN{printf "%.1f", c/m*100}'
  args:
    executable: /bin/bash
  register: ct_util
  changed_when: false

- name: Warn on conntrack pressure
  ansible.builtin.assert:
    that:
      - ct_util.stdout | float < 80.0
    fail_msg: >-
      conntrack utilisation is {{ ct_util.stdout }}% - the kernel is already
      early-dropping non-ASSURED entries. Raise nf_conntrack_max and lower
      nf_conntrack_tcp_timeout_established.
    success_msg: "conntrack utilisation {{ ct_util.stdout }}% - healthy"

- name: Verify no legacy iptables rules shadow the nftables ruleset
  ansible.builtin.command: iptables-legacy -S
  register: legacy
  changed_when: false
  failed_when: false

- name: Assert the legacy backend is empty
  ansible.builtin.assert:
    that:
      - legacy.stdout_lines | reject('match', '^-P .* ACCEPT$') | list | length == 0
    fail_msg: >-
      Rules exist in BOTH the legacy and nft backends. Both are evaluated;
      the effective policy is the intersection. Consolidate on one backend.
```

```yaml
# roles/netfilter/handlers/main.yml
---
- name: reload sysctl
  ansible.builtin.command: sysctl --system
  changed_when: true

- name: restore ipsets
  # -exist makes this idempotent; sets must exist BEFORE the ruleset loads.
  ansible.builtin.command: ipset restore -exist -file /etc/ipset.conf
  changed_when: true

- name: reload nftables
  ansible.builtin.systemd:
    name: nftables
    state: reloaded

- name: reload iptables
  ansible.builtin.systemd:
    name: "{{ item }}"
    state: reloaded
  loop:
    - iptables
    - ip6tables

- name: restart conntrackd
  ansible.builtin.systemd:
    name: conntrackd
    state: restarted
```

```yaml
# roles/netfilter/vars/main.yml
---
netfilter_units: >-
  {{
    (['nftables'] if netfilter_backend == 'nftables' else ['iptables', 'ip6tables'])
    + ['ipset-persistent', 'ulogd2']
    + (['conntrackd', 'keepalived'] if netfilter_ha_enabled | bool else [])
  }}
```

### 11.2 systemd units — boot ordering is a correctness requirement

```ini
# /etc/systemd/system/ipset-persistent.service
# ipsets MUST be loaded before the ruleset: iptables-restore/nft abort with
# "Set blocklist4 doesn't exist" and the box boots with NO firewall.
[Unit]
Description=Restore ipset sets
Documentation=man:ipset(8)
DefaultDependencies=no
Before=network-pre.target nftables.service iptables.service ip6tables.service
Wants=network-pre.target
ConditionPathExists=/etc/ipset.conf

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ipset restore -exist -file /etc/ipset.conf
ExecReload=/sbin/ipset restore -exist -file /etc/ipset.conf
ExecStop=/bin/true
StandardOutput=journal

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/nftables.service.d/override.conf
[Unit]
After=ipset-persistent.service
Requires=ipset-persistent.service

[Service]
# Fail the unit loudly if the ruleset does not parse. A firewall that
# "started successfully" with an empty ruleset is worse than one that failed.
ExecStartPre=/usr/sbin/nft -c -f /etc/nftables.conf
ExecReload=
ExecReload=/usr/sbin/nft -c -f /etc/nftables.conf
ExecReload=/usr/sbin/nft -f /etc/nftables.conf
```

```ini
# /etc/systemd/system/fw-blocklist-refresh.service
[Unit]
Description=Refresh threat-intelligence ipsets
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/refresh-blocklist.sh
# The firewall must keep working if the feed is down.
SuccessExitStatus=0
Nice=10
IOSchedulingClass=idle
```

```ini
# /etc/systemd/system/fw-blocklist-refresh.timer
[Unit]
Description=Refresh threat-intelligence ipsets hourly

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
```

### 11.3 CI gate: no ruleset reaches a node unvalidated

```yaml
# .gitlab-ci.yml
---
stages: [lint, validate, dryrun, deploy]

variables:
  ANSIBLE_FORCE_COLOR: "1"
  ANSIBLE_HOST_KEY_CHECKING: "False"

.netfilter_image: &netfilter_image
  image: registry.example.net/ci/netfilter-tools:1.8.10-nft1.0.9
  before_script:
    - nft --version
    - iptables --version
    - ipset --version

lint:ansible:
  stage: lint
  <<: *netfilter_image
  script:
    - ansible-lint roles/netfilter
    - yamllint -s roles/netfilter

validate:nftables:
  stage: validate
  <<: *netfilter_image
  script:
    # Render every host's ruleset and parse-check it. A syntax error here
    # is a pipeline failure, not a 3 a.m. lockout.
    - ansible-playbook -i inventory/prod site.yml --tags netfilter --check --diff
    - |
      for f in build/rendered/*.nft; do
        echo "checking $f"
        nft -c -f "$f" || exit 1
      done

validate:invariants:
  stage: validate
  <<: *netfilter_image
  script:
    # Policy invariants asserted against the RENDERED text, before deploy.
    - |
      set -euo pipefail
      fail=0
      for f in build/rendered/*.nft; do
        grep -q 'policy drop;' "$f"        || { echo "$f: no drop policy"; fail=1; }
        grep -q 'packet-too-big'  "$f"     || { echo "$f: ICMPv6 PTB filtered"; fail=1; }
        grep -q 'nd-neighbor-solicit' "$f" || { echo "$f: NDP filtered"; fail=1; }
        grep -q 'ct state invalid' "$f"    || { echo "$f: INVALID not dropped"; fail=1; }
        # Dual-stack parity: every table must be inet, or both ip and ip6 present.
        grep -q 'table inet' "$f"          || { echo "$f: not dual-stack"; fail=1; }
      done
      exit $fail

dryrun:staging:
  stage: dryrun
  <<: *netfilter_image
  script:
    - ansible-playbook -i inventory/staging site.yml --tags netfilter --diff
    - ansible-playbook -i inventory/staging site.yml --tags verify
  environment:
    name: staging

deploy:prod:
  stage: deploy
  <<: *netfilter_image
  script:
    # serial: 1 in the play + the verify tasks mean a broken node stops the
    # rollout before it reaches the second firewall of an HA pair.
    - ansible-playbook -i inventory/prod site.yml --tags netfilter --diff
    - ansible-playbook -i inventory/prod site.yml --tags verify
  environment:
    name: production
  when: manual
  only:
    refs: [main]
```

### 11.4 The lockout guard

Applying a ruleset to a remote firewall over the link that ruleset governs is the single most common way to lose a box. Always arm a rollback first:

```console
$ iptables-save > /root/fw-rollback-$(date +%s).v4
$ nft list ruleset > /root/nft-rollback-$(date +%s).nft
$ systemd-run --on-active=120 --unit=fw-rollback \
    /usr/sbin/nft -f /root/nft-rollback-1756108800.nft
Running timer as unit: fw-rollback.timer
Will run service as unit: fw-rollback.service

$ nft -f /etc/nftables.conf          # apply the new ruleset
$ ssh fw-edge-a 'echo still reachable'
still reachable
$ systemctl stop fw-rollback.timer   # cancel the rollback - you survived
```

If the new ruleset locks you out, the timer restores the old one in 120 s and your SSH session recovers. This costs 15 seconds to set up and has saved more site visits than any other habit in this document.

---

## 12. The container era: who else is writing your ruleset

On any node running Docker or Kubernetes, you are not the only author.

```console
$ iptables -t nat -S | head -8
-P PREROUTING ACCEPT
-P INPUT ACCEPT
-P OUTPUT ACCEPT
-P POSTROUTING ACCEPT
-N DOCKER
-N KUBE-MARK-MASQ
-N KUBE-POSTROUTING
-N KUBE-SERVICES
-A PREROUTING -m comment --comment "kubernetes service portals" -j KUBE-SERVICES
```

| Agent | Where it writes | How to coexist |
|---|---|---|
| `dockerd` | `nat/DOCKER`, `filter/DOCKER`, `filter/FORWARD` (inserts `-j DOCKER-USER` **first**) | **Put your rules in `DOCKER-USER`.** Anything you add to `FORWARD` is bypassed. `dockerd` also forces `net.ipv4.ip_forward=1` |
| `kube-proxy` (iptables mode) | `KUBE-SERVICES`, `KUBE-SVC-*`, `KUBE-SEP-*`, `KUBE-POSTROUTING` | Thousands of generated rules; a full resync is O(services). Do not hand-edit |
| `kube-proxy` (ipvs mode) | IPVS table + a small iptables set of helper rules and ipsets (`KUBE-CLUSTER-IP`, …) | Scales far better past ~1 000 services |
| `kube-proxy` (nftables mode) | `table ip kube-proxy` in the nft backend | Alpha in v1.29, beta in v1.31 — verify against your cluster's version before relying on it |
| CNI (Calico/Cilium) | Own chains (`cali-*`) or eBPF, replacing iptables entirely | Cilium's kube-proxy replacement removes most of the above |
| `fail2ban` | Own chains via `f2b-*`, or ipset | Prefer the ipset action: no ruleset churn, no lock contention |
| `firewalld` | Owns the whole nftables ruleset | Either use it exclusively or mask it. Never both |

```bash
# The correct place for node-level policy on a Docker host:
iptables -I DOCKER-USER 1 -i eth0 -m set --match-set blocklist4 src -j DROP
iptables -I DOCKER-USER 2 -i eth0 -p tcp --dport 8080 ! -s 10.20.0.0/16 -j DROP
```

**The `DOCKER-USER` chain is the only chain Docker guarantees it will not rewrite.** Rules elsewhere in `FORWARD` are silently ineffective because Docker's own jump precedes them.

---

## 13. Verification and failure diagnosis

### 13.1 The decision tree

```
Traffic does not arrive at the service
│
├─ tcpdump on the firewall's ingress interface: is the packet there?
│  ├─ NO ──▶ upstream problem: routing, upstream ACL, DNS, or the client.
│  │         Not your firewall. Verify with: ip route get <dst>
│  └─ YES ─┐
│          │
├─ Does the client get an RST/ICMP-unreachable, or silence?
│  ├─ RST / ICMP admin-prohibited ──▶ an explicit REJECT rule, or nothing listening.
│  │   Check: ss -tlnp 'sport = :443'  AND  iptables -vnL | grep REJECT
│  └─ SILENCE ──▶ a DROP. Continue.
│
├─ Does a conntrack entry exist?
│  │   conntrack -L -d <dst> -p tcp --dport <port>
│  ├─ NO entry ──▶ dropped in raw/PREROUTING, or in a netdev/ingress chain,
│  │               or by rp_filter. Check dmesg for "martian source".
│  ├─ Entry, [UNREPLIED] ──▶ it got in; the REPLY is being dropped, or the
│  │                         backend never answered. Check FORWARD/OUTPUT and
│  │                         the backend's own host firewall.
│  └─ Entry, ASSURED ──▶ the firewall is fine; the problem is above L4 (TLS,
│                        vhost, app). Stop debugging netfilter.
│
├─ Are the counters moving?
│  │   iptables -Z && sleep 10 && iptables -vnL --line-numbers
│  ├─ The DROP rule's counter climbs ──▶ found it. Read the rule.
│  └─ No counter moves anywhere ──▶ the packet is not reaching this ruleset:
│      wrong backend (legacy vs nft), wrong table, or an agent's chain
│      (DOCKER-USER, KUBE-*) terminated first.
│
└─ Still unexplained ──▶ trace the packet (§13.3).
```

### 13.2 Counter-driven diagnosis

```console
$ iptables -Z && ip6tables -Z && nft reset counters
$ sleep 10
$ iptables -vnL FORWARD --line-numbers
Chain FORWARD (policy DROP 47 packets, 2820 bytes)
num   pkts bytes target     prot opt in     out     source               destination
1    18442 22M   ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0            ctstate RELATED,ESTABLISHED
2        0     0 LOGDROP    all  --  *      *       0.0.0.0/0            0.0.0.0/0            ctstate INVALID
3      211 12660 ACCEPT     all  --  eth0   eth2    0.0.0.0/0            0.0.0.0/0            ctstate DNAT
4        0     0 ACCEPT     tcp  --  eth1   eth0    10.20.0.0/16         0.0.0.0/0            multiport dports 80,443,587,993
5       47  2820 LOGDROP    all  --  *      *       0.0.0.0/0            0.0.0.0/0
```

Read this in ten seconds:

* Rule 1 handles 18 442 of 18 700 packets — the fast path works.
* Rule 4 has **zero** hits while rule 5 dropped 47: LAN egress is matching nothing. Suspect the interface name (`eth1` vs a bond/VLAN) or the source CIDR.
* `policy DROP 47 packets` on the chain header equals rule 5's count — every drop is going through `LOGDROP`, so the logs will show what.

```console
$ journalctl -k --since "-2 min" -g 'FW4-DROP' -o cat | tail -2
FW4-DROP: IN=bond0.20 OUT=eth0 MAC=... SRC=10.20.4.51 DST=140.82.121.4 LEN=60 TOS=0x00 PREC=0x00 TTL=63 ID=54321 DF PROTO=TCP SPT=49882 DPT=443 WINDOW=64240 RES=0x00 SYN URGP=0
FW4-DROP: IN=bond0.20 OUT=eth0 MAC=... SRC=10.20.4.51 DST=140.82.121.4 LEN=60 TOS=0x00 PREC=0x00 TTL=63 ID=54322 DF PROTO=TCP SPT=49882 DPT=443 WINDOW=64240 RES=0x00 SYN URGP=0
```

`IN=bond0.20`, not `eth1`. Diagnosis complete: the rule names the wrong interface. This is the single most common "the firewall is broken" ticket, and the `LOG` prefix is what makes it a 90-second fix instead of an afternoon.

### 13.3 Tracing

**nftables (and `iptables-nft`):**

```console
$ nft add rule inet fw prerouting_raw ip saddr 198.51.100.7 meta nftrace set 1
$ nft monitor trace
trace id 9f3c1a02 inet fw prerouting_raw packet: iif "eth0" ether saddr 00:1b:21:0a:bc:de ether daddr 00:1b:21:0a:bc:df ip saddr 198.51.100.7 ip daddr 203.0.113.10 ip dscp cs0 ip ttl 54 ip id 41288 ip protocol tcp ip length 60 tcp sport 41234 tcp dport 22 tcp flags == syn tcp window 64240
trace id 9f3c1a02 inet fw prerouting_raw rule ip saddr 198.51.100.7 meta nftrace set 1 (verdict continue)
trace id 9f3c1a02 inet fw prerouting_raw verdict continue
trace id 9f3c1a02 inet fw input packet: iif "eth0" ... tcp dport 22 tcp flags == syn
trace id 9f3c1a02 inet fw input rule ct state vmap { established : accept, related : accept, invalid : drop } (verdict continue)
trace id 9f3c1a02 inet fw input rule iifname { "eth0", "eth1" } tcp dport 22 ct state new counter packets 1 bytes 60 jump logdrop (verdict jump logdrop)
trace id 9f3c1a02 inet fw logdrop rule limit rate 6/minute burst 12 packets log prefix "FW-DROP: " level warn (verdict continue)
trace id 9f3c1a02 inet fw logdrop verdict drop
trace id 9f3c1a02 inet fw logdrop policy accept
^C
$ nft -a list chain inet fw prerouting_raw | grep nftrace
		ip saddr 198.51.100.7 meta nftrace set 1 # handle 27
$ nft delete rule inet fw prerouting_raw handle 27
```

Every rule the packet touched, in order, with the verdict. The `trace id` groups one packet's whole journey. **Remove the trace rule when done** — it is a per-packet netlink event storm.

**Legacy iptables:**

```console
$ modprobe nf_log_ipv4
$ sysctl -w net.netfilter.nf_log.2=nf_log_ipv4
$ iptables-legacy -t raw -A PREROUTING -s 198.51.100.7 -j TRACE
$ dmesg -w | grep TRACE
[318442.114] TRACE: raw:PREROUTING:policy:2 IN=eth0 OUT= SRC=198.51.100.7 DST=203.0.113.10 LEN=60 PROTO=TCP SPT=41234 DPT=22 SYN
[318442.114] TRACE: filter:INPUT:rule:1 IN=eth0 OUT= SRC=198.51.100.7 DST=203.0.113.10 LEN=60 PROTO=TCP SPT=41234 DPT=22 SYN
[318442.114] TRACE: filter:INPUT:policy:14 IN=eth0 OUT= SRC=198.51.100.7 DST=203.0.113.10 LEN=60 PROTO=TCP SPT=41234 DPT=22 SYN
$ iptables-legacy -t raw -D PREROUTING -s 198.51.100.7 -j TRACE
```

Format: `table:chain:rule|policy:number`. **With the `iptables-nft` backend, `-j TRACE` does not write to `dmesg`** — use `xtables-monitor --trace` or `nft monitor trace` instead. This surprises people who learned tracing on RHEL 7 and moved to RHEL 9.

### 13.4 Symptom → cause reference

| Symptom | First command | Likely cause | Fix |
|---|---|---|---|
| `nf_conntrack: table full, dropping packet` | `conntrack -C; sysctl net.netfilter.nf_conntrack_max` | Table undersized, or 5-day established timeout | §4.3 sysctls |
| Long TCP flows die, short ones fine | `conntrack -S` (`invalid` climbing) | Asymmetric routing; conntrack sees one direction | Fix routing, or `tcp_be_liberal=1` as a documented last resort |
| Intermittent `Cannot assign requested address` on egress | `conntrack -S` (`insert_failed`) | SNAT port exhaustion | `--random-fully`, SNAT pool |
| IPv6 works, large transfers hang | `ip6tables -vnL \| grep -c packet-too-big` | ICMPv6 PTB filtered → PMTUD blackhole | §3.6; also `TCPMSS --clamp-mss-to-pmtu` |
| IPv6 neighbours unreachable | `ip -6 neigh show` (all `FAILED`) | NDP (ICMPv6 133–137) filtered | §3.6 |
| Rules present but ignored | `iptables --version`; `iptables-legacy -S` | Two backends in use | Consolidate |
| Policy reverts after container restart | `iptables -S FORWARD \| head -1` | Rules in `FORWARD` instead of `DOCKER-USER` | §12 |
| `Another app is currently holding the xtables lock` | `fuser /run/xtables.lock` | Concurrent writer (`fail2ban`, `dockerd`) | Always pass `-w <timeout>` |
| `Set blocklist4 doesn't exist` at boot | `systemctl list-dependencies nftables` | ipsets restored after the ruleset | §11.2 unit ordering |
| Every connection drops at failover | `conntrackd -s` (external cache empty) | Replication down, or `-c` never called | §9 |
| Kernel log flooded, box unresponsive | `journalctl -k --since -1min \| wc -l` | `LOG` target without `-m limit` | Add `limit`, or move to `NFLOG` + `ulogd2` |
| `martian source` in `dmesg` | `sysctl net.ipv4.conf.all.rp_filter` | Strict RPF vs asymmetric/multi-homed path | `rp_filter=2` (loose) or `-m rpfilter --loose` |

### 13.5 Structured logging with `NFLOG` + `ulogd2`

`LOG` writes free text to the kernel ring buffer, in the datapath, with no structure. On a busy firewall that is both a performance problem and an unparseable one. `NFLOG` hands packets to userspace over netlink:

```bash
nft add rule inet fw logdrop limit rate 20/second burst 40 packets \
    log prefix "drop " group 1
```

```ini
# /etc/ulogd.conf
[global]
logfile="/var/log/ulogd.log"
loglevel=5
plugin="/usr/lib/x86_64-linux-gnu/ulogd/ulogd_inppkt_NFLOG.so"
plugin="/usr/lib/x86_64-linux-gnu/ulogd/ulogd_raw2packet_BASE.so"
plugin="/usr/lib/x86_64-linux-gnu/ulogd/ulogd_filter_IFINDEX.so"
plugin="/usr/lib/x86_64-linux-gnu/ulogd/ulogd_filter_IP2STR.so"
plugin="/usr/lib/x86_64-linux-gnu/ulogd/ulogd_output_JSON.so"

stack=log1:NFLOG,base1:BASE,ifi1:IFINDEX,ip2str1:IP2STR,json1:JSON

[log1]
group=1
numeric_label=1

[json1]
sync=0
file="/var/log/ulogd.json"
```

```console
$ tail -1 /var/log/ulogd.json | jq -c '{ts:.timestamp,in:.oob.in,src:.src_ip,dst:.dst_ip,dpt:.dest_port,pfx:.oob.prefix}'
{"ts":"2026-08-25T09:41:12","in":"eth0","src":"198.51.100.7","dst":"203.0.113.10","dpt":22,"pfx":"drop "}
```

JSON lines ship straight to Loki/Elasticsearch. Rate-limit the `log` statement regardless of backend — netlink is cheaper than `printk`, not free.

### 13.6 Accounting without logging

For "how much traffic matched this policy" without any per-packet logging cost:

```console
$ nfacct add dmz-egress-https
$ iptables -A FORWARD -i eth2 -o eth0 -p tcp --dport 443 -m nfacct --nfacct-name dmz-egress-https
$ nfacct list
{ pkts = 00000000000418829, bytes = 00000000411204118 } = dmz-egress-https;
```

In nftables, a named counter does the same:

```console
$ nft add counter inet fw dmz_egress_https
$ nft add rule inet fw forward iifname "eth2" oifname "eth0" tcp dport 443 counter name dmz_egress_https accept
$ nft list counters
table inet fw {
	counter dmz_egress_https {
		packets 418829 bytes 411204118
	}
}
```

---

## 14. Exam-focused consolidation

Facts that are asked directly and are easy to lose under pressure:

1. **Traversal order for a forwarded packet:** `raw/PREROUTING` → conntrack → `mangle/PREROUTING` → `nat/PREROUTING` (DNAT) → *routing decision* → `mangle/FORWARD` → `filter/FORWARD` → `mangle/POSTROUTING` → `nat/POSTROUTING` (SNAT).
2. **`filter`** has `INPUT`, `FORWARD`, `OUTPUT`. **`nat`** has `PREROUTING`, `INPUT`, `OUTPUT`, `POSTROUTING`. **`mangle`** has all five. **`raw`** has `PREROUTING`, `OUTPUT`.
3. **`-m state --state`** is the legacy syntax; **`-m conntrack --ctstate`** is current. Both appear in exam material.
4. **`iptables-save`/`iptables-restore`** work on the whole ruleset; `restore` **flushes by default**, `-n`/`--noflush` appends. `-t`/`--test` validates only.
5. **`ipset` has one address family per set.** IPv4 and IPv6 need separate sets.
6. **`ipset swap`** is the atomic-update primitive. `ipset destroy` fails while `References > 0`.
7. **`ebtables` tables:** `filter`, `nat`, `broute`. The `broute`/`BROUTING` chain is unique to ebtables and decides bridge-vs-route.
8. **nftables families:** `ip`, `ip6`, `inet`, `arp`, `bridge`, `netdev`. `inet` is the dual-stack one.
9. **`nft` has no built-in tables or chains.** You create everything, including the base chains with `type`/`hook`/`priority`/`policy`.
10. **`conntrackd`** replicates conntrack state; modes `alarm`, `ftfw`, `notrack`; `-c` commits the external cache into the kernel on promotion to primary.
11. **`MASQUERADE`** = SNAT to the outgoing interface's address, for dynamic IPs. **`SNAT`** for static — cheaper, and it does not flush conntrack on link events.
12. **`REDIRECT`** is DNAT to the local machine; **`REJECT`** sends an error, **`DROP`** sends nothing.
13. **ICMPv6 types 133–137** are NDP and must pass; **type 2** (`packet-too-big`) must pass or PMTUD blackholes.
14. `-j LOG` continues to the next rule; `-j DROP`/`ACCEPT`/`REJECT` terminate.

---

## Referencias

**Certification objectives**

* LPI — Exam 303 Objectives (LPIC-3 Security, v3.0.0): <https://www.lpi.org/our-certifications/exam-303-objectives/>

**Netfilter project (upstream)**

* Netfilter/iptables project documentation index: <https://www.netfilter.org/documentation/index.html>
* iptables project page: <https://www.netfilter.org/projects/iptables/index.html>
* nftables project page and manpage: <https://www.netfilter.org/projects/nftables/manpage.html>
* nftables wiki (main page): <https://wiki.nftables.org/wiki-nftables/index.php/Main_Page>
* Moving from iptables to nftables: <https://wiki.nftables.org/wiki-nftables/index.php/Moving_from_iptables_to_nftables>
* nftables — Sets, maps and concatenations: <https://wiki.nftables.org/wiki-nftables/index.php/Sets>
* nftables — Flowtables: <https://wiki.nftables.org/wiki-nftables/index.php/Flowtables>
* nftables — Troubleshooting and ruleset debug: <https://wiki.nftables.org/wiki-nftables/index.php/Ruleset_debug/tracing>
* ipset project and manpage: <https://ipset.netfilter.org/ipset.man.html>
* conntrack-tools manual (`conntrack`, `conntrackd`): <https://conntrack-tools.netfilter.org/manual.html>
* ebtables project page: <https://www.netfilter.org/projects/ebtables/index.html>
* libnetfilter_log / ulogd project: <https://www.netfilter.org/projects/ulogd/index.html>

**Linux kernel documentation**

* Conntrack sysctl reference: <https://docs.kernel.org/networking/nf_conntrack-sysctl.html>
* Netfilter flowtable infrastructure: <https://docs.kernel.org/networking/nf_flowtable.html>
* IP sysctl reference (`rp_filter`, `ip_forward`, `accept_ra`): <https://docs.kernel.org/networking/ip-sysctl.html>

**Manual pages**

* `iptables(8)`: <https://man7.org/linux/man-pages/man8/iptables.8.html>
* `iptables-extensions(8)` — every match and target: <https://man7.org/linux/man-pages/man8/iptables-extensions.8.html>
* `ip6tables(8)`: <https://man7.org/linux/man-pages/man8/ip6tables.8.html>
* `nft(8)`: <https://man7.org/linux/man-pages/man8/nft.8.html>
* `ipset(8)`: <https://man7.org/linux/man-pages/man8/ipset.8.html>
* `ebtables(8)`: <https://man7.org/linux/man-pages/man8/ebtables.8.html>
* `conntrackd(8)`: <https://man7.org/linux/man-pages/man8/conntrackd.8.html>

**Standards and guidance**

* RFC 4890 — Recommendations for Filtering ICMPv6 Messages in Firewalls: <https://www.rfc-editor.org/rfc/rfc4890.html>
* RFC 4861 — Neighbor Discovery for IPv6: <https://www.rfc-editor.org/rfc/rfc4861.html>
* RFC 8200 — IPv6 Specification (fragmentation, extension headers): <https://www.rfc-editor.org/rfc/rfc8200.html>
* RFC 5095 — Deprecation of Type 0 Routing Headers in IPv6: <https://www.rfc-editor.org/rfc/rfc5095.html>
* NIST SP 800-41 Rev. 1 — Guidelines on Firewalls and Firewall Policy: <https://csrc.nist.gov/pubs/sp/800/41/r1/final>

**Ecosystem interaction**

* Kubernetes — kube-proxy and the nftables proxy mode: <https://kubernetes.io/docs/reference/networking/virtual-ips/>
* Docker — packet filtering and firewalls (`DOCKER-USER`): <https://docs.docker.com/engine/network/packet-filtering-firewalls/>
* keepalived documentation: <https://www.keepalived.org/manpage.html>