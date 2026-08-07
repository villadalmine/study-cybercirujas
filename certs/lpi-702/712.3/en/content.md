# LPI 702-100: BSD Specialist Certification
## Topic 712.3: Control Mounting and Unmounting of File Systems
**Weight:** 3.33 | **Target Level:** Advanced SRE / Principal Platform Architect

---

### 1. Production Motivation & Architectural Problem

In enterprise BSD production environments (FreeBSD, NetBSD, OpenBSD), the Virtual File System (VFS) abstraction layer bridges physical storage controllers, network storage endpoints, and in-memory structures to the unified root filesystem tree (`/`). Controlling the attachment (mounting) and detachment (unmounting) of filesystems is not merely an administrative convenience—it is a core security boundary, performance tuning vector, and resiliency mechanism.

```
                  +-------------------------------------------------+
                  |              User Space Applications            |
                  +-------------------------------------------------+
                                           |
                                  POSIX System Calls
                               (open, read, write, stat)
                                           |
                  +-------------------------------------------------+
                  |              VFS (Virtual File System)          |
                  |                vnode / mount table              |
                  +-------------------------------------------------+
                     /                     |                     \
                    /                      |                      \
    +-----------------------+    +-------------------+    +-----------------------+
    |   UFS2 / FFS VFS      |    |      ZFS VFS      |    |      NFS VFS          |
    | (softdep, journal)    |    | (SPA, ZPL, ARC)   |    | (RPC, Client VFS)     |
    +-----------------------+    +-------------------+    +-----------------------+
                |                          |                          |
    +-----------------------+    +-------------------+    +-----------------------+
    |   GEOM Storage Layer  |    |   vdev / Disks    |    | Network Stack (ixgbe) |
    |  (gpart, gmirror, etc)|    +-------------------+    +-----------------------+
    +-----------------------+
```

#### Architectural Challenges in Production
1. **Security Isolation & Privilege Boundaries:** Exposing raw read-write mounts with setuid (`suid`) permissions and execution bits (`exec`) inside web application directories or multi-tenant FreeBSD Jails presents catastrophic privilege escalation risks. Engineers must enforce strict mount-level security options (`noexec`, `nosuid`, `nosymfollow`, `wxneeded`) at the VFS kernel boundary.
2. **Atomic Upgrades & Immutable Infrastructure:** Zero-downtime OS upgrades rely on read-only base system mounts combined with `nullfs` (loopback) or `unionfs` layers, or ZFS boot environments (`beadm`/`bectl`). Converting a mounted filesystem from read-only to read-write must happen atomically via runtime remount operations (`mount -u`).
3. **Graceful Detachment vs. Storage Failure:** Storage Array Network (SAN) drops, NFS server crashes, or runaway worker processes holding open vnodes cause target mount points to lock into `EBUSY` states. SREs require precise diagnostics (`fstat`, `fuser`, `lsof`) and controlled forcing routines (`umount -f`) to prevent kernel hang conditions or system deadlocks.
4. **Boot Sequence Ordering & Dependency Management:** Modern BSD systems parse static tables (`/etc/fstab`) during early initialization (`/etc/rc.d/mountcritlocal`, `/etc/rc.d/mountcritremote`). Misconfigured network filesystem dependencies without non-blocking options (`late`, `bg`, `noauto`) cause startup execution to hang indefinitely before sshd starts.

---

### 2. Technical Comparison & Trade-off Tables

#### 2.1 File System Mounting Paradigms

| Paradigm | Configuration Source | Performance Overhead | Kernel VFS Mechanism | Best Use Case | Primary Trade-off |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Static `/etc/fstab`** | `/etc/fstab` parsed at boot by `/etc/rc` | Zero runtime control overhead | Direct VFS mount point registration | Base OS partitions (`/`, `/usr`, `/var`), swap | Rigid structure; requiring reboot or manual `mount -a` on edits |
| **ZFS Auto-mount** | ZFS Pool Properties (`mountpoint`, `canmount`) | Microsecond lookup via ZPL metadata | Dynamic VFS attachment bypassing `/etc/fstab` | Enterprise storage, database volumes, container datasets | Incompatible with legacy UFS tooling; bypasses traditional fstab audit pipelines |
| **Automounter (`autofs` / `amd`)** | `/etc/auto_master`, direct/indirect maps | Minor latency on initial directory access | Kernel autofs daemon triggers dynamic mounting | On-demand NFS home directories, optical drives | First-access latency penalty; stale mount cleanup overhead |
| **Nullfs (Loopback Mount)** | Manual CLI or `/etc/fstab` (`nullfs` / `null`) | Minimal (vnode redirection layer) | Maps a directory tree into another namespace | FreeBSD Jails, chroots, isolated build roots | Potential recursion loops if nested incorrectly |
| **Tmpfs (Memory FS)** | `/etc/fstab` (`tmpfs`) | Ultra-fast (RAM speed throughput) | Page cache memory allocator allocation | `/tmp`, `/var/run`, transient build artifacts | Volatile storage; consumes system RAM/swap pool |

#### 2.2 BSD VFS Mount Flags & Security Options

| Flag | VFS Kernel Option | Security / Operational Function | Performance Impact | Supported OS |
| :--- | :--- | :--- | :--- | :--- |
| `ro` | `MNT_RDONLY` | Forces read-only access on the filesystem. Prevents file modifications. | Eliminates write operations and metadata updates | FreeBSD, NetBSD, OpenBSD |
| `rw` | Default | Allows read and write operations. | Standard disk I/O path | FreeBSD, NetBSD, OpenBSD |
| `nosuid` | `MNT_NOSUID` | Disables execution of Set-User-ID and Set-Group-ID binaries. | Zero | FreeBSD, NetBSD, OpenBSD |
| `noexec` | `MNT_NOEXEC` | Prevents execution of any binaries residing on the partition. | Prevents execution attacks | FreeBSD, NetBSD, OpenBSD |
| `noatime` | `MNT_NOATIME` | Disables access time updates on vnodes when files are read. | High write reduction; boosts read IOPS | FreeBSD, NetBSD, OpenBSD |
| `async` | `MNT_ASYNC` | Asynchronous metadata writes. Metadata operations return before hitting disk. | Ultra-high performance; extreme risk of data corruption on panic | FreeBSD, NetBSD, OpenBSD |
| `softdep` | `UFS_SOFTUPDATES` | Uses Soft Updates to maintain UFS metadata consistency without blocking synchronous writes. | High performance boost for UFS metadata ops | FreeBSD, NetBSD, OpenBSD |
| `wxneeded` | `MNT_WXNEEDED` | Enforces W^X (Write XOR Execute) security; permits processes to violate W^X only if binary is flagged. | Negligible; tightens security | OpenBSD specific |

#### 2.3 BSD Variant Utility & Mounting Differences

| Feature / Utility | FreeBSD | NetBSD | OpenBSD |
| :--- | :--- | :--- | :--- |
| **Primary File System** | UFS2 / ZFS | FFSv2 (Fast File System) | FFS (Fast File System) |
| **Loopback Mount Tool** | `mount_nullfs` (FSType: `nullfs`) | `mount_null` (FSType: `null`) | `mount_null` (FSType: `null`) |
| **FSType Update Flag** | `mount -u` | `mount -u` | `mount -u` |
| **ZFS Native Support** | Base System (`openzfs`) | Module / Port support | Not natively supported |
| **Default Security Flags** | Explicitly set in `/etc/fstab` | Explicitly set in `/etc/fstab` | Hardened defaults (`wxneeded`, `nosuid` on `/tmp`) |
| **Automounter Service** | `autofs` (`autofs_enable="YES"`) | `amd` daemon | `amd` daemon |

---

### 3. Production-Grade Configuration Manifests

#### 3.1 Hardened FreeBSD Production `/etc/fstab`

This configuration defines a multi-partition setup incorporating UFS2, ZFS datasets, `tmpfs`, `nullfs` isolation for Jails, and non-blocking NFS mounts.

```fstab
# /etc/fstab - Production FreeBSD Infrastructure Node
# Device                Mountpoint           FSType    Options                                  Dump Pass
# ------------------------------------------------------------------------------------------------------
# Root Partition (UFS2 with Soft Updates and Journaling)
/dev/ada0p3             /                    ufs       rw,noatime,acls                          1    1

# Dedicated Boot Partition
/dev/ada0p2             /boot/efi            msdosfs   ro,noauto                                0    0

# System Partitions Hardened with Security Flags
/dev/ada0p4             /var                 ufs       rw,noatime,nosuid                        2    2
/dev/ada0p5             /var/tmp             ufs       rw,noatime,nosuid,noexec                 2    2
/dev/ada0p6             /usr                 ufs       rw,noatime                               2    2

# In-Memory Ephemeral Storage for High IOPS / Isolation
tmpfs                   /tmp                 tmpfs     rw,mode=1777,size=4G,nosuid,noexec       0    0
procfs                  /proc                procfs    rw,noauto                                0    0

# FreeBSD Jail Infrastructure - Base System Read-Only Loopback Nullfs Mounts
/usr/jails/basejail     /usr/jails/containers/app01/basejail nullfs ro,nosuid                        0    0
/usr/jails/basejail     /usr/jails/containers/app02/basejail nullfs ro,nosuid                        0    0

# Enterprise NFS Mount (Non-blocking, background, hardened against server failures)
nfs-storage.internal:/export/assets /mnt/assets nfs rw,noatime,soft,bg,intr,retrycnt=3,nosuid,noexec 0 0
```

#### 3.2 Security-Hardened OpenBSD Production `/etc/fstab`

OpenBSD utilizes strict partition layouts enforcing W^X security boundaries.

```fstab
# /etc/fstab - OpenBSD Hardened Server Node
# Device UUID / DUID    Mountpoint           FSType    Options                                  Dump Pass
# ------------------------------------------------------------------------------------------------------
a1b2c3d4e5f6a7b8.a      /                    ffs       rw,noatime                               1    1
a1b2c3d4e5f6a7b8.b      none                 swap      sw                                       0    0
a1b2c3d4e5f6a7b8.d      /tmp                 ffs       rw,noatime,nosuid,noexec,nodev           2    2
a1b2c3d4e5f6a7b8.e      /var                 ffs       rw,noatime,nosuid,nodev                  2    2
a1b2c3d4e5f6a7b8.f      /usr                 ffs       rw,noatime,nodev                         2    2
a1b2c3d4e5f6a7b8.g      /usr/X11R6           ffs       ro,nodev                                 2    2
a1b2c3d4e5f6a7b8.h      /usr/local           ffs       rw,noatime,nodev,wxneeded                2    2
a1b2c3d4e5f6a7b8.i      /usr/obj             ffs       rw,noatime,nosuid,nodev                  2    2
a1b2c3d4e5f6a7b8.j      /home                ffs       rw,noatime,nosuid,nodev,noexec           2    2
```

#### 3.3 FreeBSD Automounter Configuration (`/etc/auto_master` and `/etc/auto_direct`)

##### File: `/etc/auto_master`
```conf
# Master Automounter Map
/-                      auto_direct             -noatime,soft
/net                    -hosts                  -nobrowse,nosuid
```

##### File: `/etc/auto_direct`
```conf
# Direct Automounter Map for Dynamic Storage Volumes
/mnt/database/backups   -fstype=nfs,rw,hard,intr,nosuid   san01.internal:/exports/backups
/mnt/media/archive      -fstype=nfs,ro,soft               nas01.internal:/exports/archive
```

---

### 4. Real CLI Commands & Terminal Outputs

#### 4.1 Viewing and Inspecting Active VFS Mounts

Examine currently mounted filesystems using `mount`, `df`, and `sysctl`.

```console
$ mount -v
zroot/ROOT/default on / (zfs, local, noatime, nfsv4acls)
devfs on /dev (devfs, local, jid=0)
zroot/tmp on /tmp (zfs, local, noatime, noexec, nosuid, nfsv4acls)
zroot/usr/home on /usr/home (zfs, local, noatime, nfsv4acls)
zroot/usr/src on /usr/src (zfs, local, noatime, nfsv4acls)
zroot/var/audit on /var/audit (zfs, local, noatime, noexec, nosuid, nfsv4acls)
zroot/var/log on /var/log (zfs, local, noatime, noexec, nosuid, nfsv4acls)
zroot/var/tmp on /var/tmp (zfs, local, noatime, noexec, nosuid, nfsv4acls)
/usr/jails/basejail on /usr/jails/containers/web01/basejail (nullfs, local, read-only)
```

```console
$ df -hT
Filesystem                                  Type      Size    Used   Avail Capacity  Mounted on
zroot/ROOT/default                          zfs       450G    12G    438G     3%     /
devfs                                       devfs     1.0Ki    0B   1.0Ki     0%     /dev
zroot/tmp                                   zfs       438G    120Ki  438G     0%     /tmp
zroot/usr/home                              zfs       465G    27G    438G     6%     /usr/home
zroot/var/log                               zfs       440G    2.1G   438G     0%     /var/log
/usr/jails/basejail                         nullfs    450G    12G    438G     3%     /usr/jails/containers/web01/basejail
```

#### 4.2 Manual Mounting, Hardening, and Live Remounting

Mounting a UFS partition manually with explicit security restrictions:

```console
# mount -t ufs -o ro,nosuid,noexec /dev/ada1p1 /mnt/secure_data
```

Verify mount flags registered in VFS kernel space:

```console
$ mount | grep secure_data
/dev/ada1p1 on /mnt/secure_data (ufs, local, read-only, noexec, nosuid)
```

Perform an **atomic runtime update (remount)** to change access mode from Read-Only (`ro`) to Read-Write (`rw`) without unmounting or disturbing active kernel paths:

```console
# mount -u -o rw,nosuid,noexec /mnt/secure_data
```

Confirm the change:

```console
$ mount | grep secure_data
/dev/ada1p1 on /mnt/secure_data (ufs, local, noexec, nosuid)
```

#### 4.3 Loopback (`nullfs`) and In-Memory (`tmpfs`) Operations

Mounting a loopback directory tree into a target directory structure (useful for chroots/jails):

```console
# mount -t nullfs -o ro /var/cache/pkg /usr/jails/containers/web01/var/cache/pkg
```

Creating a high-speed memory-backed filesystem using `tmpfs`:

```console
# mount -t tmpfs -o size=2G,mode=1777,noexec,nosuid tmpfs /mnt/ramdisk
```

Verify `tmpfs` capacity and mount properties:

```console
$ df -h /mnt/ramdisk
Filesystem    Size    Used   Avail Capacity  Mounted on
tmpfs         2.0G     4.0Ki  2.0G     0%     /mnt/ramdisk
```

#### 4.4 ZFS Mount Management

ZFS manages mounting declaratively via dataset properties instead of static `/etc/fstab` lines.

Check ZFS dataset mount properties:

```console
$ zfs get mountpoint,canmount,mounted zroot/data/db
NAME           PROPERTY    VALUE       SOURCE
zroot/data/db  mountpoint  /var/db/db  local
zroot/data/db  canmount    on          default
zroot/data/db  mounted     yes         -
```

Unmount a ZFS dataset explicitly:

```console
# zfs unmount zroot/data/db
```

Verify dataset status:

```console
$ zfs get mounted zroot/data/db
NAME           PROPERTY  VALUE  SOURCE
zroot/data/db  mounted   no     -
```

Mount all configured ZFS datasets according to pool definitions:

```console
# zfs mount -a
```

Change mountpoint path dynamically:

```console
# zfs set mountpoint=/mnt/postgres_data zroot/data/db
```

---

### 5. Verification & Failure Diagnostics Guide

#### 5.1 Troubleshooting "Device Busy" (`EBUSY` / Resource Lock) Errors

When attempting to unmount a filesystem, the kernel returns `Device busy` (`EBUSY`) if active processes hold open vnode handles, working directory references, or memory-mapped files on the target partition.

##### Scenario: Failed Unmount Attempt
```console
# umount /mnt/data
umount: unmount of /mnt/data failed: Device busy
```

##### Step 1: Identify Locking Processes via `fstat` (FreeBSD) or `lsof`
`fstat` queries open vnode references across the kernel process table:

```console
# fstat /mnt/data
USER     CMD          PID   FD MOUNT      INUM MODE         SZ|DV R/W
www      nginx      84920 text /mnt/data 10492 -rwxr-xr-x  524288  r
www      nginx      84921   wd /mnt/data     2 drwxr-xr-x    4096  r
postgres postgres   85102    5 /mnt/data 84910 -rw------- 1048576 rw
```

##### Step 2: Identify Locking Processes via `fuser`
`fuser` displays process IDs using specified files or filesystems:

```console
# fuser -c /mnt/data
/mnt/data: 84920c 84921c 85102e
```
*(Flags: `c` = current directory, `e` = executable text file, `f` = open file handle)*

##### Step 3: Terminate Locking Processes and Unmount
Terminate blocking PIDs gracefully:

```console
# kill -TERM 84920 84921 85102
```

If processes do not terminate, issue `SIGKILL`:

```console
# fuser -k -9 /mnt/data
/mnt/data: 84920 84921 85102
```

Retry standard unmount:

```console
# umount /mnt/data
```

#### 5.2 Handling Unresponsive Network Mounts (Forced Unmount)

When an NFS server crashes or becomes network-unreachable, standard `umount` calls block indefinitely while waiting for RPC response timeouts.

##### Forced Unmount Command:
```console
# umount -f /mnt/assets
```
`umount -f` invalidates open vnodes forcibly within the VFS layer, returning `EIO` to application processes attempting active read/write calls, and unlinks the mount structure immediately.

#### 5.3 Emergency Boot Recovery: Broken `/etc/fstab`

If a syntax error or non-existent device ID is introduced to `/etc/fstab`, the BSD boot sequence halts and drops into Single-User Mode with a read-only root filesystem.

```
Mounting local filesystems:
mount: /dev/ada9p1: No such file or directory
Mounting /etc/fstab filesystems failed, startup aborted
Enter full pathname of shell or RETURN for /bin/sh:
```

##### Single-User Recovery Procedure:

1. Press `Enter` to access `/bin/sh`.
2. Remount the root partition (`/`) in read-write mode (`rw`):

```console
# mount -u -w /
```

3. If `/var` or `/usr` are on separate partitions needed for editing tools, mount them individually:

```console
# mount /usr
# mount /var
```

4. Verify current mounts:

```console
# mount
/dev/ada0p3 on / (ufs, local, read-only) -> updated to (ufs, local)
```

5. Correct `/etc/fstab` using `vi` or `ee`:

```console
# vi /etc/fstab
```

6. Test `/etc/fstab` mounting definitions without rebooting:

```console
# mount -a
```

7. Exit single-user mode to resume normal multi-user boot:

```console
# exit
```

---

#### 5.4 Diagnostic Decision Flowchart

```
                 +-----------------------------------+
                 |    File System Operation Fails    |
                 +-----------------------------------+
                                   |
                  Is error "Device busy" (EBUSY)?
                                  / \
                                 /   \
                               YES   NO
                               /       \
                              /         \
  +--------------------------------+   +------------------------------------+
  | Run: fstat <mountpoint>        |   | Is it an unresponsive network FS?  |
  |  OR: fuser -c <mountpoint>     |   +------------------------------------+
  +--------------------------------+                  / \
                  |                                  /   \
  +--------------------------------+               YES   NO
  | Terminate blocking PIDs:       |               /       \
  | # kill -15 <PID>               |              /         \
  | # kill -9 <PID> (if persistent)|  +------------------+  +-------------------+
  +--------------------------------+  | Force unmount:   |  | Check sysctl/dmesg|
                  |                   | # umount -f <mp> |  | Verify fstab syntax|
  +--------------------------------+  +------------------+  +-------------------+
  | Retry: # umount <mountpoint>   |
  +--------------------------------+
```

---

### 6. References

* **LPI BSD Specialist Certification Overview:**  
  https://www.lpi.org/our-certifications/bsd-specialist-overview/
* **FreeBSD Manual Pages - `mount(8)`:**  
  https://man.freebsd.org/cgi/man.cgi?query=mount&sektion=8
* **FreeBSD Manual Pages - `fstab(5)`:**  
  https://man.freebsd.org/cgi/man.cgi?query=fstab&sektion=5
* **FreeBSD Handbook - Mounting and Unmounting File Systems:**  
  https://docs.freebsd.org/en/books/handbook/basics/#filesystems-mounting
* **OpenBSD Manual Pages - `mount(8)` & `fstab(5)`:**  
  https://man.openbsd.org/mount.8  
  https://man.openbsd.org/fstab.5
* **NetBSD Manual Pages - `mount(8)`:**  
  https://man.netbsd.org/mount.8
* **OpenZFS Documentation - Mounting & Datasets:**  
  https://openzfs.github.io/openzfs-docs/Getting%20Started/FreeBSD/index.html