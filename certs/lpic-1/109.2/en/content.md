# 109.2 — Persistent Network Configuration

*LPIC-1, Exam 102-500, v5.0 — Topic 109: Networking Fundamentals*

---

## 1. The architectural problem: runtime state is not configuration

Every Linux host carries **two independent network states**, and confusing them is the single most common cause of "it worked until we rebooted" incidents.

| Plane | Where it lives | Lifetime | Mutated by |
|---|---|---|---|
| **Runtime plane** | Kernel structures: `netdev` list, `struct in_ifaddr`, FIB tables, neighbour cache | Until reboot, link event, or daemon reconciliation | `ip`, `ifconfig`, `route`, netlink from any daemon |
| **Configuration plane** | Files on disk: `/etc/network/interfaces`, `*.nmconnection`, `*.network`, `/etc/netplan/*.yaml` | Persistent | Editor, `nmcli`, `netplan`, cloud-init, Ansible |

`ip addr add 10.20.0.5/24 dev enp1s0` writes only to the runtime plane. It survives no reboot, and — worse — it does not even survive a *carrier flap* if a reconciling daemon (NetworkManager, systemd-networkd, `wicked`) owns that interface, because those daemons re-apply their declared state on every `RTM_NEWLINK` event. A `netlink` race with an operator's manual `ip` command is invisible in `dmesg` and looks like "the address randomly disappeared".

The production discipline that follows from this:

> **Single-writer principle.** Exactly one component may own an interface's configuration. Two owners (e.g. NetworkManager *and* `ifupdown`, or netplan-generated `systemd-networkd` *and* a hand-written `.network` file) produce non-deterministic boot behaviour that depends on unit ordering and udev event timing.

Persistence in Linux is not one problem but **three orthogonal planes**, each with its own file set, its own daemon and its own failure mode:

1. **Identity** — the hostname (`/etc/hostname`, `hostnamectl`, `systemd-hostnamed`).
2. **Topology** — interface names, addresses, routes, bonds, VLANs, bridges.
3. **Resolution** — `/etc/hosts`, `/etc/nsswitch.conf`, `/etc/resolv.conf`.

A host can boot with a perfect L3 topology and still be functionally dead because plane 3 was overwritten by a DHCP client. LPI tests all three under this single objective.

### 1.1 Why this matters beyond the exam

On a Kubernetes node, the three planes map directly onto cluster-visible behaviour:

- The **static hostname** normally becomes the `kubelet --hostname-override` default and therefore the `Node` object's name. A hostname that changes at boot (DHCP-supplied, non-persistent) registers a *second* `Node` and orphans the first, with all its `Pod` objects.
- The **address plane** determines `InternalIP`. A NIC that comes up with a DHCP address instead of its declared static one shifts the node IP and breaks kubelet↔apiserver mTLS SANs.
- The **resolver plane** on the host is what `dnsPolicy: Default` pods inherit, and a stray `options ndots:5` or a 127.0.0.53 stub address copied into a container is the classic "DNS is slow in the cluster" root cause.

---

## 2. Identity plane: interface names must be persistent before addresses can be

You cannot persist `Address=10.20.0.5/24` on `eth0` if `eth0` is `eth1` on the next boot. Kernel enumeration order for PCI devices is not stable: it depends on probe order, which depends on driver load order, which depends on initrd contents and SMP timing.

### 2.1 Predictable Network Interface Names

`systemd-udevd` renames interfaces during coldplug using the `net_id` builtin. The name is built from a **prefix** plus a **policy-selected suffix**:

| Element | Values | Meaning |
|---|---|---|
| Prefix | `en`, `wl`, `ww`, `sl`, `ib`, `nl` | Ethernet, WLAN, WWAN, SLIP, InfiniBand, NetLink |
| `o<index>` | `eno1` | On-board index from firmware (SMBIOS / DT) |
| `s<slot>[f<fn>][d<dev>]` | `ens3`, `ens1f0` | PCI hotplug slot index |
| `p<bus>s<slot>` | `enp3s0`, `enp0s31f6` | PCI geographical location |
| `x<MAC>` | `enx001b638445e6` | MAC-derived |
| `d<n>` / `i<n>` | `enp2s0d1` | Device/port on multi-port cards |

Policy order is declared by `NamePolicy=` in `.link` files, default from `/usr/lib/systemd/network/99-default.link`:

```ini
[Match]
OriginalName=*

[Link]
NamePolicy=keep kernel database onboard slot path
AlternativeNamesPolicy=database onboard slot path
MACAddressPolicy=persistent
```

Inspect what udev derives for a device — this is the authoritative debugging command:

```console
$ udevadm test-builtin net_id /sys/class/net/enp1s0 2>/dev/null
ID_NET_NAMING_SCHEME=v252
ID_NET_NAME_MAC=enx525400a1b2c3
ID_OUI_FROM_DATABASE=QEMU Virtual NIC
ID_NET_NAME_PATH=enp1s0
ID_NET_NAME_SLOT=ens1
```

```console
$ udevadm info /sys/class/net/enp1s0 | grep -E 'ID_NET_NAME|ID_PATH='
E: ID_NET_NAME_MAC=enx525400a1b2c3
E: ID_NET_NAME_PATH=enp1s0
E: ID_PATH=pci-0000:01:00.0
```

### 2.2 Pinning a name yourself (`.link` file)

The supported way to force a name — never `udev` `NAME=` rules for network devices on systemd hosts, and never both:

```ini
# /etc/systemd/network/10-mgmt0.link
[Match]
MACAddress=52:54:00:a1:b2:c3

[Link]
Name=mgmt0
MACAddressPolicy=none
```

```console
# udevadm control --reload
# udevadm trigger --action=add --subsystem-match=net
# ip -br link show mgmt0
mgmt0            UP             52:54:00:a1:b2:c3 <BROADCAST,MULTICAST,UP,LOWER_UP>
```

**Trap:** if the interface is brought up by the initramfs (root on NFS/iSCSI, network-bound LUKS), the `.link` file must also be inside the initrd:

```console
# dracut -f --regenerate-all          # RHEL/Fedora
# update-initramfs -u -k all          # Debian/Ubuntu
```

**Trap:** names must not collide with the kernel's own namespace during rename. Renaming `eth0` → `eth1` while `eth1` exists fails with `EEXIST`; udev logs `Could not rename interface`. Use a name the kernel would never generate (`mgmt0`, `wan0`, `stor0`).

### 2.3 Disabling predictable names (legacy compatibility)

| Method | Scope | Notes |
|---|---|---|
| `net.ifnames=0` kernel cmdline | All NICs | Reverts to `eth*`; add `biosdevname=0` on Dell hardware |
| `ln -s /dev/null /etc/systemd/network/99-default.link` | All NICs | Masks the default policy; survives systemd upgrades better than editing `/usr/lib` |
| `net.naming-scheme=v247` | All NICs | Freezes the naming *algorithm* version across a distro upgrade — the correct fix when an upgrade renames NICs |

`net.naming-scheme=` is the underused one. Upgrading RHEL 8 → 9 or Debian 11 → 12 can change `ens1f0` to `ens1f0np0` because the scheme learned about phys-port-names. Freezing the scheme keeps every existing declaration valid.

---

## 3. The configuration-plane landscape

Five components compete for ownership. Knowing which distro ships which — and which is a *frontend* rather than an owner — is examinable and operationally decisive.

| Stack | Config location | Daemon | Model | Typical distro | Reconciles on link event | Rollback |
|---|---|---|---|---|---|---|
| **ifupdown** | `/etc/network/interfaces`, `interfaces.d/` | none (scripts + `ifup@.service`) | Imperative, one-shot at boot | Debian (minimal/server installs) | ❌ no | none |
| **NetworkManager** | `/etc/NetworkManager/system-connections/*.nmconnection` | `NetworkManager.service` | Declarative, stateful, event-driven | RHEL/Fedora/CentOS Stream, Ubuntu Desktop | ✅ yes | manual (`nmcli con up`) |
| **systemd-networkd** | `/etc/systemd/network/*.{link,netdev,network}` | `systemd-networkd.service` | Declarative, stateless daemon | Ubuntu Server (via netplan), containers, minimal images | ✅ yes | none built-in |
| **netplan** | `/etc/netplan/*.yaml` | *renders to* NM or networkd | Declarative frontend, no runtime | Ubuntu 18.04+ | via backend | ✅ `netplan try` |
| **wicked** | `/etc/sysconfig/network/ifcfg-*` | `wicked.service` | Declarative | SLES/openSUSE ≤15 | ✅ yes | none |
| **cloud-init** | `/etc/cloud/cloud.cfg.d/`, datasource | one-shot at first boot | Bootstrapper that *writes* one of the above | All cloud images | ❌ (writes then exits) | n/a |

### 3.1 Choosing an owner — trade-offs

| Criterion | ifupdown | NetworkManager | systemd-networkd |
|---|---|---|---|
| Footprint | ~200 KB shell | ~30 MB, D-Bus, polkit | in systemd, ~2 MB |
| Roaming / WiFi / WWAN | poor | excellent | none (needs `wpa_supplicant` glue) |
| Handles hotplug NIC | `allow-hotplug` only | native | native |
| Idempotent partial apply | ❌ | ✅ `device reapply` | ⚠️ `networkctl reload` (no L2 changes) |
| DNS management | delegates to `resolvconf` | built-in plugin system | via `systemd-resolved` only |
| API for automation | none | D-Bus, `nmstate`, Ansible `nmcli` | files only |
| Config validation | none | `nmcli` rejects bad values at set time | `systemd-analyze verify`-ish, weak |
| Fits immutable/golden images | ✅ | ⚠️ mutable state in `/etc` | ✅ (files can live in `/usr/lib`) |
| Fits desktop/laptop | ❌ | ✅ | ❌ |
| Recommended for | legacy Debian fleets | RHEL-family servers, any host with wireless | Ubuntu servers, minimal container hosts, appliances |

**Production heuristic:** on RHEL-family, do not fight NetworkManager — it is the only supported path since RHEL 8 and `network-scripts` was removed entirely in RHEL 9. On Ubuntu Server, do not bypass netplan; write netplan YAML and let it render `systemd-networkd`. On a hand-built minimal image, `systemd-networkd` gives the smallest reconciling surface.

---

## 4. Hostname persistence

### 4.1 Three hostnames, not one

`systemd-hostnamed` exposes three values over D-Bus:

| Kind | Storage | Format constraints | Set by |
|---|---|---|---|
| **static** | `/etc/hostname` | RFC 1123 label(s), ≤ 64 bytes (`HOST_NAME_MAX`), `[a-zA-Z0-9-.]` | administrator, cloud-init |
| **transient** | kernel, via `sethostname(2)` | same | DHCP client, container runtime, `hostname` command |
| **pretty** | `/etc/machine-info` → `PRETTY_HOSTNAME=` | free-form UTF-8 | administrator |

Precedence at boot: `systemd-hostnamed` sets the kernel hostname from `/etc/hostname`; if that file is absent or contains `localhost`, the transient name from DHCP (option 12 / option 81) wins.

`/etc/hostname` format: **one line, one name, no comments in the classic implementations, no trailing whitespace**. systemd accepts `#` comments and ignores blank lines, but Debian's `hostname.sh` init historically did not — do not rely on it.

```console
$ cat /etc/hostname
node01.prod.example.net

$ hostnamectl
 Static hostname: node01.prod.example.net
       Icon name: computer-vm
         Chassis: vm 🖴
      Machine ID: 4f3c1a9be6f24d0a8a7e2c5d11b0e9aa
         Boot ID: 9a1f0c73b2ee4c1e9f6d55a2c48b3d10
  Virtualization: kvm
Operating System: Debian GNU/Linux 12 (bookworm)
          Kernel: Linux 6.1.0-18-amd64
    Architecture: x86-64
 Hardware Vendor: QEMU
  Hardware Model: Standard PC _Q35 + ICH9, 2009_
```

```console
# hostnamectl set-hostname node01.prod.example.net
# hostnamectl set-hostname "Prod Node 01 — Rack B14" --pretty
# hostnamectl hostname --static
node01.prod.example.net
```

`hostnamectl set-hostname NAME` without a qualifier sets **static + transient** (and pretty, if the string is not a valid DNS label). `hostname NAME` sets **only the transient** name and is lost on reboot — this distinction is a favourite exam item.

```console
$ hostname                 # transient (kernel)
node01
$ hostname -f              # FQDN via resolver — requires /etc/hosts or DNS to answer
node01.prod.example.net
$ hostname -d              # domain part as resolved
prod.example.net
$ hostname -I              # all configured addresses, no DNS lookup
10.20.0.5 fd00:20::5
```

**`hostname -f` performs a name lookup.** If `/etc/hosts` has no matching entry and DNS is down, it fails or hangs — which is why every production host carries a static `/etc/hosts` entry for itself.

### 4.2 Stopping DHCP from renaming the host

| Stack | Directive |
|---|---|
| NetworkManager | `nmcli con mod <name> ipv4.dhcp-send-hostname no` and global `hostname-mode=none` in `[main]` of `NetworkManager.conf` |
| systemd-networkd | `[DHCPv4] UseHostname=false` and `SendHostname=false` |
| dhclient | remove `host-name` from the `request` list in `/etc/dhcp/dhclient.conf` |
| cloud-init | `preserve_hostname: true` in `/etc/cloud/cloud.cfg` |

```ini
# /etc/NetworkManager/conf.d/00-hostname.conf
[main]
hostname-mode=none
```

### 4.3 The `/etc/hosts` self-entry convention

Debian writes a **`127.0.1.1`** line so that the FQDN resolves even with no network; RHEL puts the real address on the interface line. Both are valid; mixing them is where the trouble starts.

```
# /etc/hosts — Debian convention
127.0.0.1       localhost
127.0.1.1       node01.prod.example.net node01

::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
```

```
# /etc/hosts — RHEL/production-cluster convention
127.0.0.1       localhost localhost.localdomain localhost4
::1             localhost localhost.localdomain localhost6

10.20.0.5       node01.prod.example.net node01
10.20.0.6       node02.prod.example.net node02
10.20.0.7       node03.prod.example.net node03
```

> **Production rule for clustered software** (etcd, Kubernetes, Ceph, RabbitMQ, Pacemaker): the node's FQDN **must** resolve to its routable address, not to `127.0.1.1`. A `127.0.1.1` self-entry makes peers advertise loopback and the cluster forms a set of one-node partitions. This is the classic "etcd nodes cannot see each other despite ping working" ticket.

---

## 5. Resolution plane 1 — `/etc/hosts` and `/etc/nsswitch.conf`

### 5.1 `/etc/hosts` format

```
IP_address    canonical_hostname    [aliases...]
```

Rules that matter in practice:

- Parsed **top to bottom**; first match wins per address family.
- Fields separated by any whitespace; `#` starts a comment.
- One address may appear on multiple lines; a name resolving to several addresses returns them in file order (no round-robin, no shuffling — unlike DNS).
- Maximum aliases per line is implementation-limited (glibc: effectively `_SC_HOST_NAME_MAX`-bounded buffer, practically dozens).
- IPv4 and IPv6 entries are independent; `getaddrinfo()` merges them under RFC 6724 destination-address selection.

### 5.2 `/etc/nsswitch.conf` — the dispatcher

This file decides **which resolution mechanism is consulted, in which order, and what happens after each result**. It governs far more than hosts.

```
# /etc/nsswitch.conf
passwd:         files systemd
group:          files [SUCCESS=merge] systemd
shadow:         files
gshadow:        files

hosts:          files resolve [!UNAVAIL=return] myhostname dns
networks:       files

protocols:      db files
services:       db files
ethers:         db files
rpc:            db files

netgroup:       nis
automount:      files
```

Syntax: `database: service1 [STATUS=ACTION] service2 ...`

| Status | Meaning |
|---|---|
| `SUCCESS` | Entry found, no error |
| `NOTFOUND` | Lookup succeeded, entry absent |
| `UNAVAIL` | Service permanently unavailable (daemon absent, file missing) |
| `TRYAGAIN` | Service temporarily unavailable (timeout, EAGAIN) |

| Action | Meaning |
|---|---|
| `return` | Stop, return the current result to the caller |
| `continue` | Try the next service |
| `merge` | Merge results (glibc ≥ 2.24, `group` only) |

Default implicit actions: `[SUCCESS=return NOTFOUND=continue UNAVAIL=continue TRYAGAIN=continue]`. `!` negates a status: `[!UNAVAIL=return]` means "for anything **other than** UNAVAIL, return" — i.e. trust `systemd-resolved` unless it is not running at all, in which case fall through.

Relevant NSS modules for `hosts:`:

| Module | Library | Function |
|---|---|---|
| `files` | glibc built-in | `/etc/hosts` |
| `dns` | `libnss_dns.so` | classic resolver, driven by `/etc/resolv.conf` |
| `resolve` | `libnss_resolve.so` | `systemd-resolved` over D-Bus/varlink — bypasses `/etc/resolv.conf` entirely |
| `myhostname` | `libnss_myhostname.so` | synthesises the local hostname, `localhost`, `_gateway`, `_outbound` |
| `mymachines` | `libnss_mymachines.so` | `systemd-nspawn`/machinectl containers |
| `mdns4_minimal` | `libnss_mdns4_minimal.so` | Avahi, `.local` only |

**Ordering trap.** `mdns4_minimal [NOTFOUND=return]` placed before `dns` (Ubuntu default) means any `.local` name never reaches DNS. Sites using `.local` as an internal AD suffix must remove it.

**Verification — each tool takes a different code path:**

```console
$ getent hosts node02              # full NSS stack, exactly what applications see
10.20.0.6       node02.prod.example.net node02

$ getent ahostsv4 node02           # getaddrinfo() path incl. address selection
10.20.0.6       STREAM node02.prod.example.net
10.20.0.6       DGRAM
10.20.0.6       RAW

$ dig +short node02.prod.example.net    # DNS ONLY — ignores /etc/hosts and nsswitch
10.20.0.6
```

> `dig` and `nslookup` speak DNS directly. They **never** read `/etc/hosts` or `/etc/nsswitch.conf`. If `ping node02` works but `dig node02` returns NXDOMAIN, the answer came from `files` — that is not a bug, and it is a guaranteed exam question. Conversely, if `dig` works and the application does not, the fault is in `nsswitch.conf`, not in DNS.

---

## 6. Resolution plane 2 — `/etc/resolv.conf` and the ownership war

### 6.1 Format

```
# /etc/resolv.conf
nameserver 10.20.0.53
nameserver 10.20.1.53
search prod.example.net example.net
options ndots:1 timeout:2 attempts:2 rotate single-request-reopen edns0 trust-ad
```

| Directive | Semantics | Hard limits |
|---|---|---|
| `nameserver` | Upstream resolver IP (v4 or v6) | **`MAXNS` = 3**; extra lines silently ignored |
| `search` | Suffix list appended to short names | `MAXDNSRCH` = 6 domains, 256 chars total |
| `domain` | Single suffix; **mutually exclusive with `search`** — last directive in the file wins | 1 |
| `sortlist` | Address-preference netmask list | 10 |
| `options ndots:n` | Try the name as-is first only if it has ≥ *n* dots | default 1 |
| `options timeout:n` | Seconds per server per try | default 5, max 30 |
| `options attempts:n` | Rounds over the server list | default 2, max 5 |
| `options rotate` | Round-robin the servers instead of always starting at the first | — |
| `options single-request-reopen` | Separate sockets for A and AAAA — workaround for broken firewalls dropping one of the parallel queries | — |
| `options trust-ad` | Propagate the DNSSEC AD bit to applications | glibc ≥ 2.31 |
| `options use-vc` | Force TCP | — |

**Worst-case latency arithmetic** — the reason `timeout:5 attempts:2` with 3 nameservers is a production hazard: a dead first resolver costs `attempts × timeout` per server before failover, i.e. up to `3 × 2 × 5 = 30 s` for a single `getaddrinfo()`. Every synchronous request handler blocked for 30 s is an outage. Production default: `timeout:1 attempts:2` plus `rotate`.

**`ndots` arithmetic** — with `ndots:5` and `search a.svc.cluster.local svc.cluster.local cluster.local`, resolving `api.example.com` (2 dots < 5) issues 3 futile qualified queries (A + AAAA each = 6 packets) before the absolute one. This is the standard Kubernetes DNS-amplification pathology; on the *host* resolver, keep `ndots:1`.

### 6.2 Who writes `/etc/resolv.conf`

This is the highest-frequency persistence failure on Linux servers: an administrator edits the file, it works, and 30 minutes later a DHCP lease renewal reverts it.

| Owner | Trigger | Neutralise with |
|---|---|---|
| `dhclient` | lease bind/renew, via `/etc/dhcp/dhclient-enter-hooks.d/resolvconf` | `supersede domain-name-servers ...;` in `dhclient.conf` |
| NetworkManager | connection activation | `dns=none` in `NetworkManager.conf`, or `ipv4.ignore-auto-dns yes` per connection |
| `systemd-resolved` | uplink DNS change | manage via `resolvectl` / `.network` files, not the file |
| `resolvconf` / `openresolv` | any subscriber | `/etc/resolvconf/resolv.conf.d/{head,base,tail}` |
| netplan | `netplan apply` | `nameservers:` stanza in the YAML |
| cloud-init | first boot | `manage_resolv_conf: false` |

**Determine the current owner before editing anything:**

```console
$ ls -l /etc/resolv.conf
lrwxrwxrwx 1 root root 39 Aug 12 09:14 /etc/resolv.conf -> ../run/systemd/resolve/stub-resolv.conf

$ head -3 /etc/resolv.conf
# This is /run/systemd/resolve/stub-resolv.conf managed by man:systemd-resolved(8).
# Do not edit.
#
```

The symlink target *is* the answer:

| Target | Meaning | `nameserver` value |
|---|---|---|
| `/run/systemd/resolve/stub-resolv.conf` | Full resolved feature set: split-DNS, DNSSEC, per-link DNS | `127.0.0.53` |
| `/run/systemd/resolve/resolv.conf` | resolved writes upstream servers verbatim; no split-DNS | real upstream IPs |
| `/run/NetworkManager/resolv.conf` | NM owns it | real upstream IPs |
| `/usr/lib/systemd/resolv.conf` | static stub pointer, for images | `127.0.0.53` |
| regular file | ifupdown/`resolvconf`/manual | varies |

### 6.3 `systemd-resolved` operation

```console
$ resolvectl status
Global
         Protocols: LLMNR=resolve -mDNS -DNSOverTLS DNSSEC=no/unsupported
  resolv.conf mode: stub

Link 2 (enp1s0)
    Current Scopes: DNS LLMNR/IPv4
         Protocols: +DefaultRoute +LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
Current DNS Server: 10.20.0.53
       DNS Servers: 10.20.0.53 10.20.1.53
        DNS Domain: prod.example.net

Link 3 (vpn0)
    Current Scopes: DNS
         Protocols: +DefaultRoute -LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
Current DNS Server: 172.16.0.53
       DNS Servers: 172.16.0.53
        DNS Domain: ~corp.internal
```

The `~corp.internal` *routing-only domain* is split-DNS: queries for `*.corp.internal` go to the VPN resolver, everything else to the LAN resolver. This capability is the reason for the `127.0.0.53` stub — a flat `/etc/resolv.conf` cannot express per-domain routing.

```console
$ resolvectl query node02.prod.example.net
node02.prod.example.net: 10.20.0.6                    -- link: enp1s0

-- Information acquired via protocol DNS in 1.8ms.
-- Data is authenticated: no; Data was acquired via local or encrypted transport: no
-- Data from: network

# resolvectl flush-caches
# resolvectl statistics | head -8
DNSSEC verdicts
Secure: 0
Insecure: 0
Bogus: 0
Indeterminate: 0

Cache
  Current Transactions: 0
  Cache Size: 41
```

### 6.4 The `chattr +i` question

Making `/etc/resolv.conf` immutable is the internet's favourite advice and a production anti-pattern:

```console
# chattr +i /etc/resolv.conf
# lsattr /etc/resolv.conf
----i---------e------- /etc/resolv.conf
```

It works, and it hides the real defect. The DHCP client will log `open: Permission denied` on every renew, `netplan apply` will fail, and the next operator has an unexplained `EPERM`. Fix the owner instead:

```ini
# /etc/NetworkManager/conf.d/90-dns-none.conf — NM stops touching resolv.conf entirely
[main]
dns=none
rc-manager=unmanaged
```

Reserve `chattr +i` for an emergency during an incident, and record it in the change log.

---

## 7. Complete persistent configurations

All examples target the same production topology so they can be compared directly:

```
  bond0 = enp1s0 + enp2s0   (802.3ad LACP, layer3+4 hash)
    ├── bond0.100  → br-mgmt   10.20.0.5/24    gw 10.20.0.1   (default route, metric 100)
    └── bond0.200  → storage   10.30.0.5/24    MTU 9000, no gateway
  DNS: 10.20.0.53, 10.20.1.53   search prod.example.net
```

### 7.1 ifupdown — Debian classic

```
# /etc/network/interfaces
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

# --- bond slaves -----------------------------------------------------------
auto enp1s0
iface enp1s0 inet manual
    bond-master bond0

auto enp2s0
iface enp2s0 inet manual
    bond-master bond0

# --- LACP bond -------------------------------------------------------------
auto bond0
iface bond0 inet manual
    bond-mode 802.3ad
    bond-slaves enp1s0 enp2s0
    bond-miimon 100
    bond-lacp-rate 1
    bond-xmit-hash-policy layer3+4
    bond-downdelay 200
    bond-updelay 200
    up   ip link set dev bond0 mtu 9000
    post-up ip link set dev bond0 txqueuelen 10000

# --- management VLAN on a bridge ------------------------------------------
auto bond0.100
iface bond0.100 inet manual
    vlan-raw-device bond0

auto br-mgmt
iface br-mgmt inet static
    bridge_ports bond0.100
    bridge_stp off
    bridge_fd 0
    bridge_maxwait 0
    address 10.20.0.5/24
    gateway 10.20.0.1
    dns-nameservers 10.20.0.53 10.20.1.53
    dns-search prod.example.net
    up   ip route add 10.99.0.0/16 via 10.20.0.254 dev br-mgmt
    down ip route del 10.99.0.0/16 || true

iface br-mgmt inet6 static
    address fd00:20::5/64
    gateway fd00:20::1
    accept_ra 0

# --- storage VLAN, jumbo frames, no gateway --------------------------------
auto bond0.200
iface bond0.200 inet static
    vlan-raw-device bond0
    address 10.30.0.5/24
    mtu 9000
```

Semantics that are examinable:

| Keyword | Effect |
|---|---|
| `auto <if>` | Brought up by `ifup -a` at boot, synchronously — boot **blocks** on it |
| `allow-hotplug <if>` | Brought up on the udev `add`/`change` event; correct for removable and slow-link NICs |
| `iface X inet static` | IPv4 static; `inet6` for IPv6; `inet manual` = configure the link, assign no address |
| `inet dhcp` | Runs the configured DHCP client (`dhclient`, `udhcpc`, `dhcpcd`) |
| `pre-up` / `up` / `post-up` | Hooks; a non-zero exit from `pre-up`/`up` aborts the interface |
| `down` / `post-down` | Teardown hooks |
| `source` / `source-directory` | Include fragments; **`source-directory` ignores files with dots in the name** (run-parts rules) |

```console
# ifquery --state                       # what ifupdown believes is up
lo=lo
bond0=bond0
br-mgmt=br-mgmt

# ifquery br-mgmt                       # effective parsed stanza
address: 10.20.0.5/24
gateway: 10.20.0.1
bridge_ports: bond0.100
dns-nameservers: 10.20.0.53 10.20.1.53

# ifdown br-mgmt && ifup -v br-mgmt
Configuring interface br-mgmt=br-mgmt (inet)
ip addr add 10.20.0.5/24 broadcast 10.20.0.255 dev br-mgmt label br-mgmt
ip link set dev br-mgmt up
ip route add default via 10.20.0.1 dev br-mgmt onlink
```

> **`ifupdown` state lives in `/run/network/ifstate`.** If a host is left inconsistent (`ifup` says "already configured" while the interface has no address), the runtime state and the state file diverged — `ip link set dev X down; rm /run/network/ifstate.X; ifup X` recovers it. `ifupdown` never reconciles: it applies once and forgets.

**`ifup`/`ifdown` on RHEL 9+ are shims.** `network-scripts` was removed; `/usr/sbin/ifup` from `NetworkManager-initscripts-updown` simply calls `nmcli connection up`. Legacy `ifcfg-*` files are read by NM's deprecated `ifcfg-rh` plugin (dropped in RHEL 10).

### 7.2 NetworkManager — `nmcli` and the keyfile format

Full imperative build, exactly as it would run in a runbook:

```console
# nmcli connection add type bond ifname bond0 con-name bond0 \
    bond.options "mode=802.3ad,miimon=100,lacp_rate=fast,xmit_hash_policy=layer3+4" \
    ipv4.method disabled ipv6.method disabled connection.autoconnect yes
Connection 'bond0' (2a6a7f1c-8b3e-4f22-9d61-7c0f2b5a1e44) successfully added.

# nmcli connection add type ethernet ifname enp1s0 con-name bond0-p1 master bond0 slave-type bond
Connection 'bond0-p1' (7e1d0c2b-4a55-4b9c-9e02-1f3d6a8c9b70) successfully added.

# nmcli connection add type ethernet ifname enp2s0 con-name bond0-p2 master bond0 slave-type bond
Connection 'bond0-p2' (b0c9e4a1-33d7-4a18-8f5c-2d1b7e6f4a93) successfully added.

# nmcli connection add type vlan ifname bond0.100 con-name mgmt-vlan dev bond0 id 100 \
    ipv4.method manual \
    ipv4.addresses 10.20.0.5/24 \
    ipv4.gateway 10.20.0.1 \
    ipv4.dns "10.20.0.53,10.20.1.53" \
    ipv4.dns-search "prod.example.net" \
    ipv4.dns-priority 100 \
    ipv4.routes "10.99.0.0/16 10.20.0.254" \
    ipv4.route-metric 100 \
    ipv4.may-fail no \
    ipv6.method manual \
    ipv6.addresses fd00:20::5/64 \
    ipv6.gateway fd00:20::1 \
    connection.autoconnect yes
Connection 'mgmt-vlan' (c41f9a02-77be-4d3a-b6a8-5e9c0f21d8b3) successfully added.

# nmcli connection add type vlan ifname bond0.200 con-name storage-vlan dev bond0 id 200 \
    ipv4.method manual ipv4.addresses 10.30.0.5/24 ipv4.never-default yes \
    802-3-ethernet.mtu 9000 ipv6.method disabled
Connection 'storage-vlan' (e5a7c318-2f40-4c99-8b1d-6a0e3d7f5c21) successfully added.

# nmcli connection up mgmt-vlan
Connection successfully activated (D-Bus active path: /org/freedesktop/NetworkManager/ActiveConnection/7)
```

Resulting persisted keyfile — this is the on-disk truth, and knowing it is what lets you review the config in Git:

```ini
# /etc/NetworkManager/system-connections/mgmt-vlan.nmconnection   (mode 0600, root:root)
[connection]
id=mgmt-vlan
uuid=c41f9a02-77be-4d3a-b6a8-5e9c0f21d8b3
type=vlan
interface-name=bond0.100
autoconnect=true
autoconnect-retries=0

[vlan]
flags=1
id=100
parent=bond0

[ipv4]
method=manual
address1=10.20.0.5/24,10.20.0.1
dns=10.20.0.53;10.20.1.53;
dns-search=prod.example.net;
dns-priority=100
route1=10.99.0.0/16,10.20.0.254
route-metric=100
may-fail=false

[ipv6]
method=manual
address1=fd00:20::5/64,fd00:20::1
addr-gen-mode=stable-privacy

[proxy]
```

> **`ipv4.may-fail no`** makes `NetworkManager-wait-online.service` block until IPv4 is actually configured. Without it, a host with `ipv6.method=auto` reports "online" as soon as a link-local address exists, and every `After=network-online.target` unit starts before the IPv4 address is up. This one property fixes the majority of "the service started before the network was ready" bugs.

Keyfiles are hand-editable, but NM must be told:

```console
# chmod 600 /etc/NetworkManager/system-connections/mgmt-vlan.nmconnection
# nmcli connection reload                 # re-read files, no activation
# nmcli device reapply bond0.100          # apply changed L3 settings without dropping the link
Connection successfully reapplied to device 'bond0.100'.
```

`nmcli device reapply` cannot change L2 attributes (MTU, bond mode, slaves). Those require a full `nmcli connection down && nmcli connection up`.

Inspection:

```console
$ nmcli -f NAME,UUID,TYPE,DEVICE connection show
NAME           UUID                                  TYPE      DEVICE
bond0          2a6a7f1c-8b3e-4f22-9d61-7c0f2b5a1e44  bond      bond0
mgmt-vlan      c41f9a02-77be-4d3a-b6a8-5e9c0f21d8b3  vlan      bond0.100
storage-vlan   e5a7c318-2f40-4c99-8b1d-6a0e3d7f5c21  vlan      bond0.200
bond0-p1       7e1d0c2b-4a55-4b9c-9e02-1f3d6a8c9b70  ethernet  enp1s0
bond0-p2       b0c9e4a1-33d7-4a18-8f5c-2d1b7e6f4a93  ethernet  enp2s0

$ nmcli device status
DEVICE     TYPE      STATE                   CONNECTION
bond0      bond      connected               bond0
bond0.100  vlan      connected               mgmt-vlan
bond0.200  vlan      connected               storage-vlan
enp1s0     ethernet  connected (externally)  bond0-p1
enp2s0     ethernet  connected (externally)  bond0-p2
lo         loopback  unmanaged               --

$ nmcli -f IP4 device show bond0.100
IP4.ADDRESS[1]:                         10.20.0.5/24
IP4.GATEWAY:                            10.20.0.1
IP4.ROUTE[1]:                           dst = 10.20.0.0/24, nh = 0.0.0.0, mt = 100
IP4.ROUTE[2]:                           dst = 0.0.0.0/0, nh = 10.20.0.1, mt = 100
IP4.ROUTE[3]:                           dst = 10.99.0.0/16, nh = 10.20.0.254, mt = 100
IP4.DNS[1]:                             10.20.0.53
IP4.DNS[2]:                             10.20.1.53
IP4.SEARCHES[1]:                        prod.example.net
```

Marking an interface unmanaged (e.g. a NIC owned by DPDK, a VF, or a CNI-managed bridge):

```ini
# /etc/NetworkManager/conf.d/99-unmanaged.conf
[keyfile]
unmanaged-devices=interface-name:cali*;interface-name:flannel*;interface-name:cni0;interface-name:veth*;interface-name:vxlan.calico
```

### 7.3 systemd-networkd

Files are processed in **lexicographic order** and the **first matching** `.network` wins per interface — hence the `NN-` numeric prefix convention.

```ini
# /etc/systemd/network/10-bond0.netdev
[NetDev]
Name=bond0
Kind=bond
MTUBytes=9000

[Bond]
Mode=802.3ad
TransmitHashPolicy=layer3+4
MIIMonitorSec=100ms
LACPTransmitRate=fast
UpDelaySec=200ms
DownDelaySec=200ms
```

```ini
# /etc/systemd/network/11-vlan100.netdev
[NetDev]
Name=bond0.100
Kind=vlan

[VLAN]
Id=100
```

```ini
# /etc/systemd/network/12-vlan200.netdev
[NetDev]
Name=bond0.200
Kind=vlan
MTUBytes=9000

[VLAN]
Id=200
```

```ini
# /etc/systemd/network/20-bond-slaves.network
[Match]
Name=enp1s0 enp2s0

[Network]
Bond=bond0
LinkLocalAddressing=no
IPv6AcceptRA=no
```

```ini
# /etc/systemd/network/30-bond0.network
[Match]
Name=bond0

[Network]
VLAN=bond0.100
VLAN=bond0.200
LinkLocalAddressing=no
IPv6AcceptRA=no
ConfigureWithoutCarrier=no
```

```ini
# /etc/systemd/network/40-mgmt.network
[Match]
Name=bond0.100

[Link]
RequiredForOnline=routable

[Network]
Address=10.20.0.5/24
Address=fd00:20::5/64
Gateway=10.20.0.1
Gateway=fd00:20::1
DNS=10.20.0.53
DNS=10.20.1.53
Domains=prod.example.net
IPv6AcceptRA=no
IPForward=yes

[Route]
Destination=10.99.0.0/16
Gateway=10.20.0.254
Metric=100

[RoutingPolicyRule]
From=10.20.0.5/32
Table=100
Priority=1000
```

```ini
# /etc/systemd/network/41-storage.network
[Match]
Name=bond0.200

[Link]
MTUBytes=9000
RequiredForOnline=carrier

[Network]
Address=10.30.0.5/24
LinkLocalAddressing=no
IPv6AcceptRA=no
DHCP=no
```

```console
# networkctl reload            # re-read .network files, apply what can be applied live
# networkctl reconfigure bond0.100
# networkctl list
IDX LINK      TYPE     OPERATIONAL SETUP
  1 lo        loopback carrier     unmanaged
  2 enp1s0    ether    enslaved    configured
  3 enp2s0    ether    enslaved    configured
  4 bond0     bond     carrier     configured
  5 bond0.100 vlan     routable    configured
  6 bond0.200 vlan     routable    configured

6 links listed.

# networkctl status bond0.100
● 5: bond0.100
                     Link File: /usr/lib/systemd/network/99-default.link
                  Network File: /etc/systemd/network/40-mgmt.network
                          Type: vlan
                         State: routable (configured)
                  Online state: online
                        Driver: 802.1Q VLAN Support
                           MTU: 1500
                       Address: 10.20.0.5 (static)
                                fd00:20::5 (static)
                       Gateway: 10.20.0.1
                           DNS: 10.20.0.53
                                10.20.1.53
                Search Domains: prod.example.net
```

`SETUP` values are the diagnostic: `configured` (a `.network` matched and applied), `unmanaged` (no match, networkd is not touching it), `failed` (matched but application errored — check `journalctl -u systemd-networkd`), `pending` (waiting for carrier).

`RequiredForOnline=` determines what `systemd-networkd-wait-online.service` waits for. Set it to `no` on the storage NIC so a down storage switch does not delay boot by 120 s.

### 7.4 netplan (Ubuntu) — full YAML

netplan has **no runtime**: it renders to `systemd-networkd` unit files (or NM keyfiles) under `/run/`, then hands control over.

```yaml
# /etc/netplan/50-production.yaml     (must be mode 0600 — netplan >= 0.106 warns otherwise)
network:
  version: 2
  renderer: networkd

  ethernets:
    enp1s0:
      match:
        macaddress: "52:54:00:a1:b2:c3"
      set-name: enp1s0
      dhcp4: false
      dhcp6: false
      mtu: 9000
    enp2s0:
      match:
        macaddress: "52:54:00:a1:b2:c4"
      set-name: enp2s0
      dhcp4: false
      dhcp6: false
      mtu: 9000

  bonds:
    bond0:
      interfaces: [enp1s0, enp2s0]
      mtu: 9000
      parameters:
        mode: 802.3ad
        lacp-rate: fast
        mii-monitor-interval: 100
        transmit-hash-policy: layer3+4
        up-delay: 200
        down-delay: 200
      dhcp4: false
      dhcp6: false

  vlans:
    bond0.100:
      id: 100
      link: bond0
      dhcp4: false
      dhcp6: false
    bond0.200:
      id: 200
      link: bond0
      mtu: 9000
      dhcp4: false
      dhcp6: false
      addresses:
        - 10.30.0.5/24

  bridges:
    br-mgmt:
      interfaces: [bond0.100]
      parameters:
        stp: false
        forward-delay: 0
      addresses:
        - 10.20.0.5/24
        - "fd00:20::5/64"
      nameservers:
        addresses: [10.20.0.53, 10.20.1.53]
        search: [prod.example.net, example.net]
      routes:
        - to: default
          via: 10.20.0.1
          metric: 100
          on-link: true
        - to: "::/0"
          via: "fd00:20::1"
          metric: 100
        - to: 10.99.0.0/16
          via: 10.20.0.254
          metric: 200
        - to: 0.0.0.0/0
          via: 10.20.0.1
          table: 100
      routing-policy:
        - from: 10.20.0.5/32
          table: 100
          priority: 1000
      accept-ra: false
      link-local: []
```

```console
# netplan get bridges.br-mgmt.addresses
- 10.20.0.5/24
- fd00:20::5/64

# netplan generate                # render only; no apply. Fails loudly on schema errors
# ls /run/systemd/network/
10-netplan-bond0.netdev  10-netplan-bond0.network  10-netplan-br-mgmt.netdev
10-netplan-br-mgmt.network  10-netplan-bond0.100.netdev  10-netplan-bond0.100.network
10-netplan-enp1s0.link  10-netplan-enp1s0.network  10-netplan-enp2s0.link  10-netplan-enp2s0.network

# netplan try --timeout 90
Do you want to keep these settings?

Press ENTER before the timeout to accept the new configuration

Changes will revert in 87 seconds
```

```console
# netplan status --all
     Online state: online
    DNS Addresses: 10.20.0.53
                   10.20.1.53
       DNS Search: prod.example.net
                   example.net

●  4: bond0 bond UP (networkd: bond0)
      MAC Address: 52:54:00:a1:b2:c3
       Addresses: -
●  6: br-mgmt bridge UP (networkd: br-mgmt)
      MAC Address: 52:54:00:a1:b2:c3
        Addresses: 10.20.0.5/24
                   fd00:20::5/64
           Routes: default via 10.20.0.1 from 10.20.0.5 metric 100 (static)
                   10.20.0.0/24 from 10.20.0.5 metric 0 (link)
                   10.99.0.0/16 via 10.20.0.254 metric 200 (static)
```

**`netplan try` is the only stack with built-in rollback**, and it is the correct way to touch the network on a remote host over the very link you are changing. Its equivalent for other stacks is a scheduled dead-man's switch:

```console
# systemd-run --on-active=300 --timer-property=AccuracySec=1s \
    /bin/sh -c 'cp /root/net-backup/*.nmconnection /etc/NetworkManager/system-connections/ && nmcli connection reload && nmcli connection up mgmt-vlan'
Running timer as unit: run-r7d0a1.timer
Will run service as unit: run-r7d0a1.service
```

Apply the change; if you are still connected, `systemctl stop run-r7d0a1.timer`. If you are not, the box restores itself in five minutes.

netplan file precedence: files in `/run/netplan` override `/etc/netplan` override `/lib/netplan`, and within each, lexicographic order — later files **merge and override** earlier keys. `/etc/netplan/99-override.yaml` beats `/etc/netplan/50-cloud-init.yaml`.

### 7.5 cloud-init — the first-boot writer

Cloud images generate network config on first boot from the datasource, and it **overwrites hand-made config** unless disabled. Network config v2 is netplan's schema verbatim.

```yaml
# /etc/cloud/cloud.cfg.d/50-network.cfg
network:
  version: 2
  ethernets:
    enp1s0:
      dhcp4: false
      addresses: [10.20.0.5/24]
      routes:
        - to: default
          via: 10.20.0.1
      nameservers:
        addresses: [10.20.0.53, 10.20.1.53]
        search: [prod.example.net]
```

```yaml
# /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
# Hand control to the local stack permanently — do this once the host is provisioned.
network: {config: disabled}
```

```yaml
# /etc/cloud/cloud.cfg.d/98-hostname.cfg
preserve_hostname: true
manage_etc_hosts: false
manage_resolv_conf: false
```

```console
$ cloud-init query --format '{{ds.meta_data.hostname}}' 2>/dev/null
node01
$ cloud-init schema --system --annotate
Valid schema /var/lib/cloud/instances/i-0ab3/cloud-config.txt
$ cloud-init status --long
status: done
extended_status: done
boot_status_code: enabled-by-generator
last_update: Tue, 12 Aug 2026 09:14:22 +0000
```

### 7.6 Fleet-level: Ansible

```yaml
# roles/network/tasks/main.yml
---
- name: Ensure static hostname is persistent
  ansible.builtin.hostname:
    name: "{{ inventory_hostname }}"
    use: systemd

- name: Ensure self-entry in /etc/hosts points at the routable address
  ansible.builtin.lineinfile:
    path: /etc/hosts
    regexp: '^\S+\s+{{ inventory_hostname }}\b'
    line: "{{ mgmt_ipv4 }} {{ inventory_hostname }} {{ inventory_hostname.split('.')[0] }}"
    state: present
    owner: root
    group: root
    mode: "0644"

- name: Remove the Debian 127.0.1.1 self-entry (breaks cluster peer discovery)
  ansible.builtin.lineinfile:
    path: /etc/hosts
    regexp: '^127\.0\.1\.1\s'
    state: absent

- name: Pin the hosts NSS order
  ansible.builtin.lineinfile:
    path: /etc/nsswitch.conf
    regexp: '^hosts:'
    line: 'hosts:          files resolve [!UNAVAIL=return] myhostname dns'

- name: Declare the management connection (NetworkManager)
  community.general.nmcli:
    conn_name: mgmt-vlan
    ifname: bond0.100
    type: vlan
    vlanid: 100
    vlandev: bond0
    ip4: "{{ mgmt_ipv4 }}/24"
    gw4: 10.20.0.1
    dns4: [10.20.0.53, 10.20.1.53]
    dns4_search: [prod.example.net]
    method4: manual
    may_fail4: false
    autoconnect: true
    state: present
  notify: reapply network

- name: Verify the config survives a cold start (offline validation)
  ansible.builtin.command: nmcli --offline connection show
  changed_when: false
  register: nm_offline
  failed_when: "'mgmt-vlan' not in nm_offline.stdout"
```

---

## 8. Apply and rollback semantics — the operator's cheat sheet

| Operation | ifupdown | NetworkManager | systemd-networkd | netplan |
|---|---|---|---|---|
| Reload config, no apply | n/a | `nmcli connection reload` | `networkctl reload` | `netplan generate` |
| Apply to one interface | `ifdown X && ifup X` | `nmcli device reapply X` | `networkctl reconfigure X` | `netplan apply` (global) |
| Full re-apply | `systemctl restart networking` | `systemctl restart NetworkManager` | `systemctl restart systemd-networkd` | `netplan apply` |
| Safe remote apply | — | `systemd-run --on-active` dead-man | same | **`netplan try`** |
| Changes L2 (MTU/bond) live | ✅ via hooks | ❌ needs down/up | ⚠️ partial | ⚠️ backend-dependent |
| Validate before apply | none | `nmcli --offline connection show` | none | `netplan generate` |

> Restarting `NetworkManager.service` does **not** drop active connections by default (`[main] no-auto-default`, plus NM adopts existing devices), whereas restarting `systemd-networkd` can briefly flush addresses on interfaces whose `.network` changed. Neither is a safe remote operation without a dead-man's switch.

---

## 9. Verification and diagnosis

### 9.1 The verification ladder — cheapest and most decisive first

```console
# 1. Is the config plane syntactically valid?  (before touching anything)
$ netplan generate && echo OK
OK
$ nmcli --offline connection show < /etc/NetworkManager/system-connections/mgmt-vlan.nmconnection
$ ifquery --list --allow=auto

# 2. Is L1/L2 up?  Carrier and speed come from the driver, not from your config.
$ ip -br link
lo               UNKNOWN        00:00:00:00:00:00 <LOOPBACK,UP,LOWER_UP>
enp1s0           UP             52:54:00:a1:b2:c3 <BROADCAST,MULTICAST,SLAVE,UP,LOWER_UP>
enp2s0           UP             52:54:00:a1:b2:c3 <BROADCAST,MULTICAST,SLAVE,UP,LOWER_UP>
bond0            UP             52:54:00:a1:b2:c3 <BROADCAST,MULTICAST,MASTER,UP,LOWER_UP>
bond0.100        UP             52:54:00:a1:b2:c3 <BROADCAST,MULTICAST,UP,LOWER_UP>

$ ethtool enp1s0 | grep -E 'Speed|Duplex|Link detected'
	Speed: 10000Mb/s
	Duplex: Full
	Link detected: yes

$ cat /proc/net/bonding/bond0
Ethernet Channel Bonding Driver: v6.1.0-18-amd64
Bonding Mode: IEEE 802.3ad Dynamic link aggregation
Transmit Hash Policy: layer3+4 (1)
MII Status: up
802.3ad info
LACP active: on
LACP rate: fast
Aggregator ID: 1
Number of ports: 2

# 3. Is L3 configured, and does it match the declaration?
$ ip -br -4 addr
lo               UNKNOWN        127.0.0.1/8
bond0.100        UP             10.20.0.5/24
bond0.200        UP             10.30.0.5/24

$ ip route show
default via 10.20.0.1 dev bond0.100 proto static metric 100
10.20.0.0/24 dev bond0.100 proto kernel scope link src 10.20.0.5 metric 100
10.30.0.0/24 dev bond0.200 proto kernel scope link src 10.30.0.5
10.99.0.0/16 via 10.20.0.254 dev bond0.100 proto static metric 200

$ ip route get 8.8.8.8
8.8.8.8 via 10.20.0.1 dev bond0.100 src 10.20.0.5 uid 0
    cache

# 4. Is the identity plane right?
$ hostnamectl hostname --static
node01.prod.example.net
$ getent hosts $(hostname -s)
10.20.0.5       node01.prod.example.net node01

# 5. Is the resolution plane right?  Three independent probes:
$ getent hosts node02             # NSS: what applications see
$ resolvectl query node02         # resolved: which link answered
$ dig @10.20.0.53 node02.prod.example.net +short   # the server itself
```

`proto` in `ip route` is the provenance field and answers "who put this route here": `kernel` (implied by an address), `static` (a config file), `dhcp`, `ra`, `boot` (added by a script with no proto), `bird`/`bgp` (a routing daemon).

### 9.2 The only test that proves persistence

Nothing above proves the config survives a reboot; it proves the runtime state is currently correct. The actual test:

```console
# ip -br addr > /root/pre-reboot.txt && ip route >> /root/pre-reboot.txt
# systemctl reboot
...
$ ip -br addr > /root/post-reboot.txt && ip route >> /root/post-reboot.txt
$ diff /root/pre-reboot.txt /root/post-reboot.txt && echo "PERSISTENCE VERIFIED"
PERSISTENCE VERIFIED
```

For a host you cannot reboot, the closest approximation is a full stack restart plus a carrier flap:

```console
# ip link set dev enp1s0 down && sleep 3 && ip link set dev enp1s0 up
# systemctl restart NetworkManager
# ip -br addr | diff - /root/pre-reboot-addr.txt
```

### 9.3 Boot-time forensics

```console
$ journalctl -b -u NetworkManager --no-pager | head -20
Aug 27 08:12:03 node01 NetworkManager[812]: <info>  [1756282323.4412] NetworkManager (version 1.42.4) is starting... (boot:9a1f0c73)
Aug 27 08:12:03 node01 NetworkManager[812]: <info>  [1756282323.4589] manager[0x55c1...]: rfkill: Wi-Fi hardware radio set enabled
Aug 27 08:12:04 node01 NetworkManager[812]: <info>  [1756282324.1023] device (bond0.100): state change: config -> ip-config (reason 'none')
Aug 27 08:12:04 node01 NetworkManager[812]: <info>  [1756282324.3310] device (bond0.100): state change: ip-config -> activated

$ journalctl -b -u systemd-networkd -p warning --no-pager
Aug 27 08:12:05 node01 systemd-networkd[798]: bond0.200: Could not bring up interface: Invalid argument

$ systemd-analyze blame | grep -Ei 'network|wait-online' | head
     31.204s systemd-networkd-wait-online.service
      1.882s NetworkManager.service
      0.421s systemd-resolved.service

$ systemd-analyze critical-chain network-online.target
network-online.target @32.7s
└─systemd-networkd-wait-online.service @1.5s +31.2s
  └─systemd-networkd.service @1.2s +281ms
```

A 30-second `wait-online` is a misconfiguration, not a fact of life: it means the unit is waiting on an interface that never becomes `routable`. Fix it with `RequiredForOnline=no` on the interface in question, or `--interface=` / `--any` on the wait-online unit:

```ini
# /etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --interface=bond0.100:routable --timeout=30
```

### 9.4 Failure catalogue

| Symptom | Most likely cause | Decisive probe | Fix |
|---|---|---|---|
| Address present before reboot, gone after | Applied with `ip addr add`, never written to a config file | `grep -r <ip> /etc/{network,NetworkManager,systemd/network,netplan}` returns nothing | Declare it in the owning stack |
| Address disappears seconds after a manual `ip addr add` | A reconciling daemon owns the interface | `nmcli device status` shows `managed`; `networkctl` shows `configured` | Change the declaration, not the runtime |
| `/etc/resolv.conf` reverts after minutes | DHCP renew / NM / resolved rewrote it | `ls -l /etc/resolv.conf`, `journalctl -u NetworkManager \| grep dns` | Set `dns=none` or configure DNS in the connection |
| NIC name changed after a distro upgrade | udev naming-scheme version bump | `udevadm test-builtin net_id`, `cat /sys/class/net/*/uevent` | `net.naming-scheme=vNNN`, or update declarations |
| Interface exists but has no config | No `.network`/connection matched | `networkctl status X` shows `unmanaged` / `nmcli` shows `--` | Fix the `[Match]` / `interface-name` |
| Boot hangs ~2 min at "A start job is running for Wait for Network" | `wait-online` blocking on a NIC without carrier | `systemd-analyze blame` | `RequiredForOnline=no` or `ipv4.may-fail` tuning |
| `ping host` works, `dig host` NXDOMAIN | Answer came from `/etc/hosts` | `getent hosts host` vs `dig host` | Not a bug — but add the DNS record if apps use DNS libs that bypass NSS (Go, JVM) |
| `dig` works, application cannot resolve | `nsswitch.conf` `hosts:` line lacks `dns`, or an early `[NOTFOUND=return]` | `getent hosts X` fails while `dig X` works | Fix the NSS order |
| `hostname -f` hangs several seconds | No self-entry in `/etc/hosts`, resolver timing out | `strace -e trace=connect hostname -f` | Add the self-entry |
| Hostname reverts to a cloud name on reboot | DHCP option 12 / cloud-init | `hostnamectl` shows transient ≠ static | `preserve_hostname: true`, `dhcp-send-hostname no` |
| Two default routes, traffic uses the wrong one | Two connections with `autoconnect` and equal metrics | `ip route show default` shows two entries | `ipv4.never-default yes` on the secondary, or distinct `route-metric` |
| Jumbo frames fail only for large payloads | MTU persisted on the VLAN but not the parent/bond | `ping -M do -s 8972 <peer>` fails, `-s 1472` works | Set MTU on parent **and** child; parent MTU ≥ child MTU |
| `nmcli connection up` says success, no address | `ipv4.method` left `disabled`/`auto` while addresses were set | `nmcli -f ipv4 connection show <name>` | `ipv4.method manual` |
| Keyfile edited by hand is ignored | Mode not 0600, or NM not reloaded | `nmcli connection show` lacks it; `journalctl -u NetworkManager \| grep -i permission` | `chmod 600` + `nmcli connection reload` |

```console
# The MTU probe worth memorising — 8972 = 9000 - 20 (IP) - 8 (ICMP)
$ ping -M do -s 8972 -c 2 10.30.0.6
PING 10.30.0.6 (10.30.0.6) 8972(9000) bytes of data.
8980 bytes from 10.30.0.6: icmp_seq=1 ttl=64 time=0.213 ms
8980 bytes from 10.30.0.6: icmp_seq=2 ttl=64 time=0.198 ms
```

---

## 10. Recap: the examinable surface

| File / tool | Owns | One-line rule |
|---|---|---|
| `/etc/hostname` | Static hostname | One line, one name; read by `systemd-hostnamed` at boot |
| `hostnamectl` | static / transient / pretty | `set-hostname` writes `/etc/hostname`; `hostname` alone is transient only |
| `/etc/hosts` | Local static name→IP | Consulted before DNS *if* `files` precedes `dns` in nsswitch |
| `/etc/nsswitch.conf` | NSS source order | `hosts:` line decides whether `/etc/hosts` or DNS is consulted first |
| `/etc/resolv.conf` | Resolver config | `nameserver` (max 3), `search` (max 6), `options ndots/timeout/attempts` |
| `/etc/network/interfaces` | ifupdown declarations | `auto` = boot; `allow-hotplug` = udev event; `inet static/dhcp/manual` |
| `ifup` / `ifdown` | ifupdown apply | State in `/run/network/ifstate`; on RHEL 9+ these are NM shims |
| `nmcli` | NetworkManager | `connection` = persistent profile; `device` = runtime; `modify` persists, `up` activates |
| `*.nmconnection` | NM keyfile store | `/etc/NetworkManager/system-connections/`, mode 0600, `nmcli connection reload` after editing |
| `*.network` / `*.netdev` / `*.link` | systemd-networkd | `/etc/systemd/network/`, lexicographic order, first `[Match]` wins |
| `/etc/netplan/*.yaml` | netplan | Frontend only — renders to networkd or NM; `netplan try` gives rollback |

**High-yield traps:**

1. `ip`/`ifconfig` changes are **never** persistent.
2. `hostname foo` is transient; `hostnamectl set-hostname foo` is persistent.
3. `dig`/`nslookup` **ignore** `/etc/hosts` and `/etc/nsswitch.conf`; `ping`/`getent`/applications do not.
4. `domain` and `search` in `resolv.conf` are mutually exclusive — the last one in the file wins.
5. Only the first **three** `nameserver` lines are used.
6. Editing `/etc/resolv.conf` on a systemd-resolved or NM host is usually a no-op that reverts.
7. On RHEL 8+, `nmcli` is the supported tool; `/etc/sysconfig/network-scripts` is deprecated (RHEL 8) and removed (RHEL 9).
8. On Ubuntu, editing `/etc/systemd/network/` directly conflicts with netplan's generated files in `/run/systemd/network/` — but files in `/etc` win over `/run`, which silently makes netplan's output ineffective and is a nasty split-brain.

---

## 11. References

**LPI — objectives**
- LPIC-1 Exam 101 objectives (v5.0) — https://www.lpi.org/our-certifications/exam-101-objectives/
- LPIC-1 Exam 102 objectives (v5.0), Topic 109.2 — https://www.lpi.org/our-certifications/exam-102-objectives/

**Hostname and identity**
- `hostname(5)` — https://www.freedesktop.org/software/systemd/man/latest/hostname.html
- `hostnamectl(1)` — https://www.freedesktop.org/software/systemd/man/latest/hostnamectl.html
- `systemd-hostnamed.service(8)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-hostnamed.service.html
- `machine-info(5)` — https://www.freedesktop.org/software/systemd/man/latest/machine-info.html

**Name resolution**
- GNU C Library — Name Service Switch — https://www.gnu.org/software/libc/manual/html_node/Name-Service-Switch.html
- `nsswitch.conf(5)` — https://man7.org/linux/man-pages/man5/nsswitch.conf.5.html
- `hosts(5)` — https://man7.org/linux/man-pages/man5/hosts.5.html
- `resolv.conf(5)` — https://man7.org/linux/man-pages/man5/resolv.conf.5.html
- `getent(1)` — https://man7.org/linux/man-pages/man1/getent.1.html
- `systemd-resolved.service(8)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-resolved.service.html
- `resolvectl(1)` — https://www.freedesktop.org/software/systemd/man/latest/resolvectl.html
- `nss-myhostname(8)` — https://www.freedesktop.org/software/systemd/man/latest/nss-myhostname.html

**Interface naming**
- systemd — Predictable Network Interface Names — https://systemd.io/PREDICTABLE_INTERFACE_NAMES/
- `systemd.link(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.link.html
- `systemd.net-naming-scheme(7)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.net-naming-scheme.html

**NetworkManager**
- NetworkManager documentation — https://networkmanager.dev/docs/
- `nmcli(1)` — https://networkmanager.dev/docs/api/latest/nmcli.html
- `nm-settings-keyfile(5)` — https://networkmanager.dev/docs/api/latest/nm-settings-keyfile.html
- `NetworkManager.conf(5)` — https://networkmanager.dev/docs/api/latest/NetworkManager.conf.html
- Red Hat — Configuring and managing networking (RHEL 9) — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_managing_networking/index

**systemd-networkd**
- `systemd.network(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.network.html
- `systemd.netdev(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.netdev.html
- `networkctl(1)` — https://www.freedesktop.org/software/systemd/man/latest/networkctl.html
- `systemd-networkd-wait-online.service(8)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-networkd-wait-online.service.html

**Debian ifupdown**
- `interfaces(5)` — https://manpages.debian.org/stable/ifupdown/interfaces.5.en.html
- Debian Reference — Network setup — https://www.debian.org/doc/manuals/debian-reference/ch05.en.html

**netplan and cloud-init**
- Netplan documentation — https://netplan.readthedocs.io/en/stable/
- Netplan YAML configuration reference — https://netplan.readthedocs.io/en/stable/netplan-yaml/
- Ubuntu Server — Network configuration — https://documentation.ubuntu.com/server/explanation/networking/configuring-networks/
- cloud-init — Network configuration — https://cloudinit.readthedocs.io/en/latest/reference/network-config.html
- cloud-init — Network config v2 — https://cloudinit.readthedocs.io/en/latest/reference/network-config-format-v2.html

**Kernel and tooling**
- `ip(8)` / iproute2 — https://man7.org/linux/man-pages/man8/ip.8.html
- Linux kernel — Bonding driver documentation — https://www.kernel.org/doc/Documentation/networking/bonding.txt
- `dhclient.conf(5)` — https://man.isc.org/dhclient.conf.5
- RFC 6724 — Default Address Selection for IPv6 — https://www.rfc-editor.org/rfc/rfc6724