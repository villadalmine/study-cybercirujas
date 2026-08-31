# 104.1 — Create Partitions and Filesystems

**LPIC-1 · Exam 101-500 · Version 5.0 · Weight: 3.12**

**Objective scope:** Manage MBR partition tables · Use `mkfs` commands to create ext2/ext3/ext4, XFS, VFAT and exFAT filesystems · Awareness of ReiserFS and Btrfs · Basic knowledge of `gdisk` and `parted` with GPT.

**Terms and utilities:** `fdisk`, `gdisk`, `parted`, `mkfs`, `mkswap`

---

## 1. The production problem: why partitioning is a reliability control, not a formality

In a single-workstation mental model, partitioning is a one-time chore performed by the installer. In a fleet, it is one of the few decisions that is **effectively immutable at runtime** and that propagates a failure across an entire tier.

Three concrete production failure classes trace directly back to this objective:

**1.1 — The unbounded-writer outage.** A node runs with `/`, `/var`, and `/var/log` on one filesystem. A container in a crash loop emits 4 GB/hour of JSON logs. When the filesystem hits 100 %, the kubelet cannot write its checkpoint, `containerd` cannot write its state database, `systemd-journald` rotates into nothing, and `sshd` can still accept a connection but PAM cannot write `lastlog` — so you get a login that hangs. A 20-line change at provisioning time (`/var/log` on its own volume, or ext4 reserved blocks left at 5 % on `/`) converts a total node loss into a degraded log path. Partitioning is **blast-radius containment implemented in the block layer**.

**1.2 — The silent 30 % throughput tax.** A partition created at sector 63 (the DOS/CHS legacy default) on a device with 4 KiB physical sectors, or on a RAID-5 LUN with a 64 KiB stripe unit, means every filesystem block straddles two physical units. Every write becomes a read-modify-write. Nothing logs an error. You discover it six months later in a latency histogram. Alignment is decided once, at `mkpart` time, and cannot be fixed without recreating the filesystem.

**1.3 — The unbootable golden image.** An image built on a host with `e2fsprogs` 1.47 or `xfsprogs` 6.x carries filesystem features (`orphan_file`, `nrext64`) that a 4.18 kernel refuses to mount. The build passes. The deploy to the older tier hard-fails at `initramfs`. `mkfs` defaults are a **compatibility contract between the build host and every kernel that will ever mount the volume**, and that contract is invisible unless you pin it.

Everything below is in service of making those three decisions deliberately and verifiably.

---

## 2. The substrate: sectors, alignment and the block layer

Before any partition table exists, the kernel already knows four numbers about the device. Every alignment decision derives from them.

| sysfs attribute | Meaning | Typical value |
|---|---|---|
| `queue/logical_block_size` | Smallest addressable unit the device will accept for I/O (the "sector" all tools count in) | 512 |
| `queue/physical_block_size` | Smallest unit the device actually writes atomically | 512 or 4096 |
| `queue/minimum_io_size` | Below this, the device does read-modify-write | = physical block size |
| `queue/optimal_io_size` | Full-stripe width advertised by a RAID controller / SAN; `0` = unknown | 0, or `chunk × data_disks` |
| `alignment_offset` | How far the first physical block is shifted (misreported cheap USB bridges) | 0 |

```
$ lsblk -o NAME,SIZE,TYPE,PHY-SEC,LOG-SEC,MIN-IO,OPT-IO,ALIGNMENT,ROTA,DISC-GRAN,MODEL
NAME      SIZE TYPE PHY-SEC LOG-SEC MIN-IO OPT-IO ALIGNMENT ROTA DISC-GRAN MODEL
nvme0n1 931.5G disk     512     512    512      0         0    0      512B SAMSUNG MZVLB1T0HBLR
sda       3.6T disk    4096     512   4096      0         0    1        0B ST4000NM0033-9ZM
md0       7.3T raid5    4096    4096  65536 262144         0    1        0B
```

```
$ cat /sys/block/md0/queue/{logical_block_size,physical_block_size,minimum_io_size,optimal_io_size}
4096
4096
65536
262144
```

Read that last block: chunk size 64 KiB, four data members → optimal I/O 256 KiB. Those two numbers are exactly what you will hand to `mkfs.xfs -d su=64k,sw=4` in §7.4.

**Terminology that the exam and the tools disagree on:** `sda` above is a **512e** drive — 4096-byte physical sectors emulated as 512-byte logical sectors. `fdisk`, `parted` and `gdisk` count in *logical* sectors (512), but correctness is measured against the *physical* sector (4096). A **4Kn** drive reports 4096/4096 and will reject a 512-byte-aligned partition outright.

### 2.1 The 1 MiB rule

Every modern tool defaults the first partition to **sector 2048 = 1 MiB**. This is not arbitrary: 1 MiB is divisible by 4 KiB (physical sectors), 8 KiB/16 KiB (NAND pages), 128 KiB–1 MiB (SSD erase blocks), and by every common RAID stripe unit up to 1 MiB. Aligning to 1 MiB and sizing partitions in whole MiB makes every subsequent structure aligned by construction.

The historical alternative — sector 63, one track of 63 sectors in CHS geometry — is what `fdisk` used before util-linux 2.17 and what some appliance imaging tools still produce.

```
$ sudo parted /dev/sda align-check optimal 1
1 aligned

$ sudo parted /dev/sdb align-check optimal 1
1 not aligned
```

---

## 3. Partition table formats: MBR versus GPT

### 3.1 MBR (DOS label) anatomy

The Master Boot Record is **LBA 0 only** — 512 bytes total:

| Offset | Size | Content |
|---|---|---|
| `0x000` | 440 B | Bootstrap code (stage 1 of the boot loader) |
| `0x1B8` | 4 B | Disk signature / "NT disk identifier" — used by `PARTUUID=` as `<sig>-<nn>` |
| `0x1BC` | 2 B | Reserved (usually `0x0000`) |
| `0x1BE` | 64 B | **Partition table: 4 entries × 16 bytes** |
| `0x1FE` | 2 B | Boot signature `0x55AA` |

Each 16-byte entry: boot flag (1 B), CHS start (3 B), **partition type ID (1 B)**, CHS end (3 B), **LBA start (4 B)**, **sector count (4 B)**.

The two 32-bit fields are the origin of every MBR limit:

- Max start LBA and max length = 2³² − 1 sectors → **2 TiB with 512-byte logical sectors** (2³² × 512 = 2 199 023 255 552 B). On a native 4Kn disk the same table reaches 16 TiB, which is why `fdisk` phrases its refusal in bytes, not terabytes.
- **Four primary partitions.** More requires an *extended* partition (type `0x05` or `0x0F`) acting as a container. Inside it, each **logical** partition is preceded by its own EBR (Extended Boot Record) — a singly-linked list. Logical partitions are always numbered from **5** upward, regardless of how many primaries exist.

```
$ sudo fdisk -l /dev/sdb
Disk /dev/sdb: 50 GiB, 53687091200 bytes, 104857600 sectors
Disk model: QEMU HARDDISK   
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disklabel type: dos
Disk identifier: 0x3f7a1c08

Device     Boot    Start       End   Sectors  Size Id Type
/dev/sdb1            2048   1050623   1048576  512M 83 Linux
/dev/sdb2         1050624 104857599 103806976 49.5G  5 Extended
/dev/sdb5         1052672  21024767  19972096  9.5G 83 Linux
/dev/sdb6        21026816  41988095  20961280   10G 83 Linux
```

Note `sdb5` starts at 1052672, **2048 sectors after** the extended container starts at 1050624. That gap holds the EBR and preserves alignment. A hand-computed layout that forgets this gap either overwrites the EBR or misaligns every logical partition.

### 3.2 GPT anatomy

| LBA | Content |
|---|---|
| 0 | **Protective MBR** — a single entry of type `0xEE` spanning the whole disk, so MBR-only tools see "full, unknown" instead of "empty" |
| 1 | **Primary GPT header** — signature `EFI PART`, disk GUID, CRC32 of itself, CRC32 of the entry array, pointer to the backup header |
| 2–33 | **Partition entry array** — 128 entries × 128 bytes = 16 KiB |
| … | Usable area (first usable sector = 34; tools start at 2048 for alignment) |
| −33…−2 | Backup entry array |
| −1 (last LBA) | **Backup GPT header** |

Each entry holds: **partition type GUID** (16 B), **unique partition GUID** (16 B — this is `PARTUUID=`), first LBA and last LBA (8 B each, 64-bit), attribute flags (8 B), and a **36-character UTF-16 name** (`PARTLABEL=`).

Consequences that matter operationally:

- 64-bit LBAs → **8 ZiB** at 512 B/sector. The limit is gone.
- 128 partitions by default, growable.
- **CRC32 on the header and on the entry array.** Corruption is *detected*, not silently tolerated. This is the single biggest reliability difference from MBR.
- **A redundant copy at the end of the disk.** When you grow a virtual disk, the backup header is no longer at the end — see §10.3.
- `PARTUUID` and `PARTLABEL` exist **without a filesystem**, which is what lets you address a raw partition (LUKS container, PV, Ceph OSD) stably.

### 3.3 Trade-off table

| Dimension | MBR / DOS label | GPT |
|---|---|---|
| Max addressable disk (512 B sectors) | 2 TiB | 8 ZiB |
| Primary partitions | 4 (more via extended + EBR chain) | 128 default, resizable |
| Integrity protection | None — a bad byte is a lost table | CRC32 on header + entry array |
| Redundancy | None | Full backup header + array at end of disk |
| Partition identity | Disk signature + index (`PARTUUID=0x3f7a1c08-01`) — changes if reordered | Per-partition GUID, stable forever |
| Partition naming | None | 36 UTF-16 chars (`PARTLABEL`) |
| Type space | 1 byte, 255 values, colliding vendor claims | 128-bit GUID, no collisions |
| Firmware fit | BIOS/CSM native; UEFI requires CSM | UEFI native; BIOS boot needs a `ef02` BIOS boot partition for GRUB core.img |
| Discoverable Partitions Spec (auto-mount by type) | Not supported | Supported (`systemd-gpt-auto-generator`) |
| Tooling | `fdisk`, `parted`, `sfdisk` | `gdisk`/`sgdisk`, `parted`, `fdisk` (≥ util-linux 2.23), `sfdisk` |
| When to still choose it | Legacy BIOS appliance, VM template that must boot on a 2010 hypervisor, USB stick for old firmware | Everything else. Default for any new fleet. |

### 3.4 Partition type identifiers you must recognise

MBR is one byte; GPT is a GUID which `gdisk` abbreviates into a 4-hex-digit shorthand.

| Purpose | MBR id | gdisk code | GPT type GUID |
|---|---|---|---|
| Linux filesystem data | `83` | `8300` | `0FC63DAF-8483-4772-8E79-3D69D8477DE4` |
| Linux swap | `82` | `8200` | `0657FD6D-A4AB-43C4-84E5-0933C84B4F4F` |
| Linux LVM | `8e` | `8e00` | `E6D6D379-F507-44C2-A23C-238F2A3DF928` |
| Linux RAID | `fd` | `fd00` | `A19D880F-05FC-4D3B-A006-743F0F84911E` |
| EFI System Partition (ESP) | `ef` | `ef00` | `C12A7328-F81F-11D2-BA4B-00A0C93EC93B` |
| BIOS boot partition (GRUB core on GPT) | — | `ef02` | `21686148-6449-6E6F-744E-656564454649` |
| Linux `/boot` (XBOOTLDR) | — | `ea00` | `BC13C2FF-59E6-4262-A352-B275FD6F7172` |
| Linux root, x86-64 (auto-mountable) | — | `8304` | `4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709` |
| Linux `/home` | — | `8302` | `933AC7E1-2EB4-4F13-B844-0E14E2AEF915` |
| Extended (CHS / LBA) | `05` / `0f` | n/a | n/a |
| FAT32 (CHS / LBA) | `0b` / `0c` | `0700` | `EBD0A0A2-B9E5-4433-87C0-68B6B72699C7` |
| NTFS / exFAT | `07` | `0700` | same Microsoft basic data GUID |

**The type ID is metadata, not enforcement.** The kernel will happily mount ext4 from a partition marked `82`. But `swapon` by systemd-generated unit, LVM's `pvscan` filters, `mdadm` autodetection, UEFI firmware's search for the ESP, and `systemd-gpt-auto-generator` **all read the type** and will skip or mis-handle a wrongly typed partition. Set it correctly.

---

## 4. The tool set

| Tool | Table formats | Interface | Scriptable | Creates filesystems | Notes |
|---|---|---|---|---|---|
| `fdisk` | MBR, GPT, SGI, Sun, BSD | Interactive menu | Poorly (stdin hack) | No | The exam's reference tool. Since util-linux 2.23 it handles GPT fully. `-l` to list, `-x` for expert detail. |
| `sfdisk` | MBR, GPT | Non-interactive, dump/restore | **Yes — the right choice** | No | `sfdisk -d` produces a re-appliable text dump. Backup/restore of layouts. |
| `gdisk` | GPT (converts MBR→GPT) | Interactive, `fdisk`-like | No | No | Recovery menu (`r`) and expert menu (`x`) rebuild damaged GPTs. |
| `sgdisk` | GPT | Pure CLI | **Yes** | No | The automation tool for GPT. Binary GPT backup/restore. |
| `cgdisk` | GPT | ncurses | No | No | |
| `parted` | MBR, GPT, and ~a dozen others | Interactive **and** CLI | Yes (`-s`) | Historically yes — **do not use it for that** | `mkpart <fstype>` only sets the *type code*. Alignment engine (`-a optimal`). |
| `partprobe` / `partx` / `blockdev` | — | CLI | Yes | No | Force the kernel to re-read the table. |
| `systemd-repart` | GPT | Declarative `.conf` | **Yes — idempotent** | **Yes** (`Format=`) | Grow-on-first-boot images, factory reset. Modern replacement for imaging scripts. |
| `wipefs` | — | CLI | Yes | No | Removes filesystem/RAID/table *signatures*. The correct "start clean" command. |

### 4.1 `fdisk` — full MBR session

```
$ sudo fdisk /dev/sdb

Welcome to fdisk (util-linux 2.39.3).
Changes will remain in memory only, until you decide to write them.
Be careful before using the write command.

Device does not contain a recognized partition table.
Created a new DOS disklabel with disk identifier 0x3f7a1c08.

Command (m for help): n
Partition type
   p   primary (0 primary, 0 extended, 4 free)
   e   extended (container for logical partitions)
Select (default p): p
Partition number (1-4, default 1): 1
First sector (2048-104857599, default 2048): 
Last sector, +/-sectors or +/-size{K,M,G,T,P} (2048-104857599, default 104857599): +512M

Created a new partition 1 of type 'Linux' and of size 512 MiB.

Command (m for help): n
Partition type
   p   primary (1 primary, 0 extended, 3 free)
   e   extended (container for logical partitions)
Select (default p): p
Partition number (2-4, default 2): 2
First sector (1050624-104857599, default 1050624): 
Last sector, +/-sectors or +/-size{K,M,G,T,P} (1050624-104857599, default 104857599): +8G

Created a new partition 2 of type 'Linux' and of size 8 GiB.

Command (m for help): t
Partition number (1,2, default 2): 2
Hex code or alias (type L to list all): 82

Changed type of partition 'Linux' to 'Linux swap / Solaris'.

Command (m for help): n
Partition type
   p   primary (2 primary, 0 extended, 2 free)
   e   extended (container for logical partitions)
Select (default p): p
Partition number (3,4, default 3): 3
First sector (17827840-104857599, default 17827840): 
Last sector, +/-sectors or +/-size{K,M,G,T,P} (17827840-104857599, default 104857599): 

Created a new partition 3 of type 'Linux' and of size 41.5 GiB.

Command (m for help): t
Partition number (1-3, default 3): 3
Hex code or alias (type L to list all): 8e

Changed type of partition 'Linux' to 'Linux LVM'.

Command (m for help): p
Disk /dev/sdb: 50 GiB, 53687091200 bytes, 104857600 sectors
Disk model: QEMU HARDDISK   
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disklabel type: dos
Disk identifier: 0x3f7a1c08

Device     Boot    Start       End  Sectors  Size Id Type
/dev/sdb1            2048   1050623  1048576  512M 83 Linux
/dev/sdb2         1050624  17827839 16777216    8G 82 Linux swap / Solaris
/dev/sdb3        17827840 104857599 87029760 41.5G 8e Linux LVM

Command (m for help): w
The partition table has been altered.
Calling ioctl() to re-read partition table.
Syncing disks.
```

**Command keys to memorise:**

| Key | Action |
|---|---|
| `m` | Help |
| `p` | Print table |
| `n` | New partition |
| `d` | Delete partition |
| `t` | Change type ID |
| `l` | List known type IDs |
| `a` | Toggle bootable flag (MBR) |
| `v` | Verify table |
| `o` | Create a **new empty DOS/MBR** label |
| `g` | Create a **new empty GPT** label |
| `x` | Expert menu (sector-level edits) |
| `w` | **Write and exit** |
| `q` | **Quit, discarding everything** |

`q` is the undo button. Nothing touches the disk until `w`. That is the whole safety model of `fdisk`, and it is why the exam tests `w` versus `q`.

`fdisk` on an oversized disk:

```
$ sudo fdisk /dev/sdd
...
The size of this disk is 4 TiB (4398046511104 bytes). DOS partition table format
cannot be used on drives for volumes larger than 2199023255040 bytes for 512-byte
sectors. Use GUID partition table format (GPT).
```

### 4.2 `sfdisk` — backup, restore, and the only sane way to script MBR

```
$ sudo sfdisk -d /dev/sdb | sudo tee /root/backup/sdb.layout
label: dos
label-id: 0x3f7a1c08
device: /dev/sdb
unit: sectors
sector-size: 512

/dev/sdb1 : start=        2048, size=     1048576, type=83
/dev/sdb2 : start=     1050624, size=    16777216, type=82
/dev/sdb3 : start=    17827840, size=    87029760, type=8e
```

Restore, or clone the layout onto a sibling disk:

```
$ sudo sfdisk /dev/sdc < /root/backup/sdb.layout
Checking that no-one is using this disk right now ... OK

Disk /dev/sdc: 50 GiB, 53687091200 bytes, 104857600 sectors
...
The partition table has been altered.
Calling ioctl() to re-read partition table.
Syncing disks.
```

Create from scratch, non-interactively, in a provisioning script:

```bash
sudo sfdisk /dev/sdb <<'EOF'
label: dos
unit: sectors
,512M,83,*
,8G,82
,,8e
EOF
```

Empty `start` = "next aligned free sector"; empty `size` on the last line = "rest of the disk"; `*` = bootable flag. Verify a table without changing it:

```
$ sudo sfdisk -V /dev/sdb
/dev/sdb: 
OK
```

### 4.3 `gdisk` — interactive GPT

```
$ sudo gdisk /dev/nvme1n1
GPT fdisk (gdisk) version 1.0.9

Partition table scan:
  MBR: not present
  BSD: not present
  APM: not present
  GPT: not present

Creating new GPT entries in memory.

Command (? for help): o
This option deletes all partitions and creates a new protective MBR.
Proceed? (Y/N): Y

Command (? for help): n
Partition number (1-128, default 1): 1
First sector (34-2147483614, default = 2048) or {+-}size{KMGTP}: 
Last sector (2048-2147483614, default = 2147483614) or {+-}size{KMGTP}: +1G
Current type is 8300 (Linux filesystem)
Hex code or GUID (L to show codes, Enter = 8300): ef00
Changed type of partition to 'EFI system partition'

Command (? for help): n
Partition number (2-128, default 2): 2
First sector (2099200-2147483614, default = 2099200) or {+-}size{KMGTP}: 
Last sector (2099200-2147483614, default = 2147483614) or {+-}size{KMGTP}: +1M
Current type is 8300 (Linux filesystem)
Hex code or GUID (L to show codes, Enter = 8300): ef02
Changed type of partition to 'BIOS boot partition'

Command (? for help): n
Partition number (3-128, default 3): 3
First sector (2101248-2147483614, default = 2101248) or {+-}size{KMGTP}: 
Last sector (2101248-2147483614, default = 2147483614) or {+-}size{KMGTP}: 
Current type is 8300 (Linux filesystem)
Hex code or GUID (L to show codes, Enter = 8300): 8e00
Changed type of partition to 'Linux LVM'

Command (? for help): c
Partition number (1-3): 1
Enter name: ESP

Command (? for help): p
Disk /dev/nvme1n1: 2147483648 sectors, 1024.0 GiB
Model: Amazon Elastic Block Store              
Sector size (logical/physical): 512/512 bytes
Disk identifier (GUID): 5F2A0F7E-3C6B-4A2E-9D14-77C0B9F1A3E2
Partition table holds up to 128 entries
Main partition table begins at sector 2 and ends at sector 33
First usable sector is 34, last usable sector is 2147483614
Partitions will be aligned on 2048-sector boundaries
Total free space is 2014 sectors (1007.0 KiB)

Number  Start (sector)    End (sector)  Size       Code  Name
   1            2048         2099199   1024.0 MiB  EF00  ESP
   2         2099200         2101247   1024.0 KiB  EF02  BIOS boot partition
   3         2101248      2147483614   1023.0 GiB  8E00  Linux LVM

Command (? for help): w

Final checks complete. About to write GPT data. THIS WILL OVERWRITE EXISTING
PARTITIONS!!

Do you want to proceed? (Y/N): Y
OK; writing new GUID partition table (GPT) to /dev/nvme1n1.
The operation has completed successfully.
```

Extra menus that have no `fdisk` equivalent and matter during incidents:

| Key | Menu | Use |
|---|---|---|
| `v` | main | Verify GPT integrity, report problems |
| `i` | main | Show one partition's full detail incl. both GUIDs |
| `r` | **recovery/transformation** | Rebuild main GPT from backup (`b`), backup from main (`d`), convert MBR→GPT (`g`), convert GPT→MBR (`g` in reverse via `x`) |
| `x` | **expert** | Move backup GPT to end (`e`), randomise disk+partition GUIDs (`z`... `g`), change alignment (`l`), set attributes (`a`) |

### 4.4 `sgdisk` — GPT in one line

```
$ sudo sgdisk --zap-all /dev/nvme1n1
Creating new GPT entries in memory.
GPT data structures destroyed! You may now partition the disk using fdisk or
other utilities.

$ sudo sgdisk \
      -n 1:0:+1G   -t 1:ef00 -c 1:"ESP" \
      -n 2:0:+1M   -t 2:ef02 -c 2:"BIOSboot" \
      -n 3:0:0     -t 3:8e00 -c 3:"pv0" \
      /dev/nvme1n1
Setting name!
partNum is 0
Setting name!
partNum is 1
Setting name!
partNum is 2
The operation has completed successfully.
```

`-n <part>:<start>:<end>` where `0` means "default": next aligned free sector for start, last available sector for end. `+1G` is relative to start.

```
$ sudo sgdisk -p /dev/nvme1n1
Disk /dev/nvme1n1: 2147483648 sectors, 1024.0 GiB
Sector size (logical/physical): 512/512 bytes
Disk identifier (GUID): 5F2A0F7E-3C6B-4A2E-9D14-77C0B9F1A3E2
Partition table holds up to 128 entries
Main partition table begins at sector 2 and ends at sector 33
First usable sector is 34, last usable sector is 2147483614
Partitions will be aligned on 2048-sector boundaries
Total free space is 2014 sectors (1007.0 KiB)

Number  Start (sector)    End (sector)  Size       Code  Name
   1            2048         2099199   1024.0 MiB  EF00  ESP
   2         2099200         2101247   1024.0 KiB  EF02  BIOSboot
   3         2101248      2147483614   1023.0 GiB  8E00  pv0
```

Binary backup and restore of the GPT structures — 33 KiB, keep it in your config store:

```
$ sudo sgdisk --backup=/root/backup/nvme1n1.gpt /dev/nvme1n1
The operation has completed successfully.

$ sudo sgdisk --load-backup=/root/backup/nvme1n1.gpt /dev/nvme2n1
The operation has completed successfully.

$ sudo sgdisk -G /dev/nvme2n1        # randomise disk GUID and every partition GUID
The operation has completed successfully.
```

**`sgdisk -G` after a restore-to-a-different-disk or a VM clone is mandatory.** Skipping it produces two disks with identical `PARTUUID`s; `/dev/disk/by-partuuid/` then resolves non-deterministically and the initramfs may mount the wrong root.

### 4.5 `parted` — declarative, scriptable, and the alignment authority

```
$ sudo parted -s -a optimal /dev/sdc -- \
      mklabel gpt \
      mkpart ESP  fat32 1MiB 513MiB \
      set 1 esp on \
      mkpart data xfs   513MiB 100%

$ sudo parted /dev/sdc print
Model: ATA Samsung SSD 870 EVO (scsi)
Disk /dev/sdc: 2000GB
Sector size (logical/physical): 512B/512B
Partition Table: gpt
Disk Flags: 

Number  Start   End     Size    File system  Name  Flags
 1      1049kB  538MB   537MB                ESP   boot, esp
 2      538MB   2000GB  1999GB                data
```

Three things in that output are exam-grade traps:

1. **The `File system` column is empty.** `mkpart ... xfs ...` set the *partition type GUID*; it did **not** run `mkfs`. The column populates only after a real filesystem exists and `parted` probes its signature.
2. `--` before the commands stops `parted` from parsing `-1s`-style negative offsets as options. Always include it.
3. The default unit is decimal (kB/MB/GB) and rounds. For anything you must reason about, force the unit:

```
$ sudo parted /dev/sdc unit s print free
Model: ATA Samsung SSD 870 EVO (scsi)
Disk /dev/sdc: 3907029168s
Sector size (logical/physical): 512B/512B
Partition Table: gpt
Disk Flags: 

Number  Start       End          Size         File system  Name  Flags
        34s         2047s        2014s        Free Space
 1      2048s       1050623s     1048576s                  ESP   boot, esp
 2      1050624s    3907028991s  3905978368s                data
        3907028992s 3907029134s  143s         Free Space
```

Useful `parted` sub-commands: `mklabel {gpt,msdos}`, `mkpart`, `rm N`, `name N <label>`, `set N <flag> {on,off}`, `unit {s,B,MiB,GiB,%,compact}`, `print [free|all|devices]`, `align-check {minimal,optimal} N`, `resizepart N <end>`, `rescue <start> <end>`.

**GPT flags in `parted` are abstractions over type GUIDs:** `esp`/`boot` → `C12A7328-…`; `bios_grub` → `21686148-…`; `lvm` → `E6D6D379-…`; `raid` → `A19D880F-…`; `swap` → `0657FD6D-…`.

### 4.6 Making the kernel see the change

Writing the table updates the disk. The kernel's in-memory partition list is separate.

```
$ sudo partprobe /dev/sdb                 # whole-table re-read (parted package)
$ sudo partx -u /dev/sdb                  # update kernel view from the on-disk table
$ sudo partx -a --nr 3 /dev/sdb           # add only partition 3
$ sudo partx -d --nr 3 /dev/sdb           # remove only partition 3
$ sudo blockdev --rereadpt /dev/sdb       # raw BLKRRPART ioctl
$ sudo udevadm settle                     # wait for /dev/ symlinks to be created

$ dmesg | tail -2
[ 8123.442110]  sdb: sdb1 sdb2 sdb3
[ 8123.501773] sdb: detected capacity change from 0 to 104857600
```

The failure you will meet:

```
$ sudo partprobe /dev/sda
Error: Partition(s) 3 on /dev/sda have been written, but we have been unable to
inform the kernel of the change, probably because it/they are in use.  As a result,
the old partition(s) will remain in use.  You should reboot now before making
further changes.
```

**The whole-disk re-read fails if *any* partition on that disk is mounted or claimed.** `partx -a --nr N` for the single new partition usually succeeds where `partprobe` cannot, because it does not touch the busy ones. See §10.1 for finding the holder.

---

## 5. Choosing the filesystem

### 5.1 Comparative matrix

| | **ext2** | **ext3** | **ext4** | **XFS** | **Btrfs** | **VFAT (FAT32)** | **exFAT** |
|---|---|---|---|---|---|---|---|
| Journal | No | Yes (metadata + optional data) | Yes (metadata + optional data) | Yes, **metadata only** | No journal — CoW + checksums | No | No |
| Allocation | Block bitmaps | Block bitmaps | **Extents** | **Extents + B+trees** | Extents + CoW B-trees | FAT chain | Cluster bitmap |
| Inode allocation | Static, at `mkfs` | Static | Static | **Dynamic** | Dynamic | n/a | n/a |
| Max filesystem (4 KiB blocks) | 16 TiB | 16 TiB | **1 EiB** (`64bit`) | **8 EiB** | 16 EiB | ~2 TiB (512 B sectors) | 128 PiB |
| Max file | 2 TiB | 2 TiB | 16 TiB | 8 EiB | 16 EiB | **4 GiB − 1** | 16 EiB |
| Metadata checksums | No | No | Yes (`metadata_csum`) | Yes (CRC32c, v5) | Yes, **data + metadata** | No | No |
| Data checksums | No | No | No | No | **Yes** | No | No |
| Grow online | Yes | Yes | **Yes** | **Yes** (`xfs_growfs`) | Yes | No | No |
| Shrink | Offline | Offline | Offline (`resize2fs` after `e2fsck`) | **Never** | Yes, online | No | No |
| Snapshots | No | No | No (use LVM/dm) | No (use LVM/dm; has `reflink`) | **Native subvolume snapshots** | No | No |
| POSIX perms / ACL / xattr | Yes | Yes | Yes | Yes | Yes | **No** | **No** |
| Parallel-write scaling | Poor | Poor | Moderate | **Excellent** (allocation groups) | Moderate | n/a | n/a |
| Many-small-files metadata | Good | Good | **Good** | Fair (better with `finobt`) | Fair | Poor | Poor |
| Repair time on a large fs | Long | Long | Long (`e2fsck`) | **Fast** (`xfs_repair`, but RAM-hungry) | Varies | Fast | Fast |
| Status | Legacy | Legacy | **Production default** | **Production default** | Production for single-disk & RAID 0/1/10 | Interop only | Interop only |

**ReiserFS** — a journaling filesystem from the early 2000s, notable for tail packing (efficient storage of many small files) and B+tree metadata. It is in the LPI objectives at *awareness* level only. Operationally it is finished: marked **deprecated in Linux 5.18** and **removed from the mainline kernel in 6.13**. There is no reason to create one; if you inherit one, plan a migration, and confirm what your running kernel actually supports:

```
$ grep -E 'reiser|btrfs|xfs|ext4' /proc/filesystems
	ext3
	ext4
	xfs
	btrfs
```

**Btrfs** — also awareness level for LPIC-1, but you will meet it: it is the default on Fedora Workstation and openSUSE, and it underlies `snapper` rollback workflows. Copy-on-write, native subvolumes and snapshots, integral checksumming of data as well as metadata, built-in multi-device profiles, transparent compression, and `send`/`receive` for incremental replication. RAID 5/6 profiles still carry a write hole and are **not** production-ready. CoW causes fragmentation under random-overwrite workloads (databases, VM images) — those directories need `chattr +C`.

### 5.2 ext3/ext4 journaling modes

| Mode | Mount option | What is journaled | Crash guarantee | Cost |
|---|---|---|---|---|
| **Ordered** (default) | `data=ordered` | Metadata only; data blocks are forced to disk *before* the metadata commit | No stale-block exposure; a file may lose recent content but never shows another file's old data | Baseline |
| **Journal** | `data=journal` | **Metadata and data**, both written twice | Strongest; survives a crash mid-write with consistent data | Up to 2× write amplification; disables `O_DIRECT` and delayed allocation |
| **Writeback** | `data=writeback` | Metadata only; data written whenever | Metadata is consistent but a file can expose **stale blocks** — potentially another user's deleted data | Fastest; a security consideration on multi-tenant hosts |

XFS journals metadata only, always. There is no XFS equivalent of `data=journal`.

### 5.3 The decision, by workload

| Workload | Choice | Reasoning |
|---|---|---|
| Root filesystem, general server | **XFS** (RHEL family default) or **ext4** (Debian family default) | Both correct. Follow the distribution — the tested, packaged, supported path. |
| `/var/lib/containers`, `/var/lib/docker` (overlayfs) | **XFS with `ftype=1`** or ext4 | overlay2 **requires** d_type support. `ftype=0` XFS breaks the container runtime at start-up. |
| Large sequential I/O, many parallel writers (object store, media, backup target) | **XFS** | Allocation groups give per-AG locking; scales with CPU count. |
| Millions of small files, heavy `unlink` (mail spool, cache) | **ext4**, or XFS with `finobt` | ext4's static inode tables and h-tree dirs are predictable here. |
| etcd / low-latency WAL | **ext4** or **XFS**, `noatime`, and never Btrfs | CoW adds unpredictable write latency to fsync-heavy WAL workloads. |
| Desktop / node needing snapshot-rollback | **Btrfs** | Native subvolumes + `snapper`. |
| EFI System Partition | **VFAT (FAT32)** | Mandated by the UEFI specification. No alternative. |
| Removable media > 4 GiB files, shared with Windows/macOS | **exFAT** | FAT32's 4 GiB file ceiling is the constraint. |
| Removable media, universal firmware/embedded compatibility | **VFAT (FAT32)** | Every firmware and device reads it. |
| Swap | `mkswap` | Not a filesystem. |

---

## 6. Creating filesystems

### 6.1 `mkfs` is a dispatcher

```
$ ls /sbin/mkfs*
/sbin/mkfs  /sbin/mkfs.bfs  /sbin/mkfs.btrfs  /sbin/mkfs.cramfs  /sbin/mkfs.exfat
/sbin/mkfs.ext2  /sbin/mkfs.ext3  /sbin/mkfs.ext4  /sbin/mkfs.fat  /sbin/mkfs.minix
/sbin/mkfs.msdos  /sbin/mkfs.vfat  /sbin/mkfs.xfs
```

`mkfs -t xfs /dev/sdb1` simply `exec`s `mkfs.xfs /dev/sdb1`. `mkfs.ext2`, `mkfs.ext3`, `mkfs.ext4` are all symlinks to `mke2fs`, which reads the invoked name to pick defaults from `/etc/mke2fs.conf`. `mkfs.vfat`, `mkfs.msdos` and `mkdosfs` are the same `mkfs.fat` binary.

Equivalent forms — recognise all of them:

```
$ sudo mkfs -t ext4 /dev/sdb1
$ sudo mkfs.ext4 /dev/sdb1
$ sudo mke2fs -t ext4 /dev/sdb1
```

### 6.2 Always start from a known-clean device

```
$ sudo wipefs /dev/sdb1
DEVICE OFFSET TYPE UUID                                 LABEL
sdb1   0x438  ext4 6ae1f2b9-5d33-4a0e-9d02-5b7e7f4b6f21 data

$ sudo wipefs -a /dev/sdb1
/dev/sdb1: 2 bytes were erased at offset 0x00000438 (ext4): 53 ef
```

Offset `0x438` = 1080 decimal, the location of the ext superblock magic `0xEF53`. Stale signatures are not cosmetic — `blkid`, `udev`, LVM and the initramfs all probe by signature, and a leftover LVM or `mdraid` header will make `mkfs` fail with `Device or resource busy` after `udev` auto-assembles the old array.

Without `wipefs`, `mkfs` protests:

```
$ sudo mkfs.xfs /dev/sdb1
mkfs.xfs: /dev/sdb1 appears to contain an existing filesystem (ext4).
mkfs.xfs: Use the -f option to force overwrite.

$ sudo mkfs.ext4 /dev/sdb1
mke2fs 1.47.0 (5-Feb-2023)
/dev/sdb1 contains a xfs file system
Proceed anyway? (y,N) 
```

### 6.3 ext4 — production invocation, fully explained

```
$ sudo mkfs.ext4 \
      -L data \
      -b 4096 \
      -i 32768 \
      -m 1 \
      -J size=256 \
      -E lazy_itable_init=0,lazy_journal_init=0,nodiscard \
      -O ^orphan_file \
      /dev/nvme1n1p3
mke2fs 1.47.0 (5-Feb-2023)
Creating filesystem with 26214400 4k blocks and 3276800 inodes
Filesystem UUID: 3f0b0c86-7f2d-4a24-9d7c-8a3c8b4a1f55
Superblock backups stored on blocks: 
	32768, 98304, 163840, 229376, 294912, 819200, 884736, 1605632, 2654208, 
	4096000, 7962624, 11239424, 20480000, 23887872

Allocating group tables: done                            
Writing inode tables: done                            
Creating journal (65536 blocks): done
Writing superblocks and filesystem accounting information: done
```

| Flag | Meaning | Why it is set here |
|---|---|---|
| `-L data` | Volume label (≤ 16 chars) | Lets `fstab` use `LABEL=data`; survives re-imaging |
| `-b 4096` | Block size | Pinned explicitly. Auto-selection gives 1024 on small volumes, which caps the filesystem at 16 GiB with `resize_inode` |
| `-i 32768` | **Bytes per inode** | One inode per 32 KiB → 3 276 800 inodes on 100 GiB. Default 16384 doubles that. Halving inode count reclaims ~800 MiB and speeds `e2fsck` |
| `-m 1` | Reserved blocks for root, percent | Default 5 % = 5 GiB wasted on a 100 GiB data volume. Keep **5 % on `/` and `/var`** (it is what lets root log in and rotate logs when the disk fills); drop to 0–1 % on pure data volumes |
| `-J size=256` | Journal size, MiB | Pinned for predictability; the default scales with volume size and varies across `e2fsprogs` releases |
| `-E lazy_itable_init=0` | Write inode tables now | Default `1` defers zeroing to a kernel thread after first mount — invisible background I/O that ruins the first benchmark and the first hour of production |
| `-E nodiscard` | Do not issue TRIM | On a thin-provisioned SAN LUN or a large SSD, the discard pass can add many minutes to `mkfs`. Skip it if the volume is already thin/fresh |
| `-O ^orphan_file` | Disable a feature | `e2fsprogs` 1.47 enables `orphan_file` by default; kernels older than 5.15 refuse to mount. Required when the build host is newer than the fleet |

Other options worth knowing:

| Flag | Effect |
|---|---|
| `-N <n>` | Absolute inode count (instead of the `-i` ratio) |
| `-U <uuid\|random\|clear>` | Set the filesystem UUID at creation |
| `-T <type>` | Use a usage profile from `/etc/mke2fs.conf`: `small`, `floppy`, `big`, `huge`, `largefile` (1 inode/MiB), `largefile4` (1 inode/4 MiB), `news` |
| `-c` / `-cc` | Bad-block scan via `badblocks`, read-only / read-write. Very slow; only for suspect media |
| `-n` | **Dry run** — prints what would be done and, crucially, where the backup superblocks are |
| `-E stride=,stripe_width=` | RAID geometry in filesystem blocks (§6.5) |
| `-F` | Force (whole device, mounted device, size mismatch) |

The dry run is your recovery map — capture it at build time:

```
$ sudo mkfs.ext4 -n /dev/nvme1n1p3
mke2fs 1.47.0 (5-Feb-2023)
Creating filesystem with 26214400 4k blocks and 3276800 inodes
Filesystem UUID: 00000000-0000-0000-0000-000000000000
Superblock backups stored on blocks: 
	32768, 98304, 163840, 229376, 294912, 819200, 884736, 1605632, 2654208, 
	4096000, 7962624, 11239424, 20480000, 23887872
```

With a destroyed primary superblock: `e2fsck -b 32768 -B 4096 /dev/nvme1n1p3`.

Verification:

```
$ sudo dumpe2fs -h /dev/nvme1n1p3
dumpe2fs 1.47.0 (5-Feb-2023)
Filesystem volume name:   data
Last mounted on:          <not available>
Filesystem UUID:          3f0b0c86-7f2d-4a24-9d7c-8a3c8b4a1f55
Filesystem magic number:  0xEF53
Filesystem revision #:    1 (dynamic)
Filesystem features:      has_journal ext_attr resize_inode dir_index filetype
                          extent 64bit flex_bg metadata_csum metadata_csum_seed
                          sparse_super large_file huge_file dir_nlink extra_isize
Default mount options:    user_xattr acl
Filesystem state:         clean
Errors behavior:          Continue
Filesystem OS type:       Linux
Inode count:              3276800
Block count:              26214400
Reserved block count:     262144
Free blocks:              25682089
Free inodes:              3276789
First block:              0
Block size:               4096
Fragment size:            4096
Group descriptor size:    64
Reserved GDT blocks:      1024
Blocks per group:         32768
Fragments per group:      32768
Inodes per group:         4096
Inode blocks per group:   256
Flex block group size:    16
Filesystem created:       Wed Aug 26 09:14:02 2026
Mount count:              0
Maximum mount count:      -1
Check interval:           0 (<none>)
Lifetime writes:          412 MB
Reserved blocks uid:      0 (user root)
Reserved blocks gid:      0 (group root)
First inode:              11
Inode size:               256
Journal inode:            8
Default directory hash:   half_md4
Journal backup:           inode blocks
Checksum type:            crc32c
Journal features:         (none)
Total journal size:       256M
```

Every number is checkable: 26 214 400 blocks ÷ 32 768 per group = 800 groups; 3 276 800 inodes ÷ 800 = 4 096 per group; `-m 1` × 26 214 400 = 262 144 reserved blocks. If these do not match your intent, you find out now — not after the data is on it.

### 6.4 XFS

```
$ sudo mkfs.xfs -f -L srv -i size=512 -m reflink=1,crc=1 -l size=512m /dev/nvme1n1p4
meta-data=/dev/nvme1n1p4         isize=512    agcount=4, agsize=6553600 blks
         =                       sectsz=512   attr=2, projid32bit=1
         =                       crc=1        finobt=1, sparse=1, rmapbt=0
         =                       reflink=1    bigtime=1 inobtcount=1 nrext64=1
data     =                       bsize=4096   blocks=26214400, imaxpct=25
         =                       sunit=0      swidth=0 blks
naming   =version 2              bsize=4096   ascii-ci=0, ftype=1
log      =internal log           bsize=4096   blocks=131072, version=2
         =                       sectsz=512   sunit=0 blks, lazy-count=1
realtime =none                   extsz=4096   blocks=0, rtextents=0
Discarding blocks...Done.
```

Reading that output is a core SRE skill:

| Line | Field | Meaning |
|---|---|---|
| `meta-data` | `agcount=4, agsize=6553600` | Four **allocation groups**, each 25 GiB. AGs are the unit of parallelism — each has its own free-space B+trees and its own lock. More AGs = more concurrent allocation, more metadata overhead. Do not force `agcount` above ~32 without a measured reason |
| | `isize=512` | Inode size. 512 lets more extended attributes (SELinux labels, ACLs) live inline instead of in a separate block |
| | `crc=1` | v5 superblock, CRC32c on all metadata. Non-negotiable |
| | `reflink=1` | Copy-on-write shared extents — `cp --reflink`, container image layers, cheap snapshots of files |
| | `nrext64=1` | 64-bit extent counters (`xfsprogs` ≥ 6.0). **Kernels < 5.19 cannot mount this.** Disable with `-i nrext64=0` when the target fleet is older |
| `data` | `bsize=4096, blocks=26214400` | 100 GiB. `bsize` cannot exceed the page size (4 KiB on x86-64) |
| | `imaxpct=25` | Maximum share of space that inodes may consume. XFS allocates inodes dynamically, so this is a ceiling, not a reservation |
| | `sunit=0 swidth=0` | No stripe geometry detected — correct for a plain partition, **wrong on a RAID LUN** |
| `naming` | `ftype=1` | d_type in directory entries. **overlayfs / container runtimes require this.** Default since `xfsprogs` 3.2.3; a filesystem created before that with `ftype=0` cannot be fixed in place |
| `log` | `internal log, blocks=131072` | 512 MiB journal inside the data section. `-l logdev=/dev/nvmeXn1` puts it on a separate fast device for metadata-heavy workloads |

Re-read the same information at any time:

```
$ sudo xfs_info /srv
meta-data=/dev/nvme1n1p4         isize=512    agcount=4, agsize=6553600 blks
...
```

`xfs_info` requires the filesystem to be mounted (or takes the device with recent `xfsprogs`). There is no XFS equivalent of `tune2fs` for most parameters — **XFS geometry is fixed at `mkfs` time and can never be changed.** That includes block size, sector size, `ftype`, `crc`, `reflink`, log size and location, and the inability to shrink. This is precisely why the `mkfs.xfs` command line deserves review before it runs.

### 6.5 Stripe-aware creation on RAID and SAN

The single most valuable production application of this objective. Given `mdadm` RAID 5 with a 64 KiB chunk over 5 devices (4 data + 1 parity):

```
$ cat /proc/mdstat
Personalities : [raid6] [raid5] [raid4] 
md0 : active raid5 sde[4] sdd[3] sdc[2] sdb[1] sda[0]
      7813771264 blocks super 1.2 level 5, 64k chunk, algorithm 2 [5/5] [UUUUU]
```

- **stripe unit (su)** = chunk = 64 KiB
- **stripe width (sw)** = number of *data* members = 4

XFS takes them directly:

```
$ sudo mkfs.xfs -f -L bulk -d su=64k,sw=4 -l size=512m /dev/md0
meta-data=/dev/md0               isize=512    agcount=32, agsize=61045248 blks
         =                       sectsz=4096  attr=2, projid32bit=1
         =                       crc=1        finobt=1, sparse=1, rmapbt=0
         =                       reflink=1    bigtime=1 inobtcount=1 nrext64=1
data     =                       bsize=4096   blocks=1953442816, imaxpct=5
         =                       sunit=16     swidth=64 blks
naming   =version 2              bsize=4096   ascii-ci=0, ftype=1
log      =internal log           bsize=4096   blocks=131072, version=2
         =                       sectsz=4096  sunit=1 blks, lazy-count=1
realtime =none                   extsz=4096   blocks=0, rtextents=0
```

`sunit=16 swidth=64 blks` — 64 KiB ÷ 4 KiB = 16 blocks, × 4 members = 64 blocks. Confirmed.

ext4 uses the same concept with different names, expressed in **filesystem blocks**:

```
$ sudo mkfs.ext4 -b 4096 -E stride=16,stripe_width=64 -L bulk /dev/md0
```

`stride = chunk / block_size`; `stripe_width = stride × data_disks`.

`mkfs` reads `optimal_io_size` from sysfs and usually derives these automatically for `md` devices. It generally **cannot** for hardware RAID controllers or SAN LUNs, which report `optimal_io_size=0`. On those, you must obtain the geometry from the array's management tool and pass it by hand. Getting it wrong means every parity update becomes a read-modify-write, and you will see it as write amplification with no error anywhere.

### 6.6 VFAT

```
$ sudo mkfs.vfat -F 32 -n ESP -v /dev/nvme1n1p1
mkfs.fat 4.2 (2021-01-31)
/dev/nvme1n1p1 has 255 heads and 63 sectors per track,
hidden sectors 0x0800;
logical sector size is 512,
using 0xf8 media descriptor, with 2097152 sectors;
drive number 0x80;
filesystem has 2 32-bit FATs and 8 sectors per cluster.
FAT size is 2048 sectors, and provides 261628 clusters.
There are 32 reserved sectors.
Volume ID is 3a7c1f22, volume label ESP        .
```

| Flag | Meaning |
|---|---|
| `-F {12,16,32}` | FAT width. **Always specify.** Auto-selection picks FAT16 on small volumes, and UEFI firmware on fixed disks expects FAT32 |
| `-n <label>` | Volume label — **11 characters, upper-case**. `blkid` reports it as `LABEL` |
| `-s <n>` | Sectors per cluster |
| `-S <n>` | Logical sector size |
| `-v` | Verbose |
| `-c` | Bad-block check |
| `-i <id>` | Set the 32-bit volume ID (`blkid` shows it as the `UUID`, formatted `3A7C-1F22`) |

FAT has no ownership or permission model. Access control comes from mount options only:

```
UUID=3A7C-1F22  /boot/efi  vfat  umask=0077,shortname=winnt,utf8,fmask=0177,dmask=0077  0 2
```

`umask=0077` is what keeps a world-readable ESP — containing your boot loader configuration and signed binaries — from being readable by every user.

Verification (`fsck.fat` is the only tool; there is no `dumpe2fs` equivalent):

```
$ sudo fsck.fat -v -n /dev/nvme1n1p1
fsck.fat 4.2 (2021-01-31)
Checking we can access the last sector of the filesystem
Boot sector contents:
System ID "mkfs.fat"
Media byte 0xf8 (hard disk)
       512 bytes per logical sector
      4096 bytes per cluster
        32 reserved sectors
First FAT starts at byte 16384 (sector 32)
         2 FATs, 32 bit entries
   1048576 bytes per FAT (= 2048 sectors)
Root directory start at cluster 2 (arbitrary size)
Data area starts at byte 2113536 (sector 4128)
    261628 data clusters (1071628288 bytes)
63 sectors/track, 255 heads
      2048 hidden sectors
   2097152 sectors total
Checking for unused clusters.
/dev/nvme1n1p1: 0 files, 0/261628 clusters
```

### 6.7 exFAT

The Linux `fs/exfat` driver landed in kernel 5.7 (a staging version in 5.4); user-space tooling is `exfatprogs`.

```
$ sudo mkfs.exfat -L FIELDKIT -c 128K /dev/sdd1
exfatprogs version : 1.2.2
Creating exFAT filesystem(/dev/sdd1, cluster size=131072)

Writing volume boot record: done
Writing backup volume boot record: done
Fat table creation: done
Allocation bitmap creation: done
Upcase table creation: done
Writing root directory entry: done
Synchronizing...

exFAT format complete!
```

| Flag | Meaning |
|---|---|
| `-L <label>` | Volume label (up to 15 UTF-16 chars — unlike FAT, mixed case is fine) |
| `-c <size>` | Cluster size. Large values (128 K–1 M) suit large sequential files on flash; small values waste less on small files |
| `-b <size>` | Boundary alignment, to match the flash erase-block size |
| `-f` | Force |

Choose exFAT over VFAT when a single file exceeds 4 GiB — camera footage, disk images, backup archives — and cross-OS compatibility is required. Choose VFAT when compatibility with old firmware matters more. **Neither is ever the right choice for a Linux server filesystem**: no journal, no permissions, no xattr, no ACL, and no crash resilience.

### 6.8 Btrfs (awareness level)

```
$ sudo mkfs.btrfs -L pool0 -d raid1 -m raid1 /dev/sdb /dev/sdc
btrfs-progs v6.6.3
See https://btrfs.readthedocs.io for more information.

NOTE: several default settings have changed in version 5.15, please make sure
      this does not affect your deployments:
      - DUP for metadata (-m dup)
      - enabled no-holes (-O no-holes)
      - enabled free-space-tree (-R free-space-tree)

Label:              pool0
UUID:               f4b2a1c9-6d5e-4b3a-9f7c-2a8e1d0b3c47
Node size:          16384
Sector size:        4096
Filesystem size:    7.28TiB
Block group profiles:
  Data:             RAID1           1.00GiB
  Metadata:         RAID1           1.00GiB
  System:           RAID1           8.00MiB
SSD detected:       no
Zoned device:       no
Checksum:           crc32c
Number of devices:  2
Devices:
   ID        SIZE  PATH
    1     3.64TiB  /dev/sdb
    2     3.64TiB  /dev/sdc
```

Note that `mkfs.btrfs` accepts **multiple devices** — Btrfs subsumes the volume-manager layer, which is the architectural difference from ext4/XFS (where LVM or `md` sits below).

---

## 7. Swap

Swap space is not a filesystem. `mkswap` writes a one-page header and nothing else.

### 7.1 Swap partition

```
$ sudo mkswap -L swap0 /dev/nvme1n1p2
Setting up swapspace version 1, size = 8 GiB (8589930496 bytes)
LABEL=swap0, UUID=1f4a2b6d-9c3e-4e08-b4a1-2f7a0d6c5e13

$ sudo swapon --priority 10 /dev/nvme1n1p2

$ swapon --show
NAME               TYPE      SIZE USED PRIO
/dev/nvme1n1p2 partition       8G   0B   10

$ free -h
               total        used        free      shared  buff/cache   available
Mem:            31Gi       2.1Gi        27Gi       9.0Mi       2.3Gi        28Gi
Swap:          8.0Gi          0B       8.0Gi
```

`8589930496` = 8 GiB minus exactly 4096 bytes: the swap header occupies one page.

| Option | Meaning |
|---|---|
| `-L <label>` | Label, for `LABEL=` in `fstab` |
| `-U <uuid>` | Explicit UUID |
| `-c` | Check for bad blocks first |
| `-p <size>` | Page size — only relevant when preparing swap for a foreign architecture |
| `-f` | Force (e.g. size larger than the device, whole-disk) |

**Priority matters in a mixed-media host.** Equal priorities round-robin (striping across devices); higher priority is consumed first. Put NVMe swap at `pri=10` and spinning-disk swap at `pri=1` and the kernel drains the fast device first.

### 7.2 Swap file

```
$ sudo dd if=/dev/zero of=/swapfile bs=1M count=8192 status=progress
8589934592 bytes (8.6 GB, 8.0 GiB) copied, 12 s, 716 MB/s
8192+0 records in
8192+0 records out
8589934592 bytes (8.6 GB, 8.0 GiB) copied, 12.0114 s, 715 MB/s

$ sudo chmod 600 /swapfile
$ sudo mkswap /swapfile
Setting up swapspace version 1, size = 8 GiB (8589930496 bytes)
no label, UUID=b2c7e4a1-8f39-4d5c-a0e2-1c6b9f3d7a84

$ sudo swapon /swapfile
```

Three filesystem-specific traps:

- **XFS:** `fallocate` produces *unwritten* extents, which `swapon` rejects. Use `dd`. Symptom: `swapon: /swapfile: swapon failed: Invalid argument`.
- **Btrfs:** requires kernel ≥ 5.0, the file must be NOCOW (`chattr +C` on an *empty* file, or created in a NOCOW directory), uncompressed, and not on a multi-device profile.
- **Permissions:** anything other than `0600` leaks memory contents to any user who can read the file.

```
$ sudo swapon /swapfile
swapon: /swapfile: insecure permissions 0644, 0600 suggested.
```

### 7.3 Making it persist

```
# /etc/fstab
UUID=1f4a2b6d-9c3e-4e08-b4a1-2f7a0d6c5e13  none  swap  sw,pri=10  0 0
/swapfile                                  none  swap  sw,pri=1   0 0
```

```
$ sudo swapoff -a          # deactivate everything
$ sudo swapon -a           # activate everything from fstab
$ sudo swapon --verbose --show=NAME,TYPE,SIZE,USED,PRIO
NAME               TYPE      SIZE USED PRIO
/dev/nvme1n1p2 partition       8G   0B   10
/swapfile           file       8G   0B    1
```

---

## 8. Infrastructure as code

The interactive sessions above teach the mechanics. In a fleet, none of them should be typed by a human. The following four manifests express the same layout declaratively and idempotently.

### 8.1 cloud-init — first-boot disk preparation

```yaml
#cloud-config
# /var/lib/cloud/seed/nocloud/user-data
# Partitions and formats the secondary data volume on first boot only.
# Idempotent: `overwrite: false` makes every stage a no-op if the
# structure already exists, so a re-run after a rescue boot is safe.

device_aliases:
  datavol: /dev/nvme1n1

disk_setup:
  datavol:
    table_type: gpt
    # Percentages of total capacity; the optional second element is the
    # MBR-style type id, translated to the matching GPT type GUID.
    layout:
      - [10, 82]     # 10% -> Linux swap        (0657FD6D-A4AB-43C4-84E5-0933C84B4F4F)
      - [90, 83]     # 90% -> Linux filesystem  (0FC63DAF-8483-4772-8E79-3D69D8477DE4)
    overwrite: false

fs_setup:
  - label: swap0
    filesystem: swap
    device: datavol.1
    overwrite: false

  - label: srv
    filesystem: xfs
    device: datavol.2
    # Passed verbatim to mkfs.xfs. nrext64=0 keeps the volume mountable
    # by the 5.14 kernels still present in the older node pool.
    extra_opts:
      - "-L"
      - "srv"
      - "-i"
      - "size=512,nrext64=0"
      - "-m"
      - "crc=1,reflink=1"
      - "-l"
      - "size=512m"
    overwrite: false

mounts:
  - ["LABEL=srv",   "/srv", "xfs",  "defaults,noatime,inode64,nofail,x-systemd.device-timeout=30s", "0", "2"]
  - ["LABEL=swap0", "none", "swap", "sw,pri=10", "0", "0"]

mount_default_fields: [None, None, "auto", "defaults,nofail", "0", "2"]

runcmd:
  # Fail the boot loudly rather than starting a node with no data volume.
  - ["systemctl", "--no-pager", "--failed"]
  - ["findmnt", "--verify", "--verbose"]
```

### 8.2 Butane / Ignition — immutable OS provisioning (Fedora CoreOS, RHCOS, Flatcar)

```yaml
variant: fcos
version: 1.5.0

storage:
  disks:
    - device: /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol0a1b2c3d4e5f6
      # Ignition refuses to touch a disk whose layout already matches,
      # which is what makes re-running the config safe.
      wipe_table: false
      partitions:
        - label: containers
          number: 1
          size_mib: 262144          # 256 GiB
          start_mib: 0              # first aligned free sector
          type_guid: 0FC63DAF-8483-4772-8E79-3D69D8477DE4
          wipe_partition_entry: false

        - label: etcd
          number: 2
          size_mib: 32768           # 32 GiB
          start_mib: 0
          type_guid: 0FC63DAF-8483-4772-8E79-3D69D8477DE4
          wipe_partition_entry: false

  filesystems:
    - device: /dev/disk/by-partlabel/containers
      format: xfs
      label: containers
      wipe_filesystem: false
      # `options` are mkfs options. ftype=1 is implicit in modern xfsprogs
      # but overlayfs hard-depends on it, so it is asserted explicitly.
      options:
        - "-L"
        - "containers"
        - "-n"
        - "ftype=1"
        - "-i"
        - "size=512"
        - "-m"
        - "reflink=1"
      with_mount_unit: true
      path: /var/lib/containers
      mount_options:
        - noatime
        - inode64
        - prjquota

    - device: /dev/disk/by-partlabel/etcd
      format: ext4
      label: etcd
      wipe_filesystem: false
      options:
        - "-L"
        - "etcd"
        - "-m"
        - "0"
        - "-E"
        - "lazy_itable_init=0,lazy_journal_init=0"
      with_mount_unit: true
      path: /var/lib/etcd
      mount_options:
        - noatime
        - data=ordered

systemd:
  units:
    - name: var-lib-containers.mount
      enabled: true
    - name: var-lib-etcd.mount
      enabled: true

    - name: verify-storage.service
      enabled: true
      contents: |
        [Unit]
        Description=Assert storage layout before the kubelet starts
        After=var-lib-containers.mount var-lib-etcd.mount
        Requires=var-lib-containers.mount var-lib-etcd.mount
        Before=kubelet.service

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/bin/bash -c 'xfs_info /var/lib/containers | grep -q "ftype=1"'
        ExecStart=/usr/bin/findmnt --verify --verbose
        ExecStart=/usr/bin/findmnt -no FSTYPE /var/lib/etcd

        [Install]
        WantedBy=multi-user.target
```

Compile and apply:

```
$ butane --pretty --strict node.bu --output node.ign
$ ignition-validate node.ign
```

### 8.3 systemd-repart — declarative, growable GPT

`systemd-repart` reconciles a disk against a set of `.conf` files at every boot: it creates what is missing, grows what is undersized, and does nothing when the disk already matches. This is how a single golden image adapts to 100 GiB and 4 TiB nodes without any imaging logic.

```ini
# /etc/repart.d/10-esp.conf
[Partition]
Type=esp
Label=ESP
Format=vfat
SizeMinBytes=512M
SizeMaxBytes=512M
```

```ini
# /etc/repart.d/50-root.conf
[Partition]
Type=root
Label=root
Format=xfs
SizeMinBytes=16G
SizeMaxBytes=64G
FactoryReset=no
```

```ini
# /etc/repart.d/70-var.conf
[Partition]
Type=var
Label=var
Format=xfs
# Take all remaining space; weight decides the split when several
# partitions compete for the free area.
Weight=1000
SizeMinBytes=8G
Encrypt=off
```

```ini
# /etc/repart.d/80-swap.conf
[Partition]
Type=swap
Label=swap0
Format=swap
SizeMinBytes=4G
SizeMaxBytes=8G
```

```
$ sudo systemd-repart --dry-run=yes --empty=allow /dev/nvme0n1
Determined sector size 512 by probing /dev/nvme0n1.

  ✓ Partition  Type   Label  UUID       File           Node          Old Size  New Size
  + (new)      esp    ESP    …a1b2c3d4  10-esp.conf    /dev/nvme0n1p1        -    512.0M
  + (new)      root   root   …e5f60718  50-root.conf   /dev/nvme0n1p2        -     64.0G
  + (new)      swap   swap0  …293a4b5c  80-swap.conf   /dev/nvme0n1p4        -      8.0G
  + (new)      var    var    …6d7e8f90  70-var.conf    /dev/nvme0n1p3        -    855.5G

$ sudo systemd-repart --dry-run=no /dev/nvme0n1
```

Because `Type=root`/`var`/`esp` map to the Discoverable Partitions Specification GUIDs, `systemd-gpt-auto-generator` mounts them **without any `/etc/fstab` entry at all** — closing the "fstab typo bricks the boot" failure class entirely.

### 8.4 Ansible — fleet convergence

```yaml
---
- name: Provision the data volume on storage nodes
  hosts: storage_nodes
  become: true
  gather_facts: true

  vars:
    data_disk: /dev/nvme1n1
    data_part: /dev/nvme1n1p1
    data_mount: /var/lib/data
    # Oldest kernel in the fleet; drives mkfs feature selection.
    min_kernel: "5.14"

  tasks:
    - name: Refuse to run against a disk that already holds a mounted filesystem
      ansible.builtin.command:
        cmd: "lsblk -no MOUNTPOINT {{ data_disk }}"
      register: disk_mounts
      changed_when: false

    - name: Abort if anything on the target disk is mounted
      ansible.builtin.assert:
        that:
          - disk_mounts.stdout | trim | length == 0
        fail_msg: >-
          {{ data_disk }} has mounted partitions; refusing to repartition.
          Mounted at: {{ disk_mounts.stdout | trim }}

    - name: Create the GPT label and a single optimally aligned data partition
      community.general.parted:
        device: "{{ data_disk }}"
        label: gpt
        number: 1
        name: data
        part_start: 1MiB
        part_end: "100%"
        align: optimal
        state: present
      register: part_result

    - name: Wait for udev to publish the partition node
      ansible.builtin.command:
        cmd: udevadm settle --timeout=30
      changed_when: false
      when: part_result is changed

    - name: Assert optimal alignment before committing a filesystem to it
      ansible.builtin.command:
        cmd: "parted -s {{ data_disk }} align-check optimal 1"
      register: align
      changed_when: false
      failed_when: "'aligned' not in align.stdout or 'not aligned' in align.stdout"

    - name: Create the XFS filesystem
      community.general.filesystem:
        dev: "{{ data_part }}"
        fstype: xfs
        # nrext64=0 keeps the volume mountable by the oldest fleet kernel.
        opts: >-
          -L data
          -i size=512,nrext64=0
          -m crc=1,reflink=1
          -n ftype=1
          -l size=512m
        state: present
      register: mkfs_result

    - name: Read back the filesystem UUID
      ansible.builtin.command:
        cmd: "blkid -s UUID -o value {{ data_part }}"
      register: fs_uuid
      changed_when: false

    - name: Mount by UUID and persist in /etc/fstab
      ansible.posix.mount:
        path: "{{ data_mount }}"
        src: "UUID={{ fs_uuid.stdout | trim }}"
        fstype: xfs
        opts: noatime,inode64,prjquota,nofail,x-systemd.device-timeout=30s
        dump: "0"
        passno: "0"        # XFS has no boot-time fsck; passno must be 0
        state: mounted

    - name: Verify that /etc/fstab is internally consistent
      ansible.builtin.command:
        cmd: findmnt --verify --verbose
      register: fstab_check
      changed_when: false
      failed_when: fstab_check.rc != 0

    - name: Confirm ftype=1 — overlayfs will not start without it
      ansible.builtin.command:
        cmd: "xfs_info {{ data_mount }}"
      register: xfsinfo
      changed_when: false
      failed_when: "'ftype=1' not in xfsinfo.stdout"

    - name: Report the final geometry
      ansible.builtin.debug:
        msg: "{{ xfsinfo.stdout_lines }}"
```

### 8.5 Where this lands in Kubernetes

Local PersistentVolumes are the point where node-level partitioning becomes cluster-visible. The `local` volume plugin has **no provisioner** — the filesystem created in §6 and mounted by §8.2 *is* the volume.

```yaml
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-nvme
provisioner: kubernetes.io/no-provisioner
# The scheduler must place the Pod before the PV is bound, because the
# volume exists on exactly one node and cannot move.
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
allowVolumeExpansion: false
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: local-nvme-node01-0
  labels:
    node: node01
    media: nvme
spec:
  capacity:
    storage: 930Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-nvme
  local:
    # Created by the node bootstrap: sgdisk -> mkfs.xfs -> systemd .mount unit.
    # The kubelet will not create this path; it must already be a mount point.
    path: /mnt/disks/nvme1n1p1
    fsType: xfs
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - node01
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: etcd-data
  namespace: infra
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-nvme
  resources:
    requests:
      storage: 900Gi
```

If `/mnt/disks/nvme1n1p1` is a plain directory on the root filesystem rather than a mount point, the Pod starts, writes, fills `/`, and takes the node down — the exact failure from §1.1. Assert the mount, not the directory:

```
$ findmnt --target /mnt/disks/nvme1n1p1 --json
{
   "filesystems": [
      {
         "target": "/mnt/disks/nvme1n1p1",
         "source": "/dev/nvme1n1p1",
         "fstype": "xfs",
         "options": "rw,noatime,attr2,inode64,logbufs=8,logbsize=32k,prjquota,noquota"
      }
   ]
}
```

---

## 9. The verification ladder

Run these in order. Each rung proves something the previous one does not.

**Rung 1 — the partition table is what you wrote**

```
$ sudo sfdisk -V /dev/nvme1n1
/dev/nvme1n1: 
OK

$ sudo sgdisk -v /dev/nvme1n1
No problems found. 2014 free sectors (1007.0 KiB) available in 1
segments, the largest of which is 2014 (1007.0 KiB) in size.

$ sudo partx -s /dev/nvme1n1
NR    START        END    SECTORS  SIZE NAME
 1     2048    2099199    2097152    1G ESP
 2  2099200    2101247       2048    1M BIOSboot
 3  2101248 2147483614 2145382367 1023G pv0
```

**Rung 2 — the kernel agrees with the disk**

```
$ lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,PARTUUID,PARTLABEL,MOUNTPOINT /dev/nvme1n1
NAME        SIZE TYPE FSTYPE LABEL UUID                                 PARTUUID                             PARTLABEL MOUNTPOINT
nvme1n1    1024G disk                                                                                                  
├─nvme1n1p1   1G part vfat   ESP   3A7C-1F22                            8f2c1a04-…-1d6e3b9a7c05              ESP       /boot/efi
├─nvme1n1p2   1M part                                                   b71e5d92-…-4a0c8e2f6d13              BIOSboot  
└─nvme1n1p3 1023G part LVM2_m…      Wq3nT9-…-8fJ2Kd                     c04a7e18-…-9b5f2c7a1e60              pv0       
```

A partition that exists in `sfdisk -V` but is missing from `lsblk` means the kernel never re-read the table (§4.6).

**Rung 3 — alignment**

```
$ for n in 1 2 3; do
>   printf 'part %s: ' "$n"
>   sudo parted -s /dev/nvme1n1 align-check optimal "$n"
> done
part 1: 1 aligned
part 2: 2 aligned
part 3: 3 aligned
```

**Rung 4 — the filesystem is what you specified**

```
$ sudo dumpe2fs -h /dev/nvme1n1p3 2>/dev/null | grep -E 'Block size|Inode count|Reserved block|features'
$ sudo xfs_info /srv | grep -E 'ftype|crc|reflink|sunit|swidth|nrext64'
$ sudo fsck.fat -v -n /dev/nvme1n1p1
```

**Rung 5 — it is addressed stably**

```
$ blkid /dev/nvme1n1p1 /dev/nvme1n1p3
/dev/nvme1n1p1: LABEL_FATBOOT="ESP" LABEL="ESP" UUID="3A7C-1F22" BLOCK_SIZE="512" TYPE="vfat" PARTLABEL="ESP" PARTUUID="8f2c1a04-3b57-4f81-9a2d-1d6e3b9a7c05"
/dev/nvme1n1p3: LABEL="data" UUID="3f0b0c86-7f2d-4a24-9d7c-8a3c8b4a1f55" BLOCK_SIZE="4096" TYPE="xfs" PARTLABEL="pv0" PARTUUID="c04a7e18-2f93-4d6b-8e15-9b5f2c7a1e60"

$ ls -l /dev/disk/by-uuid/ /dev/disk/by-partuuid/
```

| Symlink tree | Stable across | Use for |
|---|---|---|
| `/dev/disk/by-uuid/` | Re-cabling, controller changes, kernel reorder | `fstab` filesystem entries |
| `/dev/disk/by-label/` | Same, but collides if two volumes share a label | Human-readable `fstab` |
| `/dev/disk/by-partuuid/` | Everything except `mkfs`/repartition | Raw partitions: LUKS, PV, Ceph OSD |
| `/dev/disk/by-partlabel/` | Same as PARTUUID; GPT only | Ignition/Butane targets |
| `/dev/disk/by-id/` | Reboots; encodes vendor + serial | Identifying the *physical* device in a chassis |
| `/dev/disk/by-path/` | Slot topology, not the device | "Which bay is this?" |
| `/dev/sdX` | **Nothing** | Never in `fstab` |

**Rung 6 — the boot will not break**

```
$ findmnt --verify --verbose
/
   [ ] target exists
   [ ] FS type is xfs
   [ ] source /dev/mapper/vg0-root exists
/boot/efi
   [ ] target exists
   [ ] FS type is vfat
   [ ] UUID=3A7C-1F22 translated to /dev/nvme1n1p1
   [ ] source /dev/nvme1n1p1 exists

Success, no errors or warnings detected
```

This is the single most important command after editing `/etc/fstab`. `mount -a` only proves the *currently reachable* entries mount; `findmnt --verify` checks the whole file including options and `passno`.

**Rung 7 — a real write survives a real cycle**

```
$ sudo mount /dev/nvme1n1p3 /srv && \
  sudo dd if=/dev/urandom of=/srv/canary bs=1M count=64 conv=fsync && \
  sha256sum /srv/canary | sudo tee /srv/canary.sha && \
  sudo umount /srv && sudo mount /dev/nvme1n1p3 /srv && \
  sha256sum -c /srv/canary.sha
/srv/canary: OK
```

---

## 10. Failure diagnosis playbook

### 10.1 `Device or resource busy` — `mkfs` or `partprobe` refuses

```
$ sudo mkfs.xfs -f /dev/sdb1
mkfs.xfs: cannot open /dev/sdb1: Device or resource busy
```

Walk the holder chain top-down:

```
$ lsblk /dev/sdb                      # is a dm/md device stacked on it?
NAME              SIZE TYPE  MOUNTPOINTS
sdb               3.6T disk  
└─sdb1            3.6T part  
  └─md127         3.6T raid1 

$ ls /sys/class/block/sdb1/holders/   # authoritative: who claims this device
md127

$ cat /proc/mdstat
md127 : active (auto-read-only) raid1 sdb1[0]
      3906885440 blocks super 1.2 [2/1] [U_]

$ sudo mdadm --stop /dev/md127
mdadm: stopped /dev/md127
$ sudo mdadm --zero-superblock /dev/sdb1
$ sudo wipefs -a /dev/sdb1
```

The complete holder checklist, in the order that resolves fastest:

```
$ findmnt -S /dev/sdb1                # mounted?
$ sudo swapon --show | grep sdb1      # active swap?
$ sudo lsof /dev/sdb1                 # raw open by a process?
$ sudo fuser -vm /dev/sdb1
$ ls /sys/class/block/sdb1/holders/   # dm / md / bcache stacked above
$ sudo dmsetup ls --tree              # device-mapper stack
$ sudo cryptsetup status <name>       # LUKS mapping
$ sudo pvs; sudo vgs                  # LVM claim
$ sudo multipath -ll                  # multipath claim
```

The most common cause on a fresh disk is **udev auto-assembling a stale `mdraid` or LVM signature left by the previous life of that LUN**. `wipefs -a` before partitioning prevents it entirely.

### 10.2 Partitions written but not visible

Symptom: `sfdisk -V` says OK, `/dev/sdb3` does not exist.

```
$ sudo partx -a --nr 3 /dev/sdb       # add only the new partition
$ sudo udevadm settle
$ ls -l /dev/sdb3
brw-rw---- 1 root disk 8, 19 Aug 26 11:42 /dev/sdb3
```

If that still fails, the disk has a busy partition blocking the whole-device re-read. Options in escalating order: `partx -a --nr N` (usually works), unmount/deactivate the busy partition, or reboot. Never write to a disk whose kernel view you know is stale — you will compute offsets against the wrong table.

### 10.3 `Warning! Secondary header claims to be at...` — GPT after a resize or clone

```
$ sudo gdisk -l /dev/vda
GPT fdisk (gdisk) version 1.0.9

Warning! Disk size is smaller than the main header indicates! Loading
secondary header from the last sector of the disk! You should use 'v' to
verify disk integrity, and perhaps options on the experts' menu to repair
the disk.
Caution: invalid backup GPT header, but valid main header; regenerating
backup header from main header.

Warning! One or more CRCs don't match. You should repair the disk!
Main header: OK
Backup header: ERROR
Main partition table: OK
Backup partition table: ERROR
```

Cause: the virtual disk was grown (or shrunk, or dd-cloned to a differently sized target) and the backup GPT is no longer at the last LBA.

```
$ sudo sgdisk -e /dev/vda          # relocate backup structures to the end of the disk
Warning: The kernel is still using the old partition table.
The new table will be used at the next reboot or after you
run partprobe(8) or partx(8)
The operation has completed successfully.

$ sudo sgdisk -v /dev/vda
No problems found. 41940958 free sectors (20.0 GiB) available in 1 segments,
the largest of which is 41940958 (20.0 GiB) in size.
```

`parted` offers the same repair interactively:

```
$ sudo parted /dev/vda print
Warning: Not all of the space available to /dev/vda appears to be used, you can
fix the GPT to use all of the space (an extra 41940958 blocks) or continue with
the current setting? 
Fix/Ignore? Fix
```

### 10.4 Duplicate UUIDs after cloning a VM template

Symptom: two nodes boot the same LUN, or `mount UUID=…` picks the wrong device non-deterministically.

```
$ sudo blkid | sort -t= -k3
/dev/vda2: UUID="3f0b0c86-7f2d-4a24-9d7c-8a3c8b4a1f55" TYPE="xfs"
/dev/vdb2: UUID="3f0b0c86-7f2d-4a24-9d7c-8a3c8b4a1f55" TYPE="xfs"
```

Regenerate — **on the unmounted clone only**:

```
$ sudo sgdisk -G /dev/vdb                            # new disk GUID + all partition GUIDs
$ sudo xfs_admin -U generate /dev/vdb2               # XFS
Clearing log and setting UUID
writing all SBs
new UUID = 7c2e4a91-5b38-4f60-a1d7-3e9c0b8f2a45

$ sudo tune2fs -U random /dev/vdb3                   # ext2/3/4
tune2fs 1.47.0 (5-Feb-2023)
Setting the UUID on this filesystem could take some time.
Proceed anyway (or wait 5 seconds to proceed) ? (y,N) y

$ sudo mkswap -U random /dev/vdb1                    # swap
```

Then update `/etc/fstab` and rebuild the initramfs (`dracut -f` / `update-initramfs -u`) — the old UUID is baked into it.

### 10.5 `No space left on device` with free blocks — inode exhaustion

```
$ df -h /var/spool/mail
Filesystem      Size  Used Avail Use% Mounted on
/dev/sdb1       917G  312G  559G  36% /var/spool/mail

$ touch /var/spool/mail/test
touch: cannot touch '/var/spool/mail/test': No space left on device

$ df -i /var/spool/mail
Filesystem       Inodes  IUsed IFree IUse% Mounted on
/dev/sdb1      60030976 60030976     0  100% /var/spool/mail
```

**ext4 inode counts are fixed at `mkfs` time and cannot be increased.** The only remedies are: delete files, or back up → `mkfs` with `-i 8192` (or `-N`) → restore.

Find the consumer:

```
$ sudo find /var/spool/mail -xdev -printf '%h\n' | sort | uniq -c | sort -rn | head
2841022 /var/spool/mail/queue/E
2799417 /var/spool/mail/queue/D
```

**XFS does not have this failure mode** — inodes are allocated dynamically, bounded only by `imaxpct`. For workloads with unpredictable file counts, that is a decisive argument for XFS.

### 10.6 `mkfs` takes 40 minutes on a SAN LUN

Cause: the discard/TRIM pass. Visible as `Discarding blocks...` from `mkfs.xfs` or a long pause before `Allocating group tables` in `mke2fs`.

```
$ sudo mkfs.xfs -f -K /dev/mapper/mpatha           # -K = do not discard
$ sudo mkfs.ext4 -E nodiscard /dev/mapper/mpatha
```

Skip discard when the volume is freshly thin-provisioned (nothing to reclaim) or when the array's UNMAP implementation is slow. Keep discard on a used consumer SSD being repurposed, where it restores write performance.

### 10.7 UEFI firmware does not see the boot entry

Checklist, in order:

```
$ sudo parted /dev/nvme0n1 print | grep -i esp
 1      1049kB  538MB   537MB   fat32        ESP   boot, esp

$ blkid -s TYPE -o value /dev/nvme0n1p1
vfat

$ sudo fdisk -l /dev/nvme0n1 | head -6 | grep Disklabel
Disklabel type: gpt

$ sudo efibootmgr -v
BootCurrent: 0001
BootOrder: 0001,0000
Boot0001* Fedora  HD(1,GPT,8f2c1a04-3b57-4f81-9a2d-1d6e3b9a7c05,0x800,0x100000)/File(\EFI\FEDORA\SHIMX64.EFI)
```

Failure causes, ranked by frequency: the ESP was formatted ext4; the type GUID is `8300` instead of `ef00`; the table is MBR on a UEFI-only machine; the loader path is not `\EFI\BOOT\BOOTX64.EFI` and no NVRAM entry exists; the ESP is FAT16 on firmware that only accepts FAT32.

### 10.8 The build host produced an unmountable filesystem

```
$ sudo mount /dev/sdb1 /mnt
mount: /mnt: wrong fs type, bad option, bad superblock on /dev/sdb1, missing
       codepage or helper program, or other error.
       dmesg(1) may have more information after failed mount system call.

$ dmesg | tail -3
[ 9241.118203] XFS (sdb1): Superblock has unknown incompatible features (0x20)
               enabled.
[ 9241.118211] XFS (sdb1): Filesystem cannot be safely mounted by this kernel.
[ 9241.118219] XFS (sdb1): SB validate failed with error -22.
```

The filesystem is fine; **this kernel is older than the feature set**. Establish the minimum kernel across the fleet and pin `mkfs` accordingly:

| Feature | Tool default since | Minimum kernel to mount | Disable with |
|---|---|---|---|
| XFS `nrext64` (64-bit extent counters) | `xfsprogs` 6.0 | 5.19 | `-i nrext64=0` |
| XFS `bigtime` (year-2486 timestamps) | `xfsprogs` 5.15 | 5.10 | `-m bigtime=0` |
| XFS `inobtcount` | `xfsprogs` 5.15 | 5.10 | `-m inobtcount=0` |
| XFS `reflink` | `xfsprogs` 5.1 | 4.9 | `-m reflink=0` |
| ext4 `orphan_file` | `e2fsprogs` 1.47 | 5.15 | `-O ^orphan_file` |
| ext4 `metadata_csum_seed` | `e2fsprogs` 1.47 | 4.4 | `-O ^metadata_csum_seed` |

Same diagnosis for ext4 (`EXT4-fs (sdb1): couldn't mount RDWR because of unsupported optional features`).

### 10.9 Wrong `passno` in `/etc/fstab`

```
UUID=…  /srv  xfs  defaults  0 2     # WRONG
```

XFS has no boot-time `fsck` — `fsck.xfs` is a script that exits 0 immediately — so `passno=2` is harmless there but meaningless. The real damage is the mirror-image error: an ext4 data volume with `passno=0` never gets checked, and a removable or network-attached volume with `nofail` missing drops the boot into emergency mode when it is absent.

```
UUID=…  /srv       xfs   defaults,noatime,inode64                          0 0
UUID=…  /var/log   ext4  defaults,noatime                                  0 2
UUID=…  /mnt/nfs   xfs   defaults,nofail,x-systemd.device-timeout=10s      0 0
```

Rule: `passno` — `1` for `/` only, `2` for other ext2/3/4, `0` for XFS/Btrfs/swap/network. Always add `nofail` to anything that is not required for the system to reach `multi-user.target`.

### 10.10 Quick symptom → cause index

| Symptom | Most likely cause | First command |
|---|---|---|
| `mkfs: Device or resource busy` | udev auto-assembled a stale md/LVM signature | `ls /sys/class/block/<dev>/holders/` |
| Partition written, node missing | Kernel table not re-read | `partx -a --nr N /dev/sdX` |
| `partprobe` reports "in use" | Another partition on the disk is mounted | `findmnt -S /dev/sdX*` |
| Boot drops to emergency shell | `fstab` UUID typo or missing device | `findmnt --verify --verbose` |
| `df` shows free space, writes fail | ext inode exhaustion | `df -i` |
| Missing ~5 % of capacity | ext reserved blocks | `dumpe2fs -h \| grep Reserved` |
| Writes 3× slower than expected | Misalignment / missing stripe geometry | `parted align-check optimal N`; `xfs_info \| grep sunit` |
| Container runtime will not start on XFS | `ftype=0` | `xfs_info \| grep ftype` |
| `mkfs` unexpectedly slow | Discard pass on a large/thin LUN | add `-K` / `-E nodiscard` |
| GPT CRC warnings after resize | Backup header not at last LBA | `sgdisk -e /dev/sdX` |
| Two devices, one UUID | VM clone without regeneration | `blkid \| sort`; `sgdisk -G` |
| `swapon: Invalid argument` on a file | `fallocate`d file on XFS | recreate with `dd` |
| Cannot shrink a volume | XFS | migrate; XFS shrink does not exist |
| Filesystem unmountable on older node | Newer `mkfs` feature set | `dmesg \| grep -i 'unknown.*feature'` |

---

## 11. Lab

Reproducible on any machine with 2 GiB of free space, using loop devices. Nothing touches real disks.

```
$ truncate -s 8G /tmp/lab-mbr.img
$ truncate -s 8G /tmp/lab-gpt.img
$ sudo losetup -fP --show /tmp/lab-mbr.img
/dev/loop0
$ sudo losetup -fP --show /tmp/lab-gpt.img
/dev/loop1
```

**Exercise 1 — MBR with four regions including an extended container.**
Build on `/dev/loop0`: 512 MiB `83`, 1 GiB `82`, an extended partition covering the rest, and two logical partitions of 2 GiB and 1 GiB inside it. Verify with `fdisk -l` that logicals are numbered from 5 and that each starts 2048 sectors after the preceding EBR.

**Exercise 2 — GPT with a full boot layout.**
On `/dev/loop1`, using `sgdisk` only, in one command: 1 MiB `ef02`, 512 MiB `ef00` named `ESP`, 1 GiB `8200` named `swap0`, remainder `8300` named `root`. Verify with `sgdisk -v` and `parted unit s print free`.

**Exercise 3 — filesystems.**
`mkfs.vfat -F 32 -n ESP` the ESP; `mkfs.ext4 -m 1 -i 32768 -L root` the root; `mkswap -L swap0` the swap. Record the backup superblock list from `mkfs.ext4 -n`.

**Exercise 4 — destroy and recover.**
`dd if=/dev/zero of=/dev/loop1p4 bs=1k count=1 seek=1` wipes the primary ext4 superblock. Confirm the failure with `mount`, then repair with `e2fsck -b <backup> -B 4096`.

**Exercise 5 — destroy and recover the GPT.**
`dd if=/dev/zero of=/dev/loop1 bs=512 count=1` destroys the protective MBR. Confirm with `fdisk -l`, then restore from the backup GPT using `gdisk` recovery menu (`r`, then `b`).

**Exercise 6 — the alignment lesson.**
Create a partition starting at sector 63 with `sfdisk`, then run `parted align-check optimal 1`. Observe `not aligned`. Recreate at 2048.

Teardown:

```
$ sudo losetup -d /dev/loop0 /dev/loop1
$ rm -f /tmp/lab-mbr.img /tmp/lab-gpt.img
```

---

## 12. Exam quick reference and traps

**Traps that appear repeatedly:**

1. `parted mkpart primary ext4 1MiB 100%` **does not create a filesystem.** It sets a partition type code. `mkfs.ext4` is still required.
2. In `fdisk`, nothing is written until `w`. `q` discards.
3. Logical partitions always start at **5**, even with only one primary in use.
4. MBR caps at **2 TiB with 512-byte sectors** — express it as a byte figure, not "2 TB".
5. `mkfs -t ext4` = `mkfs.ext4` = `mke2fs -t ext4`. `mkfs.vfat` = `mkfs.msdos` = `mkdosfs` = `mkfs.fat`.
6. `mkswap` prepares; `swapon` activates. Both are needed, plus an `fstab` entry to survive reboot.
7. GPT is required beyond 2 TiB **and** for UEFI native boot; the `ef02` BIOS boot partition is required for GRUB on GPT under legacy BIOS.
8. Default alignment is sector 2048 = 1 MiB in `fdisk`, `gdisk` and `parted`.
9. `mkfs.ext4 -m` takes a **percentage**, not a byte count.
10. XFS can grow but **never shrink**. ext4 can shrink, but only unmounted.
11. ReiserFS and Btrfs are *awareness* level for LPIC-1 — recognise what they are, do not expect deep configuration questions.
12. `fdisk` handles GPT since util-linux 2.23; the "fdisk cannot do GPT" claim is outdated, but `gdisk`/`parted` remain the objective's named GPT tools.

**Command cheat sheet:**

```
fdisk -l                        # list all partition tables
fdisk /dev/sdX                  # n d t l p a v o g w q  (x = expert)
gdisk /dev/sdX                  # n d t i p v w q  (r = recovery, x = expert)
sgdisk -n N:0:+SIZE -t N:CODE -c N:"NAME" /dev/sdX
sgdisk --backup=F /dev/sdX      # sgdisk --load-backup=F ; sgdisk -G ; sgdisk -e
parted -s -a optimal /dev/sdX -- mklabel gpt mkpart NAME fs START END
parted /dev/sdX unit s print free
parted /dev/sdX align-check optimal N
sfdisk -d /dev/sdX > f          # sfdisk /dev/sdY < f ; sfdisk -V /dev/sdX
partprobe /dev/sdX  |  partx -u /dev/sdX  |  blockdev --rereadpt /dev/sdX
wipefs -a /dev/sdXN

mkfs.ext4 -L L -b 4096 -i 32768 -m 1 -J size=256 -E lazy_itable_init=0 /dev/sdXN
mkfs.ext4 -n /dev/sdXN          # dry run: backup superblock locations
mkfs.xfs  -f -L L -i size=512 -m crc=1,reflink=1 -n ftype=1 -d su=64k,sw=4 /dev/sdXN
mkfs.vfat -F 32 -n LABEL /dev/sdXN
mkfs.exfat -L LABEL -c 128K /dev/sdXN
mkfs.btrfs -L L -d raid1 -m raid1 /dev/sdb /dev/sdc
mkswap -L L /dev/sdXN  ;  swapon --priority 10 /dev/sdXN  ;  swapon --show

blkid ; lsblk -f ; dumpe2fs -h ; xfs_info ; fsck.fat -v -n ; findmnt --verify
```

---

## 13. References

**Official certification objectives**
- LPI — Exam 101-500 Objectives (V5.0), Topic 104.1: https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — LPIC-1 Certification Overview: https://www.lpi.org/our-certifications/lpic-1-overview/

**Specifications**
- UEFI Specification (GPT layout, ESP requirements, partition type GUIDs) — UEFI Forum: https://uefi.org/specifications
- Discoverable Partitions Specification — systemd/UAPI Group: https://uapi-group.org/specifications/specs/discoverable_partitions_specification/

**Utilities — upstream documentation and manual pages**
- util-linux (`fdisk`, `sfdisk`, `partx`, `blkid`, `lsblk`, `wipefs`, `mkswap`, `swapon`, `findmnt`): https://github.com/util-linux/util-linux and https://man7.org/linux/man-pages/man8/fdisk.8.html
- `sfdisk(8)`: https://man7.org/linux/man-pages/man8/sfdisk.8.html
- `mkswap(8)`: https://man7.org/linux/man-pages/man8/mkswap.8.html
- `swapon(8)`: https://man7.org/linux/man-pages/man8/swapon.8.html
- GPT fdisk (`gdisk`, `sgdisk`, `cgdisk`) — project home and documentation: https://www.rodsbooks.com/gdisk/
- `gdisk(8)`: https://man7.org/linux/man-pages/man8/gdisk.8.html
- GNU Parted manual: https://www.gnu.org/software/parted/manual/parted.html
- `parted(8)`: https://man7.org/linux/man-pages/man8/parted.8.html
- `mkfs(8)`: https://man7.org/linux/man-pages/man8/mkfs.8.html

**Filesystems**
- e2fsprogs project (`mke2fs`, `dumpe2fs`, `tune2fs`, `e2fsck`): https://e2fsprogs.sourceforge.net/
- `mke2fs(8)`: https://man7.org/linux/man-pages/man8/mke2fs.8.html
- `mke2fs.conf(5)`: https://man7.org/linux/man-pages/man5/mke2fs.conf.5.html
- ext4 kernel documentation: https://docs.kernel.org/filesystems/ext4/index.html
- XFS kernel documentation: https://docs.kernel.org/filesystems/xfs/index.html
- `mkfs.xfs(8)`: https://man7.org/linux/man-pages/man8/mkfs.xfs.8.html
- xfsprogs source: https://git.kernel.org/pub/scm/fs/xfs/xfsprogs-dev.git/
- Btrfs documentation: https://btrfs.readthedocs.io/en/latest/
- `mkfs.btrfs`: https://btrfs.readthedocs.io/en/latest/mkfs.btrfs.html
- dosfstools (`mkfs.fat`, `fsck.fat`): https://github.com/dosfstools/dosfstools
- `mkfs.fat(8)`: https://man7.org/linux/man-pages/man8/mkfs.fat.8.html
- exfatprogs: https://github.com/exfatprogs/exfatprogs
- exFAT kernel documentation: https://docs.kernel.org/filesystems/index.html

**Kernel and block layer**
- Block layer sysfs ABI (`queue/logical_block_size`, `optimal_io_size`, alignment): https://docs.kernel.org/block/queue-sysfs.html
- Linux kernel filesystem documentation index: https://docs.kernel.org/filesystems/index.html
- ReiserFS deprecation notice, kernel documentation: https://docs.kernel.org/process/deprecated.html

**Infrastructure as code**
- systemd `repart.d(5)`: https://www.freedesktop.org/software/systemd/man/latest/repart.d.html
- `systemd-repart(8)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-repart.html
- `systemd-gpt-auto-generator(8)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-gpt-auto-generator.html
- `fstab(5)`: https://www.freedesktop.org/software/systemd/man/latest/fstab.html
- cloud-init modules — Disk Setup: https://cloudinit.readthedocs.io/en/latest/reference/modules.html#disk-setup
- Butane configuration specification v1.5.0: https://coreos.github.io/butane/config-fcos-v1_5/
- Ignition specification v3.4.0: https://coreos.github.io/ignition/configuration-v3_4/
- Ansible `community.general.parted`: https://docs.ansible.com/ansible/latest/collections/community/general/parted_module.html
- Ansible `community.general.filesystem`: https://docs.ansible.com/ansible/latest/collections/community/general/filesystem_module.html
- Ansible `ansible.posix.mount`: https://docs.ansible.com/ansible/latest/collections/ansible/posix/mount_module.html
- Kubernetes — Local Persistent Volumes: https://kubernetes.io/docs/concepts/storage/volumes/#local
- Kubernetes — Storage Classes: https://kubernetes.io/docs/concepts/storage/storage-classes/