# LPI-702 (Exam 702-100) Study Guide: Topic 713.4 – System Logging

---

## 1. Production Architectural Motivation & Problem Statement

In enterprise production environments, system logging forms the operational bedrock for observability, security auditing, and forensic analysis across BSD ecosystems (FreeBSD, OpenBSD, and NetBSD). System logs capture state transitions, kernel faults, security violations, and daemon activities.

```
+-----------------------------------------------------------------------------------+
|                                   KERNEL SPACE                                    |
|                                                                                   |
|  [ Kernel Subsystems / Drivers ] ---> Log Ring Buffer (sysctl kern.msgbuf)        |
|                                             |                                     |
|                                             v                                     |
|                                         /dev/klog                                 |
+---------------------------------------------|-------------------------------------+
                                              |
+---------------------------------------------v-------------------------------------+
|                                    USER SPACE                                     |
|                                                                                   |
|  [ System Daemons ] ---> /dev/log <--- syslogd (Daemon)                           |
|  [ User Processes ]  (UNIX Domain Socket)   |                                     |
|                                             +---> Local Disk (/var/log/*)         |
|                                             +---> Console (/dev/console)          |
|                                             +---> Named Pipe (|/usr/local/bin/...) |
|                                             +---> Remote Syslog Server (@remote)  |
|                                                                                   |
|  [ Cron / Interval Daemon ] ---> newsyslog (Log Rotation Engine)                  |
|                                        |                                          |
|                                        +---> Rotate, Compress (.gz/.bz2/.xz),      |
|                                              & Signal Daemon (SIGHUP / SIGUSR1)   |
+-----------------------------------------------------------------------------------+
```

### Architectural Challenge: Kernel vs. User-Space Logging
The operating system divides logging into two primary execution spaces:
1. **Kernel-Space Logging (`/dev/klog`)**: The kernel writes hardware initialization, driver diagnostics, and panic events into an in-memory ring buffer (accessible via `sysctl kern.msgbuf` or `dmesg`). Because kernel memory allocation cannot block during high-severity panics or interrupt contexts, this buffer is fixed-size. If the user-space logging daemon cannot consume entries fast enough from `/dev/klog`, old messages are overwritten.
2. **User-Space Logging (`/dev/log` & `syslogd`)**: User-space daemons (e.g., `sshd`, `unbound`, `pf`, `dhcpd`) emit logs via the standard UNIX domain datagram socket `/dev/log`. The `syslogd` daemon listens on `/dev/log` and `/dev/klog`, parses facility/severity metadata, applies selector rules from `/etc/syslog.conf`, and dispatches output to filesystem targets, virtual consoles, remote syslog endpoints, or worker pipelines.

### Engineering Trade-offs & Production Risks
- **Synchronous vs. Asynchronous I/O**: Direct file writes in `syslogd` can perform `fsync()` operations or block under severe disk I/O saturation. To prevent cascading system lockups, production SREs must decouple critical local logging from remote stream delivery.
- **Log Rotation Race Conditions**: Rotating log files while processes actively write to open file descriptors leads to orphaned data or unlinked writes. The `newsyslog` daemon solves this by executing atomic file shifts and signaling target processes (e.g., via `SIGHUP`) to re-open file descriptors.
- **Security & Integrity**: Unrestricted log files risk privilege escalation and log tampering. In BSD systems, strict file ownership (`root:wheel`), modes (`0600` / `0640`), and secure flags (`file flags` such as `nodump` or `append-only`) must be enforced during rotation.

---

## 2. Technical Comparison & Trade-off Tables

### 2.1 Daemon Architectures: Native BSD `syslogd` vs. Advanced Third-Party Collectors

| Feature / Metric | Native BSD `syslogd` | `rsyslog` | `syslog-ng` |
| :--- | :--- | :--- | :--- |
| **Footprint & Memory** | Extremely minimal (~2-5 MB RSS) | Medium (~15-40 MB RSS) | Medium-High (~30-80 MB RSS) |
| **Configuration Complexity** | Low (`/etc/syslog.conf` position-based syntax) | High (RainerScript + Legacy format) | Medium-High (Structured block syntax) |
| **Transport Protocols** | Local Socket, UDP (`514`), TCP (FreeBSD extensions) | UDP, TCP, RELP, TLS/SSL, Kafka, HTTP | UDP, TCP, TLS/SSL, Elasticsearch, Kafka |
| **Buffering Strategy** | In-memory socket queue only | Disk-assisted queue & In-memory | In-memory & Disk buffer options |
| **Parsing Capabilities** | RFC 3164 (BSD Syslog), BSD program tags | RFC 3164, RFC 5424, JSON parsing | RFC 3164, RFC 5424, Key-Value, JSON |
| **Production Suitability** | Base system logging, minimal hosts, hypervisors | Complex enterprise Linux/BSD aggregators | Complex multi-tenant log parsing nodes |

### 2.2 Log Rotation Engines: BSD `newsyslog` vs. Linux `logrotate`

| Dimensional Metric | BSD `newsyslog` | Linux `logrotate` |
| :--- | :--- | :--- |
| **Execution Trigger** | Periodic `cron` execution (typically hourly) or run as a daemon (`-D`) | Periodic `cron` execution (daily/weekly/monthly) or systemd timer |
| **Configuration Architecture** | Single file (`/etc/newsyslog.conf`) + include directory (`/etc/newsyslog.conf.d/`) | Central config (`/etc/logrotate.conf`) + includes (`/etc/logrotate.d/`) |
| **Size & Time Triggers** | Dual support: Size-based (KB), exact ISO 8601 time triggers, or interval hours | Size-based, daily/weekly/monthly schedules |
| **Compression Support** | Native `gzip` (`Z`), `bzip2` (`J`), `xz` (`X`), `zstd` (`Y`) via flags | External binary invocation (`gzip`, `bzip2`, `xz`) |
| **PID Management** | Direct signal routing per file entry (`/var/run/daemon.pid`) | `postrotate`/`prerotate` script blocks or `kill -HUP` |
| **Atomic Handling** | Native support for socket/pipe recreation and log creation flags | Native `create`, `copytruncate`, `delaycompress` |

### 2.3 Compression Algorithm Trade-offs for Rotated Logs

| Algorithm | Flag in `newsyslog.conf` | CPU Overhead (Compression) | Decompression Speed | Compression Ratio | Primary Production Use Case |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`gzip`** | `Z` | Low | Very High | Standard (~4:1) | Default standard legacy rotation |
| **`bzip2`** | `J` | High | Moderate | High (~6:1) | Cold archive storage with limited disk space |
| **`xz`** | `X` | Very High | High | Very High (~8:1) | Long-term compliance retention compliance |
| **`zstd`** | `Y` (FreeBSD 13+) | Low-Moderate | Extremely High | High (~6.5:1) | Modern high-throughput SRE log aggregators |

---

## 3. Production Configuration Manifests

### 3.1 Production BSD `/etc/syslog.conf` Manifest
This configuration configures logging facilities, isolates security events, streams operational logs to dedicated files, forwards errors to a remote SRE log aggregator via UDP/TCP, and writes urgent kernel alerts directly to active administrative terminals.

```syntax
# /etc/syslog.conf - Production FreeBSD/OpenBSD System Logging Configuration
# Selector Syntax: facility.level destination

# ------------------------------------------------------------------------------
# 1. EMERGENCY & CRITICAL KERNEL ALERTS
# ------------------------------------------------------------------------------
# Write all emergency messages (system unusable) to all logged-in operators
*.emerg                                         *

# Send critical kernel and hardware messages to system console and emergency log
kern.crit                                       /dev/console
kern.crit                                       /var/log/kernel_crit.log

# ------------------------------------------------------------------------------
# 2. SECURITY & AUTHENTICATION AUDITING
# ------------------------------------------------------------------------------
# Log all authentication events (auth, authpriv) with restricted permissions
auth,authpriv.info                              /var/log/auth.log
auth.notice                                     root

# ------------------------------------------------------------------------------
# 3. DAEMON & INFRASTRUCTURE SERVICES
# ------------------------------------------------------------------------------
# Capture general daemon activity (excluding debug logs for noise reduction)
daemon.info;daemon.!debug                        /var/log/daemon.log

# Mail subsystem logging
mail.info                                       /var/log/maillog

# Cron subsystem logging
cron.info                                       /var/log/cron

# ------------------------------------------------------------------------------
# 4. SYSTEM MESSAGES & CATCH-ALL
# ------------------------------------------------------------------------------
# General system messages catch-all rule
*.notice;auth.none;authpriv.none;mail.none;cron.none    /var/log/messages

# Debug logs isolated for non-production diagnostic tracing
*.debug;auth.none;authpriv.none                  /var/log/debug.log

# ------------------------------------------------------------------------------
# 5. PROGRAM-SPECIFIC FILTERING (BSD Extension Syntax)
# ------------------------------------------------------------------------------
# Isolate OpenSSH Server Logs
!sshd
*.*                                             /var/log/sshd.log
!*

# Isolate NGINX Web Server Logs (using Local Facility local0)
!nginx
local0.info                                     /var/log/nginx_access.log
local0.err                                      /var/log/nginx_error.log
!*

# ------------------------------------------------------------------------------
# 6. REMOTE CENTRALIZED LOG FORWARDING
# ------------------------------------------------------------------------------
# Forward all critical and error logs to central SRE aggregator via UDP
*.err;authpriv.info                             @syslog-relay.internal.net:514
```

### 3.2 Production BSD `/etc/newsyslog.conf` & Included Module Manifest
Log rotation parameters are defined using `newsyslog.conf`. The schema consists of 9 mandatory/optional fields:
`logfilename` | `owner:group` | `mode` | `count` | `size` | `when` | `flags` | `[/pid_file]` | `[sig_num]`

Below is the production master configuration (`/etc/newsyslog.conf`) and an application-specific extension file (`/etc/newsyslog.conf.d/app-services.conf`).

#### Central Configuration: `/etc/newsyslog.conf`

```syntax
# /etc/newsyslog.conf - Core BSD System Log Rotation Policy
# configuration file for newsyslog
#
# logfilename          owner:group    mode count size when  flags [/pid_file]          [sig_num]
/var/log/auth.log      root:wheel     600  12    1000 *     JC    /var/run/syslog.pid     1
/var/log/cron          root:wheel     600  10    1000 *     JC    /var/run/syslog.pid     1
/var/log/daemon.log    root:wheel     640  7     2048 *     Z     /var/run/syslog.pid     1
/var/log/debug.log     root:wheel     600  7     1024 *     ZC    /var/run/syslog.pid     1
/var/log/kernel_crit.log root:wheel   600  14    *    $D0   Z     /var/run/syslog.pid     1
/var/log/maillog       root:wheel     640  7     1000 *     ZC    /var/run/syslog.pid     1
/var/log/messages      root:wheel     644  5     1024 *     ZCNU  /var/run/syslog.pid     1
/var/log/sshd.log      root:wheel     600  14    5000 *     JC    /var/run/sshd.pid       1

# Include supplemental configuration directory
<include> /etc/newsyslog.conf.d/*.conf
```

#### Microservice Configuration: `/etc/newsyslog.conf.d/app-services.conf`

```syntax
# /etc/newsyslog.conf.d/app-services.conf - Production Application Rotation Rules
#
# logfilename               owner:group      mode count size  when flags [/pid_file]               [sig_num]
/var/log/nginx_access.log   www:www          644  24    10000 *    Z     /var/run/nginx.pid           30
/var/log/nginx_error.log    www:www          644  14    2048  *    ZC    /var/run/nginx.pid           30
/var/log/pg_cluster.log     postgres:wheel   600  30    *     $W6D0 X    /var/run/postgresql/pid.file 1
```

#### Field Explanations & Flag Glossary for `newsyslog.conf`:
- **`mode`**: Octal file permissions for created log files (e.g., `600` restricts access to owner; `644` permits world-read).
- **`count`**: Number of historical log archives to retain before deletion.
- **`size`**: Maximum file size in kilobytes (KB) before rotation triggers (e.g., `1000` = ~1 MB). Set to `*` if rotation is driven purely by time.
- **`when`**: Time-based rotation trigger.
  - `*`: Size-only rotation.
  - `$D0`: Rotate daily at midnight.
  - `$W6D0`: Rotate weekly on Saturday (Day 6) at midnight.
  - `ISO 8601` formats (e.g., `20260806T200000`).
- **`flags`**:
  - **`B`**: Treat file as binary; do not write the `newsyslog` rotational ASCII header indicator.
  - **`C`**: Create the log file if it does not exist.
  - **`J`**: Compress rotated log files using `bzip2` (`.bz2`).
  - **`Z`**: Compress rotated log files using `gzip` (`.gz`).
  - **`X`**: Compress rotated log files using `xz` (`.xz`).
  - **`Y`**: Compress rotated log files using `zstd` (`.zst`).
  - **`N`**: No daemon signal is required upon rotation.
  - **`U`**: The `pid_file` field specifies a UNIX domain socket path instead of a file containing a numerical PID.
- **`pid_file`**: Path to the PID file of the target daemon (defaults to `/var/run/syslog.pid`).
- **`sig_num`**: Signal number to transmit to the daemon post-rotation (defaults to `1` = `SIGHUP`; `30` = `SIGUSR1`).

---

### 3.3 System Initialization Syntax (`/etc/rc.conf` for FreeBSD)

```sh
# /etc/rc.conf - Syslogd and Newsyslog Daemon Flags
syslogd_enable="YES"
# -s: Secure mode (do not listen on UDP 514 socket for incoming remote messages)
# -c: Disable compression of repeated consecutive lines (log integrity)
# -b 127.0.0.1: Bind socket specifically to loopback interface if networking is needed
syslogd_flags="-s -c"

# Run newsyslog in daemon mode checking intervals every 60 minutes
newsyslog_enable="YES"
newsyslog_flags="-i 60"
```

---

## 4. Real CLI Commands and Terminal Outputs

### 4.1 Extracting Kernel Ring Buffer Logs via `dmesg` & `sysctl`

```console
$ dmesg | head -n 15
FreeBSD 14.0-RELEASE-p6 GENERIC amd64
FreeBSD clang version 16.0.6 (https://github.com/llvm/llvm-project.git llvmorg-16.0.6-0-g7c207378d37e)
VT(vga): resolution 640x480
CPU: AMD EPYC 7763 64-Core Processor (2445.38-MHz K8-class CPU)
  Origin="AuthenticAMD"  Id=0xa00f11  Family=0x19  Model=0x1  Stepping=1
real memory  = 8589934592 (8192 MB)
avail memory = 8245719040 (7863 MB)
Event timer "LAPIC" quality 600
ACPI APIC Table: <BOCHS  BXPCAPIC>
random: entropy device external interface
kbd0 at kbdmux0
smbios0: <System BIOS> at iomem 0xf0000-0xfffff
vtnet0: <Ethernet> rva 0x1000 on virtio_pci0
vtnet0: Ethernet address: 52:54:00:12:34:56
001.000000 [GIANT-LOCKED] init: flags 0x1

$ sysctl kern.msgbuf
kern.msgbuf: <13>1 2026-08-06T20:15:32.104218-04:00 bsd-prod-node01 kernel - - - vtnet0: link state changed to UP
<13>1 2026-08-06T20:15:33.401290-04:00 bsd-prod-node01 kernel - - - ZFS storage pool 'zroot' feature@async_destroy is enabled
<11>1 2026-08-06T20:22:11.001923-04:00 bsd-prod-node01 kernel - - - pf: Bad IP option (20) from 192.168.1.100 to 10.0.0.1
```

### 4.2 Generating Test Log Messages via `logger`

```console
$ logger -p local0.err -t NGINX_TEST "CRITICAL: Upstream database connection timed out on 10.0.0.50:5432"

$ tail -n 2 /var/log/nginx_error.log
Aug  6 20:30:12 bsd-prod-node01 NGINX_TEST[45102]: CRITICAL: Upstream database connection timed out on 10.0.0.50:5432
```

### 4.3 Inspecting Active and Compressed Log Files

#### Real-time Log Streaming (`tail -f`)

```console
$ tail -n 5 -f /var/log/auth.log
Aug  6 20:32:01 bsd-prod-node01 sshd[88102]: Server listening on 0.0.0.0 port 22.
Aug  6 20:32:01 bsd-prod-node01 sshd[88102]: Server listening on :: port 22.
Aug  6 20:33:15 bsd-prod-node01 sshd[88204]: Accepted publickey for admin from 192.168.1.250 port 52104 ssh2: RSA SHA256:d8a9f...
Aug  6 20:33:15 bsd-prod-node01 sudo[88209]:    admin : TTY=pts/0 ; PWD=/home/admin ; USER=root ; COMMAND=/usr/bin/su -
Aug  6 20:35:40 bsd-prod-node01 sshd[88310]: Failed password for invalid user hacker from 203.0.113.45 port 41122 ssh2
```

#### Searching Compressed Logs (`zgrep`, `zless`, `bzcat`)

```console
$ ls -l /var/log/messages*
-rw-r--r--  1 root  wheel  1048820 Aug  6 20:00 /var/log/messages
-rw-r--r--  1 root  wheel   124512 Aug  5 23:59 /var/log/messages.0.gz
-rw-r--r--  1 root  wheel   118940 Aug  4 23:59 /var/log/messages.1.gz
-rw-r--r--  1 root  wheel    98412 Aug  3 23:59 /var/log/messages.2.bz2

$ zgrep -i "OOM" /var/log/messages.0.gz /var/log/messages.1.gz
/var/log/messages.0.gz:Aug  5 14:12:01 bsd-prod-node01 kernel: pid 41203 (java), jid 0, was killed: out of swap space
/var/log/messages.1.gz:Aug  4 09:45:22 bsd-prod-node01 kernel: pid 11029 (redis-server), jid 0, was killed: out of swap space

$ bzcat /var/log/messages.2.bz2 | grep "panic" | head -n 3
Aug  3 11:20:05 bsd-prod-node01 kernel: Fatal trap 12: page fault while in kernel mode
Aug  3 11:20:05 bsd-prod-node01 kernel: cpuid = 2; apic id = 02
Aug  3 11:20:05 bsd-prod-node01 kernel: panic: vm_fault_lookup: fault on no-fault-zone address
```

### 4.4 Simulating Log Rotation Dry-Run via `newsyslog`

```console
$ newsyslog -n -v -f /etc/newsyslog.conf
Processing /etc/newsyslog.conf
Processing /etc/newsyslog.conf.d/app-services.conf
/var/log/auth.log <12J>: size (KB): 450 [1000] count: 12 --> skipped
/var/log/cron <10J>: size (KB): 120 [1000] count: 10 --> skipped
/var/log/daemon.log <7Z>: size (KB): 2150 [2048] count: 7 --> ROTATING
Signal daemon: /var/run/syslog.pid with signal 1
Trim log file /var/log/daemon.log to /var/log/daemon.log.0
Compress /var/log/daemon.log.0 to /var/log/daemon.log.0.gz with gzip
/var/log/nginx_access.log <24Z>: size (KB): 12400 [10000] count: 24 --> ROTATING
Signal daemon: /var/run/nginx.pid with signal 30
Trim log file /var/log/nginx_access.log to /var/log/nginx_access.log.0
Compress /var/log/nginx_access.log.0 to /var/log/nginx_access.log.0.gz with gzip
```

### 4.5 Auditing Active Listening Sockets and File Handles

```console
$ sockstat -46 -l -p 514
USER     COMMAND    PID   FD PROTO  LOCAL ADDRESS         FOREIGN ADDRESS      
root     syslogd    1045  4  udp4   *:514                 *:*
root     syslogd    1045  5  udp6   *:514                 *:*

$ fstat /dev/log
USER     CMD          PID FD MOUNT      INUM MODE         RDEV R/W
root     syslogd     1045  3 /var       4510 crw-rw-rw-   log  r+
www      nginx      42105  4 /var       4510 crw-rw-rw-   log   w
postgres postgres   18902  3 /var       4510 crw-rw-rw-   log   w
```

---

## 5. Verification & Failure Diagnosis Guide

```
                         [ TROUBLESHOOTING LOGGING FAILURES ]
                                          |
                        Is syslogd process running?
                                          |
                     +--------------------+--------------------+
                     | NO                                      | YES
                     v                                         v
         Check /var/log/messages or            Are logs writing to /var/log/?
         run: service syslogd start                            |
                     |                       +-----------------+-----------------+
                     v                       | NO                                | YES
         Inspect syntax errors in            v                                   v
         /etc/syslog.conf via:       Are socket permissions          Are rotated files
         syslogd -d -n               /dev/log set to 0666?           expanding infinitely?
                                             |                                   |
                                 +-----------+-----------+           +-----------+-----------+
                                 | NO                    | YES       | YES                   | NO
                                 v                       v           v                       v
                         Fix file modes via:     Check disk space   Verify newsyslog.conf   System logging
                         chmod 666 /dev/log      & mounts via:      syntax via:             functioning
                                                 df -h /var/log     newsyslog -n -v         normally.
```

### 5.1 Step-by-Step Diagnostic Workflows

#### Scenario A: Log Messages Dropped Under High System Load
1. **Symptom**: Application logs missing during traffic spikes; `syslogd` drops entries emitted to `/dev/log`.
2. **Root Cause**: The default socket buffer size for `/dev/log` is saturated, or kernel log buffer wraps over.
3. **Diagnostic Commands**:
   ```console
   # Check kernel socket buffer overflow counters
   $ netstat -s -p datagram | grep "buffer overflow"
           4120 datagram socket buffer overflows

   # Inspect syslogd process status and socket bindings
   $ fstat -p $(cat /var/run/syslog.pid)
   ```
4. **Remediation**: Increase socket buffer depth in `/etc/rc.conf` or tuning `kern.ipc.maxsockbuf`:
   ```console
   $ sysctl kern.ipc.maxsockbuf=2097152
   ```

#### Scenario B: `newsyslog` Rotates Files, but Application Continues Writing to Old Unlinked File (`.0`)
1. **Symptom**: Disk space is not reclaimed after rotation, and new log files (`/var/log/app.log`) remain 0 bytes while `/var/log/app.log.0` grows.
2. **Root Cause**: `newsyslog` failed to send the correct signal to the target process, or the process does not catch `SIGHUP` to close and reopen file handles.
3. **Diagnostic Commands**:
   ```console
   # Check deleted/unlinked open file descriptorsheld by processes
   $ fstat | grep " /var" | grep "deleted"
   www      nginx      42105  5 /var     102404 crw-r--r--  -  rw

   # Test manual signal delivery to application PID
   $ kill -HUP $(cat /var/run/nginx.pid)
   ```
4. **Remediation**: Update `/etc/newsyslog.conf` with the explicit PID file path and accurate signal number (e.g., `30` for `SIGUSR1` in NGINX).

#### Scenario C: Debugging `syslogd` Parsing Failures
1. **Symptom**: Rules defined in `/etc/syslog.conf` do not route logs to designated target files.
2. **Root Cause**: Syntax errors (e.g., spaces used instead of tabs on legacy BSD syslogd, invalid facility specifiers, or unclosed program blocks `!prog`).
3. **Diagnostic Commands**:
   ```console
   # Stop the running syslogd service
   $ service syslogd stop

   # Launch syslogd in foreground debug mode
   $ syslogd -d -n
   cfline("*.notice;auth.none /var/log/messages", f)
   cfline("auth.info /var/log/auth.log", f)
   logmsg: pri 56, flags 0, from bsd-node, msg Aug 6 20:40:00 test: hello world
   Logging to /var/log/messages
   ```

---

## 6. References

- **FreeBSD Official Manual Pages**:
  - `syslogd(8)`: System logging daemon specification and flags.  
    URL: https://man.freebsd.org/cgi/man.cgi?query=syslogd&sektion=8
  - `syslog.conf(5)`: Format and rules for system log configuration.  
    URL: https://man.freebsd.org/cgi/man.cgi?query=syslog.conf&sektion=5
  - `newsyslog(8)`: Log file rotation engine operation.  
    URL: https://man.freebsd.org/cgi/man.cgi?query=newsyslog&sektion=8
  - `newsyslog.conf(5)`: Log rotation file format and flags specification.  
    URL: https://man.freebsd.org/cgi/man.cgi?query=newsyslog.conf&sektion=5
  - `logger(1)`: User command interface to system log socket.  
    URL: https://man.freebsd.org/cgi/man.cgi?query=logger&sektion=1
- **OpenBSD Official Manual Pages**:
  - `syslogd(8)`: OpenBSD syslog daemon documentation.  
    URL: https://man.openbsd.org/syslogd.8
  - `newsyslog(8)`: OpenBSD log rotation utility documentation.  
    URL: https://man.openbsd.org/newsyslog.8
- **LPI BSD Specialist Certification Overview**:
  - Official LPI BSD Specialist (Exam 702-100) Certification Page.  
    URL: https://www.lpi.org/our-certifications/bsd-specialist-overview/