# LPIC-2 (Exams 201-450 & 202-450) Topic 2.3: File Sharing — Advanced Production Guide & Guided Labs

---

## 1. Deep Technical Architecture & Internal Mechanics

### 1.1 Samba Architecture & Internal Mechanics
Samba provides file and print services using the Server Message Block (SMB) / Common Internet File System (CIFS) protocol suite.

```
+-------------------------------------------------------------------------+
|                              SMB Client                                 |
+-------------------------------------------------------------------------+
                                    | SMB3 / TCP 445 (or NetBIOS TCP 139)
                                    v
+-------------------------------------------------------------------------+
|                             Samba Daemon Layer                          |
|  +------------------------+  +-------------------+  +----------------+  |
|  | smbd (File/Print/ACLs)   |  | nmbd (NetBIOS Name|  | winbindd (AD/  |  |
|  |                        |  |  Resolution/Browse|  |  Domain Identity| |
|  +------------------------+  +-------------------+  +----------------+  |
+-------------------------------------------------------------------------+
       |                         |                           |
       v                         v                           v
+-------------------------------------------------------------------------+
|                        Passdb Backend Engine                            |
|  +-------------------------------------+  +--------------------------+  |
|  | tdbsam (TDB database local store)   |  | ldapsam (OpenLDAP directory| |
|  +-------------------------------------+  +--------------------------+  |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|                  VFS Layer (acl_xattr, fruit, recycle)                  |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|                     Linux Kernel VFS & POSIX ACLs                       |
+-------------------------------------------------------------------------+
```

#### Core Daemons
*   **`smbd`**: Handles SMB/CIFS connection requests, user authentication, authorization against share definitions, file locking (byte-range locking), and file/printer I/O operations over TCP ports 445 (direct SMB over TCP) and 139 (SMB over NetBIOS session service).
*   **`nmbd`**: Handles NetBIOS over TCP/IP (NBT) name resolution and browsing services (NetBIOS Name Service over UDP 137, NetBIOS Datagram Service over UDP 138). *Note: Modern AD-integrated SMB environments operate entirely without `nmbd`.*
*   **`winbindd`**: Acts as the identity mapping bridge between Active Directory/NT4 domains and Linux NSS (Name Service Switch) and PAM (Pluggable Authentication Modules). It translates Windows SIDs (Security Identifiers) to Linux UIDs/GIDs.

#### Passdb Backends
Samba stores user credentials in specialized backends rather than using plain `/etc/shadow` because Windows SMB authentication requires NTLM hashes (NT-Hash / LM-Hash) or Kerberos tickets:
*   **`tdbsam`**: A local binary database format (`passdb.tdb`) based on TDB (Trivial DataBase). High performance, lightweight, suitable for standalone servers and small domain controllers. Managed via `pdbedit`.
*   **`ldapsam`**: Connects Samba to an enterprise OpenLDAP directory server (`smb.conf` target `ldapsam:ldap://...`). Ideal for centralized user account management across multi-server topologies.

---

### 1.2 NFSv3 vs. NFSv4 Architecture & Identity Mapping

```
+-------------------------------------------------------------------------+
|                           NFS Architecture Comparison                   |
+-------------------------------------------------------------------------+
|  NFSv3 (Stateless, Multi-Port, RPC-Dependent)                           |
|  +----------------+    +----------------+    +-----------------------+  |
|  | rpcbind (111)  |--->| rpc.mountd     |--->| rpc.statd / rpc.lockd |  |
|  | Portmapper     |    | Mount Auth     |    | Lock Management       |  |
|  +----------------+    +----------------+    +-----------------------+  |
|         ^                     ^                          ^              |
|         +---------------------+--------------------------+              |
|                               | nfs/TCP 2049                            |
|                               v                                         |
|                       +---------------+                                 |
|                       |  rpc.nfsd     |                                 |
|                       +---------------+                                 |
+-------------------------------------------------------------------------+
|  NFSv4 (Stateful, Single-Port TCP 2049, Compound RPCs, ID Mapping)      |
|  +-------------------------------------------------------------------+  |
|  | Client ---> TCP 2049 (rpc.nfsd)                                   |  |
|  |               |                                                   |  |
|  |               v                                                   |  |
|  |         +------------------+     +----------------------------+   |  |
|  |         | Pseudo-FS Root   | <-> | rpc.idmapd                 |   |  |
|  |         | (fsid=0 / root)  |     | (User@Domain <-> UID/GID)  |   |  |
|  |         +------------------+     +----------------------------+   |  |
|  +-------------------------------------------------------------------+  |
+-------------------------------------------------------------------------+
```

| Architectural Attribute | NFSv3 | NFSv4 / NFSv4.1 / NFSv4.2 |
| :--- | :--- | :--- |
| **Protocol State** | Stateless (requires `rpc.statd` & `rpc.lockd` for NLM) | Stateful (native open/close state tracking, lease locking) |
| **Network Transport & Ports** | TCP/UDP across multiple dynamic RPC ports (`rpcbind` port 111, `rpc.mountd`, `rpc.statd`, `rpc.lockd`) | Pure TCP on single deterministic port **2049** (Firewall friendly) |
| **Export Hierarchy** | Independent directory exports mapped individually | Pseudo-filesystem hierarchy rooted at `fsid=0` (or `fsid=root`) |
| **User Identity** | Numeric UID/GID passed across network (vulnerable to UID collisions) | String format `user@domain` resolved locally by `rpc.idmapd` or kernel idmapper |
| **Security Models** | `sec=sys` (AUTH_SYS / trusted UIDs), `sec=krb5` | Integrated GSS-API: `sec=sys`, `sec=krb5`, `sec=krb5i` (integrity), `sec=krb5p` (privacy/encrypted) |

---

### 1.3 AutoFS & Systemd Automount Mechanics

AutoFS dynamically mounts network shares when accessed and unmounts them after a configured period of inactivity (`timeout`), reducing memory, network kernel overhead, and stale mount points.

```
                                 AutoFS Kernel VFS Layer
                                           |
    Access /mnt/auto/finance ------------->| Trap access
                                           |
                                           v
                                    autofs daemon (automount)
                                           |
                                           | Inspect /etc/auto.master & map files
                                           v
                                    Execute mount command
                                  (mount.nfs / mount.cifs)
                                           |
                                           v
                                Mount attached to VFS target
```

#### AutoFS Map Types
*   **Master Map (`/etc/auto.master`)**: Top-level configuration file that pairs mount points with map sources.
*   **Indirect Maps**: Map paths relative to a key under a common base mount point (e.g., `/net/share1`, `/net/share2`).
*   **Direct Maps**: Map absolute paths anywhere in the filesystem hierarchy using key `/` (e.g., `/data/backup`).

#### Systemd Automount Units (`.automount` and `.mount`)
Systemd replaces traditional AutoFS by utilizing Linux kernel `autofs4` mountpoints natively:
*   An `.automount` unit monitors a directory path.
*   Upon first file access (`stat`, `ls`, `cd`), systemd traps the request and synchronously triggers the corresponding `.mount` unit.

---

## 2. Guided Production Labs

---

### Lab 1: Hardened Enterprise Samba 4 File Server Setup

#### Scenario
You are tasked with deploying a secure Samba share `/srv/samba/finance` for the `finance` department on a production Linux server. You must enforce strict user group access (`@finance`), custom file creation masks, VFS audit/recycle functionality, user mapping via `username map`, and validate the configuration using `testparm` and `pdbedit`.

#### Step 1: Directory Structure, Linux Groups, and System Users Creation
Execute the following commands to set up the system groups, users, and target shared directory:

```bash
sudo groupadd finance
sudo useradd -M -s /sbin/nologin alice
sudo useradd -M -s /sbin/nologin bob
sudo usermod -aG finance alice
sudo usermod -aG finance bob

sudo mkdir -p /srv/samba/finance
sudo chown -R root:finance /srv/samba/finance
sudo chmod -R 2770 /srv/samba/finance
```

Expected Output:
```text
(No error output returned; verification via ls -ld /srv/samba/finance)
drwxr-sr-x 2 root finance 4096 Aug  6 10:00 /srv/samba/finance
```

#### Step 2: Provision Samba Passdb Users
Add `alice` and `bob` to Samba's internal `tdbsam` database using `smbpasswd`:

```bash
sudo smbpasswd -a alice
sudo smbpasswd -a bob
```

Expected Output:
```text
New SMB password:
Retype new SMB password:
Added user alice.
New SMB password:
Retype new SMB password:
Added user bob.
```

Verify the passdb database using `pdbedit`:

```bash
sudo pdbedit -L -v -u alice
```

Expected Output:
```text
Unix username:        alice
NT username:          
Account Flags:        [U          ]
User SID:             S-1-5-21-3928172635-192837465-102938475-1001
Primary Group SID:    S-1-5-21-3928172635-192837465-102938475-513
Full Name:            
Home Directory:       \\server\alice
Home Dir Drive:       
Logon Script:         
Profile Path:         \\server\alice\profile
Domain:               SAMBASERVER
Account desc:         
Workstations:         
Munged dial:          
Logon time:           0
Logoff time:          never
Kickoff time:         never
Password last set:    Thu, 06 Aug 2026 10:05:00 UTC
Password can change:  Thu, 06 Aug 2026 10:05:00 UTC
Password must change: never
Last bad password:    0
Bad password count:   0
Logon hours:          FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEE
```

#### Step 3: Write Production Samba Configuration (`/etc/samba/smb.conf`)
Create or edit `/etc/samba/smb.conf` with production security settings:

```ini
[global]
    workgroup = WORKGROUP
    server string = Production Samba Gateway
    security = user
    passdb backend = tdbsam
    
    # Network Security & Binding
    interfaces = 127.0.0.1/8 192.168.1.0/24
    bind interfaces only = yes
    hosts allow = 127.0.0.1 192.168.1.0/24
    hosts deny = 0.0.0.0/0
    
    # Logging Configuration
    log file = /var/log/samba/log.%m
    max log size = 5000
    log level = 2
    
    # Encryption Protocols
    server min protocol = SMB3
    client max protocol = SMB3
    
    # User Mapping
    username map = /etc/samba/smbusers

[finance]
    comment = Confidential Financial Records
    path = /srv/samba/finance
    browseable = yes
    writable = yes
    read only = no
    valid users = @finance
    write list = @finance
    force group = finance
    create mask = 0660
    directory mask = 0770
    guest ok = no
    
    # VFS Modules for Audit & Recycle Bin Security
    vfs objects = recycle full_audit
    recycle:repository = .recycle
    recycle:keeptree = yes
    recycle:versions = yes
    full_audit:prefix = %u|%I|%m|%S
    full_audit:success = unlink rmdir mkdir write pwrite
    full_audit:failure = none
    full_audit:facility = LOCAL7
    full_audit:priority = NOTICE
```

Create `/etc/samba/smbusers` for mapping Windows domain identity `Administrator` to Linux `root`:

```text
root = Administrator admin
```

#### Step 4: Syntactical Validation with `testparm`
Validate `/etc/samba/smb.conf` for configuration syntax errors:

```bash
testparm -s /etc/samba/smb.conf
```

Expected Output:
```text
Load smb config files from /etc/samba/smb.conf
Loaded services file OK.
Weak crypto is allowed by smb.conf (default)

Server role: ROLE_STANDALONE

# Section name: [global]
	bind interfaces only = Yes
	hosts allow = 127.0.0.1 192.168.1.0/24
	hosts deny = 0.0.0.0/0
	interfaces = 127.0.0.1/8 192.168.1.0/24
	log file = /var/log/samba/log.%m
	log level = 2
	max log size = 5000
	server min protocol = SMB3
	server string = Production Samba Gateway
	username map = /etc/samba/smbusers
	idmap config * : backend = tdb

# Section name: [finance]
	comment = Confidential Financial Records
	create mask = 0660
	directory mask = 0770
	force group = finance
	path = /srv/samba/finance
	read only = No
	valid users = @finance
	write list = @finance
	vfs objects = recycle full_audit
	full_audit:facility = LOCAL7
	full_audit:failure = none
	full_audit:priority = NOTICE
	full_audit:prefix = %u|%I|%m|%S
	full_audit:success = unlink rmdir mkdir write pwrite
	recycle:versions = yes
	recycle:keeptree = yes
	recycle:repository = .recycle
```

#### Step 5: Start Samba Service and Test Authentication
Start `smbd`:

```bash
sudo systemctl restart smbd
sudo systemctl enable smbd
```

Test access via `smbclient` as user `alice`:

```bash
smbclient //127.0.0.1/finance -U alice%password123 -c "ls"
```

Expected Output:
```text
  .                                   D        0  Thu Aug  6 10:10:00 2026
  ..                                  D        0  Thu Aug  6 10:10:00 2026

		104806400 blocks of size 1024. 89234120 blocks available
```

---

### Verification Questions — Lab 1

1. **Question 1.1**: What is the architectural difference between `valid users = @finance` and `write list = @finance` inside `/etc/samba/smb.conf`? What happens if `read only = yes` is set in the share definition while `write list = alice` is defined?
2. **Question 1.2**: Why is `passdb backend = tdbsam` preferred over older legacy backends like `smbpasswd`? Which CLI utility must be used to inspect extended attributes, account locks, and SIDs stored within `tdbsam`?
3. **Question 1.3**: When `vfs objects = full_audit` is enabled, where does `smbd` send its audit log entries by default, and how can an administrator capture these events in a distinct file?

---

### Lab 2: Enterprise NFSv4 Server Setup with Identity Mapping & Diagnostic Verification

#### Scenario
Build an enterprise-grade NFSv4 file server exporting `/exports/secdata` exclusively via NFSv4. Set up pseudo-root exports (`fsid=0`), enforce numeric user id mapping via `rpc.idmapd`, configure client exports in `/etc/exports`, and diagnose RPC daemon operations with `nfsstat`, `rpcinfo`, and `exportfs`.

#### Step 1: Build NFSv4 Directory Hierarchy and Pseudo-Root
NFSv4 introduces a single unified file system namespace. Create a pseudo-root directory `/exports` and bind-mount the actual shared data directory into it:

```bash
sudo mkdir -p /exports/secdata
sudo mkdir -p /srv/nfs/secdata

# Apply bind mount to integrate into the pseudo-root
sudo mount --bind /srv/nfs/secdata /exports/secdata
```

To make this bind mount permanent across system reboots, append the following line to `/etc/fstab`:

```text
/srv/nfs/secdata    /exports/secdata    none    bind    0    0
```

#### Step 2: Configure `/etc/idmapd.conf`
Configure the NFSv4 ID mapping daemon on both server and client to translate `user@domain` strings to local system numeric UIDs:

```ini
[General]
Verbosity = 2
Pipefs-Directory = /var/lib/nfs/rpc_pipefs
Domain = internal.lab.net

[Mapping]
Nobody-User = nobody
Nobody-Group = nogroup

[Translation]
Method = nsswitch
```

#### Step 3: Configure `/etc/exports`
Define the NFSv4 exports in `/etc/exports`. The pseudo-root must be declared with `fsid=0` (or `fsid=root`):

```text
# Pseudo-filesystem Root export for NFSv4 clients
/exports                  192.168.1.0/24(ro,sync,no_subtree_check,crossmnt,fsid=0)

# Export definition for secure data
/exports/secdata          192.168.1.0/24(rw,sync,no_subtree_check,root_squash,anonuid=65534,anongid=65534)
```

#### Step 4: Export Shares and Reload Daemon
Apply exports using `exportfs` and start the required daemons:

```bash
sudo exportfs -rav
sudo systemctl restart nfs-server
sudo systemctl restart rpc-idmapd
```

Expected Output from `exportfs -rav`:
```text
exporting 192.168.1.0/24:/exports/secdata
exporting 192.168.1.0/24:/exports
```

Verify active exports with `exportfs -v`:

```bash
sudo exportfs -v
```

Expected Output:
```text
/exports      	192.168.1.0/24(ro,sync,wdelay,hide,nocrossmnt,secure,no_root_squash,no_all_squash,no_subtree_check,secure_locks,acl,no_pnfs,fsid=0,anonuid=65534,anongid=65534)
/exports/secdata
              	192.168.1.0/24(rw,sync,wdelay,hide,nocrossmnt,secure,root_squash,no_all_squash,no_subtree_check,secure_locks,acl,no_pnfs,anonuid=65534,anongid=65534)
```

#### Step 5: Advanced RPC Diagnostics
Execute `rpcinfo` to ensure RPC service registration is clean:

```bash
rpcinfo -p localhost
```

Expected Output:
```text
   program vers proto   port  service
    100000    4   tcp    111  portmapper
    100000    3   tcp    111  portmapper
    100000    2   tcp    111  portmapper
    100005    1   tcp  20048  mountd
    100005    3   tcp  20048  mountd
    100003    3   tcp   2049  nfs
    100003    4   tcp   2049  nfs
```

Execute `nfsstat -s` to view NFS server statistics:

```bash
nfsstat -s
```

Expected Output:
```text
Server rpc stats:
calls      badcalls   badclnt    badauth    xdrcall
124        0          0          0          0

Server nfs v4 operations:
null         compound     
2 0%         122 98%      

Server nfs v4 compound ops:
OP0-BADOP    OP1-READLINK OP2-GATTR    OP3-LOOKUP   OP4-GETATTR  
0 0%         0 0%         0 0%         12 9%        45 36%       
OP5-SETATTR  OP6-LOOKUPP  OP7-NVERIFY  OP8-VERIFY   OP9-HOMEPAGE 
0 0%         4 3%         0 0%         0 0%         0 0%         
```

Mount the NFSv4 share from a client machine (or localhost):

```bash
sudo mkdir -p /mnt/nfs_client
sudo mount -t nfs4 -o proto=tcp,port=2049 192.168.1.50:/secdata /mnt/nfs_client
```

---

### Verification Questions — Lab 2

1. **Question 2.1**: In NFSv4, why is `fsid=0` (or `fsid=root`) required in `/etc/exports`, and how does client mount syntax differ between NFSv3 (`mount -t nfs 192.168.1.50:/exports/secdata /mnt`) and NFSv4 (`mount -t nfs4 192.168.1.50:/secdata /mnt`)?
2. **Question 2.2**: Explain the operational consequence of `root_squash` versus `no_root_squash` in `/etc/exports`. If a remote user with UID 0 writes a file to an export configured with `root_squash,anonuid=5000,anongid=5000`, what ownership will the newly created file hold on the local disk?
3. **Question 2.3**: What diagnostic information does `showmount -e <NFS_IP>` provide, and why might `showmount` fail when querying a pure NFSv4 server that has disabled `rpcbind` and `rpc.mountd`?

---

### Lab 3: Dynamic Automounting with AutoFS and Systemd Automount Units

#### Scenario
Deploy dynamic target mounting using two distinct enterprise techniques:
1. AutoFS Indirect and Direct Maps for NFS home/project directories.
2. Native `systemd.automount` units for Samba shares.

---

#### Part A: AutoFS Map Implementation

##### Step 1: Master Map Configuration (`/etc/auto.master`)
Configure `/etc/auto.master` to register an indirect map for `/mnt/auto` and a direct map via `/etc/auto.direct`:

```text
# Master Map
/mnt/auto      /etc/auto.indirect  --timeout=300
/-             /etc/auto.direct    --timeout=180
```

##### Step 2: Indirect Map File (`/etc/auto.indirect`)
Create `/etc/auto.indirect` for dynamic project directory mounting:

```text
# Key        Options                          Location
projects     -rw,soft,intr,nosuid,proto=tcp   192.168.1.50:/exports/secdata
docs         -ro,soft,intr,proto=tcp          192.168.1.50:/exports/docs
```

##### Step 3: Direct Map File (`/etc/auto.direct`)
Create `/etc/auto.direct` for explicit filesystem paths:

```text
# Absolute Path           Options                       Location
/var/build/artifacts      -rw,sync,proto=tcp,hard       192.168.1.50:/exports/builds
```

##### Step 4: Start AutoFS Service and Test Access
Ensure mount point directories exist, restart `autofs`, and trigger on-demand mounts:

```bash
sudo mkdir -p /var/build/artifacts
sudo systemctl restart autofs
sudo systemctl enable autofs
```

Trigger automount by accessing the path:

```bash
ls -l /mnt/auto/projects
```

Verify active mount using `df -hT` or `mount`:

```bash
mount | grep secdata
```

Expected Output:
```text
192.168.1.50:/exports/secdata on /mnt/auto/projects type nfs4 (rw,nosuid,relatime,vers=4.2,rsize=1048576,wsize=1048576,namlen=255,hard,proto=tcp,timeo=600,retrans=2,sec=sys,clientaddr=192.168.1.10,local_lock=none,addr=192.168.1.50)
```

---

#### Part B: Systemd Automount Unit Implementation

##### Step 1: Define `.mount` Unit (`/etc/systemd/system/mnt-samba-finance.mount`)
Systemd unit names **must** strictly match the target mount path string (e.g., `/mnt/samba/finance` maps to `mnt-samba-finance.mount`):

```ini
[Unit]
Description=Production Samba Finance Share Mount
After=network.target

[Mount]
What=//192.168.1.50/finance
Where=/mnt/samba/finance
Type=cifs
Options=credentials=/etc/samba/credentials.cred,uid=1001,gid=1001,file_mode=0660,dir_mode=0770

[Install]
WantedBy=multi-user.target
```

Create credentials file `/etc/samba/credentials.cred`:

```ini
username=alice
password=password123
domain=WORKGROUP
```

Set secure permissions on the credentials file:

```bash
sudo chmod 0600 /etc/samba/credentials.cred
```

##### Step 2: Define `.automount` Unit (`/etc/systemd/system/mnt-samba-finance.automount`)

```ini
[Unit]
Description=Automount for Production Samba Finance Share
ConditionPathExists=/mnt/samba/finance

[Automount]
Where=/mnt/samba/finance
TimeoutIdleSec=300

[Install]
WantedBy=multi-user.target
```

##### Step 3: Enable and Activate Systemd Automount
Reload systemd daemon, create the target mount directory, and activate **only** the `.automount` unit:

```bash
sudo mkdir -p /mnt/samba/finance
sudo systemctl daemon-reload
sudo systemctl enable --now mnt-samba-finance.automount
```

Check unit status:

```bash
systemctl status mnt-samba-finance.automount
```

Expected Output:
```text
● mnt-samba-finance.automount - Automount for Production Samba Finance Share
     Loaded: loaded (/etc/systemd/system/mnt-samba-finance.automount; enabled; vendor preset: disabled)
     Active: active (waiting) since Thu 2026-08-06 10:25:00 UTC; 10s ago
   Triggers: ● mnt-samba-finance.mount
      Where: /mnt/samba/finance

Aug 06 10:25:00 server systemd[1]: Set up automount Automount for Production Samba Finance Share.
```

Trigger automount via CLI access:

```bash
ls -la /mnt/samba/finance
```

Verify active mount unit:

```bash
systemctl status mnt-samba-finance.mount
```

Expected Output:
```text
● mnt-samba-finance.mount - Production Samba Finance Share Mount
     Loaded: loaded (/etc/systemd/system/mnt-samba-finance.mount; static)
     Active: active (mounted) since Thu 2026-08-06 10:26:12 UTC; 2s ago
      Where: /mnt/samba/finance
       What: //192.168.1.50/finance
      Tasks: 0 (limit: 4915)
     Memory: 1.2M
     CGroup: /system.slice/mnt-samba-finance.mount
```

---

### Verification Questions — Lab 3

1. **Question 3.1**: In AutoFS `/etc/auto.master`, what is the precise syntactic and operational difference between an indirect entry like `/mnt/auto /etc/auto.indirect` and a direct entry like `/- /etc/auto.direct`?
2. **Question 3.2**: When configuring systemd automount units, why is it mandatory to name the files strictly according to their destination path (e.g., `mnt-samba-finance.automount` for `/mnt/samba/finance`)? What happens if the filename deviates from this convention?
3. **Question 3.3**: Why should administrators activate and enable the `.automount` unit via systemctl, but **not** enable the `.mount` unit directly when utilizing systemd on-demand automounting?

---

## 3. Advanced Diagnostic & Troubleshooting Playbook

### 3.1 Samba Diagnostic Flowchart & Commands

```
                              Samba Connection Failure
                                         |
                       +-----------------+-----------------+
                       |                                   |
                       v                                   v
             Configuration Syntax Check           Network/Auth Check
                       |                                   |
              `testparm -s /etc/samba/smb.conf`    `smbclient -L //IP -U user`
                       |                                   |
                       v                                   v
             Inspect Daemon Passdb                 Packet Level Trace
                       |                                   |
              `pdbedit -L -v -u user`              `tcpdump -i eth0 port 445`
```

#### Diagnostic Commands

1.  **Validate configuration syntax and active defaults**:
    ```bash
    testparm -v /etc/samba/smb.conf
    ```
2.  **Inspect Samba user attributes, flags, and SIDs**:
    ```bash
    sudo pdbedit -L -v
    ```
3.  **Perform network client share listing and protocol negotiation check**:
    ```bash
    smbclient -L //127.0.0.1 -U alice --option="client max protocol=SMB3"
    ```
4.  **Query NetBIOS name resolution**:
    ```bash
    nmblookup -A 192.168.1.50
    ```
5.  **Audit real-time SMB active connections**:
    ```bash
    sudo smbstatus --shares --processes --locks
    ```

---

### 3.2 NFS Diagnostic Flowchart & Commands

```
                               NFS Mount Failure
                                       |
                     +-----------------+-----------------+
                     |                                   |
                     v                                   v
             RPC Daemon Registration            Export Table Verification
                     |                                   |
             `rpcinfo -p <NFS_IP>`               `exportfs -v` or `showmount -e`
                     |                                   |
                     v                                   v
           Protocol Level Counters              Kernel Trace Analysis
                     |                                   |
             `nfsstat -c` / `nfsstat -s`         `rpcdebug -m nfs -s all`
```

#### Diagnostic Commands

1.  **Verify RPC Portmapper registrations**:
    ```bash
    rpcinfo -p 192.168.1.50
    ```
2.  **Inspect kernel export table directly**:
    ```bash
    sudo exportfs -v
    ```
3.  **Check server-side NFS statistics for dropped calls or authentication failures**:
    ```bash
    nfsstat -s
    ```
4.  **Check client-side NFS RPC call counters**:
    ```bash
    nfsstat -c
    ```
5.  **Enable Linux kernel NFS debugging flags dynamically**:
    ```bash
    # Enable NFS client debugging
    sudo rpcdebug -m nfs -s all
    
    # Read diagnostic kernel ring buffer
    sudo dmesg -wH | grep -i nfs
    
    # Clear debugging flags after diagnosis
    sudo rpcdebug -m nfs -c all
    ```
6.  **Network packet capture for NFSv4 compound operations**:
    ```bash
    sudo tcpdump -nn -s 0 -i any port 2049 -w nfs_trace.pcap
    ```

---

## 4. Official Documentation References

*   **Linux Professional Institute (LPI) LPIC-2 Objectives**: [https://www.lpi.org/our-certifications/lpic-2-overview/](https://www.lpi.org/our-certifications/lpic-2-overview/)
*   **Samba Official Documentation & smb.conf Manual**: [https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html](https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html)
*   **Linux Kernel NFS Documentation**: [https://www.kernel.org/doc/html/latest/filesystems/nfs/index.html](https://www.kernel.org/doc/html/latest/filesystems/nfs/index.html)
*   **AutoFS Linux Documentation**: [https://man7.org/linux/man-pages/man5/autofs.5.html](https://man7.org/linux/man-pages/man5/autofs.5.html)
*   **Systemd Mount Unit Specifications**: [https://www.freedesktop.org/software/systemd/man/latest/systemd.mount.html](https://www.freedesktop.org/software/systemd/man/latest/systemd.mount.html)

---

## 5. Verification Answers & Detailed Explanations

<details>
<summary>Click to expand Answer Key & Explanations</summary>

### Lab 1 Answers

*   **Answer 1.1**:
    *   `valid users = @finance` acts as an **authentication/authorization gatekeeper**: only users belonging to the `finance` Linux group are allowed to connect to the share. All other authenticated users are denied access.
    *   `write list = @finance` specifies which authorized users are granted write permissions.
    *   If `read only = yes` is set globally in the share definition, but `write list = alice` (or `@finance`) is defined, Samba **overrides** `read only = yes` specifically for the users listed in `write list`. Thus, users in `write list` gain read-write access, while all other valid users remain restricted to read-only access.

*   **Answer 1.2**:
    *   `tdbsam` stores user accounts in a structured binary TDB database (`passdb.tdb`), supporting indexed lookups, SIDs, user account flags (e.g., locked, disabled, password never expires), password history, and bad password counts. Legacy `smbpasswd` was a plain flat file lacking extended SID attributes and performance scalability.
    *   The command line utility used to inspect, modify, and manage accounts in `tdbsam` is **`pdbedit`** (e.g., `pdbedit -L -v`).

*   **Answer 1.3**:
    *   By default, `vfs objects = full_audit` outputs syslog events using the facility `LOCAL7` (or syslog facility specified in `full_audit:facility`). On Linux systems, these messages land in `/var/log/syslog` or `/var/log/messages` alongside standard system events.
    *   To route full_audit events into a dedicated log file (e.g., `/var/log/samba/audit.log`), an administrator configures a rule in the system logging daemon (rsyslog or syslog-ng):
        ```text
        # /etc/rsyslog.d/samba-audit.conf
        local7.*    /var/log/samba/audit.log
        & stop
        ```
        Then restart rsyslog: `systemctl restart rsyslog`.

---

### Lab 2 Answers

*   **Answer 2.1**:
    *   In NFSv4, `fsid=0` (or `fsid=root`) defines the **root of the pseudo-filesystem hierarchy**. NFSv4 clients view all exported directories relative to this designated root.
    *   **Mount Syntax Difference**:
        *   NFSv3 requires specifying the full absolute server filesystem path:
            `mount -t nfs 192.168.1.50:/exports/secdata /mnt`
        *   NFSv4 specifies paths relative to the pseudo-root `fsid=0`:
            `mount -t nfs4 192.168.1.50:/secdata /mnt` (omitting `/exports`).

*   **Answer 2.2**:
    *   `root_squash` maps any incoming requests from UID 0 / GID 0 (the client's `root` user) to the anonymous unprivileged account (`anonuid`/`anongid`, defaulting to `nobody`/`65534`). `no_root_squash` disables this protection, allowing remote root clients full root capabilities on the server's filesystem.
    *   If a remote root user creates a file on an export with `root_squash,anonuid=5000,anongid=5000`, the resulting file on the local server disk will be owned by **UID 5000** and **GID 5000**.

*   **Answer 2.3**:
    *   `showmount -e <NFS_IP>` queries the remote RPC `mountd` daemon to list all active directory exports declared in `/etc/exports`.
    *   In a pure NFSv4 environment where `rpcbind` (port 111) and `rpc.mountd` (port 20048) are disabled for security, `showmount` will **fail** with a RPC connection timeout error (`rpc mount export: RPC: Unable to receive; errno = Connection refused`), because NFSv4 does not use `rpc.mountd` or `rpcbind` (it operates entirely over TCP port 2049).

---

### Lab 3 Answers

*   **Answer 3.1**:
    *   An **Indirect Map** (`/mnt/auto /etc/auto.indirect`) manages dynamic subdirectories *under* a specified base directory (`/mnt/auto`). The base directory `/mnt/auto` is owned by AutoFS, and subdirectories (e.g., `/mnt/auto/projects`) appear on-demand when accessed.
    *   A **Direct Map** (`/- /etc/auto.direct`) specifies absolute target mount paths located anywhere across the system filesystem hierarchy (e.g., `/var/build/artifacts`). The key `/-` indicates to AutoFS that map keys contain full absolute paths.

*   **Answer 3.2**:
    *   Systemd uses strict string transformation algorithms to convert mount point paths into unit names: slashes are replaced with hyphens (e.g., `/mnt/samba/finance` $\rightarrow$ `mnt-samba-finance.mount` / `mnt-samba-finance.automount`).
    *   If the filename deviates from this exact path mapping, systemd will refuse to load or link the automount unit to its corresponding target directory, failing with an invalid unit configuration error (`Unit name ... does not match path ...`).

*   **Answer 3.3**:
    *   The `.automount` unit is responsible for creating the kernel autofs file descriptor on the target path to monitor incoming filesystem calls. When access occurs, the `.automount` unit automatically triggers and starts the associated `.mount` unit on demand.
    *   If an administrator manually enables and starts the `.mount` unit directly at boot, systemd will mount the remote network share immediately during bootup, completely bypassing the on-demand automounting mechanism and keeping the network mount permanently attached.

</details>