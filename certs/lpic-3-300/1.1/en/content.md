# LPIC-3 Exam 300-300 (v3.0) — Topic 301: Samba Basics (Weight: 20)
## Advanced Production Engineering & Platform Architecture Guide

---

## 1. Production Architectural Motivation & Problem Statement

### 1.1 The Cross-Platform Heterogeneous Enterprise Problem
In modern enterprise data centers and hybrid-cloud infrastructures, POSIX-compliant operating systems (Linux, UNIX) and NT-based operating systems (Windows Server, Windows Workstations) must share file storage and user identities under a unified security architecture.

Linux and Windows enforce fundamentally different access control paradigms:
* **POSIX Model:** 3-tier permission mask (`owner`, `group`, `other` with `rwx`) combined with POSIX UIDs (32-bit unsigned integers) and GIDs.
* **Windows NT Model:** Security Descriptors containing Discretionary Access Control Lists (DACLs) composed of Access Control Entries (ACEs), indexed by Security Identifiers (SIDs, e.g., `S-1-5-21-...`).

Samba bridges this gap by acting as a high-performance, open-source implementation of the Server Message Block (SMB) / Common Internet File System (CIFS) protocols and Microsoft Active Directory (AD) protocols. It allows Linux hosts to function as:
1. **Active Directory Domain Controller (AD DC):** Providing Kerberos KDC, LDAP server, SYSVOL replication, and DNS capabilities.
2. **Domain Member Server:** Joining an existing Active Directory or NT4 Domain to serve SMB shares while honoring central identity management via `winbindd`.
3. **Standalone File/Print Server:** Managing localized SMB authentication through TDB/Passdb backends.

```
                  +-------------------------------------------------------+
                  |               Windows Workstations / SMB Clients      |
                  +-------------------------------------------------------+
                                              |
                                              | SMB3.1.1 (TCP 445)
                                              v
+-----------------------------------------------------------------------------------+
| Linux Enterprise Storage Node (Samba 4.x)                                         |
|                                                                                   |
|  +---------------------+   +-----------------------+   +-----------------------+  |
|  |     smbd daemon     |   |     winbindd daemon   |   |      nmbd daemon      |  |
|  | (SMB/CIFS & RPCs)   |   |  (NSS/PAM & IDMap)    |   |  (NetBIOS/WINS)       |  |
|  +---------------------+   +-----------------------+   +-----------------------+  |
|             |                          |                           |              |
|             +-------------+------------+                           |              |
|                           |                                        |              |
|                           v                                        v              |
|  +-------------------------------------------------+    +----------------------+  |
|  | VFS Layer (acl_xattr, fruit, shadow_copy2)      |    | UDP 137/138          |  |
|  +-------------------------------------------------+    +----------------------+  |
|                           |                                                       |
|                           v                                                       |
|  +-------------------------------------------------+                              |
|  | File System (ext4 / xfs / zfs) with EA (`user.*`) |                              |
|  +-------------------------------------------------+                              |
+-----------------------------------------------------------------------------------+
```

### 1.2 Architectural Challenges in Production
* **Concurrency and File Locking:** SMB clients mandate strict lock semantics (Byte-Range Locking, Opportunistic Locking / Oplocks, and SMB2/3 Leases). Samba must synchronize these Windows lock semantics with Linux kernel POSIX file locks (`fcntl`/`flock`) without deadlocking the file system.
* **Identity Mapping Overhead:** SIDs must map dynamically or deterministically to Linux UIDs/GIDs in high-concurrency environments. Bad ID mapping causes unresolvable permissions, security breaches, or degraded I/O throughput due to cache misses.
* **Extended Attributes (EA) & ACL Translation:** Windows NTFS permissions require arbitrary ACE entries (Allow/Deny per user/group with precise flags). Samba translates NT DACLs into raw extended attributes stored in `user.NTACL` metadata on POSIX filesystems via the `vfs_acl_xattr` module.

---

## 2. Technical Architecture & Deep Trade-off Comparisons

### 2.1 Core Samba Daemons Architecture

| Daemon Process | Role & Responsibilities | Port Bindings | Process Model |
| :--- | :--- | :--- | :--- |
| **`smbd`** | Handles SMB/CIFS file sharing, printing, named pipes, and MS-RPC services (`srvsvc`, `lsarpc`, `samr`). Responsible for authentication, ACL evaluation, and file locking. | TCP 445 (Direct SMB over TCP), TCP 139 (NetBIOS Session) | Multi-process model. A parent master daemon listens for incoming connections and forks a dedicated child process per connected client socket. |
| **`nmbd`** | Manages NetBIOS Name Service (NBNS), WINS client/server requests, and local subnet master browser elections. (Legacy protocol, disabled in modern pure-Active Directory environments). | UDP 137 (NetBIOS Name), UDP 138 (NetBIOS Datagram) | Single-threaded event loop per subnet socket. |
| **`winbindd`** | Resolves Windows AD/NT Domain names, users, and groups into UNIX NSS (`/etc/nsswitch.conf`) identities. Handles PAM authentication tokens, Kerberos ticket acquisition, and ID mapping. | UNIX Domain Socket (`/var/run/samba/winbindd/pipe`) | Multi-threaded / worker-pool model to asynchronously process NSS and PAM lookups. |
| **`samba`** | The umbrella binary used **only** when running Samba as an Active Directory Domain Controller (AD DC). Spawns integrated LDAP, Kerberos KDC, DNS, and internal IPC processes. | TCP/UDP 88 (Kerberos), TCP/UDP 389 (LDAP), TCP 636 (LDAPS), TCP 3268/3269 (Global Catalog) | Process supervisor model spawning sub-daemons (`kdc`, `ldap`, `dns`). |

---

### 2.2 Database Engine Internals: TDB vs. LDB

Samba uses custom lightweight databases optimized for ultra-low latency and local IPC rather than relying on external SQL engines.

```
                    +----------------------------------------+
                    |          Samba State Engines           |
                    +----------------------------------------+
                                 |              |
                +----------------+              +----------------+
                |                                                |
                v                                                v
  +---------------------------+                    +---------------------------+
  |    TDB (Trivial Database) |                    |    LDB (LDAP Database)    |
  +---------------------------+                    +---------------------------+
  | - Key/Value Binary Store  |                    | - Object-Oriented Schema  |
  | - Lock per Hash Chain     |                    | - Index-backed Lookups    |
  | - Dynamic IPC/State Cache |                    | - AD DC Directory Store   |
  +---------------------------+                    +---------------------------+
  | Examples:                 |                    | Examples:                 |
  | - locking.tdb             |                    | - sam.ldb                 |
  | - passdb.tdb              |                    | - secrets.ldb             |
  | - gencache.tdb            |                    | - idmap.ldb               |
  +---------------------------+                    +---------------------------+
```

1. **TDB (Trivial Database):**
   * **Mechanism:** Memory-mapped (`mmap`) key-value binary database supporting concurrent multiple readers and single writers via record-level hash-chain locking.
   * **Production Databases:**
     * `locking.tdb`: Active byte-range locks and oplock states (Volatile).
     * `brlock.tdb`: Byte-range locks repository (Volatile).
     * `gencache.tdb`: Generic cache for SID-to-name resolutions and DNS results (Volatile).
     * `passdb.tdb`: Local SAM user database when `passdb backend = tdbsam` (Persistent).
     * `secrets.tdb`: Local machine password, domain trust secrets, and private keys (Persistent).

2. **LDB (LDAP Database):**
   * **Mechanism:** Embedded LDAP-like database built on top of TDB. Supports hierarchical schema structures, indexing, data manipulation via LDIF files, and rich LDAP search filters.
   * **Production Databases (AD DC context):**
     * `sam.ldb`: Active Directory Security Account Manager database (Users, Groups, Computers, OUs).
     * `secrets.ldb`: Kerberos keys and domain trust secrets.

---

### 2.3 Comprehensive Technical Trade-off Matrices

#### Table 1: Samba Security Modes (`security = ...`)

| Security Mode | Description | Authentication Mechanism | Use-Case Scenario | Pros | Cons |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`user`** (Default) | Client authenticates explicitly with a username/password against local Samba backends (`passdb.tdb`) or remote domain controllers via RPC. | NTLMv2 or Kerberos validated locally or proxied. | Standalone file servers, isolated DMZ nodes, or Domain Members. | High isolation; independent of Active Directory availability for local users. | Scalability overhead for user management across multiple servers without AD. |
| **`ads`** | Native Active Directory Domain Member mode. Samba acts as an integrated kerberized machine account in an AD forest. | Kerberos v5 (SPNEGO ticket) with fallback to NTLMv2. | Enterprise Domain Member file servers integrated with MS Active Directory. | Seamless single sign-on (SSO), centralized ACL policy enforcement, full AD group evaluation. | Strict dependency on DNS, NTP clock skew (<5s), and Active Directory availability. |
| **`domain`** *(Deprecated)* | Samba joins an old NT4-style domain using SamSync RPCs. | Remote RPC passthrough to NT Domain Controller. | Legacy infrastructure integration. | Compatible with legacy NT4 DCs. | Deprecated in Samba 4.x; lacks Kerberos SSO support and modern security enforcement. |
| **`server` / `share`** *(Removed)* | Obsolete legacy Samba 2.x/3.x modes. | Plaintext / basic password challenge per share or per server session. | Unsupported. | None. | Severe security vulnerabilities; completely removed in modern Samba 4 releases. |

#### Table 2: SMB Protocol Dialects Comparison

| Protocol Dialect | Introduced In | Maximum Buffer Size / Features | Security Improvements | Performance / Scale Impact |
| :--- | :--- | :--- | :--- | :--- |
| **SMB 1.0 (CIFS)** *(Disabled by default)* | Windows NT 3.1 / Samba 1.x | 64 KB message size. Synchronous command execution per packet. | Plaintext / NTLMv1 capabilities. Extremely vulnerable to MITM & relay attacks. | Terrible WAN performance due to extreme protocol chattiness. Deprecated & disabled in modern Samba (`server min protocol = SMB2_10`). |
| **SMB 2.1** | Windows 7 / Samba 3.5 | Large MTU support (1 MB). Command compounding (combining multiple requests into one packet). | Mandatory signing capability (HMAC-SHA256), resilient handles. | High performance improvement over gigabit networks; reduced network round-trips. |
| **SMB 3.02** | Windows 8.1 / Samba 4.1 | SMB Multichannel, Directory Leasing, BranchCache v2. | AES-128-CCM end-to-end payload encryption. SHA-512 integrity hashes. | Massive throughput scaling across multiple NICs (Multichannel). Zero overhead security for cross-site links. |
| **SMB 3.1.1** *(Modern Default)* | Windows 10 / Samba 4.3+ | Pre-Authentication Integrity validation, AES-128-GCM cipher suite selection. | Protection against dialect downgrade MITM attacks using SHA-512 pre-auth hashing. | Optimal network performance, direct RDMA support (SMB Direct ready), maximum payload cipher security. |

#### Table 3: Identity Mapping Backends (`idmap config`)

| IDMap Backend | Mechanism | Configuration Complexity | UID/GID Consistency across Multiple Servers | Ideal Operating Environment |
| :--- | :--- | :--- | :--- | :--- |
| **`idmap_rid`** | Algorithmic mapping: `UID = RID + base_rid`. | Low | **Guaranteed 100% consistent** across all Linux nodes sharing the same `smb.conf` base configuration. | Multi-node enterprise file clusters without custom Unix attributes in AD. |
| **`idmap_autorid`** | Dynamic range allocation: Assigns ID ranges to domains automatically as they are encountered. | Very Low | Local to node state stored in `idmap2.tdb`. Needs centralized TDB synchronization across cluster nodes. | Branch offices with multiple untrusted domains. |
| **`idmap_ad`** | Reads RFC2307 attributes (`uidNumber`, `gidNumber`) explicitly defined in Active Directory objects. | High | **100% consistent** if AD schema contains Unix Attributes for all security principals. | Environments with strict centralized Unix/POSIX governance managed inside AD. |
| **`idmap_tdb`** | Local dynamic allocation stored in local `idmap.tdb`. | Zero (Default) | **Inconsistent** across multiple servers. UID for the same Windows SID will differ on every node. | Single, isolated standalone Samba server. **Forbidden in clusters**. |

---

## 3. Production Infrastructure Manifests & Complete Configurations

### 3.1 Production Active Directory Domain Member File Server (`/etc/samba/smb.conf`)

This configuration enforces SMB3.1.1 minimum constraints, VFS macOS extensions, shadow copies, performance tuning, and deterministic `idmap_rid` configuration.

```ini
# /etc/samba/smb.conf
# Production Enterprise Domain Member File Server Configuration

[global]
   # ------------------------------------------------------------------
   # Network & Identity Definitions
   # ------------------------------------------------------------------
   workgroup = CORP
   realm = CORP.ENTERPRISE.INTERNAL
   netbios name = FILESRV01
   server string = Enterprise High-Performance Storage Node %v

   # Security & Domain Integration Mode
   security = ads
   role = member server
   encrypt passwords = yes

   # ------------------------------------------------------------------
   # Protocol Bounds & Encryption Security Enforcement
   # ------------------------------------------------------------------
   # Disable insecure legacy SMB1 (Mitigates WannaCry / EternalBlue vectors)
   server min protocol = SMB2_10
   server max protocol = SMB3_11
   client min protocol = SMB2_10
   client max protocol = SMB3_11

   # Security Hardening Options
   server smb encrypt = desired
   client smb encrypt = desired
   client signing = mandatory
   server signing = mandatory
   smb ports = 445

   # ------------------------------------------------------------------
   # Winbind & Identity Mapping (idmap_rid implementation)
   # ------------------------------------------------------------------
   winbind enum users = no
   winbind enum groups = no
   winbind use default domain = yes
   winbind refresh tickets = yes
   winbind offline logon = yes
   winbind nested groups = yes

   # Default Local Allocations (Fallback range for non-domain users)
   idmap config * : backend = tdb
   idmap config * : range = 10000-19999

   # Primary Active Directory Domain Range Allocation (Deterministic Mapping)
   idmap config CORP : backend = rid
   idmap config CORP : range = 20000-999999

   # Template Shell and Home directories for NSS
   template shell = /bin/bash
   template homedir = /home/%D/%U

   # ------------------------------------------------------------------
   # Performance, Socket & Threading Optimizations
   # ------------------------------------------------------------------
   aio read size = 1
   aio write size = 1
   use sendfile = yes
   min receivefile size = 16384
   getwd cache = yes
   max xmit = 65536

   # Disable NetBIOS browsing overhead (Pure DNS/AD Architecture)
   disable netbios = yes
   smb ports = 445
   dns proxy = no

   # ------------------------------------------------------------------
   # Logging & Diagnostics
   # ------------------------------------------------------------------
   log level = 1 auth:3 winbind:3
   log file = /var/log/samba/log.%m
   max log size = 50000
   logging = file

   # ------------------------------------------------------------------
   # VFS Modules Defaults
   # ------------------------------------------------------------------
   vfs objects = acl_xattr filter_acl_extended

# ======================================================================
# Share Definitions
# ======================================================================

[Engineering]
   comment = Enterprise Engineering File Share
   path = /srv/samba/shares/engineering
   read only = no
   browseable = yes
   guest ok = no
   valid users = @"CORP\Engineering_Group" @"CORP\Domain Admins"

   # Extended Attributes & NT ACL Persistence
   vfs objects = acl_xattr fruit streams_xattr shadow_copy2 full_audit

   # Apple OS X Client Optimizations (vfs_fruit)
   fruit:aapl = yes
   fruit:metadata = stream
   fruit:model = MacSamba
   fruit:posix_rename = yes
   fruit:veto_appledouble = no
   fruit:wipe_intentionally_left_blank_rf = yes
   fruit:delete_empty_adfiles = yes

   # Shadow Copy Integration (vfs_shadow_copy2)
   shadow:snapdir = .snapshots
   shadow:format = @GMT-%Y.%m.%d-%H.%M.%S
   shadow:sort = desc
   shadow:localtime = yes

   # Auditing Engine (vfs_full_audit)
   full_audit:prefix = %u|%I|%m|%S
   full_audit:success = mkdir rmdir read write rename unlink pwrite pwrite_send
   full_audit:failure = none
   full_audit:facility = LOCAL7
   full_audit:priority = NOTICE

   # File Locking & Permission Masks
   inherit acls = yes
   inherit permissions = yes
   map acl inherit = yes
   store dos attributes = yes

[Finance]
   comment = Restricted Finance Data Share
   path = /srv/samba/shares/finance
   read only = no
   browseable = no
   guest ok = no
   valid users = @"CORP\Finance_Group"
   create mask = 0660
   directory mask = 0770
   force group = "CORP\Finance_Group"
   vfs objects = acl_xattr streams_xattr
```

---

### 3.2 System Name Service Switch Configuration (`/etc/nsswitch.conf`)

Enables POSIX user and group lookups to consult `winbind` after local files.

```ini
# /etc/nsswitch.conf
passwd:         files winbind
group:          files winbind
shadow:         files
gshadow:        files

hosts:          files dns mdns4_minimal [NOTFOUND=return]
networks:       files

protocols:      db files
services:       db files
ethers:         db files
rpc:            db files

netgroup:       nis
```

---

### 3.3 Systemd Hardened Service Unit Definitions

#### `smbd.service` Override File (`/etc/systemd/system/smbd.service.d/override.conf`)

```ini
[Unit]
Description=Samba SMB Daemon (Hardened Production Unit)
After=network.target network-online.target nss-lookup.target winbindd.service
Wants=network-online.target
Requires=winbindd.service

[Service]
Type=notify
LimitNOFILE=163840
PIDFile=/run/samba/smbd.pid
ExecStart=/usr/sbin/smbd --foreground --no-process-group $SMBDOPTIONS
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s

# Security Hardening Directives
ProtectSystem=full
ProtectHome=read-only
ReadWritePaths=/var/log/samba /var/lib/samba /var/cache/samba /run/samba /srv/samba/shares
PrivateTmp=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_SETUID CAP_SETGID CAP_DAC_OVERRIDE CAP_CHOWN CAP_FOWNER CAP_SYS_ADMIN

[Install]
WantedBy=multi-user.target
```

#### `winbindd.service` Override File (`/etc/systemd/system/winbindd.service.d/override.conf`)

```ini
[Unit]
Description=Samba Winbind Daemon
After=network.target network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=notify
PIDFile=/run/samba/winbindd.pid
ExecStart=/usr/sbin/winbindd --foreground --no-process-group $WINBINDOPTIONS
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s

# Security Hardening Directives
ProtectSystem=full
ReadWritePaths=/var/log/samba /var/lib/samba /var/cache/samba /run/samba /var/run/samba

[Install]
WantedBy=multi-user.target
```

---

### 3.4 Production Firewall Configuration Commands

#### UFW (Ubuntu / Debian)
```bash
# Allow Direct SMB over TCP
$ sudo ufw allow 445/tcp comment 'Samba Direct SMB'

# Allow NetBIOS Services (Only if disable netbios = no)
$ sudo ufw allow 137/udp comment 'Samba NetBIOS Name Service'
$ sudo ufw allow 138/udp comment 'Samba NetBIOS Datagram Service'
$ sudo ufw allow 139/tcp comment 'Samba NetBIOS Session Service'

# Reload Firewall Rules
$ sudo ufw reload
```

#### Firewalld (RHEL / Rocky Linux / Fedora)
```bash
# Add permanent samba service definition to active zone
$ sudo firewall-cmd --permanent --add-service=samba
$ sudo firewall-cmd --reload
```

---

## 4. Production Execution: Real CLI Commands & Terminal Outputs

### 4.1 Validating Syntax with `testparm`

`testparm` parses the `smb.conf` file, verifies configuration parameters, and dumps the operational processing matrix.

```bash
$ testparm -s --suppress-prompt /etc/samba/smb.conf
```
```text
Load smb config files from /etc/samba/smb.conf
Loaded services file OK.
Weak setup is: None
Server role: ROLE_DOMAIN_MEMBER

# Section expansion options:
[global]
	client max protocol = SMB3_11
	client min protocol = SMB2_10
	client signing = required
	disable netbios = Yes
	idmap config corp : range = 20000-999999
	idmap config corp : backend = rid
	idmap config * : range = 10000-19999
	idmap config * : backend = tdb
	log level = 1 auth:3 winbind:3
	realm = CORP.ENTERPRISE.INTERNAL
	security = ADS
	server max protocol = SMB3_11
	server min protocol = SMB2_10
	server signing = required
	smb ports = 445
	workgroup = CORP
	vfs objects = acl_xattr filter_acl_extended

[Engineering]
	browseable = Yes
	comment = Enterprise Engineering File Share
	full_audit:facility = LOCAL7
	full_audit:failure = none
	full_audit:prefix = %u|%I|%m|%S
	full_audit:priority = NOTICE
	full_audit:success = mkdir rmdir read write rename unlink pwrite pwrite_send
	path = /srv/samba/shares/engineering
	read only = No
	valid users = @"CORP\Engineering_Group", @"CORP\Domain Admins"
	vfs objects = acl_xattr fruit streams_xattr shadow_copy2 full_audit
	fruit:delete_empty_adfiles = yes
	fruit:wipe_intentionally_left_blank_rf = yes
	fruit:posix_rename = yes
	fruit:model = MacSamba
	fruit:metadata = stream
	fruit:aapl = yes
```

---

### 4.2 Local SAM Passdb Management with `pdbedit`

For standalone servers (`security = user`), `pdbedit` manages the Passdb backend (`passdb.tdb`).

```bash
# Add a new local Samba user (User must already exist in /etc/passwd)
$ sudo pdbedit -a -u sreadmin -r
```
```text
new password:
retype new password:
Unix username:        sreadmin
NT username:          
Account Flags:        [U          ]
User SID:             S-1-5-21-3849204912-1029384910-482910394-1001
Primary Group SID:    S-1-5-21-3849204912-1029384910-482910394-513
Full Name:            SRE Administrator Account
Home Directory:       \\FILESRV01\sreadmin
Home Dir Drive:       
Logon Script:         
Profile Path:         \\FILESRV01\sreadmin\profile
Domain:               FILESRV01
Account must change password: No
Expected password must change: Never
```

```bash
# Verbose listing of all passdb entries
$ sudo pdbedit -L -v
```
```text
-----------------------------------------
Unix username:        sreadmin
NT username:          
Account Flags:        [U          ]
User SID:             S-1-5-21-3849204912-1029384910-482910394-1001
Primary Group SID:    S-1-5-21-3849204912-1029384910-482910394-513
Full Name:            SRE Administrator Account
Home Directory:       \\FILESRV01\sreadmin
Password last set:    Thu, 06 Aug 2026 10:15:30 EDT
Password can change:  Thu, 06 Aug 2026 10:15:30 EDT
Password must change: Never
Last logon:           N/A
Logon failure count:  0
-----------------------------------------
```

---

### 4.3 Active Directory Domain Join and Verification with `net`

```bash
# Request Kerberos ticket for AD Admin
$ kinit Administrator@CORP.ENTERPRISE.INTERNAL
```
```text
Password for Administrator@CORP.ENTERPRISE.INTERNAL:
```

```bash
# Join Active Directory domain using net ads
$ sudo net ads join -U Administrator
```
```text
Using short domain name -- CORP
Joined 'FILESRV01' to dns domain 'corp.enterprise.internal'
No DNS domain configured for filesrv01. Unable to perform DNS Update.
DNS update should be performed manually or via DHCP.
```

```bash
# Test AD Trust Connection State
$ sudo net ads testjoin
```
```text
Join is OK
```

```bash
# Display Machine Account Status in Active Directory
$ sudo net ads status
```
```text
objectGUID: 8c34f8e2-892a-4f81-a982-1b837d991c01
sAMAccountName: FILESRV01$
servicePrincipalName: HOST/FILESRV01
servicePrincipalName: HOST/filesrv01.corp.enterprise.internal
servicePrincipalName: RestrictedKrbHost/FILESRV01
servicePrincipalName: RestrictedKrbHost/filesrv01.corp.enterprise.internal
pwdLastSet: 133984920194829102
userAccountControl: 4096
```

---

### 4.4 Inspecting Runtime Samba State with `smbstatus`

`smbstatus` reads `locking.tdb` and `sessionid.tdb` to generate real-time metrics on connected clients, active protocol versions, locking states, and open handles.

```bash
$ sudo smbstatus
```
```text
Samba version 4.19.5-Ubuntu
PID     Username     Group        Machine                         Protocol Version Password Cipher Encryption Cipher 
--------------------------------------------------------------------------------------------------------------------------------
40921   jdoe         CORP\Domain  10.0.15.102 (ipv4:10.0.15.102:54821) SMB3_11           -               AES-128-GCM     

Service      pid     Machine       Connected at                     Encryption   Signing     
---------------------------------------------------------------------------------------------
Engineering  40921   10.0.15.102   Thu Aug  6 11:20:42 2026 EDT     AES-128-GCM  -           

Locked files:
Pid          User(O/U)           Uid        Gid        Mode             TCPAddr          Access Mask    Type         Oplock           EA Key             Path
----------------------------------------------------------------------------------------------------------------------------------------------------------------
40921        20015               20015      20002      RDWR             10.0.15.102      0x12019f       POSIX        LEASE(RWA)       -                  /srv/samba/shares/engineering/CAD_Schematics_v2.dwg
```

---

### 4.5 Winbind Identity Resolution Checks (`wbinfo` & `getent`)

```bash
# Check winbind ping response to DC
$ wbinfo -p
```
```text
Ping to winbindd succeeded
```

```bash
# Query AD User SID to Linux UID via idmap_rid backend
$ wbinfo -n "CORP\jdoe"
```
```text
S-1-5-21-3849204912-1029384910-482910394-1105 SID_USER (1)
```

```bash
# Convert SID to allocated Linux UID
$ wbinfo -s S-1-5-21-3849204912-1029384910-482910394-1105
```
```text
CORP\jdoe 1
```

```bash
# Verify system NSS integration via getent
$ getent passwd "CORP\jdoe"
```
```text
jdoe:*:21105:20000:John Doe:/home/CORP/jdoe:/bin/bash
```

---

### 4.6 Client Protocol Connectivity and Testing with `smbclient`

```bash
# Query available SMB shares on target host enforcing SMB3 protocol
$ smbclient -L //FILESRV01.CORP.ENTERPRISE.INTERNAL -U "CORP\jdoe" -m SMB3
```
```text
Password for [CORP\jdoe]:

	Sharename       Type      Comment
	---------       ----      -------
	Engineering     Disk      Enterprise Engineering File Share
	IPC$            IPC       IPC Service (Enterprise High-Performance Storage Node v4.19)
SMB1 trading is disabled. Suppress This Array: SMB1 disabled

Reconnecting with SMB3...
Server exit code 0
```

```bash
# Interactively connect to an encrypted share
$ smbclient //FILESRV01.CORP.ENTERPRISE.INTERNAL/Engineering -U "CORP\jdoe" -e
```
```text
Password for [CORP\jdoe]:
Try "help" to get a list of possible commands.
smb: \> ls
  .                                   D        0  Thu Aug  6 11:20:42 2026
  ..                                  D        0  Thu Aug  6 10:00:00 2026
  CAD_Schematics_v2.dwg               A  1485920  Thu Aug  6 11:15:20 2026

                524160000 blocks of size 1024. 312849200 blocks available
smb: \> quit
```

---

### 4.7 Low-Level TDB Database Inspection and Repair Tools

```bash
# Backup volatile locking database safely while smbd is running
$ sudo tdbbackup /var/lib/samba/locking.tdb
```
```text
/var/lib/samba/locking.tdb.bak : 1048576 bytes
```

```bash
# Check integrity of persistent passdb database
$ sudo tdbtool /var/lib/samba/private/passdb.tdb check
```
```text
Database integrity is OK
```

```bash
# Dump keys contained within a TDB database
$ sudo tdbdump /var/lib/samba/account_policy.tdb
```
```text
key(23) = "min password length\00"
data(4) = "\0a\00\00\00"
key(21) = "password history\00"
data(4) = "\00\00\00\00"
```

---

## 5. Troubleshooting, Verification & Failure Diagnosis Guide

### 5.1 Production Diagnostics Workflow Decision Tree

```
                      +------------------------------------------+
                      |   Client SMB Connection / Auth Failure   |
                      +------------------------------------------+
                                           |
                                           v
                     +--------------------------------------------+
                     |  Can client reach TCP Port 445 via network?|
                     +--------------------------------------------+
                               /                        \
                             NO                          YES
                             /                            \
                            v                              v
            +-------------------------------+    +----------------------------------+
            | Check iptables / firewalld /  |    | Is Samba service running?        |
            | UFW rules & physical routing  |    | Check systemctl status smbd      |
            +-------------------------------+    +----------------------------------+
                                                           /                  \
                                                         NO                    YES
                                                         /                      \
                                                        v                        v
                                        +-----------------------+  +-------------------------------+
                                        | Check /var/log/samba/ |  | Does testparm raise syntax    |
                                        | log.smbd for binding  |  | errors in /etc/samba/smb.conf?|
                                        | or socket errors      |  +-------------------------------+
                                        +-----------------------+            /           \
                                                                           YES            NO
                                                                           /                \
                                                                          v                  v
                                                         +--------------------+    +-----------------------+
                                                         | Fix smb.conf syntax|    | Run diagnostic tests: |
                                                         | and reload daemon  |    | wbinfo -p & net ads   |
                                                         +--------------------+    | testjoin              |
                                                                                   +-----------------------+
```

---

### 5.2 Diagnostic Scenarios & Remediation Protocols

#### Scenario A: Winbind ID Mapping Failure (`NT_STATUS_UNSUCCESSFUL` or `No such user`)
* **Symptom:** Active Directory users authenticate successfully over SMB, but fail to read/write to filesystem shares. `ls -l` shows raw numerical SIDs or ownership assigned to `nobody` or `10000`.
* **Root Cause Analysis:** `winbindd` cannot execute SID-to-UID translation due to misconfigured `idmap config` ranges or range exhaustion in `idmap config CORP : range`.
* **Diagnostic Execution:**
  ```bash
  # 1. Check Winbind operational state
  $ sudo wbinfo -p
  
  # 2. Trace SID allocation for failing user
  $ sudo wbinfo -n "CORP\user1"
  # Returns: S-1-5-21-3849204912-1029384910-482910394-985000

  # 3. Check allocated UID
  $ sudo wbinfo -s S-1-5-21-3849204912-1029384910-482910394-985000
  # Error: WBC_ERR_DOMAIN_NOT_FOUND or failed to convert SID
  ```
* **Remediation Protocol:**
  1. Inspect `smb.conf`. Calculate required range offset for `idmap_rid`:
     $$\text{RID} = 985000$$
     If `idmap config CORP : range = 20000-999999`, then:
     $$\text{UID} = 20000 + 985000 = 1005000$$
     *Failure:* Calculated UID ($1,005,000$) exceeds max range limit ($999,999$).
  2. Increase the domain range upper bound in `/etc/samba/smb.conf`:
     ```ini
     idmap config CORP : range = 20000-2000000
     ```
  3. Clear winbind ID map cache and restart services:
     ```bash
     $ sudo net cache flush
     $ sudo systemctl restart winbindd smbd
     ```

---

#### Scenario B: Volatile TDB Database Corruption (`locking.tdb`)
* **Symptom:** `smbd` processes lock up at 100% CPU utilization. Users report severe I/O stalls or `NT_STATUS_FILE_LOCK_CONFLICT` errors when accessing existing unlocked files.
* **Root Cause Analysis:** Hard node reset or high-concurrency storage power failure corrupted record hash-chains inside `/var/lib/samba/locking.tdb`.
* **Diagnostic Execution:**
  ```bash
  # Inspect log.smbd for TDB panic traces
  $ sudo tail -n 50 /var/log/samba/log.smbd
  ```
  ```text
  [2026/08/06 11:45:12.102839,  0] ../../lib/util/fault.c:171(smb_panic_default)
    INTERNAL ERROR: Signal 11 in ping_message child process
  [2026/08/06 11:45:12.103001,  0] ../../source3/lib/dbwrap/dbwrap_tdb.c:75(db_tdb_fetchv)
    tdb_fetchv failed for hash chain 402 in /var/lib/samba/locking.tdb: Bad database format
  ```
* **Remediation Protocol:**
  1. Stop Samba daemons:
     ```bash
     $ sudo systemctl stop smbd nmbd winbindd
     ```
  2. Perform TDB verification check:
     ```bash
     $ sudo tdbtool /var/lib/samba/locking.tdb check
     # Output: Database integrity failed: 1 corrupted record found
     ```
  3. Because `locking.tdb` stores volatile state, safely wipe the corrupted file (Samba will re-create a clean database automatically on startup):
     ```bash
     $ sudo rm -f /var/lib/samba/locking.tdb
     $ sudo rm -f /var/lib/samba/brlock.tdb
     ```
  4. Start Samba daemons:
     ```bash
     $ sudo systemctl start winbindd smbd
     ```

---

#### Scenario C: Windows Extended Attribute ACL Translation Mismatch (`Access Denied`)
* **Symptom:** AD Domain Admins receive `Access Denied` when modifying Windows Security permissions tab on an SMB share, even though POSIX ownership allows root write access.
* **Root Cause Analysis:** Underlying POSIX filesystem was mounted without extended attribute support, or `security.NTACL` attribute cannot be written due to missing `acl_xattr` VFS module.
* **Diagnostic Execution:**
  ```bash
  # Check mount options for target share volume
  $ mount | grep /srv/samba/shares
  # Output: /dev/sdb1 on /srv/samba/shares type ext4 (rw,relatime,nouser_xattr)
  ```
* **Remediation Protocol:**
  1. Remount filesystem with extended attribute support:
     ```bash
     $ sudo mount -o remount,user_xattr /srv/samba/shares
     ```
  2. Verify POSIX extended attribute read/write capability manually:
     ```bash
     $ sudo setfattr -n user.test -v "samba_test" /srv/samba/shares/engineering
     $ sudo getfattr -n user.test /srv/samba/shares/engineering
     # Output: user.test="samba_test"
     $ sudo setfattr -x user.test /srv/samba/shares/engineering
     ```
  3. Ensure `vfs objects = acl_xattr` is configured in `[global]` or share level in `/etc/samba/smb.conf`.
  4. Reload Samba config:
     ```bash
     $ sudo smbcontrol smbd reload-config
     ```

---

## 6. References

* **Linux Professional Institute (LPI) LPIC-3 300 Official Objectives:**
  https://www.lpi.org/our-certifications/lpic-3-300-overview/
* **Samba Official Documentation & Reference Manual (`smb.conf`):**
  https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html
* **Samba Wiki — Active Directory Domain Member Setup:**
  https://wiki.samba.org/index.php/Setting_up_Samba_as_a_Domain_Member
* **Samba Wiki — Identity Mapping (idmap_rid / idmap_ad):**
  https://wiki.samba.org/index.php/Identity_Management
* **Samba VFS Modules Documentation (`vfs_acl_xattr`, `vfs_fruit`, `vfs_shadow_copy2`):**
  https://www.samba.org/samba/docs/current/man-html/vfs_acl_xattr.8.html
  https://www.samba.org/samba/docs/current/man-html/vfs_fruit.8.html