# LPIC-2 Exam 202-450: Topic 2.4 / 210 - Network Client Management

**Exam:** LPIC-2 (Exam 201-450 & 202-450, Version 4.5)  
**Topic 2.4 / 210:** Network Client Management  
**Exam Weight:** 8  
**Target Level:** Senior SRE / Principal Platform Architect  
**Official Reference:** [Linux Professional Institute - LPIC-2 Overview](https://www.lpi.org/our-certifications/lpic-2-overview/)

---

## Technical Overview & Architecture

Network Client Management in enterprise Linux environments establishes the foundation for automated network bootstrap, centralized identity management, and secure access enforcement. A production SRE architecture integrates four critical layers:

1. **Dynamic Addressing & Network Bootstrap (DHCP/DHCPv6 & Relay):** Automates IPv4/IPv6 address assignment, routing, and PXE boot parameters using ISC DHCP (`dhcpd`) and DHCP Relay agents (`dhcrelay`).
2. **Pluggable Authentication Modules (PAM):** Provides a modular abstraction layer (`/etc/pam.d/`) to enforce enterprise authentication pipelines, brute-force mitigation (`pam_faillock`), resource constraints (`pam_limits`), and authorization policies (`pam_wheel`).
3. **Directory Services (OpenLDAP & OLC):** Implements On-Line Configuration (`cn=config` / OLC) with Lightning Memory-Mapped Database (`mdb`) backends, fine-grained Access Control Lists (`olcAccess`), and mandatory TLS/SSL encryption.
4. **Client Identity Orchestration (SSSD & NSSwitch):** Integrates Linux clients into directory infrastructure via System Security Services Daemon (`sssd`) and Name Service Switch (`/etc/nsswitch.conf`) with offline credentials caching and high-performance identity resolution.

---

## Exercise Block 1: ISC DHCP Server, Subnet Isolation, PXE Boot, and DHCP Relay

### Architectural Mechanics & Deep-Dive

The DHCP protocol operates on a four-way handshake (**DORA**: **D**iscover, **O**ffer, **R**equest, **A**cknowledge) over UDP ports `67` (server) and `68` (client).

```
Client (Port 68)                             DHCP Relay / Server (Port 67)
       |                                                    |
       |--- DHCPDISCOVER (Broadcast 255.255.255.255) ------>|
       |<-- DHCPOFFER (Unicast/Broadcast + Offered IP) -----|
       |--- DHCPREQUEST (Broadcast + Selected IP) -------->|
       |<-- DHCPACK (Unicast/Broadcast + Lease Terms) ------|
```

When clients reside on remote subnets where UDP broadcasts cannot cross router boundaries, a **DHCP Relay Agent** (`dhcrelay`) inspects incoming `DHCPDISCOVER` packets, intercepts them at Layer 2/3, injects its own interface address into the `giaddr` (**G**ateway **I**P **A**ddress) field, and forwards the packet as a unicast payload to the central DHCP server.

In IPv6 environments, address configuration splits into:
* **Stateless Address Autoconfiguration (SLAAC):** Driven by ICMPv6 Router Advertisements (RA).
* **Stateless DHCPv6:** Router Advertisements set the **O** (Other configuration) flag to `1`, prompting clients to fetch DNS and domain settings via DHCPv6.
* **Stateful DHCPv6:** Router Advertisements set the **M** (Managed address configuration) flag to `1`, instructing clients to obtain their IPv6 address directly from the DHCPv6 daemon (`dhcpd -6`).

---

### Step-by-Step Guided Implementation

#### Step 1.1: Deploy an Enterprise ISC DHCP Configuration with Subnets and PXE Boot Options

Edit `/etc/dhcp/dhcpd.conf` to configure an authoritative DHCP server handling subnet isolation, fixed MAC reservations, and PXE boot parameters.

```dhcpd
# /etc/dhcp/dhcpd.conf
default-lease-time 86400;
max-lease-time 604800;
authoritative;

log-facility local7;

# Global Option Definitions
option domain-name "infra.production.local";
option domain-name-servers 10.100.0.10, 10.100.0.11;
option ntp-servers 10.100.0.1;

# Production Application Subnet
subnet 10.100.10.0 netmask 255.255.255.0 {
  range 10.100.10.100 10.100.10.200;
  option routers 10.100.10.1;
  option broadcast-address 10.100.10.255;

  # PXE Boot Options for Automated Deployment
  filename "pxelinux.0";
  next-server 10.100.0.50;

  # Static Host Reservation based on Hardware MAC
  host baremetal-node-01 {
    hardware ethernet 52:54:00:ab:cd:ef;
    fixed-address 10.100.10.50;
    option host-name "node01.infra.production.local";
  }
}
```

Verify syntax and start the daemon:

```bash
dhcpd -t -cf /etc/dhcp/dhcpd.conf
systemctl restart isc-dhcp-server
```

**Expected Output:**
```text
Internet Systems Consortium DHCP Server 4.4.1
Config file: /etc/dhcp/dhcpd.conf
Source file: /etc/dhcp/dhcpd.conf
Line 1: semicolon expected. (Only if syntax error exists; clean output exits with status 0)
Server starts without syntax errors.
```

#### Step 1.2: Inspect State in the DHCP Lease Database

Inspect active leases dynamically recorded in `/var/lib/dhcp/dhcpd.leases`:

```bash
cat /var/lib/dhcp/dhcpd.leases
```

**Expected Output:**
```text
lease 10.100.10.105 {
  starts 4 2026/08/06 10:00:00;
  ends 5 2026/08/07 10:00:00;
  cltt 4 2026/08/06 10:00:00;
  binding state active;
  next binding state free;
  rewind binding state free;
  hardware ethernet 52:54:00:12:34:56;
  client-hostname "worker-node-12";
}
```

#### Step 1.3: Configure a Multi-Interface DHCP Relay Agent (`dhcrelay`)

On a gateway node routing traffic between `10.100.20.0/24` (`eth1`) and the central DHCP server at `10.100.0.5` (`eth0`), launch `dhcrelay`:

```bash
dhcrelay -i eth1 -i eth0 10.100.0.5
```

Verify process runtime state:

```bash
ps aux | grep dhcrelay
```

**Expected Output:**
```text
dhcpd     14201  0.0  0.1  12456  3120 ?        Ss   10:05   0:00 dhcrelay -i eth1 -i eth0 10.100.0.5
```

#### Step 1.4: Capture and Analyze DHCP Protocol Traffic

Capture DHCP handshake frames using `tcpdump` to verify Relay Agent option injection (`giaddr`):

```bash
tcpdump -i eth0 -nn -vvv port 67 or port 68
```

**Expected Output:**
```text
10:10:01.102938 IP (tos 0x0, ttl 64, id 1202, offset 0, flags [none], proto UDP (17), length 328)
    10.100.20.1.67 > 10.100.0.5.67: [udp sum ok] BOOTP/DHCP, Request from 52:54:00:fe:dc:ba, length 300, xid 0x9a3c1f, Flags [none]
	  Gateway-IP 10.100.20.1
	  Client-Ethernet-Address 52:54:00:fe:dc:ba
	  Vendor-rfc1048 Extensions
	    Magic Cookie 0x63825363
	    DHCP-Message Option 53, length 1: Discover
	    Parameter-Request Option 55, length 4: Subnet-Mask, BR, Time-Zone, Router
```

---

### Verification Questions - Block 1

#### Question 1.1
An SRE deploys a DHCP relay agent on a router connecting Subnet A (`10.200.1.0/24`) to a centralized DHCP server on Subnet B (`10.200.2.10`). Clients on Subnet A are failing to acquire IP addresses. Inspection of the server logs shows `DHCPDISCOVER from 52:54:00:11:22:33 via eth0: network 10.200.2.0/24: no free leases`. What is the primary cause of this failure?

- A) The DHCP server requires an entry in `/etc/hosts` matching the MAC address of the DHCP relay agent.
- B) The DHCP server lacks a `subnet 10.200.1.0 netmask 255.255.255.0` declaration matching the relay agent's `giaddr` field.
- C) The DHCP relay agent failed to inject Option 82 metadata into the Ethernet frame header.
- D) The client requested a static lease via BOOTP, which overrides dynamic range processing.

#### Question 1.2
In an IPv6 auto-configuration design, an SRE needs clients to generate their own interface identifiers via SLAAC, but mandates that they query a local DHCPv6 server for DNS nameservers and domain search lists. Which configuration combination must be set on the router's ICMPv6 Router Advertisement (RA) flags?

- A) Managed Address Configuration Flag ($M$) = 1, Other Configuration Flag ($O$) = 0
- B) Managed Address Configuration Flag ($M$) = 0, Other Configuration Flag ($O$) = 1
- C) Managed Address Configuration Flag ($M$) = 1, Other Configuration Flag ($O$) = 1
- D) Managed Address Configuration Flag ($M$) = 0, Other Configuration Flag ($O$) = 0

---

## Exercise Block 2: Pluggable Authentication Modules (PAM) Architecture & Security Enforcement

### Architectural Mechanics & Deep-Dive

PAM provides modular system authentication by decoupling applications (e.g., `sshd`, `sudo`, `login`) from back-end authentication technologies (e.g., local shadow passwords, LDAP, Kerberos). PAM configuration resides under `/etc/pam.d/<service>` or `/etc/pam.conf`.

Each PAM line follows the syntax:
```text
type    control_flag    module_path    module_arguments
```

```
               +----------------------------------+
               |      Application (e.g., SSHD)    |
               +----------------------------------+
                                |
                                v
               +----------------------------------+
               |        PAM Stack Engine          |
               +----------------------------------+
                                |
        +-----------------------+-----------------------+
        |                       |                       |
        v                       v                       v
  [auth module]          [account module]       [session module]
  Verify identity        Verify permissions,    Setup environment,
  (Password, Token)      expiration, hours      mounts, logging
```

#### Management Groups (`type`)
1. `auth`: Validates user authenticity (e.g., password prompt) and sets credentials.
2. `account`: Verifies non-authentication account availability (e.g., password expiration, access hours, root restrictions).
3. `session`: Configures environment tasks prior to shell execution and cleanup upon termination (e.g., mounting homes, logging, resource limits).
4. `password`: Handles password updates and updates linked credential stores.

#### Control Flags & Evaluation Matrix
* `required`: Module failure guarantees ultimate stack failure. However, execution **continues** down the stack to mask module failure reasons from potential attackers.
* `requisite`: Module failure causes **immediate failure** of the entire stack; subsequent modules in the group are skipped.
* `sufficient`: Module success immediately returns **success** to the application, skipping remaining modules *if no prior `required` module has failed*.
* `optional`: Module failure/success is ignored unless it is the only module in the stack.
* `include` / `substack`: Embeds external configuration stacks.

---

### Step-by-Step Guided Implementation

#### Step 2.1: Construct a Production Security Stack with `pam_faillock`, `pam_limits`, and `pam_wheel`

Modify `/etc/pam.d/system-auth` to lock accounts after 3 failed password attempts within 15 minutes (900s), enforce `wheel` group isolation for administrative escalations, and set strict resource limits.

```pam
# /etc/pam.d/system-auth
# Priority Auth Stack with Brute-Force Lockout
auth        required      pam_env.so
auth        required      pam_faillock.so preauth silent audit deny=3 unlock_time=900 even_deny_root
auth        sufficient    pam_unix.so nullok try_first_pass
auth        required      pam_faillock.so authfail audit deny=3 unlock_time=900 even_deny_root
auth        required      pam_deny.so

# Account Expiration and Access Control
account     required      pam_faillock.so
account     required      pam_unix.so

# Password Hardening Policy
password    requisite     pam_pwquality.so retry=3 minlen=14 retry=3 enforce_for_root
password    sufficient    pam_unix.so sha512 shadow try_first_pass use_authtok
password    required      pam_deny.so

# Session Setup and Resource Isolation
session     optional      pam_keyinit.so revoke
session     required      pam_limits.so
session     required      pam_unix.so
```

Modify `/etc/pam.d/su` to restrict `su` access exclusively to members of the `wheel` system group:

```pam
# /etc/pam.d/su
auth        required      pam_env.so
auth        sufficient    pam_rootok.so
auth        required      pam_wheel.so use_uid group=wheel
auth        include       system-auth
account     include       system-auth
session     include       system-auth
```

#### Step 2.2: Audit and Clear Account Lockouts via `faillock` CLI

Simulate authentication failures and manage locked accounts using `faillock`:

Check account lockout status:

```bash
faillock --user secadmin
```

**Expected Output:**
```text
secadmin:
When                Type  Source                          Valid
2026-08-06 10:15:22 V     192.168.1.50                    V
2026-08-06 10:15:28 V     192.168.1.50                    V
2026-08-06 10:15:34 V     192.168.1.50                    V
```

Clear account lockout state immediately:

```bash
faillock --user secadmin --reset
```

**Expected Output:**
```text
(No output returned; exit status 0 indicates successfully cleared database record).
```

#### Step 2.3: Configure Hard System Resource Isolation in `/etc/security/limits.conf`

Enforce resource constraints processed by `pam_limits.so`:

```text
# /etc/security/limits.conf
# <domain>      <type>  <item>         <value>
*               hard    core           0
*               hard    nproc          2048
*               soft    nofile         65536
*               hard    nofile         524288
@developers     hard    maxlogins      2
```

Validate user limit execution:

```bash
su - secadmin -c "ulimit -a"
```

**Expected Output:**
```text
core file size          (blocks, -c) 0
data seg size           (kbytes, -d) unlimited
scheduling priority             (-e) 0
file size               (blocks, -f) unlimited
pending signals                 (-i) 62832
max locked memory       (kbytes, -l) 64
max memory size         (kbytes, -m) unlimited
open files                      (-n) 65536
pipe size            (512 bytes, -p) 8
POSIX message queues     (bytes, -q) 819200
real-time priority              (-r) 0
stack size              (kbytes, -s) 8192
cpu time               (seconds, -t) unlimited
max user processes              (-u) 2048
virtual memory          (kbytes, -v) unlimited
file locks                      (-x) unlimited
```

---

### Verification Questions - Block 2

#### Question 2.1
An architect analyzes the following custom `/etc/pam.d/sshd` configuration fragment:

```pam
auth    requisite     pam_ipmatch.so ip=10.0.0.0/8
auth    required      pam_faillock.so preauth silent deny=3
auth    sufficient    pam_unix.so
auth    required      pam_deny.so
```

If an authentication attempt originates from IP address `192.168.1.100`, how does the PAM engine evaluate the stack?

- A) `pam_ipmatch.so` fails, but because it is followed by `pam_faillock.so` (required), the user is prompted for a password.
- B) `pam_ipmatch.so` fails, triggering an immediate termination of the `auth` group with a denial status, skipping `pam_faillock.so` and `pam_unix.so`.
- C) `pam_ipmatch.so` returns `PAM_IGNORE`, allowing execution to pass directly to `pam_unix.so`.
- D) `pam_ipmatch.so` fails, but `pam_unix.so` (sufficient) overrides the failure if the user inputs a valid password.

#### Question 2.2
A sysadmin needs to force `su` authentication to fail immediately if the invoking user is not a member of the group `sysadmin`, while ensuring no password prompts are presented to unauthorized callers. Which PAM configuration line achieves this in `/etc/pam.d/su`?

- A) `auth optional pam_wheel.so group=sysadmin deny`
- B) `auth requisite pam_wheel.so group=sysadmin use_uid`
- C) `auth sufficient pam_wheel.so group=sysadmin trust`
- D) `auth required pam_group.so allow=sysadmin`

---

## Exercise Block 3: OpenLDAP Directory Server Architecture & OLC (`cn=config`) Management

### Architectural Mechanics & Deep-Dive

Modern OpenLDAP deployments (`slapd`) discard static `slapd.conf` flat files in favor of **On-Line Configuration** (OLC), represented internally as an active LDAP directory database under `cn=config`. Changes are applied dynamically at runtime using `ldapmodify` and LDIF files without restarting the `slapd` daemon.

```
                         OpenLDAP Slapd Daemon
                                   |
         +-------------------------+-------------------------+
         |                                                   |
         v                                                   v
   cn=config (OLC)                                 dc=production,dc=local
 (Runtime Settings)                                (Directory User Data)
   |- olcDatabase={0}config                          |- olcDatabase={1}mdb
   |- olcDatabase={1}mdb                             |- User entries (posixAccount)
   |- Access Controls (olcAccess)                   |- Group entries (posixGroup)
   |- TLS Configuration                              |- Indexing (olcDbIndex)
```

Official Reference: [OpenLDAP Software 2.4 Administrator's Guide](https://www.openldap.org/doc/admin24/)

#### Key OpenLDAP Utilities
* `slapadd`: Direct database insertion tool (bypasses daemon; must run offline or against unmounted stores).
* `slapcat`: Exports database content directly to LDIF output.
* `slapindex`: Rebuilds database search indexes based on `olcDbIndex` attributes.
* `ldapsearch` / `ldapmodify`: Client operational tools utilizing standard network protocol calls (over TLS/LDAPS).

---

### Step-by-Step Guided Implementation

#### Step 3.1: Bootstrap an OpenLDAP MDB Database via OLC (`cn=config`)

Create a deployment schema `bootstrap_domain.ldif` to set up the organization base structure and database options:

```ldif
# bootstrap_domain.ldif
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcSuffix
olcSuffix: dc=production,dc=local
-
replace: olcRootDN
olcRootDN: cn=admin,dc=production,dc=local
-
replace: olcRootPW
# Secret generated via: slappasswd -h {SSHA} -s "SuperSecurePassword123!"
olcRootPW: {SSHA}vR3Zk9w8N8XQ5J3e2Y1U4P6O7I8U9Y0T
```

Apply runtime modifications using `ldapmodify` against `cn=config`:

```bash
ldapmodify -Y EXTERNAL -H ldapi:/// -f bootstrap_domain.ldif
```

**Expected Output:**
```text
SASL/EXTERNAL authentication started
SASL username: gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth
SASL SSF: 0
modifying entry "olcDatabase={1}mdb,cn=config"
```

#### Step 3.2: Configure Fine-Grained Access Control Lists (`olcAccess`)

Securing user password hashes and directory attributes requires strict ordering in `olcAccess`. First match wins!

Create `configure_acls.ldif`:

```ldif
# configure_acls.ldif
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcAccess
olcAccess: {0}to attrs=userPassword
  by self write
  by anonymous auth
  by dn.exact="cn=admin,dc=production,dc=local" write
  by * none
olcAccess: {1}to attrs=shadowLastChange
  by self write
  by dn.exact="cn=admin,dc=production,dc=local" write
  by * none
olcAccess: {2}to *
  by dn.exact="cn=admin,dc=production,dc=local" write
  by users read
  by * read
```

Apply ACL modifications:

```bash
ldapmodify -Y EXTERNAL -H ldapi:/// -f configure_acls.ldif
```

#### Step 3.3: Enforce TLS Infrastructure Encryption (StartTLS)

Import TLS certificates into `cn=config` to enforce channel security:

```ldif
# enable_tls.ldif
dn: cn=config
changetype: modify
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: /etc/ssl/certs/ca-production.crt
-
replace: olcTLSCertificateFile
olcTLSCertificateFile: /etc/ssl/certs/ldap-server.crt
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: /etc/ssl/private/ldap-server.key
-
replace: olcSecurity
olcSecurity: tls=1
```

Apply TLS policy configuration:

```bash
ldapmodify -Y EXTERNAL -H ldapi:/// -f enable_tls.ldif
```

Test TLS connectivity over standard LDAP port (`389`) using StartTLS (`-ZZ`):

```bash
ldapsearch -x -H ldap://ldap.production.local -ZZ -b "dc=production,dc=local" "(objectClass=*)"
```

**Expected Output:**
```text
# extended LDIF
#
# LDAPv3
# base <dc=production,dc=local> with scope subtree
# filter: (objectClass=*)
# requesting: ALL
#

# production.local
dn: dc=production,dc=local
objectClass: top
objectClass: dcObject
objectClass: organization
o: Production Enterprise
dc: production

# search result
search: 3
result: 0 Success
```

#### Step 3.4: Rebuild Search Indexes via `slapindex`

Define indexing parameters in `cn=config` for performance optimization:

```ldif
# indexing.ldif
dn: olcDatabase={1}mdb,cn=config
changetype: modify
add: olcDbIndex
olcDbIndex: uid eq,pres,sub
olcDbIndex: cn,sn eq,sub
olcDbIndex: objectClass eq
```

Apply index configuration and force database re-indexing offline:

```bash
ldapmodify -Y EXTERNAL -H ldapi:/// -f indexing.ldif
systemctl stop slapd
slapindex -b "dc=production,dc=local"
chown -R openldap:openldap /var/lib/ldap/
systemctl start slapd
```

---

### Verification Questions - Block 3

#### Question 3.1
An OpenLDAP server is configured with the following `olcAccess` rules:

```text
olcAccess: {0}to * by users read by * none
olcAccess: {1}to attrs=userPassword by self write by anonymous auth by * none
```

A non-administrative authenticated user (`uid=jdoe,ou=users,dc=production,dc=local`) attempts to update their password attribute (`userPassword`). What is the outcome?

- A) The password change succeeds because Rule `{1}` permits `self write`.
- B) The operation fails with permission denied because Rule `{0}` matches first, evaluation stops, and Rule `{0}` does not grant write permission to `userPassword`.
- C) The operation succeeds because password modifications bypass standard `olcAccess` matching when executed over StartTLS.
- D) The OpenLDAP server crashes due to conflicting access rule declarations.

#### Question 3.2
An SRE needs to rebuild corrupted indexes on an active OpenLDAP database (`mdb` engine). What is the mandatory procedure to prevent database corruption during `slapindex` execution?

- A) Run `slapindex -F /etc/openldap/slapd.d` while `slapd` is actively processing writes.
- B) Stop the `slapd` daemon, execute `slapindex` with appropriate database scope/privileges, fix file permissions, and start `slapd`.
- C) Issue `ldapmodify` with `olcDbIndex: rebuild` while `slapd` is running in single-user mode.
- D) Export the database via `ldapsearch`, delete `/var/lib/ldap/*`, and restart `slapd`.

---

## Exercise Block 4: Client Directory Integration with SSSD, NSSwitch, and LDAP Diagnostic Tooling

### Architectural Mechanics & Deep-Dive

Integrating Linux clients with centralized directories involves two primary sub-systems:

```
Applications (e.g., ls, id, sshd)
       |
       v
/etc/nsswitch.conf  -------------------------> PAM (/etc/pam.d/)
       | (Identity Lookups)                          | (Authentication)
       v                                             v
  nss_sss.so                                    pam_sss.so
       |                                             |
       +----------------------+----------------------+
                              |
                              v
                  SSSD Daemon (sssd)
                     |- Data Provider (LDAP / AD)
                     |- Fast In-Memory Cache (LDB: /var/lib/sss/db/)
```

1. **Name Service Switch (`/etc/nsswitch.conf`):** Configures database lookups (e.g., `passwd`, `group`, `hosts`, `shadow`). Libraries like `libnss_files.so` and `libnss_sss.so` resolve identities sequentially based on rules defined in `nsswitch.conf`.
2. **System Security Services Daemon (SSSD):** Manages identity lookups and authentication requests. SSSD retrieves entries from directory servers, caches them locally in LDB files (`/var/lib/sss/db/`), and allows users to log in even when offline or disconnected from the network.

---

### Step-by-Step Guided Implementation

#### Step 4.1: Configure `/etc/nsswitch.conf` for SSSD Integration

Edit `/etc/nsswitch.conf` to direct identity calls to local system files first, falling back to SSSD:

```text
# /etc/nsswitch.conf
passwd:         files sss
group:          files sss
shadow:         files sss
gshadow:        files sss

hosts:          files dns
networks:       files

protocols:      db files
services:       db files sss
ethers:         db files
rpc:            db files
```

#### Step 4.2: Deploy Production `/etc/sssd/sssd.conf` with Secure LDAP Binding

Create `/etc/sssd/sssd.conf` to handle identity lookup and authentication over LDAPS:

```ini
# /etc/sssd/sssd.conf
[sssd]
config_file_version = 2
services = nss, pam
domains = PRODUCTION

[domain/PRODUCTION]
id_provider = ldap
auth_provider = ldap
chpass_provider = ldap

# LDAP Infrastructure Endpoints
ldap_uri = ldaps://ldap01.infra.production.local:636, ldaps://ldap02.infra.production.local:636
ldap_search_base = dc=production,dc=local
ldap_schema = rfc2307bis

# TLS Security Requirements
ldap_tls_cacert = /etc/ssl/certs/ca-production.crt
ldap_tls_reqcert = hard

# Credentials Binding for Client Queries
ldap_default_bind_dn = cn=sssd-bind,ou=services,dc=production,dc=local
ldap_default_authtok = DirectClientBindSecret987!

# Offline Caching Policies
cache_credentials = true
account_cache_expiration = 1
entry_cache_timeout = 5400
```

Set required security permissions (SSSD will refuse to launch if permissions are overly permissive):

```bash
chmod 600 /etc/sssd/sssd.conf
chown root:root /etc/sssd/sssd.conf
systemctl restart sssd
```

#### Step 4.3: Perform Identity Resolution and LDAP Directory Querying

Verify NSS resolution using system primitives:

```bash
getent passwd sysop_user
```

**Expected Output:**
```text
sysop_user:*:10052:10001:System Operations User:/home/sysop_user:/bin/bash
```

Directly query LDAP attributes via `ldapsearch` using client service bind credentials:

```bash
ldapsearch -x -H ldaps://ldap01.infra.production.local \
  -D "cn=sssd-bind,ou=services,dc=production,dc=local" \
  -w "DirectClientBindSecret987!" \
  -b "ou=users,dc=production,dc=local" \
  "(uid=sysop_user)" uidNumber gidNumber homeDirectory loginShell
```

**Expected Output:**
```text
# extended LDIF
#
# LDAPv3
# base <ou=users,dc=production,dc=local> with scope subtree
# filter: (uid=sysop_user)
# requesting: uidNumber gidNumber homeDirectory loginShell
#

# sysop_user, users, production.local
dn: uid=sysop_user,ou=users,dc=production,dc=local
uidNumber: 10052
gidNumber: 10001
homeDirectory: /home/sysop_user
loginShell: /bin/bash

# search result
search: 2
result: 0 Success
```

Validate current bind authentication state using `ldapwhoami`:

```bash
ldapwhoami -x -H ldaps://ldap01.infra.production.local \
  -D "cn=sssd-bind,ou=services,dc=production,dc=local" \
  -w "DirectClientBindSecret987!"
```

**Expected Output:**
```text
dn:cn=sssd-bind,ou=services,dc=production,dc=local
```

#### Step 4.4: Flush Cache and Debug SSSD Issues

When directory attributes are updated on the server but not reflected on the client, clear the SSSD cache using `sss_cache`:

```bash
sss_cache -E
```

Inspect SSSD domain logs for connection failures or schema mismatch issues:

```bash
tail -n 25 /var/log/sssd/sssd_PRODUCTION.log
```

---

### Verification Questions - Block 4

#### Question 4.1
A Linux server configured with SSSD experiences an unexpected network isolation event separating it from all OpenLDAP domain controllers. Users report that existing cached accounts can log in, but executing `getent passwd` only outputs local `/etc/passwd` accounts. What explains this behavior?

- A) SSSD disables local cached credential verification when network interfaces drop.
- B) `getent passwd` enumerates all entries. SSSD disables full enumeration by default (`enumeration = false`) to prevent network flooding and memory consumption, while still permitting direct cached authentication.
- C) NSSwitch automatically removes `sss` from `/etc/nsswitch.conf` upon detecting network link loss.
- D) Cached identity databases under `/var/lib/sss/db/` are wiped immediately when LDAP servers become unreachable.

#### Question 4.2
SSSD fails to start following a host reboot. Running `systemctl status sssd` displays `FATAL: Unsafe permissions on configuration file /etc/sssd/sssd.conf`. What exact file mode bit combination is required to fix this?

- A) `0755` (`rwxr-xr-x`) owned by `root:root`
- B) `0644` (`rw-r--r--`) owned by `root:sssd`
- C) `0600` (`rw-------`) owned by `root:root`
- D) `0400` (`r--------`) owned by `sssd:sssd`

---

<details>
<summary><strong>Click to expand: Comprehensive Solutions & Answer Key</strong></summary>

### Block 1 Answers

* **Question 1.1: Correct Answer B**  
  * **Reasoning:** When a DHCP Relay Agent forwards a `DHCPDISCOVER` packet, it populates the `giaddr` field with its own interface IP address on the client subnet (`10.200.1.1`). The DHCP server uses `giaddr` to match incoming requests to an appropriate `subnet` declaration in `dhcpd.conf`. If no `subnet 10.200.1.0 netmask 255.255.255.0` block exists on the DHCP server, it cannot assign an IP address from that pool, resulting in a log indicating no free leases for the server's local network segment.
  * **Incorrect Options:** A is incorrect because DHCP does not map relay agents in `/etc/hosts`. C is incorrect because missing Option 82 metadata does not prevent basic subnet allocation via `giaddr`. D is incorrect because normal dynamic clients issue `DHCPDISCOVER` via standard DORA, not BOOTP.

* **Question 1.2: Correct Answer B**  
  * **Reasoning:** In IPv6 autoconfiguration:
    * The **$M$ (Managed address configuration)** flag determines whether addresses are obtained via Stateful DHCPv6 ($M=1$). Setting $M=0$ instructs clients to use **SLAAC** to generate their own IP addresses.
    * The **$O$ (Other configuration)** flag determines whether non-address parameters (such as DNS servers and domain search lists) are fetched via DHCPv6 ($O=1$).
    * Therefore, SLAAC + Stateless DHCPv6 for options requires **$M=0, O=1$**.
  * **Incorrect Options:** A ($M=1, O=0$) forces Stateful DHCPv6 for IP assignment without extra options. C ($M=1, O=1$) mandates fully stateful DHCPv6 for both IP assignment and options. D ($M=0, O=0$) represents pure SLAAC with no DHCPv6 server interaction.

---

### Block 2 Answers

* **Question 2.1: Correct Answer B**  
  * **Reasoning:** The `requisite` control flag specifies that if the module fails, the PAM engine **immediately terminates execution of that management group (`auth`)** and returns a failure status directly to the application. Because `192.168.1.100` does not match `10.0.0.0/8`, `pam_ipmatch.so` returns a failure, stopping the stack instantly and skipping `pam_faillock.so` and `pam_unix.so`.
  * **Incorrect Options:** A describes `required` behavior, not `requisite`. C is incorrect because an unmatched IP causes module failure, not `PAM_IGNORE`. D is incorrect because `requisite` failures short-circuit the stack before reaching subsequent `sufficient` modules.

* **Question 2.2: Correct Answer B**  
  * **Reasoning:** The line `auth requisite pam_wheel.so group=sysadmin use_uid` enforces that the invoking user (determined via `use_uid`) must belong to the `sysadmin` group. Using the `requisite` control flag ensures that if the user is not in `sysadmin`, module evaluation fails and halts execution immediately before prompt-generating modules (like `pam_unix.so`) are executed.
  * **Incorrect Options:** A uses `optional`, which does not block non-members. C uses `sufficient`, which bypasses password verification for group members rather than denying non-members prior to prompt execution. D references a non-standard syntax and module for group-based `su` gating.

---

### Block 3 Answers

* **Question 3.1: Correct Answer B**  
  * **Reasoning:** OpenLDAP evaluates `olcAccess` rules sequentially in numeric order (`{0}`, `{1}`, `{2}`, ...). **The first rule that matches the targeted entry and attribute processes the request, and evaluation stops.** Because Rule `{0}` targets `to *` (all attributes, including `userPassword`), it matches the request first. Rule `{0}` permits `users` to `read`, but does not grant `write` access. Consequently, evaluation halts at Rule `{0}` and access is denied. Rule `{1}` is never evaluated.
  * **Incorrect Options:** A is incorrect because Rule `{0}` short-circuits evaluation before Rule `{1}` is reached. C is incorrect because TLS encrypts the transport channel but does not override directory ACLs. D is incorrect because invalid ACL ordering causes operational authorization failures, not daemon crashes.

* **Question 3.2: Correct Answer B**  
  * **Reasoning:** `slapindex` directly modifies the underlying database storage engine (`mdb` or legacy `hdb`/`bdb`) on disk, bypassing the `slapd` daemon process. Running `slapindex` while `slapd` is actively running leads to concurrent file writes, index corruption, and database lock failures. The service must be stopped prior to running `slapindex`.
  * **Incorrect Options:** A causes severe database corruption. C is invalid because `olcDbIndex` modifies configuration parameters in `cn=config`, but does not support a `rebuild` keyword. D is an inefficient workaround that requires exporting/importing data rather than running an offline re-index.

---

### Block 4 Answers

* **Question 4.1: Correct Answer B**  
  * **Reasoning:** SSSD disables database enumeration (`enumeration = false`) by default. Enumerating full directories (`getent passwd`) over large enterprise databases generates immense network and CPU overhead. When offline, `getent passwd` queries NSS, which calls `sss`; because enumeration is disabled, `sss` returns only local system files or active matches. However, direct user authentication (`pam_sss`) and explicit single-user queries (`id <username>`) succeed because credentials and individual user mappings are cached locally in `/var/lib/sss/db/`.
  * **Incorrect Options:** A is incorrect because SSSD explicitly supports offline authentication via cached credentials. C is incorrect because NSSwitch does not dynamically rewrite `/etc/nsswitch.conf`. D is incorrect because SSSD retains cache files across network disruptions to support offline authentication.

* **Question 4.2: Correct Answer C**  
  * **Reasoning:** `/etc/sssd/sssd.conf` stores sensitive operational secrets, including plain-text service account bind passwords (`ldap_default_authtok`). To protect these credentials, SSSD enforces strict file security permissions. The configuration file must be owned by `root:root` with permissions set strictly to `0600` (`rw-------`) or `0400` (`r--------`). Any group or world readability causes SSSD to abort daemon startup.
  * **Incorrect Options:** A (`0755`), B (`0644`), and D (wrong ownership `sssd:sssd`) violate SSSD security enforcement checks, causing startup failures.

</details>