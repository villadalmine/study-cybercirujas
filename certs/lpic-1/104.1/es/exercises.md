# LPIC-1 — 104.1 Crear particiones y sistemas de archivos
## Ejercicios guiados (Examen 101-500, peso 3)

> **Alcance cubierto aquí:** tablas de particiones MBR con `fdisk`, GPT con `gdisk`/`sgdisk`/`parted`, `mkfs` para ext2/ext3/ext4, XFS, VFAT y exFAT, `mkswap`, y conocimiento general de Btrfs y ReiserFS.

---

## 0. Entorno de laboratorio y seguridad

Cada comando de este documento destruye datos en el dispositivo que se le indique. **Nunca** los vas a apuntar a un disco real. En su lugar construís dos imágenes de disco y las exponés como dispositivos de bloque con el driver loop, que el kernel trata exactamente igual que `/dev/sda` — mismo escaneo de particiones, mismo `mkfs`, mismo `mount`, mismos modos de falla.

**Prerrequisitos** (nombres de Debian/Ubuntu; en la familia RHEL usá `dnf`):

```bash
sudo apt-get install -y util-linux gdisk parted e2fsprogs xfsprogs \
                        dosfstools exfatprogs btrfs-progs
```

Las salidas de abajo fueron capturadas en Debian 12 con `util-linux 2.38.1`, `e2fsprogs 1.47.0`, `xfsprogs 6.1.0`, `dosfstools 4.2`, `exfatprogs 1.2.2`, `btrfs-progs 6.2`. Las versiones de las herramientas cambian la redacción exacta de la salida, no los conceptos. Ejecutá todo como root (`sudo -i`) salvo que se indique lo contrario.

---

## Ejercicio 1 — Mapear la capa de bloques antes de tocarla

La causa más común de destrucción de datos en producción en este tema es ejecutar un comando correcto contra el nombre de dispositivo equivocado. Los nombres de dispositivo *no* son estables entre reinicios; identificá por tamaño, modelo y UUID.

**Pasos**

1. Creá el directorio de trabajo y los dos archivos de respaldo. `truncate` crea archivos dispersos (sparse), así que 6 GiB de "disco" casi no ocupan espacio real:

   ```bash
   mkdir -p /var/tmp/lpic104 /mnt/lab
   truncate -s 2G /var/tmp/lpic104/disk-mbr.img
   truncate -s 4G /var/tmp/lpic104/disk-gpt.img
   ls -lsh /var/tmp/lpic104/
   ```

   ```
   total 0
   0 -rw-r--r-- 1 root root 2.0G Aug 26 10:12 disk-mbr.img
   0 -rw-r--r-- 1 root root 4.0G Aug 26 10:12 disk-gpt.img
   ```

   Fijate en el `0` de la primera columna (bloques realmente asignados) frente al tamaño aparente.

2. Asociá cada archivo a un dispositivo loop. `-P` (`--partscan`) le indica al kernel que escanee el dispositivo en busca de una tabla de particiones y cree dispositivos hijos `pN`:

   ```bash
   losetup -f -P --show /var/tmp/lpic104/disk-mbr.img
   losetup -f -P --show /var/tmp/lpic104/disk-gpt.img
   ```

   ```
   /dev/loop0
   /dev/loop1
   ```

   Si tus números difieren, **usá los tuyos** para el resto del laboratorio. Confirmá el mapeo en cualquier momento con `losetup -a`.

3. Mirá la capa de bloques de cuatro maneras distintas. Cada herramienta responde una pregunta diferente:

   ```bash
   lsblk /dev/loop0 /dev/loop1
   ```

   ```
   NAME  MAJ:MIN RM SIZE RO TYPE MOUNTPOINTS
   loop0   7:0    0   2G  0 loop
   loop1   7:1    0   4G  0 loop
   ```

   ```bash
   grep loop /proc/partitions
   ```

   ```
      7        0    2097152 loop0
      7        1    4194304 loop1
   ```

   ```bash
   blkid /dev/loop0 ; echo "exit=$?"
   ```

   ```
   exit=2
   ```

   ```bash
   fdisk -l /dev/loop1
   ```

   ```
   Disk /dev/loop1: 4 GiB, 4294967296 bytes, 8388608 sectors
   Units: sectors of 1 * 512 = 512 bytes
   Sector size (logical/physical): 512 bytes / 512 bytes
   I/O size (minimum/optimal): 512 bytes / 512 bytes
   ```

4. Revisá la geometría que va a determinar cada decisión de alineación más adelante:

   ```bash
   blockdev --getss --getpbsz --getsize64 /dev/loop1
   ```

   ```
   512
   512
   4294967296
   ```

   En hardware real, compará con un disco físico propio (solo lectura, inofensivo):

   ```bash
   lsblk -o NAME,SIZE,PHY-SEC,LOG-SEC,ROTA,MODEL -d
   ```

**Comprobá tu comprensión**

- **Q1.1** `blkid /dev/loop0` no imprimió nada y salió con 2. ¿Qué prueba exactamente eso, y qué *no* prueba?
- **Q1.2** `/proc/partitions` lista `loop0` pero no `loop0p1`. Nombrá dos razones independientes por las que esa entrada podría faltar en un disco real.
- **Q1.3** Un disco reporta tamaño de sector lógico 512 y tamaño de sector físico 4096. ¿Cómo se llama este tipo de unidad, y qué sale mal si una partición empieza en el sector 63?
- **Q1.4** ¿Por qué `lsblk -o ...,MODEL,SERIAL` es una forma más segura de elegir un objetivo que `/dev/sdb`?

---

## Ejercicio 2 — MBR: los 512 bytes que describen el disco

**Pasos**

1. Iniciá `fdisk` en el dispositivo de 2 GiB. Es interactivo; `m` imprime el menú en cualquier momento:

   ```bash
   fdisk /dev/loop0
   ```

   ```
   Welcome to fdisk (util-linux 2.38.1).
   Changes will remain in memory only, until you decide to write them.
   Be careful before using the write command.

   Device does not contain a recognized partition table.
   Created a new DOS disklabel with disk identifier 0x1a4f9c73.

   Command (m for help):
   ```

   Leé esa última línea con atención: `fdisk` ya inventó un MBR vacío **en memoria**. Todavía no hay nada en el disco.

2. Creá la primera partición primaria, de 512 MiB, aceptando el inicio por defecto:

   ```
   Command (m for help): n
   Partition type
      p   primary (0 primary, 0 extended, 3 free)
      e   extended (container for logical partitions)
   Select (default p): p
   Partition number (1-4, default 1): 1
   First sector (2048-4194303, default 2048): <Enter>
   Last sector, +/-sectors or +/-size{K,M,G,T,P} (2048-4194303, default 4194303): +512M

   Created a new partition 1 of type 'Linux' and of size 512 MiB.
   ```

3. Creá una segunda partición primaria del mismo tamaño y cambiá su tipo a Linux swap. El tipo es un solo byte; `l` lista los valores conocidos:

   ```
   Command (m for help): n
   Select (default p): p
   Partition number (2-4, default 2): 2
   First sector (1050624-4194303, default 1050624): <Enter>
   Last sector, ... : +512M

   Created a new partition 2 of type 'Linux' and of size 512 MiB.

   Command (m for help): t
   Partition number (1,2, default 2): 2
   Hex code or alias (type L to list all): 82

   Changed type of partition 'Linux' to 'Linux swap / Solaris'.
   ```

4. Inspeccioná la tabla en memoria y después confirmala:

   ```
   Command (m for help): p
   Disk /dev/loop0: 2 GiB, 2147483648 bytes, 4194304 sectors
   Disklabel type: dos
   Disk identifier: 0x1a4f9c73

   Device       Boot   Start     End Sectors  Size Id Type
   /dev/loop0p1         2048 1050623 1048576  512M 83 Linux
   /dev/loop0p2      1050624 2099199 1048576  512M 82 Linux swap / Solaris

   Command (m for help): w
   The partition table has been altered.
   Calling ioctl() to re-read partition table.
   Syncing disks.
   ```

5. Verificá desde afuera que el kernel la tomó:

   ```bash
   lsblk /dev/loop0
   ```

   ```
   NAME      MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
   loop0       7:0    0    2G  0 loop
   ├─loop0p1 259:0    0  512M  0 part
   └─loop0p2 259:1    0  512M  0 part
   ```

6. Ahora leé vos mismo el MBR en crudo. Este es todo el sentido del ejercicio — la "tabla de particiones" son 64 bytes:

   ```bash
   dd if=/dev/loop0 bs=512 count=1 status=none | hexdump -C | tail -n 6
   ```

   ```
   000001b0  00 00 00 00 00 00 00 00  73 9c 4f 1a 00 00 00 20  |........s.O.... |
   000001c0  21 00 83 2a 44 20 00 08  00 00 00 00 10 00 00 2a  |!..*D ....... .*|
   000001d0  45 20 82 4b 4d 20 00 08  10 00 00 00 10 00 00 00  |E .KM ..........|
   000001e0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
   000001f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 55 aa  |..............UU|
   ```

   El desplazamiento de byte `0x1BE` inicia la entrada 1, `0x1CE` la entrada 2, `0x1DE` la entrada 3, `0x1EE` la entrada 4, y `0x1FE` contiene la firma de arranque `55 AA`. Dentro de cada entrada de 16 bytes, el byte 0 es la bandera de arranque, el byte 4 es el **ID de tipo de partición**, y los bytes 8–11 y 12–15 son el LBA inicial de 32 bits y la longitud en sectores, en little-endian.

7. Hacé un respaldo de todo el conjunto — el hábito profesional antes de cada sesión de particionado:

   ```bash
   sfdisk --dump /dev/loop0 > /var/tmp/lpic104/loop0.sfdisk
   dd if=/dev/loop0 of=/var/tmp/lpic104/loop0-mbr.bin bs=512 count=1
   cat /var/tmp/lpic104/loop0.sfdisk
   ```

   ```
   label: dos
   label-id: 0x1a4f9c73
   device: /dev/loop0
   unit: sectors
   sector-size: 512

   /dev/loop0p1 : start=        2048, size=     1048576, type=83
   /dev/loop0p2 : start=     1050624, size=     1048576, type=82
   ```

   Ese archivo de texto se puede reproducir con `sfdisk /dev/loop0 < loop0.sfdisk`.

**Comprobá tu comprensión**

- **Q2.1** `fdisk` eligió el sector 2048 como inicio por defecto. Convertilo a bytes y explicá la elección en una oración.
- **Q2.2** Pusiste el byte de tipo de la partición 2 en `82`. ¿El kernel se niega ahora a hacer `mkfs.ext4` sobre esa partición? ¿Para qué sirve realmente el byte de tipo?
- **Q2.3** En el hexdump, el LBA de inicio de la partición 1 está codificado como `00 08 00 00`. ¿Qué valor decimal es ese, y por qué el orden de bytes es así?
- **Q2.4** MBR almacena el LBA de inicio y la longitud como valores de 32 bits. Derivá el tamaño máximo de disco direccionable para una unidad con sectores de 512 bytes, e indicá qué cambia en una unidad 4Kn.
- **Q2.5** ¿Cuál es la diferencia práctica entre `sfdisk --dump` y un `dd` del primer sector como respaldo?

---

## Ejercicio 3 — La partición extendida y la cadena de EBR

MBR tiene lugar para exactamente cuatro entradas. La partición extendida es el rodeo histórico: uno de los cuatro slots se convierte en un contenedor que aloja una lista enlazada simple.

**Pasos**

1. Volvé a entrar en `fdisk` y creá una partición extendida que ocupe el resto del disco:

   ```bash
   fdisk /dev/loop0
   ```

   ```
   Command (m for help): n
   Partition type
      p   primary (2 primary, 0 extended, 2 free)
      e   extended (container for logical partitions)
   Select (default p): e
   Partition number (3,4, default 3): 3
   First sector (2099200-4194303, default 2099200): <Enter>
   Last sector, ... (default 4194303): <Enter>

   Created a new partition 3 of type 'Extended' and of size 1023 MiB.
   ```

2. Creá dos particiones lógicas dentro de ella. Notá que `fdisk` ya no pide un número:

   ```
   Command (m for help): n
   All primary partitions are in use.
   Adding logical partition 5
   First sector (2101248-4194303, default 2101248): <Enter>
   Last sector, ... : +500M

   Created a new partition 5 of type 'Linux' and of size 500 MiB.

   Command (m for help): n
   All primary partitions are in use.
   Adding logical partition 6
   First sector (3127296-4194303, default 3127296): <Enter>
   Last sector, ... (default 4194303): <Enter>

   Created a new partition 6 of type 'Linux' and of size 521 MiB.
   ```

3. Configurá los tipos que vas a formatear realmente más adelante — `07` para exFAT y `0c` para FAT32 (LBA) — y después escribí:

   ```
   Command (m for help): t
   Partition number (1-3,5,6, default 6): 5
   Hex code or alias (type L to list all): 07
   Changed type of partition 'Linux' to 'HPFS/NTFS/exFAT'.

   Command (m for help): t
   Partition number (1-3,5,6, default 6): 6
   Hex code or alias (type L to list all): 0c
   Changed type of partition 'Linux' to 'W95 FAT32 (LBA)'.

   Command (m for help): p

   Device       Boot   Start     End Sectors  Size Id Type
   /dev/loop0p1         2048 1050623 1048576  512M 83 Linux
   /dev/loop0p2      1050624 2099199 1048576  512M 82 Linux swap / Solaris
   /dev/loop0p3      2099200 4194303 2095104 1023M  5 Extended
   /dev/loop0p5      2101248 3125247 1024000  500M  7 HPFS/NTFS/exFAT
   /dev/loop0p6      3127296 4194303 1067008  521M  c W95 FAT32 (LBA)

   Command (m for help): w
   ```

4. Confirmá la topología y los tamaños que expone el kernel:

   ```bash
   lsblk /dev/loop0
   ```

   ```
   NAME      MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
   loop0       7:0    0    2G  0 loop
   ├─loop0p1 259:0    0  512M  0 part
   ├─loop0p2 259:1    0  512M  0 part
   ├─loop0p3 259:2    0    1K  0 part
   ├─loop0p5 259:3    0  500M  0 part
   └─loop0p6 259:4    0  521M  0 part
   ```

   `loop0p3` aparece como **1K**. Esa es la partición extendida en sí: el kernel expone deliberadamente solo su primer sector para que nadie pueda escribir accidentalmente un sistema de archivos sobre el contenedor y destruir la cadena.

5. Mirá el primer EBR. Vive en el primerísimo sector de la partición extendida (2099200) y tiene el mismo layout de 512 bytes que el MBR, pero solo dos de las cuatro entradas se usan alguna vez:

   ```bash
   dd if=/dev/loop0 bs=512 count=1 skip=2099200 status=none | hexdump -C | sed -n '28,32p'
   ```

   ```
   000001b0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 20  |............... |
   000001c0  21 00 07 fe ff ff 00 08  00 00 00 a0 0f 00 00 fe  |!............... |
   000001d0  ff ff 05 fe ff ff 00 c0  0f 00 00 40 10 00 00 00  |...........@....|
   000001e0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
   000001f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 55 aa  |..............UU|
   ```

   La entrada 1 (`0x1BE`) describe la partición lógica, con un inicio **relativo a este EBR**. La entrada 2 (`0x1CE`) tiene tipo `05` y apunta al *siguiente* EBR, con un inicio relativo al comienzo de la partición extendida. Esa es la lista enlazada.

6. Restablecé la disciplina de verificación — volcá la tabla de nuevo y compará (`diff`) contra tu respaldo:

   ```bash
   sfdisk --dump /dev/loop0 | diff -u /var/tmp/lpic104/loop0.sfdisk - | head -n 20
   ```

**Comprobá tu comprensión**

- **Q3.1** ¿Por qué la numeración de las particiones lógicas siempre empieza en 5, incluso cuando existe una sola partición primaria?
- **Q3.2** ¿Puede un disco MBR contener dos particiones extendidas? Justificá la respuesta a partir de la estructura en disco, no del mensaje de error de la herramienta.
- **Q3.3** `/dev/loop0p3` mide 1 KiB. ¿Qué riesgo previene esto deliberadamente?
- **Q3.4** La partición lógica 5 empieza en el sector 2101248 mientras que la extendida empieza en 2099200 — una brecha de 2048 sectores. ¿Qué vive en esa brecha, y cuántos sectores necesita estrictamente?
- **Q3.5** Borrás la partición lógica 5 con `fdisk` mientras la partición 6 existe. ¿Qué le pasa al nombre de dispositivo de la partición 6, y por qué eso es peligroso para `/etc/fstab`?

---

## Ejercicio 4 — GPT con `gdisk`

**Pasos**

1. Abrí el dispositivo de 4 GiB con `gdisk`. Leé el informe del escaneo antes de hacer nada:

   ```bash
   gdisk /dev/loop1
   ```

   ```
   GPT fdisk (gdisk) version 1.0.9

   Partition table scan:
     MBR: not present
     BSD: not present
     APM: not present
     GPT: not present

   Creating new GPT entries in memory.

   Command (? for help):
   ```

2. Creá cuatro particiones. `gdisk` acepta la notación `+size` y alinea los inicios automáticamente:

   ```
   Command (? for help): n
   Partition number (1-128, default 1): 1
   First sector (34-8388574, default = 2048) or {+-}size{KMGTP}: <Enter>
   Last sector (2048-8388574, default = 8388574) or {+-}size{KMGTP}: +512M
   Current type is 8300 (Linux filesystem)
   Hex code or GUID (L to show codes, Enter = 8300): ef00
   Changed type of partition to 'EFI system partition'

   Command (? for help): n
   Partition number (2-128, default 2): 2
   First sector ... (default = 1050624): <Enter>
   Last sector ... : +1G
   Hex code or GUID (L to show codes, Enter = 8300): <Enter>
   Changed type of partition to 'Linux filesystem'
   ```

   Repetí `n` dos veces más para las particiones 3 y 4, cada una `+1G`, tipo `8300`.

3. Dales a las particiones nombres legibles por humanos — una característica de GPT que MBR no tiene — con `c`:

   ```
   Command (? for help): c
   Partition number (1-4): 2
   Enter name: xfs-data

   Command (? for help): c
   Partition number (1-4): 3
   Enter name: ext4-data

   Command (? for help): c
   Partition number (1-4): 4
   Enter name: btrfs-data
   ```

4. Imprimí la tabla y estudiá la geometría de la cabecera:

   ```
   Command (? for help): p
   Disk /dev/loop1: 8388608 sectors, 4.0 GiB
   Sector size (logical/physical): 512/512 bytes
   Disk identifier (GUID): 7C2E4A61-9B33-4E77-B0F2-15E0C2A9D4A8
   Partition table holds up to 128 entries
   Main partition table begins at sector 2 and ends at sector 33
   First usable sector is 34, last usable sector is 8388574
   Partitions will be aligned on 2048-sector boundaries
   Total free space is 1048509 sectors (512.0 MiB)

   Number  Start (sector)    End (sector)  Size       Code  Name
      1            2048         1050623   512.0 MiB   EF00  EFI system partition
      2         1050624         3147775   1024.0 MiB  8300  xfs-data
      3         3147776         5244927   1024.0 MiB  8300  ext4-data
      4         5244928         7342079   1024.0 MiB  8300  btrfs-data
   ```

5. Ejecutá la verificación de consistencia incorporada y después escribí:

   ```
   Command (? for help): v

   No problems found. 1048509 free sectors (512.0 MiB) available in 2
   segments, the largest of which is 1046495 (511.0 MiB) in size.

   Command (? for help): w

   Final checks complete. About to write GPT data. THIS WILL OVERWRITE EXISTING
   PARTITIONS!!

   Do you want to proceed? (Y/N): Y
   OK; writing new GUID partition table (GPT) to /dev/loop1.
   The operation has completed successfully.
   ```

6. Verificá desde afuera y comprobá que existe el MBR protector:

   ```bash
   sgdisk -p /dev/loop1 | head -n 8
   dd if=/dev/loop1 bs=512 count=1 status=none | hexdump -C | sed -n '28,32p'
   ```

   ```
   000001b0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
   000001c0  02 00 ee ff ff ff 01 00  00 00 ff ff 7f 00 00 00  |................|
   000001d0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
   000001e0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
   000001f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 55 aa  |..............UU|
   ```

   Una sola entrada, de tipo `EE`, abarcando todo el disco. Una herramienta que solo entiende MBR ve un disco lleno y desconocido, y se niega a tocarlo.

7. Compará las dos cabeceras GPT — la primaria en el LBA 1, la de respaldo en el último LBA:

   ```bash
   dd if=/dev/loop1 bs=512 count=1 skip=1 status=none | hexdump -C | head -n 4
   dd if=/dev/loop1 bs=512 count=1 skip=8388607 status=none | hexdump -C | head -n 4
   ```

   ```
   00000000  45 46 49 20 50 41 52 54  00 00 01 00 5c 00 00 00  |EFI PART....\...|
   ```

   Ambas empiezan con la firma `EFI PART`. Esta redundancia es la razón por la que `gdisk` puede reparar un disco cuyos primeros sectores fueron sobrescritos (`r` → menú de recuperación → `b`, reconstruir la cabecera principal desde la de respaldo).

8. Respaldá la GPT a un archivo:

   ```bash
   sgdisk --backup=/var/tmp/lpic104/loop1.gpt /dev/loop1
   ```

   ```
   The operation has completed successfully.
   ```

**Comprobá tu comprensión**

- **Q4.1** `gdisk` dijo "First usable sector is 34". Derivá ese número a partir del layout de GPT.
- **Q4.2** Calculá el último sector usable para este disco de 8388608 sectores y explicá por qué no es 8388606.
- **Q4.3** ¿Para qué sirve la entrada de tipo `EE` en el sector 0? Nombrá una falla concreta que previene.
- **Q4.4** GPT almacena un **GUID** de tipo por partición en lugar del ID de un byte de MBR. Más allá del espacio de nombres más grande, ¿qué capacidad habilita eso que MBR no puede expresar?
- **Q4.5** Un colega ejecutó `dd if=/dev/zero of=/dev/sdb bs=512 count=1` en un disco GPT y dice "el disco se perdió". ¿Qué se perdió realmente, qué sobrevive, y qué menú de `gdisk` lo recupera?
- **Q4.6** ¿Cuántas particiones puede contener esta tabla, y dónde está almacenado ese número?

---

## Ejercicio 5 — Particionado por script con `parted` y `sgdisk`, y alineación

Las herramientas interactivas son para humanos. La automatización necesita `parted -s`, `sgdisk` o `sfdisk`.

**Pasos**

1. Inspeccioná el disco GPT con `parted`, incluyendo el espacio libre:

   ```bash
   parted /dev/loop1 unit MiB print free
   ```

   ```
   Model: Loopback device (loop)
   Disk /dev/loop1: 4096MiB
   Sector size (logical/physical): 512B/512B
   Partition Table: gpt
   Disk Flags:

   Number  Start     End       Size      File system  Name                  Flags
           0.02MiB   1.00MiB   0.98MiB   Free Space
    1      1.00MiB   513MiB    512MiB                 EFI system partition
    2      513MiB    1537MiB   1024MiB                xfs-data
    3      1537MiB   2561MiB   1024MiB                ext4-data
    4      2561MiB   3585MiB   1024MiB                btrfs-data
           3585MiB   4096MiB   511MiB    Free Space
   ```

   `unit MiB` importa: por defecto `parted` imprime potencias de diez (`MB` = 1 000 000 bytes), lo cual es una fuente clásica de confusión por un factor considerable.

2. Agregá una quinta partición de forma no interactiva en el espacio restante:

   ```bash
   parted -s -a optimal /dev/loop1 mkpart scratch ext4 3585MiB 100%
   parted -s /dev/loop1 unit MiB print | tail -n 3
   ```

   ```
    4      2561MiB   3585MiB   1024MiB               btrfs-data
    5      3585MiB   4096MiB   511MiB   ext4         scratch
   ```

   El argumento `ext4` estableció el **GUID de tipo** de la partición y una pista en la tabla. **No** creó un sistema de archivos — la columna `File system` de acá es el resultado del sondeo propio de `parted` más la pista registrada.

3. Comprobá la alineación:

   ```bash
   parted /dev/loop1 align-check optimal 1
   parted /dev/loop1 align-check optimal 5
   ```

   ```
   1 aligned
   5 aligned
   ```

4. Ahora creá deliberadamente una partición desalineada en el disco MBR para ver fallar la verificación. Primero liberá algo de espacio, después usá `sfdisk` para ubicar una partición en el sector 2049:

   ```bash
   sgdisk --version >/dev/null   # sanity check tools exist
   parted /dev/loop0 align-check optimal 1
   ```

   ```
   1 aligned
   ```

   ```bash
   parted /dev/loop0 unit s print | grep -E '^ [0-9]'
   ```

   ```
    1      2048s    1050623s  1048576s  primary
    2      1050624s 2099199s  1048576s  primary
   ```

5. Compará el equivalente GPT por script con `sgdisk`, que es el front end por lotes de `gdisk`:

   ```bash
   sgdisk -p /dev/loop1 | tail -n 6
   ```

   ```
   Number  Start (sector)    End (sector)  Size       Code  Name
      1            2048         1050623   512.0 MiB   EF00  EFI system partition
      2         1050624         3147775   1024.0 MiB  8300  xfs-data
      3         3147776         5244927   1024.0 MiB  8300  ext4-data
      4         5244928         7342079   1024.0 MiB  8300  btrfs-data
      5         7342080         8388574   511.0 MiB   8300  scratch
   ```

   La forma idiomática por script de todo lo que hiciste interactivamente habría sido:

   ```bash
   # Reference only — do not run, it would wipe the lab
   sgdisk --zap-all /dev/loop1
   sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI system partition" \
          -n 2:0:+1G    -t 2:8300 -c 2:"xfs-data" \
          -n 3:0:+1G    -t 3:8300 -c 3:"ext4-data" \
          -n 4:0:+1G    -t 4:8300 -c 4:"btrfs-data" /dev/loop1
   ```

   En `-n num:start:end`, un inicio de `0` significa "primer sector libre alineado".

**Comprobá tu comprensión**

- **Q5.1** En `parted mkpart scratch ext4 3585MiB 100%`, ¿qué hizo realmente la palabra `ext4`? ¿Qué tenés que ejecutar después para poder almacenar archivos?
- **Q5.2** `parted` imprimió `4096MB` en un lugar y `4096MiB` en otro para el mismo disco. ¿Cuál es más grande y por cuánto, aproximadamente, para un disco de 4 TB?
- **Q5.3** ¿Cuál es la diferencia entre `align-check minimal` y `align-check optimal`?
- **Q5.4** ¿Por qué `parted -s` (o `sgdisk`/`sfdisk`) es obligatorio en un script de aprovisionamiento, mientras que `fdisk` no encaja bien?
- **Q5.5** `sgdisk --zap-all` frente a `wipefs -a` frente a `dd if=/dev/zero bs=1M count=10` — ¿qué elimina cada uno?

---

## Ejercicio 6 — ext2, ext3 y ext4 con `mke2fs`

**Pasos**

1. Creá un sistema de archivos ext2 simple en la primera partición MBR y leé la salida línea por línea:

   ```bash
   mkfs.ext2 -L labext2 /dev/loop0p1
   ```

   ```
   mke2fs 1.47.0 (5-Feb-2023)
   Creating filesystem with 131072 4k blocks and 32768 inodes
   Filesystem UUID: 6c1d8f3e-42a7-4a19-9b0c-7e5f21d3ab88
   Superblock backups stored on blocks:
   	32768, 98304

   Allocating group tables: done
   Writing inode tables: done
   Writing superblocks and filesystem accounting information: done
   ```

   512 MiB ÷ 4 KiB = 131072 bloques. 536870912 bytes ÷ 16384 bytes-por-inodo = 32768 inodos. Nada de esto es arbitrario.

2. Confirmá que no hay journal y después agregá uno en el lugar — esto es exactamente lo que convierte ext2 en ext3:

   ```bash
   dumpe2fs -h /dev/loop0p1 2>/dev/null | grep -E 'Filesystem (features|volume)'
   ```

   ```
   Filesystem volume name:   labext2
   Filesystem features:      ext_attr resize_inode dir_index filetype sparse_super large_file
   ```

   ```bash
   tune2fs -j /dev/loop0p1
   blkid /dev/loop0p1
   ```

   ```
   tune2fs 1.47.0 (5-Feb-2023)
   Creating journal inode: done

   /dev/loop0p1: LABEL="labext2" UUID="6c1d8f3e-..." BLOCK_SIZE="4096" TYPE="ext3"
   ```

   El `TYPE` que reporta `blkid` cambió de `ext2` a `ext3` porque apareció una bandera de característica: `has_journal`. No existe un "formato ext3" separado.

3. Ahora creá un ext4 real en la partición GPT con opciones relevantes para producción:

   ```bash
   mkfs.ext4 -L ext4-data -m 1 -E lazy_itable_init=0,lazy_journal_init=0 /dev/loop1p3
   ```

   ```
   mke2fs 1.47.0 (5-Feb-2023)
   Creating filesystem with 262144 4k blocks and 65536 inodes
   Filesystem UUID: b0e93f5a-1c4d-4f0e-8a77-33d1c6b2ef41
   Superblock backups stored on blocks:
   	32768, 98304, 163840, 229376

   Allocating group tables: done
   Writing inode tables: done
   Creating journal (8192 blocks): done
   Writing superblocks and filesystem accounting information: done
   ```

4. Leé el superbloque:

   ```bash
   dumpe2fs -h /dev/loop1p3 2>/dev/null
   ```

   ```
   Filesystem volume name:   ext4-data
   Last mounted on:          <not available>
   Filesystem UUID:          b0e93f5a-1c4d-4f0e-8a77-33d1c6b2ef41
   Filesystem magic number:  0xEF53
   Filesystem revision #:    1 (dynamic)
   Filesystem features:      has_journal ext_attr resize_inode dir_index filetype
                             extent 64bit flex_bg sparse_super large_file huge_file
                             dir_nlink extra_isize metadata_csum_seed metadata_csum
   Filesystem state:         clean
   Errors behavior:          Continue
   Filesystem OS type:       Linux
   Inode count:              65536
   Block count:              262144
   Reserved block count:     2621
   Free blocks:              243373
   Free inodes:              65525
   First block:              0
   Block size:               4096
   Reserved GDT blocks:      127
   Blocks per group:         32768
   Inodes per group:         8192
   Inode size:               256
   Journal size:             32M
   ```

   `Reserved block count: 2621` es el 1 % de 262144 — tu `-m 1`. El valor por defecto habría sido 5 % (13107 bloques, 51 MiB en un volumen de 1 GiB).

5. Usá la bandera de simulación para dimensionar un sistema de archivos *antes* de comprometerte con él. `-n` calcula e imprime sin escribir:

   ```bash
   mkfs.ext4 -n -i 1024 /dev/loop1p3
   ```

   ```
   mke2fs 1.47.0 (5-Feb-2023)
   Creating filesystem with 262144 4k blocks and 1048576 inodes
   Filesystem UUID: ...
   Superblock backups stored on blocks:
   	32768, 98304, 163840, 229376
   ```

   Un inodo cada 1024 bytes da 1 048 576 inodos en lugar de 65 536 — la perilla para un spool de correo o una caché de compilación llena de archivos diminutos. Como se usó `-n`, el sistema de archivos en disco queda intacto; confirmalo con `dumpe2fs -h` de nuevo.

6. Montalo, ajustá la reserva en un sistema de archivos vivo y observá la contabilidad:

   ```bash
   mkdir -p /mnt/lab/ext4
   mount /dev/loop1p3 /mnt/lab/ext4
   df -h /mnt/lab/ext4 ; df -i /mnt/lab/ext4
   ```

   ```
   Filesystem      Size  Used Avail Use% Mounted on
   /dev/loop1p3    974M   24K  963M   1% /mnt/lab/ext4

   Filesystem      Inodes IUsed IFree IUse% Mounted on
   /dev/loop1p3     65536    11 65525    1% /mnt/lab/ext4
   ```

   ```bash
   tune2fs -m 5 /dev/loop1p3
   df -h /mnt/lab/ext4 | tail -n 1
   ```

   ```
   Setting reserved blocks percentage to 5% (13107 blocks)
   /dev/loop1p3    974M   24K  922M   1% /mnt/lab/ext4
   ```

   41 MiB de "Avail" desaparecieron sin que se escribiera un solo byte. La reserva es un cambio de `tune2fs`, aplicable en cualquier momento; el conteo de inodos no.

7. Localizá un superbloque de respaldo — el número que vas a necesitar cuando el primario esté corrupto:

   ```bash
   dumpe2fs /dev/loop1p3 2>/dev/null | grep -i 'superblock at'
   ```

   ```
     Primary superblock at 0, Group descriptors at 1-1
     Backup superblock at 32768, Group descriptors at 32769-32769
     Backup superblock at 98304, Group descriptors at 98305-98305
     Backup superblock at 163840, Group descriptors at 163841-163841
     Backup superblock at 229376, Group descriptors at 229377-229377
   ```

   Forma de recuperación (no la ejecutes ahora, el sistema de archivos está montado y limpio): `e2fsck -b 32768 -B 4096 /dev/loop1p3`.

**Comprobá tu comprensión**

- **Q6.1** De `mkfs.ext2` sobre una partición de 512 MiB obtuviste exactamente 32768 inodos. Mostrá la aritmética e indicá qué opción de `mke2fs` lo cambia.
- **Q6.2** Después de `tune2fs -j`, `blkid` reporta `ext3`. ¿Se movieron los datos? ¿Qué única cosa cambió?
- **Q6.3** Necesitás almacenar 400 000 archivos pequeños en un volumen de 1 GiB con la configuración por defecto. ¿Qué se agota primero — el espacio o los inodos — y podés arreglarlo después del `mkfs`?
- **Q6.4** Explicá el propósito del 5 % de bloques reservados y dá las dos razones distintas por las que existe. ¿Cuándo es aceptable `-m 0`, y cuándo es una mala idea?
- **Q6.5** ¿Qué bandera de característica de ext4 hace posible el árbol de extents, y qué usaba ext3 en su lugar?
- **Q6.6** ¿Para qué sirven `-E lazy_itable_init=0,lazy_journal_init=0`, y cuál es el compromiso?
- **Q6.7** Tenés que recuperar un sistema de archivos cuyo superbloque primario está destruido. ¿Dónde encontrás un número de superbloque de respaldo si el propio `dumpe2fs` falla?

---

## Ejercicio 7 — XFS

**Pasos**

1. Creá el sistema de archivos en la partición GPT de 1 GiB:

   ```bash
   mkfs.xfs -L xfs-data /dev/loop1p2
   ```

   ```
   meta-data=/dev/loop1p2           isize=512    agcount=4, agsize=65536 blks
            =                       sectsz=512   attr=2, projid32bit=1
            =                       crc=1        finobt=1, sparse=1, rmapbt=0
            =                       reflink=1    bigtime=0 inobtcount=0
   data     =                       bsize=4096   blocks=262144, imaxpct=25
            =                       sunit=0      swidth=0 blks
   naming   =version 2              bsize=4096   ascii-ci=0, ftype=1
   log      =internal log           bsize=4096   blocks=2560, version=2
            =                       sectsz=512   sunit=0 blks, lazy-count=1
   realtime =none                   extsz=4096   blocks=0, rtextents=0
   ```

   Cuatro grupos de asignación de 65536 bloques cada uno — XFS paraleliza la asignación entre AGs, que es la razón por la que escala en sistemas con muchos núcleos y muchos husillos.

2. Montá e inspeccioná el sistema de archivos vivo:

   ```bash
   mkdir -p /mnt/lab/xfs
   mount /dev/loop1p2 /mnt/lab/xfs
   xfs_info /mnt/lab/xfs | head -n 3
   df -h /mnt/lab/xfs
   ```

   ```
   meta-data=/dev/loop1p2           isize=512    agcount=4, agsize=65536 blks
            =                       sectsz=512   attr=2, projid32bit=1
            =                       crc=1        finobt=1, sparse=1, rmapbt=0

   Filesystem      Size  Used Avail Use% Mounted on
   /dev/loop1p2   1014M   40M  975M   4% /mnt/lab/xfs
   ```

   XFS no tiene un porcentaje de bloques reservados expuesto como el `-m` de ext; los ~40 MiB de "Used" en un sistema de archivos vacío son metadatos y el log interno de 10 MiB.

3. Intentá reformatear un dispositivo que ya tiene un sistema de archivos, para ver el seguro de protección:

   ```bash
   umount /mnt/lab/xfs
   mkfs.xfs /dev/loop1p2
   ```

   ```
   mkfs.xfs: /dev/loop1p2 appears to contain an existing filesystem (xfs).
   mkfs.xfs: Use the -f option to force overwrite.
   ```

   ```bash
   mkfs.xfs -f -L xfs-data /dev/loop1p2 >/dev/null && echo "forced OK"
   mount /dev/loop1p2 /mnt/lab/xfs
   ```

4. Cambiá la etiqueta en línea — el equivalente XFS de `e2label`:

   ```bash
   xfs_admin -L xfs-prod /dev/loop1p2
   ```

   ```
   xfs_admin: /dev/loop1p2 contains a mounted filesystem
   fatal error -- couldn't initialize XFS library
   ```

   ```bash
   umount /mnt/lab/xfs
   xfs_admin -L xfs-prod /dev/loop1p2
   xfs_admin -l -u /dev/loop1p2
   ```

   ```
   writing all SBs
   new label = "xfs-prod"

   label = "xfs-prod"
   UUID = 4a91b2c7-58e0-4d33-9f21-6b0ac8e4d7f5
   ```

5. Observá la restricción de tamaño. Intentá crear un sistema de archivos XFS en un volumen pequeño:

   ```bash
   mkfs.xfs -f /dev/loop0p1
   ```

   ```
   mkfs.xfs: Filesystem must be larger than 300MB.
   Usage: mkfs.xfs ...
   ```

   (En una partición de 512 MiB tiene éxito; el mensaje de arriba es lo que obtenés por debajo del piso de 300 MiB impuesto desde xfsprogs 5.19. Las versiones recientes de xfsprogs también rechazan de plano tamaños menores a 16 MiB.)

6. Agrandá, y confirmá que no podés achicar:

   ```bash
   mount /dev/loop1p2 /mnt/lab/xfs
   xfs_growfs -D 300000 /mnt/lab/xfs
   ```

   ```
   data size 300000 too large, maximum is 262144
   ```

   La partición es el techo — primero agrandás la partición, después `xfs_growfs`. No existe `xfs_shrinkfs`; achicar requiere respaldo, `mkfs.xfs` y restauración.

**Comprobá tu comprensión**

- **Q7.1** ¿Qué es un grupo de asignación, y por qué XFS usa más de uno por defecto?
- **Q7.2** El log es "internal" por defecto. ¿Qué se almacena en él, y cuál es la razón operativa para ubicarlo en un dispositivo separado?
- **Q7.3** `mkfs.xfs` se negó a ejecutarse sin `-f`. ¿Qué otras variantes de `mkfs` tienen el mismo seguro, y cuáles no?
- **Q7.4** Nombrá las dos capacidades que ext4 tiene y XFS no, relevantes para la planificación de capacidad.
- **Q7.5** `xfs_admin -L` falló en un sistema de archivos montado pero `xfs_info` funcionó. ¿Qué distingue a los dos?
- **Q7.6** Un XFS de 1 GiB muestra 40 MiB usados cuando está vacío; un ext4 de 1 GiB muestra 24 KiB. ¿Son números comparables? Explicalo.

---

## Ejercicio 8 — VFAT y exFAT

**Pasos**

1. Formateá la EFI System Partition como FAT32. Indicá siempre `-F` explícitamente en lugar de dejar que la herramienta adivine FAT12/16/32 a partir del tamaño:

   ```bash
   mkfs.vfat -F 32 -n ESP /dev/loop1p1
   ```

   ```
   mkfs.fat 4.2 (2021-01-31)
   ```

   Esa única línea es toda la salida — `mkfs.vfat` es un enlace simbólico a `mkfs.fat` y es célebremente parco.

2. Verificá qué se escribió realmente:

   ```bash
   blkid /dev/loop1p1
   fatlabel /dev/loop1p1
   ```

   ```
   /dev/loop1p1: SEC_TYPE="msdos" LABEL_FATBOOT="ESP" LABEL="ESP" UUID="3C4A-91F7" TYPE="vfat"
   ESP
   ```

   Notá que el `UUID` es `3C4A-91F7` — ocho dígitos hexadecimales, no un UUID real de 128 bits. FAT no tiene campo UUID; esto es el número de serie del volumen, y es lo que `UUID=` en `/etc/fstab` va a hacer coincidir para un volumen FAT.

3. Observá las reglas de las etiquetas rompiéndolas:

   ```bash
   mkfs.vfat -F 32 -n "my long label" /dev/loop0p6
   ```

   ```
   mkfs.fat 4.2 (2021-01-31)
   mkfs.fat: Label can be no longer than 11 characters
   ```

   ```bash
   mkfs.vfat -F 32 -n DATOS /dev/loop0p6
   blkid /dev/loop0p6
   ```

   ```
   mkfs.fat 4.2 (2021-01-31)
   /dev/loop0p6: SEC_TYPE="msdos" LABEL_FATBOOT="DATOS" LABEL="DATOS" UUID="1B7E-4A02" TYPE="vfat"
   ```

4. Montalo y demostrá el modelo de propiedad:

   ```bash
   mkdir -p /mnt/lab/vfat
   mount -o uid=1000,gid=1000,umask=022 /dev/loop0p6 /mnt/lab/vfat
   touch /mnt/lab/vfat/hello.txt
   ls -l /mnt/lab/vfat
   chmod 700 /mnt/lab/vfat/hello.txt
   ```

   ```
   total 0
   -rw-r--r-- 1 1000 1000 0 Aug 26 11:04 hello.txt

   chmod: changing permissions of '/mnt/lab/vfat/hello.txt': Operation not permitted
   ```

   FAT no almacena ni propietario ni modo. Todo lo que ves proviene de las opciones de montaje, de manera uniforme para todo el sistema de archivos.

5. Formateá la partición lógica como exFAT:

   ```bash
   mkfs.exfat -L PORTABLE /dev/loop0p5
   ```

   ```
   exfatprogs version : 1.2.2
   Creating exFAT filesystem(/dev/loop0p5, cluster size=32768)

   Writing volume boot record: done
   Writing backup volume boot record: done
   Fat table creation: done
   Allocation bitmap creation: done
   Upcase table creation: done
   Writing root directory entry: done
   Synchronizing...

   exFAT format complete!
   ```

   ```bash
   blkid /dev/loop0p5
   ```

   ```
   /dev/loop0p5: LABEL="PORTABLE" UUID="A81C-3D0F" BLOCK_SIZE="512" TYPE="exfat"
   ```

   En sistemas más antiguos el paquete es `exfat-utils` y el comando es `mkfs.exfat` de ese proyecto o `mkexfatfs`, donde la opción de etiqueta es `-n` en lugar de `-L`. Revisá `mkfs.exfat --help` antes de armar un script.

6. Confirmá que el driver del kernel está presente:

   ```bash
   grep -E 'exfat|vfat|msdos' /proc/filesystems
   ```

   ```
   	vfat
   	exfat
   ```

   ```bash
   mkdir -p /mnt/lab/exfat
   mount /dev/loop0p5 /mnt/lab/exfat && df -h /mnt/lab/exfat
   ```

   ```
   Filesystem      Size  Used Avail Use% Mounted on
   /dev/loop0p5    500M  128K  500M   1% /mnt/lab/exfat
   ```

**Comprobá tu comprensión**

- **Q8.1** ¿Por qué una EFI System Partition tiene que ser FAT (normalmente FAT32), y no ext4 o XFS?
- **Q8.2** `blkid` reportó `UUID="3C4A-91F7"`. ¿Por qué son solo 8 dígitos hexadecimales, y cuál es la consecuencia práctica para `/etc/fstab` y para el riesgo de colisión al clonar un disco?
- **Q8.3** `chmod` falló en el volumen FAT montado. ¿Qué opciones de montaje controlan los permisos que *sí* ves, y a qué archivos se aplican?
- **Q8.4** Indicá el tamaño máximo de un archivo individual en FAT32 y la razón de ese límite. ¿Qué cambia exFAT?
- **Q8.5** Pusiste el tipo MBR `07` en la partición exFAT y `0c` en la FAT32. ¿Se montarían igual los sistemas de archivos si hubieras dejado ambas como `83`? ¿Qué se rompe?
- **Q8.6** ¿Por qué `mkfs.vfat -F 32` en una partición de 32 MiB merece pensarlo dos veces?

---

## Ejercicio 9 — Swap: `mkswap` y `swapon`

**Pasos**

1. Formateá la partición swap del MBR:

   ```bash
   mkswap -L labswap /dev/loop0p2
   ```

   ```
   Setting up swapspace version 1, size = 512 MiB (536866816 bytes)
   LABEL=labswap, UUID=e7d1c40b-3a58-4f92-b6ce-c0f9d2118a37
   ```

   La partición tiene 536870912 bytes pero el swap utilizable es 536866816 — exactamente una página de 4 KiB menos. Esa página es la cabecera del swap, que contiene la firma `SWAPSPACE2`, la etiqueta y el UUID.

2. Comprobá que `mkswap` no activó nada:

   ```bash
   swapon --show
   ```

   ```
   NAME      TYPE       SIZE USED PRIO
   /swapfile file       2G     0B   -2
   ```

   Solo aparece el swap preexistente del sistema. `mkswap` escribe una cabecera; `swapon` le dice al kernel que la use. Dos pasos separados, como `mkfs` y `mount`.

3. Activalo con una prioridad explícita y confirmá:

   ```bash
   swapon -p 10 /dev/loop0p2
   swapon --show
   cat /proc/swaps
   ```

   ```
   NAME          TYPE       SIZE USED PRIO
   /swapfile     file         2G   0B   -2
   /dev/loop0p2  partition  512M   0B   10

   Filename                 Type            Size            Used    Priority
   /swapfile                file            2097148         0       -2
   /dev/loop0p2             partition       524284          0       10
   ```

   Número más alto = se usa primero. Prioridades iguales en varios dispositivos hacen que el kernel las use por turnos (round-robin), que es la configuración correcta para varios discos idénticos.

4. Leé y cambiá los metadatos del swap sin volver a ejecutar `mkswap`:

   ```bash
   swaplabel /dev/loop0p2
   swapoff /dev/loop0p2
   swaplabel -L fastswap /dev/loop0p2
   swaplabel /dev/loop0p2
   ```

   ```
   LABEL: labswap
   UUID:  e7d1c40b-3a58-4f92-b6ce-c0f9d2118a37

   LABEL: fastswap
   UUID:  e7d1c40b-3a58-4f92-b6ce-c0f9d2118a37
   ```

5. Construí un *archivo* de swap y observá la verificación de permisos que atrapa un error de seguridad real:

   ```bash
   dd if=/dev/zero of=/var/tmp/lpic104/swapfile bs=1M count=256 status=none
   mkswap /var/tmp/lpic104/swapfile
   ```

   ```
   mkswap: /var/tmp/lpic104/swapfile: insecure permissions 0644, fix with: chmod 0600 /var/tmp/lpic104/swapfile
   Setting up swapspace version 1, size = 256 MiB (268431360 bytes)
   no label, UUID=1f0b7c9a-5d24-4e88-b3a1-9c6e0d51fa22
   ```

   ```bash
   chmod 0600 /var/tmp/lpic104/swapfile
   swapon /var/tmp/lpic104/swapfile
   swapon --show | tail -n 1
   swapoff /var/tmp/lpic104/swapfile
   ```

   ```
   /var/tmp/lpic104/swapfile file 256M 0B  -3
   ```

   Usar `dd` en lugar de `fallocate` es deliberado: un archivo creado con `fallocate` puede contener huecos, y hacer swap sobre un archivo disperso o copy-on-write (notablemente en Btrfs sin `chattr +C` y un archivo debidamente preparado) falla o corrompe.

6. Escribí la entrada persistente como corresponde — por UUID, nunca por nombre de dispositivo:

   ```bash
   blkid -s UUID -o value /dev/loop0p2
   ```

   ```
   e7d1c40b-3a58-4f92-b6ce-c0f9d2118a37
   ```

   La línea correspondiente de `/etc/fstab` sería (**no** la agregues para un dispositivo loop — va a romper el próximo arranque):

   ```
   UUID=e7d1c40b-3a58-4f92-b6ce-c0f9d2118a37   none   swap   sw,pri=10   0   0
   ```

**Comprobá tu comprensión**

- **Q9.1** Después de `mkswap`, `swapon --show` no listó el dispositivo nuevo. ¿Por qué eso es el comportamiento correcto y no un bug?
- **Q9.2** `mkswap` sobre una partición de 512 MiB reportó 536866816 bytes. Justificá los 4096 bytes que faltan.
- **Q9.3** Tenés cuatro SSD idénticos y querés repartir el swap entre todos. ¿Qué prioridad le asignás a cada uno, y qué pasa si en cambio asignás 40, 30, 20, 10?
- **Q9.4** ¿Por qué `mkswap` advierte sobre el modo 0644, dado que solo root puede invocar `swapon`?
- **Q9.5** En la línea de `fstab` de arriba, el punto de montaje es `none` y los campos dump/pass son `0 0`. Explicá cada una de esas tres elecciones.
- **Q9.6** ¿Qué ID de tipo MBR y qué GUID de tipo GPT identifican una partición de swap de Linux, y alguno de los dos hace que el kernel la use como swap automáticamente?

---

## Ejercicio 10 — Conocimiento general: Btrfs y ReiserFS

El objetivo requiere *conocimiento general* de estos dos, no dominio. Sabé qué son y en qué estado están.

**Pasos**

1. Creá un sistema de archivos Btrfs y leé los valores por defecto que anuncia:

   ```bash
   mkfs.btrfs -L btrfs-data /dev/loop1p4
   ```

   ```
   btrfs-progs v6.2

   NOTE: several default settings have changed in version 5.15, please make sure
         this does not affect your deployments:
         - DUP for metadata (mixed for small filesystems)
         - enabled no-holes
         - enabled free-space-tree

   Label:              btrfs-data
   UUID:               d2a7f114-6b90-4e35-8c02-71ab4f9d5e63
   Node size:          16384
   Sector size:        4096
   Filesystem size:    1.00GiB
   Block group profiles:
     Data:             single            8.00MiB
     Metadata:         DUP              51.19MiB
     System:           DUP               8.00MiB
   SSD detected:       no
   Checksum:           crc32c
   Number of devices:  1
   Devices:
      ID        SIZE  PATH
       1     1.00GiB  /dev/loop1p4
   ```

   `Metadata: DUP` significa dos copias de todos los metadatos en un solo dispositivo — Btrfs calcula la suma de verificación de cada bloque y por lo tanto puede *detectar* corrupción y, con una segunda copia, repararla.

2. Montalo y mirá las dos visiones distintas del "espacio libre":

   ```bash
   mkdir -p /mnt/lab/btrfs
   mount /dev/loop1p4 /mnt/lab/btrfs
   df -h /mnt/lab/btrfs
   btrfs filesystem usage /mnt/lab/btrfs
   ```

   ```
   Filesystem      Size  Used Avail Use% Mounted on
   /dev/loop1p4    1.0G  5.6M  885M   1% /mnt/lab/btrfs

   Overall:
       Device size:                   1.00GiB
       Device allocated:             130.38MiB
       Device unallocated:           893.62MiB
       Used:                         256.00KiB
       Free (estimated):             885.44MiB      (min: 438.62MiB)
   ```

   `df` en Btrfs es una estimación; el segundo número, "min", refleja que los metadatos futuros se van a escribir dos veces.

3. Creá un subvolumen — un concepto de Btrfs sin equivalente en ext4 o XFS:

   ```bash
   btrfs subvolume create /mnt/lab/btrfs/@data
   btrfs subvolume list /mnt/lab/btrfs
   ```

   ```
   Create subvolume '/mnt/lab/btrfs/@data'
   ID 256 gen 8 top level 5 path @data
   ```

4. Comprobá la disponibilidad de ReiserFS en tu sistema:

   ```bash
   grep -c reiserfs /proc/filesystems ; modinfo reiserfs 2>&1 | head -n 3
   ```

   ```
   0
   modinfo: ERROR: Module reiserfs not found.
   ```

   En muchas distribuciones actuales el módulo ya no se compila. ReiserFS (v3) fue marcado como **obsoleto (deprecated)** en Linux 6.6 y está previsto que se elimine del kernel; su herramienta de creación es `mkfs.reiserfs` de `reiserfsprogs`, y su herramienta de ajuste es `reiserfstune`. Para el examen, conocé los nombres y sabé que es legado. Reiser4 nunca fue integrado al kernel principal.

**Comprobá tu comprensión**

- **Q10.1** ¿Por qué `mkfs.btrfs` usa `DUP` para metadatos por defecto en un solo dispositivo, y contra qué clase de falla *no* protege eso?
- **Q10.2** `df` reportó 885M disponibles en un volumen Btrfs de 1 GiB con 5,6M usados. ¿Por qué no cierra la cuenta, y por qué `btrfs filesystem usage` es la visión autoritativa?
- **Q10.3** Nombrá una cosa que te da un subvolumen Btrfs y que un directorio en ext4 no.
- **Q10.4** Para el examen: ¿qué dos herramientas crean sistemas de archivos ReiserFS y Btrfs, y cuál es el estado actual de ReiserFS en el kernel principal?
- **Q10.5** Btrfs y XFS soportan ambos características de copy-on-write. ¿Cuál de los dos elegirías para un volumen de base de datos, y cuál es la preocupación relacionada con CoW?

---

## Ejercicio 11 — Diagnóstico: "el kernel no ve mi partición nueva"

Esta es la falla del mundo real más común en este tema, y es la que vale la pena poder arreglar sin reiniciar.

**Pasos**

1. Reproducila. Asegurate de que una partición del disco MBR esté en uso, después intentá cambiar la tabla:

   ```bash
   mount /dev/loop0p6 /mnt/lab/vfat 2>/dev/null
   echo -e 'n\np\n' | fdisk /dev/loop0 2>&1 | tail -n 4
   ```

   Una reproducción más directa con `partprobe` mientras una partición está montada:

   ```bash
   partprobe /dev/loop0 ; echo "exit=$?"
   ```

   ```
   Error: Partition(s) 6 on /dev/loop0 have been written, but we have been unable
   to inform the kernel of the change, probably because it/they are in use.  As a
   result, the old partition(s) will remain in use.  You should reboot now before
   making further changes.
   exit=1
   ```

2. Entendé las tres palancas que tenés:

   ```bash
   partprobe /dev/loop0        # re-read the whole table (parted)
   partx -u /dev/loop0         # update kernel's view from the on-disk table
   partx -a -n 7 /dev/loop0    # add only partition 7
   partx -d -n 7 /dev/loop0    # remove only partition 7 from the kernel view
   blockdev --rereadpt /dev/loop0
   ```

   `partprobe` y `blockdev --rereadpt` son todo o nada y fallan cuando *cualquier* partición del dispositivo está ocupada. `partx` opera por partición, así que puede agregar una partición 7 recién creada mientras las particiones 1–6 siguen montadas. Ese es el arreglo que evita un reinicio.

3. Liberá el dispositivo y confirmá la recuperación:

   ```bash
   umount /mnt/lab/vfat
   partprobe /dev/loop0 ; echo "exit=$?"
   lsblk /dev/loop0
   ```

   ```
   exit=0
   ```

4. Diagnosticá un problema de firma obsoleta. Escribí dos firmas de sistema de archivos en el mismo dispositivo y mirá cómo `blkid` se vuelve ambiguo:

   ```bash
   umount /mnt/lab/exfat
   mkfs.ext4 -q -F /dev/loop0p5
   wipefs /dev/loop0p5
   ```

   ```
   DEVICE OFFSET TYPE  UUID                                 LABEL
   loop0p5 0x0    exfat A81C-3D0F                            PORTABLE
   loop0p5 0x438  ext4  9a3c1e77-0b52-4d18-a6f4-2e8b70c1d539
   ```

   Dos firmas, en desplazamientos distintos, ambas intactas. `mkfs.ext4` escribió su superbloque en el byte 1024 sin borrar el registro de arranque de exFAT en el desplazamiento 0. Las herramientas que sondean por prioridad ahora pueden elegir la equivocada, y `mount -t auto` se vuelve impredecible.

5. Limpialo como corresponde:

   ```bash
   wipefs -a /dev/loop0p5
   wipefs /dev/loop0p5 ; echo "signatures left: $?"
   blkid /dev/loop0p5 ; echo "exit=$?"
   ```

   ```
   /dev/loop0p5: 2 bytes were erased at offset 0x00000438 (ext4): 53 ef
   /dev/loop0p5: 8 bytes were erased at offset 0x00000003 (exfat): 45 58 46 41 54 20 20 20
   ...
   signatures left: 0
   exit=2
   ```

   Hábito que vale la pena adquirir: `wipefs -a` **antes** de cada `mkfs` sobre medios reutilizados.

6. Verificá que el tipo de sistema de archivos que pensás usar está realmente soportado por el kernel en ejecución antes de comprometerte con él en una construcción:

   ```bash
   cat /proc/filesystems | grep -v nodev
   ls /sbin/mkfs.* /usr/sbin/mkfs.* 2>/dev/null
   ```

   ```
   	ext3
   	ext2
   	ext4
   	vfat
   	xfs
   	btrfs
   	exfat

   /usr/sbin/mkfs.btrfs  /usr/sbin/mkfs.exfat  /usr/sbin/mkfs.ext2
   /usr/sbin/mkfs.ext3   /usr/sbin/mkfs.ext4   /usr/sbin/mkfs.fat
   /usr/sbin/mkfs.minix  /usr/sbin/mkfs.msdos  /usr/sbin/mkfs.vfat
   /usr/sbin/mkfs.xfs
   ```

   `mkfs -t <type>` es solo un despachador: ejecuta (`exec`) `mkfs.<type>` desde `$PATH`. Si `mkfs.xfs` no está instalado, `mkfs -t xfs` falla con "mkfs.xfs: not found", no con un error del kernel.

**Comprobá tu comprensión**

- **Q11.1** ¿Por qué `partx -a` puede tener éxito donde `partprobe` falla, en el mismo dispositivo y en el mismo momento?
- **Q11.2** `wipefs` listó una firma exFAT en el desplazamiento 0x0 y una de ext4 en 0x438. Convertí 0x438 a decimal y explicá por qué ext ubica su superbloque ahí.
- **Q11.3** Ejecutaste `mkfs.ext4` sobre un volumen exFAT viejo y ahora `mount` a veces elige el tipo equivocado. ¿Cuál es el arreglo de un solo comando, y cuál es el hábito correcto?
- **Q11.4** `mkfs -t xfs /dev/sdb1` devuelve "not found" en una imagen de contenedor mínima. ¿El problema es el kernel o el espacio de usuario? ¿Cómo verificás cada uno?
- **Q11.5** ¿En qué situación un reinicio es genuinamente la única forma de que el kernel vea una tabla de particiones modificada?

---

## 12. Limpieza

Ejecutá esto en orden. Nada de acá toca un disco real, pero es exactamente el orden que usarías en producción.

```bash
umount /mnt/lab/ext4 /mnt/lab/xfs /mnt/lab/vfat /mnt/lab/btrfs 2>/dev/null
swapoff /dev/loop0p2 2>/dev/null
swapoff /var/tmp/lpic104/swapfile 2>/dev/null
losetup -d /dev/loop0 /dev/loop1
losetup -a
rm -rf /var/tmp/lpic104 /mnt/lab
```

`losetup -a` no debe imprimir nada para tus dispositivos loop. Si `losetup -d` reporta "Device or resource busy", algo sigue montado o sigue activo como swap — encontralo con `lsof` / `swapon --show`, no con `--force`.

---

## Referencia de comandos para este objetivo

| Tarea | Comando |
|---|---|
| Particionado MBR, interactivo | `fdisk /dev/sdX` |
| Particionado GPT, interactivo | `gdisk /dev/sdX` (o `fdisk` → `g`) |
| Particionado GPT, por script | `sgdisk -n 1:0:+512M -t 1:ef00 /dev/sdX` |
| Cualquier etiqueta, por script | `parted -s -a optimal /dev/sdX mklabel gpt mkpart ...` |
| Volcar / restaurar una tabla | `sfdisk --dump`, `sfdisk /dev/sdX < file`, `sgdisk --backup=` |
| ext2 / ext3 / ext4 | `mkfs.ext2`, `mkfs.ext3`, `mkfs.ext4` (todos `mke2fs`) |
| Inspeccionar / ajustar ext | `dumpe2fs -h`, `tune2fs -l`, `tune2fs -m/-L/-U/-j`, `e2label` |
| XFS | `mkfs.xfs [-f]`, `xfs_info`, `xfs_admin -L/-U`, `xfs_growfs` |
| FAT | `mkfs.vfat -F 32 -n LABEL`, `fatlabel`, `fsck.fat` |
| exFAT | `mkfs.exfat -L LABEL` (exfatprogs) |
| Btrfs | `mkfs.btrfs -L LABEL`, `btrfs filesystem show/usage` |
| ReiserFS (legado) | `mkfs.reiserfs`, `reiserfstune` |
| Swap | `mkswap -L`, `swapon -p N`, `swapoff`, `swaplabel` |
| Identificar | `lsblk -f`, `blkid`, `blkid -p`, `findmnt` |
| Refrescar la vista del kernel | `partprobe`, `partx -u/-a/-d`, `blockdev --rereadpt` |
| Borrar firmas | `wipefs -a`, `sgdisk --zap-all` |

---

<details>
<summary><strong>Respuestas — clic para expandir</strong></summary>

### Ejercicio 1

**A1.1** Prueba únicamente que `blkid` **no encontró ninguna firma reconocida de sistema de archivos, RAID o tabla de particiones** en los lugares donde sondea. El código de salida 2 significa "no se encontró nada". **No** prueba que el dispositivo esté vacío, sin uso, o que sea seguro sobrescribirlo: el dispositivo puede contener un formato propietario, un volumen cifrado sin firma de cabecera, un sistema de archivos con el superbloque corrupto, o datos perfectamente buenos sin número mágico. "`blkid` no dice nada" nunca es autorización suficiente para ejecutar `mkfs`.

**A1.2** (1) El disco genuinamente no tiene tabla de particiones, o su tabla está vacía. (2) El kernel no volvió a leer la tabla desde que cambió — la partición existe en el disco pero no se creó ningún dispositivo de bloque para ella (se arregla con `partx -u` / `partprobe`). Otras respuestas válidas: el dispositivo se usa entero, sin particiones (común para PVs de LVM, DRBD, o un sistema de archivos escrito directamente sobre `/dev/sdb`); o, específicamente para dispositivos loop, se invocó `losetup` sin `-P`.

**A1.3** Es una unidad **512e** (sectores físicos de 4 KiB, emulación lógica de 512 bytes). Una partición que empieza en el sector 63 está desalineada: cada escritura lógica que no comienza en un límite de 4096 bytes fuerza a la unidad a un ciclo de lectura-modificación-escritura — leer el sector físico completo de 4 KiB, fusionar el cambio, escribirlo de vuelta. El rendimiento en escrituras aleatorias pequeñas puede caer más de la mitad. Empezar en el sector 2048 (1 MiB) es múltiplo de 4096 bytes y de todos los tamaños de franja (stripe) de RAID comunes, y por eso toda herramienta moderna lo usa por defecto.

**A1.4** Porque los nombres de dispositivo del kernel se asignan en **orden de descubrimiento**, no por posición física. Agregar un disco, cambiar una controladora, o una unidad que arranca lento pueden convertir el `/dev/sdb` de ayer en el `/dev/sdc` de hoy. `MODEL`, `SERIAL`, `SIZE` y `WWN` son propiedades del hardware en sí; `/dev/disk/by-id/` te da nombres de ruta estables construidos a partir de ellas.

---

### Ejercicio 2

**A2.1** 2048 × 512 = 1 048 576 bytes = **1 MiB**. Empezar en 1 MiB garantiza que la partición comience en un límite que es múltiplo de sectores físicos de 4 KiB, de los tamaños típicos de bloque de borrado y de página de un SSD, y de los tamaños de franja de RAID — un solo valor por defecto que los satisface a todos. También deja lugar después del MBR para el código del cargador de arranque (la imagen core de GRUB en sistemas BIOS con arranque MBR vive en esa brecha).

**A2.2** No — al kernel no le importa. El byte de tipo es **metadato informativo**, una pista para cargadores de arranque, herramientas de particionado, instaladores y otros sistemas operativos sobre qué se *pretende* que contenga la partición. Linux va a poner ext4 sin problema en una partición marcada como `82`, y `swapon` va a rechazar una partición marcada como `83` solo si le falta la cabecera de swap — lo que importa es la cabecera, no el byte. El byte de tipo se vuelve funcionalmente significativo en unos pocos casos: `05`/`0f` define genuinamente una partición extendida, `ee` define un MBR protector, y `8e` es cómo algunas herramientas autodetectan LVM.

**A2.3** `00 08 00 00` en little-endian es `0x00000800` = **2048**. Los campos del MBR se almacenan en little-endian porque el formato se origina en x86, donde la CPU es little-endian; el byte menos significativo va primero en memoria y por lo tanto primero en el disco.

**A2.4** 2³² sectores × 512 bytes = 2 199 023 255 552 bytes = **2 TiB**. El campo de LBA de inicio también es de 32 bits, así que una partición ni siquiera puede empezar más allá de 2 TiB. En una unidad 4Kn (sectores lógicos de 4096 bytes) el mismo campo de 32 bits direcciona 2³² × 4096 = **16 TiB**, y por eso algunos dispositivos 4Kn de gran capacidad todavía pueden particionarse con MBR — pero esto es frágil y poco portable; GPT es la respuesta correcta por encima de 2 TiB.

**A2.5** `sfdisk --dump` produce una **descripción de texto legible, editable y portable** del layout de particiones que puede reproducirse en un disco distinto, compararse con `diff` y versionarse en control de versiones. Captura también las definiciones de las particiones lógicas de toda la cadena extendida. El `dd` del sector 0 captura los **bytes exactos**, incluyendo el código del cargador de arranque en los primeros 446 bytes y el identificador de disco — que el volcado de texto no puede reproducir por completo — pero es opaco, específico del tamaño del disco, y *no* incluye los EBR de las particiones lógicas. Hacé las dos cosas: cubren fallas distintas.

---

### Ejercicio 3

**A3.1** Porque los números 1–4 están permanentemente reservados para los cuatro slots primarios del MBR, estén poblados o no. Las particiones lógicas viven en una cadena dentro de la partición extendida y se numeran desde 5 en adelante por convención, así que `/dev/sda5` puede existir cuando solo existen `/dev/sda1` y `/dev/sda2`.

**A3.2** La partición extendida se define por un byte de tipo (`05`, o `0f` para LBA) en uno de los cuatro slots del MBR, y el proceso de arranque y todas las herramientas de particionado siguen exactamente una cadena de EBRs. No hay ningún campo en ninguna parte del formato que distinga "cadena A" de "cadena B", ni forma de que una herramienta sepa a qué partición extendida pertenece una partición lógica dada. El límite es estructural, no una política que la herramienta imponga.

**A3.3** Previene que alguien ejecute `mkfs` o `dd` contra el nodo de dispositivo de la partición extendida. El primer sector de la partición extendida *es* el primer EBR; escribir un sistema de archivos ahí destruye la cabeza de la lista enlazada y por lo tanto vuelve inalcanzables de golpe todas las particiones lógicas del disco. Al exponer solo 1 KiB, el kernel hace que el error falle de inmediato en lugar de silenciosamente.

**A3.4** La brecha contiene el **EBR** — el registro de arranque extendido de 512 bytes de esa partición lógica, que contiene la entrada que la describe y el puntero al siguiente EBR. Estrictamente necesita **un sector**. `fdisk` deja 2048 sectores para que la partición lógica en sí empiece en un límite de 1 MiB; la alineación vale 1 MiB de desperdicio por partición lógica.

**A3.5** La partición 6 se **renumera a 5**. La numeración de las particiones lógicas es posicional dentro de la cadena, no está almacenada en el disco — quitá un eslabón y todo lo que sigue se corre hacia abajo. Cualquier entrada de `/etc/fstab` escrita como `/dev/sda6` ahora apunta a lo que antes era otro sistema de archivos, o a nada. Esta es la razón concreta por la que `fstab` debería referenciar `UUID=` o `LABEL=`, que siguen al sistema de archivos en lugar de a su posición.

---

### Ejercicio 4

**A4.1** El LBA 0 es el MBR protector, el LBA 1 es la cabecera GPT primaria, y los LBAs 2–33 contienen el arreglo de entradas de partición: 128 entradas × 128 bytes = 16 384 bytes = 32 sectores de 512 bytes. 2 + 32 = 34, así que el primer sector disponible para una partición es el **34**.

**A4.2** El disco tiene 8 388 608 sectores, numerados del 0 al 8 388 607. La cabecera GPT de **respaldo** ocupa el último sector (8 388 607) y el arreglo de entradas de partición de respaldo ocupa los 32 sectores anteriores (8 388 575–8 388 606). El último sector usable es por lo tanto **8 388 574** — un arreglo de respaldo completo más una cabecera por debajo del final, no apenas un sector, porque GPT duplica ambas estructuras.

**A4.3** Es el **MBR protector**: una única entrada de MBR de tipo `0xEE` que abarca todo el disco (limitada a 0xFFFFFFFF sectores en discos mayores a 2 TiB). Una herramienta antigua que no conoce GPT lee el sector 0 y ve un disco enteramente ocupado por un tipo de partición desconocido, así que reporta "sin espacio libre" y se niega a crear particiones, en lugar de ver un disco aparentemente en blanco y alegremente escribir un MBR nuevo encima de la GPT.

**A4.4** Los GUID de tipo de GPT son globalmente únicos y **autodescriptivos entre sistemas operativos y arquitecturas**, así que pueden codificar semántica que un espacio de nombres de 1 byte no puede. La Discoverable Partition Specification explota esto: una partición con el GUID de `x86-64 root` (`4f68bce3-e8cd-4db1-96e7-fbcaf984b709`) puede ser montada como `/` por el initramfs sin `/etc/fstab` y sin línea de comandos del kernel, y `/home`, `/srv`, `/var` y swap tienen sus propios GUIDs. GPT también almacena un **nombre** UTF-16 de 36 caracteres y banderas de atributos por partición, ninguno de los cuales existe en MBR.

**A4.5** Solo se perdió el **MBR protector** del sector 0. La cabecera GPT primaria en el LBA 1, el arreglo de particiones primario en los LBAs 2–33, y toda la GPT de respaldo al final del disco sobreviven — así que no se perdió ningún dato de particiones. En `gdisk`, `r` entra al menú de recuperación y transformación; desde ahí `b` reconstruye el MBR protector a partir de la GPT (y `c`/`d`/`e` se encargan de cargar o reconstruir desde la cabecera de respaldo si la primaria también estuviera dañada). `w` lo escribe de vuelta. `sgdisk -e /dev/sdb` o `sgdisk --load-backup=` son los equivalentes por script.

**A4.6** **128** particiones. El número está almacenado en la propia cabecera GPT, en el campo `NumberOfPartitionEntries`, junto con `SizeOfPartitionEntry` — así que no es un límite duro del formato; 128 es simplemente el valor por defecto casi universal, elegido para que el arreglo ocupe unos cómodos 16 KiB. `gdisk` lo reporta como "Partition table holds up to 128 entries".

---

### Ejercicio 5

**A5.1** Estableció el **GUID de tipo** de la partición al asociado con datos genéricos de sistema de archivos Linux, y registró una pista en la visión de `parted`. **No** creó un sistema de archivos, no escribió un superbloque, ni hizo que la partición fuera montable. Todavía tenés que ejecutar `mkfs.ext4 /dev/loop1p5`. Este es uno de los malentendidos más persistentes sobre `parted`: el argumento `fs-type` de `mkpart` es una etiqueta, no una acción. (Los viejos comandos `parted mkfs`/`mkpartfs` que *sí* creaban sistemas de archivos fueron eliminados hace años precisamente porque no tenían mantenimiento y no eran seguros.)

**A5.2** `MiB` es más grande: 1 MiB = 1 048 576 bytes frente a 1 MB = 1 000 000 bytes, una diferencia del 4,86 %. Compuesta a escala tera, la brecha es de ~10 %: un disco de "4 TB" (4 000 000 000 000 bytes) son 3,64 TiB. Cuando especifiques límites de partición, usá siempre las unidades binarias (`MiB`, `GiB`) — son en las que se expresa la aritmética de alineación, y `parted` las acepta explícitamente.

**A5.3** `minimal` verifica que la partición satisfaga la granularidad *mínima* de E/S del dispositivo — suficiente para evitar lectura-modificación-escritura sobre el tamaño de sector físico (`minimum_io_size`, típicamente el sector físico o el chunk de RAID). `optimal` es más estricto: verifica la alineación al tamaño de E/S *óptimo* del dispositivo (`optimal_io_size`, por ejemplo el ancho completo de una franja de RAID, o el valor por defecto de 1 MiB cuando el dispositivo no reporta nada). Una partición puede pasar `minimal` y fallar `optimal`, y aun así funcionar correctamente — solo que más lento en almacenamiento con franjas.

**A5.4** Porque la interfaz de `fdisk` es un menú manejado por pulsaciones de teclas con prompts y valores por defecto que dependen del contexto y varían según la versión de util-linux, así que manejarlo desde un script significa canalizar un bloque frágil de pulsaciones y esperar que la secuencia de prompts no haya cambiado. `parted -s` (modo script: sin prompts, sin confirmaciones interactivas), `sgdisk` y `sfdisk` toman el layout como **argumentos o un archivo de volcado declarativo**, devuelven códigos de salida significativos, y son estables entre versiones. `sfdisk` en particular hace ida y vuelta con su propio formato `--dump`, lo que convierte "capturar el layout, reproducirlo en el disco de reemplazo" en una operación de dos comandos.

**A5.5**
- `sgdisk --zap-all` destruye las **estructuras GPT** (tanto la primaria como la de respaldo) y el MBR protector. No toca los superbloques de sistemas de archivos dentro de las particiones viejas.
- `wipefs -a` borra **firmas mágicas** — superbloques de sistemas de archivos, superbloques de RAID, etiquetas de LVM y firmas de tablas de particiones — en sus desplazamientos conocidos dentro del dispositivo que se le indique. Elimina aquello en lo que se basan las herramientas de sondeo, con precisión y con un registro impreso de lo que borró.
- `dd if=/dev/zero bs=1M count=10` sobrescribe incondicionalmente los **primeros 10 MiB**, lo que destruye el MBR/la GPT primaria y típicamente el superbloque del primer sistema de archivos, pero deja intacta la **GPT de respaldo al final del disco** — un clásico borrado a medias que hace que las herramientas encuentren una tabla fantasma. Si usás `dd`, tenés que poner en cero también la cola.

---

### Ejercicio 6

**A6.1** La partición tiene 512 MiB = 536 870 912 bytes. `mke2fs` usa por defecto un inodo cada 16 384 bytes (`inode_ratio` para el tipo `default` en `/etc/mke2fs.conf`): 536 870 912 ÷ 16 384 = **32 768**. Cambialo con `-i <bytes-por-inodo>` (valor más chico → más inodos), con `-N <cantidad>` para indicar el número directamente, o con `-T <usage-type>` para seleccionar un perfil distinto de `mke2fs.conf` (`news`, `largefile`, `largefile4`).

**A6.2** No se movió ningún dato, y no se reescribió ningún archivo existente. `tune2fs -j` asignó un **inodo de journal** y activó la bandera de característica `has_journal` en el superbloque. `blkid` reporta el tipo inspeccionando las banderas de características, así que un sistema de archivos con `has_journal` se reporta como ext3. ext2, ext3 y ext4 son la misma familia en disco, distinguidas por banderas de características — que es también la razón por la que un sistema de archivos ext4 que no usa características exclusivas de ext4 puede ser montado por el driver ext3.

**A6.3** Se agotan primero los **inodos**. Con la relación por defecto de 16 KiB por inodo, un volumen de 1 GiB obtiene 65 536 inodos, así que el archivo número 65 526 o por ahí falla con `ENOSPC` — "No space left on device" — mientras `df -h` todavía muestra la mayor parte del volumen libre. `df -i` revela la causa real. **No** se puede arreglar después del `mkfs`: el conteo de inodos queda fijado en el momento de la creación para ext2/3/4 (`resize2fs` agrega inodos solo proporcionalmente cuando el sistema de archivos crece). El remedio es respaldar, `mkfs.ext4 -i 4096` (o `-N 500000`), y restaurar. XFS asigna inodos dinámicamente y no tiene este modo de falla.

**A6.4** Dos razones distintas: (1) **Seguridad operativa** — los bloques reservados solo son escribibles por root (o por el UID/GID configurado con `tune2fs -u`/`-g`), así que cuando un log descontrolado llena un sistema de archivos compartido, root todavía puede iniciar sesión, escribir en `/var/log` y ejecutar comandos de recuperación; en `/` específicamente, un sistema de archivos raíz completamente lleno puede impedir que el sistema arranque. (2) **Evitar la fragmentación** — el asignador de bloques de ext se degrada mucho cuando un sistema de archivos se acerca al 100 % de ocupación, porque ya no puede encontrar tramos contiguos; mantener un margen preserva la calidad de la asignación. `-m 0` es razonable en un volumen grande y dedicado a **datos** en el que root nunca necesita escribir y que está monitoreado — una reserva del 5 % en un volumen de archivo de 16 TB son 800 GB de capacidad desperdiciada. `-m 0` es una mala idea en `/`, `/var`, o cualquier sistema de archivos donde la recuperación del propio sistema dependa de poder escribir.

**A6.5** La característica `extent`. ext3 usaba **mapeo de bloques indirecto**: una lista de punteros a bloques, con bloques indirectos simples, dobles y triples para archivos más grandes — así que un archivo de 1 GiB necesitaba cientos de miles de punteros, y borrarlo significaba leerlos todos. Un extent describe un rango contiguo como `(inicio, longitud)`, así que el mismo archivo puede necesitar un puñado de extents. Esta es la razón principal por la que el rendimiento con archivos grandes y la latencia de `unlink` mejoraron tanto en ext4.

**A6.6** Por defecto `mke2fs` retorna rápido y deja que el kernel ponga en cero las tablas de inodos y el journal de forma perezosa, en segundo plano, después de que el sistema de archivos se monta por primera vez. Poner ambos en `0` obliga a `mkfs` a hacer ese trabajo **inmediatamente y de forma síncrona**. El compromiso: `mkfs` tarda mucho más (minutos en un disco giratorio de varios terabytes), pero el rendimiento del sistema de archivos es predecible desde el primer montaje en lugar de estar degradado por la puesta a cero en segundo plano, y cada bloque fue tocado — útil para benchmarking y para imágenes que se van a verificar por checksum o aprovisionar de forma fina y determinista.

**A6.7** Dos opciones gratuitas: (1) `mke2fs -n` con **los mismos parámetros que crearon el sistema de archivos** — calcula e imprime las ubicaciones de los superbloques de respaldo sin escribir nada. Por eso importa registrar las opciones originales del `mkfs`. (2) Los valores por defecto son predecibles: con bloques de 4 KiB y `sparse_super`, los respaldos están al inicio de los grupos de bloques 1, 3, 5, 7, 9, 25, 27, 49… y los grupos de bloques son de 32 768 bloques, dando 32768, 98304, 163840, 229376, 294912…; con bloques de 1 KiB, 8193, 24577, 40961, 57345, 73729. Después `e2fsck -b 32768 -B 4096 /dev/sdXN`. Pasá siempre `-B` (tamaño de bloque) junto con `-b`, ya que `e2fsck` no puede inferirlo de un superbloque primario destruido.

---

### Ejercicio 7

**A7.1** Un grupo de asignación es una región independiente y autocontenida de un sistema de archivos XFS, cada una con sus propios árboles B de espacio libre y árboles B de inodos. Como las estructuras de metadatos son por AG, las asignaciones en AGs distintos pueden avanzar **en paralelo sin contender por un único lock**, que es la razón arquitectónica por la que XFS escala con la cantidad de núcleos y de husillos. El compromiso es que cada AG cuesta sobrecarga de metadatos, y las operaciones entre AGs son más caras; `mkfs.xfs` los dimensiona automáticamente (4 AGs en un volumen chico, más en uno grande) vía `agcount`/`agsize`.

**A7.2** El log contiene el **journal**: los cambios de metadatos se escriben ahí y se confirman antes de las actualizaciones de metadatos en el lugar, así que una caída deja un registro reproducible en lugar de un árbol inconsistente. XFS registra en el journal solo metadatos, no datos de archivo. Ubicar el log en un dispositivo separado (`mkfs.xfs -l logdev=/dev/nvme0n1p1`) saca las escrituras síncronas, pequeñas y secuenciales del log de la cabeza del dispositivo de datos — históricamente una gran ganancia en almacenamiento rotacional, y todavía útil cuando el dispositivo de log es mucho más rápido (log en NVMe delante de un arreglo lento) o cuando querés las escrituras del log fuera de un dispositivo muy disputado. El riesgo es que el dispositivo de log se convierte en un punto único de falla para todo el sistema de archivos.

**A7.3** `mkfs.xfs`, `mkfs.btrfs` y `mkfs.exfat` se niegan a sobrescribir un dispositivo que ya contiene un sistema de archivos reconocido salvo que se fuerce (`-f`). `mke2fs` pregunta de forma interactiva ("Proceed anyway? (y,N)") cuando el dispositivo está montado o parece en uso, y tiene `-F` para forzar — pero va a formatear un dispositivo que contiene un sistema de archivos viejo *no montado* con solo una advertencia. `mkfs.vfat` esencialmente **no tiene tal seguro**: formatea lo que se le dé. Esta asimetría es exactamente por qué hacer `wipefs -a` primero es el hábito universal seguro, en lugar de confiar en la protección de cada herramienta.

**A7.4** (1) **Achicar.** ext4 puede achicarse fuera de línea con `resize2fs`; XFS no puede achicarse en absoluto, con ninguna herramienta, ni en línea ni fuera de línea. (2) **Espacio reservado fijo y ajustable, y una tabla de inodos preasignada** — ext4 te deja configurar `-m`, `-i`/`-N` y conocer tu techo de inodos por adelantado, mientras que XFS asigna inodos dinámicamente (lo que normalmente es una ventaja, pero significa que el consumo de inodos puede comerse espacio de datos de maneras que la planificación de capacidad tiene que contemplar). Una tercera respuesta válida: ext4 soporta crearse y montarse en un rango mucho más amplio de volúmenes diminutos, donde XFS impone un tamaño mínimo.

**A7.5** `xfs_admin` modifica el superbloque en disco directamente a través de la biblioteca de `xfs_db`, esquivando al kernel. Si el sistema de archivos está montado, el kernel tiene su propia copia cacheada del superbloque y la va a reescribir, así que un cambio fuera de banda sería silenciosamente revertido o corrompería el estado — de ahí la negativa tajante. `xfs_info` solo **lee** la geometría, y cuando se le da un punto de montaje le pregunta al *kernel* (vía `ioctl`) en lugar de al dispositivo crudo, así que estar montado no solo está permitido: es necesario para esa forma. (`xfs_admin -L` sobre un sistema de archivos montado es posible en versiones muy recientes de xfsprogs mediante el ioctl de etiquetado en línea, pero el comportamiento clásico y relevante para el examen es: desmontá primero.)

**A7.6** **No** son directamente comparables. Los ~40 MiB de XFS son mayormente el log interno, que se preasigna en el momento del `mkfs` y se contabiliza como usado; el journal de ext4 también está preasignado (32 MiB acá) pero `df` lo contabiliza de otra manera — ext4 excluye los bloques de journal y metadatos del tamaño total reportado en lugar de mostrarlos como usados, así que su "Size" ya viene neto de sobrecarga. Compará **`Avail` en un sistema de archivos vacío del mismo tamaño de partición**, no `Used`. En este laboratorio ambos quedan cerca de 960–975 MiB de espacio utilizable en una partición de 1 GiB, que es la comparación significativa.

---

### Ejercicio 8

**A8.1** Porque la especificación UEFI lo *exige*: el firmware tiene que poder leer la ESP antes de que cargue cualquier sistema operativo, y el único sistema de archivos que toda implementación UEFI está obligada a entender es FAT (FAT32, con FAT12/FAT16 también especificados). El firmware contiene un driver de FAT en ROM; no contiene ningún driver de ext4 ni de XFS. La ESP es por lo tanto FAT32 por especificación, no por convención.

**A8.2** FAT no tiene campo UUID. Lo que `blkid` reporta es el **número de serie del volumen**, un valor de 32 bits en el sector de arranque que `mkfs.fat` deriva de la hora actual (o de `-i`). Tiene 8 dígitos hexadecimales porque son 4 bytes. Consecuencias: `UUID=3C4A-91F7` en `/etc/fstab` funciona y sigue siendo mejor que `/dev/sdX`, pero el espacio de colisión es 2³² en lugar de 2¹²⁸ — y, de manera decisiva, un **clon bit a bit de un disco produce dos volúmenes con el número de serie idéntico**, así que `mount UUID=...` se vuelve ambiguo y puede elegir cualquiera de los dos. Después de clonar, volvé a sellarlo con `fatlabel -i` / `mkfs.fat -i`, exactamente como volverías a sellar un ext4 con `tune2fs -U random`.

**A8.3** `uid=`, `gid=`, `umask=`, y los más granulares `fmask=` (archivos) y `dmask=` (directorios); `mode=`/`dmode=` en algunos drivers. Se aplican **uniformemente a cada archivo y directorio del sistema de archivos** — FAT no almacena propietario ni modo por archivo, así que todo el volumen presenta una única propiedad sintética y una única máscara de permisos sintética derivadas de las opciones de montaje. Nada de lo que hagas con `chmod` o `chown` puede persistir, y por eso las llamadas al sistema fallan en lugar de no hacer nada silenciosamente. (La opción `showexec` es la pequeña excepción: hace que el bit de ejecución siga a la extensión `.exe`/`.com`/`.bat`.)

**A8.4** **4 GiB − 1 byte (4 294 967 295 bytes).** La entrada de directorio almacena el tamaño de un archivo en un único campo de 32 bits, así que no hay forma de representar un valor mayor. exFAT usa un campo de tamaño de 64 bits, llevando el límite práctico al rango de los exabytes, y también elimina el techo de 65 534 entradas por directorio de FAT32 y su límite de volumen de unos 2 TiB. Ese único límite de 4 GiB es por lo que exFAT existe en cámaras y medios extraíbles grandes, y por lo que un pendrive FAT32 rechaza un video de 5 GB incluso con 20 GB libres.

**A8.5** Sí, se montarían igual. Linux identifica un sistema de archivos **sondeando la firma de su superbloque/registro de arranque**, no por el byte de tipo del MBR, así que tanto `mount /dev/loop0p5 /mnt` como `mount -t exfat` funcionan sin importar el byte. Lo que se rompe es la interoperabilidad y la intención: Windows y muchos firmwares de cámaras/embebidos *sí* consultan el byte de tipo y pueden ignorar u ofrecer reformatear una partición cuyo tipo no coincide con su contenido; los instaladores y las GUIs de particionado lo van a mostrar mal; y una persona que lea `fdisk -l` se lleva una imagen falsa del disco. Configurá el byte de tipo correctamente — no cuesta nada y es documentación que viaja con el disco.

**A8.6** Porque FAT32 tiene una **cantidad mínima práctica de clústeres**: el tipo de FAT se define por la cantidad de clústeres (FAT32 requiere más de 65 524), así que forzar FAT32 en un volumen chico lleva el tamaño de clúster a 512 bytes y hace que las dos tablas FAT en sí consuman una fracción significativa del volumen. En volúmenes muy chicos `mkfs.fat` puede negarse de plano ("Attempting to create a too large filesystem" o un error de conteo de clústeres). Para un volumen de 32 MiB, FAT12 o FAT16 es la elección correcta — dejá que `mkfs.fat` elija, o indicá `-F 16`.

---

### Ejercicio 9

**A9.1** Porque `mkswap` y `swapon` son dos operaciones separadas, exactamente como `mkfs` y `mount`. `mkswap` **formatea**: escribe una cabecera de swap (firma `SWAPSPACE2`, versión, tamaño de página, cantidad de páginas utilizables, etiqueta y UUID) en la primera página del dispositivo o archivo. `swapon` **activa**: valida esa cabecera y le pide al kernel que empiece a usar el área para paginación. Nada en el paso de formateo registra el dispositivo ante el kernel, y esa separación es deliberada — podés preparar el swap en un disco mucho antes de que pienses usarlo.

**A9.2** La primera **página** (4096 bytes en x86-64) queda reservada para la cabecera de swap en sí y no está disponible para intercambio. 536 870 912 − 4096 = 536 866 816. Esto también significa que un área de swap formateada en una máquina con un tamaño de página puede ser rechazada en una máquina con otro distinto, ya que la cabecera registra el tamaño de página con el que se creó.

**A9.3** Asignales a los cuatro la **misma** prioridad (por ejemplo `pri=10` para cada uno). Cuando varias áreas de swap comparten la prioridad más alta, el kernel distribuye las páginas entre ellas por turnos (round-robin), así que obtenés aproximadamente cuatro veces el rendimiento de un solo dispositivo. Asignar 40/30/20/10 en cambio hace que el kernel llene por completo el dispositivo de prioridad 40 antes de tocar el de prioridad 30, y así sucesivamente — obtenés la capacidad de cuatro discos pero el **rendimiento de uno**, más un punto caliente patológico en el primer dispositivo.

**A9.4** Porque un área de swap legible por todo el mundo es una divulgación de información directa: todo lo que el kernel pagine hacia afuera — secretos descifrados, claves privadas, contraseñas en la memoria de un proceso, material de sesión TLS — termina en ese archivo en texto plano, y el modo 0644 le permite a **cualquier usuario local leerlo todo** con `strings`. La advertencia se dispara esté o no activado el archivo, porque la exposición empieza en el momento en que los datos se escriben ahí. `chmod 0600` (solo root) es el mínimo; swap cifrado o una partición de swap sobre un dispositivo cifrado es la respuesta más fuerte.

**A9.5**
- **Punto de montaje `none`** (o `swap`): un área de swap nunca se monta dentro del árbol de directorios, así que no hay ruta que indicar. El campo es obligatorio en el formato de seis columnas de `fstab`, así que se usa un marcador de posición.
- **Campo dump `0`**: la utilidad de respaldo legada `dump` no debe intentar respaldarlo. Es irrelevante para el swap (y, en la práctica, para casi todo hoy en día).
- **Campo pass `0`**: `fsck` no debe chequearlo en el arranque. No hay sistema de archivos que chequear, y un valor distinto de cero haría que `fsck` fallara sobre él.

**A9.6** El ID de tipo MBR **`82`** (`Linux swap / Solaris`) y el GUID de tipo GPT **`0657FD6D-A4AB-43C4-84E5-0933C84B4F4F`** (`8200` en la notación abreviada de `gdisk`). **Ninguno provoca la activación automática** en un sistema Linux moderno. La vieja autodetección por tipo del `swapon -a` del kernel no es cómo funciona esto: la activación viene de `/etc/fstab`, de una unidad `.swap` de systemd, o de un `swapon` explícito. La única excepción moderna es la implementación de systemd de la Discoverable Partition Specification, que *puede* activar una partición de swap en el disco raíz puramente a partir de su GUID de tipo GPT — vale la pena saberlo, pero por lo demás el byte de tipo por sí solo es informativo.

---

### Ejercicio 10

**A10.1** Porque Btrfs calcula la suma de verificación de cada bloque de metadatos y de datos, así que puede **detectar** corrupción de manera fiable — pero la detección sin una segunda copia solo le permite reportar un error irrecuperable. `DUP` escribe dos copias de todos los metadatos en ubicaciones distintas del mismo dispositivo, así que una falla localizada (un sector defectuoso, una escritura interrumpida, la corrupción de un solo bloque) puede repararse de forma transparente desde la otra copia, y perder metadatos es lo que convierte un sistema de archivos recuperable en uno que no se puede montar. **No** protege contra la falla de todo el dispositivo, la falla de la controladora, ni un bug de firmware que corrompa ambas copias — DUP no es RAID, y las dos copias mueren con el disco. Para protección contra fallas de dispositivo necesitás `-d raid1 -m raid1` entre dos o más dispositivos, o RAID por debajo.

**A10.2** `df` en Btrfs reporta una **estimación**, porque Btrfs no tiene un mapeo fijo y conocido de bytes libres a bytes de archivo utilizables. El espacio se entrega en *grupos de bloques* (chunks) tipificados como datos, metadatos o sistema, y los metadatos se almacenan como `DUP` — así que cada megabyte futuro de metadatos consume dos megabytes de espacio de dispositivo, y cuánto de los 893 MiB del área no asignada termina siendo datos frente a metadatos duplicados no se puede saber por adelantado. `btrfs filesystem usage` es autoritativo porque muestra la contabilidad real: tamaño del dispositivo, cuánto está *asignado* a grupos de bloques, cuánto de eso está realmente *usado*, y una estimación mínima del peor caso. Esta es también la razón por la que "Btrfs dice `ENOSPC` mientras `df` muestra espacio libre" es una condición bien conocida y legítima — los grupos de bloques de metadatos pueden agotarse mientras queda espacio de datos.

**A10.3** Varias respuestas válidas: un subvolumen es una **unidad de la que se pueden tomar snapshots de forma independiente** (`btrfs subvolume snapshot` es instantáneo y copy-on-write); puede **montarse por separado** con sus propias opciones de montaje vía `subvol=`; tiene su propio espacio de nombres de inodos y su propia raíz; puede enviarse y recibirse entre máquinas con `btrfs send`/`receive`; y puede tener su propio grupo de cuota. El uso canónico es el layout `@` / `@home`, que convierte "revertir el SO a antes de esa actualización, pero conservar home" en una única operación instantánea.

**A10.4** `mkfs.reiserfs` (de `reiserfsprogs`) y `mkfs.btrfs` (de `btrfs-progs`). ReiserFS v3 está **obsoleto (deprecated) en el kernel principal**: fue marcado como obsoleto en Linux 6.6 con una eliminación planificada, su módulo ya no se compila en muchas distribuciones, y no debería usarse para sistemas de archivos nuevos. Reiser4 nunca fue integrado al kernel principal en absoluto. Para el examen: reconocé los nombres, sabé que ReiserFS es anterior a ext4 y es legado, sabé que Btrfs es el sistema de archivos CoW en desarrollo activo, con snapshots, sumas de verificación, subvolúmenes y soporte multi-dispositivo.

**A10.5** **XFS** es la opción por defecto más segura para un volumen de base de datos. El comportamiento copy-on-write de Btrfs interactúa mal con el patrón de reescritura aleatoria en el lugar de los archivos de base de datos: cada escritura pequeña reubica un bloque, lo que fragmenta el archivo severamente, infla los metadatos y degrada el rendimiento con el tiempo — la mitigación estándar es `chattr +C` sobre el directorio antes de crear los archivos, lo que deshabilita CoW para ellos pero también deshabilita las sumas de verificación y la consistencia de snapshots justamente para los datos que más querías proteger. El CoW de XFS está confinado a reflinks explícitos y no se aplica a las reescrituras comunes, así que su comportamiento bajo una carga de base de datos es predecible; además es el sistema de archivos por defecto en RHEL y el que la mayoría de los proveedores de bases de datos certifican. (El mismo razonamiento aplica a las imágenes de máquinas virtuales y a los archivos de swap.)

---

### Ejercicio 11

**A11.1** `partprobe` y `blockdev --rereadpt` le piden al kernel que **descarte y vuelva a leer la tabla de particiones entera** del dispositivo. El kernel no puede descartar una partición que está en uso — montada, activa como swap, mantenida abierta por un proceso, o reclamada por LVM/mdadm — así que si una sola partición está ocupada, toda la operación es rechazada y nada cambia. `partx` trabaja **por partición**: `partx -a -n 7` le dice al kernel que agregue solo el dispositivo de bloque de la partición 7, dejando las particiones 1–6 y sus montajes completamente intactos. Como las particiones ocupadas nunca están involucradas, no hay nada que rechazar. Esta es la forma estándar de agregar una partición a un servidor de producción en vivo sin reiniciar.

**A11.2** 0x438 = **1080** en decimal. El superbloque de ext2/3/4 vive en el desplazamiento de byte **1024** desde el inicio del sistema de archivos, y el número mágico de 16 bits `0xEF53` está en el desplazamiento 56 dentro de él — 1024 + 56 = 1080. Los primeros 1024 bytes se dejan libres deliberadamente para un sector de arranque o un remanente de tabla de particiones, que es precisamente por lo que `mkfs.ext4` no sobrescribió el registro de arranque de exFAT ubicado en el desplazamiento 0.

**A11.3** El arreglo es `wipefs -a /dev/loop0p5` (y después volver a ejecutar `mkfs`). El hábito correcto es ejecutar **`wipefs -a` antes de cada `mkfs` sobre medios reutilizados**, y confirmar con un `wipefs <device>` pelado (que solo lista) que no queda nada. Distintos sistemas de archivos guardan sus firmas en desplazamientos distintos, así que ningún `mkfs` borra de manera fiable toda la historia de un dispositivo; `wipefs` conoce todos los desplazamientos e imprime exactamente lo que eliminó.

**A11.4** Es un problema de **espacio de usuario**: `mkfs` es solo un despachador que ejecuta (`exec`) `mkfs.<type>` desde `$PATH`, así que "not found" significa que falta el paquete `xfsprogs`. Los dos se verifican de forma independiente: para el **espacio de usuario**, `ls /sbin/mkfs.*` o `command -v mkfs.xfs`; para el soporte del **kernel**, `grep xfs /proc/filesystems` (ya cargado o compilado dentro) y `modprobe xfs && lsmod | grep xfs` (módulo cargable). Podés toparte con cualquiera de las dos fallas por separado — una imagen de contenedor comúnmente tiene el soporte del kernel (comparte el kernel del anfitrión) pero no las herramientas, y un kernel personalizado recortado puede tener las herramientas pero no el driver.

**A11.5** Cuando la partición que necesitás **cambiar o eliminar** está ella misma en uso y no puede liberarse — sobre todo, cuando es el **sistema de archivos raíz** o contiene swap activo que no se puede desactivar. `partx -d`/`partprobe` no pueden revocar una partición que el kernel está usando activamente, y `partx -a` no ayuda porque la partición ya existe. Agrandar la partición raíz en el lugar es el caso clásico: el cambio de tabla se escribe, pero la visión del kernel de `/dev/sda2` solo se actualiza en el próximo arranque — que es por lo que `growpart` + `resize2fs` en imágenes de nube normalmente se combina con un reinicio, o se maneja con LVM para que el límite del dispositivo de bloque nunca tenga que moverse.

</details>

---

## Fuentes

- LPI — Objetivos del Examen 101-500, tema 104.1: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- `fdisk(8)`, `sfdisk(8)`, `partx(8)`, `losetup(8)`, `blkid(8)`, `lsblk(8)`, `wipefs(8)`, `mkswap(8)`, `swapon(8)`, `swaplabel(8)`, `blockdev(8)` — util-linux: <https://www.kernel.org/pub/linux/utils/util-linux/> y <https://man7.org/linux/man-pages/>
- Documentación de GPT fdisk (`gdisk`, `sgdisk`, `cgdisk`): <https://www.rodsbooks.com/gdisk/>
- Manual de GNU Parted: <https://www.gnu.org/software/parted/manual/parted.html>
- `mke2fs(8)`, `mke2fs.conf(5)`, `tune2fs(8)`, `dumpe2fs(8)` — e2fsprogs: <https://e2fsprogs.sourceforge.net/>
- Sistema de archivos ext4, documentación del kernel Linux: <https://docs.kernel.org/admin-guide/ext4.html>
- Layout en disco de ext4: <https://docs.kernel.org/filesystems/ext4/>
- Documentación de XFS y `xfsprogs`: <https://xfs.wiki.kernel.org/> y <https://docs.kernel.org/admin-guide/xfs.html>
- dosfstools (`mkfs.fat`, `fatlabel`, `fsck.fat`): <https://github.com/dosfstools/dosfstools>
- exfatprogs (`mkfs.exfat`): <https://github.com/exfatprogs/exfatprogs>
- Documentación de Btrfs: <https://btrfs.readthedocs.io/>
- Obsolescencia de ReiserFS, documentación del kernel Linux: <https://docs.kernel.org/filesystems/index.html>
- Especificación UEFI (EFI System Partition, requisito de FAT): <https://uefi.org/specifications>
- Discoverable Partitions Specification (GUIDs de tipo de GPT): <https://uapi-group.org/specifications/specs/discoverable_partitions_specification/>