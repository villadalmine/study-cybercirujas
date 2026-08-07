# LPI-702 Study Guide: Topic 712.4 – Manage File Permissions and Ownership

**Exam:** BSD Specialist (Exam 702-100, Version 1.0)  
**Topic 712:** Storage Devices and BSD Filesystems  
**Subtopic 712.4:** Manage File Permissions and Ownership  
**Weight:** 5  

---

## 1. Architectural Motivation and Production Problem

In multi-tenant BSD enterprise environments—such as infrastructure running FreeBSD Jails, OpenBSD edge routers, or ZFS-backed high-density storage nodes—file security enforcement occurs across multiple kernel subsystems:
1. Standard Discretionary Access Control (DAC) permission bits (POSIX `rwx`, SUID, SGID, Sticky Bit).
2. Process execution mode masks (`umask`).
3. BSD-specific Kernel File Flags (`chflags` like `schg`, `uchg`, `sappnd`).
4. Granular Access Control Lists (NFSv4 and POSIX.1e ACLs on ZFS and UFS2).

### The Production Incident Scenario
Consider a high-concurrency production payment gateway running inside a FreeBSD Jail with a ZFS storage pool (`tank/jail/gateway`). A compromise of an unprivileged daemon process (`www` user) attempts to alter binary dependencies (`/usr/local/bin/gateway-daemon`) and write malware into a shared temporary socket directory (`/var/run/app-sockets`).

If permissions are misconfigured:
* **Standard DAC Failure:** Standard `0755` permissions allow `root` processes inside an unprivileged jail to mutate shared binaries if jail root mapping is mismanaged, or allow users sharing a group to overwrite critical configuration.
* **Lack of Immutability:** standard `chmod` and `chown` settings allow even benign administrative errors (e.g., an errant `rm -rf /` or malicious `payload` injection by compromised root inside container/jail) to overwrite static binaries and system configuration.
* **Coarse Access Control:** POSIX `u/g/o` bits force engineers to choose between overly open permissions (`0777`) or bloated group management when sharing log directories between audit agents, web servers, and database workers.

### Architectural Solution
To achieve zero-trust filesystem isolation and immutable system integrity, Platform Architects design a layered access defense using BSD primitives:
* **Kernel Immutability (`schg` / `uchg`):** Protect binaries against unauthorized modification even by the `root` superuser (when running at elevated kernel `securelevel`).
* **Append-Only Logging (`sappnd` / `uappnd`):** Force audit and application logs to be append-only, preventing log tampering during post-exploitation analysis.
* **Set Group ID (SGID) & Sticky Bits:** Enforce group inheritance on directories while preventing multi-tenant file deletion within shared scratch spaces.
* **NFSv4 ACL Inheritance:** Override crude POSIX mode bits with exact access control entries (ACEs) inherited automatically on ZFS datasets.

```
                     +-------------------------------------------------------+
                     |                 Kernel Access Check                   |
                     +-------------------------------------------------------+
                                                 |
                                                 v
                     +-------------------------------------------------------+
                     |    1. Kernel Securelevel & BSD Flags Check            |
                     |   (e.g., schg, uchg, sappnd via chflags/vnode flags) |
                     +-------------------------------------------------------+
                                                 |
                                            Pass | (Not Blocked)
                                                 v
                     +-------------------------------------------------------+
                     |    2. Access Control Lists (NFSv4 / POSIX.1e ACLs)    |
                     |   (Evaluated before standard Unix mode bits if present) |
                     +-------------------------------------------------------+
                                                 |
                                            Pass | (ACL matched / fallback)
                                                 v
                     +-------------------------------------------------------+
                     |    3. Traditional Discretionary Access Control (DAC)  |
                     |   (UID/GID match against owner/group/other rwx bits)   |
                     +-------------------------------------------------------+
                                                 |
                                            Pass | (Allowed)
                                                 v
                     +-------------------------------------------------------+
                     |           System Call Granted (Read/Write/Exec)       |
                     +-------------------------------------------------------+
```

---

## 2. Technical Comparisons & Trade-off Tables

### Permission Enforcement Models: DAC vs. BSD File Flags vs. NFSv4 ACLs

| Feature / Attribute | Traditional POSIX DAC (`chmod`/`chown`) | BSD File Flags (`chflags`) | NFSv4 ACLs (`setfacl`/`getfacl`) |
| :--- | :--- | :--- | :--- |
| **Granularity** | Single User, Single Group, Others (`u/g/o`) | System-wide / User-wide state bits on Vnode | Arbitrary list of Users, Groups, and Explicit Inheritance Rules |
| **Superuser Override** | `root` (UID 0) bypasses all `rwx` checks | `root` **cannot** override `schg`/`sappnd` if `securelevel > 0` | `root` can modify ACLs, but ACEs strictly enforce non-root boundaries |
| **Storage Metadata Location** | Inode / Vnode standard mode bits (`st_mode`) | Inode / Vnode flag bitmask (`st_flags`) | Extended Attributes / ZFS System Attributes |
| **Performance Overhead** | Negligible (Direct bitmask operation) | Negligible (Bitwise check in kernel VFS) | Low to Moderate (ACL parsing & inheritance evaluation on creation) |
| **Primary Use Case** | Baseline Unix service execution & ownership | Ransomware defense, system binary immutability, tamper-proof logging | Complex enterprise multi-tenant directory sharing |
| **Portability** | Universal POSIX standard | BSD Specific (FreeBSD, OpenBSD, NetBSD, macOS) | ZFS / NFSv4 standard (FreeBSD ZFS, Linux NFSv4) |

### Special Permission Bits in BSD

| Bit Name | Numeric Octal | File Behavior | Directory Behavior | Security Risk / Implication |
| :--- | :--- | :--- | :--- | :--- |
| **SUID** (Set-User-ID) | `4000` | Process executes with privileges of the file **owner** (e.g., `root`). | No effect on standard BSD systems. | **High:** Risk of privilege escalation if binary contains execution bugs. |
| **SGID** (Set-Group-ID) | `2000` | Process executes with privileges of the file **group**. | Newly created sub-files/directories inherit parent directory's **GID**. | **Medium:** Unintended file access if directory group ownership is loose. |
| **Sticky Bit** | `1000` | Text segment caching (obsolete legacy BSD behavior). | Only file **owner** or `root` can rename/delete files inside directory. | **Low:** Mandatory for shared temporary directories like `/tmp` and `/var/tmp`. |

---

## 3. Complete Infrastructure & System Configuration Manifests

### 1. FreeBSD System Hardening Script: `/usr/local/sbin/harden-platform.sh`
This shell script configures system-wide process masks (`umask`), restricts directory inheritance via kernel variables, applies system-level flags to base utilities, and provisions a secured multi-tenant workspace with NFSv4 ACLs on ZFS.

```sh
#!/bin/sh
# System-wide Security and Permission Enforcement Script for BSD Environments
# Target OS: FreeBSD 13+ / 14+ on ZFS

set -euo pipefail

LOG_FILE="/var/log/sys_hardening.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "[+] Starting Enterprise BSD File System Hardening..."

# 1. Enforce strict system default process creation umask in login.conf
echo "[+] Updating default umask in /etc/login.conf..."
cap_mkdb /etc/login.conf

# 2. Configure kernel sysctl settings for permission safety
echo "[+] Configuring sysctl security knobs..."
sysctl security.bsd.see_other_uids=0
sysctl security.bsd.see_other_gids=0
sysctl security.bsd.hardlink_check_uid=1
sysctl security.bsd.hardlink_check_gid=1
sysctl security.bsd.unprivileged_proc_debug=0

cat << 'EOF' >> /etc/sysctl.conf
# Managed by Platform Automation - Hardened Kernel Parameters
security.bsd.see_other_uids=0
security.bsd.see_other_gids=0
security.bsd.hardlink_check_uid=1
security.bsd.hardlink_check_gid=1
security.bsd.unprivileged_proc_debug=0
EOF

# 3. Create Multi-tenant Application Storage with ZFS ACL Properties
DATASET="tank/appdata"
MOUNTPOINT="/var/appdata"

if ! zfs list "${DATASET}" >/dev/null 2>&1; then
    echo "[+] Creating ZFS Dataset ${DATASET} with strict NFSv4 ACL mode..."
    zfs create -o mountpoint="${MOUNTPOINT}" \
               -o aclmode=restricted \
               -o acltype=nfsv4 \
               "${DATASET}"
fi

# 4. Set Directory Structure and Special DAC Bits
echo "[+] Provisioning base application hierarchy..."
mkdir -p "${MOUNTPOINT}/shared_bin"
mkdir -p "${MOUNTPOINT}/shared_logs"
mkdir -p "${MOUNTPOINT}/incoming_data"

# Standard ownership setup
chown -R root:wheel "${MOUNTPOINT}"
chown -R root:www "${MOUNTPOINT}/shared_bin"
chown -R root:audit "${MOUNTPOINT}/shared_logs"
chown -R root:dataops "${MOUNTPOINT}/incoming_data"

# Apply standard DAC permissions
chmod 0755 "${MOUNTPOINT}"
chmod 0750 "${MOUNTPOINT}/shared_bin"
chmod 02770 "${MOUNTPOINT}/shared_logs"   # SGID set: force group inheritance
chmod 01777 "${MOUNTPOINT}/incoming_data" # Sticky bit set: prevent user file deletion

# 5. Apply BSD File Flags for Immutability and Append-Only Logging
echo "[+] Applying BSD Kernel Flags..."
# Protect core binaries from modification (System Immutable)
chflags schg /sbin/init /usr/bin/login /usr/bin/su /usr/bin/passwd

# Make log files in shared_logs append-only
touch "${MOUNTPOINT}/shared_logs/audit.log"
chown root:audit "${MOUNTPOINT}/shared_logs/audit.log"
chmod 0640 "${MOUNTPOINT}/shared_logs/audit.log"
chflags sappnd "${MOUNTPOINT}/shared_logs/audit.log"

# 6. Apply NFSv4 ACLs for Granular Operations
echo "[+] Configuring fine-grained NFSv4 ACEs..."
setfacl -s "owner@:rwaWCoDdaARWcCos:fd:allow,group@:rwaWdE:fd:allow,everyone@:r:fd:allow" "${MOUNTPOINT}/incoming_data"

echo "[+] Hardening complete. System state verified."
```

### 2. FreeBSD Jail Infrastructure Blueprint: `/etc/jail.conf`
Defines isolated filesystem roots, securing permission boundaries across jails.

```etc
# /etc/jail.conf - Production Multi-tenant Jail Configuration
# Enforces system level security boundaries and mount restrictions

exec.start = "/bin/sh /etc/rc";
exec.stop = "/bin/sh /etc/rc.shutdown";
exec.clean;
mount.devfs;
devfs_ruleset = "4";

# System-wide resource parameters
path = "/usr/jails/${name}";
host.hostname = "${name}.internal.net";

# Security level enforcement inside jails
securelevel = "2";

gateway_prod {
    vnet;
    vnet.interface = "epair0b";
    mount.fstab = "/etc/fstab.gateway_prod";
    exec.created = "zfs mount tank/jails/gateway_prod";
    exec.poststop = "zfs unmount tank/jails/gateway_prod";
}
```

### 3. Ansible Automation Task Suite: `manage_bsd_permissions.yml`
Automates permission management, flags, and umask enforcement across a FreeBSD cluster.

```yaml
---
- name: Harden BSD System Permissions, Flags, and ACLs
  hosts: bsd_servers
  gather_facts: true
  tasks:

    - name: Ensure target application groups exist
      ansible.builtin.group:
        name: "{{ item }}"
        state: present
      loop:
        - audit
        - dataops
        - secops

    - name: Set target directory DAC permissions and ownership
      ansible.builtin.file:
        path: /var/secure_app
        state: directory
        owner: root
        group: secops
        mode: '02750'

    - name: Set BSD System Immutable flag on core system configuration
      community.general.bsd_flags:
        path: /etc/master.passwd
        flags: schg
        state: present

    - name: Ensure log directory files have append-only flags set
      community.general.bsd_flags:
        path: /var/log/security
        flags: sappnd
        state: present

    - name: Configure system default umask in /etc/profile
      ansible.builtin.lineinfile:
        path: /etc/profile
        regexp: '^umask'
        line: 'umask 027'
        state: present
```

---

## 4. Real CLI Commands & Terminal Execution Logs

### 1. Diagnostic Listing of Files with BSD Flags (`ls -lo` and `stat`)
Standard `ls -l` does not expose BSD file flags. The `-o` flag is required.

```syslog
$ ls -lo /var/appdata/shared_logs/
total 4
-rw-r-----  1 root  audit  sappnd 1024 Aug  6 20:15 audit.log
drwxrws---  2 root  audit  -         512 Aug  6 20:15 archive

$ ls -lo /sbin/init /usr/bin/su
-r-xr-xr-x  1 root  wheel  schg 948320 Jun 22 14:02 /sbin/init
-r-sr-xr-x  1 root  wheel  schg  54120 Jun 22 14:02 /usr/bin/su

$ stat -f "File: %N | Octal Mode: %Lp | Mode String: %Sp | Owner: %Su (%u) | Group: %Sg (%g) | Flags: %SH" /var/appdata/shared_logs/audit.log
File: /var/appdata/shared_logs/audit.log | Octal Mode: 640 | Mode String: -rw-r----- | Owner: root (0) | Group: audit (1002) | Flags: sappnd
```

### 2. Modifying Mode Bits via Octal and Symbolic Modes (`chmod`)

```syslog
# Grant group execute, remove all permissions from others using symbolic syntax
$ chmod g+x,o-rwx /var/appdata/shared_bin/gateway-daemon

# Verify symbolic update
$ ls -l /var/appdata/shared_bin/gateway-daemon
-rwxr-x---  1 root  www  45088 Aug  6 20:20 /var/appdata/shared_bin/gateway-daemon

# Apply octal mode setting SUID and SGID simultaneously (6750 = SUID 4000 + SGID 2000 + 0750)
$ chmod 6750 /usr/local/bin/custom-auth-helper
$ ls -l /usr/local/bin/custom-auth-helper
-rwsr-s---  1 root  secops  18432 Aug  6 20:21 /usr/local/bin/custom-auth-helper
```

### 3. Setting and Clearing BSD File Flags (`chflags`)

```syslog
# Attempt to modify an append-only file using standard user redirection (Fails)
$ echo "Unauthorized entry" >> /var/appdata/shared_logs/audit.log
sh: /var/appdata/shared_logs/audit.log: Operation not permitted

# Attempt to remove a system immutable file as root (Fails when securelevel >= 1)
$ syslog-ng --test
$ rm -f /sbin/init
rm: /sbin/init: Operation not permitted

# Unset user immutable flag (uchg) on user owned data
$ chflags nouchg /home/deploy/release.tar.gz
$ ls -lo /home/deploy/release.tar.gz
-rw-r--r--  1 deploy  deploy  - 5242880 Aug  6 20:22 /home/deploy/release.tar.gz

# Set user append-only flag (uappnd)
$ chflags uappnd /home/deploy/app.log
$ ls -lo /home/deploy/app.log
-rw-r--r--  1 deploy  deploy  uappnd 4096 Aug  6 20:23 /home/deploy/app.log
```

### 4. Evaluating Process Creation Masks (`umask`)

```syslog
# Check current shell umask
$ umask
0022

# Test file creation under default umask (0022)
$ touch /tmp/test_default.txt
$ ls -l /tmp/test_default.txt
-rw-r--r--  1 deploy  deploy  0 Aug  6 20:25 /tmp/test_default.txt

# Set restrictive umask for secure operations (0077: no permissions for group/others)
$ umask 0077
$ umask -S
u=rwx,g=,o=

# Test file and directory creation under secure umask
$ touch /tmp/test_secure.txt
$ mkdir /tmp/test_dir
$ ls -ld /tmp/test_secure.txt /tmp/test_dir
drwx------  2 deploy  deploy  512 Aug  6 20:26 /tmp/test_dir
-rw-------  1 deploy  deploy    0 Aug  6 20:26 /tmp/test_secure.txt
```

### 5. Managing NFSv4 Access Control Lists (`getfacl` / `setfacl`)

```syslog
# Read default NFSv4 ACL on ZFS dataset
$ getfacl /var/appdata/incoming_data
# file: /var/appdata/incoming_data
# owner: root
# group: dataops
            owner@:rwaWCoDdaARWcCos:fd----:allow
            group@:rwaWdE----------:fd----:allow
         everyone@:r-------------:fd----:allow

# Add explicit entry granting user 'secmod' full read/write/delete permissions
$ setfacl -m u:secmod:rw-pDdaARWcCos:fd----:allow /var/appdata/incoming_data

# Read modified ACLs
$ getfacl /var/appdata/incoming_data
# file: /var/appdata/incoming_data
# owner: root
# group: dataops
         user:secmod:rwaWCoDdaARWcCos:fd----:allow
            owner@:rwaWCoDdaARWcCos:fd----:allow
            group@:rwaWdE----------:fd----:allow
         everyone@:r-------------:fd----:allow

# Remove explicit user ACE
$ setfacl -x u:secmod:rw-pDdaARWcCos:fd----:allow /var/appdata/incoming_data
```

---

## 5. Troubleshooting & Verification Guide

### Diagnostic Flowchart for File Access Denials

```
                   [ Operation Fails: "Operation not permitted" or "Permission denied" ]
                                                 |
                                                 v
                                  Check Kernel Securelevel:
                                  `sysctl kern.securelevel`
                                                 |
                       +-------------------------+-------------------------+
                       |                                                   |
             securelevel >= 1                                    securelevel <= 0
                       |                                                   |
                       v                                                   v
       Check system flags: `ls -lo`                        Check traditional user/group permissions
       Are `schg` or `sappnd` active?                      Is current UID == File Owner?
                       |                                                   |
           +-----------+-----------+                           +-----------+-----------+
           |                       |                           |                       |
          YES                      NO                         YES                      NO
           |                       |                           |                       |
     MUST reboot into       Check user flags:            Verify exact mode     Check Group Membership
     Single-User mode       `uchg` / `uappnd`            bits (`chmod`) and    `id -Gn <user>` & ACLs
     to clear flags.        `chflags nouchg <file>`      umask settings.       `getfacl <file>`
```

### Common Production Scenarios & Root Cause Analysis

#### Scenario A: Root user gets "Operation not permitted" (EPERM) when trying to delete or edit a configuration file.
* **Symptom:** `rm -f /etc/resolv.conf` executed as `root` returns `rm: /etc/resolv.conf: Operation not permitted`.
* **Root Cause:** The file has the System Immutable (`schg`) flag set, and the kernel `kern.securelevel` is currently set to `1` or `2`.
* **Diagnostic Verification:**
  ```syslog
  $ sysctl kern.securelevel
  kern.securelevel: 1
  $ ls -lo /etc/resolv.conf
  -rw-r--r--  1 root  wheel  schg 148 Aug  6 19:40 /etc/resolv.conf
  ```
* **Remediation:** If `securelevel > 0`, system flags cannot be cleared even by root while running multi-user mode. The administrator must reboot into single-user mode, lower securelevel, execute `chflags noschg /etc/resolv.conf`, modify the file, and reboot.

#### Scenario B: Group member cannot write to a directory despite directory having `0770` permissions.
* **Symptom:** User `alice` is in group `dataops`. Directory `/var/data` has mode `0770` (`drwxrwx--- root dataops`). `alice` executes `touch /var/data/file.txt` and receives `Permission denied`.
* **Root Cause 1:** The user's dynamic login shell session has not refreshed its supplementary group vector.
* **Root Cause 2:** An extended ACL entry or ACL mask restricts write capabilities.
* **Diagnostic Verification:**
  ```syslog
  # Step 1: Verify current session credentials
  $ id
  uid=1001(alice) gid=1001(alice) groups=1001(alice) # Notice 'dataops' is missing!

  # Step 2: If group is present, inspect ACL mask on ZFS
  $ getfacl /var/data
  # file: /var/data
  # owner: root
  # group: dataops
  mask::r-x
  ```
* **Remediation:** If missing from current session groups, run `exec su - ${USER}` or re-authenticate. If an ACL mask limits permissions, execute `setfacl -m mask::rwx /var/data`.

#### Scenario C: Newly created files in a shared directory do not inherit group ownership, causing broken service workflows.
* **Symptom:** User `bob` creates `/var/appdata/shared_logs/app.log`. The file is created with primary group `bob` instead of `audit`. Other `audit` members cannot read it.
* **Root Cause:** The parent directory `/var/appdata/shared_logs` lacks the Set-Group-ID (SGID) bit (`2000`).
* **Diagnostic Verification:**
  ```syslog
  $ ls -ld /var/appdata/shared_logs
  drwxrwxr-x  2 root  audit  512 Aug  6 20:10 /var/appdata/shared_logs
  ```
* **Remediation:** Apply the SGID bit to the directory:
  ```syslog
  $ chmod g+s /var/appdata/shared_logs
  $ ls -ld /var/appdata/shared_logs
  drwxrwsr-x  2 root  audit  512 Aug  6 20:30 /var/appdata/shared_logs
  ```

### Audit Command Cheat Sheet for SRE Security Audits

```syslog
# 1. Audit all SUID binaries across the filesystem
$ find / -type f -perm -4000 -exec ls -ld {} + 2>/dev/null

# 2. Audit all SGID binaries
$ find / -type f -perm -2000 -exec ls -ld {} + 2>/dev/null

# 3. Find world-writable files excluding symlinks and sockets
$ find / -type f -perm -0002 ! -type l -exec ls -lo {} + 2>/dev/null

# 4. Find all files with active BSD system flags (schg, uchg, sappnd, uappnd)
$ find / -flags +schg,uchg,sappnd,uappnd -exec ls -ldo {} + 2>/dev/null

# 5. Audit directories missing the sticky bit under /tmp or /var
$ find /var/tmp /tmp -type d ! -perm -1000 -exec ls -ld {} +
```

---

## 6. References

* **LPI BSD Specialist Certification Overview:**  
  [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
* **FreeBSD Manual Pages – `chmod(1)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=chmod&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=chmod&sektion=1)
* **FreeBSD Manual Pages – `chflags(1)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=chflags&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=chflags&sektion=1)
* **FreeBSD Manual Pages – `chown(1)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=chown&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=chown&sektion=1)
* **FreeBSD Manual Pages – `setfacl(1)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=setfacl&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=setfacl&sektion=1)
* **FreeBSD Manual Pages – `getfacl(1)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=getfacl&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=getfacl&sektion=1)
* **FreeBSD Manual Pages – `umask(2)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=umask&sektion=2](https://man.freebsd.org/cgi/man.cgi?query=umask&sektion=2)
* **FreeBSD Handbook – Security Chapter:**  
  [https://docs.freebsd.org/en/books/handbook/security/](https://docs.freebsd.org/en/books/handbook/security/)