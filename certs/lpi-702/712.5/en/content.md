# LPI-702 (Exam 702-100) Topic 712.5: Create and Change Hard and Symbolic Links

**Exam Topic**: 712.5 Create and Change Hard and Symbolic Links  
**Weight**: 1.67  
**Target Certification**: LPI BSD Specialist (Exam 702-100, Version 1.0)  

---

## 1. Production Architectural Motivation & Core Mechanics

In enterprise Unix and BSD infrastructure (FreeBSD, OpenBSD, NetBSD), filesystem pointer abstractions dictate how binaries, libraries, configuration trees, dynamic deployments, and container storage backends interact with Virtual File System (VFS) layers.

```
       Directory Entry (dirent)              Inode (UFS2 / znode)           Storage Blocks
+------------------------------------+    +------------------------+    +--------------------+
| Filename: app.conf                 |--->| Inode Number: 1048578  |--->| [ Block Data ]     |
| Pointer:  1048578                  |    | st_nlink: 2            |    | "server_name: ..." |
+------------------------------------+    | st_mode:  -rw-r--r--   |    +--------------------+
                                          +------------------------+              ^
                                                      ^                           |
       Directory Entry (dirent)                       |                           |
+------------------------------------+                |                           |
| Filename: app.conf.hardlink        |----------------+                           |
| Pointer:  1048578                  |                                            |
+------------------------------------+                                            |
                                                                                  |
       Directory Entry (dirent)              Inode (UFS2 / znode)                 |
+------------------------------------+    +------------------------+              |
| Filename: app.conf.symlink         |--->| Inode Number: 2097152  |              |
| Pointer:  2097152                  |    | st_nlink: 1            |              |
+------------------------------------+    | st_mode:  lrwxrwxrwx   |              |
                                          | Target: "app.conf"     |--------------+
                                          +------------------------+ (Fast Symlink / Direct inline string)
```

### 1.1 Inodes vs. Directory Entries (dirents)
A file in a Unix/BSD filesystem (such as UFS2 or ZFS) consists of two distinct components:
1. **Metadata Index Node (Inode / znode)**: Contains metadata including permissions (`st_mode`), owner (`st_uid`), group (`st_gid`), size (`st_size`), timestamp array (`st_atim`, `st_mtim`, `st_ctim`), hard link counter (`st_nlink`), and data block pointers. Crucially, the inode does **not** contain the filename.
2. **Directory Entry (`dirent`)**: A simple mapping stored inside a directory data block that pairs a human-readable filename string with an inode integer number.

### 1.2 Hard Links Engine (`link(2)`)
A hard link creates a new directory entry (`dirent`) pointing to an **already existing inode number** on the same filesystem instance.
* **Metadata Impact**: Executing `link(2)` increments the inode's `st_nlink` counter by 1.
* **Deletion Mechanics**: Calling `unlink(2)` on a hard-linked filename removes the specified directory entry and decrements `st_nlink`. The underlying storage blocks and inode structure are freed by the kernel VFS memory management subsytem **only when `st_nlink` reaches 0** and all open file descriptors (`open(2)`) pointing to the inode are closed.
* **Constraint**: Hard links cannot cross filesystem boundaries because inode numbers are strictly local to a specific VFS mount identifier (`fsid`). They cannot target directories (with rare system-level exceptions) to prevent cycles in the directory graph hierarchy that break path resolution engines (`namei(9)`).

### 1.3 Symbolic Links Engine (`symlink(2)`)
A symbolic link (symlink or soft link) is a distinct, standalone file object allocated with its **own unique inode number** and a special file mode bit mask (`S_IFLNK`).
* **Content**: The data payload stored in a symlink is simply a text path string pointing to a target relative or absolute destination.
* **Fast Symlink vs. Slow Symlink Optimization**:
  * **Fast Symlink (Inline)**: If the target path string length is shorter than the inode's internal data pointer array space (e.g., $< 60$ bytes in UFS2), the kernel stores the path string directly inside the inode structure itself (`i_shortlink`). This avoids allocating extra disk data blocks, resulting in `st_blocks == 0`.
  * **Slow Symlink (Allocated)**: If the target path exceeds the inline limit, dedicated data block(s) are allocated to hold the target string, incrementing `st_blocks > 0`.
* **Path Resolution**: When kernel `namei(9)` encounters an `S_IFLNK` object during path lookup, it reads the stored path string, replaces the link component, and restarts path resolution up to a system-defined recursion limit (`MAXSYMLINKS`, typically 32 on FreeBSD).

### 1.4 Production Use Cases: Atomic Blue/Green Deployments
In enterprise FreeBSD / SRE web clusters, symbolic links enable **zero-downtime application deployments**. By pointing a static web server document root symlink (`/var/www/current`) to a new build release directory (`/var/www/releases/20260806_v2`), microservices can be updated atomically using an atomic `rename(2)` system call over symlinks, completely avoiding partial file read conditions during ongoing HTTP traffic.

---

## 2. Technical Comparison & Trade-off Matrix

| Metric / Dimension | Hard Link (`ln target link`) | Relative Symlink (`ln -s target link`) | Absolute Symlink (`ln -s /path/target link`) | Nullfs / Mount Bind (`mount_nullfs`) |
| :--- | :--- | :--- | :--- | :--- |
| **Inode Allocation** | Shares target inode | Allocates new unique inode | Allocates new unique inode | Reuses target VFS node via mount table entry |
| **Cross-Filesystem Support** | **No** (Fails with `EXDEV`) | **Yes** | **Yes** | **Yes** (Mounts across devices) |
| **Target Type Support** | Files only | Files and Directories | Files and Directories | Directories and Filesystems |
| **Target Deletion Impact** | Data retained (accessible via link) | Link breaks (Dangling link, `ENOENT`) | Link breaks (Dangling link, `ENOENT`) | Original target remains accessible |
| **Path Relocation Safety** | **High**: Moving link or file retains mapping | **High**: Portable if link & target move together | **Low**: Breaks if top-level directory structure shifts | **High**: Kernel mount table handles mapping |
| **Kernel Lookup Overhead (`namei`)** | Direct inode resolution ($O(1)$) | Re-evaluates string path ($O(N)$ lookups) | Re-evaluates root path string ($O(N)$ lookups) | VFS node translated via layer ops |
| **Atomic Replacement Flag** | `ln -f` | `ln -sfn` / `ln -shf` | `ln -sfn` / `ln -shf` | Requires `umount` + `mount` sequence |

---

## 3. Infrastructure & Deployment Manifests

### 3.1 FreeBSD Zero-Downtime Blue/Green Release Engine
The following production shell script demonstrates robust POSIX/BSD atomic symbolic link updates, preventing nested directory bugs when replacing symlinks pointing to directories.

```sh
#!/bin/sh
# /usr/local/bin/deploy-app.sh
# Production FreeBSD Atomic Symlink Deployment Script
set -eu

APP_ROOT="/var/www/apps/myapp"
RELEASES_DIR="${APP_ROOT}/releases"
CURRENT_LINK="${APP_ROOT}/current"
NEW_RELEASE_ID="$(date -u +'%Y%m%d_%H%M%S')"
TARGET_DIR="${RELEASES_DIR}/${NEW_RELEASE_ID}"
TMP_LINK="${APP_ROOT}/current.tmp.${NEW_RELEASE_ID}"

echo "[INFO] Initializing deployment payload: ${NEW_RELEASE_ID}"
mkdir -p "${TARGET_DIR}"

# Populate new application artifacts
cat << 'EOF' > "${TARGET_DIR}/index.html"
<!DOCTYPE html>
<html>
<head><title>Production Deployment</title></head>
<body><h1>Application Release Active</h1></body>
</html>
EOF

# Ensure target permissions match web server worker context (www:www)
chown -R www:www "${TARGET_DIR}"

echo "[INFO] Creating temporary atomic symlink: ${TMP_LINK} -> ${TARGET_DIR}"
# POSIX / FreeBSD symlink creation targeting directory
ln -s "${TARGET_DIR}" "${TMP_LINK}"

echo "[INFO] Performing atomic link swap via rename(2)"
# BSD rename(2) atomicity guarantees that readers never encounter a missing target
mv -f -h "${TMP_LINK}" "${CURRENT_LINK}"

echo "[SUCCESS] Active deployment link pointing to: $(readlink "${CURRENT_LINK}")"
```

### 3.2 Kubernetes Local Persistent Volume HostPath Manifest
When mounting local filesystems containing symlinks into container runtime environments, understanding symlink resolution and path boundary enforcement is vital.

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: bsd-local-storage-pv
  labels:
    type: local
    environment: production
spec:
  capacity:
    storage: 50Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /mnt/zfs_data/app_storage
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - bsd-node-01.prod.internal
---
apiVersion: v1
kind: Pod
metadata:
  name: nginx-symlink-service
  namespace: production
spec:
  containers:
    - name: nginx-web
      image: nginx:1.25-alpine
      ports:
        - containerPort: 80
      volumeMounts:
        - name: app-volume
          mountPath: /usr/share/nginx/html
          # Note: Symlinks inside the mounted directory pointing outside /usr/share/nginx/html
          # will be rejected by standard web server security controls unless FollowSymLinks is set.
  volumes:
    - name: app-volume
      persistentVolumeClaim:
        claimName: bsd-local-storage-pvc
```

---

## 4. Real CLI Commands & Terminal Outputs ($)

The following terminal session illustrates complete, real-world execution on a FreeBSD 14.x system executing standard BSD utilities (`ln`, `ls`, `stat`, `readlink`, `sysctl`, `truss`).

### 4.1 Creating and Inspecting Hard Links

```syslog
$ cd /tmp
$ mkdir -p link_demo && cd link_demo
$ echo "Production Database Secret Payload" > secret.key

$ ls -li secret.key
 1048712 -rw-r--r--  1 root  wheel  35 Aug  6 20:30 secret.key

$ ln secret.key secret.key.hardlink

$ ls -li secret.key*
 1048712 -rw-r--r--  2 root  wheel  35 Aug  6 20:30 secret.key
 1048712 -rw-r--r--  2 root  wheel  35 Aug  6 20:30 secret.key.hardlink

$ stat -f "Inode: %i | HardLinks: %l | Size: %z bytes" secret.key
Inode: 1048712 | HardLinks: 2 | Size: 35 bytes
```

### 4.2 Demonstrating Inline Fast Symlinks vs. Slow Symlinks

```syslog
$ ln -s secret.key short_sym.link
$ ln -s /var/db/system/production/cluster/nodes/node01/data/storage/configuration/very_long_path_target.key long_sym.link

$ ls -li *_sym.link
 1048713 lrwxr-xr-x  1 root  wheel  10 Aug  6 20:32 short_sym.link -> secret.key
 1048714 lrwxr-xr-x  1 root  wheel  86 Aug  6 20:32 long_sym.link -> /var/db/system/production/cluster/nodes/node01/data/storage/configuration/very_long_path_target.key

$ stat -f "Name: %N | Inode: %i | Size: %z | Allocated Blocks: %b" short_sym.link
Name: short_sym.link | Inode: 1048713 | Size: 10 | Allocated Blocks: 0

$ stat -f "Name: %N | Inode: %i | Size: %z | Allocated Blocks: %b" long_sym.link
Name: long_sym.link | Inode: 1048714 | Size: 86 | Allocated Blocks: 2
```

### 4.3 Attempting Cross-Filesystem Hard Link (Handling `EXDEV`)

```syslog
$ df -h /tmp /dev
Filesystem     Size    Used   Avail Capacity  Mounted on
zroot/tmp      100G    1.2M    100G     0%    /tmp
devfs          1.0K    1.0K      0B   100%    /dev

$ ln /tmp/link_demo/secret.key /dev/secret.key.hardlink
ln: /dev/secret.key.hardlink: Cross-device link

$ echo $?
1
```

### 4.4 FreeBSD Directory Symlink Replacement: The `-n` / `-h` Flag Requirement

When replacing a symlink pointing to a directory, standard `ln -sf` will dereference the symlink and place a new link *inside* the target directory unless `-n` (or `-h` in BSD) is provided.

```syslog
$ mkdir -p v1_dir v2_dir
$ echo "Version 1" > v1_dir/app.txt
$ echo "Version 2" > v2_dir/app.txt

$ ln -s v1_dir active_dir
$ readlink active_dir
v1_dir

# Incorrect replacement without -n / -h flag:
$ ln -sf v2_dir active_dir
$ ls -la v1_dir/
total 12
drwxr-xr-x  2 root  wheel  3 Aug  6 20:35 .
drwxr-xr-x  5 root  wheel  6 Aug  6 20:35 ..
-rw-r--r--  1 root  wheel 10 Aug  6 20:35 app.txt
lrwxr-xr-x  1 root  wheel  6 Aug  6 20:35 v2_dir -> v2_dir

# Correct replacement using BSD -shf (or -sfn):
$ rm -rf v1_dir/v2_dir
$ ln -shf v2_dir active_dir
$ readlink active_dir
v2_dir
```

### 4.5 Tracing System Calls via `truss` (FreeBSD)

```syslog
$ truss -t symlink,link,unlink,rename ln -shf v1_dir active_dir
symlink("v1_dir","active_dir")                  ERR#17 'File exists'
unlink("active_dir")                            = 0 (0x0)
symlink("v1_dir","active_dir")                  = 0 (0x0)
process exit status=0
```

---

## 5. Verification, Hardening & Failure Diagnostics

### 5.1 System Security: Kernel Symlink & Hardlink Protection Controls
On modern BSD and Linux platforms, symbolic link traversal and hard link creation in world-writable sticky directories (`/tmp`, `/var/tmp`) are common attack vectors for Privilege Escalation and Symlink Vulnerabilities (TOCTOU / Time-of-Check to Time-of-Use race conditions).

```syslog
# Inspecting FreeBSD Security Kernel Constraints via sysctl
$ sysctl security.bsd.hardlink_check_uid security.bsd.hardlink_check_gid
security.bsd.hardlink_check_uid: 1
security.bsd.hardlink_check_gid: 1

# Enabling stricter link protection rules
$ sysctl security.bsd.hardlink_check_uid=1
$ sysctl security.bsd.see_other_uids=0
```

* **`security.bsd.hardlink_check_uid = 1`**: Prevents unprivileged users from creating hard links to files they do not own, stopping attacks targeting system binaries or restricted log files.
* **`security.bsd.hardlink_check_gid = 1`**: Restricts hard link creation based on group ownership match.

### 5.2 Diagnostic Matrix & Troubleshooting Recipes

#### Issue 1: Dangling / Broken Symbolic Links
* **Symptom**: Applications throw `ENOENT` (No such file or directory) even though `ls active.conf` lists the file.
* **Root Cause**: The symlink exists, but its target path string points to a deleted or non-existent file.
* **Diagnostic Command**:
  ```syslog
  $ find -L /var/www/apps -type l
  /var/www/apps/myapp/current.conf -> /var/www/apps/releases/old_build/app.conf
  ```
  *(The `-L` flag instructs `find` to follow symbolic links; if a link target is missing, `find -L` evaluates the symlink as broken).*

#### Issue 2: Inode Exhaustion despite Available Disk Space
* **Symptom**: `write failed: No space left on device` (Error `ENOSPC`), but `df -h` shows plenty of gigabytes available.
* **Root Cause**: An abundance of micro-files or improper hard link tracking has depleted total available filesystem inodes.
* **Diagnostic Command**:
  ```syslog
  $ df -i /var
  Filesystem  1K-blocks  Used   Avail Capacity iused IFree %iused Mounted on
  zroot/var    52428800 12400 52416400     0% 327680     0  100%  /var
  ```
* **Resolution**: Locate directories consuming abnormally high inode counts:
  ```syslog
  $ find /var -xdev -type f | awk -F/ '{print $1"/"$2"/"$3}' | sort | uniq -c | sort -nr | head -n 10
  ```

#### Issue 3: `EXDEV` (Cross-device link error)
* **Symptom**: `ln: /mnt/data/file.txt /var/data/file.txt: Cross-device link`.
* **Root Cause**: `ln` attempted to create a hard link spanning across two separate VFS mounts or ZFS datasets.
* **Resolution**: Replace the hard link command with a symbolic link (`ln -s`) or use a BSD nullfs mount (`mount_nullfs`).

---

## 6. References

* **LPI Official BSD Specialist Overview**:  
  https://www.lpi.org/our-certifications/bsd-specialist-overview/
* **FreeBSD Manual Page — `ln(1)` Utility**:  
  https://man.freebsd.org/cgi/man.cgi?query=ln&sektion=1
* **FreeBSD Manual Page — `symlink(7)` Concepts**:  
  https://man.freebsd.org/cgi/man.cgi?query=symlink&sektion=7
* **FreeBSD Manual Page — `link(2)` System Call**:  
  https://man.freebsd.org/cgi/man.cgi?query=link&sektion=2
* **FreeBSD Manual Page — `namei(9)` Path Resolution**:  
  https://man.freebsd.org/cgi/man.cgi?query=namei&sektion=9
* **POSIX IEEE Std 1003.1 — `ln` Specification**:  
  https://pubs.opengroup.org/onlinepubs/9699919799/utilities/ln.html