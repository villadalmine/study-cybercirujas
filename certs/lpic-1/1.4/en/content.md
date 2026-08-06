# Devices, Linux Filesystems, and the Filesystem Hierarchy Standard (FHS)

## 1. Architectural Motivation and Production Context

In modern distributed infrastructure, treating storage simply as "disks where data lives" is a recipe for catastrophic outages. The Linux kernel's architectural genius lies in the **Virtual Filesystem Switch (VFS)**. VFS provides a unified API to user-space applications, allowing a single `write()` syscall to transparently handle data destined for a local NVMe drive, a remote NFS share, or an in-memory `tmpfs` allocation.

This abstraction stems from the Unix philosophy: **"Everything is a file"** (or more accurately, a file descriptor). For a Principal Platform Architect, this means that hardware devices are exposed as block or character files in `/dev`, kernel state parameters are exposed as text files in `/proc` and `/sys`, and network sockets follow the same file I/O paradigms.

To enforce consistency across the millions of Linux servers deployed worldwide, the **Filesystem Hierarchy Standard (FHS)** dictates strict directory structures. Without FHS compliance, automated configuration management (Ansible, Terraform) and orchestrators (Kubernetes) would collapse, as they rely on predictable paths for binaries (`/usr/bin`), dynamic runtime data (`/run`), and persistent configurations (`/etc`). Mastering this hierarchy is not just about passing an exam; it is about writing idempotent automation that survives OS upgrades.

## 2. Technical Comparison and Trade-offs

### The Anatomy of `/dev`: Block vs. Character Devices

Devices in Linux are represented by special files created dynamically by `udev` based on kernel events.
*   **Block Devices (`b`):** Transfer data in buffered blocks (e.g., 4KB). Examples: `/dev/sda` (SATA/SCSI disks), `/dev/nvme0n1` (NVMe drives), `/dev/vda` (VirtIO disks in KVM/AWS).
*   **Character Devices (`c`):** Transfer data byte-by-byte, unbuffered. Examples: `/dev/tty` (terminals), `/dev/urandom` (entropy pool), `/dev/null`.

Each device is identified by a **Major Number** (identifies the driver) and a **Minor Number** (identifies the specific instance).

### Filesystem Architectures

| Filesystem | Underlying Mechanics & Use Case | Architectural Trade-offs |
| :--- | :--- | :--- |
| **ext4** | Uses extents instead of traditional block mapping to reduce metadata overhead. Standard across most Linux distributions. | **Pros:** Exceptionally stable, fast fsck. **Cons:** No native snapshotting, deduplication, or volume management (relies on LVM). Maximum volume size is 1EiB, but performance degrades gracefully at scale. |
| **XFS** | Allocation groups allow parallel I/O operations. Default in RHEL/CentOS. | **Pros:** Unmatched scalability for multi-threaded database workloads (e.g., PostgreSQL). **Cons:** **Cannot be shrunk.** Once grown, you cannot reduce the size of an XFS partition. |
| **Btrfs** | Copy-on-Write (CoW) B-tree structure. | **Pros:** Native snapshots, transparent compression, checksumming against bit-rot. **Cons:** CoW can cause severe fragmentation and performance cliffs for workloads with heavy random overwrites (e.g., databases) unless `nodatacow` is set. |
| **tmpfs** | RAM-backed storage allocation. Swaps to disk if memory is exhausted. | **Pros:** Microsecond latency. **Cons:** Volatile. Over-allocating `tmpfs` can trigger the Out Of Memory (OOM) killer if the system runs out of swap. |

### The FHS in a Cloud-Native Era

While traditional FHS remains intact, containerization has shifted the focus for SREs:
*   `/etc`: Host configuration. In immutable infrastructure, this is populated at boot via `cloud-init` or Ignition.
*   `/var/lib/containers` or `/var/lib/docker`: The most critical paths on modern nodes, prone to filling up due to image bloat.
*   `/run`: Replaced the legacy `/var/run`. It is a `tmpfs` containing transient state (PIDs, sockets) that must not persist across reboots.

## 3. Configuration and Infrastructure Automation

### Modern Mount Management: `fstab` and `systemd`

Historically, `/etc/fstab` was processed sequentially by `mount -a`. Today, **systemd** parses `/etc/fstab` at boot and dynamically generates native `.mount` units in `/run/systemd/generator/`. This allows for parallel mounting and complex dependency management.

Using **UUIDs (Universally Unique Identifiers)** is mandatory in cloud environments. If you attach an EBS volume in AWS, the kernel might enumerate it as `/dev/nvme1n1` on one boot and `/dev/nvme2n1` on the next. UUIDs are cryptographic hashes written to the filesystem's superblock, rendering them immune to hardware enumeration changes.

**Advanced Production `/etc/fstab`:**

```text
# <file system>                                <mount point>   <type>  <options>                                                               <dump>  <pass>
# Root Filesystem (XFS)
UUID=3a4b5c6d-7e8f-9a0b-1c2d-3e4f5a6b7c8d      /               xfs     defaults,noatime,prjquota                                               0       1

# Persistent Application Data with Systemd Automount
# x-systemd.automount delays the actual mount until a process attempts to access /data, saving boot time.
UUID=11223344-5566-7788-9900-aabbccddeeff      /data           ext4    defaults,noatime,x-systemd.automount,x-systemd.idle-timeout=600         0       2

# Non-critical Backup Mount (NFS)
# nofail ensures the server boots even if the NFS share is unreachable.
10.0.0.50:/exports/backups                     /mnt/backups    nfs4    defaults,nofail,_netdev,x-systemd.requires=network-online.target        0       0
```
*Tuning Note: `noatime` is a critical performance tweak. By default (`relatime`), Linux updates the access timestamp of a file every time it is read (if older than 24h). `noatime` disables this entirely, eliminating write overhead on read-heavy systems.*

## 4. CLI Commands and Terminal Outputs

### Inspecting Block Devices and Inodes

To view the raw topology of storage, including LVM layers and UUIDs:
```bash
$ lsblk -f
NAME                  FSTYPE      LABEL UUID                                   MOUNTPOINT
nvme0n1                                                                        
├─nvme0n1p1           vfat              4A2B-1234                              /boot/efi
├─nvme0n1p2           ext4              98765432-10ab-cdef-0123-456789abcdef   /boot
└─nvme0n1p3           LVM2_member       xyz123-4567-890a-bcde-fghi-jklm-nopq   
  ├─vg_main-lv_root   xfs               3a4b5c6d-7e8f-9a0b-1c2d-3e4f5a6b7c8d   /
  └─vg_main-lv_swap   swap              abcdef12-3456-7890-abcd-ef1234567890   [SWAP]
```

To extract the exact UUID directly from the superblock without parsing trees:
```bash
$ sudo blkid /dev/mapper/vg_main-lv_root
/dev/mapper/vg_main-lv_root: UUID="3a4b5c6d-7e8f-9a0b-1c2d-3e4f5a6b7c8d" BLOCK_SIZE="4096" TYPE="xfs"
```

### Filesystem Creation and Online Resizing

When provisioning high-performance databases, SREs tune the filesystem creation. Here, we format an `ext4` drive, reducing the reserved space from the default 5% to 1% (saving 40GB on a 1TB drive):
```bash
$ sudo mkfs.ext4 -m 1 -L db_data /dev/nvme1n1
mke2fs 1.45.5 (07-Jan-2020)
Filesystem label=db_data
OS type: Linux
Block size=4096 (log=2)
Fragment size=4096 (log=2)
Stride=0 blocks, Stripe width=0 blocks
65536000 inodes, 262144000 blocks
2621440 blocks (1.00%) reserved for the super user
...
```

Resizing a filesystem dynamically while the system is live (after extending the underlying LVM or cloud block storage):
```bash
# For ext4:
$ sudo resize2fs /dev/mapper/vg_main-lv_data
resize2fs 1.45.5 (07-Jan-2020)
Filesystem at /dev/mapper/vg_main-lv_data is mounted on /data; on-line resizing required
old_desc_blocks = 63, new_desc_blocks = 125
The filesystem on /dev/mapper/vg_main-lv_data is now 262144000 (4k) blocks long.

# For XFS (uses the mount point, not the device path):
$ sudo xfs_growfs /data
meta-data=/dev/mapper/vg_main-lv_data isize=512    agcount=4, agsize=3276800 blks
data     =                       bsize=4096   blocks=13107200, imaxpct=25
```

## 5. Troubleshooting and Diagnostics

### Issue: "No space left on device" (Disk isn't full)
**Symptom:** Application crashes stating the disk is full. `df -h` shows 40% free space.
**Diagnosis:** The VFS architecture separates data blocks from **inodes** (metadata structures that track file location, permissions, etc.). Every file requires exactly one inode. If you have millions of tiny files (like a runaway PHP session cache), you will exhaust the inode table before exhausting physical gigabytes.
```bash
$ df -i /var
Filesystem       Inodes   IUsed  IFree IUse% Mounted on
/dev/nvme0n1p2  3276800 3276800      0  100% /var
```
**Fix:** Locate the directory hoarding the inodes using a combination of `find` and `wc`, then purge the files.
```bash
$ sudo find /var -xdev -type d -print0 | xargs -0 -I {} bash -c 'echo -ne "{}\t"; ls -1 "{}" | wc -l' | awk '$2 > 100000'
/var/lib/php/sessions   1420500
$ sudo rm -rf /var/lib/php/sessions/*
```

### Issue: Superblock Corruption on Boot
**Symptom:** Server boots into Emergency Mode. The `journalctl -xb` logs show:
```text
EXT4-fs (sda1): VFS: Can't find ext4 filesystem
mount: /boot: wrong fs type, bad option, bad superblock on /dev/sda1, missing codepage or helper program, or other error.
```
**Diagnosis:** The primary superblock (located at block 0) is corrupted. The superblock contains critical filesystem geometry (block size, inode count).
**Fix:** Linux filesystems automatically scatter backup superblocks throughout the partition during formatting. Use `mke2fs -n` to simulate formatting and reveal the backup block locations, then force `fsck` to use one.
```bash
# 1. Find backup superblocks (the -n flag ensures it does NOT format the drive)
$ sudo mke2fs -n /dev/sda1
Superblock backups stored on blocks: 
        32768, 98304, 163840, 229376, 294912, 819200, 884736

# 2. Run fsck using the first backup superblock
$ sudo fsck.ext4 -b 32768 /dev/sda1
```

### Issue: Zombie Mounts (Unresponsive NFS/CIFS)
**Symptom:** Running `df -h` hangs indefinitely. You cannot `cd` into `/mnt/network_share`.
**Diagnosis:** A remote filesystem is hard-mounted, but the network link dropped. The kernel is blocking the process in an uninterruptible sleep state (`D` state in `top`).
**Fix:** Attempt a "lazy unmount". This immediately detaches the filesystem from the VFS namespace, allowing `df` to recover, and cleans up the kernel references in the background once the timeout expires.
```bash
$ sudo umount -l /mnt/network_share
```

## References
- [LPIC-1 Overview](https://www.lpi.org/our-certifications/lpic-1-overview/)
- [Filesystem Hierarchy Standard (FHS) 3.0](https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html)
- [Kernel Documentation: VFS (Virtual Filesystem Switch)](https://www.kernel.org/doc/html/latest/filesystems/vfs.html)
- [systemd.mount - Mount unit configuration](https://www.freedesktop.org/software/systemd/man/systemd.mount.html)
- [Arch Linux Wiki: fstab and Automount](https://wiki.archlinux.org/title/fstab)