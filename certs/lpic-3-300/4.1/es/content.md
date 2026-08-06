# LPIC-3 300: Arquitecturas de Almacenamiento Heterogéneo y Samba Empresarial
## Tema 4.1: Configuración Avanzada de Clientes Samba (Peso: 20)

---

## 1. Motivación Arquitectónica y Planteamiento del Problema en Producción

En la infraestructura heterogénea empresarial, contar con almacenamiento de archivos multiplataforma que se mantenga de alto rendimiento, altamente disponible y en estricto cumplimiento con los identificadores de seguridad (SIDs) de Active Directory y POSIX es un requisito fundamental. Los clientes Linux que interactúan con Windows Server Failover Clusters (WSFC), nodos de clúster Samba (CTDB) o arreglos NAS empresariales (NetApp/Isilon) deben montar sistemas de archivos remotos a través del protocolo SMB/CIFS mientras satisfacen el aislamiento multinquilino (multi-tenant), los cambios dinámicos de contexto de sesión y la confidencialidad de la capa de transporte.

```
+-----------------------------------------------------------------------------------+
|                                 LINUX CLIENT NODE                                 |
|                                                                                   |
|  +---------------------+   +---------------------+   +--------------------------+ |
|  | User Process A      |   | User Process B      |   | Systemd / Autofs Daemon  | |
|  | (UID 10001 / Alice) |   | (UID 10002 / Bob)   |   | (UID 0 / Root)           | |
|  +----------+----------+   +----------+----------+   +------------+-------------+ |
|             |                         |                           |               |
|             v                         v                           v               |
|    [ VFS Interface ]         [ VFS Interface ]          [ Static/Auto Mount ]     |
|             |                         |                           |               |
|             +--------------------+----+---------------------------+               |
|                                  |                                                |
|                                  v                                                |
|                   [ Linux Kernel cifs.ko VFS Module ]                             |
|                                  |                                                |
|       +--------------------------+--------------------------+                     |
|       | Kerberos Upcall          | SMB Session Management   |                     |
|       v                          v                          v                     |
|   /usr/sbin/cifs.upcall    SPNEGO / NTLMv2           SMB3 Engine                  |
|   (Keys in Kernel Keyring) (AES-128-GCM / CCM)       (vers=3.1.1, MultiChannel)   |
+-------+--------------------------+--------------------------+---------------------+
        |                          |                          |
        | KDC Ticket (Port 88)     | SMB3 Transport (Port 445)|
        v                          v                          v
+-------+--------------------------+--------------------------+---------------------+
| ACTIVE DIRECTORY / KDC           | ENTERPRISE SMB FILE CLUSTER / SAMBA NAS        |
| (Domain Controller)              | (Win2022 / Samba 4 CTDB / NetApp ONTAP)        |
+----------------------------------+------------------------------------------------+
```

### Desafíos Arquitectónicos Clave en Producción:

1. **Mapeo de Identidades y Contextos Multiusuario**: Los montajes UNIX tradicionales mapean todas las acciones de archivos a un `uid`/`gid` local estático pasado en el momento del montaje. En entornos multinquilino (nodos de cómputo HPC, contenedores VDI, hosts bastión), distintos usuarios del SO que acceden al mismo punto de montaje CIFS deben autenticarse contra Microsoft Active Directory de forma independiente utilizando sus propias credenciales GSSAPI de Kerberos sin contaminar de forma cruzada los descriptores de archivos (file handles) o los privilegios.
2. **Cifrado y Conmutación de Protocolo**: Los protocolos heredados SMB1/SMB2 exponen credenciales en texto plano o hashes NTLMv1 débiles, careciendo de cifrado de transporte y comprobaciones de integridad de extremo a extremo. Los patrones SRE modernos exigen una negociación estricta del protocolo SMB 3.1.1, cifrado obligatorio AES-128-GCM/AES-256-GCM (`seal`) y firma de carga útil (payload) AES-CMAC.
3. **Ciclo de Vida Automatizado y Resiliencia de Reconexión**: Los montajes estáticos en `/etc/fstab` pueden bloquear las secuencias de inicio del sistema cuando las interfaces de red no están inicializadas (falta de `_netdev`) o causar bloqueos de hilos del kernel (deadlocks) cuando el almacenamiento del backend conmuta por error (failover). Las arquitecturas SRE requieren automontaje bajo demanda y transitorio (`autofs`, `systemd.automount`), reconexiones transparentes de sesión y protección efímera de credenciales.

---

## 2. Comparaciones Técnicas y Análisis de Componendas (Trade-offs)

La evaluación de las modalidades de acceso del cliente requiere equilibrar el rendimiento en espacio de kernel, la flexibilidad en espacio de usuario, la preservación del contexto de identidad y las posturas de seguridad.

### Matriz de Modalidades de Acceso del Cliente

| Característica / Métrica | Kernel CIFS VFS (`mount.cifs`) | Automontaje Dinámico (`autofs` / `systemd`) | CLI en Espacio de Usuario (`smbclient`) | Montaje Automatizado PAM (`pam_mount`) |
| :--- | :--- | :--- | :--- | :--- |
| **Dominio de Ejecución** | Espacio de Kernel (`cifs.ko`) | Kernel + Demonio de Usuario (`autofs`) | Espacio de Usuario (Librerías Userland) | Espacio de Usuario (Hook de Sesión) |
| **Integración VFS POSIX** | Nativa (`/mnt/...`) | Nativa Bajo Demanda | Ninguna (Interactivo/Script) | Directorio Personal de Usuario Nativo |
| **Delegación de Identidad** | UID Único o `multiuser` | UID Único o `multiuser` | Credenciales de Usuario por Comando | Credenciales de Usuario por Sesión |
| **Integración con Kernel Keyring**| Completa (`cifs.spnego` / Kerberos)| Completa | GSSAPI Directo / Ticket | Indirecta vía Sesión PAM |
| **Riesgo de Dependencia en el Inicio** | Alto (Se cuelga si la red está offline)| Bajo (Monta al ejecutar `cd`/acceder) | Cero | Bajo (Monta al Iniciar Sesión) |
| **Rendimiento / IOPS** | Máximo (Zero-copy en Kernel) | Máximo | Moderado (Sobrecarga de Copia de Búfer)| Máximo |
| **Caso de Uso** | Almacenamiento Persistente de Aplicaciones | Recursos Compartidos Empresariales Efímeros | Automatización, Respaldos y Auditoría | Directorios Personales para Escritorios VDI |

### Componendas en los Modos de Autenticación de Seguridad (Opciones `sec=`)

```
       Security Level & Cryptographic Overhead
Higher  ▲  [ sec=krb5p ] -> Kerberos + AES-128/256 Encryption (Payload Sealed)
        │  [ sec=krb5i ] -> Kerberos + AES-CMAC Signing (Integrity Protected)
        │  [ sec=krb5  ] -> Kerberos Authentication Only (No Integrity/Privacy)
        │  [ sec=ntlmssp ] -> NTLMv2 via Extended Security (No Kerberos Dependency)
Lower   │  [ sec=ntlm   ] -> Deprecated / Insecure (Vulnerable to Relay/MitM)
```

| Modo de Seguridad (`sec=`) | Cifrado (`seal`) | Integridad (`signing`) | Proveedor de Identidad | Impacto en el Rendimiento | Protección contra MitM |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `krb5p` | Obligatorio (AES-GCM/CCM)| Obligatorio | Active Directory / MIT KDC | Alto (Sobrecarga de Criptografía) | Máxima |
| `krb5i` | Ninguno | Obligatorio (AES-CMAC) | Active Directory / MIT KDC | Moderado | Alta |
| `krb5` | Ninguno | Opcional | Active Directory / MIT KDC | Bajo | Baja |
| `ntlmssp` | Opcional | Opcional | SAM Local / Dominio NTLM | Bajo | Moderada |
| `ntlmsv2` (Heredado) | Ninguno | Obsoleto | SAM Local | Bajo | Baja |

---

## 3. Archivos de Configuración Completos y Manifiestos de Infraestructura

### 3.1 Configuración de Kerberos Upcall en el Kernel: `/etc/request-key.d/cifs.spnego.conf`

El kernel depende de la utilidad auxiliar en espacio de usuario `cifs.upcall` para resolver nombres de servicio principal (SPNs) y obtener credenciales de Kerberos desde el keyring de la sesión.

```ini
# /etc/request-key.d/cifs.spnego.conf
# Syntax: create <type> <reason> <class> <argument> <program> [args...]
# Used by cifs.ko to resolve Kerberos tickets dynamically
create cifs.spnego * * /usr/sbin/cifs.upcall -c %k
create dns_resolver * * /usr/sbin/key.dns_resolver %k
```

### 3.2 Configuración Base Segura para la Empresa: `/etc/samba/smb.conf`

Las herramientas de cliente (`smbclient`, `rpcclient`, `net`, `cifs.upcall`) leen los valores predeterminados de configuración local desde `/etc/samba/smb.conf`.

```ini
[global]
   workgroup = CORP
   realm = CORP.ENTERPRISE.INTERNAL
   security = ads
   kerberos method = secrets and keytab
   
   # Protocol Constraints for Hardened Environments
   client max protocol = SMB3_11
   client min protocol = SMB2_10
   
   # Transport Layer Security Requirements
   client ipc signing = mandatory
   client signing = mandatory
   client smb encrypt = required
   
   # Identity & Name Resolution
   name resolve order = host bcast lmhosts
   idmap config * : backend = tdb
   idmap config * : range = 30000-39999
   idmap config CORP : backend = rid
   idmap config CORP : range = 10000-29999
   
   # Client Performance Tuning
   client sockets options = TCP_NODELAY SO_RCVBUF=131072 SO_SNDBUF=131072
```

### 3.3 Archivo de Credenciales Protegido: `/etc/samba/credentials/finance.cred`

```ini
username=svc_smb_finance
password=K9#mP!vL9$xQ2zR8
domain=CORP
```

*La aplicación de permisos debe ser strictly `0600`, siendo propietario `root:root`.*

### 3.4 Tabla de Montaje del Sistema para Producción: `/etc/fstab`

Esta configuración de `/etc/fstab` destaca los montajes de almacenamiento estándar junto con los montajes de Kerberos avanzados `multiuser`.

```ini
# /etc/fstab
# Device / Remote Path                       Mount Point            FSType  Options                                                                                                                   Dump Pass
# ------------------------------------------ ---------------------- ------- ------------------------------------------------------------------------------------------------------------------------- ---- ----

# 1. Standard Static Service Access Mount (Explicit Protocol 3.1.1, Encrypted, Secured Credentials File)
//fs.corp.enterprise.internal/shares/finance /mnt/smb/finance       cifs    credentials=/etc/samba/credentials/finance.cred,uid=10001,gid=10001,file_mode=0660,dir_mode=0770,vers=3.1.1,sec=krb5p,seal,_netdev,nofail 0 0

# 2. Multi-User Enterprise Kerberos Mount (Dynamic Kerberos Ticket Delegation per User Process)
//fs.corp.enterprise.internal/shares/engineering /mnt/smb/engineering   cifs    sec=krb5p,multiuser,cruid=0,vers=3.1.1,seal,_netdev,nofail,file_mode=0777,dir_mode=0777                                   0 0
```

### 3.5 Unidades de Automontaje Nativas de Systemd

#### `/etc/systemd/system/mnt-smb-reports.mount`
```ini
[Unit]
Description=Production Enterprise SMB Share - Reports
Documentation=https://docs.enterprise.internal/storage/smb
After=network-online.target remote-fs-pre.target
Wants=network-online.target

[Mount]
What=//fs.corp.enterprise.internal/shares/reports
Where=/mnt/smb/reports
Type=cifs
Options=credentials=/etc/samba/credentials/finance.cred,vers=3.1.1,sec=krb5p,seal,uid=10001,gid=10001,file_mode=0640,dir_mode=0750,_netdev
TimeoutSec=30

[Install]
WantedBy=multi-user.target
```

#### `/etc/systemd/system/mnt-smb-reports.automount`
```ini
[Unit]
Description=Automount Infrastructure for SMB Reports Share
Documentation=https://docs.enterprise.internal/storage/smb

[Automount]
Where=/mnt/smb/reports
DirectoryMode=0755
TimeoutIdleSec=300

[Install]
WantedBy=multi-user.target
```

### 3.6 Infraestructura Autofs con Mapeo Directo (Direct Map)

#### `/etc/auto.master.d/cifs.autofs`
```ini
/- /etc/auto.cifs --timeout=600 --ghost
```

#### `/etc/auto.cifs`
```ini
/mnt/smb/analytics -fstype=cifs,vers=3.1.1,sec=krb5p,seal,credentials=/etc/samba/credentials/finance.cred,uid=10001,gid=10001 ://fs.corp.enterprise.internal/shares/analytics
```

### 3.7 Montaje Automático de Directorio Personal con Módulo de Autenticación Enchufable (PAM): `/etc/security/pam_mount.conf.xml`

```xml
<?xml version="1.0" encoding="utf-8" ?>
<!DOCTYPE pam_mount SYSTEM "pam_mount.conf.xml.dtd">
<pam_mount>
    <!-- Debug level: 0=silent, 1=verbose -->
    <debug enable="0" />

    <!-- Volume definition for AD User Home Directories mounted seamlessly on SSH/Console login -->
    <volume 
        user="*" 
        fstype="cifs" 
        server="fs.corp.enterprise.internal" 
        path="homes/%(USER)" 
        mountpoint="~/SMB_Home" 
        options="vers=3.1.1,sec=krb5i,seal,cruid=%(USERUID),uid=%(USERUID),gid=%(USERGID),dir_mode=0700,file_mode=0600" 
    />

    <!-- Global mount command formatting -->
    <cifsmount>/sbin/mount.cifs %(SERVER)/%(VOLUME) %(MNTPT) -o %(OPTIONS)</cifsmount>
    <cifsumount>/sbin/umount.cifs %(MNTPT)</cifsumount>
</pam_mount>
```

---

## 4. Trazas de Ejecución Reales en CLI y Salidas de Terminal

### 4.1 Autenticación Kerberos e Inicialización de Keyring de Usuario

```bash
$ kinit smb_user@CORP.ENTERPRISE.INTERNAL
Password for smb_user@CORP.ENTERPRISE.INTERNAL: 

$ klist -A
Credentials cache: KCC:FILE:/tmp/krb5cc_10001
Principal: smb_user@CORP.ENTERPRISE.INTERNAL

Number of credentials: 2

Ref # Target Principal
  1   krbtgt/CORP.ENTERPRISE.INTERNAL@CORP.ENTERPRISE.INTERNAL
	Valid starting       Expires              Service Principal
	08/06/26 10:00:00  08/06/26 20:00:00  krbtgt/CORP.ENTERPRISE.INTERNAL@CORP.ENTERPRISE.INTERNAL
	renew until 08/07/26 10:00:00
  2   cifs/fs.corp.enterprise.internal@CORP.ENTERPRISE.INTERNAL
	Valid starting       Expires              Service Principal
	08/06/26 10:05:12  08/06/26 20:00:00  cifs/fs.corp.enterprise.internal@CORP.ENTERPRISE.INTERNAL
```

### 4.2 Diagnóstico y Descubrimiento de Recursos Compartidos a través de `smbclient`

```bash
$ smbclient -L //fs.corp.enterprise.internal -k -m SMB3_11
lp_load_ex: reviewing free resources
smbXcli_negprot_send: negotiation complete with SMB3_11 dialect

	Sharename       Type      Comment
	---------       ----      -------
	NETLOGON        Disk      Logon server share 
	SYSVOL          Disk      Logon server share 
	finance         Disk      Financial Records Root
	engineering     Disk      R&D Build Cache
	analytics       Disk      Data Science Datasets
	IPC$            IPC       IPC Service (Samba 4.19.4-Debian)

SMB1 calls are disabled by protocol range
Reconnecting with SMB3_11...
Domain=[CORP] OS=[Windows 10 Build 19041] Server=[Samba 4.19.4-Debian]
```

### 4.3 Operaciones Interactivas de Archivos a través de `smbclient`

```bash
$ smbclient //fs.corp.enterprise.internal/finance -k -c "cd Q3_Reports; dir; get quarter_final.xlsx /tmp/quarter_final.xlsx"
smb: \Q3_Reports\> dir
  .                                   D        0  Thu Aug  6 09:12:44 2026
  ..                                  D        0  Thu Aug  6 09:12:44 2026
  quarter_final.xlsx                  A  4194304  Thu Aug  6 09:15:20 2026
  audit_manifest.csv                  A    12480  Wed Aug  5 14:02:11 2026

		104857600 blocks of size 1024. 64210940 blocks available
getting file \Q3_Reports\quarter_final.xlsx of size 4194304 as /tmp/quarter_final.xlsx (148210.4 kb/s) (average 148210.4 kb/s)
```

### 4.4 Administración RPC Empresarial a través de `rpcclient`

```bash
$ rpcclient -k fs.corp.enterprise.internal -c "enumdomgroups; queryuser 10001"
group:[Domain Admins] rid:[0x200]
group:[Domain Users] rid:[0x201]
group:[Finance_Operators] rid:[0x452]

User Name   :   smb_user
Full Name   :   Financial Automation Service Account
Home Drive  :   \\fs.corp.enterprise.internal\homes\smb_user
Dir Drive   :   Z:
Profile Path:   
Logon Script:   logon.bat
User Id     :   0x0
Group Id    :   0x0
Primary Group RID : 0x201 (Domain Users)
Account Flags     : 0x210
```

### 4.5 Automatización de Descarga Recursiva a través de `smbget`

```bash
$ smbget -k -R smb://fs.corp.enterprise.internal/finance/Q3_Reports/ -o /var/backups/finance_q3/
Downloading smb://fs.corp.enterprise.internal/finance/Q3_Reports/quarter_final.xlsx
100% [================================================>] 4.19M/4.19M  Speed: 180MB/s
Downloading smb://fs.corp.enterprise.internal/finance/Q3_Reports/audit_manifest.csv
100% [================================================>] 12.48K/12.48K Speed: 12MB/s
Transferred 4.20MB in 2 files at 165MB/s
```

---

## 5. Guía de Verificación y Diagnóstico de Fallas (Runbook)

### 5.1 Verificación del Sistema e Inspección de Sesiones Activas

```bash
# 1. Verify Active System Kernel CIFS Mounts
$ mount -t cifs
//fs.corp.enterprise.internal/shares/engineering on /mnt/smb/engineering type cifs (rw,relatime,vers=3.1.1,sec=krb5p,cache=strict,multiuser,max_credits=128,uid=0,noforceuid,gid=0,noforcegid,addr=192.168.10.50,file_mode=0777,dir_mode=0777,soft,nounix,serverino,mapposix,echo_interval=60,actimeo=1)

# 2. Inspect Active SMB Kernel Interfaces and Socket Connections
$ cat /proc/fs/cifs/DebugData
Display Internal CIFS Data Structures for Debugging
---------------------------------------------------
CIFS Version 2.42
Active Server Connections:
1) Connection Id: 0x1 Hostname: fs.corp.enterprise.internal
	TCP status: 1 Dynamic power state: 0
	Local side addr: 192.168.10.105 Port: 42180
	Remote side addr: 192.168.10.50 Port: 445
	Dialect: 0x311 (SMB3.1.1)
	Capabilities: 0x300001 Encryption: AES-128-GCM Bytes: 489210
	
	Sessions:
	1) SecMode: 0x1 Login Name: smb_user Domain: CORP
	   State: 1 User UID: 10001
	   Shares:
	   1) Path: \\fs.corp.enterprise.internal\engineering Mounts: 1 Type: VFS
```

### 5.2 Diagrama de Flujo de Diagnóstico Profundo

```
                 CIFS Mount Failure Triggered
                              │
                              ▼
               Check Network Connectivity & Port 445
             ┌────────────────┘───────────────┐
      [Port Closed]                    [Port Open]
            │                                │
            ▼                                ▼
Check Firewalls/Security Groups   Check Kernel Diagnostics
                                  echo 7 > /proc/fs/cifs/cifsFYI
                                            │
                                            ▼
                                   Attempt Mount Command
                                            │
                                            ▼
                                    Read dmesg Logs
             ┌──────────────────────────────┼──────────────────────────────┐
  [Status: STATUS_ACCESS_DENIED] [Status: STATUS_LOGON_FAILURE] [Status: ENOKEY / GSSAPI]
             │                              │                              │
             ▼                              ▼                              ▼
Verify POSIX Share ACLs          Verify Credential File/Secret  Verify Kerberos Ticket (klist)
& Active Directory SIDs          & NTLMv2 Dialect Compatibility  & Check cifs.spnego Service
```

### 5.3 Procedimientos de Diagnóstico Paso a Paso

#### Paso 1: Habilitar el Rastro de Depuración Dinámica a Nivel de Kernel

```bash
# Enable verbose debugging in kernel CIFS subsystem (Mask 0x7 enables info, error, and socket debugging)
$ sudo bash -c 'echo 7 > /proc/fs/cifs/cifsFYI'

# Monitor kernel ring buffer in real time filtered for CIFS events
$ dmesg -wH | grep -i cifs
```

*Salida de diagnóstico esperada para un fallo de ticket de Kerberos:*
```
[Aug6 11:20:04] fs/smb/client/cifsfs.c: Devname: //fs.corp.enterprise.internal/shares/engineering flags: 0
[Aug6 11:20:04] fs/smb/client/connect.c: Username: NULL
[Aug6 11:20:04] fs/smb/client/connect.c: secMode 0x1
[Aug6 11:20:04] fs/smb/client/cifs_spnego.c: key description: cifs/fs.corp.enterprise.internal
[Aug6 11:20:04] fs/smb/client/cifs_spnego.c: gss_init_sec_context status: 0xd0000 (Major), 0x24 (Minor)
[Aug6 11:20:04] CIFS: VFS: Send error in Required SPN Negotiate Stage = -126 [ENOKEY]
[Aug6 11:20:04] CIFS: VFS: cifs_mount failed w/return code = -126
```

#### Paso 2: Validar la Infraestructura de Keyring de Usuario y el Resolvedor

```bash
# Verify the key resolution helper registered in request-key.d responds to the active user keyring
$ keyctl show
Session Keyring
 94820194 --alswrv  10001 10001  keyring: _ses
 51920412 --alswrv  10001 10001   \_ logon: cifs:a:192.168.10.50

# Force cifs.upcall execution manually in dry-run mode to verify SPN mapping
$ /usr/sbin/cifs.upcall -d -c 51920412
cifs.upcall: key description: cifs/fs.corp.enterprise.internal
cifs.upcall: handling retrieve key request for process
cifs.upcall: using principal smb_user@CORP.ENTERPRISE.INTERNAL
cifs.upcall: successfully obtained GSSAPI credential for service cifs/fs.corp.enterprise.internal
```

#### Paso 3: Captura de Paquetes de Red y Disección de Protocolo SMB

Cuando la negociación del protocolo se cuelga o falla silenciosamente, capture los estrechamientos de mano (handshakes) de tramas SMB en la red:

```bash
# Capture raw SMB2/SMB3 traffic over port 445
$ tcpdump -i eth0 -nn -s 0 -w /tmp/smb_debug.pcap port 445

# Analyze negotiation dialects and response status codes using tshark
$ tshark -r /tmp/smb_debug.pcap -Y "smb2" -T fields -e frame.number -e smb2.cmd -e smb2.nt_status
1    0   0x00000000 (STATUS_SUCCESS)       # Negotiate Protocol Request/Response
3    1   0x00000000 (STATUS_SUCCESS)       # Session Setup Request (SPNEGO)
5    3   0xc0000022 (STATUS_ACCESS_DENIED) # Tree Connect Failure
```

#### Paso 4: Limpieza y Restablecimiento del Estado de Depuración

```bash
# Re-enable production quiet mode for kernel CIFS module
$ sudo bash -c 'echo 0 > /proc/fs/cifs/cifsFYI'
```

---

## 6. Referencias

- [Objetivos Oficiales de la Certificación LPIC-3 300](https://www.lpi.org/our-certifications/lpic-3-300-overview/)
- [Documentación Oficial de Samba - Manual de smb.conf](https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html)
- [Documentación del Kernel de Linux - Cliente CIFS VFS](https://www.kernel.org/doc/html/latest/filesystems/cifs/cifs.html)
- [Página Man de mount.cifs - Utilidades CIFS de Linux](https://www.samba.org/samba/docs/current/man-html/mount.cifs.8.html)
- [Especificaciones Abiertas de Microsoft - MS-SMB2: Protocolo Server Message Block Versiones 2 y 3](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-smb2/)
- [Página Man de cifs.upcall - Auxiliar en Espacio de Usuario para Montajes Kerberos](https://www.samba.org/samba/docs/current/man-html/cifs.upcall.8.html)