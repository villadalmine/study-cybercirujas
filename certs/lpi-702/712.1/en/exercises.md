# LPI 702-100 (BSD Specialist) Study Guide
## Topic 712.1: BSD Partitioning and Disk Labels
**Weight:** 3.33 (Exam Weight 2)  
**Target Audience:** SREs, Systems Engineers, and Platform Architects  
**Official Reference:** [LPI BSD Specialist Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

---

## 1. Deep Dive: Architecture & Internal Mechanics

### 1.1 The Two-Tiered BSD Partitioning Model vs. Native GPT
Traditional UNIX/Linux disk layout schemes map partition entries directly within the MBR (Master Boot Record) partition table (up to 4 primary partitions). In contrast, BSD operating systems historically employ a two-tiered disk partitioning model to overcome MBR limitations while providing kernel-enforced filesystem security boundaries.

```
+-----------------------------------------------------------------------+
| Physical Disk / Storage LUN (e.g., /dev/ada0 or /dev/sd0)              |
+-----------------------------------------------------------------------+
| MBR (Master Boot Record) Sector 0                                     |
+-------------------+-------------------+------------------+------------+
| Slice 1 (0xA5/0xA6)| Slice 2          | Slice 3          | Slice 4    |
| (BSD Primary)     | (Linux/NTFS/etc.) | (FreeBSD/OpenBSD)| (Unused)   |
+-------------------+-------------------+------------------+------------+
        |
        v
+-----------------------------------------------------------------------+
| BSD Disklabel (Offset 512 bytes inside Slice 1 or sector 1 of disk)   |
+-----------------------------------------------------------------------+
| Partition 'a' -> / (Root Filesystem, Bootable)                        |
| Partition 'b' -> Swap Space                                           |
| Partition 'c' -> Entire Slice / Physical Disk (Raw Container)         |
| Partition 'd' -> /var Filesystem                                      |
| Partition 'e' -> /tmp Filesystem                                      |
| Partition 'f' -> /usr Filesystem                                      |
| Partition 'g' -> /home Filesystem                                     |
| Partition 'h' -> Additional Mount/Data Volume                         |
+-----------------------------------------------------------------------+
```

1. **Slices (Primary Partitioning):** The primary MBR partitions are called **slices** in BSD terminology. In FreeBSD and NetBSD, an MBR slice designated for BSD is assigned partition type `0xA5` (165 decimal). In OpenBSD, it is assigned type `0xA6` (166 decimal).
2. **Disklabels (Secondary Sub-partitioning):** Inside a BSD slice (or directly on a raw disk block device in dedicated mode), a **BSD disklabel** sub-partitions the slice into sub-units denoted by letters (`a` through `h`, or up to `p` on 16-partition disklabels).
3. **Partition Letter Conventions:**
   * **`a`**: Traditionally designated for the root (`/`) filesystem.
   * **`b`**: Reserved for system swap space (`swap`).
   * **`c`**: Defines the boundary of the **entire BSD slice** or raw disk. In OpenBSD and NetBSD, modifying partition `c` is blocked or restricted to preserve slice metadata.
   * **`d`**: In NetBSD/OpenBSD, `d` traditionally represents the **entire physical disk** (whereas `c` represents the BSD slice). On FreeBSD, `c` covers both contexts.
   * **`e`–`h` (or up to `p`)**: General-purpose filesystems (`/var`, `/tmp`, `/usr`, `/home`).

### 1.2 Modern Architecture: FreeBSD GEOM Framework vs. Traditional BSD Disklabel
Modern BSD systems split disk topology into distinct architectural subsystems:

* **FreeBSD GEOM Framework (`gpart`):** Modular storage architecture where disk operations are handled by GEOM classes (`GPT`, `MBR`, `BSD`, `MIRROR`). `gpart` abstracts away the legacy slice/disklabel distinction into unified partition schemes (e.g., `MBR`, `BSD`, `GPT`).
* **OpenBSD & NetBSD (`fdisk` + `disklabel`):** Retain explicit separation between `fdisk` (MBR slice editor) and `disklabel` (sub-partition editor). NetBSD also offers `gpt` for GUID Partition Table management.

### 1.3 Device Naming Schemes Across BSD Variants
Understanding naming conventions is critical for `/etc/fstab` configuration and recovery scenarios:

| BSD Variant | Storage Interface | Raw Disk | MBR Slice | BSD Sub-partition | Full Device Path |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **FreeBSD (GEOM)** | SATA/AHCI | `ada0` | `ada0s1` | `ada0s1a` | `/dev/ada0s1a` |
| **FreeBSD (GEOM)** | NVMe / SAS | `nda0` / `da0` | N/A (GPT) | Partition 2 | `/dev/da0p2` or `/dev/gpt/rootfs` |
| **OpenBSD** | SATA/SCSI/NVMe | `sd0` | `sd0` (s1) | `a` | `/dev/sd0a` (raw: `/dev/rsd0a`) |
| **NetBSD** | SATA/IDE | `wd0` | `wd0` | `a` | `/dev/wd0a` (raw: `/dev/rwd0a`) |

---

## 2. Guided Production Lab Exercises

---

### Lab Block 1: Legacy MBR Slicing & BSD Disklabel Management (`fdisk` & `bsdlabel`/`disklabel`)

#### Scenario
You are provisioning a legacy infrastructure appliance running an MBR-based BSD installation. You must create an MBR slice, write a valid BSD disklabel, partition it into designated system mounts (`/`, `swap`, `/var`, `/usr`), edit the label via ASCII configuration stream, and export it for automation backup.

#### Step 1: Inspect and Initialize the MBR Partition Table (`fdisk`)
Execute `fdisk` on the target disk device (`/dev/ada1` or `/dev/sd1`) to inspect existing slice metadata and write a primary BSD slice covering the entire drive.

```bash
# 1. View current MBR table layout
fdisk /dev/ada1
```

**Expected Output:**
```text
******* Working on device /dev/ada1 *******
parameters extracted from in-core disklabel are:
cylinders=20805 heads=255 sectors/track=63 (16065 sectors/cylinder)

Figures below are in sectors (512 bytes):
Media sector size is 512
Warning: BIOS sector numbering starts with sector 1
Information from DOS bootblock is:
The data for partition 1 is:
sysid 165 (0xa5),(FreeBSD/NetBSD/386BSD)
    start 63, size 33423225 (16320Meg), flag 80 (active)
        beg: cyl 0/ head 1/ sector 1;
        end: cyl 1023/ head 255/ sector 63
The data for partition 2 is <UNUSED>
The data for partition 3 is <UNUSED>
The data for partition 4 is <UNUSED>
```

```bash
# 2. Initialize a clean MBR table and create a FreeBSD slice (0xA5) spanning sector 63 to end
fdisk -BI /dev/ada1
```

**Expected Output:**
```text
Information from DOS bootblock is:
The data for partition 1 is:
sysid 165 (0xa5),(FreeBSD/NetBSD/386BSD)
    start 63, size 33423225 (16320Meg), flag 80 (active)
        beg: cyl 0/ head 1/ sector 1;
        end: cyl 1023/ head 255/ sector 63
The data for partition 2 is <UNUSED>
The data for partition 3 is <UNUSED>
The data for partition 4 is <UNUSED>
fdisk: Placement warning: a range of 63 sectors (sector 0 - 62) is reserved.
fdisk: Wrote sector 0 successfully
```

#### Step 2: Write Initial Boot Strap and BSD Disklabel (`bsdlabel` / `disklabel`)
Write the default raw disklabel into slice 1 (`ada1s1`) and install the standard BSD bootstrap code.

```bash
# Write standard initial disklabel layout and bootcode
bsdlabel -B -w /dev/ada1s1 auto
```

Now, dump the generated ASCII disklabel configuration to standard output to verify default geometry and auto-assigned partition `c`.

```bash
bsdlabel /dev/ada1s1
```

**Expected Output:**
```text
# /dev/ada1s1:
8 partitions:
#          size   offset    fstype   [fsize bsize bps/cpg]
  c:   33423225        0    unused        0     0        # "raw" part, don't edit
```

#### Step 3: Define Custom Partitions via ASCII Stream Editing
Create an ASCII layout definition file named `/tmp/disklabel.cfg` with explicit block calculations to allocate `a` (root: 4GB), `b` (swap: 2GB), `d` (var: 4GB), and `e` (usr: remaining space).

```bash
cat << 'EOF' > /tmp/disklabel.cfg
# /dev/ada1s1 production layout
8 partitions:
#          size   offset    fstype   [fsize bsize bps/cpg]
  a:    8388608        0    4.2BSD     2048 16384     0  # 4GB Root (starts offset 0)
  b:    4194304  8388608      swap                      # 2GB Swap (starts offset 8388608)
  c:   33423225        0    unused        0     0        # Full Slice Boundary
  d:    8388608 12582912    4.2BSD     2048 16384     0  # 4GB /var (starts offset 12582912)
  e:   12451705 20971520    4.2BSD     2048 16384     0  # ~6GB /usr (starts offset 20971520)
EOF
```

Apply the configuration file back to the disklabel:

```bash
bsdlabel -R /dev/ada1s1 /tmp/disklabel.cfg
bsdlabel /dev/ada1s1
```

**Expected Output:**
```text
# /dev/ada1s1:
8 partitions:
#          size   offset    fstype   [fsize bsize bps/cpg]
  a:    8388608        0    4.2BSD     2048 16384     0
  b:    4194304  8388608      swap
  c:   33423225        0    unused        0     0
  d:    8388608 12582912    4.2BSD     2048 16384     0
  e:   12451705 20971520    4.2BSD     2048 16384     0
```

---

#### Verification Questions (Block 1)

1. **During partition offset calculation, why does partition `a` start at offset `0` relative to the BSD slice (`ada1s1`), even though `fdisk` reported the slice itself starts at sector `63` of the physical disk?**
   * A) Sector 63 is automatically discarded by `bsdlabel` as corrupt space.
   * B) BSD disklabel offsets are relative to the start sector of the containing *slice*, not the absolute physical disk sector.
   * C) Partition `a` overwrites the MBR located at sector 0.
   * D) Sector 0 of a slice is reserved exclusively for partition `c`.

2. **An engineer attempts to delete partition `c` in a BSD disklabel on OpenBSD (`disklabel -e sd0`). The editor rejects the edit upon saving. What is the root cause?**
   * A) Partition `c` requires an ext2fs filesystem type.
   * B) Partition `c` defines the hard boundary of the slice/disk; deleting or modifying its range violates kernel disk geometry validation checks.
   * C) Partition `c` can only be modified using `fdisk`.
   * D) OpenBSD disklabels do not use letters; they use numeric IDs.

---

### Lab Block 2: Modern Partition Management with FreeBSD GEOM Framework (`gpart`)

#### Scenario
Modern SRE environments require GUID Partition Tables (GPT), 4KiB sector alignment (Advanced Format SSDs/NVMe), and GPT labels to decouple mount points from volatile device nodes like `/dev/ada0` or `/dev/da0`. You will construct a production-ready GPT layout using FreeBSD `gpart`.

#### Step 1: Create GPT Scheme and Install Bootcode
Destroy any stale headers on `/dev/ada0` and instantiate a clean GPT partitioning scheme.

```bash
# 1. Clear existing GEOM metadata and instantiate GPT
gpart destroy -F ada0 2>/dev/null || true
gpart create -s gpt ada0
```

**Expected Output:**
```text
ada0 created
```

```bash
# 2. Add the mandatory FreeBSD boot partition (512 KiB)
gpart add -t freebsd-boot -size 512k -l gptboot0 ada0
```

**Expected Output:**
```text
ada0p1 added
```

```bash
# 3. Embed the GPT bootstrap code into the PMBR and freebsd-boot partition
gpart bootcode -b /boot/pmbr -p /boot/gptboot -i 1 ada0
```

**Expected Output:**
```text
bootcode written to ada0
```

#### Step 2: Create Aligned Partitions with GPT Labels (`-a 4k`)
Create 4KiB-aligned partitions for swap and root filesystems, assigning logical labels to allow hardware-independent mounting.

```bash
# Create 4GB Swap aligned to 4K boundaries
gpart add -t freebsd-swap -size 4G -label system-swap -a 4k ada0

# Create 30GB UFS Root filesystem aligned to 4K boundaries
gpart add -t freebsd-ufs -size 30G -label system-root -a 4k ada0

# Create remaining capacity for ZFS pool / data partition
gpart add -t freebsd-zfs -label zfs-data -a 4k ada0
```

Display detailed partition geometry including start/end offsets, alignment, and GPT labels:

```bash
gpart show -l -e ada0
```

**Expected Output:**
```text
=>      40  83886000  ada0  GPT  (40G)
        40      1024     1  gptboot0  [bootcode]  (512K)
      1064         8        - free -  (4.0K)
      1072   8388608     2  system-swap  (4.0G)
   8389680  62914560     3  system-root  (30G)
  71304240  12581799     4  zfs-data  (6.0G)
  83886039     41         - free -  (20K)
```

#### Step 3: Production `/etc/fstab` Configuration using Device Labels
Configure `/etc/fstab` using persistent GEOM label paths (`/dev/gpt/`) to prevent system boot failures if drive enumeration order changes during reboot or controller replacement.

```bash
cat << 'EOF' > /etc/fstab
# Device                Mountpoint      FSType  Options         Dump    Pass#
/dev/gpt/system-root    /               ufs     rw              1       1
/dev/gpt/system-swap    none            swap    sw              0       0
EOF
```

Verify `/etc/fstab` syntax and test label resolution under `/dev/gpt/`:

```bash
ls -l /dev/gpt/
```

**Expected Output:**
```text
crw-r-----  1 root  operator  0x091 Aug  6 20:15 gptboot0
crw-r-----  1 root  operator  0x093 Aug  6 20:15 system-root
crw-r-----  1 root  operator  0x092 Aug  6 20:15 system-swap
crw-r-----  1 root  operator  0x094 Aug  6 20:15 zfs-data
```

---

#### Verification Questions (Block 2)

3. **What is the structural purpose of the `-a 4k` flag when executing `gpart add` on modern storage drives?**
   * A) It formats the partition automatically using UFS2 blocks of 4096 bytes.
   * B) It enforces sector start offsets to be even multiples of 4096 bytes (8 sectors of 512B), preventing Read-Modify-Write performance degradation on Advanced Format (4Kn/512e) storage media.
   * C) It limits the partition size to 4 Terabytes.
   * D) It enables AES-256 sector encryption within GEOM.

4. **An Administrator changes a server's SAS controller, causing the OS disk previously named `/dev/da0` to enumerate as `/dev/da4`. Why does a system configured with `/dev/gpt/system-root` in `/etc/fstab` still boot successfully without manual intervention?**
   * A) The kernel queries all disk controllers for MBR active flags during stage 2 booting.
   * B) GEOM automatically reads GPT header metadata on all discovered disks and exposes volume labels under `/dev/gpt/`, making node paths device-enumeration agnostic.
   * C) The `/etc/fstab` file is re-written by the bootloader before mounting root.
   * D) FreeBSD UEFI bootcode converts device nodes to IP addresses.

---

### Lab Block 3: Cross-BSD Disklabel Disaster Recovery & Advanced Diagnostics

#### Scenario
A corruption event zeroed out the first sector of a NetBSD/OpenBSD BSD slice (`/dev/sd0`), wiping out the disklabel header. The underlying UFS/FFS filesystems remain intact on disk blocks. You must use diagnostic recovery techniques (`scan_ffs`) to discover lost partition offset boundaries and reconstruct the disklabel manually.

#### Step 1: Simulate Disklabel Destruction and Diagnose Corruption
Execute a diagnostic check using `disklabel` on the corrupted disk device.

```bash
# Run disklabel inspection on damaged device /dev/sd0
disklabel sd0
```

**Expected Output:**
```text
disklabel: /dev/rsd0c: Invalid signature in disklabel
disklabel: /dev/rsd0c: No disk label read from disk.
```

#### Step 2: Recover Partition Offsets with `scan_ffs`
Execute `scan_ffs` to scan raw disk blocks for UFS/FFS superblock magic numbers (`0x011954` or `0x19540119`) and calculate exact start sectors and sizes.

```bash
scan_ffs /dev/rsd0c
```

**Expected Output:**
```text
# Size      Offset       Filesystem     Blocksize   Fragsize
  4194304   64           FFS1/FFS2      16384       2048
  16777216  4194368      FFS1/FFS2      16384       2048
  20971520  20971584     FFS1/FFS2      16384       2048
```

#### Step 3: Reconstruct Disklabel from Discovered Superblocks
Using the stdout values from `scan_ffs`, construct a recovery disklabel template file `/tmp/recover.cfg` and restore the label using `disklabel -R`.

```bash
cat << 'EOF' > /tmp/recover.cfg
type: SCSI
disk: SCSI disk
label: RecoveredDisk
flags:
bytes/sector: 512
sectors/track: 63
tracks/cylinder: 255
sectors/cylinder: 16065
cylinders: 5000
total sectors: 41943040

8 partitions:
#          size   offset    fstype   [fsize bsize bps/cpg]
  a:    4194304       64    4.2BSD     2048 16384        # Root filesystem
  b:   16777216  4194368    4.2BSD     2048 16384        # Data partition (/usr)
  c:   41943040        0    unused                        # Entire disk boundary
  d:   20971520 20971584    4.2BSD     2048 16384        # Extra partition (/var)
EOF
```

Apply the restored disklabel to the physical disk:

```bash
disklabel -R sd0 /tmp/recover.cfg
disklabel sd0
```

**Expected Output:**
```text
# /dev/sd0:
type: SCSI
disk: SCSI disk
label: RecoveredDisk
flags:
bytes/sector: 512
sectors/track: 63
tracks/cylinder: 255
sectors/cylinder: 16065
cylinders: 5000
total sectors: 41943040

8 partitions:
#          size   offset    fstype   [fsize bsize bps/cpg]
  a:    4194304       64    4.2BSD     2048 16384
  b:   16777216  4194368    4.2BSD     2048 16384
  c:   41943040        0    unused
  d:   20971520 20971584    4.2BSD     2048 16384
```

Verify filesystem integrity on partition `a` using `fsck`:

```bash
fsck_ffs -n /dev/rsd0a
```

**Expected Output:**
```text
** /dev/rsd0a (NO WRITE)
** File System: FFS2 Volume: 
** Last Mounted on: /
** Phase 1 - Check Blocks and Sizes
** Phase 2 - Check Pathnames
** Phase 3 - Check Connectivity
** Phase 4 - Check Reference Counts
** Phase 5 - Check Cyl groups
3214 files, 412045 used, 1685107 free (1235 frags, 210484 blocks, 0.0% fragmentation)
```

---

#### Verification Questions (Block 3)

5. **How does `scan_ffs` locate lost BSD partition boundaries when the disklabel table is missing?**
   * A) By reading backup copies of `/etc/fstab` stored in raw sector 1.
   * B) By scanning sequential sector blocks for valid UFS/FFS superblock signatures, extracting cylinder group headers, and calculating filesystem block offsets.
   * C) By querying the system BIOS CMOS log.
   * D) By executing `gpart recover` under the hood.

6. **On FreeBSD, which command displays the full hierarchical dependency tree of GEOM storage modules (including DISK, PART, MBR, BSD, and LABEL classes)?**
   * A) `disklabel -tree`
   * B) `geom disk list` / `gpart status` / `sysctl kern.geom.conftxt`
   * C) `fdisk -s`
   * D) `cat /proc/partitions`

---

## 3. Comprehensive Verification Answers & Technical Rationale

<details>
<summary><strong>Click to expand Answer Key & Detailed Rationale</strong></summary>

### Question 1
* **Correct Answer:** **B**
* **Technical Rationale:** In the traditional BSD two-tier partitioning model, MBR slices subdivide the physical media first. The BSD disklabel resides inside a specific slice (`sysid 0xA5` or `0xA6`). Consequently, sector offset `0` inside a disklabel definition file corresponds to the starting sector of that *slice*, not block 0 of the entire physical hard drive.

### Question 2
* **Correct Answer:** **B**
* **Technical Rationale:** In OpenBSD and NetBSD, partition `c` represents the full slice or full disk raw container boundary. The kernel disklabel subsystem enforces strict validation rules that prevent administrators from deleting or altering partition `c` size boundaries to prevent catastrophic loss of access to raw disk geometry metadata.

### Question 3
* **Correct Answer:** **B**
* **Technical Rationale:** Modern drives (Advanced Format 512e/4Kn) use physical sector sizes of 4096 bytes. If a partition starts on an unaligned sector (e.g., sector 63), single block write operations span two physical sectors, resulting in severe Read-Modify-Write performance penalties. The `-a 4k` flag in `gpart` forces alignment to sector bounds that are divisible by 4096 bytes (8 x 512-byte sectors).

### Question 4
* **Correct Answer:** **B**
* **Technical Rationale:** FreeBSD's GEOM subsystem inspects GPT header fields dynamically upon drive attachment. The GEOM `LABEL` class parses GPT partition labels and exposes them as persistent nodes under `/dev/gpt/<label>`. This abstracts storage attachments from underlying bus enumeration changes (`/dev/ada0`, `/dev/da4`, etc.).

### Question 5
* **Correct Answer:** **B**
* **Technical Rationale:** `scan_ffs` scans disk sectors sequentially searching for the UFS/FFS superblock magic number (`SBLOCKMAGIC` - `0x011954`). When found, it parses the superblock structure to extract the block size, sector offsets, and partition extent, outputting valid disklabel offset lines that can be directly piped to `disklabel -R`.

### Question 6
* **Correct Answer:** **B**
* **Technical Rationale:** FreeBSD's GEOM architecture models storage topologies as a Directed Acyclic Graph (DAG). The command `geom disk list`, along with `gpart status` and `sysctl kern.geom.conftxt`, outputs the complete kernel storage tree (Providers, Consumers, and GEOM classes).

</details>

---

## 4. Official References & Citation Links
* [LPI BSD Specialist Exam Objectives 702-100](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
* [FreeBSD Handbook: Storage & Partitioning (`gpart`)](https://docs.freebsd.org/en/books/handbook/disks/)
* [FreeBSD Manual Pages: `bsdlabel(8)`](https://man.freebsd.org/cgi/man.cgi?bsdlabel(8))
* [FreeBSD Manual Pages: `gpart(8)`](https://man.freebsd.org/cgi/man.cgi?gpart(8))
* [OpenBSD Manual Pages: `disklabel(8)`](https://man.openbsd.org/disklabel.8)
* [OpenBSD Manual Pages: `scan_ffs(8)`](https://man.openbsd.org/scan_ffs.8)