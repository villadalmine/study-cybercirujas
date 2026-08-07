# Enterprise Production Guide: BSD User Accounts and Group Management
**Certification:** LPI 702 BSD Specialist (Exam 702-100, Version 1.0)  
**Topic 713.1:** Manage User Accounts and Groups  
**Objective Weight:** 5  

---

## 1. Production Architectural Motivation & Problem

In high-availability, multi-tenant enterprise environments, state management for user identities and group authorization forms the core security boundary of the operating system. UNIX user and group management on BSD platforms (FreeBSD, OpenBSD, NetBSD) differs fundamentally from Linux distribution models in both database architecture and runtime resolution performance.

### The Production Identity Problem
Modern infrastructure architectures face three major challenges regarding local identity management:

1. **System Lookup Latency at Scale**: Sequential parsing of standard text files (`/etc/passwd`, `/etc/group`) introduces severe I/O bottlenecks when user counts scale to tens of thousands on high-throughput application servers, batch processing nodes, or CI/CD build pools.
2. **Atomic State Updates & Concurrency Control**: Race conditions during concurrent user provisioning (e.g., automated configuration management agents executing alongside microservice user bootstrap scripts) can result in truncated identity files, inconsistent permissions, or system lockouts.
3. **Fine-Grained Resource Isolation (Login Capabilities)**: Linux traditionally separates resource limits into `/etc/security/limits.conf` (PAM dependent) and user properties into `/etc/passwd`. BSD consolidates user profile metadata, process memory caps, open file descriptor limits, resource usage, CPU constraints, and authentication requirements into a unified engine backed by `/etc/login.conf`.

### BSD Architectural Solutions
BSD systems solve these challenges through:
* **Hashed Database Generation**: The master account file `/etc/master.passwd` is compiled via `pwd_mkdb` into indexed Berkeley DB binary databases (`/etc/pwd.db` and `/etc/spwd.db`). System system calls (`getpwnam(3)`, `getpwuid(3)`) perform $O(1)$ indexed binary lookups rather than $O(N)$ sequential file scans.
* **Separation of Public and Shadow Passwords**: `/etc/passwd` contains public metadata (with password fields masked as `*`), while `/etc/master.passwd` and `/etc/spwd.db` store encrypted password hashes (bcrypt/SHA-512) accessible exclusively by `root` (mode `0600`).
* **Centralized System Utility (`pw`)**: FreeBSD centralizes all account and group mutations through the `pw(8)` management engine. It handles locking via `/etc/ptmp`, atomic file updates, home directory skeleton initialization, login class assignments, and automatic database regeneration in a single transaction.

---

## 2. Technical Comparisons & Trade-off Tables

### 2.1 BSD Identity Database Architecture vs. Linux Shadow Architecture

| Feature / Dimension | BSD Identity Architecture (`/etc/master.passwd`) | Linux Identity Architecture (`/etc/shadow`) |
| :--- | :--- | :--- |
| **Primary Master File** | `/etc/master.passwd` (10 fields) | Split across `/etc/passwd` (7 fields) & `/etc/shadow` (9 fields) |
| **Lookup Mechanism** | $O(1)$ Berkeley DB binary lookups (`/etc/pwd.db`, `/etc/spwd.db`) | $O(N)$ text scanning or `nscd`/`sssd` daemon caching |
| **Database Compilation Tool** | `pwd_mkdb` (manual or auto-triggered via `pw`/`vipw`) | `grpck` / `pwconv` / `grpconv` (sync utility scripts) |
| **Resource Allocation Control** | Native login class field mapping to `/etc/login.conf` | External PAM modules (`pam_limits.so`) & Systemd slices |
| **Password Expiration Storage** | Embedded epoch fields in `master.passwd` (`change`, `expire`) | Stored in shadow file as days since Epoch |
| **File Locking Lockfile** | `/etc/ptmp` | `/etc/passwd.lock`, `/etc/shadow.lock` |

### 2.2 User Provisioning Tools Comparison across BSD Variants

| Command / Tool | Primary Platform | Operations Supported | Key Characteristics & Trade-offs |
| :--- | :--- | :--- | :--- |
| **`pw`** | FreeBSD | User/Group CRUD, locking, password aging | Unified system binary; atomic operations; directly updates master database and binary DBs. |
| **`useradd` / `usermod` / `userdel`** | OpenBSD / NetBSD | User lifecycle management | Standard POSIX-style CLI interface; wrapper around shadow DB creation routines. |
| **`vipw` / `vigr`** | All BSDs | Manual interactive modification | Locks `/etc/ptmp` using editor; automatically compiles `/etc/pwd.db` and `/etc/spwd.db` upon save. |
| **`adduser`** | FreeBSD / NetBSD | Interactive creation script | Shell/Perl wrapper intended for manual sysadmin setup; uses `/etc/adduser.conf`. Not suitable for non-interactive automation. |
| **`chpass` / `chfn` / `chsh`** | All BSDs | User metadata modification | Modifies user GECOS, shell, or password; updates `/etc/master.passwd` and regenerates DBs. |

---

## 3. Complete Manifests & Configuration Infrastructures

### 3.1 The 10-Field BSD `/etc/master.passwd` Schema
Unlike the 7-field Linux `/etc/passwd` file, BSD master account files utilize a 10-field colon-separated layout:

```text
name:password:uid:gid:class:change:expire:gecos:homedir:shell
```

#### Field Specification Reference
1. `name`: User login identifier (alphanumeric, case-sensitive, max 32 chars).
2. `password`: Encrypted hash (e.g., `$6$` for SHA-512, `$2b$` for bcrypt, `*` for locked/no-login accounts).
3. `uid`: Numeric User ID (0 for superuser, <1000 for system daemons, ≥1000 for standard users).
4. `gid`: Primary Group ID (maps to `/etc/group`).
5. `class`: Login capability class (defined in `/etc/login.conf`, e.g., `default`, `staff`, `untrusted`).
6. `change`: Password change deadline (UNIX timestamp in seconds; `0` disables mandatory password rotation).
7. `expire`: Account expiration date (UNIX timestamp in seconds; `0` disables account expiration).
8. `gecos`: General information (Full Name, Office, Office Phone, Home Phone).
9. `homedir`: Absolute path to home directory.
10. `shell`: Path to default user shell (must be listed in `/etc/shells`).

#### Syntactically Valid `/etc/master.passwd` Example
```text
root:$6$v19zG9.k$8N3Z.6vUe...:0:0::0:0:System Administrator:/root:/bin/csh
daemon:*:1:1::0:0:Owner of many system processes:/root:/usr/sbin/nologin
operator:*:2:5::0:0:System Site Operator:/usr/share/man:/usr/sbin/nologin
bin:*:3:7::0:0:Binaries Commands and Source:/usr/include:/usr/sbin/nologin
tty:*:4:4::0:0:Tty Arbitrator:/nonexistent:/usr/sbin/nologin
kmem:*:5:5::0:0:KMem Arbitrator:/nonexistent:/usr/sbin/nologin
games:*:7:13::0:0:Games pseudo-user:/nonexistent:/usr/sbin/nologin
news:*:8:8::0:0:News Subsystem:/nonexistent:/usr/sbin/nologin
man:*:9:9::0:0:World Wide Web Owner:/nonexistent:/usr/sbin/nologin
sshd:*:22:22::0:0:SSHD Privilege Separation User:/var/empty:/usr/sbin/nologin
sre_admin:$6$J9kX...$4l0P...:1001:1001:staff:0:0:SRE Platform Lead:/home/sre_admin:/usr/local/bin/zsh
app_runner:$2b$12$K8...:1002:1002:apps:0:1767225600:Application Service Account:/nonexistent:/usr/sbin/nologin
```

---

### 3.2 Production `/etc/login.conf` Capability Matrix
The `/etc/login.conf` file establishes process limit ceilings, environment variable injection, and security rules per capability class.

```text
# /etc/login.conf - Production Hardened Platform Configuration
# Compile changes using: cap_mkdb /etc/login.conf

default:\
	:passwd_format=sha512:\
	:copyright=/etc/COPYRIGHT:\
	:welcome=/etc/motd:\
	:setenv=MAIL=/var/mail/$$,BLOCKSIZE=K:\
	:path=/sbin /bin /usr/sbin /usr/bin /usr/local/sbin /usr/local/bin ~/bin:\
	:nologin=/var/run/nologin:\
	:cputime=unlimited:\
	:datasize=unlimited:\
	:stacksize=unlimited:\
	:memorylocked=64M:\
	:memoryuse=unlimited:\
	:filesize=unlimited:\
	:coredumpsize=0:\
	:openfiles=4096:\
	:maxproc=512:\
	:sbsize=unlimited:\
	:vmemorysize=unlimited:\
	:priority=0:\
	:ignoretime@:\
	:umask=022:

# High-Privilege Engineer Class
staff:\
	:tc=default:\
	:datasize=8G:\
	:openfiles=65536:\
	:maxproc=4096:\
	:coredumpsize=unlimited:\
	:umask=027:

# Application Service Account Class
apps:\
	:tc=default:\
	:requirehome@:\
	:coredumpsize=0:\
	:openfiles=131072:\
	:maxproc=8192:\
	:memorylocked=512M:\
	:umask=007:

# Restricted Multi-Tenant Class
untrusted:\
	:tc=default:\
	:datasize=1G:\
	:openfiles=256:\
	:maxproc=64:\
	:memoryuse=2G:\
	:priority=10:\
	:umask=077:
```

---

### 3.3 Production BSD User & Group Configuration File: `/etc/pw.conf`
The `pw(8)` utility reads `/etc/pw.conf` to enforce default creation policies during automated provisioning.

```text
# /etc/pw.conf - FreeBSD Default Provisioning Configuration File
defaultgroup = 
group = 
defaultattributes = 
defaultshell = /bin/sh
reuseuids = no
reusegids = no
nispass = no
dnspass = no
minuid = 1000
maxuid = 32000
mingid = 1000
maxgid = 32000
home = /home
homemode = 0750
logfile = /var/log/pw.log
skippass = no
sendmail = no
sendmail_file = /etc/adduser.message
mkdir = yes
login_class = default
```

---

### 3.4 Production Provisioning & Idempotent Automation Script
This POSIX-compliant shell script demonstrates enterprise-grade account provisioning, database compilation, and login capability configuration for FreeBSD target infrastructure.

```sh
#!/bin/sh
# System Identity Bootstrap Script for BSD Production Hosts
# Enforces account rules, login capability mapping, and DB synchronization.

set -eu

LOG_FILE="/var/log/sys_identity_provision.log"
exec 3>&1 1>>"${LOG_FILE}" 2>&1

log() {
    echo "[$(date -u +'%Y-%m-%d %H:%M:%SZ')] $*" >&3
    echo "[$(date -u +'%Y-%m-%d %H:%M:%SZ')] $*"
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

# Ensure execution by root
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be executed with superuser privileges."
fi

log "Beginning BSD System Identity Provisioning..."

# 1. Compile login.conf database
if [ -f /etc/login.conf ]; then
    log "Rebuilding /etc/login.conf.db binary database..."
    cap_mkdb /etc/login.conf
fi

# 2. Provision Core Operational Groups
log "Provisioning operational system groups..."
if ! pw show group deployment >/dev/null 2>&1; then
    pw groupadd deployment -g 2001
    log "Created group: deployment (GID 2001)"
fi

if ! pw show group secops >/dev/null 2>&1; then
    pw groupadd secops -g 2002
    log "Created group: secops (GID 2002)"
fi

# 3. Provision SRE Operator User Account
SRE_USER="ops_admin"
SRE_UID="1501"

if ! pw show user "${SRE_USER}" >/dev/null 2>&1; then
    log "Creating operational account ${SRE_USER}..."
    pw useradd "${SRE_USER}" \
        -u "${SRE_UID}" \
        -g deployment \
        -G wheel,secops \
        -c "Senior SRE Operator" \
        -d "/home/${SRE_USER}" \
        -m \
        -s /usr/local/bin/bash \
        -L staff
    
    # Lock password until initial SSH key deployment
    pw lock "${SRE_USER}"
    log "Account ${SRE_USER} provisioned and locked pending credential setup."
else
    log "Updating existing account ${SRE_USER} configuration..."
    pw usermod "${SRE_USER}" \
        -G wheel,secops \
        -L staff \
        -s /usr/local/bin/bash
fi

# 4. Enforce Strict Home Directory Permissions
log "Enforcing ACL/permission boundaries on home directories..."
chmod 0750 "/home/${SRE_USER}"
chown "${SRE_USER}:deployment" "/home/${SRE_USER}"

# 5. Explicitly Trigger Database Consistency Synchronization
log "Executing master database synchronization verify check..."
pwd_mkdb -c /etc/master.passwd

log "System identity provisioning successfully finished."
```

---

## 4. Real CLI Commands & Expected Terminal Outputs

### 4.1 Creating System Groups and Adding Users with `pw` (FreeBSD)

```syslog
$ sudo pw groupadd platform -g 3000
$ sudo pw show group platform
platform:*:3000:

$ sudo pw useradd devops_lead -u 3001 -g platform -G wheel -c "Platform Team Lead" -d /home/devops_lead -m -s /bin/sh -L staff
$ sudo pw show user devops_lead
devops_lead:*$6$...:3001:3000:staff:0:0:Platform Team Lead:/home/devops_lead:/bin/sh

$ id devops_lead
uid=3001(devops_lead) gid=3000(platform) groups=3000(platform),0(wheel)
```

---

### 4.2 Account Locking and Status Auditing

```syslog
$ sudo pw lock devops_lead
$ sudo pw show user devops_lead
devops_lead:*LOCKED**$6$...:3001:3000:staff:0:0:Platform Team Lead:/home/devops_lead:/bin/sh

$ grep devops_lead /etc/master.passwd
devops_lead:*LOCKED**$6$v19zG9...:3001:3000:staff:0:0:Platform Team Lead:/home/devops_lead:/bin/sh

$ sudo pw unlock devops_lead
$ sudo pw show user devops_lead
devops_lead:$6$v19zG9...:3001:3000:staff:0:0:Platform Team Lead:/home/devops_lead:/bin/sh
```

---

### 4.3 Interactive Safe Modification with `vipw`
When `vipw` is executed, it opens `/etc/master.passwd` under a temporary file lock (`/etc/ptmp`). Upon exiting the editor, `vipw` validates syntax and automatically calls `pwd_mkdb`.

```syslog
$ sudo vipw
vipw: editing /etc/master.passwd
vipw: rebuilding target database...
vipw: sys db update complete
```

---

### 4.4 Compiling the User and Login Capability Databases

```syslog
$ sudo pwd_mkdb -p -d /etc /etc/master.passwd
$ ls -la /etc/pwd.db /etc/spwd.db /etc/passwd /etc/master.passwd
-rw-r--r--  1 root  wheel   2412 Aug  6 20:10 /etc/master.passwd
-rw-r--r--  1 root  wheel   1854 Aug  6 20:12 /etc/passwd
-rw-r--r--  1 root  wheel  40960 Aug  6 20:12 /etc/pwd.db
-rw-------  1 root  wheel  40960 Aug  6 20:12 /etc/spwd.db

$ sudo cap_mkdb /etc/login.conf
$ ls -la /etc/login.conf.db
-rw-r--r--  1 root  wheel  16384 Aug  6 20:15 /etc/login.conf.db
```

---

### 4.5 Modifying Group Membership with `pw groupmod`

```syslog
$ sudo pw groupmod wheel -m devops_lead,sre_admin
$ sudo pw show group wheel
wheel:*:0:root,devops_lead,sre_admin

$ sudo pw groupmod wheel -d devops_lead
$ sudo pw show group wheel
wheel:*:0:root,sre_admin
```

---

### 4.6 User Account Deletion with Cleanup

```syslog
$ sudo pw userdel devops_lead -r
$ id devops_lead
id: devops_lead: no such user

$ ls -d /home/devops_lead
ls: /home/devops_lead: No such file or directory
```

---

## 5. Verification & Troubleshooting Guide

### 5.1 Common Production Failures & Root Cause Analysis

```
+-------------------------------------------------------+
|                 Symptom Observed                      |
+-------------------------------------------------------+
                           |
                           v
         +-----------------------------------+
         | Is /etc/ptmp lockfile remaining?  |
         +-----------------------------------+
                   /               \
            (Yes) /                 \ (No)
                 v                   v
   +---------------------------+   +------------------------------------+
   | Stale vipw/pw Lockfile    |   | Is database out of sync with text? |
   | Cause: Crashed session    |   +------------------------------------+
   | Fix: Remove /etc/ptmp     |              /             \
   +---------------------------+       (Yes) /               \ (No)
                                            v                 v
                              +--------------------+   +-----------------------+
                              | Corrupted .db file |   | PAM / Login Class     |
                              | Fix: Run pwd_mkdb  |   | Capability Misconfig  |
                              +--------------------+   +-----------------------+
```

---

### 5.2 Diagnostic Scenarios & Step-by-Step Resolution

#### Scenario A: Database Synchronization Mismatch (`/etc/master.passwd` vs `/etc/spwd.db`)
* **Symptom**: User account added manually via text editor or custom tool to `/etc/master.passwd` cannot authenticate via SSH or standard login, or `getent passwd` / `id` commands report "no such user".
* **Root Cause**: The system APIs query `/etc/pwd.db` and `/etc/spwd.db`. Manual edits to `/etc/master.passwd` without executing `pwd_mkdb` leave the binary indexed databases stale.
* **Resolution Protocol**:
  1. Validate `/etc/master.passwd` syntax:
     ```syslog
     $ sudo pwd_mkdb -c /etc/master.passwd
     ```
  2. Force a clean database rebuild:
     ```syslog
     $ sudo pwd_mkdb -p /etc/master.passwd
     ```
  3. Verify lookup functionality:
     ```syslog
     $ id <username>
     ```

---

#### Scenario B: Stale Lockfile Blocking User Management (`/etc/ptmp`)
* **Symptom**: Executing `pw`, `vipw`, or `chpass` returns the following failure:
  ```syslog
  vipw: /etc/ptmp: Resource temporarily unavailable
  pw: cannot open /etc/ptmp: File exists
  ```
* **Root Cause**: A previous execution of `vipw` or `pw` terminated abruptly (e.g., SSH session timeout, SIGKILL), leaving the lockfile `/etc/ptmp` behind to prevent concurrent writes.
* **Resolution Protocol**:
  1. Inspect the PID owning the file or check for active instances:
     ```syslog
     $ sudo fuser /etc/ptmp
     ```
  2. If no process is running, verify lockfile age and remove it:
     ```syslog
     $ ls -l /etc/ptmp
     $ sudo rm -f /etc/ptmp
     ```
  3. Re-run `vipw` to verify normal file locking behavior.

---

#### Scenario C: Non-Privileged Escalation Failure for `su` (`wheel` Group Constraint)
* **Symptom**: A standard user attempting to execute `su -` receives `su: Permission denied` despite providing the correct superuser password.
* **Root Cause**: By default on BSD systems, `su(1)` strictly enforces that only users belonging to the primary or supplementary group `wheel` (GID 0) are authorized to elevate privileges to `root`.
* **Resolution Protocol**:
  1. Check target user membership:
     ```syslog
     $ id <username>
     ```
  2. Append user to `wheel` group using `pw`:
     ```syslog
     $ sudo pw groupmod wheel -m <username>
     ```
  3. Re-test `su -` elevation.

---

#### Scenario D: Resource Exhaustion via Login Class Limits
* **Symptom**: Applications owned by a specific service account fail with `fork: Cannot allocate memory` or `Too many open files`, despite global sysctl values (`kern.maxfiles`, `kern.maxproc`) having sufficient head room.
* **Root Cause**: The user's assigned login class in `/etc/login.conf` has restrictive per-process caps (`openfiles`, `maxproc`, `datasize`).
* **Resolution Protocol**:
  1. Inspect user login class assignment:
     ```syslog
     $ pw show user <username> | cut -d: -f5
     ```
  2. Check capability definitions in `/etc/login.conf`.
  3. Adjust parameters in `/etc/login.conf`, then recompile the capability database:
     ```syslog
     $ sudo cap_mkdb /etc/login.conf
     ```
  4. Have the user log out and log back in to pick up updated class parameters (`login_cap`).

---

## 6. References

* **LPI BSD Specialist Certification Overview**:  
  https://www.lpi.org/our-certifications/bsd-specialist-overview/
* **FreeBSD Handbook: User and Basic Account Management**:  
  https://docs.freebsd.org/en/books/handbook/basics/#users-synopsis
* **FreeBSD Manual Pages - `pw(8)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=pw&sektion=8
* **FreeBSD Manual Pages - `pwd_mkdb(8)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=pwd_mkdb&sektion=8
* **FreeBSD Manual Pages - `login.conf(5)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=login.conf&sektion=5
* **OpenBSD Manual Pages - `useradd(8)`**:  
  https://man.openbsd.org/useradd.8
* **OpenBSD Manual Pages - `vipw(8)`**:  
  https://man.openbsd.org/vipw.8