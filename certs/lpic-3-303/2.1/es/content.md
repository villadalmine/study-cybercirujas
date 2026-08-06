# LPIC-3 Security (Exam 303-300, v3.0) — Topic 333: Access Control
**Peso del examen:** 10 de 60 (16.67% de cobertura total del examen)  
**Audiencia objetivo:** Senior SREs, Platform Architects, Security Engineers

---

## 1. Motivación Arquitectónica de Producción y Planteamiento del Problema

En plataformas Linux empresariales, las cargas de trabajo rara vez se ejecutan de forma aislada. Las infraestructuras modernas albergan microservicios multi-tenant, runtimes de contenedores (`containerd`, `CRI-O`, `Podman`), bases de datos con estado (stateful databases) y agentes de automatización en kernels de Linux compartidos. 

### La Falla Fundamental del UNIX DAC Estándar
El **Discretionary Access Control (DAC)** tradicional de Linux se basa en un modelo de permisos de tres partes (Owner, Group, Other) adjunto directamente al inodo del archivo (`rwxrwxrwx`). Este modelo sufre de severas limitaciones arquitectónicas en producción:

1. **Autorización de Grano Grueso (Coarse-Grained Authorization):** Un proceso que se ejecuta como usuario `www-data` necesita acceso de lectura a `/var/www/html` y acceso de escritura a `/var/log/nginx/`. Si otro daemon (por ejemplo, un exportador de métricas) requiere acceso de lectura a `/var/log/nginx/`, debe agregarse al grupo `www-data` (otorgándole acceso también a los archivos de la raíz web) o los logs deben hacerse legibles para todo el mundo (`o+r`), violando el Principio de Menor Privilegio (Principle of Least Privilege - PoLP).
2. **Autoridad Ambiental y Escalada de Privilegios (Ambient Authority & Privilege Escalation):** Bajo DAC, un proceso hereda **todos** los privilegios del usuario que lo ejecuta. Si `nginx` se ejecuta como `root` (para vincularse al puerto 80) y sufre una Ejecución Remota de Código (Remote Code Execution - RCE) a través de un desbordamiento de búfer (buffer overflow), el atacante obtiene acceso root sin restricciones a todo el sistema operativo, elude DAC por completo y puede acceder a `/etc/shadow`, insertar módulos del kernel o limpiar dispositivos de bloque (block devices).
3. **Sin Protección contra Propietarios Maliciosos o Comprometidos:** El propietario del archivo puede modificar los permisos del archivo a voluntad (`chmod 777`). DAC no puede restringir que un usuario o proceso de aplicación exponga sus propios datos a usuarios no confiables.

```
                   +------------------------------------------+
                   |           User Space Process             |
                   |      (e.g., compromised web app)         |
                   +------------------------------------------+
                                        |
                                        v
                   +------------------------------------------+
                   |    Virtual File System (VFS) Layer       |
                   +------------------------------------------+
                                        |
                  +---------------------+---------------------+
                  |                                           |
                  v                                           v
       +--------------------+                      +--------------------+
       |  DAC Check (VFS)   |                      |  LSM Framework     |
       | Inode Mode Bits /  |                      | Hook:              |
       | POSIX Extended ACL |                      | security_file_open |
       +--------------------+                      +--------------------+
                  |                                           |
           (Pass: User/Group)                          (Pass: Policy)
                  |                                           |
                  +---------------------+---------------------+
                                        |
                                        v
                   +------------------------------------------+
                   |       Underlying Filesystem (ext4/xfs)   |
                   +------------------------------------------+
```

### La Solución del Kernel: LSM Hooks y Mandatory Access Control
Para mitigar las deficiencias de DAC, el kernel de Linux proporciona el framework **Linux Security Modules (LSM)**. LSM ubica hooks de mediación en puntos clave y críticos para la seguridad dentro de las estructuras de datos del kernel (tales como búsqueda de inodos, apertura de archivos, creación de sockets, transiciones de tareas e IPC).

* **POSIX ACLs (Extended DAC):** Extiende los bits de archivo estándar para otorgar permisos granulares por usuario (`u:alice:r--`) y por grupo (`g:devs:rw-`) utilizando atributos extendidos del kernel (`xattr`).
* **Extended Attributes (`xattr`):** Permite el etiquetado de metadatos directamente en los inodos del sistema de archivos a través de cuatro namespaces distintos (`user`, `trusted`, `security`, `system`).
* **Mandatory Access Control (MAC):** Anula las decisiones de DAC al aplicar políticas de seguridad a nivel de todo el sistema definidas por un administrador central. Incluso si un proceso se ejecuta como `root` (`uid=0`), el LSM del kernel aplica restricciones:
  * **SELinux (Type Enforcement & MCS/MLS):** Sistema MAC basado en etiquetas (labels). Verifica las etiquetas adjuntas a los procesos (sujetos) u objetos (archivos, sockets, puertos, IPC) contra una política binaria compilada.
  * **AppArmor (Path-Based Enforcement):** Sistema MAC basado en rutas (path-names). Restringe programas individuales utilizando perfiles legibles por humanos vinculados a rutas de ejecución binarias.

---

## 2. Comparativa Técnica y Matrices de Compromisos Arquitectónicos

### 2.1 Matriz de Paradigmas de Control de Acceso

| Característica / Dimensión | Standard UNIX DAC | POSIX Extended ACLs | File Extended Attributes (`xattr`) | SELinux (MAC) | AppArmor (MAC) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Mecanismo de Aplicación (Enforcement Mechanism)** | VFS Kernel Inode Mode Bits | Evaluación extendida de inodos VFS | Almacenamiento clave-valor de metadatos de inodo | LSM Hooks mediante Type Enforcement / Etiquetas | LSM Hooks mediante coincidencia de ruta canónica (Canonical Path Matching) |
| **Granularidad** | Usuario, Grupo, World (3 buckets) | Múltiples usuarios y grupos explícitos por archivo | Almacenamiento de metadatos (hasta 64KB por inodo) | Basado en contexto de Objeto/Sujeto (`u:r:t:s0`) | Basado en ruta binaria (`/usr/bin/nginx`) |
| **¿Omisión de Root (Root Bypassing)?** | No (Root omite todo DAC) | No (Root omite todo DAC) | Parcial (Solo `CAP_SYS_ADMIN` modifica `security`/`trusted`) | **Sí** (Root confinado por reglas de política) | **Sí** (Root confinado por reglas de perfil) |
| **Ubicación de Almacenamiento** | Campos estándar del inodo | Atributo extendido `system.posix_acl_access` | Bloques de atributos extendidos en disco | Atributo extendido `security.selinux` | Cargado en Kernel RAM (Tabla de perfiles) |
| **Postura por Defecto (Default Stance)** | Abierto / Discrecional | Abierto / Discrecional | Solo almacenamiento de metadatos | Default Deny (Denegación implícita de todo a menos que esté permitido) | Default Deny (para binarios perfilados) |
| **Impacto en el Rendimiento** | Mínimo (Operaciones bit a bit directas) | Bajo (Búsqueda extra de xattr en inodo) | Bajo (Búsqueda de xattr según la alineación de bloques) | Bajo-Medio (Aciertos en caché AVC ~1-2%, búsqueda en fallos de caché) | Bajo-Medio (Resolución de rutas y evaluación de regex de cadenas) |
| **Herramientas de Gestión** | `chmod`, `chown`, `umask` | `getfacl`, `setfacl` | `getfattr`, `setfattr`, `lsattr`, `chattr` | `semanage`, `restorecon`, `audit2allow`, `setsebool` | `aa-status`, `apparmor_parser`, `aa-complain`, `aa-enforce` |

### 2.2 Comparativa Arquitectónica de SELinux vs. AppArmor

```
+---------------------------------------------------------------------------------------------------+
| Feature               | SELinux                                 | AppArmor                        |
+-----------------------+-----------------------------------------+---------------------------------+
| Binding Mechanism     | Security Labels (Stored in xattr)       | Absolute Path Names             |
| File Rename Traversal | Immune (Label tied to Inode)            | Sensitive (New path needs rule) |
| Policy Complexity     | High (Requires TE, Rules, Interfaces)   | Low (Human readable profiles)   |
| Multi-Category (MCS)  | Supported (Container isolation: `s0:c1`)| Limited / Not natively label-based |
| Default Distribution  | RHEL, Fedora, Rocky Linux, AlmaLinux    | Ubuntu, Debian, SUSE Linux      |
+---------------------------------------------------------------------------------------------------+
```

---

## 3. Manifiestos de Producción y Configuraciones Completas de Infraestructura

### 3.1 Módulo de Política Personalizado de Type Enforcement de SELinux
El siguiente módulo de política define un contexto de seguridad específico para un microservicio de API empresarial que se ejecuta en un puerto no estándar (`8443`) y accede a un almacenamiento persistente dedicado (`/var/data/api`).

#### Archivo: `custom_microservice.te` (Archivo Fuente de Type Enforcement)
```te
policy_module(custom_microservice, 1.0.0)

gen_require(`
    type unconfined_t;
    type httpd_config_t;
    type node_t;
    type cert_t;
    class file { read getattr open map write create unlink rename };
    class dir { read search getattr open write add_name remove_name };
    class tcp_socket { name_bind name_connect node_bind };
')

# Declarations of custom security types
type custom_api_t;
type custom_api_exec_t;
type custom_api_data_t;
type custom_api_log_t;
type custom_api_port_t;

# Define target process as a domain transition destination
init_daemon_domain(custom_api_t, custom_api_exec_t)

# Define port and object types
files_type(custom_api_data_t)
logging_log_file(custom_api_log_t)
corenetwork_port(custom_api_port_t)

# Allow domain transition when unconfined_t or init script executes custom_api_exec_t
domain_auto_trans(unconfined_t, custom_api_exec_t, custom_api_t)

# File and Directory Rules for Process Domain (custom_api_t)
allow custom_api_t custom_api_data_t:dir { read search getattr open write add_name remove_name };
allow custom_api_t custom_api_data_t:file { read getattr open map write create unlink rename };

allow custom_api_t custom_api_log_t:dir { read search getattr open write add_name };
allow custom_api_t custom_api_log_t:file { create open append getattr setattr write };

# Allow reading SSL/TLS Certificates from system store
allow custom_api_t cert_t:dir { read search getattr open };
allow custom_api_t cert_t:file { read getattr open };

# Network Access Rules
allow custom_api_t custom_api_port_t:tcp_socket { name_bind name_connect };
allow custom_api_t node_t:tcp_socket node_bind;

# System access logging interface
sysnet_dns_name_resolve(custom_api_t)
```

#### Archivo: `custom_microservice.fc` (Archivo de Definición de Contexto de Archivos)
```fc
/usr/local/bin/custom_api_server        --  gen_context(system_u:object_r:custom_api_exec_t,s0)
/var/data/api(/.*)?                         gen_context(system_u:object_r:custom_api_data_t,s0)
/var/log/custom_api(/.*)?                   gen_context(system_u:object_r:custom_api_log_t,s0)
```

---

### 3.2 Perfil de AppArmor para Entornos de Producción
Este perfil de AppArmor completo y sintácticamente válido confina una instancia de proxy inverso NGINX en producción, aplicando permisos de ruta, restricciones de capacidades de red y evitando la ejecución de binarios no aprobados.

#### Archivo: `/etc/apparmor.d/usr.sbin.nginx`
```apparmor
#include <tunables/global>

profile nginx /usr/sbin/nginx flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>
  #include <abstractions/nameservice>
  #include <abstractions/openssl>

  # Network Capabilities
  capability net_bind_service,
  capability setuid,
  capability setgid,
  capability chown,
  capability dac_override,
  capability sys_resource,

  # Deny raw sockets and dangerous capabilities explicitly
  deny capability sys_admin,
  deny capability sys_module,
  deny capability rawio,

  # Executable File Rules
  /usr/sbin/nginx mr,

  # Configuration File Access
  /etc/nginx/ r,
  /etc/nginx/** r,
  /etc/ssl/certs/ r,
  /etc/ssl/certs/** r,
  /etc/pki/tls/certs/ r,
  /etc/pki/tls/certs/** r,

  # Dynamic Libraries
  /usr/lib{,32,64}/** mr,
  /lib{,32,64}/** mr,

  # Process and System Information Files
  /proc/sys/kernel/ngroups_max r,
  /proc/cpuinfo r,
  /sys/devices/system/cpu/ r,
  /sys/devices/system/cpu/** r,

  # Logging and Pid Files
  /var/log/nginx/ r,
  /var/log/nginx/* w,
  /var/log/nginx/** rw,
  /run/nginx.pid rw,
  /run/nginx.pid.* rw,

  # Web Root Data Directories
  /usr/share/nginx/html/ r,
  /usr/share/nginx/html/** r,
  /var/www/html/ r,
  /var/www/html/** r,

  # Temporary Directories for Buffer Files
  /var/lib/nginx/ rw,
  /var/lib/nginx/** rw,
  /tmp/nginx_* rw,
  /tmp/nginx_*/** rw,

  # Explicit Deny for Executables inside Web Root
  deny /var/www/html/**/*.sh x,
  deny /var/www/html/**/*.py x,
  deny /var/www/html/**/*.php x,

  # Signal Handling
  signal (receive, send) set=(term, int, quit, hup, usr1, usr2) peer=nginx,
}
```

---

### 3.3 Diseño de Directorios POSIX Extended ACL y Automatización con Systemd
El siguiente manifiesto de servicio de Systemd configura una estructura de directorios empresarial con herencia predeterminada de ACL POSIX de grano fino para la colaboración entre múltiples departamentos (`devops` y `secops`).

#### Archivo: `/etc/systemd/system/configure-secure-acl.service`
```ini
[Unit]
Description=Configure Enterprise POSIX Extended ACLs and Filesystem Attributes
After=local-fs.target
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/setup-acls.sh

[Install]
WantedBy=multi-user.target
```

#### Archivo: `/usr/local/bin/setup-acls.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="/srv/engineering/shared"

# Create target directories
mkdir -p "${TARGET_DIR}"

# Reset existing ACLs and permissions
chmod 2770 "${TARGET_DIR}"
chown root:devops "${TARGET_DIR}"

# Clear existing ACLs
setfacl -b -R "${TARGET_DIR}"

# Apply Base ACLs
# Grant read/write/execute to devops group
setfacl -m g:devops:rwx "${TARGET_DIR}"
# Grant read-only access to secops group
setfacl -m g:secops:r-x "${TARGET_DIR}"
# Grant explicit read/write access to automated build user
setfacl -m u:ci-builder:rwx "${TARGET_DIR}"

# Set the Mask to prevent accidental permission truncation
setfacl -m m:rwx "${TARGET_DIR}"

# Apply Default ACLs for automatic inheritance on new files/subdirectories
setfacl -d -m g:devops:rwx "${TARGET_DIR}"
setfacl -d -m g:secops:r-x "${TARGET_DIR}"
setfacl -d -m u:ci-builder:rwx "${TARGET_DIR}"
setfacl -d -m m:rwx "${TARGET_DIR}"
setfacl -d -m o::--- "${TARGET_DIR}"

# Set Immutable Extended Attribute on critical policy lock file
touch "${TARGET_DIR}/POLICY.lock"
chattr +i "${TARGET_DIR}/POLICY.lock"
```

---

## 4. Comandos de Ejecución y Sesiones de Salida Real de Terminal

### 4.1 Mecánica de Evaluación de POSIX ACLs y Máscara (Mask)

```console
$ # Inspect initial directory permissions and ACLs
$ getfacl /srv/engineering/shared
# file: srv/engineering/shared
# owner: root
# group: devops
# flags: s--
user::rwx
group::rwx
group:secops:r-x
user:ci-builder:rwx
mask::rwx
other::---
default:user::rwx
default:group::rwx
default:group:secops:r-x
default:user:ci-builder:rwx
default:mask::rwx
default:other::---

$ # Modify the ACL mask to restrict all named users and groups to read-only
$ setfacl -m m:r-- /srv/engineering/shared

$ # Verify mask recalculation effect on effective permissions
$ getfacl /srv/engineering/shared
# file: srv/engineering/shared
# owner: root
# group: devops
# flags: s--
user::rwx
group::rwx			#effective:r--
group:secops:r-x		#effective:r--
user:ci-builder:rwx		#effective:r--
mask::r--
other::---

$ # Demonstrate impact of chmod on ACL mask
$ chmod g=rx /srv/engineering/shared
$ getfacl /srv/engineering/shared | grep mask
mask::r-x
```

---

### 4.2 Atributos Extendidos de Linux (`xattr`) y Atributos de Archivo

```console
$ # Setting user-defined extended attributes
$ setfattr -n user.checksum -v "e3b0c44298fc1c149afbf4c8996fb924" /srv/engineering/shared/build.tar.gz
$ getfattr -d /srv/engineering/shared/build.tar.gz
# file: srv/engineering/shared/build.tar.gz
user.checksum="e3b0c44298fc1c149afbf4c8996fb924"

$ # Display security extended attribute used by SELinux
$ getfattr -n security.selinux /srv/engineering/shared/build.tar.gz
# file: srv/engineering/shared/build.tar.gz
security.selinux="system_u:object_r:default_t:s0"

$ # Demonstrate file immutability via chattr
$ lsattr /srv/engineering/shared/POLICY.lock
----i---------e---- /srv/engineering/shared/POLICY.lock

$ rm -f /srv/engineering/shared/POLICY.lock
rm: cannot remove '/srv/engineering/shared/POLICY.lock': Operation not permitted

$ # Remove immutable attribute and delete
$ chattr -i /srv/engineering/shared/POLICY.lock
$ rm -f /srv/engineering/shared/POLICY.lock
```

---

### 4.3 Compilación de Políticas de SELinux, Mapeo de Contexto y Booleanos

```console
$ # Check current system SELinux status
$ sestatus
SELinux status:                 enabled
SELinuxfs mount:                /sys/fs/selinux
SELinux root directory:         /etc/selinux
Loaded policy name:             targeted
Current mode:                   enforcing
Mode from config file:          enforcing
Policy MLS status:              enabled
Policy deny_unknown status:     allowed
Memory protection checking:     actualized
Max kernel policy version:      33

$ # Compile and insert custom SELinux policy module
$ checkmodule -M -m -o custom_microservice.mod custom_microservice.te
checkmodule:  loading policy configuration from custom_microservice.te
checkmodule:  policy configuration loaded
checkmodule:  writing binary representation (version 19) to custom_microservice.mod

$ semodule_package -o custom_microservice.pp -m custom_microservice.mod -f custom_microservice.fc
$ semodule -i custom_microservice.pp

$ # Confirm installed module
$ semodule -l | grep custom_microservice
custom_microservice

$ # Configure persistent context mapping using semanage
$ semanage fcontext -a -t custom_api_data_t "/var/data/api(/.*)?"
$ restorecon -Rv /var/data/api
Relabeled /var/data/api from unconfined_u:object_r:var_t:s0 to system_u:object_r:custom_api_data_t:s0
Relabeled /var/data/api/config.json from unconfined_u:object_r:var_t:s0 to system_u:object_r:custom_api_data_t:s0

$ # Manage SELinux Booleans persistently
$ getsebool httpd_can_network_connect_db
httpd_can_network_connect_db --> off

$ setsebool -P httpd_can_network_connect_db on
$ getsebool httpd_can_network_connect_db
httpd_can_network_connect_db --> on
```

---

### 4.4 Administración de Perfiles de AppArmor y Gestión de Enforcement

```console
$ # Check AppArmor execution status and profile counts
$ aa-status
apparmor module is loaded.
48 profiles are loaded.
44 profiles are in enforce mode.
   /usr/bin/evince
   /usr/sbin/nginx
   ...
4 profiles are in complain mode.
   /usr/sbin/identd
0 profiles are in kill mode.
0 profiles are in unconfined mode.
3 processes have profiles defined.
3 processes are in enforce mode.
   /usr/sbin/nginx (124802) nginx
   /usr/sbin/nginx (124803) nginx
   /usr/sbin/nginx (124804) nginx

$ # Load new profile in enforce mode directly via parser
$ apparmor_parser -r -W /etc/apparmor.d/usr.sbin.nginx

$ # Transition profile into complain mode for testing
$ aa-complain /usr/sbin/nginx
Setting /usr/sbin/nginx to complain mode.

$ # Transition profile back into enforce mode for production
$ aa-enforce /usr/sbin/nginx
Setting /usr/sbin/nginx to enforce mode.
```

---

## 5. Verificación, Diagnóstico de Fallas y Guía de Resolución de Problemas (Troubleshooting)

### 5.1 Protocolo de Triaje Sistémico por Capas de Seguridad

Cuando ocurre un error de `Access Denied` en producción, siga esta jerarquía lógica de eliminación:

```
[ Application Permission Request Failed ]
                   |
                   v
     [ Check 1: Traditional DAC ]
     Is User/Group/Other bit matching? 
     Is Sticky Bit or umask blocking?
                   |
        +----------+----------+
        | NO                  | YES
        v                     v
[ Adjust standard     [ Check 2: POSIX Extended ACL ]
  chmod / chown ]     Is 'mask' restricting effective permissions?
                      Is explicit user/group ACL denying access?
                               |
                    +----------+----------+
                    | NO                  | YES
                    v                     v
            [ Check 3: Extended   [ Update setfacl /
              Attributes ]          recalculate mask ]
            Is file set to +i or +a via chattr?
                               |
                    +----------+----------+
                    | NO                  | YES
                    v                     v
            [ Check 4: Linux      [ Remove attribute:
              Security Module ]     chattr -i / -a ]
            Is system running SELinux or AppArmor?
                               |
                    +----------+----------+
                    | SELinux             | AppArmor
                    v                     v
            [ Inspect audit.log   [ Inspect dmesg /
              for AVC denials ]     syslog for AppArmor ]
```

---

### 5.2 Flujo de Trabajo para la Resolución de Problemas de SELinux AVC

#### Paso 1: Capturar el Evento Exacto de Denegación (Denial Event)
Consulte `/var/log/audit/audit.log` utilizando `ausearch` filtrando por mensajes de Access Vector Cache (AVC).

```console
$ ausearch -m avc -ts recent
----
time->Thu Aug  6 13:30:10 2026
type=AVC msg=audit(1786037410.512:410): avc:  denied  { read } for  pid=12510 comm="nginx" name="index.html" dev="sda1" ino=912401 scontext=system_u:system_r:httpd_t:s0 tcontext=unconfined_u:object_r:user_home_t:s0 tclass=file permissive=0
```

#### Paso 2: Analizar la Incongruencia de Contexto (Context Mismatch)
* **Contexto del Sujeto (`scontext`):** `system_u:system_r:httpd_t:s0` (Servidor web ejecutándose en el dominio `httpd_t`).
* **Contexto del Objetivo (`tcontext`):** `unconfined_u:object_r:user_home_t:s0` (Archivo objetivo etiquetado con el tipo de directorio home de usuario `user_home_t`).
* **Causa Raíz:** NGINX está intentando leer un archivo etiquetado como datos de home de usuario, lo cual está prohibido bajo la política `targeted` predeterminada de SELinux.

#### Paso 3: Estrategias Diagnósticas de Resolución

**Opción A: Corregir Contextos de Archivo (Recomendado si el archivo está en la ubicación correcta)**
```console
$ semanage fcontext -a -t httpd_sys_content_t "/srv/www/html(/.*)?"
$ restorecon -Rv /srv/www/html
```

**Opción B: Alternar Booleano (Si la función está gobernada por un conmutador de política)**
```console
$ sealert -a /var/log/audit/audit.log
# Sealert analyzes denial and suggests:
# If you want to allow httpd to read home directories:
# setsebool -P httpd_enable_homedirs 1
$ setsebool -P httpd_enable_homedirs 1
```

**Opción C: Generar un Módulo Personalizado mediante `audit2allow` (Usar como último recurso)**
```console
$ ausearch -m avc -c "nginx" | audit2allow -M fix_nginx_denial
$ semodule -i fix_nginx_denial.pp
```

---

### 5.3 Flujo de Trabajo para la Resolución de Problemas de AppArmor

#### Paso 1: Consultar los Logs del Sistema en Busca de Mensajes DENIED
Las violaciones de AppArmor se emiten en `dmesg`, `/var/log/syslog` o el journal de systemd.

```console
$ journalctl -ke | grep -i apparmor
Aug 06 13:35:22 node-01 kernel: audit: type=1400 audit(1786037722.814:521): apparmor="DENIED" operation="open" profile="nginx" name="/etc/nginx/conf.d/custom.conf" pid=12601 comm="nginx" requested_mask="r" denied_mask="r" fsuid=0 ouid=0
```

#### Paso 2: Analizar los Detalles de la Violación
* **Perfil:** `nginx`
* **Operación:** `open`
* **Ruta Objetivo:** `/etc/nginx/conf.d/custom.conf`
* **Permiso Solicitado:** `r` (read)
* **Causa Raíz:** El perfil `/etc/apparmor.d/usr.sbin.nginx` carece de una regla explícita que permita acceso de lectura a los subarchivos dentro de `/etc/nginx/conf.d/`.

#### Paso 3: Optimización Interactiva con Log-Prof
Ejecute `aa-logprof` para analizar los registros de auditoría y actualizar interactivamente las reglas del perfil.

```console
$ aa-logprof
Reading log entries from /var/log/syslog.
Updating AppArmor profiles in /etc/apparmor.d.
Enforcing requested permissions...

Profile:        nginx
Path:           /etc/nginx/conf.d/custom.conf
New Mode:       r
Severity:       unknown

  1 - #include <abstractions/base> 
  2 - /etc/nginx/conf.d/custom.conf 
* 3 - /etc/nginx/conf.d/* 
[(A)llow] / (D)eny / (I)gnore / (G)lob / (E)dit profile: 3

Adding /etc/nginx/conf.d/* r to profile.
Save Changes? [(S)ave] / (C)ancel: S
```

---

## 6. Referencias

* **Linux Professional Institute (LPI) LPIC-3 Security Objectives:**  
  [https://www.lpi.org/our-certifications/lpic-3-303-overview/](https://www.lpi.org/our-certifications/lpic-3-303-overview/)
* **LPI Wiki — LPIC-3 (303-300) Detailed Syllabus:**  
  [https://wiki.lpi.org/wiki/LPIC-3_303_Objectives_V3.0](https://wiki.lpi.org/wiki/LPIC-3_303_Objectives_V3.0)
* **Red Hat Enterprise Linux 9 — Managing SELinux:**  
  [https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/using_selinux/index](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/using_selinux/index)
* **Ubuntu Server Documentation — AppArmor Configuration:**  
  [https://ubuntu.com/server/docs/security-apparmor](https://ubuntu.com/server/docs/security-apparmor)
* **Linux Kernel Security Module (LSM) Architecture:**  
  [https://www.kernel.org/doc/html/latest/security/lsm.html](https://www.kernel.org/doc/html/latest/security/lsm.html)
* **POSIX Access Control Lists (ACLs) Linux Man Page:**  
  [https://man7.org/linux/man-pages/man5/acl.5.html](https://man7.org/linux/man-pages/man5/acl.5.html)