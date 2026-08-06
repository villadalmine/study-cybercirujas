# LPIC-2 (Exam 201-450 / 202-450 v4.5) - Topic 2.1: Domain Name Server

**Topic Weight:** 8  
**Target Level:** Senior SRE / Principal Platform Architect  

---

## 1. Architectural Problem & Production Motivation

In enterprise platform engineering, Domain Name System (DNS) infrastructure is the fundamental routing plane for network service discovery, traffic management, and security boundary enforcement. A naïve or default DNS deployment introduces major systemic vulnerabilities:

1. **DNS Cache Poisoning & Man-in-the-Middle (MitM) Attacks:** Without cryptographic verification (DNSSEC), attackers can forge recursive cache responses via transaction ID predicting or UDP spoofing (Kaminsky-style attacks), diverting internal microservice traffic to rogue endpoints.
2. **Zone Data Exfiltration & Unauthorized Transfer:** Exposing internal topology metadata via unauthenticated zone transfers (`AXFR`/`IXFR`) allows adversaries to map internal RFC 1918/4193 network endpoints.
3. **Monolithic Architecture Flaws:** Combining public recursive resolution with internal authoritative hosting on a single instance creates a single point of failure (SPOF) vulnerable to Distributed Denial of Service (DDoS) reflection attacks.
4. **Split-Brain Horizon Discrepancies:** Internal workloads requiring private IP resolution (`10.0.0.0/8`) must be strictly segregated from public requests attempting to resolve the same domain namespace to public edge ingress IPs (`198.51.100.0/24`).

### Production Architecture Blueprint

```
                         +-----------------------------------+
                         |       Internet DNS Clients        |
                         +-----------------------------------+
                                           |
                                           v
                         +-----------------------------------+
                         |      External Anycast VIP         |
                         |        (198.51.100.53)            |
                         +-----------------------------------+
                                           |
                   +-----------------------+-----------------------+
                   |                                               |
                   v                                               v
     +---------------------------+                   +---------------------------+
     | BIND Authoritative Master |== TSIG (AXFR/IXFR)==> BIND Authoritative Slave  |
     |   View: "external-view"   |   Over TLS/TCP    |   View: "external-view"   |
     +---------------------------+                   +---------------------------+
                   |                                               |
                   +-----------------------+-----------------------+
                                           |
===========================================|===========================================
  Internal Network Boundary (VPC / DMZ)    |
===========================================|===========================================
                                           v
                         +-----------------------------------+
                         |      Internal Recursive VIP       |
                         |         (10.50.0.53)              |
                         +-----------------------------------+
                                           |
                   +-----------------------+-----------------------+
                   |                                               |
                   v                                               v
     +---------------------------+                   +---------------------------+
     | BIND Internal Resolver    |                   | BIND Authoritative Internal|
     |  View: "internal-view"    |                   |   View: "internal-view"   |
     |  DNSSEC Validation: Yes   |                   |   Zone: corp.internal     |
     +---------------------------+                   +---------------------------+
```

---

## 2. Technical Comparisons & Architecture Trade-off Tables

### 2.1 Authoritative vs. Recursive / Caching DNS Engine Comparison

| Dimension | BIND 9 (`named`) | Unbound | PowerDNS (Authoritative / Recursor) | Knot DNS |
| :--- | :--- | :--- | :--- | :--- |
| **Primary Role** | Hybrid (Authoritative + Recursive via Views) | Dedicated Caching / Recursive | Separated (PDNS Auth + PDNS Recursor) | Dedicated High-Performance Authoritative |
| **Backend Storage** | In-Memory (Zone Files), DLZ (Database) | In-Memory | Relational DB (MySQL, Postgres), LMDB, BIND files | In-Memory, LMDB |
| **DNSSEC Support** | Built-in Auto-signing (`dnssec-policy`), Key Management | Validation-focused | Native Auto-signing, PKCS#11 | Automatic On-the-fly Signing |
| **Memory Footprint** | Moderate to High (due to rich feature set) | Low / Optimized Caching | Low (Recursor), Variable (Auth DB dependent) | Extremely Low / Memory-efficient |
| **Use-Case Fit** | Enterprise Enterprise Split-Horizon, Legacy Compliance | Edge Recursive Resolvers, K8s DNS Forwarders | Massive Scale ISP / Telco DB-driven Auth | High-Throughput TLD / Core Auth Infrastructure |

### 2.2 Zone Transfer Mechanisms: AXFR vs. IXFR

| Feature | Full Zone Transfer (`AXFR`) | Incremental Zone Transfer (`IXFR`) |
| :--- | :--- | :--- |
| **Protocol Mechanics** | Transfers the complete DNS zone contents from primary to secondary. | Transfers only records modified between the Secondary's current SOA serial and Primary's latest SOA serial. |
| **Bandwidth Consumption** | High ($O(N)$ where $N$ = total RRsets in zone). | Minimal ($O(\Delta)$ proportional to delta changes). |
| **Server Overhead** | High disk I/O & memory payload serialization per transfer. | Requires Primary to maintain change journal (`.jnl` files). |
| **Failure Recovery** | Fallback mode if `IXFR` gap sequence is broken or journal missing. | Fails back automatically to `AXFR` if serial history is out of bounds. |
| **Security Layer** | Must be enforced via TSIG (Transaction Signature, RFC 2845). | Must be enforced via TSIG (Transaction Signature, RFC 2845). |

### 2.3 DNSSEC Operational Trade-offs

| Factor | Unsigned Zone | DNSSEC Signed Zone |
| :--- | :--- | :--- |
| **Packet Size Impact** | Small (~512 bytes UDP payload limits). | Large (1024-4096 bytes, triggers EDNS0 requirement & TCP fallback). |
| **Amplification Vulnerability** | Low amplification factor (~1:2 to 1:5). | High amplification factor (~1:20 to 1:50). Requires RRL (Response Rate Limiting). |
| **CPU Overhead** | Minimal (Lookup & Static Cache read). | High during signature generation (`RRSIG`) and cryptographic validation. |
| **Key Lifecycle Risk** | None. | High operational burden: KSK/ZSK key rollover management, DS record parent updates. |

---

## 3. Production-Grade Configuration Manifests

### 3.1 Hardened `/etc/bind/named.conf` Infrastructure Configuration

```named
// Production BIND 9 Configuration Manifest (/etc/bind/named.conf)
// Environment: Hardened Split-Horizon Authoritative & Recursive Cluster

include "/etc/bind/rndc.key";
include "/etc/bind/keys/transfer-keys.conf";

// Access Control Lists (ACLs)
acl "internal-networks" {
    127.0.0.1/32;
    ::1/128;
    10.50.0.0/16;
    172.16.0.0/12;
};

acl "secondary-slaves" {
    192.0.2.53/32;   // Primary Secondary IP
    198.51.100.53/32;// Secondary Slave IP
};

acl "monitoring-hosts" {
    10.50.10.15/32;
};

// Global Daemon Options
options {
    directory "/var/cache/bind";
    managed-keys-directory "/var/lib/bind";
    dump-file "/var/log/bind/named_dump.db";
    stats-file "/var/log/bind/named.stats";
    memstats-file "/var/log/bind/named.memstats";

    // Listener Interfaces
    listen-on port 53 { 127.0.0.1; 10.50.0.53; 198.51.100.10; };
    listen-on-v6 port 53 { ::1; 2001:db8:50::53; };

    // Protocol Security & Hide Version
    version "NOT DISCLOSED";
    server-id "dns-node-01.infra.prod.example.com";
    hostname none;

    // DNSSEC Engine Controls
    dnssec-validation auto;
    auth-nxdomain no;    // conform to RFC1035

    // EDNS0 Buffer Sizes & Amplification Defense
    edns-udp-size 1232;
    max-udp-size 1232;

    // Response Rate Limiting (RRL) to Mitigate Amplification DDoS
    rate-limit {
        responses-per-second 15;
        referrals-per-second 5;
        nodata-per-second 5;
        nxdomains-per-second 5;
        error-per-second 5;
        all-per-second 20;
        window 5;
        ipv4-prefix-length 24;
        ipv6-prefix-length 56;
        slip 2;
    };

    // Global Transfer & Query Defaults (Strict Lockdown)
    allow-query { none; };
    allow-recursion { none; };
    allow-transfer { none; };
    allow-update { none; };

    // Performance Tuning
    threads 8;
    max-cache-size 2G;
    minimal-responses yes;
};

// Centralized Logging Architecture
logging {
    channel "default_syslog" {
        syslog daemon;
        severity info;
    };

    channel "security_file" {
        file "/var/log/bind/security.log" versions 10 size 50m;
        severity info;
        print-time yes;
        print-category yes;
        print-severity yes;
    };

    channel "dnssec_file" {
        file "/var/log/bind/dnssec.log" versions 5 size 20m;
        severity debug 3;
        print-time yes;
        print-category yes;
    };

    channel "query_file" {
        file "/var/log/bind/queries.log" versions 5 size 100m;
        severity info;
        print-time yes;
    };

    category default { default_syslog; };
    category general { default_syslog; };
    category security { security_file; default_syslog; };
    category config { default_syslog; };
    category resolver { security_file; };
    category xfer-in { security_file; };
    category xfer-out { security_file; };
    category dnssec { dnssec_file; };
    category queries { query_file; };
};

// RNDC Control Interface
controls {
    inet 127.0.0.1 port 953
    allow { 127.0.0.1; } keys { "rndc-key"; };
};

// Automated Cryptographic Key Management Configuration for Transfers
// File: /etc/bind/keys/transfer-keys.conf
/*
key "sec-transfer-key" {
    algorithm hmac-sha256;
    secret "C+4o9P0mGZ5h7R1lK+u8vW9X2Y3z4A5B6C7D8E9F0gH=";
};
*/

// Modern DNSSEC Automated Rollover Policy Definition
dnssec-policy "production-policy" {
    keys {
        ksk lifetime unlimited algorithm rsasha256 2048;
        zsk lifetime 60 days algorithm rsasha256 1024;
    };
    nsec3param iterations 1 optout no salt-length 16;
    signatures-refresh 5d;
    signatures-validity 14d;
    signatures-validity-dnskey 14d;
};

// SPLIT-HORIZON VIEW 1: INTERNAL
view "internal-view" {
    match-clients { "internal-networks"; };
    recursion yes;
    allow-query { "internal-networks"; };
    allow-recursion { "internal-networks"; };

    zone "." IN {
        type hint;
        file "/usr/share/dns/root.hints";
    };

    // Internal Authoritative Forward Zone
    zone "prod.example.com" IN {
        type primary;
        file "/var/lib/bind/internal/db.prod.example.com";
        allow-transfer { key "sec-transfer-key"; };
        notify yes;
        also-notify { 10.50.0.54; };
    };

    // Internal Reverse Zone IPv4 (10.50.0.0/16)
    zone "50.10.in-addr.arpa" IN {
        type primary;
        file "/var/lib/bind/internal/db.10.50";
        allow-transfer { key "sec-transfer-key"; };
    };
};

// SPLIT-HORIZON VIEW 2: EXTERNAL
view "external-view" {
    match-clients { any; };
    recursion no;
    allow-query { any; };

    // Public Authoritative Zone with Inline DNSSEC Signing
    zone "example.com" IN {
        type primary;
        file "/var/lib/bind/external/db.example.com";
        dnssec-policy "production-policy";
        inline-signing yes;
        allow-transfer { "secondary-slaves"; key "sec-transfer-key"; };
        notify yes;
        also-notify { 198.51.100.53; };
    };

    // Public Reverse Zone IPv4 (198.51.100.0/24)
    zone "100.51.198.in-addr.arpa" IN {
        type primary;
        file "/var/lib/bind/external/db.198.51.100";
        allow-transfer { key "sec-transfer-key"; };
    };
};
```

---

### 3.2 Standard Production Zone File: `db.example.com` (External Zone)

```zone
$TTL 86400
@   IN  SOA ns1.example.com. hostmaster.example.com. (
            2026080601 ; Serial YYYYMMDDver
            10800      ; Refresh (3 hours)
            3600       ; Retry (1 hour)
            1209600    ; Expire (2 weeks)
            3600       ; Minimum TTL (1 hour)
)

; Authoritative Nameservers
@           IN  NS      ns1.example.com.
@           IN  NS      ns2.example.com.

; Glue Records
ns1         IN  A       198.51.100.10
ns1         IN  AAAA    2001:db8:50::10
ns2         IN  A       198.51.100.53
ns2         IN  AAAA    2001:db8:50::53

; Ingress Gateways & Services
@           IN  A       198.51.100.100
@           IN  AAAA    2001:db8:50::100
api         IN  A       198.51.100.101
k8s-ingress IN  A       198.51.100.102

; Canonical Name Aliases
www         IN  CNAME   @
app         IN  CNAME   api.example.com.

; Mail Exchange Infrastructure
@           IN  MX  10  mail1.example.com.
@           IN  MX  20  mail2.example.com.
mail1       IN  A       198.51.100.25
mail2       IN  A       198.51.100.26

; Security Records: SPF, DMARC, DKIM
@           IN  TXT     "v=spf1 ip4:198.51.100.25 ip4:198.51.100.26 -all"
_dmarc      IN  TXT     "v=DMARC1; p=reject; rua=mailto:dmarc-reports@example.com; pct=100"
k1._domainkey IN TXT    ( "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAz"
                          "Y9C3h1n..." )

; Service Discovery (SRV) for SIP Service
_sip._tcp   IN  SRV 10 60 5060 sipserver.example.com.
sipserver   IN  A       198.51.100.200

; DANE TLSA Record for HTTPS
_443._tcp.www IN TLSA   3 1 1 0c72ac70b745ac19998811b131d662c9ac698d8b858f432b8d5855feb739265f
```

---

### 3.3 Reverse Mapping Zone File: `db.198.51.100`

```zone
$TTL 86400
@   IN  SOA ns1.example.com. hostmaster.example.com. (
            2026080601 ; Serial
            10800      ; Refresh
            3600       ; Retry
            1209600    ; Expire
            3600       ; Minimum TTL
)

; Nameserver Delegation
@           IN  NS      ns1.example.com.
@           IN  NS      ns2.example.com.

; PTR Records (Mapping Host Octet to FQDN)
10          IN  PTR     ns1.example.com.
53          IN  PTR     ns2.example.com.
25          IN  PTR     mail1.example.com.
26          IN  PTR     mail2.example.com.
100         IN  PTR     example.com.
101         IN  PTR     api.example.com.
102         IN  PTR     k8s-ingress.example.com.
```

---

### 3.4 Systemd Hardened Unit Override (`/etc/systemd/system/named.service.d/override.conf`)

```ini
[Unit]
Description=BIND Open Source DNS Server (Production Hardened Chroot)
After=network.target

[Service]
EnvironmentFile=-/etc/default/named
ExecStart=
ExecStart=/usr/sbin/named -f -u bind -t /var/bind/chroot -c /etc/bind/named.conf
ExecReload=/usr/sbin/rndc reload
ExecStop=/usr/sbin/rndc stop

# Process Sandboxing & Capabilities
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=/
ReadWritePaths=/var/bind/chroot/var/cache/bind /var/bind/chroot/var/lib/bind /var/bind/chroot/var/log/bind /var/bind/chroot/run/named
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_SETGID CAP_SETUID CAP_SYS_CHROOT
NoNewPrivileges=true
```

---

## 4. Real CLI Commands & Terminal Outputs ($)

### 4.1 Generating TSIG Keys with `tsig-keygen`

```bash
$ tsig-keygen -a hmac-sha256 sec-transfer-key
```

**Output:**
```named
key "sec-transfer-key" {
	algorithm hmac-sha256;
	secret "J3eK9+a81N7L0/VwQ2xP4mR6tY8uI0oO1pP2qR3sT4u=";
};
```

---

### 4.2 Validating BIND Configurations & Zone Files

#### Validating Configuration Syntax (`named-checkconf`)

```bash
$ named-checkconf -z -t /var/bind/chroot /etc/bind/named.conf
```

**Output:**
```text
zone prod.example.com/IN (internal-view): loaded serial 2026080601
zone 50.10.in-addr.arpa/IN (internal-view): loaded serial 2026080601
zone example.com/IN (external-view): loaded serial 2026080601
zone 100.51.198.in-addr.arpa/IN (external-view): loaded serial 2026080601
```

#### Validating Zone File Integrity (`named-checkzone`)

```bash
$ named-checkzone -m -M -v example.com /var/lib/bind/external/db.example.com
```

**Output:**
```text
loading "example.com" from "/var/lib/bind/external/db.example.com" class "IN"
zone example.com/IN: loaded serial 2026080601
OK
```

---

### 4.3 Runtime Administration via `rndc`

#### Checking Server Status

```bash
$ rndc status
```

**Output:**
```text
version: BIND 9.18.28-1~deb12u1-Debian (Extended Support Version) <id:0b4f8c9>
running on dns-node-01: Linux x86_64 6.1.0-21-amd64 #1 SMP PREEMPT_DYNAMIC Debian 6.1.90-1
boot time: Thu, 06 Aug 2026 08:00:00 GMT
last configured: Thu, 06 Aug 2026 08:15:22 GMT
configuration file: /etc/bind/named.conf
CPUs found: 8
worker threads: 8
UDP listeners per interface: 8
number of zones: 4 (0 automatic)
debug level: 0
xfers running: 0
xfers deferred: 0
soa queries in progress: 0
query logging is ON
recursive clients: 0/1000/10000
tcp clients: 4/1500
server is up and running
```

#### Triggering Dynamic Zone Retransfer & Cache Flush

```bash
$ rndc retransfer example.com IN external-view
```

**Output:**
```text
zone transfer queued for 'example.com/IN' in view 'external-view'
```

```bash
$ rndc flushname api.example.com
```

**Output:**
```text
flushing 'api.example.com' succeeded
```

---

### 4.4 Advanced Verification with `dig`

#### Performing Full Recursive Resolution Trace with DNSSEC (`dig +trace`)

```bash
$ dig @127.0.0.1 example.com A +trace +dnssec +multiline
```

**Output:**
```text
; <<>> DiG 9.18.28-1~deb12u1-Debian <<>> @127.0.0.1 example.com A +trace +dnssec +multiline
;; global options: +cmd
.			518400 IN SOA a.root-servers.net. nstld.verisign-grs.com. (
				2026080600 ; serial
				1800       ; refresh
				900        ; retry
				604800     ; expire
				86400      ; minimum
				)
.			518400 IN RRSIG SOA 8 0 518400 20260816000000 20260805230000 30899 . (
				u8n+56K41L... )
;; RECEIVED 525 BYTES FROM 127.0.0.1#53(127.0.0.1) IN 1 ms

com.			172800 IN NS a.gtld-servers.net.
com.			172800 IN DS 19718 8 2 8AC5BCD622D7010285477FA400DB12B4D0B5300C
com.			172800 IN RRSIG DS 8 1 172800 20260813050000 20260806040000 30899 . (
				H7zLp19... )
;; RECEIVED 1170 BYTES FROM 198.41.0.4#53(a.root-servers.net) IN 14 ms

example.com.		172800 IN NS ns1.example.com.
example.com.		172800 IN NS ns2.example.com.
example.com.		172800 IN DS 41235 13 2 B691E885B7A757FA9C9D71C80411200E4A102A19
example.com.		172800 IN RRSIG DS 8 2 172800 20260812112211 20260805102211 58933 com. (
				O8mK2... )
;; RECEIVED 380 BYTES FROM 192.5.6.30#53(a.gtld-servers.net) IN 22 ms

example.com.		86400 IN A 198.51.100.100
example.com.		86400 IN RRSIG A 13 2 86400 20260820100000 20260806080000 41235 example.com. (
				V9zN8uP0m... )
;; RECEIVED 215 BYTES FROM 198.51.100.10#53(ns1.example.com) IN 2 ms
```

#### Authenticated TSIG Authenticated Zone Transfer Request (`AXFR`)

```bash
$ dig @10.50.0.53 prod.example.com AXFR -y hmac-sha256:sec-transfer-key:C+4o9P0mGZ5h7R1lK+u8vW9X2Y3z4A5B6C7D8E9F0gH=
```

**Output:**
```text
; <<>> DiG 9.18.28-1~deb12u1-Debian <<>> @10.50.0.53 prod.example.com AXFR -y hmac-sha256:sec-transfer-key:...
;; global options: +cmd
prod.example.com.	86400 IN SOA ns1.prod.example.com. hostmaster.prod.example.com. 2026080601 10800 3600 1209600 3600
prod.example.com.	86400 IN NS ns1.prod.example.com.
ns1.prod.example.com.	86400 IN A 10.50.0.53
db1.prod.example.com.	3600 IN A 10.50.10.20
k8s.prod.example.com.	3600 IN A 10.50.20.100
prod.example.com.	86400 IN SOA ns1.prod.example.com. hostmaster.prod.example.com. 2026080601 10800 3600 1209600 3600
;; Query time: 3 msec
;; SERVER: 10.50.0.53#53(10.50.0.53) (TCP)
;; WHEN: Thu Aug 06 10:30:00 EDT 2026
;; XFR size: 6 records (messages 1, bytes 342)
;; TSIG record verified successfully.
```

---

## 5. Verification & Troubleshooting Guide

```
                      [ Diagnostic Decision Tree ]
                                  |
                   Does `named-checkconf` pass?
                   /                          \
                 No                            Yes
                 /                              \
    [ Fix Syntax Error in ]            Can client query port 53?
    [    named.conf       ]            /                       \
                                      No                        Yes
                                     /                            \
                        [ Check Firewall / UDP ]        Is response `SERVFAIL`?
                        [ Listen-on Interface  ]        /                     \
                                                       Yes                    No
                                                       /                        \
                                             [ Test DNSSEC Trust ]       Is query routing
                                             [ Anchor / Clock    ]       to wrong View?
                                             [ Synchronization   ]              |
                                                                        [ Check ACLs & ]
                                                                        [ match-clients]
```

### 5.1 Common Production Failures & Solutions

#### Failure Scenario 1: Zone Transfer Denied (`NOTAUTH` or `REFUSED`)

* **Symptom:** Secondary DNS logs `transfer of 'example.com/IN' from 10.50.0.53#53: failed while receiving responses: REFUSED`.
* **Root Cause Analysis:** TSIG key name/secret mismatch or missing `allow-transfer` entry in Primary server's zone block.
* **Diagnostic Procedure:**
  1. Inspect primary daemon logs: `journalctl -u named -g "transfer.*denied"`
  2. Verify system clock delta between Primary and Secondary (TSIG rejects packets with skew > 300s):
     ```bash
     $ chronyc tracking
     ```
  3. Force explicit TSIG verification with `dig`:
     ```bash
     $ dig @10.50.0.53 example.com SOA -y hmac-sha256:sec-transfer-key:SECRET
     ```
* **Remediation:** Align TSIG configuration in `/etc/bind/keys/transfer-keys.conf` across both instances and ensure clock synchronization via NTP/Chrony.

---

#### Failure Scenario 2: DNSSEC Validation Breakage (`SERVFAIL`)

* **Symptom:** Resolvers return `SERVFAIL` for valid signed zone; `dig +cd` (Checking Disabled) succeeds and returns data.
* **Root Cause Analysis:** Expired `RRSIG` record signatures or system NTP clock drift causing current time to fall outside `[RRSIG inception, RRSIG expiration]`.
* **Diagnostic Procedure:**
  1. Use `delv` to trace cryptographic chain of trust:
     ```bash
     $ delv @127.0.0.1 example.com A +rtrace
     ```
  2. Inspect output for signature validation bounds error:
     ```text
     ;; RRSIG (example.com/A) has expired (inception 20260701, expiration 20260801, current 20260806)
     ```
* **Remediation:** Re-sign the zone manually or force `rndc` to regenerate signatures:
  ```bash
  $ rndc sign example.com
  $ rndc dnssec -status example.com
  ```

---

#### Failure Scenario 3: Chroot File Descriptor or Permission Block

* **Symptom:** `named` fails to start or update journal files when running inside chroot jail `/var/bind/chroot`.
* **Root Cause Analysis:** Ownership of `/var/bind/chroot/var/lib/bind` set to `root:root` instead of `bind:bind`, or missing system pseudo-devices (`/dev/null`, `/dev/random`) inside chroot environment.
* **Diagnostic Procedure:**
  1. Check system logs: `journalctl -u named.service --no-pager -n 50`
  2. Verify pseudo-device node status:
     ```bash
     $ ls -l /var/bind/chroot/dev/
     ```
* **Remediation Commands:**
  ```bash
  $ mkdir -p /var/bind/chroot/dev
  $ mknod -m 666 /var/bind/chroot/dev/null c 1 3
  $ mknod -m 666 /var/bind/chroot/dev/urandom c 1 9
  $ chown -R bind:bind /var/bind/chroot/var/lib/bind /var/bind/chroot/var/cache/bind
  ```

---

## 6. References

* **LPIC-2 Exam Objectives (4.5):**  
  [https://www.lpi.org/our-certifications/lpic-2-overview/](https://www.lpi.org/our-certifications/lpic-2-overview/)
* **ISC BIND 9 Administrator Reference Manual (ARM):**  
  [https://bind9.readthedocs.io/en/v9.18/](https://bind9.readthedocs.io/en/v9.18/)
* **RFC 1034 - Domain Names - Concepts and Facilities:**  
  [https://datatracker.ietf.org/doc/html/rfc1034](https://datatracker.ietf.org/doc/html/rfc1034)
* **RFC 1035 - Domain Names - Implementation and Specification:**  
  [https://datatracker.ietf.org/doc/html/rfc1035](https://datatracker.ietf.org/doc/html/rfc1035)
* **RFC 2845 - Secret Key Transaction Authentication for DNS (TSIG):**  
  [https://datatracker.ietf.org/doc/html/rfc2845](https://datatracker.ietf.org/doc/html/rfc2845)
* **RFC 4033 - DNS Security Introduction and Requirements (DNSSEC):**  
  [https://datatracker.ietf.org/doc/html/rfc4033](https://datatracker.ietf.org/doc/html/rfc4033)