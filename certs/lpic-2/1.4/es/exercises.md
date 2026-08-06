# Guía de Estudio para la Certificación LPIC-2 — Tema 1.4: Filesystem and Devices

**Alcance del examen:** LPIC-2 (Examen 201-450 y Examen 202-450, Versión 4.5)  
**Código del tema:** 201.4 Filesystem and Devices  
**Peso:** 7  
**Objetivos de referencia oficiales:** [Linux Professional Institute (LPI) LPIC-2 Overview](https://www.lpi.org/our-certifications/lpic-2-overview/)

---

## Documentación de referencia arquitectónica
* **Kernel Storage & Filesystem Documentation:** [https://www.kernel.org/doc/html/latest/filesystems/index.html](https://www.kernel.org/doc/html/latest/filesystems/index.html)
* **systemd Mount & Automount Units:** [https://www.freedesktop.org/software/systemd/man/latest/systemd.mount.html](https://www.freedesktop.org/software/systemd/man/latest/systemd.mount.html)
* **Btrfs Documentation & Mechanics:** [https://btrfs.readthedocs.io/en/latest/](https://btrfs.readthedocs.io/en/latest/)
* **Linux udev Rule Architecture:** [https://www.kernel.org/doc/html/latest/admin-guide/abi-testing.html#sys-class-block](https://www.kernel.org/doc/html/latest/admin-guide/abi-testing.html#sys-class-block)
* **dm-crypt / LUKS2 Specification:** [https://gitlab.com/cryptsetup/cryptsetup/-/wikis/LUKS-standard](https://gitlab.com/cryptsetup/cryptsetup/-/wikis/LUKS-standard)

---

## Ejercicio 1: Ajuste avanzado de archivos de sistema Ext4 y XFS, inspección de metadatos y reparación en línea

### Escenario
Como SRE Senior, debés optimizar `/dev/sdb1` (Ext4) para una carga de trabajo OLTP transaccional de alta concurrencia y `/dev/sdc1` (XFS) para un repositorio de logs analíticos de archivos grandes. Inspeccionarás las estructuras internas de asignación de bloques, ajustarás flags operacionales y ejecutarás secuencias de diagnóstico y reparación no destructivas.

---

### Paso 1.1: Inspección del Superblock y del Descriptor de Block Group en Ext4

Ejecutá `dumpe2fs` para inspeccionar los metadatos del superblock, la relación de inodes, los agrupamientos flex_bg y las características activas del filesystem:

```bash
sudo dumpe2fs -h /dev/sdb1
```

**Salida de terminal esperada:**
```text
dumpe2fs 1.46.5 (30-Dec-2021)
Filesystem volume name:   DB_STORAGE
Filesystem magic number:  0xEF53
Filesystem state:         clean
Errors behavior:          Continue
Filesystem OS type:       Linux
Inode count:              13107200
Block count:              52428800
Reserved block count:     2621440
Free blocks:              48123901
Free inodes:              13107100
First block:              0
Block size:               4096
Fragment size:            4096
Group descriptor size:    64
Blocks per group:         32768
Inodes per group:         8192
Flex_bg size:             16
Filesystem features:      has_journal ext_attr resize_inode dir_index filetype extent 64bit flex_bg sparse_super large_file huge_file dir_nlink extra_isize metadata_csum
Default mount options:    user_xattr acl
Filesystem created:       Wed Jan 14 08:30:00 2026
Last mount time:          Thu Aug  6 09:12:44 2026
Last write time:          Thu Aug  6 09:12:44 2026
Mount count:              14
Maximum mount count:      -1
Last checked:             Wed Jan 14 08:30:00 2026
Check interval:           0 (<none>)
Lifetime write:           184 GB
Reserved blocks uid:      0 (user root)
Reserved blocks gid:      0 (group root)
First inode:              11
Inode size:               256
Required extra isize:     32
Desired extra isize:      32
Journal inode:            8
Default directory hash:   half_md4
Journal backup:           inode blocks
Journal features:         journal_incompat_revoke journal_64bit journal_checksum_v3
Journal size:             1024M
Journal length:           262144
Journal sequence:         0x0001a42b
Journal start:            1
```

---

### Paso 1.2: Ajuste fino de Ext4 para cargas de trabajo OLTP de alto IOPS

Configurá `/dev/sdb1` para reducir los bloques reservados del 5% al 2% (recuperando espacio en NVMe empresarial), forzar el journaling en modo writeback para obtener el máximo rendimiento, habilitar Multi-Mount Protection (MMP) para prevenir el doble montaje en entornos SAN, y actualizar los conteos de montaje:

```bash
# Reduce reserved block allocation for superuser to 2%
sudo tune2fs -m 2 /dev/sdb1

# Enable Multi-Mount Protection (MMP)
sudo tune2fs -O mmp /dev/sdb1

# Set filesystem check triggers to 50 mounts or 60 days
sudo tune2fs -c 50 -i 60d /dev/sdb1

# Verify new configuration flags
sudo tune2fs -l /dev/sdb1 | grep -E "Reserved block count|Filesystem features|Maximum mount count|Check interval"
```

**Salida de terminal esperada:**
```text
Reserved block count:     1048576
Filesystem features:      has_journal ext_attr resize_inode dir_index filetype extent 64bit flex_bg sparse_super large_file huge_file dir_nlink extra_isize metadata_csum mmp
Maximum mount count:      50
Check interval:           5184000 (60 days)
```

---

### Paso 1.3: Inspección estructural de metadatos XFS y análisis de Allocation Group

Inspeccioná el filesystem XFS en `/dev/sdc1` usando `xfs_info`, analizá la geometría de allocation group (AG) y consultá los metadatos del superblock usando `xfs_db`:

```bash
# Display detailed XFS geometry
sudo xfs_info /mnt/xfsdata
```

**Salida de terminal esperada:**
```text
meta-data=/dev/sdc1              isize=512    agcount=16, agsize=3276800 blks
         =                       sectsz=4096  attr=2, projid32bit=1
         =                       crc=1        finobt=1, rmapbt=0, reflink=1
data     =                       bsize=4096   blocks=52428800, imaxpct=25
         =                       sunit=0      swidth=0 blks
naming   =version 2              bsize=4096   ascii-ci=0, ftype=1
log      =internal log           bsize=4096   blocks=256000, version=2
         =                       sectsz=4096  sunit=1 blks, lazy-count=1
realtime =none                   extsz=4096   blocks=0, rtextents=0
```

Abrí `xfs_db` en modo de solo lectura para imprimir los metadatos del superblock del Allocation Group 0 (AG 0):

```bash
sudo xfs_db -r -c "sb 0" -c "p" /dev/sdc1 | head -n 20
```

**Salida de terminal esperada:**
```text
magicnum = 0x58465342
blocksize = 4096
dblocks = 52428800
rblocks = 0
rextents = 0
uuid = 8f4e21a9-7c3d-4e9b-b210-99812f00a34b
logstart = 262148
rootino = 128
rsumino = 0
rbmino = 0
rextsize = 1
agblocks = 3276800
agcount = 16
rbmblocks = 0
logblocks = 256000
versionnum = 0xb4b5
sectsize = 4096
inodesize = 512
inopblock = 8
icount = 64
```

---

### Paso 1.4: Realización de reparaciones en modo simulación (Dry-Run) en Ext4 y XFS

Ejecutá comandos de diagnóstico y reparación no destructivos en ambos filesystems para verificar las estructuras de bloques sin modificar los bloques del disco:

```bash
# Ext4 dry-run check
sudo fsck.ext4 -fn /dev/sdb1

# XFS dry-run check (must be performed unmounted)
sudo umount /mnt/xfsdata 2>/dev/null || true
sudo xfs_repair -n /dev/sdc1
```

**Salida de terminal esperada:**
```text
e2fsck 1.46.5 (30-Dec-2021)
Pass 1: Checking inodes, blocks, and sizes
Pass 2: Checking directory structure
Pass 3: Checking directory connectivity
Pass 4: Checking reference counts
Pass 5: Checking group summary information
DB_STORAGE: 11/13107200 files (0.0% non-contiguous), 4304899/52428800 blocks

Phase 1 - find agheaders...
Phase 2 - verify agheaders...
Phase 3 - process agfl blocks and inobt roots...
Phase 4 - check inode counters...
Phase 5 - check agalloc structures...
Phase 6 - check inode connectivity...
Phase 7 - verify and correct link counts...
No modify flag set, skipping filesystem flush.
Done.
```

---

### Preguntas de comprensión: Ejercicio 1

1.1. ¿Cuál es el rol mecánico exacto de Ext4 Multi-Mount Protection (MMP) y cómo previene la corrupción del filesystem en entornos de almacenamiento de bloques compartidos en SAN o Alta Disponibilidad (HA)?  
1.2. En la arquitectura XFS, ¿por qué la escalabilidad de escritura concurrente depende fuertemente de la cantidad de Allocation Groups (`agcount`), y qué compensación de rendimiento ocurre si `agcount` se configura excesivamente alto en relación con la profundidad de cola del almacenamiento?  
1.3. Explicá por qué ejecutar `xfs_repair -n` en un filesystem desmontado con un journal sucio y no confirmado hace que la herramienta aborte, y indicá los flags exactos de la CLI requeridos para manejar esta situación de forma segura.

---

## Ejercicio 2: Subvolumes, Snapshots, mecánica Copy-on-Write (CoW) y Quota Groups en Btrfs

### Escenario
Estás diseñando una arquitectura de despliegue de respaldos inmutables utilizando pools de almacenamiento multidispositivo Btrfs. Necesitás configurar subvolumes optimizados para bases de datos PostgreSQL, aplicar límites de almacenamiento usando Quota Groups (`qgroups`) y ejecutar streaming de respaldos incrementales a través de snapshots de subvolumes.

---

### Paso 2.1: Formateo de pools multidispositivo Btrfs y creación de subvolumes

Inicializá un pool Btrfs multidispositivo usando `/dev/sdd1` y `/dev/sde1` con metadatos en espejo (RAID1) y datos en franjas (RAID0):

```bash
sudo mkfs.btrfs -f -L "BTRFS_PROD_POOL" -m raid1 -d raid0 /dev/sdd1 /dev/sde1
```

**Salida de terminal esperada:**
```text
btrfs-progs v5.16.2 
See http://btrfs.wiki.kernel.org for more information.

Label:              BTRFS_PROD_POOL
UUID:               c6f89012-3a4b-5c6d-7e8f-9012345678ab
Node size:          16384
Sector size:        4096
Filesystem size:    100.00GiB
Block group head:   2176
64Bit (#254):       1
Incompat features:  EXTENDED_IREF, SKINNY_METADATA, NO_HOLES
Runtime features:   none
Checksum:           crc32c
Number of devices:  2
Devices:
   ID        SIZE  PATH
    1    50.00GiB  /dev/sdd1
    2    50.00GiB  /dev/sde1
```

Montá el subvolume de nivel superior (Subvolume ID 5) y construí la disposición de subvolumes `@pg_data` y `@snapshots`:

```bash
sudo mkdir -p /mnt/btrfs-root
sudo mount /dev/sdd1 /mnt/btrfs-root

# Create structured subvolumes
sudo btrfs subvolume create /mnt/btrfs-root/@pg_data
sudo btrfs subvolume create /mnt/btrfs-root/@snapshots

# List subvolumes to capture Subvolume IDs
sudo btrfs subvolume list /mnt/btrfs-root
```

**Salida de terminal esperada:**
```text
ID 256 gen 7 top level 5 path @pg_data
ID 257 gen 8 top level 5 path @snapshots
```

---

### Paso 2.2: Montaje de subvolumes con flags de tiempo de ejecución optimizados y deshabilitación de CoW

Montá `@pg_data` en `/var/lib/postgresql/data` utilizando compresión ZSTD, sin actualización de fecha de acceso (noatime), y deshabilitá Copy-on-Write (`nodatacow`) específicamente en el directorio de archivos de la base de datos para eliminar la fragmentación del B-tree:

```bash
sudo mkdir -p /var/lib/postgresql/data

# Mount @pg_data with explicit subvolume selector
sudo mount -o subvol=@pg_data,compress=zstd:3,noatime /dev/sdd1 /var/lib/postgresql/data

# Disable Copy-on-Write (CoW) on the directory before database initialization
sudo chattr +C /var/lib/postgresql/data

# Verify file attributes (C flag indicates NOCOW)
lsattr -d /var/lib/postgresql/data
```

**Salida de terminal esperada:**
```text
---------------C------ /var/lib/postgresql/data
```

---

### Paso 2.3: Snapshots de solo lectura y pipelines de respaldo incremental Send/Receive

Creá un snapshot de solo lectura de `@pg_data`, transmitilo a un directorio de destino de respaldo secundario a través de `btrfs send` y `btrfs receive`:

```bash
# Create read-only snapshot
sudo btrfs subvolume snapshot -r /var/lib/postgresql/data /mnt/btrfs-root/@snapshots/pg_data_20260806_0000

# Prepare local backup directory representing remote storage
sudo mkdir -p /mnt/backup_target

# Stream full snapshot stream
sudo btrfs send /mnt/btrfs-root/@snapshots/pg_data_20260806_0000 | sudo btrfs receive /mnt/backup_target/
```

**Salida de terminal esperada:**
```text
Create snapshot of '/var/lib/postgresql/data' in '/mnt/btrfs-root/@snapshots/pg_data_20260806_0000'
At subvol /mnt/btrfs-root/@snapshots/pg_data_20260806_0000
At subvol pg_data_20260806_0000
```

---

### Paso 2.4: Configuración de Btrfs Quota Group (`qgroup`) y aplicación de jerarquía

Habilitá el subsistema de cuotas de Btrfs en el pool, creá un quota group de alto nivel (`1/0`), asignale el subvolume `@pg_data` y aplicá un límite máximo de 20GB:

```bash
# Enable quota subsystem
sudo btrfs quota enable /mnt/btrfs-root

# Create hierarchical qgroup 1/0
sudo btrfs qgroup create 1/0 /mnt/btrfs-root

# Assign subvolume ID 256 (@pg_data) to qgroup 1/0
sudo btrfs qgroup assign 0/256 1/0 /mnt/btrfs-root

# Enforce a 20 Gigabyte limit on qgroup 1/0
sudo btrfs qgroup limit 20G 1/0 /mnt/btrfs-root

# Query quota assignment and current consumption
sudo btrfs qgroup show -p -r --units g /mnt/btrfs-root
```

**Salida de terminal esperada:**
```text
qgroupid         rfer         excl Parent  Max referenced Max exclusive 
--------         ----         ---- ------  -------------- ------------- 
0/5          0.00GiB      0.00GiB ---      none           none          
0/256        0.01GiB      0.01GiB 1/0      none           none          
0/257        0.00GiB      0.00GiB ---      none           none          
1/0          0.01GiB      0.01GiB ---      20.00GiB       none          
```

---

### Preguntas de comprensión: Ejercicio 2

2.1. ¿Por qué aplicar `chattr +C` (`nodatacow`) en un directorio existente *no* despoja de forma retroactiva las propiedades Copy-on-Write de los archivos ya presentes dentro de ese directorio, y qué secuencia de comandos se requiere para convertir los archivos de base de datos existentes a NOCOW?  
2.2. Explicá cómo `btrfs send -p <parent_snapshot> <child_snapshot>` calcula las diferencias de bloques entre dos snapshots de solo lectura sin leer el contenido de datos subyacente de los bloques.  
2.3. ¿Qué problema grave de sobrecarga de CPU en el kernel y contención de bloqueos (lock contention) puede ocurrir en entornos Kubernetes o Docker ejecutados sobre Btrfs cuando los `qgroups` están habilitados junto con eventos dinámicos del ciclo de vida de contenedores?

---

## Ejercicio 3: Orquestación de almacenamiento nativa con systemd (unidades `.mount` y `.automount`) vs. `/etc/fstab`

### Escenario
Para lograr secuencias de arranque no bloqueantes y una orquestación estricta de dependencias, estás reemplazando las entradas de almacenamiento heredadas en `/etc/fstab` con archivos de unidad `.mount` y `.automount` de systemd para un directorio analítico de alta concurrencia en `/mnt/data/analytics`.

---

### Paso 3.1: Creación de una unidad Mount de systemd para producción

Creá la unidad mount en `/etc/systemd/system/mnt-data-analytics.mount`.

```ini
[Unit]
Description=Production Analytics High-Performance Storage Block
Documentation=https://docs.internal.net/storage/analytics
Wants=network-online.target
After=network-online.target blockdev@dev-disk-by\x2dlabel-ANALYTICS_DATA.target
RequiresMountsFor=/mnt/data

[Mount]
What=/dev/disk/by-label/ANALYTICS_DATA
Where=/mnt/data/analytics
Type=xfs
Options=defaults,noatime,nodiratime,logbufs=8,logbsize=256k,allocsize=64m
TimeoutSec=30s
DirectoryMode=0755

[Install]
WantedBy=multi-user.target
```

---

### Paso 3.2: Creación de una unidad Automount a demanda de systemd

Creá la unidad automount correspondiente en `/etc/systemd/system/mnt-data-analytics.automount`. Esta intercepta las llamadas de acceso al filesystem en `/mnt/data/analytics` y monta el dispositivo de bloques a demanda, desmontándolo automáticamente después de 10 minutos de inactividad.

```ini
[Unit]
Description=Automount Controller for Analytics Storage Block
Documentation=https://docs.internal.net/storage/analytics
ConditionPathExists=/mnt/data

[Automount]
Where=/mnt/data/analytics
TimeoutIdleSec=600s
DirectoryMode=0755

[Install]
WantedBy=multi-user.target
```

---

### Paso 3.3: Activación de unidades, verificación y gestión del ciclo de vida

Recargá systemd para compilar los árboles de dependencias de las unidades, activá la interfaz `.automount` y verificá el estado del montaje dinámico:

```bash
# Reload systemd manager configuration
sudo systemctl daemon-reload

# Enable and start the automount unit (do NOT start the .mount unit directly)
sudo systemctl enable --now mnt-data-analytics.automount

# Inspect automount status
sudo systemctl status mnt-data-analytics.automount
```

**Salida de terminal esperada:**
```text
● mnt-data-analytics.automount - Automount Controller for Analytics Storage Block
     Loaded: loaded (/etc/systemd/system/mnt-data-analytics.automount; enabled; vendor preset: enabled)
     Active: active (waiting) since Thu 2026-08-06 09:40:12 EDT; 12s ago
   Triggers: ● mnt-data-analytics.mount
      Where: /mnt/data/analytics

Aug 06 09:40:12 node01 systemd[1]: Set up automount Automount Controller for Analytics Storage Block.
```

Dispará el montaje a demanda consultando el contenido del directorio:

```bash
# Accessing path triggers autofs kernel intercept
ls -la /mnt/data/analytics

# Check status of the underlying mount unit
sudo systemctl status mnt-data-analytics.mount
```

**Salida de terminal esperada:**
```text
● mnt-data-analytics.mount - Production Analytics High-Performance Storage Block
     Loaded: loaded (/etc/systemd/system/mnt-data-analytics.mount; disabled; vendor preset: enabled)
     Active: active (mounted) since Thu 2026-08-06 09:40:45 EDT; 3s ago
   TriggeredBy: ● mnt-data-analytics.automount
      Where: /mnt/data/analytics
       What: /dev/sdb2
      Tasks: 0 (limit: 19125)
     Memory: 44.0K
        CPU: 4ms
     CGroup: /system.slice/mnt-data-analytics.mount
```

---

### Preguntas de comprensión: Ejercicio 3

3.1. ¿Qué regla obligatoria de convención de nombres debe seguirse estrictamente al crear un archivo de unidad `.mount` de systemd, y qué comando específico de `systemd-escape` generaría el nombre de unidad correcto para una ruta de destino de `/srv/data/logs/2026`?  
3.2. ¿Cómo previenen las unidades `.automount` de systemd fallos y bloqueos en el arranque de aplicaciones cuando un dispositivo de almacenamiento de bloques subyacente (como un destino iSCSI o NFS) es temporalmente inalcanzable al momento del arranque?  
3.3. Describí el mecanismo exacto mediante el cual `systemd-fstab-generator` convierte las líneas heredadas de `/etc/fstab` en unidades mount nativas de systemd en memoria durante las etapas iniciales del arranque del kernel (`sysinit.target`).

---

## Ejercicio 4: Manejo dinámico de eventos de hardware con udev, sysfs y ajuste de I/O de bloques del kernel

### Escenario
Debés escribir reglas de `udev` para producción para identificar automáticamente dispositivos de bloques NVMe de alto rendimiento, aplicar el I/O scheduler multicola `none`, expandir los buffers de read-ahead del kernel a 1024 KiB y construir symlinks persistentes para dispositivos basados en números de serie de hardware.

---

### Paso 4.1: Interrogación de propiedades de hardware a través de `sysfs` y `udevadm`

Rastreá los atributos del dispositivo a lo largo de la jerarquía física del kernel para el dispositivo `/dev/nvme0n1`:

```bash
# Walk system hardware parent chain
sudo udevadm info --attribute-walk --name=/dev/nvme0n1
```

**Salida de terminal esperada:**
```text
Udevadm info starts with the device specified by the devpath '/devices/pci0000:00/0000:00:1d.0/0000:01:00.0/nvme/nvme0/nvme0n1':
  looking at device '/devices/pci0000:00/0000:00:1d.0/0000:01:00.0/nvme/nvme0/nvme0n1':
    KERNEL=="nvme0n1"
    SUBSYSTEM=="block"
    DRIVER==""
    ATTR{alignment_offset}=="0"
    ATTR{capability}=="0"
    ATTR{discard_max_bytes}=="2199023255552"
    ATTR{ext_range}=="256"
    ATTR{hidden}=="0"
    ATTR{range}=="0"
    ATTR{removable}=="0"
    ATTR{ro}=="0"
    ATTR{size}=="1000204880"
    ATTR{stat}=="     456     120    34568    1200      890     450    89012    4500        0     3200     5700"

  looking at parent device '/devices/pci0000:00/0000:00:1d.0/0000:01:00.0/nvme/nvme0':
    KERNELS=="nvme0"
    SUBSYSTEMS=="nvme"
    DRIVERS==""
    ATTRS{model}=="SAMSUNG MZQL2960HCJR-00A07"
    ATTRS{serial}=="S64BNX0T101928"
    ATTRS{firmware_rev}=="MPK7301Q"
```

Consultá las variables de entorno de la base de datos de udev del sistema para el dispositivo:

```bash
sudo udevadm info --query=all --name=/dev/nvme0n1 | grep -E "DEVLINKS|ID_SERIAL|ID_MODEL"
```

**Salida de terminal esperada:**
```text
E: DEVLINKS=/dev/disk/by-id/nvme-SAMSUNG_MZQL2960HCJR-00A07_S64BNX0T101928 /dev/disk/by-path/pci-0000:01:00.0-nvme-1
E: ID_MODEL=SAMSUNG MZQL2960HCJR-00A07
E: ID_SERIAL=S64BNX0T101928
```

---

### Paso 4.2: Escritura de reglas de producción para I/O Scheduling y Symlinks

Creá `/etc/udev/rules.d/60-persistent-nvme-scheduler.rules` para aplicar políticas operativas de almacenamiento:

```udev
# /etc/udev/rules.d/60-persistent-nvme-scheduler.rules
# Enforce 'none' I/O scheduler for NVMe block devices to bypass single-queue locks
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme[0-n]*n[1-9]*", ATTR{queue/scheduler}="none"

# Expand kernel read-ahead buffer size to 1024 KiB (2048 blocks of 512 bytes)
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme[0-n]*n[1-9]*", ATTR{queue/read_ahead_kb}="1024"

# Generate custom persistent symlink under /dev/storage/ using parent serial number match
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme*n1", ATTRS{serial}=="S64BNX0T101928", SYMLINK+="storage/fast-db-nvme"
```

---

### Paso 4.3: Simulación de reglas, recarga y validación en tiempo de ejecución

Realizá una prueba de simulación (dry-run) con `udevadm test` para verificar el procesamiento de reglas sin efectos secundarios:

```bash
sudo udevadm test /sys/block/nvme0n1 2>&1 | grep -E "scheduler|read_ahead_kb|fast-db-nvme"
```

**Salida de terminal esperada:**
```text
ATTR '/sys/devices/pci0000:00/0000:00:1d.0/0000:01:00.0/nvme/nvme0/nvme0n1/queue/scheduler' writing 'none'
ATTR '/sys/devices/pci0000:00/0000:00:1d.0/0000:01:00.0/nvme/nvme0/nvme0n1/queue/read_ahead_kb' writing '1024'
creating symlink '/dev/storage/fast-db-nvme' to '../nvme0n1'
```

Recargá el motor de reglas del demonio udev y dispará eventos de dispositivos de bloques para aplicar los cambios:

```bash
# Reload control daemon
sudo udevadm control --reload-rules

# Trigger subsystem events for block devices
sudo udevadm trigger --subsystem-match=block --action=change

# Verify current runtime scheduler and read-ahead settings
cat /sys/block/nvme0n1/queue/scheduler
cat /sys/block/nvme0n1/queue/read_ahead_kb
ls -la /dev/storage/fast-db-nvme
```

**Salida de terminal esperada:**
```text
[none] mq-deadline bfq 
1024
lrwxrwxrwx 1 root root 10 Aug  6 09:52 /dev/storage/fast-db-nvme -> ../nvme0n1
```

---

### Preguntas de comprensión: Ejercicio 4

4.1. En la lógica de reglas de udev, ¿cuál es la diferencia funcional precisa entre coincidir claves usando `ATTR{key}` frente a `ATTRS{key}`, y qué fallo ocurre si se usa `ATTR{serial}` en lugar de `ATTRS{serial}` al apuntar a dispositivos NVMe?  
4.2. ¿Por qué el I/O scheduler multicola `none` (passthrough) es óptimo para unidades NVMe de alto IOPS, mientras que `mq-deadline` o `bfq` se requiere para discos mecánicos rotacionales SATA/SAS?  
4.3. ¿Qué bloqueos mutuos (deadlocks) en la ejecución del kernel ocurren si una regla de udev ejecuta un script bloqueante de larga duración mediante `RUN+="/usr/local/bin/backup.sh"`, y cuál es el mecanismo adecuado para delegar tareas asincrónicas desde udev?

---

## Ejercicio 5: Dispositivos de bloques cifrados con LUKS2, dm-crypt e integración de arranque automatizado

### Escenario
Se te encarga aprovisionar una partición de almacenamiento LUKS2 cifrada en `/dev/sdf1` utilizando el cifrado AES-XTS-PLAIN64, configurar el desbloqueo automatizado mediante un keyfile a través de `/etc/crypttab`, montarla de forma persistente vía `/etc/fstab` y realizar una copia de respaldo de los encabezados críticos de LUKS para la recuperación ante desastres.

---

### Paso 5.1: Formateo de dispositivos LUKS2 con parámetros PBKDF Argon2id

Formateá `/dev/sdf1` con la especificación LUKS2, una longitud de clave explícita de 512 bits, hash SHA-512 y PBKDF intensivo en memoria Argon2id:

```bash
# Create dedicated keyfile directory with restricted permissions
sudo mkdir -p /etc/keys
sudo chmod 700 /etc/keys

# Generate 4096-bit cryptographically secure keyfile
sudo dd if=/dev/urandom of=/etc/keys/secure_vault.key bs=512 count=1
sudo chmod 400 /etc/keys/secure_vault.key

# Format partition with LUKS2 specifications
sudo cryptsetup luksFormat \
  --type luks2 \
  --cipher aes-xts-plain64 \
  --key-size 512 \
  --hash sha512 \
  --pbkdf argon2id \
  --pbkdf-memory 1048576 \
  --label "SECURE_STORAGE" \
  --batch-mode \
  /dev/sdf1 /etc/keys/secure_vault.key
```

Volcá los metadatos del encabezado de LUKS para verificar la alineación del payload, la configuración del cifrado y la asignación de keyslots:

```bash
sudo cryptsetup luksDump /dev/sdf1
```

**Salida de terminal esperada:**
```text
LUKS header information
Version:        2
Epoch:          3
Metadata area:  16384 [bytes]
Keyslot area:   16744448 [bytes]
UUID:           a1b2c3d4-e5f6-7890-abcd-ef1234567890
Label:          SECURE_STORAGE
Subsystem:      (no subsystem)

Data segments:
  0: crypt
	offset: 16777216 [bytes]
	length: (default)
	cipher: aes-xts-plain64
	sector: 512 [bytes]

Keyslots:
  0: luks2
	digest: 0
	kdf:    argon2id
	time cost: 4
	memory cost: 1048576
	cpus: 4
	cipher: aes-xts-plain64
	key size: 64 [bytes]
	AF:     luks1
	AF size: 4000 [bytes]
	Area:   131072 [bytes]
```

---

### Paso 5.2: Mapeo del dispositivo, formateo del filesystem y configuración de montajes automatizados

Abrí la capa de mapeo de LUKS en `/dev/mapper/secure_vault_ds`:

```bash
sudo cryptsetup open --key-file /etc/keys/secure_vault.key /dev/sdf1 secure_vault_ds

# Format the unencrypted dm-crypt block interface with XFS
sudo mkfs.xfs -f -L "SECURE_DATA" /dev/mapper/secure_vault_ds
```

Configurá `/etc/crypttab` para el desbloqueo automatizado persistente durante el arranque inicial del sistema:

```bash
# Add line to /etc/crypttab (using UUID of physical partition /dev/sdf1)
echo "secure_vault_ds UUID=a1b2c3d4-e5f6-7890-abcd-ef1234567890 /etc/keys/secure_vault.key luks,discard" | sudo tee -a /etc/crypttab
```

Configurá `/etc/fstab` para montar el dispositivo de bloques virtual mapeado:

```bash
sudo mkdir -p /mnt/secure_vault

# Add entry to /etc/fstab
echo "/dev/mapper/secure_vault_ds /mnt/secure_vault xfs defaults,noatime,nofail 0 2" | sudo tee -a /etc/fstab

# Test mount invocation using fstab engine
sudo mount /mnt/secure_vault
df -Th /mnt/secure_vault
```

**Salida de terminal esperada:**
```text
Filesystem                   Type  Size  Used Avail Use% Mounted on
/dev/mapper/secure_vault_ds  xfs    50G  390M   50G   1% /mnt/secure_vault
```

---

### Paso 5.3: Operaciones de recuperación ante desastres del encabezado LUKS

Realizá una copia de respaldo del encabezado binario de LUKS2 (incluyendo metadatos y keyslots) en una ubicación de rescate aislada:

```bash
sudo cryptsetup luksHeaderBackup /dev/sdf1 --header-backup-file /root/luks_header_sdf1.img
ls -lh /root/luks_header_sdf1.img
```

**Salida de terminal esperada:**
```text
-rw------- 1 root root 16M Aug  6 09:58 /root/luks_header_sdf1.img
```

---

### Preguntas de comprensión: Ejercicio 5

5.1. ¿Cuáles son las principales mejoras arquitectónicas de la especificación LUKS2 sobre LUKS1 con respecto a la redundancia de metadatos de encabezado, flexibilidad de esquema JSON y resiliencia contra la corrupción por corte físico de energía?  
5.2. Explicá los riesgos de seguridad asociados con especificar la opción `discard` (TRIM) en `/etc/crypttab` en unidades de estado sólido (SSD), y describí qué patrones estructurales de datos quedan expuestos a un atacante que analice chips flash en bruto.  
5.3. Si el encabezado primario de un volumen LUKS2 queda completamente sobrescrito con ceros debido a una escritura de bloques mal configurada (`dd if=/dev/zero of=/dev/sdf1 bs=1M count=10`), ¿qué procedimiento paso a paso debe seguirse para restaurar el encabezado usando `luksHeaderRestore` y recuperar el acceso a los datos subyacentes?

---

## Sección de respuestas

<details>
<summary><strong>Hacé clic para desplegar las respuestas técnicas de producción exhaustivas</strong></summary>

### Respuestas del Ejercicio 1

**1.1. Mecánica de Ext4 Multi-Mount Protection (MMP):**  
Ext4 Multi-Mount Protection (MMP) previene que un volumen de almacenamiento de bloques compartido (por ejemplo, un LUN iSCSI o un volumen FC presentado a múltiples nodos SAN) sea montado simultáneamente en modo lectura-escritura por más de un host. 

Al habilitar MMP (`tune2fs -O mmp`), un bloque dedicado (el bloque MMP) se actualiza periódicamente mediante un hilo del kernel en segundo plano en el nodo que montó el filesystem. El hilo escribe un número de secuencia único y un timestamp en el bloque MMP en un intervalo controlado por `s_mmp_update_interval`. 

Antes de que otro nodo monte el filesystem, lee el bloque MMP, espera un intervalo ligeramente superior a la frecuencia de actualización y verifica si el número de secuencia o el timestamp cambian. Si se detectan cambios, el kernel deniega la operación de montaje con un error `EEXIST` o "Device or resource busy". Esto previene la corrupción catastrófica de tablas de inodes y mapas de bloques causada por escrituras concurrentes en un escenario de split-brain.

**1.2. Escalabilidad vs. Sobrecarga de Allocation Group (AG) en XFS:**  
En XFS, los Allocation Groups (AGs) funcionan como filesystems virtuales independientes dentro del dispositivo de bloques. Cada AG mantiene sus propios b-trees de metadatos: b-trees de espacio libre para asignación de bloques (`bnobt`, `cntbt`), b-trees de asignación de inodes (`inobt`, `finobt`) y árboles de mapeo inverso (`rmapbt`). 

Los hilos paralelos que ejecutan asignaciones concurrentes adquieren bloqueos solo en AGs individuales. Un `agcount` más alto incrementa la concurrencia debido a que las solicitudes de asignación bloquean estructuras AG separadas simultáneamente sin contención de hilos. 

Sin embargo, si `agcount` se configura excesivamente alto en relación con el tamaño del volumen y la profundidad de cola, la fragmentación del espacio en disco aumenta. El espacio libre se fragmenta en trozos más pequeños por AG, impidiendo la asignación de grandes extents contiguos. Además, el consumo de memoria del kernel aumenta debido a mayores asignaciones de caché de metadatos de AG activos.

**1.3. Comportamiento de `xfs_repair` con journals sucios:**  
A diferencia del `e2fsck` de Ext4 (el cual reproduce transacciones de journal sucias no confirmadas antes de ejecutar verificaciones estructurales del filesystem), `xfs_repair` rehúsa intencionalmente reproducir el journal de logs de XFS. `xfs_repair` opera exclusivamente sobre estructuras en disco y no puede analizar ni reproducir de forma segura transacciones del journal en el espacio de usuario sin arriesgar transiciones de estado inválidas.

Si `xfs_repair -n` o `xfs_repair` detecta un journal sucio no confirmado, aborta con un mensaje indicando que el log está sucio y debe montarse para reproducirse. 

Para resolver esto de forma segura:
1. Montá el filesystem temporalmente para que el driver XFS del kernel reproduzca el journal de logs en el espacio del kernel.
2. Desmontá el filesystem limpiamente (`umount`), confirmando todas las transacciones.
3. Volvé a ejecutar `xfs_repair /dev/sdc1`.

Si el hardware de almacenamiento está permanentemente dañado y el log no se puede reproducir mediante el montaje, el administrador puede forzar la puesta a cero del log usando `xfs_repair -L /dev/sdc1`. *Advertencia:* Esto invalida las modificaciones de metadatos no confirmadas y puede provocar que los archivos huérfanos se muevan a `lost+found`.

---

### Respuestas del Ejercicio 2

**2.1. Alcance retrospectivo de `chattr +C` (NOCOW):**  
En Btrfs, el atributo de archivo NOCOW (`+C`) establece el flag en el inode al momento de la creación del archivo. Aplicar `chattr +C` a un directorio existente establece el atributo solo en los archivos recién creados dentro de ese directorio. Los archivos existentes conservan su propiedad inicial de Copy-on-Write porque sus extents de metadatos ya fueron escritos en disco siguiendo las reglas de CoW.

Para convertir los archivos existentes a NOCOW:
1. Creá un directorio hermano temporal: `mkdir /var/lib/postgresql/data_nocow`
2. Establecé NOCOW en el nuevo directorio: `chattr +C /var/lib/postgresql/data_nocow`
3. Copiá los archivos existentes al nuevo directorio: `cp -a --attr-same=no /var/lib/postgresql/data/* /var/lib/postgresql/data_nocow/` (o realizá una copia estándar sin reflink). Esto crea archivos completamente nuevos que heredan el flag `+C` del directorio padre.
4. Reemplazá el directorio antiguo por el nuevo directorio.

**2.2. Cálculo de diferencias en pipelines incrementales de `btrfs send`:**  
`btrfs send -p <parent_snapshot> <child_snapshot>` no escanea el contenido bruto de los archivos ni el contenido de los bloques. En su lugar, inspecciona los B-trees del subvolume Btrfs—específicamente el Extent Tree y los Metadata Trees. 

Dado que los snapshots en Btrfs comparten referencias de extents inmutables debido a Copy-on-Write, el snapshot padre y el snapshot hijo hacen referencia a Extent Data Items idénticos para los bloques que no sufrieron cambios. `btrfs send` recorre las estructuras del árbol de metadatos de ambos snapshots en paralelo, comparando números de generación y referencias de extents. 

Genera comandos de stream (`write`, `clone`, `snapshot`, `unlink`) únicamente para los registros de extents donde los números de generación difieren o donde existen nuevos nodos de extents en el snapshot hijo pero no en el padre. Esto reduce el tiempo de identificación de diferencias a un rápido recorrido de metadatos.

**2.3. Impacto de rendimiento de los `qgroups` de Btrfs en entornos de contenedores con alta rotación:**  
Los Btrfs Quota Groups (`qgroups`) calculan el uso de bloques referenciados y exclusivos por subvolume. En filesystems Copy-on-Write, los extents se comparten con frecuencia entre múltiples snapshots y subvolumes. 

Cuando se escribe, modifica o libera un bloque en cualquier subvolume, el kernel debe ejecutar búsquedas inversas de extents a través del Extent Tree global para recalcular los contadores `rfer` (referenciado) y `excl` (exclusivo) en todos los quota groups padres e hijos asociados. 

En entornos Docker o Kubernetes sobre Btrfs, continuamente se crean y eliminan cientos de capas de contenedores, volúmenes efímeros y snapshots de subvolumes de corta duración. Esto desencadena una masiva contención de bloqueos en los bloqueos de la raíz del árbol de extents global de Btrfs y provoca que el hilo del kernel `btrfs-transaction` consuma el 100% de uso de CPU, congelando el I/O de bloques del host.

---

### Respuestas del Ejercicio 3

**3.1. Restricciones de nombres en archivos de unidad Mount de systemd:**  
Systemd requiere que los nombres de archivo de las unidades `.mount` coincidan estrictamente con la ruta absoluta del punto de montaje de destino, reemplazando las barras diagonales (`/`) por guiones (`-`) y escapando caracteres especiales en valores hexadecimales. 

Si un archivo de unidad llamado `mnt-data-analytics.mount` contiene `Where=/mnt/data/other`, systemd rechaza la unidad durante la carga (`daemon-reload`) con un error crítico de configuración indicando que el nombre de la unidad no coincide con la configuración de la ruta en `Where=`.

Para generar el nombre de unidad exacto requerido para `/srv/data/logs/2026`:
```bash
systemd-escape --path --suffix=mount /srv/data/logs/2026
```
*Salida:* `srv-data-logs-2026.mount`.

**3.2. Resiliencia de las unidades Automount durante interrupciones de red o almacenamiento de bloques:**  
Los montajes estáticos estándar de `/etc/fstab` se ejecutan de manera síncrona durante la secuencia de arranque (`local-fs.target` o `remote-fs.target`). Si un dispositivo de almacenamiento de bloques de destino (como un destino iSCSI, LUN de Fibre Channel o exportación NFS) responde con lentitud, falla o está desconectado, el progreso del arranque se detiene hasta que expira `TimeoutSec` (con un valor predeterminado de 90 segundos por dispositivo), causando a menudo la caída a shells de rescate de emergencia.

Las unidades `.automount` de systemd desacoplan el progreso del arranque de la disponibilidad del almacenamiento de destino. Durante el arranque, systemd crea una interfaz de descriptor de archivos virtual kernel `autofs` en la ubicación de montaje de destino al instante sin intentar establecer comunicación con el dispositivo de almacenamiento de bloques físico. Los hitos de arranque del sistema (`multi-user.target`) se completan inmediatamente sin bloqueos. 

Cuando una aplicación emite una llamada al sistema de I/O (`open()`, `stat()`) hacia el directorio, la intercepción de kernel `autofs` pausa el hilo emisor y envía una señal a systemd para que dispare la unidad `.mount` subyacente. Si el dispositivo de almacenamiento está temporalmente fuera de línea, solo el proceso de la aplicación que intenta el acceso permanece a la espera; el resto del sistema operativo funciona con normalidad.

**3.3. Flujo de ejecución de `systemd-fstab-generator`:**  
Durante el inicio temprano del sistema (antes de que el PID 1 monte los filesystems locales), el initramfs o el espacio de usuario inicial ejecuta `systemd-fstab-generator` (ubicado en `/usr/lib/systemd/system-generators/`).

1. El generador lee `/etc/fstab` línea por línea.
2. Para cada entrada válida (excluyendo comentarios `comment`, `noauto` o entradas no válidas), sintetiza dinámicamente un archivo de unidad `.mount` en memoria dentro de `/run/systemd/generator/` (por ejemplo, `/run/systemd/generator/var-log.mount`).
3. Mapea las opciones: `noauto` omite los symlinks de destino en `multi-user.target.wants/`; `x-systemd.automount` genera dinámicamente una unidad `.automount` coincidente en `/run/systemd/generator/`; `x-systemd.device-timeout` establece los límites de espera de detección del dispositivo.
4. Construye dinámicamente las directivas de orden de dependencias (`Before=`, `After=`, `Requires=`, `Wants=`) contra las unidades de dispositivos de bloques (por ejemplo, `dev-disk-by\x2duuid-xxx.device`) y los objetivos de la jerarquía de montaje del filesystem.
5. El PID 1 de systemd carga estas unidades sintetizadas en su grafo de dependencias.

---

### Respuestas del Ejercicio 4

**4.1. Diferencia entre `ATTR{key}` y `ATTRS{key}` en reglas de udev:**  
- `ATTR{key}` verifica un atributo perteneciente **estrictamente al nodo de dispositivo individual que se está evaluando actualmente** por el evento (el nodo de dispositivo udev de destino al final de la ruta sysfs).
- `ATTRS{key}` (así como `KERNELS`, `DRIVERS`, `SUBSYSTEMS`) realiza un **recorrido ascendente recursivo a lo largo de la jerarquía del árbol de dispositivos padres** en `/sys`, haciendo coincidencia si la clave existe en el dispositivo *o en cualquiera de sus controladores de hardware padres* (por ejemplo, controladores NVMe, puentes PCI, hubs raíz USB).

Si un administrador escribe `ATTR{serial}=="S64BNX0T101928"` para el nodo de dispositivo de bloques `/dev/nvme0n1`, la regla **falla** porque el atributo `serial` está expuesto por el subsistema del controlador NVMe padre (`/sys/devices/.../nvme/nvme0`), mientras que `/dev/nvme0n1` expone únicamente métricas a nivel de bloque (`size`, `stat`, `capability`). Coincidir atributos del padre requiere el uso de `ATTRS{serial}`.

**4.2. Dinámica de I/O Schedulers: NVMe Multi-Queue vs. Discos mecánicos:**  
Los discos duros mecánicos tradicionales (HDDs) sufren de latencia por rotación física y tiempos de búsqueda. Los schedulers de cola única (`mq-deadline`, `bfq`) son necesarios para reordenar, fusionar y priorizar las solicitudes de bloques en función de la proximidad de los sectores físicos del disco, minimizando el movimiento físico del cabezal.

Las unidades NVMe utilizan controladores de estado sólido de alto paralelismo compatibles con hasta 64.000 colas de envío, cada una capaz de procesar 64.000 comandos concurrentes directamente sobre líneas PCIe. 

Interponer un algoritmo de planificación de software a nivel de sistema operativo (`mq-deadline` o `bfq`) introduce contención de bloqueos de CPU, sobrecarga por cambio de contexto y cuellos de botella artificiales en la cola. Configurar el scheduler en `none` pasa los vectores de lectura/escritura de bloques directamente desde el espacio de usuario/caché de páginas del kernel hacia las colas de hardware del controlador NVMe sin sobrecarga de bloqueos, alcanzando el máximo de IOPS y latencias submilisegundo.

**4.3. Ejecuciones bloqueantes en `RUN+=` y mecánica de colas de eventos del demonio udev:**  
El demonio udev (`systemd-udevd`) procesa los eventos netlink de hardware de forma secuencial o dentro de un pool acotado de hilos de trabajo. Si una regla de udev invoca un script en primer plano de larga ejecución mediante `RUN+="/usr/local/bin/backup.sh"`, el hilo de trabajo de udev asignado se bloquea hasta que el script finaliza.

Si la ejecución excede el tiempo de espera predeterminado de los eventos de udev (típicamente 180 segundos definidos por `event_timeout`), `systemd-udevd` termina por la fuerza el hilo de trabajo, registra un error "worker timed out, killing it", deja los nodos de dispositivos en un estado de inicialización incompleto y bloquea el manejo posterior de eventos de hardware en todo el sistema.

*Delegación asincrónica adecuada:*  
Nunca ejecutes rutinas bloqueantes dentro de `RUN+=`. En su lugar, usá udev para disparar una unidad de servicio de systemd asincrónica:
```udev
ACTION=="add", SUBSYSTEM=="block", KERNEL=="sd[a-z]1", TAG+="systemd", ENV{SYSTEMD_WANTS}="backup-workload@%k.service"
```
Esto provoca que udev notifique a systemd para que instancie y ejecute `backup-workload@sda1.service` en un contexto de ejecución separado, permitiendo a udev completar el procesamiento del evento de forma instantánea.

---

### Respuestas del Ejercicio 5

**5.1. Arquitectura del encabezado LUKS2 vs. LUKS1:**  
1. **Redundancia de metadatos y autoreparación:** LUKS1 contiene un único bloque de encabezado binario vulnerable en el offset 0. Si se corrompe, se pierde el acceso a todos los keyslots. LUKS2 implementa dos encabezados de metadatos idénticos (encabezado primario y secundario) almacenados en diferentes offsets, contando con checksums individuales (`crc32c`). Si el encabezado primario sufre corrupción de sectores, LUKS2 recupera automáticamente los metadatos desde la copia secundaria intacta.
2. **Esquema de metadatos JSON:** LUKS2 reemplaza los offsets binarios fijos con un esquema de cadena de metadatos JSON ASCII extensible. Esto permite la ubicación dinámica de keyslots, asignación dinámica de funciones de derivación de claves y soporte para mecanismos de tokens de múltiples segmentos (por ejemplo, vinculaciones TPM2, tokens FIDO2, smartcards PKCS#11).
3. **Resiliencia de Argon2id PBKDF:** LUKS1 dependía de PBKDF2 (SHA-256/SHA-512), que es vulnerable a ataques de diccionario paralelos por GPU y ASIC debido a que PBKDF2 requiere una memoria caché de CPU mínima. LUKS2 utiliza Argon2id, un Password-Based Key Derivation Function intensivo en memoria. Obliga al sistema a asignar grandes bloques configurables de RAM (por ejemplo, 1 GB por intento de ejecución) durante el descifrado de la clave, neutralizando los ataques acelerados por GPU/ASIC.

**5.2. Vulnerabilidades de seguridad de TRIM/Discard en almacenamiento cifrado:**  
Habilitar `discard` (TRIM) en `/etc/crypttab` permite al kernel informar al controlador de SSD subyacente cuando el filesystem libera rangos de bloques. El controlador de la SSD limpia las páginas de memoria flash, devolviendo ceros para los sectores no asignados.

*Compensación de seguridad (fuga de información):*  
Sin TRIM, un dispositivo de bloques cifrado le aparece a un atacante fuera de línea como un bloque homogéneo de datos aleatorios de alta entropía; la frontera entre sectores de datos utilizados y espacio libre es indistinguible. 

Cuando TRIM está habilitado en un volumen LUKS, los bloques recortados devuelven sectores 0x00 vacíos directamente a las consultas de lectura brutos. Un atacante en posesión del soporte de almacenamiento físico en bruto puede identificar:
- Métricas exactas de utilización del volumen y espacio libre disponible.
- Ubicación física exacta, disposición y patrones de fragmentación de extents de los filesystems activos.
- El tipo exacto de filesystem basado en ubicaciones reservadas de bloques estructurales sin recortar (por ejemplo, superblocks, tablas de inodes).

**5.3. Procedimiento de recuperación para encabezados primarios LUKS2 sobrescritos con ceros:**  
Si el encabezado primario al inicio de `/dev/sdf1` está corrompido o puesto a cero:

1. NO intentes ejecutar `mkfs` ni volver a formatear el dispositivo. Desmontá cualquier interfaz mapeada (`cryptsetup close`).
2. Verificá si existe un archivo de respaldo externo fuera de línea (por ejemplo, `/root/luks_header_sdf1.img`).
3. Si existe una copia de respaldo fuera de línea, restaurá el encabezado directamente:
   ```bash
   sudo cryptsetup luksHeaderRestore /dev/sdf1 --header-backup-file /root/luks_header_sdf1.img
   ```
4. Si no existe un archivo de respaldo fuera de línea, pero se utilizó LUKS2, intentá la recuperación desde el encabezado secundario interno de respaldo utilizando `cryptsetup`:
   ```bash
   sudo cryptsetup open --repair /dev/sdf1 secure_vault_ds
   ```
   La opción `--repair` detecta que la firma mágica del encabezado primario de LUKS2 no es válida, verifica el checksum CRC32 del encabezado secundario ubicado más adelante en el arreglo de bloques del disco y sobrescribe el encabezado primario corrompido con la estructura del encabezado secundario intacta.
5. Volvé a abrir la interfaz de bloques mapeada dm-crypt:
   ```bash
   sudo cryptsetup open /dev/sdf1 secure_vault_ds
   ```
6. Ejecutá verificaciones de integridad no destructivas del filesystem (`xfs_repair -n` o `fsck.ext4 -fn`) en `/dev/mapper/secure_vault_ds` para verificar la integridad estructural de los datos.

</details>