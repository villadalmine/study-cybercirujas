# LPI-702 Study Guide: Topic 714.4 – Configure Client Side DNS

**Certification:** LPI BSD Specialist (Exam 702-100, Version 1.0)  
**Topic:** 714.4 Configure Client Side DNS  
**Exam Weight:** 3.33 (High Priority)  
**Target Profile:** Senior SRE / Principal Platform Architect  

---

## 1. Architectural Motivation & Production Problem Statement

In production enterprise environments—spanning bare-metal BSD/Linux clusters, hybrid clouds, and high-density Kubernetes deployments—client-side Domain Name System (DNS) resolution is a critical path dependency. Every HTTP request, RPC call, database transaction, and microservice invocation begins with a hostname resolution step. Improperly configured client-side DNS leads to catastrophic tail latency amplification, packet drops, thread starvation, and cascading system outages.

### 1.1 The Mechanics of Client-Side Resolution: `getaddrinfo(3)` vs. Direct Wire Queries

Operating systems resolve hostnames through two fundamentally distinct mechanisms:

```
+-----------------------------------------------------------------------------------+
|                                 APPLICATION LAYER                                 |
+-----------------------------------------------------------------------------------+
           |                                                       |
           | Uses standard C Library API                           | Bypasses libc API
           v                                                       v
+-----------------------+                               +-----------------------+
|   getaddrinfo(3) /    |                               |      dig / drill /    |
|   gethostbyname(3)    |                               |        host CLI       |
+-----------------------+                               +-----------------------+
           |                                                       |
           v                                                       |
+-----------------------+                                          |
|  /etc/nsswitch.conf   | (Determines lookup order)                |
+-----------------------+                                          |
     |             |                                               |
     v             v                                               v
+----------+  +-----------------------+                 +-----------------------+
|  /etc/   |  |   /etc/resolv.conf    |                 |   /etc/resolv.conf    |
|  hosts   |  | (Nameservers/Options) |                 |  (Direct Nameserver)  |
+----------+  +-----------------------+                 +-----------------------+
                           |                                       |
                           +-------------------+-------------------+
                                               |
                                               v
                                    +---------------------+
                                    | Network Wire (UDP)  |
                                    | Port 53 / EDNS0     |
                                    +---------------------+
```

1. **POSIX System C Library (`libc` / `glibc` / BSD `libc`):** Standard applications invoke synchronous functions such as `getaddrinfo(3)`. This layer reads `/etc/nsswitch.conf` to evaluate name resolution sources in strict left-to-right order (e.g., local host files before network DNS). If DNS is selected, `libc` invokes its internal resolver routines, which parse `/etc/resolv.conf`.
2. **Direct Wire DNS Utilities (`dig`, `drill`, `host`):** Diagnostic commands bypass `/etc/nsswitch.conf` and `/etc/hosts` entirely. They construct raw DNS binary wire format frames and transmit them directly to the upstream DNS nameservers defined in `/etc/resolv.conf` or supplied via command-line flags. A successful resolution via `dig` **does not** guarantee that an application calling `getaddrinfo(3)` will resolve the same hostname.

### 1.2 Production Bottlenecks and Failure Modes

* **Single-Threaded Blocking & Connection Starvation:** Standard C library resolvers do not maintain persistent socket pools or internal thread pools. Synchronous `getaddrinfo()` calls block worker threads. When an upstream DNS server experiences elevated latency or drops packets, application threads stall waiting for DNS timeouts (defaulting to 5 seconds per attempt), exhausting application thread pools.
* **The Linux/BSD Netfilter Conntrack Race Condition:** When applications query for dual-stack destinations (`A` for IPv4 and `AAAA` for IPv6), `libc` sends two UDP queries simultaneously over distinct sockets. On multi-core systems, parallel UDP packets traversing Linux `netfilter` or BSD `pf` state tables with the same source tuple trigger a lock contention/race condition in connection tracking (`conntrack`), resulting in dropped DNS responses and unexplainable 5-second delays.
* **Search Domain Multiplication (The `ndots` Penalty):** If a target hostname contains fewer dots than specified by the `ndots` directive in `/etc/resolv.conf`, the resolver appends every search domain listed in the `search` path sequentially before querying the absolute FQDN. In Kubernetes environments (`ndots:5`), looking up `external-api.stripe.com` (2 dots) generates 4 failed queries (`.svc.cluster.local`, `.cluster.local`, etc.) before issuing the valid query, multiplying DNS cluster load by 5x.
* **Uncached Latency Penalty:** Remote DNS lookups over UDP add 15ms–50ms of RTT latency. High-frequency microservices performing thousands of outbound connections per second encounter severe performance degradation without local stub caching (e.g., Unbound or NodeLocal DNSCache), which reduces hit latency to sub-millisecond (<1ms) levels.

---

## 2. Technical Comparison & Trade-off Analysis

### Table 2.1: Client-Side DNS Architecture Models

| Metric / Dimension | Direct `libc` Stub Resolver (`/etc/resolv.conf`) | Local Daemon Caching Resolver (Unbound) | Node-Local Proxy / Kubernetes DNSCache |
| :--- | :--- | :--- | :--- |
| **Lookup Latency** | High (15ms–100ms per RTT) | Very Low (<1ms on cache hit) | Ultra Low (<0.5ms via local loopback) |
| **Resource Overhead** | Near Zero (In-process memory) | Low (~15MB–50MB RAM, CPU scalable) | Low-Medium (~30MB RAM per Node) |
| **Cache Support** | None (Every call goes to wire) | Advanced (RRset, Infra, Negative, Prefetch) | Advanced (CoreDNS/Unbound engine) |
| **Resilience & Failover**| Poor (Basic round-robin / timeout) | High (Serve-Expired, Health checks) | Maximum (Local cache shields upstream failures) |
| **DNSSEC Validation** | None (Relies entirely on resolver `AD` flag) | Native Full In-Process Validation | Proxy or Full Validation dependent on engine |
| **Complexity** | Minimal (Simple text file editing) | Medium (Requires process management) | High (Requires DaemonSets, iptables/nftables) |

### Table 2.2: Inspection Tools Comparison

| Feature | `getent hosts` | `dig` (BIND Tools) | `drill` (NLnet Labs / ldns) | `host` |
| :--- | :--- | :--- | :--- | :--- |
| **Subsystem Tested** | Full System Stack (`nsswitch.conf` + `libc`) | Direct Wire Protocol (UDP/TCP Port 53) | Direct Wire Protocol (UDP/TCP Port 53) | Direct Wire Protocol (Simple) |
| **Respects `/etc/hosts`** | **Yes** | **No** | **No** | **No** |
| **Respects `nsswitch.conf`**| **Yes** | **No** | **No** | **No** |
| **Default on BSD** | Yes | Optional (ports/packages) | **Yes (Default on FreeBSD/OpenBSD)** | Optional / Base depending on OS |
| **EDNS0 / DNSSEC Flags** | No | Full control (`+dnssec`, `+bufsize`) | Full control (`-D`, `-s`) | Basic |
| **Output Format** | Parsed `/etc/hosts` syntax | Standard Master File Format / Verbose | Master File Format (Clean) | Human-readable text summary |

### Table 2.3: DNS Transport Protocol Trade-offs

| Transport Protocol | Maximum Payload | Overhead / Handshake | Firewall Traversability | MTU / Fragmentation Risk |
| :--- | :--- | :--- | :--- | :--- |
| **Standard UDP** | 512 Bytes | 0 RTT (Stateless) | High (Port 53 open) | None (Fits within standard MTU) |
| **UDP + EDNS0** | 1232–4096 Bytes | 0 RTT | High (Port 53 open) | **High** if payload > Path MTU (Fragment drops) |
| **TCP (`use-vc`)** | 65535 Bytes | 1 RTT (SYN-ACK) + Tear-down | High (Port 53 TCP) | Low (Handled by TCP MSS segmentation) |
| **DNS over TLS (DoT)**| 65535 Bytes | TLS 1.3 Handshake (1-2 RTT) | Medium (Requires Port 853 open) | Low (TCP/TLS payload encapsulation) |

---

## 3. Production Manifests and Configuration Specifications

### 3.1 Production Name Service Switch Configuration (`/etc/nsswitch.conf`)

This configuration dictates the host resolution lookup order. Local static overrides in `/etc/hosts` take precedence, followed by DNS queries. The `[NOTFOUND=return]` policy prevents falling back to subsequent resolution sources if local files explicitly report a domain as non-existent.

```ini
# /etc/nsswitch.conf - Production Host Resolution Configuration
# Syntax: database: source1 [action1] source2 [action2]

group:       files
group_compat: nis
hosts:       files dns [NOTFOUND=return]
networks:    files
passwd:      files
passwd_compat: nis
shells:      files
services:    files
protocols:   files
rpc:         files
```

---

### 3.2 Enterprise Client Resolver Configuration (`/etc/resolv.conf`)

This file configures the `libc` stub resolver behavior. All options are tuned for high-throughput, fault-tolerant production workloads.

```ini
# /etc/resolv.conf - Enterprise Client DNS Resolver Configuration

# Primary, Secondary, and Tertiary Upstream Recursive Nameservers
nameserver 10.240.0.10
nameserver 10.240.0.11
nameserver 1.1.1.1

# Domain Search Path (Keep short to avoid lookup multiplication penalties)
search infrastructure.internal production.corp

# Resolver Control Options:
# ndots:2            - Perform direct FQDN query if domain contains >= 2 dots.
# timeout:1          - Wait 1 second for a response before timing out (Default: 5s).
# attempts:2         - Query upstream nameservers a maximum of 2 times (Default: 2).
# rotate             - Round-robin load balance queries across all listed nameservers.
# single-request-reopen - Force socket closure and recreate a new socket for A and AAAA
#                      queries. Mitigates netfilter/conntrack UDP race conditions.
# edns0              - Enable EDNS0 extensions (supports large buffer sizes > 512B).
# trust-ad           - Pass Authentic Data (AD) bit from upstream validating resolver to app.
options ndots:2 timeout:1 attempts:2 rotate single-request-reopen edns0 trust-ad
```

---

### 3.3 Production Local Caching Resolver (`/etc/unbound/unbound.conf`)

Unbound is an enterprise-grade, lightweight, validating, and caching recursive DNS resolver. Below is a complete, syntactically valid production configuration optimized for multi-threaded systems.

```yaml
# /etc/unbound/unbound.conf - Production Caching Resolver Configuration

server:
    # Interface and Port Bindings
    interface: 127.0.0.1
    interface: ::1
    port: 53
    do-ip4: yes
    do-ip6: yes
    do-udp: yes
    do-tcp: yes

    # Access Control Enforcement
    access-control: 127.0.0.0/8 allow
    access-control: ::1/128 allow
    access-control: 0.0.0.0/0 refuse

    # Performance Tuning & Memory Optimization
    num-threads: 4
    msg-cache-slabs: 4
    rrset-cache-slabs: 4
    infra-cache-slabs: 4
    key-cache-slabs: 4
    
    # Memory Sizing (Adjust according to host capacity)
    rrset-cache-size: 128m
    msg-cache-size: 64m
    key-cache-size: 32m
    infra-cache-numhosts: 10000

    # EDNS0 Buffer Safety (1232 bytes prevents IP fragmentation over standard 1500 MTU)
    edns-buffer-size: 1232
    max-udp-size: 1232

    # Prefetching and Resilience (Serve-Expired mitigates upstream outages)
    prefetch: yes
    prefetch-key: yes
    serve-expired: yes
    serve-expired-ttl: 86400
    serve-expired-client-timeout: 1800

    # Hardening & Security Policies
    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-below-nxdomain: yes
    harden-referral-path: yes
    use-caps-for-id: no
    hide-identity: yes
    hide-version: yes
    identity: "DNS Resolver"

    # DNSSEC Root Anchor Configuration
    auto-trust-anchor-file: "/var/unbound/db/root.key"

    # Logging Parameters
    verbosity: 1
    log-queries: no
    log-replies: no
    use-syslog: yes

# Forwarding Zones - Route queries to authoritative enterprise DNS infrastructure
forward-zone:
    name: "."
    forward-addr: 10.240.0.10@53
    forward-addr: 10.240.0.11@53
    forward-first: yes

forward-zone:
    name: "internal.production."
    forward-addr: 10.250.0.1#53
```

---

### 3.4 Kubernetes NodeLocal DNSCache Configuration

This Kubernetes manifest deploys NodeLocal DNSCache on nodes to intercept client queries, eliminating connection tracking race conditions and caching responses locally.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: node-local-dns
  namespace: kube-system
  labels:
    addonmanager.kubernetes.io/mode: Reconcile
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
        bind 169.254.20.10
        forward . 10.96.0.10 {
                force_tcp
        }
        prometheus :9253
    }
    .:53 {
        errors
        cache 30
        reload
        loop
        bind 169.254.20.10
        forward . /etc/resolv.conf
        prometheus :9253
    }
---
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
  template:
    metadata:
      labels:
        k8s-app: node-local-dns
    spec:
      priorityClassName: system-node-critical
      serviceAccountName: node-local-dns
      hostNetwork: true
      dnsPolicy: Default
      tolerations:
      - operator: Exists
        effect: NoSchedule
      containers:
      - name: node-cache
        image: registry.k8s.io/dns/k8s-dns-node-cache:1.22.28
        resources:
          requests:
            cpu: 25m
            memory: 25Mi
          limits:
            memory: 100Mi
        args:
        - -localip
        - 169.254.20.10
        - -conf
        - /etc/Corefile
        - -upstreamdns-config
        - /etc/kube-dns/config
        securityContext:
          capabilities:
            add:
            - NET_ADMIN
        volumeMounts:
        - mountPath: /etc/Corefile
          name: config-volume
        - mountPath: /etc/kube-dns
          name: kube-dns-config
      volumes:
      - name: config-volume
        configMap:
          name: node-local-dns
          items:
            - key: Corefile
              path: Corefile
      - name: kube-dns-config
        configMap:
          name: kube-dns
          optional: true
```

---

## 4. Real CLI Commands & Production Terminal Outputs

### 4.1 Querying DNS Records with `dig`

Executing an `A` record query with DNSSEC validation (`+dnssec`) and tracking response latency:

```bash
$ dig +dnssec +multiline api.github.com A
```

**Output:**
```text
; <<>> DiG 9.18.28 <<>> +dnssec +multiline api.github.com A
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 48291
;; flags: qr rd ra ad; QUERY: 1, ANSWER: 3, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version 0, flags: do; udp: 1232
;; QUESTION SECTION:
;api.github.com.		IN A

;; ANSWER SECTION:
api.github.com.		60 IN CNAME dualstack.g.github.com.
dualstack.g.github.com.	60 IN A 140.82.121.4
dualstack.g.github.com.	60 IN RRSIG A 13 3 60 20260807024412 (
				20260806004412 34070 github.com.
				pL8/kU3Z2mHq/K7tS0lA9dY8zQn31xZ2A8B9C0D1
				E2F3G4H5I6J7K8L9M0N= )

;; Query time: 14 msec
;; SERVER: 10.240.0.10#53(10.240.0.10) (UDP)
;; WHEN: Thu Aug 06 20:55:24 EDT 2026
;; MSG SIZE  rcvd: 214
```

---

### 4.2 Querying DNS Records on BSD with `drill`

`drill` is the standard DNS query utility on BSD systems (FreeBSD, OpenBSD, NetBSD), built on top of the `ldns` library.

Executing a reverse DNS pointer (`PTR`) lookup using `drill`:

```bash
$ drill -x 140.82.121.4
```

**Output:**
```text
;; ->>HEADER<<- opcode: QUERY, rcode: NOERROR, id: 18402
;; flags: qr rd ra ; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 0
;; QUESTION SECTION:
;; 4.121.82.140.in-addr.arpa.	IN	PTR

;; ANSWER SECTION:
4.121.82.140.in-addr.arpa.	3600	IN	PTR	lb-140-82-121-4-iad.github.com.

;; AUTHORITY SECTION:

;; ADDITIONAL SECTION:

;; Query time: 18 msec
;; SERVER: 127.0.0.1
;; WHEN: Thu Aug 06 20:55:24 2026
;; MSG SIZE rcvd: 87
```

---

### 4.3 Querying SRV Service Discovery Records

Evaluating Service (`SRV`) records for HashiCorp Consul or Kubernetes cluster services:

```bash
$ host -t SRV _k8s-cat-port._tcp.my-service.default.svc.cluster.local
```

**Output:**
```text
_k8s-cat-port._tcp.my-service.default.svc.cluster.local has SRV record 0 100 8080 10-244-1-45.my-service.default.svc.cluster.local.
```

---

### 4.4 Auditing System-Wide NSS Layer via `getent`

Verifying host resolution through the OS `libc`/`nsswitch.conf` pipeline vs raw wire DNS. This command checks `/etc/hosts` first, respecting OS configuration rules:

```bash
$ getent hosts db-primary.internal
```

**Output:**
```text
10.240.5.50     db-primary.internal db-primary
```

---

### 4.5 Inspecting Unbound Runtime Cache Metrics

Using `unbound-control` to inspect cache hits, memory consumption, and operational health:

```bash
$ unbound-control stats_noreset
```

**Output:**
```text
total.num.queries=148592
total.num.cachehits=139201
total.num.cachemiss=9391
total.num.prefetch=4120
total.num.zero_ttl=102
total.num.recursivereplies=9391
total.requestlist.avg=0.42
total.requestlist.max=12
total.requestlist.overwritten=0
total.requestlist.exceeded=0
total.tcpusage=4
time.up=86400.221045
time.elapsed=86400.221045
mem.cache.rrset=67108864
mem.cache.message=33554432
mem.mod.iterator=16384
mem.mod.validator=524288
```

---

### 4.6 Real-Time Socket Tracing with `tcpdump`

Capturing client-side DNS queries to inspect wire flags, transaction IDs, and transport protocols:

```bash
$ sudo tcpdump -nn -i eth0 -s 0 'port 53'
```

**Output:**
```text
20:55:24.104921 IP 10.240.0.50.41092 > 10.240.0.10.53: 48291+ [1au] A? api.github.com. (43)
20:55:24.118204 IP 10.240.0.10.53 > 10.240.0.50.41092: 48291 2/0/1 CNAME dualstack.g.github.com., A 140.82.121.4 (98)
20:55:24.118310 IP 10.240.0.50.59821 > 10.240.0.10.53: 12049+ [1au] AAAA? api.github.com. (43)
20:55:24.132115 IP 10.240.0.10.53 > 10.240.0.50.59821: 12049 2/0/1 CNAME dualstack.g.github.com., AAAA 2606:50c0:8000::64 (110)
```

---

## 5. Verification & Troubleshooting Runbook

### 5.1 Production Diagnostic Flowchart

```
                          [DNS Failure Reported]
                                    |
                                    v
                     Is the issue system-wide or app-specific?
                                    |
        +---------------------------+---------------------------+
        |                                                       |
        v                                                       v
 [App-Specific Failure]                                [System-Wide Failure]
        |                                                       |
        v                                                       v
Run `getent hosts <domain>`                             Run `dig +trace <domain>` /
Check /etc/nsswitch.conf order                         `drill -TD <domain>`
Check /etc/hosts for static overrides                   Inspect wire latency
        |                                                       |
        +---------------------------+---------------------------+
                                    |
                                    v
                  Check /etc/resolv.conf configuration
                                    |
          +-------------------------+-------------------------+
          |                                                   |
          v                                                   v
[UDP Timeout / 5s Delay]                           [SERVFAIL / DNSSEC Error]
          |                                                   |
          v                                                   v
Add `single-request-reopen`                         Validate upstream trust anchors
Verify MTU / EDNS0 size (1232)                      Check system time sync (NTP)
Check iptables/pf conntrack table                   Verify EDNS0 `do` flag handling
```

---

### 5.2 Failure Scenarios & Emergency Remediation

#### Scenario A: The 5-Second Latency Spike (Netfilter/Conntrack Race Condition)
* **Symptom:** Microservices randomly experience 5.003-second delays during HTTP/gRPC requests. UDP packets are visibly dropped in firewall telemetry.
* **Root Cause:** Parallel `A` and `AAAA` requests share the same source port and sequence path, triggering a lock race condition in kernel connection tracking (`conntrack`).
* **Remediation:** Update `/etc/resolv.conf` options to include `single-request-reopen`. This forces `libc` to close the socket and open a new socket before transmitting the secondary query:
  ```ini
  options single-request-reopen
  ```

#### Scenario B: High Upstream Latency due to Search Domain Amplification
* **Symptom:** Upstream CoreDNS or Bind servers hit 100% CPU. Telemetry shows massive volumes of invalid queries (`app.production.svc.cluster.local.svc.cluster.local`).
* **Root Cause:** The `ndots` setting in `/etc/resolv.conf` is too high (e.g., `ndots:5`), forcing FQDN lookups with fewer dots to iterate through the entire `search` path.
* **Remediation:** Lower `ndots` to `2` or `1` in client configurations, or append a trailing dot (`.`) to absolute hostnames inside application code (e.g., `api.stripe.com.`):
  ```ini
  options ndots:2
  ```

#### Scenario C: Path MTU Blackhole Truncation (EDNS0 Buffer Drops)
* **Symptom:** `dig` queries with `+edns0` fail or hang, but basic short queries succeed. Large responses (e.g., DNSSEC signed records) time out.
* **Root Cause:** Upstream DNS returns a UDP payload larger than the Path MTU (e.g., 4096 bytes over a 1500 byte link), causing IP fragmentation. Firewalls or routers drop IP fragments.
* **Remediation:** Clamp the client-side EDNS0 buffer size in `/etc/unbound/unbound.conf` or `/etc/resolv.conf` to a safe threshold of `1232` bytes:
  ```yaml
  edns-buffer-size: 1232
  max-udp-size: 1232
  ```

#### Scenario D: `SERVFAIL` Returned on DNSSEC Validating Resolvers
* **Symptom:** Resolvers return `RCODE 2 (SERVFAIL)`. Direct unvalidated lookups succeed.
* **Root Cause:** System clock skew on the client host causes valid DNSSEC signature time windows (`RRSIG` inception and expiration timestamps) to be rejected as expired or not yet valid.
* **Remediation:** Synchronize client OS hardware clocks via NTP/Chrony and test validation:
  ```bash
  $ sudo chronyc tracking
  $ drill -D api.github.com
  ```

---

## 6. References

* **Linux Professional Institute (LPI) BSD Specialist Overview:**  
  https://www.lpi.org/our-certifications/bsd-specialist-overview/
* **LPI Wiki – Topic 714.4 Objectives:**  
  https://wiki.lpi.org/wiki/BSD_Specialist_Objectives_V1.0
* **FreeBSD Manual Pages – resolv.conf(5):**  
  https://man.freebsd.org/cgi/man.cgi?resolv.conf(5)
* **FreeBSD Manual Pages – nsswitch.conf(5):**  
  https://man.freebsd.org/cgi/man.cgi?nsswitch.conf(5)
* **NLnet Labs Unbound Documentation:**  
  https://nlnetlabs.nl/documentation/unbound/unbound.conf/
* **Kubernetes Official Documentation – NodeLocal DNSCache:**  
  https://kubernetes.io/docs/tasks/administer-cluster/nodelocaldns/
* **IETF RFC 6891 – Extension Mechanisms for DNS (EDNS(0)):**  
  https://datatracker.ietf.org/doc/html/rfc6891