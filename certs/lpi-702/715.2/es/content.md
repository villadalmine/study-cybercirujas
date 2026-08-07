# LPI 702-100: Guía de estudio de producción avanzada de BSD
## Tema 715.2: Realizar la gestión básica de archivos (Peso: 5)

---

## 1. Motivación en producción y problema arquitectónico

En entornos de producción BSD empresariales —tales como infraestructura que ejecuta FreeBSD Jails, dispositivos edge embebidos NetBSD o firewalls de seguridad OpenBSD— la gestión de archivos va mucho más allá de la invocación básica de comandos. Los Platform Architects y Senior SREs deben diseñar flujos de trabajo en pipelines de archivos, despliegues automatizados y políticas de ciclo de vida del almacenamiento que garanticen la integridad de los datos, transiciones de estado atómicas, resistencia a fallas (crash resistance) y un rendimiento óptimo del sistema de archivos.

### Desafíos arquitectónicos clave

#### 1. Atomicidad, límites de almacenamiento y la restricción `EXDEV`
Las arquitecturas modernas de contenedores y microservicios dependen de estrategias de despliegue de archivos sin tiempo de inactividad (zero-downtime). Reemplazar un binario de aplicación o un archivo de configuración activo mediante la copia directa con truncamiento (`cp source target`) introduce condiciones de carrera (race conditions) donde los procesos leen escrituras parciales (vulnerabilidades TOCTOU: Time-of-Check to Time-of-Use o ejecución de binarios corruptos).

Los sistemas POSIX y BSD proporcionan atomicidad a través de la llamada al sistema `rename(2)` (`mv`), la cual intercambia entradas de directorio de forma instantánea dentro de un mismo montaje de sistema de archivos VFS. Sin embargo, cuando los directorios de destino cruzan los límites de montaje del sistema de archivos (por ejemplo, mover un archivo desde `/tmp` en `tmpfs` a `/var/db` en `ZFS`), `rename(2)` falla con el error `EXDEV` (*Cross-device link*). El sistema operativo recurre a una secuencia no atómica `read(2)` $\rightarrow$ `write(2)` $\rightarrow$ `unlink(2)`. Los pipelines de automatización empresarial deben detectar los límites de almacenamiento para prevenir la corrupción de estado durante las actualizaciones de software.

#### 2. Pérdida de metadatos, atributos y listas de control de acceso (ACL)
Las operaciones de copia estándar crean nuevos inodos con la configuración predeterminada del `umask` del usuario y actualizan las marcas de tiempo de acceso y modificación del archivo (`atime`/`mtime`). En migraciones de producción o flujos de trabajo de validación de respaldos, no preservar los bits de modo POSIX (`chmod`), la propiedad de usuario/grupo (`chown`), los atributos extendidos (`xattr`) y los flags de archivo específicos de BSD (`chflags`) vulnera los límites de seguridad y provoca denegaciones de acceso a las aplicaciones.

#### 3. Amplificación de almacenamiento mediante la expansión de archivos dispersos (Sparse Files)
Las imágenes base de contenedores, los discos de máquinas virtuales (`qcow2`, `raw`) y los bloques de asignación de motores de bases de datos (por ejemplo, archivos WAL de PostgreSQL o SQLite) a menudo utilizan *archivos dispersos* (sparse files), donde los rangos de bloques no escritos se almacenan como metadatos no asignados en lugar de bloques físicos de disco llenos de ceros. Ejecutar comandos de copia recursiva ingenuos sin detección de archivos dispersos expande gigabytes de espacio virtual asignado con agujeros (hole-allocated) a ceros secuenciales físicos, agotando los pools de almacenamiento y causando una masiva saturación de E/S.

#### 4. Recorrido de enlaces simbólicos (Symlink Traversals) y fuga de aislamiento de Jails
En entornos BSD Jails multitenant o restringidos, los comandos recursivos de archivos (`cp -R`, `rm -rf`) pueden seguir enlaces simbólicos que apuntan fuera del directorio del tenant previsto. Las eliminaciones o copias recursivas mal configuradas pueden cruzar puntos de montaje, desreferenciar enlaces simbólicos circulares causando bucles de recursión infinita o borrar involuntariamente datos a nivel del host.

#### 5. Inmutabilidad de archivos forzada por el kernel (`chflags` y `kern.securelevel`)
Los sistemas de archivos BSD implementan atributos de seguridad extendidos (`chflags(2)`) más allá de los permisos POSIX estándar. Los flags de inmutabilidad del sistema (`schg`) e inmutabilidad del usuario (`uchg`) impiden la modificación, eliminación o renombrado de archivos, incluso por parte del superusuario `root` (UID 0). Además, cuando el kernel se ejecuta a un nivel `kern.securelevel >= 1`, el flag `schg` no se puede remover hasta que el sistema se reinicie en modo monousuario (single-user mode). Los pipelines de automatización deben gestionar los flags de BSD de forma explícita durante las tareas de limpieza y compilación.

---

## 2. Comparativas técnicas y matriz de compensaciones (Trade-Offs)

### Tabla 2.1: Herramientas de copia y archivado de archivos en producción en BSD

| Herramienta / Mecanismo | Estándar POSIX / BSD | Preservación de metadatos (`flags`, ACLs, timestamps) | Manejo de archivos dispersos (Sparse Files) | Atomicidad entre sistemas de archivos | Eficiencia de E/S y rendimiento | Caso de uso principal en producción |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`cp` (BSD `cp`)** | POSIX.1-2008 / Nativo de BSD | Requiere `-p` (modo, propietario, tiempo) o `-a` (archive) | Manual (flag `-S` en `cp` de BSD) | No atómico a través de puntos de montaje | Alto para archivos individuales; moderado para árboles recursivos | Duplicación rápida de archivos, respaldos de configuración dentro del directorio local |
| **`mv` (BSD `mv`)** | POSIX.1-2008 / Nativo de BSD | Preservado implícitamente en el mismo montaje VFS | Preservado (entrada de inodo sin cambios) | **Atómico** en el mismo VFS; No atómico entre dispositivos (`EXDEV`) | Instantáneo (actualización de inodo) en el mismo VFS | Despliegues de versiones sin tiempo de inactividad, actualizaciones atómicas de configuración |
| **`pax`** | Intercambio de archivos portátil POSIX (POSIX Portable Archive Interchange) | Preservación completa (`-pe` preserva flags, modos, ACLs, tiempos) | Soporte nativo de sparse | No atómico (copia basada en flujo) | Superior para árboles de directorios masivos | Migración de datos estándar compatible con POSIX a través de sistemas BSD |
| **`tar` (bsdtar / libarchive)** | Estándar BSD (`libarchive`) | Preservación completa (`--acls`, `--xattrs`, `-p`) | Detección automática (flag `S` / `--sparse`) | No atómico (creación/extracción de archivos tar) | Alto rendimiento; maneja pipelines en flujo sobre la red | Extracción de rootfs de contenedores, archivos de respaldo del sistema |
| **`rsync`** | Utilidad no estándar | Preservación completa (`-aAXz`, `-H`) | Detección nativa de sparse (`-S`) | No atómico (transferencia delta a archivo temporal + intercambio) | Altamente optimizado (algoritmo de transferencia delta) | Replicación de estado multinodo, respaldos remotos |

---

### Tabla 2.2: Estrategias de actualización atómica

| Estrategia | Mecanismo técnico | Contención de cerrojos (Lock Contention) | ¿Seguro entre dispositivos (`EXDEV`)? | Garantía de seguridad ante caídas (Crash Safety) | Mejor utilizado para |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Copia con truncamiento (`cp src dst`)** | En el sitio `open(O_TRUNC)` + `write()` | Alta (los procesos leen datos parciales) | Sí | **Pobre** (archivo dejado truncado ante una caída) | Truncamiento de logs, actualizaciones en vivo donde el descriptor de archivo no puede cambiar |
| **Renombrado atómico (`mv -f tmp dst`)** | Invoca la llamada al sistema `rename(2)` | Cero (entrada de directorio VFS intercambiada) | **No** (falla con `EXDEV`) | **Excelente** (el archivo original permanece intacto hasta la confirmación VFS) | Lanzamientos de binarios de aplicaciones, actualizaciones de archivos de configuración |
| **Intercambio de enlaces simbólicos (`ln -sfn new current`)** | Actualización atómica del puntero de enlace simbólico | Cero | Sí | **Excelente** (enlace actualizado vía `symlink(2)` / puntero atómico) | Directorios de despliegue sin tiempo de inactividad (despliegues blue/green) |

---

### Tabla 2.3: Arquitectura de enlaces: Enlaces duros (Hard Links) vs. Enlaces suaves/simbólicos (Soft Links)

| Métrica / Característica | Enlace duro / Hard Link (`ln file link`) | Enlace suave / Simbólico (`ln -s file link`) |
| :--- | :--- | :--- |
| **Relación con el inodo de destino** | Apunta directamente al número de inodo existente | Ocupa un **nuevo inodo** que contiene la cadena de la ruta de destino |
| **Soporte entre sistemas de archivos** | **No** (limitado a un único sistema de archivos VFS) | **Sí** (puede apuntar a cualquier ruta en diferentes dispositivos) |
| **Soporte para directorios de destino** | **No** (restringido por el kernel para prevenir bucles) | **Sí** (puede enlazar directorios) |
| **Comportamiento al eliminar la fuente** | Los datos del archivo de destino persisten hasta que el conteo de enlaces cae a 0 | El enlace se rompe (se convierte en un enlace huérfano / colgante) |
| **Impacto en seguridad BSD / Jail** | No puede escapar del Jail si el archivo original reside dentro del Jail | Puede apuntar fuera de la raíz del Jail si la ruta de destino es absoluta |

---

## 3. Manifiestos completos de infraestructura y aprovisionamiento automatizado

### Manifiesto 3.1: Configuración de producción de FreeBSD Jail (`/etc/jail.conf.d/app_jail.conf`)

Esta configuración impone límites estrictos de almacenamiento, aislamiento de puntos de montaje, protección de solo lectura con nullfs y gestión de la estructura de staging para microservicios en contenedores.

```ini
# /etc/jail.conf.d/app_jail.conf
# Complete production FreeBSD Jail specification for secure file management isolation

# Global Jail Defaults
exec.start = "/bin/sh /etc/rc";
exec.stop = "/bin/sh /etc/rc.shutdown";
exec.clean;
mount.devfs;
devfs.ruleset = 4;

# Primary Application Jail
app_service {
    # System Host Integration
    host.hostname = "app-service.prod.internal";
    ip4.addr = 10.0.100.25;
    interface = "vnet0";
    
    # Path Specification & Mount Management
    path = "/usr/jails/app_service";
    
    # Storage Boundaries - Fstab containing nullfs and zfs mounts
    mount.fstab = "/usr/jails/configs/app_service.fstab";
    
    # Security Controls
    allow.raw_sockets = 0;
    allow.chflags = 0;
    securelevel = 2;
    
    # Jail Operational Tasks
    exec.prestart  = "/bin/mkdir -p /usr/jails/app_service/var/staging";
    exec.prestart += "/sbin/mount -t nullfs -o ro /usr/releases/app/current /usr/jails/app_service/usr/local/bin/app";
    exec.poststop  = "/sbin/umount -f /usr/jails/app_service/usr/local/bin/app || true";
    exec.poststop += "/bin/rm -rf /usr/jails/app_service/var/staging/*";
}
```

---

### Manifiesto 3.2: Pipeline de staging automatizado en producción y despliegue atómico (`/usr/local/bin/deploy_service.sh`)

Un script de pipeline completo en shell POSIX para entorno de producción que demuestra la gestión de archivos, validación de metadatos, detección de archivos dispersos y despliegue atómico de directorios.

```sh
#!/bin/sh
# /usr/local/bin/deploy_service.sh
# Production Deployment Pipeline with Atomic File Swapping and Flag Protection

set -eu

# Define Environment Paths
BASE_DIR="/var/db/deployments/app_service"
STAGING_DIR="${BASE_DIR}/staging"
RELEASES_DIR="${BASE_DIR}/releases"
CURRENT_SYMLINK="${BASE_DIR}/current"
RELEASE_ID=$(date +%Y%m%d_%H%M%S)
NEW_RELEASE_DIR="${RELEASES_DIR}/${RELEASE_ID}"
ARTIFACT_TARBALL="/tmp/artifacts/release_${RELEASE_ID}.tar.gz"

log_info() {
    printf "[INFO] %s: %s\n" "$(date +'%Y-%m-%dT%H:%M:%SZ')" "$1"
}

log_error() {
    printf "[ERROR] %s: %s\n" "$(date +'%Y-%m-%dT%H:%M:%SZ')" "$1" >&2
}

cleanup_staging() {
    log_info "Cleaning up staging directory..."
    if [ -d "${STAGING_DIR}" ]; then
        # Remove immutable flags if set during failed operations
        chflags -R noschg "${STAGING_DIR}" 2>/dev/null || true
        rm -rf "${STAGING_DIR}"
    fi
}

trap cleanup_staging EXIT INT TERM

# Step 1: Pre-Flight Environment Checks
log_info "Starting deployment sequence for release ${RELEASE_ID}"

if [ ! -f "${ARTIFACT_TARBALL}" ]; then
    log_error "Artifact tarball ${ARTIFACT_TARBALL} not found!"
    exit 1
fi

# Step 2: Create Staging and Target Release Directories
mkdir -p "${STAGING_DIR}" "${RELEASES_DIR}"

# Step 3: Extract Artifacts using BSD tar with Metadata Preservation
log_info "Extracting artifact to staging area..."
tar -xzpf "${ARTIFACT_TARBALL}" -C "${STAGING_DIR}"

# Step 4: Validate File Types and Binary Headers
log_info "Validating executable binaries..."
for binary in "${STAGING_DIR}/bin/"*; do
    if [ -f "${binary}" ]; then
        FILE_TYPE=$(file -b --mime-type "${binary}")
        if [ "${FILE_TYPE}" != "application/x-executable" ] && [ "${FILE_TYPE}" != "application/x-sharedlib" ]; then
            log_error "File ${binary} is not a valid executable binary! (Type: ${FILE_TYPE})"
            exit 1
        fi
    fi
done

# Step 5: Transfer Staging to Target Release via PAX (Preserving Attributes & Sparse Files)
log_info "Transferring staging structure to release directory ${NEW_RELEASE_DIR}..."
mkdir -p "${NEW_RELEASE_DIR}"
(cd "${STAGING_DIR}" && pax -rw -pe -v . "${NEW_RELEASE_DIR}")

# Step 6: Apply Security Flags to Application Binaries
log_info "Applying BSD System Immutable (schg) flags to binaries..."
chflags schg "${NEW_RELEASE_DIR}/bin/"* || log_info "Warning: Unable to set schg flag (securelevel constraint)"

# Step 7: Atomic Symlink Switchover
log_info "Performing atomic symlink release update..."
TMP_SYMLINK="${BASE_DIR}/current_tmp_${RELEASE_ID}"
ln -sfn "${NEW_RELEASE_DIR}" "${TMP_SYMLINK}"
mv -f "${TMP_SYMLINK}" "${CURRENT_SYMLINK}"

# Step 8: Purge Old Releases (Retention: Keep last 5 releases)
log_info "Purging old releases..."
cd "${RELEASES_DIR}"
ls -1t | tail -n +6 | while read -r old_release; do
    if [ -n "${old_release}" ]; then
        log_info "Removing old release: ${old_release}"
        chflags -R noschg "${old_release}" 2>/dev/null || true
        rm -rf "${old_release}"
    fi
done

log_info "Deployment of release ${RELEASE_ID} successfully completed."
exit 0
```

---

## 4. Comandos CLI reales y salidas de terminal

### Comando 1: Creación de estructuras de directorios complejas en producción con `mkdir`
Demuestra la creación de jerarquías de directorios anidados, la configuración de permisos de modo predeterminados y la inspección de propiedades de rutas absolutas.

```bash
$ mkdir -pv -m 0750 /var/db/app/{bin,config,data,logs,staging/temp}
```

```text
/var/db/app/bin
/var/db/app/config
/var/db/app/data
/var/db/app/logs
/var/db/app/staging
/var/db/app/staging/temp
```

---

### Comando 2: Inspección profunda de archivos con `ls` y `stat` de BSD
Muestra el listado de metadatos de archivos, incluyendo números de inodo, flags de BSD, modos de archivo POSIX, propiedad y tamaño de asignación.

```bash
$ ls -laoi /var/db/app/
```

```text
total 24
784121 drwxr-x---  7 appuser  appgroup  -        512 Aug 06 20:45 .
512002 drwxr-xr-x  4 root     wheel     -        512 Aug 06 20:40 ..
784122 drwxr-x---  2 appuser  appgroup  schg     512 Aug 06 20:45 bin
784123 drwxr-x---  2 appuser  appgroup  -        512 Aug 06 20:45 config
784124 drwxr-x---  2 appuser  appgroup  nodump   512 Aug 06 20:45 data
784125 drwxr-x---  2 appuser  appgroup  -        512 Aug 06 20:45 logs
784126 drwxr-x---  3 appuser  appgroup  -        512 Aug 06 20:45 staging
```

Salida de formato detallado con `stat` en BSD:

```bash
$ stat -f "File: %N | Inode: %i | Mode: %Sp (%Lp) | Owner: %Su:%Sg | Flags: %f | Size: %z bytes" /var/db/app/bin
```

```text
File: /var/db/app/bin | Inode: 784122 | Mode: drwxr-x--- (0750) | Owner: appuser:appgroup | Flags: schg | Size: 512 bytes
```

---

### Comando 3: Identificación precisa del tipo MIME utilizando `file`
Determina el contenido estructural interno de los archivos independientemente de su extensión.

```bash
$ file -b --mime-type /var/db/app/config/settings.json /var/db/app/bin/service_worker /var/db/app/logs/system.log
```

```text
application/json
application/x-executable
text/plain
```

Inspección de nodos de dispositivos de bloque y superbloques del sistema de archivos:

```bash
$ file -s /dev/ada0s1a
```

```text
/dev/ada0s1a: Unix Fast File system (FFS2) with dump dates, data blocks, cylinder groups, volume label , light application
```

---

### Comando 4: Copia recursiva con preservación de atributos usando `cp` de BSD
Ejecuta una copia recursiva preservando metadatos, controlando el recorrido de enlaces simbólicos (`-R` con `-P`) y forzando la preservación de archivos dispersos (`-S`).

```bash
$ cp -RPpS /var/db/app/staging/temp/ /var/db/app/data/
$ echo $?
```

```text
0
```

---

### Comando 5: Migración de directorios POSIX nativa con `pax`
Migra datos de estado dinámicos a un nuevo volumen de sistema de archivos mientras preserva flags, ACLs y estructuras de enlaces duros.

```bash
$ cd /var/db/app/data && pax -rw -pe -v -X . /mnt/backup_volume/data/
```

```text
.
./db_primary.sqlite
./db_primary.sqlite-wal
./sessions
./sessions/sess_982b1a
```

---

### Comando 6: Gestión de flags de archivos en BSD mediante `chflags`
Aplica y remueve la protección de inmutabilidad del sistema (`schg`) y de no eliminación por usuario (`sunlnk`).

```bash
$ touch /var/db/app/config/protected_core.cfg
$ sudo chflags schg,sunlnk /var/db/app/config/protected_core.cfg
$ rm -f /var/db/app/config/protected_core.cfg
```

```text
rm: /var/db/app/config/protected_core.cfg: Operation not permitted
```

Deshacer los flags para permitir el mantenimiento:

```bash
$ sudo chflags noschg,nosunlnk /var/db/app/config/protected_core.cfg
$ rm -fv /var/db/app/config/protected_core.cfg
```

```text
/var/db/app/config/protected_core.cfg
```

---

### Comando 7: Archivación y compresión eficiente con `tar` de BSD
Crea un archivo comprimido tarball compatible con archivos dispersos mientras preserva los atributos extendidos del sistema.

```bash
$ tar --format=pax --acls --xattrs -czvf /tmp/app_backup_$(date +%Y%m%d).tar.gz -C /var/db/app data config
```

```text
a data
a data/db_primary.sqlite
a data/db_primary.sqlite-wal
a data/sessions
a config
a config/settings.json
```

Verificación del contenido del archivo sin extracción:

```bash
$ tar -tvf /tmp/app_backup_20260806.tar.gz
```

```text
drwxr-x---  0 appuser appgroup       0 Aug 06 20:45 data
-rw-r-----  0 appuser appgroup 1048576 Aug 06 20:45 data/db_primary.sqlite
-rw-r-----  0 appuser appgroup   32768 Aug 06 20:45 data/db_primary.sqlite-wal
drwxr-x---  0 appuser appgroup       0 Aug 06 20:45 data/sessions
drwxr-x---  0 appuser appgroup       0 Aug 06 20:45 config
-rw-r-----  0 appuser appgroup    1240 Aug 06 20:45 config/settings.json
```

---

## 5. Verificación de fallas y guía de resolución de problemas (Troubleshooting)

### Matriz diagnóstica para fallas de alto impacto en producción

```
                    +-------------------------------------+
                    | File Management Operation Failure   |
                    +-------------------------------------+
                                       |
           +---------------------------+---------------------------+
           |                                                       |
[ Operation Not Permitted ]                              [ Cross-Device Link ]
           |                                                       |
   v       v       v                                               v
Inspect file flags:                                      Detect mount boundaries:
`ls -lo` or `stat -f %f`                                 `df -h <src> <dst>`
   |                                                       |
   +--> Contains `schg`/`uchg`?                            +--> Different filesystems?
   |    YES: `chflags noschg`                                   YES: Use `pax -rw` or 
   |                                                                 `cp -RPp` then `rm`.
   +--> Check Kernel Securelevel:
        `sysctl kern.securelevel`
        If >= 1: CANNOT clear `schg`.
        Fix: Reboot to single-user mode.
```

---

### Escenarios de resolución de problemas y protocolos de solución

#### Escenario A: `rm: filename: Operation not permitted` (Falla en la eliminación por superusuario)
* **Causa raíz:** El archivo posee el flag de inmutabilidad del sistema BSD (`schg`) o el flag de inmutabilidad de usuario (`uchg`). Ni siquiera `root` puede eliminar o truncar archivos marcados con `schg`.
* **Paso de diagnóstico:**
  ```bash
  $ ls -lO /var/log/security.audit
  -rw-------  1 root  wheel  schg 4096 Aug 06 18:00 /var/log/security.audit
  ```
  Comprobar el nivel de seguridad activo del kernel:
  ```bash
  $ sysctl kern.securelevel
  kern.securelevel: 1
  ```
* **Protocolo de solución:**
  1. Si `kern.securelevel` es `0` o `-1`:
     ```bash
     $ sudo chflags noschg /var/log/security.audit
     $ sudo rm -f /var/log/security.audit
     ```
  2. Si `kern.securelevel` es `>= 1`:
     La modificación de `schg` está bloqueada a nivel de kernel. Reinicie en modo monousuario (single-user mode) (`boot -s` en el prompt del loader) donde `securelevel` comienza en `-1`, modifique los flags mediante `chflags noschg` y complete la recuperación del sistema.

---

#### Escenario B: `mv: /tmp/app_staging to /var/db/app: Cross-device link (EXDEV)`
* **Causa raíz:** Intento de ejecutar un `rename(2)` atómico a través de diferentes puntos de montaje físicos o sistemas de archivos en memoria virtual (por ejemplo, `/tmp` en `tmpfs` y `/var` en `ZFS`).
* **Paso de diagnóstico:**
  ```bash
  $ df -Th /tmp/app_staging /var/db/app
  ```
  ```text
  Filesystem     Type    Size  Used Avail Capacity  Mounted on
  tmpfs          tmpfs   8.0G  512M  7.5G     6%    /tmp
  zroot/ROOT/default zfs 450G   45G  405G    10%    /
  ```
* **Protocolo de solución:**
  No utilice `mv` cuando se requiera atomicidad a través de puntos de montaje. Implemente directorios de staging dentro del espacio de nombres del sistema de archivos de destino (por ejemplo, `/var/db/app/.staging`):
  ```bash
  # Correct architectural workflow:
  $ mkdir -p /var/db/app/.staging
  $ pax -rw -pe /tmp/app_staging/ /var/db/app/.staging/
  $ mv -f /var/db/app/.staging /var/db/app/live_release
  ```

---

#### Escenario C: Agotamiento de espacio durante el respaldo de un disco virtual disperso (Sparse)
* **Causa raíz:** Una imagen de disco en formato raw que contiene 100GB de tamaño lógico con solo 5GB de datos escritos fue copiada sin tener en cuenta los archivos dispersos (sparse), expandiendo el uso físico a 100GB.
* **Paso de diagnóstico:**
  Comparar la longitud de archivo reportada frente a los bloques de disco asignados reales:
  ```bash
  $ ls -lh /virtual/images/vm_disk.raw
  -rw-r--r--  1 root  wheel   100G Aug 06 19:00 /virtual/images/vm_disk.raw
  
  $ du -h /virtual/images/vm_disk.raw
  5.0G    /virtual/images/vm_disk.raw
  ```
  Verificar la salida de la copia corrupta:
  ```bash
  $ du -h /backup/images/vm_disk_copy.raw
  100G    /backup/images/vm_disk_copy.raw
  ```
* **Protocolo de solución:**
  Utilice herramientas preparadas para archivos dispersos (`cp -S` en BSD o `cp --sparse=always` en herramientas GNU, o `tar -S`):
  ```bash
  $ cp -S /virtual/images/vm_disk.raw /backup/images/vm_disk_sparse.raw
  $ du -h /backup/images/vm_disk_sparse.raw
  5.0G    /backup/images/vm_disk_sparse.raw
  ```

---

#### Escenario D: Archivos desvinculados (Unlinked) consumiendo espacio en disco ("Ghost Storage")
* **Causa raíz:** Un archivo pesado de log o datos fue eliminado con `rm` mientras un proceso activo de la aplicación mantenía abierto un descriptor de archivo. El VFS desvincula la entrada de directorio, pero los bloques permanecen asignados hasta que se cierra el descriptor de archivo.
* **Paso de diagnóstico:**
  Comprobar la discrepancia de espacio en el sistema de archivos ZFS o UFS:
  ```bash
  $ df -h /var
  # Shows high consumption (e.g., 95% full)
  $ du -d 1 -h /var
  # Shows low sum of files (e.g., 10% used)
  ```
  Identificar el proceso que retiene los descriptores de archivos desvinculados utilizando `fstat` (nativo de BSD):
  ```bash
  $ sudo fstat /var | grep -i "N/A\|deleted"
  ```
  ```text
  appuser  app_daemon 84920   3* pipe 0xfffffe0045ab2100 <-> 0xfffffe0045ab2280
  appuser  app_daemon 84920    4 /var  3294812 -rw-r----- 10737418240 r
  ```
* **Protocolo de solución:**
  Reiniciar el demonio retenedor para liberar el descriptor de archivo:
  ```bash
  $ sudo service app_daemon restart
  ```
  Para prevenir futuras ocurrencias, trunque los logs activos mediante `copytruncate` o `cat /dev/null > /var/log/app.log` en lugar de ejecutar `rm` sobre archivos de log activos.

---

## 6. Referencias

* **Linux Professional Institute (LPI) Official BSD Specialist Overview:**  
  [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

* **LPI Wiki BSD Specialist Objectives V1.0 (Topic 715.2):**  
  [https://wiki.lpi.org/wiki/BSD_Specialist_Objectives_V1.0](https://wiki.lpi.org/wiki/BSD_Specialist_Objectives_V1.0)

* **FreeBSD Manual Pages - `cp(1)` File Copy Utility:**  
  [https://man.freebsd.org/cgi/man.cgi?query=cp&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=cp&sektion=1)

* **FreeBSD Manual Pages - `chflags(1)` System & User Flags:**  
  [https://man.freebsd.org/cgi/man.cgi?query=chflags&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=chflags&sektion=1)

* **FreeBSD Manual Pages - `pax(1)` Portable Archive Interchange:**  
  [https://man.freebsd.org/cgi/man.cgi?query=pax&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=pax&sektion=1)

* **FreeBSD Manual Pages - `stat(1)` File Status Display:**  
  [https://man.freebsd.org/cgi/man.cgi?query=stat&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=stat&sektion=1)

* **FreeBSD Manual Pages - `rename(2)` Atomic File Name System Call:**  
  [https://man.freebsd.org/cgi/man.cgi?query=rename&sektion=2](https://man.freebsd.org/cgi/man.cgi?query=rename&sektion=2)