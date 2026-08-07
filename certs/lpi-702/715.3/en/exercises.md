# LPI BSD Specialist (Exam 702-100) — Topic 715.3: Create, Monitor and Kill Processes

**Weight:** 5  
**Target Certification:** LPI BSD Specialist (Exam 702-100, Version 1.0)  
**Reference Material:** [LPI BSD Specialist Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/) | [FreeBSD Manual Pages (Section 1 & 8)](https://man.freebsd.org/)

---

## 1. Architectural & Theoretical Foundations

### 1.1 The BSD Process Lifecycle & Kernel Mechanics
In BSD operating systems (such as FreeBSD, OpenBSD, and NetBSD), a process is represented internally by `struct proc` and managed via kernel subsystem interfaces (`sysctl kern.proc`). Process creation and management rely on several core syscalls and concepts:

*   **Process Creation (`fork(2)`, `vfork(2)`, `rfork(2)`, `execve(2)`):**
    *   `fork(2)` duplicates the calling process, creating an exact child copy via Copy-On-Write (COW) page tables.
    *   `vfork(2)` spawns a child while borrowing the parent's memory space and suspending the parent until `execve` or `_exit` is called (avoiding page-table copying overhead).
    *   `rfork(2)` (BSD-specific) allows granular sharing of file descriptor tables, virtual memory space, and signal handlers between parent and child threads/processes.
    *   `execve(2)` replaces the process memory image with a new executable binary image.
*   **Process Termination & Reaping (`exit(2)`, `wait4(2)`):**
    *   When a process terminates via `_exit(2)`, its kernel resources (file descriptors, memory maps) are reclaimed, but its `struct proc` entry persists as a **Zombie** state (`Z` state in `ps`) until its parent executes `wait4(2)` to harvest its exit status.
    *   If a parent process terminates before its child, the child is adopted by `init` (PID 1), which automatically reaps orphaned zombies.
*   **Process Groups, Sessions, and TTYs:**
    *   A **Process Group** is a collection of processes associated with a Process Group ID (`PGID`), created via `setpgid(2)`. Signals sent to a negative PID (e.g., `kill -9 -PGID`) hit every process in the group.
    *   A **Session** (`SID`) is a collection of process groups managed by a Session Leader (created via `setsid(2)`), typically bound to a Controlling Terminal (`tty`). Daemons call `setsid(2)` to detach from their controlling terminal.

```
       +-------------------------------------------------------------------+
       |                       Parent Process (PID P)                      |
       +-------------------------------------------------------------------+
                                         |
                                  fork() / rfork()
                                         v
       +-------------------------------------------------------------------+
       |                       Child Process (PID C)                       |
       |  - Shares or copies address space / file descriptors              |
       |  - Belongs to Process Group (PGID) and Session (SID)              |
       +-------------------------------------------------------------------+
                    |                                  |
               execve(bin)                         exit(code)
                    v                                  v
       +-------------------------+        +--------------------------------+
       |   New Executable Image  |        |    Zombie State (Z in ps)      |
       +-------------------------+        |  Struct proc retained until    |
                                          |  Parent calls wait4(code)      |
                                          +--------------------------------+
```

### 1.2 Signal Trapping & Kernel Delivery Mechanics
Signals are asynchronous notifications delivered by the FreeBSD kernel to a process thread.
*   **Uncatchable Signals:** `SIGKILL` (signal 9) and `SIGSTOP` (signal 19) cannot be caught, ignored, or blocked by a user-space application. The kernel immediately terminates or suspends the target thread frame.
*   **Catchable Core Signals:** `SIGHUP` (1), `SIGINT` (2), `SIGQUIT` (3), `SIGTERM` (15), `SIGUSR1` (30), `SIGUSR2` (31), `SIGALRM` (14), `SIGCHLD` (20), `SIGCONT` (18).
*   **FreeBSD Signal Masking:** Threads use `sigprocmask(2)` to temporarily block signals. Blocked signals remain in a pending state in the kernel's signal queue until unblocked.

### 1.3 FreeBSD Process Monitoring Subsystems
Unlike Linux environments relying heavily on pseudo-filesystems like `/proc`, modern FreeBSD handles process introspection primarily through high-performance `sysctl(3)` kernel MIB interfaces (`kern.proc.*`) and native utility suites (`procstat(1)`, `ps(1)`, `top(1)`).
*   **`procstat(1)`:** Directly queries kernel structures to inspect process file descriptors (`-f`), virtual memory maps (`-v`), thread kernel stacks (`-k`), signal dispositions (`-i`), environment variables (`-e`), and security credentials (`-c`).
*   **FreeBSD `killall(1)` vs. Linux/Solaris `killall(1)`:** On FreeBSD, `killall` matches processes by executable image name. *(Crucial SRE distinction: On System V / Solaris systems, `killall` terminates all active system processes. FreeBSD `killall` operates safely by target process name).*

---

## 2. Guided Production Hands-On Exercises

### Exercise 1: Job Control, Daemonization, and Subshell Process Isolation

#### Scenario
As a Systems Engineer, you need to execute background processes, control job suspend/resume states, inspect subshell execution contexts, and verify process group isolation when detaching workloads.

#### Execution Steps

1. Start a long-running, harmless background process using job control syntax:
```bash
sleep 3600 &
```
*Expected Output:*
```text
[1] 84920
```

2. Launch a process in the foreground, suspend it via terminal signals, and view job queue status:
```bash
tail -f /var/log/messages
```
*(Press `CTRL+Z` while running)*

*Expected Output:*
```text
^Z
[2]+  Stopped                 tail -f /var/log/messages
```

3. Display active jobs managed by the current shell session:
```bash
jobs -l
```
*Expected Output:*
```text
[1]- 84920 Running                 sleep 3600 &
[2]+ 84921 Stopped                 tail -f /var/log/messages
```

4. Resume job `[2]` in the background, then inspect process attributes using `ps`:
```bash
bg %2
ps -o pid,pgid,sid,tpgid,stat,command -p 84921
```
*Expected Output:*
```text
[2]+ tail -f /var/log/messages &
  PID  PGID   SID TPGID STAT COMMAND
84921 84921 84800 84800 I    tail -f /var/log/messages
```

5. Spawn an isolated, disowned background process inside a subshell to prevent `SIGHUP` propagation when the controlling shell exits:
```bash
(nohup sleep 7200 > /tmp/nohup_sleep.log 2>&1 &)
ps -auxww | grep "sleep 7200"
```
*Expected Output:*
```text
root     85104  0.0  0.1  12840  2420  -  I    21:15    0:00.00 sleep 7200
root     85106  0.0  0.1  12980  2510  0  S+   21:15    0:00.00 grep sleep 7200
```
*(Note: The process `85104` displays `-` in the TTY column, proving it detached from the controlling terminal).*

#### Verification Questions — Exercise 1
1. **Q1.1:** What does a value of `-` in the `TTY` column of `ps -aux` indicate regarding process architecture?
2. **Q1.2:** If the controlling shell receives a `SIGHUP`, why does process `85104` spawned via `(nohup ... &)` remain alive while job `[1]` (`sleep 3600 &`) is terminated?

---

### Exercise 2: Deep-Dive Process Inspection with `ps`, `top`, and `procstat`

#### Scenario
A critical production daemon is exhibiting high CPU usage and locked threads. You must diagnose thread kernel wait channels (`wchan`), memory layout, open file handles, and jail association.

#### Execution Steps

1. Create a lightweight test process performing periodic disk and loop operations:
```bash
sh -c 'while true; do date >> /tmp/test_loop.log; sleep 2; done' &
```
*Expected Output:*
```text
[1] 85430
```

2. Execute advanced FreeBSD `ps` formatting to display Jail ID (`jid`), Priority (`pri`), Nice Level (`ni`), Process State (`stat`), Wait Channel (`wchan`), and Command:
```bash
ps -o pid,jid,user,pri,ni,stat,wchan,command -p 85430
```
*Expected Output:*
```text
  PID JID USER   PRI NI STAT WCHAN  COMMAND
85430   0 root    24  0 S    nwait  sh -c while true; do date >> /tmp/test_loop.log; sleep 2; done
```

3. Query the process thread kernel stack using `procstat`:
```bash
procstat -k 85430
```
*Expected Output:*
```text
  PID    TID COMM             TDNAME           KSTACK                       
85430 100412 sh               -                mi_switch sleepq_catch_signals sleepq_wait_sig kern_clock_nanosleep sys_nanosleep amd64_syscall
```

4. Inspect all open file descriptors held by the target process:
```bash
procstat -f 85430
```
*Expected Output:*
```text
  PID COMM               FD ATTR ATFLAGS PD FDNAME
85430 sh text r--- v---  - /bin/sh
85430 sh cdwd r--- v---  - /root
85430 sh root r--- v---  - /
85430 sh    0 r--v r---  - /dev/null
85430 sh    1 r--v w---  - /dev/null
85430 sh    2 r--v w---  - /dev/null
85430 sh    3 r--v -w-a  - /tmp/test_loop.log
```

5. Monitor interactive system load and sort processes by resident memory footprint in batch mode using FreeBSD `top`:
```bash
top -b -o res -s 1 -n 5
```
*Expected Output:*
```text
last pid: 85450;  load averages:  0.08,  0.03,  0.01    up 0+04:12:30  21:20:00
42 processes:  1 running, 41 sleeping
CPU:  0.0% user,  0.0% nice,  0.2% system,  0.0% interrupt, 99.8% idle
Mem: Real 45M/380M act/tot, Shared 12M, Free 3400M

  PID USERNAME    THR PRI NICE   SIZE    RES STATE    TIME    CPU COMMAND
  848 postgres      1  20    0   140M    32M sleep   0:02   0.00% postgres
  712 root          1  20    0    45M    12M select  0:01   0.00% sshd
  891 syslogd       1  20    0  12.5M  3450K select  0:00   0.00% syslogd
85430 root          1  20    0  12.8M  2680K nwait   0:00   0.00% sh
```

#### Verification Questions — Exercise 2
1. **Q2.1:** In the output of `procstat -k`, what operational detail does the kernel backtrace provide to an SRE?
2. **Q2.2:** What does the state letter `S` in the `STAT` column of `ps` represent, and how does it differ from state `D`?

---

### Exercise 3: Precision Process Termination, Signal Trapping, and Process Groups

#### Scenario
A misbehaving worker process cluster must be gracefully shut down, trapped, or forcibly killed using signal management tools (`kill`, `pkill`, `killall`).

#### Execution Steps

1. Create a POSIX shell script that intercepts (`trap`) termination signals to perform cleanup before exit:
```bash
cat << 'EOF' > /tmp/traptest.sh
#!/bin/sh
trap 'echo "[$(date)] Caught SIGTERM! Cleaning up..."; rm -f /tmp/lockfile.lock; exit 0' TERM
trap 'echo "[$(date)] Caught SIGHUP! Reloading config..."' HUP

touch /tmp/lockfile.lock
echo "Process PID $$ started. Lockfile created."

while true; do
    sleep 1
done
EOF
chmod +x /tmp/traptest.sh
/tmp/traptest.sh > /tmp/trap.log 2>&1 &
```
*Expected Output:*
```text
[1] 85810
```

2. Inspect the signal disposition table for the running process using `procstat`:
```bash
procstat -i 85810
```
*Expected Output:*
```text
  PID COMM             SIG SIGNAME          DELIVERY
85810 traptest.sh        1 HUP              catch   
85810 traptest.sh       15 TERM             catch   
```

3. Send a non-destructive `SIGHUP` signal to reload configuration via process name targeting:
```bash
pkill -HUP -f traptest.sh
cat /tmp/trap.log
```
*Expected Output:*
```text
Process PID 85810 started. Lockfile created.
[Thu Aug  6 21:25:01 EDT 2026] Caught SIGHUP! Reloading config...
```

4. Issue a graceful `SIGTERM` using `kill`:
```bash
kill -TERM 85810
cat /tmp/trap.log
ls -l /tmp/lockfile.lock
```
*Expected Output:*
```text
Process PID 85810 started. Lockfile created.
[Thu Aug  6 21:25:01 EDT 2026] Caught SIGHUP! Reloading config...
[Thu Aug  6 21:25:10 EDT 2026] Caught SIGTERM! Cleaning up...
ls: /tmp/lockfile.lock: No such file or directory
```

5. Spawn three identical background worker processes and issue a verbose `killall` command:
```bash
sleep 4000 & sleep 4000 & sleep 4000 &
killall -v -TERM sleep
```
*Expected Output:*
```text
kill -TERM 86012
kill -TERM 86013
kill -TERM 86014
```

#### Verification Questions — Exercise 3
1. **Q3.1:** If a process is trapped in state `D` (Uninterruptible Disk I/O Wait), what happens if you issue `kill -9 <PID>`?
2. **Q3.2:** What is the technical risk when executing `killall sleep` on Solaris vs FreeBSD?

---

### Exercise 4: Real-time Scheduling, Priorities, and RACCT/RCTL Resource Limits

#### Scenario
You must adjust process execution priorities (`nice`, `renice`), assign real-time thread scheduling (`rtprio`), and enforce modern FreeBSD resource control rules (`rctl`) to prevent resource exhaustion attacks.

#### Execution Steps

1. Launch a high-CPU calculation workload with a lower priority (higher nice value):
```bash
nice -n 15 sha256 /dev/zero &
```
*Expected Output:*
```text
[1] 86320
```

2. Verify the nice level and priority score via `ps`:
```bash
ps -o pid,user,pri,ni,stat,command -p 86320
```
*Expected Output:*
```text
  PID USER   PRI NI STAT COMMAND
86320 root    35 15 R+   sha256 /dev/zero
```

3. Alter the priority of a running process dynamically using `renice`:
```bash
renice -n 5 -p 86320
ps -o pid,pri,ni,command -p 86320
```
*Expected Output:*
```text
86320 (process ID) old priority 15, new priority 5
  PID PRI NI COMMAND
86320  25  5 sha256 /dev/zero
```

4. Assign absolute Real-Time priority using FreeBSD `rtprio(1)` (enables fixed real-time scheduling above normal time-sharing threads):
```bash
rtprio 10 -p 86320
rtprio 86320
```
*Expected Output:*
```text
pid 86320 real time priority 10
```

5. Terminate the CPU-bound test process:
```bash
kill -9 86320
```

6. Inspect active FreeBSD Resource Limit rules using `rctl(8)`:
```bash
rctl
```
*Expected Output:*
```text
# (If no rules are currently set, returns empty output)
```

7. Apply a temporary RACCT/RCTL rule to cap maximum memory usage for user `nobody` to 100 Megabytes, triggering a SIGKILL when breached:
```bash
rctl -a user:nobody:vmemoryuse:deny=100M
rctl user:nobody
```
*Expected Output:*
```text
user:nobody:vmemoryuse:deny=104857600
```

8. Flush the rule:
```bash
rctl -r user:nobody:vmemoryuse:deny=100M
```

#### Verification Questions — Exercise 4
1. **Q4.1:** What is the valid range of `nice` values in FreeBSD, and how does `nice` influence thread scheduling compared to `rtprio`?
2. **Q4.2:** What system feature must be enabled in the FreeBSD kernel to use `rctl(8)`?

---

## 3. Comprehensive Solutions & Technical Rationale

<details>
<summary>Click to expand official solutions and deep-dive technical explanations</summary>

### Exercise 1 Solutions

*   **Q1.1 Answer:** A `-` in the `TTY` column indicates that the process has **no controlling terminal**.
    *   *Technical Rationale:* During daemonization, a process invokes `setsid(2)`. This creates a new session, sets the process as the session leader, detaches it from the parent process group, and explicitly releases the controlling terminal (`/dev/tty*`). This ensures the process is immune to terminal closure events or console hangup signals (`SIGHUP`).
*   **Q1.2 Answer:** The subshell construct `(nohup ... &)` detaches signal handlers and reassigns stdin/stdout. `nohup(1)` explicitly sets the action for `SIGHUP` to `SIG_IGN` (Ignore). When the parent shell terminates and sends `SIGHUP` to all jobs in its session group, `sleep 7200` ignores the signal and continues running under PID 1 adoption.

---

### Exercise 2 Solutions

*   **Q2.1 Answer:** `procstat -k` displays the **kernel thread execution stack (backtrace)** for every thread in the target process.
    *   *Technical Rationale:* In the output (`mi_switch sleepq_catch_signals sleepq_wait_sig kern_clock_nanosleep`), the backtrace reveals that the thread is currently executing inside the kernel sleep queue (`sleepq`), waiting for a timer clock interrupt (`nanosleep`). This tells an SRE exactly why a process is blocked (e.g., waiting for mutex locks, disk I/O, network socket select, or sleep timers) without requiring a debugger like `gdb`.
*   **Q2.2 Answer:** 
    *   State **`S`** represents **Interruptible Sleep**: The process is sleeping, waiting for an event (such as I/O completion, timer, or terminal input), but will immediately awaken to handle incoming system signals.
    *   State **`D`** represents **Uninterruptible Disk/Kernel Sleep**: The process is waiting for low-level hardware I/O or critical kernel page locks. While in state `D`, the process will **not** wake up to process signals, including `SIGKILL`.

---

### Exercise 3 Solutions

*   **Q3.1 Answer:** The process will **not** be terminated immediately.
    *   *Technical Rationale:* `kill -9` posts a non-catchable `SIGKILL` to the process's pending signal mask in kernel space. However, a thread in state `D` (Uninterruptible Sleep) is executing critical kernel-level routines where waking up prematurely could corrupt kernel memory or filesystem data structures. The kernel defers signal processing until the driver thread finishes the lock operation and transitions out of state `D`.
*   **Q3.2 Answer:** 
    *   On **FreeBSD**, `killall` safely terminates processes matching the specified **name string** (e.g., `killall sleep` terminates processes running the `sleep` binary image).
    *   On **Solaris / System V UNIX**, `killall` terminates **ALL active processes on the system** (used during system shutdown). Running `killall` on Solaris without arguments or process qualifiers will immediately bring down the operating system.

---

### Exercise 4 Solutions

*   **Q4.1 Answer:** 
    *   The `nice` range in FreeBSD spans from **`-20`** (highest execution priority) to **`+20`** (lowest execution priority), with **`0`** as default. Non-root users can only increase nice values (lower priority).
    *   While `nice` alters dynamic priorities within the standard SCHED_ULE / SCHED_4BSD time-sharing scheduler, **`rtprio`** assigns fixed **Real-Time Priority**. A thread assigned real-time priority via `rtprio` pre-empts standard time-sharing threads regardless of their nice values.
*   **Q4.2 Answer:** The FreeBSD kernel must have **Resource Accounting (`RACCT`)** and **Resource Limits (`RCTL`)** compiled in or loaded as a kernel module (`kern.racct.enable=1` set in `/boot/loader.conf`).

</details>

---

## 4. Key Exam Command Reference Summary

| Tool / Command | FreeBSD Target Syntax Example | Production SRE Function |
| :--- | :--- | :--- |
| `ps` | `ps -auxww -O jid,pri,ni,wchan` | Introspect processes, terminal sessions, wait channels, and jail IDs. |
| `top` | `top -b -o res -s 1` | Real-time system monitoring, CPU/Memory resource sorting in non-interactive batch mode. |
| `procstat` | `procstat -k <PID>` / `procstat -f <PID>` | Detailed BSD kernel inspection (kernel thread stack backtrace, open file descriptors). |
| `pkill` | `pkill -HUP -f "nginx"` | Signal delivery targeting process command line match patterns. |
| `killall` | `killall -v -TERM process_name` | Terminate all processes matching exact binary executable name. |
| `nice` / `renice` | `nice -n 10 <cmd>` / `renice +5 <PID>` | Modify standard process scheduling priority within dynamic time-sharing queues. |
| `rtprio` | `rtprio 15 -p <PID>` | Query or set fixed Real-Time thread scheduling priorities on FreeBSD. |
| `rctl` | `rctl -a user:www:vmemoryuse:deny=500M` | Set fine-grained kernel resource limits using FreeBSD RACCT/RCTL rules. |