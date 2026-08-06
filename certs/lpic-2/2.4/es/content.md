# LPIC-2 Study Guide: Tema 205 — Network Client Management (Examen 202-450, Versión 4.5)

---

## 1. Motivación y problemas de arquitectura en producción

En la ingeniería de infraestructura empresarial y la Ingeniería de Confiabilidad del Sitio (SRE), la gestión centralizada de red y la orquestación de identidades constituyen la base fundamental de la arquitectura zero-trust. Operar clústeres heterogéneos a escala —que abarcan compute bare-metal, hipervisores y nodos edge en la nube— requiere el bootstrapping automatizado de la red junto con una gestión centralizada de identidades y accesos (IAM) asegurada de forma criptográfica.

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

### Desafíos clave de producción y compensaciones arquitectónicas

#### 1. Fallos en cascada en la gestión de identidades y direcciones IP (IPAM)
Si la configuración del cliente de red (DHCP) o la resolución de identidades (LDAP/SSSD) sufren interrupciones o picos de latencia, el aprovisionamiento de hosts se detiene, la autenticación SSH se bloquea y los procesos críticos de cron/daemon fallan. Los sistemas que dependen de consultas síncronas a bases de datos remotas por cada transacción de PAM corren el riesgo de sufrir una caída completa si el backend de LDAP deja de estar accesible.

#### 2. Riesgos en el aprovisionamiento de clientes de red
Los mecanismos estándar de broadcast de DHCP carecen de autenticación de forma predeterminada. Sin la supresión de rogue-DHCP (DHCP Snooping), el etiquetado de la option 82 y la redundancia (protocolo DHCP Failover), la gestión de clientes de red es vulnerable a ataques de man-in-the-middle (MitM), agotamiento de direcciones IP (DHCP starvation) y disrupciones por punto único de fallo (SPOF).

#### 3. Fragilidad del pipeline de autenticación
Los vectores de ejecución de PAM ordenados de manera incorrecta (por ejemplo, colocar `sufficient` antes de un módulo obligatorio de auditoría o bloqueo como `pam_faillock.so`) crean vulnerabilidades críticas de bypass de autorización. Además, los órdenes de búsqueda de NSS mal configurados (`/etc/nsswitch.conf`) provocan bloqueos en la ejecución de aplicaciones cuando los servicios de nombres externos no responden con rapidez.

#### 4. Escalabilidad del motor de almacenamiento y de las Listas de Control de Acceso (ACL) del directorio
Los despliegues heredados de OpenLDAP que utilizan `slapd.conf` y backends `bdb`/`hdb` experimentan corrupción de base de datos durante apagados abruptos y bloquean los cambios de configuración dinámica en tiempo de ejecución. Las arquitecturas de producción modernas requieren el motor Memory-Mapped Database (`mdb`) junto con `cn=config` (On-Line Configuration - OLC) para realizar modificaciones de esquemas y políticas sin tiempo de inactividad a través de flujos LDIF.

---

## 2. Comparativas técnicas y matriz de compensaciones

### 2.1 Estrategias de direccionamiento de red e IPAM

| Métrica de arquitectura | Servidor ISC DHCP (Par HA Failover) | Asignación estática de IP (Ansible/Cloud-Init) | Kubernetes / CNI IPAM (Cilium / Calico) |
| :--- | :--- | :--- | :--- |
| **Capa de bootstrapping** | PXE físico L2/L3 e hipervisor | Plantillado estático en tiempo de aprovisionamiento | Interfaces virtuales de superposición L3 / eBPF |
| **Mecanismo de alta disponibilidad** | Sincronización de estado DHCP Failover basada en OMAPI | N/A (Estado integrado en la config del nodo) | Almacén de estado distribuido Etcd / CRD |
| **Latencia de reasignación** | Baja (Limitada por el TTL de la concesión y renovación T1/T2) | Cero (Estática), alto costo manual de ciclo de vida | Microsegundos (Asignación dinámica de pods) |
| **Mitigación de rogue** | Requiere DHCP Snooping en switches L2 | Aplicación estática nativa L2/L3 | Aplicación de políticas NetworkPolicies y eBPF |
| **Carga operativa de SRE** | Moderada (Auditoría de base de datos de concesiones y config de relay) | Alta a escala (Riesgo de solapamiento/agotamiento de IPs) | Baja (Ciclo de vida automatizado gestionado mediante Operator) |

### 2.2 Stack de autenticación de Linux e integración de directorios

| Componente | LDAP NSS directo (`nslcd` / `pam_ldap`) | Daemon de Servicios de Seguridad del Sistema (`sssd`) | Proxy Cloud IAM / OIDC (Teleport / Boundary) |
| :--- | :--- | :--- | :--- |
| **Autenticación offline** | **No** (Requiere conexión directa a la red por evento de autenticación) | **Sí** (Caché local cifrada de credenciales/esquemas) | **No** (Requiere certificados TLS/SSH activos de corta duración) |
| **Rendimiento de consultas NSS** | Bajo (RTT de red en cada llamada a `getpwnam()`) | Alto (Caché `fast-pam` en memoria + almacenamiento LDB) | N/A (Omite la capa POSIX NSS por completo) |
| **Agrupación de conexiones y conmutación por error**| DNS SRV round-robin básico | Descubrimiento multiservidor avanzado, comprobación de estado y backoff | Abstracción de Edge Access Proxy con balanceo de carga global |
| **Integración con Kerberos / AD** | Requiere una integración manual compleja | Integración nativa con Active Directory mediante el proveedor `ad` | Se integra a nivel de proveedor de identidades (IdP) |
| **Vector de seguridad** | Vulnerable a bloqueos por partición de red | Riesgo de permisos en caché desactualizados si el TTL es alto | Requiere ecosistema PKI; cero claves de largo plazo en el host |

### 2.3 Implementaciones de servicios de directorio

| Parámetro | OpenLDAP (`cn=config` + `MDB`) | FreeIPA / Red Hat IdM | Servicios de Dominio de Microsoft Active Directory |
| :--- | :--- | :--- | :--- |
| **Motor backend principal** | LMDB (Lightning Memory-Mapped Database) | OpenLDAP (`389-ds`) + MIT Kerberos | Motor de Almacenamiento Extensible (ESE / Jet) |
| **Flexibilidad de esquema** | Alta (Esquemas personalizados editables en vivo mediante LDIF) | Moderada (Esquemas POSIX, Kerberos y DNS preempaquetados) | Estricta (Extensiones de esquema de Active Directory) |
| **Protocolo de replicación** | SyncRepl (RefreshAndPersist / Auditlog) | Replicación Multi-Master (plugin `389-ds`) | Replicación Multi-Master RPC/DRSR |
| **Integración nativa con Linux**| Excelente (Nativa POSIX `posixAccount`/`posixGroup`) | Nativa (Diseñada específicamente para la gestión empresarial en Linux) | Requiere el proveedor `ad` de SSSD o Samba Winbind |

---

## 3. Manifiestos de producción completos y archivos de configuración

### 3.1 Configuración del servidor ISC DHCP primario (`/etc/dhcp/dhcpd.conf`)

Configuración de servidor DHCP de grado de producción con doble interfaz de red (dual-homed), que incluye emparejamiento de failover de alta disponibilidad, configuración de arranque PXE, definiciones de opciones personalizadas y asignaciones estáticas de MAC a IP.

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

### 3.2 Pipeline de autenticación PAM SSH empresarial (`/etc/pam.d/sshd`)

Configuración de PAM de Linux reinforced (hardened) que cuenta con protección contra bloqueo de cuentas (`pam_faillock`), resolución remota de identidades a través de SSSD (`pam_sss`), fallback de anulación local de root (`pam_unix`), aislamiento de entorno (`pam_limits`) y creación automática del directorio home (`pam_mkhomedir`).

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

### 3.3 Daemon de Servicios de Seguridad del Sistema (`/etc/sssd/sssd.conf`) y NSS (`/etc/nsswitch.conf`)

#### Configuración del motor SSSD (`/etc/sssd/sssd.conf`)

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

#### Configuración de Name Service Switch (`/etc/nsswitch.conf`)

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

### 3.4 Flujo LDIF de configuración dinámica de OpenLDAP (`cn=config` / OLC)

Este manifiesto LDIF aprovisiona el backend de base de datos LMDB, certificados TLS, índices y Listas de Control de Acceso (ACLs) a través de la Configuración en Línea (OLC).

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

## 4. Comandos CLI y transcripciones de salida de terminal

### 4.1 Gestión del ciclo de vida del servidor DHCP e inspección de concesiones (leases)

#### Paso 1: Validar la sintaxis del servidor DHCP
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

#### Paso 2: Consultar el archivo de concesiones activas del servidor
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

#### Paso 3: Monitorear la interacción del cliente DHCP (`dhclient`)
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

### 4.2 Pruebas del stack PAM y bloqueo de cuentas (`faillock` / `pamtester`)

#### Paso 1: Validar el stack de autenticación a través de `pamtester`
```bash
$ sudo pamtester sshd devops-user authenticate
```
```text
Password: 
pamtester: successfully authenticated
```

#### Paso 2: Inspeccionar el motor de estado de bloqueo de cuentas (`faillock`)
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

#### Paso 3: Limpiar el estado de cuenta bloqueada
```bash
$ sudo faillock --user devops-user --reset
```
```text
devops-user:
When                Type  Source            Valid
```

---

### 4.3 Auditoría operativa de SSSD y resolución de identidades

#### Paso 1: Verificar el estado del dominio SSSD y la conectividad del backend
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

#### Paso 2: Validar la resolución POSIX del sistema a través de NSS Switch
```bash
$ getent passwd devops-user
```
```text
devops-user:x:10052:10000:DevOps SRE Engineer:/home/devops-user:/bin/bash
```

#### Paso 3: Ejecutar la verificación interactiva de acceso de usuario a través de `sssctl`
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

### 4.4 Administración del directorio OpenLDAP y herramientas operativas

#### Paso 1: Validar la estructura de directorios de configuración OLC de OpenLDAP
```bash
$ sudo slaptest -F /etc/ldap/slapd.d -v
```
```text
config file testing succeeded
```

#### Paso 2: Volcar registros directos de la base de datos usando la utilidad de motor de bajo nivel (`slapcat`)
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

#### Paso 3: Consultar el Árbol de Información del Directorio (DIT) mediante la utilidad de cliente sobre TLS
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

## 5. Guía de verificación y diagnóstico de fallos

### 5.1 Diagrama de flujo para resolución sistemática de problemas

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

### 5.2 Matriz de diagnóstico detallado

| Modo de fallo | Hipótesis de causa raíz | Método de verificación empírica | Paso de mitigación |
| :--- | :--- | :--- | :--- |
| **`DHCPDISCOVER` del cliente DHCP atascado** | Aislamiento de broadcast L2 o fallo del DHCP Relay (`dhcrelay`) | Ejecutar captura de paquetes:<br>`sudo tcpdump -i eth0 -n "port 67 or port 68"` | Verificar etiquetado VLAN L2 / Configurar el agente DHCP Relay en la interfaz del router |
| **DHCP Failover desincronizado** | Desviación de reloj entre pares HA o desajuste de estado | Inspeccionar logs del servidor:<br>`grep -i "failover peer" /var/log/syslog` | Sincronizar relojes NTP (`chronyc tracking`) y forzar la sincronización de estado |
| **`getent` resuelve el usuario, pero SSH falla** | Fallo en el orden de la cadena de módulos PAM o restricción de `faillock` | Inspeccionar log de PAM:<br>`journalctl -u sshd -e --no-pager`<br>Verificar bloqueos: `faillock --user <id>` | Reordenar `/etc/pam.d/sshd` para ejecutar `pam_faillock` y `pam_sss` correctamente |
| **SSSD no puede autenticar usuarios offline** | `cache_credentials = false` o almacenamiento LDB corrupto | Verificar estado de la caché de SSSD:<br>`sudo ls -la /var/lib/sss/db/`<br>Ejecutar `sssctl domain-status` | Habilitar `cache_credentials = true` o limpiar la caché corrupta usando `sss_cache -E` |
| **Fallo en el handshake TLS de `ldapsearch` en OpenLDAP** | Desajuste en el certificado CA o en el hostname en el certificado TLS | Ejecutar búsqueda de depuración:<br>`LDAPTLS_CACERT=/etc/ssl/certs/ca.pem ldapsearch -d 1 -x -ZZ -H ldap://...` | Coincidir la ruta cliente `TLS_CACERT` en `/etc/openldap/ldap.conf` con la CA del servidor |
| **Bloqueo de escritura en la base de datos OpenLDAP** | Límite de `olcDbMaxSize` alcanzado en LMDB o disco lleno | Ejecutar `slapcat` y revisar el log:<br>`grep -i "MDB_MAP_FULL" /var/log/syslog` | Actualizar `cn=config` con LDIF extendiendo `olcDbMaxSize` |

---

### 5.3 Comandos de diagnóstico paso a paso

#### 1. Captura de paquetes a bajo nivel para verificación del ciclo de vida de DHCP
```bash
$ sudo tcpdump -i eth0 -vvv -s 1500 -n "port 67 or port 68"
```

#### 2. Ejecución de diagnóstico de alta verbosidad en OpenLDAP
Iniciar el daemon de OpenLDAP en primer plano con registro de trazas para ACLs, filtros de búsqueda y procesamiento de configuración (Nivel 256 + 128 + 512 = 896):
```bash
$ sudo slapd -d 896 -F /etc/ldap/slapd.d -h "ldaps:///"
```

#### 3. Reinicio completo y reindexación de las cachés de seguridad de SSSD
Si SSSD genera atributos desactualizados o vinculaciones de base de datos rotas:
```bash
$ sudo systemctl stop sssd
$ sudo sss_cache -E
$ sudo rm -f /var/lib/sss/db/*.ldb
$ sudo systemctl start sssd
$ sssctl domain-status PROD_LDAP
```

---

## 6. Referencias

- [Objetivos del examen LPIC-2 202-450 de Linux Professional Institute (LPI)](https://www.lpi.org/our-certifications/lpic-2-overview/)
- [Guía del administrador de OpenLDAP Software 2.6 (On-Line Configuration - cn=config)](https://www.openldap.org/doc/admin26/slapdconf2.html)
- [Documentación de System Security Services Daemon (SSSD)](https://sssd.io/documentation/index.html)
- [Manual de referencia de ISC DHCP y arquitectura del protocolo Failover](https://www.isc.org/dhcp/)
- [Arquitectura de Linux PAM y especificaciones de módulos](https://github.com/linux-pam/linux-pam)
- [RFC 2131: Dynamic Host Configuration Protocol](https://datatracker.ietf.org/doc/html/rfc2131)
- [RFC 4511: Lightweight Directory Access Protocol (LDAP): El protocolo](https://datatracker.ietf.org/doc/html/rfc4511)