# LPI-702: Certificación BSD Specialist (Examen 702-100)
## Tema 712.1: Particionamiento BSD y Disklabels

---

### 1. Motivación Arquitectónica y Fundamentos de Producción

Las arquitecturas de almacenamiento x86 tradicionales heredaron el formato de tabla de particiones Master Boot Record (MBR) de IBM PC introducido en PC-DOS 2.0 (1983). La especificación MBR impone severas restricciones: un máximo de cuatro particiones primarias (o tres primarias y una extendida), direccionamiento Logical Block Addressing (LBA) de 32 bits que limita la capacidad máxima de disco direccionable a 2 TiB ($2^{32} \times 512$ bytes), y una falta total de redundancia de metadatos.

Para eludir las limitaciones de MBR manteniendo la compatibilidad a nivel de hardware con el firmware BIOS de PC, el ecosistema BSD Unix implementó un diseño de almacenamiento jerárquico de dos niveles:

1. **Slices (Particiones MBR Primarias):** A nivel de hardware/BIOS, el disco se divide en particiones MBR estándar. En la nomenclatura de BSD, estas entradas MBR se denominan **Slices** (por ejemplo, `/dev/ada0s1`, `/dev/da0s2`).
2. **Particiones BSD (Disklabels):** Dentro de un único slice de BSD (asignado tradicionalmente al tipo de partición MBR `0xA6` para OpenBSD, `0xA5` para FreeBSD y `0xA9` para NetBSD), BSD escribe su propia tabla de particiones secundaria llamada **Disk Label** (o `bsdlabel`). Este disklabel subdivide aún más el slice en hasta 8 (FreeBSD/NetBSD heredados) o 16 (OpenBSD / FreeBSD moderno `gpart`) subparticiones identificadas por letras individuales (`a` a la `h` o `p`).

```
+-----------------------------------------------------------------------------------+
| Physical Storage Device: /dev/da0 (e.g., 1 TB NVMe / SAS)                          |
+-----------------------------------------------------------------------------------+
| Sector 0: Master Boot Record (MBR Partition Table)                                |
| +-----------------+-----------------+-----------------+-------------------------+ |
| | Slice 1 (0xA5)  | Slice 2 (0x83)  | Slice 3 (0x82)  | Slice 4 (Unused)        | |
| | FreeBSD         | Linux ext4      | Linux Swap      |                         | |
| +--------+--------+-----------------+-----------------+-------------------------+ |
+----------|------------------------------------------------------------------------+
           v
+-----------------------------------------------------------------------------------+
| FreeBSD Slice 1: /dev/da0s1                                                       |
+-----------------------------------------------------------------------------------+
| Sector 0: Primary Boot Record (PBR / stage1 boot)                                 |
| Sector 1: struct disklabel (512 bytes, DISKMAGIC = 0x82564557)                     |
| +-------------------------------------------------------------------------------+ |
| | /dev/da0s1a : UFS2 / Root Filesystem (/) [Offset: LBA 16, Size: 10GB]         | |
| | /dev/da0s1b : Swap Space               [Offset: LBA 20971536, Size: 8GB]     | |
| | /dev/da0s1c : Raw Slice Cover-All      [Offset: LBA 0, Size: Entire Slice]    | |
| | /dev/da0s1d : UFS2 / /var              [Offset: LBA 37748752, Size: 50GB]     | |
| | /dev/da0s1e : UFS2 / /usr              [Offset: LBA 142606352, Size: 100GB]    | |
| | /dev/da0s1f : UFS2 / /home             [Offset: LBA 352321552, Size: Remainder]| |
| +-------------------------------------------------------------------------------+ |
+-----------------------------------------------------------------------------------+
```

#### Desglose Anatómico de `struct disklabel`
En los encabezados C de BSD (`sys/disklabel.h`), `struct disklabel` reside dentro del segundo sector de 512 bytes (LBA 1) del disco o slice. Los campos binarios clave incluyen:

* `d_magic` (`uint32_t`): Número mágico (`0x82564557` / `DISKMAGIC`). Verifica la validez del disklabel.
* `d_type` (`uint16_t`): Identificador del tipo de unidad (por ejemplo, `DTYPE_SCSI`, `DTYPE_ESDI`).
* `d_secsize` (`uint32_t`): Tamaño de sector en bytes (típicamente 512 o 4096).
* `d_nsectors` (`uint32_t`): Sectores por pista.
* `d_ntracks` (`uint32_t`): Pistas por cilindro.
* `d_ncylinders` (`uint32_t`): Cilindros totales en el dispositivo.
* `d_secpercyl` (`uint32_t`): Sectores por cilindro ($d\_nsectors \times d\_ntracks$).
* `d_secperunit` (`uint32_t`): Sectores totales en todo el disco o slice.
* `d_npartitions` (`uint16_t`): Número de entradas de partición definidas en `d_partitions[]`.
* `d_partitions[MAXPARTITIONS]` (arreglo `struct partition`): Cada entrada especifica:
  * `p_size` (`uint32_t`): Número de sectores en la partición.
  * `p_offset` (`uint32_t`): Offset LBA absoluto desde el inicio del disco/slice.
  * `p_fstype` (`uint8_t`): Identificador del tipo de sistema de archivos (`FS_UNUSED=0`, `FS_SWAP=1`, `FS_V6=2`, `FS_V7=3`, `FS_SYSV=4`, `FS_V71D=5`, `FS_BSDFFS=7`, `FS_MSDOS=8`, `FS_BSDLFS=9`, `FS_OTHER=10`, `FS_HPFS=11`, `FS_UFS2=14`, `FS_ZFS=27`).

#### Asignaciones Estándar de Letras de Partición en BSD
Por convención estricta en FreeBSD, OpenBSD y NetBSD, se reservan letras de partición específicas para roles operativos estandarizados:

| Letra de Partición | Rol Funcional | Descripción Operativa |
| :--- | :--- | :--- |
| **`a`** | Root Filesystem (`/`) | Partición de arranque del sistema que contiene `/boot`, binarios esenciales y la configuración inicial del kernel. |
| **`b`** | Swap Space | Área de paginación de memoria virtual. Direccionable directamente por el subsistema swapper del kernel. |
| **`c`** | Raw Slice / Device | Abarca el slice **completo** o el disco físico. Utilizado por utilidades del sistema (`fsck`, `dump`, `restore`, `gpart`) para I/O raw. Nunca debe formatearse con un sistema de archivos. |
| **`d`** | Raw Disk (NetBSD/OpenBSD) / Partición Estándar (FreeBSD) | En NetBSD/OpenBSD, `d` representa el disco físico completo (a través de todos los slices). En FreeBSD, `d` es una partición de sistema de archivos ordinaria de propósito general (`/var`). |
| **`e` - `h` / `p`** | User Filesystems | Montados como sistemas de archivos generales (`/usr`, `/var`, `/tmp`, `/home`). OpenBSD extiende este rango hasta `p` (16 entradas en total). |

---

### 2. Comparaciones Técnicas y Matrices de Compromisos Arquitectónicos

#### Tabla 1: Comparación de Esquemas de Particionamiento de Almacenamiento

| Métrica Arquitectónica | Master Boot Record (MBR Slices) | BSD Disklabel (Tradicional) | GUID Partition Table (GPT) |
| :--- | :--- | :--- | :--- |
| **Límites de Direccionamiento** | LBA de 32 bits (Máx. 2.0 TiB a 512B/sector) | LBA de 32 bits relativo al offset del slice (máx. 2.0 TiB) | LBA de 64 bits (Máx. 9.4 ZiB / límite de diseño de 8 ZiB) |
| **Cantidad Máxima de Particiones** | 4 Primarias (o 3 Primarias + 1 Extendida) | 8 (FreeBSD heredado), 16 (OpenBSD/NetBSD/GEOM moderno) | 128 particiones (predeterminado en encabezado; ampliable) |
| **Redundancia de Metadatos** | Ninguna (Un solo sector LBA 0; vulnerable a corrupción) | Ninguna (Un solo sector LBA 1 dentro del slice; sin encabezado de respaldo) | Encabezado Primario (LBA 1) + Encabezado Secundario de Respaldo (Último LBA del disco) |
| **Nivel de Jerarquía** | Nivel 1 (Abstracción de Hardware de Disco) | Nivel 2 (Subparticionamiento anidado dentro de MBR Slice) | Nivel 1 (Esquema Unificado de Particionamiento de Disco) |
| **Verificación de Integridad** | Solo verificación de firma de arranque `0xAA55` | `DISKMAGIC` (`0x82564557`) + Header Checksum | Sumas de comprobación CRC32 para Encabezado y Arreglo de Particiones |
| **Compatibilidad con Firmware** | BIOS Heredado / CS-MBR | BIOS Heredado vía código de arranque PBR de MBR | UEFI nativo / BIOS vía Protective MBR (PMBR) |

#### Tabla 2: Conjuntos de Herramientas de Administración de Discos en BSD

| Utilidad | Alcance del SO Destino | Arquitectura / Framework | Redimensionamiento Dinámico | Soporte de Esquema de Partición |
| :--- | :--- | :--- | :--- | :--- |
| **`gpart(8)`** | FreeBSD 8.0+ | Framework GEOM Modular (`geom_part.ko`) | Soportado (`gpart resize`) | GPT, MBR, BSD, VTOC8, PC98, APM |
| **`disklabel(8)`** | OpenBSD / NetBSD | ioctl Directo del Kernel (`DIOCWDINFO`, `DIOCGDINFO`) | Soportado (`disklabel -e`) | BSD Disklabel, wrapper MBR |
| **`bsdlabel(8)`** | FreeBSD Heredado | I/O Directo de Sector / Clase BSD Disklabel | Cálculo manual de sectores | Solo BSD Disklabel |
| **`fdisk(8)`** | FreeBSD / OpenBSD | Manipulador de Sectores MBR de Bajo Nivel | Destructivo / Manual | Solo MBR Slices |

---

### 3. Scripts de Automatización de Producción y Configuraciones de Infraestructura

#### Motor de Particionamiento Automatizado Zero-Touch para FreeBSD (`setup_bsd_storage.sh`)
Este script utiliza `gpart(8)` y `glabel(8)` de FreeBSD para crear una configuración de disco alineada de esquema dual (slice MBR heredado + bsdlabel), asignar etiquetas de sistema de archivos, construir sistemas de archivos UFS2 y autogenerar `/etc/fstab`.

```bash
#!/usr/bin/env sh
# ==============================================================================
# Script: setup_bsd_storage.sh
# Target OS: FreeBSD 13.x / 14.x
# Description: Automated, production-ready MBR slice and BSD disklabel provisioner
# ==============================================================================
set -eu

TARGET_DISK="da1"
SLICE_ID="s1"
TARGET_SLICE="${TARGET_DISK}${SLICE_ID}"

echo "[+] Destroying stale GEOM metadata on /dev/${TARGET_DISK}..."
sysctl kern.geom.debugflags=16
gpart destroy -F "${TARGET_DISK}" || true

echo "[+] Step 1: Initializing MBR Partition Table on /dev/${TARGET_DISK}..."
gpart create -s MBR "${TARGET_DISK}"

echo "[+] Step 2: Creating FreeBSD Slice (0xA5) spanning entire disk..."
gpart add -t freebsd "${TARGET_DISK}"

echo "[+] Step 3: Writing MBR Bootcode (boot0sio for serial console / boot0 for standard)..."
gpart bootcode -b /boot/boot0 "${TARGET_DISK}"

echo "[+] Step 4: Nesting BSD Disklabel scheme inside /dev/${TARGET_SLICE}..."
gpart create -s BSD "${TARGET_SLICE}"

echo "[+] Step 5: Allocating BSD Partitions with LBA alignment..."
# Partition 'a': 4GB UFS2 Root
gpart add -t freebsd-ufs -a 4k -s 4g "${TARGET_SLICE}"
# Partition 'b': 2GB Swap
gpart add -t freebsd-swap -a 4k -s 2g "${TARGET_SLICE}"
# Partition 'd': 10GB /var
gpart add -t freebsd-ufs -a 4k -s 10g "${TARGET_SLICE}"
# Partition 'e': 15GB /usr
gpart add -t freebsd-ufs -a 4k -s 15g "${TARGET_SLICE}"
# Partition 'f': Remaining capacity /data
gpart add -t freebsd-ufs -a 4k "${TARGET_SLICE}"

echo "[+] Step 6: Installing BSD Bootcode (boot1) into Slice 1..."
gpart bootcode -b /boot/boot1 "${TARGET_SLICE}"

echo "[+] Step 7: Formatting UFS2 Filesystems with Soft updates & SU+J..."
newfs -U -j -L rootfs "/dev/${TARGET_SLICE}a"
newfs -U -j -L varfs  "/dev/${TARGET_SLICE}d"
newfs -U -j -L usrfs  "/dev/${TARGET_SLICE}e"
newfs -U -j -L datafs "/dev/${TARGET_SLICE}f"

echo "[+] Setup complete. Partition layout for ${TARGET_DISK}:"
gpart show -p "${TARGET_DISK}"
gpart show -p "${TARGET_SLICE}"
```

#### Manifiesto `/etc/fstab` Sintácticamente Válido (Basado en Etiquetas y Referenciación por Ruta de Dispositivo)
```fstab
# Device                Mountpoint      FStype  Options         Dump    Pass#
# ==============================================================================
# Root Filesystem referenced via GEOM Filesystem Label
/dev/ufs/rootfs         /               ufs     rw,noatime      1       1

# Swap space allocated on BSD Partition 'b'
/dev/da1s1b             none            swap    sw              0       0

# Variable data partition with Soft Updates + Journaling
/dev/ufs/varfs          /var            ufs     rw,noatime      2       2

# System Binaries and Libraries
/dev/ufs/usrfs          /usr            ufs     rw,noatime      2       2

# Secondary Volume referenced via direct BSD Partition Slice notation
/dev/da1s1f             /data           ufs     rw,noatime      2       2

# Process Filesystem Abstraction
proc                    /proc           procfs  rw              0       0
```

---

### 4. Ejecuciones Reales de CLI y Salidas de Inspección de Sectores Raw

#### Ejecución 1: Consultando la Topología de Disco GEOM en FreeBSD
```console
$ geom disk list da1
Geom name: da1
Providers:
1. Name: da1
   Mediasize: 107374182400 (100GiB)
   Sectorsize: 512
   Stripesize: 4096
   Stripeoffset: 0
   Mode: r0w0e0
   descr: QEMU HARDDISK
   lunid: 5000457601234567
   ident: QM00001
   rotationrate: 0
   fwsectors: 63
   fwheads: 255
```

#### Ejecución 2: Visualización Detallada de Particiones mediante `gpart show`
```console
$ gpart show -p da1
=>       63  209715137  da1  MBR  (100GiB)
         63       63       - free -  (31KiB)
        126  209715074  da1s1  freebsd  [active]  (100GiB)

$ gpart show -p da1s1
=>        0  209715074  da1s1  BSD  (100GiB)
          0    8388608  da1s1a  freebsd-ufs  (4.0GiB)
    8388608    4194304  da1s1b  freebsd-swap  (2.0GiB)
   12582912   20971520  da1s1d  freebsd-ufs  (10GiB)
   33554432   31457280  da1s1e  freebsd-ufs  (15GiB)
   65011712  144703362  da1s1f  freebsd-ufs  (69GiB)
```

#### Ejecución 3: Análisis de Hexdump de Bajo Nivel de `struct disklabel` en LBA 1
Leyendo el sector 1 de `/dev/da1s1` directamente para verificar `DISKMAGIC` (`0x82564557` en orden little-endian: `57 45 56 82`):

```console
$ dd if=/dev/da1s1 bs=512 count=1 skip=1 | hexdump -C
1+0 records in
1+0 records out
512 bytes transferred in 0.000142 secs (3605633 bytes/sec)
00000000  57 45 56 82 01 00 00 00  00 02 00 00 3f 00 00 00  |WEV.........?...|
00000010  ff 00 00 00 00 04 00 00  72 fab 0c 0c 00 00 00 00  |........r.......|
00000020  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
*
00000080  08 00 07 00 00 00 80 00  00 00 00 00 00 00 00 00  |................|
00000090  00 00 40 00 00 00 00 00  07 00 00 00 00 00 00 00  |..@.............|
000000a0  00 00 20 00 00 00 80 00  01 00 00 00 00 00 00 00  |.. .............|
000000b0  00 00 00 00 00 00 20 01  07 00 00 00 00 00 00 00  |...... .........|
000000c0  00 00 40 01 00 00 20 01  07 00 00 00 00 00 00 00  |..@... .........|
000000d0  02 4b 20 08 00 00 40 03  07 00 00 00 00 00 00 00  |.K ...@.........|
000000e0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
*
000001f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 perform|................|
00000200
```

#### Ejecución 4: Inspeccionando y Editando Disklabels en OpenBSD (`disklabel`)
```console
$ doas disklabel sd0
# /dev/rsd0c:
type: SCSI
disk: SCSI disk
label: VBOX HARDDISK
duid: a1b2c3d4e5f60789
flags:
bytes/sector: 512
sectors/track: 63
tracks/cylinder: 255
sectors/cylinder: 16065
cylinders: 13054
total sectors: 209715200
boundstart: 64
boundend: 209715136

16 partitions:
#                size        offset  fstype [fsize bsize cpg]
  a:          4194304            64  4.2BSD   2048 16384  16 # /
  b:          4194304       4194368    swap                  # swap
  c:        209715200             0    unused                # entire disk
  d:         20971520            8388672  4.2BSD   2048 16384  16 # /var
  e:         10485760          29360192  4.2BSD   2048 16384  16 # /tmp
  f:         41943040          39845952  4.2BSD   2048 16384  16 # /usr
  g:         20971520          81788992  4.2BSD   2048 16384  16 # /usr/X11R6
  h:         41943040         102760512  4.2BSD   2048 16384  16 # /usr/local
  k:         65011684         144703552  4.2BSD   4096 32768  32 # /home
```

---

### 5. Resolución de Problemas en Producción y Flujos de Trabajo de Diagnóstico

```
                        +-----------------------------------------+
                        | Disk Mount Failure / Partition Corruption|
                        +-----------------------------------------+
                                             |
                                             v
                        +-----------------------------------------+
                        | Run: gpart show or disklabel <device>   |
                        +-----------------------------------------+
                                             |
                   +-------------------------+-------------------------+
                   |                                                   |
                   v                                                   v
     [GEOM Provider Locked Error]                        [Corrupted Disklabel Metadata]
     "Operation not permitted"                           "Invalid magic number" / Missing Partitions
                   |                                                   |
                   v                                                   v
     +---------------------------+                       +---------------------------+
     | Check kernel write-lock   |                       | Dump sector 1 via dd:     |
     | sysctl kern.geom.debugflags|                      | dd if=/dev/da0s1 count=1  |
     +---------------------------+                       | skip=1 | hexdump -C       |
                   |                                     +---------------------------+
                   v                                                   |
     +---------------------------+                                     v
     | Temporarily disable lock: |                       +---------------------------+
     | sysctl kern.geom.debugflags=16                    | Check DISKMAGIC (0x82564557)|
     +---------------------------+                       +---------------------------+
                   |                                                   |
                   +-------------------------+-------------------------+
                                             |
                                             v
                        +-----------------------------------------+
                        | Restore Disklabel via Backup File or    |
                        | Rebuild Partition Table Metadata:       |
                        | FreeBSD: gpart recover / gpart restore  |
                        | OpenBSD: disklabel -R <dev> <protofile> |
                        +-----------------------------------------+
                                             |
                                             v
                        +-----------------------------------------+
                        | Run File System Integrity Check:        |
                        | fsck -t ufs -y /dev/<device_partition>  |
                        +-----------------------------------------+
```

#### Escenario de Diagnóstico 1: Bloqueos de Seguridad de GEOM que Impiden la Modificación del Disklabel
**Síntoma:** Ejecutar `gpart create`, `gpart add`, o escribir datos de sectores raw en un slice de BSD falla con:
```console
gpart: GEOM provider da1s1 is locked: Operation not permitted
```

**Causa Raíz:** La topología GEOM de FreeBSD impone un bloqueo de escritura (verificación de `footprint`) en proveedores de almacenamiento activos. Si cualquier partición dentro del slice `da1s1` está actualmente montada o accedida por el kernel, GEOM bloquea las actualizaciones de metadatos para evitar la corrupción del sistema de archivos.

**Pasos de Remediación:**
1. Desmontar todas las particiones activas que pertenezcan al slice de destino:
   ```console
   # umount -f /dev/da1s1*
   ```
2. Si el slice contiene la raíz o sistemas de archivos del sistema que no se pueden desmontar, anular los bloqueos de seguridad de GEOM mediante `sysctl`:
   ```console
   # sysctl kern.geom.debugflags=16
   kern.geom.debugflags: 0 -> 16
   ```
   *Nota: `debugflags=16` establece el bit `BERASE`, permitiendo escrituras raw en proveedores de almacenamiento protegidos.*

3. Ejecutar la modificación requerida de `gpart`.
4. Restablecer inmediatamente `debugflags` a `0` para restaurar las garantías de seguridad de almacenamiento del kernel:
   ```console
   # sysctl kern.geom.debugflags=0
   ```

---

#### Escenario de Diagnóstico 2: Encabezado `DISKMAGIC` Corrupto y Recuperación de la Tabla de Particiones
**Síntoma:** El kernel entra en panic o reporta `Invalid disklabel magic number` al montar `/dev/da1s1a`. La salida de `gpart show da1s1` indica `CORRUPT` o definiciones de partición faltantes.

**Flujo de Trabajo de Remediación:**

1. **Diagnóstico a Nivel de Sector:** Verificar si el sector del disklabel (LBA 1) ha sido puesto a cero o sobrescrito por un comando `dd` erróneo:
   ```console
   # dd if=/dev/da1s1 bs=512 count=1 skip=1 | hexdump -C | head -n 4
   ```
   Si el offset `00000000` no muestra `57 45 56 82`, el encabezado del disklabel está destruido.

2. **Recuperación mediante Disklabels de Respaldo en OpenBSD:**
   OpenBSD guarda automáticamente respaldos en ASCII del disklabel en `/var/backups/disklabel.*`. Para restaurar un diseño guardado en el disco `sd0`:
   ```console
   # disklabel -R sd0 /var/backups/disklabel.sd0.current
   ```

3. **Reconstrucción de Metadatos de Disklabel de `gpart` en FreeBSD:**
   Si se utiliza FreeBSD GEOM, `gpart` puede intentar una autorecuperación si existen espejos de metadatos primarios, o se puede restaurar manualmente desde un respaldo de `gpart` exportado previamente:
   ```console
   # Export layout backup during normal operations:
   # gpart backup da1s1 > /etc/backups/da1s1.layout

   # Restore layout to slice:
   # gpart restore da1s1 < /etc/backups/da1s1.layout
   ```

4. **Validación de Consistencia del Sistema de Archivos:**
   Después de reparar los límites de las particiones del disklabel, ejecutar `fsck` en todas las particiones BSD restauradas:
   ```console
   # fsck_ufs -y /dev/da1s1a
   # fsck_ufs -y /dev/da1s1d
   ```

---

### 6. Referencias

* **Resumen de la Certificación LPI BSD Specialist:**  
  https://www.lpi.org/our-certifications/bsd-specialist-overview/

* **Páginas de Manual de FreeBSD - Utilidad de Administración del Sistema `gpart(8)`:**  
  https://man.freebsd.org/cgi/man.cgi?gpart(8)

* **Páginas de Manual de FreeBSD - Utilidad de Etiquetado de Discos `bsdlabel(8)`:**  
  https://man.freebsd.org/cgi/man.cgi?bsdlabel(8)

* **Páginas de Manual de OpenBSD - Lectura y Escritura de Labels de Disco `disklabel(8)`:**  
  https://man.openbsd.org/disklabel.8

* **FreeBSD Handbook - Administración de Almacenamiento y Framework GEOM:**  
  https://docs.freebsd.org/en/books/handbook/disks/