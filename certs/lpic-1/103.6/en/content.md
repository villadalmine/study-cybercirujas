# 103.6 — Modify Process Execution Priorities

**LPIC-1 · Exam 101-500 · Version 5.0 · Weight: 3.12**

---

## 1. Motivation: the architectural problem

You operate a fleet of 40-core bare-metal nodes serving a latency-critical gRPC API. At 02:00 a nightly indexer starts on the same nodes. p99 latency goes from 12 ms to 480 ms. The on-call runbook says: *"run the indexer with `nice -n 19`."* Someone does. **Nothing changes.**

This is the single most common failure in this topic, and it is not a bug — it is three layers of the Linux scheduler interacting:

```
                  ┌─────────────────────────────────────┐
   cgroup v2      │  /sys/fs/cgroup/system.slice        │  cpu.weight = 100
   (cpu ctrl)     │    ├── api.service      cpu.weight  │  = 10000
                  │    └── indexer.service  cpu.weight  │  = 1
                  └─────────────────────────────────────┘
                                  │  proportional split happens HERE first
                                  ▼
                  ┌─────────────────────────────────────┐
   autogroup      │  /proc/<pid>/autogroup (per setsid) │  nice applies to the GROUP
                  └─────────────────────────────────────┘
                                  │
                                  ▼
                  ┌─────────────────────────────────────┐
   task nice      │  se.load.weight from nice(-20..19)  │  applies only among SIBLINGS
                  └─────────────────────────────────────┘
```

A `nice` value is **not** a global statement about a process's importance. It is a *weight relative to the other runnable tasks inside the same scheduling entity*. If the indexer lives in its own cgroup, its `nice` value competes only against itself. If it lives in its own autogroup (its own `setsid` session — which is what every `systemd` service and every SSH login gets), the same is true.

The production-grade mental model you must leave this section with:

| Question | Correct instrument |
|---|---|
| "Make this process yield to *its siblings*." | `nice` / `renice` |
| "Make this *service* yield to another service." | cgroup v2 `cpu.weight` (systemd `CPUWeight=`) |
| "Cap this workload at N cores regardless of idle capacity." | cgroup v2 `cpu.max` (systemd `CPUQuota=`) |
| "This task must run within a bounded latency, always." | `SCHED_FIFO`/`SCHED_RR`/`SCHED_DEADLINE` via `chrt` |
| "This task should run only when the CPU is otherwise idle." | `SCHED_IDLE` (`chrt -i`) or cgroup `cpu.idle` |
| "This batch job is destroying my disk latency." | `ionice` **only on BFQ**, otherwise cgroup `io.latency`/`io.max` |
| "Which pod gets killed / scheduled first?" | Kubernetes `PriorityClass` + `oom_score_adj` — **not** nice |

The exam tests `nice`, `renice`, `ps` and `top`. Production tests whether you know that those four tools address only the bottom layer of the diagram above.

---

## 2. The priority number line

Linux exposes at least four different numeric scales for "priority", three of which are inverted relative to each other. Getting these straight is the whole topic.

### 2.1 The scales

| Scale | Range | Direction | Where you see it |
|---|---|---|---|
| **nice value** (user-facing) | `-20` … `19` | lower = **more** CPU | `nice`, `renice`, `NI` column, `/proc/<pid>/stat` field 19 |
| **kernel nice** (internal) | `0` … `39` | lower = more CPU | `/proc/<pid>/stat` field 18, `top`'s `PR` |
| **kernel `prio`** | `0` … `139` | lower = more CPU | `/proc/<pid>/sched` (`prio`), `100 + 20 + nice` for normal tasks |
| **RT static priority** | `1` … `99` | **higher = more CPU** | `chrt`, `RTPRIO` column |
| **`ps` `PRI`** | build-dependent | see warning below | `ps -l` |

The conversions for a `SCHED_OTHER` task:

```
nice          = -20   -10     0     5    10    19
kernel nice   =   0    10    20    25    30    39     (= 20 + nice)   → top's PR
kernel prio   = 100   110   120   125   130   139     (= 120 + nice)  → /proc/<pid>/sched
ps -l PRI     =  60    70    80    85    90    99     (= 80 + nice)
```

For a real-time task, `/proc/<pid>/stat` field 18 becomes `-1 - rt_priority` (so `rtprio 50` → `-51`), which is why `top` renders `PR` as `-51` for it.

> **⚠️ Never script against `PRI`.** `procps-ng` ships **six** historical renderings of the priority column (`pri`, `opri`, `pri_foo`, `pri_bar`, `pri_baz`, `priority`), selected by which format flag you used. `ps -l` and `ps -o pri` can legitimately print different numbers for the same process on the same machine. The only fields with stable, documented semantics are **`ni`**, **`cls`** and **`rtprio`**. Every automation you write must use those.

### 2.2 What a nice value actually buys you

`nice` is not a percentage and not a slice length. It is an index into the kernel's weight table (`kernel/sched/core.c`, `sched_prio_to_weight[]`). Each nice level is worth **≈1.25×**:

| nice | weight | nice | weight | nice | weight | nice | weight |
|---:|---:|---:|---:|---:|---:|---:|---:|
| -20 | 88761 | -10 | 9548 | 0 | **1024** | 10 | 110 |
| -19 | 71755 | -9 | 7620 | 1 | 820 | 11 | 87 |
| -18 | 56483 | -8 | 6100 | 2 | 655 | 12 | 70 |
| -17 | 46273 | -7 | 4904 | 3 | 526 | 13 | 56 |
| -16 | 36291 | -6 | 3906 | 4 | 423 | 14 | 45 |
| -15 | 29154 | -5 | 3121 | 5 | 335 | 15 | 36 |
| -14 | 23254 | -4 | 2501 | 6 | 272 | 16 | 29 |
| -13 | 18705 | -3 | 1991 | 7 | 215 | 17 | 23 |
| -12 | 14949 | -2 | 1586 | 8 | 172 | 18 | 18 |
| -11 | 11916 | -1 | 1277 | 9 | 137 | 19 | **15** |

CPU share for a set of *continuously runnable* tasks on the same runqueue:

```
share(i) = weight(i) / Σ weight(j)
```

Two CPU-bound tasks pinned to one core:

| Task A nice | Task B nice | A share | B share | Ratio |
|---:|---:|---:|---:|---:|
| 0 | 0 | 50.0 % | 50.0 % | 1.0× |
| 0 | 5 | 75.3 % | 24.7 % | 3.1× |
| 0 | 10 | 90.3 % | 9.7 % | 9.3× |
| 0 | 19 | 98.6 % | 1.4 % | 68.3× |
| -5 | 5 | 90.3 % | 9.7 % | 9.3× |
| -20 | 19 | 99.98 % | 0.02 % | 5917× |

Two consequences that matter in production:

1. **`nice 19` is not `SCHED_IDLE`.** A nice-19 task still gets ~1.4 % of a busy CPU, and — critically — it is still *eligible* to preempt and to hold locks. `SCHED_IDLE` has weight 3 and is scheduled only when nothing else is runnable.
2. **Only the ratio matters.** `nice 0` vs `nice 5` and `nice -5` vs `nice 0`... wait — `nice -5` (3121) vs `nice 5` (335) is 9.3×, identical to `nice 0` vs `nice 10`. Shifting both by the same amount is a no-op. Teams that "renice everything to -5" have accomplished nothing except burning `CAP_SYS_NICE`.

### 2.3 CFS, EEVDF and where nice went

Since **Linux 6.6** the default scheduling class is **EEVDF** (Earliest Eligible Virtual Deadline First), replacing the classic CFS vruntime-ordering. The nice → weight table is unchanged, but nice now influences two things instead of one:

| Property | CFS (< 6.6) | EEVDF (≥ 6.6) |
|---|---|---|
| Proportional share | `weight / Σweight` via vruntime scaling | same weights, tracked as *lag* |
| Latency / preemption | indirect; `sched_min_granularity_ns` | virtual deadline `vd = ve + slice/weight` — higher weight ⇒ earlier deadline ⇒ better wakeup latency |
| Per-task latency hint | none | `sched_attr.sched_runtime` via `sched_setattr(2)` |

Practical upshot: on ≥ 6.6, a negative nice value improves *wakeup latency* as well as throughput share, which makes it a slightly better tool for interactive daemons than it used to be. It still does **not** cross cgroup or autogroup boundaries.

---

## 3. `nice` and `renice`: mechanics and traps

### 3.1 `nice(1)` — set at exec time

```
nice [-n ADJUSTMENT] [COMMAND [ARG]...]
```

Key semantics, all of which appear on the exam and all of which bite in production:

| Behaviour | Detail |
|---|---|
| Default adjustment | **10**, not 0. Bare `nice make -j64` runs at nice 10. |
| `-n` is an **adjustment**, not an absolute | It is added to the caller's current nice value. `nice -n 5 nice -n 5 cmd` → nice **10**. |
| Obsolete syntax | `nice -5 cmd` means adjustment **+5**, not −5. To go negative you *must* write `nice -n -5 cmd`. |
| No arguments | Prints the shell's current nice value and exits. |
| Clamping | Results outside `[-20, 19]` are clamped silently, not rejected. |
| Failure is **non-fatal** | If the adjustment is denied, GNU `nice` prints a warning **and runs the command anyway**. |
| Inheritance | The nice value survives `fork(2)` and is preserved across `execve(2)`. |

```console
$ nice
0

$ nice -n 12 nice
12

$ nice -n 5 nice -n 5 nice
10

$ nice -5 nice          # obsolete syntax: this is +5, NOT -5
5

$ nice -n -5 sleep 1
nice: cannot set niceness: Permission denied
$ echo $?
0
```

That exit status of `0` is the trap. A deployment script that does:

```bash
nice -n -5 /usr/local/bin/latency-sensitive-daemon &
```

runs the daemon at nice 0 forever, exits clean, and passes CI. **Always verify after setting, never trust the exit status of `nice`.**

### 3.2 `renice(1)` — change a running process

```
renice [-n] PRIORITY [-p PID...] [-g PGID...] [-u USER...]
```

| Behaviour | Detail |
|---|---|
| The value is **absolute** on util-linux | `renice -n 5 -p 1234` sets nice **to** 5, it does not add 5. This is the opposite of `nice(1)` and of the historical BSD/POSIX `renice`. |
| Targets | `-p` PID (default), `-g` process group, `-u` user/UID. |
| Unprivileged users | May only **raise** the nice value (make it less favourable), and only for processes they own — one-way ratchet. |
| Per-thread | On Linux `setpriority(2)` is a **per-thread** attribute despite POSIX. `renice -p <PID>` changes only the thread whose TID equals the PID — i.e. the main thread. |

The per-thread behaviour is the second big production surprise. A JVM or a Go binary with 200 OS threads is essentially unaffected by `renice -p`:

```console
$ ps -o pid,ni,comm -p 4412
    PID  NI COMMAND
   4412   0 indexer

$ sudo renice -n 19 -p 4412
4412 (process ID) old priority 0, new priority 19

$ ps -L -o pid,tid,ni,comm -p 4412 | head -6
    PID     TID  NI COMMAND
   4412    4412  19 indexer
   4412    4413   0 indexer
   4412    4414   0 indexer
   4412    4415   0 indexer
   4412    4416   0 indexer
```

One thread was reniced. The other 199 still run at nice 0. The correct incantation:

```console
$ for t in /proc/4412/task/*; do sudo renice -n 19 -p "${t##*/}" >/dev/null; done
$ ps -L -o tid,ni -p 4412 | awk 'NR>1 {c[$2]++} END {for (n in c) print "nice="n, c[n]" threads"}'
nice=19 200 threads
```

Or, far better, put the workload in a cgroup and stop chasing threads (§6).

### 3.3 Who may go negative: `RLIMIT_NICE` and `CAP_SYS_NICE`

Lowering a nice value below the current one requires either:

* **`CAP_SYS_NICE`** (root, or a file capability, or `AmbientCapabilities=`/`CapabilityBoundingSet=` in a unit), **or**
* headroom in **`RLIMIT_NICE`**.

`RLIMIT_NICE` is stored inverted. The floor a process may reach is:

```
nice_floor = 20 - RLIMIT_NICE
```

Default `RLIMIT_NICE` is `0`, giving a floor of nice 20 — i.e. clamped to the current value, no lowering at all.

```console
$ ulimit -e
0

$ prlimit --pid $$ --nice
RESOURCE DESCRIPTION                     SOFT HARD UNITS
NICE     max nice prio allowed to raise     0    0
```

Grant a group the ability to reach nice −10 (the classic low-latency-audio / trading-engine pattern) via PAM limits:

```ini
# /etc/security/limits.d/20-lowlatency.conf
# Format: <domain> <type> <item> <value>
# RLIMIT_NICE is inverted: value 30 => floor of nice (20 - 30) = -10
@lowlat   soft   nice        30
@lowlat   hard   nice        30
# Companion RT budget, capped so a runaway FIFO task cannot wedge the box.
@lowlat   soft   rtprio      50
@lowlat   hard   rtprio      50
@lowlat   -      memlock     unlimited
```

```console
$ sudo -u alice -i ulimit -e
30
$ sudo -u alice nice -n -10 nice
-10
```

> `pam_limits` is not applied to systemd services. For units, use `LimitNICE=` / `LimitRTPRIO=` in the unit file — see §7.

### 3.4 Reading the current state

```console
$ ps -eo pid,ni,cls,rtprio,pri,psr,comm --sort=ni | head -8
    PID  NI CLS RTPRIO PRI PSR COMMAND
   1189 -10  TS      -  90   6 pipewire
    987  -5  TS      -  85   2 sshd
      1   0  TS      -  80   0 systemd
   4412  19  TS      -  99  11 indexer
   2201   - FF      50   9   3 irq/24-nvme0
   2318   - RR      10  49   1 xdp-poller
   3390   - IDL      -  79   8 backup-rsync
```

| `CLS` | Policy | Constant |
|---|---|---|
| `TS` | `SCHED_OTHER` (time sharing) | 0 |
| `FF` | `SCHED_FIFO` | 1 |
| `RR` | `SCHED_RR` | 2 |
| `B` | `SCHED_BATCH` | 3 |
| `IDL` | `SCHED_IDLE` | 5 |
| `DLN` | `SCHED_DEADLINE` | 6 |

In `top`, press **`f`** to add fields, then sort. The relevant columns are `PR` (kernel nice, or `-1-rtprio` for RT), `NI` (user-facing nice) and `S`. Renicing interactively is **`r`**; changing sort field is **`x`**/**`<`**/**`>`**.

```console
$ top -b -n 1 -o %CPU | head -12
top - 02:14:31 up 41 days,  3:07,  2 users,  load average: 39.12, 38.44, 31.09
Tasks: 612 total,   3 running, 609 sleeping,   0 stopped,   0 zombie
%Cpu(s): 94.1 us,  4.2 sy,  0.0 ni,  1.1 id,  0.0 wa,  0.4 hi,  0.2 si,  0.0 st
MiB Mem :  128721.4 total,   9812.2 free,  71204.8 used,  47704.4 buff/cache

    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
   4412 indexer   39  19   8.1g   2.4g  18244 R  1580   1.9   3:11.42 indexer
   2210 api       20   0  12.4g   6.1g  31002 S   412   4.8 918:02.11 api-server
   2201 root     -51   -   0.0m   0.0m      0 S   3.1   0.0  41:19.07 irq/24-nvme0
```

Read that third line carefully: **`0.0 ni`**. The `ni` field in the `%Cpu(s)` summary is the fraction of CPU spent on *positively niced* user tasks. It reads `0.0` while a nice-19 process burns 1580 % CPU — because `top`'s `ni` accounting bucket only counts tasks with nice > 0 **as sampled at tick boundaries**, and more importantly because in this run the indexer is in its own cgroup, so… no. The real reason here is the autogroup, and that is exactly the bug from §1. Let's prove it.

---

## 4. Why your `nice` did nothing: autogroups

**Autogrouping** (`CONFIG_SCHED_AUTOGROUP`, on by default in every mainstream distro) automatically places every task created by `setsid(2)` — every SSH session, every terminal, every `systemd` service — into its own scheduling group. The scheduler then splits CPU **between autogroups first**, and only then applies per-task nice values *within* each group.

```console
$ cat /proc/sys/kernel/sched_autogroup_enabled
1

$ cat /proc/self/autogroup
/autogroup-431 nice 0
```

The demonstration. Two identical CPU hogs, pinned to the same core so the arithmetic is visible:

```console
$ taskset -c 7 sh -c 'while :; do :; done' &
[1] 8801
$ taskset -c 7 nice -n 19 sh -c 'while :; do :; done' &
[2] 8802

$ pidstat -p 8801,8802 2 1
Linux 6.11.0-19-generic (node-07)   08/26/26   _x86_64_   (40 CPU)

02:19:44      UID       PID    %usr %system  %guest   %wait    %CPU   CPU  Command
02:19:46     1000      8801   98.51    0.00    0.00    1.49   98.51     7  sh
02:19:46     1000      8802    1.49    0.00    0.00   98.02    1.49     7  sh
```

That worked — 98.5 / 1.5, exactly the 1024:15 ratio predicted by the weight table. It worked because **both hogs are in the same shell session, hence the same autogroup**.

Now run the low-priority hog from a *second* SSH session (a different `setsid`):

```console
# session A
$ taskset -c 7 sh -c 'while :; do :; done' &
[1] 8901

# session B
$ taskset -c 7 nice -n 19 sh -c 'while :; do :; done' &
[1] 8902

# session A
$ pidstat -p 8901,8902 2 1
02:23:10     1000      8901   50.25    0.00    0.00   49.75   50.25     7  sh
02:23:10     1000      8902   49.75    0.00    0.00   50.25   49.75     7  sh
```

**50/50.** The nice-19 task is the only member of its autogroup, so it gets 100 % of its group's share, and the two groups have equal weight. This is the exact production incident from §1.

Two correct fixes:

```console
# (a) Nice the whole autogroup — value written to /proc/<pid>/autogroup
$ echo 19 | sudo tee /proc/8902/autogroup
19
$ cat /proc/8902/autogroup
/autogroup-512 nice 19

$ pidstat -p 8901,8902 2 1
02:25:02     1000      8901   98.51    0.00    0.00    1.49   98.51     7  sh
02:25:02     1000      8902    1.49    0.00    0.00   98.51    1.49     7  sh
```

```console
# (b) Disable autogrouping node-wide (do this only if you manage CPU via cgroups)
$ echo 'kernel.sched_autogroup_enabled = 0' | sudo tee /etc/sysctl.d/90-sched.conf
kernel.sched_autogroup_enabled = 0
$ sudo sysctl --system | grep autogroup
kernel.sched_autogroup_enabled = 0
```

> **Diagnostic rule:** before concluding "nice doesn't work", always check `cat /proc/<pid>/autogroup` for *both* the victim and the offender. If the group names differ, the nice values are not being compared to each other.

---

## 5. Scheduling policies: `chrt`

`nice` only exists inside `SCHED_OTHER`. For workloads with a latency contract, the policy itself is the knob.

### 5.1 Policy comparison

| Policy | `chrt` flag | Static prio | Preempts `OTHER`? | Semantics | Production use |
|---|---|---|---|---|---|
| `SCHED_OTHER` | `-o` | 0 (nice −20..19) | — | EEVDF/CFS proportional share | everything by default |
| `SCHED_BATCH` | `-b` | 0 (nice applies) | no | like `OTHER` but assumed non-interactive; wakeup preemption suppressed, longer effective slices | compilers, encoders, ETL — better throughput, worse latency |
| `SCHED_IDLE` | `-i` | 0 (nice ignored) | no | weight 3; runs only when nothing else is runnable | `updatedb`, backups, scrubbers |
| `SCHED_RR` | `-r` | 1–99 | **yes** | round-robin within a priority level, quantum = `sched_rr_timeslice_ms` | packet pollers, audio, motion control |
| `SCHED_FIFO` | `-f` | 1–99 | **yes** | runs until it blocks or yields — no quantum | IRQ threads, hard-RT loops |
| `SCHED_DEADLINE` | `-d` | n/a (EDF) | **yes, above FIFO** | CBS: (runtime, deadline, period) with admission control | periodic sensor/control loops |

Ordering: `DEADLINE` > `FIFO`/`RR` (by static prio, high wins) > `OTHER`/`BATCH` > `IDLE`.

### 5.2 Usage

```console
$ chrt -m
SCHED_OTHER min/max priority        : 0/0
SCHED_FIFO min/max priority         : 1/99
SCHED_RR min/max priority           : 1/99
SCHED_BATCH min/max priority        : 0/0
SCHED_IDLE min/max priority         : 0/0
SCHED_DEADLINE min/max priority     : 0/0

$ chrt -p 2210
pid 2210's current scheduling policy: SCHED_OTHER
pid 2210's current scheduling priority: 0

$ sudo chrt -f -p 50 2318
$ chrt -p 2318
pid 2318's current scheduling policy: SCHED_FIFO
pid 2318's current scheduling priority: 50

# Launch directly under a policy
$ sudo chrt -r 20 /usr/local/bin/xdp-poller --iface eth0
$ chrt -i 0 nice ionice -c3 /usr/bin/updatedb
0

# SCHED_DEADLINE: 2 ms of runtime every 10 ms period
$ sudo chrt -d --sched-runtime 2000000 --sched-deadline 10000000 \
             --sched-period 10000000 0 ./control-loop
$ chrt -p $(pgrep control-loop)
pid 9134's current scheduling policy: SCHED_DEADLINE
pid 9134's current scheduling priority: 0
pid 9134's current runtime/deadline/period parameters: 2000000/10000000/10000000
```

`SCHED_DEADLINE` performs **admission control**: the kernel refuses the call if total bandwidth `Σ(runtime/period)` would exceed the allowance. This is a feature — it is the only Linux policy that cannot be oversubscribed.

```console
$ sudo chrt -d --sched-runtime 900000000 --sched-deadline 1000000000 \
             --sched-period 1000000000 0 ./greedy
chrt: failed to set pid 0's policy: Device or resource busy
```

### 5.3 The RT safety net — and how to not remove it

An uncapped `SCHED_FIFO` busy loop at priority 99 on a single-CPU VM will wedge the machine: nothing else, including your SSH daemon, will ever run. Linux ships a throttle:

```console
$ sysctl kernel.sched_rt_period_us kernel.sched_rt_runtime_us
kernel.sched_rt_period_us = 1000000
kernel.sched_rt_runtime_us = 950000
```

RT classes get at most 950 ms of every 1 s (95 %), leaving 5 % for `SCHED_OTHER`. This is what saves you.

| Setting | Effect | Verdict |
|---|---|---|
| `sched_rt_runtime_us = 950000` | 95 % RT ceiling (default) | ✅ keep |
| `sched_rt_runtime_us = 990000` | 99 % ceiling | ⚠️ only with a watchdog and out-of-band console access |
| `sched_rt_runtime_us = -1` | throttling **off** | ❌ one bug = unrecoverable node, no SSH, no kubelet |

If you must disable it (hard-RT appliances with `isolcpus` + `nohz_full`), you must also isolate the RT CPUs and keep a housekeeping core:

```
# /etc/default/grub  → GRUB_CMDLINE_LINUX_DEFAULT
isolcpus=nohz,domain,managed_irq,8-15 nohz_full=8-15 rcu_nocbs=8-15 irqaffinity=0-7
```

### 5.4 Priority inversion — the failure mode that makes RT worse than nothing

A `SCHED_FIFO` prio-80 task blocks on a mutex held by a nice-0 task. A nice-0 CPU hog now prevents the lock holder from running, which prevents the RT task from ever running. The RT task has effectively become the *lowest* priority thing on the box.

Linux offers **priority inheritance** only through PI futexes (`pthread_mutexattr_setprotocol(..., PTHREAD_PRIO_INHERIT)`), which the application must opt into. There is no kernel-level auto-fix.

**Architectural rule:** never promote a process to a real-time policy unless you know every lock it takes is either PI-enabled or uncontended by non-RT tasks. Promoting a random daemon to `SCHED_FIFO` "because it's important" is how you turn an intermittent latency spike into a hard hang.

---

## 6. I/O priorities and cgroup v2

### 6.1 `ionice(1)`

CPU priority and I/O priority are independent. A nice-19 `rsync` still issues the same block requests at the same depth.

| Class | `-c` | Priority levels | Semantics |
|---|---|---|---|
| none | 0 | — | not explicitly set; kernel derives best-effort from nice |
| realtime | 1 | 0–7 (0 = highest) | served first; can starve everything. Requires `CAP_SYS_NICE` |
| best-effort | 2 | 0–7 | default class |
| idle | 3 | n/a | served only when no other I/O is pending |

The derived default is:

```
best_effort_prio = (nice + 20) / 5      →  nice 0 ⇒ 4,  nice 19 ⇒ 7,  nice -20 ⇒ 0
```

```console
$ ionice -p 1
none: prio 4

$ ionice
none: prio 4

$ sudo ionice -c 3 -p 4412
$ ionice -p 4412
idle

$ ionice -c 2 -n 7 -p 4412
$ ionice -p 4412
best-effort: prio 7

$ ionice -c 3 -t nice -n 19 rsync -aHAX /data/ /backup/data/
```

`-t` tells `ionice` to ignore failure and run the command anyway — the same silent-failure hazard as `nice`.

> **⚠️ The single biggest `ionice` trap:** class and priority are honoured **only by the BFQ I/O scheduler**. `mq-deadline`, `kyber` and `none` ignore them entirely. Since the removal of CFQ in Linux 5.0, most distributions default NVMe devices to `none` — where `ionice` is a **no-op**.

```console
$ cat /sys/block/nvme0n1/queue/scheduler
[none] mq-deadline kyber bfq

$ cat /sys/block/sda/queue/scheduler
mq-deadline kyber [bfq] none
```

On `nvme0n1` above, every `ionice` command you type does nothing. Verify before you rely on it. To switch (and understand you are trading raw IOPS for fairness):

```ini
# /etc/udev/rules.d/60-ioscheduler.rules
# Rotational devices → BFQ (fairness, honours ionice)
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
# NVMe → none (lowest overhead); use cgroup io.latency for isolation instead of ionice
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
```

### 6.2 cgroup v2 — the layer that actually holds in production

```console
$ mount | grep cgroup2
cgroup2 on /sys/fs/cgroup type cgroup2 (rw,nosuid,nodev,noexec,relatime,nsdelegate,memory_recursive_prot)

$ cat /sys/fs/cgroup/cgroup.controllers
cpuset cpu io memory hugetlb pids rdma misc
```

| Interface file | Range / format | Meaning |
|---|---|---|
| `cpu.weight` | 1–10000, default **100** | proportional share among siblings — the cgroup analogue of nice |
| `cpu.weight.nice` | −20…19, default 0 | same knob expressed on the nice scale (translation shim) |
| `cpu.max` | `"MAX PERIOD"`, e.g. `200000 100000` | **hard** bandwidth cap: 2 CPUs |
| `cpu.idle` | 0 / 1 | 1 ⇒ every task in the cgroup is scheduled as `SCHED_IDLE` |
| `cpu.pressure` | PSI | `some`/`full` stall percentages — the real starvation signal |
| `cpu.stat` | counters | `nr_throttled`, `throttled_usec` |
| `io.weight` | 1–10000 | BFQ proportional I/O share |
| `io.latency` | `MAJ:MIN target=USEC` | latency SLO; throttles *other* cgroups to protect this one |
| `io.max` | `MAJ:MIN rbps=… wiops=…` | hard I/O cap |

```console
$ cd /sys/fs/cgroup/system.slice
$ cat indexer.service/cpu.weight api.service/cpu.weight
100
100

$ echo 1    | sudo tee indexer.service/cpu.weight
1
$ echo 10000 | sudo tee api.service/cpu.weight
10000

$ cat indexer.service/cpu.stat
usage_usec 918234112
user_usec 902118440
system_usec 16115672
nr_periods 0
nr_throttled 0
throttled_usec 0
```

`cpu.weight` beats `nice` for service-vs-service isolation for one decisive reason: it is **hierarchical and thread-agnostic**. Every current and future thread of the service inherits it, with no `for t in /proc/*/task/*` loop and no autogroup surprise.

**Trade-off table — pick the right instrument:**

| Instrument | Scope | Work-conserving? | Survives new threads? | Crosses cgroups? | Hard guarantee? |
|---|---|---|---|---|---|
| `nice`/`renice` | one **thread** | yes | ❌ no | ❌ no | no |
| autogroup nice | one session | yes | yes | ❌ no | no |
| `cpu.weight` | cgroup subtree | yes | ✅ yes | ✅ yes | no (share only) |
| `cpu.max` | cgroup subtree | **no** (wastes idle CPU) | ✅ yes | ✅ yes | ✅ ceiling |
| `cpuset.cpus` | cgroup subtree | no | ✅ yes | ✅ yes | ✅ partition |
| `SCHED_IDLE` / `cpu.idle` | thread / cgroup | yes | thread: ❌ / cgroup: ✅ | ✅ yes | ✅ floor of 0 |
| `SCHED_FIFO/RR` | thread | yes | ❌ no | ✅ yes (global) | ✅ but dangerous |
| `SCHED_DEADLINE` | thread | no | ❌ no | ✅ yes | ✅ with admission control |

> **`cpu.max` vs `cpu.weight`:** a quota is not free. `cpu.max` throttles even when the machine is 90 % idle, and CFS bandwidth throttling is a documented source of p99 latency spikes for multi-threaded runtimes (all threads burn the quota in the first few ms of the period, then the whole application sleeps for the rest). Prefer `cpu.weight` for isolation and reserve `cpu.max` for tenancy/billing boundaries where predictability beats throughput.

---

## 7. Infrastructure manifests

### 7.1 systemd unit — the low-latency API

```ini
# /etc/systemd/system/api.service
[Unit]
Description=Latency-critical gRPC API
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/api-server --config /etc/api/config.yaml
Restart=on-failure
RestartSec=2s

# ---- CPU priority: the per-task layer -------------------------------------
# Nice= is applied via setpriority(2) on the main process before exec and is
# inherited by every child and thread it creates thereafter.
Nice=-5
# LimitNICE is RLIMIT_NICE, expressed by systemd on the NICE scale (not inverted).
LimitNICE=-10

# ---- CPU priority: the cgroup layer (this is the one that actually holds) --
CPUAccounting=yes
CPUWeight=10000
# Extra weight during boot/startup only, released once the unit is "started".
StartupCPUWeight=10000
# NO CPUQuota= here on purpose: this workload must be able to burst.

# ---- I/O ------------------------------------------------------------------
IOAccounting=yes
IOWeight=1000
# Protect this service's read latency; the kernel throttles *other* cgroups
# when this one exceeds the target. Requires the io controller + BFQ or blk-iolatency.
IODeviceLatencyTargetSec=/dev/nvme0n1 2ms

# ---- Memory ---------------------------------------------------------------
MemoryAccounting=yes
MemoryLow=8G
OOMScoreAdjust=-500

# ---- Hardening ------------------------------------------------------------
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
# CAP_SYS_NICE is required only if the process lowers its OWN threads' nice
# at runtime; Nice=/LimitNICE= above are applied by systemd (PID 1), which
# already has the capability, so most services do NOT need this.
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/indexer.service
[Unit]
Description=Nightly corpus indexer (background, must never disturb api.service)
After=api.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/indexer --corpus /data/corpus

# ---- CPU ------------------------------------------------------------------
Nice=19
# The decisive setting: 1/10000th of api.service's share at every contention point.
CPUAccounting=yes
CPUWeight=1
# Also cap it, so an indexer bug cannot consume a whole node even when idle
# capacity exists and cache pollution would still hurt the API.
CPUQuota=400%
# Keep it off the API's cores entirely on this NUMA-partitioned node.
AllocationCPUs=
CPUAffinity=20-39

# ---- Scheduling policy ----------------------------------------------------
CPUSchedulingPolicy=batch
# (Use CPUSchedulingPolicy=idle for a truly best-effort job. For RT units:
#  CPUSchedulingPolicy=rr + CPUSchedulingPriority=1..99 + LimitRTPRIO=.)

# ---- I/O ------------------------------------------------------------------
IOAccounting=yes
IOSchedulingClass=idle
IOWeight=1
IOReadBandwidthMax=/dev/nvme0n1 200M
IOWriteBandwidthMax=/dev/nvme0n1 100M

[Install]
WantedBy=multi-user.target
```

Apply and verify:

```console
$ sudo systemctl daemon-reload && sudo systemctl restart api.service indexer.service

$ systemctl show api.service -p Nice -p CPUWeight -p CPUSchedulingPolicy -p LimitNICE
Nice=-5
CPUWeight=10000
CPUSchedulingPolicy=0
LimitNICE=30

$ systemd-cgls /system.slice/indexer.service
Control group /system.slice/indexer.service:
└─ 9455 /usr/local/bin/indexer --corpus /data/corpus

$ systemd-cgtop -1 --order=cpu | head -6
Control Group                    Tasks   %CPU   Memory  Input/s Output/s
/                                  1204 3891.2    71.2G    12.1M    88.4M
/system.slice/api.service           212 3402.7     6.1G     1.2M     4.0M
/system.slice/indexer.service        48  398.9     2.4G    10.4M    81.2M
/system.slice/kubelet.service        61   41.2   812.0M        -    1.1M
```

Ad-hoc, without writing a unit — the correct way to run a one-off heavy job on a production node:

```console
$ systemd-run --scope --unit=oneoff-reindex \
    -p CPUWeight=1 -p CPUQuota=200% -p Nice=19 \
    -p IOWeight=1 -p IOSchedulingClass=idle \
    /usr/local/bin/reindex --all
Running scope as unit: oneoff-reindex.scope

# Retune it live, without restarting
$ sudo systemctl set-property --runtime oneoff-reindex.scope CPUQuota=50%
```

### 7.2 Kubernetes: what maps to what

There is **no `nice` field in a Pod spec.** Understanding what Kubernetes *does* expose — and what it does not — is the difference between a working isolation strategy and cargo cult.

| Kubernetes concept | Kernel mechanism | Affects CPU time? |
|---|---|---|
| `resources.requests.cpu` | cgroup **`cpu.weight`** | ✅ **yes** — this is the real priority knob |
| `resources.limits.cpu` | cgroup **`cpu.max`** (quota/period) | ✅ hard cap, causes throttling |
| QoS class (Guaranteed/Burstable/BestEffort) | `oom_score_adj` + eviction order | ❌ no (memory/eviction only) |
| `PriorityClass` / `priority` | scheduler admission + preemption | ❌ no (which node, not which cycle) |
| `spec.containers[].securityContext.capabilities` `SYS_NICE` | allows `setpriority`/`sched_setscheduler` in-container | enables the app to nice itself |

The `requests.cpu` → `cpu.weight` conversion the kubelet performs:

```
shares  = max(2, millicores * 1024 / 1000)                  # cgroup v1 units
weight  = 1 + ((shares - 2) * 9999) / (262144 - 2)          # v1 → v2 translation
```

| `requests.cpu` | shares | `cpu.weight` |
|---|---:|---:|
| `100m` | 102 | 4 |
| `500m` | 512 | 20 |
| `1` | 1024 | **39** |
| `4` | 4096 | 157 |
| `16` | 16384 | 626 |

Complete manifest — the same api/indexer split, expressed in Kubernetes:

```yaml
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: latency-critical
value: 1000000
globalDefault: false
preemptionPolicy: PreemptLowerPriority
description: >-
  Scheduling/eviction priority only. This does NOT give the pod more CPU time;
  CPU time comes from resources.requests.cpu, which the kubelet translates
  into cgroup v2 cpu.weight.
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: background-batch
value: 100
globalDefault: false
preemptionPolicy: Never
description: Never preempts anything; first to be evicted under node pressure.
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-server
  namespace: prod
  labels:
    app.kubernetes.io/name: api-server
spec:
  replicas: 6
  selector:
    matchLabels:
      app.kubernetes.io/name: api-server
  template:
    metadata:
      labels:
        app.kubernetes.io/name: api-server
    spec:
      priorityClassName: latency-critical
      # Guaranteed QoS: requests == limits for every container and every resource.
      # On a node with the static CPUManager policy this also grants exclusive
      # pinned cores, which removes scheduler contention entirely.
      containers:
        - name: api
          image: registry.internal/api-server:1.24.3
          command: ["/usr/local/bin/api-server"]
          args: ["--config=/etc/api/config.yaml"]
          ports:
            - name: grpc
              containerPort: 8443
              protocol: TCP
          resources:
            requests:
              cpu: "4"           # -> cpu.weight 157
              memory: "8Gi"
            limits:
              cpu: "4"           # requests == limits -> Guaranteed
              memory: "8Gi"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            capabilities:
              drop: ["ALL"]
              # SYS_NICE lets the runtime pin/prioritise its own worker threads.
              # Grant ONLY if the application actually calls sched_setaffinity(2)
              # or setpriority(2) with a negative adjustment.
              add: ["SYS_NICE"]
          readinessProbe:
            grpc:
              port: 8443
            initialDelaySeconds: 5
            periodSeconds: 5
          volumeMounts:
            - name: config
              mountPath: /etc/api
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: api-config
      tolerations:
        - key: workload
          operator: Equal
          value: latency-critical
          effect: NoSchedule
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: corpus-indexer
  namespace: prod
spec:
  schedule: "0 2 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          restartPolicy: Never
          priorityClassName: background-batch
          containers:
            - name: indexer
              image: registry.internal/indexer:0.9.1
              command: ["/usr/local/bin/indexer"]
              args: ["--corpus=/data/corpus"]
              resources:
                requests:
                  cpu: "100m"    # -> cpu.weight 4  (39x less than the API's 157)
                  memory: "2Gi"
                limits:
                  cpu: "8"       # may burst into idle capacity...
                  memory: "4Gi"  # ...but yields instantly when the API needs CPU
              securityContext:
                allowPrivilegeEscalation: false
                runAsNonRoot: true
                runAsUser: 10002
                capabilities:
                  drop: ["ALL"]
              volumeMounts:
                - name: corpus
                  mountPath: /data/corpus
          volumes:
            - name: corpus
              persistentVolumeClaim:
                claimName: corpus-pvc
```

Note the deliberate asymmetry in the CronJob: `requests.cpu: 100m` with `limits.cpu: 8`. Low request = low `cpu.weight` = yields under contention. High limit = high `cpu.max` = uses idle capacity when the API is quiet. This is the **work-conserving batch pattern**, and it is strictly better than `nice 19` inside the container, which the container could not set anyway without `SYS_NICE`.

Verify the kubelet actually produced what you expect:

```console
$ POD=$(kubectl -n prod get pod -l app.kubernetes.io/name=api-server -o jsonpath='{.items[0].metadata.name}')
$ NODE=$(kubectl -n prod get pod "$POD" -o jsonpath='{.spec.nodeName}')
$ UID_=$(kubectl -n prod get pod "$POD" -o jsonpath='{.metadata.uid}' | tr '-' '_')

$ ssh "$NODE" "cat /sys/fs/cgroup/kubepods.slice/kubepods-pod${UID_}.slice/cpu.weight"
157

$ ssh "$NODE" "cat /sys/fs/cgroup/kubepods.slice/kubepods-pod${UID_}.slice/cpu.max"
400000 100000

$ ssh "$NODE" "cat /sys/fs/cgroup/kubepods.slice/kubepods-besteffort.slice/cpu.weight"
1
```

---

## 8. Verification and failure diagnosis

### 8.1 The verification ladder

Never assert a priority change succeeded — read it back. In increasing order of rigour:

```console
# Rung 1: was the value accepted?
$ ps -o pid,tid,ni,cls,rtprio,comm -L -p 4412 | head -4
    PID     TID  NI CLS RTPRIO COMMAND
   4412    4412  19  TS      - indexer
   4412    4413  19  TS      - indexer
   4412    4414  19  TS      - indexer

$ chrt -p 4412
pid 4412's current scheduling policy: SCHED_OTHER
pid 4412's current scheduling priority: 0

$ ionice -p 4412
idle

# Rung 2: is the scheduler using the weight you think it is?
$ grep -E 'se.load.weight|policy|prio|nr_involuntary' /proc/4412/sched
se.load.weight                               :                15360
policy                                       :                    0
prio                                         :                  139
nr_involuntary_switches                      :               412809
```

> `se.load.weight` is **scaled by 2^10 on 64-bit kernels**. `15360 = 15 × 1024` = nice 19. A nice-0 task reads `1048576`. If you see `1048576` after "successfully" renicing to 19, you reniced the wrong thread.

```console
# Rung 3: is it actually being starved / is it actually starving someone?
# /proc/<pid>/schedstat = <time_on_cpu_ns> <runqueue_wait_ns> <timeslices>
$ cat /proc/4412/schedstat
918234112000 41209884773991 412809
$ cat /proc/2210/schedstat
3441290551000 2118440221 918442
```

The indexer waited **41 209 s** on the runqueue for 918 s of CPU (4400 % wait/run). The API waited 2.1 s for 3441 s of CPU (0.06 %). That is a *correct* configuration, quantitatively proven. Reverse those numbers and you have your incident.

```console
# Rung 4: pressure stall information — the SLO-level signal
$ cat /sys/fs/cgroup/system.slice/api.service/cpu.pressure
some avg10=0.11 avg60=0.09 avg300=0.14 total=88412991
full avg10=0.00 avg60=0.00 avg300=0.00 total=0

$ cat /sys/fs/cgroup/system.slice/indexer.service/cpu.pressure
some avg10=94.22 avg60=91.87 avg300=88.03 total=8811240991
full avg10=91.02 avg60=88.44 avg300=84.19 total=8402118440
```

`some avg10` on the API is 0.11 % — it is not waiting. The indexer is stalled 94 % of the time. Exactly the intended outcome. **PSI on the protected workload is the metric to alert on**, not CPU utilisation.

```console
# Rung 5: quota throttling (only meaningful when cpu.max is set)
$ cat /sys/fs/cgroup/system.slice/indexer.service/cpu.stat
usage_usec 918234112
nr_periods 88124
nr_throttled 71209
throttled_usec 412098844
```

`nr_throttled / nr_periods = 80.8 %` — this workload is quota-bound, not weight-bound. If this were the API, that ratio would be your p99 latency bug, and the fix is raising `limits.cpu` (or removing it), **not** touching nice.

### 8.2 Reproducible lab

```bash
#!/usr/bin/env bash
# nice-lab.sh — prove the weight table on a single core. Run as a normal user.
set -euo pipefail

CPU=${CPU:-$(( $(nproc) - 1 ))}     # last CPU; keep the others free
DURATION=${DURATION:-6}

hog() {  # $1 = nice value
    taskset -c "$CPU" nice -n "$1" \
        setsid --wait sh -c 'while :; do :; done' &
    echo $!
}

run_case() {
    local a=$1 b=$2 same_session=$3
    echo "=== nice $a vs nice $b  (same autogroup: $same_session) ==="
    if [[ $same_session == yes ]]; then
        taskset -c "$CPU" nice -n "$a" sh -c 'while :; do :; done' & local pa=$!
        taskset -c "$CPU" nice -n "$b" sh -c 'while :; do :; done' & local pb=$!
    else
        local pa pb; pa=$(hog "$a"); pb=$(hog "$b")
    fi
    sleep 1
    pidstat -p "$pa","$pb" "$DURATION" 1 | tail -n +4
    kill -- -"$pa" "$pa" 2>/dev/null || true
    kill -- -"$pb" "$pb" 2>/dev/null || true
    wait 2>/dev/null || true
    echo
}

run_case 0  0  yes     # expect 50 / 50
run_case 0  5  yes     # expect 75 / 25
run_case 0 19  yes     # expect 98.6 / 1.4
run_case 0 19  no      # expect 50 / 50  <-- the autogroup effect
```

```console
$ ./nice-lab.sh
=== nice 0 vs nice 0  (same autogroup: yes) ===
02:41:12     1000     11201   50.17    0.00    0.00   49.83   50.17    39  sh
02:41:12     1000     11202   49.83    0.00    0.00   50.17   49.83    39  sh

=== nice 0 vs nice 5  (same autogroup: yes) ===
02:41:20     1000     11244   75.33    0.00    0.00   24.67   75.33    39  sh
02:41:20     1000     11245   24.67    0.00    0.00   75.33   24.67    39  sh

=== nice 0 vs nice 19  (same autogroup: yes) ===
02:41:28     1000     11288   98.50    0.00    0.00    1.50   98.50    39  sh
02:41:28     1000     11289    1.50    0.00    0.00   98.50    1.50    39  sh

=== nice 0 vs nice 19  (same autogroup: no) ===
02:41:36     1000     11333   50.00    0.00    0.00   50.00   50.00    39  sh
02:41:36     1000     11334   50.00    0.00    0.00   50.00   50.00    39  sh
```

Three predictions confirmed, one deliberate demonstration of the trap. `taskset -c` is not decoration: on a 40-core box, two hogs never contend, and the whole experiment silently reads 100/100.

### 8.3 Failure catalogue

| Symptom | Root cause | Confirm with | Fix |
|---|---|---|---|
| `nice -n 19` has no effect | offender and victim are in different **autogroups** | `cat /proc/<pid>/autogroup` for both | write the nice value to `/proc/<pid>/autogroup`, or set `kernel.sched_autogroup_enabled=0`, or move to cgroups |
| `nice -n 19` has no effect | offender and victim are in different **cgroups** | `cat /proc/<pid>/cgroup` for both | set `cpu.weight` / `CPUWeight=` on the cgroups |
| `nice -n 19` has no effect | there is spare CPU; nothing is contending | `vmstat 1` → `r` column ≤ `nproc` | nothing to fix — the contention is elsewhere (I/O, memory bandwidth, locks) |
| `renice` "succeeded" but process still hogs | Linux nice is **per-thread**; only the main thread changed | `ps -L -o tid,ni -p <pid>` | loop over `/proc/<pid>/task/*`, or use a cgroup |
| `nice: cannot set niceness: Permission denied`, exit 0 | negative adjustment without `CAP_SYS_NICE`/`RLIMIT_NICE` | `ulimit -e`, `prlimit --pid $$ --nice` | `limits.conf` `nice 30`, or unit `LimitNICE=`/`Nice=` |
| `renice: failed to set priority for 4412 (process ID): Operation not permitted` | not the owner, or trying to lower as unprivileged | `ps -o user -p <pid>`; `id` | run as root, or `-u`/`-g` targeting your own processes |
| Service's nice resets after every restart | someone used `renice` instead of editing the unit | `systemctl show <u> -p Nice` | set `Nice=` in the unit; `renice` is never persistent |
| nice-19 backup still tanks disk latency | `ionice` is a no-op on `none`/`mq-deadline`/`kyber` | `cat /sys/block/<dev>/queue/scheduler` | switch to `bfq`, or use `io.latency`/`io.max` (`IOReadBandwidthMax=`) |
| Whole box unresponsive, no SSH | runaway `SCHED_FIFO` with RT throttling disabled | serial/IPMI console; `sysctl kernel.sched_rt_runtime_us` | restore `950000`; never ship `-1` without `isolcpus` |
| RT task misses deadlines while a nice-0 task spins | **priority inversion** on a non-PI mutex | `cat /proc/<tid>/wchan`, `perf sched latency` | PI futexes in the app, or drop RT and use `cpu.weight` |
| `chrt -d` → `Device or resource busy` | `SCHED_DEADLINE` admission control rejected the bandwidth | `sysctl kernel.sched_rt_runtime_us`; sum existing DL bandwidth | reduce `--sched-runtime` or raise the period |
| Latency spikes at exactly period boundaries | CFS **bandwidth throttling** from `cpu.max` / `limits.cpu` | `cpu.stat` → `nr_throttled`, `throttled_usec` | raise or remove the CPU limit; prefer `cpu.weight` for isolation |
| `top` shows `%Cpu(s) ... 0.0 ni` while a niced job runs hot | that bucket counts only positively-niced **user** time at tick sampling; niced kernel time and cgroup-attributed time land elsewhere | compare with `pidstat` / `cpuacct` | trust per-task/per-cgroup accounting, not the summary line |

### 8.4 Diagnostic one-liners

```bash
# Every non-default nice value on the box, with its cgroup
ps -eLo tid,ni,cls,rtprio,comm --no-headers \
  | awk '$2 != 0 && $2 != "-" {print}' \
  | while read -r tid ni cls rt cmd; do
      printf '%-8s ni=%-4s cls=%-4s rt=%-4s %-20s %s\n' \
        "$tid" "$ni" "$cls" "$rt" "$cmd" "$(cut -d: -f3 /proc/$tid/cgroup 2>/dev/null | head -1)"
    done

# Every real-time thread — audit this after any incident
ps -eLo pid,tid,cls,rtprio,pri,comm | awk '$3 ~ /FF|RR|DLN/'

# Top 10 threads by runqueue wait time (starvation ranking)
for t in /proc/[0-9]*/task/[0-9]*; do
  [ -r "$t/schedstat" ] || continue
  read -r run wait n < "$t/schedstat"
  printf '%s %s %s\n' "$wait" "${t##*/}" "$(cat "$t/comm" 2>/dev/null)"
done | sort -rn | head -10

# cgroups sorted by CPU pressure
grep -H '^some' /sys/fs/cgroup/**/cpu.pressure 2>/dev/null \
  | sed 's#/sys/fs/cgroup/##; s#/cpu.pressure:some avg10=# #' \
  | sort -k2 -rn | head -10
```

### 8.5 Non-negotiable operating rules

1. **Never `renice` a process to fix a service.** It survives until the next restart and no further. Edit the unit or the cgroup.
2. **Never grant `SCHED_FIFO`/`SCHED_RR` without an `RTPRIO` ceiling** (`LimitRTPRIO=`, `limits.conf`) and without leaving RT throttling enabled.
3. **Never disable RT throttling on a node you cannot reach over IPMI/serial.**
4. **Never assume `ionice` works.** Check `/sys/block/*/queue/scheduler` first, every time.
5. **`nice` is a hint about relative importance among siblings; `cgroups` are the enforcement layer.** Use the first for interactive convenience, the second for anything with an SLO.
6. **Prove the change with `schedstat` or `cpu.pressure`, not with the absence of complaints.**

---

## 9. Command reference

| Task | Command |
|---|---|
| Show current shell nice | `nice` |
| Run at nice +10 (default) | `nice COMMAND` |
| Run at nice +19 | `nice -n 19 COMMAND` |
| Run at nice −5 (needs privilege) | `sudo nice -n -5 COMMAND` |
| Set running process to nice 5 | `renice -n 5 -p PID` |
| Renice all processes of a user | `sudo renice -n 10 -u alice` |
| Renice a process group | `sudo renice -n 10 -g PGID` |
| Renice every thread of a process | `for t in /proc/PID/task/*; do sudo renice -n 19 -p "${t##*/}"; done` |
| Show nice/class/rtprio | `ps -eLo pid,tid,ni,cls,rtprio,comm` |
| Interactive view + renice | `top` → `r`, then PID, then value |
| Query scheduling policy | `chrt -p PID` |
| Set `SCHED_FIFO` prio 50 | `sudo chrt -f -p 50 PID` |
| Set `SCHED_IDLE` | `sudo chrt -i -p 0 PID` |
| Show valid priority ranges | `chrt -m` |
| Query I/O priority | `ionice -p PID` |
| Idle-class I/O | `sudo ionice -c 3 -p PID` |
| Combined background launch | `chrt -i 0 nice -n 19 ionice -c 3 CMD` |
| RLIMIT_NICE of a process | `prlimit --pid PID --nice` |
| Autogroup of a process | `cat /proc/PID/autogroup` |
| cgroup weight | `cat /sys/fs/cgroup/<path>/cpu.weight` |
| Live cgroup CPU view | `systemd-cgtop` |
| Ad-hoc constrained job | `systemd-run --scope -p CPUWeight=1 -p Nice=19 CMD` |
| Retune a live unit | `systemctl set-property --runtime UNIT CPUWeight=50` |

**Exam-critical facts:** default nice is **0**; range is **−20 (most favourable)** to **19 (least favourable)**; only a privileged process may **lower** a nice value; `nice` with no `-n` applies **+10**; `nice -n` is an **increment** while util-linux `renice -n` is **absolute**; `nice -5` means **+5**.

---

## 10. Referencias

**LPI official objectives**
- LPIC-1 Exam 101-500 Objectives (Topic 103.6) — https://www.lpi.org/our-certifications/exam-101-objectives/
- LPIC-1 Certification Overview — https://www.lpi.org/our-certifications/lpic-1-overview/

**Linux man-pages (upstream, Michael Kerrisk / kernel.org project)**
- `nice(1)` — https://man7.org/linux/man-pages/man1/nice.1.html
- `renice(1)` — https://man7.org/linux/man-pages/man1/renice.1.html
- `nice(2)` — https://man7.org/linux/man-pages/man2/nice.2.html
- `getpriority(2)` / `setpriority(2)` — https://man7.org/linux/man-pages/man2/setpriority.2.html
- `sched(7)` — overview of scheduling APIs, policies, autogroups, RT throttling — https://man7.org/linux/man-pages/man7/sched.7.html
- `sched_setscheduler(2)` — https://man7.org/linux/man-pages/man2/sched_setscheduler.2.html
- `sched_setattr(2)` — `SCHED_DEADLINE` and per-task latency hints — https://man7.org/linux/man-pages/man2/sched_setattr.2.html
- `chrt(1)` — https://man7.org/linux/man-pages/man1/chrt.1.html
- `ionice(1)` — https://man7.org/linux/man-pages/man1/ionice.1.html
- `ioprio_set(2)` / `ioprio_get(2)` — https://man7.org/linux/man-pages/man2/ioprio_set.2.html
- `getrlimit(2)` — `RLIMIT_NICE`, `RLIMIT_RTPRIO`, `RLIMIT_RTTIME` — https://man7.org/linux/man-pages/man2/getrlimit.2.html
- `capabilities(7)` — `CAP_SYS_NICE` — https://man7.org/linux/man-pages/man7/capabilities.7.html
- `proc(5)` / `proc_pid_stat(5)` — fields 18 (priority) and 19 (nice) — https://man7.org/linux/man-pages/man5/proc.5.html
- `ps(1)` — https://man7.org/linux/man-pages/man1/ps.1.html
- `top(1)` — https://man7.org/linux/man-pages/man1/top.1.html
- `taskset(1)` — https://man7.org/linux/man-pages/man1/taskset.1.html
- `limits.conf(5)` — https://man7.org/linux/man-pages/man5/limits.conf.5.html
- `cgroups(7)` — https://man7.org/linux/man-pages/man7/cgroups.7.html

**Linux kernel documentation (kernel.org)**
- CFS scheduler design — https://docs.kernel.org/scheduler/sched-design-CFS.html
- EEVDF scheduler — https://docs.kernel.org/scheduler/sched-eevdf.html
- Real-time group scheduling and RT throttling — https://docs.kernel.org/scheduler/sched-rt-group.html
- `SCHED_DEADLINE` — https://docs.kernel.org/scheduler/sched-deadline.html
- Scheduler statistics (`/proc/<pid>/schedstat`) — https://docs.kernel.org/scheduler/sched-stats.html
- Control Group v2 — `cpu.weight`, `cpu.max`, `cpu.idle`, `io.latency` — https://docs.kernel.org/admin-guide/cgroup-v2.html
- Pressure Stall Information (PSI) — https://docs.kernel.org/accounting/psi.html
- BFQ I/O scheduler — https://docs.kernel.org/block/bfq-iosched.html
- Kernel sysctl reference (`kernel.sched_*`) — https://docs.kernel.org/admin-guide/sysctl/kernel.html

**GNU coreutils**
- `nice` invocation — https://www.gnu.org/software/coreutils/manual/html_node/nice-invocation.html

**systemd (freedesktop.org)**
- `systemd.exec(5)` — `Nice=`, `CPUSchedulingPolicy=`, `CPUSchedulingPriority=`, `IOSchedulingClass=`, `LimitNICE=` — https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- `systemd.resource-control(5)` — `CPUWeight=`, `CPUQuota=`, `IOWeight=`, `IODeviceLatencyTargetSec=` — https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html
- `systemd-run(1)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html
- `systemd-cgtop(1)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-cgtop.html

**Kubernetes**
- Resource Management for Pods and Containers — https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Pod Quality of Service Classes — https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- Pod Priority and Preemption — https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/
- Control CPU Management Policies on the Node — https://kubernetes.io/docs/tasks/administer-cluster/cpu-management-policies/