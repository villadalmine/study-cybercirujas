# LPI-702 BSD Specialist Study Guide: Topic 713.6 — Manage Printing and Print Jobs

**Certification:** LPI BSD Specialist (Exam 702-100, Version 1.0)  
**Topic:** 713.6 Manage Printing and Print Jobs  
**Weight:** 1.67  
**Target Audience:** Senior SREs, Systems Architects, and Systems Administrators operating BSD-based Unix environments.

---

## 1. Production Architecture & Operational Motivation

In enterprise UNIX and BSD infrastructure, print spooling and job management represent a critical boundary between application-layer document generation, network serialization, and hardware-level raster processing. Print subsystems must handle concurrency, network timeouts, resource starvation, and format conversion without stalling application threads or consuming excessive kernel buffers.

BSD environments rely on two primary printing paradigms:
1. **Traditional Line Printer Daemon (`lpd`)**: The historical BSD spooling subsystem adhering to RFC 1179 (Line Printer Daemon Protocol). It operates via a light, daemon-driven spooling pipeline driven by `/etc/printcap`.
2. **Common Unix Printing System (`CUPS`)**: A modular IPP-compliant (Internet Printing Protocol, RFC 2911/8010) printing system utilizing PPD (PostScript Printer Description) files, MIME type filtering pipelines, and explicit RBAC authorization.

### Architectural Breakdown: Classic BSD LPD Spooling Subsystem

```
 +------------------+     lpr     +------------------------+
 | Application / UI | ----------->| /var/spool/output/lpd/ |
 +------------------+             +------------------------+
                                              |
                                      lpd daemon reads
                                    cf* (control) & df* (data)
                                              |
                                              v
                                  +-----------------------+
                                  | Input Filter (/if)    |
                                  | Format Conversion     |
                                  +-----------------------+
                                              |
                                              v
                              +-------------------------------+
                              | Network (TCP 515 / RFC 1179)  |
                              |  OR Direct Device (/dev/lpt0) |
                              +-------------------------------+
```

The `lpd` daemon operates asynchronously by monitoring spool directories defined in `/etc/printcap`. When a job is submitted via `lpr`:
1. **Control File (`cfA*`)**: Contains metadata (user, job name, class, format flags, filter arguments).
2. **Data File (`dfA*`)**: Contains raw or unformatted payload (PostScript, plain text, PCL).
3. **Lock File (`lock`)**: Prevents multiple `lpd` processes from writing to the same physical device concurrently.

Understanding the mechanics of both `lpd` and `cupsd` is essential for maintaining deterministic spooling pipelines, hardening print network boundaries, and troubleshooting print job deadlocks in BSD environments.

---

## 2. Technical Comparisons & Architectural Trade-offs

Selecting between native BSD `lpd` and modern `cupsd` requires evaluating system resources, driver constraints, and network protocol requirements.

| Metric / Dimension | Classic BSD `lpd` | Modern `CUPS` (`cupsd`) |
| :--- | :--- | :--- |
| **Primary Protocol** | LPR/LPD (RFC 1179 over TCP port 515) | IPP/IPPS (RFC 2911 / RFC 8010 over TCP port 631) |
| **Configuration Model** | Single file `/etc/printcap` (colon-delimited key-value capabilities) | Modular directory (`/usr/local/etc/cups/cupsd.conf`, `printers.conf`, PPD directory) |
| **Memory Footprint** | Micro (< 5 MB RAM idle), zero dependencies | Moderate (20-80 MB RAM), depends on `dbus`, `avahi`, `libcups` |
| **Authentication & TLS** | Host-based IP verification (`/etc/hosts.lpd`), no native TLS | TLS/SSL enforcement, HTTP Basic/Digest authentication, PAM integration |
| **Filtering Mechanism** | Monolithic executable/shell scripts defined per capability (`if`, `of`, `xf`) | Dynamic MIME-type conversion graph (`pstoraster`, `rastertoepson`, CUPS filters) |
| **Dynamic Discovery** | Manual configuration or fixed IP endpoints | mDNS / DNS-SD / Avahi automatic queue broadcasting |
| **Fault Isolation** | High — simple process model with isolated spool locks per printer | Moderate — shared HTTP server process hosting internal filter pipelines |

---

## 3. Production Infrastructure & Complete Configurations

### A. Production `/etc/printcap` (BSD Classic LPD)

The `/etc/printcap` database uses termcap-style colon-separated key-value pairs. Lines are continued using trailing backslashes (`\`).

```ini
# /etc/printcap - Production BSD LPD Configuration
# Default local queue with input filtering and strict accounting
lp|laser_floor2|Floor 2 HP LaserJet Pro:\
        :lp=/dev/ulpt0:\
        :sd=/var/spool/output/lpd/laser_floor2:\
        :lf=/var/log/lpd-errs:\
        :af=/var/backups/printer_acct:\
        :if=/usr/local/libexec/ps2pdf_filter.sh:\
        :mx#0:\
        :sh:

# Network-attached LPD print queue (RFC 1179 passthrough)
net_eng|engineering_plotter|HP DesignJet Network:\
        :lp=:\
        :rm=10.0.20.50:\
        :rp=raw:\
        :sd=/var/spool/output/lpd/net_eng:\
        :lf=/var/log/lpd-errs:\
        :mx#0:\
        :sh:
```

### B. Complete Custom Input Filter (`/usr/local/libexec/ps2pdf_filter.sh`)

Input filters in `lpd` receive options passed via standard switches (`-c`, `-w`, `-l`, `-n`, `-h`) and handle `stdin` to `stdout` streaming.

```bash
#!/bin/sh
# /usr/local/libexec/ps2pdf_filter.sh
# Production LPD Input Filter for ASCII to PostScript / Pass-through conversion
set -eu

LOGFILE="/var/log/lpd-filter.log"
DATE_STAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Parse stdin first 4 bytes to check for PostScript magic bytes (%!PS)
HEADER=$(head -c 4)

exec 3>&1

{
    echo "[${DATE_STAMP}] Processing print job for filter..." >> "${LOGFILE}"

    if [ "${HEADER}" = "%!PS" ]; then
        # Direct PostScript pass-through: concatenate header and remaining stream
        echo "[${DATE_STAMP}] Format detected: PostScript raw pass-through" >> "${LOGFILE}"
        { printf "%s" "${HEADER}"; cat; }
    else
        # Plain text: convert ASCII to PostScript via enscript or text2ps
        echo "[${DATE_STAMP}] Format detected: Plain Text (converting via enscript)" >> "${LOGFILE}"
        { printf "%s" "${HEADER}"; cat; } | /usr/local/bin/enscript -B -p - 2>> "${LOGFILE}"
    fi
}

exit 0
```

Ensure correct execution permissions and spool directory setup:

```bash
# Set appropriate owner and access control on spool and filter
chown -R daemon:daemon /var/spool/output/lpd/laser_floor2 /var/spool/output/lpd/net_eng
chmod 755 /usr/local/libexec/ps2pdf_filter.sh
chmod 770 /var/spool/output/lpd/*
```

### C. Hardened CUPS Configuration (`/usr/local/etc/cups/cupsd.conf`)

Below is a complete, production-grade `/usr/local/etc/cups/cupsd.conf` enforced for security and enterprise subnet isolation.

```apache
# /usr/local/etc/cups/cupsd.conf - Enterprise Hardened Configuration
LogLevel info
PageLogFormat %p %u %j %T %P %C %{job-billing} %{job-originating-host-name} %{job-name} %{media} %{sides}
MaxLogSize 1m

# Network Listening Configuration
Listen 127.0.0.1:631
Listen 10.0.10.5:631
Listen /var/run/cups.sock

# Encryption Settings
ServerAlias *
DefaultEncryption IfRequested

# Security and Policy Controls
<Location />
  Order allow,deny
  Allow from 127.0.0.1
  Allow from 10.0.10.0/24
</Location>

<Location /admin>
  Order allow,deny
  Allow from 10.0.10.0/24
  Require user @SYSTEM
  Encryption Required
</Location>

<Location /admin/conf>
  AuthType Default
  Require user @SYSTEM
  Order allow,deny
  Allow from 10.0.10.250
</Location>

<Policy default>
  JobPrivateAccess default
  JobPrivateValues default
  SubscriptionPrivateAccess default
  SubscriptionPrivateValues default

  <Limit Create-Job Print-Job Print-URI Validate-Job>
    Order allow,deny
    Allow from 10.0.10.0/24
  </Limit>

  <Limit Send-Document Send-URI Cancel-Job Hold-Job Release-Job Restart-Job Purge-Jobs Set-Job-Attributes Create-Job-Subscription Renew-Subscription Close-Job Get-Notifications Reprocess-Job Cancel-Current-Job Suspend-Current-Job Resume-Job Cancel-My-Jobs Get-Notifications Get-Job-Attributes>
    Require user @OWNER @SYSTEM
    Order allow,deny
    Allow from 10.0.10.0/24
  </Limit>

  <Limit CUPS-Add-Modify-Printer CUPS-Delete-Printer CUPS-Add-Modify-Class CUPS-Delete-Class CUPS-Set-Default CUPS-Pause-Printer CUPS-Resume-Printer>
    AuthType Default
    Require user @SYSTEM
    Order allow,deny
  </Limit>
</Policy>
```

### D. OpenBSD / FreeBSD Packet Filter (`/etc/pf.conf`) Snippet

```pf
# /etc/pf.conf - Print Services Firewall Enforcement
ext_if = "em0"
admin_net = "10.0.10.0/24"

# Table of allowed print clients
table <print_clients> { 10.0.10.0/24, 10.0.20.0/24 }

# Block unapproved inbound traffic to print ports
block in log on $ext_if proto tcp from any to any port { 515, 631 }

# Pass legitimate LPD and IPP requests
pass in quick on $ext_if proto tcp from <print_clients> to $ext_if port { 515, 631 } flags S/SA keep state
```

### E. System Initialization (`/etc/rc.conf`)

Enable native LPD or CUPS services in FreeBSD/NetBSD `/etc/rc.conf`:

```sh
# /etc/rc.conf
# Enable classic LPD
lpd_enable="YES"
lpd_flags="-l"    # Log incoming requests via syslog

# Alternatively, enable CUPS (disable lpd if cupsd is used)
cupsd_enable="YES"
```

---

## 4. Real-world CLI Operations & Expected Terminal Outputs

### A. Classic BSD Print Management (`lpc`, `lpr`, `lpq`, `lprm`)

#### 1. Checking Spool Status (`lpc status`)
```bash
$ lpc status
laser_floor2:
        queuing is enabled
        printing is enabled
        1 entry in spool area
        printer is ready and printing
net_eng:
        queuing is enabled
        printing is disabled
        0 entries in spool area
        daemon present
```

#### 2. Controlling Print Queues (`lpc`)
The `lpc` command can run interactively or non-interactively to disable queuing, halt printing, or reprioritize jobs.

```bash
# Disable queuing for maintenance and stop the active spooler daemon
$ sudo lpc disable net_eng
net_eng:
        queuing disabled

$ sudo lpc stop net_eng
net_eng:
        printing disabled
        daemon killed
```

#### 3. Submitting Jobs (`lpr`)
Submit a PostScript job to a specific printer with custom job ownership and metadata:

```bash
$ lpr -P laser_floor2 -J "Q3_Financial_Report" -#2 /usr/local/share/docs/report.ps
```

#### 4. Inspecting Queue Details (`lpq`)
```bash
$ lpq -P laser_floor2
Rank   Owner      Job  Files                                 Total Size
active dbrown     42   report.ps                             1048576 bytes
1st    jdoe       43   (standard input)                      51200 bytes
```

#### 5. Removing Print Jobs (`lprm`)
Remove an active job by ID, or clear all jobs for a specific user:

```bash
# Remove specific job 42
$ sudo lprm -P laser_floor2 42
dfA042host1 dequeued
cfA042host1 dequeued

# Remove all jobs owned by current user
$ lprm -P laser_floor2 -
```

---

### B. CUPS Management CLI (`lpadmin`, `lpstat`, `cupsenable`, `cupsaccept`)

#### 1. Provisioning a CUPS Queue (`lpadmin`)
Add a new IPP network printer using an existing PPD driver file:

```bash
$ sudo lpadmin -p Eng_LaserJet \
    -E \
    -v ipp://10.0.20.50/ipp/print \
    -m raw \
    -L "Building B, Room 302" \
    -D "HP LaserJet Engineering Queue"
```

#### 2. Querying Queue Status and Defaults (`lpstat`)
```bash
$ lpstat -p Eng_LaserJet -d -o
system default destination: Eng_LaserJet
printer Eng_LaserJet is idle.  enabled since Thu Aug  6 14:22:10 2026
Eng_LaserJet-101      sysadmin          20480   Thu Aug  6 14:30:00 2026
```

#### 3. Enabling Queues and Accepting Jobs
```bash
$ sudo cupsaccept Eng_LaserJet
destination "Eng_LaserJet" is now accepting jobs.

$ sudo cupsenable Eng_LaserJet
printer "Eng_LaserJet" is now enabled.
```

---

## 5. Production Verification & Diagnostics Guide

When print jobs fail, stall, or corrupt, SREs must follow a systematic diagnostic methodology to trace failure vectors across the OS spooler, filter executables, system permissions, and network sockets.

```
       Print Job Submitted (lpr / lp)
                     |
                     v
   [ Step 1: Daemon Verification ]
     Is lpd / cupsd process running?
             /               \
          (No)               (Yes)
           |                   |
    Start Daemon               v
   (service lpd start)   [ Step 2: Spool Directory Audit ]
                         Check lock files, permissions (daemon:daemon)
                         & disk space (/var/spool/output/lpd/)
                               |
                               v
                         [ Step 3: Filter Pipeline Execution ]
                         Test filter script manually on input file:
                         cat file.ps | /path/to/filter > /tmp/out.raw
                               |
                               v
                         [ Step 4: Network & Socket Testing ]
                         Test TCP 515/631 via nc / tcpdump:
                         nc -zv <printer_ip> 515
```

### Troubleshooting Workflow

#### Step 1: Daemon & Process Verification
Verify that the `lpd` or `cupsd` process is running:

```bash
$ pgrep -lf lpd
9821 /usr/sbin/lpd -l

$ service lpd status
lpd is running as pid 9821.
```

If the daemon is not running, check `/var/log/messages` or syslog output for initialization errors:

```bash
$ tail -n 20 /var/log/messages | grep lpd
```

#### Step 2: Spool Directory and Lock File Inspection
Stalled jobs in classic `lpd` often stem from stale lock files left behind after an ungraceful system shutdown or a crashing filter script.

```bash
$ ls -la /var/spool/output/lpd/laser_floor2/
total 16
drwxrwx---  2 daemon  daemon  512 Aug  6 14:00 .
drwxr-xr-x  4 root    daemon  512 Aug  6 13:30 ..
-rw-r--r--  1 daemon  daemon    4 Aug  6 14:00 cfA042host1
-rw-r--r--  1 daemon  daemon  1048576 Aug  6 14:00 dfA042host1
-rw-r--r--  1 daemon  daemon   19 Aug  6 14:00 lock
```

Inspect the `lock` file contents (contains the active PID and current control file):

```bash
$ cat /var/spool/output/lpd/laser_floor2/lock
9822 cfA042host1
```

If PID 9822 does not exist (`kill -0 9822` returns no such process), clear the stale lock:

```bash
$ sudo lpc stop laser_floor2
$ sudo rm /var/spool/output/lpd/laser_floor2/lock
$ sudo lpc restart laser_floor2
```

#### Step 3: Filter Pipeline Debugging
To isolate input filter issues from spooling issues, run the defined filter directly from the command line under the `daemon` user:

```bash
$ sudo -u daemon /usr/local/libexec/ps2pdf_filter.sh < /tmp/test_document.ps > /tmp/filtered_output.raw
$ echo $?
0
```

Inspect the log output generated by the filter script:

```bash
$ cat /var/log/lpd-filter.log
[2026-08-06 14:05:12] Processing print job for filter...
[2026-08-06 14:05:12] Format detected: PostScript raw pass-through
```

#### Step 4: Network & Socket Diagnostic Tracing
If remote network printing via LPR (`rm` parameter in `/etc/printcap`) or CUPS IPP fails, verify layer 4 network reachability and perform packet tracing:

```bash
# Check connectivity to destination printer on port 515 (LPD) or 631 (IPP)
$ nc -zv 10.0.20.50 515
Connection to 10.0.20.50 515 port [tcp/printer] succeeded!

# Monitor raw LPR traffic using tcpdump
$ sudo tcpdump -ni em0 -s 0 -A 'host 10.0.20.50 and tcp port 515'
14:10:00.123456 IP 10.0.10.5.1023 > 10.0.20.50.515: Flags [P.], seq 1:3, ack 1, win 65535, length 2
E..a..@.@..v...n...r...s...#...P..W.....\002raw\n
```

---

## 6. References

* **LPI BSD Specialist Certification Overview**:  
  [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

* **FreeBSD Handbook: Chapter 9, Printing**:  
  [https://docs.freebsd.org/en/books/handbook/printing/](https://docs.freebsd.org/en/books/handbook/printing/)

* **OpenBSD `lpd(8)` Manual Page**:  
  [https://man.openbsd.org/lpd.8](https://man.openbsd.org/lpd.8)

* **OpenBSD `printcap(5)` Manual Page**:  
  [https://man.openbsd.org/printcap.5](https://man.openbsd.org/printcap.5)

* **CUPS System Administrator Documentation**:  
  [https://www.cups.org/doc/overview.html](https://www.cups.org/doc/overview.html)

* **RFC 1179 — Line Printer Daemon Protocol**:  
  [https://datatracker.ietf.org/doc/html/rfc1179](https://datatracker.ietf.org/doc/html/rfc1179)

* **RFC 2911 — Internet Printing Protocol/1.1: Model and Semantics**:  
  [https://datatracker.ietf.org/doc/html/rfc2911](https://datatracker.ietf.org/doc/html/rfc2911)