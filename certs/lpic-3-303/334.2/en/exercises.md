# LPIC-3 303 (303-300 v3.0.0) — Topic 334.2: Network Intrusion Detection
## Guided Laboratory Exercises

> **Exam weight:** 6.67 · **Objective source:** <https://www.lpi.org/our-certifications/exam-303-objectives/>
>
> **Key knowledge areas covered here:** bandwidth usage monitoring · Snort configuration, rule writing and rule management · OpenVAS/GVM configuration and NASL.
>
> **Terms and utilities exercised:** `ntop`/`ntopng`, `Cacti`, `bandwidthd`, `iftop`, `iptraf-ng`, `snort`, `snort-stat`, `/etc/snort/*`, `oinkmaster`, `pulledpork`, `openvas`/`gvmd`/`gsad`/`ospd-openvas`, `greenbone-feed-sync`, `gvm-check-setup`, `gvm-cli`, `openvas-nasl`, NASL.

---

## 0. Lab topology, prerequisites and rules of engagement

> **Rules of engagement.** Every scan, probe and exploit in this lab is aimed at machines you build yourself, on an isolated host-only network with **no route to the Internet from the target segment**. Vulnerability scanning a host you do not own or have written authorisation to test is a criminal offence in most jurisdictions. Never point `gvmd` at a production network without a signed scope document — an authenticated GVM scan is indistinguishable from an attack in any SOC worth its salary.

Build three virtual machines on an isolated network `192.168.56.0/24`:

| Role | Hostname | IP | OS | Purpose |
|---|---|---|---|---|
| Sensor | `sensor` | 192.168.56.10 | Debian 12 (bookworm) | Snort 2.9 + Snort 3, bandwidth tooling, Cacti |
| Target | `target`  | 192.168.56.20 | Debian 12 | `nginx`, `vsftpd`, `openssh-server`, `snmpd` |
| Scanner | `scanner` | 192.168.56.30 | Kali Linux (rolling) | GVM/OpenVAS, `nmap`, `hping3` |

The sensor additionally has a second interface, `eth1`, attached to the same segment in **promiscuous / monitor** mode — this is the interface Snort listens on, emulating a SPAN/mirror port.

```bash
# On all three, as root
apt-get update && apt-get -y install tcpdump ethtool net-tools iproute2 curl git
hostnamectl set-hostname sensor    # adjust per host
```

On `target`:

```bash
apt-get -y install nginx vsftpd openssh-server snmpd
systemctl enable --now nginx vsftpd ssh snmpd
```

Snapshot all three VMs now. Several exercises are destructive to configuration.

---

## Exercise 1 — Prepare the sensor interface for honest capture

A NIDS that reads reassembled, offloaded frames sees a packet stream the target host will never see. This is the single most common cause of "Snort is running but detects nothing" in production.

**Steps**

1. Bring the monitoring interface up without an IP address. An IP-less interface cannot be addressed, which is the correct posture for a passive sensor:

   ```bash
   ip link set eth1 up
   ip addr flush dev eth1
   ip -brief link show eth1
   ```

   Expected:

   ```
   eth1             UP             08:00:27:9c:1a:44 <BROADCAST,MULTICAST,UP,LOWER_UP>
   ```

2. Enable promiscuous mode explicitly and confirm the kernel accepted it:

   ```bash
   ip link set eth1 promisc on
   ip -d link show eth1 | grep -i promisc
   dmesg | tail -3
   ```

   Expected (abridged):

   ```
   [ 4213.882110] device eth1 entered promiscuous mode
   ```

3. Inspect the NIC offload features that rewrite the packet stream before it reaches libpcap:

   ```bash
   ethtool -k eth1 | grep -E 'generic-receive-offload|large-receive-offload|tcp-segmentation-offload|generic-segmentation-offload'
   ```

   Expected:

   ```
   tcp-segmentation-offload: on
   generic-segmentation-offload: on
   generic-receive-offload: on
   large-receive-offload: off [fixed]
   ```

4. Disable them and make the change survive a reboot:

   ```bash
   ethtool -K eth1 gro off lro off tso off gso off
   ethtool -k eth1 | grep -E 'generic-receive-offload|tcp-segmentation-offload'
   ```

   ```bash
   cat >/etc/systemd/system/nic-offload@.service <<'EOF'
   [Unit]
   Description=Disable NIC offloads on %i for IDS capture
   After=network.target

   [Service]
   Type=oneshot
   ExecStart=/usr/sbin/ethtool -K %i gro off lro off tso off gso off
   RemainAfterExit=yes

   [Install]
   WantedBy=multi-user.target
   EOF
   systemctl daemon-reload
   systemctl enable --now nic-offload@eth1
   ```

5. Take a baseline capture and confirm you see traffic that is *not* addressed to the sensor. From `scanner`, run `ping -c 20 192.168.56.20` while the sensor runs:

   ```bash
   tcpdump -i eth1 -nn -c 10 -s 0 'icmp'
   ```

   Expected (abridged):

   ```
   14:02:11.334512 IP 192.168.56.30 > 192.168.56.20: ICMP echo request, id 12, seq 1, length 64
   14:02:11.334980 IP 192.168.56.20 > 192.168.56.30: ICMP echo reply,   id 12, seq 1, length 64
   ```

6. Measure drops before you trust any alert count:

   ```bash
   tcpdump -i eth1 -nn -s 0 -w /tmp/base.pcap &
   sleep 30; kill %1
   ip -s link show eth1 | sed -n '3,6p'
   ```

   Expected:

   ```
   RX:  bytes packets errors dropped  missed   mcast
       184220    1902      0       0       0      12
   ```

**Comprehension check — block 1**

- **Q1.1** — Why does an interface in promiscuous mode with no IP address still deliver frames to `libpcap`?
- **Q1.2** — Explain precisely what GRO does to a stream of five 1460-byte TCP segments, and why that breaks a Snort rule with `content:"attack"; depth:20;`.
- **Q1.3** — You see `dropped 0` in `ip -s link` but Snort's exit summary reports 4% of packets dropped. Where is the loss occurring, and which counter would you read instead?
- **Q1.4** — Give one operational reason to prefer a passive network TAP over a switch SPAN port for a NIDS sensor.

---

## Exercise 2 — Real-time bandwidth usage monitoring

The objective explicitly requires *"implement bandwidth usage monitoring"*. Real-time tools answer "what is happening now"; Exercise 3 answers "what happened last Tuesday".

**Steps**

1. Install the real-time toolset on `sensor`:

   ```bash
   apt-get -y install iftop iptraf-ng nload bmon vnstat
   ```

2. Run `iftop` bound to the monitoring interface, with numeric hosts and ports and byte-based units:

   ```bash
   iftop -i eth1 -nNPB
   ```

   Expected (abridged):

   ```
                     12.5KB          25.0KB          37.5KB          50.0KB   62.5KB
   └───────────────┴───────────────┴───────────────┴───────────────┴──────────────
   192.168.56.30:51244        =>  192.168.56.20:80          14.2KB  9.81KB  9.02KB
                              <=                            310KB   241KB   228KB
   192.168.56.30:22           =>  192.168.56.10:22           1.9KB  1.71KB  1.65KB
   ──────────────────────────────────────────────────────────────────────────────
   TX:  cum:  1.42MB   peak:  45.2KB   rates:  16.1KB  11.5KB  10.7KB
   RX:        7.31MB          312KB            311KB   243KB   230KB
   TOTAL:     8.73MB          338KB            327KB   254KB   241KB
   ```

   While it runs, press `n` (toggle DNS resolution), `p` (toggle ports), `t` (cycle the two-line/one-line display), `L` (logarithmic scale), `P` (pause), `o` (freeze the current order).

   > The three rate columns are the 2-second, 10-second and 40-second moving averages — not instantaneous values.

3. Generate load from `scanner` and watch the flows appear:

   ```bash
   # on scanner
   dd if=/dev/zero bs=1M count=200 | ssh root@192.168.56.10 'cat > /dev/null'
   ```

4. Use `iftop` non-interactively so it can feed a script or a cron report:

   ```bash
   timeout 15 iftop -i eth1 -nNB -t -s 10 -L 10 > /tmp/iftop-report.txt
   head -20 /tmp/iftop-report.txt
   ```

5. Apply a BPF filter to exclude your own management traffic — a sensor that reports its own SSH session as the top talker is useless:

   ```bash
   iftop -i eth1 -nNPB -f 'not (host 192.168.56.10 and port 22)'
   ```

6. Switch to `iptraf-ng` for per-protocol and per-service breakdowns:

   ```bash
   iptraf-ng -i eth1              # IP traffic monitor, single interface
   ```

   Then exercise the non-interactive collectors, each of which writes a log and can be backgrounded:

   ```bash
   timeout 30 iptraf-ng -s eth1 -L /var/log/iptraf-services.log -B
   timeout 30 iptraf-ng -d eth1 -L /var/log/iptraf-detail.log   -B
   timeout 30 iptraf-ng -z eth1 -L /var/log/iptraf-sizes.log    -B
   grep -A15 'TCP/UDP service monitor' /var/log/iptraf-services.log | head -20
   ```

   Expected (abridged):

   ```
   *** TCP/UDP service monitor started on eth1
   Proto/Port      Pkts     Bytes   Pkts to/from   Bytes to/from
   TCP/80          4821   6431220           2410         6398112
   TCP/22           932    141880            466           78210
   UDP/161           48      6912             24            3456
   ```

7. Enable `vnstat` for zero-cost long-term interface totals (kernel counters, not packet capture):

   ```bash
   systemctl enable --now vnstat
   vnstat -i eth1 --add 2>/dev/null; sleep 60
   vnstat -i eth1 -h
   ```

**Comprehension check — block 2**

- **Q2.1** — `iftop` and `vnstat` disagree about total throughput on the same interface. Give the architectural reason and say which one you would quote in a capacity-planning report.
- **Q2.2** — `iptraf-ng -z` reports that 71% of packets are in the 1–75 byte bucket while total throughput is low. What two very different conditions produce that profile, and how would you tell them apart with `iftop` alone?
- **Q2.3** — Why does `iftop` need `CAP_NET_RAW`, and what is the least-privilege way to let a non-root operator run it?
- **Q2.4** — You add `-f 'not port 22'` to `iftop` and traffic drops to almost nothing on a busy link. What does that tell you, and why is that a *finding* rather than a configuration mistake?

---

## Exercise 3 — Historical accounting: `bandwidthd`, SNMP, RRDtool and Cacti

**Steps — part A: `bandwidthd`**

1. Install and configure per-host accounting:

   ```bash
   apt-get -y install bandwidthd
   cp /etc/bandwidthd/bandwidthd.conf /etc/bandwidthd/bandwidthd.conf.orig
   ```

2. Edit `/etc/bandwidthd/bandwidthd.conf`:

   ```conf
   subnet 192.168.56.0/24
   dev "eth1"
   skip_intervals 0
   graph_cutoff 1024
   promiscuous true
   output_cdf true
   recover_cdf true
   filter "ip"
   graph true
   meta_refresh 150
   ```

3. Restart and confirm it is writing:

   ```bash
   systemctl restart bandwidthd
   systemctl is-active bandwidthd
   ls -l /var/lib/bandwidthd/htdocs/ | head
   ```

   Expected (abridged, after the first 150-second interval):

   ```
   -rw-r--r-- 1 root root  15234 Aug 25 14:20 index.html
   -rw-r--r-- 1 root root   4211 Aug 25 14:20 ip-192.168.56.20.html
   -rw-r--r-- 1 root root  28110 Aug 25 14:20 192.168.56.20-daily.png
   ```

4. Inspect the persistent CDF (the raw accounting database, not the graphs):

   ```bash
   ls -l /var/lib/bandwidthd/*.cdf
   head -3 /var/lib/bandwidthd/log.1.0.cdf
   ```

**Steps — part B: SNMP + RRDtool + Cacti**

5. On `target`, expose interface counters over SNMP, restricted to the sensor:

   ```bash
   cp /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.orig
   cat >/etc/snmp/snmpd.conf <<'EOF'
   agentaddress udp:161
   rocommunity lab303 192.168.56.10
   sysLocation  Lab-303
   sysContact   lab@example.invalid
   view   systemonly  included   .1.3.6.1.2.1.1
   view   systemonly  included   .1.3.6.1.2.1.2
   view   systemonly  included   .1.3.6.1.2.1.25.1
   EOF
   systemctl restart snmpd
   ```

6. From `sensor`, verify the counters are readable and that you are getting **64-bit** counters:

   ```bash
   apt-get -y install snmp snmp-mibs-downloader rrdtool
   snmpwalk -v2c -c lab303 192.168.56.20 IF-MIB::ifDescr
   snmpget  -v2c -c lab303 192.168.56.20 IF-MIB::ifHCInOctets.2 IF-MIB::ifHCOutOctets.2
   ```

   Expected:

   ```
   IF-MIB::ifDescr.1 = STRING: lo
   IF-MIB::ifDescr.2 = STRING: eth0
   IF-MIB::ifHCInOctets.2  = Counter64: 1043221190
   IF-MIB::ifHCOutOctets.2 = Counter64: 88213377
   ```

7. Build a minimal RRD by hand so the Cacti abstraction stops being magic:

   ```bash
   rrdtool create /tmp/eth0.rrd --step 300 \
     DS:in:COUNTER:600:0:U \
     DS:out:COUNTER:600:0:U \
     RRA:AVERAGE:0.5:1:600 \
     RRA:AVERAGE:0.5:6:700 \
     RRA:AVERAGE:0.5:24:775 \
     RRA:MAX:0.5:288:797
   rrdtool info /tmp/eth0.rrd | grep -E '^(step|ds\[in\]\.(type|minimal_heartbeat)|rra\[0\])'
   ```

   Expected (abridged):

   ```
   step = 300
   ds[in].type = "COUNTER"
   ds[in].minimal_heartbeat = 600
   rra[0].cf = "AVERAGE"
   ```

8. Install Cacti and let `dbconfig-common` create the database:

   ```bash
   apt-get -y install cacti cacti-spine
   # Accept dbconfig-common; choose apache2 when prompted.
   grep -R 'poller' /etc/cron.d/cacti
   ```

   Expected:

   ```
   */5 * * * * www-data [ -x /usr/share/cacti/site/poller.php ] && php /usr/share/cacti/site/poller.php >/dev/null 2>&1
   ```

9. Finish the web installer at `http://192.168.56.10/cacti/` (default credentials `admin` / the password you set during install). Then:
   - **Console → Devices → Add**: hostname `192.168.56.20`, template *Generic SNMP-enabled Host*, SNMP v2c, community `lab303`.
   - **Create Graphs for this Host** → select the `eth0` interface → *Interface - Traffic (bits/sec)*.
   - **Console → Settings → Poller** → Poller Type `spine`.

10. Force a poll instead of waiting five minutes, and read the resulting RRD directly:

    ```bash
    sudo -u www-data php /usr/share/cacti/site/poller.php --force 2>&1 | tail -5
    ls -l /var/lib/cacti/rra/ | head
    rrdtool fetch /var/lib/cacti/rra/<file>.rrd AVERAGE -s -30m | head -8
    ```

    Expected (abridged):

    ```
    OK u:0.00 s:0.00 r:2.34
    08/25/2026 02:20:00 PM - SYSTEM STATS: Time:2.3418 Method:spine Processes:1 Threads:1 Hosts:2 HostsPerProcess:2 DataSources:8 RRDsProcessed:4
    ```

    ```
                          traffic_in          traffic_out
    1756130400: 1.2043302847e+04 8.8210039122e+02
    1756130700: 1.1980221194e+04 9.0112377301e+02
    ```

**Comprehension check — block 3**

- **Q3.1** — `bandwidthd` and Cacti both graph "bandwidth". State the fundamental difference in *data source* and give one thing each can show that the other structurally cannot.
- **Q3.2** — Your RRD has `DS:in:COUNTER:600:0:U` and the device reboots. What value is stored for the interval spanning the reboot, and why?
- **Q3.3** — You polled `ifInOctets` (32-bit) on a 1 Gbit/s link at 5-minute intervals and the graph shows implausible spikes. Explain the failure and the fix.
- **Q3.4** — Explain, using the RRA definitions in step 7, why a 30-second traffic burst is invisible in the yearly graph but visible in the `MAX` RRA.
- **Q3.5** — Why is `rocommunity lab303 192.168.56.10` still weak authentication, and what does SNMPv3 change?

---

## Exercise 4 — Snort 2.9 from the distribution: `/etc/snort/*` and the core modes

Debian's `snort` package is the artefact the exam objective names (`/etc/snort/*`, `snort-stat`). Snort 2.9 is end-of-life upstream — you will build Snort 3 in Exercise 6 — but the configuration layout and rule dialect are directly examinable.

**Steps**

1. Install on `sensor`, answering the debconf prompts with interface `eth1` and HOME_NET `192.168.56.0/24`:

   ```bash
   apt-get -y install snort snort-rules-default
   snort -V
   ```

   Expected (abridged):

   ```
      ,,_     -*> Snort! <*-
     o"  )~   Version 2.9.20 GRE (Build 82)
      ''''    By Martin Roesch & The Snort Team: http://www.snort.org/contact#team
              Copyright (C) 2014-2022 Cisco and/or its affiliates. All rights reserved.
   ```

2. Map the configuration tree — know what each file is *for*, not just that it exists:

   ```bash
   ls -1 /etc/snort/
   ls -1 /etc/snort/rules | head
   ```

   Expected (abridged):

   ```
   attribute_table.dtd
   classification.config
   gen-msg.map
   reference.config
   rules/
   snort.conf
   snort.debian.conf
   threshold.conf
   unicode.map
   ```

   | File | Role |
   |---|---|
   | `snort.conf` | Master configuration: variables, decoder, preprocessors, output, `include` of rule files |
   | `snort.debian.conf` | Debian-specific init wrapper settings: `DEBIAN_SNORT_INTERFACE`, `HOME_NET`, options |
   | `classification.config` | Maps `classtype:` names to priorities |
   | `reference.config` | Maps `reference:` prefixes (`cve`, `bugtraq`, `url`) to URL templates |
   | `gen-msg.map` / `sid-msg.map` | Generator-ID and SID → message maps used by output plugins and `snort-stat` |
   | `threshold.conf` | Legacy event thresholding and suppression |
   | `rules/` | Rule files pulled in by `include $RULE_PATH/…` |

3. Read the variable block that every rule depends on:

   ```bash
   grep -E '^(ipvar|portvar|var) ' /etc/snort/snort.conf | head -20
   ```

   Expected (abridged):

   ```
   ipvar HOME_NET 192.168.56.0/24
   ipvar EXTERNAL_NET !$HOME_NET
   ipvar DNS_SERVERS $HOME_NET
   portvar HTTP_PORTS [80,81,311,383,591,593,901,1220,...]
   var RULE_PATH /etc/snort/rules
   ```

4. Validate the configuration **before** touching the service — this is the step that separates a working sensor from a silent one:

   ```bash
   snort -T -c /etc/snort/snort.conf -i eth1 2>&1 | tail -8
   ```

   Expected (abridged):

   ```
           --== Initialization Complete ==--
   Snort successfully validated the configuration!
   Snort exiting
   ```

5. Run the three classic modes in sequence, on a short capture, and observe how the output differs:

   ```bash
   # (a) Sniffer mode — decoded headers to stdout, no rules at all
   timeout 10 snort -v -i eth1

   # (b) Sniffer with payload and link layer
   timeout 10 snort -dev -i eth1

   # (c) Packet logger mode — binary pcap into a log directory
   timeout 10 snort -b -l /var/log/snort -i eth1
   ls -l /var/log/snort/snort.log.*
   ```

6. Replay a pcap through the full rule set — this is how you test a sensor deterministically:

   ```bash
   # produce traffic first, from scanner:  nmap -sS -p 1-100 192.168.56.20
   tcpdump -i eth1 -nn -s 0 -w /tmp/scan.pcap &   # on sensor, before the nmap
   # ...run the nmap, then kill tcpdump
   snort -q -A console -c /etc/snort/snort.conf -r /tmp/scan.pcap
   ```

   Expected (abridged):

   ```
   08/25-14:31:02.118344  [**] [122:1:0] (portscan) TCP Portscan [**] [Priority: 3] {PROTO:255} 192.168.56.30 -> 192.168.56.20
   ```

7. Read the exit statistics carefully — these numbers, not the alert count, tell you whether the sensor is healthy:

   ```bash
   snort -c /etc/snort/snort.conf -r /tmp/scan.pcap 2>&1 | sed -n '/Packet I\/O Totals/,/^===/p'
   ```

   Expected (abridged):

   ```
   ===============================================================================
   Packet I/O Totals:
      Received:         1902
      Analyzed:         1902 (100.000%)
       Dropped:            0 (  0.000%)
      Filtered:            0 (  0.000%)
   Outstanding:            0 (  0.000%)
      Injected:            0
   ===============================================================================
   ```

**Comprehension check — block 4**

- **Q4.1** — What is the practical consequence of setting `ipvar EXTERNAL_NET any` instead of `!$HOME_NET`? Give both the detection effect and the performance effect.
- **Q4.2** — `snort -T` succeeds but the systemd unit fails to start. Name three causes that `-T` structurally cannot catch.
- **Q4.3** — In the alert `[122:1:0]`, identify each of the three numbers and explain why the third is `0` here but non-zero in a rule you write yourself.
- **Q4.4** — Why is replaying a pcap not a complete test of a sensor that will run inline? Name two behaviours that only appear on live traffic.
- **Q4.5** — Under what circumstances does `Analyzed` fall below `Received` even when `Dropped` is 0?

---

## Exercise 5 — Rule anatomy: writing, testing and tuning Snort rules

**Steps**

1. Create a local rule file and make sure it is included exactly once:

   ```bash
   grep -n 'local.rules' /etc/snort/snort.conf
   ```

   Expected:

   ```
   576:include $RULE_PATH/local.rules
   ```

2. Write four rules that exercise the header, the payload options, the non-payload options and the post-detection options:

   ```bash
   cat >/etc/snort/rules/local.rules <<'EOF'
   # ---- 1. Header only: any ICMP echo request into the lab
   alert icmp $EXTERNAL_NET any -> $HOME_NET any ( \
     msg:"LOCAL ICMP echo request into HOME_NET"; \
     itype:8; \
     classtype:misc-activity; \
     sid:1000001; rev:1; )

   # ---- 2. Payload: path traversal attempt in a URI
   alert tcp $EXTERNAL_NET any -> $HOME_NET $HTTP_PORTS ( \
     msg:"LOCAL HTTP path traversal attempt"; \
     flow:to_server,established; \
     content:"GET"; http_method; \
     content:"../"; http_uri; nocase; \
     reference:url,owasp.org/www-community/attacks/Path_Traversal; \
     classtype:web-application-attack; \
     sid:1000002; rev:1; )

   # ---- 3. Non-payload + rate: SSH authentication brute force
   alert tcp $EXTERNAL_NET any -> $HOME_NET 22 ( \
     msg:"LOCAL SSH connection flood from single source"; \
     flow:to_server; \
     flags:S; \
     detection_filter:track by_src, count 10, seconds 30; \
     classtype:attempted-recon; \
     sid:1000003; rev:1; )

   # ---- 4. Stateful across packets: FTP login followed by SITE EXEC
   alert tcp $EXTERNAL_NET any -> $HOME_NET 21 ( \
     msg:"LOCAL FTP USER observed"; \
     flow:to_server,established; \
     content:"USER "; depth:5; nocase; \
     flowbits:set,lab.ftp_user; flowbits:noalert; \
     sid:1000004; rev:1; )

   alert tcp $EXTERNAL_NET any -> $HOME_NET 21 ( \
     msg:"LOCAL FTP SITE EXEC after USER"; \
     flow:to_server,established; \
     flowbits:isset,lab.ftp_user; \
     content:"SITE EXEC"; nocase; \
     classtype:attempted-admin; priority:1; \
     sid:1000005; rev:1; )
   EOF
   snort -T -c /etc/snort/snort.conf -i eth1 2>&1 | tail -3
   ```

3. Trigger rules 1 and 2 from `scanner` while Snort runs in console mode on `sensor`:

   ```bash
   # sensor
   snort -q -A console -c /etc/snort/snort.conf -i eth1
   ```

   ```bash
   # scanner
   ping -c 3 192.168.56.20
   curl -s 'http://192.168.56.20/index.html?f=../../../../etc/passwd' -o /dev/null
   ```

   Expected on the sensor:

   ```
   08/25-15:04:19.774312  [**] [1:1000001:1] LOCAL ICMP echo request into HOME_NET [**] [Classification: Misc activity] [Priority: 3] {ICMP} 192.168.56.30 -> 192.168.56.20
   08/25-15:04:33.117905  [**] [1:1000002:1] LOCAL HTTP path traversal attempt [**] [Classification: Web Application Attack] [Priority: 1] {TCP} 192.168.56.30:41288 -> 192.168.56.20:80
   ```

4. Trigger rule 3 and observe `detection_filter` semantics:

   ```bash
   # scanner
   hping3 -S -p 22 -c 25 -i u20000 192.168.56.20
   ```

   You get **one** alert on the 10th matching packet within the window, then one per subsequent packet — not one per packet from the start.

5. Now suppress a noisy rule per-source without editing it, using event filtering:

   ```bash
   cat >>/etc/snort/threshold.conf <<'EOF'
   # Only ever report SID 1000001 once per 60s per source
   event_filter gen_id 1, sig_id 1000001, type limit, track by_src, count 1, seconds 60

   # The monitoring station legitimately pings everything; silence it entirely
   suppress gen_id 1, sig_id 1000001, track by_src, ip 192.168.56.30
   EOF
   snort -T -c /etc/snort/snort.conf -i eth1 2>&1 | tail -3
   ```

6. Verify the suppression took effect by repeating step 3's ping — no ICMP alert should appear, while the HTTP alert still does.

7. Read a shipped rule and decompose it. Pick any rule from the distribution set:

   ```bash
   grep -m1 'flowbits' /etc/snort/rules/*.rules
   ```

**Comprehension check — block 5**

- **Q5.1** — In rule 2, why is `content:"GET"; http_method;` cheaper for the detection engine than `content:"GET /"; depth:5;` even though both match the same traffic?
- **Q5.2** — What is the difference between `detection_filter` and an `event_filter` with `type limit`? Which one changes whether the rule *matched*?
- **Q5.3** — Rule 4 uses `flowbits:noalert`. What breaks if you omit it, and what breaks if you also omit `flowbits:set`?
- **Q5.4** — Two analysts both add rules with `sid:1000002`. What does Snort do, and what SID range should locally written rules use?
- **Q5.5** — You need `content:"admin"` to match only in the HTTP response body, never in headers. Name the mechanism in Snort 2 and its Snort 3 equivalent.
- **Q5.6** — Why does `flow:to_server,established` both improve accuracy *and* reduce CPU?

---

## Exercise 6 — Snort 3: architecture, Lua configuration and multithreading

**Steps**

1. Build Snort 3 from source on `sensor` (allow 15–30 minutes):

   ```bash
   apt-get -y install build-essential cmake libpcap-dev libpcre2-dev libdumbnet-dev \
     bison flex zlib1g-dev pkg-config libhwloc-dev liblzma-dev openssl libssl-dev \
     libnghttp2-dev libluajit-5.1-dev libunwind-dev uuid-dev libtool autoconf \
     libmnl-dev libnetfilter-queue-dev

   cd /usr/local/src
   git clone https://github.com/snort3/libdaq.git
   cd libdaq && ./bootstrap && ./configure --prefix=/usr/local && make -j"$(nproc)" && make install

   cd /usr/local/src
   git clone https://github.com/snort3/snort3.git
   cd snort3 && ./configure_cmake.sh --prefix=/usr/local --enable-tcmalloc
   cd build && make -j"$(nproc)" && make install
   ldconfig
   /usr/local/bin/snort -V
   ```

   Expected (abridged):

   ```
      ,,_     -*> Snort++ <*-
     o"  )~   Version 3.1.78.0
      ''''    By Martin Roesch & The Snort Team
   ```

2. Enumerate the runtime architecture. Every stage below is a plugin you can list:

   ```bash
   /usr/local/bin/snort --show-plugins 2>&1 | awk '{print $1}' | sort | uniq -c | sort -rn | head
   /usr/local/bin/snort --help-module search_engine | head -20
   /usr/local/bin/snort --list-modules | head -20
   ```

   The pipeline, in order: **DAQ** (packet acquisition) → **codecs** (decode link/network/transport) → **stream** (flow tracking + TCP reassembly) → **inspectors** (`http_inspect`, `dns`, `ssh`, `port_scan`, …, the Snort 2 "preprocessors") → **detection** (fast-pattern MPSE, then full rule evaluation) → **events** (filters/suppression) → **loggers** (`alert_fast`, `alert_json`, `unified2`, …).

3. Inspect the default Lua configuration and note the structural difference from `snort.conf`:

   ```bash
   ls -1 /usr/local/etc/snort/
   grep -n 'HOME_NET' /usr/local/etc/snort/snort.lua
   ```

   Expected (abridged):

   ```
   file_magic.lua
   snort.lua
   snort_defaults.lua
   talos.lua
   ```

4. Configure a minimal working sensor. Edit `/usr/local/etc/snort/snort.lua`:

   ```lua
   HOME_NET = '192.168.56.0/24'
   EXTERNAL_NET = '!$HOME_NET'

   ips =
   {
       enable_builtin_rules = true,
       include = RULE_PATH .. '/local.rules',
       variables = default_variables,
   }

   port_scan = { protos = 'all', scan_types = 'all', watch_ip = '192.168.56.0/24' }

   alert_fast = { file = true, packet = false }
   ```

5. Port two of your Snort 2 rules to Snort 3 syntax and note the sticky-buffer change:

   ```bash
   mkdir -p /usr/local/etc/snort/rules
   cat >/usr/local/etc/snort/rules/local.rules <<'EOF'
   alert icmp ( msg:"LOCAL ICMP echo request into HOME_NET"; itype:8;
                classtype:misc-activity; sid:1000001; rev:1; )

   alert http ( msg:"LOCAL HTTP path traversal attempt";
                flow:to_server,established;
                http_method; content:"GET";
                http_uri;    content:"../", nocase;
                classtype:web-application-attack; sid:1000002; rev:1; )
   EOF
   ```

   > In Snort 3 the buffer option (`http_uri`) is a **sticky buffer** that comes *before* the `content:` it applies to, and rule option arguments are comma-separated. In Snort 2 the modifier followed the `content:`.

6. Validate, then replay:

   ```bash
   /usr/local/bin/snort -c /usr/local/etc/snort/snort.lua --warn-all -T 2>&1 | tail -5
   /usr/local/bin/snort -c /usr/local/etc/snort/snort.lua \
     -R /usr/local/etc/snort/rules/local.rules \
     -r /tmp/scan.pcap -A alert_fast -s 65535 -k none -l /var/log/snort
   ```

   Expected (abridged):

   ```
   Snort successfully validated the configuration (with 0 warnings).
   o")~   Snort exiting
   ```

7. Run live with multiple packet threads over AF_PACKET fanout:

   ```bash
   /usr/local/bin/snort -c /usr/local/etc/snort/snort.lua \
     -i eth1 --daq afpacket --daq-var buffer_size_mb=1024 \
     -z 4 -A alert_fast -l /var/log/snort --warn-all
   ```

   The `-z 4` flag starts four packet-processing threads; `afpacket` fanout hashes each flow to exactly one thread so stream reassembly stays coherent.

8. Compare the two rule dialects mechanically:

   ```bash
   /usr/local/bin/snort -c /usr/local/etc/snort/snort.lua --rule-to-text \
     -R /usr/local/etc/snort/rules/local.rules 2>&1 | head
   /usr/local/bin/snort --dump-builtin-rules | head -5
   ```

**Comprehension check — block 6**

- **Q6.1** — What does the DAQ abstraction buy you that calling `libpcap` directly does not? Name two DAQ modules and the deployment each implies.
- **Q6.2** — Explain why `-z 4` with `afpacket` fanout is safe for TCP reassembly, but four *separate* `snort` processes on the same interface would not be.
- **Q6.3** — Convert `content:"admin"; nocase; http_client_body;` (Snort 2) to Snort 3, and explain why the order changed.
- **Q6.4** — What is `-k none` doing, and name the exact scenario in which omitting it makes a rule silently never fire.
- **Q6.5** — `--dump-builtin-rules` emits rules with GIDs other than 1. Where do those rules come from and why can't you edit them in a `.rules` file?

---

## Exercise 7 — Rule management and updates: `oinkmaster` and PulledPork

The objective is explicit about *"Snort rules management and updates"*. A sensor whose rules are three months old is a compliance artefact, not a control.

**Steps — part A: `oinkmaster` (classic, Snort 2)**

1. Install and inspect the configuration:

   ```bash
   apt-get -y install oinkmaster
   grep -vE '^\s*#|^\s*$' /etc/oinkmaster.conf | head -20
   ```

2. Register at <https://www.snort.org/users/sign_up> to obtain an **Oinkcode**, then set the rule source:

   ```bash
   cat >>/etc/oinkmaster.conf <<'EOF'
   url = https://www.snort.org/rules/snortrules-snapshot-29200.tar.gz?oinkcode=<YOUR_OINKCODE>
   url = https://www.snort.org/downloads/community/community-rules.tar.gz
   EOF
   ```

3. Learn the three tuning directives — this is the whole point of `oinkmaster`, and it is examinable:

   ```bash
   cat >>/etc/oinkmaster.conf <<'EOF'
   # Never let an update overwrite rules I own
   skipfile local.rules
   skipfile deleted.rules

   # Disable a rule that is a permanent false positive here
   disablesid 2013504

   # Re-enable a rule the vendor ships disabled
   enablesid 2010935

   # Change a rule in place, every time it is updated
   modifysid 2002383 "alert" | "drop"
   EOF
   ```

4. Do a dry run first, then apply, then reload the sensor:

   ```bash
   mkdir -p /var/backups/snort-rules
   oinkmaster -C /etc/oinkmaster.conf -o /etc/snort/rules -c        # -c = careful (dry run)
   oinkmaster -C /etc/oinkmaster.conf -o /etc/snort/rules -b /var/backups/snort-rules
   ```

   Expected (abridged):

   ```
   Loading /etc/oinkmaster.conf
   Downloading file from https://www.snort.org/rules/... done.
   Archive successfully downloaded, unpacking... done.
   Setting up rules structures... done.
   Processing downloaded rules... disabled 1, enabled 1, modified 1, total=48231
   Comparing new files to the old ones... done.
   [***] Results from Oinkmaster started ... [***]
   [*] Rules modifications: [*]
       -> Modified active rules: 214
       -> Added new rules: 37
   ```

5. Never restart, always reload — a restart drops packets:

   ```bash
   snort -T -c /etc/snort/snort.conf -i eth1 >/dev/null 2>&1 && kill -HUP "$(cat /var/run/snort_eth1.pid)"
   ```

**Steps — part B: PulledPork 3 (current, Snort 3)**

6. Install:

   ```bash
   cd /usr/local/src
   git clone https://github.com/shirkdog/pulledpork3.git
   cd pulledpork3
   mkdir -p /usr/local/etc/pulledpork3 /usr/local/bin/pulledpork3
   cp pulledpork.py       /usr/local/bin/
   cp -r lib/             /usr/local/bin/pulledpork3/
   cp etc/pulledpork.conf /usr/local/etc/pulledpork3/
   chmod +x /usr/local/bin/pulledpork.py
   ```

7. Configure `/usr/local/etc/pulledpork3/pulledpork.conf`:

   ```conf
   registered_ruleset  = true
   community_ruleset   = true
   oinkcode            = <YOUR_OINKCODE>
   snort_path          = /usr/local/bin/snort
   snort_version       = 3.1.78.0
   rule_path           = /usr/local/etc/snort/rules/pulledpork.rules
   local_rules         = /usr/local/etc/snort/rules/local.rules
   sorule_path         = /usr/local/etc/snort/so_rules/
   ips_policy          = balanced
   include_disabled_rules = false
   ```

8. Run it and read the summary:

   ```bash
   /usr/local/bin/pulledpork.py -c /usr/local/etc/pulledpork3/pulledpork.conf -v 2>&1 | tail -20
   wc -l /usr/local/etc/snort/rules/pulledpork.rules
   ```

   Expected (abridged):

   ```
   Rules ruleset:
       Rules loaded:              52104
       Rules enabled:             10233
       Rules disabled:            41871
       ...
   Writing rules to: /usr/local/etc/snort/rules/pulledpork.rules
   ```

9. Point Snort 3 at the merged file, revalidate, and confirm the enabled-rule count changed:

   ```lua
   -- in snort.lua
   ips = {
       enable_builtin_rules = true,
       include = RULE_PATH .. '/pulledpork.rules',
       variables = default_variables,
   }
   ```

   ```bash
   /usr/local/bin/snort -c /usr/local/etc/snort/snort.lua --warn-all -T 2>&1 | grep -iE 'rules|warning' | head
   ```

10. Automate it — but never blindly:

    ```bash
    cat >/etc/cron.d/pulledpork <<'EOF'
    # Update rules nightly; validate before reloading. Failure mails root.
    30 3 * * * root /usr/local/bin/pulledpork.py -c /usr/local/etc/pulledpork3/pulledpork.conf >/var/log/pulledpork.log 2>&1 && /usr/local/bin/snort -c /usr/local/etc/snort/snort.lua -T >>/var/log/pulledpork.log 2>&1 && systemctl reload snort3
    EOF
    ```

**Comprehension check — block 7**

- **Q7.1** — `oinkmaster` offers `disablesid` and you could equally just delete the rule line. Why is `disablesid` the correct choice in a managed environment?
- **Q7.2** — What is an `ips_policy` (`connectivity` / `balanced` / `security` / `max-detect`), and what does changing it from `balanced` to `security` do to your false-positive rate and your CPU?
- **Q7.3** — The cron job in step 10 uses `&&` between three commands. Name the exact failure mode this chaining prevents.
- **Q7.4** — What are SO rules, why do they need `sorule_path` and a matching `snort_version`, and what is the supply-chain risk they carry?
- **Q7.5** — Your `local.rules` disappeared after a rule update. Which configuration directive was missing, in each of the two tools?

---

## Exercise 8 — Output, logging and triage: `unified2`, `alert_json`, syslog and `snort-stat`

**Steps**

1. Exercise the Snort 2 output plugins one at a time against the same pcap and compare:

   ```bash
   for mode in fast full console cmg csv; do
     echo "=== $mode ==="
     snort -q -A "$mode" -c /etc/snort/snort.conf -r /tmp/scan.pcap -l /tmp/out-$mode 2>&1 | head -4
   done
   ```

2. Configure binary `unified2` output — the only format that scales, because Snort writes a compact binary record and hands the parsing cost to another process:

   ```bash
   # in /etc/snort/snort.conf
   output unified2: filename snort.u2, limit 128, mpls_event_types, vlan_event_types
   ```

   ```bash
   snort -q -c /etc/snort/snort.conf -r /tmp/scan.pcap -l /var/log/snort
   ls -l /var/log/snort/snort.u2.*
   u2spewfoo /var/log/snort/snort.u2.* | head -30
   ```

   Expected (abridged):

   ```
   (Event)
       sensor id: 0	event id: 1	event second: 1756131062	event microsecond: 118344
       sig id: 1	gen id: 122	revision: 0	 classification: 3
       priority: 3	ip source: 192.168.56.30	ip destination: 192.168.56.20
       src port: 0	dest port: 0	protocol: 255	impact_flag: 0	blocked: 0
   ```

3. Send alerts to syslog and confirm they land:

   ```bash
   snort -q -A syslog -c /etc/snort/snort.conf -r /tmp/scan.pcap
   grep snort /var/log/syslog | tail -3
   ```

   Expected (abridged):

   ```
   Aug 25 15:31:02 sensor snort[4412]: [122:1:0] (portscan) TCP Portscan [Classification: Attempted Information Leak] [Priority: 2]: {PROTO255} 192.168.56.30 -> 192.168.56.20
   ```

4. Summarise with `snort-stat`, the reporting tool the objective names. It is a Perl script that consumes **syslog-format** alert lines on standard input:

   ```bash
   head -30 /usr/sbin/snort-stat
   grep -h snort /var/log/syslog | /usr/sbin/snort-stat | head -40
   ```

   You get a plain-text report grouped by source host, destination host, signature and port, with per-group counts. *(The exact column layout varies between package versions — read the script header on your system rather than memorising a sample.)*

5. See where the distribution wires it up automatically:

   ```bash
   cat /etc/cron.daily/snort
   grep -vE '^\s*#|^\s*$' /etc/snort/snort.debian.conf
   ```

6. Now the Snort 3 equivalent — structured JSON, ready for a log shipper:

   ```lua
   -- in snort.lua
   alert_json =
   {
       file = true,
       limit = 100,
       fields = 'timestamp iface src_addr src_port dst_addr dst_port proto ' ..
                'action msg gid sid rev priority class service pkt_num'
   }
   ```

   ```bash
   /usr/local/bin/snort -c /usr/local/etc/snort/snort.lua -r /tmp/scan.pcap -l /var/log/snort -q
   tail -2 /var/log/snort/alert_json.txt | python3 -m json.tool
   ```

   Expected (abridged):

   ```json
   {
       "timestamp": "08/25-15:31:02.118344",
       "iface": "eth1",
       "src_addr": "192.168.56.30",
       "dst_addr": "192.168.56.20",
       "dst_port": 80,
       "proto": "TCP",
       "action": "allow",
       "msg": "LOCAL HTTP path traversal attempt",
       "gid": 1, "sid": 1000002, "rev": 1,
       "priority": 1,
       "class": "Web Application Attack"
   }
   ```

7. Compute a triage metric — the top ten signatures by volume — which is what actually drives tuning:

   ```bash
   python3 - <<'EOF'
   import json, collections
   c = collections.Counter()
   for line in open('/var/log/snort/alert_json.txt'):
       try: c[json.loads(line)['msg']] += 1
       except Exception: pass
   for msg, n in c.most_common(10): print(f'{n:8d}  {msg}')
   EOF
   ```

**Comprehension check — block 8**

- **Q8.1** — Why is `-A full` unacceptable on a 1 Gbit/s sensor, and what specific resource does it exhaust first?
- **Q8.2** — `unified2` records reference a SID but carry no message text. Which two files must the consumer (`barnyard2`, `u2spewfoo`, a SIEM connector) also read, and what breaks if they are stale?
- **Q8.3** — The `limit 128` option on `unified2` — 128 of what, and what does Snort do when the limit is reached?
- **Q8.4** — Give one advantage and one disadvantage of `-A syslog` versus writing a local file, for a sensor in a hostile network segment.
- **Q8.5** — `snort-stat` produces nothing at all from your alert file. Name the two most likely causes.

---

## Exercise 9 — Inline IPS mode with the NFQ DAQ

**Steps**

1. Make the sensor a router between `scanner` and `target` for this exercise (or run the test on the target host itself, which is simpler and equally instructive):

   ```bash
   sysctl -w net.ipv4.ip_forward=1
   ```

2. Add a `drop` rule. In Snort 3, `drop` requires inline mode; in passive mode it is silently downgraded to `alert`:

   ```bash
   cat >>/usr/local/etc/snort/rules/local.rules <<'EOF'
   drop tcp any any -> any 80 ( msg:"LOCAL BLOCK path traversal";
        flow:to_server,established;
        http_uri; content:"../", nocase;
        sid:1000010; rev:1; )
   EOF
   ```

3. Queue the traffic to userspace with netfilter:

   ```bash
   iptables -I FORWARD -p tcp --dport 80 -j NFQUEUE --queue-num 4 --queue-bypass
   iptables -L FORWARD -n -v --line-numbers | head
   ```

4. Run Snort inline:

   ```bash
   /usr/local/bin/snort -c /usr/local/etc/snort/snort.lua \
     -Q --daq nfq --daq-var queue=4 --daq-var device=4 \
     -R /usr/local/etc/snort/rules/local.rules \
     -A alert_fast -l /var/log/snort --warn-all
   ```

   Expected (abridged):

   ```
   --------------------------------------------------
   Commencing packet processing
   ++ [0] nfq
   ```

5. Test from `scanner` and observe that the request is *dropped*, not merely logged:

   ```bash
   curl -m 5 -s -o /dev/null -w '%{http_code}\n' 'http://192.168.56.20/?f=../../etc/passwd'
   ```

   Expected: `000` (timeout — no response), and on the sensor:

   ```
   08/25-16:02:44.881120 [Drop] [**] [1:1000010:1] LOCAL BLOCK path traversal [**] [Priority: 1] {TCP} 192.168.56.30:44120 -> 192.168.56.20:80
   ```

6. Read the inline statistics on exit:

   ```
   ===============================================================================
   Action Stats:
        Alerts:            1 (  0.052%)
         Total:            1
        Logged:            1 (  0.052%)
        Passed:            0 (  0.000%)
   Limits:
         match:            0
         queue:            0
   ===============================================================================
   ```

7. Now understand the failure mode you just created. Kill Snort while `--queue-bypass` is set, then remove it and repeat:

   ```bash
   # With --queue-bypass: traffic flows when no userspace program is attached (fail-open)
   iptables -R FORWARD 1 -p tcp --dport 80 -j NFQUEUE --queue-num 4
   # Without it: killing snort blackholes all port-80 traffic (fail-closed)
   ```

8. Clean up:

   ```bash
   iptables -D FORWARD -p tcp --dport 80 -j NFQUEUE --queue-num 4 2>/dev/null
   iptables -D FORWARD -p tcp --dport 80 -j NFQUEUE --queue-num 4 --queue-bypass 2>/dev/null
   sysctl -w net.ipv4.ip_forward=0
   ```

**Comprehension check — block 9**

- **Q9.1** — State the difference between IDS and IPS in terms of *packet path*, not intent, and explain why a SPAN-port sensor can never do the latter.
- **Q9.2** — `--queue-bypass` — describe the security trade-off in one sentence each direction, and say which you would choose for (a) a payment-card segment, (b) a hospital clinical network.
- **Q9.3** — Your inline sensor adds 4 ms of latency. Name two configuration levers in Snort 3 that reduce it and the detection you sacrifice with each.
- **Q9.4** — In passive mode you write `drop tcp …`. What actually happens, and how do you make Snort tell you rather than guess?
- **Q9.5** — Why does an IPS make the *TCP reassembly* configuration a stability risk rather than just a detection-quality question?

---

## Exercise 10 — OpenVAS / GVM: installation, architecture and feeds

**Steps**

1. On `scanner` (Kali), install the Greenbone Vulnerability Management stack:

   ```bash
   apt-get update && apt-get -y install gvm gvm-tools
   ```

2. Run the setup. This creates the PostgreSQL database, generates certificates, creates the `admin` user and performs the first full feed synchronisation — budget 30–90 minutes and several GB of disk:

   ```bash
   gvm-setup 2>&1 | tee /root/gvm-setup.log
   ```

   Expected (abridged, at the end):

   ```
   [+] GVM feeds updated
   [*] Checking Default scanner
   [*] Please note the password for the admin user
   [*] User created with password 'b3f0e2c1-9a2d-4f7b-8c1e-6a9d0e2b4c11'.
   ```

   Record that password.

3. Verify the installation with the tool the objective names:

   ```bash
   gvm-check-setup
   ```

   Expected (abridged):

   ```
   gvm-check-setup 24.5.0
     Test completeness and readiness of GVM-24.5.0
   Step 1: Checking OpenVAS (Scanner) ...
           OK: OpenVAS Scanner is present in version 23.0.1.
           OK: Notus Scanner is present in version 22.6.2.
           OK: Server CA Certificate is present as /var/lib/gvm/CA/servercert.pem.
           OK: NVT collection in /var/lib/openvas/plugins contains 92311 NVTs.
   Step 2: Checking GVMD Manager ...
           OK: gvmd is present in version 23.5.2.
   Step 3: Checking Certificates ...
   Step 4: Checking data ...
           OK: SCAP data found in /var/lib/gvm/scap-data.
           OK: CERT data found in /var/lib/gvm/cert-data.
   Step 5: Checking Postgresql DB and user ...
   Step 6: Checking GSA (Greenbone Security Assistant) ...
   Step 7: Checking if GVM services are up and running ...
           OK: ospd-openvas service is active.
           OK: gvmd    service is active.
           OK: gsad    service is active.
   It seems like your GVM-24.5.0 installation is OK.
   ```

4. Start the stack and map the process architecture to what you just read:

   ```bash
   gvm-start
   systemctl --no-pager status gvmd ospd-openvas gsad notus-scanner 2>&1 | grep -E 'Active:|●'
   ss -lntp | grep -E '9392|5432'
   ss -lxp | grep -E 'gvmd|ospd'
   ```

   Expected (abridged):

   ```
   LISTEN 0 128 127.0.0.1:9392 0.0.0.0:* users:(("gsad",pid=5120,fd=8))
   u_str LISTEN 0 128 /run/gvmd/gvmd.sock 39211 users:(("gvmd",pid=5033,fd=6))
   u_str LISTEN 0 128 /run/ospd/ospd-openvas.sock 39044 users:(("ospd-openvas",pid=4988,fd=5))
   ```

   | Component | Role | Speaks |
   |---|---|---|
   | `gsad` | Greenbone Security Assistant — the web UI (HTTPS :9392) | GMP over the gvmd socket |
   | `gvmd` | Manager: users, targets, tasks, scan configs, reports, SCAP/CERT data in PostgreSQL | **GMP** (Greenbone Management Protocol) |
   | `ospd-openvas` | OSP wrapper that launches and supervises `openvas` scan processes | **OSP** to gvmd, Redis to the scanner |
   | `openvas` | The scanner engine: executes NVTs (NASL scripts) against targets | — |
   | `notus-scanner` | Package-version-based vulnerability matching (fast, no probing) | MQTT via `mosquitto` |
   | `redis-server@openvas` | Per-host knowledge base shared between scanner processes | — |

5. Synchronise the feeds explicitly and understand the three separate feeds:

   ```bash
   runuser -u _gvm -- greenbone-feed-sync --type nvt
   runuser -u _gvm -- greenbone-feed-sync --type scap
   runuser -u _gvm -- greenbone-feed-sync --type cert
   runuser -u _gvm -- greenbone-feed-sync --type gvmd-data
   ```

   | Feed | Content | Legacy command |
   |---|---|---|
   | `nvt` | NASL vulnerability tests → `/var/lib/openvas/plugins/` | `greenbone-nvt-sync`, formerly `openvas-nvt-sync` |
   | `scap` | CPE / CVE / OVAL data → `/var/lib/gvm/scap-data/` | `greenbone-scapdata-sync` |
   | `cert` | CERT-Bund / DFN-CERT advisories → `/var/lib/gvm/cert-data/` | `greenbone-certdata-sync` |
   | `gvmd-data` | Scan configs, port lists, report formats, compliance policies | `greenbone-gvmd-data-sync` |

6. Confirm the feed status through the manager rather than the filesystem:

   ```bash
   export GVM_USER=admin GVM_PASS='<password-from-step-2>'
   gvm-cli --gmp-username "$GVM_USER" --gmp-password "$GVM_PASS" \
     socket --socketpath /run/gvmd/gvmd.sock --xml "<get_feeds/>" | xmllint --format - | head -30
   ```

   Expected (abridged):

   ```xml
   <get_feeds_response status="200" status_text="OK">
     <feed><type>NVT</type><name>Greenbone Community Feed</name>
       <version>202608250541</version><currently_syncing/></feed>
     <feed><type>SCAP</type><version>202608241030</version></feed>
     <feed><type>CERT</type><version>202608241030</version></feed>
   </get_feeds_response>
   ```

7. Manage users. `openvas-adduser` / `openvas-rmuser` are long gone; `gvmd` owns identity now:

   ```bash
   runuser -u _gvm -- gvmd --get-users --verbose
   runuser -u _gvm -- gvmd --create-user=analyst --password='S0me-Str0ng-Pass!'
   runuser -u _gvm -- gvmd --user=admin --new-password='An0ther-Str0ng-Pass!'
   runuser -u _gvm -- gvmd --get-roles
   runuser -u _gvm -- gvmd --delete-user=analyst --inheritor=admin
   ```

8. Expose the UI on the lab network only, and note what you are accepting by doing so:

   ```bash
   sed -n '/ExecStart/p' /usr/lib/systemd/system/gsad.service
   # --listen 127.0.0.1 by default; change deliberately, behind a reverse proxy in production
   ```

**Comprehension check — block 10**

- **Q10.1** — Trace a single scan request from the browser to the packet on the wire, naming every daemon and every protocol it crosses.
- **Q10.2** — Why does `notus-scanner` exist when `openvas` can already detect vulnerable versions? What must be true of the scan for Notus to contribute anything?
- **Q10.3** — What is Redis used for here, and what happens to a running scan if `redis-server@openvas` is restarted?
- **Q10.4** — Your `gvm-check-setup` reports `NVT collection … contains 0 NVTs` immediately after a successful `greenbone-feed-sync --type nvt`. Give two likely causes.
- **Q10.5** — Distinguish the **SCAP** feed from the **NVT** feed. Which one lets GVM tell you a CVE's CVSS score, and which one lets it tell you the host is affected?
- **Q10.6** — Why does `gvmd --delete-user` want an `--inheritor`?

---

## Exercise 11 — Driving GVM from the CLI: the full GMP scan lifecycle

The web UI is not scriptable, auditable or reproducible. Everything below is GMP XML over the `gvmd` UNIX socket.

**Steps**

1. Set up a reusable invocation and verify authentication:

   ```bash
   apt-get -y install xmlstarlet
   GMP='gvm-cli --gmp-username admin --gmp-password '"$GVM_PASS"' socket --socketpath /run/gvmd/gvmd.sock --xml'
   $GMP "<get_version/>"
   ```

   Expected:

   ```xml
   <get_version_response status="200" status_text="OK"><version>22.5</version></get_version_response>
   ```

2. Discover the object IDs you need — always query, never hard-code UUIDs from a blog post:

   ```bash
   $GMP "<get_port_lists/>"  | xmlstarlet sel -t -m '//port_list'  -v 'name' -o '  ' -v '@id' -n
   $GMP "<get_configs/>"     | xmlstarlet sel -t -m '//config'     -v 'name' -o '  ' -v '@id' -n
   $GMP "<get_scanners/>"    | xmlstarlet sel -t -m '//scanner'    -v 'name' -o '  ' -v '@id' -n
   $GMP "<get_report_formats/>" | xmlstarlet sel -t -m '//report_format' -v 'name' -o '  ' -v '@id' -n
   ```

   Expected (abridged):

   ```
   All IANA assigned TCP                33d0cd82-57c6-11e1-8ed1-406186ea4fc5
   All IANA assigned TCP and UDP        4a4717fe-57d2-11e1-9a26-406186ea4fc5
   OpenVAS Default                      c7e03b6c-3bbe-11e1-a057-406186ea4fc5
   Full and fast                        daba56c8-73ec-11df-a475-002264764cea
   Base                                 d21f6c81-2b88-4ac1-b7b4-a2a9f2ad4663
   OpenVAS Default                      08b69003-5fc2-4037-a479-93b440211c73
   ```

3. Capture them into shell variables:

   ```bash
   PORTLIST_ID=$($GMP "<get_port_lists/>" | xmlstarlet sel -t -m '//port_list[name="All IANA assigned TCP"]' -v '@id' -n | head -1)
   CONFIG_ID=$($GMP  "<get_configs/>"     | xmlstarlet sel -t -m '//config[name="Full and fast"]'            -v '@id' -n | head -1)
   SCANNER_ID=$($GMP "<get_scanners/>"    | xmlstarlet sel -t -m '//scanner[name="OpenVAS Default"]'         -v '@id' -n | head -1)
   printf 'portlist=%s\nconfig=%s\nscanner=%s\n' "$PORTLIST_ID" "$CONFIG_ID" "$SCANNER_ID"
   ```

4. Create the target:

   ```bash
   TARGET_ID=$($GMP "<create_target>
       <name>lab-target-56.20</name>
       <hosts>192.168.56.20</hosts>
       <port_list id=\"$PORTLIST_ID\"/>
       <alive_tests>ICMP, TCP-ACK Service &amp; ARP Ping</alive_tests>
     </create_target>" | xmlstarlet sel -t -v '//create_target_response/@id')
   echo "$TARGET_ID"
   ```

5. Create and start the task, capturing the report ID it returns:

   ```bash
   TASK_ID=$($GMP "<create_task>
       <name>lab-scan-56.20</name>
       <config  id=\"$CONFIG_ID\"/>
       <target  id=\"$TARGET_ID\"/>
       <scanner id=\"$SCANNER_ID\"/>
     </create_task>" | xmlstarlet sel -t -v '//create_task_response/@id')

   REPORT_ID=$($GMP "<start_task task_id=\"$TASK_ID\"/>" \
       | xmlstarlet sel -t -v '//start_task_response/report_id')
   echo "task=$TASK_ID report=$REPORT_ID"
   ```

6. Poll to completion — the scan will take 10–40 minutes:

   ```bash
   while :; do
     read -r status progress < <($GMP "<get_tasks task_id=\"$TASK_ID\"/>" \
       | xmlstarlet sel -t -v '//task/status' -o ' ' -v '//task/progress' -n)
     printf '\r%-12s %3s%%' "$status" "$progress"
     [ "$status" = "Done" ] && { echo; break; }
     [ "$status" = "Stopped" ] && { echo " — scan stopped"; break; }
     sleep 20
   done
   ```

   Expected:

   ```
   Requested      0%
   Running       47%
   Done         100%
   ```

7. Extract the results — first as a summary, then in full:

   ```bash
   $GMP "<get_reports report_id=\"$REPORT_ID\" details=\"0\"/>" \
     | xmlstarlet sel -t -m '//report/result_count' \
         -o 'total='   -v 'full' -o ' hole='  -v 'hole' \
         -o ' warning=' -v 'warning' -o ' info=' -v 'info' -n

   $GMP "<get_results filter=\"task_id=$TASK_ID rows=100 sort-reverse=severity\"/>" \
     | xmlstarlet sel -t -m '//result' \
         -v 'severity' -o '  ' -v 'host' -o ':' -v 'port' -o '  ' -v 'name' -n \
     | head -20
   ```

   Expected (abridged):

   ```
   10.0  192.168.56.20:21/tcp   vsftpd Compromised Source Packages Backdoor Vulnerability
   7.5   192.168.56.20:80/tcp   nginx Multiple Vulnerabilities
   5.0   192.168.56.20:22/tcp   Weak Key Exchange (KEX) Algorithm(s) Supported (SSH)
   0.0   192.168.56.20:general  Traceroute
   ```

8. Export a report in a portable format, using an ID you queried rather than guessed:

   ```bash
   FMT_ID=$($GMP "<get_report_formats/>" \
     | xmlstarlet sel -t -m '//report_format[name="CSV Results"]' -v '@id' -n | head -1)
   $GMP "<get_reports report_id=\"$REPORT_ID\" format_id=\"$FMT_ID\" details=\"1\"/>" \
     | xmlstarlet sel -t -v '//report/text' | base64 -d > /root/lab-report.csv
   head -3 /root/lab-report.csv
   ```

9. Create a credentialed (authenticated) target and observe the difference in result count:

   ```bash
   CRED_ID=$($GMP "<create_credential>
       <name>lab-ssh</name><type>usk</type>
       <login>scanuser</login>
       <key><private>$(sed 's/$/\\n/' /root/.ssh/id_ed25519 | tr -d '\n')</private></key>
     </create_credential>" | xmlstarlet sel -t -v '//create_credential_response/@id')
   # then reference it with <ssh_credential id="..."  port="22"/> inside <create_target>
   ```

**Comprehension check — block 11**

- **Q11.1** — Why does `<start_task>` return a `report_id` rather than results? What does that tell you about the GMP execution model?
- **Q11.2** — A credentialed scan of the same host returns 6× as many findings as the unauthenticated one. Explain the mechanism, and name the corresponding increase in risk you have accepted.
- **Q11.3** — What is **QoD** (Quality of Detection), what is the default filter threshold, and why does raising it to 100 hide real vulnerabilities?
- **Q11.4** — Compare `Full and fast` with `Full and very deep ultimate`. Name the specific NVT property that differs and the operational danger of the latter.
- **Q11.5** — Why is hard-coding `daba56c8-73ec-11df-a475-002264764cea` in a production automation script a defect, even though the UUID is stable across most installations?
- **Q11.6** — `<alive_tests>` is set to `ICMP, TCP-ACK Service & ARP Ping`. What happens to your scan if the target segment drops ICMP and you leave the default, and how do you prove that is what happened?

---

## Exercise 12 — NASL: reading, linting, writing and deploying a custom NVT

**Steps**

1. Find the scanner's NASL interpreter and the plugin tree:

   ```bash
   which openvas-nasl openvas-nasl-lint 2>/dev/null
   ls /var/lib/openvas/plugins | head
   ls /var/lib/openvas/plugins/*.inc | head
   ```

2. Read a real NVT and identify the two-phase structure that every NASL script has:

   ```bash
   grep -l 'ACT_GATHER_INFO' /var/lib/openvas/plugins/gb_*.nasl | head -1 | xargs sed -n '1,60p'
   ```

   Every NVT is executed twice: once with the `description` variable set (to register metadata — this is what feed indexing reads), and once for real.

3. Run an existing NVT in description mode only, to see the registration output:

   ```bash
   openvas-nasl -X -B -i /var/lib/openvas/plugins \
     /var/lib/openvas/plugins/gb_nginx_detect.nasl 2>&1 | head -20
   ```

4. Write your own NVT:

   ```bash
   mkdir -p /root/lab-nvt
   cat >/root/lab-nvt/lab_banner_check.nasl <<'EOF'
   # Lab NVT: flag any HTTP server that advertises its exact version in the
   # Server: header. Original work for LPIC-3 303 exercise 334.2.

   if (description)
   {
     script_oid("1.3.6.1.4.1.25623.1.0.999001");
     script_version("2026-08-25T00:00:00+0000");
     script_tag(name:"creation_date",     value:"2026-08-25 00:00:00 +0000 (Tue, 25 Aug 2026)");
     script_tag(name:"last_modification", value:"2026-08-25 00:00:00 +0000 (Tue, 25 Aug 2026)");
     script_name("Lab: HTTP Server Header Discloses Exact Version");
     script_category(ACT_GATHER_INFO);
     script_family("General");
     script_copyright("Copyright (C) 2026 Lab 303 - original work");
     script_dependencies("find_service.nasl", "http_version.nasl");
     script_require_ports("Services/www", 80);

     script_tag(name:"summary",  value:"The remote HTTP server discloses its exact
   product version in the Server response header.");
     script_tag(name:"solution", value:"Suppress or genericise the Server header
   (nginx: server_tokens off; Apache: ServerTokens Prod).");
     script_tag(name:"solution_type", value:"Mitigation");
     script_tag(name:"qod_type", value:"remote_banner");
     script_tag(name:"cvss_base", value:"2.6");
     script_tag(name:"severity_vector",
       value:"CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:L/I:N/A:N");

     exit(0);
   }

   include("http_func.inc");
   include("http_keepalive.inc");

   port   = get_http_port(default:80);
   banner = get_http_banner(port:port);

   if (!banner)
     exit(0);

   server = egrep(pattern:"^Server:", string:banner, icase:TRUE);
   if (!server)
     exit(99);

   server = chomp(server);

   # A version is disclosed only if the header contains digits and a dot
   if (eregmatch(pattern:"[0-9]+\.[0-9]+", string:server))
   {
     report = "The remote HTTP server returned the following header:\n\n" + server + "\n";
     log_message(port:port, data:report);
     exit(0);
   }

   exit(99);
   EOF
   ```

5. Lint it before you ever run it against a host:

   ```bash
   openvas-nasl -L /root/lab-nvt/lab_banner_check.nasl
   ```

   Expected on success: no output (or `lint: OK`); a syntax error prints file, line and the offending token.

6. Run it in description mode, then against the live target:

   ```bash
   openvas-nasl -X -B -i /var/lib/openvas/plugins /root/lab-nvt/lab_banner_check.nasl
   openvas-nasl -X -d -i /var/lib/openvas/plugins \
                -t 192.168.56.20 /root/lab-nvt/lab_banner_check.nasl
   ```

   Expected (abridged):

   ```
   ** Lab: HTTP Server Header Discloses Exact Version **
   The remote HTTP server returned the following header:

   Server: nginx/1.22.1
   ```

7. Prove the negative case. On `target`:

   ```bash
   # /etc/nginx/nginx.conf, inside http { }
   server_tokens off;
   ```

   ```bash
   systemctl reload nginx
   curl -sI http://192.168.56.20/ | grep -i '^server'
   ```

   Expected: `Server: nginx` — re-run the NVT and confirm it now exits 99 with no finding.

8. Deploy the NVT into the scanner and rebuild the VT cache:

   ```bash
   install -o _gvm -g _gvm -m 0644 /root/lab-nvt/lab_banner_check.nasl /var/lib/openvas/plugins/
   runuser -u _gvm -- openvas --update-vt-info
   systemctl restart ospd-openvas
   $GMP "<get_nvts nvt_oid='1.3.6.1.4.1.25623.1.0.999001'/>" | xmlstarlet sel -t -v '//nvt/name' -n
   ```

9. **Production caveat — do this before your next feed sync.** The NVT feed is delivered by `rsync` with deletion enabled: a custom script living in `/var/lib/openvas/plugins/` is not in the feed manifest and can be removed by the next `greenbone-feed-sync --type nvt`. Keep the master copy outside the tree and redeploy from a script:

   ```bash
   cat >/usr/local/sbin/deploy-lab-nvts.sh <<'EOF'
   #!/bin/sh
   set -eu
   SRC=/opt/lab-nvts
   DST=/var/lib/openvas/plugins
   for f in "$SRC"/*.nasl; do
       openvas-nasl -L "$f" || { echo "lint failed: $f" >&2; exit 1; }
       install -o _gvm -g _gvm -m 0644 "$f" "$DST/"
   done
   runuser -u _gvm -- openvas --update-vt-info
   EOF
   chmod +x /usr/local/sbin/deploy-lab-nvts.sh
   mkdir -p /opt/lab-nvts && cp /root/lab-nvt/*.nasl /opt/lab-nvts/
   ```

**Comprehension check — block 12**

- **Q12.1** — Explain the `if (description) { … exit(0); }` block. What calls the script with `description` set, and what would happen if you forgot the `exit(0)`?
- **Q12.2** — The script ends with `exit(99)` in one branch and `exit(0)` in another. What is the semantic difference to the scanner?
- **Q12.3** — What does `script_dependencies("find_service.nasl")` guarantee, and what would `get_http_port()` return without it?
- **Q12.4** — Why is `script_oid` required to be in the `1.3.6.1.4.1.25623.1.0.` arc, and what collides if you reuse an existing OID?
- **Q12.5** — Your NVT uses `qod_type: remote_banner`. What QoD percentage does that map to, and why would a `package`-based check score higher?
- **Q12.6** — Name two categories of NASL script (`ACT_*`) that must never run in a `safe_checks` scan, and say why.
- **Q12.7** — What is the specific risk of `-X` (`--no-signature-check`), and when is it nevertheless correct to use it?

---

## Exercise 13 — Closing the loop: watch the scanner from the sensor

A vulnerability scan is, from the wire's point of view, a sustained attack. This exercise proves your NIDS can see your own tooling — and therefore an attacker's.

**Steps**

1. Enable scan detection in Snort 3 (`snort.lua`) and confirm the equivalent Snort 2 preprocessor:

   ```lua
   port_scan =
   {
       protos      = 'all',
       scan_types  = 'all',
       watch_ip    = '192.168.56.0/24',
       tcp_window  = 0,
       tcp_ports   = { scans = 5, rejects = 5, nets = 25, ports = 25 },
   }
   ```

   ```bash
   grep -n 'sfportscan' /etc/snort/snort.conf
   ```

   Expected (Snort 2):

   ```
   preprocessor sfportscan: proto  { all } memcap { 10000000 } sense_level { low }
   ```

2. Start the sensor with alerting to console and JSON simultaneously:

   ```bash
   /usr/local/bin/snort -c /usr/local/etc/snort/snort.lua \
     -R /usr/local/etc/snort/rules/local.rules \
     -i eth1 -A alert_fast -l /var/log/snort --warn-all
   ```

3. From `scanner`, run the GVM task from Exercise 11 again (`<start_task task_id="$TASK_ID"/>`), or, for a quick equivalent:

   ```bash
   nmap -sS -sV -p- --min-rate 2000 192.168.56.20
   ```

4. Observe the sensor. You should see builtin GID 122 (`port_scan`) events plus whatever content rules the scanner's probe payloads trip:

   ```
   08/25-17:12:04.221190 [**] [122:1:1] (portscan) TCP Portscan [**] [Priority: 3] {TCP} 192.168.56.30 -> 192.168.56.20
   08/25-17:12:19.774081 [**] [122:5:1] (portscan) TCP Filtered Portsweep [**] [Priority: 3] {TCP} 192.168.56.30 -> 192.168.56.0
   08/25-17:14:02.008112 [**] [1:1000002:1] LOCAL HTTP path traversal attempt [**] [Priority: 1] {TCP} 192.168.56.30:52288 -> 192.168.56.20:80
   ```

5. Quantify the noise a single scan produces, and hold that number in mind:

   ```bash
   wc -l /var/log/snort/alert_fast.txt
   awk -F'[][]' '{print $4}' /var/log/snort/alert_fast.txt | sort | uniq -c | sort -rn | head
   ```

6. Now do the thing that makes this operationally useful: add an *authorised scanner* suppression so the SOC's queue is not destroyed on the first Tuesday of every month, while keeping the events available for audit:

   ```lua
   suppress = { { gid = 122, track = 'by_src', ip = '192.168.56.30' } }
   ```

   ```bash
   /usr/local/bin/snort -c /usr/local/etc/snort/snort.lua --warn-all -T 2>&1 | tail -3
   ```

7. Re-run step 3 and verify the GID 122 alerts are gone while GID 1 content alerts remain.

**Comprehension check — block 13**

- **Q13.1** — Suppressing all GID 122 events from the scanner's IP is convenient and dangerous. State the danger precisely and propose a control that mitigates it.
- **Q13.2** — Your NIDS saw the nmap SYN scan but produced *zero* alerts during the credentialed portion of the GVM scan. Why, and what class of monitoring covers that gap? (Cross-reference objective 332.2.)
- **Q13.3** — The `port_scan` inspector fires on your backup server every night. Before writing a suppression, what should you verify, and what is the correct order of the three tuning options (suppress / event_filter / rule edit)?
- **Q13.4** — Explain why a NIDS is not a compensating control for an unpatched host, in terms a change-advisory board would accept.

---

## 14. Cleanup

```bash
# sensor
systemctl stop snort snort3 bandwidthd ntopng 2>/dev/null
iptables -F FORWARD
sysctl -w net.ipv4.ip_forward=0
rm -f /var/log/snort/* /tmp/*.pcap

# scanner
gvm-stop
runuser -u _gvm -- gvmd --get-tasks | head    # note IDs before deleting
```

Restore the VM snapshots you took in section 0 if you want a clean slate for the next objective.

---

## Answers

<details>
<summary><strong>Click to reveal all answers (Q1.1 – Q13.4)</strong></summary>

### Block 1 — Sensor preparation

**Q1.1** — Promiscuous mode is a property of the NIC/driver, applied below the IP stack. The card stops discarding frames whose destination MAC is not its own and passes every frame up; `AF_PACKET` sockets (which `libpcap` uses) receive frames at layer 2, before any IP processing. An IP address is only needed for the *IP stack* to accept and originate packets, which a passive sensor deliberately does not do — no address means no routable attack surface on the monitoring interface.

**Q1.2** — GRO (Generic Receive Offload) coalesces the five 1460-byte segments into one large ~7300-byte pseudo-segment before delivery to `AF_PACKET`. Snort therefore sees a packet layout that never existed on the wire. `depth:20` restricts the `content` search to the first 20 bytes *of the packet payload*; if the string "attack" appeared at offset 5 of the third real segment, it is now at offset ~2925 of the coalesced buffer and falls outside `depth`. More generally, offload breaks any offset/depth/distance/within arithmetic and can mask evasion that depends on segmentation.

**Q1.3** — `ip -s link` reports drops at the *driver/ring buffer* layer. Snort's percentage comes from the DAQ, which counts packets the kernel enqueued into the `AF_PACKET` ring but that Snort did not consume in time — a userspace-side loss caused by an undersized ring buffer or a too-slow detection engine. Read `/proc/net/ptype`, the DAQ statistics in Snort's exit summary, or `ethtool -S eth1 | grep -i drop`; for `AF_PACKET` specifically, the `tp_drops` counter that Snort surfaces in its `Packet I/O Totals`. The fix is `--daq-var buffer_size_mb=`, more packet threads (`-z`), or fewer rules.

**Q1.4** — A TAP is passive hardware: it cannot be oversubscribed, it forwards errored/runt/oversized frames the switch ASIC would drop, it does not compete with production forwarding for switch resources, and it cannot be reconfigured by someone who compromises the switch management plane. A SPAN port silently drops frames when the aggregate mirrored bandwidth exceeds the port speed — and it drops them *without telling you*, so your sensor reports "0 drops" while missing traffic.

### Block 2 — Real-time monitoring

**Q2.1** — `iftop` counts bytes it captures via `libpcap` on that interface, so it measures what the sensor *sees* and is subject to capture drops, BPF filters and layer-2 framing choices. `vnstat` reads the kernel's own interface counters (`/sys/class/net/*/statistics/`, ultimately the same counters SNMP exposes), so it is exact and cheap but has no per-flow detail. Quote **`vnstat`** (or SNMP) for capacity planning: it is authoritative for volume. Use `iftop` to attribute that volume to conversations.

**Q2.2** — (a) A flood of small packets — a SYN flood, a port scan, or interactive SSH/telnet sessions. (b) Normal protocol overhead dominating: lots of TCP ACKs, DNS queries, ARP, or keepalives, i.e. a link with many short-lived connections and little payload. `iftop` distinguishes them: a scan/flood shows one source fanning out to many destinations or ports with near-zero return traffic; normal overhead shows balanced bidirectional pairs across many established conversations.

**Q2.3** — `iftop` opens a raw/packet socket to capture frames, which requires `CAP_NET_RAW` (and `CAP_NET_ADMIN` to set promiscuous mode). Least privilege is to grant the capability to the binary rather than the user: `setcap cap_net_raw,cap_net_admin=eip /usr/sbin/iftop`, then restrict execute permission to a dedicated group. This avoids a blanket `sudo` rule that would let the operator use `iftop`'s BPF filter argument as a foothold.

**Q2.4** — It tells you that essentially all traffic on that link is SSH — or, much more likely on a monitoring interface, that what you are graphing is *your own management sessions and the sensor's own traffic*, not the traffic you meant to monitor. It is a finding because it means your tap/SPAN is mirroring the wrong thing (often the sensor's own uplink), so every subsequent detection metric is measuring the monitoring path rather than the production path.

### Block 3 — Historical accounting

**Q3.1** — `bandwidthd` does packet capture and does per-**host/IP** accounting inside a subnet, so it can tell you *which host on the LAN* consumed the bandwidth. Cacti polls **SNMP counters on a device**, so it accounts per-**interface** and can graph anything with an OID (CPU, temperature, disk, error counters) for years with tiny storage — but it cannot break an interface's traffic down by host. Only `bandwidthd` answers "who"; only Cacti answers "what was the 95th percentile on the WAN port last quarter".

**Q3.2** — `COUNTER` assumes monotonically increasing values and computes a per-second rate from the delta. On a reboot the counter resets to 0, producing a *negative* delta; RRDtool's `COUNTER` type interprets a decrease as a wrap of a 32-bit or 64-bit counter and computes an enormous rate, which then exceeds the `max` bound (`U` here means unbounded, so it does not) — with `U` you get a huge spike; with a sane max you get `UNKN` (NaN). This is exactly why `DERIVE` + `min:0` (which discards negatives as unknown) is preferred for counters that can legitimately reset.

**Q3.3** — A 32-bit `ifInOctets` counter wraps after 4,294,967,296 bytes — about **34 seconds** at 1 Gbit/s. With a 300-second poll interval the counter may wrap multiple times between polls, so RRDtool's wrap correction computes a wrong (usually far too small, occasionally absurd) rate. The fix is to poll the 64-bit High Capacity counters `ifHCInOctets`/`ifHCOutOctets` from `IF-MIB`, which requires SNMPv2c or v3 — 64-bit counters do not exist in SNMPv1.

**Q3.4** — The yearly view is served by an RRA with a high consolidation factor (`RRA:AVERAGE:0.5:288:797` consolidates 288 primary data points — one day — into one row, using the AVERAGE consolidation function). A 30-second burst is already averaged away inside the 300-second step, and then averaged again across a whole day, so it disappears entirely. The `MAX` RRA keeps the largest primary data point in each consolidation interval instead of the mean, so the burst survives as a visible peak — at the cost of telling you nothing about duration.

**Q3.5** — The community string is sent in cleartext in every SNMPv1/v2c packet, so anyone who can capture one packet has it; the source-IP restriction is only as strong as your anti-spoofing, and UDP is trivially spoofed for a write operation. SNMPv3 adds a real user model with HMAC authentication (`authPriv` with SHA) and payload encryption (AES), plus replay protection via engine boots/time — so the credential is never on the wire and the request is integrity-protected.

### Block 4 — Snort 2.9 basics

**Q4.1** — Detection effect: rules written as `$EXTERNAL_NET any -> $HOME_NET …` will now also match *internal-to-internal* traffic, which surfaces lateral movement you would otherwise miss — but also generates large volumes of false positives from normal internal service traffic. Performance effect: `EXTERNAL_NET any` removes an early, extremely cheap IP-based rejection, so far more packets reach expensive content matching; on a busy internal segment this can double or triple CPU. The usual production answer is to keep `!$HOME_NET` for the imported ruleset and write a small, targeted set of internal-to-internal rules separately.

**Q4.2** — Three classes `-T` cannot catch: (1) **runtime permissions/environment** — the unit runs as an unprivileged user that cannot open the interface, write `/var/log/snort`, or bind the PID file; (2) **interface state at start time** — `eth1` does not exist yet, is down, or the systemd unit races the network target; (3) **resource limits** — the config validates but the process is OOM-killed or hits an `ulimit`/`memcap` under real load, and unit-level options (`-D`, `-u`, `-g`, `--daq`, PID paths) supplied by the unit file rather than by your `-T` command line are simply not exercised by the test.

**Q4.3** — `[122:1:0]` is `[GID:SID:REV]` — **generator ID** 122 (the `sfportscan`/`port_scan` preprocessor, not the rules engine), **signature ID** 1, **revision** 0. GID 1 means "the text rules engine"; GIDs above 100 identify preprocessors/inspectors and decoder events, whose rules are compiled in. The revision is 0 because built-in preprocessor events carry no rule text to revise; a rule you write carries `rev:1;` and you increment it every time you change the rule so that downstream systems can tell which version produced an alert.

**Q4.4** — (1) **Timing-dependent detection**: `detection_filter`, `event_filter`, stream timeouts and flow expiry behave differently when a whole capture is replayed in seconds rather than over the real interval — a rate rule that would never fire live can fire on replay, and vice versa. (2) **Inline-only behaviour**: `drop`/`reject` verdicts, packet injection, session blocking, and the latency and queue-depth characteristics of the NFQ/AFPacket inline DAQ simply do not exist in `-r` mode; neither does packet loss, fragmentation reassembly under memory pressure, or asymmetric routing.

**Q4.5** — When a packet is received by the DAQ but excluded from detection before analysis: a BPF filter applied via `-F`/command line (shows as `Filtered`), packets discarded by the decoder as malformed, packets in a flow that has been marked for `stream` "ignore"/whitelist by a preprocessor or a `pass` rule with flow-based fast-path, and — in inline mode — packets whitelisted by the DAQ. Also, packets still queued at exit appear as `Outstanding`.

### Block 5 — Rules

**Q5.1** — `content:"GET"; http_method;` restricts the search to the **HTTP method buffer** that `http_inspect` has already extracted and normalised. The detection engine matches three bytes against a tiny, already-parsed buffer, and the rule is only evaluated at all for packets `http_inspect` has identified as HTTP requests. `content:"GET /"; depth:5;` searches the **raw packet payload** of every TCP packet on those ports, participates in fast-pattern selection as a raw pattern, and will also match "GET /" appearing inside a POST body, a file transfer, or an HTTP response — so it is both slower and less accurate.

**Q5.2** — `detection_filter` is a **pre-detection** gate: the rule only *generates an event* after the threshold is reached, and it is evaluated as part of rule matching, so the first N-1 matches produce no event at all. `event_filter type limit` is **post-detection**: the rule matched every time, the event was generated, and the filter decides how many of those events get *logged*. The distinction matters for anything downstream that counts matches (and for `flowbits`, which are still set by a rule whose event a filter suppressed).

**Q5.3** — Without `flowbits:noalert`, rule 1000004 fires an alert on **every** FTP `USER` command, i.e. on every normal login — turning a stateful precondition into a permanent false positive generator. Without `flowbits:set,lab.ftp_user`, the second rule's `flowbits:isset,lab.ftp_user` never becomes true, so the `SITE EXEC` rule never fires — you have silently disabled the detection you actually care about.

**Q5.4** — Snort refuses to load duplicate SIDs within the same GID and aborts configuration parsing with an error like `Duplicate rule SID 1000002` — the sensor does not start, which is a failure you notice, but in a large managed ruleset it is a needless outage. Local rules must use SIDs **≥ 1,000,000**; 100–999,999 are reserved for the distributed/vendor rulesets, and 1–99 for reserved/legacy use.

**Q5.5** — Snort 2: `content:"admin"; http_server_body;` — the `http_server_body` modifier restricts the preceding `content` to the normalised response body buffer extracted by `http_inspect`. Snort 3: the sticky buffer form, `http_server_body; content:"admin";` — the buffer selector precedes the content options it governs, and remains in effect for all subsequent content options until another buffer is selected.

**Q5.6** — Accuracy: it restricts matching to packets travelling client→server within a TCP session the `stream` preprocessor has seen fully established (three-way handshake completed), which eliminates matches on stray/spoofed packets, on the server's response echoing the attack string, and on scanner probes that never complete a handshake. CPU: flow state is checked very early and very cheaply, so the vast majority of packets are rejected before any pattern matching, and the rule is excluded from the fast-pattern group evaluated for server→client traffic.

### Block 6 — Snort 3

**Q6.1** — The DAQ (Data AcQuisition) layer abstracts packet capture *and* packet verdicts behind one API, so the same Snort binary can run passively over `libpcap`, at high speed over `AF_PACKET` with kernel fanout, inline over netfilter, or on a hardware-accelerated card — without recompiling the detection engine, and with a uniform way to return `pass`/`block`/`replace` verdicts, which raw `libpcap` cannot express at all. Two modules: **`afpacket`** — high-performance passive or inline-on-a-pair-of-interfaces deployment; **`nfq`** — true inline IPS behind an `iptables`/`nftables` NFQUEUE target on a Linux forwarding path.

**Q6.2** — With `afpacket` fanout, the kernel applies a *hash over the flow tuple* to choose which ring (and therefore which Snort packet thread) each packet is delivered to. Every packet of a given TCP connection — in both directions, when a symmetric hash is used — lands on the same thread, so that thread holds the complete stream and can reassemble it. Four independent processes each opening their own capture would each receive a *copy of every packet*, quadrupling the work, or (with independent fanout groups) would split flows arbitrarily so that no single instance ever holds a complete stream — destroying reassembly, `flowbits` state and rate tracking.

**Q6.3** — Snort 3: `http_client_body; content:"admin", nocase;`. The order changed because Snort 3 replaced trailing *content modifiers* with leading **sticky buffers**: the buffer name is an option that sets the current inspection buffer, and every following `content`/`pcre`/`byte_test` applies to that buffer until a different one is selected. This makes the rule read in evaluation order and removes the Snort 2 ambiguity where a modifier appeared to attach to the wrong `content`.

**Q6.4** — `-k none` disables checksum verification for all protocols. Omitting it makes Snort *drop from analysis* any packet whose IP/TCP/UDP checksum is invalid — and checksums are routinely invalid in two normal situations: when the capture is taken on a host with **checksum offload** (the NIC computes the checksum after the tap point, so captured outbound packets carry a placeholder), and when reading a pcap that was rewritten or anonymised. The result is a rule that never fires on your own outbound traffic while looking perfectly correct.

**Q6.5** — They are **built-in rules** emitted by the codecs, the `stream` module and the inspectors (`port_scan` = GID 122, decoder events = GID 116, `http_inspect` = GID 119/120, etc.). They are compiled into the corresponding C++ plugin rather than parsed from rule text, so there is no rule body to edit; you control them through the module's Lua configuration (`enable_builtin_rules`, per-inspector alert options) and through `suppress`/`event_filter`, not by rewriting the rule. `--dump-builtin-rules` exists so you can generate stub rule text for SID-to-message mapping and for selectively enabling them in `ips.states`.

### Block 7 — Rule management

**Q7.1** — `disablesid` is *declarative and idempotent*: it lives in configuration under version control, it is reapplied automatically after every update, it documents the decision (with a comment) in one auditable place, and it survives the vendor re-adding or renumbering the rule. Deleting the line is a manual edit to generated content — it is silently undone by the next update, invisible to anyone reviewing configuration, and leaves no record of who disabled what or why. The same argument applies to `enablesid` and `modifysid`.

**Q7.2** — An IPS policy is a vendor-curated selection of which rules are enabled, ordered by aggressiveness: `connectivity` (only very high-confidence, low-impact rules — never break traffic), `balanced` (the default trade-off), `security` (stricter, accepts more false positives), `max-detect` (research/lab; enables nearly everything). Moving `balanced` → `security` enables several thousand additional rules: false positives rise materially, and CPU rises both from the extra rules and from the larger fast-pattern matcher state — on a saturated sensor this converts into packet drops, which *reduces* real detection. Change it, then measure drop rate and alert volume before and after.

**Q7.3** — It prevents a broken or truncated rule download from being loaded into the running sensor. If `pulledpork.py` fails (network error, expired oinkcode, corrupt archive) the `snort -T` never runs; if `snort -T` fails (a malformed rule in the new set) the `systemctl reload` never runs, so the sensor keeps its last known-good ruleset and keeps inspecting. Without the chaining you can reload Snort onto an unparseable ruleset and — especially inline — take the sensor, and possibly the traffic path, down at 03:30.

**Q7.4** — SO ("shared object") rules are detection logic distributed as **compiled C shared libraries** rather than rule text, used for detections that the rule language cannot express (complex protocol state machines, custom decoders). They need `sorule_path` because Snort loads them with `dlopen()` from a dedicated directory, and they need a matching `snort_version` because they are built against a specific Snort ABI — a mismatched binary either fails to load or crashes the process. The supply-chain risk is that you are loading opaque native code into the address space of a root-privileged process sitting on the traffic path: you cannot review it, so its integrity rests entirely on the transport (HTTPS + oinkcode) and on trusting the vendor.

**Q7.5** — `oinkmaster`: the missing directive is **`skipfile local.rules`**, which tells `oinkmaster` never to touch that file when synchronising the output directory. PulledPork 3: the missing setting is **`local_rules = /path/to/local.rules`**, which tells PulledPork to read your rules and merge them into the generated output file instead of producing a file that replaces them. In both cases the underlying lesson is the same: the tool owns its output directory, so anything you hand-write must be declared.

### Block 8 — Output and triage

**Q8.1** — `-A full` writes a multi-line, human-formatted alert *including the decoded packet header block* for every event, synchronously, from the packet-processing path. On a busy sensor the first resource exhausted is **disk I/O bandwidth / write latency**: the blocking write stalls the detection thread, the DAQ ring fills, and Snort starts dropping packets — so the more attacks you see, the less you see. Disk space is exhausted shortly afterwards. Use `unified2` (binary, compact, asynchronous consumer) or `alert_fast`/`alert_json` with `limit` set.

**Q8.2** — The consumer must read **`sid-msg.map`** (SID → message text, references and classification) and **`gen-msg.map`** (GID:SID → message for preprocessor/built-in events); `classification.config` supplies the classtype→priority names. If they are stale relative to the running ruleset, new rules render as "Snort Alert [1:2054112:1]" with no description, and — worse — a SID that was reused or renumbered renders with the *wrong* description, so an analyst triages the wrong thing. Regenerating the maps must be part of the same automation step as the rule update.

**Q8.3** — `limit 128` is a size cap in **megabytes** per output file. When the current `snort.u2.<timestamp>` reaches 128 MB, Snort closes it and opens a new file with a fresh timestamp suffix; it does not delete anything and does not stop logging. This exists so that the downstream consumer (`barnyard2` or a SIEM agent) can process and rotate completed files, and so a single file never grows beyond what tooling and filesystems handle comfortably.

**Q8.4** — Advantage: alerts leave the sensor immediately and land on a separate, hardened log host, so an attacker who compromises the sensor cannot retroactively delete the evidence of how they got in — and you get central aggregation and retention for free. Disadvantage: classic syslog over UDP/514 is unauthenticated, unencrypted and lossy — it silently drops messages under load exactly when an incident generates the most alerts, and it advertises to anyone on the path that a sensor exists and what it detected. Mitigate with `rsyslog`/`syslog-ng` over TLS with a disk-assisted queue.

**Q8.5** — (1) **Wrong input format**: `snort-stat` parses syslog-style alert lines, so pointing it at a file produced by `-A fast`, `-A full` or `unified2` yields no parseable records — you must run Snort with `-A syslog` (or feed it the syslog file). (2) **Nothing to read**: no alerts were generated, the file is empty or rotated, or you lack permission to read `/var/log/syslog`; on systems with `systemd-journald` and no `rsyslog`, `/var/log/syslog` may not exist at all and you need `journalctl -t snort | snort-stat`.

### Block 9 — Inline IPS

**Q9.1** — An **IDS** sits *off* the packet path: it receives a copy of traffic (TAP/SPAN) and its verdict has no effect on whether the packet is delivered — by the time it decides, the packet has already arrived. An **IPS** sits *on* the packet path: the packet is held in the forwarding path (NFQUEUE, bridge, hardware) until the engine returns a verdict, so a `drop` prevents delivery. A SPAN-port sensor can never prevent delivery because it only ever holds a copy; the original was forwarded by the switch ASIC at the moment it was mirrored. (TCP resets injected by an IDS are a race, not prevention.)

**Q9.2** — With `--queue-bypass` (**fail-open**): if Snort dies, traffic flows uninspected — you preserve availability and lose security. Without it (**fail-closed**): if Snort dies, all matching traffic is blackholed — you preserve security and lose availability. (a) Payment-card segment: **fail-closed** — a CDE that is forwarding uninspected traffic is out of compliance, and the cost of an outage is lower than the cost of an undetected breach. (b) Hospital clinical network: **fail-open** — a blackholed network can prevent access to patient records or interrupt device telemetry, and patient safety outranks the marginal security benefit; compensate with hard monitoring and alerting on the IPS process itself.

**Q9.3** — (1) Reduce the ruleset — a smaller/lower-tier `ips_policy` or targeted rule states; you sacrifice detection of the removed signatures. (2) Reduce stream reassembly and inspection depth — lower `stream_tcp` reassembly buffers, reduce `http_inspect` normalisation and body depth, or exclude large flows with `stream.ignore`/`pass` rules for known bulk traffic; you sacrifice detection of anything that only appears in reassembled or deep payload. (Adding packet threads with `-z` and increasing the DAQ buffer help throughput and jitter but do not reduce per-packet latency.)

**Q9.4** — In passive mode there is no way to enforce a `drop`, so Snort treats the rule as an alert: the event is generated and logged, and the action shown is `allow`. To make it explicit rather than assumed, run with `--warn-all`, which reports rules whose action cannot be honoured in the current mode, and read the `Action Stats` block on exit — `Blocked`/`Dropped` will be 0 regardless of how many `drop` rules matched. Snort 3 also reports the run mode at startup (`-Q` present or not), which you should assert in your deployment checks.

**Q9.5** — Inline, the engine holds packets while it reassembles, so reassembly memory (`memcap`) and flow-table sizing directly determine buffering and latency, and exhausting them forces a policy choice: either release traffic uninspected (a security failure) or hold/drop it (an availability failure). Under attack — deliberate fragmentation, huge numbers of half-open flows, or asymmetric routing that prevents streams from ever completing — the reassembly subsystem becomes the resource an adversary targets to either blind or brown-out the network. Passively, the same misconfiguration only degrades detection quality.

### Block 10 — GVM architecture

**Q10.1** — Browser → **HTTPS** to **`gsad`** (:9392). `gsad` translates the request into **GMP** XML and writes it over the UNIX socket `/run/gvmd/gvmd.sock` to **`gvmd`**. `gvmd` authenticates the user, persists the target/task/config in **PostgreSQL**, and dispatches the scan over **OSP** on `/run/ospd/ospd-openvas.sock` to **`ospd-openvas`**. `ospd-openvas` writes the scan preferences and the target's knowledge base into **Redis** and forks the **`openvas`** scanner, which executes NASL **NVTs** — those NVTs open real TCP/UDP connections to the target, and *that* is the packet on the wire. Results flow back through Redis → `ospd-openvas` → OSP → `gvmd` → PostgreSQL, and `gsad` renders them. `notus-scanner` receives package lists over **MQTT** (`mosquitto`) and returns matches on the same path.

**Q10.2** — `notus-scanner` performs purely *local* vulnerability matching: given a list of installed packages and versions obtained by an authenticated (credentialed) scan, it compares them against the Notus advisory database and reports every known-vulnerable package — with no network probing at all. It is dramatically faster and more complete than banner-based NVTs, but it contributes **nothing unless the scan is credentialed**, because without SSH/SMB/SNMP credentials there is no package list to compare.

**Q10.3** — Redis is the **knowledge base**: the per-host store where the scanner records everything it learns (open ports, detected services, banners, credentials results, NVT outputs) so that hundreds of concurrently running NASL scripts can share findings — `find_service.nasl` writes `Services/www`, and every dependent NVT reads it. Restarting `redis-server@openvas` destroys that state: running scans lose their knowledge base and fail or produce grossly incomplete results, and `ospd-openvas` typically errors out. Never restart Redis while scans are running.

**Q10.4** — (1) The sync succeeded but the scanner has not been told: the VT metadata cache in Redis was not rebuilt — run `runuser -u _gvm -- openvas --update-vt-info` and restart `ospd-openvas`. (2) **Ownership/permissions**: the sync ran as `root` (or another user) and the files under `/var/lib/openvas/plugins/` are not readable by `_gvm`, so the scanner sees an empty collection. A third common cause is a path mismatch — the sync wrote to a different `plugins_folder` than the one configured in `/etc/openvas/openvas.conf`.

**Q10.5** — The **NVT feed** contains the executable detection logic — NASL scripts that probe a host and decide "this host is affected". The **SCAP feed** contains the reference data — CPE product dictionaries, CVE records with their CVSS vectors and scores, and OVAL definitions. So: SCAP tells you a CVE's **severity and description**; NVTs tell you the **host is affected**. A GVM with a current NVT feed and a stale SCAP feed will detect vulnerabilities but report missing or outdated CVE metadata for them.

**Q10.6** — Every object in `gvmd` (targets, tasks, reports, credentials, filters, schedules) has an owner. Deleting a user without specifying who inherits their objects would either orphan them — making historical reports and running schedules inaccessible and undeletable — or destroy audit evidence. `--inheritor` transfers ownership atomically so that scan history and configuration survive personnel changes, which is exactly what an auditor will ask for.

### Block 11 — GMP scan lifecycle

**Q11.1** — Because GMP is **asynchronous**: `<start_task>` only enqueues the scan and returns immediately with the identifier of the report that *will* be populated. The scan itself runs for minutes to hours in `ospd-openvas`/`openvas`, streaming partial results into that report as it goes. The client is expected to poll `<get_tasks>` for `status`/`progress` (or subscribe to an alert), then fetch `<get_reports>`. This is why every correct automation of GVM has a polling loop and a timeout, and why holding an HTTP request open waiting for results is a design error.

**Q11.2** — With credentials the scanner logs in (SSH/SMB/WMI/SNMP), enumerates installed packages, kernel version, configuration files and registry state, and hands them to package-version matching (Notus and local-security-check NVTs). That converts thousands of "cannot determine remotely" cases into definite findings — it is the difference between guessing from banners and reading the package database. The accepted risk: you have stored **privileged credentials for every scanned host** in the scanner's database, so the scanner is now a crown-jewel target whose compromise yields fleet-wide access; and a misconfigured or hostile scan can lock accounts, exhaust resources, or write to targets. Mitigate with dedicated least-privilege scan accounts, key-based auth, per-segment credentials, and strict access control on the GVM host.

**Q11.3** — **QoD** is the *Quality of Detection*: a 0–100% confidence value attached to each result expressing how reliably the detection method establishes that the vulnerability is actually present (e.g. `exploit` 100%, `package` 97%, `registry` 97%, `remote_banner` 80%, `remote_banner_unreliable` 30%, `general_note` 1%). The default report filter shows results with **QoD ≥ 70%**. Raising it to 100 shows only findings proved by successful exploitation or equivalent — which discards the overwhelming majority of *true* findings, including nearly all credentialed package-based results, and produces a report that looks reassuringly clean while the host is still vulnerable.

**Q11.4** — The differing NVT property is **`ACT_DESTRUCTIVE_ATTACK` / `ACT_DENIAL` / `ACT_KILL_HOST` category scripts and the `safe_checks` preference**. `Full and fast` enables safe checks and relies on version/banner/registry evidence; `Full and very deep ultimate` disables safe checks and enables destructive and denial-of-service tests that actually attempt the exploit. The danger is direct: it can crash services, corrupt data, reboot appliances and take production hosts offline — it belongs only in a lab or a pre-production environment with an explicit, written agreement that outages are acceptable.

**Q11.5** — Because the UUID is *data*, not API. It is populated by the `gvmd-data` feed and can differ between versions, between community and enterprise feeds, after a rename, or if a local administrator has cloned and modified the config; a fresh installation from a different feed generation may not have it at all. The script then either fails with an opaque `Failed to find config` or — worse — silently binds the task to a different config than intended. Querying `<get_configs/>` by name and asserting exactly one match makes the failure loud and the intent explicit.

**Q11.6** — `alive_tests` controls how GVM decides a host is up before scanning it. If the segment drops ICMP and ARP is unavailable (routed segment) while your TCP-ACK probes hit filtered ports, GVM concludes the host is **dead and skips it entirely** — you get a completed task, no errors, and an empty report, which reads exactly like "no vulnerabilities found". Prove it by checking the report's host count and the `Host Start`/`Host End` entries (`<get_reports … details="1"/>` shows zero hosts scanned), by looking for the `Hosts scanned: 0` summary, and by re-running the target with `<alive_tests>Consider Alive</alive_tests>` — if findings appear, alive-test failure was the cause.

### Block 12 — NASL

**Q12.1** — The scanner runs every NASL file **twice**. On the first pass it sets the global `description` variable to TRUE and executes the script purely to harvest metadata — OID, name, category, family, dependencies, required ports, tags — which is what populates the VT cache in Redis and the NVT list in `gvmd`. On the real pass `description` is unset and execution falls through to the detection logic. Omitting the `exit(0)` means the description pass would continue into the detection code and try to probe a host during metadata registration — producing errors during `--update-vt-info` and, in older scanners, unintended network activity at cache-build time.

**Q12.2** — `exit(0)` means the script completed normally and *has reported whatever it found* (any `log_message`/`security_message` calls already made stand). `exit(99)` is the conventional "**not applicable / nothing found**" return: the script determined the condition does not apply to this host and produced no finding. The distinction is used for diagnostics and statistics — it lets you tell "the NVT ran and found nothing" apart from "the NVT ran and found something", and in debug output it makes an unexpectedly silent NVT easy to spot.

**Q12.3** — It guarantees that `find_service.nasl` has already run against this host and has populated the knowledge base entries (`Services/www`, `Services/ftp`, …) that describe which service is on which port, including services on non-standard ports. Without the dependency, `get_http_port(default:80)` has no KB entry to consult and falls back to the supplied default — so the NVT would test port 80 only, and would silently miss an HTTP server on 8080, 8443 or any other port, while also failing to skip hosts where port 80 runs something that is not HTTP.

**Q12.4** — `1.3.6.1.4.1.25623` is Greenbone's **IANA Private Enterprise Number** arc; `1.3.6.1.4.1.25623.1.0.x` is the namespace the scanner and manager use to key NVTs. The OID is the primary key: it is what `gvmd` stores in results, what report filters and overrides reference, and what the VT cache indexes. Reusing an existing OID makes your script collide with a feed NVT — depending on load order one silently replaces the other, results are attributed to the wrong test, and the next feed sync produces inconsistent state. For local work, pick a clearly-out-of-feed sub-range and document it; for anything published, obtain your own PEN arc.

**Q12.5** — `remote_banner` maps to **QoD 80%**. It is below the `package` value (**97%**) because a banner is self-reported, trivially altered (`server_tokens off`, `ServerTokens Prod`, reverse proxies, vendor backports) and frequently misleading — most notably, distributions backport security fixes without changing the advertised version, so a banner-based check reports a vulnerability that has already been patched. A `package`-based check reads the actual installed package version from the host's own package database via authenticated access, which is direct evidence rather than an advertisement.

**Q12.6** — `ACT_DENIAL` (denial-of-service tests), `ACT_KILL_HOST` (tests that crash or reboot the target), and `ACT_DESTRUCTIVE_ATTACK` (tests that modify or destroy data). They must not run under `safe_checks` because they establish the vulnerability by *triggering* it — the proof is an outage or data loss on a system you were asked to assess, not to break. Under `safe_checks` the scanner substitutes version/configuration inference for these tests, trading certainty for safety.

**Q12.7** — NVTs in the official feed are cryptographically signed, and signature checking is what prevents a tampered feed mirror, a compromised rsync path, or a malicious local file from injecting code that the scanner executes with the scanner's privileges against every host in scope. `-X` disables that check entirely. It is nevertheless correct — and necessary — when running a script **you wrote yourself and have not signed**, i.e. exactly the development workflow in this exercise. The rule is: `-X` for your own scripts in a lab; never as a way to silence signature failures on feed content, which should be treated as a security incident.

### Block 13 — Correlation

**Q13.1** — Suppressing GID 122 by source IP means that anyone who can source packets from `192.168.56.30` — by compromising the scanner (a host that by design holds privileged credentials for the whole estate) or by spoofing its address — gets a free, permanently invisible reconnaissance channel through your NIDS. Mitigations, in order of strength: (a) suppress only during the scheduled scan window rather than permanently, driven by the same scheduler that launches the scan; (b) keep the events but route them to a low-priority/audit stream via `event_filter` or a separate logger instead of deleting them; (c) pair the suppression with strong host-based monitoring and integrity checking on the scanner itself (objective 332.2), and with anti-spoofing (uRPF / port security) so the source address cannot be forged.

**Q13.2** — The credentialed portion of the scan runs over **SSH**: the scanner authenticates and then executes local commands (package queries, file reads) inside an encrypted channel. A network IDS sees only a TLS/SSH session — encrypted payload it cannot pattern-match — so no content rule can fire. The gap is covered by **host-based intrusion detection and audit**: a HIDS/file-integrity tool (AIDE, Samhain), the Linux audit subsystem (`auditd`) recording the executions, and authentication logging shipped off-host. This is precisely the complementarity between objectives 332.2 (Host Intrusion Detection) and 334.2 — neither replaces the other.

**Q13.3** — First verify **whether the traffic is legitimate**: identify the process and the business function (a backup agent enumerating many hosts/ports legitimately looks identical to a sweep), confirm the source is what it claims to be, and confirm the behaviour has a change record. Only then tune, and in this order: (1) **`event_filter`/threshold** first — reduce volume while keeping visibility, because it is the least destructive; (2) **`suppress`** scoped as narrowly as possible (specific GID:SID *and* specific source *and*, where supported, specific destination) if the events carry no value at all; (3) **edit or disable the rule** last, and only for a rule that is wrong rather than merely noisy — because that decision affects every host, not just this one. Document each with a reason and a review date.

**Q13.4** — A NIDS detects and reports; it does not remove the vulnerability. Concretely: it is blind to encrypted and to host-local exploitation, it only recognises attack patterns it has signatures for (so a novel or lightly-obfuscated exploit of the same flaw passes), it produces alerts that require a staffed, funded response process to have any effect, and even an inline IPS makes a best-effort blocking decision that a determined attacker can evade — while the unpatched host remains exploitable by anyone who reaches it by any other path (a compromised internal host, a VPN client, a maintenance interface, physical access). A compensating control must reduce the *likelihood or impact* of exploitation to a level comparable with the original control; detection with a mean time to respond measured in hours does not meet that bar for a remotely exploitable flaw. It is a legitimate *interim* risk-reduction measure with a documented expiry date and a patch commitment — not a substitute for the patch.

</details>

---

## Official sources

- **LPI — Exam 303 Objectives (303-300 v3.0.0)**: <https://www.lpi.org/our-certifications/exam-303-objectives/>
- **Snort — official documentation portal**: <https://docs.snort.org/>
- **Snort — rule writing reference**: <https://docs.snort.org/rules/>
- **Snort — downloads and rule sets**: <https://www.snort.org/downloads>
- **Snort 3 source**: <https://github.com/snort3/snort3> · **libdaq**: <https://github.com/snort3/libdaq>
- **PulledPork 3**: <https://github.com/shirkdog/pulledpork3>
- **Oinkmaster**: <http://oinkmaster.sourceforge.net/>
- **Greenbone — community documentation**: <https://greenbone.github.io/docs/>
- **Greenbone — openvas-scanner (NASL engine and documentation)**: <https://github.com/greenbone/openvas-scanner>
- **Greenbone — gvmd (GMP protocol documentation)**: <https://github.com/greenbone/gvmd>
- **Greenbone — gvm-tools / `gvm-cli`**: <https://gvm-tools.readthedocs.io/>
- **Greenbone — feed sync**: <https://github.com/greenbone/greenbone-feed-sync>
- **ntop / ntopng documentation**: <https://www.ntop.org/guides/ntopng/>
- **iftop**: <https://pdw.ex-parrot.com/iftop/>
- **iptraf-ng**: <https://github.com/iptraf-ng/iptraf-ng>
- **bandwidthd**: <https://sourceforge.net/projects/bandwidthd/>
- **Cacti documentation**: <https://docs.cacti.net/>
- **RRDtool documentation**: <https://oss.oetiker.ch/rrdtool/doc/>
- **Net-SNMP (IF-MIB, snmpd)**: <https://www.net-snmp.org/docs/man/>
- **netfilter — NFQUEUE / libnetfilter_queue**: <https://www.netfilter.org/projects/libnetfilter_queue/>