# Examen LPIC-3 300-300 (v3.0) — Tema 3.1: Configuración de Recursos Compartidos de Samba

**Ponderación:** 20  
**Certificación objetivo:** LPIC-3 Enterprise File and Storage Solutions (Exam 300-300, Version 3.0)  
**Referencia oficial:** [LPI LPIC-3 300 Objectives & Overview](https://www.lpi.org/our-certifications/lpic-3-300-overview/)  
**Documentación de Samba:** [Samba smb.conf Documentation](https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html)

---

## Visión general técnica y fundamentos arquitectónicos

El demonio del servidor de archivos de Samba (`smbd`) proporciona soporte para el protocolo Server Message Block (SMB/CIFS) a través de los puertos TCP `445` (Direct Host SMB) y `139` (NetBIOS Session Service sobre NetBT). En entornos modernos de SRE e Ingeniería de Plataformas en Linux, la configuración de recursos compartidos de Samba requiere equilibrar la negociación del protocolo SMB3, los bits de modo POSIX, atributos extendidos (`xattr`), listas de control de acceso de Windows (NT ACLs), cadenas de complementos del sistema de archivos virtual (VFS) y rendimiento de I/O asincrónico.

### Mecánica clave de la arquitectura
1. **Traducción de NT ACL a POSIX ACL (`acl_xattr` y `acl_tdb`)**: Los clientes de Windows manipulan descriptores de seguridad (DACLs/SACLs) que contienen identificadores de seguridad (SIDs). Samba mapea estos SIDs a User IDs (UIDs) / Group IDs (GIDs) de Linux a través de Winbind (`idmap`) y almacena descriptores de seguridad completos de Windows dentro de atributos extendidos (`user.DOSATTRIB` y `user.NTACL`) en el sistema de archivos subyacente (por ejemplo, ext4, xfs, ZFS).
2. **Máscaras de permisos vs. Herencia explícita de ACL**:
   - `create mask` / `directory mask`: Máscaras `AND` a nivel de bits aplicadas a los bits de modo de creación entrantes solicitados por el cliente.
   - `force create mode` / `force directory mode`: Máscaras `OR` a nivel de bits que aplican bits de permiso obligatorios independientemente de las solicitudes del cliente.
   - `inherit permissions` vs. `inherit acls`: `inherit permissions` copia los permisos POSIX del directorio padre; `inherit acls` utiliza ACLs POSIX nativas (`setfacl`/`getfacl`) para propagar las entradas de ACL predeterminadas (Default ACL) a lo largo de la jerarquía de rutas.
3. **Capa VFS (Virtual File System)**: Samba ejecuta operaciones de archivos a través de una tubería (pipeline) VFS modular. Los módulos colocados en `vfs objects` se ejecutan secuencialmente de izquierda a derecha para operaciones entrantes, y de derecha a izquierda para respuestas salientes. El orden es críticamente importante (por ejemplo, `catia fruit streams_xattr` para compatibilidad con macOS o `shadow_copy2 full_audit` para toma de snapshots y registro de cumplimiento empresarial).

---

## Ejercicios guiados

---

### Ejercicio 1: Mapeo avanzado de POSIX y Windows ACL con directivas de máscara y herencia

#### Escenario
Estás diseñando un recurso compartido de datos de ingeniería seguro y de alta concurrencia en `/srv/samba/engineering` en un servidor Linux. El requisito establece que todos los archivos recién creados deben ser estrictamente legibles y escribibles por el propietario del archivo y el grupo `eng-team`, pero prohibidos para otros (`0660` para archivos, `0770` para directorios). También debés asegurarte de que la propagación nativa de Windows ACL esté habilitada a través de atributos extendidos (`user.NTACL`).

#### Paso 1: Crear la estructura de directorios y establecer la propiedad POSIX base
```bash
sudo mkdir -p /srv/samba/engineering
sudo groupadd -g 2001 eng-team
sudo chown -R root:eng-team /srv/samba/engineering
sudo chmod 2770 /srv/samba/engineering
```
*Salida esperada:*
```text
(No output returned on success; verify with ls -ld /srv/samba/engineering)
drwxr-sr-x 2 root eng-team 4096 Aug  6 12:00 /srv/samba/engineering
```

#### Paso 2: Garantizar el soporte del sistema de archivos para atributos extendidos
Verificá que los atributos extendidos estén habilitados en el sistema de archivos que aloja `/srv/samba/engineering`:
```bash
sudo getfattr -d /srv/samba/engineering
```
*Salida esperada:*
```text
# file: srv/samba/engineering
```
*(Si no se devuelve ningún error, los atributos extendidos están activos. En XFS y ext4 con núcleos modernos, `user_xattr` está activo por defecto).*

#### Paso 3: Configurar `/etc/samba/smb.conf` con reglas de herencia explícitas
Añadí el siguiente manifiesto de producción a `/etc/samba/smb.conf`:

```ini
[engineering]
    comment = Engineering Team Secure Data Repository
    path = /srv/samba/engineering
    read only = no
    browseable = yes
    guest ok = no

    # Identity and Group Enforcement
    force group = eng-team
    
    # Permission Masks
    create mask = 0660
    force create mode = 0660
    directory mask = 0770
    force directory mode = 0770
    
    # POSIX & Windows ACL Inheritance Control
    inherit permissions = yes
    inherit acls = yes
    map acl inherit = yes
    
    # Enable Extended Attribute VFS for NT ACL Storage
    vfs objects = acl_xattr
    acl_xattr:ignore system acls = no
```

#### Paso 4: Validar la sintaxis con `testparm`
```bash
sudo testparm -s /etc/samba/smb.conf
```
*Salida esperada:*
```text
Load smb config files from /etc/samba/smb.conf
Loaded services file OK.
Weak setup is: Operational
Server role: ROLE_STANDALONE

[engineering]
	comment = Engineering Team Secure Data Repository
	path = /srv/samba/engineering
	force group = eng-team
	read only = No
	create mask = 0660
	directory mask = 0770
	force create mode = 0660
	force directory mode = 0770
	inherit acls = Yes
	inherit permissions = Yes
	map acl inherit = Yes
	vfs objects = acl_xattr
```

#### Paso 5: Recargar el servicio Samba
```bash
sudo systemctl reload smbd
```
*Salida esperada:*
```text
(Silent success; check `systemctl status smbd` for active status)
```

---

#### Preguntas de verificación — Ejercicio 1

1. **Pregunta 1.1:** ¿Cuál es la operación matemática exacta que realiza `smbd` al combinar el modo de creación de archivos solicitado por el cliente (`requested_mode`), `create mask` y `force create mode`?
2. **Pregunta 1.2:** ¿Cuál es la diferencia técnica entre `inherit permissions = yes` e `inherit acls = yes`, y por qué es esencial configurar `vfs objects = acl_xattr` para los clientes SMB que ejecutan Windows 11 / Windows Server 2022?

---

### Ejercicio 2: Controles de acceso granulares, restricciones de red y delegación de identidad

#### Escenario
Necesitás restringir el acceso a un recurso compartido financiero `[finance_audit]` ubicado en `/srv/samba/finance`. Solo los usuarios que pertenezcan al grupo `fin-auditors` o el usuario explícito `auditor1` que se conecten desde la subred corporativa `192.168.50.0/24` o el host de confianza `10.10.10.15` deben recibir acceso. Las conexiones desde `192.168.50.250` deben bloquearse explícitamente a pesar de que se encuentran dentro de la subred permitida. Además, cualquier escritura dentro de este recurso compartido debe ejecutarse bajo la identidad del sistema de `fin-sysops`.

#### Paso 1: Preparar las cuentas del sistema y el directorio destino
```bash
sudo groupadd fin-auditors
sudo useradd -M -s /usr/sbin/nologin fin-sysops
sudo useradd -M -s /usr/sbin/nologin auditor1
sudo mkdir -p /srv/samba/finance
sudo chown -R fin-sysops:fin-auditors /srv/samba/finance
sudo chmod 0770 /srv/samba/finance
```

#### Paso 2: Configurar `/etc/samba/smb.conf` para restricciones de red y usuario
Añadí la siguiente sección a `/etc/samba/smb.conf`:

```ini
[finance_audit]
    comment = Financial Audit Storage - Strictly Confidential
    path = /srv/samba/finance
    browseable = yes
    read only = no
    guest ok = no

    # Host-based Network Access Controls
    hosts allow = 192.168.50. 10.10.10.15 EXCEPT 192.168.50.250
    hosts deny = ALL

    # User and Group Access Restrictions
    valid users = @fin-auditors, auditor1
    invalid users = root, guest, anonymous
    write list = @fin-auditors, auditor1

    # Identity Delegation / Impersonation
    force user = fin-sysops
    force group = fin-auditors
```

#### Paso 3: Probar la lógica de restricción de hosts usando `testparm`
`testparm` permite evaluar la lógica de `hosts allow` / `hosts deny` frente a combinaciones hipotéticas de nombre de host/IP del cliente:
```bash
sudo testparm /etc/samba/smb.conf 192.168.50.45 client45.example.com
```
*Salida esperada:*
```text
Load smb config files from /etc/samba/smb.conf
Loaded services file OK.
...
Allow connection from 192.168.50.45 (192.168.50.45) to finance_audit
```

Ahora probá contra la IP restringida (`192.168.50.250`):
```bash
sudo testparm /etc/samba/smb.conf 192.168.50.250 client250.example.com
```
*Salida esperada:*
```text
Load smb config files from /etc/samba/smb.conf
Loaded services file OK.
...
Deny connection from 192.168.50.250 (192.168.50.250) to finance_audit
```

---

#### Preguntas de verificación — Ejercicio 2

1. **Pregunta 2.1:** En el orden de evaluación de Samba, si una dirección IP coincide tanto con un patrón de `hosts allow` como con un patrón de `hosts deny` (o una cláusula explícita `EXCEPT`), ¿qué directiva tiene prioridad?
2. **Pregunta 2.2:** ¿Cuáles son las implicaciones de seguridad y auditoría de usar `force user = fin-sysops` en un recurso compartido de Samba de múltiples usuarios?

---

### Ejercicio 3: Arquitectura de tubería de módulos VFS y ocultamiento avanzado de archivos

#### Escenario
El cumplimiento empresarial requiere auditar todas las operaciones de escritura/eliminación de SMB en un archivo legal público `/srv/samba/legal`. Además, los archivos eliminados no deben desvincularse (unlink) inmediatamente; en su lugar, deben redirigirse a un directorio oculto `.recycle` dentro del recurso compartido. Los archivos temporales que terminen en `.tmp`, `.bak` o que comiencen con `~$` (archivos de bloqueo temporal de Office) deben ser bloqueados para su carga (`veto files`). Los archivos que comiencen con un punto (`.`) deben ocultarse de los listados de directorios normales.

#### Paso 1: Crear la ruta del recurso compartido y la infraestructura de la papelera de reciclaje
```bash
sudo mkdir -p /srv/samba/legal/.recycle
sudo chmod 1777 /srv/samba/legal/.recycle
sudo chown -R root:domain_users /srv/samba/legal 2>/dev/null || sudo chown -R root:nogroup /srv/samba/legal
sudo chmod 0775 /srv/samba/legal
```

#### Paso 2: Configurar `/etc/samba/smb.conf` con la cadena VFS y filtros veto
Añadí la configuración del recurso compartido `[legal_archive]`:

```ini
[legal_archive]
    comment = Legal Document Repository with Compliance Auditing
    path = /srv/samba/legal
    read only = no
    browseable = yes
    guest ok = no

    # File Hiding & Exclusion Masks
    hide dot files = yes
    hide unreadable = yes
    veto files = /*.tmp/*.bak/~$*/
    delete veto files = yes
    dont descend = /.recycle

    # VFS Module Chain (Evaluated Left to Right)
    vfs objects = full_audit recycle

    # VFS: full_audit Configuration
    full_audit:prefix = %u|%I|%m|%S
    full_audit:facility = LOCAL7
    full_audit:priority = NOTICE
    full_audit:success = pwrite unlink rename mkdir rmdir
    full_audit:failure = all

    # VFS: recycle Configuration
    recycle:repository = .recycle
    recycle:keeptree = yes
    recycle:versions = yes
    recycle:touch = yes
    recycle:maxsize = 0
    recycle:exclude = *.tmp, *.temp, *.bak
    recycle:excludedir = /tmp, /temp
```

#### Paso 3: Configurar Rsyslog para capturar logs de auditoría de VFS de Samba
Añadí el enrutamiento de syslog para `LOCAL7` en `/etc/rsyslog.d/45-samba-audit.conf`:
```bash
echo "local7.notice /var/log/samba/vfs_audit.log" | sudo tee /etc/rsyslog.d/45-samba-audit.conf
sudo systemctl restart rsyslog
sudo systemctl reload smbd
```

#### Paso 4: Validar la ejecución de VFS con operaciones de clientes reales
Simulá la creación y eliminación de un archivo a través de `smbclient`:
```bash
smbclient //localhost/legal_archive -U "auditor1%Password123" -c "put /etc/issue testdoc.txt; rm testdoc.txt"
```
*Salida esperada:*
```text
putting file /etc/issue as \testdoc.txt (0.2 kb/s) (average 0.2 kb/s)
rm-ing file \testdoc.txt
```

Verificá que `testdoc.txt` se haya movido a `.recycle` en lugar de ser destruido:
```bash
ls -la /srv/samba/legal/.recycle/
```
*Salida esperada:*
```text
total 12
drwxrwxrwt 2 root     nogroup 4096 Aug  6 12:15 .
drwxr-xr-x 3 root     nogroup 4096 Aug  6 12:15 ..
-rw-r--r-- 1 auditor1 nogroup   26 Aug  6 12:15 testdoc.txt
```

Inspeccioná el archivo de registro (log) de auditoría:
```bash
sudo tail -n 5 /var/log/samba/vfs_audit.log
```
*Salida esperada:*
```text
Aug 6 12:15:02 server smbd_audit: auditor1|127.0.0.1|localhost|legal_archive|pwrite|ok|testdoc.txt
Aug 6 12:15:02 server smbd_audit: auditor1|127.0.0.1|localhost|legal_archive|unlink|ok|testdoc.txt
```

---

#### Preguntas de verificación — Ejercicio 3

1. **Pregunta 3.1:** ¿Qué sucede cuando un cliente SMB intenta crear o cargar un archivo que coincide con el patrón definido en `veto files = /*.tmp/*.bak/~$*/`? ¿En qué se diferencia esto de `hide files`?
2. **Pregunta 3.2:** Si se configura `vfs objects = shadow_copy2 full_audit recycle`, ¿en qué orden se procesan las llamadas `pwrite` durante las operaciones de guardado de archivos, y qué sucede si `full_audit` se enumera DESPUÉS de `recycle`?

---

### Ejercicio 4: Integración de impresión empresarial con CUPS y mecánica del Spooler

#### Escenario
Estás integrando un servidor de impresión Linux empresarial en un entorno de Active Directory / SMB. Samba debe exponer todas las impresoras locales del Common Unix Printing System (CUPS) automáticamente, proporcionar distribución de controladores de impresora de Windows mediante Point-and-Print a través del recurso compartido `[print$]`, y deshabilitar la arquitectura RPC Spoolss si la descarga de controladores se gestiona fuera de banda (out-of-band) para ahorrar recursos de memoria del demonio.

#### Paso 1: Configuración global de impresión de Samba en `/etc/samba/smb.conf`
Modificá la sección `[global]` y añadí los recursos compartidos `[printers]` y `[print$]`:

```ini
[global]
    workgroup = CORPORATE
    server string = Enterprise Print Server
    security = user

    # CUPS Integration Mechanics
    printing = cups
    printcap name = cups
    load printers = yes
    cups connection timeout = 30
    
    # Disable Spoolss RPC service if Point-and-Print is disabled (Optional performance tweak)
    # disable spoolss = yes

[printers]
    comment = All Network Printers
    path = /var/spool/samba
    browseable = no
    guest ok = no
    writable = no
    printable = yes
    create mask = 0700

[print$]
    comment = Windows Printer Driver Repository (Point-and-Print)
    path = /var/lib/samba/printers
    browseable = yes
    read only = yes
    guest ok = no
    write list = root, @lpadmin, "@CORPORATE\Domain Admins"
```

#### Paso 2: Crear los directorios requeridos para el spool y los controladores de impresora
```bash
sudo mkdir -p /var/spool/samba
sudo chmod 1777 /var/spool/samba
sudo mkdir -p /var/lib/samba/printers/{W32X86,x64,COLOR}
sudo chown -R root:lpadmin /var/lib/samba/printers
sudo chmod -R 0775 /var/lib/samba/printers
```

#### Paso 3: Verificar las impresoras cargadas por Samba
```bash
rpcclient -U "auditor1%Password123" localhost -c 'enumprinters'
```
*Salida esperada:*
```text
flags:[0x800000]
name:[\\localhost\PDF_Printer]
description:[\\localhost\PDF_Printer,PDF_Printer,Generic CUPS PDF Printer]
comment:[Generic CUPS PDF Printer]
```

---

#### Preguntas de verificación — Ejercicio 4

1. **Pregunta 4.1:** ¿Cuál es el rol específico de la directiva `disable spoolss = yes`, y qué conjunto de características se pierde en los clientes de Windows cuando este parámetro está habilitado?
2. **Pregunta 4.2:** ¿Por qué la ruta del directorio referenciada en `[printers]` (por ejemplo, `/var/spool/samba`) debe tener configurado el sticky bit (`1777`) en los permisos de modo POSIX?

---

### Ejercicio 5: Herramientas avanzadas de diagnóstico y telemetría en vivo

#### Escenario
Los usuarios informan que los archivos en el recurso compartido `[engineering]` están bloqueados y no se pueden editar. Como Senior SRE, debés inspeccionar las sesiones activas de SMB, determinar los bloqueos de archivos abiertos (bloqueos por rango de bytes [byte-range locks] y bloqueos oportunistas / leases [oplocks]), inspeccionar las resoluciones de nombres NetBIOS y consultar los endpoints RPC de IPC$ directamente.

#### Paso 1: Inspeccionar conexiones activas, recursos compartidos y procesos con `smbstatus`
Ejecutá `smbstatus` con flags de telemetría específicos:

1. **Ver usuarios conectados y versiones de protocolo:**
```bash
sudo smbstatus -b
```
*Salida esperada:*
```text
Samba version 4.19.5-Ubuntu
PID     Username     Group        Machine               Protocol Version         Encryption           Signing              
--------------------------------------------------------------------------------------------------------------------------------
12435   auditor1     eng-team     192.168.50.45 (ipv4:192.168.50.45:54322) SMB3_11                  -                    AES-128-GMAC
```

2. **Ver recursos compartidos conectados:**
```bash
sudo smbstatus -S
```
*Salida esperada:*
```text
Service      pid     Machine       Connected at                     Encryption                   Signing              
--------------------------------------------------------------------------------------------------------------------
engineering  12435   192.168.50.45 Thu Aug  6 12:20:11 2026 EDT     -                            AES-128-GMAC
```

3. **Ver archivos bloqueados y oplocks:**
```bash
sudo smbstatus -L
```
*Salida esperada:*
```text
Locked files:
Pid          User(ID)   DenyMode   Access      R/W        Oplock           SharePath                    Name   Time
------------------------------------------------------------------------------------------------------------------
12435        1001       DENY_NONE  0x120089    RDWR       EXCLUSIVE+BATCH  /srv/samba/engineering      cad_v2.dwg   Thu Aug 6 12:22:01 2026
```

#### Paso 2: Interrogar servicios RPC del servidor con `rpcclient`
Consultá la identidad del servidor, la información del dominio y los recursos compartidos activos utilizando llamadas RPC sobre IPC$:
```bash
rpcclient -U "auditor1%Password123" localhost -c 'srvinfo; netshareenumall'
```
*Salida esperada:*
```text
	localhost        Wk Sv Prq Unx NT SNT Server Message Block
	platform_id     : 500
	os version      : 6.1
	server type     : 0x809a03

netshareenumall response:
	netname: engineering
		type: 0x0
		remark: Engineering Team Secure Data Repository
	netname: IPC$
		type: 0x3
		remark: IPC Service (Server Message Block)
```

#### Paso 3: Validar el estado del recurso compartido en vivo con `netconf` (Verificación de configuración basada en Registro)
Si Samba se gestiona mediante una configuración respaldada en el registro (`config backend = registry`), usá `net`:
```bash
sudo net conf list
```
*Salida esperada:*
```text
[engineering]
	comment = Engineering Team Secure Data Repository
	path = /srv/samba/engineering
	read only = no
	force group = eng-team
```

---

#### Preguntas de verificación — Ejercicio 5

1. **Pregunta 5.1:** Un usuario no puede guardar un archivo debido a un oplock `EXCLUSIVE+BATCH` retenido por un PID de cliente bloqueado/caído. ¿Qué comando puede ejecutar un administrador para terminar ese proceso específico de Samba y liberar el bloqueo sin reiniciar `smbd` por completo?
2. **Pregunta 5.2:** ¿Qué información proporciona `smbstatus -u` en comparación con `smbstatus -L`?

---

## <details><summary>Respuestas y explicaciones técnicas profundas</summary>

### Respuestas del Ejercicio 1

* **1.1:** La máscara de bits del modo de permiso efectivo para un archivo recién creado se calcula como:
  $$\text{Modo efectivo} = ((\text{Modo solicitado} \mathbin{\&} \text{create mask}) \mid \text{force create mode})$$
  Por ejemplo, si un cliente solicita `0666` y los parámetros son `create mask = 0660` y `force create mode = 0660`:
  $$(0666 \mathbin{\&} 0660) \mid 0660 = 0660 \mid 0660 = 0660 \quad (\texttt{rw-rw----})$$
  Esto garantiza que la operación `AND` a nivel de bits elimine los permisos no aprobados (por ejemplo, los bits de `others`), y la operación `OR` a nivel de bits aplique obligatoriamente los permisos requeridos.

* **1.2:** 
  - `inherit permissions = yes` fuerza a los archivos/directorios recién creados a heredar sus bits de permisos POSIX (`rwx`) directamente de los bits de modo del directorio padre, ignorando el modo solicitado por el cliente o `umask`.
  - `inherit acls = yes` garantiza que si un directorio padre tiene Listas de Control de Acceso POSIX (ACLs extendidas definidas mediante `setfacl`), los nuevos archivos hereden esas entradas de Default ACL de forma nativa.
  - `vfs objects = acl_xattr` es crítico para los clientes modernos de Windows porque el sistema operativo Windows utiliza descriptores de seguridad NT (DACLs/SACLs, SIDs, banderas de herencia). Los permisos POSIX estándar de Linux (`rwxrwxrwx`) no pueden representar modelos complejos de permisos de Windows (por ejemplo, reglas de *Deny*, *Change Permissions*, *Take Ownership*). `vfs_acl_xattr` intercepta las solicitudes de ACL de Windows y serializa el NT ACL binario completo dentro del atributo extendido `user.NTACL` en el sistema de archivos.

---

### Respuestas del Ejercicio 2

* **2.1:** Samba evalúa los controles de acceso en una jerarquía estricta de múltiples niveles:
  1. `hosts allow` se evalúa primero. Si se especifica `hosts allow`, SOLO se permiten las IPs de clientes que coincidan con la lista; todas las demás se deniegan implícitamente.
  2. Si se incluye una cláusula `EXCEPT` explícita dentro de `hosts allow` (por ejemplo, `hosts allow = 192.168.50. EXCEPT 192.168.50.250`), cualquier host que coincida con la cláusula `EXCEPT` se deniega de inmediato (**denied**), independientemente de cualquier coincidencia de red más amplia.
  3. `hosts deny` se evalúa a continuación para cualquier host que no coincida explícitamente con `hosts allow`.
  Por lo tanto, las condiciones `EXCEPT` explícitas dentro de `hosts allow` tienen prioridad inmediata y rechazan la conexión coincidente durante la configuración de la sesión SMB antes de que ocurra la autenticación.

* **2.2:** 
  - **Impacto en la seguridad:** `force user = fin-sysops` hace que `smbd` realice un intercambio de identidad de proceso (`setuid()`) para todas las operaciones del sistema de archivos en ese recurso compartido. Independientemente de qué usuario autenticado se haya conectado (por ejemplo, `auditor1`), todos los archivos creados en el disco serán propiedad de `fin-sysops`.
  - **Impacto en la auditoría:** A nivel del sistema de archivos POSIX, el seguimiento de la propiedad estándar del archivo se pierde por completo porque todas las operaciones se originan en `fin-sysops`. Para mantener la auditabilidad, los administradores DEBEN habilitar la auditoría VFS a nivel de Samba (`vfs objects = full_audit`) para que el nombre de usuario autenticado real de SMB (`%u`) se registre en syslog para cada acción de I/O.

---

### Respuestas del Ejercicio 3

* **3.1:** 
  - Cuando un archivo coincide con `veto files`, `smbd` oculta por completo la existencia de los archivos coincidentes de las solicitudes de listado de directorios (`FIND_FIRST2` / `SMB2_GETINFO`) Y rechaza activamente cualquier solicitud del cliente para abrir, crear, escribir o leer archivos que coincidan con el patrón, devolviendo un error `NT_STATUS_ACCESS_DENIED` o `NT_STATUS_OBJECT_NAME_NOT_FOUND`.
  - En contraste, `hide files` solo establece el bit de atributo DOS `DOS_ATTRIBUTE_HIDDEN` en los archivos coincidentes. Los clientes de Windows seguirán viendo los archivos si la opción "Mostrar archivos ocultos" está habilitada en el Explorador de archivos, y los clientes pueden abrirlos y leerlos/escribirlos normalmente.
  - Si se establece `delete veto files = yes` junto con `veto files`, la eliminación de un directorio que contenga archivos vedados forzará a Samba a eliminar de forma recursiva los archivos vedados que contiene; de lo contrario, la eliminación del directorio falla porque el `rmdir` de POSIX falla en directorios no vacíos.

* **3.2:** 
  - Los módulos VFS funcionan como una tubería (pipeline) apilada. Para **solicitudes entrantes** (escritura cliente $\rightarrow$ servidor), los módulos se ejecutan de **izquierda a derecha**: `shadow_copy2` $\rightarrow$ `full_audit` $\rightarrow$ `recycle` $\rightarrow$ sistema de archivos POSIX.
  - Si `full_audit` se coloca DESPUÉS de `recycle`, cuando ocurre la eliminación de un archivo (`unlink`), `recycle` intercepta la llamada, renombra/mueve el archivo a `.recycle/` y devuelve éxito a la pila sin llamar a la llamada del sistema `unlink()` del sistema operativo subyacente. Como resultado, `full_audit` (posicionado después de `recycle`) registraría la operación de forma incorrecta o no registraría un evento de llamada al sistema `unlink` nativo. Por lo tanto, los módulos de auditoría siempre deben colocarse antes de los módulos de modificación/redirección en la cadena de `vfs objects`.

---

### Respuestas del Ejercicio 4

* **4.1:** 
  - `disable spoolss = yes` desactiva por completo el servicio de tubería RPC Spoolss de Samba (`\PIPE\spoolss`).
  - Habilitar esta opción ahorra memoria del demonio y ciclos de CPU en servidores de archivos dedicados que no gestionan impresión.
  - **Característica perdida:** Deshabilitar Spoolss rompe las características de Point-and-Print de Windows. Los clientes de Windows ya no podrán consultar, descargar o actualizar automáticamente los controladores de impresora a través de SMB desde `[print$]`, ni recibirán telemetría de la cola de impresión o notificaciones de estado del spooler a través de las APIs nativas de RPC de Windows. La impresión solo puede ocurrir si los controladores están preinstalados manualmente en los clientes de Windows.

* **4.2:** 
  - Cuando los trabajos de impresión se envían a través de SMB, `smbd` actúa en nombre del usuario de SMB autenticado y escribe archivos de spool temporales en el directorio especificado por `path` en `[printers]` (por ejemplo, `/var/spool/samba`).
  - Debido a que varios usuarios distintos imprimen simultáneamente, todos los usuarios necesitan acceso de escritura para crear archivos temporales en esta carpeta compartida (`0777`).
  - El **Sticky Bit (`1777` / `chmod +t`)** es obligatorio para evitar que usuarios sin privilegios eliminen, modifiquen o sobrescriban archivos temporales de spool de impresión creados por otros usuarios antes de que CUPS termine de procesarlos.

---

### Respuestas del Ejercicio 5

* **5.1:** 
  Un administrador puede terminar el proceso específico que retiene el bloqueo del archivo usando el comando `kill` dirigido al `PID` revelado en `smbstatus -L` o `smbstatus -b`:
  ```bash
  sudo kill -15 12435
  ```
  El demonio padre de Samba monitorea la finalización del proceso hijo `smbd`, limpia los bloqueos de memoria compartida en `locks.tdb` / `locking.tdb`, libera los bloqueos por rango de bytes/oplocks y permite que otros clientes SMB accedan al archivo de inmediato sin necesidad de reiniciar el demonio `smbd` principal por completo.

* **5.2:** 
  - `smbstatus -u` (o `smbstatus -b`) proporciona **Telemetría a nivel de usuario/sesión**: informa sobre las sesiones de usuario autenticadas activas, las direcciones IP/nombres de host de los clientes, el dialecto de negociación de protocolo (por ejemplo, `SMB3_11`), el estado de cifrado (`AES-128-GCM`), los algoritmos de firma de transporte e IDs de procesos hijos individuales (`PIDs`).
  - `smbstatus -L` proporciona **Telemetría de bloqueos y leases**: informa sobre los descriptores de archivos abiertos en todos los recursos compartidos, derechos de acceso (`0x120089`), modos de denegación, bloqueos por rango de bytes y estados de Bloqueo Oportunista de SMB (Oplock) (`EXCLUSIVE`, `BATCH`, `LEASE`).

---

</details>