# LPIC-2 (Exams 201-450 & 202-450, v4.5) — Topic 206 / 1.7: System Maintenance
**Exam Weight:** 8  
**Target Audience:** SREs, Platform Engineers, and Senior Linux Systems Administrators preparing for LPIC-2 certification.

---

## Official Reference Documentation & Specifications

- **LPI LPIC-2 Objectives & Overview:**  
  [https://www.lpi.org/our-certifications/lpic-2-overview/](https://www.lpi.org/our-certifications/lpic-2-overview/)
- **GNU Autotools & Configure Build System Specification:**  
  [https://www.gnu.org/software/autoconf/manual/autoconf.html](https://www.gnu.org/software/autoconf/manual/autoconf.html)
- **GNU Make Reference Manual:**  
  [https://www.gnu.org/software/make/manual/make.html](https://www.gnu.org/software/make/manual/make.html)
- **GNU Tar Specification and Incremental Backup Algorithms:**  
  [https://www.gnu.org/software/tar/manual/html_node/Using-tar-to-Perform-Incremental-Dumps.html](https://www.gnu.org/software/tar/manual/html_node/Using-tar-to-Perform-Incremental-Dumps.html)
- **rsync Remote Update Protocol & Delta-Transfer Algorithm:**  
  [https://rsync.samba.org/tech_report/](https://rsync.samba.org/tech_report/)
- **Linux PAM (Pluggable Authentication Modules) & MOTD Architecture:**  
  [https://man7.org/linux/man-pages/man8/pam_motd.8.html](https://man7.org/linux/man-pages/man8/pam_motd.8.html)

---

## 1. Deep-Dive Technical Architecture & Internal Mechanics

### 1.1 Source Code Compilation, Build Systems, and Shared Library Linkage

Building production software from source requires an understanding of compilation stages, preprocessor flags, linker behaviors, and install prefixes.

```
                  +-------------------------------------------------------+
                  |                 Source Files (.c, .h)                 |
                  +-------------------------------------------------------+
                                              |
                                              v  C Preprocessor (cpp / CFLAGS)
                  +-------------------------------------------------------+
                  |               Expanded Source Code                    |
                  +-------------------------------------------------------+
                                              |
                                              v  Compiler (gcc / clang)
                  +-------------------------------------------------------+
                  |               Assembly Code (.s)                      |
                  +-------------------------------------------------------+
                                              |
                                              v  Assembler (as)
                  +-------------------------------------------------------+
                  |             Relocatable Object Code (.o)              |
                  +-------------------------------------------------------+
                                              |
                                              v  Linker (ld / LDFLAGS)
           +----------------------------------+----------------------------------+
           |                                                                     |
           v Static Linking (-static)                                            v Dynamic Linking (-Wl,-rpath)
+------------------------------------+                                +------------------------------------+
| Self-contained Monolithic Binary   |                                | Binary + Dynamic Dependencies      |
+------------------------------------+                                | (.so libraries via ld-linux.so)    |
                                                                      +------------------------------------+
```

#### The GNU Autotools Toolchain Mechanics
1. **`./configure` Shell Execution:**
   The `./configure` script is generated via Autoconf. It performs system introspection (checking available header files, kernel APIs, compiler features, and dependency libraries).
   - Generates `config.log` (detailed diagnostic compilation logs).
   - Generates `config.status` (an executable script that produces the final `Makefile` from `Makefile.in`).
2. **Standard Variable Injections:**
   - `CPPFLAGS`: Includes preprocessor flags (e.g., `-I/opt/custom/include`).
   - `CFLAGS` / `CXXFLAGS`: Optimization and debug flags passed to standard C/C++ compilers (e.g., `-O2 -g -fstack-protector-strong`).
   - `LDFLAGS`: Flags passed directly to the linker `ld` (e.g., `-L/opt/custom/lib -Wl,-rpath=/opt/custom/lib`).
   - `--prefix=PREFIX`: Sets the base target directory (defaults to `/usr/local`).
   - `DESTDIR`: Used during `make install DESTDIR=/tmp/stage` for non-root staged builds or binary package creation (e.g., building `.deb` or `.rpm` packages).

#### Dynamic Shared Object (DSO) Resolution Order
When an executable calls a dynamic shared library (`.so`), the ELF interpreter (`/lib64/ld-linux-x86-64.so.2`) resolves shared dependencies using the following lookup order:
1. `DT_RPATH` tag embedded in the ELF binary header (if `DT_RUNPATH` is not set).
2. Environment variable `LD_LIBRARY_PATH` (evaluated at runtime; overridable).
3. `DT_RUNPATH` tag embedded in the ELF binary header.
4. Binary cache `/etc/ld.so.cache` (generated by `/sbin/ldconfig` parsing `/etc/ld.so.conf` and `/etc/ld.so.conf.d/*.conf`).
5. Standard system library directories: `/lib64`, `/usr/lib64`.

---

### 1.2 Backup Mechanics, Delta Transfers, and Snapshot Consistency

#### Full vs. Incremental vs. Differential Backup Trade-offs

| Parameter | Full Backup | Differential Backup | Incremental Backup |
| :--- | :--- | :--- | :--- |
| **Data Scope** | Entire designated dataset | All changes since the *last Full* backup | All changes since the *last backup of any type* |
| **Backup Speed** | Slowest | Medium | Fastest |
| **Restore Speed** | Fastest (Single dataset restore) | Medium (Full + 1 Differential) | Slowest (Full + N Sequential Incrementals) |
| **Storage Usage** | Maximum | Moderate | Minimal |
| **Fault Isolation**| High | Moderate | Low (Failure in 1 incremental breaks chain) |

#### Rsync Rolling Checksum Algorithm Mechanics
Rsync minimizes network transfer using a two-pass hash check:
1. **Block Division:** The target file on the destination system is partitioned into non-overlapping blocks of size $S$ (typically 512–2048 bytes).
2. **Two Checksums per Block:**
   - **Rolling Checksum (Adler-32 derivative):** A 32-bit fast algorithm computed over a sliding window.
   - **Strong Checksum (MD5/MD4):** A 128-bit cryptographically strong hash.
3. **Sliding Window Scanning:** The source machine calculates the fast 32-bit rolling checksum for a sliding window of size $S$ across the source file byte-by-byte.
   - If the fast 32-bit checksum matches a destination block, the source calculates the 128-bit strong hash.
   - If both hashes match, the block exists on the target. The source transmits only the offset pointer.
   - If no match occurs, the single byte is transmitted as raw data, and the window slides right by 1 byte.

#### Hardlink-Based Snapshot Trees (`--link-dest`)
When `rsync --link-dest=/backups/backup.0` executes:
- Rsync compares metadata (mtime, size, permissions) of source files against `/backups/backup.0`.
- Unchanged files are created in the target directory `/backups/backup.1` as **hardlinks** (`inotify`/`stat` inode reference count incremented) pointing to the identical inode in `backup.0`.
- Modified files are transferred and written to a new inode.
- **Result:** Provides fully accessible, isolated point-in-time directory trees while occupying storage only for modified block deltas.

---

### 1.3 System Notifications, IPC, and Dynamic MOTD Integration

#### User Terminal Messaging Mechanics (`utmp`, `wtmp`, `/dev/pts/*`)
Linux manages logged-in user sessions via binary structure tracking:
- `/var/run/utmp`: Tracks currently logged-in users, active terminal sessions (`/dev/pts/X`), and login timestamps.
- `/var/log/wtmp`: Append-only historical log of logins/logouts.
- `/var/log/btmp`: Records failed authentication attempts.

Commands like `wall` and `write` operate by:
1. Iterating through `/var/run/utmp` to map active users to their designated pseudo-terminal devices (`/dev/pts/X`).
2. Checking terminal write permissions via file mode bits on the device file (managed via `mesg y` [mode `0620`] or `mesg n` [mode `0600`]).
3. Writing the message buffer directly to `/dev/pts/X`.

#### Login Notification Hierarchy & Dynamic PAM Execution
```
+------------------------------------------------------------------------------------+
| System Login Event (Console / SSH / TTY)                                           |
+------------------------------------------------------------------------------------+
                                         |
                                         v
+------------------------------------------------------------------------------------+
| 1. Pre-Authentication Display: /etc/issue (Local TTY) or /etc/issue.net (SSH)       |
+------------------------------------------------------------------------------------+
                                         |
                                         v
+------------------------------------------------------------------------------------+
| 2. Authentication Stage (PAM Stack Processing)                                     |
+------------------------------------------------------------------------------------+
                                         |
                                         v
+------------------------------------------------------------------------------------+
| 3. Post-Authentication Stage: pam_motd.so                                          |
|    - Executes /etc/update-motd.d/* executable scripts in numerical order           |
|    - Aggregates stdout into dynamic runtime file /run/motd.dynamic                 |
|    - Appends contents of static file /etc/motd (if present)                        |
+------------------------------------------------------------------------------------+
                                         |
                                         v
+------------------------------------------------------------------------------------+
| User Interactive Shell Spawned ($SHELL)                                           |
+------------------------------------------------------------------------------------+
```

---

## 2. Guided Production Hands-on Labs & Verification Questions

### Exercise 1: Custom Source Compilation, Patching, Prefix Isolation, and Shared Library Management

#### Objective
Download, unpack, patch, compile, and isolate a modern open-source tool (`memcached`) into a non-standard production prefix (`/opt/services/memcached`), configure custom rpaths, and verify dynamic link dependencies without polluting standard system directories.

#### Step 1: Prepare Sandbox Workspace and Fetch Source Artifacts
Execute the following commands to create an isolated build workspace and download source files:

```bash
mkdir -p /tmp/build-workspace/src
cd /tmp/build-workspace/src

# Create a sample bugfix patch file simulating an SRE security/logging hotfix
cat << 'EOF' > /tmp/build-workspace/src/sre_custom_logging.patch
--- a/memcached.c	2023-01-01 00:00:00.000000000 +0000
+++ b/memcached.c	2023-01-01 00:00:05.000000000 +0000
@@ -1,5 +1,6 @@
 /* SRE Production Hotfix Hook */
 #include <stdio.h>
+/* Custom SRE Audit Log Initialization */
 EOF

# Download libevent (dependency) and memcached source tarballs
curl -sSL -O https://github.com/libevent/libevent/releases/download/release-2.1.12-stable/libevent-2.1.12-stable.tar.gz
curl -sSL -O https://memcached.org/files/memcached-1.6.22.tar.gz

# Extract archives using tar with verbose output and gzip decompression
tar -zxvf libevent-2.1.12-stable.tar.gz
tar -zxvf memcached-1.6.22.tar.gz
```

*Expected Output (Truncated):*
```text
libevent-2.1.12-stable/
libevent-2.1.12-stable/configure
...
memcached-1.6.22/
memcached-1.6.22/memcached.c
memcached-1.6.22/configure
```

#### Step 2: Compile Dependency Library with Isolation Prefix
Compile `libevent` and install it under `/opt/services/libevent`:

```bash
cd /tmp/build-workspace/src/libevent-2.1.12-stable

# Configure with custom prefix
./configure --prefix=/opt/services/libevent --disable-static

# Compile utilizing all available CPU cores
make -j$(nproc)

# Perform staged target installation
make install
```

*Expected Output (Truncated):*
```text
config.status: creating Makefile
...
Libraries have been installed in:
   /opt/services/libevent/lib
```

#### Step 3: Apply Patch and Compile Application with Custom Linker Flags
Navigate to `memcached`, apply the patch, and build with linker environment variables linking against `/opt/services/libevent`:

```bash
cd /tmp/build-workspace/src/memcached-1.6.22

# Apply patch cleanly with dry-run verification first
patch -p1 --dry-run < /tmp/build-workspace/src/sre_custom_logging.patch
patch -p1 < /tmp/build-workspace/src/sre_custom_logging.patch

# Set C preprocessor, Linker, and RPATH options
export CPPFLAGS="-I/opt/services/libevent/include"
export LDFLAGS="-L/opt/services/libevent/lib -Wl,-rpath=/opt/services/libevent/lib"

# Configure memcached pointing to the dependency prefix
./configure --prefix=/opt/services/memcached --with-libevent=/opt/services/libevent

# Build and Install
make -j$(nproc)
make install
```

*Expected Output (Truncated):*
```text
checking for libevent directory... /opt/services/libevent
config.status: creating Makefile
...
make[1]: Leaving directory '/tmp/build-workspace/src/memcached-1.6.22'
Installing /opt/services/memcached/bin/memcached
```

#### Step 4: Verify ELF Binary Execution Header and Dynamic Linkage
Inspect the generated ELF binary to verify rpath embedding and dependency resolution:

```bash
# Verify shared library resolution via ldd
ldd /opt/services/memcached/bin/memcached

# Read ELF dynamic tag section using readelf
readelf -d /opt/services/memcached/bin/memcached | grep -E "(RPATH|RUNPATH|NEEDED)"
```

*Expected Output:*
```text
	linux-vdso.so.1 (0x00007ffc91bfe000)
	libevent-2.1.so.6 => /opt/services/libevent/lib/libevent-2.1.so.6 (0x00007f3a8b4a2000)
	libc.so.6 => /lib64/libc.so.6 (0x00007f3a8b200000)
 0x0000000000000001 (NEEDED)             Shared library: [libevent-2.1.so.6]
 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
 0x000000000000000f (RPATH)              Library rpath: [/opt/services/libevent/lib]
```

---

#### Verification Questions — Exercise 1

1. **Question 1.1:** What is the fundamental operational difference between passing `-L/path/to/lib` during compilation versus embedding `-Wl,-rpath=/path/to/lib` into the binary?
2. **Question 1.2:** If `make install` is run with `DESTDIR=/tmp/pkg-root`, what exact path does the binary end up in given `--prefix=/opt/app`, and what is the technical purpose of `DESTDIR`?
3. **Question 1.3:** Suppose `ldd /opt/services/memcached/bin/memcached` outputs `libevent-2.1.so.6 => not found` on a machine where `LD_LIBRARY_PATH` is empty and `/etc/ld.so.conf` does not contain `/opt/services/libevent/lib`. How can an operator fix this dynamically without recompiling or modifying global system files?

---

### Exercise 2: Automated Point-in-Time Rsync Backups with LVM Snapshot Consistency and GPG Encryption

#### Objective
Configure a zero-downtime, block-level consistent backup strategy. Create a dummy LVM logical volume hosting production data, execute an LVM snapshot to guarantee transactional integrity, perform a space-efficient hardlinked differential incremental backup using `rsync --link-dest`, and compress/encrypt the output using GPG keys for secure offsite archival.

#### Step 1: Create Mock Volume Group and Production Storage Partition
Set up a loopback device to simulate physical storage, configure an LVM Volume Group (`vg_data`), and format a production volume (`lv_prod`):

```bash
# Create a 2GB storage file to simulate a disk
dd if=/dev/zero of=/tmp/disk_backend.img bs=1M count=2048 status=none

# Attach storage file as a loopback device
LOOP_DEV=$(losetup --find --show /tmp/disk_backend.img)
echo "Attached loop device: ${LOOP_DEV}"

# Create LVM Physical Volume and Volume Group
pvcreate ${LOOP_DEV}
vgcreate vg_data ${LOOP_DEV}

# Create a 1GB Logical Volume for Production Data
lvcreate -L 1G -n lv_prod vg_data

# Format with ext4 and mount
mkfs.ext4 -q /dev/vg_data/lv_prod
mkdir -p /mnt/production_data
mount /dev/vg_data/lv_prod /mnt/production_data

# Populate production data
echo "Critical Transaction Log 1" > /mnt/production_data/db_log_1.txt
echo "Critical Config File" > /mnt/production_data/app_config.json
dd if=/dev/urandom of=/mnt/production_data/blob_data.bin bs=1M count=50 status=none
```

*Expected Output:*
```text
Attached loop device: /dev/loop0
  Physical volume "/dev/loop0" successfully created.
  Volume group "vg_data" successfully created.
  Logical volume "lv_prod" created.
```

#### Step 2: Perform Consistent LVM Snapshot Creation
Freeze any outstanding filesystem I/O operations and take an LVM snapshot (`lv_prod_snap`):

```bash
# Create a 250MB snapshot volume
lvcreate -L 250M --snapshot --name lv_prod_snap /dev/vg_data/lv_prod

# Mount snapshot volume read-only
mkdir -p /mnt/snapshot_raw
mount -o ro /dev/vg_data/lv_prod_snap /mnt/snapshot_raw

# Verify snapshot block mapping status
lvs /dev/vg_data/lv_prod_snap
```

*Expected Output:*
```text
  LV           VG      Attr       LSize   Pool Origin  Data%  Meta%  Move Log Cpy%Sync Log%
  lv_prod_snap vg_data swi-a-s--- 250.00m      lv_prod 0.05
```

#### Step 3: Implement Space-Efficient Multi-Generational Rsync Backups (`--link-dest`)
Build a automated point-in-time incremental snapshot tree using `rsync` hardlinks:

```bash
# Define backup repository base
mkdir -p /backups/repository/daily.0

# Initial Full Backup (daily.0)
rsync -aHAX --delete /mnt/snapshot_raw/ /backups/repository/daily.0/

# Unmount and drop snapshot
umount /mnt/snapshot_raw
lvremove -y /dev/vg_data/lv_prod_snap

# Modify production data to simulate new changes (Day 2)
echo "Critical Transaction Log 2" > /mnt/production_data/db_log_2.txt
rm /mnt/production_data/db_log_1.txt

# Create new snapshot for Day 2 backup
lvcreate -L 250M --snapshot --name lv_prod_snap /dev/vg_data/lv_prod
mount -o ro /dev/vg_data/lv_prod_snap /mnt/snapshot_raw

# Rotate backup generations
mv /backups/repository/daily.0 /backups/repository/daily.1

# Execute Incremental Backup using --link-dest referencing daily.1
rsync -aHAX --delete --link-dest=/backups/repository/daily.1 /mnt/snapshot_raw/ /backups/repository/daily.0/

# Clean up snapshot
umount /mnt/snapshot_raw
lvremove -y /dev/vg_data/lv_prod_snap
```

*Expected Output:*
```text
  Logical volume "lv_prod_snap" successfully removed
  Logical volume "lv_prod_snap" created.
  Logical volume "lv_prod_snap" successfully removed
```

#### Step 4: Verify Inode Sharing and Hardlink Storage Efficiency
Verify that unchanged files in `daily.0` share inodes with `daily.1`, while modified files occupy independent inodes:

```bash
# Inspect inode numbers of unchanged binary blob across backups
ls -i /backups/repository/daily.1/blob_data.bin
ls -i /backups/repository/daily.0/blob_data.bin

# Check disk space consumption (Notice total size vs actual disk usage)
du -sh /backups/repository/*
du -sh --apparent-size /backups/repository/*
```

*Expected Output:*
```text
1052673 /backups/repository/daily.1/blob_data.bin
1052673 /backups/repository/daily.0/blob_data.bin
51M	/backups/repository/daily.0
4.0K	/backups/repository/daily.1
51M	total
```

#### Step 5: Streaming Encryption for Offsite Transfer
Stream `daily.0` through `tar`, encrypt it with GPG using `AES256`, and verify archive integrity:

```bash
# Compress and symmetrically encrypt stream on the fly
tar -cf - -C /backups/repository/daily.0 . | \
  gpg --batch --yes --symmetric --cipher-algo AES256 --passphrase "SuperSecretSREPassphrase123" \
  -o /backups/offsite_archive_$(date +%F).tar.gpg

# Test decryption stream without writing to disk
gpg --batch --yes --decrypt --passphrase "SuperSecretSREPassphrase123" \
  /backups/offsite_archive_$(date +%F).tar.gpg | tar -tzf - | head -n 5
```

*Expected Output:*
```text
./
./db_log_2.txt
./app_config.json
./blob_data.bin
```

---

#### Verification Questions — Exercise 2

1. **Question 2.1:** What occurs to an active LVM snapshot if the volume space allocated to it (e.g., 250MB in our lab) experiences more block changes on the origin volume (`lv_prod`) than the allocated capacity can store?
2. **Question 2.2:** In the `rsync` command, why is it critical that `--link-dest` uses either an absolute path or a path relative to the *destination* directory rather than the working execution directory?
3. **Question 2.3:** Why are the flags `-H`, `-A`, and `-X` explicitly included in production SRE backup scripts using `rsync` or `tar`?

---

### Exercise 3: Dynamic PAM-based MOTD Engine, Emergency System Notifications, and Terminal Isolation

#### Objective
Configure system-wide pre-login legal warnings, build a dynamic post-authentication Message of the Day (MOTD) script reporting system health and backup status via Linux PAM, and execute targeted/broadcast user notifications using `wall` and `write`.

#### Step 1: Configure Pre-Login Warnings (`/etc/issue` and `/etc/issue.net`)
Configure banner warnings using escaping sequences for local TTYs and remote SSH clients:

```bash
# Backup original banners
cp /etc/issue /etc/issue.bak
cp /etc/issue.net /etc/issue.net.bak

# Set local TTY issue banner with escape sequences (\n = node name, \l = tty line, \t = time)
cat << 'EOF' > /etc/issue
*******************************************************************
* AUTHORIZED USE ONLY!                                            *
* Hostname: \n  | Line: \l | System Time: \t                     *
*******************************************************************
EOF

# Set remote network SSH banner (Plain text without local escape codes)
cat << 'EOF' > /etc/issue.net
*******************************************************************
* AUTHORIZED ACCESS ONLY - ALL ACTIVITIES ARE LOGGED AND MONITORED *
*******************************************************************
EOF
```

#### Step 2: Construct a Dynamic PAM MOTD Generation Script
Create a custom script inside `/etc/update-motd.d/` that dynamically outputs system stats upon user login:

```bash
# Ensure update-motd directory exists
mkdir -p /etc/update-motd.d

# Create script 99-sre-health-status
cat << 'EOF' > /etc/update-motd.d/99-sre-health-status
#!/bin/bash
# Description: Custom SRE Production Status Generator

echo ""
echo "=== SRE PLATFORM HEALTH STATUS ==="
echo "Host: $(hostname -f)"
echo "Uptime: $(uptime -p)"
echo "Kernel: $(uname -r)"
echo "Memory Usage: $(free -m | awk '/Mem:/ { printf "%3.1f%%", $3/$2*100 }')"
echo "Root FS Usage: $(df -h / | awk 'NR==2 {print $5}')"

# Check backup integrity state
if [ -f /backups/offsite_archive_$(date +%F).tar.gpg ]; then
    echo "Backup Status: [ OK ] Today's offsite encrypted archive present."
else
    echo "Backup Status: [ WARNING ] No encrypted backup found for $(date +%F)!"
fi
echo "=================================="
echo ""
EOF

# Grant execution permissions (Mandatory for PAM processing)
chmod +x /etc/update-motd.d/99-sre-health-status
```

#### Step 3: Configure PAM to Process Dynamic MOTD
Verify and update `/etc/pam.d/sshd` and `/etc/pam.d/login` configuration blocks to ensure `pam_motd.so` executes the dynamic MOTD stack:

```bash
# Inspect PAM configuration for pam_motd calls
grep -E "pam_motd" /etc/pam.d/sshd /etc/pam.d/login
```

*Expected Configuration Snippet (`/etc/pam.d/sshd`):*
```text
session    optional     pam_motd.so motd=/run/motd.dynamic
session    optional     pam_motd.so noupdate
```

#### Step 4: Manually Trigger Dynamic MOTD Re-generation
Test the script manually by invoking `run-parts` on the dynamic MOTD folder:

```bash
# Execute scripts in numerical order and dump output to /run/motd.dynamic
run-parts /etc/update-motd.d/ > /run/motd.dynamic
cat /run/motd.dynamic
```

*Expected Output:*
```text
=== SRE PLATFORM HEALTH STATUS ===
Host: production-node-1.internal
Uptime: up 4 hours, 12 minutes
Kernel: 5.14.0-362.8.1.el9_3.x86_64
Memory Usage: 14.2%
Root FS Usage: 22%
Backup Status: [ OK ] Today's offsite encrypted archive present.
==================================
```

#### Step 5: Execute Emergency Broadcast Notifications and Test Terminal Isolation
Simulate emergency SRE maintenance communication to all active terminals using `wall`, then test terminal write isolation via `mesg`:

```bash
# Send system-wide emergency broadcast message
wall "URGENT: Emergency Kernel Patching starting in 5 minutes. Save your work!"

# Verify current terminal write status
mesg

# Disable messages to current terminal session
mesg n
mesg

# Enable messages to current terminal session
mesg y
```

*Expected Output:*
```text
Broadcast message from root@production-node-1 (pts/0) (Thu Aug 06 10:25:21 2026):

URGENT: Emergency Kernel Patching starting in 5 minutes. Save your work!

is y
is n
is y
```

---

#### Verification Questions — Exercise 3

1. **Question 3.1:** Why does `/etc/issue.net` avoid using special terminal escape codes (such as `\n`, `\l`, `\t`), whereas `/etc/issue` standardly uses them?
2. **Question 3.2:** If a script placed under `/etc/update-motd.d/50-custom` has permissions `0644` (`-rw-r--r--`), how will `pam_motd.so` respond when a user logs in?
3. **Question 3.3:** Can a non-root user block emergency system broadcast notifications issued by `root` using `wall` by executing `mesg n` in their TTY shell session? Explain the underlying kernel/permission mechanism.

---

## 3. Answer Key & Comprehensive Solutions

<details>
<summary>Click to Expand Answer Key and Technical Explanations</summary>

### Exercise 1 Solutions

- **1.1 Answer:**  
  `-L/path/to/lib` is a **compile/link-time** directive. It instructs the linker (`ld`) where to find dynamic shared object (`.so`) symbol definitions during the compilation phase. Once compilation completes, `-L` information is discarded.  
  `-Wl,-rpath=/path/to/lib` is a **runtime** directive. It embeds an explicit `DT_RPATH` or `DT_RUNPATH` attribute inside the compiled ELF binary header. At binary execution time, the dynamic loader (`ld-linux.so`) uses this embedded string to locate shared dependencies without relying on external system environment configurations.

- **1.2 Answer:**  
  The binary will be placed at `/tmp/pkg-root/opt/app/bin/binary_name`.  
  The purpose of `DESTDIR` is to support staged non-root installations. It prepends an alternate root directory to all target installation paths. This allows package builders (RPM, DEB) to assemble the entire filesystem directory hierarchy inside a sandbox without overwriting actual system files or requiring `root` privileges during build steps.

- **1.3 Answer:**  
  Set the `LD_LIBRARY_PATH` environment variable inline when executing the binary:  
  `LD_LIBRARY_PATH=/opt/services/libevent/lib /opt/services/memcached/bin/memcached`  
  Alternatively, add `/opt/services/libevent/lib` to a new configuration file under `/etc/ld.so.conf.d/memcached.conf` and execute `ldconfig` as root.

---

### Exercise 2 Solutions

- **2.1 Answer:**  
  When an LVM snapshot is created, it allocates a Copy-on-Write (CoW) metadata block mapping table. If the snapshot's allocated CoW space fills up completely (100% usage), the snapshot becomes invalidated. The kernel drops the snapshot target, invalidates the snapshot logical volume, marks it as "INACTIVE", and I/O reads to the snapshot mount will fail with Input/Output errors (`EIO`).

- **2.2 Answer:**  
  `rsync` evaluates `--link-dest` paths **relative to the destination directory**, not the current working directory from which the command is executed. If a relative path like `--link-dest=daily.1` is provided while the destination argument is `/backups/repository/daily.0`, `rsync` correctly searches `/backups/repository/daily.0/../daily.1` (which resolves to `/backups/repository/daily.1`). Passing an improper path causes `rsync` to silently fail matching existing files, converting the operation into a full redundant backup.

- **2.3 Answer:**  
  - `-H` (`--hard-links`): Preserves hardlinks across files. Without this, hardlinked files are expanded into separate duplicate files on the target, ballooning storage usage.
  - `-A` (`--acls`): Preserves POSIX Access Control Lists attached to files/directories.
  - `-X` (`--xattrs`): Preserves Extended Attributes (such as SELinux security contexts `security.selinux` or filesystem capabilities `security.capability`).

---

### Exercise 3 Solutions

- **3.1 Answer:**  
  `/etc/issue` is parsed directly by the local `getty` / `agetty` terminal process, which natively interprets local escape characters (`\n`, `\l`, etc.).  
  `/etc/issue.net` is sent over network protocols (like SSH via `sshd`). RFC 4253 specifies that SSH banner authentication payloads must be raw UTF-8 string streams. `sshd` does not parse local `getty` escape codes; rendering them unparsed directly to remote clients would output literal raw escape strings (e.g. `\n \l`) to the SSH terminal client.

- **3.2 Answer:**  
  `pam_motd.so` invokes `run-parts` to discover scripts in `/etc/update-motd.d/`. `run-parts` strictly filters files and executes **only files that have the executable permission bit set** (`+x`). If a script has `0644` permissions, `pam_motd.so` will ignore it, and its stdout content will not be included in `/run/motd.dynamic`.

- **3.3 Answer:**  
  **No.** `wall` (write all) commands issued by `root` bypass user terminal permission checks.  
  Executing `mesg n` removes write permissions for non-root users by changing the device permissions of `/dev/pts/X` to mode `0600` (owned by the logged-in user). However, because `root` possesses the `CAP_DAC_OVERRIDE` capability, the kernel permits `root` processes to bypass file permission modes and write directly to any pseudo-terminal character device (`/dev/pts/*`) regardless of `mesg` state.

</details>