# LPIC-1 · Topic 107.2 — Automate system administration tasks by scheduling jobs

> **Exam:** 102-500 (LPIC-1 v5.0), Topic 107 — Administrative Tasks
> **Actual published weight: 4** (the `0.0` in the generation metadata is a syllabus-import artifact; 107.2 is one of the heavier objectives in 102-500 and is treated at full depth here).
> **Key files, terms and utilities (per LPI):** `/usr/bin/crontab`, `/etc/crontab`, `/etc/cron.{d,daily,hourly,monthly,weekly}`, `/var/spool/cron/`, `/etc/cron.allow`, `/etc/cron.deny`, `/etc/at.allow`, `/etc/at.deny`, `at`, `atq`, `atrm`, `crontab`, `systemd-run`, `systemctl` (timers), `.timer` and `.service` units.

---

## 1. Motivation: the architectural problem behind "just run it every night"

Every production platform accumulates a shadow control plane made of periodic work: certificate renewal, log rotation, backup snapshots, cache warmers, reconciliation loops, metric rollups, orphaned-resource garbage collection. This work is not part of any request path, so it has no user complaining when it silently stops. That asymmetry is the whole problem.

A scheduled job is a **distributed system with one node and no observability by default**. Consider what it actually needs to be correct in production:

| Requirement | Why it bites you in production | Naïve cron behaviour |
|---|---|---|
| **Deterministic environment** | The job worked in your shell, fails under the scheduler | `PATH=/usr/bin:/bin`, `SHELL=/bin/sh`, no `~/.bashrc`, no `LANG`, no SSH agent, no `$HOME` you assumed |
| **Mutual exclusion** | Backup at 02:00 still running when 03:00 fires → two `rsync` writing one target | cron happily starts overlapping instances forever |
| **Missed-run recovery** | Laptop/VM was off at 03:00; the monthly report never runs | classic cron: the run is simply lost |
| **Thundering herd** | 4 000 nodes all `curl` the artifact mirror at `0 3 * * *` | every node fires at exactly the same second |
| **Failure visibility** | Job exits 1 for 6 weeks, nobody notices | output is mailed to a local mailbox nobody reads; the exit code is discarded |
| **Resource containment** | A runaway rollup job OOMs the database node | cron forks a process with the caller's full limits and no cgroup |
| **Time discontinuity** | DST spring-forward: `02:30` does not exist; fall-back: it exists twice | Vixie cron has heuristics; they are not what most people assume |
| **Auditability** | "Who scheduled this? When? From what change?" | `crontab -e` is an untracked, unreviewed mutation of `/var/spool` |

Topic 107.2 is where you learn the three Linux mechanisms that address these — **cron**, **anacron/at**, and **systemd timers** — and, more importantly, *which one is the correct architectural choice*. The SRE-relevant framing: **cron is a fire-and-forget process launcher; systemd timers are a supervised, cgroup-confined, journald-instrumented scheduling front-end to the service manager.** They are not interchangeable, and the exam expects fluency in both.

The container-orchestration analogue is exact and worth holding in mind: a Kubernetes `CronJob` is `.spec.schedule` (a cron expression) plus `concurrencyPolicy` (mutual exclusion), `startingDeadlineSeconds` (missed-run policy), `backoffLimit` (retry), and `successfulJobsHistoryLimit` (observability). Those four fields exist precisely because raw cron lacks all four. On a Linux host, `systemd` timers are where you get the equivalents.

---

## 2. The scheduler landscape: technical comparison

### 2.1 Trade-off matrix

| Capability | Vixie/`cronie` cron | `anacron` | `at` / `batch` | `systemd.timer` | Kubernetes `CronJob` |
|---|---|---|---|---|---|
| Trigger model | Wall-clock calendar, 1-minute granularity | Elapsed-days since last success | One-shot at absolute/relative time | Calendar **and** monotonic (`OnBootSec`, `OnUnitActiveSec`) | Wall-clock calendar (controller-polled) |
| Sub-minute granularity | ✗ (1 min floor) | ✗ | ✗ | ✓ (`OnUnitActiveSec=30s`, `AccuracySec=1s`) | ✗ |
| Catch-up after downtime | ✗ (run is lost) | ✓ (core purpose) | ✗ (job fires when `atd` next starts — late but not lost) | ✓ `Persistent=true` | Partial: `startingDeadlineSeconds` |
| Overlap prevention | ✗ (needs `flock`) | ✓ (per-job serialisation) | n/a | ✓ (unit is already active → trigger is a no-op) | ✓ `concurrencyPolicy: Forbid` |
| Jitter / herd control | ✗ (manual `sleep $((RANDOM%...))`) | ✓ `RANDOM_DELAY` | ✗ | ✓ `RandomizedDelaySec=` | ✗ |
| Resource limits | Inherited only | Inherited only | Inherited only | ✓ full cgroup: `MemoryMax=`, `CPUQuota=`, `IOWeight=` | ✓ pod resources |
| Sandboxing | ✗ | ✗ | ✗ | ✓ `ProtectSystem=`, `PrivateTmp=`, `NoNewPrivileges=`, `CapabilityBoundingSet=` | ✓ securityContext |
| Exit status handling | Discarded (mail on *output*, not on failure) | Discarded | Discarded | ✓ recorded, `OnFailure=` unit, `Restart=` | ✓ `backoffLimit` |
| Logging | syslog line + mail | syslog | mail | ✓ structured journald (`_SYSTEMD_UNIT`, `INVOCATION_ID`) | ✓ pod logs |
| Dependency ordering | ✗ | ✗ | ✗ | ✓ `After=`, `Requires=`, `Wants=` | ✗ |
| Load-aware deferral | ✗ | ✗ | ✓ (`batch`, loadavg < 1.5) | ✗ (approximate via `ConditionCPUPressure` on new systemd) | ✗ |
| Per-user self-service | ✓ `crontab -e` | ✗ (system-wide; user anacrontabs are manual) | ✓ | ✓ `systemctl --user` (needs lingering) | n/a |
| Timezone control | Daemon TZ / `CRON_TZ=` | System TZ | System TZ | ✓ `OnCalendar=... ` + `Timezone` in newer systemd; else `TZ=` in Environment | ✓ `.spec.timeZone` |
| Declarative / GitOps-able | Via `/etc/cron.d` files | Via `/etc/anacrontab` | ✗ (imperative by nature) | ✓ unit files | ✓ |
| Exam presence (LPIC-1) | **Heavy** | **Moderate** | **Heavy** | **Moderate** | ✗ |

**Architect's decision rule:**

- **New system-level automation on a systemd host → write a `.timer` + `.service` pair.** You get supervision, cgroups, journald, dependency ordering and catch-up for free.
- **Per-user, low-stakes, portable, or the host isn't systemd (containers, BSD-ish, minimal images) → cron.**
- **Machine is not always on (laptops, dev VMs, intermittently powered edge nodes) → anacron, or `Persistent=true` timers.**
- **One-shot deferred work (a scheduled maintenance action, a "retry this in 20 minutes") → `at` or `systemd-run --on-active=`.**
- **Never** hand-edit a crontab on a fleet node. Ship it through configuration management as a file in `/etc/cron.d/` or a unit file, so it is reviewable, diffable and revertible.

### 2.2 cron implementations you will actually meet

| Implementation | Default on | Notable behaviour |
|---|---|---|
| `cronie` (fork of Vixie cron) | RHEL/Rocky/Alma/Fedora, openSUSE, Arch | `inotify` on spool → `crontab -e` takes effect instantly; PAM-aware (`/etc/pam.d/crond`); `-s` syslog integration; `/etc/sysconfig/crond` |
| Debian `cron` (Vixie-derived) | Debian, Ubuntu | Polls spool mtime each minute; strict `/etc/cron.d` filename rules (`run-parts` naming: no dots); `/etc/default/cron` |
| `bcron`, `fcron`, `dcron` | niche | `fcron` adds "run if system was down", job serialisation, `@` intervals natively |
| `systemd-cron` | opt-in | Generator that converts crontabs into transient timer units |
| `busybox crond` | embedded/containers | Minimal; no `@reboot` in some builds; different mail semantics |

Exam answers should assume **Vixie-compatible syntax**, which all of the above honour.

---

## 3. cron internals

### 3.1 Daemon architecture

```
                    ┌──────────────────────────────────────────┐
   crontab(1)  ──►  │  /var/spool/cron/crontabs/<user>  (0600) │  ← per-user, no user field
   (setgid crontab) └──────────────────────────────────────────┘
                    ┌──────────────────────────────────────────┐
   package mgr ──►  │  /etc/crontab                            │  ← system, HAS user field
   config mgmt ──►  │  /etc/cron.d/*                           │  ← system, HAS user field
                    └──────────────────────────────────────────┘
                                     │
                                     ▼
                          ┌────────────────────┐
                          │  crond (PID 1 child)│  wakes every 60 s (or on inotify)
                          │  reload if mtime ↑  │
                          └────────┬───────────┘
                                   │ match minute
                                   ▼
                     fork() ─► setgid/setuid(user)  [+ PAM session on cronie]
                            ─► chdir($HOME)
                            ─► exec $SHELL -c "command"
                                   │
                          stdout+stderr ──► sendmail ──► MAILTO / job owner
                          exit status   ──► /dev/null   ← the silent-failure trap
```

Points that generate exam questions and production incidents alike:

1. **`crond` never runs a job more than once per minute per crontab line.** Sub-minute scheduling with cron requires a wrapper loop — which is a smell; use a timer.
2. **The job's stdout *and* stderr are captured.** If the command produces **any** output, cron mails it. A job that prints a progress bar generates a mail every run. A job that fails silently generates nothing.
3. **The exit status is discarded.** `MAILTO` is an *output* notifier, not a *failure* notifier. This is the single most important operational fact in this topic.
4. **cron does not source login files.** No `/etc/profile`, no `~/.bash_profile`, no `~/.bashrc` (the latter because `/bin/sh` is non-interactive and `BASH_ENV` is unset).
5. **`crontab` is setgid `crontab`** (Debian) or setuid root (cronie), so unprivileged users can write into a root-owned spool directory without direct write access. Never `chmod` the spool.

### 3.2 The crontab field format

```
# ┌───────────── minute        (0 - 59)
# │ ┌─────────── hour          (0 - 23)
# │ │ ┌───────── day of month  (1 - 31)
# │ │ │ ┌─────── month         (1 - 12, or jan..dec)
# │ │ │ │ ┌───── day of week   (0 - 7, 0 and 7 = Sunday, or sun..sat)
# │ │ │ │ │
# * * * * *  command to be executed
```

Field operators:

| Operator | Example | Meaning |
|---|---|---|
| `*` | `* * * * *` | every value of the field |
| `,` list | `0 2,14 * * *` | 02:00 and 14:00 |
| `-` range | `0 9-17 * * 1-5` | hourly, 09:00–17:00, Mon–Fri |
| `/` step | `*/15 * * * *` | :00, :15, :30, :45 |
| range + step | `0 0-23/2 * * *` | every 2 hours starting at 00:00 |
| names | `0 4 * * sun` | Sundays (names are **not** valid in ranges/lists on all implementations — prefer numbers) |

**The DOM/DOW OR-rule — a guaranteed exam item.** If *both* day-of-month and day-of-week are restricted (neither is `*`), cron runs the job when **either** matches, not both:

```cron
# Runs on the 13th of every month, AND on every Friday. NOT only Friday the 13th.
0 3 13 * 5   /usr/local/bin/audit.sh
```

To get a true AND, restrict one field to `*` and test the other in the command:

```cron
# Truly only Friday the 13th
0 3 13 * *   [ "$(date +\%u)" -eq 5 ] && /usr/local/bin/audit.sh
```

**The `%` trap — the second guaranteed exam item.** In a crontab command, an unescaped `%` is translated to a newline; everything after the *first* `%` becomes the command's **standard input**. This is why `date +%F` inside a crontab silently breaks:

```cron
# WRONG — cron rewrites this to `date +` with "F" fed on stdin
0 1 * * *  /usr/bin/tar czf /backup/etc-$(date +%F).tgz /etc

# RIGHT — escape every percent
0 1 * * *  /usr/bin/tar czf /backup/etc-$(date +\%F).tgz /etc

# BEST — no percent in the crontab at all; put logic in a script
0 1 * * *  /usr/local/sbin/backup-etc
```

Deliberate use of the stdin behaviour:

```cron
# Everything after the first % is stdin for mailx
30 6 * * 1 /usr/bin/mailx -s "Weekly capacity" sre@example.com%Disk report follows:%%$(df -h)
```

### 3.3 Special schedule strings (nicknames)

| Nickname | Equivalent | Notes |
|---|---|---|
| `@reboot` | — | Once, when `crond` starts. **Not** "on every boot" if cron is restarted; and it does **not** run for `/etc/cron.d` on all implementations. Prefer a systemd unit with `WantedBy=multi-user.target`. |
| `@yearly`, `@annually` | `0 0 1 1 *` | |
| `@monthly` | `0 0 1 * *` | |
| `@weekly` | `0 0 * * 0` | |
| `@daily`, `@midnight` | `0 0 * * *` | |
| `@hourly` | `0 * * * *` | |

### 3.4 Environment variables inside a crontab

Assignments must appear **before** the schedule lines that use them; there is no shell expansion on the right-hand side of a crontab assignment (`PATH=$PATH:/opt/bin` does **not** work).

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=sre-oncall@example.com
MAILFROM=cron@web-07.example.com          # cronie only
CRON_TZ=UTC                               # Vixie/cronie: interpret schedules in this TZ
LANG=C.UTF-8
HOME=/var/lib/reporting

# MAILTO="" for this whole crontab would disable mail entirely.
```

Defaults cron sets on its own: `SHELL=/bin/sh`, `HOME` and `LOGNAME`/`USER` from `/etc/passwd`, and a minimal `PATH` (`/usr/bin:/bin` on Debian cron, `/sbin:/bin:/usr/sbin:/usr/bin` on cronie). Everything else is absent.

### 3.5 `crontab(1)` — the user-facing commands

| Command | Effect |
|---|---|
| `crontab -l` | List the invoking user's crontab to stdout |
| `crontab -e` | Edit via `$VISUAL`/`$EDITOR`, syntax-check, install atomically |
| `crontab -r` | **Remove** the crontab — no confirmation. Dangerously adjacent to `-e` on a keyboard. |
| `crontab -i -r` | Remove with confirmation prompt |
| `crontab <file>` | **Replace** the crontab from a file (this is the idempotent, automatable form) |
| `crontab -u alice -l` | Operate on another user's crontab (root only) |
| `crontab -` | Read the new crontab from stdin |

```console
$ crontab -l
no crontab for deploy

$ cat > /tmp/deploy.cron <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
MAILTO=sre-oncall@example.com

# m h dom mon dow  command
*/10 * * * *  /usr/bin/flock -n /run/lock/artifact-sync.lock /usr/local/bin/artifact-sync
17   4 * * *  /usr/local/bin/prune-registry --older-than 30d
EOF

$ crontab /tmp/deploy.cron
$ crontab -l
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
MAILTO=sre-oncall@example.com

# m h dom mon dow  command
*/10 * * * *  /usr/bin/flock -n /run/lock/artifact-sync.lock /usr/local/bin/artifact-sync
17   4 * * *  /usr/local/bin/prune-registry --older-than 30d

$ sudo ls -l /var/spool/cron/crontabs/deploy
-rw------- 1 deploy crontab 331 Aug 27 11:42 /var/spool/cron/crontabs/deploy
```

Note the ownership: file owned by the user, group `crontab`, mode `0600`. On RHEL the path is `/var/spool/cron/deploy` and the group is `root`.

Syntax validation happens at install time:

```console
$ echo '99 * * * * /bin/true' | crontab -
"/tmp/crontab.Xk29aB":1: bad minute
errors in crontab file, can't install.
```

**Backup discipline before touching a fleet crontab:**

```console
$ crontab -l > ~/crontab.$(date +%F-%H%M).bak 2>/dev/null || echo "(none)"
$ sudo tar czf /root/crontabs-$(date +%F).tgz /var/spool/cron /etc/crontab /etc/cron.d /etc/cron.*ly
```

### 3.6 System crontabs: `/etc/crontab` and `/etc/cron.d/`

These files carry an **extra sixth field — the user** — between the schedule and the command. This is the single most-tested syntactic difference in 107.2.

```console
$ cat /etc/crontab
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# m h dom mon dow user  command
17 *    * * *   root    cd / && run-parts --report /etc/cron.hourly
25 6    * * *   root    test -x /usr/sbin/anacron || { cd / && run-parts --report /etc/cron.daily; }
47 6    * * 7   root    test -x /usr/sbin/anacron || { cd / && run-parts --report /etc/cron.weekly; }
52 6    1 * *   root    test -x /usr/sbin/anacron || { cd / && run-parts --report /etc/cron.monthly; }
```

Read that carefully — it encodes the **cron/anacron handoff**: if `anacron` is installed, the daily/weekly/monthly directories are *not* run by cron; anacron owns them.

`/etc/cron.d/` is the drop-in directory and the correct target for configuration management:

```console
$ sudo tee /etc/cron.d/node-exporter-textfile >/dev/null <<'EOF'
# Managed by Ansible — do not edit by hand.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""

# m  h  dom mon dow  user       command
*/5  *  *   *   *    node_exp   /usr/local/bin/collect-textfile-metrics.sh
EOF
$ sudo chmod 0644 /etc/cron.d/node-exporter-textfile
$ sudo chown root:root /etc/cron.d/node-exporter-textfile
```

**`/etc/cron.d` filename rules — a silent-failure classic.** Debian's cron applies `run-parts` naming: the filename must consist only of `[A-Za-z0-9_-]`. A file named `backup.cron`, `sync.sh` or `job.dpkg-new` is **ignored without any error**. cronie is more permissive but still skips names containing `.` in some configurations. Always name drop-ins without an extension.

`/etc/cron.d` files must be regular files, root-owned, not group/world-writable, or cron refuses them.

### 3.7 `run-parts` and the `cron.{hourly,daily,weekly,monthly}` directories

```console
$ ls -l /etc/cron.daily/
total 20
-rwxr-xr-x 1 root root  311 Mar 22 09:14 0anacron
-rwxr-xr-x 1 root root 1478 Jan 11 03:02 apt-compat
-rwxr-xr-x 1 root root  123 Feb  2 17:40 dpkg
-rwxr-xr-x 1 root root  377 Apr  9 12:31 logrotate
-rwxr-xr-x 1 root root 1123 May 18 08:55 man-db

$ run-parts --test /etc/cron.daily
/etc/cron.daily/0anacron
/etc/cron.daily/apt-compat
/etc/cron.daily/dpkg
/etc/cron.daily/logrotate
/etc/cron.daily/man-db
```

`run-parts` requirements for a script to execute: **executable bit set**, **valid filename** (`[A-Za-z0-9_-]` only — this is why `logrotate` works and `logrotate.sh` does not), and it runs scripts in **C-locale lexical order** (hence the `0anacron` prefix to force it first).

```console
$ sudo install -m 0755 /dev/stdin /etc/cron.daily/trim-container-images <<'EOF'
#!/bin/sh
set -eu
# Reclaim overlay2 space nightly; never fail the whole cron.daily run.
/usr/bin/podman image prune --all --force --filter "until=168h" >/dev/null 2>&1 || exit 0
EOF

$ run-parts --test /etc/cron.daily | grep trim
/etc/cron.daily/trim-container-images
```

`--report` (used by Debian's `/etc/crontab`) prefixes any output with the script name, so a mail from `cron.daily` tells you *which* script talked.

---

## 4. `anacron` — scheduling for machines that are not always on

cron assumes the machine is up at the scheduled instant. `anacron` assumes it is not, and instead tracks **days elapsed since the job last succeeded**.

### 4.1 `/etc/anacrontab`

```console
$ cat /etc/anacrontab
# /etc/anacrontab: configuration file for anacron
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
HOME=/root
LOGNAME=root

# These replace cron's entries
RANDOM_DELAY=45
START_HOURS_RANGE=3-22

# period(days)  delay(min)  job-identifier   command
1               5           cron.daily       run-parts --report /etc/cron.daily
7               25          cron.weekly      run-parts --report /etc/cron.weekly
@monthly        45          cron.monthly     run-parts --report /etc/cron.monthly
```

Field semantics:

| Field | Meaning |
|---|---|
| **period** | Days between runs. `1`, `7`, `30`, or `@daily`/`@weekly`/`@monthly`/`@yearly` |
| **delay** | Minutes to wait after anacron starts before launching this job — staggers boot-time load |
| **job-identifier** | Unique name; becomes the timestamp filename under `/var/spool/anacron/` and the lock name |
| **command** | Executed via `SHELL -c` |

`RANDOM_DELAY=45` adds 0–45 extra minutes — **built-in jitter**, the anti-thundering-herd control cron lacks.
`START_HOURS_RANGE=3-22` prevents jobs from starting between 22:00 and 03:00.

### 4.2 The timestamp spool

```console
$ ls -l /var/spool/anacron/
total 12
-rw------- 1 root root 9 Aug 27 03:11 cron.daily
-rw------- 1 root root 9 Aug 24 03:47 cron.monthly
-rw------- 1 root root 9 Aug 25 03:22 cron.weekly

$ cat /var/spool/anacron/cron.daily
20260827
```

anacron compares today's date to that stamp. If `today - stamp >= period`, the job is due. The stamp is written **only on successful completion**, which gives anacron its retry-until-success property.

### 4.3 Running and testing anacron

```console
$ sudo anacron -T && echo "anacrontab syntax OK"
anacrontab syntax OK

$ sudo anacron -n -d cron.daily          # -n: run now, ignore delays; -d: foreground, log to stderr
Anacron 2.3 started on 2026-08-27
Will run job `cron.daily' in 0 min.
Jobs will be executed sequentially
Job `cron.daily' started
/etc/cron.daily/logrotate:
/etc/cron.daily/man-db:
Job `cron.daily' terminated
Normal exit (1 job run)

$ sudo anacron -u                        # update timestamps WITHOUT running anything
$ sudo anacron -f                        # force: run all jobs regardless of timestamps
$ sudo anacron -s                        # serialise: never run two jobs concurrently
```

On modern distributions anacron itself is triggered by a systemd timer rather than by cron:

```console
$ systemctl list-timers anacron.timer
NEXT                        LEFT       LAST                        PASSED     UNIT          ACTIVATES
Wed 2026-08-27 15:30:00 -03 3h 47min   Wed 2026-08-27 14:30:00 -03 12min ago  anacron.timer anacron.service

$ systemctl cat anacron.timer
# /usr/lib/systemd/system/anacron.timer
[Unit]
Description=Trigger anacron every hour

[Timer]
OnCalendar=*-*-* 00..23:30
RandomizedDelaySec=5m
Persistent=true

[Install]
WantedBy=timers.target
```

### 4.4 anacron vs cron — when each is right

| Scenario | Correct tool | Reason |
|---|---|---|
| 24×7 server, run at exactly 02:00 | cron / timer | Precision matters, machine is always up |
| Laptop or dev VM, "roughly daily" | anacron | Survives being powered off |
| Sub-daily (every 15 min) | cron / timer | anacron's minimum period is 1 day |
| Job must run as a non-root user | cron / timer | `/etc/anacrontab` has no user field; runs as root |
| Fleet-wide nightly with jitter | anacron or timer with `RandomizedDelaySec` | Herd control |
| Precise time-of-day + catch-up | systemd timer with `Persistent=true` | anacron cannot pin a time-of-day |

---

## 5. `at`, `batch`, `atq`, `atrm` — one-shot deferred execution

### 5.1 The `atd` daemon and the job spool

```console
$ systemctl status atd
● atd.service - Deferred execution scheduler
     Loaded: loaded (/lib/systemd/system/atd.service; enabled; preset: enabled)
     Active: active (running) since Wed 2026-08-27 08:02:14 -03; 6h ago
       Docs: man:atd(8)
   Main PID: 743 (atd)
      Tasks: 1 (limit: 4653)
     Memory: 452.0K
        CPU: 11ms
     CGroup: /system.slice/atd.service
             └─743 /usr/sbin/atd -f
```

`at` captures the **entire current environment** (except `TERM`, `DISPLAY` and `_`) plus the current working directory and umask, writes them into a shell script under the spool, and replays them at execution time. This is the crucial behavioural difference from cron:

```console
$ sudo ls -l /var/spool/cron/atjobs/          # Debian; RHEL: /var/spool/at/
total 8
-rwx------ 1 deploy deploy 5891 Aug 27 14:41 a0000c01c6f2b1
-rwx------ 1 root   root      0 Aug 27 08:02 .SEQ

$ sudo head -20 /var/spool/cron/atjobs/a0000c01c6f2b1
#!/bin/sh
# atrun uid=1001 gid=1001
# mail deploy 0
umask 22
LANG=en_US.UTF-8; export LANG
PATH=/usr/local/bin:/usr/bin:/bin; export PATH
HOME=/home/deploy; export HOME
LOGNAME=deploy; export LOGNAME
USER=deploy; export USER
SHELL=/bin/bash; export SHELL
PWD=/srv/app; export PWD
cd /srv/app || {
	 echo 'Execution directory inaccessible' >&2
	 exit 1
}
${SHELL:-/bin/sh} << 'marcinDELIMITER0a1b2c3d'
/usr/local/bin/rollback-release --to v4.2.1
marcinDELIMITER0a1b2c3d
```

Note `# mail deploy 0` — the trailing `0` means "only mail if there is output"; `at -m` sets it to mail unconditionally.

### 5.2 Time specification grammar

| Form | Example |
|---|---|
| Absolute clock | `at 23:45`, `at 4pm`, `at 16:00` |
| Named times | `at noon`, `at midnight`, `at teatime` (16:00) |
| Clock + date | `at 10:00 Aug 30`, `at 10:00 2026-08-30`, `at 4pm + 3 days` |
| Date formats | `MMDDYY`, `MM/DD/YY`, `DD.MM.YYYY`, `YYYY-MM-DD` |
| Relative | `at now + 30 minutes`, `at now + 2 hours`, `at now + 1 week` |
| Relative units | `minutes`, `hours`, `days`, `weeks`, `months`, `years` |
| Suffixes | `at 12:00 today`, `at 12:00 tomorrow`, `at 9am UTC` |
| From a file | `at -f script.sh 03:00` |
| Queue selection | `at -q d now + 1 hour` (queues `a`–`z`, `A`–`Z`) |

Queue letter determines nice level: queue `a` runs at nice 0, `b` at nice 1, … each later letter one step nicer. Uppercase queues are `batch` queues. Default: `a` for `at`, `b` for `batch`.

### 5.3 Practical session

```console
$ at now + 15 minutes
warning: commands will be executed using /bin/sh
at> /usr/local/bin/drain-node --node web-07 --grace 300
at> /usr/bin/systemctl stop nginx.service
at> <EOT>
job 12 at Wed Aug 27 15:02:00 2026

$ at -f /usr/local/sbin/quarterly-close.sh 02:00 2026-10-01
job 13 at Thu Oct  1 02:00:00 2026

$ echo '/usr/local/bin/expire-tokens --batch' | at -M 03:30 tomorrow
job 14 at Thu Aug 28 03:30:00 2026
```

`-M` suppresses mail entirely; `-m` forces mail even with no output.

```console
$ atq
13	Thu Oct  1 02:00:00 2026 a deploy
12	Wed Aug 27 15:02:00 2026 a deploy
14	Thu Aug 28 03:30:00 2026 a deploy

$ at -c 12 | tail -5
${SHELL:-/bin/sh} << 'marcinDELIMITER00000001'
/usr/local/bin/drain-node --node web-07 --grace 300
/usr/bin/systemctl stop nginx.service

marcinDELIMITER00000001

$ atrm 12
$ atq
13	Thu Oct  1 02:00:00 2026 a deploy
14	Thu Aug 28 03:30:00 2026 a deploy
```

Root sees every user's jobs; a normal user sees only their own. `atq` is `at -l`; `atrm` is `at -d` / `at -r`.

### 5.4 `batch` — load-average-gated execution

```console
$ batch
warning: commands will be executed using /bin/sh
at> /usr/local/bin/reindex-search-corpus --full
at> <EOT>
job 15 at Wed Aug 27 14:47:00 2026

$ atq
15	Wed Aug 27 14:47:00 2026 b deploy
```

The job becomes eligible immediately but `atd` will not start it while the 1-minute load average exceeds the threshold (default **1.5**, or 0.8 × number of CPUs in some builds). Change it with `atd -l <loadavg>`:

```console
$ sudo systemctl edit atd.service
### /etc/systemd/system/atd.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/sbin/atd -f -l 6.0 -b 120

$ sudo systemctl daemon-reload && sudo systemctl restart atd
$ ps -o args= -C atd
/usr/sbin/atd -f -l 6.0 -b 120
```

`-b` sets the minimum interval in seconds between starting two batch jobs (default 60), serialising heavy work.

### 5.5 `at` limitations you must design around

- **Not persistent across a missed window in the way you'd hope**: if the machine is off at the target time, `atd` runs the job at its next start — arbitrarily late, with no deadline check.
- **No repetition.** A self-rescheduling `at` job (a job that ends with `at now + 1 hour -f "$0"`) is a known anti-pattern: one failed run silently ends the chain forever.
- **The captured environment can go stale.** A job scheduled three weeks out replays a three-week-old `PATH` and `PWD`.
- **Jobs are plain scripts in the spool.** Anyone who can read the spool reads your command line; never embed secrets.

---

## 6. Access control: `cron.allow` / `cron.deny` / `at.allow` / `at.deny`

The evaluation order is identical for both subsystems and is a certain exam question.

```
                 ┌──────────────────────────────┐
                 │ Does /etc/cron.allow exist?  │
                 └───────────┬──────────────────┘
                     yes     │      no
              ┌──────────────┘      └──────────────┐
              ▼                                    ▼
   User listed in cron.allow?         ┌──────────────────────────────┐
        yes → ALLOW                   │ Does /etc/cron.deny exist?   │
        no  → DENY                    └────────┬─────────────────────┘
   (cron.deny is IGNORED entirely)      yes    │    no
                                  ┌────────────┘    └──────────────┐
                                  ▼                                ▼
                    User listed in cron.deny?        Site-dependent default:
                         yes → DENY                  Debian/Ubuntu → all users allowed
                         no  → ALLOW                 RHEL/cronie   → root only
```

Rules to memorise:

1. **`*.allow` wins.** If it exists, `*.deny` is not consulted at all.
2. **One username per line.** No comments, no groups, no wildcards, no whitespace tolerance.
3. **`root` is normally exempt** for `cron` on most implementations, but on cronie root is subject to `cron.allow` if that file exists — so an `/etc/cron.allow` that omits `root` can lock root out of `crontab -e`. Always include `root`.
4. These files control the **`crontab`/`at` commands**, not the daemon. A crontab already installed in the spool keeps running even after the owner is denied. Removing access ≠ removing scheduled work.
5. `/etc/cron.d` and `/etc/crontab` bypass this entirely — they are root-managed files.

```console
$ sudo tee /etc/cron.allow >/dev/null <<'EOF'
root
deploy
backup
EOF
$ sudo chmod 0600 /etc/cron.allow
$ sudo chown root:root /etc/cron.allow

$ sudo -u www-data crontab -l
You (www-data) are not allowed to use this program (crontab)
See crontab(1) for more information

$ sudo -u deploy crontab -l
SHELL=/bin/bash
...
```

Same mechanics for `at`:

```console
$ sudo sh -c 'echo www-data >> /etc/at.deny'
$ sudo -u www-data at now + 1 minute
You do not have permission to use at.
```

Baseline hardening posture on a fleet node (deny-by-default, allow-list a small set):

```console
$ sudo install -m 0600 -o root -g root /dev/stdin /etc/cron.allow <<'EOF'
root
deploy
EOF
$ sudo install -m 0600 -o root -g root /dev/stdin /etc/at.allow <<'EOF'
root
EOF
$ sudo rm -f /etc/cron.deny /etc/at.deny     # ignored anyway once *.allow exists; remove to avoid confusion
```

Verification, including the "already-installed crontab survives" caveat:

```console
$ for u in $(cut -d: -f1 /etc/passwd); do
>   out=$(sudo crontab -u "$u" -l 2>/dev/null) && [ -n "$out" ] && echo "== $u"
> done
== root
== deploy
== www-data          # ← still scheduled despite being denied. Remove it explicitly.

$ sudo crontab -u www-data -r
```

---

## 7. systemd timers — the supervised alternative

### 7.1 The two-unit model

A timer never contains the command. It activates a **unit** — by default the `.service` with the same stem.

```console
$ sudo tee /etc/systemd/system/registry-prune.service >/dev/null <<'EOF'
[Unit]
Description=Prune container registry blobs older than 30 days
Documentation=https://internal.example.com/runbooks/registry-prune
After=network-online.target
Wants=network-online.target
# Refuse to run if the registry volume is not mounted.
ConditionPathIsMountPoint=/srv/registry

[Service]
Type=oneshot
User=registry
Group=registry

# Deterministic environment — the thing cron never gives you.
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=LANG=C.UTF-8
Environment=REGISTRY_URL=https://registry.example.com
EnvironmentFile=-/etc/default/registry-prune

WorkingDirectory=/srv/registry
ExecStart=/usr/local/bin/registry-prune --older-than 30d --confirm

# Bound the blast radius.
TimeoutStartSec=45min
Restart=on-failure
RestartSec=5min
StartLimitBurst=3

# cgroup resource containment — no cron equivalent exists.
MemoryMax=2G
MemoryHigh=1500M
CPUQuota=150%
IOWeight=20
Nice=10

# Sandboxing.
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ReadWritePaths=/srv/registry
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
LockPersonality=yes
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
CapabilityBoundingSet=

# Structured logging.
StandardOutput=journal
StandardError=journal
SyslogIdentifier=registry-prune

[Install]
WantedBy=multi-user.target
EOF
```

```console
$ sudo tee /etc/systemd/system/registry-prune.timer >/dev/null <<'EOF'
[Unit]
Description=Nightly registry prune
Documentation=https://internal.example.com/runbooks/registry-prune

[Timer]
# Every day at 03:15 local time.
OnCalendar=*-*-* 03:15:00

# Fleet-wide herd control: spread starts across a 40-minute window.
RandomizedDelaySec=40m

# Let systemd coalesce this with nearby timers to save wakeups.
AccuracySec=1min

# If the machine was off at 03:15, run as soon as it is up again.
Persistent=true

# Belt-and-braces overlap guard (the unit being active already blocks re-trigger).
# Fail loudly if the service is somehow still running after 12 hours.
Unit=registry-prune.service

[Install]
WantedBy=timers.target
EOF
```

Companion failure-notification unit — the piece cron structurally cannot provide:

```console
$ sudo tee /etc/systemd/system/notify-failure@.service >/dev/null <<'EOF'
[Unit]
Description=Alert on failure of %i

[Service]
Type=oneshot
ExecStart=/usr/local/bin/alert-webhook \
    --severity critical \
    --unit "%i" \
    --host "%H" \
    --message "systemd unit %i failed on %H"
EOF

$ sudo mkdir -p /etc/systemd/system/registry-prune.service.d
$ sudo tee /etc/systemd/system/registry-prune.service.d/onfailure.conf >/dev/null <<'EOF'
[Unit]
OnFailure=notify-failure@%n.service
EOF
```

Activate and verify:

```console
$ sudo systemd-analyze verify /etc/systemd/system/registry-prune.{service,timer}
$ sudo systemctl daemon-reload
$ sudo systemctl enable --now registry-prune.timer
Created symlink /etc/systemd/system/timers.target.wants/registry-prune.timer → /etc/systemd/system/registry-prune.timer.

$ systemctl list-timers registry-prune.timer
NEXT                        LEFT     LAST                        PASSED  UNIT                  ACTIVATES
Thu 2026-08-28 03:15:00 -03 12h left Wed 2026-08-27 03:15:00 -03 11h ago registry-prune.timer  registry-prune.service

1 timers listed.
```

### 7.2 `OnCalendar` syntax and `systemd-analyze calendar`

Format: `DayOfWeek Year-Month-Day Hour:Minute:Second [Timezone]`

| Expression | Meaning |
|---|---|
| `hourly` | `*-*-* *:00:00` |
| `daily` | `*-*-* 00:00:00` |
| `weekly` | `Mon *-*-* 00:00:00` |
| `monthly` | `*-*-01 00:00:00` |
| `*-*-* 03:15:00` | Daily at 03:15 |
| `Mon..Fri *-*-* 09:00` | Weekdays at 09:00 |
| `*-*-* *:0/15` | Every 15 minutes |
| `*-*-* *:*:0/30` | Every 30 seconds |
| `Mon *-*-1..7 04:00` | First Monday of the month |
| `*-01,04,07,10-01 00:00` | Quarterly |
| `2026-12-31 23:59` | One specific instant |
| `*-*-* 02:00 UTC` | Pinned to UTC, DST-immune |

Always validate before shipping — this is the timer equivalent of `crontab` syntax checking:

```console
$ systemd-analyze calendar --iterations=5 'Mon *-*-1..7 04:00:00'
  Original form: Mon *-*-1..7 04:00:00
Normalized form: Mon *-*-01..07 04:00:00
    Next elapse: Mon 2026-09-07 04:00:00 -03
       (in UTC): Mon 2026-09-07 07:00:00 UTC
       From now: 1 week 3 days left
       Iter. #2: Mon 2026-10-05 04:00:00 -03
       (in UTC): Mon 2026-10-05 07:00:00 UTC
       From now: 1 month 8 days left
       Iter. #3: Mon 2026-11-02 04:00:00 -03
       (in UTC): Mon 2026-11-02 07:00:00 UTC
       From now: 2 months 6 days left
       Iter. #4: Mon 2026-12-07 04:00:00 -03
       (in UTC): Mon 2026-12-07 07:00:00 UTC
       From now: 3 months 10 days left
       Iter. #5: Mon 2026-01-04 04:00:00 -03
       From now: 4 months 8 days left

$ systemd-analyze calendar 'Mon *-*-* 25:00'
Failed to parse calendar expression: Invalid argument
```

Monotonic timers (relative to an event, not the wall clock) — impossible with cron:

```ini
[Timer]
OnBootSec=15min           # 15 min after boot
OnStartupSec=10min        # 10 min after systemd itself started
OnUnitActiveSec=6h        # 6 h after the unit last ACTIVATED  → true "every 6 hours of uptime"
OnUnitInactiveSec=1h      # 1 h after the unit last DEACTIVATED → true "1 h after it finished"
OnActiveSec=30s           # 30 s after the timer itself was activated
```

`OnUnitActiveSec` vs cron's `0 */6 * * *`: cron fires at fixed clock hours regardless of whether the previous run took five hours; `OnUnitActiveSec=6h` measures from the actual last start, which is what "every six hours" almost always means operationally.

### 7.3 `systemd-run` — transient jobs, the `at` replacement

```console
$ sudo systemd-run --on-active=20min --unit=drain-web07 \
>      /usr/local/bin/drain-node --node web-07 --grace 300
Running timer as unit: drain-web07.timer
Will run service as unit: drain-web07.service

$ systemctl list-timers drain-web07.timer
NEXT                        LEFT       LAST PASSED UNIT              ACTIVATES
Wed 2026-08-27 15:09:41 -03 19min left -    -      drain-web07.timer drain-web07.service

$ sudo systemd-run --on-calendar='*-*-* 02:00:00' --unit=nightly-vacuum \
>      --property=MemoryMax=4G --property=Nice=15 \
>      /usr/bin/psql -c 'VACUUM (ANALYZE);'
Running timer as unit: nightly-vacuum.timer
Will run service as unit: nightly-vacuum.service

$ sudo systemctl stop drain-web07.timer          # equivalent of atrm
```

Ad-hoc, resource-capped, one-shot foreground run — useful for testing the exact job body a timer will execute:

```console
$ sudo systemd-run --scope --unit=test-prune -p MemoryMax=512M -p CPUQuota=50% \
>      /usr/local/bin/registry-prune --dry-run
Running scope as unit: test-prune.scope
[dry-run] would delete 1,284 blobs (18.4 GiB)
```

### 7.4 Migrating a crontab line to a timer, mechanically

| crontab | timer |
|---|---|
| `*/10 * * * *` | `OnCalendar=*:0/10` |
| `0 3 * * *` | `OnCalendar=*-*-* 03:00:00` |
| `0 3 * * 1` | `OnCalendar=Mon *-*-* 03:00:00` |
| `0 0 1 * *` | `OnCalendar=*-*-01 00:00:00` |
| `@reboot` | `OnBootSec=1min` (or plain `WantedBy=multi-user.target`, no timer) |
| `MAILTO=x` | `OnFailure=` + a notification unit — and it fires on *failure*, not on output |
| `flock -n /run/lock/x` | nothing needed: an active unit cannot be re-triggered |
| `sleep $((RANDOM % 1800))` | `RandomizedDelaySec=30m` |
| `nice -n 19 ionice -c3 cmd` | `Nice=19`, `IOSchedulingClass=idle` |

---

## 8. Complete infrastructure manifests

### 8.1 Ansible role — idempotent, declarative scheduling

`roles/scheduling/defaults/main.yml`

```yaml
---
# Managed scheduled jobs. Every entry is rendered into /etc/cron.d/ or a
# systemd timer pair depending on `scheduling_backend`.
scheduling_backend: systemd          # systemd | cron

scheduling_cron_allow:
  - root
  - deploy

scheduling_at_allow:
  - root

scheduling_jobs:
  - name: registry-prune
    description: Prune container registry blobs older than 30 days
    user: registry
    group: registry
    command: /usr/local/bin/registry-prune --older-than 30d --confirm
    working_directory: /srv/registry
    cron_schedule: "15 3 * * *"
    calendar: "*-*-* 03:15:00"
    randomized_delay: 40m
    persistent: true
    memory_max: 2G
    cpu_quota: 150%
    nice: 10
    timeout: 45min
    read_write_paths:
      - /srv/registry
    environment:
      REGISTRY_URL: https://registry.example.com

  - name: metrics-textfile
    description: Collect node textfile metrics
    user: node_exp
    group: node_exp
    command: /usr/local/bin/collect-textfile-metrics.sh
    working_directory: /var/lib/node_exporter
    cron_schedule: "*/5 * * * *"
    calendar: "*:0/5"
    randomized_delay: 20s
    persistent: false
    memory_max: 256M
    cpu_quota: 25%
    nice: 19
    timeout: 2min
    read_write_paths:
      - /var/lib/node_exporter/textfile_collector
    environment: {}

  - name: cert-renew
    description: Renew ACME certificates and reload nginx
    user: root
    group: root
    command: /usr/local/sbin/renew-certs --reload nginx
    working_directory: /etc/ssl
    cron_schedule: "42 2,14 * * *"
    calendar: "*-*-* 02,14:42:00"
    randomized_delay: 1h
    persistent: true
    memory_max: 512M
    cpu_quota: 50%
    nice: 0
    timeout: 15min
    read_write_paths:
      - /etc/ssl
      - /var/lib/acme
    environment:
      ACME_DIRECTORY: https://acme-v02.api.letsencrypt.org/directory
```

`roles/scheduling/tasks/main.yml`

```yaml
---
- name: Assert a supported backend was selected
  ansible.builtin.assert:
    that:
      - scheduling_backend in ['systemd', 'cron']
    fail_msg: "scheduling_backend must be 'systemd' or 'cron', got '{{ scheduling_backend }}'"

- name: Install scheduling packages
  ansible.builtin.package:
    name: "{{ scheduling_packages }}"
    state: present
  vars:
    scheduling_packages: >-
      {{ ['cronie', 'at'] if ansible_os_family == 'RedHat'
         else ['cron', 'anacron', 'at'] }}

# ------------------------------------------------------------------ access
- name: Deploy cron access allow-list
  ansible.builtin.copy:
    content: "{{ scheduling_cron_allow | join('\n') }}\n"
    dest: /etc/cron.allow
    owner: root
    group: root
    mode: "0600"

- name: Deploy at access allow-list
  ansible.builtin.copy:
    content: "{{ scheduling_at_allow | join('\n') }}\n"
    dest: /etc/at.allow
    owner: root
    group: root
    mode: "0600"

- name: Remove deny files (ignored when allow-lists exist; removed to avoid ambiguity)
  ansible.builtin.file:
    path: "/etc/{{ item }}"
    state: absent
  loop:
    - cron.deny
    - at.deny

# ------------------------------------------------------------------ cron backend
- name: Deploy cron drop-ins
  ansible.builtin.template:
    src: cron.d.j2
    # Filename MUST match run-parts rules: [A-Za-z0-9_-] only, no extension.
    dest: "/etc/cron.d/{{ item.name | regex_replace('[^A-Za-z0-9_-]', '-') }}"
    owner: root
    group: root
    mode: "0644"
    validate: /bin/sh -c 'test -r %s'
  loop: "{{ scheduling_jobs }}"
  loop_control:
    label: "{{ item.name }}"
  when: scheduling_backend == 'cron'

- name: Remove cron drop-ins when the systemd backend is active
  ansible.builtin.file:
    path: "/etc/cron.d/{{ item.name | regex_replace('[^A-Za-z0-9_-]', '-') }}"
    state: absent
  loop: "{{ scheduling_jobs }}"
  loop_control:
    label: "{{ item.name }}"
  when: scheduling_backend == 'systemd'

# ------------------------------------------------------------------ systemd backend
- name: Deploy failure-notification template unit
  ansible.builtin.copy:
    src: notify-failure@.service
    dest: /etc/systemd/system/notify-failure@.service
    owner: root
    group: root
    mode: "0644"
  notify: systemd daemon-reload
  when: scheduling_backend == 'systemd'

- name: Deploy service units
  ansible.builtin.template:
    src: job.service.j2
    dest: "/etc/systemd/system/{{ item.name }}.service"
    owner: root
    group: root
    mode: "0644"
  loop: "{{ scheduling_jobs }}"
  loop_control:
    label: "{{ item.name }}.service"
  notify: systemd daemon-reload
  when: scheduling_backend == 'systemd'

- name: Deploy timer units
  ansible.builtin.template:
    src: job.timer.j2
    dest: "/etc/systemd/system/{{ item.name }}.timer"
    owner: root
    group: root
    mode: "0644"
  loop: "{{ scheduling_jobs }}"
  loop_control:
    label: "{{ item.name }}.timer"
  notify: systemd daemon-reload
  when: scheduling_backend == 'systemd'

- name: Flush unit handlers before enabling timers
  ansible.builtin.meta: flush_handlers

- name: Validate every deployed unit parses
  ansible.builtin.command:
    argv:
      - systemd-analyze
      - verify
      - "/etc/systemd/system/{{ item.name }}.timer"
  loop: "{{ scheduling_jobs }}"
  loop_control:
    label: "{{ item.name }}"
  changed_when: false
  when: scheduling_backend == 'systemd'

- name: Enable and start timers
  ansible.builtin.systemd_service:
    name: "{{ item.name }}.timer"
    enabled: true
    state: started
  loop: "{{ scheduling_jobs }}"
  loop_control:
    label: "{{ item.name }}.timer"
  when: scheduling_backend == 'systemd'

# ------------------------------------------------------------------ daemons
- name: Ensure the cron daemon is running
  ansible.builtin.systemd_service:
    name: "{{ 'crond' if ansible_os_family == 'RedHat' else 'cron' }}"
    enabled: true
    state: started

- name: Ensure atd is running
  ansible.builtin.systemd_service:
    name: atd
    enabled: true
    state: started
```

`roles/scheduling/templates/cron.d.j2`

```jinja
# {{ item.description }}
# Managed by Ansible ({{ ansible_managed }}). Local edits will be overwritten.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
{% for k, v in (item.environment | default({})).items() %}
{{ k }}={{ v }}
{% endfor %}

# m h dom mon dow user command
{{ item.cron_schedule }} {{ item.user }} cd {{ item.working_directory }} && /usr/bin/flock -n /run/lock/{{ item.name }}.lock /usr/bin/nice -n {{ item.nice }} /usr/bin/timeout {{ item.timeout | replace('min','m') }} {{ item.command }} 2>&1 | /usr/bin/logger -t {{ item.name }}
```

`roles/scheduling/templates/job.service.j2`

```jinja
# {{ ansible_managed }}
[Unit]
Description={{ item.description }}
After=network-online.target
Wants=network-online.target
OnFailure=notify-failure@%n.service

[Service]
Type=oneshot
User={{ item.user }}
Group={{ item.group }}
WorkingDirectory={{ item.working_directory }}

Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=LANG=C.UTF-8
{% for k, v in (item.environment | default({})).items() %}
Environment={{ k }}={{ v }}
{% endfor %}
EnvironmentFile=-/etc/default/{{ item.name }}

ExecStart={{ item.command }}

TimeoutStartSec={{ item.timeout }}
Restart=on-failure
RestartSec=5min
StartLimitBurst=3

MemoryMax={{ item.memory_max }}
CPUQuota={{ item.cpu_quota }}
Nice={{ item.nice }}
IOSchedulingClass=best-effort
IOWeight=20

NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictNamespaces=yes
LockPersonality=yes
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
{% for p in item.read_write_paths | default([]) %}
ReadWritePaths={{ p }}
{% endfor %}

StandardOutput=journal
StandardError=journal
SyslogIdentifier={{ item.name }}

[Install]
WantedBy=multi-user.target
```

`roles/scheduling/templates/job.timer.j2`

```jinja
# {{ ansible_managed }}
[Unit]
Description=Timer for {{ item.description }}

[Timer]
OnCalendar={{ item.calendar }}
RandomizedDelaySec={{ item.randomized_delay }}
AccuracySec=1min
Persistent={{ 'true' if item.persistent else 'false' }}
Unit={{ item.name }}.service

[Install]
WantedBy=timers.target
```

`roles/scheduling/handlers/main.yml`

```yaml
---
- name: systemd daemon-reload
  ansible.builtin.systemd_service:
    daemon_reload: true
```

### 8.2 cloud-init — scheduling baked into first boot

```yaml
#cloud-config
# Provisions a node with a hardened, fully declarative scheduling baseline.

package_update: true
package_upgrade: false
packages:
  - cron
  - anacron
  - at
  - util-linux          # provides flock
  - moreutils           # provides chronic (suppresses output unless the job fails)

users:
  - name: registry
    system: true
    shell: /usr/sbin/nologin
    homedir: /srv/registry

write_files:
  # ---------------------------------------------------------------- access control
  - path: /etc/cron.allow
    owner: root:root
    permissions: "0600"
    content: |
      root
      deploy

  - path: /etc/at.allow
    owner: root:root
    permissions: "0600"
    content: |
      root

  # ---------------------------------------------------------------- anacron tuning
  - path: /etc/anacrontab
    owner: root:root
    permissions: "0600"
    content: |
      SHELL=/bin/sh
      PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
      HOME=/root
      LOGNAME=root

      # Spread fleet-wide daily work over 45 minutes; never start after 22:00.
      RANDOM_DELAY=45
      START_HOURS_RANGE=3-22

      # period  delay  job-id         command
      1         5      cron.daily     nice run-parts --report /etc/cron.daily
      7         25     cron.weekly    nice run-parts --report /etc/cron.weekly
      @monthly  45     cron.monthly   nice run-parts --report /etc/cron.monthly

  # ---------------------------------------------------------------- units
  - path: /etc/systemd/system/registry-prune.service
    owner: root:root
    permissions: "0644"
    content: |
      [Unit]
      Description=Prune container registry blobs older than 30 days
      After=network-online.target
      Wants=network-online.target
      ConditionPathIsMountPoint=/srv/registry
      OnFailure=notify-failure@%n.service

      [Service]
      Type=oneshot
      User=registry
      Group=registry
      WorkingDirectory=/srv/registry
      Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      Environment=LANG=C.UTF-8
      ExecStart=/usr/local/bin/registry-prune --older-than 30d --confirm
      TimeoutStartSec=45min
      Restart=on-failure
      RestartSec=5min
      MemoryMax=2G
      CPUQuota=150%
      Nice=10
      NoNewPrivileges=yes
      PrivateTmp=yes
      ProtectSystem=strict
      ProtectHome=yes
      ReadWritePaths=/srv/registry
      SystemCallFilter=@system-service
      StandardOutput=journal
      StandardError=journal
      SyslogIdentifier=registry-prune

      [Install]
      WantedBy=multi-user.target

  - path: /etc/systemd/system/registry-prune.timer
    owner: root:root
    permissions: "0644"
    content: |
      [Unit]
      Description=Nightly registry prune

      [Timer]
      OnCalendar=*-*-* 03:15:00
      RandomizedDelaySec=40m
      AccuracySec=1min
      Persistent=true

      [Install]
      WantedBy=timers.target

  - path: /etc/systemd/system/notify-failure@.service
    owner: root:root
    permissions: "0644"
    content: |
      [Unit]
      Description=Alert on failure of %i

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/alert-webhook --severity critical --unit "%i" --host "%H"

  # ---------------------------------------------------------------- cron drop-in
  # Filename has no extension on purpose: /etc/cron.d honours run-parts naming
  # ([A-Za-z0-9_-] only) and silently ignores anything else.
  - path: /etc/cron.d/node-exporter-textfile
    owner: root:root
    permissions: "0644"
    content: |
      SHELL=/bin/bash
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      MAILTO=""

      # m  h dom mon dow  user      command
      */5  * *   *   *    node_exp  /usr/bin/flock -n /run/lock/textfile.lock /usr/local/bin/collect-textfile-metrics.sh 2>&1 | /usr/bin/logger -t textfile-metrics

  - path: /etc/logrotate.d/scheduled-jobs
    owner: root:root
    permissions: "0644"
    content: |
      /var/log/scheduled-jobs/*.log {
          daily
          rotate 14
          compress
          delaycompress
          missingok
          notifempty
          create 0640 root adm
          sharedscripts
      }

runcmd:
  - [ install, -d, -m, "0755", -o, root, -g, root, /var/log/scheduled-jobs ]
  - [ install, -d, -m, "0750", -o, registry, -g, registry, /srv/registry ]
  - [ rm, -f, /etc/cron.deny, /etc/at.deny ]
  - [ systemctl, daemon-reload ]
  - [ systemctl, enable, --now, cron.service ]
  - [ systemctl, enable, --now, atd.service ]
  - [ systemctl, enable, --now, registry-prune.timer ]
  # Fail the boot loudly if any unit is malformed.
  - [ systemd-analyze, verify, /etc/systemd/system/registry-prune.timer ]

final_message: "Scheduling baseline provisioned after $UPTIME seconds."
```

### 8.3 Kubernetes `CronJob` — the same problem, one layer up

Included because it makes the trade-off table concrete: every field below exists to fix a cron deficiency listed in §1.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: registry-prune
  namespace: platform
  labels:
    app.kubernetes.io/name: registry-prune
    app.kubernetes.io/component: maintenance
spec:
  # Same five-field cron expression the exam tests.
  schedule: "15 3 * * *"
  # Explicit timezone — the cron equivalent is CRON_TZ= or a UTC-pinned daemon.
  timeZone: "Etc/UTC"
  # Overlap prevention: the `flock` of the cluster world.
  concurrencyPolicy: Forbid
  # Missed-run policy: if the controller was down, only start if <10 min late.
  startingDeadlineSeconds: 600
  suspend: false
  # Observability: keep history instead of discarding exit codes like cron does.
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 2700          # 45 min, mirrors TimeoutStartSec
      ttlSecondsAfterFinished: 86400
      template:
        metadata:
          labels:
            app.kubernetes.io/name: registry-prune
        spec:
          restartPolicy: Never
          serviceAccountName: registry-prune
          securityContext:
            runAsNonRoot: true
            runAsUser: 65534
            runAsGroup: 65534
            fsGroup: 65534
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: prune
              image: registry.example.com/platform/registry-prune:v1.8.3
              imagePullPolicy: IfNotPresent
              args: ["--older-than", "30d", "--confirm"]
              env:
                - name: REGISTRY_URL
                  value: https://registry.example.com
                - name: REGISTRY_TOKEN
                  valueFrom:
                    secretKeyRef:
                      name: registry-prune-credentials
                      key: token
              resources:
                requests:
                  cpu: 100m
                  memory: 256Mi
                limits:
                  cpu: 1500m
                  memory: 2Gi
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              volumeMounts:
                - name: tmp
                  mountPath: /tmp
          volumes:
            - name: tmp
              emptyDir:
                sizeLimit: 512Mi
```

Mapping table:

| Host-level control (107.2) | Kubernetes equivalent |
|---|---|
| `flock -n` | `concurrencyPolicy: Forbid` |
| `Persistent=true` | `startingDeadlineSeconds` (bounded, not unbounded catch-up) |
| `TimeoutStartSec=` | `activeDeadlineSeconds` |
| `Restart=on-failure` + `StartLimitBurst` | `backoffLimit` |
| `MemoryMax=` / `CPUQuota=` | `resources.limits` |
| `ProtectSystem=strict` | `readOnlyRootFilesystem: true` |
| `CapabilityBoundingSet=` | `capabilities.drop: ["ALL"]` |
| `RandomizedDelaySec=` | **no equivalent** — implement jitter in the container entrypoint |
| journald + `OnFailure=` | pod logs + `kube_cronjob_status_last_successful_time` alert |

---

## 9. Production patterns every scheduled job should use

### 9.1 Mutual exclusion with `flock`

```cron
# -n : fail immediately if the lock is held (do not queue up)
# -E 0 : exit 0 when the lock is busy, so the "skipped" case is not an alert
*/10 * * * * /usr/bin/flock -n -E 0 /run/lock/artifact-sync.lock /usr/local/bin/artifact-sync
```

```console
$ flock -n /tmp/demo.lock -c 'sleep 60' &
[1] 20913
$ flock -n /tmp/demo.lock -c 'echo ran'; echo "exit=$?"
exit=1
$ flock -n -E 0 /tmp/demo.lock -c 'echo ran'; echo "exit=$?"
exit=0
```

Use `-w <seconds>` when you want the second instance to wait briefly rather than skip.

### 9.2 Silence success, surface failure

The default cron contract ("mail me all output") produces alert fatigue. Invert it with `chronic` (from `moreutils`), which buffers output and emits it **only** on a non-zero exit:

```cron
MAILTO=sre-oncall@example.com
0 3 * * * /usr/bin/chronic /usr/local/bin/nightly-report
```

Or route to the journal and alert on exit status explicitly:

```cron
MAILTO=""
0 3 * * * /usr/local/bin/nightly-report 2>&1 | /usr/bin/logger -t nightly-report -p cron.info; \
          [ ${PIPESTATUS[0]} -eq 0 ] || /usr/local/bin/alert-webhook --unit nightly-report
```

(`PIPESTATUS` requires `SHELL=/bin/bash` in the crontab.)

### 9.3 Dead-man's-switch monitoring — the only real fix for silent failure

A job that never runs emits nothing, so you cannot alert on its logs. Alert on the **absence** of a success heartbeat:

```bash
#!/bin/bash
# /usr/local/bin/job-wrapper — run a job, emit Prometheus textfile metrics either way.
set -uo pipefail

JOB_NAME="$1"; shift
TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector
OUT="${TEXTFILE_DIR}/job_${JOB_NAME}.prom"
START=$(date +%s)

"$@"
RC=$?

END=$(date +%s)

# Atomic write: node_exporter must never read a half-written file.
cat > "${OUT}.$$" <<EOF
# HELP scheduled_job_last_run_timestamp_seconds Unix time of the last completed run.
# TYPE scheduled_job_last_run_timestamp_seconds gauge
scheduled_job_last_run_timestamp_seconds{job="${JOB_NAME}"} ${END}
# HELP scheduled_job_last_exit_code Exit code of the last run.
# TYPE scheduled_job_last_exit_code gauge
scheduled_job_last_exit_code{job="${JOB_NAME}"} ${RC}
# HELP scheduled_job_duration_seconds Wall-clock duration of the last run.
# TYPE scheduled_job_duration_seconds gauge
scheduled_job_duration_seconds{job="${JOB_NAME}"} $((END - START))
EOF
mv -f "${OUT}.$$" "${OUT}"

exit "$RC"
```

```cron
0 3 * * * /usr/local/bin/job-wrapper registry-prune /usr/local/bin/registry-prune --older-than 30d
```

Corresponding alert rule:

```yaml
groups:
  - name: scheduled-jobs
    rules:
      - alert: ScheduledJobNotRunning
        expr: |
          time() - scheduled_job_last_run_timestamp_seconds > 129600
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Job {{ $labels.job }} has not completed in 36h on {{ $labels.instance }}"

      - alert: ScheduledJobFailing
        expr: scheduled_job_last_exit_code != 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Job {{ $labels.job }} exited {{ $value }} on {{ $labels.instance }}"
```

### 9.4 Timezone and DST discipline

DST is the source of the two ugliest cron bugs:

- **Spring forward** (clocks jump 02:00 → 03:00): a job at `0 2 * * *` — the wall-clock time never occurs. Vixie cron runs jobs scheduled in the skipped interval once, immediately after the jump; jobs with a wildcard hour are not repeated.
- **Fall back** (02:00 occurs twice): a job at `0 2 * * *` — Vixie cron suppresses the second occurrence for fixed-time jobs, but wildcard-hour jobs (`0 * * * *`) do run twice.

Production rules:

1. **Run infrastructure hosts in UTC.** `timedatectl set-timezone UTC`.
2. If local time is mandatory, schedule outside 01:00–04:00.
3. Pin explicitly where the tooling supports it: `CRON_TZ=UTC` (Vixie/cronie), `OnCalendar=*-*-* 03:15:00 UTC` (systemd).
4. Make the job **idempotent**, so a duplicate run is harmless. This is the only defence that always works.

```console
$ timedatectl
               Local time: Wed 2026-08-27 14:52:31 -03
           Universal time: Wed 2026-08-27 17:52:31 UTC
                 RTC time: Wed 2026-08-27 17:52:31
                Time zone: America/Argentina/Buenos_Aires (-03, -0300)
System clock synchronized: yes
              NTP service: active
          RTC in local TZ: no
```

`RTC in local TZ: no` matters: an RTC in local time makes boot-time scheduling non-deterministic across DST transitions.

---

## 10. Verification and failure diagnosis

### 10.1 Layered verification ladder

Run these in order; each rung assumes the previous one passed.

**Rung 1 — is the daemon even running?**

```console
$ systemctl is-active cron.service atd.service          # Debian/Ubuntu
active
active

$ systemctl is-active crond.service atd.service         # RHEL family
active
active

$ pgrep -a cron
612 /usr/sbin/cron -f -P
```

**Rung 2 — is the schedule installed where you think it is?**

```console
$ sudo crontab -l -u deploy
$ cat /etc/crontab
$ ls -la /etc/cron.d/
$ sudo run-parts --test /etc/cron.daily

$ systemctl list-timers --all
NEXT                        LEFT       LAST                        PASSED    UNIT                         ACTIVATES
Wed 2026-08-27 15:00:00 -03 7min left  Wed 2026-08-27 14:00:00 -03 52min ago anacron.timer                anacron.service
Wed 2026-08-27 18:07:12 -03 3h 14min   Wed 2026-08-27 06:07:12 -03 8h ago    apt-daily.timer              apt-daily.service
Thu 2026-08-28 00:00:00 -03 9h left    Wed 2026-08-27 00:00:14 -03 14h ago   logrotate.timer              logrotate.service
Thu 2026-08-28 03:15:00 -03 12h left   Wed 2026-08-27 03:41:22 -03 11h ago   registry-prune.timer         registry-prune.service
-                           -          -                           -         systemd-tmpfiles-clean.timer systemd-tmpfiles-clean.service

5 timers listed.
```

A `NEXT` of `-` means the timer is loaded but will never fire — usually a mistyped `OnCalendar` or a timer that was never `start`ed.

**Rung 3 — full crontab inventory across the machine**

```console
$ sudo sh -c '
  echo "### user crontabs"
  for f in /var/spool/cron/crontabs/* /var/spool/cron/*; do
    [ -f "$f" ] || continue
    echo "--- $f"; grep -Ev "^\s*(#|$)" "$f"
  done
  echo "### /etc/crontab";      grep -Ev "^\s*(#|$)" /etc/crontab
  echo "### /etc/cron.d";       grep -rEv "^\s*(#|$)" /etc/cron.d/ 2>/dev/null
  echo "### run-parts dirs";    ls /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly
  echo "### at queue";          atq
'
```

**Rung 4 — does the schedule mean what you think?**

```console
$ systemd-analyze calendar --iterations=3 '*-*-* 03:15:00'
  Original form: *-*-* 03:15:00
Normalized form: *-*-* 03:15:00
    Next elapse: Thu 2026-08-28 03:15:00 -03
       (in UTC): Thu 2026-08-28 06:15:00 UTC
       From now: 12h left
       Iter. #2: Fri 2026-08-29 03:15:00 -03
       Iter. #3: Sat 2026-08-30 03:15:00 -03
```

For cron expressions, `systemd-analyze calendar` also accepts the classic form after translation, and `crontab -l | crontab -` re-validates syntax non-destructively.

**Rung 5 — did it actually run?**

```console
# Debian / Ubuntu
$ sudo journalctl -u cron.service --since "24 hours ago" --no-pager | tail -20
Aug 27 03:15:01 web-07 CRON[19204]: (deploy) CMD (/usr/local/bin/registry-prune --older-than 30d)
Aug 27 03:15:01 web-07 CRON[19203]: (CRON) info (No MTA installed, discarding output)
Aug 27 03:17:01 web-07 CRON[19288]: (root) CMD (cd / && run-parts --report /etc/cron.hourly)

# RHEL family
$ sudo tail -20 /var/log/cron
Aug 27 03:15:01 web-07 CROND[19204]: (deploy) CMD (/usr/local/bin/registry-prune --older-than 30d)
Aug 27 03:15:01 web-07 CROND[19203]: (deploy) CMDOUT (pruned 1284 blobs)
Aug 27 03:15:02 web-07 CROND[19203]: (deploy) CMDEND (/usr/local/bin/registry-prune --older-than 30d)

# systemd timers — this is where the difference shows
$ journalctl -u registry-prune.service --since today --no-pager
Aug 27 03:41:22 web-07 systemd[1]: Starting registry-prune.service - Prune container registry blobs...
Aug 27 03:41:23 web-07 registry-prune[19311]: scanning 41,882 manifests
Aug 27 03:44:07 web-07 registry-prune[19311]: deleted 1,284 blobs, reclaimed 18.4 GiB
Aug 27 03:44:07 web-07 systemd[1]: registry-prune.service: Deactivated successfully.
Aug 27 03:44:07 web-07 systemd[1]: Finished registry-prune.service - Prune container registry blobs.
Aug 27 03:44:07 web-07 systemd[1]: registry-prune.service: Consumed 2min 41.203s CPU time, 812.4M memory peak.
```

That last line — CPU and memory accounting per invocation — is free with a timer and unobtainable with cron.

```console
$ systemctl show registry-prune.service -p Result -p ExecMainStatus -p ExecMainStartTimestamp -p ExecMainExitTimestamp
Result=success
ExecMainStatus=0
ExecMainStartTimestamp=Wed 2026-08-27 03:41:22 -03
ExecMainExitTimestamp=Wed 2026-08-27 03:44:07 -03
```

**Rung 6 — reproduce the job's actual environment.** This is where 80 % of "works in my shell" incidents resolve.

```cron
# Temporary diagnostic line
* * * * * /usr/bin/env > /tmp/cron-env.txt 2>&1; /usr/bin/id >> /tmp/cron-env.txt
```

```console
$ cat /tmp/cron-env.txt
LANG=en_US.UTF-8
HOME=/home/deploy
LOGNAME=deploy
PATH=/usr/bin:/bin
SHELL=/bin/sh
PWD=/home/deploy
uid=1001(deploy) gid=1001(deploy) groups=1001(deploy)
```

`PATH=/usr/bin:/bin` — no `/usr/local/bin`, no `/sbin`. That single line explains the majority of `command not found` failures.

Then replay it exactly:

```console
$ env -i \
>   HOME=/home/deploy LOGNAME=deploy USER=deploy \
>   PATH=/usr/bin:/bin SHELL=/bin/sh \
>   /bin/sh -c '/usr/local/bin/registry-prune --older-than 30d'
/bin/sh: 1: /usr/local/bin/registry-prune: not found
```

Reproduced. For a systemd unit the equivalent is a one-shot manual start, which uses the real unit environment and sandboxing:

```console
$ sudo systemctl start registry-prune.service
$ systemctl status registry-prune.service --no-pager
× registry-prune.service - Prune container registry blobs older than 30 days
     Loaded: loaded (/etc/systemd/system/registry-prune.service; enabled)
     Active: failed (Result: exit-code) since Wed 2026-08-27 14:58:03 -03; 4s ago
   Duration: 118ms
    Process: 21044 ExecStart=/usr/local/bin/registry-prune --older-than 30d --confirm (code=exited, status=13)
   Main PID: 21044 (code=exited, status=13)
        CPU: 96ms

Aug 27 14:58:03 web-07 registry-prune[21044]: error: cannot write /srv/registry/.lock: Read-only file system
Aug 27 14:58:03 web-07 systemd[1]: registry-prune.service: Main process exited, code=exited, status=13
```

`Read-only file system` under `ProtectSystem=strict` → the fix is a missing `ReadWritePaths=` entry, not a permissions change. Sandbox-induced failures are diagnosable because they name the mechanism.

### 10.2 Failure decision tree

| Symptom | Likely cause | Confirm with | Fix |
|---|---|---|---|
| Nothing in the log at all, ever | Daemon not running / not enabled | `systemctl is-enabled cron` | `systemctl enable --now cron` |
| `/etc/cron.d` file ignored, no error | Filename has a `.` or other illegal char | `run-parts --test /etc/cron.d` | Rename to `[A-Za-z0-9_-]` only |
| `/etc/cron.d` file ignored | Wrong perms/owner, or group-writable | `ls -l /etc/cron.d/` | `chown root:root`, `chmod 0644` |
| `command not found` in mail | Minimal `PATH` | Dump `env` from a cron line | Set `PATH=` in the crontab, or use absolute paths |
| Works as root, fails for the user | Missing sixth field in `/etc/cron.d`, or ran in the wrong crontab type | `head` the file | `/etc/cron.d` and `/etc/crontab` need a user field; user crontabs must not have one |
| Command truncated at a `%` | Unescaped percent | `crontab -l \| cat -A` | Escape as `\%` or move logic into a script |
| Runs on the wrong days | DOM/DOW OR-rule | `systemd-analyze calendar` on the translated expr | Set one field to `*`, test the other in the command |
| Two instances overlapping | No locking | `pgrep -af <job>` | `flock -n` or a systemd timer |
| Runs an hour early/late twice a year | DST | `timedatectl` | UTC host, `CRON_TZ=UTC`, or `OnCalendar=... UTC` |
| Ran at 03:15 yesterday, not today | Machine was off | `journalctl --list-boots` | `Persistent=true`, or anacron |
| Fires at boot in a burst | `Persistent=true` on many timers | `systemctl list-timers` | Add `RandomizedDelaySec=` |
| Job hangs forever, blocks the next | No timeout | `systemctl status` shows long `Duration` | `timeout` in cron, `TimeoutStartSec=` in a unit |
| `You are not allowed to use this program` | `cron.allow` / `cron.deny` | `ls -l /etc/cron.allow /etc/cron.deny` | Add the user to `cron.allow` |
| `crontab -e` opens the wrong editor | `EDITOR`/`VISUAL` unset | `echo $VISUAL $EDITOR` | `export EDITOR=vim`, or `update-alternatives --config editor` |
| `at` job never fires | `atd` not running | `systemctl is-active atd` | `systemctl enable --now atd` |
| `batch` job sits in the queue | Load average above threshold | `uptime`, `ps -o args= -C atd` | Raise with `atd -l` |
| Timer loaded, `NEXT` shows `-` | Invalid `OnCalendar` or timer not started | `systemd-analyze verify`, `systemctl status <t>.timer` | Fix expression, `systemctl start` |
| Unit fails only under the scheduler | Sandboxing (`ProtectSystem`, `PrivateTmp`) | Error names the mechanism | Add `ReadWritePaths=` / relax the specific directive |
| `(CRON) info (No MTA installed, discarding output)` | Output produced, no mailer | `journalctl -u cron` | Install an MTA, or set `MAILTO=""` and log via `logger` |
| Ran, but the outcome is wrong | Wrong `HOME`/`PWD` assumption | Dump `pwd` from a cron line | `cd` explicitly, or `WorkingDirectory=` |

### 10.3 Auditing a machine's full scheduled-work surface

Unreviewed scheduled jobs are a persistence mechanism as well as an operational risk. This inventory is worth running as a compliance check:

```bash
#!/bin/bash
# /usr/local/sbin/audit-scheduled-work
set -uo pipefail
echo "=== Scheduled work inventory: $(hostname -f) $(date -Is) ==="

echo -e "\n--- Daemons"
systemctl is-active cron crond atd 2>/dev/null | paste -d' ' <(echo -e "cron\ncrond\natd") -

echo -e "\n--- Per-user crontabs"
for d in /var/spool/cron/crontabs /var/spool/cron; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    echo "[$(basename "$f")] owner=$(stat -c '%U:%G %a' "$f")"
    grep -Ev '^\s*(#|$)' "$f" | sed 's/^/    /'
  done
done

echo -e "\n--- /etc/crontab"
grep -Ev '^\s*(#|$)' /etc/crontab 2>/dev/null | sed 's/^/    /'

echo -e "\n--- /etc/cron.d (flagging names run-parts will reject)"
for f in /etc/cron.d/*; do
  [ -f "$f" ] || continue
  b=$(basename "$f")
  case "$b" in
    *[!A-Za-z0-9_-]*) echo "    !! IGNORED BY CRON (illegal filename): $b" ;;
    *) echo "[$b] $(stat -c '%U:%G %a' "$f")"
       grep -Ev '^\s*(#|$)' "$f" | sed 's/^/    /' ;;
  esac
done

echo -e "\n--- run-parts directories"
for d in hourly daily weekly monthly; do
  echo "[cron.$d]"; run-parts --test "/etc/cron.$d" 2>/dev/null | sed 's/^/    /'
done

echo -e "\n--- anacron"
grep -Ev '^\s*(#|$)' /etc/anacrontab 2>/dev/null | sed 's/^/    /'
ls -l /var/spool/anacron/ 2>/dev/null | sed 's/^/    /'

echo -e "\n--- at queue (all users)"
atq 2>/dev/null | sed 's/^/    /'

echo -e "\n--- systemd timers"
systemctl list-timers --all --no-pager | sed 's/^/    /'

echo -e "\n--- Access control"
for f in /etc/cron.allow /etc/cron.deny /etc/at.allow /etc/at.deny; do
  if [ -e "$f" ]; then echo "[$f] $(stat -c '%U:%G %a' "$f")"; sed 's/^/    /' "$f"
  else echo "[$f] absent"; fi
done
```

```console
$ sudo /usr/local/sbin/audit-scheduled-work | head -40
=== Scheduled work inventory: web-07.example.com 2026-08-27T15:01:44-03:00 ===

--- Daemons
cron active
crond inactive
atd active

--- Per-user crontabs
[deploy] owner=deploy:crontab 600
    SHELL=/bin/bash
    PATH=/usr/local/bin:/usr/bin:/bin
    MAILTO=sre-oncall@example.com
    */10 * * * * /usr/bin/flock -n /run/lock/artifact-sync.lock /usr/local/bin/artifact-sync
    17 4 * * * /usr/local/bin/prune-registry --older-than 30d

--- /etc/crontab
    SHELL=/bin/sh
    PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
    17 * * * * root cd / && run-parts --report /etc/cron.hourly

--- /etc/cron.d (flagging names run-parts will reject)
    !! IGNORED BY CRON (illegal filename): backup.sh
[node-exporter-textfile] root:root 644
    SHELL=/bin/bash
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    MAILTO=""
    */5 * * * * node_exp /usr/bin/flock -n /run/lock/textfile.lock /usr/local/bin/collect-textfile-metrics.sh
```

That `!! IGNORED BY CRON` line is a real class of incident: someone dropped `backup.sh` into `/etc/cron.d`, `ls` shows it, and it has never once executed.

---

## 11. Exam-focused summary

### 11.1 File locations by distribution family

| Purpose | Debian/Ubuntu | RHEL/Fedora/SUSE |
|---|---|---|
| User crontab spool | `/var/spool/cron/crontabs/<user>` | `/var/spool/cron/<user>` |
| System crontab | `/etc/crontab` | `/etc/crontab` |
| Drop-in directory | `/etc/cron.d/` | `/etc/cron.d/` |
| Periodic dirs | `/etc/cron.{hourly,daily,weekly,monthly}` | same |
| anacron config | `/etc/anacrontab` | `/etc/anacrontab` |
| anacron stamps | `/var/spool/anacron/` | `/var/spool/anacron/` |
| `at` spool | `/var/spool/cron/atjobs/` | `/var/spool/at/` |
| Cron log | `/var/log/syslog`, `journalctl -u cron` | `/var/log/cron`, `journalctl -u crond` |
| Service name | `cron.service` | `crond.service` |
| Daemon defaults | `/etc/default/cron` | `/etc/sysconfig/crond` |
| Package | `cron`, `anacron`, `at` | `cronie`, `cronie-anacron`, `at` |

### 11.2 Command reference

| Command | Purpose |
|---|---|
| `crontab -e` / `-l` / `-r` / `-i -r` | Edit / list / remove / remove-with-confirmation |
| `crontab -u <user> ...` | Operate on another user's crontab (root) |
| `crontab <file>` / `crontab -` | Replace crontab from file / stdin (the automatable form) |
| `at <time>` | Schedule a one-shot job |
| `at -f <file> <time>` | Schedule from a script file |
| `at -c <jobid>` | Print the job's full script, environment included |
| `at -l` / `atq` | List pending jobs |
| `at -d <id>` / `atrm <id>` | Delete a pending job |
| `at -m` / `at -M` | Force mail / suppress mail |
| `at -q <letter>` | Select queue (affects nice level) |
| `batch` | Run when load average drops below the threshold |
| `anacron -T` | Validate `/etc/anacrontab` |
| `anacron -n -d <job>` | Run now, foreground, ignore delays |
| `anacron -u` | Update timestamps without running |
| `anacron -f` | Force all jobs regardless of timestamps |
| `anacron -s` | Serialise jobs |
| `run-parts --test <dir>` | Show which scripts *would* run |
| `run-parts --report <dir>` | Run, prefixing output with the script name |
| `systemctl list-timers [--all]` | Show timers, last and next elapse |
| `systemctl enable --now <x>.timer` | Enable and start a timer |
| `systemctl cat <unit>` | Show effective unit content including drop-ins |
| `systemd-analyze calendar '<expr>'` | Validate and preview an `OnCalendar` expression |
| `systemd-analyze verify <unit>` | Static unit validation |
| `systemd-run --on-active=<t> <cmd>` | Transient one-shot job (the `at` analogue) |
| `systemd-run --on-calendar='<expr>' <cmd>` | Transient recurring timer |
| `journalctl -u <unit>` | Structured logs for a scheduled unit |

### 11.3 The nine facts most likely to be tested

1. `/etc/crontab` and `/etc/cron.d/*` have a **user field**; user crontabs do **not**.
2. Field order is **minute hour day-of-month month day-of-week**; DOW `0` and `7` are both Sunday.
3. When **both** DOM and DOW are restricted, the job runs when **either** matches (OR, not AND).
4. If `cron.allow` exists, `cron.deny` is **ignored entirely**.
5. If neither file exists, the default is **site-dependent** — commonly "all users" on Debian, "root only" on RHEL.
6. `%` in a crontab command becomes a **newline**; text after the first `%` becomes **stdin**. Escape with `\%`.
7. cron mails **output**, not failures; the **exit status is discarded**.
8. anacron measures **days elapsed**, has a minimum period of **one day**, runs everything as **root**, and writes its timestamps to `/var/spool/anacron/`.
9. `run-parts` requires the **executable bit** and a filename made only of `[A-Za-z0-9_-]` — a `.sh` extension means the script is silently skipped.

---

## 12. References

**LPI official**

- LPIC-1 Exam 101-500 Objectives — https://www.lpi.org/our-certifications/exam-101-objectives/
- LPIC-1 Exam 102-500 Objectives (Topic 107.2 lives here) — https://www.lpi.org/our-certifications/exam-102-objectives/
- LPIC-1 Certification Overview — https://www.lpi.org/our-certifications/lpic-1-overview/
- LPI Learning Materials, LPIC-1 102 — https://learning.lpi.org/en/learning-materials/102-500/

**cron, anacron, at — upstream projects and manual pages**

- `cronie` project (RHEL/Fedora/Arch/openSUSE cron) — https://github.com/cronie-crond/cronie
- `crontab(5)` — https://man7.org/linux/man-pages/man5/crontab.5.html
- `crontab(1)` — https://man7.org/linux/man-pages/man1/crontab.1.html
- `cron(8)` — https://man7.org/linux/man-pages/man8/cron.8.html
- `anacron(8)` — https://man7.org/linux/man-pages/man8/anacron.8.html
- `anacrontab(5)` — https://man7.org/linux/man-pages/man5/anacrontab.5.html
- `at(1)` (includes `batch`, `atq`, `atrm`) — https://man7.org/linux/man-pages/man1/at.1.html
- `atd(8)` — https://man7.org/linux/man-pages/man8/atd.8.html
- `at` upstream (`at` / `atd`, Debian-maintained) — https://salsa.debian.org/debian/at
- `run-parts(8)` — https://manpages.debian.org/stable/debianutils/run-parts.8.en.html
- `flock(1)` (util-linux) — https://man7.org/linux/man-pages/man1/flock.1.html
- util-linux project — https://github.com/util-linux/util-linux

**systemd**

- systemd project — https://systemd.io/
- `systemd.timer(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html
- `systemd.time(7)` (calendar-event grammar) — https://www.freedesktop.org/software/systemd/man/latest/systemd.time.html
- `systemd.service(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html
- `systemd.exec(5)` (sandboxing directives) — https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- `systemd.resource-control(5)` (cgroup limits) — https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html
- `systemd-run(1)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html
- `systemd-analyze(1)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html
- `timedatectl(1)` — https://www.freedesktop.org/software/systemd/man/latest/timedatectl.html
- `journalctl(1)` — https://www.freedesktop.org/software/systemd/man/latest/journalctl.html

**Distribution documentation**

- Debian Administrator's Handbook, Scheduling Tasks — https://debian-handbook.info/browse/stable/sect.task-scheduling-cron-atd.html
- Red Hat Enterprise Linux 9, Automating system tasks — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/automating_system_administration_by_using_rhel_system_roles/index
- Ubuntu Server Documentation — https://documentation.ubuntu.com/server/
- openSUSE, `cron` and `systemd` timers — https://doc.opensuse.org/documentation/leap/reference/html/book-reference/cha-tuning-cron.html
- Arch Wiki, systemd/Timers — https://wiki.archlinux.org/title/Systemd/Timers
- Arch Wiki, cron — https://wiki.archlinux.org/title/Cron

**Infrastructure-as-code and orchestration**

- Ansible `ansible.builtin.cron` module — https://docs.ansible.com/ansible/latest/collections/ansible/builtin/cron_module.html
- Ansible `ansible.builtin.systemd_service` module — https://docs.ansible.com/ansible/latest/collections/ansible/builtin/systemd_service_module.html
- cloud-init documentation — https://cloudinit.readthedocs.io/en/latest/
- Kubernetes CronJob — https://kubernetes.io/docs/concepts/workloads/controllers/cron-job/
- Kubernetes CronJob API reference (`batch/v1`) — https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/cron-job-v1/
- Prometheus node_exporter textfile collector — https://github.com/prometheus/node_exporter#textfile-collector
- Google SRE Workbook, *Distributed Periodic Scheduling with Cron* — https://sre.google/sre-book/distributed-periodic-scheduling/

**Standards**

- POSIX.1-2024 `crontab` utility — https://pubs.opengroup.org/onlinepubs/9799919799/utilities/crontab.html
- POSIX.1-2024 `at` utility — https://pubs.opengroup.org/onlinepubs/9799919799/utilities/at.html
- IANA Time Zone Database — https://www.iana.org/time-zones