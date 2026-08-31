# 109.3 — Basic network troubleshooting

## Guided exercises

> **Objective mapping.** Topic 109 (*Networking Fundamentals*) is examined in **102-500**; objective 109.3 covers reachability testing, socket inspection, name resolution and the configuration files behind them. Official objective lists: [exam 101-500](https://www.lpi.org/our-certifications/exam-101-objectives/) and [exam 102-500](https://www.lpi.org/our-certifications/exam-102-objectives/).

---

## How to use this document

Every block is a sequence of commands you actually run, followed by questions you answer **before** opening the collapsed answer section at the end. Outputs shown are representative — your addresses, MAC addresses and latencies will differ. What must match is the *shape* of the output and the *meaning* of each field.

### Lab prerequisites

A single Linux host with a working uplink is enough. Two hosts on the same L2 segment make exercises 2, 7 and 10 considerably richer.

```bash
# Debian / Ubuntu
sudo apt install -y iproute2 iputils-ping iputils-tracepath traceroute \
                    dnsutils netcat-openbsd net-tools mtr-tiny

# RHEL / Rocky / Fedora
sudo dnf install -y iproute iputils traceroute bind-utils nmap-ncat \
                    net-tools mtr
```

> **Safety.** Exercises 8 and 10 deliberately break routing and name resolution. **Do not run them over SSH on a machine you cannot reach through a console.** Removing a default route drops your own session. Use a VM, a container with `NET_ADMIN`, or a machine with physical/serial access.

### The troubleshooting ladder

Every exercise below is a rung on the same ladder. Work it bottom-up, and never skip a rung because "that part obviously works":

| Rung | Question | Primary tool |
|---|---|---|
| 1. Link | Is the cable/radio up? Does the driver see carrier? | `ip link`, `ip -s link` |
| 2. Address | Does the interface have an address and the right prefix? | `ip addr` |
| 3. Local L2 | Can we resolve the next hop's MAC? | `ip neigh`, `ping` |
| 4. Route | Which route does the kernel pick for this destination? | `ip route get` |
| 5. Path | Where does the packet die? | `traceroute`, `tracepath`, `mtr` |
| 6. Name | Does the name resolve, and via which source? | `getent hosts`, `dig`, `host` |
| 7. Transport | Is the port open, closed, or filtered? | `nc`, `ss` |
| 8. Service | Is anything listening, and on which address? | `ss -tulpn` |

---

## Exercise 1 — Establishing a baseline with `ip`

**Goal.** Read the three state tables the kernel exposes — links, addresses, routes — and learn the compact forms you will reach for under pressure.

1. List every link with its operational state:

   ```bash
   ip -br link show
   ```

   ```
   lo               UNKNOWN        00:00:00:00:00:00 <LOOPBACK,UP,LOWER_UP>
   enp1s0           UP             52:54:00:12:34:56 <BROADCAST,MULTICAST,UP,LOWER_UP>
   docker0          DOWN           02:42:1f:8c:9a:01 <NO-CARRIER,BROADCAST,MULTICAST,UP>
   ```

2. Now the same view for addresses:

   ```bash
   ip -br -c addr show
   ```

   ```
   lo               UNKNOWN        127.0.0.1/8 ::1/128
   enp1s0           UP             192.168.178.42/24 fe80::5054:ff:fe12:3456/64
   docker0          DOWN           172.17.0.1/16
   ```

3. Look at the full record for the uplink, including counters:

   ```bash
   ip -s link show enp1s0
   ```

   ```
   2: enp1s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP mode DEFAULT group default qlen 1000
       link/ether 52:54:00:12:34:56 brd ff:ff:ff:ff:ff:ff
       RX:  bytes packets errors dropped  missed   mcast
       412398821 1204331      0       0       0    18422
       TX:  bytes packets errors dropped carrier collsns
        88213394  642119      0       0       0        0
   ```

4. Print the main routing table:

   ```bash
   ip route show
   ```

   ```
   default via 192.168.178.1 dev enp1s0 proto dhcp src 192.168.178.42 metric 100
   172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1 linkdown
   192.168.178.0/24 dev enp1s0 proto kernel scope link src 192.168.178.42 metric 100
   ```

5. Ask the kernel which route it would *actually* use — this is the single most useful routing command in the objective:

   ```bash
   ip route get 1.1.1.1
   ip route get 192.168.178.99
   ```

   ```
   1.1.1.1 via 192.168.178.1 dev enp1s0 src 192.168.178.42 uid 1000
       cache
   192.168.178.99 dev enp1s0 src 192.168.178.42 uid 1000
       cache
   ```

**Check your understanding**

- **Q1.1** In step 1, `docker0` shows state `DOWN` yet its flags include `UP`. Explain the contradiction.
- **Q1.2** In step 3, what does `LOWER_UP` mean, and how does it differ from the `UP` flag?
- **Q1.3** The route to `192.168.178.0/24` has `proto kernel scope link`. Who created it, and what does `scope link` assert about those destinations?
- **Q1.4** `ip route get 192.168.178.99` printed no `via`. What does the absence of `via` tell you about how the packet will be delivered?
- **Q1.5** Why is `ip route get` more trustworthy than reading `ip route show` by eye when a host has several interfaces?

---

## Exercise 2 — Layer 2: the neighbour (ARP/NDP) table

**Goal.** Prove that L3 reachability on a local subnet is really an L2 problem, and learn to read neighbour states.

1. Dump the current neighbour cache:

   ```bash
   ip neigh show
   ```

   ```
   192.168.178.1 dev enp1s0 lladdr 3c:a6:2f:0b:11:22 REACHABLE
   192.168.178.77 dev enp1s0  FAILED
   fe80::3ea6:2fff:fe0b:1122 dev enp1s0 lladdr 3c:a6:2f:0b:11:22 router STALE
   ```

2. Flush the entry for your default gateway, then force it to be rebuilt:

   ```bash
   GW=$(ip -4 route show default | awk '{print $3}')
   echo "gateway is $GW"
   sudo ip neigh del "$GW" dev enp1s0
   ip neigh show "$GW"          # expect: nothing, or INCOMPLETE
   ping -c 1 "$GW" >/dev/null
   ip neigh show "$GW"
   ```

   ```
   192.168.178.1 dev enp1s0 lladdr 3c:a6:2f:0b:11:22 REACHABLE
   ```

3. Ping an address inside your subnet that certainly does not exist:

   ```bash
   ping -c 2 -W 1 192.168.178.253
   ```

   ```
   PING 192.168.178.253 (192.168.178.253) 56(84) bytes of data.
   From 192.168.178.42 icmp_seq=1 Destination Host Unreachable
   From 192.168.178.42 icmp_seq=2 Destination Host Unreachable

   --- 192.168.178.253 ping statistics ---
   2 packets transmitted, 0 received, +2 errors, 100% packet loss, time 1029ms
   pipe 2
   ```

4. Inspect what that left behind, then compare with the legacy view:

   ```bash
   ip neigh show 192.168.178.253
   arp -n | head
   ```

   ```
   192.168.178.253 dev enp1s0  FAILED
   ```

**Check your understanding**

- **Q2.1** In step 3, the `Destination Host Unreachable` message came *from your own address*, `192.168.178.42`. Why does the local host emit an ICMP error about a destination it never reached?
- **Q2.2** Contrast that with pinging an off-subnet address that is unreachable. Which host would generate the ICMP error then, and what would `ping` print?
- **Q2.3** What is the practical difference between the neighbour states `REACHABLE`, `STALE` and `FAILED`? Is `STALE` a fault?
- **Q2.4** The IPv6 entry is a link-local `fe80::` address flagged `router`. Which protocol populated it, and why is it not ARP?
- **Q2.5** A host has a correct address, correct route, and `ip neigh` shows the gateway as `INCOMPLETE` and never leaves that state. Name three plausible causes.

---

## Exercise 3 — Layer 3 reachability with `ping` / `ping6`

**Goal.** Read every field `ping` prints, and use its options as instruments rather than as a yes/no oracle.

1. Baseline ping to the gateway, then read the summary carefully:

   ```bash
   ping -c 4 "$GW"
   ```

   ```
   PING 192.168.178.1 (192.168.178.1) 56(84) bytes of data.
   64 bytes from 192.168.178.1: icmp_seq=1 ttl=64 time=0.412 ms
   64 bytes from 192.168.178.1: icmp_seq=2 ttl=64 time=0.398 ms
   64 bytes from 192.168.178.1: icmp_seq=3 ttl=64 time=0.489 ms
   64 bytes from 192.168.178.1: icmp_seq=4 ttl=64 time=0.451 ms

   --- 192.168.178.1 ping statistics ---
   4 packets transmitted, 4 received, 0% packet loss, time 3053ms
   rtt min/avg/max/mdev = 0.398/0.437/0.489/0.035 ms
   ```

2. Ping a public host and compare the TTL:

   ```bash
   ping -c 3 1.1.1.1
   ```

   ```
   64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=12.8 ms
   ```

3. Pin the ping to a specific source interface and to a specific source address:

   ```bash
   ping -c 2 -I enp1s0 1.1.1.1
   ping -c 2 -I 192.168.178.42 1.1.1.1
   ```

4. Probe the path MTU by forbidding fragmentation:

   ```bash
   ping -c 1 -M do -s 1472 1.1.1.1     # 1472 + 8 + 20 = 1500
   ping -c 1 -M do -s 1473 1.1.1.1
   ```

   ```
   PING 1.1.1.1 (1.1.1.1) 1472(1500) bytes of data.
   1480 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=13.1 ms

   PING 1.1.1.1 (1.1.1.1) 1473(1501) bytes of data.
   ping: local error: message too long, mtu=1500
   ```

5. Now IPv6, including a link-local target that needs a zone index:

   ```bash
   ping -6 -c 3 2606:4700:4700::1111
   ping -6 -c 2 fe80::3ea6:2fff:fe0b:1122%enp1s0
   ```

6. Flood-free load test and interval control (root required for intervals below 0.2 s):

   ```bash
   sudo ping -c 100 -i 0.05 -q "$GW"
   ```

   ```
   --- 192.168.178.1 ping statistics ---
   100 packets transmitted, 100 received, 0% packet loss, time 5012ms
   rtt min/avg/max/mdev = 0.331/0.442/1.902/0.161 ms
   ```

**Check your understanding**

- **Q3.1** The header says `56(84) bytes`. Decompose those two numbers.
- **Q3.2** The gateway replied with `ttl=64`, `1.1.1.1` with `ttl=57`. What do you infer, and what is the standard reasoning?
- **Q3.3** What exactly does `mdev` measure, and why does a low `avg` with a high `mdev` deserve investigation?
- **Q3.4** In step 4, the 1473-byte probe failed with `local error: message too long`. Which host produced that error? How would the output differ if the MTU bottleneck were three hops away instead of on your own NIC?
- **Q3.5** Why does `ping fe80::…` require the `%enp1s0` suffix while `ping 2606:4700:4700::1111` does not?
- **Q3.6** A colleague concludes "the server is down" because ICMP echo times out, yet `https://` to that server works. Explain the flaw in the conclusion.

---

## Exercise 4 — Where does the packet die: `traceroute`, `tracepath`, `mtr`

**Goal.** Distinguish the three tools by transport, privilege requirement and what they measure.

1. Run `tracepath` (unprivileged, UDP, discovers PMTU):

   ```bash
   tracepath -n 1.1.1.1
   ```

   ```
    1?: [LOCALHOST]                      pmtu 1500
    1:  192.168.178.1                                         0.503ms
    1:  192.168.178.1                                         0.421ms
    2:  100.64.0.1                                            8.114ms
    3:  no reply
    4:  62.53.16.9                                           11.902ms asymm  5
    5:  1.1.1.1                                              12.744ms reached
        Resume: pmtu 1500 hops 5 back 5
   ```

2. Run classic `traceroute` (UDP high ports by default):

   ```bash
   traceroute -n 1.1.1.1
   ```

   ```
   traceroute to 1.1.1.1 (1.1.1.1), 30 hops max, 60 byte packets
    1  192.168.178.1  0.482 ms  0.463 ms  0.451 ms
    2  100.64.0.1  8.221 ms  8.905 ms  9.114 ms
    3  * * *
    4  62.53.16.9  11.9 ms  12.1 ms  12.0 ms
    5  1.1.1.1  12.7 ms  12.6 ms  12.8 ms
   ```

3. Switch probe transports and compare which hops answer:

   ```bash
   sudo traceroute -n -I 1.1.1.1      # ICMP echo probes
   sudo traceroute -n -T -p 443 1.1.1.1   # TCP SYN probes to 443
   ```

4. Run a continuous path monitor to separate loss from latency:

   ```bash
   mtr -n --report --report-cycles 20 1.1.1.1
   ```

   ```
   Start: 2026-08-27T10:14:22+0200
   HOST: workstation           Loss%   Snt   Last   Avg  Best  Wrst StDev
     1.|-- 192.168.178.1        0.0%    20    0.4   0.5   0.4   0.9   0.1
     2.|-- 100.64.0.1           0.0%    20    8.2   8.6   7.9  10.1   0.6
     3.|-- ???                 100.0%    20    0.0   0.0   0.0   0.0   0.0
     4.|-- 62.53.16.9           0.0%    20   11.9  12.1  11.7  13.4   0.4
     5.|-- 1.1.1.1              0.0%    20   12.7  12.8  12.5  13.9   0.3
   ```

5. IPv6 equivalents:

   ```bash
   tracepath6 -n 2606:4700:4700::1111
   traceroute6 -n 2606:4700:4700::1111
   ```

**Check your understanding**

- **Q4.1** Explain the mechanism common to all three tools: how does incrementing the IP TTL reveal intermediate routers?
- **Q4.2** Hop 3 shows `* * *` in `traceroute` and 100 % loss in `mtr`, yet hops 4 and 5 answer normally. Is traffic being lost? Justify.
- **Q4.3** Why does `traceroute -T` require root while plain `traceroute` and `tracepath` do not?
- **Q4.4** `tracepath` printed `pmtu 1500` and `asymm 5` on hop 4. What does each tell you?
- **Q4.5** You must prove that a firewall between you and a web server permits port 443 but blocks port 8080, and you may only use tools from this objective. Which exact commands do you run?
- **Q4.6** For a user complaint of "the connection is slow and drops occasionally", which of the three tools do you reach for first, and why?

---

## Exercise 5 — Name resolution: NSS, `/etc/hosts`, `/etc/resolv.conf`

**Goal.** Understand that "resolving a name" means two different things depending on which tool asks, and learn to test each path separately.

1. Inspect the resolver order and the resolver configuration:

   ```bash
   grep -E '^hosts:' /etc/nsswitch.conf
   cat /etc/resolv.conf
   ls -l /etc/resolv.conf
   ```

   ```
   hosts:          files mdns4_minimal [NOTFOUND=return] dns

   # Generated by NetworkManager
   search home.arpa
   nameserver 192.168.178.1
   options edns0
   ```

2. Add a deliberately false entry to `/etc/hosts` and test three different resolvers:

   ```bash
   echo '203.0.113.99  lab.example.test' | sudo tee -a /etc/hosts
   getent hosts lab.example.test
   ping -c 1 lab.example.test
   dig +short lab.example.test
   host lab.example.test
   ```

   ```
   203.0.113.99    lab.example.test

   PING lab.example.test (203.0.113.99) 56(84) bytes of data.

   (dig prints nothing)
   Host lab.example.test not found: 3(NXDOMAIN)
   ```

3. Query DNS directly and read the header:

   ```bash
   dig www.lpi.org A
   ```

   ```
   ; <<>> DiG 9.18.24-1-Debian <<>> www.lpi.org A
   ;; global options: +cmd
   ;; Got answer:
   ;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 51224
   ;; flags: qr rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1

   ;; QUESTION SECTION:
   ;www.lpi.org.                   IN      A

   ;; ANSWER SECTION:
   www.lpi.org.            300     IN      A       208.94.116.9

   ;; Query time: 24 msec
   ;; SERVER: 192.168.178.1#53(192.168.178.1) (UDP)
   ;; WHEN: Thu Aug 27 10:22:41 CEST 2026
   ;; MSG SIZE  rcvd: 56
   ```

4. Bypass the configured resolver to isolate a server-side fault:

   ```bash
   dig @1.1.1.1 www.lpi.org +short
   dig @9.9.9.9 www.lpi.org +short
   dig @192.168.178.1 www.lpi.org +short
   ```

5. Reverse lookups and record types:

   ```bash
   dig -x 208.94.116.9 +short
   dig lpi.org MX +short
   dig lpi.org NS +short
   dig lpi.org SOA +short
   host -t MX lpi.org
   ```

6. Observe the `search` domain and `ndots` behaviour:

   ```bash
   dig +search +short www          # tries www.home.arpa.
   dig +noall +answer www.lpi.org.  # note the trailing dot: no search applied
   ```

7. Clean up:

   ```bash
   sudo sed -i '/lab.example.test/d' /etc/hosts
   getent hosts lab.example.test; echo "exit=$?"
   ```

**Check your understanding**

- **Q5.1** In step 2, `ping` and `getent` found the host but `dig` and `host` did not. Explain precisely why, in terms of which library each tool uses.
- **Q5.2** Given `hosts: files mdns4_minimal [NOTFOUND=return] dns`, what happens to a query for `printer.local` that mDNS answers with NOTFOUND? Would `dns` still be consulted?
- **Q5.3** Distinguish `NXDOMAIN`, `SERVFAIL` and `REFUSED` in a `dig` header. Which one points at your *own* resolver rather than at the zone?
- **Q5.4** In the step-3 header, what do the flags `qr`, `rd` and `ra` mean? Which one would be missing if the server did not offer recursion?
- **Q5.5** `dig @1.1.1.1 example.com` succeeds but `dig example.com` times out. Where is the fault, and what is your next command?
- **Q5.6** On a systemd host, `/etc/resolv.conf` is a symlink to `/run/systemd/resolve/stub-resolv.conf` containing `nameserver 127.0.0.53`. Why does editing that file rarely fix anything, and which command shows the *real* upstream servers?
- **Q5.7** The resolver library ignores every `nameserver` line after the third. What is the consequence for someone who "adds more DNS servers to be safe"?

---

## Exercise 6 — Sockets and listeners: `ss`, `netstat`, `/etc/services`

**Goal.** Answer "is anything listening, on which address, owned by which process" without guessing.

1. List every listening TCP and UDP socket with its owning process:

   ```bash
   sudo ss -tulpn
   ```

   ```
   Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
   udp   UNCONN 0      0      127.0.0.53%lo:53        0.0.0.0:*    users:(("systemd-resolve",pid=612,fd=14))
   udp   UNCONN 0      0      0.0.0.0:68              0.0.0.0:*    users:(("dhclient",pid=744,fd=6))
   tcp   LISTEN 0      4096   127.0.0.53%lo:53        0.0.0.0:*    users:(("systemd-resolve",pid=612,fd=15))
   tcp   LISTEN 0      128            0.0.0.0:22      0.0.0.0:*    users:(("sshd",pid=921,fd=3))
   tcp   LISTEN 0      511          127.0.0.1:8080    0.0.0.0:*    users:(("gunicorn",pid=1503,fd=5))
   tcp   LISTEN 0      128               [::]:22         [::]:*    users:(("sshd",pid=921,fd=4))
   ```

2. Look at established connections and per-socket state:

   ```bash
   ss -tan state established
   ss -tanp '( dport = :443 or sport = :443 )'
   ss -s
   ```

   ```
   Total: 431
   TCP:   18 (estab 6, closed 4, orphaned 0, timewait 3)

   Transport Total     IP        IPv6
   RAW       1         0         1
   UDP       6         4         2
   TCP       14        11        3
   INET      21        15        6
   FRAG      0         0         0
   ```

3. Inspect timers and congestion state on one live connection:

   ```bash
   ss -tio state established '( dport = :443 )'
   ```

   ```
   ESTAB 0 0 192.168.178.42:51422 208.94.116.9:443 timer:(keepalive,18min,0)
        cubic wscale:7,7 rto:220 rtt:18.4/2.1 mss:1448 cwnd:10 bytes_sent:4211 bytes_acked:4211 ...
   ```

4. Translate ports to service names via `/etc/services`:

   ```bash
   grep -E '^(ssh|https|domain)\s' /etc/services
   getent services 22/tcp
   getent services https
   ```

   ```
   ssh             22/tcp
   domain          53/tcp
   domain          53/udp
   https           443/tcp

   ssh                   22/tcp
   https                 443/tcp
   ```

5. Compare with the deprecated `net-tools` view:

   ```bash
   sudo netstat -tulpn
   sudo netstat -i
   netstat -rn
   ```

**Check your understanding**

- **Q6.1** `sshd` listens on `0.0.0.0:22` while `gunicorn` listens on `127.0.0.1:8080`. A remote client cannot reach port 8080 and the firewall is empty. Explain, and state the fix.
- **Q6.2** What is the `Send-Q` column showing for a socket in state `LISTEN`, and how does its meaning change for an `ESTAB` socket?
- **Q6.3** `ss -tulpn` shows `[::]:22` but no separate `0.0.0.0:22` on some systems. Which kernel setting explains a single socket serving both families?
- **Q6.4** Does `/etc/services` control which port a daemon binds to? Justify your answer with what happened in step 4.
- **Q6.5** Give two concrete reasons to prefer `ss` over `netstat` on a busy production host.
- **Q6.6** A socket is stuck in `TIME-WAIT`. Which side of the connection closed first, and why does the state exist at all?

---

## Exercise 7 — Transport-level probing with `netcat`

**Goal.** Separate *closed* from *filtered*, and test a service without its client.

1. Test an open port, a closed port and (if available) a filtered one:

   ```bash
   nc -vz -w 3 www.lpi.org 443
   nc -vz -w 3 www.lpi.org 4242
   nc -vz -w 3 192.0.2.1 443
   ```

   ```
   Connection to www.lpi.org (208.94.116.9) 443 port [tcp/https] succeeded!

   nc: connect to www.lpi.org (208.94.116.9) port 4242 (tcp) failed: Connection refused

   nc: connect to 192.0.2.1 port 443 (tcp) timed out: Operation now in progress
   ```

2. Stand up a listener locally and connect to it from a second terminal:

   ```bash
   # terminal A
   nc -l -p 4242 -k          # OpenBSD nc: -l 4242 also works; -k keeps listening

   # terminal B
   ss -tlnp '( sport = :4242 )'
   printf 'hello from B\n' | nc -w 2 127.0.0.1 4242
   ```

3. Speak a real protocol by hand:

   ```bash
   printf 'GET / HTTP/1.1\r\nHost: www.lpi.org\r\nConnection: close\r\n\r\n' \
     | nc -w 5 www.lpi.org 80 | head -n 8
   ```

   ```
   HTTP/1.1 301 Moved Permanently
   Server: nginx
   Date: Thu, 27 Aug 2026 08:31:07 GMT
   Content-Type: text/html
   Content-Length: 162
   Connection: close
   Location: https://www.lpi.org/
   ```

4. Scan a small port range and test UDP:

   ```bash
   nc -vz -w 1 127.0.0.1 20-25 2>&1 | grep -v refused
   nc -vzu -w 2 "$GW" 53
   ```

**Check your understanding**

- **Q7.1** Distinguish the three step-1 outcomes at the packet level: which TCP flags (or absence of packets) produce *succeeded*, *Connection refused* and *timed out*?
- **Q7.2** Why is *Connection refused* actually good news when you are diagnosing a firewall?
- **Q7.3** Why is `nc -zu` (UDP) an unreliable open/closed test, while `nc -z` (TCP) is reliable?
- **Q7.4** In step 3, why is `\r\n` mandatory rather than plain `\n`, and why does the request include a `Host:` header?
- **Q7.5** You can `ping` a server and `nc -z` its port 22 succeeds, but `ssh` hangs after the banner. Which rung of the ladder is now suspect, and what would you test?

---

## Exercise 8 — Breaking and repairing: routes, addresses, DNS

> **Console access required.** Do not perform this over SSH.

**Goal.** Produce each classic failure signature on purpose so you recognise it later.

1. Record the current state so you can restore it:

   ```bash
   ip addr show enp1s0 > /tmp/before-addr.txt
   ip route show > /tmp/before-route.txt
   sudo cp /etc/resolv.conf /tmp/resolv.conf.bak
   cat /tmp/before-route.txt
   ```

2. **Break the default route.** Remove it and observe the difference between local and remote failures:

   ```bash
   sudo ip route del default
   ping -c 1 -W 2 "$GW"      # still works: on-link
   ping -c 1 -W 2 1.1.1.1
   ip route get 1.1.1.1
   ```

   ```
   ping: connect: Network is unreachable
   RTNETLINK answers: Network is unreachable
   ```

3. Restore it:

   ```bash
   sudo ip route add default via "$GW" dev enp1s0
   ping -c 1 1.1.1.1 && echo OK
   ```

4. **Break the prefix length.** Replace the /24 with a /28 and see who becomes unreachable:

   ```bash
   sudo ip addr add 192.168.178.42/28 dev enp1s0
   sudo ip addr del 192.168.178.42/24 dev enp1s0
   ip route get 192.168.178.1
   ip route get 192.168.178.200
   ```

5. Restore the correct prefix:

   ```bash
   sudo ip addr add 192.168.178.42/24 dev enp1s0
   sudo ip addr del 192.168.178.42/28 dev enp1s0
   sudo ip route add default via "$GW" dev enp1s0 2>/dev/null
   ip -br addr show enp1s0
   ```

6. **Break DNS only.** Point the resolver at a black hole and characterise the symptom:

   ```bash
   printf 'nameserver 203.0.113.53\noptions timeout:1 attempts:1\n' \
     | sudo tee /etc/resolv.conf >/dev/null
   time getent hosts www.lpi.org; echo "exit=$?"
   ping -c 1 1.1.1.1 && echo "raw IP still fine"
   dig @1.1.1.1 www.lpi.org +short
   ```

7. Restore DNS and verify the whole ladder:

   ```bash
   sudo cp /tmp/resolv.conf.bak /etc/resolv.conf
   getent hosts www.lpi.org
   diff <(ip route show) /tmp/before-route.txt && echo "routes restored"
   ```

**Check your understanding**

- **Q8.1** In step 2, `ping 1.1.1.1` failed with `Network is unreachable` rather than timing out. Which component produced that message, and at what point in the send path?
- **Q8.2** Contrast `Network is unreachable`, `Destination Host Unreachable` and a silent timeout: which layer is broken in each case?
- **Q8.3** In step 4, with a /28 mask, `192.168.178.200` is no longer on-link. Trace what the kernel does with a packet for it, assuming a default route exists.
- **Q8.4** Explain the exact symptom profile of step 6 as a user would report it, and why `ping 1.1.1.1` working is the key discriminator.
- **Q8.5** Why did the exercise add the new address *before* deleting the old one in step 4, and why does the order matter more on a remote host?
- **Q8.6** Every change above is lost on reboot. Name the persistence mechanism on a NetworkManager system and on a Debian `ifupdown` system.

---

## Exercise 9 — Host identity: `hostname`, `/etc/hosts`, `/etc/hostname`

**Goal.** Understand the three distinct names a host carries and how each is resolved.

1. Query the current identity:

   ```bash
   hostname
   hostname -s
   hostname -f
   hostname -I
   cat /etc/hostname
   ```

   ```
   workstation
   workstation
   workstation.home.arpa
   192.168.178.42 fe80::5054:ff:fe12:3456
   workstation
   ```

2. Inspect the loopback mapping that makes `hostname -f` work:

   ```bash
   grep -n workstation /etc/hosts
   getent hosts workstation
   ```

   ```
   2:127.0.1.1      workstation.home.arpa workstation
   127.0.1.1       workstation.home.arpa workstation
   ```

3. Change the transient hostname and observe what did and did not change:

   ```bash
   sudo hostname lab-node
   hostname
   cat /etc/hostname
   hostname -f
   ```

4. Restore, and set it persistently the systemd way:

   ```bash
   sudo hostname "$(cat /etc/hostname)"
   hostnamectl status
   # persistent change would be:  sudo hostnamectl set-hostname workstation
   ```

**Check your understanding**

- **Q9.1** Why does `hostname -f` fail with `Name or service not known` on a host whose `/etc/hosts` lacks a mapping for its own name, even when DNS is healthy?
- **Q9.2** Debian maps the hostname to `127.0.1.1` rather than `127.0.0.1`. What problem does that convention avoid?
- **Q9.3** Which of these survives a reboot: `hostname lab-node`, editing `/etc/hostname`, `hostnamectl set-hostname lab-node`?
- **Q9.4** `hostname -I` and `ip -br addr` disagree — the former omits an address you can see in the latter. Give a plausible reason.

---

## Exercise 10 — Full triage drill

**Goal.** Run the ladder end to end against an unknown fault, producing evidence at each rung.

1. Take a snapshot of every rung in one shot:

   ```bash
   {
     echo "=== links ==="   ; ip -br link
     echo "=== addrs ==="   ; ip -br addr
     echo "=== routes ==="  ; ip route show
     echo "=== neigh ==="   ; ip neigh show
     echo "=== resolv ==="  ; cat /etc/resolv.conf
     echo "=== nsswitch ==="; grep '^hosts:' /etc/nsswitch.conf
     echo "=== listeners ==="; ss -tulpn
   } > /tmp/net-snapshot.txt
   wc -l /tmp/net-snapshot.txt
   ```

2. Walk the ladder against a target of your choice, stopping at the first failure:

   ```bash
   TARGET=www.lpi.org
   ip link show enp1s0 | grep -o 'LOWER_UP'           # rung 1
   ip -4 -br addr show enp1s0                          # rung 2
   ping -c 2 -W 1 "$GW"                                # rung 3
   ip route get 1.1.1.1                                # rung 4
   ping -c 2 -W 1 1.1.1.1                              # rung 4
   tracepath -n 1.1.1.1 | tail -3                      # rung 5
   getent hosts "$TARGET"                              # rung 6
   dig @1.1.1.1 +short "$TARGET"                       # rung 6
   nc -vz -w 3 "$TARGET" 443                           # rung 7
   ```

3. Record the finding in a form another engineer can act on:

   ```
   Symptom:   HTTPS to www.lpi.org fails from workstation
   Rung 1-4:  OK   (LOWER_UP, 192.168.178.42/24, gw REACHABLE, 1.1.1.1 rtt 12.8 ms)
   Rung 5:    OK   (tracepath reaches, pmtu 1500)
   Rung 6:    FAIL (getent: no result; dig @1.1.1.1 returns 208.94.116.9)
   Rung 7:    OK   (nc -z 208.94.116.9 443 succeeded)
   Conclusion: local resolver path broken, upstream DNS and transport healthy
   Next:      inspect /etc/resolv.conf and resolvectl status
   ```

**Check your understanding**

- **Q10.1** Why does the drill test `ping 1.1.1.1` before `getent hosts www.lpi.org`, and not the reverse?
- **Q10.2** Rung 6 fails but rung 7 succeeds in the sample report. How was rung 7 tested at all, given the name did not resolve?
- **Q10.3** Two hosts on the same switch cannot reach each other; both show `LOWER_UP`, both have addresses, `ip neigh` shows `FAILED` in both directions. Name the two most likely causes and one command that discriminates between them.
- **Q10.4** A web application intermittently stalls on large uploads but small requests are fine, and ping and traceroute are clean. Which rung is implicated, and which exact command from this document produces the evidence?
- **Q10.5** Why is capturing `/tmp/net-snapshot.txt` *before* changing anything a professional habit rather than bureaucracy?

---

<details>
<summary><strong>Answers</strong> — open only after attempting every block</summary>

### Exercise 1

**A1.1** The two words describe different things. The flag `UP` is the *administrative* state: the operator (or the init system) asked the kernel to enable the interface — `IFF_UP` is set. The word `DOWN` in `ip -br link` is the *operational* state (`operstate`), which the driver derives from carrier detection. `docker0` is administratively enabled but has `NO-CARRIER` because no container is attached to the bridge, so no port is forwarding. The same pattern appears on a physical NIC that is `UP` with the cable unplugged.

**A1.2** `UP` is `IFF_UP`, set by `ip link set dev X up`. `LOWER_UP` is `IFF_LOWER_UP`, meaning the driver reports physical-layer carrier — link pulses on copper, association on Wi-Fi, an attached peer for a veth. Diagnostically: `UP` without `LOWER_UP` means "I asked for it, the wire disagrees" — a cable, port, or duplex/autoneg problem, not a configuration problem.

**A1.3** `proto kernel` means the kernel installed it automatically the moment an address with a prefix was configured on the interface; no routing daemon or administrator created it. `scope link` asserts that every destination in `192.168.178.0/24` is reachable *directly on this L2 segment* — the kernel will ARP/ND for the destination itself instead of handing the frame to a router. Deleting this route by hand is one of the fastest ways to break a subnet.

**A1.4** No `via` means no next-hop gateway: the destination is on-link. The kernel will resolve `192.168.178.99`'s own MAC address via ARP and put that MAC in the Ethernet destination field. If `via` were present, the frame would carry the *gateway's* MAC while the IP header still carried the final destination.

**A1.5** `ip route show` prints rules; `ip route get` prints the *decision*. On a multi-homed host the decision depends on longest-prefix match, metric, policy routing rules (`ip rule`), and multiple routing tables — `ip route show` without `table all` shows only the main table and hides all of that. `ip route get` also reveals the **source address** the kernel will select, which is the single field most often responsible for "the packet leaves but nothing comes back".

### Exercise 2

**A2.1** The destination is on-link, so the kernel must learn its MAC before it can build a frame. It broadcast ARP requests, nobody answered, the neighbour entry went to `FAILED`, and the *local* IP stack generated `ICMP Destination Unreachable / Host Unreachable` for its own queued packet and delivered it back up to `ping`. No packet ever left the host beyond the ARP broadcasts. This is why the source address of the error is your own.

**A2.2** For an off-subnet destination the local host has a valid next hop, so the packet is forwarded. The ICMP error, if any, is generated by an *upstream router* — typically the last router that has a route to the network but no ARP answer for the host, or one that has no route at all (`Destination Net Unreachable`). `ping` prints `From <router-ip> icmp_seq=N Destination Host Unreachable`, and the address is the router's, not yours. If the packet is silently dropped by a firewall instead, you get no error at all — just `100% packet loss` with no `+errors` count.

**A2.3**
- `REACHABLE` — the mapping was confirmed recently (default ~30 s base, randomised); traffic flows without further probing.
- `STALE` — the entry is still cached and *will be used*, but the confirmation timer expired. The kernel sends the next packet with that MAC and simultaneously starts a unicast probe (`DELAY` → `PROBE`). **`STALE` is not a fault**; it is the normal resting state of a quiet neighbour. Treating it as a fault is a common misread.
- `FAILED` — resolution was attempted and no answer arrived. This *is* a fault: the neighbour is absent, on a different VLAN, or ARP/ND is being filtered.

**A2.4** IPv6 does not use ARP. Neighbour Discovery (NDP, RFC 4861) populates that entry using ICMPv6 Neighbor Solicitation / Neighbor Advertisement messages sent to solicited-node multicast addresses. The `router` keyword means the neighbour advertised itself as a router (via Router Advertisement), which is how the host learned its default gateway — note that the gateway is identified by its **link-local** address, which is why IPv6 default routes point at `fe80::…` rather than at a global address.

**A2.5** Any three of:
1. The gateway is on a different VLAN than the switch port grants (native/access VLAN mismatch).
2. Wrong prefix length on the local address, so the "gateway" is not actually on-link and ARP goes out on a segment where nobody owns it.
3. A switch port in a blocking state (spanning tree), port security violation, or a dead cable pair — carrier is up but frames do not traverse.
4. ARP filtering / client isolation on the AP or switch.
5. Duplicate IP or a MAC-filtering firewall dropping the reply.

### Exercise 3

**A3.1** `56` is the ICMP *payload* size that `ping` requested (its default `-s 56`). `84` is the full IP datagram: 56 bytes payload + 8 bytes ICMP header + 20 bytes IPv4 header. The reply lines then report `64 bytes`, which is the ICMP message as seen above the IP layer (56 + 8), because the IP header is stripped before `ping` counts it.

**A3.2** TTL is decremented by one per router traversed. Common initial values are 64 (Linux, macOS), 128 (Windows), 255 (many network devices). `ttl=64` arriving intact means **zero** routers were crossed — the gateway is on-link, as expected. `ttl=57` from an initial 64 implies **7** hops. The reasoning is inference, not proof: you assume the initial value, and some devices reset or rewrite TTL. Use it as a cheap corroboration of `traceroute`, not as a substitute.

**A3.3** `mdev` is the mean deviation of the round-trip times — a jitter measure, computed as the mean of the absolute deviations from the mean RTT. A low `avg` with a high `mdev` means most packets are fast but some are dramatically delayed: bufferbloat, an overloaded CPU on an intermediate device, a saturated uplink, a flapping wireless link, or a route oscillating between two paths. Interactive protocols (SSH, VoIP, RDP) degrade with jitter far more than with a uniformly higher latency, so `mdev` frequently explains a complaint that `avg` cannot.

**A3.4** *Your own kernel* produced it. `-M do` sets the IP `Don't Fragment` bit; the kernel compared the 1501-byte datagram against the outgoing interface's MTU of 1500 and refused locally with `EMSGSIZE` — the phrase `local error` is the tell, and `mtu=1500` names the local limit. If the bottleneck were three hops away, the packet would leave normally and the *remote router* would return `ICMP Fragmentation Needed (Type 3, Code 4)` carrying its MTU; `ping` would then print something like `From 62.53.16.9 icmp_seq=1 Frag needed and DF set (mtu = 1400)`. The difference between the two messages is exactly the difference between "misconfigured NIC" and "path MTU black hole".

**A3.5** `fe80::/10` is link-local: the *same* address may legitimately exist on every interface of the host, so the address alone does not identify a destination. The zone index (`%enp1s0`, RFC 4007 scope-id) tells the stack which interface to transmit on. Global addresses like `2606:4700:4700::1111` are globally unique and the routing table alone selects the egress interface, so no zone is needed. The same rule applies to `ssh`, `curl` and any other IPv6-capable client.

**A3.6** ICMP echo is a *distinct* protocol from the service under test, and it is routinely rate-limited or dropped by firewalls, cloud security groups and hardened hosts, as a matter of policy rather than fault. "No echo reply" therefore proves nothing about TCP/443. The correct conclusion is "ICMP echo is not answered"; the correct next test is a transport-layer probe — `nc -vz host 443`, `traceroute -T -p 443 host`, or simply the application client.

### Exercise 4

**A4.1** Each probe is sent with a deliberately small IP TTL (IPv6: Hop Limit). A router that decrements the TTL to zero must discard the packet and return `ICMP Time Exceeded` (Type 11) to the source, and that error carries the router's own address as source. So TTL=1 elicits a reply from the first router, TTL=2 from the second, and so on. The walk ends when the probe finally reaches the destination, which answers differently — `ICMP Port Unreachable` for the UDP variant, `Echo Reply` for `-I`, `SYN/ACK` or `RST` for `-T`.

**A4.2** Almost certainly **not**. Loss reported at an intermediate hop reflects only that router's willingness to generate `ICMP Time Exceeded` for *itself* — many routers deprioritise or rate-limit ICMP generation from the control plane, and many operators filter it outright. Because hops 4 and 5 answer, packets clearly *transit* hop 3 intact. The rule for reading `mtr`: loss is real only when it starts at some hop **and persists to the destination**. Loss at one hop that clears afterwards is a reporting artefact.

**A4.3** Plain `traceroute` sends UDP datagrams to high, unlikely ports — an unprivileged socket operation. `tracepath` likewise uses UDP with `IP_MTU_DISCOVER`, and modern `ping`/`tracepath` use unprivileged ICMP datagram sockets where `net.ipv4.ping_group_range` allows it. `traceroute -T` must craft raw TCP SYN packets with an arbitrary TTL and read the raw responses, which requires `CAP_NET_RAW` — hence root or a file capability. `traceroute -I` needs raw ICMP for the same reason.

**A4.4** `pmtu 1500` is the smallest MTU discovered along the path so far — `tracepath`'s distinguishing feature over `traceroute`; a value below 1500 predicts trouble for protocols that set DF. `asymm 5` means the *return* path from that hop appears to be 5 hops long while the forward path is 4: routing is asymmetric. Asymmetry is normal on the Internet, but it matters when a stateful firewall sits on only one of the two paths, or when you are interpreting one-way latency.

**A4.5**
```bash
nc -vz -w 3 <server> 443     # expect: succeeded
nc -vz -w 3 <server> 8080    # expect: timed out  -> filtered (not refused)
sudo traceroute -n -T -p 8080 <server>   # shows the last hop before the silence
sudo traceroute -n -T -p 443  <server>   # reaches the server, for contrast
```
The decisive evidence is the *pair*: 443 succeeds and 8080 **times out** rather than being refused. A refusal would prove the packet reached the server and no process was listening; silence at a hop that answers for 443 localises the drop to a filtering device on the path.

**A4.6** `mtr`. `ping` gives loss and jitter but no idea *where*; `traceroute` gives a path but only three probes per hop, far too few to characterise intermittent loss. `mtr` sends continuous probes to every hop simultaneously, so after a few hundred cycles it shows loss and latency **per hop over time** — exactly the shape of evidence an intermittent complaint needs. Run it long (`--report-cycles 100+`) and read it with the rule from A4.2.

### Exercise 5

**A5.1** `ping`, `getent`, `ssh`, browsers and virtually all applications resolve names through the **glibc Name Service Switch**, calling `getaddrinfo(3)`, which consults the sources listed in `/etc/nsswitch.conf` — here `files` (i.e. `/etc/hosts`) first. `dig` and `host` are **DNS diagnostic tools**: they bypass NSS entirely and speak the DNS protocol directly to a nameserver. They therefore never see `/etc/hosts`, never honour `nsswitch.conf`, and never use mDNS or LDAP sources. This is the single most valuable distinction in the whole objective: **`getent hosts` tells you what the application will see; `dig` tells you what DNS actually says.** When the two disagree, the fault is in NSS configuration, not in DNS.

**A5.2** `dns` would **not** be consulted. The action `[NOTFOUND=return]` instructs NSS to stop the whole lookup and return failure as soon as `mdns4_minimal` reports "authoritatively, this name does not exist", instead of falling through to the next source. This is deliberate: the `mdns4_minimal` module only claims the `.local` pseudo-TLD, so the construct means "`.local` is mDNS territory; do not leak `.local` queries to the public DNS." A name such as `printer.local` therefore fails immediately if no mDNS responder answers.

**A5.3**
- `NXDOMAIN` — the authoritative server for the zone states the name does not exist. Authoritative, cacheable, and it means the *data* is missing. Fix it in the zone.
- `SERVFAIL` — the server you asked could not produce an answer: recursion failed, upstream timed out, DNSSEC validation failed, or the zone is broken/lame. This points at **your own resolver or the path from it**, and is the one you own.
- `REFUSED` — the server understood the query and declines to serve you by policy: you are outside its allowed ACL, or it is authoritative-only and you asked for recursion.

**A5.4** `qr` = this message is a *response*, not a query. `rd` = *recursion desired*, set by the client, asking the server to chase the answer through the delegation chain. `ra` = *recursion available*, set by the server, confirming it is willing to do so. **`ra` would be missing** on an authoritative-only server; asking such a server for a name outside its zones typically yields a referral or `REFUSED`, not an answer — a frequent cause of "it works with `dig @8.8.8.8` but not with our internal server".

**A5.5** DNS itself and the whole path below it are healthy — 1.1.1.1 answered, which required working link, address, route, and UDP/53 to the Internet. The fault is in the **locally configured resolver path**: either the `nameserver` line in `/etc/resolv.conf` points somewhere unreachable, or the local server is down or filtering. Next commands, in order:
```bash
cat /etc/resolv.conf                       # which server is configured?
dig @<that-server> example.com             # is it that specific server?
resolvectl status                          # if systemd-resolved is in play
ss -ulnp '( sport = :53 )'                 # is a local stub listening at all?
```

**A5.6** On such a host, `systemd-resolved` owns resolution: `/etc/resolv.conf` is a *generated* symlink pointing at a stub whose only nameserver is the local listener `127.0.0.53`. Editing it either edits the generated file (overwritten on the next network event) or replaces the symlink (silently disabling the stub and diverging from what `resolved` believes). The real upstream servers, per-link search domains, DNSSEC state and the DNS-over-TLS mode are shown by:
```bash
resolvectl status
resolvectl query www.lpi.org      # resolve through NSS/resolved, showing which link answered
```
Configuration belongs in `/etc/systemd/resolved.conf`, in a NetworkManager connection profile, or in the DHCP lease — not in `/etc/resolv.conf`.

**A5.7** The glibc resolver compiles in `MAXNS 3` and silently ignores every `nameserver` beyond the third. Adding a fourth "for safety" is dead configuration that creates a false sense of redundancy — and worse, if the first three are the broken ones, the working entry never gets used. Note also that the default behaviour is *sequential with timeout*, not parallel: with `options timeout:5 attempts:2` and three servers, a fully dead first server can add tens of seconds to every lookup. Reducing `timeout` and `attempts`, or fixing the list, is the real remedy.

### Exercise 6

**A6.1** `0.0.0.0:22` is the IPv4 wildcard: the socket accepts connections arriving on **any** local address, including `192.168.178.42`. `127.0.0.1:8080` binds only the loopback address, so the kernel will only deliver connections whose destination IP is `127.0.0.1` — traffic from another host can never carry that destination. No firewall is involved; the packet is rejected by socket demultiplexing. Fixes, in order of preference: bind the service to `0.0.0.0` (or a specific LAN address) in its own configuration, or, when the loopback bind is deliberate, put a reverse proxy in front of it, or tunnel with `ssh -L`.

**A6.2** For a `LISTEN` socket, `Send-Q` is the **accept-queue backlog limit** — the value passed to `listen(2)`, capped by `net.core.somaxconn` (4096 for `systemd-resolve`, 128 for `sshd`, 511 for `gunicorn` above), and `Recv-Q` is the number of established connections *waiting to be accepted*. A non-zero, persistent `Recv-Q` on a listener means the application is not calling `accept()` fast enough — a real capacity signal. For an `ESTAB` socket the columns revert to their obvious meaning: bytes received but not yet read by the application, and bytes written by the application but not yet acknowledged by the peer.

**A6.3** `net.ipv6.bindv6only`. When it is `0` (the Linux default), a socket bound to the IPv6 wildcard `::` also accepts IPv4 connections, which arrive as IPv4-mapped addresses (`::ffff:192.0.2.1`) — one socket, both families, hence the single `[::]:22` line. When it is `1`, or when the daemon sets `IPV6_V6ONLY` on the socket itself (OpenSSH does, which is why the sample shows two separate lines), each family needs its own socket. This explains the otherwise baffling "IPv6 works, IPv4 does not" after a kernel tunable change.

**A6.4** **No.** `/etc/services` is purely a *name↔number registry* consulted by `getservbyname(3)`/`getaddrinfo(3)` and by display tools such as `ss`, `netstat` and `nc` when they render `443` as `https`. Which port a daemon binds is decided by that daemon's own configuration (`Port` in `sshd_config`, `listen` in nginx, and so on) or by a hardcoded default. Deleting the `ssh` line from `/etc/services` would change how `ss` *labels* port 22 and would break `nc host ssh`, but `sshd` would keep listening exactly where it was. Editing `/etc/services` to "move a service" is a classic exam trap.

**A6.5** Any two of:
1. **Speed and scale.** `ss` reads `sock_diag` netlink sockets, obtaining the kernel's socket tables in a few structured messages. `netstat` parses `/proc/net/*` line by line and, for `-p`, walks every `/proc/<pid>/fd/` in the system — on a host with 100 000 sockets that is minutes versus milliseconds, and it consumes CPU while you are already in an incident.
2. **Kernel-side filtering.** `ss` accepts a real filter language — `ss -tan state established '( dport = :443 or sport = :443 )'` — evaluated by the kernel, instead of piping everything through `grep`.
3. **Richer data.** `ss -i` exposes per-socket TCP internals (congestion algorithm, `cwnd`, `rtt`, `retrans`, `mss`, pacing) that `netstat` cannot show at all; `ss -o` shows timers; `ss -e` shows the inode and cgroup.
4. **Maintenance.** `net-tools` is effectively frozen and absent by default on many modern distributions; `iproute2` is the maintained interface to current kernel features (namespaces, policy routing, `-N` netns awareness).

**A6.6** `TIME-WAIT` is held by the side that performed the **active close** — the one that sent the first `FIN`. It lasts 2×MSL (60 s on Linux) and exists for two reasons: to absorb delayed duplicate segments from the closed connection so they cannot be misdelivered to a new connection reusing the same four-tuple, and to guarantee the final ACK can be retransmitted if the peer's `FIN` is repeated. Thousands of `TIME-WAIT` sockets on a *server* is a design signal — it means the server is closing connections first, typically because keep-alive is off or a proxy is opening a fresh connection per request. It is a symptom to interpret, not a leak to "fix" by disabling the state.

### Exercise 7

**A7.1**
- **succeeded** — `nc` sent `SYN`, the peer answered `SYN/ACK`, `nc` completed the handshake with `ACK` (and immediately closed, because of `-z`). A process is listening and the path permits the traffic.
- **Connection refused** — the peer answered with `RST/ACK`. The packet *reached a host* that owns that address, and its kernel found no listening socket on that port. Path is open end to end; the service is absent or bound elsewhere.
- **timed out** — **no packet came back at all**. A firewall silently dropped the SYN (`DROP` rather than `REJECT`), the host does not exist, or the return path is broken. `nc` gave up after the `-w 3` deadline.

**A7.2** Because a refusal is *proof of end-to-end reachability*. An `RST` can only be generated by the host that owns the destination address, so it proves the SYN traversed every router and every firewall on the way and that the reply traversed them coming back. The problem is therefore not the network: it is the service — not started, crashed, bound to `127.0.0.1`, or listening on a different port. That single distinction routinely saves an entire round of blaming the firewall team.

**A7.3** TCP mandates a response to a SYN: either `SYN/ACK` or `RST`. UDP mandates nothing. A UDP probe to a closed port *should* elicit `ICMP Port Unreachable` (Type 3, Code 3), but that ICMP is heavily rate-limited by Linux (`net.ipv4.icmp_ratelimit`) and very commonly filtered, and a UDP probe to an *open* port produces no reply at all unless the application chooses to answer a payload it understands. So both "open" and "filtered" look identical — silence — and `nc -zu` reports success for anything that does not explicitly refuse. The reliable UDP test is protocol-specific: `dig @host name` for DNS, `ntpdate -q` for NTP, `snmpget` for SNMP.

**A7.4** HTTP/1.1 (RFC 9112) defines the line terminator for the request line and headers as `CRLF`, and the end of the header block as a bare `CRLF` on its own line; a server may reject or hang on lone `LF`. `printf` emits `\r\n` literally, whereas `echo` would not. The `Host:` header is **mandatory** in HTTP/1.1 — it is what allows name-based virtual hosting, since the TCP connection carries only an IP address. Omitting it yields `400 Bad Request` from most servers, which students frequently misread as a network fault.

**A7.5** Rungs 1–7 are proven good: the TCP connection establishes and the server sends its banner, so link, address, route, path, name and transport are all fine. Suspicion moves to the **application / authentication layer** — and, notably, to something that happens *after* the banner: reverse-DNS lookup of your client address by `sshd` (`UseDNS yes` with an unreachable resolver produces exactly a post-banner stall of tens of seconds), a hung PAM module (LDAP, SSSD, `pam_systemd`), an exhausted entropy pool on old kernels, or a full `/` preventing `utmp` writes. Diagnose with `ssh -vvv host` to see the exact stage, and on the server `journalctl -u ssh -f`, `ss -tanp '( sport = :22 )'` and `resolvectl query <client-ip>`. A path-MTU black hole is the other classic candidate — it stalls precisely when the first large packet (the key exchange) is sent; test with `ping -M do -s 1400`.

### Exercise 8

**A8.1** The **local kernel** produced it, at route-lookup time, before any packet was constructed. With no default route and no more specific match, the FIB lookup for `1.1.1.1` failed and the `connect()`/`sendto()` syscall returned `ENETUNREACH`, which `ping` printed as `connect: Network is unreachable`. Nothing was transmitted. `ip route get` reported the same failure directly from netlink: `RTNETLINK answers: Network is unreachable`. The distinguishing feature of this class of fault is that it is *instant* — there is no timeout, because there is nothing to wait for.

**A8.2**
- **`Network is unreachable`** — layer 3 *configuration* on the local host: no route exists. Instant failure, no packets sent. Fix the routing table.
- **`Destination Host Unreachable` from your own address** — layer 2: the route exists and says on-link, but ARP/ND found nobody. Fix the address/prefix, VLAN, or the neighbour itself. (The same message *from a router's address* means the same thing one hop further out.)
- **Silent timeout** — packets left and nothing returned. Either a firewall is dropping (rather than rejecting), the return path is broken, or the destination is off. This is the only one of the three where the problem may be entirely outside your host.

**A8.3** With `192.168.178.42/28`, the on-link prefix is `192.168.178.32/28`, i.e. `.33`–`.46`. `192.168.178.200` no longer matches the `scope link` route (which the kernel silently rewrote when the address changed), so the FIB falls through to the default route and the packet is sent **to the gateway's MAC address** with `192.168.178.200` still in the IP destination field. The gateway, which believes the whole `/24` is on-link, ARPs for `.200`, gets an answer, forwards the frame — and typically also returns an `ICMP Redirect` telling you to use the on-link path. Traffic may well work, badly and asymmetrically, via an unnecessary router hop; meanwhile `.200`'s replies come back directly, which breaks any stateful firewall in the middle. Mask mismatches produce *partial* failure, which is why they are so much harder to spot than a total one.

**A8.4** The user reports "the Internet is down" or "the website doesn't load", while anything addressed numerically or already cached still works: an SSH session to an IP stays alive, `ping 1.1.1.1` is clean, a bookmarked host with a fresh DNS cache entry loads. Everything by name hangs for a second or two and then fails. `getent hosts` returns non-zero after the resolver timeout; `dig @1.1.1.1` succeeds. **`ping 1.1.1.1` working is the discriminator** because it proves rungs 1–5 — link, address, neighbour, route and path — are all healthy, which excludes every layer below name resolution in a single command. Pair it with `getent` failing and `dig @<public>` succeeding and the fault is localised to `/etc/resolv.conf` or `nsswitch.conf` with certainty.

**A8.5** Adding before deleting keeps the interface continuously addressed, so no connection is torn down and no routing state is lost in the gap. Deleting first leaves the interface address-less for the duration of your typing: the kernel immediately removes the associated `scope link` route **and the default route that depended on it**, every established TCP connection through that interface breaks, and — on a remote host — your own SSH session dies before you can issue the `add`, leaving the machine unreachable and requiring console intervention. For genuinely risky remote changes, the professional habits are `ip addr replace`, wrapping the change in a script with a `sleep 60 && <rollback>` scheduled beforehand, or using `at`/`systemd-run --on-active` to auto-revert.

**A8.6** Every `ip` command writes to the running kernel only; nothing touches disk.
- **NetworkManager** (Fedora/RHEL/Rocky/Ubuntu desktop): connection profiles in `/etc/NetworkManager/system-connections/*.nmconnection`, edited with `nmcli connection modify <name> ipv4.addresses … ipv4.gateway … ipv4.dns …` followed by `nmcli connection up <name>`. RHEL 9 has dropped the legacy `/etc/sysconfig/network-scripts/ifcfg-*` files in favour of these.
- **Debian `ifupdown`**: `/etc/network/interfaces` and `/etc/network/interfaces.d/*`, applied with `ifdown`/`ifup` or `systemctl restart networking`.
- Also common: **`systemd-networkd`** (`/etc/systemd/network/*.network`) on servers and containers, and **Netplan** (`/etc/netplan/*.yaml`, `netplan apply`) on Ubuntu Server, which is a front-end that renders to one of the other two.

### Exercise 9

**A9.1** `hostname -f` calls `getaddrinfo()` on the short hostname with `AI_CANONNAME` and returns the canonical name that comes back. That lookup goes through NSS: `files` first, then `dns`. If `/etc/hosts` has no entry for `workstation` **and** the DNS zone has no `A`/`AAAA` record for that bare label with the configured `search` domain appended, there is no canonical name to return, and the call fails with `Name or service not known` — regardless of how healthy DNS is for *other* names. The lesson: a host's FQDN is not an intrinsic property it "knows"; it is the result of resolving its own name, and it fails exactly like any other resolution.

**A9.2** `127.0.1.1` lets the hostname resolve to a loopback address **without** colliding with the entry `127.0.0.1 localhost`, which many programs expect to map to the literal name `localhost` and nothing else. Debian Policy §11.9 mandates it for machines with a dynamic (DHCP) address, so that `hostname -f` works before and independently of any address being leased. The alternative — pointing the hostname at the machine's real LAN address — breaks the moment DHCP hands out a different one, and pointing it at `127.0.0.1` alongside `localhost` causes services that bind "the hostname" to bind loopback and services that reverse-resolve `127.0.0.1` to get the wrong name.

**A9.3**
- `hostname lab-node` — **transient only**. It calls `sethostname(2)`; the kernel forgets it at reboot. Useful for a quick test, never for configuration.
- Editing `/etc/hostname` — **persistent**, but does *not* change the running hostname; it takes effect at the next boot (or when `systemd-hostnamed`/the init script reads it).
- `hostnamectl set-hostname lab-node` — **both**: it writes `/etc/hostname` *and* calls `sethostname(2)` immediately, and it notifies interested services over D-Bus. This is the correct single command on any systemd distribution. Note that none of the three updates `/etc/hosts`, so `hostname -f` can break after a rename until you fix that file too.

**A9.4** `hostname -I` deliberately filters: it omits loopback addresses, and it omits IPv6 **link-local** addresses. So a host whose only IPv6 address is `fe80::…` shows nothing for IPv6 in `hostname -I` while `ip -br addr` displays it plainly. Other reasons for divergence: addresses on interfaces that are administratively down, addresses in a different network namespace, and (in older `net-tools` builds) addresses marked `deprecated` or `tentative` during Duplicate Address Detection. The general principle applies well beyond this command — `hostname -I` and `ifconfig` are *summaries*; `ip` is the source of truth.

### Exercise 10

**A10.1** Because the ladder must be climbed from the bottom, and each rung is only meaningful if the ones below it hold. `ping 1.1.1.1` exercises link, address, neighbour, route and path *without* involving DNS at all. If it fails, testing `getent hosts` is wasted effort — the resolver query is itself carried over the very network that is broken, so it would fail for reasons that tell you nothing new. Testing top-down inverts cause and symptom and is the most common way an engineer spends twenty minutes on DNS when a cable is unplugged.

**A10.2** By using the address that `dig @1.1.1.1` returned. The drill deliberately keeps the two halves of rung 6 separate: `getent hosts` (what the application sees) and `dig @<public resolver>` (what DNS actually says). When they disagree, `dig` has still handed you a usable address, so rung 7 can proceed against `208.94.116.9` directly:
```bash
nc -vz -w 3 208.94.116.9 443
```
This is the general technique for testing *below* a broken layer — substitute the artefact the broken layer would have produced, and the rungs above become testable again. It converts "everything is broken" into "exactly one thing is broken", which is the whole objective.

**A10.3** Most likely causes:
1. **VLAN mismatch** — the two switch ports are in different VLANs, so ARP broadcasts never reach the other host. Both hosts look perfect locally.
2. **Host firewall dropping ARP or ICMP inbound** on one or both machines — less common for ARP (it is handled below netfilter's IP hooks and needs `arptables`/`ebtables`/`nft` bridge rules), but very common for ICMP echo, which would give `FAILED` only if you were relying on `ping` to trigger resolution.
   A third strong candidate is **mismatched prefix lengths**, where each host believes the other is off-link.

Discriminating command:
```bash
sudo ip neigh flush all && ping -c 2 -W 1 <other-host> ; ip neigh show <other-host>
sudo tcpdump -ni enp1s0 arp        # on the other host, while the first pings
```
If the second host's `tcpdump` shows the ARP *requests* arriving, L2 delivery works and the fault is a filter or a stack issue on that host; if no ARP arrives at all, the segment itself is separating them — VLAN, port isolation, or wrong prefix. Confirming the prefix takes one command: `ip -br -4 addr` on both.

**A10.4** Rung 5 — **path MTU**. The signature is unmistakable: small packets (which fit any MTU) succeed, so ping, traceroute and the TLS handshake are all clean; the failure begins exactly when the first full-size segment is sent, which for an upload is the moment real data starts flowing. The cause is usually a tunnel (PPPoE, IPsec, WireGuard, GRE) reducing MTU somewhere on the path, combined with a device that blocks `ICMP Fragmentation Needed`, so Path MTU Discovery silently black-holes.

Evidence:
```bash
ping -c 1 -M do -s 1472 <server>    # 1500-byte datagram
ping -c 1 -M do -s 1400 <server>    # 1428-byte datagram
tracepath -n <server>               # Resume: pmtu <n>
```
If 1400 succeeds and 1472 fails with `Frag needed and DF set (mtu = …)` — or worse, fails *silently* — you have located it, and `tracepath`'s `pmtu` line names the value. The remedy is to lower the interface MTU to the discovered value or to clamp TCP MSS on the router.

**A10.5** Three concrete reasons, none of them ceremonial:
1. **You cannot compare against a state you did not record.** The most common diagnostic question is "what changed?", and without a before-image the answer is guesswork. `diff` against the snapshot answers it in one command.
2. **Troubleshooting mutates the evidence.** Flushing a neighbour table, restarting NetworkManager, or bouncing an interface destroys exactly the state that would have identified the fault. The snapshot is the only copy of the crime scene.
3. **You need a rollback path.** Every change in Exercise 8 was safe only because step 1 recorded what to restore. On a production host, "I'll remember" fails at the moment you most need it — twenty minutes into an incident, under pressure, on a machine you can no longer reach.

A fourth, organisational reason: the snapshot is what you hand to the next engineer, or attach to the ticket. It is the difference between a report someone can act on and a report that starts another investigation from zero.

</details>

---

## Sources

- **LPI exam objectives** — Topic 109, *Networking Fundamentals*: [102-500 objectives](https://www.lpi.org/our-certifications/exam-102-objectives/); companion list [101-500 objectives](https://www.lpi.org/our-certifications/exam-101-objectives/)
- **iproute2** (`ip`, `ss`, `bridge`) — upstream: <https://wiki.linuxfoundation.org/networking/iproute2>; man pages: [`ip-address(8)`](https://man7.org/linux/man-pages/man8/ip-address.8.html), [`ip-route(8)`](https://man7.org/linux/man-pages/man8/ip-route.8.html), [`ip-neighbour(8)`](https://man7.org/linux/man-pages/man8/ip-neighbour.8.html), [`ss(8)`](https://man7.org/linux/man-pages/man8/ss.8.html)
- **iputils** (`ping`, `tracepath`, `arping`) — <https://github.com/iputils/iputils>; [`ping(8)`](https://man7.org/linux/man-pages/man8/ping.8.html), [`tracepath(8)`](https://man7.org/linux/man-pages/man8/tracepath.8.html)
- **traceroute** — <https://traceroute.sourceforge.net/>; [`traceroute(8)`](https://man7.org/linux/man-pages/man8/traceroute.8.html)
- **BIND diagnostic tools** (`dig`, `host`) — ISC documentation: <https://bind9.readthedocs.io/en/latest/manpages.html>
- **glibc name resolution** — NSS and the resolver: [`nsswitch.conf(5)`](https://man7.org/linux/man-pages/man5/nsswitch.conf.5.html), [`resolv.conf(5)`](https://man7.org/linux/man-pages/man5/resolv.conf.5.html), [`getaddrinfo(3)`](https://man7.org/linux/man-pages/man3/getaddrinfo.3.html), [`hosts(5)`](https://man7.org/linux/man-pages/man5/hosts.5.html), [`services(5)`](https://man7.org/linux/man-pages/man5/services.5.html)
- **systemd-resolved** — <https://www.freedesktop.org/software/systemd/man/latest/systemd-resolved.service.html>, [`resolvectl(1)`](https://www.freedesktop.org/software/systemd/man/latest/resolvectl.html), [`hostnamectl(1)`](https://www.freedesktop.org/software/systemd/man/latest/hostnamectl.html)
- **OpenBSD netcat** — [`nc(1)`](https://man.openbsd.org/nc.1)
- **mtr** — <https://www.bitwizard.nl/mtr/>
- **RFCs** — [RFC 792](https://www.rfc-editor.org/rfc/rfc792) (ICMP), [RFC 826](https://www.rfc-editor.org/rfc/rfc826) (ARP), [RFC 1191](https://www.rfc-editor.org/rfc/rfc1191) (Path MTU Discovery), [RFC 4007](https://www.rfc-editor.org/rfc/rfc4007) (IPv6 scoped addresses), [RFC 4861](https://www.rfc-editor.org/rfc/rfc4861) (IPv6 Neighbor Discovery), [RFC 9293](https://www.rfc-editor.org/rfc/rfc9293) (TCP), [RFC 9112](https://www.rfc-editor.org/rfc/rfc9112) (HTTP/1.1)
- **Debian Policy §11.9**, on the `127.0.1.1` convention — <https://www.debian.org/doc/debian-policy/ch-customized-programs.html>