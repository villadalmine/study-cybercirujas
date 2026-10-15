# LPIC-2 — Topic 200.1: Measure and Troubleshoot Resource Usage

**Exam:** 201-450 · **Objectives version:** 4.5.0 · **LPI weight:** 6 (of 120 across exams 201 and 202; 5.0 in this site's syllabus, which scales LPIC-2 to 100)
**Key knowledge areas:** measure CPU, memory, disk I/O and network I/O; measure firewalling and routing throughput; map client bandwidth usage; correlate system symptoms with likely problems; estimate throughput and identify bottlenecks.
**Files, terms and utilities (LPI's partial list, verbatim):** `iostat`, `iotop`, `vmstat`, `netstat`, `ss`, `iptraf`, `pstree`, `ps`, `w`, `lsof`, `top`, `htop`, `uptime`, `sar`, swap, processes blocked on I/O, blocks in, blocks out.
This material also uses tools that are not on that list (`mpstat`, `pidstat`, `ip`, `nstat`, PSI, cgroup v2); they help in practice, but the exam objective is the list above.

> Sample output in this document is **illustrative**: it was written to be internally consistent, not captured from a host, and the host names, dates and kernel strings in it are made up. **Column sets differ between tool versions** — `iostat`'s extended report changed its fields in sysstat 11.5.7 (`avgqu-sz` became `aqu-sz`) and dropped `svctm` in 12.1.2, and `vmstat` prints guest time (`gu`) in its default output since procps-ng 4.0.4 (sysstat `CHANGES`, procps-ng `NEWS`, both in the References). Always read the header your host prints, never the header you remember.

---

## 1. The architectural problem: utilization is not the thing you care about

Every production incident that begins with "the server is slow" is a **latency** complaint. Every dashboard that gets looked at first reports **utilization**. These two quantities are related by a curve that is nearly flat and then nearly vertical, which is why utilization is such a treacherous proxy.

For a single service centre with random arrivals, the residence time of a request is:

```
R = S / (1 - ρ)
```

where `S` is the service time of one request and `ρ` is utilization. The practical consequence:

| Utilization ρ | Latency multiplier `1/(1-ρ)` | What a human sees |
|---|---|---|
| 0.50 | 2.0× | "normal" |
| 0.70 | 3.3× | "normal" |
| 0.80 | 5.0× | p99 starts to fray |
| 0.90 | 10× | "intermittent slowness" tickets |
| 0.95 | 20× | paging, no obvious cause on CPU graphs |
| 0.98 | 50× | "the server is down" (it is not) |

A CPU graph pinned at 90 % and a CPU graph pinned at 50 % look like the same colour of green on most dashboards and differ by a factor of three in queueing delay. Worse, a device can be at **100 % utilization and not be the bottleneck** (an NVMe drive reporting `%util 100` may be serving 2 % of its possible IOPS), and a device can be at **40 % utilization and absolutely be the bottleneck** (a single-threaded process pinned to one core on a 16-core box tops out at 6.25 % system-wide CPU).

This is why serious measurement work separates three distinct quantities per resource — the **USE method**:

| Quantity | Definition | Where Linux exposes it | Failure mode if you only track this |
|---|---|---|---|
| **Utilization** | fraction of time the resource was busy | `/proc/stat`, `/proc/diskstats`, `/proc/net/dev` | Hides saturation on queued devices; hides per-core imbalance |
| **Saturation** | work that had to wait because the resource was busy | `/proc/loadavg`, `aqu-sz`, `/proc/pressure/*`, `Recv-Q`, `cpu.stat` throttling | None — this is the quantity that correlates with user pain |
| **Errors** | work that was discarded or failed | `ip -s link`, `ethtool -S`, `nstat`, `dmesg`, `memory.events` | Silent drops look like "network is fine, app is buggy" |

**The second architectural problem is the recording.** Interactive tools (`top`, `iostat 1`, `iotop`) can only answer "what is happening now". Incidents are reported in the past tense. A host without a persistent sampler has, for every past event, exactly zero data — and the single most expensive sentence in operations is "let's wait for it to happen again". `sysstat` (`sadc` collecting into `/var/log/sa/saDD`, `sar` reading it back, `sadf` exporting it) is the flight recorder that turns a post-mortem from speculation into arithmetic. Section 9 deploys it properly.

**The third problem is containment.** On any host running containers or systemd resource control, the host-level numbers are no longer the numbers the workload experiences. A process can be stalled at 100 % of *its* CPU allowance while the host reports 30 % idle, because the limit is enforced in `cpu.max` inside a cgroup and the throttling is only visible in `cpu.stat`. Host metrics are necessary and insufficient; Section 3.6 and Section 4.5 cover the cgroup v2 views.

---

## 2. Where the numbers actually come from

Every tool in this objective is a formatter over one of five kernel interfaces. Knowing which one a tool uses tells you its cost, its resolution, and its failure modes.

| Interface | Form | Consumers | Cost / resolution | Hard limits |
|---|---|---|---|---|
| `/proc/<file>` | ASCII, regenerated per read | `vmstat`, `top`, `free`, `mpstat`, `iostat`, `sar`, `netstat` | cheap for fixed-size files; **O(n) for per-object files** | counters are 32/64-bit monotonic; no history; `/proc/net/tcp` re-renders every socket as text on every read |
| `netlink` (`sock_diag`, `rtnetlink`) | binary, filterable in kernel | `ss`, `ip`, `nstat`, `tc` | filtering happens kernel-side, so cost scales with the *answer*, not the table | needs `CONFIG_INET_DIAG`; semantics differ per family |
| `taskstats` / delay accounting | binary netlink per task | `iotop`, `pidstat -d` | per-task I/O and delay, exact | needs `CONFIG_TASK_DELAY_ACCT` **and** `kernel.task_delayacct=1` (off by default since 5.14) |
| `perf_events` | ring buffer, sampling + PMU | `perf`, flame graphs | hardware counters, ns resolution | `kernel.perf_event_paranoid`; counters are virtualized away or wrong in many VMs |
| eBPF / tracepoints | in-kernel aggregation | `biolatency`, `biosnoop`, `execsnoop`, `tcplife` | histograms with no sampling loss, low overhead | kernel ≥ 4.9 realistically ≥ 5.4, `CAP_BPF`, tooling must be installed |

Two consequences you should be able to state in an exam and defend in an architecture review:

1. **`ss` is not merely "the new `netstat`"** — it is a different data path. `netstat` parses `/proc/net/tcp`, `/proc/net/tcp6`, `/proc/net/udp`, … as text, and then (for `-p`) walks `/proc/*/fd/*` to map inodes to processes. On a host with many sockets this becomes the most expensive command on the box.

```
$ ss -s | head -2
Total: 118427
TCP:   117981 (estab 116204, closed 1431, orphaned 0, timewait 1402)

$ time ss -tan > /dev/null
real    0m0.214s
user    0m0.061s
sys     0m0.151s

$ time netstat -tan > /dev/null
real    0m7.842s
user    0m1.903s
sys     0m5.914s

$ time netstat -tanp > /dev/null
real    1m12.418s
user    0m9.332s
sys     1m2.590s
```

   On a loaded reverse proxy, `netstat -tanp` is a self-inflicted incident. Use `ss`; keep `netstat` for exam questions and for reading ancient runbooks.

2. **Counter semantics**: almost everything in `/proc` is a monotonic counter since boot, not a rate. `vmstat 5`, `iostat 5`, `sar` and the exporters all compute deltas for you. The **first line of `vmstat`, `iostat`, `mpstat`, `sar` output is the average since boot** and must be discarded — this single mistake invalidates more capacity reports than any other.

---

## 3. CPU

### 3.1 The accounting model

`/proc/stat` accumulates, per CPU and in total, the ticks spent in each state. The kernel's internal unit is `USER_HZ` (100 Hz on x86_64, i.e. one jiffy = 10 ms), regardless of the real scheduler tick:

```
$ head -4 /proc/stat
cpu  48123944 11204 9983012 1472339108 2104771 0 492013 1831904 0 0
cpu0 3011901 702 624312 92013441 131604 0 61204 114702 0 0
cpu1 2998412 688 619884 92110223 129911 0 30112 113884 0 0
cpu2 3004118 711 621044 92071004 130442 0 29884 114011 0 0

$ getconf CLK_TCK
100
```

Field order, which is also the column order in `mpstat`:

| # | Field | Meaning | Diagnostic weight |
|---|---|---|---|
| 1 | `user` | userspace, nice ≤ 0 | the work you are paying for |
| 2 | `nice` | userspace, nice > 0 | batch/background work |
| 3 | `system` | kernel on behalf of a task (syscalls) | high ⇒ syscall storm, lock contention, copy-heavy I/O |
| 4 | `idle` | idle, no I/O outstanding | — |
| 5 | `iowait` | **idle while at least one I/O was outstanding on this CPU** | a hint about disks, not a measure of them |
| 6 | `irq` | hardware interrupt servicing | high ⇒ NIC/storage IRQ affinity problem |
| 7 | `softirq` | deferred interrupt work (`NET_RX`, `NET_TX`, `BLOCK`, `TIMER`, `RCU`) | **the usual ceiling on packet-per-second throughput** |
| 8 | `steal` | runnable but the hypervisor ran someone else | the only honest "noisy neighbour" metric |
| 9 | `guest` | running a guest vCPU (host view) | KVM hosts |
| 10 | `guest_nice` | guest at nice > 0 | KVM hosts |

**`%iowait` is the most misread number in Linux.** It is a *CPU* state, not a disk state. It only accrues when the CPU had nothing else to run. Therefore:

- A fully saturated disk array with a busy CPU reports `%iowait ≈ 0`.
- A single-threaded `dd` on an idle 16-CPU host reports `%iowait ≈ 6 %` even though that process is 100 % blocked.
- `%iowait` rising while throughput *falls* is the real signal (the system is waiting more and getting less).

Measure disks with `iostat`/`biolatency`; use `%iowait` only as a pointer.

### 3.2 Load average — what it counts on Linux

```
$ cat /proc/loadavg
7.41 6.88 5.02 4/1283 884219
```

Fields: 1/5/15-minute exponentially weighted moving averages, `running/total` tasks, last PID. The EWMA decay constants are `exp(-5/60)`, `exp(-5/300)`, `exp(-5/900)`, updated every 5 seconds.

The Linux-specific part — and a classic exam trap — is **what goes into the average**:

| OS family | Counted in load average |
|---|---|
| Classic UNIX (Solaris, older BSD) | tasks in `R` (running + runnable) only — a pure CPU demand metric |
| **Linux** | tasks in `R` **and** `D` (uninterruptible sleep: block I/O, some NFS waits, certain locks) |

So on Linux a load average of 40 on a 16-CPU host can mean "CPU demand is 2.5× capacity" **or** "16 CPUs idle and 40 processes blocked on a dead NFS mount". Load average alone can never distinguish them. The disambiguation is one command:

```
$ vmstat 5 3
procs -----------memory---------- ---swap-- -----io---- -system-- -------cpu-------
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st gu
 2  0  73216 1284992 912384 19884416    0    0   184   412 2104  4881  7  3 89  1  0  0
 1 38  73216 1261504 912512 19901824    0    0 182304  118 9842 14207  4  6 49 41  0  0
 0 41  73216 1258880 912512 19906048    0    0 196112   96 10114 14998  3  7 48 42  0  0
```

`r` is the run queue (CPU demand), `b` is blocked on I/O. Here `r` is ~1 on 16 CPUs and `b` is ~40: this host has **no CPU problem whatsoever**, and a load average near 40. Route this to Section 5.

### 3.3 `uptime` and `w`

```
$ uptime
 11:02:17 up 94 days,  3:12,  3 users,  load average: 7.41, 6.88, 5.02

$ uptime -p
up 3 months, 4 days, 3 hours, 12 minutes

$ uptime -s
2026-07-13 07:50:04

$ w
 11:02:21 up 94 days,  3:12,  3 users,  load average: 7.41, 6.88, 5.02
USER     TTY      FROM              LOGIN@   IDLE   JCPU   PCPU WHAT
root     pts/0    10.20.0.14        10:58    0.00s  0.09s  0.00s w
deploy   pts/1    10.20.0.31        09:12    1:44m  0.21s  0.21s -bash
deploy   pts/2    10.20.0.31        10:41    2:03   4:51   4:48  python3 reindex.py
```

- `JCPU` — CPU consumed by **all** processes attached to that TTY (including finished ones); `PCPU` — CPU of the process listed in `WHAT`. On `pts/2`, `JCPU ≈ PCPU`, so the interactive `reindex.py` is the whole story.
- `w -h` drops the header (scriptable), `w -s` is the short form, `w <user>` filters.
- **`w` reads `/var/run/utmp`**, so it only sees *login* sessions. A runaway process started by cron, a systemd unit, a container, or `ssh host 'cmd'` without a PTY is invisible to `w`. `w` answers "who is logged in and what are they running", never "what is consuming this machine".

### 3.4 `mpstat` — per-CPU distribution, and why aggregates lie

```
$ mpstat -P ALL 5 1
Linux 6.8.0-45-generic (lb01)   10/15/2026      _x86_64_        (16 CPU)

11:05:31     CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle
11:05:36     all   11.42    0.00    6.18    0.21    0.44    5.91    0.00    0.00    0.00   75.84
11:05:36       0    4.21    0.00    3.02    0.00    3.81   81.96    0.00    0.00    0.00    7.00
11:05:36       1   12.04    0.00    6.42    0.20    0.00    1.01    0.00    0.00    0.00   80.33
11:05:36       2   11.88    0.00    6.11    0.41    0.00    0.82    0.00    0.00    0.00   80.78
11:05:36       3   12.31    0.00    6.52    0.20    0.00    0.61    0.00    0.00    0.00   80.36
11:05:36       4   11.64    0.00    6.08    0.00    0.20    0.81    0.00    0.00    0.00   81.27
[... CPUs 5-15 similar ...]

Average:     all   11.42    0.00    6.18    0.21    0.44    5.91    0.00    0.00    0.00   75.84
```

The aggregate says **75 % idle**; CPU 0 is at **93 % busy, 82 % of it in softirq**. This is the canonical single-queue NIC / missing-RSS / broken-IRQ-affinity signature, and it caps the box's packet rate *regardless of the other 15 cores*. Aggregated CPU graphs cannot show it. `mpstat -P ALL` is the first command after `vmstat` on any throughput complaint.

Confirm the interrupt distribution:

```
$ grep -E 'CPU0|eth0|NET_RX' /proc/interrupts /proc/softirqs | head -6
/proc/interrupts:            CPU0       CPU1       CPU2       CPU3
/proc/interrupts: 142:  884210934          0          0          0  IR-PCI-MSI-0000:3b:00.0   eth0-TxRx-0
/proc/softirqs:  NET_RX: 1204881093      40112      38994      39210

$ mpstat -I SCPU 5 1 | head -8
Linux 6.8.0-45-generic (lb01)   10/15/2026      _x86_64_        (16 CPU)

11:06:02     CPU     HI/s  TIMER/s   NET_TX/s   NET_RX/s   BLOCK/s  IRQ_POLL/s  TASKLET/s  SCHED/s  HRTIMER/s   RCU/s
11:06:07     all     0.00   1884.21      42.11   48112.44     88.21        0.00       1.22  1204.11       0.00  2104.88
11:06:07       0     0.00     118.44     40.88   48088.12      0.00        0.00       0.00     84.21       0.00     94.12
```

Single-queue reality: all 48 k `NET_RX`/s land on CPU 0. Fixes are `ethtool -L` (more combined queues), IRQ affinity spreading, or RPS/RFS — see Section 7.4.

Other useful `mpstat` modes: `mpstat -I ALL` (hardware + soft IRQ rates), `mpstat -N ALL` (per-NUMA-node), `mpstat -u -P 0-3`.

### 3.5 `top`, `ps`, `pstree`, `pidstat` — attributing CPU to a process

`top` in batch mode is the scriptable form, and the one to put in an incident capture script:

```
$ top -b -n 1 -o %CPU -w 512 | head -16
top - 11:08:44 up 94 days,  3:18,  3 users,  load average: 7.41, 6.88, 5.02
Tasks: 1283 total,   3 running, 1280 sleeping,   0 stopped,   0 zombie
%Cpu(s): 11.4 us,  6.2 sy,  0.0 ni, 75.8 id,  0.2 wa,  0.4 hi,  5.9 si,  0.0 st
MiB Mem :  64264.4 total,   1254.9 free,  41988.2 used,  21021.3 buff/cache
MiB Swap:   8192.0 total,   7120.0 free,   1072.0 used.  17284.1 avail Mem

    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
 884102 app       20   0 8412004 3.9g   24104 S 398.7   6.2  18:44.21 java -Xmx8g -jar api.jar
 112044 postgres  20   0 4812332 2.1g  1.9g   D  12.4   3.3 884:12.09 postgres: autovacuum worker
  88412 node_exp  20   0  812044  44104  18204 S   2.1   0.1  94:12.84 node_exporter
      9 root      20   0       0      0      0 I   1.8   0.0 412:09.11 [rcu_preempt]
```

Essential interactive keys (exam-relevant and genuinely useful):

| Key | Effect |
|---|---|
| `1` | toggle aggregate vs per-CPU lines (`mpstat -P ALL` from inside `top`) |
| `H` | show **threads** instead of processes — mandatory for JVMs, nginx, databases |
| `c` | full command line instead of comm name |
| `V` | forest/hierarchy view |
| `f` | field selector (add `WCHAN`, `nMaj`, `P` = last-used CPU, `SWAP`) |
| `o` | filter, e.g. `%CPU>10` |
| `x` / `y` | highlight sort column / running tasks |
| `W` | write `~/.config/procps/toprc` so the layout survives |
| `-b -n N -d S` | batch mode, N iterations, S-second delay |

> `%CPU` > 100 is correct and expected: `top` reports percentage of **one** core, so 398.7 means ~4 cores' worth. With `H`, each thread's `%CPU` is ≤ 100 and they sum to the process figure.

`ps` is the stateless, scriptable counterpart. Build the output you need rather than memorizing `aux`:

```
$ ps -eo pid,ppid,user,stat,psr,pcpu,pmem,rss,vsz,wchan:22,etimes,args --sort=-pcpu | head -8
    PID    PPID USER     STAT PSR %CPU %MEM     RSS     VSZ WCHAN                  ELAPSED COMMAND
 884102  884001 app      Sl     6 398.7  6.2 4089104 8412004 futex_wait_queue          1124 java -Xmx8g -jar api.jar
 112044   88102 postgres D      3 12.4  3.3 2201344 4812332 wait_on_page_bit         884012 postgres: autovacuum worker
 112088   88102 postgres D      9  9.8  3.1 2104992 4812332 wait_on_page_bit         883914 postgres: autovacuum worker
  88412       1 node_exp Ssl    1  2.1  0.1   44104  812044 ep_poll                 8121044 /usr/bin/node_exporter
 991204       1 root     Zs    -  0.0  0.0       0       0 do_exit                      88 [backup.sh] <defunct>
```

`STAT` decoding — the first letter is the state, the rest are modifiers:

| Code | Meaning | Operational reading |
|---|---|---|
| `R` | running or runnable | counts toward load and `r` in `vmstat` |
| `S` | interruptible sleep | normal idle waiting (network, timers) |
| `D` | **uninterruptible sleep** | blocked in the kernel; counts toward load; cannot be killed; read `WCHAN` |
| `I` | idle kernel thread | excluded from load (since 4.2) — why `[kworker]` no longer inflates load |
| `Z` | zombie | exited, parent has not reaped; costs a PID slot, nothing else; fix the parent |
| `T` / `t` | stopped / stopped by debugger | `SIGSTOP`, or a job suspended in a shell |
| `<` | high priority (negative nice) | |
| `N` | low priority | |
| `s` | session leader | |
| `l` | multi-threaded | |
| `+` | foreground process group | |
| `L` | pages locked in memory (`mlock`) | not swappable — read with Section 4 |

For a `D`-state investigation, `WCHAN` plus the kernel stack is the whole diagnosis:

```
$ cat /proc/112044/wchan; echo
wait_on_page_bit

$ sudo cat /proc/112044/stack
[<0>] folio_wait_bit_common+0x124/0x330
[<0>] filemap_read_folio+0x9d/0xd0
[<0>] filemap_get_pages+0x5f1/0x6a0
[<0>] filemap_read+0xd1/0x340
[<0>] blkdev_read_iter+0x6d/0x150
[<0>] vfs_read+0x29f/0x350

$ cat /proc/112044/syscall
0 0x2b 0x7f9c08a04000 0x20000 0x0 0x0 0x0 0x7ffd8c0f21a8 0x7f9c0a1d4b32
```

Syscall 0 on x86_64 is `read(2)`: the process is inside a block-device read. If the whole box is in `D` and you need the full picture at once:

```
$ echo w | sudo tee /proc/sysrq-trigger
$ sudo dmesg -T | tail -20
```

`pstree` gives the ancestry that `ps` flattens — indispensable when the CPU burner is a grandchild of something you recognize:

```
$ pstree -aps 884102
systemd,1 --system --deserialize=44
  └─containerd-shim,884001 -namespace moby -id 9f2c...
      └─java,884102 -Xmx8g -jar api.jar
          ├─{java},884110
          ├─{java},884111
          └─{GC Thread#0},884118

$ pstree -Tp postgres | head -5
postgres(88102)─┬─postgres(88104)
                ├─postgres(88105)
                ├─postgres(112044)
                └─postgres(112088)
```

Flags worth knowing: `-a` (arguments), `-p` (PIDs), `-s` (show parents of the target), `-T` (hide threads), `-t` (thread names), `-n` (sort by PID), `-u` (show uid transitions), `-S` (show namespace transitions — reveals container boundaries).

`pidstat` is the per-process equivalent of `vmstat`/`iostat`, and it is the tool that answers "which process, averaged over an interval" instead of `top`'s instantaneous snapshot:

```
$ pidstat -u -t -p 884102 5 2
Linux 6.8.0-45-generic (lb01)   10/15/2026      _x86_64_        (16 CPU)

11:12:04      UID      TGID       TID    %usr %system  %guest   %wait    %CPU   CPU  Command
11:12:09     1001    884102         -   312.4    86.3    0.00    41.2   398.7     6  java
11:12:09     1001         -    884110    98.2    12.1    0.00    38.4   110.3     6  |__java
11:12:09     1001         -    884118    84.1     2.2    0.00     0.8    86.3    11  |__GC Thread#0

$ pidstat -w -p 884102 5 1
11:12:20      UID       PID   cswch/s nvcswch/s  Command
11:12:25     1001    884102    412.80   8841.60  java
```

Two numbers to internalise:

- **`%wait`** (not `%iowait`) is the time the task was **runnable but not scheduled** — direct run-queue latency per process. 41 % means the application is losing nearly half its wall time to CPU contention, which no utilization graph will tell you.
- **`nvcswch/s`** (involuntary context switches) at 8 841/s means the task is being preempted constantly — the scheduler-level confirmation of the same contention.

The per-process ground truth for that is `schedstat`, fields = `[cpu_time_ns] [runqueue_wait_ns] [timeslices]`:

```
$ cat /proc/884102/schedstat
184221904112 98412004881 1204881
```

Ratio `98.4e9 / 184.2e9 ≈ 0.53` — over its lifetime this task waited for a CPU ~0.53 ns per ns of runtime. That is a hard, cumulative, dashboard-free proof of CPU shortage.

### 3.6 Pressure Stall Information: saturation as a first-class metric

Kernels ≥ 4.20 export, per resource, the share of wall time during which work was stalled:

```
$ cat /proc/pressure/cpu
some avg10=18.44 avg60=14.21 avg300=9.07 total=18472930184

$ cat /proc/pressure/io
some avg10=41.07 avg60=38.84 avg300=31.22 total=99184772093
full avg10=29.88 avg60=27.14 avg300=22.04 total=71204881003

$ cat /proc/pressure/memory
some avg10=0.00 avg60=0.00 avg300=0.04 total=1204881
full avg10=0.00 avg60=0.00 avg300=0.01 total=402114
```

- `some` — at least one task was stalled on this resource.
- `full` — **every** non-idle task was stalled, i.e. the machine did no useful work at all. `io full = 29.88` means ~30 % of the last 10 seconds were pure, total I/O stall.
- `cpu` has no meaningful `full` at system scope (a stalled CPU means another task ran).

Why this matters architecturally: PSI is normalized `0–100`, interval-based, and directly comparable across resources. "CPU pressure 18 %, I/O pressure 41 %" is a ranked bottleneck list in two lines, which neither utilization nor load average can produce. It is also available per cgroup (`/sys/fs/cgroup/<slice>/cpu.pressure`), which makes it the correct SLO input on container hosts.

### 3.7 Containment: when the host is idle and the app is throttled

```
$ cat /sys/fs/cgroup/system.slice/api.service/cpu.max
200000 100000

$ cat /sys/fs/cgroup/system.slice/api.service/cpu.stat
usage_usec 18844120049
user_usec 14021884110
system_usec 4822235939
nr_periods 884120
nr_throttled 412884
throttled_usec 2048812044
nr_bursts 0
burst_usec 0
```

`cpu.max = 200000 100000` is a 2-CPU quota over a 100 ms period. `nr_throttled / nr_periods = 412884/884120 = 46.7 %`: in nearly half of all 100 ms windows this service was stopped dead before the window ended — p99 latency will be dominated by up to ~100 ms of pure throttle stall. The host, meanwhile, reports 75 % idle. **Any CPU investigation on a container host that does not read `cpu.stat` is incomplete.**

### 3.8 CPU tooling trade-offs

| Tool | Granularity | Interval | Cost | Best for | Blind spot |
|---|---|---|---|---|---|
| `uptime` / `/proc/loadavg` | whole system | 1/5/15 min EWMA | ~0 | "is this new?" trend direction | cannot separate R from D |
| `w` | per login session | instant | ~0 | interactive-user attribution | only `utmp` sessions |
| `vmstat` | whole system | ≥ 1 s | ~0 | first command; `r` vs `b` split | no per-CPU, no per-process |
| `mpstat -P ALL` | per CPU / per IRQ | ≥ 1 s | ~0 | imbalance, softirq, steal | no per-process |
| `top` / `htop` | per process/thread | ≥ 1 s | low (high with many tasks) | live triage, interactive sort | sampling misses short-lived tasks |
| `ps` | per process | snapshot | ~0 | scripted captures, `STAT`/`WCHAN` | no rates, instantaneous `%CPU` is lifetime average |
| `pidstat -t` | per task | ≥ 1 s | low | `%wait`, context switches, per-thread | needs an interval to be meaningful |
| `sar -u -q -P ALL` | system + per CPU | historical | ~0 | **the past**, capacity planning | resolution = collection interval |
| `/proc/pressure/*` | system + cgroup | 10/60/300 s | ~0 | ranking saturation across resources | kernel ≥ 4.20; no per-process |
| `perf top` / `perf record` | instruction/function | sampled | 1–5 % | *which code* burns CPU | needs symbols; PMU often absent in VMs |
| `exec`/`cpudist` (eBPF) | per event | per-event | low | short-lived processes, run-queue histograms | kernel + tooling requirements |

---

## 4. Memory

### 4.1 `/proc/meminfo`: the only complete account

```
$ grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapCached|Active|Inactive|Dirty|Writeback|AnonPages|Mapped|Shmem|KReclaimable|Slab|SReclaimable|SUnreclaim|PageTables|CommitLimit|Committed_AS|SwapTotal|SwapFree|AnonHugePages|HugePages_Total)' /proc/meminfo
MemTotal:       65806848 kB
MemFree:         1284992 kB
MemAvailable:   17699040 kB
Buffers:          912384 kB
Cached:         19884416 kB
SwapCached:        44112 kB
Active:         38412004 kB
Inactive:       18204112 kB
Dirty:           1204884 kB
Writeback:        204112 kB
AnonPages:      41021884 kB
Mapped:          2104884 kB
Shmem:           2204112 kB
KReclaimable:    1884012 kB
Slab:            2412884 kB
SReclaimable:    1884012 kB
SUnreclaim:       528872 kB
PageTables:       184112 kB
SwapTotal:       8388608 kB
SwapFree:        7291904 kB
CommitLimit:    41291904 kB
Committed_AS:   58412004 kB
AnonHugePages:   8388608 kB
HugePages_Total:       0
```

`free` is a formatter over this file, and `-w` is the flag that makes it honest by splitting `buff/cache`:

```
$ free -w -h
               total        used        free      shared     buffers       cache   available
Mem:            62Gi        40Gi       1.2Gi       2.1Gi       891Mi        18Gi        16Gi
Swap:          8.0Gi       1.0Gi       6.9Gi
```

The three rules that resolve 90 % of "we are out of memory" false alarms:

1. **`free` being near zero is the correct steady state.** Unused RAM is wasted RAM; the kernel fills it with page cache. The number that matters is **`available`** (`MemAvailable`), the kernel's own estimate of what a new allocation could get without swapping, which accounts for reclaimable page cache, `SReclaimable` slab, and the watermarks it must keep. Never compute "free + buffers + cache" by hand; `MemAvailable` already does it correctly and conservatively.
2. **`Committed_AS` > `CommitLimit` (58.4 G vs 41.3 G here) is not an error** under the default `vm.overcommit_memory=0`. It means processes have *promised* allocations exceeding the accounting limit, which is normal for anything that reserves large virtual arenas (JVM, Go runtime, Redis forks). It becomes fatal only under `vm.overcommit_memory=2`, where allocations beyond `CommitLimit` fail outright.
3. **Swap *used* is not a problem; swap *traffic* is.** `si`/`so` in `vmstat`, or `pswpin/s`/`pswpout/s` in `sar -W`, are the symptom. 1 GiB of long-forgotten anonymous pages parked on disk costs nothing.

### 4.2 Per-process memory: VSZ, RSS, PSS, USS

| Metric | Definition | Where | Correct use |
|---|---|---|---|
| `VSZ` / `VmSize` | total virtual address space mapped | `ps`, `/proc/PID/status` | essentially meaningless for capacity; includes unbacked reservations, file maps, guard pages |
| `RSS` / `VmRSS` | resident pages in RAM, **counted in full for every sharer** | `ps`, `top` | per-process pressure, but **sums to more than physical RAM** |
| `PSS` | resident pages with shared pages divided by sharer count | `/proc/PID/smaps_rollup` | the only metric whose sum across processes is meaningful |
| `USS` (`Private_*`) | pages mapped only by this process | `smaps_rollup` | what you would actually reclaim by killing it |
| `WSS` | pages touched in a time window | `/proc/PID/clear_refs` + `Referenced` | right-sizing limits (vs. right-sizing for peak RSS) |

```
$ sudo cat /proc/884102/smaps_rollup
55a1c0000000-7ffd8c0f4000 ---p 00000000 00:00 0                          [rollup]
Rss:             4089104 kB
Pss:             3884112 kB
Pss_Dirty:       3802044 kB
Shared_Clean:     204992 kB
Shared_Dirty:       1024 kB
Private_Clean:     82044 kB
Private_Dirty:   3801020 kB
Referenced:      3912884 kB
Anonymous:       3802044 kB
LazyFree:              0 kB
AnonHugePages:   2097152 kB
Swap:              44112 kB
SwapPss:           44112 kB
Locked:                0 kB
```

Killing this process frees ~3.88 GiB (`Pss`), not 4.09 GiB (`Rss`). On a host with 300 nginx workers, naive RSS summation overstates usage by tens of gigabytes because every worker counts the same shared binary, shared libraries and shared cache pages.

### 4.3 Reclaim, paging and the thrash signature

```
$ sar -B 1 3
Linux 6.8.0-45-generic (db03)   10/15/2026      _x86_64_        (16 CPU)

11:20:01  pgpgin/s pgpgout/s   fault/s  majflt/s  pgfree/s pgscank/s pgscand/s pgsteal/s    %vmeff
11:20:02 184112.00    412.00  88412.00   4812.00 198412.00 412884.00  88412.00 198412.00     39.58
11:20:03 191204.00    388.00  91204.00   5102.00 201884.00 441204.00  91884.00 204112.00     38.29
11:20:04 188412.00    404.00  89884.00   4984.00 199104.00 428112.00  90112.00 201884.00     38.85
Average: 187909.33    401.33  89833.33   4966.00 199800.00 427400.00  90136.00 201469.33     38.90
```

Field-by-field, and what each one proves:

| Field | Meaning | Threshold reading |
|---|---|---|
| `pgpgin/s`, `pgpgout/s` | KiB/s paged in/out from block devices | includes normal file I/O; not swap-specific |
| `fault/s` | all page faults | minor faults are cheap and normal |
| **`majflt/s`** | faults requiring a disk read | **the expensive kind**; sustained thousands/s = working set does not fit |
| `pgscank/s` | pages scanned by `kswapd` (background reclaim) | background reclaim is healthy |
| **`pgscand/s`** | pages scanned **directly** by the allocating task | **direct reclaim = the application is doing the kernel's memory work synchronously, inside its own latency budget** |
| `pgsteal/s` | pages actually reclaimed | |
| **`%vmeff`** | `pgsteal / (pgscank + pgscand)` | ~100 % = easy reclaim; **< 30–40 % = the kernel scans three pages to free one** — thrashing |

`%vmeff` at 39 % with `pgscand` at 90 k/s is unambiguous: this host is spending its CPU looking for memory to free. Add swap traffic for completeness:

```
$ sar -W 1 2
11:21:14  pswpin/s pswpout/s
11:21:15   1204.00    884.00
11:21:16   1312.00    912.00
Average:   1258.00    898.00

$ sar -r -h 1 1
11:21:30    kbmemfree   kbavail  kbmemused  %memused kbbuffers  kbcached  kbcommit   %commit  kbactive   kbinact   kbdirty
11:21:31       1.2G      1.9G      59.8G     93.2%    284.0M      1.1G     55.8G    135.1%     57.1G      1.4G    104.0M
```

Page cache collapsed from 18 GiB to 1.1 GiB, `kbavail` down to 1.9 GiB, swap flowing in both directions at ~1 200 pages/s: a memory-exhaustion event in progress, minutes before the OOM killer acts.

### 4.4 The OOM killer, read correctly

```
$ sudo dmesg -T | grep -A 3 'Out of memory'
[Wed Oct 14 03:41:12 2026] api.jar invoked oom-killer: gfp_mask=0x140cca(GFP_HIGHUSER_MOVABLE|__GFP_COMP), order=0, oom_score_adj=0
[Wed Oct 14 03:41:12 2026] Tasks state (memory values in pages):
[Wed Oct 14 03:41:12 2026] [  pid  ]   uid  tgid total_vm      rss pgtables_bytes swapents oom_score_adj name
[Wed Oct 14 03:41:12 2026] [ 884102]  1001 884102  2103001  1022276      8421376    11028             0 java

$ sudo dmesg -T | grep 'Killed process'
[Wed Oct 14 03:41:12 2026] Out of memory: Killed process 112044 (postgres) total-vm:4812332kB, anon-rss:2201344kB, file-rss:0kB, shmem-rss:1948160kB, UID:108 pgtables:4812kB oom_score_adj:0
```

The critical distinction, and a frequent production misdiagnosis: **the process that invoked the OOM killer is almost never the process that gets killed.** `java` was the allocator that hit the wall; `postgres` was selected as the victim because it had the highest `oom_score`. Reading only the "Killed process" line produces the wrong root cause and the wrong remediation.

```
$ cat /proc/884102/oom_score
742
$ cat /proc/884102/oom_score_adj
0
```

`oom_score_adj` ranges `-1000` (never kill) to `+1000` (kill first) and is biased in units of 1/1000 of total memory. Protect the control plane, sacrifice the batch job:

```
$ echo -800 | sudo tee /proc/$(pidof sshd | cut -d' ' -f1)/oom_score_adj
-800
```

and persist it in the unit, not in a script (Section 9.4 uses `OOMScoreAdjust=`).

### 4.5 cgroup v2: the memory limit the application actually has

```
$ cat /sys/fs/cgroup/system.slice/api.service/memory.max
8589934592
$ cat /sys/fs/cgroup/system.slice/api.service/memory.high
7516192768
$ cat /sys/fs/cgroup/system.slice/api.service/memory.current
8314208256
$ cat /sys/fs/cgroup/system.slice/api.service/memory.events
low 0
high 48112
max 1204
oom 2
oom_kill 2
$ cat /sys/fs/cgroup/system.slice/api.service/memory.stat | head -12
anon 7204118528
file 904112128
kernel 204881920
kernel_stack 12582912
pagetables 88412928
slab 102891520
sock 4194304
shmem 201326592
file_mapped 104857600
file_dirty 8388608
file_writeback 2097152
anon_thp 2147483648
```

`high 48112` means the cgroup crossed `memory.high` 48 112 times, each occurrence applying **reclaim throttling** to the workload — a latency event with no host-level signature at all. `oom_kill 2` means two local OOM kills happened without any global memory pressure. On a container host, `memory.events` and `memory.pressure` are the memory metrics; `free` is background colour.

### 4.6 Kernel memory and slab

```
$ sudo slabtop -o -s c | head -10
 Active / Total Objects (% used)    : 8841204 / 9104882 (97.1%)
 Active / Total Slabs (% used)      : 204112 / 204112 (100.0%)
 Active / Total Caches (% used)     : 142 / 198 (71.7%)
 Active / Total Size (% used)       : 1884.21M / 1912.44M (98.5%)
 Minimum / Average / Maximum Object : 0.01K / 0.21K / 16.00K

  OBJS ACTIVE  USE OBJ SIZE  SLABS OBJ/SLAB CACHE SIZE NAME
4128412 4021884  97%    0.19K  98296       42    786368K dentry
1204884 1188412  98%    0.57K  43031       28    688496K radix_tree_node
 884112  881204  99%    0.10K  22669       39     90676K buffer_head
 412884  402112  97%    1.06K  13763       30    440416K nf_conntrack
```

`dentry` at 786 MiB plus `nf_conntrack` at 440 MiB is kernel memory that `free` reports as `used` and that no process owns. 412 k conntrack entries also ties directly to Section 7.2.

### 4.7 Memory tooling trade-offs

| Tool | Scope | Sharing-aware | Historical | Best for |
|---|---|---|---|---|
| `free -w` | system | n/a | no | `available` vs `free` sanity check |
| `vmstat` (`si`/`so`) | system | n/a | no | detecting swap *traffic* |
| `sar -r -R -B -W -S` | system | n/a | **yes** | post-mortem of a memory event |
| `top` / `ps` (`RSS`) | process | **no** (double counts) | no | quick ranking of offenders |
| `smaps_rollup` (`PSS`/`USS`) | process | yes | no | true attribution, right-sizing |
| `slabtop` | kernel caches | n/a | no | kernel-side growth (dentry, conntrack, inode) |
| `memory.events` / `memory.pressure` | cgroup | yes | no (counters) | the limit the workload truly hit |
| `memleak`, `oomkill` (eBPF) | per allocation | yes | no | leak attribution to call sites |

---

## 5. Disk I/O

### 5.1 `iostat -x`: every column, and the two that are traps

```
$ iostat -xz 5 2
Linux 6.8.0-45-generic (db03)   10/15/2026      _x86_64_        (16 CPU)

avg-cpu:  %user   %nice %system %iowait  %steal   %idle
           7.12    0.00    3.48   41.07    0.00   48.33

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util
nvme0n1       14882.40 186030.00     0.00   0.00    1.84    12.50  412.80  52838.40    12.20   2.87    0.91   128.00    0.00     0.00     0.00   0.00    0.00     0.00   88.20    0.42   27.78   99.80
sdb             184.20  23577.60     2.40   1.29   48.72   128.00   42.60   5452.80     8.20  16.14   91.44   128.00    0.00     0.00     0.00   0.00    0.00     0.00   12.40   84.10   13.86   98.40
```

| Column | Definition | Interpretation |
|---|---|---|
| `r/s`, `w/s`, `d/s`, `f/s` | completed reads, writes, discards, flushes per second | IOPS; `f/s` is fsync/FUA barrier traffic — databases live here |
| `rkB/s`, `wkB/s` | throughput | compare against the device's sequential ceiling |
| `rrqm/s`, `wrqm/s`, `%rrqm`, `%wrqm` | requests merged by the scheduler | high merge % ⇒ sequential access; ~0 % ⇒ random |
| **`r_await`, `w_await`** | mean time per request **including queue time** | the latency the filesystem layer sees |
| `rareq-sz`, `wareq-sz` | mean request size in KiB | 4–16 KiB random vs 128 KiB+ sequential |
| **`aqu-sz`** | mean queue length = `throughput × await` (Little's law) | **the saturation metric** |
| `%util` | share of time with ≥ 1 request in flight | **not a saturation metric on any queued device** |

The two traps, stated precisely:

- **`%util` is `1 - idle_time_fraction`, not "percentage of capacity".** It counts time during which *at least one* request was outstanding. An NVMe device with 64 hardware queues × 1024 entries can be at `%util 100` while servicing 5 % of the IOPS it is capable of. In the capture above, `nvme0n1` at `%util 99.8` with `aqu-sz 27.8` and `r_await 1.84 ms` is **busy and healthy**. `sdb` at `%util 98.4` with `aqu-sz 13.9` and `w_await 91.4 ms` is **dying**. Same `%util`, opposite conclusions. The discriminator is `await`.
- **`svctm` no longer exists** (removed in sysstat 12.x) because it was computed as `%util/throughput` and became meaningless for concurrent devices. If a runbook references `svctm`, the runbook predates your kernel.

Verify concurrency with Little's law yourself: `aqu-sz ≈ (r/s + w/s) × await` → `(14882.4 + 412.8) × 0.00180 s ≈ 27.5`, matching the reported `27.78`. If the arithmetic does not close, you are reading two different intervals.

Useful variants: `iostat -xz 5` (`-z` hides idle devices), `iostat -xm` (MiB), `iostat -p ALL` (per partition), `iostat -xdt 5` (timestamped, drops the CPU block), `iostat -y 5` (skips the since-boot first report — the correct flag for scripts).

### 5.2 `iotop`: attributing I/O to processes

```
$ sudo iotop -oPa -d 5 -n 2 -b
Total DISK READ:       182.44 M/s | Total DISK WRITE:        51.60 M/s
Current DISK READ:     179.12 M/s | Current DISK WRITE:      48.84 M/s
    PID  PRIO  USER     DISK READ  DISK WRITE  SWAPIN      IO    COMMAND
 112044  be/4 postgres    721.04 M     12.44 M  0.00 %  91.24 % postgres: autovacuum worker
 112088  be/4 postgres    688.12 M      8.84 M  0.00 %  88.41 % postgres: autovacuum worker
  88102  be/4 postgres     12.44 M    188.12 M  0.00 %  14.02 % postgres: walwriter
 884102  be/4 app           1.02 M      4.12 M  0.00 %   2.11 % java -Xmx8g -jar api.jar
```

Flags: `-o` only processes doing I/O, `-P` processes not threads, `-a` accumulated totals since start, `-b` batch, `-d` delay, `-n` iterations, `-k` kilobytes.

`iotop` depends on **delay accounting**, which is compiled in but disabled by default since kernel 5.14. The failure is not subtle:

```
$ sudo iotop -oPa
CONFIG_TASK_DELAY_ACCT not enabled in kernel, cannot determine SWAPIN and IO%

$ sysctl kernel.task_delayacct
kernel.task_delayacct = 0
$ sudo sysctl -w kernel.task_delayacct=1
kernel.task_delayacct = 1
```

Persist it (Section 9.2) or every disk incident starts with a tool that cannot answer. Note also that `iotop` attributes **block-layer** I/O: writes appear against the flusher or journal thread when the dirtying process has long returned from `write(2)`. For write attribution, `pidstat -d` plus the dirty-page accounting in Section 5.4 is more truthful.

```
$ pidstat -d 5 1
11:30:04      UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command
11:30:09      108    112044 147812.80   2548.40      0.00    8412  postgres
11:30:09      108     88102   2504.80  38412.00      0.00     884  postgres
11:30:09     1001    884102    208.40    844.80     12.40      42  java
```

`kB_ccwr/s` is write cancelled by truncation; `iodelay` is clock ticks the task spent blocked on I/O — a per-process `%iowait` that actually means something.

### 5.3 Historical and per-device views

```
$ sar -d -p 600 -f /var/log/sa/sa14 | grep -E 'DEV|nvme0n1' | head -6
00:00:01       DEV       tps     rkB/s     wkB/s     dkB/s   areq-sz    aqu-sz     await     %util
00:10:01  nvme0n1    412.44   1884.21  18412.04      0.00     49.21      0.42      1.02      8.41
03:20:01  nvme0n1  15295.20 186030.00  52838.40      0.00     15.62     27.78      1.84     99.80
03:30:01  nvme0n1  15104.80 184112.40  51204.80      0.00     15.58     28.12      1.86     99.80
04:00:01  nvme0n1    488.12   2104.44  19884.12      0.00     45.02      0.48      1.04      9.12

$ sar -b -f /var/log/sa/sa14 | head -5
00:00:01          tps      rtps      wtps      dtps   bread/s   bwrtn/s   bdscd/s
00:10:01       412.44    102.44    310.00      0.00   3768.42  36824.08      0.00
03:20:01     15295.20  14882.40    412.80      0.00 372060.00 105676.80      0.00
```

`-p` prints persistent/pretty device names instead of `dev259-0`. `-f` reads an archived day. This is the capability that lets you answer "what happened at 03:25 last night" — the entire reason Section 9 exists.

### 5.4 Writeback, the dirty-page cliff, and filesystem-level exhaustion

A very common "the disk froze for 20 seconds" incident is not the disk at all:

```
$ grep -E 'Dirty|Writeback' /proc/meminfo
Dirty:           1204884 kB
Writeback:        204112 kB

$ sysctl vm.dirty_background_ratio vm.dirty_ratio vm.dirty_expire_centisecs vm.dirty_writeback_centisecs
vm.dirty_background_ratio = 10
vm.dirty_ratio = 20
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 500
```

At `dirty_background_ratio` the kernel starts writing back asynchronously. At `dirty_ratio` **every writing process is blocked synchronously** until the backlog drains. On a 64 GiB host, `dirty_ratio=20` permits ~12.8 GiB of dirty pages; flushing that to a device doing 150 MiB/s takes ~85 seconds of application stall. On large-memory hosts, use the `*_bytes` variants instead of ratios:

```
$ sudo sysctl -w vm.dirty_background_bytes=268435456 vm.dirty_bytes=1073741824
vm.dirty_background_bytes = 268435456
vm.dirty_bytes = 1073741824
```

Two space-exhaustion failures that `df -h` cannot show:

```
$ df -h /var
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p3  196G   88G  101G  47% /var

$ df -i /var
Filesystem        Inodes   IUsed    IFree IUse% Mounted on
/dev/nvme0n1p3  13107200 13104881     2319  100% /var
```

47 % of the bytes, 100 % of the inodes — writes fail with `ENOSPC` and the space graph looks fine. Millions of small files (session caches, per-request logs, maildirs) do this.

```
$ df -h /var/log
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p4   48G   47G   84M 100% /var/log

$ du -sh /var/log
2.1G    /var/log

$ sudo lsof +L1 | head -5
COMMAND     PID    USER   FD   TYPE DEVICE  SIZE/OFF NLINK     NODE NAME
rsyslogd  88412  syslog    7w   REG  259,4 44104885248     0  1204881 /var/log/app/huge.log (deleted)
java     884102     app  142w   REG  259,4   982441984     0  1204912 /var/log/app/gc.log.1 (deleted)
```

`du` says 2.1 GiB, `df` says 47 GiB: 45 GiB is held by **deleted files that still have open descriptors** (`NLINK 0`). The space returns only when the holder closes the fd or restarts — a logrotate without `copytruncate` or without signalling the daemon is the classic cause. `lsof +L1` (link count < 1) is the command that finds it; `fuser -vm /var/log` lists who is on the filesystem at all.

### 5.5 Measuring the device, not the guesses: `fio`

`iostat` tells you what the workload is doing. To know the ceiling you are approaching you must measure the device directly, with a job file under version control rather than an ad-hoc command line. INI format:

```ini
; /etc/fio/baseline-nvme.fio
; Device characterisation baseline. Run on an idle host, against a RAW DEVICE or
; a preallocated file; never against production data (writes are destructive).
[global]
ioengine=libaio
direct=1
filename=/dev/nvme0n1
runtime=60
time_based=1
ramp_time=10
group_reporting=1
randrepeat=0
norandommap=1
percentile_list=50.0:90.0:99.0:99.9:99.99
log_avg_msec=1000
write_lat_log=/var/tmp/fio-baseline
write_bw_log=/var/tmp/fio-baseline
write_iops_log=/var/tmp/fio-baseline

[lat-floor-randread-qd1]
description=Latency floor: one outstanding 4k read. No queueing, pure device+path latency.
rw=randread
bs=4k
iodepth=1
numjobs=1
stonewall

[iops-ceiling-randread-qd128]
description=IOPS ceiling: 4k random reads, deep queue, 4 workers.
rw=randread
bs=4k
iodepth=128
numjobs=4
stonewall

[bw-ceiling-seqread]
description=Sequential read bandwidth ceiling.
rw=read
bs=1m
iodepth=32
numjobs=1
stonewall

[sync-write-cost-qd1]
description=Journal/WAL cost: 4k synchronous writes with FUA, the database write path.
rw=write
bs=4k
iodepth=1
numjobs=1
sync=1
fdatasync=1
stonewall

[mixed-70r30w]
description=Representative OLTP mix.
rw=randrw
rwmixread=70
bs=8k
iodepth=32
numjobs=4
stonewall
```

```
$ sudo fio /etc/fio/baseline-nvme.fio --section=lat-floor-randread-qd1
lat-floor-randread-qd1: (groupid=0, jobs=1): err= 0: pid=991204: Thu Oct 15 11:38:04 2026
  read: IOPS=12.8k, BW=49.9MiB/s (52.3MB/s)(2995MiB/60001msec)
    clat (usec): min=58, max=1884, avg=76.82, stdev=12.44
     lat percentiles (usec):
     |  50.0000th=[   76], 90.0000th=[   88], 99.0000th=[  104],
     | 99.9000th=[  142], 99.9900th=[  412]
  cpu          : usr=2.14%, sys=8.88%, ctx=768412, majf=0, minf=12
  IO depths    : 1=100.0%, 2=0.0%, 4=0.0%, 8=0.0%
```

From that single number you derive the capacity model: a 77 µs floor at QD1 means a single-threaded, synchronous workload cannot exceed ~13 000 IOPS **no matter how fast the device is**, because it is latency-bound, not bandwidth-bound. The fix is concurrency in the application, not a faster disk — a conclusion no utilization graph will ever produce.

### 5.6 Below `iostat`: latency distributions

Averages hide the tail that causes incidents. Histograms do not:

```
$ sudo biolatency-bpfcc -D 10 1
Tracing block device I/O... Hit Ctrl-C to end.

disk = nvme0n1
     usec               : count     distribution
        32 -> 63        : 88412    |****************************************|
        64 -> 127       : 41204    |******************                      |
       128 -> 255       : 8841     |****                                    |
       256 -> 511       : 1204     |                                        |
       512 -> 1023      : 412      |                                        |

disk = sdb
     usec               : count     distribution
      2048 -> 4095      : 184      |****                                    |
      4096 -> 8191      : 412      |**********                              |
      8192 -> 16383     : 884      |*********************                   |
     16384 -> 32767     : 1684     |****************************************|
     32768 -> 65535     : 1204     |****************************            |
     65536 -> 131071    : 884      |*********************                   |
    131072 -> 262143    : 412      |**********                              |
```

`sdb` is bimodal around 16–65 ms with a tail past 131 ms — a profile consistent with a failing drive, a degraded RAID rebuild, or a thin-provisioned LUN under remote contention. The mean `await` of 91 ms described none of that shape.

Also useful: `biosnoop-bpfcc` (per-I/O trace with PID and latency), `blktrace -d /dev/sdb -o - | blkparse -i -` (full block-layer event trace), and the per-queue tunables you should check before blaming hardware:

```
$ cat /sys/block/nvme0n1/queue/scheduler
[none] mq-deadline kyber bfq
$ cat /sys/block/sdb/queue/scheduler
[mq-deadline] kyber bfq none
$ grep . /sys/block/sdb/queue/{nr_requests,read_ahead_kb,rotational,nomerges,wbt_lat_usec,max_sectors_kb}
/sys/block/sdb/queue/nr_requests:64
/sys/block/sdb/queue/read_ahead_kb:128
/sys/block/sdb/queue/rotational:1
/sys/block/sdb/queue/nomerges:0
/sys/block/sdb/queue/wbt_lat_usec:75000
/sys/block/sdb/queue/max_sectors_kb:512
```

### 5.7 Disk tooling trade-offs

| Tool | Layer | Attribution | Distribution | Overhead | Best for |
|---|---|---|---|---|---|
| `iostat -xz` | block device | none | mean only | ~0 | first look; `await` + `aqu-sz` |
| `sar -d -p` / `sar -b` | block device | none | mean only | ~0 | historical, capacity trends |
| `iotop` | block device | per task | none | low | "who is reading the disk right now" |
| `pidstat -d` | task | per task | none | low | scripted per-process I/O + `iodelay` |
| `biolatency` | block device | optional | **histogram** | low | tail latency, bimodality |
| `biosnoop` | block device | per I/O + PID | per event | medium | rare outliers, correlation |
| `blktrace`/`blkparse` | full block layer | per I/O | per event | **high** | merge/queue/scheduler forensics |
| `fio` | block or FS | synthetic | percentiles | destructive | **ceilings and floors** |
| `df -h` / `df -i` / `du` / `lsof +L1` | filesystem | per file/fd | n/a | ~0 | space and inode exhaustion |

---

## 6. Network I/O

### 6.1 Interface counters and errors

```
$ ip -s -h link show eth0
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 9000 qdisc fq_codel state UP mode DEFAULT group default qlen 1000
    link/ether 3c:ec:ef:11:22:33 brd ff:ff:ff:ff:ff:ff
    RX:    bytes  packets errors dropped  missed   mcast
       188.4G    412.8M      0   84.1k    12.4k    1.2k
    TX:    bytes  packets errors dropped carrier collsns
        91.2G    204.1M      0       0       0       0
```

| Counter | Meaning | Typical cause |
|---|---|---|
| RX `errors` | malformed frames (CRC, frame, length) | cable, SFP, duplex mismatch, bad optics |
| RX `dropped` | received but discarded by the **kernel** | no socket buffer space, no qdisc room, VLAN/protocol not handled |
| RX `missed` / `overrun` | the **NIC** had no descriptor | ring buffer too small, softirq budget exhausted, CPU 0 saturated |
| TX `dropped` | discarded on transmit | qdisc queue full, `txqueuelen` too small |
| TX `carrier` | link-layer carrier transitions | flapping link, autoneg renegotiation |

The split matters: RX `missed` is a **hardware/ring** problem (Section 7.4 fixes it with `ethtool -G` and queue spreading), while RX `dropped` with zero `missed` is a **socket buffer** problem (application not reading fast enough, or `net.core.rmem_max` too small).

Driver-level counters are more specific than the generic ones:

```
$ ethtool -S eth0 | grep -E 'drop|miss|err|no_buf|fifo|discard' | grep -v ': 0$'
     rx_missed_errors: 12412
     rx_no_buffer_count: 8841
     rx_fifo_errors: 12412
     rx_queue_0_drops: 84112

$ ethtool -g eth0
Ring parameters for eth0:
Pre-set maximums:
RX:             4096
RX Mini:        n/a
RX Jumbo:       n/a
TX:             4096
Current hardware settings:
RX:             512
TX:             512

$ ethtool -l eth0
Channel parameters for eth0:
Pre-set maximums:
RX:             0
TX:             0
Other:          1
Combined:       16
Current hardware settings:
Combined:       1
```

RX ring at 512 of a possible 4096, and **one** combined queue of 16 available: the root cause of both the softirq imbalance in Section 3.4 and the `rx_missed_errors` here.

### 6.2 `ss` — the socket-level truth

```
$ ss -ltn
State      Recv-Q     Send-Q            Local Address:Port        Peer Address:Port
LISTEN     0          4096                    0.0.0.0:443              0.0.0.0:*
LISTEN     129        128                     0.0.0.0:8080             0.0.0.0:*
LISTEN     0          4096                  127.0.0.1:5432              0.0.0.0:*
```

**For `LISTEN` sockets the two queue columns change meaning entirely**, and this is both an exam favourite and a real production diagnostic:

| Column | On `LISTEN` | On `ESTAB` |
|---|---|---|
| `Recv-Q` | connections **completed and waiting to be `accept()`ed** | bytes received, not yet read by the application |
| `Send-Q` | the **accept queue size** (effective backlog) | bytes sent, not yet ACKed by the peer |

`:8080` with `Recv-Q 129` against `Send-Q 128` is an **overflowing accept queue**: the application is not calling `accept()` fast enough, and the kernel is dropping new connections. Clients see timeouts or connection resets while CPU, memory and disk all look fine. The proof is in the counters, not the gauge:

```
$ nstat -az | grep -E 'TcpExtListenOverflows|TcpExtListenDrops|TcpExtSyncookies'
TcpExtSyncookiesSent            0                  0.0
TcpExtSyncookiesRecv            0                  0.0
TcpExtListenOverflows           184412             0.0
TcpExtListenDrops               184412             0.0

$ nstat -n && sleep 10 && nstat | grep -E 'Overflow|Drop|Retrans'
#kernel
TcpExtListenOverflows           1204               0.0
TcpExtListenDrops               1204               0.0
TcpExtTCPSynRetrans             84                 0.0
```

120 overflows per second, currently. `nstat` without `-a` prints **deltas since the last run** (state in `/tmp/.nstat.u<uid>`), which is what you want during an incident; `nstat -n` resets the baseline. This is strictly better than `netstat -s` for the same data:

```
$ netstat -s | grep -A 2 -E 'listen|segments retransmit'
    184412 times the listen queue of a socket overflowed
    184412 SYNs to LISTEN sockets dropped
    1204881 segments retransmitted
```

The backlog is the minimum of what the application asked for and the system cap:

```
$ sysctl net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_abort_on_overflow
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 1024
net.ipv4.tcp_abort_on_overflow = 0
```

`somaxconn` is 4096 but this socket's backlog is 128 — therefore the application passed `listen(fd, 128)`. Raising `somaxconn` changes nothing here; the fix is in the application config (nginx `backlog=`, gunicorn `--backlog`, Java `SO_BACKLOG`).

Per-connection TCP internals, which is where throughput questions get answered:

```
$ ss -tiepm 'dst 203.0.113.44'
ESTAB  0  4194304  10.20.0.90:443  203.0.113.44:51234
         users:(("nginx",pid=88412,fd=142)) timer:(on,208ms,0) uid:33 ino:1204881 sk:4f2c <->
         skmem:(r0,rb6291456,t0,tb4194304,f4096,w4198400,o0,bl0,d12)
         bbr wscale:7,7 rto:312 rtt:84.112/2.441 mss:1448 pmtu:9000 rcvmss:536 advmss:8948
         cwnd:142 ssthresh:98 bytes_sent:1884120448 bytes_retrans:18841204 bytes_acked:1865279244
         segs_out:1301204 segs_in:412884 data_segs_out:1300118
         bbr:(bw:628.4Mbps,mrtt:81.204,pacing_gain:1.25,cwnd_gain:2) send 19.6Mbps lastsnd:4
         pacing_rate 785.5Mbps delivery_rate 612.1Mbps busy:184112ms rwnd_limited:84112ms(45.7%)
         retrans:0/1284 dsack_dups:84 reordering:12 rcv_rtt:88.4 rcv_space:14480 minrtt:81.204
```

What this single block proves:

- `rtt:84.112` with `mss:1448` and `cwnd:142` → in-flight ≈ `142 × 1448 = 205 KiB`; over an 84 ms RTT that is ~19.6 Mbit/s, exactly the `send 19.6Mbps` figure.
- **`rwnd_limited:84112ms(45.7%)`** — for 45.7 % of the connection's busy time the *receiver's* window was the limit. The sender is not the problem, the network is not the problem, and no amount of extra bandwidth will help. This is the single most valuable field in `ss` output and has no equivalent anywhere in `netstat`.
- `bytes_retrans / bytes_sent = 1 %` — enough to keep CUBIC/BBR out of its optimal regime.
- `skmem:(rb6291456,tb4194304)` — actual socket buffer sizes, i.e. whether autotuning reached the configured maximum.

Everyday `ss` forms worth having in muscle memory:

```
$ ss -s
Total: 118427
TCP:   117981 (estab 116204, closed 1431, orphaned 0, timewait 1402)

Transport Total     IP        IPv6
RAW       1         0         1
UDP       14        10        4
TCP       116550    114204    2346
INET      116565    114214    2351
FRAG      0         0         0

$ ss -tan state time-wait | wc -l
1402

$ ss -tn state established '( dport = :5432 or sport = :5432 )' | head -3
Recv-Q Send-Q      Local Address:Port       Peer Address:Port
0      0            10.20.0.90:48122         10.20.0.31:5432
0      0            10.20.0.90:48124         10.20.0.31:5432

$ ss -uap 'sport = :53'
State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
UNCONN 212992 0            0.0.0.0:53        0.0.0.0:*     users:(("unbound",pid=1204,fd=4))

$ ss -K 'dst 198.51.100.7'
```

`Recv-Q 212992` on a UDP socket is a **full receive buffer** — datagrams are being dropped right now; cross-check with `nstat -az | grep UdpRcvbufErrors`. `ss -K` destroys matching sockets (needs `CONFIG_INET_DIAG_DESTROY` and root) — a real remediation tool, not just a viewer.

### 6.3 `netstat` vs `ss` vs `nstat` vs `ip`

| Task | Legacy | Modern | Why the modern one |
|---|---|---|---|
| list sockets | `netstat -tulpn` | `ss -tulpn` | netlink, kernel-side filtering, orders of magnitude faster |
| socket summary | `netstat -s` | `nstat` / `nstat -az` | deltas by default, machine-readable, one line per counter |
| routing table | `netstat -rn` | `ip route show` / `ip -4 route get 8.8.8.8` | policy routing, multiple tables, `get` shows the actual decision |
| interface stats | `netstat -i` | `ip -s link` / `ethtool -S` | driver-level detail, error taxonomy |
| ARP/neighbours | `arp -an` | `ip neigh show` | IPv6 NDP included, states (`REACHABLE`, `STALE`, `FAILED`) |
| multicast | `netstat -g` | `ip maddr show` | consistent interface |
| masquerade/conntrack | `netstat -M` | `conntrack -L` | nftables/nf_conntrack era |

```
$ ip -4 route get 203.0.113.44
203.0.113.44 via 10.20.0.1 dev eth0 src 10.20.0.90 uid 0
    cache

$ ip -s -s link show eth0 | tail -6
    TX: bytes  packets errors dropped carrier collsns
    91234567890 204112884      0       0       0       0
    TX errors: aborted  fifo   window heartbeat transns
               0        0      0      0         4
```

`ip -s -s` (twice) prints the extended error breakdown, including `transns` — link transitions, i.e. flapping.

### 6.4 Historical network data with `sar`

```
$ sar -n DEV --iface=eth0 600 -f /var/log/sa/sa14 | head -6
00:00:01     IFACE   rxpck/s   txpck/s    rxkB/s    txkB/s   rxcmp/s   txcmp/s  rxmcst/s   %ifutil
00:10:01      eth0  48112.44  41204.80  58412.04  44112.80      0.00      0.00      0.42     18.44
03:20:01      eth0 884112.40 112044.80 128412.44  12884.04      0.00      0.00      0.44     41.02
03:30:01      eth0 891204.80 118412.40 129884.12  13204.44      0.00      0.00      0.48     41.44

$ sar -n EDEV --iface=eth0 600 -f /var/log/sa/sa14 | head -4
00:00:01     IFACE   rxerr/s   txerr/s    coll/s  rxdrop/s  txdrop/s  txcarr/s  rxfram/s  rxfifo/s  txfifo/s
03:20:01      eth0      0.00      0.00      0.00    412.44      0.00      0.00      0.00    188.40      0.00

$ sar -n TCP,ETCP,SOCK 600 -f /var/log/sa/sa14 | head -8
00:00:01    totsck    tcpsck    udpsck    rawsck   ip-frag    tcp-tw
03:20:01    118427    116550        14         1         0      1402

00:00:01  active/s passive/s    iseg/s    oseg/s
03:20:01   1204.44  18412.80 412884.40 388112.44

00:00:01  atmptf/s  estres/s retrans/s isegerr/s   orsts/s
03:20:01    184.40     12.44   1204.88      0.42   1884.12
```

The decisive observation: at 03:20 the packet rate jumped to **884 k packets/s** while bandwidth only reached 128 MB/s and `%ifutil` 41 %. Mean packet size ≈ 145 bytes. This host is **packet-rate bound, not bandwidth bound** — and `rxfifo/s 188` plus `rxdrop/s 412` confirms the NIC ring and softirq path gave up long before the link did. Buying more bandwidth would change nothing; `ethtool -L`/`-G` and queue spreading would.

`sar -n` keyword set: `DEV`, `EDEV`, `NFS`, `NFSD`, `SOCK`, `IP`, `EIP`, `ICMP`, `EICMP`, `TCP`, `ETCP`, `UDP`, `SOCK6`, `IP6`, `EIP6`, `ICMP6`, `EICMP6`, `UDP6`, `FC`, `SOFT`, `ALL`.

### 6.5 Network tooling trade-offs

| Tool | Resolution | Per-connection | Per-process | Historical | Cost |
|---|---|---|---|---|---|
| `ip -s link` | interface, cumulative | no | no | no | ~0 |
| `ethtool -S` | driver queue | no | no | no | ~0 |
| `sar -n DEV/EDEV/TCP` | interval | no | no | **yes** | ~0 |
| `ss -tiepm` | socket, instantaneous | **yes, deep** | yes | no | low |
| `nstat` | stack counters, delta | no | no | no | ~0 |
| `netstat -s` | stack counters, cumulative | no | no | no | low |
| `iftop` | host pair, live | aggregated | no | no | promiscuous capture |
| `iptraf-ng` | connection + interface | yes | no | logfile | capture-bound |
| `nload` / `bmon` | interface, live graph | no | no | no | ~0 |
| NetFlow/IPFIX (`nfdump`, Akvorado) | flow records | yes | no | **yes, long term** | exporter CPU + storage |
| `tcplife`, `tcpretrans` (eBPF) | per connection lifetime | yes | **yes** | no | low |
| `tcpdump`/`tshark` | per packet | yes | no | pcap | **high** — can itself drop packets |

---

## 7. Firewalling and routing throughput

This is the objective's least-practised area and the one that produces the most confusing incidents, because a saturated firewall path does not look like a saturated resource: it looks like *the network is losing packets*.

### 7.1 The real limit is packets per second, not bits per second

Every firewall and routing decision is per packet. Link capacity is quoted in bits per second. The conversion is where capacity plans die.

Ethernet frame = payload + 14 B header + 4 B FCS (64 B minimum). On the wire each frame also costs 8 B preamble/SFD + 12 B inter-frame gap, so bytes on wire = frame + 20. The rows below are frame sizes, with the payload they carry:

| Frame (payload) | Bytes on wire | 1 GbE | 10 GbE | 25 GbE |
|---|---|---|---|---|
| 64 B (46 B, minimum frame) | 84 | 1.488 Mpps | 14.88 Mpps | 37.2 Mpps |
| 128 B (110 B) | 148 | 844 kpps | 8.45 Mpps | 21.1 Mpps |
| 512 B (494 B) | 532 | 234 kpps | 2.35 Mpps | 5.87 Mpps |
| 1518 B (1500 B, standard MTU) | 1538 | 81.3 kpps | 812.7 kpps | 2.03 Mpps |
| 9018 B (9000 B, jumbo) | 9038 | 13.8 kpps | 138.3 kpps | 345.8 kpps |

How many packets per second one core can push through conntrack and a ruleset depends on the CPU, the NIC, the driver and the ruleset; there is no figure to memorize, it has to be measured on the box, as shown just below. The point of the table is the ratio:

- A 10 GbE link carrying full-size frames (1500 B payload) needs ~813 kpps.
- The same link carrying minimum-size frames (DNS, VoIP, SYN flood, telemetry) needs 14.88 Mpps, eighteen times the packet rate at the same bit rate; a single-queue software firewall reaches its packet limit long before the link is full. You will see 8 % `%ifutil` and massive drops simultaneously.

Measure the actual packet rate, never infer it from bandwidth:

```
$ sar -n DEV --iface=eth0 1 3
11:48:01     IFACE   rxpck/s   txpck/s    rxkB/s    txkB/s   rxcmp/s   txcmp/s  rxmcst/s   %ifutil
11:48:02      eth0 884112.40 112044.80 128412.44  12884.04      0.00      0.00      0.44     41.02
```

### 7.2 Connection tracking: the table that fills silently

```
$ sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max net.netfilter.nf_conntrack_buckets
net.netfilter.nf_conntrack_count = 412884
net.netfilter.nf_conntrack_max = 425984
net.netfilter.nf_conntrack_buckets = 106496

$ sudo dmesg -T | grep -i conntrack | tail -3
[Wed Oct 14 03:24:51 2026] nf_conntrack: nf_conntrack: table full, dropping packet
[Wed Oct 14 03:24:51 2026] nf_conntrack: nf_conntrack: table full, dropping packet
[Wed Oct 14 03:24:52 2026] nf_conntrack: nf_conntrack: table full, dropping packet

$ sudo conntrack -S | head -4
cpu=0   found=1204881 invalid=4112 insert=0 insert_failed=184412 drop=184412 early_drop=0 error=0 search_restart=88412 clash_resolve=1204 chaintoolong=0
cpu=1   found=1188412 invalid=3984 insert=0 insert_failed=182044 drop=182044 early_drop=0 error=0 search_restart=87112 clash_resolve=1188 chaintoolong=0

$ sudo conntrack -L -p tcp --state TIME_WAIT 2>/dev/null | wc -l
388412
```

97 % full, 184 k `insert_failed` per CPU, and 388 k of the 412 k entries are `TIME_WAIT`. The table is full of corpses. Two orthogonal fixes:

```
$ sysctl net.netfilter.nf_conntrack_tcp_timeout_time_wait net.netfilter.nf_conntrack_tcp_timeout_established
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 120
net.netfilter.nf_conntrack_tcp_timeout_established = 432000

$ sudo sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
$ sudo sysctl -w net.netfilter.nf_conntrack_max=1048576
net.netfilter.nf_conntrack_max = 1048576
$ echo 262144 | sudo tee /sys/module/nf_conntrack/parameters/hashsize
262144
```

Note `nf_conntrack_tcp_timeout_established = 432000` (5 days) is the default and is almost always wrong for a busy edge: it pins an entry for five days after the last packet. Sizing arithmetic: each entry is ~320 B of `SUnreclaim` slab (see Section 4.6), so 1 048 576 entries ≈ 320 MiB of unreclaimable kernel memory. **Raising `nf_conntrack_max` without budgeting that memory converts a packet-drop incident into an OOM incident.** Keep `hashsize ≈ max/4` or the hash degenerates into linked-list walks (`search_restart`, `chaintoolong`).

The structurally better answer for high-rate, stateless paths is to not track at all:

```
table inet raw {
    chain prerouting {
        type filter hook prerouting priority raw; policy accept;
        ip daddr 10.20.0.90 tcp dport 443 notrack
        ip protocol udp udp dport 53 notrack
    }
}
```

### 7.3 Ruleset evaluation cost: chains vs sets

A packet traverses every rule until it matches. With `iptables`, a 5 000-rule chain is 5 000 comparisons per packet; at 1 Mpps that is 5 × 10⁹ comparisons per second. `nftables` sets and maps are hash/interval lookups — O(1) or O(log n) — and this is the single largest firewall throughput factor after conntrack.

| Approach | Lookup cost | 50 k blocked prefixes | Update cost | Verdict |
|---|---|---|---|---|
| `iptables` linear chain | O(n) | unusable (~50 k compares/packet) | full ruleset reload | never |
| `ipset` hash set | O(1) | fine | atomic per-entry add/del | good with legacy iptables |
| `nftables` named set | O(1) / O(log n) for intervals | fine | atomic, transactional | **preferred** |
| `nftables` verdict map | O(1) + jump | fine | atomic | best for per-tenant policy |
| `nftables` flowtable | **bypasses the stack** after the first packet | n/a | n/a | best for routed forwarding throughput |

```
$ sudo nft list ruleset | head -30
table inet filter {
    set blocklist_v4 {
        type ipv4_addr
        flags interval
        counter
        elements = { 198.51.100.0/24, 203.0.113.128/25 }
    }

    counter dropped_blocklist {
        packets 1884112 bytes 128412884
    }

    chain input {
        type filter hook input priority filter; policy drop;
        ct state established,related accept
        iif "lo" accept
        ip saddr @blocklist_v4 counter name dropped_blocklist drop
        tcp dport { 22, 443 } ct state new limit rate 2000/second burst 500 packets accept
        ip protocol icmp icmp type echo-request limit rate 10/second accept
        counter
    }
}

$ sudo nft list counter inet filter dropped_blocklist
table inet filter {
    counter dropped_blocklist {
        packets 1884112 bytes 128412884
    }
}
```

Measure where the time goes — `perf` names the function, which is the only non-speculative answer:

```
$ sudo perf top -e cycles:k --sort symbol -d 5 | head -12
Samples: 1M of event 'cycles:k', 4000 Hz, Event count (approx.): 184112884412
Overhead  Symbol
  18.44%  [k] nft_do_chain
  12.08%  [k] __nf_conntrack_find_get
   9.12%  [k] nf_conntrack_tuple_taken
   7.84%  [k] fib_table_lookup
   6.41%  [k] napi_poll
   5.12%  [k] dev_queue_xmit
   4.88%  [k] __memcpy
   3.42%  [k] nft_lookup_eval
```

31 % of kernel cycles in `nft_do_chain` + conntrack lookup is the quantitative statement "the firewall is the bottleneck".

### 7.4 Softirq, rings and the receive path

```
$ sysctl net.core.netdev_budget net.core.netdev_budget_usecs net.core.netdev_max_backlog
net.core.netdev_budget = 300
net.core.netdev_budget_usecs = 8000
net.core.netdev_max_backlog = 1000

$ awk 'NR==1 || /^ *[0-9]+:/ {print}' /proc/net/softnet_stat | head -4
00f2a1b4 00001e44 0000012c 00000000 00000000 00000000 00000000 00000000 00000000 00000412 00000000
000841aa 00000000 00000004 00000000 00000000 00000000 00000000 00000000 00000000 00000012 00000000
```

`/proc/net/softnet_stat` columns 1–3 are `processed`, **`dropped`** (backlog full), **`time_squeeze`** (NAPI ran out of budget before draining the ring) per CPU. Non-zero column 2 means `netdev_max_backlog` is too small; non-zero column 3 means `netdev_budget` is too small or that CPU is overloaded. Both appear as `rx_missed_errors` at the NIC and as "the network is dropping packets" in the ticket.

Remediation, in order of effectiveness:

```
$ sudo ethtool -L eth0 combined 16
$ sudo ethtool -G eth0 rx 4096 tx 4096
$ sudo sysctl -w net.core.netdev_budget=1200 net.core.netdev_max_backlog=16384
net.core.netdev_budget = 1200
net.core.netdev_max_backlog = 16384

$ for q in /sys/class/net/eth0/queues/rx-*; do echo ffff | sudo tee $q/rps_cpus > /dev/null; done
$ sudo sysctl -w net.core.rps_sock_flow_entries=32768
net.core.rps_sock_flow_entries = 32768
$ for q in /sys/class/net/eth0/queues/rx-*; do echo 2048 | sudo tee $q/rps_flow_cnt > /dev/null; done

$ ethtool -c eth0 | grep -E 'rx-usecs|rx-frames|Adaptive'
Adaptive RX: on  TX: on
rx-usecs: 8
rx-frames: 0
```

Multi-queue (`-L`) spreads interrupts across cores in hardware and is strictly better than RPS; RPS is the software fallback for single-queue NICs and virtio.

### 7.5 Queue discipline — the egress side

```
$ tc -s qdisc show dev eth0
qdisc fq_codel 8001: root refcnt 9 limit 10240p flows 1024 quantum 9000 target 5ms interval 100ms memory_limit 32Mb ecn drop_batch 64
 Sent 91234567890 bytes 204112884 pkt (dropped 18412, overlimits 0 requeues 1204)
 backlog 1842960b 204p requeues 1204
  maxpacket 9000 drop_overlimit 0 new_flow_count 884112 ecn_mark 41204
  new_flows_len 2 old_flows_len 14
```

`backlog 204p` with `dropped 18412` and `ecn_mark 41204` says the egress queue is actively congested — packets are being marked and dropped *on this host*, before they ever reach the network. Standing backlog is queueing latency added to every flow. `tc -s class show dev eth0` plus `tc -s filter show dev eth0` extend this to shaped, per-class setups.

---

## 8. Mapping client bandwidth usage

"Which client is consuming the bandwidth" requires a tool that aggregates by address pair, which none of the system tools in Sections 3–6 do.

### 8.1 `iptraf-ng`

`iptraf-ng` (the maintained fork of `iptraf`, and the binary present on current distributions) is a curses front end with five relevant modes. It is also scriptable in background mode, which is how it belongs in a runbook:

```
$ sudo iptraf-ng -i eth0 -B -L /var/log/iptraf-ng/eth0-detail.log -t 15
$ sudo iptraf-ng -s eth0 -B -L /var/log/iptraf-ng/eth0-ports.log -t 15
$ sudo iptraf-ng -z eth0 -B -L /var/log/iptraf-ng/eth0-pktsize.log -t 15
$ sudo iptraf-ng -l eth0 -B -L /var/log/iptraf-ng/eth0-lan.log -t 15
```

| Flag | Mode | Answers |
|---|---|---|
| `-i <iface>` / `-i all` | IP traffic monitor | per-TCP-connection and per-datagram rates, with flags and window sizes |
| `-d <iface>` | detailed interface statistics | total/incoming/outgoing rates, by protocol, interface utilization |
| `-s <iface>` | TCP/UDP service monitor | **per-port** byte and packet rates |
| `-z <iface>` | packet size distribution | whether you are bandwidth-bound or packet-bound |
| `-l <iface>` / `-l all` | LAN station monitor | **per-MAC-address** rates — the per-client view |
| `-B` | background (daemonize) | unattended capture |
| `-L <file>` | logfile | persistence |
| `-t <min>` | run for N minutes then exit | bounded capture |

A LAN station monitor capture:

```
$ sudo tail -14 /var/log/iptraf-ng/eth0-lan.log

*** LAN station monitor started Thu Oct 15 11:58:04 2026

 Ethernet address        Total   Total    Incoming  Incoming   Outgoing  Outgoing
                       Packets   Bytes     Packets    Bytes      Packets   Bytes
 3c:ec:ef:11:22:33    18841204 24118412884  8841204 2118412884  10000000 22000000000
 b8:27:eb:04:12:88     8412004  9884112044  4112044 1204881204   4299960  8679230840
 00:16:3e:44:12:04      412884   188412004   204881   88412004     208003   99999999

*** LAN station monitor stopped Thu Oct 15 12:13:04 2026
```

Important limitations to state before anyone builds a billing system on this: `iptraf-ng` reads from a raw `AF_PACKET` socket, so (a) it only sees traffic that reaches **this** interface — on a switched network that is this host's traffic plus broadcast/multicast, unless the switch port is mirroring; (b) the LAN station monitor keys on **MAC address**, which beyond the local segment is just the router; (c) at high packet rates the capture socket itself drops, so its totals are a lower bound. Validate against the interface counters:

```
$ cat /proc/net/softnet_stat | awk '{s+=strtonum("0x"$2)} END {print "backlog drops:", s}'
backlog drops: 1042
```

### 8.2 Live per-pair view and durable accounting

```
$ sudo iftop -i eth0 -n -N -P -t -s 10 2>/dev/null | head -14
interface: eth0
IP address is: 10.20.0.90
MAC address is: 3c:ec:ef:11:22:33
Listening on eth0
   # Host name (port/service)         last 2s   last 10s   last 40s cumulative
--------------------------------------------------------------------------------
   1 10.20.0.90:443                =>    412Mb      388Mb      402Mb      1.96GB
     203.0.113.44:51234            <=   18.4Mb     17.2Mb     18.1Mb      88.4MB
   2 10.20.0.90:443                =>    188Mb      184Mb      186Mb       908MB
     198.51.100.12:44122           <=   8.41Mb     8.12Mb     8.22Mb      40.1MB
--------------------------------------------------------------------------------
Total send rate:                        882Mb       871Mb       884Mb
Total receive rate:                    44.1Mb      42.8Mb      43.4Mb
```

For accounting that must be exact, cheap and permanent, do not capture packets — use kernel counters, which are maintained in the forwarding path at no extra cost:

```
table inet accounting {
    map client_bytes_v4 {
        type ipv4_addr : counter
        elements = {
            10.20.10.11 : counter packets 0 bytes 0,
            10.20.10.12 : counter packets 0 bytes 0,
            10.20.10.13 : counter packets 0 bytes 0
        }
    }

    chain forward_accounting {
        type filter hook forward priority filter - 10; policy accept;
        counter name ip saddr map @client_bytes_v4
        counter name ip daddr map @client_bytes_v4
    }
}
```

```
$ sudo nft -j list map inet accounting client_bytes_v4 | jq -r '
    .nftables[] | select(.map) | .map.elem[] |
    "\(.[0]) \(.[1].counter.bytes) \(.[1].counter.packets)"'
10.20.10.11 128412884412 188412004
10.20.10.12 41204881204 88412004
10.20.10.13 8841204884 12044881
```

| Method | Exactness | Cost at 1 Mpps | Retention | Identifies |
|---|---|---|---|---|
| `iptraf-ng` / `iftop` (AF_PACKET) | lower bound; drops under load | high (full copy to userspace) | logfile | IP pair, MAC, port |
| `nftables` counters/maps | **exact** | negligible | until flush; scrape to TSDB | whatever you key on |
| `tc` filters with `action police`/counters | exact | negligible | until reload | class, flow |
| `conntrack -L -o extended` accounting | per flow, exact | low (needs `nf_conntrack_acct=1`) | flow lifetime | full 5-tuple |
| NetFlow/IPFIX/sFlow export | sampled (sFlow) or per-flow | low–medium | **months, off-box** | flow, AS, interface |
| eBPF per-cgroup/per-socket | exact, per process | low | as designed | **process and container** |

```
$ sysctl net.netfilter.nf_conntrack_acct
net.netfilter.nf_conntrack_acct = 0
$ sudo sysctl -w net.netfilter.nf_conntrack_acct=1
net.netfilter.nf_conntrack_acct = 1
$ sudo conntrack -L -o extended 2>/dev/null | head -2
ipv4     2 tcp      6 431998 ESTABLISHED src=10.20.10.11 dst=10.20.0.90 sport=48122 dport=443 packets=184112 bytes=224118412 src=10.20.0.90 dst=10.20.10.11 sport=443 dport=48122 packets=88412 bytes=1204881204 [ASSURED] mark=0 use=1
```

---

## 9. Infrastructure: deploying the measurement substrate

Everything above is useless during an incident if it was not installed and collecting beforehand. This section is the complete, idempotent deployment.

### 9.1 `sysstat` architecture

| Component | Role |
|---|---|
| `sadc` | the collector — reads `/proc` and `/sys`, appends a binary record |
| `/var/log/sa/sa<DD>` | daily binary datafile (one per day of month, rotated by overwrite) |
| `/var/log/sa/sar<DD>` | daily **text** summary produced by `sa2` |
| `sa1` | wrapper that invokes `sadc` once (driven by cron or `sysstat-collect.timer`) |
| `sa2` | daily report + housekeeping (`sysstat-summary.timer`) |
| `sar` | reads a datafile (default: today's) and formats it |
| `sadf` | exports a datafile to CSV / XML / JSON / SVG for other tools |

The collection interval is the hard limit on everything you will ever be able to see. The default of 10 minutes is a choice to be made deliberately:

| Interval | Bytes/day (approx., full `-S ALL`) | Shortest visible event | Appropriate for |
|---|---|---|---|
| 10 min (default) | ~1.5 MB | ~20 min | capacity trending only |
| 2 min | ~7 MB | ~4 min | general production default |
| 1 min | ~14 MB | ~2 min | latency-sensitive services |
| 10 s | ~85 MB | ~20 s | debugging a known, reproducing incident (temporary) |

A 10-minute average cannot represent a 90-second stall; it will show a 15 % bump. **One minute is the defensible production default** — the cost is ~14 MB/day against the alternative of having no data at all.

### 9.2 Ansible playbook — complete

```yaml
---
# site-observability.yml
# Deploys the resource-measurement substrate on every Linux host:
#   - sysstat (sadc/sar) as a 1-minute flight recorder with 28 days of history
#   - the full interactive toolchain (iostat, iotop, ss, iptraf-ng, fio, ethtool)
#   - the sysctl settings those tools require in order to report anything
#   - node_exporter with the PSI, cgroup and per-process collectors enabled
# Idempotent: safe to re-run; nothing is restarted unless its input changed.
- name: Resource measurement substrate
  hosts: linux_fleet
  become: true
  gather_facts: true

  vars:
    sysstat_history_days: 28
    sysstat_compress_after_days: 7
    # Quoted: a bare *:00/1 would be parsed by YAML as an alias node.
    sysstat_collect_calendar: "*:00/1"
    sysstat_summary_calendar: "00:07:00"
    node_exporter_version: "1.8.2"
    node_exporter_user: node_exp
    node_exporter_listen: "127.0.0.1:9100"
    node_exporter_textfile_dir: /var/lib/node_exporter/textfile_collector
    measurement_packages:
      - sysstat
      - procps
      - iotop
      - iproute2
      - lsof
      - iptraf-ng
      - fio
      - ethtool
      - numactl
      - psmisc
      - conntrack
      - nftables
    measurement_sysctls:
      # iotop and pidstat -d report nothing at all without delay accounting.
      - key: kernel.task_delayacct
        value: "1"
      # Let unprivileged tooling read perf events for its own processes.
      - key: kernel.perf_event_paranoid
        value: "1"
      # Keep writeback backlog bounded in time rather than as a share of RAM:
      # on a large-memory host, dirty_ratio=20 permits multi-second write stalls.
      - key: vm.dirty_background_bytes
        value: "268435456"
      - key: vm.dirty_bytes
        value: "1073741824"
      # Receive-path headroom; without it, bursts show up as rx_missed_errors.
      - key: net.core.netdev_max_backlog
        value: "16384"
      - key: net.core.netdev_budget
        value: "1200"
      # Byte accounting per conntrack entry, for client bandwidth attribution.
      - key: net.netfilter.nf_conntrack_acct
        value: "1"

  handlers:
    - name: Reload systemd
      ansible.builtin.systemd_service:
        daemon_reload: true

    - name: Restart node_exporter
      ansible.builtin.systemd_service:
        name: node_exporter
        state: restarted

  tasks:
    - name: Install the measurement toolchain
      ansible.builtin.package:
        name: "{{ measurement_packages }}"
        state: present

    - name: Install eBPF tooling where the kernel supports it
      ansible.builtin.package:
        name: "{{ (ansible_os_family == 'Debian') | ternary('bpfcc-tools', 'bcc-tools') }}"
        state: present
      when: ansible_kernel is version('5.4', '>=')
      failed_when: false

    - name: Apply measurement sysctls
      ansible.posix.sysctl:
        name: "{{ item.key }}"
        value: "{{ item.value }}"
        sysctl_file: /etc/sysctl.d/90-measurement.conf
        sysctl_set: true
        reload: true
        state: present
      loop: "{{ measurement_sysctls }}"
      loop_control:
        label: "{{ item.key }}={{ item.value }}"

    - name: Configure sysstat collection
      ansible.builtin.copy:
        dest: "{{ (ansible_os_family == 'Debian') | ternary('/etc/sysstat/sysstat', '/etc/sysconfig/sysstat') }}"
        owner: root
        group: root
        mode: "0644"
        content: |
          # Managed by Ansible. Do not edit by hand.
          # Days of history to keep. Values > 28 switch sadc to YYYYMMDD filenames.
          HISTORY={{ sysstat_history_days }}
          # Compress datafiles older than this many days.
          COMPRESSAFTER={{ sysstat_compress_after_days }}
          # Collect every statistic group sadc knows about. Without these flags,
          # sar -d (DISK) and sar -x (per-device detail) have no data to read,
          # and that only becomes apparent during the incident you needed them for.
          SADC_OPTIONS="-S DISK,XDISK,SNMP,IPV6,POWER,XALL"
          # Keep uncompressed datafiles reasonable; 28 * ~14 MB at 1-minute sampling.
          ZIP="xz"
      notify: Reload systemd

    - name: Let Debian's cron helper collect (debian-sa1 exits unless ENABLED="true")
      ansible.builtin.lineinfile:
        path: /etc/default/sysstat
        regexp: '^ENABLED='
        line: 'ENABLED="true"'
      when: ansible_os_family == 'Debian'

    - name: Enable sysstat data collection
      ansible.builtin.service:
        name: sysstat
        enabled: true
        state: started

    - name: Ensure the timer override directory exists
      ansible.builtin.file:
        path: /etc/systemd/system/sysstat-collect.timer.d
        state: directory
        owner: root
        group: root
        mode: "0755"
      when: ansible_service_mgr == 'systemd'

    - name: Override the collection interval (systemd-timer distributions)
      ansible.builtin.copy:
        dest: /etc/systemd/system/sysstat-collect.timer.d/override.conf
        owner: root
        group: root
        mode: "0644"
        content: |
          [Unit]
          Description=Collect system activity every minute

          [Timer]
          OnCalendar=
          OnCalendar={{ sysstat_collect_calendar }}
          AccuracySec=1s
          Persistent=false
      when: ansible_service_mgr == 'systemd'
      notify: Reload systemd

    - name: Enable sysstat timers
      ansible.builtin.systemd_service:
        name: "{{ item }}"
        enabled: true
        state: started
        daemon_reload: true
      loop:
        - sysstat-collect.timer
        - sysstat-summary.timer
      when: ansible_service_mgr == 'systemd'
      failed_when: false

    - name: Fall back to cron where no sysstat timers exist
      ansible.builtin.cron:
        name: "{{ item.name }}"
        minute: "{{ item.minute }}"
        hour: "{{ item.hour | default('*') }}"
        user: root
        job: "{{ item.job }}"
        cron_file: sysstat
      loop:
        - name: sysstat-collect
          minute: "*/1"
          job: "command -v debian-sa1 > /dev/null && debian-sa1 1 1 || /usr/lib64/sa/sa1 1 1"
        - name: sysstat-summary
          minute: "7"
          hour: "0"
          job: "command -v debian-sa2 > /dev/null && debian-sa2 -A || /usr/lib64/sa/sa2 -A"
      when: ansible_service_mgr != 'systemd'

    - name: Create the node_exporter system user
      ansible.builtin.user:
        name: "{{ node_exporter_user }}"
        system: true
        shell: /usr/sbin/nologin
        home: /var/lib/node_exporter
        create_home: true

    - name: Create the textfile collector directory
      ansible.builtin.file:
        path: "{{ node_exporter_textfile_dir }}"
        state: directory
        owner: "{{ node_exporter_user }}"
        group: "{{ node_exporter_user }}"
        mode: "0755"

    - name: Install node_exporter
      ansible.builtin.unarchive:
        src: "https://github.com/prometheus/node_exporter/releases/download/v{{ node_exporter_version }}/node_exporter-{{ node_exporter_version }}.linux-amd64.tar.gz"
        dest: /usr/local/bin
        remote_src: true
        extra_opts:
          - --strip-components=1
          - --wildcards
          - "*/node_exporter"
        owner: root
        group: root
        mode: "0755"
        creates: /usr/local/bin/node_exporter
      notify: Restart node_exporter

    - name: Install the node_exporter unit
      ansible.builtin.copy:
        dest: /etc/systemd/system/node_exporter.service
        owner: root
        group: root
        mode: "0644"
        content: |
          [Unit]
          Description=Prometheus node exporter
          Documentation=https://github.com/prometheus/node_exporter
          After=network-online.target
          Wants=network-online.target

          [Service]
          Type=simple
          User={{ node_exporter_user }}
          Group={{ node_exporter_user }}
          ExecStart=/usr/local/bin/node_exporter \
            --web.listen-address={{ node_exporter_listen }} \
            --collector.textfile.directory={{ node_exporter_textfile_dir }} \
            --collector.pressure \
            --collector.cpu.info \
            --collector.diskstats \
            --collector.netdev.enable-detailed-tx-metrics \
            --collector.netdev.enable-detailed-rx-metrics \
            --collector.netstat.fields=^(.*_(InErrors|InCsumErrors|RetransSegs|OutRsts|ListenOverflows|ListenDrops|RcvbufErrors|SndbufErrors|NoPorts)|Tcp_(ActiveOpens|PassiveOpens|CurrEstab|InSegs|OutSegs))$ \
            --collector.vmstat.fields=^(oom_kill|pgpg|pswp|pg.*fault|pgscan|pgsteal).* \
            --collector.processes \
            --collector.cgroups \
            --collector.systemd \
            --no-collector.wifi \
            --no-collector.nfsd
          ExecReload=/bin/kill -HUP $MAINPID
          Restart=on-failure
          RestartSec=5s
          NoNewPrivileges=true
          ProtectHome=yes
          ProtectSystem=strict
          ProtectKernelTunables=true
          ProtectControlGroups=false
          PrivateTmp=true
          # The exporter must stay alive precisely when memory is scarce.
          OOMScoreAdjust=-500
          MemoryMax=256M
          CPUQuota=20%

          [Install]
          WantedBy=multi-user.target
      notify:
        - Reload systemd
        - Restart node_exporter

    - name: Enable node_exporter
      ansible.builtin.systemd_service:
        name: node_exporter
        enabled: true
        state: started
        daemon_reload: true

    - name: Verify that sysstat is actually producing data
      ansible.builtin.command:
        cmd: sar -u 1 1
      register: sar_check
      changed_when: false
      failed_when: "'Average' not in sar_check.stdout"

    - name: Report the measurement substrate state
      ansible.builtin.debug:
        msg: >-
          sysstat collecting at {{ sysstat_collect_calendar }},
          {{ sysstat_history_days }} days retained,
          delay accounting = {{ lookup('ansible.builtin.file', '/proc/sys/kernel/task_delayacct') }},
          node_exporter on {{ node_exporter_listen }}
```

### 9.3 Prometheus rules — saturation-first, complete

```yaml
---
# /etc/prometheus/rules/resource-saturation.yml
# Alerts on SATURATION (work that had to wait) and ERRORS (work that was lost),
# not on utilisation. A host at 95% CPU with no queue is doing its job; a host
# at 40% CPU with a run queue is failing its users.
groups:
  - name: resource-saturation-recording
    interval: 30s
    rules:
      # Average disk queue depth, i.e. iostat's aqu-sz: the derivative of the
      # millisecond-weighted I/O time is, by definition, the mean queue length.
      - record: instance_device:disk_queue_depth:rate5m
        expr: rate(node_disk_io_time_weighted_seconds_total[5m])

      # iostat's r_await and w_await, in seconds.
      - record: instance_device:disk_read_await_seconds:rate5m
        expr: |
          rate(node_disk_read_time_seconds_total[5m])
          /
          clamp_min(rate(node_disk_reads_completed_total[5m]), 1)

      - record: instance_device:disk_write_await_seconds:rate5m
        expr: |
          rate(node_disk_write_time_seconds_total[5m])
          /
          clamp_min(rate(node_disk_writes_completed_total[5m]), 1)

      # Run-queue pressure per CPU: load average normalised by core count.
      - record: instance:cpu_load_per_core:ratio
        expr: |
          node_load1
          /
          count by (instance) (node_cpu_seconds_total{mode="idle"})

      # Mean packet size, which decides whether the ceiling is bits or packets.
      - record: instance_device:net_mean_rx_packet_bytes:rate5m
        expr: |
          rate(node_network_receive_bytes_total[5m])
          /
          clamp_min(rate(node_network_receive_packets_total[5m]), 1)
```

The alerting group lives in its own file, built on the recording rules above:

```yaml
---
# /etc/prometheus/rules/resource-saturation-alerts.yml
groups:
  - name: resource-saturation-alerts
    interval: 30s
    rules:
      - alert: CPUSaturation
        expr: rate(node_pressure_cpu_waiting_seconds_total[5m]) > 0.20
        for: 10m
        labels:
          severity: warning
          resource: cpu
        annotations:
          summary: "CPU pressure above 20% on {{ $labels.instance }}"
          description: >-
            Runnable tasks spent more than 20% of wall time waiting for a CPU.
            Utilisation may still look healthy. Triage with:
            mpstat -P ALL 5, pidstat -u -t 5, cat /proc/pressure/cpu
          runbook_url: "https://runbooks.example.net/cpu-saturation"

      - alert: CPUStealTime
        expr: |
          sum by (instance) (rate(node_cpu_seconds_total{mode="steal"}[5m]))
          /
          count by (instance) (node_cpu_seconds_total{mode="idle"})
          > 0.05
        for: 15m
        labels:
          severity: warning
          resource: cpu
        annotations:
          summary: "Hypervisor steal time above 5% on {{ $labels.instance }}"
          description: "This guest is runnable but not being scheduled by the host. The fix is capacity on the hypervisor, not on the guest."

      - alert: CPUThrottledByCgroup
        expr: |
          rate(container_cpu_cfs_throttled_periods_total[5m])
          /
          clamp_min(rate(container_cpu_cfs_periods_total[5m]), 1)
          > 0.25
        for: 10m
        labels:
          severity: warning
          resource: cpu
        annotations:
          summary: "More than 25% of CFS periods throttled for {{ $labels.name }}"
          description: "The workload is hitting its cpu.max quota. Host CPU graphs will show idle capacity; read cpu.stat in the cgroup."

      - alert: MemoryPressureStall
        expr: rate(node_pressure_memory_stalled_seconds_total[5m]) > 0.05
        for: 5m
        labels:
          severity: critical
          resource: memory
        annotations:
          summary: "Full memory stall above 5% on {{ $labels.instance }}"
          description: >-
            All non-idle tasks were stalled on memory reclaim. Verify with
            sar -B 1 (watch %vmeff and pgscand/s) and sar -W 1.

      - alert: MemoryReclaimInefficient
        expr: |
          rate(node_vmstat_pgsteal_direct[5m])
          /
          clamp_min(rate(node_vmstat_pgscan_direct[5m]), 1)
          < 0.40
        for: 10m
        labels:
          severity: warning
          resource: memory
        annotations:
          summary: "Reclaim efficiency below 40% on {{ $labels.instance }}"
          description: "The kernel scans more than two pages per page freed, inside the allocating task. This is thrashing, and it precedes the OOM killer."

      - alert: MemoryAvailableLow
        expr: node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.10
        for: 10m
        labels:
          severity: warning
          resource: memory
        annotations:
          summary: "MemAvailable below 10% on {{ $labels.instance }}"
          description: "Judged on MemAvailable, not MemFree: low MemFree alone is the normal, healthy state of a Linux host."

      - alert: InodeExhaustion
        expr: |
          node_filesystem_files_free{fstype!~"tmpfs|overlay|squashfs"}
          /
          clamp_min(node_filesystem_files{fstype!~"tmpfs|overlay|squashfs"}, 1)
          < 0.10
        for: 10m
        labels:
          severity: critical
          resource: disk
        annotations:
          summary: "Inodes below 10% on {{ $labels.instance }}:{{ $labels.mountpoint }}"
          description: "Writes will fail with ENOSPC while df -h still shows free space. Confirm with df -i."

      - alert: DiskLatencyHigh
        expr: instance_device:disk_write_await_seconds:rate5m > 0.050
        for: 10m
        labels:
          severity: warning
          resource: disk
        annotations:
          summary: "Write await above 50ms on {{ $labels.instance }}:{{ $labels.device }}"
          description: >-
            Latency, not %util, is the saturation signal for a queued device.
            Get the distribution with biolatency-bpfcc -D 10 1 before replacing hardware.

      - alert: IOPressureStall
        expr: rate(node_pressure_io_stalled_seconds_total[5m]) > 0.20
        for: 10m
        labels:
          severity: warning
          resource: disk
        annotations:
          summary: "Full I/O stall above 20% on {{ $labels.instance }}"
          description: "The host did no useful work for a fifth of the interval because every task was blocked on I/O."

      - alert: TCPAcceptQueueOverflow
        expr: rate(node_netstat_TcpExt_ListenOverflows[5m]) > 1
        for: 5m
        labels:
          severity: critical
          resource: network
        annotations:
          summary: "TCP accept queue overflowing on {{ $labels.instance }}"
          description: >-
            Completed connections are being dropped because the application is not
            calling accept() fast enough. Confirm with: ss -ltn (compare Recv-Q
            against Send-Q on LISTEN rows). Raising somaxconn does not help if the
            application passed a small backlog to listen(2).

      - alert: NICReceiveDrops
        expr: |
          rate(node_network_receive_drop_total[5m])
          +
          rate(node_network_receive_fifo_total[5m])
          > 1
        for: 10m
        labels:
          severity: warning
          resource: network
        annotations:
          summary: "Receive drops on {{ $labels.instance }}:{{ $labels.device }}"
          description: >-
            Separate ring exhaustion from socket-buffer exhaustion:
            fifo/missed means the NIC had no descriptor (ethtool -G, ethtool -L),
            plain drop means the kernel or the application could not keep up.

      - alert: PacketRateBound
        expr: |
          rate(node_network_receive_packets_total[5m]) > 500000
          and
          instance_device:net_mean_rx_packet_bytes:rate5m < 300
        for: 10m
        labels:
          severity: warning
          resource: network
        annotations:
          summary: "Small-packet flood on {{ $labels.instance }}:{{ $labels.device }}"
          description: "Over 500 kpps at under 300 bytes mean size: the ceiling here is packets per second in the softirq path, not link bandwidth. Interface utilisation will look low."

      - alert: ConntrackTableNearFull
        expr: node_nf_conntrack_entries / node_nf_conntrack_entries_limit > 0.80
        for: 5m
        labels:
          severity: critical
          resource: network
        annotations:
          summary: "Connection tracking table above 80% on {{ $labels.instance }}"
          description: >-
            At 100% the kernel drops packets and logs "nf_conntrack: table full".
            Inspect the composition first (conntrack -L | awk), because the usual
            cause is a 5-day established timeout or a TIME_WAIT pile, not real load.
            Raising nf_conntrack_max costs ~320 bytes of unreclaimable kernel
            memory per entry.
```

### 9.4 A measurement-safe systemd slice

```ini
# /etc/systemd/system/batch.slice
# Confine batch work so that it can never starve the control plane, and so that
# its own saturation is measurable per-cgroup instead of being averaged into the
# host figures.
[Unit]
Description=Batch and reporting workloads
Before=slices.target

[Slice]
# Relative weight under contention; no hard quota, so idle capacity is usable.
CPUWeight=20
# Reclaim throttling starts here; the hard wall is 4 G.
MemoryHigh=3G
MemoryMax=4G
MemorySwapMax=1G
# Proportional I/O weight; prevents a backup job from adding queue depth to the
# database's device.
IOWeight=20
TasksMax=4096
# Sacrifice this slice first if the host runs out of memory.
OOMScoreAdjust=500
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=60%
```

```
$ systemd-run --slice=batch.slice --unit=nightly-report \
    --property=CPUQuota=200% --property=IOReadBandwidthMax="/dev/nvme0n1 200M" \
    /usr/local/bin/nightly-report.sh
Running as unit: nightly-report.service

$ systemd-cgtop -1 --order=cpu -n 2 -b
Control Group                      Tasks   %CPU   Memory  Input/s Output/s
/                                   1283  412.4    40.1G   182.4M    51.6M
system.slice                         884  388.1    38.2G   180.1M    48.4M
system.slice/postgresql.service      142  198.4    22.1G   178.2M    44.1M
system.slice/api.service              88  188.4    12.4G     1.0M     4.1M
batch.slice                           12   18.4     2.1G     1.2M     3.2M
batch.slice/nightly-report.service     4   18.4     2.1G     1.2M     3.2M
```

`systemd-cgtop` is the per-service `top`, and on a systemd host it is frequently the fastest route from "the box is busy" to "this unit is busy". `systemd-cgls` shows the same tree structurally.

### 9.5 Machine-readable export with `sadf`

```
$ sadf -j -- -u -q -f /var/log/sa/sa14 | python3 -c 'import json,sys; json.load(sys.stdin); print("valid")'
valid
```

A complete `sadf -j` document (one interval, trimmed to two statistic groups by the `--` arguments, not by editing — editing the JSON would make it invalid):

```json
{
  "sysstat": {
    "hosts": [
      {
        "nodename": "db03.prod.example.net",
        "sysname": "Linux",
        "release": "6.8.0-45-generic",
        "machine": "x86_64",
        "number-of-cpus": 16,
        "file-date": "2026-10-14",
        "file-utc-offset": 0,
        "statistics": [
          {
            "timestamp": {
              "date": "2026-10-14",
              "time": "03:25:01",
              "utc": 0,
              "interval": 60
            },
            "cpu-load": [
              {
                "cpu": "all",
                "user": 7.12,
                "nice": 0.00,
                "system": 3.48,
                "iowait": 41.07,
                "steal": 0.00,
                "idle": 48.33
              }
            ],
            "queue": {
              "runq-sz": 3,
              "plist-sz": 1283,
              "ldavg-1": 18.42,
              "ldavg-5": 14.77,
              "ldavg-15": 9.31,
              "blocked": 41
            }
          }
        ]
      }
    ]
  }
}
```

Other export forms, all operationally useful:

```
$ sadf -d -- -d -p -f /var/log/sa/sa14 | head -3
# hostname;interval;timestamp;DEV;tps;rkB/s;wkB/s;dkB/s;areq-sz;aqu-sz;await;%util
db03.prod.example.net;60;2026-10-14 00:01:01 UTC;nvme0n1;412.44;1884.21;18412.04;0.00;49.21;0.42;1.02;8.41
db03.prod.example.net;60;2026-10-14 00:02:01 UTC;nvme0n1;408.12;1902.44;18204.80;0.00;49.44;0.41;1.01;8.22

$ sadf -g -T -- -u -r -n DEV -f /var/log/sa/sa14 > /tmp/sa14.svg
$ sadf -x -- -A -f /var/log/sa/sa14 | head -4
<?xml version="1.0" encoding="ISO-8859-1"?>
<!DOCTYPE sysstat PUBLIC "DTD v3.11 sysstat //DTD Sysstat 3.11//EN" "http://pagesperso-orange.fr/sebastien.godard/sysstat-3.11.dtd">
<sysstat xmlns="http://pagesperso-orange.fr/sebastien.godard/sysstat"
```

`sadf -g` produces a self-contained SVG of the whole day with no Grafana, no Prometheus and no network access — the single most useful artefact to attach to an incident report on an isolated host.

---

## 10. Estimating throughput and identifying the bottleneck

### 10.1 The ceiling for each resource

| Resource | Ceiling formula | Measure the terms with | First symptom of saturation |
|---|---|---|---|
| CPU (parallel) | `cores × 1.0` | `mpstat -P ALL` | `r` > cores in `vmstat`; `%wait` in `pidstat` |
| CPU (one thread) | `1 core` | `pidstat -t`, `top -H` | one core at 100 %, box at `100/ncores` % |
| Softirq / packet path | ~1–3 Mpps per core | `mpstat -I SCPU`, `softnet_stat` | `time_squeeze`, `rx_missed_errors` |
| Memory capacity | `MemTotal - kernel - min_free` | `MemAvailable`, `memory.current` | `majflt/s`, `%vmeff` falling |
| Memory bandwidth | platform (`mbw`, `perf stat`) | `perf stat -e cache-misses` | IPC drop with no change in workload |
| Disk IOPS | device IOPS at the queue depth you use | `fio` ceiling job | `await` rising while IOPS is flat |
| Disk bandwidth | device MB/s | `fio` sequential job | `rareq-sz` large, `await` rising |
| Sync write rate | `1 / fdatasync_latency` | `fio` `sync-write-cost` job | commit latency = whole transaction latency |
| Link bandwidth | line rate × (payload / frame-on-wire) | `sar -n DEV` (`rxkB/s`) | `%ifutil`, qdisc `backlog` |
| Link packet rate | line rate / frame-on-wire bits | `sar -n DEV` (`rxpck/s`) | drops at low `%ifutil` |
| Single TCP flow | `min(cwnd, rwnd) / RTT` | `ss -ti` | `rwnd_limited`, `sndbuf_limited` |
| Conntrack | `nf_conntrack_max` entries | `conntrack -S` | `insert_failed`, "table full" in `dmesg` |
| Accept rate | application `listen()` backlog | `ss -ltn`, `nstat` | `ListenOverflows` |
| File descriptors | `ulimit -n`, `fs.file-max` | `lsof \| wc -l`, `/proc/sys/fs/file-nr` | `EMFILE`, "too many open files" |

### 10.2 Worked example: why a 25 GbE host moves 600 Mbit/s

```
$ ss -ti 'dst 198.51.100.200' | tail -4
         cubic wscale:7,7 rto:284 rtt:80.112/0.884 mss:1448 pmtu:9000 rcvmss:1448 advmss:8948
         cwnd:1448 bytes_sent:4194304000 bytes_acked:4194303000 segs_out:2896000 segs_in:1448000
         send 209.4Mbps lastsnd:4 pacing_rate 251.3Mbps delivery_rate 208.1Mbps
         sndbuf_limited:184112ms(88.4%) busy:208112ms rcv_space:14480 minrtt:80.004

$ sysctl net.ipv4.tcp_wmem net.ipv4.tcp_rmem net.core.wmem_max net.ipv4.tcp_congestion_control
net.ipv4.tcp_wmem = 4096        16384   4194304
net.ipv4.tcp_rmem = 4096        131072  6291456
net.core.wmem_max = 212992
net.ipv4.tcp_congestion_control = cubic
```

The arithmetic:

- Bandwidth-delay product for 25 Gbit/s at 80 ms RTT: `25e9 × 0.080 / 8 = 250 MB`. To fill the pipe with one flow you need a 250 MB window.
- The send buffer maximum is `tcp_wmem[2] = 4 MiB`. Usable window ≈ 4 MiB (minus overhead).
- Maximum single-flow throughput: `4 MiB / 0.080 s ≈ 419 Mbit/s`. The observed 209 Mbit/s is lower still because roughly half the buffer is consumed by un-ACKed data accounting.
- `sndbuf_limited:88.4%` is the kernel telling you precisely this, in one field.

So this is a **sysctl bug, not a network problem**, and the cost of diagnosing it wrongly is a capacity order. Note also that `net.core.wmem_max = 212992` is the default and does not override `tcp_wmem` for TCP autotuning — but it *does* cap any application that calls `setsockopt(SO_SNDBUF)`, where it halves the effective ask. Both must be raised:

```
$ sudo sysctl -w net.ipv4.tcp_wmem="4096 65536 268435456"
net.ipv4.tcp_wmem = 4096 65536 268435456
$ sudo sysctl -w net.ipv4.tcp_rmem="4096 131072 268435456"
net.ipv4.tcp_rmem = 4096 131072 268435456
$ sudo sysctl -w net.core.wmem_max=268435456 net.core.rmem_max=268435456
net.core.wmem_max = 268435456
net.core.rmem_max = 268435456
$ sudo sysctl -w net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_congestion_control = bbr
```

For a lossy long-fat path, the Mathis bound is the sanity check before buying anything: `BW ≈ MSS / (RTT × √p)`. With `MSS=1448`, `RTT=0.080 s`, loss `p=0.001`: `1448 / (0.080 × 0.0316) ≈ 573 kB/s ≈ 4.6 Mbit/s` per flow with classic loss-based CC. On a 0.1 %-loss path, **no window tuning gets a single CUBIC flow past a few megabits per second** — the answers are BBR, parallel flows, or fixing the loss.

Verify with the standard instruments, in both directions and with parallelism:

```
$ iperf3 -c 198.51.100.200 -t 30 -P 8 -i 10 --get-server-output | tail -6
[SUM]   0.00-30.00  sec  68.4 GBytes  19.6 Gbits/sec  1204            sender
[SUM]   0.00-30.04  sec  68.3 GBytes  19.5 Gbits/sec                  receiver

$ iperf3 -c 198.51.100.200 -u -b 10G -l 64 -t 10 | tail -3
[  5]   0.00-10.00  sec  1.02 GBytes   876 Mbits/sec  0.000 ms  0/17104882 (0%)  sender
[  5]   0.00-10.04  sec   712 MBytes   595 Mbits/sec  0.041 ms  5204112/17104882 (30%)  receiver
```

Eight parallel streams reach 19.6 Gbit/s — the path is fine and the single-flow limit was local. The UDP 64-byte test then shows the *other* ceiling: 30 % loss at ~1.7 Mpps offered. That is the packet-rate wall from Section 7.1, measured.

### 10.3 Little's law as a bottleneck locator

`concurrency = throughput × latency`. Applied per layer, it tells you which layer holds the requests:

```
Observed: 2,000 req/s at 250 ms p50  →  in-flight requests = 2000 × 0.25 = 500
Application worker pool                                     = 64
```

500 in-flight against 64 workers means 436 requests are queued **before** the application — in the accept queue, the load balancer, or the kernel. No amount of application profiling will find them; `ss -ltn` will, in one line. Conversely, if the pool were 512 and the database showed `aqu-sz 480`, the requests are queued in the storage layer and the fix is downstream.

---

## 11. Symptom → likely cause correlation matrix

This is the objective's "match / correlate system symptoms with likely problems" area, and the table is the deliverable.

| Observed symptom | Most likely causes | Confirming command | Decisive evidence |
|---|---|---|---|
| High load, `%idle` high, `b` high in `vmstat` | storage or NFS blocking | `vmstat 5`, `ps -eo stat,wchan,args \| grep '^D'` | processes in `D` with block/NFS `WCHAN` |
| High load, `r` ≫ cores, `%usr` high | genuine CPU shortage | `mpstat -P ALL`, `pidstat -u -t` | run queue > cores, `%wait` per task |
| High load, one core at 100 %, box mostly idle | single-threaded hot path, or single NIC queue | `mpstat -P ALL`, `top -H` | one CPU busy; `%soft` if networking |
| CPU busy but throughput falling | lock contention, cgroup throttling, memory thrash | `pidstat -w`, `cpu.stat`, `sar -B` | `nvcswch/s` high; `nr_throttled`; `%vmeff` < 40 % |
| `%steal` > 5 % | hypervisor oversubscription | `mpstat -P ALL`, `sar -u` | `%steal` sustained; nothing on the guest fixes it |
| `%iowait` high **and** throughput high | normal I/O-bound work | `iostat -xz 5` | `await` within device spec |
| `%iowait` high **and** throughput low | device degradation, remote storage, queue starvation | `biolatency`, `iostat -xz` | bimodal/long-tail latency histogram |
| `%util` 100 % on NVMe, `await` ~1 ms | **not a problem** | `iostat -xz`, `fio` baseline | `await` ≈ measured device floor |
| `%util` 100 %, `await` ≫ 20 ms, `aqu-sz` high | real disk saturation | `iostat -xz`, `iotop -oPa` | `await` rising with offered load |
| Free memory near zero | **normal** page-cache behaviour | `free -w`, `MemAvailable` | `available` still large |
| `majflt/s` high, `%vmeff` low, `pgscand/s` high | working set exceeds RAM | `sar -B`, `sar -r` | direct reclaim with poor efficiency |
| Swap used but `si`/`so` ≈ 0 | **normal** — cold anonymous pages | `vmstat 5`, `sar -W` | no swap traffic |
| `si`/`so` sustained, latency spikes | thrashing | `sar -W`, `/proc/pressure/memory` | `full` memory pressure > 0 |
| Process killed, no application error | OOM killer, or cgroup OOM | `dmesg -T`, `memory.events` | "Killed process"; `oom_kill` > 0 |
| 20-second write freezes | dirty-page writeback cliff | `grep Dirty /proc/meminfo`, `sysctl vm.dirty_ratio` | `Dirty` near `dirty_ratio × MemTotal` |
| `ENOSPC` with free space in `df -h` | inode exhaustion | `df -i` | `IUse% 100` |
| `df` and `du` disagree by gigabytes | deleted files still open | `lsof +L1` | `NLINK 0` entries |
| Connection timeouts, host otherwise idle | accept queue overflow | `ss -ltn`, `nstat` | `Recv-Q` > `Send-Q` on LISTEN; `ListenOverflows` |
| Intermittent resets under load | ephemeral port or conntrack exhaustion | `ss -s`, `conntrack -S`, `sysctl net.ipv4.ip_local_port_range` | `TIME_WAIT` pile; `insert_failed` |
| Packet loss at low `%ifutil` | packet-rate bound, ring too small, single queue | `sar -n DEV/EDEV`, `ethtool -S/-l/-g`, `softnet_stat` | small mean packet size; `rx_missed`, `time_squeeze` |
| RX `dropped` with zero `missed` | socket buffers / slow reader | `ss -tm`, `nstat` (`RcvbufErrors`) | `Recv-Q` large on the socket |
| One slow flow, others fine | receiver window, or buffer caps | `ss -ti` | `rwnd_limited` / `sndbuf_limited` percentages |
| Throughput collapses above N Mbit/s | loss + loss-based CC on a fat pipe | `ss -ti`, `nstat` (`TCPSynRetrans`, `RetransSegs`) | retransmits > 0.1 %; Mathis bound matches |
| Firewall host drops packets, CPU "fine" | `nft_do_chain` cost / conntrack lookup | `perf top -e cycles:k`, `conntrack -S` | kernel cycles in netfilter functions |
| Everything slow after a deploy, metrics normal | cgroup limits on the new unit | `systemd-cgtop`, `cpu.stat`, `memory.events` | throttled periods / `high` events |

---

## 12. Verification and failure-diagnosis guide

### 12.1 Verify the measurement substrate before you need it

```
$ sar -u 1 1
Linux 6.8.0-45-generic (db03)   10/15/2026      _x86_64_        (16 CPU)
12:21:04        CPU     %user     %nice   %system   %iowait    %steal     %idle
12:21:05        all      7.12      0.00      3.48      0.21      0.00     89.19
Average:        all      7.12      0.00      3.48      0.21      0.00     89.19

$ sar -d -p 1 1 | head -3
12:21:10          DEV       tps     rkB/s     wkB/s     dkB/s   areq-sz    aqu-sz     await     %util
12:21:11      nvme0n1    412.00   1884.00  18412.00      0.00     49.26      0.42      1.02      8.40

$ sudo systemctl list-timers 'sysstat*' --no-pager
NEXT                        LEFT       LAST                        PASSED     UNIT                   ACTIVATES
Thu 2026-10-15 12:22:00 CEST 41s       Thu 2026-10-15 12:21:00 CEST 19s ago    sysstat-collect.timer  sysstat-collect.service
Fri 2026-10-16 00:07:00 CEST 11h 46min Thu 2026-10-15 00:07:00 CEST 12h ago    sysstat-summary.timer  sysstat-summary.service

$ ls -la /var/log/sa/ | tail -4
-rw-r--r-- 1 root root 14204881 Oct 13 23:59 sa13
-rw-r--r-- 1 root root 14118412 Oct 14 23:59 sa14
-rw-r--r-- 1 root root  7204112 Oct 15 12:21 sa15
-rw-r--r-- 1 root root  2104884 Oct 14 00:07 sar14

$ sysctl kernel.task_delayacct
kernel.task_delayacct = 1

$ grep . /proc/pressure/* 
/proc/pressure/cpu:some avg10=1.42 avg60=2.11 avg300=1.88 total=18472930184
/proc/pressure/io:some avg10=0.84 avg60=1.02 avg300=0.91 total=99184772093
/proc/pressure/io:full avg10=0.41 avg60=0.48 avg300=0.44 total=71204881003
/proc/pressure/memory:some avg10=0.00 avg60=0.00 avg300=0.00 total=1204881
/proc/pressure/memory:full avg10=0.00 avg60=0.00 avg300=0.00 total=402114
```

Failure modes of the substrate itself, each of which silently produces an empty investigation:

| Check | Failure | Cause | Fix |
|---|---|---|---|
| `sar -u 1 1` | `Cannot open /var/log/sa/sa15: No such file` | collection never enabled | enable `sysstat` service and the collect timer |
| `sar -d` | `Requested activities not available in file` | `SADC_OPTIONS` lacks `-S DISK` | set `SADC_OPTIONS`, then wait for new data (old files cannot be fixed) |
| `sar -f sa01` | file is this month's or older-than-expected | `HISTORY` ≤ 28 reuses `saDD` names monthly | set `HISTORY` > 28 for `YYYYMMDD` names, or archive off-box |
| `iotop` | `CONFIG_TASK_DELAY_ACCT not enabled` | `kernel.task_delayacct=0` | sysctl, persisted |
| `ss -tiepm` | no `skmem`/`bbr` details | not root | run with `sudo` |
| `/proc/pressure/*` | missing | kernel < 4.20 or `psi=0` | boot with `psi=1` |
| `perf top` | `Permission denied` | `perf_event_paranoid=3` | lower to 1 (or 2) |

### 12.2 The incident capture script

The first casualty of an incident is the data, because the symptom ends before anyone logs in. Capture everything at once, to disk, in one bounded pass:

```bash
#!/usr/bin/env bash
# /usr/local/sbin/resource-snapshot — capture every resource view in parallel.
# Bounded (exits after DURATION), writes one file per view, never pipes through tee.
set -euo pipefail

DURATION="${1:-60}"
OUT="/var/tmp/snapshot-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"

{
    uname -a
    uptime
    date -u
} > "$OUT/00-context.txt"

# Point-in-time state.
ps -eo pid,ppid,user,stat,psr,pcpu,pmem,rss,vsz,wchan:22,etimes,args --sort=-pcpu \
    > "$OUT/01-ps.txt"
pstree -aps > "$OUT/02-pstree.txt"
ss -tanipemo > "$OUT/03-ss-sockets.txt"
ss -ltn > "$OUT/04-ss-listen.txt"
ss -s > "$OUT/05-ss-summary.txt"
ip -s -s link > "$OUT/06-ip-link.txt"
nstat -az > "$OUT/07-nstat.txt"
df -h > "$OUT/08-df.txt"
df -i > "$OUT/09-df-inode.txt"
free -w > "$OUT/10-free.txt"
cat /proc/meminfo > "$OUT/11-meminfo.txt"
cat /proc/interrupts > "$OUT/12-interrupts.txt"
cat /proc/net/softnet_stat > "$OUT/13-softnet.txt"
grep . /proc/pressure/* > "$OUT/14-pressure.txt" 2>/dev/null || true
tc -s qdisc show > "$OUT/15-qdisc.txt"
dmesg -T | tail -500 > "$OUT/16-dmesg.txt"
systemd-cgtop -1 --order=cpu -n 1 -b > "$OUT/17-cgtop.txt" 2>/dev/null || true
conntrack -S > "$OUT/18-conntrack-stats.txt" 2>/dev/null || true
lsof +L1 > "$OUT/19-deleted-open-files.txt" 2>/dev/null || true
for f in /sys/fs/cgroup/*/cpu.stat /sys/fs/cgroup/*/*/cpu.stat; do
    [ -r "$f" ] && { echo "== $f"; cat "$f"; }
done > "$OUT/20-cgroup-cpu-stat.txt" 2>/dev/null || true

# Interval samplers, all started together so the timelines align.
vmstat 1 "$DURATION"                         > "$OUT/30-vmstat.txt"  2>&1 &
mpstat -P ALL 1 "$DURATION"                  > "$OUT/31-mpstat.txt"  2>&1 &
mpstat -I SCPU 1 "$DURATION"                 > "$OUT/32-softirq.txt" 2>&1 &
iostat -xzt 1 "$DURATION"                    > "$OUT/33-iostat.txt"  2>&1 &
pidstat -urdw -t 1 "$DURATION"               > "$OUT/34-pidstat.txt" 2>&1 &
sar -n DEV,EDEV,TCP,ETCP,SOCK 1 "$DURATION"  > "$OUT/35-sar-net.txt" 2>&1 &
sar -B 1 "$DURATION"                         > "$OUT/36-sar-paging.txt" 2>&1 &
top -b -H -n "$DURATION" -d 1 -w 512         > "$OUT/37-top.txt"     2>&1 &
iotop -oPab -d 1 -n "$DURATION"              > "$OUT/38-iotop.txt"   2>&1 &

wait
tar -caf "$OUT.tar.zst" -C "$(dirname "$OUT")" "$(basename "$OUT")"
printf 'snapshot: %s.tar.zst\n' "$OUT"
```

Two deliberate properties: **nothing is piped through `tee`** (in a pipeline the exit status is the last command's, so a failed sampler reports success), and every sampler is bounded by `-n`/count so the script cannot outlive the incident.

### 12.3 The triage order

A fixed order beats intuition, because intuition anchors on the last incident.

```
$ uptime                                    # 1. Is this new? Which direction?
$ vmstat 5 3                                # 2. r vs b: CPU demand or blocked?
$ grep . /proc/pressure/*                   # 3. Rank saturation across resources
$ mpstat -P ALL 5 2                         # 4. Imbalance? softirq? steal?
$ iostat -xz 5 2                            # 5. await, not %util
$ free -w -h && sar -B 1 3                  # 6. MemAvailable, %vmeff, majflt/s
$ ss -ltn && nstat                          # 7. Accept queues and stack errors
$ ip -s link && cat /proc/net/softnet_stat  # 8. Drops: ring or socket?
$ systemd-cgtop -1 --order=cpu -n 1 -b      # 9. Which unit, and is it throttled?
$ pidstat -urdw -t 5 2                      # 10. Attribute to a task
```

Steps 1–3 take fifteen seconds and eliminate three of the four resources. Everything after that is confirmation, not search.

### 12.4 Three complete diagnoses

**(a) "The API is slow", 16 CPUs, host 75 % idle.**

```
$ uptime
 13:02:11 up 12 days,  4:18,  1 user,  load average: 2.14, 2.08, 1.94
$ vmstat 5 2 | tail -1
 2  0  73216 1284992 912384 19884416    0    0   184   412 2104  4881  11  6 82  1  0  0
$ cat /proc/pressure/cpu
some avg10=0.84 avg60=0.91 avg300=0.88 total=18472930184
$ ss -ltn | grep 8080
LISTEN     412        128                     0.0.0.0:8080             0.0.0.0:*
$ nstat -n; sleep 10; nstat | grep -i listen
TcpExtListenOverflows           1842               0.0
TcpExtListenDrops               1842               0.0
```

No CPU pressure, no memory pressure, no disk pressure — and 184 dropped connections per second at the accept queue. The box is idle because it is **refusing work**, not performing it. Fix: the application's `listen()` backlog (128), plus worker concurrency. `somaxconn` is already 4096 and is not the constraint.

**(b) "Database writes hang every few minutes."**

```
$ grep -E 'Dirty|Writeback:' /proc/meminfo
Dirty:          11204884 kB
Writeback:       1204112 kB
$ sysctl vm.dirty_ratio vm.dirty_background_ratio
vm.dirty_ratio = 20
vm.dirty_background_ratio = 10
$ iostat -xz 5 1 | grep -E 'Device|sdb'
Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util
sdb              12.40    198.40     0.00   0.00    4.12    16.00  1204.80 154214.40   188.40  13.52 1884.12   128.00    0.00     0.00     0.00   0.00    0.00     0.00  412.40 2104.88  241.84  100.00
$ cat /proc/pressure/io
some avg10=88.41 avg60=71.04 avg300=52.11 total=99184772093
full avg10=74.12 avg60=61.44 avg300=44.08 total=71204881003
```

`Dirty` is 11.2 GB, `dirty_ratio=20` on 64 GB permits ~12.8 GB — the host is at the cliff, every writer is blocked synchronously, `w_await` is 1.88 s, `f_await` (fsync) is 2.1 s, and `io full` pressure is 74 %. The device is not broken; the kernel accumulated an unflushable backlog. Fix: `vm.dirty_bytes`/`vm.dirty_background_bytes` as in Section 5.4, sized so the backlog drains within the latency budget (`dirty_bytes ≈ device_MBps × acceptable_stall_seconds`).

**(c) "Packet loss to the edge firewall, interface utilization 11 %."**

```
$ sar -n DEV --iface=eth0 1 2
13:14:02     IFACE   rxpck/s   txpck/s    rxkB/s    txkB/s   rxcmp/s   txcmp/s  rxmcst/s   %ifutil
13:14:03      eth0 1484112.40 188412.80 141204.44  18412.04      0.00      0.00      0.44     11.29
13:14:04      eth0 1492044.80 191204.40 142112.80  18884.44      0.00      0.00      0.48     11.36

$ sar -n EDEV --iface=eth0 1 1
13:14:08     IFACE   rxerr/s   txerr/s    coll/s  rxdrop/s  txdrop/s  txcarr/s  rxfram/s  rxfifo/s  txfifo/s
13:14:09      eth0      0.00      0.00      0.00  18412.44      0.00      0.00      0.00  84112.80      0.00

$ mpstat -P ALL 1 1 | awk 'NR<4 || $4+$8 > 60'
Linux 6.8.0-45-generic (fw01)   10/15/2026      _x86_64_        (16 CPU)

13:14:12     CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle
13:14:13       0    1.02    0.00    4.12    0.00    8.41   86.45    0.00    0.00    0.00    0.00
13:14:13       1    0.82    0.00    3.88    0.00    0.00    0.00    0.00    0.00    0.00   95.30

$ awk '{print NR-1, strtonum("0x"$2), strtonum("0x"$3)}' /proc/net/softnet_stat | head -3
0 1884112 412884
1 0 0
2 0 0

$ ethtool -l eth0 | tail -2
Current hardware settings:
Combined:       1

$ sudo conntrack -S | awk -F'[= ]' '{s+=$12} END {print "insert_failed total:", s}'
insert_failed total: 1842044
```

Mean packet size is `141204 kB / 1484112 pkt ≈ 97 bytes`. At 1.48 Mpps the link is 11 % utilized in bits and **effectively at 100 % in packets** for a single-queue receive path: CPU 0 is at 86 % softirq with zero idle, `softnet_stat` shows 412 884 backlog drops and 1.88 M processed on CPU 0 alone, and `rxfifo/s` of 84 k confirms the NIC ran out of descriptors. Conntrack adds 1.84 M failed inserts on top.

The remediation is ordered by effect, and none of it involves bandwidth:

```
$ sudo ethtool -L eth0 combined 16
$ sudo ethtool -G eth0 rx 4096 tx 4096
$ sudo sysctl -w net.core.netdev_budget=1200 net.core.netdev_max_backlog=16384
net.core.netdev_budget = 1200
net.core.netdev_max_backlog = 16384
$ sudo sysctl -w net.netfilter.nf_conntrack_max=1048576
net.netfilter.nf_conntrack_max = 1048576
$ echo 262144 | sudo tee /sys/module/nf_conntrack/parameters/hashsize
262144
```

Re-measure, and require the counters to be flat rather than merely smaller:

```
$ sar -n EDEV --iface=eth0 1 1
13:28:41     IFACE   rxerr/s   txerr/s    coll/s  rxdrop/s  txdrop/s  txcarr/s  rxfram/s  rxfifo/s  txfifo/s
13:28:42      eth0      0.00      0.00      0.00      0.00      0.00      0.00      0.00      0.00      0.00

$ mpstat -P ALL 1 1 | tail -4
13:28:46      13    0.82    0.00    3.12    0.00    0.41   28.44    0.00    0.00    0.00   67.21
13:28:46      14    0.88    0.00    3.08    0.00    0.41   27.88    0.00    0.00    0.00   67.75
13:28:46      15    0.84    0.00    3.21    0.00    0.38   28.12    0.00    0.00    0.00   67.45
Average:     all    0.86    0.00    3.14    0.00    0.40   28.04    0.00    0.00    0.00   67.56
```

Softirq load is now spread across all 16 cores at ~28 % each, with zero drops — the same 1.48 Mpps, on the same 11 %-utilized link.

### 12.5 Post-remediation verification checklist

Every change above must be verified against the counter it was supposed to fix, not against the complaint.

| Change | Verify with | Pass condition |
|---|---|---|
| `listen()` backlog raised | `ss -ltn`; `nstat \| grep Listen` | `Recv-Q` ≪ `Send-Q`; `ListenOverflows` delta = 0 |
| `vm.dirty_bytes` lowered | `grep Dirty /proc/meminfo`; `iostat -xz 5` | `Dirty` ≪ `dirty_bytes`; `f_await` within device spec |
| `nf_conntrack_max` raised | `conntrack -S`; `slabtop -o -s c` | `insert_failed` delta = 0; `nf_conntrack` slab within budget |
| `ethtool -L/-G` | `ethtool -S`; `mpstat -P ALL`; `softnet_stat` | `rx_missed_errors` delta = 0; softirq spread; cols 2–3 flat |
| `tcp_wmem`/`tcp_rmem` raised | `ss -ti` | `sndbuf_limited`/`rwnd_limited` ≈ 0 % |
| cgroup limits adjusted | `cpu.stat`; `memory.events` | `nr_throttled` delta = 0; `high`/`oom_kill` delta = 0 |
| scheduler/queue tunables | `fio` baseline re-run | measured floor/ceiling moved in the expected direction |
| persistence of any sysctl | `sysctl -p /etc/sysctl.d/90-measurement.conf`; reboot test | value survives reboot |

Two rules that prevent false "fixed" reports:

1. **Compare deltas, never cumulative counters.** `nstat -n` to reset, wait, `nstat` again. A cumulative `ListenOverflows` of 184 412 stays at 184 412 forever after the fix.
2. **Re-baseline the flight recorder.** After the change, confirm `sar` for the next hour shows the new regime; a fix verified only in a 10-second window has not been verified.

---

## 13. Exam-focused notes for 200.1

The traps that recur, stated as the answers they are:

- **The first line of `vmstat`/`iostat`/`mpstat`/`sar` is the since-boot average.** Use `iostat -y` or discard it; never quote it as current.
- **Linux load average includes `D` state.** It is not a CPU-demand metric. `vmstat`'s `r` and `b` columns split it.
- **`%iowait` is a CPU state**, accrued only when the CPU is idle with outstanding I/O. It can be 0 on a saturated array and 6 % on an idle host with one blocked process.
- **For `LISTEN` sockets, `Recv-Q` is pending accepts and `Send-Q` is the backlog size.** For `ESTAB` they are unread and unacknowledged bytes.
- **`free`'s `available`, not `free`,** is the memory you can use. Low `free` is the normal state.
- **Swap *used* is harmless; swap *traffic* (`si`/`so`, `pswpin/s`, `pswpout/s`) is the symptom.**
- **`%util` is time-with-a-request-in-flight**, not capacity; `await` and `aqu-sz` are the saturation signals. `svctm` no longer exists.
- **`iotop` needs `kernel.task_delayacct=1`** on kernels ≥ 5.14.
- **`sar -d` needs `SADC_OPTIONS="-S DISK"`** at collection time; you cannot retroactively add activities to an existing datafile.
- **`sadc` writes binary; `sar` reads it; `sadf` exports it** (`-j` JSON, `-d` CSV, `-x` XML, `-g` SVG). `sa1` and `sa2` are the cron/timer wrappers.
- **`sar -f /var/log/sa/saDD`** reads a past day; with `HISTORY ≤ 28` those filenames are reused monthly.
- **`w` reads `utmp`** and therefore sees only login sessions.
- **`pstree -aps <pid>`** shows ancestry *and* arguments *and* PIDs — the combination that identifies which parent spawned a runaway.
- **`ss` uses netlink, `netstat` parses `/proc`.** `netstat -p` additionally walks `/proc/*/fd`, which is why it is pathologically slow on busy hosts.
- **`nstat` prints deltas by default**; `netstat -s` prints cumulative totals.
- **`iptraf-ng` modes:** `-i` IP traffic, `-d` detailed interface, `-s` per-port service, `-z` packet sizes, `-l` per-MAC LAN stations; `-B -L file -t minutes` for unattended capture.
- **Throughput ceilings are packets per second as often as bits per second.** 10 GbE is 14.88 Mpps at 64 B and 812.7 kpps at 1500 B.
- **Single-flow TCP throughput is `window / RTT`.** `ss -ti`'s `rwnd_limited` and `sndbuf_limited` name the limiting side directly.
- **"nf_conntrack: table full, dropping packet" in `dmesg`** is a firewall capacity event, and each entry costs ~320 B of unreclaimable kernel slab.
- **The process that invokes the OOM killer is usually not the process it kills.** Read both `dmesg` lines.

A minimal command set you should be able to produce from memory, in order:

```
$ uptime; w
$ vmstat 5 3
$ mpstat -P ALL 5 2
$ iostat -xz 5 2
$ free -w -h
$ sar -u -q -r -B -W -d -p -n DEV,EDEV,TCP,ETCP 1 3
$ ps -eo pid,stat,pcpu,pmem,rss,wchan:20,args --sort=-pcpu | head
$ pstree -aps 1 | head
$ pidstat -urdw -t 5 2
$ sudo iotop -oPab -d 5 -n 2
$ ss -s; ss -ltn; ss -tiepm
$ nstat -n; sleep 10; nstat
$ ip -s -s link show eth0
$ sudo iptraf-ng -d eth0 -B -L /var/log/iptraf-ng/eth0.log -t 5
```

---

## 14. References

**LPI official**

- Exam 201-450 and 202-450 objectives, version 4.5.0 (includes 200.1, weight 6): https://www.lpi.org/our-certifications/exam-201-202-objectives/
- LPIC-2 certification overview: https://www.lpi.org/our-certifications/lpic-2-overview/

**Kernel documentation (`docs.kernel.org`)**

- `proc(5)` filesystem, including `/proc/stat`, `/proc/meminfo`, `/proc/diskstats`, `/proc/loadavg`: https://docs.kernel.org/filesystems/proc.html
- Pressure Stall Information: https://docs.kernel.org/accounting/psi.html
- Delay accounting (required by `iotop`, `pidstat -d`): https://docs.kernel.org/accounting/delay-accounting.html
- taskstats interface: https://docs.kernel.org/accounting/taskstats.html
- Control Group v2 (`cpu.max`, `cpu.stat`, `memory.max`, `memory.events`, `io.stat`): https://docs.kernel.org/admin-guide/cgroup-v2.html
- VM sysctl reference (`overcommit_memory`, `dirty_ratio`, `swappiness`, `min_free_kbytes`): https://docs.kernel.org/admin-guide/sysctl/vm.html
- Kernel sysctl reference (`task_delayacct`, `perf_event_paranoid`): https://docs.kernel.org/admin-guide/sysctl/kernel.html
- Networking sysctl reference (`tcp_rmem`, `tcp_wmem`, `somaxconn`, `netdev_budget`): https://docs.kernel.org/admin-guide/sysctl/net.html
- TCP implementation and tuning notes: https://docs.kernel.org/networking/ip-sysctl.html
- Scaling in the Linux networking stack (RSS, RPS, RFS, XPS): https://docs.kernel.org/networking/scaling.html
- Block layer statistics (`/sys/block/*/stat`, queue tunables): https://docs.kernel.org/block/stat.html
- Block queue sysfs attributes (`/sys/block/<disk>/queue/*`, stable ABI): https://www.kernel.org/doc/Documentation/ABI/stable/sysfs-block
- Multi-queue block IO queueing (blk-mq): https://docs.kernel.org/block/blk-mq.html
- OOM killer and `oom_score_adj`: https://docs.kernel.org/admin-guide/mm/concepts.html
- Transparent Hugepages: https://docs.kernel.org/admin-guide/mm/transhuge.html

**Tool projects and manual pages**

- `sysstat` (`sar`, `sadc`, `sadf`, `iostat`, `mpstat`, `pidstat`) project and documentation: https://github.com/sysstat/sysstat
- `sysstat` project site (releases, features, FAQ): https://sysstat.github.io/
- `procps-ng` (`ps`, `top`, `vmstat`, `free`, `pstree`, `slabtop`): https://gitlab.com/procps-ng/procps
- `sysstat` CHANGES (iostat fields in 11.5.7, `svctm` removed in 12.1.2): https://github.com/sysstat/sysstat/blob/master/CHANGES
- `procps-ng` NEWS (`vmstat` guest time in default output, 4.0.4): https://gitlab.com/procps-ng/procps/-/blob/master/NEWS
- `iproute2` (`ip`, `ss`, `nstat`, `tc`), upstream repository: https://git.kernel.org/pub/scm/network/iproute2/iproute2.git/
- `ss(8)`: https://man7.org/linux/man-pages/man8/ss.8.html
- `ip(8)`: https://man7.org/linux/man-pages/man8/ip.8.html
- `tc(8)`: https://man7.org/linux/man-pages/man8/tc.8.html
- `iostat(1)`: https://man7.org/linux/man-pages/man1/iostat.1.html
- `mpstat(1)`: https://man7.org/linux/man-pages/man1/mpstat.1.html
- `pidstat(1)`: https://man7.org/linux/man-pages/man1/pidstat.1.html
- `sar(1)`: https://man7.org/linux/man-pages/man1/sar.1.html
- `sadf(1)`: https://man7.org/linux/man-pages/man1/sadf.1.html
- `vmstat(8)`: https://man7.org/linux/man-pages/man8/vmstat.8.html
- `top(1)`: https://man7.org/linux/man-pages/man1/top.1.html
- `ps(1)`: https://man7.org/linux/man-pages/man1/ps.1.html
- `pstree(1)`: https://man7.org/linux/man-pages/man1/pstree.1.html
- `uptime(1)`: https://man7.org/linux/man-pages/man1/uptime.1.html
- `w(1)`: https://man7.org/linux/man-pages/man1/w.1.html
- `lsof(8)`: https://man7.org/linux/man-pages/man8/lsof.8.html
- `netstat(8)`: https://man7.org/linux/man-pages/man8/netstat.8.html
- `iotop` project: https://github.com/Tomas-M/iotop
- `iptraf-ng` project: https://github.com/iptraf-ng/iptraf-ng
- `ethtool`: https://man7.org/linux/man-pages/man8/ethtool.8.html
- `fio` documentation: https://fio.readthedocs.io/en/latest/fio_doc.html
- `iperf3` documentation: https://software.es.net/iperf/
- `bcc` tools (`biolatency`, `biosnoop`, `tcplife`, `tcpretrans`): https://github.com/iovisor/bcc
- `bpftrace`: https://github.com/bpftrace/bpftrace
- `perf` wiki: https://perfwiki.github.io/main/
- `nftables` wiki (counters, sets, maps, flowtables, `notrack`): https://wiki.nftables.org/wiki-nftables/index.php/Main_Page
- `conntrack-tools`: https://conntrack-tools.netfilter.org/manual.html
- netfilter project: https://www.netfilter.org/documentation/

**systemd resource control and measurement**

- `systemd.resource-control(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html
- `systemd-cgtop(1)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-cgtop.html
- `systemd.slice(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.slice.html
- `systemd.timer(5)` (for the `sysstat-collect.timer` override): https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html

**Monitoring stack used in the manifests**

- Prometheus `node_exporter` (collector list, PSI collector): https://github.com/prometheus/node_exporter
- Prometheus recording and alerting rules: https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/ and https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Ansible `ansible.posix.sysctl` module: https://docs.ansible.com/ansible/latest/collections/ansible/posix/sysctl_module.html
- Ansible `ansible.builtin.systemd_service` module: https://docs.ansible.com/ansible/latest/collections/ansible/builtin/systemd_service_module.html