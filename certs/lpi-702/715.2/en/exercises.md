# LPI BSD Specialist (Exam 702-100) — Topic 715.2: Perform Basic File Management

**Exam Objective:** 715.2 Perform basic file management  
**Topic Weight:** 5  
**Target Certification:** LPI BSD Specialist (702-100, Version 1.0)  
**Official Reference:** [LPI BSD Specialist Overview & Objectives](https://www.lpi.org/our-certifications/bsd-specialist-overview/) | [FreeBSD Handbook: File Permissions](https://docs.freebsd.org/en/books/handbook/basics/#permissions) | [FreeBSD `chflags(1)` Manual](https://man.freebsd.org/cgi/man.cgi?query=chflags&sektion=1)

---

## 1. Architectural Overview & System Mechanics

### 1.1 Inode Mechanics, Directory Entries, and Link Count
In BSD filesystems (such as UFS2 and ZFS POSIX layer), a file consists of two distinct components:
1. **Directory Entry (dentry):** A mapping between a human-readable name and an inode number inside a directory file.
2. **Inode:** The metadata structure storing file ownership (`uid`, `gid`), permissions (`mode`), access control lists (ACLs), file flags (`chflags`), timestamps (`atime`, `mtime`, `ctime`, `birthtime`), payload block pointers, and the **link count (`nlink`)**.

```
 Directory Entry                 Inode Structure (UFS2 / ZFS)
+------------------+             +----------------------------------+
| Name: "app.log"  | ------------> Inode: 1048580                   |
| Inode: 1048580   |             |  - Owner: 1001 (www)             |
+------------------+             |  - Group: 1001 (www)             |
                                 |  - Mode: 0640 (-rw-r-----)        |
 Directory Entry                 |  - Link Count (nlink): 2         |
+------------------+             |  - Flags: uchg (User Immutable)  |
| Name: "hard.log" | ------------>  - Data Pointers -> Disk Blocks  |
| Inode: 1048580   |             +----------------------------------+
+------------------+
```

* **Hard Links (`ln target link`):** Create an additional directory entry pointing to the *same* inode number. Hard links cannot cross filesystem boundaries (since inode numbers are filesystem-unique) and cannot target directories (to prevent cycles in the VFS tree).
* **Symbolic Links (`ln -s target link`):** Create a distinct inode of type `S_IFLNK` containing the path string of the target file. Symbolic links can span across different filesystems and target directories.
* **Unlink Semantics (`rm` / `unlink`):** Executing `rm` calls `unlink(2)`. This decrements `nlink` in the inode and removes the directory entry. Disk blocks are freed only when `nlink == 0` **and** no active process holds an open file descriptor targeting the inode.

---

### 1.2 BSD File Flags (`chflags`)
BSD systems extend traditional POSIX mode bits (`chmod`) with kernel-enforced file flags configured via `chflags(1)`. These flags provide tamper-proof immutability and append-only restrictions even against `root` when running at elevated securelevels (`kern.securelevel > 0`).

| Flag Name | Short Name | Description | SRE / Production Use Case |
| :--- | :--- | :--- | :--- |
| `uchg` / `nouchg` | `user immutable` | File cannot be modified, renamed, deleted, or hard-linked by regular owner or root. | Protection of static deployment artifacts and credentials. |
| `schg` / `noschg` | `system immutable` | File cannot be modified or deleted. Can only be cleared by root when `securelevel <= 0`. | Hardening binary payloads and boot configurations (`/sbin/init`). |
| `uappnd` / `nuappnd` | `user append-only` | File can only be opened in append mode (`O_APPEND`). Cannot be truncated or overwritten. | Preventing truncation of application log files. |
| `sappnd` / `nsappnd` | `system append-only` | System-level append-only restriction. | Tamper-proof audit logs (`/var/log/security`). |
| `nodump` / `dump` | `nodump` | File is skipped by the `dump(8)` backup utility. | Excluding cache files or ephemeral sockets from backups. |

---

### 1.3 BSD File Mode Mechanics & `umask`
File permissions in BSD are represented as a 12-bit mode field:
* **Special Bits (3 bits):** SUID (`4000`), SGID (`2000`), Sticky Bit (`1000`).
* **Owner Bits (3 bits):** `r` (`4`), `w` (`2`), `x` (`1`).
* **Group Bits (3 bits):** `r` (`4`), `w` (`2`), `x` (`1`).
* **Other Bits (3 bits):** `r` (`4`), `w` (`2`), `x` (`1`).

**Umask Evaluation:** When creating files (`open(..., O_CREAT)` default `0666`) or directories (`mkdir`, default `0777`), the system applies the process `umask` via bitwise operation:
$$\text{Final Mode} = \text{Default Mode} \land \neg(\text{umask})$$

---

## 2. Guided Hands-On Exercises

### Lab Environment Setup
Log in to a FreeBSD system as a user with `sudo` privileges. Open a shell session (`tcsh` or `sh`) and create a clean sandbox directory:

```bash
mkdir -p /tmp/bsd_file_mgmt_lab && cd /tmp/bsd_file_mgmt_lab
```

---

### Exercise 1: Directory Tree Creation, Wildcard Expansion, and Safe Removal

#### Step 1.1: Create a nested hierarchy in a single atomic invocation
Run `mkdir` with the recursive directory creation flag:

```bash
mkdir -p prod_cluster/nodes/{node01,node02}/etc/sysctl.d
```

Expected output (no output on success):
```bash
# Silent execution indicates success
```

Verify directory structure using `ls -R`:

```bash
ls -R prod_cluster
```

Expected output:
```
prod_cluster:
nodes

prod_cluster/nodes:
node01  node02

prod_cluster/nodes/node01:
etc

prod_cluster/nodes/node01/etc:
sysctl.d

prod_cluster/nodes/node01/etc/sysctl.d:

prod_cluster/nodes/node02:
etc

prod_cluster/nodes/node02/etc:
sysctl.d

prod_cluster/nodes/node02/etc/sysctl.d:
```

#### Step 1.2: Populate files and execute batch copy and move operations
Create multiple configuration files using bracket expansion:

```bash
touch prod_cluster/nodes/node01/etc/sysctl.d/{10-network.conf,20-security.conf,30-storage.conf}
ls -la prod_cluster/nodes/node01/etc/sysctl.d/
```

Expected output:
```
total 8
drwxr-xr-x  2 root  wheel  512 Aug  6 21:00 .
drwxr-xr-x  3 root  wheel  512 Aug  6 21:00 ..
-rw-r--r--  1 root  wheel    0 Aug  6 21:00 10-network.conf
-rw-r--r--  1 root  wheel    0 Aug  6 21:00 20-security.conf
-rw-r--r--  1 root  wheel    0 Aug  6 21:00 30-storage.conf
```

Copy all configuration files from `node01` to `node02` using `cp(1)` with the preserve metadata flag (`-p`):

```bash
cp -p prod_cluster/nodes/node01/etc/sysctl.d/*.conf prod_cluster/nodes/node02/etc/sysctl.d/
ls -la prod_cluster/nodes/node02/etc/sysctl.d/
```

Expected output:
```
total 8
drwxr-xr-x  2 root  wheel  512 Aug  6 21:00 .
drwxr-xr-x  3 root  wheel  512 Aug  6 21:00 ..
-rw-r--r--  1 root  wheel    0 Aug  6 21:00 10-network.conf
-rw-r--r--  1 root  wheel    0 Aug  6 21:00 20-security.conf
-rw-r--r--  1 root  wheel    0 Aug  6 21:00 30-storage.conf
```

Rename `20-security.conf` to `20-hardening.conf` inside `node02` using `mv(1)` with the non-clobber flag (`-n`):

```bash
mv -n prod_cluster/nodes/node02/etc/sysctl.d/20-security.conf prod_cluster/nodes/node02/etc/sysctl.d/20-hardening.conf
ls -1 prod_cluster/nodes/node02/etc/sysctl.d/
```

Expected output:
```
10-network.conf
20-hardening.conf
30-storage.conf
```

#### Step 1.3: Clean up directories safely
Attempt to remove non-empty directory with `rmdir(1)` vs `rm -r`:

```bash
rmdir prod_cluster/nodes/node01/etc/sysctl.d
```

Expected output:
```
rmdir: prod_cluster/nodes/node01/etc/sysctl.d: Directory not empty
```

Now remove directory cleanly using `rm -rf`:

```bash
rm -rf prod_cluster/nodes/node01
ls -1 prod_cluster/nodes/
```

Expected output:
```
node02
```

---

#### Verification Questions — Exercise 1
1. **Question 1.1:** What is the primary difference in behavior between `cp -a` (or `cp -p`) and standard `cp` regarding file metadata during automated deployments?
2. **Question 1.2:** Why does `rmdir` fail on non-empty directories at the VFS layer, and how does this safeguard production pipelines compared to `rm -rf`?

---

### Exercise 2: Hard Links, Soft Links, and Inode Ref-Count Analysis

#### Step 2.1: Create source file and inspect initial inode state
Create a file named `app_v1.bin` and inspect its inode number and link count using `ls -i -l`:

```bash
echo "binary_v1.0_payload" > app_v1.bin
ls -i -l app_v1.bin
```

Expected output (inode number will vary):
```
1048600 -rw-r--r--  1 root  wheel  20 Aug  6 21:00 app_v1.bin
```
*(Notice link count is `1` in column 3).*

#### Step 2.2: Create a hard link and verify inode sharing
Create a hard link named `app_current.bin` pointing to `app_v1.bin`:

```bash
ln app_v1.bin app_current.bin
ls -i -l app_v1.bin app_current.bin
```

Expected output:
```
1048600 -rw-r--r--  2 root  wheel  20 Aug  6 21:00 app_current.bin
1048600 -rw-r--r--  2 root  wheel  20 Aug  6 21:00 app_v1.bin
```
*(Notice both files share inode `1048600`, and the link count increased to `2`).*

#### Step 2.3: Create a symbolic link and inspect entry structure
Create a symbolic link named `app_symlink.bin` pointing to `app_v1.bin`:

```bash
ln -s app_v1.bin app_symlink.bin
ls -i -l app_v1.bin app_symlink.bin
```

Expected output:
```
1048600 -rw-r--r--  2 root  wheel  20 Aug  6 21:00 app_v1.bin
1048601 lrwxr-xr-x  1 root  wheel  10 Aug  6 21:00 app_symlink.bin -> app_v1.bin
```
*(Notice `app_symlink.bin` has a new inode `1048601`, file type `l`, and size 10 matching string length of target `"app_v1.bin"`).*

#### Step 2.4: Test unlink behavior by removing target file
Delete the original file `app_v1.bin`:

```bash
rm app_v1.bin
ls -i -l app_current.bin app_symlink.bin
```

Expected output:
```
1048600 -rw-r--r--  1 root  wheel  20 Aug  6 21:00 app_current.bin
1048601 lrwxr-xr-x  1 root  wheel  10 Aug  6 21:00 app_symlink.bin -> app_v1.bin
```

Test reading data through both links:

```bash
cat app_current.bin
```
Expected output:
```
binary_v1.0_payload
```

```bash
cat app_symlink.bin
```
Expected output:
```
cat: app_symlink.bin: No such file or directory
```

---

#### Verification Questions — Exercise 2
1. **Question 2.1:** Why does `cat app_current.bin` succeed after `app_v1.bin` is removed, while `cat app_symlink.bin` fails with `No such file or directory`?
2. **Question 2.2:** If a process has `app_v1.bin` open for reading and you run `rm app_v1.bin` and `rm app_current.bin`, when are the underlying disk blocks reclaimed by the kernel?

---

### Exercise 3: Advanced BSD File Flags (`chflags`), Ownership, and Immutable Hardening

#### Step 3.1: Configure ownership and permissions
Create a file named `audit_vault.key`:

```bash
touch audit_vault.key
chmod 0600 audit_vault.key
chown root:wheel audit_vault.key
ls -l audit_vault.key
```

Expected output:
```
-rw-------  1 root  wheel  0 Aug  6 21:00 audit_vault.key
```

#### Step 3.2: Apply user immutability (`uchg`) and test write restrictions
Apply the `uchg` flag to `audit_vault.key` using `chflags(1)`:

```bash
chflags uchg audit_vault.key
```

Verify flag status using `ls -lo`:

```bash
ls -lo audit_vault.key
```

Expected output:
```
-rw-------  1 root  wheel  uchg 0 Aug  6 21:00 audit_vault.key
```

Attempt to append data, rename, or delete the file (even as `root`):

```bash
echo "secret" >> audit_vault.key
```
Expected output:
```
sh: audit_vault.key: Operation not permitted
```

```bash
rm audit_vault.key
```
Expected output:
```
override r-------- root/wheel uchg for audit_vault.key? y
rm: audit_vault.key: Operation not permitted
```

#### Step 3.3: Remove flags and apply append-only (`uappnd`) protection
Clear the immutable flag and set the append-only flag:

```bash
chflags nouchg audit_vault.key
chflags uappnd audit_vault.key
ls -lo audit_vault.key
```

Expected output:
```
-rw-------  1 root  wheel  uappnd 0 Aug  6 21:00 audit_vault.key
```

Test append vs overwrite operations:

```bash
# Valid: Appending data
echo "audit_log_entry_1" >> audit_vault.key
cat audit_vault.key
```
Expected output:
```
audit_log_entry_1
```

```bash
# Invalid: Overwriting/truncating data
echo "overwrite_attempt" > audit_vault.key
```
Expected output:
```
sh: audit_vault.key: Operation not permitted
```

Clean up flag for teardown:

```bash
chflags nuappnd audit_vault.key
rm audit_vault.key
```

---

#### Verification Questions — Exercise 3
1. **Question 3.1:** What is the difference between `uchg` and `schg` flags in BSD systems operating at `kern.securelevel = 1`?
2. **Question 3.2:** Which option flag must be passed to `ls(1)` on BSD systems to inspect file flags such as `uchg`, `schg`, and `nodump`?

---

### Exercise 4: Umask Dynamics, Special Permission Bits (SUID/SGID/Sticky), and Directory Invalidation

#### Step 4.1: Compute and verify `umask` bitwise masks
Check current `umask`:

```bash
umask
```
Expected output:
```
0022
```

Set umask to `0027` and create test files and directories:

```bash
umask 0027
touch secure_file.txt
mkdir secure_dir
ls -ld secure_file.txt secure_dir
```

Expected output:
```
drwxr-x---  2 root  wheel  512 Aug  6 21:00 secure_dir
-rw-r-----  1 root  wheel    0 Aug  6 21:00 secure_file.txt
```

#### Step 4.2: Apply sticky bit and test shared directory isolation
Create a shared directory and set the sticky bit (`1000` / `t`):

```bash
mkdir shared_dropzone
chmod 1777 shared_dropzone
ls -ld shared_dropzone
```

Expected output:
```
drwxrwxrwt  2 root  wheel  512 Aug  6 21:00 shared_dropzone
```

#### Step 4.3: Apply SGID bit on directory for automatic group inheritance
Create a directory with SGID bit (`2000` / `g+s`):

```bash
mkdir shared_team
chmod 2775 shared_team
ls -ld shared_team
```

Expected output:
```
drwxrwsr-x  2 root  wheel  512 Aug  6 21:00 shared_team
```

Reset `umask` back to standard `0022`:

```bash
umask 0022
```

---

#### Verification Questions — Exercise 4
1. **Question 4.1:** Why did `touch secure_file.txt` produce permissions `-rw-r-----` (`0640`) when created under `umask 0027`?
2. **Question 4.2:** In a multi-tenant FreeBSD production environment, what security risk does setting the Sticky Bit (`chmod +t`) mitigate on public writable directories such as `/tmp`?

---

<details>
<summary><strong>3. Comprehensive Answers & Deep-Dive SRE Explanations</strong></summary>

### Exercise 1 Solutions & Mechanical Explanations
* **Answer 1.1:** `cp -p` explicitly preserves timestamps (`atime`, `mtime`), owner `uid`, group `gid`, file permissions `mode`, extended attributes, and file flags (`chflags`). Standard `cp` creates new destination files using the current process credentials (`uid`/`gid`) and evaluates permissions against the active `umask`. In production pipelines (e.g., software deployment), unpreserved metadata causes permission denied errors or inconsistent audit trails.
* **Answer 1.2:** At the VFS layer, `rmdir(2)` checks whether the target directory's link count is greater than 2 (`.` and `..`) or whether directory blocks contain entries other than `.` and `..`. If entries exist, it returns `ENOTEMPTY` (`Directory not empty`). This prevents accidental recursive destruction of directory subtrees. `rm -rf` bypasses this by doing a post-order traversal to call `unlink(2)` on all child files and `rmdir(2)` on empty child directories sequentially.

---

### Exercise 2 Solutions & Mechanical Explanations
* **Answer 2.1:** `app_current.bin` is a hard link that points directly to Inode `1048600`. Deleting `app_v1.bin` calls `unlink("app_v1.bin")`, removing the directory entry for `app_v1.bin` and decrementing inode link count from `2` to `1`. Inode `1048600` remains fully intact, so `cat app_current.bin` accesses the data blocks directly. Conversely, `app_symlink.bin` is a symbolic link containing the text string path `"app_v1.bin"`. When `app_v1.bin` is removed, the target path no longer resolves at VFS path lookup, turning `app_symlink.bin` into a broken/dangling link (`ENOENT`).
* **Answer 2.2:** The kernel reclaims disk blocks only when **both** conditions are satisfied:
  1. The inode's link count (`nlink`) drops to zero.
  2. The file descriptor reference count held by active processes in the kernel process table drops to zero.  
  As long as a process holds an open file descriptor (`open(2)`), the kernel keeps the inode and data blocks allocated on the filesystem, even if `rm` has unlinked all directory entries from disk. When the process terminates or calls `close(2)`, the filesystem frees the blocks.

---

### Exercise 3 Solutions & Mechanical Explanations
* **Answer 3.1:** 
  * `uchg` (User Immutable): Can be set or cleared by the file owner or `root` at any securelevel.
  * `schg` (System Immutable): Can only be modified by `root`. Furthermore, if the system security level (`sysctl kern.securelevel`) is greater than `0` (e.g., in production hardening mode), even `root` is prohibited from clearing `schg`. The system must be rebooted into single-user mode to lower the securelevel before `schg` can be removed.
* **Answer 3.2:** The `-o` flag (`ls -lo`). In FreeBSD, `ls -lo` displays the file flags column (e.g., `uchg`, `uappnd`, `schg`, `nodump`, or `-` if no flags are set).

---

### Exercise 4 Solutions & Mechanical Explanations
* **Answer 4.1:** Files are created by default with base mask `0666` (read + write for user, group, other; executable bit `x` is omitted for non-executable file creation for security).
  Applying `umask 0027`:
  $$\text{Base Mode} = 0666_2 = 110\,110\,110_2$$
  $$\text{Umask} = 0027_2 = 000\,010\,111_2$$
  $$\text{Mask Bitwise Calculation} = 0666 \land \neg(0027) = 0640 \quad (\text{-rw-r-----})$$
  * Owner: `rw-` (`6`)
  * Group: `r--` (`4`)
  * Other: `---` (`0`)
* **Answer 4.2:** On shared directories with `0777` permissions, any user with write permission can delete or rename files created by other users. Setting the **Sticky Bit** (`1000` / `t` on directory) enforces an kernel check during `unlink(2)` and `rename(2)`: a user can only delete or rename files inside the directory if they are the **owner of the file**, the **owner of the directory**, or `root`. This prevents unprivileged users from overwriting or deleting other users' temporary files or sockets in `/tmp` and `/var/tmp`.

</details>

---

## 4. Production Diagnostic & Verification Cheatsheet

### Diagnostic Commands for BSD File Management

```bash
# Display inode numbers, human-readable size, and file flags in a single view
ls -liho /path/to/target

# Locate all files with the 'uchg' or 'schg' immutable flag set under /var
find /var -flags +uchg,schg -ls

# View files with open file descriptors that have been unlinked from disk (FreeBSD fstat)
fstat | grep -E "vnode.*unlinked| Mount"

# Recursively change ownership only if current owner matches user 'www'
chown -h -R --from=www nginx:nginx /var/www/data

# Display file system information and free inodes (UFS/ZFS)
df -ih
```

---

## Summary of Completed Work
- **Course Material**: Produced a production-grade guide for LPI-702 (Exam 702-100) Topic 715.2 (Perform basic file management).
- **Technical Coverage**: Covered inode mechanics, link count (`nlink`), hard vs symbolic links, VFS unlinking semantics, BSD file flags (`chflags`), permission bitwise masking with `umask`, and special bits (`SUID`/`SGID`/`Sticky`).
- **Hands-On Exercises**: Included 4 detailed guided step-by-step labs with shell outputs and verification questions.
- **Answer Key**: Provided deep technical explanations and mathematical permission proofs inside a collapsible `<details>` block.