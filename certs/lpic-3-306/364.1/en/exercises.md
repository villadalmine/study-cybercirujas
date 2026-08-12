# Guided Exercises — 364.1 Hardware and Resource High Availability

> **Exam context.** Objective 364.1 (weight 3.33) sits in *Single Node High Availability*: keeping one server alive by detecting failing hardware *before* it takes the node down, and forcing a clean recovery when the OS itself hangs. You will practice S.M.A.R.T. disk monitoring, thermal/`lm-sensors` telemetry, out-of-band management with IPMI, the kernel and `systemd` watchdogs, and resource observation with the `sysstat` family.
>
> **Lab requirements.** A Linux VM you can safely reboot (Debian/Ubuntu or RHEL-family). Root or `sudo`. Packages: `smartmontools`, `lm-sensors`, `ipmitool`, `watchdog`, `sysstat`, and optionally `monit`. Several steps arm a watchdog that **will hard-reset the machine** — never run those on a host you care about.
>
> **Reference sources**
> - LPI 306 objectives — https://www.lpi.org/our-certifications/exam-306-objectives/
> - smartmontools — https://www.smartmontools.org/ (`man smartctl`, `man smartd.conf`)
> - lm-sensors — https://github.com/lm-sensors/lm-sensors
> - ipmitool — https://github.com/ipmitool/ipmitool (`man ipmitool`)
> - Linux kernel watchdog API — https://www.kernel.org/doc/html/latest/watchdog/watchdog-api.html
> - systemd watchdog — https://www.freedesktop.org/software/systemd/man/systemd.service.html and https://0pointer.de/blog/projects/watchdog.html
> - sysstat — https://github.com/sysstat/sysstat
> - monit — https://mmonit.com/monit/documentation/monit.html

---

## Exercise 1 — Reading S.M.A.R.T. disk health with `smartctl`

The goal is to distinguish a *normalized* value (a 1–253 health score) from a *raw* value (the real physical count), and to identify the attributes that actually predict failure.

1. Install the toolset and confirm the disk supports S.M.A.R.T.:

   ```bash
   sudo apt-get install -y smartmontools     # or: sudo dnf install smartmontools
   sudo smartctl -i /dev/sda
   ```

   ```
   === START OF INFORMATION SECTION ===
   Device Model:     Samsung SSD 870 EVO 500GB
   Serial Number:    S5Y2NG0R123456A
   Firmware Version: SVT02B6Q
   User Capacity:    500,107,862,016 bytes [500 GB]
   Rotation Rate:    Solid State Device
   SMART support is: Available - device has SMART capability.
   SMART support is: Enabled
   ```

2. If S.M.A.R.T. is *Available* but *Disabled*, turn it on so the firmware keeps counters:

   ```bash
   sudo smartctl -s on /dev/sda
   ```

3. Ask the drive for its own overall verdict (this is the firmware's threshold logic, not yours):

   ```bash
   sudo smartctl -H /dev/sda
   ```

   ```
   === START OF READ SMART DATA SECTION ===
   SMART overall-health self-assessment test result: PASSED
   ```

4. Dump the full attribute table and read the columns:

   ```bash
   sudo smartctl -A /dev/sda
   ```

   ```
   ID# ATTRIBUTE_NAME          FLAGS    VALUE WORST THRESH FAIL RAW_VALUE
     5 Reallocated_Sector_Ct   PO--CK   100   100   010    -    0
     9 Power_On_Hours          -O--CK   095   095   000    -    21833
   177 Wear_Leveling_Count     PO--C-   094   094   000    -    213
   187 Reported_Uncorrect      -O--CK   100   100   000    -    0
   194 Temperature_Celsius     -O---K   067   050   000    -    33
   197 Current_Pending_Sector  -O--C-   100   100   000    -    0
   198 Offline_Uncorrectable   ----CK   100   100   000    -    0
   199 UDMA_CRC_Error_Count    -OSRCK   100   100   000    -    0
   ```

5. On an NVMe device the health page looks different — read it too:

   ```bash
   sudo smartctl -a /dev/nvme0 | sed -n '/SMART.*Health Information/,/Temperature Sensor/p'
   ```

   ```
   SMART/Health Information (NVMe Log 0x02)
   Critical Warning:                   0x00
   Temperature:                        41 Celsius
   Available Spare:                    100%
   Available Spare Threshold:          10%
   Percentage Used:                    3%
   Media and Data Integrity Errors:    0
   ```

**Comprehension check**

- **Q1.** In the ATA table, `Reallocated_Sector_Ct` shows `VALUE 100`, `THRESH 010`, `RAW_VALUE 0`. Which of those three numbers is the reallocated-sector count, and how do `VALUE` and `THRESH` decide a failure?
- **Q2.** Attribute 194 shows `VALUE 067` with `RAW_VALUE 33`. Why is the "health score" *lower* even though 33 °C is a perfectly good temperature?
- **Q3.** Which five attributes are the classic pre-failure predictors for a spinning ATA disk, and what does the NVMe equivalent of "the disk is wearing out / running out of spares" look like?

---

## Exercise 2 — Self-tests and unattended monitoring with `smartd`

`smartctl -H` only trusts the firmware's own flag; a proactive HA node runs periodic self-tests and mails you on the first reallocated sector.

1. Launch an on-line **short** self-test and poll for completion:

   ```bash
   sudo smartctl -t short /dev/sda
   # ... wait the estimated time, then:
   sudo smartctl -l selftest /dev/sda
   ```

   ```
   Num  Test_Description  Status                  Remaining  LifeTime(hours)  LBA_of_first_error
   # 1  Short offline     Completed without error       00%          21834             -
   # 2  Extended offline  Completed without error       00%          21789             -
   ```

2. Inspect the drive's error log (populated only when the drive logged an internal error):

   ```bash
   sudo smartctl -l error /dev/sda
   ```

   ```
   SMART Error Log Version: 1
   No Errors Logged
   ```

3. Configure the `smartd` daemon. Edit `/etc/smartd.conf`, comment out any existing `DEVICESCAN`, and add an explicit, fully-monitored line:

   ```conf
   # /etc/smartd.conf
   # -a           : monitor all standard attributes (health, error log, selftest log, usage, temp)
   # -o on        : enable automatic offline data collection
   # -S on        : enable attribute autosave
   # -n standby   : do not spin up a sleeping disk just to poll it
   # -H           : monitor overall SMART health
   # -l error     : monitor the ATA error log
   # -l selftest  : monitor the self-test log
   # -f           : report failures of usage (prefail) attributes
   # -I 194       : ignore raw temperature changes (avoid noise), but...
   # -W 5,45,55   : warn on +5 °C swings, INFO at 45 °C, CRITICAL at 55 °C
   # -s (S/../.././02|L/../../6/03) : short test daily 02:00, long test Saturday 03:00
   # -m root -M exec /usr/share/smartmontools/smartd_warning.sh : how to alert
   /dev/sda -a -o on -S on -n standby -H -l error -l selftest -f \
            -I 194 -W 5,45,55 \
            -s (S/../.././02|L/../../6/03) \
            -m root -M exec /usr/share/smartmontools/smartd_warning.sh
   ```

4. Validate the config in the foreground with debug output before enabling the service:

   ```bash
   sudo smartd -q onecheck -d
   ```

   ```
   Device: /dev/sda, opened
   Device: /dev/sda, is SMART capable. Adding to "monitor" list.
   Monitoring 1 ATA/SATA, 0 SCSI, 0 NVMe devices
   Executed test suite for /dev/sda; next test schedule ...
   ```

5. Enable and start the daemon, then confirm it is watching:

   ```bash
   sudo systemctl enable --now smartd
   systemctl status smartd --no-pager
   journalctl -u smartd -b | tail -n 5
   ```

**Comprehension check**

- **Q4.** In the schedule token `-s (S/../.././02|L/../../6/03)`, what do `S`/`L` mean and what do the five slash-separated fields encode? Decode the whole expression.
- **Q5.** What is the difference between `smartctl -t offline` / `-o on` (offline data collection) and `smartctl -t short` (a self-test)? Why does `-n standby` matter on a node with idle disks?
- **Q6.** `smartd` found a problem at 03:00. Where does the notification physically go, and what is the role of `smartd_warning.sh` versus `-m root`?

---

## Exercise 3 — Thermal and fan telemetry with `lm-sensors`

Overheating is a slow-motion outage. `lm-sensors` exposes the on-board hardware monitor chips (Super I/O, CPU `coretemp`, etc.).

1. Install and run the interactive prober. Accept the safe defaults (answer `YES` to the summary that offers to load the detected modules):

   ```bash
   sudo apt-get install -y lm-sensors
   sudo sensors-detect
   ```

   ```
   Now follows a summary of the probes I have just done.
   Driver `coretemp':
     * Chip `Intel digital thermal sensor' (confidence: 9)
   Driver `nct6775':
     * ISA bus, address 0x290
       Chip `Nuvoton NCT6779D Super IO Sensors' (confidence: 9)
   Do you want to add these lines automatically to /etc/modules? (yes/NO): yes
   ```

2. Make sure the detected modules are loaded now (without a reboot):

   ```bash
   sudo systemctl restart lm-sensors 2>/dev/null || sudo /etc/init.d/kmod start
   sudo modprobe coretemp; sudo modprobe nct6779 2>/dev/null || sudo modprobe nct6775
   ```

3. Read the sensors:

   ```bash
   sensors
   ```

   ```
   coretemp-isa-0000
   Adapter: ISA adapter
   Package id 0:  +38.0°C  (high = +84.0°C, crit = +100.0°C)
   Core 0:        +35.0°C  (high = +84.0°C, crit = +100.0°C)

   nct6779-isa-0290
   Adapter: ISA adapter
   Vcore:         1.02 V   (min =  +0.00 V, max =  +1.74 V)
   fan1:          0 RPM    (min =    0 RPM)
   fan2:        1123 RPM   (min =  300 RPM)
   temp1:       +41.0°C    (high = +80.0°C, hyst = +75.0°C)
   ```

4. Emit machine-readable output (this is what a monitoring agent would scrape):

   ```bash
   sensors -j | head -n 20     # JSON
   sensors -A                  # bare, no adapter lines
   ```

5. Relabel a cryptic chip channel and set your own alarm limits in a drop-in, then re-read:

   ```bash
   sudo tee /etc/sensors.d/local.conf >/dev/null <<'EOF'
   chip "nct6779-isa-0290"
       label temp1 "SystemBoard"
       set temp1_max 70
       label fan2  "CPU_FAN"
       set fan2_min 500
   EOF
   sudo sensors -s      # apply 'set' limits to the chips
   sensors nct6779-isa-0290
   ```

6. *(Optional, real hardware only.)* Calibrate PWM fan control. `pwmconfig` spins each fan up and down to map PWM channels to fans, then writes `/etc/fancontrol`:

   ```bash
   sudo pwmconfig
   sudo systemctl enable --now fancontrol
   ```

**Comprehension check**

- **Q7.** What does `sensors-detect` actually change on the system, and why must those kernel modules be loaded (e.g. via `/etc/modules`) for `sensors` to show anything after a reboot?
- **Q8.** In the `coretemp` output, what is the difference between the `high` and `crit` thresholds, and which one does the CPU act on by itself regardless of your monitoring?
- **Q9.** You added `set temp1_max 70` in a drop-in. Does that change what the hardware does at 70 °C? What is `set` actually for, and what applies it?

---

## Exercise 4 — Out-of-band monitoring and control with IPMI (`ipmitool`)

IPMI talks to the **BMC** (Baseboard Management Controller), which is powered and reachable even when the OS is dead — the backbone of remote HA recovery and, in cluster terms, of **fencing/STONITH**.

1. Load the in-band IPMI drivers and confirm the device node appears:

   ```bash
   sudo modprobe ipmi_si
   sudo modprobe ipmi_devintf
   ls -l /dev/ipmi0
   sudo apt-get install -y ipmitool
   ```

2. Query the BMC itself and the chassis power state:

   ```bash
   sudo ipmitool mc info
   sudo ipmitool chassis status
   ```

   ```
   System Power         : on
   Power Overload       : false
   Last Power Event     :
   Main Power Fault     : false
   ```

3. Read hardware sensors *through the BMC* (independent of `lm-sensors`) and filter by type:

   ```bash
   sudo ipmitool sdr list
   sudo ipmitool sdr type Temperature
   sudo ipmitool sdr type Fan
   ```

   ```
   CPU1 Temp        | 34 degrees C      | ok
   Inlet Temp       | 21 degrees C      | ok
   FAN1             | 4680 RPM          | ok
   PSU1 Status      | 0x01              | ok
   ```

4. Inspect the **System Event Log** — the persistent record of hardware faults (ECC errors, PSU loss, thermal trips):

   ```bash
   sudo ipmitool sel info
   sudo ipmitool sel elist
   ```

   ```
   1 | 08/12/2026 | 02:14:07 | Power Supply PSU2 | Power Supply Failure detected | Asserted
   2 | 08/12/2026 | 02:14:41 | Memory ECC #0x14  | Correctable ECC | Asserted
   ```

5. Configure **IPMI over LAN** so the node can be managed even when unreachable in-band (channel number varies; often 1):

   ```bash
   sudo ipmitool lan print 1
   sudo ipmitool lan set 1 ipsrc static
   sudo ipmitool lan set 1 ipaddr 192.168.50.30
   sudo ipmitool lan set 1 netmask 255.255.255.0
   sudo ipmitool lan set 1 defgw ipaddr 192.168.50.1
   sudo ipmitool lan set 1 access on
   sudo ipmitool user set name 2 hauser
   sudo ipmitool user set password 2
   sudo ipmitool channel setaccess 1 2 callin=on ipmi=on link=on privilege=4
   sudo ipmitool user enable 2
   ```

6. From a *second machine*, query and (carefully) power-cycle the node remotely, and open a **Serial-over-LAN** console:

   ```bash
   ipmitool -I lanplus -H 192.168.50.30 -U hauser -P '******' sensor list
   ipmitool -I lanplus -H 192.168.50.30 -U hauser -P '******' chassis power status
   # Recovery actions — irreversible on a live node:
   ipmitool -I lanplus -H 192.168.50.30 -U hauser -P '******' chassis power cycle
   ipmitool -I lanplus -H 192.168.50.30 -U hauser -P '******' sol activate
   ```

**Comprehension check**

- **Q10.** Why can IPMI read temperatures and power the box on when the OS is completely hung, whereas `lm-sensors` cannot? What component makes that possible?
- **Q11.** Contrast `chassis power off`, `chassis power cycle`, `chassis power reset`, and `chassis power soft`. Which one asks the OS to shut down cleanly, and which is the hard fence used by STONITH?
- **Q12.** What is the practical HA value of `ipmitool sel elist` after an unexplained reboot, and what is the difference between the in-band interface (`-I open`, the default) and `-I lanplus`?

---

## Exercise 5 — Kernel, `watchdog` daemon, and `systemd` watchdogs

A watchdog is a countdown timer the software must keep resetting ("petting"). If the software wedges and stops petting, the timer expires and the hardware resets the machine — turning a silent hang into an automatic reboot.

> ⚠️ Every step here can reboot the VM. Use a disposable VM. `softdog` is a software watchdog safe enough for learning the mechanics.

1. Load a watchdog driver and inspect the resulting device. On a VM, use `softdog`:

   ```bash
   sudo modprobe softdog
   ls -l /dev/watchdog*
   sudo wdctl /dev/watchdog
   ```

   ```
   Device:        /dev/watchdog0
   Identity:      Software Watchdog [version 0]
   Timeout:       60 seconds
   Pre-timeout:   0 seconds
   FLAG           DESCRIPTION               STATUS BOOT-STATUS
   KEEPALIVEPING  Keep alive ping reply          1           0
   MAGICCLOSE     Support for magic close char   0           0
   ```

2. Understand the "magic close" contract. Opening `/dev/watchdog` **arms** it; closing it normally *disarms* it **only** if the character `V` was written first, otherwise the timer keeps running:

   ```bash
   # Arms the timer. If you just Ctrl-C without writing 'V', the machine reboots ~60s later.
   echo -n 'V' | sudo tee /dev/watchdog >/dev/null   # writes magic-close, safe disarm
   ```

3. Install and configure the userspace `watchdog` daemon, which pets the device *and* runs its own health checks (load, memory, network, temperature, file freshness):

   ```conf
   # /etc/watchdog.conf
   watchdog-device = /dev/watchdog
   watchdog-timeout = 60          # hardware timeout to program into the chip
   interval        = 10           # pet the device every 10 s (must be < timeout)

   max-load-1      = 24           # reboot if 1-min load average exceeds 24
   min-memory      = 1            # reboot if free pages fall below this (in pages)
   ping            = 192.168.50.1 # reboot if this gateway stops answering
   interface       = eth0

   temperature-sensor = /sys/class/hwmon/hwmon0/temp1_input
   max-temperature    = 90        # in the unit of the sensor (milli-°C → 90000 if raw)

   file   = /var/log/heartbeat    # a file that must keep changing...
   change = 1800                  # ...at least every 1800 s, else reboot

   repair-binary  = /usr/sbin/repair.sh   # try to fix before rebooting (must exit 0)
   ```

4. Test the daemon logic *without* arming the real hardware, then enable it for real:

   ```bash
   sudo watchdog -c /etc/watchdog.conf -v    # verbose foreground test
   sudo systemctl enable --now watchdog
   ```

5. Learn the role of `wd_keepalive`: it is the *minimal* petting-only daemon that keeps the watchdog fed while the full `watchdog` daemon is stopped (e.g. during service restarts) so the timer never fires by accident:

   ```bash
   systemctl status wd_keepalive --no-pager
   ```

6. Wire the **hardware watchdog into `systemd`** so `systemd` itself (PID 1) is what pets the chip — if the kernel or `systemd` deadlocks, the box resets:

   ```ini
   # /etc/systemd/system.conf   (or a drop-in under /etc/systemd/system.conf.d/)
   [Manager]
   RuntimeWatchdogSec=20      # systemd pets the hw watchdog; hangs → reset after ~20s
   RebootWatchdogSec=10min    # arm watchdog during reboot so a stuck shutdown still resets
   ```

   ```bash
   sudo systemctl daemon-reexec
   systemctl show -p RuntimeWatchdogUSec -p RebootWatchdogUSec
   ```

   > Note: `RuntimeWatchdogSec` requires a **real** `/dev/watchdog` and conflicts with the standalone `watchdog` daemon — only one process may own the device. Do not run both against the same chip.

7. See the **per-service software watchdog**: a service declares `WatchdogSec=` and must call `sd_notify(WATCHDOG=1)`; if it stops notifying, `systemd` restarts *that unit* (not the whole box):

   ```ini
   # /etc/systemd/system/myapp.service  (drop-in)
   [Service]
   WatchdogSec=30
   Restart=on-watchdog
   ```

**Comprehension check**

- **Q13.** Explain the "magic close" (`V`) contract on `/dev/watchdog`. Why can a careless script that opens the device and exits reboot the machine one timeout later?
- **Q14.** Compare the standalone `watchdog` daemon, `RuntimeWatchdogSec` in `systemd`, and a service's `WatchdogSec=`. Which one recovers a hung *kernel*, which recovers a hung *systemd*, and which recovers a single hung *application*?
- **Q15.** What is `wd_keepalive` for, and why is it dangerous to run both the `watchdog` daemon and `systemd`'s `RuntimeWatchdogSec` against the same `/dev/watchdog`?

---

## Exercise 6 — Resource monitoring with `uptime`, `vmstat`, `iostat`, and `sar`

Hardware that is technically healthy can still make the node effectively unavailable through saturation. This is the "resource" half of the objective.

1. Read load average and put it in context with the CPU count:

   ```bash
   uptime
   nproc
   cat /proc/loadavg
   ```

   ```
    14:52:10 up 15 days,  3:11,  2 users,  load average: 7.42, 6.10, 4.88
   4
   7.42 6.10 4.88 3/842 20117
   ```

2. Sample system-wide state every second and read the CPU/IO/memory columns:

   ```bash
   vmstat 1 5
   ```

   ```
   procs -----------memory----------  ---swap-- -----io---- -system-- ------cpu-----
    r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
    9  1  10240 152340  88120 990112    0    4  1200  3400 5100 8900 71  9  4 15  1
   10  0  10240 149880  88120 992440    0    0   980  4100 5300 9200 74 11  2 13  0
   ```

3. Watch per-device I/O with extended stats from `sysstat` (skip the since-boot first sample with `-y`):

   ```bash
   sudo apt-get install -y sysstat
   iostat -xz 1 3
   ```

   ```
   Device   r/s   w/s   rkB/s   wkB/s  r_await w_await aqu-sz  %util
   sda     40.0 320.0  2560.0 12800.0     1.10   18.40   6.20   98.7
   nvme0n1  8.0  15.0   512.0   960.0     0.05    0.10   0.01    3.1
   ```

4. Enable historical collection so you can answer "what happened at 02:00 last night?". Turn on the `sysstat` collector (`sadc` via a systemd timer / cron), then query archives:

   ```bash
   # Debian/Ubuntu: set ENABLED="true" in /etc/default/sysstat
   sudo sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat
   sudo systemctl enable --now sysstat            # RHEL uses the same unit name
   ```

5. Read yesterday's/today's history from the saved `saNN` files:

   ```bash
   sar -u 1 3                 # live CPU (user/system/iowait/steal/idle)
   sar -r                     # memory over the day
   sar -d -p                  # per-disk activity, pretty device names
   sar -n DEV                 # per-interface network throughput
   sar -q                     # run-queue length and load averages
   sar -f /var/log/sysstat/sa12 -u   # CPU history from the 12th of the month
   ```

   ```
   12:00:01  CPU   %user  %nice  %system  %iowait  %steal  %idle
   02:10:01  all   71.20   0.00     9.10    15.30    1.10    3.30
   ```

6. Correlate memory pressure directly from the kernel's PSI (Pressure Stall Information):

   ```bash
   for r in cpu memory io; do echo "== $r =="; cat /proc/pressure/$r; done
   free -h
   ```

**Comprehension check**

- **Q16.** The node has 4 CPUs and a 1-minute load average of `7.42`. Is that overloaded? What extra column in `vmstat`/`sar` tells you whether the pressure is *CPU-bound* versus *I/O-bound*?
- **Q17.** In `vmstat`, what do the `wa` and `st` CPU columns mean, and which one specifically signals that a *virtualized* HA node is being starved by its hypervisor?
- **Q18.** `iostat -x` shows `sda` at `%util 98.7` with `w_await 18.40` ms while `nvme0n1` is at `3.1%`. What is the disk telling you, and why is `%util` alone a misleading saturation signal on modern SSD/NVMe? What must you enable *in advance* for `sar` to reconstruct this after the fact?

---

## Exercise 7 — Turning monitoring into automatic reaction (`monit`, awareness of `collectd`)

Observation only helps if something acts on it. The objective expects *awareness* of tools that watch a metric and take an action.

1. Install `monit` and drop in a control file that restarts a service and alerts on resource thresholds:

   ```conf
   # /etc/monit/conf.d/ha.conf
   set daemon 30                      # check cycle: every 30 s
   set alert admin@example.org

   check system $HOST
       if loadavg (5min) > 8      then alert
       if memory usage    > 90%   then alert
       if cpu usage (wait) > 40%  then alert

   check filesystem rootfs with path /
       if space usage > 85% then alert

   check process sshd with pidfile /run/sshd.pid
       start program = "/bin/systemctl start ssh"
       stop  program = "/bin/systemctl stop ssh"
       if 3 restarts within 5 cycles then alert
   ```

2. Validate the syntax, reload, and read status:

   ```bash
   sudo monit -t              # test control file syntax
   sudo systemctl enable --now monit
   sudo monit reload
   sudo monit status
   sudo monit summary
   ```

3. *(Awareness.)* Note where `collectd` fits: a lightweight daemon whose plugins (`cpu`, `memory`, `df`, `disk`, `sensors`, `smart`, `thermal`, `ipmi`) gather the very metrics from Exercises 1–6 and ship them to RRD, Prometheus, or a network collector — the same numbers, centralized instead of read by hand:

   ```conf
   # /etc/collectd/collectd.conf (excerpt)
   LoadPlugin cpu
   LoadPlugin sensors
   LoadPlugin smart
   LoadPlugin thermal
   LoadPlugin write_prometheus
   <Plugin write_prometheus>
       Port "9103"
   </Plugin>
   ```

**Comprehension check**

- **Q19.** What does `monit` do that plain `sar`/`sensors` do not? Illustrate with the `check process sshd` block.
- **Q20.** In one line each, position `collectd` versus `monit`: which one *reacts* to a threshold on the local node, and which one *collects and exports* metrics for centralized graphing/alerting?

---

<details>
<summary><strong>Answers</strong> (click to expand)</summary>

**Q1.** `RAW_VALUE = 0` is the real physical count of reallocated sectors. `VALUE` (100) is a firmware-computed *normalized health score* from 1–253; higher is healthier. The drive is considered failing for that attribute when `VALUE` drops to or below `THRESH` (10). So health is judged by `VALUE ≤ THRESH`, not by the raw number directly — though a climbing `RAW_VALUE` is what eventually drags `VALUE` down.

**Q2.** The normalized `VALUE` for temperature is an inverse score: hotter → lower score. `067` is just the vendor's normalization of "33 °C" against its own scale; it is not an alarm. Judge temperature by the `RAW_VALUE` (33 °C) and the drive's `high`/`crit` limits, not by the normalized column. This is exactly why `smartd`'s `-W` option acts on the raw temperature, not on the normalized value.

**Q3.** Classic ATA pre-failure predictors: **5** Reallocated_Sector_Ct, **197** Current_Pending_Sector, **198** Offline_Uncorrectable, **187** Reported_Uncorrect, and **188** Command_Timeout / **10** Spin_Retry_Count (either is commonly cited). Backblaze-style guidance treats non-zero 5/187/197/198 as strong failure signals. The NVMe equivalents of "wearing out / out of spares" are **Percentage Used**, **Available Spare** vs **Available Spare Threshold**, and a non-zero **Critical Warning** bitmask / **Media and Data Integrity Errors**.

**Q4.** `S` = short self-test, `L` = long (extended) self-test. The five fields after the letter are `MONTH/DAY-OF-MONTH/DAY-OF-WEEK/HOUR` — actually the token is `T/MM/DD/d/HH`: **Type / Month / Day-of-month / Day-of-week / Hour**, each a regex where `..` means "any". So `S/../.././02` = a **short** test on any month, any day-of-month, any weekday, at **02:00**; `L/../../6/03` = a **long** test on any month, any day-of-month, weekday **6 (Saturday)**, at **03:00**. Net: short test nightly at 02:00, long test weekly on Saturday at 03:00.

**Q5.** *Offline data collection* (`-o on` / `-t offline`) is the firmware continuously updating attribute counters in the background; it doesn't verify the media by reading it end-to-end. A *self-test* (`-t short`/`-t long`) is an active diagnostic the drive runs against its own electronics and surface (long = full read scan). `-n standby` tells `smartd` **not to spin up a disk that is in standby/sleep** just to poll it — important on nodes with idle disks, both to avoid needless wear/power and to let disks actually sleep.

**Q6.** `smartd` runs the program given by `-M exec` (here `smartd_warning.sh`) and passes the alert details via environment variables; `-m root` sets the mail recipient the default warning script (or your custom one) uses. So `-m` names *who* is notified and `-M exec …` names *how* / *what runs* to deliver it (e.g. send mail, page, write to a webhook). The event is also logged to syslog/journal (`journalctl -u smartd`).

**Q7.** `sensors-detect` probes I2C/SMBus adapters and Super-I/O chips and, on confirmation, appends the matching kernel modules (e.g. `coretemp`, `nct6775`) to `/etc/modules` (Debian) or `/etc/modules-load.d/` and configures adapter modules. `sensors` reads values exposed under `/sys/class/hwmon/` by those **driver modules**; if the modules aren't loaded, there is no hwmon interface to read, so `sensors` prints nothing. Persisting them in `/etc/modules` ensures they load on every boot.

**Q8.** `high` is a warning/soft threshold ("getting hot, act on it"); `crit` is the critical limit at which the CPU/firmware itself takes protective action — thermal throttling and, if exceeded, an emergency shutdown/thermal trip — **independently of any monitoring you run**. Your tooling should react at/near `high`; you should never *rely* on reaching `crit`, because that means the hardware is already defending itself.

**Q9.** `set temp1_max 70` does **not** change hardware behavior; the chip's own limits are what trigger hardware responses. `set` (and `label`, `compute`) in `/etc/sensors.d/*.conf` only affects **how `libsensors`/`sensors` displays and evaluates** the reading — the limit shown, and what user-space tools consider "alarm". It is applied by `sensors -s` (and read on each `sensors` invocation). To make anything *happen* at 70 °C you still need a daemon (`watchdog`, `monit`, `collectd` threshold, etc.) acting on that value.

**Q10.** IPMI runs on the **BMC**, a dedicated microcontroller on the motherboard with its own firmware, its own power rail (standby power), and its own network path. It reads sensors over side-band buses and controls chassis power directly, so it works while the host CPU/OS is halted, panicked, or powered off. `lm-sensors` is just user-space code on the *main* OS reading hwmon drivers — if that OS is hung, `lm-sensors` is hung with it.

**Q11.** `chassis power soft` sends an ACPI soft power button event asking the OS to shut down **cleanly**. `chassis power off` cuts power immediately (hard, no OS cooperation). `chassis power cycle` = off then on. `chassis power reset` = a hard reset without a full power drop. The clean one is `power soft`; the hard fence used by STONITH/fencing agents is `power off` (or `reset`/`cycle`) because it guarantees the node is dead regardless of OS state — the whole point of fencing.

**Q12.** After an unexplained reboot, `ipmitool sel elist` shows the **System Event Log** — persistent, BMC-recorded hardware events (thermal trip, PSU failure, correctable/uncorrectable ECC, watchdog expiry) with timestamps — often the only record of *why* the box reset, since the OS logs died with it. `-I open` (default) talks to the local BMC via `/dev/ipmi0` in-band; `-I lanplus` uses **IPMI v2.0 RMCP+ over the network** to a remote BMC (`-H/-U/-P`), which is how you reach a node whose OS is unreachable.

**Q13.** Opening `/dev/watchdog` **arms** the timer. The kernel only *disarms* on close if the process wrote the magic character `V` first (the "magic close" contract); otherwise a close is treated as a possible crash and the timer keeps counting, resetting the machine at timeout. So a script that opens the device to pet it, then exits (or is Ctrl-C'd) without writing `V`, leaves an armed, un-petted timer — one timeout later the box hard-resets. Always `echo -n 'V' > /dev/watchdog` before releasing it.

**Q14.** 
- Standalone **`watchdog` daemon**: user-space process that pets `/dev/watchdog` and runs health checks; catches conditions it tests (load, memory, ping, temperature, file freshness) and a total user-space lockup, but is itself just a process.
- **`RuntimeWatchdogSec`** (systemd/PID 1 pets the hardware watchdog): recovers a hung **kernel or `systemd`** itself — if PID 1 can't run, it stops petting and the hardware resets the node.
- Service **`WatchdogSec=`** (+ `sd_notify(WATCHDOG=1)`, `Restart=on-watchdog`): recovers a single hung **application** by restarting *that unit only*, without rebooting the machine.

**Q15.** `wd_keepalive` is a stripped-down daemon that does nothing but keep petting `/dev/watchdog` while the full `watchdog` daemon is stopped (e.g. during its own restart/upgrade), so an already-armed timer doesn't fire during the gap. Running the `watchdog` daemon **and** `systemd`'s `RuntimeWatchdogSec` against the same `/dev/watchdog` is dangerous because the device generally allows a **single opener/owner**: they fight over the chip, one fails to pet reliably, and you get spurious resets. Pick one owner of the hardware watchdog.

**Q16.** Load `7.42` on 4 CPUs means ~7.4 runnable/uninterruptible tasks competing for 4 cores → the run queue is ~1.85× the CPU count, i.e. **overloaded** (roughly, load > nproc = saturated). But load counts both CPU-bound *and* uninterruptible-I/O tasks, so it doesn't say *why*. The `wa` (%iowait) column in `vmstat`/`sar -u` (and the `r` vs `b` process columns in `vmstat`) distinguishes CPU-bound (high `us`+`sy`, high `r`) from I/O-bound (high `wa`, high `b`).

**Q17.** `wa` = **% of CPU time idle while waiting on outstanding disk/network I/O** (the CPU has nothing to run because tasks are blocked on I/O). `st` = **steal time**: % of time the (virtual) CPU was *ready* to run but the **hypervisor gave the physical CPU to another guest**. High `st` is the specific signal that a *virtualized* HA node is being starved by an oversubscribed host — a hardware/capacity problem outside the guest.

**Q18.** `sda` at `%util 98.7%` with `w_await 18.4 ms` is a saturated, slow (likely spinning) disk that is the bottleneck, while the NVMe is nearly idle — move the hot workload or investigate `sda`. `%util` is misleading on SSD/NVMe because those devices service many requests **in parallel**; a modern drive can be "100% of the time servicing at least one I/O" while still far from its real throughput/queue-depth limit, so `%util` no longer implies saturation — look at `aqu-sz` (average queue depth) and `await` instead. To reconstruct this historically, you must have **enabled `sysstat` collection in advance** (`ENABLED="true"` / `systemctl enable --now sysstat`) so `sadc` wrote the `saNN` archives that `sar -d` reads.

**Q19.** `monit` doesn't just *report* a value — it evaluates a condition every cycle and **takes an action** (restart, alert, exec). In the `check process sshd` block, if the process is missing it runs the `start program` to bring it back, and if it flaps (`3 restarts within 5 cycles`) it escalates with an alert instead of restarting forever. `sar`/`sensors` only expose numbers; a human or another tool has to act.

**Q20.** `monit` = **local reactive supervisor**: watches thresholds/processes on one node and *acts* (restart/alert). `collectd` = **metrics collector/exporter**: lightweight plugin-based daemon that gathers CPU/memory/disk/sensors/SMART/IPMI/thermal data and ships it to RRD, a network collector, or Prometheus for centralized graphing and alerting — it collects, it doesn't restart your services.

</details>