# 109.2 — Persistent Network Configuration
## Guided Exercises (LPIC-1, exams 101-500 / 102-500, version 5.0)

> **Lab requirements.** A disposable VM or container-free VM (KVM/libvirt, VirtualBox, or a cloud instance you can reach through a serial/VNC console), `root` or `sudo`, and a **snapshot taken before you start**. Several steps deliberately reload the networking stack; if your only access is SSH, take console access first — `nmcli connection down` on your management interface will lock you out.
>
> All addressing uses documentation ranges: `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24` (RFC 5737) and `2001:db8::/32` (RFC 3849). Nothing here touches your real uplink, provided you follow the "no gateway on the lab interface" rule in Exercise 4.
>
> Not every distribution ships every stack. Exercise 4 (NetworkManager), Exercise 5 (ifupdown) and Exercise 6 (systemd-networkd) are written so you can run the ones your system has and *read* the ones it does not — the exam expects recognition of all three.

---

## Exercise 0 — Establish the baseline: who owns this machine's network?

Before changing anything, you must know which daemon is authoritative. Persistent configuration written for a stack that is not running is silently ignored — the single most common failure in this objective.

1. Identify the distribution and init generation:

   ```bash
   cat /etc/os-release | head -3
   pidof systemd >/dev/null && echo "systemd PID 1"
   ```

2. Ask which network managers are installed and which are actually active:

   ```bash
   systemctl is-enabled NetworkManager systemd-networkd networking 2>&1
   systemctl is-active  NetworkManager systemd-networkd networking 2>&1
   ```

   Expected output on a Debian 12 desktop-flavoured install:

   ```
   enabled
   disabled
   enabled
   active
   inactive
   active
   ```

3. Enumerate the on-disk configuration sources that exist right now:

   ```bash
   ls -l /etc/network/interfaces /etc/network/interfaces.d/ 2>/dev/null
   ls -l /etc/NetworkManager/system-connections/ 2>/dev/null
   ls -l /etc/systemd/network/ 2>/dev/null
   ls -l /etc/netplan/ 2>/dev/null
   ```

4. Record the live state so you can diff against it later:

   ```bash
   ip -br addr show > /root/baseline-addr.txt
   ip -4 route show > /root/baseline-route4.txt
   ip -6 route show > /root/baseline-route6.txt
   cp -a /etc/resolv.conf /root/baseline-resolv.conf
   ip -br addr show
   ```

   ```
   lo               UNKNOWN        127.0.0.1/8 ::1/128
   enp1s0           UP             192.168.122.61/24 fe80::5054:ff:fe12:3456/64
   ```

5. Prove that `ip(8)` is **not** persistence:

   ```bash
   ip addr add 192.0.2.250/32 dev lo
   ip -br addr show lo
   ```

   ```
   lo               UNKNOWN        127.0.0.1/8 192.0.2.250/32 ::1/128
   ```

   ```bash
   ip addr del 192.0.2.250/32 dev lo
   ```

**Check your understanding**

- **Q0.1** — Both `networking.service` (ifupdown) and `NetworkManager.service` report `active` on the same host. Why is that not automatically a bug, and what single piece of evidence would turn it into one?
- **Q0.2** — You add an address with `ip addr add` and it works. Name the two distinct events that will destroy it, and explain why "it survived a `systemctl restart sshd`" tells you nothing about persistence.
- **Q0.3** — `/etc/network/interfaces` exists and contains a static stanza for `enp1s0`, but `ip -br addr` shows the interface holding a DHCP-style address in a completely different subnet. Give two plausible explanations, each testable with one command.

---

## Exercise 1 — Persistent hostname: static, transient, pretty

1. Read all three hostname flavours at once:

   ```bash
   hostnamectl status
   ```

   ```
    Static hostname: localhost
    Transient hostname: dhcp-192-168-122-61
          Icon name: computer-vm
            Chassis: vm 🖴
         Machine ID: 4f2e0d9a1c3b4f5e8a7d6c5b4a392817
            Boot ID: 9b1c7e2f5a4d43c1b8e6f0a2d3c4b5a6
     Virtualization: kvm
   Operating System: Debian GNU/Linux 12 (bookworm)
             Kernel: Linux 6.1.0-18-amd64
       Architecture: x86-64
   ```

2. Set the **static** hostname (systemd ≥ 249 syntax first, older syntax second — both are examinable):

   ```bash
   hostnamectl hostname lab-node01        # systemd >= 249
   # hostnamectl set-hostname lab-node01  # any systemd version
   hostnamectl set-hostname --pretty "LPIC-1 Lab Node 01"
   ```

3. Show where each value landed on disk:

   ```bash
   cat /etc/hostname
   grep PRETTY_HOSTNAME /etc/machine-info
   hostname
   ```

   ```
   lab-node01
   PRETTY_HOSTNAME=LPIC-1 Lab Node 01
   lab-node01
   ```

4. Ask for the fully qualified name — and watch it fail:

   ```bash
   hostname -f
   ```

   ```
   hostname: Name or service not known
   ```

5. Fix it in `/etc/hosts`. Edit the file to contain exactly:

   ```
   127.0.0.1       localhost
   127.0.1.1       lab-node01.example.internal lab-node01
   ::1             localhost ip6-localhost ip6-loopback
   ff02::1         ip6-allnodes
   ff02::2         ip6-allrouters
   ```

6. Re-test the derived names:

   ```bash
   hostname -f; hostname -d; hostname -s; hostname -I
   ```

   ```
   lab-node01.example.internal
   example.internal
   lab-node01
   192.168.122.61
   ```

7. Confirm NetworkManager exposes the same value (if it is running):

   ```bash
   nmcli general hostname
   ```

   ```
   lab-node01
   ```

**Check your understanding**

- **Q1.1** — Which of the three hostnames survives a reboot, which is lost, and which file backs each one?
- **Q1.2** — `hostnamectl hostname lab-node01` succeeded, yet `hostname -f` failed. Explain the mechanism: what does `hostname -f` actually do, and which subsystem answered "Name or service not known"?
- **Q1.3** — Debian maps the FQDN to `127.0.1.1` instead of `127.0.0.1`. What breaks if you instead append the FQDN to the `127.0.0.1 localhost` line, and why is `127.0.1.1` (rather than the real LAN address) the safer choice on a DHCP client?
- **Q1.4** — `nmcli general hostname lab-node02` — which file does that command ultimately modify, and through which D-Bus service?

---

## Exercise 2 — The resolver order: `/etc/nsswitch.conf` vs `/etc/resolv.conf`

1. Inspect the name-resolution policy:

   ```bash
   grep -E '^(hosts|networks):' /etc/nsswitch.conf
   ```

   ```
   hosts:          files mdns4_minimal [NOTFOUND=return] dns myhostname
   networks:       files
   ```

2. Add a host-file-only record:

   ```bash
   echo '198.51.100.77  lab-alias.lab.example.internal lab-alias' >> /etc/hosts
   ```

3. Query it two different ways and compare:

   ```bash
   getent hosts lab-alias
   dig +short lab-alias.lab.example.internal
   ```

   ```
   198.51.100.77   lab-alias.lab.example.internal lab-alias
   
   ```

4. Disable the `files` source temporarily. Change the `hosts:` line to:

   ```
   hosts:          dns myhostname
   ```

   then re-query — no daemon restart, no cache flush:

   ```bash
   getent hosts lab-alias
   echo "exit=$?"
   ```

   ```
   exit=2
   ```

5. Restore the original `hosts:` line and verify:

   ```bash
   getent hosts lab-alias >/dev/null && echo restored
   ```

6. Exercise the action syntax. Set:

   ```
   hosts:          files [SUCCESS=continue] dns myhostname
   ```

   ```bash
   getent hosts lab-alias
   ```

   ```
   198.51.100.77   lab-alias.lab.example.internal lab-alias
   ```

   Then restore the original line again.

7. Test the `myhostname` module without any DNS at all:

   ```bash
   getent hosts lab-node01
   getent hosts _gateway
   ```

**Check your understanding**

- **Q2.1** — `getent hosts` found the alias and `dig` did not. Explain precisely which library each tool uses and which configuration file governs each.
- **Q2.2** — What does `[NOTFOUND=return]` mean, and what would change if it were `[NOTFOUND=continue]`? Name the four status keys and the four actions available in that bracket syntax.
- **Q2.3** — Editing `/etc/nsswitch.conf` took effect immediately for a new `getent`, but a long-running daemon kept resolving the old way. Why — and what is the general rule about when NSS configuration is read?
- **Q2.4** — `myhostname` appears *after* `dns` on Debian and *before* it on some other distributions. Give one concrete failure mode caused by each ordering.

---

## Exercise 3 — Who writes `/etc/resolv.conf`?

1. Determine whether the file is real, a symlink, or generated:

   ```bash
   ls -l /etc/resolv.conf
   head -5 /etc/resolv.conf
   ```

   Three common outcomes:

   ```
   # (a) systemd-resolved stub
   lrwxrwxrwx 1 root root 39 Aug 12 09:14 /etc/resolv.conf -> ../run/systemd/resolve/stub-resolv.conf
   nameserver 127.0.0.53
   options edns0 trust-ad
   search lab.example.internal
   ```

   ```
   # (b) NetworkManager writing the file directly
   -rw-r--r-- 1 root root 112 Aug 12 09:14 /etc/resolv.conf
   # Generated by NetworkManager
   search lab.example.internal
   nameserver 192.168.122.1
   ```

   ```
   # (c) openresolv / resolvconf
   lrwxrwxrwx 1 root root 29 Aug 12 09:14 /etc/resolv.conf -> /run/resolvconf/resolv.conf
   ```

2. If `systemd-resolved` is active, inspect the real upstream servers behind the stub:

   ```bash
   resolvectl status
   ```

   ```
   Global
          Protocols: -LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
   resolv.conf mode: stub

   Link 2 (enp1s0)
       Current Scopes: DNS
            Protocols: +DefaultRoute -LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
   Current DNS Server: 192.168.122.1
          DNS Servers: 192.168.122.1
           DNS Domain: lab.example.internal
   ```

3. Prove the anti-pattern. Hand-edit the file and then force the owning daemon to rewrite it:

   ```bash
   sed -i '1i nameserver 203.0.113.53' /etc/resolv.conf
   head -2 /etc/resolv.conf
   systemctl restart NetworkManager    # or: systemctl restart systemd-resolved
   sleep 2
   head -3 /etc/resolv.conf
   ```

   The hand-added line is gone.

4. Make a resolver option persistent *the supported way* (NetworkManager host):

   ```bash
   nmcli connection modify "$(nmcli -g NAME connection show --active | head -1)" \
        ipv4.dns-options "timeout:2,attempts:2,rotate"
   nmcli connection up "$(nmcli -g NAME connection show --active | head -1)"
   grep ^options /etc/resolv.conf
   ```

   ```
   options timeout:2 attempts:2 rotate edns0 trust-ad
   ```

5. Inspect NetworkManager's DNS backend policy:

   ```bash
   grep -rE '^\s*dns\s*=' /etc/NetworkManager/NetworkManager.conf /etc/NetworkManager/conf.d/ 2>/dev/null
   ```

**Check your understanding**

- **Q3.1** — Your hand-edited `nameserver` line vanished after a service restart. List the four candidate owners of `/etc/resolv.conf` covered above and the one-command test that identifies which one is in charge on a given host.
- **Q3.2** — `/etc/resolv.conf` contains only `nameserver 127.0.0.53`, yet queries reach an upstream server on the LAN. Explain the data path, and explain why `dig @127.0.0.53` and `dig @192.168.122.1` can return different answers for the same name.
- **Q3.3** — What is the practical difference between `search` and `domain` in `resolv.conf`, and what does `ndots:` change about when the search list is consulted?
- **Q3.4** — Give the two *legitimate* ways to pin a static resolver on a NetworkManager-managed host permanently, and state the trade-off of each.

---

## Exercise 4 — NetworkManager: persistent profiles with `nmcli`

We use a `dummy` device so nothing you do can strand your session.

1. Create the connection profile — NetworkManager creates the device itself:

   ```bash
   nmcli connection add type dummy ifname lpic0 con-name lab-dummy
   ```

   ```
   Connection 'lab-dummy' (3a5d1e2c-7b4f-4e2a-9c8d-1f0b6a3e5d94) successfully added.
   ```

2. Configure dual-stack static addressing, DNS, a static route, and — critically — **no default route**:

   ```bash
   nmcli connection modify lab-dummy \
        ipv4.method manual \
        ipv4.addresses 192.0.2.10/24 \
        ipv4.dns 192.0.2.53 \
        ipv4.dns-search lab.example.internal \
        ipv4.dns-priority 200 \
        ipv4.never-default yes \
        +ipv4.routes "198.51.100.0/24 192.0.2.1 100" \
        ipv6.method manual \
        ipv6.addresses 2001:db8:cafe::10/64 \
        ipv6.never-default yes \
        connection.autoconnect yes
   ```

3. Activate and verify the runtime result:

   ```bash
   nmcli connection up lab-dummy
   ip -br addr show lpic0
   ip -4 route show dev lpic0
   ```

   ```
   Connection successfully activated (D-Bus active path: /org/freedesktop/NetworkManager/ActiveConnection/4)
   lpic0            UNKNOWN        192.0.2.10/24 2001:db8:cafe::10/64 fe80::9c4b:1eff:fe33:20a1/64
   192.0.2.0/24 proto kernel scope link src 192.0.2.10
   198.51.100.0/24 via 192.0.2.1 proto static metric 100
   ```

4. Read the profile back through the API, then off the disk:

   ```bash
   nmcli -f ipv4.addresses,ipv4.routes,ipv4.dns,connection.autoconnect connection show lab-dummy
   ls -l /etc/NetworkManager/system-connections/
   cat /etc/NetworkManager/system-connections/lab-dummy.nmconnection
   ```

   ```
   -rw------- 1 root root 372 Aug 27 11:02 lab-dummy.nmconnection
   ```

   ```ini
   [connection]
   id=lab-dummy
   uuid=3a5d1e2c-7b4f-4e2a-9c8d-1f0b6a3e5d94
   type=dummy
   autoconnect=true
   interface-name=lpic0

   [dummy]

   [ipv4]
   address1=192.0.2.10/24
   dns=192.0.2.53;
   dns-priority=200
   dns-search=lab.example.internal;
   method=manual
   never-default=true
   route1=198.51.100.0/24,192.0.2.1,100

   [ipv6]
   addr-gen-mode=default
   address1=2001:db8:cafe::10/64
   method=manual
   never-default=true

   [proxy]
   ```

5. Edit the keyfile by hand and make NetworkManager notice:

   ```bash
   sed -i 's/^dns=192.0.2.53;/dns=192.0.2.53;198.51.100.53;/' \
       /etc/NetworkManager/system-connections/lab-dummy.nmconnection
   nmcli -f ipv4.dns connection show lab-dummy      # still the OLD value
   nmcli connection reload
   nmcli -f ipv4.dns connection show lab-dummy      # now updated
   nmcli connection up lab-dummy
   ```

6. Prove persistence — reboot, then re-verify:

   ```bash
   systemctl reboot
   # after login:
   ip -br addr show lpic0
   nmcli -f NAME,DEVICE,STATE connection show --active | grep lab-dummy
   ```

7. Contrast a *persistent* profile with a *transient* device-level override:

   ```bash
   resolvectl dns lpic0 203.0.113.53      # runtime only, if systemd-resolved is the backend
   nmcli connection up lab-dummy          # profile reasserts itself
   ```

**Check your understanding**

- **Q4.1** — Why does this lab forbid setting `ipv4.gateway` on the dummy interface, and what exactly does `ipv4.never-default yes` prevent?
- **Q4.2** — After hand-editing the keyfile, `nmcli connection show` still reported the old DNS server. Explain the two-layer model (on-disk plugin vs in-memory settings) and name the command that reconciles them. Which command would instead have *overwritten* your edit?
- **Q4.3** — What is the difference between `nmcli connection modify ipv4.dns 1.1.1.1` and `nmcli connection modify +ipv4.dns 1.1.1.1`? What does the `-` prefix do?
- **Q4.4** — `connection.autoconnect` is `yes` and the device exists, but the profile does not come up at boot. Give three independent causes, and the command that distinguishes each.
- **Q4.5** — `ipv4.dns-priority 200`: what does a *lower* number mean, and in which scenario does this setting decide which server ends up first in `resolv.conf`?

---

## Exercise 5 — Debian ifupdown: `/etc/network/interfaces`

Run this exercise on a Debian-family system with the `ifupdown` package. First, keep NetworkManager from fighting over the device.

1. Mark the lab device unmanaged by NetworkManager:

   ```bash
   cat > /etc/NetworkManager/conf.d/99-lab-unmanaged.conf <<'EOF'
   [keyfile]
   unmanaged-devices=interface-name:lpic1
   EOF
   nmcli general reload
   ```

2. Confirm the include directive is present in the main file:

   ```bash
   grep -n 'source' /etc/network/interfaces
   ```

   ```
   3:source /etc/network/interfaces.d/*
   ```

3. Create a drop-in stanza. **Note the filename has no dot or dash** — `run-parts`-style include rules ignore files with extensions in some configurations, so use a plain name:

   ```bash
   cat > /etc/network/interfaces.d/lpic1 <<'EOF'
   # Lab interface for LPIC-1 objective 109.2
   auto lpic1
   iface lpic1 inet static
       address 198.51.100.10/24
       dns-nameservers 198.51.100.53
       dns-search lab.example.internal
       pre-up  ip link show lpic1 >/dev/null 2>&1 || ip link add lpic1 type dummy
       post-up ip route add 203.0.113.0/24 via 198.51.100.1 dev lpic1
       pre-down ip route del 203.0.113.0/24 via 198.51.100.1 dev lpic1 || true
       post-down ip link del lpic1 || true

   iface lpic1 inet6 static
       address 2001:db8:beef::10/64
   EOF
   ```

4. Dry-run the parser before applying it:

   ```bash
   ifquery lpic1
   ifquery --list --allow=auto
   ```

   ```
   address: 198.51.100.10/24
   dns-nameservers: 198.51.100.53
   dns-search: lab.example.internal
   ...
   ```

5. Bring it up and inspect:

   ```bash
   ifup lpic1
   ip -br addr show lpic1
   ip -4 route show dev lpic1
   ifquery --state lpic1
   cat /run/network/ifstate
   ```

   ```
   lpic1            UNKNOWN        198.51.100.10/24 2001:db8:beef::10/64 fe80::4c6a:5eff:fe91:11c3/64
   198.51.100.0/24 proto kernel scope link src 198.51.100.10
   203.0.113.0/24 via 198.51.100.1 dev lpic1
   lpic1=lpic1
   ```

6. Test idempotency and the down path:

   ```bash
   ifup lpic1
   ```

   ```
   ifup: interface lpic1 already configured
   ```

   ```bash
   ifdown lpic1
   ip link show lpic1
   ```

   ```
   Device "lpic1" does not exist.
   ```

7. Reboot and confirm the interface returns without any manual command:

   ```bash
   systemctl reboot
   # after login:
   ip -br addr show lpic1
   ```

8. Examine the `dns-nameservers` plumbing:

   ```bash
   ls /etc/resolvconf/ 2>/dev/null || echo "resolvconf not installed"
   grep -R 198.51.100.53 /etc/resolv.conf /run/resolvconf/ 2>/dev/null
   ```

**Check your understanding**

- **Q5.1** — Distinguish `auto lpic1`, `allow-hotplug lpic1`, and a stanza with neither. Which one brings the interface up when a USB NIC is plugged in after boot, and which one does `ifup -a` act on?
- **Q5.2** — Order the five hook types (`pre-up`, `up`/`post-up`, `down`/`pre-down`, `post-down`) relative to the address configuration, and explain why the route was added in `post-up` rather than `pre-up`.
- **Q5.3** — `dns-nameservers` is in the stanza but `/etc/resolv.conf` never changes. What component is missing, and what is the exact chain from the stanza to the file?
- **Q5.4** — `ifdown lpic1` returns "interface lpic1 not configured" even though the address is clearly present in `ip addr`. Which file did ifupdown consult to reach that conclusion, and how do you recover the interface cleanly?
- **Q5.5** — The stanza declares both `inet static` and `inet6 static` for the same interface. How many address families does a single `ifup lpic1` configure, and how would you bring up only IPv6?

---

## Exercise 6 — systemd-networkd: `.netdev`, `.network`, and match ordering

1. Enable the stack (only on a host where NetworkManager is *not* managing the lab device):

   ```bash
   systemctl enable --now systemd-networkd
   systemctl is-active systemd-networkd
   ```

2. Declare the virtual device:

   ```bash
   cat > /etc/systemd/network/10-lpic2.netdev <<'EOF'
   [NetDev]
   Name=lpic2
   Kind=dummy
   EOF
   ```

3. Declare its addressing:

   ```bash
   cat > /etc/systemd/network/10-lpic2.network <<'EOF'
   [Match]
   Name=lpic2

   [Network]
   Address=203.0.113.10/24
   Address=2001:db8:f00d::10/64
   DNS=203.0.113.53
   Domains=~lab.example.internal
   IPv6AcceptRA=no
   LinkLocalAddressing=ipv6

   [Route]
   Destination=192.0.2.0/24
   Gateway=203.0.113.1
   Metric=200
   EOF
   chmod 0644 /etc/systemd/network/10-lpic2.netdev /etc/systemd/network/10-lpic2.network
   ```

4. Apply without restarting the daemon (systemd ≥ 244):

   ```bash
   networkctl reload
   networkctl status lpic2
   ```

   ```
   ● 5: lpic2
                      Link File: /usr/lib/systemd/network/99-default.link
                   Network File: /etc/systemd/network/10-lpic2.network
                          State: routable (configured)
                   Online state: online
                           Type: ether
                          Kind: dummy
                        Address: 203.0.113.10
                                 2001:db8:f00d::10
                                 fe80::30c1:9aff:fe7d:4e02
                            DNS: 203.0.113.53
                 Search Domains: ~lab.example.internal
   ```

5. Verify the route and the resolver scope:

   ```bash
   ip -4 route show dev lpic2
   resolvectl domain lpic2
   resolvectl dns lpic2
   ```

   ```
   203.0.113.0/24 proto kernel scope link src 203.0.113.10
   192.0.2.0/24 via 203.0.113.1 proto static metric 200
   Link 5 (lpic2): ~lab.example.internal
   Link 5 (lpic2): 203.0.113.53
   ```

6. Demonstrate lexical precedence. Create a second, broader match:

   ```bash
   cat > /etc/systemd/network/05-catchall.network <<'EOF'
   [Match]
   Name=lpic*

   [Network]
   Address=10.99.99.99/24
   EOF
   networkctl reload
   networkctl status lpic2 | grep 'Network File'
   ```

   ```
                   Network File: /etc/systemd/network/05-catchall.network
   ```

7. Remove the catch-all and restore correct behaviour:

   ```bash
   rm /etc/systemd/network/05-catchall.network
   networkctl reload
   networkctl status lpic2 | grep 'Network File'
   ```

8. List every link and its verdict:

   ```bash
   networkctl list
   ```

   ```
   IDX LINK   TYPE     OPERATIONAL SETUP
     1 lo     loopback carrier     unmanaged
     2 enp1s0 ether    routable    unmanaged
     5 lpic2  ether    routable    configured
   ```

**Check your understanding**

- **Q6.1** — Only one `.network` file applies to a given link. State the selection rule exactly, and explain why `05-catchall.network` won over `10-lpic2.network` even though the latter matched more specifically.
- **Q6.2** — What does `SETUP: unmanaged` mean for `enp1s0` in step 8, and why is that the *correct* outcome on a host where NetworkManager owns that NIC?
- **Q6.3** — Name the three unit types systemd-networkd reads from `/etc/systemd/network/` and state the single responsibility of each.
- **Q6.4** — What is the difference between `Domains=lab.example.internal` and `Domains=~lab.example.internal` in resolver behaviour?
- **Q6.5** — Compare `networkctl reload`, `networkctl reconfigure lpic2`, and `systemctl restart systemd-networkd` in terms of blast radius. Which one would you run on a production host reached over SSH through the interface being changed?

---

## Exercise 7 — Coexistence, conflicts, and diagnosis drill

You now have up to three stacks on one host. This exercise injects three realistic faults and asks you to isolate each from evidence, not from memory.

### Fault A — the invisible keyfile

1. Break the permissions and reload:

   ```bash
   chmod 0644 /etc/NetworkManager/system-connections/lab-dummy.nmconnection
   nmcli connection reload
   nmcli -f NAME,DEVICE connection show | grep lab-dummy || echo "profile gone"
   ```

2. Read the daemon's own account (exact wording varies by NetworkManager version):

   ```bash
   journalctl -u NetworkManager -n 30 --no-pager | grep -i keyfile
   ```

   ```
   NetworkManager[812]: <warn>  [1756...] keyfile: load: "/etc/NetworkManager/system-connections/lab-dummy.nmconnection": file permissions (644) are insecure, ignoring file
   ```

3. Repair and confirm recovery:

   ```bash
   chmod 0600 /etc/NetworkManager/system-connections/lab-dummy.nmconnection
   nmcli connection reload
   nmcli -f NAME,DEVICE connection show | grep lab-dummy
   ```

### Fault B — the typo in `[Match]`

1. Inject it:

   ```bash
   sed -i 's/^Name=lpic2$/Name=lpci2/' /etc/systemd/network/10-lpic2.network
   networkctl reload
   networkctl status lpic2 | grep -E 'Network File|State'
   ```

   ```
                   Network File: n/a
                          State: off (unmanaged)
   ```

2. Diagnose, then repair:

   ```bash
   grep -rn '^Name=' /etc/systemd/network/
   sed -i 's/^Name=lpci2$/Name=lpic2/' /etc/systemd/network/10-lpic2.network
   networkctl reload
   networkctl status lpic2 | grep State
   ```

### Fault C — two owners, one interface

1. Hand the ifupdown-managed device back to NetworkManager and watch the contention:

   ```bash
   rm /etc/NetworkManager/conf.d/99-lab-unmanaged.conf
   nmcli general reload
   ifup lpic1
   nmcli device status | grep lpic1
   ip -br addr show lpic1
   ```

   ```
   lpic1   ethernet  connected  Wired connection 2
   lpic1            UNKNOWN        198.51.100.10/24 169.254.x.x/16 ...
   ```

2. Restore single ownership:

   ```bash
   nmcli device set lpic1 managed no
   cat > /etc/NetworkManager/conf.d/99-lab-unmanaged.conf <<'EOF'
   [keyfile]
   unmanaged-devices=interface-name:lpic1
   EOF
   nmcli general reload
   nmcli device status | grep lpic1
   ```

   ```
   lpic1   ethernet  unmanaged  --
   ```

**Check your understanding**

- **Q7.1** — Fault A produced *no error at all* from `nmcli connection reload`; the profile simply ceased to exist. What is the security rationale for that behaviour, and which log source is authoritative when `nmcli` is silent?
- **Q7.2** — In Fault B, `networkctl status` reported `Network File: n/a`. Why is that message strictly more useful than "interface down", and what does it prove about where the fault is *not*?
- **Q7.3** — In Fault C, the interface ended up with both a static address and a link-local `169.254.0.0/16` address. Reconstruct the sequence of events that produces that specific combination.
- **Q7.4** — Compare the three mechanisms for excluding a device from NetworkManager: `nmcli device set <dev> managed no`, `unmanaged-devices=` in `conf.d`, and `NM_CONTROLLED=no` in a legacy ifcfg file. Which survive a reboot, and which survive a NetworkManager restart?
- **Q7.5** — Write the one-line rule you would put in a runbook for deciding which stack owns a given interface on an unfamiliar host.

---

## Exercise 8 — Cleanup and final verification

1. Remove everything created above:

   ```bash
   nmcli connection delete lab-dummy
   rm -f /etc/systemd/network/10-lpic2.netdev /etc/systemd/network/10-lpic2.network
   networkctl reload
   ifdown lpic1 2>/dev/null
   rm -f /etc/network/interfaces.d/lpic1
   rm -f /etc/NetworkManager/conf.d/99-lab-unmanaged.conf
   nmcli general reload
   sed -i '/lab-alias/d' /etc/hosts
   ```

2. Diff the live state against the baseline you captured in Exercise 0:

   ```bash
   ip -br addr show | diff /root/baseline-addr.txt - && echo "addresses restored"
   ip -4 route show | diff /root/baseline-route4.txt - && echo "IPv4 routes restored"
   ip -6 route show | diff /root/baseline-route6.txt - && echo "IPv6 routes restored"
   ```

3. Reboot and diff once more — a clean diff *before* reboot but a dirty one *after* means a persistent artefact was missed:

   ```bash
   systemctl reboot
   # after login:
   ip -br addr show | diff /root/baseline-addr.txt -
   ```

**Check your understanding**

- **Q8.1** — Why is the post-reboot diff the only one that actually proves cleanup succeeded?
- **Q8.2** — You deleted `10-lpic2.netdev` but the `lpic2` device is still present until reboot. Explain why, and give the command that removes it immediately.
- **Q8.3** — Write the four-file checklist you would inspect, in order, to fully document the persistent network configuration of an unknown Linux host in an audit.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 0

**A0.1** — On Debian, `networking.service` (ifupdown) and `NetworkManager.service` routinely coexist: ifupdown handles interfaces declared in `/etc/network/interfaces` and NetworkManager handles everything else, precisely because NetworkManager's ifupdown plugin defaults to leaving those devices alone. It becomes a bug the moment **both stacks claim the same interface** — evidence: an interface listed in `/etc/network/interfaces` that also appears as `connected` (not `unmanaged`) in `nmcli device status`.

**A0.2** — (1) A reboot — the kernel's address table is entirely in memory. (2) Any action that flushes or re-runs configuration on that link: `ip addr flush`, `ifdown`/`ifup`, `nmcli connection up`, `networkctl reconfigure`, a DHCP lease renewal that replaces the address, or a restart of the managing daemon. `systemctl restart sshd` touches none of these — it restarts an unrelated userspace daemon and never talks to the netlink address table, so surviving it demonstrates nothing.

**A0.3** — (1) The stanza lacks `auto`/`allow-hotplug`, so `ifup -a` never brought it up and NetworkManager configured the device instead — test: `ifquery --list --allow=auto` (the interface will be absent) plus `nmcli device status`. (2) `networking.service` is disabled or failed, so the file is never read — test: `systemctl status networking`. A third possibility worth checking: the stanza names a predictable interface name (`enp1s0`) that no longer matches the actual kernel name — test: `ip -br link`.

### Exercise 1

**A1.1** — **Static** survives reboot, stored in `/etc/hostname`. **Transient** (kernel `CONFIG_HOSTNAME` value, typically set by a DHCP client or by `hostname(1)`) is lost at reboot and is only used when the static hostname is unset or is `localhost`. **Pretty** — a free-form UTF-8 label — survives reboot in `/etc/machine-info` as `PRETTY_HOSTNAME=` and is never used for networking.

**A1.2** — `hostname -f` does not read any hostname file. It takes the current node name and resolves it through the NSS `hosts` database (`gethostbyname`-family call), returning the canonical name of the first result. The failure came from NSS: no `files` entry matched `lab-node01` and DNS had no record for it either, so the lookup returned "not found". Setting the static hostname changes what is *asked*, not what *answers*.

**A1.3** — If you append the FQDN to the `127.0.0.1 localhost` line, the canonical name of `127.0.0.1` becomes the FQDN, so software that reverse-resolves the loopback (mailers, some RPC and cluster daemons) sees the host's public name attached to `localhost`, which breaks HELO/identity checks and confuses `hostname -f` consumers. `127.0.1.1` gives the FQDN a dedicated loopback address without disturbing `localhost`. Using the real LAN address is wrong on a DHCP client because the address changes and the stale `/etc/hosts` line then resolves the machine's own name to an address it no longer owns — a hard-to-trace source of self-connection failures.

**A1.4** — It writes `/etc/hostname`, indirectly: `nmcli` sends a D-Bus request to NetworkManager, which forwards it to `systemd-hostnamed` (`org.freedesktop.hostname1`), and that service is the only writer of the file. This is the same path `hostnamectl` uses.

### Exercise 2

**A2.1** — `getent hosts` calls the glibc NSS resolver (`libnss_*` modules), driven by `/etc/nsswitch.conf`; because `files` is listed there, `/etc/hosts` is consulted. `dig` is a DNS-protocol tool from BIND utilities: it bypasses NSS entirely, reads only `/etc/resolv.conf` for its default server and sends a real DNS query. `/etc/hosts` is invisible to it by design. (`host` and `nslookup` behave the same way; `ping` and `curl` use NSS.)

**A2.2** — `[NOTFOUND=return]` means: if the preceding source authoritatively answered "this name does not exist", stop the lookup and return that result instead of trying later sources. With `continue`, the resolver would fall through to the next source (e.g. `dns`) after a negative answer. Status keys: `SUCCESS`, `NOTFOUND`, `UNAVAIL`, `TRYAGAIN` (each may be negated with `!`). Actions: `return`, `continue`, `merge` (glibc ≥ 2.24, valid for `SUCCESS`), and the implicit default per status.

**A2.3** — glibc reads `/etc/nsswitch.conf` when the NSS machinery is first initialised in a process and caches the parsed configuration for that process's lifetime; `getent` is a fresh process each time, so it sees the change immediately. A long-running daemon keeps its cached configuration (and, if `nscd`/`systemd-resolved` caching is in play, cached answers as well) until it is restarted. General rule: NSS configuration changes apply to newly started processes; existing ones must be restarted.

**A2.4** — `myhostname` **after** `dns`: if a DNS zone contains a stale record for the local hostname, the machine resolves its own name to the wrong address — the local fallback never gets consulted. `myhostname` **before** `dns`: a legitimate DNS record for the host's own name (e.g. its public service address in a split-horizon zone) is shadowed by the module's synthetic answer, so the host reaches itself over loopback/link-local when it should have used the routed address.

### Exercise 3

**A3.1** — Candidates: (a) `systemd-resolved`, (b) NetworkManager writing the file directly, (c) `resolvconf`/`openresolv`, (d) a static hand-maintained file. Identifying test: `ls -l /etc/resolv.conf` — a symlink into `/run/systemd/resolve/` means resolved, a symlink into `/run/resolvconf/` or `/run/NetworkManager/` names the owner directly, and a regular file whose first line is `# Generated by NetworkManager` identifies NetworkManager. If it is a plain file with no generator header, cross-check with `grep -rE '^\s*dns\s*=' /etc/NetworkManager/` for `dns=none`.

**A3.2** — `127.0.0.53:53` is the `systemd-resolved` **stub listener**. Applications send ordinary DNS queries there through NSS or the resolver library; resolved applies its per-link configuration (search domains, routing domains, DNSSEC/DoT policy, cache) and forwards to the upstream server it learned from the link's configuration. `dig @127.0.0.53` therefore exercises the whole resolved policy stack including its cache and negative caching, while `dig @192.168.122.1` bypasses it and asks the upstream directly — different answers reveal a stale cache, a routing-domain rule sending the query to a different link's server, or a DNSSEC validation failure inside resolved.

**A3.3** — `domain` sets a **single** default domain appended to unqualified names; `search` sets an ordered **list** (up to 6 entries, 256 characters total in glibc) tried in sequence. They are mutually exclusive — the last one to appear in the file wins. `ndots:N` sets the threshold: a query containing **fewer than N** dots is tried against the search list first; at or above N it is tried as an absolute name first. The default is `ndots:1`, which is why `host.lab` (one dot) is sent absolute before the search list is used.

**A3.4** — (1) Put the servers in the connection profile: `nmcli connection modify <name> ipv4.dns <ip>` plus `ipv4.ignore-auto-dns yes` — trade-off: correct and per-link, but must be repeated for every profile that can be active. (2) Set `dns=none` in `/etc/NetworkManager/NetworkManager.conf` and maintain `/etc/resolv.conf` yourself (or point it at your own file) — trade-off: one authoritative place, but you lose per-link DNS entirely, including VPN split-DNS, and DHCP-provided servers are ignored on every interface.

### Exercise 4

**A4.1** — A gateway on the connection installs a **default route** through a device that discards every packet; depending on metric it can win against your real default route and blackhole all traffic, including the SSH session you are working over. `ipv4.never-default yes` tells NetworkManager never to install a default route from this profile, even if one is offered by DHCP or configured — the interface's on-link and static routes still apply.

**A4.2** — NetworkManager keeps connection settings in memory, populated by the settings plugins (`keyfile` reading `/etc/NetworkManager/system-connections/`, plus `ifcfg-rh`/`ifupdown` on some distributions) at startup. `nmcli` reads and writes the in-memory copy over D-Bus; NetworkManager writes it back to disk. Editing the file directly changes only the on-disk copy, so the two diverge until `nmcli connection reload` (or `nmcli connection load <file>`) re-reads it. Conversely, any `nmcli connection modify` before reloading would have serialised the stale in-memory settings back to disk and **destroyed your edit**.

**A4.3** — Bare `ipv4.dns 1.1.1.1` **replaces** the entire property value with that single entry. `+ipv4.dns 1.1.1.1` **appends** to the existing multi-valued property. `-ipv4.dns 1.1.1.1` removes a specific value (a numeric index may be given instead of the value). The `+`/`-` forms are only valid for multi-valued properties such as `ipv4.dns`, `ipv4.addresses`, `ipv4.routes`.

**A4.4** — (1) The profile is bound to a device that does not exist at boot time or whose name/MAC does not match `connection.interface-name` / `802-3-ethernet.mac-address` — distinguish with `nmcli -f connection.interface-name connection show <name>` against `ip -br link`. (2) Another profile with higher `connection.autoconnect-priority` claimed the device — distinguish with `nmcli -f NAME,AUTOCONNECT,AUTOCONNECT-PRIORITY,DEVICE connection show`. (3) The device is unmanaged (`unmanaged-devices=` in `conf.d`, `nmcli device set … managed no`, or the ifupdown plugin) — distinguish with `nmcli device status`. A fourth: activation failed and `may-fail=false` on a family that never came up — visible in `journalctl -u NetworkManager -b`.

**A4.5** — Lower numeric value = **higher** priority: the servers of the connection with the lowest `dns-priority` are placed first in the generated resolver configuration. It decides the ordering whenever more than one connection is active simultaneously and each supplies DNS servers — the classic case being a VPN profile (which normally sets a low/negative priority) versus the LAN profile. A negative value additionally makes that connection's servers *exclusive*, suppressing the others entirely.

### Exercise 5

**A5.1** — `auto lpic1` marks the interface for configuration by `ifup -a`, which is what `networking.service` runs at boot — it is applied unconditionally at that point, whether or not the device exists yet. `allow-hotplug lpic1` marks it for configuration by `ifup --allow=hotplug` triggered from a udev rule, i.e. when the kernel announces the device — this is the one that handles a USB NIC plugged in after boot. A stanza with neither is configured only by an explicit manual `ifup lpic1`. `ifup -a` acts on the `auto` class only.

**A5.2** — Order: `pre-up` → address/route configuration from the stanza → `up`/`post-up` (synonyms), and on teardown `pre-down`/`down` (synonyms) → address deconfiguration → `post-down`. The static route was added in `post-up` because it requires `198.51.100.10/24` to already be on the link — a `via 198.51.100.1` next hop is only reachable once the on-link prefix route exists, so the same command in `pre-up` fails with `Error: Nexthop has invalid gateway`. Symmetrically, the route is deleted in `pre-down`, before the address disappears.

**A5.3** — The missing component is the `resolvconf` (or `openresolv`) package. Chain: `ifup` runs the hook scripts in `/etc/network/if-up.d/`, one of which is `000resolvconf`; it pipes the stanza's `dns-nameservers`/`dns-search` values into `resolvconf -a lpic1.inet`; resolvconf merges all registered sources by interface order into `/run/resolvconf/resolv.conf`, to which `/etc/resolv.conf` is a symlink. Without the package, `dns-nameservers` is parsed and then silently discarded.

**A5.4** — ifupdown consults its state file, `/run/network/ifstate` — an interface is "configured" only if it is recorded there, regardless of the kernel's actual address table. A reboot, a manual `ip addr add`, or a crashed `ifup` desynchronises the two. Recovery: `ifup --force lpic1` to re-mark and reconfigure it, or bring it down explicitly with `ifdown --force lpic1` first; in the worst case remove the stale entry from `/run/network/ifstate` and re-run `ifup`.

**A5.5** — One `ifup lpic1` configures **both** families: modern Debian ifupdown processes every `iface` stanza matching the name and the requested address families. To act on one family only, use `ifup -6 lpic1` / `ifdown -6 lpic1` (equivalently `ifup lpic1=lpic1 --family inet6` on older versions), or name the stanza explicitly with the `iface lpic1 inet6` form and the `--family` selector.

### Exercise 6

**A6.1** — systemd-networkd sorts all `*.network` files in `/etc/systemd/network/`, `/run/systemd/network/` and `/usr/lib/systemd/network/` by **filename in lexical order** and applies the **first file whose `[Match]` section matches** the link; all remaining files are ignored for that link. Specificity of the match is irrelevant. `05-catchall.network` sorts before `10-lpic2.network`, matched `lpic*`, and therefore won. This is exactly why the convention is to number files with a two-digit prefix, most specific first.

**A6.2** — `unmanaged` means no `.network` file matched that link, so systemd-networkd will not touch it — it neither configures nor deconfigures it. That is the correct outcome when NetworkManager owns `enp1s0`: the two daemons can run on the same host as long as their match sets are disjoint. A `SETUP: configured` on an interface that NetworkManager also has `connected` is the conflict signature.

**A6.3** — `.netdev` — **creates** virtual devices (dummy, bridge, bond, vlan, veth, wireguard, …); it defines existence, not addressing. `.network` — **configures** an existing link: addresses, routes, DHCP, DNS, RA behaviour, bridge/bond membership. `.link` — **link-layer properties applied by udev** at device appearance: interface naming policy, MAC address, MTU, offloads, ring/queue settings. `.link` files are read by `systemd-udevd`, not by networkd, which is why changing one may require regenerating the initramfs to take effect at boot.

**A6.4** — `Domains=lab.example.internal` is a **search domain**: unqualified names get it appended, *and* it implicitly routes queries for that domain to this link's servers. `Domains=~lab.example.internal` (tilde prefix) is a **routing-only domain**: it is never appended to unqualified names, it only tells `systemd-resolved` "send queries under this domain to this link's DNS servers". The tilde form is what makes split-DNS over a VPN work without polluting the search list; `Domains=~.` routes *all* queries to that link.

**A6.5** — `networkctl reload` re-reads the configuration files and applies changes only to links whose configuration actually changed — smallest blast radius. `networkctl reconfigure lpic2` forcibly re-applies configuration to one named link, briefly deconfiguring it — scoped, but disruptive to that link. `systemctl restart systemd-networkd` restarts the daemon and reconfigures every managed link — largest blast radius and the one that can drop your session. On a production host reached through the interface you are changing: `networkctl reload`.

### Exercise 7

**A7.1** — A keyfile may contain secrets (PSKs, 802.1X passwords, VPN credentials). NetworkManager refuses to load a file in `system-connections/` whose permissions expose it beyond root, because loading it would be an implicit endorsement of a file the system has already leaked. It skips the file rather than failing loudly so that one bad file cannot prevent the rest of the configuration from loading — which is exactly why the failure is invisible at the `nmcli` layer. The authoritative source is the daemon log: `journalctl -u NetworkManager -b`. Correct permissions are `0600`, owner `root:root`.

**A7.2** — `Network File: n/a` states that networkd evaluated its file set and found **no matching configuration**, which localises the fault to the `[Match]` section or to file placement/naming — and simultaneously proves the fault is *not* in the addressing, the routes, the device itself, or the daemon's health. "Interface down" would be consistent with a dozen unrelated causes; this message eliminates all of them.

**A7.3** — `ifup lpic1` created the dummy device in its `pre-up` hook and assigned `198.51.100.10/24`. Because the `unmanaged-devices` rule had been removed and NetworkManager had been reloaded, NetworkManager saw a new, managed, carrier-bearing device with no matching profile, so it applied its default behaviour: auto-create a `Wired connection N` profile with `ipv4.method auto`, run DHCP, get no answer on an isolated dummy link, and fall back to IPv4 link-local (`169.254.0.0/16`) autoconfiguration. The result is the static address from ifupdown plus the link-local address from NetworkManager on the same link — two owners, two addresses.

**A7.4** — `nmcli device set <dev> managed no` is **runtime only**: it is lost on reboot and on a NetworkManager restart. `unmanaged-devices=` in `/etc/NetworkManager/conf.d/*.conf` (or `NetworkManager.conf`) is **persistent**: it survives both reboot and restart, and it is the correct mechanism. `NM_CONTROLLED=no` in an `ifcfg-*` file is persistent but only on distributions that still build the `ifcfg-rh` plugin (RHEL/CentOS-family, deprecated in RHEL 9+ in favour of keyfiles) — it has no effect on Debian-family systems.

**A7.5** — "For interface *X*: run `nmcli device status`, `networkctl list`, and `ifquery --list --allow=auto`; exactly one of them must claim *X*. Whichever does is the owner, and its configuration file is the only place to make persistent changes; if two claim it, exclude it from all but one before changing anything."

### Exercise 8

**A8.1** — Pre-reboot the interfaces may look clean simply because you tore them down at runtime; that says nothing about what remains on disk. Persistent artefacts — a leftover `.netdev`, an `auto` stanza in an `interfaces.d` drop-in, an autoconnect profile — only re-assert themselves when the boot-time configuration path runs again. A clean post-reboot diff is the only evidence that no configuration file was left behind.

**A8.2** — `.netdev` files are only consulted when creating devices; removing the file plus `networkctl reload` stops the device from being *recreated* at the next boot but does not delete an already-existing kernel device, because networkd does not destroy virtual devices it no longer has configuration for. Remove it immediately with `ip link del lpic2`.

**A8.3** — In order: (1) `/etc/hostname` and `/etc/hosts` — node identity and static mappings. (2) `/etc/nsswitch.conf` and `/etc/resolv.conf` (including `ls -l` to identify its owner) — resolution policy and servers. (3) The addressing configuration of whichever stack is authoritative: `/etc/NetworkManager/system-connections/*.nmconnection` + `/etc/NetworkManager/conf.d/`, `/etc/network/interfaces` + `/etc/network/interfaces.d/`, and `/etc/systemd/network/*.{link,netdev,network}`. (4) The service state that decides which of those files is actually read: `systemctl is-enabled NetworkManager systemd-networkd networking`.

</details>

---

## Sources

- LPI — Exam 101-500 objectives (LPIC-1 v5.0): <https://www.lpi.org/our-certifications/exam-101-objectives/>
- LPI — Exam 102-500 objectives, Topic 109 "Networking Fundamentals": <https://www.lpi.org/our-certifications/exam-102-objectives/>
- `hostnamectl(1)` / `hostname(5)` / `machine-info(5)`: <https://www.freedesktop.org/software/systemd/man/latest/hostnamectl.html>
- `nsswitch.conf(5)`, GNU C Library NSS: <https://www.gnu.org/software/libc/manual/html_node/Name-Service-Switch.html>
- `resolv.conf(5)` — man-pages project: <https://man7.org/linux/man-pages/man5/resolv.conf.5.html>
- `systemd-resolved.service(8)` and `resolvectl(1)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd-resolved.service.html>
- NetworkManager — `nmcli(1)`, `nm-settings-keyfile(5)`, `NetworkManager.conf(5)`: <https://networkmanager.dev/docs/api/latest/>
- Debian — `interfaces(5)` (ifupdown): <https://manpages.debian.org/stable/ifupdown/interfaces.5.en.html>
- `systemd.network(5)`, `systemd.netdev(5)`, `systemd.link(5)`, `networkctl(1)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.network.html>
- RFC 5737 (IPv4 documentation prefixes) and RFC 3849 (IPv6 documentation prefix): <https://www.rfc-editor.org/rfc/rfc5737> · <https://www.rfc-editor.org/rfc/rfc3849>