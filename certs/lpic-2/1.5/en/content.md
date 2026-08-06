# LPIC-2 (Exam 201-450 v4.5) — Topic 204 / 1.5: Advanced Storage Device Administration

---

## 1. Motivation & Enterprise Architectural Context

In modern enterprise infrastructure and SRE operations, storage architectures must provide four non-negotiable guarantees: **high availability (HA)**, **horizontal predictability**, **zero-downtime maintenance**, and **resilience against hardware degradation**. 

Direct-Attached Storage (DAS) operating without redundant pathing or logical abstraction creates single points of failure (SPOF) and hard IO boundaries. Enterprise Linux storage architectures decouple physical storage hardware from logical operating system abstractions through a layered storage stack:

```
+-----------------------------------------------------------------------+
|                       Filesystem Layer (ext4, xfs)                    |
+-----------------------------------------------------------------------+
|                    Logical Volume Manager (LVM2)                      |
|            [ Logical Volumes (LV) / Thin Pools / Snapshots ]          |
+-----------------------------------------------------------------------+
|                 Device-Mapper Multipathing (DM-Multipath)             |
|                 [ Active/Active or Active/Passive Failover ]          |
+-----------------------------------------------------------------------+
|                     Block Layer & I/O Schedulers                      |
|                  [ mq-deadline / kyber / bfq / none ]                 |
+-----------------------------------------------------------------------+
|                   Storage Network / Controller Layer                  |
|               [ iSCSI Initiator / Software RAID (mdadm) ]             |
+-----------------------------------------------------------------------+
|                     Physical Hardware / Fabric Path                   |
|                   [ NVMe / SAS / iSCSI Target / SAN LUNs ]            |
+-----------------------------------------------------------------------+
```

### The Enterprise Storage Problem Space
1. **Physical Medium & Controller Failure**: Hard drives and SSDs suffer from unrecoverable read errors (URE), latent sector errors, and controller hangs. Software RAID (`mdadm`) provides programmatic block-level redundancy without vendor lock-in associated with proprietary hardware RAID controllers.
2. **Path Availability & SAN Resilience**: In Storage Area Networks (SAN) using iSCSI or Fibre Channel, a network switch failure or host bus adapter (HBA) port outage breaks block storage connectivity. Device-Mapper Multipathing (`dm-multipath`) provides transparent path aggregation, load balancing, and failover across distinct storage fabrics.
3. **Capacity Allocation Dynamics**: Static partitioning forces offline re-partitioning when volume demand exceeds initial limits. Logical Volume Manager (`LVM2`) enables online expansion, snapshotting for point-in-time state backups, thin provisioning for over-commit models, and live data migration (`pvmove`) without unmounting filesystems.
4. **Kernel I/O Congestion**: Modern NVMe and Multi-Queue block devices (`blk-mq`) can process hundreds of thousands of Input/Output Operations Per Second (IOPS). Misconfigured block queue depth, incorrect I/O schedulers, or inadequate readahead values saturate system CPU cores with interrupt handling and degrade database transaction latencies.

---

## 2. Technical Comparisons & Architectural Trade-off Tables

### Matrix 1: Redundant Storage Topologies (Software RAID vs. Hardware RAID vs. ZFS/Btrfs)

| Feature / Metric | Software RAID (`mdadm`) | Hardware RAID Controller | ZFS / Btrfs (CoW Storage) |
| :--- | :--- | :--- | :--- |
| **Control Layer** | Linux Kernel (`md` driver) | Dedicated On-card ASIC/PICA | Kernel / ZFS C-module |
| **Hardware Portability** | **High**: Arrays assemble on any Linux kernel | **Low**: Requires identical controller vendor/firmware | **High**: Import pool on any OS supporting ZFS/Btrfs |
| **Write Hole Protection** | Requires Write-Intent Bitmap or PPL (Post-Log) | Hardware NVRAM with Battery-Backed Unit (BBU) | Guaranteed via Copy-on-Write (CoW) design |
| **Data Scrubbing / Integrity** | Patrol read via Sysfs (`check` action) | Controller background patrol | End-to-end checksum verification (sha256/fletcher4) |
| **Memory / CPU Overhead** | Low-to-Moderate (Calculates parity in RAM) | Zero CPU overhead (Offloaded to controller) | High (ARC cache and checksum calculation demands RAM) |
| **Recovery Latency** | Configurable speed limits via sysctl | Fixed by controller rebuild priority | Fast (Rebuilds only allocated data, not empty blocks) |

---

### Matrix 2: Block Storage Transport Protocols

| Protocol | Transport Layer | Overhead | Typical Latency | Routing Capabilities | Target Environment |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **iSCSI** | TCP/IP (Port 3260) | Moderate (Ethernet + IP + TCP + iSCSI framing) | 1–5 ms | Fully routable across Standard L2/L3 Networks | General Enterprise Data Centers & KVM Hypervisors |
| **Fibre Channel (FC)** | Dedicated FC Framing | Minimal (Hardware offload on HBA) | < 0.5 ms | Isolated FC Switched Fabric | High-throughput OLTP & legacy SAN environments |
| **NVMe-oF (RDMA/TCP)** | RoCE v2 / NVMe-TCP | Extremely Low | < 100 µs | Routable (NVMe-TCP) or L2 Converged Ethernet | Supercomputing, High-Frequency Trading & AI/ML |

---

### Matrix 3: LVM Storage Allocation Models

| Architectural Attribute | Thick Provisioned LVM (`lvcreate -L`) | Thin Provisioned LVM (`lvcreate -V -T`) | Direct Raw Block Device |
| :--- | :--- | :--- | :--- |
| **Storage Allocation** | Allocated fully upfront | Allocated dynamically on write | Allocated fully upfront |
| **Over-commit Capacity** | Unsupported | Supported (Thin Pool over-subscription) | Unsupported |
| **Performance Overhead** | Zero overhead | Minor metadata write allocation overhead | Lowest absolute latency |
| **Snapshot Efficiency** | Copy-on-Write (Degrades performance over time) | Redirect-on-Write (Pointer updates only, constant O(1)) | N/A (Requires file-level tools) |
| **Operational Risk** | Low (Out of space impossible if VG has space) | High (Pool exhaustion freezes all constituent LVs) | Low |

---

### Matrix 4: Multi-Queue Block Layer (`blk-mq`) I/O Schedulers

| Scheduler | Primary Use Case | Queuing Mechanism | Latency Profile | Best Hardware Match |
| :--- | :--- | :--- | :--- | :--- |
| **`none`** | High-performance hardware arrays | Direct passthrough to controller hardware queue | Lowest CPU overhead | High-end NVMe drives & Hardware SAN LUNs |
| **`mq-deadline`** | General read-heavy workloads | Separate Read/Write deadline queues (Read priority) | Guarantees read latency caps | Enterprise SATA/SAS SSDs |
| **`kyber`** | Multi-tenant latency-sensitive applications | Target read/synchronous request latency queues | Tight p99 latency bounds | Fast NVMe pools under heavy concurrent write load |
| **`bfq` (Budget Fair Queueing)** | Desktop / Interactive workloads | Per-process bandwidth budgeting | High fairness, higher CPU overhead | Rotational HDDs (SATA/SAS) |

---

## 3. Production Infrastructure Configurations & Syntactically Valid Manifests

### 3.1 Software RAID Configuration File (`/etc/mdadm.conf`)

This configuration registers an explicit RAID-5 array with write-intent metadata logging, custom device node naming, and automated email alert hooks for degraded states.

```ini
# /etc/mdadm.conf - Production Software RAID Configuration
# Reference: mdadm.conf(5)

# Device scanning directive to limit discovery to physical enterprise SAS/SATA nodes
DEVICE /dev/sd[b-e]1

# Global Mail configuration for daemon alerts
MAILADDR sre-storage-alerts@infrastructure.internal
MAILFROM mdadm-daemon@node01.infrastructure.internal
PROGRAM /usr/lib/mdadm/send-spares-handler

# Array Definitions
# ARRAY <device-node> metadata=<version> UUID=<unique-id> name=<host:alias>
ARRAY /dev/md/data_raid5 metadata=1.2 UUID=a8f4c21b:991e48ba:c810d4ff:7a1102e5 name=node01:data_raid5
   spares=1
```

---

### 3.2 iSCSI Target Export Setup Script (`targetcli`)

Syntactically valid Python/CLI automation script for `targetcli` to create an iSCSI Target (SAN server) presenting a block device with CHAP authentication.

```bash
#!/usr/bin/env bash
set -euo pipefail

# Provision iSCSI Target using targetcli commands non-interactively
targetcli /backstores/block create name=san_storage_block dev=/dev/vg_san/lv_san_data
targetcli /iscsi create iqn.2026-08.internal.infrastructure:storage.target01
targetcli /iscsi/iqn.2026-08.internal.infrastructure:storage.target01/tpg1/luns create /backstores/block/san_storage_block

# Enable CHAP Authentication
targetcli /iscsi/iqn.2026-08.internal.infrastructure:storage.target01/tpg1 set attribute authentication=1
targetcli /iscsi/iqn.2026-08.internal.infrastructure:storage.target01/tpg1 set auth userid=TargetUserSecret
targetcli /iscsi/iqn.2026-08.internal.infrastructure:storage.target01/tpg1 set auth password=TargetPasswordSecret123

# Create Access Control List (ACL) for the Initiator Node
targetcli /iscsi/iqn.2026-08.internal.infrastructure:storage.target01/tpg1/acls create iqn.2026-08.internal.infrastructure:node01.initiator
targetcli /iscsi/iqn.2026-08.internal.infrastructure:storage.target01/tpg1/acls/iqn.2026-08.internal.infrastructure:node01.initiator set auth userid=InitiatorUserSecret
targetcli /iscsi/iqn.2026-08.internal.infrastructure:storage.target01/tpg1/acls/iqn.2026-08.internal.infrastructure:node01.initiator set auth password=InitiatorPasswordSecret123

# Bind portal to all local IPv4 interfaces on default port 3260
targetcli /iscsi/iqn.2026-08.internal.infrastructure:storage.target01/tpg1/portals create 0.0.0.0 3260

# Save configuration persistently to /etc/rtslib-fb-target/saveconfig.json
targetcli saveconfig
```

---

### 3.3 iSCSI Initiator Configurations

#### Initiator Name Definition (`/etc/iscsi/initiatorname.iscsi`)
```ini
## /etc/iscsi/initiatorname.iscsi
## Uniquely identifies this initiator host to iSCSI Targets
InitiatorName=iqn.2026-08.internal.infrastructure:node01.initiator
```

#### Open-iSCSI Daemon Configuration (`/etc/iscsi/iscsid.conf`)
```ini
# /etc/iscsi/iscsid.conf - Production Initiator Configuration
# Reference: iscsid.conf(5)

iscsid.startup = /sbin/iscsid

# Automatic login on system boot
node.startup = automatic

# CHAP Authentication settings for Node sessions
node.session.auth.authmethod = CHAP
node.session.auth.username = TargetUserSecret
node.session.auth.password = TargetPasswordSecret123
node.session.auth.username_in = InitiatorUserSecret
node.session.auth.password_in = InitiatorPasswordSecret123

# Timeout & Retries for Network Stability Tuning
node.session.timeo.replacement_timeout = 120
node.conn[0].timeo.login_timeout = 15
node.conn[0].timeo.logout_timeout = 15
node.conn[0].timeo.noop_out_interval = 5
node.conn[0].timeo.noop_out_timeout = 5
node.session.iscsi.FastAbort = Yes
```

---

### 3.4 Device Mapper Multipath Configuration (`/etc/multipath.conf`)

This configuration handles dynamic path discovery, Asymmetric Logical Unit Access (ALUA) state prioritization, and transparent failover across SAN fabrics.

```conf
# /etc/multipath.conf - Production DM-Multipath Configuration
# Reference: multipath.conf(5)

defaults {
    user_friendly_names      yes
    find_multipaths          yes
    enable_foreign           "NONE"
    path_grouping_policy     group_by_prio
    path_checker             tur
    features                 "1 queue_if_no_path"
    hardware_handler         "1 alua"
    prio                     alua
    failback                 immediate
    rr_weight                uniform
    no_path_retry            12
    rr_min_io_rq             10
}

blacklist {
    devnode "^(td|hd|vd|xvd|mmcblk)[a-z0-9]*"
    devnode "^sd[a]$"
    wwid    "3600508e0000000000000000000000000"
}

multipaths {
    multipath {
        wwid                    36001405a12cd86b097b47e2a9b3d11b4
        alias                   san_block_vol01
        path_grouping_policy    multibus
        path_checker            tur
        failback                immediate
    }
}

devices {
    device {
        vendor                  "NETAPP"
        product                 "LUN.*"
        path_grouping_policy    group_by_prio
        prio                    alua
        path_checker            tur
        hardware_handler        "1 alua"
        failback                immediate
        no_path_retry           queue
    }
}
```

---

### 3.5 Storage Queue & Udev Tuning Rules (`/etc/udev/rules.d/99-storage-performance.rules`)

Automated rules enforcing specific queue parameters and schedulers based on storage type (NVMe SSD vs Rotational SATA vs SAN Multipath).

```udev
# /etc/udev/rules.d/99-storage-performance.rules
# Custom kernel block queue parameters for production workloads

# 1. NVMe Solid State Drives: Use 'none' scheduler, disable add_random, increase nr_requests
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none", ATTR{queue/add_random}="0", ATTR{queue/nr_requests}="1024", ATTR{queue/read_ahead_kb}="2048"

# 2. SAN Multipath Virtual Devices (dm-*): Set scheduler to 'none', optimize request queues
ACTION=="add|change", KERNEL=="dm-[0-9]*", SUBSYSTEM=="block", ATTR{queue/scheduler}="none", ATTR{queue/nr_requests}="512", ATTR{queue/read_ahead_kb}="4096"

# 3. Rotational Mechanical Hard Disks (SATA/SAS): Use 'mq-deadline', enable readahead
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline", ATTR{queue/read_ahead_kb}="1024", ATTR{queue/nr_requests}="256"
```

---

### 3.6 Systemd Mount & Automount Unit Files

#### Persistent Network Storage Mount Unit (`/etc/systemd/system/mnt-san-data.mount`)
```ini
[Unit]
Description=Production Enterprise SAN Storage Mount
Documentation=man:fstab(5) man:systemd.mount(5)
After=network-online.target open-iscsi.service multipathd.service
Wants=network-online.target open-iscsi.service multipathd.service
Requires=open-iscsi.service multipathd.service

[Mount]
What=/dev/mapper/san_block_vol01
Where=/mnt/san-data
Type=xfs
Options=_netdev,noatime,nodiratime,logbufs=8,logbsize=256k,allocsize=64M

[Install]
WantedBy=remote-fs.target
```

#### On-Demand Systemd Automount Unit (`/etc/systemd/system/mnt-san-data.automount`)
```ini
[Unit]
Description=Automount for Production SAN Storage
Documentation=man:systemd.automount(5)
After=network-online.target

[Automount]
Where=/mnt/san-data
TimeoutIdleSec=300

[Install]
WantedBy=multi-user.target
```

---

## 4. Hands-On CLI Execution & Real Terminal Outputs

### 4.1 Software RAID (`mdadm`) Operations

#### Creating a RAID-5 Array with a Live Hot Spare
```console
$ sudo mdadm --create /dev/md0 --level=5 --raid-devices=3 --spare-devices=1 /dev/sdb1 /dev/sdc1 /dev/sdd1 /dev/sde1
mdadm: Defaulting to version 1.2 metadata
mdadm: array /dev/md0 started.
```

#### Inspecting Detailed Array Health and Rebuild Status
```console
$ sudo mdadm --detail /dev/md0
/dev/md0:
           Version : 1.2
     Creation Time : Thu Aug  6 10:30:15 2026
        Raid Level : raid5
        Array Size : 41910272 (39.97 GiB 42.92 GB)
     Used Dev Size : 20955136 (19.98 GiB 21.46 GB)
      Raid Devices : 3
     Total Devices : 4
       Persistence : Superblock is present

     Intent Bitmap : Internal active
       State : clean 
Active Devices : 3
Working Devices : 4
Failed Devices : 0
 Spare Devices : 1

        Layout : left-symmetric
    Chunk Size : 512K

Consistency Policy : bitmap

          Name : node01:0  (local to host node01)
          UUID : a8f4c21b:991e48ba:c810d4ff:7a1102e5
        Events : 18

    Number   Major   Minor   RaidDevice State
       0       8       17        0      active sync   /dev/sdb1
       1       8       33        1      active sync   /dev/sdc1
       2       8       49        2      active sync   /dev/sdd1

       3       8       65        -      spare   /dev/sde1
```

#### Simulating Drive Failure, Hot-Removing, and Triggering Rebuild
```console
$ sudo mdadm /dev/md0 --fail /dev/sdc1
mdadm: set /dev/sdc1 faulty in /dev/md0

$ sudo mdadm --detail /dev/md0 | grep -E "(State|Device)"
       State : active, degraded, recovering 
Active Devices : 2
Working Devices : 3
Failed Devices : 1
 Spare Devices : 0
Rebuild Status : 14% complete
    Number   Major   Minor   RaidDevice State
       0       8       17        0      active sync   /dev/sdb1
       3       8       65        1      spare rebuilding   /dev/sde1
       2       8       49        2      active sync   /dev/sdd1
       1       8       33        -      faulty   /dev/sdc1

$ sudo mdadm /dev/md0 --remove /dev/sdc1
mdadm: hot removed /dev/sdc1 from /dev/md0
```

---

### 4.2 Low-Level Drive & Filesystem Parameter Tuning

#### Querying & Setting Hardware Parameters (`sdparm` & `hdparm`)
```console
$ sudo hdparm -I /dev/sdb | grep -A 4 "Capabilities"
	Capabilities:
		LBA, Logical Block Addressing Support
		Disabling IORDY permitted
		Queue depth: 32
		Capabilities: Standby timer values spoken here

$ sudo sdparm --get=WCE /dev/sdb
    /dev/sdb: SEAGATE   ST2000NX0253      NT01
WCE           1  [V_mode: 1]

# Enable Write Cache Enable (WCE) persistently on a SCSI/SAS disk
$ sudo sdparm --set=WCE --save /dev/sdb
    /dev/sdb: SEAGATE   ST2000NX0253      NT01
```

#### Ext4 Filesystem Attribute Tuning (`tune2fs`)
```console
$ sudo tune2fs -m 1 -O fast_commit,journal_data_writeback /dev/mapper/vg_data-lv_production
tune2fs 1.46.5 (30-Dec-2021)
Setting reserved blocks percentage to 1% (104857 blocks)
Filesystem features set 'fast_commit,journal_data_writeback'

$ sudo tune2fs -l /dev/mapper/vg_data-lv_production | grep -i "reserved block count"
Reserved block count:     104857
```

#### NVMe Controller & Queue Diagnostics (`nvme-cli`)
```console
$ sudo nvme list
Node             SN                   Model                                  Namespace Usage                      Format           FW Rev  
---------------- -------------------- -------------------------------------- --------- -------------------------- ---------------- --------
/dev/nvme0n1     S59BNX0R102938       SAMSUNG MZQL21T9HCJR-00A07             1           1.92  TB /   1.92  TB    512   B +  0 B   MPK7301Q

$ sudo nvme smart-log /dev/nvme0n1
Smart Log for NVME device:nvme0n1 namespace-id:ffffffff
critical_warning			: 0
temperature				: 33°C (306 K)
available_reserve			: 100%
percentage_used				: 1%
data_units_read				: 14,892,104 (7.62 TB)
data_units_written			: 42,109,211 (21.56 TB)
host_read_commands			: 189,201,442
host_write_commands			: 512,940,119
controller_busy_time			: 142
power_cycles				: 12
power_on_hours				: 2,410
unsafe_shutdowns			: 1
media_errors				: 0
num_err_log_entries			: 0
```

---

### 4.3 Advanced LVM2 Operations: Thin Pools & Live Data Migration (`pvmove`)

#### Creating Physical Volumes, Volume Group, and Thin Provisioning Pool
```console
$ sudo pvcreate /dev/sdb1 /dev/sdc1 /dev/sdd1
  Physical volume "/dev/sdb1" successfully created.
  Physical volume "/dev/sdc1" successfully created.
  Physical volume "/dev/sdd1" successfully created.

$ sudo vgcreate -s 4M vg_enterprise /dev/sdb1 /dev/sdc1 /dev/sdd1
  Volume group "vg_enterprise" successfully created

# Create a 50GB Thin Pool and a 200GB Thinly-Provisioned Volume (Over-provisioned)
$ sudo lvcreate -L 50G --thinpool tp_enterprise_pool vg_enterprise
  Thin pool volume with chunk size 64.00 KiB set to "vg_enterprise/tp_enterprise_pool".
  Logical volume "tp_enterprise_pool" created.

$ sudo lvcreate -V 200G --thin -n lv_app_data vg_enterprise/tp_enterprise_pool
  Logical volume "lv_app_data" created.
```

#### Creating Copy-on-Write Logical Volume Snapshots
```console
$ sudo lvcreate --size 10G --snapshot --name lv_app_data_snap /dev/vg_enterprise/lv_app_data
  Logical volume "lv_app_data_snap" created.

$ sudo lvs vg_enterprise/lv_app_data_snap
  LV                VG            Attr       LSize  Pool Origin      Data%  Meta%  Move Log Cpy%Sync Convert
  lv_app_data_snap  vg_enterprise s-wi-a--- 10.00g      lv_app_data  0.02
```

#### Performing Live Online Disk Migration (`pvmove`) Without Downtime
```console
$ sudo pvmove -v /dev/sdb1 /dev/sdd1
  Cluster snapshot status summary: 0 logical volumes configured.
  Moving 5120 extents of logical volume vg_enterprise/tp_enterprise_pool.
  Preparing finished.
  Un-suspending origin volume...
  /dev/sdb1: Moved: 0.00%
  /dev/sdb1: Moved: 24.50%
  /dev/sdb1: Moved: 68.20%
  /dev/sdb1: Moved: 100.00%
  Updated volume group metadata.
```

---

### 4.4 iSCSI Target Discovery & Device-Mapper Multipath Management

#### Target Discovery & Session Login
```console
$ sudo iscsiadm -m discovery -t sendtargets -p 192.168.10.50:3260
192.168.10.50:3260,1 iqn.2026-08.internal.infrastructure:storage.target01

$ sudo iscsiadm -m node -T iqn.2026-08.internal.infrastructure:storage.target01 -p 192.168.10.50:3260 --login
Logging in to [iface: default, target: iqn.2026-08.internal.infrastructure:storage.target01, portal: 192.168.10.50,3260]
Login to [iface: default, target: iqn.2026-08.internal.infrastructure:storage.target01, portal: 192.168.10.50,3260] successful.
```

#### Inspecting Active iSCSI Sessions
```console
$ sudo iscsiadm -m session -P 1
Target: iqn.2026-08.internal.infrastructure:storage.target01 (node01)
	Current Portal: 192.168.10.50:3260,1
	Persistent Portal: 192.168.10.50:3260,1
		---------- Session State ----------
		State: LOGGED_IN
		Session Target Name: iqn.2026-08.internal.infrastructure:storage.target01
		Credentials: Username: TargetUserSecret
		Attached scsi disk sdf State: Running
```

#### Verifying Device-Mapper Multipath Topology (`multipath -ll`)
```console
$ sudo multipath -ll
san_block_vol01 (36001405a12cd86b097b47e2a9b3d11b4) dm-2 NETAPP,LUN C-Mode
size=500G features='1 queue_if_no_path' hwhandler='1 alua' wp=rw
|-+- policy='group-by-prio 0' prio=50 status=active
| |- 2:0:0:0 sdd 8:48 active ready running
| `- 3:0:0:0 sde 8:64 active ready running
`-+- policy='group-by-prio 0' prio=10 status=enabled
  |- 4:0:0:0 sdf 8:80 active ghost retention
  `- 5:0:0:0 sdg 8:96 active ghost retention
```

---

## 5. SRE Diagnostic & Failure Recovery Guide

```
             +--------------------------------------------------+
             |         Storage Failure Event Detected           |
             +--------------------------------------------------+
                                      |
                                      v
             +--------------------------------------------------+
             | Is it a Hardware, Network Path, or Metadata Issue?|
             +--------------------------------------------------+
               /                      |                       \
              /                       |                        \
  [ Hardware Sector / RAID ]     [ Network / iSCSI Path ]     [ LVM Metadata Fault ]
             |                        |                        |
             v                        v                        v
  1. Check dmesg / smartctl   1. Inspect iscsiadm session  1. Locate backup in
  2. Query mdadm status       2. Verify multipath -ll         /etc/lvm/backup/
  3. Replace drive & sync     3. Query dmsetup status      2. Run vgcfgrestore
```

### Scenario 1: Degraded Software RAID Array Recovery

**Symptom**: Kernel reports I/O errors; `mdadm` marks drive as faulty.

1. **Locate Failed Component**:
   ```console
   $ sudo dmesg -T | grep -E "(sector|I/O error|md0)"
   [Thu Aug  6 10:45:12 2026] sd 2:0:0:1: [sdc] FAILED Result: hostbyte=DID_OK driverbyte=DRIVER_OK
   [Thu Aug  6 10:45:12 2026] sd 2:0:0:1: [sdc] CDB: Read(10) 28 00 00 a1 b2 c0 00 00 08 00
   [Thu Aug  6 10:45:12 2026] blk_update_request: I/O error, dev sdc, sector 10597056 op 0x0:(READ) flags 0x0 phys_seg 1 prio class 0
   [Thu Aug  6 10:45:13 2026] md/raid5:md0: Device /dev/sdc1 failed, disabling device.
   ```

2. **Isolate Physical Disk Serial Number via `smartctl`**:
   ```console
   $ sudo smartctl -i /dev/sdc | grep "Serial Number"
   Serial Number:     WCC4M7XU8912
   ```

3. **Replace Physical Disk and Re-create Partition Table**:
   ```console
   # Copy partition layout identically from a working array member (/dev/sdb) to new disk (/dev/sdc)
   $ sudo sfdisk -d /dev/sdb | sudo sfdisk /dev/sdc
   Checking that no-one is using this disk right now ... OK
   Successfully wrote the new partition table
   ```

4. **Hot-Add New Disk Partition to RAID Array**:
   ```console
   $ sudo mdadm --manage /dev/md0 --add /dev/sdc1
   mdadm: added /dev/sdc1 to /dev/md0
   ```

---

### Scenario 2: LVM2 Metadata Corruption and Volume Group Recovery

**Symptom**: `vgdisplay` fails with "Volume group not found" or reports invalid metadata headers after accidental block overwrites.

1. **Locate Automated LVM Metadata Backup**:
   LVM2 automatically maintains text-based metadata history in `/etc/lvm/backup/` and `/etc/lvm/archive/`.
   ```console
   $ sudo ls -la /etc/lvm/backup/
   total 16
   -rw------- 1 root root 2415 Aug  6 09:12 vg_enterprise
   ```

2. **Inspect the Physical Volume UUID Requirements**:
   ```console
   $ sudo head -n 25 /etc/lvm/backup/vg_enterprise
   # Generated by LVM2 version 2.03.11(2) (2021-01-08): Thu Aug  6 09:12:00 2026

   contents = "Text Format Volume Group"
   version = 1

   vg_enterprise {
       id = "x8A9k1-M7p2-9011-LKs2-0199-mKls-910293"
       seqno = 4
       format = "lvm2"
       
       physical_volumes {
           pv0 {
               id = "a1b2c3-d4e5-6789-0123-4567-890a-bcdef0"
               device = "/dev/sdb1"
           }
       }
   }
   ```

3. **Restore Physical Volume Metadata UUID**:
   ```console
   $ sudo pvcreate --uuid "a1b2c3-d4e5-6789-0123-4567-890a-bcdef0" --restorefile /etc/lvm/backup/vg_enterprise /dev/sdb1
   Physical volume "/dev/sdb1" successfully created with UUID a1b2c3-d4e5-6789-0123-4567-890a-bcdef0
   ```

4. **Restore Volume Group Configuration**:
   ```console
   $ sudo vgcfgrestore -f /etc/lvm/backup/vg_enterprise vg_enterprise
   Restored volume group vg_enterprise.

   $ sudo vgscan && sudo vgchange -ay vg_enterprise
   Found volume group "vg_enterprise" using metadata type lvm2
   1 logical volume(s) in volume group "vg_enterprise" now active
   ```

---

### Scenario 3: SAN Path Interruption & DM-Multipath Diagnostics

**Symptom**: File operations hang; kernel reports multipath device errors.

1. **Inspect Low-level Device-Mapper Table**:
   ```console
   $ sudo dmsetup table san_block_vol01
   0 1048576000 multipath 1 queue_if_no_path 1 alua 2 1 group-by-prio 0 2 1 8:48 A 0 8:64 A 0 group-by-prio 0 2 0 8:80 F 0 8:96 F 0
   ```
   *(Note: `A` indicates Active path; `F` indicates Failed path).*

2. **Check iSCSI Connection Status for Dropped Connections**:
   ```console
   $ sudo iscsiadm -m session -o show | grep -i "Network Failure"
   iSCSI Connection State: LOGGED_OUT (Network Failure Timeout)
   ```

3. **Force Path Re-scan and Multipath Daemon Reload**:
   ```console
   $ sudo iscsiadm -m node --loginall=all
   $ sudo multipath -r
   $ sudo multipathd show paths format "%n %d %t %T %s"
   dev dev_t target WWNN               status
   sdd 8:48   0x200000a098001122       active
   sde 8:64   0x200000a098001123       active
   ```

---

### Scenario 4: Deep Block Queue I/O Latency Diagnosis

**Symptom**: Application experiences high p99 write latency spikes; database throughput collapses.

1. **Collect Real-time Block Device Queue Metrics (`iostat`)**:
   ```console
   $ sudo iostat -xz 1 3
   Device            r/s     w/s     rkB/s     wkB/s   rrqm/s  wrqm/s  r_await  w_await aqu-sz  rareq-sz  wareq-sz  %util
   nvme0n1         15.00 4500.00    120.00 288000.00     0.00 1200.00     0.12    18.40   82.80     8.00     64.00  98.40
   sda              0.00    2.00      0.00     16.00     0.00    1.00     0.00     1.50    0.00      0.00      8.00   0.40
   ```
   *(Diagnostic: `aqu-sz` (Average Queue Size) of 82.80 combined with `w_await` > 18ms indicates heavy request queue backlog on `nvme0n1`).*

2. **Trace Block Layer Queue Latency Distribution (`blktrace`)**:
   ```console
   $ sudo blktrace -d /dev/nvme0n1 -o - | blkparse -i -
   8,0    1        1     0.000000000  1294  Q   W 2097152 + 128 [postgres]
   8,0    1        2     0.000003112  1294  G   W 2097152 + 128 [postgres]
   8,0    1        3     0.000005421  1294  I   W 2097152 + 128 [postgres]
   8,0    1        4     0.000009120  1294  D   W 2097152 + 128 [postgres]
   8,0    1        5     0.018210441     0  C   W 2097152 + 128 [0]
   ```
   *(Analysis: Time spent between issue `D` and completion `C` is 18.2ms, isolating latency to hardware controller execution rather than OS kernel queuing `Q` to `D`).*

3. **Remediation Strategy**: Adjust block queue depth and scheduler settings dynamically:
   ```console
   $ echo "none" | sudo tee /sys/block/nvme0n1/queue/scheduler
   $ echo "2048" | sudo tee /sys/block/nvme0n1/queue/nr_requests
   ```

---

## 6. References

- **Linux Professional Institute LPIC-2 Official Overview & Objectives**: [https://www.lpi.org/our-certifications/lpic-2-overview/](https://www.lpi.org/our-certifications/lpic-2-overview/)
- **Linux Kernel Block Layer Documentation**: [https://www.kernel.org/doc/html/latest/block/index.html](https://www.kernel.org/doc/html/latest/block/index.html)
- **Open-iSCSI Official Documentation & Admin Guide**: [https://github.com/open-iscsi/open-iscsi](https://github.com/open-iscsi/open-iscsi)
- **Red Hat Enterprise Linux Storage Administration Guide**: [https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/managing_storage_devices/](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/managing_storage_devices/)
- **Multipath-Tools Source & Man Pages**: [https://github.com/opensvc/multipath-tools](https://github.com/opensvc/multipath-tools)
- **LVM2 Architecture and Command Reference**: [https://sourceware.org/lvm2/](https://sourceware.org/lvm2/)