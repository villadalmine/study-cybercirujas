# 103.5 — Create, monitor and kill processes

**Certification:** LPIC-1 (Exams 101-500 / 102-500, version 5.0)
**Topic weight:** 6.25
**Profile:** Principal Platform Architect / Senior SRE
**Prerequisites:** 103.1 (shell and command line), 103.2 (text filters), 103.4 (streams, pipes, redirects)
**Adjacent topic:** 103.6 (`nice`, `renice`, scheduling priorities) — deliberately out of scope here

---

## 1. Motivation: the architectural problem

Every incident postmortem you will ever write about a Linux platform reduces, eventually, to one of four process-level facts:

1. **A process that should have died did not.** A `SIGTERM` was delivered, the application never installed a handler, the orchestrator waited out its grace period, and `SIGKILL` truncated an in-flight write. The database is now missing the last 3 seconds of a WAL segment.
2. **A process that should have lived did not.** An SSH session dropped, the terminal was hung up, the kernel delivered `SIGHUP` to the foreground process group, and a 6-hour data migration died at hour 5. Nobody used `nohup`, `setsid`, `tmux`, or — the correct answer — a `systemd` unit.
3. **A process is alive but unaccounted for.** PID 1 in a container is a shell that never reaps children, so `ps` shows 40,000 zombies and the pod hits its `pids` cgroup limit. New threads fail with `EAGAIN` and the readiness probe flaps.
4. **A process is neither alive nor dead.** It sits in `D` state — uninterruptible sleep on a hung NFS mount or a stalled NVMe queue — and `kill -9` does nothing at all, because there is no user-space code left to interrupt.

The unifying insight is this: **on Linux, "kill" is a misnomer.** `kill(2)` does not terminate anything. It delivers a signal — an asynchronous notification — and the *receiving process* decides what happens next, unless the signal is one of the two the kernel refuses to let it intercept (`SIGKILL`, `SIGSTOP`). Process lifecycle management is therefore a **contract** between three parties:

```
  supervisor  ──signal──▶  process  ──exit status──▶  supervisor
  (systemd,        │           │                          │
   kubelet,        │           └── handler? default?      │
   shell)          │               ignored? blocked?      │
                   └───────── grace period timer ─────────┘
                                     │
                              expiry ▼
                              SIGKILL (non-negotiable)
```

An SRE who understands only "`kill -9` makes it stop" will build systems that lose data under normal operation. This topic is where that habit gets corrected.

### The production stakes, concretely

| Failure | Root cause at the process layer | Blast radius |
|---|---|---|
| Truncated writes during rolling deploy | App ignores `SIGTERM`; k8s escalates to `SIGKILL` after 30 s | Data corruption, silent |
| 502s for 30 s during every deploy | App exits on `SIGTERM` *before* the endpoint is removed from the Service | User-visible errors, every release |
| Container fills PID table | Shell as PID 1 does not `wait()` on children → zombies | Pod becomes unschedulable; node PID exhaustion |
| Migration dies at 05:00 | Job ran in a login shell; terminal hangup delivered `SIGHUP` | Hours of re-work, missed maintenance window |
| Node "hangs" but CPU is idle | Tasks stuck in `D` state on dead storage; load average = 300 | Whole node undebuggable via normal tooling |
| `kill -9` on a stuck NFS client does nothing | `D` state is not interruptible; signal is queued, never delivered | Requires storage-layer or reboot remediation |

---

## 2. Process mechanics: what the kernel actually maintains

### 2.1 Creation — `fork()` / `execve()` / `wait()`

Linux has no "create a new program" primitive. It has:

- **`fork(2)`** (in practice `clone(2)`) — duplicate the calling process. Copy-on-write address space, duplicated file descriptor table, same credentials. Returns `0` in the child, the child's PID in the parent.
- **`execve(2)`** — replace the current process image with a new program. **The PID does not change.** Open FDs survive unless marked `FD_CLOEXEC`. Signal *handlers* are reset to default; signal *dispositions* set to `SIG_IGN` are preserved (this is exactly how `nohup` works).
- **`_exit(2)`** — terminate, leaving an exit status in the kernel's task structure.
- **`wait(2)` / `waitpid(2)`** — the parent collects that status. Until it does, the child is a **zombie** (`Z`): no memory, no code, just a PID and 8 bits of exit status held for the parent.

```
  parent                     child
    │
    ├── fork() ──────────────▶ (copy of parent)
    │                            │
    │                            ├── execve("/usr/bin/foo")
    │                            │       (same PID, new image)
    │                            │
    │                            └── _exit(0)  ──▶ becomes Z (zombie)
    │                                                  │
    └── waitpid() ◀──── exit status ───────────────────┘
                        (zombie reaped, PID freed)
```

**Architectural consequence:** a zombie is not a leak of memory, it is a leak of *PID namespace slots*. `/proc/sys/kernel/pid_max` (default 4194304 on modern kernels, 32768 historically) and the cgroup `pids.max` are both finite. A process that forks and never waits will exhaust them.

**Orphan handling:** if a parent exits before its children, the children are re-parented — historically to PID 1, since Linux 3.4 to the nearest ancestor marked as a **child subreaper** (`prctl(PR_SET_CHILD_SUBREAPER)`), which `systemd --user` and container runtimes use. The reaper must call `wait()`. This is the single reason `tini` and `dumb-init` exist.

### 2.2 Process states as reported by `ps` / `top`

| Code | Kernel state | Killable? | Typical cause |
|---|---|---|---|
| `R` | Running or runnable (on a run queue) | Yes | Actively consuming CPU or waiting for a slot |
| `S` | Interruptible sleep | Yes | Waiting on a socket, timer, or `poll()`; the normal idle state |
| `D` | **Uninterruptible** sleep | **No** | Blocking I/O: dead NFS, stalled block device, some `ioctl`s |
| `Z` | Zombie / defunct | **No — already dead** | Parent has not `wait()`ed |
| `T` | Stopped by job-control signal | Yes (after `SIGCONT`) | `SIGSTOP`, `SIGTSTP`, `SIGTTIN`, `SIGTTOU` |
| `t` | Stopped by debugger during trace | Yes | `ptrace` attach (`gdb`, `strace`) |
| `I` | Idle kernel thread (Linux ≥ 4.14) | N/A | Kernel worker with nothing to do |
| `X` | Dead | N/A | Transient; should never be observed |

Modifier flags appended by `ps`:

| Flag | Meaning |
|---|---|
| `<` | High priority (negative nice) |
| `N` | Low priority (positive nice) |
| `L` | Has pages locked in memory (real-time / mlock) |
| `s` | **Session leader** |
| `l` | Multi-threaded (uses `clone`) |
| `+` | In the **foreground process group** of its controlling terminal |

The `+` flag is the one that matters for job control: exactly one process group per terminal may read from it, and that is the foreground group.

### 2.3 Sessions, process groups, and controlling terminals

This hierarchy is the substrate for everything in section 3.

```
  SESSION (SID = PID of session leader, e.g. the login shell)
   │  controlling terminal: /dev/pts/3
   │
   ├── PROCESS GROUP 4210 (foreground, has terminal read access)  ← "+"
   │     ├── PID 4210  tar
   │     └── PID 4211  gzip           (a pipeline is ONE process group)
   │
   ├── PROCESS GROUP 4198 (background, running)
   │     └── PID 4198  rsync
   │
   └── PROCESS GROUP 4185 (background, stopped)
         └── PID 4185  vim
```

Inspect it directly:

```
$ ps -eo pid,ppid,pgid,sid,tty,stat,comm --sort=sid | grep -E 'pts/3|PID'
    PID    PPID    PGID     SID TT       STAT COMMAND
   4102    4099    4102    4102 pts/3    Ss   bash
   4185    4102    4185    4102 pts/3    T    vim
   4198    4102    4198    4102 pts/3    S    rsync
   4210    4102    4210    4102 pts/3    S+   tar
   4211    4102    4210    4102 pts/3    S+   gzip
```

Read that carefully: `tar` and `gzip` share `PGID 4210` because they are one pipeline; `bash` has `SID == PID == PGID` and the `s` flag because it is the session leader; only PGID 4210 carries `+`.

**Why this matters:** `kill -TERM -4210` (note the minus) signals *the whole process group*. Terminal-generated signals — `Ctrl-C`, `Ctrl-Z`, `Ctrl-\` — are delivered by the terminal driver to the entire foreground process group, which is why `Ctrl-C` on a pipeline kills every stage.

---

## 3. Job control: `&`, `jobs`, `fg`, `bg`

Job control is a **shell feature**, not a kernel feature. The kernel provides process groups and `tcsetpgrp(3)`; `bash` builds the user-facing abstraction on top.

### 3.1 The primitives

```
$ sleep 300 &
[1] 5821

$ tar -czf /backup/srv.tar.gz /srv &
[2] 5834

$ jobs
[1]-  Running                 sleep 300 &
[2]+  Running                 tar -czf /backup/srv.tar.gz /srv &

$ jobs -l
[1]- 5821 Running                 sleep 300 &
[2]+ 5834 Running                 tar -czf /backup/srv.tar.gz /srv &

$ jobs -p
5821
5834
```

`+` marks the **current job** (what bare `fg` / `bg` act on, also `%%` or `%+`); `-` marks the **previous job** (`%-`).

Suspend a foreground job and resume it in the background:

```
$ ping -i 5 10.0.0.1
PING 10.0.0.1 (10.0.0.1) 56(84) bytes of data.
64 bytes from 10.0.0.1: icmp_seq=1 ttl=64 time=0.412 ms
64 bytes from 10.0.0.1: icmp_seq=2 ttl=64 time=0.398 ms
^Z
[3]+  Stopped                 ping -i 5 10.0.0.1

$ bg %3
[3]+ ping -i 5 10.0.0.1 &

$ jobs
[1]   Running                 sleep 300 &
[2]-  Running                 tar -czf /backup/srv.tar.gz /srv &
[3]+  Running                 ping -i 5 10.0.0.1 &

$ fg %2
tar -czf /backup/srv.tar.gz /srv
```

What `Ctrl-Z` actually did: the terminal driver sent `SIGTSTP` (20) to the foreground process group. What `bg` did: sent `SIGCONT` (18) to that group *without* calling `tcsetpgrp()`, so the group runs but is no longer the foreground group. What `fg` did: called `tcsetpgrp()` to hand the terminal back, then sent `SIGCONT`.

### 3.2 Job specifications

| Spec | Selects |
|---|---|
| `%1` | Job number 1 |
| `%%` or `%+` | Current job |
| `%-` | Previous job |
| `%tar` | Job whose command **begins with** `tar` |
| `%?backup` | Job whose command **contains** `backup` |

These work with the shell builtins `fg`, `bg`, `wait`, `disown`, and — importantly — the shell builtin `kill`:

```
$ kill -TERM %2
$ jobs
[2]+  Terminated              tar -czf /backup/srv.tar.gz /srv
```

`/bin/kill` does **not** understand `%2`; only the builtin does.

### 3.3 The background-write trap

A background job may write to the terminal freely, but if it *reads* from the terminal it receives `SIGTTIN` and stops. If `stty tostop` is set, writing also stops it with `SIGTTOU`.

```
$ cat > /tmp/notes.txt &
[1] 6102

$ jobs
[1]+  Stopped (tty input)     cat > /tmp/notes.txt

$ ps -o pid,stat,comm -p 6102
    PID STAT COMMAND
   6102 T    cat
```

**SRE reading:** any background job that mysteriously enters `T` and never progresses is almost always blocked on `SIGTTIN` — it wants stdin. In automation, always redirect: `cmd < /dev/null &`.

### 3.4 `wait` — the missing piece in shell orchestration

```bash
#!/usr/bin/env bash
set -euo pipefail

# Fan out three independent backups, then reconcile.
pids=()

for host in db-01 db-02 db-03; do
    pg_dumpall -h "$host" -f "/backup/${host}.sql" < /dev/null &
    pids+=("$!")          # $! = PID of the most recent background job
done

failed=0
for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
        printf 'backup pid %s failed with status %d\n' "$pid" "$?" >&2
        failed=1
    fi
done

exit "$failed"
```

`$!` and `wait` are how a shell script becomes a supervisor. Without `wait`, the script exits, the children are orphaned and re-parented, and your exit status is a lie.

---

## 4. Signals: the complete reference

### 4.1 The standard signal table (Linux, x86-64 / ARM / most architectures)

| # | Name | Default action | Catchable | Typical meaning |
|---|---|---|---|---|
| 1 | `SIGHUP` | Terminate | Yes | Terminal hangup; **by convention: reload configuration** |
| 2 | `SIGINT` | Terminate | Yes | `Ctrl-C` — interactive interrupt |
| 3 | `SIGQUIT` | Terminate + **core dump** | Yes | `Ctrl-\` — also dumps Java/Go stacks |
| 4 | `SIGILL` | Terminate + core | Yes | Illegal instruction |
| 5 | `SIGTRAP` | Terminate + core | Yes | Breakpoint (debuggers) |
| 6 | `SIGABRT` | Terminate + core | Yes | `abort(3)`, failed assertion |
| 7 | `SIGBUS` | Terminate + core | Yes | Bad memory access alignment / truncated `mmap` |
| 8 | `SIGFPE` | Terminate + core | Yes | Arithmetic error (integer div by zero) |
| **9** | **`SIGKILL`** | **Terminate** | **NO** | Unconditional kill by the kernel |
| 10 | `SIGUSR1` | Terminate | Yes | Application-defined (nginx: reopen logs) |
| 11 | `SIGSEGV` | Terminate + core | Yes | Invalid memory reference |
| 12 | `SIGUSR2` | Terminate | Yes | Application-defined (nginx: upgrade binary) |
| 13 | `SIGPIPE` | Terminate | Yes | Write to a pipe with no reader |
| 14 | `SIGALRM` | Terminate | Yes | `alarm(2)` timer expired |
| **15** | **`SIGTERM`** | **Terminate** | **Yes** | **Polite shutdown — the default of `kill`** |
| 16 | `SIGSTKFLT` | Terminate | Yes | Coprocessor stack fault (unused) |
| 17 | `SIGCHLD` | **Ignore** | Yes | A child stopped or terminated |
| 18 | `SIGCONT` | Continue | Yes | Resume a stopped process |
| **19** | **`SIGSTOP`** | **Stop** | **NO** | Unconditional suspend |
| 20 | `SIGTSTP` | Stop | Yes | `Ctrl-Z` — terminal stop |
| 21 | `SIGTTIN` | Stop | Yes | Background process read from terminal |
| 22 | `SIGTTOU` | Stop | Yes | Background process wrote to terminal (`stty tostop`) |
| 23 | `SIGURG` | Ignore | Yes | Out-of-band socket data |
| 24 | `SIGXCPU` | Terminate + core | Yes | CPU time limit exceeded (`RLIMIT_CPU`) |
| 25 | `SIGXFSZ` | Terminate + core | Yes | File size limit exceeded (`RLIMIT_FSIZE`) |
| 26 | `SIGVTALRM` | Terminate | Yes | Virtual timer expired |
| 27 | `SIGPROF` | Terminate | Yes | Profiling timer expired |
| 28 | `SIGWINCH` | Ignore | Yes | Terminal window resized |
| 29 | `SIGIO`/`SIGPOLL` | Terminate | Yes | Async I/O ready |
| 30 | `SIGPWR` | Terminate | Yes | Power failure (UPS daemons) |
| 31 | `SIGSYS` | Terminate + core | Yes | Bad system call (**seccomp violations**) |
| 34–64 | `SIGRTMIN`..`SIGRTMAX` | Terminate | Yes | Real-time signals; queued, not coalesced |

```
$ kill -l
 1) SIGHUP       2) SIGINT       3) SIGQUIT      4) SIGILL       5) SIGTRAP
 6) SIGABRT      7) SIGBUS       8) SIGFPE       9) SIGKILL     10) SIGUSR1
11) SIGSEGV     12) SIGUSR2     13) SIGPIPE     14) SIGALRM     15) SIGTERM
16) SIGSTKFLT   17) SIGCHLD     18) SIGCONT     19) SIGSTOP     20) SIGTSTP
21) SIGTTIN     22) SIGTTOU     23) SIGURG      24) SIGXCPU     25) SIGXFSZ
26) SIGVTALRM   27) SIGPROF     28) SIGWINCH    29) SIGIO       30) SIGPWR
31) SIGSYS      34) SIGRTMIN    35) SIGRTMIN+1  36) SIGRTMIN+2  37) SIGRTMIN+3
...
63) SIGRTMAX-1  64) SIGRTMAX

$ kill -l 15
TERM

$ kill -l TERM
15
```

> **Portability caveat that appears on exams and in real cross-platform tooling:** signal *numbers* 1–15 excluding the architecture-specific ones are stable, but `SIGUSR1`/`SIGUSR2` are **10/12 on x86-64, ARM, and most Linux ports, 16/17 on MIPS, and 30/31 on Alpha/SPARC**. Never hardcode numbers in portable scripts — use names. `kill -HUP`, `kill -s HUP`, and `kill -1` are equivalent on x86-64 only.

### 4.2 Blocked, ignored, pending — reading the masks

```
$ grep -E '^Sig|^Name|^State' /proc/1/status
Name:   systemd
State:  S (sleeping)
SigQ:   0/62481
SigPnd: 0000000000000000
SigBlk: 7be3c0fe28014a03
SigIgn: 0000000000001000
SigCgt: 00000001800004ec
```

Decode with `bc` or, more practically:

```
$ awk '/^SigCgt/ {print $2}' /proc/1/status | \
    xargs -I{} python3 -c "
import sys
m=int('{}',16)
names={1:'HUP',2:'INT',3:'QUIT',6:'ABRT',10:'USR1',12:'USR2',13:'PIPE',15:'TERM',17:'CHLD',
       18:'CONT',28:'WINCH',29:'IO',30:'PWR',31:'SYS'}
print('caught:', [names.get(i,i) for i in range(1,65) if m>>(i-1)&1])"
caught: ['HUP', 'INT', 'ABRT', 'USR1', 'USR2', 'CHLD', 'PWR', 'SYS']
```

| Field | Meaning | Diagnostic use |
|---|---|---|
| `SigPnd` | Pending for **this thread** | Non-zero + `D` state ⇒ signal queued but undeliverable |
| `ShdPnd` | Pending for the whole **thread group** | Same, process-wide |
| `SigBlk` | Currently **blocked** (`sigprocmask`) | Explains "I sent TERM and nothing happened" |
| `SigIgn` | Set to `SIG_IGN` | `0x…1000` = bit 13 = `SIGPIPE` ignored (very common) |
| `SigCgt` | Has a **handler** installed | **If `SIGTERM` (bit 15) is 0, the app has no graceful shutdown** |

This single check — "does bit 15 appear in `SigCgt`?" — is the fastest way to prove an application will lose data on rolling restart, *before* the incident.

### 4.3 `kill` — the three forms

```
$ kill 5821                     # implicit SIGTERM
$ kill -9 5821                  # by number  (SIGKILL)
$ kill -KILL 5821               # by short name
$ kill -s SIGKILL 5821          # POSIX form, portable
$ kill -TERM -4210              # NEGATIVE pid = entire process GROUP 4210
$ kill -TERM -1                 # every process the caller may signal (DANGEROUS)
$ kill -0 5821 && echo alive    # send NOTHING: pure existence/permission probe
```

`kill -0` is the idiomatic liveness probe in shell supervisors — it performs the permission check and existence check but delivers no signal:

```
$ kill -0 1 && echo "PID 1 exists and I may signal it"
-bash: kill: (1) - Operation not permitted
$ echo $?
1
```

`EPERM` (permission denied) means the process **exists**; `ESRCH` (no such process) means it does not. Robust scripts distinguish the two:

```bash
is_running() {
    kill -0 "$1" 2>/dev/null && return 0
    [[ -d /proc/$1 ]] && return 0      # exists but we lack permission
    return 1
}
```

### 4.4 The escalation ladder — the only correct kill sequence

```bash
#!/usr/bin/env bash
# terminate <pid> [grace_seconds]
# Escalates TERM -> (grace) -> KILL, reporting which rung was needed.
set -euo pipefail

terminate() {
    local pid=$1 grace=${2:-30} waited=0

    kill -0 "$pid" 2>/dev/null || { echo "pid $pid: not running"; return 0; }

    echo "pid $pid: sending SIGTERM"
    kill -TERM "$pid"

    while kill -0 "$pid" 2>/dev/null; do
        if (( waited >= grace )); then
            echo "pid $pid: grace period of ${grace}s expired, sending SIGKILL" >&2
            kill -KILL "$pid"
            sleep 1
            kill -0 "$pid" 2>/dev/null && {
                echo "pid $pid: SURVIVED SIGKILL - process is in D state" >&2
                cat "/proc/$pid/stack" 2>/dev/null || true
                return 1
            }
            return 2      # non-zero: the app has a shutdown bug worth a ticket
        fi
        sleep 1
        (( waited++ ))
    done

    echo "pid $pid: exited cleanly after ${waited}s"
    return 0
}

terminate "$@"
```

```
$ ./terminate 7431 10
pid 7431: sending SIGTERM
pid 7431: exited cleanly after 3s

$ ./terminate 7502 5
pid 7502: sending SIGTERM
pid 7502: grace period of 5s expired, sending SIGKILL
$ echo $?
2
```

**Exit code 2 is a signal to the platform team, not to the operator.** Track it. Every application that needs `SIGKILL` is a future data-loss incident.

### 4.5 Signal semantics by convention (memorise these)

| Signal | Daemon convention | Example |
|---|---|---|
| `SIGHUP` | **Reload config without restart** | `kill -HUP $(cat /run/nginx.pid)`, `sshd`, `rsyslogd` |
| `SIGUSR1` | Reopen log files (log rotation) | nginx, HAProxy |
| `SIGUSR2` | Binary upgrade / spawn new master | nginx zero-downtime upgrade |
| `SIGQUIT` | **Graceful** shutdown, drain connections | nginx (inverted vs. `SIGTERM` = fast shutdown!) |
| `SIGTERM` | Graceful shutdown | Almost everything else |
| `SIGWINCH` | Graceful worker shutdown | nginx |

> **The nginx inversion is a classic production trap.** For nginx, `SIGTERM`/`SIGINT` mean *fast shutdown* (drop in-flight requests) and `SIGQUIT` means *graceful shutdown*. Since Kubernetes and systemd send `SIGTERM` by default, an unconfigured nginx pod drops connections on every deploy. The fix is `STOPSIGNAL SIGQUIT` in the Dockerfile or `KillSignal=SIGQUIT` in the unit — both shown in section 7.

---

## 5. Surviving logout: `nohup`, `setsid`, `disown`, `screen`, `tmux`

### 5.1 What actually kills your job at logout

Two independent mechanisms, frequently confused:

1. **The kernel.** When the controlling terminal is hung up (SSH connection drops, `pty` closes), the kernel sends `SIGHUP` to the **controlling process** (the session leader). It also sends `SIGHUP` + `SIGCONT` to any **orphaned process group** that contains stopped members.
2. **The shell.** On exit, `bash` sends `SIGHUP` to all its jobs *only if* the `huponexit` option is set — which is **off by default**.

```
$ shopt huponexit
huponexit       off
```

So a clean `exit` from an interactive bash usually does *not* kill background jobs; a *dropped* SSH session does, because the kernel gets involved.

### 5.2 The four mechanisms, compared

| Mechanism | What it changes | Survives hangup | Survives shell exit | Reattachable | Output capture |
|---|---|---|---|---|---|
| `cmd &` | Nothing — same session, background PG | ❌ | ⚠️ only if `huponexit` off | ❌ | Terminal (lost) |
| `disown -h %1` | Marks job: shell won't send `SIGHUP` | ⚠️ kernel may still HUP | ✅ | ❌ | Terminal (lost) |
| `nohup cmd &` | Sets `SIGHUP` disposition to `SIG_IGN`; redirects stdout to `nohup.out` | ✅ | ✅ | ❌ | `nohup.out` |
| `setsid cmd` | **New session, no controlling terminal** | ✅ (no tty to hang up) | ✅ | ❌ | Wherever redirected |
| `screen` / `tmux` | Runs inside a detached daemon with its own pty | ✅ | ✅ | ✅ | Scrollback buffer |
| **`systemd-run` / unit** | Process owned by PID 1, own cgroup, own logging | ✅ | ✅ | ✅ (`journalctl`) | **journald** |

### 5.3 `nohup` in practice

```
$ nohup ./import-catalog.sh &
[1] 8123
nohup: ignoring input and appending output to 'nohup.out'

$ cat /proc/8123/status | grep SigIgn
SigIgn: 0000000000000001
```

Bit 1 set = `SIGHUP` ignored. That is literally all `nohup` does, plus the redirection. Note that `nohup` **does not** detach from the session, so `ps` still shows the original SID.

Explicit redirection is better practice than letting it write `nohup.out` into `$PWD`:

```
$ nohup ./import-catalog.sh > /var/log/import.log 2>&1 < /dev/null &
[1] 8140

$ ps -o pid,ppid,pgid,sid,tty,stat,cmd -p 8140
    PID    PPID    PGID     SID TT       STAT CMD
   8140    4102    8140    4102 pts/3    S    /bin/bash ./import-catalog.sh
```

Still `pts/3`, still SID 4102 — attached, merely deaf to `SIGHUP`.

### 5.4 `setsid` — real detachment

```
$ setsid ./import-catalog.sh > /var/log/import.log 2>&1 < /dev/null

$ pgrep -af import-catalog
8199 /bin/bash ./import-catalog.sh

$ ps -o pid,ppid,pgid,sid,tty,stat,cmd -p 8199
    PID    PPID    PGID     SID TT       STAT CMD
   8199       1    8199    8199 ?        Ss   /bin/bash ./import-catalog.sh
```

`TT` is `?` (no controlling terminal), `PPID` is 1 (re-parented), `SID == PID` (new session leader), `STAT` shows `s`. **This is a genuine daemon.** There is no terminal to hang up, so `SIGHUP` never arrives.

### 5.5 `disown`

```
$ long-running-job &
[1] 8250

$ disown -h %1        # keep in job table, but do not send SIGHUP
$ jobs
[1]+  Running                 long-running-job &

$ disown %1           # remove from job table entirely
$ jobs
$ 
```

| Form | Effect |
|---|---|
| `disown %1` | Remove job 1 from the shell's job table |
| `disown -h %1` | Keep the job listed but mark it "do not `SIGHUP`" |
| `disown -a` | All jobs |
| `disown -r` | Running jobs only |

`disown` is a **retroactive** `nohup`: use it when you forgot. It cannot re-parent or create a new session, so a hard SSH drop can still take the job down if it is the controlling process.

### 5.6 `screen`

```
$ screen -S migration
# ... inside the screen session ...
$ ./migrate-schema.sh
# detach with Ctrl-a d
[detached from 9014.migration]

$ screen -ls
There is a screen on:
        9014.migration  (08/26/2026 09:14:22 AM)        (Detached)
1 Socket in /run/screen/S-sre.

$ screen -r migration
```

| Key / command | Action |
|---|---|
| `screen -S <name>` | Start a named session |
| `Ctrl-a d` | Detach |
| `screen -ls` | List sessions |
| `screen -r <name>` | Reattach |
| `screen -d -r <name>` | Detach elsewhere, then attach here (steal) |
| `screen -x <name>` | **Multi-attach** — two operators share one terminal |
| `Ctrl-a c` | New window |
| `Ctrl-a "` | Window list |
| `Ctrl-a A` | Rename window |
| `Ctrl-a [` | Copy/scrollback mode |

### 5.7 `tmux`

```
$ tmux new -s migration
# detach with Ctrl-b d
[detached (from session migration)]

$ tmux ls
migration: 1 windows (created Wed Aug 26 09:20:11 2026) [190x48]

$ tmux attach -t migration

$ tmux new-session -d -s batch 'pg_restore -d prod /backup/prod.dump'
$ tmux ls
batch: 1 windows (created Wed Aug 26 09:22:03 2026)
migration: 1 windows (created Wed Aug 26 09:20:11 2026)
```

| `screen` | `tmux` | Action |
|---|---|---|
| `Ctrl-a d` | `Ctrl-b d` | Detach |
| `screen -ls` | `tmux ls` | List sessions |
| `screen -r` | `tmux attach -t` | Reattach |
| `Ctrl-a c` | `Ctrl-b c` | New window |
| `Ctrl-a S` / `Ctrl-a |` | `Ctrl-b "` / `Ctrl-b %` | Split pane |
| `screen -x` | `tmux attach` (default shared) | Multi-attach |
| `screen -S x -X quit` | `tmux kill-session -t x` | Destroy |

**Architectural note:** `screen` and `tmux` are *operator* tools, not *production* tools. A `tmux` session is invisible to the service manager, produces no structured logs, has no restart policy, no resource limits, and dies with the node. Use them to babysit a one-off migration; never to run a service.

### 5.8 The production answer: `systemd-run`

```
$ systemd-run --unit=catalog-import \
    --description="One-shot catalog import" \
    --property=Type=oneshot \
    --property=TimeoutStopSec=300 \
    --collect \
    /usr/local/bin/import-catalog.sh
Running as unit: catalog-import.service

$ systemctl status catalog-import.service
● catalog-import.service - One-shot catalog import
     Loaded: loaded (/run/systemd/transient/catalog-import.service; transient)
  Transient: yes
     Active: active (running) since Wed 2026-08-26 09:31:04 UTC; 12s ago
   Main PID: 9302 (import-catalog.)
      Tasks: 3 (limit: 18942)
     Memory: 41.2M
        CPU: 8.114s
     CGroup: /system.slice/catalog-import.service
             ├─9302 /bin/bash /usr/local/bin/import-catalog.sh
             ├─9318 psql -h db-01 -f /srv/catalog/schema.sql
             └─9319 tee /var/log/catalog-import.log

$ journalctl -u catalog-import.service -f
```

This survives logout, survives reboot policy, has a cgroup, has structured logs, has a stop timeout, and can be killed as a unit with `systemctl kill`. Compare:

| Property | `nohup &` | `tmux` | `systemd-run` |
|---|---|---|---|
| Survives logout | ✅ | ✅ | ✅ |
| Survives node reboot (restart) | ❌ | ❌ | ✅ (with `Restart=`) |
| Structured, queryable logs | ❌ | ❌ | ✅ journald |
| Resource limits (cgroup) | ❌ | ❌ | ✅ |
| Kills entire process tree | ❌ | ⚠️ | ✅ `KillMode=control-group` |
| Exit status recorded | ❌ | ❌ | ✅ |
| Reattachable interactive TTY | ❌ | ✅ | ⚠️ (`--pty`) |

---

## 6. Monitoring: `ps`, `top`, `free`, `uptime`, `watch`, `pgrep`

### 6.1 `ps` — three incompatible syntaxes in one binary

`ps` on Linux (procps-ng) accepts **UNIX** options (`-e`), **BSD** options (`aux`, no dash), and **GNU long** options (`--sort`). Mixing them changes the meaning of letters.

| Invocation | Style | Meaning |
|---|---|---|
| `ps -e` | UNIX | All processes |
| `ps -ef` | UNIX | All processes, full format |
| `ps aux` | BSD | All processes with a tty + all users + processes without tty |
| `ps -aux` | **Ambiguous** | UNIX-style: processes of user `x`… procps warns and falls back |
| `ps axjf` | BSD | Job-control format, forest |
| `ps -eLf` | UNIX | All **threads** (`L`) |
| `ps -eo …` | UNIX | Custom output columns |

```
$ ps aux | head -6
USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root           1  0.0  0.1 168720 13104 ?        Ss   Aug20   0:31 /sbin/init
root           2  0.0  0.0      0     0 ?        S    Aug20   0:00 [kthreadd]
root          15  0.0  0.0      0     0 ?        I<   Aug20   0:00 [rcu_gp]
postgres    1842  1.2  8.4 2418516 686340 ?      Ss   Aug20  84:11 /usr/lib/postgresql/16/bin/postgres
www-data    2311  0.3  0.6 142208 52104 ?        S    Aug20  12:44 nginx: worker process
```

```
$ ps -ef | head -6
UID          PID    PPID  C STIME TTY          TIME CMD
root           1       0  0 Aug20 ?        00:00:31 /sbin/init
root           2       0  0 Aug20 ?        00:00:00 [kthreadd]
postgres    1842    1839  1 Aug20 ?        01:24:11 /usr/lib/postgresql/16/bin/postgres
www-data    2311    2309  0 Aug20 ?        00:12:44 nginx: worker process
```

| `ps aux` column | `ps -ef` column | Interpretation |
|---|---|---|
| `%CPU` | `C` | `aux` = lifetime average; `-ef` = scheduler's integer utilisation factor |
| `VSZ` | — | Virtual size (KiB) — includes unbacked mappings; **not** memory used |
| `RSS` | — | Resident set (KiB) — physical pages, **double-counts shared pages** |
| `STAT` | — | State + flags (section 2.2) |
| `START`/`STIME` | | Start time or date |
| `TIME` | `TIME` | Cumulative CPU time |

> **Neither `VSZ` nor `RSS` is "memory used."** `RSS` counts shared libraries once per process; summing `RSS` over a fleet of forked workers overcounts by gigabytes. Use `PSS` from `/proc/<pid>/smaps_rollup` (or `smem`) for a proportional figure. This misunderstanding drives most "why is my node OOMing when `ps` says 4 GB free" tickets.

**Custom output is where `ps` becomes an SRE tool:**

```
$ ps -eo pid,ppid,user,pcpu,pmem,rss,nlwp,stat,wchan:20,etimes,cmd --sort=-pcpu | head -8
    PID    PPID USER     %CPU %MEM   RSS NLWP STAT WCHAN                ETIMES CMD
   4471    1842 postgres 94.3  3.1 254112    1 R    -                     18422 postgres: prod app 10.0.2.14(51422) SELECT
   2311    2309 www-data 12.6  0.6  52104   17 S    ep_poll               518711 nginx: worker process
   9012       1 root      4.1  1.2  98440    9 S    futex_wait_queue_me     3204 /usr/bin/containerd
   1842    1839 postgres  1.2  8.4 686340    1 S    epoll_wait            518744 /usr/lib/postgresql/16/bin/postgres
```

| Column | Why an SRE asks for it |
|---|---|
| `nlwp` | Thread count — runaway thread creation shows here first |
| `wchan` | **Kernel function the task is sleeping in** — the single best `D`-state clue |
| `etimes` | Elapsed seconds (machine-sortable, unlike `etime`) |
| `pmem` / `rss` | Memory pressure attribution |
| `stat` | State + `+` foreground flag |
| `cgroup` | Which unit / container owns it |

Sorting and selection:

```
$ ps -eo pid,user,rss,cmd --sort=-rss | head -5          # top memory consumers
$ ps -eo pid,etimes,cmd --sort=-etimes | head -5         # oldest processes
$ ps -u postgres -o pid,stat,cmd                          # by user
$ ps -C nginx -o pid,ppid,stat,cmd                        # by command name
$ ps -p 1842 -o pid,cgroup --no-headers                   # which cgroup owns it
1842 0::/system.slice/postgresql@16-main.service
```

The process tree:

```
$ ps axjf | head -20
   PPID     PID    PGID     SID TTY       TPGID STAT   UID   TIME COMMAND
      0       1       1       1 ?            -1 Ss       0   0:31 /sbin/init
      1     892     892     892 ?            -1 Ss       0   0:04 /usr/sbin/sshd -D
    892    4098    4098    4098 ?            -1 Ss       0   0:00  \_ sshd: sre [priv]
   4098    4101    4098    4098 ?            -1 S     1000   0:00      \_ sshd: sre@pts/3
   4101    4102    4102    4102 pts/3      4210 Ss    1000   0:00          \_ -bash
   4102    4210    4210    4102 pts/3      4210 S+    1000   0:02              \_ tar -czf /backup/srv.tar.gz /srv
   4210    4211    4210    4102 pts/3      4210 S+    1000   0:11              \_ gzip
```

`TPGID` is the terminal's foreground process group — 4210 here, matching the `+` flag. Alternative: `pstree -p 4102`.

Threads:

```
$ ps -eLo pid,tid,nlwp,pcpu,stat,comm -p 2311
    PID     TID NLWP %CPU STAT COMMAND
   2311    2311   17  0.4 Sl   nginx
   2311    2315   17  0.1 Sl   nginx
   2311    2316   17  0.1 Sl   nginx
...
```

`PID == TID` for the thread group leader; the rest are LWPs sharing the address space.

### 6.2 `top` — the interactive baseline

```
$ top
top - 09:47:31 up 6 days,  2:14,  3 users,  load average: 4.82, 3.91, 2.44
Tasks: 428 total,   3 running, 424 sleeping,   0 stopped,   1 zombie
%Cpu(s): 38.4 us, 11.2 sy,  0.0 ni, 41.1 id,  8.9 wa,  0.0 hi,  0.4 si,  0.0 st
MiB Mem :   7960.4 total,    412.8 free,   5104.2 used,   2443.4 buff/cache
MiB Swap:   2048.0 total,   1621.3 free,    426.7 used.   2381.9 avail Mem

    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
   4471 postgres  20   0 2418516 254112  18104 R  94.3   3.1  18:22.14 postgres
   2311 www-data  20   0  142208  52104   9880 S  12.6   0.6  12:44.02 nginx
   9012 root      20   0 1874320  98440  42116 S   4.1   1.2   3:12.88 containerd
      1 root      20   0  168720  13104   8420 S   0.0   0.1   0:31.02 systemd
```

**The CPU line, field by field — this is where diagnosis begins:**

| Field | Name | Meaning | What high values indicate |
|---|---|---|---|
| `us` | user | User-space, normal priority | Application CPU work |
| `sy` | system | Kernel on behalf of processes | Syscall storm, context switching, lock contention |
| `ni` | nice | User-space, positive nice | Batch jobs (see 103.6) |
| `id` | idle | Idle | — |
| `wa` | **iowait** | Idle *while* I/O is outstanding | **Storage is the bottleneck** |
| `hi` | hardware IRQ | Hardware interrupt servicing | NIC/storage interrupt pressure |
| `si` | software IRQ | Softirq (network stack) | Packet-processing bottleneck |
| `st` | **steal** | vCPU wanted to run, hypervisor ran someone else | **Noisy neighbour / oversubscribed host** |

> `st` > 5% sustained on a cloud VM is an infrastructure problem, not an application problem. `wa` high with `id` low means the CPU is genuinely saturated *and* I/O-bound. `wa` high with `us`+`sy` near zero means storage alone.

**Interactive keys worth memorising:**

| Key | Effect |
|---|---|
| `h` / `?` | Help |
| `1` | Toggle per-CPU-core breakdown |
| `H` | Toggle **threads** view |
| `M` | Sort by memory (`%MEM`) |
| `P` | Sort by CPU (`%CPU`) — default |
| `T` | Sort by cumulative TIME |
| `N` | Sort by PID |
| `u` | Filter by user |
| `o` | Filter expression (e.g. `%CPU>10`) |
| `c` | Toggle full command line |
| `V` | Forest (tree) view |
| `k` | **Send a signal to a PID** (prompts for PID, then signal) |
| `r` | **renice** a PID |
| `e` / `E` | Cycle memory units (task / summary) |
| `d` or `s` | Change refresh delay |
| `W` | Write current config to `~/.config/procps/toprc` |
| `q` | Quit |

**Batch mode — how `top` enters automation:**

```
$ top -b -n 1 -o %CPU | head -12
$ top -b -n 3 -d 5 -p 4471 | grep -E '^ *4471'
   4471 postgres  20   0 2418516 254112  18104 R  94.3   3.1  18:22.14 postgres
   4471 postgres  20   0 2418516 256880  18104 R  97.1   3.1  18:27.02 postgres
   4471 postgres  20   0 2419540 258104  18104 R  91.8   3.2  18:31.61 postgres
```

| Flag | Meaning |
|---|---|
| `-b` | Batch mode — no curses, safe for pipes and cron |
| `-n <N>` | Exit after N iterations |
| `-d <sec>` | Delay between iterations |
| `-p <pid>` | Monitor specific PIDs (comma-separated, up to 20) |
| `-u <user>` | Filter by effective user |
| `-H` | Start in thread mode |
| `-o <field>` | Sort field |
| `-w 512` | Wide output (avoid truncated command lines) |

### 6.3 `ps` vs `top` vs the alternatives

| Tool | Model | Cost | Best for | Limitation |
|---|---|---|---|---|
| `ps` | **Snapshot** | Single `/proc` walk | Scripting, one-shot inventory, custom columns | No rates; `%CPU` is a lifetime average |
| `top` | **Sampled, repeating** | Curses redraw + `/proc` walk per interval | Interactive triage, "what is hot right now" | Heavyweight in tight loops; per-interval only |
| `htop` | Sampled, richer UI | Similar to `top` | Tree view, mouse, per-core bars, easy signal send | Not installed by default; not in LPIC-1 objectives |
| `pidstat` (sysstat) | **Interval deltas** | Low | Per-process CPU/IO/memory *rates* over time | Separate package |
| `pgrep`/`pidof` | Snapshot, PIDs only | Minimal | Scripting a lookup | No resource data |
| `/proc/<pid>/*` | Raw kernel state | Minimal | Anything the tools do not expose | Requires manual parsing |
| `watch` | Re-runs any command | Cost of that command | Turning a snapshot tool into a monitor | Naive re-execution; no history |

```
$ pidstat -p 4471 -u -r -d 2 3
Linux 6.8.0-45-generic (node-01)  08/26/2026  _x86_64_  (8 CPU)

09:52:10 AM   UID       PID    %usr %system  %guest   %wait    %CPU   CPU  Command
09:52:12 AM   114      4471   71.50   22.50    0.00    1.00   94.00     3  postgres
09:52:14 AM   114      4471   74.00   23.00    0.00    0.50   97.00     3  postgres
09:52:16 AM   114      4471   69.50   22.00    0.00    2.00   91.50     3  postgres
Average:      114      4471   71.67   22.50    0.00    1.17   94.17     -  postgres
```

`%wait` (run-queue latency) is data `top` does not give you.

### 6.4 `free` — and why "free memory" is the wrong metric

```
$ free -h
               total        used        free      shared  buff/cache   available
Mem:            7.8Gi       5.0Gi       402Mi       184Mi       2.4Gi       2.3Gi
Swap:           2.0Gi       416Mi       1.6Gi

$ free -m -w
               total        used        free      shared     buffers       cache   available
Mem:            7960        5104         402         184         212        2231        2381
Swap:           2048         416        1621
```

| Column | Definition | Operational meaning |
|---|---|---|
| `total` | `MemTotal` | Physical RAM visible to the kernel |
| `used` | `total - free - buffers - cache` | Genuinely allocated to processes |
| `free` | `MemFree` | **Unused RAM — a low value is normal and healthy** |
| `shared` | `Shmem` (tmpfs, shared memory) | `/dev/shm` and tmpfs usage counts here |
| `buffers` | Block-device metadata cache | Reclaimable |
| `cache` | Page cache + slab reclaimable | Reclaimable |
| `available` | **Kernel's estimate of allocatable memory without swapping** | **The number to alert on** |

> **`free` being near zero is the correct steady state.** Linux uses all spare RAM as page cache and reclaims it on demand. Alert on `available`, never on `free`. `available` is computed by the kernel (`MemAvailable` in `/proc/meminfo`, since Linux 3.14) and accounts for the fraction of cache that is *not* actually reclaimable.

Useful flags:

| Flag | Effect |
|---|---|
| `-h` | Human-readable, auto-scaled |
| `-b` / `-k` / `-m` / `-g` | Bytes / KiB / MiB / GiB |
| `-w` | Wide: split `buffers` and `cache` |
| `-t` | Add a total (RAM + swap) line |
| `-s <sec>` | Repeat every N seconds |
| `-c <count>` | With `-s`, stop after N iterations |
| `-l` | Show low/high memory statistics |

```
$ free -h -s 2 -c 3
               total        used        free      shared  buff/cache   available
Mem:            7.8Gi       5.0Gi       402Mi       184Mi       2.4Gi       2.3Gi
Swap:           2.0Gi       416Mi       1.6Gi

               total        used        free      shared  buff/cache   available
Mem:            7.8Gi       5.2Gi       288Mi       184Mi       2.3Gi       2.1Gi
Swap:           2.0Gi       418Mi       1.6Gi
...
```

The authoritative source, which `free` merely formats:

```
$ head -5 /proc/meminfo
MemTotal:        8151464 kB
MemFree:          412032 kB
MemAvailable:    2438848 kB
Buffers:          217088 kB
Cached:          2284544 kB
```

### 6.5 `uptime` and the load average — the most misread number in Linux

```
$ uptime
 09:47:31 up 6 days,  2:14,  3 users,  load average: 4.82, 3.91, 2.44

$ uptime -p
up 6 days, 2 hours, 14 minutes

$ uptime -s
2026-08-20 07:33:12

$ cat /proc/loadavg
4.82 3.91 2.44 3/428 9482
```

`/proc/loadavg` fields: 1-min, 5-min, 15-min averages; `running/total` tasks; last PID allocated.

**The critical distinction:** on most UNIXes load average counts *runnable* tasks. **On Linux it counts runnable (`R`) plus uninterruptible (`D`) tasks.** It is therefore a measure of *demand on the system*, not of CPU utilisation.

| Observation | Interpretation |
|---|---|
| Load 4.0 on 8 cores, `%Cpu id` = 50% | Healthy: half the CPU capacity in use |
| Load 40 on 8 cores, `%Cpu id` = 95%, `wa` = 0 | **Tasks stuck in `D` state.** Storage or NFS is hung, not CPU |
| Load 16 on 8 cores, `id` = 0%, `us` = 90% | Genuine CPU saturation; 2× oversubscribed |
| 1-min ≫ 15-min | Load is *rising* — incident in progress |
| 1-min ≪ 15-min | Load is *falling* — recovering |

Confirm which of the two by counting states directly:

```
$ ps -eo stat --no-headers | cut -c1 | sort | uniq -c | sort -rn
    398 S
     18 I
      6 R
      4 D
      1 Z
```

Four tasks in `D` with load 4.82 and idle CPUs is a storage incident, full stop.

> The modern successor is **Pressure Stall Information** (Linux ≥ 4.20), which separates the three resources instead of conflating them:
> ```
> $ cat /proc/pressure/io
> some avg10=41.22 avg60=38.90 avg300=22.14 total=884215309
> full avg10=29.10 avg60=27.44 avg300=15.02 total=612093118
> ```
> `some` = at least one task stalled; `full` = *all* tasks stalled. Not an LPIC-1 objective, but it is what you should actually be alerting on in production.

### 6.6 `watch` — turning any snapshot into a monitor

```
$ watch -n 2 'ps -eo pid,stat,pcpu,rss,comm --sort=-pcpu | head -10'
Every 2.0s: ps -eo pid,stat,pcpu,rss,comm --sort=-pcpu | head -10   node-01: Wed Aug 26 09:58:02 2026

    PID STAT %CPU   RSS COMMAND
   4471 R    94.3 254112 postgres
   2311 S    12.6  52104 nginx
   9012 S     4.1  98440 containerd
```

| Flag | Effect |
|---|---|
| `-n <sec>` | Interval (default 2.0; fractional allowed) |
| `-d` | **Highlight differences** between iterations |
| `-d=cumulative` | Highlight anything that has *ever* changed |
| `-t` | Suppress the header |
| `-g` | **Exit when output changes** — turns `watch` into a trigger |
| `-e` | Exit on non-zero command status |
| `-b` | Beep on non-zero status |
| `-c` | Interpret ANSI colour |
| `-x` | Pass the command to `exec` rather than `sh -c` |

Two high-value patterns:

```
# Watch a drain complete, highlighting changes
$ watch -d -n 1 'ss -tan state established "( sport = :443 )" | wc -l'

# Block until a condition flips, then continue the runbook
$ watch -g -n 5 'pgrep -c -f pg_basebackup' ; echo "basebackup finished"
```

**Quoting is the classic `watch` bug.** `watch ps aux | grep nginx` pipes `watch`'s output into `grep` — it does not watch the pipeline. Always quote: `watch 'ps aux | grep nginx'`.

### 6.7 `pgrep`, `pkill`, `killall`, `pidof`

```
$ pgrep nginx
2309
2311
2312

$ pgrep -a nginx                       # -a / --list-full: show full command line
2309 nginx: master process /usr/sbin/nginx -g daemon on; master_process on;
2311 nginx: worker process
2312 nginx: worker process

$ pgrep -u www-data -l
2311 nginx
2312 nginx

$ pgrep -f 'postgres: prod app'        # -f matches the FULL command line
4471

$ pgrep -x ssh                         # -x: exact match on the process NAME
$ pgrep -x sshd
892

$ pgrep -c nginx                       # count only
3

$ pgrep -P 2309                         # children of PID 2309
2311
2312

$ pgrep -n nginx                        # newest matching
2312
$ pgrep -o nginx                        # oldest matching
2309
```

| Option | `pgrep` / `pkill` meaning |
|---|---|
| `-f` | Match against the **full command line**, not just `comm` |
| `-x` | Require an **exact** match (no substring) |
| `-u <user>` | Effective UID |
| `-U <user>` | Real UID |
| `-P <ppid>` | Parent PID |
| `-g <pgid>` / `-s <sid>` | Process group / session |
| `-t <tty>` | Controlling terminal |
| `-n` / `-o` | Newest / oldest match only |
| `-a` | List full command line (`pgrep` only) |
| `-c` | Count matches (`pgrep` only) |
| `-l` | List name (`pgrep` only) |
| `--ns <pid>` | Match only processes in the **same namespaces** as `<pid>` |
| `-e` | Echo what was signalled (`pkill` only) |
| `-<SIG>` / `--signal <SIG>` | Signal to send (`pkill` only) |

```
$ pkill -HUP -x nginx
$ pkill -e -TERM -u deploy -f 'stale-worker'
stale-worker killed (pid 8811)
stale-worker killed (pid 8812)

$ pkill -9 -f 'java.*batch-import'
```

**`killall` (psmisc) — different matching rules:**

```
$ killall nginx                        # exact name match, ALL matching processes
$ killall -s HUP nginx
$ killall -v -TERM postgres
Killed postgres(1842) with signal 15

$ killall -r 'python3\.(9|10)'         # -r: regex on the name
$ killall -u deploy                     # all processes of a user
$ killall -o 2h stale-worker            # OLDER than 2 hours
$ killall -y 10m runaway                # YOUNGER than 10 minutes
$ killall -i firefox                    # interactive confirm
Kill firefox(3312) ? (y/N) 
$ killall -w nginx                      # WAIT until they actually die
```

### 6.8 `kill` vs `pkill` vs `killall` — choosing correctly

| Aspect | `kill` | `pkill` | `killall` |
|---|---|---|---|
| Package | shell builtin + coreutils/util-linux | procps-ng | psmisc |
| Selector | PID / PGID / job spec | Pattern (name or `-f` cmdline) | **Exact name** (or `-r` regex) |
| Default signal | `SIGTERM` | `SIGTERM` | `SIGTERM` |
| Substring matching | N/A | **Yes by default** (dangerous) | No (exact) |
| Full cmdline matching | N/A | `-f` | ❌ not supported |
| Job specs (`%1`) | ✅ (builtin only) | ❌ | ❌ |
| Process groups (`-PID`) | ✅ | via `-g` | ❌ |
| Namespace awareness | N/A | `--ns` | ❌ |
| Wait for exit | ❌ | ❌ | `-w` |
| Age filters | ❌ | ❌ | `-o` / `-y` |
| **Portability hazard** | — | — | **On Solaris, `killall` kills EVERY process** |

> **Two rules from production.**
> 1. `pkill` matches **substrings** by default. `pkill redis` will also match `redis-sentinel`, `redis-exporter`, and your `vim redis.conf`. **Always dry-run with `pgrep -a` first**, and prefer `-x` or a tightly anchored `-f` pattern.
> 2. `pkill -f` matches against the *full* command line — **including the `pkill` process's own arguments in some shells**, and including any `grep`/editor holding that string. Anchor the pattern: `pkill -f '^/usr/bin/java .*batch-import'`.

The safe idiom:

```
$ pgrep -a -f 'batch-import'            # 1. INSPECT
8811 /usr/bin/java -Xmx2g -jar /opt/app/batch-import.jar --shard=3
8812 /usr/bin/java -Xmx2g -jar /opt/app/batch-import.jar --shard=4

$ pgrep -c -f 'batch-import'            # 2. COUNT — does it match what you expect?
2

$ pkill -e -TERM -f 'batch-import'      # 3. ACT, with -e to log what was hit
java killed (pid 8811)
java killed (pid 8812)
```

---

## 7. Production infrastructure: complete manifests

### 7.1 systemd unit — correct lifecycle for a graceful service

`/etc/systemd/system/catalog-api.service`

```ini
[Unit]
Description=Catalog API (HTTP, graceful shutdown)
Documentation=https://internal.example.com/runbooks/catalog-api
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=notify
NotifyAccess=main
User=catalog
Group=catalog
WorkingDirectory=/opt/catalog-api
ExecStart=/opt/catalog-api/bin/catalog-api --config /etc/catalog-api/config.yaml

# --- Reload without restart: SIGHUP convention -------------------------------
ExecReload=/bin/kill -HUP $MAINPID

# --- Signal / kill policy ----------------------------------------------------
# KillSignal    : first signal sent on stop. SIGTERM is the default; nginx wants SIGQUIT.
# RestartKillSignal : signal used when stopping as part of a restart.
# KillMode      : control-group  -> signal EVERY process in the unit's cgroup (default, correct)
#                 mixed          -> KillSignal to main PID only, SIGKILL to the rest on timeout
#                 process        -> signal ONLY the main PID (leaks children)
#                 none           -> signal nothing (almost always a bug)
# SendSIGHUP    : additionally send SIGHUP after KillSignal (for tty-attached children)
# SendSIGKILL   : escalate to SIGKILL after TimeoutStopSec. Set to no ONLY if you accept hangs.
# TimeoutStopSec: grace period before SIGKILL. MUST exceed the app's worst-case drain time.
# FinalKillSignal: signal used for the final escalation (default SIGKILL).
KillSignal=SIGTERM
KillMode=control-group
SendSIGHUP=no
SendSIGKILL=yes
TimeoutStartSec=30s
TimeoutStopSec=90s
FinalKillSignal=SIGKILL

# --- Restart policy ----------------------------------------------------------
Restart=on-failure
RestartSec=5s
StartLimitIntervalSec=300
StartLimitBurst=5

# --- Resource containment (cgroup v2) ----------------------------------------
# TasksMax caps the pids controller: a fork bomb or a zombie leak is contained
# to this unit instead of exhausting the node's PID space.
TasksMax=512
MemoryMax=2G
MemoryHigh=1800M
CPUQuota=200%
LimitNOFILE=65536
LimitCORE=0
OOMPolicy=stop

# --- Hardening ---------------------------------------------------------------
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/catalog-api /var/log/catalog-api
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

# --- Logging -----------------------------------------------------------------
StandardOutput=journal
StandardError=journal
SyslogIdentifier=catalog-api

[Install]
WantedBy=multi-user.target
```

Operate it:

```
$ sudo systemctl daemon-reload
$ sudo systemctl enable --now catalog-api.service

$ systemctl show catalog-api -p KillMode -p KillSignal -p TimeoutStopUSec -p TasksMax
KillMode=control-group
KillSignal=15
TimeoutStopUSec=1min 30s
TasksMax=512

$ systemctl reload catalog-api          # ExecReload -> SIGHUP, no restart
$ systemctl kill --signal=SIGUSR1 catalog-api        # arbitrary signal to the cgroup
$ systemctl kill --kill-whom=main --signal=SIGQUIT catalog-api

$ systemd-cgls -u catalog-api.service
Unit catalog-api.service (/system.slice/catalog-api.service):
├─10241 /opt/catalog-api/bin/catalog-api --config /etc/catalog-api/config.yaml
├─10248 /opt/catalog-api/bin/catalog-worker --queue=default
└─10249 /opt/catalog-api/bin/catalog-worker --queue=priority

$ systemd-cgtop -1
Control Group                     Tasks   %CPU   Memory  Input/s Output/s
/                                   428   62.4     5.1G        -        -
/system.slice                       211   48.1     3.9G        -        -
/system.slice/postgresql@16-main…    38   31.2     1.8G     412K     8.1M
/system.slice/catalog-api.service     3    9.8   412.1M        -        -
```

**`KillMode` trade-offs — the field that causes the most orphaned-process incidents:**

| `KillMode` | Signals sent to | Orphans children? | Use when |
|---|---|---|---|
| `control-group` (default) | Every process in the cgroup | ❌ No | **Almost always correct** |
| `mixed` | `KillSignal` → main PID; `SIGKILL` → whole cgroup on timeout | ❌ No | Main process must coordinate its own children's shutdown |
| `process` | Main PID only | ✅ **Yes** | Main process provably reaps its own tree; rare |
| `none` | Nothing | ✅ Yes | Container shims managing their own lifecycle; dangerous |

### 7.2 Kubernetes: PID 1, graceful termination, and process debugging

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: catalog
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: catalog-api-config
  namespace: catalog
data:
  config.yaml: |
    server:
      listen: "0.0.0.0:8080"
      # Must be shorter than terminationGracePeriodSeconds minus the preStop sleep,
      # or SIGKILL will arrive mid-drain.
      shutdown_timeout: "25s"
    database:
      host: "postgresql.data.svc.cluster.local"
      port: 5432
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog-api
  namespace: catalog
  labels:
    app.kubernetes.io/name: catalog-api
    app.kubernetes.io/component: api
spec:
  replicas: 3
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: catalog-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: catalog-api
        app.kubernetes.io/component: api
    spec:
      # ---------------------------------------------------------------------
      # TERMINATION BUDGET (this is the whole point of the manifest)
      #
      #   t=0    kubelet removes the pod from Service endpoints (async!)
      #          AND runs the preStop hook
      #   t=0    preStop sleeps 10s  -> lets in-flight LB reprogramming settle,
      #                                 preventing the 502s of an eager exit
      #   t=10s  kubelet sends SIGTERM to PID 1 of each container
      #          app has shutdown_timeout=25s to drain
      #   t=45s  terminationGracePeriodSeconds expires -> SIGKILL
      #
      # Invariant: preStop_sleep + app_shutdown_timeout < terminationGracePeriodSeconds
      #            10 + 25 = 35 < 45   OK
      # ---------------------------------------------------------------------
      terminationGracePeriodSeconds: 45

      # Share the PID namespace between containers in the pod so that a debug
      # container can `ps`, `strace` and signal the application's processes.
      # NOTE: with shareProcessNamespace, the PAUSE container becomes PID 1 and
      # reaps zombies for the whole pod; the app is no longer PID 1.
      shareProcessNamespace: true

      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault

      containers:
        - name: catalog-api
          image: registry.example.com/catalog-api:1.14.2
          imagePullPolicy: IfNotPresent

          # The image's ENTRYPOINT is ["/sbin/tini","--","/opt/catalog-api/bin/catalog-api"].
          # tini as PID 1 does two things the application cannot:
          #   1. installs default handlers so SIGTERM is not silently discarded
          #      (PID 1 ignores signals that have no explicit handler);
          #   2. calls wait() on re-parented orphans, so zombies cannot accumulate.
          # The Kubernetes-native equivalent to a custom init is simply making sure
          # the app itself is PID 1 AND handles signals - tini is for when it is not.
          args:
            - "--config=/etc/catalog-api/config.yaml"

          ports:
            - name: http
              containerPort: 8080
              protocol: TCP

          lifecycle:
            preStop:
              exec:
                # Do NOT exit immediately on SIGTERM. Endpoint removal and
                # SIGTERM delivery are concurrent, not ordered.
                command: ["/bin/sh", "-c", "sleep 10"]

          startupProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 2
            failureThreshold: 30
          readinessProbe:
            httpGet: { path: /readyz, port: http }
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 2
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3

          resources:
            requests: { cpu: "250m", memory: "256Mi" }
            limits:   { cpu: "1",    memory: "512Mi" }

          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]

          volumeMounts:
            - name: config
              mountPath: /etc/catalog-api
              readOnly: true
            - name: tmp
              mountPath: /tmp

      volumes:
        - name: config
          configMap:
            name: catalog-api-config
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
---
# nginx inverts the signal convention: SIGTERM = fast (lossy) shutdown,
# SIGQUIT = graceful drain. Kubernetes always sends SIGTERM, so the image
# MUST declare STOPSIGNAL SIGQUIT for the container runtime to translate it.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: edge-proxy
  namespace: catalog
spec:
  replicas: 2
  selector:
    matchLabels: { app.kubernetes.io/name: edge-proxy }
  template:
    metadata:
      labels: { app.kubernetes.io/name: edge-proxy }
    spec:
      terminationGracePeriodSeconds: 60
      containers:
        - name: nginx
          # Dockerfile of this image ends with:  STOPSIGNAL SIGQUIT
          image: registry.example.com/edge-proxy:1.27.1
          ports:
            - { name: http, containerPort: 8080 }
          lifecycle:
            preStop:
              exec:
                command:
                  - /bin/sh
                  - -c
                  - "sleep 5 && /usr/sbin/nginx -s quit"
---
# Cap PIDs per namespace: a zombie leak or fork bomb in one workload must not
# exhaust the node's PID table for every other pod scheduled there.
apiVersion: v1
kind: ResourceQuota
metadata:
  name: catalog-pids
  namespace: catalog
spec:
  hard:
    pods: "40"
    count/deployments.apps: "10"
---
# PodDisruptionBudget: guarantees the graceful-termination path is never
# short-circuited by draining every replica at once.
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: catalog-api
  namespace: catalog
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: catalog-api
```

Corresponding kubelet configuration (per-node PID containment):

```yaml
# /var/lib/kubelet/config.yaml  (excerpt)
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
# Hard cap on PIDs any single pod may create. Without this, one runaway
# container can exhaust /proc/sys/kernel/pid_max for the entire node.
podPidsLimit: 4096
evictionHard:
  memory.available: "200Mi"
  pid.available: "10%"
evictionSoft:
  pid.available: "15%"
evictionSoftGracePeriod:
  pid.available: "1m"
systemReserved:
  cpu: "500m"
  memory: "1Gi"
  pid: "1000"
```

Observing the lifecycle in a live cluster:

```
$ kubectl -n catalog get pods -o wide
NAME                           READY   STATUS    RESTARTS   AGE   IP           NODE
catalog-api-7d4c9b8f6-2xk4m    1/1     Running   0          14m   10.244.2.7   node-02
catalog-api-7d4c9b8f6-9pnrt    1/1     Running   0          14m   10.244.1.9   node-01
catalog-api-7d4c9b8f6-lkq8c    1/1     Running   0          14m   10.244.3.4   node-03

$ kubectl -n catalog exec catalog-api-7d4c9b8f6-2xk4m -- ps -eo pid,ppid,stat,comm
    PID   PPID STAT COMMAND
      1      0 Ss   pause
      7      0 Ss   tini
     14      7 Sl   catalog-api

$ kubectl -n catalog exec catalog-api-7d4c9b8f6-2xk4m -- \
    grep -E 'SigCgt|SigIgn' /proc/14/status
SigIgn: 0000000000001000
SigCgt: 0000000180004a03

# Bit 15 (SIGTERM) is set in SigCgt -> the app WILL drain gracefully.

$ kubectl -n catalog delete pod catalog-api-7d4c9b8f6-2xk4m
pod "catalog-api-7d4c9b8f6-2xk4m" deleted

$ kubectl -n catalog get events --field-selector involvedObject.name=catalog-api-7d4c9b8f6-2xk4m
LAST SEEN   TYPE     REASON      OBJECT                              MESSAGE
0s          Normal   Killing     pod/catalog-api-7d4c9b8f6-2xk4m     Stopping container catalog-api
```

Ephemeral debug container — the modern replacement for `kubectl exec` into a distroless image:

```
$ kubectl -n catalog debug -it catalog-api-7d4c9b8f6-9pnrt \
    --image=registry.example.com/netshoot:0.13 \
    --target=catalog-api \
    --profile=general \
    -- bash
Defaulting debug container name to debugger-4qz7x.

root@catalog-api-7d4c9b8f6-9pnrt:/# ps -eo pid,ppid,stat,wchan:20,comm
    PID   PPID STAT WCHAN                COMMAND
      1      0 Ss   ep_poll              pause
      7      0 Ss   do_wait              tini
     14      7 Sl   futex_wait_queue_me  catalog-api
     29      0 Ss   do_wait              bash

root@catalog-api-7d4c9b8f6-9pnrt:/# kill -QUIT 14      # dump Go/Java stacks
root@catalog-api-7d4c9b8f6-9pnrt:/# cat /proc/14/status | grep -E 'Threads|SigBlk'
Threads:        24
SigBlk: 0000000000000000
```

### 7.3 A signal-handling reference implementation

The application side of the contract, in Python — this is what "handles `SIGTERM`" means concretely:

```python
#!/usr/bin/env python3
"""Reference graceful-shutdown skeleton.

Demonstrates the three obligations of a well-behaved production process:
  1. install handlers for SIGTERM and SIGINT and drain instead of exiting;
  2. reload configuration on SIGHUP without dropping connections;
  3. reap children so no zombie can accumulate.
"""
import os
import signal
import sys
import threading
import time

_shutdown = threading.Event()
_reload = threading.Event()


def _on_terminate(signum: int, _frame) -> None:
    """SIGTERM/SIGINT: start draining. Never call sys.exit() from a handler."""
    print(f"received {signal.Signals(signum).name}: draining", flush=True)
    _shutdown.set()


def _on_reload(_signum: int, _frame) -> None:
    """SIGHUP: reload config in the main loop, not in the handler."""
    _reload.set()


def _reap_children(_signum: int, _frame) -> None:
    """SIGCHLD: reap every exited child. WNOHANG loops because signals coalesce."""
    while True:
        try:
            pid, status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if pid == 0:
            return
        print(f"reaped child {pid} status={status}", flush=True)


def main() -> int:
    signal.signal(signal.SIGTERM, _on_terminate)
    signal.signal(signal.SIGINT, _on_terminate)
    signal.signal(signal.SIGHUP, _on_reload)
    signal.signal(signal.SIGCHLD, _reap_children)
    # Ignoring SIGPIPE turns broken-pipe writes into EPIPE errors we can handle,
    # instead of silent process death.
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)

    print(f"started pid={os.getpid()} ppid={os.getppid()}", flush=True)

    while not _shutdown.is_set():
        if _reload.is_set():
            _reload.clear()
            print("configuration reloaded", flush=True)
        time.sleep(0.5)

    # Drain phase: bounded, and shorter than the supervisor's grace period.
    deadline = time.monotonic() + 25.0
    while time.monotonic() < deadline:
        print("draining in-flight work...", flush=True)
        time.sleep(1.0)
        break  # replace with a real in-flight counter

    print("shutdown complete", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

```
$ ./gracefuld.py &
[1] 11402
started pid=11402 ppid=4102

$ kill -HUP 11402
configuration reloaded

$ grep SigCgt /proc/11402/status
SigCgt: 0000000000014203

$ kill -TERM 11402
received SIGTERM: draining
draining in-flight work...
shutdown complete
[1]+  Done                    ./gracefuld.py
```

### 7.4 Ansible: fleet-wide process verification

`playbooks/verify-process-hygiene.yml`

```yaml
---
- name: Verify process hygiene across the fleet
  hosts: linux_fleet
  gather_facts: true
  become: true
  vars:
    zombie_threshold: 20
    load_per_core_threshold: 2.0
    critical_units:
      - catalog-api.service
      - postgresql@16-main.service
      - nginx.service

  tasks:
    - name: Count zombie processes
      ansible.builtin.shell:
        cmd: "ps -eo stat --no-headers | grep -c '^Z' || true"
      changed_when: false
      register: zombie_count

    - name: Count uninterruptible (D state) processes
      ansible.builtin.shell:
        cmd: "ps -eo stat --no-headers | grep -c '^D' || true"
      changed_when: false
      register: dstate_count

    - name: Read the load average
      ansible.builtin.slurp:
        src: /proc/loadavg
      register: loadavg_raw

    - name: Compute load per core
      ansible.builtin.set_fact:
        load_1m: "{{ (loadavg_raw.content | b64decode).split()[0] | float }}"
        load_per_core: >-
          {{ ((loadavg_raw.content | b64decode).split()[0] | float)
             / (ansible_processor_vcpus | int) }}

    - name: Fail when zombies exceed the threshold
      ansible.builtin.assert:
        that:
          - (zombie_count.stdout | int) < zombie_threshold
        fail_msg: >-
          {{ inventory_hostname }} has {{ zombie_count.stdout }} zombies
          (threshold {{ zombie_threshold }}). A parent process is not calling wait().
        success_msg: "zombies: {{ zombie_count.stdout }} - OK"

    - name: Warn when tasks are stuck in uninterruptible sleep
      ansible.builtin.debug:
        msg: >-
          WARNING {{ inventory_hostname }}: {{ dstate_count.stdout }} tasks in D state,
          load {{ load_1m }} over {{ ansible_processor_vcpus }} vCPU.
          Load is inflated by blocked I/O, not CPU demand. Investigate storage.
      when: (dstate_count.stdout | int) > 0

    - name: Assert every critical unit is active
      ansible.builtin.systemd_service:
        name: "{{ item }}"
        state: started
        enabled: true
      loop: "{{ critical_units }}"
      register: unit_state

    - name: Verify each critical unit escalates to SIGKILL and caps its task count
      ansible.builtin.shell:
        cmd: "systemctl show {{ item }} -p SendSIGKILL -p TasksMax -p KillMode --value"
      changed_when: false
      register: kill_policy
      loop: "{{ critical_units }}"

    - name: Report kill policy
      ansible.builtin.debug:
        msg: "{{ item.item }} -> {{ item.stdout_lines | join(' / ') }}"
      loop: "{{ kill_policy.results }}"
      loop_control:
        label: "{{ item.item }}"

    - name: Reload (not restart) configuration on the API tier
      ansible.builtin.systemd_service:
        name: catalog-api.service
        state: reloaded
      when: "'api_tier' in group_names"
```

```
$ ansible-playbook -i inventory/prod playbooks/verify-process-hygiene.yml --limit node-01

PLAY [Verify process hygiene across the fleet] *********************************

TASK [Count zombie processes] **************************************************
ok: [node-01]

TASK [Fail when zombies exceed the threshold] **********************************
ok: [node-01] => {
    "changed": false,
    "msg": "zombies: 1 - OK"
}

TASK [Warn when tasks are stuck in uninterruptible sleep] **********************
ok: [node-01] => {
    "msg": "WARNING node-01: 4 tasks in D state, load 4.82 over 8 vCPU. Load is inflated by blocked I/O, not CPU demand. Investigate storage."
}

TASK [Report kill policy] ******************************************************
ok: [node-01] => (item=catalog-api.service) => {
    "msg": "catalog-api.service -> yes / 512 / control-group"
}

PLAY RECAP *********************************************************************
node-01   : ok=9  changed=1  unreachable=0  failed=0  skipped=0
```

---

## 8. Verification and failure diagnosis

### 8.1 Triage decision tree

```
Symptom: "the process will not die"
   │
   ├── ps -o stat= -p PID  →  Z   ──▶ It is ALREADY dead. Kill/signal the PARENT.
   │                                   ps -o ppid= -p PID ; kill -CHLD <ppid>
   │                                   If the parent will not reap, kill the parent;
   │                                   the zombie re-parents to init and is reaped.
   │
   ├── ps -o stat= -p PID  →  D   ──▶ Uninterruptible. SIGKILL CANNOT reach it.
   │                                   cat /proc/PID/wchan ; cat /proc/PID/stack
   │                                   Fix the I/O layer (NFS, iSCSI, dm device).
   │
   ├── ps -o stat= -p PID  →  T   ──▶ Stopped. kill -CONT PID first.
   │
   ├── grep SigBlk /proc/PID/status  → bit 15 set ──▶ SIGTERM is BLOCKED.
   │                                                   Use SIGKILL, then file a bug.
   │
   ├── grep SigCgt /proc/PID/status  → bit 15 CLEAR ──▶ No SIGTERM handler.
   │                                                     Default action is terminate;
   │                                                     if it survives, it is PID 1
   │                                                     in a namespace (see below).
   │
   └── PID == 1 in a container ──▶ PID 1 IGNORES signals with no installed handler.
                                    The kernel special-cases init. Add tini/dumb-init,
                                    or install a handler in the application.

Symptom: "load average is 40 but the CPUs are idle"
   │
   └── ps -eo stat= | grep -c '^D'   ──▶ non-zero: Linux load counts D state.
       cat /proc/pressure/io               This is a STORAGE incident.
       for p in $(pgrep -f ''); do cat /proc/$p/wchan; echo; done | sort | uniq -c

Symptom: "cannot fork / Resource temporarily unavailable"
   │
   ├── ps -eo stat= | grep -c '^Z'          ──▶ zombie leak (parent not wait()ing)
   ├── cat /sys/fs/cgroup/<slice>/pids.current  vs  pids.max
   ├── ulimit -u  /  systemctl show <unit> -p TasksMax
   └── cat /proc/sys/kernel/pid_max ; ps -e --no-headers | wc -l
```

### 8.2 Zombie diagnosis, end to end

```
$ ps -eo stat --no-headers | grep -c '^Z'
1247

$ ps -eo pid,ppid,stat,comm | awk '$3 ~ /^Z/ {print}' | head -5
  14203  14198 Z    worker
  14204  14198 Z    worker
  14205  14198 Z    worker
  14206  14198 Z    worker
  14207  14198 Z    worker

$ ps -eo pid,ppid,stat,comm | awk '$3 ~ /^Z/ {print $2}' | sort | uniq -c | sort -rn
   1247 14198

# One parent is responsible for all of them.
$ ps -o pid,ppid,stat,cmd -p 14198
    PID    PPID STAT CMD
  14198       1 Ssl  /usr/bin/python3 /opt/dispatcher/dispatch.py

$ grep -E '^SigCgt|^Threads' /proc/14198/status
Threads:        4
SigCgt: 0000000000010002

# Bit 17 (SIGCHLD) is CLEAR and the code never calls wait(): confirmed leak.

$ cat /proc/14198/wchan; echo
ep_poll

# Immediate mitigation: nudge the parent, then restart it.
$ kill -CHLD 14198
$ ps -eo stat --no-headers | grep -c '^Z'
1247                                  # unchanged - the parent has no handler

$ sudo systemctl restart dispatcher.service
$ ps -eo stat --no-headers | grep -c '^Z'
0

# Zombies re-parented to systemd (PID 1), which reaped them immediately.
```

**Permanent fix:** either install a `SIGCHLD` handler that loops on `waitpid(-1, WNOHANG)` (section 7.3), or run the process under an init that reaps (`tini`), or — in systemd — leave `KillMode=control-group` so the whole tree is cleaned up on stop.

### 8.3 `D` state — proving it is the storage layer

```
$ ps -eo pid,stat,wchan:32,comm --no-headers | awk '$2 ~ /^D/'
   8841 D    nfs_wait_bit_killable            rsync
   8842 D    nfs_wait_bit_killable            rsync
   9103 D    io_schedule                      postgres
   9111 D    wait_on_page_bit                 kworker/u16:3

$ sudo cat /proc/8841/stack
[<0>] nfs_wait_bit_killable+0x2e/0x90 [nfs]
[<0>] __wait_on_bit+0x5c/0xb0
[<0>] out_of_line_wait_on_bit+0x8e/0xb0
[<0>] nfs_wait_client_init_complete+0x64/0xa0 [nfs]
[<0>] nfs4_discover_server_trunking+0x8c/0x2c0 [nfsv4]

$ kill -9 8841
$ ps -o pid,stat -p 8841
    PID STAT
   8841 D

# SIGKILL delivered, process still in D. Confirms: no user-space code is running
# to receive it. The signal is queued in SigPnd until the kernel returns.

$ grep -E 'SigPnd|ShdPnd' /proc/8841/status
SigPnd: 0000000000000100
ShdPnd: 0000000000000100

# Bit 9 = SIGKILL, pending and undeliverable.

$ mount | grep nfs
nfs-01:/exports/data on /mnt/data type nfs4 (rw,relatime,vers=4.2,hard,proto=tcp,timeo=600,...)

$ ping -c 2 -W 2 nfs-01
PING nfs-01 (10.0.4.11) 56(84) bytes of data.
--- nfs-01 ping statistics ---
2 packets transmitted, 0 received, 100% packet loss, time 1023ms
```

**Conclusion and remediation path.** The NFS server is unreachable and the mount uses `hard` semantics, so the client retries forever in an uninterruptible wait. Nothing at the process layer can fix this. Options, in order: (a) restore the server; (b) `umount -f -l /mnt/data` (lazy force) to release the namespace reference; (c) remount with `soft,intr` accepting I/O-error semantics; (d) reboot. `kill -9` is not among them.

### 8.4 The PID 1 signal trap in containers

```
$ docker run -d --name shell-init alpine:3.20 sh -c 'while true; do sleep 5; done'
9c1f2a4b8e73

$ docker exec shell-init ps -eo pid,ppid,stat,comm
PID   PPID  STAT COMMAND
    1     0 S    sh
   14     1 S    sleep
   15     0 R    ps

$ time docker stop shell-init
shell-init
real    0m10.412s        # <-- ten seconds: the full default grace period

$ docker inspect shell-init --format '{{.State.ExitCode}}'
137                      # 128 + 9 = SIGKILL. It was NOT a graceful stop.
```

**Why.** The kernel gives PID 1 a special property: signals with the default action *terminate* are **silently discarded** unless the process has installed an explicit handler. `sh` installs no `SIGTERM` handler, so `docker stop`'s `SIGTERM` vanished and only the 10-second `SIGKILL` ended it. `exit 137` is the fingerprint.

Correct version:

```
$ docker run -d --name tini-init --init alpine:3.20 sh -c 'while true; do sleep 5; done'
4d8e11c92fa6

$ docker exec tini-init ps -eo pid,ppid,stat,comm
PID   PPID  STAT COMMAND
    1     0 S    docker-init
    7     1 S    sh
   13     7 S    sleep

$ time docker stop tini-init
tini-init
real    0m0.318s

$ docker inspect tini-init --format '{{.State.ExitCode}}'
143                      # 128 + 15 = SIGTERM. Graceful.
```

| Exit code | Meaning | Interpretation |
|---|---|---|
| `0` | Clean exit | Success |
| `1`–`125` | Application exit status | Application decided |
| `126` | Not executable | Permission or format problem |
| `127` | Command not found | `PATH` or missing binary |
| `128 + N` | **Killed by signal N** | `130` = SIGINT, `137` = **SIGKILL**, `139` = SIGSEGV, `143` = SIGTERM |

> **`137` in a Kubernetes `kubectl describe pod` is the single most common lifecycle finding.** It means either (a) the grace period expired and the kubelet escalated, or (b) the cgroup OOM killer fired. Distinguish them: `reason: OOMKilled` in the container status means memory; absence of `OOMKilled` with `reason: Error` means the grace period.

```
$ kubectl -n catalog describe pod catalog-api-7d4c9b8f6-lkq8c | sed -n '/Last State/,/Ready/p'
    Last State:     Terminated
      Reason:       Error
      Exit Code:    137
      Started:      Wed, 26 Aug 2026 09:12:04 +0000
      Finished:     Wed, 26 Aug 2026 09:41:49 +0000
    Ready:          True
```

### 8.5 Verification checklist

Run this before declaring any service production-ready:

```bash
#!/usr/bin/env bash
# verify-process-contract.sh <pid|unit>
# Proves - not assumes - that a process honours the lifecycle contract.
set -euo pipefail

pid=${1:?usage: verify-process-contract.sh <pid>}

bit_set() { local mask=$1 bit=$2; (( 0x$mask >> (bit - 1) & 1 )); }

sigcgt=$(awk '/^SigCgt/ {print $2}' "/proc/$pid/status")
sigblk=$(awk '/^SigBlk/ {print $2}' "/proc/$pid/status")
sigign=$(awk '/^SigIgn/ {print $2}' "/proc/$pid/status")

printf '=== process contract for PID %s (%s) ===\n' \
    "$pid" "$(tr -d '\0' < "/proc/$pid/comm")"

printf 'state          : %s\n'  "$(awk '/^State/ {print $2, $3}' /proc/$pid/status)"
printf 'threads        : %s\n'  "$(awk '/^Threads/ {print $2}' /proc/$pid/status)"
printf 'ppid           : %s\n'  "$(awk '/^PPid/ {print $2}' /proc/$pid/status)"
printf 'cgroup         : %s\n'  "$(cut -d: -f3 /proc/$pid/cgroup | tail -1)"
printf 'wchan          : %s\n'  "$(cat /proc/$pid/wchan 2>/dev/null || echo '-')"

bit_set "$sigcgt" 15 && echo 'SIGTERM handler: YES  - graceful shutdown possible' \
                     || echo 'SIGTERM handler: NO   - *** default terminate; verify no in-flight state ***'
bit_set "$sigcgt" 1  && echo 'SIGHUP  handler: YES  - config reload supported' \
                     || echo 'SIGHUP  handler: no   - reload requires restart'
bit_set "$sigcgt" 17 && echo 'SIGCHLD handler: YES  - reaps children' \
                     || echo 'SIGCHLD handler: no   - zombie risk if it forks'
bit_set "$sigblk" 15 && echo 'SIGTERM blocked: *** YES - SIGTERM WILL BE IGNORED ***' \
                     || echo 'SIGTERM blocked: no'
bit_set "$sigign" 13 && echo 'SIGPIPE ignored: yes  - handles EPIPE in userspace' \
                     || echo 'SIGPIPE ignored: no   - broken pipe will kill it'

if [[ $pid -eq 1 ]]; then
    echo 'NOTE: PID 1 - signals without an explicit handler are DISCARDED by the kernel.'
fi
```

```
$ sudo ./verify-process-contract.sh 10241
=== process contract for PID 10241 (catalog-api) ===
state          : S (sleeping)
threads        : 18
ppid           : 1
cgroup         : /system.slice/catalog-api.service
wchan          : futex_wait_queue_me
SIGTERM handler: YES  - graceful shutdown possible
SIGHUP  handler: YES  - config reload supported
SIGCHLD handler: no   - zombie risk if it forks
SIGTERM blocked: no
SIGPIPE ignored: yes  - handles EPIPE in userspace
```

### 8.6 Quick-reference: symptom → command

| Symptom | First command | What it proves |
|---|---|---|
| "It won't die" | `ps -o pid,stat,wchan:24,comm -p PID` | `Z`/`D`/`T` distinction |
| "It died silently at logout" | `grep SigIgn /proc/PID/status`; `ps -o tty,sid` | `SIGHUP` disposition + session |
| "Load is high, CPU is idle" | `ps -eo stat= \| grep -c '^D'` | Load inflated by blocked I/O |
| "Out of memory but `free` shows GB" | `free -w -h`; `/proc/meminfo` `MemAvailable` | `free` ≠ `available` |
| "Cannot fork" | `cat /sys/fs/cgroup/.../pids.{current,max}`; `ulimit -u` | PID/task limit hit |
| "Job stopped by itself" | `jobs -l`; `ps -o stat` → `T` | `SIGTTIN` — wants stdin |
| "Deploy causes 502s" | `grep SigCgt`; check `preStop` + grace period | No handler or racing endpoint removal |
| "Exit code 137" | `kubectl describe pod` → `OOMKilled`? | OOM vs grace-period `SIGKILL` |
| "Process is using 100% CPU" | `top -H -p PID`, then `strace -c -p TID` | Which thread, which syscall |
| "Which unit owns this PID?" | `ps -o cgroup= -p PID`; `systemctl status PID` | cgroup → unit mapping |

```
$ systemctl status 10248
● catalog-api.service - Catalog API (HTTP, graceful shutdown)
     Loaded: loaded (/etc/systemd/system/catalog-api.service; enabled)
     Active: active (running) since Wed 2026-08-26 08:41:12 UTC; 1h 12min ago
   Main PID: 10241 (catalog-api)
      Tasks: 3 (limit: 512)
     CGroup: /system.slice/catalog-api.service
             ├─10241 /opt/catalog-api/bin/catalog-api --config /etc/catalog-api/config.yaml
             ├─10248 /opt/catalog-api/bin/catalog-worker --queue=default
             └─10249 /opt/catalog-api/bin/catalog-worker --queue=priority
```

---

## 9. Exam-focused summary

### 9.1 Command matrix for objective 103.5

| Utility | Primary purpose | Must-know invocation |
|---|---|---|
| `&` | Run in background | `cmd &` → prints `[job] PID` |
| `jobs` | List shell jobs | `jobs -l` (with PIDs), `jobs -p` |
| `fg` | Bring to foreground | `fg %1`, `fg` (current job) |
| `bg` | Resume stopped job in background | `bg %1` |
| `kill` | Send a signal | `kill -9 PID`, `kill -s TERM PID`, `kill %1`, `kill -l` |
| `nohup` | Ignore `SIGHUP` | `nohup cmd > out 2>&1 &` |
| `ps` | Process snapshot | `ps aux`, `ps -ef`, `ps -eo …`, `ps axjf`, `--sort=-pcpu` |
| `top` | Live process monitor | `top -b -n1`, keys `M P k r H 1 c` |
| `free` | Memory summary | `free -h`, `free -m -w`, watch `available` |
| `uptime` | Load average | `uptime`, `/proc/loadavg` |
| `pgrep` | Find PIDs by pattern | `pgrep -af name`, `pgrep -u user -x name` |
| `pkill` | Signal by pattern | `pkill -HUP -x nginx`, `pkill -f pattern` |
| `killall` | Signal by exact name | `killall -s HUP nginx`, `killall -w`, `killall -o 2h` |
| `watch` | Repeat a command | `watch -n1 -d 'cmd'` (quote the pipeline!) |
| `screen` | Detachable session | `screen -S n`, `Ctrl-a d`, `screen -ls`, `screen -r n` |
| `tmux` | Detachable session | `tmux new -s n`, `Ctrl-b d`, `tmux ls`, `tmux attach -t n` |

### 9.2 Traps that cost marks and outages

1. **`kill` does not kill.** It sends a signal. Default is `SIGTERM` (15), not `SIGKILL` (9).
2. **`SIGKILL` (9) and `SIGSTOP` (19) cannot be caught, blocked, or ignored** — by anything, ever.
3. **A `D`-state process ignores `SIGKILL`** because there is no user context to deliver it to. This is not a contradiction of rule 2 — the signal is *pending*, not *ignored*.
4. **A zombie cannot be killed.** It is already dead. Signal or restart the parent.
5. **`kill -TERM -4210`** (negative) targets the process *group*; **`kill -TERM 4210`** targets one PID.
6. **`nohup` does not detach.** It only sets `SIGHUP` to ignored and redirects stdout. `setsid` detaches.
7. **`bash` does not send `SIGHUP` on exit by default** (`shopt huponexit` is off). A *dropped* connection is a different mechanism — the kernel hangs up the tty.
8. **`free` low is healthy; `available` low is the alert.**
9. **Linux load average includes `D` state.** High load with idle CPUs means blocked I/O.
10. **`ps -aux` is not `ps aux`.** The dash makes it UNIX syntax and `x` becomes a username.
11. **`pkill` matches substrings by default.** `pgrep -a` first, always.
12. **`killall` on Solaris kills every process.** On Linux (psmisc) it matches by name. Do not carry the habit across platforms.
13. **`watch cmd | grep x` watches nothing useful.** Quote the whole pipeline.
14. **PID 1 discards signals it has no handler for.** This is why containers need `tini` or an application that handles `SIGTERM`.
15. **Exit code `128 + N` means killed by signal N.** `137` = `SIGKILL`, `143` = `SIGTERM`.
16. **`SIGUSR1`/`SIGUSR2` are 10/12 on x86-64, not universally.** Use names.
17. **nginx inverts the convention:** `SIGQUIT` is graceful, `SIGTERM` is fast/lossy.

---

## 10. References

**Certification objectives**
- LPI — Exam 101-500 Objectives (v5.0), Topic 103.5 *Create, monitor and kill processes*: https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — LPIC-1 certification overview: https://www.lpi.org/our-certifications/lpic-1-overview/

**Kernel and system-call interfaces (`man-pages` project)**
- `signal(7)` — signal numbers, default actions, catchability: https://man7.org/linux/man-pages/man7/signal.7.html
- `kill(1)` — the command: https://man7.org/linux/man-pages/man1/kill.1.html
- `kill(2)` — the system call, including negative PID semantics: https://man7.org/linux/man-pages/man2/kill.2.html
- `fork(2)`: https://man7.org/linux/man-pages/man2/fork.2.html
- `execve(2)` — signal disposition across `exec`: https://man7.org/linux/man-pages/man2/execve.2.html
- `wait(2)` / `waitpid(2)` — zombie reaping: https://man7.org/linux/man-pages/man2/wait.2.html
- `credentials(7)` — process groups, sessions, controlling terminal: https://man7.org/linux/man-pages/man7/credentials.7.html
- `setsid(2)`: https://man7.org/linux/man-pages/man2/setsid.2.html
- `setsid(1)`: https://man7.org/linux/man-pages/man1/setsid.1.html
- `proc(5)` — `/proc/[pid]/status`, `stat`, `wchan`, `/proc/loadavg`, `/proc/meminfo`: https://man7.org/linux/man-pages/man5/proc.5.html
- `prctl(2)` — `PR_SET_CHILD_SUBREAPER`: https://man7.org/linux/man-pages/man2/prctl.2.html
- `cgroups(7)` — `pids` controller: https://man7.org/linux/man-pages/man7/cgroups.7.html
- `nohup(1)`: https://man7.org/linux/man-pages/man1/nohup.1.html

**procps-ng (`ps`, `top`, `free`, `uptime`, `pgrep`, `pkill`, `watch`)**
- Project home: https://gitlab.com/procps-ng/procps
- `ps(1)`: https://man7.org/linux/man-pages/man1/ps.1.html
- `top(1)`: https://man7.org/linux/man-pages/man1/top.1.html
- `free(1)`: https://man7.org/linux/man-pages/man1/free.1.html
- `uptime(1)`: https://man7.org/linux/man-pages/man1/uptime.1.html
- `pgrep(1)` / `pkill(1)`: https://man7.org/linux/man-pages/man1/pgrep.1.html
- `watch(1)`: https://man7.org/linux/man-pages/man1/watch.1.html

**psmisc (`killall`, `pstree`, `fuser`)**
- Project home: https://gitlab.com/psmisc/psmisc
- `killall(1)`: https://man7.org/linux/man-pages/man1/killall.1.html
- `pstree(1)`: https://man7.org/linux/man-pages/man1/pstree.1.html

**Shell job control**
- GNU Bash Reference Manual — Job Control: https://www.gnu.org/software/bash/manual/bash.html#Job-Control
- GNU Bash Reference Manual — Job Control Builtins (`bg`, `fg`, `jobs`, `kill`, `wait`, `disown`): https://www.gnu.org/software/bash/manual/bash.html#Job-Control-Builtins
- POSIX.1-2024 — Shell and Utilities, `kill`: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/kill.html

**Terminal multiplexers**
- GNU Screen manual: https://www.gnu.org/software/screen/manual/screen.html
- tmux project and manual: https://github.com/tmux/tmux/wiki

**systemd**
- `systemd.kill(5)` — `KillMode`, `KillSignal`, `SendSIGKILL`, `FinalKillSignal`: https://www.freedesktop.org/software/systemd/man/latest/systemd.kill.html
- `systemd.service(5)` — `Type`, `ExecReload`, `TimeoutStopSec`, `Restart`: https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html
- `systemd.resource-control(5)` — `TasksMax`, `MemoryMax`, `CPUQuota`: https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html
- `systemd-run(1)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html
- `systemd-cgls(1)` / `systemd-cgtop(1)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-cgls.html

**Containers and orchestration**
- Kubernetes — Pod Lifecycle, termination and grace periods: https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination
- Kubernetes — Container Lifecycle Hooks (`preStop`): https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/
- Kubernetes — Share Process Namespace Between Containers in a Pod: https://kubernetes.io/docs/tasks/configure-pod-container/share-process-namespace/
- Kubernetes — Debug Running Pods (ephemeral containers): https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubernetes — Process ID Limits and Reservations: https://kubernetes.io/docs/concepts/policy/pid-limiting/
- Docker — `docker stop` and `STOPSIGNAL`: https://docs.docker.com/reference/cli/docker/container/stop/
- tini — a tiny but valid init for containers: https://github.com/krallin/tini

**Application signal conventions**
- nginx — Controlling nginx (signal table, `SIGQUIT` graceful vs `SIGTERM` fast): https://nginx.org/en/docs/control.html

**Supplementary observability**
- Linux kernel documentation — Pressure Stall Information: https://docs.kernel.org/accounting/psi.html
- sysstat (`pidstat`, `sar`): https://github.com/sysstat/sysstat