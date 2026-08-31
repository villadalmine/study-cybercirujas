# 104.1 — Crear particiones y sistemas de archivos

**LPIC-1 · Examen 101-500 · Versión 5.0 · Peso: 3.12**

**Alcance del objetivo:** Gestionar tablas de particiones MBR · Usar comandos `mkfs` para crear sistemas de archivos ext2/ext3/ext4, XFS, VFAT y exFAT · Conocimiento general de ReiserFS y Btrfs · Conocimiento básico de `gdisk` y `parted` con GPT.

**Términos y utilidades:** `fdisk`, `gdisk`, `parted`, `mkfs`, `mkswap`

---

## 1. El problema de producción: por qué particionar es un control de fiabilidad, no un trámite

En el modelo mental de una única estación de trabajo, particionar es una tarea que se hace una sola vez desde el instalador. En una flota, es una de las pocas decisiones que resulta **efectivamente inmutable en tiempo de ejecución** y que propaga un fallo a toda una capa.

Tres clases concretas de fallos en producción se remontan directamente a este objetivo:

**1.1 — La caída por escritor sin límites.** Un nodo funciona con `/`, `/var` y `/var/log` en un solo sistema de archivos. Un contenedor en bucle de reinicios emite 4 GB/hora de logs JSON. Cuando el sistema de archivos llega al 100 %, el kubelet no puede escribir su checkpoint, `containerd` no puede escribir su base de datos de estado, `systemd-journald` rota hacia la nada, y `sshd` todavía puede aceptar una conexión pero PAM no puede escribir `lastlog` — con lo cual obtenés un login que se cuelga. Un cambio de 20 líneas en el momento del aprovisionamiento (`/var/log` en su propio volumen, o los bloques reservados de ext4 dejados al 5 % en `/`) convierte una pérdida total del nodo en una ruta de logs degradada. Particionar es **contención del radio de impacto implementada en la capa de bloques**.

**1.2 — El impuesto silencioso del 30 % en rendimiento.** Una partición creada en el sector 63 (el valor por defecto heredado de DOS/CHS) en un dispositivo con sectores físicos de 4 KiB, o en un LUN RAID-5 con una unidad de stripe de 64 KiB, significa que cada bloque del sistema de archivos queda a caballo entre dos unidades físicas. Cada escritura se convierte en un read-modify-write. Nada registra un error. Lo descubrís seis meses después en un histograma de latencia. La alineación se decide una sola vez, en el momento del `mkpart`, y no se puede arreglar sin recrear el sistema de archivos.

**1.3 — La imagen dorada que no arranca.** Una imagen construida en un host con `e2fsprogs` 1.47 o `xfsprogs` 6.x incorpora características del sistema de archivos (`orphan_file`, `nrext64`) que un kernel 4.18 se niega a montar. La construcción pasa. El despliegue en la capa más vieja falla de forma dura en el `initramfs`. Los valores por defecto de `mkfs` son un **contrato de compatibilidad entre el host de construcción y cada kernel que alguna vez montará el volumen**, y ese contrato es invisible salvo que lo fijes explícitamente.

Todo lo que sigue está al servicio de tomar esas tres decisiones de forma deliberada y verificable.

---

## 2. El sustrato: sectores, alineación y la capa de bloques

Antes de que exista tabla de particiones alguna, el kernel ya conoce cuatro números sobre el dispositivo. Toda decisión de alineación deriva de ellos.

| Atributo sysfs | Significado | Valor típico |
|---|---|---|
| `queue/logical_block_size` | La unidad direccionable más pequeña que el dispositivo aceptará para E/S (el "sector" en el que cuentan todas las herramientas) | 512 |
| `queue/physical_block_size` | La unidad más pequeña que el dispositivo escribe realmente de forma atómica | 512 o 4096 |
| `queue/minimum_io_size` | Por debajo de esto, el dispositivo hace read-modify-write | = tamaño de bloque físico |
| `queue/optimal_io_size` | Ancho de stripe completo anunciado por una controladora RAID / SAN; `0` = desconocido | 0, o `chunk × discos_de_datos` |
| `alignment_offset` | Cuánto está desplazado el primer bloque físico (puentes USB baratos lo informan mal) | 0 |

```
$ lsblk -o NAME,SIZE,TYPE,PHY-SEC,LOG-SEC,MIN-IO,OPT-IO,ALIGNMENT,ROTA,DISC-GRAN,MODEL
NAME      SIZE TYPE PHY-SEC LOG-SEC MIN-IO OPT-IO ALIGNMENT ROTA DISC-GRAN MODEL
nvme0n1 931.5G disk     512     512    512      0         0    0      512B SAMSUNG MZVLB1T0HBLR
sda       3.6T disk    4096     512   4096      0         0    1        0B ST4000NM0033-9ZM
md0       7.3T raid5    4096    4096  65536 262144         0    1        0B
```

```
$ cat /sys/block/md0/queue/{logical_block_size,physical_block_size,minimum_io_size,optimal_io_size}
4096
4096
65536
262144
```

Leé ese último bloque: tamaño de chunk 64 KiB, cuatro miembros de datos → E/S óptima 256 KiB. Esos dos números son exactamente lo que le vas a pasar a `mkfs.xfs -d su=64k,sw=4` en §7.4.

**Terminología en la que el examen y las herramientas no coinciden:** `sda` arriba es un disco **512e** — sectores físicos de 4096 bytes emulados como sectores lógicos de 512 bytes. `fdisk`, `parted` y `gdisk` cuentan en sectores *lógicos* (512), pero la corrección se mide contra el sector *físico* (4096). Un disco **4Kn** informa 4096/4096 y rechazará de plano una partición alineada a 512 bytes.

### 2.1 La regla de 1 MiB

Toda herramienta moderna pone por defecto la primera partición en el **sector 2048 = 1 MiB**. Esto no es arbitrario: 1 MiB es divisible por 4 KiB (sectores físicos), 8 KiB/16 KiB (páginas NAND), 128 KiB–1 MiB (bloques de borrado de SSD), y por cada unidad de stripe RAID común hasta 1 MiB. Alinear a 1 MiB y dimensionar las particiones en MiB enteros hace que toda estructura posterior quede alineada por construcción.

La alternativa histórica — el sector 63, una pista de 63 sectores en la geometría CHS — es lo que usaba `fdisk` antes de util-linux 2.17 y lo que algunas herramientas de imagen de appliances todavía producen.

```
$ sudo parted /dev/sda align-check optimal 1
1 aligned

$ sudo parted /dev/sdb align-check optimal 1
1 not aligned
```

---

## 3. Formatos de tabla de particiones: MBR frente a GPT

### 3.1 Anatomía de MBR (etiqueta DOS)

El Master Boot Record es **únicamente el LBA 0** — 512 bytes en total:

| Desplazamiento | Tamaño | Contenido |
|---|---|---|
| `0x000` | 440 B | Código de arranque (etapa 1 del gestor de arranque) |
| `0x1B8` | 4 B | Firma del disco / "identificador de disco NT" — usado por `PARTUUID=` como `<sig>-<nn>` |
| `0x1BC` | 2 B | Reservado (normalmente `0x0000`) |
| `0x1BE` | 64 B | **Tabla de particiones: 4 entradas × 16 bytes** |
| `0x1FE` | 2 B | Firma de arranque `0x55AA` |

Cada entrada de 16 bytes: bandera de arranque (1 B), inicio CHS (3 B), **ID de tipo de partición (1 B)**, fin CHS (3 B), **LBA de inicio (4 B)**, **cantidad de sectores (4 B)**.

Los dos campos de 32 bits son el origen de todos los límites de MBR:

- LBA de inicio máximo y longitud máxima = 2³² − 1 sectores → **2 TiB con sectores lógicos de 512 bytes** (2³² × 512 = 2 199 023 255 552 B). En un disco nativo 4Kn la misma tabla llega a 16 TiB, razón por la cual `fdisk` formula su negativa en bytes, no en terabytes.
- **Cuatro particiones primarias.** Más requiere una partición *extendida* (tipo `0x05` o `0x0F`) actuando como contenedor. Dentro de ella, cada partición **lógica** está precedida por su propio EBR (Extended Boot Record) — una lista enlazada simple. Las particiones lógicas se numeran siempre desde el **5** hacia arriba, sin importar cuántas primarias existan.

```
$ sudo fdisk -l /dev/sdb
Disk /dev/sdb: 50 GiB, 53687091200 bytes, 104857600 sectors
Disk model: QEMU HARDDISK   
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disklabel type: dos
Disk identifier: 0x3f7a1c08

Device     Boot    Start       End   Sectors  Size Id Type
/dev/sdb1            2048   1050623   1048576  512M 83 Linux
/dev/sdb2         1050624 104857599 103806976 49.5G  5 Extended
/dev/sdb5         1052672  21024767  19972096  9.5G 83 Linux
/dev/sdb6        21026816  41988095  20961280   10G 83 Linux
```

Observá que `sdb5` empieza en 1052672, **2048 sectores después** de que el contenedor extendido empieza en 1050624. Ese hueco alberga el EBR y preserva la alineación. Un diseño calculado a mano que olvide este hueco o bien sobrescribe el EBR o bien desalinea todas las particiones lógicas.

### 3.2 Anatomía de GPT

| LBA | Contenido |
|---|---|
| 0 | **MBR protectivo** — una única entrada de tipo `0xEE` que abarca todo el disco, para que las herramientas que solo entienden MBR vean "lleno, desconocido" en vez de "vacío" |
| 1 | **Cabecera GPT primaria** — firma `EFI PART`, GUID del disco, CRC32 de sí misma, CRC32 del array de entradas, puntero a la cabecera de respaldo |
| 2–33 | **Array de entradas de partición** — 128 entradas × 128 bytes = 16 KiB |
| … | Área utilizable (primer sector utilizable = 34; las herramientas empiezan en 2048 por alineación) |
| −33…−2 | Array de entradas de respaldo |
| −1 (último LBA) | **Cabecera GPT de respaldo** |

Cada entrada contiene: **GUID de tipo de partición** (16 B), **GUID único de partición** (16 B — esto es `PARTUUID=`), primer LBA y último LBA (8 B cada uno, 64 bits), banderas de atributos (8 B), y un **nombre UTF-16 de 36 caracteres** (`PARTLABEL=`).

Consecuencias que importan operativamente:

- LBAs de 64 bits → **8 ZiB** a 512 B/sector. El límite desapareció.
- 128 particiones por defecto, ampliable.
- **CRC32 sobre la cabecera y sobre el array de entradas.** La corrupción se *detecta*, no se tolera en silencio. Esta es la mayor diferencia de fiabilidad respecto de MBR.
- **Una copia redundante al final del disco.** Cuando ampliás un disco virtual, la cabecera de respaldo deja de estar al final — ver §10.3.
- `PARTUUID` y `PARTLABEL` existen **sin sistema de archivos**, que es lo que te permite direccionar de forma estable una partición cruda (contenedor LUKS, PV, OSD de Ceph).

### 3.3 Tabla de compromisos

| Dimensión | MBR / etiqueta DOS | GPT |
|---|---|---|
| Disco máximo direccionable (sectores de 512 B) | 2 TiB | 8 ZiB |
| Particiones primarias | 4 (más mediante extendida + cadena de EBR) | 128 por defecto, redimensionable |
| Protección de integridad | Ninguna — un byte malo es una tabla perdida | CRC32 en la cabecera + array de entradas |
| Redundancia | Ninguna | Cabecera y array de respaldo completos al final del disco |
| Identidad de la partición | Firma del disco + índice (`PARTUUID=0x3f7a1c08-01`) — cambia si se reordena | GUID por partición, estable para siempre |
| Nombrado de particiones | Ninguno | 36 caracteres UTF-16 (`PARTLABEL`) |
| Espacio de tipos | 1 byte, 255 valores, reclamos de fabricantes que colisionan | GUID de 128 bits, sin colisiones |
| Encaje con el firmware | Nativo en BIOS/CSM; UEFI requiere CSM | Nativo en UEFI; el arranque BIOS necesita una partición BIOS boot `ef02` para el core.img de GRUB |
| Discoverable Partitions Spec (automontaje por tipo) | No soportado | Soportado (`systemd-gpt-auto-generator`) |
| Herramientas | `fdisk`, `parted`, `sfdisk` | `gdisk`/`sgdisk`, `parted`, `fdisk` (≥ util-linux 2.23), `sfdisk` |
| Cuándo seguir eligiéndolo | Appliance con BIOS heredada, plantilla de VM que debe arrancar en un hipervisor de 2010, pendrive para firmware antiguo | Todo lo demás. Por defecto para cualquier flota nueva. |

### 3.4 Identificadores de tipo de partición que hay que reconocer

MBR es un byte; GPT es un GUID que `gdisk` abrevia en una notación corta de 4 dígitos hexadecimales.

| Propósito | id MBR | código gdisk | GUID de tipo GPT |
|---|---|---|---|
| Datos de sistema de archivos Linux | `83` | `8300` | `0FC63DAF-8483-4772-8E79-3D69D8477DE4` |
| Swap de Linux | `82` | `8200` | `0657FD6D-A4AB-43C4-84E5-0933C84B4F4F` |
| LVM de Linux | `8e` | `8e00` | `E6D6D379-F507-44C2-A23C-238F2A3DF928` |
| RAID de Linux | `fd` | `fd00` | `A19D880F-05FC-4D3B-A006-743F0F84911E` |
| EFI System Partition (ESP) | `ef` | `ef00` | `C12A7328-F81F-11D2-BA4B-00A0C93EC93B` |
| Partición BIOS boot (core de GRUB en GPT) | — | `ef02` | `21686148-6449-6E6F-744E-656564454649` |
| `/boot` de Linux (XBOOTLDR) | — | `ea00` | `BC13C2FF-59E6-4262-A352-B275FD6F7172` |
| Raíz de Linux, x86-64 (automontable) | — | `8304` | `4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709` |
| `/home` de Linux | — | `8302` | `933AC7E1-2EB4-4F13-B844-0E14E2AEF915` |
| Extendida (CHS / LBA) | `05` / `0f` | n/a | n/a |
| FAT32 (CHS / LBA) | `0b` / `0c` | `0700` | `EBD0A0A2-B9E5-4433-87C0-68B6B72699C7` |
| NTFS / exFAT | `07` | `0700` | mismo GUID de datos básicos de Microsoft |

**El ID de tipo es metadato, no imposición.** El kernel montará tranquilamente ext4 desde una partición marcada como `82`. Pero `swapon` mediante una unidad generada por systemd, los filtros de `pvscan` de LVM, la autodetección de `mdadm`, la búsqueda de la ESP por parte del firmware UEFI y `systemd-gpt-auto-generator` **leen todos el tipo** y omitirán o manejarán mal una partición con el tipo equivocado. Configuralo correctamente.

---

## 4. El conjunto de herramientas

| Herramienta | Formatos de tabla | Interfaz | Automatizable | Crea sistemas de archivos | Notas |
|---|---|---|---|---|---|
| `fdisk` | MBR, GPT, SGI, Sun, BSD | Menú interactivo | Mal (truco por stdin) | No | La herramienta de referencia del examen. Desde util-linux 2.23 maneja GPT por completo. `-l` para listar, `-x` para detalle experto. |
| `sfdisk` | MBR, GPT | No interactiva, dump/restore | **Sí — la elección correcta** | No | `sfdisk -d` produce un volcado de texto reaplicable. Copia de seguridad/restauración de diseños. |
| `gdisk` | GPT (convierte MBR→GPT) | Interactiva, al estilo `fdisk` | No | No | El menú de recuperación (`r`) y el de experto (`x`) reconstruyen GPTs dañadas. |
| `sgdisk` | GPT | CLI pura | **Sí** | No | La herramienta de automatización para GPT. Copia de seguridad/restauración binaria de la GPT. |
| `cgdisk` | GPT | ncurses | No | No | |
| `parted` | MBR, GPT y ~una docena más | Interactiva **y** CLI | Sí (`-s`) | Históricamente sí — **no la uses para eso** | `mkpart <fstype>` solo fija el *código de tipo*. Motor de alineación (`-a optimal`). |
| `partprobe` / `partx` / `blockdev` | — | CLI | Sí | No | Fuerzan al kernel a releer la tabla. |
| `systemd-repart` | GPT | `.conf` declarativo | **Sí — idempotente** | **Sí** (`Format=`) | Imágenes que crecen en el primer arranque, restablecimiento de fábrica. Reemplazo moderno de los scripts de imagen. |
| `wipefs` | — | CLI | Sí | No | Elimina *firmas* de sistema de archivos/RAID/tabla. El comando correcto para "empezar limpio". |

### 4.1 `fdisk` — sesión MBR completa

```
$ sudo fdisk /dev/sdb

Welcome to fdisk (util-linux 2.39.3).
Changes will remain in memory only, until you decide to write them.
Be careful before using the write command.

Device does not contain a recognized partition table.
Created a new DOS disklabel with disk identifier 0x3f7a1c08.

Command (m for help): n
Partition type
   p   primary (0 primary, 0 extended, 4 free)
   e   extended (container for logical partitions)
Select (default p): p
Partition number (1-4, default 1): 1
First sector (2048-104857599, default 2048): 
Last sector, +/-sectors or +/-size{K,M,G,T,P} (2048-104857599, default 104857599): +512M

Created a new partition 1 of type 'Linux' and of size 512 MiB.

Command (m for help): n
Partition type
   p   primary (1 primary, 0 extended, 3 free)
   e   extended (container for logical partitions)
Select (default p): p
Partition number (2-4, default 2): 2
First sector (1050624-104857599, default 1050624): 
Last sector, +/-sectors or +/-size{K,M,G,T,P} (1050624-104857599, default 104857599): +8G

Created a new partition 2 of type 'Linux' and of size 8 GiB.

Command (m for help): t
Partition number (1,2, default 2): 2
Hex code or alias (type L to list all): 82

Changed type of partition 'Linux' to 'Linux swap / Solaris'.

Command (m for help): n
Partition type
   p   primary (2 primary, 0 extended, 2 free)
   e   extended (container for logical partitions)
Select (default p): p
Partition number (3,4, default 3): 3
First sector (17827840-104857599, default 17827840): 
Last sector, +/-sectors or +/-size{K,M,G,T,P} (17827840-104857599, default 104857599): 

Created a new partition 3 of type 'Linux' and of size 41.5 GiB.

Command (m for help): t
Partition number (1-3, default 3): 3
Hex code or alias (type L to list all): 8e

Changed type of partition 'Linux' to 'Linux LVM'.

Command (m for help): p
Disk /dev/sdb: 50 GiB, 53687091200 bytes, 104857600 sectors
Disk model: QEMU HARDDISK   
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disklabel type: dos
Disk identifier: 0x3f7a1c08

Device     Boot    Start       End  Sectors  Size Id Type
/dev/sdb1            2048   1050623  1048576  512M 83 Linux
/dev/sdb2         1050624  17827839 16777216    8G 82 Linux swap / Solaris
/dev/sdb3        17827840 104857599 87029760 41.5G 8e Linux LVM

Command (m for help): w
The partition table has been altered.
Calling ioctl() to re-read partition table.
Syncing disks.
```

**Teclas de comando que hay que memorizar:**

| Tecla | Acción |
|---|---|
| `m` | Ayuda |
| `p` | Imprimir la tabla |
| `n` | Nueva partición |
| `d` | Borrar partición |
| `t` | Cambiar el ID de tipo |
| `l` | Listar los IDs de tipo conocidos |
| `a` | Alternar la bandera de arranque (MBR) |
| `v` | Verificar la tabla |
| `o` | Crear una **nueva etiqueta DOS/MBR vacía** |
| `g` | Crear una **nueva etiqueta GPT vacía** |
| `x` | Menú experto (ediciones a nivel de sector) |
| `w` | **Escribir y salir** |
| `q` | **Salir, descartando todo** |

`q` es el botón de deshacer. Nada toca el disco hasta `w`. Ese es todo el modelo de seguridad de `fdisk`, y por eso el examen evalúa `w` frente a `q`.

`fdisk` en un disco demasiado grande:

```
$ sudo fdisk /dev/sdd
...
The size of this disk is 4 TiB (4398046511104 bytes). DOS partition table format
cannot be used on drives for volumes larger than 2199023255040 bytes for 512-byte
sectors. Use GUID partition table format (GPT).
```

### 4.2 `sfdisk` — copia de seguridad, restauración y la única forma sensata de automatizar MBR

```
$ sudo sfdisk -d /dev/sdb | sudo tee /root/backup/sdb.layout
label: dos
label-id: 0x3f7a1c08
device: /dev/sdb
unit: sectors
sector-size: 512

/dev/sdb1 : start=        2048, size=     1048576, type=83
/dev/sdb2 : start=     1050624, size=    16777216, type=82
/dev/sdb3 : start=    17827840, size=    87029760, type=8e
```

Restaurar, o clonar el diseño en un disco hermano:

```
$ sudo sfdisk /dev/sdc < /root/backup/sdb.layout
Checking that no-one is using this disk right now ... OK

Disk /dev/sdc: 50 GiB, 53687091200 bytes, 104857600 sectors
...
The partition table has been altered.
Calling ioctl() to re-read partition table.
Syncing disks.
```

Crear desde cero, de forma no interactiva, en un script de aprovisionamiento:

```bash
sudo sfdisk /dev/sdb <<'EOF'
label: dos
unit: sectors
,512M,83,*
,8G,82
,,8e
EOF
```

`start` vacío = "siguiente sector libre alineado"; `size` vacío en la última línea = "el resto del disco"; `*` = bandera de arranque. Verificar una tabla sin modificarla:

```
$ sudo sfdisk -V /dev/sdb
/dev/sdb: 
OK
```

### 4.3 `gdisk` — GPT interactivo

```
$ sudo gdisk /dev/nvme1n1
GPT fdisk (gdisk) version 1.0.9

Partition table scan:
  MBR: not present
  BSD: not present
  APM: not present
  GPT: not present

Creating new GPT entries in memory.

Command (? for help): o
This option deletes all partitions and creates a new protective MBR.
Proceed? (Y/N): Y

Command (? for help): n
Partition number (1-128, default 1): 1
First sector (34-2147483614, default = 2048) or {+-}size{KMGTP}: 
Last sector (2048-2147483614, default = 2147483614) or {+-}size{KMGTP}: +1G
Current type is 8300 (Linux filesystem)
Hex code or GUID (L to show codes, Enter = 8300): ef00
Changed type of partition to 'EFI system partition'

Command (? for help): n
Partition number (2-128, default 2): 2
First sector (2099200-2147483614, default = 2099200) or {+-}size{KMGTP}: 
Last sector (2099200-2147483614, default = 2147483614) or {+-}size{KMGTP}: +1M
Current type is 8300 (Linux filesystem)
Hex code or GUID (L to show codes, Enter = 8300): ef02
Changed type of partition to 'BIOS boot partition'

Command (? for help): n
Partition number (3-128, default 3): 3
First sector (2101248-2147483614, default = 2101248) or {+-}size{KMGTP}: 
Last sector (2101248-2147483614, default = 2147483614) or {+-}size{KMGTP}: 
Current type is 8300 (Linux filesystem)
Hex code or GUID (L to show codes, Enter = 8300): 8e00
Changed type of partition to 'Linux LVM'

Command (? for help): c
Partition number (1-3): 1
Enter name: ESP

Command (? for help): p
Disk /dev/nvme1n1: 2147483648 sectors, 1024.0 GiB
Model: Amazon Elastic Block Store              
Sector size (logical/physical): 512/512 bytes
Disk identifier (GUID): 5F2A0F7E-3C6B-4A2E-9D14-77C0B9F1A3E2
Partition table holds up to 128 entries
Main partition table begins at sector 2 and ends at sector 33
First usable sector is 34, last usable sector is 2147483614
Partitions will be aligned on 2048-sector boundaries
Total free space is 2014 sectors (1007.0 KiB)

Number  Start (sector)    End (sector)  Size       Code  Name
   1            2048         2099199   1024.0 MiB  EF00  ESP
   2         2099200         2101247   1024.0 KiB  EF02  BIOS boot partition
   3         2101248      2147483614   1023.0 GiB  8E00  Linux LVM

Command (? for help): w

Final checks complete. About to write GPT data. THIS WILL OVERWRITE EXISTING
PARTITIONS!!

Do you want to proceed? (Y/N): Y
OK; writing new GUID partition table (GPT) to /dev/nvme1n1.
The operation has completed successfully.
```

Menús adicionales que no tienen equivalente en `fdisk` y que importan durante los incidentes:

| Tecla | Menú | Uso |
|---|---|---|
| `v` | principal | Verificar la integridad de la GPT, informar problemas |
| `i` | principal | Mostrar el detalle completo de una partición, incluidos ambos GUIDs |
| `r` | **recuperación/transformación** | Reconstruir la GPT principal desde la de respaldo (`b`), la de respaldo desde la principal (`d`), convertir MBR→GPT (`g`), convertir GPT→MBR (`g` a la inversa vía `x`) |
| `x` | **experto** | Mover la GPT de respaldo al final (`e`), aleatorizar los GUIDs de disco y particiones (`z`... `g`), cambiar la alineación (`l`), fijar atributos (`a`) |

### 4.4 `sgdisk` — GPT en una línea

```
$ sudo sgdisk --zap-all /dev/nvme1n1
Creating new GPT entries in memory.
GPT data structures destroyed! You may now partition the disk using fdisk or
other utilities.

$ sudo sgdisk \
      -n 1:0:+1G   -t 1:ef00 -c 1:"ESP" \
      -n 2:0:+1M   -t 2:ef02 -c 2:"BIOSboot" \
      -n 3:0:0     -t 3:8e00 -c 3:"pv0" \
      /dev/nvme1n1
Setting name!
partNum is 0
Setting name!
partNum is 1
Setting name!
partNum is 2
The operation has completed successfully.
```

`-n <part>:<inicio>:<fin>` donde `0` significa "por defecto": siguiente sector libre alineado para el inicio, último sector disponible para el fin. `+1G` es relativo al inicio.

```
$ sudo sgdisk -p /dev/nvme1n1
Disk /dev/nvme1n1: 2147483648 sectors, 1024.0 GiB
Sector size (logical/physical): 512/512 bytes
Disk identifier (GUID): 5F2A0F7E-3C6B-4A2E-9D14-77C0B9F1A3E2
Partition table holds up to 128 entries
Main partition table begins at sector 2 and ends at sector 33
First usable sector is 34, last usable sector is 2147483614
Partitions will be aligned on 2048-sector boundaries
Total free space is 2014 sectors (1007.0 KiB)

Number  Start (sector)    End (sector)  Size       Code  Name
   1            2048         2099199   1024.0 MiB  EF00  ESP
   2         2099200         2101247   1024.0 KiB  EF02  BIOSboot
   3         2101248      2147483614   1023.0 GiB  8E00  pv0
```

Copia de seguridad y restauración binaria de las estructuras GPT — 33 KiB, guardala en tu almacén de configuración:

```
$ sudo sgdisk --backup=/root/backup/nvme1n1.gpt /dev/nvme1n1
The operation has completed successfully.

$ sudo sgdisk --load-backup=/root/backup/nvme1n1.gpt /dev/nvme2n1
The operation has completed successfully.

$ sudo sgdisk -G /dev/nvme2n1        # randomise disk GUID and every partition GUID
The operation has completed successfully.
```

**`sgdisk -G` tras una restauración en un disco distinto o un clonado de VM es obligatorio.** Omitirlo produce dos discos con `PARTUUID`s idénticos; entonces `/dev/disk/by-partuuid/` resuelve de forma no determinista y el initramfs puede montar la raíz equivocada.

### 4.5 `parted` — declarativo, automatizable y la autoridad en alineación

```
$ sudo parted -s -a optimal /dev/sdc -- \
      mklabel gpt \
      mkpart ESP  fat32 1MiB 513MiB \
      set 1 esp on \
      mkpart data xfs   513MiB 100%

$ sudo parted /dev/sdc print
Model: ATA Samsung SSD 870 EVO (scsi)
Disk /dev/sdc: 2000GB
Sector size (logical/physical): 512B/512B
Partition Table: gpt
Disk Flags: 

Number  Start   End     Size    File system  Name  Flags
 1      1049kB  538MB   537MB                ESP   boot, esp
 2      538MB   2000GB  1999GB                data
```

Tres cosas en esa salida son trampas de nivel examen:

1. **La columna `File system` está vacía.** `mkpart ... xfs ...` fijó el *GUID de tipo de partición*; **no** ejecutó `mkfs`. La columna se completa solo cuando existe un sistema de archivos real y `parted` detecta su firma.
2. `--` antes de los comandos impide que `parted` interprete desplazamientos negativos al estilo `-1s` como opciones. Incluilo siempre.
3. La unidad por defecto es decimal (kB/MB/GB) y redondea. Para cualquier cosa sobre la que tengas que razonar, forzá la unidad:

```
$ sudo parted /dev/sdc unit s print free
Model: ATA Samsung SSD 870 EVO (scsi)
Disk /dev/sdc: 3907029168s
Sector size (logical/physical): 512B/512B
Partition Table: gpt
Disk Flags: 

Number  Start       End          Size         File system  Name  Flags
        34s         2047s        2014s        Free Space
 1      2048s       1050623s     1048576s                  ESP   boot, esp
 2      1050624s    3907028991s  3905978368s                data
        3907028992s 3907029134s  143s         Free Space
```

Subcomandos útiles de `parted`: `mklabel {gpt,msdos}`, `mkpart`, `rm N`, `name N <etiqueta>`, `set N <bandera> {on,off}`, `unit {s,B,MiB,GiB,%,compact}`, `print [free|all|devices]`, `align-check {minimal,optimal} N`, `resizepart N <fin>`, `rescue <inicio> <fin>`.

**Las banderas GPT en `parted` son abstracciones sobre los GUIDs de tipo:** `esp`/`boot` → `C12A7328-…`; `bios_grub` → `21686148-…`; `lvm` → `E6D6D379-…`; `raid` → `A19D880F-…`; `swap` → `0657FD6D-…`.

### 4.6 Hacer que el kernel vea el cambio

Escribir la tabla actualiza el disco. La lista de particiones que el kernel mantiene en memoria es aparte.

```
$ sudo partprobe /dev/sdb                 # whole-table re-read (parted package)
$ sudo partx -u /dev/sdb                  # update kernel view from the on-disk table
$ sudo partx -a --nr 3 /dev/sdb           # add only partition 3
$ sudo partx -d --nr 3 /dev/sdb           # remove only partition 3
$ sudo blockdev --rereadpt /dev/sdb       # raw BLKRRPART ioctl
$ sudo udevadm settle                     # wait for /dev/ symlinks to be created

$ dmesg | tail -2
[ 8123.442110]  sdb: sdb1 sdb2 sdb3
[ 8123.501773] sdb: detected capacity change from 0 to 104857600
```

El fallo con el que te vas a encontrar:

```
$ sudo partprobe /dev/sda
Error: Partition(s) 3 on /dev/sda have been written, but we have been unable to
inform the kernel of the change, probably because it/they are in use.  As a result,
the old partition(s) will remain in use.  You should reboot now before making
further changes.
```

**La relectura de todo el disco falla si *cualquier* partición de ese disco está montada o reclamada.** `partx -a --nr N` para la única partición nueva suele tener éxito donde `partprobe` no puede, porque no toca las ocupadas. Ver §10.1 para encontrar al poseedor.

---

## 5. Elegir el sistema de archivos

### 5.1 Matriz comparativa

| | **ext2** | **ext3** | **ext4** | **XFS** | **Btrfs** | **VFAT (FAT32)** | **exFAT** |
|---|---|---|---|---|---|---|---|
| Journal | No | Sí (metadatos + datos opcional) | Sí (metadatos + datos opcional) | Sí, **solo metadatos** | Sin journal — CoW + sumas de verificación | No | No |
| Asignación | Mapas de bits de bloques | Mapas de bits de bloques | **Extents** | **Extents + árboles B+** | Extents + árboles B CoW | Cadena FAT | Mapa de bits de clústeres |
| Asignación de inodos | Estática, en el `mkfs` | Estática | Estática | **Dinámica** | Dinámica | n/a | n/a |
| Sistema de archivos máx. (bloques de 4 KiB) | 16 TiB | 16 TiB | **1 EiB** (`64bit`) | **8 EiB** | 16 EiB | ~2 TiB (sectores de 512 B) | 128 PiB |
| Archivo máx. | 2 TiB | 2 TiB | 16 TiB | 8 EiB | 16 EiB | **4 GiB − 1** | 16 EiB |
| Sumas de verificación de metadatos | No | No | Sí (`metadata_csum`) | Sí (CRC32c, v5) | Sí, **datos + metadatos** | No | No |
| Sumas de verificación de datos | No | No | No | No | **Sí** | No | No |
| Crecer en línea | Sí | Sí | **Sí** | **Sí** (`xfs_growfs`) | Sí | No | No |
| Reducir | Desmontado | Desmontado | Desmontado (`resize2fs` tras `e2fsck`) | **Nunca** | Sí, en línea | No | No |
| Snapshots | No | No | No (usar LVM/dm) | No (usar LVM/dm; tiene `reflink`) | **Snapshots nativos de subvolúmenes** | No | No |
| Permisos POSIX / ACL / xattr | Sí | Sí | Sí | Sí | Sí | **No** | **No** |
| Escalado en escrituras paralelas | Pobre | Pobre | Moderado | **Excelente** (grupos de asignación) | Moderado | n/a | n/a |
| Metadatos con muchos archivos pequeños | Bueno | Bueno | **Bueno** | Aceptable (mejor con `finobt`) | Aceptable | Pobre | Pobre |
| Tiempo de reparación en un fs grande | Largo | Largo | Largo (`e2fsck`) | **Rápido** (`xfs_repair`, pero consume mucha RAM) | Variable | Rápido | Rápido |
| Estado | Legacy | Legacy | **Predeterminado en producción** | **Predeterminado en producción** | Producción para disco único y RAID 0/1/10 | Solo interoperabilidad | Solo interoperabilidad |

**ReiserFS** — un sistema de archivos con journal de principios de los 2000, notable por el empaquetado de colas (almacenamiento eficiente de muchos archivos pequeños) y metadatos en árbol B+. Está en los objetivos de LPI solo a nivel de *conocimiento general*. Operativamente está terminado: marcado como **obsoleto en Linux 5.18** y **eliminado del kernel mainline en 6.13**. No hay razón para crear uno; si heredás uno, planificá una migración, y confirmá qué soporta realmente tu kernel en ejecución:

```
$ grep -E 'reiser|btrfs|xfs|ext4' /proc/filesystems
	ext3
	ext4
	xfs
	btrfs
```

**Btrfs** — también de nivel conocimiento general para LPIC-1, pero te lo vas a cruzar: es el predeterminado en Fedora Workstation y openSUSE, y sustenta los flujos de rollback de `snapper`. Copy-on-write, subvolúmenes y snapshots nativos, verificación integral tanto de datos como de metadatos, perfiles multidispositivo incorporados, compresión transparente, y `send`/`receive` para replicación incremental. Los perfiles RAID 5/6 todavía arrastran un write hole y **no** están listos para producción. El CoW causa fragmentación bajo cargas de sobreescritura aleatoria (bases de datos, imágenes de VM) — esos directorios necesitan `chattr +C`.

### 5.2 Modos de journaling de ext3/ext4

| Modo | Opción de montaje | Qué se registra en el journal | Garantía ante caída | Coste |
|---|---|---|---|---|
| **Ordered** (por defecto) | `data=ordered` | Solo metadatos; los bloques de datos se fuerzan a disco *antes* del commit de metadatos | Sin exposición de bloques obsoletos; un archivo puede perder contenido reciente pero nunca muestra los datos viejos de otro archivo | Base de referencia |
| **Journal** | `data=journal` | **Metadatos y datos**, ambos escritos dos veces | La más fuerte; sobrevive a una caída a mitad de escritura con datos consistentes | Hasta 2× de amplificación de escritura; deshabilita `O_DIRECT` y la asignación diferida |
| **Writeback** | `data=writeback` | Solo metadatos; los datos se escriben cuando sea | Los metadatos quedan consistentes pero un archivo puede exponer **bloques obsoletos** — potencialmente datos borrados de otro usuario | El más rápido; una consideración de seguridad en hosts multiinquilino |

XFS registra en el journal solo metadatos, siempre. No hay equivalente de `data=journal` en XFS.

### 5.3 La decisión, según la carga de trabajo

| Carga de trabajo | Elección | Razonamiento |
|---|---|---|
| Sistema de archivos raíz, servidor general | **XFS** (predeterminado en la familia RHEL) o **ext4** (predeterminado en la familia Debian) | Ambos correctos. Seguí a la distribución — la ruta probada, empaquetada y soportada. |
| `/var/lib/containers`, `/var/lib/docker` (overlayfs) | **XFS con `ftype=1`** o ext4 | overlay2 **requiere** soporte de d_type. Un XFS con `ftype=0` rompe el runtime de contenedores al arrancar. |
| E/S secuencial grande, muchos escritores en paralelo (almacén de objetos, medios, destino de backup) | **XFS** | Los grupos de asignación dan bloqueo por AG; escala con la cantidad de CPUs. |
| Millones de archivos pequeños, mucho `unlink` (spool de correo, caché) | **ext4**, o XFS con `finobt` | Las tablas de inodos estáticas y los directorios h-tree de ext4 son predecibles acá. |
| etcd / WAL de baja latencia | **ext4** o **XFS**, `noatime`, y nunca Btrfs | El CoW añade latencia de escritura impredecible a cargas WAL intensivas en fsync. |
| Escritorio / nodo que necesita rollback por snapshots | **Btrfs** | Subvolúmenes nativos + `snapper`. |
| EFI System Partition | **VFAT (FAT32)** | Impuesto por la especificación UEFI. Sin alternativa. |
| Medios extraíbles con archivos > 4 GiB, compartidos con Windows/macOS | **exFAT** | El techo de 4 GiB por archivo de FAT32 es la restricción. |
| Medios extraíbles, compatibilidad universal con firmware/embebidos | **VFAT (FAT32)** | Todo firmware y dispositivo lo lee. |
| Swap | `mkswap` | No es un sistema de archivos. |

---

## 6. Crear sistemas de archivos

### 6.1 `mkfs` es un despachador

```
$ ls /sbin/mkfs*
/sbin/mkfs  /sbin/mkfs.bfs  /sbin/mkfs.btrfs  /sbin/mkfs.cramfs  /sbin/mkfs.exfat
/sbin/mkfs.ext2  /sbin/mkfs.ext3  /sbin/mkfs.ext4  /sbin/mkfs.fat  /sbin/mkfs.minix
/sbin/mkfs.msdos  /sbin/mkfs.vfat  /sbin/mkfs.xfs
```

`mkfs -t xfs /dev/sdb1` simplemente hace `exec` de `mkfs.xfs /dev/sdb1`. `mkfs.ext2`, `mkfs.ext3` y `mkfs.ext4` son todos enlaces simbólicos a `mke2fs`, que lee el nombre con el que fue invocado para elegir los valores por defecto de `/etc/mke2fs.conf`. `mkfs.vfat`, `mkfs.msdos` y `mkdosfs` son el mismo binario `mkfs.fat`.

Formas equivalentes — reconocelas todas:

```
$ sudo mkfs -t ext4 /dev/sdb1
$ sudo mkfs.ext4 /dev/sdb1
$ sudo mke2fs -t ext4 /dev/sdb1
```

### 6.2 Empezá siempre desde un dispositivo que sabés que está limpio

```
$ sudo wipefs /dev/sdb1
DEVICE OFFSET TYPE UUID                                 LABEL
sdb1   0x438  ext4 6ae1f2b9-5d33-4a0e-9d02-5b7e7f4b6f21 data

$ sudo wipefs -a /dev/sdb1
/dev/sdb1: 2 bytes were erased at offset 0x00000438 (ext4): 53 ef
```

El desplazamiento `0x438` = 1080 en decimal, la ubicación del número mágico del superbloque ext `0xEF53`. Las firmas residuales no son cosméticas — `blkid`, `udev`, LVM y el initramfs sondean todos por firma, y una cabecera LVM o `mdraid` sobrante hará que `mkfs` falle con `Device or resource busy` después de que `udev` autoensamble el array viejo.

Sin `wipefs`, `mkfs` protesta:

```
$ sudo mkfs.xfs /dev/sdb1
mkfs.xfs: /dev/sdb1 appears to contain an existing filesystem (ext4).
mkfs.xfs: Use the -f option to force overwrite.

$ sudo mkfs.ext4 /dev/sdb1
mke2fs 1.47.0 (5-Feb-2023)
/dev/sdb1 contains a xfs file system
Proceed anyway? (y,N) 
```

### 6.3 ext4 — invocación de producción, explicada por completo

```
$ sudo mkfs.ext4 \
      -L data \
      -b 4096 \
      -i 32768 \
      -m 1 \
      -J size=256 \
      -E lazy_itable_init=0,lazy_journal_init=0,nodiscard \
      -O ^orphan_file \
      /dev/nvme1n1p3
mke2fs 1.47.0 (5-Feb-2023)
Creating filesystem with 26214400 4k blocks and 3276800 inodes
Filesystem UUID: 3f0b0c86-7f2d-4a24-9d7c-8a3c8b4a1f55
Superblock backups stored on blocks: 
	32768, 98304, 163840, 229376, 294912, 819200, 884736, 1605632, 2654208, 
	4096000, 7962624, 11239424, 20480000, 23887872

Allocating group tables: done                            
Writing inode tables: done                            
Creating journal (65536 blocks): done
Writing superblocks and filesystem accounting information: done
```

| Opción | Significado | Por qué se fija acá |
|---|---|---|
| `-L data` | Etiqueta de volumen (≤ 16 caracteres) | Permite que `fstab` use `LABEL=data`; sobrevive a la reimagen |
| `-b 4096` | Tamaño de bloque | Fijado explícitamente. La selección automática da 1024 en volúmenes pequeños, lo que limita el sistema de archivos a 16 GiB con `resize_inode` |
| `-i 32768` | **Bytes por inodo** | Un inodo por cada 32 KiB → 3 276 800 inodos en 100 GiB. El valor por defecto de 16384 duplica esa cifra. Reducir a la mitad la cantidad de inodos recupera ~800 MiB y acelera `e2fsck` |
| `-m 1` | Bloques reservados para root, en porcentaje | El 5 % por defecto = 5 GiB desperdiciados en un volumen de datos de 100 GiB. Mantené el **5 % en `/` y `/var`** (es lo que permite que root inicie sesión y rote logs cuando se llena el disco); bajá a 0–1 % en volúmenes de datos puros |
| `-J size=256` | Tamaño del journal, en MiB | Fijado por previsibilidad; el valor por defecto escala con el tamaño del volumen y varía entre versiones de `e2fsprogs` |
| `-E lazy_itable_init=0` | Escribir las tablas de inodos ahora | El valor por defecto `1` difiere el puesta a cero a un hilo del kernel después del primer montaje — E/S de fondo invisible que arruina el primer benchmark y la primera hora de producción |
| `-E nodiscard` | No emitir TRIM | En un LUN SAN con aprovisionamiento fino o un SSD grande, la pasada de descarte puede añadir muchos minutos al `mkfs`. Salteala si el volumen ya es fino/nuevo |
| `-O ^orphan_file` | Deshabilitar una característica | `e2fsprogs` 1.47 activa `orphan_file` por defecto; los kernels anteriores a 5.15 se niegan a montarlo. Necesario cuando el host de construcción es más nuevo que la flota |

Otras opciones que conviene conocer:

| Opción | Efecto |
|---|---|
| `-N <n>` | Cantidad absoluta de inodos (en lugar de la proporción `-i`) |
| `-U <uuid\|random\|clear>` | Fijar el UUID del sistema de archivos en la creación |
| `-T <type>` | Usar un perfil de uso de `/etc/mke2fs.conf`: `small`, `floppy`, `big`, `huge`, `largefile` (1 inodo/MiB), `largefile4` (1 inodo/4 MiB), `news` |
| `-c` / `-cc` | Escaneo de bloques defectuosos mediante `badblocks`, solo lectura / lectura-escritura. Muy lento; solo para medios sospechosos |
| `-n` | **Simulación** — imprime lo que haría y, sobre todo, dónde están los superbloques de respaldo |
| `-E stride=,stripe_width=` | Geometría RAID en bloques del sistema de archivos (§6.5) |
| `-F` | Forzar (dispositivo completo, dispositivo montado, discrepancia de tamaño) |

La simulación es tu mapa de recuperación — capturala en el momento de la construcción:

```
$ sudo mkfs.ext4 -n /dev/nvme1n1p3
mke2fs 1.47.0 (5-Feb-2023)
Creating filesystem with 26214400 4k blocks and 3276800 inodes
Filesystem UUID: 00000000-0000-0000-0000-000000000000
Superblock backups stored on blocks: 
	32768, 98304, 163840, 229376, 294912, 819200, 884736, 1605632, 2654208, 
	4096000, 7962624, 11239424, 20480000, 23887872
```

Con el superbloque primario destruido: `e2fsck -b 32768 -B 4096 /dev/nvme1n1p3`.

Verificación:

```
$ sudo dumpe2fs -h /dev/nvme1n1p3
dumpe2fs 1.47.0 (5-Feb-2023)
Filesystem volume name:   data
Last mounted on:          <not available>
Filesystem UUID:          3f0b0c86-7f2d-4a24-9d7c-8a3c8b4a1f55
Filesystem magic number:  0xEF53
Filesystem revision #:    1 (dynamic)
Filesystem features:      has_journal ext_attr resize_inode dir_index filetype
                          extent 64bit flex_bg metadata_csum metadata_csum_seed
                          sparse_super large_file huge_file dir_nlink extra_isize
Default mount options:    user_xattr acl
Filesystem state:         clean
Errors behavior:          Continue
Filesystem OS type:       Linux
Inode count:              3276800
Block count:              26214400
Reserved block count:     262144
Free blocks:              25682089
Free inodes:              3276789
First block:              0
Block size:               4096
Fragment size:            4096
Group descriptor size:    64
Reserved GDT blocks:      1024
Blocks per group:         32768
Fragments per group:      32768
Inodes per group:         4096
Inode blocks per group:   256
Flex block group size:    16
Filesystem created:       Wed Aug 26 09:14:02 2026
Mount count:              0
Maximum mount count:      -1
Check interval:           0 (<none>)
Lifetime writes:          412 MB
Reserved blocks uid:      0 (user root)
Reserved blocks gid:      0 (group root)
First inode:              11
Inode size:               256
Journal inode:            8
Default directory hash:   half_md4
Journal backup:           inode blocks
Checksum type:            crc32c
Journal features:         (none)
Total journal size:       256M
```

Cada número es comprobable: 26 214 400 bloques ÷ 32 768 por grupo = 800 grupos; 3 276 800 inodos ÷ 800 = 4 096 por grupo; `-m 1` × 26 214 400 = 262 144 bloques reservados. Si esto no coincide con tu intención, te enterás ahora — no después de que los datos ya estén encima.

### 6.4 XFS

```
$ sudo mkfs.xfs -f -L srv -i size=512 -m reflink=1,crc=1 -l size=512m /dev/nvme1n1p4
meta-data=/dev/nvme1n1p4         isize=512    agcount=4, agsize=6553600 blks
         =                       sectsz=512   attr=2, projid32bit=1
         =                       crc=1        finobt=1, sparse=1, rmapbt=0
         =                       reflink=1    bigtime=1 inobtcount=1 nrext64=1
data     =                       bsize=4096   blocks=26214400, imaxpct=25
         =                       sunit=0      swidth=0 blks
naming   =version 2              bsize=4096   ascii-ci=0, ftype=1
log      =internal log           bsize=4096   blocks=131072, version=2
         =                       sectsz=512   sunit=0 blks, lazy-count=1
realtime =none                   extsz=4096   blocks=0, rtextents=0
Discarding blocks...Done.
```

Leer esa salida es una habilidad central de SRE:

| Línea | Campo | Significado |
|---|---|---|
| `meta-data` | `agcount=4, agsize=6553600` | Cuatro **grupos de asignación**, de 25 GiB cada uno. Los AG son la unidad de paralelismo — cada uno tiene sus propios árboles B+ de espacio libre y su propio bloqueo. Más AGs = más asignación concurrente, más sobrecarga de metadatos. No fuerces `agcount` por encima de ~32 sin una razón medida |
| | `isize=512` | Tamaño de inodo. 512 permite que más atributos extendidos (etiquetas SELinux, ACLs) vivan en línea en vez de en un bloque aparte |
| | `crc=1` | Superbloque v5, CRC32c en todos los metadatos. No negociable |
| | `reflink=1` | Extents compartidos con copy-on-write — `cp --reflink`, capas de imágenes de contenedores, snapshots baratos de archivos |
| | `nrext64=1` | Contadores de extents de 64 bits (`xfsprogs` ≥ 6.0). **Los kernels < 5.19 no pueden montar esto.** Deshabilitalo con `-i nrext64=0` cuando la flota destino sea más vieja |
| `data` | `bsize=4096, blocks=26214400` | 100 GiB. `bsize` no puede exceder el tamaño de página (4 KiB en x86-64) |
| | `imaxpct=25` | Proporción máxima del espacio que pueden consumir los inodos. XFS asigna inodos dinámicamente, así que esto es un techo, no una reserva |
| | `sunit=0 swidth=0` | No se detectó geometría de stripe — correcto para una partición simple, **incorrecto en un LUN RAID** |
| `naming` | `ftype=1` | d_type en las entradas de directorio. **overlayfs y los runtimes de contenedores lo requieren.** Predeterminado desde `xfsprogs` 3.2.3; un sistema de archivos creado antes de eso con `ftype=0` no se puede arreglar in situ |
| `log` | `internal log, blocks=131072` | Journal de 512 MiB dentro de la sección de datos. `-l logdev=/dev/nvmeXn1` lo pone en un dispositivo rápido aparte para cargas intensivas en metadatos |

Volvé a leer la misma información en cualquier momento:

```
$ sudo xfs_info /srv
meta-data=/dev/nvme1n1p4         isize=512    agcount=4, agsize=6553600 blks
...
```

`xfs_info` requiere que el sistema de archivos esté montado (o acepta el dispositivo con versiones recientes de `xfsprogs`). No existe un equivalente de `tune2fs` para XFS en la mayoría de los parámetros — **la geometría de XFS queda fijada en el momento del `mkfs` y no se puede cambiar nunca.** Eso incluye el tamaño de bloque, el tamaño de sector, `ftype`, `crc`, `reflink`, el tamaño y la ubicación del log, y la imposibilidad de reducir. Precisamente por eso la línea de comandos de `mkfs.xfs` merece una revisión antes de ejecutarse.

### 6.5 Creación consciente del stripe en RAID y SAN

La aplicación de producción más valiosa de este objetivo. Dado un RAID 5 de `mdadm` con chunk de 64 KiB sobre 5 dispositivos (4 de datos + 1 de paridad):

```
$ cat /proc/mdstat
Personalities : [raid6] [raid5] [raid4] 
md0 : active raid5 sde[4] sdd[3] sdc[2] sdb[1] sda[0]
      7813771264 blocks super 1.2 level 5, 64k chunk, algorithm 2 [5/5] [UUUUU]
```

- **unidad de stripe (su)** = chunk = 64 KiB
- **ancho de stripe (sw)** = cantidad de miembros de *datos* = 4

XFS los toma directamente:

```
$ sudo mkfs.xfs -f -L bulk -d su=64k,sw=4 -l size=512m /dev/md0
meta-data=/dev/md0               isize=512    agcount=32, agsize=61045248 blks
         =                       sectsz=4096  attr=2, projid32bit=1
         =                       crc=1        finobt=1, sparse=1, rmapbt=0
         =                       reflink=1    bigtime=1 inobtcount=1 nrext64=1
data     =                       bsize=4096   blocks=1953442816, imaxpct=5
         =                       sunit=16     swidth=64 blks
naming   =version 2              bsize=4096   ascii-ci=0, ftype=1
log      =internal log           bsize=4096   blocks=131072, version=2
         =                       sectsz=4096  sunit=1 blks, lazy-count=1
realtime =none                   extsz=4096   blocks=0, rtextents=0
```

`sunit=16 swidth=64 blks` — 64 KiB ÷ 4 KiB = 16 bloques, × 4 miembros = 64 bloques. Confirmado.

ext4 usa el mismo concepto con nombres distintos, expresados en **bloques del sistema de archivos**:

```
$ sudo mkfs.ext4 -b 4096 -E stride=16,stripe_width=64 -L bulk /dev/md0
```

`stride = chunk / tamaño_de_bloque`; `stripe_width = stride × discos_de_datos`.

`mkfs` lee `optimal_io_size` de sysfs y normalmente deriva estos valores automáticamente para dispositivos `md`. Por lo general **no puede** hacerlo para controladoras RAID por hardware o LUNs SAN, que informan `optimal_io_size=0`. En esos casos, tenés que obtener la geometría de la herramienta de gestión del array y pasarla a mano. Equivocarse significa que cada actualización de paridad se convierte en un read-modify-write, y lo vas a ver como amplificación de escritura sin ningún error en ninguna parte.

### 6.6 VFAT

```
$ sudo mkfs.vfat -F 32 -n ESP -v /dev/nvme1n1p1
mkfs.fat 4.2 (2021-01-31)
/dev/nvme1n1p1 has 255 heads and 63 sectors per track,
hidden sectors 0x0800;
logical sector size is 512,
using 0xf8 media descriptor, with 2097152 sectors;
drive number 0x80;
filesystem has 2 32-bit FATs and 8 sectors per cluster.
FAT size is 2048 sectors, and provides 261628 clusters.
There are 32 reserved sectors.
Volume ID is 3a7c1f22, volume label ESP        .
```

| Opción | Significado |
|---|---|
| `-F {12,16,32}` | Ancho de FAT. **Especificalo siempre.** La selección automática elige FAT16 en volúmenes pequeños, y el firmware UEFI en discos fijos espera FAT32 |
| `-n <etiqueta>` | Etiqueta de volumen — **11 caracteres, en mayúsculas**. `blkid` la informa como `LABEL` |
| `-s <n>` | Sectores por clúster |
| `-S <n>` | Tamaño de sector lógico |
| `-v` | Detallado |
| `-c` | Comprobación de bloques defectuosos |
| `-i <id>` | Fijar el ID de volumen de 32 bits (`blkid` lo muestra como el `UUID`, con formato `3A7C-1F22`) |

FAT no tiene modelo de propiedad ni de permisos. El control de acceso viene únicamente de las opciones de montaje:

```
UUID=3A7C-1F22  /boot/efi  vfat  umask=0077,shortname=winnt,utf8,fmask=0177,dmask=0077  0 2
```

`umask=0077` es lo que impide que una ESP legible por todo el mundo — que contiene la configuración de tu gestor de arranque y binarios firmados — sea legible por cualquier usuario.

Verificación (`fsck.fat` es la única herramienta; no hay equivalente de `dumpe2fs`):

```
$ sudo fsck.fat -v -n /dev/nvme1n1p1
fsck.fat 4.2 (2021-01-31)
Checking we can access the last sector of the filesystem
Boot sector contents:
System ID "mkfs.fat"
Media byte 0xf8 (hard disk)
       512 bytes per logical sector
      4096 bytes per cluster
        32 reserved sectors
First FAT starts at byte 16384 (sector 32)
         2 FATs, 32 bit entries
   1048576 bytes per FAT (= 2048 sectors)
Root directory start at cluster 2 (arbitrary size)
Data area starts at byte 2113536 (sector 4128)
    261628 data clusters (1071628288 bytes)
63 sectors/track, 255 heads
      2048 hidden sectors
   2097152 sectors total
Checking for unused clusters.
/dev/nvme1n1p1: 0 files, 0/261628 clusters
```

### 6.7 exFAT

El controlador `fs/exfat` de Linux llegó en el kernel 5.7 (una versión en staging en 5.4); las herramientas de espacio de usuario son `exfatprogs`.

```
$ sudo mkfs.exfat -L FIELDKIT -c 128K /dev/sdd1
exfatprogs version : 1.2.2
Creating exFAT filesystem(/dev/sdd1, cluster size=131072)

Writing volume boot record: done
Writing backup volume boot record: done
Fat table creation: done
Allocation bitmap creation: done
Upcase table creation: done
Writing root directory entry: done
Synchronizing...

exFAT format complete!
```

| Opción | Significado |
|---|---|
| `-L <etiqueta>` | Etiqueta de volumen (hasta 15 caracteres UTF-16 — a diferencia de FAT, se admiten mayúsculas y minúsculas) |
| `-c <tamaño>` | Tamaño de clúster. Los valores grandes (128 K–1 M) sirven para archivos secuenciales grandes en flash; los valores pequeños desperdician menos con archivos chicos |
| `-b <tamaño>` | Alineación de frontera, para coincidir con el tamaño del bloque de borrado de la flash |
| `-f` | Forzar |

Elegí exFAT sobre VFAT cuando un único archivo supere los 4 GiB — metraje de cámara, imágenes de disco, archivos de backup — y se requiera compatibilidad entre sistemas operativos. Elegí VFAT cuando importe más la compatibilidad con firmware antiguo. **Ninguno de los dos es jamás la elección correcta para el sistema de archivos de un servidor Linux**: sin journal, sin permisos, sin xattr, sin ACL y sin resiliencia ante caídas.

### 6.8 Btrfs (nivel de conocimiento general)

```
$ sudo mkfs.btrfs -L pool0 -d raid1 -m raid1 /dev/sdb /dev/sdc
btrfs-progs v6.6.3
See https://btrfs.readthedocs.io for more information.

NOTE: several default settings have changed in version 5.15, please make sure
      this does not affect your deployments:
      - DUP for metadata (-m dup)
      - enabled no-holes (-O no-holes)
      - enabled free-space-tree (-R free-space-tree)

Label:              pool0
UUID:               f4b2a1c9-6d5e-4b3a-9f7c-2a8e1d0b3c47
Node size:          16384
Sector size:        4096
Filesystem size:    7.28TiB
Block group profiles:
  Data:             RAID1           1.00GiB
  Metadata:         RAID1           1.00GiB
  System:           RAID1           8.00MiB
SSD detected:       no
Zoned device:       no
Checksum:           crc32c
Number of devices:  2
Devices:
   ID        SIZE  PATH
    1     3.64TiB  /dev/sdb
    2     3.64TiB  /dev/sdc
```

Notá que `mkfs.btrfs` acepta **múltiples dispositivos** — Btrfs absorbe la capa de gestión de volúmenes, que es la diferencia arquitectónica con ext4/XFS (donde LVM o `md` se ubican por debajo).

---

## 7. Swap

El espacio de swap no es un sistema de archivos. `mkswap` escribe una cabecera de una página y nada más.

### 7.1 Partición de swap

```
$ sudo mkswap -L swap0 /dev/nvme1n1p2
Setting up swapspace version 1, size = 8 GiB (8589930496 bytes)
LABEL=swap0, UUID=1f4a2b6d-9c3e-4e08-b4a1-2f7a0d6c5e13

$ sudo swapon --priority 10 /dev/nvme1n1p2

$ swapon --show
NAME               TYPE      SIZE USED PRIO
/dev/nvme1n1p2 partition       8G   0B   10

$ free -h
               total        used        free      shared  buff/cache   available
Mem:            31Gi       2.1Gi        27Gi       9.0Mi       2.3Gi        28Gi
Swap:          8.0Gi          0B       8.0Gi
```

`8589930496` = 8 GiB menos exactamente 4096 bytes: la cabecera de swap ocupa una página.

| Opción | Significado |
|---|---|
| `-L <etiqueta>` | Etiqueta, para `LABEL=` en `fstab` |
| `-U <uuid>` | UUID explícito |
| `-c` | Comprobar bloques defectuosos primero |
| `-p <tamaño>` | Tamaño de página — solo relevante al preparar swap para otra arquitectura |
| `-f` | Forzar (p. ej. tamaño mayor que el dispositivo, disco completo) |

**La prioridad importa en un host con medios mixtos.** Prioridades iguales van por turnos (repartiendo entre dispositivos); la prioridad más alta se consume primero. Poné el swap NVMe en `pri=10` y el swap en disco rotativo en `pri=1` y el kernel vaciará primero el dispositivo rápido.

### 7.2 Archivo de swap

```
$ sudo dd if=/dev/zero of=/swapfile bs=1M count=8192 status=progress
8589934592 bytes (8.6 GB, 8.0 GiB) copied, 12 s, 716 MB/s
8192+0 records in
8192+0 records out
8589934592 bytes (8.6 GB, 8.0 GiB) copied, 12.0114 s, 715 MB/s

$ sudo chmod 600 /swapfile
$ sudo mkswap /swapfile
Setting up swapspace version 1, size = 8 GiB (8589930496 bytes)
no label, UUID=b2c7e4a1-8f39-4d5c-a0e2-1c6b9f3d7a84

$ sudo swapon /swapfile
```

Tres trampas específicas del sistema de archivos:

- **XFS:** `fallocate` produce extents *no escritos*, que `swapon` rechaza. Usá `dd`. Síntoma: `swapon: /swapfile: swapon failed: Invalid argument`.
- **Btrfs:** requiere kernel ≥ 5.0, el archivo debe ser NOCOW (`chattr +C` sobre un archivo *vacío*, o creado en un directorio NOCOW), sin comprimir, y no estar en un perfil multidispositivo.
- **Permisos:** cualquier cosa distinta de `0600` filtra el contenido de la memoria a cualquier usuario que pueda leer el archivo.

```
$ sudo swapon /swapfile
swapon: /swapfile: insecure permissions 0644, 0600 suggested.
```

### 7.3 Hacerlo persistente

```
# /etc/fstab
UUID=1f4a2b6d-9c3e-4e08-b4a1-2f7a0d6c5e13  none  swap  sw,pri=10  0 0
/swapfile                                  none  swap  sw,pri=1   0 0
```

```
$ sudo swapoff -a          # deactivate everything
$ sudo swapon -a           # activate everything from fstab
$ sudo swapon --verbose --show=NAME,TYPE,SIZE,USED,PRIO
NAME               TYPE      SIZE USED PRIO
/dev/nvme1n1p2 partition       8G   0B   10
/swapfile           file       8G   0B    1
```

---

## 8. Infraestructura como código

Las sesiones interactivas de arriba enseñan la mecánica. En una flota, ninguna de ellas debería ser tecleada por una persona. Los cuatro manifiestos siguientes expresan el mismo diseño de forma declarativa e idempotente.

### 8.1 cloud-init — preparación de disco en el primer arranque

```yaml
#cloud-config
# /var/lib/cloud/seed/nocloud/user-data
# Partitions and formats the secondary data volume on first boot only.
# Idempotent: `overwrite: false` makes every stage a no-op if the
# structure already exists, so a re-run after a rescue boot is safe.

device_aliases:
  datavol: /dev/nvme1n1

disk_setup:
  datavol:
    table_type: gpt
    # Percentages of total capacity; the optional second element is the
    # MBR-style type id, translated to the matching GPT type GUID.
    layout:
      - [10, 82]     # 10% -> Linux swap        (0657FD6D-A4AB-43C4-84E5-0933C84B4F4F)
      - [90, 83]     # 90% -> Linux filesystem  (0FC63DAF-8483-4772-8E79-3D69D8477DE4)
    overwrite: false

fs_setup:
  - label: swap0
    filesystem: swap
    device: datavol.1
    overwrite: false

  - label: srv
    filesystem: xfs
    device: datavol.2
    # Passed verbatim to mkfs.xfs. nrext64=0 keeps the volume mountable
    # by the 5.14 kernels still present in the older node pool.
    extra_opts:
      - "-L"
      - "srv"
      - "-i"
      - "size=512,nrext64=0"
      - "-m"
      - "crc=1,reflink=1"
      - "-l"
      - "size=512m"
    overwrite: false

mounts:
  - ["LABEL=srv",   "/srv", "xfs",  "defaults,noatime,inode64,nofail,x-systemd.device-timeout=30s", "0", "2"]
  - ["LABEL=swap0", "none", "swap", "sw,pri=10", "0", "0"]

mount_default_fields: [None, None, "auto", "defaults,nofail", "0", "2"]

runcmd:
  # Fail the boot loudly rather than starting a node with no data volume.
  - ["systemctl", "--no-pager", "--failed"]
  - ["findmnt", "--verify", "--verbose"]
```

### 8.2 Butane / Ignition — aprovisionamiento de SO inmutable (Fedora CoreOS, RHCOS, Flatcar)

```yaml
variant: fcos
version: 1.5.0

storage:
  disks:
    - device: /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol0a1b2c3d4e5f6
      # Ignition refuses to touch a disk whose layout already matches,
      # which is what makes re-running the config safe.
      wipe_table: false
      partitions:
        - label: containers
          number: 1
          size_mib: 262144          # 256 GiB
          start_mib: 0              # first aligned free sector
          type_guid: 0FC63DAF-8483-4772-8E79-3D69D8477DE4
          wipe_partition_entry: false

        - label: etcd
          number: 2
          size_mib: 32768           # 32 GiB
          start_mib: 0
          type_guid: 0FC63DAF-8483-4772-8E79-3D69D8477DE4
          wipe_partition_entry: false

  filesystems:
    - device: /dev/disk/by-partlabel/containers
      format: xfs
      label: containers
      wipe_filesystem: false
      # `options` are mkfs options. ftype=1 is implicit in modern xfsprogs
      # but overlayfs hard-depends on it, so it is asserted explicitly.
      options:
        - "-L"
        - "containers"
        - "-n"
        - "ftype=1"
        - "-i"
        - "size=512"
        - "-m"
        - "reflink=1"
      with_mount_unit: true
      path: /var/lib/containers
      mount_options:
        - noatime
        - inode64
        - prjquota

    - device: /dev/disk/by-partlabel/etcd
      format: ext4
      label: etcd
      wipe_filesystem: false
      options:
        - "-L"
        - "etcd"
        - "-m"
        - "0"
        - "-E"
        - "lazy_itable_init=0,lazy_journal_init=0"
      with_mount_unit: true
      path: /var/lib/etcd
      mount_options:
        - noatime
        - data=ordered

systemd:
  units:
    - name: var-lib-containers.mount
      enabled: true
    - name: var-lib-etcd.mount
      enabled: true

    - name: verify-storage.service
      enabled: true
      contents: |
        [Unit]
        Description=Assert storage layout before the kubelet starts
        After=var-lib-containers.mount var-lib-etcd.mount
        Requires=var-lib-containers.mount var-lib-etcd.mount
        Before=kubelet.service

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/bin/bash -c 'xfs_info /var/lib/containers | grep -q "ftype=1"'
        ExecStart=/usr/bin/findmnt --verify --verbose
        ExecStart=/usr/bin/findmnt -no FSTYPE /var/lib/etcd

        [Install]
        WantedBy=multi-user.target
```

Compilar y aplicar:

```
$ butane --pretty --strict node.bu --output node.ign
$ ignition-validate node.ign
```

### 8.3 systemd-repart — GPT declarativa y expansible

`systemd-repart` reconcilia un disco contra un conjunto de archivos `.conf` en cada arranque: crea lo que falta, agranda lo que quedó chico, y no hace nada cuando el disco ya coincide. Así es como una única imagen dorada se adapta a nodos de 100 GiB y de 4 TiB sin ninguna lógica de imagen.

```ini
# /etc/repart.d/10-esp.conf
[Partition]
Type=esp
Label=ESP
Format=vfat
SizeMinBytes=512M
SizeMaxBytes=512M
```

```ini
# /etc/repart.d/50-root.conf
[Partition]
Type=root
Label=root
Format=xfs
SizeMinBytes=16G
SizeMaxBytes=64G
FactoryReset=no
```

```ini
# /etc/repart.d/70-var.conf
[Partition]
Type=var
Label=var
Format=xfs
# Take all remaining space; weight decides the split when several
# partitions compete for the free area.
Weight=1000
SizeMinBytes=8G
Encrypt=off
```

```ini
# /etc/repart.d/80-swap.conf
[Partition]
Type=swap
Label=swap0
Format=swap
SizeMinBytes=4G
SizeMaxBytes=8G
```

```
$ sudo systemd-repart --dry-run=yes --empty=allow /dev/nvme0n1
Determined sector size 512 by probing /dev/nvme0n1.

  ✓ Partition  Type   Label  UUID       File           Node          Old Size  New Size
  + (new)      esp    ESP    …a1b2c3d4  10-esp.conf    /dev/nvme0n1p1        -    512.0M
  + (new)      root   root   …e5f60718  50-root.conf   /dev/nvme0n1p2        -     64.0G
  + (new)      swap   swap0  …293a4b5c  80-swap.conf   /dev/nvme0n1p4        -      8.0G
  + (new)      var    var    …6d7e8f90  70-var.conf    /dev/nvme0n1p3        -    855.5G

$ sudo systemd-repart --dry-run=no /dev/nvme0n1
```

Como `Type=root`/`var`/`esp` se corresponden con los GUIDs de la Discoverable Partitions Specification, `systemd-gpt-auto-generator` los monta **sin ninguna entrada en `/etc/fstab`** — eliminando por completo la clase de fallo "un error de tipeo en fstab deja el sistema sin arrancar".

### 8.4 Ansible — convergencia de la flota

```yaml
---
- name: Provision the data volume on storage nodes
  hosts: storage_nodes
  become: true
  gather_facts: true

  vars:
    data_disk: /dev/nvme1n1
    data_part: /dev/nvme1n1p1
    data_mount: /var/lib/data
    # Oldest kernel in the fleet; drives mkfs feature selection.
    min_kernel: "5.14"

  tasks:
    - name: Refuse to run against a disk that already holds a mounted filesystem
      ansible.builtin.command:
        cmd: "lsblk -no MOUNTPOINT {{ data_disk }}"
      register: disk_mounts
      changed_when: false

    - name: Abort if anything on the target disk is mounted
      ansible.builtin.assert:
        that:
          - disk_mounts.stdout | trim | length == 0
        fail_msg: >-
          {{ data_disk }} has mounted partitions; refusing to repartition.
          Mounted at: {{ disk_mounts.stdout | trim }}

    - name: Create the GPT label and a single optimally aligned data partition
      community.general.parted:
        device: "{{ data_disk }}"
        label: gpt
        number: 1
        name: data
        part_start: 1MiB
        part_end: "100%"
        align: optimal
        state: present
      register: part_result

    - name: Wait for udev to publish the partition node
      ansible.builtin.command:
        cmd: udevadm settle --timeout=30
      changed_when: false
      when: part_result is changed

    - name: Assert optimal alignment before committing a filesystem to it
      ansible.builtin.command:
        cmd: "parted -s {{ data_disk }} align-check optimal 1"
      register: align
      changed_when: false
      failed_when: "'aligned' not in align.stdout or 'not aligned' in align.stdout"

    - name: Create the XFS filesystem
      community.general.filesystem:
        dev: "{{ data_part }}"
        fstype: xfs
        # nrext64=0 keeps the volume mountable by the oldest fleet kernel.
        opts: >-
          -L data
          -i size=512,nrext64=0
          -m crc=1,reflink=1
          -n ftype=1
          -l size=512m
        state: present
      register: mkfs_result

    - name: Read back the filesystem UUID
      ansible.builtin.command:
        cmd: "blkid -s UUID -o value {{ data_part }}"
      register: fs_uuid
      changed_when: false

    - name: Mount by UUID and persist in /etc/fstab
      ansible.posix.mount:
        path: "{{ data_mount }}"
        src: "UUID={{ fs_uuid.stdout | trim }}"
        fstype: xfs
        opts: noatime,inode64,prjquota,nofail,x-systemd.device-timeout=30s
        dump: "0"
        passno: "0"        # XFS has no boot-time fsck; passno must be 0
        state: mounted

    - name: Verify that /etc/fstab is internally consistent
      ansible.builtin.command:
        cmd: findmnt --verify --verbose
      register: fstab_check
      changed_when: false
      failed_when: fstab_check.rc != 0

    - name: Confirm ftype=1 — overlayfs will not start without it
      ansible.builtin.command:
        cmd: "xfs_info {{ data_mount }}"
      register: xfsinfo
      changed_when: false
      failed_when: "'ftype=1' not in xfsinfo.stdout"

    - name: Report the final geometry
      ansible.builtin.debug:
        msg: "{{ xfsinfo.stdout_lines }}"
```

### 8.5 Dónde aterriza esto en Kubernetes

Los PersistentVolumes locales son el punto donde el particionado a nivel de nodo se vuelve visible para el clúster. El plugin de volumen `local` **no tiene aprovisionador** — el sistema de archivos creado en §6 y montado por §8.2 *es* el volumen.

```yaml
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-nvme
provisioner: kubernetes.io/no-provisioner
# The scheduler must place the Pod before the PV is bound, because the
# volume exists on exactly one node and cannot move.
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
allowVolumeExpansion: false
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: local-nvme-node01-0
  labels:
    node: node01
    media: nvme
spec:
  capacity:
    storage: 930Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-nvme
  local:
    # Created by the node bootstrap: sgdisk -> mkfs.xfs -> systemd .mount unit.
    # The kubelet will not create this path; it must already be a mount point.
    path: /mnt/disks/nvme1n1p1
    fsType: xfs
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - node01
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: etcd-data
  namespace: infra
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-nvme
  resources:
    requests:
      storage: 900Gi
```

Si `/mnt/disks/nvme1n1p1` es un directorio común en el sistema de archivos raíz en vez de un punto de montaje, el Pod arranca, escribe, llena `/` y tira abajo el nodo — exactamente el fallo de §1.1. Verificá el montaje, no el directorio:

```
$ findmnt --target /mnt/disks/nvme1n1p1 --json
{
   "filesystems": [
      {
         "target": "/mnt/disks/nvme1n1p1",
         "source": "/dev/nvme1n1p1",
         "fstype": "xfs",
         "options": "rw,noatime,attr2,inode64,logbufs=8,logbsize=32k,prjquota,noquota"
      }
   ]
}
```

---

## 9. La escalera de verificación

Ejecutá esto en orden. Cada peldaño prueba algo que el anterior no prueba.

**Peldaño 1 — la tabla de particiones es la que escribiste**

```
$ sudo sfdisk -V /dev/nvme1n1
/dev/nvme1n1: 
OK

$ sudo sgdisk -v /dev/nvme1n1
No problems found. 2014 free sectors (1007.0 KiB) available in 1
segments, the largest of which is 2014 (1007.0 KiB) in size.

$ sudo partx -s /dev/nvme1n1
NR    START        END    SECTORS  SIZE NAME
 1     2048    2099199    2097152    1G ESP
 2  2099200    2101247       2048    1M BIOSboot
 3  2101248 2147483614 2145382367 1023G pv0
```

**Peldaño 2 — el kernel coincide con el disco**

```
$ lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,PARTUUID,PARTLABEL,MOUNTPOINT /dev/nvme1n1
NAME        SIZE TYPE FSTYPE LABEL UUID                                 PARTUUID                             PARTLABEL MOUNTPOINT
nvme1n1    1024G disk                                                                                                  
├─nvme1n1p1   1G part vfat   ESP   3A7C-1F22                            8f2c1a04-…-1d6e3b9a7c05              ESP       /boot/efi
├─nvme1n1p2   1M part                                                   b71e5d92-…-4a0c8e2f6d13              BIOSboot  
└─nvme1n1p3 1023G part LVM2_m…      Wq3nT9-…-8fJ2Kd                     c04a7e18-…-9b5f2c7a1e60              pv0       
```

Una partición que existe en `sfdisk -V` pero falta en `lsblk` significa que el kernel nunca releyó la tabla (§4.6).

**Peldaño 3 — alineación**

```
$ for n in 1 2 3; do
>   printf 'part %s: ' "$n"
>   sudo parted -s /dev/nvme1n1 align-check optimal "$n"
> done
part 1: 1 aligned
part 2: 2 aligned
part 3: 3 aligned
```

**Peldaño 4 — el sistema de archivos es el que especificaste**

```
$ sudo dumpe2fs -h /dev/nvme1n1p3 2>/dev/null | grep -E 'Block size|Inode count|Reserved block|features'
$ sudo xfs_info /srv | grep -E 'ftype|crc|reflink|sunit|swidth|nrext64'
$ sudo fsck.fat -v -n /dev/nvme1n1p1
```

**Peldaño 5 — se lo direcciona de forma estable**

```
$ blkid /dev/nvme1n1p1 /dev/nvme1n1p3
/dev/nvme1n1p1: LABEL_FATBOOT="ESP" LABEL="ESP" UUID="3A7C-1F22" BLOCK_SIZE="512" TYPE="vfat" PARTLABEL="ESP" PARTUUID="8f2c1a04-3b57-4f81-9a2d-1d6e3b9a7c05"
/dev/nvme1n1p3: LABEL="data" UUID="3f0b0c86-7f2d-4a24-9d7c-8a3c8b4a1f55" BLOCK_SIZE="4096" TYPE="xfs" PARTLABEL="pv0" PARTUUID="c04a7e18-2f93-4d6b-8e15-9b5f2c7a1e60"

$ ls -l /dev/disk/by-uuid/ /dev/disk/by-partuuid/
```

| Árbol de enlaces simbólicos | Estable frente a | Usar para |
|---|---|---|
| `/dev/disk/by-uuid/` | Recableado, cambios de controladora, reordenamiento del kernel | Entradas de sistemas de archivos en `fstab` |
| `/dev/disk/by-label/` | Lo mismo, pero colisiona si dos volúmenes comparten etiqueta | `fstab` legible por humanos |
| `/dev/disk/by-partuuid/` | Todo excepto `mkfs`/reparticionado | Particiones crudas: LUKS, PV, OSD de Ceph |
| `/dev/disk/by-partlabel/` | Igual que PARTUUID; solo GPT | Destinos de Ignition/Butane |
| `/dev/disk/by-id/` | Reinicios; codifica fabricante + número de serie | Identificar el dispositivo *físico* en un chasis |
| `/dev/disk/by-path/` | Topología de ranuras, no el dispositivo | "¿Qué bahía es esta?" |
| `/dev/sdX` | **Nada** | Nunca en `fstab` |

**Peldaño 6 — el arranque no se va a romper**

```
$ findmnt --verify --verbose
/
   [ ] target exists
   [ ] FS type is xfs
   [ ] source /dev/mapper/vg0-root exists
/boot/efi
   [ ] target exists
   [ ] FS type is vfat
   [ ] UUID=3A7C-1F22 translated to /dev/nvme1n1p1
   [ ] source /dev/nvme1n1p1 exists

Success, no errors or warnings detected
```

Este es el comando más importante después de editar `/etc/fstab`. `mount -a` solo prueba que montan las entradas *actualmente alcanzables*; `findmnt --verify` revisa todo el archivo, incluidas las opciones y el `passno`.

**Peldaño 7 — una escritura real sobrevive a un ciclo real**

```
$ sudo mount /dev/nvme1n1p3 /srv && \
  sudo dd if=/dev/urandom of=/srv/canary bs=1M count=64 conv=fsync && \
  sha256sum /srv/canary | sudo tee /srv/canary.sha && \
  sudo umount /srv && sudo mount /dev/nvme1n1p3 /srv && \
  sha256sum -c /srv/canary.sha
/srv/canary: OK
```

---

## 10. Manual de diagnóstico de fallos

### 10.1 `Device or resource busy` — `mkfs` o `partprobe` se niega

```
$ sudo mkfs.xfs -f /dev/sdb1
mkfs.xfs: cannot open /dev/sdb1: Device or resource busy
```

Recorré la cadena de poseedores de arriba hacia abajo:

```
$ lsblk /dev/sdb                      # is a dm/md device stacked on it?
NAME              SIZE TYPE  MOUNTPOINTS
sdb               3.6T disk  
└─sdb1            3.6T part  
  └─md127         3.6T raid1 

$ ls /sys/class/block/sdb1/holders/   # authoritative: who claims this device
md127

$ cat /proc/mdstat
md127 : active (auto-read-only) raid1 sdb1[0]
      3906885440 blocks super 1.2 [2/1] [U_]

$ sudo mdadm --stop /dev/md127
mdadm: stopped /dev/md127
$ sudo mdadm --zero-superblock /dev/sdb1
$ sudo wipefs -a /dev/sdb1
```

La lista completa de comprobación de poseedores, en el orden que resuelve más rápido:

```
$ findmnt -S /dev/sdb1                # mounted?
$ sudo swapon --show | grep sdb1      # active swap?
$ sudo lsof /dev/sdb1                 # raw open by a process?
$ sudo fuser -vm /dev/sdb1
$ ls /sys/class/block/sdb1/holders/   # dm / md / bcache stacked above
$ sudo dmsetup ls --tree              # device-mapper stack
$ sudo cryptsetup status <name>       # LUKS mapping
$ sudo pvs; sudo vgs                  # LVM claim
$ sudo multipath -ll                  # multipath claim
```

La causa más común en un disco nuevo es que **udev autoensambló una firma de `mdraid` o LVM obsoleta que dejó la vida anterior de ese LUN**. `wipefs -a` antes de particionar lo previene por completo.

### 10.2 Particiones escritas pero no visibles

Síntoma: `sfdisk -V` dice OK, `/dev/sdb3` no existe.

```
$ sudo partx -a --nr 3 /dev/sdb       # add only the new partition
$ sudo udevadm settle
$ ls -l /dev/sdb3
brw-rw---- 1 root disk 8, 19 Aug 26 11:42 /dev/sdb3
```

Si aun así falla, el disco tiene una partición ocupada bloqueando la relectura de todo el dispositivo. Opciones en orden de escalada: `partx -a --nr N` (suele funcionar), desmontar/desactivar la partición ocupada, o reiniciar. Nunca escribas en un disco cuya vista del kernel sabés que está desactualizada — vas a calcular desplazamientos contra la tabla equivocada.

### 10.3 `Warning! Secondary header claims to be at...` — GPT tras un redimensionado o un clonado

```
$ sudo gdisk -l /dev/vda
GPT fdisk (gdisk) version 1.0.9

Warning! Disk size is smaller than the main header indicates! Loading
secondary header from the last sector of the disk! You should use 'v' to
verify disk integrity, and perhaps options on the experts' menu to repair
the disk.
Caution: invalid backup GPT header, but valid main header; regenerating
backup header from main header.

Warning! One or more CRCs don't match. You should repair the disk!
Main header: OK
Backup header: ERROR
Main partition table: OK
Backup partition table: ERROR
```

Causa: el disco virtual fue ampliado (o reducido, o clonado con dd a un destino de tamaño distinto) y la GPT de respaldo ya no está en el último LBA.

```
$ sudo sgdisk -e /dev/vda          # relocate backup structures to the end of the disk
Warning: The kernel is still using the old partition table.
The new table will be used at the next reboot or after you
run partprobe(8) or partx(8)
The operation has completed successfully.

$ sudo sgdisk -v /dev/vda
No problems found. 41940958 free sectors (20.0 GiB) available in 1 segments,
the largest of which is 41940958 (20.0 GiB) in size.
```

`parted` ofrece la misma reparación de forma interactiva:

```
$ sudo parted /dev/vda print
Warning: Not all of the space available to /dev/vda appears to be used, you can
fix the GPT to use all of the space (an extra 41940958 blocks) or continue with
the current setting? 
Fix/Ignore? Fix
```

### 10.4 UUIDs duplicados tras clonar una plantilla de VM

Síntoma: dos nodos arrancan el mismo LUN, o `mount UUID=…` elige el dispositivo equivocado de forma no determinista.

```
$ sudo blkid | sort -t= -k3
/dev/vda2: UUID="3f0b0c86-7f2d-4a24-9d7c-8a3c8b4a1f55" TYPE="xfs"
/dev/vdb2: UUID="3f0b0c86-7f2d-4a24-9d7c-8a3c8b4a1f55" TYPE="xfs"
```

Regenerar — **únicamente sobre el clon desmontado**:

```
$ sudo sgdisk -G /dev/vdb                            # new disk GUID + all partition GUIDs
$ sudo xfs_admin -U generate /dev/vdb2               # XFS
Clearing log and setting UUID
writing all SBs
new UUID = 7c2e4a91-5b38-4f60-a1d7-3e9c0b8f2a45

$ sudo tune2fs -U random /dev/vdb3                   # ext2/3/4
tune2fs 1.47.0 (5-Feb-2023)
Setting the UUID on this filesystem could take some time.
Proceed anyway (or wait 5 seconds to proceed) ? (y,N) y

$ sudo mkswap -U random /dev/vdb1                    # swap
```

Después actualizá `/etc/fstab` y reconstruí el initramfs (`dracut -f` / `update-initramfs -u`) — el UUID viejo está incrustado ahí.

### 10.5 `No space left on device` con bloques libres — agotamiento de inodos

```
$ df -h /var/spool/mail
Filesystem      Size  Used Avail Use% Mounted on
/dev/sdb1       917G  312G  559G  36% /var/spool/mail

$ touch /var/spool/mail/test
touch: cannot touch '/var/spool/mail/test': No space left on device

$ df -i /var/spool/mail
Filesystem       Inodes  IUsed IFree IUse% Mounted on
/dev/sdb1      60030976 60030976     0  100% /var/spool/mail
```

**Las cantidades de inodos en ext4 quedan fijadas en el momento del `mkfs` y no se pueden aumentar.** Los únicos remedios son: borrar archivos, o respaldar → `mkfs` con `-i 8192` (o `-N`) → restaurar.

Encontrar al consumidor:

```
$ sudo find /var/spool/mail -xdev -printf '%h\n' | sort | uniq -c | sort -rn | head
2841022 /var/spool/mail/queue/E
2799417 /var/spool/mail/queue/D
```

**XFS no tiene este modo de fallo** — los inodos se asignan dinámicamente, acotados solo por `imaxpct`. Para cargas con cantidades de archivos impredecibles, ese es un argumento decisivo a favor de XFS.

### 10.6 `mkfs` tarda 40 minutos en un LUN SAN

Causa: la pasada de discard/TRIM. Visible como `Discarding blocks...` en `mkfs.xfs` o una pausa larga antes de `Allocating group tables` en `mke2fs`.

```
$ sudo mkfs.xfs -f -K /dev/mapper/mpatha           # -K = do not discard
$ sudo mkfs.ext4 -E nodiscard /dev/mapper/mpatha
```

Salteá el discard cuando el volumen está recién aprovisionado de forma fina (no hay nada que reclamar) o cuando la implementación de UNMAP del array es lenta. Mantené el discard en un SSD de consumo usado que se está reutilizando, donde restaura el rendimiento de escritura.

### 10.7 El firmware UEFI no ve la entrada de arranque

Lista de comprobación, en orden:

```
$ sudo parted /dev/nvme0n1 print | grep -i esp
 1      1049kB  538MB   537MB   fat32        ESP   boot, esp

$ blkid -s TYPE -o value /dev/nvme0n1p1
vfat

$ sudo fdisk -l /dev/nvme0n1 | head -6 | grep Disklabel
Disklabel type: gpt

$ sudo efibootmgr -v
BootCurrent: 0001
BootOrder: 0001,0000
Boot0001* Fedora  HD(1,GPT,8f2c1a04-3b57-4f81-9a2d-1d6e3b9a7c05,0x800,0x100000)/File(\EFI\FEDORA\SHIMX64.EFI)
```

Causas de fallo, ordenadas por frecuencia: la ESP fue formateada como ext4; el GUID de tipo es `8300` en vez de `ef00`; la tabla es MBR en una máquina solo UEFI; la ruta del cargador no es `\EFI\BOOT\BOOTX64.EFI` y no existe una entrada en NVRAM; la ESP es FAT16 en un firmware que solo acepta FAT32.

### 10.8 El host de construcción produjo un sistema de archivos no montable

```
$ sudo mount /dev/sdb1 /mnt
mount: /mnt: wrong fs type, bad option, bad superblock on /dev/sdb1, missing
       codepage or helper program, or other error.
       dmesg(1) may have more information after failed mount system call.

$ dmesg | tail -3
[ 9241.118203] XFS (sdb1): Superblock has unknown incompatible features (0x20)
               enabled.
[ 9241.118211] XFS (sdb1): Filesystem cannot be safely mounted by this kernel.
[ 9241.118219] XFS (sdb1): SB validate failed with error -22.
```

El sistema de archivos está bien; **este kernel es más viejo que el conjunto de características**. Establecé el kernel mínimo de toda la flota y fijá `mkfs` en consecuencia:

| Característica | Por defecto en la herramienta desde | Kernel mínimo para montar | Deshabilitar con |
|---|---|---|---|
| XFS `nrext64` (contadores de extents de 64 bits) | `xfsprogs` 6.0 | 5.19 | `-i nrext64=0` |
| XFS `bigtime` (marcas de tiempo hasta el año 2486) | `xfsprogs` 5.15 | 5.10 | `-m bigtime=0` |
| XFS `inobtcount` | `xfsprogs` 5.15 | 5.10 | `-m inobtcount=0` |
| XFS `reflink` | `xfsprogs` 5.1 | 4.9 | `-m reflink=0` |
| ext4 `orphan_file` | `e2fsprogs` 1.47 | 5.15 | `-O ^orphan_file` |
| ext4 `metadata_csum_seed` | `e2fsprogs` 1.47 | 4.4 | `-O ^metadata_csum_seed` |

El mismo diagnóstico aplica para ext4 (`EXT4-fs (sdb1): couldn't mount RDWR because of unsupported optional features`).

### 10.9 `passno` incorrecto en `/etc/fstab`

```
UUID=…  /srv  xfs  defaults  0 2     # WRONG
```

XFS no tiene `fsck` en el arranque — `fsck.xfs` es un script que sale con 0 de inmediato — así que `passno=2` es inofensivo ahí pero carece de sentido. El daño real es el error espejo: un volumen de datos ext4 con `passno=0` nunca se comprueba, y un volumen extraíble o accesible por red al que le falta `nofail` deja el arranque en modo de emergencia cuando está ausente.

```
UUID=…  /srv       xfs   defaults,noatime,inode64                          0 0
UUID=…  /var/log   ext4  defaults,noatime                                  0 2
UUID=…  /mnt/nfs   xfs   defaults,nofail,x-systemd.device-timeout=10s      0 0
```

Regla: `passno` — `1` solo para `/`, `2` para los demás ext2/3/4, `0` para XFS/Btrfs/swap/red. Agregá siempre `nofail` a todo lo que no sea imprescindible para que el sistema llegue a `multi-user.target`.

### 10.10 Índice rápido síntoma → causa

| Síntoma | Causa más probable | Primer comando |
|---|---|---|
| `mkfs: Device or resource busy` | udev autoensambló una firma md/LVM obsoleta | `ls /sys/class/block/<dev>/holders/` |
| Partición escrita, falta el nodo | El kernel no releyó la tabla | `partx -a --nr N /dev/sdX` |
| `partprobe` informa "in use" | Otra partición del disco está montada | `findmnt -S /dev/sdX*` |
| El arranque cae al shell de emergencia | Error de tipeo en un UUID de `fstab` o dispositivo ausente | `findmnt --verify --verbose` |
| `df` muestra espacio libre, las escrituras fallan | Agotamiento de inodos en ext | `df -i` |
| Falta ~5 % de la capacidad | Bloques reservados de ext | `dumpe2fs -h \| grep Reserved` |
| Escrituras 3× más lentas de lo esperado | Desalineación / falta de geometría de stripe | `parted align-check optimal N`; `xfs_info \| grep sunit` |
| El runtime de contenedores no arranca sobre XFS | `ftype=0` | `xfs_info \| grep ftype` |
| `mkfs` inesperadamente lento | Pasada de discard en un LUN grande/fino | agregar `-K` / `-E nodiscard` |
| Advertencias de CRC de GPT tras un redimensionado | Cabecera de respaldo fuera del último LBA | `sgdisk -e /dev/sdX` |
| Dos dispositivos, un mismo UUID | Clon de VM sin regeneración | `blkid \| sort`; `sgdisk -G` |
| `swapon: Invalid argument` sobre un archivo | Archivo creado con `fallocate` en XFS | recrearlo con `dd` |
| No se puede reducir un volumen | XFS | migrar; la reducción de XFS no existe |
| Sistema de archivos no montable en un nodo más viejo | Conjunto de características de un `mkfs` más nuevo | `dmesg \| grep -i 'unknown.*feature'` |

---

## 11. Laboratorio

Reproducible en cualquier máquina con 2 GiB de espacio libre, usando dispositivos de bucle. Nada toca discos reales.

```
$ truncate -s 8G /tmp/lab-mbr.img
$ truncate -s 8G /tmp/lab-gpt.img
$ sudo losetup -fP --show /tmp/lab-mbr.img
/dev/loop0
$ sudo losetup -fP --show /tmp/lab-gpt.img
/dev/loop1
```

**Ejercicio 1 — MBR con cuatro regiones incluyendo un contenedor extendido.**
Construí en `/dev/loop0`: 512 MiB `83`, 1 GiB `82`, una partición extendida que cubra el resto, y dentro de ella dos particiones lógicas de 2 GiB y 1 GiB. Verificá con `fdisk -l` que las lógicas se numeran desde 5 y que cada una empieza 2048 sectores después del EBR precedente.

**Ejercicio 2 — GPT con un diseño de arranque completo.**
En `/dev/loop1`, usando solo `sgdisk`, en un único comando: 1 MiB `ef02`, 512 MiB `ef00` llamada `ESP`, 1 GiB `8200` llamada `swap0`, el resto `8300` llamada `root`. Verificá con `sgdisk -v` y `parted unit s print free`.

**Ejercicio 3 — sistemas de archivos.**
`mkfs.vfat -F 32 -n ESP` sobre la ESP; `mkfs.ext4 -m 1 -i 32768 -L root` sobre la raíz; `mkswap -L swap0` sobre el swap. Registrá la lista de superbloques de respaldo que devuelve `mkfs.ext4 -n`.

**Ejercicio 4 — destruir y recuperar.**
`dd if=/dev/zero of=/dev/loop1p4 bs=1k count=1 seek=1` borra el superbloque ext4 primario. Confirmá el fallo con `mount`, luego reparalo con `e2fsck -b <respaldo> -B 4096`.

**Ejercicio 5 — destruir y recuperar la GPT.**
`dd if=/dev/zero of=/dev/loop1 bs=512 count=1` destruye el MBR protectivo. Confirmá con `fdisk -l`, luego restaurá desde la GPT de respaldo usando el menú de recuperación de `gdisk` (`r`, y después `b`).

**Ejercicio 6 — la lección de la alineación.**
Creá una partición que empiece en el sector 63 con `sfdisk`, luego ejecutá `parted align-check optimal 1`. Observá `not aligned`. Recreala en 2048.

Desmontaje:

```
$ sudo losetup -d /dev/loop0 /dev/loop1
$ rm -f /tmp/lab-mbr.img /tmp/lab-gpt.img
```

---

## 12. Referencia rápida y trampas del examen

**Trampas que aparecen una y otra vez:**

1. `parted mkpart primary ext4 1MiB 100%` **no crea un sistema de archivos.** Fija un código de tipo de partición. `mkfs.ext4` sigue siendo necesario.
2. En `fdisk`, no se escribe nada hasta `w`. `q` descarta.
3. Las particiones lógicas empiezan siempre en **5**, incluso con una sola primaria en uso.
4. MBR tope en **2 TiB con sectores de 512 bytes** — expresalo como una cifra en bytes, no como "2 TB".
5. `mkfs -t ext4` = `mkfs.ext4` = `mke2fs -t ext4`. `mkfs.vfat` = `mkfs.msdos` = `mkdosfs` = `mkfs.fat`.
6. `mkswap` prepara; `swapon` activa. Ambos son necesarios, más una entrada en `fstab` para sobrevivir al reinicio.
7. GPT es obligatorio más allá de 2 TiB **y** para el arranque UEFI nativo; la partición BIOS boot `ef02` es obligatoria para GRUB en GPT bajo BIOS heredada.
8. La alineación por defecto es el sector 2048 = 1 MiB en `fdisk`, `gdisk` y `parted`.
9. `mkfs.ext4 -m` toma un **porcentaje**, no una cantidad de bytes.
10. XFS puede crecer pero **nunca reducirse**. ext4 puede reducirse, pero solo desmontado.
11. ReiserFS y Btrfs son de nivel *conocimiento general* para LPIC-1 — reconocé qué son, no esperes preguntas de configuración profunda.
12. `fdisk` maneja GPT desde util-linux 2.23; la afirmación "fdisk no puede con GPT" está desactualizada, pero `gdisk`/`parted` siguen siendo las herramientas para GPT nombradas por el objetivo.

**Chuleta de comandos:**

```
fdisk -l                        # list all partition tables
fdisk /dev/sdX                  # n d t l p a v o g w q  (x = expert)
gdisk /dev/sdX                  # n d t i p v w q  (r = recovery, x = expert)
sgdisk -n N:0:+SIZE -t N:CODE -c N:"NAME" /dev/sdX
sgdisk --backup=F /dev/sdX      # sgdisk --load-backup=F ; sgdisk -G ; sgdisk -e
parted -s -a optimal /dev/sdX -- mklabel gpt mkpart NAME fs START END
parted /dev/sdX unit s print free
parted /dev/sdX align-check optimal N
sfdisk -d /dev/sdX > f          # sfdisk /dev/sdY < f ; sfdisk -V /dev/sdX
partprobe /dev/sdX  |  partx -u /dev/sdX  |  blockdev --rereadpt /dev/sdX
wipefs -a /dev/sdXN

mkfs.ext4 -L L -b 4096 -i 32768 -m 1 -J size=256 -E lazy_itable_init=0 /dev/sdXN
mkfs.ext4 -n /dev/sdXN          # dry run: backup superblock locations
mkfs.xfs  -f -L L -i size=512 -m crc=1,reflink=1 -n ftype=1 -d su=64k,sw=4 /dev/sdXN
mkfs.vfat -F 32 -n LABEL /dev/sdXN
mkfs.exfat -L LABEL -c 128K /dev/sdXN
mkfs.btrfs -L L -d raid1 -m raid1 /dev/sdb /dev/sdc
mkswap -L L /dev/sdXN  ;  swapon --priority 10 /dev/sdXN  ;  swapon --show

blkid ; lsblk -f ; dumpe2fs -h ; xfs_info ; fsck.fat -v -n ; findmnt --verify
```

---

## 13. Referencias

**Objetivos oficiales de la certificación**
- LPI — Objetivos del examen 101-500 (V5.0), Tema 104.1: https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — Descripción general de la certificación LPIC-1: https://www.lpi.org/our-certifications/lpic-1-overview/

**Especificaciones**
- Especificación UEFI (diseño GPT, requisitos de la ESP, GUIDs de tipo de partición) — UEFI Forum: https://uefi.org/specifications
- Discoverable Partitions Specification — systemd/UAPI Group: https://uapi-group.org/specifications/specs/discoverable_partitions_specification/

**Utilidades — documentación upstream y páginas de manual**
- util-linux (`fdisk`, `sfdisk`, `partx`, `blkid`, `lsblk`, `wipefs`, `mkswap`, `swapon`, `findmnt`): https://github.com/util-linux/util-linux y https://man7.org/linux/man-pages/man8/fdisk.8.html
- `sfdisk(8)`: https://man7.org/linux/man-pages/man8/sfdisk.8.html
- `mkswap(8)`: https://man7.org/linux/man-pages/man8/mkswap.8.html
- `swapon(8)`: https://man7.org/linux/man-pages/man8/swapon.8.html
- GPT fdisk (`gdisk`, `sgdisk`, `cgdisk`) — sitio del proyecto y documentación: https://www.rodsbooks.com/gdisk/
- `gdisk(8)`: https://man7.org/linux/man-pages/man8/gdisk.8.html
- Manual de GNU Parted: https://www.gnu.org/software/parted/manual/parted.html
- `parted(8)`: https://man7.org/linux/man-pages/man8/parted.8.html
- `mkfs(8)`: https://man7.org/linux/man-pages/man8/mkfs.8.html

**Sistemas de archivos**
- Proyecto e2fsprogs (`mke2fs`, `dumpe2fs`, `tune2fs`, `e2fsck`): https://e2fsprogs.sourceforge.net/
- `mke2fs(8)`: https://man7.org/linux/man-pages/man8/mke2fs.8.html
- `mke2fs.conf(5)`: https://man7.org/linux/man-pages/man5/mke2fs.conf.5.html
- Documentación del kernel sobre ext4: https://docs.kernel.org/filesystems/ext4/index.html
- Documentación del kernel sobre XFS: https://docs.kernel.org/filesystems/xfs/index.html
- `mkfs.xfs(8)`: https://man7.org/linux/man-pages/man8/mkfs.xfs.8.html
- Código fuente de xfsprogs: https://git.kernel.org/pub/scm/fs/xfs/xfsprogs-dev.git/
- Documentación de Btrfs: https://btrfs.readthedocs.io/en/latest/
- `mkfs.btrfs`: https://btrfs.readthedocs.io/en/latest/mkfs.btrfs.html
- dosfstools (`mkfs.fat`, `fsck.fat`): https://github.com/dosfstools/dosfstools
- `mkfs.fat(8)`: https://man7.org/linux/man-pages/man8/mkfs.fat.8.html
- exfatprogs: https://github.com/exfatprogs/exfatprogs
- Documentación del kernel sobre exFAT: https://docs.kernel.org/filesystems/index.html

**Kernel y capa de bloques**
- ABI sysfs de la capa de bloques (`queue/logical_block_size`, `optimal_io_size`, alineación): https://docs.kernel.org/block/queue-sysfs.html
- Índice de la documentación de sistemas de archivos del kernel Linux: https://docs.kernel.org/filesystems/index.html
- Aviso de obsolescencia de ReiserFS, documentación del kernel: https://docs.kernel.org/process/deprecated.html

**Infraestructura como código**
- systemd `repart.d(5)`: https://www.freedesktop.org/software/systemd/man/latest/repart.d.html
- `systemd-repart(8)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-repart.html
- `systemd-gpt-auto-generator(8)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-gpt-auto-generator.html
- `fstab(5)`: https://www.freedesktop.org/software/systemd/man/latest/fstab.html
- Módulos de cloud-init — Disk Setup: https://cloudinit.readthedocs.io/en/latest/reference/modules.html#disk-setup
- Especificación de configuración de Butane v1.5.0: https://coreos.github.io/butane/config-fcos-v1_5/
- Especificación de Ignition v3.4.0: https://coreos.github.io/ignition/configuration-v3_4/
- Ansible `community.general.parted`: https://docs.ansible.com/ansible/latest/collections/community/general/parted_module.html
- Ansible `community.general.filesystem`: https://docs.ansible.com/ansible/latest/collections/community/general/filesystem_module.html
- Ansible `ansible.posix.mount`: https://docs.ansible.com/ansible/latest/collections/ansible/posix/mount_module.html
- Kubernetes — Local Persistent Volumes: https://kubernetes.io/docs/concepts/storage/volumes/#local
- Kubernetes — Storage Classes: https://kubernetes.io/docs/concepts/storage/storage-classes/