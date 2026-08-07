# LPI-702 (Exam 702-100 v1.0) Topic 712.4: Manage File Permissions and Ownership

**Weight:** 5  
**Official References:**
* [LPI BSD Specialist Certification Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
* [FreeBSD Handbook: File Permissions](https://docs.freebsd.org/en/books/handbook/basics/#permissions)
* [FreeBSD Manual Pages: chmod(1)](https://man.freebsd.org/cgi/man.cgi?query=chmod&sektion=1)
* [FreeBSD Manual Pages: chflags(1)](https://man.freebsd.org/cgi/man.cgi?query=chflags&sektion=1)
* [FreeBSD Manual Pages: setfacl(1)](https://man.freebsd.org/cgi/man.cgi?query=setfacl&sektion=1)
* [FreeBSD Manual Pages: getfacl(1)](https://man.freebsd.org/cgi/man.cgi?query=getfacl&sektion=1)

---

## Exercise 1: Standard POSIX Permissions, Ownership, and Umask Mechanics

### Objective
Understand the underlying inode permission mode bits (`st_mode`), user/group ID mapping (`st_uid`/`st_gid`), octal vs. symbolic representations, and process bitwise mask subtraction (`umask`) in BSD systems.

---

### Hands-On Steps

1. Create a dedicated workspace and inspect default `umask` behavior during file and directory creation.

```bash
$ mkdir -p /tmp/permission_lab && cd /tmp/permission_lab
$ umask
0022
$ touch standard_file.txt
$ mkdir standard_dir
$ ls -ld standard_file.txt standard_dir
drwxr-xr-x  2 student  wheel  512 Aug  6 20:30 standard_dir
-rw-r--r--  1 student  wheel    0 Aug  6 20:30 standard_file.txt
```

2. Perform octal and symbolic permission mutations using `chmod`, observing how `st_mode` bits map to Read (4), Write (2), and Execute (1) across User, Group, and Other tiers.

```bash
$ chmod 0640 standard_file.txt
$ ls -l standard_file.txt
-rw-r-----  1 student  wheel  0 Aug  6 20:30 standard_file.txt

$ chmod g+w,o-r standard_file.txt
$ ls -l file_permission_check
-rw-rw----  1 student  wheel  0 Aug  6 20:30 standard_file.txt
```

3. Change user and group ownership using `chown` and `chgrp`. Note that on BSD systems, non-root users cannot give away file ownership (`chown` is restricted by `sysctl security.bsd.see_other_uids` and kernel VFS security checks). Switch to `root` or use `sudo` to reassign ownership.

```bash
$ sudo chown www:www standard_file.txt
$ ls -l standard_file.txt
-rw-rw----  1 www  www  0 Aug  6 20:30 standard_file.txt

$ sudo chgrp daemon standard_file.txt
$ ls -l standard_file.txt
-rw-rw----  1 www  daemon  0 Aug  6 20:30 standard_file.txt
```

4. Modify the process `umask` dynamically and observe how the bitwise complement filter applies to maximum creation permissions (`0666` for regular files, `0777` for directories).

```bash
$ umask 0077
$ touch strict_file.txt
$ mkdir strict_dir
$ ls -ld strict_file.txt strict_dir
drx------  2 student  wheel  512 Aug  6 20:32 strict_dir
-rw-------  1 student  wheel    0 Aug  6 20:32 strict_file.txt
```

---

### Verification Questions

1. **Question 1.1:** If a process with a `umask` of `0027` creates a directory using `mkdir()`, what are the precise octal and symbolic permissions assigned to the directory inode? Show the bitwise calculation.
2. **Question 1.2:** Why does a regular file created under `umask 0000` get `0666` permissions instead of `0777`? What system call parameter dictates this boundary?

---

## Exercise 2: Special Permission Bits (SUID, SGID, Sticky Bit) and Directory Inheritance

### Objective
Master the operational behavior and security implications of SUID (`4000`), SGID (`2000`), and Sticky (`1000`) bits on executable binaries and directories in BSD filesystems.

---

### Hands-On Steps

1. Create a shared directory hierarchy to examine group ownership inheritance via the SGID bit (`chmod 2770` or `chmod g+s`).

```bash
$ sudo mkdir -p /tmp/permission_lab/shared_project
$ sudo chown root:wheel /tmp/permission_lab/shared_project
$ sudo chmod 2770 /tmp/permission_lab/shared_project
$ ls -ld /tmp/permission_lab/shared_project
drwxrws---  2 root  wheel  512 Aug  6 20:35 /tmp/permission_lab/shared_project
```

2. Create a file inside the SGID-enabled directory as user `student` (who belongs to a non-primary group or default group) and verify group ID inheritance.

```bash
$ cd /tmp/permission_lab/shared_project
$ touch team_doc.txt
$ ls -l team_doc.txt
-rw-r--r--  1 student  wheel  0 Aug  6 20:36 team_doc.txt
```

> **BSD Architectural Note:** On BSD systems, directories inherit the group ownership of their parent directory by default upon creation, even without the SGID bit set. Setting the SGID bit on a directory additionally ensures that any subdirectories created inside will also inherit the SGID bit.

3. Configure a public write directory with the Sticky Bit (`chmod 1777` or `chmod +t`) to prevent unprivileged users from deleting or renaming files owned by others.

```bash
$ sudo mkdir -p /tmp/permission_lab/public_drop
$ sudo chmod 1777 /tmp/permission_lab/public_drop
$ ls -ld /tmp/permission_lab/public_drop
drwxrwxrwt  2 root  wheel  512 Aug  6 20:38 /tmp/permission_lab/public_drop
```

4. Create a dummy binary and examine SUID bit application (`chmod 4755` or `chmod u+s`). Note how uppercase `S` indicates missing execution rights for the owner/group.

```bash
$ cp /bin/echo /tmp/permission_lab/custom_echo
$ sudo chmod 4755 /tmp/permission_lab/custom_echo
$ ls -l /tmp/permission_lab/custom_echo
-rwsr-xr-x  1 root  wheel  24128 Aug  6 20:40 /tmp/permission_lab/custom_echo

$ chmod u-x /tmp/permission_lab/custom_echo
$ ls -l /tmp/permission_lab/custom_echo
-rwSr-xr-x  1 root  wheel  24128 Aug  6 20:40 /tmp/permission_lab/custom_echo
```

---

### Verification Questions

1. **Question 2.1:** In a directory configured with `chmod 1777`, user `alice` creates a file `data.log`. Can user `bob` (who has full write permissions on `data.log` via group permissions) delete or rename `data.log`? Why or why not?
2. **Question 2.2:** What is the technical meaning of uppercase `S` vs lowercase `s` in the output of `ls -l` for user and group permission fields?

---

## Exercise 3: BSD Extended File Flags (`chflags`) and Securelevel Enforcement

### Objective
Understand the BSD-specific extended file flags subsystem (`st_flags`), including user flags (`uchg`, `uappnd`) and system flags (`schg`, `sappnd`), and their interaction with `sysctl kern.securelevel`.

---

### Hands-On Steps

1. Create a critical configuration file and list extended file flags using `ls -lo` (BSD-specific verbose flag display).

```bash
$ cd /tmp/permission_lab
$ touch critical_config.conf
$ ls -lo critical_config.conf
-rw-r--r--  1 student  wheel  - 0 Aug  6 20:42 critical_config.conf
```

2. Apply the User Immutable flag (`uchg`) to prevent modification, renaming, or deletion—even by file owner or `root` (when `kern.securelevel` is low).

```bash
$ chflags uchg critical_config.conf
$ ls -lo critical_config.conf
-rw-r--r--  1 student  wheel  uchg 0 Aug  6 20:42 critical_config.conf

$ rm critical_config.conf
rm: critical_config.conf: Operation not permitted

$ echo "malicious append" >> critical_config.conf
bash: critical_config.conf: Operation not permitted
```

3. Remove the User Immutable flag using the `no` prefix (`nouchg`).

```bash
$ chflags nouchg critical_config.conf
$ ls -lo critical_config.conf
-rw-r--r--  1 student  wheel  - 0 Aug  6 20:43 critical_config.conf
```

4. Apply User Append-Only (`uappnd`) flag and test writing constraints.

```bash
$ chflags uappnd critical_config.conf
$ ls -lo critical_config.conf
-rw-r--r--  1 student  wheel  uappnd 0 Aug  6 20:44 critical_config.conf

$ echo "line 1" >> critical_config.conf
$ cat critical_config.conf
line 1

$ echo "overwrite" > critical_config.conf
bash: critical_config.conf: Operation not permitted
```

5. Clear flags and inspect System Immutable (`schg`) flag behavior and `kern.securelevel` state.

```bash
$ chflags nouappnd critical_config.conf
$ sudo chflags schg critical_config.conf
$ ls -lo critical_config.conf
-rw-r--r--  1 student  wheel  schg 7 Aug  6 20:45 critical_config.conf

$ sysctl kern.securelevel
kern.securelevel: -1
```

> **Security Architecture Note:** When `kern.securelevel` is `-1` or `0`, `root` can clear `schg` via `sudo chflags noschg`. However, when `kern.securelevel >= 1`, `schg` flags **cannot** be removed by any process (including `root`), preventing compromise even if superuser privilege is acquired.

---

### Verification Questions

1. **Question 3.1:** What is the fundamental difference between `uchg` (User Immutable) and `schg` (System Immutable)? Who can set and unset each flag?
2. **Question 3.2:** If `sysctl kern.securelevel` returns `1`, can root clear the `schg` flag on `/sbin/init`? What administrative intervention is required to modify a file locked with `schg` at `securelevel 1`?

---

## Exercise 4: Granular Control with FreeBSD POSIX.1e and NFSv4 Access Control Lists (ACLs)

### Objective
Deploy, audit, and remove POSIX.1e and NFSv4 Access Control Lists using `getfacl` and `setfacl` on FreeBSD file systems (UFS and ZFS).

---

### Hands-On Steps

1. Check the target filesystem type and ACL support settings (`tunefs` for UFS or `aclmode`/`aclinherit` properties for ZFS).

```bash
$ zfs get aclmode,aclinherit zroot/tmp
NAME       PROPERTY    VALUE          SOURCE
zroot/tmp  aclmode     passthrough    default
zroot/tmp  aclinherit  passthrough    default
```

2. Create a file for ACL manipulation and inspect its default ACL structure using `getfacl`.

```bash
$ cd /tmp/permission_lab
$ touch acl_file.txt
$ getfacl acl_file.txt
# file: acl_file.txt
# owner: student
# group: wheel
user::rw-
group::r--
other::r--
```

3. Grant specific read-write permissions to an explicit user (`operator`) using `setfacl -m` (POSIX.1e format). Notice how the trailing `+` appears in standard `ls -l` output when ACL entries exist.

```bash
$ setfacl -m u:operator:rw- acl_file.txt
$ getfacl acl_file.txt
# file: acl_file.txt
# owner: student
# group: wheel
user::rw-
user:operator:rw-
group::r--
mask::rw-
other::r--

$ ls -l acl_file.txt
-rw-rw-r--+ 1 student  wheel  0 Aug  6 20:50 acl_file.txt
```

4. Modify the POSIX.1e mask entry (`mask::`) to constrain effective maximum permissions for named users and groups.

```bash
$ setfacl -m m::r-- acl_file.txt
$ getfacl acl_file.txt
# file: acl_file.txt
# owner: student
# group: wheel
user::rw-
user:operator:rw-	#effective:r--
group::r--
mask::r--
other::r--
```

5. Remove specific ACL entries (`setfacl -x`) or strip all extended ACL entries (`setfacl -b`).

```bash
$ setfacl -x u:operator acl_file.txt
$ getfacl acl_file.txt
# file: acl_file.txt
# owner: student
# group: wheel
user::rw-
group::r--
mask::r--
other::r--

$ setfacl -b acl_file.txt
$ ls -l acl_file.txt
-rw-r--r--  1 student  wheel  0 Aug  6 20:52 acl_file.txt
```

---

### Verification Questions

1. **Question 4.1:** How does the POSIX.1e `mask::` entry recalculate the *effective permissions* for explicit user (`u:name:`) and group (`g:name:`) ACL entries?
2. **Question 4.2:** What character in the output of `ls -l` signals that a file has extended ACL entries on FreeBSD, and how does ZFS NFSv4 ACL output differ from POSIX.1e output in `getfacl`?

---

## Solutions & Detailed Explanations

<details>
<summary>Click here to expand solutions for Exercises 1 to 4</summary>

### Exercise 1 Solutions

* **Answer 1.1:**
  * **Octal Permissions:** `0750`
  * **Symbolic Permissions:** `drwxr-x---`
  * **Bitwise Calculation:**
    Directories evaluate base creation mode `0777` (`111 111 111` in binary).
    `umask 0027` (`000 010 111` in binary).
    Formula: $\text{Mode} = \text{Base} \land \neg(\text{Umask})$
    $$\text{User}: 7 \land \neg(0) = 7 \quad (rwx)$$
    $$\text{Group}: 7 \land \neg(2) = 5 \quad (r-x)$$
    $$\text{Other}: 7 \land \neg(7) = 0 \quad (---)$$
    Resulting octal mode is `0750` (`drwxr-x---`).

* **Answer 1.2:**
  POSIX system calls (`open(2)`, `creat(2)`) specify a maximum creation mask of `0666` (`rw-rw-rw-`) for files by default to avoid creating executable security hazards automatically. The execute bit (`x`) is intentionally withheld unless explicitly passed by the application binary during invocation. `umask` subtracts permissions from this `0666` base for regular files.

---

### Exercise 2 Solutions

* **Answer 2.1:**
  **No, user `bob` cannot delete or rename `data.log`.**  
  Under the Sticky Bit (`+t` / `1000`) on a directory, directory write permissions alone do not grant file unlinking (deletion) or renaming rights. A user can only delete/rename a file inside a sticky directory if at least one of the following conditions is met:
  1. The user owns the file (`st_uid` matches).
  2. The user owns the directory (`st_uid` of directory matches).
  3. The user is `root` (superuser privileges).

* **Answer 2.2:**
  * **Lowercase `s` (`rwsr-xr-x` / `rwxr-sr-x`):** Indicates that the SUID/SGID bit is set **AND** the corresponding owner/group execute bit (`x`) is also set.
  * **Uppercase `S` (`rwSr-xr-x` / `rwxr-Sr-x`):** Indicates that the SUID/SGID bit is set **BUT** the underlying owner/group execute bit (`x`) is **NOT** set (indicating potential configuration oversight).

---

### Exercise 3 Solutions

* **Answer 3.1:**
  * **`uchg` (User Immutable):** Can be set or cleared by the owner of the file or by `root`. It prevents file modification, deletion, renaming, or link creation.
  * **`schg` (System Immutable):** Can **only** be set or cleared by `root`. Furthermore, its removal depends strictly on `sysctl kern.securelevel`.

* **Answer 3.2:**
  **No, root cannot clear `schg` while `kern.securelevel >= 1`.**  
  To modify or clear `schg` on `/sbin/init` when running at `securelevel 1`:
  1. Edit `/etc/rc.conf` to adjust securelevel settings (or boot into single-user mode).
  2. Reboot the operating system into single-user mode (where `securelevel` defaults to `-1` or `0`).
  3. Execute `chflags noschg /sbin/init`.
  4. Perform required maintenance and reboot back to multi-user operation.

---

### Exercise 4 Solutions

* **Answer 4.1:**
  In POSIX.1e ACLs, the `mask::` entry defines the **maximum allowable permission ceiling** for all named users (`u:username:`), named groups (`g:groupname:`), and the primary group (`group::`). The effective permission granted to any named entity is calculated via a bitwise AND between that entity's permission entry and the `mask::` entry:
  $$\text{Effective Permission} = \text{ACL Entry} \land \text{Mask Entry}$$
  If `user:operator` has `rw-` (4+2=6) and `mask::` is set to `r--` (4), the resulting effective permission is `r--` (4).

* **Answer 4.2:**
  * The **plus sign (`+`)** at the end of the mode string in `ls -l` (e.g., `-rw-rw-r--+`) indicates extended ACL entries exist on the vnode.
  * **POSIX.1e ACLs** (UFS) display permissions in standard `user/group/mask/other` format.
  * **NFSv4 ACLs** (ZFS default) display detailed fine-grained access entries with explicit inherit flags and detailed privileges (e.g., `user:alice:read_data/write_data/append_data/allow`).

</details>