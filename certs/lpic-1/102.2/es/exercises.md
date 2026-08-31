# LPIC‑1 — 102.2 Instalar un gestor de arranque
## Ejercicios guiados (profundidad de producción)

**Examen:** LPI 101‑500 (LPIC‑1 v5.0) · **Objetivo 102.2** · **Peso:** 3.13
**Objetivos oficiales:** https://www.lpi.org/our-certifications/exam-101-objectives/

---

### Requisitos del laboratorio y seguridad

Todos los pasos destructivos de este material ocurren **dentro de una imagen de disco loop‑back descartable o de una máquina virtual desechable**. Nunca ejecute `grub-install`, `dd` sobre un sector de arranque ni `parted` contra el disco desde el que arranca su estación de trabajo.

| Requisito | Notas |
|---|---|
| Una VM Linux que pueda romper | Debian 12/13, Ubuntu 22.04+, Fedora 39+ u openSUSE. Tome una instantánea antes. |
| Acceso de root | Todos los comandos con el prefijo `#` requieren root (`sudo -i`). |
| Paquetes | `grub2-common`/`grub-common`, `grub-pc-bin` (Debian) o `grub2-pc-modules` (Fedora), `util-linux` ≥ 2.37, `parted`, `gdisk`, `efibootmgr` (equipos UEFI), `xxd`/`bsdextrautils`. |
| Acceso a consola | Para los ejercicios 8 y 9 debe poder llegar al menú de GRUB — consola de la VM, IPMI/serie o teclado físico. SSH no alcanza. |

**Convenciones usadas más abajo**

* `#` → comando ejecutado como root · `$` → sin privilegios · `grub>` → el intérprete de comandos de GRUB.
* División por distribución: Debian/Ubuntu usan los binarios `grub-*` y `/boot/grub/`; Red Hat/Fedora/SUSE usan los binarios `grub2-*` y `/boot/grub2/`. Donde difieren, se muestran ambos.
* Las salidas son representativas. Las suyas diferirán en UUID, versiones de kernel y nombres de dispositivo — de eso se tratan las preguntas.

---

## Ejercicio 1 — Determinar qué ruta de arranque usa realmente su sistema

Antes de tocar un gestor de arranque debe saber *cuál* gestor está corriendo y *cómo* llega el firmware hasta él. BIOS/CSM y UEFI son rutas de código distintas, con modos de fallo distintos, y `grub-install` se comporta de forma diferente en cada una.

1. Pregunte al kernel si el firmware le entregó los servicios de tiempo de ejecución EFI:

   ```bash
   # [ -d /sys/firmware/efi ] && echo "UEFI" || echo "BIOS/CSM"
   UEFI
   ```

2. Confirme desde el búfer de mensajes del kernel, que registra el traspaso durante el arranque:

   ```bash
   # dmesg | grep -iE 'efi|bios' | head -5
   [    0.000000] efi: EFI v2.70 by EDK II
   [    0.000000] efi: ACPI=0x7f9de000 ACPI 2.0=0x7f9de014 SMBIOS=0x7f9cc000
   [    0.000000] efi: Remapping runtime services memory map
   ```

3. Identifique el kernel en ejecución y la línea de comandos que el gestor de arranque le pasó:

   ```bash
   $ uname -r
   6.1.0-18-amd64
   $ cat /proc/cmdline
   BOOT_IMAGE=/boot/vmlinuz-6.1.0-18-amd64 root=UUID=6f2c1a7e-9b31-42d4-8f0a-1c2b3d4e5f60 ro quiet
   ```

4. Localice el directorio de GRUB y la configuración generada en uso:

   ```bash
   # ls -l /boot/grub/grub.cfg /boot/grub2/grub.cfg 2>/dev/null
   -r--r--r-- 1 root root 7412 Aug 20 09:14 /boot/grub/grub.cfg
   # readlink -f /boot/grub2/grub.cfg 2>/dev/null
   /boot/efi/EFI/fedora/grub.cfg
   ```

5. Pregunte a las propias herramientas de sondeo de GRUB qué opinan de `/boot`:

   ```bash
   # grub-probe --target=device /boot
   /dev/vda2
   # grub-probe --target=fs /boot
   ext2
   # grub-probe --target=fs_uuid /boot
   a1b2c3d4-0000-4444-8888-aabbccddeeff
   # grub-probe --target=drive /boot
   (hd0,gpt2)
   ```

**Verificación de comprensión**

* **Q1.1** — ¿Por qué la presencia de `/sys/firmware/efi` es una prueba fiable, y qué *no* le dice sobre la capacidad del hardware de la máquina?
* **Q1.2** — `/proc/cmdline` muestra `BOOT_IMAGE=/boot/vmlinuz-...`. ¿Qué componente escribió ese parámetro y para qué sirve?
* **Q1.3** — En un sistema Fedora UEFI, `readlink -f /boot/grub2/grub.cfg` puede resolverse dentro de `/boot/efi/EFI/fedora/`. ¿Qué error operativo invita esa disposición cuando un administrador "edita la configuración de GRUB"?
* **Q1.4** — `grub-probe --target=fs /boot` devolvió `ext2` sobre un sistema de archivos que usted creó con `mkfs.ext4`. ¿Es un error del programa? Explíquelo.

---

## Ejercicio 2 — Mapear la cadena de arranque en el propio disco

GRUB 2 para `i386-pc` (BIOS) no cabe en el área de 446 bytes de código de arranque de un MBR. Allí sólo vive `boot.img`; contiene un puntero LBA a `core.img`, que reside o bien en el *hueco del MBR* (etiqueta msdos) o bien en una **partición de arranque BIOS** dedicada (etiqueta GPT). Entender esto es la diferencia entre reparar un arranque roto y reinstalar el sistema operativo.

1. Imprima la disposición de particiones con los *tipos* de partición, no sólo los sistemas de archivos:

   ```bash
   # lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTTYPENAME,MOUNTPOINTS
   NAME    SIZE TYPE FSTYPE PARTTYPENAME       MOUNTPOINTS
   vda      40G disk
   ├─vda1    1M part        BIOS boot
   ├─vda2  512M part vfat   EFI System         /boot/efi
   └─vda3 39.5G part ext4   Linux filesystem   /
   ```

   En util-linux anterior a 2.37, use `lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTTYPE,MOUNTPOINT` y resuelva el GUID a mano.

2. Lea el tipo de etiqueta del disco y el primer sector utilizable:

   ```bash
   # fdisk -l /dev/vda
   Disk /dev/vda: 40 GiB, 42949672960 bytes, 83886080 sectors
   Units: sectors of 1 * 512 = 512 bytes
   Disklabel type: gpt
   Disk identifier: 3F2504E0-4F89-41D3-9A0C-0305E82C3301

   Device       Start      End  Sectors  Size Type
   /dev/vda1     2048     4095     2048    1M BIOS boot
   /dev/vda2     4096  1052671  1048576  512M EFI System
   /dev/vda3  1052672 83884031 82831360 39.5G Linux filesystem
   ```

3. En un disco con etiqueta **msdos** no hay partición de arranque BIOS; mida el hueco en su lugar:

   ```bash
   # fdisk -l /dev/vdb | grep -A3 '^Device'
   Device     Boot Start      End  Sectors Size Id Type
   /dev/vdb1  *     2048 41943039 41940992  20G 83 Linux
   ```

   La primera partición empieza en el sector 2048, así que los sectores 1–2047 (1 MiB menos un sector) están libres para `core.img`.

4. Observe los primeros 512 bytes del disco y confirme la firma de arranque:

   ```bash
   # dd if=/dev/vdb bs=512 count=1 status=none | xxd | tail -3
   000001d0: 0000 0000 0000 0000 0000 0000 0000 0000  ................
   000001e0: 0000 0000 0000 0000 0000 0000 0000 0000  ................
   000001f0: 0000 0000 0000 0000 0000 0000 0000 55aa  ..............U.
   ```

5. Confirme las cadenas de la etapa 1 de GRUB y lea el puntero que incrustó:

   ```bash
   # dd if=/dev/vdb bs=512 count=1 status=none | strings
   ZRr=
   GRUB
   Geom
   Hard Disk
   Read
    Error
   # hexdump -C -s 0x5c -n 8 /dev/vdb
   0000005c  01 00 00 00 00 00 00 00                           |........|
   ```

   En `i386-pc`, el desplazamiento `0x5c` de `boot.img` contiene un LBA little‑endian de 8 bytes: el primer sector de `core.img`. `01` significa sector 1 — inmediatamente después del MBR, es decir, el área de incrustación.

6. Liste los módulos que GRUB instaló en disco para esta plataforma:

   ```bash
   # ls /boot/grub/i386-pc/ | head -6
   acpi.mod
   adler32.mod
   affs.mod
   ahci.mod
   all_video.mod
   at_keyboard.mod
   # ls /boot/grub/x86_64-efi/ 2>/dev/null | wc -l
   0
   ```

**Verificación de comprensión**

* **Q2.1** — ¿Por qué un disco GPT arrancado por BIOS requiere una partición de 1 MiB de tipo `EF02` (`21686148-6449-6E6F-744E-656564454649`), mientras que un disco MBR no?
* **Q2.2** — Un administrador alinea la primera partición en el sector 63 (la vieja convención CHS) en un disco MBR y luego ejecuta `grub-install /dev/sda`. ¿Qué ocurre y qué mensaje de error debería esperar?
* **Q2.3** — ¿Qué son los dos bytes `55 aa` en el desplazamiento `0x1FE`, y qué pasa si faltan?
* **Q2.4** — De los 512 bytes del MBR, ¿cuántos son código de arranque, cuántos la tabla de particiones y cuántos la firma?
* **Q2.5** — `/boot/grub/i386-pc/` existe pero `/boot/grub/x86_64-efi/` está vacío. ¿Qué le dice eso sobre cómo arranca este sistema, independientemente de lo que diga la pantalla de configuración del firmware?

---

## Ejercicio 3 — Leer `grub.cfg` sin editarlo

`grub.cfg` es **salida generada**. Tratarlo como un archivo de configuración es el error operativo más común de este objetivo — sus ediciones son destruidas silenciosamente por la siguiente actualización del paquete del kernel, que ejecuta `grub-mkconfig` desde un hook del paquete.

1. Confirme el aviso que escribe el generador:

   ```bash
   # head -6 /boot/grub/grub.cfg
   #
   # DO NOT EDIT THIS FILE
   #
   # It is automatically generated by grub-mkconfig using templates
   # from /etc/grub.d and settings from /etc/default/grub
   #
   ```

2. Liste los fragmentos generadores y observe que están numerados y son ejecutables:

   ```bash
   # ls -l /etc/grub.d/
   -rwxr-xr-x 1 root root  10046 Jan 15 2024 00_header
   -rwxr-xr-x 1 root root   6260 Jan 15 2024 10_linux
   -rwxr-xr-x 1 root root  12894 Jan 15 2024 20_linux_xen
   -rwxr-xr-x 1 root root  12059 Jan 15 2024 30_os-prober
   -rwxr-xr-x 1 root root   1416 Jan 15 2024 30_uefi-firmware
   -rwxr-xr-x 1 root root    214 Jan 15 2024 40_custom
   -rwxr-xr-x 1 root root    216 Jan 15 2024 41_custom
   -rw-r--r-- 1 root root    483 Jan 15 2024 README
   ```

3. Extraiga las entradas de menú tal como las verá el usuario:

   ```bash
   # grep -E "^\s*(menuentry|submenu)" /boot/grub/grub.cfg
   menuentry 'Debian GNU/Linux' --class debian --class gnu-linux ... $menuentry_id_option 'gnulinux-simple-6f2c1a7e-...' {
   submenu 'Advanced options for Debian GNU/Linux' $menuentry_id_option 'gnulinux-advanced-6f2c1a7e-...' {
   ```

4. Lea una entrada completa e identifique cada comando:

   ```bash
   # sed -n '/^menuentry .Debian/,/^}/p' /boot/grub/grub.cfg
   menuentry 'Debian GNU/Linux' --class debian --class gnu-linux --class os \
       $menuentry_id_option 'gnulinux-simple-6f2c1a7e-9b31-42d4-8f0a-1c2b3d4e5f60' {
       load_video
       insmod gzio
       insmod part_gpt
       insmod ext2
       search --no-floppy --fs-uuid --set=root a1b2c3d4-0000-4444-8888-aabbccddeeff
       echo    'Loading Linux 6.1.0-18-amd64 ...'
       linux   /vmlinuz-6.1.0-18-amd64 root=UUID=6f2c1a7e-9b31-42d4-8f0a-1c2b3d4e5f60 ro quiet
       echo    'Loading initial ramdisk ...'
       initrd  /initrd.img-6.1.0-18-amd64
   }
   ```

5. Valide la sintaxis del archivo generado (esto lo analiza con el propio intérprete de scripts de GRUB, sin arrancar):

   ```bash
   # grub-script-check /boot/grub/grub.cfg && echo "syntax OK"
   syntax OK
   ```

6. Inspeccione el bloque de entorno persistente, que *no* está en `grub.cfg`:

   ```bash
   # grub-editenv list
   saved_entry=Debian GNU/Linux
   boot_success=1
   ```

**Verificación de comprensión**

* **Q3.1** — En la entrada de arriba, `linux /vmlinuz-6.1.0-18-amd64` no tiene el prefijo `/boot`, y sin embargo `/proc/cmdline` decía `BOOT_IMAGE=/boot/vmlinuz-...`. ¿Por qué difieren ambas rutas?
* **Q3.2** — ¿Qué logra `search --no-floppy --fs-uuid --set=root <uuid>`, y por qué es más robusto que `set root=(hd0,gpt2)`?
* **Q3.3** — La entrada pasa `root=UUID=...` al kernel *y* además fija el `root` propio de GRUB. ¿Son lo mismo? ¿A qué se refiere cada uno?
* **Q3.4** — Los archivos de `/etc/grub.d/` están numerados. ¿Cuál es el significado del número, y qué ocurre si le quita el bit de ejecución a `30_os-prober`?
* **Q3.5** — ¿Dónde almacena `grub-editenv` la variable `saved_entry`, y por qué ese archivo no puede residir en un volumen lógico LVM o en un subvolumen Btrfs en algunas configuraciones?

---

## Ejercicio 4 — Cambiar el comportamiento de GRUB 2 por la vía soportada

La ruta de cambio soportada es: editar `/etc/default/grub` → ejecutar `grub-mkconfig -o <path>` → verificar el archivo generado.

1. Tome una instantánea del estado actual para poder demostrar qué cambió:

   ```bash
   # cp -a /etc/default/grub /root/grub.default.bak
   # cp -a /boot/grub/grub.cfg /root/grub.cfg.bak
   ```

2. Lea la configuración actual:

   ```bash
   # grep -vE '^\s*(#|$)' /etc/default/grub
   GRUB_DEFAULT=0
   GRUB_TIMEOUT=5
   GRUB_DISTRIBUTOR=`lsb_release -i -s 2> /dev/null || echo Debian`
   GRUB_CMDLINE_LINUX_DEFAULT="quiet"
   GRUB_CMDLINE_LINUX=""
   ```

3. Aplique un conjunto de cambios orientado a producción. Esto hace visible el menú durante 10 segundos, envía la consola tanto a VGA como al puerto serie (esencial en servidores sin monitor) y desactiva el submenú plegable:

   ```bash
   # cat >> /etc/default/grub <<'EOF'

   # --- lab 102.2 ---
   GRUB_TIMEOUT=10
   GRUB_TIMEOUT_STYLE=menu
   GRUB_DISABLE_SUBMENU=y
   GRUB_TERMINAL="console serial"
   GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
   GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8"
   GRUB_RECORDFAIL_TIMEOUT=10
   EOF
   ```

4. Regenere la configuración. **Observe el comando y la ruta de salida distintos según la distribución:**

   ```bash
   # Debian / Ubuntu
   # grub-mkconfig -o /boot/grub/grub.cfg
   Generating grub configuration file ...
   Found linux image: /boot/vmlinuz-6.1.0-18-amd64
   Found initrd image: /boot/initrd.img-6.1.0-18-amd64
   Warning: os-prober will not be executed to detect other bootable partitions.
   done

   # Red Hat / Fedora (BIOS)
   # grub2-mkconfig -o /boot/grub2/grub.cfg

   # Red Hat / Fedora (UEFI, RHEL 8 layout)
   # grub2-mkconfig -o /boot/efi/EFI/redhat/grub.cfg
   ```

   `update-grub` en Debian/Ubuntu es un envoltorio de dos líneas alrededor de `grub-mkconfig -o /boot/grub/grub.cfg`. Prefiera el comando real — es lo que pide el examen y lo que existe en todas partes.

5. Demuestre que el cambio llegó al archivo generado:

   ```bash
   # diff /root/grub.cfg.bak /boot/grub/grub.cfg | head -20
   < set timeout=5
   > set timeout=10
   > serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
   > terminal_input console serial
   > terminal_output console serial
   ```

6. Fije qué entrada arrancará la próxima vez — sin editar nada:

   ```bash
   # grub-set-default "Debian GNU/Linux"     # persistent default
   # grub-reboot 2                            # ONE-TIME override, next boot only
   # grub-editenv list
   saved_entry=Debian GNU/Linux
   next_entry=2
   ```

   `grub-set-default`/`grub-reboot` requieren `GRUB_DEFAULT=saved` en `/etc/default/grub`.

**Verificación de comprensión**

* **Q4.1** — ¿Cuál es la diferencia práctica entre `GRUB_CMDLINE_LINUX` y `GRUB_CMDLINE_LINUX_DEFAULT`? ¿Cuál usaría para añadir `console=ttyS0,115200n8`, y por qué?
* **Q4.2** — Apareció el aviso de `os-prober`. ¿Qué versión de GRUB 2 cambió este valor por defecto, cuál es la justificación de seguridad y qué ajuste lo vuelve a habilitar?
* **Q4.3** — Su servidor sin monitor está configurado con `GRUB_TIMEOUT=0`. Tras un corte de energía nunca vuelve, y la consola muestra el menú de GRUB esperando indefinidamente. ¿Qué mecanismo hizo esto y qué variable lo corrige?
* **Q4.4** — Configuró `GRUB_TIMEOUT=10` pero el menú sigue sin aparecer. ¿Qué otra variable lo está anulando y cuáles son sus valores admitidos?
* **Q4.5** — Después de `grub-mkconfig -o /boot/grub/grub.cfg`, ¿es también necesario volver a ejecutar `grub-install`? Justifique su respuesta en términos de qué escribe cada comando.

---

## Ejercicio 5 — Añadir una entrada de menú personalizada y una contraseña de arranque

1. Observe el esqueleto de `40_custom`:

   ```bash
   # cat /etc/grub.d/40_custom
   #!/bin/sh
   exec tail -n +3 $0
   # This file provides an easy way to add custom menu entries.  Simply type the
   # menu entries you want to add after this comment.  Be careful not to change
   # the 'exec tail' line above.
   ```

2. Añada una entrada de rescate que arranque el kernel actual directamente a un shell, más una entrada de firmware:

   ```bash
   # KVER=$(uname -r)
   # RUUID=$(findmnt -no UUID /)
   # BUUID=$(grub-probe --target=fs_uuid /boot)
   # cat >> /etc/grub.d/40_custom <<EOF

   menuentry 'Emergency shell (no init)' --class recovery {
       insmod part_gpt
       insmod ext2
       search --no-floppy --fs-uuid --set=root ${BUUID}
       linux /vmlinuz-${KVER} root=UUID=${RUUID} ro init=/bin/bash
       initrd /initrd.img-${KVER}
   }

   menuentry 'Reboot into firmware setup' {
       fwsetup
   }
   EOF
   ```

3. Verifique que el fragmento es ejecutable y sintácticamente válido *antes* de regenerar:

   ```bash
   # test -x /etc/grub.d/40_custom && echo executable
   executable
   # /etc/grub.d/40_custom | grub-script-check && echo "fragment OK"
   fragment OK
   ```

4. Genere un hash PBKDF2 para un superusuario de GRUB:

   ```bash
   # grub-mkpasswd-pbkdf2
   Enter password:
   Reenter password:
   PBKDF2 hash of your password is grub.pbkdf2.sha512.10000.9B2C...F1A3.4D7E...0C88
   ```

5. Restrinja la *edición* del menú sin restringir el arranque normal — la postura correcta para un servidor, ya que la alternativa es una máquina que nadie puede arrancar de forma desatendida:

   ```bash
   # cat >> /etc/grub.d/40_custom <<'EOF'

   set superusers="gadmin"
   password_pbkdf2 gadmin grub.pbkdf2.sha512.10000.9B2C...F1A3.4D7E...0C88
   EOF
   # sed -i 's/^CLASS="/CLASS="--unrestricted /' /etc/grub.d/10_linux
   ```

6. Regenere y confirme que tanto la entrada como el superusuario llegaron a `grub.cfg`:

   ```bash
   # grub-mkconfig -o /boot/grub/grub.cfg
   # grep -E "Emergency shell|superusers|unrestricted" /boot/grub/grub.cfg
   set superusers="gadmin"
   menuentry 'Debian GNU/Linux' --class debian ... --unrestricted {
   menuentry 'Emergency shell (no init)' --class recovery {
   ```

**Verificación de comprensión**

* **Q5.1** — ¿Por qué está `exec tail -n +3 $0` al principio de `40_custom`, y qué se rompe si elimina esa línea?
* **Q5.2** — ¿Por qué el ejercicio pasó `${BUUID}` a `search` pero `${RUUID}` al `root=` del kernel? En un sistema sin partición `/boot` separada, ¿cuáles serían esos dos valores?
* **Q5.3** — `init=/bin/bash` le da un shell de root sin pedir contraseña. ¿Qué implica esto sobre el valor de una contraseña de root en una máquina cuyo menú de GRUB no está protegido, y cuál es la mitigación *por debajo* del gestor de arranque?
* **Q5.4** — Sin `--unrestricted` en las entradas normales, ¿cuál es la consecuencia operativa de `set superusers=` en un servidor desatendido?
* **Q5.5** — `/etc/grub.d/40_custom` frente a `/boot/grub/custom.cfg`: ¿cuál es la diferencia en la forma en que cada uno llega al menú de arranque?

---

## Ejercicio 6 — Instalar GRUB en un MBR con `grub-install` (seguro, loop‑back)

Esta es la destreza práctica central del objetivo. Todo ocurre dentro de un archivo.

1. Cree una imagen dispersa de 2 GiB y móntela como dispositivo de bloques con escaneo de particiones:

   ```bash
   # truncate -s 2G /var/tmp/lab-disk.img
   # LOOP=$(losetup --find --show --partscan /var/tmp/lab-disk.img)
   # echo $LOOP
   /dev/loop0
   ```

2. Escriba una etiqueta **msdos** con una partición arrancable, dejando el hueco de 1 MiB:

   ```bash
   # parted -s $LOOP mklabel msdos
   # parted -s $LOOP mkpart primary ext4 1MiB 100%
   # parted -s $LOOP set 1 boot on
   # partprobe $LOOP; lsblk $LOOP
   NAME      SIZE TYPE MOUNTPOINTS
   loop0       2G loop
   └─loop0p1   2G part
   ```

3. Cree un sistema de archivos y móntelo:

   ```bash
   # mkfs.ext4 -q -L LABDISK ${LOOP}p1
   # mkdir -p /mnt/lab && mount ${LOOP}p1 /mnt/lab
   # mkdir -p /mnt/lab/boot
   ```

4. Instale el gestor de arranque BIOS, apuntándolo al `/boot` de esta imagen y no al suyo:

   ```bash
   # grub-install --target=i386-pc --boot-directory=/mnt/lab/boot --no-floppy $LOOP
   Installing for i386-pc platform.
   Installation finished. No error reported.
   ```

   Si falla con `cannot find a device for /mnt/lab/boot`, instale `grub-pc-bin` (Debian) / `grub2-pc-modules` (Fedora) y añada `--recheck`.

5. Confirme qué se escribió **dentro del archivo** — tres lugares, no uno:

   ```bash
   # dd if=$LOOP bs=512 count=1 status=none | strings | head -4
   ZRr=
   GRUB
   Geom
   Hard Disk
   # hexdump -C -s 0x5c -n 8 $LOOP
   0000005c  01 00 00 00 00 00 00 00                           |........|
   # ls /mnt/lab/boot/grub/
   fonts  grubenv  i386-pc  locale
   # ls /mnt/lab/boot/grub/i386-pc/ | wc -l
   287
   ```

6. Observe el área de incrustación entre el MBR y la partición 1, donde ahora vive `core.img`:

   ```bash
   # dd if=$LOOP bs=512 skip=1 count=8 status=none | strings | grep -m3 .
   loading
   .
   grub_
   ```

7. Proporcione al gestor una configuración y un kernel al que encadenar, y luego verifique el árbol:

   ```bash
   # cp /boot/vmlinuz-$(uname -r) /boot/initrd.img-$(uname -r) /mnt/lab/boot/
   # cat > /mnt/lab/boot/grub/grub.cfg <<EOF
   set timeout=5
   set default=0
   menuentry 'Lab kernel' {
       search --no-floppy --fs-label --set=root LABDISK
       linux /boot/vmlinuz-$(uname -r) root=LABEL=LABDISK ro
       initrd /boot/initrd.img-$(uname -r)
   }
   EOF
   # grub-script-check /mnt/lab/boot/grub/grub.cfg && echo OK
   OK
   ```

8. (Opcional) Arranque la imagen para demostrar que funciona, y luego desmonte el laboratorio:

   ```bash
   $ qemu-system-x86_64 -m 1024 -drive file=/var/tmp/lab-disk.img,format=raw -nographic
   # umount /mnt/lab
   # losetup -d $LOOP
   ```

**Verificación de comprensión**

* **Q6.1** — A `grub-install` se le dio `$LOOP` (el dispositivo completo), no `${LOOP}p1`. ¿Qué pasaría si lo apuntara a la partición, y por qué GRUB se niega o advierte?
* **Q6.2** — ¿Qué controla exactamente `--boot-directory` y cuál es su valor por defecto? Nombre la opción más antigua a la que reemplazó.
* **Q6.3** — Nombre las tres ubicaciones distintas en las que `grub-install` escribió en esta imagen, e indique qué contiene cada una.
* **Q6.4** — ¿Por qué `grub-install` necesita aquí `--target=i386-pc` aunque su equipo anfitrión pueda ser una máquina UEFI?
* **Q6.5** — En un sistema UEFI, `grub-install` ejecuta además `efibootmgr`. ¿Qué dos opciones permiten omitir eso — una para clonar a medios extraíbles y otra para chroots donde las variables EFI no están disponibles?
* **Q6.6** — Instalar el `core.img` de GRUB en el sector de arranque de una partición (`--force` sobre una partición) está documentado como poco fiable. ¿Por qué? Dé la razón a nivel de sistema de archivos.

---

## Ejercicio 7 — Respaldar y restaurar el código de arranque y la configuración

1. Respalde el primer sector completo (código de arranque **y** tabla de particiones):

   ```bash
   # dd if=/dev/vdb of=/root/vdb-mbr-full.bin bs=512 count=1
   1+0 records in
   1+0 records out
   512 bytes copied, 0.000241 s, 2.1 MB/s
   ```

2. Respalde sólo el área de código de arranque, dejando la tabla de particiones fuera del archivo:

   ```bash
   # dd if=/dev/vdb of=/root/vdb-bootcode.bin bs=446 count=1
   1+0 records in
   1+0 records out
   446 bytes copied, 0.000187 s, 2.4 MB/s
   ```

3. Respalde también el área de incrustación — el MBR por sí solo es inútil sin `core.img`:

   ```bash
   # dd if=/dev/vdb of=/root/vdb-gap.bin bs=512 count=2048
   2048+0 records in
   2048+0 records out
   1048576 bytes (1.0 MB, 1.0 MiB) copied, 0.0041 s, 256 MB/s
   ```

4. Respalde la tabla de particiones en forma *textual* y revisable:

   ```bash
   # sfdisk --dump /dev/vdb > /root/vdb-parttable.txt
   # sgdisk --backup=/root/vda-gpt.bin /dev/vda        # GPT disks
   The operation has completed successfully.
   ```

5. Respalde las entradas de configuración (las salidas son regenerables; las entradas no):

   ```bash
   # tar czf /root/grub-config-$(date +%F).tar.gz \
       /etc/default/grub /etc/grub.d/ /boot/grub/grub.cfg
   ```

6. Simule un daño y repárelo **sólo en la imagen de laboratorio**:

   ```bash
   # dd if=/dev/zero of=$LOOP bs=446 count=1        # wipe boot code, keep table
   # dd if=$LOOP bs=512 count=1 status=none | strings | grep -c GRUB
   0
   # grub-install --target=i386-pc --boot-directory=/mnt/lab/boot $LOOP
   Installing for i386-pc platform.
   Installation finished. No error reported.
   ```

7. O restaure desde la copia byte a byte en lugar de reinstalar:

   ```bash
   # dd if=/root/vdb-bootcode.bin of=/dev/vdb bs=446 count=1 conv=notrunc
   ```

**Verificación de comprensión**

* **Q7.1** — ¿Por qué el paso 2 usa `bs=446` mientras que el paso 1 usa `bs=512`? Describa un escenario concreto en el que restaurar la copia de 512 bytes destruye datos.
* **Q7.2** — ¿Qué hace `conv=notrunc`, y qué ocurre si lo omite cuando la salida es un archivo regular en lugar de un dispositivo de bloques?
* **Q7.3** — Restauró una copia de 446 bytes del código de arranque en un disco que después fue reparticionado y reinstalado. La máquina ahora cae en `error: unknown filesystem` / `grub rescue>`. ¿Por qué falló una restauración byte a byte perfecta?
* **Q7.4** — En un disco GPT, ¿por qué un `dd` del primer sector es una copia de seguridad inadecuada, y qué dos estructuras adicionales deben capturarse?
* **Q7.5** — ¿Cuáles de estos archivos vale la pena respaldar y cuáles son regenerables: `/etc/default/grub`, `/boot/grub/grub.cfg`, `/etc/grub.d/40_custom`, `/boot/grub/i386-pc/`?

---

## Ejercicio 8 — Interactuar con el gestor de arranque en tiempo de ejecución

Haga esto en la consola de la VM. Todo aquí es transitorio: no se escribe nada en disco.

1. Reinicie y mantenga presionada **Shift** (BIOS) o pulse repetidamente **Esc** (UEFI) para forzar el menú si está oculto.

2. Resalte la entrada por defecto y pulse **`e`**. Ahora está en un editor a pantalla completa de una *copia* de la entrada.

3. Vaya a la línea que empieza por `linux`, muévase al final de línea y añada un objetivo de rescate:

   ```
   linux /vmlinuz-6.1.0-18-amd64 root=UUID=6f2c1a7e-... ro quiet systemd.unit=rescue.target
   ```

4. Pulse **Ctrl‑x** (o **F10**) para arrancar la entrada editada. Pulse **Esc** en cambio para descartar la edición y volver al menú.

5. Cuando el sistema llegue al shell de rescate, verifique dónde aterrizó y vuelva a la operación normal:

   ```bash
   # systemctl get-default
   graphical.target
   # cat /proc/cmdline
   BOOT_IMAGE=/boot/vmlinuz-6.1.0-18-amd64 root=UUID=6f2c1a7e-... ro quiet systemd.unit=rescue.target
   # systemctl isolate default.target
   ```

6. Reinicie otra vez y esta vez pulse **`c`** en el menú para acceder al intérprete de comandos de GRUB. Explore el árbol de dispositivos:

   ```
   grub> set pager=1
   grub> echo $prefix
   (hd0,gpt2)/grub
   grub> ls
   (hd0) (hd0,gpt3) (hd0,gpt2) (hd0,gpt1) (fd0)
   grub> ls (hd0,gpt2)/
   lost+found/ vmlinuz-6.1.0-18-amd64 initrd.img-6.1.0-18-amd64 grub/ config-6.1.0-18-amd64
   grub> ls -l (hd0,gpt2)
   Partition hd0,gpt2: Filesystem type ext2, UUID a1b2c3d4-..., Partition start at 2048KiB, Total size 512000KiB
   ```

7. Arranque el sistema enteramente a mano, sin ninguna entrada de menú:

   ```
   grub> set root=(hd0,gpt2)
   grub> linux /vmlinuz-6.1.0-18-amd64 root=UUID=6f2c1a7e-9b31-42d4-8f0a-1c2b3d4e5f60 ro
   grub> initrd /initrd.img-6.1.0-18-amd64
   grub> boot
   ```

8. Simule el prompt `grub rescue>` (el gestor mínimo, con casi ningún comando disponible) y recupérese de él:

   ```
   grub rescue> ls
   (hd0) (hd0,gpt1) (hd0,gpt2) (hd0,gpt3)
   grub rescue> ls (hd0,gpt2)/grub
   error: unknown filesystem.
   grub rescue> ls (hd0,gpt2)/
   grub/ vmlinuz-6.1.0-18-amd64 ...
   grub rescue> set prefix=(hd0,gpt2)/grub
   grub rescue> set root=(hd0,gpt2)
   grub rescue> insmod normal
   grub rescue> normal
   ```

   Ya está de vuelta en el menú completo — pero sólo en memoria. La corrección debe hacerse permanente desde el sistema en ejecución con `grub-install` + `grub-mkconfig`.

**Verificación de comprensión**

* **Q8.1** — ¿Son persistentes las ediciones hechas con `e`? ¿Dónde se almacenan y cuál es la consecuencia relevante para el examen?
* **Q8.2** — Distinga `grub>` de `grub rescue>`. ¿Qué causa cada uno, y por qué `insmod normal` falla en el prompt `grub>` pero es necesario en `grub rescue>`?
* **Q8.3** — En `(hd0,gpt2)`, decodifique cada componente. ¿Qué partes se indexan desde 0 y cuáles desde 1?
* **Q8.4** — Dé cuatro parámetros de kernel utilizables desde el editor de GRUB para llegar a un shell en un sistema roto, y describa qué le da cada uno.
* **Q8.5** — Añadió `init=/bin/bash` y obtuvo un shell, pero `passwd` falla con "Read-only file system". ¿Qué único comando lo soluciona?
* **Q8.6** — En el paso 7, si escribe `linux` e `initrd` pero olvida `boot`, no ocurre nada. ¿Por qué GRUB no arranca automáticamente después de `initrd`?

---

## Ejercicio 9 — Reparar un sistema que no arranca desde un medio en vivo (chroot)

El escenario: el instalador de otro sistema operativo sobrescribió el MBR, o `/boot` se restauró desde una copia de seguridad sin gestor de arranque. Usted tiene una ISO en vivo.

1. Arranque el medio en vivo e identifique las particiones:

   ```bash
   # lsblk -f
   NAME   FSTYPE FSVER LABEL UUID                                 MOUNTPOINTS
   vda
   ├─vda1 vfat   FAT32       AB12-CD34
   ├─vda2 ext4   1.0         a1b2c3d4-0000-4444-8888-aabbccddeeff
   └─vda3 ext4   1.0         6f2c1a7e-9b31-42d4-8f0a-1c2b3d4e5f60
   ```

2. Monte el sistema de archivos raíz y luego todo lo que sea un sistema de archivos separado, **en orden**:

   ```bash
   # mount /dev/vda3 /mnt
   # mount /dev/vda2 /mnt/boot           # separate /boot
   # mount /dev/vda1 /mnt/boot/efi       # UEFI only
   ```

3. Enlace (bind) los sistemas de archivos virtuales del kernel para que las herramientas dentro del chroot puedan ver el hardware real:

   ```bash
   # for d in dev dev/pts proc sys run; do mount --rbind /$d /mnt/$d; mount --make-rslave /mnt/$d; done
   # mount -t efivarfs efivarfs /mnt/sys/firmware/efi/efivars   # UEFI only, if not already rbound
   ```

4. Entre en el chroot y confirme que está dentro del sistema destino:

   ```bash
   # chroot /mnt /bin/bash
   # cat /etc/os-release | head -1
   PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
   # findmnt -no SOURCE /
   /dev/vda3
   ```

5. Reinstale el gestor de arranque para la plataforma correcta:

   ```bash
   # BIOS
   # grub-install --target=i386-pc --recheck /dev/vda
   Installing for i386-pc platform.
   Installation finished. No error reported.

   # UEFI
   # grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck
   Installing for x86_64-efi platform.
   Installation finished. No error reported.
   ```

6. Regenere el menú, verifique y salga limpiamente:

   ```bash
   # grub-mkconfig -o /boot/grub/grub.cfg
   # grub-script-check /boot/grub/grub.cfg && echo OK
   OK
   # exit
   # umount -R /mnt
   # reboot
   ```

**Verificación de comprensión**

* **Q9.1** — ¿Por qué deben montarse por bind `/dev`, `/proc` y `/sys` antes del chroot? Nombre un comando del paso 5 que falla sin cada uno de ellos.
* **Q9.2** — ¿Cuál es el propósito de `--make-rslave`, y qué sale mal en `umount -R /mnt` sin él?
* **Q9.3** — En una reparación UEFI, ¿por qué es necesario `efivarfs`, y qué opción de `grub-install` permite continuar sin él?
* **Q9.4** — Está reparando un sistema x86‑64 desde una ISO en vivo de 32 bits. ¿Qué paso falla y por qué?
* **Q9.5** — El chroot funciona y `grub-install` no reporta errores, pero la máquina sigue arrancando el otro sistema operativo. Nombre dos causas no relacionadas con GRUB en sí.
* **Q9.6** — En un sistema con Secure Boot, `grub-install` tiene éxito pero el firmware se niega a cargar el gestor. ¿Qué componente falta en la cadena, y qué comando informa del estado de Secure Boot?

---

## Ejercicio 10 — GRUB Legacy: leer `menu.lst` / `grub.conf`

GRUB Legacy (0.97) sigue en la lista de objetivos y se sigue encontrando en RHEL/CentOS 5–6 y en appliances de larga vida. Lo leerá mucho más a menudo de lo que lo instalará.

1. Localice la configuración. En sistemas Red Hat el archivo es `grub.conf` con un enlace simbólico:

   ```bash
   # ls -l /boot/grub/menu.lst /boot/grub/grub.conf /etc/grub.conf
   lrwxrwxrwx 1 root root 11 Mar  3  2019 /boot/grub/menu.lst -> ./grub.conf
   -rw------- 1 root root 852 Mar  3  2019 /boot/grub/grub.conf
   lrwxrwxrwx 1 root root 22 Mar  3  2019 /etc/grub.conf -> ../boot/grub/grub.conf
   ```

2. Léala:

   ```
   default=0
   timeout=5
   fallback=1
   splashimage=(hd0,0)/grub/splash.xpm.gz
   hiddenmenu
   password --md5 $1$Xy3Kz$8pQ2mR7vN0hL4dW1sE6tB.

   title CentOS (2.6.32-754.el6.x86_64)
       root (hd0,0)
       kernel /vmlinuz-2.6.32-754.el6.x86_64 ro root=UUID=6f2c1a7e-... rhgb quiet
       initrd /initramfs-2.6.32-754.el6.x86_64.img

   title Windows Server 2008
       rootnoverify (hd1,0)
       chainloader +1
   ```

3. Inspeccione el mapa de dispositivos, que GRUB Legacy usa para traducir los números de unidad de la BIOS a nodos de dispositivo de Linux:

   ```bash
   # cat /boot/grub/device.map
   (fd0)   /dev/fd0
   (hd0)   /dev/sda
   (hd1)   /dev/sdb
   ```

4. Liste los archivos de las etapas:

   ```bash
   # ls /boot/grub/
   device.map  e2fs_stage1_5  grub.conf  menu.lst  splash.xpm.gz  stage1  stage2
   ```

5. Instale GRUB Legacy desde su shell interactivo (el equivalente de `grub-install`):

   ```
   # grub
   grub> root (hd0,0)
    Filesystem type is ext2fs, partition type 0x83
   grub> setup (hd0)
    Checking if "/boot/grub/stage1" exists... yes
    Checking if "/boot/grub/stage2" exists... yes
    Checking if "/boot/grub/e2fs_stage1_5" exists... yes
    Running "embed /boot/grub/e2fs_stage1_5 (hd0)"...  27 sectors are embedded.
   succeeded
    Running "install /boot/grub/stage1 (hd0) (hd0)1+27 p (hd0,0)/boot/grub/stage2 /boot/grub/grub.conf"... succeeded
   Done.
   ```

6. Traduzca los nombres de dispositivo a la sintaxis de GRUB 2. Escriba el equivalente en GRUB 2 de cada línea antes de consultar las respuestas:

   | GRUB Legacy | GRUB 2 (etiqueta msdos) | GRUB 2 (etiqueta gpt) |
   |---|---|---|
   | `(hd0,0)` | ? | ? |
   | `(hd0,4)` | ? | — |
   | `(hd1,2)` | ? | ? |

**Verificación de comprensión**

* **Q10.1** — Dé el equivalente completo en GRUB 2 de `(hd0,0)`, `(hd0,4)` y `(hd1,2)`. Enuncie la regla de indexación de discos y de particiones en cada generación.
* **Q10.2** — Asocie cada directiva de GRUB Legacy con su contraparte en GRUB 2: `title`, `root`, `kernel`, `initrd`, `default`, `timeout`, `hiddenmenu`.
* **Q10.3** — ¿Qué es `stage1_5`, dónde reside y qué componente de GRUB 2 lo reemplazó?
* **Q10.4** — ¿Cuál es la diferencia entre `root` y `rootnoverify`, y por qué la entrada de Windows necesita esta última más `chainloader +1`?
* **Q10.5** — GRUB Legacy no tiene `grub-mkconfig`. ¿Cuál es la consecuencia operativa tras una actualización del paquete del kernel, y qué usó Red Hat para compensarlo?
* **Q10.6** — El archivo de Legacy tiene modo `0600`. ¿Qué está protegiendo, y cuál es la protección equivalente en GRUB 2?

---

## Ejercicio 11 — UEFI: ubicaciones de arranque alternativas y `efibootmgr`

1. Liste las entradas de arranque del firmware y el orden de arranque:

   ```bash
   # efibootmgr -v
   BootCurrent: 0001
   Timeout: 3 seconds
   BootOrder: 0001,0002,0000
   Boot0000* UiApp   FvVol(7cb8bdc9-...)/FvFile(462caa21-...)
   Boot0001* debian  HD(1,GPT,ab12cd34-...,0x800,0x100000)/File(\EFI\debian\shimx64.efi)
   Boot0002* UEFI QEMU DVD-ROM  PciRoot(0x0)/Pci(0x1,0x1)/Ata(1,0,0)
   ```

2. Inspeccione el contenido de la ESP — aquí es donde realmente ocurre "instalar un gestor de arranque" en UEFI:

   ```bash
   # find /boot/efi -maxdepth 3 -type f | sort
   /boot/efi/EFI/BOOT/BOOTX64.EFI
   /boot/efi/EFI/BOOT/fbx64.efi
   /boot/efi/EFI/debian/BOOTX64.CSV
   /boot/efi/EFI/debian/grub.cfg
   /boot/efi/EFI/debian/grubx64.efi
   /boot/efi/EFI/debian/mmx64.efi
   /boot/efi/EFI/debian/shimx64.efi
   # cat /boot/efi/EFI/debian/grub.cfg
   search.fs_uuid a1b2c3d4-0000-4444-8888-aabbccddeeff root
   set prefix=($root)'/grub'
   configfile $prefix/grub.cfg
   ```

3. Cree una **entrada de arranque de respaldo** que apunte al mismo gestor, de modo que una entrada de NVRAM corrupta no sea fatal:

   ```bash
   # efibootmgr -c -d /dev/vda -p 1 -L "debian-backup" -l '\EFI\debian\grubx64.efi'
   BootCurrent: 0001
   BootOrder: 0003,0001,0002,0000
   Boot0003* debian-backup
   ```

4. Instale en la **ruta extraíble / de reserva**, que todo firmware UEFI prueba cuando la NVRAM no tiene ninguna entrada utilizable:

   ```bash
   # grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable
   Installing for x86_64-efi platform.
   Installation finished. No error reported.
   # ls /boot/efi/EFI/BOOT/
   BOOTX64.EFI  fbx64.efi  grubx64.efi
   ```

5. Gestione el orden de arranque y los arranques de una sola vez, y luego limpie la entrada del laboratorio:

   ```bash
   # efibootmgr -o 0001,0003,0002,0000     # set persistent order
   # efibootmgr -n 0002                    # BootNext: one boot from DVD
   # efibootmgr -b 0003 -B                 # delete entry 0003
   ```

**Verificación de comprensión**

* **Q11.1** — En un sistema UEFI, ¿qué componente cumple el papel que desempeña el código de arranque del MBR en BIOS? ¿Dónde va `core.img`?
* **Q11.2** — ¿Por qué `\EFI\debian\` usa barras invertidas en `efibootmgr -l` mientras que `/boot/efi/EFI/debian/` usa barras normales?
* **Q11.3** — ¿Cuál es la importancia de `/EFI/BOOT/BOOTX64.EFI`, y en qué dos situaciones le salva `--removable`?
* **Q11.4** — Explique la cadena `shimx64.efi → grubx64.efi → vmlinuz` en una máquina con Secure Boot. ¿Para qué sirve `mmx64.efi`?
* **Q11.5** — El diminuto `grub.cfg` de la ESP contiene sólo `search`/`set prefix`/`configfile`. ¿Por qué no se almacena la configuración real en la ESP?
* **Q11.6** — `efibootmgr` falla con `EFI variables are not supported on this system`. Dé las dos causas más probables.

---

<details>
<summary><strong>Respuestas</strong> (ábralas sólo después de intentar todos los ejercicios)</summary>

### Ejercicio 1

**A1.1** — El kernel crea `/sys/firmware/efi` únicamente cuando fue arrancado a través del stub EFI o de un gestor de arranque EFI y los servicios de tiempo de ejecución EFI están disponibles. Refleja **cómo ocurrió este arranque**, no lo que soporta el hardware: una máquina con capacidad UEFI arrancada mediante CSM/modo legacy no tiene `/sys/firmware/efi`, e instalar GRUB allí requiere `--target=i386-pc`. Confíe siempre en el estado en ejecución, no en la pantalla de configuración del firmware.

**A1.2** — El comando `linux` de GRUB 2 añade `BOOT_IMAGE=` automáticamente, registrando la ruta de la imagen del kernel que cargó, expresada de forma relativa al `root` de GRUB. Es oro diagnóstico: en una máquina con varios sistemas de archivos `/boot` le dice qué archivo de imagen del kernel se ejecutó realmente, con independencia de lo que informe `uname -r`.

**A1.3** — Entonces hay dos archivos llamados `grub.cfg` — uno en la ESP, otro bajo `/boot/grub2/` — y un administrador que edita el equivocado no ve efecto alguno, o edita el correcto y este es sobrescrito por el siguiente `grub2-mkconfig`. Resuelva siempre la ruta con `readlink -f` primero, y regenere siempre en lugar de editar. (RHEL 9/Fedora unificaron esto: `/boot/grub2/grub.cfg` es el archivo real en ambos tipos de firmware, con un pequeño stub en la ESP.)

**A1.4** — No es un error del programa. El módulo `ext2` de GRUB lee ext2, ext3 y ext4; `grub-probe` nombra el módulo, no el conjunto de características en disco. El valor importa porque es lo que se escribe como `insmod ext2` dentro de `grub.cfg`.

### Ejercicio 2

**A2.1** — En un disco MBR, los sectores desde el 1 hasta el inicio de la primera partición (convencionalmente 2047, dando ~1 MiB) están sin asignar y GRUB incrusta `core.img` allí. GPT no tiene tal hueco garantizado — la tabla de particiones y sus entradas ocupan los sectores justo después del MBR protector — de modo que GRUB necesita una partición explícitamente reservada y sin formatear de tipo `EF02` en la que incrustarse. Sin ella, `grub-install` falla con `embedding is not possible, but this is required for cross-disk install`.

**A2.2** — Sólo hay 62 sectores (~31 KiB) disponibles antes del sector 63, lo cual es demasiado pequeño para un `core.img` moderno (típicamente 25–40 KiB con los módulos necesarios, más con LVM/RAID/cifrado). `grub-install` falla con:
`error: embedding is not possible, but this is required when the root device is on a RAID array or LVM volume` o `warning: your core.img is unusually large. It won't fit in the embedding area.` La solución es realinear la partición en 1 MiB, o usar un `/boot` separado sin cifrar.

**A2.3** — La firma de arranque (también llamada número mágico), en los desplazamientos `0x1FE`–`0x1FF`. La BIOS lee el sector 0 en memoria en `0x7C00` y sólo le transfiere el control si esos dos bytes son `0x55 0xAA`. Sin ellos, la BIOS trata el disco como no arrancable y pasa al siguiente dispositivo del orden de arranque.

**A2.4** — 446 bytes de código de arranque (desplazamientos 0–445), 64 bytes de tabla de particiones (446–509: cuatro entradas de 16 bytes), 2 bytes de firma (510–511). Dentro del área de código de arranque, las herramientas modernas reservan además los desplazamientos 440–443 para la firma de disco de 32 bits y 444–445 como nulos, razón por la cual parte de la documentación habla de "440 bytes de código de arranque".

**A2.5** — GRUB fue instalado para la plataforma BIOS/`i386-pc`, así que esta máquina arranca mediante CSM/legacy, no UEFI nativo. Si alguien más adelante deshabilita CSM en el firmware, la máquina no arrancará hasta que se reinstale GRUB con `--target=x86_64-efi`. El directorio de módulos es la evidencia en disco más fiable de qué plataforma está en uso.

### Ejercicio 3

**A3.1** — Las rutas de GRUB son relativas al **propio root de GRUB**, que aquí es la partición `/boot` separada — así que, desde la perspectiva de GRUB, el kernel está en `/vmlinuz-...`. Una vez que Linux monta esa partición en `/boot`, el mismo archivo está en `/boot/vmlinuz-...`. Si no hubiera una partición `/boot` separada, ambas rutas serían `/boot/vmlinuz-...`. Esta discrepancia es la causa número uno de que las entradas de menú escritas a mano fallen con `error: file not found`.

**A3.2** — Busca en todos los dispositivos que GRUB puede ver un sistema de archivos con ese UUID y asigna la primera coincidencia a la variable `root`. Es robusto porque los UUID viajan con el sistema de archivos: añadir un disco, cambiar la controladora SATA/NVMe o mover el disco a otro puerto renumera `(hd0)`/`(hd1)` pero no cambia el UUID. Un `(hd0,gpt2)` fijado a mano se rompe en el momento en que la BIOS enumera las unidades de otra forma.

**A3.3** — No, son dos raíces distintas.
* El `root` de GRUB (`set root=` / `search --set=root`) le dice a **GRUB** desde dónde cargar `vmlinuz` e `initrd` — es el sistema de archivos `/boot`.
* `root=UUID=...` en la línea `linux` es un parámetro del **kernel** que le indica qué sistema de archivos montar como `/` una vez que el initramfs cede el control.
En un sistema con `/boot` separado, estos son dos sistemas de archivos distintos con dos UUID distintos.

**A3.4** — `grub-mkconfig` ejecuta los scripts en orden de ordenación `LC_ALL=C`, así que el número controla la posición de la salida de cada fragmento dentro de `grub.cfg` — y por tanto el índice numérico de las entradas de menú. Quitar el bit de ejecución a `30_os-prober` hace que `grub-mkconfig` lo omita por completo: no se detecta ningún otro sistema operativo y las entradas de arranque dual desaparecen del menú en la siguiente regeneración. Esta es la forma soportada de desactivar un fragmento.

**A3.5** — En `/boot/grub/grubenv`, un archivo de 1024 bytes de tamaño fijo que GRUB reescribe **in situ**. GRUB debe poder escribirlo sin un controlador de sistema de archivos capaz de asignar bloques, así que requiere un mapeo de bloques estático y contiguo. Los sistemas de archivos que reubican bloques — Btrfs con COW, algunas disposiciones LVM/RAID — rompen esa premisa, razón por la cual GRUB imprime `sparse file not allowed` o `environment block too small` y por la que `GRUB_DEFAULT=saved` no es fiable sobre raíces Btrfs.

### Ejercicio 4

**A4.1** — `GRUB_CMDLINE_LINUX` se añade a **todas** las entradas generadas, incluidas las de recuperación/monousuario. `GRUB_CMDLINE_LINUX_DEFAULT` se añade sólo a las entradas normales y se omite deliberadamente de las de recuperación. Los parámetros de consola serie pertenecen a `GRUB_CMDLINE_LINUX`: en una máquina sin monitor es en modo de recuperación donde más necesita la salida por consola, que es exactamente donde `..._DEFAULT` no se aplicaría.

**A4.2** — GRUB 2.06 deshabilitó `os-prober` por defecto (Debian 12, Ubuntu 22.04+, Fedora 36+). La razón es que `os-prober` monta todos los sistemas de archivos que encuentra y ejecuta lógica de sondeo contra sistemas de archivos ajenos no confiables durante una operación privilegiada — una superficie de ataque real en anfitriones multiinquilino y de VM. Vuelva a habilitarlo con `GRUB_DISABLE_OS_PROBER=false` en `/etc/default/grub`, y luego regenere.

**A4.3** — La lógica **recordfail** de Ubuntu. `/etc/grub.d/00_header` escribe `recordfail=1` en `grubenv` antes de ceder el control al kernel, y una unidad de systemd lo borra tras un arranque exitoso. Si el arranque anterior no se completó, GRUB fija el tiempo de espera en `-1` (esperar indefinidamente) para que una persona pueda intervenir — precisamente lo incorrecto para un servidor sin monitor. `GRUB_RECORDFAIL_TIMEOUT=<seconds>` limita esa espera.

**A4.4** — `GRUB_TIMEOUT_STYLE`. Valores admitidos: `menu` (mostrar el menú durante todo el tiempo de espera), `countdown` (mostrar sólo una cuenta atrás, sin menú) y `hidden` (no mostrar nada; el tiempo de espera es un período de gracia silencioso durante el cual una pulsación de tecla revela el menú). Con `hidden` o `countdown`, `GRUB_TIMEOUT` sigue transcurriendo pero no se dibuja ningún menú.

**A4.5** — No es necesario. Los dos comandos escriben en lugares distintos y resuelven problemas distintos:
* `grub-mkconfig -o <path>` regenera la **configuración del menú** — un archivo de texto en un sistema de archivos normal.
* `grub-install` escribe los **binarios del gestor de arranque**: `boot.img` en el MBR, `core.img` en el área de incrustación o en la ESP, y el directorio de módulos bajo `/boot/grub/`.
Vuelva a ejecutar `grub-install` sólo cuando deban cambiar los propios binarios del gestor de arranque: tras una actualización del paquete GRUB, tras reemplazar o reparticionar el disco de arranque, o al añadir un disco a un espejo de arranque.

### Ejercicio 5

**A5.1** — La propia salida del script pasa a formar parte de `grub.cfg`. `exec tail -n +3 $0` reemplaza el shell por `tail`, que imprime el archivo a partir de la línea 3 — es decir, todo lo que hay tras el shebang y la propia línea `exec`. Bórrela y el script no produce salida, así que sus entradas personalizadas nunca aparecen en el menú; quítele el bit de ejecución al archivo y `grub-mkconfig` lo omite por completo.

**A5.2** — `search` localiza el sistema de archivos del que **GRUB** debe leer el kernel y el initrd — es decir, `/boot`, de ahí `BUUID`. `root=` le dice al **kernel** qué sistema de archivos montar como `/`, de ahí `RUUID`. En un sistema sin `/boot` separado, `grub-probe --target=fs_uuid /boot` y `findmnt -no UUID /` devuelven el *mismo* UUID y la distinción desaparece — razón por la cual pasa desapercibida hasta que alguien despliega una máquina con `/boot` separado.

**A5.3** — El acceso físico o por consola a un menú de GRUB desprotegido equivale a root: `init=/bin/bash` sortea todos los mecanismos de autenticación del espacio de usuario, incluidos PAM y la contraseña de root. La mitigación por debajo del gestor de arranque es el **cifrado de disco completo** (LUKS sobre `/` e idealmente también sobre `/boot`), de modo que el atacante obtiene un shell sobre texto cifrado, respaldado por contraseña de firmware + Secure Boot para impedir que arranque su propio medio. Una contraseña de GRUB por sí sola detiene el ataque casual; sólo el cifrado impide que el disco sea extraído y montado en otro lugar.

**A5.4** — Todas las entradas de menú quedan protegidas por contraseña, incluida la predeterminada, así que la máquina no puede arrancar de forma desatendida tras un corte de energía o un reinicio programado — la consola se queda para siempre en un aviso de usuario/contraseña. `--unrestricted` en las entradas normales da la postura correcta: cualquiera puede arrancar la configuración por defecto, sólo `gadmin` puede editar una entrada o usar el shell de GRUB.

**A5.5** — `/etc/grub.d/40_custom` es una **entrada** de `grub-mkconfig`: su salida se copia dentro de `grub.cfg` en el momento de la generación y sobrevive a la regeneración. `/boot/grub/custom.cfg` es leído por `grub.cfg` en **tiempo de arranque** mediante una cláusula `source`/`configfile` emitida por `41_custom`; nunca pasa por `grub-mkconfig`, así que puede cambiarse sin regenerar nada — útil en imágenes y con `/etc` de sólo lectura, pero invisible para `grub-script-check` sobre `grub.cfg` y fácil de olvidar durante las auditorías.

### Ejercicio 6

**A6.1** — Instalar en el dispositivo completo escribe `boot.img` en el MBR, que es lo que la BIOS ejecuta realmente. Apuntar `grub-install` a una partición escribe `core.img` en el sector de arranque de esa partición, algo que GRUB documenta como no soportado; se niega salvo que pase `--force`, y advierte `Attempting to install GRUB to a partition instead of the MBR. This is a BAD idea.` La BIOS no ejecutará el sector de arranque de una partición a menos que algo en el MBR lo encadene.

**A6.2** — `--boot-directory=DIR` establece dónde escribe GRUB su directorio de módulos, fuentes, localización y `grubenv` — crea `DIR/grub/`, con valor por defecto `/boot`, de ahí `/boot/grub/`. Reemplazó a la opción más antigua `--root-directory`, que tomaba el punto de montaje (`--root-directory=/mnt/lab` significaba `/mnt/lab/boot/grub`) y era ambigua cuando `/boot` era a su vez un punto de montaje.

**A6.3** — (1) El **MBR** (sector 0): `boot.img`, 446 bytes, que contiene el LBA de `core.img`. (2) El **área de incrustación** (sectores 1–2047): `core.img`, la imagen comprimida del núcleo de GRUB más exactamente los módulos necesarios para leer el sistema de archivos y el esquema de particiones de `/boot`. (3) `/mnt/lab/boot/grub/`: el directorio de módulos (`i386-pc/*.mod`), `grubenv`, fuentes y localización — todo lo que `core.img` carga después.

**A6.4** — `grub-install` toma por defecto la plataforma del sistema *en ejecución*. En un anfitrión UEFI intentaría `x86_64-efi`, buscaría una ESP y fallaría con `--efi-directory not specified` — o peor, tocaría las variables EFI reales de su anfitrión. `--target` desacopla la plataforma destino del anfitrión de construcción, que es exactamente lo que requieren la construcción de imágenes y la instalación cruzada.

**A6.5** — `--removable` (escribe en la ruta de reserva `/EFI/BOOT/BOOTX64.EFI` y no crea entrada en NVRAM — correcto para medios USB e imágenes clonadas) y `--no-nvram` (instala en el directorio del proveedor pero omite la llamada a `efibootmgr` — correcto dentro de un chroot donde `efivarfs` no está montado o es de sólo lectura).

**A6.6** — El sector de arranque de una partición contiene sólo el primer sector; `core.img` ocupa decenas de kilobytes. GRUB debe por tanto almacenar el resto en bloques que localiza mediante una **lista de bloques absoluta**, incrustada en el momento de la instalación. Cualquier operación que reubique esos bloques — una desfragmentación del sistema de archivos, una restauración con `tar`/`rsync`, la asignación diferida de ext4 moviendo el archivo, una reescritura COW de Btrfs, una reparación de fsck — invalida la lista, y la máquina falla al arrancar con `error: unknown filesystem` aunque nada haya cambiado visiblemente. El área de incrustación en un disco completo no tiene ese problema porque es espacio no asignado que ningún sistema de archivos tocará jamás.

### Ejercicio 7

**A7.1** — 446 bytes copia sólo el código de arranque; la tabla de particiones en los desplazamientos 446–509 queda intacta en el destino. Restaurar la copia de 512 bytes reescribe también la tabla de particiones. Escenario concreto: respalda el MBR, luego añade una cuarta partición y crea un sistema de archivos en ella. Semanas más tarde el código de arranque se daña y restaura el archivo de 512 bytes — la tabla de particiones vuelve a tener tres entradas y la cuarta partición, todavía llena de datos, se convierte en espacio libre invisible que la próxima operación de `parted` sobrescribirá alegremente.

**A7.2** — `conv=notrunc` le dice a `dd` que no trunque el archivo de salida tras escribir. No tiene efecto sobre un dispositivo de bloques, pero es esencial cuando la salida es un archivo regular — por ejemplo al parchear una imagen de disco — porque sin él `dd` trunca la imagen a 446 bytes y destruye todo lo que hay tras el MBR.

**A7.3** — Porque el MBR es sólo un puntero. `boot.img` contiene el LBA de `core.img` y `core.img` contiene la lista de bloques de `/boot/grub`; tras un reparticionado y una reinstalación, ni el contenido del área de incrustación ni la ubicación de `/boot` coinciden con lo que esperan los 446 bytes restaurados. Las copias de seguridad de arranque a nivel de bytes sólo son válidas frente a la disposición exacta de disco de la que fueron tomadas. La reparación correcta es `grub-install`, no `dd`.

**A7.4** — GPT mantiene una **cabecera primaria + array de entradas** en el LBA 1 y siguientes, y una **cabecera de respaldo + array de entradas** en los últimos sectores del disco; el primer sector es sólo un MBR protector que existe para impedir que las herramientas que sólo entienden MBR arrasen el disco. Capturar el sector 0 no preserva nada de la tabla real. Use `sgdisk --backup=file /dev/sdX` (o `sfdisk --dump`) para capturar ambas copias más el GUID del disco.

**A7.5** —
* `/etc/default/grub` — **respaldar**: entrada mantenida a mano, no reproducible.
* `/etc/grub.d/40_custom` — **respaldar**: entrada mantenida a mano.
* `/boot/grub/grub.cfg` — **regenerable** a partir de los dos anteriores con `grub-mkconfig`; guarde una copia de todos modos como referencia de diff para demostrar qué cambió.
* `/boot/grub/i386-pc/` — **regenerable**: `grub-install` lo reinstala desde `/usr/lib/grub/i386-pc/`.

### Ejercicio 8

**A8.1** — No son persistentes. El texto editado vive únicamente en la memoria de GRUB para ese único arranque; no se escribe nada en disco, y el siguiente arranque usa el `grub.cfg` sin modificar. Esta es la razón por la que la tecla `e` es a la vez segura (no puede inutilizar el sistema con ella) e insuficiente (una corrección que necesite en cada arranque debe ir a `/etc/default/grub` + `grub-mkconfig`).

**A8.2** —
* `grub>` — el shell **normal**. `core.img` encontró su prefijo, cargó `normal.mod` y el resto del directorio de módulos, pero no había un `grub.cfg` utilizable (ausente, vacío o con un error de sintaxis). El conjunto completo de comandos está disponible, así que `insmod normal` es redundante — `normal` ya está cargado.
* `grub rescue>` — el shell de **rescate** integrado en `core.img`. GRUB no pudo encontrar `$prefix`/`/boot/grub` en absoluto: partición equivocada, sistema de archivos movido, directorio borrado, o un tipo de sistema de archivos que sus módulos incrustados no pueden leer. Sólo existe un puñado de comandos integrados (`ls`, `set`, `unset`, `insmod`, `boot`). Debe fijar `prefix` correctamente, luego `insmod normal` para cargar el módulo desde disco, y después `normal` para entrar al shell completo.

**A8.3** — `hd0` = primer disco duro tal como lo enumera GRUB, **indexado desde 0** (`fd0` para disqueteras, `cd0` para unidades ópticas). `gpt2` = segunda partición, **indexada desde 1**, con el tipo de tabla de particiones explicitado (`gpt` o `msdos`). Así que en GRUB 2 los discos se cuentan desde 0 y las particiones desde 1. GRUB Legacy contaba **ambos** desde 0, que es la trampa clásica del examen.

**A8.4** —
* `systemd.unit=rescue.target` — equivalente a monousuario: sistemas de archivos locales montados, sin red, shell de root tras autenticarse.
* `systemd.unit=emergency.target` — mínimo: `/` montado de sólo lectura, casi nada iniciado. Úselo cuando el propio `rescue.target` falla.
* `init=/bin/bash` — reemplaza el PID 1 por completo; sin systemd, sin servicios, sin autenticación, `/` de sólo lectura.
* `rd.break` — específico de dracut (Red Hat/Fedora/SUSE): se detiene en el initramfs *antes* de `switch_root`, con la raíz real en `/sysroot`. Es el único que funciona cuando el problema es el propio sistema de archivos raíz o el reetiquetado de SELinux.
* También útiles: `single`, `s` o `1` (systemd los mapea a `rescue.target`), `enforcing=0` (SELinux en modo permisivo), `nomodeset` (fallos gráficos de pantalla en negro).

**A8.5** — `mount -o remount,rw /`. Con `init=/bin/bash` no hay sistema de init que remonte el sistema de archivos raíz en lectura‑escritura, así que se queda tal como lo montó el kernel — de sólo lectura, según el `ro` de la línea de comandos del kernel. Todo lo que escribe (`passwd`, `vipw`, las actualizaciones de metadatos de `fsck`) falla hasta que lo remonte.

**A8.6** — `linux` e `initrd` sólo *cargan* imágenes en memoria y registran sus parámetros; `boot` es el comando que realmente transfiere el control. La separación es deliberada — le permite cargar, inspeccionar, ajustar variables, cargar un segundo initrd, o cambiar de opinión y pulsar Esc. La misma regla se aplica dentro de un bloque `menuentry`, donde GRUB suministra un `boot` implícito al final del bloque.

### Ejercicio 9

**A9.1** —
* `/dev` — `grub-install` debe abrir el dispositivo de bloques real (`/dev/vda`) para escribir el MBR, y `grub-probe` debe hacer stat sobre los nodos de dispositivo para mapear sistemas de archivos a unidades. Sin él: `cannot find a device for /boot (is /dev mounted?)`.
* `/proc` — `grub-probe` y `os-prober` leen `/proc/self/mountinfo` y `/proc/devices` para resolver puntos de montaje y objetivos de device‑mapper. Sin él: `failed to get canonical path` o un `root=` incorrecto.
* `/sys` — GRUB lee `/sys/block/*` para conocer la topología de dispositivos (desplazamientos de particiones, miembros MD/LVM) y, en UEFI, `efibootmgr` lee `/sys/firmware/efi/efivars`.

**A9.2** — `--rbind` enlaza recursivamente un montaje y todos sus submontajes; `--make-rslave` fija la propagación de modo que los eventos de montaje y desmontaje viajen *desde* el anfitrión *hacia* el chroot pero no en sentido inverso. Sin él, los montajes del chroot comparten un grupo de pares con los del anfitrión, y `umount -R /mnt` se propaga hacia afuera — desmontando el propio `/dev`, `/proc` o `/sys` del sistema en vivo y dejando inutilizable el entorno de rescate.

**A9.3** — `efibootmgr` lee y escribe las variables de arranque de la NVRAM UEFI (`BootOrder`, `Boot####`) exclusivamente a través del sistema de archivos `efivarfs` en `/sys/firmware/efi/efivars`; `grub-install` lo invoca para registrar el nuevo gestor. Sin efivarfs falla con `EFI variables are not supported on this system`. Pase `--no-nvram` para instalar los binarios y omitir la actualización de la NVRAM, o `--removable` para instalar en la ruta de reserva, que no necesita entrada alguna en la NVRAM.

**A9.4** — El propio `chroot` falla, o falla cada binario dentro de él, con `Exec format error`: un kernel de 32 bits no puede ejecutar el `/bin/bash` de 64 bits del sistema destino. La arquitectura del chroot debe ser ejecutable por el kernel en ejecución. Una ISO en vivo de 64 bits puede hacer chroot en un sistema de 32 bits (con las bibliotecas multilib adecuadas presentes en el destino), pero nunca al revés.

**A9.5** — (1) **Orden de arranque del firmware**: en UEFI, el `BootOrder` de la NVRAM sigue listando primero el otro sistema operativo — corríjalo con `efibootmgr -o`. En BIOS, el firmware está arrancando un disco físico distinto de aquel en el que usted instaló. (2) **Disco equivocado**: instaló en `/dev/vda` mientras el firmware arranca `/dev/vdb`; dentro de un chroot los nombres de dispositivo pueden no coincidir con lo que enumera el firmware. También es posible: la máquina arranca por UEFI mientras que usted instaló `i386-pc`, así que nunca se llega al nuevo gestor.

**A9.6** — **shim** (`shimx64.efi`), el gestor de primera etapa firmado por Microsoft que valida y carga `grubx64.efi`. `grub-install` instala GRUB pero no proporciona shim; necesita el paquete `shim-signed` de la distribución y una entrada de NVRAM que apunte a `\EFI\<vendor>\shimx64.efi`, no directamente a `grubx64.efi`. Compruebe el estado de Secure Boot con `mokutil --sb-state` (o `bootctl status`, que además informa de la cadena del gestor).

### Ejercicio 10

**A10.1** —

| GRUB Legacy | GRUB 2 (msdos) | GRUB 2 (gpt) |
|---|---|---|
| `(hd0,0)` | `(hd0,msdos1)` | `(hd0,gpt1)` |
| `(hd0,4)` | `(hd0,msdos5)` — primera partición lógica | — (GPT no tiene particiones extendidas/lógicas) |
| `(hd1,2)` | `(hd1,msdos3)` | `(hd1,gpt3)` |

Regla: **GRUB Legacy cuenta discos y particiones desde 0.** **GRUB 2 cuenta los discos desde 0 pero las particiones desde 1**, y antepone al número de partición el tipo de tabla. GRUB 2 también acepta el escueto `(hd0,1)`, tratándolo como `msdos1`.

**A10.2** —

| GRUB Legacy | GRUB 2 |
|---|---|
| `title X` | `menuentry 'X' { ... }` |
| `root (hd0,0)` | `set root=(hd0,msdos1)` — o, preferiblemente, `search --fs-uuid --set=root <uuid>` |
| `kernel /vmlinuz ...` | `linux /vmlinuz ...` (`linux16` para el protocolo de arranque de 16 bits heredado) |
| `initrd /initrd.img` | `initrd /initrd.img` (sin cambios; `initrd16` para la variante de 16 bits) |
| `default=0` | `set default=0` — desde `GRUB_DEFAULT` |
| `timeout=5` | `set timeout=5` — desde `GRUB_TIMEOUT` |
| `hiddenmenu` | `set timeout_style=hidden` — desde `GRUB_TIMEOUT_STYLE` |

**A10.3** — `stage1_5` es un pequeño controlador específico de sistema de archivos (`e2fs_stage1_5`, `reiserfs_stage1_5`, `xfs_stage1_5`, …) incrustado en el hueco del MBR. Existe porque `stage1` cabe en 446 bytes — suficiente para cargar una lista de bloques fija, no para entender un sistema de archivos — de modo que `stage1_5` aporta el conocimiento mínimo del sistema de archivos para localizar `/boot/grub/stage2` **por ruta** en lugar de por lista de bloques. GRUB 2 reemplazó toda la división `stage1_5`/`stage2` por un único `core.img` ensamblado en el momento de la instalación con exactamente los módulos que ese sistema necesita, razón por la cual GRUB 2 tiene un solo artefacto de incrustación en lugar de un zoológico por sistema de archivos.

**A10.4** — `root` fija el dispositivo *y además* monta/verifica el sistema de archivos, imprimiendo su tipo — GRUB Legacy debe leer kernels de Linux desde él. `rootnoverify` fija el dispositivo sin intentar leer un sistema de archivos, lo cual es necesario para sistemas de archivos que GRUB no entiende (NTFS en compilaciones antiguas) y para el encadenamiento en general. `chainloader +1` carga el primer sector de esa partición (`+1` es una lista de bloques que significa "1 bloque a partir del bloque 0") y salta a él, cediendo el control al gestor de arranque propio del otro sistema operativo. GRUB 2 fusionó ambos: `set root=` nunca verifica, y `chainloader +1` no ha cambiado.

**A10.5** — Nada regenera el menú, así que un paquete de kernel nuevo debe editar `menu.lst` por sí mismo — y si esa edición es incorrecta o se omite, el sistema arranca el kernel antiguo o nada en absoluto. Red Hat lo compensó con `/sbin/new-kernel-pkg` (llamado desde el scriptlet `%post` del RPM del kernel), más `grubby`, una herramienta de línea de comandos que parchea las configuraciones del gestor de arranque in situ (`grubby --default-kernel`, `grubby --update-kernel=ALL --args=...`). `grubby` sobrevive hoy en RHEL/Fedora como la forma soportada de modificar entradas sin regenerar.

**A10.6** — La línea del hash `password --md5`. El modo `0600` impide que usuarios locales sin privilegios lean el hash y lo ataquen sin conexión. El equivalente en GRUB 2 es que `grub.cfg` en sistemas Red Hat queda igualmente restringido cuando se usa `GRUB_PASSWORD` y, más importante, que GRUB 2 usa `password_pbkdf2` con un hash PBKDF2‑SHA512 con sal en lugar de MD5 sin sal — de modo que la exposición del hash es mucho menos dañina de inmediato. La mejor práctica es mantener la credencial en `/etc/grub.d/01_users` (modo `0700`) en lugar de en el archivo generado legible por todos.

### Ejercicio 11

**A11.1** — Ninguno — la cadena es más corta. El firmware UEFI entiende FAT32 y lee una **aplicación EFI** ejecutable directamente desde la partición del sistema EFI, así que no hay etapa de 446 bytes ni área de incrustación. `core.img` se escribe como un archivo PE/COFF, `grubx64.efi`, dentro de `/boot/efi/EFI/<vendor>/` en la ESP, con los módulos que necesita o bien integrados o bien junto a él en `/boot/grub/x86_64-efi/`. Por eso la reparación de arranque UEFI es una copia de archivos más una entrada de NVRAM, mientras que la reparación de arranque BIOS es una escritura de sectores en crudo.

**A11.2** — La especificación UEFI define las rutas de dispositivo usando la convención FAT/DOS, con la barra invertida como separador de rutas, y `efibootmgr` escribe la ruta tal cual en la variable de NVRAM. `/boot/efi/EFI/debian/` es el **punto de montaje** en Linux de ese mismo sistema de archivos FAT, así que sigue las convenciones POSIX. El mismo archivo, dos espacios de nombres. Entrecomille la ruta con barras invertidas en el shell (`'\EFI\debian\grubx64.efi'`) o será alterada por el procesamiento de barras invertidas.

**A11.3** — Es la **ruta de reserva / de medios extraíbles** definida por la especificación UEFI: cuando el firmware no encuentra ninguna entrada `Boot####` válida, o está arrancando un medio extraíble, busca `\EFI\BOOT\BOOTX64.EFI` en la ESP de cada dispositivo. `--removable` le salva (1) cuando la NVRAM ha sido borrada o corrompida — un reinicio de la CMOS, una actualización de firmware, un cambio de placa base — y (2) cuando produce una imagen o una memoria USB que debe arrancar en una máquina cuya NVRAM nunca ha oído hablar de ella. El coste: ninguna entrada específica del proveedor, y un segundo sistema operativo que instale en la misma ruta de reserva la sobrescribirá.

**A11.4** — El firmware verifica `shimx64.efi` contra un certificado firmado por Microsoft presente en su db. Shim verifica entonces `grubx64.efi` contra el certificado propio incrustado de la distribución — esto es lo que permite a una distro publicar actualizaciones sin que Microsoft vuelva a firmar cada compilación. GRUB, a su vez, verifica la firma del kernel antes de llamar a `linux`, y el kernel impone las firmas de módulos y el lockdown. `mmx64.efi` es **MokManager**: la interfaz que se invoca en el arranque para inscribir Machine Owner Keys, de modo que un sitio pueda firmar su propio kernel o módulos fuera del árbol (NVIDIA, VirtualBox, compilaciones DKMS) y que shim confíe en ellos.

**A11.5** — Porque la ESP es FAT32, que no tiene propiedad, permisos, enlaces simbólicos ni journaling, y se comparte con otros sistemas operativos que pueden reescribirla o reformatearla. Mantener allí sólo un localizador de tres líneas — `search` por el UUID de `/boot`, `set prefix`, `configfile` — significa que el `grub.cfg` real, el directorio de módulos, `grubenv` y los kernels viven todos en un sistema de archivos Linux propiamente dicho, y que `grub-mkconfig` nunca tiene que tocar la ESP. También significa que el mismo binario de GRUB sigue funcionando después de que `/boot` se mueva a otro disco.

**A11.6** — (1) El sistema arrancó en **modo BIOS/CSM**, así que no existen servicios de tiempo de ejecución EFI en absoluto — verifíquelo con `[ -d /sys/firmware/efi ]`. (2) **`efivarfs` no está montado**, típicamente dentro de un chroot o de un entorno de rescate mínimo — corríjalo con `mount -t efivarfs efivarfs /sys/firmware/efi/efivars`. Una tercera causa, más rara: el kernel se arrancó con `noefi` o `efi=noruntime`, o el firmware expone las variables en sólo lectura.

</details>

---

## Referencias

* LPI — Objetivos del examen 101‑500 (v5.0), Tema 102.2: https://www.lpi.org/our-certifications/exam-101-objectives/
* Manual de GNU GRUB 2.x — Instalación, configuración, intérprete de comandos, red/rescate: https://www.gnu.org/software/grub/manual/grub/grub.html
* Manual de GNU GRUB — invocación de `grub-install`: https://www.gnu.org/software/grub/manual/grub/grub.html#Invoking-grub_002dinstall
* Manual de GNU GRUB Legacy (0.97) — `menu.lst`, `setup`, archivos de etapas: https://www.gnu.org/software/grub/manual/legacy/grub.html
* El kernel de Linux — Parámetros de la línea de comandos del kernel: https://docs.kernel.org/admin-guide/kernel-parameters.html
* systemd — `bootup(7)`, proceso de arranque y targets: https://www.freedesktop.org/software/systemd/man/latest/bootup.html
* systemd — `systemd(1)`, opciones de la línea de comandos del kernel (`systemd.unit=`): https://www.freedesktop.org/software/systemd/man/latest/systemd.html
* UEFI Forum — Especificación UEFI (gestor de arranque, rutas de dispositivo, ruta de reserva): https://uefi.org/specifications
* util-linux — `fdisk(8)`, `lsblk(8)`, `sfdisk(8)`: https://github.com/util-linux/util-linux/blob/master/Documentation/
* GNU coreutils — invocación de `dd`: https://www.gnu.org/software/coreutils/manual/html_node/dd-invocation.html
* rhboot/efibootmgr — uso y opciones: https://github.com/rhboot/efibootmgr
* rhboot/shim — cadena de Secure Boot y MokManager: https://github.com/rhboot/shim