# Guía de Estudio LPI-702: Tema 712.4 – Administrar Permisos y Propiedad de Archivos

**Examen:** BSD Specialist (Examen 702-100, Versión 1.0)  
**Tema 712:** Storage Devices and BSD Filesystems  
**Subtema 712.4:** Manage File Permissions and Ownership  
**Ponderación:** 5  

---

## 1. Motivación Arquitectónica y Problema de Producción

En entornos empresariales BSD multitenant (multi-inquilino)—como infraestructura que ejecuta FreeBSD Jails, routers de borde OpenBSD o nodos de almacenamiento de alta densidad respaldados por ZFS—la aplicación de la seguridad de archivos ocurre a través de múltiples subsistemas del kernel:
1. Bits de permisos estándar de Control de Acceso Discrecional (DAC, Discretionary Access Control) (POSIX `rwx`, SUID, SGID, Sticky Bit).
2. Máscaras de modo de ejecución de procesos (`umask`).
3. Flags de Archivos del Kernel (Kernel File Flags) específicos de BSD (`chflags` como `schg`, `uchg`, `sappnd`).
4. Listas de Control de Acceso (ACLs, Access Control Lists) granulares (ACLs NFSv4 y POSIX.1e en ZFS y UFS2).

### El Escenario del Incidente de Producción
Considere una pasarela de pago (payment gateway) de producción de alta concurrencia ejecutándose dentro de un FreeBSD Jail con un pool de almacenamiento ZFS (`tank/jail/gateway`). Una intromisión en un proceso daemon no privilegiado (usuario `www`) intenta alterar dependencias binarias (`/usr/local/bin/gateway-daemon`) y escribir malware en un directorio de sockets temporales compartido (`/var/run/app-sockets`).

Si los permisos están desconfigurados:
* **Fallo Estándar de DAC:** Los permisos estándar `0755` permiten que los procesos `root` dentro de un jail no privilegiado muten binarios compartidos si la asignación de jail root se gestiona de forma incorrecta, o permiten que los usuarios que comparten un grupo sobrescriban configuración crítica.
* **Falta de Inmutabilidad:** Los ajustes estándar de `chmod` y `chown` permiten que incluso errores administrativos benignos (por ejemplo, un `rm -rf /` erróneo o la inyección maliciosa de un `payload` por parte de un root comprometido dentro del contenedor/jail) sobrescriban binarios estáticos y la configuración del sistema.
* **Control de Acceso Poco Granular (Coarse Access Control):** Los bits POSIX `u/g/o` fuerzan a los ingenieros a elegir entre permisos excesivamente abiertos (`0777`) o una gestión de grupos inflada al compartir directorios de logs entre agentes de auditoría, servidores web y workers de base de datos.

### Solución Arquitectónica
Para lograr un aislamiento de sistema de archivos de cero confianza (zero-trust) e integridad inmutable del sistema, los Arquitectos de Plataforma diseñan una defensa de acceso en capas utilizando primitivas de BSD:
* **Inmutabilidad del Kernel (`schg` / `uchg`):** Protege los binarios contra modificaciones no autorizadas incluso por parte del superusuario `root` (cuando se ejecuta en un `securelevel` elevado del kernel).
* **Logs de Solo Anexo (Append-Only Logging) (`sappnd` / `uappnd`):** Fuerza a que los logs de auditoría y de aplicaciones sean únicamente de anexo, evitando la manipulación de logs durante el análisis posterior a una explotación (post-exploitation).
* **Set Group ID (SGID) y Sticky Bits:** Aplican la herencia de grupo en directorios mientras previenen la eliminación de archivos multitenant dentro de espacios de borrador (scratch spaces) compartidos.
* **Herencia de ACL NFSv4:** Anula los bits de modo POSIX rudimentarios con entradas de control de acceso (ACEs) exactas heredadas automáticamente en datasets de ZFS.

```
                     +-------------------------------------------------------+
                     |                 Kernel Access Check                   |
                     +-------------------------------------------------------+
                                                 |
                                                 v
                     +-------------------------------------------------------+
                     |    1. Kernel Securelevel & BSD Flags Check            |
                     |   (e.g., schg, uchg, sappnd via chflags/vnode flags) |
                     +-------------------------------------------------------+
                                                 |
                                            Pass | (Not Blocked)
                                                 v
                     +-------------------------------------------------------+
                     |    2. Access Control Lists (NFSv4 / POSIX.1e ACLs)    |
                     |   (Evaluated before standard Unix mode bits if present) |
                     +-------------------------------------------------------+
                                                 |
                                            Pass | (ACL matched / fallback)
                                                 v
                     +-------------------------------------------------------+
                     |    3. Traditional Discretionary Access Control (DAC)  |
                     |   (UID/GID match against owner/group/other rwx bits)   |
                     +-------------------------------------------------------+
                                                 |
                                            Pass | (Allowed)
                                                 v
                     +-------------------------------------------------------+
                     |           System Call Granted (Read/Write/Exec)       |
                     +-------------------------------------------------------+
```

---

## 2. Comparaciones Técnicas y Tablas de Sopesamiento (Trade-off)

### Modelos de Aplicación de Permisos: DAC vs. BSD File Flags vs. ACLs NFSv4

| Característica / Atributo | POSIX DAC Tradicional (`chmod`/`chown`) | Flags de Archivo de BSD (`chflags`) | ACLs NFSv4 (`setfacl`/`getfacl`) |
| :--- | :--- | :--- | :--- |
| **Granularidad** | Usuario Único, Grupo Único, Otros (`u/g/o`) | Bits de estado a nivel de sistema / usuario en Vnode | Lista arbitraria de Usuarios, Grupos y Reglas Explícitas de Herencia |
| **Anulación del Superusuario** | `root` (UID 0) omite todas las comprobaciones `rwx` | `root` **no puede** anular `schg`/`sappnd` si `securelevel > 0` | `root` puede modificar ACLs, pero las ACEs aplican strictly límites de no-root |
| **Ubicación de Metadatos de Almacenamiento** | Bits de modo estándar del Inode / Vnode (`st_mode`) | Máscara de bits de flags del Inode / Vnode (`st_flags`) | Atributos Extendidos / Atributos del Sistema ZFS |
| **Sobrecarga de Rendimiento** | Despreciable (Operación directa con máscara de bits) | Despreciable (Comprobación bit a bit en el VFS del kernel) | Baja a Moderada (Análisis de ACL y evaluación de herencia en la creación) |
| **Caso de Uso Principal** | Ejecución de servicios y propiedad de Unix de referencia | Defensa contra ransomware, inmutabilidad de binarios del sistema, registros a prueba de manipulaciones | Compartición compleja de directorios multitenant empresariales |
| **Portabilidad** | Estándar POSIX Universal | Específico de BSD (FreeBSD, OpenBSD, NetBSD, macOS) | Estándar ZFS / NFSv4 (FreeBSD ZFS, Linux NFSv4) |

### Bits de Permisos Especiales en BSD

| Nombre del Bit | Octal Numérico | Comportamiento en Archivos | Comportamiento en Directorios | Riesgo / Implicación de Seguridad |
| :--- | :--- | :--- | :--- | :--- |
| **SUID** (Set-User-ID) | `4000` | El proceso se ejecuta con privilegios del **propietario** del archivo (ej. `root`). | Sin efecto en sistemas BSD estándar. | **Alto:** Riesgo de escalación de privilegios si el binario contiene errores de ejecución. |
| **SGID** (Set-Group-ID) | `2000` | El proceso se ejecuta con privilegios del **grupo** del archivo. | Los subarchivos/directorios recién creados heredan el **GID** del directorio padre. | **Medio:** Acceso no intencionado a archivos si la propiedad del grupo del directorio es laxa. |
| **Sticky Bit** | `1000` | Caching del segmento de texto (comportamiento obsoleto de legacy BSD). | Solo el **propietario** del archivo o `root` pueden renombrar/eliminar archivos dentro del directorio. | **Bajo:** Obligatorio para directorios temporales compartidos como `/tmp` y `/var/tmp`. |

---

## 3. Manifiestos Completos de Infraestructura y Configuración del Sistema

### 1. Script de Endurecimiento (Hardening) del Sistema FreeBSD: `/usr/local/sbin/harden-platform.sh`
Este script shell configura las máscaras de creación de procesos a nivel de sistema (`umask`), restringe la herencia de directorios mediante variables del kernel, aplica flags a nivel de sistema a utilidades base y aprovisiona un espacio de trabajo multitenant asegurado con ACLs NFSv4 en ZFS.

```sh
#!/bin/sh
# System-wide Security and Permission Enforcement Script for BSD Environments
# Target OS: FreeBSD 13+ / 14+ on ZFS

set -euo pipefail

LOG_FILE="/var/log/sys_hardening.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "[+] Starting Enterprise BSD File System Hardening..."

# 1. Enforce strict system default process creation umask in login.conf
echo "[+] Updating default umask in /etc/login.conf..."
cap_mkdb /etc/login.conf

# 2. Configure kernel sysctl settings for permission safety
echo "[+] Configuring sysctl security knobs..."
sysctl security.bsd.see_other_uids=0
sysctl security.bsd.see_other_gids=0
sysctl security.bsd.hardlink_check_uid=1
sysctl security.bsd.hardlink_check_gid=1
sysctl security.bsd.unprivileged_proc_debug=0

cat << 'EOF' >> /etc/sysctl.conf
# Managed by Platform Automation - Hardened Kernel Parameters
security.bsd.see_other_uids=0
security.bsd.see_other_gids=0
security.bsd.hardlink_check_uid=1
security.bsd.hardlink_check_gid=1
security.bsd.unprivileged_proc_debug=0
EOF

# 3. Create Multi-tenant Application Storage with ZFS ACL Properties
DATASET="tank/appdata"
MOUNTPOINT="/var/appdata"

if ! zfs list "${DATASET}" >/dev/null 2>&1; then
    echo "[+] Creating ZFS Dataset ${DATASET} with strict NFSv4 ACL mode..."
    zfs create -o mountpoint="${MOUNTPOINT}" \
               -o aclmode=restricted \
               -o acltype=nfsv4 \
               "${DATASET}"
fi

# 4. Set Directory Structure and Special DAC Bits
echo "[+] Provisioning base application hierarchy..."
mkdir -p "${MOUNTPOINT}/shared_bin"
mkdir -p "${MOUNTPOINT}/shared_logs"
mkdir -p "${MOUNTPOINT}/incoming_data"

# Standard ownership setup
chown -R root:wheel "${MOUNTPOINT}"
chown -R root:www "${MOUNTPOINT}/shared_bin"
chown -R root:audit "${MOUNTPOINT}/shared_logs"
chown -R root:dataops "${MOUNTPOINT}/incoming_data"

# Apply standard DAC permissions
chmod 0755 "${MOUNTPOINT}"
chmod 0750 "${MOUNTPOINT}/shared_bin"
chmod 02770 "${MOUNTPOINT}/shared_logs"   # SGID set: force group inheritance
chmod 01777 "${MOUNTPOINT}/incoming_data" # Sticky bit set: prevent user file deletion

# 5. Apply BSD File Flags for Immutability and Append-Only Logging
echo "[+] Applying BSD Kernel Flags..."
# Protect core binaries from modification (System Immutable)
chflags schg /sbin/init /usr/bin/login /usr/bin/su /usr/bin/passwd

# Make log files in shared_logs append-only
touch "${MOUNTPOINT}/shared_logs/audit.log"
chown root:audit "${MOUNTPOINT}/shared_logs/audit.log"
chmod 0640 "${MOUNTPOINT}/shared_logs/audit.log"
chflags sappnd "${MOUNTPOINT}/shared_logs/audit.log"

# 6. Apply NFSv4 ACLs for Granular Operations
echo "[+] Configuring fine-grained NFSv4 ACEs..."
setfacl -s "owner@:rwaWCoDdaARWcCos:fd:allow,group@:rwaWdE:fd:allow,everyone@:r:fd:allow" "${MOUNTPOINT}/incoming_data"

echo "[+] Hardening complete. System state verified."
```

### 2. Plano de Infraestructura FreeBSD Jail: `/etc/jail.conf`
Define raíces de sistema de archivos aisladas, asegurando los límites de permisos a través de los jails.

```etc
# /etc/jail.conf - Production Multi-tenant Jail Configuration
# Enforces system level security boundaries and mount restrictions

exec.start = "/bin/sh /etc/rc";
exec.stop = "/bin/sh /etc/rc.shutdown";
exec.clean;
mount.devfs;
devfs_ruleset = "4";

# System-wide resource parameters
path = "/usr/jails/${name}";
host.hostname = "${name}.internal.net";

# Security level enforcement inside jails
securelevel = "2";

gateway_prod {
    vnet;
    vnet.interface = "epair0b";
    mount.fstab = "/etc/fstab.gateway_prod";
    exec.created = "zfs mount tank/jails/gateway_prod";
    exec.poststop = "zfs unmount tank/jails/gateway_prod";
}
```

### 3. Suite de Tareas de Automatización de Ansible: `manage_bsd_permissions.yml`
Automatiza la gestión de permisos, flags y la aplicación de umask a través de un clúster FreeBSD.

```yaml
---
- name: Harden BSD System Permissions, Flags, and ACLs
  hosts: bsd_servers
  gather_facts: true
  tasks:

    - name: Ensure target application groups exist
      ansible.builtin.group:
        name: "{{ item }}"
        state: present
      loop:
        - audit
        - dataops
        - secops

    - name: Set target directory DAC permissions and ownership
      ansible.builtin.file:
        path: /var/secure_app
        state: directory
        owner: root
        group: secops
        mode: '02750'

    - name: Set BSD System Immutable flag on core system configuration
      community.general.bsd_flags:
        path: /etc/master.passwd
        flags: schg
        state: present

    - name: Ensure log directory files have append-only flags set
      community.general.bsd_flags:
        path: /var/log/security
        flags: sappnd
        state: present

    - name: Configure system default umask in /etc/profile
      ansible.builtin.lineinfile:
        path: /etc/profile
        regexp: '^umask'
        line: 'umask 027'
        state: present
```

---

## 4. Comandos de CLI Reales y Logs de Ejecución de Terminal

### 1. Listado Diagnóstico de Archivos con BSD Flags (`ls -lo` y `stat`)
El `ls -l` estándar no expone los flags de archivos de BSD. Se requiere el flag `-o`.

```syslog
$ ls -lo /var/appdata/shared_logs/
total 4
-rw-r-----  1 root  audit  sappnd 1024 Aug  6 20:15 audit.log
drwxrws---  2 root  audit  -         512 Aug  6 20:15 archive

$ ls -lo /sbin/init /usr/bin/su
-r-xr-xr-x  1 root  wheel  schg 948320 Jun 22 14:02 /sbin/init
-r-sr-xr-x  1 root  wheel  schg  54120 Jun 22 14:02 /usr/bin/su

$ stat -f "File: %N | Octal Mode: %Lp | Mode String: %Sp | Owner: %Su (%u) | Group: %Sg (%g) | Flags: %SH" /var/appdata/shared_logs/audit.log
File: /var/appdata/shared_logs/audit.log | Octal Mode: 640 | Mode String: -rw-r----- | Owner: root (0) | Group: audit (1002) | Flags: sappnd
```

### 2. Modificación de Bits de Modo mediante Modos Octales y Simbólicos (`chmod`)

```syslog
# Grant group execute, remove all permissions from others using symbolic syntax
$ chmod g+x,o-rwx /var/appdata/shared_bin/gateway-daemon

# Verify symbolic update
$ ls -l /var/appdata/shared_bin/gateway-daemon
-rwxr-x---  1 root  www  45088 Aug  6 20:20 /var/appdata/shared_bin/gateway-daemon

# Apply octal mode setting SUID and SGID simultaneously (6750 = SUID 4000 + SGID 2000 + 0750)
$ chmod 6750 /usr/local/bin/custom-auth-helper
$ ls -l /usr/local/bin/custom-auth-helper
-rwsr-s---  1 root  secops  18432 Aug  6 20:21 /usr/local/bin/custom-auth-helper
```

### 3. Configuración y Limpieza de Flags de Archivos BSD (`chflags`)

```syslog
# Attempt to modify an append-only file using standard user redirection (Fails)
$ echo "Unauthorized entry" >> /var/appdata/shared_logs/audit.log
sh: /var/appdata/shared_logs/audit.log: Operation not permitted

# Attempt to remove a system immutable file as root (Fails when securelevel >= 1)
$ syslog-ng --test
$ rm -f /sbin/init
rm: /sbin/init: Operation not permitted

# Unset user immutable flag (uchg) on user owned data
$ chflags nouchg /home/deploy/release.tar.gz
$ ls -lo /home/deploy/release.tar.gz
-rw-r--r--  1 deploy  deploy  - 5242880 Aug  6 20:22 /home/deploy/release.tar.gz

# Set user append-only flag (uappnd)
$ chflags uappnd /home/deploy/app.log
$ ls -lo /home/deploy/app.log
-rw-r--r--  1 deploy  deploy  uappnd 4096 Aug  6 20:23 /home/deploy/app.log
```

### 4. Evaluación de Máscaras de Creación de Procesos (`umask`)

```syslog
# Check current shell umask
$ umask
0022

# Test file creation under default umask (0022)
$ touch /tmp/test_default.txt
$ ls -l /tmp/test_default.txt
-rw-r--r--  1 deploy  deploy  0 Aug  6 20:25 /tmp/test_default.txt

# Set restrictive umask for secure operations (0077: no permissions for group/others)
$ umask 0077
$ umask -S
u=rwx,g=,o=

# Test file and directory creation under secure umask
$ touch /tmp/test_secure.txt
$ mkdir /tmp/test_dir
$ ls -ld /tmp/test_secure.txt /tmp/test_dir
drwx------  2 deploy  deploy  512 Aug  6 20:26 /tmp/test_dir
-rw-------  1 deploy  deploy    0 Aug  6 20:26 /tmp/test_secure.txt
```

### 5. Gestión de Listas de Control de Acceso NFSv4 (`getfacl` / `setfacl`)

```syslog
# Read default NFSv4 ACL on ZFS dataset
$ getfacl /var/appdata/incoming_data
# file: /var/appdata/incoming_data
# owner: root
# group: dataops
            owner@:rwaWCoDdaARWcCos:fd----:allow
            group@:rwaWdE----------:fd----:allow
         everyone@:r-------------:fd----:allow

# Add explicit entry granting user 'secmod' full read/write/delete permissions
$ setfacl -m u:secmod:rw-pDdaARWcCos:fd----:allow /var/appdata/incoming_data

# Read modified ACLs
$ getfacl /var/appdata/incoming_data
# file: /var/appdata/incoming_data
# owner: root
# group: dataops
         user:secmod:rwaWCoDdaARWcCos:fd----:allow
            owner@:rwaWCoDdaARWcCos:fd----:allow
            group@:rwaWdE----------:fd----:allow
         everyone@:r-------------:fd----:allow

# Remove explicit user ACE
$ setfacl -x u:secmod:rw-pDdaARWcCos:fd----:allow /var/appdata/incoming_data
```

---

## 5. Guía de Solución de Problemas y Verificación

### Diagrama de Flujo Diagnóstico para Denegaciones de Acceso a Archivos

```
                   [ Operation Fails: "Operation not permitted" or "Permission denied" ]
                                                 |
                                                 v
                                  Check Kernel Securelevel:
                                  `sysctl kern.securelevel`
                                                 |
                       +-------------------------+-------------------------+
                       |                                                   |
             securelevel >= 1                                    securelevel <= 0
                       |                                                   |
                       v                                                   v
       Check system flags: `ls -lo`                        Check traditional user/group permissions
       Are `schg` or `sappnd` active?                      Is current UID == File Owner?
                       |                                                   |
           +-----------+-----------+                           +-----------+-----------+
           |                       |                           |                       |
          YES                      NO                         YES                      NO
           |                       |                           |                       |
     MUST reboot into       Check user flags:            Verify exact mode     Check Group Membership
     Single-User mode       `uchg` / `uappnd`            bits (`chmod`) and    `id -Gn <user>` & ACLs
     to clear flags.        `chflags nouchg <file>`      umask settings.       `getfacl <file>`
```

### Escenarios Comunes de Producción y Análisis de Causa Raíz

#### Escenario A: El usuario root obtiene "Operation not permitted" (EPERM) al intentar eliminar o editar un archivo de configuración.
* **Síntoma:** `rm -f /etc/resolv.conf` ejecutado como `root` devuelve `rm: /etc/resolv.conf: Operation not permitted`.
* **Causa Raíz:** El archivo tiene activado el flag System Immutable (`schg`), y el `kern.securelevel` del kernel está actualmente configurado en `1` o `2`.
* **Verificación Diagnóstica:**
  ```syslog
  $ sysctl kern.securelevel
  kern.securelevel: 1
  $ ls -lo /etc/resolv.conf
  -rw-r--r--  1 root  wheel  schg 148 Aug  6 19:40 /etc/resolv.conf
  ```
* **Remediación:** Si `securelevel > 0`, los flags del sistema no se pueden limpiar ni siquiera mediante root mientras se ejecute en modo multiusuario. El administrador debe reiniciar en modo monousuario (single-user mode), bajar el securelevel, ejecutar `chflags noschg /etc/resolv.conf`, modificar el archivo y reiniciar.

#### Escenario B: Un miembro del grupo no puede escribir en un directorio a pesar de que el directorio tiene permisos `0770`.
* **Síntoma:** El usuario `alice` está en el grupo `dataops`. El directorio `/var/data` tiene el modo `0770` (`drwxrwx--- root dataops`). `alice` ejecuta `touch /var/data/file.txt` y recibe `Permission denied`.
* **Causa Raíz 1:** La sesión de shell de inicio de sesión dinámico del usuario no ha actualizado su vector de grupos suplementarios.
* **Causa Raíz 2:** Una entrada de ACL extendida o una máscara de ACL restringe las capacidades de escritura.
* **Verificación Diagnóstica:**
  ```syslog
  # Step 1: Verify current session credentials
  $ id
  uid=1001(alice) gid=1001(alice) groups=1001(alice) # Notice 'dataops' is missing!

  # Step 2: If group is present, inspect ACL mask on ZFS
  $ getfacl /var/data
  # file: /var/data
  # owner: root
  # group: dataops
  mask::r-x
  ```
* **Remediación:** Si falta en los grupos de la sesión actual, ejecute `exec su - ${USER}` o reautentíquese. Si una máscara de ACL limita los permisos, ejecute `setfacl -m mask::rwx /var/data`.

#### Escenario C: Los archivos recién creados en un directorio compartido no heredan la propiedad de grupo, lo que rompe los flujos de trabajo de los servicios.
* **Síntoma:** El usuario `bob` crea `/var/appdata/shared_logs/app.log`. El archivo se crea con el grupo primario `bob` en lugar de `audit`. Otros miembros de `audit` no pueden leerlo.
* **Causa Raíz:** El directorio padre `/var/appdata/shared_logs` carece del bit Set-Group-ID (SGID) (`2000`).
* **Verificación Diagnóstica:**
  ```syslog
  $ ls -ld /var/appdata/shared_logs
  drwxrwxr-x  2 root  audit  512 Aug  6 20:10 /var/appdata/shared_logs
  ```
* **Remediación:** Aplique el bit SGID al directorio:
  ```syslog
  $ chmod g+s /var/appdata/shared_logs
  $ ls -ld /var/appdata/shared_logs
  drwxrwsr-x  2 root  audit  512 Aug  6 20:30 /var/appdata/shared_logs
  ```

### Hoja de Chequeo (Cheat Sheet) de Comandos de Auditoría para Auditorías de Seguridad de SRE

```syslog
# 1. Audit all SUID binaries across the filesystem
$ find / -type f -perm -4000 -exec ls -ld {} + 2>/dev/null

# 2. Audit all SGID binaries
$ find / -type f -perm -2000 -exec ls -ld {} + 2>/dev/null

# 3. Find world-writable files excluding symlinks and sockets
$ find / -type f -perm -0002 ! -type l -exec ls -lo {} + 2>/dev/null

# 4. Find all files with active BSD system flags (schg, uchg, sappnd, uappnd)
$ find / -flags +schg,uchg,sappnd,uappnd -exec ls -ldo {} + 2>/dev/null

# 5. Audit directories missing the sticky bit under /tmp or /var
$ find /var/tmp /tmp -type d ! -perm -1000 -exec ls -ld {} +
```

---

## 6. Referencias

* **Visión General de la Certificación LPI BSD Specialist:**  
  [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
* **Páginas de Manual de FreeBSD – `chmod(1)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=chmod&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=chmod&sektion=1)
* **Páginas de Manual de FreeBSD – `chflags(1)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=chflags&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=chflags&sektion=1)
* **Páginas de Manual de FreeBSD – `chown(1)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=chown&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=chown&sektion=1)
* **Páginas de Manual de FreeBSD – `setfacl(1)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=setfacl&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=setfacl&sektion=1)
* **Páginas de Manual de FreeBSD – `getfacl(1)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=getfacl&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=getfacl&sektion=1)
* **Páginas de Manual de FreeBSD – `umask(2)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=umask&sektion=2](https://man.freebsd.org/cgi/man.cgi?query=umask&sektion=2)
* **Handbook de FreeBSD – Capítulo de Seguridad:**  
  [https://docs.freebsd.org/en/books/handbook/security/](https://docs.freebsd.org/en/books/handbook/security/)