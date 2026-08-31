# 103.6 — Modify Process Execution Priorities

**Certification:** LPIC-1 (LPI 101-500 / 102-500, version 5.0)
**Objective 103.6**, exam weight **3.12**
**Key knowledge:** default priority of a newly created job; running a program with a higher/lower priority than the default; changing the priority of a running process.
**Terms and utilities:** `nice`, `ps`, `renice`, `top`

---

## Lab requirements and safety

* A disposable Linux VM or container with a **modern kernel (≥ 5.4)**, `sudo`, `util-linux`, `procps-ng` and `coreutils`. Do not run this on a production host: several steps deliberately saturate a CPU.
* At least **2 logical CPUs** (`nproc`). One will be dedicated to the load, the rest keep your shell responsive.
* Two terminals on the same machine (a second SSH session or a second `tmux` pane) for the observation steps.
* Everything here is reversible; the **Cleanup** section at the end kills every process you start.

### Conventions used in this document

| Symbol | Meaning |
|---|---|
| `$` | Command run as your normal, unprivileged user |
| `#` / `sudo` | Command that requires root |
| `NI` | The **nice value**: `-20` (most favourable) … `0` (default) … `19` (least favourable) |
| `PR` / `PRI` | A *derived* priority number. Its scale and direction differ per tool — that is the point of Exercise 2 |
| `$CPU` | The CPU you pin the lab load to (set in Exercise 0) |

> Outputs shown below were captured on Debian 12 (kernel 6.1, procps-ng 4.0.2, util-linux 2.38). **PIDs, timings and the absolute `PRI` base will differ on your system.** Where a number is scale-dependent, the exercise tells you to record your own value.

---

## Exercise 0 — Build the lab harness

You need two things repeatedly: a process that burns exactly one CPU at a known nice value, and a way to measure how much CPU it actually got.

1. Pick the last logical CPU on the box and confirm it exists:

```
$ CPU=$(( $(nproc) - 1 )); echo "using CPU $CPU"
using CPU 3
$ uname -r
6.1.0-18-amd64
```

2. Create the load generator. Writing it to a file (instead of a shell one-liner) keeps the PID stable through `nice` and `taskset`, which both `exec` into the final command:

```
$ cat > /tmp/burn.sh <<'EOF'
#!/bin/bash
# usage: burn.sh <cpu> <nice> <pidfile>
# Records its own PID, then execs into a pinned, niced busy loop.
echo $$ > "$3"
exec nice -n "$2" taskset -c "$1" bash -c 'while :; do :; done'
EOF
$ chmod +x /tmp/burn.sh
```

3. Create the CPU accounting helper. Fields 14 (`utime`) and 15 (`stime`) of `/proc/<pid>/stat` are the total CPU time in clock ticks. The `sed` strips the `pid (comm)` prefix, because a process name may contain spaces and parentheses and would otherwise shift every field:

```
$ cpu_ticks() { sed 's/^.*) //' "/proc/$1/stat" | awk '{print $12 + $13}'; }
$ getconf CLK_TCK
100
```

4. Verify the harness end to end, then stop it:

```
$ /tmp/burn.sh "$CPU" 0 /tmp/p1.pid &
[1] 4310
$ P1=$(cat /tmp/p1.pid); echo "$P1"
4310
$ sleep 2; cpu_ticks "$P1"
198
$ kill "$P1"
```

**Check your understanding — Exercise 0**

* **Q0.1** — `/tmp/burn.sh` writes `$$` to a file and then calls `exec`. Why is the recorded PID still valid after `nice` and `taskset` have run?
* **Q0.2** — Why does the `sed` expression use a *greedy* `.*)` instead of matching the first `)`?
* **Q0.3** — `cpu_ticks` returned `198` after `sleep 2` on a 100 Hz tick. What does that tell you about how much of one CPU the process consumed, and why is it not exactly `200`?

---

## Exercise 1 — The default priority and how it is inherited

1. Ask `nice` what the current nice value of your shell is. Called with no arguments it does not launch anything; it prints its own inherited niceness:

```
$ nice
0
```

2. Confirm it from the kernel's own view. Field 18 is `priority`, field 19 is `nice` (post-`sed`: `$16` and `$17`):

```
$ sed 's/^.*) //' /proc/$$/stat | awk '{print "kernel_prio="$16, "nice="$17}'
kernel_prio=20 nice=0
```

3. Show that the nice value is **inherited by children at fork time**:

```
$ nice -n 7 bash -c 'nice; sleep 1 & nice'
7
7
```

4. Show that it **survives `execve`** — the value is a property of the task, not of the program image:

```
$ nice -n 7 bash -c 'exec nice'
7
```

5. Show that changing a parent afterwards does **not** retroactively change existing children. Start a child, then renice only the parent:

```
$ bash -c 'sleep 300 & echo "child=$!"; echo "parent=$$"'
child=4402
parent=4401
$ renice -n 5 -p 4402 >/dev/null; ps -o pid,ppid,ni,comm -p 4402
    PID    PPID  NI COMMAND
   4402       1   5 sleep
$ kill 4402
```

**Check your understanding — Exercise 1**

* **Q1.1** — What is the default nice value of a process created by a normal login shell, and what is the full legal range?
* **Q1.2** — A daemon is started by systemd with `Nice=5`. It forks a worker, which `exec`s `/usr/bin/python3`. What is the worker's nice value, and why?
* **Q1.3** — You `renice` a running shell to `10`. Which of its processes are affected: the ones already running, the ones started afterwards, both, or neither?

---

## Exercise 2 — Reading the numbers: `NI`, `PR`, `PRI` and `/proc`

Three tools show "priority" and **none of them uses the same scale**. Only `NI` is portable.

1. In terminal A, start a niced load and keep it running:

```
$ /tmp/burn.sh "$CPU" 0 /tmp/p1.pid & P1=$(cat /tmp/p1.pid)
[1] 4507
```

2. Read it with `top` in batch mode (`-b` non-interactive, `-n 1` one iteration, `-p` restrict to a PID). Record the `PR` and `NI` columns:

```
$ top -b -n 1 -p "$P1" | tail -n 3

    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
   4507 student   20   0    8192   3456   3200 R  99.7   0.0   0:12.44 burn.sh
```

3. Read the same process with `ps`, twice, in two different formats. **Record both `PRI` values — your build's base may differ from the sample:**

```
$ ps -o pid,ni,pri,psr,pcpu,comm -p "$P1"
    PID  NI PRI PSR %CPU COMMAND
   4507   0  19   3 99.7 burn.sh
$ ps -l -p "$P1"
F S   UID   PID  PPID  C PRI  NI ADDR SZ WCHAN  TTY          TIME CMD
0 R  1000  4507  4310 99  80   0 -  2048 -      pts/0    00:00:20 burn.sh
```

4. Now change the nice value and re-read **all three** views, noting the *direction* each number moves:

```
$ renice -n 5 -p "$P1"
4507 (process ID) old priority 0, new priority 5
$ top -b -n 1 -p "$P1" | tail -n 2
   4507 student   25   5    8192   3456   3200 R  99.3   0.0   0:31.02 burn.sh
$ ps -o pid,ni,pri -p "$P1"; ps -l -p "$P1" | tail -n 1
    PID  NI PRI
   4507   5  14
0 R  1000  4507  4310 99  85   5 -  2048 -      pts/0    00:00:31 burn.sh
$ sed 's/^.*) //' /proc/$P1/stat | awk '{print "kernel_prio="$16, "nice="$17}'
kernel_prio=25 nice=5
```

5. Leave the process running for the next exercise, or kill it with `kill "$P1"`.

**Check your understanding — Exercise 2**

* **Q2.1** — From your own measurements, write the formula relating `top`'s `PR` column to `NI` for a normal (`SCHED_OTHER`) task. What does `top` print in `PR` for a real-time task instead?
* **Q2.2** — In your capture, `ps -o pri` moved *down* when `NI` went up, while `ps -l`'s `PRI` moved *up*. Which of the two is "higher number = better priority"? Which single column is safe to script against?
* **Q2.3** — `%CPU` stayed at ~99% after the process was reniced from 0 to 5. Does that mean `renice` had no effect? Explain.

---

## Exercise 3 — `nice(1)`: syntax, the obsolete-form trap, and clamping

1. Start from the documented default. With no adjustment, `nice` adds **10**:

```
$ nice nice
10
```

2. Use the modern, unambiguous form. `-n` takes the **increment**, relative to the caller's current nice value:

```
$ nice -n 5 nice
5
```

3. Trigger the classic exam trap. The obsolete form `nice -10` does **not** mean "nice value −10"; the historic syntax treats the digits as the increment:

```
$ nice -10 nice
10
```

4. Prove that increments **compose** — each `nice` is relative to what it inherited, not absolute:

```
$ nice -n 5 nice -n 5 nice
10
$ nice -n 5 nice -n 5 nice -n 19 nice
19
```

5. Observe **clamping**. Out-of-range values are silently saturated, not rejected:

```
$ nice -n 100 nice
19
$ sudo nice -n -100 nice
-20
```

6. Try to raise priority as an unprivileged user, and read the behaviour carefully:

```
$ nice -n -5 nice
nice: cannot set niceness: Permission denied
0
$ nice -n -5 sh -c 'echo command ran anyway'; echo "exit=$?"
nice: cannot set niceness: Permission denied
command ran anyway
exit=0
```

7. Compare with root, where the request succeeds:

```
$ sudo nice -n -5 nice
-5
```

**Check your understanding — Exercise 3**

* **Q3.1** — A batch job is launched from a cron entry as `nice -5 /usr/local/bin/reindex`. The author intended "run with more CPU than normal". What nice value does the job actually get, and how should the line be written to express the original intent?
* **Q3.2** — In step 6 the command still ran and the exit status was `0`. Why is that dangerous in a script that assumes `nice` enforces a priority, and how would you detect the failure?
* **Q3.3** — Your shell is already at nice 5. What does `nice -n 3 nice` print, and what would `renice -n 3 -p $$` have produced instead?

---

## Exercise 4 — Measuring what nice actually buys you

The kernel does not schedule "10% slower". It assigns each nice level a **weight**, and CPU is split in proportion to weight. Nice 0 has weight 1024, and each step of one nice level multiplies the weight by roughly **1.25**.

| NI | −20 | −10 | −5 | 0 | 1 | 5 | 10 | 15 | 19 |
|---|---|---|---|---|---|---|---|---|---|
| weight | 88761 | 9548 | 3121 | **1024** | 820 | 335 | 110 | 36 | 15 |

1. Make the experiment deterministic: both processes must compete for **one CPU**, from the **same shell session** (Exercise 7 explains why the session matters). Start them at nice 0 and nice 5:

```
$ /tmp/burn.sh "$CPU" 0 /tmp/p1.pid & /tmp/burn.sh "$CPU" 5 /tmp/p2.pid &
[1] 4611
[2] 4612
$ P1=$(cat /tmp/p1.pid); P2=$(cat /tmp/p2.pid)
$ ps -o pid,ni,psr,comm -p "$P1","$P2"
    PID  NI PSR COMMAND
   4611   0   3 burn.sh
   4612   5   3 burn.sh
```

2. Take a 20-second delta of consumed CPU ticks and turn it into a share:

```
$ a1=$(cpu_ticks $P1); a2=$(cpu_ticks $P2); sleep 20
$ b1=$(cpu_ticks $P1); b2=$(cpu_ticks $P2)
$ d1=$((b1-a1)); d2=$((b2-a2))
$ echo "nice0=$d1 ticks  nice5=$d2 ticks"; awk -v a=$d1 -v b=$d2 \
    'BEGIN{printf "share: %.1f%% / %.1f%%\n", 100*a/(a+b), 100*b/(a+b)}'
nice0=1497 ticks  nice5=494 ticks
share: 75.2% / 24.8%
```

3. Compare against the weight table: `1024 / (1024 + 335) = 75.4 %`. Your result should land within a couple of percent.

4. Widen the gap to nice 10 and predict **before** you measure:

```
$ renice -n 10 -p "$P2"
4612 (process ID) old priority 5, new priority 10
$ a1=$(cpu_ticks $P1); a2=$(cpu_ticks $P2); sleep 20
$ b1=$(cpu_ticks $P1); b2=$(cpu_ticks $P2)
$ awk -v a=$((b1-a1)) -v b=$((b2-a2)) \
    'BEGIN{printf "share: %.1f%% / %.1f%%\n", 100*a/(a+b), 100*b/(a+b)}'
share: 90.1% / 9.9%
```

5. Now remove the competition and watch the nice-19 process take the whole CPU:

```
$ renice -n 19 -p "$P2" >/dev/null
$ kill "$P1"
$ sleep 5; top -b -n 1 -p "$P2" | tail -n 2
   4612 student   39  19    8192   3456   3200 R  99.7   0.0   1:22.10 burn.sh
$ kill "$P2"
```

**Check your understanding — Exercise 4**

* **Q4.1** — Using the weight table, predict the CPU split between a nice 0 and a nice −5 process competing for one CPU. Show the arithmetic.
* **Q4.2** — Step 5 shows a nice-19 process at 99.7% CPU. Restate precisely what a nice value guarantees and what it does not.
* **Q4.3** — Your host has 8 CPUs and one nice-0 process competing with one nice-19 process. Why would this experiment show ~100% / ~100% instead of 98.6% / 1.4%, and what did the lab do to avoid that?
* **Q4.4** — A colleague claims "each nice level is 10% of the CPU". In what sense is that true, and in what sense is it wrong?

---

## Exercise 5 — `renice`: the one-way street and `RLIMIT_NICE`

1. Start a process you own at the default priority:

```
$ /tmp/burn.sh "$CPU" 0 /tmp/p1.pid & P1=$(cat /tmp/p1.pid)
[1] 4703
```

2. Lower its priority (increase the nice value). Unprivileged users may always do this to their own processes:

```
$ renice -n 12 -p "$P1"
4703 (process ID) old priority 0, new priority 12
```

3. Try to undo it — **still as the same user, on your own process, back to a value you started from**:

```
$ renice -n 0 -p "$P1"
renice: failed to set priority for 4703 (process ID): Permission denied
```

4. Inspect the resource limit that governs this. `RLIMIT_NICE` expresses a *ceiling* as `20 − limit`; the default `0` means "may never go below nice 20", i.e. never negative:

```
$ ulimit -e
0
$ prlimit --nice --pid $$
RESOURCE DESCRIPTION                             SOFT HARD UNITS
NICE     max nice prio allowed to raise             0    0
```

5. Raise the hard limit on your running shell from outside (raising a hard limit needs `CAP_SYS_RESOURCE`), then retry as your unprivileged self:

```
$ sudo prlimit --pid $$ --nice=30:30
$ ulimit -e
30
$ nice -n -10 nice
-10
$ nice -n -11 nice
nice: cannot set niceness: Permission denied
0
```

6. Confirm that root is unconstrained, and clean up:

```
$ sudo renice -n -5 -p "$P1"
4703 (process ID) old priority 12, new priority -5
$ kill "$P1"
```

7. Make the permission persistent the correct way, rather than by handing out `sudo`. This file grants a group the right to go down to nice −10:

```
# /etc/security/limits.d/90-lab-nice.conf
# <domain>  <type>  <item>     <value>
@rt-operators   -    nice       -10
@rt-operators   -    priority   -10
```

`nice` sets the floor a member may lower to; `priority` sets the nice value their login shell starts at. The file is read by `pam_limits.so`, so it applies at **next login**, not to existing sessions.

**Check your understanding — Exercise 5**

* **Q5.1** — State the permission rule for `renice` in one sentence covering both directions and both privilege levels.
* **Q5.2** — `ulimit -e` prints `30`. What is the lowest nice value this user can request, and what is the formula?
* **Q5.3** — In step 3 the user could not restore nice 0 on a process they own and started themselves. What class of attack does that rule prevent?
* **Q5.4** — After editing `/etc/security/limits.d/90-lab-nice.conf`, a member of `rt-operators` still gets `Permission denied` in their current SSH session. What is the most likely reason?

---

## Exercise 6 — Bulk operations: by process group and by user, and their blast radius

`renice` takes three kinds of identifier: `-p` PID (default), `-g` process **group** ID, `-u` user name or UID.

1. Start a small process group. In an interactive shell, each job is its own process group, and the group ID equals the leader's PID:

```
$ (sleep 300 & sleep 300 & sleep 300 & wait) &
[1] 4801
$ ps -o pid,pgid,ni,comm --ppid 4801
    PID    PGID  NI COMMAND
   4802    4801   0 sleep
   4803    4801   0 sleep
   4804    4801   0 sleep
```

2. Renice the whole group with one call:

```
$ renice -n 8 -g 4801
4801 (process group ID) old priority 0, new priority 8
$ ps -o pid,pgid,ni,comm --ppid 4801
    PID    PGID  NI COMMAND
   4802    4801   8 sleep
   4803    4801   8 sleep
   4804    4801   8 sleep
```

3. Now the blast radius. `-u` hits **every process owned by that user**, including their login shell, their editor and their SSH session — and, if the user is a service account, the service itself:

```
$ ps -u "$USER" -o pid,ni,comm --no-headers | wc -l
27
$ renice -n 3 -u "$USER"
1000 (user ID) old priority 0, new priority 3
$ ps -u "$USER" -o ni --no-headers | sort | uniq -c
     27 3
```

4. Note the direction problem this creates. Every one of those 27 processes is now at nice 3 and, as an unprivileged user, **you cannot put them back**:

```
$ renice -n 0 -u "$USER"
renice: failed to set priority for 1000 (user ID): Permission denied
$ sudo renice -n 0 -u "$USER"
1000 (user ID) old priority 3, new priority 0
```

5. Kill the group and confirm nothing is left:

```
$ kill -- -4801 2>/dev/null; ps -o pid,ni,comm --ppid 4801
    PID  NI COMMAND
```

6. The surgical alternative — select processes by name and renice only those:

```
$ pgrep -d, -f 'sleep 300'
4901,4902
$ renice -n 10 -p $(pgrep -d' ' -f 'sleep 300')
```

**Check your understanding — Exercise 6**

* **Q6.1** — `renice -n 19 -u postgres` is run on a database server to "free up CPU for the web tier". Describe two concrete ways this can make overall latency worse rather than better.
* **Q6.2** — Which identifier type does `renice` assume when you give a bare number with no `-p`, `-g` or `-u`?
* **Q6.3** — Why is `renice -n 5 -g <PGID>` usually safer than `-u <user>` for taming a runaway batch job launched from a shell?

---

## Exercise 7 — Why `nice` sometimes appears to do nothing: autogroups and cgroups

This is the single most common production surprise with `nice`, and it is invisible from the `ps`/`top` columns.

1. Check whether **autogrouping** is enabled and see your shell's autogroup:

```
$ cat /proc/sys/kernel/sched_autogroup_enabled
1
$ cat /proc/$$/autogroup
/autogroup-231 nice 0
```

2. Reproduce the surprise. Start the two burners in **different sessions** (`setsid` creates a new session, and therefore a new autogroup), with an extreme nice spread:

```
$ setsid /tmp/burn.sh "$CPU" 0  /tmp/p1.pid
$ setsid /tmp/burn.sh "$CPU" 19 /tmp/p2.pid
$ P1=$(cat /tmp/p1.pid); P2=$(cat /tmp/p2.pid)
$ ps -o pid,ni,sid,psr,comm -p "$P1","$P2"
    PID  NI   SID PSR COMMAND
   5011   0  5011   3 burn.sh
   5012  19  5012   3 burn.sh
```

3. Measure the split. Nice 0 versus nice 19 should be ~98.6% / ~1.4% by the weight table:

```
$ a1=$(cpu_ticks $P1); a2=$(cpu_ticks $P2); sleep 20
$ b1=$(cpu_ticks $P1); b2=$(cpu_ticks $P2)
$ awk -v a=$((b1-a1)) -v b=$((b2-a2)) \
    'BEGIN{printf "share: %.1f%% / %.1f%%\n", 100*a/(a+b), 100*b/(a+b)}'
share: 50.2% / 49.8%
```

4. Fix it at the level that actually applies — the autogroup's own nice value, written through `/proc/<pid>/autogroup`:

```
$ cat /proc/$P2/autogroup
/autogroup-244 nice 0
$ echo 19 | sudo tee /proc/$P2/autogroup
19
$ cat /proc/$P2/autogroup
/autogroup-244 nice 19
$ a1=$(cpu_ticks $P1); a2=$(cpu_ticks $P2); sleep 20
$ b1=$(cpu_ticks $P1); b2=$(cpu_ticks $P2)
$ awk -v a=$((b1-a1)) -v b=$((b2-a2)) \
    'BEGIN{printf "share: %.1f%% / %.1f%%\n", 100*a/(a+b), 100*b/(a+b)}'
share: 98.4% / 1.6%
$ kill "$P1" "$P2"
```

5. Inspect the other grouping layer that outranks `nice` — **cgroup v2**. Each systemd unit and each login session is its own cgroup, and CPU is divided between cgroups by `cpu.weight` *before* nice is consulted inside them:

```
$ cat /proc/$$/cgroup
0::/user.slice/user-1000.slice/session-42.scope
$ CG=/sys/fs/cgroup$(cut -d: -f3 /proc/$$/cgroup)
$ cat "$CG/cgroup.controllers"
cpuset cpu io memory pids
$ cat "$CG/cpu.weight" 2>/dev/null || echo "cpu controller not enabled here"
100
```

6. Compare the two knobs on a real unit. `Nice=` acts *inside* the unit's cgroup; `CPUWeight=` decides how much the unit gets *versus other units*:

```
$ systemctl show -p Nice -p CPUWeight -p IOWeight sshd.service
Nice=0
CPUWeight=[not set]
IOWeight=[not set]
```

7. Express the production-correct version of "this batch job must yield to everything else" as a drop-in:

```ini
# /etc/systemd/system/batch-indexer.service.d/10-priority.conf
[Service]
# Within its own cgroup: deprioritise the threads.
Nice=10
# Versus every other unit on the box: take ~1/5 of a fair share.
CPUWeight=20
IOWeight=20
CPUAccounting=yes
IOAccounting=yes
```

```
$ sudo systemctl daemon-reload
$ sudo systemctl restart batch-indexer.service
$ systemctl show -p Nice -p CPUWeight batch-indexer.service
Nice=10
CPUWeight=20
```

8. For an ad-hoc command, get the same containment without editing units:

```
$ sudo systemd-run --scope -p Nice=10 -p CPUWeight=20 /usr/local/bin/reindex
Running scope as unit: run-r3f2c1.scope
```

**Check your understanding — Exercise 7**

* **Q7.1** — Two CPU-bound jobs, one at nice 0 and one at nice 19, get 50/50 of a CPU. Give two distinct grouping mechanisms that can cause this, and one command that reveals each.
* **Q7.2** — What is the scheduling scope of an autogroup, and which system call creates a new one?
* **Q7.3** — A unit has `Nice=19` and `CPUWeight=10000`. Under contention with other units, is it a low-priority or a high-priority workload? Explain the two layers.
* **Q7.4** — Why does the default `cpu.weight` of `100` correspond to nice `0`, and what is the rough conversion for one nice step?

---

## Exercise 8 — Diagnostic playbook: choose the right knob

`nice` only redistributes **CPU run time**. Half of production "priority" problems are not CPU problems at all.

1. Find the CPU consumers, sorted, with their nice values, in one non-interactive shot suitable for a script or an alert:

```
$ ps -eo pid,user,ni,pri,pcpu,pmem,stat,etimes,comm --sort=-pcpu | head -n 6
    PID USER      NI PRI %CPU %MEM STAT ETIMES COMMAND
   5210 batch      0  19 99.4  0.3 R      1841 reindex
   5233 www-data   0  19 41.2  2.1 R       620 nginx
      1 root       0  19  0.1  0.4 Ss    98211 systemd
```

2. Cross-check with `top`, which reports *instantaneous* CPU while `ps -o pcpu` reports the **average over the process's whole lifetime** — an hours-old process that was busy at start will lie to you in `ps`:

```
$ top -b -n 2 -d 2 -o %CPU -p 5210 | tail -n 2
   5210 batch     20   0  412M  9.8M  3.1M R  99.0   0.3   30:41.09 reindex
```

3. Change it interactively from inside `top`: press **`r`**, type the PID, press Enter, type the new nice value, press Enter. Then press **`q`**. (Requesting a negative value here fails for an unprivileged user exactly as `renice` does.)

4. Establish whether CPU is even the constraint. A process in state `D` is blocked on I/O, and no nice value will help it:

```
$ ps -eo pid,stat,wchan:24,comm --sort=stat | awk '$2 ~ /^D/'
   5301 D    folio_wait_bit_common    rsync
```

5. For that case, reach for the I/O knob instead — and know its limitation:

```
$ ionice -p 5301
none: prio 4
$ sudo ionice -c 2 -n 7 -p 5301
$ ionice -p 5301
best-effort: prio 7
$ cat /sys/block/sda/queue/scheduler
[none] mq-deadline
```

The last line is the caveat: I/O classes are honoured by **BFQ** (and historically CFQ). With `none` or `mq-deadline` selected, `ionice` sets the value and the block layer ignores it. Note also that when no class is set explicitly, the best-effort I/O priority is *derived* from the CPU nice value as `(nice + 20) / 5` — which is why `nice 0` shows `prio 4`.

6. Confirm what scheduling policy you are actually dealing with before blaming nice. Nice values are meaningless for real-time policies:

```
$ chrt -p 5210
pid 5210's current scheduling policy: SCHED_OTHER
pid 5210's current scheduling priority: 0
$ chrt -p 1
pid 1's current scheduling policy: SCHED_OTHER
pid 1's current scheduling priority: 0
```

7. Finally, check whether the problem is *placement* rather than *priority* — a process pinned to a saturated CPU while others idle:

```
$ taskset -cp 5210
pid 5210's current affinity list: 3
$ ps -eo psr,comm --no-headers | sort | uniq -c | sort -rn | head -n 4
     12 3 reindex
      3 0 nginx
```

**Check your understanding — Exercise 8**

* **Q8.1** — `ps -o pcpu` shows 3% and `top` shows 99% for the same PID. Which is wrong, and why are they both "correct"?
* **Q8.2** — For each symptom, name the tool: (a) job is CPU-bound and starving interactive users; (b) job is saturating the disk during backups; (c) job must never be preempted by normal work; (d) job is on the wrong CPU.
* **Q8.3** — You set `ionice -c 3` (idle) on a backup job and see no change at all. Give the most likely reason and the command that confirms it.
* **Q8.4** — Explain why lowering the priority of a process that holds a widely contended lock can *increase* total system latency. What is this phenomenon called?

---

## Cleanup

```
$ for f in /tmp/p1.pid /tmp/p2.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
$ pkill -f 'while :; do :; done' 2>/dev/null
$ pkill -f 'sleep 300' 2>/dev/null
$ rm -f /tmp/burn.sh /tmp/p1.pid /tmp/p2.pid
$ ps -eo pid,ni,comm --sort=-pcpu | head -n 3
    PID  NI COMMAND
      1   0 systemd
```

If you edited `/etc/security/limits.d/90-lab-nice.conf` or created a systemd drop-in, remove them and run `sudo systemctl daemon-reload`. Limits set with `prlimit` disappear with the shell.

---

## Exam-day summary

| Fact | Value |
|---|---|
| Default nice value of a new process | `0` (inherited from the parent) |
| Legal range | `-20` (most favourable) … `19` (least favourable) |
| `nice` with no adjustment | adds **`+10`** |
| `nice -n X cmd` | X is an **increment** relative to the caller |
| `nice -10 cmd` | obsolete form → increment **`+10`**, *not* `-10` |
| `nice` with no arguments | prints the current nice value |
| Out-of-range values | clamped to `-20` / `19`, not rejected |
| `renice` on Linux (util-linux) | the priority argument is **absolute** |
| Unprivileged user may | only **increase** the nice value, only on their own processes |
| Restoring a raised nice value | requires root / `CAP_SYS_NICE` |
| `renice` selectors | `-p` PID (default), `-g` PGID, `-u` user |
| `top` `PR` column | `20 + NI`, or `rt` for real-time tasks |
| Change priority inside `top` | key **`r`** |
| Kernel view | `/proc/<pid>/stat` field 18 = `20+nice`, field 19 = `nice` |
| Nice affects | CPU run-time share only — not memory, not I/O bandwidth |
| Nice is inherited | across `fork()`, and preserved across `execve()` |

---

## Sources

* LPI — Exam 101 Objectives, v5.0, objective 103.6: <https://www.lpi.org/our-certifications/exam-101-objectives/>
* `nice(1)`: <https://man7.org/linux/man-pages/man1/nice.1.html>
* GNU coreutils, `nice` invocation: <https://www.gnu.org/software/coreutils/manual/html_node/nice-invocation.html>
* `renice(1)`: <https://man7.org/linux/man-pages/man1/renice.1.html>
* `top(1)`: <https://man7.org/linux/man-pages/man1/top.1.html>
* `ps(1)`: <https://man7.org/linux/man-pages/man1/ps.1.html>
* `setpriority(2)` / `getpriority(2)`: <https://man7.org/linux/man-pages/man2/setpriority.2.html>
* `getrlimit(2)` — `RLIMIT_NICE`: <https://man7.org/linux/man-pages/man2/getrlimit.2.html>
* `sched(7)` — policies, nice, autogroup: <https://man7.org/linux/man-pages/man7/sched.7.html>
* `proc(5)` — `/proc/[pid]/stat`, `/proc/[pid]/autogroup`: <https://man7.org/linux/man-pages/man5/proc.5.html>
* Linux kernel — nice design rationale: <https://docs.kernel.org/scheduler/sched-nice-design.html>
* Linux kernel — CFS design: <https://docs.kernel.org/scheduler/sched-design-CFS.html>
* Linux kernel — cgroup v2 (`cpu.weight`, `io.weight`): <https://docs.kernel.org/admin-guide/cgroup-v2.html>
* `systemd.exec(5)` — `Nice=`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html>
* `systemd.resource-control(5)` — `CPUWeight=`, `IOWeight=`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html>
* `limits.conf(5)`: <https://man7.org/linux/man-pages/man5/limits.conf.5.html>
* `ionice(1)`: <https://man7.org/linux/man-pages/man1/ionice.1.html>
* `chrt(1)`: <https://man7.org/linux/man-pages/man1/chrt.1.html>
* `taskset(1)`: <https://man7.org/linux/man-pages/man1/taskset.1.html>

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 0

**A0.1** — Both `nice` and `taskset` are *wrapper* utilities: they perform their syscall (`setpriority(2)` and `sched_setaffinity(2)` respectively) and then `execve()` the remaining command line. `execve` replaces the process image **without creating a new process**, so the PID never changes. `$$` recorded before the `exec` is the same PID that ends up running the busy loop. This is also why `nice` and `taskset` compose freely in either order on the same command line.

**A0.2** — Field 2 of `/proc/<pid>/stat` is `comm`, wrapped in parentheses, and it may itself contain spaces *and* parentheses (a process can be named `my (weird) app`). Every field after `comm` is numeric and contains no `)`. A greedy `.*)` therefore matches through the **last** `)` on the line, which is guaranteed to be the closing parenthesis of `comm`. A non-greedy match would stop at the first `)` inside the name and shift every subsequent field, silently reading the wrong column.

**A0.3** — `CLK_TCK` is 100, so 198 ticks = 1.98 seconds of CPU time in 2 seconds of wall clock — approximately one full CPU (~99%). It is not exactly 200 because the process does not start burning at the instant `sleep` starts, and it is preempted briefly by kernel threads, timer interrupts and the shell itself. Tick accounting is also sampled, not exact.

---

### Exercise 1

**A1.1** — The default is **0**. The legal range is **−20 to 19** inclusive: −20 is the most favourable (largest CPU share), 19 the least favourable. The default is not a property of "login shells" specifically — it is inherited from the parent, and the chain traces back to PID 1, which normally runs at nice 0.

**A1.2** — **5.** Nice is a per-task attribute inherited by children at `fork()` and preserved across `execve()`. Neither forking nor replacing the program image resets it. This is exactly why `Nice=` on a systemd unit propagates to the whole process tree the unit spawns — and why a shell you reniced hands the new value to everything you launch from it afterwards.

**A1.3** — **Only the ones started afterwards.** `renice` calls `setpriority(2)` on the targeted task; there is no recursion into the process tree. Already-running children keep the value they inherited at their own fork time. To catch the existing ones too you must target them explicitly — `renice -n 10 -g <PGID>` for the whole job's process group, or iterate over `pgrep -P <pid>`.

---

### Exercise 2

**A2.1** — For `SCHED_OTHER` tasks, `top`'s `PR = 20 + NI`, giving the range 0 (at NI −20) to 39 (at NI 19). Because the number *rises* as priority *falls*, a lower `PR` is better. For real-time tasks (`SCHED_FIFO` / `SCHED_RR`), `top` prints the literal string **`rt`** in the `PR` column, since those tasks are scheduled ahead of every normal task and the nice value does not apply to them.

**A2.2** — `ps -o pri` is the "higher number = higher priority" convention, so it moves *down* as `NI` goes up; `ps -l` reports a kernel-internal scale where the number moves *up* with `NI`. The absolute base of both depends on the `procps-ng` build and on the format specifier used (`pri`, `opri`, `intpri` are all distinct fields with different scales). **`NI` is the only column that is stable across tools, distributions and versions** — it is the value you set and the value the exam asks about. Script against `NI`, never against `PRI`/`PR`.

**A2.3** — No. `%CPU` measures *how much CPU the process got*, not *how much it is entitled to*. Nice values only matter under **contention**: they set the ratio in which runnable tasks divide a CPU that is not big enough for all of them. With no competitor on that CPU, a nice-19 task gets 100% just like a nice-0 task would. This is the single most common reason people conclude that "renice did nothing" — the correct test is the one in Exercise 4: two competing tasks, one CPU.

---

### Exercise 3

**A3.1** — It gets nice **+10** (increment 10, *less* favourable), which is the opposite of the intent. The digits after a bare `-` in the obsolete syntax are read as the increment, and a leading `-` there is part of the option marker, not a minus sign. To actually raise priority you need both the modern `-n` form with an explicit negative number *and* the privilege to use it: `nice -n -5 /usr/local/bin/reindex` run as root (or by a user whose `RLIMIT_NICE` permits −5). Anything negative from an ordinary cron user will be refused.

**A3.2** — GNU `nice` treats a failed `setpriority()` as a **warning**, not a fatal error: it prints the diagnostic to stderr and then runs the command anyway, so the exit status you observe is the *command's* status. A wrapper script that only checks `$?` will conclude the priority was applied. Detect it either by capturing stderr (`nice -n -5 cmd 2>err.log` and testing the file), or — much better — by verifying the result from the kernel after the fact: `ps -o ni= -p <pid>`, or have the process print `nice` itself. A cron job that *must* run niced should be launched under `systemd-run -p Nice=…`, which fails the unit if the property cannot be applied.

**A3.3** — `nice -n 3 nice` prints **8**, because `-n` is an increment applied to the caller's current value (5 + 3). `renice -n 3 -p $$` would instead have set the shell to the **absolute** value **3** — on util-linux, `renice`'s priority argument is not an increment. This asymmetry between the two commands is the most frequently missed detail in this objective. (It is also a portability trap: POSIX specifies `renice -n` as relative, and some non-Linux `renice` implementations behave that way. Check `man renice` on any unfamiliar system.)

---

### Exercise 4

**A4.1** — Nice 0 has weight 1024, nice −5 has weight 3121. Total = 4145. Nice 0 gets `1024 / 4145 = 24.7 %`; nice −5 gets `3121 / 4145 = 75.3 %`. Note the symmetry with the nice 0 / nice +5 case from step 2 — what matters is the *difference* of five nice levels, not the absolute values.

**A4.2** — A nice value guarantees only a **proportional share of a contended CPU relative to other runnable tasks on that same CPU and in that same scheduling group**. It guarantees nothing in absolute terms: it does not cap CPU usage, does not reserve CPU, does not limit memory, page-cache pressure, I/O bandwidth, or network usage, and does not prevent the process from holding locks that block higher-priority work. On an otherwise idle CPU, nice 19 and nice −20 both get 100%.

**A4.3** — With 8 CPUs and only 2 runnable tasks, the load balancer places them on **different CPUs**, so they never compete and both run at ~100%. Nice values only take effect when tasks are contending for the same runqueue. The lab pinned both processes to a single CPU with `taskset -c "$CPU"` precisely to force contention; you can verify the placement with the `PSR` column of `ps` or `taskset -cp <pid>`.

**A4.4** — It is a reasonable *rule of thumb for one step*: consecutive weights differ by a factor of ~1.25 (1024 → 820), so a one-level change shifts roughly 10 percentage points of a two-task split (55/45 instead of 50/50). It is wrong as a *linear* model: the relationship is geometric, so ten levels is not "100%" — it is `1.25^10 ≈ 9.3×`, i.e. about a 90/10 split, and 39 levels is a ~5900× ratio, not a nonsensical 390%.

---

### Exercise 5

**A5.1** — An unprivileged user may only **increase** the nice value (lower the priority) of processes whose real or effective UID matches their own, and may never decrease it again — not even back to a value the process previously had. A process with `CAP_SYS_NICE` (normally root) may set any value in `[-20, 19]` on any process. The one exception to "never decrease" is `RLIMIT_NICE`: a user may lower nice down to the floor `20 − RLIMIT_NICE`, which is `20` (i.e. no decrease at all) by default.

**A5.2** — The lowest requestable value is **−10**, from `20 − RLIMIT_NICE = 20 − 30 = −10`. The limit is deliberately encoded this way — as a positive number that inverts to a nice floor — because `getrlimit` values are unsigned. `ulimit -e 0` therefore yields a floor of 20, which is above the maximum 19, meaning "may not lower priority at all".

**A5.3** — Priority theft / self-serving resource escalation. If a user could freely restore priority, they could bypass any administrative deprioritisation: an admin reniced a runaway batch job to 19, and the owner would simply put it back to 0. More generally, the rule makes nice a **one-way ratchet** for unprivileged users, so a deprioritisation applied by the administrator (or by a batch wrapper) is durable, and no user can grant themselves a larger CPU share than their peers.

**A5.4** — `/etc/security/limits.d/*` is applied by the PAM module `pam_limits.so` **at session establishment**. The current SSH session was created before the file existed, so its process tree still carries the old `RLIMIT_NICE`. The member must log out and back in. (Check with `prlimit --nice --pid $$`. Note also that PAM limits do not apply to systemd *services* — those need `LimitNICE=` in the unit — and that the group must actually contain the user, which `id -nG <user>` confirms.)

---

### Exercise 6

**A6.1** — (a) **Priority inversion:** a deprioritised PostgreSQL backend holding a lightweight lock, a buffer pin or the WAL insert lock is preempted by web-tier processes; every other backend — and therefore every web request that needs the database — blocks behind it. Total latency rises even though "CPU was freed". (b) **Critical auxiliary processes get caught in the blast radius:** `-u postgres` also hits the checkpointer, the WAL writer, the autovacuum launcher and the archiver. A slow checkpointer lengthens recovery time and can stall the whole cluster when WAL segments back up; a starved autovacuum leads to bloat and, eventually, transaction-ID wraparound protection kicking in. The correct instrument for "the web tier matters more" is a cgroup-level `CPUWeight=` on the two units, not a per-user nice sweep.

**A6.2** — **PID** — `-p` is the default when no selector is given, so `renice 5 1234` and `renice -n 5 -p 1234` are equivalent. Because a bare leading negative number is ambiguous with an option, always prefer the explicit `-n <value> -p <pid>` form in scripts.

**A6.3** — A process group corresponds exactly to one **job**: the shell puts the pipeline and all its children into a single process group, so `-g` reaches precisely the runaway job's process tree and nothing else. `-u` reaches every process the user owns — their login shell, their SSH session, their editor, any other job, and any long-lived service running under the same account — which both misses the target's precision and creates a permission problem, since an unprivileged user cannot undo the change.

---

### Exercise 7

**A7.1** — (a) **Autogroups**: the kernel groups tasks by *session*; CPU is divided between autogroups first, and nice only orders tasks *within* one autogroup. Reveal with `cat /proc/<pid>/autogroup` (and check the feature with `cat /proc/sys/kernel/sched_autogroup_enabled`); confirm the two tasks are in different sessions with `ps -o pid,sid`. (b) **cgroup v2 with the `cpu` controller**: each systemd unit and login session is its own cgroup with its own `cpu.weight`, and the same nesting rule applies. Reveal with `cat /proc/<pid>/cgroup` and compare the `cpu.weight` of the two cgroups under `/sys/fs/cgroup/`. (A third, less common cause is that the two tasks are simply on different CPUs — check `ps -o psr`.)

**A7.2** — An autogroup is created for each new **session**, i.e. by `setsid(2)` — which is what a terminal emulator, an SSH login, `screen`/`tmux` and any daemonising process do. Every task in that session shares one scheduling entity. CPU is divided fairly *between* autogroups (weighted by each autogroup's own nice value in `/proc/<pid>/autogroup`), and each autogroup's share is then divided among its tasks according to their individual nice values. The feature exists so that a `make -j64` in one terminal cannot starve the rest of an interactive desktop.

**A7.3** — Under contention with other units it is a **high-priority** workload. `CPUWeight=10000` is the outer layer: against the default weight of 100, this unit claims roughly 100× the share of a competing unit at the cgroup level. `Nice=19` is the inner layer, applying only *among the threads of that unit* — it changes how the unit's large share is divided internally, not how big the share is. The combination is not necessarily a mistake (it can mean "this unit deserves a lot of CPU, and inside it these threads are the background ones"), but if the two knobs were set by different people with different intentions, it is a strong smell.

**A7.4** — The cgroup v2 `cpu.weight` scale is a rescaling of the same scheduler weights used for nice: nice 0's internal weight of 1024 maps to the cgroup default of **100**, and the range 1–10000 covers approximately the nice range. The conversion per nice step is the same factor of ~**1.25**: nice −1 ≈ weight 125, nice +1 ≈ weight 80, nice −5 ≈ weight ~305, nice +5 ≈ weight ~33. This is why `CPUWeight=` and `Nice=` feel like the same knob — they are the same mechanism applied at two different levels of the scheduling hierarchy.

---

### Exercise 8

**A8.1** — Neither is wrong; they measure different windows. `ps -o pcpu` reports `cputime / elapsed_time` — the average over the process's **entire lifetime**. A process that ran flat out for one minute and has now been idle for an hour shows a low single-digit percentage. `top` recomputes CPU usage from the delta between two samples, so it reports the **current** rate. For triage, always trust a delta-based figure: `top -b -n 2 -d <interval>` and read the *second* iteration (the first is lifetime-averaged, exactly like `ps`), or compute the delta yourself from `/proc/<pid>/stat` as in Exercise 0.

**A8.2** — (a) `nice` / `renice` — or, better on a systemd host, `CPUWeight=`; (b) `ionice` (with the BFQ caveat) or `IOWeight=` / `io.max` on cgroup v2; (c) `chrt` to set `SCHED_FIFO` or `SCHED_RR` — with great care, since a runaway real-time task can lock up a CPU entirely, which is what `kernel.sched_rt_runtime_us` exists to bound; (d) `taskset` (or `CPUAffinity=` in the unit) to change CPU affinity.

**A8.3** — The active block-layer I/O scheduler almost certainly does not implement I/O priorities. Since the removal of CFQ in kernel 5.0, only **BFQ** honours `ionice` classes; `none` and `mq-deadline` accept the setting and ignore it. Confirm with `cat /sys/block/<dev>/queue/scheduler` — the active one is in square brackets. Either switch that device to `bfq` (`echo bfq | sudo tee /sys/block/sda/queue/scheduler`, made persistent via a udev rule) or use cgroup v2 `io.weight`/`io.max` instead, which works independently of the elevator. Two further reasons for "no effect": the workload is dominated by writeback, which is issued by kernel flusher threads rather than the process, and so is not attributed to its I/O priority; and the device is NVMe with enough queue depth that there is no contention to arbitrate.

**A8.4** — When a low-priority task holds a lock that a high-priority task needs, the high-priority task cannot proceed until the lock is released — but the lock holder is being scheduled rarely precisely because you deprioritised it. The high-priority task's effective priority collapses to that of the lock holder, and any number of medium-priority tasks can preempt the holder, extending the stall indefinitely. This is **priority inversion** (in its unbounded form). Real-time kernels solve it with **priority inheritance** (the holder temporarily inherits the waiter's priority; `PTHREAD_PRIO_INHERIT` mutexes and rtmutexes implement this), but ordinary `SCHED_OTHER` nice values have no such mechanism. The practical rule: never deprioritise a process that participates in a shared lock, transaction or queue with latency-sensitive work — deprioritise workloads that are genuinely independent.

</details>