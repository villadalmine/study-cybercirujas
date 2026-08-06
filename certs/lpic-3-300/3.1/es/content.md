# Examen LPIC-3 300-300 (v3.0) — Tema 3.1: Configuración de Samba Share

**Peso del examen:** 20  
**Rol objetivo:** Senior SRE / Principal Platform Architect  
**Alcance de los objetivos:** Diseño avanzado de recursos compartidos de Samba, integración con Active Directory (`security = ADS`), autorización granular (`valid users`, `hosts allow`), mapeo de ACL POSIX/NTFS (`vfs_acl_xattr`), apilamiento de módulos VFS (`full_audit`, `shadow_copy2`, `recycle`), ajuste de concurrencia de baja latencia (`smb2 leases`, `aio`), aplicación de políticas SELinux y flujos de trabajo de diagnóstico de bajo nivel (`smbstatus`, `smbcacls`, `getfattr`, `tcpdump`).

---

## 1. Motivación arquitectónica de producción y planteamiento del problema

### 1.1 El desafío de la infraestructura de archivos híbrida empresarial
En entornos empresariales modernos, los servidores Linux alojan frecuentemente recursos compartidos de archivos de misión crítica a los que acceden de forma concurrente estaciones de trabajo Windows, nodos de cómputo Linux, clientes macOS y pipelines de CI/CD automatizados. Este ecosistema multiprotocolo introduce cinco grandes desafíos arquitectónicos:

1. **Disparidad en la gestión de identidades y accesos (IAM):** Los ecosistemas Windows dependen de los Security Identifiers (SIDs) de Active Directory y de las Windows Access Control Lists (NTFS ACLs), mientras que Linux depende de los POSIX User IDs (UIDs), Group IDs (GIDs) y borradores de ACLs POSIX/NFSv4. Enlazar estos paradigmas sin corrupción de identidad ni escalación de privilegios es crítico.
2. **Semántica de concurrencia y bloqueo de archivos:** Las aplicaciones de Windows (como Microsoft Office o software CAD) dependen en gran medida de los Opportunistic Locks (Oplocks) y SMB2/3 Leases para el almacenamiento en caché del lado del cliente y la revocación dinámica de bloqueos. Si los procesos locales de Linux o las exportaciones NFS acceden a la misma jerarquía de archivos sin la sincronización de bloqueos de SMB, se producen corrupción de datos e interbloqueos (deadlocks) en el bloqueo de archivos.
3. **Protección de datos y recuperación en un punto en el tiempo (Point-in-Time Recovery):** El cumplimiento normativo empresarial (SOX, HIPAA, ISO 27001) exige la recuperación de snapshots en autoservicio (integración con Windows Volume Shadow Copy Service / VSS) sin exponer los montajes de snapshots del sistema de archivos subyacente a usuarios no autorizados de la red.
4. **Trazabilidad de auditoría:** Los centros de operaciones de seguridad (SOC) requieren registros de auditoría granulares y no repudiables que cubran la creación, eliminación, modificación de archivos, alteraciones de permisos y operaciones de lectura, enviados directamente a soluciones SIEM (por ejemplo, Splunk, Elastic) a través de syslog.
5. **E/S de almacenamiento de alto rendimiento:** El renderizado de medios de alto rendimiento, la ingesta de datos científicos o el acceso desde estaciones de trabajo a velocidades de multi-gigabit requieren E/S asíncrona (`aio`), operaciones de red zero-copy (`sendfile`), cifrado SMB3 (AES-128-GCM / AES-256-GCM) y SMB Multichannel sin generar cuellos de botella en la CPU.

```
                         [ Active Directory Domain Controller ]
                                          |
                                (Kerberos v5 / LDAP)
                                          |
[ Windows 11 Client ] <---> [ Samba 4 smbd (vfs_acl_xattr) ] <---> [ POSIX File System ]
  (NTFS ACL / SMB3.1.1)                 |                             (ext4 / XFS / ZFS)
                                        +--> [ Extended Attributes ] (security.NTACL)
                                        +--> [ VFS Audit Logs ]      (/var/log/audit)
                                        +--> [ Shadow Copy VSS ]     (LVM/ZFS Snapshots)
```

---

## 2. Comparaciones técnicas y tablas de balance (Trade-offs)

### 2.1 Modelos de seguridad de Samba y estrategias de integración de dominios

| Métrica / Parámetro | `security = ADS` | `security = USER` | `security = DOMAIN` (Obsoleto) |
| :--- | :--- | :--- | :--- |
| **Proveedor de identidad** | Active Directory (Kerberos v5 + LDAP a través de Winbind/SSSD) | Base de datos local Samba TDB (`passdb.tdb`) o LDAP | Windows NT4 Domain Controller (NTLM RPC) |
| **Flujo de autenticación** | Ticket del Ticket Granting Service (TGS) / SPNEGO / fallback a NTLMv2 | Challenge-Response a través de SAM / Passdb local | Pass-through de tubería RPC al DC |
| **Soporte de Kerberos** | Soporte completo (AES-256-CTS-HMAC-SHA1-96) | Ninguno | Ninguno |
| **Carga administrativa** | Baja (centralizada en AD) | Alta (gestión del ciclo de vida del usuario por nodo) | Carga operacional heredada (legacy) |
| **Caso de uso en producción** | Miembro del dominio de Active Directory empresarial | Nodo de borde independiente / appliance en DMZ | Solo escenarios de migración heredados (legacy) |

### 2.2 Estrategias de almacenamiento y mapeo de ACL

| Estrategia | Detalles mecánicos | Pros | Contras / Trade-offs |
| :--- | :--- | :--- | :--- |
| **ACLs POSIX puras borrador** (`vfs_default`) | Mapea las ACLs de Windows NT directamente a las ACLs borrador POSIX 1003.1e (`getfacl`/`setfacl`). | Compatibilidad con herramientas nativas de Linux; legible mediante utilidades estándar del sistema de archivos. | No puede representar toda la granularidad de los Security Descriptors (SD) de Windows (por ejemplo, reglas de auditoría granulares, flags específicos como `Delete Child`). |
| **NTACL en atributos extendidos** (`vfs_acl_xattr`) | Almacena el Security Descriptor binario completo de Windows en el EA del sistema de archivos `security.NTACL`. Mapea permisos POSIX básicos para fallback. | 100% de fidelidad con NTFS ACL de Windows; soporte completo para permisos heredados y flags avanzados. | Requiere soporte del sistema de archivos subyacente para atributos extendidos (`user_xattr`); un `chmod` POSIX en el host puede desincronizar `security.NTACL`. |
| **NTACL en base de datos TDB** (`vfs_acl_tdb`) | Almacena los Security Descriptors de Windows en una base de datos TDB centralizada mapeada por ID de archivo. | Funciona en sistemas de archivos sin soporte para atributos extendidos (por ejemplo, montajes NFS). | Cuello de botella en TDB bajo alto IPC; punto único de falla si la TDB se corrompe; desafíos en la sincronización de snapshots. |

### 2.3 Mecánica de concurrencia y bloqueo

| Característica | Capa de protocolo | Mecanismo de comportamiento | Configuración recomendada |
| :--- | :--- | :--- | :--- |
| **Batch / Exclusive Oplocks** | SMB1 / SMB2 | El servidor delega al cliente permiso exclusivo de escritura en caché. El servidor rompe el oplock ante un intento de acceso concurrente. | `oplocks = yes` |
| **SMB2/3 Leases** | SMB2.1+ / SMB3.1.1 | Otorga leases de Lectura (R), Escritura (W) y Handle (H) de forma independiente. Permite a los clientes almacenar handles en caché a través de reconexiones de red. | `smb2 leases = yes` |
| **Kernel Oplocks** | Kernel de Linux (`fcntl` F_SETLEASE) | Sincroniza los oplocks SMB de Samba con el acceso a archivos de procesos locales de Linux mediante señales del kernel. | `kernel oplocks = yes` (Desactivar si se utilizan sistemas de archivos en clúster no POSIX como GlusterFS/Ceph a menos que un módulo VFS lo gestione). |
| **Strict Locking** | Motor del servidor Samba | Fuerza a Samba a verificar el estado de bloqueo del lado del servidor en cada operación de lectura/escritura independientemente del estado del oplock del cliente. | `strict locking = auto` (Alta seguridad; impacto mínimo en SMB2/3). |

---

## 3. Configuraciones completas de producción y manifiestos de infraestructura

### 3.1 Configuración de Samba de producción completamente formateada (`/etc/samba/smb.conf`)

A continuación se muestra un archivo `smb.conf` de producción empresarial completo y sintácticamente válido, diseñado para un miembro del dominio de Active Directory con registro de auditoría VFS, papelera de reciclaje automatizada, shadow copies y mapeo de ACL POSIX.

```ini
# ==============================================================================
# Production Enterprise Samba Configuration
# Node Role: Domain Member Server (Active Directory Integration)
# Architecture: High-Availability Shared Storage Server
# ==============================================================================

[global]
    # --- Identity & Active Directory Integration ---
    workgroup = CORP
    realm = CORP.EXAMPLE.COM
    security = ADS
    kerberos method = secrets and keytab
    winbind refresh tickets = yes
    winbind use default domain = yes
    winbind offline logon = yes
    winbind enum users = no
    winbind enum groups = no

    # --- ID Mapping (idmap_rid: Deterministic SID-to-UID/GID Algorithmic Mapping) ---
    idmap config * : backend = tdb
    idmap config * : range = 10000-19999
    idmap config CORP : backend = rid
    idmap config CORP : range = 20000-999999

    # --- Server Roles & Services ---
    server string = Enterprise Storage Node %h (Samba %v)
    netbios name = STOR-NODE-01
    disable netbios = yes
    smb ports = 445

    # --- Protocol & Security Hardening ---
    server min protocol = SMB3_00
    server max protocol = SMB3_11
    client ipc min protocol = SMB3_00
    client max protocol = SMB3_11
    client signing = required
    server signing = required
    smb encrypt = required
    restrict anonymous = 2
    invalid users = root daemon bin sys sync games man lp mail news uucp proxy

    # --- Performance Tuning & Async I/O ---
    aio read size = 1
    aio write size = 1
    use sendfile = yes
    min receivefile size = 16384
    socket options = TCP_NODELAY SO_RCVBUF=131072 SO_SNDBUF=131072
    smb2 leases = yes
    oplocks = yes
    kernel oplocks = yes
    strict locking = auto

    # --- Global ACL & Attribute Behavior ---
    ea support = yes
    store dos attributes = yes
    map archive = no
    map hidden = no
    map system = no
    map read only = no
    vfs objects = acl_xattr full_audit

    # --- Global VFS Audit Configuration ---
    full_audit:prefix = %u|%I|%m|%S
    full_audit:success = mkdir rmdir write pwrite unlink rename pwritev chmod chown
    full_audit:failure = connect write pwrite unlink rename chmod chown
    full_audit:facility = LOCAL7
    full_audit:priority = NOTICE

    # --- Logging Configuration ---
    log level = 1 auth:3 winbind:3 vfs:2
    log file = /var/log/samba/log.%m
    max log size = 50000
    logging = syslog@LOCAL7 file

# ==============================================================================
# Share Definitions
# ==============================================================================

[homes]
    comment = User Home Directories
    path = /srv/samba/homes/%U
    browseable = no
    read only = no
    create mask = 0700
    directory mask = 0700
    valid users = %V\%U CORP\"Domain Admins"
    root preexec = /usr/local/bin/samba_mkhomedir.sh "%U" "%G"
    vfs objects = acl_xattr full_audit recycle
    recycle:repository = .recycle
    recycle:keeptree = yes
    recycle:versions = yes
    recycle:touch = yes
    recycle:maxsize = 0
    recycle:exclude = *.tmp, *.temp, ~$*

[Finance_Data]
    comment = Enterprise Finance Secure Repository
    path = /srv/samba/shares/finance
    browseable = yes
    read only = no
    guest ok = no
    valid users = @CORP\"Finance Department" @CORP\"Domain Admins"
    write list = @CORP\"Finance Managers" @CORP\"Domain Admins"
    force group = CORP\"Finance Department"
    
    # Permission Inheritance & POSIX / Windows Mapping Controls
    create mask = 0660
    directory mask = 0770
    force create mode = 0660
    force directory mode = 0770
    inherit permissions = yes
    inherit acls = yes
    map acl inherit = yes

    # VFS Module Pipeline Stacking
    vfs objects = acl_xattr shadow_copy2 full_audit recycle

    # VFS Shadow Copy 2 Parameters (LVM/ZFS Snapshot Integration)
    shadow:snapdir = .snapshots
    shadow:format = @GMT-%Y.%m.%d-%H.%M.%S
    shadow:sort = desc
    shadow:localtime = no
    shadow:basedir = /srv/samba/shares/finance

    # VFS Recycle Parameters
    recycle:repository = /srv/samba/shares/finance/.recycle
    recycle:keeptree = yes
    recycle:versions = yes
    recycle:touch_mtime = yes
    recycle:directory_mode = 0770
    recycle:exclude = ~$*, *.tmp, *.log, index.dat

[Engineering_Builds]
    comment = High-Throughput CI/CD Build Artifacts (Read-Only Public Access)
    path = /srv/samba/shares/engineering
    browseable = yes
    read only = yes
    guest ok = yes
    hosts allow = 10.250.0.0/16 192.168.10.0/24 127.0.0.1
    hosts deny = ALL
    valid users = @CORP\"Engineers" @CORP\"Domain Admins" guest
    write list = @CORP\"Release Engineers"
    
    # High-Performance File Handling Settings
    oplocks = yes
    level2 oplocks = yes
    smb2 leases = yes
    vfs objects = acl_xattr full_audit
```

---

### 3.2 Inicialización del sistema de archivos del host e integración con Systemd

Para respaldar la configuración anterior, ejecute el script de configuración estructural para configurar los directorios de almacenamiento, las anulaciones (overrides) del servicio systemd y las políticas de SELinux.

```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. Create Base Directories
mkdir -p /srv/samba/homes
mkdir -p /srv/samba/shares/finance/{.snapshots,.recycle}
mkdir -p /srv/samba/shares/engineering

# 2. Set Default Host POSIX Permissions
chown -R root:20000 /srv/samba/shares/finance # 20000 mapped to Domain Admins
chmod -R 2770 /srv/samba/shares/finance

chown -R root:20001 /srv/samba/shares/engineering # 20001 mapped to Engineers
chmod -R 2775 /srv/samba/shares/engineering

# 3. Configure SELinux Booleans & File Contexts
if command -v getenforce &> /dev/null && [ "$(getenforce)" != "Disabled" ]; then
    echo "[+] Configuring SELinux policy contexts for Samba..."
    setsebool -P samba_enable_home_dirs on
    setsebool -P samba_export_all_rw on
    
    semanage fcontext -a -t samba_share_t "/srv/samba(/.*)?"
    restorecon -Rv /srv/samba
fi

# 4. Systemd Service Hardening Override (/etc/systemd/system/smbd.service.d/override.conf)
mkdir -p /etc/systemd/system/smbd.service.d/
cat << 'EOF' > /etc/systemd/system/smbd.service.d/override.conf
[Service]
LimitNOFILE=65536
LimitNPROC=65536
TasksMax=infinity
Restart=always
RestartSec=5s
EOF

systemctl daemon-reload
```

---

## 4. Comandos CLI reales y salidas de terminal paso a paso

### 4.1 Validación de sintaxis y verificación de parámetros (`testparm`)

Ejecute `testparm` para verificar la sintaxis de los parámetros, asegurarse de que no existan combinaciones de claves ilegales y validar los alcances (scopes) globales y de recursos compartidos.

```bash
$ testparm -s /etc/samba/smb.conf
```
```output
Load smb config files from /etc/samba/smb.conf
Loaded services file OK.
Weak crypto is allowed by GnuTLS (default)
Server role: ROLE_DOMAIN_MEMBER

# Log output truncates default values, dumping effective configuration:
[global]
	bind interfaces only = Yes
	client max protocol = SMB3_11
	client min protocol = SMB3_00
	client signing = required
	disable netbios = Yes
	ea support = Yes
	idmap config corp : range = 20000-999999
	idmap config corp : backend = rid
	idmap config * : range = 10000-19999
	idmap config * : backend = tdb
	invalid users = root daemon bin sys sync games man lp mail news uucp proxy
	kerberos method = secrets and keytab
	logging = syslog@LOCAL7 file
	realm = CORP.EXAMPLE.COM
	security = ADS
	server max protocol = SMB3_11
	server min protocol = SMB3_00
	server signing = required
	smb encrypt = required
	workgroup = CORP
	idmap config * : backend = tdb

[Finance_Data]
	comment = Enterprise Finance Secure Repository
	create mask = 0660
	directory mask = 0770
	force create mode = 0660
	force directory mode = 0770
	force group = CORP\"Finance Department"
	inherit acls = Yes
	inherit permissions = Yes
	map acl inherit = Yes
	path = /srv/samba/shares/finance
	read only = No
	shadow:basedir = /srv/samba/shares/finance
	shadow:format = @GMT-%Y.%m.%d-%H.%M.%S
	shadow:snapdir = .snapshots
	valid users = @CORP\"Finance Department", @CORP\"Domain Admins"
	vfs objects = acl_xattr shadow_copy2 full_audit recycle
	write list = @CORP\"Finance Managers", @CORP\"Domain Admins"
```

---

### 4.2 Unión al dominio de Active Directory y verificación de secretos (`net ads`)

Una el nodo a Active Directory, pueble `/etc/krb5.keytab` y verifique el estado de la autenticación.

```bash
$ net ads join -U "Administrator%P@ssw0rd2026" -s /etc/samba/smb.conf
```
```output
Using short domain name -- CORP
Joined 'STOR-NODE-01' to dns domain 'corp.example.com'
No DNS domain configured for stor-node-01. Unable to perform DNS Update.
DNS update should be performed manually or fix your /etc/hosts file.
```

```bash
$ net ads testjoin
```
```output
Join is OK
```

```bash
$ klist -k /etc/krb5.keytab
```
```output
Keytab version: 0x0502
KVNO Timestamp           Principal
---- ------------------- ------------------------------------------------------
   3 08/06/2026 12:00:01 STOR-NODE-01$@CORP.EXAMPLE.COM
   3 08/06/2026 12:00:01 STOR-NODE-01$@CORP.EXAMPLE.COM
   3 08/06/2026 12:00:01 host/STOR-NODE-01@CORP.EXAMPLE.COM
   3 08/06/2026 12:00:01 host/STOR-NODE-01.corp.example.com@CORP.EXAMPLE.COM
   3 08/06/2026 12:00:01 cifs/STOR-NODE-01@CORP.EXAMPLE.COM
   3 08/06/2026 12:00:01 cifs/STOR-NODE-01.corp.example.com@CORP.EXAMPLE.COM
```

---

### 4.3 Monitoreo en tiempo de ejecución e inspección de bloqueos (`smbstatus`)

Inspeccione las conexiones SMB activas, los dialectos del protocolo, la firma, el cifrado y los bloqueos abiertos en todos los recursos compartidos.

```bash
$ smbstatus --verbose
```
```output
Samba version 4.19.4-Debian
PID     Username     Group        Machine                             Protocol Version           Encryption           Signing              
----------------------------------------------------------------------------------------------------------------------------------------
409112  john_doe     Domain Users 10.250.4.12 (ipv4:10.250.4.12:51234)  SMB3_11                    AES-128-GCM          partial(signed)      

Service      pid     Machine       Connected at                     Encryption                   Signing              
----------------------------------------------------------------------------------------------------------------------
Finance_Data 409112  10.250.4.12   Thu Aug  6 12:14:02 2026 EDT     AES-128-GCM                  partial(signed)      

Locked files:
Pid          User(uid)           DenyMode   Access      R/W        Oplock           SharePath                        Name                        Time
------------------------------------------------------------------------------------------------------------------------------------------------------------------
409112       20542               DENY_NONE  0x120089    RDWR       LEASE(RWH)       /srv/samba/shares/finance        budget_2027_draft.xlsx      Thu Aug  6 12:15:30 2026

# Lease status detailing RWH (Read/Write/Handle) state:
Key: 3a:fa:8c:11:02:ee:4b:11:b9:2d:00:15:5d:01:10:04
Flags: 0x3 (READ WRITE HANDLE)
```

---

### 4.4 Gestión de Windows Security Descriptors mediante CLI (`smbcacls`)

Inspeccione y modifique directamente el Windows NT Security Descriptor (`security.NTACL`) almacenado en un archivo de un recurso compartido de Samba sin necesidad de utilizar una estación de trabajo Windows con interfaz gráfica (GUI).

```bash
$ smbcacls //localhost/Finance_Data "/budget_2027_draft.xlsx" -U "CORP\john_doe%Secret123"
```
```output
REVISION:1
CONTROL:SR|PD|DI
OWNER:CORP\john_doe
GROUP:CORP\Finance Department
ACL:CORP\Domain Admins:ALLOWED/OI|CI/FULL
ACL:CORP\Finance Managers:ALLOWED/OI|CI/CHANGE
ACL:CORP\john_doe:ALLOWED/OI|CI/READ
```

Para revocar el acceso a `john_doe` y agregar una regla explícita de ALLOW para `CORP\jane_smith`:

```bash
$ smbcacls //localhost/Finance_Data "/budget_2027_draft.xlsx" \
  -U "CORP\administrator%P@ssw0rd2026" \
  -ADD "ACL:CORP\jane_smith:ALLOWED/OI|CI/FULL"
```
```output
REVISION:1
CONTROL:SR|PD|DI
OWNER:CORP\john_doe
GROUP:CORP\Finance Department
ACL:CORP\Domain Admins:ALLOWED/OI|CI/FULL
ACL:CORP\Finance Managers:ALLOWED/OI|CI/CHANGE
ACL:CORP\john_doe:ALLOWED/OI|CI/READ
ACL:CORP\jane_smith:ALLOWED/OI|CI/FULL
```

---

### 4.5 Inspección de atributos extendidos de bajo nivel (`getfattr`)

Verifique cómo `vfs_acl_xattr` codifica el Windows Security Descriptor binario en el atributo extendido `security.NTACL` del sistema de archivos del host Linux.

```bash
$ getfattr -n security.NTACL -d /srv/samba/shares/finance/budget_2027_draft.xlsx
```
```output
# file: srv/samba/shares/finance/budget_2027_draft.xlsx
security.NTACL=0sAQABAAAAAABgAAAAAAAABAAAAAEAACAAAQAAAAAABAAQAAAAAAAHAAAAAAACACAAAQAAAAAAAwAUAAAAAAABBQAAAAAAABQAAAAAAA==
```

Para inspeccionar los atributos DOS en bruto (por ejemplo, los flags Read-Only, Hidden, System, Archive mapeados mediante `store dos attributes = yes`):

```bash
$ getfattr -h -d -m "user.DOSATTRIB" /srv/samba/shares/finance/budget_2027_draft.xlsx
```
```output
# file: srv/samba/shares/finance/budget_2027_draft.xlsx
user.DOSATTRIB=0s00040020000000000000000000000000
```

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 Flujo de trabajo de arquitectura para resolución de problemas (Troubleshooting)

```
[ Incident Triggered ]
         |
         v
[ 1. Syntax Check ] -----------> Run `testparm -v`
         | (OK)
         v
[ 2. Domain & Auth Check ] ----> Run `wbinfo -u`, `wbinfo -t`, `klist -k`
         | (OK)
         v
[ 3. Local ID Resolution ] ----> Run `id CORP\username` (Verify RID range mapping)
         | (OK)
         v
[ 4. File Permission Audit ] --> Run `getfacl` AND `getfattr -n security.NTACL`
         | (OK)
         v
[ 5. Dynamic Lock/Lease ] -----> Run `smbstatus -L`
         | (OK)
         v
[ 6. Network/Protocol Trace ] -> Run `tcpdump -i any port 445 -w smb_trace.pcap`
```

---

### 5.2 Escenarios de falla comunes y matriz de resolución

#### Escenario A: Acceso denegado al cliente a pesar de una pertenencia a grupo correcta
* **Síntoma:** El usuario `CORP\alice` recibe `NT_STATUS_ACCESS_DENIED` al conectarse a `\\STOR-NODE-01\Finance_Data`.
* **Causa raíz 1:** Falla en `idmap config`; Winbind no puede convertir el SID de `CORP\alice` (`S-1-5-21-...-5001`) al UID de Linux del host porque el RID queda fuera de los rangos especificados.
* **Causa raíz 2:** El atributo extendido `security.NTACL` tiene una entrada DENY explícita, o los permisos POSIX del sistema de archivos (`chmod`) prohíben la lectura/escritura al proceso del host.
* **Ejecución de diagnóstico:**
  ```bash
  # Check if Winbind resolves user and group SIDs to local UIDs/GIDs
  $ id "CORP\alice"
  ```
  *Salida con falla:* `id: 'CORP\alice': no such user`
  
  *Solución:* Ajuste `idmap config CORP : range` en `/etc/samba/smb.conf` para dar cabida a números RID más grandes, luego purgue la caché de idmap:
  ```bash
  $ net cache flush
  $ systemctl restart winbind smbd
  ```

#### Escenario B: Colisiones de bloqueo de archivos y guardado lento de archivos de Office
* **Síntoma:** Microsoft Excel advierte a los usuarios que los archivos están "Bloqueados para edición por otro usuario" incluso después de que el usuario inicial haya cerrado el documento.
* **Causa raíz:** Timeout en la ruptura del SMB2 Lease o del Oplock entre el demonio de Samba y el cliente, o falla de los kernel oplocks para sincronizarse con un agente de respaldo del host que accede a los archivos locales.
* **Ejecución de diagnóstico:**
  ```bash
  $ smbstatus -L | grep "budget_2027_draft.xlsx"
  ```
  *Análisis:* Verifique si el PID asociado con el bloqueo del archivo aún existe en el sistema operativo del host:
  ```bash
  $ ps aux | grep 409112
  ```
  Si el PID está obsoleto (stale), fuerce el cierre del handle del archivo abierto a través de la CLI de Samba:
  ```bash
  $ smbstatus --close-file="/srv/samba/shares/finance/budget_2027_draft.xlsx"
  ```

#### Escenario C: La pestaña de Versiones Anteriores (Shadow Copies) de Windows está vacía
* **Síntoma:** Los usuarios de Windows hacen clic derecho en el recurso compartido `Finance_Data` -> Propiedades -> pestaña Versiones anteriores, pero no aparece ningún snapshot a pesar de que existen snapshots de LVM/ZFS en el host Linux.
* **Causa raíz:** Cadena `shadow:format` incorrecta o desajuste de zona horaria en la marca de tiempo (`shadow:localtime`).
* **Ejecución de diagnóstico:**
  Verifique la estructura del directorio de montaje de snapshots. Los snapshots deben coincidir estrictamente con el formato de marca de tiempo definido en `shadow:format`:
  ```bash
  $ ls -la /srv/samba/shares/finance/.snapshots
  ```
  ```output
  drwxr-xr-x 4 root root 4096 Aug  6 00:00:00 @GMT-2026.08.06-00.00.00
  drwxr-xr-x 4 root root 4096 Aug  5 00:00:00 @GMT-2026.08.05-00.00.00
  ```
  Asegúrese de que `shadow:basedir` apunte a la raíz de la ruta del recurso compartido `/srv/samba/shares/finance` y de que `vfs objects` ubique `shadow_copy2` **antes** de `default` o `acl_xattr` en la precedencia de ejecución si es necesario.

---

### 5.3 Sintaxis de filtros de diagnóstico profundo de paquetes (`tcpdump` y `tshark`)

Al analizar fallas de negociación de protocolos, rechazos de tickets de Kerberos o fallas de cifrado SMB3, capture el tráfico en bruto (raw) en el puerto 445:

```bash
# Capture raw SMB2/3 traffic to pcap file
$ tcpdump -nn -i any port 445 -s 0 -w /tmp/samba_traffic.pcap
```

Analice el flujo de paquetes capturado utilizando la CLI de `tshark` para aislar los códigos de error de estado de SMB:

```bash
$ tshark -r /tmp/samba_traffic.pcap -Y "smb2.nt_status != 0" \
  -T fields -e frame.number -e ip.src -e ip.dst -e smb2.filename -e smb2.nt_status
```
```output
142   10.250.4.12   10.250.0.5   finance/budget.xlsx   0xc0000022  # STATUS_ACCESS_DENIED
289   10.250.4.88   10.250.0.5   finance/secret.doc    0xc0000034  # STATUS_OBJECT_NAME_NOT_FOUND
```

---

## 6. Referencias

* **Objetivos oficiales del examen 300-300 del Linux Professional Institute (LPI):**  
  https://www.lpi.org/our-certifications/lpic-3-300-overview/
* **Documentación oficial de Samba — Página de manual de smb.conf:**  
  https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html
* **Wiki oficial de Samba — Configuración de Samba como miembro de dominio:**  
  https://wiki.samba.org/index.php/Setting_up_Samba_as_a_Domain_Member
* **Wiki oficial de Samba — Configuración de ACLs POSIX y Windows:**  
  https://wiki.samba.org/index.php/Setting_up_POSIX_ACLs
* **Wiki oficial de Samba — Módulos VFS (vfs_acl_xattr, vfs_shadow_copy2, vfs_full_audit):**  
  https://wiki.samba.org/index.php/Virtual_Filesystem_Modules