# LPIC-1 — 104.1 Create partitions and filesystems
## Guided exercises (Exam 101-500, weight 3)

> **Scope covered here:** MBR partition tables with `fdisk`, GPT with `gdisk`/`sgdisk`/`parted`, `mkfs` for ext2/ext3/ext4, XFS, VFAT and exFAT, `mkswap`, and awareness of Btrfs and ReiserFS.

---

## 0. Lab environment and safety

Every command in this document destroys data on the device it is given. You will **never** point them at a real disk. Instead you build two disk images and expose them as block devices with the loop driver, which the kernel treats exactly like `/dev/sda` — same partition scanning, same `mkfs`, same `mount`, same failure modes.

**Prerequisites** (Debian/Ubuntu names; on RHEL-family use `dnf`):

```bash
sudo apt-get install -y util-linux gdisk parted e2fsprogs xfsprogs \
                        dosfstools exfatprogs btrfs-progs
```

Outputs below were captured on Debian 12 with `util-linux 2.38.1`, `e2fsprogs 1.47.0`, `xfsprogs 6.1.0`, `dosfstools 4.2`, `exfatprogs 1.2.2`, `btrfs-progs 6.2`. Tool versions change the exact wording of the output, not the concepts. Run everything as root (`sudo -i`) unless noted.

---

## Exercise 1 — Map the block layer before you touch it

The single most common cause of destroyed production data in this topic is running a correct command against the wrong device name. Device names are *not* stable across reboots; identify by size, model and UUID.

**Steps**

1. Create the working directory and the two backing files. `truncate` creates sparse files, so 6 GiB of "disk" costs almost no real space:

   ```bash
   mkdir -p /var/tmp/lpic104 /mnt/lab
   truncate -s 2G /var/tmp/lpic104/disk-mbr.img
   truncate -s 4G /var/tmp/lpic104/disk-gpt.img
   ls -lsh /var/tmp/lpic104/
   ```

   ```
   total 0
   0 -rw-r--r-- 1 root root 2.0G Aug 26 10:12 disk-mbr.img
   0 -rw-r--r-- 1 root root 4.0G Aug 26 10:12 disk-gpt.img
   ```

   Note the `0` in the first column (blocks actually allocated) against the apparent size.

2. Attach each file to a loop device. `-P` (`--partscan`) tells the kernel to scan the device for a partition table and create `pN` child devices:

   ```bash
   losetup -f -P --show /var/tmp/lpic104/disk-mbr.img
   losetup -f -P --show /var/tmp/lpic104/disk-gpt.img
   ```

   ```
   /dev/loop0
   /dev/loop1
   ```

   If your numbers differ, **use yours** for the rest of the lab. Confirm the mapping at any time with `losetup -a`.

3. Look at the block layer four different ways. Each tool answers a different question:

   ```bash
   lsblk /dev/loop0 /dev/loop1
   ```

   ```
   NAME  MAJ:MIN RM SIZE RO TYPE MOUNTPOINTS
   loop0   7:0    0   2G  0 loop
   loop1   7:1    0   4G  0 loop
   ```

   ```bash
   grep loop /proc/partitions
   ```

   ```
      7        0    2097152 loop0
      7        1    4194304 loop1
   ```

   ```bash
   blkid /dev/loop0 ; echo "exit=$?"
   ```

   ```
   exit=2
   ```

   ```bash
   fdisk -l /dev/loop1
   ```

   ```
   Disk /dev/loop1: 4 GiB, 4294967296 bytes, 8388608 sectors
   Units: sectors of 1 * 512 = 512 bytes
   Sector size (logical/physical): 512 bytes / 512 bytes
   I/O size (minimum/optimal): 512 bytes / 512 bytes
   ```

4. Check the geometry that will drive every alignment decision later:

   ```bash
   blockdev --getss --getpbsz --getsize64 /dev/loop1
   ```

   ```
   512
   512
   4294967296
   ```

   On real hardware, compare with a physical disk you own (read-only, harmless):

   ```bash
   lsblk -o NAME,SIZE,PHY-SEC,LOG-SEC,ROTA,MODEL -d
   ```

**Check your understanding**

- **Q1.1** `blkid /dev/loop0` printed nothing and exited 2. What exactly does that prove, and what does it *not* prove?
- **Q1.2** `/proc/partitions` lists `loop0` but no `loop0p1`. Name two independent reasons that entry could be missing on a real disk.
- **Q1.3** A disk reports logical sector size 512 and physical sector size 4096. What is this drive called, and what goes wrong if a partition starts at sector 63?
- **Q1.4** Why is `lsblk -o ...,MODEL,SERIAL` a safer way to pick a target than `/dev/sdb`?

---

## Exercise 2 — MBR: the 512 bytes that describe the disk

**Steps**

1. Start `fdisk` on the 2 GiB device. It is interactive; `m` prints the menu at any point:

   ```bash
   fdisk /dev/loop0
   ```

   ```
   Welcome to fdisk (util-linux 2.38.1).
   Changes will remain in memory only, until you decide to write them.
   Be careful before using the write command.

   Device does not contain a recognized partition table.
   Created a new DOS disklabel with disk identifier 0x1a4f9c73.

   Command (m for help):
   ```

   Read that last line carefully: `fdisk` has already invented an empty MBR **in memory**. Nothing is on disk yet.

2. Create the first primary partition, 512 MiB, accepting the default start:

   ```
   Command (m for help): n
   Partition type
      p   primary (0 primary, 0 extended, 3 free)
      e   extended (container for logical partitions)
   Select (default p): p
   Partition number (1-4, default 1): 1
   First sector (2048-4194303, default 2048): <Enter>
   Last sector, +/-sectors or +/-size{K,M,G,T,P} (2048-4194303, default 4194303): +512M

   Created a new partition 1 of type 'Linux' and of size 512 MiB.
   ```

3. Create a second primary partition of the same size and change its type to Linux swap. The type is a single byte; `l` lists the known values:

   ```
   Command (m for help): n
   Select (default p): p
   Partition number (2-4, default 2): 2
   First sector (1050624-4194303, default 1050624): <Enter>
   Last sector, ... : +512M

   Created a new partition 2 of type 'Linux' and of size 512 MiB.

   Command (m for help): t
   Partition number (1,2, default 2): 2
   Hex code or alias (type L to list all): 82

   Changed type of partition 'Linux' to 'Linux swap / Solaris'.
   ```

4. Inspect the in-memory table, then commit it:

   ```
   Command (m for help): p
   Disk /dev/loop0: 2 GiB, 2147483648 bytes, 4194304 sectors
   Disklabel type: dos
   Disk identifier: 0x1a4f9c73

   Device       Boot   Start     End Sectors  Size Id Type
   /dev/loop0p1         2048 1050623 1048576  512M 83 Linux
   /dev/loop0p2      1050624 2099199 1048576  512M 82 Linux swap / Solaris

   Command (m for help): w
   The partition table has been altered.
   Calling ioctl() to re-read partition table.
   Syncing disks.
   ```

5. Verify from the outside that the kernel picked it up:

   ```bash
   lsblk /dev/loop0
   ```

   ```
   NAME      MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
   loop0       7:0    0    2G  0 loop
   ├─loop0p1 259:0    0  512M  0 part
   └─loop0p2 259:1    0  512M  0 part
   ```

6. Now read the raw MBR yourself. This is the whole point of the exercise — the "partition table" is 64 bytes:

   ```bash
   dd if=/dev/loop0 bs=512 count=1 status=none | hexdump -C | tail -n 6
   ```

   ```
   000001b0  00 00 00 00 00 00 00 00  73 9c 4f 1a 00 00 00 20  |........s.O.... |
   000001c0  21 00 83 2a 44 20 00 08  00 00 00 00 10 00 00 2a  |!..*D ....... .*|
   000001d0  45 20 82 4b 4d 20 00 08  10 00 00 00 10 00 00 00  |E .KM ..........|
   000001e0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
   000001f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 55 aa  |..............UU|
   ```

   Byte offset `0x1BE` starts entry 1, `0x1CE` entry 2, `0x1DE` entry 3, `0x1EE` entry 4, and `0x1FE` holds the boot signature `55 AA`. Within each 16-byte entry, byte 0 is the boot flag, byte 4 is the **partition type ID**, and bytes 8–11 and 12–15 are the 32-bit starting LBA and length in sectors, little-endian.

7. Take a backup of the whole thing — the professional habit before every partitioning session:

   ```bash
   sfdisk --dump /dev/loop0 > /var/tmp/lpic104/loop0.sfdisk
   dd if=/dev/loop0 of=/var/tmp/lpic104/loop0-mbr.bin bs=512 count=1
   cat /var/tmp/lpic104/loop0.sfdisk
   ```

   ```
   label: dos
   label-id: 0x1a4f9c73
   device: /dev/loop0
   unit: sectors
   sector-size: 512

   /dev/loop0p1 : start=        2048, size=     1048576, type=83
   /dev/loop0p2 : start=     1050624, size=     1048576, type=82
   ```

   That text file can be replayed with `sfdisk /dev/loop0 < loop0.sfdisk`.

**Check your understanding**

- **Q2.1** `fdisk` chose sector 2048 as the default start. Convert that to bytes and explain the choice in one sentence.
- **Q2.2** You set the type byte of partition 2 to `82`. Does the kernel refuse to `mkfs.ext4` that partition now? What is the type byte actually for?
- **Q2.3** In the hexdump, partition 1's start LBA is encoded `00 08 00 00`. What decimal value is that, and why is the byte order like that?
- **Q2.4** MBR stores the start LBA and the length as 32-bit values. Derive the maximum addressable disk size for a 512-byte-sector drive, and state what changes on a 4Kn drive.
- **Q2.5** What is the practical difference between `sfdisk --dump` and `dd` of the first sector as a backup?

---

## Exercise 3 — The extended partition and the EBR chain

MBR has room for exactly four entries. The extended partition is the historical workaround: one of the four slots becomes a container holding a singly-linked list.

**Steps**

1. Re-enter `fdisk` and create an extended partition filling the rest of the disk:

   ```bash
   fdisk /dev/loop0
   ```

   ```
   Command (m for help): n
   Partition type
      p   primary (2 primary, 0 extended, 2 free)
      e   extended (container for logical partitions)
   Select (default p): e
   Partition number (3,4, default 3): 3
   First sector (2099200-4194303, default 2099200): <Enter>
   Last sector, ... (default 4194303): <Enter>

   Created a new partition 3 of type 'Extended' and of size 1023 MiB.
   ```

2. Create two logical partitions inside it. Note that `fdisk` no longer asks for a number:

   ```
   Command (m for help): n
   All primary partitions are in use.
   Adding logical partition 5
   First sector (2101248-4194303, default 2101248): <Enter>
   Last sector, ... : +500M

   Created a new partition 5 of type 'Linux' and of size 500 MiB.

   Command (m for help): n
   All primary partitions are in use.
   Adding logical partition 6
   First sector (3127296-4194303, default 3127296): <Enter>
   Last sector, ... (default 4194303): <Enter>

   Created a new partition 6 of type 'Linux' and of size 521 MiB.
   ```

3. Set the types you will actually format later — `07` for exFAT and `0c` for FAT32 (LBA) — then write:

   ```
   Command (m for help): t
   Partition number (1-3,5,6, default 6): 5
   Hex code or alias (type L to list all): 07
   Changed type of partition 'Linux' to 'HPFS/NTFS/exFAT'.

   Command (m for help): t
   Partition number (1-3,5,6, default 6): 6
   Hex code or alias (type L to list all): 0c
   Changed type of partition 'Linux' to 'W95 FAT32 (LBA)'.

   Command (m for help): p

   Device       Boot   Start     End Sectors  Size Id Type
   /dev/loop0p1         2048 1050623 1048576  512M 83 Linux
   /dev/loop0p2      1050624 2099199 1048576  512M 82 Linux swap / Solaris
   /dev/loop0p3      2099200 4194303 2095104 1023M  5 Extended
   /dev/loop0p5      2101248 3125247 1024000  500M  7 HPFS/NTFS/exFAT
   /dev/loop0p6      3127296 4194303 1067008  521M  c W95 FAT32 (LBA)

   Command (m for help): w
   ```

4. Confirm the topology and the sizes the kernel exposes:

   ```bash
   lsblk /dev/loop0
   ```

   ```
   NAME      MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
   loop0       7:0    0    2G  0 loop
   ├─loop0p1 259:0    0  512M  0 part
   ├─loop0p2 259:1    0  512M  0 part
   ├─loop0p3 259:2    0    1K  0 part
   ├─loop0p5 259:3    0  500M  0 part
   └─loop0p6 259:4    0  521M  0 part
   ```

   `loop0p3` shows as **1K**. That is the extended partition itself: the kernel deliberately exposes only its first sector so that nobody can accidentally write a filesystem over the container and destroy the chain.

5. Look at the first EBR. It lives at the very first sector of the extended partition (2099200) and has the same 512-byte layout as the MBR, but only two of the four entries are ever used:

   ```bash
   dd if=/dev/loop0 bs=512 count=1 skip=2099200 status=none | hexdump -C | sed -n '28,32p'
   ```

   ```
   000001b0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 20  |............... |
   000001c0  21 00 07 fe ff ff 00 08  00 00 00 a0 0f 00 00 fe  |!............... |
   000001d0  ff ff 05 fe ff ff 00 c0  0f 00 00 40 10 00 00 00  |...........@....|
   000001e0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
   000001f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 55 aa  |..............UU|
   ```

   Entry 1 (`0x1BE`) describes the logical partition, with a start **relative to this EBR**. Entry 2 (`0x1CE`) has type `05` and points at the *next* EBR, with a start relative to the beginning of the extended partition. That is the linked list.

6. Restore the discipline of verification — dump the table again and diff it against your backup:

   ```bash
   sfdisk --dump /dev/loop0 | diff -u /var/tmp/lpic104/loop0.sfdisk - | head -n 20
   ```

**Check your understanding**

- **Q3.1** Why does the numbering of logical partitions always start at 5, even when only one primary partition exists?
- **Q3.2** Can an MBR disk hold two extended partitions? Justify the answer from the on-disk structure, not from the tool's error message.
- **Q3.3** `/dev/loop0p3` is 1 KiB. What is the risk this deliberately prevents?
- **Q3.4** Logical partition 5 begins at sector 2101248 while the extended partition begins at 2099200 — a gap of 2048 sectors. What lives in that gap, and how many sectors does it strictly need?
- **Q3.5** You delete logical partition 5 with `fdisk` while partition 6 exists. What happens to partition 6's device name, and why is that dangerous for `/etc/fstab`?

---

## Exercise 4 — GPT with `gdisk`

**Steps**

1. Open the 4 GiB device with `gdisk`. Read the scan report before doing anything:

   ```bash
   gdisk /dev/loop1
   ```

   ```
   GPT fdisk (gdisk) version 1.0.9

   Partition table scan:
     MBR: not present
     BSD: not present
     APM: not present
     GPT: not present

   Creating new GPT entries in memory.

   Command (? for help):
   ```

2. Create four partitions. `gdisk` accepts `+size` notation and aligns starts automatically:

   ```
   Command (? for help): n
   Partition number (1-128, default 1): 1
   First sector (34-8388574, default = 2048) or {+-}size{KMGTP}: <Enter>
   Last sector (2048-8388574, default = 8388574) or {+-}size{KMGTP}: +512M
   Current type is 8300 (Linux filesystem)
   Hex code or GUID (L to show codes, Enter = 8300): ef00
   Changed type of partition to 'EFI system partition'

   Command (? for help): n
   Partition number (2-128, default 2): 2
   First sector ... (default = 1050624): <Enter>
   Last sector ... : +1G
   Hex code or GUID (L to show codes, Enter = 8300): <Enter>
   Changed type of partition to 'Linux filesystem'
   ```

   Repeat `n` twice more for partitions 3 and 4, each `+1G`, type `8300`.

3. Give partitions human-readable names — a GPT feature MBR does not have — with `c`:

   ```
   Command (? for help): c
   Partition number (1-4): 2
   Enter name: xfs-data

   Command (? for help): c
   Partition number (1-4): 3
   Enter name: ext4-data

   Command (? for help): c
   Partition number (1-4): 4
   Enter name: btrfs-data
   ```

4. Print the table and study the header geometry:

   ```
   Command (? for help): p
   Disk /dev/loop1: 8388608 sectors, 4.0 GiB
   Sector size (logical/physical): 512/512 bytes
   Disk identifier (GUID): 7C2E4A61-9B33-4E77-B0F2-15E0C2A9D4A8
   Partition table holds up to 128 entries
   Main partition table begins at sector 2 and ends at sector 33
   First usable sector is 34, last usable sector is 8388574
   Partitions will be aligned on 2048-sector boundaries
   Total free space is 1048509 sectors (512.0 MiB)

   Number  Start (sector)    End (sector)  Size       Code  Name
      1            2048         1050623   512.0 MiB   EF00  EFI system partition
      2         1050624         3147775   1024.0 MiB  8300  xfs-data
      3         3147776         5244927   1024.0 MiB  8300  ext4-data
      4         5244928         7342079   1024.0 MiB  8300  btrfs-data
   ```

5. Run the built-in consistency check, then write:

   ```
   Command (? for help): v

   No problems found. 1048509 free sectors (512.0 MiB) available in 2
   segments, the largest of which is 1046495 (511.0 MiB) in size.

   Command (? for help): w

   Final checks complete. About to write GPT data. THIS WILL OVERWRITE EXISTING
   PARTITIONS!!

   Do you want to proceed? (Y/N): Y
   OK; writing new GUID partition table (GPT) to /dev/loop1.
   The operation has completed successfully.
   ```

6. Verify from outside, and prove the protective MBR exists:

   ```bash
   sgdisk -p /dev/loop1 | head -n 8
   dd if=/dev/loop1 bs=512 count=1 status=none | hexdump -C | sed -n '28,32p'
   ```

   ```
   000001b0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
   000001c0  02 00 ee ff ff ff 01 00  00 00 ff ff 7f 00 00 00  |................|
   000001d0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
   000001e0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
   000001f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 55 aa  |..............UU|
   ```

   One entry, type `EE`, spanning the whole disk. An MBR-only tool sees a full, unknown disk and refuses to touch it.

7. Compare the two GPT headers — primary at LBA 1, backup at the last LBA:

   ```bash
   dd if=/dev/loop1 bs=512 count=1 skip=1 status=none | hexdump -C | head -n 4
   dd if=/dev/loop1 bs=512 count=1 skip=8388607 status=none | hexdump -C | head -n 4
   ```

   ```
   00000000  45 46 49 20 50 41 52 54  00 00 01 00 5c 00 00 00  |EFI PART....\...|
   ```

   Both begin with the `EFI PART` signature. This redundancy is why `gdisk` can repair a disk whose first sectors were overwritten (`r` → recovery menu → `b`, rebuild main header from backup).

8. Back up the GPT to a file:

   ```bash
   sgdisk --backup=/var/tmp/lpic104/loop1.gpt /dev/loop1
   ```

   ```
   The operation has completed successfully.
   ```

**Check your understanding**

- **Q4.1** `gdisk` said "First usable sector is 34". Derive that number from the GPT layout.
- **Q4.2** Compute the last usable sector for this 8388608-sector disk and explain why it is not 8388606.
- **Q4.3** What is the type `EE` entry in sector 0 for? Name one concrete failure it prevents.
- **Q4.4** GPT stores a type **GUID** per partition instead of MBR's one-byte ID. Beyond the larger namespace, what capability does that unlock that MBR cannot express?
- **Q4.5** A colleague ran `dd if=/dev/zero of=/dev/sdb bs=512 count=1` on a GPT disk and says "the disk is gone". What is actually gone, what survives, and which `gdisk` menu recovers it?
- **Q4.6** How many partitions can this table hold, and where is that number stored?

---

## Exercise 5 — Scripted partitioning with `parted` and `sgdisk`, and alignment

Interactive tools are for humans. Automation needs `parted -s`, `sgdisk` or `sfdisk`.

**Steps**

1. Inspect the GPT disk with `parted`, including free space:

   ```bash
   parted /dev/loop1 unit MiB print free
   ```

   ```
   Model: Loopback device (loop)
   Disk /dev/loop1: 4096MiB
   Sector size (logical/physical): 512B/512B
   Partition Table: gpt
   Disk Flags:

   Number  Start     End       Size      File system  Name                  Flags
           0.02MiB   1.00MiB   0.98MiB   Free Space
    1      1.00MiB   513MiB    512MiB                 EFI system partition
    2      513MiB    1537MiB   1024MiB                xfs-data
    3      1537MiB   2561MiB   1024MiB                ext4-data
    4      2561MiB   3585MiB   1024MiB                btrfs-data
           3585MiB   4096MiB   511MiB    Free Space
   ```

   `unit MiB` matters: by default `parted` prints powers of ten (`MB` = 1 000 000 bytes), which is a classic source of off-by-a-lot confusion.

2. Add a fifth partition non-interactively in the remaining space:

   ```bash
   parted -s -a optimal /dev/loop1 mkpart scratch ext4 3585MiB 100%
   parted -s /dev/loop1 unit MiB print | tail -n 3
   ```

   ```
    4      2561MiB   3585MiB   1024MiB               btrfs-data
    5      3585MiB   4096MiB   511MiB   ext4         scratch
   ```

   The `ext4` argument set the partition **type GUID** and a table hint. It did **not** create a filesystem — the `File system` column here is `parted`'s own probe result plus the recorded hint.

3. Prove alignment:

   ```bash
   parted /dev/loop1 align-check optimal 1
   parted /dev/loop1 align-check optimal 5
   ```

   ```
   1 aligned
   5 aligned
   ```

4. Now deliberately create a misaligned partition on the MBR disk to see the check fail. First free some space, then use `sfdisk` to place a partition at sector 2049:

   ```bash
   sgdisk --version >/dev/null   # sanity check tools exist
   parted /dev/loop0 align-check optimal 1
   ```

   ```
   1 aligned
   ```

   ```bash
   parted /dev/loop0 unit s print | grep -E '^ [0-9]'
   ```

   ```
    1      2048s    1050623s  1048576s  primary
    2      1050624s 2099199s  1048576s  primary
   ```

5. Compare the scripted GPT equivalent with `sgdisk`, which is `gdisk`'s batch front end:

   ```bash
   sgdisk -p /dev/loop1 | tail -n 6
   ```

   ```
   Number  Start (sector)    End (sector)  Size       Code  Name
      1            2048         1050623   512.0 MiB   EF00  EFI system partition
      2         1050624         3147775   1024.0 MiB  8300  xfs-data
      3         3147776         5244927   1024.0 MiB  8300  ext4-data
      4         5244928         7342079   1024.0 MiB  8300  btrfs-data
      5         7342080         8388574   511.0 MiB   8300  scratch
   ```

   The idiomatic scripted form of everything you did interactively would have been:

   ```bash
   # Reference only — do not run, it would wipe the lab
   sgdisk --zap-all /dev/loop1
   sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI system partition" \
          -n 2:0:+1G    -t 2:8300 -c 2:"xfs-data" \
          -n 3:0:+1G    -t 3:8300 -c 3:"ext4-data" \
          -n 4:0:+1G    -t 4:8300 -c 4:"btrfs-data" /dev/loop1
   ```

   In `-n num:start:end`, a start of `0` means "first aligned free sector".

**Check your understanding**

- **Q5.1** In `parted mkpart scratch ext4 3585MiB 100%`, what did the word `ext4` actually do? What must you run afterwards to store files?
- **Q5.2** `parted` printed `4096MB` in one place and `4096MiB` in another for the same disk. Which is bigger and by how much, roughly, for a 4 TB disk?
- **Q5.3** What is the difference between `align-check minimal` and `align-check optimal`?
- **Q5.4** Why is `parted -s` (or `sgdisk`/`sfdisk`) required in a provisioning script, while `fdisk` is not a good fit?
- **Q5.5** `sgdisk --zap-all` versus `wipefs -a` versus `dd if=/dev/zero bs=1M count=10` — what does each remove?

---

## Exercise 6 — ext2, ext3 and ext4 with `mke2fs`

**Steps**

1. Create a plain ext2 filesystem on the first MBR partition and read the output line by line:

   ```bash
   mkfs.ext2 -L labext2 /dev/loop0p1
   ```

   ```
   mke2fs 1.47.0 (5-Feb-2023)
   Creating filesystem with 131072 4k blocks and 32768 inodes
   Filesystem UUID: 6c1d8f3e-42a7-4a19-9b0c-7e5f21d3ab88
   Superblock backups stored on blocks:
   	32768, 98304

   Allocating group tables: done
   Writing inode tables: done
   Writing superblocks and filesystem accounting information: done
   ```

   512 MiB ÷ 4 KiB = 131072 blocks. 536870912 bytes ÷ 16384 bytes-per-inode = 32768 inodes. Nothing here is arbitrary.

2. Confirm there is no journal, then add one in place — this is exactly what turns ext2 into ext3:

   ```bash
   dumpe2fs -h /dev/loop0p1 2>/dev/null | grep -E 'Filesystem (features|volume)'
   ```

   ```
   Filesystem volume name:   labext2
   Filesystem features:      ext_attr resize_inode dir_index filetype sparse_super large_file
   ```

   ```bash
   tune2fs -j /dev/loop0p1
   blkid /dev/loop0p1
   ```

   ```
   tune2fs 1.47.0 (5-Feb-2023)
   Creating journal inode: done

   /dev/loop0p1: LABEL="labext2" UUID="6c1d8f3e-..." BLOCK_SIZE="4096" TYPE="ext3"
   ```

   The `TYPE` reported by `blkid` changed from `ext2` to `ext3` because one feature flag, `has_journal`, appeared. There is no separate "ext3 format".

3. Now create a real ext4 on the GPT partition with production-relevant options:

   ```bash
   mkfs.ext4 -L ext4-data -m 1 -E lazy_itable_init=0,lazy_journal_init=0 /dev/loop1p3
   ```

   ```
   mke2fs 1.47.0 (5-Feb-2023)
   Creating filesystem with 262144 4k blocks and 65536 inodes
   Filesystem UUID: b0e93f5a-1c4d-4f0e-8a77-33d1c6b2ef41
   Superblock backups stored on blocks:
   	32768, 98304, 163840, 229376

   Allocating group tables: done
   Writing inode tables: done
   Creating journal (8192 blocks): done
   Writing superblocks and filesystem accounting information: done
   ```

4. Read the superblock:

   ```bash
   dumpe2fs -h /dev/loop1p3 2>/dev/null
   ```

   ```
   Filesystem volume name:   ext4-data
   Last mounted on:          <not available>
   Filesystem UUID:          b0e93f5a-1c4d-4f0e-8a77-33d1c6b2ef41
   Filesystem magic number:  0xEF53
   Filesystem revision #:    1 (dynamic)
   Filesystem features:      has_journal ext_attr resize_inode dir_index filetype
                             extent 64bit flex_bg sparse_super large_file huge_file
                             dir_nlink extra_isize metadata_csum_seed metadata_csum
   Filesystem state:         clean
   Errors behavior:          Continue
   Filesystem OS type:       Linux
   Inode count:              65536
   Block count:              262144
   Reserved block count:     2621
   Free blocks:              243373
   Free inodes:              65525
   First block:              0
   Block size:               4096
   Reserved GDT blocks:      127
   Blocks per group:         32768
   Inodes per group:         8192
   Inode size:               256
   Journal size:             32M
   ```

   `Reserved block count: 2621` is 1 % of 262144 — your `-m 1`. The default would have been 5 % (13107 blocks, 51 MiB on a 1 GiB volume).

5. Use the dry-run flag to size a filesystem *before* committing to it. `-n` computes and prints without writing:

   ```bash
   mkfs.ext4 -n -i 1024 /dev/loop1p3
   ```

   ```
   mke2fs 1.47.0 (5-Feb-2023)
   Creating filesystem with 262144 4k blocks and 1048576 inodes
   Filesystem UUID: ...
   Superblock backups stored on blocks:
   	32768, 98304, 163840, 229376
   ```

   One inode per 1024 bytes gives 1 048 576 inodes instead of 65 536 — the knob for a mail spool or a build cache full of tiny files. Because `-n` was used, the on-disk filesystem is untouched; confirm with `dumpe2fs -h` again.

6. Mount it, adjust the reserve on a live filesystem, and observe the accounting:

   ```bash
   mkdir -p /mnt/lab/ext4
   mount /dev/loop1p3 /mnt/lab/ext4
   df -h /mnt/lab/ext4 ; df -i /mnt/lab/ext4
   ```

   ```
   Filesystem      Size  Used Avail Use% Mounted on
   /dev/loop1p3    974M   24K  963M   1% /mnt/lab/ext4

   Filesystem      Inodes IUsed IFree IUse% Mounted on
   /dev/loop1p3     65536    11 65525    1% /mnt/lab/ext4
   ```

   ```bash
   tune2fs -m 5 /dev/loop1p3
   df -h /mnt/lab/ext4 | tail -n 1
   ```

   ```
   Setting reserved blocks percentage to 5% (13107 blocks)
   /dev/loop1p3    974M   24K  922M   1% /mnt/lab/ext4
   ```

   41 MiB of "Avail" vanished without a byte being written. The reserve is a `tune2fs` change, applicable at any time; the inode count is not.

7. Locate a backup superblock — the number you need when the primary is corrupt:

   ```bash
   dumpe2fs /dev/loop1p3 2>/dev/null | grep -i 'superblock at'
   ```

   ```
     Primary superblock at 0, Group descriptors at 1-1
     Backup superblock at 32768, Group descriptors at 32769-32769
     Backup superblock at 98304, Group descriptors at 98305-98305
     Backup superblock at 163840, Group descriptors at 163841-163841
     Backup superblock at 229376, Group descriptors at 229377-229377
   ```

   Recovery form (do not run now, the filesystem is mounted and clean): `e2fsck -b 32768 -B 4096 /dev/loop1p3`.

**Check your understanding**

- **Q6.1** From `mkfs.ext2` on a 512 MiB partition you got exactly 32768 inodes. Show the arithmetic, and state which `mke2fs` option changes it.
- **Q6.2** After `tune2fs -j`, `blkid` reports `ext3`. Did the data move? What single thing changed?
- **Q6.3** You need to store 400 000 small files on a 1 GiB volume with default settings. What fails first — space or inodes — and can you fix it after `mkfs`?
- **Q6.4** Explain the purpose of the 5 % reserved blocks and give the two distinct reasons it exists. When is `-m 0` acceptable, and when is it a bad idea?
- **Q6.5** Which ext4 feature flag makes the extent tree possible, and what did ext3 use instead?
- **Q6.6** What are `-E lazy_itable_init=0,lazy_journal_init=0` for, and what is the trade-off?
- **Q6.7** You must recover a filesystem whose primary superblock is destroyed. Where do you find a backup superblock number if `dumpe2fs` itself fails?

---

## Exercise 7 — XFS

**Steps**

1. Create the filesystem on the 1 GiB GPT partition:

   ```bash
   mkfs.xfs -L xfs-data /dev/loop1p2
   ```

   ```
   meta-data=/dev/loop1p2           isize=512    agcount=4, agsize=65536 blks
            =                       sectsz=512   attr=2, projid32bit=1
            =                       crc=1        finobt=1, sparse=1, rmapbt=0
            =                       reflink=1    bigtime=0 inobtcount=0
   data     =                       bsize=4096   blocks=262144, imaxpct=25
            =                       sunit=0      swidth=0 blks
   naming   =version 2              bsize=4096   ascii-ci=0, ftype=1
   log      =internal log           bsize=4096   blocks=2560, version=2
            =                       sectsz=512   sunit=0 blks, lazy-count=1
   realtime =none                   extsz=4096   blocks=0, rtextents=0
   ```

   Four allocation groups of 65536 blocks each — XFS parallelises allocation across AGs, which is why it scales on many-core, many-spindle systems.

2. Mount and inspect the live filesystem:

   ```bash
   mkdir -p /mnt/lab/xfs
   mount /dev/loop1p2 /mnt/lab/xfs
   xfs_info /mnt/lab/xfs | head -n 3
   df -h /mnt/lab/xfs
   ```

   ```
   meta-data=/dev/loop1p2           isize=512    agcount=4, agsize=65536 blks
            =                       sectsz=512   attr=2, projid32bit=1
            =                       crc=1        finobt=1, sparse=1, rmapbt=0

   Filesystem      Size  Used Avail Use% Mounted on
   /dev/loop1p2   1014M   40M  975M   4% /mnt/lab/xfs
   ```

   XFS has no reserved-blocks percentage exposed like ext's `-m`; the ~40 MiB "Used" on an empty filesystem is metadata and the 10 MiB internal log.

3. Try to re-format a device that already has a filesystem, to see the safety interlock:

   ```bash
   umount /mnt/lab/xfs
   mkfs.xfs /dev/loop1p2
   ```

   ```
   mkfs.xfs: /dev/loop1p2 appears to contain an existing filesystem (xfs).
   mkfs.xfs: Use the -f option to force overwrite.
   ```

   ```bash
   mkfs.xfs -f -L xfs-data /dev/loop1p2 >/dev/null && echo "forced OK"
   mount /dev/loop1p2 /mnt/lab/xfs
   ```

4. Change the label online — the XFS equivalent of `e2label`:

   ```bash
   xfs_admin -L xfs-prod /dev/loop1p2
   ```

   ```
   xfs_admin: /dev/loop1p2 contains a mounted filesystem
   fatal error -- couldn't initialize XFS library
   ```

   ```bash
   umount /mnt/lab/xfs
   xfs_admin -L xfs-prod /dev/loop1p2
   xfs_admin -l -u /dev/loop1p2
   ```

   ```
   writing all SBs
   new label = "xfs-prod"

   label = "xfs-prod"
   UUID = 4a91b2c7-58e0-4d33-9f21-6b0ac8e4d7f5
   ```

5. See the size constraint. Try to make an XFS filesystem on a small volume:

   ```bash
   mkfs.xfs -f /dev/loop0p1
   ```

   ```
   mkfs.xfs: Filesystem must be larger than 300MB.
   Usage: mkfs.xfs ...
   ```

   (On a 512 MiB partition it succeeds; the message above is what you get below the 300 MiB floor enforced since xfsprogs 5.19. Recent xfsprogs also refuse sizes under 16 MiB outright.)

6. Grow, and confirm you cannot shrink:

   ```bash
   mount /dev/loop1p2 /mnt/lab/xfs
   xfs_growfs -D 300000 /mnt/lab/xfs
   ```

   ```
   data size 300000 too large, maximum is 262144
   ```

   The partition is the ceiling — you enlarge the partition first, then `xfs_growfs`. There is no `xfs_shrinkfs`; shrinking requires backup, `mkfs.xfs`, restore.

**Check your understanding**

- **Q7.1** What is an allocation group, and why does XFS default to more than one?
- **Q7.2** The log is "internal" by default. What is stored in it, and what is the operational reason to place it on a separate device?
- **Q7.3** `mkfs.xfs` refused to run without `-f`. Which other `mkfs` variants have the same interlock, and which do not?
- **Q7.4** Name the two capabilities ext4 has that XFS does not, relevant to capacity planning.
- **Q7.5** `xfs_admin -L` failed on a mounted filesystem but `xfs_info` worked. What distinguishes the two?
- **Q7.6** A 1 GiB XFS shows 40 MiB used when empty; a 1 GiB ext4 shows 24 KiB. Are these comparable numbers? Explain.

---

## Exercise 8 — VFAT and exFAT

**Steps**

1. Format the EFI System Partition as FAT32. Always state `-F` explicitly rather than letting the tool guess FAT12/16/32 from size:

   ```bash
   mkfs.vfat -F 32 -n ESP /dev/loop1p1
   ```

   ```
   mkfs.fat 4.2 (2021-01-31)
   ```

   That single line is the whole output — `mkfs.vfat` is a symlink to `mkfs.fat` and is famously terse.

2. Verify what was actually written:

   ```bash
   blkid /dev/loop1p1
   fatlabel /dev/loop1p1
   ```

   ```
   /dev/loop1p1: SEC_TYPE="msdos" LABEL_FATBOOT="ESP" LABEL="ESP" UUID="3C4A-91F7" TYPE="vfat"
   ESP
   ```

   Note the `UUID` is `3C4A-91F7` — eight hex digits, not a real 128-bit UUID. FAT has no UUID field; this is the volume serial number, and it is what `UUID=` in `/etc/fstab` will match for a FAT volume.

3. Observe the label rules by breaking them:

   ```bash
   mkfs.vfat -F 32 -n "my long label" /dev/loop0p6
   ```

   ```
   mkfs.fat 4.2 (2021-01-31)
   mkfs.fat: Label can be no longer than 11 characters
   ```

   ```bash
   mkfs.vfat -F 32 -n DATOS /dev/loop0p6
   blkid /dev/loop0p6
   ```

   ```
   mkfs.fat 4.2 (2021-01-31)
   /dev/loop0p6: SEC_TYPE="msdos" LABEL_FATBOOT="DATOS" LABEL="DATOS" UUID="1B7E-4A02" TYPE="vfat"
   ```

4. Mount it and demonstrate the ownership model:

   ```bash
   mkdir -p /mnt/lab/vfat
   mount -o uid=1000,gid=1000,umask=022 /dev/loop0p6 /mnt/lab/vfat
   touch /mnt/lab/vfat/hello.txt
   ls -l /mnt/lab/vfat
   chmod 700 /mnt/lab/vfat/hello.txt
   ```

   ```
   total 0
   -rw-r--r-- 1 1000 1000 0 Aug 26 11:04 hello.txt

   chmod: changing permissions of '/mnt/lab/vfat/hello.txt': Operation not permitted
   ```

   FAT stores no owner and no mode. Everything you see comes from the mount options, uniformly for the whole filesystem.

5. Format the logical partition as exFAT:

   ```bash
   mkfs.exfat -L PORTABLE /dev/loop0p5
   ```

   ```
   exfatprogs version : 1.2.2
   Creating exFAT filesystem(/dev/loop0p5, cluster size=32768)

   Writing volume boot record: done
   Writing backup volume boot record: done
   Fat table creation: done
   Allocation bitmap creation: done
   Upcase table creation: done
   Writing root directory entry: done
   Synchronizing...

   exFAT format complete!
   ```

   ```bash
   blkid /dev/loop0p5
   ```

   ```
   /dev/loop0p5: LABEL="PORTABLE" UUID="A81C-3D0F" BLOCK_SIZE="512" TYPE="exfat"
   ```

   On older systems the package is `exfat-utils` and the command is `mkfs.exfat` from that project or `mkexfatfs`, where the label option is `-n` rather than `-L`. Check `mkfs.exfat --help` before scripting.

6. Confirm the kernel driver is present:

   ```bash
   grep -E 'exfat|vfat|msdos' /proc/filesystems
   ```

   ```
   	vfat
   	exfat
   ```

   ```bash
   mkdir -p /mnt/lab/exfat
   mount /dev/loop0p5 /mnt/lab/exfat && df -h /mnt/lab/exfat
   ```

   ```
   Filesystem      Size  Used Avail Use% Mounted on
   /dev/loop0p5    500M  128K  500M   1% /mnt/lab/exfat
   ```

**Check your understanding**

- **Q8.1** Why must an EFI System Partition be FAT (usually FAT32), rather than ext4 or XFS?
- **Q8.2** `blkid` reported `UUID="3C4A-91F7"`. Why is it only 8 hex digits, and what is the practical consequence for `/etc/fstab` and for collision risk when cloning a disk?
- **Q8.3** `chmod` failed on the mounted FAT volume. Which mount options control the permissions you *do* see, and to which files do they apply?
- **Q8.4** State the maximum single-file size on FAT32 and the reason for it. What does exFAT change?
- **Q8.5** You set MBR type `07` on the exFAT partition and `0c` on the FAT32 one. Would the filesystems still mount if you had left both as `83`? What breaks?
- **Q8.6** Why does `mkfs.vfat -F 32` on a 32 MiB partition deserve a second thought?

---

## Exercise 9 — Swap: `mkswap` and `swapon`

**Steps**

1. Format the MBR swap partition:

   ```bash
   mkswap -L labswap /dev/loop0p2
   ```

   ```
   Setting up swapspace version 1, size = 512 MiB (536866816 bytes)
   LABEL=labswap, UUID=e7d1c40b-3a58-4f92-b6ce-c0f9d2118a37
   ```

   The partition is 536870912 bytes but the usable swap is 536866816 — exactly one 4 KiB page less. That page is the swap header, holding the signature `SWAPSPACE2`, the label and the UUID.

2. Prove that `mkswap` did not activate anything:

   ```bash
   swapon --show
   ```

   ```
   NAME      TYPE       SIZE USED PRIO
   /swapfile file       2G     0B   -2
   ```

   Only the system's pre-existing swap appears. `mkswap` writes a header; `swapon` tells the kernel to use it. Two separate steps, like `mkfs` and `mount`.

3. Activate it with an explicit priority and confirm:

   ```bash
   swapon -p 10 /dev/loop0p2
   swapon --show
   cat /proc/swaps
   ```

   ```
   NAME          TYPE       SIZE USED PRIO
   /swapfile     file         2G   0B   -2
   /dev/loop0p2  partition  512M   0B   10

   Filename                 Type            Size            Used    Priority
   /swapfile                file            2097148         0       -2
   /dev/loop0p2             partition       524284          0       10
   ```

   Higher number = used first. Equal priorities on multiple devices cause the kernel to round-robin across them, which is the correct configuration for several identical disks.

4. Read and change swap metadata without re-running `mkswap`:

   ```bash
   swaplabel /dev/loop0p2
   swapoff /dev/loop0p2
   swaplabel -L fastswap /dev/loop0p2
   swaplabel /dev/loop0p2
   ```

   ```
   LABEL: labswap
   UUID:  e7d1c40b-3a58-4f92-b6ce-c0f9d2118a37

   LABEL: fastswap
   UUID:  e7d1c40b-3a58-4f92-b6ce-c0f9d2118a37
   ```

5. Build a swap *file*, and see the permission check that catches a real security mistake:

   ```bash
   dd if=/dev/zero of=/var/tmp/lpic104/swapfile bs=1M count=256 status=none
   mkswap /var/tmp/lpic104/swapfile
   ```

   ```
   mkswap: /var/tmp/lpic104/swapfile: insecure permissions 0644, fix with: chmod 0600 /var/tmp/lpic104/swapfile
   Setting up swapspace version 1, size = 256 MiB (268431360 bytes)
   no label, UUID=1f0b7c9a-5d24-4e88-b3a1-9c6e0d51fa22
   ```

   ```bash
   chmod 0600 /var/tmp/lpic104/swapfile
   swapon /var/tmp/lpic104/swapfile
   swapon --show | tail -n 1
   swapoff /var/tmp/lpic104/swapfile
   ```

   ```
   /var/tmp/lpic104/swapfile file 256M 0B  -3
   ```

   `dd` rather than `fallocate` is deliberate: a `fallocate`d file may contain holes, and swapping onto a sparse or copy-on-write file (notably on Btrfs without `chattr +C` and a properly prepared file) fails or corrupts.

6. Write the persistent entry the way it should be written — by UUID, never by device name:

   ```bash
   blkid -s UUID -o value /dev/loop0p2
   ```

   ```
   e7d1c40b-3a58-4f92-b6ce-c0f9d2118a37
   ```

   The corresponding `/etc/fstab` line would be (do **not** add it for a loop device — it will break the next boot):

   ```
   UUID=e7d1c40b-3a58-4f92-b6ce-c0f9d2118a37   none   swap   sw,pri=10   0   0
   ```

**Check your understanding**

- **Q9.1** After `mkswap`, `swapon --show` did not list the new device. Why is that correct behaviour and not a bug?
- **Q9.2** `mkswap` on a 512 MiB partition reported 536866816 bytes. Account for the missing 4096 bytes.
- **Q9.3** You have four identical SSDs and want swap spread across all of them. What priority do you assign to each, and what happens if you assign 40, 30, 20, 10 instead?
- **Q9.4** Why does `mkswap` warn about mode 0644, given that only root can call `swapon`?
- **Q9.5** In the `fstab` line above, the mount point is `none` and the dump/pass fields are `0 0`. Explain each of those three choices.
- **Q9.6** Which MBR type ID and which GPT type GUID identify a Linux swap partition, and does either one make the kernel use it as swap automatically?

---

## Exercise 10 — Awareness: Btrfs and ReiserFS

The objective requires *awareness* of these two, not mastery. Know what they are and what state they are in.

**Steps**

1. Create a Btrfs filesystem and read the defaults it announces:

   ```bash
   mkfs.btrfs -L btrfs-data /dev/loop1p4
   ```

   ```
   btrfs-progs v6.2

   NOTE: several default settings have changed in version 5.15, please make sure
         this does not affect your deployments:
         - DUP for metadata (mixed for small filesystems)
         - enabled no-holes
         - enabled free-space-tree

   Label:              btrfs-data
   UUID:               d2a7f114-6b90-4e35-8c02-71ab4f9d5e63
   Node size:          16384
   Sector size:        4096
   Filesystem size:    1.00GiB
   Block group profiles:
     Data:             single            8.00MiB
     Metadata:         DUP              51.19MiB
     System:           DUP               8.00MiB
   SSD detected:       no
   Checksum:           crc32c
   Number of devices:  1
   Devices:
      ID        SIZE  PATH
       1     1.00GiB  /dev/loop1p4
   ```

   `Metadata: DUP` means two copies of all metadata on a single device — Btrfs checksums every block and can therefore *detect* corruption and, with a second copy, repair it.

2. Mount it and look at the two different views of "free space":

   ```bash
   mkdir -p /mnt/lab/btrfs
   mount /dev/loop1p4 /mnt/lab/btrfs
   df -h /mnt/lab/btrfs
   btrfs filesystem usage /mnt/lab/btrfs
   ```

   ```
   Filesystem      Size  Used Avail Use% Mounted on
   /dev/loop1p4    1.0G  5.6M  885M   1% /mnt/lab/btrfs

   Overall:
       Device size:                   1.00GiB
       Device allocated:             130.38MiB
       Device unallocated:           893.62MiB
       Used:                         256.00KiB
       Free (estimated):             885.44MiB      (min: 438.62MiB)
   ```

   `df` on Btrfs is an estimate; the two-number "min" reflects that future metadata will be written twice.

3. Create a subvolume — a Btrfs concept with no equivalent in ext4 or XFS:

   ```bash
   btrfs subvolume create /mnt/lab/btrfs/@data
   btrfs subvolume list /mnt/lab/btrfs
   ```

   ```
   Create subvolume '/mnt/lab/btrfs/@data'
   ID 256 gen 8 top level 5 path @data
   ```

4. Check ReiserFS availability on your system:

   ```bash
   grep -c reiserfs /proc/filesystems ; modinfo reiserfs 2>&1 | head -n 3
   ```

   ```
   0
   modinfo: ERROR: Module reiserfs not found.
   ```

   On many current distributions the module is no longer built. ReiserFS (v3) was marked **deprecated** in Linux 6.6 and is scheduled for removal from the kernel; its creation tool is `mkfs.reiserfs` from `reiserfsprogs`, and its tuning tool is `reiserfstune`. For the exam, know the names and know that it is legacy. Reiser4 was never merged into the mainline kernel.

**Check your understanding**

- **Q10.1** Why does `mkfs.btrfs` default to `DUP` metadata on a single device, and what class of failure does that *not* protect against?
- **Q10.2** `df` reported 885M available on a 1 GiB Btrfs volume with 5.6M used. Why does that not add up, and why is `btrfs filesystem usage` the authoritative view?
- **Q10.3** Name one thing a Btrfs subvolume gives you that a directory on ext4 does not.
- **Q10.4** For the exam: which two tools create ReiserFS and Btrfs filesystems, and what is ReiserFS's current status in the mainline kernel?
- **Q10.5** Btrfs and XFS both support copy-on-write features. Which of the two would you choose for a database volume, and what is the CoW-related concern?

---

## Exercise 11 — Diagnostics: "the kernel does not see my new partition"

This is the single most common real-world failure in this topic, and it is the one worth being able to fix without rebooting.

**Steps**

1. Reproduce it. Make sure a partition on the MBR disk is in use, then try to change the table:

   ```bash
   mount /dev/loop0p6 /mnt/lab/vfat 2>/dev/null
   echo -e 'n\np\n' | fdisk /dev/loop0 2>&1 | tail -n 4
   ```

   A more direct reproduction with `partprobe` while a partition is mounted:

   ```bash
   partprobe /dev/loop0 ; echo "exit=$?"
   ```

   ```
   Error: Partition(s) 6 on /dev/loop0 have been written, but we have been unable
   to inform the kernel of the change, probably because it/they are in use.  As a
   result, the old partition(s) will remain in use.  You should reboot now before
   making further changes.
   exit=1
   ```

2. Understand the three levers you have:

   ```bash
   partprobe /dev/loop0        # re-read the whole table (parted)
   partx -u /dev/loop0         # update kernel's view from the on-disk table
   partx -a -n 7 /dev/loop0    # add only partition 7
   partx -d -n 7 /dev/loop0    # remove only partition 7 from the kernel view
   blockdev --rereadpt /dev/loop0
   ```

   `partprobe` and `blockdev --rereadpt` are all-or-nothing and fail when *any* partition on the device is busy. `partx` operates per partition, so it can add a brand-new partition 7 while partitions 1–6 stay mounted. That is the fix that avoids a reboot.

3. Free the device and confirm recovery:

   ```bash
   umount /mnt/lab/vfat
   partprobe /dev/loop0 ; echo "exit=$?"
   lsblk /dev/loop0
   ```

   ```
   exit=0
   ```

4. Diagnose a stale-signature problem. Write two filesystem signatures onto the same device and watch `blkid` become ambiguous:

   ```bash
   umount /mnt/lab/exfat
   mkfs.ext4 -q -F /dev/loop0p5
   wipefs /dev/loop0p5
   ```

   ```
   DEVICE OFFSET TYPE  UUID                                 LABEL
   loop0p5 0x0    exfat A81C-3D0F                            PORTABLE
   loop0p5 0x438  ext4  9a3c1e77-0b52-4d18-a6f4-2e8b70c1d539
   ```

   Two signatures, at different offsets, both intact. `mkfs.ext4` wrote its superblock at 1024 bytes without erasing the exFAT boot record at offset 0. Tools that probe by priority may now pick the wrong one, and `mount -t auto` becomes unpredictable.

5. Clean it properly:

   ```bash
   wipefs -a /dev/loop0p5
   wipefs /dev/loop0p5 ; echo "signatures left: $?"
   blkid /dev/loop0p5 ; echo "exit=$?"
   ```

   ```
   /dev/loop0p5: 2 bytes were erased at offset 0x00000438 (ext4): 53 ef
   /dev/loop0p5: 8 bytes were erased at offset 0x00000003 (exfat): 45 58 46 41 54 20 20 20
   ...
   signatures left: 0
   exit=2
   ```

   Habit worth acquiring: `wipefs -a` **before** every `mkfs` on reused media.

6. Sanity-check that a filesystem type you intend to use is actually supported by the running kernel before you commit to it in a build:

   ```bash
   cat /proc/filesystems | grep -v nodev
   ls /sbin/mkfs.* /usr/sbin/mkfs.* 2>/dev/null
   ```

   ```
   	ext3
   	ext2
   	ext4
   	vfat
   	xfs
   	btrfs
   	exfat

   /usr/sbin/mkfs.btrfs  /usr/sbin/mkfs.exfat  /usr/sbin/mkfs.ext2
   /usr/sbin/mkfs.ext3   /usr/sbin/mkfs.ext4   /usr/sbin/mkfs.fat
   /usr/sbin/mkfs.minix  /usr/sbin/mkfs.msdos  /usr/sbin/mkfs.vfat
   /usr/sbin/mkfs.xfs
   ```

   `mkfs -t <type>` is only a dispatcher: it execs `mkfs.<type>` from `$PATH`. If `mkfs.xfs` is not installed, `mkfs -t xfs` fails with "mkfs.xfs: not found", not with a kernel error.

**Check your understanding**

- **Q11.1** Why can `partx -a` succeed where `partprobe` fails, on the same device at the same moment?
- **Q11.2** `wipefs` listed an exFAT signature at offset 0x0 and an ext4 one at 0x438. Convert 0x438 to decimal and explain why ext places its superblock there.
- **Q11.3** You ran `mkfs.ext4` over an old exFAT volume and now `mount` sometimes picks the wrong type. What is the one-command fix, and what is the correct habit?
- **Q11.4** `mkfs -t xfs /dev/sdb1` returns "not found" on a minimal container image. Is the problem the kernel or userspace? How do you check each?
- **Q11.5** In which situation is a reboot genuinely the only way to make the kernel see a changed partition table?

---

## 12. Cleanup

Run this in order. Nothing here touches a real disk, but it is exactly the order you would use in production.

```bash
umount /mnt/lab/ext4 /mnt/lab/xfs /mnt/lab/vfat /mnt/lab/btrfs 2>/dev/null
swapoff /dev/loop0p2 2>/dev/null
swapoff /var/tmp/lpic104/swapfile 2>/dev/null
losetup -d /dev/loop0 /dev/loop1
losetup -a
rm -rf /var/tmp/lpic104 /mnt/lab
```

`losetup -a` must print nothing for your loop devices. If `losetup -d` reports "Device or resource busy", something is still mounted or still active as swap — find it with `lsof` / `swapon --show`, not with `--force`.

---

## Command reference for this objective

| Task | Command |
|---|---|
| MBR partitioning, interactive | `fdisk /dev/sdX` |
| GPT partitioning, interactive | `gdisk /dev/sdX` (or `fdisk` → `g`) |
| GPT partitioning, scripted | `sgdisk -n 1:0:+512M -t 1:ef00 /dev/sdX` |
| Any label, scripted | `parted -s -a optimal /dev/sdX mklabel gpt mkpart ...` |
| Dump / restore a table | `sfdisk --dump`, `sfdisk /dev/sdX < file`, `sgdisk --backup=` |
| ext2 / ext3 / ext4 | `mkfs.ext2`, `mkfs.ext3`, `mkfs.ext4` (all `mke2fs`) |
| Inspect / tune ext | `dumpe2fs -h`, `tune2fs -l`, `tune2fs -m/-L/-U/-j`, `e2label` |
| XFS | `mkfs.xfs [-f]`, `xfs_info`, `xfs_admin -L/-U`, `xfs_growfs` |
| FAT | `mkfs.vfat -F 32 -n LABEL`, `fatlabel`, `fsck.fat` |
| exFAT | `mkfs.exfat -L LABEL` (exfatprogs) |
| Btrfs | `mkfs.btrfs -L LABEL`, `btrfs filesystem show/usage` |
| ReiserFS (legacy) | `mkfs.reiserfs`, `reiserfstune` |
| Swap | `mkswap -L`, `swapon -p N`, `swapoff`, `swaplabel` |
| Identify | `lsblk -f`, `blkid`, `blkid -p`, `findmnt` |
| Refresh kernel view | `partprobe`, `partx -u/-a/-d`, `blockdev --rereadpt` |
| Erase signatures | `wipefs -a`, `sgdisk --zap-all` |

---

<details>
<summary><strong>Answers — click to expand</strong></summary>

### Exercise 1

**A1.1** It proves only that `blkid` found **no recognised filesystem, RAID or partition-table signature** in the places it probes. Exit code 2 means "nothing found". It does **not** prove the device is empty, unused, or safe to overwrite: the device may contain a proprietary format, an encrypted volume with no header signature, a filesystem whose superblock is corrupt, or perfectly good data with no magic number. "`blkid` says nothing" is never sufficient authorisation to run `mkfs`.

**A1.2** (1) The disk genuinely has no partition table, or its table is empty. (2) The kernel has not re-read the table since it changed — the partition exists on disk but no block device was created for it (fixed with `partx -u` / `partprobe`). Other valid answers: the device is used whole, without partitions (common for LVM PVs, DRBD, or a filesystem written directly to `/dev/sdb`); or, for loop devices specifically, `losetup` was called without `-P`.

**A1.3** It is a **512e** drive (4 KiB physical sectors, 512-byte logical emulation). A partition starting at sector 63 is misaligned: every logical write that does not begin on a 4096-byte boundary forces the drive into a read-modify-write cycle — read the whole 4 KiB physical sector, merge the change, write it back. Throughput on small random writes can drop by more than half. Starting at sector 2048 (1 MiB) is a multiple of 4096 bytes and of every common RAID stripe size, which is why every modern tool defaults to it.

**A1.4** Because kernel device names are assigned in **discovery order**, not by physical position. Adding a disk, changing a controller, or a slow-spinning drive can turn yesterday's `/dev/sdb` into today's `/dev/sdc`. `MODEL`, `SERIAL`, `SIZE` and `WWN` are properties of the hardware itself; `/dev/disk/by-id/` gives you stable path names built from them.

---

### Exercise 2

**A2.1** 2048 × 512 = 1 048 576 bytes = **1 MiB**. Starting at 1 MiB guarantees the partition begins on a boundary that is a multiple of 4 KiB physical sectors, of typical SSD erase-block and page sizes, and of RAID stripe sizes — one default that satisfies all of them. It also leaves room after the MBR for boot loader code (GRUB's core image on MBR-booted BIOS systems lives in that gap).

**A2.2** No — the kernel does not care. The type byte is **advisory metadata**, a hint to boot loaders, partitioning tools, installers and other operating systems about what the partition is *intended* to hold. Linux will happily put ext4 on a partition marked `82`, and `swapon` will refuse a partition marked `83` only if it lacks a swap header — the header, not the byte, is what matters. The type byte becomes functionally significant in a few cases: `05`/`0f` genuinely defines an extended partition, `ee` defines a protective MBR, and `8e` is how some tooling auto-detects LVM.

**A2.3** `00 08 00 00` little-endian is `0x00000800` = **2048**. MBR fields are stored little-endian because the format originates on x86, where the CPU is little-endian; the least significant byte comes first in memory and therefore first on disk.

**A2.4** 2³² sectors × 512 bytes = 2 199 023 255 552 bytes = **2 TiB**. The start-LBA field is also 32-bit, so a partition cannot even begin beyond 2 TiB. On a 4Kn drive (4096-byte logical sectors) the same 32-bit field addresses 2³² × 4096 = **16 TiB**, which is why some large-capacity 4Kn devices can still be MBR-partitioned — but this is fragile and unportable; GPT is the correct answer above 2 TiB.

**A2.5** `sfdisk --dump` produces a **human-readable, editable, portable text description** of the partition layout that can be replayed onto a different disk, diffed, and committed to version control. It captures the logical partition definitions of the whole extended chain too. The `dd` of sector 0 captures the **exact bytes**, including the boot loader code in the first 446 bytes and the disk identifier — which the text dump cannot fully reproduce — but it is opaque, disk-size-specific, and does *not* include the EBRs of logical partitions. Do both: they cover different failures.

---

### Exercise 3

**A3.1** Because numbers 1–4 are permanently reserved for the four MBR primary slots, whether or not they are populated. Logical partitions live in a chain inside the extended partition and are numbered from 5 upwards by convention, so `/dev/sda5` can exist when only `/dev/sda1` and `/dev/sda2` do.

**A3.2** The extended partition is defined by a type byte (`05`, or `0f` for LBA) in one of the four MBR slots, and the boot process and every partitioning tool follow exactly one chain of EBRs. There is no field anywhere in the format that distinguishes "chain A" from "chain B", and no way for a tool to know which extended partition a given logical partition belongs to. The limit is structural, not a policy the tool enforces.

**A3.3** It prevents anyone from running `mkfs` or `dd` against the extended partition's device node. The extended partition's first sector *is* the first EBR; writing a filesystem there destroys the head of the linked list and therefore makes every logical partition on the disk unreachable at once. By exposing only 1 KiB, the kernel makes the mistake fail immediately instead of silently.

**A3.4** The gap holds the **EBR** — the 512-byte extended boot record for that logical partition, containing the entry describing it and the pointer to the next EBR. Strictly it needs **one sector**. `fdisk` leaves 2048 sectors so that the logical partition itself starts on a 1 MiB boundary; alignment is worth 1 MiB of waste per logical partition.

**A3.5** Partition 6 is **renumbered to 5**. The numbering of logical partitions is positional within the chain, not stored on disk — remove a link and everything after it shifts down. Any `/etc/fstab` entry written as `/dev/sda6` now points at what used to be a different filesystem, or at nothing. This is the concrete reason `fstab` should reference `UUID=` or `LABEL=`, which follow the filesystem rather than its position.

---

### Exercise 4

**A4.1** LBA 0 is the protective MBR, LBA 1 is the primary GPT header, and LBAs 2–33 hold the partition entry array: 128 entries × 128 bytes = 16 384 bytes = 32 sectors of 512 bytes. 2 + 32 = 34, so the first sector available to a partition is **34**.

**A4.2** The disk has 8 388 608 sectors, numbered 0 to 8 388 607. The **backup** GPT header occupies the very last sector (8 388 607) and the backup partition entry array occupies the 32 sectors before it (8 388 575–8 388 606). The last usable sector is therefore **8 388 574** — one full backup array plus one header below the end, not just one sector, because GPT mirrors both structures.

**A4.3** It is the **protective MBR**: a single MBR entry of type `0xEE` spanning the whole disk (clamped to 0xFFFFFFFF sectors on disks larger than 2 TiB). A legacy, GPT-unaware tool reading sector 0 sees a disk that is entirely occupied by an unknown partition type, so it reports "no free space" and refuses to create partitions, instead of seeing an apparently blank disk and cheerfully writing a new MBR over the GPT.

**A4.4** GPT type GUIDs are globally unique and **self-describing across operating systems and architectures**, so they can encode semantics that a 1-byte namespace cannot. The Discoverable Partition Specification exploits this: a partition with the `x86-64 root` GUID (`4f68bce3-e8cd-4db1-96e7-fbcaf984b709`) can be mounted as `/` by the initramfs with no `/etc/fstab` and no kernel command line, and `/home`, `/srv`, `/var` and swap have their own GUIDs. GPT also stores a 36-character UTF-16 **name** and per-partition attribute flags, neither of which exists in MBR.

**A4.5** Only the **protective MBR** in sector 0 is gone. The primary GPT header at LBA 1, the primary partition array at LBAs 2–33, and the entire backup GPT at the end of the disk all survive — so no partition data was lost. In `gdisk`, `r` enters the recovery and transformation menu; from there `b` rebuilds the protective MBR from the GPT (and `c`/`d`/`e` handle loading or rebuilding from the backup header if the primary were also damaged). `w` writes it back. `sgdisk -e /dev/sdb` or `sgdisk --load-backup=` are the scripted equivalents.

**A4.6** **128** partitions. The number is stored in the GPT header itself, in the `NumberOfPartitionEntries` field, together with `SizeOfPartitionEntry` — so it is not a hard limit of the format; 128 is simply the near-universal default, chosen so the array occupies a convenient 16 KiB. `gdisk` reports it as "Partition table holds up to 128 entries".

---

### Exercise 5

**A5.1** It set the partition's **type GUID** to the one associated with generic Linux filesystem data, and recorded a hint in `parted`'s view. It did **not** create a filesystem, write a superblock, or make the partition mountable. You must still run `mkfs.ext4 /dev/loop1p5`. This is one of the most persistent misconceptions about `parted`: the `fs-type` argument to `mkpart` is a label, not an action. (The old `parted mkfs`/`mkpartfs` commands that *did* create filesystems were removed years ago precisely because they were unmaintained and unsafe.)

**A5.2** `MiB` is bigger: 1 MiB = 1 048 576 bytes versus 1 MB = 1 000 000 bytes, a 4.86 % difference. Compounded to tera-scale the gap is ~10 %: a "4 TB" disk (4 000 000 000 000 bytes) is 3.64 TiB. When you specify partition boundaries, always use the binary units (`MiB`, `GiB`) — they are what alignment arithmetic is expressed in, and `parted` accepts them explicitly.

**A5.3** `minimal` checks that the partition satisfies the device's *minimum* I/O granularity — enough to avoid read-modify-write on the physical sector size (`minimum_io_size`, typically the physical sector or the RAID chunk). `optimal` is stricter: it checks alignment to the device's *optimal* I/O size (`optimal_io_size`, e.g. a full RAID stripe width, or the 1 MiB default when the device reports nothing). A partition can pass `minimal` and fail `optimal`, and still work correctly — just more slowly on striped storage.

**A5.4** Because `fdisk`'s interface is a keystroke-driven menu with context-dependent prompts and defaults that vary by util-linux version, so driving it from a script means piping a fragile blob of keystrokes and hoping the prompt sequence has not changed. `parted -s` (script mode: no prompts, no interactive confirmations), `sgdisk` and `sfdisk` take the layout as **arguments or a declarative dump file**, return meaningful exit codes, and are stable across versions. `sfdisk` in particular round-trips its own `--dump` format, which makes "capture the layout, replay it on the replacement disk" a two-command operation.

**A5.5**
- `sgdisk --zap-all` destroys the **GPT structures** (both primary and backup) and the protective MBR. It does not touch filesystem superblocks inside the old partitions.
- `wipefs -a` erases **magic signatures** — filesystem superblocks, RAID superblocks, LVM labels, and partition-table signatures — at their known offsets on the device it is given. It removes what probing tools key on, precisely and with a printed record of what it erased.
- `dd if=/dev/zero bs=1M count=10` overwrites the **first 10 MiB** unconditionally, which destroys the MBR/primary GPT and typically the first filesystem's superblock, but leaves the **backup GPT at the end of the disk** intact — a classic half-wipe that leaves tools finding a phantom table. If you use `dd`, you must also zero the tail.

---

### Exercise 6

**A6.1** The partition is 512 MiB = 536 870 912 bytes. `mke2fs` uses a default of one inode per 16 384 bytes (`inode_ratio` for the `default` type in `/etc/mke2fs.conf`): 536 870 912 ÷ 16 384 = **32 768**. Change it with `-i <bytes-per-inode>` (smaller value → more inodes), with `-N <count>` to state the number directly, or with `-T <usage-type>` to select a different profile from `mke2fs.conf` (`news`, `largefile`, `largefile4`).

**A6.2** No data moved, and no existing file was rewritten. `tune2fs -j` allocated a **journal inode** and set the `has_journal` feature flag in the superblock. `blkid` reports the type by inspecting feature flags, so a filesystem with `has_journal` is reported as ext3. ext2, ext3 and ext4 are the same on-disk family distinguished by feature flags — which is also why an ext4 filesystem that uses no ext4-only features can be mounted by the ext3 driver.

**A6.3** **Inodes** fail first. With the default 16 KiB-per-inode ratio a 1 GiB volume gets 65 536 inodes, so file number 65 526 or so fails with `ENOSPC` — "No space left on device" — while `df -h` still shows most of the volume free. `df -i` reveals the real cause. It **cannot** be fixed after `mkfs`: the inode count is fixed at creation time for ext2/3/4 (`resize2fs` adds inodes only proportionally when the filesystem grows). The remedy is backup, `mkfs.ext4 -i 4096` (or `-N 500000`), restore. XFS allocates inodes dynamically and does not have this failure mode.

**A6.4** Two distinct reasons: (1) **Operational safety** — reserved blocks are writable only by root (or the UID/GID set with `tune2fs -u`/`-g`), so when a runaway log fills a shared filesystem, root can still log in, write to `/var/log`, and run recovery commands; on `/` specifically, a completely full root filesystem can prevent the system from booting. (2) **Fragmentation avoidance** — the ext block allocator degrades badly when a filesystem approaches 100 % full, because it can no longer find contiguous runs; keeping a margin preserves allocation quality. `-m 0` is reasonable on a large dedicated **data** volume that root never needs to write to and that is monitored — a 5 % reserve on a 16 TB archive volume is 800 GB of wasted capacity. `-m 0` is a bad idea on `/`, `/var`, or any filesystem where the system's own recovery depends on being able to write.

**A6.5** The `extent` feature. ext3 used **indirect block mapping**: a list of block pointers, with single, double and triple indirect blocks for larger files — so a 1 GiB file needed hundreds of thousands of pointers, and deleting it meant reading them all. An extent describes a contiguous range as `(start, length)`, so the same file may need a handful of extents. This is the main reason large-file performance and `unlink` latency improved so much in ext4.

**A6.6** By default `mke2fs` returns quickly and lets the kernel zero the inode tables and the journal lazily in the background after the filesystem is first mounted. Setting both to `0` forces `mkfs` to do that work **immediately and synchronously**. The trade-off: `mkfs` takes much longer (minutes on a multi-terabyte spinning disk), but the filesystem's performance is predictable from the first mount instead of degraded by background zeroing, and every block has been touched — useful for benchmarking and for images that will be checksummed or thin-provisioned deterministically.

**A6.7** Two free options: (1) `mke2fs -n` with **the same parameters that created the filesystem** — it computes and prints the superblock backup locations without writing anything. This is why recording the original `mkfs` options matters. (2) The defaults are predictable: with 4 KiB blocks and `sparse_super`, backups sit at the start of block groups 1, 3, 5, 7, 9, 25, 27, 49… and block groups are 32 768 blocks, giving 32768, 98304, 163840, 229376, 294912…; with 1 KiB blocks, 8193, 24577, 40961, 57345, 73729. Then `e2fsck -b 32768 -B 4096 /dev/sdXN`. Always pass `-B` (block size) with `-b`, since `e2fsck` cannot infer it from a destroyed primary superblock.

---

### Exercise 7

**A7.1** An allocation group is an independent, self-contained region of an XFS filesystem, each with its own free-space B-trees and inode B-trees. Because the metadata structures are per-AG, allocations in different AGs can proceed **in parallel without contending on a single lock**, which is the architectural reason XFS scales with core count and spindle count. The trade-off is that each AG costs metadata overhead, and cross-AG operations are more expensive; `mkfs.xfs` sizes them automatically (4 AGs on a small volume, more on a large one) via `agcount`/`agsize`.

**A7.2** The log holds the **journal**: metadata changes are written there and committed before the in-place metadata updates, so a crash leaves a replayable record rather than an inconsistent tree. XFS journals metadata only, not file data. Placing the log on a separate device (`mkfs.xfs -l logdev=/dev/nvme0n1p1`) removes the log's synchronous, small, sequential writes from the data device's head — historically a large win on rotational storage, and still useful when the log device is far faster (NVMe log in front of a slow array) or when you want log writes off a heavily contended device. The risk is that the log device becomes a single point of failure for the whole filesystem.

**A7.3** `mkfs.xfs`, `mkfs.btrfs` and `mkfs.exfat` refuse to overwrite a device that already holds a recognised filesystem unless forced (`-f`). `mke2fs` prompts interactively ("Proceed anyway? (y,N)") when the device is mounted or looks in use, and has `-F` to force — but it will format a device holding an *unmounted* old filesystem with only a warning. `mkfs.vfat` has essentially **no such interlock**: it formats what it is given. This asymmetry is exactly why `wipefs -a` first is the safe universal habit rather than trusting each tool's guard.

**A7.4** (1) **Shrinking.** ext4 can be shrunk offline with `resize2fs`; XFS cannot be shrunk at all, by any tool, online or offline. (2) **Fixed, tunable reserved space and a preallocated inode table** — ext4 lets you set `-m`, `-i`/`-N` and know your inode ceiling in advance, while XFS allocates inodes dynamically (which is usually an advantage, but means inode consumption can eat data space in ways capacity planning has to account for). A third valid answer: ext4 supports being created on and mounted from a much wider range of tiny volumes, where XFS enforces a minimum size.

**A7.5** `xfs_admin` modifies the on-disk superblock directly through the `xfs_db` library, bypassing the kernel. If the filesystem is mounted, the kernel holds its own cached copy of the superblock and will write it back, so an out-of-band change would be silently reverted or would corrupt state — hence the hard refusal. `xfs_info` only **reads** geometry, and when given a mount point it asks the *kernel* (via `ioctl`) rather than the raw device, so mounting is not merely allowed, it is required for that form. (`xfs_admin -L` on a mounted filesystem is possible on very recent xfsprogs via the online label ioctl, but the classic and exam-relevant behaviour is: unmount first.)

**A7.6** They are **not directly comparable**. XFS's ~40 MiB is mostly the internal log, which is preallocated at `mkfs` time and counted as used; ext4's journal is also preallocated (32 MiB here) but `df` accounts for it differently — ext4 excludes journal and metadata blocks from the reported total size rather than showing them as used, so its "Size" is already net of overhead. Compare **`Avail` on an empty filesystem of the same partition size**, not `Used`. In this lab both land near 960–975 MiB of usable space on a 1 GiB partition, which is the meaningful comparison.

---

### Exercise 8

**A8.1** Because the UEFI specification *requires* it: firmware must be able to read the ESP before any operating system loads, and the only filesystem every UEFI implementation is mandated to understand is FAT (FAT32, with FAT12/FAT16 also specified). The firmware contains a FAT driver in ROM; it contains no ext4 or XFS driver. The ESP is therefore FAT32 by specification, not by convention.

**A8.2** FAT has no UUID field. What `blkid` reports is the **volume serial number**, a 32-bit value in the boot sector that `mkfs.fat` derives from the current time (or from `-i`). It is 8 hex digits because it is 4 bytes. Consequences: `UUID=3C4A-91F7` in `/etc/fstab` works and is still better than `/dev/sdX`, but the collision space is 2³² instead of 2¹²⁸ — and, decisively, a **bit-for-bit clone of a disk produces two volumes with the identical serial**, so `mount UUID=...` becomes ambiguous and may pick either one. After cloning, re-stamp with `fatlabel -i` / `mkfs.fat -i`, exactly as you would re-stamp ext4 with `tune2fs -U random`.

**A8.3** `uid=`, `gid=`, `umask=`, and the finer-grained `fmask=` (files) and `dmask=` (directories); `mode=`/`dmode=` on some drivers. They apply **uniformly to every file and directory on the filesystem** — FAT stores no per-file owner or mode, so the whole volume presents one synthetic ownership and one synthetic permission mask derived from the mount options. Nothing you `chmod` or `chown` can persist, which is why the syscalls fail rather than silently doing nothing. (The `showexec` option is the one small exception: it makes the execute bit follow the `.exe`/`.com`/`.bat` extension.)

**A8.4** **4 GiB − 1 byte (4 294 967 295 bytes).** The directory entry stores a file's size in a single 32-bit field, so no larger value is representable. exFAT uses a 64-bit size field, lifting the practical limit into the exabyte range, and also removes FAT32's 65 534-entries-per-directory ceiling and its 2 TiB-ish volume limit. That single 4 GiB limit is why exFAT exists on cameras and large removable media, and why a FAT32 USB stick refuses a 5 GB video file even with 20 GB free.

**A8.5** Yes, they would still mount. Linux identifies a filesystem by **probing its superblock/boot-record signature**, not by the MBR type byte, so `mount /dev/loop0p5 /mnt` and `mount -t exfat` both work regardless of the byte. What breaks is interoperability and intent: Windows and many camera/embedded firmwares *do* consult the type byte and may ignore or offer to reformat a partition whose type does not match its content; installers and partitioning GUIs will display it wrongly; and a human reading `fdisk -l` gets a false picture of the disk. Set the type byte correctly — it costs nothing and it is documentation that travels with the disk.

**A8.6** Because FAT32 has a **minimum practical cluster count**: the FAT type is defined by the number of clusters (FAT32 requires more than 65 524), so forcing FAT32 on a small volume drives the cluster size down to 512 bytes and makes the two FAT tables themselves consume a significant fraction of the volume. On very small volumes `mkfs.fat` may refuse outright ("Attempting to create a too large filesystem" or a cluster-count error). For a 32 MiB volume, FAT12 or FAT16 is the correct choice — let `mkfs.fat` pick, or state `-F 16`.

---

### Exercise 9

**A9.1** Because `mkswap` and `swapon` are two separate operations, exactly like `mkfs` and `mount`. `mkswap` **formats**: it writes a swap header (signature `SWAPSPACE2`, version, page size, usable page count, label, UUID) into the first page of the device or file. `swapon` **activates**: it validates that header and asks the kernel to start using the area for paging. Nothing in the format step registers the device with the kernel, and that separation is deliberate — you can prepare swap on a disk long before you intend to use it.

**A9.2** The first **page** (4096 bytes on x86-64) is reserved for the swap header itself and is not available for swapping. 536 870 912 − 4096 = 536 866 816. This also means a swap area formatted on a machine with one page size may be rejected on a machine with a different one, since the header records the page size it was made with.

**A9.3** Assign all four the **same** priority (e.g. `pri=10` for each). When multiple swap areas share the highest priority, the kernel distributes pages across them round-robin, so you get roughly four times the throughput of a single device. Assigning 40/30/20/10 instead makes the kernel fill the priority-40 device completely before touching the priority-30 one, and so on — you get the capacity of four disks but the **throughput of one**, plus a pathological hotspot on the first device.

**A9.4** Because a world-readable swap area is a direct information disclosure: anything the kernel pages out — decrypted secrets, private keys, passwords held in process memory, TLS session material — lands in that file in plaintext, and mode 0644 lets **any local user read all of it** with `strings`. The warning fires whether or not the file is ever activated, because the exposure begins the moment the data is written there. `chmod 0600` (root-only) is the minimum; encrypted swap or a swap partition on an encrypted device is the stronger answer.

**A9.5**
- **Mount point `none`** (or `swap`): a swap area is never mounted into the directory tree, so there is no path to give. The field is mandatory in `fstab`'s six-column format, so a placeholder is used.
- **Dump field `0`**: the legacy `dump` backup utility should not attempt to back this up. It is meaningless for swap (and, in practice, for nearly everything today).
- **Pass field `0`**: `fsck` must not check it at boot. There is no filesystem to check, and a non-zero value would make `fsck` fail on it.

**A9.6** MBR type ID **`82`** (`Linux swap / Solaris`) and GPT type GUID **`0657FD6D-A4AB-43C4-84E5-0933C84B4F4F`** (`8200` in `gdisk`'s shorthand). **Neither causes automatic activation** on a modern Linux system. The kernel's old `swapon -a`-by-type autodetection is not how this works: activation comes from `/etc/fstab`, from a systemd `.swap` unit, or from an explicit `swapon`. The one modern exception is systemd's implementation of the Discoverable Partition Specification, which *can* activate a swap partition on the root disk purely from its GPT type GUID — worth knowing, but the type byte alone is otherwise advisory.

---

### Exercise 10

**A10.1** Because Btrfs checksums every metadata and data block, so it can **detect** corruption reliably — but detection without a second copy only lets it report an unrecoverable error. `DUP` writes two copies of all metadata at different locations on the same device, so a localised failure (a bad sector, a torn write, a single-block corruption) can be transparently repaired from the other copy, and losing metadata is what turns a recoverable filesystem into an unmountable one. It does **not** protect against whole-device failure, controller failure, or a firmware bug that corrupts both copies — DUP is not RAID, and both copies die with the disk. For device-failure protection you need `-d raid1 -m raid1` across two or more devices, or RAID beneath.

**A10.2** `df` on Btrfs reports an **estimate**, because Btrfs does not have a fixed, known mapping from free bytes to usable file bytes. Space is handed out in *block groups* (chunks) that are typed as data, metadata or system, and metadata is stored `DUP` — so every future megabyte of metadata consumes two megabytes of device space, and how much of the 893 MiB unallocated area ends up as data versus duplicated metadata is not knowable in advance. `btrfs filesystem usage` is authoritative because it shows the real accounting: device size, how much is *allocated* to block groups, how much of that is actually *used*, and a worst-case minimum estimate. This is also why "Btrfs says `ENOSPC` while `df` shows free space" is a well-known and legitimate condition — metadata block groups can be exhausted while data space remains.

**A10.3** Several valid answers: a subvolume is an **independently snapshottable unit** (`btrfs subvolume snapshot` is instant and copy-on-write); it can be **mounted separately** with its own mount options via `subvol=`; it has its own inode namespace and its own root; it can be sent and received across machines with `btrfs send`/`receive`; and it can carry its own quota group. The canonical use is the `@` / `@home` layout, which makes "roll the OS back to before that upgrade, but keep home" a single instant operation.

**A10.4** `mkfs.reiserfs` (from `reiserfsprogs`) and `mkfs.btrfs` (from `btrfs-progs`). ReiserFS v3 is **deprecated in the mainline kernel**: it was marked deprecated in Linux 6.6 with a planned removal, its module is no longer built by many distributions, and it should not be used for new filesystems. Reiser4 was never merged into mainline at all. For the exam: recognise the names, know ReiserFS predates ext4 and is legacy, know Btrfs is the actively developed CoW filesystem with snapshots, checksums, subvolumes and multi-device support.

**A10.5** **XFS** is the safer default for a database volume. Btrfs's copy-on-write behaviour interacts badly with the random in-place rewrite pattern of database files: each small write relocates a block, which fragments the file severely, inflates metadata, and degrades throughput over time — the standard mitigation is `chattr +C` on the directory before the files are created, which disables CoW for them but also disables checksums and snapshot consistency for exactly the data you most wanted protected. XFS's CoW is confined to explicit reflinks and does not apply to ordinary rewrites, so its behaviour under a database workload is predictable; it is also the default filesystem on RHEL and the one most database vendors qualify against. (The same reasoning applies to VM images and to swap files.)

---

### Exercise 11

**A11.1** `partprobe` and `blockdev --rereadpt` ask the kernel to **discard and re-read the entire partition table** for the device. The kernel cannot discard a partition that is in use — mounted, active as swap, held open by a process, or claimed by LVM/mdadm — so if any single partition is busy, the whole operation is refused and nothing changes. `partx` works **per partition**: `partx -a -n 7` tells the kernel to add just partition 7's block device, leaving partitions 1–6 and their mounts entirely untouched. Since the busy partitions are never involved, there is nothing to refuse. This is the standard way to add a partition to a live production server without rebooting.

**A11.2** 0x438 = **1080** decimal. The ext2/3/4 superblock lives at byte offset **1024** from the start of the filesystem, and the 16-bit magic number `0xEF53` sits at offset 56 within it — 1024 + 56 = 1080. The first 1024 bytes are deliberately left free for a boot sector or partition-table remnant, which is precisely why `mkfs.ext4` did not overwrite the exFAT boot record sitting at offset 0.

**A11.3** The fix is `wipefs -a /dev/loop0p5` (then re-run `mkfs`). The correct habit is to run **`wipefs -a` before every `mkfs` on reused media**, and to confirm with a bare `wipefs <device>` (which only lists) that nothing remains. Different filesystems keep their signatures at different offsets, so no single `mkfs` reliably erases all of a device's history; `wipefs` knows every offset and prints exactly what it removed.

**A11.4** It is a **userspace** problem: `mkfs` is only a dispatcher that `exec`s `mkfs.<type>` from `$PATH`, so "not found" means the `xfsprogs` package is missing. The two are checked independently: for **userspace**, `ls /sbin/mkfs.*` or `command -v mkfs.xfs`; for **kernel** support, `grep xfs /proc/filesystems` (already-loaded or built-in) and `modprobe xfs && lsmod | grep xfs` (loadable module). You can hit either failure alone — a container image commonly has the kernel support (it shares the host kernel) but not the tools, and a stripped custom kernel can have the tools but no driver.

**A11.5** When the partition you need to **change or remove** is itself in use and cannot be released — most importantly, when it is the **root filesystem** or holds active swap that cannot be swapped off. `partx -d`/`partprobe` cannot revoke a partition the kernel is actively using, and `partx -a` cannot help because the partition already exists. Growing the root partition in place is the classic case: the table change is written, but the kernel's view of `/dev/sda2` only updates at the next boot — which is why `growpart` + `resize2fs` on cloud images is normally combined with a reboot, or handled by LVM so the block-device boundary never has to move.

</details>

---

## Sources

- LPI — Exam 101-500 Objectives, topic 104.1: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- `fdisk(8)`, `sfdisk(8)`, `partx(8)`, `losetup(8)`, `blkid(8)`, `lsblk(8)`, `wipefs(8)`, `mkswap(8)`, `swapon(8)`, `swaplabel(8)`, `blockdev(8)` — util-linux: <https://www.kernel.org/pub/linux/utils/util-linux/> and <https://man7.org/linux/man-pages/>
- GPT fdisk (`gdisk`, `sgdisk`, `cgdisk`) documentation: <https://www.rodsbooks.com/gdisk/>
- GNU Parted manual: <https://www.gnu.org/software/parted/manual/parted.html>
- `mke2fs(8)`, `mke2fs.conf(5)`, `tune2fs(8)`, `dumpe2fs(8)` — e2fsprogs: <https://e2fsprogs.sourceforge.net/>
- ext4 filesystem, Linux kernel documentation: <https://docs.kernel.org/admin-guide/ext4.html>
- ext4 on-disk layout: <https://docs.kernel.org/filesystems/ext4/>
- XFS documentation and `xfsprogs`: <https://xfs.wiki.kernel.org/> and <https://docs.kernel.org/admin-guide/xfs.html>
- dosfstools (`mkfs.fat`, `fatlabel`, `fsck.fat`): <https://github.com/dosfstools/dosfstools>
- exfatprogs (`mkfs.exfat`): <https://github.com/exfatprogs/exfatprogs>
- Btrfs documentation: <https://btrfs.readthedocs.io/>
- ReiserFS deprecation, Linux kernel documentation: <https://docs.kernel.org/filesystems/index.html>
- UEFI Specification (EFI System Partition, FAT requirement): <https://uefi.org/specifications>
- Discoverable Partitions Specification (GPT type GUIDs): <https://uapi-group.org/specifications/specs/discoverable_partitions_specification/>