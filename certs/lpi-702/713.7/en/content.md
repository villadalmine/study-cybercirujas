# LPI BSD Specialist (702-100) — Topic 713.7: Manage User Sessions

**Exam Target**: 702-100 (Version 1.0)  
**Topic Weight**: 1.67  
**Role Level**: Senior SRE / Principal Platform Architect  

---

## 1. Architectural Motivation & Production Context

In high-concurrency multi-tenant FreeBSD and BSD infrastructure, managing user sessions goes beyond simply seeing who is logged into a shell. It is a critical operational boundary for **resource isolation**, **security auditing**, **terminal control**, and **process lifecycle governance**.

```
                           +-----------------------------------------------+
                           |            BSD Kernel Space                   |
                           +-----------------------------------------------+
                                  |                     |            |
                      tty / pts device             setsid(2)      revoke(2)
                                  |                     |            |
                                  v                     v            v
+------------------+     +------------------+     +--------------------------+
|  SSH / Console   | --> | Login Shell (PGRP| --> | Child Processes / Daemons|
| Daemon (sshd/pty)|     |  Leader / Session|     | (tmux, background jobs)  |
+------------------+     |      Leader)     |     +--------------------------+
                         +------------------+
                                  |
                                  v
                      +------------------------+
                      | Accounting Engine      |
                      | (/var/run/utx.active,  |
                      |  /var/log/utx.log)     |
                      +------------------------+
```

### Key Architectural Challenges in Production

1. **Orphaned Sessions & Resource Leaks**: When an SSH connection drops ungracefully (e.g., network partition), the transport layer breaks. If `SIGHUP` is ignored or trapped by subshells/terminal multiplexers (`tmux`, `screen`, `nohup`), the process tree detached from the controlling terminal (`ctty`) remains alive indefinitely. This leaks file descriptors (FDs), memory, sockets, and login process slots (`maxproc`).
2. **Terminal Invalidation Security Gaps**: Terminating a login shell (`kill -9 <PID>`) leaves the underlying pseudo-terminal device (`/dev/pts/X`) open if child processes retain file descriptors pointing to `/dev/tty`. Subsequent processes allocated to that `pts` slot could suffer from file descriptor leaks or unauthorized input/output sniffing.
3. **Session Accounting Corruption**: In BSD systems, user session tracking relies on the `utmpx(3)` subsystem. If processes crash or are forcefully killed (`SIGKILL`) without triggering standard cleanup code paths (`exit(3)`), stale session entries linger in `/var/run/utx.active`. This corrupts audit queries (`w(1)`, `who(1)`), causing security monitoring tools to misreport system occupancy.
4. **Multi-Tenant Resource Starvation**: Unrestricted session allocations allow single users to consume available processes (`maxproc`), open files (`openfiles`), and swap space, degrading neighbor workloads on shared bastion hosts or CI/CD runners.

---

## 2. Technical Comparison & Trade-off Analysis

### 2.1 Session Termination Mechanisms

| Mechanism | Trigger / Command | Kernel/OS Action | Trade-offs & Production Risk | Primary Use Case |
| :--- | :--- | :--- | :--- | :--- |
| **Session Leader Termination** | `pkill -HUP -t pts/1` or `kill -1 <Session_PID>` | Sends `SIGHUP` to Session Leader. Standard shells propagate `SIGHUP` to Process Group (`PGRP`). | **Soft Termination**: Processes catching or ignoring `SIGHUP` (`nohup`, `tmux`) will survive. Cleanest application shutdown. | Orderly session logout and config reload requests. |
| **Process Group Tree Sweep** | `pkill -TERM -u <user>` / `pkill -9 -u <user>` | Delivers signal (`SIGTERM`/`SIGKILL`) directly to all PIDs owned by the user UID. | **Aggressive**: Kills user background jobs (e.g., active long-running compilations). `SIGKILL` prevents cleanup handlers and corrupts `utmpx`. | Removing unresponsive users or stopping malicious scripts. |
| **Terminal Device Revocation** | `revoke /dev/pts/1` or `fbtab(5)` invocation | Invokes `revoke(2)` syscall. Invalidates all open file descriptors accessing the specified tty file. | **Hard Disconnect**: Destroys I/O capability instantly. Future read/write calls return `-1 (EBADF)`. Child processes die on next I/O. | Sanitizing physical/virtual tty devices on user logout to prevent eavesdropping. |
| **PAM / Login Class Enforcement** | `/etc/login.conf` (`idletime`, `maxproc`) | Enforces resource bounds via `setrlimit(2)` during session initialization (`login_cap`). | **Preventative**: Requires binary database compilation (`cap_mkdb`). Cannot terminate already running rogue sessions reactively. | Establishing default resource ceilings per login class. |

### 2.2 BSD Session Accounting Architecture (`utmpx`)

| Data Store / Interface | File Path / API | Purpose & Mechanics | Resilience & Maintenance |
| :--- | :--- | :--- | :--- |
| **Active Sessions Database** | `/var/run/utx.active` | Stores binary records of currently connected users (read by `w(1)`, `who(1)`). | **Transient**: Cleared on boot. Susceptible to ghost entries if session processes die via `SIGKILL`. | Real-time session monitoring and current occupancy checks. |
| **Historical Login Audit Log** | `/var/log/utx.log` | Append-only historical ledger of logins, logouts, reboots, and shutdowns (read by `last(1)`). | **Persistent**: Requires log rotation (`newsyslog.conf`) to prevent disk filling. | Compliance, forensic auditing, and historical access patterns. |
| **Last Login Store** | `/var/log/utx.lastlogin` | Tracks the most recent login timestamp per user UID (read by `pam_lastlog(8)`). | **Fixed Size**: Keyed by UID. High durability. | User security notifications upon login ("Last login: ..."). |
| **Accounting Management Tool** | `/usr/bin/utx` | CLI utility to manually insert, remove (`utx rm`), or sanitize dead records in `utx.active`. | **Manual/Scripted**: Reclaims state consistency without requiring a system reboot. | SRE automated cleanup scripts and operational repair. |

---

## 3. Complete Production Configuration Files & Automation

### 3.1 Hardened `/etc/login.conf` (Login Class Capabilities)

```ini
# /etc/login.conf - Production Session Control Configuration
# Recompile after modification: cap_mkdb /etc/login.conf

default:\
	:passwd_format=sha512:\
	:copyright=/etc/COPYRIGHT:\
	:welcome=/etc/motd:\
	:setenv=MAIL=/var/mail/$,BLOCKSIZE=K:\
	:path=/sbin /bin /usr/sbin /usr/bin /usr/local/sbin /usr/local/bin ~/bin:\
	:nologin=/var/run/nologin:\
	:cputime=unlimited:\
	:datasize=unlimited:\
	:stacksize=unlimited:\
	:memorylocked=64M:\
	:memoryuse=unlimited:\
	:filesize=unlimited:\
	:coredumpsize=0:\
	:openfiles=1024:\
	:maxproc=128:\
	:sbsize=unlimited:\
	:vmemorysize=unlimited:\
	:priority=0:\
	:ignorequota=off:\
	:umask=022:\
	:idletime=60m:

# Restricted class for temporary SRE contractors and junior developers
untrusted:\
	:tc=default:\
	:openfiles=256:\
	:maxproc=64:\
	:memoryuse=2048M:\
	:idletime=15m:\
	:welcome=/etc/motd.untrusted:\
	:requirehome:

# High-capacity login class for automated platform CI/CD pipelines
automation:\
	:tc=default:\
	:openfiles=8192:\
	:maxproc=1024:\
	:memoryuse=16384M:\
	:idletime=unlimited:\
	:coredumpsize=unlimited:
```

*To apply `/etc/login.conf` changes to the database:*
```bash
$ sudo cap_mkdb /etc/login.conf
```

---

### 3.2 Secure `/etc/ssh/sshd_config` Session Rules

```ini
# /etc/ssh/sshd_config - Session Lifecycle Limits

# Global session constraints
MaxSessions 4
ClientAliveInterval 300
ClientAliveCountMax 2
TCPKeepAlive no

# Enforce strict session control for untrusted group
Match Group untrusted
    AllowTcpForwarding no
    X11Forwarding no
    MaxSessions 2
    ClientAliveInterval 120
    ClientAliveCountMax 1
```

---

### 3.3 Production SRE Session Reaper & Sanitizer Script

`/usr/local/sbin/sre_session_reaper.sh`

```bash
#!/bin/sh
# ==============================================================================
# SRE Automated Session Reaper & UTMPX Sanitizer for FreeBSD Systems
# ==============================================================================
set -eu

LOG_FILE="/var/log/session_reaper.log"
IDLE_THRESHOLD_SEC=7200 # 2 Hours in seconds

log_msg() {
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [SESSION-REAPER] $1" | tee -a "$LOG_FILE"
}

log_msg "Starting session health sweep..."

# 1. Broadcast maintenance notification to stale sessions
wall << 'EOF'
[SYSTEM NOTICE] Automated SRE policy enforcement: Idle sessions exceeding policy limits are subject to immediate termination.
EOF

# 2. Identify orphaned processes detached from terminals with high runtime
ps -ax -o user,pid,tty,state,command | awk '$3 == "??" && $4 ~ /I|S/ {print $1, $2, $5}' | while read -r USER PID CMD; do
    if [ "$USER" != "root" ] && [ "$USER" != "_daemon" ]; then
        log_msg "Terminating orphaned non-tty process: User=$USER PID=$PID Cmd=$CMD"
        kill -TERM "$PID" 2>/dev/null || kill -9 "$PID" 2>/dev/null || true
    fi
done

# 3. Clean up ghost entries in utx database where process no longer exists
utx list | while read -r LINE; do
    # Extract line pattern: ID | User | TTY | Host | Time
    ID=$(echo "$LINE" | awk '{print $1}')
    TYPE=$(echo "$LINE" | awk '{print $2}')
    
    if [ "$TYPE" = "USER_PROCESS" ]; then
        TTY=$(echo "$LINE" | awk '{print $4}')
        PID=$(echo "$LINE" | awk '{print $5}')
        
        if [ -n "$PID" ] && ! kill -0 "$PID" 2>/dev/null; then
            log_msg "Purging stale utx.active entry: ID=$ID TTY=$TTY DeadPID=$PID"
            utx rm "$ID" || true
        fi
    fi
done

log_msg "Session health sweep completed successfully."
exit 0
```

*Set permissions:*
```bash
$ sudo chmod 700 /usr/local/sbin/sre_session_reaper.sh
```

---

## 4. Real CLI Commands & Terminal Outputs

### 4.1 Inspecting Active User Sessions (`w` and `who`)

```bash
$ w
 8:42PM up 14 days,  3:21, 3 users, load averages: 0.12, 0.08, 0.05
USER     TTY      FROM              LOGIN@  IDLE WHAT
sre_admin pts/0    192.168.10.45    8:10PM     - w
dev_user pts/1    192.168.10.88    7:45PM 35:12 python3 long_running_script.py
bad_actor pts/2   10.0.0.15        6:15PM  2:14 -bash
```

```bash
$ who -a -H
NAME     LINE         TIME           IDLE          PID COMMENT             EXIT
         system boot  Aug  2 17:21
sre_admin pts/0       Aug  6 20:10     .         14205 (192.168.10.45)
dev_user pts/1       Aug  6 19:45   00:35        18902 (192.168.10.88)
bad_actor pts/2       Aug  6 18:15   02:14        22104 (10.0.0.15)
```

---

### 4.2 Detailed Process Tree & Session Ownership Inspection

```bash
$ ps -o user,pid,pgid,sid,tty,state,command -u dev_user
USER     PID  PGID   SID TTY      STAT COMMAND
dev_user 18902 18902 18902 pts/1    Is   -bash (bash)
dev_user 19105 19105 18902 pts/1    I+   python3 long_running_script.py
```

```bash
$ fstat -u dev_user
USER     CMD          PID FD MOUNT      INUM MODE         SZ|DV R/W
dev_user python3    19105 text /usr     104922 -rwxr-xr-x  2.4M  r
dev_user python3    19105    0 /dev       128 crw--w----  pts/1 rw
dev_user python3    19105    1 /dev       128 crw--w----  pts/1 rw
dev_user python3    19105    2 /dev       128 crw--w----  pts/1 rw
```

---

### 4.3 Querying Historical Sessions (`last`)

```bash
$ last -n 5 -h 192.168.10.88
dev_user pts/1        192.168.10.88    Thu Aug  6 19:45   still logged in
dev_user pts/0        192.168.10.88    Wed Aug  5 10:12 - 12:44  (02:31)
dev_user pts/2        192.168.10.88    Mon Aug  3 09:00 - 17:05  (08:05)

utx.log begins Mon Aug  3 00:00:00 UTC 2026
```

---

### 4.4 Managing `utmpx` Database State (`utx`)

```bash
$ utx list
BOOT_TIME  - -                     Thu Aug  2 17:21:00 2026
USER_PROC  sre_admin pts/0 14205   Thu Aug  6 20:10:15 2026
USER_PROC  dev_user  pts/1 18902   Thu Aug  6 19:45:02 2026
USER_PROC  bad_actor pts/2 22104   Thu Aug  6 18:15:33 2026
```

```bash
$ sudo utx rm pts/2
utx: record pts/2 removed from /var/run/utx.active
```

---

### 4.5 Terminating Sessions and Revoking Terminal Devices

```bash
$ sudo pkill -HUP -t pts/2
```

*If processes trap `SIGHUP` and refuse to terminate:*

```bash
$ sudo pkill -KILL -u bad_actor
```

*Invalidate device file descriptors to enforce clean disconnection:*

```bash
$ sudo revoke /dev/pts/2
```

---

## 5. Verification & Fault Diagnostics Guide

```
                        +------------------------------------+
                        | Incident: Stale / Rogue Session   |
                        +------------------------------------+
                                          |
                                          v
                    Run `w` / `who -a` / `ps -o tty,pid,user`
                                          |
                     +--------------------+--------------------+
                     |                                         |
            Process is alive                        Process is dead (Ghost)
                     |                                         |
                     v                                         v
        Check CTTY: `fstat -p <PID>`                  Run `utx list`
                     |                                         |
       +-------------+-------------+                           v
       |                           |                  Remove via `utx rm <id>`
TTY Attached              Orphaned (TTY ??)                    |
       |                           |                           v
       v                           v                     Verify `w` output
  `pkill -HUP -t`          `pkill -KILL -g <PGRP>`           is clean
       |                           |
       v                           v
Check if process dies      Check FD leak (`fstat`)
       |                           |
[If persistent]                   v
`revoke /dev/pts/X`        `revoke /dev/pts/X`
```

### 5.1 Step-by-Step Diagnostic Scenarios

#### Scenario A: Rogue Process Trapping Signals on Terminal Disconnect
* **Symptom**: User `bad_actor` logged out, but CPU utilization remains high and `fstat` shows processes attached to `/dev/pts/2`.
* **Diagnostic Procedure**:
  1. Inspect process state and signal disposition:
     ```bash
     $ ps -o pid,ppid,pgid,jobc,state,tty,command -u bad_actor
     ```
  2. Verify active file descriptors pointing to the terminal:
     ```bash
     $ fstat -p 22104
     ```
  3. Attempt graceful process group termination:
     ```bash
     $ sudo kill -TERM -22104
     ```
  4. If the process remains, invoke hardware-level file descriptor revocation:
     ```bash
     $ sudo revoke /dev/pts/2
     ```
  5. Issue ultimate forced process cleanup:
     ```bash
     $ sudo pkill -9 -u bad_actor
     ```

---

#### Scenario B: Corrupted `utmpx` Database (Ghost Sessions in `w(1)`)
* **Symptom**: `w(1)` shows user `dev_user` active on `pts/1`, but `ps -p <PID>` reveals the process no longer exists.
* **Root Cause**: The session leader process suffered an unhandled crash or received `SIGKILL`, bypassing normal accounting exit routines (`pututxline(3)`).
* **Diagnostic & Remediation Procedure**:
  1. Confirm the PID listed in `utmpx` is dead:
     ```bash
     $ utx list | grep pts/1
     USER_PROC dev_user pts/1 18902 Thu Aug 6 19:45:02 2026
     $ ps -p 18902
     PID TT STAT TIME COMMAND
     # (No output returned - PID is dead)
     ```
  2. Safely purge the ghost entry without restarting system daemons:
     ```bash
     $ sudo utx rm pts/1
     ```
  3. Validate that `w(1)` output now reflects real kernel state:
     ```bash
     $ w
     ```

---

#### Scenario C: Login Class Limit Reached (`maxproc` Exhaustion)
* **Symptom**: User receives `fork: Resource temporarily unavailable` when opening a new session.
* **Diagnostic Procedure**:
  1. Inspect the target user's active process count:
     ```bash
     $ ps -u dev_user | wc -l
     ```
  2. Check the user's login class limit in `/etc/login.conf`:
     ```bash
     $ login.conf -v
     $ grep -A 10 "untrusted:" /etc/login.conf
     ```
  3. Check current capability values applied to the user session via `limits(1)`:
     ```bash
     $ limits -U dev_user
     Resource limits for class untrusted:
       cputime          infinity
       datasize         infinity
       stacksize        infinity
       memorylocked     64 MB
       memoryuse        2048 MB
       filesize         infinity
       coredumpsize     0 B
       openfiles        256
       maxproc          64
     ```
  4. Adjust limits in `/etc/login.conf` if required, recompile with `cap_mkdb /etc/login.conf`, or kill runaway processes.

---

## 6. References

* **LPI BSD Specialist Certification Overview**:  
  https://www.lpi.org/our-certifications/bsd-specialist-overview/
* **FreeBSD Manual Pages — `w(1)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=w&sektion=1
* **FreeBSD Manual Pages — `login.conf(5)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=login.conf&sektion=5
* **FreeBSD Manual Pages — `utx(8)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=utx&sektion=8
* **FreeBSD Manual Pages — `revoke(2)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=revoke&sektion=2
* **FreeBSD Manual Pages — `ps(1)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=ps&sektion=1
* **FreeBSD Architecture Handbook — User Architecture & Login Capabilities**:  
  https://docs.freebsd.org/en/books/handbook/users/