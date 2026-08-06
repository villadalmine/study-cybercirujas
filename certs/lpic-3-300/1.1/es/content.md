# Examen LPIC-3 300-300 (v3.0) — Tema 301: Samba Basics (Peso: 20)
## Guía de Arquitectura de Plataforma e Ingeniería de Producción Avanzada

---

## 1. Motivación Arquitectónica de Producción y Declaración del Problema

### 1.1 El Problema Empresarial Heterogéneo Multiplataforma
En los centros de datos empresariales modernos e infraestructuras de nube híbrida, los sistemas operativos compatibles con POSIX (Linux, UNIX) y los sistemas operativos basados en NT (Windows Server, Windows Workstations) deben compartir el almacenamiento de archivos y las identidades de usuario bajo una arquitectura de seguridad unificada.

Linux y Windows aplican paradigmas de control de acceso fundamentalmente diferentes:
* **Modelo POSIX:** Máscara de permisos de 3 niveles (`owner`, `group`, `other` con `rwx`) combinada con UIDs POSIX (enteros no firmados de 32 bits) y GIDs.
* **Modelo Windows NT:** Security Descriptors que contienen Discretionary Access Control Lists (DACLs) compuestas por Access Control Entries (ACEs), indexadas por Security Identifiers (SIDs, p. ej., `S-1-5-21-...`).

Samba cierra esta brecha actuando como una implementación de código abierto y alto rendimiento de los protocolos Server Message Block (SMB) / Common Internet File System (CIFS) y protocolos de Microsoft Active Directory (AD). Permite que los hosts de Linux funcionen como:
1. **Active Directory Domain Controller (AD DC):** Proporcionando capacidades de Kerberos KDC, servidor LDAP, replicación SYSVOL y DNS.
2. **Domain Member Server:** Uniéndose a un Active Directory o dominio NT4 existente para servir SMB shares mientras respeta la gestión centralizada de identidades a través de `winbindd`.
3. **Standalone File/Print Server:** Gestionando la autenticación SMB local a través de backends TDB/Passdb.

```
                  +-------------------------------------------------------+
                  |               Windows Workstations / SMB Clients      |
                  +-------------------------------------------------------+
                                              |
                                              | SMB3.1.1 (TCP 445)
                                              v
+-----------------------------------------------------------------------------------+
| Linux Enterprise Storage Node (Samba 4.x)                                         |
|                                                                                   |
|  +---------------------+   +-----------------------+   +-----------------------+  |
|  |     smbd daemon     |   |     winbindd daemon   |   |      nmbd daemon      |  |
|  | (SMB/CIFS & RPCs)   |   |  (NSS/PAM & IDMap)    |   |  (NetBIOS/WINS)       |  |
|  +---------------------+   +-----------------------+   +-----------------------+  |
|             |                          |                           |              |
|             +-------------+------------+                           |              |
|                           |                                        |              |
|                           v                                        v              |
|  +-------------------------------------------------+    +----------------------+  |
|  | VFS Layer (acl_xattr, fruit, shadow_copy2)      |    | UDP 137/138          |  |
|  +-------------------------------------------------+    +----------------------+  |
|                           |                                                       |
|                           v                                                       |
|  +-------------------------------------------------+                              |
|  | File System (ext4 / xfs / zfs) with EA (`user.*`) |                              |
|  +-------------------------------------------------+                              |
+-----------------------------------------------------------------------------------+
```

### 1.2 Desafíos Arquitectónicos en Producción
* **Concurrencia y Bloqueo de Archivos (File Locking):** Los clientes SMB exigen semánticas de bloqueo estrictas (Byte-Range Locking, Opportunistic Locking / Oplocks y SMB2/3 Leases). Samba debe sincronizar estas semánticas de bloqueo de Windows con los bloqueos de archivos POSIX del kernel de Linux (`fcntl`/`flock`) sin generar deadlocks en el sistema de archivos.
* **Sobrecarga del Mapeo de Identidades (Identity Mapping Overhead):** Los SIDs deben mapearse de forma dinámica o determinista a UIDs/GIDs de Linux en entornos de alta concurrencia. Un mal ID mapping causa permisos no resolubles, fallas de seguridad o un rendimiento de I/O degradado debido a cache misses.
* **Atributos Extendidos (EA) y Traducción de ACL:** Los permisos de Windows NTFS requieren entradas ACE arbitrarias (Allow/Deny por usuario/grupo con flags precisos). Samba traduce las NT DACLs a atributos extendidos en bruto almacenados en los metadatos `user.NTACL` en sistemas de archivos POSIX a través del módulo `vfs_acl_xattr`.

---

## 2. Arquitectura Técnica y Comparaciones Profundas de Alternativas (Trade-offs)

### 2.1 Arquitectura Principal de Demonios de Samba

| Proceso Demonio | Rol y Responsabilidades | Enlaces de Puertos (Port Bindings) | Modelo de Procesos |
| :--- | :--- | :--- | :--- |
| **`smbd`** | Maneja el intercambio de archivos SMB/CIFS, impresión, named pipes y servicios MS-RPC (`srvsvc`, `lsarpc`, `samr`). Responsable de la autenticación, evaluación de ACL y bloqueo de archivos. | TCP 445 (Direct SMB over TCP), TCP 139 (NetBIOS Session) | Modelo de múltiples procesos. Un demonio maestro padre escucha las conexiones entrantes y realiza un fork de un proceso hijo dedicado por cada socket de cliente conectado. |
| **`nmbd`** | Gestiona NetBIOS Name Service (NBNS), peticiones cliente/servidor WINS y elecciones de master browser en la subred local. (Protocolo heredado, deshabilitado en entornos modernos puros de Active Directory). | UDP 137 (NetBIOS Name), UDP 138 (NetBIOS Datagram) | Bucle de eventos monohilo (single-threaded event loop) por socket de subred. |
| **`winbindd`** | Resuelve nombres de dominio, usuarios y grupos de Windows AD/NT en identidades UNIX NSS (`/etc/nsswitch.conf`). Maneja tokens de autenticación PAM, adquisición de tickets de Kerberos e ID mapping. | UNIX Domain Socket (`/var/run/samba/winbindd/pipe`) | Modelo multihilo / worker-pool para procesar de forma asíncrona las búsquedas de NSS y PAM. |
| **`samba`** | El binario paraguas utilizado **únicamente** cuando se ejecuta Samba como un Active Directory Domain Controller (AD DC). Genera procesos integrados de LDAP, Kerberos KDC, DNS e IPC interno. | TCP/UDP 88 (Kerberos), TCP/UDP 389 (LDAP), TCP 636 (LDAPS), TCP 3268/3269 (Global Catalog) | Modelo supervisor de procesos que genera subdemonios (`kdc`, `ldap`, `dns`). |

---

### 2.2 Internos del Motor de Base de Datos: TDB vs. LDB

Samba utiliza bases de datos ligeras personalizadas optimizadas para ultra baja latencia e IPC local en lugar de depender de motores SQL externos.

```
                    +----------------------------------------+
                    |          Samba State Engines           |
                    +----------------------------------------+
                                 |              |
                +----------------+              +----------------+
                |                                                |
                v                                                v
  +---------------------------+                    +---------------------------+
  |    TDB (Trivial Database) |                    |    LDB (LDAP Database)    |
  +---------------------------+                    +---------------------------+
  | - Key/Value Binary Store  |                    | - Object-Oriented Schema  |
  | - Lock per Hash Chain     |                    | - Index-backed Lookups    |
  | - Dynamic IPC/State Cache |                    | - AD DC Directory Store   |
  +---------------------------+                    +---------------------------+
  | Examples:                 |                    | Examples:                 |
  | - locking.tdb             |                    | - sam.ldb                 |
  | - passdb.tdb              |                    | - secrets.ldb             |
  | - gencache.tdb            |                    | - idmap.ldb               |
  +---------------------------+                    +---------------------------+
```

1. **TDB (Trivial Database):**
   * **Mecanismo:** Base de datos binaria clave-valor mapeada en memoria (`mmap`) que admite múltiples lectores concurrentes y un solo escritor mediante bloqueo de cadena de hash a nivel de registro.
   * **Bases de Datos de Producción:**
     * `locking.tdb`: Bloqueos de byte-range activos y estados de oplock (Volátil).
     * `brlock.tdb`: Repositorio de bloqueos byte-range (Volátil).
     * `gencache.tdb`: Caché genérica para resoluciones de SID a nombre y resultados de DNS (Volátil).
     * `passdb.tdb`: Base de datos local de usuarios SAM cuando `passdb backend = tdbsam` (Persistente).
     * `secrets.tdb`: Contraseña de la máquina local, secretos de confianza de dominio y claves privadas (Persistente).

2. **LDB (LDAP Database):**
   * **Mecanismo:** Base de datos embebida tipo LDAP construida sobre TDB. Admite estructuras de esquema jerárquicas, indexación, manipulación de datos a través de archivos LDIF y filtros de búsqueda LDAP avanzados.
   * **Bases de Datos de Producción (contexto AD DC):**
     * `sam.ldb`: Base de datos del Security Account Manager de Active Directory (Usuarios, Grupos, Equipos, OUs).
     * `secrets.ldb`: Claves de Kerberos y secretos de confianza de dominio.

---

### 2.3 Matrices Integrales de Comparación Técnica (Trade-offs)

#### Tabla 1: Modos de Seguridad de Samba (`security = ...`)

| Modo de Seguridad | Descripción | Mecanismo de Autenticación | Escenario de Caso de Uso | Pros | Contras |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`user`** (Predeterminado) | El cliente se autentica explícitamente con un usuario/contraseña contra los backends locales de Samba (`passdb.tdb`) o controladores de dominio remotos a través de RPC. | NTLMv2 o Kerberos validados localmente o por proxy. | Servidores de archivos Standalone, nodos aislados en DMZ o Domain Members. | Alto aislamiento; independiente de la disponibilidad de Active Directory para usuarios locales. | Sobrecarga de escalabilidad para la gestión de usuarios en múltiples servidores sin AD. |
| **`ads`** | Modo nativo Active Directory Domain Member. Samba actúa como una cuenta de máquina integrativa y kerberizada en un bosque de AD. | Kerberos v5 (ticket SPNEGO) con fallback a NTLMv2. | Servidores de archivos Domain Member empresariales integrados con MS Active Directory. | Single sign-on (SSO) transparente, aplicación centralizada de políticas ACL, evaluación completa de grupos de AD. | Dependencia estricta de DNS, desvío de reloj NTP (clock skew <5s) y disponibilidad de Active Directory. |
| **`domain`** *(Obsoleto)* | Samba se une a un dominio antiguo estilo NT4 utilizando RPCs SamSync. | Passthrough de RPC remoto al NT Domain Controller. | Integración con infraestructura heredada. | Compatible con DCs NT4 heredados. | Obsoleto en Samba 4.x; carece de soporte para Kerberos SSO y aplicación de seguridad moderna. |
| **`server` / `share`** *(Eliminado)* | Modos obsoletos heredados de Samba 2.x/3.x. | Desafío de contraseña básica / texto plano por share o por sesión de servidor. | No soportado. | Ninguno. | Vulnerabilidades de seguridad graves; completamente eliminado en versiones modernas de Samba 4. |

#### Tabla 2: Comparación de Dialectos del Protocolo SMB

| Dialecto del Protocolo | Introducido En | Tamaño Máximo de Búfer / Características | Mejoras de Seguridad | Impacto en Rendimiento / Escalabilidad |
| :--- | :--- | :--- | :--- | :--- |
| **SMB 1.0 (CIFS)** *(Deshabilitado por defecto)* | Windows NT 3.1 / Samba 1.x | Tamaño de mensaje de 64 KB. Ejecución síncrona de comandos por paquete. | Capacidades de texto plano / NTLMv1. Extremadamente vulnerable a ataques MITM y relay. | Rendimiento WAN pésimo debido a la extrema verbosidad del protocolo (chattiness). Obsoleto y deshabilitado en Samba moderno (`server min protocol = SMB2_10`). |
| **SMB 2.1** | Windows 7 / Samba 3.5 | Soporte para Large MTU (1 MB). Comprensión de comandos (Command compounding: combinación de múltiples peticiones en un paquete). | Capacidad de firma obligatoria (HMAC-SHA256), resilient handles. | Gran mejora de rendimiento en redes gigabit; reducción de ida y vuelta en la red (network round-trips). |
| **SMB 3.02** | Windows 8.1 / Samba 4.1 | SMB Multichannel, Directory Leasing, BranchCache v2. | Cifrado de carga útil de extremo a extremo AES-128-CCM. Hashes de integridad SHA-512. | Escalabilidad masiva de rendimiento a través de múltiples NICs (Multichannel). Seguridad sin sobrecarga para enlaces entre sitios. |
| **SMB 3.1.1** *(Predeterminado Moderno)* | Windows 10 / Samba 4.3+ | Validación de Pre-Authentication Integrity, selección de suite de cifrado AES-128-GCM. | Protección contra ataques MITM de degradación de dialecto (dialect downgrade) usando hashing de pre-autenticación SHA-512. | Rendimiento de red óptimo, soporte directo de RDMA (listo para SMB Direct), máxima seguridad de cifrado de carga útil. |

#### Tabla 3: Backends de Mapeo de Identidades (`idmap config`)

| Backend IDMap | Mecanismo | Complejidad de Configuración | Consistencia de UID/GID en Múltiples Servidores | Entorno de Operación Ideal |
| :--- | :--- | :--- | :--- | :--- |
| **`idmap_rid`** | Mapeo algorítmico: `UID = RID + base_rid`. | Baja | **100% consistencia garantizada** en todos los nodos Linux que comparten la misma configuración base `smb.conf`. | Clusters de archivos empresariales multinodo sin atributos Unix personalizados en AD. |
| **`idmap_autorid`** | Asignación dinámica de rangos: Asigna rangos de ID a los dominios automáticamente a medida que se encuentran. | Muy baja | Estado local al nodo almacenado en `idmap2.tdb`. Requiere sincronización centralizada de TDB entre los nodos del cluster. | Oficinas remotas con múltiples dominios no confiables. |
| **`idmap_ad`** | Lee atributos RFC2307 (`uidNumber`, `gidNumber`) definidos explícitamente en objetos de Active Directory. | Alta | **100% consistente** si el esquema de AD contiene Unix Attributes para todas las entidades de seguridad (security principals). | Entornos con gobernanza Unix/POSIX estricta y centralizada gestionada dentro de AD. |
| **`idmap_tdb`** | Asignación dinámica local almacenada en el `idmap.tdb` local. | Cero (Predeterminado) | **Inconsistente** en múltiples servidores. El UID para el mismo Windows SID diferirá en cada nodo. | Servidor Samba Standalone único y aislado. **Prohibido en clusters**. |

---

## 3. Manifiestos de Infraestructura de Producción y Configuraciones Completas

### 3.1 Servidor de Archivos Domain Member de Active Directory en Producción (`/etc/samba/smb.conf`)

Esta configuración aplica restricciones mínimas de SMB3.1.1, extensiones VFS para macOS, shadow copies, ajuste de rendimiento (performance tuning) y una configuración determinista de `idmap_rid`.

```ini
# /etc/samba/smb.conf
# Production Enterprise Domain Member File Server Configuration

[global]
   # ------------------------------------------------------------------
   # Network & Identity Definitions
   # ------------------------------------------------------------------
   workgroup = CORP
   realm = CORP.ENTERPRISE.INTERNAL
   netbios name = FILESRV01
   server string = Enterprise High-Performance Storage Node %v

   # Security & Domain Integration Mode
   security = ads
   role = member server
   encrypt passwords = yes

   # ------------------------------------------------------------------
   # Protocol Bounds & Encryption Security Enforcement
   # ------------------------------------------------------------------
   # Disable insecure legacy SMB1 (Mitigates WannaCry / EternalBlue vectors)
   server min protocol = SMB2_10
   server max protocol = SMB3_11
   client min protocol = SMB2_10
   client max protocol = SMB3_11

   # Security Hardening Options
   server smb encrypt = desired
   client smb encrypt = desired
   client signing = mandatory
   server signing = mandatory
   smb ports = 445

   # ------------------------------------------------------------------
   # Winbind & Identity Mapping (idmap_rid implementation)
   # ------------------------------------------------------------------
   winbind enum users = no
   winbind enum groups = no
   winbind use default domain = yes
   winbind refresh tickets = yes
   winbind offline logon = yes
   winbind nested groups = yes

   # Default Local Allocations (Fallback range for non-domain users)
   idmap config * : backend = tdb
   idmap config * : range = 10000-19999

   # Primary Active Directory Domain Range Allocation (Deterministic Mapping)
   idmap config CORP : backend = rid
   idmap config CORP : range = 20000-999999

   # Template Shell and Home directories for NSS
   template shell = /bin/bash
   template homedir = /home/%D/%U

   # ------------------------------------------------------------------
   # Performance, Socket & Threading Optimizations
   # ------------------------------------------------------------------
   aio read size = 1
   aio write size = 1
   use sendfile = yes
   min receivefile size = 16384
   getwd cache = yes
   max xmit = 65536

   # Disable NetBIOS browsing overhead (Pure DNS/AD Architecture)
   disable netbios = yes
   smb ports = 445
   dns proxy = no

   # ------------------------------------------------------------------
   # Logging & Diagnostics
   # ------------------------------------------------------------------
   log level = 1 auth:3 winbind:3
   log file = /var/log/samba/log.%m
   max log size = 50000
   logging = file

   # ------------------------------------------------------------------
   # VFS Modules Defaults
   # ------------------------------------------------------------------
   vfs objects = acl_xattr filter_acl_extended

# ======================================================================
# Share Definitions
# ======================================================================

[Engineering]
   comment = Enterprise Engineering File Share
   path = /srv/samba/shares/engineering
   read only = no
   browseable = yes
   guest ok = no
   valid users = @"CORP\Engineering_Group" @"CORP\Domain Admins"

   # Extended Attributes & NT ACL Persistence
   vfs objects = acl_xattr fruit streams_xattr shadow_copy2 full_audit

   # Apple OS X Client Optimizations (vfs_fruit)
   fruit:aapl = yes
   fruit:metadata = stream
   fruit:model = MacSamba
   fruit:posix_rename = yes
   fruit:veto_appledouble = no
   fruit:wipe_intentionally_left_blank_rf = yes
   fruit:delete_empty_adfiles = yes

   # Shadow Copy Integration (vfs_shadow_copy2)
   shadow:snapdir = .snapshots
   shadow:format = @GMT-%Y.%m.%d-%H.%M.%S
   shadow:sort = desc
   shadow:localtime = yes

   # Auditing Engine (vfs_full_audit)
   full_audit:prefix = %u|%I|%m|%S
   full_audit:success = mkdir rmdir read write rename unlink pwrite pwrite_send
   full_audit:failure = none
   full_audit:facility = LOCAL7
   full_audit:priority = NOTICE

   # File Locking & Permission Masks
   inherit acls = yes
   inherit permissions = yes
   map acl inherit = yes
   store dos attributes = yes

[Finance]
   comment = Restricted Finance Data Share
   path = /srv/samba/shares/finance
   read only = no
   browseable = no
   guest ok = no
   valid users = @"CORP\Finance_Group"
   create mask = 0660
   directory mask = 0770
   force group = "CORP\Finance_Group"
   vfs objects = acl_xattr streams_xattr
```

---

### 3.2 Configuración del Name Service Switch del Sistema (`/etc/nsswitch.conf`)

Permite que las búsquedas de usuarios y grupos POSIX consulten `winbind` después de los archivos locales.

```ini
# /etc/nsswitch.conf
passwd:         files winbind
group:          files winbind
shadow:         files
gshadow:        files

hosts:          files dns mdns4_minimal [NOTFOUND=return]
networks:       files

protocols:      db files
services:       db files
ethers:         db files
rpc:            db files

netgroup:       nis
```

---

### 3.3 Definición de Unidades de Servicio Reforzadas (Hardened) de Systemd

#### Archivo de Override `smbd.service` (`/etc/systemd/system/smbd.service.d/override.conf`)

```ini
[Unit]
Description=Samba SMB Daemon (Hardened Production Unit)
After=network.target network-online.target nss-lookup.target winbindd.service
Wants=network-online.target
Requires=winbindd.service

[Service]
Type=notify
LimitNOFILE=163840
PIDFile=/run/samba/smbd.pid
ExecStart=/usr/sbin/smbd --foreground --no-process-group $SMBDOPTIONS
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s

# Security Hardening Directives
ProtectSystem=full
ProtectHome=read-only
ReadWritePaths=/var/log/samba /var/lib/samba /var/cache/samba /run/samba /srv/samba/shares
PrivateTmp=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_SETUID CAP_SETGID CAP_DAC_OVERRIDE CAP_CHOWN CAP_FOWNER CAP_SYS_ADMIN

[Install]
WantedBy=multi-user.target
```

#### Archivo de Override `winbindd.service` (`/etc/systemd/system/winbindd.service.d/override.conf`)

```ini
[Unit]
Description=Samba Winbind Daemon
After=network.target network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=notify
PIDFile=/run/samba/winbindd.pid
ExecStart=/usr/sbin/winbindd --foreground --no-process-group $WINBINDOPTIONS
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s

# Security Hardening Directives
ProtectSystem=full
ReadWritePaths=/var/log/samba /var/lib/samba /var/cache/samba /run/samba /var/run/samba

[Install]
WantedBy=multi-user.target
```

---

### 3.4 Comandos de Configuración de Firewall en Producción

#### UFW (Ubuntu / Debian)
```bash
# Allow Direct SMB over TCP
$ sudo ufw allow 445/tcp comment 'Samba Direct SMB'

# Allow NetBIOS Services (Only if disable netbios = no)
$ sudo ufw allow 137/udp comment 'Samba NetBIOS Name Service'
$ sudo ufw allow 138/udp comment 'Samba NetBIOS Datagram Service'
$ sudo ufw allow 139/tcp comment 'Samba NetBIOS Session Service'

# Reload Firewall Rules
$ sudo ufw reload
```

#### Firewalld (RHEL / Rocky Linux / Fedora)
```bash
# Add permanent samba service definition to active zone
$ sudo firewall-cmd --permanent --add-service=samba
$ sudo firewall-cmd --reload
```

---

## 4. Ejecución en Producción: Comandos CLI Reales y Salidas de Terminal

### 4.1 Validación de Sintaxis con `testparm`

`testparm` analiza el archivo `smb.conf`, verifica los parámetros de configuración y vuelca la matriz de procesamiento operacional.

```bash
$ testparm -s --suppress-prompt /etc/samba/smb.conf
```
```text
Load smb config files from /etc/samba/smb.conf
Loaded services file OK.
Weak setup is: None
Server role: ROLE_DOMAIN_MEMBER

# Section expansion options:
[global]
	client max protocol = SMB3_11
	client min protocol = SMB2_10
	client signing = required
	disable netbios = Yes
	idmap config corp : range = 20000-999999
	idmap config corp : backend = rid
	idmap config * : range = 10000-19999
	idmap config * : backend = tdb
	log level = 1 auth:3 winbind:3
	realm = CORP.ENTERPRISE.INTERNAL
	security = ADS
	server max protocol = SMB3_11
	server min protocol = SMB2_10
	server signing = required
	smb ports = 445
	workgroup = CORP
	vfs objects = acl_xattr filter_acl_extended

[Engineering]
	browseable = Yes
	comment = Enterprise Engineering File Share
	full_audit:facility = LOCAL7
	full_audit:failure = none
	full_audit:prefix = %u|%I|%m|%S
	full_audit:priority = NOTICE
	full_audit:success = mkdir rmdir read write rename unlink pwrite pwrite_send
	path = /srv/samba/shares/engineering
	read only = No
	valid users = @"CORP\Engineering_Group", @"CORP\Domain Admins"
	vfs objects = acl_xattr fruit streams_xattr shadow_copy2 full_audit
	fruit:delete_empty_adfiles = yes
	fruit:wipe_intentionally_left_blank_rf = yes
	fruit:posix_rename = yes
	fruit:model = MacSamba
	fruit:metadata = stream
	fruit:aapl = yes
```

---

### 4.2 Gestión de Passdb SAM Local con `pdbedit`

Para servidores standalone (`security = user`), `pdbedit` gestiona el backend Passdb (`passdb.tdb`).

```bash
# Add a new local Samba user (User must already exist in /etc/passwd)
$ sudo pdbedit -a -u sreadmin -r
```
```text
new password:
retype new password:
Unix username:        sreadmin
NT username:          
Account Flags:        [U          ]
User SID:             S-1-5-21-3849204912-1029384910-482910394-1001
Primary Group SID:    S-1-5-21-3849204912-1029384910-482910394-513
Full Name:            SRE Administrator Account
Home Directory:       \\FILESRV01\sreadmin
Home Dir Drive:       
Logon Script:         
Profile Path:         \\FILESRV01\sreadmin\profile
Domain:               FILESRV01
Account must change password: No
Expected password must change: Never
```

```bash
# Verbose listing of all passdb entries
$ sudo pdbedit -L -v
```
```text
-----------------------------------------
Unix username:        sreadmin
NT username:          
Account Flags:        [U          ]
User SID:             S-1-5-21-3849204912-1029384910-482910394-1001
Primary Group SID:    S-1-5-21-3849204912-1029384910-482910394-513
Full Name:            SRE Administrator Account
Home Directory:       \\FILESRV01\sreadmin
Password last set:    Thu, 06 Aug 2026 10:15:30 EDT
Password can change:  Thu, 06 Aug 2026 10:15:30 EDT
Password must change: Never
Last logon:           N/A
Logon failure count:  0
-----------------------------------------
```

---

### 4.3 Unión al Dominio de Active Directory y Verificación con `net`

```bash
# Request Kerberos ticket for AD Admin
$ kinit Administrator@CORP.ENTERPRISE.INTERNAL
```
```text
Password for Administrator@CORP.ENTERPRISE.INTERNAL:
```

```bash
# Join Active Directory domain using net ads
$ sudo net ads join -U Administrator
```
```text
Using short domain name -- CORP
Joined 'FILESRV01' to dns domain 'corp.enterprise.internal'
No DNS domain configured for filesrv01. Unable to perform DNS Update.
DNS update should be performed manually or via DHCP.
```

```bash
# Test AD Trust Connection State
$ sudo net ads testjoin
```
```text
Join is OK
```

```bash
# Display Machine Account Status in Active Directory
$ sudo net ads status
```
```text
objectGUID: 8c34f8e2-892a-4f81-a982-1b837d991c01
sAMAccountName: FILESRV01$
servicePrincipalName: HOST/FILESRV01
servicePrincipalName: HOST/filesrv01.corp.enterprise.internal
servicePrincipalName: RestrictedKrbHost/FILESRV01
servicePrincipalName: RestrictedKrbHost/filesrv01.corp.enterprise.internal
pwdLastSet: 133984920194829102
userAccountControl: 4096
```

---

### 4.4 Inspección del Estado de Samba en Tiempo de Ejecución con `smbstatus`

`smbstatus` lee `locking.tdb` y `sessionid.tdb` para generar métricas en tiempo real sobre clientes conectados, versiones de protocolo activas, estados de bloqueo y handles abiertos.

```bash
$ sudo smbstatus
```
```text
Samba version 4.19.5-Ubuntu
PID     Username     Group        Machine                         Protocol Version Password Cipher Encryption Cipher 
--------------------------------------------------------------------------------------------------------------------------------
40921   jdoe         CORP\Domain  10.0.15.102 (ipv4:10.0.15.102:54821) SMB3_11           -               AES-128-GCM     

Service      pid     Machine       Connected at                     Encryption   Signing     
---------------------------------------------------------------------------------------------
Engineering  40921   10.0.15.102   Thu Aug  6 11:20:42 2026 EDT     AES-128-GCM  -           

Locked files:
Pid          User(O/U)           Uid        Gid        Mode             TCPAddr          Access Mask    Type         Oplock           EA Key             Path
----------------------------------------------------------------------------------------------------------------------------------------------------------------
40921        20015               20015      20002      RDWR             10.0.15.102      0x12019f       POSIX        LEASE(RWA)       -                  /srv/samba/shares/engineering/CAD_Schematics_v2.dwg
```

---

### 4.5 Comprobaciones de Resolución de Identidad de Winbind (`wbinfo` y `getent`)

```bash
# Check winbind ping response to DC
$ wbinfo -p
```
```text
Ping to winbindd succeeded
```

```bash
# Query AD User SID to Linux UID via idmap_rid backend
$ wbinfo -n "CORP\jdoe"
```
```text
S-1-5-21-3849204912-1029384910-482910394-1105 SID_USER (1)
```

```bash
# Convert SID to allocated Linux UID
$ wbinfo -s S-1-5-21-3849204912-1029384910-482910394-1105
```
```text
CORP\jdoe 1
```

```bash
# Verify system NSS integration via getent
$ getent passwd "CORP\jdoe"
```
```text
jdoe:*:21105:20000:John Doe:/home/CORP/jdoe:/bin/bash
```

---

### 4.6 Conectividad de Protocolo de Cliente y Pruebas con `smbclient`

```bash
# Query available SMB shares on target host enforcing SMB3 protocol
$ smbclient -L //FILESRV01.CORP.ENTERPRISE.INTERNAL -U "CORP\jdoe" -m SMB3
```
```text
Password for [CORP\jdoe]:

	Sharename       Type      Comment
	---------       ----      -------
	Engineering     Disk      Enterprise Engineering File Share
	IPC$            IPC       IPC Service (Enterprise High-Performance Storage Node v4.19)
SMB1 trading is disabled. Suppress This Array: SMB1 disabled

Reconnecting with SMB3...
Server exit code 0
```

```bash
# Interactively connect to an encrypted share
$ smbclient //FILESRV01.CORP.ENTERPRISE.INTERNAL/Engineering -U "CORP\jdoe" -e
```
```text
Password for [CORP\jdoe]:
Try "help" to get a list of possible commands.
smb: \> ls
  .                                   D        0  Thu Aug  6 11:20:42 2026
  ..                                  D        0  Thu Aug  6 10:00:00 2026
  CAD_Schematics_v2.dwg               A  1485920  Thu Aug  6 11:15:20 2026

                524160000 blocks of size 1024. 312849200 blocks available
smb: \> quit
```

---

### 4.7 Herramientas de Inspección y Reparación de Bases de Datos TDB a Bajo Nivel

```bash
# Backup volatile locking database safely while smbd is running
$ sudo tdbbackup /var/lib/samba/locking.tdb
```
```text
/var/lib/samba/locking.tdb.bak : 1048576 bytes
```

```bash
# Check integrity of persistent passdb database
$ sudo tdbtool /var/lib/samba/private/passdb.tdb check
```
```text
Database integrity is OK
```

```bash
# Dump keys contained within a TDB database
$ sudo tdbdump /var/lib/samba/account_policy.tdb
```
```text
key(23) = "min password length\00"
data(4) = "\0a\00\00\00"
key(21) = "password history\00"
data(4) = "\00\00\00\00"
```

---

## 5. Guía de Solución de Problemas, Verificación y Diagnóstico de Fallas

### 5.1 Árbol de Decisión del Flujo de Trabajo de Diagnóstico en Producción

```
                      +------------------------------------------+
                      |   Client SMB Connection / Auth Failure   |
                      +------------------------------------------+
                                           |
                                           v
                     +--------------------------------------------+
                     |  Can client reach TCP Port 445 via network?|
                     +--------------------------------------------+
                               /                        \
                             NO                          YES
                             /                            \
                            v                              v
            +-------------------------------+    +----------------------------------+
            | Check iptables / firewalld /  |    | Is Samba service running?        |
            | UFW rules & physical routing  |    | Check systemctl status smbd      |
            +-------------------------------+    +----------------------------------+
                                                           /                  \
                                                         NO                    YES
                                                         /                      \
                                                        v                        v
                                        +-----------------------+  +-------------------------------+
                                        | Check /var/log/samba/ |  | Does testparm raise syntax    |
                                        | log.smbd for binding  |  | errors in /etc/samba/smb.conf?|
                                        | or socket errors      |  +-------------------------------+
                                        +-----------------------+            /           \
                                                                           YES            NO
                                                                           /                \
                                                                          v                  v
                                                         +--------------------+    +-----------------------+
                                                         | Fix smb.conf syntax|    | Run diagnostic tests: |
                                                         | and reload daemon  |    | wbinfo -p & net ads   |
                                                         +--------------------+    | testjoin              |
                                                                                   +-----------------------+
```

---

### 5.2 Escenarios de Diagnóstico y Protocolos de Remediación

#### Escenario A: Falla en el ID Mapping de Winbind (`NT_STATUS_UNSUCCESSFUL` o `No such user`)
* **Síntoma:** Los usuarios de Active Directory se autentican con éxito a través de SMB, pero fallan al leer/escribir en los shares del sistema de archivos. `ls -l` muestra SIDs numéricos en bruto o propiedad asignada a `nobody` o `10000`.
* **Análisis de Causa Raíz:** `winbindd` no puede ejecutar la traducción de SID a UID debido a rangos de `idmap config` mal configurados o al agotamiento de rangos en `idmap config CORP : range`.
* **Ejecución del Diagnóstico:**
  ```bash
  # 1. Check Winbind operational state
  $ sudo wbinfo -p
  
  # 2. Trace SID allocation for failing user
  $ sudo wbinfo -n "CORP\user1"
  # Returns: S-1-5-21-3849204912-1029384910-482910394-985000

  # 3. Check allocated UID
  $ sudo wbinfo -s S-1-5-21-3849204912-1029384910-482910394-985000
  # Error: WBC_ERR_DOMAIN_NOT_FOUND or failed to convert SID
  ```
* **Protocolo de Remediación:**
  1. Inspeccionar `smb.conf`. Calcular el offset de rango requerido para `idmap_rid`:
     $$\text{RID} = 985000$$
     Si `idmap config CORP : range = 20000-999999`, entonces:
     $$\text{UID} = 20000 + 985000 = 1005000$$
     *Falla:* El UID calculado ($1,005,000$) excede el límite máximo del rango ($999,999$).
  2. Incrementar el límite superior del rango de dominio en `/etc/samba/smb.conf`:
     ```ini
     idmap config CORP : range = 20000-2000000
     ```
  3. Limpiar la caché de ID map de winbind y reiniciar los servicios:
     ```bash
     $ sudo net cache flush
     $ sudo systemctl restart winbindd smbd
     ```

---

#### Escenario B: Corrupción de Base de Datos TDB Volátil (`locking.tdb`)
* **Síntoma:** Los procesos `smbd` se bloquean al 100% de uso de CPU. Los usuarios reportan bloqueos severos de I/O o errores `NT_STATUS_FILE_LOCK_CONFLICT` al acceder a archivos desprotegidos existentes.
* **Análisis de Causa Raíz:** Un reinicio forzado del nodo (hard node reset) o una falla de energía en el almacenamiento de alta concurrencia corrompió las cadenas de hash de registros dentro de `/var/lib/samba/locking.tdb`.
* **Ejecución del Diagnóstico:**
  ```bash
  # Inspect log.smbd for TDB panic traces
  $ sudo tail -n 50 /var/log/samba/log.smbd
  ```
  ```text
  [2026/08/06 11:45:12.102839,  0] ../../lib/util/fault.c:171(smb_panic_default)
    INTERNAL ERROR: Signal 11 in ping_message child process
  [2026/08/06 11:45:12.103001,  0] ../../source3/lib/dbwrap/dbwrap_tdb.c:75(db_tdb_fetchv)
    tdb_fetchv failed for hash chain 402 in /var/lib/samba/locking.tdb: Bad database format
  ```
* **Protocolo de Remediación:**
  1. Detener los demonios de Samba:
     ```bash
     $ sudo systemctl stop smbd nmbd winbindd
     ```
  2. Realizar la comprobación de verificación de TDB:
     ```bash
     $ sudo tdbtool /var/lib/samba/locking.tdb check
     # Output: Database integrity failed: 1 corrupted record found
     ```
  3. Dado que `locking.tdb` almacena estado volátil, eliminar de forma segura el archivo corrompido (Samba volverá a crear una base de datos limpia automáticamente al iniciar):
     ```bash
     $ sudo rm -f /var/lib/samba/locking.tdb
     $ sudo rm -f /var/lib/samba/brlock.tdb
     ```
  4. Iniciar los demonios de Samba:
     ```bash
     $ sudo systemctl start winbindd smbd
     ```

---

#### Escenario C: Incompatibilidad en la Traducción de ACL de Atributos Extendidos de Windows (`Access Denied`)
* **Síntoma:** Los Domain Admins de AD reciben `Access Denied` al modificar la pestaña de permisos de seguridad de Windows en un SMB share, a pesar de que la propiedad POSIX permite acceso de escritura a root.
* **Análisis de Causa Raíz:** El sistema de archivos POSIX subyacente se montó sin soporte para atributos extendidos, o el atributo `security.NTACL` no se puede escribir debido a la falta del módulo VFS `acl_xattr`.
* **Ejecución del Diagnóstico:**
  ```bash
  # Check mount options for target share volume
  $ mount | grep /srv/samba/shares
  # Output: /dev/sdb1 on /srv/samba/shares type ext4 (rw,relatime,nouser_xattr)
  ```
* **Protocolo de Remediación:**
  1. Volver a montar el sistema de archivos con soporte para atributos extendidos:
     ```bash
     $ sudo mount -o remount,user_xattr /srv/samba/shares
     ```
  2. Verificar manualmente la capacidad de lectura/escritura de atributos extendidos POSIX:
     ```bash
     $ sudo setfattr -n user.test -v "samba_test" /srv/samba/shares/engineering
     $ sudo getfattr -n user.test /srv/samba/shares/engineering
     # Output: user.test="samba_test"
     $ sudo setfattr -x user.test /srv/samba/shares/engineering
     ```
  3. Asegurar que `vfs objects = acl_xattr` esté configurado en `[global]` o a nivel de share en `/etc/samba/smb.conf`.
  4. Recargar la configuración de Samba:
     ```bash
     $ sudo smbcontrol smbd reload-config
     ```

---

## 6. Referencias

* **Objetivos Oficiales de LPIC-3 300 de Linux Professional Institute (LPI):**
  https://www.lpi.org/our-certifications/lpic-3-300-overview/
* **Documentación Oficial y Manual de Referencia de Samba (`smb.conf`):**
  https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html
* **Samba Wiki — Configuración de Active Directory Domain Member:**
  https://wiki.samba.org/index.php/Setting_up_Samba_as_a_Domain_Member
* **Samba Wiki — Mapeo de Identidades (idmap_rid / idmap_ad):**
  https://wiki.samba.org/index.php/Identity_Management
* **Documentación de Módulos VFS de Samba (`vfs_acl_xattr`, `vfs_fruit`, `vfs_shadow_copy2`):**
  https://www.samba.org/samba/docs/current/man-html/vfs_acl_xattr.8.html
  https://www.samba.org/samba/docs/current/man-html/vfs_fruit.8.html