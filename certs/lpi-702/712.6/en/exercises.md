# LPI-702 (Exam 702-100) Topic 712.6: Find Files and BSD Directory Layout
**Weight:** 2 (Exam Version 1.0)

---

## 1. Technical Architecture & Internal Mechanics

### BSD Directory Hierarchy Architecture (`hier(7)`)
Unlike Linux distributions, which often blur the lines between the core operating system and user-installed software, BSD operating systems enforce a strict separation governed by the [`hier(7)`](https://man.freebsd.org/cgi/man.cgi?query=hier&sektion=7) design specification.

```
/
├── bin/          # Fundamental binaries required for single-user recovery
├── sbin/         # System administration binaries required for single-user recovery
├── etc/          # Base system configuration files
│   └── defaults/ # Default base system configurations (DO NOT EDIT DIRECTLY)
├── lib/          # Shared libraries essential for binaries in /bin and /sbin
├── libexec/      # System daemons and internal helpers targeted by execution scripts
├── dev/          # Device nodes (DEVFS dynamic filesystem)
├── boot/         # Kernel (/boot/kernel/kernel), loader, and boot modules
├── var/          # Multi-purpose variable dynamic data (logs, spools, databases)
│   └── db/       # System databases (pkg, locate.database)
└── usr/          # Subdirectory hierarchy for static, read-only system files
    ├── bin/      # Standard user utility binaries
    ├── sbin/     # System management binaries for multi-user operation
    ├── lib/      # Libraries for user binaries
    ├── libexec/  # System daemons executed by system services
    ├── share/    # Architecture-independent data (doc, zoneinfo, man)
    │   └── man/  # Manual page repository
    ├── src/      # Base system OS source code tree
    ├── ports/    # FreeBSD Ports Collection tree (or /usr/pkgsrc in NetBSD)
    └── local/    # THIRD-PARTY SOFTWARE PREFIX (bin, etc, lib, man, share)
```

#### Key Structural Constraints and Trade-Offs:
1. **Base System vs. Third-Party Isolation (`/usr/local` vs `/usr`):**
   - The OS base distribution resides under `/`, `/bin`, `/usr/bin`, `/sbin`, and `/etc`. 
   - Non-base packages installed via `pkg(8)` or the FreeBSD Ports Collection **must** be contained within `/usr/local` (or `/usr/pkg` in NetBSD `pkgsrc`). Configuration files for ports live in `/usr/local/etc`, avoiding pollution of `/etc`.
2. **Immutable Base Configuration (`/etc/defaults`):**
   - System defaults reside in `/etc/defaults/rc.conf`. Sysadmins override parameters in `/etc/rc.conf`. Updating the OS replaces `/etc/defaults/rc.conf` safely without clobbering administrator modifications.
3. **Partitioning & Mount Boundaries:**
   - In traditional UFS2/ZFS setups, `/var` and `/usr` are isolated file systems. Running out of disk space in `/var` (e.g., due to log flooding) does not corrupt or halt root filesystem operations.

---

### Utility Comparison: File & Command Discovery Mechanisms

| Feature / Utility | `which(1)` | `whereis(1)` | `locate(1)` | `find(1)` |
| :--- | :--- | :--- | :--- | :--- |
| **Search Mechanism** | Scans current `$PATH` environment variable | Scans standard system binary, manual, and source directories | Queries pre-built database (`/var/db/locate.database`) | Performs dynamic live VFS directory tree traversal |
| **Search Target** | Executables in `$PATH` | Standard binaries, source files, and man pages | Filename pattern matching in indexed DB | Arbitrary inode attributes (metadata, flags, size, time) |
| **Speed** | Instant ($O(k)$ where $k$ is `$PATH` length) | Instant ($O(m)$ fixed path array search) | Extremely fast ($O(\log N)$ indexed binary search) | Slow ($O(N)$ live filesystem I/O scan) |
| **Real-time Accuracy** | Yes | Yes | No (Stale between `updatedb` runs) | Yes |
| **Permission Filter** | Filters by execute bit (`+x`) for user | Searches predefined path list without permission filter | Enforces user permissions during reading if configured | Evaluates against full POSIX ACL / BSD flags |

#### Mechanics of `locate` and `locate.updatedb(8)`
- `locate` relies on a fast, compressed database created by `/usr/libexec/locate.updatedb`.
- On FreeBSD, `locate.updatedb` runs automatically via the periodic maintenance framework (`/etc/periodic/weekly/310.locate`).
- **Security Isolation:** `locate.updatedb` drops root privileges to user `nobody` (or `_locate` on OpenBSD) during filesystem scanning. Files inside restricted directories (e.g., `0700` owned by `root`) are omitted from the database to prevent unprivileged users from discovering sensitive path names.

#### Mechanics of BSD `find(1)` and BSD File Flags
BSD `find` traverses directory trees using `fts(3)` functions and evaluates file metadata via `stat(2)`. Unlike GNU `find`, BSD `find` includes native support for BSD File Flags (`chflags(2)`):
- Flags include: `uchg` (user immutable), `schg` (system immutable), `uappnd` (user append-only), `sappnd` (system append-only), `nodump` (dump utility skip flag).
- BSD `find` evaluates flags using the `-flags` primary (e.g., `find / -flags uchg`).

---

### Official Documentation References
- [FreeBSD `hier(7)` Manual Page](https://man.freebsd.org/cgi/man.cgi?query=hier&sektion=7)
- [FreeBSD `find(1)` Manual Page](https://man.freebsd.org/cgi/man.cgi?query=find&sektion=1)
- [FreeBSD `locate(1)` Manual Page](https://man.freebsd.org/cgi/man.cgi?query=locate&sektion=1)
- [FreeBSD `locate.updatedb(8)` Manual Page](https://man.freebsd.org/cgi/man.cgi?query=locate.updatedb&sektion=8)
- [FreeBSD `chflags(2)` System Call Manual](https://man.freebsd.org/cgi/man.cgi?query=chflags&sektion=2)

---

## 2. Hands-On Guided Exercises

### Exercise 1: BSD Directory Layout Exploration and Structural Audit

**Objective:** Audit a live BSD filesystem to verify adherence to `hier(7)` standards, identifying base system locations versus third-party package locations.

#### Step 1.1: Verify System Manual Hierarchy
Read the `hier(7)` manual page to inspect standard directory roles:
```bash
man 7 hier | head -n 30
```
*Expected Output Snippet:*
```text
HIER(7)                 FreeBSD Manual Pages Statement              HIER(7)

NAME
     hier -- layout of file systems

DESCRIPTION
     A sketch of the file system hierarchy.

     /        root directory of the file system
     /bin/    user utilities fundamental to both single-user and multi-user
              environments
```

#### Step 1.2: Differentiate Base Configurations vs Default Overrides
Inspect `/etc/defaults/rc.conf` and verify its immutability rule:
```bash
head -n 12 /etc/defaults/rc.conf
```
*Expected Output Snippet:*
```text
# This is rc.conf - a file full of utility variable settings that you
# might maintain to change the default configuration of your system.
#
# DO NOT EDIT THIS FILE DIRECTLY. IT IS A MASTER FILE FOR ALL DEFAULTS.
# Make your changes to /etc/rc.conf instead.
```

#### Step 1.3: Audit Third-Party vs Base Binary Directories
Check where the base system stores system management tools versus third-party installed services (e.g., Nginx or PostgreSQL installed via `pkg`):
```bash
ls -ld /sbin/ifconfig /usr/sbin/sshd /usr/local/sbin 2>/dev/null
```
*Expected Output Snippet:*
```text
-r-xr-xr-x  1 root  wheel  387496 Aug  1 12:00 /sbin/ifconfig
-r-xr-xr-x  1 root  wheel  845120 Aug  1 12:00 /usr/sbin/sshd
drwxr-xr-x  2 root  wheel     512 Aug  2 14:10 /usr/local/sbin
```

---

#### Verification Questions (Exercise 1)

1. A junior administrator installs a third-party daemon package via FreeBSD `pkg` and attempts to manually edit `/etc/daemon.conf`. Following `hier(7)` standards, where should this configuration file actually be located, and why does BSD enforce this location?
2. Why does BSD separate binaries between `/bin` & `/sbin` and `/usr/bin` & `/usr/sbin`? What scenario relies on binaries existing inside `/bin` rather than `/usr/bin`?

---

### Exercise 2: Command Discovery & `locate` Database Administration

**Objective:** Utilize `which`, `whereis`, and configure/generate the indexed `locate` database manually as system administrator.

#### Step 2.1: Compare Command Resolution (`which` vs `whereis`)
Search for the `reboot` utility using both tools:
```bash
which reboot
whereis reboot
```
*Expected Output:*
```text
/sbin/reboot
reboot: /sbin/reboot /usr/share/man/man8/reboot.8.gz
```

#### Step 2.2: Test `locate` Failure on Missing Database
Attempt to search for `rc.conf` using `locate`:
```bash
locate rc.conf
```
*Expected Output (If database is absent or uninitialized):*
```text
locate: warning: database /var/db/locate.database is small or missing
locate: run /usr/libexec/locate.updatedb or wait for periodic maintenance
```

#### Step 2.3: Manually Update the `locate` Database
Trigger `/usr/libexec/locate.updatedb` to index the filesystem:
```bash
su -m root -c "/usr/libexec/locate.updatedb"
```
Verify the generated database metadata:
```bash
ls -lh /var/db/locate.database
```
*Expected Output:*
```text
-rw-r--r--  1 nobody  wheel   1.2M Aug  6 20:40 /var/db/locate.database
```

#### Step 2.4: Execute Indexed Search
Query `locate` for system manual pages related to `zfs`:
```bash
locate -i "/man8/zfs" | head -n 5
```
*Expected Output:*
```text
/usr/share/man/man8/zfs-create.8.gz
/usr/share/man/man8/zfs-destroy.8.gz
/usr/share/man/man8/zfs-mount.8.gz
/usr/share/man/man8/zfs-receive.8.gz
/usr/share/man/man8/zfs-rollback.8.gz
```

---

#### Verification Questions (Exercise 2)

1. When running `/usr/libexec/locate.updatedb`, the resulting `/var/db/locate.database` file is owned by user `nobody`. Why does the `locate.updatedb` script switch to user `nobody` during the indexing process instead of running directly as `root`?
2. If an administrator creates a new file `/etc/secret_audit.conf` at 10:00 AM, why does `locate secret_audit.conf` fail to return results at 10:05 AM, whereas `find /etc -name secret_audit.conf` succeeds?

---

### Exercise 3: Advanced File Queries and BSD File Flags with `find(1)`

**Objective:** Construct precise `find` queries utilizing BSD-specific file flags, time primitives, permission modes, and size filters.

#### Step 3.1: Create Test Workspace and Set BSD File Flags
Create a dedicated test environment and set BSD file flags using `chflags(1)`:
```bash
mkdir -p /tmp/bsd_find_lab/restricted
touch /tmp/bsd_find_lab/app.log
touch /tmp/bsd_find_lab/critical.conf
touch /tmp/bsd_find_lab/restricted/key.pem

# Apply user immutable flag (uchg) to critical.conf
chflags uchg /tmp/bsd_find_lab/critical.conf

# Set permission 0600 on key.pem
chmod 0600 /tmp/bsd_find_lab/restricted/key.pem
```

#### Step 3.2: Verify BSD Flags using `ls -lo`
Inspect system flags using BSD-specific `ls` options:
```bash
ls -lo /tmp/bsd_find_lab/
```
*Expected Output:*
```text
total 0
-rw-r--r--  1 root  wheel  -    Aug  6 20:42 app.log
-rw-r--r--  1 root  wheel  uchg Aug  6 20:42 critical.conf
drwxr-xr-x  2 root  wheel  -    Aug  6 20:42 restricted
```

#### Step 3.3: Query Files by BSD File Flag (`-flags`)
Use BSD `find` to isolate files explicitly marked with the `uchg` (user immutable) flag:
```bash
find /tmp/bsd_find_lab -flags uchg
```
*Expected Output:*
```text
/tmp/bsd_find_lab/critical.conf
```

#### Step 3.4: Multi-Criteria Filter (Mode, User, Type)
Find all regular files (`-type f`) under `/tmp/bsd_find_lab` with exact permissions `0600` owned by `root`:
```bash
find /tmp/bsd_find_lab -type f -user root -perm 0600
```
*Expected Output:*
```text
/tmp/bsd_find_lab/restricted/key.pem
```

#### Step 3.5: Time-Based Primitives (`-mtime`, `-atime`, `-ctime`, `-mmin`)
Find files modified in the last 15 minutes (`-mmin -15`):
```bash
find /tmp/bsd_find_lab -type f -mmin -15
```
*Expected Output:*
```text
/tmp/bsd_find_lab/app.log
/tmp/bsd_find_lab/critical.conf
/tmp/bsd_find_lab/restricted/key.pem
```

---

#### Verification Questions (Exercise 3)

1. What is the operational difference between the `-ctime` and `-mtime` primaries in `find`? Which of these changes when a file's BSD flag (`chflags uchg file`) is updated without altering the file's content?
2. You attempt to delete a file found via `find /tmp -name "old.log" -exec rm {} \;`, but the command fails with `rm: old.log: Operation not permitted`, even though you are logged in as `root`. What BSD-specific attribute causes this, and how can `find` be used to identify all such files?

---

### Exercise 4: Production Diagnostic Pipelines & Safe Batch Execution

**Objective:** Safely handle batch file operations using `find`, `-print0`, `xargs -0`, and compare with BSD `-delete` primary.

#### Step 4.1: Construct Filenames with Spaces and Whitespace
Create sample files containing problematic white space characters:
```bash
mkdir -p /tmp/bsd_find_lab/space_test
touch "/tmp/bsd_find_lab/space_test/audit log 2026.log"
touch "/tmp/bsd_find_lab/space_test/error log 2026.log"
```

#### Step 4.2: Demonstrate `xargs` Pipeline Failure (Unsafe Standard Pipeline)
Observe how standard newline/space delimiter pipelines break when filenames contain spaces:
```bash
find /tmp/bsd_find_lab/space_test -type f | xargs ls -l
```
*Expected Output (Truncated Error):*
```text
ls: /tmp/bsd_find_lab/space_test/audit: No such file or directory
ls: log: No such file or directory
ls: 2026.log: No such file or directory
ls: /tmp/bsd_find_lab/space_test/error: No such file or directory
ls: log: No such file or directory
ls: 2026.log: No such file or directory
```

#### Step 4.3: Execute Safe Pipeline using Null Delimiters (`-print0` and `xargs -0`)
Fix the pipeline by injecting ASCII NUL (`\0`) character separators:
```bash
find /tmp/bsd_find_lab/space_test -type f -print0 | xargs -0 ls -l
```
*Expected Output:*
```text
-rw-r--r--  1 root  wheel  0 Aug  6 20:45 /tmp/bsd_find_lab/space_test/audit log 2026.log
-rw-r--r--  1 root  wheel  0 Aug  6 20:45 /tmp/bsd_find_lab/space_test/error log 2026.log
```

#### Step 4.4: Interactive Batch Deletion (`-ok`)
Demonstrate safe interactive confirmation prior to execution:
```bash
find /tmp/bsd_find_lab/space_test -type f -name "*error*" -ok rm {} \;
```
*Expected Output:*
```text
"< rm /tmp/bsd_find_lab/space_test/error log 2026.log >? " y
```

#### Step 4.5: Cleanup using BSD Fast Deletion (`-delete`)
Clean up the remaining workspace using BSD `find`'s native `-delete` primary:
```bash
# Clean up test flags prior to directory removal
chflags 0 /tmp/bsd_find_lab/critical.conf

# Execute depth-first direct deletion without invoking external processes
find /tmp/bsd_find_lab -delete
```

---

#### Verification Questions (Exercise 4)

1. What architectural performance advantage does `find /path -type f -delete` offer over `find /path -type f -exec rm {} \;` in high-density directories containing millions of files?
2. What safety risk occurs if `-delete` is placed at the beginning of a `find` expression (e.g., `find /tmp -delete -name "*.tmp"`) compared to placing it at the end?

---

## 3. Solutions & Verification Answers

<details>
<summary>Click here to expand solutions for all verification questions</summary>

### Answers for Exercise 1: BSD Directory Layout Exploration

1. **Answer:**
   - **Correct Path:** `/usr/local/etc/daemon.conf`
   - **Architectural Rationale:** BSD `hier(7)` enforces a strict boundary between the operating system base distribution and third-party packages installed via ports/pkg. All third-party binaries, libraries, manual pages, and configuration files must live under `/usr/local` (or `/usr/pkg` in NetBSD). This design ensures that OS base upgrades (via `freebsd-update` or source builds) never overwrite, conflict with, or leave orphaned configuration files inside `/etc`.

2. **Answer:**
   - **Architectural Rationale:** `/bin` and `/sbin` reside on the root (`/`) filesystem partition and contain the absolute minimum set of binaries required to boot the system into single-user recovery mode, repair filesystems (`fsck`), or mount auxiliary partitions.
   - **Failure Scenario:** `/usr` is frequently stored on a separate filesystem partition, network mount (NFS), or complex storage pool (ZFS). If `/usr` fails to mount or suffers storage pool corruption during boot, binaries located in `/usr/bin` or `/usr/sbin` are inaccessible. Having emergency recovery utilities (`sh`, `cp`, `fsck`, `ifconfig`, `mount`) inside `/bin` and `/sbin` guarantees system debug capability in single-user mode.

---

### Answers for Exercise 2: Command Discovery & `locate` Database Administration

1. **Answer:**
   - **Security Mechanics:** Dropping privileges to `nobody` prevents the indexing process from recording file paths located inside restricted directories (such as `0700` home directories or private `/var` subdirectories). If `locate.updatedb` ran as `root`, it would record every sensitive filename on the system into `/var/db/locate.database`. Since `/var/db/locate.database` is world-readable (`0644`), unprivileged users could query `locate` to perform unauthorized reconnaissance on private paths, system backups, or secret files.

2. **Answer:**
   - **Execution Mechanics:** `locate` does not scan the live VFS directory structure; it queries the static pre-compiled database `/var/db/locate.database`. Files created after the last execution of `/usr/libexec/locate.updatedb` will not exist in the database index. Conversely, `find` executes live directory traversal system calls (`opendir(3)`, `readdir(3)`, `stat(2)`), providing real-time data directly from the filesystem kernel cache and disk blocks.

---

### Answers for Exercise 3: Advanced File Queries and BSD File Flags

1. **Answer:**
   - **Operational Difference:** 
     - `-mtime` (Modification Time) reflects changes to the actual file **content** (e.g., writing data to disk via `write(2)`).
     - `-ctime` (Change Time) reflects metadata changes to the inode itself (e.g., permissions, ownership, link count, or file flags).
   - **Flag Modification Effect:** Modifying a BSD file flag using `chflags uchg file` triggers an inode metadata update (`utimes(2)` / inode write), updating `-ctime`. It does not alter file payload content, so `-mtime` remains untouched.

2. **Answer:**
   - **BSD Attribute:** The file has the System Immutable (`schg`) or User Immutable (`uchg`) BSD file flag set (`chflags`). Even the `root` superuser cannot delete, rename, overwrite, or truncate a file protected by immutable flags without first removing the flag.
   - **Find Primary Command:**
     ```bash
     find /tmp -flags uchg,schg
     ```
     To strip the flag automatically across all matching files via `find`:
     ```bash
     find /tmp -flags uchg,schg -exec chflags 0 {} +
     ```

---

### Answers for Exercise 4: Production Diagnostic Pipelines & Safe Batch Execution

1. **Answer:**
   - **Performance Advantage:** Using `-exec rm {} \;` causes `find` to execute an `fork(2)` and `execve(2)` system call sequence for **every single matching file**, spawning thousands of child processes and destroying CPU pipeline efficiency.
   - **`-delete` Mechanics:** The BSD native `-delete` primary executes internal `unlinkat(2)` or `rmdir(2)` kernel system calls directly within the running `find` process context. It eliminates process creation overhead entirely, running orders of magnitude faster on massive filesystems.

2. **Answer:**
   - **Safety Risk:** `find` evaluates expression arguments sequentially from left to right. If `-delete` is specified prior to conditional primaries (e.g., `find /tmp -delete -name "*.tmp"`), `find` will evaluate `-delete` **first** on every file encountered under `/tmp`, wiping out the entire directory tree regardless of whether the file matches `-name "*.tmp"`.
   - **Rule:** Operational action primaries (`-delete`, `-exec`, `-print`) must always be positioned at the end of the argument chain after all filtering predicates (`-type`, `-name`, `-mtime`).

</details>