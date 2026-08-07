# LPI-702 (Exam 702-100) Topic 713.1: Manage User Accounts and Groups

**Certification Target:** LPI BSD Specialist (Exam 702-100, Version 1.0)  
**Topic Code:** 713.1 — Manage User Accounts and Groups  
**Exam Weight:** 5  

---

## 1. System Architecture & Technical Mechanics Overview

In BSD systems (FreeBSD, OpenBSD, NetBSD), user account and group administration differs fundamentally from Linux distributions. Rather than using standard flat-file parsing of `/etc/passwd` and `/etc/shadow` on every system authentication event, BSD systems maintain indexed Berkeley DB databases (`.db` format) for linear $O(1)$ lookups under heavy concurrency.

```
                  +-----------------------------------+
                  |   /etc/master.passwd (0600)       |
                  | 10 Fields (Includes Password Hash)|
                  +-----------------------------------+
                                    |
                                    |  (via vipw or pwd_mkdb)
                                    v
            +-----------------------+-----------------------+
            |                                               |
            v                                               v
+-----------------------+                       +-----------------------+
|  /etc/passwd (0644)   |                       | /etc/spwd.db (0600)   |
| Insecure (No Hashes)  |                       | Indexed DB w/ Hashes  |
+-----------------------+                       +-----------------------+
            |                                               |
            v                                               v
+-----------------------+                       +-----------------------+
|  /etc/pwd.db (0644)   |                       | /etc/login.conf       |
| Insecure Indexed DB   |                       | Resource Limits       |
+-----------------------+                       +-----------------------+
                                                            |
                                                            | (via cap_mkdb)
                                                            v
                                                +-----------------------+
                                                | /etc/login.conf.db    |
                                                +-----------------------+
```

### The 10-Field `master.passwd` Layout
Unlike the 7-field `/etc/passwd` file found on System V and Linux systems, BSD's master authentication source `/etc/master.passwd` contains 10 colon-separated fields:

```
name:password:uid:gid:class:change:expire:gecos:home_dir:shell
```

1. **`name`**: Unique user login name.
2. **`password`**: Encrypted password hash (e.g., Argon2, bcrypt, or SHA-512). Set to `*` or `*LOCKED*` to prevent login.
3. **`uid`**: User ID integer.
4. **`gid`**: Primary Group ID integer.
5. **`class`**: Login class mapped to `/etc/login.conf` (e.g., `default`, `staff`, `untrusted`).
6. **`change`**: Password change time in seconds since Unix epoch (0 = disabled).
7. **`expire`**: Account expiration time in seconds since Unix epoch (0 = disabled).
8. **`gecos`**: User information (Full Name, Office, Office Phone, Home Phone).
9. **`home_dir`**: Absolute path to the user's home directory.
10. **`shell`**: Absolute path to the user's login shell.

### Official Reference Documentation
* LPI BSD Specialist Overview: [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
* FreeBSD `master.passwd` Manual: [https://man.freebsd.org/cgi/man.cgi?query=master.passwd&sektion=5](https://man.freebsd.org/cgi/man.cgi?query=master.passwd&sektion=5)
* FreeBSD `pwd_mkdb` Manual: [https://man.freebsd.org/cgi/man.cgi?query=pwd_mkdb&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=pwd_mkdb&sektion=8)
* FreeBSD `pw` Utility Manual: [https://man.freebsd.org/cgi/man.cgi?query=pw&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=pw&sektion=8)
* FreeBSD `login.conf` Manual: [https://man.freebsd.org/cgi/man.cgi?query=login.conf&sektion=5](https://man.freebsd.org/cgi/man.cgi?query=login.conf&sektion=5)
* OpenBSD `useradd` Manual: [https://man.openbsd.org/useradd.8](https://man.openbsd.org/useradd.8)
* NetBSD `usermod` Manual: [https://man.netbsd.org/usermod.8](https://man.netbsd.org/usermod.8)

---

## Exercise 1: Low-Level User Database Architecture & `pwd_mkdb` Ingestion

### Objective
Manually inspect, modify, and rebuild the BSD user authentication database stack (`/etc/master.passwd`, `/etc/passwd`, `/etc/pwd.db`, `/etc/spwd.db`) while maintaining file locks and syntax validity.

### Guided Steps

1. Inspect the permissions and file types of the password database system files:
   ```bash
   ls -lo /etc/master.passwd /etc/passwd /etc/pwd.db /etc/spwd.db
   ```
   **Expected Output:**
   ```text
   -rw-------  1 root  wheel  - 1482 Aug  6 18:22 /etc/master.passwd
   -rw-r--r--  1 root  wheel  - 1204 Aug  6 18:22 /etc/passwd
   -rw-r--r--  1 root  wheel  - 40960 Aug 6 18:22 /etc/pwd.db
   -rw-------  1 root  wheel  - 40960 Aug 6 18:22 /etc/spwd.db
   ```

2. Invoke `vipw` to lock `/etc/ptmp` and open `/etc/master.passwd` in a safe editor session:
   ```bash
   sudo vipw
   ```

3. Add a new service account entry directly into the 10-field editor buffer at the end of the file:
   ```text
   sre_monitor:*LOCKED*:1500:1500:staff:0:0:SRE Monitoring Agent:/nonexistent:/usr/sbin/nologin
   ```
   Save and exit the editor. Observe the automatic regeneration of indexed binary databases.

4. Verify that `/etc/master.passwd` contains the password field while `/etc/passwd` strips the password field for non-privileged reading:
   ```bash
   sudo grep '^sre_monitor' /etc/master.passwd
   grep '^sre_monitor' /etc/passwd
   ```
   **Expected Output:**
   ```text
   sre_monitor:*LOCKED*:1500:1500:staff:0:0:SRE Monitoring Agent:/nonexistent:/usr/sbin/nologin
   sre_monitor:*:1500:1500:staff:0:0:SRE Monitoring Agent:/nonexistent:/usr/sbin/nologin
   ```

5. Manually force a rebuild of the hashed databases from `/etc/master.passwd` using `pwd_mkdb`:
   ```bash
   sudo pwd_mkdb -p /etc/master.passwd
   ```

6. Inspect the database timestamp update to verify synchronization:
   ```bash
   ls -lu /etc/pwd.db /etc/spwd.db
   ```
   **Expected Output:**
   ```text
   -rw-r--r--  1 root  wheel  - 40960 Aug  6 20:41 /etc/pwd.db
   -rw-------  1 root  wheel  - 40960 Aug  6 20:41 /etc/spwd.db
   ```

---

### Verification Questions — Exercise 1

**Question 1.1:** Why is direct modification of `/etc/master.passwd` using standard text editors (such as `vi` or `nano` directly) considered a critical operational hazard on BSD systems?
* A) Standard editors modify file ownership to `nobody:nogroup`.
* B) Direct editing bypasses `/etc/ptmp` locking, causing race conditions and failing to rebuild `/etc/pwd.db` and `/etc/spwd.db`.
* C) `/etc/master.passwd` is a read-only filesystem mount point on BSD systems.
* D) Standard editors automatically unencrypt hash fields when saving.

**Question 1.2:** A system auditor asks why `/etc/passwd` exists if system authentication relies on `/etc/spwd.db`. What is the primary operational rationale for maintaining `/etc/passwd` via `pwd_mkdb -p`?
* A) legacy NIS (Network Information Service) daemons mandate `/etc/passwd` for root authentication.
* B) Legacy applications and non-root system utilities rely on `/etc/passwd` to map UIDs to usernames without requiring root privileges to access hashes.
* C) `/etc/passwd` acts as an in-memory fallback cache when `pwd.db` suffers disk block corruption.
* D) It stores the secondary group memberships that cannot fit into Berkeley DB records.

---

## Exercise 2: Multi-Platform User Account Lifecycle Management (`pw` vs `useradd`/`usermod`)

### Objective
Master imperative user creation, modification, locking, and deletion across FreeBSD (using the unified `pw` utility) and OpenBSD/NetBSD (using standard `useradd`/`usermod`/`userdel` commands).

### Guided Steps

1. Create a dedicated engineering primary group and user account on FreeBSD using `pw`:
   ```bash
   sudo pw groupadd devops -g 2000
   sudo pw useradd sre_lead -u 2001 -g devops -G wheel -c "Lead SRE Engineer" -m -s /usr/local/bin/zsh
   ```

2. Confirm the account parameters in `/etc/master.passwd` and verify home directory structure:
   ```bash
   pw user show sre_lead
   ls -ld /home/sre_lead
   ```
   **Expected Output:**
   ```text
   sre_lead:*:2001:2000::0:0:Lead SRE Engineer:/home/sre_lead:/usr/local/bin/zsh
   drwxr-xr-x  2 sre_lead  devops  512 Aug  6 20:45 /home/sre_lead
   ```

3. Modify the user account to set an account expiration date and assign a custom login class (`staff`):
   ```bash
   sudo pw usermod sre_lead -L staff -e 31-Dec-2026
   ```

4. Lock the user account immediately to simulate an incident response policy:
   ```bash
   sudo pw lock sre_lead
   ```

5. Inspect the password field in `/etc/master.passwd` to analyze the exact locking syntax implemented by BSD:
   ```bash
   sudo grep '^sre_lead' /etc/master.passwd
   ```
   **Expected Output:**
   ```text
   sre_lead:*LOCKED*1798761600:2001:2000:staff:0:1798761600:Lead SRE Engineer:/home/sre_lead:/usr/local/bin/zsh
   ```

6. Unlock the user account and restore operational status:
   ```bash
   sudo pw unlock sre_lead
   ```

7. Execute equivalent account creation on OpenBSD/NetBSD using `useradd`:
   ```bash
   sudo groupadd -g 3000 secops
   sudo useradd -u 3001 -g secops -G wheel -c "Security Analyst" -m -s /bin/ksh sec_analyst
   ```

8. Modify the login shell on OpenBSD/NetBSD using `usermod`:
   ```bash
   sudo usermod -s /usr/local/bin/bash sec_analyst
   ```

---

### Verification Questions — Exercise 2

**Question 2.1:** What is the structural difference in `/etc/master.passwd` between locking a user account with `pw lock <user>` versus changing their login shell to `/usr/sbin/nologin`?
* A) `pw lock` prepends `*LOCKED*` to the password hash, preventing authentication entirely, while setting shell to `/usr/sbin/nologin` permits authentication but denies interactive shell access.
* B) `pw lock` deletes the entry from `/etc/spwd.db`, whereas `/usr/sbin/nologin` removes the home directory.
* C) `pw lock` changes the UID to `65534`, whereas `/usr/sbin/nologin` disables password expiration timestamps.
* D) Both actions perform identical modifications under the hood by changing the login class field to `disabled`.

**Question 2.2:** When using `pw useradd` on FreeBSD without specifying the `-g` flag, what is the default primary group assignment behavior?
* A) The user is automatically assigned to primary GID `0` (`wheel`).
* B) The user is assigned to the `nobody` group (GID `65534`).
* C) `pw` creates a new group with the same name as the user and assigns an identical GID/UID integer pair.
* D) The command fails with an syntax error demanding an explicit GID.

---

## Exercise 3: Group Architecture, Membership Isolation, and `vigr`

### Objective
Manage secondary group assignments, preserve `/etc/group` integrity using `vigr`, and implement shared directory access controls with SGID bit semantics.

### Guided Steps

1. Safely open `/etc/group` for editing using `vigr`:
   ```bash
   sudo vigr
   ```

2. Add a new secondary engineering group `platform` and append users directly in the file:
   ```text
   platform:*:2500:sre_lead,sec_analyst
   ```
   Save and close the editor.

3. Verify group membership using `id` and `pw`:
   ```bash
   id sre_lead
   ```
   **Expected Output:**
   ```text
   uid=2001(sre_lead) gid=2000(devops) groups=2000(devops),0(wheel),2500(platform)
   ```

4. Create a shared team directory and assign group ownership to `platform`:
   ```bash
   sudo mkdir -p /var/data/platform_shared
   sudo chown root:platform /var/data/platform_shared
   ```

5. Apply the set-group-ID (SGID) bit and directory permissions so all newly created files automatically inherit group ownership:
   ```bash
   sudo chmod 2770 /var/data/platform_shared
   ls -ld /var/data/platform_shared
   ```
   **Expected Output:**
   ```text
   drwxr-sr-x  2 root  platform  512 Aug  6 20:50 /var/data/platform_shared
   ```

6. Append a user to a group imperatively on FreeBSD using `pw groupmod`:
   ```bash
   sudo pw groupmod platform -m sre_monitor
   groups sre_monitor
   ```
   **Expected Output:**
   ```text
   devops platform
   ```

---

### Verification Questions — Exercise 3

**Question 3.1:** What locking mechanism does `vigr` utilize to prevent concurrent administrative race conditions when modifying `/etc/group`?
* A) It acquires a POSIX flock lock on `/etc/master.passwd`.
* B) It creates a lock file named `/etc/gtmp` during the edit session.
* C) It temporarily modifies `/etc/group` filesystem attributes to immutable (`chflags uchg`).
* D) It stops the `cron` and `sshd` system daemons until editing finishes.

**Question 3.2:** If user `sec_analyst` creates a file inside `/var/data/platform_shared` (which has permissions `2770` and ownership `root:platform`), what will be the group ownership of the created file?
* A) `secops` (The user's primary group).
* B) `wheel` (The default administrative root group).
* C) `platform` (Inherited from the parent directory due to SGID bit).
* D) `nobody` (Stripped due to non-root execution).

---

## Exercise 4: Declarative Environment Provisioning via Skeleton Templates & Login Classes

### Objective
Customize default user skeleton files in `/usr/share/skel`, configure fine-grained system resource limits in `/etc/login.conf`, and compile the binary capability database using `cap_mkdb`.

### Guided Steps

1. Inspect the default skeleton template directory structure on BSD:
   ```bash
   ls -la /usr/share/skel/
   ```
   **Expected Output:**
   ```text
   drwxr-xr-x   2 root  wheel   512 Aug  6 18:00 .
   drwxr-xr-x  30 root  wheel  1024 Aug  6 18:00 ..
   -rw-r--r--   1 root  wheel   942 Aug  6 18:00 dot.cshrc
   -rw-r--r--   1 root  wheel   481 Aug  6 18:00 dot.login
   -rw-r--r--   1 root  wheel   243 Aug  6 18:00 dot.profile
   -rw-r--r--   1 root  wheel   352 Aug  6 18:00 dot.shrc
   ```

2. Create a global custom shell initialization template for all newly created accounts:
   ```bash
   sudo sh -c 'cat << "EOF" >> /usr/share/skel/dot.profile
   # Enterprise SRE Environment Defaults
   export HISTSIZE=10000
   export BLOCKSIZE=K
   alias ll="ls -laFo"
   EOF'
   ```

3. Open `/etc/login.conf` and define a complete, syntactically valid custom login class named `sre_tier` with production resource bounds:

```text
sre_tier:\
	:lang=en_US.UTF-8:\
	:setenv=MAIL=/var/mail/$USER,BLOCKSIZE=K:\
	:path=/sbin /bin /usr/sbin /usr/bin /usr/local/sbin /usr/local/bin:\
	:cputime=unlimited:\
	:datasize=4G:\
	:stacksize=128M:\
	:memorymax=8G:\
	:openfiles=2048:\
	:maxproc=512:\
	:coredumpsize=0:\
	:priority=0:\
	:tc=default:
```

4. Add the `sre_tier` class stanza to `/etc/login.conf` and compile the file capability database using `cap_mkdb`:
   ```bash
   sudo cap_mkdb /etc/login.conf
   ls -l /etc/login.conf.db
   ```
   **Expected Output:**
   ```text
   -rw-r--r--  1 root  wheel  8192 Aug  6 20:55 /etc/login.conf.db
   ```

5. Assign the new `sre_tier` login class to user `sre_lead` and verify using `limits`:
   ```bash
   sudo pw usermod sre_lead -L sre_tier
   sudo limits -U sre_lead
   ```
   **Expected Output:**
   ```text
   Resource limits for user sre_lead (class sre_tier):
     cputime          infinity secs
     datasize          4194304 kB
     stacksize          131072 kB
     coredumpsize            0 kB
     memoryuse        8388608 kB
     maxproc               512
     openfiles            2048
   ```

---

### Verification Questions — Exercise 4

**Question 4.1:** Why must `cap_mkdb` be executed immediately after making changes to `/etc/login.conf`?
* A) `cap_mkdb` verifies PAM authentication syntax and reloads the `sshd` service daemon.
* B) The kernel and system APIs (such as `getcap(3)`) read the compiled binary Hashed DB `/etc/login.conf.db` for performance rather than parsing flat text.
* C) `cap_mkdb` encrypts the skeleton dotfiles copied to user home directories.
* D) It converts BSD login capability syntax into Linux `/etc/security/limits.conf` format.

**Question 4.2:** Which parameter in a `/etc/login.conf` capability entry allows a custom class to inherit all default settings from an existing class baseline while applying specific overrides?
* A) `:inherit=default:`
* B) `:parent=default:`
* C) `:tc=default:`
* D) `:include=/etc/login.conf.default:`

---

## Exercise 5: Incident Response & Emergency Database Repair

### Objective
Diagnose and repair a corrupted BSD password database state, recover from lock file deadlocks, and execute emergency single-user emergency restoration.

### Guided Steps

1. Simulate a scenario where a hard power loss occurs while an administrator was running `vipw`, leaving an abandoned lock file behind:
   ```bash
   sudo touch /etc/ptmp
   ```

2. Attempt to run `vipw` or `pw` and observe the lock collision error:
   ```bash
   sudo vipw
   ```
   **Expected Output:**
   ```text
   vipw: /etc/ptmp: File exists
   vipw: /etc/master.passwd: resource temporarily unavailable
   ```

3. Identify stale lock files and clear the locking lockfile safely:
   ```bash
   ls -l /etc/ptmp /etc/gtmp
   sudo rm -f /etc/ptmp /etc/gtmp
   ```

4. Simulate database index desynchronization by corrupting `/etc/spwd.db` and verify diagnostic output:
   ```bash
   sudo truncate -s 0 /etc/spwd.db
   id sre_lead
   ```
   *Note: Under desynchronized conditions, user resolution may fail or report missing details because `getpwnam(3)` queries the corrupted DB file.*

5. Execute emergency database recovery from `/etc/master.passwd` using `pwd_mkdb`:
   ```bash
   sudo pwd_mkdb -C /etc/master.passwd
   ```
   **Expected Output:**
   ```text
   pwd_mkdb: /etc/master.passwd: integrity check passed
   ```

6. Rebuild both `pwd.db` and `spwd.db` cleanly:
   ```bash
   sudo pwd_mkdb -p /etc/master.passwd
   ```

---

### Verification Questions — Exercise 5

**Question 5.1:** What is the primary purpose of the `pwd_mkdb -C` flag during emergency diagnostic procedures?
* A) It converts MD5 password hashes into SHA-512 hashes.
* B) It checks the syntax and structural integrity of `/etc/master.passwd` without altering existing `.db` databases.
* C) It clears all active user sessions and terminates background daemons.
* D) It creates an encrypted backup of `/etc/passwd` in `/var/backups`.

**Question 5.2:** During an emergency recovery in single-user mode, `/etc/master.passwd` is edited manually using `vi` because `vipw` fails due to a read-only root filesystem mount. Which sequence of commands must be executed to properly restore system access?
* A) `mount -uw /` followed by `pwd_mkdb -p /etc/master.passwd`
* B) `reboot --force`
* C) `cap_mkdb /etc/passwd` followed by `touch /etc/ptmp`
* D) `chmod 777 /etc/spwd.db`

---

<details>
<summary><strong>Click to expand Answer Key & Technical Explanations</strong></summary>

### Exercise 1 Answers

* **Question 1.1 Solution: B**
  * **Explanation:** Direct editing of `/etc/master.passwd` bypasses the atomic file lock (`/etc/ptmp`). Furthermore, standard text editors do not automatically invoke `pwd_mkdb`. As a result, the indexed databases (`/etc/pwd.db` and `/etc/spwd.db`) become desynchronized from the text file, rendering system authentication out-of-date or broken.
* **Question 1.2 Solution: B**
  * **Explanation:** `/etc/passwd` is a world-readable (0644) legacy file generated by `pwd_mkdb -p` where all password hash fields are replaced with `*`. Non-privileged commands (like `ls -l`, `ps`, or `finger`) read `/etc/passwd` or `/etc/pwd.db` to resolve numerical UIDs to human-readable names without needing elevated permissions to read sensitive password hashes stored in `/etc/spwd.db` (0600).

---

### Exercise 2 Answers

* **Question 2.1 Solution: A**
  * **Explanation:** `pw lock` alters the password field in `/etc/master.passwd` by prepending the string `*LOCKED*`. This invalidates hash verification at the PAM/authentication layer, preventing all authentication mechanisms (SSH key auth, password auth, etc.). Changing the shell to `/usr/sbin/nologin` allows PAM authentication to succeed, but immediately terminates the session upon shell execution.
* **Question 2.2 Solution: C**
  * **Explanation:** By default, BSD follow the User Private Group (UPG) scheme. When creating a user without specifying `-g`, `pw` creates a new primary group matching the username and assigns identical UID and GID numbers.

---

### Exercise 3 Answers

* **Question 3.1 Solution: B**
  * **Explanation:** `vigr` creates an atomic lock file named `/etc/gtmp`. If another administrator attempts to run `vigr` or `pw groupmod` concurrently, the process detects `/etc/gtmp` and aborts to prevent file corruption.
* **Question 3.2 Solution: C**
  * **Explanation:** Setting the Set-Group-ID (SGID) bit (`chmod 2770` or `chmod g+s`) on a directory forces all newly created files and subdirectories within it to inherit the parent directory's group ownership (`platform`), rather than the creating user's primary group (`secops`).

---

### Exercise 4 Answers

* **Question 4.1 Solution: B**
  * **Explanation:** BSD C library functions (such as `getcap(3)` and `getpwuid(3)`) utilize fast Berkeley DB files (`.db`) for key-value lookups. Modifications to `/etc/login.conf` remain inactive until `cap_mkdb` compiles the text configuration into `/etc/login.conf.db`.
* **Question 4.2 Solution: C**
  * **Explanation:** The `:tc=` (template capability) entry allows a login class to include another capability entry as a base template. For example, `:tc=default:` inherits all default system resource limits and applies specified class overrides.

---

### Exercise 5 Answers

* **Question 5.1 Solution: B**
  * **Explanation:** The `-C` flag tells `pwd_mkdb` to run in check-only mode. It performs syntax analysis and field validation on `/etc/master.passwd` without generating output database files or modifying system state.
* **Question 5.2 Solution: A**
  * **Explanation:** Single-user mode initially mounts the root filesystem as read-only (`ro`). The administrator must first remount root as read-write (`mount -uw /`). After editing `/etc/master.passwd`, `pwd_mkdb -p /etc/master.passwd` must be run to generate `/etc/passwd`, `/etc/pwd.db`, and `/etc/spwd.db`.

</details>