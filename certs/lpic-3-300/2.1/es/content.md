# LPIC-3 Examen 300-300 (v3.0): Tema 2.1 – Dominios Samba y Active Directory

---

## 1. Motivación de Arquitectura y Planteamiento del Problema en Producción

### 1.1 El Desafío del Plano de Control e Identidad Empresarial
Las infraestructuras empresariales híbridas modernas exigen un plano de control de autenticación, autorización y directorio unificado en sistemas operativos heterogéneos (Linux/POSIX y Microsoft Windows). Las organizaciones que operan infraestructuras multi-cloud o local (on-premises) enfrentan severa fricción operativa y de seguridad cuando la identidad se fragmenta en silos aislados (por ejemplo, `/etc/passwd` local, OpenLDAP independiente o proveedores de IAM en la nube sin federación Kerberos). 

Active Directory Domain Services (AD DS) sirve como la arquitectura de directorio multimaestro de facto, utilizando protocolos de red estándar:
- **Kerberos v5 (RFC 4120 / RFC 4556):** Proporciona autenticación mutua, servicio de concesión de tickets (TGS) y inicio de sesión único (SSO) sin transmitir contraseñas en texto plano a través de la red.
- **LDAPv3 (RFC 4511) & Simple Auth and Security Layer (SASL / RFC 4422):** Proporciona consultas de directorio estructuradas, listas de control de acceso (ACLs) y jerarquías de objetos.
- **Domain Name System (DNS - RFC 1035 / RFC 2782):** Sirve como el servicio de ubicación dinámica a través de registros canónicos `SRV` y `TXT` permitiendo el descubrimiento del Centro de Distribución de Claves (KDC) Kerberos y del servidor LDAP.
- **DCE/RPC & MS-RPC (Microsoft Remote Procedure Call):** Proporciona llamadas de interfaz administrativa para la gestión del dominio, replicación de usuarios, aplicación de políticas de seguridad y traducción de SID (Security Identifier).

Samba en modo Active Directory Domain Controller (Samba AD DC) implementa un motor de código abierto totalmente compatible con MS-ADTS (Active Directory Technical Specification) y MS-DRSR (Directory Replication Service Remote Protocol). Elimina la necesidad de controladores de dominio propietarios al tiempo que mantiene una paridad de protocolo transparente para clientes Windows, miembros del dominio Linux y herramientas de puente de identidad en la nube.

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

### 1.2 Componentes Principales de la Arquitectura de Samba AD DC

1. **LDB (LDAP-like Database System):**
   - Samba reemplaza los motores de base de datos SQL o Berkeley Database estándar con **LDB**, un almacén clave-valor embebido optimizado para atributos LDAP y archivos de backend TDB (Trivial Database).
   - Las bases de datos residen en `/var/lib/samba/private/`:
     - `sam.ldb`: Contiene las particiones de dominio de Active Directory (Domain NC, Configuration NC, Schema NC).
     - `sam.ldb.d/`: Sub-bases de datos específicas de partición (`DC=DOM,DC=COM.ldb`, `CN=CONFIGURATION...ldb`, `CN=SCHEMA...ldb`).
     - `idmap.ldb`: Mapea los SIDs de Active Directory (`S-1-5-21-...`) a UIDs y GIDs locales de POSIX.
     - `secrets.ldb`: Almacena las contraseñas de cuentas de máquina de servicios locales y claves Kerberos.

2. **Flexible Single Master Operation (FSMO) Roles:**
   Active Directory opera principalmente como un sistema multimaestro, pero cinco operaciones específicas requieren autoridad estricta de maestro único para evitar condiciones de split-brain:
   - **Roles para todo el Bosque (Forest-wide Roles):**
     1. *Schema Master:* Controla las modificaciones al esquema LDAP (`CN=Schema,CN=Configuration...`).
     2. *Domain Naming Master:* Controla la adición o eliminación de dominios dentro del bosque.
   - **Roles para todo el Dominio (Domain-wide Roles):**
     3. *PDC Emulator:* Maneja actualizaciones de contraseñas, sincronización de tiempo (NTP), fallback de autenticación NTLM legada y ediciones de GPO.
     4. *RID Master:* Asigna pools de Identificadores Relativos (RIDs) a los Domain Controllers para la construcción de SIDs (`SID = Domain SID + RID`).
     5. *Infrastructure Master:* Traduce referencias de objetos entre dominios (SIDs a DNs).

3. **Directory Replication Service Protocol (DRSUAPI):**
   Samba AD DC utiliza el DRSUAPI nativo de Microsoft sobre DCE/RPC para realizar la replicación de directorio peer-to-peer con DCs de Windows Server o DCs secundarios de Samba. La replicación se divide a través de Contextos de Nombres (NCs) estándar:
   - **Domain NC:** Contiene usuarios, grupos, computadoras y unidades organizativas (OUs).
   - **Configuration NC:** Contiene la topología empresarial, límites de sitios y servicios RPC.
   - **Schema NC:** Contiene definiciones de clases y atributos para cada objeto en el bosque.
   - **DomainDnsZones / ForestDnsZones NCs:** Contiene datos de zonas DNS integradas y actualizaciones dinámicas.

---

## 2. Tablas de Comparación Técnica y Trade-offs

### 2.1 Comparación de Arquitectura de Integración e Identidad

| Métrica de Arquitectura | Samba 4 AD DC | Samba Domain Member (Winbind) | SSSD Domain Member | FreeIPA / Red Hat IdM |
| :--- | :--- | :--- | :--- | :--- |
| **Rol Primario** | Identity Provider / KDC / Domain Controller | File/Print Server adjunto a AD | Client Auth / POSIX Enforcer | Linux-Native Identity Provider |
| **Capacidad de AD Forest Trust** | Soportado (Trusts de bosque y dominio vía `samba-tool`) | N/A (Se une a AD existente) | N/A (Se une a AD existente) | Cross-Forest Trust con AD |
| **Motor Kerberos KDC** | Integrado (Heimdal / MIT integrado) | Usa KDC externo (AD) | Usa KDC externo (AD) | MIT Kerberos KDC nativo |
| **Almacenamiento de Directorio** | LDB embebido (respaldado por TDB) | Caché local (`winbindd_cache.tdb`) | Caché local de SSSD (LDB) | 389 Directory Server (basado en OpenLDAP) |
| **Compartición de Archivos (SMB3/CIFS)** | Soportado (con limitaciones en módulos VFS) | Soporte empresarial completo (NTFS ACLs, VFS, Ceph/Gluster) | Acceso SMB manejado vía Samba, Autenticación vía SSSD | Requiere integración con Samba |
| **Generación de UID/GID POSIX** | Mapeo de ID integrado (`idmap.ldb` o RFC 2307) | Configurable (`idmap_rid`, `idmap_ad`, `idmap_autorid`) | Algorítmico integrado o atributos explícitos de AD | Esquema POSIX nativo (`uidNumber`, `gidNumber`) |
| **Procesamiento de Group Policy (GPO)** | Alojar y replicar GPOs (`SYSVOL`) | Aplicar políticas de cliente (`samba-gpupdate`) | Aplicación limitada de control de acceso por GPO | Políticas IPA nativas (HBAC, Sudo) |

### 2.2 Backends de Integración DNS para Samba AD DC

| Característica / Trade-Off | `SAMBA_INTERNAL` DNS | `BIND9_DLZ` (Dynamic Link Zone) |
| :--- | :--- | :--- |
| **Complejidad de Implementación** | Configuración cero; integrado directamente en el binario `samba`. | Requiere instalación de BIND 9, inclusión en `named.conf` y carga del módulo DLZ. |
| **Soporte DNSSEC** | Básico / Limitado. | Firma, validación y gestión de claves DNSSEC completas de grado de producción. |
| **Rendimiento y Escala** | Adecuado para entornos de tamaño pequeño a mediano (< 5,000 objetos). | Escala empresarial de alto rendimiento (> 50,000 consultas/seg), enrutamiento de vistas avanzado. |
| **Actualizaciones Dinámicas (TSIG/GSS-TSIG)** | Completamente soportado de forma nativa vía Kerberos (`gss-tsig`). | Completamente soportado vía controlador de plugin Samba DLZ (`dlz_bind9.so`). |
| **Reenvío de Zonas Externas** | Configurable vía parámetro `dns forwarder` en `smb.conf`. | Bloque `forwarders {}` estándar de BIND 9 con ACLs, transferencias de zona y split-horizon. |
| **Aislamiento de Procesos** | Se ejecuta dentro del bucle de proceso principal de Samba. | Espacio de proceso separado (`named`); la caída del demonio DNS no impacta a KDC/LDAP. |

### 2.3 Backends de Mapeo de Identidad POSIX (idmap) para Miembros del Dominio

| Módulo Backend | Mecanismo de Mapeo | ¿Determinista entre Hosts? | ¿Requiere Modificación de Esquema AD? | Mejor Caso de Uso en Producción |
| :--- | :--- | :--- | :--- | :--- |
| **`idmap_rid`** | $\text{UID} = \text{RID} - \text{Low Range} + \text{Base UID}$ | Sí (Derivado algorítmicamente del RID del SID del dominio) | No | Entornos puros de Active Directory sin esquemas UNIX legados. |
| **`idmap_ad`** | Lee `uidNumber` y `gidNumber` explícitos de los objetos de AD. | Sí (Almacenado centralmente en AD) | Sí (Requiere extensiones RFC 2307 / NIS pobladas) | Entornos migrando de instalaciones legadas LDAP/UNIX con UIDs predefinidos. |
| **`idmap_autorid`** | Asigna rangos de ID dinámicamente por dominio descubierto. | Sí (Almacenado en base de datos local, replicado entre instancias) | No | Bosques multi-dominio sin administración central de RFC 2307. |
| **`idmap_hash`** | Hash criptográfico del SID a entero de 32 bits. | Sí | No | Compatibilidad con sistemas legados (obsoleto en compilaciones modernas de Samba). |

---

## 3. Configuraciones de Producción y Manifiestos de Infraestructura

### 3.1 Configuración Completa de Samba AD DC (`/etc/samba/smb.conf`)

El siguiente manifiesto representa una configuración completamente válida y sin truncar para un Samba Active Directory Domain Controller que utiliza BIND9 DLZ, puertos RPC dinámicos, atributos POSIX de RFC 2307 y firma SMB segura.

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

### 3.2 Configuración del Cliente Kerberos v5 del Sistema (`/etc/krb5.conf`)

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

### 3.3 Configuración Empresarial de BIND 9 para Samba DLZ (`/etc/bind/named.conf.local`)

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

### 3.4 Configuración de Miembro del Dominio Samba (`/etc/samba/smb.conf`)

Esta configuración demuestra un servidor de archivos blindado configurado como Miembro del Dominio utilizando `idmap_rid`.

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

## 4. Flujos Reales de Ejecución CLI y Salidas Realistas ($)

### 4.1 Aprovisionar un Nuevo Samba Active Directory Domain Controller

El comando `samba-tool domain provision` inicializa las bases de datos LDB, genera el keytab de Kerberos, configura SYSVOL y establece las zonas DNS iniciales.

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

### 4.2 Unir un Samba Domain Controller Secundario a un Bosque Existente

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

### 4.3 Inspección y Transferencia de Roles FSMO

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

Transfiriendo el rol de PDC Emulator al controlador secundario `DC02`:

```bash
$ sudo samba-tool fsmo transfer --role=pdc -U"ENTERPRISE\Administrator" --password='Str0ngP@ssw0rd!2026'
```

```text
FSMO transfer of 'pdc' role requested
FSMO transfer of 'pdc' role successful.
PdcEmulationMasterRole owner changed to CN=NTDS Settings,CN=DC02,CN=Servers,CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=ad,DC=enterprise,DC=internal
```

---

### 4.4 Inspección del Estado de Replicación de Directorio (DRSUAPI)

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

### 4.5 Administración de Usuarios y Grupos en Active Directory

Creando un usuario con atributos POSIX RFC 2307:

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

Creando un Security Group y añadiendo el usuario:

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

### 4.6 Consultar el Directorio a Través de Herramientas LDB de Bajo Nivel (`ldbsearch`)

`ldbsearch` permite consultar directamente la base de datos `sam.ldb` subyacente sin pasar por la pila LDAP de red estándar.

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

### 4.7 Unión de Miembro del Dominio (`net ads join`) y Verificación de Winbind

Uniendo un servidor de archivos Linux al dominio:

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

Verificando la resolución de identidad vía Winbind:

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

## 5. Matriz de Verificación en Producción y Diagnóstico de Fallas

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

### 5.1 Diagnóstico Profundo y Procedimientos de Respuesta a Incidentes

#### Escenario 1: Falla de Replicación de Directorio (Error `DRSUAPI` / RPC No Disponible)
- **Síntoma:** `samba-tool drs showrepl` indica `WERR_BUSY` o `NT_STATUS_UNSUCCESSFUL` entre los Domain Controllers.
- **Análisis de Causa Raíz:**
  1. Desviación de tiempo / desfasaje de reloj (clock skew) superior a 300 segundos que rompe la validez del ticket Kerberos entre DCs.
  2. Firewall bloqueando los rangos de puertos dinámicos DCE/RPC (Puerto 135 + Puertos Efímeros 1024-65535 o `rpc server port` configurado estáticamente).
  3. Descoincidencia de GUID de LDB tras una restauración no limpia de snapshot de un DC virtualizado.
- **Comandos de Remediación:**
  ```bash
  # Step 1: Force Time Sync using ntpdate / chrony against PDC Emulator
  $ sudo chronyd -q 'server dc01.ad.enterprise.internal iburst'

  # Step 2: Trigger manual replication forcing full sync of Domain NC
  $ sudo samba-tool drs replicate dc02.ad.enterprise.internal dc01.ad.enterprise.internal DC=ad,DC=enterprise,DC=internal --full-sync

  # Step 3: Check database consistency across partitions
  $ sudo samba-tool dbcheck --cross-ncs
  ```

#### Escenario 2: Error de Desfasaje de Reloj de Kerberos (`KRB_AP_ERR_SKEW`)
- **Síntoma:** Los clientes fallan al autenticar con el error `Clock skew too great`.
- **Causa Raíz:** El protocolo Kerberos de Active Directory impone una diferencia máxima de reloj de 5 minutos (300 segundos) entre el cliente, el Domain Controller y el servicio de destino para prevenir ataques de repetición (replay attacks).
- **Remediación:**
  Asegurar que el Samba DC ejecute `systemd-timesyncd` o `chrony` configurado con permisos de socket `ntp signd` habilitados para Samba:
  ```ini
  # /etc/chrony/chrony.conf snippet
  ntpsigndsocket /var/lib/samba/ntp_signd
  ```
  Corregir los permisos del directorio:
  ```bash
  $ sudo chown root:chrony /var/lib/samba/ntp_signd
  $ sudo chmod 0750 /var/lib/samba/ntp_signd
  ```

#### Escenario 3: Desviación de Sincronización de SYSVOL Entre Samba DCs
- **Síntoma:** Los objetos de directiva de grupo (GPOs) creados en DC01 no se aplican a los clientes que se autentican contra DC02.
- **Causa Raíz:** A diferencia de Microsoft Windows Server (que utiliza DFS-R), Samba no implementa nativamente replicación automatizada a nivel de kernel del sistema de archivos SYSVOL.
- **Solución en Producción:** Implementar `rsync` bidireccional sobre SSH con preservación estricta de ACLs POSIX (`--acls --xattrs`), o utilizar mecanismos de sistema de archivos distribuido tales como CTDB / GlusterFS / Ceph para alojamiento de SYSVOL en clúster.
- **Comando Manual de Restablecimiento de SYSVOL:**
  ```bash
  $ sudo samba-tool ntacl sysvolreset
  ```

#### Escenario 4: Corrupción de Base de Datos LDB y Recolección de Basura Tombstone
- **Síntoma:** Samba no inicia con `LDB Transaction error` o la búsqueda de objetos falla con errores de índice corrupto.
- **Procedimiento de Remediación:**
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

## 6. Referencias

- **Objetivos Oficiales del Examen de Linux Professional Institute (LPI):**
  [LPIC-3 Exam 300 Objectives & Overview](https://www.lpi.org/our-certifications/lpic-3-300-overview/)
- **Documentación Oficial de Samba y Guías Wiki de AD DC:**
  [Samba AD DC HOWTO & Architecture Guides](https://wiki.samba.org/index.php/Setting_up_Samba_as_an_Active_Directory_Domain_Controller)
- **Especificaciones Técnicas de Samba e Integración con BIND9:**
  [Samba BIND9 DLZ Module Configuration](https://wiki.samba.org/index.php/BIND9_DLZ_DNS_Back_End)
- **Especificaciones Técnicas de Microsoft Active Directory (MS-ADTS):**
  [Microsoft Docs: MS-ADTS Active Directory Technical Specification](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-adts/)
- **Microsoft Directory Replication Service Remote Protocol (MS-DRSR):**
  [Microsoft Docs: MS-DRSR Specification](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-drsr/)
- **IETF RFC 4120 - El Servicio de Autenticación de Red Kerberos (V5):**
  [IETF RFC 4120 Specification](https://datatracker.ietf.org/doc/html/rfc4120)
- **IETF RFC 2782 - Un RR DNS para especificar la ubicación de servicios (DNS SRV):**
  [IETF RFC 2782 Specification](https://datatracker.ietf.org/doc/html/rfc2782)