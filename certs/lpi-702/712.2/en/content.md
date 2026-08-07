# Topic 712.2: Create File Systems and Maintain Their Integrity

**Certification:** LPI BSD Specialist (Exam 702-100, Version 1.0)  
**Topic Weight:** 1.67  

---

## 1. Production Architecture Motivation & Problem Statement

In enterprise BSD production environments—ranging from high-throughput storage appliances and database servers to edge hypervisors—file system architecture directly dictates system availability, I/O performance, data integrity, and disaster recovery SLA bounds. 

Systems engineers and Site Reliability Engineers (SREs) face two primary storage paradigms in FreeBSD/BSD systems:

1. **UFS2 (Unix File System 2):** A traditional block-based file system characterized by fixed structural layouts (Cylinder Groups, Superblocks, Inode tables). While highly efficient for lightweight root filesystems, embedded systems, or workloads with deterministic low memory overhead, UFS2 historically suffered from long crash-recovery times (`fsck`) and metadata update bottlenecks during unclean shutdowns. Modern UFS2 mitigates this using **Soft Updates (SU)** and **Soft Updates with Journaling (SU+J)**.
2. **OpenZFS (Zettabyte File System):** An advanced Copy-on-Write (CoW) transactional storage engine that unifies volume management and file system layers. OpenZFS provides end-to-end data integrity verification via checksumming, self-healing capabilities, dynamic snapshotting, inline compression, and scalable pool topology (vdevs). However, ZFS requires careful ARC (Adaptive Replacement Cache) tuning, memory allocation planning (typically requiring 1GB RAM per TB of storage as a rule of thumb for standard usage, higher for deduplication), and strict vdev expansion discipline.

### Production Problem Scenario
An enterprise platform infrastructure requires zero-downtime operations for a database cluster and a multi-tenant web application tier. Unclean host reboots (e.g., kernel panics or power loss) on un-journaled UFS2 volumes trigger synchronous foreground `fsck` scans during boot, causing 45+ minute outage windows on multi-terabyte drives. Conversely, misconfigured ZFS pools lacking dedicated log vdevs (SLOG) or running out of allocatable pool capacity (>85% pool saturation) suffer severe write latency spikes and fragmented allocation structures.

SREs must master both storage paradigms: customizing UFS2 structural layouts and tuning parameters (`newfs`, `tunefs`), enforcing integrity maintenance (`fsck_ffs`), architecting resilient OpenZFS storage pools (`zpool`), enforcing dataset governance (`zfs`), and orchestrating proactive integrity verification routines (`zpool scrub`).

---

## 2. Technical Deep-Dive & Comparative Trade-off Analysis

### 2.1 Architectural Comparison: UFS2 vs. OpenZFS

| Architecture Feature | UFS2 (Unix File System v2) | OpenZFS (Zettabyte File System) |
| :--- | :--- | :--- |
| **Allocation Model** | Static block allocation (Cylinder Groups, Direct/Indirect blocks) | Transactional Copy-on-Write (CoW) allocation |
| **Volume Layering** | Requires GEOM framework (`gpart`, `gmirror`, `gvinum`) for volume management | Integrated logical volume manager and file system engine |
| **Integrity Verification** | Superblock status flags, manual/boot-time `fsck_ffs` linear structural checks | Continuous 256-bit block checksums (Fletcher4 / SHA256 / BLAKE3), background `zpool scrub` |
| **Metadata Protection** | Soft Updates (dependency ordering) or Soft Updates + Journaling (SU+J) | Transaction groups (TXGs), ZFS Intent Log (ZIL / SLOG) |
| **Growth & Resize** | Destructive structural layout; online growth supported via `growfs` | Dynamic vdev addition; seamless online expansion |
| **Memory Footprint** | Extremely low (< 64MB kernel buffer cache requirement) | High (ARC defaults to up to 50%–90% of physical RAM; configurable via sysctl) |
| **SSD Optimization** | TRIM enabled via `tunefs -t` | Autotrim via `zpool set autotrim=on`, L2ARC caching |

### 2.2 UFS2 Metadata Consistency Mechanisms: Soft Updates (SU) vs. SU+J

* **Soft Updates (SU):** Tracks and orders in-memory metadata dependencies to ensure that on-disk structures are never left in an inconsistent state (e.g., an inode pointing to an unallocated block). Eliminates synchronous metadata writes.
  * *Trade-off:* Unclean shutdowns leave orphaned blocks/inodes that do not threaten structural stability, but require background `fsck` to recover lost free space.
* **Soft Updates with Journaling (SU+J):** Introduces a intent log for metadata updates directly inside the UFS2 filesystem allocation space.
  * *Trade-off:* Reduces boot recovery times from tens of minutes to seconds by replaying the intent log. However, it requires a small continuous write overhead and cannot be combined with SU-only on certain legacy GEOM providers.

---

## 3. Infrastructure Configurations & Syntactically Complete File System Manifests

### 3.1 Production `/etc/fstab` Manifest
The following `/etc/fstab` demonstrates production mount configurations across UFS2 partitions, swap spaces, process filesystems, and NFS/tmpfs mounts on FreeBSD 14.x.

```ini
# Device                Mountpoint      FStype      Options                             Dump    Pass
# --------------------------------------------------------------------------------------------------
# Root Filesystem (UFS2 with Soft Updates + Journaling, TRIM enabled)
/dev/gpt/rootfs         /               ufs         rw,noatime                          1       1

# Dedicated User/Var Partitions (UFS2)
/dev/gpt/varfs          /var            ufs         rw,noatime                          2       2

# Temporary volatile storage using tmpfs (prevents wear on solid-state drives)
tmpfs                   /tmp            tmpfs       rw,mode=1777,nosuid,size=4G        0       0

# Process File System (Required for legacy metrics & container runtimes)
proc                    /proc           procfs      rw                                  0       0

# Network Attached Backup Mount (NFSv4)
10.0.100.50:/exports/bkp /mnt/backups   nfs         rw,nfsv4,late,soft,intr,retrycnt=3 0       0

# Dump/Swap Device with Encryption (GEOM GELI managed dynamically, excluded from fstab direct ufs)
/dev/gpt/swap0.eli      none            swap        sw                                  0       0
```

---

### 3.2 Production `/etc/rc.conf` System Filesystem Manifest
Ensures ZFS subsystems, background checking services, and TRIM functionality auto-start correctly at boot.

```sh
# Enable OpenZFS Core Services
zfs_enable="YES"

# Automatic Background File System Checking Strategy
background_fsck="YES"
fsck_y_enable="YES"

# GEOM Subsystem Settings
geom_eli_enable="YES"

# Crash Dump & Core Dumps Management
dumpdev="/dev/gpt/swap0.eli"
dumpdir="/var/crash"
```

---

### 3.3 Production Tuning Manifest: `/etc/periodic.conf`
Configures automated maintenance, monitoring, and scrub intervals for file system integrity.

```sh
# Daily System Maintenance File System Checks
daily_clean_tmps_enable="YES"
daily_clean_tmps_days="3"

# Weekly File System Status & Security Verification
weekly_status_zfs_enable="YES"

# Monthly Scrub Strategy Configuration (Managed via custom periodic script or zfs daemon)
monthly_zfs_scrub_enable="YES"
monthly_zfs_scrub_pools="zroot tank"
```

---

## 4. Executable CLI Workflows with Realistic Terminal Outputs

### 4.1 UFS2 Creation, Parameter Modification, and Tuning

#### Step 1: Create a UFS2 File System with Custom Block/Frag Sizes, TRIM, and SU+J
We construct a UFS2 file system on partition `/dev/da1p1` specifying:
- `-O2`: UFS2 format.
- `-b 32768`: Block size of 32 KB.
- `-f 4096`: Fragment size of 4 KB.
- `-U`: Enable Soft Updates.
- `-j`: Enable Soft Updates with Journaling.
- `-t`: Enable TRIM.
- `-m 5`: Reserve 5% minfree space for `root`.

```console
# newfs -O2 -b 32768 -f 4096 -U -j -t -m 5 -L appdata /dev/da1p1
/dev/da1p1: 102400.0MB (209715200 sectors) block size 32768, fragment size 4096
        using 163 cylinder groups of 628.31MB, 20106 blocks, 80640 inodes.
        with Soft Updates with Journaling (-j)
super-block backups (for fsck_ffs -b #) at:
 160, 1286944, 2573728, 3860512, 5147300, 6434088, 7720876, 9007664, 10294452,
 11581240, 12868028, 14154816, 15441604, 16728392, 18015180, 19301968, 20588756
```

#### Step 2: Inspect and Tune UFS2 Runtime Parameters via `tunefs`

```console
# tunefs -p /dev/da1p1
tunefs: POSIX.1e ACLs: (-a)                                disabled
tunefs: NFSv4 ACLs: (-N)                                  disabled
tunefs: MAC multi-label: (-l)                             disabled
tunefs: soft updates: (-n)                                enabled
tunefs: soft updates journaling: (-j)                     enabled
tunefs: gjournal: (-J)                                    disabled
tunefs: trim: (-t)                                        enabled
tunefs: maximum contiguous soft-update blocks: (-e)       2560
tunefs: rotational delay between contiguous blocks: (-d)  0 ms
tunefs: maximum blocks per file in a cylinder group: (-m) 5%
tunefs: optimization preference: (-o)                     time
tunefs: volume label: (-L)                                appdata
```

#### Step 3: Modify Optimization Mode to Space and Adjust Reserved Inode Space

```console
# tunefs -o space -m 2 /dev/da1p1
tunefs: optimization preference changed from time to space
tunefs: minimum percentage of free space changed from 5% to 2%
```

---

### 4.2 UFS2 Integrity Verification and Repair (`fsck_ffs`)

#### Step 1: Execute Preen Integrity Check on Unmounted Volume

```console
# fsck_ffs -p /dev/da1p1
/dev/da1p1: FILE SYSTEM CLEAN; SKIPPING CHECKS
/dev/da1p1: clean, 11 blocks, 1Link, 1 files, 0 directories
```

#### Step 2: Force Complete Non-Interactive Structural Scan using Alternate Superblock
When the primary superblock is corrupted (e.g., hardware degradation), we force a check using the alternate superblock at location `160` (discovered during `newfs`).

```console
# fsck_ffs -f -b 160 -y /dev/da1p1
Alternate super block location: 160
** Last Mounted on 
** Phase 1 - Check Blocks and Sizes
** Phase 2 - Check Pathnames
** Phase 3 - Check Connectivity
** Phase 4 - Check Reference Counts
** Phase 5 - Check Cyl groups
80640 files, 154201 blocks used, 26060159 free (15 frags, 3257518 blocks)

***** FILE SYSTEM MARKED CLEAN *****
```

---

### 4.3 OpenZFS Storage Pool (`zpool`) Architecture & Administration

#### Step 1: Create an Enterprise ZFS Storage Pool (`zpool`)
We construct a resilient pool named `tank` utilizing a Mirrored layout, a dedicated SLOG (ZFS Intent Log) device on NVMe, a Read Cache (L2ARC), and a Hot Spare.

* **Data Mirror:** `da2`, `da3`
* **SLOG (Log):** `nvd0p1`
* **Cache (L2ARC):** `nvd0p2`
* **Spare:** `da4`

```console
# zpool create -f -o ashift=12 tank mirror da2 da3 log nvd0p1 cache nvd0p2 spare da4
```

#### Step 2: Query ZFS Pool Topology and Operational Status

```console
# zpool status tank
  pool: tank
 state: ONLINE
  scan: none requested
config:

	NAME        STATE     READ WRITE CKSUM
	tank        ONLINE       0     0     0
	  mirror-0  ONLINE       0     0     0
	    da2     ONLINE       0     0     0
	    da3     ONLINE       0     0     0
	logs	
	  nvd0p1    ONLINE       0     0     0
	cache	
	  nvd0p2    ONLINE       0     0     0
	spares	
	  da4       AVAIL

errors: No known data errors
```

---

### 4.4 ZFS Dataset Management, Quotas, and Property Enforcement

#### Step 1: Create Hierarchy of Production Datasets

```console
# zfs create tank/db
# zfs create tank/db/pgdata
# zfs create tank/apps
# zfs create tank/apps/logs
```

#### Step 2: Enforce Production Dataset Governance (Properties, Quotas, Compression, Mountpoints)

```console
# zfs set compression=zstd tank/db/pgdata
# zfs set atime=off tank/db/pgdata
# zfs set recordsize=16k tank/db/pgdata
# zfs set quota=500G tank/db/pgdata
# zfs set reservation=100G tank/db/pgdata
# zfs set mountpoint=/var/db/postgres tank/db/pgdata

# zfs set compression=gzip-6 tank/apps/logs
# zfs set exec=off tank/apps/logs
# zfs set setuid=off tank/apps/logs
# zfs set quota=50G tank/apps/logs
```

#### Step 3: Verify Applied Dataset Properties

```console
# zfs list -o name,quota,reservation,compress,atime,mountpoint -r tank
NAME              QUOTA  RESV  COMPRESS  ATIME  MOUNTPOINT
tank               none  none       off     on  /tank
tank/apps          none  none       off     on  /tank/apps
tank/apps/logs      50G  none    gzip-6    off  /tank/apps/logs
tank/db            none  none       off     on  /tank/db
tank/db/pgdata     500G  100G      zstd    off  /var/db/postgres
```

---

### 4.5 ZFS Maintenance & Integrity Monitoring (`zpool scrub`)

#### Step 1: Initiate Background Data Scrubbing Workflow

```console
# zpool scrub tank
```

#### Step 2: Monitor Scrub Progress and Self-Healing Results

```console
# zpool status tank
  pool: tank
 state: ONLINE
  scan: scrub in progress since Thu Aug  6 20:45:10 2026
	18.45G scanned at 1.20G/s, 2.10G issued at 140M/s, 45.2G total
	0B repaired, 4.65% done, 00:05:12 to go
config:

	NAME        STATE     READ WRITE CKSUM
	tank        ONLINE       0     0     0
	  mirror-0  ONLINE       0     0     0
	    da2     ONLINE       0     0     0
	    da3     ONLINE       0     0     0
	logs	
	  nvd0p1    ONLINE       0     0     0
	cache	
	  nvd0p2    ONLINE       0     0     0
	spares	
	  da4       AVAIL

errors: No known data errors
```

---

## 5. Verification & Troubleshooting Guide

### 5.1 Troubleshooting UFS2 Integrity Failures

```
                    +-------------------------------------+
                    | Unclean Shutdown or GEOM I/O Error  |
                    +-------------------------------------+
                                       |
                                       v
                    +-------------------------------------+
                    | Boot Failure / Soft Updates Panic   |
                    +-------------------------------------+
                                       |
                                       v
                    +-------------------------------------+
                    | Boot Single-User Mode:              |
                    | # fsck_ffs -p /dev/da1p1            |
                    +-------------------------------------+
                                       |
                    +------------------+------------------+
                    |                                     |
           [ Clean Execution ]                   [ Superblock Corrupted ]
                    |                                     |
                    v                                     v
     +-----------------------------+       +-----------------------------+
     | Mount Read-Write & Resume:  |       | Locate Alternate Superblocks|
     | # mount -uw /               |       | # newfs -N /dev/da1p1       |
     +-----------------------------+       +-----------------------------+
                                                          |
                                                          v
                                           +-----------------------------+
                                           | Force Alternate Repair:     |
                                           | # fsck_ffs -b 160 -y /dev...|
                                           +-----------------------------+
```

#### Common Diagnostic Scenarios & Remediation

##### Scenario A: UFS2 Superblock Corruption
* **Symptom:** Boot process aborts with: `fsck: /dev/da1p1: BAD SUPER BLOCK: MAGIC NUMBER WRONG`.
* **Root Cause:** Degradation of block sector offset 0/1 on the partition where the primary superblock resides.
* **Resolution Path:**
  1. Retrieve backup superblocks without overwriting data using `newfs -N /dev/da1p1`.
  2. Execute `fsck_ffs` targeting a verified alternate superblock (e.g., `160` or `1286944`):
     ```console
     # fsck_ffs -b 1286944 -y /dev/da1p1
     ```

##### Scenario B: Soft Updates Journal Inconsistency (SU+J Panic)
* **Symptom:** Kernel panics during boot at `ffs_valloc: lost block` or `SU+J journal check failed`.
* **Root Cause:** Journal write buffer missed sync to storage hardware prior to complete loss of power.
* **Resolution Path:**
  1. Boot into Single-User mode.
  2. Disable Soft Updates Journaling temporarily to clear the log:
     ```console
     # tunefs -j disable /dev/da1p1
     ```
  3. Run a comprehensive non-journaled `fsck_ffs` scan:
     ```console
     # fsck_ffs -f -y /dev/da1p1
     ```
  4. Re-enable Soft Updates Journaling:
     ```console
     # tunefs -j enable /dev/da1p1
     ```

---

### 5.2 Troubleshooting OpenZFS Pool Failures & Degradation

#### Scenario A: Vdev Degradation or Checksum Fault Accumulation
* **Symptom:** `zpool status` reports `DEGRADED` state with high `CKSUM` counts on member disk `da2`.
* **Root Cause:** Physical SATA/SAS cable failure, transient bus reset, or bad physical disk sectors.

```console
# zpool status tank
  pool: tank
 state: DEGRADED
status: One or more devices has experienced an unrecoverable error. An
	attempt was made to correct the error. Applications are unaffected.
action: Determine if the device needs to be replaced using 'zpool status -v'.
   see: https://openzfs.github.io/openzfs-docs/msg/ZFS-8000-9P
config:

	NAME        STATE     READ WRITE CKSUM
	tank        DEGRADED     0     0     0
	  mirror-0  DEGRADED     0     0     0
	    da2     FAULTED     14    250  1.2K  too many errors
	    da3     ONLINE       0     0     0
```

* **Resolution Path:**
  1. Confirm fault location via kernel ring buffer (`dmesg -a | grep da2` or `/var/log/messages`).
  2. Take the faulted vdev offline if still partially responding:
     ```console
     # zpool offline tank da2
     ```
  3. Physically replace the failed device (or partition target).
  4. Execute pool replacement command to initiate automatic silvering/resilver process:
     ```console
     # zpool replace tank da2 da4
     ```
  5. Clear accumulated fault counters:
     ```console
     # zpool clear tank
     ```

#### Scenario B: Out-of-Space Pool Failure (100% Saturation Lockup)
* **Symptom:** All write operations to ZFS datasets fail with `No space left on device` (ENOSPC). `zfs destroy` fails because CoW requires space to allocate deletion transaction state.
* **Root Cause:** Pool capacity reached 100% saturation. Copy-on-Write semantics require free blocks to write data block state changes.
* **Resolution Path:**
  1. Add a temporary file-backed or emergency physical vdev to the pool to break the transaction deadlock:
     ```console
     # truncate -s 10G /var/tmp/rescue.img
     # zpool add tank /var/tmp/rescue.img
     ```
  2. Destroy redundant snapshots or large unneeded files to free space:
     ```console
     # zfs destroy tank/apps/logs@old_snapshot
     ```
  3. Detach or remove the temporary rescue vdev:
     ```console
     # zpool remove tank /var/tmp/rescue.img
     # rm /var/tmp/rescue.img
     ```

---

## 6. References

* **Linux Professional Institute (LPI) BSD Specialist Overview:**  
  [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
* **FreeBSD Detailed Objectives (702-100 Topic 712.2):**  
  [https://wiki.lpi.org/wiki/BSD_Specialist_Objectives_V1](https://wiki.lpi.org/wiki/BSD_Specialist_Objectives_V1)
* **FreeBSD Handbook - The Unix File System (UFS):**  
  [https://docs.freebsd.org/en/books/handbook/filesystems/#filesystems-ufs](https://docs.freebsd.org/en/books/handbook/filesystems/#filesystems-ufs)
* **FreeBSD Handbook - The Z File System (ZFS):**  
  [https://docs.freebsd.org/en/books/handbook/zfs/](https://docs.freebsd.org/en/books/handbook/zfs/)
* **FreeBSD Manual Pages - `newfs(8)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=newfs&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=newfs&sektion=8)
* **FreeBSD Manual Pages - `tunefs(8)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=tunefs&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=tunefs&sektion=8)
* **FreeBSD Manual Pages - `fsck_ffs(8)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=fsck_ffs&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=fsck_ffs&sektion=8)
* **FreeBSD Manual Pages - `zpool(8)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=zpool&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=zpool&sektion=8)
* **FreeBSD Manual Pages - `zfs(8)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=zfs&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=zfs&sektion=8)
* **OpenZFS Official Documentation:**  
  [https://openzfs.github.io/openzfs-docs/](https://openzfs.github.io/openzfs-docs/)