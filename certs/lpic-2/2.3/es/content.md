# LPIC-2 (Exámenes 201-450 y 202-450, v4.5) — Tema 208: File Sharing (Ponderación: 8)
## Guía de Estudio de Producción para SRE y Arquitectura de Plataforma

---

## 1. Motivación Arquitectónica de Producción y Declaración del Problema

En entornos de producción empresariales, el intercambio de archivos por red (network file sharing) constituye la columna vertebral del almacenamiento persistente compartido, el acceso a estado dinámico a través de clusters de contenedores/VMs, destinos de respaldos de bases de datos y repositorios de archivos heterogéneos integrados con identidad. 

Los ingenieros se enfrentan a una dualidad arquitectónica fundamental:
1. **Cargas de trabajo POSIX nativas de Unix y de alto rendimiento (high-throughput)** que operan sobre clusters Linux y requieren bajo overhead, transferencia de archivos a nivel de kernel y mapeo de identidad alineado con esquemas UID/GID.
2. **Acceso multiplataforma heterogéneo (Windows, macOS, Linux)** integrado en dominios de Active Directory (AD) que requiere protocolos SMB/CIFS, listas de control de acceso de Windows (NTFS ACLs), oplocks/leases de SMB y autenticación Kerberos/SPNEGO.

```
                     +-----------------------------------+
                     |  Enterprise Identity & Storage    |
                     |  Active Directory / FreeIPA / NFS |
                     +-----------------+-----------------+
                                       |
                +----------------------+----------------------+
                |                                             |
   +------------v------------+                   +------------v------------+
   |   NFSv4.2 Server        |                   |  Samba 4 AD Member FS   |
   |   (Kernel nfsd)         |                   |  (smbd / winbindd)      |
   +------------+------------+                   +------------+------------+
                |                                             |
     TCP 2049   | RPC / sec=krb5p                 TCP 445     | SMB3 / NTLMv2 / Kerberos
     Stateful   | POSIX / IDMAP                   Oplocks     | Windows ACLs / Idmap
                |                                             |
   +------------v------------+                   +------------v------------+
   | Linux Compute Nodes     |                   | Windows / macOS / Linux |
   | Kubernetes Persistent V.|                   | Endpoints & Legacy Apps |
   +-------------------------+                   +-------------------------+
```

### Desafíos Arquitectónicos Clave de Producción:
* **Estado del Protocolo y Resiliencia de Red (Protocol Statefulness & Network Resiliency)**: NFSv3 es stateless, apoyándose en daemons RPC auxiliares (`lockd`, `statd`, `mountd`) sobre puertos dinámicos, lo que crea serios problemas de traversado de firewall y bloqueos por split-brain. NFSv4+ unifica la gestión de estado y bloqueos a través de un único puerto TCP (2049), pero introduce seguimiento de leases de clientes y timeouts de recuperación de estado del servidor durante el failover.
* **Mapeo de Identidad y Límites de Seguridad (Identity Mapping & Security Boundaries)**: El `sec=sys` estándar (NFS) confía en el UID/GID provisto por el paquete de red del cliente sin verificación—un riesgo de seguridad importante en redes de cero confianza (zero-trust). NFSv4 en producción requiere Kerberos (`sec=krb5p`) o RPCSEC_GSS, mientras que Samba requiere integración con Active Directory a través de Winbind o SSSD para mapear SIDs de Windows a UIDs/GIDs de Linux de manera determinista.
* **Concurrencia, Bloqueo y Coherencia de Caché (Concurrency, Locking & Cache Coherency)**: Las operaciones de lectura/escritura de alta concurrencia requieren delegación de bloqueos de grano fino (`oplocks` en Samba, write delegations en NFSv4.2). Un ajuste inadecuado resulta en bloqueos mutuos (deadlocks), file handles obsoletos (`ESTALE`) y severa latencia de I/O de archivos.

---

## 2. Comparaciones Técnicas Profundas y Tablas de Compromisos (Trade-offs)

### Tabla 2.1: Comparación de Versiones del Protocolo NFS (NFSv3 vs NFSv4.0 vs NFSv4.1/v4.2)

| Dimensión Técnica | NFSv3 | NFSv4.0 | NFSv4.1 / NFSv4.2 |
| :--- | :--- | :--- | :--- |
| **Modelo de Estado** | Servidor stateless; se apoya en protocolos externos (`NLM`, `NSM`). | Servidor stateful; solicitudes RPC compuestas integradas. | Completamente stateful; RPCs compuestas orientadas a sesión con NFS paralelo (pNFS). |
| **Red y Firewall** | Puertos RPC dinámicos (`rpcbind` / puerto 111, `mountd`, `lockd`). | Puerto único TCP 2049. | Puerto único TCP 2049; soporte para RDMA (RoCE / InfiniBand). |
| **Mecanismo de Identidad** | UIDs/GIDs numéricos en bruto enviados por la red (`sec=sys`). | Mapeo de usuario basado en cadenas (`user@domain`) vía `rpc.idmapd`. | IDMAP basado en cadenas con caché extendida de IDs numéricos (`nfsidmap`). |
| **Autenticación y Seguridad** | Filtrado por IP de cliente; modelo de confianza `sec=sys`; RPCSEC_GSS débil opcional. | RPCSEC_GSS integrado (`sec=krb5`, `sec=krb5i`, `sec=krb5p`). | Soporte obligatorio de cifrado fuerte (`krb5p` con AES-256-CTS-HMAC-SHA1-96). |
| **Bloqueo de Archivos** | Protocolo auxiliar (`lockd` / NLM sobre puerto 4045). | Bloqueo stateful nativo integrado en el protocolo principal. | Bloqueos por lease nativos con garantías de recuperación de estado al reiniciar el servidor. |
| **Características Avanzadas** | Ninguna (POSIX básico). | Pseudo-sistema de archivos (`fsid=0`), ACLs. | pNFS, Copia del lado del servidor (SSC), archivos dispersos / Sparse Files (SEEK_HOLE/SEEK_DATA), Labeled NFS (xattrs de SELinux). |

---

### Tabla 2.2: Comparación Arquitectónica de Protocolos de Almacenamiento en Red (NFSv4.2 vs Samba/SMB3)

| Métrica / Requisito | Linux Kernel NFSv4.2 | Samba 4 / SMB3.1.1 |
| :--- | :--- | :--- |
| **Cargas de Trabajo Objetivo** | Linux HPC de alto rendimiento, PVs de Kubernetes, respaldos de BD. | Recursos compartidos de escritorio multiplataforma, recursos compartidos integrados en dominio AD, Windows CAD. |
| **Arquitectura de SO** | Ejecución en el kernel (`nfsd.ko`), transferencias por socket con zero-copy. | Arquitectura multiproceso en espacio de usuario (`smbd`, `nmbd`, `winbindd`). |
| **Cifrado en Transporte** | Kerberos gss-api (`sec=krb5p` - AES-256 vía RPCSEC_GSS). | Cifrado en transporte nativo de SMB3 AES-128-GCM / AES-256-GCM. |
| **Modelo de Control de Acceso** | Permisos POSIX y ACLs de NFSv4. | ACLs de POSIX mapeadas a descriptores de seguridad NTFS de Windows (`vfs_acl_xattr`). |
| **Coherencia de Caché y Bloqueo** | Delegaciones de archivos y directorios (el servidor retira la delegación ante un conflicto). | Bloqueos oportunistas (`oplocks`), Leases de lectura/escritura/handle de SMB2/3. |
| **Mecanismo de Failover** | Temporizador de lease de recuperación de estado de NFSv4 (período de gracia de ~90s). | Failover transparente (recursos compartidos continuamente disponibles en SMB3 vía CTDB). |

---

## 3. Manifiestos de Producción Sintácticamente Válidos Completos y Configuraciones de Infraestructura

### 3.1 Configuración del Servidor de Almacenamiento NFSv4.2 Empresarial

#### Archivo: `/etc/nfs.conf`
```ini
# Production Enterprise NFSv4 Server Configuration
[general]
 pipefs-directory = /var/lib/nfs/rpc_pipefs

[nfsd]
 threads = 64
 host = 192.168.10.50
 port = 2049
 grace-time = 90
 lease-time = 60
 vers2 = n
 vers3 = n
 vers4 = y
 vers4.0 = y
 vers4.1 = y
 vers4.2 = y

[mountd]
 manage-gids = y
 threads = 16

[statd]
 port = 4000
 outlet-port = 4001

[lockd]
 port = 4045
 udp-port = 4045
 tcp-port = 4045
```

#### Archivo: `/etc/idmapd.conf`
```ini
[General]
Verbosity = 1
Pipefs-Directory = /var/lib/nfs/rpc_pipefs
Domain = enterprise.internal

[Mapping]
Nobody-User = nobody
Nobody-Group = nogroup

[Translation]
Method = nsswitch
```

#### Archivo: `/etc/exports`
```exports
# Root Pseudo-Filesystem for NFSv4 Export Tree
/exports                                    192.168.10.0/24(ro,sync,no_subtree_check,crossmnt,fsid=0,sec=krb5p:krb5i:sys)

# Production High-Performance Application Shared Volume
/exports/app-data                           192.168.10.0/24(rw,sync,no_wdelay,no_root_squash,no_subtree_check,sec=krb5p:sys)

# Secure Backup Vault with User Squashing
/exports/backups                            192.168.10.0/24(rw,sync,root_squash,all_squash,anonuid=65534,anongid=65534,no_subtree_check,sec=krb5p)
```

---

### 3.2 Configuración del Servidor de Archivos Miembro del Dominio Active Directory con Samba 4

#### Archivo: `/etc/krb5.conf`
```ini
[libdefaults]
    default_realm = ENTERPRISE.INTERNAL
    dns_lookup_realm = false
    dns_lookup_kdc = true
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true
    rdns = false
    default_tkt_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
    default_tgs_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96

[realms]
    ENTERPRISE.INTERNAL = {
        kdc = ad01.enterprise.internal:88
        admin_server = ad01.enterprise.internal:749
        default_domain = enterprise.internal
    }

[domain_realm]
    .enterprise.internal = ENTERPRISE.INTERNAL
    enterprise.internal = ENTERPRISE.INTERNAL
```

#### Archivo: `/etc/samba/smb.conf`
```ini
[global]
    # Basic Server Identification & AD Domain Alignment
    workgroup = ENTERPRISE
    realm = ENTERPRISE.INTERNAL
    netbios name = FS01
    server string = Enterprise Samba Production File Server
    server role = member server
    security = ADS

    # Protocol Restrictions & Security Hardening
    client min protocol = SMB3_00
    server min protocol = SMB2_10
    client max protocol = SMB3_11
    server max protocol = SMB3_11
    smb encrypt = required
    server signing = required
    client signing = required
    disable netbios = yes
    smb ports = 445

    # Identity Mapping Architecture (winbindd backend)
    idmap config * : backend = tdb
    idmap config * : range = 30000-39999
    idmap config ENTERPRISE : backend = rid
    idmap config ENTERPRISE : range = 10000-29999
    
    winbind use default domain = yes
    winbind enum users = no
    winbind enum groups = no
    winbind refresh tickets = yes
    winbind offline login = yes
    template shell = /bin/bash
    template homedir = /home/%D/%U

    # VFS Modules & Extended Attributes Mapping
    vfs objects = acl_xattr fruit streams_xattr
    map acl inherit = yes
    store dos attributes = yes

    # Performance Tuning & Async I/O
    aio read size = 1
    aio write size = 1
    use sendfile = yes
    min receivefile size = 16384
    read raw = yes
    write raw = yes
    oplocks = yes
    level2 oplocks = yes

    # Logging Architecture
    log level = 2 winbind:3
    log file = /var/log/samba/log.%m
    max log size = 50000
    logging = systemd

[finance-data]
    comment = Secure Enterprise Financial Records
    path = /srv/samba/finance
    read only = no
    browseable = yes
    guest ok = no
    valid users = @"ENTERPRISE\finance-dept" @"ENTERPRISE\domain admins"
    write list = @"ENTERPRISE\finance-dept"
    force create mode = 0660
    force directory mode = 0770
    inherit permissions = yes
    inherit acls = yes
    vfs objects = acl_xattr fruit streams_xattr full_audit
    full_audit:prefix = %u|%I|%m|%S
    full_audit:success = pwrite unlinkat renameat mkdirat rmdirat
    full_audit:failure = all
    full_audit:facility = LOCAL7
    full_audit:priority = NOTICE

[public-docs]
    comment = Corporate Public Documentation Read-Only Share
    path = /srv/samba/public
    read only = yes
    guest ok = yes
    browseable = yes
    valid users = @"ENTERPRISE\domain users" guest
```

---

### 3.3 Configuraciones de Montaje de Cliente en Producción `/etc/fstab`

```fstab
# Enterprise NFSv4.2 Production Mount with Kerberos & Performance Tuning
192.168.10.50:/exports/app-data /mnt/nfs_app nfs4 rw,noatime,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,sec=krb5p,proto=tcp,nfsvers=4.2,_netdev 0 0

# Samba/CIFS SMB3.1.1 Mount with Active Directory Credentials File & Automated Lock Cleanup
//fs01.enterprise.internal/finance-data /mnt/smb_finance cifs credentials=/etc/samba/credentials.smb,uid=10005,gid=10001,iocharset=utf8,rw,vers=3.1.1,seal,mfsymlinks,noperm,_netdev 0 0
```

#### Archivo: `/etc/samba/credentials.smb`
```ini
username=sre_service_account
password=P@ssw0rd!Secure987654#
domain=ENTERPRISE.INTERNAL
```

---

## 4. Comandos de CLI Reales y Salidas de Terminal Realistas ($)

### 4.1 Verificación de Infraestructura NFS y Diagnósticos RPC

#### Comando: Reexportación de recursos compartidos configurados y visualización de flags de exportación activos
```bash
$ sudo exportfs -arv
```
```text
exporting 192.168.10.0/24:/exports/backups
exporting 192.168.10.0/24:/exports/app-data
exporting 192.168.10.0/24:/exports
```

#### Comando: Inspección de flags de la tabla de exportación activa del kernel a bajo nivel
```bash
$ cat /proc/fs/nfs/exports
```
```text
#Path Client(Flags) #Current Access Control Options
/exports/app-data	192.168.10.0/24(rw,root_squash,sync,wdelay,no_hide,nocrossmnt,sub_tree_check,no_all_squash,sec=390005:sec=1)
/exports/backups	192.168.10.0/24(rw,all_squash,sync,wdelay,no_hide,nocrossmnt,sub_tree_check,anonuid=65534,anongid=65534,sec=390005)
/exports	192.168.10.0/24(ro,root_squash,sync,wdelay,fsid=0,nocrossmnt,sub_tree_check,no_all_squash,sec=390005:sec=390004:sec=1)
```

#### Comando: Verificación de endpoints RPC registrados con `rpcbind`
```bash
$ rpcinfo -p localhost
```
```text
   program vers proto   port  service
    100000    4   tcp    111  portmapper
    100000    3   tcp    111  portmapper
    100000    2   tcp    111  portmapper
    100005    1   tcp   20048  mountd
    100005    3   tcp   20048  mountd
    100003    3   tcp   2049  nfs
    100003    4   tcp   2049  nfs
    100021    4   tcp   4045  nlockmgr
```

#### Comando: Comprobación de estadísticas de cliente/servidor NFS y contadores de llamadas
```bash
$ nfsstat -s
```
```text
Server rpc stats:
calls      badcalls   badclnt    badauth    xdrcall
1489201    0          0          0          0       

Server nfs v4 operations:
null         compound     
31 (0%)      412098 (99%) 

Server nfs v4.2 op statistics:
op0-unused   op1-unused   op2-future   access       close        commit       create       
0 (0%)       0 (0%)       0 (0%)       45102 (10%)  12050 (2%)   8901 (2%)    1002 (0%)    
delegreturn  getattr      getfh        link         lock         lockt        locku        
3102 (0%)    180590 (43%) 98040 (23%)  0 (0%)       4100 (0%)    0 (0%)       4100 (0%)    
lookup       lookup_root  open         openattr     open_confirm open_downgrd read         
12040 (2%)   12 (0%)      12050 (2%)   0 (0%)       0 (0%)       0 (0%)       25010 (6%)   
readdir      readlink     remove       rename       renew        restorefh    savefh       
1400 (0%)    12 (0%)      450 (0%)     102 (0%)     0 (0%)       1890 (0%)    1890 (0%)    
secinfo      setattr      setclientid  setcltconf   verify       write        release_lock 
0 (0%)       2100 (0%)    0 (0%)       0 (0%)       0 (0%)       10490 (2%)   0 (0%)       
```

#### Comando: Inspección de estadísticas de rendimiento de montaje para un montaje NFS activo
```bash
$ mountstats /mnt/nfs_app
```
```text
Stats for 192.168.10.50:/exports/app-data mounted on /mnt/nfs_app:
  NFS mount options: racache=60,rsize=1048576,wsize=1048576,timeo=600,retrans=2,acdirmin=30,acdirmax=60,acregmin=30,acregmax=60,sec=krb5p,port=2049,proto=tcp,nfsvers=4.2
  NFS security flavor: krb5p
  
  RPC statistics:
    78902 RPC requests sent, 78902 RPC replies received (0 retransmissions)
    Average RTT: 0.852 ms
    Average Execution Time: 1.120 ms
    Read bytes: 5242880000 (avg 1048576.0 read bytes per op)
    Write bytes: 2097152000 (avg 1048576.0 write bytes per op)
```

---

### 4.2 Arquitectura Samba y Operaciones de CLI en Active Directory

#### Comando: Validación sintáctica de `smb.conf`
```bash
$ testparm -s /etc/samba/smb.conf
```
```text
Load smb config files from /etc/samba/smb.conf
Loaded services file OK.
Weak crypto is allowed by GnuTLS (default)
Server role: ROLE_DOMAIN_MEMBER

# Global parameters
[global]
	client max protocol = SMB3_11
	client min protocol = SMB3_00
	disable netbios = Yes
	idmap config enterprise : range = 10000-29999
	idmap config enterprise : backend = rid
	idmap config * : range = 30000-39999
	idmap config * : backend = tdb
	log level = 2 winbind:3
	logging = systemd
	netbios name = FS01
	realm = ENTERPRISE.INTERNAL
	security = ADS
	server min protocol = SMB2_10
	server signing = required
	smb encrypt = required
	smb ports = 445
	workgroup = ENTERPRISE
	vfs objects = acl_xattr fruit streams_xattr

[finance-data]
	comment = Secure Enterprise Financial Records
	force create mode = 0660
	force directory mode = 0770
	inherit acls = Yes
	inherit permissions = Yes
	path = /srv/samba/finance
	read only = No
	valid users = @"ENTERPRISE\finance-dept" @"ENTERPRISE\domain admins"
	write list = @"ENTERPRISE\finance-dept"
	vfs objects = acl_xattr fruit streams_xattr full_audit
```

#### Comando: Unirse al dominio de Active Directory utilizando credenciales Kerberos
```bash
$ sudo net ads join -U "sre_admin@ENTERPRISE.INTERNAL"
```
```text
Password for [sre_admin@ENTERPRISE.INTERNAL]:
Using short domain name -- ENTERPRISE
Joined 'FS01' to dns domain 'enterprise.internal'
No DNS domain configured for fs01. Unable to perform DNS Update.
DNS update should be performed by DC or external DNS server.
```

#### Comando: Consulta del estado de pertenencia a Active Directory
```bash
$ sudo net ads status
```
```text
objectClass: top
objectClass: person
objectClass: organizationalPerson
objectClass: user
objectClass: computer
cn: FS01
distinguishedName: CN=FS01,CN=Computers,DC=enterprise,DC=internal
instanceType: 4
whenCreated: 20260806121045.0Z
uSNCreated: 450912
name: FS01
sAMAccountName: FS01$
sAMAccountType: 805306369
dNSHostName: fs01.enterprise.internal
servicePrincipalName: HOST/fs01.enterprise.internal
servicePrincipalName: HOST/FS01
servicePrincipalName: RestrictedKrbHost/FS01
servicePrincipalName: RestrictedKrbHost/fs01.enterprise.internal
```

#### Comando: Prueba de resolución de usuarios de dominio mediante la integración Winbind NSS
```bash
$ getent passwd "ENTERPRISE\jdoe"
```
```text
ENTERPRISE\jdoe:*:10501:10001:John Doe:/home/ENTERPRISE/jdoe:/bin/bash
```

#### Comando: Listado de conexiones activas de clientes, recursos compartidos abiertos y bloqueos por rango de bytes (byte-range locks)
```bash
$ sudo smbstatus --shares --locks
```
```text
Service      pid     Machine       Connected at                  Encryption                   Signing              
--------------------------------------------------------------------------------------------------
finance-data 45102   192.168.10.88 Thu Aug  6 13:40:12 2026 EDT  AES-256-GCM                  partial(AES-128-GMAC)

Locked files:
Pid          Uid        DenyMode   Access      R/W        Oplock           SharePath   Name   Time
--------------------------------------------------------------------------------------------------
45102        10501      DENY_NONE  0x120089    RDWR       EXCLUSIVE+BATCH  /srv/samba/finance   Q3_Audit.xlsx   Thu Aug 6 13:42:01 2026
```

#### Comando: Exploración remota de recursos compartidos Samba usando `smbclient` con autenticación Kerberos
```bash
$ smbclient -k -L //fs01.enterprise.internal
```
```text
Sharename       Type      Comment
---------       ----      -------
finance-data    Disk      Secure Enterprise Financial Records
public-docs     Disk      Corporate Public Documentation Read-Only Share
IPC$            IPC       IPC Service (Enterprise Samba Production File Server)
```

---

## 5. Verificación de Fallas y Guía de Resolución de Problemas (Troubleshooting)

```
                  +-----------------------------------+
                  | Production Incident Diagnostic    |
                  | File Sharing Failure Reported     |
                  +-----------------+-----------------+
                                    |
                    +---------------+---------------+
                    |                               |
          +---------v---------+           +---------v---------+
          |   NFS Issue       |           |   Samba / SMB     |
          +---------+---------+           +---------+---------+
                    |                               |
          +---------v---------+           +---------v---------+
          | 1. Check Port 2049|           | 1. Test smb.conf  |
          |    & rpcinfo      |           |    (testparm)     |
          | 2. Verify IDMAP   |           | 2. Check Winbind  |
          |    (nobody:nobody)|           |    (wbinfo -t)    |
          | 3. Inspect Locks  |           | 3. Audit Oplocks  |
          |    (/proc/locks)  |           |    (smbstatus -L) |
          +-------------------+           +-------------------+
```

### Escenario 5.1: Bloqueo de Montaje NFS / Timeout de RPC / Caída de Paquetes por Firewall

* **Síntoma**: El comando del cliente `mount -t nfs4 192.168.10.50:/exports/app-data /mnt/nfs_app` se bloquea indefinidamente y eventualmente retorna `mount.nfs4: Connection timed out`.
* **Causa Raíz**: ACLs de red, iptables/nftables o firewalls por hardware bloqueando el puerto TCP 2049, o bloqueando el portmapper RPC (puerto TCP/UDP 111).

#### Protocolo Paso a Paso de Diagnóstico y Resolución:

1. **Verificar la alcanzabilidad del puerto TCP 2049 desde el cliente usando `nc` / `nmap`**:
   ```bash
   $ nc -zvw5 192.168.10.50 2049
   ```
   *Salida de Falla Esperada*: `nc: connect to 192.168.10.50 port 2049 (tcp) failed: Connection timed out`

2. **Ejecutar una captura de paquetes en la interfaz del servidor de almacenamiento filtrando por NFS/RPC**:
   ```bash
   $ sudo tcpdump -nn -i eth0 host 192.168.10.105 and \(port 2049 or port 111\)
   ```
   *Observación*: Los paquetes SYN llegan desde el cliente `192.168.10.105.48910 > 192.168.10.50.2049: Flags [S]`, pero no se retorna respuesta SYN-ACK debido a las reglas del firewall del host local.

3. **Comprobar las reglas de Firewall en el servidor**:
   ```bash
   $ sudo nft list ruleset | grep 2049
   ```

4. **Remediación**: Abrir puertos explícitos en el Firewall para NFSv4 en el servidor:
   ```bash
   $ sudo firewall-cmd --permanent --add-service=nfs
   $ sudo firewall-cmd --permanent --add-service=rpc-bind
   $ sudo firewall-cmd --permanent --add-service=mountd
   $ sudo firewall-cmd --reload
   ```

---

### Escenario 5.2: Desajuste de Mapeo de Identidad (Archivos Mapeados a `nobody:nobody`)

* **Síntoma**: El montaje NFSv4 es exitoso, pero todos los archivos pertenecientes a usuarios válidos se muestran como `nobody:nobody` (o UID `65534`).
* **Causa Raíz**: Desajuste en el mapeador de ID basado en cadenas de NFSv4. El servidor y el cliente tienen configuraciones diferentes en `/etc/idmapd.conf` (ej., desajuste de Dominio: el servidor tiene `Domain = enterprise.internal`, el cliente tiene `Domain = localdomain`).

#### Protocolo Paso a Paso de Diagnóstico y Resolución:

1. **Inspeccionar `/etc/idmapd.conf` tanto en el cliente como en el servidor**:
   ```bash
   $ grep "Domain" /etc/idmapd.conf
   ```
   *Salida del Cliente*: `Domain = localdomain`  
   *Salida del Servidor*: `Domain = enterprise.internal`

2. **Verificar la falla de traducción de ID mediante la utilidad `nfsidmap`**:
   ```bash
   $ sudo nfsidmap -u jdoe@enterprise.internal
   ```
   *Salida*: `nfsidmap: key 'jdoe@enterprise.internal': No such file or directory`

3. **Remediación**:
   * Alinear `/etc/idmapd.conf` en ambas máquinas:
     ```ini
     [General]
     Domain = enterprise.internal
     ```
   * Limpiar la caché IDMAP del kernel en el cliente y servidor:
     ```bash
     $ sudo nfsidmap -c
     ```
   * Reiniciar los servicios IDMAP:
     ```bash
     $ sudo systemctl restart rpc-idmapd.service
     ```

---

### Escenario 5.3: Bloqueos Obsoletos (Stale Locks) y Deadlocks de Acceso a Archivos en Samba

* **Síntoma**: Los clientes Samba de Windows o Linux reciben errores de "File Locked by another user" (Archivo bloqueado por otro usuario) al abrir hojas de cálculo compartidas, incluso después de que el usuario original cerrara la aplicación.
* **Causa Raíz**: Oplock de SMB o bloqueo por rango de bytes (byte-range lock) obsoleto que permanece activo en `locking.tdb` debido a una desconexión de red del cliente sin un cierre de sesión (logoff) SMB limpio.

#### Protocolo Paso a Paso de Diagnóstico y Resolución:

1. **Localizar los bloqueos de archivos usando `smbstatus`**:
   ```bash
   $ sudo smbstatus -L | grep "Q3_Audit.xlsx"
   ```
   *Salida*:
   ```text
   45102        10501      DENY_NONE  0x120089    RDWR       EXCLUSIVE+BATCH  /srv/samba/finance   Q3_Audit.xlsx   Thu Aug 6 13:42:01 2026
   ```

2. **Hacer referencia cruzada del PID con la lista de procesos activos**:
   ```bash
   $ ps aux | grep 45102
   ```
   *Salida*: `samba: smbd-notifyd --configfile=/etc/samba/smb.conf [orphaned]`

3. **Verificar bloqueos a nivel de kernel vía `/proc/locks`**:
   ```bash
   $ cat /proc/locks | grep 45102
   ```

4. **Remediación**:
   * Terminar el hilo worker del cliente `smbd` huérfano que mantiene el bloqueo:
     ```bash
     $ sudo kill -9 45102
     ```
   * Para prevenir futuros estancamientos persistentes por bloqueos, habilitar `oplock break wait time` y keepalives de socket adecuados en `smb.conf`:
     ```ini
     [global]
     keepalive = 300
     oplock break wait time = 2000
     ```

---

### Escenario 5.4: Acceso Denegado debido a Restricciones de Seguridad de Contexto SELinux

* **Síntoma**: El cliente recibe `Permission Denied` al intentar escribir en el recurso compartido de Samba `/srv/samba/finance` o en la exportación NFS `/exports/app-data`, a pesar de que los permisos POSIX estándar son `0777`.
* **Causa Raíz**: El contexto de seguridad de SELinux está configurado como `default_t` o `usr_t` estándar, lo que provoca que el subsistema SELinux del kernel bloquee los daemons `smbd` o `nfsd` para lectura/escritura.

#### Protocolo Paso a Paso de Diagnóstico y Resolución:

1. **Revisar los registros de auditoría (Audit Logs) en busca de denegaciones AVC de SELinux**:
   ```bash
   $ sudo ausearch -m avc -ts recent | grep -E "smbd|nfsd"
   ```
   *Salida*:
   ```text
   type=AVC msg=audit(1786018900.120:801): avc:  denied  { write } for  pid=45102 comm="smbd" name="finance" dev="sdb1" ino=2048 scontext=system_u:system_r:smbd_t:s0 tcontext=unconfined_u:object_r:default_t:s0 tclass=dir permissive=0
   ```

2. **Inspeccionar las etiquetas de contexto actuales del directorio**:
   ```bash
   $ ls -Zd /srv/samba/finance /exports/app-data
   ```
   *Salida*:
   ```text
   drwxrwxrwx. 2 root root unconfined_u:object_r:default_t:s0 /srv/samba/finance
   drwxrwxrwx. 2 root root unconfined_u:object_r:default_t:s0 /exports/app-data
   ```

3. **Remediación**: Aplicar los contextos persistentes correctos de SELinux:
   * **Para Recursos Compartidos Samba**:
     ```bash
     $ sudo semanage fcontext -a -t samba_share_t "/srv/samba/finance(/.*)?"
     $ sudo restorecon -Rv /srv/samba/finance
     ```
   * **Para Exportaciones NFS**:
     ```bash
     $ sudo semanage fcontext -a -t nfs_export_t "/exports/app-data(/.*)?"
     $ sudo restorecon -Rv /exports/app-data
     ```
   * **Verificar Booleanos de SELinux**:
     ```bash
     $ sudo setsebool -P samba_enable_home_dirs on
     $ sudo setsebool -P nfs_export_all_rw on
     ```

---

## 6. Referencias

* **Objetivos Oficiales de los Exámenes del Linux Professional Institute (LPI)**:
  * [LPIC-2 Overview & Detailed Objectives](https://www.lpi.org/our-certifications/lpic-2-overview/)
  * [LPIC-2 Exam 202-450 Objective 208.1: Samba Configuration](https://wiki.lpi.org/wiki/LPIC-2_Objectives_V4.5#208.1_Samba_Configuration_.28weight:_4.29)
  * [LPIC-2 Exam 202-450 Objective 208.2: NFS Configuration](https://wiki.lpi.org/wiki/LPIC-2_Objectives_V4.5#208.2_NFS_Configuration_.28weight:_4.29)

* **Documentación Oficial de Samba y Manuales de Integración con AD**:
  * [Samba Official Documentation & smb.conf Architecture](https://www.samba.org/samba/docs/man/manpages/smb.conf.5.html)
  * [Setting up Samba as a Domain Member](https://wiki.samba.org/index.php/Setting_up_Samba_as_a_Domain_Member)
  * [Samba VFS Modules and POSIX ACL Mapping](https://www.samba.org/samba/docs/current/man-html/vfs_acl_xattr.8.html)

* **Documentación del Kernel para NFS en Linux y Especificaciones IETF**:
  * [Linux Kernel NFS Server Guide & exports(5)](https://man7.org/linux/man-pages/man5/exports.5.html)
  * [IETF RFC 7530: Network File System (NFS) version 4 Protocol](https://datatracker.ietf.org/doc/html/rfc7530)
  * [IETF RFC 5661: Network File System (NFS) Version 4 Minor Version 1 Protocol (pNFS)](https://datatracker.ietf.org/doc/html/rfc5661)
  * [Linux nfs.conf Architecture Guide](https://man7.org/linux/man-pages/man5/nfs.conf.5.html)