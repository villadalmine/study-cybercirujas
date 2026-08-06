# LPIC-3 Exam 300-300 (v3.0) | Topic 305: Linux Identity Management and File Sharing

---

## 1. Architectural Motivation & Production Problem Statement

In modern heterogeneous enterprise environments, managing identity, authentication, access control, and network storage at scale introduces significant operational friction. Historical approaches—such as local `/etc/passwd` synchronization via Configuration Management Systems (Ansible/Puppet), standalone OpenLDAP instances, or fragmented Samba deployments—fail to meet zero-trust security compliance, high availability (HA) SLAs, and seamless Cross-Realm interoperability with Active Directory (AD).

```
                      +---------------------------------------------------+
                      |      FreeIPA / Red Hat IdM Domain Realm           |
                      |  (MIT Kerberos KDC + 389 Directory Server + CA)   |
                      +-------------------------+-------------------------+
                                                |
               +--------------------------------+--------------------------------+
               | (389-DS Multi-Master Replication)                               | (Kerberos Cross-Realm Trust)
               v                                                                 v
+-----------------------------+                                   +-----------------------------+
|    FreeIPA Replica Server   |                                   |  Microsoft Active Directory |
| (KDC + Directory Server+PKI)|                                   |       Forest (AD DS)        |
+--------------+--------------+                                   +--------------+--------------+
               |                                                                 |
               +-------------------------------+---------------------------------+
                                               |
                                               v
                        +-----------------------------------------------+
                        |        SSSD (System Security Services Daemon)  |
                        |      (Local Cache + ID Mapping + PAM/NSS)     |
                        +----------------------+------------------------+
                                               |
                                               v
                        +-----------------------------------------------+
                        | Secure Network File System (NFSv4.2) Server   |
                        |  (RPCSEC_GSS / Kerberos sec=krb5p Protection)  |
                        +-----------------------------------------------+
```

### Key Architectural Challenges

1. **Centralized Identity & Single Sign-On (SSO):** Operating thousands of Linux nodes requires a unified domain controller combining LDAP directory services (389 Directory Server), MIT Kerberos V5 for ticket-based SSO, Dogtag PKI for automated X.509 certificate management, and Integrated BIND DNS for service location (`SRV` records).
2. **High Availability and Replication Mechanics:** FreeIPA employs 389 Directory Server's Multi-Master Replication (MMR) engine using Changelog plugins and fractional replication. High Availability requires topology design where Kerberos principal updates and LDAP schema mutations replicate asynchronously with conflict resolution governed by CSN (Change Sequence Numbers).
3. **Kerberized Storage Authorization (NFSv4.2 & RPCSEC_GSS):** Legacy NFS (`sec=sys`) relies on client-side UID/GID trust over unencrypted channels, vulnerable to IP spoofing and privilege escalation. Production environments require **RPCSEC_GSS** (RFC 2203) integrated with Kerberos V5 (`sec=krb5p`), enforcing per-packet cryptographically signed payloads, AES-256 CTS HMAC SHA1 encryption, and server-side UID translation via `idmapd` / SSSD.
4. **Cross-Realm Identity Federation:** Enterprise infrastructures often maintain Active Directory as the authoritative identity provider (IdP). FreeIPA addresses this without modifying AD schema by establishing a **Kerberos 5 Cross-Realm Forest Trust** leveraging SSSD's `idmap_sssd` plugin to dynamically map Active Directory Security Identifiers (SIDs) into Linux POSIX UIDs/GIDs using deterministic algorithmic hashing.

---

## 2. Technical Comparisons & Trade-off Analysis

### 2.1 Identity Management Architecture Comparison

| Feature / Metric | FreeIPA / Red Hat IdM | SSSD Direct Join to AD | Legacy OpenLDAP + Kerberos | Samba Winbind |
| :--- | :--- | :--- | :--- | :--- |
| **Primary Domain Controller** | Yes (MIT KDC + 389-DS) | No (Relies on AD DC) | Manual Integration | Yes (Samba AD DC) |
| **POSIX Attribute Storage** | Native in FreeIPA LDAP | Computed locally via SSSD or read from AD | Native in LDAP | Calculated from SID |
| **Active Directory Integration** | Native Cross-Realm Forest Trust | Direct Kerberos/LDAP Domain Join | Manual Trust Configuration | Join to AD Domain |
| **PKI / Certificate Management** | Integrated Dogtag CA / ACME | External (Microsoft CA / Cert-Manager) | Manual OpenSSL/Vault setup | External |
| **HBAC / Sudo Management** | Native Centralized HBAC & Sudo Rules | Limited to AD Group Policy / Local Sudo | Custom LDAP Schemas | Local Sudoers / GPO |
| **Operational Overhead** | Moderate (Dedicated Linux Domain) | Low (No Linux DC infrastructure) | Very High (Custom schema/wiring) | High (SMB Protocol complexity) |

### 2.2 NFSv4 Security Flavors Comparison

| Security Flavor | Authentication | Integrity Protection | Payload Encryption | Performance Impact | Threat Protection |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `sec=sys` | Client-asserted UID/GID | None | None | 0% Overhead | None (Vulnerable to IP/UID spoofing) |
| `sec=krb5` | Kerberos V5 Ticket | None | None | Low (Initial Handshake only) | Protects against unauthenticated users |
| `sec=krb5i` | Kerberos V5 Ticket | HMAC-SHA1 Cryptographic Hash | None | Moderate (Checksum calculation per packet) | Prevents Man-in-the-Middle (MitM) tampering |
| `sec=krb5p` | Kerberos V5 Ticket | HMAC-SHA1 Cryptographic Hash | AES-256-CTS Payload Encryption | High (Cryptographic overhead per I/O) | Complete confidentiality and integrity |

### 2.3 Cross-Realm Trust Models

| Dimension | FreeIPA-to-AD Forest Trust | Active Directory Sync (WinSync) | Direct AD Join via SSSD |
| :--- | :--- | :--- | :--- |
| **Trust Topology** | Transitive 2-way or 1-way Forest Trust | Polling-based Account Synchronization | Client-to-AD direct binding |
| **Kerberos Mechanics** | KDC cross-realm referral ticket issuing | Local principal mapping after account copy | Native AD Ticket Granting Ticket (TGT) |
| **Kerberos Transitivity** | Supported across domains | Not applicable | Handled directly by AD DCs |
| **Schema Alterations** | Zero changes required on AD DCs | Requires POSIX schema extensions in AD | Optional (Supports Algorithmic Mapping) |
| **Failure Isolation** | High (FreeIPA operational if AD links drop) | Low (Password hashes out of sync on failure)| Medium (Local cache handles outages) |

---

## 3. Production Infrastructure & Syntactically Valid Manifests

### 3.1 Automated Deployment: Ansible Playbook for FreeIPA Master Server

```yaml
---
- name: Deploy Production FreeIPA Master Domain Controller
  hosts: ipa_masters
  become: true
  vars:
    ipaserver_domain: infra.internal
    ipaserver_realm: INFRA.INTERNAL
    ipaserver_server_fqdn: idm01.infra.internal
    ipaserver_ip_addresses:
      - 10.100.10.5
    ipaserver_setup_dns: true
    ipaserver_auto_forwarders: true
    ipaserver_forwarders:
      - 10.100.0.2
      - 10.100.0.3
    ipapassword: "VaultSecureAdminPassword123!"
    ipadm_password: "VaultSecureDSManagerPassword123!"
  collections:
    - freeipa.ansible_freeipa
  tasks:
    - name: Ensure Hostname matches FQDN
      ansible.builtin.hostname:
        name: "{{ ipaserver_server_fqdn }}"

    - name: Configure Firewall Rules for FreeIPA Topology
      ansible.posix.firewalld:
        service: "{{ item }}"
        state: enabled
        permanent: true
        immediate: true
      loop:
        - freeipa-ldap
        - freeipa-ldaps
        - dns
        - ntp
        - krb5

    - name: Install FreeIPA Server Package Suite
      ansible.builtin.package:
        name:
          - freeipa-server
          - freeipa-server-dns
          - freeipa-server-trust-ad
        state: present

    - name: Run FreeIPA Server Installation
      include_role:
        name: ipaserver
```

---

### 3.2 Enterprise SSSD Client Configuration (`/etc/sssd/sssd.conf`)

```ini
[sssd]
services = nss, pam, sudo, ssh
config_file_version = 2
domains = infra.internal

[domain/infra.internal]
id_provider = ipa
auth_provider = ipa
access_provider = ipa
chpass_provider = ipa
ipa_server = _srv_, idm01.infra.internal, idm02.infra.internal
ipa_domain = infra.internal
ipa_hostname = app01.infra.internal
krb5_realm = INFRA.INTERNAL

# Security Hardening & Performance Optimizations
cache_credentials = True
entry_cache_timeout = 600
entry_cache_nowait_percentage = 50
krb5_store_password_if_offline = True
ssl_default_verify_scheme = ipa

# Dynamic ID Mapping Configuration for AD Cross-Realm Trust
ldap_id_mapping = True
ldap_idmap_range_min = 200000
ldap_idmap_range_max = 200000000
ldap_idmap_range_size = 200000
ldap_idmap_default_domain_sid = S-1-5-21-3623811015-3361044348-30300820
ldap_idmap_autorid_compatibility = True

# SSSD Sudo Integration
sudo_provider = ipa
ipa_automated_backup_server = True
```

---

### 3.3 Production Kerberos v5 Client Configuration (`/etc/krb5.conf`)

```ini
[libdefaults]
    default_realm = INFRA.INTERNAL
    dns_lookup_realm = true
    dns_lookup_kdc = true
    rdns = false
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true
    udp_preference_limit = 0
    default_tkt_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
    default_tgs_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
    permitted_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96

[realms]
    INFRA.INTERNAL = {
        kdc = idm01.infra.internal:88
        kdc = idm02.infra.internal:88
        master_kdc = idm01.infra.internal:88
        admin_server = idm01.infra.internal:749
        default_domain = infra.internal
        pkinit_anchors = FILE:/etc/ipa/ca.crt
    }

[domain_realm]
    .infra.internal = INFRA.INTERNAL
    infra.internal = INFRA.INTERNAL

[plugins]
    certauth = {
        module = ipa:/usr/lib64/sssd/modules/sssd_krb5_localauth_plugin.so
    }
```

---

### 3.4 Production NFSv4.2 Kerberized Export (`/etc/exports` & `/etc/idmapd.conf`)

#### Server Side: `/etc/exports`
```
/exports/production_storage  *.infra.internal(rw,sync,no_subtree_check,sec=krb5p:krb5i:krb5,root_squash)
```

#### NFS ID Mapping Configuration: `/etc/idmapd.conf`
```ini
[General]
Verbosity = 2
Pipefs-Directory = /var/lib/nfs/rpc_pipefs
Domain = infra.internal

[Mapping]
Nobody-User = nobody
Nobody-Group = nobody

[Translation]
Method = sssd
```

---

## 4. Real CLI Commands & Terminal Execution Logs

### 4.1 Initializing FreeIPA Domain Controller

```bash
$ sudo ipa-server-install \
    --realm=INFRA.INTERNAL \
    --domain=infra.internal \
    --ds-password="VaultSecureDSManagerPassword123!" \
    --admin-password="VaultSecureAdminPassword123!" \
    --setup-dns \
    --forwarder=10.100.0.2 \
    --no-ntp \
    --unattended
```

```output
The log file for this installation can be found in /var/log/ipaserver-install.log
==============================================================================
This program will set up the FreeIPA Server.
Directory Manager password defined
IPA admin password defined

Installing Directory Server (389-DS)
  [1/8]: creating directory server instance
  [2/8]: configuring certmonger
  [3/8]: setting up initial data
  [4/8]: configuring SSL for directory server
  [5/8]: configuring replication version plugin
  [6/8]: enabling IPA plugin
  [7/8]: configuring schema extensions
  [8/8]: starting directory server instance
Done configuring Directory Server.

Configuring Kerberos KDC (MIT Kerberos)
  [1/7]: adding kerberos principal entries
  [2/7]: configuring KDC
  [3/7]: starting KDC
  [4/7]: configuring admin service
  [5/7]: starting admin service
  [6/7]: creating Master key
  [7/7]: initializing account lockout policy
Done configuring Kerberos KDC.

Setup complete of FreeIPA Server version 4.10.2!
```

---

### 4.2 Entity Management via `ipa` CLI

#### Authenticate Admin Principal
```bash
$ kinit admin
```
```output
Password for admin@INFRA.INTERNAL: 
```

```bash
$ klist
```
```output
Ticket cache: KCM:0:19284
Default principal: admin@INFRA.INTERNAL

Valid starting       Expires              Service principal
08/06/26 13:00:01  08/07/26 13:00:01  krbtgt/INFRA.INTERNAL@INFRA.INTERNAL
	renew until 08/13/26 13:00:01
```

#### Create User, Group, and Host Entities
```bash
$ ipa user-add sre_developer --first="SRE" --last="Engineer" --password
```
```output
Password: 
Enter Password again to verify: 
---------------------------------
Added user "sre_developer"
---------------------------------
  User login: sre_developer
  First name: SRE
  Last name: Engineer
  Full name: SRE Engineer
  Home directory: /home/sre_developer
  GECOS: SRE Engineer
  Login shell: /bin/bash
  Principal name: sre_developer@INFRA.INTERNAL
  Principal alias: sre_developer@INFRA.INTERNAL
  UID: 754200001
  GID: 754200001
```

```bash
$ ipa group-add devops_team --desc="DevOps SRE Core Team"
```
```output
----------------------------
Added group "devops_team"
----------------------------
  Group name: devops_team
  Description: DevOps SRE Core Team
  GID: 754200002
```

```bash
$ ipa group-add-member devops_team --users=sre_developer
```
```output
  Group name: devops_team
  Description: DevOps SRE Core Team
  GID: 754200002
  Member users: sre_developer
-------------------------
Number of members added 1
-------------------------
```

#### Provision NFS Service Principal and Issue Keytab
```bash
$ ipa service-add nfs/nfs-server.infra.internal
```
```output
-------------------------------------------------------------------
Added service "nfs/nfs-server.infra.internal@INFRA.INTERNAL"
-------------------------------------------------------------------
  Principal name: nfs/nfs-server.infra.internal@INFRA.INTERNAL
  Principal alias: nfs/nfs-server.infra.internal@INFRA.INTERNAL
  Managed by: nfs-server.infra.internal
```

```bash
$ sudo ipa-getkeytab \
    -p nfs/nfs-server.infra.internal@INFRA.INTERNAL \
    -k /etc/krb5.keytab
```
```output
Keytab successfully retrieved and stored in: /etc/krb5.keytab
```

```bash
$ sudo ktutil
```
```output
ktutil:  read_kt /etc/krb5.keytab
ktutil:  list
slot KVNO Principal
---- ---- ---------------------------------------------------------------------
   1    1 nfs/nfs-server.infra.internal@INFRA.INTERNAL
   2    1 nfs/nfs-server.infra.internal@INFRA.INTERNAL
```

---

### 4.3 Active Directory Cross-Realm Trust Setup

```bash
$ sudo ipa-adtrust-install \
    --netbios-name=INFRA \
    --add-sids \
    --unattended
```
```output
Configuring CIFS Services...
  [1/4]: setting up CIFS configuration
  [2/4]: adding admin principal to Samba keytab
  [3/4]: starting Samba service (smb)
  [4/4]: starting Winbind service (winbind)
Done configuring CIFS Services.
IPA AD Trust installation successful.
```

```bash
$ ipa trust-add \
    --type=ad corporate.local \
    --admin Administrator \
    --password
```
```output
Active Directory domain administrator's password: 
--------------------------------------------------
Added Active Directory trust for "corporate.local"
--------------------------------------------------
  Realm name: corporate.local
  Domain netbios name: CORPORATE
  Domain Security Identifier: S-1-5-21-3623811015-3361044348-30300820
  Trust type: Active Directory domain
  Trust direction: Two-way trust
```

---

### 4.4 Mount Kerberized NFS Share on Client

```bash
$ sudo mount -t nfs4 -o sec=krb5p idm01.infra.internal:/exports/production_storage /mnt/secure_data
```

```bash
$ df -T -h /mnt/secure_data
```
```output
Filesystem                                    Type  Size  Used Avail Use% Mounted on
idm01.infra.internal:/exports/production_storage nfs4   500G   45G  456G  10% /mnt/secure_data
```

```bash
$ mount | grep secure_data
```
```output
idm01.infra.internal:/exports/production_storage on /mnt/secure_data type nfs4 (rw,relatime,vers=4.2,rsize=1048576,wsize=1048576,namlen=255,hard,proto=tcp,timeo=600,retrans=2,sec=krb5p,clientaddr=10.100.10.12,local_lock=none,addr=10.100.10.5)
```

---

## 5. Verification, Production Diagnostics & Troubleshooting Guide

### 5.1 System Matrix: Failure Modes and Remediation

```
+------------------------------------+------------------------------------+------------------------------------+
| Symptom / Error                    | Root Cause                         | Diagnostic Command & Fix           |
+------------------------------------+------------------------------------+------------------------------------+
| kinit: Clock skew too great        | NTP drift between client and KDC   | chronyc tracking                   |
| (Error 37)                         | exceeds 300 seconds default.       | chronyc -a makestep                |
+------------------------------------+------------------------------------+------------------------------------+
| NFS mount hangs or gives           | Service principal missing in       | klist -k /etc/krb5.keytab          |
| "Permission Denied" (sec=krb5p)    | keytab or GSSProxy inactive.       | systemctl restart gssproxy         |
+------------------------------------+------------------------------------+------------------------------------+
| Files owned by nobody:nobody       | Domain mismatch in idmapd.conf     | nfsidmap -c                        |
| on NFSv4 volume                    | or SSSD NSS mapping failed.        | sssctl domain-status               |
+------------------------------------+------------------------------------+------------------------------------+
| ipa trust-add fails with           | DNS SRV record lookup for AD       | dig SRV _ldap._tcp.corporate.local |
| "Active Directory domain unreachable" DC failed over DNS topology. | verify named forwarding rules.     |
+------------------------------------+------------------------------------+------------------------------------+
```

---

### 5.2 Deep-Dive SSSD Diagnostics

#### Enable Debugging in `/etc/sssd/sssd.conf`
```ini
[domain/infra.internal]
debug_level = 9
```

#### Diagnostic Execution Sequence
```bash
$ sudo systemctl restart sssd
$ sudo sssctl domain-status infra.internal
```
```output
Online status: Online

Active servers:
IPA: idm01.infra.internal

Discovered servers:
- idm01.infra.internal
- idm02.infra.internal
```

```bash
$ sudo sssctl user-checks sre_developer
```
```output
user-checks requested for user sre_developer
sssd_nss user lookup result:
  Username: sre_developer
  UID: 754200001
  GID: 754200001
  Home directory: /home/sre_developer
  Shell: /bin/bash

pam_acct_mgmt result for account sre_developer: Success
```

#### Inspect Live Log Streams
```bash
$ sudo tail -n 25 /var/log/sssd/sssd_infra.internal.log
```
```output
(2026-08-06 13:15:02): [sssd[be[infra.internal]]] [be_get_account_info] (0x0200): Got request for [0x1][BE_REQ_USER][1][name=sre_developer]
(2026-08-06 13:15:02): [sssd[be[infra.internal]]] [sdap_get_users_send] (0x0400): Requesting info for user sre_developer from LDAP
(2026-08-06 13:15:02): [sssd[be[infra.internal]]] [sdap_get_generic_ext_step] (0x0400): calling ldap_search_ext with [(&(uid=sre_developer)(objectClass=posixAccount))]
(2026-08-06 13:15:02): [sssd[be[infra.internal]]] [sdap_save_user] (0x0400): Save user entry: sre_developer
```

---

### 5.3 Kerberos Tracing & GSS-API Debugging

#### Tracing Kerberos Handshakes
Set the `KRB5_TRACE` variable to intercept API calls directly:

```bash
$ env KRB5_TRACE=/dev/stdout kinit sre_developer
```
```output
[19302] 1786036502.12000: Getting initial tickets for sre_developer@INFRA.INTERNAL
[19302] 1786036502.12001: Sending request (182 bytes) to INFRA.INTERNAL
[19302] 1786036502.12002: Resolving KDC hostname idm01.infra.internal
[19302] 1786036502.12003: Initiating TCP connection to 10.100.10.5:88
[19302] 1786036502.12004: Received answer (1520 bytes) from 10.100.10.5:88
[19302] 1786036502.12005: Selected etype aes256-cts-hmac-sha1-96
[19302] 1786036502.12006: PKINIT client has no configured anchors
[19302] 1786036502.12007: AS key verified successfully
[19302] 1786036502.12008: Storing krbtgt/INFRA.INTERNAL@INFRA.INTERNAL in KCM:0:19284
```

---

### 5.4 Directory Server Replication Topology Verification

Check multi-master agreement state across domain controllers:

```bash
$ sudo ipa-replica-manage list-help idm01.infra.internal
```
```bash
$ sudo ipa-replica-manage list idm01.infra.internal
```
```output
idm02.infra.internal: replica
```

```bash
$ sudo ipa-replica-manage force-sync --from idm02.infra.internal
```
```output
Directory Manager password: 
Endpoint idm02.infra.internal updated successfully.
```

```bash
$ sudo tail -n 20 /var/log/dirsrv/slapd-INFRA-INTERNAL/errors
```
```output
[06/Aug/2026:13:20:00.123456789 +0000] NSERLugin - agmt="cn=meToidm02.infra.internal,cn=replica,cn=dc\3Dinfra\2Cdc\3Dinternal,cn=mapping tree,cn=config" (idm02:389): Replication agreement is in sync.
```

---

## 6. References

- [Linux Professional Institute: LPIC-3 300 Exam Objectives](https://www.lpi.org/our-certifications/lpic-3-300-overview/)
- [FreeIPA Official Architecture & Documentation](https://www.freeipa.org/page/Documentation)
- [Red Hat Enterprise Linux Identity Management Design & Deployment](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/accessing_identity_management_services/)
- [RFC 7530: Network File System (NFS) version 4 Protocol](https://datatracker.ietf.org/doc/html/rfc7530)
- [RFC 4120: The Kerberos Network Authentication Service (V5)](https://datatracker.ietf.org/doc/html/rfc4120)
- [RFC 2203: RPCSEC_GSS Protocol Specification](https://datatracker.ietf.org/doc/html/rfc2203)
- [SSSD Project Documentation and Architecture Guides](https://sssd.io/documentation/index.html)