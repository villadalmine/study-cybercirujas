# Guía de Estudio LPI 702-100 (BSD Specialist)
## Tema 712.1: BSD Partitioning y Disk Labels
**Peso:** 3.33 (Peso del examen 2)  
**Audiencia objetivo:** SREs, Systems Engineers y Platform Architects  
**Referencia oficial:** [LPI BSD Specialist Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

---

## 1. Análisis Profundo: Arquitectura y Mecánica Interna

### 1.1 El Modelo de BSD Partitioning de Dos Niveles vs. GPT Nativo
Los esquemas tradicionales de layout de disco en UNIX/Linux mapean entradas de partición directamente dentro de la tabla de particiones MBR (Master Boot Record) (hasta 4 particiones primarias). En contraste, los sistemas operativos BSD emplean históricamente un modelo de disk partitioning de dos niveles para superar las limitaciones de MBR mientras proporcionan límites de seguridad de filesystem impuestos por el kernel.

```
+-----------------------------------------------------------------------+
| Physical Disk / Storage LUN (e.g., /dev/ada0 or /dev/sd0)              |
+-----------------------------------------------------------------------+
| MBR (Master Boot Record) Sector 0                                     |
+-------------------+-------------------+------------------+------------+
| Slice 1 (0xA5/0xA6)| Slice 2          | Slice 3          | Slice 4    |
| (BSD Primary)     | (Linux/NTFS/etc.) | (FreeBSD/OpenBSD)| (Unused)   |
+-------------------+-------------------+------------------+------------+
        |
        v
+-----------------------------------------------------------------------+
| BSD Disklabel (Offset 512 bytes inside Slice 1 or sector 1 of disk)   |
+-----------------------------------------------------------------------+
| Partition 'a' -> / (Root Filesystem, Bootable)                        |
| Partition 'b' -> Swap Space                                           |
| Partition 'c' -> Entire Slice / Physical Disk (Raw Container)         |
| Partition 'd' -> /var Filesystem                                      |
| Partition 'e' -> /tmp Filesystem                                      |
| Partition 'f' -> /usr Filesystem                                      |
| Partition 'g' -> /home Filesystem                                     |
| Partition 'h' -> Additional Mount/Data Volume                         |
+-----------------------------------------------------------------------+
```

1. **Slices (Primary Partitioning):** Las particiones MBR primarias se denominan **slices** en la terminología BSD. En FreeBSD y NetBSD, a un MBR slice designado para BSD se le asigna el tipo de partición `0xA5` (165 decimal). En OpenBSD, se le asigna el tipo `0xA6` (166 decimal).
2. **Disklabels (Sub-particionamiento Secundario):** Dentro de un BSD slice (o directamente en un dispositivo de bloques raw disk en modo dedicado), un **BSD disklabel** subparticiona el slice en subunidades denotadas por letras (de la `a` a la `h`, o hasta la `p` en disklabels de 16 particiones).
3. **Convenciones de Letras de Partición:**
   * **`a`**: Tradicionalmente designada para el filesystem root (`/`).
   * **`b`**: Reservada para el swap space del sistema (`swap`).
   * **`c`**: Define el límite del **BSD slice completo** o raw disk. En OpenBSD y NetBSD, modificar la partición `c` está bloqueado o restringido para preservar los metadatos del slice.
   * **`d`**: En NetBSD/OpenBSD, `d` representa tradicionalmente el **disco físico completo** (mientras que `c` representa el BSD slice). En FreeBSD, `c` cubre ambos contextos.
   * **`e`–`h` (o hasta `p`)**: Filesystems de propósito general (`/var`, `/tmp`, `/usr`, `/home`).

### 1.2 Arquitectura Moderna: FreeBSD GEOM Framework vs. BSD Disklabel Tradicional
Los sistemas BSD modernos dividen la topología de disco en subsistemas arquitectónicos distintos:

* **FreeBSD GEOM Framework (`gpart`):** Arquitectura de storage modular donde las operaciones de disco son manejadas por clases GEOM (`GPT`, `MBR`, `BSD`, `MIRROR`). `gpart` abstrae la distinción heredada entre slice/disklabel en esquemas de partición unificados (por ejemplo, `MBR`, `BSD`, `GPT`).
* **OpenBSD & NetBSD (`fdisk` + `disklabel`):** Mantienen una separación explícita entre `fdisk` (editor de MBR slice) y `disklabel` (editor de subparticiones). NetBSD también ofrece `gpt` para la gestión de GUID Partition Table.

### 1.3 Esquemas de Nombres de Dispositivos entre Variantes BSD
Comprender las convenciones de nombres es crítico para la configuración de `/etc/fstab` y escenarios de recuperación:

| Variante BSD | Interfaz de Storage | Raw Disk | MBR Slice | Subpartición BSD | Ruta Completa del Dispositivo |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **FreeBSD (GEOM)** | SATA/AHCI | `ada0` | `ada0s1` | `ada0s1a` | `/dev/ada0s1a` |
| **FreeBSD (GEOM)** | NVMe / SAS | `nda0` / `da0` | N/A (GPT) | Partición 2 | `/dev/da0p2` o `/dev/gpt/rootfs` |
| **OpenBSD** | SATA/SCSI/NVMe | `sd0` | `sd0` (s1) | `a` | `/dev/sd0a` (raw: `/dev/rsd0a`) |
| **NetBSD** | SATA/IDE | `wd0` | `wd0` | `a` | `/dev/wd0a` (raw: `/dev/rwd0a`) |

---

## 2. Ejercicios Prácticos de Laboratorio para Producción

---

### Bloque de Lab 1: MBR Slicing Heredado y Gestión de BSD Disklabel (`fdisk` y `bsdlabel`/`disklabel`)

#### Escenario
Estás aprovisionando un appliance de infraestructura heredada ejecutando una instalación de BSD basada en MBR. Debes crear un MBR slice, escribir un BSD disklabel válido, particionarlo en montajes del sistema designados (`/`, `swap`, `/var`, `/usr`), editar el label mediante un stream de configuración ASCII y exportarlo para backup de automatización.

#### Paso 1: Inspeccionar e Inicializar la Tabla de Particiones MBR (`fdisk`)
Ejecuta `fdisk` en el dispositivo de disco objetivo (`/dev/ada1` o `/dev/sd1`) para inspeccionar los metadatos del slice existente y escribir un BSD slice primario que cubra todo el disco.

```bash
# 1. View current MBR table layout
fdisk /dev/ada1
```

**Salida Esperada:**
```text
******* Working on device /dev/ada1 *******
parameters extracted from in-core disklabel are:
cylinders=20805 heads=255 sectors/track=63 (16065 sectors/cylinder)

Figures below are in sectors (512 bytes):
Media sector size is 512
Warning: BIOS sector numbering starts with sector 1
Information from DOS bootblock is:
The data for partition 1 is:
sysid 165 (0xa5),(FreeBSD/NetBSD/386BSD)
    start 63, size 33423225 (16320Meg), flag 80 (active)
        beg: cyl 0/ head 1/ sector 1;
        end: cyl 1023/ head 255/ sector 63
The data for partition 2 is <UNUSED>
The data for partition 3 is <UNUSED>
The data for partition 4 is <UNUSED>
```

```bash
# 2. Initialize a clean MBR table and create a FreeBSD slice (0xA5) spanning sector 63 to end
fdisk -BI /dev/ada1
```

**Salida Esperada:**
```text
Information from DOS bootblock is:
The data for partition 1 is:
sysid 165 (0xa5),(FreeBSD/NetBSD/386BSD)
    start 63, size 33423225 (16320Meg), flag 80 (active)
        beg: cyl 0/ head 1/ sector 1;
        end: cyl 1023/ head 255/ sector 63
The data for partition 2 is <UNUSED>
The data for partition 3 is <UNUSED>
The data for partition 4 is <UNUSED>
fdisk: Placement warning: a range of 63 sectors (sector 0 - 62) is reserved.
fdisk: Wrote sector 0 successfully
```

#### Paso 2: Escribir el Boot Strap Inicial y el BSD Disklabel (`bsdlabel` / `disklabel`)
Escribe el disklabel raw por defecto en el slice 1 (`ada1s1`) e instala el código bootstrap estándar de BSD.

```bash
# Write standard initial disklabel layout and bootcode
bsdlabel -B -w /dev/ada1s1 auto
```

Ahora, vuelca la configuración de disklabel ASCII generada a la salida estándar para verificar la geometría por defecto y la partición `c` asignada automáticamente.

```bash
bsdlabel /dev/ada1s1
```

**Salida Esperada:**
```text
# /dev/ada1s1:
8 partitions:
#          size   offset    fstype   [fsize bsize bps/cpg]
  c:   33423225        0    unused        0     0        # "raw" part, don't edit
```

#### Paso 3: Definir Particiones Personalizadas Mediante Edición de Stream ASCII
Crea un archivo de definición de layout ASCII llamado `/tmp/disklabel.cfg` con cálculos explícitos de bloques para asignar `a` (root: 4GB), `b` (swap: 2GB), `d` (var: 4GB), y `e` (usr: espacio restante).

```bash
cat << 'EOF' > /tmp/disklabel.cfg
# /dev/ada1s1 production layout
8 partitions:
#          size   offset    fstype   [fsize bsize bps/cpg]
  a:    8388608        0    4.2BSD     2048 16384     0  # 4GB Root (starts offset 0)
  b:    4194304  8388608      swap                      # 2GB Swap (starts offset 8388608)
  c:   33423225        0    unused        0     0        # Full Slice Boundary
  d:    8388608 12582912    4.2BSD     2048 16384     0  # 4GB /var (starts offset 12582912)
  e:   12451705 20971520    4.2BSD     2048 16384     0  # ~6GB /usr (starts offset 20971520)
EOF
```

Aplica el archivo de configuración de nuevo al disklabel:

```bash
bsdlabel -R /dev/ada1s1 /tmp/disklabel.cfg
bsdlabel /dev/ada1s1
```

**Salida Esperada:**
```text
# /dev/ada1s1:
8 partitions:
#          size   offset    fstype   [fsize bsize bps/cpg]
  a:    8388608        0    4.2BSD     2048 16384     0
  b:    4194304  8388608      swap
  c:   33423225        0    unused        0     0
  d:    8388608 12582912    4.2BSD     2048 16384     0
  e:   12451705 20971520    4.2BSD     2048 16384     0
```

---

#### Preguntas de Verificación (Bloque 1)

1. **Durante el cálculo del offset de partición, ¿por qué la partición `a` comienza en el offset `0` relativo al BSD slice (`ada1s1`), aunque `fdisk` reportó que el slice en sí comienza en el sector `63` del disco físico?**
   * A) El sector 63 es descartado automáticamente por `bsdlabel` como espacio corrupto.
   * B) Los offsets de BSD disklabel son relativos al sector de inicio del *slice* contenedor, no al sector absoluto del disco físico.
   * C) La partición `a` sobrescribe el MBR ubicado en el sector 0.
   * D) El sector 0 de un slice está reservado exclusivamente para la partición `c`.

2. **Un ingeniero intenta eliminar la partición `c` en un BSD disklabel en OpenBSD (`disklabel -e sd0`). El editor rechaza la edición al guardar. ¿Cuál es la causa raíz?**
   * A) La partición `c` requiere un tipo de filesystem ext2fs.
   * B) La partición `c` define el límite estricto del slice/disco; eliminar o modificar su rango viola las comprobaciones de validación de geometría de disco del kernel.
   * C) La partición `c` solo se puede modificar usando `fdisk`.
   * D) Los disklabels de OpenBSD no usan letras; usan IDs numéricos.

---

### Bloque de Lab 2: Gestión Moderna de Particiones con FreeBSD GEOM Framework (`gpart`)

#### Escenario
Los entornos SRE modernos requieren GUID Partition Tables (GPT), alineación de sectores de 4KiB (SSDs/NVMe Advanced Format) y GPT labels para desacoplar los puntos de montaje de nodos de dispositivos volátiles como `/dev/ada0` o `/dev/da0`. Construirás un layout GPT listo para producción utilizando `gpart` de FreeBSD.

#### Paso 1: Crear el Esquema GPT e Instalar el Código de Arranque (Bootcode)
Destruye cualquier encabezado obsoleto en `/dev/ada0` e instancia un esquema de particionamiento GPT limpio.

```bash
# 1. Clear existing GEOM metadata and instantiate GPT
gpart destroy -F ada0 2>/dev/null || true
gpart create -s gpt ada0
```

**Salida Esperada:**
```text
ada0 created
```

```bash
# 2. Add the mandatory FreeBSD boot partition (512 KiB)
gpart add -t freebsd-boot -size 512k -l gptboot0 ada0
```

**Salida Esperada:**
```text
ada0p1 added
```

```bash
# 3. Embed the GPT bootstrap code into the PMBR and freebsd-boot partition
gpart bootcode -b /boot/pmbr -p /boot/gptboot -i 1 ada0
```

**Salida Esperada:**
```text
bootcode written to ada0
```

#### Paso 2: Crear Particiones Alineadas con GPT Labels (`-a 4k`)
Crea particiones alineadas a 4KiB para los filesystems swap y root, asignando labels lógicos para permitir un montaje independiente del hardware.

```bash
# Create 4GB Swap aligned to 4K boundaries
gpart add -t freebsd-swap -size 4G -label system-swap -a 4k ada0

# Create 30GB UFS Root filesystem aligned to 4K boundaries
gpart add -t freebsd-ufs -size 30G -label system-root -a 4k ada0

# Create remaining capacity for ZFS pool / data partition
gpart add -t freebsd-zfs -label zfs-data -a 4k ada0
```

Muestra la geometría detallada de las particiones, incluidos los offsets de inicio/fin, la alineación y los GPT labels:

```bash
gpart show -l -e ada0
```

**Salida Esperada:**
```text
=>      40  83886000  ada0  GPT  (40G)
        40      1024     1  gptboot0  [bootcode]  (512K)
      1064         8        - free -  (4.0K)
      1072   8388608     2  system-swap  (4.0G)
   8389680  62914560     3  system-root  (30G)
  71304240  12581799     4  zfs-data  (6.0G)
  83886039     41         - free -  (20K)
```

#### Paso 3: Configuración de `/etc/fstab` en Producción usando Device Labels
Configura `/etc/fstab` utilizando rutas persistentes de labels GEOM (`/dev/gpt/`) para prevenir fallos en el arranque del sistema si el orden de enumeración de discos cambia durante un reinicio o reemplazo de controladora.

```bash
cat << 'EOF' > /etc/fstab
# Device                Mountpoint      FSType  Options         Dump    Pass#
/dev/gpt/system-root    /               ufs     rw              1       1
/dev/gpt/system-swap    none            swap    sw              0       0
EOF
```

Verifica la sintaxis de `/etc/fstab` y prueba la resolución de labels bajo `/dev/gpt/`:

```bash
ls -l /dev/gpt/
```

**Salida Esperada:**
```text
crw-r-----  1 root  operator  0x091 Aug  6 20:15 gptboot0
crw-r-----  1 root  operator  0x093 Aug  6 20:15 system-root
crw-r-----  1 root  operator  0x092 Aug  6 20:15 system-swap
crw-r-----  1 root  operator  0x094 Aug  6 20:15 zfs-data
```

---

#### Preguntas de Verificación (Bloque 2)

3. **¿Cuál es el propósito estructural de la flag `-a 4k` al ejecutar `gpart add` en unidades de almacenamiento modernas?**
   * A) Formatea la partición automáticamente usando bloques UFS2 de 4096 bytes.
   * B) Fuerza que los offsets de inicio de sector sean múltiplos pares de 4096 bytes (8 sectores de 512B), previniendo la degradación del rendimiento por Read-Modify-Write en medios de almacenamiento Advanced Format (4Kn/512e).
   * C) Limita el tamaño de la partición a 4 Terabytes.
   * D) Habilita el cifrado de sectores AES-256 dentro de GEOM.

4. **Un Administrador cambia la controladora SAS de un servidor, lo que hace que el disco del SO anteriormente llamado `/dev/da0` se enumere como `/dev/da4`. ¿Por qué un sistema configurado con `/dev/gpt/system-root` en `/etc/fstab` todavía arranca con éxito sin intervención manual?**
   * A) El kernel consulta todas las controladoras de disco para buscar flags activas de MBR durante la etapa 2 del arranque.
   * B) GEOM lee automáticamente los metadatos del encabezado GPT en todos los discos descubiertos y expone los labels de volumen bajo `/dev/gpt/`, haciendo que las rutas de los nodos sean independientes de la enumeración de dispositivos.
   * C) El bootloader reescribe el archivo `/etc/fstab` antes de montar root.
   * D) El bootcode UEFI de FreeBSD convierte los nodos de dispositivos a direcciones IP.

---

### Bloque de Lab 3: Recuperación ante Desastres de BSD Disklabel Multiplataforma (Cross-BSD) y Diagnósticos Avanzados

#### Escenario
Un evento de corrupción puso en cero el primer sector de un BSD slice de NetBSD/OpenBSD (`/dev/sd0`), borrando el encabezado del disklabel. Los filesystems UFS/FFS subyacentes permanecen intactos en los bloques del disco. Debes utilizar técnicas de recuperación de diagnóstico (`scan_ffs`) para descubrir los límites de offset de partición perdidos y reconstruir manualmente el disklabel.

#### Paso 1: Simular la Destrucción del Disklabel y Diagnosticar la Corrupción
Ejecuta una comprobación de diagnóstico usando `disklabel` en el dispositivo de disco corrupto.

```bash
# Run disklabel inspection on damaged device /dev/sd0
disklabel sd0
```

**Salida Esperada:**
```text
disklabel: /dev/rsd0c: Invalid signature in disklabel
disklabel: /dev/rsd0c: No disk label read from disk.
```

#### Paso 2: Recuperar Offsets de Partición con `scan_ffs`
Ejecuta `scan_ffs` para escanear bloques de disco raw en busca de los números mágicos del superbloque UFS/FFS (`0x011954` o `0x19540119`) y calcular los sectores de inicio y tamaños exactos.

```bash
scan_ffs /dev/rsd0c
```

**Salida Esperada:**
```text
# Size      Offset       Filesystem     Blocksize   Fragsize
  4194304   64           FFS1/FFS2      16384       2048
  16777216  4194368      FFS1/FFS2      16384       2048
  20971520  20971584     FFS1/FFS2      16384       2048
```

#### Paso 3: Reconstruir el Disklabel a partir de los Superbloques Descubiertos
Usando los valores de la salida estándar de `scan_ffs`, construye un archivo de plantilla de recuperación de disklabel `/tmp/recover.cfg` y restaura el label usando `disklabel -R`.

```bash
cat << 'EOF' > /tmp/recover.cfg
type: SCSI
disk: SCSI disk
label: RecoveredDisk
flags:
bytes/sector: 512
sectors/track: 63
tracks/cylinder: 255
sectors/cylinder: 16065
cylinders: 5000
total sectors: 41943040

8 partitions:
#          size   offset    fstype   [fsize bsize bps/cpg]
  a:    4194304       64    4.2BSD     2048 16384        # Root filesystem
  b:   16777216  4194368    4.2BSD     2048 16384        # Data partition (/usr)
  c:   41943040        0    unused                        # Entire disk boundary
  d:   20971520 20971584    4.2BSD     2048 16384        # Extra partition (/var)
EOF
```

Aplica el disklabel restaurado al disco físico:

```bash
disklabel -R sd0 /tmp/recover.cfg
disklabel sd0
```

**Salida Esperada:**
```text
# /dev/sd0:
type: SCSI
disk: SCSI disk
label: RecoveredDisk
flags:
bytes/sector: 512
sectors/track: 63
tracks/cylinder: 255
sectors/cylinder: 16065
cylinders: 5000
total sectors: 41943040

8 partitions:
#          size   offset    fstype   [fsize bsize bps/cpg]
  a:    4194304       64    4.2BSD     2048 16384
  b:   16777216  4194368    4.2BSD     2048 16384
  c:   41943040        0    unused
  d:   20971520 20971584    4.2BSD     2048 16384
```

Verifica la integridad del filesystem en la partición `a` usando `fsck`:

```bash
fsck_ffs -n /dev/rsd0a
```

**Salida Esperada:**
```text
** /dev/rsd0a (NO WRITE)
** File System: FFS2 Volume: 
** Last Mounted on: /
** Phase 1 - Check Blocks and Sizes
** Phase 2 - Check Pathnames
** Phase 3 - Check Connectivity
** Phase 4 - Check Reference Counts
** Phase 5 - Check Cyl groups
3214 files, 412045 used, 1685107 free (1235 frags, 210484 blocks, 0.0% fragmentation)
```

---

#### Preguntas de Verificación (Bloque 3)

5. **¿Cómo localiza `scan_ffs` los límites de particiones BSD perdidos cuando falta la tabla de disklabel?**
   * A) Leyendo copias de seguridad de `/etc/fstab` almacenadas en el sector raw 1.
   * B) Escaneando bloques de sectores secuenciales en busca de firmas válidas de superbloques UFS/FFS, extrayendo encabezados de grupos de cilindros y calculando los offsets de bloques del filesystem.
   * C) Consultando el registro CMOS del BIOS del sistema.
   * D) Ejecutando `gpart recover` por debajo (under the hood).

6. **En FreeBSD, ¿qué comando muestra el árbol de dependencias jerárquico completo de los módulos de almacenamiento de GEOM (incluidas las clases DISK, PART, MBR, BSD y LABEL)?**
   * A) `disklabel -tree`
   * B) `geom disk list` / `gpart status` / `sysctl kern.geom.conftxt`
   * C) `fdisk -s`
   * D) `cat /proc/partitions`

---

## 3. Respuestas de Verificación Exhaustivas y Justificación Técnica

<details>
<summary><strong>Haz clic para expandir la Clave de Respuestas y la Justificación Detallada</strong></summary>

### Pregunta 1
* **Respuesta Correcta:** **B**
* **Justificación Técnica:** En el modelo tradicional de particionamiento BSD de dos niveles, los MBR slices subdividen primero el medio físico. El BSD disklabel reside dentro de un slice específico (`sysid 0xA5` o `0xA6`). Por consiguiente, el offset de sector `0` dentro de un archivo de definición de disklabel corresponde al sector de inicio de ese *slice*, no al bloque 0 de todo el disco rígido físico.

### Pregunta 2
* **Respuesta Correcta:** **B**
* **Justificación Técnica:** En OpenBSD y NetBSD, la partición `c` representa el límite del contenedor raw del slice completo o disco completo. El subsistema de disklabel del kernel impone reglas de validación strictly que impiden a los administradores eliminar o alterar los límites de tamaño de la partición `c` para evitar la pérdida catastrófica del acceso a los metadatos de geometría del disco raw.

### Pregunta 3
* **Respuesta Correcta:** **B**
* **Justificación Técnica:** Las unidades modernas (Advanced Format 512e/4Kn) utilizan tamaños de sectores físicos de 4096 bytes. Si una partición comienza en un sector no alineado (por ejemplo, el sector 63), las operaciones de escritura de un solo bloque abarcan dos sectores físicos, lo que resulta en penalizaciones severas de rendimiento por Read-Modify-Write. La flag `-a 4k` en `gpart` fuerza la alineación a límites de sectores que sean divisibles por 4096 bytes (8 sectores de 512 bytes).

### Pregunta 4
* **Respuesta Correcta:** **B**
* **Justificación Técnica:** El subsistema GEOM de FreeBSD inspecciona dinámicamente los campos del encabezado GPT al conectar una unidad. La clase `LABEL` de GEOM analiza los labels de partición GPT y los expone como nodos persistentes bajo `/dev/gpt/<label>`. Esto abstrae las conexiones de almacenamiento de los cambios en la enumeración del bus subyacente (`/dev/ada0`, `/dev/da4`, etc.).

### Pregunta 5
* **Respuesta Correcta:** **B**
* **Justificación Técnica:** `scan_ffs` escanea los sectores del disco secuencialmente buscando el número mágico del superbloque UFS/FFS (`SBLOCKMAGIC` - `0x011954`). Cuando lo encuentra, analiza la estructura del superbloque para extraer el tamaño de bloque, los offsets de sectores y la extensión de la partición, generando líneas de offset de disklabel válidas que se pueden enviar directamente mediante un pipe a `disklabel -R`.

### Pregunta 6
* **Respuesta Correcta:** **B**
* **Justificación Técnica:** La arquitectura GEOM de FreeBSD modela las topologías de almacenamiento como un Grafo Acíclico Dirigido (DAG). El comando `geom disk list`, junto con `gpart status` y `sysctl kern.geom.conftxt`, muestra el árbol completo de almacenamiento del kernel (Providers, Consumers y clases GEOM).

</details>

---

## 4. Referencias Oficiales y Enlaces de Citación
* [LPI BSD Specialist Exam Objectives 702-100](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
* [FreeBSD Handbook: Storage & Partitioning (`gpart`)](https://docs.freebsd.org/en/books/handbook/disks/)
* [FreeBSD Manual Pages: `bsdlabel(8)`](https://man.freebsd.org/cgi/man.cgi?bsdlabel(8))
* [FreeBSD Manual Pages: `gpart(8)`](https://man.freebsd.org/cgi/man.cgi?gpart(8))
* [OpenBSD Manual Pages: `disklabel(8)`](https://man.openbsd.org/disklabel.8)
* [OpenBSD Manual Pages: `scan_ffs(8)`](https://man.openbsd.org/scan_ffs.8)