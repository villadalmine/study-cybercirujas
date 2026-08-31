# LPIC-1 · Tema 102.1 — Diseñar la distribución del disco duro
## Ejercicios guiados (Examen 101-500, versión 5.0 · Peso: 3.13)

> **Alcance de este laboratorio.** Vas a inventariar la distribución de un sistema en funcionamiento y luego diseñar y construir tres distribuciones completas — UEFI/GPT, BIOS/GPT y una respaldada por LVM — sobre un **dispositivo loop respaldado por archivo**, de modo que nunca se toque nada de tus discos reales. Cada comando destructivo de este documento apunta únicamente a `/dev/loopN`. Leé cada línea de `wipefs`, `sgdisk`, `mkfs` y `dd` antes de presionar Enter y confirmá el nombre del dispositivo destino en el mismo acto.

**Requisitos previos**

- Un sistema Linux con acceso `root` (o `sudo`).
- Paquetes: `util-linux` (`lsblk`, `losetup`, `blkid`, `findmnt`, `wipefs`, `mkswap`, `swapon`), `gdisk`/`sgdisk`, `parted`, `dosfstools` (`mkfs.vfat`), `e2fsprogs`, `lvm2`.
- Al menos **2 GiB** de espacio genuinamente libre en el sistema de archivos que contiene `/var/tmp` (la imagen es dispersa, pero LVM y los metadatos del sistema de archivos la harán crecer).

**Fuentes de referencia usadas a lo largo del documento**

- Objetivos del Examen 101 de LPI — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- `fstab(5)` — <https://man7.org/linux/man-pages/man5/fstab.5.html>
- `mkswap(8)` / `swapon(8)` — <https://man7.org/linux/man-pages/man8/mkswap.8.html>
- Manual de GNU GRUB (partición BIOS boot, soporte de LVM/LUKS) — <https://www.gnu.org/software/grub/manual/grub/grub.html>
- Especificación UEFI (EFI System Partition) — <https://uefi.org/specifications>
- Discoverable Partitions Specification (GUIDs de tipo de partición) — <https://uapi-group.org/specifications/specs/discoverable_partitions_specification/>
- Red Hat Enterprise Linux 9 — *Managing storage devices*, recomendaciones de swap — <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_storage_devices/index>
- Guía de instalación de Debian — *Recommended partitioning scheme* — <https://www.debian.org/releases/stable/amd64/apcs03.en.html>
- `lvm(8)` y el proyecto LVM2 — <https://man7.org/linux/man-pages/man8/lvm.8.html>, <https://sourceware.org/lvm2/>

---

## Ejercicio 1 — Leer la distribución que ya tenés

Un diseño empieza midiendo lo que existe. Antes de proponer tamaños, tenés que ser capaz de decir, para el sistema que tenés delante, qué es un disco, qué es una partición, qué es un volumen lógico y dónde está montado cada uno.

1. Imprimí el árbol de dispositivos de bloque con los atributos que importan para el diseño:

   ```bash
   lsblk -o NAME,TYPE,SIZE,FSTYPE,FSUSE%,MOUNTPOINTS
   ```

   Salida representativa (la tuya será distinta):

   ```
   NAME          TYPE  SIZE FSTYPE      FSUSE% MOUNTPOINTS
   nvme0n1       disk  476G
   ├─nvme0n1p1   part  600M vfat            4% /boot/efi
   ├─nvme0n1p2   part    1G ext4           38% /boot
   └─nvme0n1p3   part  474G LVM2_member
     ├─vg0-root  lvm    30G ext4           61% /
     ├─vg0-var   lvm    40G ext4           22% /var
     ├─vg0-home  lvm   200G ext4           47% /home
     └─vg0-swap  lvm    16G swap             [SWAP]
   ```

2. Distinguí los sistemas de archivos reales de los del kernel/virtuales, que nunca reciben una partición:

   ```bash
   findmnt --real --output TARGET,SOURCE,FSTYPE,OPTIONS
   ```

3. Mirá la misma imagen desde el lado del sistema de archivos, incluida la presión de inodos:

   ```bash
   df -hT -x tmpfs -x devtmpfs
   df -i  -x tmpfs -x devtmpfs
   ```

4. Leé la tabla de particiones en sí, no el resultado montado. Reemplazá `/dev/nvme0n1` por tu propio disco (esto es de solo lectura — `-l` solamente lista):

   ```bash
   sudo fdisk -l /dev/nvme0n1
   sudo gdisk -l /dev/nvme0n1     # shows GPT type codes and partition GUIDs
   sudo parted /dev/nvme0n1 unit MiB print
   ```

5. Recolectá los identificadores que realmente pondrías en `/etc/fstab`:

   ```bash
   sudo blkid
   lsblk -o NAME,UUID,PARTUUID,PARTLABEL,LABEL
   ```

6. Inspeccioná el swap y la memoria:

   ```bash
   swapon --show
   free -h
   cat /proc/swaps
   ```

7. Determiná si la máquina arrancó a través de UEFI o de BIOS heredada. Este único dato decide todo el extremo de arranque de tu diseño:

   ```bash
   [ -d /sys/firmware/efi ] && echo "UEFI boot" || echo "BIOS/CSM boot"
   sudo efibootmgr -v 2>/dev/null | head
   ```

8. Medí dónde se va realmente el espacio, para que tus tamaños de `/var` y `/home` estén basados en evidencia y no en folclore. `-x` mantiene a `du` dentro de un solo sistema de archivos:

   ```bash
   sudo du -x -h -d1 /var  | sort -h | tail -n 10
   sudo du -x -h -d1 /home | sort -h | tail -n 10
   sudo journalctl --disk-usage
   ```

**Comprobá tu comprensión**

- **Q1.** En la salida de `lsblk` de arriba, ¿qué línea es una *partición*, cuál es un *volumen lógico* y cuál es el *volumen físico* que contiene los datos de LVM? ¿Cómo te lo dice la columna `TYPE`?
- **Q2.** `df -hT` reporta 40% usado en `/home`, pero las escrituras fallan con `No space left on device`. `df -i` muestra `IUse% 100`. Explicá la falla y decí qué decisión de diseño (tomada en el momento del particionado) la causó.
- **Q3.** ¿Por qué `findmnt --real` omite `/proc`, `/sys`, `/run` y `/dev/shm`, y por qué eso importa cuando estás dimensionando particiones?
- **Q4.** Ejecutaste `du -h -d1 /var` **sin** `-x` y el número fue mucho mayor que lo que reporta `df` para el sistema de archivos `/var`. ¿Qué pasó?
- **Q5.** ¿Qué comando de este bloque te dice si la máquina necesita una EFI System Partition, y por qué no podés responder esa pregunta solo con `lsblk`?

---

## Ejercicio 2 — Construir un disco descartable

Necesitás un dispositivo de bloque que tengas permitido destruir. Un archivo disperso asociado a un dispositivo loop se comporta como un disco real a los fines del particionado, los sistemas de archivos, LVM y `fstab`.

1. Creá una imagen dispersa de 8 GiB fuera de `tmpfs` (`/tmp` es RAM en la mayoría de las distribuciones modernas — verificá antes de usarlo):

   ```bash
   findmnt -no FSTYPE /var/tmp        # must NOT be tmpfs
   df -h /var/tmp
   sudo truncate -s 8G /var/tmp/lab-disk.img
   ls -lh /var/tmp/lab-disk.img       # apparent size 8.0G
   du -h  /var/tmp/lab-disk.img       # actual size 0 — it is sparse
   ```

2. Asociala a un dispositivo loop con el escaneo de particiones habilitado:

   ```bash
   LOOP=$(sudo losetup --find --show --partscan /var/tmp/lab-disk.img)
   echo "$LOOP"        # e.g. /dev/loop0
   ```

3. Confirmá que el kernel ve un dispositivo de bloque con una geometría razonable:

   ```bash
   lsblk "$LOOP"
   sudo blockdev --getsize64 "$LOOP"   # 8589934592
   cat /sys/block/$(basename "$LOOP")/queue/logical_block_size    # 512
   cat /sys/block/$(basename "$LOOP")/queue/physical_block_size   # 512
   ```

4. Conservá la variable para el resto del laboratorio. Si abrís una shell nueva, volvé a derivarla en lugar de adivinar:

   ```bash
   LOOP=$(losetup -j /var/tmp/lab-disk.img | cut -d: -f1)
   echo "$LOOP"
   ```

**Comprobá tu comprensión**

- **Q6.** ¿Qué hace `--partscan`, y qué síntoma verías sin él después de crear particiones en la imagen?
- **Q7.** `ls -lh` dice 8.0G y `du -h` dice 0. Explicalo, y enunciá el riesgo de ejecutar un sistema de archivos de producción sobre un archivo de respaldo disperso.
- **Q8.** ¿Por qué `/tmp` es un mal lugar para esta imagen en una distribución con systemd?

---

## Ejercicio 3 — Una distribución UEFI/GPT: ESP, `/boot` y un volumen físico LVM

Este es el estándar moderno. La frase del objetivo *"ensure the /boot partition conforms to the hardware architecture requirements for booting"* significa, en UEFI x86-64: una tabla GPT, una EFI System Partition en FAT32 que el firmware pueda leer, y una ubicación del kernel/initramfs que el gestor de arranque pueda leer.

1. Borrá cualquier firma obsoleta y luego escribí una GPT nueva con tres particiones:

   ```bash
   sudo wipefs -a "$LOOP"
   sudo sgdisk --zap-all "$LOOP"

   sudo sgdisk \
     -n 1:1MiB:+512MiB -t 1:ef00 -c 1:"EFI System Partition" \
     -n 2:0:+1GiB      -t 2:8300 -c 2:"boot" \
     -n 3:0:0          -t 3:8e00 -c 3:"lvm-pv" \
     "$LOOP"
   sudo partprobe "$LOOP"
   ```

2. Verificá los códigos de tipo y la alineación. Cada inicio debe caer en un límite de 1 MiB (sector 2048 con sectores de 512 bytes):

   ```bash
   sudo sgdisk -p "$LOOP"
   sudo parted "$LOOP" unit s print
   sudo parted "$LOOP" align-check optimal 1
   sudo parted "$LOOP" align-check optimal 3
   ```

   Salida representativa de `sgdisk -p`:

   ```
   Number  Start (sector)    End (sector)  Size       Code  Name
      1            2048         1050623   512.0 MiB   EF00  EFI System Partition
      2         1050624         3147775   1024.0 MiB  8300  boot
      3         3147776        16775134   6.5 GiB     8E00  lvm-pv
   ```

3. Leé los GUIDs de tipo reales que hay detrás de esos códigos abreviados:

   ```bash
   sudo sgdisk -i 1 "$LOOP"    # C12A7328-F81F-11D2-BA4B-00A0C93EC93B  (ESP)
   sudo sgdisk -i 3 "$LOOP"    # E6D6D379-F507-44C2-A23C-238F2A3DF928  (Linux LVM)
   ```

4. Creá los sistemas de archivos del lado del arranque. La ESP **debe** ser FAT — el firmware UEFI implementa FAT y nada más, por especificación:

   ```bash
   sudo mkfs.vfat -F 32 -n EFI  "${LOOP}p1"
   sudo mkfs.ext4 -L boot       "${LOOP}p2"
   sudo blkid "${LOOP}p1" "${LOOP}p2"
   ```

5. Registrá los identificadores que vas a necesitar más adelante:

   ```bash
   ESP_UUID=$(sudo blkid -s UUID -o value "${LOOP}p1")
   BOOT_UUID=$(sudo blkid -s UUID -o value "${LOOP}p2")
   echo "ESP=$ESP_UUID BOOT=$BOOT_UUID"
   ```

   Notá que el UUID de la ESP tiene la forma corta `XXXX-XXXX`: FAT no tiene un UUID real, solo un número de serie de volumen de 32 bits.

**Comprobá tu comprensión**

- **Q9.** ¿Por qué la ESP no puede ser `ext4`, y por qué no puede ser un volumen lógico LVM?
- **Q10.** ¿Qué significa exactamente el código de tipo `ef00` para (a) `sgdisk`, (b) el firmware UEFI y (c) el kernel de Linux? ¿Cuál de los tres lo hace cumplir realmente?
- **Q11.** En el paso 1, la partición 3 es `8e00` (Linux LVM) en lugar de `8300` (Linux filesystem). ¿El kernel se niega a construir un PV si te equivocás en esto? Entonces, ¿para qué sirve el código de tipo?
- **Q12.** La ESP es de 512 MiB y `/boot` es de 1 GiB. Justificá ambos números en términos de lo que se guarda en cada uno, y nombrá un comportamiento de distribución que hace que un `/boot` de 200 MiB falle meses después de la instalación.
- **Q13.** Explicá qué verifica `parted align-check optimal 1` y por qué un sector de inicio desalineado degrada el rendimiento en SSDs y en discos 4Kn / 512e.

---

## Ejercicio 4 — El caso BIOS/GPT: la partición BIOS boot

Si el firmware es BIOS heredada pero la tabla es GPT, GRUB no tiene dónde poner `core.img`: no hay un hueco post-MBR con el que pueda contar, porque el encabezado primario de GPT y el arreglo de entradas lo ocupan. La respuesta es una partición `ef02` pequeña y **sin formato**. Esta es la trampa clásica del examen.

Hacé esto en una segunda imagen descartable, para que la distribución del Ejercicio 3 sobreviva.

1. Creá y asociá una segunda imagen:

   ```bash
   sudo truncate -s 2G /var/tmp/lab-bios.img
   LOOPB=$(sudo losetup --find --show --partscan /var/tmp/lab-bios.img)
   echo "$LOOPB"
   ```

2. Construí una distribución GPT arrancable por BIOS:

   ```bash
   sudo sgdisk --zap-all "$LOOPB"
   sudo sgdisk \
     -n 1:1MiB:+2MiB -t 1:ef02 -c 1:"BIOS boot" \
     -n 2:0:+512MiB  -t 2:8300 -c 2:"boot" \
     -n 3:0:0        -t 3:8300 -c 3:"root" \
     "$LOOPB"
   sudo partprobe "$LOOPB"
   sudo sgdisk -p "$LOOPB"
   sudo sgdisk -i 1 "$LOOPB"     # 21686148-6449-6E6F-744E-656564454649
   ```

3. Demostrá que la partición 1 no lleva ningún sistema de archivos, y que no debe llevarlo:

   ```bash
   sudo blkid "${LOOPB}p1"       # no output, exit status 2
   sudo wipefs "${LOOPB}p1"      # no signatures
   ```

4. Como contraste, construí la misma idea sobre una tabla **MBR (msdos)**, donde los IDs de tipo son de un byte, no un GUID:

   ```bash
   sudo sgdisk --zap-all "$LOOPB"
   sudo parted -s "$LOOPB" mklabel msdos \
     mkpart primary ext4 1MiB 513MiB \
     mkpart primary ext4 513MiB 1537MiB \
     mkpart primary linux-swap 1537MiB 100%
   sudo parted -s "$LOOPB" set 1 boot on
   sudo fdisk -l "$LOOPB"
   ```

   Después cambiá el tipo de la tercera partición a swap (`82`) de forma no interactiva:

   ```bash
   echo -e 't\n3\n82\nw\n' | sudo fdisk "$LOOPB"
   sudo fdisk -l "$LOOPB" | tail -n 5
   ```

5. Notá los límites de MBR dentro de los que acabás de vivir:

   ```bash
   sudo parted "$LOOPB" print | head -n 8
   ```

   Cuatro entradas primarias; una quinta partición requiere convertir una en *extendida* y anidar particiones *lógicas* dentro de ella, que el kernel numera desde 5 en adelante sin importar cuántas primarias existan.

**Comprobá tu comprensión**

- **Q14.** ¿Por qué GRUB necesita la partición `ef02` en BIOS+GPT pero no en BIOS+MBR? ¿Dónde vive `core.img` en cada caso?
- **Q15.** ¿Qué es lo *peor* que le podés hacer a una partición `ef02`, y qué síntoma produce?
- **Q16.** En MBR creás las particiones 1, 2 y 3 como primarias y después necesitás dos sistemas de archivos más. Describí con precisión qué tenés que hacer y qué nombres de dispositivo recibirán los nuevos sistemas de archivos.
- **Q17.** Dá el tamaño máximo de disco direccionable de una tabla MBR con sectores de 512 bytes, y mostrá la aritmética.
- **Q18.** Una máquina arranca en modo UEFI desde un disco que también tiene una partición `ef02`. ¿Se usa la partición `ef02`? ¿Es perjudicial? Justificá.

---

## Ejercicio 5 — LVM: separar la *distribución* del *particionado*

El objetivo requiere "knowledge of basic features of LVM". El punto de LVM en una discusión de *diseño* es que pospone la decisión de dimensionamiento: las particiones quedan fijadas en el momento de la instalación, los volúmenes lógicos no.

Trabajá sobre la imagen UEFI del Ejercicio 3 (`$LOOP`), partición 3.

1. Creá el volumen físico e inspeccioná sus metadatos:

   ```bash
   sudo pvcreate "${LOOP}p3"
   sudo pvs
   sudo pvdisplay "${LOOP}p3"
   ```

   > **Si `pvs` no lo lista:** las distribuciones que usan el archivo de dispositivos de LVM (RHEL 9+, Fedora reciente) restringen qué dispositivos tocará LVM. Verificá con `sudo lvmdevices` y, si hace falta, `sudo lvmdevices --adddev "${LOOP}p3"`.

2. Creá el grupo de volúmenes y leé su tamaño de extensión:

   ```bash
   sudo vgcreate vg_lab "${LOOP}p3"
   sudo vgs -o vg_name,pv_count,vg_size,vg_free,vg_extent_size
   sudo vgdisplay vg_lab | grep -E 'PE Size|Total PE|Free  PE'
   ```

   El tamaño de Physical Extent (PE) por defecto es 4 MiB; todo tamaño de LV se redondea **hacia arriba** a un número entero de extensiones.

3. Repartí los volúmenes lógicos, dejando deliberadamente espacio libre en el VG:

   ```bash
   sudo lvcreate -L 2G  -n lv_root vg_lab
   sudo lvcreate -L 1G  -n lv_var  vg_lab
   sudo lvcreate -L 1G  -n lv_home vg_lab
   sudo lvcreate -L 512M -n lv_swap vg_lab
   sudo lvs -o lv_name,lv_size,vg_name,lv_path
   sudo vgs -o vg_name,vg_size,vg_free
   ```

4. Poneles sistemas de archivos y swap:

   ```bash
   sudo mkfs.ext4 -L root /dev/vg_lab/lv_root
   sudo mkfs.ext4 -L var  /dev/vg_lab/lv_var
   sudo mkfs.ext4 -L home /dev/vg_lab/lv_home
   sudo mkswap   -L swap /dev/vg_lab/lv_swap
   lsblk "$LOOP"
   ```

5. Realizá la operación que justifica la existencia de LVM — agrandar un sistema de archivos *montado*:

   ```bash
   sudo mkdir -p /mnt/lab && sudo mount /dev/vg_lab/lv_var /mnt/lab
   df -hT /mnt/lab

   sudo lvextend -L +512M -r /dev/vg_lab/lv_var
   df -hT /mnt/lab          # grew, still mounted, no reboot
   ```

   `-r` (`--resizefs`) llama a `resize2fs` por vos. Sin él tenés que ejecutar `sudo resize2fs /dev/vg_lab/lv_var` como segundo paso.

6. Tomá una instantánea, observá que consume espacio del VG, y después descartala:

   ```bash
   sudo lvcreate -s -L 256M -n snap_var /dev/vg_lab/lv_var
   sudo lvs -o lv_name,lv_attr,lv_size,origin,data_percent vg_lab
   sudo vgs -o vg_name,vg_free
   sudo lvremove -y /dev/vg_lab/snap_var
   ```

7. Desmontá antes de continuar:

   ```bash
   sudo umount /mnt/lab
   ```

**Comprobá tu comprensión**

- **Q19.** Nombrá las tres capas de LVM en orden y dá el comando que crea cada una.
- **Q20.** Pedís `lvcreate -L 1000M`. `lvs` reporta `1000.00m`, pero en otro VG el mismo pedido reporta un número distinto. Explicá el mecanismo y la propiedad que lo controla.
- **Q21.** ¿Por qué el ejercicio dejó deliberadamente espacio libre en `vg_lab` en lugar de usar `-l 100%FREE`? Dá dos operaciones distintas que ese espacio libre hace posibles.
- **Q22.** Extendiste `lv_var` y `df` sigue mostrando el tamaño anterior. ¿Qué olvidaste, y cuál es el comando equivalente para XFS?
- **Q23.** ¿Puede `/boot` vivir en un volumen lógico? Respondé específicamente para GRUB2, y explicá por qué los instaladores igualmente mantienen `/boot` en una partición común.
- **Q24.** Se crea una instantánea de un volumen de 100 GiB con `-L 1G`. El origen recibe después 3 GiB de escrituras. ¿Qué le pasa a la instantánea, y qué muestra `lv_attr`?

---

## Ejercicio 6 — Swap: tamaño, ubicación, prioridad

1. Calculá lo que recomendaría la guía clásica para **esta** máquina. Determiná primero la RAM:

   ```bash
   free -h
   awk '/MemTotal/ {printf "%.1f GiB\n", $2/1024/1024}' /proc/meminfo
   ```

   La recomendación de Red Hat (RHEL 9, *Managing storage devices*) es:

   | RAM | Swap (sin hibernación) | Swap (con hibernación) |
   |---|---|---|
   | ≤ 2 GiB | 2 × RAM | 3 × RAM |
   | > 2 – 8 GiB | = RAM | 2 × RAM |
   | > 8 – 64 GiB | ≥ 4 GiB | 1.5 × RAM |
   | > 64 GiB | ≥ 4 GiB | no recomendado |

2. Activá el **volumen lógico** de swap del Ejercicio 5, brevemente, y observá la prioridad:

   ```bash
   sudo swapon --priority 10 /dev/vg_lab/lv_swap
   swapon --show
   cat /proc/swaps
   ```

   Salida representativa:

   ```
   NAME                 TYPE      SIZE USED PRIO
   /dev/dm-3            partition 512M   0B   10
   ```

   > **Precaución solo para el laboratorio.** Esta área de swap está respaldada en última instancia por un archivo en otro sistema de archivos, a través de un dispositivo loop. Hacer swap hacia un dispositivo loop en el mismo host puede provocar un interbloqueo bajo presión real de memoria. Verificalo, y después apagalo. Nunca hagas esto en una máquina de producción.

   ```bash
   sudo swapoff /dev/vg_lab/lv_swap
   ```

3. Construí un **archivo** de swap y compará. Notá los permisos obligatorios:

   ```bash
   sudo fallocate -l 256M /var/tmp/swapfile
   sudo chmod 600 /var/tmp/swapfile
   sudo mkswap /var/tmp/swapfile
   sudo swapon --priority 5 /var/tmp/swapfile
   swapon --show
   ```

   En **Btrfs**, `fallocate` por sí solo no alcanza — el archivo debe crearse con `btrfs filesystem mkswapfile`, o tener `chattr +C` (nodatacow) y estar sin comprimir, o `swapon` falla con `Invalid argument`.

4. Leé el encabezado que un área de swap realmente lleva:

   ```bash
   sudo blkid /var/tmp/swapfile
   sudo file /var/tmp/swapfile
   ```

5. Desactivá y eliminá:

   ```bash
   sudo swapoff /var/tmp/swapfile
   sudo rm -f /var/tmp/swapfile
   swapon --show
   ```

6. Inspeccioná la perilla del kernel que decide *con cuánta avidez* se envían a swap las páginas anónimas — un parámetro de ajuste, no de dimensionamiento:

   ```bash
   cat /proc/sys/vm/swappiness
   ```

**Comprobá tu comprensión**

- **Q25.** Un servidor tiene 128 GiB de RAM y corre una carga de trabajo JVM con la hibernación deshabilitada. ¿Necesita 128 GiB de swap? Enunciá un tamaño defendible y justificalo.
- **Q26.** ¿Por qué un archivo de swap debe tener modo `0600`, y qué se niega a hacer `mkswap` si no lo tiene?
- **Q27.** Existen dos áreas de swap, una en NVMe con `pri=10` y otra en un HDD SATA con `pri=1`. Describí el comportamiento de asignación del kernel. ¿Qué cambia si ambas tienen `pri=10`?
- **Q28.** Una laptop debe hibernar. Enunciá los dos requisitos independientes que el área de swap debe satisfacer, más allá de la mera existencia.
- **Q29.** Poner `vm.swappiness=0` — ¿deshabilita el swapping? ¿Cuál es el efecto práctico bajo presión de memoria?
- **Q30.** Dá una ventaja de diseño de una partición de swap sobre un archivo de swap, y una de un archivo de swap sobre una partición de swap.

---

## Ejercicio 7 — Adaptar el diseño al uso previsto

Este es el segundo punto del objetivo y la parte que una pregunta de examen es más probable que esconda dentro de un escenario. Los sistemas de archivos separados te compran cuatro cosas: **aislamiento del llenado**, **opciones de montaje distintas**, **granularidad independiente de instantánea/respaldo** y **alcance separado de `fsck`/redimensionado**. Te cuestan **espacio libre varado**.

1. Razoná sobre un caso concreto. Un relay de correo escribe en `/var/spool` y `/var/log`; una oleada implacable de spam llena el disco. Simulá el modo de falla con un sistema de archivos sin cuotas — llená el pequeño `lv_var` y observá:

   ```bash
   sudo mount /dev/vg_lab/lv_var /mnt/lab
   sudo dd if=/dev/zero of=/mnt/lab/fill bs=1M count=2000 status=none || true
   df -hT /mnt/lab
   sudo touch /mnt/lab/another          # No space left on device
   ```

   Ahora demostrá el aislamiento: el sistema de archivos raíz de tu máquina real está intacto.

   ```bash
   df -hT /
   sudo rm -f /mnt/lab/fill && sudo umount /mnt/lab
   ```

2. Escribí una distribución para cada uno de los siguientes roles, usando el VG de LVM que construiste. Para cada uno, indicá tamaño, sistema de archivos y opciones de montaje. Usá esto como plantilla:

   | Punto de montaje | Tamaño | FS | Opciones | Razón |
   |---|---|---|---|---|
   | `/boot/efi` | 512 MiB | vfat | `umask=0077,shortname=winnt` | legible por el firmware |
   | `/boot` | 1 GiB | ext4 | `defaults` | kernels + initramfs |
   | `/` | 20 GiB | ext4 | `defaults` | SO + paquetes |
   | `/var` | ? | ext4 | `nosuid,nodev` | logs, spool, imágenes de contenedor |
   | `/home` | ? | ext4 | `nosuid,nodev` | datos de usuario, destino de cuotas |
   | `/tmp` | ? | ext4/tmpfs | `nosuid,nodev,noexec` | borrador no confiable |
   | `/srv` | ? | xfs | `nosuid,nodev` | datos servidos |
   | swap | ? | swap | `sw` | ver Ejercicio 6 |

   Roles a diseñar:

   - **(a)** Servidor web, 16 GiB de RAM, 500 GiB de disco, sirve contenido estático desde `/srv/www`, sin hibernación.
   - **(b)** Host multiusuario de shell/compilación, 200 usuarios, 64 GiB de RAM, 4 TiB de disco.
   - **(c)** Host de contenedores corriendo `containerd` (almacén de imágenes bajo `/var/lib/containerd`), 32 GiB de RAM.
   - **(d)** Appliance/VM mínima, 2 GiB de RAM, 20 GiB de disco, desatendida, gestionada remotamente.

3. Verificá qué opciones de montaje aplica ya tu sistema actual, y mirá cómo se ve un `/tmp` endurecido:

   ```bash
   findmnt --real -o TARGET,FSTYPE,OPTIONS
   findmnt /tmp
   ```

4. Probá que `noexec` hace lo que el diseño afirma. Montá `lv_home` con opciones endurecidas:

   ```bash
   sudo mount -o nosuid,nodev,noexec /dev/vg_lab/lv_home /mnt/lab
   printf '#!/bin/sh\necho ran\n' | sudo tee /mnt/lab/t.sh >/dev/null
   sudo chmod +x /mnt/lab/t.sh
   /mnt/lab/t.sh                 # Permission denied
   sh /mnt/lab/t.sh              # ran   <-- the interpreter bypasses noexec
   sudo umount /mnt/lab
   ```

**Comprobá tu comprensión**

- **Q31.** Enunciá el argumento individual más fuerte a favor de un `/var` separado, y el argumento individual más fuerte en contra de dividir una VM pequeña en seis sistemas de archivos.
- **Q32.** Para el rol (b), ¿qué sistema de archivos recibe la mayor parte del espacio y qué mecanismo — no visible en la tabla de particiones — debe habilitarse para evitar que un solo usuario lo consuma todo?
- **Q33.** La demostración de `noexec` de arriba fue burlada por `sh /mnt/lab/t.sh`. ¿Eso hace que `noexec` no sirva para nada? ¿Qué clase de ataque sigue bloqueando?
- **Q34.** `/tmp` como `tmpfs` versus `/tmp` como volumen lógico: dá un escenario donde cada uno es la elección equivocada.
- **Q35.** Para el rol (c), ¿dónde consumen espacio realmente las imágenes de contenedor, y qué cambiarías de la distribución por defecto para evitar que la descarga de una imagen tumbe el registro de `journald` y `sshd`?
- **Q36.** Explicá el "espacio libre varado" con un ejemplo numérico sobre un disco de 500 GiB, y decí cómo LVM reduce (pero no elimina) el problema.

---

## Ejercicio 8 — Expresar el diseño como `/etc/fstab`

Una distribución que no está escrita correctamente en `/etc/fstab` no sobrevive a un reinicio — y un `fstab` equivocado es una de las pocas formas de dejar un sistema sin poder arrancar, en el prompt de emergencia.

1. Recolectá cada identificador de la distribución LVM:

   ```bash
   sudo blkid "${LOOP}p1" "${LOOP}p2" /dev/vg_lab/lv_root /dev/vg_lab/lv_var \
              /dev/vg_lab/lv_home /dev/vg_lab/lv_swap
   ```

2. Escribí el diseño en un **archivo de borrador**, no en el `/etc/fstab` real:

   ```bash
   sudo tee /var/tmp/fstab.lab >/dev/null <<EOF
   # <device>                        <mount point>  <type>  <options>                 <dump> <pass>
   /dev/mapper/vg_lab-lv_root        /              ext4    defaults                  0      1
   UUID=$(sudo blkid -s UUID -o value "${LOOP}p2")  /boot          ext4    defaults                  0      2
   UUID=$(sudo blkid -s UUID -o value "${LOOP}p1")  /boot/efi      vfat    umask=0077,shortname=winnt 0     2
   /dev/mapper/vg_lab-lv_var         /var           ext4    defaults,nosuid,nodev     0      2
   /dev/mapper/vg_lab-lv_home        /home          ext4    defaults,nosuid,nodev     0      2
   /dev/mapper/vg_lab-lv_swap        none           swap    sw                        0      0
   EOF
   cat /var/tmp/fstab.lab
   ```

3. Estudiá los seis campos, en orden: dispositivo, punto de montaje, tipo, opciones, `dump`, `pass`. Notá que `pass` es `1` para la raíz, `2` para los demás sistemas de archivos reales, y `0` para el swap y para todo lo que no deba ser verificado.

4. Validá la sintaxis y montá una sola entrada del archivo de borrador sin tocar el real:

   ```bash
   sudo findmnt --verify --fstab /var/tmp/fstab.lab
   sudo mkdir -p /mnt/lab
   sudo mount -o nosuid,nodev /dev/mapper/vg_lab-lv_var /mnt/lab
   findmnt /mnt/lab -o TARGET,SOURCE,FSTYPE,OPTIONS
   sudo umount /mnt/lab
   ```

5. Aprendé las dos opciones que hacen que una entrada no sea fatal. `nofail` permite que el arranque continúe cuando el dispositivo está ausente; `x-systemd.device-timeout=` acota la espera:

   ```bash
   man 5 fstab | sed -n '/nofail/,+6p'
   man 5 systemd.mount | grep -n 'x-systemd.device-timeout' | head -n 3
   ```

6. Recordá la regla para editar un `fstab` *real*: después de cualquier cambio, ejecutá `sudo mount -a` **y** `sudo systemctl daemon-reload` antes de reiniciar. Si `mount -a` da error, el reinicio te habría dejado en modo de emergencia.

**Comprobá tu comprensión**

- **Q37.** Nombrá los seis campos de `fstab` en orden y dá el valor correcto de `pass` para `/`, para `/home` y para una entrada de swap.
- **Q38.** ¿Por qué se prefiere `UUID=` a `/dev/sda2`, y por qué `/dev/mapper/vg_lab-lv_root` es de todos modos aceptable para un volumen lógico?
- **Q39.** ¿Cuál de estos comandos habría detectado un error de tipeo en la ruta de un dispositivo *antes* del reinicio: `mount -a`, `findmnt --verify`, `blkid`, `systemctl daemon-reload`? Explicá qué verifica cada uno.
- **Q40.** Un disco USB externo de respaldo está en `fstab`. La máquina se cuelga en el arranque cuando está desconectado. ¿Qué dos opciones lo arreglan, y qué hace cada una?
- **Q41.** Una entrada para `/boot/efi` tiene `pass 1`. ¿Cuál es la consecuencia, y cuál debería ser en su lugar?

---

## Ejercicio 9 — Desmontaje

Dejá la máquina exactamente como la encontraste. El orden importa: desmontar, desactivar el swap, eliminar LVM de arriba hacia abajo, desasociar los loops, borrar las imágenes.

```bash
# 1. Nothing from the lab may still be mounted or swapped on
mount | grep -E '/mnt/lab' || true
sudo umount /mnt/lab 2>/dev/null || true
sudo swapoff /dev/vg_lab/lv_swap 2>/dev/null || true
swapon --show

# 2. LVM, from the top down
sudo vgchange -an vg_lab
sudo vgremove -f vg_lab
sudo pvremove -ff -y "${LOOP}p3" 2>/dev/null || true
sudo pvs; sudo vgs; sudo lvs

# 3. Detach the loop devices
sudo losetup -d "$LOOP"
sudo losetup -d "$LOOPB"
losetup -a

# 4. Remove the images
sudo rm -f /var/tmp/lab-disk.img /var/tmp/lab-bios.img /var/tmp/fstab.lab
sudo rmdir /mnt/lab
```

**Comprobá tu comprensión**

- **Q42.** ¿Por qué `vgremove` debe preceder a `losetup -d`, y en qué estado termina el sistema si desasociás primero el dispositivo loop?
- **Q43.** `losetup -d` devuelve `Device or resource busy`. Dá dos causas y el comando que identifica al que lo retiene.

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**A1.** La columna `TYPE` nombra cada capa explícitamente. `nvme0n1p1/p2/p3` son `part` — particiones del `disk` `nvme0n1`. `vg0-root`, `vg0-var`, `vg0-home`, `vg0-swap` son `lvm` — volúmenes lógicos de device-mapper. El volumen físico es `nvme0n1p3`: es una partición cuyo `FSTYPE` es `LVM2_member`, lo que significa que lleva una etiqueta y metadatos de LVM en lugar de un sistema de archivos. `lsblk` anida los LVs debajo de ella porque device-mapper reporta esa dependencia.

**A2.** El sistema de archivos se quedó sin **inodos**, no sin bloques. Se asigna un inodo por archivo (y por directorio, enlace simbólico, nodo de dispositivo), y ext2/3/4 fijan la cantidad de inodos en el momento de `mkfs` a partir de la relación `bytes-per-inode` (por defecto 16 KiB). Millones de archivos diminutos — un spool de correo, una caché, un árbol de compilación — agotan los inodos mucho antes que los bloques. La decisión de diseño que lo causó: aceptar la relación por defecto de `mkfs.ext4` en un sistema de archivos destinado a archivos pequeños, en lugar de `mkfs.ext4 -i 4096` o `-T small`. No se puede arreglar después del hecho en ext4 sin recrear el sistema de archivos, por eso pertenece a la fase de *diseño*. XFS asigna inodos dinámicamente y no tiene este modo de falla.

**A3.** `--real` filtra los pseudo-sistemas de archivos: `proc`, `sysfs`, `devtmpfs`, `tmpfs`, `cgroup2`, `securityfs`, y demás. Son interfaces del kernel o están respaldados por RAM, así que no consumen almacenamiento de bloque persistente. Importa porque `df -h` sin exclusiones reporta una docena de líneas `tmpfs` cuyos "tamaños" son límites de RAM, no de disco. Contarlas al dimensionar particiones lleva a diseñar para una capacidad que no existe en el disco — y, a la inversa, a olvidar que un `/tmp` en `tmpfs` consume RAM (y swap), no el disco que estabas presupuestando.

**A4.** Sin `-x` (`--one-file-system`), `du` desciende a través de los puntos de montaje. Si `/var/lib/containers`, `/var/log/journal` o un bind mount vive en un sistema de archivos *distinto*, `du` lo sumó al total de `/var` aunque `df` lo atribuya a otro lado. Usá siempre `du -x` cuando el objetivo es dimensionar el sistema de archivos sobre el que estás parado.

**A5.** `[ -d /sys/firmware/efi ]`. El kernel solo crea `/sys/firmware/efi` cuando fue arrancado por firmware UEFI y tiene disponibles los servicios de tiempo de ejecución EFI; en un arranque por BIOS/CSM heredada el directorio no existe. `lsblk` no puede responder esto porque un disco puede perfectamente llevar una partición con tipo ESP y aun así ser arrancado a través del CSM en modo BIOS — la tabla de particiones describe el disco, no el firmware que lo arrancó. Que `efibootmgr` falle con *"EFI variables are not supported on this system"* es una señal corroborante.

### Ejercicio 2

**A6.** `--partscan` (`-P`) le dice al kernel que lea la tabla de particiones del archivo de respaldo y cree los nodos de dispositivo `/dev/loopNpM` correspondientes. Sin él obtenés solo `/dev/loop0`; `sgdisk` igual escribirá una tabla válida dentro del archivo, pero `/dev/loop0p1` nunca aparece, así que `mkfs` y `pvcreate` no tienen dispositivo al que apuntar. La recuperación sin volver a asociar es `sudo partprobe /dev/loop0` o `sudo kpartx -a /dev/loop0`.

**A7.** `ls` reporta el tamaño *aparente* del archivo — la longitud lógica registrada en el inodo. `du` reporta los bloques realmente asignados. Un archivo disperso tiene huecos: rangos que nunca fueron escritos no consumen bloques y se leen como ceros. El riesgo en producción es que el sistema de archivos de respaldo se quede sin espacio *mientras una escritura a una región ya "asignada" está en vuelo*. El sistema de archivos huésped cree que tiene espacio, el anfitrión no puede proveer un bloque, y el resultado es un error de E/S a mitad de escritura — una falla mucho peor que un `ENOSPC` limpio, porque puede corromper los metadatos del sistema de archivos. Este es exactamente el peligro del sobreaprovisionamiento del thin provisioning, y es la razón por la que los thin pools de LVM necesitan monitoreo de `data_percent`.

**A8.** En las distribuciones basadas en systemd, `/tmp` es comúnmente `tmpfs` — respaldado por RAM, dimensionado por defecto al 50% de la memoria física. Escribir ahí una imagen de 8 GiB consumiría RAM y después swap, potencialmente disparando el OOM killer. `/tmp` además es limpiado por `systemd-tmpfiles` por temporizador y en el arranque, así que la imagen podría desaparecer a mitad del laboratorio. `/var/tmp` está en almacenamiento persistente y no se borra al reiniciar.

### Ejercicio 3

**A9.** La especificación UEFI requiere que el firmware implemente el sistema de archivos FAT12/16/32, y solo ese, para la ESP. El firmware corre *antes* que cualquier sistema operativo, así que no tiene driver de ext4 ni device-mapper. Por la misma razón la ESP no puede ser un volumen lógico: LVM es una construcción del kernel de Linux (device-mapper); el firmware solo ve la tabla de particiones cruda y espera una partición común, contigua y formateada en FAT. Tampoco puede estar sobre RAID por software con metadatos al principio, ni sobre LUKS.

**A10.**
(a) Para `sgdisk`, `ef00` es una abreviatura de dos bytes que expande al GUID de tipo `C12A7328-F81F-11D2-BA4B-00A0C93EC93B` cuando escribe la entrada de partición.
(b) Para el firmware UEFI, ese GUID es la definición de una EFI System Partition: el firmware escanea las entradas de partición buscándolo y mira dentro por `\EFI\BOOT\BOOTX64.EFI` o por una ruta de una entrada de arranque registrada con `efibootmgr`.
(c) Para el kernel de Linux es esencialmente informativo — el kernel montará sin problemas una partición con tipo ESP como cualquier cosa que sus drivers de sistema de archivos reconozcan; solo `systemd-gpt-auto-generator` y espacio de usuario similar actúan sobre el GUID (según la Discoverable Partitions Specification).
**El firmware es el que realmente lo hace cumplir.** Equivocate en el GUID y la máquina no arranca, sin importar lo que Linux piense.

**A11.** No — el kernel no lo hace cumplir. `pvcreate` escribe una etiqueta LVM en el sector 1 de cualquier dispositivo de bloque al que lo apuntes y funciona bien sobre una partición `8300`. El código de tipo es metadato para *otros* consumidores: le dice a las herramientas de particionado, a los instaladores, a `systemd-gpt-auto-generator`, y por sobre todo al humano que lea `sgdisk -p` seis meses después, para qué es la partición. Hacerlo bien es una práctica de corrección y mantenibilidad, no un requisito funcional — con las excepciones filosas de `ef00` (el firmware lo hace cumplir) y `ef02` (el instalador de GRUB la busca).

**A12.** La **ESP** contiene los binarios del gestor de arranque: `grubx64.efi`, `shimx64.efi`, `mmx64.efi`, cápsulas de firmware del fabricante y — con systemd-boot o una configuración de Unified Kernel Image — kernels completos e imágenes de initramfs. 512 MiB acomoda el caso de UKI y el arranque múltiple; el viejo mínimo de 100 MiB no. **`/boot`** contiene `vmlinuz-*`, `initramfs-*`, `System.map-*`, y el `grub.cfg` de GRUB más sus módulos. El comportamiento de distribución que mata un `/boot` de 200 MiB: los gestores de paquetes mantienen *varias* versiones de kernel instaladas (Debian/Ubuntu mantienen la actual más la anterior más la ABI más reciente; RHEL/Fedora usan por defecto `installonly_limit=3`). Cada kernel moderno más su initramfs pesa 100–200 MiB, así que la tercera actualización de kernel llena el sistema de archivos, `update-initramfs` falla a mitad de escritura, y — en el peor caso — te quedás con un initramfs truncado en un sistema que no arranca.

**A13.** `align-check optimal N` verifica que el desplazamiento de inicio de la partición N sea un múltiplo del *tamaño óptimo de E/S* del dispositivo, reportado a través de `/sys/block/*/queue/optimal_io_size` y `alignment_offset` (para un disco común, `parted` recurre a un grano de 1 MiB). La desalineación importa porque un disco con sector físico de 4 KiB (4Kn, o 512e que emula sectores lógicos de 512 bytes sobre 4 KiB físicos) debe realizar un ciclo de **lectura-modificación-escritura** cada vez que una escritura lógica cruza el límite de un sector físico: leer el sector de 4 KiB, parchear la parte modificada, escribirlo de vuelta. En SSDs el mismo problema ocurre a nivel del bloque de borrado y además aumenta la amplificación de escritura, desgastando la flash más rápido. Iniciar cada partición en 1 MiB (sector 2048) es un múltiplo de todo tamaño de sector físico, bloque de borrado y unidad de franja RAID plausible, y por eso toda herramienta moderna lo usa por defecto.

### Ejercicio 4

**A14.** El `boot.img` de GRUB entra en el área de arranque de 440 bytes del MBR, que es demasiado chica para contener un driver de sistema de archivos. Debe encadenar la carga de `core.img` (decenas a cientos de KiB, con los drivers de ext4/LVM/RAID necesarios para llegar a `/boot`).
- En **BIOS+MBR**, `core.img` se escribe en el *hueco post-MBR*: los sectores no asignados entre el MBR (sector 0) y la primera partición (tradicionalmente el sector 63, hoy el sector 2048).
- En **BIOS+GPT** ese hueco no está libre — GPT ubica su encabezado en el LBA 1 y su arreglo de 128 entradas de partición en los LBA 2–33, y las herramientas pueden usar más. No hay espacio escribible garantizado. La **partición BIOS boot** `ef02` (GUID `21686148-6449-6E6F-744E-656564454649`) existe precisamente para darle a `grub-install` una región reservada y avalada por la especificación, de 1–2 MiB, donde escribir `core.img`.

**A15.** Formatearla. Poner un sistema de archivos en la partición BIOS boot sobrescribe `core.img` con el superbloque y los metadatos del sistema de archivos. El síntoma es una máquina que llega a `boot.img`, falla al cargar la etapa 1.5, e imprime algo como `error: unknown filesystem` seguido del prompt `grub rescue>` — o, en algunas versiones, simplemente se cuelga después de `GRUB` sin más salida. El arreglo es arrancar desde un medio de rescate y volver a ejecutar `grub-install`. Esta es la trampa: la partición debe dejarse **cruda**, y nunca debe aparecer en `/etc/fstab`.

**A16.** MBR permite solo cuatro entradas de partición *primarias* en su tabla de 64 bytes. Con 1, 2 y 3 primarias, tenés que hacer de la partición 4 una partición **extendida** que abarque el espacio restante, y después crear particiones **lógicas** dentro de ella. Los dos sistemas de archivos nuevos pasan a ser `/dev/sdb5` y `/dev/sdb6` — la numeración de particiones lógicas empieza en 5 incondicionalmente, dejando un hueco después del 3 porque el número 4 lo consume el contenedor extendido. La partición extendida en sí no contiene ningún sistema de archivos; es una cadena de EBRs.

**A17.** MBR almacena el LBA inicial y la longitud de cada partición en campos de **32 bits**. Máximo de sectores direccionables = 2³² − 1 ≈ 4,295 × 10⁹. Con sectores de 512 bytes: 2³² × 512 bytes = 2 TiB (2.199.023.255.552 bytes). Cualquier cosa más allá de 2 TiB es indireccionable en una tabla MBR, que es la razón práctica por la que GPT — con LBAs de 64 bits — se volvió obligatoria para las unidades modernas. (Un disco 4Kn con sectores de 4096 bytes empuja el límite de MBR a 16 TiB, pero eso depende del disco y del firmware, y no es la respuesta que se espera en el examen.)

**A18.** No, no se usa, y no, no es perjudicial. En modo UEFI el firmware busca únicamente una partición con el GUID de ESP y carga un binario `.efi` desde ella; no tiene concepto de partición BIOS boot e ignora esa entrada por completo. Llevar tanto una partición `ef02` como una `ef00` es de hecho la técnica estándar para un disco de **firmware dual** — la misma unidad arranca en máquinas con BIOS heredada y en máquinas UEFI — a un costo de 1–2 MiB. Instaladores como el de Debian crean exactamente esto cuando se les indica soportar ambos.

### Ejercicio 5

**A19.** Physical Volume → Volume Group → Logical Volume.
- PV: `pvcreate /dev/sdb1` — escribe la etiqueta LVM y el área de metadatos sobre un dispositivo de bloque.
- VG: `vgcreate vg_lab /dev/sdb1` — agrupa uno o más PVs en un grupo con nombre y un tamaño de extensión fijo.
- LV: `lvcreate -L 10G -n lv_data vg_lab` — asigna extensiones del conjunto libre del grupo a un dispositivo de device-mapper en `/dev/vg_lab/lv_data` (canónicamente `/dev/mapper/vg_lab-lv_data`).

**A20.** LVM asigna espacio en **Physical Extents** enteras. El tamaño de PE por defecto es 4 MiB, y 1000 MiB son exactamente 250 extensiones, así que obtenés 1000.00 MiB. En un VG creado con un tamaño de PE distinto — digamos `vgcreate -s 32M` — 1000 MiB son 31,25 extensiones, que LVM redondea **hacia arriba** a 32 extensiones = 1024 MiB. La propiedad que lo controla es el tamaño de extensión del VG, visible como `PE Size` en `vgdisplay` o `vg_extent_size` en `vgs -o`. Queda fijado en el momento de `vgcreate` y afecta tanto la granularidad como el tamaño máximo de LV.

**A21.** Porque las extensiones libres en el VG son lo que hace real la flexibilidad de LVM; un VG asignado al 100% es apenas mejor que particiones fijas. Dos operaciones que habilita: (1) **`lvextend`** — agrandar el volumen que resulte estar subdimensionado, en línea, sin reparticionar; (2) **`lvcreate -s`** — una instantánea de copia en escritura, que necesita extensiones libres para su almacén de excepciones y es la forma estándar de tomar un respaldo consistente o un punto de reversión previo a una actualización. Una regla habitual en producción es asignar de forma conservadora en la instalación y mantener el 20–30% del VG sin asignar, dado que agrandar es trivial y encoger un sistema de archivos ext4 montado no es posible en absoluto (requiere desmontar; XFS no puede encoger ni siquiera así).

**A22.** Redimensionaste el *dispositivo de bloque* pero no el *sistema de archivos* que vive sobre él. O le pasás `-r` / `--resizefs` a `lvextend`, o ejecutás `sudo resize2fs /dev/vg_lab/lv_var` después. Para **XFS** el equivalente es `sudo xfs_growfs /mnt/lab` — notá que `xfs_growfs` toma el **punto de montaje**, no el dispositivo, y que XFS solo puede crecer, nunca encoger.

**A23.** Sí, GRUB2 puede leer `/boot` desde un volumen lógico LVM **lineal o en franjas**: incluye un módulo `lvm` que entiende los metadatos de LVM2, y `grub-install` lo embebe en `core.img`. No puede manejar volúmenes **thin** de LVM, y su soporte para niveles de RAID y volúmenes de caché/writecache es limitado. Los instaladores igualmente mantienen `/boot` en una partición común por *fragilidad, no por imposibilidad*: cada capa adicional entre el firmware y `vmlinuz` es una cosa más cuyo formato puede cambiar bajo tus pies (un salto de formato de metadatos de LVM, un `grub-install` que corrió antes de que el módulo `lvm` estuviera disponible), y el modo de falla es una máquina que no arranca, recuperable solo desde un medio de rescate. El mismo razonamiento aplica a LUKS — el soporte de LUKS2 de GRUB históricamente excluyó la KDF Argon2id por defecto, así que muchos instaladores todavía dejan `/boot` sin cifrar o en LUKS1; verificá contra la versión de GRUB de tu distribución antes de confiar en ello.

**A24.** El almacén de excepciones de copia en escritura de la instantánea está dimensionado en 1 GiB. Cada primera escritura a una extensión del origen copia los datos originales a ese almacén. Una vez que 3 GiB de escrituras han golpeado extensiones distintas del origen, el almacén se desborda, y el kernel **invalida la instantánea**: queda inutilizable y cualquier intento de leerla devuelve errores de E/S. `lvs` muestra `data_percent` en 100.00 y el quinto carácter del campo `lv_attr` (estado) pasa a ser `I` de *invalid* — por ejemplo `swi-I-s---` en lugar de un saludable `swi-a-s---`. La lección para el diseño: dimensioná una instantánea para la *rotación de escrituras esperada en el origen durante la vida de la instantánea*, no para el tamaño del origen, y borrala en cuanto el respaldo termine. Habilitá `snapshot_autoextend_threshold` en `lvm.conf` si la rotación es impredecible.

### Ejercicio 6

**A25.** No. La vieja regla de "swap = 2 × RAM" data de una época en que la RAM se medía en megabytes y el kernel requería almacenamiento de respaldo para toda la memoria anónima; carece de sentido con 128 GiB. La guía de RHEL para >64 GiB sin hibernación es "al menos 4 GiB". Una cifra defendible es **4–8 GiB**. La justificación es que el swap en un servidor moderno de memoria grande no está ahí para extender la RAM — si el heap de la JVM realmente excede la memoria física, la máquina se va a arrastrar hasta la inutilidad mucho antes de quedarse sin memoria. El swap está ahí para permitirle al kernel expulsar páginas anónimas genuinamente frías (código de arranque de demonios, asignaciones filtradas pero nunca tocadas) para que la caché de páginas pueda usar esa RAM, y para darle a una situación de OOM unos segundos de gracia en los que el monitoreo pueda dispararse. Notá además lo específico de la JVM: un heap que va a swap causa pausas de GC de duración patológica, así que adicionalmente limitarías el heap por debajo de la RAM física y considerarías `vm.swappiness=1`.

**A26.** Porque cualquier proceso que pueda leer el archivo de swap puede leer el contenido de memoria de todo proceso del sistema que haya sido enviado a swap — contraseñas, claves privadas, tokens de sesión. El modo `0600` con propietario `root` restringe eso a root, igualando la protección que una *partición* de swap obtiene de los permisos de su nodo de dispositivo. `mkswap` no se niega — advierte: `mkswap: /var/tmp/swapfile: insecure permissions 0644, fix with: chmod 0600 /var/tmp/swapfile`. Es **`swapon`** el que se niega, fallando con `swapon: /var/tmp/swapfile: insecure permissions 0644, 0600 suggested` en `util-linux` moderno. El archivo además debe ser propiedad de root y no debe ser disperso.

**A27.** El kernel usa siempre primero el área de swap disponible de **mayor prioridad** y solo desborda a áreas de menor prioridad cuando la superior está llena. Así que todo el swapping va al dispositivo NVMe hasta usar el 100% de su capacidad, y recién entonces el HDD recibe páginas — una jerarquía sensata. Si ambas tienen `pri=10`, el kernel hace **round-robin** entre ellas, distribuyendo las asignaciones en franjas entre las dos áreas, lo que aproximadamente duplica el rendimiento cuando los dispositivos son de igual velocidad. (Distribuir en franjas entre un NVMe y un HDD con la misma prioridad es lo peor de ambos mundos: el rendimiento queda acotado por el HDD.) La prioridad se establece con `swapon -p N` o con la opción `pri=N` en `fstab`; sin ella el kernel asigna prioridades negativas descendentes en el orden de activación.

**A28.** (1) **Capacidad**: el área de swap debe ser al menos tan grande como la cantidad de RAM que haya que volcar — en la práctica ≥ la RAM física, dado que la imagen de reanudación puede, en el peor caso, contenerla toda. RHEL recomienda 1,5 × RAM en la banda de 8–64 GiB precisamente para dejar margen. (2) **Resolubilidad en el momento de reanudar**: el initramfs debe poder encontrar y leer el área de swap antes de que se monte el sistema de archivos raíz, lo que significa que debe ser un área única y contigua referenciada por el parámetro de kernel `resume=UUID=…` (y, si es un *archivo* de swap, además por `resume_offset=`, obtenido con `filefrag -v`). Un área de swap repartida en dos dispositivos, o una cuyo dispositivo requiera red o un driver no disponible en el arranque temprano, no puede servir como dispositivo de reanudación.

**A29.** No, no deshabilita el swapping. `vm.swappiness` controla la *preferencia relativa* del kernel por reclamar páginas anónimas frente a la caché de páginas: 0 significa "reclamá memoria anónima solo cuando la alternativa es que falle una asignación". Bajo presión genuina de memoria el kernel igual hará swap en lugar de invocar al OOM killer. El efecto práctico desde Linux 3.5 es que `swappiness=0` hace al kernel mucho más agresivo descartando la caché de páginas — lo que, en una base de datos o un servidor de archivos, puede ser *peor* para el rendimiento que permitir un poco de swapping. El valor para deshabilitar el swap por completo es `swapoff -a`, no un ajuste de swappiness; `vm.swappiness=1` es la elección habitual de "casi nunca, pero conservá la red de seguridad".

**A30.**
- **Ventaja de la partición**: distribución en disco contigua garantizada, sin una capa de sistema de archivos interpuesta, así que no hay fragmentación ni indirección o bloqueos a nivel de sistema de archivos en la ruta de E/S del swap. Además no puede ser borrada accidentalmente, movida por un desfragmentador, ni afectada por un `fsck` del sistema de archivos anfitrión, y es lo más simple para la hibernación.
- **Ventaja del archivo**: puede crearse, redimensionarse y eliminarse en cualquier momento en un sistema en funcionamiento sin reparticionar — `fallocate`, `mkswap`, `swapon`, listo. En una instancia de nube o una VM cuya distribución de disco queda fijada en el aprovisionamiento, esa flexibilidad es el factor decisivo. Los kernels modernos acceden a los archivos de swap a través del mapa de extensiones con una sobrecarga insignificante comparada con la penalización histórica.

### Ejercicio 7

**A31.** **A favor de un `/var` separado:** aísla el crecimiento no acotado y dirigido desde afuera respecto del sistema de archivos raíz. Los logs, los spools de correo, las colas de impresión, las cachés de paquetes y las imágenes de contenedor crecen todos en respuesta a entradas que el administrador no controla. Un `/` lleno es cualitativamente peor que un `/var` lleno — puede impedir que PAM escriba archivos de sesión, que `systemd` escriba estado de tiempo de ejecución, y en el peor caso impedir el inicio de sesión, convirtiendo un incidente de espacio en disco en una visita presencial. **En contra de seis sistemas de archivos en una VM pequeña:** espacio libre varado y rigidez administrativa. En un disco de 20 GiB, seis sistemas de archivos cada uno con su margen de seguridad desperdician varios gigabytes que ningún sistema de archivos individual puede pedir prestados; y el modo de falla que realmente vas a sufrir es "`/var` está lleno mientras `/home` está 90% vacío", que en un único sistema de archivos raíz nunca habría ocurrido. La regla práctica correcta: dividí cuando un directorio tiene un motor de crecimiento independiente, un requisito de seguridad distinto, o una cadencia de respaldo/instantánea distinta — no por defecto.

**A32.** `/home` recibe la mayor parte del espacio, por amplio margen — en un disco de 4 TiB para 200 usuarios, algo así como 3 TiB. El mecanismo no visible en la tabla de particiones son las **cuotas de disco**: `quota`/`quotatool` en ext4 (opción de montaje `usrquota,grpquota` o el flag de característica `quota`, más `quotacheck`/`quotaon`), o cuotas de proyecto en XFS (`pquota`). Las cuotas aplican *por sistema de archivos*, que es precisamente por qué `/home` debe ser su propio sistema de archivos — no podés poner cuota a un directorio en un sistema de archivos raíz compartido con el mecanismo tradicional. Límites blandos con un período de gracia más un techo duro es la configuración habitual.

**A33.** No es inútil. `noexec` impide que el kernel honre el `execve()` de un binario o de un script vía su shebang. Lo que *no* impide es que un intérprete ya permitido sea invocado explícitamente sobre un archivo de datos — `sh archivo`, `python archivo`, `perl archivo` — porque ahí el kernel ejecuta `/bin/sh`, que vive en un sistema de archivos ejecutable, y `archivo` es meramente entrada. La clase de ataque que sigue bloqueando es el **binario ELF depositado**: un atacante que gana un punto de apoyo limitado y escribe un exploit compilado, un rootkit o un criptominero en `/tmp` o `/home` no puede ejecutarlo. Eso cubre una fracción grande de los ataques automatizados y de mercadería, y es por eso que los benchmarks de CIS lo exigen. Debe entenderse como algo que eleva el costo, no como una frontera.

**A34.**
- **`tmpfs` es la elección equivocada** cuando las aplicaciones escriben archivos temporales grandes: el volcado de un `ORDER BY` grande de base de datos, una transcodificación de video, un `rpmbuild`/`dpkg-buildpackage` de un árbol de fuentes grande, o un directorio de preparación de `tar`. `tmpfs` consume RAM, así que un archivo temporal de varios gigabytes desaloja la caché de páginas y después empuja al sistema a swap o a OOM. El síntoma clásico es una compilación que tiene éxito en una máquina y agota la memoria en otra con menos RAM.
- **Un volumen lógico es la elección equivocada** en un sistema donde `/tmp` ve mucha rotación de archivos pequeños de alta frecuencia y donde importa el beneficio de seguridad de un borrador respaldado por RAM y borrado al reiniciar — y en cualquier sistema en el que preferirías no gastar disco en eso. Un `/tmp` persistente además acumula archivos rancios a través de los reinicios, necesitando una política de limpieza de `systemd-tmpfiles`, y le agrega desgaste de escritura extra a la flash.

**A35.** `containerd` almacena las imágenes y los sistemas de archivos de los contenedores bajo `/var/lib/containerd` (Docker: `/var/lib/docker`; Podman con root: `/var/lib/containers`; sin root: `~/.local/share/containers`). Cada capa descargada, cada capa escribible de un contenedor detenido y cada entrada de caché de compilación aterriza ahí, y el crecimiento lo impulsan los pipelines de CI y las etiquetas de imagen — completamente fuera del control del administrador. El cambio: darle al almacén de contenedores su **propio** volumen lógico, montado en `/var/lib/containerd`, para que una descarga de imagen no acotada llene ese volumen y nada más. `journald` sigue escribiendo en `/var/log/journal` sobre un `/var` separado, `sshd` sigue escribiendo `/var/log/*` y su estado de tiempo de ejecución, y conservás un sistema funcional sobre el cual ejecutar `crictl rmi --prune`. La falla alternativa — un `/var` lleno — detiene silenciosamente a `journald` (no escribirá más allá de su `SystemMaxUse`, pero un sistema de archivos lleno además rompe otros demonios) y puede bloquear los inicios de sesión.

**A36.** El **espacio libre varado** es capacidad libre que existe en el disco pero es inalcanzable para el sistema de archivos que la necesita, porque vive dentro de una partición fija distinta. Ejemplo numérico en un disco de 500 GiB dividido como `/` 50 GiB, `/var` 100 GiB, `/home` 350 GiB: `/var` llega al 100% durante un incidente de logs mientras `/home` está al 40% de uso — hay 210 GiB libres en el disco y completamente inutilizables para `/var`. Arreglarlo con particiones fijas requiere cirugía con `parted`, un redimensionado y tiempo fuera de servicio.

**LVM reduce** el problema de dos maneras: las extensiones no asignadas del VG pueden darse al LV que las necesite (`lvextend -r -L +50G vg/lv_var`) en línea y al instante; y un LV incluso puede extenderse sobre un PV recién agregado en un segundo disco. **No lo elimina**, porque el espacio ya *asignado* a un LV sigue estando varado — `/home` con 350 GiB y 210 GiB libres no puede prestarle a `/var` sin encoger, y encoger requiere desmontar en ext4 y es imposible en XFS. La mitigación es asignar de forma conservadora y mantener una reserva de extensiones libres; el thin provisioning va más lejos, al costo del riesgo de sobreaprovisionamiento y de un monitoreo obligatorio.

### Ejercicio 8

**A37.** Los seis campos, en orden: **dispositivo** (o `UUID=`/`LABEL=`/`PARTUUID=`), **punto de montaje**, **tipo de sistema de archivos**, **opciones de montaje**, **dump** (un flag heredado para la utilidad de respaldo `dump`; `0` en esencialmente todas las configuraciones modernas), **pass** (el número de pasada de `fsck`).
Valores de `pass`: `/` → **1**; `/home` → **2**; swap → **0**. La pasada 1 corre primero y sola (el sistema de archivos raíz debe verificarse antes que cualquier otro); las entradas de pasada 2 se verifican después y pueden verificarse en paralelo entre distintos dispositivos físicos; la pasada 0 significa "nunca verificar", lo cual es correcto para el swap, para `tmpfs`, para los sistemas de archivos de red, y para cualquier cosa sin un ayudante `fsck`.

**A38.** `/dev/sda2` es un **nombre asignado por el orden de enumeración de dispositivos**, que no es estable. Agregar un disco, cambiar un cable SATA/SAS, un orden distinto de sondeo de USB, una actualización de kernel que cambia la inicialización de drivers, o mover el disco a otra máquina: todo eso puede renumerar los dispositivos — y entonces `/dev/sda2` se refiere a una partición distinta o a ninguna, y el sistema no arranca. Un `UUID=` se escribe en el superbloque del sistema de archivos en el momento de `mkfs` y viaja con los datos, así que identifica el mismo sistema de archivos sin importar dónde aparezca el dispositivo. (`PARTUUID=` es el GUID de la entrada de partición GPT, igualmente estable, y sobrevive a un reformateo, cosa que `UUID=` no.)

`/dev/mapper/vg_lab-lv_root` es aceptable porque **no** es un nombre por orden de enumeración: se construye determinísticamente a partir del nombre del grupo de volúmenes y del nombre del volumen lógico. LVM escanea las etiquetas de PV en todos los dispositivos y ensambla el mismo VG bajo el mismo nombre sin importar en qué `/dev/sdX` aterrizaron los PVs. `/dev/vg_lab/lv_root` es el enlace simbólico equivalente. Ambos son tan estables como un UUID, y más legibles.

**A39.**
- **`mount -a`** — la verificación decisiva. Intenta montar cada entrada que no sea `noauto`, así que una ruta de dispositivo errónea, un tipo de sistema de archivos equivocado, una opción inválida o un directorio de punto de montaje faltante producen todos un error *ahora*, en un prompt de shell, en lugar de en el arranque. Este es el que detecta un error de tipeo en la ruta de un dispositivo.
- **`findmnt --verify`** — un análisis estático del archivo: señala puntos de montaje inalcanzables, tipos de sistema de archivos desconocidos, valores sospechosos de `pass`/`dump` y destinos duplicados, y *sí* reporta una fuente que no existe. No intenta el montaje, así que no atrapará toda falla en tiempo de ejecución (una opción que el sistema de archivos rechace, por ejemplo).
- **`blkid`** — solo confirma que un identificador existe y a qué mapea; no valida nada sobre el `fstab` en sí. Útil para producir el `UUID=` correcto en primer lugar.
- **`systemctl daemon-reload`** — regenera las unidades `.mount` que `systemd-fstab-generator` deriva de `/etc/fstab`. Hace aflorar quejas a nivel de parseo en el journal y es *requerido* después de editar `fstab` en un sistema con systemd para que la visión de systemd coincida con el archivo — pero no comprueba que el dispositivo exista.

La secuencia correcta después de editar un `fstab` real es: `findmnt --verify`, luego `systemctl daemon-reload`, luego `mount -a`, y recién entonces reiniciar.

**A40.** **`nofail`** — el arranque no falla si el dispositivo está ausente; systemd marca la unidad de montaje como no crítica en lugar de caer en modo de emergencia. **`x-systemd.device-timeout=5s`** — acota cuánto espera systemd a que el dispositivo aparezca antes de rendirse; sin ella el valor por defecto son 90 segundos de aparente cuelgue, y con `nofail` solamente igual te comés ese tiempo de espera. Usá ambas juntas. `noauto` es la tercera opción que vale la pena conocer: mantiene la entrada en `fstab` para un cómodo `mount /mnt/backup` pero nunca la monta en el arranque — apropiado cuando el disco está normalmente ausente, mientras que `nofail` encaja con un disco que normalmente está presente.

**A41.** `pass 1` significa "verificá este sistema de archivos en la primera pasada de `fsck`, antes que todos los demás". La pasada 1 está reservada para el sistema de archivos raíz: `fsck` ejecuta las entradas de pasada 1 en serie y primero, y tener una segunda entrada de pasada 1 es en el mejor caso inútil y en el peor retrasa o confunde el orden de verificación en el arranque. Además, correr `fsck.vfat` (`dosfsck`) sobre la ESP en cada arranque es indeseable — una verificación innecesaria y con capacidad de escritura sobre la partición de la que depende el firmware, y una fuente de quejas espurias por el "dirty bit". El valor correcto para `/boot/efi` es **`0`** (no verificar) en la mayoría de las distribuciones, o `2` como máximo; tanto Debian como Fedora entregan `0` para la ESP.

### Ejercicio 9

**A42.** Los dispositivos de device-mapper de los volúmenes lógicos están *mantenidos abiertos* por el kernel y su ruta de E/S termina en el dispositivo loop. Desasociar el dispositivo loop mientras un VG está activo le arranca el almacenamiento de respaldo por debajo a objetivos `dm` en vivo. `losetup -d` normalmente se negará con `Device or resource busy`; si se lo fuerza (`losetup -D`, o borrando el archivo mientras está asociado), los LVs quedan en `/dev/mapper` apuntando a un dispositivo sin respaldo, y toda E/S devuelve un error. Terminás entonces con entradas `dm` rancias que hay que limpiar con `dmsetup remove`, y `pvs`/`vgs` imprimirán advertencias `Couldn't find device with uuid …` en cada invocación hasta que el VG se limpie. De ahí el orden estricto de arriba hacia abajo: desmontar → `swapoff` → `vgchange -an` (desactivar) → `vgremove` → `losetup -d`.

**A43.** Dos causas: (1) un sistema de archivos en una de las particiones del loop sigue **montado** — incluido un montaje que olvidaste, o un automontador que lo agarró; (2) LVM todavía lo retiene — un VG sobre el loop sigue **activo**, así que device-mapper tiene la partición abierta. Una tercera causa común es que un área de swap en el dispositivo siga activa. Para identificar al que lo retiene:

```bash
sudo lsof "$LOOP"* 2>/dev/null
sudo fuser -vm "$LOOP" 2>/dev/null
lsblk "$LOOP"                       # shows any child dm/mount still present
sudo dmsetup ls --tree              # shows dm devices and their dependencies
cat /sys/block/$(basename "$LOOP")/holders/*   2>/dev/null
```

`lsblk` y `dmsetup ls --tree` son usualmente los más rápidos: muestran exactamente qué capa sigue apilada encima.

</details>