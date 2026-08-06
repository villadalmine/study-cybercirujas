# Examen LPIC-3 300-300 (v3.0) — Tema 4.1: Configuración del Cliente Samba
**Público Objetivo:** SREs, Platform Architects, Linux Systems Engineers  
**Peso:** 20  
**Referencia Oficial:** [LPI LPIC-3 300 Objectives](https://www.lpi.org/our-certifications/lpic-3-300-overview/) | [Samba Documentation](https://www.samba.org/samba/docs/) | [Linux Kernel CIFS VFS Documentation](https://www.kernel.org/doc/html/latest/admin-guide/cifs/cifs.html)

---

## Ejercicio 1: Diagnósticos Avanzados por CLI y Extracción de Datos (`smbclient`, `rpcclient`, `smbget`)

### Arquitectura y Mecánica
La interacción del cliente con los servidores SMB/CIFS requiere una comprensión profunda de la negociación de protocolos, la configuración de la sesión (session setup) y la ejecución de tuberías RPC (RPC pipes).
* **Negociación y Transporte del Protocolo SMB:** `smbclient` utiliza NetBIOS sobre TCP (puerto 139) o TCP/IP nativo (puerto 445). Durante la negociación, el cliente y el servidor acuerdan el dialecto (por ejemplo, `SMB2_02`, `SMB3_11`), la firma de mensajes (`client signing`) y las capacidades de cifrado.
* **Arquitectura de RPC Pipe (`rpcclient`):** MS-RPC funciona sobre named pipes de SMB (por ejemplo, `\PIPE\lsarpc`, `\PIPE\samr`, `\PIPE\srvsvc`). `rpcclient` establece un contexto DCE/RPC autenticado, lo que permite la ejecución de consultas de bajo nivel contra el Security Account Manager (SAM) o Active Directory Domain Services (AD DS).
* **Recuperación de Alto Rendimiento (`smbget`):** `smbget` opera como una utilidad similar a `wget` que utiliza `libsmbclient` para transferencias recursivas y no interactivas de carga útil SMB de múltiples archivos.

---

### Pasos de Ejecución Práctica

#### Paso 1.1: Negociar límites de dialecto y enumerar shares ocultos con `smbclient`
Ejecute `smbclient` contra el controlador de dominio `dc01.prod.internal` forzando el dialecto SMB3 (`-m SMB3`) con un nivel de salida de depuración detallada (verbose) 3 (`-d 3`) para analizar la secuencia de NTLMSSP session setup.

```bash
smbclient -L //dc01.prod.internal -U "PROD\\sre_admin%P@ssw0rd2026!" -m SMB3 -d 3
```

**Salida Esperada:**
```text
lp_load_ex: reviewing free structure members
Initialising global parameters
rhost_resolve_addrinfo: resolved 1 hostnames or IP addresses
Connecting to 192.168.10.10 at port 445
SMB2/3 dialect negotiation client requested min SMB2_02 max SMB3_11
Selected dialect SMB3_11
GENSEC backend 'gssapi_spnego' chosen
GENSEC backend 'schannel' chosen
Got challenge flags: 0xe2088297
NTLMSSP authentication succeeded to DC01
Sharename       Type      Comment
---------       ----      -------
ADMIN$          Disk      Remote Admin
C$              Disk      Default share
IPC$            IPC       Remote IPC
NETLOGON        Disk      Logon server share 
SYSVOL          Disk      Logon server share 
finance_data    Disk      Financial Archival Storage
SMB1 disabled -- Server does not support SMB1 protocol
Reconnecting with SMB3_11...
```

#### Paso 1.2: Ejecutar consultas DCE/RPC pipe mediante `rpcclient`
Conéctese a los endpoints RPC de Remote SAM y Local Security Authority (LSA) en el objetivo `192.168.10.10` para consultar el SID del dominio, enumerar usuarios del dominio y resolver Security Identifiers (SIDs) a nombres de usuario.

```bash
rpcclient -U "PROD\\sre_admin%P@ssw0rd2026!" 192.168.10.10 -c "lsaquery; enumdomusers; lookupsids S-1-5-21-382910482-1928374829-291827364-500"
```

**Salida Esperada:**
```text
Domain Name: PROD
Domain SID: S-1-5-21-382910482-1928374829-291827364
user:[Administrator] rid:[0x1f4]
user:[Guest] rid:[0x1f5]
user:[krbtgt] rid:[0x1f9]
user:[sre_admin] rid:[0x450]
user:[svc_backup] rid:[0x451]
S-1-5-21-382910482-1928374829-291827364-500 PROD\Administrator (1)
```

#### Paso 1.3: Recuperación recursiva no interactiva de shares mediante `smbget`
Extraiga archivos de registro (log files) de forma recursiva (`-R`) desde el share `finance_data` hacia `/var/log/audit_ingest/` mientras registra las acciones con salida de depuración (`-v`).

```bash
mkdir -p /var/log/audit_ingest
smbget -R -u "sre_admin" -p "P@ssw0rd2026!" -w "PROD" -v smb://192.168.10.10/finance_data/logs/ -o /var/log/audit_ingest/
```

**Salida Esperada:**
```text
Using Workgroup: PROD, User: sre_admin
Connecting to smb://192.168.10.10/finance_data/logs/
Downloading /logs/audit_20260801.log ...
[===================================================================>] 100% (4.2MB/s)
Downloading /logs/audit_20260802.log ...
[===================================================================>] 100% (5.1MB/s)
Downloaded 2 files (9.3MB) in 1.98 seconds.
```

---

### Preguntas de Verificación

1. **Pregunta 1:** Ejecuta `smbclient //fs01/data -U user` y recibe `NT_STATUS_RESOURCE_NAME_NOT_FOUND`. Sin embargo, `smbclient -L //fs01` muestra que el share `data` existe. ¿Qué comportamiento de SMB de bajo nivel o problema de credenciales causó más probablemente esta discrepancia?
2. **Pregunta 2:** Al ejecutar `rpcclient`, ¿cuál es la diferencia precisa entre los comandos `lookupnames` y `lookupsids` en términos de operación de protocolo y entradas/salidas esperadas?

---

## Ejercicio 2: Montajes CIFS en Kernel-Space (`mount.cifs`, `/etc/fstab`, Kerberos y Multiuser)

### Arquitectura y Mecánica
La integración de SMB a nivel de kernel es administrada por el módulo VFS `cifs.ko` de Linux (`cifs-utils`).
* **Transporte de Sesión y Multiplexación:** A diferencia de las herramientas en user-space (`libsmbclient`), kernel CIFS crea mapeos de inode VFS directamente en la memoria del sistema.
* **Modos de Seguridad (`sec=`):**
  * `sec=ntlmssp`: Hashing de contraseña NTLMv2 envuelto en NTLMSSP.
  * `sec=krb5`: Autenticación por ticket de Kerberos v5 a través de GSS-API. Requiere un TGT válido de usuario/host en la caché de credenciales `krb5cc`.
  * `sec=krb5i`: Autenticación Kerberos con firma de paquetes SMB (packet signing) habilitada para prevenir ataques de replay de Man-in-the-Middle (MitM).
* **Arquitectura Multiuser (`multiuser`):** Con `multiuser`, el montaje inicial se realiza utilizando una cuenta de servicio maestra. El acceso a archivos posterior por cada usuario fuerza al kernel de Linux a intercambiar claves de sesión SMB de forma dinámica según el Kerberos TGT del usuario local del sistema (encontrado en su caché `KRB5CCNAME` a través de `cifs.upcall`).

---

### Pasos de Ejecución Práctica

#### Paso 2.1: Crear un archivo de credenciales externo seguro
Almacene credenciales sensibles de SMB en un archivo dedicado con permisos POSIX estrictos para evitar la exposición de credenciales en los listados de procesos (`ps aux`).

```bash
mkdir -p /etc/samba/credentials
cat << 'EOF' > /etc/samba/credentials/finance.creds
username=svc_cifs_mount
password=SecureK8sStorageEnv2026!
domain=PROD
EOF

chmod 600 /etc/samba/credentials/finance.creds
ls -la /etc/samba/credentials/finance.creds
```

**Salida Esperada:**
```text
-rw------- 1 root root 78 Aug 6 12:00 /etc/samba/credentials/finance.creds
```

#### Paso 2.2: Realizar un montaje CIFS autenticado por Kerberos con firma de paquetes (`sec=krb5i`) y `multiuser`
Verifique la existencia del TGT de Kerberos del dominio usando `klist`, luego ejecute un montaje de grado empresarial.

```bash
kinit -k -t /etc/krb5.keytab host/appserver01.prod.internal@PROD.INTERNAL
klist
mkdir -p /mnt/finance_secure
mount -t cifs //dc01.prod.internal/finance_data /mnt/finance_secure \
  -o sec=krb5i,multiuser,cruid=0,vers=3.1.1,uid=1050,gid=1050,dir_mode=0770,file_mode=0660
```

**Salida Esperada:**
```text
Ticket cache: FILE:/tmp/krb5cc_0
Default principal: host/appserver01.prod.internal@PROD.INTERNAL

Valid starting       Expires              Service principal
08/06/26 12:05:00  08/06/26 22:05:00  krbtgt/PROD.INTERNAL@PROD.INTERNAL
```

#### Paso 2.3: Configurar `/etc/fstab` para la persistencia en producción
Añada una entrada de montaje completamente calificada y sintácticamente válida a `/etc/fstab` utilizando el archivo de credenciales, el forzado explícito de la versión de SMB (`vers=3.1.1`) y opciones de mapeo de usuario dinámico.

```bash
cat << 'EOF' >> /etc/fstab
//dc01.prod.internal/finance_data /mnt/finance_secure cifs credentials=/etc/samba/credentials/finance.creds,sec=krb5i,multiuser,vers=3.1.1,uid=1050,gid=1050,dir_mode=0770,file_mode=0660,_netdev 0 0
EOF

mount -a -t cifs
df -Th /mnt/finance_secure
```

**Salida Esperada:**
```text
Filesystem                         Type  Size  Used Avail Use% Mounted on
//dc01.prod.internal/finance_data cifs  2.0T  450G  1.6T  22% /mnt/finance_secure
```

---

### Preguntas de Verificación

1. **Pregunta 1:** Cuando un usuario regular (`uid=1002`) intenta acceder a un directorio dentro de `/mnt/finance_secure` montado con `sec=krb5,multiuser`, se encuentra con `Permission denied (Required key not available)`. Root puede acceder al montaje sin problemas. ¿Cuál es la causa raíz y cómo resuelve el kernel las credenciales?
2. **Pregunta 2:** Explique el impacto operativo de especificar `_netdev` en `/etc/fstab` para montajes CIFS en distribuciones Linux empresariales administradas por Systemd.

---

## Ejercicio 3: Interrogación Administrativa por CLI mediante la Utilidad `net`

### Arquitectura y Mecánica
La herramienta `net` es el marco de administración principal de Samba. Opera bajo diferentes modos de ejecución:
* `net rpc`: Interroga a las máquinas objetivo mediante llamadas DCE/RPC sobre SMB (funciona en servidores independientes y dominios NT4).
* `net ads`: Interroga a los controladores de dominio de Active Directory utilizando los protocolos LDAP, Kerberos y CLDAP.
* `net lookup`: Realiza consultas de resolución de nombres contra WINS, broadcast NetBIOS o DNS para resolver nombres NetBIOS a direcciones IP.

---

### Pasos de Ejecución Práctica

#### Paso 3.1: Ejecutar búsquedas NetBIOS/WINS utilizando `net lookup`
Localice la infraestructura IP de controladores de dominio consultando tipos de nombre NetBIOS (por ejemplo, `<1C>` para controladores de dominio).

```bash
net lookup dc
net lookup dsgetdc PROD.INTERNAL
```

**Salida Esperada:**
```text
192.168.10.10
Got DC info from host dc01.prod.internal
GUID: 8f9b2d21-a3b4-4c5e-9f12-3b4c5d6e7f8a
Domain name: PROD.INTERNAL
Forest name: PROD.INTERNAL
DC IP: 192.168.10.10
Flags: 0xe0003fdd (PDC GC DS KDC SHARES TIMESERV)
```

#### Paso 3.2: Realizar validación del estado de Domain Join y del entorno ADS
Consulte el estado de incorporación (join) a Active Directory, la sincronización de hora del controlador de dominio y las contraseñas de cuenta de máquina (Machine Account Passwords) utilizando `net ads`.

```bash
net ads status -U "sre_admin%P@ssw0rd2026!"
net ads testjoin
```

**Salida Esperada:**
```text
Object DN: CN=APPSERVER01,OU=Servers,DC=prod,DC=internal
sAMAccountName: APPSERVER01$
userAccountControl: 4096 (WORKSTATION_TRUST_ACCOUNT)
pwdLastSet: 133674829100000000
Join is OK
```

#### Paso 3.3: Enumerar relaciones de confianza de dominio mediante `net rpc`
Interrogue las estructuras de confianza de dominio utilizando llamadas RPC directamente contra el subsistema SAM/LSA.

```bash
net rpc trustdom list -U "sre_admin%P@ssw0rd2026!" -S dc01.prod.internal
```

**Salida Esperada:**
```text
Trusted domains list:
CORP.GLOBAL      (Direct Outbound Trust, Active Directory)
PARTNERS.EXT     (External Trust, NTLM Authenticated)
```

---

### Preguntas de Verificación

1. **Pregunta 1:** ¿Cuál es la distinción técnica entre ejecutar `net rpc join` frente a `net ads join` al integrar un cliente Linux en un entorno Microsoft?
2. **Pregunta 2:** Un SRE ejecuta `net lookup host appserver01` y falla, pero `ping appserver01` funciona. ¿Qué parámetro de configuración en `/etc/samba/smb.conf` dicta cómo las herramientas del cliente Samba resuelven nombres de host?

---

## Ejercicio 4: Ajuste Global del Cliente y Endurecimiento de Protocolo (`smb.conf`)

### Arquitectura y Mecánica
Los parámetros del cliente definidos en `/etc/samba/smb.conf` (dentro de la sección `[global]`) dictan los comportamientos predeterminados para `smbclient`, `rpcclient`, `net` y las aplicaciones que consumen `libsmbclient`.
* **Restricciones de Rango de Protocolo (`client min protocol` / `client max protocol`):** Previene downgrades a dialectos inseguros (por ejemplo, SMB1/NT1).
* **Firmas Criptográficas (`client signing`):** Fuerza o deshabilita la firma de paquetes SMB a nivel del runtime del cliente (`mandatory`, `auto`, `disabled`).
* **Estrategia de Resolución de Nombres (`name resolve order`):** Controla la cadena de alternativa (fallback chain) al resolver destinos de servidores SMB.

---

### Pasos de Ejecución Práctica

#### Paso 4.1: Construir un archivo `/etc/samba/smb.conf` de cliente endurecido y zero-trust
Despliegue una configuración del lado del cliente que prohíba estrictamente los protocolos heredados (legacy), exija la firma de paquetes y configure la autenticación Kerberos SPNEGO.

```bash
cat << 'EOF' > /etc/samba/smb.conf
[global]
   workgroup = PROD
   realm = PROD.INTERNAL
   security = ads

   # Protocol Hardening Boundaries
   client min protocol = SMB3_00
   client max protocol = SMB3_11
   client ipc min protocol = SMB3_00
   client ipc max protocol = SMB3_11

   # Cryptographic & Auth Controls
   client signing = required
   client NTLMv2 auth = yes
   client use spnego = yes
   client protected auth = yes

   # Name Resolution Mechanics
   name resolve order = host bcast lmhosts

   # Logging & Diagnostics
   log level = 2 client:3
   max log size = 5000
EOF

testparm -s /etc/samba/smb.conf
```

**Salida Esperada:**
```text
Load smb config files from /etc/samba/smb.conf
Loaded services file OK.
Weak crypto is allowed by smb.conf attribute 'allow weak auth'

Server role: ROLE_DOMAIN_MEMBER

# Section listing omitted for brevity...
[global]
	client max protocol = SMB3_11
	client min protocol = SMB3_00
	client ipc max protocol = SMB3_11
	client ipc min protocol = SMB3_00
	client NTLMv2 auth = Yes
	client protected auth = Yes
	client signing = required
	client use spnego = Yes
	name resolve order = host bcast lmhosts
	realm = PROD.INTERNAL
	security = ADS
	workgroup = PROD
```

---

### Preguntas de Verificación

1. **Pregunta 1:** ¿Cómo afecta la configuración `client ipc min protocol = SMB3_00` a las operaciones de domain join y a las herramientas de administración RPC (`rpcclient`, `net rpc`) al interactuar con controladores de dominio heredados de Samba 3.x?
2. **Pregunta 2:** ¿Cuál es la diferencia operativa entre `name resolve order = host bcast` y `name resolve order = lmhosts bcast host`?

---

<details>
<summary><strong>Respuestas y Explicaciones Detalladas</strong></summary>

### Respuestas del Ejercicio 1

1. **Respuesta 1:** El error `NT_STATUS_RESOURCE_NAME_NOT_FOUND` indica que, aunque la conexión al servidor y la enumeración de shares (`IPC$`) tuvieron éxito, la ruta de destino especificada está mal escrita, es sensible a mayúsculas/minúsculas en implementaciones SMB que no son de Windows, o está protegida por Access-Based Enumeration (ABE). Si ABE está habilitado en el share de destino, los usuarios sin permisos de lectura recibirán `NT_STATUS_RESOURCE_NAME_NOT_FOUND` o `NT_STATUS_ACCESS_DENIED` al intentar un acceso explícito a la ruta.
2. **Respuesta 2:** `lookupnames` convierte cadenas legibles de nombre de usuario/grupo (por ejemplo, `PROD\sre_admin`) en SIDs binarios/cadena (por ejemplo, `S-1-5-21-...-1104`) consultando la interfaz RPC `LookupNames` de LSA (`\PIPE\lsarpc`). Por el contrario, `lookupsids` realiza la transformación exactamente inversa: traduce SIDs a nombres de cuenta de dominio completamente cualificados a través de la interfaz de RPC pipe `LookupSids` de LSA.

---

### Respuestas del Ejercicio 2

1. **Respuesta 1:** La opción `multiuser` indica al controlador CIFS del kernel que NO reutilice las credenciales del usuario que realizó el montaje para accesos posteriores por parte de otros usuarios locales de Linux. Cuando el usuario `uid=1002` accede a `/mnt/finance_secure`, el kernel busca una caché de credenciales de Kerberos propiedad de `uid=1002` (a través del helper `cifs.upcall`). Dado que `uid=1002` no ha inicializado un TGT válido (`kinit`), no hay ninguna clave de Kerberos disponible en su contexto de keyring/caché (`FILE:/tmp/krb5cc_1002`), desencadenando `Required key not available`.
2. **Respuesta 2:** La opción `_netdev` es una directiva de systemd/mount que informa explícitamente al marco de inicialización del SO que el punto de montaje depende de la conectividad de red activa. Retrasa el montaje durante el arranque hasta que el stack de red (`NetworkManager` / `systemd-networkd`) esté completamente en línea y evita los tiempos de espera (timeouts) por fallo de arranque. Durante el apagado, systemd desmonta los shares con `_netdev` *antes* de desactivar las interfaces de red, evitando bloqueos al desmontar y kernel panics.

---

### Respuestas del Ejercicio 3

1. **Respuesta 1:** `net rpc join` se basa estrictamente en la autenticación NTLM/SMB sobre named pipes de DCE/RPC para vincular la cuenta de máquina a un dominio estilo NT4 o Active Directory en modo de compatibilidad. `net ads join` utiliza protocolos nativos de Active Directory: Kerberos para la autenticación de cliente a DC, LDAP para la ubicación del objeto contenedor/OU y actualizaciones de DNS Dinámico para registrar los registros A/AAAA de la máquina en el DC.
2. **Respuesta 2:** El parámetro es `name resolve order` definido en `/etc/samba/smb.conf`. Los comandos estándar del sistema operativo (`ping`, `curl`) utilizan el subsistema NSS definido en `/etc/nsswitch.conf` (`hosts: files dns`). Las herramientas del cliente Samba (`net`, `smbclient`) analizan la configuración `name resolve order` de `/etc/samba/smb.conf` (que por defecto es `lmhosts wins host bcast`), ignorando `/etc/nsswitch.conf` a menos que se analice explícitamente `host`.

---

### Respuestas del Ejercicio 4

1. **Respuesta 1:** Los controladores de dominio heredados de Samba 3.x o versiones antiguas de Windows Server (2003/2008) a menudo utilizan SMB1 para los named pipes IPC (`\PIPE\lsarpc`, `\PIPE\samr`). Configurar `client ipc min protocol = SMB3_00` fuerza todo el tráfico de comunicación entre procesos (IPC) sobre SMB3. Si el DC remoto no admite SMB3 para pipes IPC, las llamadas a `rpcclient` y `net rpc` fallarán de inmediato con `NT_STATUS_REVISION_MISMATCH` o `NT_STATUS_NOT_SUPPORTED`.
2. **Respuesta 2:** `name resolve order = host bcast` fuerza a las aplicaciones cliente de Samba a consultar primero la resolución estándar del sistema (DNS/`/etc/hosts`), recurriendo a transmisiones por broadcast NetBIOS IPv4 (`bcast`) si el DNS falla. `name resolve order = lmhosts bcast host` fuerza a Samba a buscar primero en el archivo estático heredado `/etc/samba/lmhosts`, seguido de broadcasts NetBIOS, y solo consulta el DNS (`host`) como último recurso de alternativa (fallback). Esto último afecta gravemente el rendimiento en entornos grandes si los nombres de host DNS no coinciden con los archivos `lmhosts` estáticos.

</details>