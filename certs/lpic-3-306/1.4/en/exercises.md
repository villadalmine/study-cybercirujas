# LPIC-3 Exam 306-300 (v3.0) — Topic 306.4: Single Node High Availability

## Architectural Overview & Domain Scope

Single Node High Availability (HA) establishes the baseline layer of infrastructure resilience before extending workloads across distributed multi-node clusters. In production SRE environments, a fault at the single-node layer—such as silent data corruption, unhandled kernel watchdog timeouts, network link dropouts, or storage path loss—erodes the mean time between failures (MTBF) of the higher-level cluster control plane (e.g., Pacemaker, Corosync, Kubernetes).

This study guide covers the four foundational pillars of Single Node High Availability defined in the LPIC-3 306-300 syllabus (Exam Weight: 25):

```
+-----------------------------------------------------------------------------------+
|                        SINGLE NODE HIGH AVAILABILITY (HA)                         |
+------------------------------------+----------------------------------------------+
| 1. Hardware & System Health        | 2. Storage Fault Tolerance                   |
|    - SMART Disk Diagnostics        |    - mdadm Software RAID (v1.2 Superblock)  |
|    - UPS Management (NUT / upsd)   |    - Write-Intent Bitmaps & Resync        |
|    - Linux Kernel & systemd        |    - LVM2 RAID1/5/6 & Thin Auto-Extend    |
|      Hardware Watchdogs            |    - dmeventd Monitoring Daemon             |
+------------------------------------+----------------------------------------------+
| 3. SAN Path Resiliency             | 4. Network Link Aggregation                  |
|    - Device-Mapper Multipathing    |    - Linux Kernel Bonding Driver             |
|    - SCSI ALUA & Path Selectors    |    - Active-Backup vs LACP (802.3ad)        |
|    - multipathd Path Checkers      |    - MII & ARP Link Health Monitoring        |
+------------------------------------+----------------------------------------------+
```

### Official References
* [Linux Professional Institute (LPI) LPIC-3 306-300 Objectives](https://www.lpi.org/our-certifications/lpic-3-306-overview/)
* [Linux Kernel Bonding Driver Documentation](https://www.kernel.org/doc/Documentation/networking/bonding.txt)
* [Red Hat Enterprise Linux Device Mapper Multipathing Guide](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_device-mapper_multipath/)
* [Network UPS Tools (NUT) User Manual](https://networkupstools.org/docs/user-manual.chunked/index.html)
* [systemd Watchdog Integration & Execution Environment](https://www.freedesktop.org/software/systemd/man/latest/systemd-system.conf.html)

---

## Module 1: Hardware & System Health Monitoring (SMART, UPS, Watchdogs)

### 1.1 Deep Technical Architecture & Mechanics

#### SMART (Self-Monitoring, Analysis, and Reporting Technology)
Modern storage drives (SATA HDDs, NVMe SSDs) maintain non-volatile internal logs tracking hardware telemetry. `smartd` (part of `smartmontools`) runs as a background daemon monitoring key attributes:
* **Reallocated_Sector_Ct (Attribute 5):** Count of remapped physical sectors. Non-zero values indicate physical surface degradation.
* **Current_Pending_Sector_Ct (Attribute 197):** Unstable sectors awaiting read/write verification before reallocation.
* **NVMe Percentage Used & Media Errors:** For NVMe drives, telemetry is parsed via NVMe Health Logs (`smartctl -a /dev/nvme0n1`), monitoring spare capacity and wear metrics.

#### Network UPS Tools (NUT) Protocol Architecture
NUT decouples hardware monitoring from client notification using a three-tier architecture:
1. **Driver Tier (`bcmxcpy`, `usbhid-ups`, `snmp-ups`):** Communicates with physical UPS hardware via USB/Serial/SNMP and writes hardware state to shared IPC sockets.
2. **Server Daemon (`upsd`):** Listens on TCP port 3493, serving state updates to authenticated client connections.
3. **Monitoring Daemon (`upsmon`):** Acts as the enforcement engine. In a Primary/Secondary topology (`master`/`slave`), `upsmon` detects `FSD` (Forced Shutdown) states, initiates gracefully ordered OS shutdowns, and instructs the UPS hardware to cut power (`upsdrvctl shutdown`).

#### Linux Kernel Hardware & Software Watchdogs
The Linux watchdog infrastructure guards against kernel panics, CPU deadlocks, and hung userspace daemons:
* **Hardware Watchdog (`/dev/watchdog`):** A physical timer module (e.g., IPMI, Intel TCO) or hypervisor virtual timer. The system must write to `/dev/watchdog` within a specified window (`WatchdogSec`). If unwritten, the hardware forces an immediate system reset (NMI/hard reset).
* **Systemd Service Watchdogs (`sd_notify`):** `systemd` configures system services with `WatchdogSec=N`. The service sends keepalive signals (`sd_notify("WATCHDOG=1")`) at intervals `< N/2`. If the event loop freezes, `systemd` triggers the service restart logic or reboots the node if configured with `FailureAction=reboot`.

```
           +----------------------------------------------------------------+
           |                    Systemd Manager / Kernel                    |
           +----------------------------------------------------------------+
             | sd_notify("WATCHDOG=1")               | /dev/watchdog Ping
             v                                       v
   +-------------------+                   +-------------------+
   | Critical Service  |                   | Hardware Watchdog |
   | Event Loop        |                   | Timer (IPMI/TCO)  |
   +-------------------+                   +-------------------+
             | (If Hung)                             | (Timer Expires)
             v                                       v
   +-------------------+                   +-------------------+
   | systemd Kills &   |                   | HARD HARDWARE     |
   | Restores Service  |                   | REBOOT TRIGGERED  |
   +-------------------+                   +-------------------+
```

---

### 1.2 Configuration Files & Production Manifests

#### `/etc/smartd.conf`
```conf
# Monitor all NVMe and SATA drives with desktop alerts and automatic self-tests
DEVICESCAN -H -m sre-alerts@infrastructure.internal -M exec /usr/share/smartmontools/smartd-runner \
-s (S/../.././02|L/../6/./03) \
-W 4,45,55 \
-I 194 -I 195 -I 200
```

#### `/etc/nut/ups.conf`
```conf
[prg-ups-01]
    driver = usbhid-ups
    port = auto
    desc = "Production Rack 01 Main Eaton UPS"
    vendorid = "0463"
    productid = "ffff"
    pollinterval = 2
```

#### `/etc/nut/upsmon.conf`
```conf
MONITOR prg-ups-01@localhost 1 upsmon_admin SecretPassword123 master
MINSUPPLIES 1
SHUTDOWNCMD "/sbin/shutdown -h +0"
POWERDOWNFLAG /etc/killpower
POLLFREQ 5
POLLFREQALERT 2
HOSTSYNC 15
DEADTIME 15
RBWARNTIME 43200
NOCOMMWARNTIME 300
FINALDELAY 5
```

#### `/etc/systemd/system.conf` (System-wide Watchdog Configuration)
```ini
[Manager]
RuntimeWatchdogSec=10s
RebootWatchdogSec=10m
KExecWatchdogSec=5m
```

#### `/etc/systemd/system/ha-core-engine.service`
```ini
[Unit]
Description=Production Critical HA Engine
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/ha-engine --config /etc/ha-engine/config.yaml
WatchdogSec=10s
Restart=always
RestartSec=2s
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
```

---

### 1.3 Guided Exercise: Implementing Hardware Self-Healing & UPS Automation

#### Step 1: Query SMART Diagnostic Telemetry for SATA and NVMe Drives
Execute detailed diagnostic queries on system storage devices to verify health status and monitor critical failure metrics:

```bash
# Query overall health status of a SATA disk
sudo smartctl -H /dev/sda
```
*Expected Output:*
```text
smartctl 7.3 2022-02-28 r5338 [x86_64-linux-5.15.0-100-generic] (local build)
Copyright (C) 2002-22, Bruce Allen, Christian Franke, www.smartmontools.org

=== START OF READ SMART DATA SECTION ===
SMART overall-health self-assessment test result: PASSED
```

```bash
# Extract raw attribute tables focusing on sectors and wear count
sudo smartctl -A /dev/sda | grep -E "Reallocated_Sector|Current_Pending_Sector|Offline_Uncorrectable"
```
*Expected Output:*
```text
  5 Reallocated_Sector_Ct   PO--CK   100   100   010    -    0
197 Current_Pending_Sector  -O--CK   100   100   000    -    0
198 Offline_Uncorrectable   ---R--   100   100   000    -    0
```

```bash
# Inspect NVMe specific health log page
sudo smartctl -a /dev/nvme0n1 | grep -E "Critical Warning|Temperature:|Available Spare:|Percentage Used"
```
*Expected Output:*
```text
Critical Warning:                   0x00
Temperature:                        34 Celsius
Available Spare:                    100%
Percentage Used:                    2%
```

#### Step 2: Validate NUT UPS Daemon Communication
Query the `upsd` server via `upsc` to verify live sensor metrics:

```bash
sudo upsc prg-ups-01@localhost ups.status
```
*Expected Output:*
```text
OL
```
*(Note: `OL` = On Line, `OB` = On Battery, `LB` = Low Battery)*

```bash
sudo upsc prg-ups-01@localhost input.voltage battery.charge battery.runtime
```
*Expected Output:*
```text
input.voltage: 231.4
battery.charge: 100
battery.runtime: 2450
```

#### Step 3: Test systemd Service Watchdog Execution
Simulate a main event-loop deadlock on a watchdog-monitored process using signal suspension (`SIGSTOP`):

```bash
# Start the critical HA daemon and verify its active status
sudo systemctl restart ha-core-engine.service
sudo systemctl status ha-core-engine.service | grep -E "Active:|Main PID"
```
*Expected Output:*
```text
   Active: active (running) since Thu 2026-08-06 14:10:00 UTC; 4s ago
 Main PID: 4892 (ha-engine)
```

```bash
# Freeze the process using SIGSTOP to block sd_notify keepalives
sudo kill -STOP 4892

# Monitor system journal logs in real-time to watch systemd catch the watchdog timeout
sudo journalctl -u ha-core-engine.service -f
```
*Expected Output:*
```text
Aug 06 14:10:14 node-01 systemd[1]: ha-core-engine.service: Watchdog timeout (limit 10s)!
Aug 06 14:10:14 node-01 systemd[1]: ha-core-engine.service: Killing process 4892 (ha-engine) with signal SIGABRT.
Aug 06 14:10:15 node-01 systemd[1]: ha-core-engine.service: Main process exited, code=killed, status=6/ABRT
Aug 06 14:10:17 node-01 systemd[1]: ha-core-engine.service: Scheduled restart job, restart counter is at 1.
Aug 06 14:10:17 node-01 systemd[1]: ha-core-engine.service: Started Production Critical HA Engine.
```

---

### 1.4 Verification Questions

1. **Question 1.1:** In a NUT setup with primary/secondary (`master`/`slave`) hosts powered by a single UPS, what mechanism prevents the primary node from powering down the UPS hardware before secondary hosts have completely unmounted their root filesystems?
2. **Question 1.2:** A system administrator configures `WatchdogSec=10s` in a unit file, but the application developer implements an `sd_notify("WATCHDOG=1")` heartbeat interval of 9.5 seconds inside the application code. Why will this service experience unexpected periodic restarts under high CPU utilization?

---

## Module 2: Advanced Software RAID & LVM Storage Redundancy

### 2.1 Deep Technical Architecture & Mechanics

#### `mdadm` RAID Mechanics & Write-Intent Bitmaps
Linux Kernel `md` (Multiple Devices) software RAID driver operates at the block level.
* **Metadata Superblocks (v1.2):** Positioned 4KiB from the start of the array device. Contains array UUID, component device indexes, generation numbers, and drive state maps.
* **Write-Intent Bitmap (`--bitmap=internal`):** When writing to a degraded array or during dirty shutdowns, updating every block requires a full array resynchronization. An internal write-intent bitmap splits the array into chunk regions and sets a single bit for dirty regions. Upon recovery, `md` scans only dirty bitmap chunks, reducing recovery time from hours to seconds.
* **Scrubbing (`sync_action`):** Scheduled background verification reads blocks across all parity drives, recalculating checksums to detect and repair silent block corruption ("bit rot").

```
+-------------------------------------------------------------------------------+
|                             /dev/md0 (RAID-1 / RAID-5)                        |
+-------------------------------------------------------------------------------+
| Superblock v1.2 | Write-Intent Bitmap (Dirty Chunk Tracker) | Data / Parity   |
+-----------------+------------------------------------------+------------------+
         |                             |                               |
         v                             v                               v
+-----------------+           +-------------------+           +-----------------+
| /dev/sdb1 (Active)|         | /dev/sdc1 (Active)|           | /dev/sdd1 (Spare|
+-----------------+           +-------------------+           +-----------------+
```

#### LVM2 Advanced Mirroring & Dynamic Thin-Pool Auto-Extension
LVM2 abstracts `mdadm` or direct `devmapper` structures into Volume Groups (VG) and Logical Volumes (LV).
* **LVM RAID (`--type raid1` / `--type raid5`):** Uses kernel `md` modules natively instead of legacy `mirror` targets. Provides sub-LV metadata tracking (`lv_rmeta`) alongside data tracking (`lv_rdata`).
* **`dmeventd` Infrastructure:** The Device Mapper Event Daemon monitors thin pools and RAID state changes. When thin pool utilization crosses `snapshot_autoextend_threshold`, `dmeventd` automatically executes `lvextend` based on `snapshot_autoextend_percent`, preventing thin-pool full write freezes.

---

### 2.2 Configuration Files & Production Manifests

#### `/etc/mdadm/mdadm.conf`
```conf
# Production mdadm layout configuration
HOMEHOST <system>
MAILADDR sre-storage-alerts@infrastructure.internal
AUTO +100
ARRAY /dev/md/data0 metadata=1.2 bitmap=internal UUID=4c88a8f1:b122904a:e900c31a:df90211a
```

#### `/etc/lvm/lvm.conf` (Thin-Pool & Monitoring Auto-Extend Excerpt)
```ini
activation {
    thin_pool_autoextend_threshold = 80
    thin_pool_autoextend_percent = 20
    snapshot_autoextend_threshold = 80
    snapshot_autoextend_percent = 20
    monitoring = 1
}
```

---

### 2.3 Guided Exercise: Managing RAID Failure Recovery & LVM Auto-Resilience

#### Step 1: Create a RAID-5 Array with Write-Intent Bitmap
Initialize a 3-disk RAID-5 array with an explicit internal write-intent bitmap using `mdadm`:

```bash
# Create the array /dev/md0 using loopback devices or spare partitions
sudo mdadm --create /dev/md0 --level=5 --raid-devices=3 /dev/sdb /dev/sdc /dev/sdd --bitmap=internal
```
*Expected Output:*
```text
mdadm: Defaulting to version 1.2 metadata
mdadm: array /dev/md0 started.
```

```bash
# Verify detail output, superblock, and active bitmap state
sudo mdadm --detail /dev/md0
```
*Expected Output:*
```text
/dev/md0:
           Version : 1.2
     Creation Time : Thu Aug  6 14:20:00 2026
        Raid Level : raid5
        Array Size : 20951040 (19.98 GiB 21.45 GB)
     Used Dev Size : 10475520 (9.99 GiB 10.73 GB)
      Raid Devices : 3
     Total Devices : 3
       Persistence : Superblock is present

     Intent Bitmap : Internal
       State : clean 
 Active Devices : 3
Working Devices : 3
 Failed Devices : 0
  Spare Devices : 0

         Layout : left-symmetric
     Chunk Size : 512K

           Consistency Policy : bitmap

           Name : node-01:0  (local to host node-01)
           UUID : 4c88a8f1:b122904a:e900c31a:df90211a
         Events : 18

    Number   Major   Minor   RaidDevice State
       0       8       16        0      active sync   /dev/sdb
       1       8       32        1      active sync   /dev/sdc
       2       8       48        2      active sync   /dev/sdd
```

#### Step 2: Inject Drive Failure, Monitor Array Degradation, and Rebuild
Simulate a hardware failure on `/dev/sdc`, hot-remove the failed device, and add a replacement spare device `/dev/sde`:

```bash
# Mark device as faulty in kernel space
sudo mdadm /dev/md0 --fail /dev/sdc
```
*Expected Output:*
```text
mdadm: set /dev/sdc faulty in /dev/md0
```

```bash
# Check degraded status via procfs
cat /proc/mdstat
```
*Expected Output:*
```text
Personalities : [raid6] [raid5] [raid4] 
md0 : active raid5 sdd[2] sdc[1](F) sdb[0]
      20951040 blocks super 1.2 level 5, 512k chunk, algorithm 2 [3/2] [U_U]
      bitmap: 1/1 pages [4KB], 65536KB chunk
```

```bash
# Hot-remove failed drive and add new spare drive /dev/sde
sudo mdadm /dev/md0 --remove /dev/sdc
sudo mdadm /dev/md0 --add /dev/sde
```
*Expected Output:*
```text
mdadm: hot removed /dev/sdc from /dev/md0
mdadm: added /dev/sde to /dev/md0
```

```bash
# Check resynchronization progress
cat /proc/mdstat
```
*Expected Output:*
```text
Personalities : [raid6] [raid5] [raid4] 
md0 : active raid5 sde[3] sdd[2] sdb[0]
      20951040 blocks super 1.2 level 5, 512k chunk, algorithm 2 [3/2] [U_U]
      [=>...................]  recovery =  8.4% (882100/10475520) finish=1.8min speed=86421K/sec
      bitmap: 1/1 pages [4KB], 65536KB chunk
```

#### Step 3: Deploy LVM RAID-1 Volume and Inspect Health Properties
Build an LVM2 redundant Volume Group and monitor LVM health attributes using `lvs`:

```bash
# Create physical volumes, volume group, and a true LVM RAID1 volume
sudo pvcreate /dev/sdf /dev/sdg
sudo vgcreate vg_production /dev/sdf /dev/sdg
sudo lvcreate --type raid1 -m 1 -L 5G -n lv_app_data vg_production
```
*Expected Output:*
```text
  Logical volume "lv_app_data" created.
```

```bash
# Inspect internal RAID sub-LVs and health statuses
sudo lvs -a -o lv_name,vg_name,copy_percent,health_status,lv_layout,stripe_size
```
*Expected Output:*
```text
  LV                  VG            Copy%  Health Status Layout     Stripe
  lv_app_data         vg_production 100.00 refresh       raid,sync      0
  [lv_app_data_rimage_0] vg_production                     linear         0
  [lv_app_data_rimage_1] vg_production                     linear         0
  [lv_app_data_rmeta_0]  vg_production                     linear         0
  [lv_app_data_rmeta_1]  vg_production                     linear         0
```

---

### 2.4 Verification Questions

1. **Question 2.1:** What is the structural purpose of `[lv_app_data_rmeta_0]` and `[lv_app_data_rmeta_1]` sub-logical volumes created automatically alongside `lv_app_data` during an LVM `--type raid1` creation?
2. **Question 2.2:** During an `mdadm` RAID-5 array scrub (`echo check > /sys/block/md0/md/sync_action`), the kernel encounters a read error on disk 0 while recalculating parity for block offset X. Disk 1 and Disk 2 read successfully. How does the kernel `md` driver handle block offset X to prevent data loss?

---

## Module 3: Storage Multipath I/O (`multipathd`)

### 3.1 Deep Technical Architecture & Mechanics

#### Device-Mapper Multipath Core Architecture
In Storage Area Networks (SAN) using Fibre Channel (FC) or iSCSI, a single LUN is exposed across multiple Host Bus Adapters (HBAs) and SAN switches. This presents multiple raw block device paths (e.g., `/dev/sdb`, `/dev/sdc`, `/dev/sdd`, `/dev/sde`) pointing to the same underlying physical LUN. 

`multipathd` uses the Linux Device-Mapper framework to aggregate individual paths into a unified block device (`/dev/mapper/mpathX` or `/dev/dm-N`).

```
+-----------------------------------------------------------------------------------+
|                        /dev/mapper/mpatha (Virtual Device)                        |
+-----------------------------------------------------------------------------------+
                                         |
                       Device-Mapper Multipath Multiplexer
                                         |
               +-------------------------+-------------------------+
               | Path Group 1 (Active/Preferred)                   | Path Group 2 (Standby)
               | Priority: 50                                      | Priority: 10
               +-------------------------+                         +-------------------------+
               |                         |                         |                         |
               v                         v                         v                         v
       +---------------+         +---------------+         +---------------+         +---------------+
       |   /dev/sdb    |         |   /dev/sdc    |         |   /dev/sdd    |         |   /dev/sde    |
       |  (HBA1->SW1)  |         |  (HBA2->SW1)  |         |  (HBA1->SW2)  |         |  (HBA2->SW2)  |
       +---------------+         +---------------+         +---------------+         +---------------+
               |                         |                         |                         |
               +-------------------------+-------------------------+-------------------------+
                                         |
                                  SAN Storage Target
                               (SCSI ALUA Controller)
```

#### SCSI ALUA (Asymmetric Logical Unit Access)
Modern storage arrays implement SCSI ALUA (SPC-3 standard), defining Target Port Group (TPG) states:
1. **Active/Optimized:** Preferred path group connected to the LUN's primary controller. Lowest latency.
2. **Active/Non-Optimized:** Direct path connected to the secondary controller. I/O incurs internal array bus traversal penalties.
3. **Standby:** Controller port is passive; accepts no user I/O until path failover occurs.
4. **Unavailable:** Port is undergoing maintenance or physically disconnected.

#### Path Checkers & Failover Mechanics
`multipathd` continuously monitors path health via active path checkers:
* **`tur` (Test Unit Ready):** Sends SCSI `TEST UNIT READY` commands down the raw block path. Fast, minimal overhead.
* **`directio`:** Issues asynchronous direct I/O reads to sector 0 of the underlying device.
* **Failover vs Failback:** When all paths in Path Group 1 fail, `multipathd` shifts traffic to Path Group 2 (`failover`). When Path Group 1 recovers, `failback immediate` or `failback <seconds>` automatically shifts I/O back to the optimized path.

---

### 3.2 Configuration Files & Production Manifests

#### `/etc/multipath.conf`
```conf
defaults {
    user_friendly_names         yes
    find_multipaths             yes
    enable_foreign              ""
    path_grouping_policy        group_by_prio
    path_selector               "service-time 0"
    path_checker                tur
    features                    "1 queue_if_no_path"
    hardware_handler            "1 alua"
    prio                        alua
    failback                    immediate
    rr_weight                   uniform
    no_path_retry               18
    max_fds                     8192
}

blacklist {
    devnode "^(td|hd|vd|xvd|sd[a-a])[0-9]*"
    wwid    "360000000000000000000000000000000"
}

blacklist_exceptions {
    property "(SCSI_IDENT_.*|ID_WWN)"
}

multipaths {
    multipath {
        wwid                    3600a09803830447a4f2b4d6f6835476d
        alias                   mpath_san_db
        path_grouping_policy    group_by_prio
        prio                    alua
        failback                immediate
    }
}

devices {
    device {
        vendor                  "NETAPP"
        product                 "LUN.*"
        path_grouping_policy    group_by_prio
        path_checker            tur
        features                "1 queue_if_no_path"
        hardware_handler        "1 alua"
        prio                    alua
        failback                immediate
    }
}
```

---

### 3.3 Guided Exercise: Multipath Topology Inspection & Path Failure Simulation

#### Step 1: Query Multipath Topology and Identify Path Groups
Examine the active multipath mapping, path priorities, and hardware ALUA states:

```bash
# Print detailed multipath topology
sudo multipath -ll
```
*Expected Output:*
```text
mpath_san_db (3600a09803830447a4f2b4d6f6835476d) dm-2 NETAPP,LUN C-Mode
size=500G features='1 queue_if_no_path' hwhandler='1 alua' wp=rw
|-+- policy='service-time 0' prio=50 status=active
| |- 1:0:0:1 sdb 8:16 active ready running
| `- 2:0:0:1 sdc 8:32 active ready running
`-+- policy='service-time 0' prio=10 status=enabled
  |- 1:0:1:1 sdd 8:48 active ready running
  `- 2:0:1:1 sde 8:64 active ready running
```

```bash
# Query multipath daemon client interface for path states
sudo multipathd show paths format "%w %i %d %D %t %T %s"
```
*Expected Output:*
```text
uuid                             hcil    dev dev_t dm_st chk_st dev_st
3600a09803830447a4f2b4d6f6835476d 1:0:0:1 sdb 8:16  active ready  running
3600a09803830447a4f2b4d6f6835476d 2:0:0:1 sdc 8:32  active ready  running
3600a09803830447a4f2b4d6f6835476d 1:0:1:1 sdd 8:48  active ready  running
3600a09803830447a4f2b4d6f6835476d 2:0:1:1 sde 8:64  active ready  running
```

#### Step 2: Inject Fibre Channel / iSCSI Path Failure in sysfs
Simulate a cable pull or switch port disable by forcing individual SCSI devices offline via `sysfs`:

```bash
# Force paths sdb and sdc to offline state
echo "offline" | sudo tee /sys/block/sdb/device/state
echo "offline" | sudo tee /sys/block/sdc/device/state
```
*Expected Output:*
```text
offline
```

```bash
# Immediately inspect multipath topology to verify failover to secondary path group
sudo multipath -ll
```
*Expected Output:*
```text
mpath_san_db (3600a09803830447a4f2b4d6f6835476d) dm-2 NETAPP,LUN C-Mode
size=500G features='1 queue_if_no_path' hwhandler='1 alua' wp=rw
|-+- policy='service-time 0' prio=0 status=active
| |- 1:0:0:1 sdb 8:16 faulty offline running
| `- 2:0:0:1 sdc 8:32 faulty offline running
`-+- policy='service-time 0' prio=10 status=active
  |- 1:0:1:1 sdd 8:48 active ready   running
  `- 2:0:1:1 sde 8:64 active ready   running
```

#### Step 3: Restore Paths and Verify Failback Execution
Re-enable SCSI device states and verify immediate failback to the primary path group:

```bash
# Restore paths sdb and sdc
echo "running" | sudo tee /sys/block/sdb/device/state
echo "running" | sudo tee /sys/block/sdc/device/state
sudo multipathd reconfigure
```
*Expected Output:*
```text
ok
```

```bash
# Confirm primary path group priority 50 is restored to active status
sudo multipath -ll | grep -E "status=|prio="
```
*Expected Output:*
```text
|-+- policy='service-time 0' prio=50 status=active
`-+- policy='service-time 0' prio=10 status=enabled
```

---

### 3.4 Verification Questions

1. **Question 3.1:** What is the critical risk of setting `features "0"` (removing `queue_if_no_path`) on a production multipath device housing an active database partition when all storage paths momentarily disconnect for 5 seconds?
2. **Question 3.2:** Contrast the `path_selector` algorithm `"round-robin 0"` with `"service-time 0"`. Why is `"service-time 0"` preferred in modern heterogeneous SAN environments?

---

## Module 4: Network Interface Bonding & Link Aggregation

### 4.1 Deep Technical Architecture & Mechanics

#### Linux Bonding Driver Architecture
The Linux `bonding` module presents a single virtual network device (`bondX`) composed of multiple underlying physical network interface cards (slaves).

```
                      +----------------------------------+
                      |         bond0 Interface          |
                      |   IP: 192.168.10.50/24           |
                      |   MAC: 52:54:00:fa:b1:01         |
                      +----------------------------------+
                                       |
                   Linux Kernel Bonding Multiplexer Engine
                                       |
               +-----------------------+-----------------------+
               | Active Path                                   | Standby Path
               v                                               v
     +-------------------+                           +-------------------+
     |   eth0 (Slave)    |                           |   eth1 (Slave)    |
     | Link: UP (10Gbps) |                           | Link: UP (10Gbps) |
     +-------------------+                           +-------------------+
               |                                               |
               v                                               v
     +-------------------+                           +-------------------+
     | Switch 01 (ToR A) |                           | Switch 02 (ToR B) |
     +-------------------+                           +-------------------+
```

#### Bonding Modes Comparison & Production Mechanics

| Mode | Mode Name | Key Mechanics & Requirements | Switch Configuration Required? |
| :--- | :--- | :--- | :--- |
| **0** | `balance-rr` | Round-robin frame transmission across active slaves. Provides load balancing and fault tolerance. | Yes (Static Trunk/EtherChannel) |
| **1** | `active-backup` | Only one slave is active. Another slave becomes active if the active slave fails. Single MAC address visible on port. | No (Ideal for redundant ToR switches) |
| **2** | `balance-xor` | Transmits based on hash (`[(source MAC XOR dest MAC) % slave count]`). | Yes (Static Trunk) |
| **3** | `broadcast` | Transmits everything on all slave interfaces. | Yes |
| **4** | `802.3ad` | Dynamic Link Aggregation (LACP). Creates aggregation groups sharing speed/duplex. Uses LACPDU frames. | Yes (LACP 802.3ad configured switch) |
| **5** | `balance-tlb` | Adaptive transmit load balancing. Outgoing traffic distributed according to current load on each slave. | No |
| **6** | `balance-alb` | Adaptive load balancing (includes receive load balancing via ARP negotiation). | No |

#### Health Monitoring Protocols: MII vs ARP Monitoring
* **MII Monitoring (`miimon`):** Queries the Media Independent Interface (MII) register of the NIC driver to check if physical carrier link state is `UP`. Fast (e.g., 100ms checks), but cannot detect upstream switch port isolation or silent carrier failure.
* **ARP Monitoring (`arp_interval`, `arp_ip_target`):** Transmits periodic ARP queries to remote IP gateway destinations (`arp_ip_target`). If replies stop, the bonding driver marks the link dead. Catches upstream routing/switch failure states.

---

### 4.2 Configuration Files & Production Manifests

#### `/etc/systemd/network/10-bond0.netdev` (systemd-networkd LACP Mode 4)
```ini
[NetDev]
Name=bond0
Kind=bond

[Bond]
Mode=802.3ad
TransmitHashPolicy=layer3+4
MIIMonitorSec=100ms
UpDelaySec=200ms
DownDelaySec=200ms
LACPTransmitRate=fast
```

#### `/etc/systemd/network/20-bond0-slaves.network`
```ini
[Match]
Name=eth0 eth1

[Network]
Bond=bond0
```

#### `/etc/systemd/network/30-bond0-ip.network`
```ini
[Match]
Name=bond0

[Network]
Address=192.168.10.50/24
Gateway=192.168.10.1
DNS=192.168.10.1
DHCP=no
```

#### Legacy Modprobe Configuration: `/etc/modprobe.d/bonding.conf` (Mode 1 Active-Backup)
```conf
alias bond0 bonding
options bonding mode=1 miimon=100 updelay=200 downdelay=200 primary=eth0 primary_reselect=failure
```

---

### 4.3 Guided Exercise: Bonding Deployment & Dynamic Failover Validation

#### Step 1: Create an Active-Backup Bond (`bond0`) via Sysfs / iproute2
Construct an active-backup bond interface dynamically using sysfs parameters:

```bash
# Load kernel bonding module
sudo modprobe bonding

# Create bond0 interface and configure mode 1 (active-backup) with MII monitoring
echo "+bond0" | sudo tee /sys/class/net/bonding_masters
echo "active-backup" | sudo tee /sys/class/net/bond0/bonding/mode
echo "100" | sudo tee /sys/class/net/bond0/bonding/miimon
echo "200" | sudo tee /sys/class/net/bond0/bonding/updelay
echo "200" | sudo tee /sys/class/net/bond0/bonding/downdelay
```
*Expected Output:*
```text
active-backup
```

```bash
# Enslave interfaces eth0 and eth1 to bond0
sudo ip link set dev eth0 down
sudo ip link set dev eth1 down
echo "+eth0" | sudo tee /sys/class/net/bond0/bonding/slaves
echo "+eth1" | sudo tee /sys/class/net/bond0/bonding/slaves
sudo ip link set dev bond0 up
```
*Expected Output:*
```text
+eth0
+eth1
```

#### Step 2: Inspect Kernel Bonding Status in Procfs
Inspect `/proc/net/bonding/bond0` to confirm slave states, MII status, and the currently active slave:

```bash
cat /proc/net/bonding/bond0
```
*Expected Output:*
```text
Ethernet Channel Bonding Driver: v5.15.0-100-generic

Bonding Mode: fault-tolerance (active-backup)
Primary Slave: None
Currently Active Slave: eth0
MII Status: up
MII Polling Interval (ms): 100
Up Delay (ms): 200
Down Delay (ms): 200
Peer Notification Delay (ms): 0

Slave Interface: eth0
MII Status: up
Speed: 10000 Mbps
Duplex: full
Link Failure Count: 0
Permanent HW addr: 52:54:00:fa:b1:01
Slave queue ID: 0

Slave Interface: eth1
MII Status: up
Speed: 10000 Mbps
Duplex: full
Link Failure Count: 0
Permanent HW addr: 52:54:00:fa:b1:02
Slave queue ID: 0
```

#### Step 3: Inject Physical Interface Failure and Monitor Failover Execution
Simulate a cable disconnect on active interface `eth0` while running a continuous ping test:

```bash
# Start background ICMP monitor (or run in separate terminal)
ping -I bond0 192.168.10.1 -i 0.2 &
PING_PID=$!

# Disable eth0 interface link
sudo ip link set dev eth0 down
```
*Expected Output:*
```text
64 bytes from 192.168.10.1: icmp_seq=1 ttl=64 time=0.312 ms
64 bytes from 192.168.10.1: icmp_seq=2 ttl=64 time=0.298 ms
64 bytes from 192.168.10.1: icmp_seq=3 ttl=64 time=0.341 ms
# [eth0 downed here - link failure detected by miimon]
64 bytes from 192.168.10.1: icmp_seq=4 ttl=64 time=1.42 ms  <-- Packet sustained during failover
64 bytes from 192.168.10.1: icmp_seq=5 ttl=64 time=0.305 ms
```

```bash
# Re-examine procfs bonding state to confirm switchover to eth1
cat /proc/net/bonding/bond0 | grep -E "Currently Active Slave|Link Failure Count"
```
*Expected Output:*
```text
Currently Active Slave: eth1
Link Failure Count: 1
Link Failure Count: 0
```

```bash
# Cleanup ping background job
kill $PING_PID
```

---

### 4.4 Verification Questions

1. **Question 4.1:** Why is `xmit_hash_policy=layer2` insufficient for load balancing outgoing TCP streams across an LACP Mode 4 (`802.3ad`) bond when all client connections route through a single upstream enterprise router?
2. **Question 4.2:** Explain the operational impact of setting `primary_reselect=failure` vs `primary_reselect=always` in an active-backup bond with `primary=eth0` when `eth0` flap-recovers after a brief cable disconnect.

---

<details>
<summary>Answers and Deep Technical Explanations</summary>

### Module 1 Answers

* **Answer 1.1:** NUT relies on the `upsmon` master/slave dependency loop coupled with the `/etc/killpower` flag file mechanism. During a power event (`OB LB` - On Battery, Low Battery), the NUT master daemon issues a shutdown signal to all NUT slaves (`upsmon secondary`). The master waits for secondary hosts to complete network disconnections (`HOSTSYNC` timer). Once all secondary connections drop or time out, `upsmon` on the primary node creates `/etc/killpower`, mounts root read-only, and invokes `upsdrvctl shutdown`. This signals the UPS hardware to delay its power-off timer (e.g., 30 seconds), allowing the primary node to safely unmount filesystems before AC output ceases completely.

* **Answer 1.2:** The application will fail under high CPU load due to scheduling jitter and queue latency. When `WatchdogSec=10s` is configured in `systemd`, `systemd` expects a ping at least once every 10 seconds. However, setting the ping interval to 9.5 seconds leaves a tight margin of only 0.5 seconds. If the CPU experiences thread contention, process context switching delay, or garbage collection pauses, the application thread sending `sd_notify("WATCHDOG=1")` will miss the 10-second window. `systemd` will mark the process as unresponsive, send `SIGABRT`, and kill the service. SRE best practice dictates setting the `sd_notify` interval to $\le \frac{1}{2} \times \text{WatchdogSec}$ (e.g., sending heartbeats every 3–4 seconds for a 10-second watchdog window).

---

### Module 2 Answers

* **Answer 2.1:** In LVM RAID (`--type raid1`), `_rmeta` sub-logical volumes store metadata for each array member, distinct from data images (`_rimage`). The `_rmeta` structures hold superblock state, write-intent bitmaps, and device allocation maps for the underlying kernel `md` RAID engine. Separating metadata into `_rmeta` enables independent metadata journaling, fast out-of-sync block re-synchronization (`Copy%`), and automated status tracking by `dmeventd`.

* **Answer 2.2:** When a read error occurs on Disk 0 during a background array scrub, the kernel `md` driver traps the I/O error (`EIO`). Because RAID-5 maintains block-level parity across remaining drives, `md` reads the corresponding blocks from Disk 1 and Disk 2, recalculates the original payload of the failed block on Disk 0 via XOR computation, and immediately attempts to write the recalculated payload back to Disk 0 at offset X.
  * If the write succeeds, the disk drive's internal controller reallocates the bad sector transparently (incrementing `Reallocated_Sector_Ct`).
  * If the write fails, `md` marks Disk 0 as failed, drops it from the array, increments the failed device count, and alerts `mdadm`.

---

### Module 3 Answers

* **Answer 3.1:** Setting `features "0"` removes the `queue_if_no_path` option. When all storage paths drop (even momentarily for 5 seconds during a SAN switch reboot or failover event), device-mapper cannot queue I/O requests. Instead, it immediately returns I/O read/write errors (`EIO`) to the file system layer. An active database engine encountering `EIO` on its transaction log or tablespace block devices will instantly flip its file system to Read-Only (`errors=remount-ro`) or abort the process via `panic()`, causing unintended service downtime. `queue_if_no_path` forces I/O requests to queue in memory until path recovery occurs or `no_path_retry` attempts expire.

* **Answer 3.2:** 
  * `"round-robin 0"` distributes I/O requests strictly sequentially across all available active paths in a path group without regard to path utilization, latency, or queue depth. If one SAN path travels over a congested 4Gbps HBA while another travels over an idle 16Gbps HBA, round-robin routes equal frame counts to both, causing I/O bottlenecking on the slower path.
  * `"service-time 0"` dynamically selects the path for the next I/O statement by evaluating both the path priority and the total volume of pending in-flight I/O (bytes in flight). Paths processing transactions faster receive a proportionally higher share of I/O throughput, optimizing storage performance in modern SAN environments.

---

### Module 4 Answers

* **Answer 4.1:** `xmit_hash_policy=layer2` hashes frame headers using only the Source MAC and Destination MAC addresses ($MAC_{src} \oplus MAC_{dest}$). When traffic routes through an upstream default gateway router, the Destination MAC address for all outbound frames destined for external subnets resolves to the router's interface MAC address. Because the server MAC ($MAC_{src}$) and router MAC ($MAC_{dest}$) remain constant across all client connections, the hash output evaluates to the exact same numerical index. Consequently, 100% of outbound TCP traffic maps to a single physical slave interface in the bond, neutralizing LACP load-balancing gains. Configuring `xmit_hash_policy=layer3+4` hashes IP addresses and TCP/UDP ports ($IP_{src} \oplus IP_{dest} \oplus Port_{src} \oplus Port_{dest}$), distributing traffic streams evenly across all active link aggregation slaves.

* **Answer 4.2:**
  * `primary_reselect=always` forces the bonding driver to immediately switch active traffic back to `eth0` the moment `eth0` recovers link carrier state (`MII UP`). If `eth0` suffers from intermittent physical link degradation ("link flapping"), setting `always` causes repeated interface failover disruptions, triggering network packet loss and MAC address re-learning churn across ToR switches.
  * `primary_reselect=failure` instructs the bonding driver to keep traffic on the current working backup slave (`eth1`) even after `eth0` recovers. `eth0` transitions to passive standby status and will only become active again if `eth1` fails completely. This policy prevents link-flap churn and ensures network stability.

</details>