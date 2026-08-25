# LPIC-3 303 — Topic 332.3: Resource Control

**Exam:** 303-300 (Security), version 3.0.0 · **Objective weight:** 5.0
**Profile:** Principal Platform Architect / Senior SRE

---

## 1. Motivation: resource exhaustion is an availability attack

Security certifications teach confidentiality and integrity well, and availability badly. Resource control is the availability half of the CIA triad, and it is the only one of the three you cannot buy with cryptography.

Consider a production failure pattern every SRE eventually lives through:

> A single PHP-FPM pool on a shared host receives a crafted upload that triggers catastrophic backtracking in a regular expression. Worker RSS climbs from 60 MB to 6 GB in eleven seconds. The kernel OOM killer wakes up, scores every task on the box by `oom_score_adj`-weighted RSS, and kills… `postgres`, because the database is the largest well-behaved consumer on the machine. The attacker sent one HTTP request and took down the tier that mattered.

That is not a memory-safety bug. Nothing was overflowed, nothing was injected. It is a **containment failure**: an untrusted workload was allowed to consume a shared, finite, kernel-managed resource without a ceiling, and the kernel's default recovery heuristic picked the wrong victim.

The same shape recurs across the entire attack surface:

| Attack / fault | Resource exhausted | Kernel default outcome | Correct control |
|---|---|---|---|
| Fork bomb (`:(){ :\|:& };:`) | PIDs / task structs | Whole-host livelock, `fork()` fails for root too | `pids.max` / `TasksMax=` |
| ReDoS, decompression bomb | Anonymous memory | Global OOM kill of an unrelated victim | `memory.max` / `MemoryMax=` |
| FD leak, slowloris | File descriptors | `EMFILE`; `accept()` loop spins | `RLIMIT_NOFILE`, `LimitNOFILE=` |
| Runaway log writer | Disk bandwidth, inode/journal | fsync latency spikes cluster-wide | `io.max` / `IOWriteBandwidthMax=` |
| Crypto-miner in a compromised service | CPU | Latency SLO breach, no crash | `cpu.max` / `CPUQuota=` |
| Malicious `mlock()` of a huge region | Unswappable RAM | Reclaim collapse | `RLIMIT_MEMLOCK` |
| Core dump of a process holding TLS keys | Disk + **secret disclosure** | Private key on disk, world-readable in `/var/lib/systemd/coredump` | `RLIMIT_CORE=0`, `CoredumpFilter=` |

The last row is the one candidates forget: resource control is not only about availability. `RLIMIT_CORE` is a **confidentiality** control, because a core file is a verbatim dump of process memory, including session keys and decrypted secrets.

### The architectural requirement

A production host must satisfy three properties simultaneously:

1. **Bounded blast radius** — no single service, session, or tenant can degrade another below its SLO, regardless of whether the cause is a bug or an attacker.
2. **Deterministic degradation** — when a limit is hit, the failure must be *inside* the offending unit (throttling, `ENOMEM`, `EAGAIN`, targeted OOM kill), never a global heuristic that picks a victim you did not choose.
3. **Auditable enforcement** — the limit must be observable at runtime from the kernel's own accounting, not inferred from configuration files. Configuration that is silently not applied is the dominant failure mode in this topic.

Linux gives you **three distinct enforcement planes** to satisfy this, and confusing them is the single largest source of production incidents and exam mistakes.

---

## 2. The three enforcement planes

```
                       ┌───────────────────────────────────────┐
   PLANE 3             │  systemd resource control             │  policy / API
   (management)        │  .slice  .scope  .service, drop-ins   │
                       └──────────────┬────────────────────────┘
                                      │ writes
                       ┌──────────────▼────────────────────────┐
   PLANE 2             │  cgroups v2 (unified hierarchy)       │  group accounting
   (kernel, group)     │  /sys/fs/cgroup/**                    │  + enforcement
                       └───────────────────────────────────────┘
                       ┌───────────────────────────────────────┐
   PLANE 1             │  POSIX rlimits (setrlimit(2))         │  per-process
   (kernel, process)   │  ulimit, prlimit, pam_limits.so       │  enforcement
                       └───────────────────────────────────────┘
```

| Dimension | rlimits (Plane 1) | cgroups v2 (Plane 2) | systemd (Plane 3) |
|---|---|---|---|
| Unit of enforcement | One process (a few are per-UID) | A group of processes, hierarchically | A unit (service/scope/slice) |
| Set by | `setrlimit(2)`, `ulimit`, `prlimit`, `pam_limits.so` | Writing `/sys/fs/cgroup/**` files | Unit directives, `systemctl set-property`, D-Bus |
| Inheritance | Copied at `fork()`/`execve()`; changes do **not** propagate to running children | Live: move a PID into the cgroup and it is bound immediately | Live, via Plane 2 |
| Applies retroactively? | **No** — a running process keeps its limits unless you `prlimit --pid` | **Yes** | **Yes** |
| Aggregate accounting | No — 100 processes × 1 GB `RLIMIT_AS` = 100 GB | Yes — the group total is the limit | Yes |
| Enforcement style | Hard failure (`ENOMEM`, `EMFILE`, `EAGAIN`, `SIGXCPU`, `SIGXFSZ`) | Throttle, reclaim, back-pressure, **or** targeted OOM kill | Same as Plane 2 |
| CPU / IO bandwidth | Only total CPU *time* (`RLIMIT_CPU`), no rate | Yes — rate, weight, latency targets | Yes |
| Survives daemon restart | Only if re-applied | Cgroup is recreated by systemd | Yes (unit file / drop-in) |
| Applies to systemd services | **Only** via `Limit*=` directives — **never** via `limits.conf` | Yes | Yes |
| Applies to interactive logins | Yes, via `pam_limits.so` | Yes, via `user-<UID>.slice` | Yes |
| Exam term | `ulimit`, `limits.conf`, `pam_limits.so` | `/sys/fs/cgroup/` | `systemd-run`, `systemctl set-property`, `systemd-cgls`, `systemd-cgtop` |

**The rule that resolves 80 % of real incidents:** `/etc/security/limits.conf` is enforced by a **PAM session module**. A systemd system service has no PAM session. Therefore `limits.conf` has *zero* effect on `nginx.service`, `mysqld.service`, or anything else started by PID 1. For services you use `LimitNOFILE=`, `LimitNPROC=`, `LimitCORE=` in the unit. This is examined, and it is the first thing to check when "I raised nofile and it still says too many open files."

---

## 3. Plane 1 — POSIX resource limits (rlimits)

### 3.1 Mechanics

Every task has a `struct rlimit[RLIM_NLIMITS]` in its signal structure, each entry a pair:

```c
struct rlimit {
    rlim_t rlim_cur;  /* soft limit — the value actually enforced      */
    rlim_t rlim_max;  /* hard limit — the ceiling on rlim_cur          */
};
```

Rules, exactly:

- An unprivileged process may **raise the soft limit up to the hard limit**, and may **lower the hard limit irreversibly**.
- Raising a hard limit requires `CAP_SYS_RESOURCE` (in the process's user namespace).
- Limits are copied on `fork()` and preserved across `execve()`. They are therefore **inherited from the login shell**, which is why the shell built-in `ulimit` is where humans meet them.
- `prlimit(2)` (Linux ≥ 2.6.36) lets a privileged process change limits of a **running** process — the only way to fix a long-lived daemon without restarting it.
- `RLIMIT_NPROC` is **per real UID and system-wide**, not per session and not per cgroup. Two services running as the same user share the counter. This makes `LimitNPROC=` almost useless for service isolation; use `TasksMax=` instead.
- Root (`CAP_SYS_RESOURCE`) **bypasses** `RLIMIT_NPROC` and `RLIMIT_MEMLOCK` checks entirely.

### 3.2 The complete limit table

| `ulimit` | `RLIMIT_*` | Unit | Enforcement when exceeded | Security relevance |
|---|---|---|---|---|
| `-c` | `CORE` | 512-B blocks | Core dump truncated / suppressed | **Prevents memory disclosure**; set `0` for secret-handling daemons |
| `-d` | `DATA` | KiB | `brk()`/`mmap` of the data segment fails | Weak; modern allocators use `mmap` |
| `-e` | `NICE` | ceiling `20 - nice` | `setpriority()` returns `EACCES` | Stops priority-inversion abuse |
| `-f` | `FSIZE` | 512-B blocks | `SIGXFSZ`, then `EFBIG` | Bounds disk-fill DoS by one writer |
| `-i` | `SIGPENDING` | count | `sigqueue()` returns `EAGAIN` | Signal-flood DoS |
| `-l` | `MEMLOCK` | bytes | `mlock()`/`mlockall()` returns `ENOMEM` | Unswappable-memory DoS; must be raised for `gpg-agent`, DPDK, databases |
| `-m` | `RSS` | KiB | **No effect since Linux 2.4.30** | Trap — candidates set it and nothing happens |
| `-n` | `NOFILE` | count | `open()`/`accept()`/`socket()` return `EMFILE` | FD-exhaustion DoS; also caps `select()` at 1024 fds |
| `-q` | `MSGQUEUE` | bytes | `mq_open()` returns `ENOMEM` | Kernel-memory pinning |
| `-r` | `RTPRIO` | priority | `sched_setscheduler()` returns `EPERM` | **Critical**: an unbounded `SCHED_FIFO` task starves the whole CPU |
| `-s` | `STACK` | KiB | `SIGSEGV` on overflow | Deep-recursion crash containment |
| `-t` | `CPU` | seconds | `SIGXCPU` at soft, `SIGKILL` at hard | Bounds infinite loops in batch jobs |
| `-u` | `NPROC` | count | `fork()` returns `EAGAIN` | Fork-bomb defence **per UID**, root exempt |
| `-v` | `AS` | KiB | `mmap()`/`brk()` return `ENOMEM` | Blunt memory cap — **breaks JVM/Go**, which reserve huge virtual arenas |
| `-x` | `LOCKS` | count | `flock()` fails | Legacy, no effect on POSIX locks |
| `-T` | `RTTIME` | µs | `SIGXCPU` on an un-yielded RT task | Real-time watchdog |

> **Architectural note on `-v` (`RLIMIT_AS`).** It limits *virtual address space*, not resident memory. The Go runtime reserves hundreds of GiB of virtual arena; the JVM reserves the whole heap plus metaspace up front. Setting `RLIMIT_AS` to "2 GB" on either produces an immediate startup crash that looks nothing like a memory limit. **Never use `RLIMIT_AS` as a memory cap on a modern runtime — use `MemoryMax=` (cgroup v2), which accounts resident pages.**

### 3.3 Reading and setting limits

```
$ ulimit -a
real-time non-blocking time  (microseconds, -R) unlimited
core file size              (blocks, -c) 0
data seg size               (kbytes, -d) unlimited
scheduling priority                 (-e) 0
file size                   (blocks, -f) unlimited
pending signals                     (-i) 30465
max locked memory           (kbytes, -l) 8192
max memory size             (kbytes, -m) unlimited
open files                          (-n) 1024
pipe size                (512 bytes, -p) 8
POSIX message queues         (bytes, -q) 819200
real-time priority                  (-r) 0
stack size                  (kbytes, -s) 8192
cpu time                   (seconds, -t) unlimited
max user processes                  (-u) 30465
virtual memory              (kbytes, -v) unlimited
file locks                          (-x) unlimited
```

`-S` shows/sets the soft limit (the default for display), `-H` the hard limit:

```
$ ulimit -Sn
1024
$ ulimit -Hn
524288
$ ulimit -n 65536      # raise soft up to hard — allowed, unprivileged
$ ulimit -Sn
65536
$ ulimit -Hn 4096      # lower the hard limit — allowed, IRREVERSIBLE
$ ulimit -Hn 8192
bash: ulimit: open files: cannot modify limit: Operation not permitted
```

The authoritative per-process view — this is what you inspect during an incident, never the config file:

```
$ cat /proc/1421/limits
Limit                     Soft Limit           Hard Limit           Units
Max cpu time              unlimited            unlimited            seconds
Max file size             unlimited            unlimited            bytes
Max data size             unlimited            unlimited            bytes
Max stack size            8388608              unlimited            bytes
Max core file size        0                    unlimited            bytes
Max resident set          unlimited            unlimited            bytes
Max processes             30465                30465                processes
Max open files            1024                 524288               files
Max locked memory         8388608              8388608              bytes
Max address space         unlimited            unlimited            bytes
Max file locks            unlimited            unlimited            locks
Max pending signals       30465                30465                signals
Max msgqueue size         819200               819200               bytes
Max nice priority         0                    0
Max realtime priority     0                    0
Max realtime timeout      unlimited            unlimited            us
```

`prlimit(1)` from util-linux — query, change in place, or launch with a limit:

```
$ prlimit --pid 1421 --nofile
RESOURCE DESCRIPTION                   SOFT   HARD UNITS
NOFILE   max number of open files      1024 524288 files

# Fix a running daemon without restarting it (requires CAP_SYS_RESOURCE)
$ sudo prlimit --pid 1421 --nofile=65536:524288
$ grep 'Max open files' /proc/1421/limits
Max open files            65536                524288               files

# Launch a command under an explicit limit
$ prlimit --nproc=64 --as=1073741824 -- /usr/local/bin/batch-import
```

Live demonstration that limits are real, and that soft/hard differ:

```
$ ulimit -Sn 3
$ exec 9< /etc/hostname
bash: /etc/hostname: Too many open files
$ ulimit -Sn 1024
$ exec 9< /etc/hostname && echo ok
ok
$ exec 9<&-
```

`RLIMIT_CPU` producing the two-stage signal, exactly as specified:

```
$ prlimit --cpu=2:4 -- bash -c 'trap "echo SIGXCPU received >&2" XCPU; while :; do :; done'
SIGXCPU received
Killed
$ echo $?
137
```

Soft limit at 2 s → `SIGXCPU` (catchable, your chance to checkpoint and exit). Hard limit at 4 s → `SIGKILL` (`128 + 9 = 137`).

### 3.4 `pam_limits.so` and `/etc/security/limits.conf`

`pam_limits.so` is a **session** module. During PAM session setup (after authentication, before the shell is spawned) it parses `/etc/security/limits.conf` and `/etc/security/limits.d/*.conf` and calls `setrlimit(2)` for the matched entries. Everything downstream of that session inherits them.

**File format:**

```
<domain>      <type>  <item>  <value>
```

| Field | Accepted values |
|---|---|
| `domain` | username · `@groupname` · `*` (default, **excludes root**) · `%` or `%group` (`maxlogins` only) · UID range `1000:2000` · `@1000:2000` (GID range) · `:1000` (0…1000) · `1000:` (1000…∞) |
| `type` | `soft` · `hard` · `-` (both at once) |
| `item` | `core fsize data stack cpu nproc as memlock nofile rss locks sigpending msgqueue nice rtprio rttime maxlogins maxsyslogins priority chroot` |
| `value` | integer · `-1` / `unlimited` / `infinity` (not valid for `nice`, `priority`, `nofile`) |

**Precedence:** `pam_limits` ranks matches by specificity — an entry naming the literal **user** overrides a `@group` entry, which overrides the `*` default — independently of line order. Among entries of equal specificity, the last one parsed wins, and `limits.d/*.conf` is parsed after `limits.conf`, in lexical filename order. Confirm on your build with `pam_limits`' `debug` option (§7.4) rather than trusting the doc.

Production file for a shared bastion / multi-tenant application host:

```conf
# /etc/security/limits.d/50-hardening.conf
#
# Baseline for every interactive and PAM-mediated session.
# Enforced ONLY through pam_limits.so — has NO effect on systemd services.
# Service limits live in unit files (see /etc/systemd/system/*.d/).

# --- 1. Confidentiality: never write process memory to disk -----------------
#     A core file of a TLS terminator or a gpg-agent is a key disclosure.
*               hard    core            0
root            hard    core            0

# --- 2. Availability: fork-bomb containment ---------------------------------
#     RLIMIT_NPROC is per-UID and system-wide; root is exempt by design.
*               soft    nproc           1024
*               hard    nproc           2048
@developers     soft    nproc           2048
@developers     hard    nproc           4096
@ci-runner      -       nproc           512

# --- 3. Availability: FD exhaustion ----------------------------------------
#     Soft stays modest so legacy select()-based code does not corrupt fd_set;
#     the hard limit lets a well-behaved process raise its own soft limit.
*               soft    nofile          4096
*               hard    nofile          65536
@developers     soft    nofile          16384
@developers     hard    nofile          262144

# --- 4. Availability: unswappable memory and real-time starvation ----------
*               hard    memlock         65536
*               hard    rtprio          0
@audio          hard    rtprio          95
@audio          hard    memlock         unlimited

# --- 5. Session count: bound concurrent logins per human -------------------
@contractors    -       maxlogins       2
*               -       maxsyslogins    50

# --- 6. Batch/untrusted accounts: bounded CPU and file size ----------------
@batch          soft    cpu             30
@batch          hard    cpu             60
@batch          hard    fsize           2097152          # 1 GiB in 512-B blocks
```

**The stack must actually load the module.** On Red Hat–family systems:

```
$ grep -rn pam_limits /etc/pam.d/
/etc/pam.d/system-auth:26:session     required      pam_limits.so
/etc/pam.d/password-auth:24:session   required      pam_limits.so
/etc/pam.d/runuser:6:session          required      pam_limits.so
```

On Debian-family systems the include chain is `/etc/pam.d/common-session`:

```
# /etc/pam.d/common-session
session [default=1]     pam_permit.so
session requisite       pam_deny.so
session required        pam_permit.so
session optional        pam_systemd.so
session required        pam_unix.so
session required        pam_limits.so
```

**Gotchas that decide exam questions and outages:**

| Symptom | Cause |
|---|---|
| Limits apply on console login but not over SSH | `sshd` built without PAM, or `UsePAM no` in `sshd_config` |
| Limits apply with `su -` but not `su` | Different PAM files (`/etc/pam.d/su-l` vs `/etc/pam.d/su`), or the non-login shell never re-read the session |
| Limits apply to users but not root | `*` explicitly excludes root — you must write `root` entries |
| `nproc` limit "leaks" between two services | `RLIMIT_NPROC` is per-UID, counted host-wide, threads included |
| `limits.conf` ignored for `nginx` | Systemd service — no PAM session. Use `LimitNOFILE=` |
| `nproc` in `limits.conf` silently overridden | `/etc/security/limits.d/20-nproc.conf` ships a `*  soft  nproc  4096` on RHEL |
| `cron` jobs ignore the limits | Only if `pam_limits.so` is absent from `/etc/pam.d/crond` |

### 3.5 rlimits for systemd units

Same kernel mechanism, entirely different configuration surface. Every `Limit*=` directive accepts either one value (both soft and hard) or `soft:hard`:

```ini
LimitNOFILE=65536:524288
LimitCORE=0
LimitNPROC=512
LimitMEMLOCK=infinity
```

Defaults come from `/etc/systemd/system.conf` (`DefaultLimitNOFILE=`, `DefaultLimitCORE=`, …). Since systemd v240 the shipped default is `DefaultLimitNOFILE=1024:524288` — a deliberately low **soft** limit so that `select(2)`-based programs cannot corrupt their `fd_set`, with a high **hard** limit so modern programs can raise their own.

> **`LimitNOFILE=infinity` is a bug, not a setting.** It resolves to `/proc/sys/fs/nr_open` (1 048 576 by default, up to 2³⁰). Several runtimes iterate `0..RLIMIT_NOFILE` to close inherited descriptors at startup, turning boot into a multi-second busy loop. Always set a concrete number.

---

## 4. Plane 2 — Control groups

### 4.1 v1 versus v2

| Property | cgroup v1 | cgroup v2 (unified) |
|---|---|---|
| Hierarchies | One **per controller**; a process can sit in unrelated places in each | **One** hierarchy for all controllers |
| Mount layout | `tmpfs` on `/sys/fs/cgroup`, one `cgroup` fs per controller subdir | Single `cgroup2` fs on `/sys/fs/cgroup` |
| Detect | `stat -fc %T /sys/fs/cgroup/` → `tmpfs` | `stat -fc %T /sys/fs/cgroup/` → `cgroup2fs` |
| Controller enablement | Mount-time, global | Per-subtree via `cgroup.subtree_control` |
| Processes in inner nodes | Allowed (ambiguous resource attribution) | **Forbidden** ("no internal processes" rule), except root |
| Thread granularity | Native (any controller) | Only in explicit *threaded* subtrees; `cpu`, `cpuset`, `perf_event` |
| Memory + swap | `memory.limit_in_bytes` + `memsw` (needs `swapaccount=1`) | `memory.max` and `memory.swap.max` — **separate, independent** |
| Memory back-pressure | None — you get the limit or the OOM killer | `memory.high` (throttle+reclaim) before `memory.max` (kill) |
| Protection floors | None | `memory.min` (hard), `memory.low` (best-effort) |
| Writeback / buffered IO accounting | Broken — buffered writes attributed to `kworker` | Correct — memory and io controllers cooperate |
| Pressure metrics (PSI) | No | `cpu.pressure`, `memory.pressure`, `io.pressure` per cgroup |
| Delegation to unprivileged users | Unsafe | Safe and designed for it (`nsdelegate`, `Delegate=`) |
| Freezer | `freezer.state` | `cgroup.freeze` |
| Mass kill | Not atomic | `cgroup.kill` (Linux ≥ 5.14) |
| Status | Deprecated; kernel maintenance mode | The default on RHEL 9+, Fedora 31+, Debian 11+, Ubuntu 21.10+ |

**The v2 property that changes architecture:** unified accounting of page cache, buffered writeback and anonymous memory. On v1, a container writing 4 GB through the page cache charged its dirty pages to the kernel writeback threads, so its `blkio` limit did nothing. On v2 that write is charged to the originating cgroup and throttled by its `io.max`. Any real multi-tenant IO isolation requires v2.

Determine, and if necessary switch, the mode:

```
$ stat -fc %T /sys/fs/cgroup/
cgroup2fs

$ mount | grep cgroup
cgroup2 on /sys/fs/cgroup type cgroup2 (rw,nosuid,nodev,noexec,relatime,nsdelegate,memory_recursiveprot)

$ grep cgroup /proc/filesystems
nodev	cgroup
nodev	cgroup2
```

If it reports `tmpfs`, the host is on v1 (or hybrid). Force unified:

```
$ sudo grubby --update-kernel=ALL --args="systemd.unified_cgroup_hierarchy=1"
$ sudo reboot
```

Force legacy v1 (only for a legacy workload you cannot port):

```
$ sudo grubby --update-kernel=ALL --args="systemd.unified_cgroup_hierarchy=0"
```

For v1 hosts that must account swap, the memory controller needs help on some distributions:

```
GRUB_CMDLINE_LINUX="cgroup_enable=memory swapaccount=1"
```

### 4.2 Anatomy of the unified hierarchy

```
$ ls -1 /sys/fs/cgroup/
cgroup.controllers
cgroup.max.depth
cgroup.max.descendants
cgroup.pressure
cgroup.procs
cgroup.stat
cgroup.subtree_control
cgroup.threads
cpu.pressure
cpu.stat
cpuset.cpus.effective
cpuset.mems.effective
init.scope
io.cost.model
io.cost.qos
io.pressure
io.stat
machine.slice
memory.numa_stat
memory.pressure
memory.reclaim
memory.stat
misc.capacity
system.slice
user.slice

$ cat /sys/fs/cgroup/cgroup.controllers
cpuset cpu io memory hugetlb pids rdma misc

$ cat /sys/fs/cgroup/cgroup.subtree_control
cpuset cpu io memory pids
```

`cgroup.controllers` is *available* here; `cgroup.subtree_control` is *enabled for my children*. A controller must be enabled in every ancestor before a leaf can use it — this is the "top-down enablement" rule, and forgetting it produces the classic `echo: write error: No such file or directory`.

Two structural rules the exam probes:

1. **No internal processes.** A non-root cgroup may contain **either** processes **or** enabled controllers for its children, never both. This is why systemd puts every service in its own leaf and never in the slice itself.
2. **Top-down constraint, bottom-up accounting.** Limits are enforced along the whole path: the effective ceiling for a leaf is the minimum across its ancestors. Usage is summed upward.

The core interface files present in **every** cgroup:

| File | Meaning |
|---|---|
| `cgroup.procs` | R: PIDs in this cgroup. W: write **one** PID to migrate it (moves the whole thread group) |
| `cgroup.threads` | Same, per-thread; only meaningful in threaded subtrees |
| `cgroup.type` | `domain`, `domain threaded`, `threaded`, `domain invalid` |
| `cgroup.controllers` | Controllers available here (set by the parent's `subtree_control`) |
| `cgroup.subtree_control` | Controllers enabled for children; write `+cpu -io` |
| `cgroup.events` | `populated 0|1`, `frozen 0|1` — pollable with `inotify`/`poll(2)` |
| `cgroup.freeze` | Write `1` to SIGSTOP-equivalent the whole subtree, atomically |
| `cgroup.kill` | Write `1` to SIGKILL every task in the subtree, atomically (≥ 5.14) |
| `cgroup.max.depth` / `cgroup.max.descendants` | **Anti-fork-bomb for cgroups themselves** — bounds a delegated subtree |
| `cgroup.stat` | `nr_descendants`, `nr_dying_descendants` |
| `*.pressure` | PSI stall metrics for this subtree |

### 4.3 The memory controller: five knobs, not one

This is the most important table in the topic.

| File | systemd | Semantics | On breach |
|---|---|---|---|
| `memory.min` | `MemoryMin=` | **Hard protection floor.** Memory below this is never reclaimed | Reclaim skips the group; may drive the *parent* to OOM |
| `memory.low` | `MemoryLow=` | **Best-effort floor.** Reclaimed only when nothing unprotected is left | Group is reclaimed last |
| `memory.high` | `MemoryHigh=` | **Throttle ceiling.** Aggressive reclaim + deliberate allocator stall | Process slows down; **never killed** |
| `memory.max` | `MemoryMax=` | **Hard ceiling** | Reclaim, then **cgroup OOM killer** on the group's own tasks |
| `memory.swap.max` | `MemorySwapMax=` | Swap ceiling, independent of `memory.max` | Anonymous pages can no longer be swapped out |

**The production pattern is `MemoryHigh` *below* `MemoryMax`.** `MemoryHigh` converts a cliff into a ramp: the workload is throttled, latency rises, your alert fires, and a human intervenes — instead of a `SIGKILL` in the middle of a transaction. `MemoryMax` is the backstop that guarantees containment. Setting only `MemoryMax` means the first symptom you ever see is a dead process.

```
$ cd /sys/fs/cgroup/system.slice/nginx.service
$ cat memory.current memory.high memory.max memory.swap.current
201326592
1610612736
2147483648
0

$ cat memory.events
low 0
high 0
max 0
oom 0
oom_kill 0
oom_group_kill 0
```

`memory.events` is the **evidence file**. `high` counting up means you are throttling; `max` counting up means allocations are failing; `oom_kill` counting up means the group killed one of its own. A configuration review that never reads this file is an assumption, not a verification.

```
$ head -12 memory.stat
anon 142606336
file 50331648
kernel 8388608
kernel_stack 1310720
pagetables 2097152
percpu 42112
sock 262144
vmalloc 0
shmem 0
file_mapped 27262976
file_dirty 176128
file_writeback 0
```

`memory.oom.group=1` (systemd: `OOMPolicy=kill`) makes the cgroup OOM killer kill **every** task in the group atomically. Use it whenever a partially-killed process tree is worse than a dead one — which is nearly every multi-process daemon, because a surviving master with dead workers is a zombie service that still passes a TCP health check.

### 4.4 The cpu controller: weight versus quota

| File | systemd | Type | Behaviour when the host is idle |
|---|---|---|---|
| `cpu.weight` (1–10000, default 100) | `CPUWeight=` | **Relative share** | No effect — the group uses all it wants |
| `cpu.max` (`"$QUOTA $PERIOD"` µs) | `CPUQuota=`, `CPUQuotaPeriodSec=` | **Absolute ceiling** | **Still throttled** |
| `cpu.max.burst` | `CPUQuotaBurst=` | Credit for bursty workloads | Absorbs short spikes without throttling |
| `cpuset.cpus` | `AllowedCPUs=` | **Pinning** | Hard affinity, NUMA-relevant |
| `cpu.idle` | `CPUWeight=idle` (v252+) | `SCHED_IDLE` for the whole group | Runs only on otherwise-idle CPUs |

```
$ cat /sys/fs/cgroup/system.slice/render.service/cpu.max
150000 100000
```

150 000 µs of CPU time per 100 000 µs period = **1.5 CPUs**, equivalent to `CPUQuota=150%`.

**The throttling trap.** `cpu.max` is enforced per period. A 16-thread Java service with `CPUQuota=200%` exhausts its 200 ms budget in 12.5 ms of wall-clock time when all threads run, then sits frozen for the remaining 87.5 ms of the period. Average utilisation looks correct; p99 latency is destroyed. The evidence:

```
$ cat /sys/fs/cgroup/system.slice/api.service/cpu.stat
usage_usec 91827364
user_usec 74829183
system_usec 16998181
nr_periods 43210
nr_throttled 31889
throttled_usec 2874651000
nr_bursts 0
burst_usec 0
```

`nr_throttled / nr_periods = 73.8 %` of periods throttled, 2 874 s of accumulated stall. **Any `nr_throttled` growth on a latency-sensitive service is a production defect.** The three fixes, in order of preference: (1) replace `CPUQuota=` with `CPUWeight=` and let the scheduler arbitrate only under real contention; (2) shorten `CPUQuotaPeriodSec=` to 10–20 ms so stalls are shorter; (3) cap the runtime's own thread pool (`GOMAXPROCS`, `-XX:ActiveProcessorCount`) to match the quota.

**Use `CPUWeight=` for isolation, `CPUQuota=` only when you are selling a fixed capacity** (billing, tenant SLA, or a deliberately capped batch job).

### 4.5 The io controller

```
$ lsblk -o NAME,MAJ:MIN,SIZE,TYPE
NAME        MAJ:MIN  SIZE TYPE
nvme0n1     259:0   931.5G disk
├─nvme0n1p1 259:1     600M part
├─nvme0n1p2 259:2       1G part
└─nvme0n1p3 259:3   929.9G part

$ echo "259:0 rbps=104857600 wbps=52428800 riops=2000 wiops=1000" \
    | sudo tee /sys/fs/cgroup/tenant.slice/io.max
259:0 rbps=104857600 wbps=52428800 riops=2000 wiops=1000

$ cat /sys/fs/cgroup/tenant.slice/io.stat
259:0 rbytes=8471347200 wbytes=2147483648 rios=41230 wios=18827 dbytes=0 dios=0
```

| Mechanism | File | Character |
|---|---|---|
| Hard bandwidth/IOPS cap | `io.max` | Absolute, per device, wastes idle capacity |
| Proportional share | `io.weight` (1–10000) | Only under contention; needs `bfq` or `io.cost` |
| Latency target | `io.latency` | Protects a group by throttling *others* when its latency degrades |
| Cost model | `io.cost.qos`, `io.cost.model` | Device-calibrated proportional control (`iocost`) |

`io.max` requires the **major:minor of the physical device**, never a partition or a device-mapper node — throttling `dm-0` while the filesystem issues IO to `259:3` silently does nothing.

### 4.6 The pids controller — the fork-bomb kill switch

```
$ cat /sys/fs/cgroup/user.slice/user-1000.slice/pids.max
10813
$ cat /sys/fs/cgroup/user.slice/user-1000.slice/pids.current
94
$ cat /sys/fs/cgroup/user.slice/user-1000.slice/pids.events
max 0
```

Unlike `RLIMIT_NPROC`, `pids.max` is **per cgroup, hierarchical, counts threads, and root is not exempt**. It is the only correct fork-bomb defence on a modern host. `RLIMIT_NPROC` remains useful as a per-UID backstop; it is not a substitute.

### 4.7 Manual cgroup v2 lab — no systemd

This is the objective's "understand and configure cgroups" in its rawest form.

```
# 1. Enable the controllers we need for our children.
$ sudo mkdir -p /sys/fs/cgroup/lab
$ echo "+cpu +memory +pids +io" | sudo tee /sys/fs/cgroup/cgroup.subtree_control
+cpu +memory +pids +io

# 2. The child inherits availability, and must in turn enable them for ITS children.
$ cat /sys/fs/cgroup/lab/cgroup.controllers
cpuset cpu io memory pids

# 3. Apply limits: 0.25 CPU, 64 MiB RAM hard / 48 MiB throttle, no swap, 20 tasks.
$ echo "25000 100000" | sudo tee /sys/fs/cgroup/lab/cpu.max
25000 100000
$ echo 50331648        | sudo tee /sys/fs/cgroup/lab/memory.high
50331648
$ echo 67108864        | sudo tee /sys/fs/cgroup/lab/memory.max
67108864
$ echo 0               | sudo tee /sys/fs/cgroup/lab/memory.swap.max
0
$ echo 20              | sudo tee /sys/fs/cgroup/lab/pids.max
20
$ echo 1               | sudo tee /sys/fs/cgroup/lab/memory.oom.group
1

# 4. Move the current shell in and verify the migration.
$ echo $$ | sudo tee /sys/fs/cgroup/lab/cgroup.procs
4711
$ cat /proc/self/cgroup
0::/lab
```

Verify the memory ceiling with a deterministic allocator:

```
$ python3 -c "b = bytearray(200*1024*1024); print(len(b))"
Killed
$ cat /sys/fs/cgroup/lab/memory.events
low 0
high 47
max 12
oom 1
oom_kill 1
oom_group_kill 1
```

`high 47` — the throttle engaged 47 times first. `max 12` — twelve allocation attempts hit the hard wall. `oom_kill 1` — the **cgroup-local** OOM killer fired. Note what did *not* happen: no unrelated process on the host was touched. That is the entire architectural point.

```
$ sudo dmesg -T | tail -6
[Mon Aug 24 11:42:07 2026] python3 invoked oom-killer: gfp_mask=0x140cca(GFP_HIGHUSER_MOVABLE|__GFP_COMP), order=0, oom_score_adj=0
[Mon Aug 24 11:42:07 2026] memory: usage 65536kB, limit 65536kB, failcnt 12
[Mon Aug 24 11:42:07 2026] swap: usage 0kB, limit 0kB, failcnt 0
[Mon Aug 24 11:42:07 2026] Memory cgroup stats for /lab: anon:64512KB file:512KB kernel:512KB
[Mon Aug 24 11:42:07 2026] Tasks state (memory values in pages):
[Mon Aug 24 11:42:07 2026] Memory cgroup out of memory: Killed process 4993 (python3) total-vm:271488kB, anon-rss:65024kB, file-rss:3584kB, shmem-rss:0kB, UID:0 pgtables:216kB oom_score_adj:0
```

Verify the CPU ceiling:

```
$ timeout 10 bash -c 'while :; do :; done' &
[1] 5102
$ sleep 5; grep -E 'nr_throttled|throttled_usec' /sys/fs/cgroup/lab/cpu.stat
nr_throttled 49
throttled_usec 3712004
$ top -b -n1 -p 5102 | tail -2
    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
   5102 root      20   0    9068   3712   3200 R  25.0   0.0   0:01.26 bash
```

Verify the PID ceiling — the fork bomb is contained, and the shell survives:

```
$ bash -c ':(){ :|:& };:' &
[2] 5210
bash: fork: retry: Resource temporarily unavailable
bash: fork: retry: Resource temporarily unavailable
$ cat /sys/fs/cgroup/lab/pids.current /sys/fs/cgroup/lab/pids.events
20
max 1483

# Atomic cleanup — Linux >= 5.14
$ echo 1 | sudo tee /sys/fs/cgroup/lab/cgroup.kill
1
$ cat /sys/fs/cgroup/lab/pids.current
0
```

Teardown (a cgroup must be empty; `rmdir` only, never `rm -r`):

```
$ echo $$ | sudo tee /sys/fs/cgroup/cgroup.procs > /dev/null
$ sudo rmdir /sys/fs/cgroup/lab
```

> **Legacy sidebar (`libcgroup`).** `cgcreate`, `cgset`, `cgexec`, `cgclassify`, `cgconfigparser` with `/etc/cgconfig.conf` and `/etc/cgrules.conf` were the v1-era userspace. On a systemd host they **conflict with PID 1**, which owns the hierarchy and will overwrite or delete groups it did not create. Recognise the tools for the exam; on a systemd host, manage cgroups through systemd or through a properly `Delegate=`d subtree.

---

## 5. Plane 3 — systemd resource control

### 5.1 Slices, scopes, services

systemd is the sole legitimate owner of the cgroup hierarchy on a modern host — this is the "single-writer rule" of `systemd.io`. It exposes three unit types that map directly onto cgroup directories:

| Unit type | Cgroup role | Created by | Example |
|---|---|---|---|
| `.slice` | **Inner node.** Holds no processes; carries limits for the subtree | Administrator / systemd | `system.slice`, `user-1000.slice`, `tenant.slice` |
| `.service` | **Leaf.** Processes that systemd itself forked | Unit file | `nginx.service` |
| `.scope` | **Leaf.** Processes forked by *someone else*, registered with systemd | D-Bus registration (`logind`, `machined`, `podman`) | `session-3.scope`, `libpod-<id>.scope` |

The default tree:

```
-.slice                        (root)
├── init.scope                 PID 1 itself
├── system.slice               all system services
├── user.slice
│   └── user-1000.slice
│       ├── user@1000.service  the per-user systemd manager
│       │   ├── app.slice
│       │   ├── session.slice
│       │   └── background.slice
│       └── session-3.scope    the actual login session
└── machine.slice              VMs and containers (machined, podman, nspawn)
```

`Slice=` in a unit places it anywhere you like; slice names encode the hierarchy with `-`, so `tenant-web-blue.slice` lives at `/tenant.slice/tenant-web.slice/tenant-web-blue.slice` and **each intermediate slice must exist** (systemd auto-instantiates them from `-.slice` templates, but you should define them explicitly to carry limits).

```
$ systemd-cgls
Control group /:
-.slice
├─user.slice
│ └─user-1000.slice
│   ├─user@1000.service …
│   │ ├─session.slice
│   │ │ ├─dbus-broker.service
│   │ │ │ ├─2461 /usr/bin/dbus-broker-launch --scope user
│   │ │ │ └─2464 dbus-broker --log 4 --controller 10 --machine-id …
│   │ │ └─pipewire.service
│   │ │   └─2455 /usr/bin/pipewire
│   │ └─init.scope
│   │   ├─2440 /usr/lib/systemd/systemd --user
│   │   └─2443 (sd-pam)
│   └─session-3.scope
│     ├─2437 "sshd-session: dalmine [priv]"
│     ├─2452 "sshd-session: dalmine@pts/0"
│     ├─2453 -bash
│     └─2712 systemd-cgls
├─init.scope
│ └─1 /usr/lib/systemd/systemd --switched-root --system --deserialize=48
└─system.slice
  ├─nginx.service
  │ ├─1421 "nginx: master process /usr/sbin/nginx"
  │ ├─1422 "nginx: worker process"
  │ └─1423 "nginx: worker process"
  ├─sshd.service
  │ └─1198 "sshd: /usr/sbin/sshd -D [listener] 0 of 10-100 startups"
  └─systemd-journald.service
    └─892 /usr/lib/systemd/systemd-journald
```

```
$ systemd-cgtop -n 2 --depth=2
Control Group                          Tasks   %CPU   Memory  Input/s Output/s
/                                        412   14.3     3.2G        -        -
system.slice                             201   11.8     2.1G        -        -
system.slice/postgresql.service           42    8.9     1.4G     1.2M   820.0K
user.slice                                88    2.1   712.4M        -        -
tenant.slice                              61    0.3   402.1M        -        -
machine.slice                             12    0.0    88.6M        -        -
```

`systemd-cgtop` reports `-` for a column when the corresponding accounting is off. `MemoryAccounting=` and `TasksAccounting=` are implicit on cgroup v2 whenever the controller is enabled; `IOAccounting=` and `CPUAccounting=` may need enabling. Accounting is not free — it is cheap, but on a 200-service host prefer `DefaultCPUAccounting=yes` deliberately rather than per-unit sprawl.

### 5.2 Directive → kernel file map

This table *is* the topic. Memorise the left two columns.

| systemd directive | cgroup v2 file | Notes |
|---|---|---|
| `CPUAccounting=` | (enables `cpu`) | `cpu.stat` |
| `CPUWeight=`, `StartupCPUWeight=` | `cpu.weight` | 1–10000, default 100; `idle` since v252 |
| `CPUQuota=` | `cpu.max` (quota field) | `200%` → `200000 100000` |
| `CPUQuotaPeriodSec=` | `cpu.max` (period field) | Default 100 ms |
| `AllowedCPUs=`, `StartupAllowedCPUs=` | `cpuset.cpus` | |
| `AllowedMemoryNodes=` | `cpuset.mems` | NUMA |
| `MemoryAccounting=` | (enables `memory`) | |
| `MemoryMin=` | `memory.min` | Hard protection |
| `MemoryLow=` | `memory.low` | Best-effort protection |
| `MemoryHigh=` | `memory.high` | Throttle |
| `MemoryMax=` | `memory.max` | Hard cap → cgroup OOM |
| `MemorySwapMax=` | `memory.swap.max` | |
| `MemoryZSwapMax=` | `memory.zswap.max` | v250+ |
| `TasksAccounting=` | (enables `pids`) | |
| `TasksMax=` | `pids.max` | Absolute or `N%` of `kernel.pid_max` |
| `IOAccounting=` | (enables `io`) | `io.stat` |
| `IOWeight=`, `StartupIOWeight=` | `io.weight` | 1–10000 |
| `IODeviceWeight=` | `io.weight` per device | |
| `IOReadBandwidthMax=`, `IOWriteBandwidthMax=` | `io.max` `rbps=`/`wbps=` | Path or `maj:min` |
| `IOReadIOPSMax=`, `IOWriteIOPSMax=` | `io.max` `riops=`/`wiops=` | |
| `IODeviceLatencyTargetSec=` | `io.latency` | |
| `DeviceAllow=`, `DevicePolicy=` | eBPF cgroup device program | v1: `devices.allow` |
| `Delegate=`, `DelegateSubgroup=` | ownership of `cgroup.procs`, `cgroup.subtree_control` | |
| `OOMPolicy=kill` | `memory.oom.group=1` | |
| `ManagedOOMSwap=`, `ManagedOOMMemoryPressure=` | consumed by `systemd-oomd` | PSI-driven |
| `Slice=` | parent directory | |
| **`Limit*=`** | **none — `setrlimit(2)`** | **Different plane. Do not confuse.** |

### 5.3 Applying limits: three routes

**Route 1 — `systemd-run`, for experiments and one-shot jobs.** Creates a transient scope or service; nothing persists.

```
$ sudo systemd-run --unit=riskyjob --slice=untrusted.slice \
    -p MemoryMax=512M -p MemoryHigh=384M -p CPUQuota=25% \
    -p TasksMax=32 -p IOWriteBandwidthMax="/dev/nvme0n1 20M" \
    -p PrivateTmp=yes -p OOMPolicy=kill \
    /usr/local/bin/untrusted-importer /srv/incoming/batch.tar.zst
Running as unit: riskyjob.service; invocation ID: 8f2a1c9e4b7d43a08e21c3f5d6a9b0c1

$ systemctl status riskyjob.service
● riskyjob.service - /usr/local/bin/untrusted-importer /srv/incoming/batch.tar.zst
     Loaded: loaded (/run/systemd/transient/riskyjob.service; transient)
  Transient: yes
     Active: active (running) since Mon 2026-08-24 11:58:02 -03; 6s ago
   Main PID: 6142 (untrusted-impo)
      Tasks: 5 (limit: 32)
     Memory: 118.4M (high: 384.0M max: 512.0M available: 393.6M)
        CPU: 1.402s
     CGroup: /untrusted.slice/riskyjob.service
             └─6142 /usr/local/bin/untrusted-importer /srv/incoming/batch.tar.zst
```

Interactive containment for an ad-hoc shell — a genuinely useful bastion technique:

```
$ sudo systemd-run --pty --same-dir --wait --collect \
    --slice=untrusted.slice \
    -p MemoryMax=256M -p TasksMax=25 -p CPUQuota=20% \
    /bin/bash
Running as unit: run-u217.service
Press ^] three times within 1s to disconnect TTY.

# cat /proc/self/cgroup
0::/untrusted.slice/run-u217.service
# :(){ :|:& };:
bash: fork: retry: Resource temporarily unavailable
```

**Route 2 — `systemctl set-property`, for live changes.** Applied immediately *and* persisted as a drop-in.

```
$ sudo systemctl set-property nginx.service MemoryMax=2G MemoryHigh=1536M TasksMax=512
$ systemctl show nginx.service -p MemoryMax -p MemoryHigh -p TasksMax -p ControlGroup
ControlGroup=/system.slice/nginx.service
MemoryHigh=1610612736
MemoryMax=2147483648
TasksMax=512

$ cat /etc/systemd/system.control/nginx.service.d/50-MemoryMax.conf
# This is a drop-in unit file extension, created via "systemctl set-property"
# or an equivalent operation. Do not edit.
[Service]
MemoryMax=2147483648
```

`--runtime` writes to `/run/systemd/system.control/` instead and evaporates on reboot — the correct choice during an incident, when you want a change that cannot outlive the investigation:

```
$ sudo systemctl set-property --runtime postgresql.service IOWeight=200
```

**Route 3 — drop-in files, for configuration management.** The only route that belongs in Git.

```
$ sudo systemctl edit nginx.service
$ cat /etc/systemd/system/nginx.service.d/10-resources.conf
[Service]
MemoryHigh=1536M
MemoryMax=2G
$ sudo systemctl daemon-reload
```

`daemon-reload` re-applies cgroup properties to **running** units without restarting them — one of the few live-reconfiguration paths in Linux that genuinely works.

### 5.4 Host-wide defaults

```ini
# /etc/systemd/system.conf.d/10-resource-defaults.conf
#
# Applies to every SYSTEM service unless the unit overrides it.
# Reboot required for Default* changes to reach already-running units.

[Manager]
# --- rlimit defaults (Plane 1) ---------------------------------------------
# Low soft limit protects select(2)-based code; high hard limit lets modern
# daemons raise their own. Never use "infinity".
DefaultLimitNOFILE=1024:524288
DefaultLimitNPROC=4096:8192
DefaultLimitMEMLOCK=64K
DefaultLimitCORE=0

# --- cgroup defaults (Plane 2/3) -------------------------------------------
# 15% of kernel.pid_max. Bounds any single service's fork storm.
DefaultTasksMax=15%

DefaultCPUAccounting=yes
DefaultMemoryAccounting=yes
DefaultIOAccounting=yes
DefaultTasksAccounting=yes

# Kill the whole cgroup rather than leaving a decapitated process tree that
# still answers TCP health checks.
DefaultOOMPolicy=kill
```

```
$ systemctl show --property=DefaultTasksMax --property=DefaultLimitNOFILE
DefaultTasksMax=4915
DefaultLimitNOFILE=1024
$ sysctl kernel.pid_max
kernel.pid_max = 32768
```

For user sessions, the modern mechanism is a drop-in on the `user-.slice` **template** (the old `logind.conf` `UserTasksMax=` is deprecated):

```ini
# /etc/systemd/system/user-.slice.d/50-limits.conf
[Slice]
TasksMax=4096
MemoryHigh=6G
MemoryMax=8G
CPUWeight=100
```

```
$ systemctl cat user-.slice | head -20
# /usr/lib/systemd/system/user-.slice
[Unit]
Description=User Slice of UID %j
Documentation=man:user@.service(5)
...
[Slice]
TasksMax=33%

# /etc/systemd/system/user-.slice.d/50-limits.conf
[Slice]
TasksMax=4096
MemoryHigh=6G
MemoryMax=8G
CPUWeight=100
```

### 5.5 `systemd-oomd` — pressure-driven, pre-emptive OOM

The kernel OOM killer only acts when allocation has already failed. By then the host has been thrashing for tens of seconds. `systemd-oomd` watches **PSI** (Pressure Stall Information) per cgroup and kills the worst offender *before* the kernel is cornered.

```ini
# /etc/systemd/oomd.conf.d/10-policy.conf
[OOM]
SwapUsedLimit=90%
DefaultMemoryPressureLimit=60%
DefaultMemoryPressureDurationSec=20s
```

```ini
# /etc/systemd/system/tenant.slice.d/20-oomd.conf
[Slice]
ManagedOOMSwap=kill
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=50%
ManagedOOMPreference=avoid
```

```
$ oomctl
Dry Run: no
Swap Used Limit: 90.00%
Default Memory Pressure Limit: 60.00%
Default Memory Pressure Duration: 20s
System Context:
	Swap: Used: 1.2G Total: 8.0G
Swap Monitored CGroups:
	Path: /
		Swap Usage: (see System Context)
Memory Pressure Monitored CGroups:
	Path: /tenant.slice
		Memory Pressure Limit: 50.00%
		Pressure: Avg10: 3.11 Avg60: 1.02 Avg300: 0.44 Total: 41s
		Current Memory Usage: 402.1M
		Memory Min: 0B
		Memory Low: 0B
		Swap Usage: 0B
```

```
$ cat /sys/fs/cgroup/tenant.slice/memory.pressure
some avg10=3.11 avg60=1.02 avg300=0.44 total=41022193
full avg10=0.87 avg60=0.31 avg300=0.09 total=12889341
```

`some` = at least one task stalled on memory; `full` = *every* runnable task stalled — that second line is the one that correlates with user-visible outage. PSI is the correct leading indicator; `memory.current` is a lagging one.

### 5.6 Delegation

An unprivileged workload manager (rootless Podman, a build agent, a nested systemd) needs to create its own sub-cgroups. `Delegate=` hands it a subtree and makes systemd stop managing inside it:

```ini
# /etc/systemd/system/buildkitd.service.d/20-delegate.conf
[Service]
Delegate=cpu cpuset io memory pids

# Bound the delegated subtree so a compromised agent cannot create cgroups forever
TasksMax=8192
MemoryMax=16G
CPUQuota=400%
```

```
$ ls -ld /sys/fs/cgroup/system.slice/buildkitd.service
drwxr-xr-x. 4 buildkit buildkit 0 Aug 24 12:10 /sys/fs/cgroup/system.slice/buildkitd.service
$ ls -l /sys/fs/cgroup/system.slice/buildkitd.service/cgroup.{procs,subtree_control,threads}
-rw-r--r--. 1 buildkit buildkit 0 Aug 24 12:10 .../cgroup.procs
-rw-r--r--. 1 buildkit buildkit 0 Aug 24 12:10 .../cgroup.subtree_control
-rw-r--r--. 1 buildkit buildkit 0 Aug 24 12:10 .../cgroup.threads
```

Exactly three files are chowned — never the limit files, so the delegatee **cannot raise its own ceiling**. Combined with the `nsdelegate` mount option and `cgroup.max.descendants` / `cgroup.max.depth`, this is a genuine privilege boundary. Delegation is only safe on cgroup v2; the v1 equivalent was a known escape vector.

---

## 6. Complete build-out: a hardened multi-tenant application host

Threat model: three tenants share one host. Tenant code is **untrusted** — assume any tenant process may be attacker-controlled at any moment. Requirement: no tenant can degrade another, and no tenant can degrade the platform's own services (SSH, journald, monitoring).

### 6.1 Kernel and sysctl foundation

```conf
# /etc/sysctl.d/60-resource-control.conf
#
# System-wide ceilings. These are the ultimate backstop: cgroup and rlimit
# percentages are computed against them, so they must be set FIRST.

# Global PID space. DefaultTasksMax=15% is derived from this value.
kernel.pid_max = 262144
kernel.threads-max = 262144

# Global file-descriptor ceiling and the per-process hard cap that
# LimitNOFILE=infinity resolves to.
fs.file-max = 2097152
fs.nr_open = 1048576

# inotify is a classic silent exhaustion vector (one watch per file, per user).
fs.inotify.max_user_instances = 512
fs.inotify.max_user_watches = 524288

# Confidentiality: never dump a setuid process's memory.
fs.suid_dumpable = 0

# Prefer the cgroup OOM killer's targeted kill over global panic.
vm.panic_on_oom = 0
vm.overcommit_memory = 0

# Make PSI meaningful: keep some reclaim headroom on a large-memory host.
vm.min_free_kbytes = 262144
```

```
$ sudo sysctl --system
* Applying /etc/sysctl.d/60-resource-control.conf ...
kernel.pid_max = 262144
kernel.threads-max = 262144
fs.file-max = 2097152
fs.nr_open = 1048576
fs.inotify.max_user_instances = 512
fs.inotify.max_user_watches = 524288
fs.suid_dumpable = 0
vm.panic_on_oom = 0
vm.overcommit_memory = 0
vm.min_free_kbytes = 262144
```

### 6.2 Protect the platform before capping the tenants

Protection floors matter more than ceilings. A host where every tenant is capped but SSH has no reservation still becomes unreachable under pressure.

```ini
# /etc/systemd/system/system.slice.d/10-platform-protection.conf
#
# system.slice must always win against tenant.slice and user.slice.
[Slice]
CPUWeight=1000
IOWeight=1000
MemoryMin=2G
MemoryLow=4G
```

```ini
# /etc/systemd/system/sshd.service.d/10-lifeline.conf
#
# The administrative lifeline. If this dies, the incident becomes an outage.
[Service]
MemoryMin=128M
MemoryLow=256M
CPUWeight=2000
IOWeight=1000
OOMScoreAdjust=-900
ManagedOOMMemoryPressure=auto
ManagedOOMPreference=omit
TasksMax=512
LimitNOFILE=16384:65536
LimitCORE=0
```

```ini
# /etc/systemd/system/systemd-journald.service.d/10-protect.conf
[Service]
MemoryMin=64M
MemoryLow=192M
IOWeight=800
```

### 6.3 The tenant slice hierarchy

```ini
# /etc/systemd/system/tenant.slice
[Unit]
Description=Aggregate slice for all untrusted tenant workloads
Documentation=man:systemd.slice(5) man:systemd.resource-control(5)
Before=slices.target

[Slice]
# --- Aggregate ceiling: all tenants together never exceed this -------------
CPUAccounting=yes
MemoryAccounting=yes
IOAccounting=yes
TasksAccounting=yes

# Loses every contest against system.slice (weight 1000).
CPUWeight=100
IOWeight=100

# Hard aggregate cap. 24 GiB of a 64 GiB host.
MemoryHigh=20G
MemoryMax=24G
MemorySwapMax=2G

# Aggregate fork-bomb ceiling.
TasksMax=8192

# Pressure-driven pre-emptive kill, before the kernel is cornered.
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=50%
ManagedOOMSwap=kill
ManagedOOMPreference=avoid
```

```ini
# /etc/systemd/system/tenant-blue.slice
[Unit]
Description=Tenant BLUE - contracted 2 vCPU / 8 GiB
After=tenant.slice
Requires=tenant.slice

[Slice]
Slice=tenant.slice

# Absolute capacity ceiling: this is a billing boundary, so CPUQuota (not
# CPUWeight) is correct here despite the throttling cost. The tenant's
# runtime must be told to size its thread pool to 2 (GOMAXPROCS / -XX:ActiveProcessorCount)
# or p99 latency will suffer -- see cpu.stat nr_throttled.
CPUQuota=200%
CPUQuotaPeriodSec=20ms
CPUWeight=100

MemoryHigh=6G
MemoryMax=8G
MemorySwapMax=512M

TasksMax=1024

IOWeight=100
IOReadBandwidthMax=/dev/nvme0n1 200M
IOWriteBandwidthMax=/dev/nvme0n1 100M
IOReadIOPSMax=/dev/nvme0n1 8000
IOWriteIOPSMax=/dev/nvme0n1 4000
```

```ini
# /etc/systemd/system/tenant-green.slice
[Unit]
Description=Tenant GREEN - contracted 1 vCPU / 4 GiB
After=tenant.slice
Requires=tenant.slice

[Slice]
Slice=tenant.slice
CPUQuota=100%
CPUQuotaPeriodSec=20ms
CPUWeight=100
MemoryHigh=3G
MemoryMax=4G
MemorySwapMax=256M
TasksMax=512
IOWeight=100
IOReadBandwidthMax=/dev/nvme0n1 100M
IOWriteBandwidthMax=/dev/nvme0n1 50M
```

```ini
# /etc/systemd/system/tenant-batch.slice
[Unit]
Description=Best-effort batch work - yields to everything
After=tenant.slice
Requires=tenant.slice

[Slice]
Slice=tenant.slice

# SCHED_IDLE for the whole subtree: runs only on otherwise-idle CPUs.
# Requires systemd >= v252; on older systemd use CPUWeight=1.
CPUWeight=idle
IOWeight=1

MemoryHigh=2G
MemoryMax=4G
# No protection floor at all: first to be reclaimed, first to be killed.
MemoryLow=0
TasksMax=256
ManagedOOMMemoryPressure=kill
ManagedOOMPreference=avoid
```

### 6.4 A tenant service unit — resource control plus process hardening

```ini
# /etc/systemd/system/blue-api.service
[Unit]
Description=Tenant BLUE public API
Documentation=https://docs.kernel.org/admin-guide/cgroup-v2.html
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=tenant-blue
Group=tenant-blue
WorkingDirectory=/srv/tenants/blue
ExecStart=/srv/tenants/blue/bin/api --config /srv/tenants/blue/etc/api.yaml
Restart=on-failure
RestartSec=5s

# ===========================================================================
# PLANE 3/2 - cgroup resource control (aggregate, hierarchical, live)
# ===========================================================================
Slice=tenant-blue.slice

CPUAccounting=yes
MemoryAccounting=yes
IOAccounting=yes
TasksAccounting=yes

# Ramp before the cliff: MemoryHigh throttles and alerts, MemoryMax contains.
MemoryHigh=3G
MemoryMax=4G
MemorySwapMax=0

# Relative share INSIDE tenant-blue.slice; the slice's CPUQuota still applies.
CPUWeight=200
IOWeight=200

TasksMax=512

# Kill the whole process tree. A surviving master with dead workers still
# accepts TCP connections and silently blackholes traffic.
OOMPolicy=kill
OOMScoreAdjust=500

# ===========================================================================
# PLANE 1 - POSIX rlimits (per process, inherited, hard failure)
# ===========================================================================
LimitNOFILE=32768:65536
LimitNPROC=512
LimitCORE=0
LimitMEMLOCK=0
LimitRTPRIO=0
LimitFSIZE=10737418240

# ===========================================================================
# Process hardening that complements resource control (topic 332.1)
# ===========================================================================
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ReadWritePaths=/srv/tenants/blue/var
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@resources @privileged @mount

# Device access is enforced by an eBPF cgroup program on v2.
DevicePolicy=closed
DeviceAllow=/dev/null rw
DeviceAllow=/dev/urandom r

[Install]
WantedBy=multi-user.target
```

> `SystemCallFilter=~@resources` blocks `setrlimit`, `setpriority`, `sched_setaffinity`, `mbind`, `migrate_pages` and friends — it stops the service raising its own soft limits or repinning itself. It complements the cgroup limits rather than duplicating them: cgroups bound *consumption*, seccomp bounds *reconfiguration*. `ProtectControlGroups=yes` remounts `/sys/fs/cgroup` read-only inside the unit, closing the direct-write path.

### 6.5 Session-side limits for the same host

```conf
# /etc/security/limits.d/60-tenant-sessions.conf
# Plane 1 backstop for interactive tenant logins. The cgroup limits above
# already bound aggregate usage; these bound a single runaway process and
# a single UID.

@tenant-blue    soft    nproc           256
@tenant-blue    hard    nproc           512
@tenant-blue    soft    nofile          8192
@tenant-blue    hard    nofile          32768
@tenant-blue    -       core            0
@tenant-blue    -       maxlogins       4
@tenant-blue    hard    memlock         0
@tenant-blue    hard    rtprio          0
@tenant-blue    hard    nice            0
```

```ini
# /etc/systemd/system/user-.slice.d/60-tenant-sessions.conf
# Plane 2/3: bound the login session itself, which limits.conf cannot do
# in aggregate.
[Slice]
CPUWeight=50
IOWeight=50
MemoryHigh=1G
MemoryMax=2G
TasksMax=512
```

### 6.6 Apply and confirm

```
$ sudo systemctl daemon-reload
$ sudo systemctl restart systemd-oomd.service
$ sudo systemctl enable --now blue-api.service
Created symlink /etc/systemd/system/multi-user.target.wants/blue-api.service → /etc/systemd/system/blue-api.service.

$ systemctl status blue-api.service
● blue-api.service - Tenant BLUE public API
     Loaded: loaded (/etc/systemd/system/blue-api.service; enabled; preset: disabled)
     Active: active (running) since Mon 2026-08-24 12:31:44 -03; 12s ago
       Docs: https://docs.kernel.org/admin-guide/cgroup-v2.html
   Main PID: 7214 (api)
      Tasks: 27 (limit: 512)
     Memory: 412.8M (high: 3.0G max: 4.0G swap max: 0B available: 3.6G)
        CPU: 3.918s
     CGroup: /tenant.slice/tenant-blue.slice/blue-api.service
             └─7214 /srv/tenants/blue/bin/api --config /srv/tenants/blue/etc/api.yaml

$ systemd-cgls /tenant.slice
Control group /tenant.slice:
├─tenant-blue.slice
│ └─blue-api.service
│   └─7214 /srv/tenants/blue/bin/api --config /srv/tenants/blue/etc/api.yaml
├─tenant-green.slice
│ └─green-worker.service
│   └─7388 /srv/tenants/green/bin/worker
└─tenant-batch.slice
  └─nightly-etl.service
    └─7501 /usr/local/bin/etl --window 24h
```

---

## 7. Verification and failure diagnosis

**Doctrine: never verify a limit from the file that declares it.** Verify from the kernel — `/proc/<pid>/limits`, `/sys/fs/cgroup/**`, `systemctl show`. Configuration that is present but not applied is the normal case, not the exception.

### 7.1 The verification ladder

```bash
#!/usr/bin/env bash
# /usr/local/sbin/verify-resource-control
# Prove, from kernel state, that a unit's limits are actually in force.
set -euo pipefail

unit="${1:?usage: verify-resource-control <unit>}"

echo "=== 1. cgroup mode ==="
stat -fc '%T' /sys/fs/cgroup/     # expect: cgroup2fs

echo "=== 2. systemd's view of the properties ==="
systemctl show "$unit" \
  -p Slice -p ControlGroup -p MemoryMax -p MemoryHigh -p MemoryMin \
  -p CPUQuotaPerSecUSec -p CPUWeight -p TasksMax -p IOWeight \
  -p LimitNOFILESoft -p LimitNOFILE -p LimitCORE -p OOMPolicy

cg=$(systemctl show -P ControlGroup "$unit")
[ -n "$cg" ] || { echo "unit has no cgroup (not running?)"; exit 1; }
d="/sys/fs/cgroup${cg}"

echo "=== 3. the kernel's view (cgroup v2) ==="
for f in cpu.max cpu.weight memory.min memory.low memory.high memory.max \
         memory.swap.max memory.current pids.max pids.current io.max io.weight; do
    [ -e "$d/$f" ] && printf '%-18s %s\n' "$f" "$(cat "$d/$f" 2>/dev/null | tr '\n' ' ')"
done

echo "=== 4. breach evidence ==="
printf 'memory.events:\n'; cat "$d/memory.events" 2>/dev/null || true
printf 'pids.events:\n';   cat "$d/pids.events"   2>/dev/null || true
printf 'cpu.stat:\n';      grep -E 'nr_throttled|throttled_usec' "$d/cpu.stat" 2>/dev/null || true

echo "=== 5. pressure (leading indicator) ==="
for p in cpu.pressure memory.pressure io.pressure; do
    [ -e "$d/$p" ] && { printf '%s:\n' "$p"; cat "$d/$p"; }
done

echo "=== 6. rlimits actually in force on the main PID ==="
pid=$(systemctl show -P MainPID "$unit")
[ "$pid" != "0" ] && cat "/proc/$pid/limits"
```

```
$ sudo /usr/local/sbin/verify-resource-control blue-api.service
=== 1. cgroup mode ===
cgroup2fs
=== 2. systemd's view of the properties ===
Slice=tenant-blue.slice
ControlGroup=/tenant.slice/tenant-blue.slice/blue-api.service
MemoryMin=0
MemoryHigh=3221225472
MemoryMax=4294967296
CPUWeight=200
CPUQuotaPerSecUSec=infinity
TasksMax=512
IOWeight=200
LimitNOFILE=65536
LimitNOFILESoft=32768
LimitCORE=0
OOMPolicy=kill
=== 3. the kernel's view (cgroup v2) ===
cpu.max            max 20000
cpu.weight         200
memory.min         0
memory.low         0
memory.high        3221225472
memory.max         4294967296
memory.swap.max    0
memory.current     432799744
pids.max           512
pids.current       27
io.weight          default 200
=== 4. breach evidence ===
memory.events:
low 0
high 0
max 0
oom 0
oom_kill 0
oom_group_kill 0
pids.events:
max 0
cpu.stat:
nr_throttled 0
throttled_usec 0
=== 5. pressure (leading indicator) ===
cpu.pressure:
some avg10=0.00 avg60=0.02 avg300=0.01 total=1204881
full avg10=0.00 avg60=0.00 avg300=0.00 total=0
memory.pressure:
some avg10=0.00 avg60=0.00 avg300=0.00 total=0
full avg10=0.00 avg60=0.00 avg300=0.00 total=0
io.pressure:
some avg10=0.11 avg60=0.09 avg300=0.04 total=8842019
full avg10=0.03 avg60=0.02 avg300=0.01 total=2213004
=== 6. rlimits actually in force on the main PID ===
Limit                     Soft Limit           Hard Limit           Units
Max cpu time              unlimited            unlimited            seconds
Max file size             10737418240          10737418240          bytes
...
Max core file size        0                    0                    bytes
Max processes             512                  512                  processes
Max open files            32768                65536                files
Max locked memory         0                    0                    bytes
```

Note line 3: `cpu.max` reads `max 20000` on the **service**, because the quota lives on the parent slice. Always read the whole ancestor path — the effective limit is the minimum along it:

```
$ for d in /sys/fs/cgroup /sys/fs/cgroup/tenant.slice \
           /sys/fs/cgroup/tenant.slice/tenant-blue.slice \
           /sys/fs/cgroup/tenant.slice/tenant-blue.slice/blue-api.service; do
    printf '%-70s cpu.max=%-16s memory.max=%s\n' "$d" \
      "$(cat $d/cpu.max 2>/dev/null | tr '\n' ' ')" "$(cat $d/memory.max 2>/dev/null)"
  done
/sys/fs/cgroup                                                         cpu.max=                 memory.max=
/sys/fs/cgroup/tenant.slice                                            cpu.max=max 100000       memory.max=25769803776
/sys/fs/cgroup/tenant.slice/tenant-blue.slice                          cpu.max=200000 20000     memory.max=8589934592
/sys/fs/cgroup/tenant.slice/tenant-blue.slice/blue-api.service         cpu.max=max 20000        memory.max=4294967296
```

### 7.2 Failure catalogue

| Symptom | Likely cause | Confirming command |
|---|---|---|
| `Too many open files` after raising `limits.conf` | Service has no PAM session | `cat /proc/$(pidof x)/limits`; fix with `LimitNOFILE=` |
| `limits.conf` works on console, not over SSH | `UsePAM no`, or `pam_limits.so` missing from `sshd`'s stack | `sshd -T \| grep usepam`; `grep pam_limits /etc/pam.d/sshd` |
| `nproc` limit smaller than configured | RHEL ships `/etc/security/limits.d/20-nproc.conf` | `grep -r nproc /etc/security/limits.d/` |
| Two services as the same user hit `fork: EAGAIN` early | `RLIMIT_NPROC` is per-UID host-wide | Switch to `TasksMax=` |
| `MemoryMax=` "ignored" | Host on cgroup v1 | `stat -fc %T /sys/fs/cgroup/` |
| `write error: No such file or directory` on a cgroup file | Controller not in the parent's `subtree_control` | `cat ../cgroup.subtree_control` |
| `write error: Device or resource busy` on `subtree_control` | Processes present in an inner node ("no internal processes") | `cat cgroup.procs` |
| CPU-capped service has correct average but awful p99 | CFS quota throttling | `grep nr_throttled cpu.stat` |
| Service killed but `journalctl` shows no OOM | `systemd-oomd` acted on PSI, not the kernel | `journalctl -u systemd-oomd`; `oomctl` |
| Only some workers died; service is a zombie | `OOMPolicy` not `kill` / `memory.oom.group=0` | `cat memory.oom.group`; set `OOMPolicy=kill` |
| Limits vanish after reboot | `systemctl set-property --runtime` was used | `ls /run/systemd/system.control/` |
| JVM/Go crashes at start under a memory cap | `RLIMIT_AS` (`ulimit -v`) set instead of `MemoryMax=` | `grep 'Max address space' /proc/<pid>/limits` |
| IO throttle has no effect | `io.max` written for a partition or `dm-*` instead of the physical device | `lsblk -o NAME,MAJ:MIN`; `cat io.stat` |
| Buffered writes escape the IO cap | cgroup v1 (writeback charged to `kworker`) | Migrate to v2 |
| `systemd-cgtop` shows `-` in a column | Accounting disabled for that controller | `systemctl show -p IOAccounting <unit>` |

### 7.3 Diagnosing the two canonical incidents

**A: "the service keeps dying and nothing is in `dmesg`."**

```
$ systemctl status green-worker.service | head -8
● green-worker.service - Tenant GREEN worker
     Active: failed (Result: oom-kill) since Mon 2026-08-24 13:02:19 -03; 40s ago
    Process: 7388 ExecStart=/srv/tenants/green/bin/worker (code=killed, signal=KILL)

$ journalctl -u green-worker.service -n 5 --no-pager
Aug 24 13:02:19 host systemd[1]: green-worker.service: A process of this unit has been killed by the OOM killer.
Aug 24 13:02:19 host systemd[1]: green-worker.service: Main process exited, code=killed, status=9/KILL
Aug 24 13:02:19 host systemd[1]: green-worker.service: Failed with result 'oom-kill'.

$ cat /sys/fs/cgroup/tenant.slice/tenant-green.slice/memory.events
low 0
high 8421
max 193
oom 4
oom_kill 4
oom_group_kill 4
```

`high 8421` says the workload spent a long time being throttled before it died — the leak was visible for minutes. That is the alert you were missing: **alert on `memory.events:high` increasing, not on the OOM kill.**

If `journalctl -k` shows nothing at all, the killer was userspace:

```
$ journalctl -u systemd-oomd -n 3 --no-pager
Aug 24 13:02:19 host systemd-oomd[981]: Considered 3 cgroups for killing, top candidate was: /tenant.slice/tenant-green.slice
Aug 24 13:02:19 host systemd-oomd[981]: Memory pressure for /tenant.slice/tenant-green.slice is 61.42% > 50.00% for > 20s with reclaim activity
Aug 24 13:02:19 host systemd-oomd[981]: Killed /tenant.slice/tenant-green.slice due to memory pressure
```

**B: "CPU usage is only 45 % but latency doubled."**

```
$ cat /sys/fs/cgroup/tenant.slice/tenant-blue.slice/cpu.stat
usage_usec 412887210
user_usec  361029844
system_usec 51857366
nr_periods 1204118
nr_throttled 812440
throttled_usec 91224881000

$ cat /sys/fs/cgroup/tenant.slice/tenant-blue.slice/cpu.pressure
some avg10=41.22 avg60=38.90 avg300=35.11 total=6188221004
full avg10=29.87 avg60=27.44 avg300=25.02 total=4011889231
```

67 % of periods throttled, and `full avg10=29.87` means for ~30 % of the last 10 seconds **every** task in the tenant was stalled waiting for CPU. Average utilisation is a lie; PSI is the truth. Remediation: shorten the period, or replace the quota with a weight.

```
$ sudo systemctl set-property --runtime tenant-blue.slice CPUQuotaPeriodSec=10ms
$ sleep 60; grep nr_throttled /sys/fs/cgroup/tenant.slice/tenant-blue.slice/cpu.stat
nr_throttled 812440
```

(The counter is cumulative — compare deltas, never absolutes.)

### 7.4 Debugging `pam_limits` itself

```
$ sudo cp /etc/pam.d/sshd{,.bak}
$ sudo sed -i 's/^\(session.*pam_limits.so\)/\1 debug/' /etc/pam.d/sshd
$ ssh tenant-blue@localhost true
$ sudo journalctl -t sshd -n 12 --no-pager | grep pam_limits
sshd[8112]: pam_limits(sshd:session): reading settings from '/etc/security/limits.conf'
sshd[8112]: pam_limits(sshd:session): reading settings from '/etc/security/limits.d/20-nproc.conf'
sshd[8112]: pam_limits(sshd:session): reading settings from '/etc/security/limits.d/60-tenant-sessions.conf'
sshd[8112]: pam_limits(sshd:session): checking limits for 'tenant-blue'
sshd[8112]: pam_limits(sshd:session): setting NPROC soft=256 hard=512
sshd[8112]: pam_limits(sshd:session): setting NOFILE soft=8192 hard=32768
sshd[8112]: pam_limits(sshd:session): setting CORE soft=0 hard=0
$ sudo mv /etc/pam.d/sshd.bak /etc/pam.d/sshd
```

This is the only way to settle precedence questions definitively on your build. Remove `debug` when you are done — the output is verbose and names accounts.

### 7.5 Non-destructive containment test

Before declaring a host hardened, attack it — from inside the box the limits are supposed to protect.

```
$ sudo systemd-run --pty --wait --collect --slice=tenant-batch.slice \
    -p MemoryMax=128M -p TasksMax=30 -p CPUQuota=10% -p OOMPolicy=kill /bin/bash
Running as unit: run-u311.service

# --- fork bomb: must be contained, host must stay responsive ---
# :(){ :|:& };:
bash: fork: retry: Resource temporarily unavailable
bash: fork: Resource temporarily unavailable

# --- memory bomb: must kill only this cgroup ---
# python3 -c "b=bytearray(400*1024*1024)"
Killed

# --- cpu bomb: must throttle to 10% ---
# (for i in $(seq 4); do while :; do :; done & done); sleep 5; kill %1 %2 %3 %4
```

From a second terminal, the host is unaffected:

```
$ uptime
 13:20:44 up 6 days,  2:11,  3 users,  load average: 4.02, 1.88, 0.94
$ systemd-cgtop -n 1 --depth=2 | head -6
Control Group                            Tasks   %CPU   Memory  Input/s Output/s
/                                          448   10.4     3.4G        -        -
tenant.slice                                92   10.1   612.7M        -        -
tenant.slice/tenant-batch.slice             30   10.0   128.0M        -        -
system.slice                               203    0.3     2.1G        -        -
```

Load average is 4.02 because four spinners are runnable — but they collectively consume 10 % of one CPU, and `system.slice` is untouched. Load average measures *runnable tasks*, not consumed capacity; under cgroup throttling the two decouple completely. Monitor PSI, not load average.

---

## 8. Quick reference for the exam

| Task | Command |
|---|---|
| Show all current limits | `ulimit -a` |
| Show/set soft vs hard | `ulimit -Sn` / `ulimit -Hn` / `ulimit -Hn 4096` |
| Limits of a running process | `cat /proc/<pid>/limits` · `prlimit --pid <pid>` |
| Change a running process's limit | `prlimit --pid <pid> --nofile=65536:524288` |
| Launch with a limit | `prlimit --nproc=64 -- cmd` |
| Session limits config | `/etc/security/limits.conf`, `/etc/security/limits.d/*.conf` |
| Enforcing module | `session required pam_limits.so` |
| Detect cgroup version | `stat -fc %T /sys/fs/cgroup/` → `cgroup2fs` \| `tmpfs` |
| Show the cgroup tree | `systemd-cgls` |
| Live per-cgroup usage | `systemd-cgtop` |
| Transient limited unit | `systemd-run -p MemoryMax=512M -p CPUQuota=25% --slice=x.slice cmd` |
| Interactive contained shell | `systemd-run --pty --wait --collect -p TasksMax=25 /bin/bash` |
| Change a unit's limits live | `systemctl set-property nginx.service MemoryMax=2G` |
| Change without persisting | `systemctl set-property --runtime …` |
| Read effective properties | `systemctl show <unit> -p MemoryMax -p TasksMax -p ControlGroup` |
| Host-wide service defaults | `/etc/systemd/system.conf` (`DefaultLimitNOFILE=`, `DefaultTasksMax=`) |
| Cgroup of a process | `cat /proc/<pid>/cgroup` |
| Pressure metrics | `cat /sys/fs/cgroup/<path>/{cpu,memory,io}.pressure` |
| oomd state | `oomctl` |

**Ten facts that decide questions:**

1. `limits.conf` is PAM-only; it has **no** effect on systemd services.
2. `*` in `limits.conf` does **not** match root.
3. `ulimit -m` (`RLIMIT_RSS`) does nothing on modern Linux.
4. `RLIMIT_NPROC` is per-**UID**, host-wide, counts threads, root exempt. `pids.max` is per-cgroup, hierarchical, no exemption.
5. Lowering a hard limit is irreversible without `CAP_SYS_RESOURCE`.
6. `CPUWeight=` is relative and only bites under contention; `CPUQuota=` is absolute and throttles even on an idle host.
7. `MemoryHigh=` throttles; `MemoryMax=` kills. Set both, `High` below `Max`.
8. cgroup v2 forbids processes in inner (non-root) cgroups.
9. A controller must be enabled top-down via each ancestor's `cgroup.subtree_control`.
10. `Limit*=` are rlimits; every other resource directive is a cgroup. Different planes, different semantics, different failure modes.

---

## 9. Referencias

**Exam objectives**
- LPI — Exam 303 (Security) Objectives, version 3.0: https://www.lpi.org/our-certifications/exam-303-objectives/
- LPIC-3 Security overview: https://www.lpi.org/our-certifications/lpic-3-303-overview/

**Kernel documentation**
- Control Group v2 (authoritative interface reference): https://docs.kernel.org/admin-guide/cgroup-v2.html
- Control Groups version 1: https://docs.kernel.org/admin-guide/cgroup-v1/index.html
- cgroup v1 memory controller: https://docs.kernel.org/admin-guide/cgroup-v1/memory.html
- PSI — Pressure Stall Information: https://docs.kernel.org/accounting/psi.html
- OOM killer / `oom_score_adj`: https://docs.kernel.org/filesystems/proc.html
- Kernel sysctl (`fs.*`, `kernel.pid_max`): https://docs.kernel.org/admin-guide/sysctl/fs.html · https://docs.kernel.org/admin-guide/sysctl/kernel.html

**Manual pages — resource limits**
- `setrlimit(2)` / `getrlimit(2)` / `prlimit(2)`: https://man7.org/linux/man-pages/man2/setrlimit.2.html
- `prlimit(1)`: https://man7.org/linux/man-pages/man1/prlimit.1.html
- `ulimit(1p)` (POSIX): https://man7.org/linux/man-pages/man1/ulimit.1p.html
- `limits.conf(5)`: https://man7.org/linux/man-pages/man5/limits.conf.5.html
- `pam_limits(8)`: https://man7.org/linux/man-pages/man8/pam_limits.8.html
- `pam.conf(5)` / PAM stack syntax: https://man7.org/linux/man-pages/man5/pam.conf.5.html
- `proc_pid_limits(5)`: https://man7.org/linux/man-pages/man5/proc_pid_limits.5.html

**Manual pages — cgroups**
- `cgroups(7)`: https://man7.org/linux/man-pages/man7/cgroups.7.html
- `cgroup_namespaces(7)`: https://man7.org/linux/man-pages/man7/cgroup_namespaces.7.html

**systemd**
- `systemd.resource-control(5)` — every directive in §5.2: https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html
- `systemd.exec(5)` — `Limit*=`, `OOMScoreAdjust=`, `CoredumpFilter=`: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- `systemd.slice(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.slice.html
- `systemd.scope(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.scope.html
- `systemd.unit(5)` — drop-in precedence: https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html
- `systemd-system.conf(5)` — `Default*` settings: https://www.freedesktop.org/software/systemd/man/latest/systemd-system.conf.html
- `systemd-run(1)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html
- `systemctl(1)` — `set-property`: https://www.freedesktop.org/software/systemd/man/latest/systemctl.html
- `systemd-cgls(1)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-cgls.html
- `systemd-cgtop(1)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-cgtop.html
- `systemd-oomd.service(8)` and `oomctl(1)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-oomd.service.html
- `oomd.conf(5)`: https://www.freedesktop.org/software/systemd/man/latest/oomd.conf.html
- `logind.conf(5)`: https://www.freedesktop.org/software/systemd/man/latest/logind.conf.html
- Control Group APIs and Delegation (design doc): https://systemd.io/CGROUP_DELEGATION/
- The New Control Group Interfaces (upstream migration guide): https://systemd.io/CONTROL_GROUP_INTERFACE/

**Distribution guidance**
- Red Hat Enterprise Linux 9 — Managing, monitoring and updating the kernel: control groups: https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_monitoring_and_updating_the_kernel/setting-limits-for-applications_managing-monitoring-and-updating-the-kernel
- SUSE Linux Enterprise Server — System Analysis and Tuning Guide, cgroups: https://documentation.suse.com/sles/15-SP6/html/SLES-all/cha-tuning-cgroups.html
- Debian Wiki — systemd resource control: https://wiki.debian.org/systemd