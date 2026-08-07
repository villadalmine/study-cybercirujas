# LPI-702 Study Guide: Topic 714.4 – Configure Client-Side DNS

**Exam:** LPI BSD Specialist (Exam 702-100, Version 1.0)  
**Topic:** 714.4 Configure Client Side DNS  
**Topic Weight:** 3.33  

---

## 1. Architectural Deep-Dive & System Mechanics

### 1.1 The BSD Resolver Architecture & Execution Lifecycle
On BSD systems (FreeBSD, OpenBSD, NetBSD), client-side Domain Name System (DNS) resolution is handled by C library functions (`libc`)—primarily modern POSIX `getaddrinfo(3)` and legacy `gethostbyname(3)`.

When an application requests network endpoint resolution (e.g., calling `curl https://api.internal.net`), the OS follows a strict processing chain:

```
[ Application ] 
       │ (calls getaddrinfo)
       ▼
[ C Library Resolver (libc) ]
       │
       ├─► Read /etc/nsswitch.conf (FreeBSD/NetBSD)
       │     └─► Host lookup source order: [ files ──► dns ──► mdns ]
       │
       ├─► [ Source 1: "files" ] ──► Parse /etc/hosts
       │     └─► Match found? Return IP to Application.
       │
       └─► [ Source 2: "dns" ] ──► Read /etc/resolv.conf
             ├─► Check domain / search directives (Apply ndots evaluation)
             ├─► Construct UDP/TCP DNS Query Packet (EDNS0, Opt Pseudo-RR)
             └─► Send to configured nameserver (IP:53 or 127.0.0.1)
```

1. **System Name Service Switch (`/etc/nsswitch.conf`):**  
   In FreeBSD and NetBSD, the Name Service Switch (NSS) daemon and library dispatch lookup requests according to the `hosts` entry. OpenBSD relies on `/etc/hosts` and `/etc/resolv.conf` directly, maintaining a lightweight resolver loop in `libc`.
2. **Local Static Table (`/etc/hosts`):**  
   Evaluates IP-to-hostname mappings line-by-line. If a matching host string is found, resolution finishes immediately without sending network packets.
3. **Domain Name System Client (`/etc/resolv.conf`):**  
   Defines recursive nameserver IP addresses, default search domains, domain appending rules (`ndots`), and socket timeout/retry parameters.

---

### 1.2 `/etc/resolv.conf` Deep-Dive: Syntax & Directives

The `/etc/resolv.conf` file configures the C library resolver routines.

| Directive | Description | Production Default / Recommendation |
| :--- | :--- | :--- |
| `nameserver <IP>` | IPv4 or IPv6 address of recursive DNS resolver. Up to 3 nameserver directives can be listed. Checked sequentially unless `rotate` is set. | Max 3 servers. Use `127.0.0.1` when running a local caching stub like Unbound. |
| `search <domain ...>` | Search list for hostname lookup. Up to 6 domains total (max 256 characters total). | Explicitly list internal domain suffixes (e.g., `prod.internal corp.local`). |
| `domain <domain>` | Local domain name. Short hostnames are appended with this string. (Mutually exclusive with `search`; last specified wins). | Prefer `search` over `domain` in multi-tier enterprise environments. |
| `options ndots:n` | Threshold for number of dots in a query name before an initial *absolute* lookup is performed. If dots $\ge n$, name is queried as-is first. If dots $< n$, search paths are appended first. | Default is `1`. Set to `1` or `2` for reduced DNS query amplification. |
| `options timeout:n` | Time (in seconds) the resolver waits for a response from a remote nameserver before retrying. | Default `5`s. In production, set to `1` or `2` seconds to prevent application threads from hanging. |
| `options attempts:n` | Number of times the resolver sends a query to its nameservers before giving up. | Default `2`. Set to `2` for low latency failover between primary/secondary. |
| `options rotate` | Enables round-robin selection among configured nameservers, balancing outbound query loads across all listed resolvers. | Enable in high-throughput stateless worker nodes. |
| `options edns0` | Enables Extension Mechanisms for DNS (RFC 6891), allowing UDP payload sizes greater than 512 bytes (typically 1232 or 4096 bytes). | Mandatory for modern DNSSEC-validated networks. |

---

### 1.3 Resolution Order Mechanics & The `ndots` Behavior

Understanding `ndots` is critical for troubleshooting microservice latencies and external domain lookups.

Suppose `/etc/resolv.conf` has:
```text
search prod.internal corp.local
options ndots:2
```

- **Query 1:** Application resolves `db01` (Number of dots = `0`).  
  - Since $0 < \text{ndots (2)}$, resolver appends search paths **first**:
    1. `db01.prod.internal`
    2. `db01.corp.local`
    3. `db01.` (FQDN root retry)
- **Query 2:** Application resolves `api.service.io` (Number of dots = `2`).  
  - Since $2 \ge \text{ndots (2)}$, resolver performs an absolute query **first**:
    1. `api.service.io.`
    2. (If NXDOMAIN returned) `api.service.io.prod.internal`
    3. (If NXDOMAIN returned) `api.service.io.corp.local`

---

### 1.4 Core Record Types & Query Diagnostic Tools

BSD environments utilize two primary DNS lookup tools in base system and ports:
- `drill`: The default BSD lookup utility provided by NLnet Labs (bundled in FreeBSD base system).
- `dig`: The classic BIND utility (available via `bind-tools` package/port).

#### Essential Resource Records (RRs):
- **A**: IPv4 address record.
- **AAAA**: IPv6 address record.
- **PTR**: Pointer record for reverse DNS lookups (maps IP address to canonical hostname via `.in-addr.arpa` or `.ip6.arpa`).
- **MX**: Mail Exchanger record (includes priority integers).
- **TXT**: Text records (used for SPF, DKIM, DMARC, and domain verification).
- **CNAME**: Canonical Name record (alias pointing to another domain name).
- **NS**: Name Server authoritative designation records.
- **SOA**: Start of Authority record (defines zone administration, serial numbers, TTLs).

---

## 2. Production Manifests & Syntactically Valid Configurations

### 2.1 Enterprise High-Availability `/etc/resolv.conf`

```text
# /etc/resolv.conf - Enterprise Production Client Configuration
# Managed by Infrastructure Automation - DO NOT EDIT MANUALLY

search infra.prod.internal corp.global
nameserver 10.0.10.53
nameserver 10.0.20.53
nameserver 1.1.1.1
options ndots:1 timeout:1 attempts:2 rotate edns0
```

### 2.2 FreeBSD / NetBSD Name Service Switch Configuration (`/etc/nsswitch.conf`)

```text
# /etc/nsswitch.conf - Name Service Switch configuration
# See nsswitch.conf(5) for syntax details.

group:          files
passwd:         files
hosts:          files dns
networks:       files dns
protocols:      files
services:       files
ethers:         files
rpc:            files
```

### 2.3 Production `/etc/hosts` Override Configuration

```text
# /etc/hosts - Static Host Lookup Table
# Syntax: <IP Address> <Official Host Name> [Aliases...]

127.0.0.1       localhost localhost.my.domain
::1             localhost localhost.my.domain

# Local Static Overrides for Emergency Out-of-Band Management
10.0.0.1        gateway.prod.internal router
10.0.10.12      db-primary.prod.internal db01
10.0.10.13      db-secondary.prod.internal db02
```

### 2.4 Local Unbound Caching Stub Resolver (`/etc/unbound/unbound.conf`)

For ultra-low latency applications, running a local caching resolver on `127.0.0.1` decouples application threads from external network DNS delays.

```unicast
# /etc/unbound/unbound.conf - Local Caching Stub Resolver
server:
    verbosity: 1
    interface: 127.0.0.1
    port: 53
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes

    # Access Control: strict loopback enforcement
    access-control: 127.0.0.0/8 allow
    access-control: ::1 allow

    # Security & Performance Hardening
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    prefetch: yes
    cache-min-ttl: 60
    cache-max-ttl: 86400

forward-zone:
    name: "."
    forward-addr: 10.0.10.53
    forward-addr: 10.0.20.53
```

---

## 3. Hands-On Guided Production Exercises

### Exercise 1: System Resolver Order and Local Host Overrides

In this exercise, you will verify and alter the host resolution fallback behavior using `/etc/nsswitch.conf` and `/etc/hosts`.

#### Step 1.1: Verify current resolution order in `/etc/nsswitch.conf`
Inspect the `hosts:` directive in `/etc/nsswitch.conf` (FreeBSD/NetBSD):

```bash
grep -E "^hosts:" /etc/nsswitch.conf
```

**Expected Output:**
```text
hosts: files dns
```

#### Step 1.2: Add a static host mapping to `/etc/hosts`
Add an entry mapping `test-internal.local` to `127.0.0.99`.

```bash
echo "127.0.0.99  test-internal.local" | sudo tee -a /etc/hosts
```

#### Step 1.3: Execute lookup using system resolver
Query the host using `host` or `getent`:

```bash
host test-internal.local
```

**Expected Output:**
```text
test-internal.local has address 127.0.0.99
```

#### Step 1.4: Inspect behavior when reversing resolution order
Temporarily edit `/etc/nsswitch.conf` so `dns` precedes `files`:

```bash
sudo sed -i '' 's/^hosts:.*/hosts: dns files/' /etc/nsswitch.conf
```

Attempt resolving a non-existent external record vs the local host entry:
```bash
host test-internal.local
```

Observe that because `dns` is checked first, the system queries the external nameserver. If the upstream DNS server does not know `test-internal.local`, it returns `NXDOMAIN` or fails before reading `/etc/hosts` depending on the libc backend flags. Restore original order:

```bash
sudo sed -i '' 's/^hosts:.*/hosts: files dns/' /etc/nsswitch.conf
```

---

#### Exercise 1 Comprehension Questions

1. If `/etc/nsswitch.conf` contains `hosts: files dns`, what happens when a application calls `getaddrinfo("db01.local")` and `db01.local` is present in `/etc/hosts`? Will a UDP port 53 packet be sent over the wire?
2. On OpenBSD, `/etc/nsswitch.conf` does not control host resolution. Which file handles static IP-to-hostname resolution before external DNS is queried?

---

### Exercise 2: Resolver Tuning (`ndots`, `timeout`, `attempts`) & Network Tracing

In this exercise, you will configure fast-fail DNS resolution options and inspect query amplification caused by `ndots`.

#### Step 2.1: Configure aggressive timeouts in `/etc/resolv.conf`
Update `/etc/resolv.conf` to configure microsecond-scale failover parameters:

```bash
cat << 'EOF' | sudo tee /etc/resolv.conf
search internal.domain corp.domain
nameserver 1.1.1.1
nameserver 8.8.8.8
options ndots:2 timeout:1 attempts:1
EOF
```

#### Step 2.2: Test DNS lookup with packet tracing
Open a second terminal or run `tcpdump` in the background to observe outgoing UDP DNS packets on port 53:

```bash
sudo tcpdump -n -i any udp port 53 &
TCPDUMP_PID=$!
sleep 1
```

#### Step 2.3: Perform a single-dot domain lookup
Query `app.service` (contains 1 dot):

```bash
host app.service
```

**Expected Output from `tcpdump`:**
```text
IP 192.168.1.50.41203 > 1.1.1.1.53: 4102+ A? app.service.internal.domain. (46)
IP 192.168.1.50.41204 > 1.1.1.1.53: 4103+ A? app.service.corp.domain. (42)
IP 192.168.1.50.41205 > 1.1.1.1.53: 4104+ A? app.service. (29)
```

Notice that because `ndots:2` was configured and `app.service` only has **1 dot** ($1 < 2$), the resolver tried `app.service.internal.domain.` first, followed by `app.service.corp.domain.`, and finally `app.service.`.

#### Step 2.4: Clean up tcpdump process
```bash
sudo kill $TCPDUMP_PID
```

---

#### Exercise 2 Comprehension Questions

1. A DevOps Engineer complains that querying `api.stripe.com` generates unnecessary search domain requests (`api.stripe.com.corp.internal`) before querying the public domain. What `resolv.conf` directive and value will fix this behavior immediately?
2. If `options timeout:2 attempts:2` is specified in `/etc/resolv.conf` with 3 nameservers listed, what is the theoretical maximum time an application thread will wait before returning a total DNS resolution timeout error?

---

### Exercise 3: Advanced DNS Query Diagnostics & Record Inspection with `drill`

In this exercise, you will use `drill` (the standard BSD DNS diagnostic tool) to perform targeted queries for A, AAAA, MX, TXT, and reverse PTR records, and inspect EDNS0 and DNSSEC flags.

#### Step 3.1: Query IPv4 (A) and IPv6 (AAAA) records explicitly
Query the IPv4 address for `freebsd.org` using `drill`:

```bash
drill A freebsd.org
```

**Expected Output:**
```text
;; ->>HEADER<<- opcode: QUERY, rcode: NOERROR, id: 34912
;; flags: qr rd ra ; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 0

;; QUESTION SECTION:
;; freebsd.org.	IN	A

;; ANSWER SECTION:
freebsd.org.	900	IN	A	96.47.72.84

;; Query time: 24 msec
;; SERVER: 1.1.1.1#53(1.1.1.1)
;; WHEN: Thu Aug  6 20:56:13 2026
;; MSG SIZE rcvd: 45
```

Now query the IPv6 (AAAA) record:
```bash
drill AAAA freebsd.org
```

#### Step 3.2: Inspect MX (Mail Exchanger) and TXT records
Retrieve Mail Exchanger servers for `freebsd.org`:

```bash
drill MX freebsd.org
```

**Expected Output:**
```text
;; ANSWER SECTION:
freebsd.org.	3600	IN	MX	10 mx1.freebsd.org.
```

Retrieve TXT records (frequently containing SPF policy rules):
```bash
drill TXT freebsd.org
```

#### Step 3.3: Perform Reverse DNS PTR Lookups
Convert an IPv4 address to its reverse DNS lookup format (`in-addr.arpa`) using `drill -x`:

```bash
drill -x 96.47.72.84
```

**Expected Output:**
```text
;; QUESTION SECTION:
;; 84.72.47.96.in-addr.arpa.	IN	PTR

;; ANSWER SECTION:
84.72.47.96.in-addr.arpa.	3600	IN	PTR	wfe0.bsdgroup.tokyo.
```

#### Step 3.4: Validate EDNS0 and DNSSEC authentication flags
Query a DNSSEC-signed domain requesting the Authenticated Data (`ad`) flag and EDNS0 buffer parameters:

```bash
drill -D -d freebsd.org @1.1.1.1
```

Observe the `ad` flag in the header response, confirming DNSSEC cryptographic validation succeeded on the recursive resolver.

---

#### Exercise 3 Comprehension Questions

1. What command line flag is passed to `drill` (or `dig`) to perform a reverse DNS lookup for an IPv4 address `192.0.2.53` without manually constructing the `53.2.0.192.in-addr.arpa` string?
2. Which response header status (`rcode`) returned by `drill` indicates that the targeted domain name does not exist on the authoritative server?

---

### Exercise 4: Local Caching Stub Resolver Deployment with Unbound

In this exercise, you will enable and configure the base system `unbound` resolver on BSD, set up loopback caching, and point `/etc/resolv.conf` to `127.0.0.1`.

#### Step 4.1: Enable Unbound in FreeBSD `/etc/rc.conf`
Enable the Unbound service to start automatically at system boot:

```bash
sudo sysrc unbound_enable="YES"
```

**Expected Output:**
```text
unbound_enable: NO -> YES
```

#### Step 4.2: Generate initial Unbound root key for DNSSEC
Anchor DNSSEC validation using `unbound-anchor`:

```bash
sudo unbound-anchor -a "/var/unbound/root.key" || true
```

#### Step 4.3: Write local loopback configuration
Deploy the local caching configuration file:

```bash
cat << 'EOF' | sudo tee /etc/unbound/unbound.conf
server:
    verbosity: 1
    interface: 127.0.0.1
    port: 53
    access-control: 127.0.0.0/8 allow
    hide-identity: yes
    hide-version: yes

forward-zone:
    name: "."
    forward-addr: 1.1.1.1
    forward-addr: 8.8.8.8
EOF
```

#### Step 4.4: Start the Unbound daemon and verify listening socket
Start the service:

```bash
sudo service unbound start
```

Verify that Unbound is actively bound to TCP/UDP port 53 on `127.0.0.1` using `sockstat` or `netstat`:

```bash
sockstat -4 -l -p 53
```

**Expected Output:**
```text
USER     COMMAND    PID   FD PROTO LOCAL ADDRESS         FOREIGN ADDRESS     
unbound  unbound    4812  3  udp4  127.0.0.1:53          *:*
unbound  unbound    4812  4  tcp4  127.0.0.1:53          *:*
```

#### Step 4.5: Update `/etc/resolv.conf` to use loopback
Reconfigure `/etc/resolv.conf` to direct all system name lookups to the local Unbound cache:

```bash
cat << 'EOF' | sudo tee /etc/resolv.conf
# Local Unbound Stub Resolver
nameserver 127.0.0.1
options edns0
EOF
```

#### Step 4.6: Verify local resolution and caching performance
Execute a cold lookup:

```bash
drill freebsd.org @127.0.0.1 | grep "Query time"
```
*Expected Cold Query Time:* `~25-50 msec`

Execute a warm (cached) lookup:

```bash
drill freebsd.org @127.0.0.1 | grep "Query time"
```
*Expected Warm Query Time:* `0 msec`

---

#### Exercise 4 Comprehension Questions

1. Why is setting `nameserver 127.0.0.1` in `/etc/resolv.conf` alongside a local Unbound service superior for high-performance SRE application nodes compared to querying remote DNS servers directly over UDP?
2. What command line tool can be used to monitor cache hits/misses and live performance statistics of a running Unbound daemon?

---

## 4. Official References & Further Reading

- **LPI BSD Specialist Certification Overview:**  
  [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
- **FreeBSD Manual Pages - `resolv.conf(5)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=resolv.conf](https://man.freebsd.org/cgi/man.cgi?query=resolv.conf)
- **FreeBSD Manual Pages - `nsswitch.conf(5)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=nsswitch.conf](https://man.freebsd.org/cgi/man.cgi?query=nsswitch.conf)
- **OpenBSD Manual Pages - `resolv.conf(5)`:**  
  [https://man.openbsd.org/resolv.conf.5](https://man.openbsd.org/resolv.conf.5)
- **NLnet Labs Unbound Documentation:**  
  [https://nlnetlabs.nl/documentation/unbound/](https://nlnetlabs.nl/documentation/unbound/)

---

<details>
<summary><strong>Exercise Comprehension Answer Key</strong></summary>

### Exercise 1 Answers
1. **Answer:** The call returns `127.0.0.99` immediately from `/etc/hosts`. No UDP port 53 DNS packet is sent over the network because `files` is listed first in `/etc/nsswitch.conf`, fulfilling the lookup locally prior to reaching the `dns` backend.
2. **Answer:** `/etc/hosts` handles static hostname resolutions in OpenBSD prior to external DNS calls.

---

### Exercise 2 Answers
1. **Answer:** Set `options ndots:1` (or ensure `ndots` is $\le 2$, matching the dot count of `api.stripe.com` which has 2 dots). If `ndots:1` is configured, `api.stripe.com` contains 2 dots ($2 \ge 1$), forcing the resolver to issue an absolute FQDN lookup first without trying search path suffixes.
2. **Answer:** **12 seconds.**  
   *Calculation:* `timeout` (2s) $\times$ `attempts` (2) = 4 seconds per nameserver. Across 3 nameservers ($4\text{s} \times 3$), total elapsed time before timeout exhaustion is $12$ seconds.

---

### Exercise 3 Answers
1. **Answer:** `drill -x <IP_ADDRESS>` (e.g., `drill -x 192.0.2.53`).
2. **Answer:** `NXDOMAIN` (Non-Existent Domain, `rcode: NXDOMAIN`).

---

### Exercise 4 Answers
1. **Answer:** A local caching resolver caches answers in memory, reducing average query response times from tens of milliseconds to sub-millisecond ($0\text{ms}$). It also eliminates thread blocking under heavy outbound query loads, isolates external DNS network failures, and enables local DNSSEC validation.
2. **Answer:** `unbound-control stats` (or `unbound-control stats_noreset`).

</details>