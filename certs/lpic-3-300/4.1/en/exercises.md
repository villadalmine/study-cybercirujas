# LPIC-3 Exam 300-300 (v3.0) — Topic 4.1: Samba Client Configuration
**Target Audience:** SREs, Platform Architects, Linux Systems Engineers  
**Weight:** 20  
**Official Reference:** [LPI LPIC-3 300 Objectives](https://www.lpi.org/our-certifications/lpic-3-300-overview/) | [Samba Documentation](https://www.samba.org/samba/docs/) | [Linux Kernel CIFS VFS Documentation](https://www.kernel.org/doc/html/latest/admin-guide/cifs/cifs.html)

---

## Exercise 1: Advanced CLI Diagnostics & Data Extraction (`smbclient`, `rpcclient`, `smbget`)

### Architecture & Mechanics
Client interaction with SMB/CIFS servers requires a deep understanding of protocol negotiation, session setup, and RPC pipe execution.
* **SMB Protocol Negotiation & Transport:** `smbclient` uses NetBIOS over TCP (port 139) or raw TCP/IP (port 445). During negotiation, the client and server agree on the dialect (e.g., `SMB2_02`, `SMB3_11`), message signing (`client signing`), and encryption capabilities.
* **RPC Pipe Architecture (`rpcclient`):** MS-RPC functions over SMB named pipes (e.g., `\PIPE\lsarpc`, `\PIPE\samr`, `\PIPE\srvsvc`). `rpcclient` establishes an authenticated DCE/RPC context, allowing low-level query execution against the Security Account Manager (SAM) or Active Directory Domain Services (AD DS).
* **High-Performance Retrieval (`smbget`):** `smbget` operates as a `wget`-like utility utilizing `libsmbclient` for non-interactive, recursive, multi-file SMB payload transfers.

---

### Hands-On Execution Steps

#### Step 1.1: Negotiate dialect boundaries and enumerate hidden shares with `smbclient`
Execute `smbclient` against domain controller `dc01.prod.internal` forcing SMB3 dialect (`-m SMB3`) with verbose debug output level 3 (`-d 3`) to analyze the NTLMSSP session setup sequence.

```bash
smbclient -L //dc01.prod.internal -U "PROD\\sre_admin%P@ssw0rd2026!" -m SMB3 -d 3
```

**Expected Output:**
```text
lp_load_ex: reviewing free structure members
Initialising global parameters
rhost_resolve_addrinfo: resolved 1 hostnames or IP addresses
Connecting to 192.168.10.10 at port 445
SMB2/3 dialect negotiation client requested min SMB2_02 max SMB3_11
Selected dialect SMB3_11
GENSEC backend 'gssapi_spnego' chosen
GENSEC backend 'schannel' chosen
Got challenge flags: 0xe2088297
NTLMSSP authentication succeeded to DC01
Sharename       Type      Comment
---------       ----      -------
ADMIN$          Disk      Remote Admin
C$              Disk      Default share
IPC$            IPC       Remote IPC
NETLOGON        Disk      Logon server share 
SYSVOL          Disk      Logon server share 
finance_data    Disk      Financial Archival Storage
SMB1 disabled -- Server does not support SMB1 protocol
Reconnecting with SMB3_11...
```

#### Step 1.2: Execute DCE/RPC pipe querying via `rpcclient`
Connect to the Remote SAM and Local Security Authority (LSA) RPC endpoints on target `192.168.10.10` to query domain SID, enumerate domain users, and resolve Security Identifiers (SIDs) to user names.

```bash
rpcclient -U "PROD\\sre_admin%P@ssw0rd2026!" 192.168.10.10 -c "lsaquery; enumdomusers; lookupsids S-1-5-21-382910482-1928374829-291827364-500"
```

**Expected Output:**
```text
Domain Name: PROD
Domain SID: S-1-5-21-382910482-1928374829-291827364
user:[Administrator] rid:[0x1f4]
user:[Guest] rid:[0x1f5]
user:[krbtgt] rid:[0x1f9]
user:[sre_admin] rid:[0x450]
user:[svc_backup] rid:[0x451]
S-1-5-21-382910482-1928374829-291827364-500 PROD\Administrator (1)
```

#### Step 1.3: Recursive non-interactive share retrieval via `smbget`
Extract log files recursively (`-R`) from the `finance_data` share into `/var/log/audit_ingest/` while logging actions debugging output (`-v`).

```bash
mkdir -p /var/log/audit_ingest
smbget -R -u "sre_admin" -p "P@ssw0rd2026!" -w "PROD" -v smb://192.168.10.10/finance_data/logs/ -o /var/log/audit_ingest/
```

**Expected Output:**
```text
Using Workgroup: PROD, User: sre_admin
Connecting to smb://192.168.10.10/finance_data/logs/
Downloading /logs/audit_20260801.log ...
[===================================================================>] 100% (4.2MB/s)
Downloading /logs/audit_20260802.log ...
[===================================================================>] 100% (5.1MB/s)
Downloaded 2 files (9.3MB) in 1.98 seconds.
```

---

### Verification Questions

1. **Question 1:** You execute `smbclient //fs01/data -U user` and receive `NT_STATUS_RESOURCE_NAME_NOT_FOUND`. However, `smbclient -L //fs01` shows the share `data` exists. Which low-level SMB behavior or credential issue most likely caused this discrepancy?
2. **Question 2:** When running `rpcclient`, what is the precise difference between the commands `lookupnames` and `lookupsids` in terms of protocol operation and expected inputs/outputs?

---

## Exercise 2: Kernel-Space CIFS Mounts (`mount.cifs`, `/etc/fstab`, Kerberos & Multiuser)

### Architecture & Mechanics
Kernel-level SMB integration is managed by the Linux `cifs.ko` VFS module (`cifs-utils`).
* **Session Transport & Multiplexing:** Unlike user-space tools (`libsmbclient`), kernel CIFS creates VFS inode mappings directly in system memory.
* **Security Modes (`sec=`):**
  * `sec=ntlmssp`: NTLMv2 password hashing wrapped in NTLMSSP.
  * `sec=krb5`: Kerberos v5 ticket authentication via GSS-API. Requires a valid user/host TGT in `krb5cc` credential cache.
  * `sec=krb5i`: Kerberos authentication with SMB packet signing enabled to prevent Man-in-the-Middle (MitM) replay attacks.
* **Multiuser Architecture (`multiuser`):** With `multiuser`, the initial mount is performed using a master service account. Subsequent per-user file access forces the Linux kernel to swap SMB session keys dynamically based on the local system user's Kerberos TGT (found in their `KRB5CCNAME` cache via `cifs.upcall`).

---

### Hands-On Execution Steps

#### Step 2.1: Create a secure external credentials file
Store sensitive SMB credentials in a dedicated file with strict POSIX permissions to prevent credential exposure in process listings (`ps aux`).

```bash
mkdir -p /etc/samba/credentials
cat << 'EOF' > /etc/samba/credentials/finance.creds
username=svc_cifs_mount
password=SecureK8sStorageEnv2026!
domain=PROD
EOF

chmod 600 /etc/samba/credentials/finance.creds
ls -la /etc/samba/credentials/finance.creds
```

**Expected Output:**
```text
-rw------- 1 root root 78 Aug 6 12:00 /etc/samba/credentials/finance.creds
```

#### Step 2.2: Perform a Kerberos-authenticated CIFS mount with packet signing (`sec=krb5i`) and `multiuser`
Verify domain Kerberos TGT existence using `klist`, then execute an enterprise-grade mount.

```bash
kinit -k -t /etc/krb5.keytab host/appserver01.prod.internal@PROD.INTERNAL
klist
mkdir -p /mnt/finance_secure
mount -t cifs //dc01.prod.internal/finance_data /mnt/finance_secure \
  -o sec=krb5i,multiuser,cruid=0,vers=3.1.1,uid=1050,gid=1050,dir_mode=0770,file_mode=0660
```

**Expected Output:**
```text
Ticket cache: FILE:/tmp/krb5cc_0
Default principal: host/appserver01.prod.internal@PROD.INTERNAL

Valid starting       Expires              Service principal
08/06/26 12:05:00  08/06/26 22:05:00  krbtgt/PROD.INTERNAL@PROD.INTERNAL
```

#### Step 2.3: Configure `/etc/fstab` for production persistence
Append a fully qualified, syntactically valid mount entry to `/etc/fstab` utilizing the credentials file, explicit SMB version forcing (`vers=3.1.1`), and dynamic user mapping options.

```bash
cat << 'EOF' >> /etc/fstab
//dc01.prod.internal/finance_data /mnt/finance_secure cifs credentials=/etc/samba/credentials/finance.creds,sec=krb5i,multiuser,vers=3.1.1,uid=1050,gid=1050,dir_mode=0770,file_mode=0660,_netdev 0 0
EOF

mount -a -t cifs
df -Th /mnt/finance_secure
```

**Expected Output:**
```text
Filesystem                         Type  Size  Used Avail Use% Mounted on
//dc01.prod.internal/finance_data cifs  2.0T  450G  1.6T  22% /mnt/finance_secure
```

---

### Verification Questions

1. **Question 1:** When a regular user (`uid=1002`) attempts to access a directory under `/mnt/finance_secure` mounted with `sec=krb5,multiuser`, they encounter `Permission denied (Required key not available)`. Root can access the mount without issues. What is the root cause, and how does the kernel resolve credentials?
2. **Question 2:** Explain the operational impact of specifying `_netdev` in `/etc/fstab` for CIFS mounts on Systemd-managed enterprise Linux distributions.

---

## Exercise 3: CLI Administrative Interrogation via `net` Utility

### Architecture & Mechanics
The `net` tool is Samba’s primary administration framework. It operates under distinct execution modes:
* `net rpc`: Interrogates target machines via DCE/RPC calls over SMB (works on standalone servers and NT4 domains).
* `net ads`: Interrogates Active Directory Domain Controllers using LDAP, Kerberos, and CLDAP protocols.
* `net lookup`: Performs name resolution queries against WINS, NetBIOS broadcast, or DNS to resolve NetBIOS names to IP addresses.

---

### Hands-On Execution Steps

#### Step 3.1: Execute NetBIOS/WINS lookups using `net lookup`
Locate domain controller IP infrastructure by querying NetBIOS name types (e.g., `<1C>` for Domain Controllers).

```bash
net lookup dc
net lookup dsgetdc PROD.INTERNAL
```

**Expected Output:**
```text
192.168.10.10
Got DC info from host dc01.prod.internal
GUID: 8f9b2d21-a3b4-4c5e-9f12-3b4c5d6e7f8a
Domain name: PROD.INTERNAL
Forest name: PROD.INTERNAL
DC IP: 192.168.10.10
Flags: 0xe0003fdd (PDC GC DS KDC SHARES TIMESERV)
```

#### Step 3.2: Perform Domain Join status and ADS environment validation
Query Active Directory join status, domain controller time synchronization, and Machine Account Passwords using `net ads`.

```bash
net ads status -U "sre_admin%P@ssw0rd2026!"
net ads testjoin
```

**Expected Output:**
```text
Object DN: CN=APPSERVER01,OU=Servers,DC=prod,DC=internal
sAMAccountName: APPSERVER01$
userAccountControl: 4096 (WORKSTATION_TRUST_ACCOUNT)
pwdLastSet: 133674829100000000
Join is OK
```

#### Step 3.3: Enumerate domain trust relationships via `net rpc`
Interrogate domain trust structures using RPC calls directly against the SAM/LSA subsytem.

```bash
net rpc trustdom list -U "sre_admin%P@ssw0rd2026!" -S dc01.prod.internal
```

**Expected Output:**
```text
Trusted domains list:
CORP.GLOBAL      (Direct Outbound Trust, Active Directory)
PARTNERS.EXT     (External Trust, NTLM Authenticated)
```

---

### Verification Questions

1. **Question 1:** What is the technical distinction between running `net rpc join` versus `net ads join` when integrating a Linux client into a Microsoft environment?
2. **Question 2:** A SRE runs `net lookup host appserver01` and it fails, but `ping appserver01` succeeds. Which configuration setting in `/etc/samba/smb.conf` dictates how Samba client tools resolve hostnames?

---

## Exercise 4: Global Client Tuning & Protocol Hardening (`smb.conf`)

### Architecture & Mechanics
Client parameters defined in `/etc/samba/smb.conf` (within the `[global]` section) dictate default behaviors for `smbclient`, `rpcclient`, `net`, and applications consuming `libsmbclient`.
* **Protocol Range Constraints (`client min protocol` / `client max protocol`):** Prevents downgrades to insecure dialects (e.g., SMB1/NT1).
* **Cryptographic Signatures (`client signing`):** Forces or disables SMB packet signing at the client runtime level (`mandatory`, `auto`, `disabled`).
* **Name Resolution Strategy (`name resolve order`):** Controls the fallback chain when resolving SMB server targets.

---

### Hands-On Execution Steps

#### Step 4.1: Construct a hardened, zero-trust client `/etc/samba/smb.conf`
Deploy a client-side configuration strictly disallowing legacy protocols, enforcing packet signing, and configuring Kerberos SPNEGO authentication.

```bash
cat << 'EOF' > /etc/samba/smb.conf
[global]
   workgroup = PROD
   realm = PROD.INTERNAL
   security = ads

   # Protocol Hardening Boundaries
   client min protocol = SMB3_00
   client max protocol = SMB3_11
   client ipc min protocol = SMB3_00
   client ipc max protocol = SMB3_11

   # Cryptographic & Auth Controls
   client signing = required
   client NTLMv2 auth = yes
   client use spnego = yes
   client protected auth = yes

   # Name Resolution Mechanics
   name resolve order = host bcast lmhosts

   # Logging & Diagnostics
   log level = 2 client:3
   max log size = 5000
EOF

testparm -s /etc/samba/smb.conf
```

**Expected Output:**
```text
Load smb config files from /etc/samba/smb.conf
Loaded services file OK.
Weak crypto is allowed by smb.conf attribute 'allow weak auth'

Server role: ROLE_DOMAIN_MEMBER

# Section listing omitted for brevity...
[global]
	client max protocol = SMB3_11
	client min protocol = SMB3_00
	client ipc max protocol = SMB3_11
	client ipc min protocol = SMB3_00
	client NTLMv2 auth = Yes
	client protected auth = Yes
	client signing = required
	client use spnego = Yes
	name resolve order = host bcast lmhosts
	realm = PROD.INTERNAL
	security = ADS
	workgroup = PROD
```

---

### Verification Questions

1. **Question 1:** How does setting `client ipc min protocol = SMB3_00` impact domain join operations and RPC administration tools (`rpcclient`, `net rpc`) when interacting with legacy Samba 3.x domain controllers?
2. **Question 2:** What is the operational difference between `name resolve order = host bcast` and `name resolve order = lmhosts bcast host`?

---

<details>
<summary><strong>Answers and Deep Dive Explanations</strong></summary>

### Exercise 1 Answers

1. **Answer 1:** The `NT_STATUS_RESOURCE_NAME_NOT_FOUND` error indicates that while server connection and share enumeration (`IPC$`) succeeded, the target path specified is either misspelled, case-sensitive on non-Windows SMB implementations, or protected by Access-Based Enumeration (ABE). If ABE is enabled on the target share, users without read permissions will receive `NT_STATUS_RESOURCE_NAME_NOT_FOUND` or `NT_STATUS_ACCESS_DENIED` upon explicit path access attempt.
2. **Answer 2:** `lookupnames` converts human-readable username/group strings (e.g., `PROD\sre_admin`) into binary/string SIDs (e.g., `S-1-5-21-...-1104`) by querying the LSA `LookupNames` RPC interface (`\PIPE\lsarpc`). Conversely, `lookupsids` performs the exact reverse transformation: it translates SIDs into fully qualified domain account names via the LSA `LookupSids` RPC pipe interface.

---

### Exercise 2 Answers

1. **Answer 1:** The `multiuser` option instructs the kernel CIFS driver NOT to reuse the mounting user's credentials for subsequent access by other local Linux users. When user `uid=1002` accesses `/mnt/finance_secure`, the kernel looks up a Kerberos credential cache owned by `uid=1002` (via `cifs.upcall` helper). Since `uid=1002` has not initialized a valid TGT (`kinit`), no Kerberos key is available in their keyring/cache context (`FILE:/tmp/krb5cc_1002`), triggering `Required key not available`.
2. **Answer 2:** The `_netdev` option is a systemd/mount directive that explicitly informs the OS init framework that the mount point depends on active network connectivity. It delays mounting during boot until the network stack (`NetworkManager` / `systemd-networkd`) is fully online and prevents boot failure timeouts. During shutdown, systemd unmounts `_netdev` shares *before* bringing down network interfaces, avoiding unmount hangs and kernel panics.

---

### Exercise 3 Answers

1. **Answer 1:** `net rpc join` relies strictly on NTLM/SMB authentication over DCE/RPC named pipes to bind the machine account to an NT4-style domain or Active Directory in compatibility mode. `net ads join` utilizes Active Directory native protocols: Kerberos for client-to-DC authentication, LDAP for container/OU object placement, and Dynamic DNS updates to register machine A/AAAA records on the DC.
2. **Answer 2:** The parameter is `name resolve order` defined in `/etc/samba/smb.conf`. Standard OS commands (`ping`, `curl`) use the NSS subsystem defined in `/etc/nsswitch.conf` (`hosts: files dns`). Samba client tools (`net`, `smbclient`) parse `/etc/samba/smb.conf`'s `name resolve order` setting (defaulting to `lmhosts wins host bcast`), ignoring `/etc/nsswitch.conf` unless `host` is explicitly parsed.

---

### Exercise 4 Answers

1. **Answer 1:** Legacy Samba 3.x domain controllers or older Windows Server versions (2003/2008) often utilize SMB1 for IPC named pipes (`\PIPE\lsarpc`, `\PIPE\samr`). Setting `client ipc min protocol = SMB3_00` forces all inter-process communication (IPC) traffic over SMB3. If the remote DC does not support SMB3 for IPC pipes, calls to `rpcclient` and `net rpc` will fail immediately with `NT_STATUS_REVISION_MISMATCH` or `NT_STATUS_NOT_SUPPORTED`.
2. **Answer 2:** `name resolve order = host bcast` forces Samba client applications to query standard system resolution (DNS/`/etc/hosts`) first, falling back to NetBIOS IPv4 broadcasts (`bcast`) if DNS fails. `name resolve order = lmhosts bcast host` forces Samba to search the legacy static file `/etc/samba/lmhosts` first, followed by NetBIOS broadcasts, and only queries DNS (`host`) as a final fallback. The latter severely impacts performance in large environments if DNS hostnames do not match static `lmhosts` files.

</details>