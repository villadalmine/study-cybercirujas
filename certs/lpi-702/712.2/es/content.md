# Topic 712.2: Create File Systems and Maintain Their Integrity

**Certification:** LPI BSD Specialist (Exam 702-100, Version 1.0)  
**Topic Weight:** 1.67  

---

## 1. Motivación de la arquitectura de producción y planteamiento del problema

En entornos BSD de producción empresarial —que van desde dispositivos de almacenamiento de alto rendimiento y servidores de bases de datos hasta hipervisores de borde (*edge hypervisors*)— la arquitectura del sistema de archivos dicta directamente la disponibilidad del sistema, el rendimiento de E/S, la integridad de los datos y los límites de los SLA de recuperación ante desastres. 

Los ingenieros de sistemas y los Site Reliability Engineers (SREs) enfrentan dos paradigmas principales de almacenamiento en sistemas FreeBSD/BSD:

1. **UFS2 (Unix File System 2):** Un sistema de archivos tradicional basado en bloques caracterizado por diseños estructurales fijos (Cylinder Groups, Superblocks, tablas de Inodes). Aunque es altamente eficiente para sistemas de archivos raíz ligeros, sistemas embebidos o cargas de trabajo con un gasto de memoria bajo y determinista, UFS2 históricamente sufría de largos tiempos de recuperación tras caídas (`fsck`) y cuellos de botella en la actualización de metadatos durante apagados no limpios. El UFS2 moderno mitiga esto utilizando **Soft Updates (SU)** y **Soft Updates with Journaling (SU+J)**.
2. **OpenZFS (Zettabyte File System):** Un motor de almacenamiento transaccional avanzado del tipo Copy-on-Write (CoW) que unifica la gestión de volúmenes y las capas del sistema de archivos. OpenZFS proporciona verificación de integridad de datos de extremo a extremo mediante checksumming, capacidades de auto-recuperación (*self-healing*), snapshotting dinámico, compresión en línea y topología de pool escalable (vdevs). Sin embargo, ZFS requiere un ajuste cuidadoso del ARC (Adaptive Replacement Cache), planificación de asignación de memoria (típicamente requiriendo 1GB de RAM por TB de almacenamiento como regla general para uso estándar, superior para deduplicación) y una estricta disciplina de expansión de vdevs.

### Escenario de problema en producción
Una infraestructura de plataforma empresarial requiere operaciones sin tiempo de inactividad para un clúster de bases de datos y una capa de aplicaciones web multitenant. Los reinicios no limpios del host (por ejemplo, kernel panics o cortes de energía) en volúmenes UFS2 sin journaling activan escaneos síncronos en primer plano de `fsck` durante el arranque, causando ventanas de inactividad de más de 45 minutos en discos de múltiples terabytes. Por el contrario, los pools de ZFS mal configurados que carecen de vdevs de registros dedicados (SLOG) o que se quedan sin capacidad de pool asignable (>85% de saturación del pool) sufren picos severos de latencia de escritura y estructuras de asignación fragmentadas.

Los SREs deben dominar ambos paradigmas de almacenamiento: personalizando los diseños estructurales de UFS2 y sus parámetros de ajuste (`newfs`, `tunefs`), imponiendo el mantenimiento de la integridad (`fsck_ffs`), diseñando pools de almacenamiento de OpenZFS resilientes (`zpool`), aplicando la gobernanza de datasets (`zfs`) y orquestando rutinas proactivas de verificación de integridad (`zpool scrub`).

---

## 2. Análisis técnico profundo y análisis comparativo de compensaciones (trade-offs)

### 2.1 Comparación arquitectónica: UFS2 vs. OpenZFS

| Característica arquitectónica | UFS2 (Unix File System v2) | OpenZFS (Zettabyte File System) |
| :--- | :--- | :--- |
| **Modelo de asignación** | Asignación de bloques estática (Cylinder Groups, bloques directos/indirectos) | Asignación transaccional Copy-on-Write (CoW) |
| **Capas de volumen** | Requiere el framework GEOM (`gpart`, `gmirror`, `gvinum`) para la gestión de volúmenes | Gestor de volúmenes lógicos y motor de sistema de archivos integrado |
| **Verificación de integridad** | Flags de estado del Superblock, comprobaciones estructurales lineales de `fsck_ffs` manuales/en tiempo de arranque | Checksums continuos de bloques de 256 bits (Fletcher4 / SHA256 / BLAKE3), `zpool scrub` en segundo plano |
| **Protección de metadatos** | Soft Updates (ordenamiento de dependencias) o Soft Updates + Journaling (SU+J) | Grupos de transacciones (TXGs), ZFS Intent Log (ZIL / SLOG) |
| **Crecimiento y redimensionamiento** | Diseño estructural destructivo; crecimiento en línea soportado vía `growfs` | Adición dinámica de vdev; expansión en línea sin interrupciones |
| **Huella de memoria** | Extremadamente baja (requerimiento de caché de buffer del kernel < 64MB) | Alta (ARC se configura por defecto hasta el 50%–90% de la RAM física; configurable vía sysctl) |
| **Optimización para SSD** | TRIM habilitado vía `tunefs -t` | Autotrim vía `zpool set autotrim=on`, almacenamiento en caché L2ARC |

### 2.2 Mecanismos de consistencia de metadatos en UFS2: Soft Updates (SU) vs. SU+J

* **Soft Updates (SU):** Rastrea y ordena las dependencias de metadatos en memoria para garantizar que las estructuras en disco nunca queden en un estado inconsistente (por ejemplo, un inode apuntando a un bloque no asignado). Elimina las escrituras síncronas de metadatos.
  * *Compensación (Trade-off):* Los apagados no limpios dejan bloques/inodes huérfanos que no amenazan la estabilidad estructural, pero requieren un `fsck` en segundo plano para recuperar el espacio libre perdido.
* **Soft Updates with Journaling (SU+J):** Introduce un registro de intención (*intent log*) para las actualizaciones de metadatos directamente dentro del espacio de asignación del sistema de archivos UFS2.
  * *Compensación (Trade-off):* Reduce los tiempos de recuperación en el arranque de decenas de minutos a segundos reproduciendo el registro de intención. Sin embargo, requiere una pequeña sobrecarga continua de escritura y no se puede combinar con solo SU en ciertos proveedores GEOM heredados.

---

## 3. Configuraciones de infraestructura y manifiestos de sistemas de archivos sintácticamente completos

### 3.1 Manifiesto de `/etc/fstab` en producción
El siguiente `/etc/fstab` demuestra configuraciones de montaje de producción en particiones UFS2, espacios de swap, sistemas de archivos de procesos y montajes NFS/tmpfs en FreeBSD 14.x.

```ini
# Device                Mountpoint      FStype      Options                             Dump    Pass
# --------------------------------------------------------------------------------------------------
# Root Filesystem (UFS2 with Soft Updates + Journaling, TRIM enabled)
/dev/gpt/rootfs         /               ufs         rw,noatime                          1       1

# Dedicated User/Var Partitions (UFS2)
/dev/gpt/varfs          /var            ufs         rw,noatime                          2       2

# Temporary volatile storage using tmpfs (prevents wear on solid-state drives)
tmpfs                   /tmp            tmpfs       rw,mode=1777,nosuid,size=4G        0       0

# Process File System (Required for legacy metrics & container runtimes)
proc                    /proc           procfs      rw                                  0       0

# Network Attached Backup Mount (NFSv4)
10.0.100.50:/exports/bkp /mnt/backups   nfs         rw,nfsv4,late,soft,intr,retrycnt=3 0       0

# Dump/Swap Device with Encryption (GEOM GELI managed dynamically, excluded from fstab direct ufs)
/dev/gpt/swap0.eli      none            swap        sw                                  0       0
```

---

### 3.2 Manifiesto del sistema de archivos del sistema `/etc/rc.conf` en producción
Garantiza que los subsistemas ZFS, los servicios de comprobación en segundo plano y la funcionalidad TRIM se inicien automáticamente de forma correcta durante el arranque.

```sh
# Enable OpenZFS Core Services
zfs_enable="YES"

# Automatic Background File System Checking Strategy
background_fsck="YES"
fsck_y_enable="YES"

# GEOM Subsystem Settings
geom_eli_enable="YES"

# Crash Dump & Core Dumps Management
dumpdev="/dev/gpt/swap0.eli"
dumpdir="/var/crash"
```

---

### 3.3 Manifiesto de ajuste de producción: `/etc/periodic.conf`
Configura el mantenimiento automatizado, la supervisión y los intervalos de scrub para la integridad del sistema de archivos.

```sh
# Daily System Maintenance File System Checks
daily_clean_tmps_enable="YES"
daily_clean_tmps_days="3"

# Weekly File System Status & Security Verification
weekly_status_zfs_enable="YES"

# Monthly Scrub Strategy Configuration (Managed via custom periodic script or zfs daemon)
monthly_zfs_scrub_enable="YES"
monthly_zfs_scrub_pools="zroot tank"
```

---

## 4. Flujos de trabajo ejecutables de CLI con salidas de terminal reales

### 4.1 Creación, modificación de parámetros y ajuste de UFS2

#### Paso 1: Crear un sistema de archivos UFS2 con tamaños personalizados de bloques/fragmentos, TRIM y SU+J
Construimos un sistema de archivos UFS2 en la partición `/dev/da1p1` especificando:
- `-O2`: Formato UFS2.
- `-b 32768`: Tamaño de bloque de 32 KB.
- `-f 4096`: Tamaño de fragmento de 4 KB.
- `-U`: Habilitar Soft Updates.
- `-j`: Habilitar Soft Updates with Journaling.
- `-t`: Habilitar TRIM.
- `-m 5`: Reservar un 5% de espacio libre mínimo (*minfree*) para `root`.

```console
# newfs -O2 -b 32768 -f 4096 -U -j -t -m 5 -L appdata /dev/da1p1
/dev/da1p1: 102400.0MB (209715200 sectors) block size 32768, fragment size 4096
        using 163 cylinder groups of 628.31MB, 20106 blocks, 80640 inodes.
        with Soft Updates with Journaling (-j)
super-block backups (for fsck_ffs -b #) at:
 160, 1286944, 2573728, 3860512, 5147300, 6434088, 7720876, 9007664, 10294452,
 11581240, 12868028, 14154816, 15441604, 16728392, 18015180, 19301968, 20588756
```

#### Paso 2: Inspeccionar y ajustar los parámetros de tiempo de ejecución de UFS2 a través de `tunefs`

```console
# tunefs -p /dev/da1p1
tunefs: POSIX.1e ACLs: (-a)                                disabled
tunefs: NFSv4 ACLs: (-N)                                  disabled
tunefs: MAC multi-label: (-l)                             disabled
tunefs: soft updates: (-n)                                enabled
tunefs: soft updates journaling: (-j)                     enabled
tunefs: gjournal: (-J)                                    disabled
tunefs: trim: (-t)                                        enabled
tunefs: maximum contiguous soft-update blocks: (-e)       2560
tunefs: rotational delay between contiguous blocks: (-d)  0 ms
tunefs: maximum blocks per file in a cylinder group: (-m) 5%
tunefs: optimization preference: (-o)                     time
tunefs: volume label: (-L)                                appdata
```

#### Paso 3: Modificar el modo de optimización a espacio y ajustar el espacio reservado para inodes

```console
# tunefs -o space -m 2 /dev/da1p1
tunefs: optimization preference changed from time to space
tunefs: minimum percentage of free space changed from 5% to 2%
```

---

### 4.2 Verificación y reparación de integridad en UFS2 (`fsck_ffs`)

#### Paso 1: Ejecutar la comprobación de integridad rápida (Preen) en un volumen desmontado

```console
# fsck_ffs -p /dev/da1p1
/dev/da1p1: FILE SYSTEM CLEAN; SKIPPING CHECKS
/dev/da1p1: clean, 11 blocks, 1Link, 1 files, 0 directories
```

#### Paso 2: Forzar un escaneo estructural completo no interactivo utilizando un Superblock alternativo
Cuando el superblock principal se corrompe (por ejemplo, por degradación del hardware), forzamos una comprobación utilizando el superblock alternativo en la ubicación `160` (descubierta durante `newfs`).

```console
# fsck_ffs -f -b 160 -y /dev/da1p1
Alternate super block location: 160
** Last Mounted on 
** Phase 1 - Check Blocks and Sizes
** Phase 2 - Check Pathnames
** Phase 3 - Check Connectivity
** Phase 4 - Check Reference Counts
** Phase 5 - Check Cyl groups
80640 files, 154201 blocks used, 26060159 free (15 frags, 3257518 blocks)

***** FILE SYSTEM MARKED CLEAN *****
```

---

### 4.3 Arquitectura y administración de almacenamiento de pools de OpenZFS (`zpool`)

#### Paso 1: Crear un pool de almacenamiento ZFS empresarial (`zpool`)
Construimos un pool resiliente llamado `tank` utilizando un diseño en espejo (Mirrored), un dispositivo SLOG (ZFS Intent Log) dedicado en NVMe, una caché de lectura (L2ARC) y un Hot Spare.

* **Data Mirror:** `da2`, `da3`
* **SLOG (Log):** `nvd0p1`
* **Cache (L2ARC):** `nvd0p2`
* **Spare:** `da4`

```console
# zpool create -f -o ashift=12 tank mirror da2 da3 log nvd0p1 cache nvd0p2 spare da4
```

#### Paso 2: Consultar la topología del pool ZFS y su estado operativo

```console
# zpool status tank
  pool: tank
 state: ONLINE
  scan: none requested
config:

	NAME        STATE     READ WRITE CKSUM
	tank        ONLINE       0     0     0
	  mirror-0  ONLINE       0     0     0
	    da2     ONLINE       0     0     0
	    da3     ONLINE       0     0     0
	logs	
	  nvd0p1    ONLINE       0     0     0
	cache	
	  nvd0p2    ONLINE       0     0     0
	spares	
	  da4       AVAIL

errors: No known data errors
```

---

### 4.4 Gestión de datasets ZFS, cuotas y aplicación de propiedades

#### Paso 1: Crear la jerarquía de datasets de producción

```console
# zfs create tank/db
# zfs create tank/db/pgdata
# zfs create tank/apps
# zfs create tank/apps/logs
```

#### Paso 2: Aplicar la gobernanza de datasets de producción (propiedades, cuotas, compresión, puntos de montaje)

```console
# zfs set compression=zstd tank/db/pgdata
# zfs set atime=off tank/db/pgdata
# zfs set recordsize=16k tank/db/pgdata
# zfs set quota=500G tank/db/pgdata
# zfs set reservation=100G tank/db/pgdata
# zfs set mountpoint=/var/db/postgres tank/db/pgdata

# zfs set compression=gzip-6 tank/apps/logs
# zfs set exec=off tank/apps/logs
# zfs set setuid=off tank/apps/logs
# zfs set quota=50G tank/apps/logs
```

#### Paso 3: Verificar las propiedades de dataset aplicadas

```console
# zfs list -o name,quota,reservation,compress,atime,mountpoint -r tank
NAME              QUOTA  RESV  COMPRESS  ATIME  MOUNTPOINT
tank               none  none       off     on  /tank
tank/apps          none  none       off     on  /tank/apps
tank/apps/logs      50G  none    gzip-6    off  /tank/apps/logs
tank/db            none  none       off     on  /tank/db
tank/db/pgdata     500G  100G      zstd    off  /var/db/postgres
```

---

### 4.5 Mantenimiento y supervisión de integridad en ZFS (`zpool scrub`)

#### Paso 1: Iniciar el flujo de trabajo de depuración de datos (scrubbing) en segundo plano

```console
# zpool scrub tank
```

#### Paso 2: Supervisar el progreso del scrub y los resultados de auto-recuperación (self-healing)

```console
# zpool status tank
  pool: tank
 state: ONLINE
  scan: scrub in progress since Thu Aug  6 20:45:10 2026
	18.45G scanned at 1.20G/s, 2.10G issued at 140M/s, 45.2G total
	0B repaired, 4.65% done, 00:05:12 to go
config:

	NAME        STATE     READ WRITE CKSUM
	tank        ONLINE       0     0     0
	  mirror-0  ONLINE       0     0     0
	    da2     ONLINE       0     0     0
	    da3     ONLINE       0     0     0
	logs	
	  nvd0p1    ONLINE       0     0     0
	cache	
	  nvd0p2    ONLINE       0     0     0
	spares	
	  da4       AVAIL

errors: No known data errors
```

---

## 5. Guía de verificación y resolución de problemas (troubleshooting)

### 5.1 Resolución de fallas de integridad en UFS2

```
                    +-------------------------------------+
                    | Unclean Shutdown or GEOM I/O Error  |
                    +-------------------------------------+
                                       |
                                       v
                    +-------------------------------------+
                    | Boot Failure / Soft Updates Panic   |
                    +-------------------------------------+
                                       |
                                       v
                    +-------------------------------------+
                    | Boot Single-User Mode:              |
                    | # fsck_ffs -p /dev/da1p1            |
                    +-------------------------------------+
                                       |
                    +------------------+------------------+
                    |                                     |
           [ Clean Execution ]                   [ Superblock Corrupted ]
                    |                                     |
                    v                                     v
     +-----------------------------+       +-----------------------------+
     | Mount Read-Write & Resume:  |       | Locate Alternate Superblocks|
     | # mount -uw /               |       | # newfs -N /dev/da1p1       |
     +-----------------------------+       +-----------------------------+
                                                          |
                                                          v
                                           +-----------------------------+
                                           | Force Alternate Repair:     |
                                           | # fsck_ffs -b 160 -y /dev...|
                                           +-----------------------------+
```

#### Escenarios de diagnóstico comunes y remediación

##### Escenario A: Corrupción del Superblock en UFS2
* **Síntoma:** El proceso de arranque se aborta con: `fsck: /dev/da1p1: BAD SUPER BLOCK: MAGIC NUMBER WRONG`.
* **Causa raíz:** Degradación del offset del sector de bloques 0/1 en la partición donde reside el superblock principal.
* **Ruta de resolución:**
  1. Recuperar los superblocks de respaldo sin sobrescribir datos utilizando `newfs -N /dev/da1p1`.
  2. Ejecutar `fsck_ffs` apuntando a un superblock alternativo verificado (por ejemplo, `160` o `1286944`):
     ```console
     # fsck_ffs -b 1286944 -y /dev/da1p1
     ```

##### Escenario B: Inconsistencia del Journal de Soft Updates (Pánico de SU+J)
* **Síntoma:** El kernel entra en pánico durante el arranque en `ffs_valloc: lost block` o `SU+J journal check failed`.
* **Causa raíz:** El buffer de escritura del journal no sincronizó con el hardware de almacenamiento antes de la pérdida total de energía.
* **Ruta de resolución:**
  1. Arrancar en modo de usuario único (Single-User mode).
  2. Deshabilitar temporalmente Soft Updates Journaling para limpiar el log:
     ```console
     # tunefs -j disable /dev/da1p1
     ```
  3. Ejecutar un escaneo exhaustivo de `fsck_ffs` sin journaling:
     ```console
     # fsck_ffs -f -y /dev/da1p1
     ```
  4. Volver a habilitar Soft Updates Journaling:
     ```console
     # tunefs -j enable /dev/da1p1
     ```

---

### 5.2 Resolución de fallas y degradación de pools en OpenZFS

#### Escenario A: Degradación de vdev o acumulación de fallas de Checksum
* **Síntoma:** `zpool status` informa el estado `DEGRADED` con un conteo elevado de `CKSUM` en el disco miembro `da2`.
* **Causa raíz:** Falla física del cable SATA/SAS, reinicio transitorio del bus o sectores físicos defectuosos en el disco.

```console
# zpool status tank
  pool: tank
 state: DEGRADED
status: One or more devices has experienced an unrecoverable error. An
	attempt was made to correct the error. Applications are unaffected.
action: Determine if the device needs to be replaced using 'zpool status -v'.
   see: https://openzfs.github.io/openzfs-docs/msg/ZFS-8000-9P
config:

	NAME        STATE     READ WRITE CKSUM
	tank        DEGRADED     0     0     0
	  mirror-0  DEGRADED     0     0     0
	    da2     FAULTED     14    250  1.2K  too many errors
	    da3     ONLINE       0     0     0
```

* **Ruta de resolución:**
  1. Confirmar la ubicación de la falla mediante el buffer circular del kernel (`dmesg -a | grep da2` o `/var/log/messages`).
  2. Poner fuera de línea (*offline*) el vdev con fallas si aún responde parcialmente:
     ```console
     # zpool offline tank da2
     ```
  3. Reemplazar físicamente el dispositivo fallado (o el objetivo de partición).
  4. Ejecutar el comando de reemplazo del pool para iniciar el proceso automático de resilverizado (*resilver*):
     ```console
     # zpool replace tank da2 da4
     ```
  5. Limpiar los contadores de fallas acumulados:
     ```console
     # zpool clear tank
     ```

#### Escenario B: Falla por falta de espacio en el pool (bloqueo por saturación del 100%)
* **Síntoma:** Todas las operaciones de escritura en los datasets de ZFS fallan con `No space left on device` (ENOSPC). `zfs destroy` falla porque CoW requiere espacio para asignar el estado de la transacción de eliminación.
* **Causa raíz:** La capacidad del pool alcanzó el 100% de saturación. Las semánticas de Copy-on-Write requieren bloques libres para escribir cambios de estado en los bloques de datos.
* **Ruta de resolución:**
  1. Agregar un vdev temporal basado en archivo o un vdev físico de emergencia al pool para romper el bloqueo (*deadlock*) de transacciones:
     ```console
     # truncate -s 10G /var/tmp/rescue.img
     # zpool add tank /var/tmp/rescue.img
     ```
  2. Destruir snapshots redundantes o archivos grandes innecesarios para liberar espacio:
     ```console
     # zfs destroy tank/apps/logs@old_snapshot
     ```
  3. Desacoplar (*detach*) o remover el vdev de rescate temporal:
     ```console
     # zpool remove tank /var/tmp/rescue.img
     # rm /var/tmp/rescue.img
     ```

---

## 6. Referencias

* **Linux Professional Institute (LPI) BSD Specialist Overview:**  
  [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
* **FreeBSD Detailed Objectives (702-100 Topic 712.2):**  
  [https://wiki.lpi.org/wiki/BSD_Specialist_Objectives_V1](https://wiki.lpi.org/wiki/BSD_Specialist_Objectives_V1)
* **FreeBSD Handbook - The Unix File System (UFS):**  
  [https://docs.freebsd.org/en/books/handbook/filesystems/#filesystems-ufs](https://docs.freebsd.org/en/books/handbook/filesystems/#filesystems-ufs)
* **FreeBSD Handbook - The Z File System (ZFS):**  
  [https://docs.freebsd.org/en/books/handbook/zfs/](https://docs.freebsd.org/en/books/handbook/zfs/)
* **FreeBSD Manual Pages - `newfs(8)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=newfs&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=newfs&sektion=8)
* **FreeBSD Manual Pages - `tunefs(8)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=tunefs&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=tunefs&sektion=8)
* **FreeBSD Manual Pages - `fsck_ffs(8)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=fsck_ffs&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=fsck_ffs&sektion=8)
* **FreeBSD Manual Pages - `zpool(8)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=zpool&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=zpool&sektion=8)
* **FreeBSD Manual Pages - `zfs(8)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=zfs&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=zfs&sektion=8)
* **OpenZFS Official Documentation:**  
  [https://openzfs.github.io/openzfs-docs/](https://openzfs.github.io/openzfs-docs/)