# LPI BSD Specialist (Exam 702-100) — Topic 713.3: Maintain System Time

**Weight:** 1.67  
**Target Certification:** LPI BSD Specialist (Version 1.0)  
**Level:** Advanced SRE / Production Platform Engineering  

---

## 1. Deep Technical Architecture & Internal Mechanics

### 1.1 Hardware Clock (RTC) vs. System Clock Architecture

BSD operating systems maintain two distinct clocks: the **Real-Time Clock (RTC / CMOS Clock)** and the **System Clock (Kernel Timekeeper)**.

```
+-------------------------------------------------------------------+
|                        Hardware Layer                             |
|  Real-Time Clock (RTC / CMOS) [Battery Backed, Persists on Off]   |
+-------------------------------------------------------------------+
                                  |
               Boot Initialization / Shutdown Sync
               (FreeBSD: adjkerntz(8) / init)
                                  v
+-------------------------------------------------------------------+
|                        Kernel Subsystem                           |
|  System Clock (Monotonic & Realtime Epoch via Timecounter API)    |
+-------------------------------------------------------------------+
       ^                                                    ^
       | Slewing (adjtime(2))                               | Stepping (settimeofday(2))
       | max ~500 PPM rate adj                              | hard jump (large offsets)
+-------------------------------+  +--------------------------------+
|       NTP Daemon (ntpd)       |  |  Manual / One-shot Utilities   |
| (FreeBSD ntpd / OpenBSD ntpd) |  |   (date, sntp, ntpdate -b)    |
+-------------------------------+  +--------------------------------+
```

1. **Hardware Clock (RTC / CMOS)**:
   - Powered by a motherboard battery. It keeps track of time while the machine is powered off.
   - Typically operates in **Coordinated Universal Time (UTC)** on Unix systems. 
   - On FreeBSD systems dual-booted or requiring local RTC time, `adjkerntz(8)` maintains the offset between local time and UTC stored in the CMOS clock, updating kernel variables via system calls.

2. **System Clock (Kernel Clock)**:
   - Represented as fractional seconds elapsed since the Unix Epoch (`1970-01-01 00:00:00 UTC`).
   - Driven continuously during uptime by high-frequency hardware timers (HPET, TSC, ACPI-fast) monitored by the kernel's **Timecounter framework**.

3. **Timezone Resolution**:
   - Timezones do not alter the system clock; they only alter human-readable conversions.
   - Handled via `/etc/localtime`, which is a copy or symbolic link pointing to a compiled zoneinfo file inside `/usr/share/zoneinfo/` (e.g., `/usr/share/zoneinfo/UTC` or `/usr/share/zoneinfo/America/New_York`).
   - Administered natively on FreeBSD using `tzsetup(8)`.

---

### 1.2 Kernel Timecounters and Clock Drift Dynamics

FreeBSD relies on the `timecounter(9)` abstraction layer to measure time intervals. The kernel queries available hardware timers and selects the most reliable source based on hardware quality scoring.

```
$ sysctl kern.timecounter
kern.timecounter.tc.i8254.mask: 65535
kern.timecounter.tc.i8254.counter: 41208
kern.timecounter.tc.i8254.frequency: 1193182
kern.timecounter.tc.i8254.quality: 0
kern.timecounter.tc.ACPI-fast.mask: 16777215
kern.timecounter.tc.ACPI-fast.counter: 12401831
kern.timecounter.tc.ACPI-fast.frequency: 3579545
kern.timecounter.tc.ACPI-fast.quality: 1000
kern.timecounter.tc.HPET.mask: 4294967295
kern.timecounter.tc.HPET.counter: 284104812
kern.timecounter.tc.HPET.frequency: 14318180
kern.timecounter.tc.HPET.quality: 950
kern.timecounter.tc.TSC-low.mask: 4294967295
kern.timecounter.tc.TSC-low.counter: 1984019284
kern.timecounter.tc.TSC-low.frequency: 2394410180
kern.timecounter.tc.TSC-low.quality: 1000
kern.timecounter.hardware: TSC-low
kern.timecounter.choice: TSC-low(1000) ACPI-fast(1000) HPET(950) i8254(0) dummy(-1000000)
```

#### Clock Adjustment Mechanics: Slewing vs. Stepping

| Parameter | Slewing (`adjtime(2)`) | Stepping (`settimeofday(2)` / `clock_settime(2)`) |
| :--- | :--- | :--- |
| **Execution** | Modifies frequency rate of system tick. | Hard jump directly to target epoch. |
| **Clock Continuity** | Monotonic, continuous. Time never flows backwards. | Non-monotonic. Can cause backward time jumps. |
| **Max Drift Delta** | Used when offset is small ($< 128\text{ ms}$ by default in standard NTP). | Used when offset is large ($> 128\text{ ms}$ or on initial startup). |
| **Max Slew Rate** | Usually capped at 500 Parts Per Million (PPM) ($0.5\text{ ms/s}$). | Instantaneous. |
| **Impact on Apps** | Safe for production databases (PostgreSQL, ZFS txgs, Kafka, TLS auth). | High risk of duplicate primary keys, broken timeouts, and log corruption. |

#### NTP Filtering Pipeline & Stratum Hierarchy

1. **Stratum Architecture**:
   - **Stratum 0**: High-precision physical devices (Atomic clocks, GPS receivers, Rubidium oscillators).
   - **Stratum 1**: Servers directly connected to Stratum 0 devices.
   - **Stratum 2**: Servers synchronizing over network connections with Stratum 1 servers.
   - **Stratum $N$**: Servers synchronizing with Stratum $N-1$ servers (max Stratum 15; Stratum 16 indicates unsynchronized state).

2. **Selection Algorithms**:
   - **Marzullo's Algorithm / Intersection Algorithm**: Filters out "falsetickers" (servers producing erroneous time spikes) and isolates "truechimers".
   - **Clock Discipline Algorithm**: Calculates the fractional frequency offset (recorded in `/var/db/ntp/ntp.drift` or `/var/db/ntpd.drift`) to adjust kernel oscillator frequency persistently.

---

### 1.3 BSD NTP Implementations: FreeBSD `ntpd` vs. OpenBSD OpenNTPD

| Feature | FreeBSD Reference `ntpd` | OpenBSD OpenNTPD (`ntpd`) |
| :--- | :--- | :--- |
| **Upstream Codebase** | Network Time Foundation (NTF) reference `ntp.org` | OpenBSD Project (Clean-room rewrite) |
| **Primary Focus** | Maximum clock accuracy, full RFC 5905 spec support. | Security, privilege separation, minimalism, ease of config. |
| **Configuration** | `/etc/ntp.conf` | `/etc/ntpd.conf` |
| **Control Utility** | `ntpq` (Query daemon statistics & peer matrix) | `ntpctl` (Query daemon and sensor status) |
| **Privilege Model** | Standard daemon process | Chrooted `_ntp` unprivileged user + parent privileged monitor |
| **HTTPS Constraints** | Not natively built-in | Supported (`constraint from`), uses TLS to prevent MITM attacks |

---

## 2. Production Reference Configurations & Manifests

### 2.1 Enterprise FreeBSD `/etc/ntp.conf`

```conf
# ==============================================================================
# Enterprise Production NTP Configuration - FreeBSD
# File: /etc/ntp.conf
# Reference: ntp.conf(5)
# ==============================================================================

# Record the frequency offset of the local system clock.
driftfile /var/db/ntp/ntp.drift

# Directory for statistics files
statsdir /var/log/ntp/
filegen peerstats file peerstats type day enable
filegen loopstats file loopstats type day enable

# ==============================================================================
# Security & Access Control Matrix (Default Deny Stance)
# ==============================================================================

# Ignore all incoming packet streams by default (Security hardening)
restrict default limited kod nomodify nopeer noquery notrap
restrict -6 default limited kod nomodify nopeer noquery notrap

# Allow full management access from local loopback interfaces
restrict 127.0.0.1
restrict ::1

# ==============================================================================
# Upstream Stratum 1/2 Time Servers (Pool & Explicit Peers)
# ==============================================================================

# Pool directive fetches multiple IPs from pool.ntp.org DNS round-robin
pool 0.freebsd.pool.ntp.org iburst maxpoll 9
pool 1.freebsd.pool.ntp.org iburst maxpoll 9
pool 2.freebsd.pool.ntp.org iburst maxpoll 9

# Explicit upstream stratum 1 servers with restriction privileges allowed for sync
server time.nist.gov iburst
restrict time.nist.gov nomodify async noquery

# Disable panic threshold (allows step adjustment on boot regardless of offset magnitude)
tinker panic 0
```

---

### 2.2 FreeBSD System Startup Configuration `/etc/rc.conf`

```sh
# ==============================================================================
# Time Synchronization Daemon Settings - FreeBSD
# File: /etc/rc.conf
# Reference: rc.conf(5)
# ==============================================================================

# Enable standard FreeBSD ntpd daemon on system startup
ntpd_enable="YES"

# Perform initial step jump on boot before starting continuous slewing daemon
ntpd_sync_on_start="YES"

# Custom operational arguments for ntpd daemon process
ntpd_flags="-p /var/run/ntpd.pid -f /var/db/ntp/ntp.drift"

# Ensure CMOS clock is updated correctly upon shutdown/reboot
adjkerntz_flags="-a"
```

---

### 2.3 OpenBSD Secure OpenNTPD Configuration `/etc/ntpd.conf`

```conf
# ==============================================================================
# OpenNTPD Production Manifest with HTTPS Constraints - OpenBSD
# File: /etc/ntpd.conf
# Reference: ntpd.conf(5)
# ==============================================================================

# Listen on local interfaces for internal subnet queries
listen on 127.0.0.1
listen on ::1

# Query NTP pool servers for time synchronization
servers pool.ntp.org

# Attach hardware sensors (e.g. DCF77, GPS attached to serial port) if present
sensor *

# ==============================================================================
# Security Constraints (TLS-Anchored Time Validation against MITM Attacks)
# ==============================================================================

# Validate NTP timestamps against authenticated HTTPS Date headers
constraint from "www.google.com"
constraints from "https://www.cloudflare.com"
```

---

## 3. Hands-on Production Guided Exercises

### Exercise 1: Timezone Configuration, RTC Adjustment, and Kernel Timecounter Inspection

#### Step 1.1: Verify current system time and set the system timezone to UTC non-interactively

Execute the following commands to inspect system time and configure timezone parameters on FreeBSD:

```bash
# Check current timezone link and system date
ls -l /etc/localtime
date -u
```

*Expected Output:*
```text
-r--r--r--  1 root  wheel  3519 Aug  6 20:40 /etc/localtime
Thu Aug  6 20:40:16 UTC 2026
```

Set system timezone to UTC using `tzsetup`:

```bash
# Non-interactively install UTC zoneinfo to /etc/localtime
tzsetup -s UTC
ls -l /etc/localtime
```

*Expected Output:*
```text
lrwxr-xr-x  1 root  wheel  36 Aug  6 20:40 /etc/localtime -> /usr/share/zoneinfo/UTC
```

#### Step 1.2: Inspect kernel timecounter choice, quality metrics, and hardware timers

Run `sysctl` to inspect timecounter hardware candidates evaluated by the BSD kernel:

```bash
sysctl kern.timecounter.choice kern.timecounter.hardware
```

*Expected Output:*
```text
kern.timecounter.choice: TSC-low(1000) ACPI-fast(1000) HPET(950) i8254(0) dummy(-1000000)
kern.timecounter.hardware: TSC-low
```

#### Step 1.3: Analyze CMOS hardware clock state and execute `adjkerntz`

Query hardware RTC time adjustments:

```bash
adjkerntz -a
```

*Expected Output:*
```text
(Command executes silently with return code 0, syncing kernel local-time offset to RTC).
```

---

#### Verification Questions (Exercise 1)

**Question 1.1:** A FreeBSD production database server exhibits unexplained log timestamp jumps backward by 5 hours whenever the system reboots. Investigation reveals that `/etc/localtime` points to `America/New_York` (UTC-5), but the RTC CMOS hardware clock is maintained in local time by the motherboard BIOS. Which utility and configuration file mechanism should be used to guarantee the kernel compensates for local-time RTC offsets during boot?

**Question 1.2:** What is the primary operational risk of changing `kern.timecounter.hardware` to `i8254` (quality score 0) on a high-throughput multi-core hypervisor running FreeBSD?

---

### Exercise 2: Production Setup and Management of FreeBSD Reference `ntpd`

#### Step 2.1: Write `/etc/ntp.conf` and enforce restricted access controls

Deploy the production `/etc/ntp.conf` file:

```bash
cat << 'EOF' > /etc/ntp.conf
driftfile /var/db/ntp/ntp.drift
restrict default limited kod nomodify nopeer noquery notrap
restrict -6 default limited kod nomodify nopeer noquery notrap
restrict 127.0.0.1
restrict ::1

pool 0.freebsd.pool.ntp.org iburst
pool 1.freebsd.pool.ntp.org iburst
EOF
```

#### Step 2.2: Perform a one-shot step sync before daemon startup

Before initiating continuous synchronization, execute a step jump using `ntpd -gq` (or `sntp`) to correct high initial clock drift:

```bash
ntpd -gq
```

*Expected Output:*
```text
ntpd: time slew +0.001248s
```

#### Step 2.3: Enable and start `ntpd` service in `/etc/rc.conf`

```bash
sysrc ntpd_enable="YES"
sysrc ntpd_sync_on_start="YES"
service ntpd start
```

*Expected Output:*
```text
ntpd_enable: NO -> YES
ntpd_sync_on_start: NO -> YES
Starting ntpd.
```

#### Step 2.4: Inspect NTP peer topology and status using `ntpq`

Query the peer status matrix and system variables using `ntpq`:

```bash
ntpq -p
```

*Expected Output:*
```text
     remote           refid      st t when poll reach   delay   offset  jitter
==============================================================================
*time.nist.gov   .GPS.            1 u   24   64  377   18.241   -0.112   0.042
+0.freebsd.pool  192.168.1.1      2 u   19   64  377   24.810    0.245   0.108
+1.freebsd.pool  204.9.156.12     2 u   52   64  377   31.104   -0.089   0.095
```

Execute system info query:

```bash
ntpq -c sysinfo
```

*Expected Output:*
```text
associd=0 status=0615 leap_none, sync_ntp, 1 filter, condition_pass,
system peer:        time.nist.gov:123
system peer mode:   client
leap:               00
stratum:            2
log2 precision:     -23
rootdelay:          18.241
rootdisp:           11.450
reference ID:       129.6.15.28
reference time:     eb5291a0.d4e21a00  Thu, Aug  6 2026 20:40:32.831
system jitter:      0.042000 ms
clock jitter:       0.038 ms
clock wander:       0.001 PPM
broadcastdelay:     0.000
sys_choplset:       0.000
```

---

#### Verification Questions (Exercise 2)

**Question 2.1:** In the output of `ntpq -p`, what does the asterisk (`*`) tally character prefixed to `time.nist.gov` signify compared to the plus sign (`+`) character prefixed to `0.freebsd.pool`?

**Question 2.2:** Why is the `iburst` option recommended on pool and server directives in enterprise `/etc/ntp.conf` files?

---

### Exercise 3: Advanced Diagnostics, Drift Analysis, and OpenBSD OpenNTPD / Constraint Validation

#### Step 3.1: Analyze hardware clock frequency drift in `/var/db/ntp/ntp.drift`

Examine the contents of the clock frequency drift file generated by `ntpd`:

```bash
cat /var/db/ntp/ntp.drift
```

*Expected Output:*
```text
-12.483
```

#### Step 3.2: Troubleshoot firewall and NTP UDP port 123 blocking issues

If `ntpq -p` shows `reach` values remaining at `0` or not incrementing up to `377` octal, test UDP packet transport to remote NTP servers.

Inspect current reachability octal representation via `ntpq`:

```bash
ntpq -c "rv &1 reach,offset,delay"
```

*Expected Output (Failure State):*
```text
reach=000, offset=0.000, delay=0.000
```

*Expected Output (Healthy State after 8 successful polls):*
```text
reach=377, offset=-0.112, delay=18.241
```

#### Step 3.3: Verify OpenBSD OpenNTPD operational status via `ntpctl`

On OpenBSD systems using `openntpd`, execute system inspection using `ntpctl`:

```bash
ntpctl -s all
```

*Expected Output:*
```text
1/1 peers valid, clock is synced, stratum 2

peer                           not valid   cnt  interval  offset
104.131.205.158 from pool      valid       8    32s       -0.084ms

constraint                     status                          received
172.217.16.206 from www.google.com
                               valid                           1s ago
```

---

#### Verification Questions (Exercise 3)

**Question 3.1:** An administrator notices that `/var/db/ntp/ntp.drift` contains a value of `500.000`. The daemon logs state `frequency error 500 PPM exceeds tolerance limit`. What does this indicate about the underlying system timekeeping hardware, and how does standard `ntpd` react to this condition?

**Question 3.2:** How do OpenBSD's OpenNTPD `constraint` directives protect a system against Network Time Protocol Man-In-The-Middle (MITM) time-spoofing attacks?

---

## 4. Official Reference Documentation

- **LPI BSD Specialist Certification Overview**:  
  [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
- **FreeBSD Handbook — Network Time Protocol (NTP)**:  
  [https://docs.freebsd.org/en/books/handbook/network-servers/#network-ntp](https://docs.freebsd.org/en/books/handbook/network-servers/#network-ntp)
- **FreeBSD Manual Pages (`ntp.conf(5)`, `ntpd(8)`, `adjkerntz(8)`, `timecounter(9)`)**:  
  [https://man.freebsd.org/](https://man.freebsd.org/)
- **OpenBSD Manual Pages (`ntpd(8)`, `ntpd.conf(5)`, `ntpctl(8)`)**:  
  [https://man.openbsd.org/](https://man.openbsd.org/)

---

## 5. Answers and Technical Explanations

<details>
<summary><strong>Click to expand Answers & Technical Rationale</strong></summary>

### Exercise 1 Answer Key

* **Answer 1.1:**
  To handle a CMOS clock kept in local time, FreeBSD uses `adjkerntz(8)`. The configuration is maintained in `/etc/rc.conf` via `adjkerntz_flags="-a"` and invoked during boot and shutdown (`rc.d/adjkerntz`). When executed with `-a`, `adjkerntz` calculates the offset between UTC and local wall clock time according to `/etc/localtime` and instructs the kernel (`machdep.wall_cmos_clock`) how to interpret hardware RTC readings accurately without incurring 5-hour phase jumps upon reboot.

* **Answer 1.2:**
  The `i8254` timecounter relies on the ancient Intel 8254 Programmable Interval Timer (PIT). It has a quality score of `0` because reading it requires costly I/O port reads (`0x40`/`0x43`) which involve high CPU latency and bus contention. On multi-core SMP systems, concurrent locks and I/O port stalls when fetching system timestamps (`gettimeofday(2)`) severely degrade throughput and add massive CPU overhead compared to lockless hardware counter registers such as `TSC-low` or `HPET`.

---

### Exercise 2 Answer Key

* **Answer 2.1:**
  In `ntpq -p` output:
  - The asterisk (`*`) indicates the **system peer**. This is the single active upstream source selected by the NTP clock discipline algorithm to synchronize the local system clock.
  - The plus sign (`+`) indicates a **candidate peer** (survivor of the Marzullo intersection algorithm). Candidate peers are validated, high-quality sources that are ready to take over as the system peer if the current system peer (`*`) fails or becomes unreachable.

* **Answer 2.2:**
  The `iburst` (initial burst) option instructs `ntpd` to send a burst of 8 packets spaced 2 seconds apart when a remote peer is unreachable or upon initial daemon startup. This allows `ntpd` to quickly acquire multiple timing samples, complete synchronization, and establish valid clock discipline within seconds of starting, rather than waiting through standard polling intervals (which can take 64 to 1024 seconds).

---

### Exercise 3 Answer Key

* **Answer 3.1:**
  A drift value of `500.000` PPM represents the absolute maximum frequency adjustment limit supported by the NTP kernel phase-locked loop (PLL) / frequency-locked loop (FLL) architecture ($500\text{ PPM} = 0.05\%$). If the hardware clock drifts faster than 500 PPM, standard `ntpd` cannot slews the clock quickly enough to maintain synchronization. The daemon will log an error and terminate (abort) to prevent maintaining an unstable or unpredictable system clock.

* **Answer 3.2:**
  OpenNTPD `constraint` directives query authenticated HTTPS web servers over TLS (e.g., `https://www.cloudflare.com`) to extract valid HTTP `Date:` response headers. Because TLS connections use X.509 certificate validation, an attacker conducting NTP UDP packet spoofing or man-in-the-middle attacks cannot forge the TLS-authenticated constraint time window. OpenNTPD validates that NTP server timestamps fall within a reasonable delta of the HTTPS constraint time; if an unauthenticated NTP packet attempts to step system time far outside the HTTPS constraint window, it is discarded as malicious.

</details>