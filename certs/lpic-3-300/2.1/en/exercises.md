# LPIC-3 Exam 300 (v3.0) — Topic 2.1: Samba and Active Directory Domains

**Exam Weight:** 20  
**Target Role:** Senior SRE / Principal Platform Architect  
**Official Reference:** [LPI LPIC-3 300 Detailed Objectives](https://www.lpi.org/our-certifications/lpic-3-300-overview/)  
**Samba Technical Documentation:** [Samba AD DC HowTo & Architecture](https://wiki.samba.org/index.php/Samba_AD_DC_HOWTO)

---

## Technical Architecture & Core Concepts Overview

Samba as an Active Directory Domain Controller (AD DC) integrates several distinct protocols and infrastructure daemons into a unified enterprise directory service:

```
+-----------------------------------------------------------------------------------+
|                                 Samba AD DC Process                               |
|                                                                                   |
|  +------------------+  +-------------------+  +--------------------------------+  |
|  |   Heimdal/MIT    |  | Embedded LDB/LDAP |  | Internal DNS Server            |  |
|  |   Kerberos KDC   |  | Directory Service |  | (or BIND9 DLZ Plugin)          |  |
|  |   (Port 88 TCP/UDP)| | (Port 389 / 636) |  | (Port 53 TCP/UDP)              |  |
|  +--------+---------+  +---------+---------+  +---------------+----------------+  |
|           |                      |                            |                   |
|  +--------+----------------------+----------------------------+----------------+  |
|  |                 Directory Replication Service (DRS / DCE-RPC)               |  |
|  |                 NETLOGON & SYSVOL SMB File Sharing (Port 445)               |  |
|  +-----------------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------------+
```

### Key Components & Architectural Trade-offs

1. **Daemon Architecture (`samba` vs `smbd`/`nmbd`/`winbindd`):**
   * When acting as an AD DC, Samba executes the single `samba` binary orchestrating the embedded KDC, LDAP server, DNS server, NBT server, and RPC endpoints.
   * Running legacy `smbd`, `nmbd`, or `winbindd` daemons separately on a Samba AD DC will cause port conflicts and service failures.

2. **Storage Engine (LDB vs OpenLDAP):**
   * Samba AD DC uses **LDB** (a lightweight TDB-backed LDAP-like database format) rather than standalone OpenLDAP.
   * LDB supports standard LDAP search filters, controls, and schema enforcement while maintaining fast local key-value access for domain operations.

3. **DNS Backends:**
   * **`SAMBA_INTERNAL`**: Embedded DNS server. Lightweight, requires zero external service configuration, perfectly suited for simple topologies. Trade-off: Lacks advanced BIND features such as split-horizon, DNSSEC inline signing, or custom zone views.
   * **`BIND9_DLZ`**: Dynamically Loaded Zones plugin (`dlz_bind9.so`). BIND9 loads zones directly from Samba's `sam.ldb` database via DCE/RPC. Best for enterprise deployments requiring advanced DNS routing and security compliance.

4. **Directory Replication Service (DRS):**
   * Uses Microsoft Directory Replication Service Remote Protocol (MS-DRSR) over DCE-RPC.
   * Operates via standard Active Directory replication metadata (USN counters, High-Water Marks, and Up-To-Dateness Vectors).

---

## Hands-On Lab Exercises

---

### Module 1: Greenfield Samba 4 Active Directory DC Provisioning

#### Objective
Provision a primary Samba 4 Active Directory Domain Controller (`dc1.corp.example.com`) using RFC 2307 schema extensions, configure system Kerberos, and validate internal LDAP, DNS, and KDC operations.

#### Step 1.1: Environment Preparation and Pre-Flight Checks
Clean up legacy configuration files and ensure hostname resolution matches the intended Realm.

```bash
# Set fully qualified domain name
hostnamectl set-hostname dc1.corp.example.com

# Verify /etc/hosts resolution
cat << 'EOF' > /etc/hosts
127.0.0.1   localhost
192.168.50.10 dc1.corp.example.com dc1
EOF

# Remove pre-existing Samba/Kerberos configurations
systemctl stop samba-ad-dc smbd nmbd winbind 2>/dev/null || true
rm -f /etc/samba/smb.conf /etc/krb5.conf
rm -rf /var/lib/samba/private/* /var/lib/samba/sysvol/*
```

#### Step 1.2: Execute Domain Provisioning
Run `samba-tool domain provision` in non-interactive mode.

```bash
samba-tool domain provision \
  --realm=CORP.EXAMPLE.COM \
  --domain=CORP \
  --server-role=dc \
  --dns-backend=SAMBA_INTERNAL \
  --adminpass="P@ssw0rd2026!" \
  --use-rfc2307
```

*Expected CLI Output Snippet:*
```text
Looking up IPv4 addresses
Looking up IPv6 addresses
Setting up share.ldb
Setting up secrets.ldb
Setting up the Registry
Setting up the SAM database
Setting up SamDB records
Setting up doming admin password
A-Cls and ACLs on SAM status...
Setting up self-join...
Setting up SAMDB security...
Setting up Netlogon and SYSVOL shares
Setting up WERR_OK
Provisioning complete!
A krb5.conf file appropriate for the Samba AD DC has been generated at /var/lib/samba/private/krb5.conf
```

#### Step 1.3: Configure System Kerberos and Services
Link the generated `krb5.conf` to system paths and start the `samba-ad-dc` service.

```bash
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
systemctl unmask samba-ad-dc
systemctl restart samba-ad-dc
systemctl enable samba-ad-dc
```

#### Step 1.4: Validate LDAP, Kerberos, and DNS Operations
Execute diagnostic queries against the new Domain Controller.

```bash
# 1. Test Kerberos authentication for Administrator
kinit administrator@CORP.EXAMPLE.COM
```
*Expected Output:*
```text
Password for administrator@CORP.EXAMPLE.COM: 
```

```bash
# 2. Inspect active Kerberos ticket-granting ticket (TGT)
klist
```
*Expected Output:*
```text
Ticket cache: FILE:/tmp/krb5cc_0
Default principal: administrator@CORP.EXAMPLE.COM

Valid starting       Expires              Service principal
08/06/26 12:50:01  08/06/26 22:50:01  krbtgt/CORP.EXAMPLE.COM@CORP.EXAMPLE.COM
	renew until 08/07/26 12:50:01
```

```bash
# 3. Test DNS SRV record resolution
host -t SRV _kerberos._tcp.corp.example.com localhost
host -t SRV _ldap._tcp.corp.example.com localhost
```
*Expected Output:*
```text
Using domain server:
Name: localhost
Address: 127.0.0.1#53

_kerberos._tcp.corp.example.com has SRV record 0 100 88 dc1.corp.example.com.
_ldap._tcp.corp.example.com has SRV record 0 100 389 dc1.corp.example.com.
```

---

#### Verification Questions — Module 1

1. **Question 1.1:** Why does provisioning an AD DC require `--use-rfc2307` if Linux/Unix clients will join the domain?
2. **Question 1.2:** What occurs if an administrator attempts to start standard `smbd` and `winbindd` systemd units concurrently with `samba-ad-dc`?

---

### Module 2: Multi-DC Architecture: DRS Replication & FSMO Role Management

#### Objective
Join a second node (`dc2.corp.example.com`) as an additional AD Domain Controller to achieve Directory Replication Service (DRS) redundancy, inspect replication topology, and safely transfer Flexible Single Master Operation (FSMO) roles.

```
                    +-----------------------+
                    |  FSMO Role Owner:     |
                    |  dc1.corp.example.com |
                    +-----------+-----------+
                                |
             MS-DRSR Replication| (DCE/RPC Port 135 / Dynamic)
                                v
                    +-----------------------+
                    |  Secondary DC:        |
                    |  dc2.corp.example.com |
                    +-----------------------+
```

#### Step 2.1: Join Secondary Server to Existing Domain
On `dc2.corp.example.com` (IP: `192.168.50.11`), set primary DNS to `192.168.50.10` (`dc1`) and execute the DC join.

```bash
# Configure DNS pointing to primary DC
echo "nameserver 192.168.50.10" > /etc/resolv.conf

# Execute Domain Controller Join
samba-tool domain join corp.example.com DC \
  -U"CORP\Administrator" \
  --password="P@ssw0rd2026!" \
  --dns-backend=SAMBA_INTERNAL
```

*Expected CLI Output Snippet:*
```text
Finding a writeable DC for domain 'corp.example.com'
Found DC dc1.corp.example.com
Password for [CORP\Administrator]:
Partition[CN=Configuration,DC=corp,DC=example,DC=com] objects[1624] linked_values[28]
Partition[CN=Schema,CN=Configuration,DC=corp,DC=example,DC=com] objects[15670] linked_values[0]
Partition[DC=corp,DC=example,DC=com] objects[742] linked_values[61]
Replicating critical objects from the distant server
Joined domain CORP (SID S-1-5-21-382910482-120493821-93810294) as a DC
```

```bash
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
systemctl start samba-ad-dc
```

#### Step 2.2: Verify DRS Inbound and Outbound Replication
Inspect replication topology status using `samba-tool drs`.

```bash
samba-tool drs showrepl
```

*Expected CLI Output Snippet:*
```text
Default-First-Site-Name\DC2
DSA Options: IS_GC
DSA object GUID: 3b1a789c-4f81-42ab-9d10-81726a510101
DSA invocationId: e801aa45-9112-4211-89ab-010192837411

==== INBOUND NEIGHBORS ====

DC=corp,DC=example,DC=com
	Default-First-Site-Name\DC1 via RPC
		DSA object GUID: 1a89c7d6-3b21-4d1a-8e19-901827465192
		Last attempt @ Thu Aug  6 12:55:10 2026 EDT was successful
		0 failures since last success.
		Naming Context USN: 39482 (High Water), 39482 (Up To Date)
```

#### Step 2.3: Query and Transfer FSMO Roles
Identify current FSMO role holders across the forest and transfer all 7 roles from `dc1` to `dc2`.

```bash
# Query initial FSMO role placement
samba-tool fsmo show
```

*Expected CLI Output:*
```text
SchemaMaster role owner: CN=NTDS Settings,CN=DC1,CN=Servers,CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=corp,DC=example,DC=com
InfrastructureMaster role owner: CN=NTDS Settings,CN=DC1,CN=Servers,CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=corp,DC=example,DC=com
RidMaster role owner: CN=NTDS Settings,CN=DC1,CN=Servers,CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=corp,DC=example,DC=com
PdcEmulation role owner: CN=NTDS Settings,CN=DC1,CN=Servers,CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=corp,DC=example,DC=com
NamingMaster role owner: CN=NTDS Settings,CN=DC1,CN=Servers,CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=corp,DC=example,DC=com
DomainDnsZonesMaster role owner: CN=NTDS Settings,CN=DC1,CN=Servers,CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=corp,DC=example,DC=com
ForestDnsZonesMaster role owner: CN=NTDS Settings,CN=DC1,CN=Servers,CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=corp,DC=example,DC=com
```

```bash
# Gracefully transfer all roles to dc2
samba-tool fsmo transfer --role=all -U"CORP\Administrator" --password="P@ssw0rd2026!"
```

*Expected Output Snippet:*
```text
FSMO transfer of 'rid' role successful
FSMO transfer of 'pdc' role successful
FSMO transfer of 'naming' role successful
FSMO transfer of 'infrastructure' role successful
FSMO transfer of 'schema' role successful
FSMO transfer of 'domaindns' role successful
FSMO transfer of 'forestdns' role successful
Transferred 7 roles successfully
```

---

#### Verification Questions — Module 2

1. **Question 2.1:** What is the technical difference between `samba-tool fsmo transfer` and `samba-tool fsmo seize`, and under what precise operational conditions must `seize` be used?
2. **Question 2.2:** Why are there 7 FSMO roles listed in Samba 4 AD DC instead of the 5 standard FSMO roles historically defined in traditional Active Directory documentation?

---

### Module 3: Enterprise DNS Integration: BIND9 DLZ & Secure Dynamic DNS Updates (GSS-TSIG)

#### Objective
Reconfigure Samba AD DC to use BIND9 with the Dynamically Loaded Zones (DLZ) driver (`dlz_bind9.so`) and configure secure Kerberos-authenticated Dynamic DNS updates (`gssapi_keytab`).

#### Step 3.1: Generate Named Configuration and Keytab
Adjust `/etc/samba/smb.conf` to reference the BIND9 DLZ backend, and verify keytab location.

```ini
# Append/verify in /etc/samba/smb.conf under [global]
[global]
    netbios name = DC1
    realm = CORP.EXAMPLE.COM
    workgroup = CORP
    server role = active directory domain controller
    dns forwarder = 1.1.1.1
    server services = -dns
```

#### Step 3.2: Configure BIND9 Named Manifest
Create a syntactically valid `/etc/bind/named.conf` integrating Samba's DLZ module.

```bind
// /etc/bind/named.conf

options {
    directory "/var/cache/bind";
    forwarders {
        1.1.1.1;
        8.8.8.8;
    };
    dnssec-validation auto;
    listen-on port 53 { any; };
    listen-on-v6 { any; };
    tkey-gssapi-keytab "/var/lib/samba/bind-dns/dns.keytab";
    minimal-responses yes;
};

// Load Samba DLZ plugin dynamically (Path varies by distribution architecture)
dlz "AD_DNS" {
    statement "http://www.samba.org/samba/docs/man/samba-tool.8.html";
    database "dlopen /usr/lib/x86_64-linux-gnu/samba/bind9/dlz_bind9_18.so -H /var/lib/samba/private/sam.ldb";
};
```

#### Step 3.3: Set Permissions and Restart Services
Ensure BIND9 has read access to the Samba DNS keytab and LDB database sockets.

```bash
# Grant bind user ownership to bind-dns path
chown -R root:bind /var/lib/samba/bind-dns
chmod 750 /var/lib/samba/bind-dns

# Stop samba-ad-dc, start bind9, then start samba-ad-dc
systemctl stop samba-ad-dc
systemctl restart bind9
systemctl start samba-ad-dc
```

#### Step 3.4: Test Secure Dynamic DNS Update via GSS-TSIG
Perform an authenticated DNS update using `nsupdate` and Kerberos credentials.

```bash
# Obtain ticket for administrator
kinit administrator@CORP.EXAMPLE.COM

# Submit GSS-TSIG authenticated DNS registration
nsupdate -g << 'EOF'
server 127.0.0.1
realm CORP.EXAMPLE.COM
zone corp.example.com
update add app-server-01.corp.example.com 3600 A 192.168.50.50
send
EOF

# Verify record in DNS
host app-server-01.corp.example.com 127.0.0.1
```

*Expected Output:*
```text
Using domain server:
Name: 127.0.0.1
Address: 127.0.0.1#53

app-server-01.corp.example.com has address 192.168.50.50
```

---

#### Verification Questions — Module 3

1. **Question 3.1:** What directive in `named.conf` allows BIND9 to perform Kerberos-authenticated GSS-TSIG updates without requiring pre-shared static TSIG keys?
2. **Question 3.2:** What operational issue occurs if `server services = -dns` is omitted from `smb.conf` when running BIND9 DLZ on the same host?

---

### Module 4: Low-Level AD Object Administration & Fine-Grained Password Policies

#### Objective
Manage Active Directory objects programmatically, inspect underlying LDB databases using `ldbsearch`/`ldbedit`, and enforce a Password Settings Object (PSO) for specific groups.

#### Step 4.1: Inspect Directory Schema via `ldbsearch`
Query Samba's `sam.ldb` directly bypassing the standard network LDAP stack.

```bash
ldbsearch -H /var/lib/samba/private/sam.ldb \
  -b "DC=corp,DC=example,DC=com" \
  "(sAMAccountName=administrator)" \
  pwdLastSet userAccountControl objectSid
```

*Expected Output Snippet:*
```ldif
dn: CN=Administrator,CN=Users,DC=corp,DC=example,DC=com
pwdLastSet: 133674829100000000
userAccountControl: 512
objectSid: S-1-5-21-382910482-120493821-93810294-500
```

#### Step 4.2: Create Organizational Unit, Users, and Security Groups
Use `samba-tool` to provision enterprise hierarchy.

```bash
# Create Organizational Unit
samba-tool ou create "OU=Engineers,DC=corp,DC=example,DC=com"

# Create Security Group
samba-tool group add "Sec-DevOps" --groupou="OU=Engineers"

# Provision User Account with explicit POSIX attributes
samba-tool user create dev-user01 "P@ssw0rd2026Sec!" \
  --userou="OU=Engineers" \
  --given-name="Dev" \
  --surname="User" \
  --mail-address="dev-user01@corp.example.com"

# Add User to Group
samba-tool group addmembers "Sec-DevOps" dev-user01
```

#### Step 4.3: Enforce Fine-Grained Password Policy (PSO)
Create a Password Settings Object (PSO) targeting high-privilege engineering groups.

```bash
samba-tool domain passwordsettings pso add "DevOps-PSO" 10 \
  --complexity=on \
  --history-length=24 \
  --min-pwd-age=1 \
  --max-pwd-age=60 \
  --min-pwd-length=16 \
  --account-lockout-threshold=5 \
  --account-lockout-duration=30 \
  --reset-account-lockout-after=30

# Apply PSO to Sec-DevOps group
samba-tool domain passwordsettings pso apply "DevOps-PSO" "Sec-DevOps"
```

#### Step 4.4: Validate PSO Enforcement
Verify effective policy application on `dev-user01`.

```bash
samba-tool domain passwordsettings pso show-user dev-user01
```

*Expected Output Snippet:*
```text
Password PSO info for user dev-user01:
  Applied PSO: DevOps-PSO
  Minimum password length: 16
  Password complexity: on
  Password history length: 24
  Minimum password age (days): 1
  Maximum password age (days): 60
  Account lockout threshold: 5
  Account lockout duration (mins): 30
  Reset account lockout counter after (mins): 30
```

---

#### Verification Questions — Module 4

1. **Question 4.1:** Why is direct manual manipulation of `/var/lib/samba/private/sam.ldb` using `ldbedit` discouraged in production unless performing emergency recovery?
2. **Question 4.2:** What is the structural difference in Active Directory between the global domain password policy (`samba-tool domain passwordsettings set`) and a Password Settings Object (PSO)?

---

### Module 5: Production SRE Diagnostics & Troubleshooting Playbook

#### Objective
Diagnose and resolve common production failures: missing Kerberos Service Principal Names (SPNs), SYSVOL Access Control List (ACL) drift, and database corruption.

#### Step 5.1: Troubleshoot Service Principal Name (SPN) Authentication Failures
Simulate a missing SPN error when a Web server attempts Kerberos HTTP authentication (`HTTP/web.corp.example.com`).

```bash
# 1. Query existing SPNs for an application service account
samba-tool spn list svc_web

# 2. Add required SPN mapping to service account
samba-tool spn add HTTP/web.corp.example.com svc_web

# 3. Verify SPN resolution in directory
ldbsearch -H /var/lib/samba/private/sam.ldb "(servicePrincipalName=HTTP/web.corp.example.com)" dn
```

*Expected Output:*
```ldif
dn: CN=svc_web,CN=Users,DC=corp,DC=example,DC=com
```

#### Step 5.2: Audit and Repair SYSVOL ACL Integrity
SYSVOL directory permissions frequently drift when backup utilities or RSAT tools apply non-POSIX compliant permissions.

```bash
# Check SYSVOL ACL integrity
samba-tool ntacl sysvolcheck
```

*Expected Output when Corrupted:*
```text
ERROR(<class 'samba.provision.ProvisioningError'>): ProvisioningError: VFS Security Information mismatch on /var/lib/samba/sysvol/corp.example.com/Policies: action=0x00040000, expected=0x000e0000
```

```bash
# Repair SYSVOL ACLs to original factory specification
samba-tool ntacl sysvolreset

# Re-verify status
samba-tool ntacl sysvolcheck
```

*Expected Output after Repair:*
```text
(No error output returned; exit code 0)
```

#### Step 5.3: Run Database Consistency and Cross-NC Integrity Check
Scan the internal LDB partitions for dangling references, broken linked attributes, or Schema mismatches.

```bash
samba-tool dbcheck --cross-ncs
```

*Expected Output snippet:*
```text
Checking 18392 objects
Checked 18392 objects (0 errors)
```

---

#### Verification Questions — Module 5

1. **Question 5.1:** What operational issue occurs if `samba-tool ntacl sysvolreset` is executed while standard `rsync` (without `--xattrs`) is used for SYSVOL replication between multiple DCs?
2. **Question 5.2:** What tool and argument should an SRE use to inspect active DCE-RPC endpoints bound on a Samba Domain Controller?

---

<details>
<summary><strong>Exercise Solutions & Architectural Justifications</strong></summary>

### Module 1 Solutions

* **Answer 1.1:** The `--use-rfc2307` flag populates the Active Directory schema with POSIX attributes (`uidNumber`, `gidNumber`, `unixHomeDirectory`, `loginShell`, `gecos`). Without this schema extension, Linux member servers using Winbind, SSD, or nslcd cannot map Active Directory security principals directly to native Linux UIDs/GIDs unless arbitrary dynamic mapping ranges (such as `idmap_autorid` or `idmap_rid`) are configured on every single client.
* **Answer 1.2:** A port collision occurs immediately. The `samba-ad-dc` process spawns embedded threads listening on TCP/UDP 389 (LDAP), 636 (LDAPS), 88 (Kerberos), 445 (SMB), 135 (RPC), and 53 (DNS). If legacy `smbd`, `nmbd`, or `winbindd` daemons run simultaneously, they attempt to bind to the exact same sockets (e.g., `smbd` on 445/139, `winbindd` on `/var/lib/samba/winbindd_privileged/pipe`), causing service initialization crashes and directory split-brain.

---

### Module 2 Solutions

* **Answer 2.1:**
  * **`transfer`**: Performed gracefully when the current FSMO role owner is online and accessible. The source DC synchronizes any pending changes, releases ownership, and updates the target DC via RPC.
  * **`seize`**: Performed forcefully when the current role owner has suffered a permanent catastrophic failure and cannot be recovered online. **CAUTION:** Once a role (especially Schema Master or RID Master) is seized, the original DC must **NEVER** be brought back online into the domain without a total re-provision; doing so causes irreversible GUID/RID duplication and Active Directory corruption.
* **Answer 2.2:** Standard Active Directory defines 5 FSMO roles:
  1. Schema Master (Forest-wide)
  2. Domain Naming Master (Forest-wide)
  3. RID Master (Domain-wide)
  4. PDC Emulator (Domain-wide)
  5. Infrastructure Master (Domain-wide)
  
  Samba 4 includes 2 additional DNS-specific FSMO master roles introduced in Windows Server 2003 for Application Directory Partitions:
  6. **DomainDnsZones Master** (Controls naming/updates for `DC=DomainDnsZones,DC=domain,DC=com`)
  7. **ForestDnsZones Master** (Controls naming/updates for `DC=ForestDnsZones,DC=domain,DC=com`)

---

### Module 3 Solutions

* **Answer 3.1:** The directive `tkey-gssapi-keytab "/var/lib/samba/bind-dns/dns.keytab";` in `named.conf`. This enables BIND9 to utilize the SPN `DNS/dc1.corp.example.com` stored in the keytab to validate Kerberos tickets presented by Windows/Linux clients during `nsupdate -g` operations, dynamically updating the LDB backend without static shared secrets.
* **Answer 3.2:** If `server services = -dns` (or removing `dns` from `server services`) is omitted in `smb.conf`, Samba's internal DNS process will start up during `samba-ad-dc` initialization and attempt to bind to port 53 TCP/UDP. This causes BIND9 (or Samba's internal DNS) to fail to start due to `EADDRINUSE` (Address already in use).

---

### Module 4 Solutions

* **Answer 4.1:** Editing `/var/lib/samba/private/sam.ldb` directly via `ldbedit` bypasses Samba's active LDAP sanity checks, referential integrity triggers, password complexity evaluations, and schema enforcement modules. Incorrect manual edits can corrupt USN counters, break GUID link attributes, or cause fatal deserialization failures during DRS replication.
* **Answer 4.2:** The global domain password policy (`samba-tool domain passwordsettings set`) applies to all accounts by default but can only enforce **one** single rule set across the entire domain. A Password Settings Object (PSO), introduced in AD DS (RFC 2307 / Windows 2008 functional level), allows SREs to apply Fine-Grained Password Policies (FGPP) with stricter constraints (e.g., 16-character minimum length and 5-try lockout) to specific users or Global Security Groups without affecting standard domain accounts.

---

### Module 5 Solutions

* **Answer 5.1:** Standard `rsync` without extended attributes (`--xattrs`) and POSIX ACL preservation (`--acls`) strips off Samba's extended NTFS attributes (`security.NTACL`) stored in `user.NTACL` filesystem attributes on `/var/lib/samba/sysvol`. When `samba-tool ntacl sysvolreset` is run or when Group Policy is checked by clients, Group Policy Objects (GPOs) become unreadable by domain machines due to missing Windows NT ACL representations on the POSIX directory.
* **Answer 5.2:** SREs use `rpcclient` or `samba-tool` diagnostics alongside `netstat` / `ss` / `lsof`. Specifically, `rpcclient -U "user" dc1 -c "netshareenumall"` or `epdump` utilities (such as `rpctorture` or `msrpc` scanners) can inspect endpoints bound to Samba's DCE-RPC endpoint mapper on TCP port 135.

</details>