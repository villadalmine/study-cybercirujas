# LPIC-3 303 — Topic 334.3: Packet Filtering
## Guided Exercises (Exam 303-300, v3.0.0 — weight 8.33)

These exercises are hands-on. Every step is meant to be executed, and every command produces
observable state you are expected to inspect. The goal is not to memorise flags but to build the
mental model an SRE needs at 3 a.m.: **which hook ran, in which order, what conntrack thought of the
packet, and where the verdict came from.**

---

### Lab environment

| Item | Requirement |
|---|---|
| Hosts | One VM (`alpha`) with a working Internet route. Debian 12 (nft 1.0.6 / kernel 6.1) or RHEL 9 (nft 1.0.4 / kernel 5.14). |
| Access | **Console or out-of-band access is mandatory.** You will set `policy drop` on the `input` hook. |
| Privileges | All commands are run as `root` (or via `sudo`). |
| Second host | Optional. Where a remote peer is needed, exercises use `ip netns` namespaces created on `alpha` itself, so no second machine is required. |
| Packages | `nftables`, `iptables`, `conntrack`, `iproute2`, `tcpdump`, `netcat-openbsd`, plus `firewalld` **or** `ufw` for Exercise 9. |

> **Anti-lockout rule for the whole lab.** Before every ruleset change, arm a dead-man switch:
> ```bash
> systemd-run --on-active=10m --unit=fw-rollback /usr/sbin/nft flush ruleset
> ```
> If the change works, disarm it with `systemctl stop fw-rollback.timer`. If it does not, the box
> opens up again in ten minutes without a console.

---

## Exercise 1 — Identify the backend and snapshot the current state

Modern distributions ship `iptables` as a **compatibility front-end over nf_tables**. Knowing which
engine actually holds your rules is the first diagnostic step, and a frequent exam question.

1. Establish the kernel and tool versions:

   ```bash
   uname -r
   nft --version
   iptables --version
   ip6tables --version
   ```

   Expected output (Debian 12):

   ```text
   6.1.0-18-amd64
   nftables v1.0.6 (Lester Gooch #5)
   iptables v1.8.9 (nf_tables)
   ip6tables v1.8.9 (nf_tables)
   ```

2. Find out what the `iptables` name resolves to and which alternatives exist:

   ```bash
   ls -l /usr/sbin/iptables
   update-alternatives --display iptables 2>/dev/null | head -n 5
   ls /usr/sbin/ | grep -E 'iptables|xtables'
   ```

   Expected output (abridged):

   ```text
   lrwxrwxrwx 1 root root 26 Mar  4 09:11 /usr/sbin/iptables -> /etc/alternatives/iptables
   iptables - auto mode
     link best version is /usr/sbin/iptables-nft
   iptables-legacy  iptables-nft  iptables-restore  iptables-save  xtables-monitor  xtables-nft-multi
   ```

3. Check which netfilter modules are loaded right now:

   ```bash
   lsmod | grep -E '^(nf_tables|ip_tables|ip6_tables|nf_conntrack|x_tables|nft_)' 
   ```

4. Dump both worlds, so you know whether anything is hiding in the legacy engine:

   ```bash
   nft list ruleset
   iptables-legacy -S 2>/dev/null
   ip6tables-legacy -S 2>/dev/null
   ```

5. Take a restorable snapshot before touching anything:

   ```bash
   mkdir -p /root/fw-backup
   nft list ruleset            > /root/fw-backup/ruleset-$(date +%F).nft
   iptables-save               > /root/fw-backup/rules-v4-$(date +%F).iptables
   ip6tables-save              > /root/fw-backup/rules-v6-$(date +%F).ip6tables
   ls -l /root/fw-backup/
   ```

6. Turn the nft snapshot into a file that is actually safe to reload:

   ```bash
   { echo '#!/usr/sbin/nft -f'; echo 'flush ruleset'; cat /root/fw-backup/ruleset-$(date +%F).nft; } \
       > /root/fw-backup/restore.nft
   chmod 0700 /root/fw-backup/restore.nft
   nft -c -f /root/fw-backup/restore.nft && echo "syntax OK"
   ```

**Check your understanding**

- **Q1.1** `iptables -V` prints `(nf_tables)`. Where do rules created with that binary end up, and what
  would `(legacy)` have meant instead?
- **Q1.2** Why is `nft list ruleset` alone an incomplete backup on a host running `firewalld`?
- **Q1.3** What exactly does `flush ruleset` at the top of a saved file protect you from, and why is
  `nft -f` on a whole file safer than a sequence of `nft add rule` commands?
- **Q1.4** Both `ip_tables` and `nf_tables` can be loaded at the same time. What determines the order in
  which their rules see a packet, and why is that combination considered an operational hazard?
- **Q1.5** What does `nft -c -f file` do, and why should it be in every change procedure?

---

## Exercise 2 — A stateful dual-stack host firewall in the `inet` family

The `inet` family (kernel ≥ 3.14) lets one table cover IPv4 and IPv6, eliminating the classic
"we hardened v4 and forgot v6" incident.

1. Write the ruleset. Create `/etc/nftables.conf` with exactly this content:

   ```nft
   #!/usr/sbin/nft -f
   flush ruleset

   table inet fw {
       chain inbound {
           type filter hook input priority filter; policy drop;

           iifname "lo" accept comment "loopback is trusted"

           ct state vmap { established : accept, related : accept, invalid : drop }

           meta nfproto ipv4 icmp type { echo-request, destination-unreachable, time-exceeded, parameter-problem } accept
           meta nfproto ipv6 icmpv6 type { echo-request, echo-reply, destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert, mld-listener-query } accept

           tcp dport 22 ct state new accept comment "SSH"

           counter comment "unmatched inbound"
           limit rate 5/minute burst 5 packets log prefix "fw-input-drop " level info flags all
       }

       chain forward {
           type filter hook forward priority filter; policy drop;
       }

       chain outbound {
           type filter hook output priority filter; policy accept;
       }
   }
   ```

2. Validate, arm the rollback, and load atomically:

   ```bash
   nft -c -f /etc/nftables.conf && echo "syntax OK"
   systemd-run --on-active=10m --unit=fw-rollback /usr/sbin/nft flush ruleset
   nft -f /etc/nftables.conf
   ```

3. Inspect what the kernel actually holds, with handles:

   ```bash
   nft -a list table inet fw
   ```

   Expected output (abridged):

   ```text
   table inet fw { # handle 12
   	chain inbound { # handle 1
   		type filter hook input priority filter; policy drop;
   		iifname "lo" accept comment "loopback is trusted" # handle 4
   		ct state vmap { established : accept, invalid : drop, related : accept } # handle 5
   		meta nfproto ipv4 icmp type { echo-request, destination-unreachable, time-exceeded, parameter-problem } accept # handle 6
   		...
   		tcp dport 22 ct state new accept comment "SSH" # handle 8
   		counter packets 0 bytes 0 comment "unmatched inbound" # handle 9
   		limit rate 5/minute burst 5 packets log prefix "fw-input-drop " level info flags all # handle 10
   	}
   ```

4. Generate traffic that must be dropped and watch the evidence accumulate:

   ```bash
   nc -vz -w2 127.0.0.1 22          # allowed via loopback
   ss -lntp | head
   # from another terminal / host, hit a closed port:
   nc -vz -w2 <alpha-ip> 8080
   nft list chain inet fw inbound | grep counter
   journalctl -k -n 20 --grep 'fw-input-drop'
   ```

   Expected kernel log line:

   ```text
   kernel: fw-input-drop IN=eth0 OUT= MAC=... SRC=192.0.2.10 DST=198.51.100.5 LEN=60 TOS=0x00 PREC=0x00 TTL=63 ID=... PROTO=TCP SPT=51234 DPT=8080 WINDOW=64240 RES=0x00 SYN URGP=0
   ```

5. Add and then remove a rule at runtime, using handles instead of line numbers:

   ```bash
   nft add rule inet fw inbound tcp dport 443 ct state new counter accept
   nft -a list chain inet fw inbound | grep 443
   nft delete rule inet fw inbound handle <handle-from-above>
   ```

6. Insert a rule *before* the SSH rule instead of appending:

   ```bash
   nft insert rule inet fw inbound position <handle-of-ssh-rule> \
       ip saddr 203.0.113.0/24 tcp dport 22 counter drop comment "blocked net"
   nft -a list chain inet fw inbound
   ```

7. Disarm the rollback once you have confirmed your SSH session still works:

   ```bash
   systemctl stop fw-rollback.timer
   systemctl enable --now nftables.service
   ```

**Check your understanding**

- **Q2.1** The chain has `policy drop` *and* a final `counter`/`log` pair, but no explicit `drop` rule at
  the end. Why does that work, and what is the advantage over ending with `log ... drop`?
- **Q2.2** What is the difference between `iif "lo"` and `iifname "lo"`, and which one breaks when an
  interface is deleted and recreated (a container or VPN tunnel, for instance)?
- **Q2.3** Another administrator adds a second base chain on the same hook with
  `type filter hook input priority 10; policy accept;`. Your chain already issued `accept` for a packet.
  Is the second chain still evaluated? What if your chain had issued `drop`?
- **Q2.4** Why drop `ct state invalid` explicitly instead of letting it fall through to the policy?
- **Q2.5** The rule `limit rate 5/minute burst 5 packets log prefix ...` places the limiter *before* the
  log statement. What would change if the two were swapped?
- **Q2.6** Why does `ct state vmap { ... }` scale better than three separate `ct state ... accept` rules?

---

## Exercise 3 — Named sets, verdict maps and a self-populating blocklist

Sets are hash or interval lookups performed once, instead of N rules evaluated linearly. They are also
the only way to update a blocklist **without reloading the ruleset**.

1. Declare a static interval set and a service verdict map. Append inside `table inet fw` in
   `/etc/nftables.conf`:

   ```nft
       set badnets {
           type ipv4_addr
           flags interval
           comment "manually curated blocklist"
           elements = { 203.0.113.0/24, 198.51.100.64/26 }
       }

       set ssh_flood {
           type ipv4_addr
           size 65535
           flags dynamic, timeout
           timeout 1h
       }

       map svcmap {
           type inet_service : verdict
           elements = { 22 : accept, 80 : accept, 443 : accept }
       }
   ```

2. Rewire the `inbound` chain to use them. Replace the SSH rule block with:

   ```nft
           ip saddr @badnets counter drop comment "static blocklist"
           ip saddr @ssh_flood counter drop comment "dynamic blocklist"

           tcp dport 22 ct state new \
               add @ssh_flood { ip saddr timeout 1h limit rate over 6/minute burst 6 packets } \
               log prefix "fw-ssh-brute " drop

           ct state new tcp dport vmap @svcmap
   ```

3. Reload and verify:

   ```bash
   nft -c -f /etc/nftables.conf && nft -f /etc/nftables.conf
   nft list set inet fw badnets
   nft list map inet fw svcmap
   ```

   Expected output:

   ```text
   table inet fw {
   	set badnets {
   		type ipv4_addr
   		flags interval
   		comment "manually curated blocklist"
   		elements = { 198.51.100.64/26, 203.0.113.0/24 }
   	}
   }
   table inet fw {
   	map svcmap {
   		type inet_service : verdict
   		elements = { 22 : accept, 80 : accept, 443 : accept }
   	}
   }
   ```

4. Update the sets at runtime — no reload, no packet loss:

   ```bash
   nft add element inet fw badnets { 192.0.2.0/25 }
   nft add element inet fw svcmap { 8443 : accept }
   nft list set inet fw badnets
   nft delete element inet fw badnets { 192.0.2.0/25 }
   ```

5. Trigger the brute-force limiter from another host or namespace and watch the dynamic set fill:

   ```bash
   for i in $(seq 1 12); do nc -z -w1 <alpha-ip> 22; done
   nft list set inet fw ssh_flood
   ```

   Expected output:

   ```text
   table inet fw {
   	set ssh_flood {
   		type ipv4_addr
   		size 65535
   		flags dynamic,timeout
   		timeout 1h
   		elements = { 192.0.2.10 expires 59m54s264ms }
   	}
   }
   ```

6. Release the offender manually and confirm:

   ```bash
   nft delete element inet fw ssh_flood { 192.0.2.10 }
   nft list set inet fw ssh_flood
   ```

**Check your understanding**

- **Q3.1** Why is `flags interval` mandatory to store `203.0.113.0/24`, and what does the kernel use
  internally for interval sets that it does not use for plain ones?
- **Q3.2** What is the practical difference between `add @set { ... }` and `update @set { ... }` in a rule?
- **Q3.3** You have 4,000 blocked prefixes. Compare "4,000 rules" versus "one rule plus a 4,000-element
  set" on two axes: per-packet cost and update cost.
- **Q3.4** You reboot the host and reload `/etc/nftables.conf`. What happens to the elements that had
  been added to `ssh_flood` at runtime, and how would you preserve them across a reload?
- **Q3.5** In step 2, the drop rule for `@ssh_flood` is placed *above* the rule that adds to it. Why does
  the ordering matter?
- **Q3.6** What is the difference between a `set` of type `inet_service` and a `map` of type
  `inet_service : verdict`?

---

## Exercise 4 — Connection tracking: the state machine behind `ct state`

`ct state established` is not magic: it is a lookup in a kernel hash table that is finite, tunable, and
able to fill up. This is the single most common cause of "the firewall randomly drops traffic".

1. Confirm conntrack is loaded and look at the sizing:

   ```bash
   lsmod | grep nf_conntrack
   sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max
   sysctl net.netfilter.nf_conntrack_buckets
   cat /sys/module/nf_conntrack/parameters/hashsize
   ```

   Expected output:

   ```text
   net.netfilter.nf_conntrack_count = 137
   net.netfilter.nf_conntrack_max = 262144
   net.netfilter.nf_conntrack_buckets = 65536
   65536
   ```

2. Read the table two different ways:

   ```bash
   head -n 3 /proc/net/nf_conntrack
   conntrack -L -p tcp --dport 22
   conntrack -S | head -n 2
   ```

   Expected output:

   ```text
   ipv4     2 tcp      6 431997 ESTABLISHED src=192.0.2.10 dst=198.51.100.5 sport=51234 dport=22 src=198.51.100.5 dst=192.0.2.10 sport=22 dport=51234 [ASSURED] mark=0 use=1
   tcp      6 431997 ESTABLISHED src=192.0.2.10 dst=198.51.100.5 sport=51234 dport=22 src=198.51.100.5 dst=192.0.2.10 sport=22 dport=51234 [ASSURED] mark=0 use=1
   conntrack v1.4.7 (conntrack-tools): 1 flow entries have been shown.
   cpu=0   found=0 invalid=12 insert=0 insert_failed=0 drop=0 early_drop=0 error=0 search_restart=41
   ```

3. Watch the state machine live. In one terminal:

   ```bash
   conntrack -E -e NEW,UPDATE,DESTROY -p tcp
   ```

   In another, open and close a connection:

   ```bash
   curl -s -o /dev/null http://example.com/
   ```

   Expected event stream (abridged):

   ```text
   [NEW] tcp      6 120 SYN_SENT src=198.51.100.5 dst=93.184.216.34 sport=44112 dport=80 [UNREPLIED] ...
   [UPDATE] tcp   6 60 SYN_RECV src=198.51.100.5 dst=93.184.216.34 sport=44112 dport=80 ...
   [UPDATE] tcp   6 432000 ESTABLISHED src=... [ASSURED] ...
   [UPDATE] tcp   6 120 FIN_WAIT src=... 
   [UPDATE] tcp   6 30 LAST_ACK src=...
   [DESTROY] tcp  6 src=198.51.100.5 dst=93.184.216.34 sport=44112 dport=80 ...
   ```

4. Prove that state, not the rule for port 22, is what keeps your SSH session alive. **Do this only with
   console access.** Delete your own SSH flow from the table:

   ```bash
   conntrack -D -p tcp --dport 22 --src <your-client-ip>
   ```

   Expected result: the SSH session freezes. The client's next data packet is no longer `established`;
   it is not a `SYN`, so it becomes `invalid` and hits your `invalid : drop`.

5. Inspect and tune the timeouts that decide how long a flow survives idle:

   ```bash
   sysctl net.netfilter | grep -E 'timeout_established|udp_timeout|icmp_timeout|tcp_loose'
   ```

   Expected output:

   ```text
   net.netfilter.nf_conntrack_icmp_timeout = 30
   net.netfilter.nf_conntrack_tcp_loose = 1
   net.netfilter.nf_conntrack_tcp_timeout_established = 432000
   net.netfilter.nf_conntrack_udp_timeout = 30
   net.netfilter.nf_conntrack_udp_timeout_stream = 120
   ```

   Apply a production-sane value persistently:

   ```bash
   cat > /etc/sysctl.d/90-conntrack.conf <<'EOF'
   net.netfilter.nf_conntrack_max = 524288
   net.netfilter.nf_conntrack_tcp_timeout_established = 86400
   EOF
   sysctl --system | grep conntrack
   ```

6. Exempt high-volume stateless traffic from tracking entirely, using a `raw` chain:

   ```bash
   nft add table inet raw
   nft add chain inet raw prerouting '{ type filter hook prerouting priority raw; }'
   nft add chain inet raw output '{ type filter hook output priority raw; }'
   nft add rule inet raw prerouting udp dport 53 notrack
   nft add rule inet raw output udp sport 53 notrack
   nft list table inet raw
   ```

7. Assign a connection tracking helper explicitly (automatic assignment is off by default since
   Linux 4.7):

   ```bash
   modprobe nf_conntrack_ftp
   sysctl net.netfilter.nf_conntrack_helper
   nft -f - <<'EOF'
   table inet helpers {
       ct helper ftp-standard {
           type "ftp" protocol tcp
       }
       chain prerouting {
           type filter hook prerouting priority filter;
           tcp dport 21 ct helper set "ftp-standard"
       }
   }
   EOF
   nft list table inet helpers
   ```

**Check your understanding**

- **Q4.1** At which hook priority does connection tracking run, and why must a `notrack` rule live in a
  chain with `priority raw` rather than `priority filter`?
- **Q4.2** Explain precisely why `conntrack -D` froze an SSH session on a `policy drop` firewall, and what
  the client would have to do to recover.
- **Q4.3** `dmesg` shows `nf_conntrack: table full, dropping packet`. Give three distinct remedies and
  say which one you would apply first on a busy NAT gateway, and why.
- **Q4.4** What is the difference in content and in requirements between `/proc/net/nf_conntrack` and
  `conntrack -L`?
- **Q4.5** Why was automatic conntrack helper assignment disabled by default in Linux 4.7, and what are
  the two things you must now do to make active-mode FTP work through the firewall?
- **Q4.6** What does the `[ASSURED]` flag mean, and how does it interact with `early_drop` when the table
  approaches `nf_conntrack_max`?
- **Q4.7** `ct state related` accepts a packet that belongs to no existing flow tuple. Give two concrete
  examples of packets that legitimately match `related`.

---

## Exercise 5 — Routing, NAT and a filtered forward path

This exercise builds a real router without a second VM, using a network namespace as the "LAN".

1. Build the topology:

   ```bash
   ip netns add lan
   ip link add veth-fw type veth peer name veth-lan
   ip link set veth-lan netns lan
   ip addr add 10.10.0.1/24 dev veth-fw
   ip link set veth-fw up

   ip netns exec lan ip link set lo up
   ip netns exec lan ip addr add 10.10.0.2/24 dev veth-lan
   ip netns exec lan ip link set veth-lan up
   ip netns exec lan ip route add default via 10.10.0.1

   ip netns exec lan ip route show
   ```

   Expected output:

   ```text
   default via 10.10.0.1 dev veth-lan 
   10.10.0.0/24 dev veth-lan proto kernel scope link src 10.10.0.2 
   ```

2. Confirm forwarding is off, and that the LAN cannot reach anything yet:

   ```bash
   sysctl net.ipv4.ip_forward
   ip netns exec lan ping -c1 -W2 1.1.1.1 ; echo "exit=$?"
   ```

3. Enable forwarding — note it is a per-namespace setting:

   ```bash
   sysctl -w net.ipv4.ip_forward=1
   echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/91-forward.conf
   ```

4. Add source NAT and a filtered forward path. Extend `/etc/nftables.conf`:

   ```nft
   table inet nat {
       chain prerouting {
           type nat hook prerouting priority dstnat; policy accept;
       }
       chain postrouting {
           type nat hook postrouting priority srcnat; policy accept;
           ip saddr 10.10.0.0/24 oifname "eth0" masquerade
       }
   }
   ```

   And replace the `forward` chain in `table inet fw`:

   ```nft
       chain forward {
           type filter hook forward priority filter; policy drop;

           ct state vmap { established : accept, related : accept, invalid : drop }
           iifname "veth-fw" oifname "eth0" ct state new accept comment "LAN egress"
           counter log prefix "fw-forward-drop " level info
       }
   ```

   ```bash
   nft -c -f /etc/nftables.conf && nft -f /etc/nftables.conf
   ip netns exec lan ping -c2 1.1.1.1
   ```

5. Observe the translation in the conntrack table — the two tuples differ:

   ```bash
   conntrack -L -s 10.10.0.2
   ```

   Expected output:

   ```text
   icmp     1 29 src=10.10.0.2 dst=1.1.1.1 type=8 code=0 id=12 src=1.1.1.1 dst=198.51.100.5 type=0 code=0 id=12 mark=0 use=1
   ```

6. Add destination NAT (a published service) and prove the filter chain sees the *post*-DNAT address.
   Start a listener inside the LAN namespace:

   ```bash
   ip netns exec lan nc -l -k -p 8080 &
   nft add rule inet nat prerouting iifname "eth0" tcp dport 80 dnat ip to 10.10.0.2:8080
   nft add rule inet fw forward iifname "eth0" oifname "veth-fw" ip daddr 10.10.0.2 tcp dport 8080 ct state new accept
   nft list table inet nat
   ```

7. Match on the fact that a flow was translated, rather than repeating the addresses:

   ```bash
   nft add rule inet fw forward ct status dnat counter comment "published services"
   nft -a list chain inet fw forward | grep dnat
   ```

8. Clean up the lab topology when finished:

   ```bash
   ip netns del lan
   ip link del veth-fw 2>/dev/null
   ```

**Check your understanding**

- **Q5.1** In which order do the `nat prerouting` (priority `dstnat` = -100) and `filter forward`
  (priority `filter` = 0) chains see a packet, and what does that imply for the address you must write
  in the forward rule of step 6?
- **Q5.2** A `nat` base chain only sees the *first* packet of each flow. Which subsystem translates the
  rest, and what practical consequence does this have if you add a NAT rule while flows are already
  running?
- **Q5.3** Compare `masquerade` with `snat to 198.51.100.5`: cost, correctness on a DHCP/PPPoE uplink, and
  what happens to existing conntrack entries when the WAN interface goes down.
- **Q5.4** `net.ipv4.ip_forward` was set on the host, not in the `lan` namespace. Why is that the correct
  place, and what would have happened if you had set it inside the namespace instead?
- **Q5.5** Define, in the vocabulary the exam uses: *screened subnet (DMZ)*, *bastion host*, *dual-homed
  firewall*, and *egress filtering*. Which chain would enforce each of the first three on this host?
- **Q5.6** Why is NAT not a security control, even though it hides internal addresses?

---

## Exercise 6 — `iptables`/`ip6tables`: interop, save/restore and migration

Legacy rulesets are everywhere. You must be able to read them, persist them and translate them.

1. Create rules with the `iptables` front-end, then look at them through `nft`:

   ```bash
   iptables -N HARDENED
   iptables -A HARDENED -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
   iptables -A HARDENED -p tcp -m multiport --dports 80,443 -m conntrack --ctstate NEW -j ACCEPT
   iptables -A HARDENED -m limit --limit 3/min -j LOG --log-prefix "legacy-drop "
   iptables -A HARDENED -j REJECT --reject-with icmp-port-unreachable
   iptables -A INPUT -i eth0 -j HARDENED

   iptables -S HARDENED
   nft list table ip filter | head -n 20
   ```

   Expected output (abridged):

   ```text
   -N HARDENED
   -A HARDENED -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
   -A HARDENED -p tcp -m multiport --dports 80,443 -m conntrack --ctstate NEW -j ACCEPT
   ...
   table ip filter {
   	chain HARDENED {
   		ct state related,established counter packets 0 bytes 0 accept
   		meta l4proto tcp tcp dport { 80,443 } ct state new counter packets 0 bytes 0 accept
   		...
   ```

2. Save with counters and inspect the on-disk format:

   ```bash
   iptables-save -c > /root/fw-backup/rules.v4
   head -n 12 /root/fw-backup/rules.v4
   ```

   Expected output:

   ```text
   # Generated by iptables-save v1.8.9 on Tue Aug 25 11:02:41 2026
   *filter
   :INPUT ACCEPT [1204:98123]
   :FORWARD DROP [0:0]
   :OUTPUT ACCEPT [980:120441]
   :HARDENED - [0:0]
   [12:720] -A INPUT -i eth0 -j HARDENED
   [8:480] -A HARDENED -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
   ...
   COMMIT
   # Completed on Tue Aug 25 11:02:41 2026
   ```

3. Restore two ways and note the difference:

   ```bash
   iptables-restore   < /root/fw-backup/rules.v4    # replaces the listed tables
   iptables-restore -n < /root/fw-backup/rules.v4   # --noflush: appends instead
   iptables -S INPUT | wc -l                        # run before and after the -n variant
   ```

4. Translate individual rules and whole files:

   ```bash
   iptables-translate -A INPUT -i eth0 -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT
   ip6tables-translate -A INPUT -p ipv6-icmp --icmpv6-type echo-request -j ACCEPT
   iptables-restore-translate -f /root/fw-backup/rules.v4 > /root/fw-backup/translated.nft
   head -n 15 /root/fw-backup/translated.nft
   ```

   Expected output:

   ```text
   nft 'add rule ip filter INPUT iifname "eth0" tcp dport 22 ct state new counter accept'
   nft 'add rule ip6 filter INPUT icmpv6 type echo-request counter accept'
   ```

5. Confirm that IPv4 and IPv6 are genuinely separate under `iptables`:

   ```bash
   ip6tables -S INPUT
   ip6tables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT
   ip6tables-save > /root/fw-backup/rules.v6
   ```

6. Make it survive a reboot, the distribution way:

   ```bash
   # Debian/Ubuntu
   apt-get install -y iptables-persistent      # writes /etc/iptables/rules.v4 and rules.v6
   netfilter-persistent save
   systemctl is-enabled netfilter-persistent

   # RHEL family
   # dnf install -y iptables-services && systemctl enable --now iptables ip6tables
   ```

7. Clean up before continuing:

   ```bash
   iptables -F; iptables -X; iptables -P INPUT ACCEPT
   ip6tables -F; ip6tables -X
   ```

**Check your understanding**

- **Q6.1** In `iptables-save` output, what do `*filter`, `:INPUT ACCEPT [1204:98123]` and `COMMIT` mean?
- **Q6.2** Why is `iptables-restore` described as atomic, and what does `-n`/`--noflush` change about that
  guarantee?
- **Q6.3** Translate by hand:
  `iptables -t nat -A POSTROUTING -s 10.0.0.0/8 ! -o lo -j MASQUERADE`
- **Q6.4** What is the difference between `-m state --state` and `-m conntrack --ctstate`, and which should
  new rules use?
- **Q6.5** You created chain `HARDENED` with `iptables-nft`, and it now shows up in `nft list ruleset`.
  Why must you still not edit it with `nft`?
- **Q6.6** What is the difference between `-j DROP` and `-j REJECT --reject-with icmp-port-unreachable`
  from the client's point of view, and when is each appropriate?
- **Q6.7** `iptables -X HARDENED` fails with "Too many links". What does that mean?

---

## Exercise 7 — IPv6: what you must never filter

IPv6 has no ARP and no in-path fragmentation. ICMPv6 is not optional; it is load-bearing.

1. Verify neighbour discovery is working before you break it:

   ```bash
   ip -6 neigh show
   ip -6 addr show scope link
   ping -6 -c2 ff02::1%eth0 | head -n 5
   ```

2. Break it deliberately. Add a rule *above* the ICMPv6 acceptance rule:

   ```bash
   systemd-run --on-active=5m --unit=fw-rollback /usr/sbin/nft flush ruleset
   nft insert rule inet fw inbound meta nfproto ipv6 meta l4proto icmpv6 counter drop
   ip -6 neigh flush all
   ping -6 -c3 -W2 <link-local-peer>%eth0 ; echo "exit=$?"
   ip -6 neigh show
   ```

   Expected result: neighbour entries stay `INCOMPLETE` or `FAILED`; IPv6 connectivity to the host dies
   even though no TCP rule changed.

3. Remove the rule and confirm recovery:

   ```bash
   nft -a list chain inet fw inbound | grep icmpv6
   nft delete rule inet fw inbound handle <handle>
   systemctl stop fw-rollback.timer
   ip -6 neigh show
   ```

4. Demonstrate the PMTUD dependency with a smaller-MTU path (conceptual verification on the lab link):

   ```bash
   ip link set dev veth-fw mtu 1400
   ping -6 -c1 -M do -s 1452 <peer-v6>       # expect "Packet too big" feedback
   ```

5. Write the minimal correct ICMPv6 policy, following RFC 4890's "must not be dropped" list:

   ```nft
           meta nfproto ipv6 icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem } accept
           meta nfproto ipv6 icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } ip6 hoplimit 255 accept
           meta nfproto ipv6 icmpv6 type { nd-router-solicit, nd-router-advert } ip6 hoplimit 255 accept
           meta nfproto ipv6 icmpv6 type { mld-listener-query, mld-listener-report, mld-listener-done } ip6 saddr fe80::/10 accept
           meta nfproto ipv6 icmpv6 type echo-request limit rate 10/second accept
           meta nfproto ipv6 udp sport 547 udp dport 546 ip6 saddr fe80::/10 accept comment "DHCPv6 replies"
   ```

6. Confirm the implicit family dependency inside an `inet` table:

   ```bash
   nft add rule inet fw inbound ip saddr 10.0.0.0/8 counter accept
   nft -a list chain inet fw inbound | grep '10.0.0.0/8'
   ```

   Expected output shows nft has inserted the family test for you:

   ```text
   		ip saddr 10.0.0.0/8 counter packets 0 bytes 0 accept # handle 31
   ```

**Check your understanding**

- **Q7.1** Name four ICMPv6 types that must never be dropped on an inbound policy, and state what breaks
  for each.
- **Q7.2** What specific failure mode appears when `packet-too-big` is filtered, and why is it usually
  reported as "small pages load, large downloads hang"?
- **Q7.3** Why do the NDP rules in step 5 include `ip6 hoplimit 255`?
- **Q7.4** In an `inet` table, why does `ip saddr 10.0.0.0/8 accept` not accidentally accept IPv6 traffic?
- **Q7.5** Your host uses SLAAC. Which two ICMPv6 types must be accepted for addressing to work at all,
  and what is the security trade-off of accepting `nd-router-advert` from any link-local source?

---

## Exercise 8 — Tracing: proving which rule made the decision

Counters tell you *how many*. Tracing tells you *which rule, in which chain, in which order*.

1. Create a dedicated trace table, hooked earlier than everything else:

   ```bash
   nft add table inet trace
   nft add chain inet trace prerouting '{ type filter hook prerouting priority -301; }'
   nft add chain inet trace output     '{ type filter hook output     priority -301; }'
   nft add rule inet trace prerouting ip saddr 192.0.2.10 meta nftrace set 1
   nft add rule inet trace output     ip daddr 192.0.2.10 meta nftrace set 1
   ```

2. Watch the packet walk the ruleset:

   ```bash
   nft monitor trace
   ```

   From the traced source, hit a port that is being dropped. Expected output (abridged):

   ```text
   trace id 7a3c1f04 inet trace prerouting packet: iif "eth0" ether saddr aa:bb:cc:dd:ee:01 ip saddr 192.0.2.10 ip daddr 198.51.100.5 ip protocol tcp tcp sport 51422 tcp dport 8080 tcp flags == syn
   trace id 7a3c1f04 inet trace prerouting rule ip saddr 192.0.2.10 meta nftrace set 1 (verdict continue)
   trace id 7a3c1f04 inet fw inbound rule ct state vmap { established : accept, invalid : drop, related : accept } (verdict continue)
   trace id 7a3c1f04 inet fw inbound rule counter packets 41 bytes 2460 comment "unmatched inbound" (verdict continue)
   trace id 7a3c1f04 inet fw inbound verdict continue
   trace id 7a3c1f04 inet fw inbound policy drop
   ```

3. Read the counters as a second, cheaper signal:

   ```bash
   nft list chain inet fw inbound | grep -n counter
   nft reset counters table inet fw
   nft list chain inet fw inbound | grep -n counter
   ```

4. Diff two rulesets without counter noise:

   ```bash
   nft -s list ruleset > /tmp/before.nft
   nft add rule inet fw inbound tcp dport 9090 accept
   nft -s list ruleset > /tmp/after.nft
   diff -u /tmp/before.nft /tmp/after.nft
   ```

5. Do the same with the legacy front-end, for comparison:

   ```bash
   iptables -t raw -A PREROUTING -p tcp --dport 8080 -j TRACE
   xtables-monitor --trace &
   # generate traffic, then:
   iptables -t raw -D PREROUTING -p tcp --dport 8080 -j TRACE
   ```

6. Always remove tracing when you are done — it is expensive under load:

   ```bash
   nft delete table inet trace
   nft list ruleset | grep -c nftrace
   ```

7. Add JSON output to your toolbox for automated checks:

   ```bash
   nft -j list ruleset | head -c 400
   nft -j list ruleset | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["nftables"]))'
   ```

**Check your understanding**

- **Q8.1** Why is the trace chain given priority `-301` rather than `0`?
- **Q8.2** The trace ends in `verdict continue` followed by `policy drop`. What does that tell you about
  your ruleset, and what is the next thing you would check?
- **Q8.3** All packets of a flow are traced, or only some? Explain in terms of where `meta nftrace set 1`
  is evaluated.
- **Q8.4** When is `nft -s list ruleset` preferable to `nft list ruleset`, and what does `nft reset
  counters` do that `-s` does not?
- **Q8.5** Why should `nftrace` never be left enabled on a production firewall?
- **Q8.6** A rule counter is incrementing but the service is still unreachable. Name two causes that are
  *not* the firewall.

---

## Exercise 9 — Front-ends and adjacent tools: firewalld, ufw, ebtables, conntrackd

The exam expects awareness of these, and production expects you not to fight them.

1. **firewalld** (RHEL family). Inspect the model:

   ```bash
   systemctl is-active firewalld
   firewall-cmd --state
   firewall-cmd --get-default-zone
   firewall-cmd --get-active-zones
   firewall-cmd --zone=public --list-all
   grep -E '^FirewallBackend' /etc/firewalld/firewalld.conf
   ```

   Expected output:

   ```text
   running
   public
   public
     interfaces: eth0
   public (active)
     target: default
     services: dhcpv6-client ssh
     ports: 
     ...
   FirewallBackend=nftables
   ```

2. Show the runtime/permanent split — the number one firewalld operational trap:

   ```bash
   firewall-cmd --zone=public --add-service=https
   firewall-cmd --zone=public --list-services
   firewall-cmd --reload
   firewall-cmd --zone=public --list-services      # https is gone
   firewall-cmd --permanent --zone=public --add-service=https
   firewall-cmd --reload
   firewall-cmd --zone=public --list-services      # https persists
   ```

3. Look at what firewalld actually programs into the kernel:

   ```bash
   nft list tables
   nft list chain inet firewalld filter_INPUT
   ```

   Expected output:

   ```text
   table inet firewalld
   table ip firewalld
   table ip6 firewalld
   ```

4. Use a rich rule and a port forward, then promote runtime to permanent:

   ```bash
   firewall-cmd --zone=public --add-rich-rule='rule family="ipv4" source address="192.0.2.0/24" service name="ssh" log prefix="rich-ssh " level="info" limit value="3/m" accept'
   firewall-cmd --zone=public --add-forward-port=port=8080:proto=tcp:toport=80:toaddr=10.10.0.2
   firewall-cmd --runtime-to-permanent
   firewall-cmd --permanent --zone=public --list-rich-rules
   ```

5. **ufw** (Debian/Ubuntu). Only on a host where firewalld is *not* running:

   ```bash
   ufw status verbose
   ufw default deny incoming
   ufw default allow outgoing
   ufw allow from 192.0.2.0/24 to any port 22 proto tcp comment 'admin net'
   ufw limit 22/tcp
   ufw logging medium
   ufw enable
   ufw status numbered
   ```

   Expected output:

   ```text
   Status: active
        To                         Action      From
        --                         ------      ----
   [ 1] 22/tcp                     ALLOW IN    192.0.2.0/24               # admin net
   [ 2] 22/tcp                     LIMIT IN    Anywhere
   ```

   ```bash
   ufw delete 2
   grep -n 'ufw-before-input' /etc/ufw/before.rules | head -n 3
   ```

6. **ebtables / bridge family** — filtering at layer 2:

   ```bash
   ip link add br0 type bridge && ip link set br0 up
   ebtables -t filter -L 2>/dev/null || echo "ebtables not installed"
   sysctl net.bridge.bridge-nf-call-iptables 2>/dev/null
   nft add table bridge fw
   nft add chain bridge fw forward '{ type filter hook forward priority filter; policy accept; }'
   nft add rule bridge fw forward ether type arp arp operation reply arp saddr ip 10.10.0.2 accept
   nft list table bridge fw
   ip link del br0
   ```

7. **conntrackd** — state synchronisation for a firewall pair (inspection only):

   ```bash
   ls /etc/conntrackd/conntrackd.conf 2>/dev/null && grep -E '^\s*(Mode|IPv4_address|Interface)' /etc/conntrackd/conntrackd.conf
   conntrackd -s 2>/dev/null | head -n 10 || echo "conntrackd not running"
   ```

**Check your understanding**

- **Q9.1** In step 2, `https` disappeared after `--reload`. Explain the runtime/permanent model and give
  the two ways to make a runtime change durable.
- **Q9.2** firewalld owns `inet firewalld`. What happens to hand-written rules you add to that table, and
  where should your own rules go instead?
- **Q9.3** What does `ufw limit 22/tcp` actually enforce, and what is its nftables-native equivalent?
- **Q9.4** Give a scenario that `ebtables`/the nftables `bridge` family can solve but `iptables`/`ip` family
  cannot. What does `net.bridge.bridge-nf-call-iptables=1` change about that boundary?
- **Q9.5** Two firewalls run VRRP with `keepalived`. Without `conntrackd`, what exactly happens to
  established TCP sessions at failover, and why?
- **Q9.6** Why should firewalld and ufw never both be enabled on the same host?
- **Q9.7** What does `firewall-cmd --panic-on` do, and when would you use it?

---

## Answers

<details>
<summary><strong>Click to reveal all answers</strong></summary>

### Exercise 1

**A1.1** `(nf_tables)` means the binary is `xtables-nft-multi`: it speaks the iptables syntax but writes
rules into the **nf_tables** kernel subsystem, into tables named `ip filter`, `ip nat`, etc., marked with
a compatibility flag. `(legacy)` would mean `xtables-multi`, writing into the older `ip_tables`/`x_tables`
subsystem, which is a completely separate kernel path with its own hook registrations. Same syntax,
different storage — which is why `nft list ruleset` shows the former and not the latter.

**A1.2** `nft list ruleset` captures firewalld's *runtime* ruleset only. firewalld regenerates that
ruleset from its own XML configuration (`/etc/firewalld/`, `/usr/lib/firewalld/`) at every `--reload`
and at service start, so restoring the nft dump gives you rules that will be silently overwritten. A
complete backup of a firewalld host is `/etc/firewalld/` plus, optionally, the nft dump as a forensic
record.

**A1.3** `nft -f` is **additive**: without `flush ruleset` the file's contents are appended to whatever is
already loaded, duplicating rules and, worse, leaving stale rules that no longer appear in your source
file. A whole-file load is also **atomic** — the entire file is one netlink transaction, committed or
rejected as a unit, so the host is never briefly half-configured. A sequence of `nft add rule` commands
is a sequence of independent transactions, and a failure in the middle leaves a partial, possibly
open, firewall.

**A1.4** Evaluation order is by **hook priority**, not by tool: at a given hook, all registered handlers
run in ascending priority order, whether they were registered by `ip_tables` or by `nf_tables`. The
hazard is that neither tool can see the other's rules: `iptables-legacy -L` shows nothing about nft rules
and `nft list ruleset` shows nothing about legacy rules, so an operator debugging a drop can be looking
at a ruleset that is not the one making the decision. Pick one engine per host.

**A1.5** `-c`/`--check` parses and validates the file (syntax, referenced tables/chains/sets, type
correctness) **without committing anything to the kernel**. It turns a class of outages — a typo on line
80 of a 120-line file loaded after `flush ruleset` — into a shell error message.

### Exercise 2

**A2.1** In nftables the **chain policy is applied only after all rules have been evaluated without a
terminal verdict**. So a packet that reaches the end of `inbound` still hits `policy drop`. Separating
"log" from "drop" means the log rule is a plain non-terminal statement: you can add, remove or rate-limit
it without ever risking the drop behaviour, and the final `counter` gives you a cheap always-on metric
of unmatched traffic. Ending with `log ... drop` couples the two.

**A2.2** `iif` matches the interface **index** (`ifindex`), resolved once at rule-load time; `iifname`
matches the interface **name**, evaluated per packet. `iif` is faster but breaks when the interface is
deleted and recreated (containers, `wg0`, `ppp0`, VM taps) because the index changes while the name does
not. `iifname` also lets you write rules for interfaces that do not exist yet. Rule of thumb: `iif lo`
for the loopback, `iifname` for anything dynamic.

**A2.3** Yes, the second chain is still evaluated. In nftables, `accept` is a verdict for the **current
chain**: evaluation of that chain stops, but other base chains registered on the same hook continue to
be evaluated in priority order, and any of them may still drop the packet. `drop` is different — it is
immediate and final: the packet is discarded and no further chain at that hook runs. This asymmetry is
the classic nftables gotcha for administrators coming from iptables.

**A2.4** `invalid` means conntrack could not associate the packet with any known flow — out-of-window TCP
segments, a late RST, ICMP errors that reference no tracked connection, or traffic that was live when the
conntrack table was flushed. These packets match neither `established` nor `new`, so they would fall
through your entire policy chain. Dropping them explicitly and early is both cheaper and clearer than
relying on the policy, and it prevents oddities such as out-of-window segments being handed to the
`new`-state service rules.

**A2.5** Statements in a rule execute **left to right**. With `limit` first, the limiter acts as a gate:
only 5 packets per minute (plus a burst of 5) ever reach the `log` statement, so the kernel ring buffer
is protected during a flood. Swapped, every packet would be logged and only then rate-limited — the
limiter would be measuring something it no longer controls, and a SYN flood would fill `/var/log`.

**A2.6** A verdict map is a **single hash lookup** producing a verdict, whereas three rules are three
sequential match evaluations. The difference is invisible with three states and decisive with hundreds
of entries; it is also atomically updatable, since you can add and remove map elements without touching
the rule.

### Exercise 3

**A3.1** Plain sets are hash sets: they can only answer "is this exact value present?". A prefix such as
`203.0.113.0/24` is a **range** of values, so nftables stores interval sets in a different backend (an
ordered/red-black-tree or `pipapo` set implementation) that supports range lookup. `flags interval` is
what selects that backend; without it, the element is rejected at load time. The cost is a slightly more
expensive lookup than a pure hash; the benefit is that one element covers 256 addresses.

**A3.2** `add` inserts the element only if it is not already present — an existing element keeps its
original expiry, so a persistent attacker's entry ages out at the original deadline. `update` inserts if
absent and **refreshes the timeout** if present, so the entry survives as long as the traffic continues.
Use `update` for "keep them blocked while they keep knocking", `add` for "block for exactly one hour from
the first offence".

**A3.3** Per-packet cost: 4,000 rules are evaluated linearly, so a packet that matches nothing pays 4,000
comparisons; the set version pays one lookup, effectively constant time. Update cost: adding a prefix to
the rule-based version requires modifying the ruleset (a transaction that must re-verify the affected
chain), whereas `nft add element` changes only set contents, atomically, with no ruleset reload and no
disruption to packets in flight.

**A3.4** They are lost. Elements added from the packet path live only in kernel memory; `flush ruleset`
destroys the set together with its contents. `nft list ruleset` *does* dump current dynamic elements
(with their remaining `expires` values), so `nft list ruleset > file` before shutdown, and reload that
file, preserves a point-in-time snapshot. For anything that must genuinely survive, persist offenders to
disk from userspace (for example, `fail2ban` or a small script consuming the log prefix) rather than
relying on the set.

**A3.5** Because rules are evaluated in order and the `add` rule ends in `drop` only for packets that
exceed the rate. An address already in `@ssh_flood` must be dropped **before** reaching the
rate-limiting rule; otherwise its packets would keep being measured by the limiter and, while under the
rate, would fall through to the accept rule — the block would never actually take effect.

**A3.6** A `set` answers a membership question and the rule supplies the verdict (`tcp dport @ports
accept`). A `map` of type `inet_service : verdict` *is* the decision: `tcp dport vmap @svcmap` looks up
the port and executes the stored verdict, which may differ per element (`22 : accept, 25 : drop, 8080 :
jump webchain`). Maps let you change policy per key without adding rules.

### Exercise 4

**A4.1** Connection tracking registers at priority **-200** (`NF_IP_PRI_CONNTRACK`) on `prerouting` and
`output`. A `raw` chain has priority **-300**, i.e. it runs *before* conntrack, which is the only point at
which you can still say "do not track this packet at all". A `notrack` statement at `priority filter`
(0) would execute after the connection had already been created and would be meaningless.

**A4.2** The `accept` for your SSH session came from `ct state established`, not from the port-22 rule —
that rule only matches `ct state new`, i.e. a `SYN`. Deleting the conntrack entry means the client's next
data segment (an `ACK` with payload) matches no flow and is classified `invalid`, so it is dropped; the
server's replies are likewise unmatched outbound. The session hangs until TCP gives up. Recovery
requires a *new* connection: the client must reconnect so that a fresh `SYN` matches the `new` rule.

**A4.3** (1) Raise `net.netfilter.nf_conntrack_max` (and the hash size, via
`/sys/module/nf_conntrack/parameters/hashsize`, to keep bucket chains short). (2) Lower the timeouts that
are hoarding entries — `nf_conntrack_tcp_timeout_established` defaults to 432000 s (5 days), which on a
busy gateway keeps hundreds of thousands of dead flows alive; `nf_conntrack_udp_timeout` matters for DNS
and VoIP. (3) Stop tracking traffic that does not need state, with `notrack` in a `raw` chain. On a busy
NAT gateway, do (1) first — it is instantaneous, safe, and stops the packet loss; then fix the timeouts,
because raising `max` without fixing a 5-day timeout just postpones the same outage. Note that entries
belonging to NAT-ed flows can never be `notrack`ed, since NAT requires state.

**A4.4** `/proc/net/nf_conntrack` is the raw kernel export: it requires the `nf_conntrack` module (and, on
some kernels, `nf_conntrack_procfs` support / `CONFIG_NF_CONNTRACK_PROCFS`), prints one line per entry
including the L3 family and protocol numbers, and offers no filtering. `conntrack -L` (from the
`conntrack-tools` package) talks to the kernel over the **netlink** `ctnetlink` interface, which is the
supported API: it can filter (`-p`, `--src`, `--dport`, `--state`), delete (`-D`), flush (`-F`), update
(`-U`) and stream events (`-E`). Scripts should use `conntrack`; `/proc` is for a quick look.

**A4.5** Helpers parse application payloads and open expectations for `related` flows (an FTP data
connection, for instance). Automatic assignment meant that *any* traffic reaching the helper's well-known
port was parsed, so an attacker who could get traffic to port 21 could make the firewall open arbitrary
pinholes. Since Linux 4.7, `net.netfilter.nf_conntrack_helper` defaults to 0 and assignment must be
explicit. To make FTP work you must: (1) load the helper module (`modprobe nf_conntrack_ftp`), and (2)
assign it explicitly to the intended traffic — in nftables, declare a `ct helper` object and apply it
with `tcp dport 21 ct helper set "ftp-standard"`; in iptables, `-t raw -A PREROUTING -p tcp --dport 21 -j
CT --helper ftp`. Your filter chain must then accept `ct state related` for the data connection.

**A4.6** `[ASSURED]` marks a flow that has seen traffic in **both directions** and completed its handshake
semantics — the kernel considers it a real, live connection. When the table is full, the kernel attempts
`early_drop`: it evicts a **non-assured** entry from the same hash bucket to make room for the new one.
Assured entries are protected from that eviction, which is why a table full of assured entries produces
`table full, dropping packet` instead of silently recycling.

**A4.7** (1) An ICMP error (destination-unreachable, time-exceeded) whose embedded header refers to a
tracked flow — this is how PMTUD and traceroute survive a stateful firewall. (2) An FTP data connection
opened as an *expectation* by the FTP conntrack helper, or the equivalent for SIP/TFTP/PPTP helpers.

### Exercise 5

**A5.1** `nat prerouting` (priority -100) runs **before** `filter forward` (priority 0). By the time the
packet reaches the forward chain, its destination has already been rewritten, so the forward rule must
match the **internal, post-DNAT** address `10.10.0.2:8080` — not the public address and port the client
used. Writing the pre-NAT address there is one of the most common "port forward doesn't work" bugs.

**A5.2** Only the first packet of a flow traverses the `nat` chains; the resulting translation is stored
in the conntrack entry, and **conntrack** applies it to every subsequent packet in both directions. The
consequence is that adding, changing or removing a NAT rule has **no effect on flows that already exist**
— they keep using the translation recorded at creation time. After changing NAT rules you must flush the
affected conntrack entries (`conntrack -D ...`) if you need the change to apply immediately.

**A5.3** `snat to <address>` is a static rewrite: cheapest, and it survives interface flaps. `masquerade`
looks up the primary address of the **outgoing interface** for each new flow, so it costs an extra lookup
per new connection, but it is correct on uplinks whose address changes (DHCP, PPPoE) where a hardcoded
`snat` would break at every lease renewal. `masquerade` also registers a device notifier: when the
interface goes down, the associated conntrack entries are flushed, so stale translations to an address
that no longer exists are not kept. Use `snat` on static uplinks, `masquerade` on dynamic ones.

**A5.4** Forwarding must be enabled in the namespace that performs the **routing between the two
interfaces** — here, the root namespace, which owns `veth-fw` and `eth0`. `net.ipv4.ip_forward` is
namespaced, so setting it inside `lan` would have enabled forwarding for a namespace that has only one
interface and routes nothing; the packets would still have been dropped by the root namespace.

**A5.5** *Screened subnet (DMZ)*: a separate network segment holding publicly reachable services, placed
between two filtering boundaries so that a compromised public service still faces a firewall before the
internal network — enforced by the `forward` chain. *Bastion host*: a deliberately minimal, hardened host
that is the only system exposed to an untrusted network and the only permitted entry point for
administration — its own exposure is enforced by the `input` chain. *Dual-homed firewall*: a host with
interfaces in two networks and forwarding controlled so that no traffic passes without an explicit rule —
`forward` chain, `policy drop`. *Egress filtering*: restricting what may leave the network, to contain
data exfiltration and command-and-control callbacks; on this host it would be the `output` chain for the
firewall's own traffic and the `forward` chain for the LAN's.

**A5.6** Because NAT's filtering side effect is incidental, not policy: it drops inbound connections only
because there is no translation entry for them, and any DNAT rule, UPnP daemon, helper expectation, or
outbound-initiated flow punches straight through. It also provides no protection at all for traffic that
is allowed to traverse it, no logging, no state policy, and nothing for IPv6, where NAT is typically
absent. Address hiding is obscurity; the packet filter is the control.

### Exercise 6

**A6.1** `*filter` selects the table that the following lines belong to. `:INPUT ACCEPT [1204:98123]`
declares the built-in chain `INPUT` with default policy `ACCEPT` and, because `-c` was used, its current
packet and byte counters. `COMMIT` ends the table block and is what makes `iptables-restore` apply that
table's contents as a single transaction — without it, the block is not applied at all.

**A6.2** `iptables-restore` loads all rules for a table and commits them in one operation, so the kernel
switches from the old ruleset to the new one with no intermediate state where the host is unprotected.
`-n`/`--noflush` keeps that atomicity but changes the semantics from *replace* to *append*: existing rules
in those tables are preserved and the file's rules are added to them. Running the same file twice with
`-n` therefore duplicates every rule.

**A6.3** `nft add rule ip nat POSTROUTING ip saddr 10.0.0.0/8 oifname != "lo" counter masquerade`
(this is exactly what `iptables-translate` emits; note `!` becomes `!=` and the implicit `counter` that
iptables rules always carry).

**A6.4** `-m state` is the obsolete `xt_state` match, which knows only the basic states. `-m conntrack`
(`xt_conntrack`) supersedes it and exposes much more: `--ctstate` including `DNAT`/`SNAT`, plus
`--ctstatus`, `--ctproto`, `--ctorigsrc`/`--ctorigdst`, `--ctdir`, and `--ctexpire`. `-m state` is
implemented as an alias for backward compatibility. New rules should always use `-m conntrack --ctstate`.

**A6.5** Because the rules carry compatibility metadata that the `iptables-nft` front-end depends on to
reconstruct its own view of the ruleset. Editing them with `nft` — reordering, inserting a native nft
expression, or renaming — produces a table that `iptables -L`/`iptables-save` can no longer interpret,
typically failing with errors or silently omitting rules. The rule is: one table, one tool.

**A6.6** `DROP` discards the packet with no response, so the client waits for its TCP timeout — the port
appears *filtered*. `REJECT --reject-with icmp-port-unreachable` sends an ICMP error, so the client fails
immediately — the port appears *closed*. Use `REJECT` on internal networks where fast failure is a
usability feature (it avoids 30-second application hangs), and `DROP` on Internet-facing interfaces where
you do not want to confirm the host exists or to spend bandwidth answering scans. Note that for TCP,
`--reject-with tcp-reset` is the closest match to "nothing is listening".

**A6.7** A user-defined chain can only be deleted when it is **empty and unreferenced**. "Too many links"
means at least one rule still jumps to `HARDENED` (here, the `-A INPUT -i eth0 -j HARDENED` rule). Delete
the referencing rules first, then flush the chain (`-F HARDENED`), then delete it (`-X HARDENED`).

### Exercise 7

**A7.1** (1) `nd-neighbor-solicit` / `nd-neighbor-advert` — Neighbour Discovery replaces ARP; blocking it
means the host cannot resolve link-layer addresses and all IPv6 connectivity on the link fails. (2)
`packet-too-big` — IPv6 routers do not fragment, so Path MTU Discovery depends entirely on this message;
blocking it produces black-hole connections. (3) `destination-unreachable` — without it, failures become
timeouts instead of immediate errors, and some protocols hang. (4) `time-exceeded` — traceroute and loop
detection stop working. `parameter-problem` and, on SLAAC networks, `nd-router-advert`/`nd-router-solicit`
belong on the same list. This is the guidance in RFC 4890.

**A7.2** A PMTU black hole. The TCP handshake and small requests fit within the minimum MTU and succeed,
so the connection appears to work. As soon as the peer sends full-sized segments that exceed the MTU of
some link on the path, the router that cannot forward them sends `packet-too-big` — which your filter
drops — so the sender never learns to reduce its segment size and keeps retransmitting packets that can
never arrive. The user sees "the page starts loading and then stalls", or SSH that connects but freezes
on the first large output.

**A7.3** NDP messages are link-local by definition. RFC 4861 requires senders to set the hop limit to 255
and receivers to verify it, because a hop limit of 255 arriving at your interface proves the packet was
not routed — any router that forwarded it would have decremented the value. The check makes off-link NDP
spoofing impossible, so filtering on `ip6 hoplimit 255` enforces that guarantee at the firewall.

**A7.4** Because nft automatically generates a **dependency** on the network-layer protocol: writing `ip
saddr` in an `inet` table causes nft to prepend an implicit `meta nfproto ipv4` test, so the rule can only
match IPv4 packets. The same applies to `ip6 saddr` and IPv6. You can see the generated dependency in
`nft --debug=netlink list ruleset`.

**A7.5** `nd-router-solicit` (the host asks) and `nd-router-advert` (the router answers with the prefix
and default route); without them SLAAC produces no global address and no default route. The trade-off is
that accepting router advertisements from any link-local source is exactly the *rogue RA* attack — a
malicious host on the segment can advertise itself as the default router and intercept traffic. The
mitigations are switch-level RA Guard, filtering RAs to known router addresses, or
`net.ipv6.conf.<if>.accept_ra=0` with static configuration on routers and servers.

### Exercise 8

**A8.1** Priority -301 is lower than `raw` (-300) and therefore lower than conntrack (-200) and everything
else, so `meta nftrace set 1` is applied before any other chain has had a chance to act on the packet.
Tracing from priority 0 would miss every decision taken in `raw`, in conntrack, and in any chain with a
negative priority — including, frequently, the very rule that is dropping the packet.

**A8.2** It tells you that the packet matched **no terminal rule at all** in `inbound`: it fell off the end
of the chain and was discarded by the chain policy. So this is not a "wrong rule matched" bug, it is a
"missing rule" bug. The next check is the packet header printed in the first trace line — compare its
`iif`, addresses and `dport` against the rule you expected to match; the usual culprits are an interface
name that does not match (`iifname "eth0"` versus a predictable name like `enp1s0`), an address family
mismatch, or a rule placed after a terminal verdict.

**A8.3** Only some. `meta nftrace set 1` is a per-packet flag set when that rule is evaluated, so it marks
exactly the packets that traverse the chain containing it and match its conditions. If the trace rule is
in `prerouting`, locally generated replies (which take `output`) are not traced — which is why the
exercise adds a rule to both hooks. Tracing is not per-flow: for a busy flow, every packet that matches
generates trace events, which is precisely why it is expensive.

**A8.4** `-s`/`--stateless` omits counters and other runtime state from the output, which makes two dumps
diffable — otherwise every line differs because the packet counts moved. `nft reset counters` actually
**zeroes** the counters in the kernel (and prints their pre-reset values), which is what you want before
a reproduction test so that "did anything hit this rule?" has an unambiguous answer.

**A8.5** Every traced packet generates a netlink event describing the full path it took through the
ruleset. Under load this is a large amount of per-packet work and event traffic, and it will hurt
throughput and CPU well before it fills any buffer. Tracing is a diagnostic to be enabled, scoped as
narrowly as possible (a single source address), and removed.

**A8.6** (1) Nothing is listening: verify with `ss -lntup | grep <port>` — the counter increments on a rule
that accepts the packet, and the kernel then answers with RST or ICMP port unreachable. (2) The return
path is broken: asymmetric routing, a missing route back to the client, or SELinux/AppArmor blocking the
service from binding. Also worth checking: an upstream firewall or security group, and the service bound
to `127.0.0.1` instead of `0.0.0.0`.

### Exercise 9

**A9.1** firewalld maintains two configurations: the **runtime** ruleset, which is what is currently in
the kernel, and the **permanent** configuration, stored as XML under `/etc/firewalld/`. Commands without
`--permanent` change only runtime and are discarded by `--reload`, a restart, or a reboot; commands with
`--permanent` change only the XML and require `--reload` to take effect. The two ways to make a runtime
change durable are to repeat it with `--permanent` (then `--reload`), or to run `firewall-cmd
--runtime-to-permanent`, which writes the entire current runtime state to the permanent configuration.
The split exists on purpose: it gives you a self-reverting test — if a runtime change locks you out,
a reboot restores access.

**A9.2** They are destroyed at the next `firewall-cmd --reload` or firewalld restart, because firewalld
flushes and regenerates the tables it owns from its XML configuration. Your own rules belong either in
firewalld's own vocabulary (services, ports, rich rules, and `--direct` passthrough rules, all of which
firewalld will regenerate for you) or in a **separate table of your own** — nftables allows multiple base
chains on the same hook, so `table inet mycompany` with its own `input` chain coexists with
`inet firewalld` and survives firewalld reloads. Remember from A2.3 that `drop` in either chain is final,
while `accept` in one does not stop the other.

**A9.3** `ufw limit 22/tcp` denies a source address that has initiated **6 or more connections within 30
seconds**, allowing it otherwise — a crude but effective SSH brute-force damper (implemented with the
`recent` match on the legacy backend). The nftables-native equivalent is the dynamic-set idiom from
Exercise 3: `tcp dport 22 ct state new add @ssh_flood { ip saddr timeout 1h limit rate over 6/minute }
drop`, combined with a preceding `ip saddr @ssh_flood drop`.

**A9.4** Filtering **between ports of the same Linux bridge** — for example, isolating two VMs or
containers attached to `br0` from each other, or filtering ARP and non-IP EtherTypes. That traffic is
switched at layer 2 and never enters the IP routing path, so `ip`-family chains never see it; only
`ebtables` or the nftables `bridge` family (hooks `prerouting`/`forward`/`postrouting` at layer 2) can act
on it. Setting `net.bridge.bridge-nf-call-iptables=1` (with the `br_netfilter` module) makes bridged IP
traffic *also* traverse the IP-family `forward` chain — useful for reusing IP policy on a bridge, and a
notorious source of surprise when a bridged host is suddenly filtered by rules that were written for a
router.

**A9.5** They break. All established TCP sessions were tracked only on the previously active node; the
newly active node has an empty conntrack table, so the first packet of each surviving session matches no
flow, is classified `invalid` (it is not a `SYN`), and is dropped by the stateful policy. Every client
must reconnect. `conntrackd` fixes this by replicating conntrack entries between the two nodes
continuously (typically in FTFW mode over a dedicated link), so the standby node has an up-to-date shadow
table and can commit it (`conntrackd -c`) at failover, letting established flows continue.

**A9.6** Both are front-ends that assume they own the host's ruleset, and both flush and regenerate it on
start and reload. Running them together produces a race in which the last one to reload wins, an
effective policy that matches neither tool's status output, and a firewall whose state after a reboot
depends on systemd unit ordering. Choose one, and `systemctl disable --now` the other.

**A9.7** Panic mode drops **all** incoming and outgoing packets — it is an emergency kill switch that
severs the host's network connectivity, including your own SSH session, and it is not persistent across
a firewalld restart. Use it from the console when you believe a host is actively compromised and you want
to stop exfiltration or lateral movement immediately while preserving the machine for forensics. Undo it
with `firewall-cmd --panic-off`, and check it with `firewall-cmd --query-panic`.

</details>

---

## Reference sources

- LPI — Exam 303 Objectives (303-300, v3.0.0): <https://www.lpi.org/our-certifications/exam-303-objectives/>
- netfilter/nftables project: <https://netfilter.org/projects/nftables/index.html>
- nftables wiki — main page and quick reference: <https://wiki.nftables.org/wiki-nftables/index.php/Main_Page>
- nftables wiki — configuring chains, hooks and priorities: <https://wiki.nftables.org/wiki-nftables/index.php/Configuring_chains>
- nftables wiki — sets and dynamic sets: <https://wiki.nftables.org/wiki-nftables/index.php/Sets>
- nftables wiki — NAT: <https://wiki.nftables.org/wiki-nftables/index.php/Performing_Network_Address_Translation_(NAT)>
- nftables wiki — moving from iptables to nftables: <https://wiki.nftables.org/wiki-nftables/index.php/Moving_from_iptables_to_nftables>
- nftables wiki — ruleset debug and tracing: <https://wiki.nftables.org/wiki-nftables/index.php/Ruleset_debug/tracing>
- netfilter — iptables/ip6tables project page: <https://netfilter.org/projects/iptables/index.html>
- netfilter — conntrack-tools (`conntrack`, `conntrackd`): <https://netfilter.org/projects/conntrack-tools/index.html>
- netfilter — ebtables project page: <https://netfilter.org/projects/ebtables/index.html>
- Linux kernel documentation — connection tracking sysctls: <https://www.kernel.org/doc/html/latest/networking/nf_conntrack-sysctl.html>
- firewalld documentation: <https://firewalld.org/documentation/>
- ufw manual page: <https://manpages.ubuntu.com/manpages/noble/en/man8/ufw.8.html>
- RFC 4890 — Recommendations for Filtering ICMPv6 Messages in Firewalls: <https://www.rfc-editor.org/rfc/rfc4890>
- RFC 4861 — Neighbor Discovery for IP version 6: <https://www.rfc-editor.org/rfc/rfc4861>
- Shorewall (awareness): <https://shorewall.org/>