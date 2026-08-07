# LPI BSD Specialist (Exam 702-100) Study Guide
## Topic 715.3: Create, Monitor and Kill Processes

---

### 1. Production Motivation & Architectural Problem

In enterprise POSIX environments—specifically FreeBSD, OpenBSD, and NetBSD—process management form the core of platform reliability engineering. When operating high-throughput network services, databases, or microservices, an SRE or Platform Architect must understand the BSD kernel process management subsystems. Failing to monitor and control process states, memory allocation, execution priorities, and termination mechanics leads to system degradation, cascade failures, and total node unresponsiveness.

```
                  +-----------------------------------+
                  |             fork()                |
                  +-----------------------------------+
                                    |
                                    v
+------------------+      +-------------------+      +-------------------+
|   Zombie (Z)     |      |    Runnable (R)   | <--> |   Sleeping (S/I)  |
| (Awaiting wait() |      | (On CPU Run Queue)|      | (Interruptible)   |
+------------------+      +-------------------+      +-------------------+
          ^                         |                          |
          | exit()                  v                          v
          +-----------------+-----------------+      +-------------------+
                            |  Stopped (T)    |      | Uninterruptible   |
                            | (SIGSTOP/SIGTSTP|      |    Sleep (D)      |
                            +-----------------+      | (Disk/IO Wait)    |
                                                     +-------------------+
```

#### Key Architectural Challenges in Production BSD Infrastructure

1. **Uninterruptible Disk I/O Sleep (`D` State) & Load Average Inflation**:
   Process load average on BSD system monitors the average number of processes in the run queue (`R`) plus processes waiting in uninterruptible disk/network I/O sleep (`D`). An application blocked on locked NFS shares, unresponsive storage hardware, or zfs vdev locks enters state `D`. Because process execution in `D` state cannot handle kernel signals (including `SIGKILL` / `kill -9`), traditional process termination strategies fail. This results in process hoarding and eventual OS thread pool exhaustion.

2. **Zombie Process Accumulation & Orphaned Process Reaping**:
   When a child process finishes execution via `exit()`, it transitions to state `Z` (Zombie). Its process control block (PCB) and process table entry remain allocated until the parent process consumes its termination status via `wait()` or `waitpid()`. If a parent process suffers a deadlock or ignores child signal handlers (`SIGCHLD`), zombies accumulate. If the parent dies, process PID 1 (`init` or system service launcher) inherits the orphaned child and reaps it. Unreaped zombies consume process slots in the kernel process table (`kern.maxproc`).

3. **PID and Kernel Process Table Limit Exhaustion**:
   The BSD kernel maintains an internal process table capped by the `kern.maxproc` sysctl node (and per-user limit `kern.maxprocperuid`). If an unconstrained application creates threads or sub-processes without limits, it exhausts the kernel process table. Once reached, system utility calls like `fork()` fail globally with `EAGAIN` ("Resource temporarily unavailable"), preventing engineers from establishing SSH sessions to diagnose the host.

4. **Resource Contention and CPU Starvation**:
   Unmanaged background processes running at default scheduling priority (nice value `0`) can starve critical system daemons (`sshd`, `ntpd`, `syslogd`). BSD schedulers (SCHED_ULE on FreeBSD, SCHED_4BSD) require tuning via POSIX priorities (`nice`/`renice`) and BSD-specific real-time priorities (`rtprio`/`idprio`) or Resource Limits (`rctl`/`login.conf`) to guarantee latency SLIs for critical workloads.

---

### 2. Technical Comparisons & Trade-off Tables

#### Table 2.1: Process Inspection & Monitoring Tools

| Tool | Scope & Access Engine | System Overhead | Primary Production Use Case | Trade-offs & Limitations |
| :--- | :--- | :--- | :--- | :--- |
| **`ps`** | Kernel `kvm` / `sysctl` process table snapshot | Low (Single execution) | Scripted audit, CI/CD pipelines, process tree inspection (`ps -axjf`). | Static snapshot; no real-time metrics tracking; format options vary across FreeBSD/OpenBSD/NetBSD. |
| **`top`** | Dynamic userland terminal display via `sysctl` / `kvm` | Moderate (Periodic kernel polling) | Interactive debugging of CPU/Memory spikes and process rankings. | Consumes terminal TTY; continuous overhead when running at high refresh intervals (<1s). |
| **`systat`** | BSD kernel subsystem visualizer (`sysctl` interface) | Moderate | Comprehensive system performance (swap, netstat, vmstat, iostat). | Native to BSD (differs from Linux); steep keyboard shortcut learning curve. |
| **`procstat`** | Deep BSD kernel process structure inspector | Low | Tracing open file descriptors, signal masks, VM maps, and kernel thread state. | FreeBSD specific; complex output parsing; requires elevated root/privilege. |
| **`fstat` / `sockstat`** | Open file descriptors & network socket mapper | Low to Moderate | Identifying processes binding specific ports (`sockstat`) or open files (`fstat`). | Large output on systems with 100k+ open sockets; requires filtering. |

---

#### Table 2.2: Signal Delivery Mechanisms

| Tool / Command | Targeted Matching Criteria | Safety Level | Target Scenario | Architectural Risk |
| :--- | :--- | :--- | :--- | :--- |
| **`kill`** | Exact Process ID (PID) or Process Group ID (PGID) | **High** | Targeted process shutdown (`kill -15 PID`). | Human error typing PIDs can terminate unintended critical system daemons. |
| **`pkill`** | Regex match on command name, UID, GID, TTY, or jail | **Medium** | Bulk process termination matching specific process names or user contexts. | Overly permissive regex matches can accidentally terminate unintended processes. |
| **`killall`** | Exact process name matching | **Low to Medium** | Terminating all instances of a daemon (e.g., `killall nginx`). | **Syntax Warning**: On Solaris/SysV `killall` kills *all* processes. On BSD/Linux it kills by name. |
| **`procstat -k`** | Direct kernel stack/signal inspection & signal | **High** | Advanced kernel-level process state diagnostics and signal verification. | Specific to FreeBSD; requires thorough knowledge of kernel signals. |

---

#### Table 2.3: Scheduling Priority & Execution Control Engines

| Execution Level | Utility / Interface | Priority Range | Target Workload | Behavioral Properties |
| :--- | :--- | :--- | :--- | :--- |
| **Normal / Dynamic** | `nice` / `renice` | `-20` (Highest) to `20` (Lowest) | Standard background jobs, batch processing, build tasks. | Subject to kernel scheduler decay; non-root users can only lower priority (increase nice). |
| **Real-time (RTPRIO)** | `rtprio` (FreeBSD) | `0` (Highest) to `31` (Lowest) | Fixed latency audio, control hardware, high-frequency trade matching. | Preempts all standard timeshare processes; abuse will lock up kernel run queues. |
| **Idle (IDPRIO)** | `idprio` (FreeBSD) | `0` (Highest) to `31` (Lowest) | Scrubbing jobs, log compressors, disk indexers. | Process executes *only* when the system CPU run queues are completely empty. |
| **Resource Rules (RCTL)** | `rctl` (FreeBSD) | Declarative metric caps (`maxproc`, `pctcpu`, `vmemoryuse`) | Multi-tenant Jails, Containerized services, User limits. | Enforces hard dynamic throttling or automatic signal emission on threshold breach. |

---

### 3. Complete Manifests & Infrastructure Configurations

#### Manifest 3.1: `/etc/login.conf` — Enterprise Resource Control & Limits Manifest

This file sets resource limits for process execution environments per login class on BSD systems. Compile changes using `cap_mkdb /etc/login.conf`.

```ini
# /etc/login.conf - Production Server Capability Database
# Syntactically valid configuration for FreeBSD/OpenBSD process limit management

default:\
	:passwd_format=sha512:\
	:copyright=/etc/COPYRIGHT:\
	:welcome=/etc/motd:\
	:setenv=MAIL=/var/mail/$USER,PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin:\
	:path=/sbin /bin /usr/sbin /usr/bin /usr/local/sbin /usr/local/bin:\
	:nologin=/usr/sbin/nologin:\
	:cputime=unlimited:\
	:datasize=unlimited:\
	:stacksize=64M:\
	:memorylocked=64M:\
	:memoryuse=unlimited:\
	:filesize=unlimited:\
	:coredumpsize=0:\
	:openfiles=10240:\
	:maxproc=512:\
	:sbsize=unlimited:\
	:vmemoryuse=unlimited:\
	:swapuse=unlimited:\
	:pseudoterminals=unlimited:\
	:priority=0:\
	:umask=022:

# Restricted Class for Production Web Services (e.g. www / nginx / application execution context)
www_daemon:\
	:ignorenologin:\
	:datasize-cur=4G:\
	:datasize-max=8G:\
	:openfiles-cur=65536:\
	:openfiles-max=131072:\
	:maxproc-cur=2048:\
	:maxproc-max=4096:\
	:memoryuse-cur=8G:\
	:memoryuse-max=16G:\
	:coredumpsize=0:\
	:priority=2:\
	:tc=default:

# Production Database Class (High I/O, High Open Files, Real-time execution priority)
database_daemon:\
	:ignorenologin:\
	:openfiles-cur=262144:\
	:openfiles-max=524288:\
	:maxproc-cur=8192:\
	:maxproc-max=16384:\
	:memorylocked=unlimited:\
	:coredumpsize=unlimited:\
	:priority=-2:\
	:tc=default:
```

---

#### Manifest 3.2: `/etc/sysctl.conf` — Kernel Process Subsystem Tuning

Production sysctl tuning file to prevent kernel process table starvation, PID exhaustion, and tune scheduling parameters.

```ini
# /etc/sysctl.conf - FreeBSD/BSD Kernel Process Subsystem Production Tuning

# Increase maximum total process limit across the entire system
kern.maxproc=32768

# Increase maximum process limit allowed per user ID (prevents PID exhaustion DOS)
kern.maxprocperuid=16384

# Maximum open file descriptors system-wide
kern.maxfiles=204800

# Maximum open files per process ID
kern.maxfilesperproc=102400

# Disable core dumps for setuid processes (Security hardening)
kern.sugid_coredump=0

# FreeBSD SCHED_ULE Quantum tuning (Microseconds allocated to running thread before preempting)
# Tuning quantum length for low-latency network applications (Default: 100000)
kern.sched.quantum=50000

# Enable BSD Resource Limits engine (RCTL)
kern.racct.enable=1

# Virtual Memory Swap and Paging threshold controls
vm.swap_enabled=1
```

---

#### Manifest 3.3: `/etc/rc.d/sre_app` — Complete Production BSD Service Script

A fully compliant FreeBSD `rc.subr(8)` process supervision and daemon creation script, demonstrating proper use of `daemon(8)`, PID file tracking, signal handling, and execution context specification.

```sh
#!/bin/sh
#
# PROVIDE: sre_app
# REQUIRE: LOGIN DAEMON NETWORKING
# KEYWORD: shutdown
#
# Add the following lines to /etc/rc.conf to enable sre_app:
# sre_app_enable="YES"
# sre_app_flags="--config=/etc/sre_app.conf"
#

. /etc/rc.subr

name="sre_app"
rcvar="sre_app_enable"

load_rc_config ${name}

: ${sre_app_enable:="NO"}
: ${sre_app_user:="www"}
: ${sre_app_group:="www"}
: ${sre_app_login_class:="www_daemon"}
: ${sre_app_pidfile:="/var/run/${name}.pid"}
: ${sre_app_binary:="/usr/local/bin/sre_app_bin"}

pidfile="${sre_app_pidfile}"
command="/usr/sbin/daemon"
command_args="-f -p ${pidfile} -t ${name} -u ${sre_app_user} ${sre_app_binary} ${sre_app_flags}"

stop_cmd="sre_app_stop"
status_cmd="sre_app_status"
reload_cmd="sre_app_reload"

extra_commands="reload"

sre_app_stop()
{
    if [ -f "${pidfile}" ]; then
        local _pid
        _pid=$(cat "${pidfile}")
        echo "Stopping ${name} (PID: ${_pid})..."
        kill -SIGTERM "${_pid}"
        
        # Wait up to 10 seconds for graceful termination
        local _i=0
        while [ ${_i} -lt 10 ]; do
            if ! kill -0 "${_pid}" 2>/dev/null; then
                echo "${name} stopped successfully."
                rm -f "${pidfile}"
                return 0
            fi
            sleep 1
            _i=$(( _i + 1 ))
        done
        
        echo "Graceful shutdown failed. Sending SIGKILL to PID ${_pid}..."
        kill -SIGKILL "${_pid}" 2>/dev/null
        rm -f "${pidfile}"
    else
        echo "${name} is not running (PID file missing)."
    fi
}

sre_app_status()
{
    if [ -f "${pidfile}" ]; then
        local _pid
        _pid=$(cat "${pidfile}")
        if kill -0 "${_pid}" 2>/dev/null; then
            echo "${name} is running as PID ${_pid}."
            /usr/bin/procstat -c "${_pid}"
        else
            echo "${name} is dead but PID file exists."
            return 1
        fi
    else
        echo "${name} is not running."
        return 3
    fi
}

sre_app_reload()
{
    if [ -f "${pidfile}" ]; then
        local _pid
        _pid=$(cat "${pidfile}")
        echo "Reloading ${name} configuration (SIGHUP to PID ${_pid})..."
        kill -SIGHUP "${_pid}"
    else
        echo "${name} is not running."
        return 1
    fi
}

run_rc_command "$1"
```

---

### 4. Real CLI Commands & Terminal Outputs

#### Command 4.1: System Load & Workload Inspection (`uptime`, `w`)

Inspect system uptime, active sessions, and 1, 5, and 15-minute system load averages.

```syslog
$ uptime
 9:15PM  up 42 days, 11:04,  3 users,  load averages: 1.45, 0.98, 0.72

$ w
 9:15PM  up 42 days, 11:04,  3 users,  load averages: 1.45, 0.98, 0.72
USER       TTY      FROM                      LOGIN@  IDLE WHAT
root       pts/0    192.168.1.50             8:45PM     0 w
opsadmin   pts/1    192.168.1.51             9:00PM    12 top -u -s 2
deploy     pts/2    192.168.1.60             9:10PM     - python3 batch_processor.py
```

*Architectural Analysis*: Load average represents the average number of threads in the run queue (`R`) plus threads in uninterruptible disk wait (`D`). A load average of 1.45 on a single-core host implies a 45% CPU/IO wait backlog.

---

#### Command 4.2: Virtual Memory & Paging Activity (`vmstat`)

Monitor virtual memory statistics, page fault rates, disk transfers, and CPU state transitions at 1-second intervals.

```syslog
$ vmstat 1 5
 procs      memory      page                    disks     faults         cpu
 r b w     avm    fre   flt  re  pi  po  fr  sr da0 da1   in   sy   cs us sy id
 2 0 0   12.4G   4.1G   120   0   0   0 150   0   0   0  450 1200 3400 12  4 84
 1 0 0   12.4G   4.1G    45   0   0   0   0   0  12   0  410  890 2900  8  2 90
 4 1 0   13.1G   3.4G  4500  12 120   0 200   0  89   0 1250 8400 9200 45 25 30
 3 0 0   13.2G   3.3G  1200   0  45   0   0   0 145   0  980 4300 6100 35 15 50
 1 0 0   12.5G   4.0G   100   0   0   0   0   0  10   0  420  910 3000  9  3 88
```

*Key Metrics for SRE Inspection*:
- `r`: Processes in CPU run queue.
- `b`: Processes blocked in uninterruptible I/O wait (`D` state).
- `pi`/`po`: Pages paged in / paged out from swap space. High `po` indicates memory pressure.
- `cs`: Context switches per second. Excessive `cs` (>50k/s) signals lock contention or CPU thrashing.

---

#### Command 4.3: Swap Space Utilization (`pstat` / `swapctl`)

Detailed inspection of physical swap devices on BSD.

```syslog
$ pstat -s
Device          1K-blocks     Used    Avail Capacity
/dev/da0p3        8388608   524288  7864320     6%

$ swapctl -l
Device      512-blocks     Used    Avail Capacity Priority
/dev/da0p3    16777216  1048576 15728640     6%      0
```

---

#### Command 4.4: BSD Process Tree & State Audit (`ps`)

Inspect process execution tree, resource footprints, user accounts, and BSD state flags.

```syslog
$ ps -ax -o pid,ppid,user,pri,nice,stat,vsz,rss,comm
  PID  PPID USER     PRI NICE STAT      VSZ    RSS COMM
    0     0 root     187    0 DLs       0k    16k kernel
    1     0 root      19    0 SLs    1048k   812k /sbin/init
  450     1 root      20    0 Ss     2450k  1420k /usr/sbin/syslogd
  890     1 root      20    0 Ss     4120k  2890k /usr/sbin/sshd
 1245   890 root      20    0 S      6780k  4100k sshd: opsadmin [priv]
 1248  1245 opsadmin  20    0 S      6780k  4150k sshd: opsadmin@pts/1
 1249  1248 opsadmin  20    0 Is+    2340k  1890k -tcsh (tcsh)
 4510     1 www       22    2 S      152M   45M /usr/local/bin/python3
 4511  4510 www       35   10 SN      98M   22M /usr/local/bin/python3
 9812  1249 opsadmin  59    0 R+     3100k  1540k ps
```

*BSD Process State Code Glossary*:
- **Primary States**: `R` (Runnable/Running), `S` (Sleeping <20s), `I` (Idle >20s), `D` (Uninterruptible Disk Wait), `Z` (Zombie), `T` (Stopped).
- **Modifiers**: `+` (Foreground process group), `s` (Session leader), `N` (Nice level > 0, reduced priority), `<` (High priority, nice < 0), `W` (Swapped out), `L` (Waiting on kernel lock).

---

#### Command 4.5: Real-Time Process Monitoring (`top`)

Run interactive `top` in non-interactive batch mode sorted by CPU consumption.

```syslog
$ top -b -s 1 -o cpu -n 5
last pid:  9823;  load averages:  1.12,  0.85,  0.65  up 42+11:06:12  21:20:00
48 processes:  1 running, 47 sleeping
CPU:  8.5% user,  0.0% nice,  4.2% system,  1.2% interrupt, 86.1% idle
Mem: 2145M Active, 1420M Inact, 890M Wired, 4120M Free
ARC: 4500M Total, 1200M MFU, 2800M MRU, 16M Anon, 85M Header, 400M Metadata
Swap: 8192M Total, 512M Used, 7680M Free, 6% Inuse

  PID USERNAME    THR PRI NICE   SIZE    RES STATE    TIME    WCPU COMMAND
 4510 www           8  22    2   152M    45M uwait   12:45  18.40% python3
 1249 opsadmin      1  20    0  2340k  1890k pause    0:01   0.10% tcsh
  450 root          1  20    0  2450k  1420k select   0:45   0.00% syslogd
```

---

#### Command 4.6: Process Filtering & Signal Delivery (`pgrep`, `pkill`, `kill`)

Lookup PID by exact pattern, filter by user, and execute signal delivery.

```syslog
# Find PIDs of all python3 processes owned by user 'www'
$ pgrep -l -u www python3
4510 python3
4511 python3

# Send SIGHUP (Signal 1 - Configuration Reload) to all nginx processes
$ pkill -HUP -x nginx

# Graceful termination request (SIGTERM - 15) to specific process group
$ kill -15 -4510

# Forceful uncatchable termination (SIGKILL - 9)
$ kill -9 4510
```

---

#### Command 4.7: Job Control and Background Process Execution

Demonstrating POSIX job control semantics within the shell.

```syslog
# Execute long running process in background using '&'
$ tar -czf /backup/app_data.tar.gz /var/www/data &
[1] 10452

# View active shell job table
$ jobs -l
[1] + 10452 Running              tar -czf /backup/app_data.tar.gz /var/www/data &

# Suspend a running foreground process using SIGTSTP (Ctrl + Z)
$ openssl speed rsa
^Z
[2]+  Stopped                 openssl speed rsa

# Resume job [2] in background
$ bg %2
[2]+ openssl speed rsa &

# Bring job [1] back to foreground
$ fg %1
tar -czf /backup/app_data.tar.gz /var/www/data

# Decouple process from SIGHUP on terminal closure using nohup
$ nohup python3 /usr/local/bin/sync_service.py > /var/log/sync.log 2>&1 &
[1] 10580
```

---

#### Command 4.8: Adjusting Process Priorities (`nice`, `renice`, `rtprio`)

Manipulating CPU scheduling priorities for running processes.

```syslog
# Launch a CPU-intensive process with low priority (High nice value = 15)
$ nice -n 15 tar -czf /tmp/logs.tar.gz /var/log/

# Dynamically alter nice priority of running PID 4511 to 5
$ renice 5 -p 4511
4511 (process ID) old priority 10, new priority 5

# FreeBSD: Set real-time priority (RTPRIO) to 10 for latency-sensitive application (Requires root)
# rtprio <priority> <pid>
$ sudo rtprio 10 -p 4510

# Query current real-time / idle priority of process
$ rtprio 4510
pid 4510 real-time priority 10

# Set process to Idle Priority (Executes ONLY when system has 0 active threads in run queue)
$ sudo idprio 20 -p 4511
```

---

#### Command 4.9: Socket & File Descriptor Tracing (`sockstat`, `fstat`, `procstat`)

Identifying process resource bindings.

```syslog
# Inspect IPv4/IPv6 listening sockets and associated PIDs/Commands
$ sockstat -4 -6 -l
USER     COMMAND    PID   FD PROTO LOCAL ADDRESS         FOREIGN ADDRESS
www      nginx      3410  6  tcp4  *:80                  *:*
www      nginx      3410  7  tcp4  *:443                 *:*
root     sshd       890   4  tcp4  *:22                  *:*
root     sshd       890   5  tcp6  *:22                  *:*

# List open files for a specific process ID using fstat
$ fstat -p 3410
USER     CMD          PID FD MOUNT      INUM MODE         SZ|DV R/W
www      nginx       3410 text /usr        4512 -rwxr-xr-x  1.2M  r
www      nginx       3410 wd   /          2 -rwxr-xr-x   512  r
www      nginx       3410    0 /          4 crw-rw-rw-  null rw
www      nginx       3410    6 internet 589122393 UDP *:53

# Query detailed BSD process binary memory mapping and signal masks
$ procstat -b 3410
  PID COMM             OSREL PATH
 3410 nginx         1302000 /usr/local/sbin/nginx

$ procstat -s 3410
  PID COMM             SIGS CAUGHT           IGNORE           HOLD
 3410 nginx            HUP  1000000000000000 0000000008000000 0000000000000000
```

---

### 5. Verification & Failure Diagnostics Guide

```
                         [Production Alert Triggers]
                                      |
                                      v
                        Is System Responding to SSH?
                       /                            \
                     (Yes)                          (No)
                      /                                \
          Check Load Avg (uptime, w)             PID Exhaustion / Console Lockup
             /                   \               Execute hard power cycle or NMI
       (High Load)           (Normal Load)       Kernel Panic Debug via Serial
          /                         \
  Check vmstat (r vs b)        Check Memory Leaks (top/ps)
     /              \
 (r > cores)      (b > 0)
   /                  \
CPU Starvation     I/O Wait (D State)
Use renice/rctl    Inspect Storage/ZFS Locks
```

#### Incident Playbook 1: Unkillable Process in Uninterruptible Disk Sleep (`D` State)

* **Symptom**: Process ignores `kill -9 <PID>`. Load average increases steadily. System calls to the underlying storage block indefinitely.
* **Root Cause Analysis**:
  The process is blocked in a kernel-level I/O wait (e.g., waiting for NFS response, faulted disk block, or ZFS deadlocked channel). Processes in `D` state ignore POSIX signals because signal delivery occurs upon returning from kernel space to user space.
* **Diagnostic Protocol**:
  1. Identify kernel thread wait channel (WCHAN):
     ```syslog
     $ ps -ao pid,stat,wchan,comm | grep ' D '
     ```
  2. Inspect kernel stack backtrace for the blocked process using `procstat -k`:
     ```syslog
     $ sudo procstat -k 4510
       PID    TID COMM             TDNAME           KSTACK
      4510 100892 python3          -                mi_switch sleepq_wait nfs_request nfs_bioread vnode_pager_getpages
     ```
  3. *Resolution*: If the wait channel (`WCHAN`) is locked on an NFS mount (`nfs_bioread`), unmount the stale NFS share forcibly using `umount -f /mnt/stale_share`. If hardware storage is hung, clear the storage path controller lock. Never attempt to force-reboot without identifying the WCHAN, as file system corruption may result.

---

#### Incident Playbook 2: Zombie Process Accumulation (`Z` State)

* **Symptom**: `ps aux` reports multiple processes in `Z` state. Total system PID capacity (`kern.maxproc`) fills up over time.
* **Root Cause Analysis**:
  Application code executes `fork()` followed by child exit without calling `waitpid()` in the parent thread loop.
* **Diagnostic Protocol**:
  1. Locate all zombies and identify their parent PIDs (`PPID`):
     ```syslog
     $ ps -ax -o pid,ppid,stat,user,comm | grep ' Z '
     ```
     *Sample Output*:
     ```syslog
     9120  4510 Z    www      <defunct>
     9121  4510 Z    www      <defunct>
     ```
  2. Inspect parent PID state (PPID 4510):
     ```syslog
     $ procstat -s 4510
     ```
  3. *Resolution*:
     - Signal the parent process to handle `SIGCHLD`: `kill -SIGCHLD 4510`.
     - If the parent process is deadlocked or non-compliant, terminate the parent process: `kill -15 4510`.
     - Once parent PID 4510 terminates, orphaned zombies are re-parented to PID 1 (`init`), which automatically reaps them from the kernel process table.

---

#### Incident Playbook 3: PID Exhaustion Panic (`EAGAIN` on Fork)

* **Symptom**: Terminal returns `fork: Resource temporarily unavailable` when running commands or logging in via SSH.
* **Root Cause Analysis**:
  Number of active processes has reached `kern.maxprocperuid` for a user or global system limit `kern.maxproc`.
* **Diagnostic Protocol**:
  1. Check system process count per UID using `ps`:
     ```syslog
     $ ps -A -o user | sort | uniq -c | sort -nr
     ```
  2. Query current sysctl kernel process limits:
     ```syslog
     $ sysctl kern.maxproc kern.maxprocperuid kern.openfiles
     ```
  3. *Immediate Mitigation*:
     - If logged into a pre-existing root shell, execute `pkill` by user or binary name:
       ```syslog
       $ pkill -u runaway_user -9
       ```
     - Dynamically raise kernel limits via sysctl (temporary fix until reboot):
       ```syslog
       $ sudo sysctl kern.maxproc=65536
       $ sudo sysctl kern.maxprocperuid=32768
       ```

---

#### Incident Playbook 4: CPU Starvation & Priority Inversion

* **Symptom**: Web service response times exceed SLA thresholds; high user CPU utilization (`us`) on single core while multi-threaded daemons lag.
* **Root Cause Analysis**:
  Low-priority background tasks consume execution quotas or lock shared mutexes required by high-priority interactive web services.
* **Diagnostic Protocol**:
  1. Identify highest CPU consuming processes:
     ```syslog
     $ top -b -o cpu -n 10
     ```
  2. Inspect scheduling class and nice values:
     ```syslog
     $ ps -o pid,user,nice,pri,stat,comm -p <PID>
     ```
  3. *Resolution*:
     - Demote rogue background process priority immediately:
       ```syslog
       $ renice +15 -p <PID>
       ```
     - Enforce FreeBSD Resource Rules (`rctl`) to cap CPU percentage for the target execution context:
       ```syslog
       $ sudo rctl -a user:runaway_user:pcpu:deny=50
       ```

---

### 6. References

* **Linux Professional Institute (LPI) BSD Specialist Overview**:
  https://www.lpi.org/our-certifications/bsd-specialist-overview/
* **LPI Wiki — BSD Specialist Objectives V1.0 (Topic 715.3)**:
  https://wiki.lpi.org/wiki/BSD_Specialist_Objectives_V1.0
* **FreeBSD Manual Pages — `ps(1)`**:
  https://man.freebsd.org/cgi/man.cgi?query=ps
* **FreeBSD Manual Pages — `top(1)`**:
  https://man.freebsd.org/cgi/man.cgi?query=top
* **FreeBSD Manual Pages — `procstat(1)`**:
  https://man.freebsd.org/cgi/man.cgi?query=procstat
* **FreeBSD Manual Pages — `daemon(8)`**:
  https://man.freebsd.org/cgi/man.cgi?query=daemon
* **FreeBSD Manual Pages — `login.conf(5)`**:
  https://man.freebsd.org/cgi/man.cgi?query=login.conf
* **FreeBSD Architecture Handbook — Process Management**:
  https://docs.freebsd.org/en/books/arch-handbook/
* **OpenBSD Manual Pages — `kill(1)` & `pkill(1)`**:
  https://man.openbsd.org/kill.1
* **NetBSD Manual Pages — `sysctl(8)` & Process Tuning**:
  https://man.netbsd.org/sysctl.8