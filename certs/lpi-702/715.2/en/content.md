# LPI 702-100: Advanced BSD Production Study Guide
## Topic 715.2: Perform Basic File Management (Weight: 5)

---

## 1. Production Motivation & Architectural Problem

In enterprise BSD production environments—such as infrastructure running FreeBSD Jails, NetBSD embedded edge appliances, or OpenBSD security firewalls—file management goes far beyond basic command invocation. Platform Architects and Senior SREs must design file pipeline workflows, automated deployments, and storage lifecycle policies that guarantee data integrity, atomic state transitions, crash resistance, and optimal filesystem performance.

### Architectural Core Challenges

#### 1. Atomicity, Storage Boundaries, and the `EXDEV` Constraint
Modern containerized and microservice architectures rely on zero-downtime file deployment strategies. Replacing an active application binary or configuration file via direct copy-truncate (`cp source target`) introduces race conditions where processes read partial writes (TOCTOU: Time-of-Check to Time-of-Use vulnerabilities or corrupted binary execution). 

POSIX and BSD systems provide atomicity through the `rename(2)` system call (`mv`), which swaps directory entries instantaneously within a single VFS filesystem mount. However, when target directories cross filesystem mount boundaries (e.g., moving a file from `/tmp` on `tmpfs` to `/var/db` on `ZFS`), `rename(2)` fails with error `EXDEV` (*Cross-device link*). The operating system falls back to a non-atomic `read(2)` $\rightarrow$ `write(2)` $\rightarrow$ `unlink(2)` sequence. Enterprise automation pipelines must detect storage boundaries to prevent state corruption during software updates.

#### 2. Metadata, Attribute, and Access Control List (ACL) Loss
Standard copy operations create new inodes with default user `umask` settings and update file access/modification timestamps (`atime`/`mtime`). In production migrations or backup validation workflows, failing to preserve POSIX mode bits (`chmod`), user/group ownership (`chown`), Extended Attributes (`xattr`), and BSD-specific file flags (`chflags`) breaches security boundaries and causes application access denials.

#### 3. Storage Amplification via Sparse File Expansion
Container base images, virtual machine disks (`qcow2`, `raw`), and database engines allocation blocks (e.g., PostgreSQL or SQLite WAL files) often utilize *sparse files*, where unwritten block ranges are stored as unallocated metadata rather than zeroed physical disk blocks. Executing naive recursive copy commands without sparse file detection expands gigabytes of hole-allocated virtual space into physical sequential zeros, exhausting storage pools and causing massive I/O saturation.

#### 4. Symlink Traversals and Jail Isolation Leakage
In multi-tenant BSD Jails or restricted environments, recursive file commands (`cp -R`, `rm -rf`) can follow symbolic links pointing outside the intended tenant directory. Misconfigured recursive deletions or copies can cross mount points, dereference circular symlinks causing infinite recursion loops, or unintentionally wipe host-level data.

#### 5. Kernel-Enforced File Immutability (`chflags` and `kern.securelevel`)
BSD filesystems implement extended security attributes (`chflags(2)`) beyond standard POSIX permissions. System immutable (`schg`) and user immutable (`uchg`) flags prevent file modification, deletion, or renaming—even by the `root` superuser (UID 0). Furthermore, when the kernel runs at `kern.securelevel >= 1`, the `schg` flag cannot be removed until the system reboots into single-user mode. Automation pipelines must handle BSD flags explicitly during cleanup and build tasks.

---

## 2. Technical Comparatives & Trade-Off Matrix

### Table 2.1: Production File Copying & Archiving Tools on BSD

| Tool / Mechanism | POSIX / BSD Standard | Metadata Preservation (`flags`, ACLs, timestamps) | Sparse File Handling | Cross-Filesystem Atomicity | I/O Efficiency & Performance | Primary Production Use Case |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`cp` (BSD `cp`)** | POSIX.1-2008 / BSD native | Requires `-p` (mode, owner, time) or `-a` (archive) | Manual (`-S` flag in BSD `cp`) | Non-atomic across mount points | High for single files; moderate for recursive trees | Quick file duplication, config backups within local directory |
| **`mv` (BSD `mv`)** | POSIX.1-2008 / BSD native | Preserved implicitly on same VFS mount | Preserved (inode entry unchanged) | **Atomic** on same VFS; Non-atomic across devices (`EXDEV`) | Instantaneous (inode update) on same VFS | Zero-downtime release deployments, atomic config updates |
| **`pax`** | POSIX Portable Archive Interchange | Full preservation (`-pe` preserves flags, modes, ACLs, times) | Native sparse support | Non-atomic (stream-based copy) | Superior for massive directory trees | Standard POSIX-compliant data migration across BSD systems |
| **`tar` (bsdtar / libarchive)** | BSD standard (`libarchive`) | Full preservation (`--acls`, `--xattrs`, `-p`) | Automatic detection (`S` flag / `--sparse`) | Non-atomic (archive creation/extraction) | High performance; handles streaming pipelines over network | Container rootfs extraction, system backup archives |
| **`rsync`** | Non-standard utility | Full preservation (`-aAXz`, `-H`) | Native sparse detection (`-S`) | Non-atomic (delta transfer to temp file + swap) | Highly optimized (delta transfer algorithm) | Multi-node state replication, remote backups |

---

### Table 2.2: Atomic Updating Strategies

| Strategy | Technical Mechanism | Lock Contention | Cross-Device (`EXDEV`) Safe? | Crash Safety Guarantee | Best Used For |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Copy-Truncate (`cp src dst`)** | In-place `open(O_TRUNC)` + `write()` | High (processes read partial data) | Yes | **Poor** (file left truncated on crash) | Log truncation, live updates where file descriptor cannot change |
| **Atomic Rename (`mv -f tmp dst`)** | Invokes `rename(2)` syscall | Zero (VFS directory entry swapped) | **No** (fails with `EXDEV`) | **Excellent** (original file remains untouched until VFS commit) | Application binary releases, configuration file updates |
| **Symlink Swapping (`ln -sfn new current`)** | Atomic update of symbolic link pointer | Zero | Yes | **Excellent** (link updated via `symlink(2)` / atomic pointer) | Zero-downtime deployment directories (blue/green releases) |

---

### Table 2.3: Link Architecture: Hard Links vs. Soft (Symbolic) Links

| Metric / Feature | Hard Link (`ln file link`) | Soft / Symbolic Link (`ln -s file link`) |
| :--- | :--- | :--- |
| **Target Inode Relation** | Points directly to existing inode number | Occupies a **new inode** containing target path string |
| **Cross-Filesystem Support** | **No** (limited to single VFS filesystem) | **Yes** (can point to any path across devices) |
| **Directory Target Support** | **No** (restricted by kernel to prevent loops) | **Yes** (can link directories) |
| **Behavior on Source Deletion** | Target file data persists until link count drops to 0 | Link breaks (becomes dangling / orphan link) |
| **BSD Security / Jail Impact** | Cannot escape jail if original file resides inside jail | Can point outside jail root if target path is absolute |

---

## 3. Complete Infrastructure Manifests & Automated Provisioning

### Manifest 3.1: FreeBSD Jail Production Configuration (`/etc/jail.conf.d/app_jail.conf`)

This configuration enforces strict storage boundaries, mount-point isolation, nullfs read-only protection, and staging layout management for containerized microservices.

```ini
# /etc/jail.conf.d/app_jail.conf
# Complete production FreeBSD Jail specification for secure file management isolation

# Global Jail Defaults
exec.start = "/bin/sh /etc/rc";
exec.stop = "/bin/sh /etc/rc.shutdown";
exec.clean;
mount.devfs;
devfs.ruleset = 4;

# Primary Application Jail
app_service {
    # System Host Integration
    host.hostname = "app-service.prod.internal";
    ip4.addr = 10.0.100.25;
    interface = "vnet0";
    
    # Path Specification & Mount Management
    path = "/usr/jails/app_service";
    
    # Storage Boundaries - Fstab containing nullfs and zfs mounts
    mount.fstab = "/usr/jails/configs/app_service.fstab";
    
    # Security Controls
    allow.raw_sockets = 0;
    allow.chflags = 0;
    securelevel = 2;
    
    # Jail Operational Tasks
    exec.prestart  = "/bin/mkdir -p /usr/jails/app_service/var/staging";
    exec.prestart += "/sbin/mount -t nullfs -o ro /usr/releases/app/current /usr/jails/app_service/usr/local/bin/app";
    exec.poststop  = "/sbin/umount -f /usr/jails/app_service/usr/local/bin/app || true";
    exec.poststop += "/bin/rm -rf /usr/jails/app_service/var/staging/*";
}
```

---

### Manifest 3.2: Automated Production Staging & Atomic Deployment Pipeline (`/usr/local/bin/deploy_service.sh`)

A complete, production-grade POSIX shell pipeline script demonstrating file management, metadata validation, sparse detection, and atomic directory deployment.

```sh
#!/bin/sh
# /usr/local/bin/deploy_service.sh
# Production Deployment Pipeline with Atomic File Swapping and Flag Protection

set -eu

# Define Environment Paths
BASE_DIR="/var/db/deployments/app_service"
STAGING_DIR="${BASE_DIR}/staging"
RELEASES_DIR="${BASE_DIR}/releases"
CURRENT_SYMLINK="${BASE_DIR}/current"
RELEASE_ID=$(date +%Y%m%d_%H%M%S)
NEW_RELEASE_DIR="${RELEASES_DIR}/${RELEASE_ID}"
ARTIFACT_TARBALL="/tmp/artifacts/release_${RELEASE_ID}.tar.gz"

log_info() {
    printf "[INFO] %s: %s\n" "$(date +'%Y-%m-%dT%H:%M:%SZ')" "$1"
}

log_error() {
    printf "[ERROR] %s: %s\n" "$(date +'%Y-%m-%dT%H:%M:%SZ')" "$1" >&2
}

cleanup_staging() {
    log_info "Cleaning up staging directory..."
    if [ -d "${STAGING_DIR}" ]; then
        # Remove immutable flags if set during failed operations
        chflags -R noschg "${STAGING_DIR}" 2>/dev/null || true
        rm -rf "${STAGING_DIR}"
    fi
}

trap cleanup_staging EXIT INT TERM

# Step 1: Pre-Flight Environment Checks
log_info "Starting deployment sequence for release ${RELEASE_ID}"

if [ ! -f "${ARTIFACT_TARBALL}" ]; then
    log_error "Artifact tarball ${ARTIFACT_TARBALL} not found!"
    exit 1
fi

# Step 2: Create Staging and Target Release Directories
mkdir -p "${STAGING_DIR}" "${RELEASES_DIR}"

# Step 3: Extract Artifacts using BSD tar with Metadata Preservation
log_info "Extracting artifact to staging area..."
tar -xzpf "${ARTIFACT_TARBALL}" -C "${STAGING_DIR}"

# Step 4: Validate File Types and Binary Headers
log_info "Validating executable binaries..."
for binary in "${STAGING_DIR}/bin/"*; do
    if [ -f "${binary}" ]; then
        FILE_TYPE=$(file -b --mime-type "${binary}")
        if [ "${FILE_TYPE}" != "application/x-executable" ] && [ "${FILE_TYPE}" != "application/x-sharedlib" ]; then
            log_error "File ${binary} is not a valid executable binary! (Type: ${FILE_TYPE})"
            exit 1
        fi
    fi
done

# Step 5: Transfer Staging to Target Release via PAX (Preserving Attributes & Sparse Files)
log_info "Transferring staging structure to release directory ${NEW_RELEASE_DIR}..."
mkdir -p "${NEW_RELEASE_DIR}"
(cd "${STAGING_DIR}" && pax -rw -pe -v . "${NEW_RELEASE_DIR}")

# Step 6: Apply Security Flags to Application Binaries
log_info "Applying BSD System Immutable (schg) flags to binaries..."
chflags schg "${NEW_RELEASE_DIR}/bin/"* || log_info "Warning: Unable to set schg flag (securelevel constraint)"

# Step 7: Atomic Symlink Switchover
log_info "Performing atomic symlink release update..."
TMP_SYMLINK="${BASE_DIR}/current_tmp_${RELEASE_ID}"
ln -sfn "${NEW_RELEASE_DIR}" "${TMP_SYMLINK}"
mv -f "${TMP_SYMLINK}" "${CURRENT_SYMLINK}"

# Step 8: Purge Old Releases (Retention: Keep last 5 releases)
log_info "Purging old releases..."
cd "${RELEASES_DIR}"
ls -1t | tail -n +6 | while read -r old_release; do
    if [ -n "${old_release}" ]; then
        log_info "Removing old release: ${old_release}"
        chflags -R noschg "${old_release}" 2>/dev/null || true
        rm -rf "${old_release}"
    fi
done

log_info "Deployment of release ${RELEASE_ID} successfully completed."
exit 0
```

---

## 4. Real-World CLI Commands & Terminal Outputs

### Command 1: Creating Complex Production Directory Layouts with `mkdir`
Demonstrates creating nested directory hierarchies, setting default mode permissions, and inspecting absolute path properties.

```bash
$ mkdir -pv -m 0750 /var/db/app/{bin,config,data,logs,staging/temp}
```

```text
/var/db/app/bin
/var/db/app/config
/var/db/app/data
/var/db/app/logs
/var/db/app/staging
/var/db/app/staging/temp
```

---

### Command 2: Deep File Inspection with BSD `ls` and `stat`
Listing file metadata including inode numbers, BSD flags, POSIX file modes, ownership, and allocation size.

```bash
$ ls -laoi /var/db/app/
```

```text
total 24
784121 drwxr-x---  7 appuser  appgroup  -        512 Aug 06 20:45 .
512002 drwxr-xr-x  4 root     wheel     -        512 Aug 06 20:40 ..
784122 drwxr-x---  2 appuser  appgroup  schg     512 Aug 06 20:45 bin
784123 drwxr-x---  2 appuser  appgroup  -        512 Aug 06 20:45 config
784124 drwxr-x---  2 appuser  appgroup  nodump   512 Aug 06 20:45 data
784125 drwxr-x---  2 appuser  appgroup  -        512 Aug 06 20:45 logs
784126 drwxr-x---  3 appuser  appgroup  -        512 Aug 06 20:45 staging
```

Detailed formatting output with `stat` on BSD:

```bash
$ stat -f "File: %N | Inode: %i | Mode: %Sp (%Lp) | Owner: %Su:%Sg | Flags: %f | Size: %z bytes" /var/db/app/bin
```

```text
File: /var/db/app/bin | Inode: 784122 | Mode: drwxr-x--- (0750) | Owner: appuser:appgroup | Flags: schg | Size: 512 bytes
```

---

### Command 3: Accurate MIME Type Identification using `file`
Determining internal structural content of files regardless of extension.

```bash
$ file -b --mime-type /var/db/app/config/settings.json /var/db/app/bin/service_worker /var/db/app/logs/system.log
```

```text
application/json
application/x-executable
text/plain
```

Inspecting block device nodes and file system superblocks:

```bash
$ file -s /dev/ada0s1a
```

```text
/dev/ada0s1a: Unix Fast File system (FFS2) with dump dates, data blocks, cylinder groups, volume label , light application
```

---

### Command 4: Attribute-Preserving Recursive Copying with BSD `cp`
Executing a metadata-preserving recursive copy, controlling symlink traversal (`-R` with `-P`), and enforcing sparse file preservation (`-S`).

```bash
$ cp -RPpS /var/db/app/staging/temp/ /var/db/app/data/
$ echo $?
```

```text
0
```

---

### Command 5: Native POSIX Directory Migration with `pax`
Migrating dynamic state data to a new filesystem volume while preserving flags, ACLs, and hard link structures.

```bash
$ cd /var/db/app/data && pax -rw -pe -v -X . /mnt/backup_volume/data/
```

```text
.
./db_primary.sqlite
./db_primary.sqlite-wal
./sessions
./sessions/sess_982b1a
```

---

### Command 6: Managing BSD File Flags via `chflags`
Applying and removing system immutable (`schg`) and user undeletable (`sunlnk`) protection.

```bash
$ touch /var/db/app/config/protected_core.cfg
$ sudo chflags schg,sunlnk /var/db/app/config/protected_core.cfg
$ rm -f /var/db/app/config/protected_core.cfg
```

```text
rm: /var/db/app/config/protected_core.cfg: Operation not permitted
```

Unset the flags to allow maintenance:

```bash
$ sudo chflags noschg,nosunlnk /var/db/app/config/protected_core.cfg
$ rm -fv /var/db/app/config/protected_core.cfg
```

```text
/var/db/app/config/protected_core.cfg
```

---

### Command 7: Efficient Archiving and Compression with BSD `tar`
Creating a sparse-aware, compressed tarball archive while preserving system extended attributes.

```bash
$ tar --format=pax --acls --xattrs -czvf /tmp/app_backup_$(date +%Y%m%d).tar.gz -C /var/db/app data config
```

```text
a data
a data/db_primary.sqlite
a data/db_primary.sqlite-wal
a data/sessions
a config
a config/settings.json
```

Verifying archive contents without extraction:

```bash
$ tar -tvf /tmp/app_backup_20260806.tar.gz
```

```text
drwxr-x---  0 appuser appgroup       0 Aug 06 20:45 data
-rw-r-----  0 appuser appgroup 1048576 Aug 06 20:45 data/db_primary.sqlite
-rw-r-----  0 appuser appgroup   32768 Aug 06 20:45 data/db_primary.sqlite-wal
drwxr-x---  0 appuser appgroup       0 Aug 06 20:45 data/sessions
drwxr-x---  0 appuser appgroup       0 Aug 06 20:45 config
-rw-r-----  0 appuser appgroup    1240 Aug 06 20:45 config/settings.json
```

---

## 5. Failure Verification & Troubleshooting Guide

### Diagnostic Matrix for High-Impact Production Failures

```
                    +-------------------------------------+
                    | File Management Operation Failure   |
                    +-------------------------------------+
                                       |
           +---------------------------+---------------------------+
           |                                                       |
[ Operation Not Permitted ]                              [ Cross-Device Link ]
           |                                                       |
   v       v       v                                               v
Inspect file flags:                                      Detect mount boundaries:
`ls -lo` or `stat -f %f`                                 `df -h <src> <dst>`
   |                                                       |
   +--> Contains `schg`/`uchg`?                            +--> Different filesystems?
   |    YES: `chflags noschg`                                   YES: Use `pax -rw` or 
   |                                                                 `cp -RPp` then `rm`.
   +--> Check Kernel Securelevel:
        `sysctl kern.securelevel`
        If >= 1: CANNOT clear `schg`.
        Fix: Reboot to single-user mode.
```

---

### Troubleshooting Scenarios & Resolution Protocols

#### Scenario A: `rm: filename: Operation not permitted` (Superuser Deletion Failure)
* **Root Cause:** File possesses the BSD system immutable flag (`schg`) or user immutable flag (`uchg`). Even `root` cannot delete or truncate files marked with `schg`.
* **Diagnostic Step:**
  ```bash
  $ ls -lO /var/log/security.audit
  -rw-------  1 root  wheel  schg 4096 Aug 06 18:00 /var/log/security.audit
  ```
  Check the active kernel security level:
  ```bash
  $ sysctl kern.securelevel
  kern.securelevel: 1
  ```
* **Resolution Protocol:**
  1. If `kern.securelevel` is `0` or `-1`:
     ```bash
     $ sudo chflags noschg /var/log/security.audit
     $ sudo rm -f /var/log/security.audit
     ```
  2. If `kern.securelevel` is `>= 1`:
     Modifying `schg` is blocked at the kernel level. Boot into single-user mode (`boot -s` at loader prompt) where `securelevel` starts at `-1`, modify flags via `chflags noschg`, and complete system recovery.

---

#### Scenario B: `mv: /tmp/app_staging to /var/db/app: Cross-device link (EXDEV)`
* **Root Cause:** Attempting to execute an atomic `rename(2)` across distinct physical mount points or virtual memory filesystems (e.g., `/tmp` on `tmpfs` and `/var` on `ZFS`).
* **Diagnostic Step:**
  ```bash
  $ df -Th /tmp/app_staging /var/db/app
  ```
  ```text
  Filesystem     Type    Size  Used Avail Capacity  Mounted on
  tmpfs          tmpfs   8.0G  512M  7.5G     6%    /tmp
  zroot/ROOT/default zfs 450G   45G  405G    10%    /
  ```
* **Resolution Protocol:**
  Do not use `mv` when atomicity across mounts is required. Implement staging directories within the target filesystem namespace (e.g., `/var/db/app/.staging`):
  ```bash
  # Correct architectural workflow:
  $ mkdir -p /var/db/app/.staging
  $ pax -rw -pe /tmp/app_staging/ /var/db/app/.staging/
  $ mv -f /var/db/app/.staging /var/db/app/live_release
  ```

---

#### Scenario C: Space Exhaustion During Sparse Virtual Disk Backup
* **Root Cause:** A raw disk image containing 100GB of logical size with only 5GB of written data was copied without sparse file awareness, expanding physical usage to 100GB.
* **Diagnostic Step:**
  Compare reported file length vs. actual allocated disk blocks:
  ```bash
  $ ls -lh /virtual/images/vm_disk.raw
  -rw-r--r--  1 root  wheel   100G Aug 06 19:00 /virtual/images/vm_disk.raw
  
  $ du -h /virtual/images/vm_disk.raw
  5.0G    /virtual/images/vm_disk.raw
  ```
  Check the corrupted copy output:
  ```bash
  $ du -h /backup/images/vm_disk_copy.raw
  100G    /backup/images/vm_disk_copy.raw
  ```
* **Resolution Protocol:**
  Use sparse-aware tools (`cp -S` on BSD or `cp --sparse=always` on GNU tools, or `tar -S`):
  ```bash
  $ cp -S /virtual/images/vm_disk.raw /backup/images/vm_disk_sparse.raw
  $ du -h /backup/images/vm_disk_sparse.raw
  5.0G    /backup/images/vm_disk_sparse.raw
  ```

---

#### Scenario D: Unlinked Files Consuming Disk Space ("Ghost Storage")
* **Root Cause:** A heavy log or data file was deleted with `rm` while an active application process held an open file descriptor. The VFS unlinks the directory entry, but blocks remain allocated until the file descriptor closes.
* **Diagnostic Step:**
  Check ZFS or UFS filesystem space mismatch:
  ```bash
  $ df -h /var
  # Shows high consumption (e.g., 95% full)
  $ du -d 1 -h /var
  # Shows low sum of files (e.g., 10% used)
  ```
  Identify process holding unlinked file descriptors using `fstat` (BSD native):
  ```bash
  $ sudo fstat /var | grep -i "N/A\|deleted"
  ```
  ```text
  appuser  app_daemon 84920   3* pipe 0xfffffe0045ab2100 <-> 0xfffffe0045ab2280
  appuser  app_daemon 84920    4 /var  3294812 -rw-r----- 10737418240 r
  ```
* **Resolution Protocol:**
  Restart the holding daemon to release the file descriptor:
  ```bash
  $ sudo service app_daemon restart
  ```
  To prevent future occurrences, truncate live logs via `copytruncate` or `cat /dev/null > /var/log/app.log` instead of issuing `rm` on active log files.

---

## 6. References

* **Linux Professional Institute (LPI) Official BSD Specialist Overview:**  
  [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

* **LPI Wiki BSD Specialist Objectives V1.0 (Topic 715.2):**  
  [https://wiki.lpi.org/wiki/BSD_Specialist_Objectives_V1.0](https://wiki.lpi.org/wiki/BSD_Specialist_Objectives_V1.0)

* **FreeBSD Manual Pages - `cp(1)` File Copy Utility:**  
  [https://man.freebsd.org/cgi/man.cgi?query=cp&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=cp&sektion=1)

* **FreeBSD Manual Pages - `chflags(1)` System & User Flags:**  
  [https://man.freebsd.org/cgi/man.cgi?query=chflags&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=chflags&sektion=1)

* **FreeBSD Manual Pages - `pax(1)` Portable Archive Interchange:**  
  [https://man.freebsd.org/cgi/man.cgi?query=pax&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=pax&sektion=1)

* **FreeBSD Manual Pages - `stat(1)` File Status Display:**  
  [https://man.freebsd.org/cgi/man.cgi?query=stat&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=stat&sektion=1)

* **FreeBSD Manual Pages - `rename(2)` Atomic File Name System Call:**  
  [https://man.freebsd.org/cgi/man.cgi?query=rename&sektion=2](https://man.freebsd.org/cgi/man.cgi?query=rename&sektion=2)