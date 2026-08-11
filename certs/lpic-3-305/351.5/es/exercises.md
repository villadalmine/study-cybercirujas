# 351.5 Gestión de Imágenes de Disco de Máquinas Virtuales — Ejercicios Guiados

> **Alcance.** Estos laboratorios cubren el objetivo 351.5 completo: formatos de imagen (`raw`, `qcow2`, `VMDK`), gestión con `qemu-img`, copy-on-write (backing files, snapshots internos/externos), redimensionamiento, acceso offline vía `qemu-nbd`/`losetup`/`kpartx`, manipulación de contenido con la toolchain **libguestfs**, y familiaridad con OVF.
>
> **Entorno.** Un host Linux con `qemu-utils` (o `qemu-img`), `libguestfs-tools`, `kpartx` y `util-linux`. Los pasos que tocan `/dev/nbd*`, dispositivos loop o `mount` requieren **root**; las herramientas `virt-*` de libguestfs **no**. Trabajá en un directorio de trabajo desechable: `mkdir -p ~/lab-351.5 && cd ~/lab-351.5`.
>
> **Seguridad.** Todo lo de acá opera sobre imágenes desechables que vos creás. Nada apunta al disco vivo de un guest en ejecución — nunca abras una imagen de disco que una VM en ejecución tenga abierta para escritura (la vas a corromper).

---

## Ejercicio 1 — Formatos de imagen e inspección con `qemu-img`

**Objetivo:** crear los tres formatos nombrados en el objetivo, leer sus metadatos, y ver cómo el *tamaño virtual* difiere del *tamaño en disco* (asignación sparse).

1. Creá una imagen **raw** de 2 GiB e inspeccionala:

   ```bash
   qemu-img create -f raw disk-raw.img 2G
   ```
   ```
   Formatting 'disk-raw.img', fmt=raw size=2147483648
   ```

2. Compará el tamaño *aparente* contra el tamaño *asignado* en disco:

   ```bash
   ls -lh disk-raw.img
   du -h --apparent-size disk-raw.img
   du -h disk-raw.img
   ```
   ```
   -rw-r--r-- 1 root root 2.0G Aug 11 12:00 disk-raw.img
   2.0G    disk-raw.img
   0       disk-raw.img
   ```

3. Creá una imagen **qcow2** y leé sus metadatos específicos del formato:

   ```bash
   qemu-img create -f qcow2 disk.qcow2 10G
   qemu-img info disk.qcow2
   ```
   ```
   Formatting 'disk.qcow2', fmt=qcow2 cluster_size=65536 extended_l2=off compression_type=zlib size=10737418240 lazy_refcounts=off refcount_bits=16

   image: disk.qcow2
   file format: qcow2
   virtual size: 10 GiB (10737418240 bytes)
   disk size: 196 KiB
   cluster_size: 65536
   Format specific information:
       compat: 1.1
       compression type: zlib
       lazy refcounts: false
       refcount bits: 16
       corrupt: false
       extended l2: false
   ```

4. Creá una imagen **VMDK** (VMware) y luego convertila a `qcow2`:

   ```bash
   qemu-img create -f vmdk disk.vmdk 4G
   qemu-img convert -p -f vmdk -O qcow2 disk.vmdk disk-from-vmdk.qcow2
   qemu-img info disk-from-vmdk.qcow2 | grep -E 'file format|virtual size'
   ```
   ```
   file format: qcow2
   virtual size: 4 GiB (4294967296 bytes)
   ```

5. Listá todos los formatos de salida que `qemu-img` entiende en este build:

   ```bash
   qemu-img --help | sed -n '/Supported formats/p'
   ```
   ```
   Supported formats: blkdebug blklogwrites blkverify bochs cloop ... qcow qcow2 qed raw vdi vhdx vmdk vpc ...
   ```

> **Q1.1** Un archivo `raw` y un `qcow2` recién creado reportan ambos un *tamaño virtual* de 10 GiB, y sin embargo `du` muestra que el qcow2 usa solo ~200 KiB mientras que el raw muestra 0. ¿Por qué el archivo raw también da 0, y qué característica del lado del host hace que ambos sean "thin"?
>
> **Q1.2** Nombrá dos capacidades que tiene `qcow2` que una imagen `raw` estructuralmente no puede proveer.
>
> **Q1.3** ¿Qué le hace `qemu-img convert` a las regiones sparse/no asignadas por defecto, y qué flag preserva la sparseness en el destino?

---

## Ejercicio 2 — Copy-on-write: backing files y cadenas de backing

**Objetivo:** construir una imagen base, superponerle overlays de solo lectura, y manipular la cadena con `rebase` y `commit`. Este es el mecanismo detrás de los linked clones y las imágenes golden.

1. Creá una imagen base y escribí un byte identificable en ella para poder probar después que los datos fluyen a través de la cadena:

   ```bash
   qemu-img create -f qcow2 base.qcow2 5G
   # (we'll treat base.qcow2 as our immutable "golden" image)
   ```

2. Creá un **overlay** cuyo backing file sea la base. Pasá siempre `-F` (backing format) — omitirlo está deprecado e imprime una advertencia:

   ```bash
   qemu-img create -f qcow2 -b base.qcow2 -F qcow2 overlay1.qcow2
   ```
   ```
   Formatting 'overlay1.qcow2', fmt=qcow2 cluster_size=65536 extended_l2=off compression_type=zlib size=5368709120 backing_file=base.qcow2 backing_fmt=qcow2 lazy_refcounts=off refcount_bits=16
   ```

3. Inspeccioná la cadena de backing completa:

   ```bash
   qemu-img info --backing-chain overlay1.qcow2
   ```
   ```
   image: overlay1.qcow2
   file format: qcow2
   virtual size: 5 GiB (5368709120 bytes)
   disk size: 196 KiB
   backing file: base.qcow2
   backing file format: qcow2
   ...
   image: base.qcow2
   file format: qcow2
   virtual size: 5 GiB (5368709120 bytes)
   disk size: 196 KiB
   ```

4. Apilá un segundo overlay sobre el primero, formando una cadena de tres eslabones `overlay2 → overlay1 → base`:

   ```bash
   qemu-img create -f qcow2 -b overlay1.qcow2 -F qcow2 overlay2.qcow2
   qemu-img info --backing-chain overlay2.qcow2 | grep -E 'image:|backing file:'
   ```
   ```
   image: overlay2.qcow2
   backing file: overlay1.qcow2
   image: overlay1.qcow2
   backing file: base.qcow2
   image: base.qcow2
   ```

5. **Commiteá** `overlay1` hacia abajo dentro de `base` (sus escrituras se fusionan en el backing file):

   ```bash
   qemu-img commit overlay1.qcow2
   ```
   ```
   Image committed.
   ```

6. **Rebaseá** `overlay2` directamente sobre la base. El modo seguro (por defecto) lee tanto el backing file viejo como el nuevo para mantener idénticos los datos visibles al guest:

   ```bash
   qemu-img rebase -b base.qcow2 -F qcow2 overlay2.qcow2
   qemu-img info --backing-chain overlay2.qcow2 | grep -E 'image:|backing file:'
   ```
   ```
   image: overlay2.qcow2
   backing file: base.qcow2
   image: base.qcow2
   ```

7. Contrastá con el rebase **unsafe**, que solo reescribe el puntero y no valida nada:

   ```bash
   qemu-img rebase -u -b base.qcow2 -F qcow2 overlay2.qcow2
   ```
   *(Sin salida. La forma `-u` asume que sabés que el nuevo contenido de backing es byte-idéntico donde el overlay está no asignado.)*

> **Q2.1** Cuando un guest **lee** un cluster no asignado en `overlay2.qcow2`, describí el camino de búsqueda a través de la cadena. Cuando **escribe**, ¿qué le pasa a ese cluster?
>
> **Q2.2** ¿Cuál es la diferencia práctica entre `qemu-img commit` y `qemu-img rebase`? ¿Cuál acorta (aplana) una cadena fusionando *hacia arriba* dentro del backing file?
>
> **Q2.3** Movés `base.qcow2` a un nuevo path absoluto. Ahora `overlay2` no abre. ¿Qué salió mal, y qué dos invocaciones de `rebase` (seguro vs `-u`) usarías para arreglar la referencia — y cuándo es correcta cada una?
>
> **Q2.4** ¿Por qué QEMU ahora *requiere* `-F`/`backing_fmt`? ¿Qué problema de seguridad/correctitud causaba históricamente el sondeo de formato (format probing) de los backing files?

---

## Ejercicio 3 — Snapshots internos vs externos

**Objetivo:** distinguir los snapshots *internos* de qcow2 (almacenados dentro del archivo) de los snapshots *externos* (un nuevo overlay), y gestionar ambos offline.

1. Tomá dos snapshots **internos** de una imagen qcow2 y listalos:

   ```bash
   qemu-img snapshot -c clean-install disk.qcow2
   qemu-img snapshot -c after-updates disk.qcow2
   qemu-img snapshot -l disk.qcow2
   ```
   ```
   Snapshot list:
   ID        TAG               VM SIZE                DATE     VM CLOCK          ICOUNT
   1         clean-install         0 B 2026-08-11 12:05:11  0000:00:00.000000
   2         after-updates         0 B 2026-08-11 12:06:02  0000:00:00.000000
   ```

2. Revertí la imagen al primer snapshot, luego borrá el segundo:

   ```bash
   qemu-img snapshot -a clean-install disk.qcow2   # apply/revert
   qemu-img snapshot -d after-updates disk.qcow2   # delete
   qemu-img snapshot -l disk.qcow2
   ```
   ```
   Snapshot list:
   ID        TAG               VM SIZE                DATE     VM CLOCK          ICOUNT
   1         clean-install         0 B 2026-08-11 12:05:11  0000:00:00.000000
   ```

3. Probá lo mismo sobre una imagen **raw** y observá la falla:

   ```bash
   qemu-img snapshot -c test disk-raw.img
   ```
   ```
   qemu-img: Could not create snapshot 'test': -95 (Operation not supported)
   ```

4. Creá un snapshot **externo** manualmente — este es exactamente el patrón de backing-file del Ejercicio 2, usado como una congelación puntual en el tiempo:

   ```bash
   # 'disk.qcow2' becomes the frozen, read-only base; new writes land in the overlay
   qemu-img create -f qcow2 -b disk.qcow2 -F qcow2 disk-snap-20260811.qcow2
   ```
   Para luego plegar los cambios de vuelta dentro de la base congelada:
   ```bash
   qemu-img commit disk-snap-20260811.qcow2
   ```

> **Q3.1** El `VM SIZE` de un snapshot interno da `0 B`. ¿Qué mide en realidad la columna `VM SIZE`, y por qué es distinta de cero solo para snapshots creados por un QEMU *en ejecución*?
>
> **Q3.2** Dá dos ventajas concretas de los snapshots externos sobre los internos para backups.
>
> **Q3.3** ¿Por qué falló el paso 3? ¿Qué propiedad única del formato `raw` es responsable?
>
> **Q3.4** Después de un snapshot externo, ¿qué archivo es seguro copiar para backup mientras el guest sigue corriendo, y qué archivo **no** debés tocar?

---

## Ejercicio 4 — Redimensionamiento de imágenes de disco

**Objetivo:** agrandar y achicar el *contenedor*, y entender por qué eso es solo la mitad del trabajo.

1. Agrandá el qcow2 en 5 GiB (relativo), luego fijá un tamaño absoluto:

   ```bash
   qemu-img resize disk.qcow2 +5G
   qemu-img info disk.qcow2 | grep 'virtual size'
   qemu-img resize disk.qcow2 20G
   qemu-img info disk.qcow2 | grep 'virtual size'
   ```
   ```
   virtual size: 15 GiB (16106127360 bytes)
   virtual size: 20 GiB (21474836480 bytes)
   ```

2. Intentá **achicar** y leé la salvaguarda:

   ```bash
   qemu-img resize disk.qcow2 5G
   ```
   ```
   qemu-img: Use the --shrink option to perform a shrink operation.
   qemu-img: warning: Shrinking an image will delete all data beyond the shrunk image size. Before performing such an operation, make sure there is no important data there.
   ```
   ```bash
   qemu-img resize --shrink disk.qcow2 5G
   ```

3. Entendé el problema de dos capas: `qemu-img resize` cambia solo el **tamaño del block device**. La **tabla de particiones** y el **filesystem** del guest no crecen por sí solos. La herramienta *content-aware* es `virt-resize`, que copia desde una imagen origen hacia una nueva imagen destino más grande y expande una partición elegida en una sola pasada:

   ```bash
   # Enlarge a real system image: grow /dev/sda2 to fill the new space
   qemu-img create -f qcow2 bigger.qcow2 30G
   virt-resize --expand /dev/sda2 guest.qcow2 bigger.qcow2
   ```
   ```
   Resize operation completed with no errors. Before deleting the old disk,
   carefully check that the resized disk boots and works correctly.
   ```

> **Q4.1** Después de `qemu-img resize disk.qcow2 +5G` sobre un disco que aloja un filesystem particionado, el guest sigue reportando la capacidad vieja. Listá la secuencia ordenada de operaciones *dentro del guest* necesarias para usar realmente el nuevo espacio para un root ext4 en un layout sin LVM (tabla de particiones → filesystem).
>
> **Q4.2** ¿Por qué achicar está protegido detrás de `--shrink` mientras que agrandar no?
>
> **Q4.3** `virt-resize` se niega a operar in-place y siempre escribe a una **nueva** imagen destino. ¿Por qué ese diseño es más seguro que un resize in-place?

---

## Ejercicio 5 — Acceso offline con `qemu-nbd`, `losetup` y `kpartx`

**Objetivo:** montar particiones desde dentro de una imagen usando el kernel del host. Primero construí una pequeña imagen particionada para que los pasos sean reproducibles.

### 5A — Construir una imagen de prueba con una partición y un filesystem

1. Creá una imagen raw, particionala, y hacé un filesystem ext4 vía un dispositivo loop:

   ```bash
   qemu-img create -f raw test.img 1G
   sudo losetup -fP --show test.img          # -P scans the partition table
   ```
   ```
   /dev/loop0
   ```
   ```bash
   sudo parted -s /dev/loop0 mklabel msdos mkpart primary ext4 1MiB 100%
   sudo partprobe /dev/loop0
   sudo mkfs.ext4 /dev/loop0p1
   sudo mount /dev/loop0p1 /mnt
   echo "hello from the guest disk" | sudo tee /mnt/README.txt
   sudo umount /mnt
   sudo losetup -d /dev/loop0
   ```

### 5B — Acceder a una imagen raw con `losetup` + `kpartx`

2. Adjuntá la imagen y exponé sus particiones como nodos device-mapper:

   ```bash
   sudo losetup -f --show test.img
   ```
   ```
   /dev/loop0
   ```
   ```bash
   sudo kpartx -av /dev/loop0
   ```
   ```
   add map loop0p1 (253:0): 0 2095104 linear 7:0 2048
   ```
   ```bash
   sudo mount /dev/mapper/loop0p1 /mnt
   cat /mnt/README.txt
   ```
   ```
   hello from the guest disk
   ```

3. Desmontá todo limpiamente, en orden inverso:

   ```bash
   sudo umount /mnt
   sudo kpartx -dv /dev/loop0
   sudo losetup -d /dev/loop0
   ```

### 5C — Acceder a una imagen qcow2 con `qemu-nbd`

`losetup` solo habla `raw`. Para `qcow2`/`vmdk` necesitás el driver de userspace **NBD**, que decodifica el formato y presenta un block device.

4. Cargá el módulo de kernel `nbd` con espacio para particiones, luego convertí y conectá:

   ```bash
   sudo modprobe nbd max_part=16
   qemu-img convert -f raw -O qcow2 test.img test.qcow2
   sudo qemu-nbd --connect=/dev/nbd0 test.qcow2
   sudo partprobe /dev/nbd0
   lsblk /dev/nbd0
   ```
   ```
   NAME    MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
   nbd0     43:0    0     1G  0 disk
   └─nbd0p1 43:1    0  1023M  0 part
   ```
   ```bash
   sudo mount /dev/nbd0p1 /mnt
   cat /mnt/README.txt
   ```
   ```
   hello from the guest disk
   ```

5. Desconectá limpiamente:

   ```bash
   sudo umount /mnt
   sudo qemu-nbd --disconnect /dev/nbd0
   ```
   ```
   /dev/nbd0 disconnected
   ```
   ```bash
   sudo rmmod nbd
   ```

6. Acceso de **solo lectura** — conectá con `-r` cuando no debés arriesgar ninguna escritura a una imagen sospechosa:

   ```bash
   sudo qemu-nbd -r --connect=/dev/nbd0 test.qcow2
   ```

> **Q5.1** `losetup` montó la imagen `raw` pero no puede abrir `test.qcow2`. ¿Por qué? ¿Qué agrega exactamente `qemu-nbd` que a `losetup` le falta?
>
> **Q5.2** ¿Cuál es el propósito de `max_part=16` en la línea `modprobe nbd`, y qué síntoma aparece si te lo olvidás?
>
> **Q5.3** En 5B, `kpartx -av` creó `/dev/mapper/loop0p1`. ¿Qué habría creado en cambio `losetup -fP` (como se usó en 5A), y por qué podrías preferir `kpartx` en algunos sistemas?
>
> **Q5.4** Montás una partición de un disco que una VM está *actualmente ejecutando*, en modo lectura-escritura, en el host. Nombrá el modo de falla y enunciá la regla que lo previene.

---

## Ejercicio 6 — Manipulación de contenido con libguestfs (`guestfish`, `virt-*`)

**Objetivo:** inspeccionar y editar el contenido de imágenes **sin root y sin montar en el host**. libguestfs bootea un pequeño appliance aislado (su propio kernel + `qemu`) que monta la imagen internamente, de modo que el kernel del host nunca parsea metadata de filesystem no confiable.

> Si las herramientas se cuelgan o dan error sobre KVM/permisos en una workstation o CI runner, forzá el backend directo: `export LIBGUESTFS_BACKEND=direct`. Agregá `LIBGUESTFS_DEBUG=1 LIBGUESTFS_TRACE=1` para diagnosticar fallas de boot del appliance.

1. Enumerá filesystems y particiones en una imagen (funciona incluso cuando el host no puede montarlos):

   ```bash
   virt-filesystems -a guest.qcow2 --long -h --all
   ```
   ```
   Name       Type        VFS   Label  Size  Parent
   /dev/sda1  filesystem  ext4  -      512M  -
   /dev/sda2  filesystem  ext4  -      19G   -
   /dev/sda1  partition   -     -      512M  /dev/sda
   /dev/sda2  partition   -     -      19G   /dev/sda
   /dev/sda   device      -     -      20G   -
   ```

2. Reportá el uso por filesystem *dentro* de la imagen:

   ```bash
   virt-df -a guest.qcow2 -h
   ```
   ```
   Filesystem                    Size    Used  Available  Use%
   guest.qcow2:/dev/sda1         488M     73M       380M   16%
   guest.qcow2:/dev/sda2          19G    3.1G        15G   17%
   ```

3. Leé y listá archivos sin montar:

   ```bash
   virt-cat -a guest.qcow2 /etc/hostname
   virt-ls -a guest.qcow2 /etc/ssh
   ```
   ```
   web01
   moduli
   ssh_config
   sshd_config
   ssh_host_ed25519_key
   ssh_host_ed25519_key.pub
   ```

4. Copiá un archivo **hacia adentro** y otro **hacia afuera**:

   ```bash
   echo "127.0.0.1 registry.internal" > extra-hosts.txt
   virt-copy-in -a guest.qcow2 extra-hosts.txt /root
   virt-copy-out -a guest.qcow2 /etc/fstab ./exported
   ```

5. Editá un archivo in-place (abre `$EDITOR`, o usá `-e` para una expresión no interactiva estilo sed):

   ```bash
   virt-edit -a guest.qcow2 /etc/default/grub -e 's/quiet splash//'
   ```

6. Autodetectá el OS y volcá un inventario estructurado:

   ```bash
   virt-inspector -a guest.qcow2 | head -n 20
   ```
   ```xml
   <?xml version="1.0"?>
   <operatingsystems>
     <operatingsystem>
       <root>/dev/sda2</root>
       <name>linux</name>
       <distro>debian</distro>
       <product_name>Debian GNU/Linux 12 (bookworm)</product_name>
       <major_version>12</major_version>
       <minor_version>0</minor_version>
       <package_format>deb</package_format>
       <package_management>apt</package_management>
       ...
   ```

7. Exploración **interactiva** con `guestfish`. El flag `-i` autoinspecciona y monta los filesystems del guest en sus mountpoints reales:

   ```bash
   guestfish --rw -a guest.qcow2 -i
   ```
   ```
   Welcome to guestfish, the guest filesystem shell for
   editing virtual machine filesystems and disk images.

   ><fs> cat /etc/hostname
   web01
   ><fs> ll /var/log
   ...
   ><fs> download /etc/passwd /tmp/passwd.copy
   ><fs> exit
   ```
   Lo mismo, manejado manualmente (sin autoinspección) — la forma explícita que el examen espera que reconozcas:
   ```bash
   guestfish --rw -a guest.qcow2 <<'EOF'
   run
   list-filesystems
   mount /dev/sda2 /
   mount /dev/sda1 /boot
   cat /etc/os-release
   umount-all
   quit
   EOF
   ```

8. Recuperá espacio no usado — hacé la imagen **sparse** de nuevo después de borrados dentro de ella:

   ```bash
   virt-sparsify --compress guest.qcow2 guest-slim.qcow2
   ```

9. Preparación de un **template golden**: quitá la identidad específica de máquina (SSH host keys, machine-id, logs, historial de shell, leases DHCP) para que las VMs clonadas no colisionen:

   ```bash
   virt-sysprep -a guest.qcow2
   ```
   ```
   [   0.0] Examining the guest ...
   [   3.2] Performing "abrt-data" ...
   [   3.2] Performing "bash-history" ...
   [   3.3] Performing "machine-id" ...
   [   3.4] Performing "ssh-hostkeys" ...
   ...
   ```

> **Q6.1** Enunciá la razón arquitectónica más importante por la que libguestfs es más seguro que `qemu-nbd`+`mount` para inspeccionar una imagen **no confiable** o corrupta. (Pista: ¿qué kernel parsea el filesystem?)
>
> **Q6.2** ¿Cuándo recurrirías a `guestfish` interactivo en lugar de un `virt-cat`/`virt-edit` de una sola pasada? Dá una tarea que le sirva a cada herramienta.
>
> **Q6.3** Clonás un template cinco veces con `qemu-img create -b`, booteás las cinco, y reciben la **misma** SSH host key y `machine-id` duplicados. ¿Qué comando único de este ejercicio previene eso, y nombrá dos cosas que limpia?
>
> **Q6.4** Los usuarios de un guest borraron 8 GiB de archivos pero el `qcow2` en el host no se achicó nada. ¿Qué herramienta recupera ese espacio, y qué le tiene que pasar a los bloques liberados para que funcione?
>
> **Q6.5** ¿Por qué las herramientas `virt-*` pueden correr como usuario sin privilegios mientras que el Ejercicio 5 requería `sudo` en todo?

---

## Ejercicio 7 — Familiaridad con el Open Virtualization Format (OVF/OVA)

**Objetivo:** reconocer el formato de empaquetado sobre el que el objetivo te pide estar *familiarizado*, y convertir su disco embebido.

1. Inspeccioná los miembros de un **OVA** (un OVF distribuido como archivo tar):

   ```bash
   tar tvf appliance.ova
   ```
   ```
   -rw-r--r-- 0/0     8724 2026-01-15 09:00 appliance.ovf
   -rw-r--r-- 0/0      141 2026-01-15 09:00 appliance.mf
   -rw-r--r-- 0/0 1892352000 2026-01-15 09:00 appliance-disk1.vmdk
   ```

2. Leé el descriptor. El `.ovf` es un documento XML que describe el hardware virtual; el `.mf` (manifest) tiene los checksums; el disco es usualmente `VMDK`:

   ```bash
   tar xf appliance.ova appliance.ovf
   grep -E 'ovf:href|VirtualQuantity|ResourceType' appliance.ovf | head
   ```
   ```
   <File ovf:href="appliance-disk1.vmdk" ovf:id="file1" ovf:size="1892352000"/>
   <rasd:ResourceType>3</rasd:ResourceType>      <!-- 3 = virtual CPU -->
   <rasd:VirtualQuantity>2</rasd:VirtualQuantity>
   <rasd:ResourceType>4</rasd:ResourceType>      <!-- 4 = memory -->
   ```

3. Extraé y convertí el disco embebido a un formato nativo de KVM:

   ```bash
   tar xf appliance.ova appliance-disk1.vmdk
   qemu-img convert -p -O qcow2 appliance-disk1.vmdk appliance.qcow2
   ```

> **Q7.1** ¿Qué hay dentro de un archivo `.ova`, y qué aporta el descriptor `.ovf` que un `.vmdk` pelado no tiene?
>
> **Q7.2** OVF es un estándar de empaquetado *portable y neutral respecto al fabricante*, y sin embargo `qemu-img` no tiene un `-O ovf`. Explicá por qué convertir un disco es directo pero re-empaquetar un appliance OVF completo no es un trabajo para `qemu-img`.

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**A1.1** Ambos son *archivos sparse*: el filesystem del host (ext4/XFS/Btrfs) registra la longitud lógica del archivo en su inode sin asignar bloques de datos para regiones que nunca se escribieron. `qemu-img create -f raw` solo fija la longitud (un hueco abarcando todo el archivo → `du` muestra 0), mientras que `qcow2` escribe un pequeño header, tablas de metadata L1/L2 y tablas de refcount (~200 KiB), de ahí el footprint diminuto pero distinto de cero. La asignación sparse es la característica del lado del host que hace que ambos sean "thin". (Nota: en un filesystem sin soporte sparse, o después de `fallocate`, el archivo raw ocuparía los 2 GiB completos.)

**A1.2** Cualquier par de: snapshots internos; backing files / overlays copy-on-write; compresión opcional zlib/zstd; encriptación (LUKS); entradas L2 extendidas / subclusters; una representación compacta en disco que crece bajo demanda. Una imagen `raw` es simplemente la imagen lineal de bytes del disco sin capa de metadata, así que no puede ofrecer ninguna de estas por sí misma.

**A1.3** Por defecto `qemu-img convert` escribe el destino *de forma sparse* donde el origen se lee como cero — detecta corridas de ceros y deja huecos (para formatos que lo soportan), así que una imagen fresca de 10 GiB se convierte pequeña. `-S <size>` ajusta la granularidad de detección de sparseness (`-S 0` la deshabilita, produciendo un destino completamente asignado). La compresión en convert es `-c` (solo qcow2/qed).

### Ejercicio 2

**A2.1** **Lectura de un cluster no asignado:** QEMU consulta la tabla L2 de `overlay2`, encuentra el cluster no mapeado, y camina *hacia abajo* por la cadena — `overlay1`, luego `base` — devolviendo la primera copia poblada, o ceros si ninguna capa la tiene. **Escritura:** copy-on-write asigna un cluster nuevo *en `overlay2`* y escribe ahí; los backing files nunca se modifican (son de solo lectura desde la perspectiva del overlay).

**A2.2** `commit` fusiona los cambios de un overlay *hacia abajo* dentro de su backing file, y luego el overlay puede descartarse — aplana empujando las escrituras hacia la base. `rebase` cambia *cuál* backing file apunta una imagen (y en modo seguro copia los clusters que hagan falta para que los datos visibles al guest sigan idénticos). Ninguno fusiona "hacia arriba dentro del backing file" como operación de acortamiento del modo en que la formulación de la pregunta tienta — el que pliega un overlay dentro de su backing file es **`commit`**.

**A2.3** El overlay guarda una referencia a su backing file (path relativo o absoluto); mover `base.qcow2` la rompió. Para reparar: con la base realmente presente en la nueva ubicación, `qemu-img rebase -u -b <new/path/base.qcow2> -F qcow2 overlay2.qcow2` — el modo **unsafe** es *correcto acá* porque el contenido de backing es byte-idéntico, solo necesitás reescribir el puntero. Usá `rebase` **seguro** (sin `-u`) cuando el nuevo backing file tenga contenido *distinto* y necesites que QEMU copie clusters para que el guest vea los mismos datos.

**A2.4** Históricamente QEMU *sondeaba* el formato de un backing file a partir de su contenido. Datos controlados por el atacante o por el guest al inicio de un backing file raw podían fabricarse para parecer un header qcow2, redirigiendo lecturas o exponiendo archivos del host — una clase real de CVE. Requerir un `backing_fmt`/`-F` explícito elimina la conjetura: el formato se declara, no se infiere.

### Ejercicio 3

**A3.1** `VM SIZE` mide el **estado de RAM/dispositivos de la VM** guardado con el snapshot — solo un QEMU *en ejecución* (vía `savevm`/`loadvm` o `virsh snapshot`) captura la memoria viva, produciendo un tamaño distinto de cero. Un `qemu-img snapshot -c` sobre una imagen offline guarda solo el estado de disco, así que `VM SIZE` es `0 B`.

**A3.2** Cualquier par de: (1) los snapshots externos congelan el archivo base, así que podés hacerle backup (o de sus clusters) mientras el guest sigue escribiendo en el overlay; (2) funcionan sobre cualquier formato que el overlay soporte y son fáciles de descartar borrando el overlay; (3) no inflan/reescriben el archivo original del modo en que lo hacen los snapshots internos; (4) flujos de backup más simples e incrementales (copiá el overlay, luego `commit` o mantenelo como cadena).

**A3.3** `raw` **no tiene capa de metadata** — es solo los bytes del disco, sin ningún lugar donde almacenar tablas de snapshots. Los snapshots internos requieren un formato contenedor (qcow2/qed); de ahí "Operation not supported".

**A3.4** Después del snapshot externo, la **base** (`disk.qcow2`) está congelada de solo lectura y es el archivo seguro para copiar para backup. El **overlay** (`disk-snap-...qcow2`) está siendo escrito activamente por el guest en ejecución — copiarlo o alterarlo por debajo de la VM arriesga un backup roto/corrupto.

### Ejercicio 4

**A4.1** Para un root ext4 en `/dev/sda2` (MBR/GPT, sin LVM): (1) reescribí la tabla de particiones para que `sda2` se extienda al nuevo espacio — `growpart /dev/sda 2`, o borrá+recreá la partición con el mismo inicio vía `fdisk`/`parted`, luego `partprobe`; (2) hacé crecer el filesystem online — `resize2fs /dev/sda2` (para XFS sería `xfs_growfs <mountpoint>`). Contenedor → tabla de particiones → filesystem, en ese orden.

**A4.2** Agrandar solo agrega espacio no usado y nunca destruye datos, así que es seguro por defecto. Achicar descarta cada byte más allá del nuevo límite; si un filesystem/partición todavía vive ahí perdés datos irrecuperablemente. `--shrink` es un reconocimiento deliberado de "entiendo". (Y tenés que achicar el *filesystem y luego la partición* dentro del guest **antes** de achicar el contenedor, nunca después.)

**A4.3** `virt-resize` copia el contenido a un destino fresco, dejando intacta la imagen origen. Si algo sale mal — una mala selección de partición, una corrida interrumpida, un resultado no booteable — el original sigue intacto para reintentar o para volver a él. Un resize in-place que falle a mitad de la operación podría dejar corrupta la única copia.

### Ejercicio 5

**A5.1** `losetup` mapea un *rango crudo de bytes* de un archivo a un block device; no entiende formatos contenedores, así que no puede decodificar la indirección de clusters de qcow2, la compresión ni las cadenas de backing. `qemu-nbd` corre la capa de bloques completa de QEMU en userspace y exporta el disco virtual *decodificado* sobre NBD, así que `/dev/nbd0` presenta el disco crudo del guest sin importar el formato en disco (qcow2, vmdk, vdi, …).

**A5.2** `max_part=N` le dice al driver `nbd` que cree `N` nodos de dispositivo de partición por dispositivo NBD (p. ej. `/dev/nbd0p1`, `/dev/nbd0p2`, …). Sin eso el módulo usa por defecto 0 particiones por dispositivo: obtenés `/dev/nbd0` pero **no** aparecen los nodos `/dev/nbd0pX`, así que no podés montar una partición individual (tendrías que usar `kpartx`/`partx` sobre el dispositivo NBD en cambio).

**A5.3** `losetup -fP` habría creado nodos de partición del kernel directamente bajo el dispositivo loop: `/dev/loop0p1`, `/dev/loop0p2`. `kpartx` en cambio crea nodos device-mapper bajo `/dev/mapper/` (`loop0p1`). `kpartx` es útil cuando el escaneo automático de particiones del kernel no está disponible o cuando querés nodos gestionados por DM (p. ej. kernels viejos, o imágenes adjuntadas sin `-P`); también es la herramienta clásica para particiones dentro de stacks multipath/LVM.

**A5.4** Montar un disco lectura-escritura mientras una VM escribe al mismo disco causa **corrupción de filesystem / incoherencia de caché** — dos escritores independientes con cachés de página y journals separados se pisan entre sí. Regla: **nunca** adjuntes ni montes una imagen que un guest en ejecución tenga abierta para escritura. Si tenés que espiar, como mínimo usá solo lectura (`qemu-nbd -r`) — e incluso entonces los resultados pueden ser inconsistentes para un filesystem vivo.

### Ejercicio 6

**A6.1** libguestfs monta el objetivo dentro de un **kernel de appliance aislado** (una VM QEMU/KVM desechable), así que un filesystem malicioso o corrupto es parseado por *ese* kernel descartable, nunca por el del host. `qemu-nbd`+`mount` parsea el filesystem no confiable con el **kernel del host**, exponiendo al host a bugs de los drivers de filesystem y a escalada de privilegios. El aislamiento del kernel que parsea es la propiedad de seguridad clave.

**A6.2** Usá `guestfish` interactivo para trabajo exploratorio o multi-paso en un solo boot de appliance — hurgar, listar filesystems, encadenar varias lecturas/escrituras/subidas, depurar un layout desconocido. Usá `virt-cat` de una sola pasada (volcar un archivo) o `virt-edit` (cambiar un archivo de forma no interactiva, scriptable en un pipeline). Regla general: muchas operaciones sobre una imagen → `guestfish`; una única operación scripteada → la herramienta `virt-*` enfocada.

**A6.3** `virt-sysprep -a <image>` (corrido sobre el template *antes* de clonar). Limpia, entre otras cosas: SSH host keys, `/etc/machine-id`, reglas de red persistentes, leases DHCP, logs, historial de shell, spool de cron/at, spool de mail — cualquier par de estas es aceptable. Esto es lo que evita que las VMs clonadas compartan identidad.

**A6.4** `virt-sparsify` recupera el espacio. Funciona descartando/poniendo en cero los bloques *libres* que el filesystem del guest ya no referencia y luego escribiendo un destino sparse (con huecos perforados, opcionalmente comprimido) — así que los bloques liberados deben ser descubribles como libres/cero. En la práctica o bien dejás que `virt-sparsify` ponga en cero el espacio libre él mismo, o hacés `fstrim`/relleno con ceros dentro del guest primero para que los bloques no usados estén realmente en cero antes de sparsificar.

**A6.5** Las herramientas `virt-*` nunca tocan block devices del host ni `mount(2)`; le entregan la imagen a un appliance QEMU sin privilegios que hace todo el montaje internamente, así que no se necesita privilegio elevado del host. El Ejercicio 5 manipulaba objetos reales del kernel del host — dispositivos loop, el módulo `nbd`, nodos device-mapper y `mount` — todas operaciones privilegiadas, de ahí el `sudo`.

### Ejercicio 7

**A7.1** Un `.ova` es simplemente un archivo **tar** (sin comprimir) que agrupa el paquete OVF: el descriptor XML `.ovf`, un manifest `.mf` opcional de checksums SHA (y posiblemente un `.cert`), más uno o más discos virtuales (comúnmente `VMDK`). El descriptor `.ovf` agrega los *metadatos y el hardware virtual* que un disco pelado no tiene — dimensionamiento de CPU/memoria, NICs, controladores de disco, orden de boot, info de producto/EULA, mapeos de red — todo lo que un hypervisor necesita para instanciar la VM, no solo sus bytes.

**A7.2** Convertir el disco es una operación bien definida sobre un único formato contenedor, que `qemu-img` hace nativamente. Un appliance OVF completo es un *paquete multi-archivo más una descripción de hardware en XML y un manifest de checksums* — re-empaquetar significa regenerar el descriptor, recalcular el manifest, mapear el hardware virtual al destino, y volver a hacer el tar. Eso es trabajo de orquestación/empaquetado que es propiedad de herramientas como `ovftool`, `virt-v2v` o `virt-install --import`, no de un conversor de una sola imagen como `qemu-img`. El objetivo solo pide *familiaridad* con OVF por esta razón.

</details>

---

### Fuentes

- LPI — *Exam 305-300 Objectives*, objetivo 351.5: <https://www.lpi.org/our-certifications/exam-305-objectives/>
- QEMU — referencia de invocación de *qemu-img* (formatos, `convert`, `snapshot`, `rebase`, `commit`, `resize`): <https://www.qemu.org/docs/master/tools/qemu-img.html>
- QEMU — manual de *qemu-nbd* y el módulo de kernel `nbd`: <https://www.qemu.org/docs/master/tools/qemu-nbd.html>
- QEMU — *Live/external snapshots and backing files* (block layer): <https://www.qemu.org/docs/master/interop/live-block-operations.html>
- libguestfs — índice de herramientas (`guestfish`, `virt-filesystems`, `virt-df`, `virt-cat`, `virt-ls`, `virt-copy-in/out`, `virt-edit`, `virt-inspector`, `virt-resize`, `virt-sparsify`, `virt-sysprep`): <https://libguestfs.org/>
- `kpartx(8)` y `losetup(8)`: manpages de util-linux / device-mapper-multipath — <https://man7.org/linux/man-pages/man8/losetup.8.html>, <https://man7.org/linux/man-pages/man8/kpartx.8.html>
- DMTF — *Open Virtualization Format (OVF) Specification* (DSP0243): <https://www.dmtf.org/standards/ovf>