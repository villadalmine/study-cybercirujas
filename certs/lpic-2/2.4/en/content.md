# LPIC-2 Study Guide: Topic 205 — Network Client Management (Exam 202-450, Version 4.5)

---

## 1. Motivation & Production Architecture Problem

In enterprise infrastructure engineering and Site Reliability Engineering (SRE), centralized network management and identity orchestration form the core foundation of zero-trust architecture. Operating heterogeneous clusters at scale—spanning bare-metal compute, hypervisors, and cloud edge nodes—requires automated network bootstrapping alongside centralized, cryptographically secured identity and access management (IAM).

```
                      +------------------------------------------+
                      |         Bare-Metal / Compute Node        |
                      |                                          |
                      |   +----------------------------------+   |
                      |   |      Linux Kernel (Network)      |   |
                      |   +----------------------------------+   |
                      |                    |                     |
                      |                    v                     |
                      |   +----------------------------------+   |
                      |   |   DHCP Client (dhclient / systemd) | <----+ [Port 67/68 UDP]
                      |   +----------------------------------+   |      DHCP HA Cluster
                      |                    |                     |
                      |                    v                     |
                      |   +----------------------------------+   |
                      |   |  PAM (Pluggable Auth Modules)    |   |
                      |   +----------------------------------+   |
                      |        |                     |           |
                      |        v                     v           |
                      |  [pam_unix.so]          [pam_sss.so]     |
                      |   (/etc/shadow)              |           |
                      +------------------------------|-----------+
                                                     |
                                                     v [Socket / IPC]
                                       +----------------------------+
                                       |   SSSD (System Security    |
                                       |      Services Daemon)      |
                                       +----------------------------+
                                                     |
                                                     v [LDAP / STARTTLS Port 389]
                                       +----------------------------+
                                       |  OpenLDAP HA Cluster (MDB)  |
                                       |  (cn=config + SyncRepl)    |
                                       +----------------------------+
```

### Key Production Challenges & Architectural Trade-Offs

#### 1. Identity & IP Address Management (IPAM) Cascading Failures
If network client configuration (DHCP) or identity resolution (LDAP/SSSD) suffers outages or latency spikes, host provisioning stops, SSH authentication blocks, and critical cron/daemon processes fail. Systems relying on synchronous remote database lookup per PAM transaction risk complete outage if the LDAP backend becomes unreachable.

#### 2. Network Client Provisioning Risks
Standard DHCP broadcast mechanisms lack authentication by default. Without rogue-DHCP suppression (DHCP Snooping), option 82 tagging, and redundancy (DHCP Failover protocol), network client management is vulnerable to man-in-the-middle (MitM) attacks, IP address depletion (DHCP starvation), and single-point-of-failure (SPOF) disruptions.

#### 3. Authentication Pipeline Fragility
Improperly ordered PAM execution vectors (e.g., placing `sufficient` before a mandatory audit or lock-out module like `pam_faillock.so`) create critical authorization bypass vulnerabilities. Furthermore, misconfigured NSS lookup orders (`/etc/nsswitch.conf`) cause application execution stalls when external naming services fail to respond promptly.

#### 4. Directory Access Control List (ACL) & Storage Engine Scalability
Legacy OpenLDAP deployments utilizing `slapd.conf` and `bdb`/`hdb` backends experience database corruption during dirty shutdowns and block runtime dynamic configuration changes. Modern production architectures require the Memory-Mapped Database (`mdb`) engine paired with `cn=config` (On-Line Configuration - OLC) to perform zero-downtime policy and schema modifications via LDIF streams.

---

## 2. Technical Comparatives & Trade-Off Matrix

### 2.1 Network Addressing & IPAM Strategies

| Architecture Metric | ISC DHCP Server (Failover HA Pair) | Static IP Allocation (Ansible/Cloud-Init) | Kubernetes / CNI IPAM (Cilium / Calico) |
| :--- | :--- | :--- | :--- |
| **Bootstrapping Layer** | L2/L3 Physical & Hypervisor PXE | Provision-time Static Templating | L3 Overlay / eBPF Virtual Interfaces |
| **High Availability Mechanism** | OMAPI-based DHCP Failover State Sync | N/A (State baked into node config) | Distributed Etcd / CRD State Store |
| **Re-allocation Latency** | Low (Bound by Lease TTL & Renewal T1/T2) | Zero (Static), High manual lifecycle cost | Microseconds (Dynamic pod allocation) |
| **Rogue Mitigation** | Requires L2 Switch DHCP Snooping | Native L2/L3 Static Enforcement | NetworkPolicies & eBPF Policy Enforcement |
| **SRE Operational Burden** | Moderate (Lease database audit & relay configuration) | High at scale (Risk of IP overlap/exhaustion) | Low (Automated lifecycle managed via Operator) |

### 2.2 Linux Authentication Stack & Directory Integration

| Component | Direct LDAP NSS (`nslcd` / `pam_ldap`) | System Security Services Daemon (`sssd`) | Cloud IAM / OIDC Proxy (Teleport / Boundary) |
| :--- | :--- | :--- | :--- |
| **Offline Authentication** | **No** (Direct network connection required per auth event) | **Yes** (Encrypted local credential/schema cache) | **No** (Requires active short-lived TLS/SSH certificates) |
| **NSS Query Performance** | Low (Network RTT on every `getpwnam()` call) | High (In-memory `fast-pam` cache + LDB storage) | N/A (Bypasses POSIX NSS layer entirely) |
| **Connection Pooling & Failover**| Basic DNS SRV round-robin | Advanced multi-server discovery, health-checking & backoff | Edge Access Proxy abstraction with global load balancing |
| **Kerberos / AD Integration** | Requires complex manual integration | Native active-directory integration via `ad` provider | Integrates at identity provider (IdP) layer |
| **Security Vector** | Vulnerable to network partition lockouts | Risk of stale cached permissions if TTL is high | Requires PKI ecosystem; zero long-term keys on host |

### 2.3 Directory Service Implementations

| Parameter | OpenLDAP (`cn=config` + `MDB`) | FreeIPA / Red Hat IdM | Microsoft Active Directory Domain Services |
| :--- | :--- | :--- | :--- |
| **Primary Backend Engine** | LMDB (Lightning Memory-Mapped Database) | OpenLDAP (`389-ds`) + MIT Kerberos | Extensible Storage Engine (ESE / Jet) |
| **Schema Flexibility** | High (Custom schemas editable live via LDIF) | Moderate (Pre-packaged POSIX, Kerberos, DNS schemas) | Strict (Active Directory Schema Extensions) |
| **Replication Protocol** | SyncRepl (RefreshAndPersist / Auditlog) | Multi-Master Replication (389-ds plugin) | Multi-Master RPC/DRSR Replication |
| **Linux Native Integration**| Excellent (Native POSIX `posixAccount`/`posixGroup`) | Native (Built specifically for Linux enterprise management) | Requires SSSD `ad` provider or Samba Winbind |

---

## 3. Complete Production Manifests & Configuration Files

### 3.1 Primary ISC DHCP Server Configuration (`/etc/dhcp/dhcpd.conf`)

Production-grade, dual-homed DHCP server configuration featuring high-availability failover peering, PXE booting setup, custom option definitions, and static MAC-to-IP bindings.

```conf
# /etc/dhcp/dhcpd.conf - Production Primary DHCP Server Configuration
authoritative;
ddns-update-style none;
log-facility local7;

# Define custom PXE options
option space gpxe;
option gpxe-encap-opts code 175 = encapsulate gpxe;
option architecture-type code 93 = unsigned integer 16;

# Global Network Parameters
option domain-name "prod.infrastructure.internal";
option domain-name-servers 10.100.0.10, 10.100.0.11;
default-lease-time 86400;     # 24 Hours
max-lease-time 172800;        # 48 Hours

# High Availability Failover Protocol Declaration (Primary Peer)
failover peer "dhcp-failover-cluster" {
  primary;
  address 10.100.0.2;
  port 520;
  peer address 10.100.0.3;
  peer port 520;
  max-response-delay 30;
  max-unacked-updates 10;
  mclt 3600;
  split 128; # 50/50 Load balance split ratio
  load balance max seconds 3;
}

# Shared Network Segment for Production VLAN 100
subnet 10.100.0.0 netmask 255.255.240.0 {
  option routers 10.100.0.1;
  option broadcast-address 10.100.15.255;
  option ntp-servers 10.100.0.5;

  # Dynamic Pool with HA Failover Enforcement
  pool {
    failover peer "dhcp-failover-cluster";
    deny dynamic bootp clients;
    range 10.100.8.1 10.100.14.254;
  }
}

# Dedicated PXE Provisioning Subnet (VLAN 200)
subnet 10.200.0.0 netmask 255.255.255.0 {
  option routers 10.200.0.1;
  next-server 10.200.0.50; # TFTP / iPXE Server

  if option architecture-type = 00:07 {
    filename "uefi/bootx64.efi";
  } else {
    filename "pxelinux.0";
  }

  pool {
    range 10.200.0.100 10.200.0.200;
    default-lease-time 7200;
  }
}

# Reserved Static Host Declarations
host edge-node-01.prod.infrastructure.internal {
  hardware ethernet 52:54:00:fa:b1:99;
  fixed-address 10.100.1.50;
  option host-name "edge-node-01";
}
```

---

### 3.2 Enterprise PAM SSH Authentication Pipeline (`/etc/pam.d/sshd`)

Hardened Linux PAM configuration featuring account lockout protection (`pam_faillock`), remote identity resolution via SSSD (`pam_sss`), local root override fallback (`pam_unix`), environment isolation (`pam_limits`), and automatic home directory creation (`pam_mkhomedir`).

```pam
# /etc/pam.d/sshd - Production Pluggable Authentication Module Configuration
# Architecture: Auth -> Account -> Password -> Session

# ============================================================================
# 1. AUTHENTICATION MODULES
# ============================================================================
# Deny access early if service is marked as restricted
auth      requisite     pam_nologin.so

# Track failed login attempts for brute-force mitigation
auth      required      pam_faillock.so preauth silent audit deny=5 unlock_time=900 even_deny_root fail_interval=900

# Primary Credential Evaluation Pipeline:
# Try SSSD (Central LDAP/Kerberos). If successful, skip the local pam_unix check.
auth      [success=1 default=ignore] pam_sss.so forward_pass
auth      requisite     pam_unix.so try_first_pass nullok

# Mark login attempt as successful in faillock state engine if authentication passes
auth      required      pam_faillock.so authsucc audit deny=5 unlock_time=900 even_deny_root fail_interval=900

# Populate environment variables
auth      required      pam_env.so

# ============================================================================
# 2. ACCOUNT MANAGEMENT MODULES
# ============================================================================
# Evaluate user lock status
account   required      pam_faillock.so
# Check host access control policies (/etc/security/access.conf)
account   required      pam_access.so
# Evaluate local and SSSD account expiration/shadow metrics
account   sufficient    pam_unix.so
account   sufficient    pam_sss.so
account   required      pam_deny.so

# ============================================================================
# 3. PASSWORD MANAGEMENT MODULES
# ============================================================================
password  requisite     pam_pwquality.so retry=3 minlen=16 lcredit=-1 ucredit=-1 dcredit=-1 ocredit=-1 enforce_for_root
password  sufficient    pam_sss.so use_authtok
password  sufficient    pam_unix.so sha512 shadow try_first_pass use_authtok
password  required      pam_deny.so

# ============================================================================
# 4. SESSION MANAGEMENT MODULES
# ============================================================================
session   required      pam_loginuid.so
session   optional      pam_keyinit.so force revoke
session   required      pam_limits.so
session   required      pam_mkhomedir.so umask=0077 skel=/etc/skel/
session   sufficient    pam_sss.so
session   required      pam_unix.so
```

---

### 3.3 System Security Services Daemon (`/etc/sssd/sssd.conf`) & NSS (`/etc/nsswitch.conf`)

#### SSSD Engine Configuration (`/etc/sssd/sssd.conf`)

```ini
# /etc/sssd/sssd.conf - System Security Services Daemon Configuration
[sssd]
config_file_version = 2
services = nss, pam, sudo
domains = PROD_LDAP

[nss]
homedir_substring = /home/%u
filter_groups = root
filter_users = root,daemon,bin,sys,sync,games,man,lp,mail,news,uucp,proxy,www-data,backup,list,irc,gnats,nobody,systemd-network

[pam]
pam_verbosity = 3
pam_id_timeout = 5
pam_pwd_expiration_warning = 7

[domain/PROD_LDAP]
id_provider = ldap
auth_provider = ldap
chpass_provider = ldap
sudo_provider = ldap

# LDAP Server Topology & Failover Array
ldap_uri = ldaps://ldap-primary.infrastructure.internal:636, ldaps://ldap-secondary.infrastructure.internal:636
ldap_search_base = dc=prod,dc=infrastructure,dc=internal
ldap_schema = rfc2307bis

# Bind Credentials & TLS Hardening
ldap_default_bind_dn = cn=sssd-service-account,ou=Services,dc=prod,dc=infrastructure,dc=internal
ldap_default_authtok_type = obfuscated_password
ldap_default_authtok = AAAQAK7Z0q0sX+v9vL1KqJ3+5Z67A9zT6Q0vY8Z8A3nK8vX1...

ldap_id_use_starttls = false
ldap_tls_cacert = /etc/ssl/certs/Internal_CA_Root.pem
ldap_tls_reqcert = hard
ldap_tls_cipher_suite = HIGH:!aNULL:!MD5:!RC4

# POSIX Schema Mapping Rules
ldap_user_object_class = posixAccount
ldap_user_name = uid
ldap_user_uid_number = uidNumber
ldap_user_gid_number = gidNumber
ldap_user_home_directory = homeDirectory
ldap_user_shell = loginShell

ldap_group_object_class = posixGroup
ldap_group_name = cn
ldap_group_gid_number = gidNumber
ldap_group_member = member

# Offline Cache Tuning & Operational Resiliency
cache_credentials = true
account_cache_expiration = 7
entry_cache_timeout = 5400
refresh_expired_interval = 3600
offline_credentials_expiration = 14
```

#### Name Service Switch Configuration (`/etc/nsswitch.conf`)

```ini
# /etc/nsswitch.conf - Name Service Switch System Engine Configuration
passwd:         files sss
group:          files sss
shadow:         files sss
gshadow:        files

hosts:          files dns myhostname
networks:       files

protocols:      db files
services:       db files sss
ethers:         db files
rpc:            db files

sudoers:        files sss
```

---

### 3.4 OpenLDAP Dynamic Configuration (`cn=config` / OLC) LDIF Stream

This LDIF manifest provisions the LMDB database backend, TLS certificates, indexes, and Access Control Lists (ACLs) via On-Line Configuration (OLC).

```ldif
# /tmp/openldap-init-config.ldif - OpenLDAP OLC cn=config Bootstrap Manifest

# 1. Global TLS Engine Configuration
dn: cn=config
changetype: modify
replace: olcTLSCertificateFile
olcTLSCertificateFile: /etc/ldap/certs/ldap-server.crt
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: /etc/ldap/certs/ldap-server.key
-
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: /etc/ldap/certs/ca-root.crt
-
replace: olcTLSVerifyClient
olcTLSVerifyClient: demand
-
replace: olcSecurity
olcSecurity: tls=1

# 2. Instantiate MDB Storage Engine Module
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: back_mdb.ltb

# 3. Provision Production Database Context (dc=prod,dc=infrastructure,dc=internal)
dn: olcDatabase={1}mdb,cn=config
changetype: add
objectClass: olcDatabaseConfig
objectClass: olcMdbConfig
olcDatabase: {1}mdb
olcSuffix: dc=prod,dc=infrastructure,dc=internal
olcRootDN: cn=admin,dc=prod,dc=infrastructure,dc=internal
olcRootPW: {SSHA}vJ7zN9wZ4Y+L6P8x3K2mQ1vT8R5a7B9c
olcDbDirectory: /var/lib/ldap
olcDbMaxSize: 107374182400
olcDbIndex: objectClass eq
olcDbIndex: uid eq,sub
olcDbIndex: uidNumber eq
olcDbIndex: gidNumber eq
olcDbIndex: member eq,sub
olcDbIndex: entryCSN,entryUUID eq

# 4. Strict Security Access Control Lists (ACLs)
olcAccess: {0}to attrs=userPassword,shadowLastChange
  by self write
  by anonymous auth
  by dn.exact="cn=admin,dc=prod,dc=infrastructure,dc=internal" write
  by * none
olcAccess: {1}to attrs=shadowExpire,shadowInactive,shadowWarning
  by self read
  by dn.exact="cn=admin,dc=prod,dc=infrastructure,dc=internal" write
  by * none
olcAccess: {2}to dn.base="" by * read
olcAccess: {3}to *
  by self write
  by dn.exact="cn=admin,dc=prod,dc=infrastructure,dc=internal" write
  by dn.exact="cn=sssd-service-account,ou=Services,dc=prod,dc=infrastructure,dc=internal" read
  by * read
```

---

## 4. CLI Commands & Terminal Output Transcripts

### 4.1 DHCP Server Lifecycle Management & Lease Inspection

#### Step 1: Validate DHCP Server Syntax
```bash
$ sudo dhcpd -t -cf /etc/dhcp/dhcpd.conf
```
```text
Internet Systems Consortium DHCP Server 4.4.1
Copyright 2004-2018 Internet Systems Consortium.
All rights reserved.
For info, please visit https://www.isc.org/software/dhcp/
Config file: /etc/dhcp/dhcpd.conf
Database file: /var/lib/dhcp/dhcpd.leases
PID file: /var/run/dhcpd.pid
Source compiled in DEFAULT feature set.
Syntax check exit status status 0: success.
```

#### Step 2: Query Active Server Leases File
```bash
$ sudo tail -n 25 /var/lib/dhcp/dhcpd.leases
```
```text
lease 10.100.8.45 {
  starts 4 2026/08/06 12:00:00;
  ends 5 2026/08/07 12:00:00;
  tstp 5 2026/08/07 12:00:00;
  cltt 4 2026/08/06 12:00:00;
  binding state active;
  next binding state free;
  rewind binding state free;
  hardware ethernet 52:54:00:12:34:56;
  uid "\001R\254\000\0224V";
  client-hostname "k8s-worker-node-12";
}
```

#### Step 3: Monitor DHCP Client Interaction (`dhclient`)
```bash
$ sudo dhclient -v -4 -pf /var/run/dhclient.eth0.pid -lf /var/lib/dhcp/dhclient.eth0.leases eth0
```
```text
Internet Systems Consortium DHCP Client 4.4.1
Listening on LPF/eth0/52:54:00:12:34:56
Sending on   LPF/eth0/52:54:00:12:34:56
Sending on   Socket/fallback
DHCPDISCOVER on eth0 to 255.255.255.255 port 67 interval 3 (xid=0x4f82a1b9)
DHCPOFFER of 10.100.8.45 from 10.100.0.2
DHCPREQUEST for 10.100.8.45 on eth0 to 255.255.255.255 port 67 (xid=0x4f82a1b9)
DHCPACK of 10.100.8.45 from 10.100.0.2 (xid=0x4f82a1b9)
bound to 10.100.8.45 -- renewal in 38452 seconds.
```

---

### 4.2 PAM Stack Testing & Account Locking (`faillock` / `pamtester`)

#### Step 1: Validate Authentication Stack via `pamtester`
```bash
$ sudo pamtester sshd devops-user authenticate
```
```text
Password: 
pamtester: successfully authenticated
```

#### Step 2: Inspect Account Lockout State Engine (`faillock`)
```bash
$ sudo faillock --user devops-user
```
```text
devops-user:
When                Type  Source            Valid
2026-08-06 14:10:02 RHOST 192.168.1.100     V
2026-08-06 14:10:05 RHOST 192.168.1.100     V
2026-08-06 14:10:08 RHOST 192.168.1.100     V
2026-08-06 14:10:11 RHOST 192.168.1.100     V
2026-08-06 14:10:14 RHOST 192.168.1.100     V
```

#### Step 3: Clear Locked Account Status
```bash
$ sudo faillock --user devops-user --reset
```
```text
devops-user:
When                Type  Source            Valid
```

---

### 4.3 SSSD Operational Audit & Identity Resolution

#### Step 1: Check SSSD Domain Status & Backend Connectivity
```bash
$ sssctl domain-status PROD_LDAP
```
```text
Online status: Online

Active servers:
LDAP: ldap-primary.infrastructure.internal

Discovered servers:
- ldap-primary.infrastructure.internal
- ldap-secondary.infrastructure.internal
```

#### Step 2: Validate System POSIX Resolution via NSS Switch
```bash
$ getent passwd devops-user
```
```text
devops-user:x:10052:10000:DevOps SRE Engineer:/home/devops-user:/bin/bash
```

#### Step 3: Run Interactive User Access Check via `sssctl`
```bash
$ sssctl user-checks -s sshd devops-user
```
```text
user-checks -s sshd devops-user

pam_start: success
pam_authenticate: success
pam_acct_mgmt: success
pam_setcred: success
pam_open_session: success
pam_close_session: success
```

---

### 4.4 OpenLDAP Directory Administration & Operational Tooling

#### Step 1: Validate OpenLDAP OLC Configuration Directory Structure
```bash
$ sudo slaptest -F /etc/ldap/slapd.d -v
```
```text
config file testing succeeded
```

#### Step 2: Dump Direct Database Records using Low-Level Engine Utility (`slapcat`)
```bash
$ sudo slapcat -n 1 -b "dc=prod,dc=infrastructure,dc=internal" -a "(uid=devops-user)"
```
```text
dn: uid=devops-user,ou=People,dc=prod,dc=infrastructure,dc=internal
objectClass: top
objectClass: person
objectClass: organizationalPerson
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
cn: DevOps SRE Engineer
sn: Engineer
givenName: DevOps
uid: devops-user
uidNumber: 10052
gidNumber: 10000
homeDirectory: /home/devops-user
loginShell: /bin/bash
mail: devops-user@infrastructure.internal
userPassword:: e1NTSEF9dlo3ek45d1o0WStMNlA4eDNLMm1RMXZUOFI1YTdCOWM=
structuralObjectClass: inetOrgPerson
entryUUID: 4a3e8b0a-3c12-103b-8f12-00163e4a9b12
creatorsName: cn=admin,dc=prod,dc=infrastructure,dc=internal
createTimestamp: 20260801083000Z
entryCSN: 20260801083000.000000Z#000000#000#000000
modifiersName: cn=admin,dc=prod,dc=infrastructure,dc=internal
modifyTimestamp: 20260801083000Z
```

#### Step 3: Query Directory Information Tree (DIT) via Client Utility over TLS
```bash
$ ldapsearch -x -ZZ -H ldap://ldap-primary.infrastructure.internal -D "cn=sssd-service-account,ou=Services,dc=prod,dc=infrastructure,dc=internal" -w "SecretPass123" -b "ou=People,dc=prod,dc=infrastructure,dc=internal" "(objectClass=posixAccount)" uid uidNumber gidNumber
```
```text
# extended LDIF
#
# LDAPv3
# base <ou=People,dc=prod,dc=infrastructure,dc=internal> with scope subtree
# filter: (objectClass=posixAccount)
# requesting: uid uidNumber gidNumber 
#

# devops-user, People, prod.infrastructure.internal
dn: uid=devops-user,ou=People,dc=prod,dc=infrastructure,dc=internal
uid: devops-user
uidNumber: 10052
gidNumber: 10000

# search result
search: 3
result: 0 Success

# numResponses: 2
# numEntries: 1
```

---

## 5. Verification & Failure Diagnostics Guide

### 5.1 Systematic Troubleshooting Flowchart

```
                 +-----------------------------------+
                 | Production Authentication /       |
                 | Provisioning Incident Triggered    |
                 +-----------------------------------+
                                   |
                                   v
             /-------------------------------------------\
            /  Is the failure related to Network Boot/    \
           <   IP Addressing (DHCP) or Identity/Auth      >
            \  (PAM / SSSD / LDAP)?                       /
             \-------------------------------------------/
                  /                             \
     DHCP / IPAM /                               \ Auth / LDAP
                /                                 \
               v                                   v
+-----------------------------+     +-----------------------------+
| 1. Run tcpdump on UDP 67/68 |     | 1. Test local resolution    |
| 2. Check Relay Options 82   |     |    'getent passwd <user>'   |
| 3. Validate dhcpd syntax    |     | 2. Audit SSSD Cache State   |
| 4. Inspect failover state   |     |    'sssctl domain-status'   |
+-----------------------------+     +-----------------------------+
               |                                   |
               v                                   v
+-----------------------------+     +-----------------------------+
| Check dhcpd.leases state    |     | Test direct LDAP TLS bind   |
| Verify subnet availability  |     | 'ldapsearch -x -ZZ ...'     |
+-----------------------------+     +-----------------------------+
                                                   |
                                                   v
                                    +-----------------------------+
                                    | Audit PAM Execution Flow    |
                                    | Set pam_debug.so /          |
                                    | Check /var/log/auth.log     |
                                    +-----------------------------+
```

---

### 5.2 Deep-Dive Diagnostic Matrix

| Failure Mode | Root Cause Hypothesis | Empirical Verification Method | Mitigation Step |
| :--- | :--- | :--- | :--- |
| **DHCP Client stuck in `DHCPDISCOVER`** | L2 Broadcast isolation or DHCP Relay (`dhcrelay`) failure | Run packet capture:<br>`sudo tcpdump -i eth0 -n "port 67 or port 68"` | Verify L2 VLAN tagging / Configure DHCP Relay Agent on router interface |
| **DHCP Failover Out of Sync** | Clock drift between HA peers or state mismatch | Inspect server logs:<br>`grep -i "failover peer" /var/log/syslog` | Synchronize NTP clocks (`chronyc tracking`) and force state sync |
| **`getent` resolves user, but SSH fails** | PAM module chain ordering failure or `faillock` restriction | Inspect PAM log:<br>`journalctl -u sshd -e --no-pager`<br>Check lockouts: `faillock --user <id>` | Re-order `/etc/pam.d/sshd` to execute `pam_faillock` and `pam_sss` correctly |
| **SSSD failing to authenticate users offline** | `cache_credentials = false` or corrupted LDB storage | Check SSSD cache status:<br>`sudo ls -la /var/lib/sss/db/`<br>Run `sssctl domain-status` | Enable `cache_credentials = true` or clear corrupted cache using `sss_cache -E` |
| **OpenLDAP `ldapsearch` TLS handshake failure** | CA certificate mismatch or hostname mismatch in TLS cert | Execute debug search:<br>`LDAPTLS_CACERT=/etc/ssl/certs/ca.pem ldapsearch -d 1 -x -ZZ -H ldap://...` | Match client `TLS_CACERT` path in `/etc/openldap/ldap.conf` with Server CA |
| **OpenLDAP database write block** | LMDB `olcDbMaxSize` limit reached or disk full | Run `slapcat` and check log:<br>`grep -i "MDB_MAP_FULL" /var/log/syslog` | Update `cn=config` with LDIF extending `olcDbMaxSize` |

---

### 5.3 Step-by-Step Diagnostic Commands

#### 1. Low-Level Packet Capture for DHCP Lifecycle Verification
```bash
$ sudo tcpdump -i eth0 -vvv -s 1500 -n "port 67 or port 68"
```

#### 2. OpenLDAP High-Verbosity Diagnostic Execution
Start OpenLDAP daemon in foreground with trace logging for ACLs, Search Filters, and Configuration processing (Level 256 + 128 + 512 = 896):
```bash
$ sudo slapd -d 896 -F /etc/ldap/slapd.d -h "ldaps:///"
```

#### 3. Complete Reset and Re-index of SSSD Security Caches
If SSSD yields stale attributes or broken database bindings:
```bash
$ sudo systemctl stop sssd
$ sudo sss_cache -E
$ sudo rm -f /var/lib/sss/db/*.ldb
$ sudo systemctl start sssd
$ sssctl domain-status PROD_LDAP
```

---

## 6. References

- [Linux Professional Institute (LPI) LPIC-2 Exam 202-450 Objectives](https://www.lpi.org/our-certifications/lpic-2-overview/)
- [OpenLDAP Software 2.6 Administrator's Guide (On-Line Configuration - cn=config)](https://www.openldap.org/doc/admin26/slapdconf2.html)
- [System Security Services Daemon (SSSD) Documentation](https://sssd.io/documentation/index.html)
- [ISC DHCP Reference Manual & Failover Protocol Architecture](https://www.isc.org/dhcp/)
- [Linux PAM Architecture & Module Specifications](https://github.com/linux-pam/linux-pam)
- [RFC 2131: Dynamic Host Configuration Protocol](https://datatracker.ietf.org/doc/html/rfc2131)
- [RFC 4511: Lightweight Directory Access Protocol (LDAP): The Protocol](https://datatracker.ietf.org/doc/html/rfc4511)