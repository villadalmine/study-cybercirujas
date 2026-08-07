# Production-Grade Study Guide: LPI-702 BSD Specialist (Exam 702-100)
## Topic 712.3: Control Mounting and Unmounting of File Systems
**Weight:** 3.33  
**Official Reference:** [LPI BSD Specialist Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

---

### Deep Technical Mechanics & Architectural Overview

In BSD operating systems (FreeBSD, OpenBSD, NetBSD), file system mounting is the kernel process of linking a storage device's root directory structure into the global VFS (Virtual File System) hierarchy at a specified mount point vnode.

```
       +--------------------------------------------------------+
       |                  BSD VFS Layer                         |
       |  (Translates generic file Ops to FS-specific vops)     |
       +--------------------------------------------------------+
              |                                            |
              v                                            v
     +-----------------+                          +-----------------+
     |   struct mount  |                          |   struct mount  |
     |   (UFS / ZFS)   |                          |     (NFS / BSD) |
     +-----------------+                          +-----------------+
        |           |                                      |
        v           v                                      v
    +-------+   +-------+                              +-------+
    | vnode |   | vnode |                              | vnode |
    | (File)|   | (Dir) |                              | (NFS) |
    +-------+   +-------+                              +-------+
```

#### Key Kernel Data Structures
*   **`struct vnode`**: Represents an active file, directory, socket, or device node in kernel memory. Every open file or active directory reference holds a vnode lock or reference count (`v_usecount`, `v_holdcnt`).
*   **`struct mount`**: Represents a mounted file system instance, containing pointers to the mount flags (`MNT_RDONLY`, `MNT_NOEXEC`, `MNT_NOSUID`, `MNT_NOATIME`, `MNT_SYNCHRONOUS`), filesystem-specific operation vectors (`vfsops`), and the root vnode of the mounted filesystem (`mnt_vnodecovered`).

#### VFS Mount Operation Lifecycle
1.  **Lookup & Validation**: The kernel resolves the mount point path to a `struct vnode`. It verifies that the target path is a directory and that the executing user has root privileges (`priv_check(td, PRIV_VFS_MOUNT)`).
2.  **Access Privilege & Lock Acquisition**: The mount point vnode is locked exclusive (`vn_lock(vp, LK_EXCLUSIVE)`).
3.  **FS Initialization**: The filesystem driver's `vfs_mount` entry point is invoked. The superblock or network protocol handshake is validated.
4.  **VFS Registration**: A new `struct mount` is initialized and linked into the global VFS mount list (`mountlist`). The mount point vnode has its `VDIR` status linked to the new filesystem root vnode.

#### The Unmount Lifecycle & `EBUSY` Failures
When invoking `umount(8)`:
1.  The kernel calls `vfs_unmount()` which attempts to flush all dirty buffers (`vfs_object_sync()`).
2.  The kernel checks for active vnodes with non-zero reference counts (`v_usecount > 0` or active file locks).
3.  If active vnodes exist and the force flag (`MNT_FORCE`) is **not** set, the system call fails immediately with error code `16` (`EBUSY`: *Device busy*).
4.  If `MNT_FORCE` (`umount -f`) is set, active vnodes are forcibly invalidated or revoked via `vgone()`, breaking active file handles for user space applications.

---

### Exercise 1: Advanced Local File System Mounting & `/etc/fstab` Engineering

In this exercise, you will create a RAM-backed memory disk (`mdconfig`), format it with UFS2, configure mounting via `/etc/fstab`, and dynamically alter runtime kernel mount parameters without unmounting.

#### Step 1: Create a RAM-Backed Storage Node and File System
Create a 128MB swap-backed memory device using `mdconfig(8)` (FreeBSD) and format it with UFS2 using `newfs(8)`.

```bash
# Create a swap-backed memory disk of 128MB
sudo mdconfig -a -t swap -s 128M -u md99

# Verify the block device exists
ls -l /dev/md99

# Create a UFS2 filesystem with softupdates enabled
sudo newfs -U /dev/md99
```

**Expected Output:**
```text
/dev/md99: 128.0MB (262144 sectors) block size 32768, fragment size 4096
	using 4 cylinder groups of 32.00MB, 1024 blks, 4160 inodes.
	with soft updates
super-block backups (for fsck -b #) at:
 192, 65728, 131264, 196800
```

#### Step 2: Configure Mount Target and Persistent Configuration
Create an absolute mount path `/mnt/secure_data` and add a syntactically valid entry to `/etc/fstab`.

```bash
sudo mkdir -p /mnt/secure_data

# Append the entry to /etc/fstab using standard BSD fstab options
# Schema: <device> <mountpoint> <fstype> <options> <dump> <pass>
echo "/dev/md99 /mnt/secure_data ufs rw,noexec,nosuid,noatime 2 2" | sudo tee -a /etc/fstab
```

#### Step 3: Mount via `fstab` and Inspect Runtime Kernel Mount Flags
Mount the newly defined filesystem using `mount(8)` referencing `/etc/fstab`, then verify flags via `mount -v`.

```bash
# Mount the entry defined in fstab
sudo mount /mnt/secure_data

# Display detailed mount status for the filesystem
mount -v -t ufs | grep /mnt/secure_data
```

**Expected Output:**
```text
/dev/md99 on /mnt/secure_data (ufs, local, noatime, noexec, nosuid, soft-updates)
```

#### Step 4: Validate Kernel Enforcement of Mount Flags (`noexec`, `nosuid`)
Test security enforcement by attempting to execute a binary within `/mnt/secure_data`.

```bash
# Copy a standard binary to the mount point
sudo cp /bin/echo /mnt/secure_data/test_echo
sudo chmod 755 /mnt/secure_data/test_echo

# Attempt execution
/mnt/secure_data/test_echo "Testing noexec"
```

**Expected Output:**
```text
bash: /mnt/secure_data/test_echo: Permission denied
```

#### Step 5: Perform Live Runtime Mount Update (Hot Modification)
Demote the filesystem to read-only at runtime without unmounting applications using the `-u` (update) flag.

```bash
# Update kernel mount flags to read-only (ro)
sudo mount -u -o ro /mnt/secure_data

# Attempt to write a file
touch /mnt/secure_data/test_file
```

**Expected Output:**
```text
touch: /mnt/secure_data/test_file: Read-only file system
```

---

#### Verification Questions - Exercise 1

1. **What is the exact functional difference between the `dump` and `pass` fields (columns 5 and 6) in `/etc/fstab` on BSD systems?**
2. **If a filesystem is mounted with `-o noexec`, can a shell script located on that partition still be executed using `sh /mnt/secure_data/script.sh`? Why or why not from a VFS perspective?**

---

### Exercise 2: Special & Layered Filesystems (`nullfs`, `tmpfs`, `devfs`)

Layered file systems pass VFS calls through an existing filesystem layer down to a lower filesystem. `nullfs(5)` (loopback/bind mount) constructs secondary views of existing directory trees. `tmpfs(5)` uses VM page cache directly.

#### Step 1: Configure a High-Performance `tmpfs` Memory Store
Mount a memory-backed file system with restricted memory sizing and strict permissions.

```bash
sudo mkdir -p /tmp/volatile_cache

# Mount tmpfs restricted to 64MB with 0700 permissions
sudo mount -t tmpfs -o size=64M,mode=0700 tmpfs /tmp/volatile_cache

# Inspect tmpfs allocation using df
df -h /tmp/volatile_cache
```

**Expected Output:**
```text
Filesystem    Size    Used   Avail Capacity  Mounted on
tmpfs          64M    4.0Ki     64M     0%    /tmp/volatile_cache
```

#### Step 2: Construct a Layered Loopback Mount (`nullfs`)
Mount an existing directory `/var/log` onto `/mnt/log_shadow` using `nullfs`.

```bash
sudo mkdir -p /mnt/log_shadow

# Mount /var/log into /mnt/log_shadow using nullfs
sudo mount -t nullfs /var/log /mnt/log_shadow

# Create a test log file in the lower filesystem shadow
touch /mnt/log_shadow/nullfs_test.log

# Verify file presence in the underlying physical directory
ls -l /var/log/nullfs_test.log
```

**Expected Output:**
```text
-rw-r--r--  1 root  wheel  0 Aug  6 20:30 /var/log/nullfs_test.log
```

#### Step 3: Implement Read-Only Passthrough Overlay with `nullfs`
Configure a read-only `nullfs` layer over a read-write underlying file system to expose safe data views to unprivileged applications or Jails.

```bash
sudo mkdir -p /mnt/log_readonly

# Mount lower filesystem with read-only overlay
sudo mount -t nullfs -o ro /var/log /mnt/log_readonly

# Attempt to write to the read-only layer
touch /mnt/log_readonly/should_fail.log
```

**Expected Output:**
```text
touch: /mnt/log_readonly/should_fail.log: Read-only file system
```

---

#### Verification Questions - Exercise 2

1. **How does `nullfs` affect vnode retention and inode numbers? Does `/mnt/log_shadow/nullfs_test.log` share the same inode number as `/var/log/nullfs_test.log`?**
2. **If the lower file system (`/var/log`) is unmounted or modified, what happens to open file descriptors accessing the upper `nullfs` overlay?**

---

### Exercise 3: Diagnosing and Resolving Mount/Unmount Failures (`EBUSY`)

System administrators frequently encounter `Device busy` (`EBUSY`) errors when attempting to unmount storage. This exercise covers kernel vnode inspection using `fstat(1)`, `procstat(1)`, and forced unmount mechanics.

#### Step 1: Simulate a Locked Filesystem Condition
Create an active lock on `/mnt/secure_data` by opening a long-running process with its working directory inside the mount point.

```bash
# Ensure /mnt/secure_data is mounted read-write
sudo mount -u -o rw /mnt/secure_data

# Launch a background process holding a file descriptor open inside the mount
( cd /mnt/secure_data && sleep 300 ) &
LOCKED_PID=$!
echo "Background process holding lock PID: ${LOCKED_PID}"
```

#### Step 2: Reproduce the Unmount Failure
Attempt to unmount the filesystem using `umount(8)`.

```bash
sudo umount /mnt/secure_data
```

**Expected Output:**
```text
umount: unmount of /mnt/secure_data failed: Device busy
```

#### Step 3: Inspect Active Vnodes and Open File Handles
Identify the precise process, user, file descriptor, and vnode locking the filesystem using `fstat(1)` and `procstat(1)`.

```bash
# Query fstat for any process holding open files on the mount point
fstat /mnt/secure_data

# Alternatively, use procstat to inspect file descriptors across processes
procstat -f -a | grep "/mnt/secure_data"
```

**Expected Output:**
```text
USER     CMD          PID   FD MOUNT      INUM MODE         SZ|DV R/W
root     sh         45129 text /mnt/secure_data     2 drwxr-xr-x     512 r
root     sh         45129 cwd  /mnt/secure_data     2 drwxr-xr-x     512 r
```

#### Step 4: Execute Graceful vs Forced Termination Protocols
Remediate the lock first via targeted process termination, then evaluate forced unmounting (`umount -f`).

```bash
# Method A: Graceful Process Termination via PID identified by fstat
sudo kill -TERM 45129
sleep 1

# Retry unmount
sudo umount /mnt/secure_data
echo "Unmount return code: $?"
```

**Expected Output:**
```text
Unmount return code: 0
```

#### Step 5: Forced Unmount Mechanism (`umount -f` / `umount -N`)
Re-mount `/mnt/secure_data`, lock it again, and execute a kernel force-invalidation unmount.

```bash
# Remount and hold lock
sudo mount /mnt/secure_data
( cd /mnt/secure_data && sleep 300 ) &

# Execute forced unmount
sudo umount -f /mnt/secure_data
```

**Expected Output:**
```text
/mnt/secure_data: unmounted
```

---

#### Verification Questions - Exercise 3

1. **What occurs internally inside the kernel when `umount -f` is executed on a filesystem with active write requests in progress? What happens to the process attempting to write?**
2. **What is the purpose of `umount -N` in BSD systems?**

---

### Exercise 4: Network File Systems (NFS) & Automount Infrastructure (`autofs`)

This exercise covers exports configuration (`/etc/exports`), mounting remote NFS exports with fault-tolerant parameters, and configuring trigger mounts via `autofs(5)`.

#### Step 1: Configure the Local NFS Server Export Definition
Define an NFS export rule in `/etc/exports` allowing access to local subnets with root credential mapping options.

```bash
# Ensure NFS server daemon configurations exist in /etc/exports
# Format: <directory> <flags> <network/host>
echo "/var/exports -alldirs -network 192.168.1.0/24 -maproot=root" | sudo tee -a /etc/exports

# Create exported directory
sudo mkdir -p /var/exports/shared_data
sudo touch /var/exports/shared_data/nfs_marker.txt

# Reload mountd daemon to apply exports modifications
sudo reload mountd || sudo service mountd reload
```

#### Step 2: Mount Remote NFS Shares with Robust Production Options
Mount the exported share locally using `mount_nfs` with `soft`, `retry`, and performance tuning settings.

```bash
sudo mkdir -p /mnt/nfs_client

# Mount NFS share using optimized options:
# soft: Fail operations after retries (prevents permanent process hang if server drops)
# timeo: Timeout interval in tenths of a second (50 = 5.0 seconds)
# retrans: Number of minor timeouts before major timeout
sudo mount -t nfs -o rw,soft,timeo=50,retrans=3 127.0.0.1:/var/exports/shared_data /mnt/nfs_client

# Verify remote mount status
mount -v -t nfs
```

**Expected Output:**
```text
127.0.0.1:/var/exports/shared_data on /mnt/nfs_client (nfs, performance options: soft, retrans=3, timeo=50)
```

#### Step 3: Configure `autofs(5)` Direct and Indirect Maps
`autofs` dynamically mounts file systems on-demand when a process accesses a target path, automatically unmounting them after an inactivity timeout (`automountd`).

Edit `/etc/auto_master` to define an indirect automount map point:

```bash
# Append an automount point to /etc/auto_master
# Syntax: <mount-point> <map-name> [ -options ]
echo "/net_auto /etc/auto_direct -timeout=30" | sudo tee -a /etc/auto_master
```

Create the map file `/etc/auto_direct`:

```bash
# Syntax: <key> [ -options ] <location>
echo "data -rw,soft,timeo=30 127.0.0.1:/var/exports/shared_data" | sudo tee -a /etc/auto_direct

# Set correct permissions on map configuration
sudo chmod 644 /etc/auto_direct
```

#### Step 4: Activate Automount Daemons and Test On-Demand Mounting
Start `automount(8)` and `automountd(8)` daemons and trigger an automated mount.

```bash
# Enable autofs daemons in /etc/rc.conf
sudo sysrc autofs_enable="YES"

# Start the autofs service
sudo service autofs start

# Force update of kernel automount triggers
sudo automount -c

# Confirm the automount trigger directory exists but is NOT mounted yet
df -h | grep net_auto
```

*(No output expected from `df`, indicating mount has not been triggered)*

Access the trigger path to force dynamic mounting:

```bash
# Accessing the key path 'data' inside /net_auto triggers automountd
ls -l /net_auto/data
```

**Expected Output:**
```text
total 0
-rw-r--r--  1 root  wheel  0 Aug  6 20:35 nfs_marker.txt
```

Verify that the VFS layer successfully mounted the share dynamically:

```bash
df -h /net_auto/data
```

**Expected Output:**
```text
Filesystem                             Size    Used   Avail Capacity  Mounted on
127.0.0.1:/var/exports/shared_data    45G    2.1G    39G     5%    /net_auto/data
```

---

#### Verification Questions - Exercise 4

1. **What is the critical failure recovery trade-off between mounting an NFS export with `-o hard` versus `-o soft` on a production system?**
2. **How does `autofs` detect when a file system is no longer in use, and what prevents `automountd` from unmounting an idle dynamic mount?**

---

<details>
<summary><b>Click to View Answer Keys and Detailed Technical Explanations</b></summary>

### Exercise 1 Answer Key

1.  **`dump` vs `pass` fields in `/etc/fstab`:**
    *   **Column 5 (`dump`):** Used by the `dump(8)` backup utility to determine which filesystems require automatic tape/disk backup. A value of `1` marks the filesystem for backup; `0` ignores it.
    *   **Column 6 (`pass`):** Used by `fsck(8)` during system boot up to determine the sequence in which filesystems are checked.
        *   `0`: Do not check (used for `tmpfs`, `procfs`, `nullfs`, or swap).
        *   `1`: Checked first (strictly reserved for the root filesystem `/`).
        *   `2`: Checked concurrently or sequentially after the root filesystem completes.

2.  **Execution of scripts on `noexec` mounts:**
    *   **Yes**, `sh /mnt/secure_data/script.sh` **will execute**.
    *   **Architectural Reason:** The `noexec` mount flag instructs the VFS layer to fail `execve(2)` system calls originating from vnodes on that filesystem (`MNT_NOEXEC` check in kernel `exec_check_permissions()`). When executing `sh script.sh`, the binary being executed by `execve(2)` is `/bin/sh` (located on `/`), which has execution permissions. `/bin/sh` opens `script.sh` via `read(2)` VFS calls, parses the text stream, and interprets it. `noexec` blocks binary execution, not reading text content.

---

### Exercise 2 Answer Key

1.  **`nullfs` vnode retention and inode numbers:**
    *   `nullfs` creates alias vnodes (`struct null_node`) in the VFS layer that wrap the underlying target vnodes (`lower vnode`).
    *   `nullfs` explicitly **preserves the underlying inode numbers** (`v_id`) and filesystem attributes of the lower filesystem. Executing `stat` or `ls -i` on `/mnt/log_shadow/nullfs_test.log` and `/var/log/nullfs_test.log` will return identical inode numbers because `nullfs` forwards attribute queries (`vop_getattr`) directly to the lower vnode vector.

2.  **Impact of lower filesystem unmounting on `nullfs`:**
    *   If the underlying lower filesystem is unmounted (e.g., using `umount -f /var`), all associated lower vnodes are reclaimed and invalidated (`vgone()`).
    *   Subsequent read/write system calls to open file descriptors on the upper `nullfs` overlay will return `EBADF` or `EIO` (Input/output error), because the underlying `struct vnode` pointers inside the `null_node` wrapper now point to reclaimed/dead vnode operations (`dead_vnodeops`).

---

### Exercise 3 Answer Key

1.  **Kernel mechanics during forced unmount (`umount -f`):**
    *   The kernel bypasses the `v_usecount == 0` validation check inside `vfs_unmount()`.
    *   It executes `vflush(mp, 0, FORCECLOSE)`, traversing all active vnodes associated with the `struct mount`.
    *   Any active vnode is forcibly converted to a dead vnode (`vgone()`), and its ops vector is replaced with `dead_vnodeops`.
    *   Active I/O operations in flight fail immediately. Processes holding open file descriptors receive `EIO` or `ESTALE` on their next read/write/fsync system call. Dirty buffers that were unwritten to disk are discarded, risking filesystem inconsistency if soft updates or journal flushes were pending.

2.  **Purpose of `umount -N`:**
    *   The `-N` flag in BSD `umount(8)` instructs the command to unmount file systems by their **mount point name** directly, bypassing lookup by device node name. This is essential when multiple virtual or layered file systems (such as `nullfs` or dynamic `tmpfs` instances) are mounted from identical pseudo-devices or when resolving ambiguous block device paths.

---

### Exercise 4 Answer Key

1.  **Trade-off between `-o hard` and `-o soft` NFS mounts:**
    *   **`-o hard` (Default/Production Recommended for Data Integrity):** If the remote NFS server stops responding, RPC requests retry indefinitely. Processes attempting I/O block in an uninterruptible sleep state (`D` state in `ps`). The system will **never** corrupt files or return partial write errors to applications, but application threads hang until the server recovers.
    *   **`-o soft` (Recommended for Non-Critical/Transient Data Only):** If an NFS server fails to respond after `retrans` attempts, the kernel returns an I/O error (`EIO`) to the calling application. While this prevents processes from hanging permanently in `D` state, most applications (databases, compilers, file copy tools) do not handle unexpected `EIO` errors gracefully, leading to **silent data corruption or broken file writes**.

2.  **`autofs` inactivity detection and unmount prevention:**
    *   The `autofs` kernel module tracks access times on automounted vnodes. When no VFS lookups or file accesses occur on the mounted filesystem for the duration specified by `-timeout` (default 600s), `automountd(8)` receives a kernel notification to unmount the tree via `vfs_unmount()`.
    *   An idle automount **cannot** be unmounted if:
        1. Any process has its current working directory (`cwd`) inside the mount tree.
        2. Any file descriptor remains open (`v_usecount > 0`).
        3. A active memory mapping (`mmap(2)`) exists for a file on that mount.

</details>