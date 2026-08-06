# LPIC-3 Exam 300-300 (v3.0) — Topic 1.1: Samba Basics

## 1. Deep-Dive Architectural & Technical Overview

Samba provides file and print services for clients using the Server Message Block (SMB) / Common Internet File System (CIFS) protocol suite across heterogeneous networks. Understanding Samba at a production SRE level requires mastering its underlying process model, state storage engines, network socket behavior, protocol dialect negotiation, and configuration subsystem.

### 1.1 Process Architecture & Daemons
Samba operates through three primary daemons:

*   **`smbd` (SMB/CIFS Service):** Handles authentication, authorization, access control, file/print sharing, and byte-range locking. In modern releases, `smbd` follows a hybrid process model: a parent `smbd` daemon listens on TCP ports and forks a child process for each incoming client connection, while offloading background tasks to worker pools (e.g., asynchronous I/O, notify sub-systems).
*   **`nmbd` (NetBIOS Name Service Daemon):** Provides NetBIOS over TCP/IP (NBT) resolution and browsing services. It manages NetBIOS name registration, resolution (WINS client/server), and local master browser elections. *Note: `nmbd` is not required when operating in pure Active Directory or modern Direct-Hosted SMB environments without legacy NetBIOS dependence.*
*   **`winbindd` (Name Service Switch / Pluggable Authentication Module Daemon):** Unified interface for resolving user/group information and authenticating domain users against Active Directory (AD) or NT4 Domains. It maps Windows Security Identifiers (SIDs) to POSIX UIDs/GIDs via configurable `idmap` backends.

#### Memory Architecture & TDB Database Layer
Samba uses **TDB (Trivial Data Base)**—a lightweight, non-relational key-value database allowing concurrent access by multiple processes—to maintain transient and persistent state:
*   `passdb.tdb`: Local user credentials and account flags (managed via `pdbedit`).
*   `secrets.tdb`: Sensitive domain machine passwords, kerberos keytabs, and local machine SID.
*   `gencache.tdb`: Cache for name resolution, domain controllers, and SID-to-name lookups.
*   `locking.tdb`: Tracks active byte-range locks and opportunistic locks (oplocks / leases).
*   `brlock.tdb`: POSIX and SMB byte-range locking allocations across child `smbd` processes.

### 1.2 Networking Protocol Mapping & Ports

| Protocol Service | Port / Transport | Process | Architectural Function |
| :--- | :--- | :--- | :--- |
| **NetBIOS Name Service (NBT NS)** | `137/UDP` | `nmbd` | NetBIOS name query, registration, and WINS resolution. |
| **NetBIOS Datagram Service** | `138/UDP` | `nmbd` | NetBIOS browser announcements and mail-slot messages. |
| **NetBIOS Session Service** | `139/TCP` | `smbd` | SMB wrapped inside NetBIOS Session layer (Legacy SMB1). |
| **Direct Hosted SMB** | `445/TCP` | `smbd` | Raw SMB directly over TCP/IP (SMB 2.x / 3.x, bypasses NBT). |

### 1.3 SMB Protocol Dialects & Evolution

1.  **SMB 1.0 / CIFS:** Chatty, high-latency protocol. Vulnerable to structural exploits (e.g., WannaCry / EternalBlue). Obsoleted and disabled by default (`server min protocol = SMB2_02`).
2.  **SMB 2.02 / 2.1:** Introduced in Windows Vista/7 and Samba 3.6. Reduced command count (compounding multiple requests into single packets), enlarged buffer sizes, supported dynamic re-auth, and added client-side resilient handles.
3.  **SMB 3.0 / 3.02:** Introduced in Samba 4.0. Added end-to-end AES-128-CCM encryption, SMB Multichannel (binding multiple network interfaces for throughput and fault tolerance), and Directory Leasing.
4.  **SMB 3.1.1:** Introduced pre-authentication integrity (SHA-512 hashes of negotiation exchanges to prevent downgrade attacks), AES-128-GCM encryption, and enhanced cluster state handling.

### 1.4 Samba 3 vs. Samba 4 Architectural Paradigm

*   **Samba 3:** Focused on file server roles, standalone authentication, NT4-style Primary Domain Controller (PDC), and domain membership. Relying heavily on external LDAP and Heimdal/MIT Kerberos configurations.
*   **Samba 4:** Complete rewrite introducing a fully integrated **Active Directory Domain Controller (AD DC)** implementation. Includes an embedded KDC (Kerberos Key Distribution Center), internal DNS server / BIND9 plugin, internal LDAP server (`ldb`), and Active Directory replication protocols (DRSUAPI). Samba 4 can still run in classical file-server mode (using `smbd` and `winbindd` without AD DC services enabled).

---

## 2. Official References & Citation Links

*   **LPI Official Exam Objectives:** [LPIC-3 Exam 300-300 Objectives](https://www.lpi.org/our-certifications/lpic-3-300-overview/)
*   **Samba Official Documentation & HowTos:** [Samba Wiki & Manual Pages](https://www.samba.org/samba/docs/)
*   **Samba Architecture & Internals:** [Samba Tech Docs - TDB & Process Architecture](https://wiki.samba.org/index.php/Samba_Internal_Architecture)
*   **SMB Protocol Specification (Microsoft Open Specs):** [MS-SMB2 Protocol Specification](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-smb2/)

---

## 3. Hands-On Guided Exercises

### Setup Prerequisites
Ensure a Linux instance (Debian/Ubuntu or RHEL/Rocky Linux) with root access and `samba`, `samba-common`, `smbclient`, `tdb-tools`, and `tshark`/`tcpdump` installed.

---

### Exercise 1: Low-Level Daemon Inspection, Port Binding, and SMB Dialect Negotiation

#### Step-by-Step Instructions

1.  Inspect the installed Samba binaries and verify system services. Enable and start `smbd` and `nmbd`:
    ```bash
    sudo systemctl stop smbd nmbd winbind 2>/dev/null
    sudo systemctl enable --now smbd nmbd
    sudo systemctl status smbd nmbd --no-pager
    ```
    *Expected Output snippet:*
    ```text
    ● smbd.service - Samba SMB Daemon
       Loaded: loaded (/lib/systemd/system/smbd.service; enabled; vendor preset: enabled)
       Active: active (running) since Thu 2026-08-06 12:45:00 UTC; 5s ago
         Docs: man:smbd(8)
               man:samba(7)
               man:smb.conf(5)
       Main PID: 14205 (smbd)
         Status: "smbd: ready to serve requests..."
          Tasks: 4 (limit: 4915)
         Memory: 21.4M
     CGroup: /system.slice/smbd.service
             ├─14205 /usr/sbin/smbd --foreground --no-process-group
             ├─14207 /usr/sbin/smbd --foreground --no-process-group
             ├─14208 /usr/sbin/smbd --foreground --no-process-group
             └─14210 /usr/sbin/smbd --foreground --no-process-group
    ```

2.  Verify socket bindings and listening TCP/UDP ports using `ss`:
    ```bash
    sudo ss -tulpn | grep -E 'smbd|nmbd'
    ```
    *Expected Output:*
    ```text
    udp   UNCONN 0      0           0.0.0.0:137       0.0.0.0:*    users:(("nmbd",pid=14215,fd=17))
    udp   UNCONN 0      0           0.0.0.0:138       0.0.0.0:*    users:(("nmbd",pid=14215,fd=18))
    tcp   LISTEN 0      50          0.0.0.0:139       0.0.0.0:*    users:(("smbd",pid=14205,fd=39))
    tcp   LISTEN 0      50          0.0.0.0:445       0.0.0.0:*    users:(("smbd",pid=14205,fd=38))
    tcp   LISTEN 0      50             [::]:139          [::]:*    users:(("smbd",pid=14205,fd=37))
    tcp   LISTEN 0      50             [::]:445          [::]:*    users:(("smbd",pid=14205,fd=36))
    ```

3.  Query the local system for NetBIOS names using `nmblookup`:
    ```bash
    nmblookup -A 127.0.0.1
    ```
    *Expected Output:*
    ```text
    Looking up status of 127.0.0.1
        SAMBA-HOST      <00> -         B <ACTIVE> 
        SAMBA-HOST      <03> -         B <ACTIVE> 
        SAMBA-HOST      <20> -         B <ACTIVE> 
        WORKGROUP       <00> - <GROUP> B <ACTIVE> 
        WORKGROUP       <1e> - <GROUP> B <ACTIVE> 

    MAC Address = 00-00-00-00-00-00
    ```

4.  Connect locally with `smbclient` specifying explicit protocol dialects to trace negotiation. First, attempt a connection forcing SMB3_11:
    ```bash
    smbclient -L //localhost -U guest% -m SMB3_11
    ```
    *Expected Output:*
    ```text
    Sharename       Type      Comment
    ---------       ----      -------
    print$          Disk      Printer Drivers
    IPC$            IPC       IPC Service (Samba 4.19.5-Ubuntu)
    SMB1 trading disabled serve mode
    ```

5.  Inspect active client connections, process IDs, and connected dialects using `smbstatus`:
    ```bash
    sudo smbstatus
    ```
    *Expected Output:*
    ```text
    Samba version 4.19.5-Ubuntu
    PID     Username     Group        Machine--------------Protocol Version----------------
    14312   nobody       nogroup      127.0.0.1 (ipv4:127.0.0.1:48392) SMB3_11           

    Service      pid     Machine       Connected at                     Encryption   Signing     
    ---------------------------------------------------------------------------------------------
    IPC$         14312   127.0.0.1     Thu Aug  6 12:48:10 2026 UTC     -            -           

    No locked files
    ```

---

#### Verification Questions — Exercise 1

*   **Question 1.1:** Why does `smbd` listen on both TCP port 139 and TCP port 445 by default, and what happens to network packet overhead when a client connects exclusively over port 445?
*   **Question 1.2:** In the output of `smbstatus`, a child PID `14312` is attached to `127.0.0.1`. What is the life cycle of this specific child process relative to the main `smbd` parent daemon?

---

### Exercise 2: Production-Grade `smb.conf` Configuration, Macro Variable Substitution, and TDB State Inspection

#### Step-by-Step Instructions

1.  Backup the default `smb.conf` file:
    ```bash
    sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
    ```

2.  Create an optimized production `smb.conf` file featuring global security hardening, macro usage, dynamic path expansion, and custom share stanzas:
    ```bash
    cat << 'EOF' | sudo tee /etc/samba/smb.conf
    [global]
       workgroup = ENTERPRISE
       server string = Core Storage Node %h (Samba %v)
       netbios name = STOR-NODE-01
       security = user
       passdb backend = tdbsam
       
       # Protocol Hardening & Dialects
       server min protocol = SMB2_10
       server max protocol = SMB3_11
       client max protocol = SMB3_11
       smb encrypt = required
       server signing = required
       
       # Logging and Diagnostics
       log file = /var/log/samba/log.%m
       max log size = 10000
       logging = file
       log level = 1 auth:3 smb2:2

       # Disable legacy NetBIOS if standalone
       disable netbios = no

    [eng-data]
       comment = Engineering Data Depository for %U
       path = /srv/samba/eng/%U
       read only = no
       browseable = yes
       valid users = @eng-team
       create mask = 0660
       directory mask = 0770
       force group = eng-team

    [node-audit]
       comment = Node Access Logs for Client %I
       path = /srv/samba/audit/%m
       read only = yes
       guest ok = no
       valid users = admin
    EOF
    ```

3.  Validate the syntax of `/etc/samba/smb.conf` using `testparm`:
    ```bash
    testparm -s
    ```
    *Expected Output:*
    ```text
    Load smb config files from /etc/samba/smb.conf
    Loaded services file OK.
    Weak crypto is allowed
    Server role: ROLE_STANDALONE

    # Processing section "[global]"
    # Processing section "[eng-data]"
    # Processing section "[node-audit]"
    Global parameter server signing = required changed to always!
    Loaded services file OK.
    [global]
    	client max protocol = SMB3_11
    	log file = /var/log/samba/log.%m
    	log level = 1 auth:3 smb2:2
    	max log size = 10000
    	netbios name = STOR-NODE-01
    	passdb backend = tdbsam
    	security = USER
    	server max protocol = SMB3_11
    	server min protocol = SMB2_10
    	server signing = REQUIRED
    	server string = Core Storage Node %h (Samba %v)
    	smb encrypt = REQUIRED
    	workgroup = ENTERPRISE
    	idmap config * : backend = tdb

    [eng-data]
    	browseable = Yes
    	comment = Engineering Data Depository for %U
    	create mask = 0660
    	directory mask = 0770
    	force group = eng-team
    	path = /srv/samba/eng/%U
    	read only = No
    	valid users = @eng-team

    [node-audit]
    	comment = Node Access Logs for Client %I
    	path = /srv/samba/audit/%m
    	valid users = admin
    ```

4.  Execute `testparm` with the verbose flag `-v` filtered to inspect default values of macro-sensitive settings:
    ```bash
    testparm -v | grep -E "lock directory|state directory|private dir"
    ```
    *Expected Output:*
    ```text
    	lock directory = /var/cache/samba
    	state directory = /var/lib/samba
    	private dir = /var/lib/samba/private
    ```

5.  Create a local POSIX group `eng-team` and user `developer01`, add the user to Samba's `passdb.tdb` database using `smbpasswd`:
    ```bash
    sudo groupadd eng-team
    sudo useradd -m -g eng-team -s /bin/false developer01
    sudo mkdir -p /srv/samba/eng/developer01
    sudo chown -R developer01:eng-team /srv/samba/eng/developer01
    sudo chmod 0770 /srv/samba/eng/developer01

    # Set Samba user password
    (echo "SecureP@ss2026!"; echo "SecureP@ss2026!") | sudo smbpasswd -a developer01
    ```
    *Expected Output:*
    ```text
    Added user developer01.
    ```

6.  Inspect the local Samba passdb account entry using `pdbedit`:
    ```bash
    sudo pdbedit -L -v -u developer01
    ```
    *Expected Output:*
    ```text
    Unix username:        developer01
    NT username:          
    Account Flags:        [U          ]
    User SID:             S-1-5-21-3921827401-1823912381-912830192-1001
    Primary Group SID:    S-1-5-21-3921827401-1823912381-912830192-513
    Full Name:            
    Home Directory:       \\STOR-NODE-01\developer01
    HomeDir Drive:        
    Logon Script:         
    Profile Path:         \\STOR-NODE-01\developer01\profile
    Domain:               STOR-NODE-01
    Account created:      Thu, 06 Aug 2026 12:50:12 UTC
    Password last set:    Thu, 06 Aug 2026 12:50:12 UTC
    ```

7.  Inspect the raw binary structure of `passdb.tdb` using `tdbdump`:
    ```bash
    sudo tdbdump /var/lib/samba/private/passdb.tdb | head -n 20
    ```
    *Expected Output snippet:*
    ```text
    key(13) = "USER_developer01\00"
    data(218) = "\00\00\00\00\09\70\35\67\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\07\64\65\76\65\6C\6F\70\65\72\30\31\00..."
    key(9) = "INFO/version\00"
    data(4) = "\04\00\00\00"
    key(19) = "RID_000003e9\00"
    data(13) = "developer01\00"
    ```

---

#### Verification Questions — Exercise 2

*   **Question 2.1:** What is the specific operational difference between the macro variables `%u`, `%U`, `%m`, `%I`, and `%v` when evaluated at runtime in `smb.conf`?
*   **Question 2.2:** What security risk is mitigated by setting `server min protocol = SMB2_10` and `smb encrypt = required` at the global level?

---

### Exercise 3: Runtime Operations, Live Signal Management, and TDB Maintenance

#### Step-by-Step Instructions

1.  Reload Samba configuration dynamically without terminating active client sockets using `smbcontrol`:
    ```bash
    sudo smbcontrol smbd reload-config
    ```
    *Expected Output:*
    ```text
    (No output indicates successful signal dispatch via IPC messaging sub-system)
    ```

2.  Increase the authentication logging verbosity live at runtime without restarting the daemon:
    ```bash
    sudo smbcontrol smbd set-log-level 3
    ```

3.  Verify the updated log level settings using `smbcontrol`:
    ```bash
    sudo smbcontrol smbd profile status 2>/dev/null || sudo tail -n 10 /var/log/samba/log.smbd
    ```

4.  Perform an online backup of the active Samba state and account database files (`secrets.tdb` and `passdb.tdb`) using `tdbbackup`:
    ```bash
    sudo mkdir -p /var/backups/samba
    sudo tdbbackup /var/lib/samba/private/passdb.tdb -s .bak /var/backups/samba/passdb.tdb.bak
    sudo tdbbackup /var/lib/samba/private/secrets.tdb -s .bak /var/backups/samba/secrets.tdb.bak
    ls -la /var/backups/samba/
    ```
    *Expected Output:*
    ```text
    total 16
    drwxr-xr-x 2 root root 4096 Aug  6 12:55 .
    drwxr-xr-x 3 root root 4096 Aug  6 12:55 ..
    -rw------- 1 root root 4218 Aug  6 12:55 passdb.tdb.bak
    -rw------- 1 root root 8192 Aug  6 12:55 secrets.tdb.bak
    ```

5.  Integrity check the backed-up TDB database using `tdbtool`:
    ```bash
    sudo tdbtool /var/backups/samba/passdb.tdb.bak check
    ```
    *Expected Output:*
    ```text
    Database integrity check passed. 3 records found.
    ```

6.  Reset the log level back to operational default (1):
    ```bash
    sudo smbcontrol smbd set-log-level 1
    ```

---

#### Verification Questions — Exercise 3

*   **Question 3.1:** Why is `tdbbackup` preferred over standard file copy utilities (`cp` or `rsync`) when backing up Samba state files while `smbd` is running?
*   **Question 3.2:** What IPC mechanism does `smbcontrol` use to communicate state modifications to running `smbd` and `nmbd` daemons?

---

## 4. Verification Solutions & Technical Answers

<details>
<summary><strong>Click to expand Solutions & Detailed Explanations</strong></summary>

### Solution to Exercise 1

*   **Answer 1.1:**
    *   **Port 139 (SMB over NBT):** Operates by encapsulating SMB frames inside the NetBIOS Session Service layer (RFC 1001/1002). This requires a NetBIOS session setup handshake preceding SMB negotiation.
    *   **Port 445 (Direct-Hosted SMB):** Eliminates the NetBIOS Session layer entirely. SMB PDUs (Protocol Data Units) are transmitted directly over raw TCP with a 4-byte length header.
    *   **Overhead Reduction:** Connecting exclusively over Port 445 removes NetBIOS encapsulation overhead, eliminates extra NBT Session Request round-trips during connection establishment, and bypasses NetBIOS name resolution dependencies (`nmbd`).
*   **Answer 1.2:**
    *   When a client connects to TCP port 445 or 139, the main parent `smbd` process calls `accept()` to obtain a new client socket.
    *   The parent process immediately calls `fork()` to create a dedicated child process (PID `14312` in this instance) to handle that specific client connection.
    *   The child process inherits the client socket, drops unnecessary privileges where applicable, processes SMB requests, and updates shared memory/TDB files (`locking.tdb`, `smbstatus`).
    *   When the client terminates the SMB session or drops the TCP connection, the child process closes its resources and exits cleanly. The parent `smbd` daemon remains running continuously to accept new connections.

---

### Solution to Exercise 2

*   **Answer 2.1:**
    *   `%u`: Effective username of the current Samba session (after Samba user mapping).
    *   `%U`: Client-requested username (the raw username string supplied by the client during SMB Session Setup before mapping).
    *   `%m`: NetBIOS name of the client machine (derived from NBT or reverse DNS fallback).
    *   `%I`: IP address of the client machine (e.g., `192.168.1.50`).
    *   `%v`: Samba version currently running (e.g., `4.19.5-Ubuntu`).
*   **Answer 2.2:**
    *   Setting `server min protocol = SMB2_10` completely blocks connection attempts using **SMB1 / CIFS**. This mitigates critical vulnerability vectors such as remote code execution exploits targeting SMB1 parser flaws (e.g., MS17-010 / EternalBlue), NULL session coercion attacks, and protocol downgrade exploits.
    *   Setting `smb encrypt = required` forces AES-128-CCM / AES-128-GCM encryption on all SMB3 transport sessions. This prevents network eavesdropping, packet tampering, and Man-In-The-Middle (MITM) session hijacking on untrusted networks.

---

### Solution to Exercise 3

*   **Answer 3.1:**
    *   `tdbbackup` utilizes internal byte-range read locks on the TDB database header and record structures while traversing the file.
    *   If `cp` or `rsync` is executed while `smbd` is actively writing to a TDB file, a write operation mid-copy can produce a corrupted database backup containing partial hash chains or split records.
    *   `tdbbackup` guarantees transactional consistency for the destination copy even while `smbd` actively mutates the database.
*   **Answer 3.2:**
    *   `smbcontrol` communicates with running Samba daemons using Samba's internal **messaging sub-system** (`messages.tdb` or Unix domain sockets under `/var/lib/samba/cores/` / `/run/samba/`).
    *   It sends structured signal messages (e.g., `MSG_SMB_CONF_UPDATED`, `MSG_REQ_POOL_USAGE`) to specific process IDs (PIDs) or broadcasts them to all `smbd`/`nmbd` processes registered in the messaging TDB table.

</details>