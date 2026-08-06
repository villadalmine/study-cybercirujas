# LPIC-2: Advanced Storage Device Administration (Topic 204 / Theme 1.5)
**Exam Weight:** 7  
**Target Certification:** LPIC-2 (Exams 201-450 & 202-450, Version 4.5)  
**Target Audience:** SREs, Platform Engineers, and Linux Systems Administrators  

---

## 1. Deep Technical Architecture & Theoretical Foundation

### 1.1 The Linux Block I/O Layer Architecture
The Linux storage stack abstracts heterogeneous physical hardware into block devices presented under `/dev/`. I/O requests traverse multiple abstraction layers before reaching the physical medium:

```
+-----------------------------------------------------------------------+
|                    Virtual File System (VFS)                          |
|                       (ext4, xfs, btrfs)                              |
+-----------------------------------------------------------------------+
|                       Page Cache / Buffer Cache                       |
+-----------------------------------------------------------------------+
|                    Generic Block Layer (bio structs)                  |
+-----------------------------------------------------------------------+
|  Device Mapper (dm)   |  Multiple Devices (md) | Block Interface      |
|  (LVM2, Thin, Cache)  |  (Software RAID)       | (Loop, NVMe, SCSI)    |
+-----------------------------------------------------------------------+
|                     Multi-Queue Block Layer (blk-mq)                  |
|                 Software Queues (per-CPU) -> Hardware Queues          |
+-----------------------------------------------------------------------+
|                    I/O Scheduler (BFQ, Kyber, mq-deadline, none)      |
+-----------------------------------------------------------------------+
|                Low-Level Drivers (nvme, ahci, mpt3sas)                |
+-----------------------------------------------------------------------+
|                 Physical Storage (NVMe SSD, SATA HDD, SAN LUN)        |
+-----------------------------------------------------------------------+
```

1. **VFS & Page Cache**: High-level system calls (`read`, `write`, `fsync`) interact with standard OS memory structures.
2. **Generic Block Layer**: Converts file system operations into `struct bio` instances representing contiguous block range operations.
3. **Device Mapper (DM) & Multiple Devices (MD)**: Virtual block device frameworks that remap sector addresses. DM underpins LVM2, LUKS, and multipathing; MD powers kernel software RAID.
4. **blk-mq (Multi-Queue Block Subsystem)**: Maps per-CPU submission queues directly to hardware dispatch queues, removing legacy global lock bottlenecks (`blk-sq`) and supporting millions of IOPS on modern NVMe drives.
5. **I/O Schedulers**: Optimize disk requests based on underlying latency characteristics.

---

### 1.2 Linux Software RAID (MD Driver)
The `md` (Multiple Devices) kernel module operates directly above raw block devices, providing software-defined striping, mirroring, and parity.

```
       +------------------------------------+
       |          /dev/md0 (RAID 5)         |
       +------------------------------------+
       |  MD Kernel Driver (Parity Calc)    |
       +------------------+-----------------+
                          |
     +--------------------+--------------------+
     |                    |                    |
+----+----+          +----+----+          +----+----+
| /dev/sdb|          | /dev/sdc|          | /dev/sdd|
| (Data)  |          | (Data)  |          | (Parity)|
+---------+          +---------+          +---------+
```

#### RAID Metadata Superblock Versions
* **Version 0.90**: Legacy metadata format placed at the end of the device. Limited to 28 component devices and 2TB array sizes.
* **Version 1.0**: Located at the end of the device (enables bootloaders to read data directly as a standard partition).
* **Version 1.1**: Located at the beginning of the device (offset 0).
* **Version 1.2 (Default)**: Located 4KiB from the start of the device. Leaves space for bootloaders while protecting metadata from overwrite.

#### Write-Intent Bitmaps
When an array component fails or goes offline temporarily, mdadm tracks changed blocks in a **Write-Intent Bitmap** (internal or external). Upon device re-addition, the kernel performs a fast differential resync (`re-add`) rather than a full array rebuild.

---

### 1.3 Logical Volume Manager (LVM2) Mechanics
LVM2 utilizes the Device Mapper kernel framework (`dm-mod`) to provide flexible logical volume management.

```
+-------------------------------------------------------------------------+
| Logical Volume (LV)         | /dev/vg_prod/lv_app (Thin / Mirrored)     |
+-------------------------------------------------------------------------+
| Volume Group (VG)           | vg_prod (Pool of Physical Extents)        |
+-------------------------------------------------------------------------+
| Physical Volume (PV)        | /dev/sdb1               | /dev/sdc1       |
+-------------------------------------------------------------------------+
| Partition / Disk            | /dev/sdb                | /dev/sdc        |
+-------------------------------------------------------------------------+
```

* **Physical Extents (PE)**: Allocation units (default 4MiB) that compose a Volume Group.
* **Logical Extents (LE)**: Mapped 1:1 to Physical Extents in linear LVs, or interleaved across PVs in striped/RAID LVs.
* **Metadata Structure**: LVM descriptors are written to the Physical Volume Header area in ASCII/JSON-like format. `vgcfgbackup` dumps this state to `/etc/lvm/backup/`.
* **Copy-on-Write (COW) vs. Thin Provisioning**:
  * **Traditional COW Snapshots**: When data in the origin LV changes, the original block is copied to the snapshot volume before being overwritten. Write latency increases as snapshot count grows ($O(N)$ write penalty).
  * **Thin Provisioning Snapshots**: Uses a dedicated data/metadata pool. Allocates blocks on demand via a virtual block allocation table ($O(1)$ allocation), enabling instantaneous, low-overhead space allocation.

---

### 1.4 Architectural Trade-Off Analysis

| Feature / Metric | RAID 1 | RAID 5 | RAID 10 | LVM Thick (Linear) | LVM Thin Provisioning |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Fault Tolerance** | 1 disk per mirror pair | 1 disk max | 1 disk per mirror pair | None (inherits underlying PV) | None (inherits underlying PV) |
| **Storage Efficiency** | 50% | $(N-1)/N$ | 50% | 100% allocated | Up to >100% (Overcommit) |
| **Random Write Overhead** | 2 Writes (Data + Mirror) | 4 IOPS (Read D/P, Write D/P) | 2 Writes | Minimal | Metadata update on alloc |
| **Snapshot Overhead** | N/A | N/A | N/A | High COW write amplification | Negligible ($O(1)$ metadata) |
| **Overcommit Risk** | None | None | None | None | **High** (Pool exhaustion brings volume offline) |

---

### 1.5 Official References & Documentation
* [LPI LPIC-2 Certification Overview](https://www.lpi.org/our-certifications/lpic-2-overview/)
* [Linux Kernel MD Driver Documentation](https://www.kernel.org/doc/html/latest/driver-api/md/md.html)
* [LVM2 Administration Manual (Red Hat / Linux Docs)](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_and_managing_logical_volumes/index)
* [Linux Block Layer & blk-mq Kernel Documentation](https://www.kernel.org/doc/html/latest/block/index.html)

---

## 2. Guided Production Lab Exercises

### Block 1: Linux Software RAID Creation, Maintenance, and Fault Injection

#### Step 1: Create a RAID 5 Array with an Internal Write-Intent Bitmap and Hot Spare
Execute `mdadm` to construct a RAID 5 array named `/dev/md0` using 3 active block devices (`/dev/sdb`, `/dev/sdc`, `/dev/sdd`) and 1 spare device (`/dev/sde`), specifying v1.2 metadata and an internal bitmap.

```bash
sudo mdadm --create /dev/md0 \
  --level=5 \
  --raid-devices=3 \
  --spare-devices=1 \
  --metadata=1.2 \
  --bitmap=internal \
  /dev/sdb /dev/sdc /dev/sdd /dev/sde
```

**Expected Command Output:**
```text
mdadm: /dev/sdb appears to contain an logs filesystem -- continue verification? yes
mdadm: Defaulting to version 1.2 metadata
mdadm: array /dev/md0 started.
```

#### Step 2: Query Array Runtime Status and Inspect Metadata
Monitor real-time sync progress via `/proc/mdstat` and retrieve detailed array attributes:

```bash
cat /proc/mdstat
```

**Expected Command Output:**
```text
Personalities : [raid6] [raid5] [raid4] 
md0 : active raid5 sdd[2] sde[3](S) sdc[1] sdb[0]
      4188160 blocks super 1.2 level 5, 512k chunk, algorithm 2 [3/3] [UUU]
      bitmap: 0/1 pages [0KB], 65536KB chunk

unused devices: <none>
```

Execute a detail query on `/dev/md0`:

```bash
sudo mdadm --detail /dev/md0
```

**Expected Command Output:**
```text
/dev/md0:
           Version : 1.2
     Creation Time : Thu Aug  6 10:30:00 2026
        Raid Level : raid5
        Array Size : 4188160 (3.99 GiB 4.29 GB)
     Used Dev Size : 2094080 (2.00 GiB 2.14 GB)
      Raid Devices : 3
     Total Devices : 4
       Persistence : Superblock is present

     Intent Bitmap : Internal
        State : clean 
Active Devices : 3
Working Devices : 4
 Failed Devices : 0
  Spare Devices : 1

        Layout : left-symmetric
    Chunk Size : 512K

Consistency Policy : bitmap

          Name : storage-node-01:0  (local to host storage-node-01)
          UUID : e4a123bc:89f1023a:771b9c0d:12ef3456
        Events : 12

    Number   Major   Minor   RaidDevice State
       0       8       16        0      active sync   /dev/sdb
       1       8       32        1      active sync   /dev/sdc
       2       8       48        2      active sync   /dev/sdd

       3       8       64        -      spare   /dev/sde
```

#### Step 3: Persist Array Configuration to `mdadm.conf`
Generate the persistent system mapping file to ensure predictable initialization across system reboots:

```bash
sudo mkdir -p /etc/mdadm
sudo mdadm --detail --scan | sudo tee /etc/mdadm/mdadm.conf
```

**Syntactically Valid `/etc/mdadm/mdadm.conf` Manifest:**
```text
# /etc/mdadm/mdadm.conf
# Automatically generated configuration file for mdadm software RAID arrays.
MAILADDR admin@infrastructure.internal
ARRAY /dev/md0 metadata=1.2 name=storage-node-01:0 UUID=e4a123bc:89f1023a:771b9c0d:12ef3456
```

#### Step 4: Inject Failure, Verify Auto-Rebuild, and Re-add Hot Spare
Simulate a disk hardware failure on `/dev/sdb` to test hot-spare auto-reconstruction:

```bash
sudo mdadm --manage /dev/md0 --fail /dev/sdb
```

**Expected Command Output:**
```text
mdadm: set /dev/sdb faulty in /dev/md0
```

Check the array status immediately to observe the automatic activation of `/dev/sde`:

```bash
sudo mdadm --detail /dev/md0 | grep -E "(State|Device)"
```

**Expected Command Output:**
```text
        State : clean, degraded, recovering 
Active Devices : 2
Working Devices : 3
 Failed Devices : 1
  Spare Devices : 0
Rebuild Status : 35% complete
    Number   Major   Minor   RaidDevice State
       3       8       64        0      spare rebuild   /dev/sde
       1       8       32        1      active sync   /dev/sdc
       2       8       48        2      active sync   /dev/sdd

       0       8       16        -      faulty   /dev/sdb
```

Remove the faulty disk and add a replacement device:

```bash
sudo mdadm --manage /dev/md0 --remove /dev/sdb
sudo mdadm --manage /dev/md0 --add /dev/sdf
```

---

### Questions — Block 1
1. **Q1.1**: What specific operational advantage does an *internal write-intent bitmap* offer when a failed member disk in a RAID 5 array is temporarily disconnected and then re-added, compared to an array configured without a bitmap?
2. **Q1.2**: Why is it dangerous to rely solely on array auto-assembly via device scans (`mdadm --assemble --scan`) without explicitly mapping UUIDs in `/etc/mdadm/mdadm.conf` on systems with multiple storage controllers?

---

### Block 2: Advanced Storage Tuning, NVMe Diagnostics, and Persistent udev Rules

#### Step 1: Query Block Layer Queue Parameters & NVMe Health Metrics
Inspect current I/O scheduler algorithms, read-ahead buffer sizes, and rotational flags for storage devices:

```bash
cat /sys/block/sda/queue/scheduler
cat /sys/block/sda/queue/read_ahead_kb
cat /sys/block/sda/queue/rotational
```

**Expected Command Output:**
```text
[mq-deadline] bfq kyber none
128
0
```

Use `nvme-cli` to inspect controller health, temperature thresholds, and Endurance Group critical warnings on an NVMe device (`/dev/nvme0n1`):

```bash
sudo nvme smart-log /dev/nvme0n1
```

**Expected Command Output:**
```text
Smart Log for NVMe device:nvme0n1 namespace-id:1
critical_warning                    : 0
temperature                         : 38 C
available_spare                     : 100%
available_spare_threshold           : 10%
percentage_used                     : 2%
data_units_read                     : 14523910
data_units_written                  : 9812404
host_read_commands                  : 120482103
host_write_commands                 : 89341201
controller_busy_time                : 412
power_cycles                        : 14
power_on_hours                      : 1240
unsafe_shutdowns                    : 2
media_errors                        : 0
num_err_log_entries                 : 0
```

#### Step 2: Implement Persistent udev Performance Rules
Construct a custom udev rule `/etc/udev/rules.d/99-storage-performance.rules` to automatically enforce optimal I/O schedulers and read-ahead settings depending on device transport type (NVMe SSD vs. Rotational SATA HDD).

**Syntactically Valid `/etc/udev/rules.d/99-storage-performance.rules` Manifest:**
```udev
# /etc/udev/rules.d/99-storage-performance.rules
# Production tuning for Enterprise Block Storage Devices

# Rule 1: Set non-rotational NVMe devices to 'none' (bypass I/O scheduler overhead for blk-mq)
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none", ATTR{queue/read_ahead_kb}="256"

# Rule 2: Set non-rotational SATA/SAS SSDs to 'mq-deadline'
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline", ATTR{queue/read_ahead_kb}="128"

# Rule 3: Set rotational HDDs to 'bfq' and optimize read-ahead for sequential access
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq", ATTR{queue/read_ahead_kb}="2048"
```

#### Step 3: Trigger and Validate udev Rule Execution
Reload the udev control daemon and trigger rule processing across block devices without rebooting:

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=block
```

Verify that settings were properly applied to an NVMe drive:

```bash
udevadm info --query=property --name=/dev/nvme0n1 | grep -E "(DEVNAME|SUBSYSTEM)"
cat /sys/block/nvme0n1/queue/scheduler
```

**Expected Command Output:**
```text
[none] mq-deadline bfq kyber
```

---

### Questions — Block 2
1. **Q2.1**: Why is configuring the I/O scheduler to `none` (or `noop`) recommended for modern NVMe solid-state drives operating on the `blk-mq` kernel architecture?
2. **Q2.2**: If `percentage_used` in `nvme smart-log` reaches 100%, does the drive immediately experience hard hardware failure? Explain the metric's technical meaning.

---

### Block 3: Advanced LVM2 Architecture: Thin Provisioning, Mirrored LVs, and COW Snapshots

#### Step 1: Initialize Physical Volumes and Volume Group
Initialize `/dev/md0` and `/dev/sdf` as LVM Physical Volumes, then create a Volume Group named `vg_production` with a custom Physical Extent (PE) size of 8MiB:

```bash
sudo pvcreate /dev/md0 /dev/sdf
sudo vgcreate -s 8M vg_production /dev/md0 /dev/sdf
```

**Expected Command Output:**
```text
  Physical volume "/dev/md0" successfully created.
  Physical volume "/dev/sdf" successfully created.
  Volume group "vg_production" successfully created
```

#### Step 2: Configure an LVM Thin Pool and Thin Logical Volume
Create a 2GiB Thin Pool (`thinpool_data`) within `vg_production`. Then provision a 10GiB Thin Logical Volume (`lv_app_data`) from the pool (demonstrating overcommit):

```bash
sudo lvcreate -L 2G --thinpool thinpool_data vg_production
sudo lvcreate -V 10G --thin -n lv_app_data vg_production/thinpool_data
```

**Expected Command Output:**
```text
  Thin pool metadata block size is 64.00 KiB.
  Logical volume "thinpool_data" created.
  Logical volume "lv_app_data" created.
```

Inspect thin allocation statistics using `lvs`:

```bash
sudo lvs -o lv_name,vg_name,lv_size,data_percent,metadata_percent,thin_prov_volume vg_production
```

**Expected Command Output:**
```text
  LV           VG            LSize  Data%  Meta%  Thin
  lv_app_data  vg_production 10.00g 0.00   0.00       
  thinpool_data vg_production  2.00g 0.00   10.55      
```

#### Step 3: Configure Automated Thin Pool Extension in `lvm.conf`
Edit `/etc/lvm/lvm.conf` to automatically extend thin pools when usage thresholds are crossed, protecting against out-of-space allocation panics.

**Partial Manifest for `/etc/lvm/lvm.conf`:**
```text
activation {
    ...
    thin_pool_autoextend_threshold = 80
    thin_pool_autoextend_percent = 20
    ...
}
```

*Explanation*: When pool allocation reaches **80%**, LVM auto-extends the thin pool by **20%** of its current size using available space in the Volume Group.

#### Step 4: Create a Snapshot and Perform a Snapshot Merge Operation
Format and mount `lv_app_data`, write test files, create a COW snapshot, simulate corrupting changes, and revert the volume using `lvconvert --merge`.

```bash
sudo mkfs.xfs /dev/vg_production/lv_app_data
sudo mkdir -p /mnt/appdata
sudo mount /dev/vg_production/lv_app_data /mnt/appdata
echo "Production State V1" | sudo tee /mnt/appdata/state.txt
```

Create a snapshot named `snap_lv_app_data`:

```bash
sudo lvcreate -s -n snap_lv_app_data /dev/vg_production/lv_app_data
```

Corrupt data on the origin volume:

```bash
echo "Corrupted State V2" | sudo tee /mnt/appdata/state.txt
sudo umount /mnt/appdata
```

Merge the snapshot back into the origin volume to restore the state:

```bash
sudo lvconvert --merge /dev/vg_production/snap_lv_app_data
```

**Expected Command Output:**
```text
  Merging of volume vg_production/snap_lv_app_data started.
  vg_production/lv_app_data: Merged: 100.00%
```

Remount and verify data restoration:

```bash
sudo mount /dev/vg_production/lv_app_data /mnt/appdata
cat /mnt/appdata/state.txt
```

**Expected Command Output:**
```text
Production State V1
```

---

### Questions — Block 3
1. **Q3.1**: What catastrophic event occurs if an LVM Thin Pool reaches 100% data space allocation while thin logical volumes have unfulfilled write requests pending?
2. **Q3.2**: How does the kernel handle an active `lvconvert --merge` operation on an origin volume that is currently mounted and busy?

---

## 3. Diagnostic & Troubleshooting Mechanics

When storage issues arise in high-availability environments, SREs must systematically locate failure points using low-level kernel interfaces.

### Diagnostic Matrix & Command Flow

```
  +-----------------------+
  | Storage Anomaly Detected |
  +-----------+-----------+
              |
              v
   Check Device Mapper Status
   `dmsetup status` / `dmsetup table`
              |
     +--------+--------+
     |                 |
     v                 v
[ RAID Failure ]  [ LVM Thin Pool Exhaustion ]
`mdadm --detail`  `lvs -a -o +thin_count,data_percent`
     |                 |
     v                 v
[ Re-add Spare ]  [ Extend Thin Pool / VG ]
`mdadm --add`     `lvextend -L +XG vg/pool`
```

#### Diagnostic Script: Storage Layer Integrity Verification
Run the following bash script to audit MD RAID arrays, LVM Thin Pools, and block device transport errors across the system:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "=========================================="
echo " 1. MD RAID Array Health Summary"
echo "=========================================="
if [ -f /proc/mdstat ]; then
    cat /proc/mdstat
else
    echo "No MD driver loaded."
fi

echo ""
echo "=========================================="
echo " 2. LVM Thin Pool Allocation Check"
echo "=========================================="
sudo lvs -a -o lv_name,vg_name,attr,size,data_percent,metadata_percent | grep -E "t[a-z-]" || echo "No Thin Pools found."

echo ""
echo "=========================================="
echo " 3. Kernel I/O Error Audit (dmesg)"
echo "=========================================="
sudo dmesg -T --level=err,crit,alert | grep -E "(blk_update_request|I/O error|nvme|md0)" || echo "No critical block device errors in dmesg."
```

---

<details>
<summary>Click to expand Answers & Detailed Explanations</summary>

### Block 1 Answers

#### **A1.1**:
An internal write-intent bitmap tracks out-of-sync blocks using a coarse-grained bit map where each bit represents a chunk of disk space (e.g., 64KB). When a disk fails or is disconnected, writes continue to the remaining active array members, and only the corresponding bits in the bitmap are flagged as dirty. 

When the disk is re-added, `mdadm` reads the bitmap and performs a **differential resync** (re-adding only dirty blocks) instead of a full reconstruction. This reduces recovery time from hours to seconds and prevents heavy I/O degradation across the storage array.

#### **A1.2**:
Relying purely on device name scans (`/dev/sd*`) during boot is non-deterministic because modern Linux kernels enumerate storage controllers and block devices asynchronously in parallel. As a result, `/dev/sdb` during boot $N$ could become `/dev/sdc` during boot $N+1$. 

Without explicit `UUID` definitions pinned in `/etc/mdadm/mdadm.conf`, the system may fail to assemble arrays properly or assemble wrong devices together, potentially leading to array corruption or boot failure.

---

### Block 2 Answers

#### **A2.1**:
Legacy I/O schedulers (`bfq`, `mq-deadline`) were designed to minimize mechanical seek overhead on single-queue spinning hard drives by reordering requests. Modern NVMe drives use the multi-queue subsystem (`blk-mq`), exposing up to 64,000 parallel hardware submission queues with hardware-level parallelism. 

Passing requests through a software-level CPU scheduler introduces unnecessary CPU locking, memory allocation overhead, and instruction context switches. Setting the scheduler to `none` allows requests to pass directly from per-CPU software queues to NVMe hardware queues, maximizing IOPS and minimizing latency.

#### **A2.2**:
No. `percentage_used` in NVMe SMART data is an **endurance rating indicator** calculated by the device vendor based on write cycle limits (TBW - Total Bytes Written) for the Flash NVM media. 

A value of 100% means the drive has reached its vendor-guaranteed write endurance limit. The drive may continue operating normally for a substantial period, but the risk of flash cell degradation increases, and manufacturer warranty coverage typically expires.

---

### Block 3 Answers

#### **A3.1**:
If a Thin Pool reaches 100% data space allocation, the Device Mapper driver cannot allocate new physical blocks for incoming write requests. Depending on the `error_if_no_space` configuration parameter in LVM:
1. The kernel blocks I/O operations indefinitely waiting for space, causing application threads to hang in Uninterruptible Sleep (`D` state).
2. Or, I/O requests immediately fail with `EIO` (Input/Output Error), causing file systems (such as XFS or ext4) to remount **Read-Only** or panic to preserve metadata consistency.

#### **A3.2**:
If the origin logical volume is mounted and active when `lvconvert --merge` is executed, the Device Mapper driver registers a **deferred merge operation**. The snapshot merge will automatically begin on the next system reboot when the origin LV is activated, or as soon as the file system is unmounted and the volume group is refreshed via `vgchange -an` / `vgchange -ay`.

</details>