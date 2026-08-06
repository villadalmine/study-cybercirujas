# LPIC-3 Security (Exam 303-300 v3.0): Topic 333 - Access Control (Guided Production Labs & Advanced Diagnostics)

## 1. Technical Architecture & Internal Mechanics

### 1.1 Discretionary Access Control (DAC), POSIX ACLs, and Extended Attributes

Discretionary Access Control (DAC) in Linux relies on ownership: the owner of an object (file, directory, socket) determines the access permissions assigned to other subjects (users, groups).

```
   +-----------------------------------------------------------------------+
   |                            VFS Layer (Inodes)                         |
   +-----------------------------------------------------------------------+
        |                                   |                         |
        v                                   v                         v
+------------------+             +--------------------+     +-------------------+
|  Traditional DAC |             |     POSIX ACLs     |     | Extended Attrs    |
| (mode_t: rwxrwxrwx|             | (Default & Access) |     |   (xattr: user,   |
|   + SUID/SGID/   |             | (system.posix_acl) |     |  trusted, sec)    |
|   Sticky Bit)    |             +--------------------+     +-------------------+
+------------------+                       |                          |
        |                                  v                          v
        |                        +--------------------+     +-------------------+
        +----------------------->| Effective Permission|----->| Kernel Permission |
                                 | Calculation (Mask) |     | Enforcement Check |
                                 +--------------------+     +-------------------+
```

#### Traditional DAC Permissions & Special Bits
- **Standard Bits (`rwx`)**: Read (`4`), Write (`2`), Execute (`1`) mapped across Owner (User), Group, and Others.
- **SUID (`setuid`, bit `4000`)**: When set on an executable, the process executes with the effective UID (`eUID`) of the file owner rather than the calling user (e.g., `/usr/bin/passwd`).
- **SGID (`setgid`, bit `2000`)**: On executables, runs with the effective GID (`eGID`) of the group owner. On directories, newly created files inherit the group ownership of the directory rather than the primary group of the creating user.
- **Sticky Bit (`1000`)**: On directories, restricts deletion or renaming of files within the directory to the file owner, directory owner, or `root` (e.g., `/tmp`).

#### POSIX Access Control Lists (POSIX ACLs)
POSIX ACLs extend standard 3-tiered permissions by allowing fine-grained assignment of permissions to specific users or groups.
- **Access ACLs**: Evaluated during file/directory access attempts.
- **Default ACLs**: Applied only to directories. Inherited by newly created subdirectories and files within that directory.
- **The ACL Mask (`mask::`)**: Defines the maximum permissions allowed for all named users, group owner, and named groups. When an ACL is applied to a file, the traditional "group" permission bits (`rwx`) represent the ACL **mask**, NOT the group owner permissions. Any change via `chmod g-w` modifies the ACL mask, restricting permissions across all ACL entries.

#### Extended Attributes (`xattr`)
Extended attributes associate arbitrary `name:value` pairs with file inodes outside the standard metadata. They are structured into four primary kernel namespaces:
1. `user`: Accessible by non-privileged users, subject to standard DAC file permissions.
2. `trusted`: Restricted to processes with `CAP_SYS_ADMIN`. Used for system-level metadata.
3. `security`: Used by kernel Security Modules (LSM) such as SELinux (e.g., `security.selinux`).
4. `system`: Used by the kernel for Access Control Lists (`system.posix_acl_access`, `system.posix_acl_default`).

---

### 1.2 Mandatory Access Control (MAC) Architecture: SELinux, AppArmor, and SMACK

Mandatory Access Control (MAC) enforces system-wide access policies defined by an administrator. Under MAC, resource owners cannot relax security permissions on their objects; the system kernel enforces policy decisions regardless of DAC settings.

```
                              User Space Application / Process
                                             |
                                             v
                                  System Call Interface
                                             |
                                             v
                                        VFS / DAC
                                  (File Mode / POSIX ACLs)
                                             |
                                             v (If DAC Passes)
 +----------------------------------------------------------------------------------+
 | Linux Security Module (LSM) Framework                                            |
 |                                                                                  |
 |   +--------------------------------------------------------------------------+   |
 |   |                              SELinux Architecture                        |   |
 |   |                                                                          |   |
 |   |   Subject Context                  Object Context                        |   |
 |   | (system_u:system_r:httpd_t)     (system_u:object_r:httpd_sys_content_t)  |   |
 |   |              \                           /                               |   |
 |   |               v                         v                                |   |
 |   |             +-------------------------------+                            |   |
 |   |             |     Access Vector Cache (AVC) |                            |   |
 |   |             +-------------------------------+                            |   |
 |   |               /                           \                              |   |
 |   |        (Cache Miss)                   (Cache Hit)                        |   |
 |   |             v                              v                             |   |
 |   |   +-------------------+          +-------------------+                   |   |
 |   |   |   Security Server |          | Direct Enforcement|                   |   |
 |   |   | (Policy Database) |          | (Allow / Deny)    |                   |   |
 |   |   +-------------------+          +-------------------+                   |   |
 |   +--------------------------------------------------------------------------+   |
 |                                                                                  |
 |   +--------------------------------------------------------------------------+   |
 |   |                              AppArmor Architecture                       |   |
 |   |  Path-based containment: Profile enforcement matching full pathnames     |   |
 |   |  e.g., /usr/bin/nginx { /var/www/html/ r, /var/log/nginx/* w }           |   |
 |   +--------------------------------------------------------------------------+   |
 +----------------------------------------------------------------------------------+
                                             |
                                             v
                                   Hardware / Resource Access
```

#### SELinux (Security-Enhanced Linux)
SELinux implements Type Enforcement (TE), Role-Based Access Control (RBAC), and Multi-Level Security (MLS) / Multi-Category Security (MCS) via the Flask architecture.

- **SELinux Security Context Syntax**: `user:role:type:sensitivity:category`
  - **User (`user_u`, `system_u`)**: Maps Linux users to SELinux identities.
  - **Role (`object_r`, `httpd_roles`)**: Defines permissible types an identity can adopt (RBAC).
  - **Type (`httpd_t`, `httpd_sys_content_t`)**: The core element of Type Enforcement (TE). For processes, this is the domain; for objects, this is the type.
  - **MLS/MCS (`s0-s0:c0.c1023`)**: Sensitivity levels (`s0`) and categories (`c0-c1023`) used for multi-tenant containment (e.g., containers, virtual machines).
- **Access Vector Cache (AVC)**: Caches policy decisions in kernel space for high-performance lookup. If a rule is absent from the AVC, the Security Server queries the loaded policy database and caches the decision.
- **SELinux Operation Modes**:
  - `Enforcing`: Policy violations are blocked and audited.
  - `Permissive`: Policy violations are allowed but audited (critical for troubleshooting/policy generation).
  - `Disabled`: SELinux kernel hooks are uninstalled; security context labeling is ignored.

#### AppArmor
AppArmor uses path-based rules bound to binary profiles rather than label-based inode tagging.
- **Profile Modes**:
  - `Enforce`: Enforces profile rules and logs violations.
  - `Complain`: Allows non-compliant behavior while logging audit events (used for profile generation).
  - `Unconfined`: Process runs without AppArmor profile restrictions.
- **Execution Transitions**:
  - `px` (Discrete Profile Execute): Executes binary under a specific named AppArmor profile.
  - `cx` (Child Profile Execute): Transitions process to a child profile nested inside the parent profile.
  - `ix` (Inherit Execute): Executes binary while retaining the parent process's profile restrictions.
  - `ux` (Unconfined Execute): Executes binary without any profile containment (high risk).

#### SMACK (Simplified Mandatory Access Control Kernel)
SMACK is a lightweight MAC implementation that relies on simple, explicit rule matrices formatted as `Subject Object Access`. Attributes are stored in the `security.smack` extended attribute namespace.

---

### 1.3 Architecture Comparison & Production Trade-Offs

| Security Mechanism | Paradigm | Granularity | Storage Overhead | Administrative Complexity | Performance Impact |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **POSIX ACLs** | DAC | Per User/Group per file | Low (`system.posix_acl` xattr) | Low | Negligible |
| **SELinux** | Label-Based MAC (TE/MLS) | Inode label & Process Domain | Medium (`security.selinux` xattr) | High (Requires policy compilation & context management) | Low (Optimized via AVC kernel lookup) |
| **AppArmor** | Path-Based MAC | Absolute filesystem paths per executable | Low (Profiles stored in `/etc/apparmor.d/`) | Medium (Intuitive profile creation) | Very Low |
| **SMACK** | Label-Based MAC | Simple Subject/Object string matching | Low (`security.smack` xattr) | Low to Medium | Very Low |

---

### 1.4 Official References & Standards
- [LPIC-3 Exam 303-300 Detailed Objectives v3.0](https://www.lpi.org/our-certifications/lpic-3-303-overview/)
- [LPI Wiki: LPIC-3 Topic 333 (Access Control)](https://wiki.lpi.org/wiki/LPIC-3_303_Objectives_V3.0)
- [Linux Kernel Security Module (LSM) Documentation](https://www.kernel.org/doc/html/latest/admin-guide/LSM/index.html)
- [SELinux Project Documentation & Reference Policy](https://github.com/SELinuxProject/selinux)
- [AppArmor Documentation Project](https://gitlab.com/apparmor/apparmor/-/wikis/Documentation)

---

## 2. Guided Production Labs

### Lab 1: Advanced POSIX ACL Inheritance, Mask Recalculation, and Extended Attributes

#### Scenario
You are hardening a multi-tenant enterprise data store located at `/srv/finance_data`. The directory must support access for financial auditors (`auditor1`) and financial managers (`mgr1`), enforce default permission inheritance for newly created subdirectories/files, and store security audit hashes using `trusted` and `user` extended attributes.

#### Guided Steps

##### Step 1: Create directory structure and set base permissions
```bash
sudo mkdir -p /srv/finance_data/reports
sudo groupadd finance_audit
sudo groupadd finance_mgr
sudo useradd -g finance_audit auditor1
sudo useradd -g finance_mgr mgr1

# Set strict DAC permissions
sudo chown root:finance_mgr /srv/finance_data
sudo chmod 770 /srv/finance_data
```

##### Step 2: Configure explicit Access ACLs and Default ACLs
Assign read/execute access to `auditor1` and read/write/execute access to the `finance_mgr` group. Ensure all future subdirectories inherit these permissions automatically.

```bash
# Assign Access ACLs
sudo setfacl -m u:auditor1:rx /srv/finance_data
sudo setfacl -m g:finance_mgr:rwx /srv/finance_data

# Assign Default ACLs for automatic inheritance
sudo setfacl -d -m u:auditor1:rx /srv/finance_data
sudo setfacl -d -m g:finance_mgr:rwx /srv/finance_data
sudo setfacl -d -m m::rwx /srv/finance_data
```

##### Step 3: Inspect ACL settings and test inheritance
```bash
getfacl /srv/finance_data
```

*Expected Output:*
```text
# file: srv/finance_data
# owner: root
# group: finance_mgr
user::rwx
user:auditor1:r-x
group::rwx
group:finance_mgr:rwx
mask::rwx
other::---
default:user::rwx
default:user:auditor1:r-x
default:group::rwx
default:group:finance_mgr:rwx
default:mask::rwx
default:other::---
```

##### Step 4: Verify Mask behavior under `chmod`
Execute a traditional `chmod` on the directory and observe how POSIX ACLs handle the mask recalculation.

```bash
sudo touch /srv/finance_data/q4_ledger.txt
sudo chmod g-w /srv/finance_data/q4_ledger.txt
getfacl /srv/finance_data/q4_ledger.txt
```

*Expected Output:*
```text
# file: srv/finance_data/q4_ledger.txt
# owner: root
# group: root
user::rw-
user:auditor1:r-x		#effective:r--
group::rwx			#effective:r--
group:finance_mgr:rwx		#effective:r--
mask::r--
other::---
```

> **Notice**: Applying `chmod g-w` reduced the ACL `mask::` to `r--`. Consequently, the effective permissions for `group:finance_mgr` and `user:auditor1` are capped at `r--`.

##### Step 5: Restore the mask explicitly
```bash
sudo setfacl -m m::rwx /srv/finance_data/q4_ledger.txt
getfacl /srv/finance_data/q4_ledger.txt | grep mask
```

*Expected Output:*
```text
mask::rwx
```

##### Step 6: Manage Extended Attributes (`user` vs `trusted` namespaces)
Set a custom compliance hash in the `user` namespace and an internal integrity signature in the `trusted` namespace.

```bash
# Set user attribute
sudo setfattr -n user.audit_hash -v "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" /srv/finance_data/q4_ledger.txt

# Set trusted attribute (Requires root privileges)
sudo setfattr -n trusted.integrity_sig -v "sec_v4_ok" /srv/finance_data/q4_ledger.txt

# Read attributes back
getfattr -d -m "-" /srv/finance_data/q4_ledger.txt
```

*Expected Output:*
```text
# file: srv/finance_data/q4_ledger.txt
trusted.integrity_sig="sec_v4_ok"
user.audit_hash="sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
```

---

#### Comprehension Check: Lab 1

**Question 1.1**: If a user runs `chmod 755 file.txt` on a file containing explicit POSIX ACLs for three individual users, how does this affect the effective permissions of those named users?
**Question 1.2**: Why does an unprivileged non-root user receive `Operation not permitted` when attempting to execute `getfattr -n trusted.integrity_sig file.txt`, even if DAC permissions give them `rwx` access to `file.txt`?

---

### Lab 2: SELinux Deep-Dive — Context Port Binding, AVC Audit Troubleshooting, & Custom Policy Module Creation

#### Scenario
A custom microservice binary `/usr/local/bin/secure_app` needs to bind to TCP port `8888` and read operational configuration from `/var/custom_app/config.json`. Currently, SELinux blocks these actions because port `8888` is not labeled for web/custom services and `/var/custom_app` lacks appropriate SELinux context labeling. You must diagnose AVC denials, bind file/port contexts using `semanage`, and compile a custom Type Enforcement policy module from raw audit logs.

#### Guided Steps

##### Step 1: Prepare test environment and generate initial denial
```bash
sudo mkdir -p /var/custom_app
echo '{"status": "production"}' | sudo tee /var/custom_app/config.json
sudo chmod 644 /var/custom_app/config.json

# Check current SELinux context of the new directory
ls -Z /var/custom_app/config.json
```

*Expected Output:*
```text
unconfined_u:object_r:var_t:s0 /var/custom_app/config.json
```

##### Step 2: Configure custom context paths using `semanage fcontext`
Bind `/var/custom_app` to `httpd_sys_content_t` persistently across system relabels.

```bash
# Add file context rule to SELinux database
sudo semanage fcontext -a -t httpd_sys_content_t "/var/custom_app(/.*)?"

# Relabel filesystem hierarchy
sudo restorecon -Rv /var/custom_app
```

*Expected Output:*
```text
Relabeled /var/custom_app from unconfined_u:object_r:var_t:s0 to unconfined_u:object_r:httpd_sys_content_t:s0
Relabeled /var/custom_app/config.json from unconfined_u:object_r:var_t:s0 to unconfined_u:object_r:httpd_sys_content_t:s0
```

##### Step 3: Configure SELinux Port Contexts
Allow web processes (`httpd_t`) to bind to non-standard TCP port `8888`.

```bash
# Query existing HTTP port bindings
sudo semanage port -l | grep http_port_t

# Assign TCP port 8888 to http_port_t context
sudo semanage port -a -t http_port_t -p tcp 8888

# Verify new binding
sudo semanage port -l | grep 8888
```

*Expected Output:*
```text
http_port_t                    tcp      8888, 80, 81, 443, 488, 8008, 8009, 8443, 9000
```

##### Step 4: Simulate AVC Denial and Inspect Audit Logs
Trigger a simulated process context conflict by testing access under a confined domain (`system_cronjob_t` trying to read `/var/custom_app/config.json`).

```bash
# Query AVC logs for recent access violations
sudo ausearch -m AVC,USER_AVC -ts recent
```

*Expected Output:*
```text
type=AVC msg=audit(1722950000.412:982): avc:  denied  { read } for  pid=4102 comm="secure_app" name="config.json" dev="dm-0" ino=134912 scontext=system_u:system_r:system_cronjob_t:s0 tcontext=unconfined_u:object_r:httpd_sys_content_t:s0 tclass=file permissive=0
```

##### Step 5: Engineer a Custom SELinux Type Enforcement (`.te`) Module
Instead of setting SELinux to `Permissive` mode, generate a custom policy module using `audit2allow` to grant the specific `read` permission on `httpd_sys_content_t` to `system_cronjob_t`.

```bash
# Extract AVC denial and generate Policy Source (.te)
sudo ausearch -m AVC -c "secure_app" | audit2allow -m custom_secure_app > custom_secure_app.te

# Inspect the generated Type Enforcement manifest
cat custom_secure_app.te
```

*Syntactically Valid Output (`custom_secure_app.te`):*
```text
module custom_secure_app 1.0;

require {
	type system_cronjob_t;
	type httpd_sys_content_t;
	class file { open read getattr };
}

#============= system_cronjob_t ==============
allow system_cronjob_t httpd_sys_content_t:file { open read getattr };
```

##### Step 6: Compile, Package, and Install the SELinux Policy Module
Compile the raw `.te` file into a kernel binary module `.mod`, build the policy package `.pp`, and load it into the active SELinux policy store.

```bash
# Step A: Compile module definition
checkmodule -M -m -o custom_secure_app.mod custom_secure_app.te

# Step B: Build policy package
semodule_package -o custom_secure_app.pp -m custom_secure_app.mod

# Step C: Install policy module into kernel store
sudo semodule -i custom_secure_app.pp

# Step D: Verify loaded policy module
sudo semodule -l | grep custom_secure_app
```

*Expected Output:*
```text
custom_secure_app
```

##### Step 7: Manage SELinux Booleans
Enable HTTP process network connection capabilities globally via SELinux boolean.

```bash
# Query boolean state
getsebool httpd_can_network_connect

# Enable boolean persistently (-P flag writes to persistent policy store)
sudo setsebool -P httpd_can_network_connect on

# Re-verify boolean state
getsebool httpd_can_network_connect
```

*Expected Output:*
```text
httpd_can_network_connect --> on
```

---

#### Comprehension Check: Lab 2

**Question 2.1**: What is the structural security risk of running `audit2allow -a -M mymodule` directly against all AVC denials without reviewing the output `.te` file first?
**Question 2.2**: What is the key difference between using `chcon` to set a file context versus using `semanage fcontext` followed by `restorecon`?

---

### Lab 3: AppArmor Profile Construction, Transition Modes, and Diagnostic Auditing

#### Scenario
You are isolating an untrusted daemon process located at `/usr/sbin/custom_daemon`. You must construct a complete AppArmor profile enforcing strict file access boundaries, block execution of external shells, configure profile execution transitions, and verify policy state using AppArmor administration tooling.

#### Guided Steps

##### Step 1: Verify AppArmor operational status and profiles
```bash
sudo aa-status
```

*Expected Output:*
```text
apparmor module is loaded.
42 profiles are loaded.
40 profiles are in enforce mode.
   /usr/bin/evince
   /usr/sbin/tcpdump
2 profiles are in complain mode.
   /usr/bin/identisk
0 processes have profiles defined.
```

##### Step 2: Create a complete, syntactically valid AppArmor Profile
Create a profile definition file at `/etc/apparmor.d/usr.sbin.custom_daemon`.

```bash
sudo bash -c 'cat << "EOF" > /etc/apparmor.d/usr.sbin.custom_daemon
#include <tunables/global>

/usr/sbin/custom_daemon {
  #include <abstractions/base>
  #include <abstractions/nameservice>

  # Capability restrictions
  capability net_bind_service,
  capability setuid,
  capability setgid,

  # File Access Controls
  /usr/sbin/custom_daemon r,
  /etc/custom_daemon/*.conf r,
  /var/log/custom_daemon/*.log w,
  /var/run/custom_daemon.pid rw,

  # Explicit execution restrictions (ix = inherit execution profile)
  /usr/bin/helper_tool ix,

  # Prevent execution of command shells (Deny rules override allow rules)
  deny /usr/bin/bash x,
  deny /usr/bin/sh x,

  # Network Restrictions
  network inet stream,
  network inet6 stream,
}
EOF'
```

##### Step 3: Load profile into AppArmor engine in Complain Mode
```bash
# Parse and load profile into complain mode
sudo aa-complain /etc/apparmor.d/usr.sbin.custom_daemon

# Verify complain mode state
sudo aa-status | grep custom_daemon
```

*Expected Output:*
```text
   /usr/sbin/custom_daemon
```

##### Step 4: Parse audit logs and transition profile to Enforce Mode
Enforce the profile using `apparmor_parser` and verify containment.

```bash
# Reload profile in enforcing mode
sudo apparmor_parser -r -W /etc/apparmor.d/usr.sbin.custom_daemon
sudo aa-enforce /usr/sbin/custom_daemon

# Verify enforce status
sudo aa-status | grep custom_daemon
```

*Expected Output:*
```text
   /usr/sbin/custom_daemon
```

##### Step 5: Test Execution Transition Rule Enforcement
Inspect AppArmor denial entries in syslog / dmesg when `/usr/sbin/custom_daemon` attempts an unauthorized write or shell invocation.

```bash
sudo dmesg | grep -i apparmor | tail -n 5
```

*Expected Output:*
```text
[ 4123.891024] audit: type=1400 audit(1722950500.100:102): apparmor="DENIED" operation="exec" profile="/usr/sbin/custom_daemon" name="/usr/bin/bash" pid=5120 comm="custom_daemon" requested_mask="x" denied_mask="x" fsuid=0 ouid=0
```

---

#### Comprehension Check: Lab 3

**Question 3.1**: In AppArmor profile syntax, what is the operational difference between the execution flags `px` (Discrete Profile Execute) and `ux` (Unconfined Execute)?
**Question 3.2**: If both an AppArmor `allow` rule and an explicit `deny` rule match the exact same path (e.g., `deny /usr/bin/bash x`), which rule takes precedence under the AppArmor evaluation engine?

---

<details>
<summary><b>Click to expand Solutions and Detailed Technical Explanations</b></summary>

### Comprehensive Answer Key & Deep-Dive Explanations

#### Lab 1 Solutions: POSIX ACLs & Extended Attributes

##### Solution 1.1
- **Answer**: Setting explicit file permissions via standard `chmod` (e.g., `chmod 755 file.txt`) modifies the POSIX ACL **mask** (`mask::`), NOT the base group owner permissions.
- **Detailed Explanation**: When POSIX ACLs exist on a file, the 4th through 6th permission bits shown by `ls -l` (the traditional group field) represent the ACL Mask. The effective permission of any named user (`u:username:rwx`) or named group (`g:groupname:rwx`) is the bitwise AND union of their explicitly assigned permission and the current ACL mask:
  $$\text{Effective Permission} = \text{Assigned ACL Permission} \land \text{ACL Mask}$$
  Executing `chmod 755` sets the group permission field (and thus the mask) to `r-x` (`5`). If a named user had `rw-` permissions, their effective access becomes `r--` (`rw-` $\land$ `r-x` = `r--`).
- **Exam Tip (LPIC-3 303)**: To restore full effective permissions after a `chmod` operation, recalculate or re-assign the mask explicitly using `setfacl -m m::rwx file.txt` or `setfacl -b file.txt` to remove extended ACL entries entirely.

##### Solution 1.2
- **Answer**: Extended attributes under the `trusted` namespace are restricted by the Linux VFS kernel layer to processes holding the `CAP_SYS_ADMIN` capability (typically root).
- **Detailed Explanation**: Extended attributes are split into distinct namespaces (`user`, `trusted`, `security`, `system`). While attributes in the `user.` namespace obey normal DAC permissions (read access allows reading `user.*` attributes), attributes in the `trusted.` namespace bypass standard DAC checks and strictly require Linux capability `CAP_SYS_ADMIN`. Even if DAC permissions are `0777`, non-root users without `CAP_SYS_ADMIN` will fail VFS security checks with `EPERM` (`Operation not permitted`).

---

#### Lab 2 Solutions: SELinux Mechanics & Diagnostics

##### Solution 2.1
- **Answer**: Executing `audit2allow -a -M mymodule` blindly generates policy rules for EVERY denial logged across the entire system, potentially granting excessive privileges to compromised or misconfigured processes.
- **Detailed Explanation**: `audit2allow` analyzes AVC denial events in the audit log and synthesizes corresponding `allow` statements. Running it globally (`-a`) without filtering for a specific process or context takes all recent system-wide denials—including legitimate security blocks triggered by malicious activity or misconfigurations—and automatically authorizes them in a compiled policy module.
- **Production Best Practice**:
  1. Filter audit entries by process name or daemon context using `ausearch -c "process_name"` or `ausearch -m AVC -ts recent`.
  2. Inspect the resulting `.te` (Type Enforcement) source file manually to ensure rules align with minimum privilege principles.
  3. Resolve labeling issues first using `semanage fcontext` / `restorecon` before creating custom `allow` policy modules. Many AVC denials stem from incorrect object context labels rather than missing TE policy rules.

##### Solution 2.2
- **Answer**: `chcon` changes the SELinux context of a file **temporarily** in file metadata, whereas `semanage fcontext` updates the **system policy file context database** (`/etc/selinux/targeted/contexts/files/file_contexts`).
- **Detailed Explanation**:
  - `chcon` (Change Context): Directly modifies the `security.selinux` extended attribute of a file inode. However, it does NOT register the mapping in SELinux policy stores. If `restorecon` is run, or if a system relabel occurs (`fixfiles` or `touch /.autorelabel`), all changes applied via `chcon` are erased and reset to default policy definitions.
  - `semanage fcontext`: Writes persistent path expression rules into the SELinux policy database. Running `restorecon -v filename` reads these persistent database rules and applies the correct context to the target file attributes.

---

#### Lab 3 Solutions: AppArmor Profile Containment

##### Solution 3.1
- **Answer**:
  - `px` (Discrete Profile Execute): Instructs AppArmor to transition execution of the target binary to a dedicated, separate AppArmor profile matching the executable's path. If no matching profile exists, execution is blocked.
  - `ux` (Unconfined Execute): Executes the target binary completely unconfined, relinquishing all AppArmor restrictions for that child process.
- **Security Impact**: Using `ux` creates a privilege boundary break. If a contained application executes a binary under `ux`, any compromise of that child binary bypasses AppArmor containment entirely. `px` or `ix` (inherit parent profile) must be used in production profiles.

##### Solution 3.2
- **Answer**: In AppArmor profile syntax, **explicit `deny` rules always take precedence over `allow` rules**, regardless of rule ordering inside the profile definition.
- **Detailed Explanation**: AppArmor evaluates security rules using a strict precedence engine:
  $$\text{Precedence} = \text{Deny Rules} > \text{Specific Allow Rules} > \text{Abstracted Allow Rules}$$
  Even if `#include <abstractions/base>` or a broad wildcard rule grants access/execution to `/usr/bin/*`, an explicit declaration of `deny /usr/bin/bash x,` guarantees that execution of `/usr/bin/bash` will be blocked and audited under all circumstances.

</details>