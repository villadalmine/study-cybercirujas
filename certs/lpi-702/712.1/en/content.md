# LPI-702: BSD Specialist Certification (Exam 702-100)
## Topic 712.1: BSD Partitioning and Disk Labels

---

### 1. Architectural Motivation & Production Fundamentals

Traditional x86 storage architectures inherited the IBM PC Master Boot Record (MBR) partition table format introduced in PC-DOS 2.0 (1983). The MBR specification imposes severe constraints: a maximum of four primary partitions (or three primary and one extended partition), 32-bit Logical Block Addressing (LBA) limiting maximum addressable disk capacity to 2 TiB ($2^{32} \times 512$ bytes), and a complete lack of metadata redundancy.

To bypass MBR limitations while remaining hardware-compatible with PC BIOS firmware, the BSD Unix ecosystem implemented a two-tiered hierarchical storage layout:

1. **Slices (Primary MBR Partitions):** At the hardware/BIOS level, the disk is divided into standard MBR partitions. In BSD nomenclature, these MBR entries are designated as **Slices** (e.g., `/dev/ada0s1`, `/dev/da0s2`).
2. **BSD Partitions (Disklabels):** Inside a single BSD slice (traditionally assigned MBR Partition Type `0xA6` for OpenBSD, `0xA5` for FreeBSD, and `0xA9` for NetBSD), BSD writes its own secondary partition table called a **Disk Label** (or `bsdlabel`). This disklabel further subdivides the slice into up to 8 (legacy FreeBSD/NetBSD) or 16 (OpenBSD / modern FreeBSD `gpart`) sub-partitions identified by single letters (`a` through `h` or `p`).

```
+-----------------------------------------------------------------------------------+
| Physical Storage Device: /dev/da0 (e.g., 1 TB NVMe / SAS)                          |
+-----------------------------------------------------------------------------------+
| Sector 0: Master Boot Record (MBR Partition Table)                                |
| +-----------------+-----------------+-----------------+-------------------------+ |
| | Slice 1 (0xA5)  | Slice 2 (0x83)  | Slice 3 (0x82)  | Slice 4 (Unused)        | |
| | FreeBSD         | Linux ext4      | Linux Swap      |                         | |
| +--------+--------+-----------------+-----------------+-------------------------+ |
+----------|------------------------------------------------------------------------+
           v
+-----------------------------------------------------------------------------------+
| FreeBSD Slice 1: /dev/da0s1                                                       |
+-----------------------------------------------------------------------------------+
| Sector 0: Primary Boot Record (PBR / stage1 boot)                                 |
| Sector 1: struct disklabel (512 bytes, DISKMAGIC = 0x82564557)                     |
| +-------------------------------------------------------------------------------+ |
| | /dev/da0s1a : UFS2 / Root Filesystem (/) [Offset: LBA 16, Size: 10GB]         | |
| | /dev/da0s1b : Swap Space               [Offset: LBA 20971536, Size: 8GB]     | |
| | /dev/da0s1c : Raw Slice Cover-All      [Offset: LBA 0, Size: Entire Slice]    | |
| | /dev/da0s1d : UFS2 / /var              [Offset: LBA 37748752, Size: 50GB]     | |
| | /dev/da0s1e : UFS2 / /usr              [Offset: LBA 142606352, Size: 100GB]    | |
| | /dev/da0s1f : UFS2 / /home             [Offset: LBA 352321552, Size: Remainder]| |
| +-------------------------------------------------------------------------------+ |
+-----------------------------------------------------------------------------------+
```

#### Anatomical Breakdown of `struct disklabel`
In BSD C headers (`sys/disklabel.h`), the `struct disklabel` resides within the second 512-byte sector (LBA 1) of the disk or slice. Key binary fields include:

* `d_magic` (`uint32_t`): Magic number (`0x82564557` / `DISKMAGIC`). Verifies disklabel validity.
* `d_type` (`uint16_t`): Drive type identifier (e.g., `DTYPE_SCSI`, `DTYPE_ESDI`).
* `d_secsize` (`uint32_t`): Sector size in bytes (typically 512 or 4096).
* `d_nsectors` (`uint32_t`): Sectors per track.
* `d_ntracks` (`uint32_t`): Tracks per cylinder.
* `d_ncylinders` (`uint32_t`): Total cylinders on device.
* `d_secpercyl` (`uint32_t`): Sectors per cylinder ($d\_nsectors \times d\_ntracks$).
* `d_secperunit` (`uint32_t`): Total sectors on the entire disk or slice.
* `d_npartitions` (`uint16_t`): Number of partition entries defined in `d_partitions[]`.
* `d_partitions[MAXPARTITIONS]` (`struct partition` array): Each entry specifies:
  * `p_size` (`uint32_t`): Number of sectors in partition.
  * `p_offset` (`uint32_t`): Absolute LBA offset from start of disk/slice.
  * `p_fstype` (`uint8_t`): File system type identifier (`FS_UNUSED=0`, `FS_SWAP=1`, `FS_V6=2`, `FS_V7=3`, `FS_SYSV=4`, `FS_V71D=5`, `FS_BSDFFS=7`, `FS_MSDOS=8`, `FS_BSDLFS=9`, `FS_OTHER=10`, `FS_HPFS=11`, `FS_UFS2=14`, `FS_ZFS=27`).

#### Standard BSD Partition Letter Assignments
By strict convention across FreeBSD, OpenBSD, and NetBSD, specific partition letters are reserved for standardized operational roles:

| Partition Letter | Functional Role | Operational Description |
| :--- | :--- | :--- |
| **`a`** | Root Filesystem (`/`) | System boot partition containing `/boot`, essential binaries, and initial kernel configuration. |
| **`b`** | Swap Space | Virtual memory paging area. Addressable directly by the kernel swapper subsystem. |
| **`c`** | Raw Slice / Device | Spans the **entire** slice or physical disk. Used by system utilities (`fsck`, `dump`, `restore`, `gpart`) for raw I/O. Must **never** format with a filesystem. |
| **`d`** | Raw Disk (NetBSD/OpenBSD) / Standard Partition (FreeBSD) | On NetBSD/OpenBSD, `d` represents the entire physical disk (across all slices). On FreeBSD, `d` is an ordinary general-purpose filesystem partition (`/var`). |
| **`e` - `h` / `p`** | User Filesystems | Mounted as general filesystems (`/usr`, `/var`, `/tmp`, `/home`). OpenBSD extends this range up to `p` (16 total entries). |

---

### 2. Technical Comparisons & Architecture Trade-off Matrices

#### Table 1: Storage Partitioning Schemes Comparison

| Architectural Metric | Master Boot Record (MBR Slices) | BSD Disklabel (Traditional) | GUID Partition Table (GPT) |
| :--- | :--- | :--- | :--- |
| **Addressing Limits** | 32-bit LBA (Max 2.0 TiB at 512B/sector) | 32-bit LBA relative to slice offset (2.0 TiB max) | 64-bit LBA (Max 9.4 ZiB / 8 ZiB layout boundary) |
| **Maximum Partition Count** | 4 Primary (or 3 Primary + 1 Extended) | 8 (FreeBSD legacy), 16 (OpenBSD/NetBSD/modern GEOM) | 128 partitions (default in header; expandable) |
| **Metadata Redundancy** | None (Single sector LBA 0; vulnerable to corruption) | None (Single sector LBA 1 within slice; no backup header) | Primary Header (LBA 1) + Secondary Backup Header (Last LBA of disk) |
| **Hierarchy Level** | Level 1 (Disk Hardware Abstraction) | Level 2 (Sub-partitioning nested within MBR Slice) | Level 1 (Unified Disk Partitioning Scheme) |
| **Integrity Verification** | Boot signature check `0xAA55` only | `DISKMAGIC` (`0x82564557`) + Header Checksum | CRC32 checksums for Header and Partition Array |
| **Firmware Compatibility** | Legacy BIOS / CS-MBR | Legacy BIOS via MBR PBR boot code | Native UEFI / BIOS via Protective MBR (PMBR) |

#### Table 2: BSD Disk Administration Toolsets

| Utility | Target OS Scope | Architecture / Framework | Dynamic Resizing | Partition Scheme Support |
| :--- | :--- | :--- | :--- | :--- |
| **`gpart(8)`** | FreeBSD 8.0+ | Modular GEOM Framework (`geom_part.ko`) | Supported (`gpart resize`) | GPT, MBR, BSD, VTOC8, PC98, APM |
| **`disklabel(8)`** | OpenBSD / NetBSD | Direct Kernel ioctl (`DIOCWDINFO`, `DIOCGDINFO`) | Supported (`disklabel -e`) | BSD Disklabel, MBR wrapper |
| **`bsdlabel(8)`** | Legacy FreeBSD | Direct Sector I/O / BSD Disklabel Class | Manual sector calculation | BSD Disklabel only |
| **`fdisk(8)`** | FreeBSD / OpenBSD | Low-level MBR Sector Manipulator | Destructive / Manual | MBR Slices only |

---

### 3. Production Automation Scripts & Infrastructure Configurations

#### Automated Zero-Touch FreeBSD Partitioning Engine (`setup_bsd_storage.sh`)
This script uses FreeBSD `gpart(8)` and `glabel(8)` to create an aligned dual-scheme disk setup (legacy MBR slice + BSD disklabel), assign filesystem labels, construct UFS2 filesystems, and auto-generate `/etc/fstab`.

```bash
#!/usr/bin/env sh
# ==============================================================================
# Script: setup_bsd_storage.sh
# Target OS: FreeBSD 13.x / 14.x
# Description: Automated, production-ready MBR slice and BSD disklabel provisioner
# ==============================================================================
set -eu

TARGET_DISK="da1"
SLICE_ID="s1"
TARGET_SLICE="${TARGET_DISK}${SLICE_ID}"

echo "[+] Destroying stale GEOM metadata on /dev/${TARGET_DISK}..."
sysctl kern.geom.debugflags=16
gpart destroy -F "${TARGET_DISK}" || true

echo "[+] Step 1: Initializing MBR Partition Table on /dev/${TARGET_DISK}..."
gpart create -s MBR "${TARGET_DISK}"

echo "[+] Step 2: Creating FreeBSD Slice (0xA5) spanning entire disk..."
gpart add -t freebsd "${TARGET_DISK}"

echo "[+] Step 3: Writing MBR Bootcode (boot0sio for serial console / boot0 for standard)..."
gpart bootcode -b /boot/boot0 "${TARGET_DISK}"

echo "[+] Step 4: Nesting BSD Disklabel scheme inside /dev/${TARGET_SLICE}..."
gpart create -s BSD "${TARGET_SLICE}"

echo "[+] Step 5: Allocating BSD Partitions with LBA alignment..."
# Partition 'a': 4GB UFS2 Root
gpart add -t freebsd-ufs -a 4k -s 4g "${TARGET_SLICE}"
# Partition 'b': 2GB Swap
gpart add -t freebsd-swap -a 4k -s 2g "${TARGET_SLICE}"
# Partition 'd': 10GB /var
gpart add -t freebsd-ufs -a 4k -s 10g "${TARGET_SLICE}"
# Partition 'e': 15GB /usr
gpart add -t freebsd-ufs -a 4k -s 15g "${TARGET_SLICE}"
# Partition 'f': Remaining capacity /data
gpart add -t freebsd-ufs -a 4k "${TARGET_SLICE}"

echo "[+] Step 6: Installing BSD Bootcode (boot1) into Slice 1..."
gpart bootcode -b /boot/boot1 "${TARGET_SLICE}"

echo "[+] Step 7: Formatting UFS2 Filesystems with Soft updates & SU+J..."
newfs -U -j -L rootfs "/dev/${TARGET_SLICE}a"
newfs -U -j -L varfs  "/dev/${TARGET_SLICE}d"
newfs -U -j -L usrfs  "/dev/${TARGET_SLICE}e"
newfs -U -j -L datafs "/dev/${TARGET_SLICE}f"

echo "[+] Setup complete. Partition layout for ${TARGET_DISK}:"
gpart show -p "${TARGET_DISK}"
gpart show -p "${TARGET_SLICE}"
```

#### Syntactically Valid `/etc/fstab` Manifest (Label-Based & Device-Path Referencing)
```fstab
# Device                Mountpoint      FStype  Options         Dump    Pass#
# ==============================================================================
# Root Filesystem referenced via GEOM Filesystem Label
/dev/ufs/rootfs         /               ufs     rw,noatime      1       1

# Swap space allocated on BSD Partition 'b'
/dev/da1s1b             none            swap    sw              0       0

# Variable data partition with Soft Updates + Journaling
/dev/ufs/varfs          /var            ufs     rw,noatime      2       2

# System Binaries and Libraries
/dev/ufs/usrfs          /usr            ufs     rw,noatime      2       2

# Secondary Volume referenced via direct BSD Partition Slice notation
/dev/da1s1f             /data           ufs     rw,noatime      2       2

# Process Filesystem Abstraction
proc                    /proc           procfs  rw              0       0
```

---

### 4. Real CLI Executions & Raw Sector Inspection Outputs

#### Execution 1: Querying the GEOM Disk Topology on FreeBSD
```console
$ geom disk list da1
Geom name: da1
Providers:
1. Name: da1
   Mediasize: 107374182400 (100GiB)
   Sectorsize: 512
   Stripesize: 4096
   Stripeoffset: 0
   Mode: r0w0e0
   descr: QEMU HARDDISK
   lunid: 5000457601234567
   ident: QM00001
   rotationrate: 0
   fwsectors: 63
   fwheads: 255
```

#### Execution 2: Detailed Partition Display via `gpart show`
```console
$ gpart show -p da1
=>       63  209715137  da1  MBR  (100GiB)
         63       63       - free -  (31KiB)
        126  209715074  da1s1  freebsd  [active]  (100GiB)

$ gpart show -p da1s1
=>        0  209715074  da1s1  BSD  (100GiB)
          0    8388608  da1s1a  freebsd-ufs  (4.0GiB)
    8388608    4194304  da1s1b  freebsd-swap  (2.0GiB)
   12582912   20971520  da1s1d  freebsd-ufs  (10GiB)
   33554432   31457280  da1s1e  freebsd-ufs  (15GiB)
   65011712  144703362  da1s1f  freebsd-ufs  (69GiB)
```

#### Execution 3: Low-Level Hexdump Analysis of `struct disklabel` at LBA 1
Reading sector 1 of `/dev/da1s1` directly to verify `DISKMAGIC` (`0x82564557` in little-endian order: `57 45 56 82`):

```console
$ dd if=/dev/da1s1 bs=512 count=1 skip=1 | hexdump -C
1+0 records in
1+0 records out
512 bytes transferred in 0.000142 secs (3605633 bytes/sec)
00000000  57 45 56 82 01 00 00 00  00 02 00 00 3f 00 00 00  |WEV.........?...|
00000010  ff 00 00 00 00 04 00 00  72 fab 0c 0c 00 00 00 00  |........r.......|
00000020  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
*
00000080  08 00 07 00 00 00 80 00  00 00 00 00 00 00 00 00  |................|
00000090  00 00 40 00 00 00 00 00  07 00 00 00 00 00 00 00  |..@.............|
000000a0  00 00 20 00 00 00 80 00  01 00 00 00 00 00 00 00  |.. .............|
000000b0  00 00 00 00 00 00 20 01  07 00 00 00 00 00 00 00  |...... .........|
000000c0  00 00 40 01 00 00 20 01  07 00 00 00 00 00 00 00  |..@... .........|
000000d0  02 4b 20 08 00 00 40 03  07 00 00 00 00 00 00 00  |.K ...@.........|
000000e0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
*
000001f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 perform|................|
00000200
```

#### Execution 4: Inspecting and Editing OpenBSD Disklabels (`disklabel`)
```console
$ doas disklabel sd0
# /dev/rsd0c:
type: SCSI
disk: SCSI disk
label: VBOX HARDDISK
duid: a1b2c3d4e5f60789
flags:
bytes/sector: 512
sectors/track: 63
tracks/cylinder: 255
sectors/cylinder: 16065
cylinders: 13054
total sectors: 209715200
boundstart: 64
boundend: 209715136

16 partitions:
#                size        offset  fstype [fsize bsize cpg]
  a:          4194304            64  4.2BSD   2048 16384  16 # /
  b:          4194304       4194368    swap                  # swap
  c:        209715200             0    unused                # entire disk
  d:         20971520            8388672  4.2BSD   2048 16384  16 # /var
  e:         10485760          29360192  4.2BSD   2048 16384  16 # /tmp
  f:         41943040          39845952  4.2BSD   2048 16384  16 # /usr
  g:         20971520          81788992  4.2BSD   2048 16384  16 # /usr/X11R6
  h:         41943040         102760512  4.2BSD   2048 16384  16 # /usr/local
  k:         65011684         144703552  4.2BSD   4096 32768  32 # /home
```

---

### 5. Production Troubleshooting & Diagnostic Workflows

```
                        +-----------------------------------------+
                        | Disk Mount Failure / Partition Corruption|
                        +-----------------------------------------+
                                             |
                                             v
                        +-----------------------------------------+
                        | Run: gpart show or disklabel <device>   |
                        +-----------------------------------------+
                                             |
                   +-------------------------+-------------------------+
                   |                                                   |
                   v                                                   v
     [GEOM Provider Locked Error]                        [Corrupted Disklabel Metadata]
     "Operation not permitted"                           "Invalid magic number" / Missing Partitions
                   |                                                   |
                   v                                                   v
     +---------------------------+                       +---------------------------+
     | Check kernel write-lock   |                       | Dump sector 1 via dd:     |
     | sysctl kern.geom.debugflags|                      | dd if=/dev/da0s1 count=1  |
     +---------------------------+                       | skip=1 | hexdump -C       |
                   |                                     +---------------------------+
                   v                                                   |
     +---------------------------+                                     v
     | Temporarily disable lock: |                       +---------------------------+
     | sysctl kern.geom.debugflags=16                    | Check DISKMAGIC (0x82564557)|
     +---------------------------+                       +---------------------------+
                   |                                                   |
                   +-------------------------+-------------------------+
                                             |
                                             v
                        +-----------------------------------------+
                        | Restore Disklabel via Backup File or    |
                        | Rebuild Partition Table Metadata:       |
                        | FreeBSD: gpart recover / gpart restore  |
                        | OpenBSD: disklabel -R <dev> <protofile> |
                        +-----------------------------------------+
                                             |
                                             v
                        +-----------------------------------------+
                        | Run File System Integrity Check:        |
                        | fsck -t ufs -y /dev/<device_partition>  |
                        +-----------------------------------------+
```

#### Diagnostic Scenario 1: GEOM Safety Locks Preventing Disklabel Modification
**Symptom:** Executing `gpart create`, `gpart add`, or writing raw sector data to a BSD slice fails with:
```console
gpart: GEOM provider da1s1 is locked: Operation not permitted
```

**Root Cause:** The FreeBSD GEOM topology enforces a write-lock (`footprint` check) on active storage providers. If any partition within slice `da1s1` is currently mounted or accessed by the kernel, GEOM blocks metadata updates to prevent filesystem corruption.

**Remediation Steps:**
1. Unmount all active partitions belonging to the target slice:
   ```console
   # umount -f /dev/da1s1*
   ```
2. If the slice contains the root or system filesystems that cannot be unmounted, override GEOM safety locks via `sysctl`:
   ```console
   # sysctl kern.geom.debugflags=16
   kern.geom.debugflags: 0 -> 16
   ```
   *Note: `debugflags=16` sets the `BERASE` bit, allowing raw writes to protected storage providers.*

3. Execute the required `gpart` modification.
4. Immediately reset `debugflags` back to `0` to restore kernel storage safety guarantees:
   ```console
   # sysctl kern.geom.debugflags=0
   ```

---

#### Diagnostic Scenario 2: Corrupted `DISKMAGIC` Header & Partition Table Recovery
**Symptom:** Kernel panics or reports `Invalid disklabel magic number` when mounting `/dev/da1s1a`. Output of `gpart show da1s1` indicates `CORRUPT` or missing partition definitions.

**Remediation Workflow:**

1. **Sector Level Diagnostic:** Verify whether the disklabel sector (LBA 1) has been zeroed out or overwritten by an errant `dd` command:
   ```console
   # dd if=/dev/da1s1 bs=512 count=1 skip=1 | hexdump -C | head -n 4
   ```
   If offset `00000000` does not display `57 45 56 82`, the disklabel header is destroyed.

2. **Recovering via OpenBSD Backup Disklabels:**
   OpenBSD automatically saves ASCII backups of the disklabel in `/var/backups/disklabel.*`. To restore a saved layout to disk `sd0`:
   ```console
   # disklabel -R sd0 /var/backups/disklabel.sd0.current
   ```

3. **Rebuilding FreeBSD `gpart` Disklabel Metadata:**
   If using FreeBSD GEOM, `gpart` can attempt auto-recovery if primary metadata mirrors exist, or you can manually restore from a previously exported `gpart` backup:
   ```console
   # Export layout backup during normal operations:
   # gpart backup da1s1 > /etc/backups/da1s1.layout

   # Restore layout to slice:
   # gpart restore da1s1 < /etc/backups/da1s1.layout
   ```

4. **Filesystem Consistency Validation:**
   After repairing the disklabel partition boundaries, run `fsck` across all restored BSD partitions:
   ```console
   # fsck_ufs -y /dev/da1s1a
   # fsck_ufs -y /dev/da1s1d
   ```

---

### 6. References

* **LPI BSD Specialist Certification Overview:**  
  https://www.lpi.org/our-certifications/bsd-specialist-overview/

* **FreeBSD Manual Pages - `gpart(8)` System Administration Utility:**  
  https://man.freebsd.org/cgi/man.cgi?gpart(8)

* **FreeBSD Manual Pages - `bsdlabel(8)` Disk Labeling Utility:**  
  https://man.freebsd.org/cgi/man.cgi?bsdlabel(8)

* **OpenBSD Manual Pages - `disklabel(8)` Read and Write Disk Labels:**  
  https://man.openbsd.org/disklabel.8

* **FreeBSD Handbook - Storage Administration & GEOM Framework:**  
  https://docs.freebsd.org/en/books/handbook/disks/