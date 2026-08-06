# LPIC-2 Certification Study Guide — Topic 1.4: Filesystem and Devices

**Exam Scope:** LPIC-2 (Exam 201-450 & Exam 202-450, Version 4.5)  
**Topic Code:** 201.4 Filesystem and Devices  
**Weight:** 7  
**Official Reference Objectives:** [Linux Professional Institute (LPI) LPIC-2 Overview](https://www.lpi.org/our-certifications/lpic-2-overview/)

---

## Architectural Reference Documentation
* **Kernel Storage & Filesystem Documentation:** [https://www.kernel.org/doc/html/latest/filesystems/index.html](https://www.kernel.org/doc/html/latest/filesystems/index.html)
* **systemd Mount & Automount Units:** [https://www.freedesktop.org/software/systemd/man/latest/systemd.mount.html](https://www.freedesktop.org/software/systemd/man/latest/systemd.mount.html)
* **Btrfs Documentation & Mechanics:** [https://btrfs.readthedocs.io/en/latest/](https://btrfs.readthedocs.io/en/latest/)
* **Linux udev Rule Architecture:** [https://www.kernel.org/doc/html/latest/admin-guide/abi-testing.html#sys-class-block](https://www.kernel.org/doc/html/latest/admin-guide/abi-testing.html#sys-class-block)
* **dm-crypt / LUKS2 Specification:** [https://gitlab.com/cryptsetup/cryptsetup/-/wikis/LUKS-standard](https://gitlab.com/cryptsetup/cryptsetup/-/wikis/LUKS-standard)

---

## Exercise 1: Advanced Ext4 and XFS Filesystem Tuning, Metadata Inspection, and Online Repair

### Scenario
As a Senior SRE, you must optimize `/dev/sdb1` (Ext4) for a high-concurrency transactional OLTP workload and `/dev/sdc1` (XFS) for a large-file analytical log repository. You will inspect internal block allocation structures, tweak operational flags, and run non-destructive diagnostic repair sequences.

---

### Step 1.1: Ext4 Superblock & Block Group Descriptor Inspection

Execute `dumpe2fs` to inspect the superblock metadata, inode ratio, flex_bg groupings, and active filesystem features:

```bash
sudo dumpe2fs -h /dev/sdb1
```

**Expected Terminal Output:**
```text
dumpe2fs 1.46.5 (30-Dec-2021)
Filesystem volume name:   DB_STORAGE
Filesystem magic number:  0xEF53
Filesystem state:         clean
Errors behavior:          Continue
Filesystem OS type:       Linux
Inode count:              13107200
Block count:              52428800
Reserved block count:     2621440
Free blocks:              48123901
Free inodes:              13107100
First block:              0
Block size:               4096
Fragment size:            4096
Group descriptor size:    64
Blocks per group:         32768
Inodes per group:         8192
Flex_bg size:             16
Filesystem features:      has_journal ext_attr resize_inode dir_index filetype extent 64bit flex_bg sparse_super large_file huge_file dir_nlink extra_isize metadata_csum
Default mount options:    user_xattr acl
Filesystem created:       Wed Jan 14 08:30:00 2026
Last mount time:          Thu Aug  6 09:12:44 2026
Last write time:          Thu Aug  6 09:12:44 2026
Mount count:              14
Maximum mount count:      -1
Last checked:             Wed Jan 14 08:30:00 2026
Check interval:           0 (<none>)
Lifetime write:           184 GB
Reserved blocks uid:      0 (user root)
Reserved blocks gid:      0 (group root)
First inode:              11
Inode size:               256
Required extra isize:     32
Desired extra isize:      32
Journal inode:            8
Default directory hash:   half_md4
Journal backup:           inode blocks
Journal features:         journal_incompat_revoke journal_64bit journal_checksum_v3
Journal size:             1024M
Journal length:           262144
Journal sequence:         0x0001a42b
Journal start:            1
```

---

### Step 1.2: Fine-Tuning Ext4 for High-IOPS OLTP Workloads

Configure `/dev/sdb1` to reduce reserved blocks from 5% to 2% (reclaiming space on enterprise NVMe), force writeback journaling for maximum throughput, enable Multi-Mount Protection (MMP) to prevent double-mounting in SAN environments, and update mount counts:

```bash
# Reduce reserved block allocation for superuser to 2%
sudo tune2fs -m 2 /dev/sdb1

# Enable Multi-Mount Protection (MMP)
sudo tune2fs -O mmp /dev/sdb1

# Set filesystem check triggers to 50 mounts or 60 days
sudo tune2fs -c 50 -i 60d /dev/sdb1

# Verify new configuration flags
sudo tune2fs -l /dev/sdb1 | grep -E "Reserved block count|Filesystem features|Maximum mount count|Check interval"
```

**Expected Terminal Output:**
```text
Reserved block count:     1048576
Filesystem features:      has_journal ext_attr resize_inode dir_index filetype extent 64bit flex_bg sparse_super large_file huge_file dir_nlink extra_isize metadata_csum mmp
Maximum mount count:      50
Check interval:           5184000 (60 days)
```

---

### Step 1.3: XFS Metadata Structural Inspection and Allocation Group Analysis

Inspect the XFS filesystem on `/dev/sdc1` using `xfs_info`, analyze allocation group (AG) geometry, and query superblock metadata using `xfs_db`:

```bash
# Display detailed XFS geometry
sudo xfs_info /mnt/xfsdata
```

**Expected Terminal Output:**
```text
meta-data=/dev/sdc1              isize=512    agcount=16, agsize=3276800 blks
         =                       sectsz=4096  attr=2, projid32bit=1
         =                       crc=1        finobt=1, rmapbt=0, reflink=1
data     =                       bsize=4096   blocks=52428800, imaxpct=25
         =                       sunit=0      swidth=0 blks
naming   =version 2              bsize=4096   ascii-ci=0, ftype=1
log      =internal log           bsize=4096   blocks=256000, version=2
         =                       sectsz=4096  sunit=1 blks, lazy-count=1
realtime =none                   extsz=4096   blocks=0, rtextents=0
```

Open `xfs_db` in read-only mode to print Allocation Group 0 (AG 0) superblock metadata:

```bash
sudo xfs_db -r -c "sb 0" -c "p" /dev/sdc1 | head -n 20
```

**Expected Terminal Output:**
```text
magicnum = 0x58465342
blocksize = 4096
dblocks = 52428800
rblocks = 0
rextents = 0
uuid = 8f4e21a9-7c3d-4e9b-b210-99812f00a34b
logstart = 262148
rootino = 128
rsumino = 0
rbmino = 0
rextsize = 1
agblocks = 3276800
agcount = 16
rbmblocks = 0
logblocks = 256000
versionnum = 0xb4b5
sectsize = 4096
inodesize = 512
inopblock = 8
icount = 64
```

---

### Step 1.4: Performing Dry-Run Repairs on Ext4 and XFS

Run non-destructive diagnostic repair commands on both filesystems to verify block structures without modifying disk blocks:

```bash
# Ext4 dry-run check
sudo fsck.ext4 -fn /dev/sdb1

# XFS dry-run check (must be performed unmounted)
sudo umount /mnt/xfsdata 2>/dev/null || true
sudo xfs_repair -n /dev/sdc1
```

**Expected Terminal Output:**
```text
e2fsck 1.46.5 (30-Dec-2021)
Pass 1: Checking inodes, blocks, and sizes
Pass 2: Checking directory structure
Pass 3: Checking directory connectivity
Pass 4: Checking reference counts
Pass 5: Checking group summary information
DB_STORAGE: 11/13107200 files (0.0% non-contiguous), 4304899/52428800 blocks

Phase 1 - find agheaders...
Phase 2 - verify agheaders...
Phase 3 - process agfl blocks and inobt roots...
Phase 4 - check inode counters...
Phase 5 - check agalloc structures...
Phase 6 - check inode connectivity...
Phase 7 - verify and correct link counts...
No modify flag set, skipping filesystem flush.
Done.
```

---

### Comprehension Questions: Exercise 1

1.1. What is the exact mechanical role of Ext4 Multi-Mount Protection (MMP), and how does it prevent filesystem corruption in SAN or High-Availability (HA) shared-block storage environments?  
1.2. In XFS architecture, why does concurrent write scalability depend heavily on the count of Allocation Groups (`agcount`), and what performance trade-off occurs if `agcount` is configured excessively high relative to storage queue depth?  
1.3. Explain why running `xfs_repair -n` on an unmounted filesystem with an uncommitted, dirty journal causes the tool to abort, and state the exact CLI flags required to handle this situation safely.

---

## Exercise 2: Btrfs Subvolumes, Snapshots, Copy-on-Write (CoW) Mechanics, and Quota Groups

### Scenario
You are designing an immutable backup deployment architecture using Btrfs multi-device storage pools. You need to configure optimized subvolumes for PostgreSQL databases, enforce storage limits using Quota Groups (`qgroups`), and execute incremental backup streaming via subvolume snapshots.

---

### Step 2.1: Formatting Btrfs Multi-Device Pools and Subvolume Creation

Initialize a multi-device Btrfs pool using `/dev/sdd1` and `/dev/sde1` with metadata mirrored (RAID1) and data striped (RAID0):

```bash
sudo mkfs.btrfs -f -L "BTRFS_PROD_POOL" -m raid1 -d raid0 /dev/sdd1 /dev/sde1
```

**Expected Terminal Output:**
```text
btrfs-progs v5.16.2 
See http://btrfs.wiki.kernel.org for more information.

Label:              BTRFS_PROD_POOL
UUID:               c6f89012-3a4b-5c6d-7e8f-9012345678ab
Node size:          16384
Sector size:        4096
Filesystem size:    100.00GiB
Block group head:   2176
64Bit (#254):       1
Incompat features:  EXTENDED_IREF, SKINNY_METADATA, NO_HOLES
Runtime features:   none
Checksum:           crc32c
Number of devices:  2
Devices:
   ID        SIZE  PATH
    1    50.00GiB  /dev/sdd1
    2    50.00GiB  /dev/sde1
```

Mount the top-level subvolume (Subvolume ID 5) and build subvolume layouts `@pg_data` and `@snapshots`:

```bash
sudo mkdir -p /mnt/btrfs-root
sudo mount /dev/sdd1 /mnt/btrfs-root

# Create structured subvolumes
sudo btrfs subvolume create /mnt/btrfs-root/@pg_data
sudo btrfs subvolume create /mnt/btrfs-root/@snapshots

# List subvolumes to capture Subvolume IDs
sudo btrfs subvolume list /mnt/btrfs-root
```

**Expected Terminal Output:**
```text
ID 256 gen 7 top level 5 path @pg_data
ID 257 gen 8 top level 5 path @snapshots
```

---

### Step 2.2: Mounting Subvolumes with Optimized Runtime Flags & Disabling CoW

Mount `@pg_data` into `/var/lib/postgresql/data` using ZSTD compression, no access time updates, and disable Copy-on-Write (`nodatacow`) specifically on the database files directory to eliminate fragmenting B-tree fragmentation:

```bash
sudo mkdir -p /var/lib/postgresql/data

# Mount @pg_data with explicit subvolume selector
sudo mount -o subvol=@pg_data,compress=zstd:3,noatime /dev/sdd1 /var/lib/postgresql/data

# Disable Copy-on-Write (CoW) on the directory before database initialization
sudo chattr +C /var/lib/postgresql/data

# Verify file attributes (C flag indicates NOCOW)
lsattr -d /var/lib/postgresql/data
```

**Expected Terminal Output:**
```text
---------------C------ /var/lib/postgresql/data
```

---

### Step 2.3: Read-Only Snapshots and Incremental Send/Receive Backup Pipelines

Create a read-only snapshot of `@pg_data`, stream it to a secondary backup target directory via `btrfs send` and `btrfs receive`:

```bash
# Create read-only snapshot
sudo btrfs subvolume snapshot -r /var/lib/postgresql/data /mnt/btrfs-root/@snapshots/pg_data_20260806_0000

# Prepare local backup directory representing remote storage
sudo mkdir -p /mnt/backup_target

# Stream full snapshot stream
sudo btrfs send /mnt/btrfs-root/@snapshots/pg_data_20260806_0000 | sudo btrfs receive /mnt/backup_target/
```

**Expected Terminal Output:**
```text
Create snapshot of '/var/lib/postgresql/data' in '/mnt/btrfs-root/@snapshots/pg_data_20260806_0000'
At subvol /mnt/btrfs-root/@snapshots/pg_data_20260806_0000
At subvol pg_data_20260806_0000
```

---

### Step 2.4: Btrfs Quota Group (`qgroup`) Configuration and Hierarchy Enforcement

Enable the Btrfs quota subsystem on the pool, create a high-level quota group (`1/0`), assign subvolume `@pg_data` to it, and enforce a 20GB maximum limit:

```bash
# Enable quota subsystem
sudo btrfs quota enable /mnt/btrfs-root

# Create hierarchical qgroup 1/0
sudo btrfs qgroup create 1/0 /mnt/btrfs-root

# Assign subvolume ID 256 (@pg_data) to qgroup 1/0
sudo btrfs qgroup assign 0/256 1/0 /mnt/btrfs-root

# Enforce a 20 Gigabyte limit on qgroup 1/0
sudo btrfs qgroup limit 20G 1/0 /mnt/btrfs-root

# Query quota assignment and current consumption
sudo btrfs qgroup show -p -r --units g /mnt/btrfs-root
```

**Expected Terminal Output:**
```text
qgroupid         rfer         excl Parent  Max referenced Max exclusive 
--------         ----         ---- ------  -------------- ------------- 
0/5          0.00GiB      0.00GiB ---      none           none          
0/256        0.01GiB      0.01GiB 1/0      none           none          
0/257        0.00GiB      0.00GiB ---      none           none          
1/0          0.01GiB      0.01GiB ---      20.00GiB       none          
```

---

### Comprehension Questions: Exercise 2

2.1. Why does applying `chattr +C` (`nodatacow`) on an existing directory *not* retroactively strip Copy-on-Write properties from files already present inside that directory, and what command sequence is required to convert existing database files to NOCOW?  
2.2. Explain how `btrfs send -p <parent_snapshot> <child_snapshot>` calculates block differences between two read-only snapshots without reading the underlying block data payload.  
2.3. What severe kernel CPU overhead and lock contention issue can occur in Kubernetes or Docker environments running on Btrfs when `qgroups` are enabled alongside dynamic container lifecycle events?

---

## Exercise 3: Systemd Native Storage Orchestration (`.mount` and `.automount` units) vs. `/etc/fstab`

### Scenario
To achieve non-blocking boot sequences and strict dependency orchestration, you are replacing legacy `/etc/fstab` storage entries with systemd `.mount` and `.automount` unit files for a high-concurrency analytical directory at `/mnt/data/analytics`.

---

### Step 3.1: Creating a Production Systemd Mount Unit

Create the mount unit at `/etc/systemd/system/mnt-data-analytics.mount`.

```ini
[Unit]
Description=Production Analytics High-Performance Storage Block
Documentation=https://docs.internal.net/storage/analytics
Wants=network-online.target
After=network-online.target blockdev@dev-disk-by\x2dlabel-ANALYTICS_DATA.target
RequiresMountsFor=/mnt/data

[Mount]
What=/dev/disk/by-label/ANALYTICS_DATA
Where=/mnt/data/analytics
Type=xfs
Options=defaults,noatime,nodiratime,logbufs=8,logbsize=256k,allocsize=64m
TimeoutSec=30s
DirectoryMode=0755

[Install]
WantedBy=multi-user.target
```

---

### Step 3.2: Creating an On-Demand Systemd Automount Unit

Create the matching automount unit at `/etc/systemd/system/mnt-data-analytics.automount`. This intercepts filesystem access calls at `/mnt/data/analytics` and mounts the block device on demand, unmounting it automatically after 10 minutes of inactivity.

```ini
[Unit]
Description=Automount Controller for Analytics Storage Block
Documentation=https://docs.internal.net/storage/analytics
ConditionPathExists=/mnt/data

[Automount]
Where=/mnt/data/analytics
TimeoutIdleSec=600s
DirectoryMode=0755

[Install]
WantedBy=multi-user.target
```

---

### Step 3.3: Unit Activation, Verification, and Lifecycle Management

Reload systemd to compile unit dependency trees, activate the `.automount` interface, and verify dynamic mounting state:

```bash
# Reload systemd manager configuration
sudo systemctl daemon-reload

# Enable and start the automount unit (do NOT start the .mount unit directly)
sudo systemctl enable --now mnt-data-analytics.automount

# Inspect automount status
sudo systemctl status mnt-data-analytics.automount
```

**Expected Terminal Output:**
```text
● mnt-data-analytics.automount - Automount Controller for Analytics Storage Block
     Loaded: loaded (/etc/systemd/system/mnt-data-analytics.automount; enabled; vendor preset: enabled)
     Active: active (waiting) since Thu 2026-08-06 09:40:12 EDT; 12s ago
   Triggers: ● mnt-data-analytics.mount
      Where: /mnt/data/analytics

Aug 06 09:40:12 node01 systemd[1]: Set up automount Automount Controller for Analytics Storage Block.
```

Trigger on-demand mounting by querying directory contents:

```bash
# Accessing path triggers autofs kernel intercept
ls -la /mnt/data/analytics

# Check status of the underlying mount unit
sudo systemctl status mnt-data-analytics.mount
```

**Expected Terminal Output:**
```text
● mnt-data-analytics.mount - Production Analytics High-Performance Storage Block
     Loaded: loaded (/etc/systemd/system/mnt-data-analytics.mount; disabled; vendor preset: enabled)
     Active: active (mounted) since Thu 2026-08-06 09:40:45 EDT; 3s ago
   TriggeredBy: ● mnt-data-analytics.automount
      Where: /mnt/data/analytics
       What: /dev/sdb2
      Tasks: 0 (limit: 19125)
     Memory: 44.0K
        CPU: 4ms
     CGroup: /system.slice/mnt-data-analytics.mount
```

---

### Comprehension Questions: Exercise 3

3.1. What mandatory naming convention rule must be strictly followed when creating a systemd `.mount` unit file, and what specific `systemd-escape` command would generate the correct unit name for a target path of `/srv/data/logs/2026`?  
3.2. How do systemd `.automount` units prevent application boot crashes and hangs when a backing block storage device (such as an iSCSI or NFS target) is temporarily unreachable at boot time?  
3.3. Describe the exact mechanism by which `systemd-fstab-generator` converts legacy `/etc/fstab` lines into native in-memory systemd mount units during early kernel boot (`sysinit.target`).

---

## Exercise 4: Dynamic Hardware Event Handling with udev, sysfs, and Kernel Block I/O Tuning

### Scenario
You must write production `udev` rules to automatically identify high-throughput NVMe block devices, enforce the `none` multi-queue I/O scheduler, expand kernel read-ahead buffers to 1024 KiB, and construct persistent device symlinks based on hardware serial numbers.

---

### Step 4.1: Interrogating Hardware Properties via `sysfs` and `udevadm`

Trace device attributes along the kernel physical hierarchy for device `/dev/nvme0n1`:

```bash
# Walk system hardware parent chain
sudo udevadm info --attribute-walk --name=/dev/nvme0n1
```

**Expected Terminal Output:**
```text
Udevadm info starts with the device specified by the devpath '/devices/pci0000:00/0000:00:1d.0/0000:01:00.0/nvme/nvme0/nvme0n1':
  looking at device '/devices/pci0000:00/0000:00:1d.0/0000:01:00.0/nvme/nvme0/nvme0n1':
    KERNEL=="nvme0n1"
    SUBSYSTEM=="block"
    DRIVER==""
    ATTR{alignment_offset}=="0"
    ATTR{capability}=="0"
    ATTR{discard_max_bytes}=="2199023255552"
    ATTR{ext_range}=="256"
    ATTR{hidden}=="0"
    ATTR{range}=="0"
    ATTR{removable}=="0"
    ATTR{ro}=="0"
    ATTR{size}=="1000204880"
    ATTR{stat}=="     456     120    34568    1200      890     450    89012    4500        0     3200     5700"

  looking at parent device '/devices/pci0000:00/0000:00:1d.0/0000:01:00.0/nvme/nvme0':
    KERNELS=="nvme0"
    SUBSYSTEMS=="nvme"
    DRIVERS==""
    ATTRS{model}=="SAMSUNG MZQL2960HCJR-00A07"
    ATTRS{serial}=="S64BNX0T101928"
    ATTRS{firmware_rev}=="MPK7301Q"
```

Query system udev database environment variables for the device:

```bash
sudo udevadm info --query=all --name=/dev/nvme0n1 | grep -E "DEVLINKS|ID_SERIAL|ID_MODEL"
```

**Expected Terminal Output:**
```text
E: DEVLINKS=/dev/disk/by-id/nvme-SAMSUNG_MZQL2960HCJR-00A07_S64BNX0T101928 /dev/disk/by-path/pci-0000:01:00.0-nvme-1
E: ID_MODEL=SAMSUNG MZQL2960HCJR-00A07
E: ID_SERIAL=S64BNX0T101928
```

---

### Step 4.2: Writing Production Rules for I/O Scheduling and Symlinks

Create `/etc/udev/rules.d/60-persistent-nvme-scheduler.rules` to enforce operational storage policies:

```udev
# /etc/udev/rules.d/60-persistent-nvme-scheduler.rules
# Enforce 'none' I/O scheduler for NVMe block devices to bypass single-queue locks
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme[0-n]*n[1-9]*", ATTR{queue/scheduler}="none"

# Expand kernel read-ahead buffer size to 1024 KiB (2048 blocks of 512 bytes)
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme[0-n]*n[1-9]*", ATTR{queue/read_ahead_kb}="1024"

# Generate custom persistent symlink under /dev/storage/ using parent serial number match
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme*n1", ATTRS{serial}=="S64BNX0T101928", SYMLINK+="storage/fast-db-nvme"
```

---

### Step 4.3: Rule Simulation, Reloading, and Runtime Validation

Perform a dry-run test with `udevadm test` to verify rule parsing without side effects:

```bash
sudo udevadm test /sys/block/nvme0n1 2>&1 | grep -E "scheduler|read_ahead_kb|fast-db-nvme"
```

**Expected Terminal Output:**
```text
ATTR '/sys/devices/pci0000:00/0000:00:1d.0/0000:01:00.0/nvme/nvme0/nvme0n1/queue/scheduler' writing 'none'
ATTR '/sys/devices/pci0000:00/0000:00:1d.0/0000:01:00.0/nvme/nvme0/nvme0n1/queue/read_ahead_kb' writing '1024'
creating symlink '/dev/storage/fast-db-nvme' to '../nvme0n1'
```

Reload the udev daemon rules engine and trigger block device events to apply changes:

```bash
# Reload control daemon
sudo udevadm control --reload-rules

# Trigger subsystem events for block devices
sudo udevadm trigger --subsystem-match=block --action=change

# Verify current runtime scheduler and read-ahead settings
cat /sys/block/nvme0n1/queue/scheduler
cat /sys/block/nvme0n1/queue/read_ahead_kb
ls -la /dev/storage/fast-db-nvme
```

**Expected Terminal Output:**
```text
[none] mq-deadline bfq 
1024
lrwxrwxrwx 1 root root 10 Aug  6 09:52 /dev/storage/fast-db-nvme -> ../nvme0n1
```

---

### Comprehension Questions: Exercise 4

4.1. In udev rule logic, what is the precise functional difference between matching keys using `ATTR{key}` versus `ATTRS{key}`, and what failure occurs if `ATTR{serial}` is used instead of `ATTRS{serial}` when targeting NVMe devices?  
4.2. Why is the `none` (passthrough) multi-queue I/O scheduler optimal for high-IOPS NVMe drives, whereas `mq-deadline` or `bfq` is required for rotational SATA/SAS mechanical disks?  
4.3. What kernel execution deadlocks occur if a udev rule executes a long-running, blocking script via `RUN+="/usr/local/bin/backup.sh"`, and what is the proper mechanism for delegating asynchronous tasks from udev?

---

## Exercise 5: Encrypted Block Devices with LUKS2, dm-crypt, and Automated Boot Integration

### Scenario
You are tasked with provisioning an encrypted LUKS2 storage partition on `/dev/sdf1` using AES-XTS-PLAIN64 encryption, configuring automated keyfile unlocking via `/etc/crypttab`, mounting it persistent via `/etc/fstab`, and backing up critical LUKS headers for disaster recovery.

---

### Step 5.1: Formatting LUKS2 Devices with Argon2id PBKDF Parameters

Format `/dev/sdf1` with LUKS2 specification, explicit 512-bit key length, SHA-512 hashing, and Argon2id memory-hard PBKDF:

```bash
# Create dedicated keyfile directory with restricted permissions
sudo mkdir -p /etc/keys
sudo chmod 700 /etc/keys

# Generate 4096-bit cryptographically secure keyfile
sudo dd if=/dev/urandom of=/etc/keys/secure_vault.key bs=512 count=1
sudo chmod 400 /etc/keys/secure_vault.key

# Format partition with LUKS2 specifications
sudo cryptsetup luksFormat \
  --type luks2 \
  --cipher aes-xts-plain64 \
  --key-size 512 \
  --hash sha512 \
  --pbkdf argon2id \
  --pbkdf-memory 1048576 \
  --label "SECURE_STORAGE" \
  --batch-mode \
  /dev/sdf1 /etc/keys/secure_vault.key
```

Dump the LUKS header metadata to verify payload alignment, cipher configuration, and keyslot allocation:

```bash
sudo cryptsetup luksDump /dev/sdf1
```

**Expected Terminal Output:**
```text
LUKS header information
Version:        2
Epoch:          3
Metadata area:  16384 [bytes]
Keyslot area:   16744448 [bytes]
UUID:           a1b2c3d4-e5f6-7890-abcd-ef1234567890
Label:          SECURE_STORAGE
Subsystem:      (no subsystem)

Data segments:
  0: crypt
	offset: 16777216 [bytes]
	length: (default)
	cipher: aes-xts-plain64
	sector: 512 [bytes]

Keyslots:
  0: luks2
	digest: 0
	kdf:    argon2id
	time cost: 4
	memory cost: 1048576
	cpus: 4
	cipher: aes-xts-plain64
	key size: 64 [bytes]
	AF:     luks1
	AF size: 4000 [bytes]
	Area:   131072 [bytes]
```

---

### Step 5.2: Mapping Device, Formatting Filesystem, and Configuring Automated Mounts

Open the LUKS mapping layer under `/dev/mapper/secure_vault_ds`:

```bash
sudo cryptsetup open --key-file /etc/keys/secure_vault.key /dev/sdf1 secure_vault_ds

# Format the unencrypted dm-crypt block interface with XFS
sudo mkfs.xfs -f -L "SECURE_DATA" /dev/mapper/secure_vault_ds
```

Configure `/etc/crypttab` for persistent automated unlocking during early system boot:

```bash
# Add line to /etc/crypttab (using UUID of physical partition /dev/sdf1)
echo "secure_vault_ds UUID=a1b2c3d4-e5f6-7890-abcd-ef1234567890 /etc/keys/secure_vault.key luks,discard" | sudo tee -a /etc/crypttab
```

Configure `/etc/fstab` to mount the mapped virtual block device:

```bash
sudo mkdir -p /mnt/secure_vault

# Add entry to /etc/fstab
echo "/dev/mapper/secure_vault_ds /mnt/secure_vault xfs defaults,noatime,nofail 0 2" | sudo tee -a /etc/fstab

# Test mount invocation using fstab engine
sudo mount /mnt/secure_vault
df -Th /mnt/secure_vault
```

**Expected Terminal Output:**
```text
Filesystem                   Type  Size  Used Avail Use% Mounted on
/dev/mapper/secure_vault_ds  xfs    50G  390M   50G   1% /mnt/secure_vault
```

---

### Step 5.3: LUKS Header Disaster Recovery Operations

Backup the binary LUKS2 header (including metadata and keyslots) to an isolated rescue location:

```bash
sudo cryptsetup luksHeaderBackup /dev/sdf1 --header-backup-file /root/luks_header_sdf1.img
ls -lh /root/luks_header_sdf1.img
```

**Expected Terminal Output:**
```text
-rw------- 1 root root 16M Aug  6 09:58 /root/luks_header_sdf1.img
```

---

### Comprehension Questions: Exercise 5

5.1. What are the key architectural improvements of the LUKS2 specification over LUKS1 regarding header metadata redundancy, JSON schema flexibility, and resilience against physical power-loss corruption?  
5.2. Explain the security risks associated with specifying the `discard` (TRIM) option in `/etc/crypttab` on solid-state drives, and describe what structural data patterns are exposed to an attacker analyzing raw flash chips.  
5.3. If the primary header of a LUKS2 volume is completely zeroed out due to misconfigured block writing (`dd if=/dev/zero of=/dev/sdf1 bs=1M count=10`), what step-by-step procedure must be followed to restore the header using `luksHeaderRestore` and regain access to underlying data?

---

## Answers Section

<details>
<summary><strong>Click to expand Comprehensive Production Technical Answers</strong></summary>

### Exercise 1 Answers

**1.1. Mechanics of Ext4 Multi-Mount Protection (MMP):**  
Ext4 Multi-Mount Protection (MMP) prevents a shared block storage volume (e.g., iSCSI LUN or FC volume presented to multiple SAN nodes) from being simultaneously mounted read-write by more than one host. 

When MMP is enabled (`tune2fs -O mmp`), a dedicated block (the MMP block) is updated periodically by a background kernel thread on the node that mounted the filesystem. The thread writes a unique sequence number and timestamp to the MMP block at an interval controlled by `s_mmp_update_interval`. 

Before another node mounts the filesystem, it reads the MMP block, waits for an interval slightly exceeding the update frequency, and checks whether the sequence number or timestamp changes. If changes are detected, the kernel denies the mount operation with an `EEXIST` or "Device or resource busy" error. This prevents catastrophic corruption of inode tables and block maps caused by split-brain concurrent writes.

**1.2. XFS Allocation Group (AG) Scalability vs. Overhead:**  
In XFS, Allocation Groups (AGs) function as independent virtual filesystems within the block device. Each AG maintains its own metadata b-trees: block allocation free space b-trees (`bnobt`, `cntbt`), inode allocation b-trees (`inobt`, `finobt`), and reverse mapping trees (`rmapbt`). 

Parallel threads performing concurrent allocations acquire locks only on individual AGs. A higher `agcount` increases concurrency because allocation requests lock separate AG structures simultaneously without thread contention. 

However, if `agcount` is configured excessively high relative to volume size and queue depth, disk space fragmentation increases. Free space becomes fragmented into smaller chunks per AG, preventing large contiguous extents from being allocated. Furthermore, kernel memory consumption increases due to larger active AG metadata cache allocations.

**1.3. `xfs_repair` Behavior with Dirty Journals:**  
Unlike Ext4's `e2fsck` (which replays dirty uncommitted journal transactions prior to executing filesystem structural checks), `xfs_repair` intentionally refuses to replay the XFS log journal. `xfs_repair` operates exclusively on disk structures and cannot safely parse or replay journal transactions in user space without risking invalid state transitions.

If `xfs_repair -n` or `xfs_repair` detects an uncommitted dirty journal, it aborts with a message stating that the log is dirty and must be mounted to replay it. 

To resolve this safely:
1. Mount the filesystem temporarily so the kernel XFS driver replays the log journal in kernel space.
2. Unmount the filesystem cleanly (`umount`), committing all transactions.
3. Re-run `xfs_repair /dev/sdc1`.

If the storage hardware is permanently damaged and the log cannot be replayed via mount, the administrator can force log zeroing using `xfs_repair -L /dev/sdc1`. *Warning:* This invalidates uncommitted metadata modifications and may cause orphan files to move to `lost+found`.

---

### Exercise 2 Answers

**2.1. Retrospective Scope of `chattr +C` (NOCOW):**  
In Btrfs, the NOCOW (`+C`) file attribute sets the flag on the inode at file creation time. Applying `chattr +C` to an existing directory sets the attribute only on newly created files within that directory. Existing files retain their initial Copy-on-Write property because their metadata extents were already written to disk using CoW rules.

To convert existing files to NOCOW:
1. Create a temporary sibling directory: `mkdir /var/lib/postgresql/data_nocow`
2. Set NOCOW on the new directory: `chattr +C /var/lib/postgresql/data_nocow`
3. Copy existing files into the new directory: `cp -a --attr-same=no /var/lib/postgresql/data/* /var/lib/postgresql/data_nocow/` (or perform a standard non-reflink copy). This creates brand new files inheriting the parent directory's `+C` flag.
4. Replace the old directory with the new directory.

**2.2. Delta Computation in `btrfs send` Incremental Pipelines:**  
`btrfs send -p <parent_snapshot> <child_snapshot>` does not scan raw file contents or block payloads. Instead, it inspects the Btrfs subvolume B-trees—specifically the Extent Tree and Metadata Trees. 

Because snapshots in Btrfs share immutable extent references due to Copy-on-Write, the parent snapshot and child snapshot reference identical Extent Data Items for unchanged blocks. `btrfs send` traverses the metadata tree structures of both snapshots in parallel, comparing generation numbers and extent references. 

It generates stream commands (`write`, `clone`, `snapshot`, `unlink`) only for extent records where generation numbers differ or where new extent nodes exist in the child snapshot but not in the parent. This reduces delta identification time to a fast metadata traversal.

**2.3. Performance Impact of Btrfs `qgroups` in High-Churn Container Environments:**  
Btrfs Quota Groups (`qgroups`) compute referenced and exclusive block usage per subvolume. In Copy-on-Write filesystems, extents are frequently shared across multiple snapshots and subvolumes. 

When a block is written, modified, or freed in any subvolume, the kernel must execute reverse extent lookups through the global Extent Tree to recalculate `rfer` (referenced) and `excl` (exclusive) counters across all associated parent and child quota groups. 

In Docker or Kubernetes environments on Btrfs, hundreds of container layers, ephemeral volumes, and short-lived subvolume snapshots are continuously created and deleted. This triggers massive lock contention on the global Btrfs extent root tree locks and causes the `btrfs-transaction` kernel thread to consume 100% CPU utilization, freezing host block I/O.

---

### Exercise 3 Answers

**3.1. Systemd Mount Unit File Naming Constraints:**  
Systemd requires that `.mount` unit filenames strictly match the absolute target mount point path, replacing slashes (`/`) with hyphens (`-`) and escaping special characters into hexadecimal values. 

If a unit file named `mnt-data-analytics.mount` contains `Where=/mnt/data/other`, systemd rejects the unit during loading (`daemon-reload`) with a critical configuration error stating that the unit name does not match the `Where=` path setting.

To generate the exact required unit name for `/srv/data/logs/2026`:
```bash
systemd-escape --path --suffix=mount /srv/data/logs/2026
```
*Output:* `srv-data-logs-2026.mount`.

**3.2. Resilience of Automount Units During Network/Block Disruptions:**  
Standard static `/etc/fstab` mounts execute synchronously during the boot sequence (`local-fs.target` or `remote-fs.target`). If a target block device (such as an iSCSI target, Fibre Channel LUN, or NFS export) is slow, failing, or disconnected, boot progress stalls until `TimeoutSec` expires (defaulting to 90 seconds per device), often causing dropping into emergency rescue shells.

Systemd `.automount` units decouples boot progress from target storage availability. During boot, systemd creates an kernel `autofs` virtual file descriptor interface at the target mount location instantly without attempting to establish communication with the physical block storage device. Boot target milestones (`multi-user.target`) complete immediately without blocking. 

When an application issues an I/O system call (`open()`, `stat()`) to the directory, the kernel `autofs` intercept pauses the calling thread and signals systemd to trigger the underlying `.mount` unit. If the storage device is temporarily offline, only the accessing application process waits; the rest of the OS functions normally.

**3.3. `systemd-fstab-generator` Execution Flow:**  
During early system startup (prior to PID 1 mounting local filesystems), the initramfs or early user-space initializes `systemd-fstab-generator` (located in `/usr/lib/systemd/system-generators/`).

1. The generator reads `/etc/fstab` line by line.
2. For each valid entry (excluding `comment`, `noauto`, or invalid entries), it dynamically synthesizes an in-memory `.mount` unit file inside `/run/systemd/generator/` (e.g., `/run/systemd/generator/var-log.mount`).
3. It maps options: `noauto` omits target symlinks in `multi-user.target.wants/`; `x-systemd.automount` dynamically generates a matching `.automount` unit in `/run/systemd/generator/`; `x-systemd.device-timeout` sets device detection wait limits.
4. It dynamically builds dependency ordering directives (`Before=`, `After=`, `Requires=`, `Wants=`) against block device units (e.g., `dev-disk-by\x2duuid-xxx.device`) and filesystem mount hierarchy targets.
5. Systemd PID 1 loads these synthesized units into its dependency graph.

---

### Exercise 4 Answers

**4.1. Difference Between `ATTR{key}` and `ATTRS{key}` in udev Rules:**  
- `ATTR{key}` checks an attribute belonging **strictly to the single device node currently being evaluated** by the event (the target udev device node at the end of the sysfs path).
- `ATTRS{key}` (and `KERNELS`, `DRIVERS`, `SUBSYSTEMS`) performs a **recursive upward traversal along the parent device tree hierarchy** in `/sys`, matching if the key exists on the device *or any of its parent hardware controllers* (e.g., NVMe controllers, PCI bridges, USB root hubs).

If an administrator writes `ATTR{serial}=="S64BNX0T101928"` for block device node `/dev/nvme0n1`, the rule **fails** because the `serial` attribute is exposed by the parent NVMe controller subsystem (`/sys/devices/.../nvme/nvme0`), whereas `/dev/nvme0n1` exposes only block-level metrics (`size`, `stat`, `capability`). Matching parent attributes requires `ATTRS{serial}`.

**4.2. I/O Scheduler Dynamics: NVMe Multi-Queue vs. Mechanical Drives:**  
Traditional mechanical Hard Disk Drives (HDDs) suffer from physical rotational latency and seek times. Single-queue schedulers (`mq-deadline`, `bfq`) are necessary to reorder, merge, and prioritize block requests based on physical disk sector proximity, minimizing physical head movement.

NVMe drives utilize high-parallelism solid-state controllers supporting up to 64,000 submission queues, each capable of handling 64,000 concurrent commands directly over PCIe lanes. 

Interposing an OS-level software scheduling algorithm (`mq-deadline` or `bfq`) introduces CPU lock contention, context switching overhead, and artificial queue bottlenecks. Setting the scheduler to `none` passes block read/write vectors straight from user space/kernel page cache into the NVMe hardware controller queues without locking overhead, achieving maximum IOPS and sub-millisecond latencies.

**4.3. Blocking `RUN+=` Executions and udev Daemon Event Queue Mechanics:**  
The udev daemon (`systemd-udevd`) processes hardware netlink events sequentially or within a bounded worker thread pool. If a udev rule invokes a long-running foreground script using `RUN+="/usr/local/bin/backup.sh"`, the assigned udev worker thread blocks until the script exits.

If execution exceeds the default udev event timeout (typically 180 seconds defined by `event_timeout`), `systemd-udevd` forcefully terminates the worker thread, logs a "worker timed out, killing it" error, leaves device nodes in an incomplete initialization state, and blocks subsequent hardware event handling across the system.

*Proper Asynchronous Delegation:*  
Never execute blocking routines inside `RUN+=`. Instead, use udev to trigger an asynchronous systemd service unit:
```udev
ACTION=="add", SUBSYSTEM=="block", KERNEL=="sd[a-z]1", TAG+="systemd", ENV{SYSTEMD_WANTS}="backup-workload@%k.service"
```
This causes udev to notify systemd to instantiate and launch `backup-workload@sda1.service` in a separate execution context, allowing udev to complete event processing instantly.

---

### Exercise 5 Answers

**5.1. LUKS2 Header Architecture vs. LUKS1:**  
1. **Metadata Redundancy and Self-Healing:** LUKS1 contains a single vulnerable binary header block at offset 0. If corrupted, access to all keyslots is lost. LUKS2 implements two identical metadata headers (primary and secondary header) stored at different offsets, featuring individual checksums (`crc32c`). If the primary header experiences sector corruption, LUKS2 auto-recovers metadata from the intact secondary copy.
2. **JSON Metadata Schema:** LUKS2 replaces fixed binary offsets with an extensible ASCII JSON metadata string. This allows dynamic placement of keyslots, dynamic assignment of key derivation functions, and support for multi-segment token mechanisms (e.g., TPM2 bindings, FIDO2 tokens, PKCS#11 smartcards).
3. **Argon2id PBKDF Resilience:** LUKS1 relied on PBKDF2 (SHA-256/SHA-512), which is vulnerable to parallelized GPU and ASIC dictionary attacks because PBKDF2 requires minimal CPU memory cache. LUKS2 uses Argon2id, a memory-hard Password-Based Key Derivation Function. It forces the system to allocate large configurable blocks of RAM (e.g., 1 GB per execution attempt) during key decryption, neutralizing GPU/ASIC acceleration attacks.

**5.2. TRIM/Discard Security Vulnerabilities on Encrypted Storage:**  
Enabling `discard` (TRIM) in `/etc/crypttab` allows the kernel to inform the underlying SSD controller when block ranges are freed by the filesystem. The SSD controller clears the flash memory pages, returning zeroes for unallocated sectors.

*Security Trade-Off (Information Leakage):*  
Without TRIM, an encrypted block device appears to an offline attacker as a homogeneous block of random high-entropy data; the boundary between used data sectors and free space is indistinguishable. 

When TRIM is enabled on a LUKS volume, trimmed blocks return empty 0x00 sectors directly to raw read queries. An attacker possessing the raw storage media can identify:
- Exact volume utilization metrics and available free space.
- Exact physical location, layout, and extent fragmentation patterns of active filesystems.
- The precise filesystem type based on reserved un-trimmed structural block locations (e.g., superblocks, inode tables).

**5.3. Recovery Procedure for Zeroed Primary LUKS2 Headers:**  
If the primary header at the start of `/dev/sdf1` is corrupted or zeroed:

1. Do NOT attempt to run `mkfs` or re-format the device. Unmount any mapped interfaces (`cryptsetup close`).
2. Verify if a external offline backup file exists (e.g., `/root/luks_header_sdf1.img`).
3. If an offline backup exists, restore the header directly:
   ```bash
   sudo cryptsetup luksHeaderRestore /dev/sdf1 --header-backup-file /root/luks_header_sdf1.img
   ```
4. If no offline backup file exists, but LUKS2 was used, attempt recovery from the secondary internal backup header using `cryptsetup`:
   ```bash
   sudo cryptsetup open --repair /dev/sdf1 secure_vault_ds
   ```
   The `--repair` option detects that the primary LUKS2 header magic signature is invalid, verifies the CRC32 checksum of the secondary header located further down the disk block array, and overwrites the corrupted primary header with the intact secondary header structure.
5. Re-open the mapped dm-crypt block interface:
   ```bash
   sudo cryptsetup open /dev/sdf1 secure_vault_ds
   ```
6. Run non-destructive filesystem sanity checks (`xfs_repair -n` or `fsck.ext4 -fn`) on `/dev/mapper/secure_vault_ds` to verify structural data integrity.

</details>