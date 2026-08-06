# LPIC-3 Exam 300-300 (v3.0): Topic 2.1 – Samba and Active Directory Domains

---

## 1. Architectural Motivation & Production Problem Statement

### 1.1 The Enterprise Identity & Control Plane Challenge
Modern hybrid enterprise infrastructures demand a unified authentication, authorization, and directory control plane across heterogeneous operating systems (Linux/POSIX and Microsoft Windows). Organizations operating multi-cloud or on-premises footprints face severe security and operational friction when identity is fragmented into isolated silos (e.g., local `/etc/passwd`, standalone OpenLDAP, or cloud IAM providers without Kerberos federation). 

Active Directory Domain Services (AD DS) serves as the de facto multi-master directory architecture, utilizing standard network protocols:
- **Kerberos v5 (RFC 4120 / RFC 4556):** Provides mutual authentication, ticket-granting service (TGS), and single sign-on (SSO) without transmitting raw passwords over the network.
- **LDAPv3 (RFC 4511) & Simple Auth and Security Layer (SASL / RFC 4422):** Provides structured directory queries, access control lists (ACLs), and object hierarchies.
- **Domain Name System (DNS - RFC 1035 / RFC 2782):** Serves as the dynamic location service through canonical `SRV` and `TXT` records enabling Kerberos Key Distribution Center (KDC) and LDAP server discovery.
- **DCE/RPC & MS-RPC (Microsoft Remote Procedure Call):** Provides administrative interface calls for domain management, user replication, security policy application, and SID (Security Identifier) translation.

Samba in Active Directory Domain Controller (Samba AD DC) mode implements an open-source, fully compliant MS-ADTS (Active Directory Technical Specification) and MS-DRSR (Directory Replication Service Remote Protocol) engine. It eliminates the need for proprietary domain controllers while maintaining seamless protocol parity for Windows clients, Linux domain members, and cloud identity bridge tools.

```
                         +-------------------------------------------------+
                         |          Samba Active Directory DC              |
                         |                                                 |
  +------------------+   | +------------------+   +----------------------+ |
  | Client Request   |---| | Kerberos v5 KDC  |   | Heimdal / Built-in   | |
  | (Win/Linux/Mac)  |   | | (Port 88 TCP/UDP)|   | KDC Engine           | |
  +------------------+   | +------------------+   +----------------------+ |
           |             |          |                         |            |
           | DNS SRV     | +------------------+   +----------------------+ |
           v             | | Embedded LDAP/S  |   | LDB Database Core    | |
  +------------------+   | | (Port 389/636)   |---| (sam.ldb, idmap.ldb, | |
  | DNS Server       |---| +------------------+   | secrets.ldb)         | |
  | Internal/BIND9   |   |          |             +----------------------+ |
  +------------------+   | +------------------+               |            |
                         | | DCE/RPC Services |               | DRSUAPI    |
                         | | (samr, lsarpc)   |               v            |
                         | +------------------+   +----------------------+ |
                         |                        | Replication Engine   | |
                         +------------------------| (DRSUAPI / RPC)      | |
                                                  +----------------------+ |
                                                              |            |
                                                              v            |
                                                   +---------------------+ |
                                                   | Peer Domain         | |
                                                   | Controllers (AD DC) | |
                                                   +---------------------+ |
```

### 1.2 Core Architectural Components of Samba AD DC

1. **LDB (LDAP-like Database System):**
   - Samba replaces standard SQL or Berkeley Database engines with **LDB**, an embedded key-value store optimized for LDAP attributes and TDB (Trivial Database) backend files.
   - Databases reside in `/var/lib/samba/private/`:
     - `sam.ldb`: Contains the Active Directory domain partitions (Domain NC, Configuration NC, Schema NC).
     - `sam.ldb.d/`: Partition-specific sub-databases (`DC=DOM,DC=COM.ldb`, `CN=CONFIGURATION...ldb`, `CN=SCHEMA...ldb`).
     - `idmap.ldb`: Maps Active Directory SIDs (`S-1-5-21-...`) to local POSIX UIDs and GIDs.
     - `secrets.ldb`: Stores local service principal machine account passwords and Kerberos keys.

2. **Flexible Single Master Operation (FSMO) Roles:**
   Active Directory operates primarily as a multi-master system, but five specific operations require strict single-master authority to prevent split-brain conditions:
   - **Forest-wide Roles:**
     1. *Schema Master:* Controls modifications to the LDAP schema (`CN=Schema,CN=Configuration...`).
     2. *Domain Naming Master:* Controls addition or removal of domains within the forest.
   - **Domain-wide Roles:**
     3. *PDC Emulator:* Handles password updates, time synchronization (NTP), legacy NTLM authentication fallback, and GPO edits.
     4. *RID Master:* Allocates pools of Relative Identifiers (RIDs) to Domain Controllers for SID construction (`SID = Domain SID + RID`).
     5. *Infrastructure Master:* Translates cross-domain object references (SIDs to DNs).

3. **Directory Replication Service Protocol (DRSUAPI):**
   Samba AD DC utilizes the native Microsoft DRSUAPI over DCE/RPC to perform peer-to-peer directory replication with Windows Server DCs or secondary Samba DCs. Replication is divided across standard Naming Contexts (NCs):
   - **Domain NC:** Contains users, groups, computers, and organizational units (OUs).
   - **Configuration NC:** Contains enterprise topology, site boundaries, and RPC services.
   - **Schema NC:** Contains class and attribute definitions for every object in the forest.
   - **DomainDnsZones / ForestDnsZones NCs:** Contains integrated DNS zone data and dynamic updates.

---

## 2. Technical Comparison & Trade-off Tables

### 2.1 Identity & Integration Architecture Comparison

| Architecture Metric | Samba 4 AD DC | Samba Domain Member (Winbind) | SSSD Domain Member | FreeIPA / Red Hat IdM |
| :--- | :--- | :--- | :--- | :--- |
| **Primary Role** | Identity Provider / KDC / Domain Controller | File/Print Server attached to AD | Client Auth / POSIX Enforcer | Linux-Native Identity Provider |
| **AD Forest Trust Capability** | Supported (Forest & Domain trusts via `samba-tool`) | N/A (Joins existing AD) | N/A (Joins existing AD) | Cross-Forest Trust with AD |
| **Kerberos KDC Engine** | Built-in (Heimdal / MIT integrated) | Uses External KDC (AD) | Uses External KDC (AD) | Native MIT Kerberos KDC |
| **Directory Storage** | Embedded LDB (TDB-backed) | Local cache (`winbindd_cache.tdb`) | SSSD Local Cache (LDB) | 389 Directory Server (OpenLDAP based) |
| **File Sharing (SMB3/CIFS)** | Supported (with limitations on VFS modules) | Full Enterprise Support (NTFS ACLs, VFS, Ceph/Gluster) | SMB Access handled via Samba, Auth via SSSD | Requires Samba Integration |
| **POSIX UID/GID Generation** | Built-in ID Mapping (`idmap.ldb` or RFC 2307) | Configurable (`idmap_rid`, `idmap_ad`, `idmap_autorid`) | Built-in Algorithmic or explicit AD attributes | Native POSIX Schema (`uidNumber`, `gidNumber`) |
| **Group Policy (GPO) Processing** | Host & Replicate GPOs (`SYSVOL`) | Apply Client Policies (`samba-gpupdate`) | Limited GPO access control enforcement | Native IPA Policies (HBAC, Sudo) |

### 2.2 DNS Integration Backends for Samba AD DC

| Feature / Trade-Off | `SAMBA_INTERNAL` DNS | `BIND9_DLZ` (Dynamic Link Zone) |
| :--- | :--- | :--- |
| **Implementation Complexity** | Zero configuration; built directly into `samba` binary. | Requires BIND 9 installation, `named.conf` inclusion, and DLZ module loading. |
| **DNSSEC Support** | Basic / Limited. | Full production-grade DNSSEC signing, validation, and key management. |
| **Performance & Scale** | Suitable for small to mid-sized environments (< 5,000 objects). | High-throughput enterprise scale (> 50,000 queries/sec), advanced view routing. |
| **Dynamic Updates (TSIG/GSS-TSIG)** | Fully supported natively via Kerberos (`gss-tsig`). | Fully supported via Samba DLZ plugin driver (`dlz_bind9.so`). |
| **External Zone Forwarding** | Configurable via `dns forwarder` parameter in `smb.conf`. | Standard BIND 9 `forwarders {}` block with ACLs, zone transfers, and split-horizon. |
| **Process Isolation** | Runs inside the main Samba process loop. | Separate process space (`named`); crash of DNS daemon does not impact KDC/LDAP. |

### 2.3 POSIX Identity Mapping (idmap) Backends for Domain Members

| Backend Module | Mapping Mechanism | Deterministic across Hosts? | AD Schema Modification Required? | Best Production Use Case |
| :--- | :--- | :--- | :--- | :--- |
| **`idmap_rid`** | $\text{UID} = \text{RID} - \text{Low Range} + \text{Base UID}$ | Yes (Algorithmically derived from domain SID RID) | No | Pure Active Directory environments with no legacy UNIX schemas. |
| **`idmap_ad`** | Reads explicit `uidNumber` and `gidNumber` from AD objects. | Yes (Stored centrally in AD) | Yes (Requires RFC 2307 / NIS extensions populated) | Environments migrating from legacy LDAP/UNIX setups with predefined UIDs. |
| **`idmap_autorid`** | Allocates ID ranges dynamically per discovered domain. | Yes (Stored in local database, replicated across instances) | No | Multi-domain forests without central RFC 2307 administration. |
| **`idmap_hash`** | Cryptographic hash of SID to 32-bit integer. | Yes | No | Legacy system compatibility (deprecated in modern Samba builds). |

---

## 3. Production Configurations & Infrastructure Manifests

### 3.1 Complete Samba AD DC Configuration (`/etc/samba/smb.conf`)

The following manifest represents a fully valid, untruncated configuration for a Samba Active Directory Domain Controller utilizing BIND9 DLZ, dynamic RPC ports, RFC 2307 POSIX attributes, and secure SMB signing.

```ini
# /etc/samba/smb.conf
# Production Samba 4 Active Directory Domain Controller Configuration
# Generated for Domain: AD.ENTERPRISE.INTERNAL

[global]
	# Basic Domain Identity
	netbios name = DC01
	realm = AD.ENTERPRISE.INTERNAL
	workgroup = ENTERPRISE
	server role = active directory domain controller

	# DNS Service Backend (Using BIND9_DLZ for production scalability)
	server services = -dns, s3fs, rpc, nbt, wzsrv, kdc, drepl, echo, dsdb, kcc, smb, heimdal
	idmap_ldb:use rfc2307 = yes

	# Network & Binding Settings
	interfaces = lo eth0
	bind interfaces only = yes

	# Cryptography & SMB Protocol Hardening
	server max protocol = SMB3_11
	server min protocol = SMB2_10
	client max protocol = SMB3_11
	client min protocol = SMB2_10

	# Require Signing across all RPC and SMB Channels
	server smb encrypt = required
	client smb encrypt = required
	server signing = required
	client signing = required
	ntlm auth = disabled

	# Kerberos & KDC Integration
	krb5 kdc windc type = heimdal
	time server = yes

	# Directory Path Declarations
	tls enabled = yes
	tls keyfile = /var/lib/samba/private/tls/key.pem
	tls certfile = /var/lib/samba/private/tls/cert.pem
	tls cafile = /var/lib/samba/private/tls/ca.pem

	# Logging Configuration
	log level = 2 default:2 auth_json_audit:3 dsdb_json_audit:3
	log file = /var/log/samba/samba.log
	max log size = 100000

[sysvol]
	path = /var/lib/samba/sysvol
	read only = no

[netlogon]
	path = /var/lib/samba/sysvol/ad.enterprise.internal/scripts
	read only = no
```

### 3.2 System Kerberos v5 Client Configuration (`/etc/krb5.conf`)

```ini
# /etc/krb5.conf
# Enterprise Production Kerberos Configuration

[libdefaults]
	default_realm = AD.ENTERPRISE.INTERNAL
	dns_lookup_realm = true
	dns_lookup_kdc = true
	rdns = false
	ticket_lifetime = 24h
	renew_lifetime = 7d
	forwardable = true
	udp_preference_limit = 1
	default_tkt_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
	default_tgs_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
	permitted_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96

[realms]
	AD.ENTERPRISE.INTERNAL = {
		kdc = dc01.ad.enterprise.internal:88
		admin_server = dc01.ad.enterprise.internal:749
		default_domain = ad.enterprise.internal
	}

[domain_realm]
	.ad.enterprise.internal = AD.ENTERPRISE.INTERNAL
	ad.enterprise.internal = AD.ENTERPRISE.INTERNAL
```

### 3.3 BIND 9 Enterprise Configuration for Samba DLZ (`/etc/bind/named.conf.local`)

```bind
// /etc/bind/named.conf.local
// Production BIND9 Integration with Samba 4 AD DC via DLZ

dlz "AD_DC" {
    # Dynamically load the DLZ module built against the specific BIND version
    # Architecture path for x86_64 Debian/RHEL systems
    database "dlopen /usr/lib/x86_64-linux-gnu/samba/bind9/dlz_bind9_18.so -H ldap://var/lib/samba/private/dns/sam.ldb";
};

// Global Options configuration enforcing Kerberos Dynamic Updates (GSS-TSIG)
options {
    directory "/var/cache/bind";

    forwarders {
        1.1.1.1;
        8.8.8.8;
    };

    dnssec-validation auto;

    listen-on-v6 { any; };
    listen-on port 53 { any; };

    # Allow dynamic updates signed by Kerberos credentials from Domain Controllers / Clients
    tkey-gssapi-keytab "/var/lib/samba/private/dns.keytab";

    auth-nxdomain no;    # conform to RFC1035
    minimal-responses yes;
};
```

### 3.4 Samba Domain Member Configuration (`/etc/samba/smb.conf`)

This configuration demonstrates a hardened file server configured as a Domain Member utilizing `idmap_rid`.

```ini
# /etc/samba/smb.conf
# Production Domain Member File Server Configuration

[global]
	netbios name = FILESRV01
	workgroup = ENTERPRISE
	realm = AD.ENTERPRISE.INTERNAL
	server role = member server

	# Security & Authentication Settings
	security = ADS
	encrypt passwords = yes
	client signing = mandatory
	server signing = mandatory
	client schannel require seal = yes

	# Winbind Daemon Identity Mapping Engine (idmap_rid)
	winbind enum users = no
	winbind enum groups = no
	winbind use default domain = yes
	winbind refresh tickets = yes
	winbind offline login = yes

	# ID Mapping Ranges
	# Local system accounts fallback range
	idmap config * : backend = tdb
	idmap config * : range = 30000-39999

	# Active Directory Domain ID Mapping Range
	idmap config ENTERPRISE : backend = rid
	idmap config ENTERPRISE : range = 100000-999999

	# VFS ACL Integration for POSIX/Windows ACL Mapping
	vfs objects = acl_xattr
	map acl inherit = yes
	store dos attributes = yes

	# Logging
	log file = /var/log/samba/log.%m
	max log size = 50000
	log level = 1 winbind:3

[engineering]
	comment = Production Engineering Data
	path = /data/shares/engineering
	read only = no
	browseable = yes
	guest ok = no
	valid users = @"ENTERPRISE\Engineering_Group"
	create mask = 0670
	directory mask = 0770
```

---

## 4. Real CLI Execution Streams & Realistic Outputs ($)

### 4.1 Provisioning a New Samba Active Directory Domain Controller

The `samba-tool domain provision` command initializes the LDB databases, generates the Kerberos keytab, configures SYSVOL, and sets up initial DNS zones.

```bash
$ sudo samba-tool domain provision \
    --realm=AD.ENTERPRISE.INTERNAL \
    --domain=ENTERPRISE \
    --server-role=dc \
    --dns-backend=BIND9_DLZ \
    --adminpass='Str0ngP@ssw0rd!2026' \
    --use-rfc2307 \
    --option="interfaces=lo eth0" \
    --option="bind interfaces only=yes"
```

```text
Looking up IPv4 addresses
Looking up IPv6 addresses
Setting up secrets.ldb
Setting up configure.ldb
Setting up sam.ldb partitions
Setting up sam.ldb rootDSE
Pre-loading the Schema DB
Info: Dynamic Re-index of SamDB required.
Disabling strict LDB header checks
Provisioning special objects ...
Setting up SAM DB users and groups
Extracting default SAMDB schema
Adding PrefixMap
Converting Schema to LDB format
Adding Schema info
Building sam.ldb schema
Setting up sam.ldb configuration data
Setting up sam.ldb domain data
Initialising sam.ldb domain data
Setting up sam.ldb rootDSE partition
Setting up sam.ldb data partitions
Setting up sam.ldb sam.ldb rootDSE group members
Setting up sam.ldb rootDSE partitions
A Kerberos configuration template suitable for Samba AD DC has been generated at /var/lib/samba/private/krb5.conf
Setting up secrets database
Setting up KDC certificate signing keys
Adding DNS accounts and groups
Creating DNS partitions
Setting up Domain Security Policies
Setting up sysvol directory
Setting up netlogon share
Setting up sysvol share
Kerberos engine Heimdal version 7.8.0 initialized.
Once lorded with BIND9_DLZ, include /var/lib/samba/private/named.conf in named.conf
SAMBA AD DC Provisioning Completed Successfully!
```

---

### 4.2 Joining a Secondary Samba Domain Controller to an Existing Forest

```bash
$ sudo samba-tool domain join ad.enterprise.internal DC \
    -U"ENTERPRISE\Administrator" \
    --password='Str0ngP@ssw0rd!2026' \
    --dns-backend=BIND9_DLZ
```

```text
Finding a domain controller for domain 'ad.enterprise.internal'
Found domain controller dc01.ad.enterprise.internal at 10.0.10.5
Retrieving NTDSA objectGUID for domain controller dc01.ad.enterprise.internal
Searching for hidden domain controller parameters
Password for [ENTERPRISE\Administrator]:
Domain storage path: /var/lib/samba
Adding 1 remote DC record(s) to DC=ad,DC=enterprise,DC=internal
Replicating directory partition: CN=Schema,CN=Configuration,DC=ad,DC=enterprise,DC=internal
Committing SAM partitions
Replicating directory partition: CN=Configuration,DC=ad,DC=enterprise,DC=internal
Committing SAM partitions
Replicating directory partition: DC=ad,DC=enterprise,DC=internal
Committing SAM partitions
Replicating directory partition: DC=DomainDnsZones,DC=ad,DC=enterprise,DC=internal
Committing SAM partitions
Replicating directory partition: DC=ForestDnsZones,DC=ad,DC=enterprise,DC=internal
Committing SAM partitions
Joined domain AD (SID S-1-5-21-3849204918-1294810293-984029481) as a DC
```

---

### 4.3 FSMO Role Inspection & Transfer

```bash
$ sudo samba-tool fsmo show
```

```text
SchemaMasterRole owner: CN=NTDS Settings,CN=DC01,CN=Servers,CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=ad,DC=enterprise,DC=internal
InfrastructureMasterRole owner: CN=NTDS Settings,CN=DC01,CN=Servers,CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=ad,DC=enterprise,DC=internal
RidMasterRole owner: CN=NTDS Settings,CN=DC01,CN=Servers,CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=ad,DC=enterprise,DC=internal
PdcEmulationMasterRole owner: CN=NTDS Settings,CN=DC01,CN=Servers,CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=ad,DC=enterprise,DC=internal
DomainNamingMasterRole owner: CN=NTDS Settings,CN=DC01,CN=Servers,CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=ad,DC=enterprise,DC=internal
DomainDnsZonesMasterRole owner: CN=NTDS Settings,CN=DC01,CN=Servers,CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=ad,DC=enterprise,DC=internal
ForestDnsZonesMasterRole owner: CN=NTDS Settings,CN=DC01,CN=Servers,CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=ad,DC=enterprise,DC=internal
```

Transferring the PDC Emulator role to secondary controller `DC02`:

```bash
$ sudo samba-tool fsmo transfer --role=pdc -U"ENTERPRISE\Administrator" --password='Str0ngP@ssw0rd!2026'
```

```text
FSMO transfer of 'pdc' role requested
FSMO transfer of 'pdc' role successful.
PdcEmulationMasterRole owner changed to CN=NTDS Settings,CN=DC02,CN=Servers,CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=ad,DC=enterprise,DC=internal
```

---

### 4.4 Directory Replication Status Inspection (DRSUAPI)

```bash
$ sudo samba-tool drs showrepl
```

```text
Default-First-Site-Name\DC01
DSA Options: IS_GC 
DSA object GUID: 4a9f8b1c-8c11-4e78-a402-8f921a48c901
DSA invocationID: e89a4410-d022-49bb-b12a-39d918c5e012

==== INBOUND NEIGHBORS ====

DC=ad,DC=enterprise,DC=internal
	Default-First-Site-Name\DC02 via RPC
		DSA objectGUID: c58921b3-7182-421f-9988-1249b6e80129
		Last attempt @ Thu Aug  6 12:00:15 2026 EDT was successful
		0 consecutive failure(s).
		Last status: NT_STATUS_OK

CN=Configuration,DC=ad,DC=enterprise,DC=internal
	Default-First-Site-Name\DC02 via RPC
		DSA objectGUID: c58921b3-7182-421f-9988-1249b6e80129
		Last attempt @ Thu Aug  6 12:00:16 2026 EDT was successful
		0 consecutive failure(s).
		Last status: NT_STATUS_OK

==== OUTBOUND NEIGHBORS ====

DC=ad,DC=enterprise,DC=internal
	Default-First-Site-Name\DC02 via RPC
		DSA objectGUID: c58921b3-7182-421f-9988-1249b6e80129
		Last attempt @ Thu Aug  6 12:00:15 2026 EDT was successful
		0 consecutive failure(s).
		Last status: NT_STATUS_OK

==== KCC CONNECTION OBJECTS ====

Connection --
	Connection name: 11f8b4a2-45bb-41a2-998c-02910481bc9e
	Enabled: TRUE
	Server DS location: CN=NTDS Settings,CN=DC02,CN=Servers,CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=ad,DC=enterprise,DC=internal
```

---

### 4.5 Active Directory User & Group Administration

Creating a user with RFC 2307 POSIX attributes:

```bash
$ sudo samba-tool user create sre_admin 'SecurePass#2026' \
    --given-name="SRE" \
    --surname="Lead" \
    --mail-address="sre_admin@enterprise.internal" \
    --uid-number=10050 \
    --gid-number=10000 \
    --login-shell="/bin/bash" \
    --unix-home="/home/sre_admin"
```

```text
User 'sre_admin' created successfully
```

Creating a Security Group and Adding the User:

```bash
$ sudo samba-tool group add "Engineering_Group" --gid-number=10000
```

```text
Added group Engineering_Group
```

```bash
$ sudo samba-tool group addmembers "Engineering_Group" sre_admin
```

```text
Added 'sre_admin' to group 'Engineering_Group'
```

---

### 4.6 Querying the Directory via Low-Level LDB Tools (`ldbsearch`)

`ldbsearch` allows direct querying of the underlying `sam.ldb` database without going through the standard network LDAP stack.

```bash
$ sudo ldbsearch -H /var/lib/samba/private/sam.ldb \
    "(sAMAccountName=sre_admin)" \
    cn sAMAccountName objectSid uidNumber gidNumber msDS-SupportedEncryptionTypes
```

```text
# record 1
dn: CN=SRE Lead,CN=Users,DC=ad,DC=enterprise,DC=internal
cn: SRE Lead
sAMAccountName: sre_admin
objectSid: S-1-5-21-3849204918-1294810293-984029481-1105
uidNumber: 10050
gidNumber: 10000
msDS-SupportedEncryptionTypes: 24

# returned 1 records
# 1 entries
# 0 referrals
```

---

### 4.7 Domain Member Join (`net ads join`) & Winbind Verification

Joining a Linux file server to the domain:

```bash
$ sudo kinit Administrator@AD.ENTERPRISE.INTERNAL
```

```text
Password for Administrator@AD.ENTERPRISE.INTERNAL:
```

```bash
$ sudo net ads join -U Administrator
```

```text
Using short domain name -- ENTERPRISE
Joined 'FILESRV01' to realm 'AD.ENTERPRISE.INTERNAL'
```

Verifying Identity Resolution via Winbind:

```bash
$ wbinfo -u
```

```text
ENTERPRISE\administrator
ENTERPRISE\krbtgt
ENTERPRISE\guest
ENTERPRISE\sre_admin
```

```bash
$ id ENTERPRISE\\sre_admin
```

```text
uid=10050(sre_admin) gid=10000(Engineering_Group) groups=10000(Engineering_Group),30001(BUILTIN\users)
```

---

## 5. Production Verification & Failure Diagnostics Matrix

```
                      +-----------------------------------------+
                      | SRE Diagnostic Flowchart: Samba AD DC  |
                      +-----------------------------------------+
                                           |
                                           v
                             [ Check Service Health ]
                             $ systemctl status samba
                                           |
                   +-----------------------+-----------------------+
                   | (Services OK)                                 | (Service Failure)
                   v                                               v
        [ DNS Resolution Test ]                         [ Inspect Journal Logs ]
        $ host -t SRV _ldap._tcp...                     $ journalctl -u samba -e
                   |                                               |
         +---------+---------+                            +--------+--------+
         | (Pass)            | (Fail)                     |                 |
         v                   v                            v                 v
   [ Kerberos Auth ]   [ Verify BIND /           [ DB Integrity ]   [ SYSVOL Sync ]
   $ kinit Admin       Samba Internal DNS ]      $ samba-tool dbcheck  $ rsync / GPO
         |                   |                            |                 |
         +---------+---------+                            +--------+--------+
                   |                                               |
                   v                                               v
         [ DRS Replication ]                             [ Execute DB Repair ]
         $ samba-tool drs showrepl                       $ samba-tool dbcheck --fix
```

### 5.1 Deep Diagnostics & Incident Response Procedures

#### Scenario 1: Directory Replication Failure (`DRSUAPI` Error / RPC Unavailable)
- **Symptom:** `samba-tool drs showrepl` indicates `WERR_BUSY` or `NT_STATUS_UNSUCCESSFUL` between Domain Controllers.
- **Root Cause Analysis:**
  1. Time drift / clock skew exceeding 300 seconds breaking Kerberos ticket validity between DCs.
  2. Firewall blocking DCE/RPC dynamic port ranges (Port 135 + Ephemeral Ports 1024-65535 or statically configured `rpc server port`).
  3. LDB GUID mismatch after an ungraceful snapshot restore of a virtualized DC.
- **Remediation Commands:**
  ```bash
  # Step 1: Force Time Sync using ntpdate / chrony against PDC Emulator
  $ sudo chronyd -q 'server dc01.ad.enterprise.internal iburst'

  # Step 2: Trigger manual replication forcing full sync of Domain NC
  $ sudo samba-tool drs replicate dc02.ad.enterprise.internal dc01.ad.enterprise.internal DC=ad,DC=enterprise,DC=internal --full-sync

  # Step 3: Check database consistency across partitions
  $ sudo samba-tool dbcheck --cross-ncs
  ```

#### Scenario 2: Kerberos Clock Skew Error (`KRB_AP_ERR_SKEW`)
- **Symptom:** Clients fail to authenticate with error `Clock skew too great`.
- **Root Cause:** Active Directory Kerberos protocol enforces a maximum clock difference of 5 minutes (300 seconds) between client, Domain Controller, and target service to prevent replay attacks.
- **Remediation:**
  Ensure the Samba DC runs `systemd-timesyncd` or `chrony` configured with `ntp signd` socket permissions enabled for Samba:
  ```ini
  # /etc/chrony/chrony.conf snippet
  ntpsigndsocket /var/lib/samba/ntp_signd
  ```
  Fix directory permissions:
  ```bash
  $ sudo chown root:chrony /var/lib/samba/ntp_signd
  $ sudo chmod 0750 /var/lib/samba/ntp_signd
  ```

#### Scenario 3: SYSVOL Synchronization Drift Across Samba DCs
- **Symptom:** Group Policy Objects (GPOs) created on DC01 do not apply to clients authenticating against DC02.
- **Root Cause:** Unlike Microsoft Windows Server (which uses DFS-R), Samba does not natively implement automated in-kernel SYSVOL file-system replication.
- **Production Solution:** Implement bi-directional `rsync` over SSH with strict POSIX ACL preservation (`--acls --xattrs`), or utilize distributed filesystem mechanisms such as CTDB / GlusterFS / Ceph for clustered SYSVOL hosting.
- **Manual SYSVOL Reset Command:**
  ```bash
  $ sudo samba-tool ntacl sysvolreset
  ```

#### Scenario 4: LDB Database Corruption & Tombstone Garbage Collection
- **Symptom:** Samba fails to launch with `LDB Transaction error` or object lookup fails with corrupted index errors.
- **Remediation Procedure:**
  ```bash
  # Step 1: Stop Samba services completely
  $ sudo systemctl stop samba-ad-dc

  # Step 2: Perform offline database check and automated repair
  $ sudo samba-tool dbcheck --cross-ncs --fix --yes

  # Step 3: If index corruption persists, force LDB re-index
  $ sudo ldbedit -H /var/lib/samba/private/sam.ldb --reindex

  # Step 4: Restart Service
  $ sudo systemctl start samba-ad-dc
  ```

---

## 6. References

- **Linux Professional Institute (LPI) Official Exam Objectives:**
  [LPIC-3 Exam 300 Objectives & Overview](https://www.lpi.org/our-certifications/lpic-3-300-overview/)
- **Samba Official Documentation & AD DC Wiki Guides:**
  [Samba AD DC HOWTO & Architecture Guides](https://wiki.samba.org/index.php/Setting_up_Samba_as_an_Active_Directory_Domain_Controller)
- **Samba Technical Specifications & BIND9 Integration:**
  [Samba BIND9 DLZ Module Configuration](https://wiki.samba.org/index.php/BIND9_DLZ_DNS_Back_End)
- **Microsoft Active Directory Technical Specifications (MS-ADTS):**
  [Microsoft Docs: MS-ADTS Active Directory Technical Specification](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-adts/)
- **Microsoft Directory Replication Service Remote Protocol (MS-DRSR):**
  [Microsoft Docs: MS-DRSR Specification](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-drsr/)
- **IETF RFC 4120 - The Kerberos Network Authentication Service (V5):**
  [IETF RFC 4120 Specification](https://datatracker.ietf.org/doc/html/rfc4120)
- **IETF RFC 2782 - A DNS RR for specifying the location of services (DNS SRV):**
  [IETF RFC 2782 Specification](https://datatracker.ietf.org/doc/html/rfc2782)