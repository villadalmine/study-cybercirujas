# LPI-702 (Exam 702-100) Topic 713.7: Manage User Sessions

**Exam Weight:** 1.67  
**Target Certification:** LPI BSD Specialist (Exam 702-100, Version 1.0)  
**Primary Domain:** Topic 713 — Basic BSD System Administration  

---

## 1. Architectural Deep Dive & Internal Mechanics

### 1.1 BSD User Session Database Architecture: `utmp`, `utmpx`, and POSIX Compliance

In BSD Unix systems (FreeBSD, OpenBSD, NetBSD), user session state is tracked via binary accounting databases. Understanding the distinction between legacy BSD `utmp` format structures and modern POSIX-compliant `utmpx` implementations is vital for enterprise system administration, security auditing, and forensic analysis.

```
+-----------------------------------------------------------------------------------+
|                                 USER LOGIN SESSION                                |
|        (sshd daemon / getty / login process allocates TTY / PTS pair)            |
+-----------------------------------------------------------------------------------+
                                          |
                                          v
                         +---------------------------------+
                         |   POSIX utmpx Library (getutx*) |
                         +---------------------------------+
                                          |
             +----------------------------+----------------------------+
             |                            |                            |
             v                            v                            v
  +--------------------+        +-------------------+        +--------------------+
  | /var/run/utx.active|        |  /var/log/utx.log |        |/var/log/utx.lastlogin|
  |  (Active Sessions) |        | (Login/Logout Log)|        | (Last Login Info)  |
  +--------------------+        +-------------------+        +--------------------+
             |                            |                            |
             v                            v                            v
  Parsed by: `w`, `who`          Parsed by: `last`, `ac`      Parsed by: `pam_lastlog`
```

#### Database Component Comparison:

| Functional Area | FreeBSD Modern standard (`utmpx`) | OpenBSD Legacy/Current standard | Description & Purpose |
| :--- | :--- | :--- | :--- |
| **Active Session Store** | `/var/run/utx.active` | `/var/run/utmp` | Holds current state of interactive login sessions, background tasks, and pseudo-terminals. |
| **Historical Login Log** | `/var/log/utx.log` | `/var/log/wtmp` | Append-only audit log tracking logins, logouts, reboot events, and system shutdowns. |
| **Last Login Log** | `/var/log/utx.lastlogin` | `/var/log/lastlog` | Fixed-size array indexed by User ID (UID) storing the timestamp and origin of the most recent session. |

#### Structural C Data Representation (`struct utmpx`)
On FreeBSD systems (`<utmpx.h>`), session records conform to the following POSIX-standard structure:

```c
struct utmpx {
    short           ut_type;        /* Type of entry (e.g., USER_PROCESS, BOOT_TIME, DEAD_PROCESS) */
    struct timeval  ut_tv;          /* Time entry was made */
    char            ut_id[8];       /* Record identifier (e.g., tty name suffix or inittab ID) */
    pid_t           ut_pid;         /* Process ID of the session process leader */
    char            ut_user[32];    /* User login name */
    char            ut_line[16];    /* Device name (tty, pts/0, etc.) */
    char            ut_host[128];   /* Remote host name / IPv4 / IPv6 string */
    char            ut_spare[64];   /* Reserved space for future extension */
};
```

#### Entry Types (`ut_type` Constants):
*   `EMPTY` (`0`): Inactive or cleared database slot.
*   `BOOT_TIME` (`2`): Timestamp of system startup recorded by `init` or kernel boot scripts.
*   `OLD_TIME` / `NEW_TIME` (`3`/`4`): Recorded when the system clock is manually or NTP-adjusted.
*   `USER_PROCESS` (`7`): Active interactive user session established by `login`, `sshd`, or `tmux`.
*   `DEAD_PROCESS` (`8`): Terminated session record remaining until reclaimed.

---

### 1.2 Process Hierarchy, Session IDs, and Terminal Allocation

When a user connects to a BSD host via SSH or console, the operating system establishes a controlled process environment bound to a controlling terminal (`tty` or `pts`).

```
 +------------------+
 |    sshd (root)   |  <-- Master Daemon listening on Port 22
 +------------------+
          |
          | forks & drops privileges
          v
 +------------------+
 |  sshd: alice [net|  <-- Session Process (Privilege Separated)
 +------------------+
          |
          | calls setsid() & opens pseudo-terminal slave (/dev/pts/0)
          v
 +------------------+
 |  -tcsh (alice)   |  <-- Login Shell (Session Leader, PID == SID == PGID)
 +------------------+
          |
          | forks foreground job
          v
 +------------------+
 |    top (alice)   |  <-- Foreground Process Group Leader
 +------------------+
```

1.  **Session Leader & `setsid()` Call:**  
    The daemon process invokes `setsid(2)`, creating a new Session ID (`SID`) equal to the process ID (`PID`) of the shell, creating a new Process Group ID (`PGID`), and detaching from any controlling terminal.
2.  **Pseudo-Terminal Multiplexing (`/dev/ptmx` and `/dev/pts/*`):**  
    The allocated slave terminal (`/dev/pts/X`) becomes the controlling terminal for the login shell. Standard descriptors (0: `stdin`, 1: `stdout`, 2: `stderr`) reference this character device interface managed by FreeBSD `devfs`.
3.  **Idle Time Computation Mechanism:**  
    Utilities like `w(1)` compute user idle time by executing `stat(2)` on the character device file node associated with the user's line (e.g., `/dev/pts/0`). The elapsed time since the file's `st_atime` (last access time) or `st_mtime` (last modification time) determines the reported idle duration.

---

### 1.3 Production Trade-Offs & Security Considerations

```
+-----------------------------------------------------------------------------------+
|                        SECURITY & AUDIT TRAIL ARCHITECTURE                        |
+-----------------------------------------------------------------------------------+
|                                                                                   |
|  1. LOG TAMPERING & INTEGRITY RISKS:                                              |
|     - Binary utx logs lack native cryptographic signature checks.                 |
|     - Attackers with root/write permissions on /var/log/utx.log can truncate or   |
|       modify login timestamps to hide footprint.                                  |
|     - Mitigation: Forward session events via syslogd to remote append-only SIEM.   |
|                                                                                   |
|  2. PRIVACY VS ACCESSIBILITY:                                                     |
|     - /var/run/utx.active is world-readable by default (0644).                    |
|     - Any user can inspect active user accounts, source IP addresses, and commands. |
|     - Hardening: Set security.bsd.see_other_uids=0 to obscure unprivileged users.   |
|                                                                                   |
|  3. PERFORMANCE & LOG ROTATION:                                                   |
|     - Unbounded growth of /var/log/utx.log degrades `last` performance.           |
|     - Maintenance: Configure rotation policies in /etc/newsyslog.conf.            |
+-----------------------------------------------------------------------------------+
```

---

## 2. Configuration Artifacts & Production Manifests

### 2.1 `/etc/login.conf` — Login Capabilities & Resource Limits Manifest

The `/etc/login.conf` file manages user login classes, setting limits on execution environments, concurrent sessions, memory usage, and open files. After editing, compile the binary database with `cap_mkdb /etc/login.conf`.

```ini
# /etc/login.conf - Production Class Specification for SRE Engineers
# Syntax: fieldname=value: or fieldname#number: or fieldname:

default:\
	:passwd_format=sha512:\
	:copyright=/etc/COPYRIGHT:\
	:welcome=/etc/motd:\
	:setenv=MAIL=/var/mail/$,BLOCKSIZE=K:\
	:path=/sbin /bin /usr/sbin /usr/bin /usr/local/sbin /usr/local/bin:\
	:nologin=/usr/sbin/nologin:\
	:cputime=unlimited:\
	:datasize=unlimited:\
	:stacksize=unlimited:\
	:memorylocked=64M:\
	:memoryuse=unlimited:\
	:filesize=unlimited:\
	:coredumpsize=0:\
	:openfiles=1024:\
	:maxproc=512:\
	:sbsize=unlimited:\
	:vmemorysize=unlimited:\
	:priority=0:\
	:ignorequota=off:\
	:umask=022:

# Restricted SRE Operator Class with session limits
sre_operator:\
	:tc=default:\
	:maxproc=256:\
	:openfiles=4096:\
	:maxlogins=3:\
	:requirehome=on:\
	:priority=0:\
	:umask=027:\
	:lang=en_US.UTF-8:
```

---

### 2.2 `/etc/pam.d/sshd` — Pluggable Authentication Module Session Flow

This configuration governs how user sessions are recorded, authenticated, and initialized upon SSH login in FreeBSD systems.

```ini
# /etc/pam.d/sshd - Production Session & Authentication Policy
# PAM module enforcement ordering for SSH user sessions

# Authentication Phase
auth        sufficient    pam_opie.so                no_warn auth_as_client
auth        requisite     pam_opieaccess.so          no_warn allow_local
auth        required      pam_unix.so                no_warn try_first_pass

# Account Management Phase
account     required      pam_nologin.so
account     required      pam_login_access.so
account     required      pam_unix.so

# Session Management Phase
session     required      pam_permit.so
session     required      pam_lastlog.so             no_fail

# Password Management Phase
password    required      pam_unix.so                no_warn shadow try_first_pass
```

---

### 2.3 `/etc/newsyslog.conf` — Log Rotation Rules for User Session Tracking

Session log files like `/var/log/utx.log` grow over time and must be systematically rotated to prevent storage exhaustion while preserving audit readiness.

```text
# /etc/newsyslog.conf snippet for Session Accounting Logs
# logfilename          [owner:group]    mode count size when  flags [/pid_file] [sig_num]
/var/log/utx.log                        644  12    1024 *     B
/var/log/utx.lastlogin                  644  5     *    @T00  B
/var/account/acct                       600  10    5000 *     BZ
```

---

## 3. Guided Lab Exercises & Diagnostics

### Lab 1: Inspecting Active Sessions & Terminal Allocation (`who`, `w`, `sockstat`, `fstat`)

In this lab, you will audit active user sessions, inspect session process details, map socket descriptors to terminal sessions, and track process execution.

#### Executable Commands:

```bash
# Step 1: Query the active system users using `who` with detailed headings
who -a -H

# Step 2: Analyze active user processes, system load, and idle times using `w`
w -v

# Step 3: Identify active SSH user sessions and their associated network sockets
sockstat -4 -6 -c -p 22

# Step 4: Map open pseudo-terminals (/dev/pts/*) to running process PIDs using `fstat`
fstat /dev/pts/0
```

#### Realistic Command Outputs:

```console
$ who -a -H
NAME     LINE         TIME           IDLE          PID COMMENT
boottime .            Aug  6 12:00      .            1
alice    pts/0        Aug  6 14:22  00:02        45120 (192.168.1.105)
bob      pts/1        Aug  6 15:10      .        48201 (192.168.1.110)

$ w
 3:30PM  up  3:30, 2 users, load averages: 0.12, 0.08, 0.04
USER     TTY      FROM              LOGIN@  IDLE WHAT
alice    pts/0    192.168.1.105    2:22PM     2 top -a
bob      pts/1    192.168.1.110    3:10PM     - vim /etc/nginx/nginx.conf

$ sockstat -4 -6 -c -p 22
USER     COMMAND    PID   FD PROTO LOCAL ADDRESS         FOREIGN ADDRESS
root     sshd       1204  4  tcp4  10.0.0.15:22          *:*
alice    sshd       45118 5  tcp4  10.0.0.15:22          192.168.1.105:54210
bob      sshd       48199 5  tcp4  10.0.0.15:22          192.168.1.110:59134

$ fstat /dev/pts/0
USER     CMD          PID FD MOUNT      INUM MODE         SZ|DV R/W
alice    tcsh       45120  0 /dev         97 crw--w----  pts/0 rw
alice    tcsh       45120  1 /dev         97 crw--w----  pts/0 rw
alice    tcsh       45120  2 /dev         97 crw--w----  pts/0 rw
alice    top        45230  0 /dev         97 crw--w----  pts/0 rw
```

#### Comprehension Questions — Lab 1

1. In the output of `w`, user `alice` shows an IDLE time of `2` minutes while running `top -a`. How does `w` determine that `alice` has been idle for 2 minutes despite `top` actively updating the terminal display?
2. If `sockstat` shows an SSH connection for user `bob` (PID `48199`), but `who` displays no corresponding session on any `pts` device, what system database state disparity has occurred, and what process failure causes this?

---

### Lab 2: Auditing Login History & User Session Accounting (`last`, `lastcomm`, `ac`)

In this lab, you will extract historical login records, track past command execution via process accounting, and aggregate total user connect hours.

#### Executable Commands:

```bash
# Step 1: Query the historical login database (/var/log/utx.log) for user `alice`
last -n 5 alice

# Step 2: Determine reboot history and system shutdowns logged in session database
last -n 5 reboot shutdown

# Step 3: Enable process accounting on the accounting storage device
accton /var/account/acct

# Step 4: Display command execution history for user `bob` using `lastcomm`
lastcomm --user bob

# Step 5: Calculate cumulative connect time per user in hours using `ac`
ac -p
```

#### Realistic Command Outputs:

```console
$ last -n 5 alice
alice    pts/0    192.168.1.105    Thu Aug  6 14:22   still logged in
alice    pts/2    192.168.1.105    Wed Aug  5 09:12 - 17:45  (08:32)
alice    pts/0    192.168.1.105    Tue Aug  4 10:00 - 12:30  (02:30)

utx.log begins Tue Aug  4 10:00:00 UTC 2026

$ last -n 5 reboot shutdown
reboot   ~                         Thu Aug  6 12:00
shutdown ~                         Thu Aug  6 11:58
reboot   ~                         Mon Aug  3 08:00

utx.log begins Mon Aug  3 08:00:00 UTC 2026

$ lastcomm --user bob
command           user     tty            cpu time start time
vim               bob      pts/1      0.04 secs Thu Aug  6 15:10
grep              bob      pts/1      0.01 secs Thu Aug  6 15:08
cat               bob      pts/1      0.00 secs Thu Aug  6 15:05

$ ac -p
	alice                               11.03
	bob                                  0.33
	total       11.36
```

#### Comprehension Questions — Lab 2

1. If a system administrator executes `last -f /var/log/utx.log.0`, what specific operational scenario requires passing the `-f` flag, and how does `last` parse binary records differently than plain text files like `/var/log/messages`?
2. How does `ac -p` compute total connect hours? If user `alice` opens three simultaneous SSH connections for 1 hour each, how many total hours will `ac -p` add to `alice`'s accounting tally?

---

### Lab 3: Low-Level Binary Diagnostics & Session Inspection (`utx` structure analysis)

In this lab, you will perform binary inspection of the `/var/run/utx.active` file to verify structural integrity and identify stale login entries.

#### Executable Commands:

```bash
# Step 1: Verify system log file path and permissions for active utx database
ls -la /var/run/utx.active /var/log/utx.log

# Step 2: Use `hexdump` to inspect raw binary bytes of the first record in `/var/run/utx.active`
hexdump -C -n 300 /var/run/utx.active

# Step 3: Search for ASCII strings inside the binary session record file to extract remote hosts
strings /var/run/utx.active | grep -E 'pts/|[0-9]{1,3}\.[0-9]{1,3}'
```

#### Realistic Command Outputs:

```console
$ ls -la /var/run/utx.active /var/log/utx.log
-rw-r--r--  1 root  wheel   600 Aug  6 15:10 /var/run/utx.active
-rw-r--r--  1 root  wheel  4200 Aug  6 15:10 /var/log/utx.log

$ hexdump -C -n 300 /var/run/utx.active
00000000  07 00 00 00 86 32 55 68  00 00 00 00 70 74 73 2f  |.....2Uh....pts/|
00000010  30 00 00 00 00 00 00 00  00 00 00 00 61 6c 69 63  |0...........alic|
00000020  65 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |e...............|
00000030  00 00 00 00 00 00 00 00  00 00 00 00 31 39 32 2e  |............192.|
00000040  31 36 38 2e 31 2e 31 30  35 00 00 00 00 00 00 00  |168.1.105.......|

$ strings /var/run/utx.active | grep -E 'pts/|[0-9]{1,3}\.[0-9]{1,3}'
pts/0
alice
192.168.1.105
pts/1
bob
192.168.1.110
```

#### Comprehension Questions — Lab 3

1. In the hex dump of `/var/run/utx.active`, the first four bytes are `07 00 00 00`. What field of `struct utmpx` does this value represent, and what does the numerical value `7` (`USER_PROCESS`) signify to login tracking tools?
2. If an SSH connection drops ungracefully due to a network outage (bypassing TCP FIN/RST packet exchange), why might `hexdump` or `who` continue to report the user in `/var/run/utx.active`? Which SSH daemon configuration parameter mitigates this session state leak?

---

### Lab 4: Inter-Session Messaging & Forced Session Termination (`mesg`, `write`, `wall`, `pkill`)

In this lab, you will manage session message permissions, execute targeted user messaging, broadcast system alerts, and terminate unresponsive user sessions.

#### Executable Commands:

```bash
# Step 1: Check terminal write permission state using `mesg`
mesg

# Step 2: Disable incoming terminal messages on current session
mesg n

# Step 3: Broadcast an administrative message to all active user sessions
wall "SYSTEM MAINTENANCE ALERT: Server rebooting in 15 minutes. Save your work."

# Step 4: Locate process tree and session PID for user `bob` using `pgrep`
pgrep -l -u bob -s $(pgrep -f "sshd: bob")

# Step 5: Forcefully terminate all session processes belonging to user `bob`
pkill -9 -u bob
```

#### Realistic Command Outputs:

```console
$ mesg
is y

$ mesg n

$ mesg
is n

$ wall "SYSTEM MAINTENANCE ALERT: Server rebooting in 15 minutes. Save your work."
Broadcast Message from root@bsd-node-01 on pts/0 (Thu Aug  6 15:35:00 2026)...
SYSTEM MAINTENANCE ALERT: Server rebooting in 15 minutes. Save your work.

$ pgrep -l -u bob
48199 sshd
48201 tcsh
48255 vim

$ pkill -9 -u bob
```

#### Comprehension Questions — Lab 4

1. How does the command `mesg n` technically restrict other non-root users from writing to a terminal via `write(1)` or `wall(1)`? What underlying filesystem permission modification occurs on `/dev/pts/X`?
2. What is the operational distinction between executing `pkill -9 -u bob` vs targeted process group termination via `kill -TERM -- -PGID`? Why is killing only the login shell session leader (`-PID`) generally safer in production environments?

---

## 4. Official References & Documentation Links

*   **LPI BSD Specialist Certification Overview:**  
    [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
*   **FreeBSD `utmpx(3)` Library Functions Manual:**  
    [https://man.freebsd.org/cgi/man.cgi?query=utmpx&sektion=3](https://man.freebsd.org/cgi/man.cgi?query=utmpx&sektion=3)
*   **FreeBSD `w(1)` Command Manual:**  
    [https://man.freebsd.org/cgi/man.cgi?query=w&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=w&sektion=1)
*   **FreeBSD `last(1)` System Audit Manual:**  
    [https://man.freebsd.org/cgi/man.cgi?query=last&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=last&sektion=1)
*   **FreeBSD `ac(8)` Connect Time Accounting Manual:**  
    [https://man.freebsd.org/cgi/man.cgi?query=ac&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=ac&sektion=8)
*   **OpenBSD `who(1)` User Accounting Manual:**  
    [https://man.openbsd.org/who.1](https://man.openbsd.org/who.1)

---

## 5. Verification Answers & Technical Explanations

<details>
<summary><strong>Click here to expand solutions for Labs 1 through 4</strong></summary>

### Lab 1 Solutions

1.  **Idle Time Mechanics in `w(1)`:**  
    The `w` command determines user idle time by inspecting the file access timestamp (`st_atime`) of the character device corresponding to the user's controlling terminal (e.g., `/dev/pts/0`). While `top` continuously writes output to stdout, updating the device's modification time (`st_mtime`), it does *not* read input from stdin (`st_atime`). Since `alice` has not typed keyboard input for 2 minutes, `st_atime` remains unchanged, and `w` correctly reports an IDLE time of 2 minutes.
2.  **Session Database Disparities:**  
    This state occurs when an SSH daemon process (`sshd`) authenticates a connection and forks a worker process, but fails to register an entry in `/var/run/utx.active` via `pututxline(3)`. This happens if PAM session configuration missing `pam_lastlog.so` or `pam_permit.so` aborts prematurely, if `sshd` is configured with `UseLogin yes` incorrectly, or if a custom non-interactive SSH subsystem (e.g., SFTP-only or port forwarding session without TTY allocation) is requested.

---

### Lab 2 Solutions

1.  **Reading Alternate Accounting Files with `last -f`:**  
    The `-f` flag directs `last` to parse a specific historical log file (such as rotated/archived files like `/var/log/utx.log.0` or `/var/log/wtmp.1.gz`) rather than the default `/var/log/utx.log`. `last` cannot read plain ASCII log files (like `/var/log/messages`); it expects a sequence of fixed-size C binary structures (`struct utmpx` or `struct utmp`). It reads the file record by record, decoding the binary timestamp, terminal line, process type, and username fields.
2.  **Connect Accounting Calculation in `ac -p`:**  
    `ac` scans entry login (`USER_PROCESS`) and logout (`DEAD_PROCESS`) record pairs in `/var/log/utx.log`. Connect time is calculated as `(logout_timestamp - login_timestamp)`. If user `alice` opens three simultaneous interactive SSH sessions that remain active for 1 wall-clock hour each, `ac -p` aggregates the duration of all three discrete line sessions, reporting a cumulative total of **3.00 connect hours**.

---

### Lab 3 Solutions

1.  **Hex Decoding of `ut_type`:**  
    The first 4 bytes (`07 00 00 00` in little-endian 32-bit integer format) represent the `ut_type` field of `struct utmpx`. The integer value `7` corresponds to the constant `USER_PROCESS`. This signifies to system tracking tools (`who`, `w`, `getutxent`) that the record represents an active, authenticated human or service session occupying a terminal, rather than a system boot event (`BOOT_TIME` = 2) or terminated process (`DEAD_PROCESS` = 8).
2.  **TCP Session Leakage & SSH Keep-Alive Mitigation:**  
    When a client network connection drops ungracefully without sending a TCP `FIN` or `RST` frame, the remote server kernel retains the socket in an established state. Consequently, the session process tree stays alive, and no cleanup routine (`endutxent()`) writes a `DEAD_PROCESS` record to `/var/run/utx.active`. To prevent session leaks, configure `/etc/ssh/sshd_config` with:
    ```ini
    ClientAliveInterval 300
    ClientAliveCountMax 3
    ```
    This instructs `sshd` to send encrypted null probe packets every 300 seconds. If the client fails to respond 3 consecutive times, `sshd` terminates the process tree and cleans up the active session record in `utx.active`.

---

### Lab 4 Solutions

1.  **Low-Level Mechanism of `mesg n`:**  
    Executing `mesg n` alters the file permission mode bits of the character device associated with the user's current controlling terminal (e.g., `/dev/pts/0`). Standard terminal allocations set mode `0620` (`crw--w----`), allowing processes owned by the `tty` group to write output to the device. `mesg n` strips group write permissions, changing the file mode to `0600` (`crw-------`). As a result, attempts by `write` or `wall` (running under non-root unprivileged credentials) to open `/dev/pts/0` for writing fail with `EACCES` (Permission Denied).
2.  **Process Termination Strategies:**  
    Executing `pkill -9 -u bob` sends an uncatchable `SIGKILL` signal to every process owned by user `bob`. This immediately terminates processes, but prevents login shells from executing clean-up handlers (such as saving shell history files `.bash_history` / `.history`, closing database locks, or executing terminal reset routines).  
    Targeting the session leader with `kill -TERM -- -PGID` or terminating the login shell PID allows the shell process to handle `SIGTERM`, broadcast `SIGHUP` to child process groups gracefully, execute logout scripts (`.logout`), update the `utmpx` database via POSIX APIs, and close pseudo-terminal devices cleanly.

</details>