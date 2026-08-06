# LPIC-3 Security (Exam 303-300, v3.0) — Topic 333: Access Control
**Exam Weight:** 10 out of 60 (16.67% total exam coverage)  
**Target Audience:** Senior SREs, Platform Architects, Security Engineers

---

## 1. Production Architectural Motivation & Problem Statement

In enterprise Linux platforms, workloads rarely run in isolation. Modern infrastructures host multi-tenant microservices, container runtimes (`containerd`, `CRI-O`, `Podman`), stateful databases, and automation agents on shared Linux kernels. 

### The Fundamental Flaw of Standard UNIX DAC
Traditional Linux **Discretionary Access Control (DAC)** relies on a tri-part permission model (Owner, Group, Other) attached directly to the file inode (`rwxrwxrwx`). This model suffers from severe architectural limitations in production:

1. **coarse-Grained Authorization:** A process running as user `www-data` needs read access to `/var/www/html` and write access to `/var/log/nginx/`. If another daemon (e.g., a metrics exporter) requires read access to `/var/log/nginx/`, it must either be added to the `www-data` group (granting it access to web root files as well) or the logs must be made world-readable (`o+r`), violating the Principle of Least Privilege (PoLP).
2. **Ambient Authority & Privilege Escalation:** Under DAC, a process inherits **all** privileges of the executing user. If `nginx` runs as `root` (to bind to port 80) and suffers a Remote Code Execution (RCE) via a buffer overflow, the attacker gains unconstrained root access to the entire operating system, bypasses DAC entirely, and can access `/etc/shadow`, insert kernel modules, or wipe block devices.
3. **No Protection Against Malicious/Compromised Owners:** The file owner can modify file permissions at will (`chmod 777`). DAC cannot restrict a user or application process from exposing its own data to untrusted users.

```
                   +------------------------------------------+
                   |           User Space Process             |
                   |      (e.g., compromised web app)         |
                   +------------------------------------------+
                                        |
                                        v
                   +------------------------------------------+
                   |    Virtual File System (VFS) Layer       |
                   +------------------------------------------+
                                        |
                  +---------------------+---------------------+
                  |                                           |
                  v                                           v
       +--------------------+                      +--------------------+
       |  DAC Check (VFS)   |                      |  LSM Framework     |
       | Inode Mode Bits /  |                      | Hook:              |
       | POSIX Extended ACL |                      | security_file_open |
       +--------------------+                      +--------------------+
                  |                                           |
           (Pass: User/Group)                          (Pass: Policy)
                  |                                           |
                  +---------------------+---------------------+
                                        |
                                        v
                   +------------------------------------------+
                   |       Underlying Filesystem (ext4/xfs)   |
                   +------------------------------------------+
```

### The Kernel Solution: LSM Hooks and Mandatory Access Control
To mitigate DAC deficiencies, the Linux kernel provides the **Linux Security Modules (LSM)** framework. LSM places mediation hooks at key security-critical points within kernel data structures (such as inode lookup, file opening, socket creation, task transitions, and IPC).

* **POSIX ACLs (Extended DAC):** Extends standard file bits to grant granular permissions per-user (`u:alice:r--`) and per-group (`g:devs:rw-`) using kernel extended attributes (`xattr`).
* **Extended Attributes (`xattr`):** Enables metadata tagging directly on filesystem inodes across four distinct namespaces (`user`, `trusted`, `security`, `system`).
* **Mandatory Access Control (MAC):** Overrides DAC decisions by enforcing system-wide security policies defined by a central administrator. Even if a process runs as `root` (`uid=0`), the kernel LSM enforces constraints:
  * **SELinux (Type Enforcement & MCS/MLS):** Label-based MAC system. Checks labels attached to processes (subjects) and objects (files, sockets, ports, IPC) against a compiled binary policy.
  * **AppArmor (Path-Based Enforcement):** Path-name based MAC system. Restricts individual programs using human-readable profiles bound to binary execution paths.

---

## 2. Technical Comparison & Architectural Trade-off Matrices

### 2.1 Access Control Paradigms Matrix

| Feature / Dimension | Standard UNIX DAC | POSIX Extended ACLs | File Extended Attributes (`xattr`) | SELinux (MAC) | AppArmor (MAC) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Enforcement Mechanism** | VFS Kernel Inode Mode Bits | Extended VFS Inode Evaluation | Inode Metadata Key-Value Storage | LSM Hooks via Type Enforcement / Labels | LSM Hooks via Canonical Path Matching |
| **Granularity** | User, Group, World (3 buckets) | Multiple explicit Users & Groups per file | Metadata storage (up to 64KB per inode) | Object/Subject context-based (`u:r:t:s0`) | Binary Path-based (`/usr/bin/nginx`) |
| **Root Bypassing?** | No (Root bypasses all DAC) | No (Root bypasses all DAC) | Partial (Only `CAP_SYS_ADMIN` modifies `security`/`trusted`) | **Yes** (Root confined by policy rules) | **Yes** (Root confined by profile rules) |
| **Storage Location** | Inode standard fields | `system.posix_acl_access` extended attribute | On-disk Extended Attribute blocks | `security.selinux` extended attribute | Loaded into Kernel RAM (Profile table) |
| **Default Stance** | Open / Discretionary | Open / Discretionary | Metadata storage only | Default Deny (Implicit deny all unless allowed) | Default Deny (for profiled binaries) |
| **Performance Impact** | Minimal (Direct Bitwise Operations) | Low (Extra inode xattr lookup) | Low (xattr lookup depending on block alignment) | Low-Medium (AVC cache hits ~1-2%, cache miss lookup) | Low-Medium (Path resolution & string regex evaluation) |
| **Management Tools** | `chmod`, `chown`, `umask` | `getfacl`, `setfacl` | `getfattr`, `setfattr`, `lsattr`, `chattr` | `semanage`, `restorecon`, `audit2allow`, `setsebool` | `aa-status`, `apparmor_parser`, `aa-complain`, `aa-enforce` |

### 2.2 SELinux vs. AppArmor Architectural Comparison

```
+---------------------------------------------------------------------------------------------------+
| Feature               | SELinux                                 | AppArmor                        |
+-----------------------+-----------------------------------------+---------------------------------+
| Binding Mechanism     | Security Labels (Stored in xattr)       | Absolute Path Names             |
| File Rename Traversal | Immune (Label tied to Inode)            | Sensitive (New path needs rule) |
| Policy Complexity     | High (Requires TE, Rules, Interfaces)   | Low (Human readable profiles)   |
| Multi-Category (MCS)  | Supported (Container isolation: `s0:c1`)| Limited / Not natively label-based |
| Default Distribution  | RHEL, Fedora, Rocky Linux, AlmaLinux    | Ubuntu, Debian, SUSE Linux      |
+---------------------------------------------------------------------------------------------------+
```

---

## 3. Production Manifests & Complete Infrastructure Configurations

### 3.1 Custom SELinux Type Enforcement Policy Module
The following policy module defines a targeted security context for a enterprise API microservice running under a non-standard port (`8443`) and accessing dedicated persistent storage (`/var/data/api`).

#### File: `custom_microservice.te` (Type Enforcement Source File)
```te
policy_module(custom_microservice, 1.0.0)

gen_require(`
    type unconfined_t;
    type httpd_config_t;
    type node_t;
    type cert_t;
    class file { read getattr open map write create unlink rename };
    class dir { read search getattr open write add_name remove_name };
    class tcp_socket { name_bind name_connect node_bind };
')

# Declarations of custom security types
type custom_api_t;
type custom_api_exec_t;
type custom_api_data_t;
type custom_api_log_t;
type custom_api_port_t;

# Define target process as a domain transition destination
init_daemon_domain(custom_api_t, custom_api_exec_t)

# Define port and object types
files_type(custom_api_data_t)
logging_log_file(custom_api_log_t)
corenetwork_port(custom_api_port_t)

# Allow domain transition when unconfined_t or init script executes custom_api_exec_t
domain_auto_trans(unconfined_t, custom_api_exec_t, custom_api_t)

# File and Directory Rules for Process Domain (custom_api_t)
allow custom_api_t custom_api_data_t:dir { read search getattr open write add_name remove_name };
allow custom_api_t custom_api_data_t:file { read getattr open map write create unlink rename };

allow custom_api_t custom_api_log_t:dir { read search getattr open write add_name };
allow custom_api_t custom_api_log_t:file { create open append getattr setattr write };

# Allow reading SSL/TLS Certificates from system store
allow custom_api_t cert_t:dir { read search getattr open };
allow custom_api_t cert_t:file { read getattr open };

# Network Access Rules
allow custom_api_t custom_api_port_t:tcp_socket { name_bind name_connect };
allow custom_api_t node_t:tcp_socket node_bind;

# System access logging interface
sysnet_dns_name_resolve(custom_api_t)
```

#### File: `custom_microservice.fc` (File Context Definition File)
```fc
/usr/local/bin/custom_api_server        --  gen_context(system_u:object_r:custom_api_exec_t,s0)
/var/data/api(/.*)?                         gen_context(system_u:object_r:custom_api_data_t,s0)
/var/log/custom_api(/.*)?                   gen_context(system_u:object_r:custom_api_log_t,s0)
```

---

### 3.2 Production-Grade AppArmor Profile
This complete, syntactically valid AppArmor profile confines a production NGINX reverse proxy instance, enforcing path permissions, network capability restrictions, and preventing execution of unapproved binaries.

#### File: `/etc/apparmor.d/usr.sbin.nginx`
```apparmor
#include <tunables/global>

profile nginx /usr/sbin/nginx flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>
  #include <abstractions/nameservice>
  #include <abstractions/openssl>

  # Network Capabilities
  capability net_bind_service,
  capability setuid,
  capability setgid,
  capability chown,
  capability dac_override,
  capability sys_resource,

  # Deny raw sockets and dangerous capabilities explicitly
  deny capability sys_admin,
  deny capability sys_module,
  deny capability rawio,

  # Executable File Rules
  /usr/sbin/nginx mr,

  # Configuration File Access
  /etc/nginx/ r,
  /etc/nginx/** r,
  /etc/ssl/certs/ r,
  /etc/ssl/certs/** r,
  /etc/pki/tls/certs/ r,
  /etc/pki/tls/certs/** r,

  # Dynamic Libraries
  /usr/lib{,32,64}/** mr,
  /lib{,32,64}/** mr,

  # Process and System Information Files
  /proc/sys/kernel/ngroups_max r,
  /proc/cpuinfo r,
  /sys/devices/system/cpu/ r,
  /sys/devices/system/cpu/** r,

  # Logging and Pid Files
  /var/log/nginx/ r,
  /var/log/nginx/* w,
  /var/log/nginx/** rw,
  /run/nginx.pid rw,
  /run/nginx.pid.* rw,

  # Web Root Data Directories
  /usr/share/nginx/html/ r,
  /usr/share/nginx/html/** r,
  /var/www/html/ r,
  /var/www/html/** r,

  # Temporary Directories for Buffer Files
  /var/lib/nginx/ rw,
  /var/lib/nginx/** rw,
  /tmp/nginx_* rw,
  /tmp/nginx_*/** rw,

  # Explicit Deny for Executables inside Web Root
  deny /var/www/html/**/*.sh x,
  deny /var/www/html/**/*.py x,
  deny /var/www/html/**/*.php x,

  # Signal Handling
  signal (receive, send) set=(term, int, quit, hup, usr1, usr2) peer=nginx,
}
```

---

### 3.3 POSIX Extended ACL Directory Blueprint & Systemd Automation
The following Systemd service manifest configures an enterprise directory structure with fine-grained POSIX default ACL inheritance for multi-department collaboration (`devops` and `secops`).

#### File: `/etc/systemd/system/configure-secure-acl.service`
```ini
[Unit]
Description=Configure Enterprise POSIX Extended ACLs and Filesystem Attributes
After=local-fs.target
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/setup-acls.sh

[Install]
WantedBy=multi-user.target
```

#### File: `/usr/local/bin/setup-acls.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="/srv/engineering/shared"

# Create target directories
mkdir -p "${TARGET_DIR}"

# Reset existing ACLs and permissions
chmod 2770 "${TARGET_DIR}"
chown root:devops "${TARGET_DIR}"

# Clear existing ACLs
setfacl -b -R "${TARGET_DIR}"

# Apply Base ACLs
# Grant read/write/execute to devops group
setfacl -m g:devops:rwx "${TARGET_DIR}"
# Grant read-only access to secops group
setfacl -m g:secops:r-x "${TARGET_DIR}"
# Grant explicit read/write access to automated build user
setfacl -m u:ci-builder:rwx "${TARGET_DIR}"

# Set the Mask to prevent accidental permission truncation
setfacl -m m:rwx "${TARGET_DIR}"

# Apply Default ACLs for automatic inheritance on new files/subdirectories
setfacl -d -m g:devops:rwx "${TARGET_DIR}"
setfacl -d -m g:secops:r-x "${TARGET_DIR}"
setfacl -d -m u:ci-builder:rwx "${TARGET_DIR}"
setfacl -d -m m:rwx "${TARGET_DIR}"
setfacl -d -m o::--- "${TARGET_DIR}"

# Set Immutable Extended Attribute on critical policy lock file
touch "${TARGET_DIR}/POLICY.lock"
chattr +i "${TARGET_DIR}/POLICY.lock"
```

---

## 4. Execution Commands & Real Terminal Output Sessions

### 4.1 POSIX ACLs and Mask Evaluation Mechanics

```console
$ # Inspect initial directory permissions and ACLs
$ getfacl /srv/engineering/shared
# file: srv/engineering/shared
# owner: root
# group: devops
# flags: s--
user::rwx
group::rwx
group:secops:r-x
user:ci-builder:rwx
mask::rwx
other::---
default:user::rwx
default:group::rwx
default:group:secops:r-x
default:user:ci-builder:rwx
default:mask::rwx
default:other::---

$ # Modify the ACL mask to restrict all named users and groups to read-only
$ setfacl -m m:r-- /srv/engineering/shared

$ # Verify mask recalculation effect on effective permissions
$ getfacl /srv/engineering/shared
# file: srv/engineering/shared
# owner: root
# group: devops
# flags: s--
user::rwx
group::rwx			#effective:r--
group:secops:r-x		#effective:r--
user:ci-builder:rwx		#effective:r--
mask::r--
other::---

$ # Demonstrate impact of chmod on ACL mask
$ chmod g=rx /srv/engineering/shared
$ getfacl /srv/engineering/shared | grep mask
mask::r-x
```

---

### 4.2 Linux Extended Attributes (`xattr`) and File Attributes

```console
$ # Setting user-defined extended attributes
$ setfattr -n user.checksum -v "e3b0c44298fc1c149afbf4c8996fb924" /srv/engineering/shared/build.tar.gz
$ getfattr -d /srv/engineering/shared/build.tar.gz
# file: srv/engineering/shared/build.tar.gz
user.checksum="e3b0c44298fc1c149afbf4c8996fb924"

$ # Display security extended attribute used by SELinux
$ getfattr -n security.selinux /srv/engineering/shared/build.tar.gz
# file: srv/engineering/shared/build.tar.gz
security.selinux="system_u:object_r:default_t:s0"

$ # Demonstrate file immutability via chattr
$ lsattr /srv/engineering/shared/POLICY.lock
----i---------e---- /srv/engineering/shared/POLICY.lock

$ rm -f /srv/engineering/shared/POLICY.lock
rm: cannot remove '/srv/engineering/shared/POLICY.lock': Operation not permitted

$ # Remove immutable attribute and delete
$ chattr -i /srv/engineering/shared/POLICY.lock
$ rm -f /srv/engineering/shared/POLICY.lock
```

---

### 4.3 SELinux Policy Compilation, Context Mapping, and Booleans

```console
$ # Check current system SELinux status
$ sestatus
SELinux status:                 enabled
SELinuxfs mount:                /sys/fs/selinux
SELinux root directory:         /etc/selinux
Loaded policy name:             targeted
Current mode:                   enforcing
Mode from config file:          enforcing
Policy MLS status:              enabled
Policy deny_unknown status:     allowed
Memory protection checking:     actualized
Max kernel policy version:      33

$ # Compile and insert custom SELinux policy module
$ checkmodule -M -m -o custom_microservice.mod custom_microservice.te
checkmodule:  loading policy configuration from custom_microservice.te
checkmodule:  policy configuration loaded
checkmodule:  writing binary representation (version 19) to custom_microservice.mod

$ semodule_package -o custom_microservice.pp -m custom_microservice.mod -f custom_microservice.fc
$ semodule -i custom_microservice.pp

$ # Confirm installed module
$ semodule -l | grep custom_microservice
custom_microservice

$ # Configure persistent context mapping using semanage
$ semanage fcontext -a -t custom_api_data_t "/var/data/api(/.*)?"
$ restorecon -Rv /var/data/api
Relabeled /var/data/api from unconfined_u:object_r:var_t:s0 to system_u:object_r:custom_api_data_t:s0
Relabeled /var/data/api/config.json from unconfined_u:object_r:var_t:s0 to system_u:object_r:custom_api_data_t:s0

$ # Manage SELinux Booleans persistently
$ getsebool httpd_can_network_connect_db
httpd_can_network_connect_db --> off

$ setsebool -P httpd_can_network_connect_db on
$ getsebool httpd_can_network_connect_db
httpd_can_network_connect_db --> on
```

---

### 4.4 AppArmor Profile Administration and Enforcement Management

```console
$ # Check AppArmor execution status and profile counts
$ aa-status
apparmor module is loaded.
48 profiles are loaded.
44 profiles are in enforce mode.
   /usr/bin/evince
   /usr/sbin/nginx
   ...
4 profiles are in complain mode.
   /usr/sbin/identd
0 profiles are in kill mode.
0 profiles are in unconfined mode.
3 processes have profiles defined.
3 processes are in enforce mode.
   /usr/sbin/nginx (124802) nginx
   /usr/sbin/nginx (124803) nginx
   /usr/sbin/nginx (124804) nginx

$ # Load new profile in enforce mode directly via parser
$ apparmor_parser -r -W /etc/apparmor.d/usr.sbin.nginx

$ # Transition profile into complain mode for testing
$ aa-complain /usr/sbin/nginx
Setting /usr/sbin/nginx to complain mode.

$ # Transition profile back into enforce mode for production
$ aa-enforce /usr/sbin/nginx
Setting /usr/sbin/nginx to enforce mode.
```

---

## 5. Verification, Failure Diagnostics & Troubleshooting Guide

### 5.1 Systemic Security Layer Triage Protocol

When an `Access Denied` error occurs in production, follow this logical elimination hierarchy:

```
[ Application Permission Request Failed ]
                   |
                   v
     [ Check 1: Traditional DAC ]
     Is User/Group/Other bit matching? 
     Is Sticky Bit or umask blocking?
                   |
        +----------+----------+
        | NO                  | YES
        v                     v
[ Adjust standard     [ Check 2: POSIX Extended ACL ]
  chmod / chown ]     Is 'mask' restricting effective permissions?
                      Is explicit user/group ACL denying access?
                               |
                    +----------+----------+
                    | NO                  | YES
                    v                     v
            [ Check 3: Extended   [ Update setfacl /
              Attributes ]          recalculate mask ]
            Is file set to +i or +a via chattr?
                               |
                    +----------+----------+
                    | NO                  | YES
                    v                     v
            [ Check 4: Linux      [ Remove attribute:
              Security Module ]     chattr -i / -a ]
            Is system running SELinux or AppArmor?
                               |
                    +----------+----------+
                    | SELinux             | AppArmor
                    v                     v
            [ Inspect audit.log   [ Inspect dmesg /
              for AVC denials ]     syslog for AppArmor ]
```

---

### 5.2 SELinux AVC Troubleshooting Workflow

#### Step 1: Capture the exact Denial Event
Query `/var/log/audit/audit.log` using `ausearch` filtering for Access Vector Cache (AVC) messages.

```console
$ ausearch -m avc -ts recent
----
time->Thu Aug  6 13:30:10 2026
type=AVC msg=audit(1786037410.512:410): avc:  denied  { read } for  pid=12510 comm="nginx" name="index.html" dev="sda1" ino=912401 scontext=system_u:system_r:httpd_t:s0 tcontext=unconfined_u:object_r:user_home_t:s0 tclass=file permissive=0
```

#### Step 2: Analyze Context Mismatch
* **Subject Context (`scontext`):** `system_u:system_r:httpd_t:s0` (Web server running in `httpd_t` domain).
* **Target Context (`tcontext`):** `unconfined_u:object_r:user_home_t:s0` (Target file tagged with user home directory type `user_home_t`).
* **Root Cause:** NGINX is attempting to read a file labeled as user home data, which is prohibited under default `targeted` SELinux policy.

#### Step 3: Diagnostic Resolution Strategies

**Option A: Fix File Contexts (Recommended if file is in correct location)**
```console
$ semanage fcontext -a -t httpd_sys_content_t "/srv/www/html(/.*)?"
$ restorecon -Rv /srv/www/html
```

**Option B: Toggle Boolean (If feature is governed by policy switch)**
```console
$ sealert -a /var/log/audit/audit.log
# Sealert analyzes denial and suggests:
# If you want to allow httpd to read home directories:
# setsebool -P httpd_enable_homedirs 1
$ setsebool -P httpd_enable_homedirs 1
```

**Option C: Generate Custom Module via `audit2allow` (Use as Last Resort)**
```console
$ ausearch -m avc -c "nginx" | audit2allow -M fix_nginx_denial
$ semodule -i fix_nginx_denial.pp
```

---

### 5.3 AppArmor Troubleshooting Workflow

#### Step 1: Query System Logs for DENIED Messages
AppArmor violations are emitted to `dmesg`, `/var/log/syslog`, or systemd journal.

```console
$ journalctl -ke | grep -i apparmor
Aug 06 13:35:22 node-01 kernel: audit: type=1400 audit(1786037722.814:521): apparmor="DENIED" operation="open" profile="nginx" name="/etc/nginx/conf.d/custom.conf" pid=12601 comm="nginx" requested_mask="r" denied_mask="r" fsuid=0 ouid=0
```

#### Step 2: Parse Violation Details
* **Profile:** `nginx`
* **Operation:** `open`
* **Target Path:** `/etc/nginx/conf.d/custom.conf`
* **Requested Permission:** `r` (read)
* **Root Cause:** The profile `/etc/apparmor.d/usr.sbin.nginx` lacks explicit rule allowing read access to sub-files inside `/etc/nginx/conf.d/`.

#### Step 3: Interactive Log-Prof Optimization
Run `aa-logprof` to parse audit records and interactively update profile rules.

```console
$ aa-logprof
Reading log entries from /var/log/syslog.
Updating AppArmor profiles in /etc/apparmor.d.
Enforcing requested permissions...

Profile:        nginx
Path:           /etc/nginx/conf.d/custom.conf
New Mode:       r
Severity:       unknown

  1 - #include <abstractions/base> 
  2 - /etc/nginx/conf.d/custom.conf 
* 3 - /etc/nginx/conf.d/* 
[(A)llow] / (D)eny / (I)gnore / (G)lob / (E)dit profile: 3

Adding /etc/nginx/conf.d/* r to profile.
Save Changes? [(S)ave] / (C)ancel: S
```

---

## 6. References

* **Linux Professional Institute (LPI) LPIC-3 Security Objectives:**  
  [https://www.lpi.org/our-certifications/lpic-3-303-overview/](https://www.lpi.org/our-certifications/lpic-3-303-overview/)
* **LPI Wiki — LPIC-3 (303-300) Detailed Syllabus:**  
  [https://wiki.lpi.org/wiki/LPIC-3_303_Objectives_V3.0](https://wiki.lpi.org/wiki/LPIC-3_303_Objectives_V3.0)
* **Red Hat Enterprise Linux 9 — Managing SELinux:**  
  [https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/using_selinux/index](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/using_selinux/index)
* **Ubuntu Server Documentation — AppArmor Configuration:**  
  [https://ubuntu.com/server/docs/security-apparmor](https://ubuntu.com/server/docs/security-apparmor)
* **Linux Kernel Security Module (LSM) Architecture:**  
  [https://www.kernel.org/doc/html/latest/security/lsm.html](https://www.kernel.org/doc/html/latest/security/lsm.html)
* **POSIX Access Control Lists (ACLs) Linux Man Page:**  
  [https://man7.org/linux/man-pages/man5/acl.5.html](https://man7.org/linux/man-pages/man5/acl.5.html)