# Guía de Producción Enterprise: Gestión de Cuentas de Usuario y Grupos en BSD
**Certificación:** LPI 702 BSD Specialist (Exam 702-100, Version 1.0)  
**Tema 713.1:** Manage User Accounts and Groups  
**Peso del Objetivo:** 5  

---

## 1. Motivación Arquitectónica y Problemática en Producción

En entornos enterprise multitenant y de alta disponibilidad, la gestión de estado para identidades de usuario y autorización de grupos constituye el límite de seguridad central del sistema operativo. La gestión de usuarios y grupos UNIX en plataformas BSD (FreeBSD, OpenBSD, NetBSD) difiere fundamentalmente de los modelos de distribuciones Linux tanto en la arquitectura de base de datos como en el rendimiento de resolución en tiempo de ejecución.

### El Problema de Identidad en Producción
Las arquitecturas de infraestructura modernas se enfrentan a tres desafíos principales con respecto a la gestión local de identidades:

1. **Latencia de Búsqueda del Sistema a Escala**: El análisis secuencial (parsing) de archivos de texto estándar (`/etc/passwd`, `/etc/group`) introduce severos cuellos de botella de I/O cuando el número de usuarios escala a decenas de miles en servidores de aplicaciones de alto rendimiento, nodos de procesamiento por lotes (batch) o pools de compilación de CI/CD.
2. **Actualizaciones de Estado Atómicas y Control de Concurrencia**: Las condiciones de carrera (race conditions) durante el aprovisionamiento concurrente de usuarios (por ejemplo, agentes automatizados de gestión de configuración ejecutándose junto con scripts de bootstrap de usuarios para microservicios) pueden resultar en archivos de identidad truncados, permisos inconsistentes o bloqueos del sistema (lockouts).
3. **Aislamiento de Recursos de Granularidad Fina (Login Capabilities)**: Linux tradicionalmente separa los límites de recursos en `/etc/security/limits.conf` (dependiente de PAM) y las propiedades de usuario en `/etc/passwd`. BSD consolida los metadatos del perfil de usuario, límites de memoria de procesos, límites de descriptores de archivo abiertos, uso de recursos, restricciones de CPU y requisitos de autenticación en un motor unificado respaldado por `/etc/login.conf`.

### Soluciones Arquitectónicas de BSD
Los sistemas BSD resuelven estos desafíos mediante:
* **Generación de Bases de Datos Hasheadas**: El archivo maestro de cuentas `/etc/master.passwd` se compila a través de `pwd_mkdb` en bases de datos binarias Berkeley DB indexadas (`/etc/pwd.db` y `/etc/spwd.db`). Las llamadas al sistema (system calls: `getpwnam(3)`, `getpwuid(3)`) realizan búsquedas binarias indexadas $O(1)$ en lugar de escaneos secuenciales de archivos $O(N)$.
* **Separación de Passwords Públicas y Shadow Passwords**: `/etc/passwd` contiene metadatos públicos (con los campos de contraseña enmascarados como `*`), mientras que `/etc/master.passwd` y `/etc/spwd.db` almacenan hashes de contraseñas encriptados (bcrypt/SHA-512) accesibles exclusivamente por `root` (modo `0600`).
* **Utilidad Centralizada del Sistema (`pw`)**: FreeBSD centraliza todas las mutaciones de cuentas y grupos a través del motor de gestión `pw(8)`. Maneja el bloqueo (locking) mediante `/etc/ptmp`, actualizaciones atómicas de archivos, inicialización del skeleton del home directory, asignaciones de login class y regeneración automática de bases de datos en una sola transacción.

---

## 2. Comparaciones Técnicas y Tablas de Trade-offs

### 2.1 Arquitectura de Base de Datos de Identidad de BSD vs. Arquitectura Shadow de Linux

| Característica / Dimensión | Arquitectura de Identidad de BSD (`/etc/master.passwd`) | Arquitectura de Identidad de Linux (`/etc/shadow`) |
| :--- | :--- | :--- |
| **Archivo Maestro Principal** | `/etc/master.passwd` (10 campos) | Dividido entre `/etc/passwd` (7 campos) y `/etc/shadow` (9 campos) |
| **Mecanismo de Búsqueda** | Búsquedas binarias Berkeley DB $O(1)$ (`/etc/pwd.db`, `/etc/spwd.db`) | Escaneo de texto $O(N)$ o caching mediante demonios `nscd`/`sssd` |
| **Herramienta de Compilación de BD** | `pwd_mkdb` (manual o activado automáticamente vía `pw`/`vipw`) | `grpck` / `pwconv` / `grpconv` (scripts de utilidad de sincronización) |
| **Control de Asignación de Recursos** | Mapeo nativo del campo login class a `/etc/login.conf` | Módulos PAM externos (`pam_limits.so`) y slices de Systemd |
| **Almacenamiento de Expiración de Password** | Campos epoch embebidos en `master.passwd` (`change`, `expire`) | Almacenado en archivo shadow como días desde la Epoch |
| **Lockfile de Bloqueo de Archivos** | `/etc/ptmp` | `/etc/passwd.lock`, `/etc/shadow.lock` |

### 2.2 Comparación de Herramientas de Aprovisionamiento de Usuarios entre Variantes BSD

| Comando / Herramienta | Plataforma Principal | Operaciones Soportadas | Características Clave y Trade-offs |
| :--- | :--- | :--- | :--- |
| **`pw`** | FreeBSD | CRUD de Usuario/Grupo, bloqueo (locking), envejecimiento de password | Binario del sistema unificado; operaciones atómicas; actualiza directamente la base de datos maestra y las BDs binarias. |
| **`useradd` / `usermod` / `userdel`** | OpenBSD / NetBSD | Gestión del ciclo de vida del usuario | Interfaz CLI estándar estilo POSIX; wrapper alrededor de rutinas de creación de BD shadow. |
| **`vipw` / `vigr`** | Todos los BSDs | Modificación manual interactiva | Bloquea `/etc/ptmp` usando un editor; compila automáticamente `/etc/pwd.db` y `/etc/spwd.db` al guardar. |
| **`adduser`** | FreeBSD / NetBSD | Script interactivo de creación | Wrapper en Shell/Perl diseñado para configuración manual de sysadmins; usa `/etc/adduser.conf`. No apto para automatización no interactiva. |
| **`chpass` / `chfn` / `chsh`** | Todos los BSDs | Modificación de metadatos de usuario | Modifica el GECOS del usuario, shell o contraseña; actualiza `/etc/master.passwd` y regenera las BDs. |

---

## 3. Manifiestos Completos e Infraestructuras de Configuración

### 3.1 El Esquema BSD de 10 Campos de `/etc/master.passwd`
A diferencia del archivo `/etc/passwd` de Linux de 7 campos, los archivos de cuenta maestra de BSD utilizan una disposición de 10 campos separados por dos puntos:

```text
name:password:uid:gid:class:change:expire:gecos:homedir:shell
```

#### Referencia de Especificación de Campos
1. `name`: Identificador de login del usuario (alfanumérico, sensible a mayúsculas y minúsculas, máx. 32 caracteres).
2. `password`: Hash encriptado (por ejemplo, `$6$` para SHA-512, `$2b$` para bcrypt, `*` para cuentas bloqueadas/sin login).
3. `uid`: User ID numérico (0 para superusuario, <1000 para demonios del sistema, ≥1000 para usuarios estándar).
4. `gid`: Group ID primario (se mapea con `/etc/group`).
5. `class`: Clase de login capability (definida en `/etc/login.conf`, por ejemplo, `default`, `staff`, `untrusted`).
6. `change`: Fecha límite para cambio de contraseña (timestamp UNIX en segundos; `0` deshabilita la rotación obligatoria de contraseñas).
7. `expire`: Fecha de expiración de la cuenta (timestamp UNIX en segundos; `0` deshabilita la expiración de la cuenta).
8. `gecos`: Información general (Nombre completo, Oficina, Teléfono de oficina, Teléfono particular).
9. `homedir`: Ruta absoluta al home directory.
10. `shell`: Ruta al shell por defecto del usuario (debe estar listado en `/etc/shells`).

#### Ejemplo Sintácticamente Válido de `/etc/master.passwd`
```text
root:$6$v19zG9.k$8N3Z.6vUe...:0:0::0:0:System Administrator:/root:/bin/csh
daemon:*:1:1::0:0:Owner of many system processes:/root:/usr/sbin/nologin
operator:*:2:5::0:0:System Site Operator:/usr/share/man:/usr/sbin/nologin
bin:*:3:7::0:0:Binaries Commands and Source:/usr/include:/usr/sbin/nologin
tty:*:4:4::0:0:Tty Arbitrator:/nonexistent:/usr/sbin/nologin
kmem:*:5:5::0:0:KMem Arbitrator:/nonexistent:/usr/sbin/nologin
games:*:7:13::0:0:Games pseudo-user:/nonexistent:/usr/sbin/nologin
news:*:8:8::0:0:News Subsystem:/nonexistent:/usr/sbin/nologin
man:*:9:9::0:0:World Wide Web Owner:/nonexistent:/usr/sbin/nologin
sshd:*:22:22::0:0:SSHD Privilege Separation User:/var/empty:/usr/sbin/nologin
sre_admin:$6$J9kX...$4l0P...:1001:1001:staff:0:0:SRE Platform Lead:/home/sre_admin:/usr/local/bin/zsh
app_runner:$2b$12$K8...:1002:1002:apps:0:1767225600:Application Service Account:/nonexistent:/usr/sbin/nologin
```

---

### 3.2 Matriz de Capabilities de `/etc/login.conf` en Producción
El archivo `/etc/login.conf` establece topes de límites de procesos, inyección de variables de entorno y reglas de seguridad por clase de capability.

```text
# /etc/login.conf - Production Hardened Platform Configuration
# Compile changes using: cap_mkdb /etc/login.conf

default:\
	:passwd_format=sha512:\
	:copyright=/etc/COPYRIGHT:\
	:welcome=/etc/motd:\
	:setenv=MAIL=/var/mail/$$,BLOCKSIZE=K:\
	:path=/sbin /bin /usr/sbin /usr/bin /usr/local/sbin /usr/local/bin ~/bin:\
	:nologin=/var/run/nologin:\
	:cputime=unlimited:\
	:datasize=unlimited:\
	:stacksize=unlimited:\
	:memorylocked=64M:\
	:memoryuse=unlimited:\
	:filesize=unlimited:\
	:coredumpsize=0:\
	:openfiles=4096:\
	:maxproc=512:\
	:sbsize=unlimited:\
	:vmemorysize=unlimited:\
	:priority=0:\
	:ignoretime@:\
	:umask=022:

# High-Privilege Engineer Class
staff:\
	:tc=default:\
	:datasize=8G:\
	:openfiles=65536:\
	:maxproc=4096:\
	:coredumpsize=unlimited:\
	:umask=027:

# Application Service Account Class
apps:\
	:tc=default:\
	:requirehome@:\
	:coredumpsize=0:\
	:openfiles=131072:\
	:maxproc=8192:\
	:memorylocked=512M:\
	:umask=007:

# Restricted Multi-Tenant Class
untrusted:\
	:tc=default:\
	:datasize=1G:\
	:openfiles=256:\
	:maxproc=64:\
	:memoryuse=2G:\
	:priority=10:\
	:umask=077:
```

---

### 3.3 Archivo de Configuración de Usuarios y Grupos BSD en Producción: `/etc/pw.conf`
La utilidad `pw(8)` lee `/etc/pw.conf` para aplicar políticas de creación por defecto durante el aprovisionamiento automatizado.

```text
# /etc/pw.conf - FreeBSD Default Provisioning Configuration File
defaultgroup = 
group = 
defaultattributes = 
defaultshell = /bin/sh
reuseuids = no
reusegids = no
nispass = no
dnspass = no
minuid = 1000
maxuid = 32000
mingid = 1000
maxgid = 32000
home = /home
homemode = 0750
logfile = /var/log/pw.log
skippass = no
sendmail = no
sendmail_file = /etc/adduser.message
mkdir = yes
login_class = default
```

---

### 3.4 Script de Automatización Idempotente y Aprovisionamiento en Producción
Este script de shell compatible con POSIX demuestra el aprovisionamiento de cuentas de nivel enterprise, la compilación de bases de datos y la configuración de login capabilities para infraestructura destino FreeBSD.

```sh
#!/bin/sh
# System Identity Bootstrap Script for BSD Production Hosts
# Enforces account rules, login capability mapping, and DB synchronization.

set -eu

LOG_FILE="/var/log/sys_identity_provision.log"
exec 3>&1 1>>"${LOG_FILE}" 2>&1

log() {
    echo "[$(date -u +'%Y-%m-%d %H:%M:%SZ')] $*" >&3
    echo "[$(date -u +'%Y-%m-%d %H:%M:%SZ')] $*"
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

# Ensure execution by root
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be executed with superuser privileges."
fi

log "Beginning BSD System Identity Provisioning..."

# 1. Compile login.conf database
if [ -f /etc/login.conf ]; then
    log "Rebuilding /etc/login.conf.db binary database..."
    cap_mkdb /etc/login.conf
fi

# 2. Provision Core Operational Groups
log "Provisioning operational system groups..."
if ! pw show group deployment >/dev/null 2>&1; then
    pw groupadd deployment -g 2001
    log "Created group: deployment (GID 2001)"
fi

if ! pw show group secops >/dev/null 2>&1; then
    pw groupadd secops -g 2002
    log "Created group: secops (GID 2002)"
fi

# 3. Provision SRE Operator User Account
SRE_USER="ops_admin"
SRE_UID="1501"

if ! pw show user "${SRE_USER}" >/dev/null 2>&1; then
    log "Creating operational account ${SRE_USER}..."
    pw useradd "${SRE_USER}" \
        -u "${SRE_UID}" \
        -g deployment \
        -G wheel,secops \
        -c "Senior SRE Operator" \
        -d "/home/${SRE_USER}" \
        -m \
        -s /usr/local/bin/bash \
        -L staff
    
    # Lock password until initial SSH key deployment
    pw lock "${SRE_USER}"
    log "Account ${SRE_USER} provisioned and locked pending credential setup."
else
    log "Updating existing account ${SRE_USER} configuration..."
    pw usermod "${SRE_USER}" \
        -G wheel,secops \
        -L staff \
        -s /usr/local/bin/bash
fi

# 4. Enforce Strict Home Directory Permissions
log "Enforcing ACL/permission boundaries on home directories..."
chmod 0750 "/home/${SRE_USER}"
chown "${SRE_USER}:deployment" "/home/${SRE_USER}"

# 5. Explicitly Trigger Database Consistency Synchronization
log "Executing master database synchronization verify check..."
pwd_mkdb -c /etc/master.passwd

log "System identity provisioning successfully finished."
```

---

## 4. Comandos Reales de CLI y Salidas de Terminal Esperadas

### 4.1 Creación de Grupos del Sistema y Adición de Usuarios con `pw` (FreeBSD)

```syslog
$ sudo pw groupadd platform -g 3000
$ sudo pw show group platform
platform:*:3000:

$ sudo pw useradd devops_lead -u 3001 -g platform -G wheel -c "Platform Team Lead" -d /home/devops_lead -m -s /bin/sh -L staff
$ sudo pw show user devops_lead
devops_lead:*$6$...:3001:3000:staff:0:0:Platform Team Lead:/home/devops_lead:/bin/sh

$ id devops_lead
uid=3001(devops_lead) gid=3000(platform) groups=3000(platform),0(wheel)
```

---

### 4.2 Bloqueo de Cuentas y Auditoría de Estado

```syslog
$ sudo pw lock devops_lead
$ sudo pw show user devops_lead
devops_lead:*LOCKED**$6$...:3001:3000:staff:0:0:Platform Team Lead:/home/devops_lead:/bin/sh

$ grep devops_lead /etc/master.passwd
devops_lead:*LOCKED**$6$v19zG9...:3001:3000:staff:0:0:Platform Team Lead:/home/devops_lead:/bin/sh

$ sudo pw unlock devops_lead
$ sudo pw show user devops_lead
devops_lead:$6$v19zG9...:3001:3000:staff:0:0:Platform Team Lead:/home/devops_lead:/bin/sh
```

---

### 4.3 Modificación Interactiva Segura con `vipw`
Cuando se ejecuta `vipw`, abre `/etc/master.passwd` bajo un bloqueo temporal de archivo (`/etc/ptmp`). Al salir del editor, `vipw` valida la sintaxis y llama automáticamente a `pwd_mkdb`.

```syslog
$ sudo vipw
vipw: editing /etc/master.passwd
vipw: rebuilding target database...
vipw: sys db update complete
```

---

### 4.4 Compilando las Bases de Datos de Usuarios y Login Capabilities

```syslog
$ sudo pwd_mkdb -p -d /etc /etc/master.passwd
$ ls -la /etc/pwd.db /etc/spwd.db /etc/passwd /etc/master.passwd
-rw-r--r--  1 root  wheel   2412 Aug  6 20:10 /etc/master.passwd
-rw-r--r--  1 root  wheel   1854 Aug  6 20:12 /etc/passwd
-rw-r--r--  1 root  wheel  40960 Aug  6 20:12 /etc/pwd.db
-rw-------  1 root  wheel  40960 Aug  6 20:12 /etc/spwd.db

$ sudo cap_mkdb /etc/login.conf
$ ls -la /etc/login.conf.db
-rw-r--r--  1 root  wheel  16384 Aug  6 20:15 /etc/login.conf.db
```

---

### 4.5 Modificación de la Pertenencia a Grupos con `pw groupmod`

```syslog
$ sudo pw groupmod wheel -m devops_lead,sre_admin
$ sudo pw show group wheel
wheel:*:0:root,devops_lead,sre_admin

$ sudo pw groupmod wheel -d devops_lead
$ sudo pw show group wheel
wheel:*:0:root,sre_admin
```

---

### 4.6 Eliminación de Cuentas de Usuario con Limpieza

```syslog
$ sudo pw userdel devops_lead -r
$ id devops_lead
id: devops_lead: no such user

$ ls -d /home/devops_lead
ls: /home/devops_lead: No such file or directory
```

---

## 5. Guía de Verificación y Resolución de Problemas (Troubleshooting)

### 5.1 Fallos Comunes en Producción y Análisis de Causa Raíz

```
+-------------------------------------------------------+
|                 Symptom Observed                      |
+-------------------------------------------------------+
                           |
                           v
         +-----------------------------------+
         | Is /etc/ptmp lockfile remaining?  |
         +-----------------------------------+
                   /               \
            (Yes) /                 \ (No)
                 v                   v
   +---------------------------+   +------------------------------------+
   | Stale vipw/pw Lockfile    |   | Is database out of sync with text? |
   | Cause: Crashed session    |   +------------------------------------+
   | Fix: Remove /etc/ptmp     |              /             \
   +---------------------------+       (Yes) /               \ (No)
                                            v                 v
                              +--------------------+   +-----------------------+
                              | Corrupted .db file |   | PAM / Login Class     |
                              | Fix: Run pwd_mkdb  |   | Capability Misconfig  |
                              +--------------------+   +-----------------------+
```

---

### 5.2 Escenarios de Diagnóstico y Resolución Paso a Paso

#### Escenario A: Desincronización de Base de Datos (`/etc/master.passwd` vs `/etc/spwd.db`)
* **Síntoma**: Una cuenta de usuario agregada manualmente mediante un editor de texto o herramienta personalizada en `/etc/master.passwd` no puede autenticarse vía SSH o login estándar, o los comandos `getent passwd` / `id` reportan "no such user".
* **Causa Raíz**: Las APIs del sistema consultan `/etc/pwd.db` y `/etc/spwd.db`. Las ediciones manuales en `/etc/master.passwd` sin ejecutar `pwd_mkdb` dejan desactualizadas las bases de datos binarias indexadas.
* **Protocolo de Resolución**:
  1. Validar la sintaxis de `/etc/master.passwd`:
     ```syslog
     $ sudo pwd_mkdb -c /etc/master.passwd
     ```
  2. Forzar una reconstrucción limpia de la base de datos:
     ```syslog
     $ sudo pwd_mkdb -p /etc/master.passwd
     ```
  3. Verificar la funcionalidad de búsqueda:
     ```syslog
     $ id <username>
     ```

---

#### Escenario B: Lockfile Obsoleto Bloqueando la Gestión de Usuarios (`/etc/ptmp`)
* **Síntoma**: Ejecutar `pw`, `vipw` o `chpass` devuelve el siguiente fallo:
  ```syslog
  vipw: /etc/ptmp: Resource temporarily unavailable
  pw: cannot open /etc/ptmp: File exists
  ```
* **Causa Raíz**: Una ejecución previa de `vipw` o `pw` terminó de forma abrupta (por ejemplo, timeout de sesión SSH, SIGKILL), dejando el lockfile `/etc/ptmp` para prevenir escrituras concurrentes.
* **Protocolo de Resolución**:
  1. Inspeccionar el PID propietario del archivo o verificar instancias activas:
     ```syslog
     $ sudo fuser /etc/ptmp
     ```
  2. Si no hay ningún proceso en ejecución, verificar la antigüedad del lockfile y eliminarlo:
     ```syslog
     $ ls -l /etc/ptmp
     $ sudo rm -f /etc/ptmp
     ```
  3. Volver a ejecutar `vipw` para verificar el comportamiento normal de bloqueo de archivos.

---

#### Escenario C: Fallo de Escalación no Privilegiada para `su` (Restricción del Grupo `wheel`)
* **Síntoma**: Un usuario estándar que intenta ejecutar `su -` recibe `su: Permission denied` a pesar de proporcionar la contraseña de superusuario correcta.
* **Causa Raíz**: Por defecto en sistemas BSD, `su(1)` exige estrictamente que solo los usuarios pertenecientes al grupo primario o suplementario `wheel` (GID 0) estén autorizados a elevar privilegios a `root`.
* **Protocolo de Resolución**:
  1. Comprobar la pertenencia del usuario objetivo:
     ```syslog
     $ id <username>
     ```
  2. Añadir el usuario al grupo `wheel` usando `pw`:
     ```syslog
     $ sudo pw groupmod wheel -m <username>
     ```
  3. Volver a probar la escalación con `su -`.

---

#### Escenario D: Agotamiento de Recursos mediante Límites de Login Class
* **Síntoma**: Las aplicaciones propiedad de una cuenta de servicio específica fallan con `fork: Cannot allocate memory` o `Too many open files`, a pesar de que los valores globales de sysctl (`kern.maxfiles`, `kern.maxproc`) tienen suficiente margen (headroom).
* **Causa Raíz**: La login class asignada al usuario en `/etc/login.conf` tiene topes restrictivos por proceso (`openfiles`, `maxproc`, `datasize`).
* **Protocolo de Resolución**:
  1. Inspeccionar la asignación de login class del usuario:
     ```syslog
     $ pw show user <username> | cut -d: -f5
     ```
  2. Comprobar las definiciones de capabilities en `/etc/login.conf`.
  3. Ajustar los parámetros en `/etc/login.conf`, luego recompilar la base de datos de capabilities:
     ```syslog
     $ sudo cap_mkdb /etc/login.conf
     ```
  4. Solicitar al usuario que cierre e inicie sesión de nuevo para tomar los parámetros de clase actualizados (`login_cap`).

---

## 6. Referencias

* **LPI BSD Specialist Certification Overview**:  
  https://www.lpi.org/our-certifications/bsd-specialist-overview/
* **FreeBSD Handbook: User and Basic Account Management**:  
  https://docs.freebsd.org/en/books/handbook/basics/#users-synopsis
* **FreeBSD Manual Pages - `pw(8)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=pw&sektion=8
* **FreeBSD Manual Pages - `pwd_mkdb(8)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=pwd_mkdb&sektion=8
* **FreeBSD Manual Pages - `login.conf(5)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=login.conf&sektion=5
* **OpenBSD Manual Pages - `useradd(8)`**:  
  https://man.openbsd.org/useradd.8
* **OpenBSD Manual Pages - `vipw(8)`**:  
  https://man.openbsd.org/vipw.8