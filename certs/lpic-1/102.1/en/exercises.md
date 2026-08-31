# LPIC-1 · Topic 102.1 — Design hard disk layout
## Guided Exercises (Exam 101-500, version 5.0 · Weight: 3.13)

> **Scope of this lab.** You will inventory a running system's layout, then design and build three complete layouts — UEFI/GPT, BIOS/GPT, and an LVM-backed one — on a **file-backed loop device**, so nothing on your real disks is ever touched. Every destructive command in this document targets `/dev/loopN` only. Read every `wipefs`, `sgdisk`, `mkfs` and `dd` line before pressing Enter and confirm the target device name in the same breath.

**Prerequisites**

- A Linux system with `root` (or `sudo`) access.
- Packages: `util-linux` (`lsblk`, `losetup`, `blkid`, `findmnt`, `wipefs`, `mkswap`, `swapon`), `gdisk`/`sgdisk`, `parted`, `dosfstools` (`mkfs.vfat`), `e2fsprogs`, `lvm2`.
- At least **2 GiB** of genuinely free space on the filesystem holding `/var/tmp` (the image is sparse, but LVM and filesystem metadata will make it grow).

**Reference sources used throughout**

- LPI Exam 101 objectives — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- `fstab(5)` — <https://man7.org/linux/man-pages/man5/fstab.5.html>
- `mkswap(8)` / `swapon(8)` — <https://man7.org/linux/man-pages/man8/mkswap.8.html>
- GNU GRUB manual (BIOS boot partition, LVM/LUKS support) — <https://www.gnu.org/software/grub/manual/grub/grub.html>
- UEFI Specification (EFI System Partition) — <https://uefi.org/specifications>
- Discoverable Partitions Specification (partition type GUIDs) — <https://uapi-group.org/specifications/specs/discoverable_partitions_specification/>
- Red Hat Enterprise Linux 9 — *Managing storage devices*, swap recommendations — <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_storage_devices/index>
- Debian Installation Guide — *Recommended partitioning scheme* — <https://www.debian.org/releases/stable/amd64/apcs03.en.html>
- `lvm(8)` and LVM2 project — <https://man7.org/linux/man-pages/man8/lvm.8.html>, <https://sourceware.org/lvm2/>

---

## Exercise 1 — Read the layout you already have

A design starts by measuring what exists. Before you propose sizes, you must be able to state, for the system in front of you, what is a disk, what is a partition, what is a logical volume, and where each one is mounted.

1. Print the block device tree with the attributes that matter for design:

   ```bash
   lsblk -o NAME,TYPE,SIZE,FSTYPE,FSUSE%,MOUNTPOINTS
   ```

   Representative output (yours will differ):

   ```
   NAME          TYPE  SIZE FSTYPE      FSUSE% MOUNTPOINTS
   nvme0n1       disk  476G
   ├─nvme0n1p1   part  600M vfat            4% /boot/efi
   ├─nvme0n1p2   part    1G ext4           38% /boot
   └─nvme0n1p3   part  474G LVM2_member
     ├─vg0-root  lvm    30G ext4           61% /
     ├─vg0-var   lvm    40G ext4           22% /var
     ├─vg0-home  lvm   200G ext4           47% /home
     └─vg0-swap  lvm    16G swap             [SWAP]
   ```

2. Distinguish real filesystems from kernel/virtual ones, which never get a partition:

   ```bash
   findmnt --real --output TARGET,SOURCE,FSTYPE,OPTIONS
   ```

3. Look at the same picture from the filesystem side, including inode pressure:

   ```bash
   df -hT -x tmpfs -x devtmpfs
   df -i  -x tmpfs -x devtmpfs
   ```

4. Read the partition table itself, not the mounted result. Replace `/dev/nvme0n1` with your own disk (this is read-only — `-l` only lists):

   ```bash
   sudo fdisk -l /dev/nvme0n1
   sudo gdisk -l /dev/nvme0n1     # shows GPT type codes and partition GUIDs
   sudo parted /dev/nvme0n1 unit MiB print
   ```

5. Collect the identifiers you would actually put in `/etc/fstab`:

   ```bash
   sudo blkid
   lsblk -o NAME,UUID,PARTUUID,PARTLABEL,LABEL
   ```

6. Inspect swap and memory:

   ```bash
   swapon --show
   free -h
   cat /proc/swaps
   ```

7. Determine whether the machine booted through UEFI or legacy BIOS. This single fact decides the whole boot end of your design:

   ```bash
   [ -d /sys/firmware/efi ] && echo "UEFI boot" || echo "BIOS/CSM boot"
   sudo efibootmgr -v 2>/dev/null | head
   ```

8. Measure where the space actually goes, so your `/var` and `/home` sizes are evidence-based rather than folklore. `-x` keeps `du` on one filesystem:

   ```bash
   sudo du -x -h -d1 /var  | sort -h | tail -n 10
   sudo du -x -h -d1 /home | sort -h | tail -n 10
   sudo journalctl --disk-usage
   ```

**Check your understanding**

- **Q1.** In the `lsblk` output above, which line is a *partition*, which is a *logical volume*, and which is the *physical volume* that holds the LVM data? How does the `TYPE` column tell you?
- **Q2.** `df -hT` reports 40% used on `/home`, but writes fail with `No space left on device`. `df -i` shows `IUse% 100`. Explain the failure and say which design decision (made at partitioning time) caused it.
- **Q3.** Why does `findmnt --real` omit `/proc`, `/sys`, `/run` and `/dev/shm`, and why does that matter when you are sizing partitions?
- **Q4.** You ran `du -h -d1 /var` **without** `-x` and the number was far larger than `df` reports for the `/var` filesystem. What happened?
- **Q5.** Which command in this block tells you whether the machine needs an EFI System Partition, and why can you not answer that question from `lsblk` alone?

---

## Exercise 2 — Build a disposable disk

You need a block device you are allowed to destroy. A sparse file attached to a loop device behaves like a real disk for partitioning, filesystems, LVM and `fstab` purposes.

1. Create an 8 GiB sparse image outside of `tmpfs` (`/tmp` is RAM on most modern distros — check before using it):

   ```bash
   findmnt -no FSTYPE /var/tmp        # must NOT be tmpfs
   df -h /var/tmp
   sudo truncate -s 8G /var/tmp/lab-disk.img
   ls -lh /var/tmp/lab-disk.img       # apparent size 8.0G
   du -h  /var/tmp/lab-disk.img       # actual size 0 — it is sparse
   ```

2. Attach it to a loop device with partition scanning enabled:

   ```bash
   LOOP=$(sudo losetup --find --show --partscan /var/tmp/lab-disk.img)
   echo "$LOOP"        # e.g. /dev/loop0
   ```

3. Confirm the kernel sees a block device with a sensible geometry:

   ```bash
   lsblk "$LOOP"
   sudo blockdev --getsize64 "$LOOP"   # 8589934592
   cat /sys/block/$(basename "$LOOP")/queue/logical_block_size    # 512
   cat /sys/block/$(basename "$LOOP")/queue/physical_block_size   # 512
   ```

4. Keep the variable for the rest of the lab. If you open a new shell, re-derive it instead of guessing:

   ```bash
   LOOP=$(losetup -j /var/tmp/lab-disk.img | cut -d: -f1)
   echo "$LOOP"
   ```

**Check your understanding**

- **Q6.** What does `--partscan` do, and what symptom would you see without it after creating partitions on the image?
- **Q7.** `ls -lh` says 8.0G and `du -h` says 0. Explain, and state the risk of running a production filesystem on a sparse backing file.
- **Q8.** Why is `/tmp` a poor location for this image on a systemd distribution?

---

## Exercise 3 — A UEFI/GPT layout: ESP, `/boot`, and an LVM physical volume

This is the modern default. The objective phrase *"ensure the /boot partition conforms to the hardware architecture requirements for booting"* means, on UEFI x86-64: a GPT table, a FAT32 EFI System Partition the firmware can read, and a kernel/initramfs location the bootloader can read.

1. Wipe any stale signatures, then write a fresh GPT with three partitions:

   ```bash
   sudo wipefs -a "$LOOP"
   sudo sgdisk --zap-all "$LOOP"

   sudo sgdisk \
     -n 1:1MiB:+512MiB -t 1:ef00 -c 1:"EFI System Partition" \
     -n 2:0:+1GiB      -t 2:8300 -c 2:"boot" \
     -n 3:0:0          -t 3:8e00 -c 3:"lvm-pv" \
     "$LOOP"
   sudo partprobe "$LOOP"
   ```

2. Verify the type codes and the alignment. Every start must land on a 1 MiB boundary (sector 2048 with 512-byte sectors):

   ```bash
   sudo sgdisk -p "$LOOP"
   sudo parted "$LOOP" unit s print
   sudo parted "$LOOP" align-check optimal 1
   sudo parted "$LOOP" align-check optimal 3
   ```

   Representative `sgdisk -p` output:

   ```
   Number  Start (sector)    End (sector)  Size       Code  Name
      1            2048         1050623   512.0 MiB   EF00  EFI System Partition
      2         1050624         3147775   1024.0 MiB  8300  boot
      3         3147776        16775134   6.5 GiB     8E00  lvm-pv
   ```

3. Read the actual type GUIDs behind those shorthand codes:

   ```bash
   sudo sgdisk -i 1 "$LOOP"    # C12A7328-F81F-11D2-BA4B-00A0C93EC93B  (ESP)
   sudo sgdisk -i 3 "$LOOP"    # E6D6D379-F507-44C2-A23C-238F2A3DF928  (Linux LVM)
   ```

4. Create the boot-side filesystems. The ESP **must** be FAT — the UEFI firmware implements FAT and nothing else by specification:

   ```bash
   sudo mkfs.vfat -F 32 -n EFI  "${LOOP}p1"
   sudo mkfs.ext4 -L boot       "${LOOP}p2"
   sudo blkid "${LOOP}p1" "${LOOP}p2"
   ```

5. Record the identifiers you will need later:

   ```bash
   ESP_UUID=$(sudo blkid -s UUID -o value "${LOOP}p1")
   BOOT_UUID=$(sudo blkid -s UUID -o value "${LOOP}p2")
   echo "ESP=$ESP_UUID BOOT=$BOOT_UUID"
   ```

   Note the ESP UUID has the short `XXXX-XXXX` form: FAT has no real UUID, only a 32-bit volume serial number.

**Check your understanding**

- **Q9.** Why can the ESP not be `ext4`, and why can it not be an LVM logical volume?
- **Q10.** What exactly does the `ef00` type code mean to (a) `sgdisk`, (b) the UEFI firmware, and (c) the Linux kernel? Which of those three actually enforces it?
- **Q11.** In step 1, partition 3 is `8e00` (Linux LVM) rather than `8300` (Linux filesystem). Does the kernel refuse to build a PV if you get this wrong? What is the type code *for*, then?
- **Q12.** The ESP is 512 MiB and `/boot` is 1 GiB. Justify both numbers in terms of what is stored in each, and name one distribution behaviour that makes a 200 MiB `/boot` fail months after installation.
- **Q13.** Explain what `parted align-check optimal 1` verifies and why a misaligned start sector degrades performance on SSDs and on 4Kn / 512e drives.

---

## Exercise 4 — The BIOS/GPT case: the BIOS boot partition

If firmware is legacy BIOS but the table is GPT, GRUB has nowhere to put `core.img`: there is no post-MBR gap it can rely on, because GPT's primary header and entry array occupy it. The answer is a small, **unformatted**, `ef02` partition. This is the classic exam trap.

Do this on a second, throwaway image so the layout from Exercise 3 survives.

1. Create and attach a second image:

   ```bash
   sudo truncate -s 2G /var/tmp/lab-bios.img
   LOOPB=$(sudo losetup --find --show --partscan /var/tmp/lab-bios.img)
   echo "$LOOPB"
   ```

2. Build a BIOS-bootable GPT layout:

   ```bash
   sudo sgdisk --zap-all "$LOOPB"
   sudo sgdisk \
     -n 1:1MiB:+2MiB -t 1:ef02 -c 1:"BIOS boot" \
     -n 2:0:+512MiB  -t 2:8300 -c 2:"boot" \
     -n 3:0:0        -t 3:8300 -c 3:"root" \
     "$LOOPB"
   sudo partprobe "$LOOPB"
   sudo sgdisk -p "$LOOPB"
   sudo sgdisk -i 1 "$LOOPB"     # 21686148-6449-6E6F-744E-656564454649
   ```

3. Prove that partition 1 carries no filesystem, and must not:

   ```bash
   sudo blkid "${LOOPB}p1"       # no output, exit status 2
   sudo wipefs "${LOOPB}p1"      # no signatures
   ```

4. For contrast, build the same idea on an **MBR (msdos)** table, where the type IDs are one byte, not a GUID:

   ```bash
   sudo sgdisk --zap-all "$LOOPB"
   sudo parted -s "$LOOPB" mklabel msdos \
     mkpart primary ext4 1MiB 513MiB \
     mkpart primary ext4 513MiB 1537MiB \
     mkpart primary linux-swap 1537MiB 100%
   sudo parted -s "$LOOPB" set 1 boot on
   sudo fdisk -l "$LOOPB"
   ```

   Then change the third partition's type to swap (`82`) non-interactively:

   ```bash
   echo -e 't\n3\n82\nw\n' | sudo fdisk "$LOOPB"
   sudo fdisk -l "$LOOPB" | tail -n 5
   ```

5. Note the MBR limits you have just been living inside:

   ```bash
   sudo parted "$LOOPB" print | head -n 8
   ```

   Four primary entries; a fifth partition requires converting one to *extended* and nesting *logical* partitions inside it, which the kernel numbers from 5 upwards regardless of how many primaries exist.

**Check your understanding**

- **Q14.** Why does GRUB need the `ef02` partition on BIOS+GPT but not on BIOS+MBR? Where does `core.img` live in each case?
- **Q15.** What is the *worst* thing you can do to an `ef02` partition, and what symptom does it produce?
- **Q16.** On MBR you create partitions 1, 2 and 3 as primary and then need two more filesystems. Describe precisely what you must do and what device names the new filesystems will get.
- **Q17.** Give the maximum addressable disk size of an MBR table with 512-byte sectors, and show the arithmetic.
- **Q18.** A machine boots in UEFI mode from a disk that also has an `ef02` partition. Is the `ef02` partition used? Is it harmful? Justify.

---

## Exercise 5 — LVM: separating *layout* from *partitioning*

The objective requires "knowledge of basic features of LVM". The point of LVM in a *design* discussion is that it postpones the sizing decision: partitions are fixed at install time, logical volumes are not.

Work on the UEFI image from Exercise 3 (`$LOOP`), partition 3.

1. Create the physical volume and inspect its metadata:

   ```bash
   sudo pvcreate "${LOOP}p3"
   sudo pvs
   sudo pvdisplay "${LOOP}p3"
   ```

   > **If `pvs` does not list it:** distributions using the LVM devices file (RHEL 9+, recent Fedora) restrict which devices LVM will touch. Check with `sudo lvmdevices` and, if needed, `sudo lvmdevices --adddev "${LOOP}p3"`.

2. Create the volume group and read its extent size:

   ```bash
   sudo vgcreate vg_lab "${LOOP}p3"
   sudo vgs -o vg_name,pv_count,vg_size,vg_free,vg_extent_size
   sudo vgdisplay vg_lab | grep -E 'PE Size|Total PE|Free  PE'
   ```

   The default Physical Extent (PE) size is 4 MiB; every LV size is rounded **up** to a whole number of extents.

3. Carve the logical volumes, deliberately leaving free space in the VG:

   ```bash
   sudo lvcreate -L 2G  -n lv_root vg_lab
   sudo lvcreate -L 1G  -n lv_var  vg_lab
   sudo lvcreate -L 1G  -n lv_home vg_lab
   sudo lvcreate -L 512M -n lv_swap vg_lab
   sudo lvs -o lv_name,lv_size,vg_name,lv_path
   sudo vgs -o vg_name,vg_size,vg_free
   ```

4. Put filesystems and swap on them:

   ```bash
   sudo mkfs.ext4 -L root /dev/vg_lab/lv_root
   sudo mkfs.ext4 -L var  /dev/vg_lab/lv_var
   sudo mkfs.ext4 -L home /dev/vg_lab/lv_home
   sudo mkswap   -L swap /dev/vg_lab/lv_swap
   lsblk "$LOOP"
   ```

5. Perform the operation that justifies LVM's existence — grow a *mounted* filesystem:

   ```bash
   sudo mkdir -p /mnt/lab && sudo mount /dev/vg_lab/lv_var /mnt/lab
   df -hT /mnt/lab

   sudo lvextend -L +512M -r /dev/vg_lab/lv_var
   df -hT /mnt/lab          # grew, still mounted, no reboot
   ```

   `-r` (`--resizefs`) calls `resize2fs` for you. Without it you must run `sudo resize2fs /dev/vg_lab/lv_var` as a second step.

6. Take a snapshot, observe that it consumes VG space, then discard it:

   ```bash
   sudo lvcreate -s -L 256M -n snap_var /dev/vg_lab/lv_var
   sudo lvs -o lv_name,lv_attr,lv_size,origin,data_percent vg_lab
   sudo vgs -o vg_name,vg_free
   sudo lvremove -y /dev/vg_lab/snap_var
   ```

7. Unmount before continuing:

   ```bash
   sudo umount /mnt/lab
   ```

**Check your understanding**

- **Q19.** Name the three LVM layers in order and give the command that creates each one.
- **Q20.** You request `lvcreate -L 1000M`. `lvs` reports `1000.00m`, but on another VG the same request reports a different number. Explain the mechanism and the property that controls it.
- **Q21.** Why did the exercise deliberately leave free space in `vg_lab` rather than using `-l 100%FREE`? Give two distinct operations that free space makes possible.
- **Q22.** You extended `lv_var` and `df` still shows the old size. What did you forget, and what is the equivalent command for XFS?
- **Q23.** Can `/boot` live on a logical volume? Answer for GRUB2 specifically, and explain why installers keep `/boot` on a plain partition anyway.
- **Q24.** A snapshot of a 100 GiB volume is created with `-L 1G`. The origin then receives 3 GiB of writes. What happens to the snapshot, and what does `lv_attr` show?

---

## Exercise 6 — Swap: size, placement, priority

1. Compute what the classic guidance would recommend for **this** machine. Determine RAM first:

   ```bash
   free -h
   awk '/MemTotal/ {printf "%.1f GiB\n", $2/1024/1024}' /proc/meminfo
   ```

   The Red Hat recommendation (RHEL 9, *Managing storage devices*) is:

   | RAM | Swap (no hibernation) | Swap (hibernation) |
   |---|---|---|
   | ≤ 2 GiB | 2 × RAM | 3 × RAM |
   | > 2 – 8 GiB | = RAM | 2 × RAM |
   | > 8 – 64 GiB | ≥ 4 GiB | 1.5 × RAM |
   | > 64 GiB | ≥ 4 GiB | not recommended |

2. Activate the swap **logical volume** from Exercise 5, briefly, and observe priority:

   ```bash
   sudo swapon --priority 10 /dev/vg_lab/lv_swap
   swapon --show
   cat /proc/swaps
   ```

   Representative output:

   ```
   NAME                 TYPE      SIZE USED PRIO
   /dev/dm-3            partition 512M   0B   10
   ```

   > **Lab-only caution.** This swap area is ultimately backed by a file on another filesystem via a loop device. Swapping into a loop device on the same host can deadlock under real memory pressure. Verify it, then turn it off. Never do this on a production machine.

   ```bash
   sudo swapoff /dev/vg_lab/lv_swap
   ```

3. Build a swap **file** and compare. Note the mandatory permissions:

   ```bash
   sudo fallocate -l 256M /var/tmp/swapfile
   sudo chmod 600 /var/tmp/swapfile
   sudo mkswap /var/tmp/swapfile
   sudo swapon --priority 5 /var/tmp/swapfile
   swapon --show
   ```

   On **Btrfs**, `fallocate` alone is not enough — the file must be created with `btrfs filesystem mkswapfile`, or be `chattr +C` (nodatacow) and uncompressed, or `swapon` fails with `Invalid argument`.

4. Read the header a swap area actually carries:

   ```bash
   sudo blkid /var/tmp/swapfile
   sudo file /var/tmp/swapfile
   ```

5. Deactivate and remove:

   ```bash
   sudo swapoff /var/tmp/swapfile
   sudo rm -f /var/tmp/swapfile
   swapon --show
   ```

6. Inspect the kernel knob that decides *how eagerly* anonymous pages are swapped — a tuning parameter, not a sizing one:

   ```bash
   cat /proc/sys/vm/swappiness
   ```

**Check your understanding**

- **Q25.** A server has 128 GiB of RAM and runs a JVM workload with hibernation disabled. Does it need 128 GiB of swap? State a defensible size and justify it.
- **Q26.** Why must a swap file be mode `0600`, and what does `mkswap` refuse to do if it is not?
- **Q27.** Two swap areas exist, one on NVMe with `pri=10` and one on a SATA HDD with `pri=1`. Describe the kernel's allocation behaviour. What changes if both have `pri=10`?
- **Q28.** A laptop must hibernate. State the two independent requirements the swap area must satisfy, beyond mere existence.
- **Q29.** Setting `vm.swappiness=0` — does it disable swapping? What is the practical effect under memory pressure?
- **Q30.** Give one design advantage of a swap partition over a swap file, and one of a swap file over a swap partition.

---

## Exercise 7 — Tailor the design to the intended use

This is the objective's second bullet and the part an exam question is most likely to hide inside a scenario. Separate filesystems buy you four things: **fill isolation**, **distinct mount options**, **independent snapshot/backup granularity**, and **separate `fsck`/resize scope**. They cost you **stranded free space**.

1. Reason about a concrete case. A mail relay writes to `/var/spool` and `/var/log`; an unrelenting spam wave fills the disk. Simulate the failure mode with a quota-free filesystem — fill the small `lv_var` and observe:

   ```bash
   sudo mount /dev/vg_lab/lv_var /mnt/lab
   sudo dd if=/dev/zero of=/mnt/lab/fill bs=1M count=2000 status=none || true
   df -hT /mnt/lab
   sudo touch /mnt/lab/another          # No space left on device
   ```

   Now prove the isolation: the root filesystem of your real machine is untouched.

   ```bash
   df -hT /
   sudo rm -f /mnt/lab/fill && sudo umount /mnt/lab
   ```

2. Write down a layout for each of the following roles, using the LVM VG you built. For each, state size, filesystem and mount options. Use this as your template:

   | Mount point | Size | FS | Options | Reason |
   |---|---|---|---|---|
   | `/boot/efi` | 512 MiB | vfat | `umask=0077,shortname=winnt` | firmware-readable |
   | `/boot` | 1 GiB | ext4 | `defaults` | kernels + initramfs |
   | `/` | 20 GiB | ext4 | `defaults` | OS + packages |
   | `/var` | ? | ext4 | `nosuid,nodev` | logs, spool, container images |
   | `/home` | ? | ext4 | `nosuid,nodev` | user data, quota target |
   | `/tmp` | ? | ext4/tmpfs | `nosuid,nodev,noexec` | untrusted scratch |
   | `/srv` | ? | xfs | `nosuid,nodev` | served data |
   | swap | ? | swap | `sw` | see Exercise 6 |

   Roles to design:

   - **(a)** Web server, 16 GiB RAM, 500 GiB disk, serves static content from `/srv/www`, no hibernation.
   - **(b)** Multi-user shell/build host, 200 users, 64 GiB RAM, 4 TiB disk.
   - **(c)** Container host running `containerd` (image store under `/var/lib/containerd`), 32 GiB RAM.
   - **(d)** Minimal appliance/VM, 2 GiB RAM, 20 GiB disk, unattended, remotely managed.

3. Verify which mount options your current system already applies, and see what a hardened `/tmp` looks like:

   ```bash
   findmnt --real -o TARGET,FSTYPE,OPTIONS
   findmnt /tmp
   ```

4. Test that `noexec` does what the design claims. Mount `lv_home` with hardened options:

   ```bash
   sudo mount -o nosuid,nodev,noexec /dev/vg_lab/lv_home /mnt/lab
   printf '#!/bin/sh\necho ran\n' | sudo tee /mnt/lab/t.sh >/dev/null
   sudo chmod +x /mnt/lab/t.sh
   /mnt/lab/t.sh                 # Permission denied
   sh /mnt/lab/t.sh              # ran   <-- the interpreter bypasses noexec
   sudo umount /mnt/lab
   ```

**Check your understanding**

- **Q31.** State the single strongest argument for a separate `/var`, and the single strongest argument against splitting a small VM into six filesystems.
- **Q32.** For role (b), which filesystem gets the most space and which mechanism — not visible in the partition table — must be enabled to keep one user from consuming it all?
- **Q33.** The `noexec` demo above was defeated by `sh /mnt/lab/t.sh`. Does that make `noexec` worthless? What class of attack does it still block?
- **Q34.** `/tmp` as `tmpfs` versus `/tmp` as a logical volume: give one scenario where each is the wrong choice.
- **Q35.** For role (c), where do container images actually consume space, and what would you change about the default layout to prevent an image pull from taking down `journald` and `sshd` logging?
- **Q36.** Explain "stranded free space" with a numeric example on a 500 GiB disk, and say how LVM reduces (but does not eliminate) the problem.

---

## Exercise 8 — Express the design as `/etc/fstab`

A layout that is not written into `/etc/fstab` correctly does not survive a reboot — and a wrong `fstab` is one of the few ways to leave a system unbootable at the emergency prompt.

1. Collect every identifier from the LVM layout:

   ```bash
   sudo blkid "${LOOP}p1" "${LOOP}p2" /dev/vg_lab/lv_root /dev/vg_lab/lv_var \
              /dev/vg_lab/lv_home /dev/vg_lab/lv_swap
   ```

2. Write the design to a **scratch file**, not to the real `/etc/fstab`:

   ```bash
   sudo tee /var/tmp/fstab.lab >/dev/null <<EOF
   # <device>                        <mount point>  <type>  <options>                 <dump> <pass>
   /dev/mapper/vg_lab-lv_root        /              ext4    defaults                  0      1
   UUID=$(sudo blkid -s UUID -o value "${LOOP}p2")  /boot          ext4    defaults                  0      2
   UUID=$(sudo blkid -s UUID -o value "${LOOP}p1")  /boot/efi      vfat    umask=0077,shortname=winnt 0     2
   /dev/mapper/vg_lab-lv_var         /var           ext4    defaults,nosuid,nodev     0      2
   /dev/mapper/vg_lab-lv_home        /home          ext4    defaults,nosuid,nodev     0      2
   /dev/mapper/vg_lab-lv_swap        none           swap    sw                        0      0
   EOF
   cat /var/tmp/fstab.lab
   ```

3. Study the six fields, in order: device, mount point, type, options, `dump`, `pass`. Note that `pass` is `1` for root, `2` for the other real filesystems, and `0` for swap and for anything that must not be checked.

4. Validate the syntax and mount a single entry from the scratch file without touching the real one:

   ```bash
   sudo findmnt --verify --fstab /var/tmp/fstab.lab
   sudo mkdir -p /mnt/lab
   sudo mount -o nosuid,nodev /dev/mapper/vg_lab-lv_var /mnt/lab
   findmnt /mnt/lab -o TARGET,SOURCE,FSTYPE,OPTIONS
   sudo umount /mnt/lab
   ```

5. Learn the two options that make an entry non-fatal. `nofail` lets boot continue when the device is absent; `x-systemd.device-timeout=` bounds the wait:

   ```bash
   man 5 fstab | sed -n '/nofail/,+6p'
   man 5 systemd.mount | grep -n 'x-systemd.device-timeout' | head -n 3
   ```

6. Recall the rule for editing a *real* `fstab`: after any change, run `sudo mount -a` **and** `sudo systemctl daemon-reload` before rebooting. If `mount -a` errors, the reboot would have dropped you into emergency mode.

**Check your understanding**

- **Q37.** Name the six `fstab` fields in order and give the correct `pass` value for `/`, for `/home`, and for a swap entry.
- **Q38.** Why is `UUID=` preferred over `/dev/sda2`, and why is `/dev/mapper/vg_lab-lv_root` nevertheless acceptable for a logical volume?
- **Q39.** Which of these commands would have caught a typo in a device path *before* the reboot: `mount -a`, `findmnt --verify`, `blkid`, `systemctl daemon-reload`? Explain what each one checks.
- **Q40.** An external USB backup disk is in `fstab`. The machine hangs at boot when it is unplugged. Which two options fix this, and what does each one do?
- **Q41.** An entry for `/boot/efi` has `pass 1`. What is the consequence, and what should it be instead?

---

## Exercise 9 — Tear down

Leave the machine exactly as you found it. Order matters: unmount, deactivate swap, remove LVM top-down, detach loops, delete images.

```bash
# 1. Nothing from the lab may still be mounted or swapped on
mount | grep -E '/mnt/lab' || true
sudo umount /mnt/lab 2>/dev/null || true
sudo swapoff /dev/vg_lab/lv_swap 2>/dev/null || true
swapon --show

# 2. LVM, from the top down
sudo vgchange -an vg_lab
sudo vgremove -f vg_lab
sudo pvremove -ff -y "${LOOP}p3" 2>/dev/null || true
sudo pvs; sudo vgs; sudo lvs

# 3. Detach the loop devices
sudo losetup -d "$LOOP"
sudo losetup -d "$LOOPB"
losetup -a

# 4. Remove the images
sudo rm -f /var/tmp/lab-disk.img /var/tmp/lab-bios.img /var/tmp/fstab.lab
sudo rmdir /mnt/lab
```

**Check your understanding**

- **Q42.** Why must `vgremove` precede `losetup -d`, and what state does the system end up in if you detach the loop device first?
- **Q43.** `losetup -d` returns `Device or resource busy`. Give two causes and the command that identifies the holder.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**A1.** The `TYPE` column names each layer explicitly. `nvme0n1p1/p2/p3` are `part` — partitions of the `disk` `nvme0n1`. `vg0-root`, `vg0-var`, `vg0-home`, `vg0-swap` are `lvm` — device-mapper logical volumes. The physical volume is `nvme0n1p3`: it is a partition whose `FSTYPE` is `LVM2_member`, meaning it carries an LVM label and metadata instead of a filesystem. `lsblk` nests the LVs under it because device-mapper reports that dependency.

**A2.** The filesystem has run out of **inodes**, not blocks. An inode is allocated per file (and per directory, symlink, device node), and ext2/3/4 fix the inode count at `mkfs` time from the `bytes-per-inode` ratio (default 16 KiB). Millions of tiny files — a mail spool, a cache, a build tree — exhaust inodes long before blocks. The design decision that caused it: accepting the default `mkfs.ext4` ratio on a filesystem intended for small files, instead of `mkfs.ext4 -i 4096` or `-T small`. It cannot be fixed after the fact on ext4 without recreating the filesystem, which is why it belongs in the *design* phase. XFS allocates inodes dynamically and does not have this failure mode.

**A3.** `--real` filters out pseudo-filesystems: `proc`, `sysfs`, `devtmpfs`, `tmpfs`, `cgroup2`, `securityfs`, and so on. They are kernel interfaces or RAM-backed, so they consume no persistent block storage. It matters because `df -h` without exclusions reports a dozen `tmpfs` lines whose "sizes" are RAM limits, not disk. Counting them when sizing partitions leads to designing for capacity that does not exist on the disk — and, conversely, forgetting that a `tmpfs` `/tmp` consumes RAM (and swap), not the disk you were budgeting.

**A4.** Without `-x` (`--one-file-system`), `du` descends across mount points. If `/var/lib/containers`, `/var/log/journal` or a bind mount lives on a *different* filesystem, `du` added it to the `/var` total even though `df` attributes it elsewhere. Always use `du -x` when the goal is to size the filesystem you are standing on.

**A5.** `[ -d /sys/firmware/efi ]`. The kernel only creates `/sys/firmware/efi` when it was booted by UEFI firmware and has EFI runtime services available; on legacy BIOS/CSM boot the directory does not exist. `lsblk` cannot answer this because a disk may perfectly well carry an ESP-typed partition and still be booted through the CSM in BIOS mode — the partition table describes the disk, not the firmware that booted it. `efibootmgr` failing with *"EFI variables are not supported on this system"* is a corroborating signal.

### Exercise 2

**A6.** `--partscan` (`-P`) tells the kernel to read the partition table on the backing file and create the corresponding `/dev/loopNpM` device nodes. Without it you get only `/dev/loop0`; `sgdisk` will still write a valid table into the file, but `/dev/loop0p1` never appears, so `mkfs` and `pvcreate` have no device to target. The recovery without re-attaching is `sudo partprobe /dev/loop0` or `sudo kpartx -a /dev/loop0`.

**A7.** `ls` reports the file's *apparent* size — the logical length recorded in the inode. `du` reports the blocks actually allocated. A sparse file has holes: ranges that have never been written consume no blocks and read back as zeros. The production risk is that the backing filesystem can run out of space *while a write to an already-"allocated" region is in flight*. The guest filesystem believes it has space, the host cannot provide a block, and the result is an I/O error mid-write — a far worse failure than a clean `ENOSPC`, because it can corrupt filesystem metadata. This is exactly the thin-provisioning overcommit hazard, and it is why LVM thin pools need monitoring on `data_percent`.

**A8.** On systemd-based distributions `/tmp` is commonly `tmpfs` — RAM-backed, sized by default at 50% of physical memory. Writing an 8 GiB image there would consume RAM and then swap, potentially triggering the OOM killer. `/tmp` is also cleaned by `systemd-tmpfiles` on a timer and on boot, so the image could vanish mid-lab. `/var/tmp` is on persistent storage and is not cleared on reboot.

### Exercise 3

**A9.** The UEFI specification requires firmware to implement the FAT12/16/32 filesystem, and only that, for the ESP. The firmware runs *before* any operating system, so it has no ext4 driver and no device-mapper. For the same reason the ESP cannot be a logical volume: LVM is a Linux kernel construct (device-mapper); the firmware sees only the raw partition table and expects a plain, contiguous, FAT-formatted partition. It also cannot be on software RAID with metadata at the front, or on LUKS.

**A10.**
(a) To `sgdisk`, `ef00` is a two-byte shorthand it expands into the type GUID `C12A7328-F81F-11D2-BA4B-00A0C93EC93B` when writing the partition entry.
(b) To the UEFI firmware, that GUID is the definition of an EFI System Partition: the firmware scans partition entries for it and looks inside for `\EFI\BOOT\BOOTX64.EFI` or a path from an `efibootmgr`-registered boot entry.
(c) To the Linux kernel it is essentially advisory — the kernel will happily mount an ESP-typed partition as anything its filesystem drivers recognise; only `systemd-gpt-auto-generator` and similar userspace act on the GUID (per the Discoverable Partitions Specification).
**The firmware is the one that actually enforces it.** Get the GUID wrong and the machine does not boot, regardless of what Linux thinks.

**A11.** No — the kernel does not enforce it. `pvcreate` writes an LVM label to sector 1 of whatever block device you point it at and works fine on an `8300` partition. The type code is metadata for *other* consumers: it tells partitioning tools, installers, `systemd-gpt-auto-generator`, and above all the human reading `sgdisk -p` six months later what the partition is for. Getting it right is a correctness-and-maintainability practice, not a functional requirement — with the sharp exceptions of `ef00` (firmware enforces) and `ef02` (GRUB's installer looks for it).

**A12.** The **ESP** holds bootloader binaries: `grubx64.efi`, `shimx64.efi`, `mmx64.efi`, vendor firmware capsules, and — with systemd-boot or a Unified Kernel Image setup — full kernels and initramfs images. 512 MiB accommodates the UKI case and multi-boot; the old 100 MiB minimum does not. **`/boot`** holds `vmlinuz-*`, `initramfs-*`, `System.map-*`, and GRUB's `grub.cfg` plus modules. The distribution behaviour that kills a 200 MiB `/boot`: package managers keep *several* kernel versions installed (Debian/Ubuntu keep the current plus previous plus the ABI-latest; RHEL/Fedora default `installonly_limit=3`). Each modern kernel plus its initramfs is 100–200 MiB, so the third kernel update fills the filesystem, `update-initramfs` fails mid-write, and — worst case — you are left with a truncated initramfs on an unbootable system.

**A13.** `align-check optimal N` verifies that partition N's start offset is a multiple of the device's *optimal I/O size* as reported through `/sys/block/*/queue/optimal_io_size` and `alignment_offset` (for a plain disk, `parted` falls back to a 1 MiB grain). Misalignment matters because a 4 KiB-physical-sector drive (4Kn, or 512e which emulates 512-byte logical sectors over 4 KiB physical) must perform a **read-modify-write** cycle whenever a logical write straddles a physical sector boundary: read the 4 KiB sector, patch the changed part, write it back. On SSDs the same problem occurs at the erase-block level and additionally increases write amplification, wearing the flash faster. Starting every partition at 1 MiB (sector 2048) is a multiple of every plausible physical sector size, erase block and RAID stripe unit, which is why every modern tool defaults to it.

### Exercise 4

**A14.** GRUB's `boot.img` fits in the 440-byte MBR bootstrap area, which is far too small to contain a filesystem driver. It must chain-load `core.img` (tens to hundreds of KiB, containing the drivers for ext4/LVM/RAID needed to reach `/boot`).
- On **BIOS+MBR**, `core.img` is written into the *post-MBR gap*: the unallocated sectors between the MBR (sector 0) and the first partition (traditionally sector 63, now sector 2048).
- On **BIOS+GPT** that gap is not free — GPT places its header at LBA 1 and its 128-entry partition array at LBA 2–33, and tools may use more. There is no guaranteed writable space. The `ef02` **BIOS boot partition** (GUID `21686148-6449-6E6F-744E-656564454649`) exists precisely to give `grub-install` a reserved, spec-blessed 1–2 MiB region to write `core.img` into.

**A15.** Format it. Putting a filesystem on the BIOS boot partition overwrites `core.img` with filesystem superblock and metadata. The symptom is a machine that reaches `boot.img`, fails to load stage 1.5, and prints something like `error: unknown filesystem` followed by the `grub rescue>` prompt — or on some versions simply hangs after `GRUB` with no further output. The fix is to boot rescue media and re-run `grub-install`. This is the trap: the partition must be left **raw**, and it must never appear in `/etc/fstab`.

**A16.** MBR allows only four *primary* partition entries in its 64-byte table. With 1, 2 and 3 primary, you must make partition 4 an **extended** partition spanning the remaining space, then create **logical** partitions inside it. The two new filesystems become `/dev/sdb5` and `/dev/sdb6` — logical partition numbering starts at 5 unconditionally, leaving a gap after 3 because the number 4 is consumed by the extended container. The extended partition itself holds no filesystem; it is a chain of EBRs.

**A17.** MBR stores the starting LBA and the length of each partition in **32-bit** fields. Maximum addressable sectors = 2³² − 1 ≈ 4.295 × 10⁹. With 512-byte sectors: 2³² × 512 bytes = 2 TiB (2,199,023,255,552 bytes). Anything beyond 2 TiB is unaddressable in an MBR table, which is the practical reason GPT — with 64-bit LBAs — became mandatory for modern drives. (A 4Kn drive with 4096-byte sectors pushes the MBR limit to 16 TiB, but that depends on the drive and firmware, and is not the answer expected on the exam.)

**A18.** No, it is not used, and no, it is not harmful. In UEFI mode the firmware looks only for a partition with the ESP GUID and loads a `.efi` binary from it; it has no concept of a BIOS boot partition and ignores that entry entirely. Carrying both an `ef02` and an `ef00` partition is in fact the standard technique for a **dual-firmware** disk — the same drive boots on legacy BIOS machines and UEFI machines — at a cost of 1–2 MiB. Installers such as Debian's create exactly this when told to support both.

### Exercise 5

**A19.** Physical Volume → Volume Group → Logical Volume.
- PV: `pvcreate /dev/sdb1` — writes the LVM label and metadata area onto a block device.
- VG: `vgcreate vg_lab /dev/sdb1` — pools one or more PVs into a named group with a fixed extent size.
- LV: `lvcreate -L 10G -n lv_data vg_lab` — allocates extents from the group's free pool into a device-mapper device at `/dev/vg_lab/lv_data` (canonically `/dev/mapper/vg_lab-lv_data`).

**A20.** LVM allocates space in whole **Physical Extents**. The default PE size is 4 MiB, and 1000 MiB is 250 extents exactly, so you get 1000.00 MiB. On a VG created with a different PE size — say `vgcreate -s 32M` — 1000 MiB is 31.25 extents, which LVM rounds **up** to 32 extents = 1024 MiB. The controlling property is the VG's extent size, visible as `PE Size` in `vgdisplay` or `vg_extent_size` in `vgs -o`. It is fixed at `vgcreate` time and affects both granularity and the maximum LV size.

**A21.** Because free extents in the VG are what make LVM's flexibility real; a VG at 100% allocated is only marginally better than fixed partitions. Two operations it enables: (1) **`lvextend`** — growing whichever volume turns out to be undersized, online, without repartitioning; (2) **`lvcreate -s`** — a copy-on-write snapshot, which needs free extents for its exception store and is the standard way to take a consistent backup or a pre-upgrade rollback point. A common production rule is to allocate conservatively at install and keep 20–30% of the VG unassigned, since growing is trivial and shrinking a mounted ext4 filesystem is not possible at all (it requires unmounting; XFS cannot shrink even then).

**A22.** You resized the *block device* but not the *filesystem* living on it. Either pass `-r` / `--resizefs` to `lvextend`, or run `sudo resize2fs /dev/vg_lab/lv_var` afterwards. For **XFS** the equivalent is `sudo xfs_growfs /mnt/lab` — note that `xfs_growfs` takes the **mount point**, not the device, and XFS can only grow, never shrink.

**A23.** Yes, GRUB2 can read `/boot` from an LVM **linear or striped** logical volume: it ships an `lvm` module that understands LVM2 metadata, and `grub-install` embeds it in `core.img`. It cannot handle LVM **thin volumes**, and its support for RAID levels and cache/writecache volumes is limited. Installers keep `/boot` on a plain partition anyway because of *fragility, not impossibility*: every additional layer between the firmware and `vmlinuz` is one more thing whose format can change under you (an LVM metadata format bump, a `grub-install` that ran before the `lvm` module was available), and the failure mode is an unbootable machine recoverable only from rescue media. The same reasoning applies to LUKS — GRUB's LUKS2 support historically excluded the default Argon2id KDF, so many installers still leave `/boot` unencrypted or on LUKS1; verify against your distribution's GRUB version before relying on it.

**A24.** The snapshot's copy-on-write exception store is sized at 1 GiB. Each first write to an origin extent copies the original data into that store. Once 3 GiB of writes have hit distinct origin extents, the store overflows, and the kernel **invalidates the snapshot**: it becomes unusable and any attempt to read it returns I/O errors. `lvs` shows `data_percent` at 100.00 and the `lv_attr` field's fifth character (state) becomes `I` for *invalid* — for example `swi-I-s---` instead of a healthy `swi-a-s---`. The lesson for design: size a snapshot for the expected *write churn on the origin during the snapshot's lifetime*, not for the origin's size, and delete it as soon as the backup completes. Enable `snapshot_autoextend_threshold` in `lvm.conf` if the churn is unpredictable.

### Exercise 6

**A25.** No. The old "swap = 2 × RAM" rule dates from an era when RAM was measured in megabytes and the kernel required backing store for all anonymous memory; it is meaningless at 128 GiB. RHEL's guidance for >64 GiB with no hibernation is "at least 4 GiB". A defensible figure is **4–8 GiB**. The justification is that swap on a modern large-memory server is not there to extend RAM — if the JVM heap genuinely exceeds physical memory the machine will thrash to uselessness long before it OOMs. Swap is there to let the kernel evict genuinely cold anonymous pages (daemon startup code, leaked-but-untouched allocations) so that page cache can use the RAM instead, and to give an OOM situation a few seconds of grace in which monitoring can fire. Also note the JVM specifically: a heap that gets swapped causes GC pauses of pathological length, so you would additionally cap the heap below physical RAM and consider `vm.swappiness=1`.

**A26.** Because any process that can read the swap file can read the memory contents of every process on the system that has been swapped out — passwords, private keys, session tokens. Mode `0600` with owner `root` restricts that to root, matching the protection a swap *partition* gets from its device node permissions. `mkswap` does not refuse — it warns: `mkswap: /var/tmp/swapfile: insecure permissions 0644, fix with: chmod 0600 /var/tmp/swapfile`. It is **`swapon`** that refuses, failing with `swapon: /var/tmp/swapfile: insecure permissions 0644, 0600 suggested` on modern `util-linux`. The file must also be owned by root and must not be sparse.

**A27.** The kernel always uses the **highest-priority** available swap area first and only spills to lower-priority areas when the higher one is full. So all swapping goes to the NVMe device until its 100% capacity is used, and only then does the HDD receive pages — a sensible tiering. If both have `pri=10`, the kernel **round-robins** across them, striping allocations between the two areas, which roughly doubles throughput when the devices are of equal speed. (Striping across an NVMe and an HDD at equal priority is the worst of both worlds: throughput becomes bounded by the HDD.) Priority is set with `swapon -p N` or the `pri=N` option in `fstab`; without it the kernel assigns descending negative priorities in activation order.

**A28.** (1) **Capacity**: the swap area must be at least as large as the amount of RAM that has to be written out — in practice ≥ physical RAM, since the resume image can, worst case, contain all of it. RHEL recommends 1.5 × RAM in the 8–64 GiB band precisely to leave headroom. (2) **Resolvability at resume time**: the initramfs must be able to find and read the swap area before the root filesystem is mounted, which means it must be a single contiguous area referenced by the `resume=UUID=…` kernel parameter (and, if it is a swap *file*, additionally by `resume_offset=`, obtained from `filefrag -v`). A swap area spread across two devices, or one whose device requires a network or unavailable-at-early-boot driver, cannot serve as a resume device.

**A29.** No, it does not disable swapping. `vm.swappiness` controls the kernel's *relative preference* for reclaiming anonymous pages versus page cache: 0 means "reclaim anonymous memory only when the alternative is failing an allocation". Under genuine memory pressure the kernel will still swap rather than invoke the OOM killer. The practical effect since Linux 3.5 is that `swappiness=0` makes the kernel much more aggressive about dropping page cache — which, on a database or fileserver, can be *worse* for performance than allowing a little swapping. The value to disable swap entirely is `swapoff -a`, not a swappiness setting; `vm.swappiness=1` is the usual "almost never, but keep the safety net" choice.

**A30.**
- **Partition advantage**: guaranteed contiguous on-disk layout with no intervening filesystem layer, so there is no fragmentation and no filesystem-level indirection or locking on the swap I/O path. It also cannot be accidentally deleted, moved by a defragmenter, or affected by a `fsck` of a host filesystem, and it is simplest for hibernation.
- **File advantage**: it can be created, resized and removed at any time on a running system with no repartitioning — `fallocate`, `mkswap`, `swapon`, done. On a cloud instance or a VM whose disk layout is fixed at provisioning, that flexibility is the deciding factor. Modern kernels access swap files through the extent map with negligible overhead compared to the historical penalty.

### Exercise 7

**A31.** **For a separate `/var`:** it isolates unbounded, externally-driven growth from the root filesystem. Logs, mail spools, print queues, package caches and container images all grow in response to input the administrator does not control. A full `/` is qualitatively worse than a full `/var` — it can prevent PAM from writing session files, `systemd` from writing runtime state, and in the worst case prevent login, turning a disk-space incident into an on-site visit. **Against six filesystems on a small VM:** stranded free space and administrative rigidity. On a 20 GiB disk, six filesystems each carrying a safety margin waste several gigabytes that no single filesystem can borrow; and the failure mode you actually hit is "`/var` is full while `/home` is 90% empty", which on a single root filesystem would never have occurred. The correct rule of thumb: split when a directory has an independent growth driver, a distinct security requirement, or a distinct backup/snapshot cadence — not by default.

**A32.** `/home` gets the most space, by a wide margin — on a 4 TiB disk for 200 users, something like 3 TiB. The mechanism not visible in the partition table is **disk quotas**: `quota`/`quotatool` on ext4 (mount option `usrquota,grpquota` or the `quota` feature flag, plus `quotacheck`/`quotaon`), or project quotas on XFS (`pquota`). Quotas apply *per filesystem*, which is precisely why `/home` must be its own filesystem — you cannot quota a directory on a shared root filesystem with the traditional mechanism. Soft limits with a grace period plus a hard ceiling is the usual configuration.

**A33.** It is not worthless. `noexec` blocks the kernel from honouring the `execve()` of a binary or of a script via its shebang. What it does *not* block is an already-permitted interpreter being invoked explicitly on a data file — `sh file`, `python file`, `perl file` — because there the kernel executes `/bin/sh`, which lives on an executable filesystem, and `file` is merely input. The class of attack it still blocks is the **dropped ELF binary**: an attacker who gains a limited foothold and writes a compiled exploit, rootkit or cryptominer to `/tmp` or `/home` cannot run it. That covers a large fraction of automated and commodity attacks, and it is why CIS benchmarks require it. It should be understood as raising the cost, not as a boundary.

**A34.**
- **`tmpfs` is wrong** when applications write large temporary files: a big database `ORDER BY` spill, a video transcode, an `rpmbuild`/`dpkg-buildpackage` of a large source tree, or a `tar` staging directory. `tmpfs` consumes RAM, so a multi-gigabyte temporary file evicts page cache and then pushes the system into swap or OOM. The classic symptom is a build that succeeds on one machine and OOMs on another with less RAM.
- **A logical volume is wrong** on a system where `/tmp` sees high-frequency small-file churn and where the security benefit of RAM-backed, reboot-cleared scratch matters — and on any system where you would rather not spend disk on it. Persistent `/tmp` also accumulates stale files across reboots, needing `systemd-tmpfiles` cleanup policy, and puts extra write wear on flash.

**A35.** `containerd` stores images and container filesystems under `/var/lib/containerd` (Docker: `/var/lib/docker`; Podman rootful: `/var/lib/containers`; rootless: `~/.local/share/containers`). Every pulled layer, every stopped container's writable layer and every build cache entry lands there, and growth is driven by CI pipelines and image tags — entirely outside the administrator's control. The change: give the container store its **own** logical volume, mounted at `/var/lib/containerd`, so that an unbounded image pull fills that volume and nothing else. `journald` keeps writing to `/var/log/journal` on a separate `/var`, `sshd` keeps writing `/var/log/*` and its runtime state, and you retain a working system on which to run `crictl rmi --prune`. The alternative failure — a full `/var` — silently stops `journald` (it will not write past its `SystemMaxUse`, but a full filesystem also breaks other daemons) and can block logins.

**A36.** **Stranded free space** is free capacity that exists on the disk but is unreachable by the filesystem that needs it, because it lives inside a different fixed partition. Numeric example on a 500 GiB disk split as `/` 50 GiB, `/var` 100 GiB, `/home` 350 GiB: `/var` reaches 100% during a log incident while `/home` is 40% used — 210 GiB is free on the disk and completely unusable to `/var`. Fixing it with fixed partitions requires `parted` surgery, a resize, and downtime.

**LVM reduces** the problem in two ways: unallocated extents in the VG can be given to whichever LV needs them (`lvextend -r -L +50G vg/lv_var`) online and instantly; and an LV can even be extended onto a newly-added PV on a second disk. **It does not eliminate** it, because space already *allocated* to an LV is still stranded — `/home` at 350 GiB with 210 GiB free cannot lend to `/var` without shrinking, and shrinking requires unmounting for ext4 and is impossible for XFS. The mitigation is to allocate conservatively and keep a free extent reserve; thin provisioning goes further at the cost of overcommit risk and mandatory monitoring.

### Exercise 8

**A37.** The six fields, in order: **device** (or `UUID=`/`LABEL=`/`PARTUUID=`), **mount point**, **filesystem type**, **mount options**, **dump** (a legacy flag for the `dump` backup utility; `0` in essentially all modern configurations), **pass** (the `fsck` pass number).
`pass` values: `/` → **1**; `/home` → **2**; swap → **0**. Pass 1 runs first and alone (the root filesystem must be checked before anything else); pass 2 entries are checked afterwards and may be checked in parallel across different physical devices; pass 0 means "never check", which is correct for swap, for `tmpfs`, for network filesystems, and for anything with no `fsck` helper.

**A38.** `/dev/sda2` is a **name assigned by device enumeration order**, which is not stable. Adding a disk, changing a SATA/SAS cable, a different USB probe order, a kernel upgrade that changes driver initialisation, or moving the disk to another machine can all renumber devices — and then `/dev/sda2` refers to a different partition or none, and the system fails to boot. A `UUID=` is written into the filesystem superblock at `mkfs` time and travels with the data, so it identifies the same filesystem regardless of where the device shows up. (`PARTUUID=` is the GPT partition entry GUID, equally stable, and it survives a reformat where `UUID=` does not.)

`/dev/mapper/vg_lab-lv_root` is acceptable because it is **not** an enumeration-order name: it is constructed deterministically from the volume group name and the logical volume name. LVM scans PV labels on all devices and assembles the same VG under the same name no matter which `/dev/sdX` the PVs landed on. `/dev/vg_lab/lv_root` is the equivalent symlink. Both are as stable as a UUID, and more readable.

**A39.**
- **`mount -a`** — the decisive check. It attempts to mount every non-`noauto` entry, so a bad device path, a wrong filesystem type, an invalid option or a missing mount-point directory all produce an error *now*, at a shell prompt, rather than at boot. This is the one that catches a typo in a device path.
- **`findmnt --verify`** — a static analysis of the file: it flags unreachable mount points, unknown filesystem types, suspicious `pass`/`dump` values and duplicated targets, and it *does* report a source that does not exist. It does not attempt the mount, so it will not catch every runtime failure (an option the filesystem rejects, for instance).
- **`blkid`** — only confirms that an identifier exists and what it maps to; it validates nothing about `fstab` itself. Useful for producing the correct `UUID=` in the first place.
- **`systemctl daemon-reload`** — regenerates the `.mount` units that `systemd-fstab-generator` derives from `/etc/fstab`. It surfaces parse-level complaints in the journal and is *required* after editing `fstab` on a systemd system so that systemd's view matches the file — but it does not test that the device exists.

The correct sequence after editing a real `fstab` is: `findmnt --verify`, then `systemctl daemon-reload`, then `mount -a`, and only then reboot.

**A40.** **`nofail`** — the boot does not fail if the device is missing; systemd marks the mount unit as non-critical rather than dropping to emergency mode. **`x-systemd.device-timeout=5s`** — bounds how long systemd waits for the device to appear before giving up; without it the default is 90 seconds of apparent hang, and with `nofail` alone you still wait out that timeout. Use both together. `noauto` is the third option worth knowing: it keeps the entry in `fstab` for a convenient `mount /mnt/backup` but never mounts it at boot at all — appropriate when the disk is normally absent, whereas `nofail` fits a disk that is normally present.

**A41.** `pass 1` means "check this filesystem in the first `fsck` pass, before all others". Pass 1 is reserved for the root filesystem: `fsck` runs pass-1 entries serially and first, and having a second pass-1 entry is at best pointless and at worst delays or confuses the boot-time check ordering. Additionally, `fsck.vfat` (`dosfsck`) on the ESP at every boot is undesirable — an unnecessary write-capable check of the partition the firmware depends on, and a source of spurious "dirty bit" complaints. The correct value for `/boot/efi` is **`0`** (do not check) in most distributions, or `2` at most; Debian and Fedora both ship `0` for the ESP.

### Exercise 9

**A42.** The device-mapper devices for the logical volumes are *held open* by the kernel and their I/O path terminates on the loop device. Detaching the loop device while a VG is active pulls the backing store out from under live `dm` targets. `losetup -d` will normally refuse with `Device or resource busy`; if it is forced (`losetup -D`, or the file being deleted while attached), the LVs remain in `/dev/mapper` pointing at a device with no backing, and every I/O returns an error. You then have stale `dm` entries that must be cleared with `dmsetup remove`, and `pvs`/`vgs` will print `Couldn't find device with uuid …` warnings on every invocation until the VG is cleaned up. Hence the strict top-down order: unmount → `swapoff` → `vgchange -an` (deactivate) → `vgremove` → `losetup -d`.

**A43.** Two causes: (1) a filesystem on one of the loop's partitions is still **mounted** — including a mount you forgot, or an automounter that grabbed it; (2) LVM still holds it — a VG on the loop is still **active**, so device-mapper has the partition open. A third common one is a swap area on the device still being active. To identify the holder:

```bash
sudo lsof "$LOOP"* 2>/dev/null
sudo fuser -vm "$LOOP" 2>/dev/null
lsblk "$LOOP"                       # shows any child dm/mount still present
sudo dmsetup ls --tree              # shows dm devices and their dependencies
cat /sys/block/$(basename "$LOOP")/holders/*   2>/dev/null
```

`lsblk` and `dmsetup ls --tree` are usually the fastest: they show exactly which layer is still stacked on top.

</details>