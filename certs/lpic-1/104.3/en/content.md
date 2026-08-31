# 104.3 — Control mounting and unmounting of filesystems

**LPIC-1 · Exam 101-500 · Topic 104 (Devices, Linux Filesystems, Filesystem Hierarchy Standard) · Weight 4.69**

**Objective coverage:** manual mount/umount · mount configuration at boot · user-mountable removable filesystems · labels and UUIDs · awareness of systemd mount units.
**Terms and utilities:** `/etc/fstab`, `/media/`, `mount`, `umount`, `blkid`, `lsblk`.

---

## 1. Motivation: the architectural problem

Linux does not expose storage as lettered drives. It exposes a **single directed tree**, and every block device, network export, pseudo-filesystem and container layer has to be *grafted* into that tree at a directory called a **mount point**. The `mount` operation is the graft; `umount` is the amputation. Everything a production system does with persistent state — a database data directory, a container image store, a log volume, a shared artifact cache — depends on the right filesystem being attached at the right path, with the right options, at the right moment in the boot sequence.

That dependency is where outages come from. Four failure classes account for the overwhelming majority of storage-related incidents on Linux hosts:

**1. Non-deterministic device naming.** Kernel device names (`/dev/sda`, `/dev/nvme1n1`) are assigned in **probe order**, which is a function of driver initialization timing, PCIe enumeration and hypervisor attach order — none of which are contractual. A cloud instance that is stopped and started can come back with the volume formerly at `/dev/sdb` now at `/dev/sdc`. If `/etc/fstab` names devices, one of two things happens: the mount fails (visible, recoverable) or **the wrong filesystem mounts at the right path** (invisible, catastrophic — a replica's data directory mounted where the primary's belongs).

**2. The empty-mount-point shadow.** If `/srv/data` contains files and the mount fails, the application does not error out — it happily writes to the *underlying* directory on the root filesystem. The service is "up", the data is in the wrong place, monitoring is green, and the root filesystem fills up hours later. The inverse is equally common: a mount succeeds *over* a directory that already had data, and that data becomes unreachable (not deleted — shadowed) until the filesystem is unmounted.

**3. Boot-blocking fstab entries.** A `/etc/fstab` entry without `nofail` is a **hard boot dependency**. `systemd` waits for the device (default 90 s), then drops the machine into emergency mode and asks for the root password on a console you do not have. On a headless cloud instance this is functionally identical to destroying the machine. A one-line fstab edit is one of the few remaining ways to brick a Linux host remotely.

**4. Unclean detach.** A filesystem's dirty pages live in the page cache. `umount` flushes and marks the superblock clean; yanking the device, or `umount -l` on a filesystem with active writers, does not. The result is journal replay at best and silent corruption at worst — and, for XFS/ext4 on shared storage, a filesystem that another node then mounts while the first still holds it.

**The SRE framing:** a mount is a *declaration of dependency between a service and a durable resource*, and it must be expressed with a stable identifier, a bounded timeout, an explicit failure policy, and a verification step. `/etc/fstab` is the oldest infrastructure-as-code file on the system. Treat it as such.

---

## 2. Mechanics: what actually happens during a mount

### 2.1 The VFS layer

The kernel's **Virtual File System** layer is an abstraction that lets `open()`, `read()` and `stat()` work identically over ext4, XFS, NFS, tmpfs and procfs. Its four core objects:

| Object | Represents | Lifetime |
|---|---|---|
| `struct super_block` | One mounted filesystem instance (the on-disk metadata: block size, UUID, feature flags, per-fs options) | One per *filesystem*, shared by all its mounts |
| `struct inode` | One file object (metadata, no name) | Cached; one per file per superblock |
| `struct dentry` | One path component; binds a name to an inode | Cached aggressively (the dcache) |
| `struct file` | One open file description (offset, flags) | Per `open()` call |
| `struct mount` | One *attachment* of a superblock into a namespace at a path | One per mount point |

The last distinction is the one that trips people up: a single filesystem (one superblock) can be attached at many points simultaneously (bind mounts). **Some options belong to the superblock and are therefore global to all attachments; others belong to the individual attachment.**

| Option class | Examples | Scope | Can differ per bind mount? |
|---|---|---|---|
| VFS / per-mount flags | `ro`, `rw`, `nosuid`, `nodev`, `noexec`, `noatime`, `relatime`, `nodiratime`, `sync`, `nosymfollow` | `struct mount` | **Yes** |
| Superblock / per-fs options | `data=ordered`, `journal_checksum`, `discard`, `barrier`, `inode64`, `allocsize=`, `errors=remount-ro` | `struct super_block` | **No** — changing it changes it everywhere |
| Userspace-only options | `user`, `users`, `owner`, `group`, `noauto`, `_netdev`, `x-systemd.*`, `comment=` | `/run/mount/utab` | N/A (never reach the kernel) |

Consequence you will hit in practice: you can bind-mount `/srv/data` read-only at `/export/data` while it stays read-write at `/srv/data`, but you **cannot** have `discard` on one and not the other.

### 2.2 The syscall path

`mount(8)` is a thin wrapper over `libmount`. The classic syscall is:

```c
int mount(const char *source, const char *target, const char *filesystemtype,
          unsigned long mountflags, const void *data);
```

Since Linux 5.2 there is a second, decomposed API — `fsopen(2)`, `fsconfig(2)`, `fsmount(2)`, `move_mount(2)` — which separates *creating a configured filesystem context* from *attaching it to the tree*, and returns real error strings instead of a single `EINVAL`. `mount(8)` from util-linux 2.39+ uses it when available. This is why modern mount failures sometimes produce a specific diagnostic and sometimes still produce the infamous:

```
mount: /mnt/data: wrong fs type, bad option, bad superblock on /dev/sdb1,
       missing codepage or helper program, or other error.
       dmesg(1) may have more information after failed mount system call.
```

That message means "the kernel returned `EINVAL` and I cannot tell you why." **Always follow it with `dmesg`.**

### 2.3 Where the mount table lives

| Path | Content | Notes |
|---|---|---|
| `/proc/self/mounts` | Kernel view of *this process's* mount namespace | Authoritative for the kernel's opinion |
| `/etc/mtab` | Symlink → `/proc/self/mounts` on every modern distro | Historically a real file; never edit it |
| `/proc/self/mountinfo` | Kernel view **plus** mount IDs, propagation, subtree root | The one to parse; `findmnt` reads this |
| `/run/mount/utab` | Userspace-only options (`user=`, `x-systemd.*`, `helper=`) | Complements mountinfo |
| `/etc/fstab` | Desired state, not current state | Consumed by `mount -a` and the systemd generator |

A `mountinfo` line, decoded:

```
$ grep ' /srv/data ' /proc/self/mountinfo
142 60 253:2 / /srv/data rw,noatime,nodev,nosuid shared:78 - xfs /dev/mapper/vg_data-lv_data rw,attr2,inode64,logbufs=8,logbsize=32k,noquota
```

| Field | Value | Meaning |
|---|---|---|
| 1 | `142` | mount ID |
| 2 | `60` | parent mount ID (→ this is mounted under mount 60) |
| 3 | `253:2` | major:minor of the backing device |
| 4 | `/` | root of the mount *within* the filesystem (`/` = whole fs; a subpath = bind mount of a subtree) |
| 5 | `/srv/data` | mount point in the namespace |
| 6 | `rw,noatime,nodev,nosuid` | **per-mount** (VFS) options |
| 7..n | `shared:78` | optional propagation fields (`shared:`, `master:`, `propagate_from:`, `unbindable`) |
| — | `-` | separator |
| n+1 | `xfs` | filesystem type |
| n+2 | `/dev/mapper/...` | mount source |
| n+3 | `rw,attr2,inode64,...` | **superblock** options |

Field 6 vs. the last field is the practical way to answer "is this mount read-only, or is the filesystem read-only?"

### 2.4 Shared subtrees and propagation

Every mount carries a **propagation type** that decides whether mounts created underneath it are mirrored into peer namespaces:

| Type | Flag | Behaviour |
|---|---|---|
| `shared` | `--make-shared` | Mount/umount events propagate **both ways** between peers |
| `private` | `--make-private` | No propagation |
| `slave` | `--make-slave` | Receives events from the master, sends none back |
| `unbindable` | `--make-unbindable` | Cannot be bind-mounted (blocks recursive-bind explosions) |

Prefix `r` (`--make-rshared`) applies recursively. `systemd` sets `/` to `shared` at PID 1. This matters directly for CNCF work: a CSI node plugin or a `mountPropagation: Bidirectional` volume in Kubernetes only works because the host's `/` is `rshared` and the container runtime does not override it with `MountFlags=slave`.

```
$ findmnt -o TARGET,PROPAGATION / /var/lib/kubelet
TARGET          PROPAGATION
/               shared
/var/lib/kubelet shared
```

---

## 3. Identifying the device: names, LABEL, UUID, PARTUUID

This is the single highest-leverage decision in the whole topic.

| Identifier | Written in fstab as | Survives reorder? | Survives `mkfs`? | Survives clone/`dd`? | Set with | Notes |
|---|---|---|---|---|---|---|
| Kernel name `/dev/sdb1` | `/dev/sdb1` | ❌ | ✔ (name is not in the fs) | ✔ | — | **Never use in fstab** on multi-disk or cloud hosts |
| Filesystem **UUID** | `UUID=…` | ✔ | ❌ (regenerated) | ❌ **collides** | `tune2fs -U`, `xfs_admin -U`, `mkfs` | The default and correct choice |
| Filesystem **LABEL** | `LABEL=…` | ✔ | ❌ | ❌ **collides** | `e2label`, `xfs_admin -L`, `fatlabel` | Human-readable; must be unique per host |
| **PARTUUID** (GPT) | `PARTUUID=…` | ✔ | ✔ | ❌ collides | `sgdisk -u`, `sfdisk --part-uuid` | Survives reformatting — right for automation that re-creates filesystems |
| **PARTLABEL** (GPT) | `PARTLABEL=…` | ✔ | ✔ | ❌ collides | `sgdisk -c`, `sfdisk --part-label` | Same, human-readable |
| `/dev/disk/by-id/…` | full path | ✔ | ✔ | ✔ (serial is per-device) | udev, from device serial | Best for "this physical disk", e.g. ZFS/Ceph |
| `/dev/disk/by-path/…` | full path | ✔ (topology-stable) | ✔ | ✔ | udev, from bus topology | Stable per *slot*, not per disk |
| LVM `/dev/vg/lv` | full path | ✔ | ✔ | ⚠ VG UUID collides | LVM metadata | Stable; LVM resolves it |

> **The clone trap.** `dd`, `virt-clone` and volume snapshots copy the superblock, and therefore the UUID and LABEL. Two identically-UUID'd XFS filesystems on one host: the second `mount` fails outright. Two ext4: the second may mount, and `UUID=` in fstab becomes a coin flip. Always re-stamp a clone before attaching it.

**Reading identifiers**

```
$ lsblk -f
NAME          FSTYPE      FSVER LABEL  UUID                                 FSAVAIL FSUSE% MOUNTPOINTS
nvme0n1                                                                                    
├─nvme0n1p1   vfat        FAT32 EFI    A1B2-C3D4                             478.4M     6% /boot/efi
├─nvme0n1p2   ext4        1.0   boot   6f4a2e91-7c33-4a0e-9c11-2b7a5f0d81ce  598.1M    30% /boot
└─nvme0n1p3   LVM2_member LVM2  001    K3jd9f-1QpZ-8Lmc-0oTb-Yh2V-wQ4s-Rz7Nn                
  ├─vg0-root  ext4        1.0   root   9c8b7a65-0d1e-4f22-8a90-3c5b7e1d4402   24.1G    31% /
  └─vg0-swap  swap        1     swap   1a2b3c4d-5e6f-4071-8293-a4b5c6d7e8f9                [SWAP]
nvme1n1       xfs               data   b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752  198.3G     1% /srv/data
```

```
$ sudo blkid /dev/nvme1n1
/dev/nvme1n1: LABEL="data" UUID="b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752" BLOCK_SIZE="512" TYPE="xfs"

$ sudo blkid -s UUID -o value /dev/nvme1n1
b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752

$ sudo blkid -L data
/dev/nvme1n1

$ sudo blkid -U b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752
/dev/nvme1n1
```

`blkid` reads the on-disk signature (and a cache in `/run/blkid/blkid.tab`); `lsblk -f` reads udev's database. When they disagree, `blkid -p -o udev /dev/X` (low-level probe, bypassing the cache) is the tiebreaker.

```
$ ls -l /dev/disk/by-uuid/
total 0
lrwxrwxrwx 1 root root 13 Aug 26 09:14 1a2b3c4d-5e6f-4071-8293-a4b5c6d7e8f9 -> ../../dm-1
lrwxrwxrwx 1 root root 13 Aug 26 09:14 6f4a2e91-7c33-4a0e-9c11-2b7a5f0d81ce -> ../../nvme0n1p2
lrwxrwxrwx 1 root root 13 Aug 26 09:14 9c8b7a65-0d1e-4f22-8a90-3c5b7e1d4402 -> ../../dm-0
lrwxrwxrwx 1 root root 13 Aug 26 09:14 b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752 -> ../../nvme1n1
lrwxrwxrwx 1 root root 15 Aug 26 09:14 A1B2-C3D4 -> ../../nvme0n1p1
```

**Re-stamping a cloned filesystem**

```
# ext4 — filesystem must be unmounted and clean
$ sudo tune2fs -U random /dev/sdb1
tune2fs 1.47.0 (5-Feb-2023)
Setting the UUID on this filesystem could take some time.
Proceed anyway (or wait 5 seconds to proceed) ? (y,N) y
$ sudo e2label /dev/sdb1 data-replica

# XFS — must be unmounted; log must be clean (mount+umount once if it is not)
$ sudo xfs_admin -U generate -L data-replica /dev/sdb1
Clearing log and setting UUID
writing all SBs
new UUID = 4f2c1a90-8b7d-4e11-a2c6-90d5e3f81b44
```

---

## 4. Manual mounting: the full command surface

### 4.1 Basic forms

```
$ sudo mount /dev/nvme1n1 /srv/data                      # explicit device + target
$ sudo mount -t xfs /dev/nvme1n1 /srv/data               # explicit type (skips probing)
$ sudo mount UUID=b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752 /srv/data
$ sudo mount LABEL=data /srv/data
$ sudo mount /srv/data                                   # target only → looks up /etc/fstab
$ sudo mount -a                                          # everything in fstab not already mounted
$ sudo mount -a -t xfs,ext4                              # restrict -a to types
$ sudo mount -a -O no_netdev                             # restrict -a by fstab option
```

Without `-t`, `mount` calls `libblkid` to probe the on-disk signature; `-t` skips that. `-t auto` is the explicit default. `-t nfs4,cifs` in `-a` context filters rather than forces.

### 4.2 Inspecting current mounts

```
$ mount | column -t | head -6
sysfs      on  /sys              type  sysfs       (rw,nosuid,nodev,noexec,relatime)
proc       on  /proc             type  proc        (rw,nosuid,nodev,noexec,relatime)
devtmpfs   on  /dev              type  devtmpfs    (rw,nosuid,size=4096k,nr_inodes=2043177,mode=755)
tmpfs      on  /dev/shm          type  tmpfs       (rw,nosuid,nodev,inode64)
/dev/mapper/vg0-root  on  /      type  ext4        (rw,relatime,errors=remount-ro)
/dev/nvme1n1  on  /srv/data      type  xfs         (rw,noatime,nodev,nosuid,attr2,inode64,logbufs=8,logbsize=32k,noquota)
```

Bare `mount` prints `/proc/self/mounts` — noisy. **`findmnt` is the correct tool** and should be your reflex:

```
$ findmnt /srv/data
TARGET    SOURCE       FSTYPE OPTIONS
/srv/data /dev/nvme1n1 xfs    rw,noatime,nodev,nosuid,attr2,inode64,logbufs=8,logbsize=32k,noquota

$ findmnt -o TARGET,SOURCE,FSTYPE,VFS-OPTIONS,FS-OPTIONS /srv/data
TARGET    SOURCE       FSTYPE VFS-OPTIONS               FS-OPTIONS
/srv/data /dev/nvme1n1 xfs    rw,noatime,nodev,nosuid   rw,attr2,inode64,logbufs=8,logbsize=32k,noquota

$ findmnt --real --df
SOURCE               FSTYPE SIZE  USED AVAIL USE% TARGET
/dev/mapper/vg0-root ext4    40G 12.4G 25.6G  33% /
/dev/nvme0n1p2       ext4   974M  291M  598M  30% /boot
/dev/nvme0n1p1       vfat   511M   33M  478M   6% /boot/efi
/dev/nvme1n1         xfs    200G  1.7G  198G   1% /srv/data

$ findmnt --fstab                # what SHOULD be mounted
$ findmnt --mtab                 # what IS mounted (default)
$ findmnt -S UUID=b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752   # find by source
$ findmnt -t nfs4,nfs            # find by type
$ findmnt --poll --target /srv/data   # block and stream mount-table changes
```

`findmnt --poll` is exceptionally useful in incident response: it prints an event line the instant something mounts, unmounts or remounts your target.

### 4.3 The option catalogue

`defaults` = `rw,suid,dev,exec,auto,nouser,async`.

| Option | Effect | Production guidance |
|---|---|---|
| `rw` / `ro` | Read-write / read-only mount | `ro` for reference data, `/boot` on hardened builds, and pre-snapshot quiescing |
| `suid` / `nosuid` | Honour / ignore setuid & setgid bits | `nosuid` on every filesystem that accepts untrusted content: `/tmp`, `/var/tmp`, `/dev/shm`, `/home`, all removable media |
| `dev` / `nodev` | Honour / ignore device special files | `nodev` everywhere except `/dev`. A device node on a user-writable fs is a root escalation path |
| `exec` / `noexec` | Allow / block direct execution | `noexec` on `/tmp`, `/var/tmp`, `/dev/shm`. **Not a security boundary** — `ld.so /tmp/x` still works — but it stops the lazy 90% |
| `auto` / `noauto` | Included in / excluded from `mount -a` | `noauto` for removable media and on-demand mounts |
| `nouser` / `user` / `users` | Who may mount | `user`: any user may mount, **only that user may unmount**. `users`: any user may mount and any user may unmount |
| `owner` / `group` | Non-root may mount if they own the *device node* / are in its group | Combines with udev rules for removable media |
| `async` / `sync` | Buffered / synchronous writes | `sync` costs 10–100× throughput. Use `sync` only on removable media that users yank |
| `dirsync` | Directory updates synchronous | Cheaper middle ground than full `sync` |
| `atime` / `noatime` / `relatime` / `nodiratime` | Access-time update policy | See table below |
| `lazytime` | Timestamps kept in memory, flushed on other I/O or every 24 h | Combine with `relatime` on write-heavy metadata workloads |
| `nofail` | Boot proceeds if the mount fails | **Mandatory on every non-essential mount on a headless host** |
| `_netdev` | Filesystem needs the network | Orders after `network-online.target`, into `remote-fs.target` |
| `nosymfollow` | Symlinks in this mount are not followed (Linux 5.10+) | Hardening for shared upload directories |
| `errors=continue\|remount-ro\|panic` | ext2/3/4 behaviour on error | `remount-ro` is the sane default; `panic` for clustered nodes that must fence themselves |
| `discard` / `nodiscard` | Inline TRIM | Prefer `nodiscard` + `fstrim.timer`; inline discard stalls on many SSDs |
| `X-mount.mkdir[=mode]` | Create the mount point if missing (util-linux 2.35+) | Handy in provisioning; `X-` = not stored in utab |
| `X-mount.owner=`, `X-mount.group=`, `X-mount.mode=` | Set ownership/mode of the mount point (2.39+) | |
| `x-systemd.*` | systemd generator directives (§6) | `x-` = stored in utab, readable by systemd |

**Access-time policy trade-offs**

| Option | Write on read? | POSIX-conformant | Breaks |
|---|---|---|---|
| `strictatime` | Every read | ✔ | Throughput on read-heavy workloads |
| `relatime` (kernel default since 2.6.30) | Only if atime < mtime/ctime, or atime > 24 h old | Approximately | Nothing in practice |
| `nodiratime` | Suppresses only directory atime | Partially | Nothing |
| `noatime` | Never | ✘ | `mutt`/`mbox` "new mail" detection, some tmpwatch policies |

For a database or a container image store, `noatime` is correct and measurable. For a general-purpose server, `relatime` is already fine — the "`noatime` for performance" advice largely predates `relatime`.

### 4.4 Remounting

```
$ sudo mount -o remount,ro /srv/data
$ sudo mount -o remount,rw /                       # classic emergency-shell recovery
$ sudo mount -o remount /srv/data                  # re-apply fstab options
```

A remount does **not** reset unspecified options to defaults; `mount` merges the command line with what it finds in `/etc/fstab` and `/run/mount/utab`. Since util-linux 2.32 you can control that merge explicitly:

```
$ sudo mount -o remount --options-mode=ignore --options-source-force -o rw,noatime /srv/data
```

| `--options-mode` | Result |
|---|---|
| `ignore` | Use only the command line |
| `append` | fstab options first, command line last (wins) |
| `prepend` | Command line first, fstab last (wins) |
| `replace` | Command line replaces fstab (default) |

**Do not assume — verify with `findmnt` after every remount.** This is the number-one source of "I set `ro` and it's still `rw`".

### 4.5 Bind mounts, loop mounts, overlays

```
# Bind: attach an existing subtree at a second path (same superblock)
$ sudo mount --bind /srv/data/pg /var/lib/postgresql/16/main
$ sudo mount --rbind /srv/data /export/data          # recursive: carries nested mounts
$ sudo mount --move /mnt/staging /srv/data           # relocate a mount, no unmount

# Read-only bind. util-linux >= 2.27 does the required second remount for you:
$ sudo mount -o bind,ro /srv/reference /export/reference
# On older util-linux this is two steps and the first one is NOT read-only:
$ sudo mount --bind /srv/reference /export/reference
$ sudo mount -o remount,bind,ro /export/reference

# Loop: mount a file as if it were a block device
$ sudo mount -o loop,ro debian-12.5.0-amd64-netinst.iso /mnt/iso
$ sudo mount -t iso9660 -o ro,loop image.iso /mnt/iso
$ losetup -a
/dev/loop0: [0053]:1835013 (/root/debian-12.5.0-amd64-netinst.iso)

# Overlay: the container-image primitive, exposed directly
$ sudo mkdir -p /ovl/{lower,upper,work,merged}
$ sudo mount -t overlay overlay \
    -o lowerdir=/ovl/lower,upperdir=/ovl/upper,workdir=/ovl/work \
    /ovl/merged

# tmpfs: RAM-backed, sized, with explicit permissions
$ sudo mount -t tmpfs -o size=2G,mode=1777,nosuid,nodev,noexec tmpfs /tmp
```

### 4.6 Dry runs

```
$ sudo mount --fake --verbose /srv/data
mount: /srv/data does not contain SELinux labels.
mount: /dev/nvme1n1 mounted on /srv/data.

$ sudo mount -a --fake --verbose
/                        : ignored
/boot                    : already mounted
/srv/data                : successfully mounted
```

`--fake` parses everything and performs the userspace work but skips the `mount(2)` call. It catches syntax errors and missing mount points; it does **not** prove the filesystem is mountable.

---

## 5. `/etc/fstab`: the complete anatomy

### 5.1 Field semantics

```
<file system>   <mount point>   <type>   <options>   <dump>   <pass>
     1                2            3          4         5        6
```

| # | Field | Values | Notes |
|---|---|---|---|
| 1 | Source | `UUID=`, `LABEL=`, `PARTUUID=`, `PARTLABEL=`, device path, `server:/export`, `//server/share`, `tmpfs`, `overlay`, `none` | Whitespace must be escaped as `\040` |
| 2 | Target | Absolute path, or `none` for swap/bind sources | Must exist (or use `X-mount.mkdir`) |
| 3 | Type | `ext4`, `xfs`, `btrfs`, `vfat`, `nfs4`, `cifs`, `tmpfs`, `swap`, `auto`, `none` (for bind) | `auto` probes; costs a little boot time |
| 4 | Options | Comma-separated, **no spaces** | `defaults` if you need a placeholder |
| 5 | `dump` | `0` or `1` | Consumed by `dump(8)`, which nobody runs. Always `0` |
| 6 | `pass` (fsck order) | `0` = never check · `1` = check first (root only) · `2` = check after the `1`s, in parallel across distinct disks | `0` for network, tmpfs, bind, btrfs (self-checking) and swap |

### 5.2 A complete, production `/etc/fstab`

```
# /etc/fstab — host: db-prod-03  ·  managed by Ansible (role: baseline/storage)
# Rebuild:  ansible-playbook site.yml --tags storage --limit db-prod-03
#
# <file system>                              <mount point>       <type>  <options>                                                                       <dump> <pass>

# --- Root and boot -----------------------------------------------------------
UUID=9c8b7a65-0d1e-4f22-8a90-3c5b7e1d4402    /                   ext4    rw,relatime,errors=remount-ro                                                    0      1
UUID=6f4a2e91-7c33-4a0e-9c11-2b7a5f0d81ce    /boot               ext4    rw,relatime,nodev,nosuid,noexec                                                  0      2
UUID=A1B2-C3D4                               /boot/efi           vfat    rw,relatime,nodev,nosuid,noexec,umask=0077,shortname=winnt,errors=remount-ro     0      2

# --- Swap --------------------------------------------------------------------
UUID=1a2b3c4d-5e6f-4071-8293-a4b5c6d7e8f9    none                swap    sw,pri=10                                                                        0      0

# --- Hardened scratch space (CIS 1.1.x) --------------------------------------
tmpfs                                        /tmp                tmpfs   rw,nosuid,nodev,noexec,relatime,size=4G,mode=1777                                 0      0
tmpfs                                        /dev/shm            tmpfs   rw,nosuid,nodev,noexec,relatime,size=1G                                          0      0
/tmp                                         /var/tmp            none    rw,nosuid,nodev,noexec,bind                                                      0      0

# --- Database data volume ----------------------------------------------------
# nofail + device-timeout: a detached EBS/Cinder volume must NOT block boot.
UUID=b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752    /srv/data           xfs     rw,noatime,nodev,nosuid,logbsize=256k,nofail,x-systemd.device-timeout=15s        0      2

# PostgreSQL expects its data at the packaged path; bind instead of relocating.
/srv/data/pgdata                             /var/lib/postgresql none    rw,bind,x-systemd.requires-mounts-for=/srv/data                                  0      0

# --- WAL archive on a separate spindle, read-mostly ---------------------------
PARTUUID=1f0d5c3b-2a44-4e77-9b81-6c0e2f4a7d99 /srv/wal-archive   xfs     rw,noatime,nodev,nosuid,noexec,nofail,x-systemd.device-timeout=15s               0      2

# --- Shared artifact store (NFS, lazily mounted on first access) --------------
nfs-01.internal:/exports/artifacts           /mnt/artifacts      nfs4    rw,noatime,nodev,nosuid,_netdev,noauto,x-systemd.automount,x-systemd.idle-timeout=600,x-systemd.mount-timeout=30,hard,proto=tcp,rsize=1048576,wsize=1048576  0  0

# --- Read-only reference dataset, mounted from an image file -----------------
/opt/images/geoip-2026-08.squashfs           /opt/geoip          squashfs ro,loop,nodev,nosuid,noexec,nofail                                              0      0

# --- Removable media: any console user may mount and unmount ------------------
LABEL=FIELD-BACKUP                           /media/field-backup auto    rw,users,noauto,nofail,nodev,nosuid,noexec,sync,uid=1000,gid=1000,umask=0007     0      0
```

Points worth internalising from that file:

- `/var/tmp` is a **bind of `/tmp`** — type `none`, option `bind`, pass `0`. That is the fstab syntax for a bind mount.
- The PostgreSQL bind carries `x-systemd.requires-mounts-for=/srv/data`, because otherwise systemd may try the bind before the XFS volume is up and bind an empty directory. This is the classic self-inflicted data-loss bug.
- Every removable and network entry has `nofail`. Every device-backed entry that is not `/` has an `x-systemd.device-timeout`.
- The NFS entry is `noauto,x-systemd.automount`: nothing blocks boot; the mount happens on the first access to `/mnt/artifacts` and is torn down after 600 s idle.
- `pass` is `2` for local data volumes and `0` for everything network-, loop- or bind-backed.

### 5.3 fstab hygiene rules

1. **Edit with a backup and validate before rebooting.** `cp /etc/fstab /etc/fstab.$(date +%F-%H%M)`.
2. **Never leave `/` un-`nofail`'d, and never `nofail` `/` itself** — the root filesystem's failure must stop the boot.
3. **After editing, tell systemd:** `sudo systemctl daemon-reload`. The fstab-generator only runs at boot and on reload; `mount -a` alone leaves systemd's view stale, and the next `systemctl` operation may unmount what you just mounted.
4. **`mount -a` is a necessary but insufficient test.** It proves the entries parse and the devices are present *now*; it proves nothing about boot-time ordering or device availability at boot.

```
$ sudo cp -a /etc/fstab /etc/fstab.2026-08-26-0914
$ sudoedit /etc/fstab
$ sudo findmnt --verify --verbose
$ sudo mount -a
$ sudo systemctl daemon-reload
$ findmnt --fstab --evaluate
```

---

## 6. systemd mount units

### 6.1 The generator

`systemd-fstab-generator(8)` runs at early boot and on every `daemon-reload`, and converts every `/etc/fstab` line into a transient `.mount` (and, where requested, `.automount`) unit under `/run/systemd/generator/`. **fstab is not "the legacy path" — on a systemd host it is a front-end to mount units.** Everything you write in fstab becomes a unit; you can read the generated unit to see exactly what systemd understood.

Unit names are the mount path with `/` replaced by `-`, escaped:

```
$ systemd-escape -p --suffix=mount /srv/data
srv-data.mount
$ systemd-escape -p --suffix=mount /var/lib/postgresql
var-lib-postgresql.mount
$ systemd-escape -u -p --suffix=mount srv-data.mount     # unescape
/srv/data
```

The root mount is the special name `-.mount`.

```
$ systemctl list-units --type=mount
UNIT                     LOAD   ACTIVE SUB     DESCRIPTION
-.mount                  loaded active mounted Root Mount
boot.mount               loaded active mounted /boot
boot-efi.mount           loaded active mounted /boot/efi
dev-shm.mount            loaded active mounted /dev/shm
srv-data.mount           loaded active mounted /srv/data
srv-wal\x2darchive.mount loaded active mounted /srv/wal-archive
tmp.mount                loaded active mounted /tmp
var-lib-postgresql.mount loaded active mounted /var/lib/postgresql

$ systemctl cat srv-data.mount
# /run/systemd/generator/srv-data.mount
# Automatically generated by systemd-fstab-generator

[Unit]
Documentation=man:fstab(5) man:systemd-fstab-generator(8)
SourcePath=/etc/fstab
Before=local-fs.target

[Mount]
Where=/srv/data
What=/dev/disk/by-uuid/b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752
Type=xfs
Options=rw,noatime,nodev,nosuid,logbsize=256k,nofail,x-systemd.device-timeout=15s
TimeoutSec=15s

$ systemctl show -p After -p Requires -p WantedBy srv-data.mount
After=systemd-journald.socket system.slice -.mount local-fs-pre.target blockdev@dev-disk-by\x2duuid...target
Requires=-.mount
WantedBy=local-fs.target
```

### 6.2 `x-systemd.*` options (fstab → unit directives)

| Option | Generated effect |
|---|---|
| `x-systemd.automount` | Also emit an `.automount` unit — mount on first access |
| `x-systemd.idle-timeout=600` | Automount unmounts after 600 s idle |
| `x-systemd.device-timeout=15s` | How long to wait for the *device* to appear |
| `x-systemd.mount-timeout=30s` | How long the `mount(8)` call itself may take |
| `x-systemd.requires=<unit>` | `Requires=` on an arbitrary unit |
| `x-systemd.after=` / `x-systemd.before=` | Explicit ordering |
| `x-systemd.requires-mounts-for=<path>` | Order after (and require) whatever provides `<path>` |
| `x-systemd.wanted-by=` / `x-systemd.required-by=` | Change which target pulls it in |
| `x-systemd.makefs` | Run `mkfs` if the device has no filesystem (**destructive-adjacent — provisioning only**) |
| `x-systemd.growfs` | Grow the filesystem to fill the device at mount time |
| `x-systemd.rw-only` | Do not fall back to a read-only mount on failure |
| `x-systemd.device-bound=no` | Do not unmount when the backing device disappears |
| `nofail` | Drop from `Requires=` to `Wants=` and remove the ordering barrier |
| `noauto` | Do not add to any target's `Wants=` |
| `_netdev` | Attach to `remote-fs.target`, order after `network-online.target` |

### 6.3 Native unit files

Write native units when you need dependencies fstab cannot express — a mount that must start after a specific service, or one with `ExecStartPre` semantics upstream of it.

**`/etc/systemd/system/srv-data.mount`**

```ini
[Unit]
Description=Primary data volume (XFS on nvme1n1)
Documentation=https://runbooks.internal/storage/srv-data
DefaultDependencies=no
Requires=blockdev@dev-disk-by\x2duuid-b7c9d2e4\x2d3f10\x2d4d5a\x2d9e88\x2d11ac33bd7752.target
After=blockdev@dev-disk-by\x2duuid-b7c9d2e4\x2d3f10\x2d4d5a\x2d9e88\x2d11ac33bd7752.target
After=local-fs-pre.target
Before=local-fs.target umount.target
Conflicts=umount.target

[Mount]
What=/dev/disk/by-uuid/b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752
Where=/srv/data
Type=xfs
Options=rw,noatime,nodev,nosuid,logbsize=256k
TimeoutSec=30s
DirectoryMode=0755
LazyUnmount=no
ForceUnmount=no

[Install]
WantedBy=local-fs.target
```

**`/etc/systemd/system/mnt-artifacts.automount`** (paired with a `.mount` of the same name)

```ini
[Unit]
Description=Automount for the shared artifact store
Documentation=man:systemd.automount(5)
After=network-online.target
Wants=network-online.target

[Automount]
Where=/mnt/artifacts
DirectoryMode=0755
TimeoutIdleSec=600

[Install]
WantedBy=remote-fs.target
```

**`/etc/systemd/system/mnt-artifacts.mount`**

```ini
[Unit]
Description=Shared artifact store (NFSv4)
After=network-online.target
Wants=network-online.target

[Mount]
What=nfs-01.internal:/exports/artifacts
Where=/mnt/artifacts
Type=nfs4
Options=rw,noatime,nodev,nosuid,hard,proto=tcp,rsize=1048576,wsize=1048576
TimeoutSec=30s
```

**The unit filename must match `Where=` after escaping**, or systemd refuses to load it:

```
$ sudo systemd-analyze verify /etc/systemd/system/srv-data.mount
$ sudo systemctl daemon-reload
$ sudo systemctl enable --now srv-data.mount
Created symlink /etc/systemd/system/local-fs.target.wants/srv-data.mount → /etc/systemd/system/srv-data.mount.
$ systemctl status srv-data.mount
● srv-data.mount - Primary data volume (XFS on nvme1n1)
     Loaded: loaded (/etc/systemd/system/srv-data.mount; enabled; preset: disabled)
     Active: active (mounted) since Tue 2026-08-26 09:14:31 UTC; 4h 2min ago
      Where: /srv/data
       What: /dev/nvme1n1
      Tasks: 0 (limit: 38304)
     Memory: 132.0K
        CPU: 6ms
     CGroup: /system.slice/srv-data.mount
```

### 6.4 Making a service depend on a mount

Never rely on `After=srv-data.mount` alone in a drop-in — use `RequiresMountsFor=`, which resolves the path to whatever unit provides it (fstab-generated or native):

**`/etc/systemd/system/postgresql@16-main.service.d/10-storage.conf`**

```ini
[Unit]
RequiresMountsFor=/var/lib/postgresql/16/main
```

That single line converts "database wrote to the root filesystem because the volume was late" from an incident into a startup dependency.

### 6.5 Transient mounts

```
$ sudo systemd-mount --no-block /dev/sdc1 /mnt/inspect
$ sudo systemd-mount --list
$ sudo systemd-mount --automount=yes --timeout-idle-sec=300 /dev/sdc1 /mnt/inspect
$ sudo systemd-umount /mnt/inspect
```

`systemd-mount` creates a transient unit rather than an unmanaged mount, so systemd will unmount it cleanly at shutdown and will not fight you over it.

### 6.6 Choosing a mechanism

| | `/etc/fstab` | Native `.mount` unit | `.automount` | `autofs` | `udisks2` |
|---|---|---|---|---|---|
| Portable across init systems | ✔ | ✘ | ✘ | ✔ | ✔ |
| Mounted at boot | ✔ | ✔ | on access | on access | on plug/login |
| Rich dependency ordering | via `x-systemd.*` | ✔ full | ✔ | ✘ | ✘ |
| Wildcard / map-driven targets | ✘ | ✘ | ✘ | ✔ (`*` maps, `-hosts`) | ✘ |
| Survives a flaky NFS server at boot | with `noauto,x-systemd.automount` | with automount | ✔ | ✔ | N/A |
| Unprivileged user mounts | via `user`/`users` | ✘ | ✘ | ✘ | ✔ (polkit) |
| Right for | 95% of servers | complex ordering | rarely-used network mounts | large/dynamic home & share maps | desktops, field laptops |

---

## 7. User-mountable and removable filesystems

### 7.1 The fstab route: `user`, `users`, `owner`, `group`

| Option | Who may mount | Who may unmount | Implies |
|---|---|---|---|
| `user` | Any user | **Only the user who mounted it** | `noexec,nosuid,nodev` |
| `users` | Any user | Any user | `noexec,nosuid,nodev` |
| `owner` | The owner of the *device node* | Same | `nosuid,nodev` |
| `group` | Members of the device node's group | Same | `nosuid,nodev` |

The implied restrictions are applied **first**, so ordering matters:

```
# noexec is in force — 'user' applied it and nothing overrode it
LABEL=USB   /media/usb  auto  rw,user,noauto  0 0

# exec is in force — it appears AFTER 'user' and wins
LABEL=USB   /media/usb  auto  rw,user,exec,noauto  0 0

# WRONG: 'user' re-applies its defaults after 'exec'
LABEL=USB   /media/usb  auto  rw,exec,user,noauto  0 0
```

Mounting as a normal user requires `mount` to be setuid root (it is, on most distros) and a matching fstab entry — the kernel does not consult fstab, `mount(8)` does:

```
$ id
uid=1000(sre) gid=1000(sre) groups=1000(sre),27(sudo),6(disk)

$ mount /media/field-backup
$ findmnt /media/field-backup
TARGET              SOURCE    FSTYPE OPTIONS
/media/field-backup /dev/sdc1 exfat  rw,nosuid,nodev,noexec,relatime,uid=1000,gid=1000,fmask=0007,dmask=0007,sync,user=sre

$ grep field-backup /run/mount/utab
SRC=/dev/sdc1 TARGET=/media/field-backup ROOT=/ OPTS=user=sre

$ umount /media/field-backup           # succeeds: user=sre matches
```

The `user=sre` field in `/run/mount/utab` is precisely how `umount` enforces "only the mounting user may unmount". Note also that FAT/exFAT/NTFS have no UNIX ownership on disk, so `uid=`, `gid=`, `umask=`/`fmask=`/`dmask=` are how you assign it at mount time.

### 7.2 `/media` vs `/mnt` (FHS)

| Path | FHS meaning |
|---|---|
| `/mnt` | A single, temporary mount point for the **system administrator** |
| `/media` | Parent directory for **removable media** mount points, one subdirectory per device |
| `/run/media/$USER/<label>` | Where `udisks2` actually puts things on modern desktops (per-user, tmpfs-backed, disappears on logout) |

Do not mount long-lived service data under either. `/srv` (site-specific service data) or an application-owned path is the correct home.

### 7.3 The `udisks2` + polkit route

For interactive users, `udisks2` is the modern answer: a privileged D-Bus daemon that mounts on request under `/run/media/$USER/`, with authorization decided by polkit. No fstab entry, no setuid `mount`.

```
$ udisksctl status
MODEL                     REVISION  SERIAL               DEVICE
--------------------------------------------------------------------------
SanDisk Ultra             1.00      4C530001120830108271 sdc

$ udisksctl mount --block-device /dev/sdc1
Mounted /dev/sdc1 at /run/media/sre/FIELD-BACKUP

$ findmnt /run/media/sre/FIELD-BACKUP
TARGET                        SOURCE    FSTYPE OPTIONS
/run/media/sre/FIELD-BACKUP   /dev/sdc1 exfat  rw,nosuid,nodev,relatime,uid=1000,gid=1000,...

$ udisksctl unmount --block-device /dev/sdc1
Unmounted /dev/sdc1.

$ udisksctl power-off --block-device /dev/sdc    # flush + safely detach the whole device
```

**Grant the `storage` group the right to mount system-internal devices** — full polkit rule, `/etc/polkit-1/rules.d/50-udisks-storage.rules`:

```javascript
/* Allow members of the 'storage' group to mount, unmount and eject
 * removable and system-internal block devices via udisks2 without a
 * password prompt. Deliberately does NOT grant filesystem-modify
 * (mkfs / partition table edits), which stays with the admin rules.
 *
 * Docs: https://www.freedesktop.org/software/polkit/docs/latest/polkit.8.html
 */
polkit.addRule(function (action, subject) {
    var allowed = [
        "org.freedesktop.udisks2.filesystem-mount",
        "org.freedesktop.udisks2.filesystem-mount-system",
        "org.freedesktop.udisks2.filesystem-unmount-others",
        "org.freedesktop.udisks2.eject-media",
        "org.freedesktop.udisks2.power-off-drive"
    ];

    if (allowed.indexOf(action.id) >= 0 && subject.isInGroup("storage")) {
        return polkit.Result.YES;
    }
});

polkit.addRule(function (action, subject) {
    /* Everything that reformats or repartitions still requires admin auth. */
    if (action.id.indexOf("org.freedesktop.udisks2.modify-device") === 0 ||
        action.id == "org.freedesktop.udisks2.filesystem-take-ownership") {
        return polkit.Result.AUTH_ADMIN_KEEP;
    }
});
```

Per-device policy lives in `/etc/udisks2/mount_options.conf`:

```ini
# /etc/udisks2/mount_options.conf
# Force hardening flags on every udisks2-managed mount.
# Docs: https://github.com/storaged-project/udisks/blob/master/doc/udisks2.8.xml

[defaults]
defaults=nosuid,nodev,noexec,relatime
allow=nosuid,nodev,noexec,relatime,noatime,sync,dirsync,uid=$UID,gid=$GID,umask,dmask,fmask,ro,rw

vfat_defaults=uid=$UID,gid=$GID,shortname=mixed,utf8=1,showexec,flush
exfat_defaults=uid=$UID,gid=$GID,iocharset=utf8,errors=remount-ro
ntfs_defaults=uid=$UID,gid=$GID,windows_names
iso9660_defaults=uid=$UID,gid=$GID,iocharset=utf8,mode=0400,dmode=0500
```

### 7.4 The `autofs` route

For map-driven mounts (hundreds of home directories, per-user NFS shares), `autofs` remains the right tool.

**`/etc/auto.master`**

```
# /etc/auto.master — autofs(5) master map
#
# Format: <mount-point> <map> [<options>]
# Docs: https://man7.org/linux/man-pages/man5/auto.master.5.html

/-          /etc/auto.direct        --timeout=120
/mnt/nfs    /etc/auto.nfs           --timeout=300 --ghost
/home/net   /etc/auto.home          --timeout=600 --ghost
/net        -hosts                  --timeout=60
+auto.master
```

**`/etc/auto.direct`** (direct map — absolute targets)

```
/opt/toolchain    -fstype=nfs4,ro,nodev,nosuid,soft,retrans=2   nfs-01.internal:/exports/toolchain
/opt/geoip        -fstype=squashfs,ro,loop,nodev,nosuid,noexec  :/opt/images/geoip-2026-08.squashfs
```

**`/etc/auto.nfs`** (indirect map — keys relative to `/mnt/nfs`)

```
artifacts   -fstype=nfs4,rw,noatime,nodev,nosuid,hard,proto=tcp   nfs-01.internal:/exports/artifacts
backups     -fstype=nfs4,ro,noatime,nodev,nosuid,noexec,hard      nfs-02.internal:/exports/backups
```

**`/etc/auto.home`** (wildcard map — `/home/net/alice` → `nfs-01:/exports/home/alice`)

```
*   -fstype=nfs4,rw,noatime,nodev,nosuid,hard,proto=tcp   nfs-01.internal:/exports/home/&
```

```
$ sudo systemctl enable --now autofs
$ sudo automount --dumpmaps
$ ls /home/net/alice          # triggers the mount
$ findmnt -t nfs4 /home/net/alice
TARGET          SOURCE                              FSTYPE OPTIONS
/home/net/alice nfs-01.internal:/exports/home/alice nfs4   rw,noatime,nodev,nosuid,hard,proto=tcp,...
```

---

## 8. Unmounting: the busy-mount problem

### 8.1 Command forms

```
$ sudo umount /srv/data              # by mount point — preferred, unambiguous
$ sudo umount /dev/nvme1n1           # by device — ambiguous if bind-mounted
$ sudo umount -R /export             # recursive: unmount everything under it too
$ sudo umount -a -t nfs4,nfs         # all mounts of given types
$ sudo umount -a -O _netdev          # all mounts carrying an fstab option
$ sudo umount -v /srv/data           # verbose
```

Only the mount point is unambiguous. A filesystem bind-mounted at three paths, unmounted by device, detaches only one — and `umount(8)` will tell you so.

### 8.2 When it is busy

```
$ sudo umount /srv/data
umount: /srv/data: target is busy.
```

Diagnose before you escalate:

```
$ sudo fuser -vm /srv/data
                     USER        PID ACCESS COMMAND
/srv/data:           root     kernel mount /srv/data
                     postgres   1842 F..c. postgres
                     postgres   1907 F...m postgres
                     sre        4210 ..c.. bash
```

`ACCESS` flags: `c` = cwd · `e` = running executable · `f` = open file · `F` = open file **for writing** · `r` = root directory · `m` = mmap'd file or shared library.

```
$ sudo lsof +f -- /srv/data | head
COMMAND    PID     USER   FD   TYPE DEVICE SIZE/OFF     NODE NAME
postgres  1842 postgres  cwd    DIR  259,0     4096      128 /srv/data/pgdata
postgres  1842 postgres    7uW  REG  259,0 16777216      131 /srv/data/pgdata/pg_wal/00000001...
bash      4210      sre  cwd    DIR  259,0     4096      128 /srv/data

# Deleted-but-still-open files also pin a mount, and lsof is the only way to see them:
$ sudo lsof -n /srv/data | grep '(deleted)'
java     8877 app   14w   REG  259,0 2147483648  4099 /srv/data/logs/app.log (deleted)

# A mount can also be pinned by another mount namespace (a container):
$ sudo lsns -t mnt
        NS TYPE NPROCS   PID USER   COMMAND
4026531840 mnt     231     1 root   /sbin/init
4026532571 mnt       1  9912 root   /pause
$ sudo nsenter -t 9912 -m findmnt | grep srv-data
```

### 8.3 Escalation ladder

| Step | Command | Effect | Risk |
|---|---|---|---|
| 1 | `fuser -vm` / `lsof` | Identify holders | none |
| 2 | Stop the service properly | `systemctl stop postgresql@16-main` | none — **this is almost always the fix** |
| 3 | `cd` out of it | Your own shell is often the culprit | none |
| 4 | `sudo umount /srv/data` | Retry | none |
| 5 | `sudo fuser -km /srv/data` | `SIGKILL` every holder | Kills processes with unflushed application state |
| 6 | `sudo mount -o remount,ro /srv/data` | Stop further writes; flushes and lets you snapshot | Application errors on write |
| 7 | `sudo umount -f /srv/data` | Force — **only meaningful for unreachable NFS** | Discards in-flight RPCs |
| 8 | `sudo umount -l /srv/data` | Lazy: detach from the tree now, release when the last reference closes | **See below** |

**Why `umount -l` is not a solution.** The mount vanishes from `/proc/self/mounts`, so the operator believes it is gone — but the superblock is still live, the device is still held, and the writers are still writing into a filesystem nobody can see or check. If you then re-mount the same device elsewhere, or the storage layer hands the LUN to another node, you get concurrent mounts of one filesystem: guaranteed corruption. Use `-l` only when you are unmounting something you intend to abandon entirely, and even then, confirm the device is truly released:

```
$ sudo umount -l /srv/data
$ findmnt /srv/data          # empty — looks clean
$ sudo lsof -n | grep 259,0  # NOT empty — writers survive
java   8877 app  14w  REG  259,0  2147483648  4099 /srv/data/logs/app.log
$ ls -l /sys/class/block/nvme1n1/holders/   # still held
$ sudo blockdev --flushbufs /dev/nvme1n1
```

### 8.4 Clean detach and quiescing

```
# Guaranteed-durable ordering before removing a device
$ sudo sync -f /srv/data                 # flush this filesystem only
$ sudo umount /srv/data
$ echo $?
0
$ sudo blockdev --flushbufs /dev/nvme1n1

# Consistent snapshot WITHOUT unmounting: freeze the filesystem
$ sudo fsfreeze --freeze /srv/data
$ sudo lvcreate --snapshot --size 20G --name lv_data_snap /dev/vg_data/lv_data
  Logical volume "lv_data_snap" created.
$ sudo fsfreeze --unfreeze /srv/data

# Verify the unmount was clean (ext4)
$ sudo dumpe2fs -h /dev/vg0-root 2>/dev/null | grep -E 'Filesystem state|Mount count|Last checked'
Filesystem state:         clean
Mount count:              47
Last checked:             Tue Jun  3 11:02:14 2026
```

`fsfreeze` blocks all writes and flushes the journal, giving a crash-consistent *and* filesystem-consistent snapshot. **Never leave a filesystem frozen** — every writer blocks in `D` state until you unfreeze, including your own shell if you `cd` into it.

---

## 9. Infrastructure manifests

### 9.1 cloud-init — partition, format, and mount a data volume at first boot

```yaml
#cloud-config
# /var/lib/cloud/seed/nocloud/user-data
# Docs: https://cloudinit.readthedocs.io/en/latest/reference/modules.html#mounts
#       https://cloudinit.readthedocs.io/en/latest/reference/modules.html#disk-setup

disk_setup:
  /dev/nvme1n1:
    table_type: gpt
    layout:
      - [100, 83]          # one partition, 100% of the device, type 83 (Linux)
    overwrite: false       # NEVER true on a volume that may already hold data

fs_setup:
  - label: data
    filesystem: xfs
    device: /dev/nvme1n1
    partition: 1
    overwrite: false
    extra_opts:
      - "-m"
      - "crc=1,finobt=1"
      - "-i"
      - "size=512"

# Applied to any 'mounts' entry that omits a field.
mount_default_fields: [None, None, "auto", "defaults,nofail", "0", "2"]

mounts:
  # [ source, mountpoint, type, options, dump, pass ]
  - ["LABEL=data", "/srv/data", "xfs",
     "rw,noatime,nodev,nosuid,logbsize=256k,nofail,x-systemd.device-timeout=15s,X-mount.mkdir=0755",
     "0", "2"]

  - ["/srv/data/pgdata", "/var/lib/postgresql", "none",
     "rw,bind,x-systemd.requires-mounts-for=/srv/data,X-mount.mkdir=0700",
     "0", "0"]

  - ["tmpfs", "/tmp", "tmpfs",
     "rw,nosuid,nodev,noexec,relatime,size=4G,mode=1777",
     "0", "0"]

  # Remove any legacy ephemeral entry the image shipped with.
  - ["ephemeral0", null]

  - ["nfs-01.internal:/exports/artifacts", "/mnt/artifacts", "nfs4",
     "rw,noatime,nodev,nosuid,_netdev,noauto,x-systemd.automount,x-systemd.idle-timeout=600,hard,proto=tcp",
     "0", "0"]

swap:
  filename: /swap.img
  size: 4294967296          # 4 GiB
  maxsize: 4294967296

runcmd:
  - [systemctl, daemon-reload]
  - [findmnt, --verify, --verbose]
  - [install, -d, -o, postgres, -g, postgres, -m, "0700", /srv/data/pgdata]
  - [systemctl, restart, local-fs.target]

final_message: "storage ready after $UPTIME seconds"
```

### 9.2 Ansible — idempotent, verified mount management

```yaml
---
# roles/storage/tasks/main.yml
# Docs: https://docs.ansible.com/ansible/latest/collections/ansible/posix/mount_module.html

- name: Resolve the filesystem UUID of the data volume
  ansible.builtin.command:
    cmd: "blkid -s UUID -o value {{ storage_data_device }}"
  register: storage_data_uuid
  changed_when: false
  failed_when: storage_data_uuid.stdout | length != 36

- name: Ensure the mount point exists with the correct ownership
  ansible.builtin.file:
    path: "{{ storage_data_mountpoint }}"
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Ensure the data volume is present in fstab and mounted
  ansible.posix.mount:
    path: "{{ storage_data_mountpoint }}"
    src: "UUID={{ storage_data_uuid.stdout }}"
    fstype: xfs
    opts: >-
      rw,noatime,nodev,nosuid,logbsize=256k,nofail,
      x-systemd.device-timeout=15s
    dump: "0"
    passno: "2"
    state: mounted          # present=fstab only · mounted=fstab+mount · absent=unmount+remove
    boot: true
  notify: reload systemd

- name: Ensure the PostgreSQL bind mount depends on the data volume
  ansible.posix.mount:
    path: /var/lib/postgresql
    src: "{{ storage_data_mountpoint }}/pgdata"
    fstype: none
    opts: "rw,bind,x-systemd.requires-mounts-for={{ storage_data_mountpoint }}"
    dump: "0"
    passno: "0"
    state: mounted
  notify: reload systemd

- name: Harden the scratch filesystems (CIS 1.1.2 - 1.1.9)
  ansible.posix.mount:
    path: "{{ item.path }}"
    src: "{{ item.src }}"
    fstype: "{{ item.fstype }}"
    opts: "{{ item.opts }}"
    dump: "0"
    passno: "0"
    state: mounted
  loop:
    - { path: /tmp,     src: tmpfs, fstype: tmpfs, opts: "rw,nosuid,nodev,noexec,relatime,size=4G,mode=1777" }
    - { path: /dev/shm, src: tmpfs, fstype: tmpfs, opts: "rw,nosuid,nodev,noexec,relatime,size=1G" }
    - { path: /var/tmp, src: /tmp,  fstype: none,  opts: "rw,nosuid,nodev,noexec,bind" }
  notify: reload systemd

- name: Ensure the service will not start before its storage
  ansible.builtin.copy:
    dest: /etc/systemd/system/postgresql@16-main.service.d/10-storage.conf
    owner: root
    group: root
    mode: "0644"
    content: |
      # Managed by Ansible (role: storage)
      [Unit]
      RequiresMountsFor=/var/lib/postgresql
  notify: reload systemd

# --- Verification: assert the running state, do not trust the task result ----

- name: Read the live mount table
  ansible.builtin.command:
    cmd: "findmnt --json --target {{ storage_data_mountpoint }}"
  register: storage_findmnt
  changed_when: false

- name: Assert the data volume is mounted with the intended VFS flags
  ansible.builtin.assert:
    that:
      - _opts is search('noatime')
      - _opts is search('nodev')
      - _opts is search('nosuid')
      - _opts is not search('(^|,)ro(,|$)')
    fail_msg: "Effective options on {{ storage_data_mountpoint }} are '{{ _opts }}'"
    success_msg: "{{ storage_data_mountpoint }} mounted correctly"
  vars:
    _opts: "{{ (storage_findmnt.stdout | from_json).filesystems[0].options }}"

- name: Validate that fstab will not break the next boot
  ansible.builtin.command:
    cmd: findmnt --verify --verbose
  register: storage_fstab_verify
  changed_when: false
  failed_when: "'0 errors' not in storage_fstab_verify.stdout"
```

```yaml
---
# roles/storage/handlers/main.yml
- name: reload systemd
  ansible.builtin.systemd_service:
    daemon_reload: true
```

```yaml
---
# roles/storage/defaults/main.yml
storage_data_device: /dev/nvme1n1
storage_data_mountpoint: /srv/data
```

### 9.3 Kubernetes — where host mount semantics surface

A CSI node plugin has to create mounts inside its container that the kubelet (outside the container) can see. That requires `mountPropagation: Bidirectional`, which requires the host's `/` to be `rshared` — which is the shared-subtree mechanism from §2.4.

```yaml
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: csi-node-driver
  namespace: kube-system
  labels:
    app.kubernetes.io/name: csi-node-driver
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: csi-node-driver
  template:
    metadata:
      labels:
        app.kubernetes.io/name: csi-node-driver
    spec:
      hostNetwork: true
      priorityClassName: system-node-critical
      tolerations:
        - operator: Exists
      containers:
        - name: node-driver
          image: registry.example.com/csi/node-driver:v1.12.0
          securityContext:
            privileged: true                 # required for mount(2) inside the container
            capabilities:
              add: ["SYS_ADMIN"]
            allowPrivilegeEscalation: true
          args:
            - "--endpoint=unix:///csi/csi.sock"
            - "--nodeid=$(NODE_ID)"
          env:
            - name: NODE_ID
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          volumeMounts:
            - name: plugin-dir
              mountPath: /csi
            - name: pods-mount-dir
              mountPath: /var/lib/kubelet/pods
              mountPropagation: Bidirectional   # mounts made here appear on the host
            - name: device-dir
              mountPath: /dev
            - name: host-sys
              mountPath: /sys
              readOnly: true
            - name: host-run-udev
              mountPath: /run/udev
              readOnly: true
      volumes:
        - name: plugin-dir
          hostPath:
            path: /var/lib/kubelet/plugins/csi.example.com
            type: DirectoryOrCreate
        - name: pods-mount-dir
          hostPath:
            path: /var/lib/kubelet/pods
            type: Directory
        - name: device-dir
          hostPath:
            path: /dev
            type: Directory
        - name: host-sys
          hostPath:
            path: /sys
            type: Directory
        - name: host-run-udev
          hostPath:
            path: /run/udev
            type: Directory
```

Node-side prerequisites, verified with the same tools as everything else:

```
$ findmnt -o TARGET,PROPAGATION -T /var/lib/kubelet
TARGET       PROPAGATION
/            shared

# If it prints 'private', bidirectional propagation silently does nothing:
$ sudo mount --make-rshared /
# Persist it:
$ cat /etc/systemd/system/make-rshared.service
[Unit]
Description=Ensure / is a shared mount for CSI mount propagation
DefaultDependencies=no
After=local-fs.target
Before=containerd.service kubelet.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/mount --make-rshared /

[Install]
WantedBy=multi-user.target

# containerd/docker must not re-privatise it:
$ systemctl show containerd -p MountFlags
MountFlags=
```

---

## 10. Verification and failure diagnosis

### 10.1 The pre-reboot checklist

Run these five commands, in order, every time you change `/etc/fstab`. They cost seconds and they are the difference between a reboot and an outage.

```
$ sudo findmnt --verify --verbose
/
   [ ] target exists
   [ ] FS type is ext4
   [ ] source UUID=9c8b7a65-0d1e-4f22-8a90-3c5b7e1d4402 exists
/srv/data
   [ ] target exists
   [ ] FS type is xfs
   [ ] source UUID=b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752 exists
/mnt/artifacts
   [W] non-bind mount source nfs-01.internal:/exports/artifacts is a directory or file

0 parse errors, 0 errors, 1 warning

$ sudo mount -a --fake --verbose         # 2. does every entry parse and resolve?
$ sudo mount -a                          # 3. does every entry actually mount now?
$ sudo systemctl daemon-reload           # 4. regenerate the mount units
$ systemctl --failed --type=mount        # 5. did any unit fail?
0 loaded units listed.
```

Then confirm the *effective* state matches the *intended* state — the two disagree more often than anyone expects:

```
$ findmnt --fstab --evaluate      # fstab with UUID/LABEL resolved to devices
TARGET              SOURCE                       FSTYPE  OPTIONS
/                   /dev/mapper/vg0-root         ext4    rw,relatime,errors=remount-ro
/boot               /dev/nvme0n1p2               ext4    rw,relatime,nodev,nosuid,noexec
/srv/data           /dev/nvme1n1                 xfs     rw,noatime,nodev,nosuid,...

$ diff <(findmnt --fstab -o TARGET,SOURCE -n --evaluate | sort) \
       <(findmnt --mtab  -o TARGET,SOURCE -n --real     | sort)
```

### 10.2 Symptom → cause → command

| Symptom | Most likely cause | Diagnostic | Fix |
|---|---|---|---|
| `wrong fs type, bad option, bad superblock` | Wrong `-t`, missing kernel module or userspace helper, or a genuine superblock problem | `dmesg \| tail -20` · `blkid /dev/X` · `lsmod \| grep xfs` | Correct the type; `modprobe`; install `nfs-common`/`cifs-utils`/`exfatprogs` |
| `Filesystem has duplicate UUID … can't mount` (XFS) | Cloned volume | `sudo blkid -s UUID /dev/sd*` | `xfs_admin -U generate /dev/sdX1` while unmounted |
| `special device UUID=… does not exist` | Filesystem was reformatted; UUID changed | `blkid` vs `grep UUID /etc/fstab` | Update fstab from live `blkid` output |
| `mount point does not exist` | Directory not created | `ls -ld /srv/data` | `mkdir -p`, or add `X-mount.mkdir=0755` |
| `only root can do that` as a normal user | No `user`/`users` in fstab, or path spelled differently | `grep /media /etc/fstab` | Add `user`/`users`; the path must match exactly |
| `umount: not mounted by you` | Mounted by another user with `user` | `grep <target> /run/mount/utab` | Use `users` instead of `user`, or unmount as that user / root |
| `target is busy` | Open files, cwd, mmap, or another namespace | `fuser -vm <t>` · `lsof <t>` · `lsns -t mnt` | Stop the service; last resort §8.3 |
| Boot drops to emergency mode | fstab entry without `nofail`, device absent | `journalctl -b -u local-fs.target` · `systemctl --failed` | `mount -o remount,rw /` → fix fstab → `systemctl daemon-reload` → `systemctl default` |
| Filesystem is read-only unexpectedly | `errors=remount-ro` fired on an I/O error | `dmesg \| grep -iE 'ext4|I/O error|remount'` · `smartctl -a /dev/X` | **Do not just remount rw** — find the hardware fault first |
| Disk full but `du` shows little | A filesystem is mounted *over* the data, or deleted-open files | `du -sh` vs `df -h` · `lsof \| grep deleted` · unmount and re-check | Restart the holder; fix the shadowing mount |
| Data written "disappears" after reboot | The mount silently failed; the app wrote to the underlying directory | `sudo umount /srv/data && ls -la /srv/data` (must be empty) | Add `RequiresMountsFor=` to the service unit |
| `mount -a` works, boot does not | Ordering/dependency problem, not a syntax problem | `systemd-analyze critical-chain local-fs.target` · `systemd-analyze plot > boot.svg` | Add `x-systemd.requires-mounts-for=` / `x-systemd.after=` |
| NFS mount hangs forever | `hard` mount + unreachable server (correct behaviour) | `findmnt -t nfs4` · `rpcinfo -p <server>` · `ss -tn state established '( dport = :2049 )'` | Restore the server; `umount -f -l` to abandon; `noauto,x-systemd.automount` to prevent boot impact |
| Ordering cycle at boot | Circular unit dependencies from `x-systemd.*` | `journalctl -b \| grep -i 'ordering cycle'` | Remove the redundant `x-systemd.after=` |

### 10.3 Worked failure #1 — the boot-blocking fstab entry

```
# Emergency console after a reboot:
You are in emergency mode. After logging in, type "journalctl -xb" to view
system logs, "systemctl reboot" to reboot, or "exit" to continue bootup.
Give root password for maintenance (or press Control-D to continue):

# ---------------------------------------------------------------------------
root@db-prod-03:~# systemctl --failed
  UNIT           LOAD   ACTIVE SUB    DESCRIPTION
● srv-data.mount loaded failed failed /srv/data
1 loaded units listed.

root@db-prod-03:~# journalctl -b -u srv-data.mount --no-pager
Aug 26 09:12:04 db-prod-03 systemd[1]: Mounting /srv/data...
Aug 26 09:13:34 db-prod-03 systemd[1]: dev-disk-by\x2duuid-b7c9....device: Job timed out.
Aug 26 09:13:34 db-prod-03 systemd[1]: Timed out waiting for device /dev/disk/by-uuid/b7c9d2e4-...
Aug 26 09:13:34 db-prod-03 systemd[1]: Dependency failed for /srv/data.
Aug 26 09:13:34 db-prod-03 systemd[1]: srv-data.mount: Job srv-data.mount/start failed with result 'dependency'.
Aug 26 09:13:34 db-prod-03 systemd[1]: Dependency failed for Local File Systems.

root@db-prod-03:~# lsblk -f | grep -c nvme1n1
0                                         # the volume genuinely is not attached

root@db-prod-03:~# mount -o remount,rw /
root@db-prod-03:~# sed -i 's|\(/srv/data .*\)nofail,\?|\1|; s|\(/srv/data .*xfs *[^ ]*\)|\1,nofail,x-systemd.device-timeout=15s|' /etc/fstab
root@db-prod-03:~# grep /srv/data /etc/fstab
UUID=b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752  /srv/data  xfs  rw,noatime,nodev,nosuid,logbsize=256k,nofail,x-systemd.device-timeout=15s  0  2

root@db-prod-03:~# findmnt --verify
root@db-prod-03:~# systemctl daemon-reload
root@db-prod-03:~# systemctl default
```

**Lesson:** `nofail` converts `Requires=` into `Wants=` and removes the 90-second device wait from the critical path. With `nofail`, that boot completes, the database refuses to start (because of `RequiresMountsFor=`), monitoring pages you, and the machine is reachable over SSH. Without it, the machine is gone.

### 10.4 Worked failure #2 — the shadowed mount point

```
$ df -h /srv/data
Filesystem      Size  Used Avail Use% Mounted on
/dev/mapper/vg0-root   40G   39G  412M  99% /       # <-- NOT nvme1n1. The mount is missing.

$ findmnt /srv/data
$ echo $?
1                                                    # nothing mounted there

$ du -sh /srv/data
26G     /srv/data                                    # 26 GB written to the ROOT filesystem

$ systemctl status srv-data.mount --no-pager
● srv-data.mount - /srv/data
     Active: failed (Result: exit-code) since Tue 2026-08-26 09:14:02 UTC
$ journalctl -b -u srv-data.mount -n 5 --no-pager
Aug 26 09:14:02 db-prod-03 mount[912]: mount: /srv/data: wrong fs type, bad option, bad superblock on /dev/nvme1n1
Aug 26 09:14:02 db-prod-03 kernel: XFS (nvme1n1): Filesystem has duplicate UUID b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752 - can't mount
```

Recovery, in the only safe order:

```
$ sudo systemctl stop postgresql@16-main
$ sudo mv /srv/data /srv/data.shadowed          # preserve what was written to root
$ sudo mkdir -p /srv/data
$ sudo xfs_admin -U generate /dev/nvme1n1
Clearing log and setting UUID
new UUID = 3d8e1f52-6b0a-4c27-8f13-72a94e6d05b1
$ sudo sed -i 's/b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752/3d8e1f52-6b0a-4c27-8f13-72a94e6d05b1/' /etc/fstab
$ sudo systemctl daemon-reload && sudo mount -a
$ findmnt /srv/data
TARGET    SOURCE       FSTYPE OPTIONS
/srv/data /dev/nvme1n1 xfs    rw,noatime,nodev,nosuid,logbsize=256k
$ sudo rsync -aHAX --info=progress2 /srv/data.shadowed/ /srv/data/
$ sudo systemctl start postgresql@16-main
```

The permanent fix is `RequiresMountsFor=/var/lib/postgresql` in the service drop-in (§6.4), so that a failed mount stops the service instead of silently redirecting it.

### 10.5 Standing verification you should automate

```
# Is anything mounted with weaker flags than fstab asks for?
$ findmnt --json --real | jq -r '.filesystems[] | "\(.target)\t\(.options)"'

# Any local filesystem that should be nodev/nosuid but is not:
$ findmnt -n -o TARGET,OPTIONS --real \
  | awk '$1 ~ "^/(tmp|home|var/tmp|dev/shm|media)" && ($2 !~ /nosuid/ || $2 !~ /nodev/) {print "WEAK: "$0}'

# Any filesystem that silently went read-only:
$ findmnt -n -o TARGET,OPTIONS --real | awk '$2 ~ /(^|,)ro(,|$)/ {print "READ-ONLY: "$0}'

# Will the next boot succeed?
$ sudo findmnt --verify --verbose | tail -1
0 parse errors, 0 errors, 0 warnings

# Boot-time storage critical path
$ systemd-analyze critical-chain local-fs.target --no-pager
local-fs.target @6.204s
└─srv-data.mount @5.918s +284ms
  └─systemd-fsck@dev-disk-by\x2duuid-b7c9....service @4.601s +1.310s
    └─dev-disk-by\x2duuid-b7c9....device @4.598s
```

Wire the `findmnt --verify` exit status into configuration management and the `READ-ONLY` check into your metrics agent. A filesystem that remounted read-only at 03:00 should page, not be discovered at 09:00.

---

## 11. Command reference

| Task | Command |
|---|---|
| List block devices with fs info | `lsblk -f` · `lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS` |
| Read fs signature | `blkid /dev/X` · `blkid -s UUID -o value /dev/X` |
| Find device by label/UUID | `blkid -L <label>` · `blkid -U <uuid>` |
| Mount from fstab | `mount /path` · `mount -a` |
| Mount by identifier | `mount UUID=… /path` · `mount LABEL=… /path` |
| Dry run | `mount --fake -v /path` · `mount -a --fake -v` |
| Bind / move | `mount --bind src dst` · `mount --rbind` · `mount --move` |
| Change options live | `mount -o remount,<opts> /path` |
| Show current mounts | `findmnt` · `findmnt -t xfs` · `findmnt --df` · `findmnt --real` |
| Show fstab, resolved | `findmnt --fstab --evaluate` |
| Validate fstab | `findmnt --verify --verbose` |
| Watch mount changes | `findmnt --poll --target /path` |
| Unmount | `umount /path` · `umount -R` · `umount -a -t nfs4` |
| Find holders | `fuser -vm /path` · `lsof /path` · `lsns -t mnt` |
| Kill holders | `fuser -km /path` |
| Flush | `sync -f /path` · `blockdev --flushbufs /dev/X` |
| Quiesce for snapshot | `fsfreeze --freeze /path` … `fsfreeze --unfreeze /path` |
| Relabel / re-UUID | `e2label` · `tune2fs -U` · `xfs_admin -L/-U` · `fatlabel` |
| systemd mount units | `systemctl list-units --type=mount` · `systemctl cat <u>.mount` · `systemd-escape -p --suffix=mount /p` |
| Transient mount | `systemd-mount /dev/X /mnt/y` · `systemd-umount /mnt/y` |
| User-space mount daemon | `udisksctl status` · `udisksctl mount -b /dev/X` · `udisksctl power-off -b /dev/X` |
| Boot storage diagnostics | `journalctl -b -u local-fs.target` · `systemd-analyze critical-chain local-fs.target` |

---

## 12. References

**Exam objectives**
- LPI — Exam 101-500 Objectives (LPIC-1 v5.0), Topic 104.3: https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — LPIC-1 Certification overview: https://www.lpi.org/our-certifications/lpic-1-overview/

**util-linux (mount, umount, findmnt, blkid, lsblk, fstab)**
- `mount(8)`: https://man7.org/linux/man-pages/man8/mount.8.html
- `umount(8)`: https://man7.org/linux/man-pages/man8/umount.8.html
- `fstab(5)`: https://man7.org/linux/man-pages/man5/fstab.5.html
- `findmnt(8)`: https://man7.org/linux/man-pages/man8/findmnt.8.html
- `blkid(8)`: https://man7.org/linux/man-pages/man8/blkid.8.html
- `lsblk(8)`: https://man7.org/linux/man-pages/man8/lsblk.8.html
- `fsfreeze(8)`: https://man7.org/linux/man-pages/man8/fsfreeze.8.html
- `losetup(8)`: https://man7.org/linux/man-pages/man8/losetup.8.html
- util-linux upstream: https://github.com/util-linux/util-linux

**Kernel**
- `mount(2)`: https://man7.org/linux/man-pages/man2/mount.2.html
- `mount_namespaces(7)`: https://man7.org/linux/man-pages/man7/mount_namespaces.7.html
- Shared subtrees (mount propagation): https://docs.kernel.org/filesystems/sharedsubtree.html
- `/proc` filesystem, incl. `mountinfo` field layout: https://docs.kernel.org/filesystems/proc.html
- ext4 administration and mount options: https://docs.kernel.org/admin-guide/ext4.html
- XFS administration: https://docs.kernel.org/admin-guide/xfs.html
- tmpfs: https://docs.kernel.org/filesystems/tmpfs.html
- overlayfs: https://docs.kernel.org/filesystems/overlayfs.html
- VFS overview: https://docs.kernel.org/filesystems/vfs.html

**systemd**
- `systemd.mount(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.mount.html
- `systemd.automount(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.automount.html
- `systemd-fstab-generator(8)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-fstab-generator.html
- `systemd-mount(1)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-mount.html
- `systemd.unit(5)` — `RequiresMountsFor=`: https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html
- `systemd-escape(1)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-escape.html

**Filesystem tools**
- `tune2fs(8)`: https://man7.org/linux/man-pages/man8/tune2fs.8.html
- `e2label(8)`: https://man7.org/linux/man-pages/man8/e2label.8.html
- `xfs_admin(8)`: https://man7.org/linux/man-pages/man8/xfs_admin.8.html
- `dumpe2fs(8)`: https://man7.org/linux/man-pages/man8/dumpe2fs.8.html

**Removable media and automounting**
- udisks2 project: https://github.com/storaged-project/udisks
- `udisksctl(1)`: https://storaged.org/doc/udisks2-api/latest/udisksctl.1.html
- polkit reference manual: https://www.freedesktop.org/software/polkit/docs/latest/polkit.8.html
- `auto.master(5)`: https://man7.org/linux/man-pages/man5/auto.master.5.html
- `autofs(5)`: https://man7.org/linux/man-pages/man5/autofs.5.html
- Filesystem Hierarchy Standard 3.0 (`/media`, `/mnt`, `/srv`): https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html

**Diagnostics**
- `fuser(1)`: https://man7.org/linux/man-pages/man1/fuser.1.html
- `lsof(8)`: https://man7.org/linux/man-pages/man8/lsof.8.html
- `lsns(8)`: https://man7.org/linux/man-pages/man8/lsns.8.html
- `nsenter(1)`: https://man7.org/linux/man-pages/man1/nsenter.1.html

**Infrastructure automation**
- cloud-init `mounts` module: https://cloudinit.readthedocs.io/en/latest/reference/modules.html#mounts
- cloud-init `disk_setup` module: https://cloudinit.readthedocs.io/en/latest/reference/modules.html#disk-setup
- Ansible `ansible.posix.mount`: https://docs.ansible.com/ansible/latest/collections/ansible/posix/mount_module.html
- Kubernetes — mount propagation: https://kubernetes.io/docs/concepts/storage/volumes/#mount-propagation
- Kubernetes CSI node plugin deployment: https://kubernetes-csi.github.io/docs/deploying.html