# LPIC-3 Exam 300-300 (v3.0) — Topic 3.1: Samba Share Configuration

**Weight:** 20  
**Target Certification:** LPIC-3 Enterprise File and Storage Solutions (Exam 300-300, Version 3.0)  
**Official Reference:** [LPI LPIC-3 300 Objectives & Overview](https://www.lpi.org/our-certifications/lpic-3-300-overview/)  
**Samba Documentation:** [Samba smb.conf Documentation](https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html)

---

## Technical Overview & Architectural Foundations

Samba’s File Server daemon (`smbd`) provides Server Message Block (SMB/CIFS) protocol support over TCP ports `445` (Direct Host SMB) and `139` (NetBIOS Session Service over NetBT). In modern Linux SRE and Platform Engineering environments, configuring Samba shares requires balancing SMB3 protocol negotiation, POSIX mode bits, extended attributes (`xattr`), Windows Access Control Lists (NT ACLs), Virtual File System (VFS) plugin chains, and asynchronous I/O performance.

### Key Architecture Mechanics
1. **NT ACL to POSIX ACL Translation (`acl_xattr` & `acl_tdb`)**: Windows clients manipulate security descriptors (DACLs/SACLs) containing Security Identifiers (SIDs). Samba maps these SIDs to Linux User IDs (UIDs) / Group IDs (GIDs) via Winbind (`idmap`) and stores full Windows security descriptors inside Extended Attributes (`user.DOSATTRIB` and `user.NTACL`) on the underlying filesystem (e.g., ext4, xfs, ZFS).
2. **Permission Masks vs. Explicit ACL Inheritance**:
   - `create mask` / `directory mask`: Bitwise `AND` masks applied to incoming creation mode bits requested by the client.
   - `force create mode` / `force directory mode`: Bitwise `OR` masks enforcing mandatory permission bits regardless of client requests.
   - `inherit permissions` vs. `inherit acls`: `inherit permissions` copies POSIX permissions from the parent directory; `inherit acls` uses native POSIX ACLs (`setfacl`/`getfacl`) to propagate Default ACL entries down the path hierarchy.
3. **VFS Layer (Virtual File System)**: Samba executes file operations through a modular VFS pipeline. Modules placed in `vfs objects` are executed sequentially from left to right for incoming operations, and right to left for outgoing responses. Order matters critically (e.g., `catia fruit streams_xattr` for macOS compatibility or `shadow_copy2 full_audit` for snapshotting and enterprise compliance logging).

---

## Guided Exercises

---

### Exercise 1: Advanced POSIX & Windows ACL Mapping with Mask and Inheritance Directives

#### Scenario
You are designing a secure, high-concurrency engineering data share `/srv/samba/engineering` on a Linux server. The requirement states that all newly created files must be strictly readable and writable by the file owner and the group `eng-team`, but forbidden to others (`0660` for files, `0770` for directories). You must also ensure native Windows ACL propagation is enabled via Extended Attributes (`user.NTACL`).

#### Step 1: Create the directory structure and set base POSIX ownership
```bash
sudo mkdir -p /srv/samba/engineering
sudo groupadd -g 2001 eng-team
sudo chown -R root:eng-team /srv/samba/engineering
sudo chmod 2770 /srv/samba/engineering
```
*Expected Output:*
```text
(No output returned on success; verify with ls -ld /srv/samba/engineering)
drwxr-sr-x 2 root eng-team 4096 Aug  6 12:00 /srv/samba/engineering
```

#### Step 2: Ensure filesystem support for extended attributes
Verify that extended attributes are enabled on the filesystem housing `/srv/samba/engineering`:
```bash
sudo getfattr -d /srv/samba/engineering
```
*Expected Output:*
```text
# file: srv/samba/engineering
```
*(If no error is returned, extended attributes are active. On XFS and ext4 with modern kernels, `user_xattr` is active by default).*

#### Step 3: Configure `/etc/samba/smb.conf` with explicit inheritance rules
Append the following production manifest to `/etc/samba/smb.conf`:

```ini
[engineering]
    comment = Engineering Team Secure Data Repository
    path = /srv/samba/engineering
    read only = no
    browseable = yes
    guest ok = no

    # Identity and Group Enforcement
    force group = eng-team
    
    # Permission Masks
    create mask = 0660
    force create mode = 0660
    directory mask = 0770
    force directory mode = 0770
    
    # POSIX & Windows ACL Inheritance Control
    inherit permissions = yes
    inherit acls = yes
    map acl inherit = yes
    
    # Enable Extended Attribute VFS for NT ACL Storage
    vfs objects = acl_xattr
    acl_xattr:ignore system acls = no
```

#### Step 4: Validate syntax with `testparm`
```bash
sudo testparm -s /etc/samba/smb.conf
```
*Expected Output:*
```text
Load smb config files from /etc/samba/smb.conf
Loaded services file OK.
Weak setup is: Operational
Server role: ROLE_STANDALONE

[engineering]
	comment = Engineering Team Secure Data Repository
	path = /srv/samba/engineering
	force group = eng-team
	read only = No
	create mask = 0660
	directory mask = 0770
	force create mode = 0660
	force directory mode = 0770
	inherit acls = Yes
	inherit permissions = Yes
	map acl inherit = Yes
	vfs objects = acl_xattr
```

#### Step 5: Reload Samba service
```bash
sudo systemctl reload smbd
```
*Expected Output:*
```text
(Silent success; check `systemctl status smbd` for active status)
```

---

#### Verification Questions — Exercise 1

1. **Question 1.1:** What is the exact mathematical operation `smbd` performs when combining the client-requested file creation mode (`requested_mode`), `create mask`, and `force create mode`?
2. **Question 1.2:** What is the technical difference between `inherit permissions = yes` and `inherit acls = yes`, and why is setting `vfs objects = acl_xattr` essential for SMB clients running Windows 11 / Windows Server 2022?

---

### Exercise 2: Granular Access Controls, Network Restrictions & Identity Delegation

#### Scenario
You need to restrict access to a financial share `[finance_audit]` located at `/srv/samba/finance`. Only users belonging to the `fin-auditors` group or explicit user `auditor1` connecting from the corporate subnet `192.168.50.0/24` or trusted host `10.10.10.15` should be granted access. Connections from `192.168.50.250` must be explicitly blocked even though it falls within the allowed subnet. Furthermore, any writes inside this share must be executed under the system identity of `fin-sysops`.

#### Step 1: Prepare system accounts and target directory
```bash
sudo groupadd fin-auditors
sudo useradd -M -s /usr/sbin/nologin fin-sysops
sudo useradd -M -s /usr/sbin/nologin auditor1
sudo mkdir -p /srv/samba/finance
sudo chown -R fin-sysops:fin-auditors /srv/samba/finance
sudo chmod 0770 /srv/samba/finance
```

#### Step 2: Configure `/etc/samba/smb.conf` for network and user restrictions
Add the following stanza to `/etc/samba/smb.conf`:

```ini
[finance_audit]
    comment = Financial Audit Storage - Strictly Confidential
    path = /srv/samba/finance
    browseable = yes
    read only = no
    guest ok = no

    # Host-based Network Access Controls
    hosts allow = 192.168.50. 10.10.10.15 EXCEPT 192.168.50.250
    hosts deny = ALL

    # User and Group Access Restrictions
    valid users = @fin-auditors, auditor1
    invalid users = root, guest, anonymous
    write list = @fin-auditors, auditor1

    # Identity Delegation / Impersonation
    force user = fin-sysops
    force group = fin-auditors
```

#### Step 3: Test host restriction logic using `testparm`
`testparm` allows evaluating `hosts allow` / `hosts deny` logic against hypothetical client hostname/IP combinations:
```bash
sudo testparm /etc/samba/smb.conf 192.168.50.45 client45.example.com
```
*Expected Output:*
```text
Load smb config files from /etc/samba/smb.conf
Loaded services file OK.
...
Allow connection from 192.168.50.45 (192.168.50.45) to finance_audit
```

Now test against the restricted IP (`192.168.50.250`):
```bash
sudo testparm /etc/samba/smb.conf 192.168.50.250 client250.example.com
```
*Expected Output:*
```text
Load smb config files from /etc/samba/smb.conf
Loaded services file OK.
...
Deny connection from 192.168.50.250 (192.168.50.250) to finance_audit
```

---

#### Verification Questions — Exercise 2

1. **Question 2.1:** In Samba evaluation order, if an IP address matches both a `hosts allow` pattern and a `hosts deny` pattern (or an explicit `EXCEPT` clause), which directive takes precedence?
2. **Question 2.2:** What are the security and auditing implications of using `force user = fin-sysops` on a multi-user Samba share?

---

### Exercise 3: VFS Module Pipeline Architecture & Advanced File Hiding

#### Scenario
Enterprise compliance requires auditing all write/delete SMB operations on a public legal archive `/srv/samba/legal`. In addition, deleted files must not be immediately unlinked; instead, they must be redirected to a hidden `.recycle` directory inside the share. Temporary files ending in `.tmp`, `.bak`, or starting with `~$` (Office temporary lockfiles) must be blocked from upload (`veto files`). Files starting with a dot (`.`) must be hidden from normal directory listings.

#### Step 1: Create share path and recycle bin infrastructure
```bash
sudo mkdir -p /srv/samba/legal/.recycle
sudo chmod 1777 /srv/samba/legal/.recycle
sudo chown -R root:domain_users /srv/samba/legal 2>/dev/null || sudo chown -R root:nogroup /srv/samba/legal
sudo chmod 0775 /srv/samba/legal
```

#### Step 2: Configure `/etc/samba/smb.conf` with VFS Chain and Veto Filters
Add the `[legal_archive]` share configuration:

```ini
[legal_archive]
    comment = Legal Document Repository with Compliance Auditing
    path = /srv/samba/legal
    read only = no
    browseable = yes
    guest ok = no

    # File Hiding & Exclusion Masks
    hide dot files = yes
    hide unreadable = yes
    veto files = /*.tmp/*.bak/~$*/
    delete veto files = yes
    dont descend = /.recycle

    # VFS Module Chain (Evaluated Left to Right)
    vfs objects = full_audit recycle

    # VFS: full_audit Configuration
    full_audit:prefix = %u|%I|%m|%S
    full_audit:facility = LOCAL7
    full_audit:priority = NOTICE
    full_audit:success = pwrite unlink rename mkdir rmdir
    full_audit:failure = all

    # VFS: recycle Configuration
    recycle:repository = .recycle
    recycle:keeptree = yes
    recycle:versions = yes
    recycle:touch = yes
    recycle:maxsize = 0
    recycle:exclude = *.tmp, *.temp, *.bak
    recycle:excludedir = /tmp, /temp
```

#### Step 3: Configure Rsyslog to capture Samba VFS Audit logs
Append syslog routing for `LOCAL7` in `/etc/rsyslog.d/45-samba-audit.conf`:
```bash
echo "local7.notice /var/log/samba/vfs_audit.log" | sudo tee /etc/rsyslog.d/45-samba-audit.conf
sudo systemctl restart rsyslog
sudo systemctl reload smbd
```

#### Step 4: Validate VFS execution with real client operations
Simulate a file creation and deletion via `smbclient`:
```bash
smbclient //localhost/legal_archive -U "auditor1%Password123" -c "put /etc/issue testdoc.txt; rm testdoc.txt"
```
*Expected Output:*
```text
putting file /etc/issue as \testdoc.txt (0.2 kb/s) (average 0.2 kb/s)
rm-ing file \testdoc.txt
```

Verify that `testdoc.txt` moved into `.recycle` instead of being destroyed:
```bash
ls -la /srv/samba/legal/.recycle/
```
*Expected Output:*
```text
total 12
drwxrwxrwt 2 root     nogroup 4096 Aug  6 12:15 .
drwxr-xr-x 3 root     nogroup 4096 Aug  6 12:15 ..
-rw-r--r-- 1 auditor1 nogroup   26 Aug  6 12:15 testdoc.txt
```

Inspect audit log file:
```bash
sudo tail -n 5 /var/log/samba/vfs_audit.log
```
*Expected Output:*
```text
Aug 6 12:15:02 server smbd_audit: auditor1|127.0.0.1|localhost|legal_archive|pwrite|ok|testdoc.txt
Aug 6 12:15:02 server smbd_audit: auditor1|127.0.0.1|localhost|legal_archive|unlink|ok|testdoc.txt
```

---

#### Verification Questions — Exercise 3

1. **Question 3.1:** What happens when an SMB client attempts to create or upload a file matching the pattern defined in `veto files = /*.tmp/*.bak/~$*/`? How does this differ from `hide files`?
2. **Question 3.2:** If `vfs objects = shadow_copy2 full_audit recycle` is configured, in what order are `pwrite` calls processed during file save operations, and what happens if `full_audit` is listed AFTER `recycle`?

---

### Exercise 4: Enterprise CUPS Printing Integration & Spooler Mechanics

#### Scenario
You are integrating an enterprise Linux print server into an Active Directory / SMB environment. Samba must expose all local Common Unix Printing System (CUPS) printers automatically, provide point-and-print Windows printer driver distribution through the `[print$]` share, and disable RPC Spoolss architecture if driver downloading is managed out-of-band to save daemon memory resources.

#### Step 1: Global Samba Printing Configuration in `/etc/samba/smb.conf`
Modify the `[global]` section and append `[printers]` and `[print$]` shares:

```ini
[global]
    workgroup = CORPORATE
    server string = Enterprise Print Server
    security = user

    # CUPS Integration Mechanics
    printing = cups
    printcap name = cups
    load printers = yes
    cups connection timeout = 30
    
    # Disable Spoolss RPC service if Point-and-Print is disabled (Optional performance tweak)
    # disable spoolss = yes

[printers]
    comment = All Network Printers
    path = /var/spool/samba
    browseable = no
    guest ok = no
    writable = no
    printable = yes
    create mask = 0700

[print$]
    comment = Windows Printer Driver Repository (Point-and-Print)
    path = /var/lib/samba/printers
    browseable = yes
    read only = yes
    guest ok = no
    write list = root, @lpadmin, "@CORPORATE\Domain Admins"
```

#### Step 2: Create required spool and printer driver directories
```bash
sudo mkdir -p /var/spool/samba
sudo chmod 1777 /var/spool/samba
sudo mkdir -p /var/lib/samba/printers/{W32X86,x64,COLOR}
sudo chown -R root:lpadmin /var/lib/samba/printers
sudo chmod -R 0775 /var/lib/samba/printers
```

#### Step 3: Verify printers loaded by Samba
```bash
rpcclient -U "auditor1%Password123" localhost -c 'enumprinters'
```
*Expected Output:*
```text
flags:[0x800000]
name:[\\localhost\PDF_Printer]
description:[\\localhost\PDF_Printer,PDF_Printer,Generic CUPS PDF Printer]
comment:[Generic CUPS PDF Printer]
```

---

#### Verification Questions — Exercise 4

1. **Question 4.1:** What is the specific role of the `disable spoolss = yes` directive, and what feature set is lost on Windows clients when this parameter is enabled?
2. **Question 4.2:** Why must the directory path referenced in `[printers]` (e.g. `/var/spool/samba`) have the sticky bit (`1777`) set in POSIX mode permissions?

---

### Exercise 5: Advanced Diagnostic & Live Telemetry Tools

#### Scenario
Users report that files on the `[engineering]` share are locked and cannot be edited. As a Senior SRE, you must inspect active SMB sessions, determine open file locks (byte-range locks and opportunistic locks / leases), inspect NetBIOS name resolutions, and query IPC$ RPC endpoints directly.

#### Step 1: Inspect active connections, shares, and processes with `smbstatus`
Run `smbstatus` with specific telemetry flags:

1. **View connected users and protocol versions:**
```bash
sudo smbstatus -b
```
*Expected Output:*
```text
Samba version 4.19.5-Ubuntu
PID     Username     Group        Machine               Protocol Version         Encryption           Signing              
--------------------------------------------------------------------------------------------------------------------------------
12435   auditor1     eng-team     192.168.50.45 (ipv4:192.168.50.45:54322) SMB3_11                  -                    AES-128-GMAC
```

2. **View connected shares:**
```bash
sudo smbstatus -S
```
*Expected Output:*
```text
Service      pid     Machine       Connected at                     Encryption                   Signing              
--------------------------------------------------------------------------------------------------------------------
engineering  12435   192.168.50.45 Thu Aug  6 12:20:11 2026 EDT     -                            AES-128-GMAC
```

3. **View locked files and oplocks:**
```bash
sudo smbstatus -L
```
*Expected Output:*
```text
Locked files:
Pid          User(ID)   DenyMode   Access      R/W        Oplock           SharePath                    Name   Time
------------------------------------------------------------------------------------------------------------------
12435        1001       DENY_NONE  0x120089    RDWR       EXCLUSIVE+BATCH  /srv/samba/engineering      cad_v2.dwg   Thu Aug 6 12:22:01 2026
```

#### Step 2: Interrogate server RPC services with `rpcclient`
Query server identity, domain information, and active shares using RPC calls over IPC$:
```bash
rpcclient -U "auditor1%Password123" localhost -c 'srvinfo; netshareenumall'
```
*Expected Output:*
```text
	localhost        Wk Sv Prq Unx NT SNT Server Message Block
	platform_id     : 500
	os version      : 6.1
	server type     : 0x809a03

netshareenumall response:
	netname: engineering
		type: 0x0
		remark: Engineering Team Secure Data Repository
	netname: IPC$
		type: 0x3
		remark: IPC Service (Server Message Block)
```

#### Step 3: Validate live share state with `netconf` (Registry-based configuration check)
If Samba is managed via registry-backed configuration (`config backend = registry`), use `net`:
```bash
sudo net conf list
```
*Expected Output:*
```text
[engineering]
	comment = Engineering Team Secure Data Repository
	path = /srv/samba/engineering
	read only = no
	force group = eng-team
```

---

#### Verification Questions — Exercise 5

1. **Question 5.1:** A user cannot save a file because of an `EXCLUSIVE+BATCH` oplock held by a crashed client PID. What command can an administrator execute to terminate that specific Samba process and clear the lock without restarting `smbd` entirely?
2. **Question 5.2:** What information does `smbstatus -u` provide compared to `smbstatus -L`?

---

## <details><summary>Answers & Deep Technical Explanations</summary>

### Exercise 1 Answers

* **1.1:** The effective permission mode bitmask for a newly created file is calculated as:
  $$\text{Effective Mode} = ((\text{Requested Mode} \mathbin{\&} \text{create mask}) \mid \text{force create mode})$$
  For example, if a client requests `0666` and the parameters are `create mask = 0660` and `force create mode = 0660`:
  $$(0666 \mathbin{\&} 0660) \mid 0660 = 0660 \mid 0660 = 0660 \quad (\texttt{rw-rw----})$$
  This guarantees that bitwise `AND` strips unapproved permissions (e.g., `others` bits), and bitwise `OR` forcefully applies mandatory permissions.

* **1.2:** 
  - `inherit permissions = yes` forces newly created files/directories to inherit their POSIX permission bits (`rwx`) directly from the parent directory's mode bits, ignoring the client's requested mode or `umask`.
  - `inherit acls = yes` ensures that if a parent directory has POSIX Access Control Lists (Extended ACLs defined via `setfacl`), new files inherit those Default ACL entries natively.
  - `vfs objects = acl_xattr` is critical for modern Windows clients because Windows OS uses NT Security Descriptors (DACLs/SACLs, SIDs, Inheritance Flags). Linux standard POSIX permissions (`rwxrwxrwx`) cannot represent complex Windows permission models (e.g., *Deny* rules, *Change Permissions*, *Take Ownership*). `vfs_acl_xattr` intercepts Windows ACL requests and serializes the complete binary NT ACL inside the `user.NTACL` extended attribute on the filesystem.

---

### Exercise 2 Answers

* **2.1:** Samba evaluates access controls in a strict multi-tier hierarchy:
  1. `hosts allow` is evaluated first. If `hosts allow` is specified, ONLY client IPs matching the list are permitted; all others are implicitly denied.
  2. If an explicit `EXCEPT` clause is included within `hosts allow` (e.g., `hosts allow = 192.168.50. EXCEPT 192.168.50.250`), any host matching the `EXCEPT` clause is immediately **denied**, regardless of any broader network match.
  3. `hosts deny` is evaluated next for any hosts not explicitly matched by `hosts allow`.
  Therefore, explicit `EXCEPT` conditions inside `hosts allow` take immediate precedence and reject the matching connection during SMB session setup before authentication occurs.

* **2.2:** 
  - **Security Impact:** `force user = fin-sysops` causes `smbd` to perform a process identity swap (`setuid()`) for all file system operations on that share. Regardless of which authenticated user connected (e.g., `auditor1`), all files created on disk will be owned by `fin-sysops`.
  - **Auditing Impact:** At the POSIX filesystem level, standard file ownership tracking is completely lost because all operations originate from `fin-sysops`. To maintain auditability, administrators MUST enable Samba level VFS auditing (`vfs objects = full_audit`) so that the actual SMB authenticated username (`%u`) is recorded in syslog for every I/O action.

---

### Exercise 3 Answers

* **3.1:** 
  - When a file matches `veto files`, `smbd` completely hides the existence of matching files from directory listing requests (`FIND_FIRST2` / `SMB2_GETINFO`) AND actively rejects any client request to open, create, write, or read files matching the pattern, returning an `NT_STATUS_ACCESS_DENIED` or `NT_STATUS_OBJECT_NAME_NOT_FOUND` error.
  - In contrast, `hide files` only sets the DOS `DOS_ATTRIBUTE_HIDDEN` attribute bit on matching files. Windows clients will still see the files if "Show Hidden Files" is enabled in File Explorer, and clients can open and read/write them normally.
  - If `delete veto files = yes` is set along with `veto files`, deleting a directory containing vetoed files will force Samba to recursively delete the vetoed files inside it; otherwise, directory deletion fails because POSIX `rmdir` fails on non-empty directories.

* **3.2:** 
  - VFS modules operate as a stacked pipeline. For **incoming requests** (client $\rightarrow$ server write), modules execute **left-to-right**: `shadow_copy2` $\rightarrow$ `full_audit` $\rightarrow$ `recycle` $\rightarrow$ POSIX filesystem.
  - If `full_audit` is placed AFTER `recycle`, when a file deletion occurs (`unlink`), `recycle` intercepts the call, renames/moves the file to `.recycle/`, and returns success to the stack without calling the underlying OS `unlink()`. As a result, `full_audit` (positioned after `recycle`) would either log the operation incorrectly or fail to register a native `unlink` syscall event. Hence, audit modules must always be placed prior to modification/redirection modules in the `vfs objects` chain.

---

### Exercise 4 Answers

* **4.1:** 
  - `disable spoolss = yes` completely turns off Samba's RPC Spoolss pipe service (`\PIPE\spoolss`). 
  - Enabling this option saves daemon memory and CPU cycles on dedicated file servers that do not manage printing.
  - **Feature Lost:** Disabling Spoolss breaks Windows Point-and-Print features. Windows clients will no longer be able to automatically query, download, or update printer drivers over SMB from `[print$]`, nor will they receive print queue telemetry or spooler status notifications via native Windows RPC APIs. Printing can only occur if drivers are pre-installed manually on the Windows clients.

* **4.2:** 
  - When print jobs are sent over SMB, `smbd` acts on behalf of the authenticated SMB user and writes temporary spool files into the directory specified by `path` in `[printers]` (e.g., `/var/spool/samba`).
  - Because multiple distinct users print concurrently, all users need write access to create temporary files in this shared folder (`0777`).
  - The **Sticky Bit (`1777` / `chmod +t`)** is mandatory to prevent unprivileged users from deleting, modifying, or overwriting temporary print spool files created by other users before CUPS finishes processing them.

---

### Exercise 5 Answers

* **5.1:** 
  An administrator can terminate the specific process holding the file lock using the `kill` command targeted at the `PID` revealed in `smbstatus -L` or `smbstatus -b`:
  ```bash
  sudo kill -15 12435
  ```
  Samba's parent daemon monitors child `smbd` process termination, cleans up shared memory locks in `locks.tdb` / `locking.tdb`, releases byte-range/oplocks, and allows other SMB clients to access the file immediately without needing to restart the master `smbd` daemon.

* **5.2:** 
  - `smbstatus -u` (or `smbstatus -b`) provides **Session/User-level Telemetry**: It reports active authenticated user sessions, client IP addresses/hostnames, protocol negotiation dialect (e.g., `SMB3_11`), encryption status (`AES-128-GCM`), transport signing algorithms, and individual child process IDs (`PIDs`).
  - `smbstatus -L` provides **Locking & Lease Telemetry**: It reports open file descriptors across all shares, access rights (`0x120089`), deny modes, byte-range locks, and SMB Opportunistic Lock (Oplock) states (`EXCLUSIVE`, `BATCH`, `LEASE`).

---

</details>