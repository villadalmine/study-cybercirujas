# LPIC-1 — 109.1 Fundamentals of Internet Protocols
## Guided Exercises

> **Scope of the objective:** IPv4/IPv6 addressing, netmasks and CIDR, private and reserved ranges, the difference between TCP, UDP and ICMP, and the well-known ports and services in `/etc/services`.
> **Official objective list:** <https://www.lpi.org/our-certifications/exam-101-objectives/> (objective 109.1 belongs to exam 102-500: <https://www.lpi.org/our-certifications/exam-102-objectives/>)

---

## Lab prerequisites

Run everything on a machine you own — a VM or container is ideal, because several steps bind listening sockets and capture traffic.

```bash
# Debian / Ubuntu
sudo apt install -y iproute2 iputils-ping iputils-tracepath traceroute \
                    tcpdump netcat-openbsd dnsutils ipcalc

# Fedora / RHEL / openSUSE
sudo dnf install -y iproute iputils traceroute tcpdump nmap-ncat \
                    bind-utils ipcalc
```

`tcpdump` needs `CAP_NET_RAW` (i.e. `sudo`). Nothing in this lab modifies persistent configuration except where explicitly stated and reverted.

---

## Exercise 1 — Read the machine's own IPv4 and IPv6 configuration

**Goal:** stop guessing what "my IP" means. Learn to read prefix length, scope, address flags and the routing decision the kernel actually makes.

### Steps

1. List every IPv4 address with its prefix length:

   ```bash
   ip -4 -brief address show
   ```

   ```
   lo               UNKNOWN        127.0.0.1/8
   enp1s0           UP             192.168.178.42/24
   ```

2. Now the full form, which is what you must be able to read on the exam and in an incident:

   ```bash
   ip -4 address show dev enp1s0
   ```

   ```
   2: enp1s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
       inet 192.168.178.42/24 brd 192.168.178.255 scope global dynamic noprefixroute enp1s0
          valid_lft 84391sec preferred_lft 84391sec
   ```

3. Repeat for IPv6 and note that a single interface normally carries **several** addresses:

   ```bash
   ip -6 address show dev enp1s0
   ```

   ```
   2: enp1s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP qlen 1000
       inet6 2001:db8:1234:5678:8b2a:44e1:9c07:3f11/64 scope global temporary dynamic
          valid_lft 6821sec preferred_lft 2621sec
       inet6 2001:db8:1234:5678:5054:ff:fe12:3456/64 scope global dynamic mngtmpaddr
          valid_lft 6821sec preferred_lft 3821sec
       inet6 fe80::5054:ff:fe12:3456/64 scope link
          valid_lft forever preferred_lft forever
   ```

4. Ask the kernel which source address and gateway it would use for a given destination — this is the single most useful networking command on Linux:

   ```bash
   ip route get 1.1.1.1
   ip -6 route get 2606:4700:4700::1111
   ```

   ```
   1.1.1.1 via 192.168.178.1 dev enp1s0 src 192.168.178.42 uid 1000
       cache
   2606:4700:4700::1111 from :: via fe80::1 dev enp1s0 src 2001:db8:1234:5678:8b2a:44e1:9c07:3f11 metric 1024 pref medium
   ```

5. Compare with the routing table itself:

   ```bash
   ip route show
   ip -6 route show
   ```

   ```
   default via 192.168.178.1 dev enp1s0 proto dhcp src 192.168.178.42 metric 100
   192.168.178.0/24 dev enp1s0 proto kernel scope link src 192.168.178.42 metric 100
   ```

> **Check your understanding — Block 1**
> 1.1 In step 2, what do `brd 192.168.178.255` and `scope global` mean, and how was the broadcast address derived?
> 1.2 In step 3 there are three IPv6 addresses. Classify each one (type and scope) and say which is used as the *source* for traffic to the internet, and why.
> 1.3 `valid_lft` and `preferred_lft` appear on IPv6 but say `forever` on the link-local address. What mechanism sets those lifetimes, and what happens to a *deprecated* address (preferred expired, valid not yet)?
> 1.4 In step 4 the IPv6 next hop is `fe80::1`, a link-local address, while the IPv4 next hop is a global address. Why can a link-local address serve as a default gateway?

---

## Exercise 2 — Netmasks, CIDR and subnetting

**Goal:** convert between dotted-decimal masks, prefix lengths and binary, and compute network / broadcast / host range fast enough to do it under exam pressure without a tool.

### Steps

1. Learn the two tables that make everything else arithmetic instead of guesswork.

   | Prefix in the octet | Mask octet | Block size | Binary |
   |---|---|---|---|
   | /25 | 128 | 128 | `10000000` |
   | /26 | 192 | 64 | `11000000` |
   | /27 | 224 | 32 | `11100000` |
   | /28 | 240 | 16 | `11110000` |
   | /29 | 248 | 8 | `11111000` |
   | /30 | 252 | 4 | `11111100` |

   The **block size** is `256 − mask_octet`. Subnet boundaries are multiples of the block size in the *interesting octet* (the last octet the mask does not fully cover).

2. Do one by hand before touching a tool. Take `192.168.10.75/27`:

   - Mask: `255.255.255.224`, interesting octet = 4th, block size = `256 − 224 = 32`.
   - Boundaries: 0, 32, 64, 96, 128, 160, 192, 224.
   - `75` falls in the block starting at `64`.
   - Network `192.168.10.64`, broadcast `192.168.10.64 + 32 − 1 = 192.168.10.95`.
   - Usable hosts `192.168.10.65` – `192.168.10.94`, i.e. `2^(32−27) − 2 = 30`.

3. Verify with `ipcalc` (the Jodies implementation shipped by Debian/Ubuntu; RHEL's rewrite uses `ipcalc --info`):

   ```bash
   ipcalc 192.168.10.75/27
   ```

   ```
   Address:   192.168.10.75        11000000.10101000.00001010.010 01011
   Netmask:   255.255.255.224 = 27 11111111.11111111.11111111.111 00000
   Wildcard:  0.0.0.31             00000000.00000000.00000000.000 11111
   =>
   Network:   192.168.10.64/27     11000000.10101000.00001010.010 00000
   HostMin:   192.168.10.65        11000000.10101000.00001010.010 00001
   HostMax:   192.168.10.94        11000000.10101000.00001010.010 11110
   Broadcast: 192.168.10.95        11000000.10101000.00001010.010 11111
   Hosts/Net: 30                    Class C, Private Internet
   ```

   The space in the binary column is the prefix boundary — everything left of it is the network part.

4. Split a `/24` into equal subnets and read them off:

   ```bash
   ipcalc 192.168.10.0/24 --s 30 30 30 30 2>/dev/null | grep -E 'Network|Hosts'
   ```

   If your `ipcalc` build lacks `--s`, derive it: 6 subnets of ≤30 hosts each needs `/27` (30 usable), giving 8 subnets at `.0 .32 .64 .96 .128 .160 .192 .224`.

5. Do the same for IPv6, where the arithmetic is hexadecimal and there is no broadcast and no `−2`:

   ```bash
   ipcalc 2001:db8:acad::/48 2>/dev/null || sipcalc 2001:db8:acad::/48
   ```

   A `/48` contains `2^(64−48) = 65536` subnets of `/64`: `2001:db8:acad:0::/64`, `2001:db8:acad:1::/64`, … `2001:db8:acad:ffff::/64`.

> **Check your understanding — Block 2**
> 2.1 For `172.16.35.99/21`: network address, broadcast address, first and last usable host, and number of usable hosts.
> 2.2 Are `192.168.4.130/26` and `192.168.4.190/26` on the same subnet? Show the reasoning, not just the verdict.
> 2.3 How many `/26` networks fit in a `/24`? How many usable hosts does each have?
> 2.4 A `/30` gives 2 usable hosts. What is a `/31` used for, and why does the "−2" rule not apply there?
> 2.5 Design VLSM allocations out of `192.168.50.0/24` for: LAN-A 100 hosts, LAN-B 50 hosts, LAN-C 20 hosts, and two point-to-point router links. Give each prefix and say what is left over.
> 2.6 Why is `/64` the standard subnet size in IPv6 even for a link with two hosts?

---

## Exercise 3 — Private, loopback, link-local and other reserved ranges

**Goal:** recognise instantly whether an address is routable on the internet, and know what a `169.254.x.x` or `fe80::` address is telling you during an outage.

### Steps

1. Write down the IPv4 ranges you must recognise on sight (RFC 1918, RFC 3927, RFC 6890, RFC 6598):

   | Range | CIDR | Purpose |
   |---|---|---|
   | `10.0.0.0` – `10.255.255.255` | `10.0.0.0/8` | Private (RFC 1918) |
   | `172.16.0.0` – `172.31.255.255` | `172.16.0.0/12` | Private (RFC 1918) |
   | `192.168.0.0` – `192.168.255.255` | `192.168.0.0/16` | Private (RFC 1918) |
   | `127.0.0.0` – `127.255.255.255` | `127.0.0.0/8` | Loopback |
   | `169.254.0.0` – `169.254.255.255` | `169.254.0.0/16` | Link-local / APIPA (RFC 3927) |
   | `100.64.0.0` – `100.127.255.255` | `100.64.0.0/10` | Carrier-grade NAT (RFC 6598) |
   | `224.0.0.0` – `239.255.255.255` | `224.0.0.0/4` | Multicast |
   | `255.255.255.255` | — | Limited broadcast |

2. And the IPv6 equivalents (RFC 4291, RFC 4193):

   | Prefix | Name | Notes |
   |---|---|---|
   | `::1/128` | Loopback | one single address, not a `/8` |
   | `::/128` | Unspecified | source during DAD/DHCPv6 solicitation |
   | `fe80::/10` | Link-local | mandatory on every IPv6 interface |
   | `fc00::/7` (in practice `fd00::/8`) | Unique Local Address | RFC 4193, not globally routed |
   | `2000::/3` | Global unicast | the currently allocated internet space |
   | `ff00::/8` | Multicast | IPv6 has **no broadcast** |
   | `2001:db8::/32` | Documentation | RFC 3849 — use it in all examples |

3. Verify the classification with a tool rather than trusting memory:

   ```bash
   for a in 10.5.4.3 172.15.0.1 172.20.0.1 192.168.1.1 169.254.9.9 100.100.1.1; do
       printf '%-15s ' "$a"; ipcalc -n -b "$a/24" 2>/dev/null | grep -i 'private\|Address' | tail -1
   done
   ```

   Note the trap in that list: `172.15.0.1` is **public**, `172.20.0.1` is private. The RFC 1918 middle block is `172.16.0.0/12`, i.e. `172.16` through `172.31` only.

4. Prove that a link-local IPv4 address is a symptom, not a configuration:

   ```bash
   ip -4 address show | grep 169.254
   journalctl -u NetworkManager -n 20 --no-pager | grep -i dhcp
   ```

   An interface holding `169.254.x.y/16` means DHCP got no answer and the host self-assigned.

5. Show that IPv6 link-local addresses require a **zone index** because the same prefix exists on every interface:

   ```bash
   ping -c2 fe80::1              # fails: "Invalid argument" / no route
   ping -c2 fe80::1%enp1s0       # works: the %zone selects the interface
   ```

> **Check your understanding — Block 3**
> 3.1 Which of these are RFC 1918 private addresses: `172.15.200.1`, `172.32.0.5`, `172.31.255.254`, `192.169.1.1`, `10.255.255.254`?
> 3.2 A server shows only `169.254.13.201/16` on `eth0`. What has happened, and what is the first thing you check?
> 3.3 IPv4 reserves an entire `/8` for loopback but IPv6 reserves a single address. What is a practical consequence of that difference for service binding (think `127.0.0.1` vs `127.0.0.53`)?
> 3.4 Why does `ping fe80::1` fail without `%enp1s0` while `ping 192.168.178.1` needs no such suffix?
> 3.5 Your architect wants "private IPv6" for an internal network. Which prefix do you use, how do you pick the 40 random bits, and why is it *not* the IPv6 equivalent of NAT?

---

## Exercise 4 — `/etc/services`, `/etc/protocols` and well-known ports

**Goal:** know where the name↔port mapping lives, how to query it programmatically, and memorise the port list the objective demands.

### Steps

1. Look at the file itself and understand the field layout:

   ```bash
   grep -vE '^\s*#|^\s*$' /etc/services | head -12
   ```

   ```
   tcpmux          1/tcp                           # TCP port service multiplexer
   ftp-data        20/tcp
   ftp             21/tcp
   ssh             22/tcp                          # SSH Remote Login Protocol
   telnet          23/tcp
   smtp            25/tcp          mail
   domain          53/tcp
   domain          53/udp
   http            80/tcp          www             # WorldWideWeb HTTP
   ```

   Fields: `service-name  port/protocol  [aliases…]  # comment`.

2. Query it through NSS instead of grepping — this is the correct way, because it honours `/etc/nsswitch.conf`:

   ```bash
   getent services ssh
   getent services 443/tcp
   getent services 53
   ```

   ```
   ssh                   22/tcp
   https                443/tcp
   domain                53/tcp
   ```

3. Do the same for IP protocol numbers, a separate registry that people constantly confuse with ports:

   ```bash
   getent protocols icmp tcp udp ipv6-icmp
   ```

   ```
   icmp                  1 ICMP
   tcp                   6 TCP
   udp                   17 UDP
   ipv6-icmp             58 IPv6-ICMP
   ```

4. Build the objective's port list yourself, so it comes from the system rather than from a slide:

   ```bash
   for p in 20 21 22 23 25 53 80 110 123 139 143 161 162 389 443 465 514 636 993 995; do
       printf '%-5s %s\n' "$p" "$(getent services "$p/tcp" || getent services "$p/udp")"
   done
   ```

   | Port | Proto | Service | Note |
   |---|---|---|---|
   | 20 | TCP | ftp-data | active-mode data channel |
   | 21 | TCP | ftp | control channel |
   | 22 | TCP | ssh | also SFTP and SCP |
   | 23 | TCP | telnet | cleartext — legacy only |
   | 25 | TCP | smtp | MTA-to-MTA |
   | 53 | UDP **and** TCP | domain | DNS |
   | 80 | TCP | http | |
   | 110 | TCP | pop3 | |
   | 123 | UDP | ntp | |
   | 139 | TCP | netbios-ssn | SMB over NetBIOS |
   | 143 | TCP | imap | |
   | 161 | UDP | snmp | polling |
   | 162 | UDP | snmptrap | traps, opposite direction |
   | 389 | TCP/UDP | ldap | |
   | 443 | TCP (+UDP for QUIC/HTTP-3) | https | |
   | 465 | TCP | submissions | SMTP over implicit TLS |
   | 514 | UDP | syslog | TCP/514 is `shell`/rsh |
   | 636 | TCP | ldaps | |
   | 993 | TCP | imaps | |
   | 995 | TCP | pop3s | |

5. Confirm that `/etc/services` is only a *label*, never an enforcement point:

   ```bash
   sudo cp /etc/services /tmp/services.bak
   nc -l 8080 &                       # bind a port with no /etc/services entry
   ss -ltnp 'sport = :8080'
   kill %1
   ```

   The socket binds regardless of whether a name exists.

> **Check your understanding — Block 4**
> 4.1 Which of the listed ports use UDP rather than TCP by default, and which one legitimately uses both?
> 4.2 If you delete the line `ssh 22/tcp` from `/etc/services`, does `sshd` stop working? Does `ss -ltn` change? Does `ss -lt` change?
> 4.3 Distinguish ports 465, 587 and 25 by role. Which one is deprecated-then-reinstated, and for what?
> 4.4 Port 514 appears twice in the registry with different protocols and different services. Name both and explain the operational risk of confusing them.
> 4.5 What is the difference between the number `6` in `/etc/protocols` and the number `22` in `/etc/services` — which header carries each?
> 4.6 Which port ranges are "well-known", "registered" and "dynamic/ephemeral", and which sysctl controls the last one on Linux?

---

## Exercise 5 — TCP versus UDP, observed on the wire

**Goal:** see the three-way handshake, the connectionless nature of UDP, and how each protocol signals failure.

### Steps

1. Open a capture in one terminal (**terminal A**):

   ```bash
   sudo tcpdump -n -i lo -c 12 'tcp port 9000 or udp port 9001 or icmp'
   ```

2. In **terminal B**, start a TCP listener and connect to it from **terminal C**:

   ```bash
   # terminal B
   nc -l 9000
   # terminal C
   printf 'hello tcp\n' | nc 127.0.0.1 9000
   ```

3. Read the capture in terminal A:

   ```
   IP 127.0.0.1.53712 > 127.0.0.1.9000: Flags [S],  seq 2216348918, win 65495, options [mss 65495,sackOK,TS val 3324180196 ecr 0,nop,wscale 7], length 0
   IP 127.0.0.1.9000 > 127.0.0.1.53712: Flags [S.], seq 3944281530, ack 2216348919, win 65483, options [mss 65495,sackOK,TS val 3324180196 ecr 3324180196,nop,wscale 7], length 0
   IP 127.0.0.1.53712 > 127.0.0.1.9000: Flags [.],  ack 1, win 512, length 0
   IP 127.0.0.1.53712 > 127.0.0.1.9000: Flags [P.], seq 1:11, ack 1, win 512, length 10
   IP 127.0.0.1.9000 > 127.0.0.1.53712: Flags [.],  ack 11, win 512, length 0
   IP 127.0.0.1.53712 > 127.0.0.1.9000: Flags [F.], seq 11, ack 1, win 512, length 0
   IP 127.0.0.1.9000 > 127.0.0.1.53712: Flags [F.], seq 1, ack 12, win 512, length 0
   IP 127.0.0.1.53712 > 127.0.0.1.9000: Flags [.],  ack 2, win 512, length 0
   ```

   `[S]` = SYN, `[S.]` = SYN+ACK, `[.]` = bare ACK, `[P.]` = PSH+ACK, `[F.]` = FIN+ACK, `[R]` = RST. Nine packets to move ten bytes.

4. Repeat with UDP. Restart the capture, then:

   ```bash
   # terminal B
   nc -u -l 9001
   # terminal C
   printf 'hello udp\n' | nc -u 127.0.0.1 9001
   ```

   ```
   IP 127.0.0.1.41234 > 127.0.0.1.9001: UDP, length 10
   ```

   One packet. No handshake, no acknowledgement, no teardown.

5. Now provoke both failure modes. Restart the capture, then connect to *closed* ports:

   ```bash
   nc -v -w2 127.0.0.1 9000    # nothing is listening now
   nc -u -v -w2 127.0.0.1 9001
   ```

   ```
   nc: connect to 127.0.0.1 port 9000 (tcp) failed: Connection refused
   ```

   In the capture:

   ```
   IP 127.0.0.1.53788 > 127.0.0.1.9000: Flags [S], seq 118219, length 0
   IP 127.0.0.1.9000 > 127.0.0.1.53788: Flags [R.], seq 0, ack 118220, win 0, length 0
   IP 127.0.0.1 > 127.0.0.1: ICMP 127.0.0.1 udp port 9001 unreachable, length 46
   ```

   TCP refuses with an RST it generates itself; **UDP has no refusal mechanism at all** — the rejection is an ICMP Destination Unreachable / Port Unreachable (type 3, code 3) produced by the IP layer.

6. Inspect socket state and per-protocol counters:

   ```bash
   ss -tan state established
   ss -uan
   ss -s
   nstat -az TcpRetransSegs TcpExtTCPSynRetrans UdpNoPorts UdpInErrors
   ```

   ```
   TcpRetransSegs                  14                 0.0
   TcpExtTCPSynRetrans              3                 0.0
   UdpNoPorts                       1                 0.0
   UdpInErrors                      0                 0.0
   ```

> **Check your understanding — Block 5**
> 5.1 Which exact packets form the three-way handshake, and what does each side prove by sending its part?
> 5.2 Why does the transfer in step 3 cost nine packets while step 4 costs one? Name three TCP guarantees you are paying for.
> 5.3 A UDP datagram sent to a closed port produced an ICMP message rather than a UDP reply. What does this imply for someone trying to scan UDP ports through a firewall that silently drops ICMP?
> 5.4 Compare the minimum header sizes of TCP and UDP and list what the extra bytes buy.
> 5.5 The UDP checksum is optional in IPv4 but mandatory in IPv6. Why did that change?
> 5.6 DNS, NTP, SNMP, syslog and VoIP all default to UDP. What property do they share that makes retransmission at the transport layer a bad trade?
> 5.7 In the tcpdump output `Flags [R.]` appeared instead of `[R]`. What is the difference, and when do you see a bare `[R]`?

---

## Exercise 6 — ICMP and ICMPv6: diagnostics, not "ping"

**Goal:** treat ICMP as a control protocol rather than a toy, and understand why blocking it breaks IPv6 outright.

### Steps

1. Send echo requests and read the reply metadata:

   ```bash
   ping -c3 1.1.1.1
   ```

   ```
   PING 1.1.1.1 (1.1.1.1) 56(84) bytes of data.
   64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=11.4 ms
   64 bytes from 1.1.1.1: icmp_seq=2 ttl=57 time=10.9 ms
   64 bytes from 1.1.1.1: icmp_seq=3 ttl=57 time=11.2 ms

   --- 1.1.1.1 ping statistics ---
   3 packets transmitted, 3 received, 0% packet loss, time 2003ms
   rtt min/avg/max/mdev = 10.912/11.183/11.436/0.214 ms
   ```

   `56(84)` = 56 bytes of payload + 8 bytes ICMP header + 20 bytes IPv4 header.

2. Watch the ICMP types on the wire:

   ```bash
   sudo tcpdump -n -i any -c4 'icmp or icmp6'
   ```

   ```
   IP 192.168.178.42 > 1.1.1.1: ICMP echo request, id 4711, seq 1, length 64
   IP 1.1.1.1 > 192.168.178.42: ICMP echo reply,   id 4711, seq 1, length 64
   ```

   Echo request is **type 8**, echo reply **type 0** in ICMPv4; **128** and **129** in ICMPv6.

3. Use ICMP to discover the path MTU manually — `-M do` sets the Don't Fragment bit:

   ```bash
   ping -c1 -M do -s 1472 1.1.1.1        # 1472 + 8 + 20 = 1500, fits
   ping -c1 -M do -s 1473 1.1.1.1        # one byte too many
   ```

   ```
   ping: local error: message too long, mtu=1500
   ```

   Across a tunnelled path you instead get the router's answer:

   ```
   From 10.8.0.1 icmp_seq=1 Frag needed and DF set (mtu = 1420)
   ```

   That is ICMP **type 3, code 4** — the message Path MTU Discovery depends on.

4. Let `tracepath` do it automatically, for both families:

   ```bash
   tracepath -4 1.1.1.1
   tracepath -6 2606:4700:4700::1111
   ```

   ```
    1?: [LOCALHOST]                      pmtu 1500
    1:  192.168.178.1                     0.512ms
    2:  10.64.0.1                         8.114ms asymm  3
    3:  no reply
    ...
        Resume: pmtu 1500 hops 9 back 9
   ```

5. See how `traceroute` exploits TTL expiry (ICMP type 11):

   ```bash
   traceroute -n 1.1.1.1        # default: UDP probes to high ports
   traceroute -n -I 1.1.1.1     # ICMP echo probes
   traceroute -n -T -p 443 1.1.1.1   # TCP SYN probes — survives most filters
   ```

   Each probe leaves with TTL 1, 2, 3…; every router that decrements TTL to zero returns **Time Exceeded**, revealing itself.

6. Observe ICMPv6 doing work that has no IPv4 equivalent — Neighbor Discovery:

   ```bash
   ip -6 neigh show
   ping -c2 ff02::1%enp1s0            # all-nodes link-local multicast
   sudo tcpdump -n -i enp1s0 -c6 'icmp6 and (ip6[40] == 135 or ip6[40] == 136)'
   ```

   ```
   IP6 fe80::5054:ff:fe12:3456 > ff02::1:ff00:1: ICMP6, neighbor solicitation, who has 2001:db8:1234:5678::1, length 32
   IP6 2001:db8:1234:5678::1 > fe80::5054:ff:fe12:3456: ICMP6, neighbor advertisement, tgt is 2001:db8:1234:5678::1, length 32
   ```

   Types 135/136 replace ARP; 133/134 (Router Solicitation / Advertisement) replace nothing in IPv4 — there is no IPv4 equivalent of router autoconfiguration at layer 3.

> **Check your understanding — Block 6**
> 6.1 ICMP has a protocol number but no port numbers. What is its protocol number, and what fields identify which reply belongs to which request?
> 6.2 Map each observed behaviour to an ICMP type/code: `Destination Host Unreachable`, `Connection timed out`, `Frag needed and DF set`, a `traceroute` hop line.
> 6.3 A firewall policy says "drop all ICMP". Name two things that break on IPv4 and two that break *catastrophically* on IPv6.
> 6.4 `ping` returns `ttl=57`. What was the likely initial TTL and how many hops did the reply cross?
> 6.5 Default `traceroute` on Linux sends UDP, not ICMP echo. How does it recognise the final destination then?
> 6.6 In IPv6 a router never fragments a transit packet. Which ICMPv6 message replaces "fragmentation needed", and what must the *source* do on receiving it?

---

## Exercise 7 — IPv6 in practice: notation, SLAAC and address selection

**Goal:** compress and expand addresses correctly, derive an EUI-64 interface identifier by hand, and understand why your modern distro probably does *not* use one.

### Steps

1. Apply the two compression rules (RFC 4291 §2.2, RFC 5952 for canonical form):
   - Drop **leading** zeros within each 16-bit group.
   - Replace **one** run of consecutive all-zero groups with `::`.

   ```bash
   # sipcalc expands and normalises for you
   sipcalc 2001:0db8:0000:0000:0008:0800:200c:417a | head -6
   ```

   ```
   Expanded Address        - 2001:0db8:0000:0000:0008:0800:200c:417a
   Compressed address      - 2001:db8::8:800:200c:417a
   ```

2. Derive a **modified EUI-64** identifier by hand from the MAC `52:54:00:12:34:56`:

   - Split in half and insert `ff:fe`: `52:54:00` + `ff:fe` + `12:34:56` → `5254:00ff:fe12:3456`
   - Flip bit 1 (the universal/local bit) of the first byte: `0x52 = 0101 0010` → `0101 0000 = 0x50`
   - Result: `5054:00ff:fe12:3456` → compressed `5054:ff:fe12:3456`
   - Link-local address: `fe80::5054:ff:fe12:3456`

   Confirm against the machine:

   ```bash
   ip link show enp1s0 | awk '/link\/ether/{print $2}'
   ip -6 addr show dev enp1s0 scope link
   ```

3. Watch SLAAC happen. Trigger a Router Solicitation and read the Router Advertisement:

   ```bash
   sudo rdisc6 enp1s0 2>/dev/null || sudo tcpdump -n -v -i enp1s0 -c2 'icmp6 and ip6[40] == 134'
   ```

   ```
   IP6 fe80::1 > ff02::1: ICMP6, router advertisement, length 88
       hop limit 64, Flags [none], pref medium, router lifetime 1800s, reachable time 0ms
       prefix info option (3), length 32 (4): 2001:db8:1234:5678::/64, Flags [onlink, auto], valid time 7200s, pref. time 3600s
   ```

   The host takes the `/64` prefix from the RA and appends its own interface identifier — no server, no lease, no state.

4. Inspect the knobs that decide *which* identifier is appended:

   ```bash
   sysctl net.ipv6.conf.enp1s0.accept_ra \
          net.ipv6.conf.enp1s0.autoconf \
          net.ipv6.conf.enp1s0.use_tempaddr \
          net.ipv6.conf.enp1s0.addr_gen_mode
   ```

   ```
   net.ipv6.conf.enp1s0.accept_ra = 1
   net.ipv6.conf.enp1s0.autoconf = 1
   net.ipv6.conf.enp1s0.use_tempaddr = 2
   net.ipv6.conf.enp1s0.addr_gen_mode = 0
   ```

   `addr_gen_mode` `0` = EUI-64, `2`/`3` = stable-privacy (RFC 7217). `use_tempaddr = 2` enables temporary addresses (RFC 8981) and *prefers* them as source.

5. Derive the solicited-node multicast address the interface must join for `fe80::5054:ff:fe12:3456`: take the low 24 bits (`12:3456`) and prepend `ff02::1:ff` → `ff02::1:ff12:3456`. Verify:

   ```bash
   ip maddr show dev enp1s0 | grep -i ff02
   netstat -g6 2>/dev/null | head
   ```

6. Confirm the source-address preference rules (RFC 6724) empirically:

   ```bash
   ip -6 route get 2606:4700:4700::1111 | grep -o 'src [0-9a-f:]*'
   getent ahosts www.kernel.org | head -4
   ```

> **Check your understanding — Block 7**
> 7.1 Compress: `2001:0db8:0000:0001:0000:0000:0000:0001` and `ff02:0000:0000:0000:0000:0000:0000:0001`. Expand: `::ffff:192.0.2.1`.
> 7.2 Why may `::` appear only once in an address?
> 7.3 Derive the EUI-64 link-local address for MAC `00:1a:2b:3c:4d:5e`. Show the bit flip explicitly.
> 7.4 Modern Fedora and Ubuntu do not build addresses from the MAC by default. What do they use instead, and which privacy problem does that solve that EUI-64 created?
> 7.5 List four structural differences between the IPv4 and IPv6 headers, and give one operational consequence of each.
> 7.6 SLAAC gives an address, prefix and gateway. What does it *not* give, and what two mechanisms cover the gap?
> 7.7 A host has both a global IPv6 address and an IPv4 address, and the destination has AAAA and A records. Which is tried first, and what mechanism prevents a long stall when IPv6 is broken?

---

## Exercise 8 — Diagnose from the symptom: refused, timeout, no route, DNS

**Goal:** turn four indistinguishable "it doesn't work" reports into four distinct layer-specific verdicts.

### Steps

1. Establish the baseline of what is listening locally:

   ```bash
   sudo ss -ltnup
   ```

   ```
   Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
   udp   UNCONN 0      0          127.0.0.53:53        0.0.0.0:*     users:(("systemd-resolve",pid=612,fd=12))
   udp   UNCONN 0      0       0.0.0.0%enp1s0:68       0.0.0.0:*     users:(("NetworkManager",pid=744,fd=22))
   tcp   LISTEN 0      4096       127.0.0.53:53        0.0.0.0:*     users:(("systemd-resolve",pid=612,fd=13))
   tcp   LISTEN 0      128           0.0.0.0:22        0.0.0.0:*     users:(("sshd",pid=901,fd=3))
   tcp   LISTEN 0      128              [::]:22           [::]:*     users:(("sshd",pid=901,fd=4))
   ```

   Read the **bind address**, not just the port: `127.0.0.53:53` is unreachable from the network; `0.0.0.0:22` is not.

2. Produce symptom A — *connection refused*:

   ```bash
   nc -vz 127.0.0.1 9999
   ```
   ```
   nc: connect to 127.0.0.1 port 9999 (tcp) failed: Connection refused
   ```
   The host answered with RST. It is up, reachable, and nothing is bound to that port.

3. Produce symptom B — *timeout*:

   ```bash
   nc -vz -w3 192.0.2.10 22
   ```
   ```
   nc: connect to 192.0.2.10 port 22 (tcp) timed out: Operation now in progress
   ```
   No answer at all: a firewall DROPping, or a host that is down.

4. Produce symptom C — *no route*:

   ```bash
   ip route get 203.0.113.9 2>&1
   ```
   ```
   RTNETLINK answers: Network is unreachable
   ```
   The failure happened before a packet was ever emitted — a routing-table problem, not a network problem.

5. Produce symptom D — *name resolution*:

   ```bash
   getent hosts does-not-exist.invalid ; echo "exit=$?"
   dig +short A example.com
   dig +short AAAA example.com
   resolvectl status | head -20
   ```

6. Confirm which transport DNS actually used, and force the other one:

   ```bash
   sudo tcpdump -n -i any -c4 'port 53' &
   dig +short A www.kernel.org @1.1.1.1
   dig +tcp +short A www.kernel.org @1.1.1.1
   ```

   ```
   IP 192.168.178.42.42311 > 1.1.1.1.53: 12345+ A? www.kernel.org. (32)
   IP 1.1.1.1.53 > 192.168.178.42.42311: 12345 2/0/0 A 139.178.84.217 (64)
   IP 192.168.178.42.51022 > 1.1.1.1.53: Flags [S], seq 88112, length 0
   IP 1.1.1.1.53 > 192.168.178.42.51022: Flags [S.], seq 4413, ack 88113, length 0
   ```

7. Map port to process for an established connection, the way you would during an incident:

   ```bash
   ss -tnp state established '( dport = :443 or sport = :443 )' | head
   ```

> **Check your understanding — Block 8**
> 8.1 Order these four verdicts from "closest to the application" to "closest to the wire": `Connection refused`, `Network is unreachable`, `Connection timed out`, `Name or service not known`.
> 8.2 A service is listening on `127.0.0.1:8080` and a remote client gets `Connection refused`. Nothing is wrong with the firewall. What is wrong, and what single change fixes it?
> 8.3 Why does a DROP firewall rule produce a timeout while a REJECT rule produces `Connection refused`? Which packet does REJECT send for TCP, and which for UDP?
> 8.4 `ss -ltn` shows both `0.0.0.0:22` and `[::]:22`. On many systems only `[::]:22` appears yet IPv4 clients still connect. Explain, and name the sysctl involved.
> 8.5 DNS used UDP first and TCP only when forced. Name two situations where a resolver switches to TCP on its own.
> 8.6 You can `ping 8.8.8.8` but not `ping google.com`. Which layer is broken, and which two files (or one service) do you inspect first?

---

## Exercise 9 — Integrative: document a host's network posture

**Goal:** produce, in one pass, the evidence an auditor or an on-call engineer would ask for.

### Steps

1. Write and run this collector:

   ```bash
   #!/usr/bin/env bash
   # net-posture.sh — summarise the L3/L4 posture of this host
   set -euo pipefail

   echo "== Addresses =="
   ip -brief address show

   echo; echo "== Default routes =="
   ip -4 route show default
   ip -6 route show default

   echo; echo "== Listening TCP/UDP sockets (with binding scope) =="
   ss -ltnup | awk 'NR==1 || $5 !~ /^127\.|^\[::1\]/'

   echo; echo "== Ports exposed on non-loopback addresses =="
   ss -ltn | awk 'NR>1 {split($4,a,":"); if (a[1] != "127.0.0.1" && $4 !~ /\[::1\]/) print $4}' | sort -u

   echo; echo "== Resolvers =="
   resolvectl status 2>/dev/null | grep -E 'DNS Servers|DNS Domain' || cat /etc/resolv.conf

   echo; echo "== Path MTU to the default gateway =="
   gw=$(ip -4 route show default | awk '{print $3; exit}')
   tracepath -4 -n "$gw" 2>/dev/null | tail -1
   ```

2. Run it and reconcile each listening socket against `/etc/services`:

   ```bash
   chmod +x net-posture.sh && ./net-posture.sh | tee posture.txt
   ss -ltn | awk 'NR>1 {n=split($4,a,":"); print a[n]}' | sort -un |
       while read -r p; do printf '%-6s %s\n' "$p" "$(getent services "$p/tcp" | awk '{print $1}')"; done
   ```

3. For every port exposed on a non-loopback address, answer in writing: which process owns it, whether the protocol is encrypted, and whether it should be reachable from outside the host's subnet.

> **Check your understanding — Block 9**
> 9.1 The report lists `0.0.0.0:23` owned by `inetd`. State the risk in one sentence and the correct replacement.
> 9.2 It also lists `0.0.0.0:389` but not `0.0.0.0:636`. What is the finding, and what would you check before recommending a change?
> 9.3 `0.0.0.0:161` is present and the host is on a routed network. Which two SNMP-specific issues do you raise?
> 9.4 The path MTU to the gateway comes back as 1492 rather than 1500. What link technology does that suggest, and which TCP option makes the difference visible?
> 9.5 A socket appears as `[::]:5432` with no matching IPv4 entry. Is PostgreSQL reachable over IPv4? What decides it?

---

<details>
<summary><strong>Answers</strong></summary>

### Block 1 — Local IP configuration

**1.1** `brd 192.168.178.255` is the subnet's directed broadcast address, obtained by setting every host bit to 1: address `192.168.178.42` with mask `/24` → network `192.168.178.0`, host bits all-ones → `192.168.178.255`. `scope global` means the address is valid for communication with any destination; contrast `scope host` (loopback, valid only inside this machine) and `scope link` (valid only on the attached link). `noprefixroute` means NetworkManager, not the kernel, manages the on-link route for that prefix.

**1.2**
- `fe80::5054:ff:fe12:3456/64` — **link-local**, `scope link`, mandatory on every IPv6-enabled interface, used for NDP and as the next hop.
- `2001:db8:1234:5678:5054:ff:fe12:3456/64` — **global unicast**, stable, derived here via EUI-64; flagged `mngtmpaddr` because it is the address from which temporary addresses are generated.
- `2001:db8:1234:5678:8b2a:44e1:9c07:3f11/64` — **global unicast, temporary** (RFC 8981 privacy address), random identifier, short lifetime.

The **temporary** address is used as source for outbound internet traffic, because RFC 6724 source-address selection (as amended by RFC 8981 and Linux's `use_tempaddr=2`) prefers temporary over public addresses for outgoing connections. The stable one remains available for inbound service.

**1.3** The lifetimes come from the **Prefix Information option in Router Advertisements** (RFC 4862): `valid_lft` from *Valid Lifetime*, `preferred_lft` from *Preferred Lifetime*. Link-local addresses are not learned from RAs, so they are `forever`. A **deprecated** address (preferred expired, valid not) is still usable for *existing* connections but is no longer chosen as source for *new* ones — which is exactly how IPv6 performs make-before-break renumbering without dropping sessions.

**1.4** Because the next hop only has to be reachable **on the link**, not globally. The router's link-local address is guaranteed to exist, is stable across renumbering, and never changes when the site's global prefix changes — which is why RAs advertise the router by its link-local address and why IPv6 default routes normally point at `fe80::`. Such a route is meaningless without the interface, hence `dev enp1s0` is always part of it.

---

### Block 2 — Netmasks, CIDR and subnetting

**2.1** `172.16.35.99/21` → mask `255.255.248.0`, interesting octet is the third, block size `256 − 248 = 8`. Boundaries: 0, 8, 16, 24, **32**, 40… `35` falls in the block starting at 32.
- Network: `172.16.32.0`
- Broadcast: `172.16.39.255`
- First usable: `172.16.32.1`, last usable: `172.16.39.254`
- Usable hosts: `2^(32−21) − 2 = 2048 − 2 = 2046`

**2.2** Yes. `/26` → block size 64 → boundaries `.0 .64 .128 .192`. `130` and `190` both fall in `128–191`, so both belong to `192.168.4.128/26` (broadcast `.191`). They can talk without a router.

**2.3** `2^(26−24) = 4` subnets: `.0/26`, `.64/26`, `.128/26`, `.192/26`. Each has `2^(32−26) − 2 = 62` usable hosts.

**2.4** A `/31` is used for **point-to-point links** under RFC 3021. On a point-to-point link there is no need for a broadcast address (there is exactly one possible peer) and no need for a network identifier, so both addresses are assignable as hosts. It halves the address waste of `/30` on router-to-router links.

**2.5** Allocate largest first (that is the whole point of VLSM):

| Segment | Requirement | Prefix | Range | Usable |
|---|---|---|---|---|
| LAN-A | 100 hosts | `192.168.50.0/25` | `.0`–`.127` | 126 |
| LAN-B | 50 hosts | `192.168.50.128/26` | `.128`–`.191` | 62 |
| LAN-C | 20 hosts | `192.168.50.192/27` | `.192`–`.223` | 30 |
| p2p-1 | 2 hosts | `192.168.50.224/30` | `.224`–`.227` | 2 |
| p2p-2 | 2 hosts | `192.168.50.228/30` | `.228`–`.231` | 2 |

Left over: `192.168.50.232` – `192.168.50.255` (24 addresses, i.e. a free `/29` + `/30` + `/31` + …), available for growth.

**2.6** Because **SLAAC requires a 64-bit interface identifier** (RFC 4862 / RFC 4291): the interface ID is generated to fill the lower 64 bits, so a prefix longer than `/64` breaks stateless autoconfiguration, and several other mechanisms (privacy addresses, cryptographically generated addresses, Subnet-Router anycast) assume the same split. Address conservation is not a concern — a single `/64` holds `2^64` addresses, and ISPs delegate `/56` or `/48` precisely so every link can have one.

---

### Block 3 — Reserved ranges

**3.1** Private: `172.31.255.254` (inside `172.16.0.0/12`) and `10.255.255.254` (inside `10.0.0.0/8`).
Public: `172.15.200.1` (below the block), `172.32.0.5` (above the block — `/12` ends at `172.31`), `192.169.1.1` (the private block is `192.168.0.0/16`, not `192.169`).

**3.2** DHCP received no reply, so the host self-assigned an IPv4 link-local address (APIPA, RFC 3927). First checks, in order: is the link actually up (`ip link show eth0` → `LOWER_UP`, `ethtool eth0` for carrier); is a DHCP client running (`systemctl status NetworkManager` / `dhcpcd` / `systemd-networkd`); and are DISCOVER packets leaving and anything coming back (`sudo tcpdump -n -i eth0 port 67 or port 68`). Only then suspect the DHCP server or a VLAN/trunk misconfiguration.

**3.3** In IPv4 the whole `127.0.0.0/8` is loopback, so different local services can bind different loopback addresses — that is exactly how `systemd-resolved` uses `127.0.0.53:53` while a real DNS server can still use `127.0.0.1:53`, and how one can run many local instances on the same port. IPv6 has only `::1`, so this trick has no IPv6 equivalent; local services must differentiate by port instead.

**3.4** `fe80::/10` is link-local: the *same* prefix exists simultaneously on every interface, so the address alone is ambiguous — the kernel cannot pick an egress interface. The `%zone` suffix (the "scope ID") disambiguates. `192.168.178.1` is a global-scope address and matches exactly one route in the routing table, so no disambiguation is needed.

**3.5** Use a **Unique Local Address** from `fd00::/8` (RFC 4193). The 40 bits after `fd` must be **randomly generated**, not chosen — e.g. `head -c5 /dev/urandom | xxd -p` → `fdXX:XXXX:XXXX::/48` — which is what makes accidental collisions between merged networks vanishingly unlikely. It is **not** IPv6 NAT: ULAs are a *scope* decision (not globally routed), and the standard design runs ULAs *alongside* global addresses on the same interface rather than translating between them. Address translation is not part of the model; RFC 6724 handles which source to use.

---

### Block 4 — `/etc/services` and ports

**4.1** UDP by default: **123** (NTP), **161** (SNMP), **162** (SNMP trap), **514** (syslog). Both TCP and UDP legitimately: **53** (DNS) — UDP for ordinary queries, TCP for zone transfers and oversized responses. **389** is registered for both but LDAP uses TCP in practice (UDP/389 was CLDAP). **443** is TCP for HTTP/1.1 and HTTP/2 and UDP for QUIC/HTTP-3.

**4.2** `sshd` keeps working: it binds port 22 from `sshd_config`'s `Port` directive (a number), not from a name lookup — and even when a config uses a name, the lookup happens once at start. `ss -ltn` does **not** change (`-n` means numeric). `ss -lt` **does** change: without `-n` it resolves port numbers to names via NSS, so port 22 would print as `22` instead of `ssh`.

**4.3**
- **25/tcp (smtp)** — server-to-server mail relay between MTAs. Widely blocked outbound by consumer ISPs.
- **587/tcp (submission)** — mail *submission* from a user agent, authenticated, with STARTTLS opportunistic upgrade (RFC 6409).
- **465/tcp** — originally `smtps` (implicit TLS), **deprecated in 1998** in favour of STARTTLS on 587, then **reinstated in 2018 by RFC 8314** as `submissions`, because implicit TLS avoids the STARTTLS-stripping downgrade attack. It is now the recommended submission port.

**4.4** `syslog 514/udp` (classic remote logging) and `shell 514/tcp` (rsh, the Berkeley remote shell). Operational risk: a firewall rule written as "allow 514" without specifying the protocol opens rsh — an unauthenticated, cleartext remote-execution service — while you believed you were permitting log shipping. Always write rules as `514/udp`.

**4.5** `6` in `/etc/protocols` is the **IP protocol number**, carried in the `Protocol` field of the IPv4 header (or `Next Header` in IPv6); it says which transport follows. `22` in `/etc/services` is a **port number**, carried in the TCP (or UDP) header; it identifies the application endpoint. Different headers, different layers, different registries — ICMP (protocol 1) has a protocol number and no ports at all.

**4.6**
- **Well-known / system**: 0–1023 — on Linux, binding these requires `CAP_NET_BIND_SERVICE` (historically root).
- **Registered / user**: 1024–49151 — assigned by IANA on request.
- **Dynamic / private / ephemeral**: 49152–65535 per IANA.

Linux does not use the IANA ephemeral range by default; it uses `net.ipv4.ip_local_port_range` (typically `32768 60999`), readable with `sysctl net.ipv4.ip_local_port_range`. The same range governs IPv6.

---

### Block 5 — TCP vs UDP

**5.1** SYN → SYN/ACK → ACK. The client's SYN carries its Initial Sequence Number (ISN); the server's SYN/ACK acknowledges it and carries the server's ISN; the client's ACK acknowledges the server's ISN. Each side thereby proves it **received** the other's ISN, which establishes bidirectional reachability and defeats blind spoofing (an off-path attacker cannot guess the ISN). Options such as MSS, window scale, SACK-permitted and timestamps are negotiated in the first two packets only.

**5.2** Nine packets = 3 handshake + 1 data + 1 ACK of the data + 4 for the FIN/ACK teardown in both directions. You are paying for: (a) **reliable delivery** — every byte is acknowledged and retransmitted if lost; (b) **ordered delivery** — sequence numbers let the receiver reassemble; (c) **flow and congestion control** — the advertised window plus the congestion window prevent overrunning the receiver or the path. Also connection state, so the endpoints agree on when the stream begins and ends.

**5.3** UDP has no in-band way to say "nobody is here", so the only negative signal is **ICMP type 3, code 3**. If the firewall drops ICMP, a closed UDP port and a filtered UDP port and an open-but-silent UDP port all look identical — silence. That is why UDP scanning is slow and unreliable (`nmap -sU` must wait for timeouts and can only report `open|filtered`), and it is also why blanket ICMP dropping degrades diagnosability rather than improving security.

**5.4** UDP header = **8 bytes**: source port, destination port, length, checksum. TCP header = **20 bytes minimum** (up to 60 with options): the same two ports plus sequence number, acknowledgement number, data offset, flags, window size, checksum, urgent pointer, and options (MSS, SACK, window scale, timestamps). The extra 12+ bytes buy sequencing, acknowledgement, windowing and connection state.

**5.5** Because **IPv6 removed the header checksum from the network layer** (RFC 8200). In IPv4 a corrupted address or port could still be caught by the IPv4 header checksum; in IPv6 nothing at layer 3 verifies integrity, so the transport checksum — which covers a pseudo-header including the addresses — becomes the only end-to-end protection and is therefore mandatory. (The narrow exception is certain tunnel encapsulations under RFC 6935/6936.)

**5.6** They are all **latency-sensitive or idempotent, and tolerate loss better than delay**. A retransmitted NTP sample or VoIP frame arriving late is worse than useless — it corrupts the measurement or the audio. A lost DNS query is cheaper to re-issue at the application layer with a fresh transaction ID than to maintain per-query connection state on a server handling millions of queries per second. TCP's head-of-line blocking would make one lost packet stall everything behind it.

**5.7** `[R.]` is **RST+ACK**: the RST acknowledges the sequence number of the offending packet — sent when a SYN reaches a closed port, so the sender knows exactly which attempt was refused. A bare `[R]` (RST without ACK) is sent when there is nothing valid to acknowledge — e.g. a packet arriving for a connection the receiver has no state for, or an abortive close of an established connection (`SO_LINGER` with a zero timeout).

---

### Block 6 — ICMP and ICMPv6

**6.1** ICMPv4 is **IP protocol 1**; ICMPv6 is **IP protocol 58**. There are no ports. Echo request/reply carry an **Identifier** and a **Sequence Number** in the ICMP header; the kernel (or `ping`) uses the identifier to match replies to the process and the sequence number to match them to the individual probe. Error messages (types 3, 11, …) instead quote the **first bytes of the offending packet**, including its IP header and the first 8 bytes of the transport header — which is exactly enough to recover the original ports and hand the error to the right socket.

**6.2**
- `Destination Host Unreachable` → **type 3, code 1** (Destination Unreachable / Host Unreachable). ICMPv6: type 1, code 3.
- `Connection timed out` → **no ICMP at all**. This is the absence of any response — the local TCP stack gave up. That is the diagnostic value: silence means a DROP or a dead host.
- `Frag needed and DF set` → **type 3, code 4** (Fragmentation Needed and DF Set). ICMPv6: **type 2**, Packet Too Big.
- A `traceroute` hop line → **type 11, code 0** (Time Exceeded / TTL exceeded in transit). ICMPv6: type 3, code 0.

**6.3** IPv4 breakage: **Path MTU Discovery** stops working (type 3/4 is dropped, producing the classic "small pages load, large ones hang" black hole), and diagnostics — `ping`, `traceroute`, and fast failure via Destination Unreachable — go dark, turning instant errors into 2-minute timeouts.
IPv6 breakage is worse and immediate: **Neighbor Discovery** (types 135/136) replaces ARP, so hosts on the same link cannot resolve each other's link-layer addresses; and **Router Solicitation/Advertisement** (133/134) is how hosts get their prefix and default route, so SLAAC never completes. Additionally, routers never fragment in IPv6, so blocking **Packet Too Big (type 2)** black-holes every path with a reduced MTU. RFC 4890 exists precisely to specify what may and may not be filtered.

**6.4** Common initial TTL values are 64 (Linux, macOS, most network gear), 128 (Windows) and 255 (some routers/Solaris). `57` is `64 − 7`, so the initial TTL was almost certainly **64** and the reply crossed **7** routers. Note this measures the *return* path, which may differ from the forward path.

**6.5** It sends UDP probes to a range of **high, deliberately unused destination ports** (from 33434 upwards). Intermediate routers reply with Time Exceeded; the **final destination**, having nothing bound to that port, replies with **ICMP Destination Unreachable / Port Unreachable (type 3, code 3)** instead. That distinct message is how `traceroute` knows it has arrived and stops.

**6.6** **ICMPv6 type 2, Packet Too Big**, which carries the MTU of the constrained link. On receiving it the **source** must reduce the packet size — either by lowering its own MSS/segment size, or, if it insists on sending larger payloads, by performing fragmentation itself using the IPv6 **Fragment extension header**. Routers in the middle are forbidden from fragmenting (RFC 8200 §4.5), which is why dropping type 2 creates an undetectable black hole.

---

### Block 7 — IPv6 in practice

**7.1**
- `2001:0db8:0000:0001:0000:0000:0000:0001` → **`2001:db8:0:1::1`** (the `::` must replace the *longest* zero run — the three trailing groups, not the single group in position 3).
- `ff02:0000:0000:0000:0000:0000:0000:0001` → **`ff02::1`** (the all-nodes link-local multicast address).
- `::ffff:192.0.2.1` → **`0000:0000:0000:0000:0000:ffff:c000:0201`** — an IPv4-mapped IPv6 address (RFC 4291 §2.5.5.2), how a dual-stack socket represents an IPv4 peer.

**7.2** Because `::` means "as many all-zero groups as needed to reach 128 bits". With two occurrences the expansion would be ambiguous — `2001::1::5` could be any of several different addresses, since there is no way to know how many zero groups belong to each `::`.

**7.3** MAC `00:1a:2b:3c:4d:5e`:
1. Split and insert `ff:fe` → `00:1a:2b : ff:fe : 3c:4d:5e` → `001a:2bff:fe3c:4d5e`
2. Flip bit 1 of the first byte: `0x00 = 0000 0000` → `0000 0010 = 0x02`
3. Interface ID: `021a:2bff:fe3c:4d5e`
4. Link-local address: **`fe80::21a:2bff:fe3c:4d5e`**

Note the flip goes *both* ways: a globally-unique (OUI-assigned) MAC has the U/L bit **0**, and modified EUI-64 inverts it to **1** to mark the identifier as globally unique in IPv6's own convention.

**7.4** They use **RFC 7217 stable-privacy addresses** (`addr_gen_mode=2`/`3`, exposed by NetworkManager as `ipv6.addr-gen-mode stable-privacy` and by systemd-networkd as `IPv6LinkLocalAddressGenerationMode=stable-privacy`), plus **RFC 8981 temporary addresses** for outbound traffic. EUI-64 embedded the MAC address in the low 64 bits, so the same identifier followed the host across every network it joined — a permanent, globally visible hardware tracking cookie. Stable-privacy derives the identifier from a hash of (prefix, interface, a per-host secret), so it is *stable per network* but *different on every network*, keeping troubleshooting sane without the tracking.

**7.5**

| Difference | Consequence |
|---|---|
| Fixed **40-byte** header vs variable 20–60 bytes; options moved to **extension headers** | Routers parse a fixed layout — faster forwarding, but middleboxes often drop unknown extension headers |
| **No header checksum** in IPv6 | Less per-hop work; makes the transport checksum mandatory (see 5.5) |
| **No router fragmentation** — only the source may fragment | PMTUD and ICMPv6 type 2 become load-bearing; filtering them causes black holes |
| **No broadcast**; multicast + anycast only, and ND replaces ARP | Broadcast storms are structurally impossible, but security now depends on filtering RAs (RA Guard) rather than DHCP snooping |

(Also acceptable: `TTL` renamed `Hop Limit`; `Protocol` renamed `Next Header`; addition of the 20-bit **Flow Label**, RFC 6437, for ECMP hashing without deep inspection.)

**7.6** SLAAC does not provide **DNS resolvers or search domains** — nor NTP servers, nor any other per-host option. The gap is covered by (a) **stateless DHCPv6** (the RA's `O` flag tells hosts to ask a DHCPv6 server for options only, not addresses), or (b) **RDNSS/DNSSL options carried in the RA itself** (RFC 8106), which `systemd-networkd` and NetworkManager both understand. The RA's `M` flag instead directs hosts to full stateful DHCPv6 for addresses too.

**7.7** **IPv6 is tried first** — RFC 6724 default address selection ranks a global IPv6 destination above IPv4, and `getaddrinfo()` returns AAAA before A. The mechanism that prevents a stall is **Happy Eyeballs** (RFC 6555, revised as RFC 8305): the client starts the IPv6 connection, and if no handshake completes within a short delay (~250 ms as specified; browsers use similar values) it races an IPv4 connection in parallel and uses whichever succeeds first. Without it, broken IPv6 produces a full TCP timeout on every connection.

---

### Block 8 — Diagnosis

**8.1** Closest to the application → closest to the wire:
1. `Name or service not known` — DNS/NSS, before any packet to the target is built.
2. `Network is unreachable` — routing table, the packet never leaves the host.
3. `Connection refused` — an RST came back: the host is reachable, the port is closed.
4. `Connection timed out` — packets left and nothing returned: filtering or a dead host.

(1 and 2 are *local* failures; 3 and 4 required a round trip, or an attempted one.)

**8.2** The service is bound to the loopback address only, so it is unreachable from any other host by design; the RST comes from the *client's own view* being answered by… in fact typically the remote host's stack RSTs because nothing is listening on the *external* address. Fix: bind the service to the external address or to the wildcard — e.g. `ListenAddress 0.0.0.0` / `bind-address = 0.0.0.0` / `--host 0.0.0.0`, or better, bind to the specific interface address. `ss -ltn` showing `127.0.0.1:8080` rather than `0.0.0.0:8080` is the evidence.

**8.3** **DROP** discards the packet silently and sends nothing, so the client's TCP retransmits its SYN until the connect timeout expires → *timeout*. **REJECT** sends an explicit error, so the client fails immediately → *refused*. For TCP, `REJECT --reject-with tcp-reset` sends a **TCP RST**; the default for both TCP and UDP is an **ICMP Destination Unreachable** (`icmp-port-unreachable` by default; `icmp6-adm-prohibited` / `icmp-admin-prohibited` are the polite variants). Practical trade-off: DROP hides the host from casual scanning but multiplies client timeouts; REJECT fails fast, which is nearly always the better choice on internal networks.

**8.4** Linux dual-stack sockets: when `net.ipv6.bindv6only = 0` (the default), a socket bound to the IPv6 wildcard `::` also accepts IPv4 connections, which arrive represented as **IPv4-mapped addresses** (`::ffff:a.b.c.d`). So `[::]:22` alone serves both families and `ss -ltn` shows only the one entry. Setting `net.ipv6.bindv6only = 1` forces separate sockets per family, and you then see both `0.0.0.0:22` and `[::]:22`. (OpenSSH shows two entries because it deliberately opens one socket per family.)

**8.5** A resolver switches to **TCP/53** on its own when: (a) a UDP response comes back with the **TC (truncated) bit** set because it exceeded the UDP payload limit — 512 bytes classically, or the EDNS0-advertised buffer size — typical with DNSSEC signatures or large RRsets; and (b) for **zone transfers** (`AXFR`/`IXFR`), which are TCP-only by specification. Also increasingly for privacy transports built on TCP (DoT/853, DoH/443).

**8.6** **Name resolution (application/DNS layer)** is broken; IP connectivity is fine. Inspect, in order: `/etc/resolv.conf` (are there nameservers, and is it a symlink to `/run/systemd/resolve/stub-resolv.conf`?) and `/etc/nsswitch.conf` (is `hosts:` configured sanely?); on a systemd machine the single most informative command is `resolvectl status`, followed by `resolvectl query example.com`. Then verify the resolver itself answers: `dig @<nameserver> example.com`.

---

### Block 9 — Integrative

**9.1** Telnet transmits credentials and session data in cleartext, so anyone on the path can capture the login and hijack the session; a service on `0.0.0.0:23` exposes that to every reachable network. Replace with **SSH (22/tcp)**, disable and mask the telnet socket unit or remove the `inetd`/`xinetd` entry, and verify with `ss -ltn 'sport = :23'` that it is gone.

**9.2** LDAP is exposed **without** its TLS counterpart, so directory queries — and, depending on the bind method, credentials — may cross the network unprotected. Before recommending a change, check whether the server requires **STARTTLS on 389** (`olcSecurity: tls=1` in OpenLDAP, or the `ldap` vs `ldaps` URI in clients), because STARTTLS on 389 is the modern, standards-track approach and the absence of 636 is then correct rather than a defect. Confirm empirically: `openssl s_client -connect host:389 -starttls ldap`.

**9.3** (a) **Version and credentials** — SNMPv1/v2c authenticate with a community string sent in cleartext, and `public`/`private` defaults are still common; only **SNMPv3** provides authentication and encryption. (b) **Exposure and amplification** — an SNMP agent reachable from a routed network leaks a detailed inventory of the host (interfaces, routes, processes, sometimes ARP tables) and UDP/161 is a known **reflection/amplification** vector because a small `GetBulk` request yields a large response to a spoofed source. Recommend SNMPv3, bind to a management address, and restrict by source.

**9.4** An MTU of 1492 is the classic signature of **PPPoE** (1500 Ethernet MTU minus the 8-byte PPPoE/PPP overhead) — DSL and many fibre-to-the-home deployments. It is visible because TCP negotiates the **MSS option** in the SYN, and the endpoints (or a router doing MSS clamping) reduce it from 1460 to 1452 accordingly; when clamping is absent and ICMP type 3/4 is filtered, you get the black hole described in 6.3. Confirm with `tracepath` and `tcpdump -v 'tcp[tcpflags] & tcp-syn != 0'` to read the advertised MSS.

**9.5** Not necessarily — it **depends on `net.ipv6.bindv6only`** (see 8.4). With the default `0`, the `[::]` socket also accepts IPv4 connections via IPv4-mapped addresses, so PostgreSQL is reachable over IPv4. With `bindv6only = 1`, or if PostgreSQL's `listen_addresses` names only IPv6 addresses, it is not. Verify from the outside rather than from the socket table: `nc -4 -vz <host> 5432`, and cross-check `listen_addresses` in `postgresql.conf`.

</details>

---

## Sources

- LPI Exam 102-500 objectives, topic 109.1 — <https://www.lpi.org/our-certifications/exam-102-objectives/>
- LPI Exam 101-500 objectives — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- RFC 791 — Internet Protocol (IPv4) — <https://www.rfc-editor.org/rfc/rfc791>
- RFC 792 — Internet Control Message Protocol — <https://www.rfc-editor.org/rfc/rfc792>
- RFC 768 — User Datagram Protocol — <https://www.rfc-editor.org/rfc/rfc768>
- RFC 9293 — Transmission Control Protocol (obsoletes RFC 793) — <https://www.rfc-editor.org/rfc/rfc9293>
- RFC 1918 — Address Allocation for Private Internets — <https://www.rfc-editor.org/rfc/rfc1918>
- RFC 3021 — Using 31-Bit Prefixes on IPv4 Point-to-Point Links — <https://www.rfc-editor.org/rfc/rfc3021>
- RFC 3927 — Dynamic Configuration of IPv4 Link-Local Addresses — <https://www.rfc-editor.org/rfc/rfc3927>
- RFC 4632 — Classless Inter-domain Routing (CIDR) — <https://www.rfc-editor.org/rfc/rfc4632>
- RFC 6890 — Special-Purpose IP Address Registries — <https://www.rfc-editor.org/rfc/rfc6890>
- RFC 8200 — Internet Protocol, Version 6 (IPv6) Specification — <https://www.rfc-editor.org/rfc/rfc8200>
- RFC 4291 — IP Version 6 Addressing Architecture — <https://www.rfc-editor.org/rfc/rfc4291>
- RFC 5952 — A Recommendation for IPv6 Address Text Representation — <https://www.rfc-editor.org/rfc/rfc5952>
- RFC 4193 — Unique Local IPv6 Unicast Addresses — <https://www.rfc-editor.org/rfc/rfc4193>
- RFC 4443 — ICMPv6 — <https://www.rfc-editor.org/rfc/rfc4443>
- RFC 4861 — Neighbor Discovery for IP version 6 — <https://www.rfc-editor.org/rfc/rfc4861>
- RFC 4862 — IPv6 Stateless Address Autoconfiguration — <https://www.rfc-editor.org/rfc/rfc4862>
- RFC 4890 — Recommendations for Filtering ICMPv6 Messages in Firewalls — <https://www.rfc-editor.org/rfc/rfc4890>
- RFC 6724 — Default Address Selection for IPv6 — <https://www.rfc-editor.org/rfc/rfc6724>
- RFC 7217 — Semantically Opaque Interface Identifiers (stable privacy) — <https://www.rfc-editor.org/rfc/rfc7217>
- RFC 8981 — Temporary Address Extensions for SLAAC — <https://www.rfc-editor.org/rfc/rfc8981>
- RFC 8305 — Happy Eyeballs Version 2 — <https://www.rfc-editor.org/rfc/rfc8305>
- RFC 8314 — Use of TLS for Email Submission and Access — <https://www.rfc-editor.org/rfc/rfc8314>
- IANA Service Name and Transport Protocol Port Number Registry — <https://www.iana.org/assignments/service-names-port-numbers/service-names-port-numbers.xhtml>
- IANA Protocol Numbers — <https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml>
- `ip-address(8)`, `ip-route(8)` — <https://man7.org/linux/man-pages/man8/ip-address.8.html>
- `ss(8)` — <https://man7.org/linux/man-pages/man8/ss.8.html>
- `services(5)`, `protocols(5)` — <https://man7.org/linux/man-pages/man5/services.5.html>
- `tcpdump(1)`, `pcap-filter(7)` — <https://www.tcpdump.org/manpages/tcpdump.1.html>
- Linux kernel IPv6 sysctl reference — <https://docs.kernel.org/networking/ip-sysctl.html>