# LPIC-2 (Exams 201-450 & 202-450) Tema 2.3: File Sharing — Guía Avanzada de Producción & Laboratorios Guiados

---

## 1. Arquitectura Técnica Profunda & Mecánica Interna

### 1.1 Arquitectura de Samba & Mecánica Interna
Samba provee servicios de archivos e impresión utilizando el conjunto de protocolos Server Message Block (SMB) / Common Internet File System (CIFS).

```
+-------------------------------------------------------------------------+
|                              SMB Client                                 |
+-------------------------------------------------------------------------+
                                    | SMB3 / TCP 445 (or NetBIOS TCP 139)
                                    v
+-------------------------------------------------------------------------+
|                             Samba Daemon Layer                          |
|  +------------------------+  +-------------------+  +----------------+  |
|  | smbd (File/Print/ACLs)   |  | nmbd (NetBIOS Name|  | winbindd (AD/  |  |
|  |                        |  |  Resolution/Browse|  |  Domain Identity| |
|  +------------------------+  +-------------------+  +----------------+  |
+-------------------------------------------------------------------------+
       |                         |                           |
       v                         v                           v
+-------------------------------------------------------------------------+
|                        Passdb Backend Engine                            |
|  +-------------------------------------+  +--------------------------+  |
|  | tdbsam (TDB database local store)   |  | ldapsam (OpenLDAP directory| |
|  +-------------------------------------+  +--------------------------+  |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|                  VFS Layer (acl_xattr, fruit, recycle)                  |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|                     Linux Kernel VFS & POSIX ACLs                       |
+-------------------------------------------------------------------------+
```

#### Core Daemons
*   **`smbd`**: Maneja las solicitudes de conexión SMB/CIFS, autenticación de usuarios, autorización contra definiciones de share, file locking (byte-range locking) y operaciones de I/O de archivos/impresoras sobre los puertos TCP 445 (SMB directo sobre TCP) y 139 (SMB sobre servicio de sesión NetBIOS).
*   **`nmbd`**: Maneja la resolución de nombres NetBIOS sobre TCP/IP (NBT) y servicios de browsing (NetBIOS Name Service sobre UDP 137, NetBIOS Datagram Service sobre UDP 138). *Nota: Los entornos SMB modernos integrados con AD operan enteramente sin `nmbd`.*
*   **`winbindd`**: Actúa como el puente de identity mapping entre dominios de Active Directory/NT4 y Linux NSS (Name Service Switch) y PAM (Pluggable Authentication Modules). Traduce SIDs (Security Identifiers) de Windows a UIDs/GIDs de Linux.

#### Passdb Backends
Samba almacena las credenciales de usuario en backends especializados en lugar de usar `/etc/shadow` plano porque la autenticación SMB de Windows requiere hashes NTLM (NT-Hash / LM-Hash) o tickets de Kerberos:
*   **`tdbsam`**: Un formato de base de datos binaria local (`passdb.tdb`) basado en TDB (Trivial DataBase). Alto rendimiento, liviano, adecuado para servidores standalone y domain controllers pequeños. Administrado a través de `pdbedit`.
*   **`ldapsam`**: Conecta Samba a un servidor de directorio OpenLDAP empresarial (target de `smb.conf` `ldapsam:ldap://...`). Ideal para la gestión centralizada de cuentas de usuario a través de topologías de múltiples servidores.

---

### 1.2 Arquitectura NFSv3 vs. NFSv4 & Identity Mapping

```
+-------------------------------------------------------------------------+
|                           NFS Architecture Comparison                   |
+-------------------------------------------------------------------------+
|  NFSv3 (Stateless, Multi-Port, RPC-Dependent)                           |
|  +----------------+    +----------------+    +-----------------------+  |
|  | rpcbind (111)  |--->| rpc.mountd     |--->| rpc.statd / rpc.lockd |  |
|  | Portmapper     |    | Mount Auth     |    | Lock Management       |  |
|  +----------------+    +----------------+    +-----------------------+  |
|         ^                     ^                          ^              |
|         +---------------------+--------------------------+              |
|                               | nfs/TCP 2049                            |
|                               v                                         |
|                       +---------------+                                 |
|                       |  rpc.nfsd     |                                 |
|                       +---------------+                                 |
+-------------------------------------------------------------------------+
|  NFSv4 (Stateful, Single-Port TCP 2049, Compound RPCs, ID Mapping)      |
|  +-------------------------------------------------------------------+  |
|  | Client ---> TCP 2049 (rpc.nfsd)                                   |  |
|  |               |                                                   |  |
|  |               v                                                   |  |
|  |         +------------------+     +----------------------------+   |  |
|  |         | Pseudo-FS Root   | <-> | rpc.idmapd                 |   |  |
|  |         | (fsid=0 / root)  |     | (User@Domain <-> UID/GID)  |   |  |
|  |         +------------------+     +----------------------------+   |  |
|  +-------------------------------------------------------------------+  |
+-------------------------------------------------------------------------+
```

| Atributo Arquitectónico | NFSv3 | NFSv4 / NFSv4.1 / NFSv4.2 |
| :--- | :--- | :--- |
| **Protocol State** | Stateless (requiere `rpc.statd` & `rpc.lockd` para NLM) | Stateful (seguimiento de estado open/close nativo, lease locking) |
| **Network Transport & Ports** | TCP/UDP a través de múltiples puertos RPC dinámicos (`rpcbind` puerto 111, `rpc.mountd`, `rpc.statd`, `rpc.lockd`) | TCP puro en un único puerto determinista **2049** (amigable para Firewall) |
| **Export Hierarchy** | Exportaciones independientes de directorios mapeadas individualmente | Jerarquía de Pseudo-filesystem con raíz en `fsid=0` (o `fsid=root`) |
| **User Identity** | UID/GID numéricos pasados a través de la red (vulnerable a colisiones de UID) | Formato de cadena `user@domain` resuelto localmente por `rpc.idmapd` o kernel idmapper |
| **Security Models** | `sec=sys` (AUTH_SYS / UIDs de confianza), `sec=krb5` | GSS-API integrado: `sec=sys`, `sec=krb5`, `sec=krb5i` (integridad), `sec=krb5p` (privacidad/encriptado) |

---

### 1.3 Mecánica de AutoFS & Systemd Automount

AutoFS monta dinámicamente shares de red cuando se accede a ellos y los desmonta después de un período configurado de inactividad (`timeout`), reduciendo memoria, overhead del kernel de red y mount points obsoletos.

```
                                 AutoFS Kernel VFS Layer
                                           |
    Access /mnt/auto/finance ------------->| Trap access
                                           |
                                           v
                                    autofs daemon (automount)
                                           |
                                           | Inspect /etc/auto.master & map files
                                           v
                                    Execute mount command
                                  (mount.nfs / mount.cifs)
                                           |
                                           v
                                Mount attached to VFS target
```

#### Tipos de Maps de AutoFS
*   **Master Map (`/etc/auto.master`)**: Archivo de configuración de nivel superior que empareja mount points con fuentes de maps.
*   **Indirect Maps**: Mapean rutas relativas a una clave bajo un mount point base común (ej. `/net/share1`, `/net/share2`).
*   **Direct Maps**: Mapean rutas absolutas en cualquier lugar de la jerarquía del filesystem usando la clave `/` (ej. `/data/backup`).

#### Unidades de Systemd Automount (`.automount` y `.mount`)
Systemd reemplaza al AutoFS tradicional utilizando mountpoints `autofs4` del kernel de Linux de forma nativa:
*   Una unidad `.automount` monitorea la ruta de un directorio.
*   Al primer acceso a un archivo (`stat`, `ls`, `cd`), systemd atrapa la solicitud y dispara de forma síncrona la unidad `.mount` correspondiente.

---

## 2. Laboratorios Guiados de Producción

---

### Laboratorio 1: Configuración de Servidor de Archivos Samba 4 Enterprise Endurecido

#### Escenario
Tiene la tarea de desplegar un share seguro de Samba `/srv/samba/finance` para el departamento de `finance` en un servidor Linux de producción. Debe aplicar un acceso estricto de grupo de usuarios (`@finance`), máscaras de creación de archivos personalizadas, funcionalidad VFS audit/recycle, mapping de usuarios a través de `username map` y validar la configuración utilizando `testparm` y `pdbedit`.

#### Paso 1: Creación de Estructura de Directorios, Grupos de Linux y Usuarios del Sistema
Ejecute los siguientes comandos para configurar los grupos del sistema, usuarios y directorio compartido objetivo:

```bash
sudo groupadd finance
sudo useradd -M -s /sbin/nologin alice
sudo useradd -M -s /sbin/nologin bob
sudo usermod -aG finance alice
sudo usermod -aG finance bob

sudo mkdir -p /srv/samba/finance
sudo chown -R root:finance /srv/samba/finance
sudo chmod -R 2770 /srv/samba/finance
```

Salida Esperada:
```text
(No error output returned; verification via ls -ld /srv/samba/finance)
drwxr-sr-x 2 root finance 4096 Aug  6 10:00 /srv/samba/finance
```

#### Paso 2: Aprovisionar Usuarios en Samba Passdb
Agregue `alice` y `bob` a la base de datos interna `tdbsam` de Samba utilizando `smbpasswd`:

```bash
sudo smbpasswd -a alice
sudo smbpasswd -a bob
```

Salida Esperada:
```text
New SMB password:
Retype new SMB password:
Added user alice.
New SMB password:
Retype new SMB password:
Added user bob.
```

Verifique la base de datos passdb utilizando `pdbedit`:

```bash
sudo pdbedit -L -v -u alice
```

Salida Esperada:
```text
Unix username:        alice
NT username:          
Account Flags:        [U          ]
User SID:             S-1-5-21-3928172635-192837465-102938475-1001
Primary Group SID:    S-1-5-21-3928172635-192837465-102938475-513
Full Name:            
Home Directory:       \\server\alice
Home Dir Drive:       
Logon Script:         
Profile Path:         \\server\alice\profile
Domain:               SAMBASERVER
Account desc:         
Workstations:         
Munged dial:          
Logon time:           0
Logoff time:          never
Kickoff time:         never
Password last set:    Thu, 06 Aug 2026 10:05:00 UTC
Password can change:  Thu, 06 Aug 2026 10:05:00 UTC
Password must change: never
Last bad password:    0
Bad password count:   0
Logon hours:          FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEE
```

#### Paso 3: Escribir la Configuración de Producción de Samba (`/etc/samba/smb.conf`)
Cree o edite `/etc/samba/smb.conf` con las configuraciones de seguridad de producción:

```ini
[global]
    workgroup = WORKGROUP
    server string = Production Samba Gateway
    security = user
    passdb backend = tdbsam
    
    # Network Security & Binding
    interfaces = 127.0.0.1/8 192.168.1.0/24
    bind interfaces only = yes
    hosts allow = 127.0.0.1 192.168.1.0/24
    hosts deny = 0.0.0.0/0
    
    # Logging Configuration
    log file = /var/log/samba/log.%m
    max log size = 5000
    log level = 2
    
    # Encryption Protocols
    server min protocol = SMB3
    client max protocol = SMB3
    
    # User Mapping
    username map = /etc/samba/smbusers

[finance]
    comment = Confidential Financial Records
    path = /srv/samba/finance
    browseable = yes
    writable = yes
    read only = no
    valid users = @finance
    write list = @finance
    force group = finance
    create mask = 0660
    directory mask = 0770
    guest ok = no
    
    # VFS Modules for Audit & Recycle Bin Security
    vfs objects = recycle full_audit
    recycle:repository = .recycle
    recycle:keeptree = yes
    recycle:versions = yes
    full_audit:prefix = %u|%I|%m|%S
    full_audit:success = unlink rmdir mkdir write pwrite
    full_audit:failure = none
    full_audit:facility = LOCAL7
    full_audit:priority = NOTICE
```

Cree `/etc/samba/smbusers` para mapear la identidad de dominio de Windows `Administrator` a `root` de Linux:

```text
root = Administrator admin
```

#### Paso 4: Validación Sintáctica con `testparm`
Valide `/etc/samba/smb.conf` en busca de errores de sintaxis de configuración:

```bash
testparm -s /etc/samba/smb.conf
```

Salida Esperada:
```text
Load smb config files from /etc/samba/smb.conf
Loaded services file OK.
Weak crypto is allowed by smb.conf (default)

Server role: ROLE_STANDALONE

# Section name: [global]
	bind interfaces only = Yes
	hosts allow = 127.0.0.1 192.168.1.0/24
	hosts deny = 0.0.0.0/0
	interfaces = 127.0.0.1/8 192.168.1.0/24
	log file = /var/log/samba/log.%m
	log level = 2
	max log size = 5000
	server min protocol = SMB3
	server string = Production Samba Gateway
	username map = /etc/samba/smbusers
	idmap config * : backend = tdb

# Section name: [finance]
	comment = Confidential Financial Records
	create mask = 0660
	directory mask = 0770
	force group = finance
	path = /srv/samba/finance
	read only = No
	valid users = @finance
	write list = @finance
	vfs objects = recycle full_audit
	full_audit:facility = LOCAL7
	full_audit:failure = none
	full_audit:priority = NOTICE
	full_audit:prefix = %u|%I|%m|%S
	full_audit:success = unlink rmdir mkdir write pwrite
	recycle:versions = yes
	recycle:keeptree = yes
	recycle:repository = .recycle
```

#### Paso 5: Iniciar el Servicio Samba y Probar la Autenticación
Inicie `smbd`:

```bash
sudo systemctl restart smbd
sudo systemctl enable smbd
```

Pruebe el acceso a través de `smbclient` como la usuaria `alice`:

```bash
smbclient //127.0.0.1/finance -U alice%password123 -c "ls"
```

Salida Esperada:
```text
  .                                   D        0  Thu Aug  6 10:10:00 2026
  ..                                  D        0  Thu Aug  6 10:10:00 2026

		104806400 blocks of size 1024. 89234120 blocks available
```

---

### Preguntas de Verificación — Laboratorio 1

1. **Pregunta 1.1**: ¿Cuál es la diferencia arquitectónica entre `valid users = @finance` y `write list = @finance` dentro de `/etc/samba/smb.conf`? ¿Qué sucede si se establece `read only = yes` en la definición del share mientras que `write list = alice` está definido?
2. **Pregunta 1.2**: ¿Por qué se prefiere `passdb backend = tdbsam` sobre backends legacy más antiguos como `smbpasswd`? ¿Qué utilidad de CLI debe usarse para inspeccionar atributos extendidos, bloqueos de cuenta y SIDs almacenados dentro de `tdbsam`?
3. **Pregunta 1.3**: Cuando `vfs objects = full_audit` está habilitado, ¿a dónde envía `smbd` sus entradas de log de auditoría por defecto, y cómo puede un administrador capturar estos eventos en un archivo separado?

---

### Laboratorio 2: Configuración de Servidor NFSv4 Enterprise con Identity Mapping & Verificación Diagnóstica

#### Escenario
Construya un servidor de archivos NFSv4 de nivel enterprise exportando `/exports/secdata` exclusivamente a través de NFSv4. Configure exportaciones de pseudo-root (`fsid=0`), aplique mapping de ID de usuario numérico a través de `rpc.idmapd`, configure las exportaciones de clientes en `/etc/exports` y diagnostique las operaciones de daemons RPC con `nfsstat`, `rpcinfo` y `exportfs`.

#### Paso 1: Construir la Jerarquía de Directorios NFSv4 y el Pseudo-Root
NFSv4 introduce un único namespace unificado de sistema de archivos. Cree un directorio pseudo-root `/exports` y realice un bind-mount del directorio de datos compartido real dentro de él:

```bash
sudo mkdir -p /exports/secdata
sudo mkdir -p /srv/nfs/secdata

# Apply bind mount to integrate into the pseudo-root
sudo mount --bind /srv/nfs/secdata /exports/secdata
```

Para hacer que este bind mount sea permanente a través de reinicios del sistema, añada la siguiente línea a `/etc/fstab`:

```text
/srv/nfs/secdata    /exports/secdata    none    bind    0    0
```

#### Paso 2: Configurar `/etc/idmapd.conf`
Configure el daemon de ID mapping de NFSv4 tanto en el servidor como en el cliente para traducir cadenas `user@domain` a UIDs numéricos del sistema local:

```ini
[General]
Verbosity = 2
Pipefs-Directory = /var/lib/nfs/rpc_pipefs
Domain = internal.lab.net

[Mapping]
Nobody-User = nobody
Nobody-Group = nogroup

[Translation]
Method = nsswitch
```

#### Paso 3: Configurar `/etc/exports`
Defina las exportaciones NFSv4 en `/etc/exports`. El pseudo-root debe declararse con `fsid=0` (o `fsid=root`):

```text
# Pseudo-filesystem Root export for NFSv4 clients
/exports                  192.168.1.0/24(ro,sync,no_subtree_check,crossmnt,fsid=0)

# Export definition for secure data
/exports/secdata          192.168.1.0/24(rw,sync,no_subtree_check,root_squash,anonuid=65534,anongid=65534)
```

#### Paso 4: Exportar Shares y Recargar Daemon
Aplique las exportaciones usando `exportfs` e inicie los daemons requeridos:

```bash
sudo exportfs -rav
sudo systemctl restart nfs-server
sudo systemctl restart rpc-idmapd
```

Salida Esperada de `exportfs -rav`:
```text
exporting 192.168.1.0/24:/exports/secdata
exporting 192.168.1.0/24:/exports
```

Verifique las exportaciones activas con `exportfs -v`:

```bash
sudo exportfs -v
```

Salida Esperada:
```text
/exports      	192.168.1.0/24(ro,sync,wdelay,hide,nocrossmnt,secure,no_root_squash,no_all_squash,no_subtree_check,secure_locks,acl,no_pnfs,fsid=0,anonuid=65534,anongid=65534)
/exports/secdata
              	192.168.1.0/24(rw,sync,wdelay,hide,nocrossmnt,secure,root_squash,no_all_squash,no_subtree_check,secure_locks,acl,no_pnfs,anonuid=65534,anongid=65534)
```

#### Paso 5: Diagnósticos RPC Avanzados
Ejecute `rpcinfo` para asegurarse de que el registro del servicio RPC esté limpio:

```bash
rpcinfo -p localhost
```

Salida Esperada:
```text
   program vers proto   port  service
    100000    4   tcp    111  portmapper
    100000    3   tcp    111  portmapper
    100000    2   tcp    111  portmapper
    100005    1   tcp  20048  mountd
    100005    3   tcp  20048  mountd
    100003    3   tcp   2049  nfs
    100003    4   tcp   2049  nfs
```

Ejecute `nfsstat -s` para ver las estadísticas del servidor NFS:

```bash
nfsstat -s
```

Salida Esperada:
```text
Server rpc stats:
calls      badcalls   badclnt    badauth    xdrcall
124        0          0          0          0

Server nfs v4 operations:
null         compound     
2 0%         122 98%      

Server nfs v4 compound ops:
OP0-BADOP    OP1-READLINK OP2-GATTR    OP3-LOOKUP   OP4-GETATTR  
0 0%         0 0%         0 0%         12 9%        45 36%       
OP5-SETATTR  OP6-LOOKUPP  OP7-NVERIFY  OP8-VERIFY   OP9-HOMEPAGE 
0 0%         4 3%         0 0%         0 0%         0 0%         
```

Monte el share NFSv4 desde una máquina cliente (o localhost):

```bash
sudo mkdir -p /mnt/nfs_client
sudo mount -t nfs4 -o proto=tcp,port=2049 192.168.1.50:/secdata /mnt/nfs_client
```

---

### Preguntas de Verificación — Laboratorio 2

1. **Pregunta 2.1**: En NFSv4, ¿por qué se requiere `fsid=0` (o `fsid=root`) en `/etc/exports`, y cómo difiere la sintaxis de montaje del cliente entre NFSv3 (`mount -t nfs 192.168.1.50:/exports/secdata /mnt`) y NFSv4 (`mount -t nfs4 192.168.1.50:/secdata /mnt`)?
2. **Pregunta 2.2**: Explique la consecuencia operativa de `root_squash` versus `no_root_squash` en `/etc/exports`. Si un usuario remoto con UID 0 escribe un archivo en una exportación configurada con `root_squash,anonuid=5000,anongid=5000`, ¿qué propiedad tendrá el archivo recién creado en el disco local?
3. **Pregunta 2.3**: ¿Qué información de diagnóstico proporciona `showmount -e <NFS_IP>`, y por qué podría fallar `showmount` al consultar un servidor NFSv4 puro que ha deshabilitado `rpcbind` y `rpc.mountd`?

---

### Laboratorio 3: Automontaje Dinámico con AutoFS y Unidades Automount de Systemd

#### Escenario
Despliegue el montaje dinámico de targets utilizando dos técnicas enterprise distintas:
1. Indirect y Direct Maps de AutoFS para directorios NFS home/project.
2. Unidades nativas `systemd.automount` para shares de Samba.

---

#### Parte A: Implementación de Maps de AutoFS

##### Paso 1: Configuración del Master Map (`/etc/auto.master`)
Configure `/etc/auto.master` para registrar un indirect map para `/mnt/auto` y un direct map a través de `/etc/auto.direct`:

```text
# Master Map
/mnt/auto      /etc/auto.indirect  --timeout=300
/-             /etc/auto.direct    --timeout=180
```

##### Paso 2: Archivo de Indirect Map (`/etc/auto.indirect`)
Cree `/etc/auto.indirect` para el montaje dinámico de directorios de proyectos:

```text
# Key        Options                          Location
projects     -rw,soft,intr,nosuid,proto=tcp   192.168.1.50:/exports/secdata
docs         -ro,soft,intr,proto=tcp          192.168.1.50:/exports/docs
```

##### Paso 3: Archivo de Direct Map (`/etc/auto.direct`)
Cree `/etc/auto.direct` para rutas explícitas de filesystem:

```text
# Absolute Path           Options                       Location
/var/build/artifacts      -rw,sync,proto=tcp,hard       192.168.1.50:/exports/builds
```

##### Paso 4: Iniciar el Servicio AutoFS y Probar el Acceso
Asegúrese de que los directorios mount point existan, reinicie `autofs` y active montajes on-demand:

```bash
sudo mkdir -p /var/build/artifacts
sudo systemctl restart autofs
sudo systemctl enable autofs
```

Active el automount accediendo a la ruta:

```bash
ls -l /mnt/auto/projects
```

Verifique el montaje activo usando `df -hT` o `mount`:

```bash
mount | grep secdata
```

Salida Esperada:
```text
192.168.1.50:/exports/secdata on /mnt/auto/projects type nfs4 (rw,nosuid,relatime,vers=4.2,rsize=1048576,wsize=1048576,namlen=255,hard,proto=tcp,timeo=600,retrans=2,sec=sys,clientaddr=192.168.1.10,local_lock=none,addr=192.168.1.50)
```

---

#### Parte B: Implementación de Unidades Automount de Systemd

##### Paso 1: Definir la Unidad `.mount` (`/etc/systemd/system/mnt-samba-finance.mount`)
Los nombres de las unidades de Systemd **deben** coincidir estrictamente con la cadena de ruta del montaje objetivo (ej. `/mnt/samba/finance` se mapea a `mnt-samba-finance.mount`):

```ini
[Unit]
Description=Production Samba Finance Share Mount
After=network.target

[Mount]
What=//192.168.1.50/finance
Where=/mnt/samba/finance
Type=cifs
Options=credentials=/etc/samba/credentials.cred,uid=1001,gid=1001,file_mode=0660,dir_mode=0770

[Install]
WantedBy=multi-user.target
```

Cree el archivo de credenciales `/etc/samba/credentials.cred`:

```ini
username=alice
password=password123
domain=WORKGROUP
```

Establezca permisos seguros en el archivo de credenciales:

```bash
sudo chmod 0600 /etc/samba/credentials.cred
```

##### Paso 2: Definir la Unidad `.automount` (`/etc/systemd/system/mnt-samba-finance.automount`)

```ini
[Unit]
Description=Automount for Production Samba Finance Share
ConditionPathExists=/mnt/samba/finance

[Automount]
Where=/mnt/samba/finance
TimeoutIdleSec=300

[Install]
WantedBy=multi-user.target
```

##### Paso 3: Habilitar y Activar Systemd Automount
Recargue el daemon de systemd, cree el directorio de montaje objetivo y active **únicamente** la unidad `.automount`:

```bash
sudo mkdir -p /mnt/samba/finance
sudo systemctl daemon-reload
sudo systemctl enable --now mnt-samba-finance.automount
```

Verifique el estado de la unidad:

```bash
systemctl status mnt-samba-finance.automount
```

Salida Esperada:
```text
● mnt-samba-finance.automount - Automount for Production Samba Finance Share
     Loaded: loaded (/etc/systemd/system/mnt-samba-finance.automount; enabled; vendor preset: disabled)
     Active: active (waiting) since Thu 2026-08-06 10:25:00 UTC; 10s ago
   Triggers: ● mnt-samba-finance.mount
      Where: /mnt/samba/finance

Aug 06 10:25:00 server systemd[1]: Set up automount Automount for Production Samba Finance Share.
```

Active automount mediante acceso CLI:

```bash
ls -la /mnt/samba/finance
```

Verifique la unidad de montaje activa:

```bash
systemctl status mnt-samba-finance.mount
```

Salida Esperada:
```text
● mnt-samba-finance.mount - Production Samba Finance Share Mount
     Loaded: loaded (/etc/systemd/system/mnt-samba-finance.mount; static)
     Active: active (mounted) since Thu 2026-08-06 10:26:12 UTC; 2s ago
      Where: /mnt/samba/finance
       What: //192.168.1.50/finance
      Tasks: 0 (limit: 4915)
     Memory: 1.2M
     CGroup: /system.slice/mnt-samba-finance.mount
```

---

### Preguntas de Verificación — Laboratorio 3

1. **Pregunta 3.1**: En `/etc/auto.master` de AutoFS, ¿cuál es la diferencia sintáctica y operativa precisa entre una entrada indirecta como `/mnt/auto /etc/auto.indirect` y una entrada directa como `/- /etc/auto.direct`?
2. **Pregunta 3.2**: Al configurar unidades de automount de systemd, ¿por qué es obligatorio nombrar los archivos estrictamente de acuerdo con su ruta de destino (ej. `mnt-samba-finance.automount` para `/mnt/samba/finance`)? ¿Qué sucede si el nombre de archivo se desvía de esta convención?
3. **Pregunta 3.3**: ¿Por qué los administradores deben activar y habilitar la unidad `.automount` a través de systemctl, pero **no** habilitar la unidad `.mount` directamente al utilizar automounting on-demand de systemd?

---

## 3. Playbook Avanzado de Diagnóstico & Solución de Problemas

### 3.1 Diagrama de Flujo & Comandos de Diagnóstico de Samba

```
                              Samba Connection Failure
                                         |
                       +-----------------+-----------------+
                       |                                   |
                       v                                   v
             Configuration Syntax Check           Network/Auth Check
                       |                                   |
              `testparm -s /etc/samba/smb.conf`    `smbclient -L //IP -U user`
                       |                                   |
                       v                                   v
             Inspect Daemon Passdb                 Packet Level Trace
                       |                                   |
              `pdbedit -L -v -u user`              `tcpdump -i eth0 port 445`
```

#### Comandos de Diagnóstico

1.  **Validar la sintaxis de configuración y valores por defecto activos**:
    ```bash
    testparm -v /etc/samba/smb.conf
    ```
2.  **Inspeccionar atributos de usuario, flags y SIDs de Samba**:
    ```bash
    sudo pdbedit -L -v
    ```
3.  **Realizar listado de shares desde el cliente de red y verificación de negociación de protocolo**:
    ```bash
    smbclient -L //127.0.0.1 -U alice --option="client max protocol=SMB3"
    ```
4.  **Consultar resolución de nombres NetBIOS**:
    ```bash
    nmblookup -A 192.168.1.50
    ```
5.  **Auditar conexiones activas de SMB en tiempo real**:
    ```bash
    sudo smbstatus --shares --processes --locks
    ```

---

### 3.2 Diagrama de Flujo & Comandos de Diagnóstico de NFS

```
                               NFS Mount Failure
                                       |
                     +-----------------+-----------------+
                     |                                   |
                     v                                   v
             RPC Daemon Registration            Export Table Verification
                     |                                   |
             `rpcinfo -p <NFS_IP>`               `exportfs -v` or `showmount -e`
                     |                                   |
                     v                                   v
           Protocol Level Counters              Kernel Trace Analysis
                     |                                   |
             `nfsstat -c` / `nfsstat -s`         `rpcdebug -m nfs -s all`
```

#### Comandos de Diagnóstico

1.  **Verificar registros del RPC Portmapper**:
    ```bash
    rpcinfo -p 192.168.1.50
    ```
2.  **Inspeccionar directamente la tabla de exportaciones del kernel**:
    ```bash
    sudo exportfs -v
    ```
3.  **Verificar estadísticas de NFS del lado del servidor para llamadas descartadas o fallos de autenticación**:
    ```bash
    nfsstat -s
    ```
4.  **Verificar contadores de llamadas RPC de NFS del lado del cliente**:
    ```bash
    nfsstat -c
    ```
5.  **Habilitar dinámicamente flags de debugging de NFS del kernel de Linux**:
    ```bash
    # Enable NFS client debugging
    sudo rpcdebug -m nfs -s all
    
    # Read diagnostic kernel ring buffer
    sudo dmesg -wH | grep -i nfs
    
    # Clear debugging flags after diagnosis
    sudo rpcdebug -m nfs -c all
    ```
6.  **Captura de paquetes de red para operaciones compuestas de NFSv4**:
    ```bash
    sudo tcpdump -nn -s 0 -i any port 2049 -w nfs_trace.pcap
    ```

---

## 4. Referencias a la Documentación Oficial

*   **Linux Professional Institute (LPI) LPIC-2 Objectives**: [https://www.lpi.org/our-certifications/lpic-2-overview/](https://www.lpi.org/our-certifications/lpic-2-overview/)
*   **Samba Official Documentation & smb.conf Manual**: [https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html](https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html)
*   **Linux Kernel NFS Documentation**: [https://www.kernel.org/doc/html/latest/filesystems/nfs/index.html](https://www.kernel.org/doc/html/latest/filesystems/nfs/index.html)
*   **AutoFS Linux Documentation**: [https://man7.org/linux/man-pages/man5/autofs.5.html](https://man7.org/linux/man-pages/man5/autofs.5.html)
*   **Systemd Mount Unit Specifications**: [https://www.freedesktop.org/software/systemd/man/latest/systemd.mount.html](https://www.freedesktop.org/software/systemd/man/latest/systemd.mount.html)

---

## 5. Respuestas de Verificación & Explicaciones Detalladas

<details>
<summary>Haga clic para expandir la clave de respuestas y explicaciones</summary>

### Respuestas del Laboratorio 1

*   **Respuesta 1.1**:
    *   `valid users = @finance` actúa como un **gatekeeper de autenticación/autorización**: solo a los usuarios que pertenecen al grupo de Linux `finance` se les permite conectarse al share. A todos los demás usuarios autenticados se les deniega el acceso.
    *   `write list = @finance` especifica a qué usuarios autorizados se les conceden permisos de escritura.
    *   Si `read only = yes` se establece globalmente en la definición del share, pero se define `write list = alice` (o `@finance`), Samba **anula** `read only = yes` específicamente para los usuarios enumerados en `write list`. Por lo tanto, los usuarios en `write list` obtienen acceso de lectura y escritura, mientras que todos los demás usuarios válidos permanecen restringidos al acceso de solo lectura.

*   **Respuesta 1.2**:
    *   `tdbsam` almacena cuentas de usuario en una base de datos binaria estructurada TDB (`passdb.tdb`), soportando búsquedas indexadas, SIDs, flags de cuenta de usuario (ej. bloqueada, deshabilitada, la contraseña nunca expira), historial de contraseñas y conteos de contraseñas incorrectas. El legacy `smbpasswd` era un archivo plano sin atributos extendidos de SID ni escalabilidad de rendimiento.
    *   La utilidad de línea de comandos utilizada para inspeccionar, modificar y administrar cuentas en `tdbsam` es **`pdbedit`** (ej. `pdbedit -L -v`).

*   **Respuesta 1.3**:
    *   Por defecto, `vfs objects = full_audit` emite eventos de syslog utilizando la facility `LOCAL7` (o la facility de syslog especificada en `full_audit:facility`). En sistemas Linux, estos mensajes llegan a `/var/log/syslog` o `/var/log/messages` junto con los eventos estándar del sistema.
    *   Para enrutar los eventos de full_audit a un archivo de log dedicado (ej. `/var/log/samba/audit.log`), un administrador configura una regla en el daemon de registro del sistema (rsyslog o syslog-ng):
        ```text
        # /etc/rsyslog.d/samba-audit.conf
        local7.*    /var/log/samba/audit.log
        & stop
        ```
        Luego reinicie rsyslog: `systemctl restart rsyslog`.

---

### Respuestas del Laboratorio 2

*   **Respuesta 2.1**:
    *   En NFSv4, `fsid=0` (o `fsid=root`) define la **raíz de la jerarquía de pseudo-filesystem**. Los clientes NFSv4 ven todos los directorios exportados en relación con esta raíz designada.
    *   **Diferencia de Sintaxis de Montaje**:
        *   NFSv3 requiere especificar la ruta absoluta completa del filesystem del servidor:
            `mount -t nfs 192.168.1.50:/exports/secdata /mnt`
        *   NFSv4 especifica rutas relativas al pseudo-root `fsid=0`:
            `mount -t nfs4 192.168.1.50:/secdata /mnt` (omitiendo `/exports`).

*   **Respuesta 2.2**:
    *   `root_squash` mapea cualquier solicitud entrante del UID 0 / GID 0 (el usuario `root` del cliente) a la cuenta anónima sin privilegios (`anonuid`/`anongid`, por defecto `nobody`/`65534`). `no_root_squash` deshabilita esta protección, permitiendo a los clientes root remotos capacidades completas de root en el filesystem del servidor.
    *   Si un usuario root remoto crea un archivo en una exportación con `root_squash,anonuid=5000,anongid=5000`, el archivo resultante en el disco local del servidor será propiedad de **UID 5000** y **GID 5000**.

*   **Respuesta 2.3**:
    *   `showmount -e <NFS_IP>` consulta al daemon RPC `mountd` remoto para listar todas las exportaciones activas de directorios declaradas en `/etc/exports`.
    *   En un entorno NFSv4 puro donde `rpcbind` (puerto 111) y `rpc.mountd` (puerto 20048) están deshabilitados por seguridad, `showmount` **fallará** con un error de timeout de conexión RPC (`rpc mount export: RPC: Unable to receive; errno = Connection refused`), porque NFSv4 no utiliza `rpc.mountd` ni `rpcbind` (opera enteramente sobre el puerto TCP 2049).

---

### Respuestas del Laboratorio 3

*   **Respuesta 3.1**:
    *   Un **Indirect Map** (`/mnt/auto /etc/auto.indirect`) administra subdirectorios dinámicos *bajo* un directorio base especificado (`/mnt/auto`). El directorio base `/mnt/auto` es propiedad de AutoFS, y los subdirectorios (ej. `/mnt/auto/projects`) aparecen on-demand cuando se accede a ellos.
    *   Un **Direct Map** (`/- /etc/auto.direct`) especifica rutas de montaje objetivo absolutas ubicadas en cualquier lugar a través de la jerarquía del filesystem del sistema (ej. `/var/build/artifacts`). La clave `/-` indica a AutoFS que las claves del map contienen rutas absolutas completas.

*   **Respuesta 3.2**:
    *   Systemd utiliza algoritmos de transformación de cadenas estrictos para convertir rutas de mount point en nombres de unidades: las barras se reemplazan con guiones (ej. `/mnt/samba/finance` $\rightarrow$ `mnt-samba-finance.mount` / `mnt-samba-finance.automount`).
    *   Si el nombre de archivo se desvía de este mapping de ruta exacto, systemd se negará a cargar o vincular la unidad automount a su directorio objetivo correspondiente, fallando con un error de configuración de unidad no válida (`Unit name ... does not match path ...`).

*   **Respuesta 3.3**:
    *   La unidad `.automount` es responsable de crear el descriptor de archivo autofs del kernel en la ruta objetivo para monitorear las llamadas entrantes del filesystem. Cuando ocurre el acceso, la unidad `.automount` activa e inicia automáticamente la unidad `.mount` asociada on-demand.
    *   Si un administrador habilita e inicia manualmente la unidad `.mount` directamente en el arranque, systemd montará el share de red remoto inmediatamente durante el arranque, omitiendo por completo el mecanismo de automounting on-demand y manteniendo el montaje de red permanentemente adjunto.

</details>