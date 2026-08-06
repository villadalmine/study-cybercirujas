# LPIC-3 Exam 300-300 (v3.0) — Topic 3.1: Samba Share Configuration

**Exam Weight:** 20  
**Target Role:** Senior SRE / Principal Platform Architect  
**Objective Scope:** Advanced Samba share design, Active Directory integration (`security = ADS`), fine-grained authorization (`valid users`, `hosts allow`), POSIX/NTFS ACL mapping (`vfs_acl_xattr`), VFS module stacking (`full_audit`, `shadow_copy2`, `recycle`), low-latency concurrency tuning (`smb2 leases`, `aio`), SELinux policy enforcement, and low-level diagnostic workflows (`smbstatus`, `smbcacls`, `getfattr`, `tcpdump`).

---

## 1. Production Architectural Motivation & Problem Statement

### 1.1 The Enterprise Hybrid File Infrastructure Challenge
In modern enterprise environments, Linux servers frequently host mission-critical file shares accessed concurrently by Windows workstations, Linux compute nodes, macOS clients, and automated CI/CD pipelines. This multi-protocol ecosystem introduces five major architectural challenges:

1. **Identity & Access Management (IAM) Disparity:** Windows ecosystems rely on Active Directory Security Identifiers (SIDs) and Windows Access Control Lists (NTFS ACLs), whereas Linux relies on POSIX User IDs (UIDs), Group IDs (GIDs), and POSIX/NFSv4 draft ACLs. Bridging these paradigms without identity corruption or privilege escalation is critical.
2. **Concurrency & File Locking Semantics:** Windows applications (such as Microsoft Office or CAD software) rely heavily on Opportunistic Locks (Oplocks) and SMB2/3 Leases for client-side caching and dynamic lock revocation. If Linux local processes or NFS exports access the same file hierarchy without SMB lock synchronization, data corruption and file lock deadlocks occur.
3. **Data Protection & Point-in-Time Recovery:** Enterprise compliance (SOX, HIPAA, ISO 27001) demands self-service snapshot recovery (Windows Volume Shadow Copy Service / VSS integration) without exposing underlying filesystem snapshot mounts to unauthorized network users.
4. **Audit Traceability:** Security Operations Centers (SOC) require granular, non-repudiable audit logs covering file creation, deletion, modification, permission alterations, and read operations, piped directly to SIEM solutions (e.g., Splunk, Elastic) via syslog.
5. **High-Performance Storage I/O:** High-throughput media rendering, scientific data ingestion, or multi-gigabit workstation access requires asynchronous I/O (`aio`), zero-copy network operations (`sendfile`), SMB3 encryption (AES-128-GCM / AES-256-GCM), and SMB Multichannel without CPU bottlenecking.

```
                         [ Active Directory Domain Controller ]
                                          |
                                (Kerberos v5 / LDAP)
                                          |
[ Windows 11 Client ] <---> [ Samba 4 smbd (vfs_acl_xattr) ] <---> [ POSIX File System ]
  (NTFS ACL / SMB3.1.1)                 |                             (ext4 / XFS / ZFS)
                                        +--> [ Extended Attributes ] (security.NTACL)
                                        +--> [ VFS Audit Logs ]      (/var/log/audit)
                                        +--> [ Shadow Copy VSS ]     (LVM/ZFS Snapshots)
```

---

## 2. Technical Comparisons & Trade-off Tables

### 2.1 Samba Security Models & Domain Integration Strategies

| Metric / Parameter | `security = ADS` | `security = USER` | `security = DOMAIN` (Deprecated) |
| :--- | :--- | :--- | :--- |
| **Identity Provider** | Active Directory (Kerberos v5 + LDAP via Winbind/SSSD) | Local Samba TDB database (`passdb.tdb`) or LDAP | Windows NT4 Domain Controller (NTLM RPC) |
| **Authentication Flow** | Ticket Granting Service (TGS) ticket / SPNEGO / NTLMv2 fallback | Challenge-Response via local SAM / Passdb | RPC pipe pass-through to DC |
| **Kerberos Support** | Full support (AES-256-CTS-HMAC-SHA1-96) | None | None |
| **Administrative Overhead** | Low (centralized in AD) | High (per-node user lifecycle management) | Legacy operational burden |
| **Production Use Case** | Enterprise Active Directory Domain Member | Standalone edge node / DMZ appliance | Legacy migration scenarios only |

### 2.2 ACL Storage & Mapping Strategies

| Strategy | Mechanical Details | Pros | Cons / Trade-offs |
| :--- | :--- | :--- | :--- |
| **Pure POSIX Draft ACLs** (`vfs_default`) | Maps Windows NT ACLs directly to POSIX 1003.1e draft ACLs (`getfacl`/`setfacl`). | Native Linux tooling compatibility; readable via standard filesystem utilities. | Cannot represent full Windows Security Descriptor (SD) granularity (e.g., granular audit rules, specific flags like `Delete Child`). |
| **Extended Attribute NTACL** (`vfs_acl_xattr`) | Stores complete binary Windows Security Descriptor in filesystem EA `security.NTACL`. Maps basic POSIX permissions for fallback. | 100% Windows NTFS ACL fidelity; full support for inherited permissions and advanced flags. | Requires underlying filesystem support for Extended Attributes (`user_xattr`); POSIX `chmod` on host can desynchronize `security.NTACL`. |
| **TDB Database NTACL** (`vfs_acl_tdb`) | Stores Windows Security Descriptors in a centralized TDB database mapped by File ID. | Works on filesystems without Extended Attribute support (e.g., NFS mounts). | TDB bottleneck under high IPC; single point of failure if TDB corrupts; snapshot sync challenges. |

### 2.3 Concurrency & Locking Mechanics

| Feature | Protocol Layer | Behavioral Mechanism | Recommended Setting |
| :--- | :--- | :--- | :--- |
| **Batch / Exclusive Oplocks** | SMB1 / SMB2 | Server delegates exclusive cache write permission to client. Server breaks oplock on concurrent access attempt. | `oplocks = yes` |
| **SMB2/3 Leases** | SMB2.1+ / SMB3.1.1 | Grants Read (R), Write (W), and Handle (H) leases independently. Allows clients to cache handles across network reconnections. | `smb2 leases = yes` |
| **Kernel Oplocks** | Linux Kernel (`fcntl` F_SETLEASE) | Synchronizes Samba SMB oplocks with local Linux process file access via kernel signals. | `kernel oplocks = yes` (Disable if using non-POSIX clustered filesystems like GlusterFS/Ceph unless VFS module handles it). |
| **Strict Locking** | Samba Server Engine | Forces Samba to check server-side lock state on every read/write operation regardless of client oplock state. | `strict locking = auto` (High safety; minimal overhead on SMB2/3). |

---

## 3. Complete Production Configurations & Infrastructure Manifests

### 3.1 Fully Formatted Production Samba Configuration (`/etc/samba/smb.conf`)

Below is a complete, syntactically valid enterprise production `smb.conf` designed for an Active Directory domain member with VFS audit logging, automated recycle bin, shadow copies, and POSIX ACL mapping.

```ini
# ==============================================================================
# Production Enterprise Samba Configuration
# Node Role: Domain Member Server (Active Directory Integration)
# Architecture: High-Availability Shared Storage Server
# ==============================================================================

[global]
    # --- Identity & Active Directory Integration ---
    workgroup = CORP
    realm = CORP.EXAMPLE.COM
    security = ADS
    kerberos method = secrets and keytab
    winbind refresh tickets = yes
    winbind use default domain = yes
    winbind offline logon = yes
    winbind enum users = no
    winbind enum groups = no

    # --- ID Mapping (idmap_rid: Deterministic SID-to-UID/GID Algorithmic Mapping) ---
    idmap config * : backend = tdb
    idmap config * : range = 10000-19999
    idmap config CORP : backend = rid
    idmap config CORP : range = 20000-999999

    # --- Server Roles & Services ---
    server string = Enterprise Storage Node %h (Samba %v)
    netbios name = STOR-NODE-01
    disable netbios = yes
    smb ports = 445

    # --- Protocol & Security Hardening ---
    server min protocol = SMB3_00
    server max protocol = SMB3_11
    client ipc min protocol = SMB3_00
    client max protocol = SMB3_11
    client signing = required
    server signing = required
    smb encrypt = required
    restrict anonymous = 2
    invalid users = root daemon bin sys sync games man lp mail news uucp proxy

    # --- Performance Tuning & Async I/O ---
    aio read size = 1
    aio write size = 1
    use sendfile = yes
    min receivefile size = 16384
    socket options = TCP_NODELAY SO_RCVBUF=131072 SO_SNDBUF=131072
    smb2 leases = yes
    oplocks = yes
    kernel oplocks = yes
    strict locking = auto

    # --- Global ACL & Attribute Behavior ---
    ea support = yes
    store dos attributes = yes
    map archive = no
    map hidden = no
    map system = no
    map read only = no
    vfs objects = acl_xattr full_audit

    # --- Global VFS Audit Configuration ---
    full_audit:prefix = %u|%I|%m|%S
    full_audit:success = mkdir rmdir write pwrite unlink rename pwritev chmod chown
    full_audit:failure = connect write pwrite unlink rename chmod chown
    full_audit:facility = LOCAL7
    full_audit:priority = NOTICE

    # --- Logging Configuration ---
    log level = 1 auth:3 winbind:3 vfs:2
    log file = /var/log/samba/log.%m
    max log size = 50000
    logging = syslog@LOCAL7 file

# ==============================================================================
# Share Definitions
# ==============================================================================

[homes]
    comment = User Home Directories
    path = /srv/samba/homes/%U
    browseable = no
    read only = no
    create mask = 0700
    directory mask = 0700
    valid users = %V\%U CORP\"Domain Admins"
    root preexec = /usr/local/bin/samba_mkhomedir.sh "%U" "%G"
    vfs objects = acl_xattr full_audit recycle
    recycle:repository = .recycle
    recycle:keeptree = yes
    recycle:versions = yes
    recycle:touch = yes
    recycle:maxsize = 0
    recycle:exclude = *.tmp, *.temp, ~$*

[Finance_Data]
    comment = Enterprise Finance Secure Repository
    path = /srv/samba/shares/finance
    browseable = yes
    read only = no
    guest ok = no
    valid users = @CORP\"Finance Department" @CORP\"Domain Admins"
    write list = @CORP\"Finance Managers" @CORP\"Domain Admins"
    force group = CORP\"Finance Department"
    
    # Permission Inheritance & POSIX / Windows Mapping Controls
    create mask = 0660
    directory mask = 0770
    force create mode = 0660
    force directory mode = 0770
    inherit permissions = yes
    inherit acls = yes
    map acl inherit = yes

    # VFS Module Pipeline Stacking
    vfs objects = acl_xattr shadow_copy2 full_audit recycle

    # VFS Shadow Copy 2 Parameters (LVM/ZFS Snapshot Integration)
    shadow:snapdir = .snapshots
    shadow:format = @GMT-%Y.%m.%d-%H.%M.%S
    shadow:sort = desc
    shadow:localtime = no
    shadow:basedir = /srv/samba/shares/finance

    # VFS Recycle Parameters
    recycle:repository = /srv/samba/shares/finance/.recycle
    recycle:keeptree = yes
    recycle:versions = yes
    recycle:touch_mtime = yes
    recycle:directory_mode = 0770
    recycle:exclude = ~$*, *.tmp, *.log, index.dat

[Engineering_Builds]
    comment = High-Throughput CI/CD Build Artifacts (Read-Only Public Access)
    path = /srv/samba/shares/engineering
    browseable = yes
    read only = yes
    guest ok = yes
    hosts allow = 10.250.0.0/16 192.168.10.0/24 127.0.0.1
    hosts deny = ALL
    valid users = @CORP\"Engineers" @CORP\"Domain Admins" guest
    write list = @CORP\"Release Engineers"
    
    # High-Performance File Handling Settings
    oplocks = yes
    level2 oplocks = yes
    smb2 leases = yes
    vfs objects = acl_xattr full_audit
```

---

### 3.2 Host Filesystem Initialization & Systemd Integration

To support the above configuration, execute the structural setup script to configure storage directories, systemd service overrides, and SELinux policies.

```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. Create Base Directories
mkdir -p /srv/samba/homes
mkdir -p /srv/samba/shares/finance/{.snapshots,.recycle}
mkdir -p /srv/samba/shares/engineering

# 2. Set Default Host POSIX Permissions
chown -R root:20000 /srv/samba/shares/finance # 20000 mapped to Domain Admins
chmod -R 2770 /srv/samba/shares/finance

chown -R root:20001 /srv/samba/shares/engineering # 20001 mapped to Engineers
chmod -R 2775 /srv/samba/shares/engineering

# 3. Configure SELinux Booleans & File Contexts
if command -v getenforce &> /dev/null && [ "$(getenforce)" != "Disabled" ]; then
    echo "[+] Configuring SELinux policy contexts for Samba..."
    setsebool -P samba_enable_home_dirs on
    setsebool -P samba_export_all_rw on
    
    semanage fcontext -a -t samba_share_t "/srv/samba(/.*)?"
    restorecon -Rv /srv/samba
fi

# 4. Systemd Service Hardening Override (/etc/systemd/system/smbd.service.d/override.conf)
mkdir -p /etc/systemd/system/smbd.service.d/
cat << 'EOF' > /etc/systemd/system/smbd.service.d/override.conf
[Service]
LimitNOFILE=65536
LimitNPROC=65536
TasksMax=infinity
Restart=always
RestartSec=5s
EOF

systemctl daemon-reload
```

---

## 4. Real CLI Commands & Step-by-Step Terminal Outputs

### 4.1 Syntax Validation and Parameter Verification (`testparm`)

Execute `testparm` to verify parameter syntax, ensure no illegal key combinations exist, and validate global/share scopes.

```bash
$ testparm -s /etc/samba/smb.conf
```
```output
Load smb config files from /etc/samba/smb.conf
Loaded services file OK.
Weak crypto is allowed by GnuTLS (default)
Server role: ROLE_DOMAIN_MEMBER

# Log output truncates default values, dumping effective configuration:
[global]
	bind interfaces only = Yes
	client max protocol = SMB3_11
	client min protocol = SMB3_00
	client signing = required
	disable netbios = Yes
	ea support = Yes
	idmap config corp : range = 20000-999999
	idmap config corp : backend = rid
	idmap config * : range = 10000-19999
	idmap config * : backend = tdb
	invalid users = root daemon bin sys sync games man lp mail news uucp proxy
	kerberos method = secrets and keytab
	logging = syslog@LOCAL7 file
	realm = CORP.EXAMPLE.COM
	security = ADS
	server max protocol = SMB3_11
	server min protocol = SMB3_00
	server signing = required
	smb encrypt = required
	workgroup = CORP
	idmap config * : backend = tdb

[Finance_Data]
	comment = Enterprise Finance Secure Repository
	create mask = 0660
	directory mask = 0770
	force create mode = 0660
	force directory mode = 0770
	force group = CORP\"Finance Department"
	inherit acls = Yes
	inherit permissions = Yes
	map acl inherit = Yes
	path = /srv/samba/shares/finance
	read only = No
	shadow:basedir = /srv/samba/shares/finance
	shadow:format = @GMT-%Y.%m.%d-%H.%M.%S
	shadow:snapdir = .snapshots
	valid users = @CORP\"Finance Department", @CORP\"Domain Admins"
	vfs objects = acl_xattr shadow_copy2 full_audit recycle
	write list = @CORP\"Finance Managers", @CORP\"Domain Admins"
```

---

### 4.2 Active Directory Domain Join & Secret Verification (`net ads`)

Join the node to Active Directory, populate `/etc/krb5.keytab`, and verify authentication status.

```bash
$ net ads join -U "Administrator%P@ssw0rd2026" -s /etc/samba/smb.conf
```
```output
Using short domain name -- CORP
Joined 'STOR-NODE-01' to dns domain 'corp.example.com'
No DNS domain configured for stor-node-01. Unable to perform DNS Update.
DNS update should be performed manually or fix your /etc/hosts file.
```

```bash
$ net ads testjoin
```
```output
Join is OK
```

```bash
$ klist -k /etc/krb5.keytab
```
```output
Keytab version: 0x0502
KVNO Timestamp           Principal
---- ------------------- ------------------------------------------------------
   3 08/06/2026 12:00:01 STOR-NODE-01$@CORP.EXAMPLE.COM
   3 08/06/2026 12:00:01 STOR-NODE-01$@CORP.EXAMPLE.COM
   3 08/06/2026 12:00:01 host/STOR-NODE-01@CORP.EXAMPLE.COM
   3 08/06/2026 12:00:01 host/STOR-NODE-01.corp.example.com@CORP.EXAMPLE.COM
   3 08/06/2026 12:00:01 cifs/STOR-NODE-01@CORP.EXAMPLE.COM
   3 08/06/2026 12:00:01 cifs/STOR-NODE-01.corp.example.com@CORP.EXAMPLE.COM
```

---

### 4.3 Runtime Monitoring & Lock Inspection (`smbstatus`)

Inspect active SMB connections, protocol dialects, signing, encryption, and open locks across all shares.

```bash
$ smbstatus --verbose
```
```output
Samba version 4.19.4-Debian
PID     Username     Group        Machine                             Protocol Version           Encryption           Signing              
----------------------------------------------------------------------------------------------------------------------------------------
409112  john_doe     Domain Users 10.250.4.12 (ipv4:10.250.4.12:51234)  SMB3_11                    AES-128-GCM          partial(signed)      

Service      pid     Machine       Connected at                     Encryption                   Signing              
----------------------------------------------------------------------------------------------------------------------
Finance_Data 409112  10.250.4.12   Thu Aug  6 12:14:02 2026 EDT     AES-128-GCM                  partial(signed)      

Locked files:
Pid          User(uid)           DenyMode   Access      R/W        Oplock           SharePath                        Name                        Time
------------------------------------------------------------------------------------------------------------------------------------------------------------------
409112       20542               DENY_NONE  0x120089    RDWR       LEASE(RWH)       /srv/samba/shares/finance        budget_2027_draft.xlsx      Thu Aug  6 12:15:30 2026

# Lease status detailing RWH (Read/Write/Handle) state:
Key: 3a:fa:8c:11:02:ee:4b:11:b9:2d:00:15:5d:01:10:04
Flags: 0x3 (READ WRITE HANDLE)
```

---

### 4.4 Managing Windows Security Descriptors via CLI (`smbcacls`)

Directly inspect and modify the stored Windows NT Security Descriptor (`security.NTACL`) on a Samba share file without using a GUI Windows workstation.

```bash
$ smbcacls //localhost/Finance_Data "/budget_2027_draft.xlsx" -U "CORP\john_doe%Secret123"
```
```output
REVISION:1
CONTROL:SR|PD|DI
OWNER:CORP\john_doe
GROUP:CORP\Finance Department
ACL:CORP\Domain Admins:ALLOWED/OI|CI/FULL
ACL:CORP\Finance Managers:ALLOWED/OI|CI/CHANGE
ACL:CORP\john_doe:ALLOWED/OI|CI/READ
```

To revoke access for `john_doe` and add an explicit ALLOW rule for `CORP\jane_smith`:

```bash
$ smbcacls //localhost/Finance_Data "/budget_2027_draft.xlsx" \
  -U "CORP\administrator%P@ssw0rd2026" \
  -ADD "ACL:CORP\jane_smith:ALLOWED/OI|CI/FULL"
```
```output
REVISION:1
CONTROL:SR|PD|DI
OWNER:CORP\john_doe
GROUP:CORP\Finance Department
ACL:CORP\Domain Admins:ALLOWED/OI|CI/FULL
ACL:CORP\Finance Managers:ALLOWED/OI|CI/CHANGE
ACL:CORP\john_doe:ALLOWED/OI|CI/READ
ACL:CORP\jane_smith:ALLOWED/OI|CI/FULL
```

---

### 4.5 Inspecting Low-Level Extended Attributes (`getfattr`)

Verify how `vfs_acl_xattr` encodes the binary Windows Security Descriptor into the host Linux filesystem's extended attribute `security.NTACL`.

```bash
$ getfattr -n security.NTACL -d /srv/samba/shares/finance/budget_2027_draft.xlsx
```
```output
# file: srv/samba/shares/finance/budget_2027_draft.xlsx
security.NTACL=0sAQABAAAAAABgAAAAAAAABAAAAAEAACAAAQAAAAAABAAQAAAAAAAHAAAAAAACACAAAQAAAAAAAwAUAAAAAAABBQAAAAAAABQAAAAAAA==
```

To inspect raw DOS attributes (e.g., Read-Only, Hidden, System, Archive flags mapped via `store dos attributes = yes`):

```bash
$ getfattr -h -d -m "user.DOSATTRIB" /srv/samba/shares/finance/budget_2027_draft.xlsx
```
```output
# file: srv/samba/shares/finance/budget_2027_draft.xlsx
user.DOSATTRIB=0s00040020000000000000000000000000
```

---

## 5. Verification & Failure Diagnostics Guide

### 5.1 Troubleshooting Architecture Workflow

```
[ Incident Triggered ]
         |
         v
[ 1. Syntax Check ] -----------> Run `testparm -v`
         | (OK)
         v
[ 2. Domain & Auth Check ] ----> Run `wbinfo -u`, `wbinfo -t`, `klist -k`
         | (OK)
         v
[ 3. Local ID Resolution ] ----> Run `id CORP\username` (Verify RID range mapping)
         | (OK)
         v
[ 4. File Permission Audit ] --> Run `getfacl` AND `getfattr -n security.NTACL`
         | (OK)
         v
[ 5. Dynamic Lock/Lease ] -----> Run `smbstatus -L`
         | (OK)
         v
[ 6. Network/Protocol Trace ] -> Run `tcpdump -i any port 445 -w smb_trace.pcap`
```

---

### 5.2 Common Failure Scenarios & Resolution Matrix

#### Scenario A: Client Access Denied despite Correct Group Membership
* **Symptom:** User `CORP\alice` gets `NT_STATUS_ACCESS_DENIED` when connecting to `\\STOR-NODE-01\Finance_Data`.
* **Root Cause 1:** `idmap config` failure; Winbind cannot convert `CORP\alice` SID (`S-1-5-21-...-5001`) to host Linux UID because the RID falls outside specified ranges.
* **Root Cause 2:** Extended Attribute `security.NTACL` has a explicit DENY entry, or file system POSIX permissions (`chmod`) prohibit host process read/write.
* **Diagnostic Execution:**
  ```bash
  # Check if Winbind resolves user and group SIDs to local UIDs/GIDs
  $ id "CORP\alice"
  ```
  *Output Failure:* `id: 'CORP\alice': no such user`
  
  *Fix:* Adjust `idmap config CORP : range` in `/etc/samba/smb.conf` to accommodate larger RID numbers, then flush the idmap cache:
  ```bash
  $ net cache flush
  $ systemctl restart winbind smbd
  ```

#### Scenario B: File Lock Collisions and Slow Office File Saves
* **Symptom:** Microsoft Excel prompts users that files are "Locked for editing by another user" even after the initial user closed the document.
* **Root Cause:** SMB2 Lease or Oplock break timeout between Samba daemon and client, or failure of kernel oplocks to synchronize with a host backup agent accessing local files.
* **Diagnostic Execution:**
  ```bash
  $ smbstatus -L | grep "budget_2027_draft.xlsx"
  ```
  *Analysis:* Check if PID associated with the file lock still exists in host OS:
  ```bash
  $ ps aux | grep 409112
  ```
  If PID is stale, force close the open file handle via Samba CLI:
  ```bash
  $ smbstatus --close-file="/srv/samba/shares/finance/budget_2027_draft.xlsx"
  ```

#### Scenario C: Windows Shadow Copies Tab is Empty
* **Symptom:** Windows users right-click `Finance_Data` share -> Properties -> Previous Versions tab, but no snapshots appear despite existing LVM/ZFS snapshots on Linux host.
* **Root Cause:** Incorrect `shadow:format` string or timestamp timezone mismatch (`shadow:localtime`).
* **Diagnostic Execution:**
  Verify snapshot mount directory structure. Snapshots must strictly match the timestamp format defined in `shadow:format`:
  ```bash
  $ ls -la /srv/samba/shares/finance/.snapshots
  ```
  ```output
  drwxr-xr-x 4 root root 4096 Aug  6 00:00:00 @GMT-2026.08.06-00.00.00
  drwxr-xr-x 4 root root 4096 Aug  5 00:00:00 @GMT-2026.08.05-00.00.00
  ```
  Ensure `shadow:basedir` points to the root of the share path `/srv/samba/shares/finance` and that `vfs objects` places `shadow_copy2` **before** `default` or `acl_xattr` in execution precedence if required.

---

### 5.3 Deep Packet Diagnostic Filter Syntax (`tcpdump` & `tshark`)

When analyzing protocol negotiation failures, Kerberos ticket rejection, or SMB3 encryption failures, capture raw traffic on port 445:

```bash
# Capture raw SMB2/3 traffic to pcap file
$ tcpdump -nn -i any port 445 -s 0 -w /tmp/samba_traffic.pcap
```

Analyze the captured packet stream using `tshark` CLI to isolate SMB status error codes:

```bash
$ tshark -r /tmp/samba_traffic.pcap -Y "smb2.nt_status != 0" \
  -T fields -e frame.number -e ip.src -e ip.dst -e smb2.filename -e smb2.nt_status
```
```output
142   10.250.4.12   10.250.0.5   finance/budget.xlsx   0xc0000022  # STATUS_ACCESS_DENIED
289   10.250.4.88   10.250.0.5   finance/secret.doc    0xc0000034  # STATUS_OBJECT_NAME_NOT_FOUND
```

---

## 6. References

* **Linux Professional Institute (LPI) Official Exam 300-300 Objectives:**  
  https://www.lpi.org/our-certifications/lpic-3-300-overview/
* **Samba Official Documentation — smb.conf Man Page:**  
  https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html
* **Samba Official Wiki — Setting up Samba as a Domain Member:**  
  https://wiki.samba.org/index.php/Setting_up_Samba_as_a_Domain_Member
* **Samba Official Wiki — Setting up POSIX & Windows ACLs:**  
  https://wiki.samba.org/index.php/Setting_up_POSIX_ACLs
* **Samba Official Wiki — VFS Modules (vfs_acl_xattr, vfs_shadow_copy2, vfs_full_audit):**  
  https://wiki.samba.org/index.php/Virtual_Filesystem_Modules