# 1.4 Devices, Linux Filesystems, Filesystem Hierarchy Standard

## 1. Motivaci\u00f3n y Problema Arquitect\u00f3nico de Producci\u00f3n

En el dise\u00f1o de plataformas nativas de la nube y bases de datos distribuidas, el almacenamiento no es un simple recurso; es el cuello de botella arquitect\u00f3nico principal (I/O Wait). Un Site Reliability Engineer (SRE) debe comprender c\u00f3mo el kernel de Linux abstrae el hardware f\u00edsico a trav\u00e9s de archivos de dispositivos (Block y Character devices en `/dev/`), c\u00f3mo formatea esos bloques en Filesystems jer\u00e1rquicos (como ext4, XFS o Btrfs) y c\u00f3mo organiza estandarizadamente estos directorios (FHS - Filesystem Hierarchy Standard).

El problema cl\u00e1sico en producci\u00f3n ocurre cuando se agotan los Inodes (incluso con terabytes de espacio libre) causando fallos catastr\u00f3ficos en bases de datos, o cuando un contenedor en un entorno Kubernetes satura el sistema de archivos principal (`/`) porque no se configur\u00f3 correctamente la arquitectura de vol\u00famenes persistentes. Entender la diferencia entre metadatos (superblocks, inodes) y data blocks, y conocer exactamente qu\u00e9 directorios son transitorios (`/tmp`, `/run`), persistentes (`/var`, `/home`) o pseudo-sistemas de archivos generados por el kernel (`/proc`, `/sys`), es fundamental para dise\u00f1ar estrategias de Disaster Recovery e Infrastructure as Code inmutables.

## 2. Comparativas T\u00e9cnicas y Trade-offs

### Filesystems de Producci\u00f3n: ext4 vs XFS vs Btrfs

| Caracter\u00edstica | ext4 | XFS | Btrfs |
| :--- | :--- | :--- | :--- |
| **Arquitectura de Asignaci\u00f3n** | Block-mapped cl\u00e1sico, uso estricto de Inodes pre-alocados. | Extent-based, escalabilidad masiva para I/O paralelo. | Copy-on-Write (CoW), subvol\u00famenes, RAID nativo. |
| **Casos de Uso (SRE)** | Discos de boot, vol\u00famenes de prop\u00f3sito general, contenedores peque\u00f1os. | Bases de datos pesadas (PostgreSQL, Cassandra), archivos gigantes. | Snapshots de root FS, entornos de testing con rollback r\u00e1pido. |
| **Limitaciones/Riesgos** | L\u00edmite r\u00edgido de Inodes (fijado en la creaci\u00f3n con `mkfs`). | No se puede reducir su tama\u00f1o (*shrink* offline u online). | Fragmentaci\u00f3n severa en workloads de escritura aleatoria (BBDD). |

### Filesystem Hierarchy Standard (FHS): Persistencia y Estado

| Directorio | Naturaleza de los Datos | Reglas de Plataforma y Backups |
| :--- | :--- | :--- |
| `/usr` | Solo lectura (Read-Only) binaries y librer\u00edas est\u00e1ticas. | No se respalda (se reconstruye v\u00eda repositorios de paquetes o im\u00e1genes de contenedores). |
| `/var` | Variable, State y Logs (`/var/log`, `/var/lib/docker`). | **Cr\u00edtico** respaldar las subcarpetas de estado (e.g., `/var/lib/mysql`). |
| `/etc` | Configuraci\u00f3n *Host-Specific*. | Se versiona completamente en Git (Ansible/Chef) o se lee v\u00eda ConfigMaps (K8s). |
| `/proc` y `/sys` | Virtuales (RAM). Exponen estado del Kernel y de los procesos (PID). | No respaldar. Usados exclusivamente para monitorizaci\u00f3n local (Node Exporter). |

## 3. Manifiestos, Configuraci\u00f3n e Infraestructura

### Configuraci\u00f3n Autom\u00e1tica: `/etc/fstab` (Filesystem Table)

En la automatizaci\u00f3n SRE de nodos bare-metal, configuramos el montaje persistente de dispositivos bloque utilizando UUIDs en lugar de nombres de device poco confiables (`/dev/sda1`), a\u00f1adiendo flags de optimizaci\u00f3n para SSDs/NVMe (como `noatime`).

```ini
# /etc/fstab: static file system information.
#
# <file system>                                  <mount point>   <type>  <options>                                       <dump>  <pass>

# Root filesystem (ext4) usando identificador inmutable UUID
UUID=a1b2c3d4-e5f6-7890-1234-56789abcdef0        /               ext4    errors=remount-ro                               0       1

# Data Volume (XFS) optimizado para bases de datos relacionales
# noatime: Evita escrituras en metadatos al leer archivos (mejora rendimiento I/O y alarga vida SSD)
# discard: Env\u00eda comandos TRIM al hardware subyacente de manera continua (opcional seg\u00fan controladora)
UUID=f9e8d7c6-b5a4-3210-9876-0fedcba98765        /var/lib/mysql  xfs     defaults,noatime,allocsize=64k                  0       2

# Memoria de Intercambio (Swap) 
# Prioridad especificada en caso de m\u00faltiples swaps
UUID=12345678-9abc-def0-1234-56789abcdef0        none            swap    sw,pri=10                                       0       0

# TMPFS: Montaje de RAM para archivos temporales (ideal para cach\u00e9s r\u00e1pidos)
tmpfs                                            /tmp            tmpfs   defaults,size=2G,mode=1777                      0       0
```

## 4. Comandos CLI y Salidas de Terminal Reales

### Gesti\u00f3n y Diagn\u00f3stico de Dispositivos de Bloque

```bash
# Listar todos los dispositivos de bloque con su jerarqu\u00eda, tama\u00f1o y punto de montaje actual
$ lsblk -f
NAME        FSTYPE   LABEL UUID                                 FSAVAIL FSUSE% MOUNTPOINT
loop0       squashfs                                                  0   100% /snap/core/11187
sda
\u251c\u2500sda1      vfat           4A2B-1C3D                               511M     0% /boot/efi
\u2514\u2500sda2      ext4           a1b2c3d4-e5f6-7890-1234-56789abcdef0     12G    35% /
nvme0n1     xfs      DATA  f9e8d7c6-b5a4-3210-9876-0fedcba98765    900G    10% /var/lib/mysql

# Identificar UUIDs exactos y File System Types de un disco crudo antes de montar
$ sudo blkid /dev/nvme0n1
/dev/nvme0n1: LABEL="DATA" UUID="f9e8d7c6-b5a4-3210-9876-0fedcba98765" TYPE="xfs"
```

### Monitoreo de Uso de Espacio e Inodes (Problemas Cl\u00e1sicos SRE)

```bash
# Espacio en disco tradicional, en formato le\u00edble por humanos (-h) e identificando sistemas de archivos (-T)
$ df -Th
Filesystem     Type      Size  Used Avail Use% Mounted on
/dev/sda2      ext4       20G  7.1G   12G  38% /
tmpfs          tmpfs      16G     0   16G   0% /dev/shm
/dev/nvme0n1   xfs       916G   95G  822G  11% /var/lib/mysql

# Verificaci\u00f3n de uso de Inodes (Cr\u00edtico: si IUse% llega al 100%, el FS reporta "No space left on device" aunque haya Terabytes libres)
$ df -ih
Filesystem     Inodes IUsed IFree IUse% Mounted on
/dev/sda2        1.3M  150K  1.2M   12% /
/dev/nvme0n1     458M   25K  458M    1% /var/lib/mysql
```

### Formateo y Mantenimiento de Filesystems

```bash
# Crear un sistema de archivos ext4 especificando una reserva (overhead) para root de solo 1% (ideal para discos grandes, default es 5%)
$ sudo mkfs.ext4 -m 1 -L BACKUPS /dev/sdb1
mke2fs 1.45.5 (07-Jan-2020)
Creating filesystem with 26214400 4k blocks and 6553600 inodes
Superblock backups stored on blocks: 
        32768, 98304, 163840, 229376, 294912, 819200, 884736, 1605632, 2654208, ...
Allocating group tables: done                            
Writing inode tables: done                            
Creating journal (131072 blocks): done
Writing superblocks and filesystem accounting information: done

# Forzar chequeo y reparaci\u00f3n de un filesystem ext4 offline (e2fsck / fsck)
$ sudo fsck.ext4 -fy /dev/sdb1
Pass 1: Checking inodes, blocks, and sizes
Pass 2: Checking directory structure
Pass 3: Checking directory connectivity
Pass 4: Checking reference counts
Pass 5: Checking group summary information
BACKUPS: 11/6553600 files (0.0% non-contiguous), 459544/26214400 blocks
```

## 5. Gu\u00eda de Verificaci\u00f3n y Diagn\u00f3stico de Fallas

1. **Error: `No space left on device` (Con espacio libre reportado por `df -h`)**:
   Esto ocurre t\u00edpicamente por una fuga masiva de archivos muy peque\u00f1os (ej. millones de archivos de sesi\u00f3n PHP o correos no procesados en `/var/spool/mqueue`) agotando la tabla de Inodes.
   *Diagn\u00f3stico:* Ejecuta `df -i`. Si IUse% est\u00e1 al 100%, debes encontrar el directorio ofensor usando: `sudo find /var/ -xdev -type f | cut -d "/" -f 2,3 | sort | uniq -c | sort -n`.
   *Resoluci\u00f3n:* Borrar los archivos residuales. Si es un requerimiento de dise\u00f1o, se debe formatear el disco con `mkfs.ext4 -N <cantidad_inodes>` o migrar a XFS/Btrfs que no tienen esta limitaci\u00f3n de manera r\u00edgida.

2. **Filesystem montado en `Read-Only` inesperadamente**:
   El kernel remonta autom\u00e1ticamente un filesystem como solo-lectura (`ro`) para proteger la integridad de los datos si detecta corrupci\u00f3n de hardware o inconsistencias a nivel software.
   *Diagn\u00f3stico:* Revisa los logs del kernel usando `dmesg -T | grep -i ext4` o `journalctl -k`. Buscar\u00e1s errores de I/O o Journal Abort.
   *Resoluci\u00f3n:* Debes desmontar (`umount`) y correr `fsck` manualmente sobre el block device problem\u00e1tico desde un Live CD o Rescue Mode. (Ej. `fsck.ext4 -y /dev/sda1`).

3. **Discos NVMe/SSD perdiendo rendimiento y degradando la aplicaci\u00f3n**:
   Si los SSDs presentan latencias (iowait alt\u00edsimo), puede que el proceso de recolecci\u00f3n de basura interno del disco est\u00e9 saturado.
   *Diagn\u00f3stico/Resoluci\u00f3n:* Verifica si est\u00e1s enviando peri\u00f3dicamente comandos TRIM. Esto se automatiza hoy en d\u00eda habilitando el timer de systemd en lugar del flag `discard` en el `fstab`:
   `$ sudo systemctl enable --now fstrim.timer`

## 6. Referencias

* LPIC-1 Objetivos (Topic 104): [https://www.lpi.org/our-certifications/exam-101-objectives](https://www.lpi.org/our-certifications/exam-101-objectives)
* EXT4 Filesystem Documentation (Kernel): [https://www.kernel.org/doc/html/latest/filesystems/ext4/index.html](https://www.kernel.org/doc/html/latest/filesystems/ext4/index.html)
* XFS Documentation: [https://xfs.org/docs/xfsdocs-xml-dev/XFS_User_Guide//tmp/en-US/html/index.html](https://xfs.org/docs/xfsdocs-xml-dev/XFS_User_Guide//tmp/en-US/html/index.html)
* Linux Filesystem Hierarchy Standard (FHS) Oficial: [https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html](https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html)