# 109.4 — Configure client side DNS

**LPIC-1 · Exam 102-500 · Topic 109: Networking Fundamentals**

> **Scope of this objective:** name resolution as consumed by a client host — `/etc/hosts`, `/etc/resolv.conf`, `/etc/nsswitch.conf`, `systemd-resolved`, and the query tools `host`, `dig`, `getent`. Authoritative server operation (BIND, zone files, DNSSEC signing) belongs to LPIC-2 202.x and is out of scope here, except where a client-side flag changes what the server is asked for.

---

## 1. Motivation: the resolver is a shared, undocumented dependency

Every distributed system you operate has an implicit hard dependency that appears in no architecture diagram: the client-side resolver. It is not a service you run, it is a **library linked into every process on the box**, configured by a file that three different daemons believe they own, and consulted before nearly every outbound connection.

The production failure modes are consistently the same four, and all four are client-side:

| Failure mode | Symptom the on-call sees | Actual cause |
|---|---|---|
| **Search-domain amplification** | p99 latency of an HTTP client jumps from 8 ms to 200 ms; DNS QPS at the resolver is 6× the request rate | `options ndots:5` plus a 5-entry `search` list turns one external lookup into 10 queries (A+AAAA per suffix) before the absolute name is tried |
| **Parallel A/AAAA race** | Exactly 5.000 s stalls, intermittently, ~1 in 200 connections | glibc sends A and AAAA from the *same* source port; a race in Netfilter conntrack NAT drops one reply, the resolver waits out `timeout:5` |
| **Split-horizon leakage** | Internal hostname resolves to a public IP (or NXDOMAIN) after a VPN reconnect | A second resolver stack rewrote `/etc/resolv.conf` and dropped the per-interface routing domain |
| **NSS vs. wire divergence** | `dig` returns the right answer, the application connects to the wrong host | `dig` bypasses NSS entirely; the application went through `/etc/hosts` or `nss-myhostname` |

That last row is the single most important conceptual point in this objective, and it is the one most often gotten wrong in incident reviews. **`dig` and `host` are DNS protocol clients. Applications are not.** Applications call `getaddrinfo(3)`, which consults the Name Service Switch, which *may* — depending on `/etc/nsswitch.conf` — never send a DNS packet at all. Any diagnostic that starts and ends with `dig` has verified the wrong layer.

### 1.1 The resolution path, precisely

```
 application
    │  getaddrinfo("api.example.internal", "443", &hints, &res)
    ▼
 glibc NSS dispatcher                     ← reads /etc/nsswitch.conf
    │
    ├─▶ nss_files      → /etc/hosts                      (no network)
    ├─▶ nss_myhostname → local hostname, _gateway, localhost, _outbound
    ├─▶ nss_resolve    → D-Bus to systemd-resolved (org.freedesktop.resolve1)
    └─▶ nss_dns        → glibc stub resolver (libresolv)
                            │  reads /etc/resolv.conf
                            ▼
                         UDP/53 (fallback TCP/53 on TC=1 or use-vc)
                            ▼
                     recursive resolver (127.0.0.53, dnsmasq, unbound, ISP, CoreDNS…)
```

Two independent configuration surfaces exist on that path and they answer different questions:

- **`/etc/nsswitch.conf` decides *which databases are consulted and in what order*.**
- **`/etc/resolv.conf` decides *how the DNS database behaves once reached*.**

Editing the wrong one is the classic wasted hour. If `getent hosts foo` returns a stale answer that `dig foo` does not, the problem is in `nsswitch.conf`/`hosts`. If both agree and both are wrong, the problem is in `resolv.conf` or upstream.

---

## 2. `/etc/hosts` — the static database

The oldest name database on the system, defined by `hosts(5)`. Consulted by `nss_files`, in file order, first match wins. No TTL, no negative caching, no failure mode other than being wrong forever.

```
$ cat /etc/hosts
127.0.0.1       localhost localhost.localdomain
::1             localhost localhost.localdomain ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters

# Canonical hostname of this machine — required by many daemons that
# call gethostname(2) and then resolve the result.
10.42.7.31      node-a.leloir.internal node-a

# Pinned during the 2026-08 registrar migration; remove after TTL drain.
198.51.100.44   artifacts.example.com
```

Format: `IP_address canonical_hostname [alias...]`. Fields are whitespace-separated, `#` starts a comment. The **first** name on the line is the canonical name — this is what a reverse NSS lookup (`getent hosts 10.42.7.31`) returns, and what `gethostbyaddr` reports.

### 2.1 Production notes that the man page does not stress

- **A `/etc/hosts` entry is an outage waiting for a schedule.** It has no expiry. Every entry you add must be accompanied by a removal ticket. The 5th-most-common cause of "it works everywhere except one node" is a forgotten pin.
- **Order matters within a line and across lines.** `nss_files` returns the first matching line; it does not merge multiple lines for the same name unless `nsswitch.conf` uses the `merge` action (glibc ≥ 2.24, and only between *different* NSS modules, not within `files`).
- **IPv4/IPv6 selection is not done by `/etc/hosts`.** It is done by `getaddrinfo`'s RFC 6724 destination-address sorting, tunable in `/etc/gai.conf`. If a dual-stack host prefers AAAA and your v6 path is black-holed, `/etc/hosts` is not the lever — `gai.conf` `precedence` is.
- **`HOSTALIASES`** (an environment variable pointing at a file of `alias realname` pairs) provides a per-process, unprivileged alias layer. It applies only to single-label names and only via `nss_dns`. Useful for testing; a security smell in production since it is user-controlled.

---

## 3. `/etc/resolv.conf` — the stub resolver's configuration

Defined by `resolv.conf(5)`, parsed by glibc's `res_init()`/`__res_vinit()`. It is read **once per process** on first resolution and re-read only when the file's mtime changes (glibc checks `stat(2)` per lookup since 2.26 — older glibc cached indefinitely, which is why long-lived daemons historically needed a restart after a DNS change).

```
$ cat /etc/resolv.conf
# Managed by systemd-resolved(8). Do not edit.
search leloir.internal svc.cluster.local
nameserver 10.42.0.10
nameserver 10.42.0.11
options edns0 trust-ad timeout:2 attempts:2 single-request-reopen rotate
```

### 3.1 Directives

| Directive | Meaning | Hard limits (glibc) |
|---|---|---|
| `nameserver <IP>` | Recursive resolver to query. IPv4 or IPv6. Tried in order (unless `rotate`). | **`MAXNS = 3`.** Additional lines are silently ignored — a genuine trap in HA designs. |
| `search <d1> <d2> …` | Suffixes appended to names with fewer than `ndots` dots. | ≤ glibc 2.25: 6 domains / 256 chars. **≥ glibc 2.26: unlimited.** musl: 256 chars total. |
| `domain <d>` | Legacy single-suffix form. **Mutually exclusive with `search`** — last directive in the file wins. | — |
| `sortlist <addr/mask>` | Reorders returned addresses by preferred subnet. Effectively deprecated; ignored by `getaddrinfo` (only affects `gethostbyname`). | 10 entries |
| `options <opt>[:v] …` | Behaviour flags, below. | — |

### 3.2 `options` — the operationally significant ones

| Option | Default | Effect | When to change it |
|---|---|---|---|
| `ndots:n` | `1` | Names containing **≥ n dots** are tried as absolute **first**; names with fewer dots go through the `search` list first. Max 15. | Set `ndots:1` in containers to kill search amplification for FQDN-heavy workloads. |
| `timeout:n` | `5` | Seconds to wait per nameserver per attempt. Max 30. | `timeout:1`–`2` on a LAN with a local cache. 5 s is a lifetime for an HTTP client with a 3 s budget. |
| `attempts:n` | `2` | Rounds over the full nameserver list. Max 5. | Worst-case resolution latency = `timeout × attempts × nameservers`. With defaults and 3 servers that is **30 seconds**. |
| `rotate` | off | Round-robin the starting nameserver per process (`RES_ROTATE`). | Crude client-side load spreading. Note: **per-process**, not per-query — a single-process daemon pins one server. |
| `single-request` | off | Send A and AAAA **sequentially** instead of in parallel. | Fixes broken middleboxes; doubles latency for dual-stack lookups. |
| `single-request-reopen` | off | Send in parallel but use a **new socket (new source port)** for the second query. | The correct fix for the conntrack 5-second-stall class of bug. Cheaper than `single-request`. |
| `use-vc` | off | Force TCP for all queries. | Large responses, or UDP-hostile networks. Costs a handshake per lookup unless the resolver keeps the connection open. |
| `edns0` | off (on via `RES_OPTIONS` in most distros) | Advertise EDNS(0), enabling responses > 512 B without truncation. | Required in practice for DNSSEC and large RRsets. |
| `trust-ad` | off (glibc ≥ 2.31) | Propagate the `AD` (Authenticated Data) bit to the application instead of clearing it. | Only when the path to the resolver is trusted (loopback, IPsec). Otherwise it is a lie the application will believe. |
| `no-aaaa` | off (glibc ≥ 2.36) | Suppress AAAA queries entirely at the stub. | IPv4-only estates that want to halve DNS QPS without patching applications. |
| `inet6` | off | Legacy: map `gethostbyname` to AAAA. Avoid. | — |

### 3.3 `ndots` arithmetic — worked example

Given `search a.internal b.internal c.internal` and `options ndots:5`, resolving `api.example.com` (2 dots < 5):

```
1.  api.example.com.a.internal      → NXDOMAIN   (A)
2.  api.example.com.a.internal      → NXDOMAIN   (AAAA)
3.  api.example.com.b.internal      → NXDOMAIN   (A)
4.  api.example.com.b.internal      → NXDOMAIN   (AAAA)
5.  api.example.com.c.internal      → NXDOMAIN   (A)
6.  api.example.com.c.internal      → NXDOMAIN   (AAAA)
7.  api.example.com.                → 93.184.216.34
8.  api.example.com.                → 2606:2800:220:1:248:1893:25c8:1946
```

**8 queries for one name, 6 of them guaranteed failures.** With a trailing dot — `api.example.com.` — the name is absolute and only steps 7–8 occur. This is the entire content of the "why is my Kubernetes cluster's CoreDNS at 40k QPS" postmortem genre.

### 3.4 Per-process override without touching the file

```
$ RES_OPTIONS="ndots:1 timeout:1 attempts:1" getent hosts api.example.com
93.184.216.34   api.example.com

$ LOCALDOMAIN="staging.internal" getent hosts api
10.42.9.7       api.staging.internal
```

`RES_OPTIONS` overrides `options`; `LOCALDOMAIN` overrides `search`. Both are read by `res_init()`. This is the fastest way to prove an `ndots` hypothesis during an incident without a config change or a restart of anything else.

---

## 4. `/etc/nsswitch.conf` — the Name Service Switch

Defined by `nsswitch.conf(5)`. Each line is `database: service [ACTION] service …`. For this objective only the `hosts:` line matters.

```
$ grep ^hosts /etc/nsswitch.conf
hosts: files mdns4_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] myhostname dns
```

Read left to right: try `/etc/hosts`; then multicast DNS but only for `.local` and stop the whole lookup if it says NOTFOUND; then `systemd-resolved` over D-Bus, and **return whatever it says unless the service is unavailable**; then the local-hostname module; and only as a last resort the classic DNS stub.

### 4.1 Status codes and actions

A module returns one of four statuses, and the bracketed expression says what to do:

| Status | Meaning |
|---|---|
| `SUCCESS` | Entry found. Default action: `return`. |
| `NOTFOUND` | Module worked, name genuinely absent. Default action: `continue`. |
| `UNAVAIL` | Module could not run (daemon down, file missing). Default: `continue`. |
| `TRYAGAIN` | Transient failure (timeout, resource limit). Default: `continue`. |

| Action | Meaning |
|---|---|
| `return` | Stop the lookup, hand the current result to the caller. |
| `continue` | Try the next module. |
| `merge` | Combine this module's result with the next one's (glibc ≥ 2.24; `hosts` and `group` only). |

`!` negates: `[!UNAVAIL=return]` means "for any status other than UNAVAIL, return".

### 4.2 The modules you will encounter

| Module | Package | What it resolves | Notes |
|---|---|---|---|
| `files` | glibc | `/etc/hosts` | Always first. Cheapest, most dangerous (no expiry). |
| `dns` | glibc | Wire DNS via `/etc/resolv.conf` | The classic stub. **No cache.** |
| `myhostname` | systemd | Local hostname, `localhost`, `_gateway`, `_outbound`, `_localdnsstub` | Prevents `sudo` hangs when `/etc/hosts` lacks the hostname. |
| `resolve` | systemd | D-Bus → `systemd-resolved` | Richer than the stub: per-link routing, DNSSEC results, LLMNR/mDNS. |
| `mymachines` | systemd | `machinectl` containers | Irrelevant outside nspawn hosts. |
| `mdns4_minimal` | nss-mdns / Avahi | `*.local` over mDNS, IPv4 only | The `_minimal` variant refuses non-`.local` names — that is why `[NOTFOUND=return]` is safe after it. |
| `libvirt` / `libvirt_guest` | libvirt-nss | Guest names from the libvirt lease DB | Handy on hypervisors. |

**Ordering hazard:** placing a plain `mdns` (non-minimal) module before `dns` sends every public lookup to multicast first, adding a fixed timeout to every miss. Always use `mdns4_minimal`/`mdns_minimal` with `[NOTFOUND=return]`.

---

## 5. Resolver stacks: choosing what owns `/etc/resolv.conf`

On a modern distribution, `/etc/resolv.conf` is usually a symlink and usually not yours.

```
$ ls -l /etc/resolv.conf
lrwxrwxrwx. 1 root root 39 Aug 12 09:14 /etc/resolv.conf -> ../run/systemd/resolve/stub-resolv.conf
```

The four symlink targets you will meet, and what each means:

| Target | Contents | Implication |
|---|---|---|
| `/run/systemd/resolve/stub-resolv.conf` | `nameserver 127.0.0.53` + `options edns0 trust-ad` + search list | Full `systemd-resolved` stack: caching, per-link routing, DNSSEC, DoT. |
| `/run/systemd/resolve/resolv.conf` | The **uplink** servers verbatim | `resolved` still runs and NSS may still use `nss-resolve`, but anything reading the file talks to the upstream directly — no local cache, no split-horizon routing. |
| `/run/NetworkManager/resolv.conf` | NM-merged config | NM owns it (`dns=default`). |
| a real file | whatever you wrote | Static. Something will eventually overwrite it anyway. |

### 5.1 Trade-off matrix

| Stack | Cache | Per-link split DNS | DNSSEC | DoT/DoH | Footprint | Failure blast radius | Best fit |
|---|---|---|---|---|---|---|---|
| **glibc stub only** (`nss_dns`) | ✗ none | ✗ | ✗ (AD bit only) | ✗ | 0 | None — no daemon to die | Immutable container images, minimal appliances |
| **systemd-resolved** | ✓ (in-memory, TTL-honouring, negative) | ✓ (routing domains `~example.com`) | ✓ validating | ✓ DoT (`opportunistic`/`yes`) | ~10 MB RSS | Daemon crash → NSS `resolve` returns UNAVAIL, falls through to `dns` **only if nsswitch says so** | General-purpose Linux hosts, laptops, VPN users |
| **dnsmasq** (via NM `dns=dnsmasq`) | ✓ | ✓ (`server=/example.com/10.0.0.1`) | ✓ (with `dnssec`) | ✗ (needs stubby/https upstream) | ~5 MB | Same as above | NM-managed desktops, small edge routers, DHCP+DNS combos |
| **unbound** | ✓ (large, prefetch, serve-stale) | ✓ (`forward-zone`) | ✓ validating, hardened | ✓ DoT upstream | ~30 MB+ | Dedicated daemon; usually paired with a second instance | Nodes with heavy DNS load; DNS-sensitive SRE fleets |
| **NodeLocal DNSCache** (k8s) | ✓ per node, TCP upstream | ✓ (Corefile zones) | pass-through | ✓ upstream | DaemonSet | Node-local; a crash affects one node | Kubernetes clusters above ~50 nodes |
| **openresolv / resolvconf** | ✗ (it is a *merger*, not a resolver) | n/a | n/a | n/a | script | Race between subscribers | Debian/Alpine without systemd; VPN + DHCP coexistence |

**Recommendation for a Linux server fleet:** `systemd-resolved` with `DNSStubListener=yes`, `Cache=yes`, `DNSSEC=allow-downgrade`, and `/etc/resolv.conf → stub-resolv.conf`. It gives you a local cache (removing the `timeout×attempts` cliff for repeat lookups), a `resolvectl statistics` cache-hit metric you can scrape, and split-horizon routing that survives VPN churn. The cost is one more daemon in the critical path — mitigate it with `Restart=always` (default) and an `nsswitch` line that falls through to `dns`.

---

## 6. `systemd-resolved` in depth

### 6.1 Listeners

| Address | Purpose |
|---|---|
| `127.0.0.53:53` | **Stub listener.** Applies the search list, per-link routing, caching, DNSSEC. This is what `stub-resolv.conf` points at. |
| `127.0.0.54:53` | **Proxy stub** (systemd ≥ 249). Forwards *verbatim* to the current upstream: no search-list expansion, no local cache, no DNSSEC processing. Use it when you need a raw view of what upstream actually says. |
| D-Bus `org.freedesktop.resolve1` | The `nss-resolve` path — richer than the stub (returns per-record DNSSEC status). |

### 6.2 Complete configuration

```ini
# /etc/systemd/resolved.conf.d/10-fleet.conf
#
# Drop-in overrides for the fleet baseline. Never edit
# /etc/systemd/resolved.conf itself: package upgrades replace it.
[Resolve]
# Global fallback servers, used only when no link supplies its own.
# Format: <IP>[#<SNI hostname>]  — the #name is required for DNSOverTLS=yes.
DNS=10.42.0.10#dns.leloir.internal 10.42.0.11#dns.leloir.internal
FallbackDNS=9.9.9.9#dns.quad9.net 1.1.1.1#cloudflare-dns.com

# Suffixes appended to single-label names. A leading '~' makes the entry a
# *routing* domain (used to pick a server) without adding it to the search list.
Domains=leloir.internal ~10.in-addr.arpa ~42.10.in-addr.arpa

# allow-downgrade: validate when the upstream supports DNSSEC, tolerate
# resolvers that strip RRSIG. 'yes' is correct only when you control the
# entire resolver path — captive portals and many corporate resolvers break it.
DNSSEC=allow-downgrade

# opportunistic: use DoT when the server offers it, plaintext otherwise.
# 'yes' requires a #SNI name on every DNS= entry and fails closed.
DNSOverTLS=opportunistic

# Local caching. 'no-negative' caches positive answers only — useful when an
# upstream returns NXDOMAIN during its own outages.
Cache=yes
CacheFromLocalhost=no

DNSStubListener=yes
DNSStubListenerExtra=127.0.0.54

# Link-local protocols: disable on servers. They add multicast traffic and a
# name-collision surface with no upside in a datacentre.
MulticastDNS=no
LLMNR=no

ReadEtcHosts=yes
ResolveUnicastSingleLabel=no
```

Apply and confirm:

```
$ sudo systemctl restart systemd-resolved
$ sudo resolvectl status
Global
         Protocols: -LLMNR -mDNS +DNSOverTLS DNSSEC=allow-downgrade/supported
  resolv.conf mode: stub
Current DNS Server: 10.42.0.10
       DNS Servers: 10.42.0.10 10.42.0.11
      Fallback DNS: 9.9.9.9 1.1.1.1
        DNS Domain: leloir.internal ~10.in-addr.arpa ~42.10.in-addr.arpa

Link 2 (enp1s0)
    Current Scopes: DNS
         Protocols: +DefaultRoute -LLMNR -mDNS +DNSOverTLS DNSSEC=allow-downgrade/supported
Current DNS Server: 10.42.0.10
       DNS Servers: 10.42.0.10 10.42.0.11
        DNS Domain: leloir.internal

Link 4 (wg0)
    Current Scopes: DNS
         Protocols: -DefaultRoute -LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
Current DNS Server: 10.99.0.1
       DNS Servers: 10.99.0.1
        DNS Domain: ~corp.example.com ~99.10.in-addr.arpa
```

Read that `wg0` block carefully — it is the whole value proposition of `resolved` on a VPN host. `-DefaultRoute` means the link never receives general queries; `~corp.example.com` means only names under that suffix are routed to `10.99.0.1`. Split-horizon without a single line in `/etc/resolv.conf`.

### 6.3 Runtime manipulation (does not survive a link going down)

```
$ sudo resolvectl dns wg0 10.99.0.1
$ sudo resolvectl domain wg0 '~corp.example.com' '~99.10.in-addr.arpa'
$ sudo resolvectl default-route wg0 false
$ sudo resolvectl dnssec wg0 no
$ sudo resolvectl flush-caches
$ resolvectl statistics
DNSSEC verdicts
Secure: 0
Insecure: 4812
Bogus: 0
Indeterminate: 0

Cache
  Current Cache Size: 214
          Cache Hits: 18944
        Cache Misses: 5027
```

`Cache Hits / (Hits + Misses)` is the metric to alarm on. A hit ratio collapsing toward zero means either a TTL-0 upstream or an application that is defeating the cache with unique names.

### 6.4 Querying through `resolved`

```
$ resolvectl query artifacts.leloir.internal
artifacts.leloir.internal: 10.42.7.90                  -- link: enp1s0

-- Information acquired via protocol DNS in 2.1ms.
-- Data is authenticated: no; Data was acquired via local or encrypted transport: yes
-- Data from: network

$ resolvectl query --type=MX example.com
example.com IN MX 0 .                          -- link: enp1s0

-- Information acquired via protocol DNS in 41.7ms.
-- Data is authenticated: yes; Data was acquired via local or encrypted transport: yes
-- Data from: network
```

The `Data is authenticated` line is DNSSEC validation status — information `dig` can only give you if you ask for `+dnssec` *and* validate yourself.

---

## 7. NetworkManager as the config owner

```ini
# /etc/NetworkManager/conf.d/10-dns.conf
[main]
# default          — NM writes /run/NetworkManager/resolv.conf itself
# systemd-resolved — NM pushes per-link DNS into resolved via D-Bus (recommended)
# dnsmasq          — NM spawns a local dnsmasq on 127.0.0.1 with split zones
# none             — NM does not touch DNS at all; you own the file
dns=systemd-resolved

# symlink | file | resolvconf | unmanaged
rc-manager=symlink

[global-dns-domain-*]
servers=10.42.0.10,10.42.0.11
```

Per-connection overrides — the correct place for a static server on a specific NIC:

```
$ sudo nmcli connection modify enp1s0 ipv4.dns "10.42.0.10 10.42.0.11"
$ sudo nmcli connection modify enp1s0 ipv4.dns-search "leloir.internal"
$ sudo nmcli connection modify enp1s0 ipv4.dns-options "ndots:1,timeout:2,attempts:2,single-request-reopen"
$ sudo nmcli connection modify enp1s0 ipv4.ignore-auto-dns yes
$ sudo nmcli connection modify enp1s0 ipv4.dns-priority 10
$ sudo nmcli connection up enp1s0
Connection successfully activated (D-Bus active path: /org/freedesktop/NetworkManager/ActiveConnection/7)

$ nmcli device show enp1s0 | grep -E 'IP4.DNS|IP4.SEARCH'
IP4.DNS[1]:                             10.42.0.10
IP4.DNS[2]:                             10.42.0.11
IP4.SEARCHES[1]:                        leloir.internal
```

`ipv4.dns-priority`: lower wins. Negative values are **exclusive** — a link with priority `-42` suppresses every other link's servers for the default route. That is the supported way to force VPN-only DNS.

### 7.1 `systemd-networkd` equivalent

```ini
# /etc/systemd/network/10-uplink.network
[Match]
Name=enp1s0

[Network]
Address=10.42.7.31/24
Gateway=10.42.7.1
DNS=10.42.0.10
DNS=10.42.0.11
Domains=leloir.internal ~10.in-addr.arpa
DNSSEC=allow-downgrade
DNSOverTLS=opportunistic
DNSDefaultRoute=yes

[DHCPv4]
UseDNS=false
UseDomains=false
```

`UseDNS=false` is the networkd counterpart of `ipv4.ignore-auto-dns yes`: accept the DHCP lease's addressing but refuse its resolvers.

### 7.2 `resolvconf` / `openresolv` (Debian, Alpine, non-systemd)

A subscriber/publisher merger, not a resolver. Interfaces register their DNS data under a key; `resolvconf` merges by an ordering rule and regenerates the file.

```
$ sudo tee /etc/resolvconf/resolv.conf.d/head >/dev/null <<'EOF'
# Prepended verbatim to the generated /etc/resolv.conf.
options ndots:1 timeout:2 attempts:2 single-request-reopen edns0
EOF

$ sudo tee /etc/resolvconf/resolv.conf.d/base >/dev/null <<'EOF'
search leloir.internal
EOF

$ sudo resolvconf -u
$ cat /etc/resolv.conf
# Generated by resolvconf
options ndots:1 timeout:2 attempts:2 single-request-reopen edns0
search leloir.internal
nameserver 10.42.0.10
nameserver 10.42.0.11
```

`head` / `base` / `tail` are prepended/merged/appended. `resolvconf -u` regenerates. Interface data lives in `/run/resolvconf/interface/`.

---

## 8. Query tools — what each one actually tests

| Tool | Path exercised | Reads `/etc/hosts`? | Reads `nsswitch`? | Reads `resolv.conf`? | Use it to answer |
|---|---|---|---|---|---|
| `getent hosts` / `getent ahosts` | **Full NSS** (`gethostbyname` / `getaddrinfo`) | ✓ | ✓ | ✓ (via `nss_dns`) | "What will my application see?" |
| `resolvectl query` | `systemd-resolved` (D-Bus) | ✓ (`ReadEtcHosts=yes`) | ✗ | ✗ (uses resolved's own config) | "What does resolved decide, and is it authenticated?" |
| `host` | Raw DNS (BIND `libresolv`) | ✗ | ✗ | ✓ | "Does DNS have this record?" — quick form |
| `dig` | Raw DNS (BIND) | ✗ | ✗ | ✓ (unless `@server`) | "What exactly is on the wire?" |
| `nslookup` | Raw DNS (BIND) | ✗ | ✗ | ✓ | Legacy; still shipped. Interactive mode is its only advantage. |
| `ping` | Full NSS | ✓ | ✓ | ✓ | Nothing about DNS. Do not diagnose DNS with `ping`. |

**Rule:** every DNS incident is diagnosed with *two* commands — `getent ahosts <name>` and `dig <name>`. Divergence localises the fault to NSS; agreement pushes it upstream.

### 8.1 `getent`

```
$ getent hosts artifacts.leloir.internal
10.42.7.90      artifacts.leloir.internal

$ getent ahosts artifacts.leloir.internal
10.42.7.90      STREAM artifacts.leloir.internal
10.42.7.90      DGRAM
10.42.7.90      RAW
2001:db8:42:7::90 STREAM
2001:db8:42:7::90 DGRAM
2001:db8:42:7::90 RAW

$ getent ahostsv4 artifacts.leloir.internal
10.42.7.90      STREAM artifacts.leloir.internal
10.42.7.90      DGRAM
10.42.7.90      RAW

$ getent hosts 10.42.7.90
10.42.7.90      artifacts.leloir.internal
```

`hosts` uses the legacy `gethostbyname` path (IPv4-biased). **`ahosts` uses `getaddrinfo`, which is what modern applications call** — including RFC 6724 address sorting. When you need to predict connection behaviour, use `ahosts`; the output order is the order the application will try.

Exit status matters in scripts: `getent` returns `2` when the key is not found.

```
$ getent hosts does-not-exist.leloir.internal; echo "exit=$?"
exit=2
```

### 8.2 `host`

```
$ host artifacts.leloir.internal
artifacts.leloir.internal has address 10.42.7.90
artifacts.leloir.internal has IPv6 address 2001:db8:42:7::90

$ host -t MX example.com
example.com mail is handled by 0 .

$ host -t NS example.com
example.com name server a.iana-servers.net.
example.com name server b.iana-servers.net.

$ host 10.42.7.90
90.7.42.10.in-addr.arpa domain name pointer artifacts.leloir.internal.

$ host -a artifacts.leloir.internal 10.42.0.10
Trying "artifacts.leloir.internal"
Using domain server:
Name: 10.42.0.10
Address: 10.42.0.10#53
Aliases:

;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 20544
;; flags: qr aa rd ra; QUERY: 1, ANSWER: 2, AUTHORITY: 1, ADDITIONAL: 1

;; QUESTION SECTION:
;artifacts.leloir.internal.     IN      ANY

;; ANSWER SECTION:
artifacts.leloir.internal. 300  IN      A       10.42.7.90
artifacts.leloir.internal. 300  IN      AAAA    2001:db8:42:7::90

;; AUTHORITY SECTION:
leloir.internal.        3600    IN      NS      ns1.leloir.internal.

Received 118 bytes from 10.42.0.10#53 in 1 ms
```

Useful flags: `-t <TYPE>` (record type), `-a` (equivalent to `-t ANY -v`), `-v` (verbose), `-4`/`-6` (transport family), `-T` (TCP), `-W <sec>` (timeout), `-R <n>` (retries), `-C` (compare SOA at all authoritative servers — a fast zone-consistency check).

### 8.3 `dig`

The reference tool. Syntax: `dig [@server] [name] [type] [+options] [-flags]`.

```
$ dig artifacts.leloir.internal

; <<>> DiG 9.18.24 <<>> artifacts.leloir.internal
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 51422
;; flags: qr rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 1232
;; QUESTION SECTION:
;artifacts.leloir.internal.     IN      A

;; ANSWER SECTION:
artifacts.leloir.internal. 300  IN      A       10.42.7.90

;; Query time: 2 msec
;; SERVER: 127.0.0.53#53(127.0.0.53) (UDP)
;; WHEN: Thu Aug 27 11:04:18 -03 2026
;; MSG SIZE  rcvd: 70
```

Every field in that header is diagnostic:

| Field | Read it as |
|---|---|
| `status: NOERROR` | Also seen: `NXDOMAIN` (name does not exist), `SERVFAIL` (resolver broke — often **DNSSEC validation failure**), `REFUSED` (ACL), `NOTIMP`. |
| `flags: qr rd ra` | `aa` = authoritative answer; `ra` = recursion available (absent ⇒ you are talking to an authoritative-only server); `tc` = truncated, retry over TCP; `ad` = DNSSEC-authenticated. |
| `OPT PSEUDOSECTION … udp: 1232` | EDNS(0) buffer size negotiated. `1232` is the post-DNS-flag-day default. |
| `SERVER:` | **Which resolver answered.** The first thing to check when the answer surprises you. |
| `Query time` | > 100 ms to a LAN resolver means the first nameserver in the list is timing out. |

Operational invocations:

```
# One-line answers — the form for scripts.
$ dig +short artifacts.leloir.internal
10.42.7.90

# Answer section only, no noise.
$ dig +noall +answer example.com A example.com AAAA
example.com.            300     IN      A       93.184.216.34
example.com.            300     IN      AAAA    2606:2800:220:1:248:1893:25c8:1946

# Bypass the local stack entirely — ask a specific server.
$ dig @10.42.0.11 +norecurse artifacts.leloir.internal

# Reverse lookup.
$ dig -x 10.42.7.90 +short
artifacts.leloir.internal.

# Walk the delegation from the root — proves whether the fault is local or in
# the delegation chain. Requires a working root hint path.
$ dig +trace example.com | tail -n 12
example.com.            172800  IN      NS      a.iana-servers.net.
example.com.            172800  IN      NS      b.iana-servers.net.
;; Received 1174 bytes from 192.5.6.30#53(a.gtld-servers.net) in 24 ms

example.com.            300     IN      A       93.184.216.34
;; Received 56 bytes from 199.43.135.53#53(a.iana-servers.net) in 18 ms

# DNSSEC records, and whether validation succeeds locally.
$ dig +dnssec +multi example.com SOA | grep -E 'flags|RRSIG'
;; flags: qr rd ra ad; QUERY: 1, ANSWER: 2, AUTHORITY: 0, ADDITIONAL: 1
example.com.  3600 IN RRSIG SOA 13 2 3600 (

# Force TCP (verifies TCP/53 is not firewalled — a real and frequent cause of
# large-response failures).
$ dig +tcp example.com DNSKEY +short | head -n 1
257 3 13 mdsswUyr3DPW132mOi8V9xESWE8jTo0d...

# Query the raw upstream through resolved's proxy stub, no cache, no search list.
$ dig @127.0.0.54 example.com +short
93.184.216.34
```

Persistent defaults live in `~/.digrc`:

```
$ cat ~/.digrc
+noall +answer +nocmd
```

---

## 9. Containers and Kubernetes: the same objective, higher stakes

A container gets `/etc/resolv.conf` **injected at creation** by the runtime; it is a bind mount, not a managed file, and editing it inside the container does not survive a restart.

### 9.1 The `ndots:5` default and its cost

```
$ kubectl exec -it deploy/api -- cat /etc/resolv.conf
search prod.svc.cluster.local svc.cluster.local cluster.local leloir.internal
nameserver 10.96.0.10
options ndots:5
```

Every call to `s3.amazonaws.com` (2 dots) generates 8 queries. Override per workload:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: prod
spec:
  replicas: 3
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      # ClusterFirst keeps in-cluster service discovery working; dnsConfig
      # below merges on top of the generated file rather than replacing it.
      dnsPolicy: ClusterFirst
      dnsConfig:
        options:
          # Cut search-list amplification: names with >=1 dot go out absolute
          # first. In-cluster single-label lookups ("api", "postgres") still
          # traverse the search list correctly.
          - name: ndots
            value: "1"
          # Bound worst-case resolution latency to 2 x 2 x 1 = 4 s instead of
          # the glibc default 5 x 2 x N.
          - name: timeout
            value: "2"
          - name: attempts
            value: "2"
          # Defeat the conntrack A/AAAA race that produces exact 5 s stalls:
          # the AAAA query gets a fresh source port, so the NAT tuple cannot
          # collide with the in-flight A query.
          - name: single-request-reopen
          - name: edns0
        searches:
          - prod.svc.cluster.local
          - svc.cluster.local
          - cluster.local
      containers:
        - name: api
          image: registry.leloir.internal/api:2.14.0
          ports:
            - name: http
              containerPort: 8080
          env:
            # Belt and braces: overrides resolv.conf for this process tree even
            # if the injected file is regenerated by a different runtime.
            - name: RES_OPTIONS
              value: "ndots:1 timeout:2 attempts:2 single-request-reopen"
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 512Mi
```

### 9.2 A pod that ignores cluster DNS entirely

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: dns-diagnostics
  namespace: prod
spec:
  # 'None' discards the runtime-generated file completely; dnsConfig must then
  # supply nameservers itself. Use for tooling pods that must observe upstream
  # behaviour without CoreDNS in the path.
  dnsPolicy: "None"
  dnsConfig:
    nameservers:
      - 10.42.0.10
      - 10.42.0.11
    searches:
      - leloir.internal
    options:
      - name: ndots
        value: "1"
      - name: timeout
        value: "1"
  containers:
    - name: tools
      image: registry.leloir.internal/netshoot:v0.13
      command: ["sleep", "infinity"]
      securityContext:
        capabilities:
          add: ["NET_RAW", "NET_ADMIN"]
  restartPolicy: Never
```

### 9.3 Cluster resolver: CoreDNS

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
            lameduck 5s
        }
        ready

        # Serve the cluster zone from the Kubernetes API. 'pods insecure' is
        # the default for the a-b-c-d.ns.pod.cluster.local form; prefer
        # 'pods verified' where the extra API watch cost is acceptable.
        kubernetes cluster.local in-addr.arpa ip6.arpa {
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
            ttl 30
        }

        prometheus :9153

        # Split horizon: internal names go to the corporate resolvers.
        forward leloir.internal 10.42.0.10 10.42.0.11 {
            max_concurrent 1000
        }

        # Everything else follows the node's resolv.conf. force_tcp avoids UDP
        # fragmentation and the conntrack race on the upstream leg.
        forward . /etc/resolv.conf {
            max_concurrent 1000
            policy sequential
            health_check 5s
        }

        # Positive/negative response cache. 'denial' bounds NXDOMAIN caching,
        # which matters because search-list misses are almost all NXDOMAIN.
        cache 30 {
            success 9984 30
            denial 9984 5
        }

        loop
        reload 6s
        loadbalance
    }
```

### 9.4 Node-local cache (removes the per-pod conntrack path for cache hits)

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-local-dns
  namespace: kube-system
  labels:
    k8s-app: node-local-dns
spec:
  selector:
    matchLabels:
      k8s-app: node-local-dns
  updateStrategy:
    rollingUpdate:
      maxUnavailable: 10%
  template:
    metadata:
      labels:
        k8s-app: node-local-dns
      annotations:
        prometheus.io/port: "9253"
        prometheus.io/scrape: "true"
    spec:
      priorityClassName: system-node-critical
      serviceAccountName: node-local-dns
      hostNetwork: true
      dnsPolicy: Default   # do NOT use cluster DNS: that would be a loop
      tolerations:
        - key: CriticalAddonsOnly
          operator: Exists
        - effect: NoExecute
          operator: Exists
        - effect: NoSchedule
          operator: Exists
      containers:
        - name: node-cache
          image: registry.k8s.io/dns/k8s-dns-node-cache:1.23.1
          resources:
            requests:
              cpu: 25m
              memory: 5Mi
          args:
            - "-localip"
            - "169.254.20.10,10.96.0.10"
            - "-conf"
            - "/etc/Corefile"
            - "-upstreamsvc"
            - "kube-dns-upstream"
          securityContext:
            capabilities:
              add: ["NET_ADMIN"]
          ports:
            - containerPort: 53
              name: dns
              protocol: UDP
            - containerPort: 53
              name: dns-tcp
              protocol: TCP
            - containerPort: 9253
              name: metrics
              protocol: TCP
          livenessProbe:
            httpGet:
              host: 169.254.20.10
              path: /health
              port: 8080
            initialDelaySeconds: 60
            timeoutSeconds: 5
          volumeMounts:
            - name: config-volume
              mountPath: /etc/coredns
            - name: xtables-lock
              mountPath: /run/xtables.lock
              readOnly: false
      volumes:
        - name: config-volume
          configMap:
            name: node-local-dns
            items:
              - key: Corefile
                path: Corefile.base
        - name: xtables-lock
          hostPath:
            path: /run/xtables.lock
            type: FileOrCreate
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: node-local-dns
  namespace: kube-system
data:
  Corefile: |
    cluster.local:53 {
        errors
        cache {
            success 9984 30
            denial 9984 5
        }
        reload
        loop
        bind 169.254.20.10 10.96.0.10
        forward . __PILLAR__CLUSTER__DNS__ {
            force_tcp
        }
        prometheus :9253
        health 169.254.20.10:8080
    }
    in-addr.arpa:53 {
        errors
        cache 30
        reload
        loop
        bind 169.254.20.10 10.96.0.10
        forward . __PILLAR__CLUSTER__DNS__ {
            force_tcp
        }
        prometheus :9253
    }
    ip6.arpa:53 {
        errors
        cache 30
        reload
        loop
        bind 169.254.20.10 10.96.0.10
        forward . __PILLAR__CLUSTER__DNS__ {
            force_tcp
        }
        prometheus :9253
    }
    .:53 {
        errors
        cache 30
        reload
        loop
        bind 169.254.20.10 10.96.0.10
        forward . __PILLAR__UPSTREAM__SERVERS__ {
            force_tcp
        }
        prometheus :9253
    }
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: node-local-dns
  namespace: kube-system
```

`force_tcp` on the upstream leg is the structural fix for the UDP conntrack race: TCP tuples are tracked by a full connection state machine and do not collide the way two same-port UDP datagrams do.

### 9.5 glibc vs. musl — the Alpine trap

| Behaviour | glibc | musl (Alpine) |
|---|---|---|
| `/etc/nsswitch.conf` | Honoured | **Ignored entirely.** `/etc/hosts` then DNS, hardcoded. |
| Nameserver order | Sequential, `timeout`×`attempts` | **All nameservers queried in parallel**, first answer wins |
| `search` list | Supported | Supported (musl ≥ 1.1.13) |
| `ndots` | Supported, max 15 | Supported |
| `timeout` / `attempts` | Supported | Supported (`attempts` is a global retry count) |
| `single-request-reopen`, `rotate`, `use-vc`, `trust-ad` | Supported | **Silently ignored** |
| `MAXNS` | 3 | 3 |
| TCP fallback on TC=1 | Yes | Yes (musl ≥ 1.2.4); older musl **fails** on truncated responses |
| NSS modules (`myhostname`, `resolve`, `mdns`) | Available | Not available |

Consequence: the `single-request-reopen` workaround does nothing in an Alpine image. On musl the mitigations are `force_tcp` at the node cache, a node-local resolver, or switching the base image to a glibc one.

---

## 10. Verification and failure diagnosis

### 10.1 The standard five-command triage

```
# 1. Who owns the config, and what does it actually say?
$ ls -l /etc/resolv.conf && cat /etc/resolv.conf
lrwxrwxrwx. 1 root root 39 Aug 12 09:14 /etc/resolv.conf -> ../run/systemd/resolve/stub-resolv.conf
# Generated by systemd-resolved(8). Do not edit.
nameserver 127.0.0.53
options edns0 trust-ad
search leloir.internal

# 2. What order will NSS use?
$ grep ^hosts: /etc/nsswitch.conf
hosts: files resolve [!UNAVAIL=return] myhostname dns

# 3. What will the APPLICATION see?  (full NSS path)
$ getent ahosts artifacts.leloir.internal
10.42.7.90      STREAM artifacts.leloir.internal

# 4. What is on the WIRE?  (raw DNS, bypasses NSS)
$ dig +short artifacts.leloir.internal
10.42.7.90

# 5. Is the local resolver stack healthy?
$ resolvectl status --no-pager | head -n 8
$ systemctl is-active systemd-resolved
active
```

### 10.2 Decision tree

| `getent` | `dig` | Conclusion | Next step |
|---|---|---|---|
| ✓ correct | ✓ correct | Not DNS. | Look at the application's own resolver (JVM `networkaddress.cache.ttl`, Go's pure-Go resolver, connection pools holding stale IPs). |
| ✓ **wrong** | ✓ correct | NSS is short-circuiting DNS. | `grep -n . /etc/hosts`; check `nss-myhostname`, `nss-resolve` cache, mDNS. |
| ✗ fails | ✓ correct | NSS module broken or `nsswitch` order wrong. | `journalctl -u systemd-resolved`; check `[!UNAVAIL=return]` masking a fallthrough. |
| ✓ correct | ✗ fails | `dig` is querying a different server than NSS does. | Compare `dig`'s `SERVER:` line with `resolvectl status`. |
| ✗ fails | ✗ fails | Upstream or transport. | `dig +trace`, `tcpdump`, firewall. |

### 10.3 Isolating a slow resolver

```
$ for s in 10.42.0.10 10.42.0.11 127.0.0.53; do
    printf '%-14s ' "$s"
    dig @"$s" +tries=1 +time=2 example.com +noall +stats 2>/dev/null \
      | awk '/Query time/{print $4, $5}' || echo "TIMEOUT"
  done
10.42.0.10     3 msec
10.42.0.11     2001 msec
127.0.0.53     1 msec
```

`10.42.0.11` is dead but still listed. With default `timeout:5 attempts:2`, every lookup that rotates onto it costs 10 s. The immediate mitigation is removing it from the link; the systemic one is `timeout:2` plus a local cache.

### 10.4 Proving `ndots` amplification

```
$ sudo tcpdump -i any -n -s0 'udp port 53' -c 20 &
[1] 40318
$ getent hosts s3.amazonaws.com >/dev/null
11:22:04.118 IP 10.42.7.31.51923 > 10.42.0.10.53: 12043+ A? s3.amazonaws.com.prod.svc.cluster.local. (57)
11:22:04.118 IP 10.42.7.31.51923 > 10.42.0.10.53: 12044+ AAAA? s3.amazonaws.com.prod.svc.cluster.local. (57)
11:22:04.119 IP 10.42.0.10.53 > 10.42.7.31.51923: 12043 NXDomain 0/1/0 (150)
11:22:04.119 IP 10.42.0.10.53 > 10.42.7.31.51923: 12044 NXDomain 0/1/0 (150)
11:22:04.120 IP 10.42.7.31.38112 > 10.42.0.10.53: 8891+ A? s3.amazonaws.com.svc.cluster.local. (52)
11:22:04.120 IP 10.42.7.31.38112 > 10.42.0.10.53: 8892+ AAAA? s3.amazonaws.com.svc.cluster.local. (52)
...
11:22:04.126 IP 10.42.7.31.44070 > 10.42.0.10.53: 3311+ A? s3.amazonaws.com. (34)
11:22:04.131 IP 10.42.0.10.53 > 10.42.7.31.44070: 3311 4/0/0 A 52.216.xx.xx ... (118)
```

Six wasted queries, visible on the wire, before the useful one. Then confirm the fix without changing any file:

```
$ RES_OPTIONS="ndots:1" getent hosts s3.amazonaws.com >/dev/null
11:24:31.002 IP 10.42.7.31.55210 > 10.42.0.10.53: 44120+ A? s3.amazonaws.com. (34)
11:24:31.002 IP 10.42.7.31.55210 > 10.42.0.10.53: 44121+ AAAA? s3.amazonaws.com. (34)
```

### 10.5 Catching the 5-second stall

```
$ for i in $(seq 1 300); do
    /usr/bin/time -f '%e' getent hosts api.leloir.internal >/dev/null
  done 2>&1 | sort -rn | head -n 5
5.01
5.01
0.02
0.01
0.01
```

Two of 300 lookups took exactly 5.01 s — the `timeout:5` default, not a slow server. Confirm the parallel-query hypothesis:

```
$ sudo conntrack -S | awk '{for(i=1;i<=NF;i++) if($i ~ /insert_failed|drop/) printf "%s ", $i; print ""}' | head -n 4
insert_failed=1842 drop=0
insert_failed=1791 drop=0
```

Non-zero `insert_failed` on UDP is the signature. Remediations, in order of preference: `single-request-reopen` (glibc only), `force_tcp` at a node-local cache, or `use-vc`.

### 10.6 Distinguishing SERVFAIL from DNSSEC failure

```
$ dig secure-but-broken.example +short
;; communications error to 127.0.0.53#53: SERVFAIL

# Ask again with validation disabled at the stub. If it now answers, the fault
# is DNSSEC (expired RRSIG, missing DS, clock skew), not reachability.
$ dig @10.42.0.10 +cd secure-but-broken.example +short
203.0.113.9

$ journalctl -u systemd-resolved -n 5 --no-pager
systemd-resolved[812]: DNSSEC validation failed for question secure-but-broken.example IN A: signature-expired
```

`+cd` (Checking Disabled) is the definitive discriminator. If `+cd` succeeds and the plain query fails, stop looking at the network — check the zone's signatures and the local clock (`timedatectl`), because DNSSEC validation is time-sensitive and a host with a skewed clock rejects perfectly valid signatures.

### 10.7 Cache behaviour

```
$ resolvectl flush-caches
$ resolvectl query example.com | tail -n 3
-- Information acquired via protocol DNS in 38.4ms.
-- Data is authenticated: no; Data was acquired via local or encrypted transport: yes
-- Data from: network

$ resolvectl query example.com | tail -n 3
-- Information acquired via protocol DNS in 1.1ms.
-- Data is authenticated: no; Data was acquired via local or encrypted transport: yes
-- Data from: cache
```

`Data from: cache` versus `network` is the ground truth. When a DNS change "has not propagated", flush and re-query before escalating to the zone owner.

### 10.8 Which process resolved what

```
$ sudo ss -lunp 'sport = :53'
State   Recv-Q  Send-Q   Local Address:Port    Peer Address:Port  Process
UNCONN  0       0         127.0.0.53%lo:53           0.0.0.0:*      users:(("systemd-resolve",pid=812,fd=18))
UNCONN  0       0         127.0.0.54%lo:53           0.0.0.0:*      users:(("systemd-resolve",pid=812,fd=20))

$ sudo strace -f -e trace=connect,sendto,openat -p "$(pgrep -f 'api-server')" 2>&1 \
  | grep -E 'resolv.conf|nsswitch|53\)' | head -n 4
[pid  9911] openat(AT_FDCWD, "/etc/nsswitch.conf", O_RDONLY|O_CLOEXEC) = 7
[pid  9911] openat(AT_FDCWD, "/etc/resolv.conf", O_RDONLY|O_CLOEXEC) = 7
[pid  9911] connect(9, {sa_family=AF_INET, sin_port=htons(53), sin_addr=inet_addr("127.0.0.53")}, 16) = 0
```

If `strace` shows the process never opens `/etc/resolv.conf`, it is not using glibc's resolver at all — Go binaries built with `CGO_ENABLED=0`, or a JVM/Node runtime with its own cache. Client-side DNS configuration will not reach it, and that is the finding.

### 10.9 Verification checklist

```
# Config sanity
[ ] readlink -f /etc/resolv.conf                  # who owns the file
[ ] grep -c '^nameserver' /etc/resolv.conf        # must be <= 3
[ ] grep '^options' /etc/resolv.conf              # ndots/timeout/attempts bounded
[ ] grep '^hosts:' /etc/nsswitch.conf             # order and actions
[ ] getent hosts "$(hostname)"                    # the local name must resolve

# Behaviour
[ ] getent ahosts <name>   ==  dig +short <name>  # NSS vs wire agree
[ ] dig +short <name> @<each nameserver>          # every listed server answers
[ ] dig +tcp <name>                               # TCP/53 is not firewalled
[ ] dig -x <ip> +short                            # reverse zone is delegated
[ ] resolvectl statistics                         # cache hit ratio is sane

# Latency budget
[ ] worst case = timeout x attempts x nameservers # compute it, write it down
```

---

## 11. Command and file reference

| File | Owner | Purpose |
|---|---|---|
| `/etc/hosts` | admin | Static name→address database |
| `/etc/resolv.conf` | resolver stack | Nameservers, search list, resolver options |
| `/etc/nsswitch.conf` | admin | Which name databases, in which order |
| `/etc/gai.conf` | admin | RFC 6724 address selection/precedence |
| `/etc/systemd/resolved.conf`, `.conf.d/*.conf` | admin | `systemd-resolved` configuration |
| `/run/systemd/resolve/stub-resolv.conf` | systemd-resolved | Points at `127.0.0.53` |
| `/run/systemd/resolve/resolv.conf` | systemd-resolved | Uplink servers verbatim |
| `/etc/NetworkManager/conf.d/*.conf` | admin | NM DNS backend and `rc-manager` |
| `/etc/resolvconf/resolv.conf.d/{head,base,tail}` | admin | `resolvconf` merge fragments |
| `~/.digrc` | user | Default `dig` options |

| Command | One-line purpose |
|---|---|
| `getent hosts` / `getent ahosts` | Resolve through the **full NSS path** — what applications see |
| `host <name> [server]` | Quick DNS lookup; `-t` for type, `-a` for everything, `-C` to compare SOAs |
| `dig [@server] <name> [type] [+opts]` | Full-fidelity DNS query; `+short`, `+trace`, `+dnssec`, `+cd`, `+tcp` |
| `nslookup <name> [server]` | Legacy query tool, still present |
| `resolvectl status\|query\|dns\|domain\|flush-caches\|statistics` | Inspect and control `systemd-resolved` |
| `nmcli connection modify … ipv4.dns…` | Persist per-connection DNS under NetworkManager |
| `resolvconf -u` | Regenerate `/etc/resolv.conf` from registered subscribers |
| `ss -lunp 'sport = :53'` | Which process is listening on port 53 |
| `tcpdump -i any -n 'port 53'` | Observe the actual queries |

---

## 12. Referencias

**LPI**
- Exam 102-500 objectives (Topic 109.4): https://www.lpi.org/our-certifications/exam-102-objectives/
- Exam 101-500 objectives: https://www.lpi.org/our-certifications/exam-101-objectives/
- LPIC-1 certification overview: https://www.lpi.org/our-certifications/lpic-1-overview/

**Manual pages and glibc**
- `resolv.conf(5)`: https://man7.org/linux/man-pages/man5/resolv.conf.5.html
- `hosts(5)`: https://man7.org/linux/man-pages/man5/hosts.5.html
- `nsswitch.conf(5)`: https://man7.org/linux/man-pages/man5/nsswitch.conf.5.html
- `getaddrinfo(3)`: https://man7.org/linux/man-pages/man3/getaddrinfo.3.html
- `gai.conf(5)`: https://man7.org/linux/man-pages/man5/gai.conf.5.html
- `getent(1)`: https://man7.org/linux/man-pages/man1/getent.1.html
- GNU C Library — Name Service Switch: https://www.gnu.org/software/libc/manual/html_node/Name-Service-Switch.html
- glibc NEWS (resolver limits, `trust-ad`, `no-aaaa`): https://sourceware.org/glibc/wiki/Release

**systemd**
- `systemd-resolved.service(8)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-resolved.service.html
- `resolved.conf(5)`: https://www.freedesktop.org/software/systemd/man/latest/resolved.conf.html
- `resolvectl(1)`: https://www.freedesktop.org/software/systemd/man/latest/resolvectl.html
- `nss-resolve(8)`: https://www.freedesktop.org/software/systemd/man/latest/nss-resolve.html
- `nss-myhostname(8)`: https://www.freedesktop.org/software/systemd/man/latest/nss-myhostname.html
- `systemd.network(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.network.html

**NetworkManager and resolvconf**
- `NetworkManager.conf(5)`: https://networkmanager.dev/docs/api/latest/NetworkManager.conf.html
- `nm-settings(5)` (`ipv4.dns-options`, `ipv4.dns-priority`): https://networkmanager.dev/docs/api/latest/nm-settings-nmcli.html
- openresolv: https://roy.marples.name/projects/openresolv/

**BIND utilities**
- `dig(1)`: https://bind9.readthedocs.io/en/latest/manpages.html#dig-dns-lookup-utility
- `host(1)`: https://bind9.readthedocs.io/en/latest/manpages.html#host-dns-lookup-utility
- ISC BIND 9 documentation: https://bind9.readthedocs.io/en/latest/

**Kubernetes and containers**
- DNS for Services and Pods: https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Customizing DNS Service: https://kubernetes.io/docs/tasks/administer-cluster/dns-custom-nameservers/
- Debugging DNS Resolution: https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/
- Using NodeLocal DNSCache: https://kubernetes.io/docs/tasks/administer-cluster/nodelocaldns/
- CoreDNS manual: https://coredns.io/manual/toc/
- Docker container DNS: https://docs.docker.com/engine/network/#dns-services

**Standards**
- RFC 1034 — Domain Names, Concepts and Facilities: https://www.rfc-editor.org/rfc/rfc1034
- RFC 1035 — Domain Names, Implementation and Specification: https://www.rfc-editor.org/rfc/rfc1035
- RFC 6724 — Default Address Selection for IPv6: https://www.rfc-editor.org/rfc/rfc6724
- RFC 6891 — Extension Mechanisms for DNS (EDNS(0)): https://www.rfc-editor.org/rfc/rfc6891
- RFC 4033/4034/4035 — DNS Security Introduction and Requirements: https://www.rfc-editor.org/rfc/rfc4033
- RFC 7858 — DNS over TLS: https://www.rfc-editor.org/rfc/rfc7858
- RFC 8482 — Handling of Queries for QTYPE=ANY: https://www.rfc-editor.org/rfc/rfc8482

**musl**
- musl DNS resolver behaviour and functional differences from glibc: https://wiki.musl-libc.org/functional-differences-from-glibc.html