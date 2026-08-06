# LPIC-3 Exam 300-300 (v3.0) — Topic 305: Linux Identity Management and File Sharing

## Official Reference Sources
* [LPI Official LPIC-3 300 Objectives & Overview](https://www.lpi.org/our-certifications/lpic-3-300-overview/)
* [FreeIPA Technical Documentation & Architecture](https://www.freeipa.org/page/Documentation)
* [SSSD System Security Services Daemon Technical Guides](https://sssd.io/docs/design_pages/index.html)
* [Linux Kernel Network File System (NFSv4) Specification & Administration](https://nfs.sourceforge.net/)
* [MIT Kerberos V5 Administrator's Guide](https://web.mit.edu/kerberos/krb5-latest/doc/admin/index.html)

---

## 1. Deep Architecture & Internal Mechanics

### 1.1 FreeIPA Integrated Core Services Engine
FreeIPA serves as an enterprise-grade, integrated identity, policy, and audit management framework. Rather than reinventing core security components, it orchestrates four main open-source protocols and daemons:

```
                  +-------------------------------------------------------+
                  |                   FreeIPA Framework                   |
                  |          (Management CLI, Web UI, XML-RPC/JSON)       |
                  +--------------------------+----------------------------+
                                             |
        +-------------------+----------------+--------------------+-------------------+
        |                   |                                     |                   |
+-------v-------+   +-------v-------+                     +-------v-------+   +-------v-------+
|  389 Directory|   |  MIT Kerberos |                     |   Dogtag PKI  |   |   BIND9 DNS   |
|     Server    |   |    KDC / CA   |                     |   Certificate |   |  (GSS-TSIG)   |
| (LDAP backend)|   | (KDB via LDAP)|                     |   Authority   |   |               |
+---------------+   +---------------+                     +---------------+   +---------------+
        ^                   ^                                     ^                   ^
        |                   |                                     |                   |
        +-------------------+-------------------------------------+-------------------+
                                            |
                                    +-------+-------+
                                    | SSSD Daemon   |
                                    | (Linux Client)|
                                    +---------------+
```

1. **389 Directory Server (LDAP Engine)**: Operates as the central identity database store. FreeIPA leverages custom LDAP schemas (`slapi-nis` plugin for legacy compatibility, `memberof` plugin for dynamic group resolution, and schema extension modules for Kerberos principal mapping).
2. **MIT Kerberos KDC (Authentication Engine)**: Provides single sign-on (SSO) ticket-granting architecture. The Kerberos database module (`kdb_ldap`) hooks directly into 389 Directory Server, eliminating database synchronization overhead between directory listings and Kerberos principal secrets.
3. **Dogtag PKI (Certificate Authority)**: Manages X.509 certificate lifecycles, automated issuance via SCEP/EST protocols, smart card enrollment, and service identity verification across nodes.
4. **BIND9 DNS (Service Discovery & Security)**: Integrates directly with 389-ds via the `bind-dyndb-ldap` plugin. It dynamically exposes Kerberos (`_kerberos._tcp.EXAMPLE.COM`) and LDAP (`_ldap._tcp.EXAMPLE.COM`) SRV records, while leveraging `GSS-TSIG` (Kerberos-authenticated DNS updates) to guarantee tamper-proof dynamic record creation during client enrollment.

---

### 1.2 Kerberos Ticket Lifecycle & SSSD Caching Architecture

#### Kerberos Authentication Mechanics
```
[Client Host]                 [FreeIPA KDC]                [NFS/SSSD Service]
     |                              |                               |
     |--- 1. AS-REQ (Principal) --->|                               |
     |<-- 2. AS-REP (TGT + Session)-|                               |
     |                              |                               |
     |--- 3. TGS-REQ (TGT + SPN) -->|                               |
     |<-- 4. TGS-REP (Service Tkt) -|                               |
     |                              |                               |
     |------------------ 5. AP-REQ (Service Ticket) --------------->|
     |<----------------- 6. AP-REP (Mutual Authentication) ---------|
```

1. **AS-REQ / AS-REP (Authentication Service Exchange)**: The user client sends an `AS-REQ` containing its user principal name (UPN) to port 88. The KDC verifies the user identity against LDAP, encrypts a Ticket Granting Ticket (TGT) using the client's secret key (derived from password/keytab via string-to-key salt algorithms), and returns an `AS-REP`.
2. **TGS-REQ / TGS-REP (Ticket Granting Service Exchange)**: To access a Kerberized service (e.g., `nfs/storage.example.com`), the client presents its TGT in a `TGS-REQ`. The KDC issues a Service Ticket encrypted with the target service principal's secret key (`TGS-REP`).
3. **AP-REQ / AP-REP (Application Exchange)**: The client presents the Service Ticket directly to the target daemon. The daemon decrypts the ticket using its local keytab file (`/etc/krb5.keytab`), proving client identity without transmitting credentials across the wire.

#### SSSD (System Security Services Daemon) Architecture
SSSD acts as the local access broker on Linux clients, reducing KDC/LDAP query traffic and enabling offline authentication via LDB (Local Database) caches:

* **NSS Responder (`sssd_nss`)**: Hooks into glibc NSS via `libnss_sss.so` to resolve POSIX identities (`getpwnam`, `getgrnam`).
* **PAM Responder (`sssd_pam`)**: Hooks into PAM via `pam_sss.so` to handle authentication, password changes, and access control policies (HBAC).
* **LDB Storage Engine**: Stores identity definitions, user attributes, sudo rules, and password hashes locally inside `/var/lib/sss/db/`. Memory-mapped files (`/var/lib/sss/mc/`) provide fast zero-IPC lookup caches for identity queries.

---

### 1.3 NFSv4 Architecture, RPCSEC_GSS, and Idmapping Mechanics

NFSv4 is a stateful, single-port protocol (TCP 2049) featuring a unified pseudo-filesystem namespace. Unlike NFSv3, it eliminates sideband daemons (`rpc.mountd`, `statd`, `lockd`).

```
                    NFSv4 Protocol Stack Over Network
+------------------------------------------------------------------------+
|                      NFSv4 Application Payload                         |
|           (COMPOUND RPC: LOOKUP + OPEN + READ/WRITE + CLOSE)           |
+------------------------------------------------------------------------+
|           RPCSEC_GSS Layer (GSS-API Wrapper for Kerberos v5)          |
|  - krb5  : Payload unencrypted, header authenticated                  |
|  - krb5i : Payload integrity protection via HMAC-SHA-1                 |
|  - krb5p : Full payload encryption via AES-256-CTS                     |
+------------------------------------------------------------------------+
|                     ONC RPC (Remote Procedure Call)                    |
+------------------------------------------------------------------------+
|                      TCP Transport Layer (Port 2049)                   |
+------------------------------------------------------------------------+
```

* **Idmapping Protocol (`nfsidmap` / `rpc.idmapd`)**: NFSv4 wire protocols transmit user/group identity strings in the format `user@domain.com` instead of numeric UIDs/GIDs. The local kernel invokes `nfsidmap` to translate wire strings to local POSIX UIDs/GIDs via SSSD/NSS. If the domain part in `/etc/idmapd.conf` mismatches between client and server, identity resolution falls back to `nobody:nobody` (`nobodyuid`/`nobodygid`).
* **RPCSEC_GSS & Security Flavors**:
  * `sec=krb5`: Authenticates RPC requests using Kerberos tokens.
  * `sec=krb5i`: Provides authentication and cryptographically signs RPC payloads to prevent tampering (Integrity).
  * `sec=krb5p`: Encrypts the entire RPC payload between client and server to prevent eavesdropping (Privacy).

---

## 2. Guided Production Exercises

### Exercise 1: Deploying a Production FreeIPA Master Server with BIND9 DNS

#### Context & Objectives
Deploy a FreeIPA master server on host `ipa-master.infra.example.com` (`192.168.50.10`) inside the domain `infra.example.com` with realm `INFRA.EXAMPLE.COM`. Enable integrated BIND DNS with external forwarders.

#### Step 1.1: System Prerequisites Verification
Execute pre-flight checks to ensure FQDN resolution and clean firewall configurations:

```bash
sudo hostnamectl set-hostname ipa-master.infra.example.com
echo "192.168.50.10 ipa-master.infra.example.com ipa-master" | sudo tee -a /etc/hosts

# Verify DNS resolution fallback
getent hosts ipa-master.infra.example.com
```

*Expected Output:*
```text
192.168.50.10   ipa-master.infra.example.com ipa-master
```

Open required network ports in `firewalld`:

```bash
sudo firewall-cmd --permanent --add-service={freeipa-ldap,freeipa-ldaps,dns,ntp}
sudo firewall-cmd --reload
```

*Expected Output:*
```text
success
success
```

---

#### Step 1.2: Unattended Installation of FreeIPA Master
Run `ipa-server-install` non-interactively:

```bash
sudo ipa-server-install --unattended \
  --realm=INFRA.EXAMPLE.COM \
  --domain=infra.example.com \
  --hostname=ipa-master.infra.example.com \
  --ds-password='DirectoryManagerSecret123!' \
  --admin-password='IPAAdminSecret123!' \
  --setup-dns \
  --forwarder=8.8.8.8 \
  --auto-reverse \
  --no-ntp
```

*Expected Output Log Snippet:*
```text
[[1/28]]: configuring Directory Server instance
[[2/28]]: adding default schema extensions
[[8/28]]: setting up Kerberos KDC daemon
[[14/28]]: setting up certificate server instance
[[22/28]]: configuring BIND DNS server
[[28/28]]: restarting FreeIPA services
==============================================================================
Setup complete

Next steps:
	1. You must make sure these network ports are open:
		TCP Ports:
		  * 80, 443: HTTP/HTTPS
		  * 389, 636: LDAP/LDAPS
		  * 88, 464: Kerberos
		  * 53: DNS

	2. You can now obtain a Kerberos ticket using:
		kinit admin

==============================================================================
```

---

#### Step 1.3: Verifying Services and Generated Configurations
Inspect the generated central configuration file `/etc/ipa/default.conf`:

```bash
cat /etc/ipa/default.conf
```

*Generated Syntactically Valid Manifest:*
```ini
# Auto-generated by IPA installer
[global]
domain = infra.example.com
realm = INFRA.EXAMPLE.COM
xmlrpc_uri = https://ipa-master.infra.example.com/ipa/xml
enable_ra = True
host = ipa-master.infra.example.com
mod_auth_ntlm_winbind_keep_state = True
basedn = dc=infra,dc=example,dc=com
```

Check system daemon status:

```bash
sudo ipactl status
```

*Expected Output:*
```text
Directory Service: RUNNING
Krb5kdc Service: RUNNING
Kadmin Service: RUNNING
Named Service: RUNNING
ipactl Service: RUNNING
pki-tomcatd Service: RUNNING
ipa-otpd Service: RUNNING
ipa-custodia Service: RUNNING
httpd Service: RUNNING
ipa-dnskeysyncd Service: RUNNING
ipa-certmonger Service: RUNNING
```

Verify admin ticket generation:

```bash
echo 'IPAAdminSecret123!' | kinit admin
klist
```

*Expected Output:*
```text
Ticket cache: KCM:0
Default principal: admin@INFRA.EXAMPLE.COM

Valid starting       Expires              Service principal
08/06/26 13:00:00  08/07/26 13:00:00  krbtgt/INFRA.EXAMPLE.COM@INFRA.EXAMPLE.COM
```

---

### Comprehension Questions (Block 1)

1. **Why does FreeIPA recommend installing an integrated BIND DNS server using `GSS-TSIG` rather than leveraging an unauthenticated external generic DNS server?**
2. **If `ipactl status` reports that `pki-tomcatd` is `STOPPED`, what specific FreeIPA capabilities are degraded, and how does this affect host certificate renewal processes?**

---

### Exercise 2: Client Enrollment, Entity Management, and SSSD Hardening

#### Context & Objectives
Enroll client `app-node-01.infra.example.com` (`192.168.50.20`) into the FreeIPA domain. Configure SSSD on the client for offline credential caching and strict access control rules (HBAC). Create enterprise user entities, POSIX groups, and sudo rules using the `ipa` CLI.

#### Step 2.1: Enrolling the Linux Client
Execute `ipa-client-install` on `app-node-01`:

```bash
sudo ipa-client-install --unattended \
  --mkhomedir \
  --domain=infra.example.com \
  --server=ipa-master.infra.example.com \
  --principal=admin \
  --password='IPAAdminSecret123!'
```

*Expected Output:*
```text
Discovery result: Domain: infra.example.com, Server: ipa-master.infra.example.com, Port: 389, KDC: ipa-master.infra.example.com
Client hostname: app-node-01.infra.example.com
Realm: INFRA.EXAMPLE.COM
DNS Domain: infra.example.com
IPA Server: ipa-master.infra.example.com
BaseDN: dc=infra,dc=example,dc=com

Configured /etc/sssd/sssd.conf
Configured /etc/krb5.conf
Client configuration complete.
The ipa-client-install command was successful.
```

---

#### Step 2.2: Hardening Client `/etc/sssd/sssd.conf`
Edit `/etc/sssd/sssd.conf` to configure offline authentication limits, dynamic DNS updates, and LDAP identity filtering:

```bash
sudo cat << 'EOF' | sudo tee /etc/sssd/sssd.conf
[sssd]
services = nss, pam, sudo, ssh
config_file_version = 2
domains = infra.example.com

[domain/infra.example.com]
id_provider = ipa
auth_provider = ipa
access_provider = ipa
chpass_provider = ipa
ipa_server = _srv_, ipa-master.infra.example.com
ipa_domain = infra.example.com
ipa_hostname = app-node-01.infra.example.com
krb5_realm = INFRA.EXAMPLE.COM
krb5_store_password_if_offline = true
cache_credentials = true
account_cache_expiration = 7
entry_cache_timeout = 600
ldap_tls_cacert = /etc/ipa/ca.crt
dyndb_auth = true
EOF

sudo chmod 600 /etc/sssd/sssd.conf
sudo systemctl restart sssd
```

---

#### Step 2.3: Entity Management via FreeIPA CLI
On `ipa-master.infra.example.com`, provision POSIX users, groups, and HBAC (Host-Based Access Control) rules:

```bash
# 1. Create a POSIX group for SysOps Engineers
ipa group-add sysops --desc="System Operations Engineers" --gid=5001

# 2. Add an enterprise SRE user
ipa user-add jdoe --first="John" --last="Doe" \
  --homedir=/home/jdoe --shell=/bin/bash \
  --uid=10001 --gidnumber=5001 --password

# 3. Add user to sysops group
ipa group-add-member sysops --users=jdoe

# 4. Create an HBAC Rule allowing sysops users access to app-node-01
ipa hbacrule-add sysops-access-app-node --usercategory=all
ipa hbacrule-add-user sysops-access-app-node --groups=sysops
ipa hbacrule-add-host sysops-access-app-node --hosts=app-node-01.infra.example.com
ipa hbacrule-add-service sysops-access-app-node --hbacservices=sshd
```

*Expected Output Snippet:*
```text
---------------------------------------------
Added HBAC rule "sysops-access-app-node"
---------------------------------------------
  Rule name: sysops-access-app-node
  User category: all
  Enabled: True
```

---

#### Step 2.4: Validating SSSD Identity Resolution and Cache Management
On `app-node-01.infra.example.com`, test user lookup and force cache invalidation:

```bash
# Verify user lookup via SSSD NSS responder
getent passwd jdoe
```

*Expected Output:*
```text
jdoe:*:10001:5001:John Doe:/home/jdoe:/bin/bash
```

Test offline caching using `sssctl`:

```bash
# Inspect domain cache status
sudo sssctl domain-status infra.example.com

# Flush local SSSD LDB memory maps and databases
sudo sssctl cache-remove --domain=infra.example.com
```

*Expected Output:*
```text
Online status: Online

Active servers:
IPA: ipa-master.infra.example.com

SSSD cache successfully removed.
```

---

### Comprehension Questions (Block 2)

1. **How does SSSD process user authentication when the network link to the FreeIPA server is completely severed, and what configuration directive controls the duration of allowed offline logins?**
2. **If an administrator revokes a user's HBAC permission on the FreeIPA server, but the user can still log into `app-node-01` via SSH for the next 10 minutes, which component and settings are responsible for this latency?**

---

### Exercise 3: Cross-Realm Active Directory Trust Integration Mechanics

#### Context & Objectives
Integrate FreeIPA with an existing Active Directory domain (`CORP.LOCAL`). Configure the trust subsystem using `ipa-adtrust-install`, establish a one-way trust relationship, and configure SSSD identity mapping rules for AD users.

```
+------------------------------------+             +------------------------------------+
|       FreeIPA Realm                |             |       Active Directory Realm       |
|    INFRA.EXAMPLE.COM               |             |             CORP.LOCAL             |
|                                    |   Trust     |                                    |
| +--------------------------------+ |  Relation   | +--------------------------------+ |
| | ipa-master.infra.example.com   |<===============>| ad-dc01.corp.local             | |
| | (Cross-Realm KDC + Samba Winbind)| | (Kerberos)  | | (Active Directory Domain Ctrl) | |
| +--------------------------------+ |             | +--------------------------------+ |
+------------------------------------+             +------------------------------------+
```

#### Step 3.1: Deploying FreeIPA AD Trust Components
On `ipa-master.infra.example.com`, run the trust installer. This configures Samba's `winbindd` daemon internally on the KDC to evaluate Active Directory PAC (Privilege Attribute Certificate) tokens:

```bash
sudo ipa-adtrust-install --unattended \
  --netbios-name=INFRA \
  --admin-name=Administrator \
  --admin-password='ADAdminSecret123!'
```

*Expected Output Log Snippet:*
```text
Configuring SMB service
Configuring NetBIOS name mapping
Configuring Samba winbindd for CIFS/AD trust processing
Setup of AD trust support complete
```

---

#### Step 3.2: Establishing Cross-Realm Forest Trust
Create the trust link between `INFRA.EXAMPLE.COM` and `CORP.LOCAL`:

```bash
ipa trust-add --type=ad corp.local \
  --admin=Administrator \
  --password='ADAdminSecret123!' \
  --two-way=false
```

*Expected Output:*
```text
--------------------------------------------------
Added Active Directory trust for realm "corp.local"
--------------------------------------------------
  Realm name: corp.local
  Trust type: Active Directory domain
  Trust direction: One-way incoming
  Trust status: Established and verified
```

---

#### Step 3.3: Configuring Algorithmic RID Mapping in SSSD
When AD users log into Linux, AD might not possess native POSIX schema attributes (`uidNumber`, `gidNumber`). SSSD generates deterministic POSIX IDs using the SID-to-RID mapping algorithm.

Examine `/etc/sssd/sssd.conf` configuration for AD subdomains:

```ini
# Add AD domain mapping section inside /etc/sssd/sssd.conf on client nodes
[domain/infra.example.com/corp.local]
id_provider = ad
auth_provider = ad
access_provider = ad
ad_domain = corp.local
ad_server = ad-dc01.corp.local
ldap_id_mapping = true
ldap_idmap_range_min = 200000
ldap_idmap_range_max = 200000000
ldap_idmap_range_size = 200000
```

---

#### Step 3.4: Verifying AD User Resolution and Cross-Realm Kerberos Tickets
Validate that an AD user (e.g., `asmith@corp.local`) can be resolved by POSIX subsystems on the FreeIPA client node:

```bash
# Query AD user through SSSD
getent passwd "asmith@corp.local"
```

*Expected Output:*
```text
asmith@corp.local:*:201004:201004:Alice Smith:/home/corp.local/asmith:/bin/bash
```

Request a cross-realm ticket using `kinit`:

```bash
kinit asmith@CORP.LOCAL
klist
```

*Expected Output:*
```text
Ticket cache: KCM:0
Default principal: asmith@CORP.LOCAL

Valid starting       Expires              Service principal
08/06/26 13:30:00  08/06/26 23:30:00  krbtgt/CORP.LOCAL@CORP.LOCAL
08/06/26 13:30:05  08/06/26 23:30:00  krbtgt/INFRA.EXAMPLE.COM@CORP.LOCAL
```

---

### Comprehension Questions (Block 3)

1. **How does FreeIPA process Active Directory Kerberos tickets containing PAC (Privilege Attribute Certificate) data when an AD user accesses a Linux resource, and why is `winbindd` required on the FreeIPA Master?**
2. **What issue occurs if two different AD domains mapped by SSSD overlap in their `ldap_idmap_range` settings, and how does SSSD compute UIDs deterministically from a user's Windows Security Identifier (SID)?**

---

### Exercise 4: Secure NFSv4 Deployment with Kerberos (RPCSEC_GSS) and Idmapping

#### Context & Objectives
Deploy a Kerberized NFSv4 storage server (`nfs-server.infra.example.com`) exporting `/exports/finance` using `sec=krb5p`. Configure identity mapping via `nfsidmap`, manage service principal keytabs via FreeIPA, and mount the secure export on `app-node-01.infra.example.com`.

```
[ app-node-01.infra.example.com ]                      [ nfs-server.infra.example.com ]
  (NFSv4 Client + SSSD)                                   (NFSv4 Server + SSSD)
         |                                                          |
         |======== RPCSEC_GSS (sec=krb5p: Encrypted TCP 2049) ======>|
         |                                                          |
  Mount: /mnt/finance                                     Export: /exports/finance
  Identity: jdoe@infra.example.com                       Identity: jdoe@infra.example.com
         |                                                          |
         +-------------> Transmitted Wire Identity <----------------+
                         "jdoe@infra.example.com"
```

#### Step 4.1: Service Principal Creation & Keytab Provisioning
On `ipa-master.infra.example.com`, generate the NFS service principal for `nfs-server.infra.example.com`:

```bash
# Register NFS service principal
ipa service-add nfs/nfs-server.infra.example.com

# Retrieve keytab and export to server host
sudo ipa-getkeytab -p nfs/nfs-server.infra.example.com \
  -k /etc/krb5.keytab
```

*Expected Output:*
```text
Keytab successfully retrieved and stored in: /etc/krb5.keytab
```

Verify service ticket keytab contents using `ktutil` or `klist`:

```bash
sudo klist -k /etc/krb5.keytab
```

*Expected Output:*
```text
Keytab name: FILE:/etc/krb5.keytab
KVNO Principal
---- --------------------------------------------------------------------------
   1 nfs/nfs-server.infra.example.com@INFRA.EXAMPLE.COM
   1 nfs/nfs-server.infra.example.com@INFRA.EXAMPLE.COM
```

---

#### Step 4.2: Configuring NFSv4 Server Pseudo-FileSystem and Exports
On `nfs-server.infra.example.com`, configure `/etc/idmapd.conf` to match the exact FreeIPA domain:

```ini
# /etc/idmapd.conf
[General]
Verbosity = 2
Pipefs-Directory = /var/lib/nfs/rpc_pipefs
Domain = infra.example.com

[Mapping]
Nobody-User = nobody
Nobody-Group = nobody

[Translation]
Method = nsswitch
```

Set up directory structures and `/etc/exports`:

```bash
sudo mkdir -p /exports/finance
sudo chown -R 10001:5001 /exports/finance
sudo chmod 770 /exports/finance

# Configure NFSv4 exports with pseudo-root and strong Kerberos privacy (krb5p)
cat << 'EOF' | sudo tee /etc/exports
/exports         *(rw,sync,no_subtree_check,crossmnt,fsid=0)
/exports/finance 192.168.50.0/24(rw,sync,no_subtree_check,sec=krb5p,root_squash)
EOF

# Export shares and restart services
sudo exportfs -rav
sudo systemctl restart nfs-server rpc-gssd
```

*Expected Output:*
```text
exporting 192.168.50.0/24:/exports/finance
exporting *:/exports
```

---

#### Step 4.3: Mounting Encrypted NFSv4 Shares on Client
On `app-node-01.infra.example.com`, retrieve an NFS client keytab if necessary, ensure `rpc-gssd` is active, and mount the share:

```bash
# Ensure gssd daemon is running for RPCSEC_GSS context handling
sudo systemctl enable --now rpc-gssd

# Mount using NFSv4 protocol and Kerberos Privacy mode
sudo mount -t nfs4 -o proto=tcp,sec=krb5p nfs-server.infra.example.com:/finance /mnt/finance

# Verify active mount point status
mount | grep nfs4
```

*Expected Output:*
```text
nfs-server.infra.example.com:/finance on /mnt/finance type nfs4 (rw,relatime,vers=4.2,rsize=1048576,wsize=1048576,namlen=255,hard,proto=tcp,timeo=600,retrans=2,sec=krb5p,clientaddr=192.168.50.20,local_lock=none,addr=192.168.50.30)
```

---

#### Step 4.4: Advanced Diagnostics and Troubleshooting Protocols
Execute diagnostics to trace identity mapping and RPCSEC_GSS payload handling:

##### 1. Inspecting Wire Idmapping Status
If files show up as `nobody:nobody`, check client kernel `nfsidmap` translation cache:

```bash
# Clear nfsidmap keyring cache
sudo nfsidmap -c

# Query translation of wire string directly
nfsidmap -g jdoe@infra.example.com
```

*Expected Output:*
```text
5001
```

##### 2. Deep Kernel RPC Debugging
Enable verbosity on kernel NFS client/RPC modules to debug GSS authentication failures:

```bash
# Enable RPC and NFS GSS debugging flags
sudo rpcdebug -m rpc -s auth gss
sudo rpcdebug -m nfs -s all

# Read kernel log buffer
sudo dmesg -T | grep -E "RPC|GSS|NFS" | tail -n 10
```

*Expected Output:*
```text
[Thu Aug 6 13:45:10 2026] RPC: SEC_GSS context established for principal nfs/nfs-server.infra.example.com@INFRA.EXAMPLE.COM
[Thu Aug 6 13:45:10 2026] NFS: nfs4_discover_server_trunking complete for server nfs-server.infra.example.com
```

Reset debug flags after analysis:

```bash
sudo rpcdebug -m rpc -c all
sudo rpcdebug -m nfs -c all
```

##### 3. Monitoring NFS Performance Metrics
Inspect RPC statistics using `nfsstat`:

```bash
nfsstat -c -4
```

*Expected Output:*
```text
Client rpc stats:
calls      retrans    authrefrsh
142        0          142

Client nfs v4 ops:
 null         read         write        commit       open         open_conf  
 0         0% 12       8% 45      31% 2        1% 5        3% 0        0% 
```

---

### Comprehension Questions (Block 4)

1. **What is the exact architectural difference between `sec=krb5`, `sec=krb5i`, and `sec=krb5p` in terms of CPU overhead, packet encapsulation, and wire privacy?**
2. **If a user `jdoe` creates a file on an NFSv4 mount with `sec=krb5p`, but the file ownership displays as `nobody:nobody` on the server, what are the three most common root causes in `/etc/idmapd.conf`, SSSD, or DNS?**
3. **Why does NFSv4 eliminate the need for `rpc.lockd` and `rpc.statd` daemons required by NFSv3?**

---

## 3. Verified Solutions & Technical Explanations

<details>
<summary>Click to expand Solutions and Detailed Technical Explanations</summary>

### Answers to Block 1 Questions

1. **Integrated BIND DNS with `GSS-TSIG` Rationale**:
   FreeIPA relies heavily on DNS Service Records (`SRV`) to allow clients to automatically discover Kerberos KDCs, LDAP servers, and CA endpoints dynamically without hardcoding IP addresses. 
   When hosts enroll into the FreeIPA domain using `ipa-client-install`, they attempt to publish their own forward (`A`/`AAAA`) and reverse (`PTR`) records. By deploying integrated BIND9 with `GSS-TSIG` (GSSAPI-authenticated TSIG keys via Kerberos), DNS dynamic updates are cryptographically authenticated using the host's Kerberos credentials (`host/hostname@REALM`). 
   Unauthenticated generic DNS servers would either reject dynamic updates or leave DNS record creation vulnerable to spoofing, potentially redirecting authentication flows to malicious KDCs (Man-in-the-Middle attacks).

2. **Impact of `pki-tomcatd` Daemon Failure**:
   `pki-tomcatd` hosts the Dogtag PKI Certificate Authority engine. If this service is stopped:
   * **Degraded Functionality**: New certificates cannot be issued, existing certificates cannot be revoked, and smart card enrollment fails.
   * **Host Certificate Renewal**: The `certmonger` daemon running on client/server nodes will fail to renew expiring SSL/TLS or IPsec certificates (e.g., HTTPD or LDAP server certs). While existing Kerberos authentication tokens will continue to work until their certificates or tickets expire, automated infrastructure maintenance breaks entirely.

---

### Answers to Block 2 Questions

1. **SSSD Offline Authentication Processing**:
   When network connectivity to FreeIPA is lost, SSSD's PAM module (`pam_sss.so`) switches to offline verification mode. Instead of contacting the KDC via AS-REQ over port 88, SSSD computes a cryptographic hash (salted PBKDF2/SHA-512) of the password supplied by the user and compares it against the cached hash stored in the local LDB database (`/var/lib/sss/db/cache_<domain>.ldb`).
   * **Controlling Directive**: The duration and validity of offline credentials are controlled by `offline_credentials_expiration` (measured in days) inside `/etc/sssd/sssd.conf`. If set to `0`, offline logins are allowed indefinitely as long as cached credentials exist.

2. **HBAC Revocation Cache Latency**:
   * **Responsible Component**: SSSD's identity and access rule caching mechanism inside `/var/lib/sss/db/`.
   * **Responsible Settings**: SSSD caches HBAC (Host-Based Access Control) rules to avoid querying LDAP on every single SSH connection or `sudo` execution. The setting controlling how long HBAC rules remain valid before re-querying the LDAP server is `entry_cache_hbac_timeout` (or general `entry_cache_timeout`, default is 5400 seconds / 90 minutes unless tuned). 
   To force immediate revocation enforcement across nodes, an operator must run `sssctl cache-remove` or `sss_cache -E` on the client host.

---

### Answers to Block 3 Questions

1. **PAC Data Processing & `winbindd` Requirement**:
   Active Directory embeds a Privilege Attribute Certificate (PAC) inside Kerberos tickets issued to users. The PAC contains the user's AD Security Identifiers (SIDs), domain group memberships, and security claims.
   When an AD user attempts to access a resource in the FreeIPA realm across the cross-realm trust:
   * The FreeIPA KDC receives the cross-realm TGT.
   * FreeIPA must evaluate whether the SIDs inside the PAC map to valid POSIX groups and whether the user is authorized.
   * The `winbindd` daemon (configured via `ipa-adtrust-install`) is specifically responsible for contacting Active Directory Domain Controllers via RPC calls, decoding the NTLM/PAC structure, verifying the PAC digital signature using the trust secret, and translating AD SIDs into internal representations that FreeIPA's 389-ds Directory Server can process.

2. **ID Mapping Overlaps & Deterministic SID Computation**:
   * **Overlap Issues**: If two AD domain configurations in `/etc/sssd/sssd.conf` have overlapping `ldap_idmap_range` values (e.g., Domain A and Domain B both using `200000-400000`), SSSD will generate colliding POSIX UIDs/GIDs for completely different AD users. This leads to critical privilege escalation vulnerabilities where User A in Domain A gains full file access permissions of User B in Domain B.
   * **Deterministic SID Computation**: SSSD converts a Windows SID (e.g., `S-1-5-21-100-200-300-1050`) into a POSIX UID using a hash-based or algorithmic range mapping function:
     $$\text{POSIX UID} = \text{Range Base UID} + (\text{RID} - \text{Min RID})$$
     Where $\text{RID}$ is the relative identifier (the last sub-authority of the SID, e.g., `1050`). Because the formula is mathematical and purely deterministic, every Linux client running SSSD computes the exact same POSIX UID for a given AD user without writing UID attributes back to Active Directory LDAP.

---

### Answers to Block 4 Questions

1. **NFSv4 Security Flavors Comparison**:
   * `sec=krb5` (Authentication Only): Authenticates the user principal via Kerberos during the initial RPC setup. Headers are signed, but standard RPC payloads (file read/write data blocks) travel across the network as unencrypted raw plaintext. Minimal CPU overhead.
   * `sec=krb5i` (Integrity Protection): Uses Kerberos session keys to compute an HMAC checksum (typically HMAC-SHA1 or HMAC-SHA256) for every RPC header and payload packet. Prevents active network tampering, packet injection, or man-in-the-middle data corruption. Moderate CPU overhead due to hash calculations.
   * `sec=krb5p` (Privacy / Encryption): Wraps the entire ONC RPC payload inside GSS-API cryptographic encapsulation using symmetric ciphers (AES-128-CTS or AES-256-CTS). Ensures full wire confidentiality and integrity. Higher CPU overhead due to hardware/software cryptographic encryption/decryption cycles per IOPS.

2. **Root Causes of `nobody:nobody` Ownership Degradation**:
   * **Mismatch in `/etc/idmapd.conf` Domain**: The `Domain =` string in `/etc/idmapd.conf` MUST be identical on both the NFSv4 server and client (e.g., `Domain = infra.example.com`). If the client uses `infra.example.com` and the server uses `localdomain`, identity translation fails, forcing the kernel to map the string `jdoe@infra.example.com` to `nobodyuid`.
   * **SSSD / NSS Name Resolution Failure**: If the server's local `rpc.idmapd` / `nfsidmap` daemon queries `getpwnam("jdoe@infra.example.com")` or `getpwnam("jdoe")` via NSS, and SSSD is stopped or misconfigured, the local OS cannot resolve the string to a valid local POSIX UID (10001).
   * **DNS FQDN / Reverse PTR Mismatch**: If Kerberos tickets are requested for the NFS server, but reverse DNS (PTR) returns an unexpected hostname, `rpc-gssd` fails to negotiate the RPCSEC_GSS security context, causing NFSv4 to drop security association down to anonymous mapping (`nobody`).

3. **Elimination of Lockd and Statd in NFSv4**:
   NFSv3 was a stateless protocol. It delegated file locking and cluster status monitoring to separate network daemons (`rpc.lockd` for NLM protocol and `rpc.statd` for NSM protocol), requiring multiple random UDP/TCP ports and complex firewall rules.
   NFSv4 is inherently stateful. Open operations, file lock leases, stateids, and sequence numbers are built directly into the core NFSv4 wire protocol using COMPOUND RPC requests. Lease state is maintained over the single TCP connection on port 2049, making external lock/status daemons completely redundant.

</details>