# LPIC-2 (Exams 201-450 & 202-450, v4.5) — Topic 208: File Sharing (Weight: 8)
## SRE & Platform Architecture Production Study Guide

---

## 1. Production Architectural Motivation & Problem Statement

In enterprise production environments, network file sharing forms the backbone of shared persistent storage, dynamic state access across container/VM clusters, database backup targets, and heterogeneous identity-integrated file repositories. 

Engineers face a fundamental architectural duality:
1. **Unix-native, high-throughput POSIX workloads** operating over Linux clusters requiring low overhead, kernel-level file passing, and identity mapping aligned with UID/GID schemas.
2. **Heterogeneous cross-platform access (Windows, macOS, Linux)** integrated into Active Directory (AD) domains requiring SMB/CIFS protocols, Windows Access Control Lists (NTFS ACLs), SMB oplocks/leases, and Kerberos/SPNEGO authentication.

```
                     +-----------------------------------+
                     |  Enterprise Identity & Storage    |
                     |  Active Directory / FreeIPA / NFS |
                     +-----------------+-----------------+
                                       |
                +----------------------+----------------------+
                |                                             |
   +------------v------------+                   +------------v------------+
   |   NFSv4.2 Server        |                   |  Samba 4 AD Member FS   |
   |   (Kernel nfsd)         |                   |  (smbd / winbindd)      |
   +------------+------------+                   +------------+------------+
                |                                             |
     TCP 2049   | RPC / sec=krb5p                 TCP 445     | SMB3 / NTLMv2 / Kerberos
     Stateful   | POSIX / IDMAP                   Oplocks     | Windows ACLs / Idmap
                |                                             |
   +------------v------------+                   +------------v------------+
   | Linux Compute Nodes     |                   | Windows / macOS / Linux |
   | Kubernetes Persistent V.|                   | Endpoints & Legacy Apps |
   +-------------------------+                   +-------------------------+
```

### Key Production Architectural Challenges:
* **Protocol Statefulness & Network Resiliency**: NFSv3 is stateless, relying on auxiliary RPC daemons (`lockd`, `statd`, `mountd`) over dynamic ports, creating severe firewall traversal and split-brain lock problems. NFSv4+ unifies state management and locks over a single TCP port (2049), but introduces client lease tracking and server state recovery timeouts during failover.
* **Identity Mapping & Security Boundaries**: Standard `sec=sys` (NFS) trusts the UID/GID supplied by the client network packet without verification—a major security risk in zero-trust networks. Production NFSv4 requires Kerberos (`sec=krb5p`) or RPCSEC_GSS, while Samba requires integration with Active Directory via Winbind or SSSD to map Windows SIDs to Linux UIDs/GIDs deterministically.
* **Concurrency, Locking & Cache Coherency**: High-concurrency read/write operations require fine-grained lock delegation (`oplocks` in Samba, write delegations in NFSv4.2). Improper tuning results in deadlocks, stale file handles (`ESTALE`), and severe file I/O latency.

---

## 2. Deep Technical Comparisons & Trade-off Tables

### Table 2.1: NFS Protocol Version Comparison (NFSv3 vs NFSv4.0 vs NFSv4.1/v4.2)

| Technical Dimension | NFSv3 | NFSv4.0 | NFSv4.1 / NFSv4.2 |
| :--- | :--- | :--- | :--- |
| **State Model** | Stateless server; relies on external protocols (`NLM`, `NSM`). | Stateful server; integrated compound RPC requests. | Fully stateful; session-aware compound RPCs with parallel NFS (pNFS). |
| **Network & Firewall** | Dynamic RPC ports (`rpcbind` / port 111, `mountd`, `lockd`). | Single port TCP 2049. | Single port TCP 2049; support for RDMA (RoCE / InfiniBand). |
| **Identity Mechanism** | Raw numeric UIDs/GIDs sent over wire (`sec=sys`). | String-based user mapping (`user@domain`) via `rpc.idmapd`. | String-based IDMAP with extended numeric ID caching (`nfsidmap`). |
| **Authentication & Security** | Client IP filtering; `sec=sys` trust model; optional weak RPCSEC_GSS. | Integrated RPCSEC_GSS (`sec=krb5`, `sec=krb5i`, `sec=krb5p`). | Mandatory strong encryption support (`krb5p` with AES-256-CTS-HMAC-SHA1-96). |
| **File Locking** | Auxiliary protocol (`lockd` / NLM over port 4045). | Native stateful locking integrated into core protocol. | Native lease locks with server restart state recovery guarantees. |
| **Advanced Features** | None (Basic POSIX). | Pseudo-filesystem (`fsid=0`), ACLs. | pNFS, Server-Side Copy (SSC), Sparse Files (SEEK_HOLE/SEEK_DATA), Labeled NFS (SELinux xattrs). |

---

### Table 2.2: Network Storage Protocol Architectural Comparison (NFSv4.2 vs Samba/SMB3)

| Metric / Requirement | Linux Kernel NFSv4.2 | Samba 4 / SMB3.1.1 |
| :--- | :--- | :--- |
| **Target Workloads** | High-throughput Linux HPC, Kubernetes PVs, DB Backups. | Cross-platform desktop shares, AD Domain integrated shares, Windows CAD. |
| **OS Architecture** | In-kernel execution (`nfsd.ko`), zero-copy socket transfers. | User-space multi-process architecture (`smbd`, `nmbd`, `winbindd`). |
| **Transport Encryption** | Kerberos gss-api (`sec=krb5p` - AES-256 via RPCSEC_GSS). | SMB3 native AES-128-GCM / AES-256-GCM transport encryption. |
| **Access Control Model** | POSIX permissions & NFSv4 ACLs. | POSIX ACLs mapped to Windows NTFS Security Descriptors (`vfs_acl_xattr`). |
| **Cache & Locking Coherency** | File & Directory Delegations (Server recalls delegation on conflict). | Opportunistic Locks (`oplocks`), SMB2/3 Read/Write/Handle Leases. |
| **Failover Mechanism** | NFSv4 State Recovery Lease Timer (~90s grace period). | Transparent Failover (SMB3 Continuously Available shares via CTDB). |

---

## 3. Complete Syntactically Valid Production Manifests & Infrastructure Configurations

### 3.1 Enterprise NFSv4.2 Storage Server Configuration

#### File: `/etc/nfs.conf`
```ini
# Production Enterprise NFSv4 Server Configuration
[general]
 pipefs-directory = /var/lib/nfs/rpc_pipefs

[nfsd]
 threads = 64
 host = 192.168.10.50
 port = 2049
 grace-time = 90
 lease-time = 60
 vers2 = n
 vers3 = n
 vers4 = y
 vers4.0 = y
 vers4.1 = y
 vers4.2 = y

[mountd]
 manage-gids = y
 threads = 16

[statd]
 port = 4000
 outlet-port = 4001

[lockd]
 port = 4045
 udp-port = 4045
 tcp-port = 4045
```

#### File: `/etc/idmapd.conf`
```ini
[General]
Verbosity = 1
Pipefs-Directory = /var/lib/nfs/rpc_pipefs
Domain = enterprise.internal

[Mapping]
Nobody-User = nobody
Nobody-Group = nogroup

[Translation]
Method = nsswitch
```

#### File: `/etc/exports`
```exports
# Root Pseudo-Filesystem for NFSv4 Export Tree
/exports                                    192.168.10.0/24(ro,sync,no_subtree_check,crossmnt,fsid=0,sec=krb5p:krb5i:sys)

# Production High-Performance Application Shared Volume
/exports/app-data                           192.168.10.0/24(rw,sync,no_wdelay,no_root_squash,no_subtree_check,sec=krb5p:sys)

# Secure Backup Vault with User Squashing
/exports/backups                            192.168.10.0/24(rw,sync,root_squash,all_squash,anonuid=65534,anongid=65534,no_subtree_check,sec=krb5p)
```

---

### 3.2 Samba 4 Active Directory Domain Member File Server Configuration

#### File: `/etc/krb5.conf`
```ini
[libdefaults]
    default_realm = ENTERPRISE.INTERNAL
    dns_lookup_realm = false
    dns_lookup_kdc = true
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true
    rdns = false
    default_tkt_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
    default_tgs_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96

[realms]
    ENTERPRISE.INTERNAL = {
        kdc = ad01.enterprise.internal:88
        admin_server = ad01.enterprise.internal:749
        default_domain = enterprise.internal
    }

[domain_realm]
    .enterprise.internal = ENTERPRISE.INTERNAL
    enterprise.internal = ENTERPRISE.INTERNAL
```

#### File: `/etc/samba/smb.conf`
```ini
[global]
    # Basic Server Identification & AD Domain Alignment
    workgroup = ENTERPRISE
    realm = ENTERPRISE.INTERNAL
    netbios name = FS01
    server string = Enterprise Samba Production File Server
    server role = member server
    security = ADS

    # Protocol Restrictions & Security Hardening
    client min protocol = SMB3_00
    server min protocol = SMB2_10
    client max protocol = SMB3_11
    server max protocol = SMB3_11
    smb encrypt = required
    server signing = required
    client signing = required
    disable netbios = yes
    smb ports = 445

    # Identity Mapping Architecture (winbindd backend)
    idmap config * : backend = tdb
    idmap config * : range = 30000-39999
    idmap config ENTERPRISE : backend = rid
    idmap config ENTERPRISE : range = 10000-29999
    
    winbind use default domain = yes
    winbind enum users = no
    winbind enum groups = no
    winbind refresh tickets = yes
    winbind offline login = yes
    template shell = /bin/bash
    template homedir = /home/%D/%U

    # VFS Modules & Extended Attributes Mapping
    vfs objects = acl_xattr fruit streams_xattr
    map acl inherit = yes
    store dos attributes = yes

    # Performance Tuning & Async I/O
    aio read size = 1
    aio write size = 1
    use sendfile = yes
    min receivefile size = 16384
    read raw = yes
    write raw = yes
    oplocks = yes
    level2 oplocks = yes

    # Logging Architecture
    log level = 2 winbind:3
    log file = /var/log/samba/log.%m
    max log size = 50000
    logging = systemd

[finance-data]
    comment = Secure Enterprise Financial Records
    path = /srv/samba/finance
    read only = no
    browseable = yes
    guest ok = no
    valid users = @"ENTERPRISE\finance-dept" @"ENTERPRISE\domain admins"
    write list = @"ENTERPRISE\finance-dept"
    force create mode = 0660
    force directory mode = 0770
    inherit permissions = yes
    inherit acls = yes
    vfs objects = acl_xattr fruit streams_xattr full_audit
    full_audit:prefix = %u|%I|%m|%S
    full_audit:success = pwrite unlinkat renameat mkdirat rmdirat
    full_audit:failure = all
    full_audit:facility = LOCAL7
    full_audit:priority = NOTICE

[public-docs]
    comment = Corporate Public Documentation Read-Only Share
    path = /srv/samba/public
    read only = yes
    guest ok = yes
    browseable = yes
    valid users = @"ENTERPRISE\domain users" guest
```

---

### 3.3 Production Client `/etc/fstab` Mount Configurations

```fstab
# Enterprise NFSv4.2 Production Mount with Kerberos & Performance Tuning
192.168.10.50:/exports/app-data /mnt/nfs_app nfs4 rw,noatime,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,sec=krb5p,proto=tcp,nfsvers=4.2,_netdev 0 0

# Samba/CIFS SMB3.1.1 Mount with Active Directory Credentials File & Automated Lock Cleanup
//fs01.enterprise.internal/finance-data /mnt/smb_finance cifs credentials=/etc/samba/credentials.smb,uid=10005,gid=10001,iocharset=utf8,rw,vers=3.1.1,seal,mfsymlinks,noperm,_netdev 0 0
```

#### File: `/etc/samba/credentials.smb`
```ini
username=sre_service_account
password=P@ssw0rd!Secure987654#
domain=ENTERPRISE.INTERNAL
```

---

## 4. Real CLI Commands and Realistic Terminal Outputs ($)

### 4.1 NFS Infrastructure Verification & RPC Diagnostics

#### Command: Re-exporting configured shares and displaying current active export flags
```bash
$ sudo exportfs -arv
```
```text
exporting 192.168.10.0/24:/exports/backups
exporting 192.168.10.0/24:/exports/app-data
exporting 192.168.10.0/24:/exports
```

#### Command: Inspecting low-level active kernel export table flags
```bash
$ cat /proc/fs/nfs/exports
```
```text
#Path Client(Flags) #Current Access Control Options
/exports/app-data	192.168.10.0/24(rw,root_squash,sync,wdelay,no_hide,nocrossmnt,sub_tree_check,no_all_squash,sec=390005:sec=1)
/exports/backups	192.168.10.0/24(rw,all_squash,sync,wdelay,no_hide,nocrossmnt,sub_tree_check,anonuid=65534,anongid=65534,sec=390005)
/exports	192.168.10.0/24(ro,root_squash,sync,wdelay,fsid=0,nocrossmnt,sub_tree_check,no_all_squash,sec=390005:sec=390004:sec=1)
```

#### Command: Verifying RPC Endpoints registered with `rpcbind`
```bash
$ rpcinfo -p localhost
```
```text
   program vers proto   port  service
    100000    4   tcp    111  portmapper
    100000    3   tcp    111  portmapper
    100000    2   tcp    111  portmapper
    100005    1   tcp   20048  mountd
    100005    3   tcp   20048  mountd
    100003    3   tcp   2049  nfs
    100003    4   tcp   2049  nfs
    100021    4   tcp   4045  nlockmgr
```

#### Command: Checking NFS client/server statistics and call counters
```bash
$ nfsstat -s
```
```text
Server rpc stats:
calls      badcalls   badclnt    badauth    xdrcall
1489201    0          0          0          0       

Server nfs v4 operations:
null         compound     
31 (0%)      412098 (99%) 

Server nfs v4.2 op statistics:
op0-unused   op1-unused   op2-future   access       close        commit       create       
0 (0%)       0 (0%)       0 (0%)       45102 (10%)  12050 (2%)   8901 (2%)    1002 (0%)    
delegreturn  getattr      getfh        link         lock         lockt        locku        
3102 (0%)    180590 (43%) 98040 (23%)  0 (0%)       4100 (0%)    0 (0%)       4100 (0%)    
lookup       lookup_root  open         openattr     open_confirm open_downgrd read         
12040 (2%)   12 (0%)      12050 (2%)   0 (0%)       0 (0%)       0 (0%)       25010 (6%)   
readdir      readlink     remove       rename       renew        restorefh    savefh       
1400 (0%)    12 (0%)      450 (0%)     102 (0%)     0 (0%)       1890 (0%)    1890 (0%)    
secinfo      setattr      setclientid  setcltconf   verify       write        release_lock 
0 (0%)       2100 (0%)    0 (0%)       0 (0%)       0 (0%)       10490 (2%)   0 (0%)       
```

#### Command: Inspecting mount performance stats for active NFS mount
```bash
$ mountstats /mnt/nfs_app
```
```text
Stats for 192.168.10.50:/exports/app-data mounted on /mnt/nfs_app:
  NFS mount options: racache=60,rsize=1048576,wsize=1048576,timeo=600,retrans=2,acdirmin=30,acdirmax=60,acregmin=30,acregmax=60,sec=krb5p,port=2049,proto=tcp,nfsvers=4.2
  NFS security flavor: krb5p
  
  RPC statistics:
    78902 RPC requests sent, 78902 RPC replies received (0 retransmissions)
    Average RTT: 0.852 ms
    Average Execution Time: 1.120 ms
    Read bytes: 5242880000 (avg 1048576.0 read bytes per op)
    Write bytes: 2097152000 (avg 1048576.0 write bytes per op)
```

---

### 4.2 Samba Architecture & Active Directory CLI Operations

#### Command: Syntactical validation of `smb.conf`
```bash
$ testparm -s /etc/samba/smb.conf
```
```text
Load smb config files from /etc/samba/smb.conf
Loaded services file OK.
Weak crypto is allowed by GnuTLS (default)
Server role: ROLE_DOMAIN_MEMBER

# Global parameters
[global]
	client max protocol = SMB3_11
	client min protocol = SMB3_00
	disable netbios = Yes
	idmap config enterprise : range = 10000-29999
	idmap config enterprise : backend = rid
	idmap config * : range = 30000-39999
	idmap config * : backend = tdb
	log level = 2 winbind:3
	logging = systemd
	netbios name = FS01
	realm = ENTERPRISE.INTERNAL
	security = ADS
	server min protocol = SMB2_10
	server signing = required
	smb encrypt = required
	smb ports = 445
	workgroup = ENTERPRISE
	vfs objects = acl_xattr fruit streams_xattr

[finance-data]
	comment = Secure Enterprise Financial Records
	force create mode = 0660
	force directory mode = 0770
	inherit acls = Yes
	inherit permissions = Yes
	path = /srv/samba/finance
	read only = No
	valid users = @"ENTERPRISE\finance-dept" @"ENTERPRISE\domain admins"
	write list = @"ENTERPRISE\finance-dept"
	vfs objects = acl_xattr fruit streams_xattr full_audit
```

#### Command: Joining Active Directory Domain using Kerberos credentials
```bash
$ sudo net ads join -U "sre_admin@ENTERPRISE.INTERNAL"
```
```text
Password for [sre_admin@ENTERPRISE.INTERNAL]:
Using short domain name -- ENTERPRISE
Joined 'FS01' to dns domain 'enterprise.internal'
No DNS domain configured for fs01. Unable to perform DNS Update.
DNS update should be performed by DC or external DNS server.
```

#### Command: Querying Active Directory Membership Status
```bash
$ sudo net ads status
```
```text
objectClass: top
objectClass: person
objectClass: organizationalPerson
objectClass: user
objectClass: computer
cn: FS01
distinguishedName: CN=FS01,CN=Computers,DC=enterprise,DC=internal
instanceType: 4
whenCreated: 20260806121045.0Z
uSNCreated: 450912
name: FS01
sAMAccountName: FS01$
sAMAccountType: 805306369
dNSHostName: fs01.enterprise.internal
servicePrincipalName: HOST/fs01.enterprise.internal
servicePrincipalName: HOST/FS01
servicePrincipalName: RestrictedKrbHost/FS01
servicePrincipalName: RestrictedKrbHost/fs01.enterprise.internal
```

#### Command: Testing domain user resolution via Winbind NSS integration
```bash
$ getent passwd "ENTERPRISE\jdoe"
```
```text
ENTERPRISE\jdoe:*:10501:10001:John Doe:/home/ENTERPRISE/jdoe:/bin/bash
```

#### Command: Listing active client connections, open shares, and byte-range locks
```bash
$ sudo smbstatus --shares --locks
```
```text
Service      pid     Machine       Connected at                  Encryption                   Signing              
--------------------------------------------------------------------------------------------------
finance-data 45102   192.168.10.88 Thu Aug  6 13:40:12 2026 EDT  AES-256-GCM                  partial(AES-128-GMAC)

Locked files:
Pid          Uid        DenyMode   Access      R/W        Oplock           SharePath   Name   Time
--------------------------------------------------------------------------------------------------
45102        10501      DENY_NONE  0x120089    RDWR       EXCLUSIVE+BATCH  /srv/samba/finance   Q3_Audit.xlsx   Thu Aug 6 13:42:01 2026
```

#### Command: Browsing Samba shares remotely using `smbclient` with Kerberos authentication
```bash
$ smbclient -k -L //fs01.enterprise.internal
```
```text
Sharename       Type      Comment
---------       ----      -------
finance-data    Disk      Secure Enterprise Financial Records
public-docs     Disk      Corporate Public Documentation Read-Only Share
IPC$            IPC       IPC Service (Enterprise Samba Production File Server)
```

---

## 5. Fault Verification and Diagnostic Troubleshooting Guide

```
                  +-----------------------------------+
                  | Production Incident Diagnostic    |
                  | File Sharing Failure Reported     |
                  +-----------------+-----------------+
                                    |
                    +---------------+---------------+
                    |                               |
          +---------v---------+           +---------v---------+
          |   NFS Issue       |           |   Samba / SMB     |
          +---------+---------+           +---------+---------+
                    |                               |
          +---------v---------+           +---------v---------+
          | 1. Check Port 2049|           | 1. Test smb.conf  |
          |    & rpcinfo      |           |    (testparm)     |
          | 2. Verify IDMAP   |           | 2. Check Winbind  |
          |    (nobody:nobody)|           |    (wbinfo -t)    |
          | 3. Inspect Locks  |           | 3. Audit Oplocks  |
          |    (/proc/locks)  |           |    (smbstatus -L) |
          +-------------------+           +-------------------+
```

### Scenario 5.1: NFS Mount Hangs / RPC Timeout / Firewall Dropping Packets

* **Symptom**: Client command `mount -t nfs4 192.168.10.50:/exports/app-data /mnt/nfs_app` hangs indefinitely and eventually returns `mount.nfs4: Connection timed out`.
* **Root Cause**: Network ACLs, iptables/nftables, or hardware firewalls blocking TCP port 2049, or blocking RPC portmapper (TCP/UDP port 111).

#### Step-by-Step Diagnostic & Resolution Protocol:

1. **Verify TCP Port 2049 reachability from client using `nc` / `nmap`**:
   ```bash
   $ nc -zvw5 192.168.10.50 2049
   ```
   *Expected Failure Output*: `nc: connect to 192.168.10.50 port 2049 (tcp) failed: Connection timed out`

2. **Execute packet capture on the storage server interface filtering for NFS/RPC**:
   ```bash
   $ sudo tcpdump -nn -i eth0 host 192.168.10.105 and \(port 2049 or port 111\)
   ```
   *Observation*: SYN packets arriving from client `192.168.10.105.48910 > 192.168.10.50.2049: Flags [S]`, but no SYN-ACK response returned due to local host firewall rules.

3. **Check Firewall Rules on Server**:
   ```bash
   $ sudo nft list ruleset | grep 2049
   ```

4. **Remediation**: Open explicit Firewall Ports for NFSv4 on Server:
   ```bash
   $ sudo firewall-cmd --permanent --add-service=nfs
   $ sudo firewall-cmd --permanent --add-service=rpc-bind
   $ sudo firewall-cmd --permanent --add-service=mountd
   $ sudo firewall-cmd --reload
   ```

---

### Scenario 5.2: Identity Mapping Mismatch (Files Mapped to `nobody:nobody`)

* **Symptom**: NFSv4 mount succeeds, but all files owned by valid users are rendered as `nobody:nobody` (or UID `65534`).
* **Root Cause**: NFSv4 string ID mapper mismatch. The server and client have differing configurations in `/etc/idmapd.conf` (e.g., Domain mismatch: Server has `Domain = enterprise.internal`, Client has `Domain = localdomain`).

#### Step-by-Step Diagnostic & Resolution Protocol:

1. **Inspect `/etc/idmapd.conf` on both client and server**:
   ```bash
   $ grep "Domain" /etc/idmapd.conf
   ```
   *Client Output*: `Domain = localdomain`  
   *Server Output*: `Domain = enterprise.internal`

2. **Verify ID Translation Failure via `nfsidmap` utility**:
   ```bash
   $ sudo nfsidmap -u jdoe@enterprise.internal
   ```
   *Output*: `nfsidmap: key 'jdoe@enterprise.internal': No such file or directory`

3. **Remediation**:
   * Align `/etc/idmapd.conf` on both machines:
     ```ini
     [General]
     Domain = enterprise.internal
     ```
   * Clear the kernel IDMAP cache on client and server:
     ```bash
     $ sudo nfsidmap -c
     ```
   * Restart IDMAP Services:
     ```bash
     $ sudo systemctl restart rpc-idmapd.service
     ```

---

### Scenario 5.3: Stale Locks and File Access Deadlocks in Samba

* **Symptom**: Windows or Linux Samba clients receive "File Locked by another user" errors when opening shared spreadsheets, even after the original user closed the application.
* **Root Cause**: Stale SMB Oplock or byte-range lock remaining active in `locking.tdb` due to a client network disconnection without clean SMB logoff.

#### Step-by-Step Diagnostic & Resolution Protocol:

1. **Locate the file locks using `smbstatus`**:
   ```bash
   $ sudo smbstatus -L | grep "Q3_Audit.xlsx"
   ```
   *Output*:
   ```text
   45102        10501      DENY_NONE  0x120089    RDWR       EXCLUSIVE+BATCH  /srv/samba/finance   Q3_Audit.xlsx   Thu Aug 6 13:42:01 2026
   ```

2. **Cross-reference PID with active process list**:
   ```bash
   $ ps aux | grep 45102
   ```
   *Output*: `samba: smbd-notifyd --configfile=/etc/samba/smb.conf [orphaned]`

3. **Check kernel-level locks via `/proc/locks`**:
   ```bash
   $ cat /proc/locks | grep 45102
   ```

4. **Remediation**:
   * Terminate the orphaned `smbd` client worker thread holding the lock:
     ```bash
     $ sudo kill -9 45102
     ```
   * To prevent future persistent lock stalls, enable `oplock break wait time` and proper socket keepalives in `smb.conf`:
     ```ini
     [global]
     keepalive = 300
     oplock break wait time = 2000
     ```

---

### Scenario 5.4: Access Denied due to SELinux Context Security Constraints

* **Symptom**: Client receives `Permission Denied` when attempting to write to Samba share `/srv/samba/finance` or NFS export `/exports/app-data`, despite standard POSIX permissions being `0777`.
* **Root Cause**: SELinux security context is set to standard `default_t` or `usr_t`, causing the kernel SELinux subsystem to block `smbd` or `nfsd` daemons from reading/writing.

#### Step-by-Step Diagnostic & Resolution Protocol:

1. **Check Audit Logs for SELinux AVC Denials**:
   ```bash
   $ sudo ausearch -m avc -ts recent | grep -E "smbd|nfsd"
   ```
   *Output*:
   ```text
   type=AVC msg=audit(1786018900.120:801): avc:  denied  { write } for  pid=45102 comm="smbd" name="finance" dev="sdb1" ino=2048 scontext=system_u:system_r:smbd_t:s0 tcontext=unconfined_u:object_r:default_t:s0 tclass=dir permissive=0
   ```

2. **Inspect Current Directory Context Labels**:
   ```bash
   $ ls -Zd /srv/samba/finance /exports/app-data
   ```
   *Output*:
   ```text
   drwxrwxrwx. 2 root root unconfined_u:object_r:default_t:s0 /srv/samba/finance
   drwxrwxrwx. 2 root root unconfined_u:object_r:default_t:s0 /exports/app-data
   ```

3. **Remediation**: Apply Correct Persistent SELinux Contexts:
   * **For Samba Shares**:
     ```bash
     $ sudo semanage fcontext -a -t samba_share_t "/srv/samba/finance(/.*)?"
     $ sudo restorecon -Rv /srv/samba/finance
     ```
   * **For NFS Exports**:
     ```bash
     $ sudo semanage fcontext -a -t nfs_export_t "/exports/app-data(/.*)?"
     $ sudo restorecon -Rv /exports/app-data
     ```
   * **Verify SELinux Booleans**:
     ```bash
     $ sudo setsebool -P samba_enable_home_dirs on
     $ sudo setsebool -P nfs_export_all_rw on
     ```

---

## 6. References

* **Linux Professional Institute (LPI) Official Exam Objectives**:
  * [LPIC-2 Overview & Detailed Objectives](https://www.lpi.org/our-certifications/lpic-2-overview/)
  * [LPIC-2 Exam 202-450 Objective 208.1: Samba Configuration](https://wiki.lpi.org/wiki/LPIC-2_Objectives_V4.5#208.1_Samba_Configuration_.28weight:_4.29)
  * [LPIC-2 Exam 202-450 Objective 208.2: NFS Configuration](https://wiki.lpi.org/wiki/LPIC-2_Objectives_V4.5#208.2_NFS_Configuration_.28weight:_4.29)

* **Samba Official Documentation & AD Integration Manuals**:
  * [Samba Official Documentation & smb.conf Architecture](https://www.samba.org/samba/docs/man/manpages/smb.conf.5.html)
  * [Setting up Samba as a Domain Member](https://wiki.samba.org/index.php/Setting_up_Samba_as_a_Domain_Member)
  * [Samba VFS Modules and POSIX ACL Mapping](https://www.samba.org/samba/docs/current/man-html/vfs_acl_xattr.8.html)

* **Linux NFS Kernel Documentation & IETF Specifications**:
  * [Linux Kernel NFS Server Guide & exports(5)](https://man7.org/linux/man-pages/man5/exports.5.html)
  * [IETF RFC 7530: Network File System (NFS) version 4 Protocol](https://datatracker.ietf.org/doc/html/rfc7530)
  * [IETF RFC 5661: Network File System (NFS) Version 4 Minor Version 1 Protocol (pNFS)](https://datatracker.ietf.org/doc/html/rfc5661)
  * [Linux nfs.conf Architecture Guide](https://man7.org/linux/man-pages/man5/nfs.conf.5.html)