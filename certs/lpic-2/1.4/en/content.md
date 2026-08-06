# LPIC-2 Topic 203: Filesystem and Devices

## Comprehensive SRE/Platform Architect Study Guide

---

## 1. Motivation and Production Architectural Problem

In production Linux infrastructure, filesystem and device management constitutes the foundational data persistence layer. An SRE managing hundreds or thousands of nodes must solve these interconnected problems:

**Problem 1: Filesystem Heterogeneity.** Different workloads demand different filesystem characteristics. A PostgreSQL database server benefits from XFS's predictable allocation patterns, while a snapshot-heavy VM host benefits from Btrfs's copy-on-write semantics. Choosing incorrectly incurs irrecoverable performance penalties and operational risk.

**Problem 2: Deterministic Mount Ordering at Scale.** When a node has 15+ mount points across local disks, NFS shares, and encrypted volumes, boot ordering becomes non-trivial. A misconfigured `/etc/fstab` on 500 nodes means 500 nodes in emergency mode after a kernel update.

**Problem 3: Device Identity Stability.** Device names (`/dev/sda`, `/dev/sdb`) are non-deterministic across reboots. A production database writing to `/dev/sdb1` that silently becomes a different physical disk after a PCI rescan leads to catastrophic data corruption.

**Problem 4: Automated Provisioning of Removable/Network Storage.** NFS home directories, optical media archival systems, and hot-plugged storage must mount on-demand without manual intervention and release resources when idle.

**Problem 5: Data-at-Rest Encryption.** Regulatory compliance (GDPR, HIPAA, PCI-DSS) mandates encryption of persistent volumes, adding a layer of complexity to boot, mount, and recovery procedures.

This topic covers the full lifecycle: creation → tuning → mounting → monitoring → repair → encryption → automation.

---

## 2. Technical Comparatives

### 2.1 Filesystem Feature Comparison

| Feature | ext4 | XFS | Btrfs | ZFS |
|---|---|---|---|---|
| **Max Volume Size** | 1 EiB | 8 EiB | 16 EiB | 256 ZiB |
| **Max File Size** | 16 TiB | 8 EiB | 16 EiB | 16 EiB |
| **Copy-on-Write** | No | No (reflink since 4.9) | Yes (native) | Yes (native) |
| **Snapshots** | No (LVM required) | No (LVM required) | Yes (subvolume) | Yes (dataset) |
| **Online Grow** | Yes | Yes | Yes | Yes |
| **Online Shrink** | Yes | **No** | Yes | **No** |
| **Built-in RAID** | No | No | Yes (RAID 0/1/10/5/6) | Yes (RAIDZ1/2/3) |
| **Checksumming** | Metadata only (journal) | Metadata only | Data + Metadata | Data + Metadata |
| **Deduplication** | No | No | Yes (offline) | Yes (online, RAM intensive) |
| **Compression** | No | No | Yes (zlib, lzo, zstd) | Yes (lz4, gzip, zstd) |
| **Inline fsck** | Offline (`e2fsck`) | Online (`xfs_repair` offline, `xfs_scrub` online) | Online (`btrfs scrub`) | Online (`zpool scrub`) |
| **Kernel Integration** | Mainline | Mainline | Mainline | Out-of-tree (DKMS) |
| **Production Maturity** | Highest | Highest | Medium-High | Highest (Solaris/FreeBSD lineage) |
| **Best Use Case** | General purpose, databases | Large files, high throughput, databases | Snapshots, desktop, containers | NAS, large-scale storage |

### 2.2 Mount Identification Methods

| Method | Example | Stability | Portability | LPIC-2 Relevance |
|---|---|---|---|---|
| **Device name** | `/dev/sda1` | ❌ Unstable (PCI enumeration order) | Low | Know to avoid |
| **UUID** | `UUID=a1b2c3d4-...` | ✅ Globally unique, survives reboot | High | **Primary method** |
| **LABEL** | `LABEL=datastore` | ⚠️ Unique only if managed | Medium | Common in scripts |
| **PARTUUID** | `PARTUUID=abcd-1234` | ✅ GPT partition UUID | High | EFI/GPT systems |
| **Device path** | `/dev/disk/by-path/...` | ⚠️ Tied to physical topology | Low | HBA/SAN scenarios |
| **Device ID** | `/dev/disk/by-id/...` | ✅ Tied to hardware serial | High | Multi-path/SAN |

### 2.3 Automount Methods Comparison

| Feature | AutoFS | systemd `.automount` | `x-systemd.automount` in fstab |
|---|---|---|---|
| **Daemon required** | Yes (`autofs.service`) | No (systemd native) | No (systemd native) |
| **Config location** | `/etc/auto.master` + map files | Unit files in `/etc/systemd/system/` | `/etc/fstab` mount options |
| **NFS integration** | Excellent (wildcard maps) | Manual per-mount | Manual per-mount |
| **Idle timeout** | `--timeout=N` in auto.master | `TimeoutIdleSec=` | `x-systemd.idle-timeout=` |
| **LDAP/NIS maps** | Yes | No | No |
| **Complexity at scale** | Lower for NFS home dirs | Higher (one unit per mount) | Lowest (single fstab line) |
| **Debugging** | `automount -f -v` | `journalctl -u *.automount` | `journalctl -u *.automount` |

### 2.4 Swap Configuration Methods

| Method | Pros | Cons | Production Use |
|---|---|---|---|
| **Swap Partition** | Fastest, dedicated I/O path | Requires partitioning, inflexible size | Traditional servers |
| **Swap File** | Flexible sizing, easy to create/remove | Slight overhead on some FS, Btrfs limitations | Cloud VMs, containers |
| **zram** | Uses compressed RAM, very fast | Uses CPU, not persistent | Desktop, memory-constrained |
| **No swap** | Predictable OOM behavior | OOM killer more aggressive | Kubernetes worker nodes (debated) |

---

## 3. Configuration Files and Infrastructure Manifests

### 3.1 Complete Production `/etc/fstab`

```bash
# /etc/fstab - Production server with multiple filesystem types
# <filesystem>                            <mountpoint>       <type>   <options>                                              <dump> <pass>

# Root filesystem - ext4 on LVM
UUID=3a4b5c6d-7e8f-9a0b-1c2d-3e4f5a6b7c8d /                  ext4     errors=remount-ro,noatime,commit=60                   0      1

# Boot partition - ext4, separate for GRUB
UUID=1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d /boot              ext4     defaults,noatime                                      0      2

# EFI System Partition
UUID=ABCD-1234                             /boot/efi          vfat     umask=0077                                            0      1

# Data volume - XFS for database workload
UUID=9f8e7d6c-5b4a-3928-1716-0f5e4d3c2b1a /var/lib/postgresql xfs      defaults,noatime,inode64,logbufs=8,logbsize=256k      0      2

# Temporary storage - tmpfs
tmpfs                                      /tmp               tmpfs    defaults,noatime,nosuid,nodev,noexec,size=2G          0      0

# Large data volume - Btrfs with compression
UUID=abcdef01-2345-6789-abcd-ef0123456789  /srv/data          btrfs    defaults,noatime,compress=zstd:3,space_cache=v2       0      0

# NFS mount with automount
nas01:/export/shared                       /mnt/shared        nfs4     _netdev,x-systemd.automount,x-systemd.idle-timeout=300,soft,timeo=30,retrans=3  0  0

# Swap partition
UUID=fedcba98-7654-3210-fedc-ba9876543210  none               swap     sw,pri=10                                             0      0

# Swap file (alternative/additional)
/swapfile                                  none               swap     sw,pri=5                                              0      0

# Encrypted volume (unlocked via /etc/crypttab)
/dev/mapper/data_crypt                     /srv/encrypted     ext4     defaults,noatime,_netdev                              0      2

# ISO image loopback mount
/opt/images/rescue.iso                     /mnt/rescue        iso9660  loop,ro,auto                                          0      0

# Proc, sys - typically auto-mounted by systemd, shown for reference
proc                                       /proc              proc     defaults                                              0      0
sysfs                                      /sys               sysfs    defaults                                              0      0
```

### 3.2 `/etc/crypttab` for LUKS Volumes

```bash
# /etc/crypttab - Encrypted block device mapping
# <name>       <device>                                        <keyfile>              <options>
data_crypt     UUID=11223344-5566-7788-99aa-bbccddeeff00       /etc/keys/data.key     luks,discard,noauto
swap_crypt     /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0-0-0-2-part2  /dev/urandom  swap,cipher=aes-xts-plain64,size=256
```

### 3.3 AutoFS Configuration

#### `/etc/auto.master` (Master Map)

```bash
# /etc/auto.master - AutoFS master map
# <mount-point>    <map-file>            <options>

# NFS home directories with 10-minute idle timeout
/home/remote       /etc/auto.home        --timeout=600

# Removable media
/media/removable   /etc/auto.removable   --timeout=30 --ghost

# Project NFS shares
/mnt/projects      /etc/auto.projects    --timeout=900

# Direct map for specific mounts (note the /- syntax)
/-                 /etc/auto.direct      --timeout=0

# Include directory for drop-in configs
+dir:/etc/auto.master.d
```

#### `/etc/auto.home` (Indirect Map for Home Directories)

```bash
# /etc/auto.home - NFS home directory map
# <key>    <options>                                          <location>

# Wildcard: any username maps to its directory on the NFS server
*          -fstype=nfs4,rw,soft,timeo=30,retrans=3,sec=krb5  nas01:/export/home/&

# Specific override for a user with different server
admin      -fstype=nfs4,rw,hard,timeo=60                     nas02:/export/admin
```

#### `/etc/auto.projects` (Indirect Map with Multiple Servers)

```bash
# /etc/auto.projects - Project shares
# Multi-mount entry: single key, multiple submounts
engineering    -fstype=nfs4,rw   nas01:/export/projects/engineering
research       -fstype=nfs4,rw   nas02:/export/projects/research
shared         -fstype=nfs4,ro   nas01:/export/projects/shared
```

#### `/etc/auto.direct` (Direct Map)

```bash
# /etc/auto.direct - Direct mount points
# These mount directly at the specified absolute path
/opt/software      -fstype=nfs4,ro     nas01:/export/software
/var/log/central   -fstype=nfs4,rw     logserver:/export/logs
```

### 3.4 systemd Mount and Automount Units

#### `/etc/systemd/system/srv-data.mount`

```ini
# srv-data.mount - systemd mount unit for data volume
[Unit]
Description=Data Volume Mount (XFS)
Documentation=man:systemd.mount(5)
Requires=local-fs-pre.target
After=local-fs-pre.target
Before=local-fs.target
Conflicts=umount.target

[Mount]
What=UUID=abcdef01-2345-6789-abcd-ef0123456789
Where=/srv/data
Type=xfs
Options=defaults,noatime,inode64,logbufs=8
TimeoutSec=30
DirectoryMode=0755

[Install]
WantedBy=local-fs.target
```

#### `/etc/systemd/system/srv-data.automount`

```ini
# srv-data.automount - on-demand automount
[Unit]
Description=Automount Data Volume
Documentation=man:systemd.automount(5)
ConditionPathExists=/srv

[Automount]
Where=/srv/data
TimeoutIdleSec=300
DirectoryMode=0755

[Install]
WantedBy=local-fs.target
```

#### `/etc/systemd/system/mnt-nfs\x2dshare.mount`

```ini
# mnt-nfs\x2dshare.mount - NFS mount with network dependency
[Unit]
Description=NFS Share Mount
After=network-online.target
Wants=network-online.target
Requires=remote-fs-pre.target
After=remote-fs-pre.target

[Mount]
What=nas01:/export/shared
Where=/mnt/nfs-share
Type=nfs4
Options=rw,soft,timeo=30,retrans=3,_netdev
TimeoutSec=60

[Install]
WantedBy=remote-fs.target
```

---

## 4. CLI Commands and Real Terminal Outputs

### 4.1 Device Identification and Enumeration

```bash
$ lsblk -f
NAME          FSTYPE      FSVER  LABEL     UUID                                 FSAVAIL FSUSE% MOUNTPOINTS
sda                                                                                             
├─sda1        vfat        FAT32  EFI       ABCD-1234                             504.5M     1% /boot/efi
├─sda2        ext4        1.0    boot      1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d 648.2M    26% /boot
└─sda3        LVM2_member LVM2 001        xxxx-yyyy-zzzz-...                                   
  ├─vg0-root  ext4        1.0    root      3a4b5c6d-7e8f-9a0b-1c2d-3e4f5a6b7c8d  14.2G    45% /
  ├─vg0-swap  swap        1                fedcba98-7654-3210-fedc-ba9876543210                 [SWAP]
  └─vg0-data  xfs                pgdata    9f8e7d6c-5b4a-3928-1716-0f5e4d3c2b1a  89.3G    22% /var/lib/postgresql
sdb                                                                                             
└─sdb1        btrfs              datastore abcdef01-2345-6789-abcd-ef0123456789   1.8T    28% /srv/data
sdc                                                                                             
└─sdc1        crypto_LUKS 2                11223344-5566-7788-99aa-bbccddeeff00                 
  └─data_crypt ext4       1.0    encrypted ee112233-4455-6677-8899-aabbccddeeff  420.8G    15% /srv/encrypted
```

```bash
$ blkid
/dev/sda1: LABEL="EFI" UUID="ABCD-1234" BLOCK_SIZE="512" TYPE="vfat" PARTUUID="a1a1a1a1-01"
/dev/sda2: LABEL="boot" UUID="1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d" BLOCK_SIZE="4096" TYPE="ext4" PARTUUID="a1a1a1a1-02"
/dev/sda3: UUID="xxxx-yyyy-zzzz" TYPE="LVM2_member" PARTUUID="a1a1a1a1-03"
/dev/mapper/vg0-root: LABEL="root" UUID="3a4b5c6d-7e8f-9a0b-1c2d-3e4f5a6b7c8d" BLOCK_SIZE="4096" TYPE="ext4"
/dev/mapper/vg0-swap: UUID="fedcba98-7654-3210-fedc-ba9876543210" TYPE="swap"
/dev/mapper/vg0-data: LABEL="pgdata" UUID="9f8e7d6c-5b4a-3928-1716-0f5e4d3c2b1a" BLOCK_SIZE="4096" TYPE="xfs"
/dev/sdb1: LABEL="datastore" UUID="abcdef01-2345-6789-abcd-ef0123456789" UUID_SUB="1234abcd-5678-efab-cdef-123456789abc" BLOCK_SIZE="4096" TYPE="btrfs"
/dev/sdc1: UUID="11223344-5566-7788-99aa-bbccddeeff00" TYPE="crypto_LUKS"
/dev/mapper/data_crypt: LABEL="encrypted" UUID="ee112233-4455-6677-8899-aabbccddeeff" BLOCK_SIZE="4096" TYPE="ext4"
```

```bash
$ ls -la /dev/disk/by-uuid/
total 0
drwxr-xr-x 2 root root 200 Jan 15 08:30 .
drwxr-xr-x 8 root root 160 Jan 15 08:30 ..
lrwxrwxrwx 1 root root  10 Jan 15 08:30 1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d -> ../../sda2
lrwxrwxrwx 1 root root  10 Jan 15 08:30 3a4b5c6d-7e8f-9a0b-1c2d-3e4f5a6b7c8d -> ../../dm-0
lrwxrwxrwx 1 root root  10 Jan 15 08:30 9f8e7d6c-5b4a-3928-1716-0f5e4d3c2b1a -> ../../dm-2
lrwxrwxrwx 1 root root  10 Jan 15 08:30 ABCD-1234 -> ../../sda1
lrwxrwxrwx 1 root root  10 Jan 15 08:30 abcdef01-2345-6789-abcd-ef0123456789 -> ../../sdb1
lrwxrwxrwx 1 root root  10 Jan 15 08:30 fedcba98-7654-3210-fedc-ba9876543210 -> ../../dm-1
```

### 4.2 Filesystem Creation

#### ext4 with Production Tuning

```bash
# Create ext4 filesystem optimized for database server
$ mkfs.ext4 -v -L "pgdata" \
    -b 4096 \
    -i 16384 \
    -J size=256 \
    -O has_journal,extent,huge_file,flex_bg,uninit_bg,dir_nlink,extra_isize,metadata_csum \
    -E stride=16,stripe-width=64,lazy_itable_init=0,lazy_journal_init=0,discard \
    /dev/mapper/vg0-data
mke2fs 1.47.0 (5-Feb-2023)
Creating filesystem with 26214400 4k blocks and 1638400 inodes
Filesystem UUID: 9f8e7d6c-5b4a-3928-1716-0f5e4d3c2b1a
Superblock backups stored on blocks:
        32768, 98304, 163840, 229376, 294912, 819200, 884736, 1605632, 2654208,
        4096000, 7962624, 11239424, 20480000, 23887872

Allocating group tables: done
Writing inode tables: done
Creating journal (16384 blocks): done
Writing superblocks and filesystem accounting information: done
```

#### XFS with Production Tuning

```bash
# Create XFS filesystem optimized for large sequential workloads
$ mkfs.xfs -f -L "pgdata" \
    -b size=4096 \
    -d agcount=16 \
    -l size=256m,lazy-count=1 \
    -i size=512 \
    /dev/mapper/vg0-data
meta-data=/dev/mapper/vg0-data   isize=512    agcount=16, agsize=1638400 blks
         =                       sectsz=512   attr=2, projid32bit=1
         =                       crc=1        finobt=1, sparse=1, rmapbt=0
         =                       reflink=1    bigtime=1 inobtcount=1 nrext64=0
data     =                       bsize=4096   blocks=26214400, imaxpct=25
         =                       sunit=0      swidth=0 blks
naming   =version 2              bsize=4096   ascii-ci=0, ftype=1
log      =internal log           bsize=4096   blocks=65536, version=2
         =                       sectsz=512   sunit=0 blks, lazy-count=1
realtime =none                   extsz=4096   blocks=0, rtextents=0
Discarding blocks...Done.
```

#### Btrfs with Compression and Subvolumes

```bash
# Create Btrfs filesystem
$ mkfs.btrfs -f -L "datastore" -d single -m dup /dev/sdb1
btrfs-progs v6.6.3
See https://btrfs.readthedocs.io for more information.

NOTE: severalass default option changes
Performing full device TRIM /dev/sdb1 (2.00TiB) ...
Label:              datastore
UUID:               abcdef01-2345-6789-abcd-ef0123456789
Node size:          16384
Sector size:        4096
Filesystem size:    2.00TiB
Block group profiles:
  Data:             single            8.00MiB
  Metadata:         DUP               1.00GiB
  System:           DUP               8.00MiB
SSD detected:       no
Zoned device:       no
Incompat features:  extref, skinny-metadata, no-holes, free-space-tree
Runtime features:
Checksum:           crc32c
Number of devices:  1
Devices:
   ID   SIZE  PATH
    1   2.00TiB  /dev/sdb1

# Mount and create subvolumes
$ mount /dev/sdb1 /mnt/tmp_btrfs

$ btrfs subvolume create /mnt/tmp_btrfs/@data
Create subvolume '/mnt/tmp_btrfs/@data'

$ btrfs subvolume create /mnt/tmp_btrfs/@snapshots
Create subvolume '/mnt/tmp_btrfs/@snapshots'

$ btrfs subvolume list /mnt/tmp_btrfs
ID 256 gen 7 top level 5 path @data
ID 257 gen 8 top level 5 path @snapshots

# Create a snapshot
$ btrfs subvolume snapshot -r /mnt/tmp_btrfs/@data /mnt/tmp_btrfs/@snapshots/data-20250115
Create a readonly snapshot of '/mnt/tmp_btrfs/@data' in '/mnt/tmp_btrfs/@snapshots/data-20250115'

# Mount specific subvolume
$ mount -o subvol=@data,compress=zstd:3,noatime /dev/sdb1 /srv/data
```

### 4.3 Filesystem Inspection and Tuning

#### ext4 Inspection

```bash
$ tune2fs -l /dev/mapper/vg0-root
tune2fs 1.47.0 (5-Feb-2023)
Filesystem volume name:   root
Last mounted on:          /
Filesystem UUID:          3a4b5c6d-7e8f-9a0b-1c2d-3e4f5a6b7c8d
Filesystem magic number:  0xEF53
Filesystem revision #:    1 (dynamic)
Filesystem features:      has_journal ext_attr resize_inode dir_index filetype needs_recovery extent 64bit flex_bg sparse_super large_file huge_file dir_nlink extra_isize metadata_csum
Filesystem flags:         signed_directory_hash
Default mount options:    user_xattr acl
Filesystem state:         clean
Errors behavior:          Remount read-only
Filesystem OS type:       Linux
Inode count:              1638400
Block count:              6553600
Reserved block count:     327680
Free blocks:              3743411
Free inodes:              1512243
First block:              0
Block size:               4096
Fragment size:            4096
Group descriptor size:    64
Reserved GDT blocks:      1024
Blocks per group:         32768
Fragments per group:      32768
Inodes per group:         8192
Inode blocks per group:   512
Flex block group size:    16
Filesystem created:       Mon Jan 15 08:00:00 2025
Last mount time:          Wed Jan 15 08:30:12 2025
Last write time:          Wed Jan 15 08:30:12 2025
Mount count:              15
Maximum mount count:      -1
Last checked:             Mon Jan 15 08:00:00 2025
Check interval:           0 (<none>)
Lifetime writes:          48 GB
Reserved blocks uid:      0 (user root)
Reserved blocks gid:      0 (group root)
First inode:              11
Inode size:               256
Required extra isize:     32
Desired extra isize:      32
Journal inode:            8
Default directory hash:   half_md4
Directory Hash Seed:      a1b2c3d4-e5f6-7890-abcd-ef0123456789
Journal backup:           inode blocks
Checksum type:            crc32c
Checksum:                 0x12345678
```

```bash
# Production tuning: adjust reserved blocks, set mount count checks
$ tune2fs -m 1 -c 50 -i 6m -e remount-ro /dev/mapper/vg0-root
tune2fs 1.47.0 (5-Feb-2023)
Setting reserved blocks percentage to 1% (65536 blocks)
Setting maximal mount count to 50
Setting interval between checks to 15552000 seconds
Setting error behavior to Remount read-only

# Set filesystem label
$ tune2fs -L "root" /dev/mapper/vg0-root
tune2fs 1.47.0 (5-Feb-2023)
```

```bash
# Deep filesystem inspection
$ dumpe2fs -h /dev/mapper/vg0-root 2>/dev/null | grep -E "^(Filesystem|Inode|Block|Free|Reserved|Journal)"
Filesystem volume name:   root
Filesystem UUID:          3a4b5c6d-7e8f-9a0b-1c2d-3e4f5a6b7c8d
Filesystem features:      has_journal ext_attr resize_inode dir_index filetype needs_recovery extent 64bit flex_bg sparse_super large_file huge_file dir_nlink extra_isize metadata_csum
Filesystem flags:         signed_directory_hash
Filesystem state:         clean
Filesystem OS type:       Linux
Inode count:              1638400
Block count:              6553600
Block size:               4096
Reserved block count:     65536
Free blocks:              3743411
Free inodes:              1512243
Journal inode:            8
Journal backup:           inode blocks
```

#### XFS Inspection

```bash
$ xfs_info /var/lib/postgresql
meta-data=/dev/mapper/vg0-data   isize=512    agcount=16, agsize=1638400 blks
         =                       sectsz=512   attr=2, projid32bit=1
         =                       crc=1        finobt=1, sparse=1, rmapbt=0
         =                       reflink=1    bigtime=1 inobtcount=1 nrext64=0
data     =                       bsize=4096   blocks=26214400, imaxpct=25
         =                       sunit=0      swidth=0 blks
naming   =version 2              bsize=4096   ascii-ci=0, ftype=1
log      =internal log           bsize=4096   blocks=65536, version=2
         =                       sectsz=512   sunit=0 blks, lazy-count=1
realtime =none                   extsz=4096   blocks=0, rtextents=0

$ xfs_admin -l /dev/mapper/vg0-data
label = "pgdata"

$ xfs_admin -u /dev/mapper/vg0-data
UUID = 9f8e7d6c-5b4a-3928-1716-0f5e4d3c2b1a
```

#### Btrfs Inspection

```bash
$ btrfs filesystem show /srv/data
Label: 'datastore'  uuid: abcdef01-2345-6789-abcd-ef0123456789
        Total devices 1 FS bytes used 552.34GiB
        devid    1 size 2.00TiB used 560.03GiB path /dev/sdb1

$ btrfs filesystem usage /srv/data
Overall:
    Device size:                   2.00TiB
    Device allocated:            560.03GiB
    Device unallocated:            1.45TiB
    Device missing:                  0.00B
    Device slack:                    0.00B
    Used:                        552.34GiB
    Free (estimated):              1.46TiB      (min: 756.31GiB)
    Free (statfs, currentlimit):   1.46TiB
    Data ratio:                       1.00
    Metadata ratio:                   2.00
    Global reserve:              512.00MiB      (used: 0.00B)
    Multiple profiles:                  no

Data,single: Size:558.00GiB, Used:550.81GiB (98.77%)
   /dev/sdb1     558.00GiB

Metadata,DUP: Size:1.00GiB, Used:783.75MiB (76.54%)
   /dev/sdb1       2.00GiB

System,DUP: Size:8.00MiB, Used:48.00KiB (0.59%)
   /dev/sdb1      16.00MiB

Unallocated:
   /dev/sdb1       1.45TiB

$ btrfs device stats /srv/data
[/dev/sdb1].write_io_errs    0
[/dev/sdb1].read_io_errs     0
[/dev/sdb1].flush_io_errs    0
[/dev/sdb1].corruption_errs  0
[/dev/sdb1].generation_errs  0
```

### 4.4 Mount Operations

```bash
# View currently mounted filesystems
$ mount | column -t
/dev/mapper/vg0-root  on  /                      type  ext4    (rw,noatime,errors=remount-ro,commit=60)
sysfs                 on  /sys                   type  sysfs   (rw,nosuid,nodev,noexec,relatime)
proc                  on  /proc                  type  proc    (rw,nosuid,nodev,noexec,relatime)
tmpfs                 on  /tmp                   type  tmpfs   (rw,nosuid,nodev,noexec,relatime,size=2097152k)
/dev/sda2             on  /boot                  type  ext4    (rw,noatime)
/dev/sda1             on  /boot/efi              type  vfat    (rw,relatime,fmask=0077,dmask=0077)
/dev/mapper/vg0-data  on  /var/lib/postgresql     type  xfs     (rw,noatime,attr2,inode64,logbufs=8,logbsize=256k,noquota)
/dev/sdb1             on  /srv/data              type  btrfs   (rw,noatime,compress=zstd:3,space_cache=v2,subvol=/@data)
/dev/mapper/data_crypt on /srv/encrypted         type  ext4    (rw,noatime)

# View from /proc (canonical source)
$ cat /proc/mounts | grep -v "^none"
/dev/mapper/vg0-root / ext4 rw,noatime,errors=remount-ro,commit=60 0 0
/dev/sda2 /boot ext4 rw,noatime 0 0
/dev/mapper/vg0-data /var/lib/postgresql xfs rw,noatime,attr2,inode64,logbufs=8,logbsize=262144,noquota 0 0

# Mount with specific options
$ mount -o remount,rw,noatime /

# Bind mount
$ mount --bind /var/lib/postgresql /backup/pg_source

# Check findmnt (structured view)
$ findmnt -t ext4,xfs,btrfs
TARGET                 SOURCE                FSTYPE OPTIONS
/                      /dev/mapper/vg0-root  ext4   rw,noatime,errors=remount-ro,commit=60
├─/boot                /dev/sda2             ext4   rw,noatime
├─/var/lib/postgresql  /dev/mapper/vg0-data  xfs    rw,noatime,attr2,inode64,logbufs=8,logbsize=262144,noquota
├─/srv/data            /dev/sdb1             btrfs  rw,noatime,compress=zstd:3,space_cache=v2,subvol=/@data
└─/srv/encrypted       /dev/mapper/data_crypt ext4  rw,noatime

# Verify fstab entries without actually mounting
$ findmnt --verify
Success, no errors or warnings detected
```

### 4.5 Swap Management

```bash
# View current swap status
$ swapon --show
NAME                  TYPE       SIZE  USED PRIO
/dev/mapper/vg0-swap  partition    4G  256M   10
/swapfile             file         2G    0B    5

$ cat /proc/swaps
Filename                                Type            Size            Used            Priority
/dev/dm-1                               partition       4194300         262144          10
/swapfile                               file            2097148         0               5

# Create a swap file
$ dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
2147483648 bytes (2.1 GB, 2.0 GiB) copied, 4.23 s, 508 MB/s
2048+0 records in
2048+0 records out
2147483648 bytes (2.1 GB, 2.0 GiB) copied, 4.22611 s, 508 MB/s

$ chmod 600 /swapfile

$ mkswap -L "swapfile" /swapfile
Setting up swapspace version 1, size = 2 GiB (2147479552 bytes)
LABEL=swapfile, UUID=aa11bb22-cc33-dd44-ee55-ff6677889900

$ swapon --priority 5 /swapfile

$ swapon --show
NAME                  TYPE       SIZE  USED PRIO
/dev/mapper/vg0-swap  partition    4G  256M   10
/swapfile             file         2G    0B    5

# Disable swap (e.g., for Kubernetes worker node)
$ swapoff -a

# Force sync all buffers to disk
$ sync
```

### 4.6 Filesystem Check and Repair

#### ext4 Repair

```bash
# Check ext4 (filesystem must be unmounted or read-only)
$ umount /dev/mapper/vg0-root
# Or from rescue/single-user mode:

$ e2fsck -f -v -C 0 /dev/mapper/vg0-root
e2fsck 1.47.0 (5-Feb-2023)
Pass 1: Checking inodes, blocks, and sizes
Pass 2: Checking directory structure
Pass 3: Checking directory connectivity
Pass 4: Checking reference counts
Pass 5: Checking group summary information

        126157 inodes used (7.70%, out of 1638400)
           541 non-contiguous files (0.4%)
           298 non-contiguous directories (0.2%)
             # of inodes with ind/dind/tind blocks: 0/0/0
             Extent depth histogram: 118462/347
      2810189 blocks used (42.88%, out of 6553600)
             0 bad blocks
             1 large file

        116238 regular files
          9891 directories
            19 character device files
             7 block device files
             0 fifos
           186 links
             0 sockets
             2 files

# Force check even if clean
$ e2fsck -f -y /dev/mapper/vg0-root

# Interactive debugging
$ debugfs /dev/mapper/vg0-root
debugfs 1.47.0 (5-Feb-2023)
debugfs:  stats
Filesystem volume name:   root
Filesystem UUID:          3a4b5c6d-7e8f-9a0b-1c2d-3e4f5a6b7c8d
...
debugfs:  ls -l /lost+found
      2   40755 (2)      0      0    16384 15-Jan-2025 08:00 .
      2   40755 (2)      0      0     4096 15-Jan-2025 08:00 ..
debugfs:  quit
```

#### XFS Repair

```bash
# XFS check (deprecated, use xfs_repair)
$ xfs_repair -n /dev/mapper/vg0-data    # -n = no-modify/dry-run
Phase 1 - find and verify superblock...
Phase 2 - using internal log
        - zero log...
        - scan filesystem freespace and inode maps...
        - found root inode chunk
Phase 3 - for each AG...
        - scan and clear agi unlinked lists...
        - process known inodes and perform inode discovery...
        - agno = 0
        - agno = 1
        ...
        - agno = 15
        - process newly discovered inodes...
Phase 4 - check for duplicate blocks...
        - setting up duplicate extent list...
        - check for inodes claiming duplicate blocks...
        - agno = 0
        ...
Phase 5 - rebuild AG headers and trees...
        - agno = 0
        ...
Phase 6 - check inode connectivity...
        - resetting contents of realtime bitmap and summary inodes
        - traversing filesystem ...
        - traversal finished ...
        - moving disconnected inodes to lost+found ...
Phase 7 - verify and correct link counts...
No modify flag set, skipping filesystem flush and execute.

# Actual repair
$ umount /var/lib/postgresql
$ xfs_repair /dev/mapper/vg0-data

# XFS dump and restore (migration/backup)
$ xfsdump -l 0 -f /backup/xfs_full.dump /var/lib/postgresql
xfsdump: using file dump (drive_simple) strategy
xfsdump: level 0 dump of prod-db01:/var/lib/postgresql
xfsdump: dump date: Wed Jan 15 12:00:00 2025
xfsdump: session id: aaaabbbb-cccc-dddd-eeee-ffff00001111
xfsdump: session label: "full_backup"
xfsdump: ino map phase 1: constructing initial dump list
xfsdump: ino map phase 2: skipping (no pruning necessary)
xfsdump: ino map phase 3: skipping (only one dump stream)
xfsdump: ino map construction complete
xfsdump: estimated dump size: 22524928 bytes
xfsdump: dump complete: 4 seconds elapsed
xfsdump: Dump Status: SUCCESS

$ xfsrestore -f /backup/xfs_full.dump /mnt/restore_target
```

### 4.7 LUKS Encryption Management

```bash
# Create LUKS encrypted volume
$ cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha512 \
    --iter-time 5000 \
    --pbkdf argon2id \
    /dev/sdc1

WARNING!
========
This will overwrite data on /dev/sdc1 irrevocably.

Are you sure? (Type 'yes' in capital letters): YES
Enter passphrase for /dev/sdc1:
Verify passphrase:

# Open (unlock) the encrypted volume
$ cryptsetup luksOpen /dev/sdc1 data_crypt
Enter passphrase for /dev/sdc1:

# Verify it's open
$ cryptsetup status data_crypt
/dev/mapper/data_crypt is active and is in use.
  type:    LUKS2
  cipher:  aes-xts-plain64
  keysize: 512 bits
  key location: keyring
  device:  /dev/sdc1
  sector size:  512
  offset:  32768 sectors
  size:    1048543232 sectors
  mode:    read/write

# Create filesystem on decrypted volume
$ mkfs.ext4 -L "encrypted" /dev/mapper/data_crypt

# LUKS header dump (backup this!)
$ cryptsetup luksDump /dev/sdc1
LUKS header information
Version:        2
Epoch:          3
Metadata area:  16384 [bytes]
Keyslots area:  16744448 [bytes]
UUID:           11223344-5566-7788-99aa-bbccddeeff00
Label:          (no label)
Subsystem:      (no subsystem)
Flags:          (no flags)

Data segments:
  0: crypt
        offset: 16777216 [bytes]
        length: (whole device)
        cipher: aes-xts-plain64
        sector: 512 [bytes]

Keyslots:
  0: luks2
        Key:        512 bits
        Priority:   normal
        Cipher:     aes-xts-plain64
        Cipher key: 512 bits
        PBKDF:      argon2id
        Time cost:  4
        Memory:     1048576
        Threads:    4
...

# Add a key file for automated unlock at boot
$ dd if=/dev/urandom of=/etc/keys/data.key bs=4096 count=1
$ chmod 400 /etc/keys/data.key
$ cryptsetup luksAddKey /dev/sdc1 /etc/keys/data.key
Enter any existing passphrase:

# Backup LUKS header (critical for disaster recovery)
$ cryptsetup luksHeaderBackup /dev/sdc1 \
    --header-backup-file /backup/luks_header_sdc1.bak
```

### 4.8 ISO/UDF Image Creation

```bash
# Create ISO9660 image with Rock Ridge and Joliet extensions
$ mkisofs -o /tmp/archive.iso \
    -V "ARCHIVE_2025" \
    -R -J \
    -joliet-long \
    -rational-rock \
    -input-charset utf-8 \
    /srv/data/archive/
  14.23% done, estimate finish Wed Jan 15 14:05:00 2025
  28.47% done, estimate finish Wed Jan 15 14:05:00 2025
  ...
 100.00% done, estimate finish Wed Jan 15 14:04:58 2025
Total translation table size: 0
Total rockridge attributes bytes: 24876
Total directory bytes: 98304
Path table size(bytes): 420
Max brk space used 2a000
1048576 extents written (2048 Mb)

# Alternative: xorrisofs (modern replacement)
$ xorrisofs -o /tmp/archive.iso \
    -V "ARCHIVE_2025" \
    -R -J \
    -joliet-long \
    /srv/data/archive/

# Create bootable ISO (El Torito)
$ xorrisofs -o /tmp/bootable.iso \
    -V "RESCUE_DISK" \
    -R -J \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    /srv/data/rescue_root/

# Write ISO to optical media
$ wodim -v dev=/dev/sr0 speed=8 -eject /tmp/archive.iso
# (cdrecord is the legacy command name, wodim is the current fork)

# Mount ISO image
$ mount -o loop,ro /tmp/archive.iso /mnt/iso
$ mount -t iso9660 -o loop,ro /tmp/archive.iso /mnt/iso
```

### 4.9 SMART Disk Health Monitoring

```bash
# Check if SMART is available and enabled
$ smartctl -i /dev/sda
smartctl 7.3 2022-02-28 r5338 [x86_64-linux-6.1.0-18-amd64] (local build)
Copyright (C) 2002-22, Bruce Allen, Christian Franke, www.smartmontools.org

=== START OF INFORMATION SECTION ===
Model Family:     Samsung SSD 870
Device Model:     Samsung SSD 870 EVO 1TB
Serial Number:    S5Y1NX0R123456B
LU WWN Device Id: 5 002538 f70abcdef
Firmware Version: SVT02B6Q
User Capacity:    1,000,204,886,016 bytes [1.00 TB]
Sector Size:      512 bytes logical/physical
Rotation Rate:    Solid State Device
Form Factor:      2.5 inches
TRIM Command:     Enabled
Device is:        In smartctl database
ATA Version is:   ACS-4 T13/BSR INCITS 529 revision 5
SATA Version is:  SATA 3.3, 6.0 Gb/s (current: 6.0 Gb/s)
Local Time is:    Wed Jan 15 14:00:00 2025 UTC
SMART support is: Available - device has SMART capability.
SMART support is: Enabled

# Full health check
$ smartctl -a /dev/sda
=== START OF READ SMART DATA SECTION ===
SMART overall-health self-assessment test result: PASSED

SMART Attributes Data Structure revision number: 1
Vendor Specific SMART Attributes with Thresholds:
ID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE
  5 Reallocated_Sector_Ct   0x0033   100   100   010    Pre-fail  Always       -       0
  9 Power_On_Hours          0x0032   096   096   000    Old_age   Always       -       18456
 12 Power_Cycle_Count       0x0032   098   098   000    Old_age   Always       -       47
177 Wear_Leveling_Count     0x0013   094   094   000    Pre-fail  Always       -       58
179 Used_Rsvd_Blk_Cnt_Tot   0x0013   100   100   010    Pre-fail  Always       -       0
181 Program_Fail_Cnt_Total  0x0032   100   100   010    Old_age   Always       -       0
182 Erase_Fail_Count_Total  0x0032   100   100   010    Old_age   Always       -       0
183 Runtime_Bad_Block        0x0013   100   100   010    Pre-fail  Always       -       0
187 Uncorrectable_Error_Cnt 0x0032   100   100   000    Old_age   Always       -       0
190 Airflow_Temperature_Cel 0x0032   073   060   000    Old_age   Always       -       27
195 ECC_Error_Rate          0x001a   200   200   000    Old_age   Always       -       0
199 CRC_Error_Count         0x003e   100   100   000    Old_age   Always       -       0
235 POR_Recovery_Count      0x0012   099   099   000    Old_age   Always       -       13
241 Total_LBAs_Written      0x0032   099   099   000    Old_age   Always       -       29834521632

# Run a short self-test
$ smartctl -t short /dev/sda
smartctl 7.3 2022-02-28 r5338 [x86_64-linux-6.1.0-18-amd64] (local build)
=== START OF OFFLINE IMMEDIATE AND SELF-TEST SECTION ===
Sending command: "Execute SMART Short self-test routine immediately in off-line mode".
Drive command "Execute SMART Short self-test routine immediately in off-line mode" successful.
Testing has begun.
Please wait 2 minutes for test to complete.
Test will complete after Wed Jan 15 14:03:00 2025 UTC
Use smartctl -X to abort test.

# Check test results
$ smartctl -l selftest /dev/sda
SMART Self-test log structure revision number 1
Num  Test_Description    Status                  Remaining  LifeTime(hours)  LBA_of_first_error
# 1  Short offline       Completed without error       00%     18456         -
```

#### `/etc/smartd.conf` (Daemon Configuration)

```bash
# /etc/smartd.conf - Monitor all SATA/SCSI disks
# -a = all SMART checks
# -o on = offline testing
# -S on = attribute autosave
# -s (S/../.././02) = short self-test every day at 2am
# -s (L/../../6/03) = long self-test every Saturday at 3am
# -m admin@example.com = send email on failure
# -M exec /usr/local/sbin/smart-alert.sh = execute script on failure

DEVICESCAN -a -o on -S on -s (S/../.././02|L/../../6/03) -m admin@example.com -M exec /usr/local/sbin/smart-alert.sh

# Or specific devices:
/dev/sda -a -o on -S on -s (S/../.././02|L/../../6/03) -m admin@example.com -W 4,35,45
/dev/sdb -a -o on -S on -s (S/../.././02|L/../../6/03) -m admin@example.com -W 4,35,45
```

### 4.10 AutoFS Operations

```bash
# Install and enable autofs
$ systemctl enable --now autofs.service

# Verify autofs is running
$ systemctl status autofs.service
● autofs.service - Automounts filesystems on demand
     Loaded: loaded (/lib/systemd/system/autofs.service; enabled; preset: enabled)
     Active: active (running) since Wed 2025-01-15 08:30:00 UTC; 5h 30min ago
       Docs: man:autofs(8)
   Main PID: 1234 (automount)
      Tasks: 6 (limit: 4915)
     Memory: 3.2M
        CPU: 124ms
     CGroup: /system.slice/autofs.service
             └─1234 /usr/sbin/automount --pid-file /var/run/autofs.pid

Jan 15 08:30:00 prod-server01 systemd[1]: Starting Automounts filesystems on demand...
Jan 15 08:30:00 prod-server01 automount[1234]: Starting automounter version 5.1.8...
Jan 15 08:30:00 prod-server01 systemd[1]: Started Automounts filesystems on demand.

# Debug mode (foreground, verbose)
$ automount -f -v -d
Starting automounter version 5.1.8, master map /etc/auto.master
using kernel protocol version 5.05
lookup_nss_read_master: reading master /etc/auto.master
do_master_list_reset: resetting master map list
  ...
  mount_mount: mount(nfs): calling mount -t nfs4 -o rw,soft,timeo=30,retrans=3,sec=krb5 nas01:/export/home/john /home/remote/john

# Trigger automount by accessing the path
$ ls /home/remote/john
Desktop  Documents  Downloads

# Check what's mounted via autofs
$ mount | grep autofs
/etc/auto.home on /home/remote type autofs (rw,relatime,fd=6,pgrp=1234,timeout=600,minproto=5,maxproto=5,indirect)
/etc/auto.projects on /mnt/projects type autofs (rw,relatime,fd=12,pgrp=1234,timeout=900,minproto=5,maxproto=5,indirect)

# Force reload after config change
$ systemctl reload autofs.service
# or
$ kill -HUP $(cat /var/run/autofs.pid)
```

### 4.11 systemd Mount/Automount Management

```bash
# Enable and start the automount unit
$ systemctl daemon-reload
$ systemctl enable --now srv-data.automount
Created symlink /etc/systemd/system/local-fs.target.wants/srv-data.automount → /etc/systemd/system/srv-data.automount.

# List all mount units
$ systemctl list-units --type=mount
UNIT                          LOAD   ACTIVE SUB     DESCRIPTION
-.mount                       loaded active mounted Root Mount
boot-efi.mount                loaded active mounted /boot/efi
boot.mount                    loaded active mounted /boot
srv-data.mount                loaded active mounted Data Volume Mount (XFS)
srv-encrypted.mount           loaded active mounted /srv/encrypted
tmp.mount                     loaded active mounted Temporary Directory
var-lib-postgresql.mount      loaded active mounted /var/lib/postgresql

# List all automount units
$ systemctl list-units --type=automount
UNIT                      LOAD   ACTIVE   SUB     DESCRIPTION
srv-data.automount        loaded active   waiting Automount Data Volume
mnt-nfs\x2dshare.automount loaded active  waiting NFS Share Automount

# Generate mount units from fstab for verification
$ systemctl list-unit-files --type=mount | grep generated
boot-efi.mount                         generated
boot.mount                             generated
srv-encrypted.mount                    generated

# Convert fstab entry name to systemd unit name
$ systemd-escape -p --suffix=mount /var/lib/postgresql
var-lib-postgresql.mount
```

---

## 5. Verification and Fault Diagnosis Guide

### 5.1 Systematic Diagnostic Flowchart

```
PROBLEM: Filesystem won't mount at boot
│
├─ 1. Check fstab syntax
│     $ findmnt --verify --tab-file /etc/fstab
│     $ mount -fav    # -f = fake (dry-run), -a = all, -v = verbose
│
├─ 2. Verify device exists
│     $ blkid | grep <UUID>
│     $ ls -la /dev/disk/by-uuid/<UUID>
│     $ lsblk -f
│
├─ 3. Check filesystem integrity
│     $ fsck -n /dev/<device>     # -n = no changes, read-only check
│     $ dmesg | grep -i "error\|fault\|fail\|corrupt"
│
├─ 4. Check mount dependencies
│     $ systemctl list-dependencies <mount-unit>
│     $ systemctl status <mount-unit>
│     $ journalctl -u <mount-unit> -b
│
├─ 5. Check for _netdev on network filesystems
│     # Missing _netdev = mount attempted before network is up
│     # Fix: add _netdev to fstab options
│
├─ 6. Check for nofail option
│     # Missing nofail = system drops to emergency mode if mount fails
│     # Production best practice: always add nofail for non-root mounts
│
└─ 7. Verify kernel module loaded
      $ lsmod | grep <fs_module>   # e.g., xfs, btrfs, nfs
      $ modprobe <fs_module>
```

### 5.2 Critical Production Scenarios

#### Scenario A: System Boots into Emergency Mode

```bash
# Symptom: Console shows:
# "You are in emergency mode. After logging in, type 'journalctl -xb' to view system logs"
# "Give root password for maintenance (or press Control-D to continue):"

# Root cause: A mount in /etc/fstab failed and doesn't have 'nofail'

# Diagnosis inside emergency shell:
$ journalctl -xb --no-pager | grep -i "mount\|fstab\|failed"
Jan 15 08:30:05 server systemd[1]: Mounting /srv/data...
Jan 15 08:30:15 server systemd[1]: srv-data.mount: Mount process exited, code=exited, status=32/n/a
Jan 15 08:30:15 server systemd[1]: srv-data.mount: Failed with result 'exit-code'.
Jan 15 08:30:15 server systemd[1]: Failed to mount /srv/data.
Jan 15 08:30:15 server systemd[1]: Dependency failed for Local File Systems.
Jan 15 08:30:15 server systemd[1]: local-fs.target: Job local-fs.target/start failed with result 'dependency'.

# Fix: edit fstab and add nofail
$ vi /etc/fstab
# Change:
# UUID=abcdef01-... /srv/data btrfs defaults,noatime 0 0
# To:
# UUID=abcdef01-... /srv/data btrfs defaults,noatime,nofail 0 0

$ systemctl daemon-reload
$ exit   # or Ctrl-D to continue boot
```

#### Scenario B: Filesystem Reports Read-Only Unexpectedly

```bash
# Symptom: Applications report "Read-only file system" errors
$ touch /srv/data/test
touch: cannot touch '/srv/data/test': Read-only file system

# Diagnosis:
$ mount | grep /srv/data
/dev/sdb1 on /srv/data type btrfs (ro,noatime,compress=zstd:3,space_cache=v2)

$ dmesg | tail -20
[185432.123456] BTRFS error (device sdb1): bdev /dev/sdb1 errs: wr 3, rd 0, flush 0, corrupt 0, gen 0
[185432.123789] BTRFS warning (device sdb1): too many errors, writeback error -5
[185432.124012] BTRFS error (device sdb1): remounting filesystem read-only

# The filesystem detected I/O errors and remounted read-only

# Check SMART for hardware issues:
$ smartctl -a /dev/sdb | grep -E "Reallocated|Uncorrectable|Pending"
  5 Reallocated_Sector_Ct   0x0033   098   098   010    Pre-fail  Always       -       42
197 Current_Pending_Sector  0x0032   098   098   000    Old_age   Always       -       16

# ^ Reallocated sectors > 0 = disk is failing!

# If disk is healthy, attempt remount rw:
$ mount -o remount,rw /srv/data

# For Btrfs specifically:
$ btrfs device stats /srv/data
[/dev/sdb1].write_io_errs    3
[/dev/sdb1].read_io_errs     0
[/dev/sdb1].flush_io_errs    0
[/dev/sdb1].corruption_errs  0
[/dev/sdb1].generation_errs  0

# Reset error counters after fixing the issue
$ btrfs device stats --reset /srv/data

# Run scrub to verify data integrity
$ btrfs scrub start /srv/data
$ btrfs scrub status /srv/data
UUID:             abcdef01-2345-6789-abcd-ef0123456789
Scrub started:    Wed Jan 15 15:00:00 2025
Status:           finished
Duration:         0:12:34
Total to scrub:   550.81GiB
Rate:             747.52MiB/s
Error summary:    no errors found
```

#### Scenario C: UUID Changed After Filesystem Recreation

```bash
# Problem: Admin recreated filesystem, UUID changed, fstab reference is stale

# Method 1: Set specific UUID on new filesystem
$ mkfs.ext4 -U 3a4b5c6d-7e8f-9a0b-1c2d-3e4f5a6b7c8d /dev/mapper/vg0-root

# Method 2: Change UUID of existing filesystem
$ tune2fs -U 3a4b5c6d-7e8f-9a0b-1c2d-3e4f5a6b7c8d /dev/mapper/vg0-root

# For XFS:
$ xfs_admin -U 9f8e7d6c-5b4a-3928-1716-0f5e4d3c2b1a /dev/mapper/vg0-data

# Method 3: Update fstab with new UUID
$ blkid /dev/mapper/vg0-root
/dev/mapper/vg0-root: UUID="NEW-UUID-HERE" TYPE="ext4"

$ sed -i 's/OLD-UUID/NEW-UUID/g' /etc/fstab
```

#### Scenario D: AutoFS NFS Mount Fails Silently

```bash
# Symptom: ls /home/remote/john shows empty directory

# Step 1: Check autofs service
$ systemctl status autofs
● autofs.service - Automounts filesystems on demand
     Loaded: loaded (/lib/systemd/system/autofs.service; enabled; preset: enabled)
     Active: active (running)

# Step 2: Run autofs in debug mode
$ systemctl stop autofs
$ automount -f -v -d 2>&1 | tee /tmp/autofs_debug.log

# In another terminal:
$ ls /home/remote/john

# In debug output look for:
# "mount_mount: mount(nfs): calling mount -t nfs4 ..."
# "mount(nfs): nfs: mount failure nas01:/export/home/john on /home/remote/john"
# ">> mount error: Connection timed out"

# Step 3: Test NFS connectivity directly
$ showmount -e nas01
Export list for nas01:
/export/home    192.168.1.0/24

$ mount -t nfs4 -o rw nas01:/export/home/john /mnt/test
mount.nfs4: access denied by server while mounting nas01:/export/home/john

# Root cause: NFS export ACL doesn't include this client's IP

# Step 4: Verify DNS and network
$ getent hosts nas01
192.168.1.10    nas01.example.com

$ ping -c 2 nas01
PING nas01 (192.168.1.10) 56(84) bytes of data.
64 bytes from 192.168.1.10: icmp_seq=1 ttl=64 time=0.284 ms

# Check RPC port connectivity
$ rpcinfo -p nas01
   program vers proto   port  service
    100000    4   tcp    111  portmapper
    100003    4   tcp   2049  nfs
    100005    3   tcp  20048  mountd
```

#### Scenario E: LUKS Volume Won't Unlock at Boot

```bash
# Symptom: Boot hangs at "A start job is running for Cryptography Setup for data_crypt"

# Root cause check: key file missing or permissions wrong
$ ls -la /etc/keys/data.key
-r-------- 1 root root 4096 Jan 15 08:00 /etc/keys/data.key

# If key file is on separate partition, check ordering in crypttab
# The key file's filesystem must be mounted BEFORE crypttab is processed

# Verify crypttab syntax
$ cat /etc/crypttab
data_crypt UUID=11223344-5566-7788-99aa-bbccddeeff00 /etc/keys/data.key luks,discard

# Test manual unlock
$ cryptsetup luksOpen --test-passphrase --key-file /etc/keys/data.key /dev/sdc1 && echo "OK" || echo "FAILED"
OK

# If using systemd-cryptsetup:
$ systemctl status systemd-cryptsetup@data_crypt.service
$ journalctl -u systemd-cryptsetup@data_crypt.service -b

# Regenerate initramfs if key file is needed in early boot
$ update-initramfs -u -k all     # Debian/Ubuntu
$ dracut --force                  # RHEL/Fedora
```

### 5.3 Production Monitoring One-Liners

```bash
# Check all filesystems for usage > 85%
$ df -h --output=pcent,target -x tmpfs -x devtmpfs | tail -n +2 | awk '{gsub(/%/,"",$1); if ($1+0 > 85) print "ALERT: " $2 " at " $1 "%"}'
ALERT: /var/lib/postgresql at 92%

# Check inode usage
$ df -i --output=ipcent,target -x tmpfs -x devtmpfs | tail -n +2 | awk '{gsub(/%/,"",$1); if ($1+0 > 80) print "INODE ALERT: " $2 " at " $1 "%"}'

# Monitor I/O latency per device
$ iostat -xz 5 1
Linux 6.1.0-18-amd64 (prod-server01)     01/15/2025      _x86_64_

avg-cpu:  %user   %nice %system %iowait  %steal   %idle
           4.21    0.00    1.83    0.42    0.00   93.54

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util
sda             12.40    198.40     0.60   4.62    0.38    16.00   45.60   1824.00    12.80  21.92    1.24    40.00    0.00      0.00     0.00   0.00    0.00     0.00    8.40    0.21    0.07   3.52
sdb              8.20    524.80     0.00   0.00    0.45    64.00   22.40   1433.60     4.20  15.79    2.38    64.00    0.00      0.00     0.00   0.00    0.00     0.00    0.00    0.00    0.06   2.14

# Detect filesystems mounted without noatime (performance issue)
$ mount | grep -E "ext[234]|xfs|btrfs" | grep -v noatime
/dev/sda2 on /boot type ext4 (rw,relatime)

# Verify all fstab entries are actually mounted
$ awk '$0 !~ /^#/ && $0 !~ /^$/ && $3 != "swap" {print $2}' /etc/fstab | while read mp; do
    if ! findmnt "$mp" > /dev/null 2>&1; then
        echo "WARNING: $mp listed in fstab but not mounted!"
    fi
done

# Check for pending sector errors on all disks
$ for disk in $(lsblk -dno NAME | grep -E "^sd|^nvme"); do
    pending=$(smartctl -A /dev/$disk 2>/dev/null | awk '/Current_Pending_Sector/{print $NF}')
    realloc=$(smartctl -A /dev/$disk 2>/dev/null | awk '/Reallocated_Sector/{print $NF}')
    [ "${pending:-0}" -gt 0 ] || [ "${realloc:-0}" -gt 0 ] && \
        echo "DISK ALERT: /dev/$disk pending=$pending reallocated=$realloc"
done
```

### 5.4 Quick Reference: Key File Locations

| File | Purpose |
|---|---|
| `/etc/fstab` | Static filesystem mount table |
| `/proc/mounts` | Currently mounted filesystems (canonical kernel view) |
| `/proc/swaps` | Active swap areas |
| `/proc/filesystems` | Kernel-supported filesystem types |
| `/etc/mtab` → `/proc/self/mounts` | Symlink to process mount namespace view |
| `/etc/crypttab` | Encrypted block device table |
| `/etc/auto.master` | AutoFS master map |
| `/etc/auto.master.d/*.autofs` | AutoFS drop-in directory |
| `/etc/auto.<name>` | AutoFS indirect/direct maps |
| `/etc/smartd.conf` | SMART daemon configuration |
| `/run/mount/utab` | User-space mount options (systemd) |
| `/etc/systemd/system/*.mount` | systemd mount units |
| `/etc/systemd/system/*.automount` | systemd automount units |

### 5.5 Essential `fstab` Options Reference for Production

| Option | Effect | Production Recommendation |
|---|---|---|
| `defaults` | rw,suid,dev,exec,auto,nouser,async | Explicit options preferred |
| `noatime` | No access-time updates | **Always** for servers (reduces writes) |
| `nodiratime` | No dir access-time (subset of noatime) | Implied by `noatime` |
| `nofail` | Don't fail boot if mount fails | **Required** for all non-root mounts |
| `_netdev` | Wait for network before mounting | **Required** for NFS, iSCSI, CIFS |
| `errors=remount-ro` | Remount read-only on error | Default for ext4 root |
| `discard` | Enable TRIM for SSDs | Use `fstrim.timer` instead (batched TRIM) |
| `commit=N` | Data sync interval in seconds | 60 for databases (journal protects) |
| `noexec` | Prevent execution of binaries | `/tmp`, `/var/tmp` security hardening |
| `nosuid` | Ignore SUID/SGID bits | `/tmp`, user-writable mounts |
| `nodev` | Ignore device files | `/tmp`, user-writable mounts |
| `x-systemd.automount` | systemd on-demand mount | NFS, rarely-used volumes |
| `x-systemd.idle-timeout=` | Unmount after idle period | NFS with automount |
| `x-systemd.requires=` | Declare dependency | Mounts depending on other units |

### 5.6 `dump` and `pass` Fields Explained

```
<dump>:  0 = don't include in dump(8) backups (most modern systems)
         1 = include in dump backups

<pass>:  0 = don't fsck at boot
         1 = fsck first (root filesystem only)
         2 = fsck after pass 1 completes (all other local filesystems)
         
Note: Btrfs and XFS set pass to 0 because they do their own
      integrity checking and don't use traditional fsck.
```

---

## 6. References

| Resource | URL |
|---|---|
| **LPIC-2 Exam 201 Objectives (v4.5)** | https://www.lpi.org/our-certifications/exam-201-objectives/ |
| **LPIC-2 Overview** | https://www.lpi.org/our-certifications/lpic-2-overview/ |
| **fstab(5) man page** | https://man7.org/linux/man-pages/man5/fstab.5.html |
| **mount(8) man page** | https://man7.org/linux/man-pages/man8/mount.8.html |
| **systemd.mount(5)** | https://www.freedesktop.org/software/systemd/man/latest/systemd.mount.html |
| **systemd.automount(5)** | https://www.freedesktop.org/software/systemd/man/latest/systemd.automount.html |
| **ext4 Documentation (kernel.org)** | https://www.kernel.org/doc/html/latest/filesystems/ext4/ |
| **XFS Documentation (kernel.org)** | https://www.kernel.org/doc/html/latest/filesystems/xfs.html |
| **Btrfs Documentation** | https://btrfs.readthedocs.io/en/latest/ |
| **Btrfs Wiki (kernel.org)** | https://btrfs.wiki.kernel.org/index.php/Main_Page |
| **LUKS/dm-crypt Documentation** | https://gitlab.com/cryptsetup/cryptsetup/-/wikis/home |
| **cryptsetup(8) man page** | https://man7.org/linux/man-pages/man8/cryptsetup.8.html |
| **AutoFS Documentation** | https://www.kernel.org/doc/html/latest/filesystems/autofs.html |
| **auto.master(5) man page** | https://man7.org/linux/man-pages/man5/auto.master.5.html |
| **smartmontools** | https://www.smartmontools.org/ |
| **blkid(8) man page** | https://man7.org/linux/man-pages/man8/blkid.8.html |
| **tune2fs(8) man page** | https://man7.org/linux/man-pages/man8/tune2fs.8.html |
| **xfs_repair(8) man page** | https://man7.org/linux/man-pages/man8/xfs_repair.8.html |
| **mkisofs / xorrisofs** | https://www.gnu.org/software/xorriso/ |
| **proc(5) - /proc/mounts, /proc/swaps** | https://man7.org/linux/man-pages/man5/proc.5.html |