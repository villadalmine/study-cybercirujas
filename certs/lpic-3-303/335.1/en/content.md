# 335.1 Common Security Vulnerabilities and Threats

**LPIC-3 Security — Exam 303-300, v3.0.0 · Topic 335 (Threats and Vulnerability Assessment) · Weight 3.33**

---

## 0. Scope map: objective → section

| Exam key knowledge area | Covered in |
|---|---|
| Terms: threat, vulnerability, exploit, risk, attack surface | §2 |
| CVE, CWE, CVSS, NVD (+ modern KEV/EPSS/VEX) | §3 |
| Buffer overflow (stack/heap), integer overflow, over-read | §4 |
| Race conditions, TOCTOU | §5 |
| Privilege escalation | §6 |
| Sniffing, ARP/DNS spoofing, MITM | §7 |
| DoS, DDoS, amplification, resource exhaustion | §8 |
| SQL injection, XSS, CSRF and web classes | §9 |
| Viruses, worms, trojans, rootkits, ransomware | §10 |
| Password attacks, phishing, social engineering | §11 |
| Side-channel attacks (Meltdown, Spectre, Rowhammer) | §12 |
| Supply-chain compromise (modern addition) | §13 |
| Operationalisation, verification, diagnosis | §14–§15 |

---

## 1. The production problem

A vulnerability is not an event. It is a **latency problem**.

Consider a realistic fleet: 400 Linux hosts (mixed RHEL 9 / Debian 12), 60 container images, 9 000 distinct package-version tuples. On any given Tuesday, the NVD publishes on the order of 100–150 new CVEs. Of those, perhaps 3 affect your fleet. Of those 3, perhaps 1 is reachable from an untrusted network, and perhaps 1 in 40 working days is *both* reachable and has public exploit code within 24 hours.

The naive architecture — "subscribe to a mailing list, patch when someone notices" — fails on three independent axes:

1. **Signal-to-noise.** A CVSS-only policy ("patch everything ≥ 7.0 in 7 days") generates thousands of tickets per quarter, of which the overwhelming majority are unexploitable in your configuration. Teams then miss the one that matters *because* they are drowning in the ones that do not.
2. **Discovery lag.** You cannot patch what you cannot enumerate. Without an authoritative inventory (package DB + SBOM + running-process map), "are we affected by CVE-2024-3094?" is answered by Slack archaeology, not by a query.
3. **Verification lag.** Installing a package does **not** remediate a vulnerability if the vulnerable code is still mapped into a long-running process. `openssl` upgraded, `nginx` not restarted = still exploitable, with a green dashboard.

The architectural response is to treat vulnerability management as an **SRE control loop** with an explicit error budget:

```
inventory ──▶ match(CVE feed) ──▶ triage(reachability, KEV, EPSS) ──▶ remediate ──▶ VERIFY ──▶ inventory
    ▲                                                                                    │
    └────────────────────────────── drift detection ─────────────────────────────────────┘
```

Every stage in that loop must be a command that returns an exit code, not a human judgement. This topic gives you the taxonomy the loop operates on: **you cannot write a triage rule for a vulnerability class you cannot name.**

The rest of the material is organised by *class* rather than by *CVE*, because the individual CVE is ephemeral and the class is not. Stack overflows have been exploited since 1988 (Morris worm, `fingerd`) and were still shipping in 2021 (`sudo` Baron Samedit). The class is the durable knowledge; the CVE is the instance.

---

## 2. Vocabulary the exam grades and production depends on

These terms are frequently confused, and the exam tests the distinction directly.

| Term | Definition | Concrete example |
|---|---|---|
| **Asset** | Anything with value to the organisation | Customer database, signing key, `/etc/shadow` |
| **Threat** | A potential cause of an unwanted incident | "A remote attacker executes code as root" |
| **Threat actor** | The entity behind a threat | Script kiddie, criminal group, insider, state actor |
| **Vulnerability** | A weakness that a threat can exploit | Unpatched `sudo` 1.9.5p1 (CVE-2021-3156) |
| **Exploit** | Code/technique that turns a vulnerability into an effect | The heap-overflow PoC for that CVE |
| **Attack vector** | The path used to reach the vulnerability | Local shell, network socket, malicious file |
| **Attack surface** | Sum of all reachable entry points | Open ports + SUID binaries + parsers |
| **Risk** | Likelihood × Impact, over a given asset | "High: internet-facing, RCE, holds PII" |
| **Control** | A measure that reduces risk | Patch, firewall rule, SELinux policy, MFA |
| **Residual risk** | Risk remaining after controls | Accepted and signed off, or not accepted |
| **0-day** | Vulnerability with no vendor fix available | Log4Shell on 2021-12-09 |
| **n-day** | Vulnerability with a fix available but unapplied | Log4Shell on 2022-06-01 — the real killer |
| **Blast radius** | Extent of damage if the control fails | One container vs. the whole node vs. the cluster |

**The critical relationship**: `Risk = Threat × Vulnerability × Impact`. Removing *any* factor removes the risk. This is why "the vulnerable service is not listening on any interface" is a legitimate remediation, and why compensating controls (network segmentation, SELinux confinement, `noexec` mounts) reduce risk without patching a single byte.

### 2.1 CIA triad — and what it means operationally

| Property | Question it answers | Broken by | Typical control |
|---|---|---|---|
| **Confidentiality** | Who can read it? | Sniffing, side channel, IDOR, data leak | TLS, LUKS, DAC/MAC, least privilege |
| **Integrity** | Can I prove it was not altered? | MITM, rootkit, supply chain, SQLi UPDATE | Signatures, AIDE, dm-verity, IMA |
| **Availability** | Is it there when needed? | DoS/DDoS, ransomware, fork bomb | Rate limits, quotas, replicas, backups |

Extended in practice with **Authenticity**, **Non-repudiation** (audit logs, signed commits) and **Accountability** (AAA: Authentication, Authorization, Accounting).

Note the **trade-off you will actually face**: hardening against confidentiality/integrity attacks often costs availability. `fail2ban` with an aggressive threshold turns a password-spray into a self-inflicted DoS when a misconfigured client loops. Full Spectre mitigations cost measurable throughput. Security engineering is the discipline of choosing *which* leg of the triad to spend.

---

## 3. The identifier stack: CWE, CVE, CVSS, NVD, KEV, EPSS

These are four orthogonal things. The exam expects you to know which is which.

| Identifier | Answers | Scope | Example |
|---|---|---|---|
| **CWE** | *What kind of bug is it?* | Class / taxonomy | CWE-121: Stack-based Buffer Overflow |
| **CVE** | *Which product instance?* | One vuln in one product | CVE-2021-3156 (sudo) |
| **CVSS** | *How bad, technically?* | Severity 0.0–10.0 | 7.8 HIGH |
| **EPSS** | *How likely to be exploited?* | Probability 0–1, 30-day | 0.94 (94 %) |
| **KEV** | *Is it exploited right now?* | Boolean, observed in the wild | Yes / No |

**NVD** (National Vulnerability Database, NIST) is the enrichment layer over the CVE list: it adds CVSS scores, CWE mapping and CPE (Common Platform Enumeration) applicability statements. **MITRE** assigns the CVE ID; **CNAs** (CVE Numbering Authorities — Red Hat, Canonical, Google, GitHub…) allocate IDs within their scope. Distributions publish their *own* advisories, which are the authoritative ones for you: **RHSA** (Red Hat), **DSA/DLA** (Debian), **USN** (Ubuntu), **SUSE-SU**, **openSUSE-SU**.

> **Backporting trap.** Debian's `openssl 3.0.11-1~deb12u2` may be immune to a CVE that "affects OpenSSL < 3.0.14". Distributions backport security fixes without bumping the upstream version. Version-string scanners produce false positives on stable distros; always cross-check against the distribution's OVAL/security tracker data.

### 3.1 Reading a CVSS v3.1 vector

```
CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:C/C:H/I:H/A:H   →  10.0 CRITICAL   (CVE-2021-44228, Log4Shell)
CVSS:3.1/AV:L/AC:L/PR:L/UI:N/S:U/C:H/I:H/A:H   →   7.8 HIGH       (CVE-2021-4034, PwnKit)
```

| Metric | Values | Meaning |
|---|---|---|
| **AV** Attack Vector | N / A / L / P | Network, Adjacent, Local, Physical |
| **AC** Attack Complexity | L / H | Low, High (requires special conditions) |
| **PR** Privileges Required | N / L / H | None, Low, High |
| **UI** User Interaction | N / R | None, Required |
| **S** Scope | U / C | Unchanged, **Changed** (escapes its security authority — VM escape, container escape) |
| **C/I/A** | N / L / H | Impact on Confidentiality / Integrity / Availability |

Base score ranges: 0.1–3.9 LOW, 4.0–6.9 MEDIUM, 7.0–8.9 HIGH, 9.0–10.0 CRITICAL.

Two derived groups exist and are almost always ignored, to everyone's cost:
- **Temporal** (v3.1): Exploit Code Maturity, Remediation Level, Report Confidence.
- **Environmental** (v3.1): lets *you* re-score for *your* deployment — e.g. `CR:H/MAV:A` for a host reachable only from a management VLAN.

**CVSS v4.0** (published 2023-11) restructures this into **CVSS-B / -BT / -BE / -BTE**, splits impact into *Vulnerable System* and *Subsequent System* (replacing Scope), adds **AT** (Attack Requirements) and expands UI into N/P/A (None, Passive, Active). Expect a v3.1-focused exam, but recognise v4.0 vectors in the wild.

### 3.2 Triage inputs compared

| Input | Strength | Weakness | Use it for |
|---|---|---|---|
| CVSS base | Universal, vendor-agnostic, offline | Says nothing about *your* exposure or exploitation; ~58 % of NVD CVEs are ≥7.0 | Floor filter only |
| CVSS environmental | Reflects your topology | Requires manual per-CVE work | Crown-jewel assets |
| **EPSS** (FIRST) | Data-driven exploitation probability, updated daily | Probabilistic, not a guarantee; poor on brand-new CVEs | Ordering the queue |
| **CISA KEV** | Ground truth: it *is* being exploited | Lagging, US-gov-centric, sparse | Drop-everything trigger |
| Reachability / VEX | Kills most false positives (unreachable code paths) | Needs SBOM + vendor VEX statements | Suppressing noise honestly |

A defensible production policy combines them:

```
if in_KEV:                      SLO = 24 h    (emergency change)
elif EPSS >= 0.10 and CVSS>=7:  SLO = 7 d
elif CVSS >= 9.0:               SLO = 14 d
elif CVSS >= 7.0:               SLO = 30 d
else:                           SLO = next monthly patch window
```

### 3.3 Querying the feeds from the CLI

```bash
$ curl -s "https://services.nvd.nist.gov/rest/json/cves/2.0?cveId=CVE-2021-4034" \
  | jq -r '.vulnerabilities[0].cve
      | "\(.id)  \(.metrics.cvssMetricV31[0].cvssData.baseScore) \
\(.metrics.cvssMetricV31[0].cvssData.baseSeverity)\n\(.descriptions[0].value)"'
CVE-2021-4034  7.8 HIGH
A local privilege escalation vulnerability was found on polkit's pkexec utility. The
pkexec application is a setuid tool designed to allow unprivileged users to run
commands as privileged users according predefined policies.
```

```bash
$ curl -s https://api.first.org/data/v1/epss?cve=CVE-2021-4034 \
  | jq -r '.data[] | "EPSS \(.epss)  percentile \(.percentile)"'
EPSS 0.94129  percentile 0.99912
```

Distribution-native matching is faster and has no false positives from backporting:

```bash
# RHEL / Fedora
$ dnf updateinfo list --security
Last metadata expiration check: 0:12:44 ago on Tue 25 Aug 2026 09:02:11 -03.
RHSA-2026:4471 Important/Sec. kernel-5.14.0-427.42.1.el9_4.x86_64
RHSA-2026:4488 Moderate/Sec.  openssl-1:3.0.7-27.el9_4.x86_64
$ dnf updateinfo info --cve CVE-2026-21432 | head -12

# Debian / Ubuntu
$ debsecan --suite bookworm --format detail --only-fixed
CVE-2026-2153 openssl (remotely exploitable, high urgency)
  fixed in 3.0.16-1~deb12u1
$ apt list --upgradable 2>/dev/null | grep -i security | head -5
libssl3/stable-security 3.0.16-1~deb12u1 amd64 [upgradable from: 3.0.15-1~deb12u1]
```

---

## 4. Memory-safety vulnerabilities

Roughly 60–70 % of critical CVEs in C/C++ codebases (Microsoft's and Google's independently published figures both land in that band) are memory-safety issues. This is the single most important vulnerability family in systems software.

### 4.1 Stack-based buffer overflow (CWE-121)

The mechanism: a fixed-size buffer lives in the function's stack frame. On x86-64 the frame grows *down* but writes go *up*, so overflowing a local buffer overwrites — in order — other locals, the saved frame pointer, and the **saved return address**. Control the return address, control `RIP`.

```c
/* vuln.c — deliberately unsafe; for study only */
#include <stdio.h>
#include <string.h>

void handle(const char *input) {
    char name[16];
    strcpy(name, input);          /* CWE-120: no bounds check */
    printf("Hello, %s\n", name);
}

int main(int argc, char **argv) {
    if (argc > 1) handle(argv[1]);
    return 0;
}
```

Compiled with every modern protection deliberately disabled, so the failure is visible:

```bash
$ gcc -fno-stack-protector -z execstack -no-pie -O0 -o vuln vuln.c
$ ./vuln AAAA
Hello, AAAA
$ ./vuln $(python3 -c 'print("A"*80)')
Hello, AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
Segmentation fault (core dumped)
```

```bash
$ gdb -q ./vuln
Reading symbols from ./vuln...
(gdb) run $(python3 -c 'print("A"*80)')
Program received signal SIGSEGV, Segmentation fault.
0x0000000000401156 in handle ()
(gdb) x/1gx $rsp
0x7fffffffe3a8: 0x4141414141414141
(gdb) info frame
Stack level 0, frame at 0x7fffffffe3b0:
 rip = 0x401156 in handle; saved rip = 0x4141414141414141
```

`saved rip = 0x4141414141414141` is the definitive signature: the return address is now attacker-controlled ASCII `AAAAAAAA`.

Now rebuild with the distribution's default hardening:

```bash
$ gcc -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=3 -fPIE -pie -Wl,-z,relro,-z,now -o safe vuln.c
$ ./safe $(python3 -c 'print("A"*80)')
*** buffer overflow detected ***: terminated
Aborted (core dumped)
$ dmesg | tail -2
[  914.223118] traps: safe[5312] general protection fault ip:7f3a2c0a1e2b sp:7ffd...
```

`_FORTIFY_SOURCE` turned an exploitable memory corruption into a clean `abort()` — availability lost, confidentiality and integrity preserved. That trade is almost always correct.

### 4.2 Heap overflow, use-after-free, double free (CWE-122, CWE-416, CWE-415)

Heap metadata (glibc `tcache`, `fastbins`, chunk headers) is inline with user data. Overflowing a `malloc`'d buffer corrupts the next chunk's header; glibc's allocator then writes attacker-influenced pointers during `free()`/`malloc()`. **Use-after-free** re-uses a dangling pointer after its chunk has been recycled into a different object — the classic route to type confusion. glibc has hardening checks that surface as distinctive aborts:

```bash
$ ./heapdemo
free(): invalid next size (fast)
Aborted (core dumped)

$ ./uaf
free(): double free detected in tcache 2
Aborted (core dumped)

$ GLIBC_TUNABLES=glibc.malloc.check=3 ./heapdemo
malloc: invalid size (unsorted)
Aborted (core dumped)
```

Real-world exemplar: **CVE-2021-3156 "Baron Samedit"** — `sudoedit -s '\'` caused `sudo` to read past a command-line argument and write a heap overflow, reachable by *any* local user, no `sudoers` entry required, present since 2011.

### 4.3 Integer overflow / underflow (CWE-190/191)

Rarely dangerous alone; lethal when it feeds a size computation.

```c
size_t n = user_count;             /* attacker: 0x40000001 */
char *buf = malloc(n * 4);         /* 0x100000004 truncated to 4 on 32-bit → malloc(4) */
for (size_t i = 0; i < n; i++)     /* writes 1 GiB into a 4-byte buffer */
    buf[i*4] = data[i];
```

Signed overflow in C is *undefined behaviour*, so the compiler may delete your "check": `if (a + b < a)` is optimised away. Correct patterns are `__builtin_mul_overflow()`, `reallocarray(3)`, or explicit division checks. Build with `-ftrapv` / `-fsanitize=signed-integer-overflow` in CI.

### 4.4 Buffer over-read (CWE-125) — the Heartbleed shape

**CVE-2014-0160**: OpenSSL's TLS heartbeat trusted an attacker-supplied length field and `memcpy`'d up to 64 KiB out of the process heap back to the client. No crash, no log entry, no memory *write* — pure confidentiality loss, repeatable, and it leaked private keys and session cookies. This is why "it didn't crash" is not evidence of safety, and why passive network logging cannot detect every attack.

### 4.5 Exploit mitigation matrix

| Mitigation | Stops | Typical bypass | Cost | Check it |
|---|---|---|---|---|
| **NX / DEP** (`W^X`) | Executing injected shellcode on stack/heap | ROP / ret2libc | ~0 % | `checksec`, `readelf -lW \| grep GNU_STACK` |
| **ASLR** (`randomize_va_space=2`) | Hardcoded addresses | Info leak, brute force on 32-bit, non-PIE binaries | ~0–1 % | `sysctl kernel.randomize_va_space` |
| **PIE** | Fixed binary base (needed for ASLR to cover the exe) | Leak of any code address | ~1–3 % on x86-64 | `checksec` → `PIE enabled` |
| **Stack canary** (`-fstack-protector-strong`) | Sequential stack smashes over the return address | Direct/indexed writes, canary leak, fork-server brute force | ~1–2 % | `checksec` → `Canary found` |
| **Full RELRO** (`-z relro -z now`) | GOT overwrite | Other writable function pointers | Slower startup | `checksec` → `Full RELRO` |
| **FORTIFY_SOURCE=2/3** | Overflows in known-size `str*`/`mem*` calls | Unfortified custom copy loops | ~0–1 % | `hardening-check`, `checksec --fortify-file` |
| **CET IBT + Shadow Stack** | ROP/JOP (returns and indirect jumps) | Hardware + glibc + kernel support required | ~1–2 % | `grep -o 'ibt\|shstk' /proc/cpuinfo` |
| **CFI / kCFI** | Indirect-call hijack | Same-signature target reuse | 1–5 % | Kernel `CONFIG_CFI_CLANG` |
| **Memory-safe language** | The entire class | Unsafe blocks, FFI boundaries | Rewrite cost | — |

```bash
$ checksec --file=/usr/sbin/sshd
RELRO        STACK CANARY  NX          PIE       RPATH     RUNPATH   Symbols  FORTIFY  Fortified  FILE
Full RELRO   Canary found  NX enabled  PIE enab  No RPATH  No RUNPATH  No Symb   Yes      27       /usr/sbin/sshd

$ sysctl kernel.randomize_va_space
kernel.randomize_va_space = 2

$ for i in 1 2 3; do setarch --addr-no-randomize true; ldd /bin/ls | grep libc; done   # ASLR off → identical
        libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007ffff7c00000)
$ for i in 1 2 3; do ldd /bin/ls | grep libc; done                                    # ASLR on  → varies
        libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f2ad9a00000)
        libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f8c14200000)
        libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007fbb31000000)
```

Fleet-wide audit of unhardened binaries:

```bash
$ find /usr/bin /usr/sbin -type f -executable -print0 \
  | xargs -0 -P4 -n1 checksec --output=json --file 2>/dev/null \
  | jq -r 'to_entries[] | select(.value.canary=="no" or .value.nx=="no")
           | "\(.key)  canary=\(.value.canary) nx=\(.value.nx) relro=\(.value.relro)"'
/usr/bin/legacy-agent  canary=no nx=yes relro=partial
```

---

## 5. Race conditions and TOCTOU (CWE-362, CWE-367)

A **race condition** exists when the correctness of an operation depends on the relative timing of concurrent actors. **TOCTOU** (Time-of-Check to Time-of-Use) is the security-relevant special case: the state validated at check time is no longer true at use time.

### 5.1 The canonical filesystem TOCTOU

```c
/* WRONG: check and use are two syscalls with a window between them */
if (access("/tmp/report.tmp", W_OK) == 0) {      /* CHECK  (as root, tests real UID) */
    fd = open("/tmp/report.tmp", O_WRONLY);      /* USE    — attacker swapped it for
                                                    a symlink to /etc/shadow in between */
    write(fd, buf, len);
}
```

Two independent bugs: `access(2)` is *never* the right check for a privileged process (it tests the real UID, not the effective one — that is precisely what the man page warns about), and the path is re-resolved at `open()`.

**Correct patterns:**

| Anti-pattern | Correct replacement |
|---|---|
| `access()` then `open()` | `open()` then check with `fstat()` on the **fd** |
| `mktemp()` / predictable `/tmp/foo.$$` | `mkstemp()` / `mkdtemp()` / `systemd` `PrivateTmp=yes` |
| `open(path, O_CREAT)` in a shared dir | `open(path, O_CREAT\|O_EXCL\|O_NOFOLLOW, 0600)` |
| `stat()` then `chown()` | `fchown()` on the already-open fd |
| Path traversal across untrusted dirs | `openat2(2)` with `RESOLVE_NO_SYMLINKS\|RESOLVE_BENEATH` |

Kernel-level mitigations for the sticky-directory symlink class:

```bash
$ sysctl fs.protected_symlinks fs.protected_hardlinks fs.protected_fifos fs.protected_regular
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 1
fs.protected_regular = 2
```

`fs.protected_symlinks=1` makes the kernel refuse to follow a symlink in a world-writable sticky directory when the symlink owner ≠ the directory owner ≠ the following process's UID — it kills a large fraction of historical `/tmp` races outright.

### 5.2 Signal-handler races — CVE-2024-6387 ("regreSSHion")

The 2024 OpenSSH pre-auth RCE is the exam-grade modern example. `sshd`'s `SIGALRM` handler (login grace timeout) called `syslog()`, which is **not async-signal-safe**. If the alarm fired while the main thread was inside `malloc()`/`free()`, the handler re-entered the allocator and corrupted the heap — reachable by an unauthenticated remote client that simply stalls the handshake. Affected glibc-based Linux with OpenSSH 8.5p1–9.7p1; scored CVSS 8.1 (`AV:N/AC:H/PR:N/UI:N/S:U/C:H/I:H/A:H` — note `AC:H`, because winning the race takes thousands of attempts).

Mitigation without patching, and the diagnostic:

```bash
$ ssh -V
OpenSSH_9.6p1 Ubuntu-3ubuntu13.4, OpenSSL 3.0.13 30 Jan 2024
$ grep -E '^LoginGraceTime' /etc/ssh/sshd_config
LoginGraceTime 0            # disables the alarm → removes the trigger, at the cost of
                            # unbounded half-open sessions (pair with MaxStartups)
$ sudo sshd -T | grep -E 'logingracetime|maxstartups'
logingracetime 0
maxstartups 10:30:60
```

### 5.3 Other race families

- **Dirty COW (CVE-2016-5195)** — race between `madvise(MADV_DONTNEED)` and the COW fault handler, letting a local user write to read-only file mappings, e.g. `/usr/bin/passwd`. Universal Linux LPE, 2007–2016.
- **Dirty Pipe (CVE-2022-0847)** — uninitialised `pipe_buffer.flags` allowed overwriting page-cache pages of *read-only* files (kernel 5.8 → 5.16.11/5.15.25/5.10.102). Trivially weaponised to edit `/etc/passwd`.
- **`sudo`/`su` TTY hijack**, double-fetch bugs in ioctl handlers (`copy_from_user` twice), and TOCTOU in container runtimes (**CVE-2019-5736**, `runc` `/proc/self/exe` overwrite → host escape).

---

## 6. Privilege escalation

Escalation is **vertical** (user → root) or **horizontal** (user A → user B). The attacker's checklist is the defender's audit list.

### 6.1 SUID/SGID inventory

```bash
$ find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%M %u %g %p\n' 2>/dev/null | sort -k4
-rwsr-xr-x root root /usr/bin/chfn
-rwsr-xr-x root root /usr/bin/chsh
-rwsr-xr-x root root /usr/bin/gpasswd
-rwsr-xr-x root root /usr/bin/mount
-rwsr-xr-x root root /usr/bin/newgrp
-rwsr-xr-x root root /usr/bin/passwd
-rwsr-xr-x root root /usr/bin/su
-rwsr-xr-x root root /usr/bin/sudo
-rwsr-xr-x root root /usr/bin/umount
-rwsr-xr-x root root /usr/libexec/openssh/ssh-keysign
-rwxr-sr-x root shadow /usr/sbin/unix_chkpwd
-rwsr-xr-x root root /opt/vendor/bin/collector        <-- NOT from a package: investigate
```

Any SUID binary outside the distribution's own set is a finding. Verify ownership:

```bash
$ rpm -qf /opt/vendor/bin/collector
file /opt/vendor/bin/collector is not owned by any package
$ dpkg -S /opt/vendor/bin/collector
dpkg-query: no path found matching pattern /opt/vendor/bin/collector
```

The class of attack is documented publicly as **GTFOBins**: legitimate SUID binaries with a feature that spawns a shell or reads arbitrary files (`find -exec`, `vim :!sh`, `awk 'BEGIN{system()}'`, `less !sh`, `env`, `nmap --interactive` historically).

### 6.2 File capabilities — the modern, quieter variant

```bash
$ getcap -r /usr /opt 2>/dev/null
/usr/bin/ping cap_net_raw=ep
/usr/bin/newgidmap cap_setgid=ep
/usr/bin/newuidmap cap_setuid=ep
/opt/telemetry/bin/agent cap_dac_read_search,cap_sys_ptrace=ep     <-- root-equivalent
```

`CAP_DAC_READ_SEARCH` reads every file on the box (including `/etc/shadow` and SSH host keys). `CAP_SYS_PTRACE` attaches to any process. `CAP_SYS_ADMIN`, `CAP_SYS_MODULE`, `CAP_DAC_OVERRIDE`, `CAP_SETUID`, `CAP_BPF`, `CAP_SYS_RAWIO` are all effectively equivalent to root. A capability inventory is **not** less dangerous than a SUID inventory — it is the same inventory, less visible to `ls -l`.

### 6.3 `sudo` misconfiguration

```bash
$ sudo -l
Matching Defaults entries for jdoe on app01:
    env_reset, mail_badpass, secure_path=/usr/sbin:/usr/bin:/sbin:/bin

User jdoe may run the following commands on app01:
    (root) NOPASSWD: /usr/bin/systemctl restart app*      <-- wildcard: "app../../../bin/sh"
    (root) /usr/bin/vi /etc/app/config.yaml               <-- vi → :!/bin/bash
    (root) SETENV: /opt/app/deploy.sh                     <-- SETENV lets LD_PRELOAD through
```

Every line above is an escalation. Rules: no wildcards in paths, no editors (use `sudoedit`, which drops privileges to edit), no `SETENV`, no interpreters, no `sudo ALL, !/bin/su`-style negation (trivially bypassed by copying the binary).

### 6.4 Environment and library hijacking

- **`PATH` injection** against a script that calls `tar` instead of `/usr/bin/tar` — mitigated by `Defaults secure_path`.
- **`LD_PRELOAD` / `LD_LIBRARY_PATH` / `LD_AUDIT`** — the dynamic loader ignores these in *secure-execution mode* (SUID/SGID/capability binaries), which is exactly why they must never be re-enabled via `sudo SETENV`. Historical bypass: **CVE-2010-3856** (`LD_AUDIT` on SUID binaries), and **CVE-2023-4911 "Looney Tunables"** (buffer overflow parsing `GLIBC_TUNABLES` in `ld.so`, local root on glibc ≥ 2.34).
- **Writable `$ORIGIN`/RPATH directories**: `readelf -d bin | grep -E 'RPATH|RUNPATH'`.

### 6.5 Kernel LPE — the class that ignores all your userspace hardening

| CVE | Name | Mechanism | Fixed in |
|---|---|---|---|
| CVE-2016-5195 | Dirty COW | COW/madvise race | 4.8.3 and backports |
| CVE-2021-4034 | PwnKit | `pkexec` argv[0]==NULL → env re-injection | polkit 0.120-x |
| CVE-2021-22555 | — | Netfilter `xt_compat` heap OOB write | 5.12 |
| CVE-2022-0847 | Dirty Pipe | Uninit `pipe_buffer.flags` | 5.16.11 / 5.15.25 / 5.10.102 |
| CVE-2022-0185 | — | Legacy `fs_context` int underflow, via user ns | 5.16.2 |
| CVE-2023-0386 | — | OverlayFS SUID copy-up | 6.2 |
| CVE-2023-32233 | — | nf_tables UAF in anonymous sets | 6.4-rc |

The recurring enabler is **unprivileged user namespaces**, which expose thousands of lines of kernel attack surface (netfilter, overlayfs, fs_context) to any local user. Restrict them when your workload does not need them:

```bash
# Debian/Ubuntu
$ sudo sysctl -w kernel.unprivileged_userns_clone=0
# Upstream / RHEL
$ sudo sysctl -w user.max_user_namespaces=0
# Ubuntu 24.04+ AppArmor-based restriction
$ sysctl kernel.apparmor_restrict_unprivileged_userns
kernel.apparmor_restrict_unprivileged_userns = 1
```

> **Trade-off**: this breaks rootless Podman, `bwrap`-based Flatpak, and unprivileged containers. Decide per host role, not fleet-wide by reflex.

### 6.6 Hardening levers with their costs

| Lever | Blocks | Breaks |
|---|---|---|
| `nosuid,nodev,noexec` on `/tmp`, `/var/tmp`, `/home`, `/dev/shm` | SUID drops, dropped payloads | Package post-install scripts using `/tmp`, some build tooling |
| `kernel.yama.ptrace_scope=1` (or 2/3) | Process memory scraping between peers | `gdb -p`, `strace -p` without root |
| `kernel.kptr_restrict=2`, `kernel.dmesg_restrict=1` | Kernel-address leaks for exploit reliability | perf tooling, some crash triage |
| Kernel **lockdown** (`integrity`/`confidentiality`) | `/dev/mem`, unsigned modules, kexec | DKMS drivers, hibernation |
| Module signature enforcement | Kernel rootkits | Out-of-tree drivers |
| SELinux `enforcing` / AppArmor | Post-exploit lateral movement | Anything with a wrong label |
| `systemd` unit sandboxing | Escalation from a compromised service | Services needing broad access |

```bash
$ systemd-analyze security nginx.service | tail -20
  NAME                                                     DESCRIPTION                    EXPOSURE
✗ PrivateNetwork=                                          Service has access to the host…      0.5
✗ User=/DynamicUser=                                       Service runs as root                 0.4
✓ CapabilityBoundingSet=~CAP_SYS_ADMIN                     Service has no administrator…
✗ RestrictAddressFamilies=~AF_PACKET                       Service may allocate packet…         0.1
✗ ProtectSystem=                                           Service has full access to the…      0.2
→ Overall exposure level for nginx.service: 8.4 EXPOSED 🙁

$ systemd-analyze security nginx.service | tail -3     # after applying the drop-in below
→ Overall exposure level for nginx.service: 2.1 OK 🙂
```

```ini
# /etc/systemd/system/nginx.service.d/10-hardening.conf
[Service]
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
RestrictSUIDSGID=yes
RestrictRealtime=yes
RestrictNamespaces=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @obsolete
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
ReadWritePaths=/var/log/nginx /var/lib/nginx /run
```

`MemoryDenyWriteExecute=yes` is the one to test carefully: it breaks any runtime that JITs (Java, Node, LuaJIT, PHP with JIT enabled).

---

## 7. Network-layer threats

### 7.1 Sniffing (passive interception)

On a hub or a wireless network in monitor mode, all traffic is visible. On a switch, an attacker must either be on a mirror port, be the gateway, or force the switch to behave like a hub — **MAC flooding** (`macof`) overflows the CAM table until the switch fails open and floods all frames.

```bash
$ sudo tcpdump -ni eth0 -c 5 'tcp port 23 or tcp port 21 or port 161'
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
10:14:02.113455 IP 10.10.5.31.51422 > 10.10.5.9.23: Flags [P.], seq 1:9, ack 1, length 8
10:14:02.115901 IP 10.10.5.31.51422 > 10.10.5.9.23: Flags [P.], seq 9:10, ack 1, length 1
5 packets captured
```

Detection of a local sniffer: an interface in promiscuous mode.

```bash
$ ip -d link show eth0 | head -2
2: eth0: <BROADCAST,MULTICAST,PROMISC,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP mode DEFAULT
$ dmesg | grep -i promisc
[ 8291.4471] device eth0 entered promiscuous mode
```

**The only durable mitigation is encryption in transit.** Port security, DAI and 802.1X raise the bar; TLS/IPsec/WireGuard remove the value of the capture.

### 7.2 ARP spoofing → MITM (CWE-290)

ARP has no authentication: any host may gratuitously announce that it owns an IP. The attacker poisons the victim's and the gateway's caches, becoming a transparent relay.

```bash
# Victim's view during an attack — gateway and attacker share a MAC
$ ip neigh show
10.10.5.1 dev eth0 lladdr 52:54:00:aa:bb:cc REACHABLE     <-- gateway
10.10.5.66 dev eth0 lladdr 52:54:00:aa:bb:cc REACHABLE    <-- attacker, SAME MAC
$ arpwatch -d -i eth0
From: arpwatch (Arpwatch)
Subject: changed ethernet address (gateway)
          hostname: gw.corp.example
        ip address: 10.10.5.1
  ethernet address: 52:54:00:aa:bb:cc
   ethernet vendor: QEMU
 old ethernet addr: 52:54:00:11:22:33
```

| Mitigation | Layer | Cost |
|---|---|---|
| Static ARP entries (`ip neigh add ... nud permanent`) | Host | Unmanageable at scale |
| Dynamic ARP Inspection + DHCP snooping | Switch | Requires managed switches, DHCP-only |
| 802.1X port authentication | Switch | PKI + RADIUS infrastructure |
| `arpwatch` / `arpon` | Host detection | Alerting only, does not prevent |
| Authenticated transport (TLS with pinning, IPsec, WireGuard) | Application/network | **Removes the impact regardless** |

### 7.3 DNS spoofing and cache poisoning

Off-path poisoning must guess the 16-bit transaction ID *and* the source port. The **Kaminsky attack (2008)** made this practical by triggering unlimited attempts against non-existent subdomains and injecting a poisoned authority record. The response was **source-port randomisation** (raising the entropy to ~32 bits), later **DNS cookies (RFC 7873)** and **0x20 encoding**. The structural fix is **DNSSEC**: origin authentication and integrity for the record set (not confidentiality — that is **DoT/DoH/DoQ**).

```bash
$ dig +dnssec +multiline example.com A | grep -E 'flags|RRSIG' | head -3
;; flags: qr rd ra ad; QUERY: 1, ANSWER: 2, AUTHORITY: 0, ADDITIONAL: 1
example.com.  3600 IN RRSIG A 13 2 3600 (

$ delv example.com A
; fully validated
example.com.            3600    IN      A       93.184.215.14
example.com.            3600    IN      RRSIG   A 13 2 3600 20260910000000 ...
```

The `ad` (Authenticated Data) flag and `delv`'s `; fully validated` are the two things to check. If `ad` is missing, either the zone is unsigned or your resolver is not validating.

### 7.4 Man-in-the-Middle against TLS

| Technique | Mechanism | Defence |
|---|---|---|
| **SSL stripping** | Rewrites `https://` links to `http://` on a plaintext landing page | HSTS + preload list, HTTPS-only redirects |
| **Downgrade** (POODLE, FREAK, Logjam, DROWN) | Forces obsolete protocol/cipher/keysize | Disable SSLv3/TLS1.0/1.1, export ciphers; `TLS_FALLBACK_SCSV` |
| **Rogue/mis-issued certificate** | Attacker-controlled or compromised CA | Certificate Transparency, CAA records, pinning, short-lived certs |
| **Corporate TLS interception** | Enterprise root CA installed on endpoints | Recognise it; pin critical flows; policy |

```bash
$ openssl s_client -connect target.example:443 -tls1_1 </dev/null 2>&1 | head -3
80B7...:error:0A0000102:SSL routines:ssl_choose_client_version:unsupported protocol
   # correct: legacy protocol refused

$ nmap --script ssl-enum-ciphers -p 443 target.example
PORT    STATE SERVICE
443/tcp open  https
| ssl-enum-ciphers:
|   TLSv1.2:
|     ciphers:
|       TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 (secp256r1) - A
|   TLSv1.3:
|     ciphers:
|       TLS_AKE_WITH_AES_256_GCM_SHA384 - A
|_  least strength: A
```

### 7.5 Other L2/L3 abuses

Rogue DHCP servers (mitigation: DHCP snooping), IPv6 Router Advertisement flooding and rogue RAs (**RA-Guard**; note that an IPv6-unaware IPv4-only firewall policy is bypassed entirely by an attacker-supplied RA), STP root-bridge takeover (BPDU Guard), VLAN hopping via DTP/double-tagging (disable DTP, never use VLAN 1 as native), and **off-path TCP RST/data injection** (mitigated by sequence-number randomisation and by encrypting/authenticating the session — the reason `tcp_md5sig`/TCP-AO exists for BGP).

---

## 8. Denial of Service

| Category | Attacker cost | Mechanism | Example |
|---|---|---|---|
| **Volumetric** | High bandwidth, or amplification | Saturate the pipe | UDP flood, DNS/NTP/memcached amplification |
| **Protocol / state exhaustion** | Low | Exhaust a finite kernel/app table | SYN flood, conntrack table fill, TLS renegotiation |
| **Application layer** | Very low | Exhaust an expensive resource per request | Slowloris, HTTP/2 Rapid Reset, ReDoS, zip bombs, expensive search queries |
| **Local resource exhaustion** | Trivial | Consume fds, PIDs, inodes, memory | Fork bomb, inode exhaustion in `/tmp` |

### 8.1 SYN flood mechanics

The three-way handshake requires the server to allocate state on `SYN` and hold it until `ACK` or timeout. Spoofed source addresses mean the `ACK` never arrives; the SYN backlog fills; legitimate connections are refused.

```bash
$ ss -s
Total: 2841
TCP:   9482 (estab 112, closed 84, orphaned 0, timewait 84)
                   ^^^^ SYN-RECV dominating

$ ss -tn state syn-recv | wc -l
8129

$ nstat -az | grep -E 'TcpExtTCPReqQFullDoCookies|TcpExtListenDrops|TcpExtListenOverflows|TcpExtSyncookies'
TcpExtSyncookiesSent            84213   0.0
TcpExtSyncookiesRecv               12   0.0
TcpExtListenOverflows            1874   0.0
TcpExtListenDrops                1874   0.0
TcpExtTCPReqQFullDoCookies      84213   0.0

$ dmesg -T | tail -1
[Tue Aug 25 10:41:12 2026] TCP: request_sock_TCP: Possible SYN flooding on port 443. Sending cookies.
```

**SYN cookies** encode the connection state into the initial sequence number, so no memory is allocated until the final `ACK` returns. The trade-off is real and examinable: cookies **cannot carry TCP options** that do not fit in the encoding, so with cookies active you lose reliable SACK/window-scaling/timestamp negotiation for cookie-accepted connections. That is why `tcp_syncookies=1` (only under pressure) is correct and `=2` (always) is a performance decision, not a security one.

Complete, deployable tuning file:

```ini
# /etc/sysctl.d/60-network-dos.conf — SYN flood and spoofing resistance
# Verify with: sudo sysctl --system && sysctl -a --pattern 'tcp_(syncookies|max_syn)'

net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384

# Reverse-path filtering: drop packets whose source is not routable back
# out of the arrival interface. Use 2 (loose) on multihomed/asymmetric hosts.
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP broadcast (Smurf) and stop being a reflector
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.icmp_ratelimit = 100

# No redirects: neither accept nor send (routing hijack primitive)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# IPv6 RA: reject unless this host is a client that needs SLAAC
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0

# Log martians for forensics
net.ipv4.conf.all.log_martians = 1

# Conntrack sizing (state-exhaustion resistance on a firewall)
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
```

```bash
$ sudo sysctl --system
* Applying /etc/sysctl.d/60-network-dos.conf ...
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 8192
...
$ sysctl net.ipv4.tcp_syncookies net.ipv4.conf.all.rp_filter
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
```

### 8.2 Reflection and amplification

The attacker spoofs the victim's source address to a service that answers with a much larger response. The **bandwidth amplification factor (BAF)** is the multiplier.

| Protocol / port | BAF (approx.) | Fix |
|---|---|---|
| memcached UDP/11211 | 10 000–51 000× | `-U 0`; never expose UDP; firewall |
| NTP `monlist` UDP/123 | ~557× | ntpd ≥ 4.2.7p26, `disable monitor` |
| CharGen UDP/19 | ~359× | Disable; it has no modern use |
| QOTD UDP/17 | ~140× | Disable |
| RIPv1 UDP/520 | ~131× | RIPv2 with auth, or a real IGP |
| CLDAP UDP/389 | ~56–70× | Do not expose LDAP to the internet |
| DNS UDP/53 (open resolver) | ~28–54× | No open recursion; RRL; ACLs |
| SSDP UDP/1900 | ~31× | Block at the border |
| SNMPv2 UDP/161 | ~6× | SNMPv3, ACLs |
| NetBIOS UDP/137 | ~4× | Block at the border |

The upstream fix for the whole class is **BCP 38 / RFC 2827 ingress filtering** — networks refusing to forward packets with source addresses they do not own. `rp_filter` is BCP 38 at the host.

Are you a reflector? Test from *outside* your own network:

```bash
$ dig @203.0.113.10 . NS +short          # your resolver, queried from the internet
;; connection timed out; no servers could be reached      # correct — recursion is closed

$ nmap -sU -p 11211,123,1900,161,19 --script memcached-info,ntp-monlist 203.0.113.10
PORT      STATE  SERVICE
19/udp    closed chargen
123/udp   open   ntp
161/udp   closed snmp
1900/udp  closed upnp
11211/udp closed memcache
| ntp-monlist: (no response — monitor disabled)
```

### 8.3 Application-layer DoS

**Slowloris** opens many connections and sends a partial HTTP header every few seconds, holding worker slots with nearly zero bandwidth. **R.U.D.Y.** does the same with a slow POST body. **HTTP/2 Rapid Reset (CVE-2023-44487)** exploits stream multiplexing: open a stream, immediately `RST_STREAM`, repeat — the server does the work, the client pays almost nothing.

```nginx
# /etc/nginx/conf.d/00-dos-limits.conf
limit_req_zone  $binary_remote_addr zone=perip:20m  rate=20r/s;
limit_conn_zone $binary_remote_addr zone=connperip:20m;

server {
    listen 443 ssl http2;

    client_body_timeout   10s;   # kills R.U.D.Y.
    client_header_timeout 10s;   # kills Slowloris
    send_timeout          10s;
    keepalive_timeout     30s;
    client_max_body_size  8m;
    large_client_header_buffers 4 8k;

    http2_max_concurrent_streams 128;   # bounds Rapid Reset per connection

    limit_req      zone=perip burst=40 nodelay;
    limit_conn     connperip 20;
    limit_req_status 429;
    limit_conn_status 429;
}
```

Kernel-level rate limiting with nftables (complete, loadable ruleset):

```
#!/usr/sbin/nft -f
# /etc/nftables.d/dos-protect.nft  —  nft -c -f this file to syntax-check
flush ruleset

table inet filter {
    set blackhole {
        type ipv4_addr
        flags dynamic, timeout
        timeout 1h
        size 65535
    }

    chain input {
        type filter hook input priority filter; policy drop;

        iif lo accept
        ct state established,related accept
        ct state invalid drop

        ip saddr @blackhole drop

        # ICMP: allow, but bounded
        ip protocol icmp icmp type echo-request limit rate 10/second burst 20 packets accept
        ip protocol icmp icmp type echo-request drop
        ip6 nexthdr icmpv6 icmpv6 type { echo-request, nd-neighbor-solicit,
             nd-neighbor-advert, nd-router-advert } limit rate 20/second accept

        # SYN rate limiting per source, then blackhole repeat offenders
        tcp flags syn tcp dport { 80, 443 } \
            meter syn_meter { ip saddr limit rate over 25/second burst 50 packets } \
            add @blackhole { ip saddr } \
            log prefix "nft-synflood: " level warn counter drop

        # Concurrent connection cap per source
        tcp dport { 80, 443 } ct count over 60 \
            log prefix "nft-connlimit: " counter drop

        # SSH: slow brute force to a crawl
        tcp dport 22 ct state new \
            meter ssh_meter { ip saddr limit rate over 6/minute burst 6 packets } \
            counter drop
        tcp dport 22 accept

        tcp dport { 80, 443 } accept
        counter comment "policy drop counter"
    }

    chain forward { type filter hook forward priority filter; policy drop; }
    chain output  { type filter hook output  priority filter; policy accept; }
}
```

```bash
$ sudo nft -c -f /etc/nftables.d/dos-protect.nft && echo "syntax OK"
syntax OK
$ sudo nft -f /etc/nftables.d/dos-protect.nft
$ sudo nft list set inet filter blackhole
table inet filter {
        set blackhole {
                type ipv4_addr
                size 65535
                flags dynamic,timeout
                timeout 1h
                elements = { 198.51.100.77 expires 58m12s344ms }
        }
}
$ sudo nft list chain inet filter input | grep -A1 synflood
                tcp flags syn tcp dport { 80, 443 } meter syn_meter ...
                log prefix "nft-synflood: " level warn counter packets 41822 bytes 2508 drop
```

> **The honest limit:** every technique above defends against *state* exhaustion. A true volumetric DDoS that saturates your transit link cannot be filtered at the host — by the time the packet reaches your NIC, the bandwidth is already spent. That requires upstream scrubbing, anycast, or a provider-level filter. Say so in your design docs.

---

## 9. Web application vulnerability classes

Even in an infrastructure role, these are exam material and the most common initial access vector.

| Class | CWE | One-line mechanism | Primary fix |
|---|---|---|---|
| SQL injection | CWE-89 | Untrusted data becomes SQL syntax | Parameterised queries / prepared statements |
| Command injection | CWE-78 | Untrusted data becomes shell syntax | `execve()` with an argv array; never a shell string |
| XSS (stored/reflected/DOM) | CWE-79 | Untrusted data becomes HTML/JS in another user's browser | Contextual output encoding + CSP |
| CSRF | CWE-352 | Victim's browser is tricked into an authenticated request | `SameSite=Lax/Strict` + anti-CSRF token |
| SSRF | CWE-918 | Server fetches an attacker-chosen URL | Allowlist, block link-local `169.254.169.254`, IMDSv2 |
| Path traversal | CWE-22 | `../../etc/passwd` escapes the document root | Canonicalise then verify prefix; `openat2 RESOLVE_BENEATH` |
| Insecure deserialization | CWE-502 | Object graph construction is code execution | Data-only formats; signed payloads |
| XXE | CWE-611 | XML external entities read files / reach internal hosts | Disable DTD/external entities |
| Broken access control / IDOR | CWE-639/862 | Object ID is trusted from the client | Server-side authorisation on every object |
| SSTI / expression injection | CWE-1336 | Template engine evaluates user input | Never build templates from user input |

**SQL injection — the mechanism and the only real fix:**

```python
# Vulnerable: input becomes syntax
cur.execute("SELECT id,email FROM users WHERE name = '%s'" % name)
#   name = "x' UNION SELECT 1,password_hash FROM users -- "

# Correct: input can only ever be a value
cur.execute("SELECT id,email FROM users WHERE name = %s", (name,))
```

Escaping and WAF rules are compensating controls. Parameterisation is the fix, because it moves the trust boundary from string content to protocol structure. Add defence in depth: least-privilege DB accounts (the web user needs no `DROP`, no `FILE`, no `outfile`), and network isolation of the database.

**Log4Shell (CVE-2021-44228)** deserves a mention as a hybrid: a *logging* library performed JNDI lookups on `${jndi:ldap://…}` substrings inside logged data, turning "log the User-Agent header" into remote class loading and RCE. CVSS 10.0. The architectural lesson is that **any component that interprets data as instructions is an injection surface**, including ones you do not think of as parsers.

---

## 10. Malicious code

| Type | Defining property | Propagation | Linux relevance |
|---|---|---|---|
| **Virus** | Attaches to a host file/program | Requires user to run the host | Historically low; ELF infectors exist |
| **Worm** | Self-propagating, no host needed | Network, autonomously | Morris (1988), Slammer, WannaCry, Mirai |
| **Trojan** | Poses as legitimate software | User installs it willingly | Malicious packages, backdoored tarballs |
| **Backdoor** | Covert access channel | Planted after or during compromise | SSH key in `authorized_keys`, `xz` |
| **Rootkit** | Hides the compromise itself | Installed post-exploitation | LD_PRELOAD, LKM, eBPF |
| **Ransomware** | Encrypts data, extorts payment | Phishing → lateral movement | ESXi/NAS/Linux variants now common |
| **Botnet agent** | Remote-controlled node | Worm or trojan | Mirai (IoT), DDoS-for-hire |
| **Cryptominer** | Steals CPU/GPU | Exposed APIs, weak SSH, K8s | The most common Linux payload today |
| **Logic bomb** | Triggers on a condition | Insider | Rare, high impact |

### 10.1 Rootkit strata — and what detects each

| Stratum | Technique | Detection |
|---|---|---|
| **Userland** | Trojaned `ls`, `ps`, `netstat`; `/etc/ld.so.preload` | Package verification (`rpm -Va`, `debsums`), AIDE, static binaries |
| **Library** | `LD_PRELOAD` hooking `readdir`, `open` | `cat /etc/ld.so.preload`, compare `ls` vs raw `getdents` |
| **Kernel module (LKM)** | Syscall table / ftrace hooks, hidden PIDs | `lsmod` vs `/proc/modules` vs `/sys/module`, module signing, lockdown |
| **eBPF** | Hooks without a module | `bpftool prog list`, `CAP_BPF` restriction, `kernel.unprivileged_bpf_disabled=1` |
| **Bootkit / firmware** | Pre-kernel | Secure Boot, TPM measured boot, IMA/EVM |

```bash
$ rpm -Va --nomtime --nordev 2>/dev/null | grep -E '^..5|missing' | head
S.5....T.  /usr/bin/ps                       <-- content hash changed: INVESTIGATE
$ debsums -c 2>/dev/null
/usr/bin/netstat

$ cat /etc/ld.so.preload 2>/dev/null
/lib/libmemcached.so.6                       <-- not owned by any package: INVESTIGATE

$ sudo aide --check
AIDE found differences between database and filesystem!!
Start timestamp: 2026-08-25 10:52:03 -0300 (AIDE 0.18.6)

Summary:
  Total number of entries:      212944
  Added entries:                1
  Removed entries:              0
  Changed entries:              3

---------------------------------------------------
Added entries:
---------------------------------------------------
f++++++++++++++++: /usr/lib64/libhealth.so

---------------------------------------------------
Changed entries:
---------------------------------------------------
f   ...    .C... : /usr/bin/ps
f   ...    .C... : /etc/ld.so.preload
f   ...    .C... : /root/.ssh/authorized_keys

$ sudo bpftool prog list | tail -6
418: kprobe  name sys_getdents_hook  tag 9c2f1a3b4d5e6f70  gpl
     loaded_at 2026-08-25T09:11:44-0300  uid 0
     xlated 1288B  jited 736B  memlock 4096B  map_ids 91,92
```

Minimal AIDE configuration that is actually useful (the database must live off-host or on read-only media, or the attacker updates it too):

```
# /etc/aide.conf (excerpt)
database_in  = file:/var/lib/aide/aide.db.gz
database_out = file:/var/lib/aide/aide.db.new.gz
database_attrs = sha512
report_url = file:/var/log/aide/aide.log
report_url = stdout

# rule definitions
NORMAL   = p+i+n+u+g+s+m+c+acl+selinux+xattrs+sha512
LOGS     = p+u+g+n+S+acl+selinux+xattrs
CONFIG   = p+i+n+u+g+s+m+c+sha512

/boot      NORMAL
/bin       NORMAL
/sbin      NORMAL
/usr/bin   NORMAL
/usr/sbin  NORMAL
/usr/lib   NORMAL
/lib       NORMAL
/etc       CONFIG
/root/.ssh NORMAL
/var/log   LOGS
!/var/log/journal
!/etc/mtab
!/etc/adjtime
```

```bash
$ sudo aide --init && sudo mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
$ sudo sha256sum /var/lib/aide/aide.db.gz | tee /media/wormdrive/aide.db.sha256
2f9a...c81  /var/lib/aide/aide.db.gz
```

`rkhunter` and `chkrootkit` complement this with signature/heuristic checks:

```bash
$ sudo rkhunter --check --sk --rwo
Warning: The file properties have changed:
         File: /usr/bin/ps
         Current hash: 4d8a...  Stored hash: 91be...
Warning: Hidden directory found: /dev/.udev
Warning: Suspicious file types found in /dev: /dev/shm/.x
```

### 10.2 Ransomware — an availability *and* integrity problem

The technical primitive is trivial (encrypt files, delete the plaintext). The defence is entirely architectural: **immutable, offline or write-once backups**, tested restores, credential segmentation so one compromised admin does not reach the backup server, and monitoring for mass-rename/mass-write patterns. Backups reachable with the same credentials as production are not backups.

---

## 11. Credential attacks, phishing, social engineering

| Attack | Mechanism | Countermeasure |
|---|---|---|
| **Brute force** | Try every candidate | Slow hashes, rate limiting, lockout, key-only auth |
| **Dictionary** | Try likely candidates | Password quality policy (`pam_pwquality`), breach-list rejection |
| **Rainbow tables** | Precomputed hash→plaintext chains | **Per-password salt** (defeats precomputation entirely) |
| **Credential stuffing** | Reuse breached pairs across sites | MFA, breach monitoring, unique-password policy |
| **Password spraying** | One common password across many accounts | Per-*account* AND per-*source* lockout, anomaly detection |
| **Pass-the-hash** | Reuse the stored hash, never crack it | Kerberos, no shared local admin hashes |
| **Keylogger / shoulder surfing** | Capture at input | Endpoint hardening, hardware tokens |
| **Phishing / spear-phishing / whaling** | Deceptive message | DMARC/DKIM/SPF, training, **phishing-resistant MFA (FIDO2)** |
| **Vishing / smishing / BEC** | Voice / SMS / business email compromise | Out-of-band verification of payment changes |
| **MFA fatigue / push bombing** | Spam approvals until one is accepted | Number matching, FIDO2 |
| **Pretexting / tailgating / baiting / quid pro quo** | Human trust exploitation | Policy, badge discipline, culture |

### 11.1 Why salting is the answer to rainbow tables

A rainbow table amortises the cost of cracking across *all* targets. A unique random salt per password means the attacker must rebuild the table for every single hash — the amortisation collapses. Modern `crypt(3)` formats embed algorithm, cost and salt:

| Prefix | Algorithm | Notes |
|---|---|---|
| `$1$` | MD5-crypt | **Obsolete** |
| `$5$` | SHA-256-crypt | Configurable rounds |
| `$6$` | SHA-512-crypt | Long-time Linux default |
| `$2b$` | bcrypt | Memory-light, GPU-resistant-ish |
| `$7$` | scrypt | Memory-hard |
| `$y$` | **yescrypt** | Memory-hard; default on Debian 11+, Fedora 35+ |
| `$argon2id$` | Argon2id | Current recommendation for new applications |

```bash
$ sudo getent shadow alice | cut -c1-70
alice:$y$j9T$Yg2Vw9xQ1rZ8kP4nL0cJs.$3nQ0v8sD2wF...:20320:0:99999:7:::
        ^^^ yescrypt
$ grep -E '^ENCRYPT_METHOD|^SHA_CRYPT' /etc/login.defs
ENCRYPT_METHOD YESCRYPT
$ authselect current 2>/dev/null || grep -l pam_unix /etc/pam.d/* | head -3
```

Accounts with no password, or with a locked-but-usable field, are a standing finding:

```bash
$ sudo awk -F: '($2 == "") {print $1 " HAS EMPTY PASSWORD"}' /etc/shadow
$ sudo awk -F: '($3 == 0) {print $1 " HAS UID 0"}' /etc/passwd
root
backupadmin        <-- second UID-0 account: INVESTIGATE
$ sudo passwd -S -a | awk '$2=="NP"'
svc_legacy NP 2026-01-14 0 99999 7 -1
```

Lockout with `pam_faillock` (RHEL 9 / modern Debian) — note the availability trade-off:

```
# /etc/security/faillock.conf
deny = 5
unlock_time = 900
fail_interval = 900
even_deny_root
audit
silent
```

```bash
$ faillock --user alice
alice:
When                Type  Source                                           Valid
2026-08-25 10:58:11 RHOST 198.51.100.77                                        V
2026-08-25 10:58:13 RHOST 198.51.100.77                                        V
$ sudo faillock --user alice --reset
```

And network-level throttling with `fail2ban`:

```ini
# /etc/fail2ban/jail.d/sshd.local
[sshd]
enabled  = true
backend  = systemd
port     = ssh
maxretry = 5
findtime = 10m
bantime  = 1h
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 48h
ignoreip = 127.0.0.1/8 ::1 10.10.0.0/16
action   = nftables[type=allports]
```

```bash
$ sudo fail2ban-client status sshd
Status for the jail: sshd
|- Filter
|  |- Currently failed: 3
|  |- Total failed:     4128
|  `- Journal matches:  _SYSTEMD_UNIT=sshd.service + _COMM=sshd
`- Actions
   |- Currently banned: 27
   |- Total banned:     912
   `- Banned IP list:   198.51.100.77 203.0.113.9 ...
```

> The structural fix for SSH is not throttling — it is `PasswordAuthentication no` with certificate or key authentication. Throttling is what you deploy for the services that cannot do that yet.

---

## 12. Side-channel and microarchitectural attacks

A side channel leaks information through a system's *physical or timing behaviour* rather than through its logical interface. The algorithm can be mathematically perfect and still leak.

| Channel | What is observed | Classic target |
|---|---|---|
| **Timing** | Execution duration | Non-constant-time `memcmp` on MACs; RSA/ECDSA |
| **Cache** (Flush+Reload, Prime+Probe, Evict+Time) | Which cache lines were touched | AES T-tables, RSA square-and-multiply |
| **Power / EM / acoustic** | Physical emissions | Smart cards, HSMs, air-gapped devices |
| **Branch predictor / TLB** | Predictor and TLB state | Spectre variants, ASLR de-randomisation |
| **Fault injection** | Induced errors | Rowhammer, voltage/clock glitching, Plundervolt |
| **Frequency/power throttling** | DVFS-induced timing | Hertzbleed (2022) |

### 12.1 Transient-execution attacks

The CPU speculates past a boundary, performs the load, then architecturally rolls back — but the **microarchitectural side effects (cache state) survive**, and can be read out with a cache timing channel.

| Family | CVE / name | Boundary crossed |
|---|---|---|
| **Meltdown** (v3) | CVE-2017-5754 | User reads kernel memory (out-of-order load past a permission check) |
| **Spectre v1** | CVE-2017-5753 | Bounds-check bypass — speculation past `if (x < len)` |
| **Spectre v2** | CVE-2017-5715 | Branch target injection — mistrained indirect branch |
| **Spectre v4 / SSB** | CVE-2018-3639 | Speculative store bypass |
| **L1TF / Foreshadow** | CVE-2018-3615/6/20 | L1 terminal fault — SGX, VM→host |
| **MDS** (RIDL/Fallout/ZombieLoad) | CVE-2018-12126/7/30, 2019-11091 | Leak from internal buffers (store/fill/load ports) |
| **TAA** | CVE-2019-11135 | TSX asynchronous abort |
| **SRBDS** | CVE-2020-0543 | Special register buffer data sampling (`RDRAND`) |
| **Retbleed** | CVE-2022-29900/1 | Return instructions speculated (defeats retpoline assumptions) |
| **Downfall / GDS** | CVE-2022-40982 | `AVX GATHER` data sampling (Intel) |
| **Inception / SRSO** | CVE-2023-20569 | Speculative return stack overflow (AMD) |
| **Zenbleed** | CVE-2023-20593 | `vzeroupper` register leak (AMD Zen 2) |
| **RFDS** | CVE-2023-28746 | Register file data sampling (Intel Atom) |

The single command that answers "am I mitigated?":

```bash
$ grep . /sys/devices/system/cpu/vulnerabilities/*
/sys/devices/system/cpu/vulnerabilities/gather_data_sampling:Mitigation: Microcode
/sys/devices/system/cpu/vulnerabilities/itlb_multihit:KVM: Mitigation: Split huge pages
/sys/devices/system/cpu/vulnerabilities/l1tf:Mitigation: PTE Inversion; VMX: conditional cache flushes, SMT vulnerable
/sys/devices/system/cpu/vulnerabilities/mds:Mitigation: Clear CPU buffers; SMT vulnerable
/sys/devices/system/cpu/vulnerabilities/meltdown:Mitigation: PTI
/sys/devices/system/cpu/vulnerabilities/mmio_stale_data:Mitigation: Clear CPU buffers; SMT vulnerable
/sys/devices/system/cpu/vulnerabilities/retbleed:Mitigation: Enhanced IBRS
/sys/devices/system/cpu/vulnerabilities/spec_rstack_overflow:Not affected
/sys/devices/system/cpu/vulnerabilities/spec_store_bypass:Mitigation: Speculative Store Bypass disabled via prctl
/sys/devices/system/cpu/vulnerabilities/spectre_v1:Mitigation: usercopy/swapgs barriers and __user pointer sanitization
/sys/devices/system/cpu/vulnerabilities/spectre_v2:Mitigation: Enhanced IBRS, IBPB: conditional, RSB filling, PBRSB-eIBRS: SW sequence
/sys/devices/system/cpu/vulnerabilities/srbds:Mitigation: Microcode
/sys/devices/system/cpu/vulnerabilities/tsx_async_abort:Not affected
```

Read `SMT vulnerable` literally: **hyper-threading is a shared-microarchitecture channel between siblings.** On a multi-tenant hypervisor that is a real cross-tenant leak; on a single-tenant application server it usually is not worth the ~15–30 % throughput loss of disabling SMT.

### 12.2 Mitigation trade-offs

| Mitigation | Kernel knob | Protects | Typical measured cost |
|---|---|---|---|
| **KPTI** (Meltdown) | `pti=on` | User→kernel memory read | Syscall-heavy: 5–30 %; compute-bound: ~0 % |
| **Retpoline / IBRS / eIBRS** | `spectre_v2=` | Branch target injection | 1–10 %, workload-dependent |
| **SSBD** | `spec_store_bypass_disable=` | Store-bypass leaks | 2–8 % on some workloads |
| **MDS buffer clear (`VERW`)** | automatic w/ microcode | Buffer sampling | 1–5 %, context-switch-heavy worse |
| **`nosmt`** | `mitigations=auto,nosmt` | Cross-sibling leaks | 15–30 % throughput loss |
| **`mitigations=off`** | — | *nothing* | Recovers all of the above |

> Treat these ranges as orders of magnitude, not constants — always benchmark your workload. The decision rule that survives review: **multi-tenant or untrusted local code → full mitigations plus `nosmt`; dedicated single-tenant appliance with no untrusted code execution and no browser → `mitigations=off` may be a defensible, documented, signed-off risk acceptance.** It must never be an undocumented default.

```bash
$ cat /proc/cmdline
BOOT_IMAGE=/vmlinuz-6.6.0 root=/dev/mapper/vg0-root ro mitigations=auto,nosmt
$ lscpu | grep -E '^Thread|^Vulnerability Meltdown|^Vulnerability Spectre v2'
Thread(s) per core:  1
Vulnerability Meltdown: Mitigation; PTI
Vulnerability Spectre v2: Mitigation; Enhanced IBRS, IBPB: conditional, RSB filling
```

### 12.3 Rowhammer — a fault-injection attack, not a software bug

Repeatedly activating a DRAM row induces charge leakage in physically adjacent rows, flipping bits **without ever accessing them**. A flipped bit in a page-table entry gives arbitrary physical memory access; a flipped bit in an RSA public key can enable factorisation. Demonstrated from JavaScript (Rowhammer.js) and over the network (Throwhammer).

Mitigations, in increasing order of effectiveness: increased refresh rate (2× tREFI), Target Row Refresh (**TRR** — repeatedly bypassed, e.g. by TRRespass and Blacksmith), **ECC memory** (raises the bar substantially but is not a proof — ECCploit), and DDR5's on-die **Refresh Management**. This is a hardware procurement decision, not a `sysctl`. For servers holding secrets, **ECC RAM is a security requirement, not a reliability nicety.**

```bash
$ sudo dmidecode -t memory | grep -E 'Type:|Total Width|Data Width' | head -6
        Total Width: 72 bits            <-- 72 vs 64 = ECC present
        Data Width: 64 bits
        Type: DDR4
$ sudo edac-util -v
mc0: 0 Uncorrected Errors with no DIMM info
mc0: 0 Corrected Errors with no DIMM info
mc0: csrow0: 0 Uncorrected Errors
mc0: csrow0: CPU_SrcID#0_MC#0_Chan#0_DIMM#0: 0 Corrected Errors
```

### 12.4 Constant-time as a discipline

Any code handling secrets must have execution time and memory-access patterns independent of the secret. Practically: use `CRYPTO_memcmp()` / `crypto_verify_32()` instead of `memcmp()` for MAC comparison; use library primitives (OpenSSL, libsodium) rather than hand-rolled modular exponentiation; never branch on secret data. A "correct" AES implementation with data-dependent table lookups leaks its key over the cache channel.

---

## 13. Supply-chain compromise

The modern version of "trusting trust". Your attack surface is the union of every dependency's attack surface, plus every build system that touches your artefact.

| Vector | Example | Control |
|---|---|---|
| Backdoored upstream source | **CVE-2024-3094** (`xz`/liblzma, 2024) | Reproducible builds, build-vs-source diff, maintainer diversity |
| Compromised maintainer account | `event-stream` (npm, 2018) | 2FA on registries, signed releases |
| **Typosquatting** | `python-dateutil` → `python3-dateutil` | Vendoring, allowlists, internal proxy registry |
| **Dependency confusion** | Internal name resolved from the public registry | Scoped names, pin the index, no fallback resolution |
| Compromised build system | SolarWinds (2020) | Hermetic builds, SLSA levels, provenance attestation |
| Malicious container base image | Cryptominers in public images | Signed images, digest pinning, admission policy |
| Compromised update channel | Unsigned/HTTP repos | GPG-signed repos, TLS, `gpgcheck=1` |

**CVE-2024-3094** is the case study: a multi-year social-engineering operation planted an obfuscated backdoor in `xz-utils` release *tarballs* (not the git tree), delivered through test fixtures, that hooked `RSA_public_decrypt` via IFUNC resolution in `sshd` (through `libsystemd`'s `liblzma` dependency) to grant authentication bypass to a holder of a specific key. CVSS 10.0. It was found by a performance investigation — a ~500 ms delay in SSH logins — not by any scanner. **Every automated check in §14 would have passed.**

```bash
$ rpm -K /var/cache/dnf/updates/packages/openssl-3.2.2-6.el9.x86_64.rpm
openssl-3.2.2-6.el9.x86_64.rpm: digests signatures OK
$ apt-key list 2>/dev/null; ls -l /etc/apt/trusted.gpg.d/ /etc/apt/keyrings/
$ grep -rE '^gpgcheck|^repo_gpgcheck' /etc/yum.repos.d/*.repo | grep -v '=1'
/etc/yum.repos.d/vendor.repo:gpgcheck=0        <-- FINDING

$ syft dir:/opt/app -o cyclonedx-json > sbom.json
 ✔ Indexed file system  /opt/app
 ✔ Cataloged contents   sha256:9f2c…
   ├── 412 packages
$ grype sbom:sbom.json --fail-on high
NAME          INSTALLED   FIXED-IN   TYPE   VULNERABILITY   SEVERITY
log4j-core    2.14.1      2.17.1     java-archive  CVE-2021-44228  Critical
netty-codec   4.1.68      4.1.77     java-archive  CVE-2022-24823  High
$ echo $?
1
```

---

## 14. Operationalising it: the remediation pipeline as infrastructure

### 14.1 Remediation SLOs

| Class | Trigger | Remediation SLO | Change process |
|---|---|---|---|
| **P0** | In CISA KEV **and** internet-reachable | 24 h | Emergency change, page on-call |
| **P1** | CVSS ≥ 9.0, or EPSS ≥ 0.10 with CVSS ≥ 7.0 | 7 days | Expedited change |
| **P2** | CVSS 7.0–8.9 | 30 days | Normal patch window |
| **P3** | CVSS < 7.0 | Next quarterly window | Batched |
| **Suppressed** | VEX `not_affected` with a stated justification | n/a | Documented, expires in 90 days |

Every suppression must carry a machine-readable reason and an expiry. A suppression without an expiry is a permanent blind spot.

### 14.2 CI scanning gate (GitLab CI, complete)

```yaml
# .gitlab-ci.yml — vulnerability gate for container images
stages: [build, sbom, scan, gate]

variables:
  IMAGE: "$CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA"
  TRIVY_CACHE_DIR: ".trivycache"
  TRIVY_NO_PROGRESS: "true"

build:
  stage: build
  image: quay.io/buildah/stable:v1.35
  script:
    - buildah bud --format docker -t "$IMAGE" .
    - buildah push "$IMAGE"

sbom:
  stage: sbom
  image: anchore/syft:v1.4.1
  script:
    - syft "$IMAGE" -o cyclonedx-json=sbom.cdx.json -o spdx-json=sbom.spdx.json
  artifacts:
    paths: [sbom.cdx.json, sbom.spdx.json]
    expire_in: 1 year
    reports:
      cyclonedx: sbom.cdx.json

scan:
  stage: scan
  image: aquasec/trivy:0.52.2
  cache:
    key: trivy-db
    paths: [".trivycache"]
  script:
    # Report everything, never fail here — the gate job decides
    - trivy image --exit-code 0 --format json --output trivy.json "$IMAGE"
    - trivy image --exit-code 0 --format table --severity HIGH,CRITICAL "$IMAGE"
    - trivy config --exit-code 0 --format json --output trivy-iac.json .
    - trivy fs --scanners secret --exit-code 1 --format table .
  artifacts:
    paths: [trivy.json, trivy-iac.json]
    when: always

gate:
  stage: gate
  image: aquasec/trivy:0.52.2
  script:
    # Hard gate: any CRITICAL with a known fix blocks the pipeline.
    - trivy image --severity CRITICAL --ignore-unfixed --exit-code 1
        --ignorefile .trivyignore.yaml --vex vex.cdx.json "$IMAGE"
    # Soft gate: HIGH with a fix is reported and tracked, not blocking.
    - trivy image --severity HIGH --ignore-unfixed --exit-code 0
        --ignorefile .trivyignore.yaml --vex vex.cdx.json "$IMAGE"
  allow_failure: false
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
```

```yaml
# .trivyignore.yaml — every suppression is justified AND expires
vulnerabilities:
  - id: CVE-2024-28085
    paths: ["usr/bin/wall"]
    statement: "util-linux wall(1) escape injection; no interactive local users on this image."
    expired_at: 2026-11-01
  - id: CVE-2023-45853
    statement: "zlib minizip; the image never processes untrusted ZIP archives."
    expired_at: 2026-10-15
```

```bash
$ trivy image --severity CRITICAL --ignore-unfixed --exit-code 1 registry.example/app:9f2c1ab
2026-08-25T11:04:18-03:00  INFO  Vulnerability scanning is enabled
registry.example/app:9f2c1ab (debian 12.6)
Total: 2 (CRITICAL: 2)

┌──────────────┬────────────────┬──────────┬────────┬───────────────────┬───────────────┐
│   Library    │ Vulnerability  │ Severity │ Status │ Installed Version │ Fixed Version │
├──────────────┼────────────────┼──────────┼────────┼───────────────────┼───────────────┤
│ libssl3      │ CVE-2026-2153  │ CRITICAL │ fixed  │ 3.0.13-1~deb12u1  │ 3.0.16-1~...  │
│ libtasn1-6   │ CVE-2026-1877  │ CRITICAL │ fixed  │ 4.19.0-2          │ 4.19.0-2+deb..│
└──────────────┴────────────────┴──────────┴────────┴───────────────────┴───────────────┘
$ echo $?
1
```

### 14.3 Fleet patching in rings (Ansible, complete)

```yaml
# patch-rings.yml — ring-based security patching with verification
# Usage: ansible-playbook -i inventory patch-rings.yml -e ring=canary
---
- name: Security patch ring
  hosts: "{{ ring | default('canary') }}"
  become: true
  serial: "{{ batch | default('20%') }}"
  max_fail_percentage: 0
  gather_facts: true

  vars:
    reboot_if_required: true
    reboot_timeout: 900

  pre_tasks:
    - name: Record pre-patch package state
      ansible.builtin.shell: |
        set -o pipefail
        if command -v rpm >/dev/null; then rpm -qa | sort; else dpkg -l | sort; fi
      args: {executable: /bin/bash}
      register: pkgs_before
      changed_when: false

    - name: Drain from load balancer
      ansible.builtin.uri:
        url: "https://lb.example/api/v1/backends/{{ inventory_hostname }}/drain"
        method: POST
        status_code: [200, 204]
      delegate_to: localhost
      become: false
      when: "'web' in group_names"

  tasks:
    - name: Apply security updates (RHEL family)
      ansible.builtin.dnf:
        name: "*"
        security: true
        bugfix: false
        state: latest
        update_cache: true
      when: ansible_os_family == "RedHat"
      register: dnf_patch

    - name: Apply security updates (Debian family)
      ansible.builtin.apt:
        upgrade: dist
        update_cache: true
        cache_valid_time: 3600
        only_upgrade: true
      environment:
        DEBIAN_FRONTEND: noninteractive
      when: ansible_os_family == "Debian"
      register: apt_patch

    - name: Detect processes still using deleted (pre-patch) libraries
      ansible.builtin.shell: |
        set -o pipefail
        if command -v needs-restarting >/dev/null; then
          needs-restarting -s 2>/dev/null || true
        else
          checkrestart -v 2>/dev/null || true
        fi
      args: {executable: /bin/bash}
      register: stale_procs
      changed_when: false

    - name: Fail loudly if remediation is incomplete without a reboot
      ansible.builtin.assert:
        that: stale_procs.stdout | length == 0 or reboot_if_required
        fail_msg: >-
          Packages upgraded but {{ stale_procs.stdout_lines | length }} services still
          map the OLD library. The host is NOT remediated.

    - name: Check whether a reboot is required
      ansible.builtin.stat:
        path: /var/run/reboot-required
      register: deb_reboot

    - name: Check kernel currency (RHEL)
      ansible.builtin.command: needs-restarting -r
      register: rhel_reboot
      failed_when: false
      changed_when: false
      when: ansible_os_family == "RedHat"

    - name: Reboot when required
      ansible.builtin.reboot:
        reboot_timeout: "{{ reboot_timeout }}"
        post_reboot_delay: 30
        test_command: systemctl is-system-running --wait
      when:
        - reboot_if_required
        - deb_reboot.stat.exists | default(false) or (rhel_reboot.rc | default(0)) == 1

  post_tasks:
    - name: Re-scan for remaining security errata
      ansible.builtin.shell: |
        set -o pipefail
        if command -v dnf >/dev/null; then
          dnf -q updateinfo list --security | wc -l
        else
          apt-get -s -o Dir::Etc::SourceList=/etc/apt/sources.list.d/security.list \
            dist-upgrade | grep -c '^Inst' || true
        fi
      args: {executable: /bin/bash}
      register: remaining
      changed_when: false

    - name: Assert zero outstanding security errata
      ansible.builtin.assert:
        that: remaining.stdout | int == 0
        fail_msg: "{{ remaining.stdout }} security errata still outstanding after patching."

    - name: Return to load balancer
      ansible.builtin.uri:
        url: "https://lb.example/api/v1/backends/{{ inventory_hostname }}/enable"
        method: POST
        status_code: [200, 204]
      delegate_to: localhost
      become: false
      when: "'web' in group_names"
```

```bash
$ ansible-playbook -i inventory patch-rings.yml -e ring=canary -e batch=1
PLAY [Security patch ring] *****************************************************
TASK [Apply security updates (Debian family)] **********************************
changed: [web-canary-01]
TASK [Detect processes still using deleted (pre-patch) libraries] **************
ok: [web-canary-01]
TASK [Reboot when required] ****************************************************
changed: [web-canary-01]
TASK [Assert zero outstanding security errata] *********************************
ok: [web-canary-01]
PLAY RECAP *********************************************************************
web-canary-01              : ok=11   changed=3    unreachable=0    failed=0
```

### 14.4 Unattended security updates (the boring control that works)

```ini
# Debian: /etc/apt/apt.conf.d/50unattended-upgrades (excerpt)
Unattended-Upgrade::Origins-Pattern {
      "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::MailReport "on-change";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
```

```ini
# RHEL: /etc/dnf/automatic.conf (excerpt)
[commands]
upgrade_type = security
apply_updates = yes
reboot = when-needed
```

```bash
$ sudo systemctl enable --now dnf-automatic.timer
$ systemctl list-timers dnf-automatic.timer
NEXT                        LEFT     LAST                        PASSED   UNIT
Wed 2026-08-26 06:31:44 -03 19h left Tue 2026-08-25 06:29:12 -03 4h 36min dnf-automatic.timer
$ sudo unattended-upgrade --dry-run -d 2>&1 | tail -3
Packages that will be upgraded: libssl3 openssl
Writing dpkg log to /var/log/unattended-upgrades/unattended-upgrades-dpkg.log
```

---

## 15. Verification and failure diagnosis

### 15.1 The verification ladder — know which rung a claim rests on

| Claim | Evidence that actually supports it | Common false substitute |
|---|---|---|
| "The package is patched" | `rpm -q --changelog pkg \| grep CVE`; distro tracker says fixed | "We ran `apt upgrade` last week" |
| "The **host** is remediated" | No process maps the old library: `needs-restarting -s` / `lsof +c0 \| grep DEL` | Package version alone |
| "The **fleet** is remediated" | Inventory query across 100 % of assets, with the denominator stated | A scan of the hosts the scanner could reach |
| "It is not exploitable" | Reachability analysis or VEX statement with justification | "It's probably not reachable" |
| "The mitigation is active" | `/sys/devices/system/cpu/vulnerabilities/*`, `checksec`, `sysctl` readback | The config file contains the setting |
| "The config is applied" | Runtime readback (`sshd -T`, `nft list ruleset`, `sysctl -a`) | The file on disk |
| "We would detect it" | A tabletop or purple-team exercise that fired the alert | An installed agent |

### 15.2 Symptom → diagnosis table

| Symptom | Likely cause | Command |
|---|---|---|
| Setting in `/etc/sysctl.d/` but not in effect | Later file overrides it; unit not applied; namespace | `sysctl -a --pattern X`; `sysctl --system`; check `/usr/lib/sysctl.d` order |
| `sshd_config` edited, behaviour unchanged | `Match` block, `Include` order, or service not reloaded | `sshd -T \| grep X`; `sshd -T -C user=x,host=y,addr=z` |
| Firewall rule present, traffic still passes | Rule after an `accept`; wrong hook/priority; conntrack `established` short-circuit | `nft list ruleset -a`; `nft monitor trace` |
| Package upgraded, scanner still flags it | Long-running process holds the old mapping | `lsof +c0 2>/dev/null \| grep -E 'DEL\|(deleted)'` |
| Scanner reports a CVE the distro says is fixed | Backport: version string mismatch | Distro OVAL data; `rpm -q --changelog` |
| CVSS 9.8 but no one can exploit it | Precondition absent in your config | Check EPSS/KEV, read the advisory's prerequisites |
| Binary crashes with `*** stack smashing detected ***` | Real overflow, caught by the canary | Core dump + `gdb bt`, then file a bug — do not disable the canary |
| SSH logins suddenly ~500 ms slower | Could be DNS/GSSAPI — or a compromised library | `ssh -vvv`; `perf trace`; `rpm -Va`; compare `sha256sum` with the distro |
| Mitigation shows `Vulnerable: … SMT vulnerable` | Microcode present but SMT enabled | `lscpu`; `mitigations=auto,nosmt`; firmware update |
| Service works in staging, `systemd` sandbox kills it in prod | `SystemCallFilter`/`ProtectSystem` too tight | `journalctl -u X`; `SystemCallLog=@all` to observe first |
| `fail2ban` bans legitimate users | Shared NAT egress; retry loop in a client | `fail2ban-client status`; widen `ignoreip`, per-account lockout instead |
| AIDE reports thousands of changes | Database not updated after a legitimate patch run | Re-init after every patch cycle; store the DB off-host |

### 15.3 Diagnostic commands worth memorising

```bash
# What is actually listening, and which binary owns it
$ sudo ss -tulpnH | awk '{print $1,$5,$7}' | sort -u
tcp 0.0.0.0:22   users:(("sshd",pid=1121,fd=3))
tcp 127.0.0.1:5432 users:(("postgres",pid=1443,fd=7))
udp 0.0.0.0:123  users:(("chronyd",pid=980,fd=5))

# Processes still mapping deleted (pre-upgrade) libraries — the #1 false "patched"
$ sudo lsof +c0 2>/dev/null | awk '/DEL|\(deleted\)/ {print $1,$2,$NF}' | sort -u
nginx     2211 /usr/lib/x86_64-linux-gnu/libssl.so.3
postgres  1443 /usr/lib/x86_64-linux-gnu/libcrypto.so.3
$ sudo needs-restarting -s
systemd-journald.service
nginx.service

# Reboot required?
$ needs-restarting -r
Core libraries or services have been updated since boot-up:
  * kernel
Reboot is required to fully utilize these updates.
$ echo $?
1

# Runtime config readback — never trust the file
$ sudo sshd -T | grep -E '^(permitrootlogin|passwordauthentication|kbdinteractive)'
permitrootlogin no
passwordauthentication no
kbdinteractiveauthentication no
$ sudo nft list ruleset | head -5
$ sudo sysctl -a --pattern 'randomize|protected_|rp_filter|syncookies'

# Broad posture baseline
$ sudo lynis audit system --quick 2>&1 | tail -8
  Hardening index : 74 [############        ]
  Tests performed : 268
  Suggestions     : 31
$ sudo oscap xccdf eval --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
    --results-arf arf.xml --report report.html \
    /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
Title   Ensure sudo is installed
Rule    xccdf_org.ssgproject.content_rule_package_sudo_installed
Result  pass
...
$ oscap info arf.xml | grep -A2 'Score'
```

### 15.4 Failure modes of the process itself

1. **Denominator fraud.** "98 % patched" over the assets the scanner could reach. The 2 % it cannot reach is where the breach starts. Reconcile scanner inventory against CMDB/DHCP/switch MAC tables and report the *gap*, not the ratio.
2. **Restart amnesia.** The single most common reason a patched fleet is still exploitable. Automate the `needs-restarting` check as a gate, not a report.
3. **Suppression rot.** A `.trivyignore` without expiry dates becomes a permanent, invisible acceptance of risk.
4. **Scanning only what you build.** Base images, sidecars, init containers, vendor appliances, firmware, and the CI runners themselves all carry CVEs.
5. **Believing "no findings" means "no vulnerabilities."** No scanner detected `xz`. Detection coverage is a *property you must measure*, not one you may assume.
6. **Confusing compliance with security.** A passing CIS benchmark is a floor. It says nothing about your application's SQL injection.

---

## 16. Exam-day distilled facts

- **CWE = class, CVE = instance, CVSS = severity, EPSS = probability, KEV = observed.**
- CVSS ranges: 0.1–3.9 low · 4.0–6.9 medium · 7.0–8.9 high · 9.0–10.0 critical.
- `Risk = Threat × Vulnerability × Impact`; remove any factor and the risk goes.
- **Salt defeats rainbow tables**, not brute force. Slow/memory-hard hashes (yescrypt, bcrypt, Argon2) defeat brute force.
- **Stack canary** protects the saved return address; **NX** stops shellcode execution; **ASLR/PIE** randomises addresses; **RELRO** protects the GOT. All four are needed — each has a bypass.
- **TOCTOU** = check and use are separate operations; fix by operating on a file descriptor, not a path.
- **SYN cookies** avoid allocating state until the handshake completes, at the cost of TCP options.
- **Amplification** requires source-address spoofing; the structural fix is **BCP 38 ingress filtering**.
- **Meltdown → KPTI. Spectre v2 → retpoline/IBRS. SMT is a side channel.** Check `/sys/devices/system/cpu/vulnerabilities/`.
- **Rowhammer** is a hardware fault-injection attack; ECC raises but does not remove the risk.
- **DNSSEC provides integrity/authenticity, not confidentiality**; DoT/DoH provide confidentiality, not integrity of the zone data.
- **Worm self-propagates; virus needs a host; trojan needs a willing user; rootkit hides the rest.**
- Rootkits live at userland, library (`/etc/ld.so.preload`), kernel module, eBPF, or firmware level — each needs a different detector.
- A **0-day** has no fix; an **n-day** has a fix you have not applied. Most breaches are n-days.

---

## References

- LPI — Exam 303-300 Objectives (LPIC-3 Security v3.0): https://www.lpi.org/our-certifications/exam-303-objectives/
- MITRE — CVE Program: https://www.cve.org/
- MITRE — CWE, Common Weakness Enumeration: https://cwe.mitre.org/
- MITRE — CWE Top 25 Most Dangerous Software Weaknesses: https://cwe.mitre.org/top25/
- FIRST — CVSS v3.1 Specification Document: https://www.first.org/cvss/v3-1/specification-document
- FIRST — CVSS v4.0 Specification Document: https://www.first.org/cvss/v4-0/specification-document
- FIRST — EPSS, Exploit Prediction Scoring System: https://www.first.org/epss/
- NIST — National Vulnerability Database: https://nvd.nist.gov/
- NIST — NVD API 2.0 documentation: https://nvd.nist.gov/developers/vulnerabilities
- CISA — Known Exploited Vulnerabilities Catalog: https://www.cisa.gov/known-exploited-vulnerabilities-catalog
- CISA — Alert TA14-013A, UDP-Based Amplification Attacks: https://www.cisa.gov/news-events/alerts/2014/01/17/udp-based-amplification-attacks
- OWASP — Top 10: https://owasp.org/www-project-top-ten/
- OWASP — Cheat Sheet Series: https://cheatsheetseries.owasp.org/
- OWASP — SQL Injection Prevention Cheat Sheet: https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html
- Linux kernel — Hardware vulnerabilities documentation: https://www.kernel.org/doc/html/latest/admin-guide/hw-vuln/index.html
- Linux kernel — Kernel parameters (`mitigations=`, `pti=`, `spectre_v2=`): https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html
- Linux kernel — sysctl/fs documentation (`protected_symlinks`, `protected_hardlinks`): https://www.kernel.org/doc/html/latest/admin-guide/sysctl/fs.html
- Linux kernel — sysctl/kernel documentation (`randomize_va_space`, `kptr_restrict`, Yama): https://www.kernel.org/doc/html/latest/admin-guide/sysctl/kernel.html
- Linux kernel — Yama LSM (`ptrace_scope`): https://www.kernel.org/doc/html/latest/admin-guide/LSM/Yama.html
- Meltdown and Spectre — official disclosure site: https://meltdownattack.com/
- Intel — Transient Execution Attacks & Related Security Issues: https://www.intel.com/content/www/us/en/developer/topic-technology/software-security-guidance/overview.html
- AMD — Security Bulletins: https://www.amd.com/en/resources/product-security.html
- Google Project Zero — "Exploiting the DRAM rowhammer bug to gain kernel privileges": https://googleprojectzero.blogspot.com/2015/03/exploiting-dram-rowhammer-bug-to-gain.html
- CVE-2024-3094 — Red Hat advisory on the `xz`/liblzma backdoor: https://access.redhat.com/security/cve/CVE-2024-3094
- CVE-2024-6387 — Qualys advisory, "regreSSHion" OpenSSH signal-handler race: https://www.qualys.com/2024/07/01/cve-2024-6387/regresshion.txt
- CVE-2021-4034 — Qualys advisory, PwnKit polkit local privilege escalation: https://www.qualys.com/2022/01/25/cve-2021-4034/pwnkit.txt
- CVE-2021-3156 — Qualys advisory, sudo "Baron Samedit" heap overflow: https://www.qualys.com/2021/01/26/cve-2021-3156/baron-samedit-heap-based-overflow-sudo.txt
- Dirty Pipe (CVE-2022-0847) — original disclosure: https://dirtypipe.cm4all.com/
- Apache Log4j Security Vulnerabilities (CVE-2021-44228): https://logging.apache.org/log4j/2.x/security.html
- Red Hat — Security Data and OVAL feeds: https://access.redhat.com/security/data/
- Debian — Security Bug Tracker: https://security-tracker.debian.org/tracker/
- Ubuntu — Security Notices: https://ubuntu.com/security/notices
- SUSE — Security Advisories: https://www.suse.com/support/security/
- systemd — `systemd.exec(5)` sandboxing directives: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- systemd — `systemd-analyze(1)` (`security` verb): https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html
- nftables wiki — Meters, sets and rate limiting: https://wiki.nftables.org/wiki-nftables/index.php/Main_Page
- AIDE — Advanced Intrusion Detection Environment: https://aide.github.io/
- Fail2ban — official documentation: https://github.com/fail2ban/fail2ban
- OpenSCAP / SCAP Security Guide: https://www.open-scap.org/ · https://complianceascode.readthedocs.io/
- Lynis — security auditing tool: https://cisofy.com/lynis/
- Aqua Trivy — documentation: https://aquasecurity.github.io/trivy/
- Anchore Syft / Grype: https://github.com/anchore/syft · https://github.com/anchore/grype
- CycloneDX — SBOM and VEX specification: https://cyclonedx.org/specification/overview/
- SPDX — Software Package Data Exchange: https://spdx.dev/
- SLSA — Supply-chain Levels for Software Artifacts: https://slsa.dev/
- IETF — RFC 2827 (BCP 38), Network Ingress Filtering: https://www.rfc-editor.org/rfc/rfc2827
- IETF — RFC 4033/4034/4035, DNS Security Introduction and Requirements: https://www.rfc-editor.org/rfc/rfc4033
- IETF — RFC 7873, Domain Name System (DNS) Cookies: https://www.rfc-editor.org/rfc/rfc7873
- IETF — RFC 4987, TCP SYN Flooding Attacks and Common Mitigations: https://www.rfc-editor.org/rfc/rfc4987
- Debian Wiki — Hardening (compiler and toolchain flags): https://wiki.debian.org/Hardening
- GNU C Library manual — Dynamic linker and secure-execution mode (`ld.so(8)`): https://man7.org/linux/man-pages/man8/ld.so.8.html
- `capabilities(7)` — Linux capability model: https://man7.org/linux/man-pages/man7/capabilities.7.html
- `openat2(2)` — path resolution with `RESOLVE_*` flags: https://man7.org/linux/man-pages/man2/openat2.2.html
- `signal-safety(7)` — async-signal-safe functions: https://man7.org/linux/man-pages/man7/signal-safety.7.html
- `crypt(5)` — password hashing methods and prefixes: https://man7.org/linux/man-pages/man5/crypt.5.html