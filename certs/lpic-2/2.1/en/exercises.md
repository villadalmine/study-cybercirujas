# LPIC-2 Certification Study Guide: Topic 207 / Theme 2.1 — Domain Name Server (Weight: 8)

## 1. Topic Architecture & Official Reference Sources

The Domain Name System (DNS) is a hierarchical, distributed database critical to platform engineering and infrastructure reliability. ISC BIND 9 (`named`) remains the reference implementation for authoritative and recursive DNS on Linux systems. 

```
                                  [ Root Hits (.) ]
                                          |
                                    [ TLD (.com) ]
                                          |
                               [ Authoritative Primary ]
                                   (example.com)
                                   /           \
                 [ Internal View (Split) ]    [ External View (Split) ]
                    (10.0.0.0/8 Clients)         (Public Internet)
```

### Official References
- **LPI LPIC-2 Objectives**: [LPI Official LPIC-2 201-450 & 202-450 Detailed Objectives](https://www.lpi.org/our-certifications/lpic-2-overview/)
- **ISC BIND 9 Administrator Reference Manual (ARM)**: [ISC BIND 9 Documentation](https://bind9.readthedocs.io/en/latest/)
- **RFC 1034 / RFC 1035**: [Domain Names - Concepts and Facilities / Implementation and Specification](https://datatracker.ietf.org/doc/html/rfc1035)
- **RFC 2845**: [Secret Key Transaction Authentication for DNS (TSIG)](https://datatracker.ietf.org/doc/html/rfc2845)
- **RFC 4033 / 4034 / 4035**: [DNS Security Extensions (DNSSEC) Resource Records & Protocol Modifications](https://datatracker.ietf.org/doc/html/rfc4033)

---

## 2. Hands-On Guided Lab Exercises

---

### Exercise Block 1: Production Master/Secondary Topology with TSIG & RRL

#### Objective
Configure an isolated primary DNS server (`ns1.ops.infra`) and secondary DNS server (`ns2.ops.infra`). Enforce security using TSIG (`hmac-sha256`) for zone transfers (AXFR), disable recursive resolution for external queries, apply Response Rate Limiting (RRL), and verify syntax using native BIND toolsets.

#### Step 1: Generate TSIG Key and Configure Access Control Lists (ACLs)
Log in to `ns1.ops.infra` (IP: `192.168.50.10`). Generate an HMAC-SHA256 TSIG key file using `tsig-keygen` and create a dedicated configuration snippet.

```bash
# Generate TSIG key for secondary synchronization
tsig-keygen -a hmac-sha256 transfer-key.ops.infra > /etc/named/tsig-transfer.key
chown root:named /etc/named/tsig-transfer.key
chmod 0640 /etc/named/tsig-transfer.key
cat /etc/named/tsig-transfer.key
```

*Expected Output:*
```bind
key "transfer-key.ops.infra" {
	algorithm hmac-sha256;
	secret "K8zP9xQvR2mN5bV8cW0L1kJ3hG6fD9sA2zX4cV6bN8m=";
};
```

#### Step 2: Construct Production `/etc/named.conf` on Primary Node
Edit `/etc/named.conf` on `ns1.ops.infra`. Configure global security options, limit query interfaces, enforce RRL to mitigate amplification attacks, and restrict zone transfers exclusively to authenticated TSIG clients.

```bind
include "/etc/named/tsig-transfer.key";

acl "trusted_secondaries" {
    192.168.50.11; // ns2.ops.infra
};

acl "internal_clients" {
    127.0.0.1;
    192.168.50.0/24;
};

options {
    listen-on port 53 { 127.0.0.1; 192.168.50.10; };
    listen-on-v6 port 53 { ::1; };
    directory "/var/named";
    dump-file "/var/named/data/cache_dump.db";
    statistics-file "/var/named/data/named_stats.txt";
    memstatistics-file "/var/named/data/named_mem_stats.txt";
    
    // Security & Recursion Controls
    recursion no;
    allow-query { any; };
    allow-recursion { none; };
    allow-transfer { key "transfer-key.ops.infra"; };
    version "NOT AVAILABLE";

    // Response Rate Limiting (RRL)
    rate-limit {
        responses-per-second 10;
        window 5;
        nxdomains-per-second 5;
        errors-per-second 5;
        ipv4-prefix-length 24;
    };

    dnssec-validation auto;
    managed-keys-directory "/var/named/dynamic";
    pid-file "/run/named/named.pid";
    session-keyfile "/run/named/session.key";
};

zone "ops.infra" IN {
    type primary; // Equivalent to 'master' in legacy BIND syntax
    file "slaves/ops.infra.db"; // Primary zone definition
    file "master/ops.infra.db";
    allow-transfer { key "transfer-key.ops.infra"; };
    notify yes;
    also-notify { 192.168.50.11; };
};
```

#### Step 3: Define Syntactically Valid Forward Zone File
Create `/var/named/master/ops.infra.db` on `ns1.ops.infra`.

```bind
$TTL 86400
$ORIGIN ops.infra.
@   IN  SOA ns1.ops.infra. sysadmin.ops.infra. (
            2026080601 ; Serial YYYYMMDDnn
            3600       ; Refresh (1 hour)
            1800       ; Retry (30 minutes)
            1209600    ; Expire (2 weeks)
            86400      ; Minimum / Negative TTL (1 day)
            )

; Name Servers
@       IN  NS      ns1.ops.infra.
@       IN  NS      ns2.ops.infra.

; A Records for Infrastructure
ns1     IN  A       192.168.50.10
ns2     IN  A       192.168.50.11
app1    IN  A       192.168.50.20
app2    IN  A       192.168.50.21
lb01    IN  A       192.168.50.5
```

#### Step 4: Validate Configuration and Zone File Integrity
Run BIND validation tools before starting the service.

```bash
# Check configuration syntax
named-checkconf /etc/named.conf

# Check zone file syntax and serial consistency
named-checkzone ops.infra /var/named/master/ops.infra.db
```

*Expected Output:*
```text
zone ops.infra/IN: loaded serial 2026080601
OK
```

#### Step 5: Configure Secondary Node (`ns2.ops.infra` - IP: 192.168.50.11)
Install the identical `tsig-transfer.key` file on `ns2.ops.infra` and configure `/etc/named.conf` to act as a secondary server pulling zone transfers via TSIG.

```bind
include "/etc/named/tsig-transfer.key";

server 192.168.50.10 {
    keys { "transfer-key.ops.infra"; };
};

options {
    listen-on port 53 { 127.0.0.1; 192.168.50.11; };
    directory "/var/named";
    recursion no;
    allow-query { any; };
};

zone "ops.infra" IN {
    type secondary; // Equivalent to 'slave'
    file "slaves/ops.infra.db";
    primaries { 192.168.50.10 key "transfer-key.ops.infra"; };
};
```

#### Step 6: Test Authenticated Zone Transfer (AXFR) via `dig`
Run `dig` from `ns2.ops.infra` to verify that unauthenticated AXFR fails, but TSIG-authenticated AXFR succeeds.

```bash
# Attempt 1: Unauthenticated transfer (Should be REFUSED)
dig @192.168.50.10 ops.infra AXFR

# Attempt 2: Authenticated transfer using TSIG key
dig @192.168.50.10 ops.infra AXFR -k /etc/named/tsig-transfer.key
```

*Expected Output (Attempt 1):*
```text
;; ->>HEADER<<- opcode: QUERY, status: REFUSED, id: 41209
;; flags: qr ra; QUERY: 1, ANSWER: 0, AUTHORITY: 0, ADDITIONAL: 0
```

*Expected Output (Attempt 2):*
```text
; <<>> DiG 9.16.23-RH <<>> @192.168.50.10 ops.infra AXFR -k /etc/named/tsig-transfer.key
;; global options: +cmd
ops.infra.		86400	IN	SOA	ns1.ops.infra. sysadmin.ops.infra. 2026080601 3600 1800 1209600 86400
ops.infra.		86400	IN	NS	ns1.ops.infra.
ops.infra.		86400	IN	NS	ns2.ops.infra.
app1.ops.infra.		86400	IN	A	192.168.50.20
app2.ops.infra.		86400	IN	A	192.168.50.21
lb01.ops.infra.		86400	IN	A	192.168.50.5
ns1.ops.infra.		86400	IN	A	192.168.50.10
ns2.ops.infra.		86400	IN	A	192.168.50.11
ops.infra.		86400	IN	SOA	ns1.ops.infra. sysadmin.ops.infra. 2026080601 3600 1800 1209600 86400
;; Query time: 2 msec
;; SERVER: 192.168.50.10#53(192.168.50.10)
```

---

#### Verification Questions (Block 1)

1. **Question 1.1**: What specific security flaw occurs if `allow-transfer` is omitted or set to `any;` in a production BIND deployment?
2. **Question 1.2**: In the SOA record syntax `2026080601 3600 1800 1209600 86400`, what happens if the secondary server fails to reach the primary server for a duration exceeding `1209600` seconds?
3. **Question 1.3**: How does BIND's `response-rate-limiting` (RRL) block help mitigate DNS Amplification (DDoS) attacks targeting authoritative servers?

---

### Exercise Block 2: Advanced Resource Records, Split-Horizon Views, and Reverse Maps

#### Objective
Implement a Split-Horizon (Split-Brain) DNS architecture using BIND `view` clauses to serve different IP mappings based on client source IP (Internal vs External). Configure SRV, CAA, TXT (SPF/DMARC), and IPv4 reverse mapping (`in-addr.arpa`) records.

#### Step 1: Configure `named.conf` for Split-Horizon Architecture
Edit `/etc/named.conf` on `ns1.ops.infra`. Note that when using BIND `view` clauses, **all zones must be inside a view**.

```bind
acl "internal-network" {
    10.0.0.0/8;
    192.168.50.0/24;
    127.0.0.1;
};

options {
    directory "/var/named";
    listen-on port 53 { any; };
    recursion no;
};

// View for Internal Network Clients
view "internal" {
    match-clients { "internal-network"; };
    recursion yes;
    allow-recursion { "internal-network"; };

    zone "ops.infra" IN {
        type primary;
        file "master/ops.infra.internal.db";
    };

    zone "50.168.192.in-addr.arpa" IN {
        type primary;
        file "master/192.168.50.rev";
    };
};

// View for External/Public Clients
view "external" {
    match-clients { any; };
    recursion no;

    zone "ops.infra" IN {
        type primary;
        file "master/ops.infra.external.db";
    };
};
```

#### Step 2: Draft Internal Zone File with Advanced Records (`master/ops.infra.internal.db`)
Create the internal zone file containing MX, TXT (SPF/DMARC), SRV, and CAA records.

```bind
$TTL 86400
$ORIGIN ops.infra.
@   IN  SOA ns1.ops.infra. sysadmin.ops.infra. (
            2026080602 ; Serial
            7200       ; Refresh
            3600       ; Retry
            1209600    ; Expire
            3600 )     ; Negative Cache TTL

@       IN  NS      ns1.ops.infra.
@       IN  MX  10  mail01.ops.infra.

; Host Address Records
ns1     IN  A       192.168.50.10
mail01  IN  A       192.168.50.25
api     IN  A       10.10.100.50

; Service Location Record (SRV): _service._proto.name. TTL Class SRV priority weight port target.
_sip._tcp IN SRV    10 60 5060 sipserver.ops.infra.
sipserver IN A      192.168.50.30

; Certificate Authority Authorization (CAA)
@       IN  CAA     0 issue "letsencrypt.org"
@       IN  CAA     0 iodef "mailto:security@ops.infra"

; TXT Records: SPF and DMARC
@       IN  TXT     "v=spf1 ip4:192.168.50.25 -all"
_dmarc  IN  TXT     "v=DMARC1; p=reject; rua=mailto:dmarc-reports@ops.infra; pct=100"
```

#### Step 3: Configure Reverse Mapping Zone (`master/192.168.50.rev`)
Create PTR records matching the IPv4 address space `192.168.50.0/24`.

```bind
$TTL 86400
$ORIGIN 50.168.192.in-addr.arpa.
@   IN  SOA ns1.ops.infra. sysadmin.ops.infra. (
            2026080601 ; Serial
            3600       ; Refresh
            1800       ; Retry
            1209600    ; Expire
            3600 )     ; Minimum TTL

@       IN  NS      ns1.ops.infra.

; PTR Records (Last octet of IP address)
10      IN  PTR     ns1.ops.infra.
11      IN  PTR     ns2.ops.infra.
20      IN  PTR     app1.ops.infra.
25      IN  PTR     mail01.ops.infra.
```

#### Step 4: Validate and Verify Split-Horizon and Pointer Lookups
Test resolution from internal and external IP contexts using `dig`.

```bash
# Verify PTR Reverse Lookup
dig @127.0.0.1 -x 192.168.50.25 +short

# Verify SRV Query
dig @127.0.0.1 SRV _sip._tcp.ops.infra. +noall +answer

# Verify CAA Record Query
dig @127.0.0.1 CAA ops.infra. +noall +answer
```

*Expected Output:*
```text
mail01.ops.infra.
_sip._tcp.ops.infra.	86400	IN	SRV	10 60 5060 sipserver.ops.infra.
ops.infra.		86400	IN	CAA	0 issue "letsencrypt.org"
ops.infra.		86400	IN	CAA	0 iodef "mailto:security@ops.infra"
```

---

#### Verification Questions (Block 2)

1. **Question 2.1**: What syntax requirement must be strictly observed in `named.conf` when introducing `view` directives regarding zones defined at the global top-level scope?
2. **Question 2.2**: Explain the operational difference between `p=none`, `p=quarantine`, and `p=reject` in a `_dmarc` TXT record.
3. **Question 2.3**: What is the canonical reverse lookup domain name for the IPv6 address `2001:db8::1`?

---

### Exercise Block 3: DNSSEC Signing, Key Management, and Operational Troubleshooting

#### Objective
Implement DNSSEC on an authoritative zone using manual and automated BIND mechanisms. Generate KSK (Key Signing Key) and ZSK (Zone Signing Key), sign the zone file, publish DS records, use `rndc` for runtime controls, and diagnose validation errors using `delv`.

#### Step 1: Generate KSK and ZSK Cryptographic Keys
Navigate to the secure BIND keys directory and generate RSASHA256 keys.

```bash
cd /var/named/keys

# Generate Zone Signing Key (ZSK) - 1280 bits
dnssec-keygen -a RSASHA256 -b 1280 -n ZONE ops.infra

# Generate Key Signing Key (KSK) - 2048 bits with Flag 257
dnssec-keygen -a RSASHA256 -b 2048 -f KSK -n ZONE ops.infra

ls -l Kops.infra.*
```

*Expected Output:*
```text
-rw-r--r--. 1 root named 1729 Aug 6 10:00 Kops.infra.+008+12345.key
-rw-------. 1 root named 3227 Aug 6 10:00 Kops.infra.+008+12345.private
-rw-r--r--. 1 root named 2380 Aug 6 10:01 Kops.infra.+008+67890.key
-rw-------. 1 root named 4096 Aug 6 10:01 Kops.infra.+008+67890.private
```

#### Step 2: Include Keys in Zone File and Sign Manually via `dnssec-signzone`
Append the public keys (`.key`) to `/var/named/master/ops.infra.db` and run `dnssec-signzone`.

```bash
# Append key includes to the zone file
echo '$INCLUDE /var/named/keys/Kops.infra.+008+12345.key' >> /var/named/master/ops.infra.db
echo '$INCLUDE /var/named/keys/Kops.infra.+008+67890.key' >> /var/named/master/ops.infra.db

# Sign the zone file (Generates ops.infra.db.signed and dsset-ops.infra.)
dnssec-signzone -A -3 $(head -c 16 /dev/urandom | hexxdump -e '16/1 "%02X"') \
  -N INCREMENT -o ops.infra -k /var/named/keys/Kops.infra.+008+67890.key \
  /var/named/master/ops.infra.db /var/named/keys/Kops.infra.+008+12345.key
```

*Expected Output:*
```text
Verifying the zone using private keys...
Zone signing complete:
Nodes: 8
Signatures generated: 18
Signatures retained: 0
Signatures dropped: 0
Signature verification failed: 0
Signature verification succeeded: 0
Signatures expired: 0
Signatures not yet valid: 0
Signatures remaining: 18
Authoritative signatures total: 18
Authoritative signatures computed: 18
Signatures set to expire in 30 days.
Signed zone file output: /var/named/master/ops.infra.db.signed
```

#### Step 3: Update `named.conf` to Serve the Signed Zone
Modify the zone block in `/etc/named.conf` to serve the `.signed` zone variant.

```bind
zone "ops.infra" IN {
    type primary;
    file "master/ops.infra.db.signed";
    allow-transfer { key "transfer-key.ops.infra"; };
};
```

Reload BIND via `rndc`:

```bash
rndc reload ops.infra
rndc status
```

*Expected Output:*
```text
version: BIND 9.16.23-RH (Extended Support Version) <id:1018968>
running on ns1.ops.infra: Linux x86_64 5.14.0-70.c8.x86_64 #1 SMP
boot time: Thu, 06 Aug 2026 09:00:00 GMT
last configured: Thu, 06 Aug 2026 10:15:00 GMT
configuration file: /etc/named.conf
cpus found: 4
worker threads: 4
number of zones: 105 (101 automatic)
debug level: 0
xfers running: 0
xfers deferred: 0
soa queries in progress: 0
query logging is OFF
server is idlok
```

#### Step 4: Validate DNSSEC Records and Signatures with `dig` and `delv`
Query RRSIG and DNSKEY records to verify operational integrity.

```bash
# Query DNSKEY records
dig @127.0.0.1 ops.infra DNSKEY +multiline

# Query A record with DNSSEC validation request (+dnssec)
dig @127.0.0.1 app1.ops.infra A +dnssec

# Deep diagnostic validation using delv (Domain Entity Lookup & Verification)
delv @127.0.0.1 app1.ops.infra A +rtrace
```

*Expected Output (`dig +dnssec` snippet):*
```text
;; QUESTION SECTION:
;app1.ops.infra.			IN	A

;; ANSWER SECTION:
app1.ops.infra.		86400	IN	A	192.168.50.20
app1.ops.infra.		86400	IN	RRSIG	A 8 3 86400 20260905100000 20260806100000 12345 ops.infra. g8F1N...==
```

---

#### Verification Questions (Block 3)

1. **Question 3.1**: What is the structural functional distinction between a Zone Signing Key (ZSK) and a Key Signing Key (KSK) in DNSSEC architecture?
2. **Question 3.2**: When executing `rndc freeze ops.infra`, what operational state is imposed on the zone, and what command must be issued after manual zone modifications?
3. **Question 3.3**: If `delv` reports `unsigned answer` or `verification failure: trusted key mismatch`, what are the primary root causes in the DNSSEC chain of trust?

---

## 3. Answer Key & Deep Architectural Explanations

<details>
<summary>Click to expand Answer Key and In-Depth Technical Explanations</summary>

### Block 1 Answers

* **Answer 1.1**: If `allow-transfer` is unconstrained (`any;`), any malicious actor on the network can execute an unsolicited `AXFR` (Full Zone Transfer) query. This leaks the entire database schema of your domain name space (all internal hostnames, IP mappings, service endpoints, and infrastructure topology), drastically expanding the reconnaissance attack surface for targeted exploits.

* **Answer 1.2**: If a secondary server cannot establish contact with the primary server for a duration exceeding the SOA **Expire** field (`1209600` seconds / 14 days), the secondary server considers its cached zone data stale and invalid. It **stops answering queries** for that zone entirely, returning `SERVFAIL` to client requests to prevent serving out-of-date records.

* **Answer 1.3**: Response Rate Limiting (RRL) tracks client query patterns grouped by subnet (`ipv4-prefix-length 24`). If an attacker spoofs a target victim's IP address and floods an authoritative BIND server with requests for large records (e.g., `ANY` queries or signed DNSSEC records), RRL drops or truncates responses exceeding `responses-per-second`. This prevents the authoritative server from being weaponized as an amplifier in a Distributed Denial of Service (DDoS) attack.

---

### Block 2 Answers

* **Answer 2.1**: Once BIND `view` directives are introduced in `named.conf`, **every single zone definition must reside inside a `view` block**. Defining top-level `zone` statements outside a `view` block triggers a fatal parsing error during `named-checkconf` (`when views are used, all zones must be in views`).

* **Answer 2.2**: The DMARC policy (`p=`) controls how receiving Mail Transfer Agents (MTAs) process messages that fail SPF and DKIM authentication:
  * `p=none`: Monitoring mode; messages are delivered normally, but failure reports are sent to the `rua` URI.
  * `p=quarantine`: Messages failing checks are marked as spam/suspicious and diverted to the recipient's junk folder.
  * `p=reject`: Messages failing checks are flatly rejected at the SMTP envelope transaction phase (hard bounce).

* **Answer 2.3**: The canonical reverse lookup domain name for `2001:db8::1` expands to a full 32-nibble hexadecimal format separated by dots under `ip6.arpa`:
  `1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa.`

---

### Block 3 Answers

* **Answer 3.1**: 
  * **Zone Signing Key (ZSK)**: Used to sign all standard Resource Record Sets (RRsets) in the zone (e.g., A, AAAA, MX, TXT). It uses shorter key lengths (e.g., RSA 1280-bit) for faster performance and is rolled over frequently (e.g., every 30–90 days).
  * **Key Signing Key (KSK)**: Used exclusively to sign the `DNSKEY` RRset containing the ZSK. It uses longer key lengths (e.g., RSA 2048-bit) for greater security. Its public key hash is published to the parent zone as a Delegation Signer (**DS**) record to establish the Chain of Trust.

* **Answer 3.2**: `rndc freeze ops.infra` pauses dynamic zone updates (IXFR/DDNS), flushes pending journal files (`.jnl`) directly into the flat-text zone file, and prevents BIND from modifying the file on disk. This allows safe manual text editing. After completing modifications and updating the SOA serial, you must issue `rndc thaw ops.infra` to reload the zone and re-enable dynamic updates.

* **Answer 3.3**: The errors signify a failure in establishing or verifying the DNSSEC Chain of Trust:
  1. The parent TLD zone holds a **DS record** digest that does not match the hash of the local zone's active **KSK**.
  2. The zone's cryptographic signatures (**RRSIG**) have expired due to unsynchronized system clocks (NTP drift) or failure to re-sign the zone before signature expiration.
  3. The local resolver lacks the updated Root Anchor key (`managed-keys`).

</details>