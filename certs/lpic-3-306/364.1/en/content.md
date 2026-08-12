# Topic 364.1 — Hardware and Resource High Availability

**LPIC-3 306 (exam 306-300, v3.0) · Topic 364: Single Node High Availability · Weight: 3.33**

---

## 1. The architectural problem: the node under the cluster is still a SPOF

Every design pattern in the earlier objectives — Pacemaker/Corosync failover clusters (361.3), LVS/HAProxy load balancing (361.2), DRBD and shared-disk storage (362) — rests on an assumption that individual nodes **fail cleanly and observably**. Production reality is the opposite. The failure modes that destroy an HA cluster are precisely the ones that happen *inside a single node and are invisible to the cluster stack*:

- **A wedged kernel that does not release its resources.** Corosync loses the token, the surviving partition tries to take over the VIP and the DRBD primary role — but the "dead" node is not dead, its NIC is just starved. This is the classic split-brain generator. Cluster-level fencing (STONITH) exists to solve this, but STONITH needs an *out-of-band* path (IPMI) and a *self-fencing fallback* (a hardware watchdog + SBD) for the case where the network path to the BMC is also gone.
- **Silent media degradation.** A disk accumulates reallocated and pending sectors for weeks. On a DRBD replicated volume, a read of a pending sector returns a read error that propagates as data corruption to *both* replicas' consumers, or forces a resync storm. The failure was predictable days in advance from S.M.A.R.T. telemetry that nobody was collecting.
- **A partial hardware fault** — a failed PSU on a dual-PSU chassis, a fan at 0 RPM, ECC correctable errors climbing toward uncorrectable, an inlet temperature past the throttle threshold. None of these appear in `top`, `dmesg` (until it is too late), or the cluster's resource monitors. They live in the BMC's sensor data repository and event log.

**Single-node HA is the substrate that makes multi-node HA trustworthy.** The three pillars of this objective map directly onto three questions an SRE must be able to answer for every node:

| Pillar | Question it answers | Failure it prevents | Primary tooling |
|---|---|---|---|
| **S.M.A.R.T. monitoring** | *Will this disk fail soon?* | Data loss / resync storms from silent media decay | `smartctl`, `smartd` |
| **Hardware watchdog** | *If the kernel hangs, will the node reliably reset itself?* | Split-brain from a "half-dead" node that STONITH can't reach | `/dev/watchdog`, systemd, `watchdog`d, SBD |
| **IPMI / BMC** | *Can I see and control this node when the OS is unreachable?* | Blind spots + no out-of-band fencing / recovery path | `ipmitool`, `ipmievd`, `fence_ipmilan` |

The watchdog is not a monitoring nicety — in a Pacemaker cluster it **is the fencing mechanism of last resort**. SBD (Storage-Based Death) arms the hardware watchdog and requires the node to keep writing a heartbeat to a shared block device; if the node loses quorum or fails to service its watchdog, the timer expires and the hardware resets the machine *without any cooperation from the OS*. That is the only fencing method that still works when the BMC network, the corosync ring, and the OS are all simultaneously unreachable.

---

## 2. Pillar 1 — S.M.A.R.T. with smartmontools

### 2.1 What SMART actually reports, and why the normalized values mislead

Each ATA SMART attribute has an ID, a **normalized VALUE** (vendor-defined, typically starts at 100 or 253 and decays toward a THRESH), a **WORST** (lowest normalized value ever seen), a **THRESH** (failure threshold), a **TYPE** (`Pre-fail` = predicts imminent failure; `Old_age` = wear), an **UPDATED** flag (`Always` or `Offline`), a **WHEN_FAILED** column, and a **RAW_VALUE**. The trap for a new SRE: the *normalized* value can still read `100` while the *raw* value is screaming. Always read the raw column of the attributes that matter.

**The attributes that predict failure** (Backblaze's large-population studies and the smartmontools project agree on these five as the strongest correlates):

| ID | Attribute | What a rising raw value means |
|---|---|---|
| 5 | `Reallocated_Sector_Ct` | Sectors remapped to spare pool — media is physically failing. |
| 187 | `Reported_Uncorrect` | Errors the ECC could not correct and reported to the host. |
| 188 | `Command_Timeout` | Aborted commands — often cabling/power, sometimes dying drive. |
| 197 | `Current_Pending_Sector` | Unstable sectors awaiting reallocation — **read errors imminent**. |
| 198 | `Offline_Uncorrectable` | Uncorrectable during offline scan — data already unreadable. |

Two more you always watch: `199 UDMA_CRC_Error_Count` (a rising value is almost always a **cable/backplane** problem, not the platter) and `194 Temperature_Celsius`.

### 2.2 Reading the drive

```
$ sudo smartctl -H /dev/sda
smartctl 7.4 2023-08-01 r5530 [x86_64-linux-6.8.0-45-generic] (local build)
Copyright (C) 2002-23, Bruce Allen, Christian Franke, www.smartmontools.org

=== START OF READ SMART DATA SECTION ===
SMART overall-health self-assessment test result: PASSED
```

`PASSED` only means no `Pre-fail` attribute has crossed its threshold **right now**. It is a lagging indicator — a drive with 300 pending sectors and a rising reallocation count will still report `PASSED`. Read the attributes:

```
$ sudo smartctl -A /dev/sda
smartctl 7.4 2023-08-01 r5530 [x86_64-linux-6.8.0-45-generic] (local build)

=== START OF READ SMART DATA SECTION ===
SMART Attributes Data Structure revision number: 16
Vendor Specific SMART Attributes with Thresholds:
ID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE
  1 Raw_Read_Error_Rate     0x000f   118   099   006    Pre-fail  Always       -       182664048
  5 Reallocated_Sector_Ct   0x0033   100   100   010    Pre-fail  Always       -       0
  9 Power_On_Hours          0x0032   071   071   000    Old_age   Always       -       25703
 12 Power_Cycle_Count       0x0032   100   100   020    Old_age   Always       -       94
187 Reported_Uncorrect      0x0032   100   100   000    Old_age   Always       -       0
188 Command_Timeout         0x0032   100   100   000    Old_age   Always       -       0
190 Airflow_Temperature_Cel 0x0022   067   052   045    Old_age   Always       -       33 (Min/Max 24/40)
194 Temperature_Celsius     0x0022   033   048   000    Old_age   Always       -       33 (0 20 0 0 0)
197 Current_Pending_Sector  0x0012   100   100   000    Old_age   Always       -       0
198 Offline_Uncorrectable   0x0010   100   100   000    Old_age   Offline      -       0
199 UDMA_CRC_Error_Count    0x003e   200   200   000    Old_age   Always       -       0
```

A **failing** drive, by contrast, looks like this — note the raw values and the `WHEN_FAILED` marker:

```
  5 Reallocated_Sector_Ct   0x0033   089   089   010    Pre-fail  Always       -       1104
187 Reported_Uncorrect      0x0032   001   001   000    Old_age   Always       -       214
197 Current_Pending_Sector  0x0012   100   100   000    Old_age   Always   In_the_past  48
198 Offline_Uncorrectable   0x0010   100   100   000    Old_age   Offline      -       21
```

1104 reallocated sectors, 214 reported-uncorrectables, 48 sectors that were pending. This drive must be replaced now; on a DRBD/RAID member it should be failed out proactively before it triggers a resync.

### 2.3 Self-tests: types and trade-offs

Attributes are passive counters. **Self-tests actively exercise the media.** You trigger them; the drive runs them in the background; you read the log afterward.

| Test | Command | Duration | Coverage | Impact on I/O |
|---|---|---|---|---|
| **Short** | `smartctl -t short` | ~1–2 min | Electrical + mechanical + small read scan | Negligible |
| **Long / extended** | `smartctl -t long` | Hours (scales with capacity) | Full surface read scan | Runs in background, low priority |
| **Conveyance** | `smartctl -t conveyance` | ~5 min | Damage-in-transit checks | Negligible |
| **Offline (data collection)** | `smartctl -t offline` | Minutes | Refreshes `Offline` attributes (e.g. ID 198) | Negligible |
| **SCT selective** | `smartctl -t select,0-max` | Variable | Test a specific LBA range | Depends on range |

```
$ sudo smartctl -t long /dev/sda
smartctl 7.4 2023-08-01 r5530 [x86_64-linux-6.8.0-45-generic] (local build)

=== START OF OFFLINE IMMEDIATE AND SELF-TEST SECTION ===
Sending command: "Execute SMART Extended self-test routine immediately in off-line mode".
Drive command "Execute SMART Extended self-test routine immediately in off-line mode" successful.
Testing has begun.
Please wait 218 minutes for test to complete.
Test will complete after Sat Aug 12 07:38:11 2026 UTC

Use smartctl -X to abort test.
```

Poll progress (does not block), then read the log:

```
$ sudo smartctl -c /dev/sda | grep -A2 'Self-test execution'
Self-test execution status:      ( 249) Self-test routine in progress...
                                        90% of test remaining.

$ sudo smartctl -l selftest /dev/sda
=== START OF READ SMART DATA SECTION ===
SMART Self-test log structure revision number 1
Num  Test_Description    Status                  Remaining  LifeTime(hours)  LBA_of_first_error
# 1  Extended offline    Completed: read failure       10%     25698         1743826512
# 2  Short offline       Completed without error       00%     25690         -
# 3  Extended offline    Completed without error       00%     25012         -
```

`Completed: read failure` with an `LBA_of_first_error` is the unambiguous verdict: this drive has an unreadable sector on the platter. On a RAID/DRBD member, force the array to rewrite that LBA (a resync or `hdparm --write-sector`) or replace the drive.

### 2.4 NVMe devices

NVMe uses a different health-log structure. `smartctl` translates it; the native `nvme-cli` gives the raw log page 0x02:

```
$ sudo smartctl -a /dev/nvme0
=== START OF SMART DATA SECTION ===
SMART overall-health self-assessment test result: PASSED

SMART/Health Information (NVMe Log 0x02)
Critical Warning:                   0x00
Temperature:                        41 Celsius
Available Spare:                    100%
Available Spare Threshold:          10%
Percentage Used:                    7%
Data Units Written:                 84,120,551 [43.0 TB]
Media and Data Integrity Errors:    0
Error Information Log Entries:      12
Warning  Comp. Temperature Time:    0
Critical Comp. Temperature Time:    0
```

The two NVMe fields that matter for capacity planning and fencing decisions: **`Percentage Used`** (the drive's own estimate of endurance consumed — a wear-out predictor absent from ATA) and **`Available Spare`** vs its threshold (once spare drops below the threshold, `Critical Warning` bit 0 sets and the drive is in end-of-life). NVMe self-tests: `nvme device-self-test /dev/nvme0 -s 1` (short) / `-s 2` (extended), read with `nvme self-test-log`.

### 2.5 Continuous monitoring with `smartd`

Interactive `smartctl` is for diagnosis. Production monitoring is `smartd` (from the same `smartmontools` package). It polls on a schedule, runs self-tests automatically, and emails on failure. This is the complete, syntactically valid `/etc/smartd.conf` you would ship on a cluster node:

```conf
# /etc/smartd.conf — production cluster node
#
# Directive reference:
#   -a            monitor all attributes (equivalent to -H -f -t -l error -l selftest -C 197 -U 198)
#   -H            check SMART health status (PASS/FAIL)
#   -f            report failures of "Usage" (Old_age) attributes
#   -C ID         report if Current_Pending_Sector (197) raw != 0
#   -U ID         report if Offline_Uncorrectable (198) raw != 0
#   -l error      monitor ATA error log for new errors
#   -l selftest   monitor self-test log for new failures
#   -s REGEX      self-test schedule: T/MM/DD/DAY-OF-WEEK/HH  (T = L,S,C,O)
#   -W D,I,C      temperature: report on D-degree change; warn at I; critical at C
#   -m ADDR       email destination for warnings
#   -M exec PATH  run a custom handler instead of / in addition to mail
#   -n STANDBY    don't spin up a sleeping disk just to poll it
#   -o on/-S on   enable automatic offline data collection / attribute autosave

# Global defaults applied to every DEVICESCAN device:
#   short self-test every day at 02:00, long self-test every Saturday at 03:00
DEFAULT -a -o on -S on -n standby,q -W 4,45,55 -m root@localhost -M exec /usr/local/sbin/smartd-notify.sh

# Auto-detect all ATA/SCSI/NVMe devices and apply the DEFAULT directives above:
DEVICESCAN -s (S/../.././02|L/../../6/03)

# --- Or, pin devices explicitly (preferred on nodes where /dev/sdX can renumber) ---
# /dev/disk/by-id/ata-Samsung_SSD_870_EVO_2TB_S6PNNS0T  -a -s (S/../.././02|L/../../6/03) -W 4,50,60 -m sre-oncall@example.com
# /dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S7D..... -a -s (L/../../7/04) -W 4,50,60 -m sre-oncall@example.com

# Devices behind a MegaRAID controller (LSI/Broadcom): iterate the backplane slots
# /dev/bus/0 -d megaraid,0 -a -s (S/../.././02|L/../../6/03) -m sre-oncall@example.com
# /dev/bus/0 -d megaraid,1 -a -s (S/../.././02|L/../../6/03) -m sre-oncall@example.com
```

**Decoding the `-s` schedule regex** `(S/../.././02|L/../../6/03)`: fields are `Type/Month/DayOfMonth/DayOfWeek/Hour`. `S/../.././02` = **S**hort test, any month, any day-of-month, any day-of-week, at hour **02**. `L/../../6/03` = **L**ong test, day-of-week **6** (Saturday), at **03**. Enable and validate:

```
$ sudo systemctl enable --now smartd
$ sudo smartd -q onecheck        # parse config + run one check cycle, then exit
smartd 7.4 2023-08-01 r5530 [x86_64-linux-6.8.0-45-generic] (local build)
Opened configuration file /etc/smartd.conf
Configuration file /etc/smartd.conf parsed.
Device: /dev/sda, type changed from 'scsi' to 'sat'
Device: /dev/sda [SAT], opened
Device: /dev/sda [SAT], Samsung SSD 870 EVO 2TB, S/N:S6PNNS0T, WWN:5-002538-f31a1b2c3, FW:SVT02B6Q, 2.00 TB
Device: /dev/sda [SAT], is SMART capable. Adding to "monitor" list.
Monitoring 1 ATA/SATA, 0 SCSI/SAS and 0 NVMe/SMART devices
```

Send a test alert end-to-end (`-M test` fires the mail/exec path immediately on startup so you prove the notification chain before a real failure): add `-M test` to a device line and restart, or run `smartctl -t short` and watch the handler fire on completion.

---

## 3. Pillar 2 — The hardware watchdog: deterministic self-fencing

### 3.1 The mechanism

A watchdog is a countdown timer. Software opens `/dev/watchdog` (char device, major 10 minor 130), which **arms** the timer. From that moment the software must "pet"/"kick" the watchdog (write any byte, or issue the `WDIOC_KEEPALIVE` ioctl) before the timer expires. If it fails to — because the kernel hung, a livelock starved the daemon, or the process died — the timer reaches zero and the device **hard-resets the machine**. There is no clean shutdown, no fsync; that is the entire point: a hung node must reset *without needing the hung software to cooperate*.

Closing `/dev/watchdog` normally **disarms** the timer — unless the "magic close" is required. Writing the byte `V` before closing signals a clean, intentional disarm. The `nowayout` behaviour (kernel config / module param) makes the watchdog un-disarmable once opened: even closing the device keeps the timer running. **For fencing you want `nowayout` semantics** — a crashing daemon that closes its fd must not silently disarm the safety net.

### 3.2 Hardware vs software vs the layers above

| Layer | Device / mechanism | Survives kernel panic? | Survives a dead OS entirely? | Use case |
|---|---|---|---|---|
| **Hardware watchdog** | `iTCO_wdt`, `sp5100_tco`, `hpwdt`, `ipmi_watchdog` | **Yes** (independent silicon / BMC) | **Yes** | Production fencing substrate |
| **softdog** | kernel software timer | Partially (panic can freeze the timer's own context) | No | Dev/VM fallback only |
| **systemd watchdog** | PID 1 opens `/dev/watchdog`, pets at ½ interval | Yes (uses HW device) | Yes | Baseline node self-reset |
| **`watchdog` daemon** | userspace, opens `/dev/watchdog`, runs health checks | Yes (uses HW device) | Yes | Health-condition-driven reset |
| **SBD** | watchdog + shared-disk poison pill | Yes | Yes | Pacemaker STONITH-of-last-resort |

**softdog caveat that shows up in the exam and in reality:** because softdog is just a kernel timer, a hard kernel lockup that stops the timer interrupt path can prevent it firing. A real hardware watchdog (iTCO on Intel PCH, sp5100 on AMD, or the BMC's IPMI watchdog) is independent silicon and fires regardless. Prefer hardware; use softdog only when no hardware watchdog is exposed (many VMs).

Identify what you have:

```
$ ls -l /dev/watchdog*
crw------- 1 root root 10, 130 Aug 12 03:11 /dev/watchdog
crw------- 1 root root 244,  0 Aug 12 03:11 /dev/watchdog0

$ sudo wdctl /dev/watchdog0
Device:        /dev/watchdog0
Identity:      iTCO_wdt [version 0]
Timeout:       30 seconds
Pre-timeout:    0 seconds
Timeleft:      28 seconds
FLAG           DESCRIPTION               STATUS BOOT-STATUS
KEEPALIVEPING  Keep alive ping reply          1           0
MAGICCLOSE     Supports magic close char      0           0
SETTIMEOUT     Set timeout (in seconds)       0           0

$ dmesg | grep -i -E 'watchdog|wdt'
[    3.882110] iTCO_wdt iTCO_wdt.1.auto: Found a Intel PCH TCO device (Version=6, TCOBASE=0x0400)
[    3.882471] iTCO_wdt iTCO_wdt.1.auto: initialized. heartbeat=30 sec (nowayout=0)
```

If no hardware device exists, load softdog explicitly:

```
$ sudo modprobe softdog soft_margin=60 nowayout=1
$ dmesg | tail -2
[  512.774193] softdog: initialized. soft_noboot=0 soft_margin=60 sec soft_panic=0 (nowayout=1)
[  512.774196] softdog: soft_reboot_cmd=<not set> soft_active_on_boot=0
```

### 3.3 Option A — the systemd watchdog

The simplest production baseline: let PID 1 own the watchdog. systemd opens `/dev/watchdog`, arms it at `RuntimeWatchdogSec`, and pets it at **half** that interval. Configure in `/etc/systemd/system.conf` (or a drop-in `/etc/systemd/system.conf.d/watchdog.conf`):

```ini
# /etc/systemd/system.conf.d/10-watchdog.conf
[Manager]
# Arm the hardware watchdog with a 30 s timeout; PID 1 pets it every 15 s.
# If systemd itself hangs, the board resets the node after 30 s.
RuntimeWatchdogSec=30

# On reboot/shutdown, re-arm the watchdog with this timeout so that a hang
# DURING shutdown (a stuck unmount, a wedged driver) still forces a reset.
# (Named ShutdownWatchdogSec before systemd v243; RebootWatchdogSec since.)
RebootWatchdogSec=10min

# Optionally pick a specific device when several exist:
WatchdogDevice=/dev/watchdog0

# Pre-timeout: fire a governor action (e.g. dump) before the hard reset.
RuntimeWatchdogPreSec=0
RuntimeWatchdogPreGovernor=none
```

Apply and verify (a change to `RuntimeWatchdogSec` takes effect on `daemon-reexec`, not a plain reload):

```
$ sudo systemctl daemon-reexec
$ systemctl show --property=RuntimeWatchdogUSec --property=RebootWatchdogUSec
RuntimeWatchdogUSec=30s
RebootWatchdogUSec=10min

$ journalctl -b -u init.scope | grep -i watchdog
Aug 12 03:11:04 node1 systemd[1]: Watchdog running with a timeout of 30s.
```

**Important conflict:** only one process may hold `/dev/watchdog`. If systemd holds it, the standalone `watchdog` daemon and SBD cannot. On a Pacemaker node you almost always want **SBD** to own the watchdog (§3.5), so you leave `RuntimeWatchdogSec=0` there. On a standalone node, the systemd watchdog is the right, zero-extra-daemon choice.

### 3.4 Option B — the `watchdog` daemon (health-condition-driven)

systemd's watchdog only proves *systemd is scheduling*. The standalone `watchdog` daemon (package `watchdog`) additionally **stops petting the timer when a health condition fails** — high load, a memory exhaustion, an unresponsive process, a stale heartbeat file, an unpingable gateway, an overheating chassis, or a failing custom test binary. When it stops petting, the hardware resets the node. `wd_keepalive` is the stripped-down variant that only pings (used during shutdown so the timer stays armed while the full daemon is being stopped).

Complete `/etc/watchdog.conf`:

```conf
# /etc/watchdog.conf — health-driven hardware watchdog
# The daemon pings /dev/watchdog every `interval` seconds AS LONG AS every
# enabled test passes. Any failing test stops the ping -> board resets node.

watchdog-device = /dev/watchdog0
watchdog-timeout = 60          # board's hard-reset timeout (>= 2*interval)
interval        = 10           # how often the daemon runs tests + pings
logtick         = 6            # log every 6th tick to avoid log spam
realtime        = yes          # mlockall() so the daemon can't be swapped out
priority        = 1

# --- System resource guards ---
max-load-1  = 24               # reset if 1-min load avg exceeds this
max-load-5  = 18
max-load-15 = 12
min-memory  = 1                # reset if free pages (in pages) drop below this
allocatable-memory = 1

# --- Thermal guard (uses hwmon/ACPI thermal zone) ---
temperature-sensor = /sys/class/hwmon/hwmon0/temp1_input
max-temperature = 90           # in the unit the sensor reports (here: milli-°C? see note)

# --- Liveness of a critical file (e.g. app heartbeat updated by cron/app) ---
file = /run/myapp/heartbeat
change = 300                   # reset if that file is not modified within 300 s

# --- Network reachability of the default gateway / a peer ---
ping = 192.168.10.1
ping-count = 3

# --- PID liveness: reset if this process dies ---
pidfile = /run/corosync.pid

# --- Custom test/repair binaries in these dirs (exit non-zero = failure) ---
test-directory = /etc/watchdog.d
test-timeout = 30
repair-binary = /usr/sbin/repair.sh
repair-timeout = 60

# On a clean daemon stop, DISARM the watchdog (write magic 'V'). Set to 'no'
# to keep nowayout semantics even across a daemon restart.
watchdog-refresh-use-settimeout = yes
```

Enable and confirm it grabbed the device:

```
$ sudo systemctl enable --now watchdog
$ journalctl -u watchdog -b --no-pager | tail
Aug 12 03:20:01 node1 watchdog[2411]: watchdog now set to 60 seconds
Aug 12 03:20:01 node1 watchdog[2411]: hardware watchdog identity: iTCO_wdt
Aug 12 03:20:01 node1 watchdog[2411]: interface: eth0 monitored via ping 192.168.10.1
Aug 12 03:20:01 node1 watchdog[2411]: file /run/myapp/heartbeat: changed every 300 seconds
Aug 12 03:20:01 node1 watchdog[2411]: currently monitoring load average, temperature, ...
```

### 3.5 Option C — SBD: the watchdog as a Pacemaker fencing device

In a Corosync/Pacemaker cluster (Topic 361), SBD ties the watchdog to cluster state. Each node runs `sbd`, which (a) writes a heartbeat to a slot on one or more **shared block devices** and reads for "poison pill" messages, and (b) **feeds the hardware watchdog**. If a node loses quorum, is told to self-fence via the shared disk, or its `sbd` daemon can no longer confirm it should live, `sbd` **stops petting the watchdog** and the board resets the node in `watchdog-timeout` seconds. This is fencing that needs *no* reachable BMC and *no* corosync — the reset is enforced by silicon.

`/etc/sysconfig/sbd`:

```sh
# /etc/sysconfig/sbd
# Shared block device(s) holding the SBD slots (up to 3 for redundancy).
# Use stable /dev/disk/by-id paths, NOT /dev/sdX.
SBD_DEVICE="/dev/disk/by-id/wwn-0x6001405abcdef01234567890abcdef01"

# The watchdog device SBD must feed. SBD REQUIRES a watchdog to be safe.
SBD_WATCHDOG_DEV="/dev/watchdog0"

# Watchdog timeout SBD asks the kernel to set (must be < msgwait; see below).
SBD_WATCHDOG_TIMEOUT="5"

# Behaviour when SBD fails to start: 'always' (only reboot on config error) or
# 'clean' (reboot only after a clean shutdown was requested). Keep default.
SBD_STARTMODE="always"

# Diskless SBD: leave SBD_DEVICE empty to fence purely on quorum loss +
# watchdog (no shared disk). Requires a real hardware watchdog on every node.
SBD_PACEMAKER="yes"
SBD_DELAY_START="no"
SBD_TIMEOUT_ACTION="flush,reboot"
```

Create the slot metadata on the shared device (watchdog/msgwait timers live in the header) and inspect it:

```
$ sudo sbd -d /dev/disk/by-id/wwn-0x6001405abc...  -1 15 -4 30 create
Initializing device /dev/disk/by-id/wwn-0x6001405abc...
Creating version 2.1 header on device 3 (uuid: 7f0c...e2)
Initializing 255 slots on device 3
Device /dev/disk/by-id/wwn-0x6001405abc... is initialized.

$ sudo sbd -d /dev/disk/by-id/wwn-0x6001405abc... dump
==Dumping header on disk /dev/disk/by-id/wwn-0x6001405abc...
Header version     : 2.1
Number of slots    : 255
Sector size        : 512
Timeout (watchdog)  : 15
Timeout (allocate)  : 2
Timeout (loop)      : 1
Timeout (msgwait)   : 30
==Header on disk /dev/disk/by-id/wwn-0x6001405abc... is dumped
```

Register SBD as the Pacemaker fence device (see also `fence_ipmilan` in §4.5 — production clusters run **both**, IPMI as primary and SBD as the last-resort backstop via a `fencing-topology`):

```
$ sudo pcs stonith create fence-sbd fence_sbd \
        devices=/dev/disk/by-id/wwn-0x6001405abc... \
        pcmk_delay_max=10 \
        meta provides=unfencing

$ sudo pcs property set stonith-watchdog-timeout=10   # >= 2 * SBD_WATCHDOG_TIMEOUT
$ sudo pcs stonith status
  * fence-sbd    (stonith:fence_sbd):     Started node1
```

### 3.6 Proving the watchdog actually fires

Never trust an unarmed safety net. The canonical destructive test — **on a lab node only** — forces a kernel panic and confirms the board resets within the timeout:

```
# Confirm what SHOULD happen, then trigger it:
$ sudo wdctl /dev/watchdog0 | grep Timeout
Timeout:       30 seconds

# Non-destructive first: verify systemd's petting keeps Timeleft topped up
$ for i in 1 2 3; do sudo wdctl /dev/watchdog0 | grep Timeleft; sleep 5; done
Timeleft:      27 seconds
Timeleft:      29 seconds
Timeleft:      28 seconds          # <- being reset ~every 15 s: petting works

# Destructive: hang the kernel. If the watchdog is real, the node hard-resets
# ~30 s later. If it does NOT reset, your fencing is a lie.
$ echo 1 | sudo tee /proc/sys/kernel/sysrq
$ echo c | sudo tee /proc/sysrq-trigger      # forces a kernel panic
```

After the machine comes back, confirm the reset was watchdog-sourced. Many watchdog drivers set a `BOOT-STATUS` bit, and the BMC records it in the SEL:

```
$ sudo wdctl /dev/watchdog0
...
FLAG           DESCRIPTION               STATUS BOOT-STATUS
CARDRESET      Card previously reset          0           1   # <- last boot was a WDT reset

$ sudo ipmitool sel elist | grep -i watchdog
  4 | 08/12/2026 | 03:41:22 UTC | Watchdog2 #0x71 | Hard reset | Asserted
```

---

## 4. Pillar 3 — IPMI / BMC: out-of-band eyes and hands

### 4.1 Where the BMC sits

The Baseboard Management Controller is a small independent processor on the motherboard with its own NIC (or a shared/sideband port), its own power domain, and its own firmware. It runs whether the host is powered on, off, or hung. IPMI is the protocol to talk to it. Two access planes:

| Access | ipmitool interface | Transport | Works when host OS is dead? | Security note |
|---|---|---|---|---|
| **In-band** | `-I open` (default) | `/dev/ipmi0` via `ipmi_si`+`ipmi_devintf` kernel modules | No (needs a running host kernel) | Local root only |
| **Out-of-band** | `-I lanplus` | RMCP+ over **UDP 623** to BMC IP | **Yes** | Encrypted (IPMI 2.0); isolate on a mgmt VLAN |

Load the in-band modules:

```
$ sudo modprobe ipmi_si ipmi_devintf
$ ls -l /dev/ipmi0
crw------- 1 root root 240, 0 Aug 12 03:11 /dev/ipmi0
$ sudo ipmitool mc info
Device ID                 : 32
Device Revision           : 1
Firmware Revision         : 4.71
IPMI Version              : 2.0
Manufacturer ID           : 674
Manufacturer Name         : Dell Inc.
Product Name              : PowerEdge R650 (iDRAC9)
```

### 4.2 Sensors and the SDR (the monitoring plane)

```
$ sudo ipmitool sensor list
Inlet Temp       | 22.000     | degrees C  | ok    | -7.000  | 3.000   | 42.000  | 47.000
Exhaust Temp     | 35.000     | degrees C  | ok    | 3.000   | 8.000   | 70.000  | 75.000
CPU1 Temp        | 48.000     | degrees C  | ok    | na      | na      | 91.000  | 95.000
Fan1A            | 8280.000   | RPM        | ok    | 840.000 | 1080.00 | na      | na
Fan2A            | 0.000      | RPM        | nc    | 840.000 | 1080.00 | na      | na
PS1 Status       | 0x1        | discrete   | 0x0100| na      | na      | na      | na
PS2 Status       | 0x1        | discrete   | 0x0300| na      | na      | na      | na
Pwr Consumption  | 168.000    | Watts      | ok    | na      | na      | 588.00  | 675.00
```

Reading this like an SRE: `Fan2A` at **0 RPM / state `nc` (non-critical)** and `PS2 Status : 0x0300` (a failure bit vs PS1's healthy `0x0100`) mean this chassis has a dead fan and a failed second PSU — it is running on redundancy that is now exhausted. None of this is visible from inside the OS. The compact form is `ipmitool sdr` (reads the Sensor Data Repository); `ipmitool sdr type Temperature` / `type Fan` filter by type.

### 4.3 The System Event Log (the forensic plane)

The SEL is the BMC's persistent, host-independent event log — the first place to look after any unexplained reboot:

```
$ sudo ipmitool sel elist
  1 | 07/29/2026 | 11:02:14 UTC | Power Supply PS2 Status | Failure detected | Asserted
  2 | 07/29/2026 | 11:02:15 UTC | Power Supply PS2 Status | Predictive failure | Asserted
  3 | 08/02/2026 | 04:18:51 UTC | Fan Fan2A | Lower Non-critical going low | Asserted
  4 | 08/12/2026 | 03:41:22 UTC | Watchdog2 | Hard reset | Asserted
  5 | 08/12/2026 | 03:41:55 UTC | System ACPI Power State | S0/G0: working | Asserted

$ sudo ipmitool sel info
SEL Information
Version          : 1.5 (v1.5, v2 compliant)
Entries          : 5
Free Space       : 14848 bytes
Percent Used     : 1%
Last Add Time    : 08/12/2026 03:41:55 UTC
Overflow         : false
```

Event 4 confirms the §3.6 test: the reboot was a **watchdog hard reset**, correlating exactly with the OS-side `wdctl` `CARDRESET` boot-status bit. Clear the SEL after triage (`ipmitool sel clear`) so the next incident is unambiguous.

### 4.4 Chassis power control and Serial-over-LAN (the "hands")

```
$ sudo ipmitool chassis status
System Power         : on
Power Restore Policy : always-on
Last Power Event     : command
Cooling/fan fault    : true
Front-panel lockout  : inactive

# Remote, over the mgmt network — power a wedged node without walking to the DC:
$ ipmitool -I lanplus -H 10.20.0.51 -U fence -P 'S3cr3t!' chassis power status
Chassis Power is on
$ ipmitool -I lanplus -H 10.20.0.51 -U fence -P 'S3cr3t!' chassis power cycle
Chassis Power Control: Cycle

# Serial-over-LAN: a full text console when SSH is dead (watch kernel panics live)
$ ipmitool -I lanplus -H 10.20.0.51 -U fence -P 'S3cr3t!' sol activate
[SOL Session operational.  Use ~? for help]
node1 login:
```

`chassis power` verbs: `on`, `off` (hard, immediate), `cycle`, `reset`, `soft` (ACPI graceful). **`reset`/`cycle` is exactly what a STONITH agent issues** — which is why the BMC credentials and the fence device below matter so much.

### 4.5 Configuring the BMC LAN + a fence-only user, then wiring `fence_ipmilan`

Provision the out-of-band channel and a least-privilege user dedicated to fencing:

```
$ sudo ipmitool lan print 1
Set in Progress         : Set Complete
IP Address Source       : Static Address
IP Address              : 10.20.0.51
Subnet Mask             : 255.255.255.0
Default Gateway IP      : 10.20.0.1
802.1q VLAN ID          : 40
Cipher Suite Priv Max   : XXXXXXXXXXXXaXX   # 'a' = ADMIN at suite 3 (HMAC-SHA1/AES)

# Set a static mgmt IP on channel 1:
$ sudo ipmitool lan set 1 ipsrc static
$ sudo ipmitool lan set 1 ipaddr 10.20.0.51
$ sudo ipmitool lan set 1 netmask 255.255.255.0
$ sudo ipmitool lan set 1 defgw ipaddr 10.20.0.1

# Create a dedicated 'fence' user (slot 4), give it ADMIN on channel 1:
$ sudo ipmitool user set name 4 fence
$ sudo ipmitool user set password 4 'S3cr3t!'
$ sudo ipmitool user priv 4 4 1          # user 4, privilege 4 (ADMIN), channel 1
$ sudo ipmitool user enable 4
$ sudo ipmitool channel setaccess 1 4 callin=on ipmi=on link=on privilege=4
$ sudo ipmitool user list 1
ID  Name        Callin  Link Auth  IPMI Msg   Channel Priv Limit
1   (Empty)     true    false      false      NO ACCESS
4   fence       true    true       true       ADMINISTRATOR

# Validate out-of-band reachability from ANOTHER host before trusting it:
$ ipmitool -I lanplus -H 10.20.0.51 -U fence -P 'S3cr3t!' -L ADMINISTRATOR mc info
```

Register it in Pacemaker as the primary STONITH device, with SBD as the backstop tier:

```
$ sudo pcs stonith create fence-node1 fence_ipmilan \
        pcmk_host_list=node1 \
        ip=10.20.0.51 \
        username=fence \
        password='S3cr3t!' \
        lanplus=1 \
        privlvl=ADMINISTRATOR \
        power_wait=4 \
        pcmk_reboot_action=reboot \
        op monitor interval=60s

# Two-tier fencing: try IPMI first; if it fails/unreachable, fall through to SBD.
$ sudo pcs stonith level add 1 node1 fence-node1
$ sudo pcs stonith level add 2 node1 fence-sbd
$ sudo pcs stonith status
  * fence-node1  (stonith:fence_ipmilan):  Started node2
  * fence-sbd    (stonith:fence_sbd):      Started node1
```

### 4.6 `ipmievd` — forwarding SEL events to syslog

`ipmievd` turns the passive SEL into a live stream: it watches for new SEL entries (via the OpenIPMI in-band interface or by polling) and writes them to syslog, where your log pipeline (rsyslog → Loki/Elastic → alerting) picks them up. This closes the loop so a failed PSU pages someone instead of sitting silently in the BMC.

```
$ sudo systemctl enable --now ipmievd
$ sudo systemctl status ipmievd --no-pager
● ipmievd.service - IPMI event daemon
     Active: active (running) since Wed 2026-08-12 03:55:10 UTC; 4s ago
   Main PID: 3120 (ipmievd)

$ logger -t test "trigger"; sudo journalctl -t ipmievd -b --no-pager | tail -3
Aug 12 03:55:10 node1 ipmievd: ipmievd: startup
Aug 12 03:55:10 node1 ipmievd: Waiting for events...
Aug 12 04:12:03 node1 ipmievd: Power Supply PS2 Status Failure detected - Asserted
```

### 4.7 A note on Redfish (successor context)

The DMTF standardised **Redfish** (RESTful/JSON over HTTPS) as IPMI's successor; IPMI 2.0 is frozen (no new spec versions) and several vendors are deprecating raw IPMI-over-LAN by default in favour of Redfish. For fencing there is now `fence_redfish`. IPMI remains the LPIC-3 examinable and still-ubiquitous mechanism, but in greenfield designs prefer Redfish for the management plane where the BMC supports it. `fence_ipmilan` and `fence_redfish` can coexist in the same `fencing-topology`.

---

## 5. Bonus: disk parameters with `hdparm` / `sdparm`

The objective touches low-level disk parameter tuning that directly affects data durability under power loss — critical on cluster nodes without battery-backed cache. The single most important is the **volatile write cache**: an SSD/HDD that acknowledges writes from DRAM before persisting them will silently lose acknowledged writes on power loss, corrupting a DRBD/journal.

```
# ATA/SATA via hdparm:
$ sudo hdparm -W /dev/sda            # query write-cache state
/dev/sda:
 write-caching =  1 (on)
$ sudo hdparm -W0 /dev/sda           # DISABLE volatile write cache (durability > throughput)
/dev/sda:
 setting drive write-caching to 0 (off)
 write-caching =  0 (off)

$ sudo hdparm -I /dev/sda | grep -iE 'Model|Write cache|Security'
        Model Number:       Samsung SSD 870 EVO 2TB
           *    Write cache
           *    Security Mode feature set

# SCSI/SAS/NVMe via sdparm (Caching mode page: WCE = Write Cache Enable):
$ sudo sdparm --get=WCE /dev/sdb
    /dev/sdb: SEAGATE   ST4000NM0025      N003
WCE           1  [cha: y, def:  1, sav:  1]
$ sudo sdparm --clear=WCE --save /dev/sdb   # disable + persist across power cycles
```

Persist `hdparm` settings across reboots via `/etc/hdparm.conf`:

```conf
# /etc/hdparm.conf
/dev/disk/by-id/ata-Samsung_SSD_870_EVO_2TB_S6PNNS0T {
    write_cache = off
    apm = 254        # disable aggressive power management / head-parking on cluster disks
}
```

---

## 6. End-to-end verification & failure-diagnosis playbook

| Symptom | First command | What confirms / refutes | Fix / next step |
|---|---|---|---|
| Node rebooted, no OS log explaining it | `ipmitool sel elist \| tail` | `Watchdog2 ... Hard reset` = watchdog fired; power events = PSU/AC loss | Correlate with `wdctl` boot-status; find *why* the OS stopped petting (load, panic) |
| Suspect a dying disk | `smartctl -A /dev/sdX` then `-t long` | Raw `5/187/197/198` rising, or `Completed: read failure` | Fail the disk out of RAID/DRBD before it forces a resync |
| Watchdog "configured" but you don't trust it | `wdctl /dev/watchdog0` + panic test (§3.6) | `Timeleft` counting down + node resets in ~timeout | If it never resets: softdog on a hung kernel, or nothing owns the device |
| `/dev/watchdog` busy / SBD won't start | `sudo fuser -v /dev/watchdog*` | systemd (PID 1) or `watchdog`d already holds it | Set `RuntimeWatchdogSec=0`; let SBD own it |
| Chassis alarm, OS looks fine | `ipmitool sensor list \| grep -v ok` | Fan at 0 RPM / PSU status bits / temp over threshold | Dispatch hands-on; the OS never sees this |
| Can't fence a node (STONITH failing) | `ipmitool -I lanplus -H <bmc> ... mc info` | Times out = BMC net/creds broken | Fix mgmt VLAN/creds; rely on SBD tier 2 meanwhile |
| smartd emails never arrive | `smartd -q onecheck` + device line `-M test` | Parse errors, or handler never runs | Fix MTA / `-M exec` handler path |

Two disciplines an SRE enforces here: **(1)** the watchdog and every fence device is *tested destructively at least once* before the node carries production — an untested fence path is worse than none because the cluster trusts it; **(2)** SMART self-tests and SEL forwarding (`ipmievd`) run continuously and *page*, because every one of these subsystems fails silently by design — their entire value is turning an invisible single-node fault into an alert *before* it becomes a cluster incident.

---

## 7. References

- LPI — Exam 306-300 Objectives (Topic 364.1): https://www.lpi.org/our-certifications/exam-306-objectives/
- smartmontools project documentation (`smartctl`, `smartd`, `smartd.conf`): https://www.smartmontools.org/
- `smartd.conf(5)` man page: https://linux.die.net/man/5/smartd.conf
- Linux kernel — Watchdog Support (`Documentation/watchdog/`): https://www.kernel.org/doc/html/latest/watchdog/index.html
- Linux kernel — Watchdog API (`watchdog-api`, `/dev/watchdog` ioctls): https://www.kernel.org/doc/html/latest/watchdog/watchdog-api.html
- systemd — `systemd-system.conf(5)` (`RuntimeWatchdogSec`, `RebootWatchdogSec`): https://www.freedesktop.org/software/systemd/man/latest/systemd-system.conf.html
- The `watchdog` daemon — `watchdog.conf(5)` / `watchdog(8)`: https://man7.org/linux/man-pages/man5/watchdog.conf.5.html
- ClusterLabs — SBD fencing (`sbd(8)`, storage-based death): https://github.com/ClusterLabs/sbd/blob/master/man/sbd.8.pod
- ClusterLabs — Pacemaker fencing / STONITH (`fence_ipmilan`, `fence_sbd`): https://clusterlabs.org/pacemaker/doc/
- `ipmitool` project and man page: https://github.com/ipmitool/ipmitool and https://linux.die.net/man/1/ipmitool
- Intelligent Platform Management Interface (IPMI) 2.0 specification (Intel/DMTF): https://www.intel.com/content/www/us/en/products/docs/servers/ipmi/ipmi-second-gen-interface-spec-v2-rev1-1.html
- DMTF Redfish (IPMI successor) specification: https://www.dmtf.org/standards/redfish
- `hdparm(8)` man page: https://man7.org/linux/man-pages/man8/hdparm.8.html
- `sdparm(8)` project and man page: https://sg.danny.cz/sg/sdparm.html