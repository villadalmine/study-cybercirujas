# LPIC-3 303 — Topic 334.4: Virtual Private Networks

> **Exam:** 303-300 v3.0.0 · **Objective weight:** 6.67 · **Scope:** principles of VPNs; OpenVPN protocol, servers and clients (routing and bridging); IPsec and IKEv2 with strongSwan (tunnel and transport mode); WireGuard servers and clients; awareness of L2TP.
> **Files and utilities you must be able to operate blind:** `/etc/openvpn/`, `openvpn`, `/etc/ipsec.conf`, `/etc/ipsec.secrets`, `/etc/swanctl/swanctl.conf`, `ipsec`, `swanctl`, `/etc/wireguard/`, `wg`, `wg-quick`.

---

## 1. The production problem: what a VPN actually buys you, and what it costs

A VPN is not "encryption for the network". Encryption in transit is a solved commodity — TLS 1.3 gives it to you per-connection with no privileged daemon, no kernel module and no MTU arithmetic. What a VPN buys you is something TLS cannot: **a routing domain**. It takes two address spaces that cannot reach each other — because they are behind NAT, on different providers, in different failure domains — and makes them mutually addressable, with a cryptographic identity check bound to that reachability.

That reframing drives every design decision in this objective:

| You actually need | Do not build a VPN | Build a VPN |
|---|---|---|
| Confidentiality of one app protocol | mTLS, SPIFFE/SPIRE, service mesh | — |
| Reachability between RFC1918 islands | — | site-to-site L3 tunnel |
| Legacy protocol that cannot be wrapped (SMB, LDAP w/o TLS, SCADA, database wire protocols) | — | site-to-site or remote-access L3 tunnel |
| One flat L2 broadcast domain (DHCP relay-free, PXE, WoL, cluster heartbeat) | — | L2 tunnel (OpenVPN TAP / L2TPv3 pseudowire / GRETAP over IPsec) |
| Operator access to production | Bastion + SSH CA + short-lived certs | remote-access VPN only when the tooling itself is L3 (kubectl to a private API server, RDP, iDRAC) |

### 1.1 The four failure modes that define the operational design

Every VPN incident in production reduces to one of four causes. Design against them explicitly; each section below returns to them.

1. **The MTU black hole.** The tunnel adds 52–80 bytes of header. If path MTU discovery is broken anywhere — a firewall dropping ICMP `fragmentation needed` (type 3 code 4) or ICMPv6 `Packet Too Big`, a common default — then small packets pass and large packets vanish. Symptom: `ping` works, `ssh` connects and then hangs at the banner, HTTP GET of a small object works and a large one stalls at exactly the same byte offset every time. This is the single most common "the VPN is flaky" ticket, and it is never flaky — it is deterministic.

2. **The routing asymmetry.** You installed a route on the gateway but not on the hosts, or on the hosts but not on the return path. Traffic leaves through the tunnel and comes back through the default gateway, where either stateful NAT drops it or `rp_filter` in strict mode (`net.ipv4.conf.*.rp_filter=1`) silently discards it as a martian.

3. **The identity lifecycle.** Certificates expire, CRLs go stale, a laptop is lost and its key is still valid. A VPN with no revocation path is a permanent credential handed to an endpoint you do not control. This is why the PKI sections below are not optional boilerplate.

4. **The single point of failure you built on purpose.** One VPN gateway concentrates every branch, every operator and every cross-region call into one process, one NIC queue, one CPU's crypto throughput and one public IP. Capacity, HA and observability must be designed before the first tunnel, because retrofitting HA onto a policy-based IPsec deployment means re-negotiating every SA on every peer.

### 1.2 The topology decision, before the protocol decision

```
 (a) HUB-AND-SPOKE                (b) FULL MESH                 (c) HIERARCHICAL HUB
     branch ─┐                      A ────── B                    region-eu ── region-us
     branch ─┼─ hub ── DC           │ ╲    ╱ │                       │             │
     branch ─┘                      │  ╲  ╱  │                    branches      branches
                                    │   ╳    │
  n tunnels, 1 blast radius,        C ────── D              n tunnels/region, 2 hops
  hairpin latency, easy policy   n(n-1)/2 tunnels,          bounded state, RPO on the
  and easy audit                 optimal latency,           regional hub only
                                 O(n²) key distribution
```

* **Hub-and-spoke** is correct until inter-spoke traffic becomes latency-sensitive. Its real virtue is that policy lives in one place, which is what auditors and incident responders need.
* **Full mesh** is only tractable when key distribution is automated. This is exactly the niche WireGuard-based overlays (Tailscale, Netbird, Netmaker, Cilium's WireGuard mode) occupy: WireGuard supplies the data plane, an orchestrator supplies the control plane WireGuard deliberately omits.
* **Hierarchical** is what actually ships at scale: mesh between regional hubs, star within a region.

---

## 2. Protocol foundations

### 2.1 The three planes, and why the split matters

| Plane | Job | OpenVPN | IPsec/IKEv2 | WireGuard |
|---|---|---|---|---|
| **Control** | Authenticate peers, agree on keys, rekey | TLS 1.3 session over the "control channel", multiplexed on the same UDP socket | IKEv2 (RFC 7296) on UDP/500 or UDP/4500, a separate protocol from the data plane | Noise_IKpsk2 handshake, in-band, 1-RTT, no separate protocol |
| **Data** | Encrypt/authenticate/encapsulate packets | OpenVPN's own frame over UDP/TCP; userspace by default, kernel with DCO | ESP (RFC 4303), always in-kernel via XFRM | ChaCha20-Poly1305 over UDP, always in-kernel |
| **Policy/routing** | Decide which packets enter the tunnel | Kernel routing table + `iroute`/`ccd` | XFRM SPD (policy-based) *or* routing table (route-based via XFRM interfaces/VTI) | `AllowedIPs` — "cryptokey routing", which is simultaneously ACL and routing |

The **policy plane** is where architectures diverge most, and it is the axis exam questions probe. OpenVPN and WireGuard put the tunnel behind a normal network interface, so `ip route` decides. Classic IPsec puts the decision in the Security Policy Database, *before* routing — which is why `ip route get` lies to you on a policy-based IPsec box and why route-based IPsec (XFRM interfaces) is now the preferred design.

### 2.2 IPsec and IKEv2 in detail

**IPsec is two databases and two protocols.**

* **SAD** (Security Association Database) — the negotiated keys, SPIs, algorithms, sequence counters. Inspect with `ip xfrm state`.
* **SPD** (Security Policy Database) — "traffic matching X must be protected by an SA with properties Y". Inspect with `ip xfrm policy`.
* **ESP** (IP protocol 50) — encryption + integrity + anti-replay. This is what you deploy.
* **AH** (IP protocol 51) — integrity only, covers immutable outer IP fields, therefore **incompatible with NAT**. Legacy; know it exists and why it is not used.

**Tunnel vs transport mode** is directly examinable:

| | Transport mode | Tunnel mode |
|---|---|---|
| What is encrypted | Payload only; original IP header preserved | Entire original IP packet |
| Resulting packet | `IP | ESP | TCP/UDP | ESP-trailer | ICV` | `newIP | ESP | IP | TCP/UDP | ESP-trailer | ICV` |
| Overhead | ~36 B (GCM) | ~56 B (GCM, +20 for the new IPv4 header) |
| Endpoints | The two hosts are the two peers | Gateways may protect subnets behind them |
| Use case | Host-to-host; **L2TP/IPsec**; protecting an already-encapsulated tunnel (GRE, VXLAN, L2TPv3) | Site-to-site, remote access — the default |

**The IKEv2 exchange** (memorise this sequence; failures are diagnosed by which exchange died):

```
Initiator                                   Responder
  ── IKE_SA_INIT ──────────────────────────────▶
     HDR, SAi1 (proposals), KEi, Ni,
     [N(NAT_DETECTION_SOURCE_IP),
      N(NAT_DETECTION_DESTINATION_IP)]
  ◀───────────────────────────── IKE_SA_INIT ──
     HDR, SAr1 (chosen proposal), KEr, Nr,
     [CERTREQ]
     ── from here everything is encrypted with SK_e/SK_a ──
  ── IKE_AUTH ─────────────────────────────────▶
     HDR, SK{ IDi, CERT, AUTH, SAi2, TSi, TSr }
  ◀────────────────────────────────  IKE_AUTH ──
     HDR, SK{ IDr, CERT, AUTH, SAr2, TSi, TSr,
              [CP(CFG_REPLY): internal IP, DNS] }
  ── CREATE_CHILD_SA ──────────────────────────▶   (rekey or additional child SA)
```

Key consequences:

* **NAT detection** happens in `IKE_SA_INIT`, by hashing the source/destination IP+port and comparing. If a NAT is detected, both peers move to **UDP/4500 with UDP-ESP encapsulation (RFC 3948)**, which costs another 8 bytes of overhead. Forcing this with `encap = yes` is a legitimate workaround for middleboxes that mangle raw ESP.
* **Traffic selectors** (`TSi`/`TSr`) are negotiated in `IKE_AUTH`. A mismatch yields `TS_UNACCEPTABLE` — this is the classic "the subnets do not match on both sides" failure, and no amount of restarting fixes it.
* **MOBIKE** (RFC 4555) lets an established IKE SA survive a change of outer IP — the mechanism that keeps a laptop's IPsec tunnel alive across Wi-Fi→LTE. Enabled by default in strongSwan.
* **DPD / liveness checks** are IKEv2 informational exchanges with an empty payload. `dpd_delay` is how often to probe an idle peer; `dpd_action = restart` is what turns a dead peer into a re-established tunnel instead of a black hole.
* **PFS** comes from performing a fresh Diffie-Hellman in `CREATE_CHILD_SA`. In strongSwan you get it by naming a DH group in `esp_proposals` (e.g. `aes256gcm16-ecp384`); omit the group and the child SA rekeys from existing keying material with no forward secrecy.

### 2.3 OpenVPN in detail

OpenVPN multiplexes two logical channels over one socket:

* **Control channel** — a full TLS session (TLS 1.3 with OpenVPN 2.5+/OpenSSL 3). Peer authentication, cipher negotiation, key material derivation, and the push of client configuration (`push "route ..."`, `push "dhcp-option DNS ..."`).
* **Data channel** — AEAD-encrypted frames (`P_DATA_V2`), keyed from the TLS session, rekeyed every hour by default (`reneg-sec 3600`).

**The pre-authentication hardening layer** is the operationally important part, because the control channel is a TLS server exposed to the internet:

| Mechanism | Protects | Key model | Verdict |
|---|---|---|---|
| none | — | — | Control channel answers every scanner; DoS and 0-day exposure |
| `tls-auth ta.key` | HMAC on control packets | one shared key, all clients | Legacy; still fine, no confidentiality of the handshake |
| `tls-crypt ta.key` | HMAC **+ encryption** of control packets | one shared key, all clients | Good default; hides the TLS handshake from DPI |
| `tls-crypt-v2` | Same, with a **per-client** key wrapped by a server key | per client, revocable | Best; a leaked client key does not unlock other clients |

**`tun` vs `tap`** — the routing-vs-bridging decision, explicitly named in the objective:

| | `dev tun` (routed, L3) | `dev tap` (bridged, L2) |
|---|---|---|
| Frames on the wire | IP packets | Ethernet frames incl. ARP, STP, DHCP, IPv6 RA |
| Per-client cost | 1 route | Full broadcast/multicast replication to every client |
| Broadcast domain | Separate per side | One domain spanning the WAN — a broadcast storm is now global |
| Overhead | Lower | +14 B Ethernet header, plus flooding |
| DCO (kernel offload) | Supported | Not supported on Linux |
| When it is right | ~99% of deployments | PXE boot, WoL, non-IP protocols, appliance clusters that heartbeat over L2 |

**DCO (Data Channel Offload)** moves the data channel into the kernel, eliminating the userspace round-trip per packet (typically a 3–5× throughput improvement on the same CPU). Two implementations exist: the out-of-tree `ovpn-dco` module shipped alongside OpenVPN 2.6, and the `ovpn` driver merged upstream in Linux 6.16. DCO constrains the configuration: AEAD data ciphers only, `dev tun` only, no `--compress`, no `--fragment`, no `--shaper`. Verify with `modinfo ovpn` / `modinfo ovpn-dco`; disable per-instance with `--disable-dco`.

### 2.4 WireGuard in detail

WireGuard's design thesis is *reduce the attack surface by removing choices*. There is no cipher negotiation, therefore no downgrade attack and no `NO_PROPOSAL_CHOSEN`. The primitives are fixed:

| Function | Primitive |
|---|---|
| Key agreement | Curve25519 (ECDH) |
| AEAD | ChaCha20-Poly1305 |
| Hashing / KDF | BLAKE2s, HKDF |
| Handshake pattern | Noise_IKpsk2 (1-RTT, mutual authentication, identity hiding for the responder) |
| Replay protection | Sliding window over a 64-bit counter |
| Anti-DoS | Cookie reply (HMAC over the source address) under load |

**Cryptokey routing** is the central concept: a peer's public key *is* its identity, and `AllowedIPs` binds source addresses to that key in both directions.

* **Outbound:** the packet's destination address selects the peer whose `AllowedIPs` contains it (longest-prefix match). No matching peer ⇒ the packet is dropped with `ENETUNREACH`.
* **Inbound:** after decryption, if the inner packet's *source* address is not in that peer's `AllowedIPs`, the packet is dropped. This is unforgeable source-address validation, applied before the packet reaches the stack.

Two peers can never own overlapping `AllowedIPs` on the same interface — the second one wins and silently steals the prefix. This is the number one WireGuard misconfiguration.

**Roaming is a consequence, not a feature:** the `Endpoint` is updated to the source address of any correctly authenticated packet. A client changing networks needs no reconnection, no MOBIKE, no state machine.

**Timers** (fixed constants from the protocol, not tunables) — these are what you reason with when diagnosing:

| Constant | Value | Meaning |
|---|---|---|
| `REKEY_AFTER_TIME` | 120 s | Initiator starts a new handshake after this much time on a session |
| `REJECT_AFTER_TIME` | 180 s | Session key is refused; no traffic passes until a new handshake |
| `REKEY_ATTEMPT_TIME` | 90 s | Give up retrying a handshake for this data-triggered attempt |
| `KEEPALIVE_TIMEOUT` | 10 s | Send a keepalive if data was received but nothing sent back |
| `PersistentKeepalive` | user-set, typically 25 s | Keeps a NAT/stateful-firewall mapping alive from behind NAT |

Therefore: **a `latest handshake` older than 180 seconds on an interface that should be carrying traffic means the tunnel is down**, and that single number is your best health metric.

**What WireGuard deliberately does not have**, and what you must supply:

* No PKI, no CRL, no expiry — key rotation and revocation are your orchestration problem.
* No IP address assignment — no DHCP, no CFG payload. Addresses are static, from your IPAM.
* No dynamic routing over the tunnel — although you can run BGP/OSPF *inside* it and set `AllowedIPs` wide.
* No user/password, no RADIUS, no MFA — pair with an identity-aware overlay if you need it.
* No outer-path PMTU discovery — you set the MTU correctly or you debug a black hole.

### 2.5 MTU arithmetic — do this once, on paper

Assume a 1500-byte path. Overheads for IPv4 outer transport:

```
OpenVPN, UDP, AES-256-GCM, P_DATA_V2:
   outer IPv4 header ........ 20
   UDP header ...............  8
   opcode + peer-id .........  4
   packet-id (GCM nonce) ....  4
   Poly/GCM auth tag ........ 16
                              ──
                              52   →  payload MTU 1448

WireGuard, IPv4 outer:
   outer IPv4 header ........ 20
   UDP header ...............  8
   WG type+reserved .........  4
   receiver index ...........  4
   counter ..................  8
   Poly1305 tag ............. 16
                              ──
                              60   →  payload MTU 1440
   (wg-quick defaults to 1420 = route MTU − 80, sized for an IPv6 outer header)

IPsec ESP tunnel mode, AES-256-GCM, no NAT-T:
   outer IPv4 header ........ 20
   ESP header (SPI+seq) .....  8
   GCM IV ...................  8
   ESP trailer (pad+len+nh) . 2..17
   ICV ...................... 16
                              ──
                            54..69  →  payload MTU ≈ 1438 (round to 1400 with NAT-T)
   +8 more bytes if UDP-encapsulated on port 4500
```

**Rule of practice:** set the tunnel MTU from this arithmetic, then *additionally* clamp TCP MSS on the gateway, because clamping fixes TCP even when PMTUD is broken, and PMTUD is broken more often than not.

```bash
# nftables: clamp MSS on every SYN crossing a tunnel interface
$ sudo nft add rule inet filter forward tcp flags syn tcp option maxseg size set rt mtu
```

---

## 3. Comparative trade-offs

### 3.1 Protocol comparison

| Dimension | OpenVPN 2.6 | IPsec/IKEv2 (strongSwan) | WireGuard | L2TP/IPsec |
|---|---|---|---|---|
| Standard | Community protocol, no RFC | RFC 7296 / 4303 / 3948 | Whitepaper + Linux upstream | RFC 2661 + RFC 3193 |
| Data plane | Userspace (kernel with DCO) | Kernel XFRM, always | Kernel, always | Kernel ESP + PPP daemon |
| Lines of core code | ~100 k | ~400 k (charon + kernel) | ~4 k (kernel module) | PPP + xl2tpd + IPsec |
| Transport | UDP **or TCP** | UDP/500, UDP/4500, ESP proto 50 | UDP only | UDP/1701 inside ESP |
| Traverses a TCP-only proxy | **Yes** (`proto tcp`, port 443) | No | No | No |
| NAT traversal | Native (UDP/TCP) | NAT-T on 4500, auto-detected | Native, plus keepalive | Requires NAT-T + often broken by CG-NAT |
| Roaming / IP change | Reconnect (fast, but a reconnect) | MOBIKE, seamless | Seamless, inherent | Reconnect |
| Cipher agility | Negotiated, configurable | Fully negotiated, FIPS-capable | **None** — fixed suite |Negotiated (ESP) |
| Post-quantum hedge | No (2.6) | IKEv2 with additional key exchanges (ML-KEM plugins) | 256-bit PSK per peer | No |
| Auth models | X.509, PSK, user/pass, PAM, LDAP, TOTP, plugins | X.509, PSK, EAP-TLS/MSCHAPv2/RADIUS, smartcards | Raw public keys only |PPP: PAP/CHAP/MSCHAPv2 + RADIUS |
| Revocation | CRL, OCSP | CRL, OCSP | External orchestration only |via IPsec layer |
| Per-user address assignment | `push`, `ifconfig-pool`, `ccd` | CFG payload + `pools` | Static, out-of-band | IPCP over PPP |
| L2 bridging | `dev tap` | GRETAP/L2TPv3 inside transport mode | No | **Yes**, natively (PPP/L2TPv3) |
| Interop with commercial firewalls | Poor | **Universal** (this is the deciding factor for third-party site-to-site) | Increasingly good, not universal | Good on legacy gear |
| Native OS client | No (app required) | **Yes** (Windows, macOS, iOS, Android, systemd) | App required, but ubiquitous | **Yes**, everywhere legacy |
| Config complexity | Medium | **High** | **Low** |High |
| Relative throughput, same CPU¹ | 1.0× (userspace) / ~3–5× (DCO) | ~3–6× | ~4–7× |~3× |
| Ops observability | status file, management socket | `swanctl --list-sas`, XFRM counters, vici | `wg show` only |split across two daemons |

¹ Order-of-magnitude only. Throughput is dominated by AES-NI presence, packet size, GRO/GSO offload and IRQ affinity. **Measure yours** — see §9.6.

### 3.2 Decision matrix

| Situation | Choose | Why |
|---|---|---|
| Site-to-site with a third party's Cisco/Fortinet/Palo Alto | **IPsec/IKEv2** | The only protocol they will all speak; policy-based selectors are the lingua franca |
| Site-to-site between machines you control | **WireGuard** | Least state, least CPU, roams, trivially auditable config |
| Remote access, corporate laptops, MDM-managed | **IPsec/IKEv2** | Native client on every OS, EAP → RADIUS → existing IdP, MOBIKE |
| Remote access on hostile networks (captive portals, egress proxies) | **OpenVPN over TCP/443** | Only stack that survives a TCP-only path |
| Remote access, engineers, self-service | **WireGuard** + an identity overlay | Fastest to operate; supply the missing control plane |
| Kubernetes node-to-node encryption | **WireGuard** (Cilium/Calico native mode) or IPsec | Kernel data plane, no per-pod sidecar |
| Must be FIPS 140-3 validated | **IPsec/IKEv2** | Kernel crypto API in FIPS mode; WireGuard's suite is not FIPS-approved |
| Legacy Windows/appliance with no installable client | **L2TP/IPsec** | Native dialer; accept the operational cost |
| L2 extension (PXE, WoL, cluster heartbeat) | **OpenVPN TAP** or **L2TPv3-over-IPsec** | The only two in scope that carry Ethernet |

---

## 4. OpenVPN in production

Reference topology used throughout §4–§6:

```
  DC / core site                                      branch site
  10.20.0.0/16                                        10.30.0.0/16
        │                                                   │
   ┌────┴─────┐  198.51.100.10            203.0.113.24  ┌────┴─────┐
   │ gw-core  │◀════════ public internet ═══════════════▶│ gw-branch│
   └──────────┘                                          └──────────┘
        ▲
        │ remote-access pool 10.20.200.0/24
   road warriors (laptops, behind CG-NAT)
```

### 4.1 PKI with Easy-RSA 3

Build the CA on a machine that is **not** the VPN gateway. The CA private key never leaves it.

```bash
$ sudo apt-get install -y openvpn easy-rsa
$ make-cadir ~/pki-vpn && cd ~/pki-vpn

$ cat > vars <<'EOF'
set_var EASYRSA_ALGO            ec
set_var EASYRSA_CURVE           secp384r1
set_var EASYRSA_DIGEST          "sha384"
set_var EASYRSA_CA_EXPIRE       3650
set_var EASYRSA_CERT_EXPIRE     398
set_var EASYRSA_CRL_DAYS        30
set_var EASYRSA_REQ_CN          "Example VPN CA"
set_var EASYRSA_REQ_ORG         "Example Inc"
set_var EASYRSA_REQ_COUNTRY     "AR"
EOF

$ ./easyrsa init-pki
Notice
------
'init-pki' complete; you may now create a CA or requests.
Your newly created PKI dir is:
* /home/ops/pki-vpn/pki

$ ./easyrsa build-ca nopass
Notice
------
CA creation complete. Your new CA certificate is at:
* /home/ops/pki-vpn/pki/ca.crt

$ ./easyrsa build-server-full vpn.example.net nopass
$ ./easyrsa build-client-full alice@example.net nopass
$ ./easyrsa gen-crl
Notice
------
An updated CRL has been created.
CRL file: /home/ops/pki-vpn/pki/crl.pem
```

Elliptic-curve keys mean **no `dh.pem` is needed** — declare `dh none` and let TLS 1.3 do ECDHE. Verify what you built before you ship it:

```bash
$ openssl x509 -in pki/issued/vpn.example.net.crt -noout -subject -dates -ext extendedKeyUsage
subject=CN=vpn.example.net
notBefore=Aug 25 12:04:11 2026 GMT
notAfter=Sep 27 12:04:11 2027 GMT
X509v3 Extended Key Usage:
    TLS Web Server Authentication
```

That `TLS Web Server Authentication` EKU is what makes the client's `remote-cert-tls server` check meaningful: without it, a stolen *client* certificate could be used to impersonate the *server*.

Generate the pre-auth keys:

```bash
$ sudo openvpn --genkey tls-crypt-v2-server /etc/openvpn/server/tc2-server.key
$ sudo openvpn --tls-crypt-v2 /etc/openvpn/server/tc2-server.key \
      --genkey tls-crypt-v2-client /tmp/tc2-alice.key
```

### 4.2 Server configuration — `/etc/openvpn/server/core.conf`

```conf
# ── /etc/openvpn/server/core.conf ─────────────────────────────────────────
# Started by: systemctl enable --now openvpn-server@core.service

# ── Transport ────────────────────────────────────────────────────────────
port                1194
proto               udp4
dev                 tun0
dev-type            tun
topology            subnet          # default since 2.6; declare it anyway
local               198.51.100.10

# ── Identity / PKI ───────────────────────────────────────────────────────
ca                  /etc/openvpn/server/pki/ca.crt
cert                /etc/openvpn/server/pki/vpn.example.net.crt
key                 /etc/openvpn/server/pki/vpn.example.net.key
dh                  none
crl-verify          /etc/openvpn/server/pki/crl.pem
tls-crypt-v2        /etc/openvpn/server/tc2-server.key
remote-cert-tls     client
verify-client-cert  require

# ── Cryptography (2.6 syntax; --cipher is deprecated) ─────────────────────
data-ciphers        AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
auth                SHA384
tls-version-min     1.3
tls-groups          secp384r1:secp256r1:X25519
reneg-sec           3600

# ── Addressing and pushed policy ─────────────────────────────────────────
server              10.20.200.0 255.255.255.0
ifconfig-pool-persist /var/lib/openvpn/ipp-core.txt 3600
client-config-dir   /etc/openvpn/server/ccd
ccd-exclusive                       # no ccd file ⇒ connection refused

push "route 10.20.0.0 255.255.0.0"
push "route 10.30.0.0 255.255.0.0"
push "dhcp-option DNS 10.20.0.53"
push "dhcp-option DOMAIN corp.example.net"
push "block-outside-dns"            # Windows clients: prevents DNS leak
# Full-tunnel instead of split-tunnel would be:
#   push "redirect-gateway def1 bypass-dhcp"

# ── Site-to-site: the branch LAN lives behind one client ──────────────────
route               10.30.0.0 255.255.0.0     # kernel route: tun0 owns it
# and /etc/openvpn/server/ccd/gw-branch.example.net contains the iroute

# ── Client isolation ─────────────────────────────────────────────────────
# client-to-client                   # DISABLED: forces traffic through the
                                     # firewall so policy is enforceable

# ── MTU / fragmentation ──────────────────────────────────────────────────
tun-mtu             1400
mssfix              1340 mtu

# ── Liveness ─────────────────────────────────────────────────────────────
keepalive           10 60           # ping every 10 s, restart after 60 s
persist-key
persist-tun
explicit-exit-notify 1

# ── Privilege drop and hardening ─────────────────────────────────────────
user                openvpn
group               openvpn
# chroot            /var/lib/openvpn/chroot    # enable once scripts are gone

# ── Observability ────────────────────────────────────────────────────────
status              /run/openvpn-server/status-core.log 10
status-version      3
management          /run/openvpn-server/mgmt-core.sock unix
log-append          /var/log/openvpn/core.log
verb                3
mute                20
```

`/etc/openvpn/server/ccd/gw-branch.example.net` — the file name **must equal the certificate CN**:

```conf
# Tell OpenVPN's internal routing table that 10.30.0.0/16 is reachable
# through THIS client. `iroute` is internal; the `route` in the server
# config is what puts the prefix in the kernel. You need BOTH.
iroute 10.30.0.0 255.255.0.0
ifconfig-push 10.20.200.10 255.255.255.0
```

`/etc/openvpn/server/ccd/alice@example.net`:

```conf
ifconfig-push 10.20.200.50 255.255.255.0
push "route 10.20.10.0 255.255.255.0"   # this user only reaches one subnet
```

**The `route` vs `iroute` distinction is a guaranteed exam item.** `route` = "kernel, send this prefix to tun0". `iroute` = "OpenVPN, within tun0, this prefix belongs to that specific client". Omit `iroute` and packets reach tun0 and are dropped by OpenVPN with `MULTI: bad source address from client`.

### 4.3 System plumbing

```bash
$ cat | sudo tee /etc/sysctl.d/90-vpn.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.rp_filter = 2          # loose: tolerate asymmetric VPN paths
net.ipv4.conf.default.rp_filter = 2
EOF
$ sudo sysctl --system | grep -E 'ip_forward|rp_filter'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
```

nftables (canonical; the iptables equivalent is in the comment):

```nft
#!/usr/sbin/nft -f
# /etc/nftables.d/vpn.nft
table inet vpn {
    set vpn_ifaces { type ifname; elements = { "tun0", "wg0", "ipsec0" } }

    chain input {
        type filter hook input priority filter; policy drop;
        ct state established,related accept
        iif lo accept
        udp dport 1194 accept                     # OpenVPN
        udp dport { 500, 4500 } accept            # IKEv2 + NAT-T
        meta l4proto esp accept                   # raw ESP (proto 50)
        udp dport 51820 accept                    # WireGuard
        iifname @vpn_ifaces tcp dport 22 accept
        icmp type { echo-request, destination-unreachable, time-exceeded } accept
        icmpv6 type { echo-request, packet-too-big, time-exceeded,
                      nd-neighbor-solicit, nd-neighbor-advert } accept
        counter comment "input-drop"
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state established,related accept
        # MSS clamping — fixes TCP even when PMTUD is broken upstream
        iifname @vpn_ifaces tcp flags syn tcp option maxseg size set rt mtu
        oifname @vpn_ifaces tcp flags syn tcp option maxseg size set rt mtu
        iifname @vpn_ifaces oifname "eth0" ip daddr 10.20.0.0/16 accept
        iifname "eth0" oifname @vpn_ifaces ip saddr 10.20.0.0/16 accept
        iifname @vpn_ifaces oifname @vpn_ifaces accept
        counter comment "forward-drop"
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        # Only NAT road warriors going to the internet; NEVER NAT site-to-site
        ip saddr 10.20.200.0/24 oifname "eth0" masquerade
    }
}
# iptables equivalent of the NAT rule, for older systems:
#   iptables -t nat -A POSTROUTING -s 10.20.200.0/24 -o eth0 -j MASQUERADE
```

```bash
$ sudo nft -f /etc/nftables.d/vpn.nft
$ sudo nft list ruleset | head -20
$ sudo systemctl enable --now openvpn-server@core.service
$ systemctl status openvpn-server@core.service --no-pager
● openvpn-server@core.service - OpenVPN service for core
     Loaded: loaded (/lib/systemd/system/openvpn-server@.service; enabled)
     Active: active (running) since Tue 2026-08-25 13:02:44 -03; 6s ago
       Docs: man:openvpn(8)
   Main PID: 20418 (openvpn)
     Status: "Initialization Sequence Completed"
      Tasks: 1 (limit: 18985)
     Memory: 2.1M
        CPU: 41ms
     CGroup: /system.slice/system-openvpn\x2dserver.slice/openvpn-server@core.service
             └─20418 /usr/sbin/openvpn --status /run/openvpn-server/status-core.log 10 ...
```

### 4.4 Client profile — single inline `.ovpn`

```conf
# ── alice.ovpn — one file, no side-car certificates ───────────────────────
client
dev tun
proto udp4
remote vpn.example.net 1194
remote vpn-dr.example.net 1194        # failover target
remote-random-hostname
resolv-retry infinite
nobind

persist-key
persist-tun
remote-cert-tls server
verify-x509-name vpn.example.net name
data-ciphers AES-256-GCM:CHACHA20-POLY1305
auth SHA384
tls-version-min 1.3
auth-nocache
pull-filter ignore "redirect-gateway"   # client refuses full-tunnel push
mssfix 1340 mtu
verb 3

<ca>
-----BEGIN CERTIFICATE-----
MIICBjCCAYygAwIBAgIUV1V7... (CA certificate)
-----END CERTIFICATE-----
</ca>
<cert>
-----BEGIN CERTIFICATE-----
MIICLTCCAbOgAwIBAgIRAOc... (client certificate)
-----END CERTIFICATE-----
</cert>
<key>
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEG... (client private key)
-----END PRIVATE KEY-----
</key>
<tls-crypt-v2>
-----BEGIN OpenVPN tls-crypt-v2 client key-----
0DBFvFcJ6PGyzUZFtOQMBQTU... (per-client wrapped key)
-----END OpenVPN tls-crypt-v2 client key-----
</tls-crypt-v2>
```

Connection trace, client side:

```
$ sudo openvpn --config alice.ovpn
2026-08-25 13:11:02 OpenVPN 2.6.12 x86_64-pc-linux-gnu [SSL (OpenSSL)] [LZO] [LZ4] [EPOLL] [DCO]
2026-08-25 13:11:02 library versions: OpenSSL 3.0.13 30 Jan 2024, LZO 2.10
2026-08-25 13:11:02 DCO version: N/A
2026-08-25 13:11:02 TCP/UDP: Preserving recently used remote address: [AF_INET]198.51.100.10:1194
2026-08-25 13:11:02 UDPv4 link local: (not bound)
2026-08-25 13:11:02 UDPv4 link remote: [AF_INET]198.51.100.10:1194
2026-08-25 13:11:02 TLS: Initial packet from [AF_INET]198.51.100.10:1194, sid=8a1f0c2e 5b93d417
2026-08-25 13:11:02 VERIFY OK: depth=1, CN=Example VPN CA
2026-08-25 13:11:02 VERIFY KU OK
2026-08-25 13:11:02 Validating certificate extended key usage
2026-08-25 13:11:02 ++ Certificate has EKU (str) TLS Web Server Authentication, expects TLS Web Server Authentication
2026-08-25 13:11:02 VERIFY EKU OK
2026-08-25 13:11:02 VERIFY X509NAME OK: CN=vpn.example.net
2026-08-25 13:11:02 VERIFY OK: depth=0, CN=vpn.example.net
2026-08-25 13:11:02 Control Channel: TLSv1.3, cipher TLSv1.3 TLS_AES_256_GCM_SHA384, peer certificate: 384 bits EC, curve secp384r1
2026-08-25 13:11:02 [vpn.example.net] Peer Connection Initiated with [AF_INET]198.51.100.10:1194
2026-08-25 13:11:03 PUSH: Received control message: 'PUSH_REPLY,route 10.20.0.0 255.255.0.0,route 10.30.0.0 255.255.0.0,dhcp-option DNS 10.20.0.53,dhcp-option DOMAIN corp.example.net,route-gateway 10.20.200.1,topology subnet,ping 10,ping-restart 60,ifconfig 10.20.200.50 255.255.255.0,peer-id 3,cipher AES-256-GCM'
2026-08-25 13:11:03 OPTIONS IMPORT: --ifconfig/up options modified
2026-08-25 13:11:03 Data Channel: cipher 'AES-256-GCM', peer-id 3
2026-08-25 13:11:03 net_addr_v4_add: 10.20.200.50/24 dev tun0
2026-08-25 13:11:03 net_route_v4_add: 10.20.0.0/16 via 10.20.200.1 dev [NULL] table 0 metric -1
2026-08-25 13:11:03 net_route_v4_add: 10.30.0.0/16 via 10.20.200.1 dev [NULL] table 0 metric -1
2026-08-25 13:11:03 Initialization Sequence Completed
```

`Initialization Sequence Completed` is the only success string that matters. Everything before it is a stage you can bisect.

### 4.5 Bridging mode (`dev tap`) — how it is configured, and why you should not

The objective names bridging, so know the mechanics.

```conf
# ── /etc/openvpn/server/bridge.conf ──────────────────────────────────────
dev tap0
dev-type tap
# The tunnel does NOT own a subnet; it joins an existing L2 segment.
# Args: gateway  netmask  pool-start  pool-end
server-bridge 10.20.10.1 255.255.255.0 10.20.10.200 10.20.10.250
push "dhcp-option DNS 10.20.0.53"
up   /etc/openvpn/server/bridge-up.sh
down /etc/openvpn/server/bridge-down.sh
script-security 2
# NOTE: tap is incompatible with DCO on Linux — this instance runs in userspace.
```

```bash
#!/bin/bash
# /etc/openvpn/server/bridge-up.sh   ($1 = tap device name)
set -euo pipefail
BR=br0; ETH=eth1; TAP="$1"
ip link add name "$BR" type bridge 2>/dev/null || true
ip link set "$BR" up
ip link set "$ETH" master "$BR"
ip link set "$TAP" up promisc on
ip link set "$TAP" master "$BR"
ip addr replace 10.20.10.1/24 dev "$BR"
```

Why to avoid it: every ARP request, DHCP discover, mDNS announcement, IPv6 router advertisement and Windows browser broadcast on the LAN is now replicated and encrypted once per connected client. Fifty clients on a chatty /24 turns broadcast noise into a sustained multi-Mbit/s crypto load carrying zero useful payload — and a broadcast storm at the office now takes down every remote user. Use `dev tun` and, if you genuinely need L2, scope it to a dedicated VLAN with only the devices that require it.

### 4.6 Revocation and lifecycle

```bash
$ cd ~/pki-vpn && ./easyrsa revoke alice@example.net
Type the word 'yes' to continue, or any other input to abort.
  Continue with revocation: yes
Notice
------
Revocation was successful. You must run gen-crl and upload a CRL to your
infrastructure in order to prevent the revoked cert from being accepted.

$ ./easyrsa gen-crl
$ scp pki/crl.pem gw-core:/tmp/crl.pem
$ ssh gw-core 'sudo install -o root -g openvpn -m 0640 /tmp/crl.pem \
      /etc/openvpn/server/pki/crl.pem'
```

OpenVPN re-reads the CRL on each connection attempt, so **no restart is needed** — but the CRL has an expiry (`EASYRSA_CRL_DAYS`), and an expired CRL makes OpenVPN refuse *all* connections. Automate regeneration well inside that window and alert on it:

```bash
$ openssl crl -in /etc/openvpn/server/pki/crl.pem -noout -lastupdate -nextupdate
lastUpdate=Aug 25 13:22:03 2026 GMT
nextUpdate=Sep 24 13:22:03 2026 GMT
```

Kill an active session without waiting for it to notice:

```bash
$ echo "kill alice@example.net" | sudo socat - UNIX-CONNECT:/run/openvpn-server/mgmt-core.sock
SUCCESS: common name 'alice@example.net' found, 1 client(s) killed
```

---

## 5. strongSwan / IPsec in production

### 5.1 Which configuration interface — and why both are examinable

strongSwan has two generations of configuration, and the exam objective names files from both:

| | Legacy (`starter`/`stroke`) | Modern (`vici`/`swanctl`) |
|---|---|---|
| Config files | `/etc/ipsec.conf`, `/etc/ipsec.secrets` | `/etc/swanctl/swanctl.conf` (+ `conf.d/*.conf`) |
| Credentials dir | `/etc/ipsec.d/{cacerts,certs,private}/` | `/etc/swanctl/{x509ca,x509,private,rsa,ecdsa}/` |
| CLI | `ipsec up|down|status|statusall|restart` | `swanctl --load-all|--list-sas|--initiate|--terminate` |
| Reload without dropping SAs | No (`ipsec reload` is coarse) | **Yes** (`swanctl --load-all`) |
| Machine interface | none | **VICI** (Versatile IKE Configuration Interface) — Python/Perl/Ruby bindings |
| Status | Deprecated, removed from modern packages | Current |

**Use `swanctl` for anything new.** Know `ipsec.conf` because you will inherit it and because it is on the exam.

### 5.2 Building the IPsec PKI with `pki`

```bash
$ sudo apt-get install -y strongswan strongswan-swanctl strongswan-pki libcharon-extra-plugins

$ pki --gen --type ecdsa --size 384 --outform pem > ca.key
$ pki --self --ca --lifetime 3650 --in ca.key --type ecdsa \
      --dn "C=AR, O=Example Inc, CN=Example IPsec CA" \
      --san "ipsec-ca.example.net" --outform pem > ca.crt

$ pki --gen --type ecdsa --size 384 --outform pem > gw-core.key
$ pki --pub --in gw-core.key --type ecdsa | \
  pki --issue --lifetime 398 --cacert ca.crt --cakey ca.key \
      --dn "C=AR, O=Example Inc, CN=gw-core.example.net" \
      --san gw-core.example.net --san 198.51.100.10 \
      --flag serverAuth --flag ikeIntermediate --outform pem > gw-core.crt

$ pki --print --in gw-core.crt
  subject:  "C=AR, O=Example Inc, CN=gw-core.example.net"
  issuer:   "C=AR, O=Example Inc, CN=Example IPsec CA"
  validity:  not before Aug 25 13:40:02 2026, ok
             not after  Sep 27 13:40:02 2027, ok (expires in 397 days)
  serial:    3a:1c:88:0f:44:2b:9e:71
  altNames:  gw-core.example.net, 198.51.100.10
  flags:     serverAuth ikeIntermediate
  authkeyId: 5f:b2:33:a1:c0:...
  subjkeyId: 91:0d:7e:44:aa:...
  pubkey:    ECDSA 384 bits
```

Install into the swanctl tree (permissions matter — charon runs as root but the directories are commonly group-readable):

```bash
$ sudo install -m 0644 ca.crt      /etc/swanctl/x509ca/ca.crt
$ sudo install -m 0644 gw-core.crt /etc/swanctl/x509/gw-core.crt
$ sudo install -m 0600 gw-core.key /etc/swanctl/private/gw-core.key
```

### 5.3 Site-to-site, route-based with XFRM interfaces — `/etc/swanctl/conf.d/branch.conf`

Route-based IPsec is the modern design: the SA is bound to an `xfrm` interface via `if_id`, so ordinary routing (including BGP/OSPF, ECMP and per-interface firewalling) decides what enters the tunnel. Policy-based IPsec, where the SPD decides, cannot be inspected with `ip route` and cannot carry a dynamic routing protocol.

```conf
# ── /etc/swanctl/conf.d/branch.conf ──────────────────────────────────────
connections {

    branch {
        version       = 2
        local_addrs   = 198.51.100.10
        remote_addrs  = 203.0.113.24

        # IKE (control plane) proposal. Explicit — no defaults, no downgrade.
        proposals     = aes256gcm16-prfsha384-ecp384

        # Liveness. Without this a dead peer becomes a black hole.
        dpd_delay     = 30s
        dpd_timeout   = 120s

        # Rekey the IKE SA well before the hard lifetime, with jitter.
        rekey_time    = 4h
        over_time     = 30m
        rand_time     = 20m

        # NAT keepalives (charon global default is 20s) and MOBIKE
        mobike        = yes
        encap         = no       # set yes to force UDP/4500 through hostile NAT

        # Retransmission budget before declaring the peer unreachable
        keyingtries   = 0        # 0 = retry forever (site-to-site: correct)

        local {
            auth  = pubkey
            certs = gw-core.crt
            id    = "C=AR, O=Example Inc, CN=gw-core.example.net"
        }
        remote {
            auth  = pubkey
            id    = "C=AR, O=Example Inc, CN=gw-branch.example.net"
        }

        children {
            net {
                # Route-based: wide selectors, routing decides.
                local_ts      = 0.0.0.0/0
                remote_ts     = 0.0.0.0/0

                # Bind this CHILD_SA to XFRM interface id 42
                if_id_in      = 42
                if_id_out     = 42

                esp_proposals = aes256gcm16-ecp384   # ecp384 ⇒ PFS on rekey
                mode          = tunnel

                rekey_time    = 1h
                life_time     = 1h10m
                rand_time     = 5m
                rekey_bytes   = 500000000            # rekey on volume too
                rekey_packets = 1000000

                dpd_action    = restart
                close_action  = start
                start_action  = start                # initiate at load time
                                                     # use "trap" on the responder
                replay_window = 1024                 # multi-queue NICs reorder
            }
        }
    }
}

secrets {
    private-gw-core {
        file = gw-core.key
    }
}
```

Create and route the XFRM interface. Note `if_id` must match `if_id_in`/`if_id_out`, and `0x2a` = 42:

```bash
$ sudo ip link add ipsec0 type xfrm dev eth0 if_id 0x2a
$ sudo ip link set ipsec0 up mtu 1400
$ sudo ip addr add 169.254.42.1/30 dev ipsec0        # optional, for BFD/BGP
$ sudo ip route add 10.30.0.0/16 dev ipsec0

# Disable policy lookup ON the xfrm interface — traffic is already
# selected by routing; leaving it on causes a double-encryption lookup.
$ sudo sysctl -w net.ipv4.conf.ipsec0.disable_policy=1
$ sudo sysctl -w net.ipv4.conf.ipsec0.rp_filter=0
```

Persist it with systemd-networkd (`.netdev` + `.network`, shipped as INI by design):

```ini
# /etc/systemd/network/25-ipsec0.netdev
[NetDev]
Name=ipsec0
Kind=xfrm
MTUBytes=1400

[Xfrm]
InterfaceId=42
Independent=false
```

```ini
# /etc/systemd/network/25-ipsec0.network
[Match]
Name=ipsec0

[Network]
Address=169.254.42.1/30
IPv4ProxyARP=no

[Route]
Destination=10.30.0.0/16
Scope=link
```

Load and bring it up:

```bash
$ sudo systemctl enable --now strongswan.service
$ sudo swanctl --load-all
loaded certificate from '/etc/swanctl/x509/gw-core.crt'
loaded certificate from '/etc/swanctl/x509ca/ca.crt'
loaded ECDSA key from '/etc/swanctl/private/gw-core.key'
loaded connection 'branch'
successfully loaded 1 connections, 0 unloaded

$ sudo swanctl --initiate --child net
[IKE] initiating IKE_SA branch[1] to 203.0.113.24
[ENC] generating IKE_SA_INIT request 0 [ SA KE No N(NATD_S_IP) N(NATD_D_IP) ]
[NET] sending packet: from 198.51.100.10[500] to 203.0.113.24[500] (464 bytes)
[NET] received packet: from 203.0.113.24[500] to 198.51.100.10[500] (441 bytes)
[ENC] parsed IKE_SA_INIT response 0 [ SA KE No N(NATD_S_IP) N(NATD_D_IP) CERTREQ ]
[CFG] selected proposal: IKE:AES_GCM_16_256/PRF_HMAC_SHA2_384/ECP_384
[IKE] authentication of 'C=AR, O=Example Inc, CN=gw-core.example.net' (myself) with ECDSA_WITH_SHA384_DER successful
[IKE] establishing CHILD_SA net{1}
[ENC] generating IKE_AUTH request 1 [ IDi CERT CERTREQ AUTH SA TSi TSr N(MOBIKE_SUP) ]
[NET] sending packet: from 198.51.100.10[500] to 203.0.113.24[500] (1516 bytes)
[NET] received packet: from 203.0.113.24[500] to 198.51.100.10[500] (1264 bytes)
[ENC] parsed IKE_AUTH response 1 [ IDr CERT AUTH SA TSi TSr N(MOBIKE_SUP) ]
[IKE] received end entity cert "C=AR, O=Example Inc, CN=gw-branch.example.net"
[CFG]   using trusted ca certificate "C=AR, O=Example Inc, CN=Example IPsec CA"
[CFG]   checking certificate status of "C=AR, O=Example Inc, CN=gw-branch.example.net"
[CFG]   certificate status is not available
[CFG]   reached self-signed root ca with a path length of 0
[IKE] authentication of 'C=AR, O=Example Inc, CN=gw-branch.example.net' with ECDSA_WITH_SHA384_DER successful
[IKE] IKE_SA branch[1] established between 198.51.100.10[C=AR, O=Example Inc, CN=gw-core.example.net]...203.0.113.24[C=AR, O=Example Inc, CN=gw-branch.example.net]
[IKE] scheduling rekeying in 13847s
[CFG] selected proposal: ESP:AES_GCM_16_256/ECP_384/NO_EXT_SEQ
[IKE] CHILD_SA net{1} established with SPIs c1f3a20b_i 9a44b1c7_o and TS 0.0.0.0/0 === 0.0.0.0/0
initiate completed successfully
```

### 5.4 Remote access (road warrior) with EAP and a virtual IP pool

```conf
# ── /etc/swanctl/conf.d/roadwarrior.conf ─────────────────────────────────
connections {

    rw-eap {
        version      = 2
        local_addrs  = 198.51.100.10
        remote_addrs = %any
        pools        = rw-pool

        proposals    = aes256gcm16-prfsha384-ecp384,aes256-sha384-prfsha384-ecp384

        # Windows/macOS native clients expect the gateway to identify by FQDN
        # matching the certificate SAN, and to send its full chain.
        send_certreq = no
        send_cert    = always
        fragmentation = yes        # IKEv2 fragmentation (RFC 7383): essential,
                                   # cert chains exceed the path MTU

        dpd_delay    = 60s
        rekey_time   = 8h

        local {
            auth  = pubkey
            certs = vpn.example.net.crt
            id    = vpn.example.net           # must equal a SAN in the cert
        }
        remote {
            auth    = eap-radius              # or eap-mschapv2 for local users
            eap_id  = %any
        }

        children {
            rw {
                # Split tunnel: only these prefixes are pushed to the client.
                # Change to 0.0.0.0/0 for a full tunnel.
                local_ts      = 10.20.0.0/16, 10.30.0.0/16
                esp_proposals = aes256gcm16-ecp384,aes256-sha256-ecp384
                mode          = tunnel
                rekey_time    = 1h
                dpd_action    = clear
                inactivity    = 30m           # reap idle laptops
            }
        }
    }
}

pools {
    rw-pool {
        addrs = 10.20.200.0/24
        dns   = 10.20.0.53, 10.20.0.54
    }
}

secrets {
    private-vpn {
        file = vpn.example.net.key
    }
    # Local EAP users, only if not using RADIUS:
    eap-alice {
        id     = alice@example.net
        secret = "REPLACE-WITH-A-GENERATED-SECRET"
    }
}
```

RADIUS wiring lives in `strongswan.conf`, not `swanctl.conf`:

```conf
# ── /etc/strongswan.d/charon/eap-radius.conf (or strongswan.conf) ────────
charon {
    plugins {
        eap-radius {
            servers {
                primary {
                    address = 10.20.0.31
                    secret  = REPLACE-WITH-THE-RADIUS-SHARED-SECRET
                    auth_port = 1812
                    acct_port = 1813
                    nas_identifier = vpn.example.net
                }
            }
            accounting = yes
            class_group = yes        # map RADIUS Class → strongSwan group
        }
    }

    # Structured logging, per subsystem, at levels 0..4
    filelog {
        charon {
            path    = /var/log/charon.log
            time_format = %b %e %T
            ike_name = yes
            default = 1
            ike  = 2
            cfg  = 2
            knl  = 1
            net  = 1
            append  = yes
            flush_line = yes
        }
    }

    # Multi-core crypto and larger worker pool for a busy gateway
    threads = 32
    processor {
        priority_threads {
            high = 4
            medium = 8
        }
    }

    # Install routes into a dedicated table so they do not fight the main one
    install_routes = yes
    routing_table = 220
    routing_table_prio = 220
}
```

### 5.5 The legacy equivalent (`ipsec.conf` / `ipsec.secrets`)

You must be able to read and write this form.

```conf
# ── /etc/ipsec.conf ──────────────────────────────────────────────────────
config setup
    charondebug="ike 2, cfg 2, knl 1"
    uniqueids=yes

conn %default
    keyexchange=ikev2
    ike=aes256gcm16-prfsha384-ecp384!      # trailing ! = strict, no defaults
    esp=aes256gcm16-ecp384!
    dpdaction=restart
    dpddelay=30s
    ikelifetime=4h
    lifetime=1h
    fragmentation=yes
    mobike=yes

# Site-to-site, tunnel mode
conn branch
    left=198.51.100.10
    leftid="C=AR, O=Example Inc, CN=gw-core.example.net"
    leftcert=gw-core.crt
    leftsubnet=10.20.0.0/16
    leftfirewall=yes
    right=203.0.113.24
    rightid="C=AR, O=Example Inc, CN=gw-branch.example.net"
    rightsubnet=10.30.0.0/16
    type=tunnel
    auto=start

# Host-to-host, TRANSPORT mode — note type=transport and no *subnet
conn host-to-host
    left=198.51.100.10
    leftid=@gw-core.example.net
    leftcert=gw-core.crt
    right=198.51.100.20
    rightid=@log-collector.example.net
    type=transport
    auto=route

# Remote access responder
conn rw
    left=198.51.100.10
    leftid=vpn.example.net
    leftcert=vpn.example.net.crt
    leftsubnet=10.20.0.0/16
    leftauth=pubkey
    leftsendcert=always
    right=%any
    rightauth=eap-mschapv2
    rightsourceip=10.20.200.0/24
    rightdns=10.20.0.53
    eap_identity=%identity
    auto=add
```

```conf
# ── /etc/ipsec.secrets ───────────────────────────────────────────────────
# Private key for our certificate (file lives in /etc/ipsec.d/private/)
: ECDSA gw-core.key

# Pre-shared key, scoped to a specific peer pair. Never use a PSK with
# right=%any: every client would share one secret and there is no revocation.
198.51.100.10 203.0.113.24 : PSK "REPLACE-WITH-A-LONG-RANDOM-SECRET"

# EAP credential for one user
alice@example.net : EAP "REPLACE-WITH-A-GENERATED-SECRET"

# XAuth (IKEv1 legacy)
bob@example.net : XAUTH "REPLACE-ME"
```

The `auto=` semantics are examinable: `add` = load only (responder), `route` = install a trap policy so the first matching packet triggers negotiation, `start` = negotiate immediately at startup. `start_action` in `swanctl.conf` is the direct successor.

Legacy CLI, with realistic output:

```bash
$ sudo ipsec restart
$ sudo ipsec status
Security Associations (1 up, 0 connecting):
      branch[1]: ESTABLISHED 27 minutes ago, 198.51.100.10[C=AR, O=Example Inc, CN=gw-core.example.net]...203.0.113.24[C=AR, O=Example Inc, CN=gw-branch.example.net]
      branch{1}: INSTALLED, TUNNEL, reqid 1, ESP SPIs: c1f3a20b_i 9a44b1c7_o
      branch{1}:   10.20.0.0/16 === 10.30.0.0/16

$ sudo ipsec up branch
$ sudo ipsec down branch
$ sudo ipsec statusall | sed -n '1,12p'
Status of IKE charon daemon (strongSwan 5.9.13, Linux 6.8.0-45-generic, x86_64):
  uptime: 34 minutes, since Aug 25 13:22:11 2026
  malloc: sbrk 3117056, mmap 0, used 1005104, free 2111952
  worker threads: 11 of 16 idle, 5/0/0/0 working, job queue: 0/0/0/0, scheduled: 8
  loaded plugins: charon aesni aes rc2 sha2 sha1 md5 mgf1 random nonce x509 revocation
    constraints pubkey pkcs1 pkcs7 pkcs8 pkcs12 pgp dnskey sshkey pem openssl gcm
    curve25519 xcbc cmac hmac kdf gcm drbg attr kernel-netlink resolve socket-default
    connmark stroke vici updown eap-identity eap-md5 eap-mschapv2 eap-tls eap-radius
    xauth-generic counters
Listening IP addresses:
  198.51.100.10
```

### 5.6 High availability

| Approach | Mechanism | Failover | Trade-off |
|---|---|---|---|
| **Active/passive with VRRP** | keepalived owns the VIP; charon binds `%any` and starts on transition | Full re-negotiation of every SA (seconds to minutes at scale) | Simple, no shared state; a rekey storm on failover |
| **Active/passive with state sync** | `ha` plugin (ClusterIP) syncs IKE/CHILD SAs | Sub-second, SAs survive | Complex, requires a dedicated sync link, tight version coupling |
| **Active/active with ECMP** | Multiple gateways, distinct public IPs; peers configured with multiple `remote_addrs` | Peer-driven; depends on peer behaviour | Only works if the peer supports multiple gateways; asymmetric return paths need care |
| **Anycast** | Same IP announced from multiple sites via BGP | Route convergence | ESP flows must land on the same box; a re-converge kills the SA |

For most deployments: **active/passive VRPP plus `dpd_action = restart` and short `dpd_delay` on the peers**, and accept a 30–60 s failover. Reserve state synchronisation for tunnels whose loss is a revenue event.

---

## 6. WireGuard in production

### 6.1 Key material

```bash
$ sudo install -d -m 0700 /etc/wireguard
$ umask 077
$ wg genkey | sudo tee /etc/wireguard/hub.key | wg pubkey | sudo tee /etc/wireguard/hub.pub
mB1sQ2v9NnCk8pR4uYw1eXhL0dTgAo7ZsFj3KqPbWnE=

$ wg genkey | tee /tmp/branch.key | wg pubkey
7Xk2rVdLp0aCmH9uJ4sQxNwTf1EoZbY6gRk8ViUcPnA=

# A per-peer pre-shared key: mixed into the Noise handshake as an additional
# symmetric layer. It hedges against a future break of Curve25519 (harvest-now,
# decrypt-later) at zero cost. Use one per peer pair.
$ wg genpsk
oQ3mZ7bK1sVxT4pRfN0uYcJgE9dLhAiW2sBnXvQrMkU=

$ sudo chmod 0600 /etc/wireguard/*.key
```

**Never generate keys on a central machine and distribute private keys.** Each peer generates its own; only the public key travels.

### 6.2 Hub — `/etc/wireguard/wg0.conf`

```ini
# ── /etc/wireguard/wg0.conf  (hub: gw-core, 198.51.100.10) ───────────────
# Managed by wg-quick(8): systemctl enable --now wg-quick@wg0

[Interface]
Address     = 10.99.0.1/24, fd00:99::1/64
ListenPort  = 51820
PrivateKey  = REPLACE-WITH-CONTENTS-OF-/etc/wireguard/hub.key
# Better: keep the key out of this file entirely (wg-quick 1.0.20200827+):
#   PostUp = wg set %i private-key /etc/wireguard/hub.key
MTU         = 1420
FwMark      = 0xca6c
Table       = auto
SaveConfig  = false        # true rewrites this file on down: loses comments

PostUp   = sysctl -qw net.ipv4.ip_forward=1
PostUp   = sysctl -qw net.ipv6.conf.all.forwarding=1
PostUp   = nft -f /etc/nftables.d/vpn.nft
PostDown = nft delete table inet vpn || true

# ── Peer: gw-branch (site-to-site, static endpoint) ──────────────────────
[Peer]
# gw-branch.example.net
PublicKey    = 7Xk2rVdLp0aCmH9uJ4sQxNwTf1EoZbY6gRk8ViUcPnA=
PresharedKey = oQ3mZ7bK1sVxT4pRfN0uYcJgE9dLhAiW2sBnXvQrMkU=
Endpoint     = 203.0.113.24:51820
# Cryptokey routing: this peer OWNS these prefixes, inbound and outbound.
AllowedIPs   = 10.99.0.2/32, 10.30.0.0/16, fd00:99::2/128
PersistentKeepalive = 25

# ── Peer: alice's laptop (roaming, no fixed endpoint) ────────────────────
[Peer]
# alice@example.net — thinkpad-t14, enrolled 2026-08-25
PublicKey    = kR8vNw2LqTzYd6PmEuXbA1sHf0oJcVi9GnQr3KyBWtM=
PresharedKey = uT6xLpB0nWq9EyMcZv2Rk4SdAg1IhFjX7oNbUrKmVsQ=
AllowedIPs   = 10.99.0.50/32
# No Endpoint: the hub learns it from the first authenticated packet.
# No PersistentKeepalive on the hub side: the client behind NAT sends it.
```

### 6.3 Branch and client

```ini
# ── /etc/wireguard/wg0.conf  (gw-branch, 203.0.113.24) ───────────────────
[Interface]
Address    = 10.99.0.2/24
ListenPort = 51820
PrivateKey = REPLACE-WITH-CONTENTS-OF-/etc/wireguard/branch.key
MTU        = 1420

[Peer]
# gw-core
PublicKey    = mB1sQ2v9NnCk8pR4uYw1eXhL0dTgAo7ZsFj3KqPbWnE=
PresharedKey = oQ3mZ7bK1sVxT4pRfN0uYcJgE9dLhAiW2sBnXvQrMkU=
Endpoint     = 198.51.100.10:51820
AllowedIPs   = 10.99.0.0/24, 10.20.0.0/16
PersistentKeepalive = 25
```

```ini
# ── alice's laptop: full-tunnel profile ──────────────────────────────────
[Interface]
Address    = 10.99.0.50/32
PrivateKey = REPLACE-WITH-THE-LAPTOP-PRIVATE-KEY
DNS        = 10.20.0.53, corp.example.net
MTU        = 1420

[Peer]
PublicKey    = mB1sQ2v9NnCk8pR4uYw1eXhL0dTgAo7ZsFj3KqPbWnE=
PresharedKey = uT6xLpB0nWq9EyMcZv2Rk4SdAg1IhFjX7oNbUrKmVsQ=
Endpoint     = vpn.example.net:51820
# 0.0.0.0/0 ⇒ wg-quick installs the fwmark + policy-routing dance below
AllowedIPs   = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

Split-tunnel variant — change one line: `AllowedIPs = 10.20.0.0/16, 10.30.0.0/16, 10.99.0.0/24`. In WireGuard, split vs full tunnel is *entirely* that field. There is no server-side push and no way for the hub to force it; the client's `AllowedIPs` is the policy. If you need server-enforced policy, enforce it with firewall rules on the hub, not by hoping about the client config.

### 6.4 What `wg-quick` actually does with a default route

```bash
$ sudo wg-quick up wg0
[#] ip link add wg0 type wireguard
[#] wg setconf wg0 /dev/fd/63
[#] ip -4 address add 10.99.0.50/32 dev wg0
[#] ip link set mtu 1420 up dev wg0
[#] resolvconf -a wg0 -m 0 -x
[#] wg set wg0 fwmark 51820
[#] ip -6 route add ::/0 dev wg0 table 51820
[#] ip -6 rule add not fwmark 51820 table 51820
[#] ip -6 rule add table main suppress_prefixlength 0
[#] ip6tables-restore -n
[#] ip -4 route add 0.0.0.0/0 dev wg0 table 51820
[#] ip -4 rule add not fwmark 51820 table 51820
[#] ip -4 rule add table main suppress_prefixlength 0
[#] iptables-restore -n
[#] sysctl -q net.ipv4.conf.all.src_valid_mark=1
```

The three-line trick is worth understanding because it is what makes a full tunnel work without a routing loop:

1. `wg set wg0 fwmark 51820` — WireGuard's own encrypted UDP packets are marked.
2. `ip rule add not fwmark 51820 table 51820` — everything *except* those packets uses the table whose default route is `wg0`. The tunnel's own traffic therefore escapes to the real internet instead of recursing into itself.
3. `ip rule add table main suppress_prefixlength 0` — consult `main` first, but ignore its *default* route (prefix length 0). Specific routes (LAN, the endpoint's /32) still win, so you keep local connectivity.

```bash
$ ip rule show
0:      from all lookup local
32764:  from all lookup main suppress_prefixlength 0
32765:  not from all fwmark 0xca6c lookup 51820
32766:  from all lookup main
32767:  from all lookup default

$ ip route show table 51820
default dev wg0 scope link
```

### 6.5 Live configuration changes without dropping sessions

`wg setconf` replaces the whole peer set and resets handshakes. `wg syncconf` computes a diff — this is the one to use on a live hub:

```bash
$ sudo wg set wg0 peer 9nH4vKzR2tLqB0eXcWm7PdAy1UgTsFjNoIrVbQ3kZuE= \
      preshared-key /etc/wireguard/psk-carol \
      allowed-ips 10.99.0.51/32

$ sudo wg-quick strip wg0 | sudo wg syncconf wg0 /dev/stdin   # reload from file
$ sudo wg set wg0 peer 9nH4vKzR2tLqB0eXcWm7PdAy1UgTsFjNoIrVbQ3kZuE= remove
```

Revocation is exactly that `remove` — there is no CRL, so your automation must be the authority. Store the peer inventory in git, render `wg0.conf`, and reconcile with `syncconf`.

### 6.6 Verification

```bash
$ sudo wg show wg0
interface: wg0
  public key: mB1sQ2v9NnCk8pR4uYw1eXhL0dTgAo7ZsFj3KqPbWnE=
  private key: (hidden)
  listening port: 51820
  fwmark: 0xca6c

peer: 7Xk2rVdLp0aCmH9uJ4sQxNwTf1EoZbY6gRk8ViUcPnA=
  preshared key: (hidden)
  endpoint: 203.0.113.24:51820
  allowed ips: 10.99.0.2/32, 10.30.0.0/16, fd00:99::2/128
  latest handshake: 47 seconds ago
  transfer: 3.21 MiB received, 8.44 MiB sent
  persistent keepalive: every 25 seconds

peer: kR8vNw2LqTzYd6PmEuXbA1sHf0oJcVi9GnQr3KyBWtM=
  preshared key: (hidden)
  endpoint: 190.17.44.201:57312
  allowed ips: 10.99.0.50/32
  latest handshake: 1 minute, 12 seconds ago
  transfer: 412.03 KiB received, 2.19 MiB sent

$ sudo wg show wg0 latest-handshakes
7Xk2rVdLp0aCmH9uJ4sQxNwTf1EoZbY6gRk8ViUcPnA=    1787061127
kR8vNw2LqTzYd6PmEuXbA1sHf0oJcVi9GnQr3KyBWtM=    1787061062

# Machine-readable: iface line, then one tab-separated line per peer:
# pubkey  psk  endpoint  allowed-ips  last-handshake  rx  tx  keepalive
$ sudo wg show all dump
wg0  mB1s...=  (none)  51820  0xca6c
wg0  7Xk2...=  (none)  203.0.113.24:51820  10.99.0.2/32,10.30.0.0/16  1787061127  3366255  8850739  25
wg0  kR8v...=  (none)  190.17.44.201:57312  10.99.0.50/32  1787061062  421918  2296381  off
```

The one-line health check every monitoring system should run:

```bash
$ sudo wg show all dump | awk 'NF>5 && (systime()-$6) > 180 {print "STALE:", $1, $2}'
```

---

## 7. L2TP — awareness level

L2TP does not encrypt anything. It is a tunnelling protocol for PPP frames (L2TPv2, RFC 2661) or arbitrary L2 pseudowires (L2TPv3, RFC 3931). Confidentiality comes from wrapping it in **IPsec transport mode** (RFC 3193) — hence "L2TP/IPsec". Know why it persists: every Windows, macOS, iOS and Android device has a built-in L2TP/IPsec dialer, so it needs no client software on hardware you do not control.

| | L2TPv2 | L2TPv3 |
|---|---|---|
| RFC | 2661 | 3931 |
| Payload | PPP only | PPP, **Ethernet**, Frame Relay, HDLC |
| Transport | UDP/1701 | UDP/1701 or **IP protocol 115** |
| Typical use | Remote access with the native OS dialer | L2 pseudowire between sites (an alternative to OpenVPN TAP) |
| Linux tooling | `xl2tpd` + `pppd` + strongSwan | `ip l2tp` (kernel, no daemon) |

The packet stack for remote access is four layers deep, which is why its MTU behaviour is bad and its debugging is split across three daemons:

```
IP | ESP | UDP(1701) | L2TP | PPP | IP | TCP | payload
        └─ IPsec transport mode protects everything to its right ─┘
```

Minimal L2TPv3 Ethernet pseudowire over an existing IPsec transport-mode SA, no daemon required:

```bash
# On gw-core (198.51.100.10)
$ sudo ip l2tp add tunnel tunnel_id 100 peer_tunnel_id 200 \
      encap udp local 198.51.100.10 remote 203.0.113.24 \
      udp_sport 1701 udp_dport 1701
$ sudo ip l2tp add session tunnel_id 100 session_id 1000 peer_session_id 2000 \
      name l2tpeth0
$ sudo ip link set l2tpeth0 up mtu 1400
$ sudo ip link set l2tpeth0 master br0        # now it is a real L2 pseudowire

$ sudo ip l2tp show tunnel
Tunnel 100, encap UDP
  From 198.51.100.10 to 203.0.113.24
  Peer tunnel 200
  UDP source / dest ports: 1701/1701
$ sudo ip l2tp show session
Session 1000 in tunnel 100
  Peer session 2000, tunnel 200
  interface name: l2tpeth0
  offset 0, peer offset 0
```

And the classic remote-access server, `/etc/xl2tpd/xl2tpd.conf`:

```ini
[global]
port = 1701
access control = no
ipsec saref = yes
force userspace = yes

[lns default]
ip range = 10.20.210.100-10.20.210.199
local ip = 10.20.210.1
require chap = yes
refuse pap = yes
require authentication = yes
name = vpn.example.net
ppp debug = no
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
```

```conf
# /etc/ppp/options.xl2tpd
require-mschap-v2
refuse-pap
refuse-chap
refuse-mschap
ms-dns 10.20.0.53
noccp
auth
idle 1800
mtu 1400
mru 1400
lcp-echo-interval 30
lcp-echo-failure 4
```

Deploy this only when a native client is a hard requirement. Its NAT behaviour is poor (many CG-NAT paths break it), its MTU stack is fragile, and it forces the IPsec layer down to whatever the built-in dialer supports.

---

## 8. Infrastructure as code

### 8.1 Netplan — declarative WireGuard on Ubuntu

```yaml
# /etc/netplan/60-wireguard.yaml   (chmod 0600 — it references key files)
network:
  version: 2
  renderer: networkd
  tunnels:
    wg0:
      mode: wireguard
      addresses:
        - 10.99.0.1/24
        - "fd00:99::1/64"
      port: 51820
      mark: 51820
      # Path to a file containing ONLY the base64 private key.
      key: /etc/wireguard/hub.key
      mtu: 1420
      peers:
        - keys:
            public: "7Xk2rVdLp0aCmH9uJ4sQxNwTf1EoZbY6gRk8ViUcPnA="
            shared: /etc/wireguard/psk-branch
          allowed-ips:
            - 10.99.0.2/32
            - 10.30.0.0/16
            - "fd00:99::2/128"
          endpoint: "203.0.113.24:51820"
          keepalive: 25
        - keys:
            public: "kR8vNw2LqTzYd6PmEuXbA1sHf0oJcVi9GnQr3KyBWtM="
            shared: /etc/wireguard/psk-alice
          allowed-ips:
            - 10.99.0.50/32
      routes:
        - to: 10.30.0.0/16
          scope: link
```

```bash
$ sudo chmod 0600 /etc/netplan/60-wireguard.yaml
$ sudo netplan generate && sudo netplan apply
$ sudo wg show wg0 | head -5
interface: wg0
  public key: mB1sQ2v9NnCk8pR4uYw1eXhL0dTgAo7ZsFj3KqPbWnE=
  private key: (hidden)
  listening port: 51820
  fwmark: 0xca6c
```

### 8.2 Ansible — peer enrolment as a reconciled inventory

```yaml
# ── roles/wireguard-hub/tasks/main.yml ───────────────────────────────────
---
- name: Ensure WireGuard is installed
  ansible.builtin.package:
    name: "{{ wireguard_packages }}"
    state: present
  vars:
    wireguard_packages:
      - wireguard-tools
      - nftables

- name: Ensure the configuration directory is private
  ansible.builtin.file:
    path: /etc/wireguard
    state: directory
    owner: root
    group: root
    mode: "0700"

- name: Generate the hub private key exactly once (never overwrite)
  ansible.builtin.shell:
    cmd: 'set -o pipefail; umask 077; wg genkey > /etc/wireguard/hub.key'
    creates: /etc/wireguard/hub.key
    executable: /bin/bash

- name: Derive the hub public key
  ansible.builtin.command:
    cmd: wg pubkey
    stdin: "{{ lookup('ansible.builtin.file', '/etc/wireguard/hub.key') }}"
  register: hub_pubkey
  changed_when: false
  no_log: true

- name: Render wg0.conf from the peer inventory
  ansible.builtin.template:
    src: wg0.conf.j2
    dest: /etc/wireguard/wg0.conf
    owner: root
    group: root
    mode: "0600"
    validate: "wg-quick strip %s > /dev/null"
  register: wg_config

- name: Enable forwarding
  ansible.posix.sysctl:
    name: "{{ item }}"
    value: "1"
    sysctl_file: /etc/sysctl.d/90-vpn.conf
    state: present
    reload: true
  loop:
    - net.ipv4.ip_forward
    - net.ipv6.conf.all.forwarding

- name: Ensure the interface is up and enabled at boot
  ansible.builtin.systemd:
    name: wg-quick@wg0
    enabled: true
    state: started
    daemon_reload: true

# Hot-reload without tearing down live sessions
- name: Sync peer set into the running interface
  ansible.builtin.shell:
    cmd: 'set -o pipefail; wg-quick strip wg0 | wg syncconf wg0 /dev/stdin'
    executable: /bin/bash
  when: wg_config.changed
  changed_when: true

- name: Assert every configured peer has a recent handshake
  ansible.builtin.shell:
    cmd: |
      set -o pipefail
      stale=$(wg show all dump | awk 'NF>5 && (systime()-$6) > 300 {print $2}')
      [ -z "$stale" ] || { echo "stale peers: $stale"; exit 1; }
    executable: /bin/bash
  register: wg_health
  changed_when: false
  failed_when: wg_health.rc != 0
  when: wireguard_assert_health | default(false)
```

```jinja
{# ── roles/wireguard-hub/templates/wg0.conf.j2 ───────────────────────── #}
# MANAGED BY ANSIBLE — local edits will be overwritten.
[Interface]
Address = {{ wg_hub_addresses | join(', ') }}
ListenPort = {{ wg_listen_port | default(51820) }}
MTU = {{ wg_mtu | default(1420) }}
PostUp = wg set %i private-key /etc/wireguard/hub.key
Table = auto

{% for peer in wg_peers | sort(attribute='name') %}
[Peer]
# {{ peer.name }} — owner {{ peer.owner }} — enrolled {{ peer.enrolled }}
PublicKey = {{ peer.public_key }}
{% if peer.preshared_key_file is defined %}
PresharedKey = {{ lookup('ansible.builtin.file', peer.preshared_key_file) }}
{% endif %}
AllowedIPs = {{ peer.allowed_ips | join(', ') }}
{% if peer.endpoint is defined %}
Endpoint = {{ peer.endpoint }}
{% endif %}
{% if peer.keepalive is defined %}
PersistentKeepalive = {{ peer.keepalive }}
{% endif %}

{% endfor %}
```

```yaml
# ── group_vars/vpn_hubs.yml ──────────────────────────────────────────────
wg_hub_addresses:
  - 10.99.0.1/24
  - "fd00:99::1/64"
wg_listen_port: 51820
wg_mtu: 1420
wg_peers:
  - name: gw-branch
    owner: platform-team
    enrolled: "2026-08-25"
    public_key: "7Xk2rVdLp0aCmH9uJ4sQxNwTf1EoZbY6gRk8ViUcPnA="
    preshared_key_file: /etc/wireguard/psk-branch
    allowed_ips: ["10.99.0.2/32", "10.30.0.0/16"]
    endpoint: "203.0.113.24:51820"
    keepalive: 25
  - name: alice-thinkpad
    owner: alice@example.net
    enrolled: "2026-08-25"
    public_key: "kR8vNw2LqTzYd6PmEuXbA1sHf0oJcVi9GnQr3KyBWtM="
    preshared_key_file: /etc/wireguard/psk-alice
    allowed_ips: ["10.99.0.50/32"]
```

### 8.3 Kubernetes — a WireGuard egress gateway

Legitimate use case: pods in a cluster must reach a partner network reachable only over a site-to-site tunnel, and the partner will only whitelist one source address.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: vpn-egress
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
---
apiVersion: v1
kind: Secret
metadata:
  name: wg-gateway-keys
  namespace: vpn-egress
type: Opaque
stringData:
  # Populate from an external secret manager; never commit real keys.
  privatekey: "REPLACE-WITH-BASE64-WIREGUARD-PRIVATE-KEY"
  psk-partner: "REPLACE-WITH-BASE64-WIREGUARD-PRESHARED-KEY"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: wg-gateway-config
  namespace: vpn-egress
data:
  wg0.conf: |
    [Interface]
    Address = 10.99.1.10/24
    ListenPort = 51820
    MTU = 1380
    # Private key is injected at start-up from the mounted Secret,
    # so it never appears in a ConfigMap or in `kubectl describe`.
    PostUp = wg set %i private-key /etc/wireguard/keys/privatekey
    PostUp = sysctl -qw net.ipv4.ip_forward=1
    PostUp = iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
    PostUp = iptables -A FORWARD -i eth0 -o wg0 -j ACCEPT
    PostUp = iptables -A FORWARD -i wg0 -o eth0 -m state \
             --state RELATED,ESTABLISHED -j ACCEPT
    PostDown = iptables -t nat -D POSTROUTING -o wg0 -j MASQUERADE || true

    [Peer]
    # partner-gw
    PublicKey = 7Xk2rVdLp0aCmH9uJ4sQxNwTf1EoZbY6gRk8ViUcPnA=
    PresharedKey = REPLACED-AT-STARTUP
    Endpoint = 203.0.113.24:51820
    AllowedIPs = 10.99.1.0/24, 172.31.0.0/16
    PersistentKeepalive = 25
  healthcheck.sh: |
    #!/bin/sh
    # Unhealthy if no peer has handshaken within 180 s (REJECT_AFTER_TIME).
    set -eu
    now=$(date +%s)
    wg show all dump | awk -v now="$now" '
      NF > 5 { if (now - $6 < 180) ok = 1 }
      END { exit(ok ? 0 : 1) }
    '
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wg-egress-gateway
  namespace: vpn-egress
  labels:
    app.kubernetes.io/name: wg-egress-gateway
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: wg-egress-gateway
  template:
    metadata:
      labels:
        app.kubernetes.io/name: wg-egress-gateway
    spec:
      automountServiceAccountToken: false
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: wg-egress-gateway
      containers:
        - name: wireguard
          image: ghcr.io/example/wireguard-go-tools:1.0.20250521
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -eu
              install -m 0600 /config/wg0.conf /etc/wireguard/wg0.conf
              sed -i "s|REPLACED-AT-STARTUP|$(cat /etc/wireguard/keys/psk-partner)|" \
                  /etc/wireguard/wg0.conf
              exec wg-quick up wg0 && sleep infinity
          securityContext:
            allowPrivilegeEscalation: true
            readOnlyRootFilesystem: false
            capabilities:
              drop: ["ALL"]
              add: ["NET_ADMIN", "NET_RAW", "SYS_MODULE"]
          ports:
            - name: wireguard
              containerPort: 51820
              protocol: UDP
          volumeMounts:
            - { name: config,  mountPath: /config,             readOnly: true }
            - { name: keys,    mountPath: /etc/wireguard/keys, readOnly: true }
            - { name: modules, mountPath: /lib/modules,        readOnly: true }
            - { name: wgdir,   mountPath: /etc/wireguard }
          livenessProbe:
            exec:
              command: ["/bin/sh", "/config/healthcheck.sh"]
            initialDelaySeconds: 30
            periodSeconds: 30
            timeoutSeconds: 5
            failureThreshold: 3
          readinessProbe:
            exec:
              command: ["/bin/sh", "/config/healthcheck.sh"]
            initialDelaySeconds: 10
            periodSeconds: 10
          resources:
            requests: { cpu: "250m", memory: "64Mi" }
            limits:   { cpu: "2",    memory: "256Mi" }
      volumes:
        - name: config
          configMap:
            name: wg-gateway-config
            defaultMode: 0555
        - name: keys
          secret:
            secretName: wg-gateway-keys
            defaultMode: 0400
        - name: modules
          hostPath: { path: /lib/modules, type: Directory }
        - name: wgdir
          emptyDir: { medium: Memory }
---
apiVersion: v1
kind: Service
metadata:
  name: wg-egress-gateway
  namespace: vpn-egress
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local     # preserve the client source IP
  selector:
    app.kubernetes.io/name: wg-egress-gateway
  ports:
    - name: wireguard
      port: 51820
      targetPort: 51820
      protocol: UDP
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: wg-egress-gateway
  namespace: vpn-egress
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: wg-egress-gateway
  policyTypes: ["Ingress", "Egress"]
  ingress:
    - ports:
        - { port: 51820, protocol: UDP }
  egress:
    - to:
        - ipBlock: { cidr: 203.0.113.24/32 }
      ports:
        - { port: 51820, protocol: UDP }
    - to:
        - ipBlock: { cidr: 172.31.0.0/16 }
```

### 8.4 Prometheus alerting rules

```yaml
# /etc/prometheus/rules/vpn.yml
groups:
  - name: vpn.rules
    interval: 30s
    rules:
      - alert: WireGuardPeerHandshakeStale
        expr: |
          (time() - wireguard_latest_handshake_seconds) > 300
          and wireguard_latest_handshake_seconds > 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "WireGuard peer {{ $labels.public_key }} has not handshaken in 5m"
          description: >-
            REJECT_AFTER_TIME is 180 s, so this tunnel is passing no traffic.
            Check reachability of the endpoint on UDP/51820 and confirm the
            peer's AllowedIPs do not overlap another peer's.
          runbook_url: "https://runbooks.example.net/vpn/wireguard-stale-handshake"

      - alert: WireGuardPeerNeverHandshaked
        expr: wireguard_latest_handshake_seconds == 0
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: "WireGuard peer {{ $labels.public_key }} has never completed a handshake"

      - alert: IPsecChildSAMissing
        expr: strongswan_child_sa_state{state="INSTALLED"} == 0
        for: 3m
        labels: { severity: critical }
        annotations:
          summary: "CHILD_SA {{ $labels.child }} is not INSTALLED"
          description: >-
            Check `swanctl --list-sas`. TS_UNACCEPTABLE means the traffic
            selectors differ between peers; NO_PROPOSAL_CHOSEN means the
            algorithm proposals do not intersect.

      - alert: IPsecReplayWindowDrops
        expr: rate(node_xfrm_state_replay_window_total[5m]) > 0
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: "ESP packets dropped by the anti-replay window"
          description: >-
            Multi-queue NICs reorder packets. Raise replay_window in the child
            config (1024) or pin RX queues; see /proc/net/xfrm_stat.

      - alert: OpenVPNCertificateExpiringSoon
        expr: (openvpn_certificate_expiry_seconds - time()) < 30 * 86400
        for: 1h
        labels: { severity: warning }
        annotations:
          summary: "OpenVPN certificate {{ $labels.cn }} expires in under 30 days"

      - alert: OpenVPNCRLExpiringSoon
        expr: (openvpn_crl_next_update_seconds - time()) < 7 * 86400
        for: 1h
        labels: { severity: critical }
        annotations:
          summary: "The OpenVPN CRL expires in under 7 days"
          description: >-
            An EXPIRED CRL makes OpenVPN reject EVERY client, not just revoked
            ones. Run `easyrsa gen-crl` and redeploy crl.pem.
```

---

## 9. Verification and failure diagnosis

### 9.1 The layered method — always bisect, never guess

Work outward-in. Each rung either passes or localises the fault; do not skip a rung because you "know" it is fine.

```
 L0  Is the daemon running and did it parse the config?
       systemctl status / journalctl -u ; openvpn --config X --test-crypto
 L1  Does the outer UDP/ESP packet leave and arrive?
       tcpdump on BOTH ends simultaneously
 L2  Did the control plane authenticate?
       "Initialization Sequence Completed" / IKE_SA ESTABLISHED / latest handshake
 L3  Is a data-plane SA installed and are its counters moving?
       ip xfrm state ; wg show transfer ; openvpn status file
 L4  Does the kernel route the inner packet into the tunnel?
       ip route get <dst> ; ip rule ; ip xfrm policy
 L5  Does the firewall permit forwarding, and is NAT correct?
       nft list ruleset ; counters on the drop rules
 L6  Is the MTU right?
       ping -M do -s <n> ; MSS clamp present?
 L7  Is the far-side host actually listening and does IT route back?
```

### 9.2 Packet-level observation

```bash
# IPsec: watch IKE and ESP together
$ sudo tcpdump -ni eth0 -vv 'udp port 500 or udp port 4500 or ip proto 50'
13:52:14.220144 IP 198.51.100.10.500 > 203.0.113.24.500: isakmp: parent_sa ikev2_init[I]
13:52:14.281903 IP 203.0.113.24.500 > 198.51.100.10.500: isakmp: parent_sa ikev2_init[R]
13:52:14.301774 IP 198.51.100.10.500 > 203.0.113.24.500: isakmp: child_sa  ikev2_auth[I]
13:52:14.372910 IP 203.0.113.24.500 > 198.51.100.10.500: isakmp: child_sa  ikev2_auth[R]
13:52:15.104822 IP 198.51.100.10 > 203.0.113.24: ESP(spi=0x9a44b1c7,seq=0x1), length 132
13:52:15.166301 IP 203.0.113.24 > 198.51.100.10: ESP(spi=0xc1f3a20b,seq=0x1), length 132

# See the DECRYPTED inner packet: capture on the xfrm/tun/wg interface instead
$ sudo tcpdump -ni ipsec0 -c 4 icmp
13:52:15.104701 IP 10.20.0.5 > 10.30.0.9: ICMP echo request, id 4711, seq 1, length 64
13:52:15.166420 IP 10.30.0.9 > 10.20.0.5: ICMP echo reply,   id 4711, seq 1, length 64

# WireGuard: only the outer UDP is visible; there is no plaintext on the wire
$ sudo tcpdump -ni eth0 'udp port 51820' -c 4
13:55:02.118220 IP 198.51.100.10.51820 > 203.0.113.24.51820: UDP, length 148   # handshake initiation
13:55:02.181330 IP 203.0.113.24.51820 > 198.51.100.10.51820: UDP, length 92    # handshake response
13:55:02.181902 IP 198.51.100.10.51820 > 203.0.113.24.51820: UDP, length 32    # keepalive
13:55:03.204411 IP 198.51.100.10.51820 > 203.0.113.24.51820: UDP, length 128   # transport data
```

Packet lengths are a fingerprint: WireGuard handshake initiation is 148 bytes, response 92, cookie reply 64, keepalive 32. If you see 148 repeatedly with no 92 in reply, the responder is not answering — wrong key, wrong port, or a firewall.

### 9.3 Kernel state inspection (IPsec)

```bash
$ sudo ip xfrm state
src 198.51.100.10 dst 203.0.113.24
	proto esp spi 0x9a44b1c7 reqid 1 mode tunnel
	replay-window 1024 flag af-unspec esn
	aead rfc4106(gcm(aes)) 0x7c1e...4b20 128
	anti-replay esn context:
	 seq-hi 0x0, seq 0x0, oseq-hi 0x0, oseq 0x1a4f
	 replay_window 1024, bitmap-length 32
	sel src 0.0.0.0/0 dst 0.0.0.0/0
	if_id 0x2a
src 203.0.113.24 dst 198.51.100.10
	proto esp spi 0xc1f3a20b reqid 1 mode tunnel
	replay-window 1024 flag af-unspec esn
	aead rfc4106(gcm(aes)) 0x91af...3d77 128
	if_id 0x2a

# Byte/packet counters and lifetimes — this is how you prove traffic flows
$ sudo ip -s xfrm state | grep -A4 'spi 0x9a44b1c7'
	proto esp spi 0x9a44b1c7 reqid 1 mode tunnel
	lifetime current:
	  244190(bytes), 1544(packets)
	  add 2026-08-25 13:41:02 use 2026-08-25 14:09:55

$ sudo ip xfrm policy
src 0.0.0.0/0 dst 0.0.0.0/0
	dir out priority 383615
	tmpl src 198.51.100.10 dst 203.0.113.24
		proto esp spi 0x00000000 reqid 1 mode tunnel
	if_id 0x2a

# Aggregate error counters — the single most useful IPsec diagnostic
$ cat /proc/net/xfrm_stat
XfrmInError                     0
XfrmInBufferError               0
XfrmInHdrError                  0
XfrmInNoStates                  17
XfrmInStateProtoError           0
XfrmInStateModeError            0
XfrmInStateSeqError             0
XfrmInStateExpired              0
XfrmInStateMismatch             0
XfrmInStateInvalid              0
XfrmInTmplMismatch              0
XfrmInNoPols                    0
XfrmInPolBlock                  0
XfrmInPolError                  0
XfrmOutError                    0
XfrmOutBundleGenError           0
XfrmOutNoStates                 43
XfrmOutStateProtoError          0
XfrmOutStateModeError           0
XfrmOutStateSeqError            0
XfrmOutStateExpired             0
XfrmOutPolBlock                 0
XfrmOutPolDead                  0
XfrmOutPolError                 0
XfrmFwdHdrError                 0
XfrmOutStateInvalid             0
XfrmAcquireError                0
```

Reading that table is the fastest IPsec skill you can acquire:

| Counter rising | Means | Fix |
|---|---|---|
| `XfrmInNoStates` | ESP arrived for an SPI we do not have | Peer rekeyed and we did not; SAs desynchronised. `swanctl --terminate --ike <name>` and re-establish |
| `XfrmOutNoStates` | A packet matched a policy but no SA exists yet | Normal at trap time; persistent means negotiation is failing — read charon.log |
| `XfrmInStateSeqError` | Anti-replay window rejected a packet | Reordering. Raise `replay_window`; check NIC multi-queue/RPS |
| `XfrmInTmplMismatch` | Packet arrived protected, but not by the SA the policy demands | Overlapping policies or mismatched selectors between peers |
| `XfrmInStateProtoError` | ICV check failed | Key mismatch or a middlebox mangling ESP — try `encap = yes` |
| `XfrmInPolBlock` | Traffic matched a `block` policy | An explicit deny policy is installed; check `ip xfrm policy` |

### 9.4 Error signature reference

| Signature | Stack | Root cause | Action |
|---|---|---|---|
| `TLS Error: TLS key negotiation failed to occur within 60 seconds` | OpenVPN | No control-channel reply reached the client | UDP/1194 blocked; wrong `proto` (`udp` vs `tcp`); wrong/missing `tls-crypt` key — a `tls-crypt` mismatch makes the server silently ignore packets, which looks identical to a firewall drop |
| `VERIFY ERROR: depth=0, error=certificate has expired` | OpenVPN | Client cert expired | Re-issue; check gateway clock too |
| `VERIFY ERROR: ... error=CRL has expired` | OpenVPN | Stale `crl.pem` | `easyrsa gen-crl`; **all** clients are being rejected, not just revoked ones |
| `Cannot load inline certificate file` | OpenVPN | Malformed inline block | Check for CRLF line endings and stray whitespace in the `.ovpn` |
| `MULTI: bad source address from client 10.30.0.9, packet dropped` | OpenVPN | Client sent traffic from a prefix it does not own | Missing `iroute` in `ccd/<CN>`, or the `route` in the server config is absent |
| `Options error: Unrecognized option ... cipher` | OpenVPN 2.6 | `--cipher` removed from the default negotiation | Use `data-ciphers`; add `data-ciphers-fallback` only for legacy 2.3 clients |
| `Authentication failed` right after `PUSH_REPLY` | OpenVPN | `auth`/`data-ciphers` mismatch after a successful TLS handshake | Align crypto on both sides |
| `received NO_PROPOSAL_CHOSEN notify` | strongSwan | IKE or ESP proposals do not intersect | Compare `proposals`/`esp_proposals` on both peers; remove the `!` from `ipsec.conf` temporarily to allow defaults and see what is chosen |
| `received TS_UNACCEPTABLE notify` | strongSwan | Traffic selectors differ | `local_ts` on one side must equal `remote_ts` on the other, exactly. A /16 vs two /24s is a mismatch on many vendors |
| `received AUTHENTICATION_FAILED notify` | strongSwan | Wrong PSK, wrong ID, untrusted CA, or clock skew | Check `id` matches a SAN/DN in the presented certificate; run `swanctl --list-certs` on both ends; `timedatectl` |
| `no matching peer config found` | strongSwan | Responder cannot map the initiator's ID to a connection | `remote { id = ... }` too narrow, or `%any` missing |
| `constraint check failed: identity 'X' required` | strongSwan | ID constraint mismatch | Certificate SAN does not contain the configured `id` |
| `retransmit 5 of request with message ID 0` | strongSwan | No response to `IKE_SA_INIT` | UDP/500 blocked, peer down, or wrong `remote_addrs` |
| `IKE_SA_INIT ok, IKE_AUTH times out` | strongSwan | IKE_AUTH is fragmented (cert chain > MTU) and fragments are dropped | Enable `fragmentation = yes`; use ECDSA certs to shrink the chain |
| `Handshake did not complete after 5 seconds, retrying` | WireGuard (kernel log) | No handshake response | Wrong `PublicKey`, wrong `Endpoint`, UDP blocked, PSK mismatch |
| `Invalid MAC of handshake, dropping packet` | WireGuard | Wrong key material | The peer's `PublicKey` on this side does not match its actual private key, or one side has a PSK the other lacks |
| `Packet has unallowed src IP from peer` | WireGuard | Inner source not in `AllowedIPs` | Add the prefix, or find the peer that is stealing it |
| `Name or service not known` on `wg-quick up` | WireGuard | `Endpoint` DNS fails at boot | Add `After=network-online.target`, or use an IP literal |
| `RTNETLINK answers: Operation not supported` | WireGuard | Kernel module missing | `modprobe wireguard`; fall back to `wireguard-go` on old kernels |
| Ping works, SSH hangs after banner | **all** | MTU black hole | §9.5 |

### 9.5 MTU diagnosis — the deterministic procedure

```bash
# 1. Confirm the symptom shape: small OK, large lost.
$ ping -c2 -M do -s 1200 10.30.0.9
PING 10.30.0.9 (10.30.0.9) 1200(1228) bytes of data.
1208 bytes from 10.30.0.9: icmp_seq=1 ttl=63 time=18.4 ms
1208 bytes from 10.30.0.9: icmp_seq=2 ttl=63 time=18.1 ms
--- 10.30.0.9 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1002ms

$ ping -c2 -M do -s 1450 10.30.0.9
PING 10.30.0.9 (10.30.0.9) 1450(1478) bytes of data.
--- 10.30.0.9 ping statistics ---
2 packets transmitted, 0 received, 100% packet loss, time 1023ms
   ← silence, not "Frag needed" ⇒ ICMP is being filtered ⇒ PMTUD is dead

# 2. Bisect for the real usable size (add 28 for IPv4+ICMP headers).
$ for s in 1400 1372 1360 1340; do
      printf '%5d: ' "$s"
      ping -c1 -W1 -M do -s "$s" 10.30.0.9 >/dev/null 2>&1 && echo OK || echo FAIL
  done
 1400: FAIL
 1372: FAIL
 1360: OK
 1340: OK
   ⇒ usable payload 1360 ⇒ interface MTU 1388

# 3. Apply on BOTH gateways, and clamp MSS regardless.
$ sudo ip link set mtu 1388 dev ipsec0
$ sudo nft add rule inet vpn forward tcp flags syn tcp option maxseg size set rt mtu

# 4. Confirm what the kernel learned per destination.
$ ip route get 10.30.0.9
10.30.0.9 dev ipsec0 src 10.20.0.5 uid 1000
    cache expires 588sec mtu 1388

# 5. OpenVPN has a built-in probe (run from the client):
$ sudo openvpn --config alice.ovpn --mtu-test
NOTE: Beginning empirical MTU test -- results should be available in 3 to 4 minutes.
NOTE: Empirical MTU test completed [Tried,Actual] local->remote=[1573,1420] remote->local=[1573,1420]
```

### 9.6 Throughput measurement — measure, do not quote

```bash
# Baseline WITHOUT the tunnel, then inside it. The delta is the real cost.
$ iperf3 -c 203.0.113.24 -t 20 -P 4 --get-server-output | tail -5
[SUM]   0.00-20.00  sec  2.18 GBytes   936 Mbits/sec                  sender
[SUM]   0.00-20.00  sec  2.17 GBytes   933 Mbits/sec                  receiver

$ iperf3 -c 10.30.0.9 -t 20 -P 4 | tail -5
[SUM]   0.00-20.00  sec  1.94 GBytes   833 Mbits/sec                  sender
[SUM]   0.00-20.00  sec  1.93 GBytes   830 Mbits/sec                  receiver

# Where the CPU goes
$ sudo perf top -e cycles --sort comm,dso
  38.11%  [kernel]        [k] aesni_xts_encrypt
  11.02%  [kernel]        [k] chacha20_neon
   6.74%  ksoftirqd/2     [k] __netif_receive_skb_core
   4.21%  openvpn         [.] openvpn_encrypt

# Is AES-NI actually available? Without it, prefer ChaCha20-Poly1305.
$ grep -o -m1 -E 'aes|avx2|vaes' /proc/cpuinfo | sort -u
aes
avx2

# Offload state — GRO/GSO on the tunnel interface changes throughput by 2-3x
$ ethtool -k wg0 | grep -E 'generic-(receive|segmentation)-offload'
generic-receive-offload: on
generic-segmentation-offload: on
```

Rules of thumb that survive measurement: with AES-NI present, prefer AES-GCM; without it (older ARM, some embedded gateways), ChaCha20-Poly1305 is dramatically faster. A userspace OpenVPN instance is single-threaded per client on the data path — scale it with multiple server instances on different ports plus a load balancer, or enable DCO.

### 9.7 Live debugging

```bash
# strongSwan: raise verbosity at runtime, no restart, no dropped SAs
$ sudo swanctl --log &            # stream the daemon log to this terminal
$ sudo swanctl --list-conns
branch: IKEv2, no reauthentication, rekeying every 14400s
  local:  198.51.100.10
  remote: 203.0.113.24
  local public key authentication:
    id: C=AR, O=Example Inc, CN=gw-core.example.net
    certs: C=AR, O=Example Inc, CN=gw-core.example.net
  remote public key authentication:
    id: C=AR, O=Example Inc, CN=gw-branch.example.net
  net: TUNNEL, rekeying every 3600s
    local:  0.0.0.0/0
    remote: 0.0.0.0/0

$ sudo swanctl --list-certs --subject gw-branch.example.net
List of X.509 End Entity Certificates
  subject:  "C=AR, O=Example Inc, CN=gw-branch.example.net"
  issuer:   "C=AR, O=Example Inc, CN=Example IPsec CA"
  validity:  not before Aug 25 13:44:19 2026, ok
             not after  Sep 27 13:44:19 2027, ok (expires in 397 days)

$ sudo swanctl --stats
uptime: 51 minutes, since Aug 25 13:22:11 2026
worker threads: 11 total, 5 idle, working: 6/0/0/0
job queues: 0/0/0/0
IKE_SAs: 1 total, 0 half-open

$ sudo swanctl --terminate --ike branch      # controlled teardown
$ sudo swanctl --load-all                    # reload config, keep live SAs

# OpenVPN: current sessions from the status file
$ sudo cat /run/openvpn-server/status-core.log
TITLE,OpenVPN 2.6.12 x86_64-pc-linux-gnu [SSL (OpenSSL)] [LZO] [LZ4] [EPOLL] [DCO]
TIME,2026-08-25 14:11:03,1787069463
HEADER,CLIENT_LIST,Common Name,Real Address,Virtual Address,Virtual IPv6 Address,Bytes Received,Bytes Sent,Connected Since,Connected Since (time_t),Username,Client ID,Peer ID,Data Channel Cipher
CLIENT_LIST,alice@example.net,190.17.44.201:57312,10.20.200.50,,1841204,9930118,2026-08-25 13:11:03,1787065863,UNDEF,0,3,AES-256-GCM
CLIENT_LIST,gw-branch.example.net,203.0.113.24:1194,10.20.200.10,,88214553,71203881,2026-08-25 09:02:11,1787051131,UNDEF,1,4,AES-256-GCM
HEADER,ROUTING_TABLE,Virtual Address,Common Name,Real Address,Last Ref,Last Ref (time_t)
ROUTING_TABLE,10.20.200.50,alice@example.net,190.17.44.201:57312,2026-08-25 14:11:01,1787069461
ROUTING_TABLE,10.30.0.0/16,gw-branch.example.net,203.0.113.24:1194,2026-08-25 14:11:02,1787069462
GLOBAL_STATS,Max bcast/mcast queue length,3
END

# OpenVPN: management interface for live control
$ sudo socat - UNIX-CONNECT:/run/openvpn-server/mgmt-core.sock
>INFO:OpenVPN Management Interface Version 5 -- type 'help' for more info
status 3
state
log 20
kill alice@example.net
quit

# WireGuard: the kernel module is the only thing that logs
$ echo module wireguard +p | sudo tee /sys/kernel/debug/dynamic_debug/control
$ sudo dmesg -w | grep -i wireguard
[ 4021.118220] wireguard: wg0: Sending handshake initiation to peer 2 (203.0.113.24:51820)
[ 4021.181330] wireguard: wg0: Receiving handshake response from peer 2 (203.0.113.24:51820)
[ 4021.181402] wireguard: wg0: Keypair 7 created for peer 2
[ 4083.402118] wireguard: wg0: Receiving handshake initiation from peer 4 (190.17.44.201:57312)
[ 4083.402551] wireguard: wg0: Sending handshake response to peer 4 (190.17.44.201:57312)
```

### 9.8 Post-change verification checklist

Run this after every VPN change, before you close the ticket:

```bash
$ set -e
# 1. Control plane is up
$ sudo swanctl --list-sas | grep -c ESTABLISHED
$ sudo wg show all dump | awk 'NF>5 && (systime()-$6)<180' | wc -l
$ sudo grep -c "Initialization Sequence Completed" /var/log/openvpn/core.log

# 2. Data plane counters are MOVING (take two samples, 10 s apart)
$ sudo ip -s xfrm state | awk '/lifetime current/{getline; print $1}'

# 3. Routing is symmetric — check from BOTH sides
$ ip route get 10.30.0.9
$ ssh gw-branch ip route get 10.20.0.5

# 4. End-to-end reachability at full MTU
$ ping -c3 -M do -s 1360 10.30.0.9

# 5. The firewall is not silently eating anything
$ sudo nft list ruleset | grep -A1 'comment "forward-drop"'

# 6. It survives a reboot
$ systemctl is-enabled strongswan wg-quick@wg0 openvpn-server@core
```

---

## 10. Exam alignment: files, commands and ports at a glance

| File / path | Stack | Purpose |
|---|---|---|
| `/etc/openvpn/server/*.conf` | OpenVPN | Server instances; started by `openvpn-server@<name>.service` |
| `/etc/openvpn/client/*.conf` | OpenVPN | Client instances; `openvpn-client@<name>.service` |
| `/etc/openvpn/server/ccd/<CN>` | OpenVPN | Per-client overrides: `iroute`, `ifconfig-push`, `push` |
| `/etc/ipsec.conf` | strongSwan (legacy) | `conn` sections; `auto=add|route|start` |
| `/etc/ipsec.secrets` | strongSwan (legacy) | PSK, RSA/ECDSA key references, EAP/XAUTH credentials |
| `/etc/ipsec.d/{cacerts,certs,private}/` | strongSwan (legacy) | Credential store |
| `/etc/swanctl/swanctl.conf`, `conf.d/*.conf` | strongSwan (modern) | `connections`, `secrets`, `pools`, `authorities` |
| `/etc/swanctl/{x509ca,x509,private}/` | strongSwan (modern) | Credential store |
| `/etc/strongswan.conf`, `/etc/strongswan.d/` | strongSwan | Daemon tuning, plugins, logging |
| `/etc/wireguard/<iface>.conf` | WireGuard | `[Interface]` + `[Peer]` sections, consumed by `wg-quick` |
| `/etc/xl2tpd/xl2tpd.conf`, `/etc/ppp/options.xl2tpd` | L2TP | LNS and PPP options |

| Command | What it does |
|---|---|
| `openvpn --config f.conf` | Run in the foreground |
| `openvpn --genkey secret ta.key` | Generate a `tls-auth`/`tls-crypt` key (2.6 syntax) |
| `openvpn --show-ciphers` / `--show-digests` / `--show-tls` | Enumerate available algorithms |
| `openvpn --mtu-test` | Empirical MTU probe |
| `ipsec start|restart|status|statusall|up <conn>|down <conn>` | Legacy control |
| `ipsec listcerts|listcacerts|rereadsecrets` | Legacy credential inspection |
| `swanctl --load-all` | Reload config without dropping live SAs |
| `swanctl --list-sas|--list-conns|--list-certs|--list-pools|--stats|--log` | Inspect |
| `swanctl --initiate --child <n>` / `--terminate --ike <n>` | Bring a tunnel up/down |
| `pki --gen|--self|--issue|--print` | strongSwan's PKI tool |
| `wg genkey|pubkey|genpsk` | Key material |
| `wg show [iface] [dump\|latest-handshakes\|transfer]` | Inspect |
| `wg set <iface> peer <pub> allowed-ips ... [remove]` | Live peer changes |
| `wg setconf` / `wg syncconf` / `wg-quick strip` | Load whole config / diff-apply / render |
| `wg-quick up|down|save|strip <iface>` | Interface lifecycle including routes and firewall |
| `ip xfrm state|policy` , `ip -s xfrm state` | Kernel SAD/SPD |
| `ip l2tp add tunnel|session` , `ip l2tp show` | L2TPv3 pseudowires |

| Port / protocol | Used by |
|---|---|
| UDP 1194 (default, configurable) | OpenVPN |
| TCP 443 (common alternative) | OpenVPN over TCP through restrictive networks |
| UDP 500 | IKEv1/IKEv2 |
| UDP 4500 | IKEv2 NAT-T (UDP-encapsulated ESP) |
| IP protocol 50 | ESP |
| IP protocol 51 | AH (legacy, NAT-incompatible) |
| UDP 51820 (convention, no default) | WireGuard |
| UDP 1701 | L2TP |
| IP protocol 115 | L2TPv3 over IP |

---

## Referencias

**Objetivos del examen**
- LPI Exam 303-300 Objectives (Topic 334: Network Security, incl. 334.4 Virtual Private Networks) — https://www.lpi.org/our-certifications/exam-303-objectives/
- LPIC-3 Security certification overview — https://www.lpi.org/our-certifications/lpic-3-303-overview/

**OpenVPN**
- OpenVPN 2.6 reference manual (all options: `--data-ciphers`, `--tls-crypt-v2`, `--topology`, `--server-bridge`, `--client-config-dir`) — https://openvpn.net/community-resources/reference-manual-for-openvpn-2-6/
- OpenVPN community wiki (HOWTO, bridging vs routing, DCO) — https://community.openvpn.net/openvpn/wiki
- OpenVPN change log (2.6 cipher deprecations and DCO) — https://github.com/OpenVPN/openvpn/blob/master/Changes.rst
- OpenVPN Data Channel Offload — https://community.openvpn.net/openvpn/wiki/DataChannelOffload
- Easy-RSA documentation — https://github.com/OpenVPN/easy-rsa/blob/master/doc/EasyRSA-Advanced.md

**strongSwan / IPsec**
- strongSwan documentation index — https://docs.strongswan.org/docs/latest/index.html
- `swanctl.conf` reference — https://docs.strongswan.org/docs/latest/swanctl/swanctlConf.html
- IKEv2 cipher suites and proposal syntax — https://docs.strongswan.org/docs/latest/config/proposals.html
- Route-based VPNs with XFRM interfaces — https://docs.strongswan.org/docs/latest/features/routeBasedVpn.html
- `ipsec.conf` (legacy `starter`) reference — https://docs.strongswan.org/docs/latest/config/IKEv2.html
- `pki` command reference — https://docs.strongswan.org/docs/latest/utils/pki.html
- VICI protocol and bindings — https://docs.strongswan.org/docs/latest/plugins/vici.html

**WireGuard**
- WireGuard project site — https://www.wireguard.com/
- WireGuard: Next Generation Kernel Network Tunnel (NDSS 2017 whitepaper — protocol, Noise_IKpsk2, timers) — https://www.wireguard.com/papers/wireguard.pdf
- Cryptokey routing and `AllowedIPs` — https://www.wireguard.com/#cryptokey-routing
- Known limitations — https://www.wireguard.com/known-limitations/
- `wg(8)` manual — https://git.zx2c4.com/wireguard-tools/about/src/man/wg.8
- `wg-quick(8)` manual — https://git.zx2c4.com/wireguard-tools/about/src/man/wg-quick.8

**RFCs**
- RFC 7296 — Internet Key Exchange Protocol Version 2 (IKEv2) — https://www.rfc-editor.org/rfc/rfc7296
- RFC 4303 — IP Encapsulating Security Payload (ESP) — https://www.rfc-editor.org/rfc/rfc4303
- RFC 4301 — Security Architecture for the Internet Protocol — https://www.rfc-editor.org/rfc/rfc4301
- RFC 3948 — UDP Encapsulation of IPsec ESP Packets (NAT-T) — https://www.rfc-editor.org/rfc/rfc3948
- RFC 4555 — IKEv2 Mobility and Multihoming Protocol (MOBIKE) — https://www.rfc-editor.org/rfc/rfc4555
- RFC 7383 — IKEv2 Message Fragmentation — https://www.rfc-editor.org/rfc/rfc7383
- RFC 2661 — Layer Two Tunneling Protocol "L2TP" — https://www.rfc-editor.org/rfc/rfc2661
- RFC 3931 — Layer Two Tunneling Protocol - Version 3 (L2TPv3) — https://www.rfc-editor.org/rfc/rfc3931
- RFC 3193 — Securing L2TP using IPsec — https://www.rfc-editor.org/rfc/rfc3193

**Linux kernel and tooling**
- Kernel XFRM device documentation — https://www.kernel.org/doc/html/latest/networking/xfrm_device.html
- `ip-xfrm(8)` — https://man7.org/linux/man-pages/man8/ip-xfrm.8.html
- `ip-l2tp(8)` — https://man7.org/linux/man-pages/man8/ip-l2tp.8.html
- `systemd.netdev(5)` (WireGuard and XFRM kinds) — https://www.freedesktop.org/software/systemd/man/latest/systemd.netdev.html
- Netplan YAML configuration reference (`mode: wireguard`) — https://netplan.readthedocs.io/en/stable/netplan-yaml/
- nftables wiki — https://wiki.nftables.org/wiki-nftables/index.php/Main_Page