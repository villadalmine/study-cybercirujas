# LPIC-1 · 104.3 — Control mounting and unmounting of filesystems
## Ejercicios guiados (Examen 101-500, peso 4)

> **Alcance de este lab.** Montaje/desmontaje manual, opciones de montaje y su semántica en el kernel, `/etc/fstab`, identificación por `UUID`/`LABEL`/`PARTUUID`, medios extraíbles montables por usuarios, diagnóstico de sistemas de archivos ocupados, y units systemd `.mount` / `.automount`.
>
> **Requisitos previos.** Una VM Linux (o una máquina descartable) con acceso root, `util-linux ≥ 2.30`, `e2fsprogs`, `dosfstools`, `lsof` y `psmisc`. **No ejecutes esto en una máquina que te importe** — el Ejercicio 9 rompe `/etc/fstab` a propósito. Todo está construido sobre dispositivos loop respaldados por archivos regulares, así que no se toca ningún disco real.
>
> Las salidas mostradas son representativas (sistemas del tipo Debian 12 / RHEL 9); los UUID y los nombres de dispositivo van a diferir en tu máquina — siempre releé los tuyos en lugar de copiar los que se imprimen acá.

---

## Ejercicio 1 — Leé la tabla de montaje antes de cambiarla

El kernel, no `/etc/fstab`, es la autoridad sobre lo que está montado en este momento.

1. Listá los sistemas de archivos montados como un árbol:

   ```bash
   findmnt
   ```

   ```
   TARGET                    SOURCE     FSTYPE     OPTIONS
   /                         /dev/vda2  ext4       rw,relatime,errors=remount-ro
   ├─/sys                    sysfs      sysfs      rw,nosuid,nodev,noexec,relatime
   │ ├─/sys/fs/cgroup        cgroup2    cgroup2    rw,nosuid,nodev,noexec,relatime,nsdelegate
   │ └─/sys/kernel/security  securityfs securityfs rw,nosuid,nodev,noexec,relatime
   ├─/proc                   proc       proc       rw,nosuid,nodev,noexec,relatime
   ├─/dev                    udev       devtmpfs   rw,nosuid,relatime,size=1980404k,...
   │ └─/dev/pts              devpts     devpts     rw,nosuid,noexec,relatime,gid=5,mode=620
   ├─/run                    tmpfs      tmpfs      rw,nosuid,nodev,noexec,relatime,size=402412k
   └─/boot/efi               /dev/vda1  vfat       rw,relatime,fmask=0077,dmask=0077,...
   ```

2. Hacele la misma pregunta directamente al kernel, y compará con el archivo heredado:

   ```bash
   cat /proc/mounts | head -5
   ls -l /etc/mtab
   ```

   ```
   /dev/vda2 / ext4 rw,relatime,errors=remount-ro 0 0
   sysfs /sys sysfs rw,nosuid,nodev,noexec,relatime 0 0
   proc /proc proc rw,nosuid,nodev,noexec,relatime 0 0
   udev /dev devtmpfs rw,nosuid,relatime,size=1980404k,nr_inodes=495101,mode=755 0 0
   devpts /dev/pts devpts rw,nosuid,noexec,relatime,gid=5,mode=620,ptmxmode=000 0 0

   lrwxrwxrwx 1 root root 19 Aug 26 09:14 /etc/mtab -> ../proc/self/mounts
   ```

3. Mirá la vista más rica, por montaje, que expone el VFS:

   ```bash
   grep ' / ' /proc/self/mountinfo
   ```

   ```
   26 1 254:2 / / rw,relatime shared:1 - ext4 /dev/vda2 rw,errors=remount-ro
   ```

   Todo lo que está **antes** del separador ` - ` es por montaje (mount ID, parent ID, subárbol de origen, punto de montaje, flags del VFS, propagación); todo lo que está **después** es tipo de sistema de archivos, origen y opciones **por superblock**.

4. Filtrá sin usar grep, con la interfaz de consulta de `findmnt`:

   ```bash
   findmnt --types ext4 --output TARGET,SOURCE,UUID,OPTIONS --noheadings
   findmnt --mountpoint /boot/efi --json
   ```

5. Mostrá qué dispositivos de bloque existen y cuáles llevan un sistema de archivos:

   ```bash
   lsblk -f
   ```

   ```
   NAME   FSTYPE FSVER LABEL UUID                                 FSAVAIL FSUSE% MOUNTPOINTS
   vda
   ├─vda1 vfat   FAT32 EFI   9C1E-3F2A                             505.9M     1% /boot/efi
   └─vda2 ext4   1.0   root  6f8a5c3e-4b21-4c9a-9f0e-2b7d1a5c8e33   18.2G    22% /
   ```

**Comprobá lo que entendiste**

- **Q1.1** — `/etc/mtab` es un symlink a `/proc/self/mounts`. ¿Qué problema operativo resolvió ese symlink, y qué información se *pierde* comparado con el viejo archivo `/etc/mtab` escribible?
- **Q1.2** — En la línea de `mountinfo` de arriba, `nosuid` aparecería antes del ` - ` mientras que `errors=remount-ro` aparece después. ¿Por qué importa esa distinción cuando el *mismo dispositivo de bloque* está montado dos veces en dos rutas distintas?
- **Q1.3** — Tanto `findmnt` como `mount` (sin argumentos) listan montajes. ¿Cuál es seguro de parsear en un script, y por qué?

---

## Ejercicio 2 — Construí un sistema de archivos descartable sobre un dispositivo loop

2. Creá un archivo de respaldo sparse de 256 MiB y confirmá que casi no consume espacio todavía:

   ```bash
   sudo -i
   truncate -s 256M /root/lab-ext4.img
   ls -lh /root/lab-ext4.img
   du -h  /root/lab-ext4.img
   ```

   ```
   -rw-r--r-- 1 root root 256M Aug 26 09:20 /root/lab-ext4.img
   0	/root/lab-ext4.img
   ```

2. Asociálo a un dispositivo loop libre y anotá el nombre que se imprime:

   ```bash
   losetup --find --show /root/lab-ext4.img
   ```

   ```
   /dev/loop0
   ```

3. Inspeccioná la asociación:

   ```bash
   losetup -a
   lsblk /dev/loop0
   ```

   ```
   /dev/loop0: [2049]:1049234 (/root/lab-ext4.img)
   NAME   MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
   loop0    7:0    0  256M  0 loop
   ```

4. Creá un sistema de archivos ext4 con una etiqueta:

   ```bash
   mkfs.ext4 -L LABDATA /dev/loop0
   ```

   ```
   mke2fs 1.47.0 (5-Feb-2023)
   Discarding device blocks: done
   Creating filesystem with 262144 1k blocks and 65536 inodes
   Filesystem UUID: 8f0c6b1a-2d47-4a9e-9c53-1b7e4d0a6f92
   Superblock backups stored on blocks:
   	8193, 24577, 40961, 57345, 73729, 204801, 221185

   Allocating group tables: done
   Writing inode tables: done
   Creating journal (8192 blocks): done
   Writing superblocks and filesystem accounting information: done
   ```

5. Creá una segunda imagen, formateada como `vfat`, que más adelante va a hacer el papel de un pendrive USB:

   ```bash
   truncate -s 128M /root/lab-usb.img
   losetup --find --show /root/lab-usb.img
   mkfs.vfat -n LABUSB /dev/loop1
   ```

   ```
   /dev/loop1
   mkfs.fat 4.2 (2021-01-31)
   ```

6. Creá los puntos de montaje:

   ```bash
   mkdir -p /mnt/lab /mnt/usb
   ```

**Comprobá lo que entendiste**

- **Q2.1** — ¿Por qué `du` reporta `0` mientras `ls -lh` reporta `256M`? ¿Qué riesgo introduce eso si la imagen vive en un sistema de archivos casi lleno?
- **Q2.2** — Podrías haberte salteado `losetup` por completo y ejecutar `mount -o loop /root/lab-ext4.img /mnt/lab`. ¿Qué hace `mount` detrás de escena en ese caso, y qué pasa con el dispositivo loop al hacer `umount`?
- **Q2.3** — `mkfs.ext4 /root/lab-ext4.img` (sobre el archivo, no sobre `/dev/loop0`) pregunta `is not a block special device. Proceed anyway? (y,N)`. ¿Esa pregunta te protege de algo real?

---

## Ejercicio 3 — Montá a mano, y probá qué hacen realmente las opciones

1. Montá la imagen ext4 en lectura-escritura con las opciones por defecto y verificá el resultado:

   ```bash
   mount -t ext4 /dev/loop0 /mnt/lab
   findmnt /mnt/lab
   ```

   ```
   TARGET   SOURCE     FSTYPE OPTIONS
   /mnt/lab /dev/loop0 ext4   rw,relatime
   ```

2. Escribí algo, y después pasá el montaje a solo lectura **sin desmontar**:

   ```bash
   echo "production data" > /mnt/lab/notes.txt
   mount -o remount,ro /mnt/lab
   findmnt -no OPTIONS /mnt/lab
   echo "more" >> /mnt/lab/notes.txt
   ```

   ```
   ro,relatime
   -bash: /mnt/lab/notes.txt: Read-only file system
   ```

3. Volvé a lectura-escritura y demostrá `noexec`:

   ```bash
   mount -o remount,rw /mnt/lab
   printf '#!/bin/sh\necho "I ran"\n' > /mnt/lab/hello.sh
   chmod +x /mnt/lab/hello.sh
   /mnt/lab/hello.sh                 # works
   mount -o remount,noexec /mnt/lab
   /mnt/lab/hello.sh                 # now blocked
   sh /mnt/lab/hello.sh              # and this?
   ```

   ```
   I ran
   -bash: /mnt/lab/hello.sh: Permission denied
   I ran
   ```

4. Demostrá `nosuid` con un binario setuid real:

   ```bash
   cp /usr/bin/id /mnt/lab/id-suid
   chown root:root /mnt/lab/id-suid
   chmod 4755 /mnt/lab/id-suid
   mount -o remount,exec,suid /mnt/lab
   su - nobody -s /bin/sh -c '/mnt/lab/id-suid'
   mount -o remount,nosuid /mnt/lab
   su - nobody -s /bin/sh -c '/mnt/lab/id-suid'
   ```

   ```
   uid=65534(nobody) gid=65534(nogroup) euid=0(root) groups=65534(nogroup)
   uid=65534(nobody) gid=65534(nogroup) groups=65534(nogroup)
   ```

5. Compará las dos categorías de opciones en `mountinfo`:

   ```bash
   mount -o remount,nosuid,nodev,noexec /mnt/lab
   grep /mnt/lab /proc/self/mountinfo
   ```

   ```
   112 26 7:0 / /mnt/lab rw,nosuid,nodev,noexec,relatime shared:74 - ext4 /dev/loop0 rw
   ```

6. Montá el *mismo* sistema de archivos una segunda vez, en solo lectura, en otro lado:

   ```bash
   mkdir -p /mnt/lab-ro
   mount -o ro /dev/loop0 /mnt/lab-ro
   findmnt --source /dev/loop0
   ```

   ```
   TARGET      SOURCE     FSTYPE OPTIONS
   /mnt/lab    /dev/loop0 ext4   rw,nosuid,nodev,noexec,relatime
   /mnt/lab-ro /dev/loop0 ext4   ro,relatime
   ```

7. Hacé un bind-mount de un subárbol — no hay ningún sistema de archivos nuevo involucrado:

   ```bash
   mkdir -p /mnt/lab/sub /srv/exported
   mount --bind /mnt/lab/sub /srv/exported
   findmnt /srv/exported
   mount -o remount,bind,ro /srv/exported     # note: bind + remount, in that order
   findmnt -no OPTIONS /srv/exported
   ```

   ```
   TARGET       SOURCE               FSTYPE OPTIONS
   /srv/exported /dev/loop0[/sub]    ext4   rw,nosuid,nodev,noexec,relatime
   ro,nosuid,nodev,noexec,relatime
   ```

8. Deshacé los montajes extra:

   ```bash
   umount /srv/exported /mnt/lab-ro
   ```

**Comprobá lo que entendiste**

- **Q3.1** — En el paso 3, `/mnt/lab/hello.sh` fue denegado pero `sh /mnt/lab/hello.sh` igual se ejecutó. Explicá con precisión por qué, y qué significa eso para `noexec` como control de seguridad.
- **Q3.2** — En el paso 6, un montaje es `rw` y el otro `ro` sobre el mismo dispositivo. ¿Cuáles de `ro`, `nosuid`, `relatime`, `errors=remount-ro` pueden genuinamente diferir entre los dos, y cuáles no?
- **Q3.3** — ¿Por qué `mount -o remount,ro /srv/exported` (sin `bind`) no hace lo que querés sobre un bind mount?
- **Q3.4** — `mount -o remount,ro /` tiene éxito sobre un sistema de archivos raíz ocupado, pero `mount -o remount,ro /home` puede fallar con `device is busy`. ¿Cuál es la diferencia?

---

## Ejercicio 4 — Identificá sistemas de archivos: UUID, LABEL, PARTUUID

1. Leé los identificadores desde los superblocks:

   ```bash
   blkid /dev/loop0 /dev/loop1
   ```

   ```
   /dev/loop0: LABEL="LABDATA" UUID="8f0c6b1a-2d47-4a9e-9c53-1b7e4d0a6f92" BLOCK_SIZE="1024" TYPE="ext4"
   /dev/loop1: SEC_TYPE="msdos" LABEL_FATBOOT="LABUSB" LABEL="LABUSB" UUID="A1B2-C3D4" TYPE="vfat"
   ```

2. Montá por `UUID=` y por `LABEL=` en lugar de por nodo de dispositivo:

   ```bash
   umount /mnt/lab
   mount UUID=8f0c6b1a-2d47-4a9e-9c53-1b7e4d0a6f92 /mnt/lab
   findmnt -no SOURCE /mnt/lab
   umount /mnt/lab
   mount LABEL=LABDATA /mnt/lab
   findmnt -no SOURCE /mnt/lab
   ```

   ```
   /dev/loop0
   /dev/loop0
   ```

3. Mirá cómo ocurre realmente la resolución — granjas de symlinks mantenidas por udev:

   ```bash
   ls -l /dev/disk/by-uuid/ | grep -i 8f0c6b1a
   ls -l /dev/disk/by-label/
   ls /dev/disk/
   ```

   ```
   lrwxrwxrwx 1 root root 11 Aug 26 09:31 8f0c6b1a-2d47-4a9e-9c53-1b7e4d0a6f92 -> ../../loop0
   lrwxrwxrwx 1 root root 11 Aug 26 09:31 LABDATA -> ../../loop0
   lrwxrwxrwx 1 root root 10 Aug 26 09:14 EFI -> ../../vda1
   by-diskseq  by-id  by-label  by-partuuid  by-path  by-uuid
   ```

4. Cambiá la etiqueta en caliente, y cambiá el UUID:

   ```bash
   e2label /dev/loop0 LABDATA2         # equivalent to: tune2fs -L LABDATA2 /dev/loop0
   blkid -o value -s LABEL /dev/loop0
   umount /mnt/lab
   tune2fs -U random /dev/loop0
   blkid -o value -s UUID /dev/loop0
   ```

   ```
   LABDATA2
   tune2fs 1.47.0 (5-Feb-2023)
   d34c7b95-1e6a-4f02-b8c9-77a1e5b0c246
   ```

5. Vaciá la caché y volvé a leer, así aprendés el modo de falla de los datos obsoletos:

   ```bash
   blkid -c /dev/null /dev/loop0
   udevadm settle
   ls -l /dev/disk/by-label/
   ```

6. Compará los identificadores de sistema de archivos con los identificadores de *partición* en el disco real:

   ```bash
   blkid /dev/vda1
   lsblk -o NAME,FSTYPE,LABEL,UUID,PARTUUID,PARTLABEL /dev/vda
   ```

   ```
   /dev/vda1: LABEL="EFI" UUID="9C1E-3F2A" BLOCK_SIZE="512" TYPE="vfat" PARTUUID="a3f1c2d1-01"
   NAME   FSTYPE LABEL UUID                                 PARTUUID     PARTLABEL
   vda
   ├─vda1 vfat   EFI   9C1E-3F2A                            a3f1c2d1-01
   └─vda2 ext4   root  6f8a5c3e-4b21-4c9a-9f0e-2b7d1a5c8e33 a3f1c2d1-02
   ```

**Comprobá lo que entendiste**

- **Q4.1** — `/dev/sdb1` el lunes puede ser `/dev/sdc1` el martes. Nombrá los dos mecanismos que causan eso, y explicá por qué `UUID=` en `/etc/fstab` es la mitigación estándar.
- **Q4.2** — `LABEL=` es más legible que `UUID=`. Dá un escenario concreto donde montar por etiqueta arranque el sistema de archivos *equivocado* mientras que montar por UUID no lo haría.
- **Q4.3** — ¿Cuál es la diferencia práctica entre `UUID=`, `PARTUUID=` y `PARTLABEL=`? ¿Cuál sobrevive a un `mkfs`, y cuál sobrevive a un reparticionado?
- **Q4.4** — Después de `dd if=/dev/sda1 of=/dev/sdb1` (un clon crudo de una partición), ¿qué se rompe, y qué comando lo repara?

---

## Ejercicio 5 — `/etc/fstab`: montajes persistentes, hechos con seguridad

1. Leé la tabla existente e identificá los seis campos:

   ```bash
   grep -v '^\s*#' /etc/fstab | column -t
   ```

   ```
   UUID=6f8a5c3e-4b21-4c9a-9f0e-2b7d1a5c8e33  /          ext4  errors=remount-ro   0  1
   UUID=9C1E-3F2A                             /boot/efi  vfat  umask=0077          0  1
   /dev/vda3                                  none       swap  sw                  0  0
   tmpfs                                      /tmp       tmpfs defaults,nosuid,nodev,size=2G  0  0
   ```

   | # | Campo | Significado |
   |---|---|---|
   | 1 | `fs_spec` | Origen: nodo de dispositivo, `UUID=`, `LABEL=`, `PARTUUID=`, recurso compartido de red, u origen pseudo (`tmpfs`, `none`) |
   | 2 | `fs_file` | Punto de montaje (`none` para swap; también se acepta `swap`) |
   | 3 | `fs_vfstype` | Tipo de sistema de archivos, o `auto` para dejar que `blkid` decida, o `swap` |
   | 4 | `fs_mntops` | Opciones separadas por comas, sin espacios |
   | 5 | `fs_freq` | Flag de `dump(8)` — `0` en la práctica |
   | 6 | `fs_passno` | Orden de `fsck` al arrancar: `1` para la raíz, `2` para el resto, `0` para omitir |

2. Hacé un backup del archivo antes de tocarlo. Esto no es opcional:

   ```bash
   cp -a /etc/fstab /etc/fstab.bak
   ```

3. Agregá entradas para los sistemas de archivos del lab, usando el UUID actual:

   ```bash
   LABUUID=$(blkid -o value -s UUID /dev/loop0)
   cat >> /etc/fstab <<EOF

   # --- LPIC-1 104.3 lab ---
   UUID=$LABUUID  /mnt/lab  ext4  defaults,nosuid,nodev,noatime,nofail  0  2
   EOF
   tail -3 /etc/fstab
   ```

4. **Validá antes de confiar en él:**

   ```bash
   findmnt --verify --verbose
   ```

   ```
   /
      [ ] target exists
      [ ] UUID=6f8a5c3e-... translated to /dev/vda2
      [ ] FS type is ext4
   ...
   /mnt/lab
      [ ] target exists
      [ ] UUID=d34c7b95-... translated to /dev/loop0
      [ ] FS type is ext4
      [ ] recommended root FS passno is 1 (current is 2)

   Success, no errors or warnings detected
   ```

5. Montá todo lo declarado en `fstab` que todavía no esté montado:

   ```bash
   mount -a
   findmnt /mnt/lab
   ```

   ```
   TARGET   SOURCE     FSTYPE OPTIONS
   /mnt/lab /dev/loop0 ext4   rw,nosuid,nodev,noatime
   ```

6. Con la entrada presente, la forma corta ahora funciona, y las opciones vienen de `fstab`:

   ```bash
   umount /mnt/lab
   mount /mnt/lab
   findmnt -no OPTIONS /mnt/lab
   mount -o ro /mnt/lab && findmnt -no OPTIONS /mnt/lab    # fstab options + your override
   ```

   ```
   rw,nosuid,nodev,noatime
   ro,nosuid,nodev,noatime
   ```

7. Avisale a systemd que `fstab` cambió (se compila en units al arrancar — mirá el Ejercicio 8):

   ```bash
   systemctl daemon-reload
   systemctl status mnt-lab.mount --no-pager | head -6
   ```

   ```
   ● mnt-lab.mount - /mnt/lab
        Loaded: loaded (/etc/fstab; generated)
        Active: active (mounted) since Wed 2026-08-26 09:44:11 UTC; 12s ago
         Where: /mnt/lab
          What: /dev/loop0
          Docs: man:fstab(5)
   ```

**Comprobá lo que entendiste**

- **Q5.1** — ¿Qué se saltea exactamente `mount -a`, y qué única opción le agregarías a la entrada del lab para que `mount -a` la ignore?
- **Q5.2** — Explicá `nofail` y `_netdev`. Si un disco USB extraíble está listado en `fstab` y está desconectado al arrancar, ¿cuál de los dos evita que falle el arranque, y qué hace el otro?
- **Q5.3** — ¿Por qué `defaults,ro` es distinto de `ro,defaults`? (Pensá en cómo `mount` parsea la cadena de opciones.) ¿Y a qué se expande realmente `defaults`?
- **Q5.4** — El campo 6 (`fs_passno`) es `1` para `/` y `2` para el resto. ¿Qué controla el número, y por qué `0` es correcto para un recurso NFS, un `tmpfs` y un volumen Btrfs?
- **Q5.5** — Editaste `fstab` y ejecutaste `mount -a` con éxito, pero **no** ejecutaste `systemctl daemon-reload`. Nombrá una situación concreta donde esa omisión te muerde más adelante.

---

## Ejercicio 6 — Sistemas de archivos extraíbles montables por el usuario

1. Creá un usuario de prueba sin privilegios:

   ```bash
   useradd -m -s /bin/bash student
   ```

2. Agregá una entrada en `fstab` para el "pendrive USB" que un usuario normal pueda montar:

   ```bash
   cat >> /etc/fstab <<'EOF'
   LABEL=LABUSB  /mnt/usb  vfat  user,noauto,noatime,uid=student,gid=student,umask=077,shortname=mixed  0  0
   EOF
   systemctl daemon-reload
   ```

3. Confirmá que *no* hace falta root:

   ```bash
   su - student -c 'mount /mnt/usb'
   su - student -c 'findmnt -no SOURCE,OPTIONS /mnt/usb'
   ```

   ```
   /dev/loop1 rw,nosuid,nodev,noexec,relatime,uid=1001,gid=1001,fmask=0077,dmask=0077,...
   ```

   Fijate en las opciones que reporta el kernel: `nosuid`, `nodev` y `noexec` están ahí aunque nunca las escribiste.

4. Verificá quién tiene permitido desmontar:

   ```bash
   su - student -c 'umount /mnt/usb'      # succeeds: student mounted it
   su - student -c 'mount /mnt/usb'
   useradd -m -s /bin/bash student2
   su - student2 -c 'umount /mnt/usb'
   ```

   ```
   umount: /mnt/usb: umount failed: Operation not permitted
   ```

5. Cambiá `user` por `users` y repetí:

   ```bash
   sed -i 's|LABEL=LABUSB  /mnt/usb  vfat  user,|LABEL=LABUSB  /mnt/usb  vfat  users,|' /etc/fstab
   su - student2 -c 'umount /mnt/usb'     # now allowed
   grep LABUSB /etc/fstab
   ```

6. Restaurá deliberadamente la semántica del bit *ejecutable*, y observá la regla de orden:

   ```bash
   sed -i 's|users,noauto,|users,noauto,exec,|' /etc/fstab
   su - student -c 'mount /mnt/usb'
   findmnt -no OPTIONS /mnt/usb
   ```

   ```
   rw,nosuid,nodev,relatime,uid=1001,gid=1001,fmask=0077,dmask=0077,...
   ```

7. Mirá el mecanismo que permite todo esto:

   ```bash
   ls -l /usr/bin/mount /usr/bin/umount
   ```

   ```
   -rwsr-xr-x 1 root root 59704 Mar 23  2023 /usr/bin/mount
   -rwsr-xr-x 1 root root 39760 Mar 23  2023 /usr/bin/umount
   ```

8. Para comparar, mirá qué hace en cambio una sesión de escritorio (si `udisks2` está instalado):

   ```bash
   command -v udisksctl && su - student -c 'udisksctl info -b /dev/loop1 | head -8'
   ```

**Comprobá lo que entendiste**

- **Q6.1** — Compará `user`, `users`, `owner` y `group`. Para cada una, indicá exactamente *quién* puede montar y *quién* puede desmontar.
- **Q6.2** — `user` habilita implícitamente `noexec,nosuid,nodev`. ¿Por qué es ese el default correcto para medios extraíbles, y cuál es el ataque que previene?
- **Q6.3** — En el paso 6, `exec` tuvo que escribirse *después* de `users` para tener efecto. ¿Cuál es la regla general de parseo, y qué habría producido `exec,users`?
- **Q6.4** — `vfat` no tiene propiedad UNIX. Explicá `uid=`, `gid=`, `umask=`, `fmask=` y `dmask=`, y dá el par `fmask`/`dmask` equivalente a `umask=022`.
- **Q6.5** — En un escritorio moderno, enchufar un pendrive USB lo monta en `/run/media/<user>/<label>` sin ninguna entrada en `fstab`. ¿Qué componente hace eso, y por qué se considera más seguro que el binario `mount` setuid?

---

## Ejercicio 7 — Desmontar: sistemas de archivos ocupados y cómo diagnosticarlos

1. Ocupá el sistema de archivos de tres maneras distintas, desde una segunda shell si preferís:

   ```bash
   mount /mnt/lab 2>/dev/null
   sleep 900 > /mnt/lab/held.log &          # (a) an open file descriptor
   cd /mnt/lab                              # (b) a process CWD inside the mount
   ```

2. Intentá desmontar y leé el error con atención:

   ```bash
   umount /mnt/lab
   ```

   ```
   umount: /mnt/lab: target is busy.
   ```

3. Encontrá a los culpables — dos herramientas complementarias:

   ```bash
   lsof +f -- /mnt/lab
   ```

   ```
   COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
   bash     4127 root  cwd    DIR    7,0     1024    2 /mnt/lab
   sleep    4162 root    1w   REG    7,0        0   14 /mnt/lab/held.log
   ```

   ```bash
   fuser -vm /mnt/lab
   ```

   ```
                        USER        PID ACCESS COMMAND
   /mnt/lab:            root       4127 ..c.. bash
                        root       4162 ...e. sleep
   ```

   Letras de `ACCESS`: `c` = directorio actual, `e` = ejecutable en ejecución, `f` = archivo abierto, `r` = directorio raíz, `m` = archivo mapeado con mmap.

4. Resolvelo como corresponde — liberá las referencias en vez de forzar al kernel:

   ```bash
   cd /
   kill 4162          # use the PID that fuser reported
   umount /mnt/lab && echo "clean unmount"
   ```

   ```
   clean unmount
   ```

5. Ahora estudiá las salidas de emergencia. Recreá la condición de ocupado y usá un desmontaje perezoso:

   ```bash
   mount /mnt/lab
   sleep 900 > /mnt/lab/held.log &
   umount --lazy /mnt/lab
   findmnt /mnt/lab ; echo "findmnt rc=$?"
   grep -c /mnt/lab /proc/self/mountinfo
   lsof +f -- /mnt/lab 2>/dev/null | wc -l
   ```

   ```
   findmnt rc=1
   0
   0
   ```

   El punto de montaje se desprende del namespace de inmediato, pero el sistema de archivos sigue vivo hasta que se suelta la última referencia. Confirmá que el dispositivo todavía está retenido:

   ```bash
   losetup -d /dev/loop0
   ```

   ```
   losetup: /dev/loop0: detach failed: Device or resource busy
   ```

6. Limpiálo de verdad, y aprendé la diferencia entre `-l` y `-f`:

   ```bash
   pkill -f 'sleep 900'
   sleep 2
   losetup -d /dev/loop0 && echo "loop freed"
   losetup --find --show /root/lab-ext4.img       # re-attach for the rest of the lab
   ```

7. Asegurate de que los datos estén en almacenamiento estable antes de sacar un dispositivo:

   ```bash
   mount /mnt/lab 2>/dev/null || mount /dev/loop0 /mnt/lab
   dd if=/dev/zero of=/mnt/lab/big.bin bs=1M count=64 status=none
   sync -f /mnt/lab/big.bin        # or: sync ; or: umount, which flushes implicitly
   rm -f /mnt/lab/big.bin
   ```

**Comprobá lo que entendiste**

- **Q7.1** — Explicá la diferencia entre `umount -l` (lazy) y `umount -f` (force). ¿Para qué tipo de sistema de archivos se diseñó `-f` principalmente, y por qué es casi inútil sobre ext4 local?
- **Q7.2** — Después de `umount -l`, `findmnt` no muestra nada pero `losetup -d` sigue fallando. Reconciliá esos dos hechos en términos del VFS.
- **Q7.3** — `fuser -km /mnt/lab` es un one-liner popular. Dá dos razones concretas por las que es peligroso en producción.
- **Q7.4** — Un proceso tiene un FD abierto sobre un archivo **borrado** dentro del montaje. `lsof` lo muestra con `(deleted)`. ¿Podés desmontar? ¿Podés recuperar el espacio en disco?
- **Q7.5** — ¿Por qué `umount` sobre un montaje de lectura-escritura no es instantáneo, y qué le pasaría al sistema de archivos si en cambio sacaras el dispositivo físicamente?

---

## Ejercicio 8 — Units systemd `.mount` y `.automount`

1. Observá que las entradas de `fstab` ya son units de systemd, generadas al arrancar:

   ```bash
   systemctl list-units --type=mount --no-pager | head
   ls /run/systemd/generator/ | head
   ls -l /usr/lib/systemd/system-generators/systemd-fstab-generator
   ```

   ```
   UNIT           LOAD   ACTIVE SUB     DESCRIPTION
   -.mount        loaded active mounted Root Mount
   boot-efi.mount loaded active mounted /boot/efi
   mnt-lab.mount  loaded active mounted /mnt/lab
   proc.mount     loaded active mounted /proc
   ```

2. Derivá un nombre de unit a partir de una ruta — la regla de escapado no es opcional:

   ```bash
   systemd-escape -p --suffix=mount /mnt/lab
   systemd-escape -p --suffix=mount /srv/data-01/backups
   systemd-escape -u -p mnt-lab.mount
   ```

   ```
   mnt-lab.mount
   srv-data\x2d01-backups.mount
   /mnt/lab
   ```

3. Quitá la entrada de `fstab` y reemplazála por una unit nativa:

   ```bash
   umount /mnt/lab
   sed -i '/LPIC-1 104.3 lab/,+1d' /etc/fstab
   LABUUID=$(blkid -o value -s UUID /dev/loop0)
   cat > /etc/systemd/system/mnt-lab.mount <<EOF
   [Unit]
   Description=LPIC-1 104.3 lab filesystem
   Documentation=man:systemd.mount(5)

   [Mount]
   What=/dev/disk/by-uuid/$LABUUID
   Where=/mnt/lab
   Type=ext4
   Options=defaults,nosuid,nodev,noatime
   TimeoutSec=30

   [Install]
   WantedBy=multi-user.target
   EOF
   systemctl daemon-reload
   systemctl start mnt-lab.mount
   systemctl status mnt-lab.mount --no-pager | head -8
   ```

   ```
   ● mnt-lab.mount - LPIC-1 104.3 lab filesystem
        Loaded: loaded (/etc/systemd/system/mnt-lab.mount; disabled; preset: enabled)
        Active: active (mounted) since Wed 2026-08-26 10:02:44 UTC; 1s ago
         Where: /mnt/lab
          What: /dev/loop0
          Docs: man:systemd.mount(5)
         Tasks: 0 (limit: 4653)
   ```

4. Confirmá que detener la unit realmente desmonta:

   ```bash
   systemctl stop mnt-lab.mount
   findmnt /mnt/lab ; echo "rc=$?"
   ```

   ```
   rc=1
   ```

5. Agregá montaje bajo demanda con una unit `.automount` acompañante:

   ```bash
   cat > /etc/systemd/system/mnt-lab.automount <<'EOF'
   [Unit]
   Description=Automount for the LPIC-1 104.3 lab filesystem

   [Automount]
   Where=/mnt/lab
   TimeoutIdleSec=30

   [Install]
   WantedBy=multi-user.target
   EOF
   systemctl daemon-reload
   systemctl start mnt-lab.automount
   findmnt /mnt/lab
   ```

   ```
   TARGET   SOURCE   FSTYPE    OPTIONS
   /mnt/lab systemd-1 autofs   rw,relatime,fd=53,pgrp=1,timeout=30,minproto=5,maxproto=5,direct
   ```

6. Disparás el montaje con solo tocar la ruta, y después dejá que expire por inactividad:

   ```bash
   ls /mnt/lab
   findmnt -no FSTYPE,SOURCE /mnt/lab
   sleep 45
   findmnt -no FSTYPE,SOURCE /mnt/lab
   ```

   ```
   lost+found  notes.txt  hello.sh  id-suid  sub
   ext4 /dev/loop0
   autofs systemd-1
   ```

7. El mismo comportamiento está disponible directamente desde `fstab`. Como referencia (no lo agregues ahora, la unit nativa está activa):

   ```
   UUID=<uuid>  /mnt/lab  ext4  noauto,x-systemd.automount,x-systemd.idle-timeout=30,x-systemd.device-timeout=10s,nofail  0  2
   ```

8. Inspeccioná el orden y las dependencias:

   ```bash
   systemctl show mnt-lab.mount -p After -p Requires -p Wants
   systemctl list-dependencies local-fs.target --no-pager | head
   ```

**Comprobá lo que entendiste**

- **Q8.1** — `/srv/data-01/backups` se convierte en `srv-data\x2d01-backups.mount`. Enunciá las tres reglas de escapado que producen ese nombre, y explicá por qué una unit cuyo `Where=` no coincide con su nombre de archivo se niega a cargar.
- **Q8.2** — Tenés tanto una línea en `fstab` como `/etc/systemd/system/mnt-lab.mount` para `/mnt/lab`. ¿Cuál gana, y por qué (nombrá la precedencia de directorios)?
- **Q8.3** — ¿Qué te aporta `x-systemd.automount` frente a una entrada `auto` común para un servidor NFS que a veces es inalcanzable? ¿Qué dos opciones acotan la espera?
- **Q8.4** — Las opciones que empiezan con `x-` son ignoradas por `mount(8)`. ¿Por qué es significativo ese prefijo, y quién las lee en cambio?
- **Q8.5** — Después de `systemctl stop mnt-lab.automount`, ¿`/mnt/lab` sigue montado si estaba montado en ese momento? Justificá.

---

## Ejercicio 9 — Lab de fallas: un `fstab` roto, y cómo no perder el arranque

> Este ejercicio crea intencionalmente una condición que bloquea el arranque. Ejecutálo en una VM que puedas snapshotear o descartar.

1. Hacé un snapshot de la VM (o al menos confirmá que existe `/etc/fstab.bak` del Ejercicio 5):

   ```bash
   ls -l /etc/fstab.bak
   ```

2. Introducí el error clásico — un UUID equivocado, sin `nofail`:

   ```bash
   cat >> /etc/fstab <<'EOF'
   UUID=00000000-dead-beef-0000-000000000000  /mnt/broken  ext4  defaults  0  2
   EOF
   mkdir -p /mnt/broken
   ```

3. Detectálo **antes** de reiniciar:

   ```bash
   findmnt --verify --verbose
   ```

   ```
   /mnt/broken
      [ ] target exists
      [W] cannot find UUID=00000000-dead-beef-0000-000000000000
      [ ] FS type is ext4

   0 parse errors, 0 errors, 1 warning
   ```

   ```bash
   mount -a ; echo "mount -a rc=$?"
   ```

   ```
   mount: /mnt/broken: can't find UUID=00000000-dead-beef-0000-000000000000.
          dmesg(1) may have more information after failed mount system call.
   mount -a rc=32
   ```

4. Mirá cómo lo trataría systemd al arrancar:

   ```bash
   systemctl daemon-reload
   systemctl start mnt-broken.mount ; echo "rc=$?"
   systemctl status mnt-broken.mount --no-pager | head -5
   journalctl -u mnt-broken.mount --no-pager | tail -3
   ```

   ```
   Job for mnt-broken.mount failed.
   See "systemctl status mnt-broken.mount" and "journalctl -xeu mnt-broken.mount" for details.
   rc=1
   ● mnt-broken.mount - /mnt/broken
        Loaded: loaded (/etc/fstab; generated)
        Active: failed (Result: exit-code) since Wed 2026-08-26 10:15:02 UTC
   ```

5. Ahora introducí un error de *sintaxis* (un espacio dentro del campo de opciones) y observá una clase distinta de falla:

   ```bash
   sed -i 's|/mnt/broken  ext4  defaults|/mnt/broken  ext4  defaults, noatime|' /etc/fstab
   findmnt --verify
   ```

   ```
   /etc/fstab: parse error at line 12 -- ignored
   1 parse error, 0 errors, 0 warnings
   ```

6. Reparalo y volvé a verificar:

   ```bash
   sed -i '/00000000-dead-beef/d' /etc/fstab
   findmnt --verify && mount -a && systemctl daemon-reload
   ```

   ```
   Success, no errors or warnings detected
   ```

7. Memorizá el camino de recuperación para cuando esto *sí* llegue a un reinicio:

   - systemd cae en **modo de emergencia** y pide la contraseña de root. Entonces:
     ```bash
     journalctl -xb -p err
     mount -o remount,rw /
     vi /etc/fstab            # fix or comment out the offending line
     systemctl daemon-reload
     mount -a
     systemctl default
     ```
   - Si la contraseña de root no está disponible, agregá `systemd.unit=emergency.target` — o, para un arranque sin tabla, `rd.break` / `init=/bin/bash` — a la línea de comandos del kernel desde el menú de GRUB, y después remontá `/` en lectura-escritura y editá.

**Comprobá lo que entendiste**

- **Q9.1** — `mount -a` devolvió el estado de salida `32`. ¿Por qué chequear ese estado importa más que leer el mensaje, y qué significa un estado distinto de cero para un script de aprovisionamiento?
- **Q9.2** — ¿Qué única opción en la entrada rota habría convertido un arranque fallido en una advertencia registrada? ¿Cuál es el compromiso de aplicarla en todos lados?
- **Q9.3** — Los pasos 3 y 5 produjeron una *advertencia* y un *error de parseo*. ¿Cuál de los dos es más peligroso en la práctica, y por qué?
- **Q9.4** — Explicá la cadena exacta de eventos, desde `systemd-fstab-generator` a `local-fs.target` a `emergency.target`, que termina en un pedido de contraseña al arrancar.
- **Q9.5** — Dá una checklist de tres comandos previa al vuelo que ejecutarías en cada host después de editar `/etc/fstab`, en orden.

---

## Ejercicio 10 — Limpieza

1. Detené las units de systemd y quitálas:

   ```bash
   systemctl stop mnt-lab.automount mnt-lab.mount
   rm -f /etc/systemd/system/mnt-lab.mount /etc/systemd/system/mnt-lab.automount
   systemctl daemon-reload
   systemctl reset-failed
   ```

2. Desmontá todo lo del lab y confirmá que no queda nada:

   ```bash
   umount /mnt/usb /mnt/lab /mnt/lab-ro /srv/exported 2>/dev/null
   findmnt --source /dev/loop0 --source /dev/loop1 ; echo "rc=$?"
   ```

3. Restaurá `/etc/fstab` desde el backup y validá:

   ```bash
   cp -a /etc/fstab.bak /etc/fstab
   findmnt --verify
   systemctl daemon-reload
   ```

4. Desasociá los dispositivos loop y borrá las imágenes:

   ```bash
   losetup -D
   losetup -a
   rm -f /root/lab-ext4.img /root/lab-usb.img
   rmdir /mnt/lab /mnt/lab-ro /mnt/usb /mnt/broken /srv/exported 2>/dev/null
   ```

5. Eliminá los usuarios de prueba:

   ```bash
   userdel -r student ; userdel -r student2
   ```

6. Chequeo final de sanidad — un reinicio debe transcurrir sin novedades:

   ```bash
   findmnt --verify --verbose && mount -a && echo "fstab is consistent"
   ```

---

<details>
<summary><strong>Respuestas</strong> — hacé clic para expandir</summary>

### Ejercicio 1

**A1.1** — El viejo `/etc/mtab` era un archivo de *espacio de usuario* escrito por `mount(8)`. Se desincronizaba de la realidad cada vez que el sistema de archivos que lo contenía estaba en solo lectura (arranque temprano, modo de rescate), cada vez que ocurría un montaje sin `mount(8)` (iniciado por el kernel, contenedores, llamadas a `mount(2)`), y dentro de chroots y mount namespaces, donde describía el host en lugar del llamador. Enlazarlo simbólicamente a `/proc/self/mounts` hace del kernel la única fuente de verdad y lo vuelve consciente de los namespaces.

Lo que se pierde: `/proc/self/mounts` muestra el origen *canónico* (`/dev/loop0`, `/dev/vda2`) y las opciones *efectivas*, no lo que escribió el administrador. Específicamente, la especificación original al estilo `fstab` (`UUID=…`, `LABEL=…`) y las opciones exclusivas del espacio de usuario (`user`, `users`, `loop=`, `x-*`, `_netdev`) no están en la tabla del kernel. `util-linux` las guarda en `/run/mount/utab`, que es la razón por la que `umount` sigue sabiendo *quién* montó un sistema de archivos con `user`, y por la que `findmnt` puede imprimir un origen `UUID` mientras `/proc/mounts` imprime un nodo de dispositivo.

**A1.2** — Los flags del VFS (`ro`, `nosuid`, `nodev`, `noexec`, `noatime`/`relatime`, `nodiratime`) son **por montaje**: pertenecen al objeto de montaje, así que el mismo superblock expuesto en dos rutas puede llevar flags distintos. Las opciones específicas del sistema de archivos (`errors=remount-ro`, `data=ordered`, `commit=`, `discard`, `journal_checksum`) son **por superblock**: hay exactamente un superblock, así que cambiarlas en un punto de montaje las cambia en todos lados. Esto es exactamente por lo que un "bind mount de solo lectura para el servidor web" funciona, pero una opción de *superblock* del tipo "solo lectura para este contenedor, lectura-escritura para el host" no.

**A1.3** — `findmnt`. Tiene un contrato de salida definido (`-o`/`--output`), modos legibles por máquina (`--json`, `--pairs`, `--raw`), códigos de salida predecibles (`1` = no encontrado), y maneja correctamente rutas que contienen espacios (codificados como `\040` en `/proc/mounts`). Parsear `mount` sin argumentos significa parsear prosa humana (`/dev/vda2 on / type ext4 (rw,relatime)`) cuyo formato no está garantizado y se rompe con puntos de montaje inusuales.

---

### Ejercicio 2

**A2.1** — `truncate` crea un archivo **sparse**: los metadatos de tamaño dicen 256 MiB pero no se asigna ningún bloque hasta que se escribe. `ls -lh` reporta el tamaño aparente; `du` reporta los bloques asignados. El riesgo: el sistema de archivos subyacente puede quedarse sin espacio *mientras el sistema de archivos huésped cree que tiene espacio libre*, produciendo `EIO`/`ENOSPC` desde adentro de la imagen montada y, en ext4, un evento `remount-ro`. Para cualquier cosa que no sea un lab, usá `fallocate -l 256M` (asignación real) en su lugar.

**A2.2** — `mount -o loop` llama a los mismos ioctls de `loop` internamente: busca un `/dev/loopN` libre, asocia el archivo y lo monta. También activa el flag **autoclear** del dispositivo loop, así que la asociación se deshace automáticamente cuando se desmonta el sistema de archivos — nunca necesitás `losetup -d`. Vale la pena saber hacerlo manualmente porque te permite inspeccionar (`blkid`, `fsck`, `mkfs`, escaneo de particiones con `losetup -P`) la imagen *antes* de montarla.

**A2.3** — Sí, genuinamente. `mkfs` sobre algo que no es un dispositivo de bloque es legítimo para imágenes, pero el mismo camino de código reformatearía con toda felicidad un archivo regular cualquiera que hayas nombrado por error — un typo en una ruta es el caso común. Como la intención no se puede inferir, `mke2fs` pregunta; `-F` suprime la pregunta, y solo debería escribirse cuando el destino fue releído.

---

### Ejercicio 3

**A3.1** — `noexec` hace que el kernel rechace `execve(2)` sobre archivos bajo ese montaje, que es lo que pasa cuando la shell ejecuta `/mnt/lab/hello.sh` directamente (el kernel carga el intérprete vía la línea `#!` recién *después* de decidir que el archivo es ejecutable). `sh /mnt/lab/hello.sh` nunca llama a `execve` sobre ese archivo: `/bin/sh` — que vive en un sistema de archivos con `exec` permitido — simplemente hace `open()` y `read()` sobre él como datos. El mismo agujero aplica a `python script.py`, `perl`, `bash -c "$(cat …)"`, y `ld.so /path/to/binary`.

Conclusión: `noexec` es una **medida de hardening que eleva el costo**, no una frontera. Frena binarios ELF depositados y payloads con `chmod +x` casual; no frena a un intérprete. Tratalo como una capa más junto a `nosuid`, `nodev` y el control de acceso obligatorio.

**A3.2** — `ro`, `nosuid` y `relatime` son flags del VFS por montaje y **pueden** diferir entre los dos montajes. `errors=remount-ro` es una opción de superblock de ext4 y **no puede**: es una propiedad del único superblock. Intentar establecer una opción de superblock conflictiva en el segundo montaje se ignora silenciosamente (kernels viejos) o se rechaza; solo los valores del primer montaje están en efecto.

**A3.3** — Un bind mount no tiene un superblock propio para remontar; `mount -o remount,ro /srv/exported` sin `bind` se interpreta como un pedido contra el superblock del sistema de archivos subyacente, así que en kernels viejos cambiaba silenciosamente *todo* el montaje ext4 y en `util-linux` actual da error. Los flags del VFS propios del bind mount se cambian con `mount -o remount,bind,ro <target>` (`util-linux ≥ 2.37` también acepta el más claro `mount -o bind,ro src tgt` en un solo paso, haciendo las dos operaciones por vos).

**A3.4** — `remount,ro` solo requiere que ningún archivo esté abierto **para escritura**; el kernel vacía los buffers y cambia el superblock. `/` está lleno de procesos con descriptores de *lectura* abiertos y ejecutables corriendo, que no lo bloquean. `/home`, en cambio, típicamente tiene editores, navegadores o una shell con un descriptor de escritura abierto o una escritura en curso, y cada uno de esos devuelve `EBUSY`. `umount` es aún más estricto: necesita *cero* referencias de cualquier tipo, incluido un CWD.

---

### Ejercicio 4

**A4.1** — (1) **El orden de enumeración no es determinista**: el descubrimiento de SCSI/SATA/NVMe/USB es asincrónico y paralelo entre hilos del kernel, así que qué disco reclama `sdb` frente a `sdc` puede cambiar en cada arranque. (2) **Cambios de topología**: agregar, quitar o reordenar una controladora, un disco o un dispositivo USB desplaza todas las letras posteriores.

`UUID=` ata la entrada al *sistema de archivos*, no al lugar en la enumeración. udev crea `/dev/disk/by-uuid/<uuid>` cuando el dispositivo aparece, `mount` resuelve a través de él, y el mapeo es correcto sin importar qué nodo asignó el kernel.

**A4.2** — Las etiquetas **no son únicas ni se hacen cumplir**. Enchufá un disco USB clonado de la misma imagen dorada (o dos pendrives de recuperación de un fabricante ambos etiquetados `DATA`), y `LABEL=DATA` resuelve al dispositivo que udev enlazó último — `/dev/disk/by-label/DATA` es un único symlink que se sobrescribe. El sistema puede entonces montar el pendrive USB donde corresponde el volumen de datos interno. Un UUID de `mkfs` es un valor aleatorio de 128 bits y no colisiona por accidente.

**A4.3** —
- `UUID=` — identificador escrito **dentro del superblock del sistema de archivos** por `mkfs`. Sobrevive al reparticionado de *otras* particiones y a mover el disco a otra controladora; se destruye con un nuevo `mkfs`; se duplica con un clon crudo.
- `PARTUUID=` — identificador en la **tabla de particiones** (nativo en GPT; para MBR es un sintético `<disk-signature>-<NN>`). Sobrevive a `mkfs` (podés reformatear la partición y el `PARTUUID` queda intacto); se destruye al reparticionar.
- `PARTLABEL=` — **nombre de partición GPT** legible por humanos (solo GPT; MBR no tiene ese campo). Misma vida útil que `PARTUUID`, misma salvedad de no unicidad que `LABEL`.

Entonces: `PARTUUID` sobrevive a `mkfs`; `UUID` sobrevive al reparticionado del resto del disco pero no a un reformateo de su propia partición; ninguno sobrevive a que se recree su propio contenedor.

**A4.4** — El clon lleva el *mismo* UUID de sistema de archivos (y la misma etiqueta) que el origen. `/dev/disk/by-uuid/<uuid>` ahora puede apuntar a cualquiera de los dos dispositivos, `blkid` reporta la ambigüedad, `mount UUID=…` se vuelve no determinista, y en un sistema de archivos raíz el initramfs puede montar el disco equivocado. Se repara generando uno nuevo en la copia:

```bash
tune2fs -U random /dev/sdb1        # ext2/3/4
xfs_admin -U generate /dev/sdb1    # XFS
btrfstune -u /dev/sdb1             # Btrfs (unmounted)
swaplabel -U $(uuidgen) /dev/sdb2  # swap
```
y actualizando `/etc/fstab` (y, para un sistema de archivos raíz, el bootloader y el initramfs) al nuevo valor.

---

### Ejercicio 5

**A5.1** — `mount -a` saltea: las entradas con `noauto`; las entradas ya montadas; las entradas cuyo tipo está excluido por los filtros `-t`/`-O`; y las entradas de swap (eso es tarea de `swapon -a`). `noauto` es la opción que mantiene la entrada del lab en `fstab` — así `mount /mnt/lab` sigue funcionando con las opciones registradas — mientras la excluye de `mount -a` y del arranque.

**A5.2** —
- `nofail` — si el dispositivo está ausente o el montaje falla, **no** lo trates como un error fatal; el arranque continúa y la falla queda registrada. Esta es la opción que salva el arranque con un disco USB faltante.
- `_netdev` — declara que el sistema de archivos necesita la red. `systemd-fstab-generator` entonces ordena la unit después de `network-online.target` y la coloca en `remote-fs.target` en lugar de `local-fs.target`, y al apagar se desmonta antes de que caiga la red. No dice nada sobre tolerancia a fallas.

Para medios extraíbles generalmente querés ambas, `noauto,nofail` (más `x-systemd.automount` si debe montarse al acceder); para iSCSI/NFS/CIFS querés `_netdev,nofail` (`nofail` sola igual colgaría hasta que expire el timeout del dispositivo).

**A5.3** — `mount` parsea la lista de opciones **de izquierda a derecha**, y las opciones posteriores anulan a las anteriores. `defaults` se expande a `rw,suid,dev,exec,auto,nouser,async`. Por lo tanto `defaults,ro` termina en solo lectura (el `ro` anula el `rw` de `defaults`), mientras que `ro,defaults` termina en **lectura-escritura**, porque `defaults` reafirma `rw` después — un typo silencioso y peligroso.

**A5.4** — `fs_passno` es el orden de pasada para `fsck` al arrancar (`fsck -A`). `1` significa "chequear primero, solo" y está reservado para el sistema de archivos raíz; `2` significa "chequear en la segunda pasada", donde todos los `2` en discos físicos *distintos* se chequean en paralelo; `0` significa "no chequear".

`0` es lo correcto para NFS (el chequeo es asunto del servidor, no del cliente), para `tmpfs` y otros pseudo-sistemas de archivos (no hay nada en disco que chequear), y para Btrfs (no existe un `fsck.btrfs` significativo en el arranque — es un script no-op por diseño; la integridad se maneja con scrub y con los chequeos de árbol al montar).

**A5.5** — Casos concretos: (1) `systemctl start mnt-lab.mount` o un ordenamiento dependiente de `systemctl daemon-reload` va a usar la unit generada *obsoleta*, así que una dependencia que agregaste (`x-systemd.requires=`, `_netdev`) no se respeta; (2) una unit que quitaste de `fstab` sigue siendo conocida por systemd, y un ciclo posterior de `systemctl stop`/`start` o una decisión de orden de apagado referencia un montaje que ya no existe; (3) en el peor caso, una entrada que *borraste* sigue en las units generadas, y algo en el grafo de dependencias la arrastra y falla. La regla es mecánica: **editar `fstab` → `findmnt --verify` → `mount -a` → `systemctl daemon-reload`.**

---

### Ejercicio 6

**A6.1** —

| Opción | Quién puede montar | Quién puede desmontar |
|---|---|---|
| `user` | cualquier usuario | **solo el usuario que lo montó** (registrado en `/run/mount/utab`), más root |
| `users` | cualquier usuario | **cualquier usuario**, más root |
| `owner` | el usuario que **posee el nodo de dispositivo** (`/dev/sdb1`) | ese mismo dueño, más root |
| `group` | cualquier usuario en el **grupo que posee el nodo de dispositivo** | ese mismo grupo, más root |

Las cuatro implican `noexec,nosuid,nodev` y (en el uso vía `fstab`) requieren que la entrada exista en `/etc/fstab` — un usuario no puede montar un dispositivo arbitrario en una ruta arbitraria.

**A6.2** — Los medios extraíbles son almacenamiento provisto por el atacante: su contenido lo elige quien te dio el pendrive. Sin `nosuid`, una imagen que contenga una shell `setuid` propiedad de root (`chmod 4755 /bin/bash` escrito en la máquina del atacante) le da a un usuario sin privilegios una shell root instantánea con solo enchufarlo y ejecutarla — el kernel respeta los bits de modo en disco, y el atacante controla esos bits. `nodev` bloquea el truco paralelo con un nodo de dispositivo de caracteres como `/dev/mem` o `/dev/sda` con modos permisivos. `noexec` eleva el costo de ejecutar binarios depositados. Esta es la clásica escalada de privilegios por "USB drop", y es la razón por la que el par kernel/`mount` fuerza estos flags en vez de confiar en que el administrador los escriba.

**A6.3** — La regla es la misma anulación de izquierda a derecha que con `defaults`: gana la última aparición de una opción, y `user`/`users` **establecen** `noexec,nosuid,nodev` en la posición donde aparecen. Así que `users,noauto,exec` da `exec` (el `exec` explícito viene después y anula), mientras que `exec,users` da `noexec` — la palabra clave `users` lo reimpone. Notá la asimetría en la salida del paso 6: `exec` se restauró pero `nosuid` y `nodev` permanecen, porque solo `exec` fue anulado. Anular estas opciones en medios montables por el usuario debería ser una decisión deliberada y justificada.

**A6.4** — `vfat`/`exfat`/`ntfs` no almacenan uid/gid/mode de UNIX, así que el driver los **sintetiza** para cada archivo al momento de montar:
- `uid=` / `gid=` — el dueño y el grupo numéricos presentados para *todos* los archivos del montaje.
- `umask=` — bits a **quitar** de los permisos por defecto (`0777`), aplicados tanto a archivos como a directorios.
- `fmask=` — lo mismo, pero solo para **archivos** regulares.
- `dmask=` — lo mismo, pero solo para **directorios**.

`umask=022` es equivalente a `fmask=0022,dmask=0022` — pero la intención habitual (archivos `rw-r--r--`, directorios `rwxr-xr-x`) se escribe mejor como `fmask=0133,dmask=0022`, porque los directorios necesitan el bit de ejecución y los archivos usualmente no deberían tenerlo. `fmask`/`dmask` anulan a `umask` cuando se dan ambos.

**A6.5** — `udisks2` (vía D-Bus, autorizado por `polkit`), manejado por el gestor de archivos del escritorio o por `udisksctl`. Es más seguro porque la operación privilegiada corre en un **demonio separado y auditable** con un motor de políticas por delante (las reglas pueden depender de que la sesión del usuario sea local y activa), en vez de depender de un binario setuid-root que parsea un archivo de texto y metadatos de sistema de archivos no confiables dentro del propio proceso del llamador. Además fija el punto de montaje y las opciones por su cuenta (`/run/media/<user>/<label>`, `nosuid,nodev`), así que no hay una cadena de opciones tipeada por el administrador que pueda salir mal, y no requiere una entrada en `fstab` por dispositivo.

---

### Ejercicio 7

**A7.1** —
- `umount -l` (**lazy**, `MNT_DETACH`): desprende el montaje del namespace *de inmediato* así la ruta queda inutilizable, pero deja vivos el sistema de archivos y el superblock hasta que se libere el último archivo abierto, CWD y mmap. Siempre "tiene éxito" y nunca pierde datos — difiere.
- `umount -f` (**force**, `MNT_FORCE`): le pide al driver del sistema de archivos que aborte las peticiones pendientes y desmonte ahora. Fue diseñado para **NFS**, donde un servidor colgado deja procesos bloqueados en E/S ininterrumpible para siempre y no hay forma de liberar las referencias; forzar permite que el kernel haga fallar esos RPC. En ext4 local es casi inútil porque la condición de "ocupado" son *referencias del espacio de usuario*, no E/S trabada — y forzar arriesga descartar datos aún no escritos.

El default correcto no es ninguno de los dos: encontrá las referencias con `lsof`/`fuser` y liberálas.

**A7.2** — Desmontar quita el montaje del **mount namespace** (así que `findmnt` y `/proc/self/mountinfo` ya no lo listan, y la ruta resuelve al directorio subyacente), pero no libera el **superblock**. Mientras un proceso mantenga un descriptor de archivo abierto, un CWD o un mmap sobre un inodo de ese sistema de archivos, el superblock sigue activo y el dispositivo de bloque sigue reclamado por él — de ahí el `EBUSY` de `losetup -d`. El dispositivo se libera en el momento en que el contador de referencias llega a cero, que es por lo que matar el `sleep` lo arregló sin ningún desmontaje adicional.

**A7.3** — (1) Manda `SIGKILL` a **todo** proceso que toque el montaje, incluidos los que no querías alcanzar: si el montaje es `/` o `/var` — o si escribiste mal la ruta — eso es el sistema entero, matado sin oportunidad de vaciar buffers ni apagarse limpiamente. (2) `SIGKILL` no le da a bases de datos, brokers de mensajes ni editores ninguna oportunidad de hacer commit, así que convierte una molestia de "no puedo desmontar" en pérdida de datos o en un ciclo de recuperación por caída. Secuencia más segura: identificar con `fuser -vm`, pedirle al servicio dueño que se detenga (`systemctl stop`), escalar a `SIGTERM` (`fuser -m -k -TERM`), y solo entonces considerar `umount -l`.

**A7.4** — **No**, no podés desmontar: un archivo borrado pero abierto todavía tiene un inodo con un contador de referencias positivo sobre ese superblock, así que el montaje está ocupado. Y **no**, no podés recuperar el espacio: los bloques se liberan solo cuando se cierra el último descriptor (esta es la clásica situación de "`df` dice lleno, `du` dice vacío", típicamente un archivo de log rotado por debajo de un demonio). Se arregla cerrando el descriptor — reiniciá o mandá `HUP` al proceso dueño, o en emergencias truncá a través de `/proc/<pid>/fd/<n>`.

**A7.5** — `umount` debe escribir de vuelta las páginas sucias de la page cache, hacer commit del journal y marcar el superblock como limpio antes de retornar; en un sistema de archivos con un gran backlog sucio de writeback eso lleva tiempo real. Sacar el dispositivo físicamente en cambio deja el estado en disco inconsistente: el superblock queda marcado como "no desmontado limpiamente", las escrituras bufferizadas se pierden, y el próximo montaje dispara recuperación del journal (ext4/XFS) o un `fsck` completo (`vfat`, que no tiene journal — por esto arrancar de un tirón un pendrive USB lo corrompe). Siempre hacé `umount` (o al menos `sync`) primero; `umount` implica el vaciado, que es por lo que no es instantáneo.

---

### Ejercicio 8

**A8.1** — Las reglas que usa `systemd-escape -p`:
1. El `/` inicial se descarta, y los separadores `/` restantes se convierten en `-`.
2. Todo carácter fuera de `[0-9a-zA-Z:_.]` se reemplaza por `\x` más su código hexadecimal de dos dígitos en minúscula — así el `-` literal en `data-01` se vuelve `\x2d` (si no, se leería de vuelta como un separador de rutas).
3. Se agrega el sufijo `.mount` (`--suffix=mount`); un dígito o un `.` inicial se escaparía además.

El nombre de archivo de una unit `.mount` **es** el punto de montaje — systemd deriva `Where=` del nombre y se niega a cargar una unit cuyo `Where=` explícito no coincida, porque los dos identificarían montajes distintos y el grafo de dependencias (`RequiresMountsFor=`, el orden dentro de `local-fs.target`) se indexa por la ruta escapada. El nombre correcto siempre es lo que imprime `systemd-escape -p --suffix=mount <path>`.

**A8.2** — Gana la unit nativa en `/etc/systemd/system/`. La precedencia de búsqueda de units, de mayor a menor, incluye: `/etc/systemd/system` → `/run/systemd/system` → `/run/systemd/generator` → `/usr/lib/systemd/system` → `/run/systemd/generator.late`. `systemd-fstab-generator` escribe en `/run/systemd/generator`, que está **por debajo** de `/etc/systemd/system`, así que una unit escrita por el administrador eclipsa por completo a la generada desde `fstab`. (Notá que la línea `Loaded:` en `systemctl status` cambió de `(/etc/fstab; generated)` a `(/etc/systemd/system/mnt-lab.mount; disabled)` — esa línea es como confirmás cuál está en vigencia.)

**A8.3** — Con una entrada `auto` común, el arranque *se bloquea* en `local-fs.target`/`remote-fs.target` mientras se intenta el montaje, y un servidor NFS inalcanzable se convierte en un cuelgue de varios minutos o en una caída al modo de emergencia. Con `noauto,x-systemd.automount`, systemd instala un placeholder autofs al arrancar — instantáneamente, sin E/S de red — y realiza el montaje real solo cuando un proceso toca la ruta por primera vez; el costo de un servidor inalcanzable lo paga ese proceso, no el arranque.

Las dos opciones que acotan son `x-systemd.device-timeout=` (cuánto esperar a que aparezca el dispositivo/`What=` subyacente antes de fallar) y `x-systemd.mount-timeout=` (cuánto puede tardar la operación de montaje en sí); `x-systemd.idle-timeout=` es la complementaria, que desmonta tras un período de inactividad.

**A8.4** — `mount(8)` ignora deliberadamente las opciones no reconocidas que empiezan con `x-` en vez de dar error, lo que reserva ese namespace para consumidores del espacio de usuario. Eso es lo que las hace seguras de poner en `fstab`: la entrada sigue funcionando con un `mount -a` común en un sistema sin systemd. Las lee **`systemd-fstab-generator`**, que las traduce a propiedades de unit (dependencias, timeouts, units automount). Relacionado: las opciones que empiezan con `x-` se guardan en `/run/mount/utab` y *no* se pasan al kernel, a diferencia de `X-mount.mkdir`/`X-mount.owner` sobre las que el propio `mount` actúa.

**A8.5** — Sí, sigue montado. `.automount` y `.mount` son **units separadas**: la unit automount solo es dueña del punto de disparo autofs que *causa* que la unit mount arranque al accederse. Detener el automount quita el disparador; la ya activa `mnt-lab.mount` queda intacta. Para terminar sin nada montado tenés que detener ambas (`systemctl stop mnt-lab.automount mnt-lab.mount`) — que es exactamente el orden usado en el Ejercicio 10, porque detener primero el mount permitiría que un acceso posterior lo volviera a disparar a través del automount todavía activo.

---

### Ejercicio 9

**A9.1** — Porque los scripts y las corridas de gestión de configuración se ramifican según el estado de salida, no según la prosa, y un mensaje en stderr es invisible para `set -e`, para el `failed_when` de Ansible y para un gate de CI a menos que el estado sea distinto de cero. `mount` devuelve una máscara de bits (`1` permisos/uso, `2` error del sistema, `4` error interno, `8` interrupción del usuario, **16** problemas al escribir/bloquear `mtab`, **32** falla de montaje, `64` algunos montajes tuvieron éxito y otros fallaron); `32` significa *este montaje falló*. Un `mount -a` que devuelve `32` en un script de aprovisionamiento debe abortar la corrida — si no, el host se declara "convergido" mientras falta un volumen de datos y la aplicación empieza a escribir en el directorio vacío del punto de montaje sobre el sistema de archivos raíz.

**A9.2** — `nofail`. El compromiso: convierte una falla dura en una *silenciosa*. El arranque tiene éxito y la aplicación arranca, pero el punto de montaje es un directorio vacío común sobre `/`, así que las escrituras aterrizan en el sistema de archivos raíz en lugar del volumen previsto — llenando `/` y desparramando datos que un montaje exitoso posterior va a ocultar. Aplicar `nofail` en todos lados es por lo tanto incorrecto; usála donde la disponibilidad le gane a la corrección (medios extraíbles, volúmenes scratch opcionales) y combinála con monitoreo del montaje, o con `x-systemd.automount` para que la falla aflore en el primer acceso.

**A9.3** — El **error de parseo** es más peligroso. `findmnt --verify` reporta el UUID faltante como una advertencia, pero la entrada igual se *entiende*: `mount -a` falla ruidosamente, systemd crea una unit fallida, y el problema es visible. Un error de parseo significa que la línea se **ignora silenciosamente** — no se intenta ningún montaje, no se genera ninguna unit, no se levanta ningún error al arrancar. El sistema de archivos simplemente no está ahí, y el primer síntoma es una aplicación escribiendo en el lugar equivocado. Un espacio perdido dentro del campo de opciones (el campo 4 se delimita por espacios en blanco, así que `defaults, noatime` se vuelven siete campos) es el caso clásico.

**A9.4** — Al arrancar, `systemd-fstab-generator` corre antes de que se compute la transacción, lee `/etc/fstab`, y escribe una unit `.mount` por entrada en `/run/systemd/generator/`. Las entradas sin `noauto` obtienen `WantedBy`/`RequiredBy` sobre `local-fs.target` (o `remote-fs.target` para `_netdev`) — **requerido**, no meramente deseado, a menos que esté presente `nofail`, en cuyo caso la dependencia se degrada a `Wants=` y solo orden. `local-fs.target` es un requisito duro de `sysinit.target`, del que dependen `basic.target` y por lo tanto `multi-user.target`. Cuando la unit mount falla, `local-fs.target` falla; la falla se propaga hacia arriba, la transacción para `default.target` no puede completarse, y systemd arranca `emergency.target` en su lugar — que ejecuta `emergency.service`, o sea `sulogin`, de ahí el pedido de contraseña de root. `nofail` corta la cadena en el primer eslabón; ese es todo el mecanismo.

**A9.5** — En orden:

```bash
findmnt --verify --verbose     # 1. syntax, targets, sources, filesystem types
mount -a ; echo $?             # 2. actually mount everything; demand status 0
systemctl daemon-reload        # 3. regenerate the systemd units from the new fstab
```

Vale la pena agregar un cuarto paso en cualquier host al que no puedas llegar fácilmente: `systemctl list-units --type=mount --failed` (o `findmnt --verify` de nuevo después del reload) antes de reiniciar.

</details>

---

## Fuentes oficiales

- **LPI, Objetivos del Examen 101-500 — 104.3 Control mounting and unmounting of filesystems** — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- `mount(8)`, `umount(8)`, `fstab(5)`, `findmnt(8)`, `blkid(8)`, `lsblk(8)`, `losetup(8)`, `fuser(1)` — páginas de manual de util-linux: <https://man7.org/linux/man-pages/man8/mount.8.html>, <https://man7.org/linux/man-pages/man5/fstab.5.html>, <https://man7.org/linux/man-pages/man8/findmnt.8.html>
- **Documentación del proyecto util-linux** — <https://github.com/util-linux/util-linux/blob/master/Documentation/>
- **Kernel de Linux — opciones de montaje de sistemas de archivos e interfaces `proc`** — <https://docs.kernel.org/filesystems/proc.html>, <https://docs.kernel.org/filesystems/sharedsubtree.html>, <https://docs.kernel.org/admin-guide/ext4.html>, <https://docs.kernel.org/filesystems/vfat.html>
- **systemd — `systemd.mount(5)`, `systemd.automount(5)`, `systemd-fstab-generator(8)`, `systemd-escape(1)`** — <https://www.freedesktop.org/software/systemd/man/latest/systemd.mount.html>, <https://www.freedesktop.org/software/systemd/man/latest/systemd.automount.html>, <https://www.freedesktop.org/software/systemd/man/latest/systemd-fstab-generator.html>
- **e2fsprogs — `tune2fs(8)`, `e2label(8)`, `mke2fs(8)`** — <https://e2fsprogs.sourceforge.net/>
- **Referencia de UDisks2 (medios extraíbles sin `fstab`)** — <https://storaged.org/doc/udisks2-api/latest/>