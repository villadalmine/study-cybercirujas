# Examen LPIC-3 300-300 (v3.0) — Tema 305: Gestión de Identidad y Compartición de Archivos en Linux

## Fuentes Oficiales de Referencia
* [Objetivos y Visión General Oficiales de LPI LPIC-3 300](https://www.lpi.org/our-certifications/lpic-3-300-overview/)
* [Documentación Técnica y Arquitectura de FreeIPA](https://www.freeipa.org/page/Documentation)
* [Guías Técnicas del Demonio de Servicios de Seguridad del Sistema SSSD](https://sssd.io/docs/design_pages/index.html)
* [Especificación y Administración de Network File System (NFSv4) del Kernel de Linux](https://nfs.sourceforge.net/)
* [Guía del Administrador de MIT Kerberos V5](https://web.mit.edu/kerberos/krb5-latest/doc/admin/index.html)

---

## 1. Arquitectura Profunda y Mecánica Interna

### 1.1 Motor Integrado de Servicios Centrales de FreeIPA
FreeIPA sirve como un framework de gestión de identidad, políticas y auditoría de nivel empresarial. En lugar de reinventar componentes de seguridad fundamentales, orquesta cuatro protocolos y demonios principales de código abierto:

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

1. **389 Directory Server (Motor LDAP)**: Opera como el almacén central de la base de datos de identidades. FreeIPA aprovecha esquemas LDAP personalizados (el plugin `slapi-nis` para compatibilidad heredada, el plugin `memberof` para resolución dinámica de grupos y módulos de extensión de esquema para la asignación de principales de Kerberos).
2. **KDC de MIT Kerberos (Motor de Autenticación)**: Proporciona una arquitectura de concesión de tickets para inicio de sesión único (SSO). El módulo de base de datos de Kerberos (`kdb_ldap`) se engancha directamente a 389 Directory Server, eliminando la sobrecarga de sincronización de bases de datos entre los listados del directorio y los secretos de los principales de Kerberos.
3. **Dogtag PKI (Autoridad de Certificación)**: Gestiona el ciclo de vida de los certificados X.509, la emisión automatizada a través de los protocolos SCEP/EST, el enrolamiento de tarjetas inteligentes y la verificación de la identidad de los servicios a través de los nodos.
4. **BIND9 DNS (Descubrimiento de Servicios y Seguridad)**: Se integra directamente con 389-ds a través del plugin `bind-dyndb-ldap`. Expone dinámicamente registros SRV de Kerberos (`_kerberos._tcp.EXAMPLE.COM`) y LDAP (`_ldap._tcp.EXAMPLE.COM`), al tiempo que aprovecha `GSS-TSIG` (actualizaciones DNS autenticadas por Kerberos) para garantizar la creación dinámica de registros a prueba de manipulaciones durante el enrolamiento de clientes.

---

### 1.2 Ciclo de Vida de los Tickets de Kerberos y Arquitectura de Caching de SSSD

#### Mecánica de Autenticación de Kerberos
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

1. **AS-REQ / AS-REP (Intercambio del Servicio de Autenticación)**: El cliente del usuario envía una solicitud `AS-REQ` que contiene su nombre de principal de usuario (UPN) al puerto 88. El KDC verifica la identidad del usuario contra LDAP, cifra un Ticket Granting Ticket (TGT) utilizando la clave secreta del cliente (derivada de la contraseña/keytab mediante algoritmos de sal string-to-key) y devuelve una respuesta `AS-REP`.
2. **TGS-REQ / TGS-REP (Intercambio del Servicio de Concesión de Tickets)**: Para acceder a un servicio con Kerberos habilitado (por ejemplo, `nfs/storage.example.com`), el cliente presenta su TGT en una solicitud `TGS-REQ`. El KDC emite un Service Ticket cifrado con la clave secreta del principal del servicio destino (`TGS-REP`).
3. **AP-REQ / AP-REP (Intercambio de Aplicación)**: El cliente presenta el Service Ticket directamente al demonio destino. El demonio descifra el ticket utilizando su archivo keytab local (`/etc/krb5.keytab`), demostrando la identidad del cliente sin transmitir credenciales a través de la red.

#### Arquitectura de SSSD (System Security Services Daemon)
SSSD actúa como el agente de acceso local en clientes Linux, reduciendo el tráfico de consultas a KDC/LDAP y habilitando la autenticación offline a través de cachés en bases de datos locales (LDB):

* **Respondedor NSS (`sssd_nss`)**: Se engancha a NSS de glibc a través de `libnss_sss.so` para resolver identidades POSIX (`getpwnam`, `getgrnam`).
* **Respondedor PAM (`sssd_pam`)**: Se engancha a PAM a través de `pam_sss.so` para gestionar la autenticación, cambios de contraseña y políticas de control de acceso (HBAC).
* **Motor de Almacenamiento LDB**: Almacena definiciones de identidad, atributos de usuario, reglas de sudo y hashes de contraseñas localmente dentro de `/var/lib/sss/db/`. Los archivos mapeados en memoria (`/var/lib/sss/mc/`) proporcionan cachés de búsqueda rápida sin IPC para consultas de identidad.

---

### 1.3 Arquitectura de NFSv4, RPCSEC_GSS y Mecánica de Idmapping

NFSv4 es un protocolo con estado de un solo puerto (TCP 2049) que cuenta con un espacio de nombres de pseudosistema de archivos unificado. A diferencia de NFSv3, elimina los demonios fuera de banda (`rpc.mountd`, `statd`, `lockd`).

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

* **Protocolo de Idmapping (`nfsidmap` / `rpc.idmapd`)**: Los protocolos de red de NFSv4 transmiten cadenas de identidad de usuario/grupo en el formato `user@domain.com` en lugar de UIDs/GIDs numéricos. El kernel local invoca `nfsidmap` para traducir las cadenas transmitidas por la red a UIDs/GIDs POSIX locales a través de SSSD/NSS. Si la parte del dominio en `/etc/idmapd.conf` no coincide entre el cliente y el servidor, la resolución de identidad recae en `nobody:nobody` (`nobodyuid`/`nobodygid`).
* **RPCSEC_GSS y Flavors de Seguridad**:
  * `sec=krb5`: Autentica solicitudes RPC utilizando tokens de Kerberos.
  * `sec=krb5i`: Proporciona autenticación y firma criptográficamente la carga útil de RPC para prevenir manipulaciones (Integridad).
  * `sec=krb5p`: Cifra toda la carga útil de RPC entre el cliente y el servidor para prevenir la escucha no autorizada (Privacidad).

---

## 2. Ejercicios Guiados de Producción

### Ejercicio 1: Despliegue de un Servidor Master de FreeIPA en Producción con DNS BIND9

#### Contexto y Objetivos
Desplegar un servidor master de FreeIPA en el host `ipa-master.infra.example.com` (`192.168.50.10`) dentro del dominio `infra.example.com` con el realm `INFRA.EXAMPLE.COM`. Habilitar el DNS BIND integrado con reenviadores externos.

#### Paso 1.1: Verificación de Prerrequisitos del Sistema
Ejecutar verificaciones previas para asegurar la resolución FQDN y configuraciones limpias del firewall:

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

Abrir los puertos de red requeridos en `firewalld`:

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

#### Paso 1.2: Instalación No Interactiva del Master de FreeIPA
Ejecutar `ipa-server-install` de forma no interactiva:

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

#### Paso 1.3: Verificación de Servicios y Configuraciones Generadas
Inspeccionar el archivo de configuración central generado `/etc/ipa/default.conf`:

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

Verificar el estado de los demonios del sistema:

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

Verificar la generación del ticket de admin:

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

### Preguntas de Comprensión (Bloque 1)

1. **¿Por qué FreeIPA recomienda instalar un servidor DNS BIND integrado utilizando `GSS-TSIG` en lugar de aprovechar un servidor DNS genérico externo no autenticado?**
2. **Si `ipactl status` informa que `pki-tomcatd` está `STOPPED`, ¿qué capacidades específicas de FreeIPA se ven degradadas y cómo afecta esto a los procesos de renovación de certificados de los hosts?**

---

### Ejercicio 2: Enrolamiento de Clientes, Gestión de Entidades y Habilitación de SSSD

#### Contexto y Objetivos
Enrolar el cliente `app-node-01.infra.example.com` (`192.168.50.20`) en el dominio de FreeIPA. Configurar SSSD en el cliente para el caching de credenciales offline y reglas de control de acceso estrictas (HBAC). Crear entidades de usuario empresariales, grupos POSIX y reglas de sudo utilizando la CLI de `ipa`.

#### Paso 2.1: Enrolamiento del Cliente Linux
Ejecutar `ipa-client-install` en `app-node-01`:

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

#### Paso 2.2: Hardening del Archivo `/etc/sssd/sssd.conf` del Cliente
Editar `/etc/sssd/sssd.conf` para configurar los límites de autenticación offline, actualizaciones dinámicas de DNS y filtrado de identidad LDAP:

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

#### Paso 2.3: Gestión de Entidades a través de la CLI de FreeIPA
En `ipa-master.infra.example.com`, aprovisionar usuarios POSIX, grupos y reglas HBAC (Host-Based Access Control):

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

#### Paso 2.4: Validación de la Resolución de Identidad y Gestión de Caché de SSSD
En `app-node-01.infra.example.com`, probar la búsqueda de usuarios y forzar la invalidación del caché:

```bash
# Verify user lookup via SSSD NSS responder
getent passwd jdoe
```

*Expected Output:*
```text
jdoe:*:10001:5001:John Doe:/home/jdoe:/bin/bash
```

Probar el caching offline utilizando `sssctl`:

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

### Preguntas de Comprensión (Bloque 2)

1. **¿Cómo procesa SSSD la autenticación de usuarios cuando el enlace de red con el servidor FreeIPA se interrumpe por completo, y qué directiva de configuración controla la duración de los inicios de sesión offline permitidos?**
2. **Si un administrador revoca los permisos HBAC de un usuario en el servidor FreeIPA, pero el usuario aún puede iniciar sesión en `app-node-01` a través de SSH durante los siguientes 10 minutos, ¿qué componente y configuraciones son responsables de esta latencia?**

---

### Ejercicio 3: Mecánica de Integración de Confianza Cross-Realm con Active Directory

#### Contexto y Objetivos
Integrar FreeIPA con un dominio de Active Directory existente (`CORP.LOCAL`). Configurar el subsistema de confianza utilizando `ipa-adtrust-install`, establecer una relación de confianza unidireccional y configurar las reglas de mapeo de identidad de SSSD para usuarios de AD.

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

#### Paso 3.1: Despliegue de Componentes de Confianza AD de FreeIPA
En `ipa-master.infra.example.com`, ejecutar el instalador de confianza. Esto configura el demonio `winbindd` de Samba internamente en el KDC para evaluar los tokens PAC (Privilege Attribute Certificate) de Active Directory:

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

#### Paso 3.2: Establecimiento de Confianza de Bosque Cross-Realm
Crear el enlace de confianza entre `INFRA.EXAMPLE.COM` y `CORP.LOCAL`:

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

#### Paso 3.3: Configuración del Mapeo Algorítmico de RID en SSSD
Cuando los usuarios de AD inician sesión en Linux, es posible que AD no posea atributos de esquema POSIX nativos (`uidNumber`, `gidNumber`). SSSD genera IDs POSIX deterministas utilizando el algoritmo de mapeo SID-a-RID.

Examinar la configuración de `/etc/sssd/sssd.conf` para los subdominios de AD:

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

#### Paso 3.4: Verificación de la Resolución de Usuarios de AD y Tickets de Kerberos Cross-Realm
Validar que un usuario de AD (por ejemplo, `asmith@corp.local`) pueda ser resuelto por los subsistemas POSIX en el nodo cliente de FreeIPA:

```bash
# Query AD user through SSSD
getent passwd "asmith@corp.local"
```

*Expected Output:*
```text
asmith@corp.local:*:201004:201004:Alice Smith:/home/corp.local/asmith:/bin/bash
```

Solicitar un ticket cross-realm utilizando `kinit`:

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

### Preguntas de Comprensión (Bloque 3)

1. **¿Cómo procesa FreeIPA los tickets de Kerberos de Active Directory que contienen datos PAC (Privilege Attribute Certificate) cuando un usuario de AD accede a un recurso Linux, y por qué se requiere `winbindd` en el Master de FreeIPA?**
2. **¿Qué problema ocurre si dos dominios de AD diferentes mapeados por SSSD se superponen en sus configuraciones de `ldap_idmap_range`, y cómo calcula SSSD los UIDs de forma determinista a partir del Identificador de Seguridad (SID) de Windows de un usuario?**

---

### Ejercicio 4: Despliegue Seguro de NFSv4 con Kerberos (RPCSEC_GSS) e Idmapping

#### Contexto y Objetivos
Desplegar un servidor de almacenamiento NFSv4 con Kerberos (`nfs-server.infra.example.com`) exportando `/exports/finance` utilizando `sec=krb5p`. Configurar el mapeo de identidades mediante `nfsidmap`, gestionar los keytabs del principal de servicio a través de FreeIPA y montar la exportación segura en `app-node-01.infra.example.com`.

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

#### Paso 4.1: Creación del Principal de Servicio y Aprovisionamiento de Keytab
En `ipa-master.infra.example.com`, generar el principal de servicio de NFS para `nfs-server.infra.example.com`:

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

Verificar el contenido del keytab del ticket de servicio utilizando `ktutil` o `klist`:

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

#### Paso 4.2: Configuración del Pseudosistema de Archivos y Exportaciones del Servidor NFSv4
En `nfs-server.infra.example.com`, configurar `/etc/idmapd.conf` para que coincida exactamente con el dominio de FreeIPA:

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

Configurar la estructura de directorios y `/etc/exports`:

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

#### Paso 4.3: Montaje de Recursos Compartidos Cifrados de NFSv4 en el Cliente
En `app-node-01.infra.example.com`, obtener un keytab de cliente NFS si es necesario, asegurar que `rpc-gssd` esté activo y montar el recurso compartido:

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

#### Paso 4.4: Diagnóstico Avanzado y Protocolos de Resolución de Problemas
Ejecutar diagnósticos para rastrear el mapeo de identidades y el manejo de cargas útiles de RPCSEC_GSS:

##### 1. Inspección del Estado de Idmapping en la Red
Si los archivos se muestran como `nobody:nobody`, verificar el caché de traducción de `nfsidmap` del kernel del cliente:

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

##### 2. Depuración Profunda de RPC en el Kernel
Habilitar la depuración detallada en los módulos del cliente NFS/RPC del kernel para depurar fallos de autenticación GSS:

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

Restablecer los flags de depuración después del análisis:

```bash
sudo rpcdebug -m rpc -c all
sudo rpcdebug -m nfs -c all
```

##### 3. Monitoreo de Métricas de Rendimiento de NFS
Inspeccionar las estadísticas RPC usando `nfsstat`:

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

### Preguntas de Comprensión (Bloque 4)

1. **¿Cuál es la diferencia arquitectónica exacta entre `sec=krb5`, `sec=krb5i` y `sec=krb5p` en términos de sobrecarga de CPU, encapsulamiento de paquetes y privacidad en la red?**
2. **Si un usuario `jdoe` crea un archivo en un montaje NFSv4 con `sec=krb5p`, pero la propiedad del archivo se muestra como `nobody:nobody` en el servidor, ¿cuáles son las tres causas raíz más comunes en `/etc/idmapd.conf`, SSSD o DNS?**
3. **¿Por qué NFSv4 elimina la necesidad de los demonios `rpc.lockd` y `rpc.statd` requeridos por NFSv3?**

---

## 3. Soluciones Verificadas y Explicaciones Técnicas

<details>
<summary>Haga clic para expandir las Soluciones y Explicaciones Técnicas Detalladas</summary>

### Respuestas a las Preguntas del Bloque 1

1. **Justificación del DNS BIND Integrado con `GSS-TSIG`**:
   FreeIPA depende enormemente de los Registros de Servicio DNS (`SRV`) para permitir que los clientes descubran automáticamente y de forma dinámica los KDC de Kerberos, servidores LDAP y endpoints de CA sin necesidad de codificar direcciones IP de forma fija. 
   Cuando los hosts se enrolan en el dominio de FreeIPA mediante `ipa-client-install`, intentan publicar sus propios registros directos (`A`/`AAAA`) e inversos (`PTR`). Al desplegar BIND9 integrado con `GSS-TSIG` (claves TSIG autenticadas por GSSAPI a través de Kerberos), las actualizaciones dinámicas de DNS se autentican criptográficamente mediante las credenciales de Kerberos del host (`host/hostname@REALM`). 
   Los servidores DNS genéricos externos no autenticados rechazarían las actualizaciones dinámicas o dejarían la creación de registros DNS expuesta a suplantación de identidad (spoofing), lo que podría redirigir los flujos de autenticación a KDC maliciosos (ataques Man-in-the-Middle).

2. **Impacto del Fallo del Demonio `pki-tomcatd`**:
   `pki-tomcatd` aloja el motor de la Autoridad de Certificación Dogtag PKI. Si este servicio se detiene:
   * **Funcionalidad Degradada**: No se pueden emitir nuevos certificados, no se pueden revocar certificados existentes y falla el enrolamiento de tarjetas inteligentes.
   * **Renovación de Certificados de Hosts**: El demonio `certmonger` que se ejecuta en los nodos cliente/servidor no podrá renovar los certificados SSL/TLS o IPsec a punto de expirar (por ejemplo, los certificados de servidor de HTTPD o LDAP). Mientras que los tokens de autenticación de Kerberos existentes seguirán funcionando hasta que sus certificados o tickets expiren, el mantenimiento automatizado de la infraestructura se interrumpe por completo.

---

### Respuestas a las Preguntas del Bloque 2

1. **Procesamiento de Autenticación Offline de SSSD**:
   Cuando se pierde la conectividad de red con FreeIPA, el módulo PAM de SSSD (`pam_sss.so`) cambia al modo de verificación offline. En lugar de contactar al KDC mediante `AS-REQ` a través del puerto 88, SSSD calcula un hash criptográfico (PBKDF2/SHA-512 con sal) de la contraseña proporcionada por el usuario y lo compara con el hash almacenado en caché en la base de datos LDB local (`/var/lib/sss/db/cache_<domain>.ldb`).
   * **Directiva de Control**: La duración y validez de las credenciales offline están controladas por `offline_credentials_expiration` (medida en días) dentro de `/etc/sssd/sssd.conf`. Si se establece en `0`, los inicios de sesión offline se permiten indefinidamente mientras existan credenciales en caché.

2. **Latencia en el Caché de Revocación de HBAC**:
   * **Componente Responsable**: El mecanismo de almacenamiento en caché de identidades y reglas de acceso de SSSD dentro de `/var/lib/sss/db/`.
   * **Configuraciones Responsables**: SSSD almacena en caché las reglas HBAC (Host-Based Access Control) para evitar consultar LDAP en cada conexión SSH o ejecución de `sudo`. La configuración que controla cuánto tiempo permanecen válidas las reglas HBAC antes de volver a consultar al servidor LDAP es `entry_cache_hbac_timeout` (o el timeout general `entry_cache_timeout`, cuyo valor predeterminado es 5400 segundos / 90 minutos a menos que se ajuste). 
   Para forzar la aplicación inmediata de la revocación en los nodos, un operador debe ejecutar `sssctl cache-remove` o `sss_cache -E` en el host cliente.

---

### Respuestas a las Preguntas del Bloque 3

1. **Procesamiento de Datos PAC y Requisito de `winbindd`**:
   Active Directory incrusta un Privilege Attribute Certificate (PAC) dentro de los tickets de Kerberos emitidos a los usuarios. El PAC contiene los Identificadores de Seguridad (SID) de AD del usuario, sus membresías de grupos de dominio y declaraciones de seguridad.
   Cuando un usuario de AD intenta acceder a un recurso en el realm de FreeIPA a través de la relación de confianza cross-realm:
   * El KDC de FreeIPA recibe el TGT cross-realm.
   * FreeIPA debe evaluar si los SID dentro del PAC se mapean a grupos POSIX válidos y si el usuario está autorizado.
   * El demonio `winbindd` (configurado mediante `ipa-adtrust-install`) es específicamente responsable de contactar a los Controladores de Dominio de Active Directory mediante llamadas RPC, decodificar la estructura NTLM/PAC, verificar la firma digital del PAC utilizando el secreto de confianza y traducir los SID de AD a representaciones internas que el Directory Server 389-ds de FreeIPA pueda procesar.

2. **Superposición de Mapeo de IDs y Cálculo Determinista de SID**:
   * **Problemas de Superposición**: Si dos configuraciones de dominio de AD en `/etc/sssd/sssd.conf` tienen valores de `ldap_idmap_range` que se superponen (por ejemplo, si el Dominio A y el Dominio B usan ambos `200000-400000`), SSSD generará UIDs/GIDs POSIX colisionados para usuarios de AD completamente diferentes. Esto conduce a vulnerabilidades críticas de escalada de privilegios donde el Usuario A del Dominio A obtiene permisos de acceso a archivos completos del Usuario B en el Dominio B.
   * **Cálculo Determinista de SID**: SSSD convierte un SID de Windows (por ejemplo, `S-1-5-21-100-200-300-1050`) en un UID POSIX utilizando una función de mapeo de rango algorítmica o basada en hash:
     $$\text{POSIX UID} = \text{Base UID del Rango} + (\text{RID} - \text{RID Mínimo})$$
     Donde $\text{RID}$ es el identificador relativo (la última subautoridad del SID, por ejemplo, `1050`). Debido a que la fórmula es matemática y puramente determinista, cada cliente Linux que ejecuta SSSD calcula exactamente el mismo UID POSIX para un usuario de AD dado sin necesidad de escribir atributos UID de regreso en el LDAP de Active Directory.

---

### Respuestas a las Preguntas del Bloque 4

1. **Comparación de Flavors de Seguridad de NFSv4**:
   * `sec=krb5` (Solo Autenticación): Autentica el principal del usuario a través de Kerberos durante el establecimiento inicial de RPC. Los encabezados están firmados, pero las cargas útiles estándar de RPC (bloques de datos de lectura/escritura de archivos) viajan a través de la red como texto plano sin cifrar. Sobrecarga mínima de CPU.
   * `sec=krb5i` (Protección de Integridad): Utiliza claves de sesión de Kerberos para calcular una suma de comprobación HMAC (típicamente HMAC-SHA1 o HMAC-SHA256) para cada encabezado y paquete de carga útil RPC. Previene la manipulación activa en la red, la inyección de paquetes o la corrupción de datos por ataques Man-in-the-Middle. Sobrecarga moderada de CPU debido al cálculo de hashes.
   * `sec=krb5p` (Privacidad / Cifrado): Envuelve toda la carga útil de ONC RPC dentro del encapsulamiento criptográfico de GSS-API utilizando cifradores simétricos (AES-128-CTS o AES-256-CTS). Garantiza confidencialidad e integridad completas en la red. Mayor sobrecarga de CPU debido a los ciclos de cifrado/descifrado criptográfico por software/hardware en cada IOPS.

2. **Causas Raíz de la Degradación de Propiedad a `nobody:nobody`**:
   * **Discordancia en el Dominio de `/etc/idmapd.conf`**: La cadena `Domain =` en `/etc/idmapd.conf` DEBE ser idéntica tanto en el servidor NFSv4 como en el cliente (por ejemplo, `Domain = infra.example.com`). Si el cliente usa `infra.example.com` y el servidor usa `localdomain`, la traducción de identidad falla, forzando al kernel a mapear la cadena `jdoe@infra.example.com` a `nobodyuid`.
   * **Fallo en la Resolución de Nombres de SSSD / NSS**: Si el demonio local `rpc.idmapd` / `nfsidmap` del servidor consulta `getpwnam("jdoe@infra.example.com")` o `getpwnam("jdoe")` a través de NSS, y SSSD está detenido o mal configurado, el sistema operativo local no puede resolver la cadena a un UID POSIX local válido (10001).
   * **Discordancia de FQDN DNS / PTR Inverso**: Si se solicitan tickets de Kerberos para el servidor NFS, pero el DNS inverso (PTR) devuelve un nombre de host inesperado, `rpc-gssd` no logra negociar el contexto de seguridad RPCSEC_GSS, lo que hace que NFSv4 degrade la asociación de seguridad a un mapeo anónimo (`nobody`).

3. **Eliminación de Lockd y Statd en NFSv4**:
   NFSv3 era un protocolo sin estado. Delegaba el bloqueo de archivos y el monitoreo del estado del clúster a demonios de red independientes (`rpc.lockd` para el protocolo NLM y `rpc.statd` para el protocolo NSM), lo que requería múltiples puertos UDP/TCP aleatorios y reglas de firewall complejas.
   NFSv4 es intrínsecamente un protocolo con estado. Las operaciones de apertura, las concesiones de bloqueo de archivos (leases), los stateids y los números de secuencia están integrados directamente en el protocolo de red central de NFSv4 utilizando solicitudes COMPOUND RPC. El estado del lease se mantiene a través de una única conexión TCP en el puerto 2049, lo que hace que los demonios externos de bloqueo/estado sean completamente redundantes.

</details>