# 331.4 — DNS and Cryptography

**Exam:** LPIC-3 303-300 (Security), version 3.0.0 · **Topic weight:** 5/60 → **8.33 %** of the exam
**Scope:** DNSSEC (authoritative signing + recursive validation), key management and rollover, TSIG, DANE, and encrypted DNS transports (DoT/DoH/DoQ/DNSCrypt).

---

## 1. The architectural problem: DNS is the unauthenticated root of everything

Every trust decision in a modern platform is bootstrapped by a name lookup that, in its original 1987 form, has **no authentication, no integrity protection, and no confidentiality**.

Consider the dependency chain of a routine production action — issuing a TLS certificate with ACME:

```
cert-manager  →  ACME DNS-01 challenge  →  _acme-challenge.svc.example.net TXT
                                              ↑
                        whoever can answer this record can mint a
                        publicly-trusted certificate for the name
```

And the chain for mail delivery:

```
sender MTA  →  MX example.net  →  mx1.example.net A  →  TCP/25  →  opportunistic STARTTLS
                    ↑                                                    ↑
        forge this and mail is rerouted              downgrade this and TLS never happens
```

And for service discovery inside a cluster:

```
kubelet /etc/resolv.conf  →  CoreDNS  →  upstream recursor  →  authoritative
                                              ↑
                        one poisoned cache entry redirects every
                        egress connection from every pod on the node
```

The threat model has three distinct layers, and **they are solved by three different mechanisms that are frequently confused**:

| Threat | What the attacker does | Mitigation | What it does *not* solve |
|---|---|---|---|
| **Off-path forgery / cache poisoning** | Races the real answer with a spoofed UDP packet (Kaminsky, 2008); guesses the 16-bit TXID + source port | **DNSSEC** (origin authentication + integrity of RRsets) | Does not hide the query; does not authenticate the *server* |
| **On-path tampering / downgrade** | ISP, hotel captive portal, hostile middlebox rewrites NXDOMAIN → ad server, strips the `DO` bit | **DNSSEC** end-to-end (stub validation) + **DoT/DoH/DoQ** for the last mile | Encrypted transport alone still trusts whatever the resolver says |
| **Surveillance / profiling** | Passive observation of port 53 plaintext; the query stream is a complete browsing history | **DoT / DoH / DoQ / DNSCrypt / ODoH** | Does not prove the answer is genuine — an encrypted lie is still a lie |

> **The single most important conceptual point in this objective:** DNSSEC and encrypted transport are **orthogonal**. DNSSEC gives you *authenticity* with no confidentiality; DoT/DoH give you *confidentiality* (hop-by-hop) with no authenticity of the data itself. A production design needs both, and neither substitutes for the other.

### 1.1 Why DNSSEC is an SRE problem, not just a security problem

DNSSEC converts a stateless, cache-friendly protocol into a system with **time-bounded cryptographic material**. Signatures expire. Keys roll. A parent zone holds a copy of your key digest that you cannot update atomically. This creates entirely new outage classes:

* **Expired RRSIGs** — the single most common self-inflicted DNSSEC outage. The zone is fine, the servers are up, the signatures are three hours past `Signature Expiration`, and every validating resolver on Earth returns `SERVFAIL`. The zone is not "slow" — it is **gone**, and it stays gone until you re-sign, because the failure is fail-closed by design.
* **DS/DNSKEY mismatch** — you rolled the KSK and the registrar's DS still points at the retired key. Same result: global `SERVFAIL`.
* **Blast radius is total and asymmetric.** An unsigned zone with a bad record breaks one name. A broken signature breaks *the entire zone and everything below it*, for every validating resolver, and it is invisible to your own non-validating monitoring.
* **Recovery is TTL-bound.** You cannot "roll back" a DS record faster than the parent's TTL (`.com` DS TTL is 86400 s). Design every rollover so that the failure mode is "old key still works", never "new key not yet trusted".

This is why the operational sections of this topic (key timing, rollover state machines, monitoring) matter as much as the cryptography.

---

## 2. DNS fundamentals that DNSSEC depends on

DNSSEC does not sign *messages*. It signs **RRsets**.

An **RRset** is the complete set of records with the same `(owner name, class, type)` tuple. This is the atomic unit of DNSSEC:

```
www.example.net.  3600  IN  A  203.0.113.10
www.example.net.  3600  IN  A  203.0.113.11
```

Those two records form **one** RRset and are covered by **one** `RRSIG`. Consequences that bite in production:

* You cannot sign an individual record. Adding one `A` record invalidates the whole RRset's signature.
* All records in an RRset **must** share the same TTL. A mismatch is a zone-load error under DNSSEC.
* The `RRSIG` carries the **Original TTL** so that a validator can reconstruct the canonical form even after a cache has decremented the TTL in transit.
* Canonical ordering (RFC 4034 §6) — names lowercased, sorted in canonical name order, RDATA sorted — must be reproduced byte-for-byte by the validator, otherwise the hash differs and validation fails.

### 2.1 The DNSSEC resource record types

| Type | Code | Lives in | Purpose |
|---|---|---|---|
| `DNSKEY` | 48 | zone apex | Public keys used to verify `RRSIG`s in this zone |
| `RRSIG` | 46 | alongside every signed RRset | The signature over one RRset |
| `DS` | 43 | **parent** zone, at the delegation point | Digest of the child's KSK — the link in the chain of trust |
| `NSEC` | 47 | signed zone | Authenticated denial of existence (next name in canonical order) |
| `NSEC3` | 50 | signed zone | Hashed authenticated denial of existence |
| `NSEC3PARAM` | 51 | zone apex | Hash algorithm, flags, iterations, salt for `NSEC3` |
| `CDS` | 59 | **child** apex | "Please publish this DS in the parent" (RFC 7344) |
| `CDNSKEY` | 60 | **child** apex | "Please derive a DS from this DNSKEY" (RFC 7344) |
| `TLSA` | 52 | `_port._proto.name` | DANE certificate association (RFC 6698) |
| `SSHFP` | 44 | host name | SSH host key fingerprint (RFC 4255) |
| `OPENPGPKEY` | 61 | hashed local-part | PGP key publication (RFC 7929) |
| `ZONEMD` | 63 | zone apex | Message digest over the whole zone (RFC 8976) |

### 2.2 The three EDNS0 / header bits that drive everything

| Bit | Set by | Meaning | Diagnostic use |
|---|---|---|---|
| `DO` (DNSSEC OK) | client, in the EDNS0 OPT RR | "Send me `RRSIG`/`NSEC` records" | `dig +dnssec` sets it. If absent, no crypto is returned at all |
| `CD` (Checking Disabled) | client, in the header | "Do not validate; give me the data even if bogus" | `dig +cd` — **the primary triage tool**: if `+cd` works and plain fails, it is a validation failure, not a data failure |
| `AD` (Authentic Data) | **resolver**, in the response | "I validated this and it is secure" | `dig` shows it in `;; flags:`. Never trust `AD` from an untrusted resolver over an unauthenticated channel |

The four validation states (RFC 4035 §4.3):

| State | Meaning | Resolver behaviour |
|---|---|---|
| **Secure** | Full chain from trust anchor to RRset validates | Answer returned with `AD` set |
| **Insecure** | A provably unsigned delegation exists (no `DS`, proven by `NSEC`/`NSEC3`) | Answer returned, `AD` clear |
| **Bogus** | Signatures exist but do not validate (expired, wrong key, tampered) | **`SERVFAIL`** |
| **Indeterminate** | No trust anchor reachable for this branch | Treated as insecure |

---

## 3. DNSSEC in depth

### 3.1 The chain of trust

```
                       root zone "."
                       ┌──────────────────────────────┐
   trust anchor ──────▶│ DNSKEY (KSK-2017, tag 20326) │
   configured out      │ DNSKEY (ZSK)                 │
   of band             │ RRSIG(DNSKEY) by KSK         │
                       │ DS  net.  ◀── digest of net's KSK
                       │ RRSIG(DS) by ZSK             │
                       └──────────────┬───────────────┘
                                      │ delegation
                       ┌──────────────▼───────────────┐
                       │ net. DNSKEY (KSK) (ZSK)      │
                       │ DS  example.net. ◀── digest of example.net's KSK
                       │ RRSIG(DS) by net's ZSK       │
                       └──────────────┬───────────────┘
                                      │ delegation
                       ┌──────────────▼───────────────┐
                       │ example.net. DNSKEY (KSK)(ZSK)│
                       │ www A 203.0.113.10           │
                       │ RRSIG(A) by example.net ZSK  │
                       └──────────────────────────────┘
```

The validator walks **down** from the anchor: verify `DNSKEY` RRset with the anchor → use the ZSK to verify the `DS` RRset of the child → hash the child's KSK and compare to the `DS` → verify the child's `DNSKEY` RRset with its KSK → verify the answer's `RRSIG` with the child's ZSK.

**Note the two independent verifications at each hop:** the `DS` in the parent is signed by the *parent*, and the `DNSKEY` in the child is signed by the *child*. Break either and the chain is bogus.

### 3.2 KSK vs ZSK vs CSK

The split into Key Signing Key and Zone Signing Key is **purely operational**, not cryptographic. Nothing in the protocol requires it — the SEP (Secure Entry Point) flag is advisory.

| | **KSK** (Key Signing Key) | **ZSK** (Zone Signing Key) | **CSK** (Combined Signing Key) |
|---|---|---|---|
| DNSKEY flags | 257 (SEP bit set) | 256 | 257 |
| Signs | Only the apex `DNSKEY` RRset | All other RRsets in the zone | Everything |
| Referenced by parent `DS` | **Yes** | No | Yes |
| Rollover requires parent interaction | **Yes** — slow, out-of-band, registrar/EPP or CDS | **No** — entirely within the zone | Yes |
| Typical lifetime | 1–2 years (or unlimited with CDS automation) | 30–90 days | 1 year |
| Typical size | RSA-2048/4096, or ECDSA P-256 | RSA-1024/2048, or ECDSA P-256 | ECDSA P-256 |
| Can live offline / in an HSM | **Yes** — this is the whole point | No, needs to be online to sign changes | No |
| `dnssec-keygen` flag | `-f KSK` | (none) | `-f KSK` with a single-key policy |

**Trade-off analysis:**

* **Split KSK/ZSK** is worth it when the KSK is genuinely protected differently — offline media, HSM, an air-gapped signer. If both keys sit in the same `/var/lib/bind/keys` directory with `0600` permissions, the split buys you nothing but complexity and one extra `DNSKEY` in every response.
* **CSK** is the right default for small and medium zones with **automated CDS/CDNSKEY** rollover (RFC 8078). One key, one state machine, smaller responses.
* With **ECDSA P-256**, RSA's original motivation for the split largely evaporates: a P-256 key is 64 bytes and a signature is 64 bytes, so the "keep the ZSK small to keep responses small" argument is moot.

### 3.3 Algorithm selection

| Alg # | Name | Key size | Sig size | Status (RFC 8624 and successors) | Verdict for new zones |
|---:|---|---:|---:|---|---|
| 1 | RSAMD5 | — | — | **MUST NOT** | Forbidden |
| 3 | DSA | — | — | MUST NOT | Forbidden |
| 5 | RSASHA1 | 1024–4096 | 128–512 B | MUST NOT sign | Migrate away immediately |
| 7 | RSASHA1-NSEC3-SHA1 | 1024–4096 | 128–512 B | MUST NOT sign | Migrate away immediately |
| 8 | RSASHA256 | 2048–4096 | 256–512 B | MUST implement, MAY sign | Acceptable; root zone uses it |
| 10 | RSASHA512 | 2048–4096 | 256–512 B | NOT RECOMMENDED | Avoid — no benefit over 8 |
| 12 | ECC-GOST | — | — | MUST NOT | Forbidden |
| 13 | **ECDSAP256SHA256** | 32 B | 64 B | **MUST implement / RECOMMENDED** | **Default choice** |
| 14 | ECDSAP384SHA384 | 48 B | 96 B | MAY | Only if a policy demands 192-bit security |
| 15 | **ED25519** | 32 B | 64 B | RECOMMENDED | Excellent, but validator support is not yet universal |
| 16 | ED448 | 57 B | 114 B | MAY | Rare validator support |

**Why algorithm 13 is the production default:** a `DNSKEY` RRset with two P-256 keys plus its `RRSIG` fits comfortably inside a 1232-byte UDP payload, eliminating TCP fallback and IP-fragmentation failures. The same zone with RSA-2048 KSK + ZSK produces a `DNSKEY` response around 1 kB and a KSK rollover pushes it past 1500 bytes — precisely the condition that DNS Flag Day 2020 was created to address.

**Ed25519 caveat:** if you sign with algorithm 15 only, resolvers that do not implement it treat the zone as **insecure** (not bogus) — you silently lose protection rather than break. That is safe but pointless. Do not "dual-sign" with 13 + 15 unless you have measured a real need; multi-algorithm zones must maintain a complete signature set per algorithm and roughly double the response size.

### 3.4 The Key Tag

The **Key Tag** is a 16-bit hint that lets a validator pick the right `DNSKEY` out of the RRset without trial-verifying all of them. It appears in `RRSIG` (field 7), in `DS` (field 1), and in the `dnssec-keygen` filename.

Critical properties:

* It is **not** a cryptographic identifier. It is a checksum over the `DNSKEY` RDATA.
* It is **not unique**. Collisions are possible and legal; a validator that finds two keys with the same tag must try both.
* It changes when the key changes — which is exactly what makes it a useful operational handle.

RFC 4034 Appendix B, for every algorithm except 1:

```python
def keytag(rdata: bytes) -> int:
    """rdata = wire-format DNSKEY RDATA: flags(2) | protocol(1) | algorithm(1) | pubkey"""
    ac = 0
    for i, b in enumerate(rdata):
        ac += b if (i & 1) else (b << 8)
    ac += (ac >> 16) & 0xFFFF
    return ac & 0xFFFF
```

The filename convention encodes it directly:

```
Kexample.net.+013+34505.key
 │           │   │
 │           │   └── key tag (34505)
 │           └────── algorithm (13 = ECDSAP256SHA256)
 └────────────────── zone name
```

### 3.5 Authenticated denial of existence

Signing an NXDOMAIN response on the fly would require the private key to be online for every query and would enable a trivial signature-oracle DoS. DNSSEC instead pre-computes **proofs of non-existence**.

**NSEC** — a linked list over the canonically sorted names in the zone:

```
example.net.        3600 IN NSEC mail.example.net. A NS SOA MX RRSIG NSEC DNSKEY
mail.example.net.   3600 IN NSEC www.example.net.  A AAAA RRSIG NSEC
www.example.net.    3600 IN NSEC example.net.      A RRSIG NSEC
```

A query for `nope.example.net` returns the `NSEC` for `mail.` proving that nothing exists between `mail.` and `www.` — which also **discloses that `mail` and `www` exist**. Walking the chain enumerates the entire zone.

**NSEC3** — the same idea over **SHA-1 hashes** of the names, with a salt and an iteration count, to make enumeration cost money instead of being free.

| | **NSEC** | **NSEC3** | **NSEC3 + opt-out** |
|---|---|---|---|
| Zone enumeration | Trivial (`ldns-walk`) | Requires offline dictionary/brute-force against SHA-1 | Same as NSEC3 |
| Signing cost | Lowest | Higher (hash every name) | Lower than plain NSEC3 |
| Zone size | 1 NSEC per name | 1 NSEC3 per name + `NSEC3PARAM` | 1 NSEC3 only per *secure* delegation |
| Response size | Smallest | Larger (2–3 NSEC3 records per NXDOMAIN) | Larger |
| CPU cost on the validator | None | `iterations + 1` SHA-1 operations per hash | Same |
| Insecure delegations | Each is individually proven | Each is individually proven | **Not proven** — unsigned children are unauthenticated |
| Correct use case | Public zones with nothing to hide; **the default** | Zones where names are sensitive; zones needing opt-out | **TLDs and huge registries only** |

**RFC 9276 is not optional guidance — treat it as a hard rule:**

```
nsec3param iterations 0 optout no salt-length 0;
```

* **Iterations MUST be 0.** Extra iterations provide negligible protection (an attacker with a wordlist wins either way) and hand any client a CPU-amplification vector against your validators. BIND ≥ 9.16.9 refuses to *serve* zones with high iteration counts and treats > 150 as insecure; BIND 9.20 rejects > 0 in `dnssec-policy`.
* **Salt MUST be empty.** The salt only defends against a *precomputed* rainbow table for the whole DNS namespace — which nobody builds, because the owner name is already in the hash input.
* **Opt-out only for registry-scale zones.** In an enterprise zone, opt-out means an attacker can insert a fake unsigned delegation and you cannot prove it did not exist.

If zone-privacy is the actual requirement, NSEC3 is the wrong tool — it delays enumeration by hours, not forever. Use a separate internal view or split-horizon DNS.

---

## 4. BIND 9 as an authoritative signer

There are three signing models. Know all three: the exam objective names the manual tools, production uses the automated one.

| Model | Tooling | Private key online? | Zone-change latency | Rollover | Use when |
|---|---|---|---|---|---|
| **Offline / manual** | `dnssec-keygen`, `dnssec-signzone`, `dnssec-settime`, cron | No — signer can be air-gapped | Minutes to hours (re-sign the whole zone) | Manual state machine | Regulatory requirement for offline KSK; very high-value zones |
| **Inline signing with `dnssec-policy`** | `named` + `rndc dnssec` | Yes (or via PKCS#11) | Seconds | **Automatic**, RFC 7344 CDS | **Default for almost everything** |
| **Dynamic update + `dnssec-policy`** | `nsupdate`/RFC 2136 + `named` | Yes | Immediate | Automatic | ACME DNS-01, cert-manager, DDNS |

### 4.1 The modern path — `dnssec-policy`

Introduced in BIND 9.16 and the only sane way to run DNSSEC at scale. It replaces the whole `auto-dnssec` / `dnssec-keymgr` / cron-job era with a declarative policy and a built-in key state machine that respects TTLs and propagation delays.

**`/etc/bind/named.conf` — complete authoritative primary:**

```conf
// ---------------------------------------------------------------------------
// /etc/bind/named.conf  --  authoritative primary, DNSSEC-signed
// BIND 9.20.x
// ---------------------------------------------------------------------------

include "/etc/bind/tsig/xfr-key.conf";      // TSIG key, mode 0640 root:bind
include "/etc/bind/tsig/rndc-key.conf";

acl "secondaries" {
    192.0.2.53;                 // ns2.example.net
    198.51.100.53;              // ns3.example.net
    2001:db8:2::53;
};

acl "monitoring" {
    10.20.0.0/16;               // Prometheus / blackbox exporter
};

options {
    directory              "/var/cache/bind";
    managed-keys-directory "/var/cache/bind/keys";
    key-directory          "/var/lib/bind/keys";     // 0700 bind:bind
    pid-file               "/run/named/named.pid";
    session-keyfile        "/run/named/session.key";

    listen-on       port 53 { 192.0.2.1; 127.0.0.1; };
    listen-on-v6    port 53 { 2001:db8:1::53; ::1; };

    // Authoritative-only: never recurse, never cache for clients.
    recursion no;
    allow-query        { any; };
    allow-query-cache  { none; };
    allow-transfer     { none; };            // overridden per zone, with TSIG
    allow-update       { none; };
    allow-notify       { none; };
    notify             explicit;

    // DNS Flag Day 2020: keep UDP payloads under the common 1500-byte MTU
    // to avoid IP fragmentation, which firewalls drop and which is a
    // spoofing vector (RFC 8900).
    edns-udp-size      1232;
    max-udp-size       1232;

    // Rate-limit the reflection/amplification surface.
    rate-limit {
        responses-per-second 15;
        nxdomains-per-second 5;
        errors-per-second    5;
        slip                 2;
        window               5;
        exempt-clients       { "monitoring"; 127.0.0.1; };
    };

    minimal-responses    yes;
    version              none;
    hostname             none;
    server-id            none;

    // Signing/serving policy defaults
    dnssec-validation    no;                 // authoritative-only: nothing to validate
    max-zone-ttl         1d;                 // must match dnssec-policy max-zone-ttl
    zone-statistics      full;
};

statistics-channels {
    inet 127.0.0.1 port 8053 allow { 127.0.0.1; };
};

controls {
    inet 127.0.0.1 port 953 allow { 127.0.0.1; } keys { "rndc-key"; };
};

logging {
    channel "dnssec_log" {
        file "/var/log/named/dnssec.log" versions 10 size 20m;
        severity debug 3;
        print-time  yes;
        print-category yes;
        print-severity yes;
    };
    channel "general_log" {
        file "/var/log/named/general.log" versions 5 size 50m;
        severity info;
        print-time yes;
        print-category yes;
    };
    channel "xfer_log" {
        file "/var/log/named/xfer.log" versions 5 size 20m;
        severity info;
        print-time yes;
    };
    category dnssec        { "dnssec_log"; };
    category dnstap        { "null"; };
    category xfer-out      { "xfer_log"; };
    category xfer-in       { "xfer_log"; };
    category notify        { "xfer_log"; };
    category security      { "general_log"; };
    category default       { "general_log"; };
};

// ---------------------------------------------------------------------------
// DNSSEC policy
// ---------------------------------------------------------------------------
dnssec-policy "prod-ecdsa" {
    keys {
        ksk key-directory lifetime P2Y  algorithm ecdsap256sha256;
        zsk key-directory lifetime P90D algorithm ecdsap256sha256;
    };

    // How long a DNSKEY RRset may be cached. Drives the rollover timing math.
    dnskey-ttl                  PT1H;       // 3600 s

    // The largest TTL that may appear anywhere in the zone. named enforces it.
    max-zone-ttl                P1D;

    // Signature lifetime and how early to refresh. Refresh MUST be well below
    // validity: the difference is your entire outage budget if signing stops.
    signatures-validity         P14D;
    signatures-validity-dnskey  P14D;
    signatures-refresh          P5D;        // ~9 days of slack
    signatures-jitter           PT12H;      // avoid a thundering-herd re-sign

    // Propagation model -- how long until every secondary and every cache
    // has seen a change. Be generous; the cost of being generous is a slower
    // rollover, the cost of being optimistic is a global SERVFAIL.
    zone-propagation-delay      PT10M;
    parent-propagation-delay    PT2H;
    parent-ds-ttl               PT1H;       // must match the parent's real DS TTL
    publish-safety              PT1H;
    retire-safety               PT1H;
    purge-keys                  P90D;

    // RFC 9276: iterations 0, no salt, no opt-out.
    nsec3param                  iterations 0 optout no salt-length 0;

    // RFC 7344 / 8078: publish CDS+CDNSKEY so the parent can automate the DS.
    cds-digest-types            { "sha-256"; };
};

// ---------------------------------------------------------------------------
// Zones
// ---------------------------------------------------------------------------
zone "example.net" IN {
    type primary;
    file "/var/lib/bind/zones/db.example.net";

    dnssec-policy "prod-ecdsa";
    inline-signing yes;          // implicit from 9.19+, explicit here for clarity

    allow-transfer   { key "xfr-key"; };
    also-notify      { 192.0.2.53 key "xfr-key";
                       198.51.100.53 key "xfr-key"; };
    notify           explicit;

    // Ask these servers whether our DS has appeared in the parent, so the
    // KSK rollover state machine can advance without human intervention.
    parental-agents  { "net-servers"; };
    checkds          explicit;
};

parental-agents "net-servers" {
    192.5.6.30;                  // a.gtld-servers.net
    192.33.14.30;                // b.gtld-servers.net
};

zone "113.0.203.in-addr.arpa" IN {
    type primary;
    file "/var/lib/bind/zones/db.203.0.113";
    dnssec-policy "prod-ecdsa";
    inline-signing yes;
    allow-transfer { key "xfr-key"; };
    also-notify    { 192.0.2.53 key "xfr-key"; };
};
```

**The unsigned zone file** — note there is no DNSSEC material in it at all. With inline signing, `named` keeps the signed copy in a separate journal/`.signed` file and you never edit signed data by hand.

```dns
; /var/lib/bind/zones/db.example.net
$TTL 3600
$ORIGIN example.net.

@   IN  SOA ns1.example.net. hostmaster.example.net. (
                2026082001  ; serial   (YYYYMMDDnn)
                7200        ; refresh  2h
                3600        ; retry    1h
                1209600     ; expire   14d
                3600 )      ; minimum / negative TTL

@           IN  NS      ns1.example.net.
@           IN  NS      ns2.example.net.
@           IN  NS      ns3.example.net.

@           IN  MX  10  mx1.example.net.
@           IN  MX  20  mx2.example.net.

@           IN  CAA 0   issue "letsencrypt.org"
@           IN  CAA 0   iodef "mailto:security@example.net"

@           IN  TXT     "v=spf1 mx -all"

ns1         IN  A       192.0.2.1
ns1         IN  AAAA    2001:db8:1::53
ns2         IN  A       192.0.2.53
ns2         IN  AAAA    2001:db8:2::53
ns3         IN  A       198.51.100.53

mx1         IN  A       203.0.113.25
mx2         IN  A       203.0.113.26

www         IN  A       203.0.113.10
www         IN  A       203.0.113.11
www         IN  AAAA    2001:db8:3::10

api         IN  A       203.0.113.20

; DANE records -- see section 7
_25._tcp.mx1   IN  TLSA 3 1 1 (
                    8A9E1B4F2C0D77A3E5619B8C4D2F0A6E
                    3B7C1D95F84A20E6C3D71B0F5A94E28C )
_443._tcp.www  IN  TLSA 3 1 1 (
                    D4C8F1A2B7E390654C1D8B2FA07E63C9
                    18B4D70A2E5C9F3168B0DA47C25E19F8 )
```

**Bringing it up:**

```
$ sudo named-checkconf -z /etc/bind/named.conf
zone example.net/IN: loaded serial 2026082001
zone 113.0.203.in-addr.arpa/IN: loaded serial 2026082001

$ sudo systemctl restart named

$ sudo rndc status
version: BIND 9.20.4-1 (Extended Support Version) <id:...>
running on signer01: Linux x86_64 6.12.0-1-amd64
boot time: Thu, 20 Aug 2026 10:58:41 GMT
last configured: Thu, 20 Aug 2026 10:58:41 GMT
configuration file: /etc/bind/named.conf
CPUs found: 8
worker threads: 8
number of zones: 4 (0 automatic)
debug level: 0
xfers running: 0
xfers deferred: 0
soa queries in progress: 0
query logging is OFF
recursive clients: 0/900/1000
tcp clients: 0/150
TCP high-water: 0
server is up and running
```

```
$ sudo grep -E 'dnssec|key' /var/log/named/dnssec.log | tail -12
20-Aug-2026 10:59:12.104 dnssec: info: keymgr: DNSKEY example.net/ECDSAP256SHA256/34505 (KSK) created for policy prod-ecdsa
20-Aug-2026 10:59:12.109 dnssec: info: keymgr: DNSKEY example.net/ECDSAP256SHA256/51230 (ZSK) created for policy prod-ecdsa
20-Aug-2026 10:59:12.115 dnssec: info: keymgr: DNSKEY example.net/ECDSAP256SHA256/34505 (KSK) is now published
20-Aug-2026 10:59:12.115 dnssec: info: keymgr: DNSKEY example.net/ECDSAP256SHA256/51230 (ZSK) is now published
20-Aug-2026 10:59:12.118 dnssec: info: zone example.net/IN (signed): reconfiguring zone keys
20-Aug-2026 10:59:12.121 dnssec: info: zone example.net/IN (signed): next key event: 20-Aug-2026 11:59:12.115
20-Aug-2026 10:59:12.402 dnssec: info: zone example.net/IN (signed): sending notifies (serial 2026082002)
```

```
$ ls -l /var/lib/bind/keys/
total 16
-rw-r--r-- 1 bind bind  435 Aug 20 10:59 Kexample.net.+013+34505.key
-rw------- 1 bind bind  187 Aug 20 10:59 Kexample.net.+013+34505.private
-rw-r--r-- 1 bind bind  601 Aug 20 10:59 Kexample.net.+013+34505.state
-rw-r--r-- 1 bind bind  431 Aug 20 10:59 Kexample.net.+013+51230.key
-rw------- 1 bind bind  187 Aug 20 10:59 Kexample.net.+013+51230.private
-rw-r--r-- 1 bind bind  598 Aug 20 10:59 Kexample.net.+013+51230.state
```

The `.state` file is the key-manager's persistent state machine — **back it up with the private keys**; without it `named` re-derives conservative defaults and can stall a rollover.

```
$ cat /var/lib/bind/keys/Kexample.net.+013+34505.state
; This is the state of key 34505, for example.net.
Algorithm: 13
Length: 256
Lifetime: 63072000
KSK: yes
ZSK: no
Generated: 20260820105912 (Thu Aug 20 10:59:12 2026)
Published: 20260820105912 (Thu Aug 20 10:59:12 2026)
Active: 20260820105912 (Thu Aug 20 10:59:12 2026)
Retired: 20280819105912 (Sat Aug 19 10:59:12 2028)
Removed: 20280819135912 (Sat Aug 19 13:59:12 2028)
DNSKEYChange: 20260820105912 (Thu Aug 20 10:59:12 2026)
KRRSIGChange: 20260820105912 (Thu Aug 20 10:59:12 2026)
DSChange: 20260820105912 (Thu Aug 20 10:59:12 2026)
DNSKEYState: rumoured
KRRSIGState: rumoured
DSState: hidden
GoalState: omnipresent
```

**The four key states** — this vocabulary is what `rndc dnssec -status` speaks:

| State | Meaning |
|---|---|
| `hidden` | The record is not published and no cache holds it |
| `rumoured` | Published, but caches may not have it yet |
| `omnipresent` | Published long enough that every cache that could hold it, holds it |
| `unretentive` | Withdrawn, but stale caches may still serve it |

A key may only be relied upon for validation once its `DNSKEY` is `omnipresent`; it may only be removed once its signatures are `hidden`. That is the entire safety argument of the rollover machine.

**Live status:**

```
$ sudo rndc dnssec -status example.net
dnssec-policy: prod-ecdsa
current time:  Thu Aug 20 12:04:11 2026

key: 34505 (ECDSAP256SHA256), KSK
  published:      yes - since Thu Aug 20 10:59:12 2026
  key signing:    yes - since Thu Aug 20 10:59:12 2026

  Key is waiting to be published in the parent zone.
  Waiting for DS to be published in the parent (checkds explicit).

key: 51230 (ECDSAP256SHA256), ZSK
  published:      yes - since Thu Aug 20 10:59:12 2026
  zone signing:   yes - since Thu Aug 20 11:59:12 2026

  Next rollover scheduled on Tue Nov 17 10:59:12 2026
  - goal:           omnipresent
  - dnskey:         omnipresent
  - zone rrsig:     omnipresent
```

**Extracting the DS to hand to the registrar:**

```
$ dnssec-dsfromkey -a SHA-256 /var/lib/bind/keys/Kexample.net.+013+34505.key
example.net. IN DS 34505 13 2 6C2A9F3E17B4D08C5E19A6B27F40D3C8B195E62A4F0D7C31 \
                            B8E5A94206DF13C7

$ dig +short @192.0.2.1 example.net CDS
34505 13 2 6C2A9F3E17B4D08C5E19A6B27F40D3C8B195E62A4F0D7C31B8E5A94206DF13C7

$ dig +short @192.0.2.1 example.net CDNSKEY
257 3 13 mdsswUyr3DPW132mOi8V9xESWE8jTo0dxCjjnopKl+GqJxpVXckHAeF+ KkxLbxILfDLUT0rAK9iUzy1L53eKGQ==
```

Submit the `DS` to the registrar (EPP, web console, or Terraform provider). Then tell BIND the parent has it:

```
$ sudo rndc dnssec -checkds -key 34505 published example.net
$ sudo rndc dnssec -status example.net | head -8
dnssec-policy: prod-ecdsa
current time:  Thu Aug 20 15:41:02 2026

key: 34505 (ECDSAP256SHA256), KSK
  published:      yes - since Thu Aug 20 10:59:12 2026
  key signing:    yes - since Thu Aug 20 10:59:12 2026
  parent ds:      yes - since Thu Aug 20 15:41:02 2026
```

With `checkds explicit` and working `parental-agents`, BIND polls the parent itself and advances the state machine with no human step at all.

### 4.2 The manual path — `dnssec-keygen` / `dnssec-signzone`

Still required knowledge for the exam, and still the correct architecture when the KSK must live on an offline machine.

**Generate keys:**

```
$ cd /var/lib/bind/keys
$ sudo -u bind dnssec-keygen -a ECDSAP256SHA256 -f KSK -n ZONE example.net
Generating key pair.
Kexample.net.+013+34505

$ sudo -u bind dnssec-keygen -a ECDSAP256SHA256 -n ZONE example.net
Generating key pair.
Kexample.net.+013+51230
```

Useful flags:

| Flag | Meaning |
|---|---|
| `-a <alg>` | Algorithm. Since BIND 9.16 the default is `ECDSAP256SHA256` |
| `-b <bits>` | Key size — required for RSA, ignored/fixed for ECDSA and EdDSA |
| `-f KSK` | Set the SEP bit (flags 257) |
| `-f REVOKE` | Set the REVOKE bit (flags 385) — RFC 5011 |
| `-n ZONE` | Owner type. `HOST` for TSIG/SIG(0) host keys |
| `-3` | Use an NSEC3-capable algorithm (legacy; only relevant for RSASHA1) |
| `-P`/`-A`/`-I`/`-D` | Publish / Activate / Inactive / Delete times |
| `-P sync` / `-D sync` | CDS/CDNSKEY publish and delete times |
| `-L <ttl>` | Default TTL for the DNSKEY record |
| `-K <dir>` | Key directory |
| `-S <keyfile>` | Create a successor key for a smooth rollover |

**Inspect the public key:**

```
$ cat Kexample.net.+013+34505.key
; This is a key-signing key, keyid 34505, for example.net.
; Created: 20260820105912 (Thu Aug 20 10:59:12 2026)
; Publish: 20260820105912 (Thu Aug 20 10:59:12 2026)
; Activate: 20260820105912 (Thu Aug 20 10:59:12 2026)
example.net. IN DNSKEY 257 3 13 mdsswUyr3DPW132mOi8V9xESWE8jTo0dxCjjnopKl+Gq
JxpVXckHAeF+KkxLbxILfDLUT0rAK9iUzy1L53eKGQ==
```

Field-by-field: `257` = flags (ZONE + SEP), `3` = protocol (always 3), `13` = algorithm, then base64 of the raw public key.

**Include the keys and sign:**

```
$ sudo -u bind sh -c 'cat /var/lib/bind/keys/K example.net.+013+*.key >> \
      /var/lib/bind/zones/db.example.net'

$ cd /var/lib/bind/zones
$ sudo -u bind dnssec-signzone -A -3 - -H 0 -N INCREMENT -o example.net \
      -K /var/lib/bind/keys -S -x -t db.example.net
Fetching example.net/ECDSAP256SHA256/34505 (KSK) from key repository.
Fetching example.net/ECDSAP256SHA256/51230 (ZSK) from key repository.
Verifying the zone using the following algorithms: ECDSAP256SHA256.
Zone fully signed:
Algorithm: ECDSAP256SHA256: KSKs: 1 active, 0 stand-by, 0 revoked
                            ZSKs: 1 active, 0 stand-by, 0 revoked
db.example.net.signed
Signatures generated:                       31
Signatures retained:                         0
Signatures dropped:                          0
Signatures successfully verified:            0
Signatures unsuccessfully verified:          0
Signing time in seconds:                 0.019
Signatures per second:                1631.578
Runtime in seconds:                      0.031
```

| Flag | Meaning |
|---|---|
| `-o <origin>` | Zone origin (defaults to the filename — always set it explicitly) |
| `-S` | Smart signing: read key metadata and honour Publish/Activate/Inactive |
| `-3 <salt>` | Generate NSEC3; `-` means **no salt** (RFC 9276) |
| `-H <n>` | NSEC3 iterations; **`0`** |
| `-A` | NSEC3 opt-out **off** for the zone apex/insecure delegations (`-AA` enables opt-out) |
| `-x` | Sign the `DNSKEY` RRset with the KSK **only** (smaller responses) |
| `-N INCREMENT` | Bump the SOA serial automatically |
| `-t` | Print signing statistics |
| `-s`/`-e` | Signature inception/expiration (`now-1h`, `now+30d`) |
| `-K <dir>` | Key directory |
| `-P` | Disable post-sign verification (do not use) |

**Verify before serving:**

```
$ dnssec-verify -o example.net db.example.net.signed
Loading zone 'example.net' from file 'db.example.net.signed'
Verifying the zone using the following algorithms: ECDSAP256SHA256.
Zone fully signed:
Algorithm: ECDSAP256SHA256: KSKs: 1 active, 0 stand-by, 0 revoked
                            ZSKs: 1 active, 0 stand-by, 0 revoked

$ named-checkzone -D -o example.net example.net db.example.net.signed
zone example.net/IN: loaded serial 2026082002 (DNSSEC signed)
OK
```

Point the zone at `db.example.net.signed`, then `rndc reload example.net`.

**The trap of the manual model:** signatures expire 30 days after signing by default (`-e now+30d`). If your re-signing cron job dies silently, the zone goes bogus on day 30 with no warning. A minimal, honest cron:

```bash
#!/usr/bin/env bash
# /usr/local/sbin/resign-zones.sh -- re-sign every 7 days, alert loudly on failure
set -Eeuo pipefail

ZONEDIR=/var/lib/bind/zones
KEYDIR=/var/lib/bind/keys
ZONES=(example.net 113.0.203.in-addr.arpa)

trap 'logger -p daemon.crit -t resign "FAILED signing ${z:-?} at line $LINENO"; exit 1' ERR

for z in "${ZONES[@]}"; do
    tmp=$(mktemp "${ZONEDIR}/.${z}.XXXXXX")
    dnssec-signzone -S -x -A -3 - -H 0 -N INCREMENT \
        -o "$z" -K "$KEYDIR" \
        -s now-3600 -e now+21d \
        -f "$tmp" "${ZONEDIR}/db.${z}"
    dnssec-verify -o "$z" "$tmp"
    install -o bind -g bind -m 0640 "$tmp" "${ZONEDIR}/db.${z}.signed"
    rm -f "$tmp"
    rndc reload "$z"
    logger -p daemon.info -t resign "re-signed ${z}"
done
```

Note `-e now+21d` with a 7-day cadence: **three missed runs before an outage**, not zero.

### 4.3 Offline KSK and HSM storage

Native PKCS#11 support was **removed in BIND 9.18**. Key storage in an HSM now goes through OpenSSL:

* **OpenSSL 3.x provider:** `pkcs11-provider`, configured in `openssl.cnf`.
* **OpenSSL 1.1.x engine:** `engine_pkcs11` / `libp11` with `engine-pkcs11` in `named.conf` (`OPENSSL_CONF`).

```
$ dnssec-keyfromlabel -E pkcs11 -a ECDSAP256SHA256 -f KSK \
      -l "token=DNSSEC;object=example-net-ksk;pin-source=/etc/bind/hsm.pin" example.net
Kexample.net.+013+34505
```

The `.private` file then contains a label reference rather than key material:

```
$ cat Kexample.net.+013+34505.private
Private-key-format: v1.3
Algorithm: 13 (ECDSAP256SHA256)
Engine: pkcs11
Label: token=DNSSEC;object=example-net-ksk;pin-source=/etc/bind/hsm.pin
```

BIND 9.21 adds **offline-KSK** support (`offline-ksk yes;` in a `dnssec-policy`), where the KSK signs the `DNSKEY` RRset out of band into a Signed Key Response (SKR) file that the online signer consumes. Know it exists; it is the answer to "the KSK must never touch a network-attached host."

---

## 5. Key rollover

### 5.1 The two rollover shapes

**ZSK rollover — Pre-Publish.** Cheap, no parent involvement.

```
 t0            t1                  t2                  t3
 │             │                   │                   │
 ├─ ZSK-A signs the zone
 │             ├─ publish ZSK-B in DNSKEY (not signing yet)
 │             │   wait ≥ dnskey-ttl + propagation
 │             │                   ├─ switch: ZSK-B signs, ZSK-A stops
 │             │                   │   wait ≥ max-zone-ttl + propagation
 │             │                   │                   ├─ remove ZSK-A
```

Why pre-publish and not double-signature: it keeps the `DNSKEY` RRset small (only one extra key) and never doubles the number of `RRSIG`s in the zone. The invariant is *"the key needed to verify any cached RRSIG is always in the published DNSKEY RRset."*

**KSK rollover — Double-DS (or Double-KSK).** Expensive, requires the parent.

```
 t0            t1                    t2                    t3
 │             │                     │                     │
 ├─ KSK-A, DS(A) in parent
 │             ├─ publish DS(B) in the parent alongside DS(A)
 │             │   wait ≥ parent-ds-ttl + parent-propagation-delay
 │             │                     ├─ publish KSK-B, sign DNSKEY with B, drop A
 │             │                     │   wait ≥ dnskey-ttl + propagation
 │             │                     │                     ├─ remove DS(A)
```

| | **Double-DS** | **Double-KSK (double-signature)** |
|---|---|---|
| Order | DS first, then key | Key first, then DS |
| `DNSKEY` RRset size during roll | Unchanged | Two KSKs + two `RRSIG(DNSKEY)` |
| Parent interactions | 2 (add DS, remove DS) | 2 |
| Risk if the parent is slow | **None** — DS(B) is simply unused | The new key is live before the DS lands only if you misorder |
| Response size risk | Low | Can exceed 1232 B with RSA |
| BIND `dnssec-policy` default | **Double-DS** | — |

**Double-DS is the correct default** precisely because the slow, human, error-prone step (the registrar) happens **first**, while the old key is still fully functional. If the registrar takes three weeks, nothing breaks.

### 5.2 Automated rollover with `dnssec-policy`

Nothing to do — the policy's `lifetime` triggers it. To force one early (suspected compromise):

```
$ sudo rndc dnssec -rollover -key 51230 example.net

$ sudo rndc dnssec -status example.net
dnssec-policy: prod-ecdsa
current time:  Thu Aug 20 16:12:44 2026

key: 34505 (ECDSAP256SHA256), KSK
  published:      yes - since Thu Aug 20 10:59:12 2026
  key signing:    yes - since Thu Aug 20 10:59:12 2026
  parent ds:      yes - since Thu Aug 20 15:41:02 2026

key: 51230 (ECDSAP256SHA256), ZSK
  published:      yes - since Thu Aug 20 10:59:12 2026
  zone signing:   yes - since Thu Aug 20 11:59:12 2026

  Key will retire on Thu Aug 20 17:12:44 2026
  - goal:           hidden
  - dnskey:         omnipresent
  - zone rrsig:     omnipresent

key: 09417 (ECDSAP256SHA256), ZSK
  published:      yes - since Thu Aug 20 16:12:44 2026
  zone signing:   no

  Key is not yet signing the zone.
  - goal:           omnipresent
  - dnskey:         rumoured
  - zone rrsig:     hidden
```

Note the machine refuses to make ZSK-09417 sign until its `DNSKEY` reaches `omnipresent` — i.e. `dnskey-ttl + publish-safety + zone-propagation-delay` has elapsed. **You cannot force this safely, and you should not try.**

For the KSK, once the new DS is live in the parent and the old one removed:

```
$ sudo rndc dnssec -checkds -key 34505 withdrawn example.net
```

### 5.3 Manual rollover with `dnssec-settime`

`dnssec-settime` edits the timing metadata inside the `.key`/`.private` pair. Times are absolute (`YYYYMMDDHHMMSS`), relative to now (`+30d`), or relative to another event.

| Metadata | Flag | Meaning |
|---|---|---|
| Created | — | Set at generation, immutable |
| Publish | `-P` | Appears in the `DNSKEY` RRset |
| Activate | `-A` | Starts producing signatures |
| Revoke | `-R` | REVOKE bit set (RFC 5011 anchors only) |
| Inactive | `-I` | Stops producing new signatures (old ones still valid) |
| Delete | `-D` | Removed from the `DNSKEY` RRset |
| SyncPublish | `-P sync` | `CDS`/`CDNSKEY` published |
| SyncDelete | `-D sync` | `CDS`/`CDNSKEY` withdrawn |

The one ordering rule that prevents outages: **`Publish` ≤ `Activate` ≤ `Inactive` ≤ `Delete`**, with `Activate − Publish ≥ dnskey_ttl + propagation` and `Delete − Inactive ≥ max_zone_ttl + propagation`.

A complete pre-publish ZSK roll by hand:

```
$ cd /var/lib/bind/keys

# 1. Create the successor, inheriting timing relationships from the predecessor.
$ sudo -u bind dnssec-keygen -S Kexample.net.+013+51230 -i 7200
Generating key pair.
Kexample.net.+013+09417

# 2. Inspect what -S decided.
$ dnssec-settime -p all Kexample.net.+013+09417
Created: Thu Aug 20 16:20:03 2026
Publish: Thu Aug 20 14:20:03 2026
Activate: Wed Nov 18 10:59:12 2026
Predecessor: 51230

$ dnssec-settime -p all Kexample.net.+013+51230
Created: Thu Aug 20 10:59:12 2026
Publish: Thu Aug 20 10:59:12 2026
Activate: Thu Aug 20 10:59:12 2026
Inactive: Wed Nov 18 10:59:12 2026
Delete: Thu Nov 19 10:59:12 2026
Successor: 09417

# 3. Nothing else to do -- smart signing honours the metadata on every run.
$ sudo -u bind dnssec-signzone -S -x -A -3 - -H 0 -N INCREMENT \
      -o example.net -K /var/lib/bind/keys -t /var/lib/bind/zones/db.example.net
Fetching example.net/ECDSAP256SHA256/34505 (KSK) from key repository.
Fetching example.net/ECDSAP256SHA256/51230 (ZSK) from key repository.
Fetching example.net/ECDSAP256SHA256/09417 (ZSK) from key repository.
Verifying the zone using the following algorithms: ECDSAP256SHA256.
Zone fully signed:
Algorithm: ECDSAP256SHA256: KSKs: 1 active, 0 stand-by, 0 revoked
                            ZSKs: 1 active, 1 stand-by, 0 revoked
```

`1 active, 1 stand-by` is exactly the pre-publish state: ZSK-09417 is in the `DNSKEY` RRset but not signing.

**Emergency KSK roll with `-R` (RFC 5011 revocation)** applies only to keys used as *trust anchors* (the root, or an internal enterprise anchor). For a normal zone with a `DS` in the parent, revocation is meaningless — the parent's `DS` is authoritative and revocation is not what removes trust.

### 5.4 Rollover timing worksheet

Compute these once per zone and put them in the policy:

```
ZSK pre-publish interval  ≥ dnskey_ttl + zone_propagation_delay + publish_safety
ZSK post-retire interval  ≥ max_zone_ttl + zone_propagation_delay + retire_safety
KSK DS-publish interval   ≥ parent_ds_ttl + parent_propagation_delay + publish_safety
KSK DS-retire interval    ≥ parent_ds_ttl + parent_propagation_delay + retire_safety
```

For the policy in §4.1 (`dnskey-ttl 1h`, `max-zone-ttl 1d`, `parent-ds-ttl 1h`, `parent-propagation-delay 2h`, `zone-propagation-delay 10m`, safeties 1h):

| Step | Minimum wait |
|---|---|
| ZSK published → signing | 1 h + 10 m + 1 h = **2 h 10 m** |
| ZSK stops signing → removed | 24 h + 10 m + 1 h = **25 h 10 m** |
| DS published → new KSK signs DNSKEY | 1 h + 2 h + 1 h = **4 h** |
| Old KSK removed → old DS removed | 1 h + 2 h + 1 h = **4 h** |

Total ZSK roll: ~27 h. Total KSK roll: ~8 h *after* the registrar acts. Plan maintenance windows accordingly, and never compress these numbers to "make the change go faster."

---

## 6. BIND 9 as a validating recursive resolver

**`/etc/bind/named.conf` — complete validating recursor:**

```conf
// ---------------------------------------------------------------------------
// /etc/bind/named.conf  --  validating recursive resolver
// BIND 9.20.x
// ---------------------------------------------------------------------------

include "/etc/bind/tsig/rndc-key.conf";

acl "internal" {
    10.0.0.0/8;
    172.16.0.0/12;
    192.168.0.0/16;
    fd00::/8;
    127.0.0.1;
    ::1;
};

tls "resolver-tls" {
    cert-file "/etc/bind/tls/fullchain.pem";
    key-file  "/etc/bind/tls/privkey.pem";
    protocols { TLSv1.3; };
    ciphers   "HIGH:!aNULL:!eNULL:!MD5:!RC4";
    prefer-server-ciphers yes;
    session-tickets no;
};

http "resolver-http" {
    endpoints { "/dns-query"; };
};

options {
    directory              "/var/cache/bind";
    managed-keys-directory "/var/cache/bind/keys";   // RFC 5011 state -- MUST be writable by named
    pid-file               "/run/named/named.pid";

    listen-on port 53  { 10.20.0.53; 127.0.0.1; };
    listen-on-v6 port 53 { fd00:20::53; ::1; };

    // DNS over TLS (RFC 7858) and DNS over HTTPS (RFC 8484)
    listen-on port 853 tls "resolver-tls" { 10.20.0.53; };
    listen-on-v6 port 853 tls "resolver-tls" { fd00:20::53; };
    listen-on port 443 tls "resolver-tls" http "resolver-http" { 10.20.0.53; };

    recursion yes;
    allow-query        { "internal"; };
    allow-recursion    { "internal"; };
    allow-query-cache  { "internal"; };
    allow-transfer     { none; };

    // ---- DNSSEC validation ------------------------------------------------
    // "auto" loads the built-in root trust anchor from /etc/bind/bind.keys and
    // maintains it automatically per RFC 5011. Do NOT hardcode a DS unless you
    // have an operational process for the next root KSK rollover.
    dnssec-validation      auto;
    // "yes" would require an explicit trust-anchors{} block, with no RFC 5011
    // tracking -- a liability during a root KSK roll.

    // Serve stale answers rather than SERVFAIL when upstream is unreachable.
    // This does NOT bypass validation: bogus data is still refused.
    stale-answer-enable    yes;
    stale-answer-ttl       30;
    max-stale-ttl          86400;
    stale-refresh-time     30;
    stale-answer-client-timeout 1800;   // ms

    // Aggressive use of DNSSEC-validated cache (RFC 8198): synthesise NXDOMAIN
    // from cached NSEC/NSEC3. Cuts random-subdomain-attack traffic dramatically.
    synth-from-dnssec      yes;

    // QNAME minimisation (RFC 9156): send only the label the upstream needs.
    qname-minimization      relaxed;

    // Flag Day 2020
    edns-udp-size          1232;
    max-udp-size           1232;

    // Do not become an amplifier if the ACL is ever misconfigured.
    rate-limit {
        responses-per-second 50;
        slip 2;
        window 5;
        exempt-clients { "internal"; };
    };

    // Prefetch popular records before they expire -- smooths validation cost.
    prefetch 2 9;

    max-cache-size         60%;
    max-cache-ttl          86400;
    max-ncache-ttl         3600;

    minimal-responses      yes;
    version                none;
    hostname               none;
};

controls {
    inet 127.0.0.1 port 953 allow { 127.0.0.1; } keys { "rndc-key"; };
};

statistics-channels {
    inet 127.0.0.1 port 8053 allow { 127.0.0.1; };
};

logging {
    channel "dnssec_log" {
        file "/var/log/named/dnssec.log" versions 10 size 50m;
        severity debug 3;                 // level 3 shows every validation step
        print-time yes; print-category yes; print-severity yes;
    };
    channel "resolver_log" {
        file "/var/log/named/resolver.log" versions 5 size 50m;
        severity info;
        print-time yes; print-category yes;
    };
    category dnssec       { "dnssec_log"; };
    category resolver     { "resolver_log"; };
    category lame-servers { "null"; };
    category default      { "resolver_log"; };
};

// Optional: forward a private namespace to internal authoritatives, and mark it
// insecure so validation does not fail on an unsigned internal zone whose parent
// is signed.
zone "corp.example.net" {
    type forward;
    forward only;
    forwarders { 10.20.1.53; 10.20.2.53; };
};

// Local trust anchor for an internal zone whose parent cannot hold a DS.
trust-anchors {
    corp.example.net. static-ds 62311 13 2
        "1F5C0AB93D7E4682C0A5B3E71D94F208C6B7A3E50D291F84B0C7E635A9D2F14C";
};
```

**Verifying validation works, end to end:**

```
$ dig +dnssec +multi @10.20.0.53 www.example.net A

; <<>> DiG 9.20.4 <<>> +dnssec +multi @10.20.0.53 www.example.net A
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 41532
;; flags: qr rd ra ad; QUERY: 1, ANSWER: 4, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags: do; udp: 1232
;; QUESTION SECTION:
;www.example.net.	IN A

;; ANSWER SECTION:
www.example.net.	3600 IN A 203.0.113.10
www.example.net.	3600 IN A 203.0.113.11
www.example.net.	3600 IN RRSIG A 13 3 3600 (
				20260903120000 20260820120000 51230 example.net.
				kZ8vQ3mF1tY7pR2wX9cH4nB6dL0aS5jE
				gT8uV2yK1xM7rN3qP6zC4wD9fA0bH5eI= )

;; Query time: 148 msec
;; SERVER: 10.20.0.53#53(10.20.0.53) (UDP)
;; WHEN: Thu Aug 20 12:31:07 UTC 2026
;; MSG SIZE  rcvd: 251
```

**`ad` in the flags is the proof.** Its absence means insecure or unvalidated — never assume.

```
$ delv +rtrace @10.20.0.53 www.example.net A
;; fetch: www.example.net/A
;; fetch: example.net/DNSKEY
;; fetch: example.net/DS
;; fetch: net/DNSKEY
;; fetch: net/DS
;; fetch: ./DNSKEY
; fully validated
www.example.net.	3600	IN	A	203.0.113.10
www.example.net.	3600	IN	A	203.0.113.11
www.example.net.	3600	IN	RRSIG	A 13 3 3600 20260903120000 20260820120000 51230 example.net. kZ8vQ3mF1tY7pR2wX9cH4nB6dL0aS5jEgT8uV2yK1xM7rN3qP6zC4wD9fA0bH5eI=
```

`delv` is **not** `dig +dnssec`. `dig` shows you what the server said; `delv` performs the validation *itself*, in the client, using the same library `named` uses. When the resolver says bogus and you need to know *why*, `delv` is the tool.

```
$ delv +vtrace @10.20.0.53 www.broken-sig.test A
;; fetch: www.broken-sig.test/A
;; validating www.broken-sig.test/A: starting
;; validating www.broken-sig.test/A: attempting positive response validation
;; fetch: broken-sig.test/DNSKEY
;; validating broken-sig.test/DNSKEY: starting
;; validating broken-sig.test/DNSKEY: attempting positive response validation
;; validating broken-sig.test/DNSKEY: verify failed due to bad signature (keyid=51230): RRSIG has expired
;; validating broken-sig.test/DNSKEY: no valid signature found
;; broken-sig.test/DNSKEY: got insecure response; parent indicates it should be secure
;; validating www.broken-sig.test/A: in fetch_callback_validator
;; validating www.broken-sig.test/A: fetch_callback_validator: got broken trust chain
;; validating www.broken-sig.test/A: bad trust chain
;; resolution failed: broken trust chain
```

**The `+cd` triage, in one command pair:**

```
$ dig +short @10.20.0.53 www.broken-sig.test A
                                              # empty -> SERVFAIL

$ dig @10.20.0.53 www.broken-sig.test A | grep -E 'status|flags'
;; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 22194
;; flags: qr rd ra; QUERY: 1, ANSWER: 0, AUTHORITY: 0, ADDITIONAL: 1

$ dig +cd @10.20.0.53 www.broken-sig.test A | grep -E 'status|^www'
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 39471
www.broken-sig.test.	300	IN	A	198.51.100.77
```

`+cd` succeeds, plain fails ⇒ **DNSSEC validation failure, not a server or data problem.**

**Negative Trust Anchors** — the emergency valve when a *third party's* zone is bogus and your users need it now. This is deliberately temporary; the maximum lifetime is capped (`max-ntas`, default 1 week) and it is not persisted across restarts by default.

```
$ sudo rndc nta -d 3600 broken-sig.test
Negative trust anchor added: broken-sig.test/_default, expires 20-Aug-2026 13:33:12.000

$ sudo rndc nta -dump
broken-sig.test/_default: expiry 20-Aug-2026 13:33:12.000

$ dig +short @10.20.0.53 www.broken-sig.test A
198.51.100.77

$ sudo rndc nta -remove broken-sig.test
Negative trust anchor removed: broken-sig.test/_default
```

**Never add an NTA for a zone you operate.** It hides your own outage from yourself while every other resolver on the Internet still fails.

**Trust anchor status:**

```
$ sudo rndc managed-keys status
view: _default
next scheduled event: Fri, 21 Aug 2026 04:11:52 GMT

  name: .
    keyid: 20326
      algorithm: RSASHA256
      flags: KSK SEP
      next refresh: Fri, 21 Aug 2026 04:11:52 GMT
      trusted since: Thu, 20 Aug 2026 10:44:03 GMT
```

If you must pin the root anchor explicitly (air-gapped build, no writable `managed-keys-directory`):

```conf
trust-anchors {
    // Root KSK-2017 -- verify against https://data.iana.org/root-anchors/root-anchors.xml
    . initial-ds 20326 8 2
        "E06D44B80B8F1D39A95C0B0D7C65D08458E880409BBC683457104237C7F8EC8D";
};
```

`initial-ds` / `initial-key` enable RFC 5011 tracking from that starting point (the value is a *bootstrap*, and `named` maintains the live set in `managed-keys-directory`). `static-ds` / `static-key` disable tracking entirely — correct only for internal anchors you roll yourself, **never** for the root.

### 6.1 systemd-resolved (awareness)

```ini
# /etc/systemd/resolved.conf.d/50-secure.conf
[Resolve]
DNS=9.9.9.9#dns.quad9.net 2620:fe::fe#dns.quad9.net
FallbackDNS=
Domains=~.
DNSOverTLS=yes
DNSSEC=yes
DNSStubListenerExtra=127.0.0.53:53
Cache=yes
CacheFromLocalhost=no
```

```
$ resolvectl status
Global
         Protocols: +LLMNR +mDNS +DNSOverTLS DNSSEC=yes/supported
  resolv.conf mode: stub
Current DNS Server: 9.9.9.9#dns.quad9.net
       DNS Servers: 9.9.9.9#dns.quad9.net 2620:fe::fe#dns.quad9.net
        DNS Domain: ~.

$ resolvectl query www.example.net
www.example.net: 203.0.113.10                  -- link: eth0
                 203.0.113.11                  -- link: eth0

-- Information acquired via protocol DNS in 21.4ms.
-- Data is authenticated: yes; Data was acquired via local or encrypted transport: yes
-- Data from: network

$ resolvectl statistics
DNSSEC Verdicts
Secure: 1842
Insecure: 9317
Bogus: 3
Indeterminate: 0
```

**Operational reality check:** `DNSSEC=yes` in `resolved` is genuinely fail-closed and genuinely breaks on hotel/airport captive portals and on corporate split-horizon zones whose parents are signed. `DNSSEC=allow-downgrade` is a **security-theatre setting** — it lets an on-path attacker who strips the `DO` bit turn validation off, which is exactly the attacker DNSSEC exists to stop. On a server, the right answer is a real validating resolver (`named`, `unbound`) on localhost with `DNSSEC=no` in `resolved`; on a laptop, `DNSSEC=yes` plus a documented workaround for captive portals.

---

## 7. DANE — binding X.509 to DNS

### 7.1 The problem DANE solves

The WebPKI's trust model is "any of ~150 CAs may issue for any name." DANE inverts it: **the domain owner states, in DNSSEC-protected DNS, which certificate or CA is acceptable for a given service.**

The `TLSA` record lives at a structured owner name:

```
_<port>._<proto>.<hostname>.  IN  TLSA  <usage> <selector> <matching-type> <data>
```

| Field | Value | Name | Meaning |
|---|---|---:|---|
| **Usage** | 0 | PKIX-TA | Cert chain must contain this CA **and** validate against the system trust store |
| | 1 | PKIX-EE | The EE cert must be this **and** validate against the system trust store |
| | 2 | DANE-TA | Chain must be anchored at this CA; **system trust store not consulted** |
| | **3** | **DANE-EE** | The EE cert must be exactly this; **no CA, no expiry check, no name check** |
| **Selector** | 0 | Cert | Match the full DER certificate |
| | **1** | **SPKI** | Match the `SubjectPublicKeyInfo` — survives certificate renewal with the same key |
| **Matching** | 0 | Full | The raw data |
| | **1** | **SHA-256** | SHA-256 digest — the only sane choice |
| | 2 | SHA-512 | SHA-512 digest |

| Combination | Renewal behaviour | Trust store needed | Recommended for |
|---|---|---|---|
| `3 1 1` | Survives renewal **if the key is reused** | No | **SMTP (RFC 7672), self-signed services, internal PKI** |
| `3 0 1` | Breaks on every renewal | No | Only with tight automation |
| `2 1 1` | Survives EE renewal entirely | No | Private CA; long-lived intermediates |
| `2 0 1` | Survives EE renewal | No | Pinning a public intermediate — **fragile**, CAs rotate intermediates |
| `1 1 1` | Breaks on renewal | **Yes** | Belt-and-braces web pinning |
| `0 x 1` | Stable | **Yes** | Rarely useful |

**Usage 0 and 1 are effectively dead for browsers** — no mainstream browser implements DANE. DANE's real, mandatory, load-bearing deployment is **SMTP (RFC 7672)**, where it fixes the fundamental flaw of opportunistic STARTTLS: an on-path attacker can strip the `STARTTLS` capability and the sending MTA silently falls back to plaintext. With a `TLSA` record present and DNSSEC-validated, the sender **must** use TLS and **must** match the record.

### 7.2 Generating TLSA records

```
# 3 1 1 -- DANE-EE, SPKI, SHA-256 -- from a live server
$ openssl s_client -connect mx1.example.net:25 -starttls smtp -showcerts </dev/null 2>/dev/null \
  | openssl x509 -noout -pubkey \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -binary \
  | xxd -p -c 64
8a9e1b4f2c0d77a3e5619b8c4d2f0a6e3b7c1d95f84a20e6c3d71b0f5a94e28c

# ...or from a local certificate file
$ openssl x509 -in /etc/ssl/certs/mx1.pem -noout -pubkey \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -binary | xxd -p -c 64
8a9e1b4f2c0d77a3e5619b8c4d2f0a6e3b7c1d95f84a20e6c3d71b0f5a94e28c

# 3 0 1 -- full certificate, SHA-256
$ openssl x509 -in /etc/ssl/certs/mx1.pem -outform DER \
  | openssl dgst -sha256 -binary | xxd -p -c 64
c71a05b8e3d94f2016ab7c58d0e93f41b62a8c07d5194e3fa8b06c21d7e4593a
```

Resulting records:

```dns
_25._tcp.mx1.example.net.  3600 IN TLSA 3 1 1 8a9e1b4f2c0d77a3e5619b8c4d2f0a6e3b7c1d95f84a20e6c3d71b0f5a94e28c
_25._tcp.mx2.example.net.  3600 IN TLSA 3 1 1 8a9e1b4f2c0d77a3e5619b8c4d2f0a6e3b7c1d95f84a20e6c3d71b0f5a94e28c
_443._tcp.www.example.net. 3600 IN TLSA 3 1 1 d4c8f1a2b7e390654c1d8b2fa07e63c918b4d70a2e5c9f3168b0da47c25e19f8
```

`TLSA` for SMTP goes on the **MX target hostname**, not on the domain. And the MX target's own name must be DNSSEC-secure, or RFC 7672 says DANE does not apply.

### 7.3 Verifying DANE

```
$ dig +dnssec +short @10.20.0.53 _25._tcp.mx1.example.net TLSA
3 1 1 8A9E1B4F2C0D77A3E5619B8C4D2F0A6E3B7C1D95F84A20E6C3D71B0F5A94E28C
TLSA 13 4 3600 20260903120000 20260820120000 51230 example.net. Qm4x...

$ delv @10.20.0.53 _25._tcp.mx1.example.net TLSA
; fully validated
_25._tcp.mx1.example.net. 3600 IN TLSA 3 1 1 8A9E1B4F2C0D77A3E5619B8C4D2F0A6E3B7C1D95F84A20E6C3D71B0F5A94E28C
_25._tcp.mx1.example.net. 3600 IN RRSIG TLSA 13 4 3600 20260903120000 20260820120000 51230 example.net. Qm4x...
```

**End-to-end validation with OpenSSL's built-in DANE support:**

```
$ openssl s_client -connect mx1.example.net:25 -starttls smtp \
      -dane_tlsa_domain mx1.example.net \
      -dane_tlsa_rrdata "3 1 1 8a9e1b4f2c0d77a3e5619b8c4d2f0a6e3b7c1d95f84a20e6c3d71b0f5a94e28c" \
      </dev/null 2>&1 | grep -E 'DANE|Verify|Verification'
DANE TLSA 3 1 1 ...5a94e28c matched EE certificate at depth 0
Verification: OK
Verify return code: 0 (ok)
```

A **failure** looks like this — note that the TLS handshake itself succeeds; only the DANE binding fails:

```
$ openssl s_client -connect mx1.example.net:25 -starttls smtp \
      -dane_tlsa_domain mx1.example.net \
      -dane_tlsa_rrdata "3 1 1 0000000000000000000000000000000000000000000000000000000000000000" \
      </dev/null 2>&1 | grep -E 'DANE|Verify|Verification'
Verification error: No matching DANE TLSA records
Verify return code: 65 (No matching DANE TLSA records)
```

Automated end-to-end check (validates the DNSSEC chain *and* the TLS binding):

```
$ danetool --check mx1.example.net --port 25 --starttls-proto smtp
Resolving 'mx1.example.net'...
Obtaining certificate from '203.0.113.25:25'...
Querying DNS for _25._tcp.mx1.example.net (TLSA)...
Verification: Certificate matches. Verified.
```

### 7.4 Deploying DANE for SMTP with Postfix

**Sending side** (verify other people's DANE records) — requires a **validating** resolver:

```conf
# /etc/postfix/main.cf
smtp_dns_support_level = dnssec
smtp_tls_security_level = dane
smtp_tls_loglevel = 1
smtp_host_lookup = dns
```

```
$ sudo postmap -q "secure-partner.example" \
      socketmap:unix:/var/spool/postfix/private/tlsproxy:
$ sudo grep 'Verified TLS' /var/log/mail.log | tail -2
Aug 20 13:02:11 mx1 postfix/smtp[8812]: Verified TLS connection established to
  mx.secure-partner.example[198.51.100.25]:25: TLSv1.3 with cipher
  TLS_AES_256_GCM_SHA384 (256/256 bits) key-exchange X25519 server-signature
  ECDSA (P-256) server-digest SHA256
```

`Verified TLS connection` (as opposed to `Trusted` or `Untrusted`) is the log line that proves DANE matched.

**Receiving side** — publish `TLSA` for your own MX hosts and make renewal safe. The key discipline: **reuse the key pair on renewal** so a `3 1 1` SPKI record survives, or run a publish-then-switch rollover.

The renewal rollover, in order:

1. Generate the new key/CSR **without** deploying it.
2. Publish a **second** `TLSA` record for the new SPKI alongside the old.
3. Wait ≥ the `TLSA` TTL + propagation.
4. Install the new certificate and reload the MTA.
5. Wait ≥ the `TLSA` TTL again.
6. Remove the old `TLSA` record.

Doing steps 4 and 2 in the wrong order is a mail outage that only affects senders who do DANE correctly — i.e. exactly your most security-conscious partners.

### 7.5 DANE vs the alternatives for SMTP

| | **DANE (RFC 7672)** | **MTA-STS (RFC 8461)** | **Plain opportunistic STARTTLS** |
|---|---|---|---|
| Trust root | DNSSEC | WebPKI + HTTPS policy file | None |
| Requires signed zone | **Yes** | No | No |
| Downgrade-proof | Yes | Only after the first successful fetch (TOFU) | **No** |
| Policy discovery | `TLSA` in DNS | `_mta-sts` TXT + `https://mta-sts.<domain>/.well-known/mta-sts.txt` | — |
| Failure mode | Hard fail | Hard fail after policy cached | Silent plaintext |
| Extra moving parts | Signed DNS | A web server that must never break | None |
| Reporting | — | TLS-RPT (RFC 8460) | — |

They are complementary, not competing: publish **both**. DANE covers DNSSEC-capable senders with no HTTPS dependency; MTA-STS covers the large providers that have chosen not to deploy DNSSEC validation.

---

## 8. TSIG — authenticating server-to-server DNS

DNSSEC authenticates **data**. TSIG (RFC 8945, obsoleting RFC 2845) authenticates **transactions**: a shared HMAC secret between two parties, covering the whole DNS message plus a timestamp.

Use TSIG for:

* **Zone transfers** (AXFR/IXFR) — IP ACLs alone are spoofable and useless behind NAT or in cloud VPCs with rotating addresses.
* **NOTIFY** messages.
* **Dynamic updates** (RFC 2136) — ACME DNS-01, DHCP-DDNS, `cert-manager`.
* **`rndc`** — the control channel is TSIG-protected by construction.

### 8.1 Generating and configuring keys

```
$ tsig-keygen -a hmac-sha256 xfr-key
key "xfr-key" {
	algorithm hmac-sha256;
	secret "Vc3AqfE7wJ2z2iZ+2Cq1sLh0X9dQ1ZKp4X1p3Yv4S6Y=";
};

$ sudo tsig-keygen -a hmac-sha256 acme-update-key > /etc/bind/tsig/acme-key.conf
$ sudo chown root:bind /etc/bind/tsig/acme-key.conf
$ sudo chmod 0640 /etc/bind/tsig/acme-key.conf
```

`ddns-confgen` is the legacy name; `tsig-keygen` is the current tool. `dnssec-keygen -a HMAC-SHA256 -n HOST` also works and produces `K<name>.+165+<tag>.{key,private}` files, which is the form `dig -k` and `nsupdate -k` consume.

| TSIG algorithm | Status | Note |
|---|---|---|
| `hmac-md5` (`HMAC-MD5.SIG-ALG.REG.INT`) | **Deprecated** | Legacy default; do not use |
| `hmac-sha1` | Deprecated | Avoid |
| `hmac-sha224` | Allowed | Unusual |
| `hmac-sha256` | **Recommended default** | 256-bit secret |
| `hmac-sha384` / `hmac-sha512` | Allowed | Larger, no practical gain |
| GSS-TSIG (RFC 3645) | Allowed | Kerberos-authenticated updates (AD integration) |

**Primary side:**

```conf
include "/etc/bind/tsig/xfr-key.conf";
include "/etc/bind/tsig/acme-key.conf";

zone "example.net" IN {
    type primary;
    file "/var/lib/bind/zones/db.example.net";
    dnssec-policy "prod-ecdsa";
    inline-signing yes;

    allow-transfer { key "xfr-key"; };
    also-notify    { 192.0.2.53 key "xfr-key"; 198.51.100.53 key "xfr-key"; };
    notify explicit;

    // Restrict dynamic updates to the ACME challenge label only.
    update-policy {
        grant "acme-update-key" name _acme-challenge.example.net. TXT;
        grant "acme-update-key" subdomain _acme-challenge.example.net. TXT;
    };
};
```

`update-policy` is strictly better than `allow-update { key "..."; }`: the latter grants **the whole zone** to whoever holds the key. `update-policy` grant types worth knowing: `name` (exact), `subdomain`, `zonesub`, `wildcard`, `self`, `selfsub`, `krb5-self`, `ms-self`, `tcp-self`, `external`.

**Secondary side:**

```conf
include "/etc/bind/tsig/xfr-key.conf";

// Bind the key to the peer address: every message to/from this IP is signed.
server 192.0.2.1  { keys { "xfr-key"; }; };
server 2001:db8:1::53 { keys { "xfr-key"; }; };

zone "example.net" IN {
    type secondary;
    file "/var/lib/bind/zones/sec.example.net";
    primaries { 192.0.2.1; 2001:db8:1::53; };
    allow-transfer { none; };
    allow-notify   { key "xfr-key"; };
    // Do NOT set dnssec-policy here -- a secondary transfers already-signed data.
};
```

The `server` statement is the piece people forget. Without it, the secondary will *accept* signed messages but will not *sign* the AXFR request it sends, and the primary will refuse it.

### 8.2 Testing TSIG

```
$ dig @192.0.2.1 example.net AXFR -y hmac-sha256:xfr-key:Vc3AqfE7wJ2z2iZ+2Cq1sLh0X9dQ1ZKp4X1p3Yv4S6Y=

; <<>> DiG 9.20.4 <<>> @192.0.2.1 example.net AXFR -y hmac-sha256:xfr-key:[key]
; (1 server found)
;; global options: +cmd
example.net.	3600 IN SOA ns1.example.net. hostmaster.example.net. 2026082002 7200 3600 1209600 3600
example.net.	3600 IN RRSIG SOA 13 2 3600 20260903120000 20260820120000 51230 example.net. Lx7...
example.net.	3600 IN NS ns1.example.net.
...
example.net.	3600 IN SOA ns1.example.net. hostmaster.example.net. 2026082002 7200 3600 1209600 3600
;; Query time: 12 msec
;; SERVER: 192.0.2.1#53(192.0.2.1) (TCP)
;; WHEN: Thu Aug 20 13:44:02 UTC 2026
;; XFR size: 47 records (messages 1, bytes 4318)

;; TSIG PSEUDOSECTION:
xfr-key.		0	ANY	TSIG	hmac-sha256. 1755697442 300 32 3nQ7xK9mB2vT... 51203 NOERROR 0
```

Putting the secret on the command line leaks it into `ps` and shell history. Use a key file:

```
$ dig @192.0.2.1 example.net AXFR -k /etc/bind/tsig/Kxfr-key.+165+51203.key
```

**Rejection without the key — this is what "it works" looks like from the outside:**

```
$ dig @192.0.2.1 example.net AXFR

; <<>> DiG 9.20.4 <<>> @192.0.2.1 example.net AXFR
;; global options: +cmd
; Transfer failed.
```

```
$ sudo tail -3 /var/log/named/xfer.log
20-Aug-2026 13:45:19.221 xfer-out: info: client @0x7f3c1004a120 198.51.100.9#51882
  (example.net): bad zone transfer request: 'example.net/IN': non-authoritative zone (NOTAUTH)
20-Aug-2026 13:45:19.221 security: info: client @0x7f3c1004a120 198.51.100.9#51882
  (example.net): zone transfer 'example.net/IN' denied
```

**Clock skew — the classic TSIG failure.** The default `fudge` is 300 s; the signature covers a timestamp.

```
$ dig @192.0.2.1 example.net SOA -y hmac-sha256:xfr-key:Vc3AqfE7wJ2z2iZ+2Cq1sLh0X9dQ1ZKp4X1p3Yv4S6Y=
;; Couldn't verify signature: tsig verify failure
...
;; TSIG PSEUDOSECTION:
xfr-key.	0 ANY TSIG hmac-sha256. 1755697442 300 0  18 BADTIME 6 ...
```

`BADTIME` (error 18) ⇒ the two hosts' clocks differ by more than the fudge. **Run NTP on every DNS server**; this is not optional once TSIG or DNSSEC is in play. TSIG error codes: `BADSIG` 16 (wrong secret), `BADKEY` 17 (unknown key name), `BADTIME` 18 (clock skew), `BADTRUNC` 22 (truncated MAC rejected).

### 8.3 Dynamic update with `nsupdate` (the ACME DNS-01 path)

```
$ nsupdate -k /etc/bind/tsig/Kacme-update-key.+165+42817.key -v <<'EOF'
server 192.0.2.1
zone example.net
update delete _acme-challenge.example.net. TXT
update add    _acme-challenge.example.net. 60 TXT "gfj9Xq...Rg85nM"
send
EOF

$ dig +short @192.0.2.1 _acme-challenge.example.net TXT
"gfj9Xq...Rg85nM"

$ sudo tail -2 /var/log/named/general.log
20-Aug-2026 13:51:07.442 update: info: client @0x7f3c10052ab0 10.20.4.18#39114/key
  acme-update-key: updating zone 'example.net/IN': deleting rrset at
  '_acme-challenge.example.net' TXT
20-Aug-2026 13:51:07.443 update: info: client @0x7f3c10052ab0 10.20.4.18#39114/key
  acme-update-key: updating zone 'example.net/IN': adding an RR at
  '_acme-challenge.example.net' TXT "gfj9Xq...Rg85nM"
```

With `dnssec-policy` + `inline-signing`, `named` re-signs the changed RRset immediately. No re-sign step, no serial bump by hand.

**Complete Kubernetes manifests — cert-manager RFC2136 solver over TSIG:**

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: bind-tsig-acme
  namespace: cert-manager
type: Opaque
stringData:
  # The raw base64 secret from tsig-keygen -- NOT re-encoded.
  # (stringData handles the Kubernetes-level base64 for us.)
  tsig-secret-key: "Kq7Rz2Xw9Nm4Bv6Tc1Yh8Jd0Ls5Pe3Fg7Ua2Wi4Oq="
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-dns01
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: hostmaster@example.net
    privateKeySecretRef:
      name: letsencrypt-dns01-account-key
    solvers:
      - selector:
          dnsZones:
            - "example.net"
        dns01:
          rfc2136:
            nameserver: "192.0.2.1:53"
            tsigKeyName: "acme-update-key"
            tsigAlgorithm: HMACSHA256
            tsigSecretSecretRef:
              name: bind-tsig-acme
              key: tsig-secret-key
          # Do not ask the cluster's own resolver whether the TXT record is
          # visible -- it may be split-horizon. Check the authoritative servers.
      - selector: {}
        http01:
          ingress:
            ingressClassName: nginx
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-example-net
  namespace: platform
spec:
  secretName: wildcard-example-net-tls
  issuerRef:
    name: letsencrypt-dns01
    kind: ClusterIssuer
  commonName: "*.example.net"
  dnsNames:
    - "example.net"
    - "*.example.net"
  duration: 2160h      # 90d
  renewBefore: 720h    # 30d
  privateKey:
    algorithm: ECDSA
    size: 256
    # rotationPolicy: Never  <-- REQUIRED if you publish a DANE `3 1 1` record
    #                            for this certificate: reusing the key keeps the
    #                            SPKI digest stable across renewals.
    rotationPolicy: Always
```

```yaml
---
# cert-manager must resolve the ACME propagation check against the
# authoritative servers, not the cluster resolver.
apiVersion: v1
kind: ConfigMap
metadata:
  name: cert-manager-dns-config
  namespace: cert-manager
data:
  extraArgs: |
    --dns01-recursive-nameservers=192.0.2.1:53,198.51.100.53:53
    --dns01-recursive-nameservers-only
```

**Security note on the grant.** The `update-policy` above restricts `acme-update-key` to `_acme-challenge.example.net` `TXT` records only. If you instead write `allow-update { key "acme-update-key"; };`, a compromised cert-manager pod can rewrite your `MX`, your `A` records, and your `TLSA` records. Scope the grant.

### 8.4 TSIG vs SIG(0) vs mutual TLS

| | **TSIG** | **SIG(0)** (RFC 2931) | **XoT / mTLS** (RFC 9103) |
|---|---|---|---|
| Cryptography | Symmetric HMAC | Asymmetric (public key in DNS) | TLS with client certificates |
| Key distribution | Out-of-band shared secret, **O(n²)** pairs | Public key published in DNS, **O(n)** | PKI, **O(n)** |
| Confidentiality of the transfer | **None** — AXFR is plaintext | None | **Yes** |
| Compromise of one peer | Exposes the shared secret for that pair | Exposes only that peer's private key | Exposes one client cert |
| Replay protection | Timestamp + fudge (needs NTP) | Timestamp (needs NTP) | TLS |
| Server support | Universal | Patchy | BIND 9.18+, Knot, Unbound |
| Best for | Two-party primary/secondary, dynamic update | Multi-party, key rotation without coordination | Confidential transfers, cloud/hostile networks |

**Zone transfer over TLS (XoT)** in BIND 9.18+, when the zone contents themselves are sensitive:

```conf
tls "xot-primary" {
    cert-file "/etc/bind/tls/ns1-fullchain.pem";
    key-file  "/etc/bind/tls/ns1-privkey.pem";
    ca-file   "/etc/bind/tls/internal-ca.pem";   // require a client cert
    remote-hostname "ns1.example.net";
    protocols { TLSv1.3; };
};

// Primary
options { listen-on port 853 tls "xot-primary" { 192.0.2.1; }; };

// Secondary
zone "example.net" {
    type secondary;
    primaries { 192.0.2.1 port 853 tls "xot-primary" key "xfr-key"; };
    file "/var/lib/bind/zones/sec.example.net";
};
```

TSIG and XoT compose: TLS gives confidentiality and channel authentication, TSIG gives message authentication that survives a TLS-terminating proxy.

---

## 9. Encrypted DNS transports

### 9.1 The comparison

| | **Do53** | **DoT** (RFC 7858) | **DoH** (RFC 8484) | **DoQ** (RFC 9250) | **DNSCrypt** | **ODoH** (RFC 9230) |
|---|---|---|---|---|---|---|
| Transport | UDP/TCP 53 | TLS 1.2+/TCP 853 | HTTPS/443 | QUIC/UDP 853 | UDP/TCP 443 or 5443 | HTTPS via a relay |
| Standards track | Yes | Yes | Yes | Yes | **No** — community spec | Experimental |
| Blockable by port | Trivially | **Yes** — port 853 is a giveaway | **No** — indistinguishable from web traffic | Yes | Partly | No |
| Head-of-line blocking | N/A | **Yes** (TCP) | Yes (HTTP/2 over TCP) | **No** (QUIC streams) | No | Depends |
| Connection setup | 0 RTT | 2–3 RTT (1 with TLS 1.3 resumption) | 3+ RTT | **0–1 RTT** | 1 RTT | 2+ RTT |
| Metadata leaked to the resolver | Query + client IP | Query + client IP | Query + client IP + **HTTP headers, User-Agent** | Query + client IP | Query + client IP | Query **or** client IP, never both |
| Server auth | None | Certificate (SPKI pin or PKIX) | Certificate | Certificate | Signed public key from a DNSCrypt stamp | Certificate |
| Enterprise visibility | Full | Blockable, so policy is enforceable | **Bypasses split-horizon and DNS-based policy** | Blockable | Blockable | Bypasses |
| BIND 9.18+ | Yes | **Yes** | **Yes** | 9.19+ (experimental) | No | No |
| Unbound | Yes | Yes | Yes (1.12+) | 1.19+ | No | No |
| `dnsdist` / `dnsdist`-style proxy | Yes | Yes | Yes | Yes | Yes | — |

**The architectural argument you must be able to make:** DoH's use of port 443 is simultaneously its greatest feature (uncensorable) and its greatest operational problem (an application-level DoH client inside a pod or browser **silently bypasses your CoreDNS, your split-horizon zones, your DNS-based egress policy, and your query logging**). In a managed fleet, the correct posture is: run your own DoT/DoH resolver, publish it via `resolvectl`/DHCP/Discovery of Designated Resolvers (RFC 9462), and block or redirect third-party DoH endpoints at the egress — not "ban encryption."

### 9.2 BIND 9.18+ as a DoT/DoH server

Configuration is in §6 above (`tls`, `http`, `listen-on ... tls ... http ...`). Client-side testing:

```
$ dig +tls @10.20.0.53 www.example.net A +dnssec

; <<>> DiG 9.20.4 <<>> +tls @10.20.0.53 www.example.net A +dnssec
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 8823
;; flags: qr rd ra ad; QUERY: 1, ANSWER: 3, AUTHORITY: 0, ADDITIONAL: 1
...
;; SERVER: 10.20.0.53#853(10.20.0.53) (TLS)
```

```
$ dig +https @10.20.0.53 www.example.net A
;; SERVER: 10.20.0.53#443(10.20.0.53) (HTTPS)

$ kdig +tls @9.9.9.9 +tls-hostname=dns.quad9.net +tls-ca www.example.net A
;; TLS session (TLS1.3)-(ECDHE-X25519)-(ECDSA-SECP256R1-SHA256)-(AES-256-GCM)
;; DEBUG: Certificate chain verified.
;; ->>HEADER<<- opcode: QUERY; status: NOERROR; id: 12005
;; Flags: qr rd ra ad; QUERY: 1; ANSWER: 2; AUTHORITY: 0; ADDITIONAL: 1
```

Verify the DoT certificate directly:

```
$ openssl s_client -connect 10.20.0.53:853 -servername dns.example.net \
      -alpn dot </dev/null 2>/dev/null | openssl x509 -noout -subject -dates -ext subjectAltName
subject=CN = dns.example.net
notBefore=Aug  1 00:00:00 2026 GMT
notAfter=Oct 30 23:59:59 2026 GMT
X509v3 Subject Alternative Name:
    DNS:dns.example.net, IP Address:10.20.0.53
```

The `IP Address` SAN matters: DoT clients that are configured with a bare IP (`DNS=10.20.0.53#dns.example.net` in `resolved` uses the name, but many clients do not) will fail name verification without it.

### 9.3 DNSCrypt (awareness)

Pre-dates DoT/DoH; **not an IETF standard**. Uses X25519 + XSalsa20-Poly1305 (or XChaCha20-Poly1305), with the server's public key distributed out of band in a "DNS stamp" (`sdns://…`) rather than via PKIX. Its distinguishing features are **anonymized relays** and **query padding**, and `dnscrypt-proxy` is widely used as a local stub that speaks DNSCrypt/DoH/ODoH upstream and plain Do53 to the host. For the exam: know what it is, that it predates and is independent of DoT/DoH, and that it authenticates the *server* with a pre-shared public key, not a CA.

```
# /etc/dnscrypt-proxy/dnscrypt-proxy.toml  (excerpt)
listen_addresses = ['127.0.0.1:53', '[::1]:53']
server_names = ['quad9-dnscrypt-ip4-filter-pri']
require_dnssec = true
require_nolog  = true
require_nofilter = false
dnscrypt_servers = true
doh_servers = true
odoh_servers = false
```

---

## 10. Verification and failure diagnosis

### 10.1 The triage ladder

Run these in order. Each rung eliminates a class of cause.

```
1.  named-checkconf -z              -- does the config parse and do the zones load?
2.  dig +short SOA @<auth>          -- is the authoritative server answering at all?
3.  dig +dnssec ... | grep flags    -- is the `ad` flag present?
4.  dig +cd                         -- does it work with validation disabled?  <-- the fork
5.  delv +vtrace @<resolver>        -- where exactly in the chain does it break?
6.  dnssec-verify -o <zone> <file>  -- is the signed zone internally consistent?
7.  dig +short DS <zone> @<parent>  -- does the parent's DS match a live DNSKEY?
8.  rndc dnssec -status <zone>      -- what does the key state machine think?
9.  journalctl / dnssec.log         -- what did named actually log?
```

### 10.2 Failure catalogue

| Symptom | Likely cause | Confirming command | Fix |
|---|---|---|---|
| `SERVFAIL` on a whole zone; `+cd` works | Expired `RRSIG` | `dig +dnssec +cd SOA <zone> @<auth>` — compare field 5 (expiration) to `date -u` | Re-sign; fix the cron; alert on expiry |
| `SERVFAIL`; `delv` says `no valid signature found` and `insecure response; parent indicates it should be secure` | `DS` in the parent does not match any published `DNSKEY` | `dig +short DS <zone> @<parent-ns>` vs `dnssec-dsfromkey` output | Publish the correct `DS`, or re-add the matching key |
| `SERVFAIL` only for some resolvers | Multi-signer/anycast inconsistency; one node has stale signed data | `for ns in ...; do dig +norec SOA <zone> @$ns +short; done` | Fix replication; check `also-notify` |
| `delv`: `RRSIG validity period has not begun` | Clock skew on the **validator** | `timedatectl` on the resolver | NTP |
| `RRSIG has expired` but the file was signed 5 min ago | Clock skew on the **signer** (signed with a past expiration) | `timedatectl` on the signer | NTP; re-sign |
| Answers work over TCP but `SERVFAIL`/timeout over UDP | Response > path MTU, fragments dropped | `dig +bufsize=1232 +ignore`, `dig +tcp` | `edns-udp-size 1232`; switch to ECDSA to shrink the `DNSKEY` RRset |
| A validating resolver returns `SERVFAIL` for an **internal** zone | Internal zone unsigned but its parent is signed and has a `DS`, or split-horizon inconsistency | `delv @<resolver> <name>` | `validate-except { "corp.example.net"; };` or a local `trust-anchors static-ds` |
| Resolver logs `no valid DS` for a zone that *is* unsigned | Stale `DS` left in the parent after "un-signing" | `dig +short DS <zone> @<parent>` | Remove the `DS` at the registrar **before** removing signatures |
| Zone transfer refused | Missing `server ... keys {}` on the secondary | `dig AXFR -y ...` from the secondary host | Add the `server` statement |
| TSIG `BADTIME` | Clock skew > `fudge` (300 s) | `dig ... -y ...` and read the TSIG pseudosection | NTP |
| TSIG `BADKEY` | Key name mismatch (names are case-insensitive but must match) | Compare `key "..."` on both ends | Align names |
| TSIG `BADSIG` | Wrong secret, or the secret was re-base64-encoded | `tsig-keygen` output vs deployed secret | Redeploy the secret verbatim |
| NSEC3 zone treated as insecure by BIND 9.16.9+ | `iterations` too high | `dig +short NSEC3PARAM <zone>` | Re-sign with `iterations 0` (RFC 9276) |
| KSK rollover stuck in `rumoured` forever | `parental-agents` unreachable, or `rndc dnssec -checkds` never run | `rndc dnssec -status <zone>` | Fix `parental-agents`; run `-checkds published` |
| DANE fails after a certificate renewal | Key rotated, `3 1 1` SPKI digest changed | `openssl s_client -dane_tlsa_domain ...` | Publish the new `TLSA` **before** deploying; or `rotationPolicy: Never` |
| `resolved` reports `Bogus` for a working zone | `DNSSEC=yes` with an upstream that mangles EDNS | `resolvectl statistics`; `resolvectl show-server-state` | Use a local validating recursor, `DNSSEC=no` in `resolved` |

### 10.3 Reading an `RRSIG` by hand

```
www.example.net. 3600 IN RRSIG A 13 3 3600 20260903120000 20260820120000 51230 example.net. kZ8v...
                               │  │ │  │            │              │        │        │
                               │  │ │  │            │              │        │        └─ signer's name
                               │  │ │  │            │              │        └────────── key tag
                               │  │ │  │            │              └─────────────────── inception (UTC)
                               │  │ │  │            └────────────────────────────────── expiration (UTC)
                               │  │ │  └─────────────────────────────────────────────── original TTL
                               │  │ └────────────────────────────────────────────────── labels (www.example.net = 3)
                               │  └──────────────────────────────────────────────────── algorithm (13)
                               └─────────────────────────────────────────────────────── type covered (A)
```

* **Expiration in the past** ⇒ bogus everywhere. Compare against `date -u +%Y%m%d%H%M%S`.
* **Labels ≠ the real label count** ⇒ the answer came from a wildcard; the validator must additionally prove the exact name does not exist.
* **Key tag** ⇒ must correspond to a key in the published `DNSKEY` RRset with a matching algorithm.
* **Signer's name** ⇒ must be the zone apex, or the answer is out of bailiwick.

A one-liner that turns "is my zone about to break" into a number:

```
$ dig +short +dnssec SOA example.net @192.0.2.1 \
  | awk '$1=="SOA" && NF>6 {print $5}' \
  | while read -r e; do
      exp=$(date -u -d "${e:0:8} ${e:8:2}:${e:10:2}:${e:12:2}" +%s)
      printf 'RRSIG(SOA) expires in %d hours\n' $(( (exp - $(date -u +%s)) / 3600 ))
    done
RRSIG(SOA) expires in 331 hours
```

### 10.4 Monitoring — the part that is not optional

Everything above is reactive. The only thing that reliably prevents a DNSSEC outage is an alert that fires **days** before the signatures expire.

**Prometheus rules:**

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: dnssec-health
  namespace: monitoring
  labels:
    prometheus: platform
    role: alert-rules
spec:
  groups:
    - name: dnssec.rules
      interval: 5m
      rules:
        # ---- Signature expiry: the number-one self-inflicted DNS outage ----
        - alert: DnssecSignatureExpiringSoon
          expr: |
            (dnssec_rrsig_expiry_timestamp_seconds - time()) < 5 * 24 * 3600
          for: 30m
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "RRSIG for {{ $labels.zone }} expires in under 5 days"
            description: >-
              Zone {{ $labels.zone }} on {{ $labels.instance }} has signatures
              expiring at {{ $value | humanizeTimestamp }}. When they expire,
              every validating resolver on the Internet returns SERVFAIL for the
              entire zone. Check the signing service and re-sign.
            runbook_url: "https://runbooks.example.net/dns/rrsig-expiry"

        - alert: DnssecSignatureExpiringCritical
          expr: |
            (dnssec_rrsig_expiry_timestamp_seconds - time()) < 24 * 3600
          for: 5m
          labels:
            severity: critical
            team: platform
          annotations:
            summary: "RRSIG for {{ $labels.zone }} expires in under 24 hours"

        # ---- Chain of trust: DS in the parent must match a live DNSKEY ----
        - alert: DnssecChainOfTrustBroken
          expr: dnssec_chain_valid == 0
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "DNSSEC chain of trust broken for {{ $labels.zone }}"
            description: >-
              The DS record in the parent zone does not match any published
              DNSKEY, or the DNSKEY RRset does not validate. The zone is BOGUS.

        # ---- Validation from the client's point of view ----
        - alert: DnssecValidationFailing
          expr: probe_success{job="blackbox-dns-validated"} == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Validated DNS probe failing for {{ $labels.instance }}"

        # ---- Resolver-side bogus rate: someone else's zone, or ours ----
        - alert: ResolverBogusRateHigh
          expr: |
            rate(bind_resolver_dnssec_validation_errors_total[10m]) > 1
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Elevated DNSSEC validation failures on {{ $labels.instance }}"

        # ---- DANE / TLSA drift after certificate renewal ----
        - alert: DaneTlsaMismatch
          expr: dane_tlsa_match == 0
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "TLSA record does not match the served certificate for {{ $labels.target }}"
            description: >-
              Mail from DANE-enforcing senders is being rejected. Publish the new
              SPKI digest and wait one TLSA TTL before removing the old record.
```

**Blackbox exporter module that actually validates:**

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: blackbox-exporter-config
  namespace: monitoring
data:
  config.yml: |
    modules:
      dns_validated_a:
        prober: dns
        timeout: 5s
        dns:
          transport_protocol: "udp"
          preferred_ip_protocol: "ip4"
          query_name: "www.example.net"
          query_type: "A"
          # dnssec_ok makes the probe request signatures; validate_answer_rrs
          # then asserts an RRSIG is actually present.
          dnssec_ok: true
          valid_rcodes:
            - NOERROR
          validate_answer_rrs:
            fail_if_not_matches_regexp:
              - "www\\.example\\.net\\.\\s+\\d+\\s+IN\\s+RRSIG\\s+A\\s+13\\s+"
          validate_authority_rrs: {}

      dns_tls_853:
        prober: dns
        timeout: 5s
        dns:
          transport_protocol: "tcp"
          query_name: "www.example.net"
          query_type: "A"
```

**A CronJob that measures real signature expiry** (the metric the rules above consume):

```yaml
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: dnssec-expiry-probe
  namespace: monitoring
spec:
  schedule: "*/15 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 300
      template:
        spec:
          restartPolicy: Never
          securityContext:
            runAsNonRoot: true
            runAsUser: 65534
            runAsGroup: 65534
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: probe
              image: internal.registry.example.net/tools/bind-utils:9.20.4
              imagePullPolicy: IfNotPresent
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              resources:
                requests: { cpu: "20m", memory: "32Mi" }
                limits:   { cpu: "200m", memory: "128Mi" }
              env:
                - name: PUSHGATEWAY
                  value: "http://pushgateway.monitoring.svc:9091"
                - name: ZONES
                  value: "example.net 113.0.203.in-addr.arpa"
                - name: AUTH_NS
                  value: "192.0.2.1"
              command: ["/bin/sh", "-eu", "-c"]
              args:
                - |
                  now=$(date -u +%s)
                  out=""
                  for z in $ZONES; do
                    line=$(dig +short +dnssec SOA "$z" "@$AUTH_NS" \
                           | awk '$1=="SOA" && NF>7 {print $5; exit}')
                    if [ -z "$line" ]; then
                      echo "no RRSIG(SOA) for $z" >&2
                      out="${out}dnssec_rrsig_present{zone=\"$z\"} 0\n"
                      continue
                    fi
                    exp=$(date -u -d "${line%??????} ${line#????????}" +%s 2>/dev/null || \
                          date -u -d "$(echo "$line" | sed -E 's/^(.{4})(.{2})(.{2})(.{2})(.{2})(.{2})$/\1-\2-\3 \4:\5:\6/')" +%s)
                    out="${out}dnssec_rrsig_present{zone=\"$z\"} 1\n"
                    out="${out}dnssec_rrsig_expiry_timestamp_seconds{zone=\"$z\"} ${exp}\n"

                    # Chain of trust: does any parent DS match a published DNSKEY?
                    if delv "@$AUTH_NS" "$z" DNSKEY 2>&1 | grep -q '^; fully validated'; then
                      out="${out}dnssec_chain_valid{zone=\"$z\"} 1\n"
                    else
                      out="${out}dnssec_chain_valid{zone=\"$z\"} 0\n"
                    fi
                    echo "zone=$z expiry=$exp remaining_h=$(( (exp - now) / 3600 ))"
                  done
                  printf "%b" "$out" | \
                    curl --fail --silent --show-error --data-binary @- \
                      "${PUSHGATEWAY}/metrics/job/dnssec_expiry_probe"
```

**Systemd timer equivalent, for hosts outside a cluster:**

```ini
# /etc/systemd/system/dnssec-expiry-check.service
[Unit]
Description=Check DNSSEC signature expiry for locally served zones
After=network-online.target named.service
Wants=network-online.target

[Service]
Type=oneshot
User=nobody
Group=nogroup
ExecStart=/usr/local/sbin/dnssec-expiry-check.sh
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
NoNewPrivileges=yes
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_INET6
```

```ini
# /etc/systemd/system/dnssec-expiry-check.timer
[Unit]
Description=Run the DNSSEC expiry check every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
```

**External validation you should also run** — because your own monitoring shares failure modes with your own servers:

* **Zonemaster** (`https://zonemaster.net`) and the `zonemaster-cli` package.
* **DNSViz** (`https://dnsviz.net`) — renders the entire chain of trust graphically and is the fastest way to see *where* a chain broke.
* **Verisign DNSSEC Analyzer** (`https://dnssec-analyzer.verisignlabs.com`).
* **Internet.nl** — checks DNSSEC, DANE, and mail security together.

---

## 11. Production checklist

**Before signing a zone for the first time**

- [ ] Every TTL in the zone is ≤ the policy's `max-zone-ttl`, and all records in each RRset share a TTL.
- [ ] NTP is running and healthy on every authoritative server and every signer.
- [ ] `edns-udp-size 1232` on authoritatives and recursors.
- [ ] Algorithm 13 (ECDSAP256SHA256) unless a written policy says otherwise.
- [ ] `nsec3param iterations 0 optout no salt-length 0`, or plain NSEC.
- [ ] Key directory and `managed-keys-directory` are `0700`, owned by the `named` user, and **in the backup set** — including `.state` files.
- [ ] `dnssec-verify` passes before the zone is served.
- [ ] Expiry monitoring exists and has been tested by forcing an alert.

**Before submitting the DS to the registrar**

- [ ] The `DNSKEY` RRset validates on **every** authoritative server (`dig +norec` each one).
- [ ] `dnssec-dsfromkey` output matches the published `CDS`.
- [ ] SHA-256 digest type (2), not SHA-1.
- [ ] You know the parent's `DS` TTL and it matches `parent-ds-ttl` in the policy.

**Before renewing a certificate that has a `TLSA` record**

- [ ] New `TLSA` published **first**; waited ≥ TTL.
- [ ] Key reuse (`rotationPolicy: Never`) if the record is `3 1 1` and you do not want a rollover.
- [ ] `openssl s_client -dane_tlsa_domain` verified against the **new** record before removing the old.

**Never**

- [ ] Never add a Negative Trust Anchor for a zone you operate.
- [ ] Never set `DNSSEC=allow-downgrade`.
- [ ] Never grant `allow-update { key "x"; }` when `update-policy` can scope it.
- [ ] Never remove signatures from a zone whose `DS` is still in the parent.
- [ ] Never compress the rollover waits to "make it go faster."

---

## 12. Command reference

| Tool | Purpose | Canonical invocation |
|---|---|---|
| `named-checkconf` | Validate `named.conf` (and zones with `-z`) | `named-checkconf -z /etc/bind/named.conf` |
| `named-checkzone` | Validate a zone file | `named-checkzone -D -o example.net example.net db.example.net.signed` |
| `dnssec-keygen` | Generate DNSSEC / TSIG keys | `dnssec-keygen -a ECDSAP256SHA256 -f KSK -n ZONE example.net` |
| `dnssec-keyfromlabel` | Create a key handle for an HSM object | `dnssec-keyfromlabel -E pkcs11 -a ECDSAP256SHA256 -f KSK -l "..." example.net` |
| `dnssec-settime` | Read/modify key timing metadata | `dnssec-settime -p all Kexample.net.+013+51230` |
| `dnssec-signzone` | Sign a zone offline | `dnssec-signzone -S -x -A -3 - -H 0 -N INCREMENT -o example.net db.example.net` |
| `dnssec-verify` | Verify a signed zone file | `dnssec-verify -o example.net db.example.net.signed` |
| `dnssec-dsfromkey` | Derive a `DS` from a `DNSKEY` | `dnssec-dsfromkey -a SHA-256 Kexample.net.+013+34505.key` |
| `dnssec-cds` | Update a parent's `DS` from a child's `CDS` | `dnssec-cds -s /var/lib/bind/zones -f db.parent -d /var/lib/bind/zones example.net` |
| `dnssec-importkey` | Import an external public key | `dnssec-importkey -f pubkey.txt example.net` |
| `tsig-keygen` | Generate a TSIG key block | `tsig-keygen -a hmac-sha256 xfr-key` |
| `rndc` | Control channel | `rndc dnssec -status example.net`, `rndc nta -d 3600 zone`, `rndc managed-keys status`, `rndc sign zone`, `rndc loadkeys zone` |
| `dig` | Query and inspect | `dig +dnssec +multi`, `+cd`, `+tls`, `+https`, `-y`, `-k`, `+trace`, `+nsid`, `+bufsize=1232` |
| `delv` | **Client-side** DNSSEC validation | `delv +vtrace @resolver name TYPE` |
| `nsupdate` | RFC 2136 dynamic update | `nsupdate -k Kacme.+165+42817.key -v` |
| `danetool` | GnuTLS DANE helper | `danetool --check host --port 25 --starttls-proto smtp` |
| `openssl` | TLSA generation and DANE verification | `openssl x509 -noout -pubkey`, `openssl s_client -dane_tlsa_domain ... -dane_tlsa_rrdata ...` |
| `resolvectl` | systemd-resolved control | `resolvectl status`, `query`, `statistics`, `flush-caches`, `show-server-state` |
| `kdig` | Knot's `dig` — best DoT/DoQ client | `kdig +tls @host +tls-hostname=... name` |

---

## Referencias

**Certification objectives**

- LPI — Exam 303 Objectives (303-300, v3.0): https://www.lpi.org/our-certifications/exam-303-objectives/
- LPI — LPIC-3 Security certification overview: https://www.lpi.org/our-certifications/lpic-3-security-overview/

**DNSSEC — core specifications**

- RFC 4033 — DNS Security Introduction and Requirements: https://www.rfc-editor.org/rfc/rfc4033
- RFC 4034 — Resource Records for the DNS Security Extensions: https://www.rfc-editor.org/rfc/rfc4034
- RFC 4035 — Protocol Modifications for the DNS Security Extensions: https://www.rfc-editor.org/rfc/rfc4035
- RFC 5155 — DNSSEC Hashed Authenticated Denial of Existence (NSEC3): https://www.rfc-editor.org/rfc/rfc5155
- RFC 6840 — Clarifications and Implementation Notes for DNSSEC: https://www.rfc-editor.org/rfc/rfc6840
- RFC 8624 — Algorithm Implementation Requirements and Usage Guidance for DNSSEC: https://www.rfc-editor.org/rfc/rfc8624
- RFC 9276 — Guidance for NSEC3 Parameter Settings: https://www.rfc-editor.org/rfc/rfc9276
- RFC 8198 — Aggressive Use of DNSSEC-Validated Cache: https://www.rfc-editor.org/rfc/rfc8198
- RFC 6605 — Elliptic Curve DSA for DNSSEC: https://www.rfc-editor.org/rfc/rfc6605
- RFC 8080 — Edwards-Curve DSA for DNSSEC: https://www.rfc-editor.org/rfc/rfc8080

**Key management and rollover**

- RFC 5011 — Automated Updates of DNS Security Trust Anchors: https://www.rfc-editor.org/rfc/rfc5011
- RFC 6781 — DNSSEC Operational Practices, Version 2: https://www.rfc-editor.org/rfc/rfc6781
- RFC 7344 — Automating DNSSEC Delegation Trust Maintenance (CDS/CDNSKEY): https://www.rfc-editor.org/rfc/rfc7344
- RFC 8078 — Managing DS Records from the Parent via CDS/CDNSKEY: https://www.rfc-editor.org/rfc/rfc8078
- RFC 8901 — Multi-Signer DNSSEC Models: https://www.rfc-editor.org/rfc/rfc8901
- IANA — DNSSEC Root Trust Anchors: https://www.iana.org/dnssec/files
- IANA — Root Zone KSK Rollover information: https://www.iana.org/dnssec/ceremonies

**Transaction security**

- RFC 8945 — Secret Key Transaction Authentication for DNS (TSIG): https://www.rfc-editor.org/rfc/rfc8945
- RFC 2931 — DNS Request and Transaction Signatures (SIG(0)): https://www.rfc-editor.org/rfc/rfc2931
- RFC 3645 — GSS Algorithm for TSIG (GSS-TSIG): https://www.rfc-editor.org/rfc/rfc3645
- RFC 2136 — Dynamic Updates in the Domain Name System: https://www.rfc-editor.org/rfc/rfc2136
- RFC 9103 — DNS Zone Transfer over TLS (XoT): https://www.rfc-editor.org/rfc/rfc9103

**DANE**

- RFC 6698 — The DNS-Based Authentication of Named Entities (DANE) Protocol for TLS: https://www.rfc-editor.org/rfc/rfc6698
- RFC 7671 — DANE Protocol: Updates and Operational Guidance: https://www.rfc-editor.org/rfc/rfc7671
- RFC 7672 — SMTP Security via Opportunistic DANE TLS: https://www.rfc-editor.org/rfc/rfc7672
- RFC 7673 — Using DANE TLSA Records with SRV Records: https://www.rfc-editor.org/rfc/rfc7673
- RFC 8461 — SMTP MTA Strict Transport Security (MTA-STS): https://www.rfc-editor.org/rfc/rfc8461
- RFC 8460 — SMTP TLS Reporting: https://www.rfc-editor.org/rfc/rfc8460
- Postfix — TLS Readme (DANE section): https://www.postfix.org/TLS_README.html#client_tls_dane

**Encrypted transports**

- RFC 7858 — Specification for DNS over Transport Layer Security (DoT): https://www.rfc-editor.org/rfc/rfc7858
- RFC 8310 — Usage Profiles for DNS over TLS and DTLS: https://www.rfc-editor.org/rfc/rfc8310
- RFC 8484 — DNS Queries over HTTPS (DoH): https://www.rfc-editor.org/rfc/rfc8484
- RFC 9250 — DNS over Dedicated QUIC Connections (DoQ): https://www.rfc-editor.org/rfc/rfc9250
- RFC 9230 — Oblivious DNS over HTTPS (ODoH): https://www.rfc-editor.org/rfc/rfc9230
- RFC 9462 — Discovery of Designated Resolvers: https://www.rfc-editor.org/rfc/rfc9462
- DNSCrypt — protocol specification: https://dnscrypt.info/protocol/
- `dnscrypt-proxy` documentation: https://github.com/DNSCrypt/dnscrypt-proxy/wiki

**Operational hardening**

- RFC 9156 — DNS Query Name Minimisation to Improve Privacy: https://www.rfc-editor.org/rfc/rfc9156
- RFC 8900 — IP Fragmentation Considered Fragile: https://www.rfc-editor.org/rfc/rfc8900
- RFC 8976 — Message Digest for DNS Zones (ZONEMD): https://www.rfc-editor.org/rfc/rfc8976
- RFC 9432 — DNS Catalog Zones: https://www.rfc-editor.org/rfc/rfc9432
- DNS Flag Day 2020 — EDNS buffer size: https://dnsflagday.net/2020/

**Implementation documentation**

- ISC — BIND 9 Administrator Reference Manual: https://bind9.readthedocs.io/en/latest/
- ISC — DNSSEC Guide: https://bind9.readthedocs.io/en/latest/dnssec-guide.html
- ISC — `dnssec-policy` reference: https://bind9.readthedocs.io/en/latest/reference.html#dnssec-policy-grammar
- ISC — `rndc` manual page: https://bind9.readthedocs.io/en/latest/manpages.html#rndc-name-server-control-utility
- NLnet Labs — Unbound documentation: https://unbound.docs.nlnetlabs.nl/
- NLnet Labs — DNSSEC key rollover guidance: https://nlnetlabs.nl/documentation/
- CZ.NIC — Knot DNS documentation: https://www.knot-dns.cz/documentation/
- freedesktop.org — `systemd-resolved` manual: https://www.freedesktop.org/software/systemd/man/latest/systemd-resolved.service.html
- freedesktop.org — `resolved.conf` manual: https://www.freedesktop.org/software/systemd/man/latest/resolved.conf.html
- OpenSSL — `s_client` manual (DANE options): https://docs.openssl.org/master/man1/openssl-s_client/
- cert-manager — RFC 2136 (TSIG) DNS-01 solver: https://cert-manager.io/docs/configuration/acme/dns01/rfc2136/

**Diagnostic services**

- DNSViz — visual analysis of DNSSEC chains: https://dnsviz.net/
- Verisign Labs — DNSSEC Debugger: https://dnssec-analyzer.verisignlabs.com/
- Zonemaster — DNS delegation and DNSSEC testing: https://zonemaster.net/
- Internet.nl — DNSSEC, DANE and mail security tests: https://internet.nl/
- ICANN — DNSSEC deployment statistics: https://stats.dnssec-tools.org/
- APNIC Labs — DNSSEC validation measurement: https://stats.labs.apnic.net/dnssec