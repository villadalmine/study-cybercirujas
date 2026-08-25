# 334.1 Network Hardening — Guided Exercises

**Certification:** LPIC-3 Security (exam 303-300, v3.0.0) · **Topic weight:** 6.67

These exercises assume you own every host you touch. Port scanning, RA injection and DHCP spoofing against networks you do not administer is, in most jurisdictions, a criminal act. Build the lab below and stay inside it.

## Lab topology

| Role | Hostname | IPv4 | IPv6 | Purpose |
|---|---|---|---|---|
| Workstation / analyst | `lab-ops` | 192.168.56.30 | 2001:db8:cafe:1::30 | nmap, tshark, FreeRADIUS, arpwatch |
| Target / supplicant | `lab-target` | 192.168.56.20 | SLAAC | scanned host, 802.1X client |
| Legitimate router + DHCP | `lab-gw` | 192.168.56.10 | 2001:db8:cafe:1::1 | `radvd`, `kea-dhcp4` / `dhcpd` |
| Rogue node | `lab-rogue` | 192.168.56.66 | link-local only | rogue RA + rogue DHCP source |

All four sit on one isolated L2 segment (a libvirt `isolated` network, a VirtualBox internal network, or a dedicated VLAN with no uplink). Packages used: `nmap ndiff wireshark tshark tcpdump freeradius freeradius-utils wpasupplicant hostapd radvd ndisc6 arpwatch nftables dhcpdump`.

Distribution paths differ and the exam expects the Red Hat layout:

| | Debian/Ubuntu | RHEL/Fedora/openSUSE |
|---|---|---|
| FreeRADIUS config | `/etc/freeradius/3.0/` | `/etc/raddb/` |
| Daemon binary | `freeradius` | `radiusd` |
| Unit | `freeradius.service` | `radiusd.service` |
| Logs / accounting | `/var/log/freeradius/` | `/var/log/radius/` |

Throughout, `/etc/raddb` is used as the canonical path; substitute `/etc/freeradius/3.0` on Debian.

---

## Exercise 1 — Measuring the attack surface with `nmap`

### Steps

1. On `lab-target`, get the *authoritative* local view of what listens, before you scan anything:

   ```bash
   ss -tulpnH | sort -k5
   ```

   ```
   tcp   LISTEN 0      4096       127.0.0.1:631        0.0.0.0:*    users:(("cupsd",pid=612,fd=7))
   tcp   LISTEN 0      511          0.0.0.0:80         0.0.0.0:*    users:(("nginx",pid=901,fd=6))
   tcp   LISTEN 0      128          0.0.0.0:22         0.0.0.0:*    users:(("sshd",pid=744,fd=3))
   udp   UNCONN 0      0            0.0.0.0:68         0.0.0.0:*    users:(("dhclient",pid=690,fd=6))
   ```

2. From `lab-ops`, run an unprivileged TCP connect scan and then the same scan as root:

   ```bash
   nmap -sT --reason -p 22,80,443,631,3306 192.168.56.20
   sudo nmap -sS --reason -p 22,80,443,631,3306 192.168.56.20
   ```

   ```
   PORT     STATE  SERVICE REASON
   22/tcp   open   ssh     syn-ack ttl 64
   80/tcp   open   http    syn-ack ttl 64
   443/tcp  closed https   reset ttl 64
   631/tcp  closed ipp     reset ttl 64
   3306/tcp closed mysql   reset ttl 64
   ```

3. Note that `631` is `closed`, not `filtered`, even though `cupsd` is running. Confirm why:

   ```bash
   ssh lab-target 'ss -tlnp | grep 631'
   ```

4. Add service and OS fingerprinting, and keep the machine-readable artefact:

   ```bash
   sudo nmap -sS -sV -O -T4 --top-ports 1000 --open \
             -oA /var/lib/nmap-drift/baseline 192.168.56.20
   ```

   ```
   PORT   STATE SERVICE VERSION
   22/tcp open  ssh     OpenSSH 9.6p1 Debian 3 (protocol 2.0)
   80/tcp open  http    nginx 1.24.0
   MAC Address: 52:54:00:AA:BB:CC (QEMU virtual NIC)
   Device type: general purpose
   Running: Linux 5.X|6.X
   OS CPE: cpe:/o:linux:linux_kernel:6
   OS details: Linux 6.1 - 6.8
   Network Distance: 1 hop
   ```

   `-oA` writes `baseline.nmap`, `baseline.gnmap` and `baseline.xml`.

5. Discover hosts without touching a single port, then compare against a UDP probe of the classic infrastructure ports:

   ```bash
   sudo nmap -sn 192.168.56.0/24
   sudo nmap -sU -p 53,67,68,123,161,1812,1813 192.168.56.10
   ```

6. Use NSE to turn a "port is open" fact into a hardening finding:

   ```bash
   sudo nmap -sV --script ssl-enum-ciphers -p 443 192.168.56.10
   sudo nmap --script "default and safe" -p 22,80 192.168.56.20
   ```

7. Watch the wire while you scan. In a second terminal on `lab-target`:

   ```bash
   sudo tshark -i enp1s0 -Y 'tcp.flags.syn == 1 && tcp.flags.ack == 0' \
        -T fields -e ip.src -e tcp.dstport -e tcp.window_size
   ```

   Re-run step 2 with `-sS` and then with `-sT`, and compare the window sizes and the presence of a completed handshake.

8. Now install something new on `lab-target` and detect the drift:

   ```bash
   sudo systemctl enable --now mariadb        # simulates an unapproved change
   sudo nmap -sS -sV -O -T4 --top-ports 1000 --open \
             -oX /var/lib/nmap-drift/current.xml 192.168.56.20
   ndiff /var/lib/nmap-drift/baseline.xml /var/lib/nmap-drift/current.xml; echo "exit=$?"
   ```

   ```
   -lab-target (192.168.56.20):
   +lab-target (192.168.56.20):
    Host is up.
    PORT     STATE SERVICE VERSION
   +3306/tcp open  mysql   MariaDB 10.11.6
   exit=1
   ```

### Comprehension questions

**Q1.1** `cupsd` is listening on port 631 but nmap reports `closed`. Why, and what does that tell you about the difference between "a service is running" and "a service is exposed"?

**Q1.2** What distinguishes `closed` from `filtered` in nmap's output, and which one indicates a packet filter is in the path?

**Q1.3** Why does `-sS` require root while `-sT` does not, and what forensic trace does each leave in the target's application logs?

**Q1.4** `ndiff` exited 1. In a monitoring script driven by `set -e`, why is that exit code a trap, and what are `ndiff`'s three exit codes?

**Q1.5** You are asked to prove an internal host has no exposed database. Which is stronger evidence: `ss -tulpn` on the host, or `nmap` from the network? Explain why the answer is "both, for different claims".

---

## Exercise 2 — Shrinking the surface: kernel, unit and filter

### Steps

1. Read the current values of the parameters that decide whether the host trusts the network:

   ```bash
   sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.all.accept_redirects \
          net.ipv4.conf.all.log_martians net.ipv6.conf.all.accept_ra \
          net.ipv6.conf.enp1s0.accept_ra net.ipv6.conf.all.autoconf
   ```

2. Write a persistent policy:

   ```ini
   # /etc/sysctl.d/60-net-hardening.conf
   # --- IPv4 path validation -------------------------------------------------
   net.ipv4.conf.all.rp_filter                = 1
   net.ipv4.conf.default.rp_filter            = 1
   net.ipv4.conf.all.accept_source_route      = 0
   net.ipv4.conf.default.accept_source_route  = 0
   net.ipv4.conf.all.log_martians             = 1
   net.ipv4.conf.default.log_martians         = 1

   # --- ICMP redirects: never accept, never send ----------------------------
   net.ipv4.conf.all.accept_redirects         = 0
   net.ipv4.conf.default.accept_redirects     = 0
   net.ipv4.conf.all.secure_redirects         = 0
   net.ipv4.conf.all.send_redirects           = 0
   net.ipv4.conf.default.send_redirects       = 0

   # --- Amplification and SYN flood -----------------------------------------
   net.ipv4.icmp_echo_ignore_broadcasts       = 1
   net.ipv4.icmp_ignore_bogus_error_responses = 1
   net.ipv4.tcp_syncookies                    = 1

   # --- ARP: answer only for addresses on the receiving interface -----------
   net.ipv4.conf.all.arp_ignore               = 1
   net.ipv4.conf.all.arp_announce             = 2

   # --- IPv6: this host is statically addressed, it learns nothing ----------
   net.ipv6.conf.all.accept_ra                = 0
   net.ipv6.conf.default.accept_ra            = 0
   net.ipv6.conf.all.accept_ra_defrtr         = 0
   net.ipv6.conf.all.accept_ra_pinfo          = 0
   net.ipv6.conf.all.accept_ra_rtr_pref       = 0
   net.ipv6.conf.all.autoconf                 = 0
   net.ipv6.conf.all.router_solicitations     = 0
   net.ipv6.conf.all.accept_redirects         = 0
   net.ipv6.conf.default.accept_redirects     = 0
   ```

   ```bash
   sudo sysctl --system
   sudo sysctl -a --pattern 'ipv6.conf.enp1s0.accept_ra'
   ```

3. Prove the `all` vs `default` vs per-device semantics rather than assuming them:

   ```bash
   sudo ip link add dummy0 type dummy && sudo ip link set dummy0 up
   sysctl net.ipv6.conf.dummy0.accept_ra net.ipv4.conf.dummy0.rp_filter
   sudo sysctl -w net.ipv4.conf.all.rp_filter=0
   sysctl net.ipv4.conf.dummy0.rp_filter          # per-device value unchanged
   ```

4. Check whether your network manager overrides the kernel behind your back:

   ```bash
   nmcli -f ipv6.method,ipv6.addr-gen-mode connection show "System enp1s0"
   grep -rn 'IPv6AcceptRA\|LinkLocalAddressing' /etc/systemd/network/ 2>/dev/null
   ```

5. Confine a single service to the addresses it is allowed to talk to, using the cgroup-v2 BPF filter rather than a global firewall rule:

   ```ini
   # /etc/systemd/system/nginx.service.d/10-net-lockdown.conf
   [Service]
   IPAddressDeny=any
   IPAddressAllow=localhost
   IPAddressAllow=192.168.56.0/24
   RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
   PrivateTmp=yes
   ProtectSystem=strict
   NoNewPrivileges=yes
   ```

   ```bash
   sudo systemctl daemon-reload && sudo systemctl restart nginx
   systemd-analyze security nginx.service | head -20
   ```

6. Lay down the packet filter. This ruleset is the enforcement point for the rogue-RA and rogue-DHCP work in exercises 6 and 7:

   ```nft
   #!/usr/sbin/nft -f
   # /etc/nftables.conf
   flush ruleset

   define TRUSTED_ROUTER_LL = fe80::5054:ff:fe12:3456
   define TRUSTED_DHCP4     = 192.168.56.10

   table inet filter {
       chain input {
           type filter hook input priority filter; policy drop;

           iif lo accept
           ct state established,related accept
           ct state invalid counter drop comment "no state, no entry"

           # Neighbour Discovery is mandatory for IPv6, but RFC 4861 says
           # every ND message must arrive with hop limit 255 and a
           # link-local source. Anything else was routed, so it is forged.
           icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } \
               ip6 hoplimit 255 ip6 saddr fe80::/10 accept
           icmpv6 type { echo-request, echo-reply, destination-unreachable,
                         packet-too-big, time-exceeded, parameter-problem } accept

           # RA guard, host side: only the authorised router may advertise
           icmpv6 type nd-router-advert ip6 hoplimit 255 \
               ip6 saddr $TRUSTED_ROUTER_LL accept
           icmpv6 type nd-router-advert \
               counter log prefix "ROGUE-RA " level warn drop

           # Only the authorised DHCPv4 server may answer a client
           udp sport 67 udp dport 68 ip saddr $TRUSTED_DHCP4 accept
           udp sport 67 udp dport 68 \
               counter log prefix "ROGUE-DHCP " level warn drop

           tcp dport 22 ct state new limit rate 10/minute burst 5 packets accept
           counter comment "input-policy-drop"
       }

       chain forward { type filter hook forward priority filter; policy drop; }
       chain output  { type filter hook output  priority filter; policy accept; }
   }
   ```

   ```bash
   sudo nft -c -f /etc/nftables.conf && sudo systemctl enable --now nftables
   sudo nft list ruleset | grep -A2 ROGUE
   ```

7. Re-scan from `lab-ops` and observe how the report changed:

   ```bash
   sudo nmap -sS -p 22,80,3306 --reason 192.168.56.20
   ```

### Comprehension questions

**Q2.1** For `rp_filter` the kernel uses the *maximum* of `conf.all` and `conf.<dev>`, but for `accept_redirects` it uses the per-device value with `all` acting as a broadcast write. What practical bug does that asymmetry cause when you set values in `/etc/sysctl.d/`?

**Q2.2** Why is `net.ipv6.conf.default.accept_ra = 0` necessary even though you already set `all`?

**Q2.3** `IPAddressDeny=any` silently does nothing on some systems. What is the prerequisite, and how would you verify it is met?

**Q2.4** After step 6, nmap reports port 3306 as `filtered` rather than `closed`. Explain the packet-level reason.

**Q2.5** Why does the ruleset check `ip6 hoplimit 255` on Neighbour Discovery messages? What class of attack does that single match eliminate?

**Q2.6** `rp_filter = 1` breaks a legitimate deployment pattern. Name it, and say what you would use instead.

---

## Exercise 3 — Traffic analysis with `tshark` and Wireshark

### Steps

1. Grant capture rights without running a 3-million-line dissector as root:

   ```bash
   sudo dpkg-reconfigure wireshark-common       # Debian: answer "yes"
   sudo usermod -aG wireshark "$USER"
   getcap /usr/bin/dumpcap
   ```

   ```
   /usr/bin/dumpcap cap_net_admin,cap_net_raw=eip
   ```

   Log out and back in, then confirm:

   ```bash
   tshark -D
   ```

   ```
   1. enp1s0
   2. lo (Loopback)
   3. any
   ```

2. Capture with a **capture filter** (in-kernel BPF) and note the CPU cost against an equivalent **display filter**:

   ```bash
   tshark -i enp1s0 -f 'tcp port 80' -c 20 -w /tmp/http-bpf.pcapng
   tshark -i enp1s0 -Y 'http'        -c 20 -w /tmp/http-dfilter.pcapng
   ```

3. Generate a cleartext credential and prove it is readable:

   ```bash
   curl -u alice:S3cr3tPass http://192.168.56.10/private/ >/dev/null
   tshark -r /tmp/http-bpf.pcapng -Y 'http.authorization' \
          -T fields -e ip.src -e ip.dst -e http.authorization
   ```

   ```
   192.168.56.30   192.168.56.10   Basic YWxpY2U6UzNjcjN0UGFzcw==
   ```

4. Summarise a capture the way you would in an incident report:

   ```bash
   capinfos /tmp/http-bpf.pcapng | head -12
   tshark -r /tmp/http-bpf.pcapng -q -z io,phs
   tshark -r /tmp/http-bpf.pcapng -q -z conv,tcp
   tshark -r /tmp/http-bpf.pcapng -q -z endpoints,ip
   tshark -r /tmp/http-bpf.pcapng -q -z expert
   ```

5. Reassemble one application conversation:

   ```bash
   tshark -r /tmp/http-bpf.pcapng -q -z follow,tcp,ascii,0
   ```

6. Extract fields for a pipeline instead of eyeballing packets:

   ```bash
   tshark -r /tmp/http-bpf.pcapng -T fields \
          -e frame.number -e frame.time_relative -e ip.src -e tcp.dstport -e _ws.col.info \
          -E header=y -E separator=, -E quote=d
   ```

7. Run a bounded, long-lived capture suitable for a production host — a ring buffer with a truncated snaplen so you keep headers, not payloads:

   ```bash
   sudo install -d -m 0750 -o root -g wireshark /var/log/captures
   tshark -i enp1s0 -s 96 -f 'not port 22' \
          -b filesize:65536 -b files:10 \
          -w /var/log/captures/lab.pcapng
   ```

8. Slice and merge afterwards:

   ```bash
   editcap -A '2026-08-25 11:00:00' -B '2026-08-25 11:05:00' \
           /var/log/captures/lab_00001_*.pcapng /tmp/window.pcapng
   mergecap -w /tmp/all.pcapng /var/log/captures/lab_*.pcapng
   ```

### Comprehension questions

**Q3.1** Where does a `-f` capture filter execute, where does a `-Y` display filter execute, and under what condition does the choice decide whether you drop packets?

**Q3.2** `-Y 'http'` and `-f 'tcp port 80'` are not equivalent even on a pure HTTP-on-80 network. Give one packet each capture keeps that the other discards.

**Q3.3** Why is running `wireshark` as root considered a hardening failure, and what is the architectural fix Wireshark ships?

**Q3.4** You set `-s 96`. Which analyses remain possible and which become impossible?

**Q3.5** A ring buffer of `-b filesize:65536 -b files:10` — how much disk does it consume at steady state, and what happens to the oldest data?

**Q3.6** Name the display filter that finds DHCPv4 traffic in Wireshark 3.0 and later, and the name it replaced.

---

## Exercise 4 — FreeRADIUS: authenticating network nodes

### Steps

1. Install and inspect the configuration tree before changing anything:

   ```bash
   sudo dnf install -y freeradius freeradius-utils     # or: apt install freeradius
   ls -1 /etc/raddb/
   ```

   ```
   certs/          dictionary       mods-config/     policy.d/       sites-available/
   clients.conf    mods-available/  panic.gdb        radiusd.conf    sites-enabled/
   ```

   ```bash
   ls -l /etc/raddb/sites-enabled/ /etc/raddb/mods-enabled/ | head
   ```

   Both directories are symlink farms into `*-available/`; enabling a module is `ln -s`.

2. Validate the shipped configuration and confirm the daemon's identity:

   ```bash
   sudo radiusd -Cxl stdout | tail -5
   ```

   ```
   Configuration appears to be OK
   ```

3. Define the NAS clients. Never leave `testing123` reachable from anything but loopback:

   ```conf
   # /etc/raddb/clients.conf
   client localhost {
       ipaddr                        = 127.0.0.1
       proto                         = *
       secret                        = testing123
       require_message_authenticator = no
       nas_type                      = other
       limit {
           max_connections = 16
           lifetime        = 0
           idle_timeout    = 30
       }
   }

   client sw-core-01 {
       ipaddr                        = 192.168.56.10
       secret                        = 'Q7!kp2Vf$Lm9zR4wXe8Tn1Bh'
       shortname                     = sw-core-01
       nas_type                      = other
       require_message_authenticator = yes
   }

   client lab-supplicants {
       ipaddr                        = 192.168.56.0/24
       secret                        = 'aK4#nD8vZq2Ls6Jr9Wt3Cy7M'
       shortname                     = lab-net
       require_message_authenticator = yes
   }
   ```

4. Create the test identities. In FreeRADIUS 3.x the `users` file lives under `mods-config`:

   ```conf
   # /etc/raddb/mods-config/files/authorize
   bob     Cleartext-Password := "hello"
           Reply-Message = "Hello, %{User-Name}",
           Session-Timeout = 3600,
           Idle-Timeout = 600

   # MAC Authentication Bypass for a printer: identity == MAC, put it in the
   # quarantine VLAN and never let it route anywhere interesting.
   "0011223344ab"  Cleartext-Password := "0011223344ab"
           Tunnel-Type = VLAN,
           Tunnel-Medium-Type = IEEE-802,
           Tunnel-Private-Group-Id = "310"

   # Default: reject. An unmatched identity must not fall through to accept.
   DEFAULT Auth-Type := Reject
           Reply-Message = "Access denied by policy"
   ```

5. Stop the service and run the daemon in the foreground in debug mode — this is the single most important FreeRADIUS skill:

   ```bash
   sudo systemctl stop radiusd
   sudo radiusd -X
   ```

   ```
   Listening on auth address * port 1812 bound to server default
   Listening on acct address * port 1813 bound to server default
   Listening on auth address 127.0.0.1 port 18120 bound to server inner-tunnel
   Ready to process requests
   ```

6. From a second terminal, authenticate with PAP:

   ```bash
   radtest bob hello 127.0.0.1 0 testing123
   ```

   ```
   Sent Access-Request Id 215 from 0.0.0.0:39764 to 127.0.0.1:1812 length 74
       User-Name = "bob"
       User-Password = "hello"
       NAS-IP-Address = 127.0.0.1
       NAS-Port = 0
       Message-Authenticator = 0x00
       Cleartext-Password = "hello"
   Received Access-Accept Id 215 from 127.0.0.1:1812 to 127.0.0.1:39764 length 47
       Reply-Message = "Hello, bob"
       Session-Timeout = 3600
       Idle-Timeout = 600
   ```

   In the `radiusd -X` window, read the policy trace: `(0) files: users: Matched entry bob at line 2`, `(0) pap: Login OK`, `(0) Sent Access-Accept Id 215`.

7. Now a rejection, and time it:

   ```bash
   time ( echo "User-Name = bob, User-Password = wrongpass" \
          | radclient -x 127.0.0.1:1812 auth testing123 )
   ```

   ```
   Received Access-Reject Id 42 from 127.0.0.1:1812 to 127.0.0.1:47000 length 20
   real    0m1.012s
   ```

8. Send an arbitrary attribute set — the tool you use when a switch vendor's request needs reproducing:

   ```bash
   cat > /tmp/req.txt <<'EOF'
   User-Name = "0011223344ab"
   User-Password = "0011223344ab"
   NAS-IP-Address = 192.168.56.10
   NAS-Port = 24
   NAS-Port-Type = Ethernet
   Called-Station-Id = "00-1A-2B-3C-4D-5E"
   Calling-Station-Id = "00-11-22-33-44-AB"
   Service-Type = Call-Check
   EOF
   radclient -x -f /tmp/req.txt 127.0.0.1:1812 auth testing123
   ```

   Expect `Tunnel-Private-Group-Id = "310"` in the Access-Accept.

9. Enable accounting to `radutmp` so the session tools work. In `/etc/raddb/sites-enabled/default`, confirm `radutmp` is present in the `accounting {}` section, then:

   ```bash
   printf 'User-Name = bob\nAcct-Status-Type = Start\nAcct-Session-Id = "0001"\nNAS-IP-Address = 192.168.56.10\nNAS-Port = 24\nFramed-IP-Address = 192.168.56.50\n' \
     | radclient -x 127.0.0.1:1813 acct testing123
   radwho
   ```

   ```
   Login      Name              What  TTY  When      From      Location
   bob        bob               shell  s24 Aug 25 11:41  192.168.56.10
   ```

   ```bash
   printf 'User-Name = bob\nAcct-Status-Type = Stop\nAcct-Session-Id = "0001"\nAcct-Session-Time = 300\nNAS-IP-Address = 192.168.56.10\nNAS-Port = 24\n' \
     | radclient -x 127.0.0.1:1813 acct testing123
   radlast
   ```

10. Watch the protocol itself, and see exactly how much the shared secret is protecting:

    ```bash
    sudo tshark -i lo -f 'udp port 1812' -O radius \
                -o 'radius.shared_secret:testing123' -Y 'radius'
    ```

    In the decoded tree, find `User-Password` and the `[Decrypted: hello]` annotation, plus the `Authenticator` and `Message-Authenticator` attributes.

11. Inspect where the accounting evidence actually lands:

    ```bash
    ls -l /var/log/radius/radacct/192.168.56.10/
    sudo tail -20 /var/log/radius/radacct/192.168.56.10/detail-20260825
    ```

### Comprehension questions

**Q4.1** Which UDP ports does modern RADIUS use for authentication and accounting, and which pair did it historically use?

**Q4.2** `radtest` sent `User-Password` in an Access-Request. Explain the mechanism that protects it, and why a weak shared secret makes it worthless.

**Q4.3** Why did the Access-Reject take almost exactly one second? Name the directive.

**Q4.4** Why must `mods-config/files/authorize` store `Cleartext-Password` rather than a hash if you intend to support CHAP or MS-CHAPv2?

**Q4.5** `radwho` printed nothing on your first attempt. Name the two configuration conditions that must hold, and which file each lives in.

**Q4.6** Why is `require_message_authenticator = yes` important for a real NAS, and why is it set to `no` for `localhost` in the shipped config?

**Q4.7** What is the operational difference between `systemctl start radiusd` and `radiusd -X`, and why is the latter the first step in every FreeRADIUS diagnosis?

**Q4.8** The `DEFAULT Auth-Type := Reject` entry is last in the file. What would happen if you placed it first?

---

## Exercise 5 — 802.1X port authentication end to end

### Steps

1. Bootstrap the server certificate chain. The shipped snake-oil CA is for labs only:

   ```bash
   cd /etc/raddb/certs && sudo ./bootstrap
   openssl x509 -in /etc/raddb/certs/server.pem -noout -subject -dates -ext extendedKeyUsage
   ```

2. Configure the EAP module for PEAP/MSCHAPv2 with a sane TLS floor:

   ```conf
   # /etc/raddb/mods-available/eap  (excerpt)
   eap {
       default_eap_type        = peap
       timer_expire            = 60
       ignore_unknown_eap_types = no
       max_sessions            = ${max_requests}

       tls-config tls-common {
           private_key_password    = whatever
           private_key_file        = ${certdir}/server.pem
           certificate_file        = ${certdir}/server.pem
           ca_file                 = ${cadir}/ca.pem
           dh_file                 = ${certdir}/dh
           tls_min_version         = "1.2"
           tls_max_version         = "1.3"
           cipher_list             = "HIGH:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK:!SRP"
           cipher_server_preference = yes
       }

       peap {
           tls                   = tls-common
           default_eap_type      = mschapv2
           copy_request_to_tunnel = no
           use_tunneled_reply    = no
           virtual_server        = "inner-tunnel"
       }

       mschapv2 { }
   }
   ```

   ```bash
   sudo radiusd -Cxl stdout | tail -3
   sudo radiusd -X            # keep this running
   ```

3. Turn `lab-gw` into an 802.1X authenticator with `hostapd` in wired mode:

   ```conf
   # /etc/hostapd/hostapd-wired.conf
   interface=br0
   driver=wired
   ieee8021x=1
   eap_reauth_period=3600
   use_pae_group_addr=1

   auth_server_addr=192.168.56.30
   auth_server_port=1812
   auth_server_shared_secret=aK4#nD8vZq2Ls6Jr9Wt3Cy7M

   acct_server_addr=192.168.56.30
   acct_server_port=1813
   acct_server_shared_secret=aK4#nD8vZq2Ls6Jr9Wt3Cy7M

   nas_identifier=lab-gw
   logger_stdout=-1
   logger_stdout_level=1
   ```

   ```bash
   sudo hostapd -dd /etc/hostapd/hostapd-wired.conf
   ```

4. Configure the supplicant on `lab-target`:

   ```conf
   # /etc/wpa_supplicant/wired.conf
   ctrl_interface=/run/wpa_supplicant
   eapol_version=2
   ap_scan=0
   fast_reauth=1

   network={
       key_mgmt=IEEE8021X
       eap=PEAP
       identity="bob"
       anonymous_identity="anonymous@lab.example"
       password="hello"
       ca_cert="/etc/ssl/certs/lab-ca.pem"
       phase1="peaplabel=0"
       phase2="auth=MSCHAPV2"
   }
   ```

   ```bash
   sudo wpa_supplicant -D wired -i enp1s0 -c /etc/wpa_supplicant/wired.conf -d
   ```

   ```
   enp1s0: CTRL-EVENT-EAP-STARTED EAP authentication started
   enp1s0: CTRL-EVENT-EAP-PROPOSED-METHOD vendor=0 method=25
   EAP: Status notification: remote certificate verification (param=success)
   enp1s0: CTRL-EVENT-EAP-METHOD EAP vendor 0 method 26 (MSCHAPV2) selected
   enp1s0: CTRL-EVENT-EAP-SUCCESS EAP authentication completed successfully
   enp1s0: CTRL-EVENT-CONNECTED - Connection to 01:80:c2:00:00:03 completed
   ```

5. Capture the exchange from both sides and see which parts are and are not encrypted:

   ```bash
   sudo tshark -i enp1s0 -Y 'eapol || eap' \
        -T fields -e frame.number -e eth.src -e eap.code -e eap.type -e eap.identity
   sudo tshark -i enp1s0 -f 'udp port 1812' -Y 'radius' \
        -T fields -e radius.code -e radius.id -e radius.User_Name
   ```

6. Break it on purpose, three ways, and read the `radiusd -X` trace for each:

   ```bash
   # wrong inner password
   sed -i 's/password="hello"/password="nope"/' /etc/wpa_supplicant/wired.conf
   # unknown identity
   sed -i 's/identity="bob"/identity="nobody"/'  /etc/wpa_supplicant/wired.conf
   # wrong shared secret on the authenticator
   sed -i 's/^auth_server_shared_secret=.*/auth_server_shared_secret=WRONG/' \
       /etc/hostapd/hostapd-wired.conf
   ```

   For the third case, note what the server prints:

   ```
   Received packet from 192.168.56.10 with invalid Message-Authenticator!  (Shared secret is incorrect.)
   ```

7. Return VLAN assignment per identity by adding tunnel attributes to `bob` in `mods-config/files/authorize`, then confirm the `Access-Accept` carries them:

   ```conf
   bob     Cleartext-Password := "hello"
           Tunnel-Type = VLAN,
           Tunnel-Medium-Type = IEEE-802,
           Tunnel-Private-Group-Id = "120",
           Reply-Message = "Welcome to VLAN 120"
   ```

### Comprehension questions

**Q5.1** Name the three 802.1X roles and map each to a component in this lab.

**Q5.2** EAPOL frames go to `01:80:c2:00:00:03`. Which protocol family is that, and why is 802.1X not carried over IP between supplicant and authenticator?

**Q5.3** With PEAP, which identity does an on-path attacker see in cleartext, and which one is protected? What is `anonymous_identity` for?

**Q5.4** Omitting `ca_cert` from the supplicant configuration still authenticates successfully. Explain precisely what security property you just discarded.

**Q5.5** `Received packet ... invalid Message-Authenticator` appeared instead of an Access-Reject. Why can the server not simply reply "wrong secret"?

**Q5.6** Which three attributes must an Access-Accept carry to place a port in a VLAN, and what must be true of the switch for them to take effect?

**Q5.7** MAC Authentication Bypass (`Service-Type = Call-Check`) authenticates a device by its MAC address. Why is that not authentication in any meaningful sense, and what compensating controls does it require?

---

## Exercise 6 — Rogue IPv6 Router Advertisements

### Steps

1. On `lab-gw`, run the *legitimate* router:

   ```conf
   # /etc/radvd.conf
   interface enp1s0 {
       AdvSendAdvert on;
       MinRtrAdvInterval 30;
       MaxRtrAdvInterval 100;
       AdvDefaultPreference high;
       AdvManagedFlag off;
       AdvOtherConfigFlag on;

       prefix 2001:db8:cafe:1::/64 {
           AdvOnLink on;
           AdvAutonomous on;
           AdvRouterAddr on;
           AdvValidLifetime 2592000;
           AdvPreferredLifetime 604800;
       };

       RDNSS 2001:db8:cafe:1::53 {
           AdvRDNSSLifetime 1200;
       };

       DNSSL lab.example {
           AdvDNSSLLifetime 1200;
       };
   };
   ```

   ```bash
   sudo sysctl -w net.ipv6.conf.enp1s0.forwarding=1
   sudo systemctl enable --now radvd && systemctl status radvd --no-pager
   ```

2. On `lab-target` (with `accept_ra` temporarily re-enabled so you can see the effect), record the honest baseline:

   ```bash
   sudo sysctl -w net.ipv6.conf.enp1s0.accept_ra=1 net.ipv6.conf.enp1s0.autoconf=1
   ip -6 addr show dev enp1s0
   ip -6 route show
   ```

   ```
   inet6 2001:db8:cafe:1:5054:ff:feaa:bbcc/64 scope global dynamic mngtmpaddr
          valid_lft 2591978sec preferred_lft 604778sec
   default via fe80::5054:ff:fe12:3456 dev enp1s0 proto ra metric 1024 pref high
   ```

   Note `proto ra` — the kernel labels routes it learned from an advertisement.

3. Actively solicit and enumerate every router that answers:

   ```bash
   rdisc6 -m enp1s0
   ```

   ```
   Soliciting ff02::2 (ff02::2) on enp1s0...

   Hop limit                 :           64 (      0x40)
   Stateful address conf.    :           No
   Stateful other conf.     :          Yes
   Router preference         :         high
   Router lifetime           :         1800 (0x00000708) seconds
    Prefix                   : 2001:db8:cafe:1::/64
     On-link                 :          Yes
     Autonomous address conf.:          Yes
    Recursive DNS server     : 2001:db8:cafe:1::53
    Source link-layer address: 52:54:00:12:34:56
    from fe80::5054:ff:fe12:3456
   ```

   `-m` keeps listening instead of exiting after the first reply — which is the whole point when you are hunting for a second router.

4. Resolve a link-layer address the IPv6 way (there is no ARP):

   ```bash
   ndisc6 2001:db8:cafe:1::1 enp1s0
   ```

   ```
   Soliciting 2001:db8:cafe:1::1 (2001:db8:cafe:1::1) on enp1s0...
   Target link-layer address: 52:54:00:12:34:56
    from 2001:db8:cafe:1::1
   ```

5. Start a continuous RA monitor on `lab-target`:

   ```bash
   sudo tshark -i enp1s0 -l -Y 'icmpv6.type == 134' \
        -T fields -e frame.time -e eth.src -e ipv6.src \
                  -e icmpv6.nd.ra.router_lifetime \
                  -e icmpv6.nd.ra.cur_hop_limit \
                  -e icmpv6.opt.prefix.prefix \
                  -e icmpv6.opt.rdnss.dns \
        -E separator=' | ' -E header=y
   ```

6. On `lab-rogue`, advertise a competing default route with a higher preference and a DNS server you control:

   ```conf
   # /etc/radvd.conf on lab-rogue
   interface enp1s0 {
       AdvSendAdvert on;
       MaxRtrAdvInterval 4;
       AdvDefaultPreference high;
       AdvDefaultLifetime 9000;
       prefix 2001:db8:dead::/64 {
           AdvOnLink on;
           AdvAutonomous on;
       };
       RDNSS 2001:db8:dead::66 { AdvRDNSSLifetime 9000; };
   };
   ```

   ```bash
   sudo systemctl start radvd
   ```

7. On `lab-target`, observe the compromise:

   ```bash
   ip -6 addr show dev enp1s0 | grep -c 'scope global dynamic'
   ip -6 route show | grep '^default'
   ```

   ```
   default via fe80::5054:ff:fe12:3456 dev enp1s0 proto ra metric 1024 pref high
   default via fe80::5054:ff:fe99:9966 dev enp1s0 proto ra metric 1024 pref high
   ```

   The host now has two default routes and two global addresses, and `rdisc6 -m` shows two distinct `eth.src` values. On a segment with exactly one router, `count(distinct eth.src where icmpv6.type==134) > 1` is your alarm condition.

8. Also watch for the denial-of-service variant — an RA that zeroes the router lifetime, withdrawing the real gateway:

   ```bash
   sudo tshark -r /dev/stdin -Y 'icmpv6.type == 134 && icmpv6.nd.ra.router_lifetime == 0' 2>/dev/null &
   ```

9. Mitigate, in order of durability:

   ```bash
   # a) Host: refuse to learn anything (correct for statically addressed servers)
   sudo sysctl -w net.ipv6.conf.enp1s0.accept_ra=0 \
                  net.ipv6.conf.enp1s0.autoconf=0 \
                  net.ipv6.conf.enp1s0.accept_ra_defrtr=0 \
                  net.ipv6.conf.enp1s0.accept_ra_pinfo=0

   # b) Host: drop and log rogue RAs at the filter (exercise 2, step 6)
   sudo nft list chain inet filter input | grep ROGUE-RA
   sudo journalctl -k -g 'ROGUE-RA' -n 5

   # c) Clean up the state the attack already installed
   sudo ip -6 route flush proto ra
   sudo ip -6 addr flush dev enp1s0 scope global dynamic
   ```

   ```
   # d) Infrastructure: the only real fix — RFC 6105 RA Guard on the access switch
   interface GigabitEthernet1/0/12
    ipv6 nd raguard attach-policy HOST_PORTS
   ```

10. Verify the host is now inert while the rogue is still transmitting:

    ```bash
    sudo timeout 20 tshark -i enp1s0 -q -Y 'icmpv6.type == 134' -z io,stat,10,'COUNT(icmpv6.type)icmpv6.type==134'
    ip -6 route show | grep -c 'proto ra'
    ```

    Advertisements still arrive; the kernel installs nothing.

### Comprehension questions

**Q6.1** Which ICMPv6 types are Router Solicitation and Router Advertisement, and which multicast group does each target?

**Q6.2** A rogue RA needs no privileged position, no ARP poisoning and no IPv4 access, yet it can take over a whole segment. Explain why the protocol permits this — cite the design assumption in RFC 4861.

**Q6.3** Distinguish the two failure modes: the rogue RA that adds a default route, and the rogue RA that carries `Router Lifetime = 0`. What is the impact of each?

**Q6.4** `accept_ra=0` protects the host. Why is that nonetheless described here as the *weakest* of the four mitigations?

**Q6.5** What is the difference between `accept_ra=1` and `accept_ra=2`, and when does the distinction matter?

**Q6.6** A host on an "IPv4-only" network is still vulnerable to a rogue RA. Explain the attack path and why disabling IPv6 addressing in the network manager is not sufficient.

**Q6.7** `rdisc6` without `-m` exits after the first response. Why does that make it useless as a rogue-router detector, and what flag fixes it?

**Q6.8** Beyond RA Guard, RFC 3971 defines a cryptographic answer. Name it and state why it is rarely deployed.

---

## Exercise 7 — Rogue DHCP and ARP anomalies

### Steps

1. From `lab-ops`, ask the segment who is willing to hand out addresses:

   ```bash
   sudo nmap --script broadcast-dhcp-discover -e enp1s0
   ```

   ```
   Pre-scan script results:
   | broadcast-dhcp-discover:
   |   Response 1 of 2:
   |     Interface: enp1s0
   |     IP Offered: 192.168.56.101
   |     DHCP Message Type: DHCPOFFER
   |     Server Identifier: 192.168.56.10
   |     Subnet Mask: 255.255.255.0
   |     Router: 192.168.56.10
   |     Domain Name Server: 192.168.56.53
   |     IP Address Lease Time: 12h00m00s
   |   Response 2 of 2:
   |     Interface: enp1s0
   |     IP Offered: 10.13.37.55
   |     DHCP Message Type: DHCPOFFER
   |     Server Identifier: 192.168.56.66
   |     Router: 192.168.56.66
   |     Domain Name Server: 10.13.37.1
   |     IP Address Lease Time: 10m00s
   Nmap done: 0 IP addresses (0 hosts up) scanned in 5.42 seconds
   ```

   Two offers on a single-server segment is the finding. The short lease, the foreign subnet and the attacker-controlled `Router`/`DNS` are the classic MITM signature.

2. Do the same for DHCPv6, which is frequently forgotten:

   ```bash
   sudo nmap --script broadcast-dhcp6-discover -e enp1s0
   ```

3. Build a passive detector rather than an active prober, so it can run permanently:

   ```bash
   sudo tshark -i enp1s0 -l -f 'udp port 67 or udp port 68' \
        -Y 'dhcp.option.dhcp == 2 || dhcp.option.dhcp == 5' \
        -T fields -e frame.time -e eth.src -e ip.src \
                  -e dhcp.option.dhcp -e dhcp.option.dhcp_server_id \
                  -e dhcp.option.router -e dhcp.option.domain_name_server \
                  -e dhcp.ip.your -e dhcp.option.ip_address_lease_time \
        -E separator=' | ' -E header=y
   ```

   Option 53 value 2 is `DHCPOFFER`, value 5 is `DHCPACK`. Any `dhcp.option.dhcp_server_id` outside your inventory is a rogue.

4. Cross-check with the purpose-built tool:

   ```bash
   sudo dhcpdump -i enp1s0
   ```

5. Enforce at the host and, where you own the bridge, at L2:

   ```bash
   # host side: already in /etc/nftables.conf from exercise 2
   sudo journalctl -k -g 'ROGUE-DHCP' -n 5
   ```

   ```nft
   # /etc/nftables-bridge.conf — for a Linux bridge acting as the access switch
   table bridge dhcp_guard {
       chain forward {
           type filter hook forward priority -300; policy accept;

           # DHCP server traffic may only enter from the uplink port
           iifname != "uplink0" udp sport 67 udp dport 68 \
               counter log prefix "DHCP-SNOOP-DROP " level warn drop
           iifname != "uplink0" udp sport 547 udp dport 546 \
               counter log prefix "DHCP6-SNOOP-DROP " level warn drop
       }
   }
   ```

   ```bash
   sudo nft -c -f /etc/nftables-bridge.conf && sudo nft -f /etc/nftables-bridge.conf
   ```

   On managed hardware the equivalent is DHCP snooping:

   ```
   ip dhcp snooping
   ip dhcp snooping vlan 56
   interface GigabitEthernet1/0/24
    description uplink to core
    ip dhcp snooping trust
   interface range GigabitEthernet1/0/1-23
    ip dhcp snooping limit rate 15
   ```

6. Detect the ARP layer of the same attack with `arpwatch`. Run it in the foreground first:

   ```bash
   sudo install -d -m 0750 -o arpwatch -g arpwatch /var/lib/arpwatch
   sudo arpwatch -d -i enp1s0 -f /var/lib/arpwatch/enp1s0.dat
   ```

7. On `lab-rogue`, claim the gateway's IPv4 address, then read the report:

   ```bash
   sudo arping -c 3 -A -I enp1s0 -s 52:54:00:99:99:66 192.168.56.10
   ```

   ```
   From: root (root)
   To: root
   Subject: changed ethernet address (lab-gw)

               hostname: lab-gw
             ip address: 192.168.56.10
       ethernet address: 52:54:00:99:99:66
        ethernet vendor: unknown
   old ethernet address: 52:54:00:12:34:56
    old ethernet vendor: unknown
              timestamp: Tuesday, August 25, 2026 11:04:12 +0000
     previous timestamp: Tuesday, August 25, 2026 11:03:58 +0000
                  delta: 14 seconds
   ```

8. Make it persistent and route the alerts somewhere a human reads:

   ```bash
   # Debian: interfaces and options in /etc/arpwatch.conf, one per line
   echo 'enp1s0 -m security@lab.example -p' | sudo tee -a /etc/arpwatch.conf
   sudo systemctl enable --now arpwatch@enp1s0.service
   sudo journalctl -u arpwatch@enp1s0 -f
   ```

   `-p` disables promiscuous mode — you monitor only what the switch forwards to this port, which is usually what you want on an access port and never what you want on a SPAN port.

9. Pin the gateway so this host cannot be redirected even if the ARP cache is attacked:

   ```bash
   sudo ip neigh replace 192.168.56.10 lladdr 52:54:00:12:34:56 \
                 dev enp1s0 nud permanent
   ip neigh show 192.168.56.10
   ```

   ```
   192.168.56.10 dev enp1s0 lladdr 52:54:00:12:34:56 PERMANENT
   ```

### Comprehension questions

**Q7.1** Why is `nmap --script broadcast-dhcp-discover` classed as a *pre-scan* script, and why does it report "0 IP addresses ... scanned"?

**Q7.2** Two DHCPOFFERs arrive. Which one does a standard client accept, and what does that imply about the reliability of a rogue DHCP attack from the attacker's point of view?

**Q7.3** The rogue offer had a 10-minute lease while the legitimate one had 12 hours. Why would an attacker choose a short lease?

**Q7.4** A rogue DHCP server can hand out a malicious `Router` (option 3) and `Domain Name Server` (option 6). Name a third option that is at least as dangerous and explain the attack.

**Q7.5** DHCP snooping is a switch feature, yet you implemented an equivalent with `nftables` in the `bridge` family. Why the `bridge` family rather than `inet`?

**Q7.6** List the event classes `arpwatch` reports and say which one indicates ARP spoofing versus which indicates ordinary DHCP churn.

**Q7.7** What does `arpwatch -p` change, and on which kind of port is omitting it a mistake?

**Q7.8** A `PERMANENT` neighbour entry defeats ARP spoofing for that one address. Give two reasons this does not scale as a general defence.

---

## Exercise 8 — A continuous drift-detection harness

### Steps

1. Write the check:

   ```bash
   #!/usr/bin/env bash
   # /usr/local/sbin/net-drift
   set -euo pipefail
   umask 077

   TARGETS=/etc/net-drift/targets.txt
   STATE=/var/lib/net-drift
   BASE="$STATE/baseline.xml"
   CUR="$STATE/current.xml"
   DIFF="$STATE/drift.txt"

   install -d -m 0700 "$STATE"

   nmap -sS -sV -O --top-ports 1000 --open -T4 \
        -iL "$TARGETS" -oX "$CUR" >/dev/null

   if [[ ! -s $BASE ]]; then
       cp -- "$CUR" "$BASE"
       logger -t net-drift -p auth.notice "baseline established"
       exit 0
   fi

   # ndiff exits 0 identical, 1 differences, 2 error — distinguish 1 from 2.
   rc=0
   ndiff "$BASE" "$CUR" > "$DIFF" || rc=$?
   case $rc in
       0) logger -t net-drift -p auth.info "no drift" ;;
       1) logger -t net-drift -p auth.warning "network surface drift detected"
          logger -t net-drift -p auth.warning -f "$DIFF" ;;
       *) logger -t net-drift -p auth.err "ndiff failed with status $rc"; exit "$rc" ;;
   esac

   # Rogue infrastructure sweep, same run.
   nmap --script broadcast-dhcp-discover,broadcast-dhcp6-discover -e enp1s0 \
       | awk '/Server Identifier/ {print $NF}' | sort -u \
       | grep -vxF -f /etc/net-drift/authorised-dhcp.txt \
       | while read -r bad; do
             logger -t net-drift -p auth.crit "unauthorised DHCP server: $bad"
         done || true

   timeout 40 rdisc6 -m enp1s0 2>/dev/null \
       | awk '/^ from / {print $2}' | sort -u \
       | grep -vxF -f /etc/net-drift/authorised-routers.txt \
       | while read -r bad; do
             logger -t net-drift -p auth.crit "unauthorised IPv6 router: $bad"
         done || true
   ```

   ```bash
   sudo install -m 0700 /tmp/net-drift /usr/local/sbin/net-drift
   sudo install -d -m 0700 /etc/net-drift
   printf '192.168.56.10\n192.168.56.20\n' | sudo tee /etc/net-drift/targets.txt
   printf '192.168.56.10\n'                | sudo tee /etc/net-drift/authorised-dhcp.txt
   printf 'fe80::5054:ff:fe12:3456\n'      | sudo tee /etc/net-drift/authorised-routers.txt
   ```

2. Schedule it:

   ```ini
   # /etc/systemd/system/net-drift.service
   [Unit]
   Description=Network surface and rogue-infrastructure drift check
   After=network-online.target
   Wants=network-online.target

   [Service]
   Type=oneshot
   Nice=10
   IOSchedulingClass=idle
   ExecStart=/usr/local/sbin/net-drift
   ProtectSystem=strict
   ReadWritePaths=/var/lib/net-drift
   PrivateTmp=yes
   NoNewPrivileges=yes
   AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN
   CapabilityBoundingSet=CAP_NET_RAW CAP_NET_ADMIN
   ```

   ```ini
   # /etc/systemd/system/net-drift.timer
   [Unit]
   Description=Run the network drift check nightly

   [Timer]
   OnCalendar=daily
   RandomizedDelaySec=1h
   Persistent=true

   [Install]
   WantedBy=timers.target
   ```

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now net-drift.timer
   systemctl list-timers net-drift.timer --no-pager
   sudo systemctl start net-drift.service && journalctl -u net-drift -n 20 --no-pager
   ```

3. Prove the harness fires. Re-run the exercise 6 rogue `radvd` and the exercise 7 `arping`, then:

   ```bash
   sudo systemctl start net-drift.service
   sudo journalctl -t net-drift -p crit --no-pager
   ```

   ```
   Aug 25 23:41:07 lab-ops net-drift[4412]: unauthorised DHCP server: 192.168.56.66
   Aug 25 23:41:49 lab-ops net-drift[4412]: unauthorised IPv6 router: fe80::5054:ff:fe99:9966
   ```

4. Approve a legitimate change the way a change-control process should:

   ```bash
   sudo cp /var/lib/net-drift/current.xml /var/lib/net-drift/baseline.xml
   logger -t net-drift -p auth.notice "baseline re-approved: CHG-2026-0812 (mariadb on lab-target)"
   ```

### Comprehension questions

**Q8.1** The script sets `set -e` yet calls `ndiff` in a way that survives a non-zero exit. Explain the construct and why a naive `ndiff a b` would abort the script on every detected drift.

**Q8.2** `AmbientCapabilities=CAP_NET_RAW` appears instead of running as root. Which nmap scan types need it, and which would work without it?

**Q8.3** Why `RandomizedDelaySec=1h` and `Persistent=true`? What does each protect against?

**Q8.4** Step 4 overwrites the baseline. Name the control that must wrap this action, and the failure mode when it is missing.

**Q8.5** This harness detects a rogue DHCP server only if it answers *during the check*. Name a detection approach without that blind spot and say what it costs.

---

## Reference sources

- LPI — Exam 303-300 objectives: <https://www.lpi.org/our-certifications/exam-303-objectives/>
- Nmap Reference Guide: <https://nmap.org/book/man.html> · Ndiff: <https://nmap.org/ndiff/> · `broadcast-dhcp-discover`: <https://nmap.org/nsedoc/scripts/broadcast-dhcp-discover.html>
- Wireshark — `tshark(1)`: <https://www.wireshark.org/docs/man-pages/tshark.html> · Display Filter Reference: <https://www.wireshark.org/docs/dfref/> · `dumpcap` privileges: <https://wiki.wireshark.org/CaptureSetup/CapturePrivileges>
- FreeRADIUS documentation: <https://www.freeradius.org/documentation/> · Wiki (config files, `radiusd -X`): <https://wiki.freeradius.org/>
- RFC 2865 — RADIUS: <https://www.rfc-editor.org/rfc/rfc2865.html> · RFC 2866 — Accounting: <https://www.rfc-editor.org/rfc/rfc2866.html> · RFC 3579 — RADIUS support for EAP: <https://www.rfc-editor.org/rfc/rfc3579.html>
- IEEE 802.1X-2020 — Port-Based Network Access Control: <https://standards.ieee.org/ieee/802.1X/7345/>
- hostapd: <https://w1.fi/hostapd/> · wpa_supplicant: <https://w1.fi/wpa_supplicant/>
- RFC 4861 — Neighbor Discovery for IPv6: <https://www.rfc-editor.org/rfc/rfc4861.html> · RFC 4862 — SLAAC: <https://www.rfc-editor.org/rfc/rfc4862.html>
- RFC 6104 — Rogue IPv6 Router Advertisement Problem Statement: <https://www.rfc-editor.org/rfc/rfc6104.html> · RFC 6105 — IPv6 RA Guard: <https://www.rfc-editor.org/rfc/rfc6105.html> · RFC 3971 — SEND: <https://www.rfc-editor.org/rfc/rfc3971.html>
- ndisc6 / rdisc6 (IPv6 diagnostic tools): <https://www.remlab.net/ndisc6/>
- radvd: <https://radvd.litech.org/>
- arpwatch (Lawrence Berkeley National Laboratory): <https://ee.lbl.gov/>
- Linux kernel — IP sysctl reference: <https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html>
- nftables wiki: <https://wiki.nftables.org/wiki-nftables/index.php/Main_Page>
- `systemd.resource-control(5)` — `IPAddressAllow`/`IPAddressDeny`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html>
- RFC 2131 — DHCP: <https://www.rfc-editor.org/rfc/rfc2131.html> · RFC 3315/8415 — DHCPv6: <https://www.rfc-editor.org/rfc/rfc8415.html>

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**A1.1** `cupsd` is bound to `127.0.0.1:631`, not `0.0.0.0:631`. The socket exists, but the kernel only accepts connections whose destination address is the loopback address, so a SYN arriving on `enp1s0` with destination `192.168.56.20` matches no listening socket and the kernel replies with RST — which nmap reports as `closed`. This is the single cheapest hardening measure available: bind services to the narrowest address that satisfies the requirement. "Running" is a process-table fact; "exposed" is a tuple of (bind address, route, packet filter).

**A1.2** `closed` means nmap received an active negative response — TCP RST, or ICMP port-unreachable for UDP — so a host is there and nothing is listening. `filtered` means nmap received *nothing*, or an ICMP administratively-prohibited message; the probe was silently dropped. `filtered` is the one that indicates a packet filter with a DROP policy in the path. `unfiltered` (only from an ACK scan) means the port is reachable but nmap cannot tell open from closed.

**A1.3** `-sS` writes raw packets and never completes the handshake, so it needs `CAP_NET_RAW` (root, or an ambient capability). `-sT` uses the ordinary `connect(2)` syscall, so any user can run it. The trace differs accordingly: `-sS` leaves nothing in the application log because the connection is torn down with RST before `accept(2)` returns, while `-sT` produces a completed and immediately closed connection that daemons like `sshd` log (`Connection closed by 192.168.56.30 port 41234 [preauth]`). `-sS` is also considerably faster and does not exhaust the local socket table.

**A1.4** `ndiff` exits **0** when the two scans are identical, **1** when they differ, and **2** on an error such as an unreadable or malformed input file. Under `set -e` the *expected, informative* case (drift found) aborts the script, and — worse — a genuine error (2) becomes indistinguishable from it if you only test `if ! ndiff`. Capture the status explicitly (`rc=0; ndiff … || rc=$?`) and branch on all three values, as in exercise 8.

**A1.5** They prove different claims. `ss -tulpn` proves *no process is bound* to that port on that host — it is authoritative about the host's own socket table but says nothing about a filter, a NAT rule, a sidecar, or another host in the same DNS name. `nmap` proves *this port is not reachable from where I scanned* — authoritative about reachability from one vantage point, but it cannot distinguish "not listening" from "listening but firewalled", and it says nothing about reachability from a different network. A defensible claim needs both: the host-local inventory for what exists, and the network view for what is reachable from each security zone.

### Exercise 2

**A2.1** For `rp_filter` the effective value is `max(conf.all.rp_filter, conf.<dev>.rp_filter)`, so setting `all = 1` reliably turns it on everywhere and setting `all = 0` does *not* turn it off where a device has 1. For most other keys — `accept_redirects`, `accept_ra`, `forwarding` — the effective value is the *per-device* one, and writing `conf.all.X` is a broadcast write that copies the value into every interface **that exists at that moment**. The practical bug: an interface created *after* `sysctl --system` ran (a VPN tun, a container veth, a bridge, a hot-plugged NIC, an interface renamed by udev late in boot) inherits `conf.default.X`, not the `conf.all.X` you set. Hence you must set both `all` (existing devices) and `default` (future devices), and re-verify per device.

**A2.2** `all` was a one-time broadcast to interfaces present when the setting was applied. `default` is the template copied into the per-device sysctl directory each time a new interface appears. Without it, every interface created later — a container's veth, a WireGuard tunnel, a bridge — comes up with the kernel default `accept_ra = 1` and will happily install a route from any advertisement it sees. Step 3 demonstrates exactly this with `dummy0`.

**A2.3** `IPAddressAllow`/`IPAddressDeny` are implemented with an eBPF cgroup socket-address filter, so they require **cgroup v2 (the unified hierarchy) and kernel BPF support**, and a systemd built with BPF firewalling. Verify with `systemd-analyze security <unit>` (the `IPAddressDeny=` line shows as exempt/ok versus unsupported), `systemctl show <unit> -p IPAddressDeny`, and `systemctl --version | grep -o '+BPF_FRAMEWORK'`. On a cgroup-v1 system systemd logs a warning at unit start and the directive is silently ineffective — a hardening control that looks configured and enforces nothing.

**A2.4** Before the ruleset, `mariadb` was not listening, so the kernel generated a TCP RST for the SYN and nmap classified the port `closed`. After the ruleset, the `policy drop` at the end of the `input` chain discards the SYN without generating any reply, so nmap's probe times out through all its retransmissions and it classifies the port `filtered`. The distinction is a reconnaissance signal in itself: `closed` tells the attacker a host exists there, `filtered` withholds even that.

**A2.5** RFC 4861 §11.2 requires every Neighbour Discovery message to be sent with an IPv6 Hop Limit of 255 and requires receivers to discard ND messages whose hop limit is not 255. Because a router decrements the hop limit, a value of 255 at the receiver proves the packet was *not routed* — it originated on the local link. The single match therefore eliminates all **off-link, remotely injected ND and RA spoofing**: an attacker who is not on your L2 segment cannot forge a packet that arrives with hop limit 255. It does nothing against an attacker who *is* on the segment — that is what the `ip6 saddr` allow-list and RA Guard are for.

**A2.6** `rp_filter = 1` (strict reverse-path forwarding) drops any packet whose source address would not be routed back out of the interface it arrived on. That breaks **asymmetric routing** — legitimate in multi-homed hosts, ECMP/multipath setups, some VRRP and DSR load-balancer topologies, and policy-routing arrangements. The fix is `rp_filter = 2` (loose mode: the source must be routable via *any* interface, not necessarily the ingress one), which still stops the classic spoofed-source flood while tolerating asymmetry. Per-interface exceptions (`net.ipv4.conf.<dev>.rp_filter = 2`) are preferable to weakening the global value — remembering the `max()` rule from A2.1, which means you must lower `all` to 0 and raise the safe interfaces individually.

### Exercise 3

**A3.1** A `-f` capture filter is compiled to BPF bytecode and executed **in the kernel**, inside `dumpcap`'s packet path, before the packet is copied to userspace. A `-Y` display filter is evaluated **in userspace** by the full Wireshark dissector engine, after the packet has been captured, copied and dissected. The choice decides whether you drop packets whenever the capture rate approaches the machine's copy-and-dissect throughput: on a busy link, dissecting everything to discard 99% of it saturates a CPU and the kernel's ring buffer overflows — `capinfos` and the `tshark` summary will report dropped packets. Rule of thumb: cut volume in the kernel with `-f`, then refine in userspace with `-Y` or offline with `-r`.

**A3.2** `-f 'tcp port 80'` keeps every TCP packet on port 80 — SYNs, ACKs, RSTs, FINs, retransmissions, TLS-on-80 and malformed junk — but discards HTTP served on any other port. `-Y 'http'` keeps HTTP wherever the dissector recognises it (8080, 8000, or a port set by `decode_as`) but discards the pure handshake and teardown packets that carry no HTTP layer, which is exactly the data you need to diagnose a connection that never completes.

**A3.3** Wireshark's dissectors are hundreds of thousands of lines of C parsing hostile, attacker-controlled input; a dissector bug becomes remote code execution with the privileges of the process. Running that as root gives an attacker who can put a packet on your wire full control of the machine. The architectural fix is privilege separation: the tiny `dumpcap` helper holds `cap_net_admin,cap_net_raw=eip` and does nothing but capture, while the GUI and the dissectors run as the unprivileged user. Membership in the `wireshark` group grants execution of `dumpcap`; nothing else needs privilege.

**A3.4** `-s 96` truncates each packet to 96 bytes, which covers Ethernet + IP + TCP/UDP headers and a little more. Still possible: flow and conversation analysis, endpoint statistics, port and protocol inventory, TCP state and retransmission analysis, timing, ND/RA/DHCP option inspection for short options, rogue-server detection. No longer possible: payload reconstruction, `follow tcp stream`, file extraction, credential recovery, full TLS handshake inspection, and any dissection of application data past the cut — those frames appear as `[Packet size limited during capture]`. Truncation is often a *requirement*, not a compromise: it keeps a permanent capture inside a data-protection policy that forbids retaining user content.

**A3.5** Steady state is at most **10 files × 65 536 kB ≈ 640 MB** (`-b filesize` is in kilobytes). When the tenth file reaches the size limit, `tshark` opens an eleventh and **deletes the oldest**, so you always hold the most recent ~640 MB and nothing grows without bound. The oldest data is gone permanently — size the ring against how long an incident takes to be noticed, and archive files off-box if you need a longer window. Note `-b duration:` and `-b interval:` as alternative roll conditions.

**A3.6** The filter is **`dhcp`** (and `dhcpv6` for IPv6). It replaced **`bootp`** in Wireshark 3.0, because DHCP is an extension of the BOOTP framing and the dissector was historically named after it. `bootp` remains accepted as a deprecated alias in many builds, but scripts should use `dhcp`; field names moved too — `bootp.option.dhcp` became `dhcp.option.dhcp`.

### Exercise 4

**A4.1** Modern RADIUS uses **UDP/1812 for authentication and authorisation** and **UDP/1813 for accounting** (assigned by IANA, RFC 2865/2866). The historical, pre-assignment ports still supported by many implementations are **UDP/1645 (auth)** and **UDP/1646 (acct)** — they collide with the `datametrics` service, which is why they were replaced. RadSec (RADIUS over TLS, RFC 6614) uses TCP/2083.

**A4.2** `User-Password` is not encrypted in any modern sense: the client XORs the password (padded to a multiple of 16 octets) with a keystream built from `MD5(shared_secret || Request_Authenticator)`, chaining MD5 over the previous ciphertext block for longer passwords. The only secret input is the **shared secret** — the Request Authenticator travels in cleartext in the same packet. So an attacker who captures one Access-Request and knows or guesses the shared secret recovers the password by recomputing the keystream; that is exactly what step 10 does with `-o radius.shared_secret:testing123`. Consequences: shared secrets must be long, random and unique per NAS (never the vendor default, never `testing123`, never reused across devices), and RADIUS should traverse only trusted paths — or, better, RadSec/IPsec.

**A4.3** `reject_delay` in `radiusd.conf` (default `1` second, expressed as `reject_delay = 1` inside the `security { }` or top-level section depending on version). The server holds a computed Access-Reject for that interval before sending it. Two purposes: it rate-limits online password guessing through the NAS, and it damps the request storms produced by misconfigured clients that retry immediately on rejection. It also means a naive "authentication latency" alert will flag every failed login.

**A4.4** CHAP (RFC 1994) and MS-CHAPv2 are challenge–response protocols: the server must compute the expected response from the challenge and the *password material* itself — `MD5(id || password || challenge)` for CHAP, and an NT-hash-derived computation for MS-CHAPv2. Neither the password nor the NT hash can be derived from a one-way hash of the password (`Crypt-Password`, bcrypt, SHA-512), so a hashed store supports **PAP only**. If you need CHAP/MS-CHAPv2 you must hold `Cleartext-Password`, or `NT-Password` for MS-CHAP specifically — which is why the credential store itself becomes the crown jewel and why EAP-TLS (certificates, no password at rest) is the stronger design.

**A4.5** Two conditions: (1) the **`radutmp` module must be listed in the `accounting { }` section** of the active virtual server, `/etc/raddb/sites-enabled/default` (and typically in `session { }` for simultaneous-use checks); and (2) the **`radutmp` file must exist and be writable** by the `radiusd` user — `/var/log/radius/radutmp` on RHEL, `/var/log/freeradius/radutmp` on Debian — with the module's `filename` in `/etc/raddb/mods-available/radutmp` pointing at it. `radwho` reads `radutmp` (current sessions); `radlast` reads `radwtmp` (historical). No accounting packets, no module, or a wrong path, and both tools print an empty table without error.

**A4.6** The Message-Authenticator attribute (RFC 2869) is an HMAC-MD5 over the whole packet keyed with the shared secret. Requiring it means the server rejects any Access-Request that is not integrity-protected, which blocks packet injection and the trivial spoofing of a NAS by anyone who can reach UDP/1812 — and it is mandatory for any request carrying EAP-Message. It is `no` for `localhost` in the shipped configuration because the local test utilities (`radtest`, and `radclient` unless you ask for it) do not always include the attribute, and the shipped config prioritises "the tutorial works out of the box" over strictness on a loopback-only client. For any real NAS, set it to `yes`.

**A4.7** `systemctl start radiusd` daemonises, drops privileges, and logs at normal verbosity to syslog or the journal — you see `Login OK` / `Login incorrect` and little else. `radiusd -X` (equivalently `-Xxx`, or `-xx -l stdout`) runs single-threaded in the foreground with full debug output, printing **every module in the policy chain, in order, with the attribute list before and after each one**, the exact `users`-file entry matched with its line number, the request and reply attribute pairs, and the reason for the decision. Since FreeRADIUS is a policy engine rather than a fixed authentication program, almost every failure is "the request went down a different branch of the policy than you assumed" — which is invisible in normal logs and explicit in `-X`. The upstream project's standard first question on any bug report is for the `radiusd -X` output.

**A4.8** The `users` file is processed top to bottom and, for a matching entry, stops at the first match unless the entry sets `Fall-Through = Yes`. `DEFAULT` matches **every** request. Placed first, it would match every authentication attempt before `bob` or the MAB entry is ever considered, and with `Auth-Type := Reject` every user in the file would be denied — a complete outage that looks like a credential problem. The ordering rule is the same as a firewall's: specific rules first, catch-all last.

### Exercise 5

**A5.1** **Supplicant** — the client seeking access: `lab-target` running `wpa_supplicant`. **Authenticator** — the network device that controls the port and relays EAP: `lab-gw` running `hostapd -d wired` (in production, the access switch or wireless AP). **Authentication Server** — the entity that makes the decision: `lab-ops` running FreeRADIUS. The authenticator is deliberately a dumb relay; it holds no credentials and makes no policy decision, which is why one RADIUS server can govern thousands of ports.

**A5.2** `01:80:c2:00:00:03` is the **PAE (Port Access Entity) group address**, a reserved IEEE 802.1D multicast MAC; EAPOL uses Ethertype `0x888E`. 802.1X cannot run over IP because its entire purpose is to authenticate *before* the port is authorised — at that point the supplicant has no IP address, no route, no DHCP lease and no permitted traffic other than EAPOL. The exchange must therefore be a link-layer protocol between directly connected peers. Only after `CTRL-EVENT-EAP-SUCCESS` does the authenticator open the port for general traffic, at which point DHCP and IP can proceed.

**A5.3** The **outer identity** in the initial EAP-Response/Identity travels in cleartext, before the TLS tunnel exists, and is visible to anyone on the segment. The **inner identity and the MSCHAPv2 credential exchange** are carried inside the PEAP TLS tunnel and are protected. `anonymous_identity` lets you put a non-identifying value (`anonymous@lab.example`) in the outer identity so that passive observers learn only the realm — needed for RADIUS proxy routing — and not who is logging in. Leaving `identity` alone leaks a username inventory of your organisation to anyone with a capture.

**A5.4** Without `ca_cert`, the supplicant establishes the PEAP TLS tunnel with **whatever certificate the server presents, unvalidated**. That destroys server authentication, and PEAP's security rests entirely on it: an attacker stands up a rogue authenticator plus a rogue RADIUS server with a self-signed certificate, the supplicant tunnels to it happily, and then hands over the MSCHAPv2 exchange — from which the attacker recovers material to crack the password offline (MSCHAPv2's DES-based construction is broken; `asleap`/`hashcat` do this routinely). This is *the* classic 802.1X misconfiguration. A correct supplicant pins `ca_cert` and additionally constrains the server name (`altsubject_match`, `domain_suffix_match`) so that a certificate from *some* trusted CA for *some other* name is also rejected.

**A5.5** The Message-Authenticator is an HMAC keyed with the shared secret. When the secret is wrong the server computes a different HMAC than the packet carries, and it cannot distinguish "a legitimate NAS with a misconfigured secret" from "an attacker injecting forged requests". RFC 2865 therefore requires it to **silently discard** the packet; replying at all would give an attacker an oracle confirming that a given source address is a configured client, and — for probing purposes — a response to work against. It logs locally instead, which is why "invalid Message-Authenticator" in `radiusd -X` is the definitive shared-secret-mismatch signature, and why a NAS with a wrong secret reports "no response from server" rather than "rejected".

**A5.6** `Tunnel-Type = VLAN (13)`, `Tunnel-Medium-Type = IEEE-802 (6)`, and `Tunnel-Private-Group-Id = "<vlan-id-or-name>"` (RFC 3580). All three are required — a switch that receives only `Tunnel-Private-Group-Id` ignores it. The switch must support RADIUS-assigned VLANs (dynamic VLAN assignment / "AAA authorization network"), must have the target VLAN defined and allowed on the port, and the port must be in 802.1X-controlled mode rather than a hard-coded access VLAN. If the tag is present in the tunnel attributes, the tag itself (`Tunnel-Type:1 = VLAN`) must be consistent across the three.

**A5.7** MAB authenticates a value the device broadcasts in every frame it sends, that any attacker on the segment can read with one capture and then set on their own NIC with `ip link set address`. It is an *identifier*, not a *credential* — there is no secret and nothing is proven. It exists because printers, IP cameras, badge readers and HVAC controllers have no supplicant. Compensating controls: put MAB devices in a dedicated, heavily filtered VLAN with no path to anything sensitive; allow-list specific MACs rather than accepting any; pair with DHCP snooping and IP Source Guard so the address cannot be stolen while the real device is online; alert on the same MAC appearing on two ports; add device profiling (DHCP fingerprint, traffic pattern) so a laptop impersonating a printer is detected; and prefer 802.1X with certificates for anything that can run a supplicant.

### Exercise 6

**A6.1** **Router Solicitation is ICMPv6 type 133**, sent to `ff02::2` (all-routers multicast). **Router Advertisement is ICMPv6 type 134**, sent to `ff02::1` (all-nodes multicast) when unsolicited/periodic, or unicast to the soliciting host in reply. For completeness: Neighbour Solicitation 135, Neighbour Advertisement 136, Redirect 137.

**A6.2** RFC 4861 assumes the local link is a **trusted, cooperative environment**: any node whose RA arrives with hop limit 255 and a link-local source is accepted as a router, with no authentication of the sender and no notion of authorisation. The design goal was zero-configuration bootstrapping — a host must be able to find a router before it has any credentials, keys, or configuration to authenticate one with. The consequence is that "may I be your default gateway and DNS server?" is an unauthenticated assertion any device on the segment can make, which RFC 6104 documents as the rogue-RA problem. Note that the same trust assumption underlies ARP in IPv4; IPv6 merely makes it more powerful, because a single RA delivers gateway, prefix and DNS in one packet.

**A6.3** Adding a route is a **man-in-the-middle**: the host installs a second default route and a second global address, and — depending on source-address selection, route metrics and the router-preference field — sends some or all of its off-link traffic through the attacker, who can also have supplied a malicious RDNSS. It is partial and probabilistic, but sufficient, and it is quiet. `Router Lifetime = 0` is a **denial of service**: RFC 4861 defines a zero lifetime as "I am no longer a default router", so a forged RA carrying the *legitimate* router's link-local source and a zero lifetime causes every host on the segment to delete its default route. Flooding many distinct forged RAs is a third variant that exhausts CPU and address state (the classic `flood_router26` effect) and can wedge unpatched stacks.

**A6.4** Because it protects only the hosts you remembered to configure, and only for as long as nobody changes them. Every new VM, container veth, laptop, contractor machine, appliance, hypervisor management interface and hot-plugged NIC starts with the kernel default `accept_ra = 1`; NetworkManager and systemd-networkd override the sysctl per connection (`ipv6.method=auto`, `IPv6AcceptRA=yes`), silently re-enabling it; and hosts that legitimately *need* SLAAC — most clients — cannot use it at all. It is host-by-host, opt-out, and fails open. RA Guard on the access switch (RFC 6105) removes the rogue advertisement from the segment entirely, protects every device including those you do not administer, needs no per-host state, and fails closed. The correct posture is both: `accept_ra=0` on statically addressed servers as defence in depth, RA Guard as the actual control.

**A6.5** `accept_ra = 1` means "accept Router Advertisements **unless** this interface is forwarding" — the kernel silently ignores RAs on an interface with `forwarding=1`, on the theory that a router should not learn its own default route from the segment it serves. `accept_ra = 2` means "accept them **even if** forwarding is enabled". The distinction matters on any host that is both a router and a SLAAC client: a Linux gateway or a container/VM host that forwards for its guests but obtains its own upstream configuration by SLAAC needs `2`, and will otherwise come up with no default route in a way that looks like an upstream failure. It also matters for hardening — enabling forwarding is *not* a reliable way to make a host ignore RAs, because a value of 2 defeats it.

**A6.6** Any modern kernel has IPv6 enabled and link-local addresses configured, and the IPv6 stack is preferred over IPv4 by the default address-selection policy (RFC 6724). A rogue RA supplies a global prefix, a default route and an RDNSS, at which point the "IPv4-only" host suddenly has working IPv6 and prefers it — so name resolution and connections that previously used IPv4 now traverse the attacker. This is the NAT64/`SLAAC attack` pattern. Disabling IPv6 addressing in the network manager is insufficient because the kernel may still autoconfigure before or independently of it, and because a re-enabled or newly created interface reverts. Real remediation is either full kernel-level disablement (`net.ipv6.conf.all.disable_ipv6=1`, plus `ipv6.disable=1` on the kernel command line where truly no IPv6 is wanted) or — far better — deploying IPv6 deliberately with RA Guard, so that IPv6 is monitored rather than merely unadministered.

**A6.7** Without `-m`, `rdisc6` prints the first Router Advertisement it receives and exits, so on a compromised segment it will report exactly one router — usually the fastest to answer, which may well be the attacker — and give you no indication that a second exists. Rogue-router detection is inherently a *set* comparison, so you must collect every reply. **`-m`** ("wait for multiple RAs") keeps listening; combine it with `-w <ms>` for the wait time and a `timeout` wrapper for scripting, then compare the set of source link-local addresses against your inventory. `-1` does the opposite of what you want here: it explicitly requests a single response.

**A6.8** **SEND — SEcure Neighbor Discovery (RFC 3971)**, which signs ND and RA messages with a public key bound to a **CGA (Cryptographically Generated Address, RFC 3972)** and validates router authorisation with X.509 certificate paths. It is rarely deployed because it requires a router-authorisation PKI, CGA support and the RSA Signature/Timestamp/Nonce options in every host stack, and mainstream operating systems ship no supported implementation; it also interacts badly with DHCPv6, privacy addresses and mobility. In practice the industry settled on the L2 controls — RA Guard, DHCPv6 Guard, IPv6 Snooping/Source Guard — which need no host cooperation at all.

### Exercise 7

**A7.1** Broadcast NSE scripts do not target a host: they send a link-local broadcast or multicast probe on an interface and listen for whoever replies. Nmap runs them in the **pre-scan phase**, before host discovery and port scanning, because their results can *inform* the scan (they discover hosts you did not know about). Since no target list was given, nmap's host-scan phase had nothing to do and reports "0 IP addresses ... scanned" — the useful output is entirely in the `Pre-scan script results:` block. This is also why `-e <iface>` is normally required: with no targets, nmap cannot infer which interface to broadcast on.

**A7.2** A standard client accepts the **first DHCPOFFER it receives** (RFC 2131 permits collecting multiple offers and selecting among them, but essentially every real implementation takes the first). So the attack is a **race the attacker usually wins**: the rogue server is a lightweight process on the same segment with no lease database to consult and no disk to touch, while the legitimate server is typically further away, busier, and may perform a lease lookup, DNS update or database write first. From the attacker's viewpoint the attack is unreliable per-client but reliable in aggregate — over a segment's worth of renewals, they will capture a substantial share of clients, and forcing renewals (a deauth, a port bounce, a DHCPNAK flood) improves the odds.

**A7.3** A short lease forces the client back to the rogue server every few minutes, which (a) re-wins the race repeatedly and re-asserts the malicious gateway and DNS even if the client briefly got a legitimate lease, (b) keeps the attacker's configuration fresh so a reboot of the rogue node quickly re-captures clients, and (c) means that when the attacker leaves, the malicious configuration expires quickly and the evidence disappears from the client's lease file. It is also a tell: a lease time wildly shorter than your standard is a cheap detection signature.

**A7.4** **Option 121 — Classless Static Route** (and its predecessor option 33, plus option 249 on Windows). It lets the server install arbitrary specific routes in the client's routing table — for example `10.0.0.0/8` and `0.0.0.0/1` + `128.0.0.0/1` via the attacker — which beat the default route on longest-prefix match. This is dangerous even against a VPN client: the "TunnelVision" class of attack uses option 121 to route traffic around the tunnel interface while the VPN still appears connected. Other high-value options: **option 66/67 (TFTP server and boot filename)**, which can redirect network boot to attacker-supplied code, **option 15 (domain name)** and **option 119 (domain search)** for search-order hijacking, and **option 252 (WPAD)** for automatic proxy injection.

**A7.5** Because the frames you must block are being **bridged, not routed**. A DHCPOFFER from a rogue node to a client on another port of the same bridge is forwarded at layer 2 and never enters the IP forwarding path, so no hook in the `inet`/`ip` families ever sees it — `type filter hook forward` in the `inet` family only processes routed packets. The `bridge` family attaches to the bridge's own forwarding path (the nftables successor to `ebtables`), which is where the decision must be made. The `iifname != "uplink0"` match implements the essence of DHCP snooping: server-role traffic (sport 67 → dport 68 for v4, 547 → 546 for v6) is legitimate only from the trusted port.

**A7.6** `arpwatch` reports: **new activity** (a MAC/IP pair not seen for six months), **new station** (a MAC never seen before), **flip flop** (the MAC for an IP changed back to a previously seen MAC), **changed ethernet address** (the MAC for an IP changed to a new one), **bogon** (an ARP source address outside the interface's configured subnet/netmask), plus **ethernet broadcast** and **ip broadcast** for addresses of all zeroes or all ones. **`changed ethernet address` and especially `flip flop`** are the spoofing indicators — a flip flop within seconds is the signature of an attacker and the real host alternately claiming an address. Ordinary DHCP churn produces **new station** and **new activity** (a new device gets an address) and, benignly, **changed ethernet address** when a lease is reassigned to a different device — which is why arpwatch on a DHCP segment needs the lease database alongside it to be actionable, and why gateway and server addresses (which should never change MAC) are the highest-signal subjects.

**A7.7** `-p` tells `arpwatch` **not to put the interface into promiscuous mode**. Without it, arpwatch sees every frame the NIC receives; with it, only frames the interface would accept anyway — broadcast (which includes all ARP requests), multicast and unicast to itself. Omitting `-p` is a mistake on a normal switched **access port**, where promiscuous mode gains almost nothing (the switch does not forward other ports' unicast to you) but costs CPU and, on some drivers, triggers link-layer monitoring alerts. Omitting it is *required* on a **SPAN/mirror port or tap**, where the whole point is to receive frames addressed to other stations — there, `-p` would blind the monitor to everything but broadcast.

**A7.8** (1) **It does not scale operationally**: every gateway, DNS server, load balancer and peer needs a manually maintained entry on every host, and a legitimate hardware replacement, NIC swap, VRRP failover or cloud migration silently breaks connectivity in a way that presents as a mysterious partial outage rather than a configuration error. (2) **It only protects the entries you pinned, and only on that host** — the attacker simply targets an unpinned address, or poisons the *gateway's* cache in the reverse direction, or attacks the switch's CAM table instead. Additionally, `nud permanent` entries bypass reachability detection, so the host keeps sending to a dead MAC. The scalable equivalents are **Dynamic ARP Inspection and IP Source Guard** on the switch (validating ARP against the DHCP snooping binding table) and **802.1X port authentication** so unauthorised devices never reach the segment; host-level static entries are best reserved for a handful of genuinely fixed, high-value addresses.

### Exercise 8

**A8.1** The construct is `rc=0; ndiff "$BASE" "$CUR" > "$DIFF" || rc=$?`. Under `set -e` a command that exits non-zero terminates the shell, **except** when it is the left operand of `||`/`&&`, part of a condition, or negated with `!` — so `|| rc=$?` both suppresses the exit and captures the status for the `case`. A naive `ndiff a b` aborts the script on exit 1, which is the *normal, informative* result whenever drift exists: the script would die precisely when it had something to report, no alert would be sent, and the systemd unit would show `FAILURE` with no explanation. Note also that `if ! ndiff a b; then …` would run without aborting but would conflate exit 1 (drift found) with exit 2 (ndiff error) — silently treating a corrupt baseline file as "drift", or worse, as handled.

**A8.2** `CAP_NET_RAW` is needed to open raw sockets and craft packets: **`-sS`, `-sA`, `-sF`, `-sN`, `-sX`, `-sU`, `-sO`, `-PE/-PS/-PA` host discovery, `-O` OS fingerprinting**, ARP-level scanning of a local segment, and the broadcast NSE scripts used in the same script. Working without it: **`-sT`** (connect scan, ordinary sockets), **`-sn` with `-PS`/`-PA` degraded to TCP connect probes**, `-sV` version detection on already-open ports, and most non-raw NSE scripts. `CAP_NET_ADMIN` is included here for the interface manipulation the broadcast scripts and `rdisc6` need. The point of `AmbientCapabilities` plus a matching `CapabilityBoundingSet` is that a dissector or NSE-script compromise yields raw-socket access, not root — a materially smaller blast radius than `User=root`.

**A8.3** `RandomizedDelaySec=1h` spreads the start time across an hour so that, on a fleet, hundreds of hosts do not all begin scanning at 00:00 — a synchronised fleet-wide scan looks like an attack to your own IDS, saturates links, and can knock over fragile appliances. `Persistent=true` records the last run and, if the machine was off or suspended when the timer should have fired, runs the unit **once shortly after boot** instead of skipping the interval — so a laptop or a host in a maintenance window still gets its check, and a gap in the evidence trail is not created by the machine simply having been down.

**A8.4** **Change control** — the baseline may be re-approved only against a recorded, authorised change (the `CHG-2026-0812` reference in the `logger` line), with the diff itself attached, by someone other than whoever made the change where separation of duties applies. Without it the harness degrades into a rubber stamp: the natural response to a noisy alert is "copy current over baseline", and the first thing an attacker who lands on the monitoring host does is exactly that. The failure mode is a monitoring system that reports "no drift" indefinitely while the surface it was watching has changed completely. Practical hardening: keep baselines in version control so re-approvals are reviewable and reversible, make `/var/lib/net-drift/baseline.xml` writable only by a separate privileged path, and alert on baseline *modification* as its own event.

**A8.5** A nightly active probe only finds a rogue server that is powered on and answering during the few seconds of the check — an attacker who runs their DHCP server for twenty minutes during a lunch break is invisible. The approach without that blind spot is **continuous passive monitoring**: a permanently running `tshark`/`dumpcap` filter on `udp port 67 or 68` and `icmpv6.type == 134` (step 3 of exercise 7 and step 5 of exercise 6), feeding a rule that alerts on any `dhcp.option.dhcp_server_id` or RA source outside the inventory — or better, the enforcement path, where `nftables` `log prefix "ROGUE-DHCP "` and switch DHCP snooping generate an event on every single offending frame. The costs are a long-lived privileged capture process to secure and patch (mitigated by `dumpcap` capabilities, a truncated snaplen and a ring buffer), continuous CPU and disk, log volume and a tuning burden for false positives, and a decision about retaining traffic data under your data-protection policy. In practice you run both: enforcement plus passive alerting for coverage, and the periodic active probe as an independent check that the enforcement is still in place.

</details>