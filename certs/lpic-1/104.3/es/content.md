# 104.3 — Controlar el montaje y desmontaje de sistemas de archivos

**LPIC-1 · Examen 101-500 · Tema 104 (Dispositivos, sistemas de archivos Linux, Filesystem Hierarchy Standard) · Peso 4.69**

**Cobertura del objetivo:** mount/umount manual · configuración de montaje en el arranque · sistemas de archivos removibles montables por el usuario · etiquetas y UUID · conocimiento de las unidades de montaje de systemd.
**Términos y utilidades:** `/etc/fstab`, `/media/`, `mount`, `umount`, `blkid`, `lsblk`.

---

## 1. Motivación: el problema arquitectónico

Linux no expone el almacenamiento como unidades identificadas con letras. Expone un **único árbol dirigido**, y cada dispositivo de bloques, exportación de red, seudo-sistema de archivos y capa de contenedor tiene que ser *injertado* en ese árbol en un directorio llamado **punto de montaje**. La operación `mount` es el injerto; `umount` es la amputación. Todo lo que un sistema en producción hace con estado persistente — el directorio de datos de una base de datos, un almacén de imágenes de contenedor, un volumen de logs, una caché compartida de artefactos — depende de que el sistema de archivos correcto esté conectado en la ruta correcta, con las opciones correctas, en el momento correcto de la secuencia de arranque.

Esa dependencia es de donde salen las caídas. Cuatro clases de fallo explican la abrumadora mayoría de los incidentes relacionados con almacenamiento en hosts Linux:

**1. Nombres de dispositivo no deterministas.** Los nombres de dispositivo del kernel (`/dev/sda`, `/dev/nvme1n1`) se asignan en **orden de detección**, que es función del momento de inicialización de los drivers, de la enumeración PCIe y del orden de conexión del hipervisor — nada de lo cual es contractual. Una instancia en la nube que se detiene y se vuelve a iniciar puede regresar con el volumen que antes estaba en `/dev/sdb` ahora en `/dev/sdc`. Si `/etc/fstab` nombra dispositivos, pasa una de dos cosas: el montaje falla (visible, recuperable) o **se monta el sistema de archivos equivocado en la ruta correcta** (invisible, catastrófico — el directorio de datos de una réplica montado donde corresponde el del primario).

**2. La sombra del punto de montaje vacío.** Si `/srv/data` contiene archivos y el montaje falla, la aplicación no da error: escribe alegremente en el directorio *subyacente* del sistema de archivos raíz. El servicio está "arriba", los datos están en el lugar equivocado, el monitoreo está en verde, y el sistema de archivos raíz se llena horas después. El caso inverso es igual de común: un montaje se realiza *encima* de un directorio que ya tenía datos, y esos datos quedan inalcanzables (no borrados — ensombrecidos) hasta que se desmonta el sistema de archivos.

**3. Entradas de fstab que bloquean el arranque.** Una entrada de `/etc/fstab` sin `nofail` es una **dependencia dura de arranque**. `systemd` espera el dispositivo (90 s por defecto), luego deja la máquina en modo de emergencia y pide la contraseña de root en una consola que no tenés. En una instancia cloud sin consola esto es funcionalmente idéntico a destruir la máquina. Editar una línea de fstab es una de las pocas formas que quedan de dejar un host Linux inutilizable de manera remota.

**4. Desconexión sucia.** Las páginas sucias de un sistema de archivos viven en la caché de páginas. `umount` las vuelca y marca el superbloque como limpio; arrancar el dispositivo de un tirón, o hacer `umount -l` sobre un sistema de archivos con escritores activos, no. El resultado es, en el mejor caso, un replay del journal, y en el peor, corrupción silenciosa — y, para XFS/ext4 sobre almacenamiento compartido, un sistema de archivos que otro nodo monta mientras el primero todavía lo retiene.

**El encuadre SRE:** un montaje es una *declaración de dependencia entre un servicio y un recurso durable*, y debe expresarse con un identificador estable, un timeout acotado, una política de fallo explícita y un paso de verificación. `/etc/fstab` es el archivo de infraestructura-como-código más antiguo del sistema. Tratalo como tal.

---

## 2. Mecánica: qué ocurre realmente durante un montaje

### 2.1 La capa VFS

La capa **Virtual File System** del kernel es una abstracción que permite que `open()`, `read()` y `stat()` funcionen de forma idéntica sobre ext4, XFS, NFS, tmpfs y procfs. Sus cuatro objetos centrales:

| Objeto | Representa | Ciclo de vida |
|---|---|---|
| `struct super_block` | Una instancia de sistema de archivos montado (los metadatos en disco: tamaño de bloque, UUID, flags de características, opciones por fs) | Uno por *sistema de archivos*, compartido por todos sus montajes |
| `struct inode` | Un objeto archivo (metadatos, sin nombre) | Cacheado; uno por archivo por superbloque |
| `struct dentry` | Un componente de ruta; asocia un nombre a un inodo | Cacheado agresivamente (la dcache) |
| `struct file` | Una descripción de archivo abierto (offset, flags) | Por cada llamada a `open()` |
| `struct mount` | Una *conexión* de un superbloque a un namespace en una ruta | Una por punto de montaje |

La última distinción es la que hace tropezar a la gente: un único sistema de archivos (un superbloque) puede estar conectado en muchos puntos simultáneamente (bind mounts). **Algunas opciones pertenecen al superbloque y por lo tanto son globales a todas las conexiones; otras pertenecen a la conexión individual.**

| Clase de opción | Ejemplos | Alcance | ¿Puede diferir por bind mount? |
|---|---|---|---|
| Flags VFS / por montaje | `ro`, `rw`, `nosuid`, `nodev`, `noexec`, `noatime`, `relatime`, `nodiratime`, `sync`, `nosymfollow` | `struct mount` | **Sí** |
| Opciones de superbloque / por fs | `data=ordered`, `journal_checksum`, `discard`, `barrier`, `inode64`, `allocsize=`, `errors=remount-ro` | `struct super_block` | **No** — cambiarla la cambia en todas partes |
| Opciones solo de espacio de usuario | `user`, `users`, `owner`, `group`, `noauto`, `_netdev`, `x-systemd.*`, `comment=` | `/run/mount/utab` | N/A (nunca llegan al kernel) |

Consecuencia con la que te vas a encontrar en la práctica: podés hacer un bind mount de solo lectura de `/srv/data` en `/export/data` mientras sigue en lectura-escritura en `/srv/data`, pero **no podés** tener `discard` en uno y no en el otro.

### 2.2 El camino de la llamada al sistema

`mount(8)` es un envoltorio delgado sobre `libmount`. La llamada al sistema clásica es:

```c
int mount(const char *source, const char *target, const char *filesystemtype,
          unsigned long mountflags, const void *data);
```

Desde Linux 5.2 existe una segunda API, descompuesta — `fsopen(2)`, `fsconfig(2)`, `fsmount(2)`, `move_mount(2)` — que separa *crear un contexto de sistema de archivos configurado* de *conectarlo al árbol*, y devuelve cadenas de error reales en lugar de un único `EINVAL`. `mount(8)` de util-linux 2.39+ la usa cuando está disponible. Por eso los fallos de montaje modernos a veces producen un diagnóstico específico y a veces siguen produciendo el infame:

```
mount: /mnt/data: wrong fs type, bad option, bad superblock on /dev/sdb1,
       missing codepage or helper program, or other error.
       dmesg(1) may have more information after failed mount system call.
```

Ese mensaje significa "el kernel devolvió `EINVAL` y no puedo decirte por qué". **Seguilo siempre con `dmesg`.**

### 2.3 Dónde vive la tabla de montaje

| Ruta | Contenido | Notas |
|---|---|---|
| `/proc/self/mounts` | Vista del kernel del namespace de montaje *de este proceso* | Autoritativa para la opinión del kernel |
| `/etc/mtab` | Enlace simbólico → `/proc/self/mounts` en toda distro moderna | Históricamente un archivo real; nunca lo edites |
| `/proc/self/mountinfo` | Vista del kernel **más** IDs de montaje, propagación, raíz del subárbol | La que hay que parsear; `findmnt` lee esta |
| `/run/mount/utab` | Opciones solo de espacio de usuario (`user=`, `x-systemd.*`, `helper=`) | Complementa a mountinfo |
| `/etc/fstab` | Estado deseado, no estado actual | Consumido por `mount -a` y el generador de systemd |

Una línea de `mountinfo`, decodificada:

```
$ grep ' /srv/data ' /proc/self/mountinfo
142 60 253:2 / /srv/data rw,noatime,nodev,nosuid shared:78 - xfs /dev/mapper/vg_data-lv_data rw,attr2,inode64,logbufs=8,logbsize=32k,noquota
```

| Campo | Valor | Significado |
|---|---|---|
| 1 | `142` | ID de montaje |
| 2 | `60` | ID de montaje padre (→ esto está montado bajo el montaje 60) |
| 3 | `253:2` | major:minor del dispositivo de respaldo |
| 4 | `/` | raíz del montaje *dentro* del sistema de archivos (`/` = todo el fs; una subruta = bind mount de un subárbol) |
| 5 | `/srv/data` | punto de montaje en el namespace |
| 6 | `rw,noatime,nodev,nosuid` | opciones **por montaje** (VFS) |
| 7..n | `shared:78` | campos opcionales de propagación (`shared:`, `master:`, `propagate_from:`, `unbindable`) |
| — | `-` | separador |
| n+1 | `xfs` | tipo de sistema de archivos |
| n+2 | `/dev/mapper/...` | origen del montaje |
| n+3 | `rw,attr2,inode64,...` | opciones de **superbloque** |

El campo 6 frente al último campo es la manera práctica de responder "¿este montaje es de solo lectura, o el sistema de archivos es de solo lectura?".

### 2.4 Subárboles compartidos y propagación

Cada montaje lleva un **tipo de propagación** que decide si los montajes creados debajo de él se replican en los namespaces pares:

| Tipo | Flag | Comportamiento |
|---|---|---|
| `shared` | `--make-shared` | Los eventos de montaje/desmontaje se propagan **en ambos sentidos** entre pares |
| `private` | `--make-private` | Sin propagación |
| `slave` | `--make-slave` | Recibe eventos del maestro, no envía ninguno de vuelta |
| `unbindable` | `--make-unbindable` | No puede ser objeto de bind mount (bloquea explosiones de bind recursivo) |

El prefijo `r` (`--make-rshared`) aplica de forma recursiva. `systemd` establece `/` como `shared` en PID 1. Esto importa directamente para el trabajo con CNCF: un plugin de nodo CSI o un volumen con `mountPropagation: Bidirectional` en Kubernetes solo funciona porque el `/` del host es `rshared` y el runtime de contenedores no lo sobreescribe con `MountFlags=slave`.

```
$ findmnt -o TARGET,PROPAGATION / /var/lib/kubelet
TARGET          PROPAGATION
/               shared
/var/lib/kubelet shared
```

---

## 3. Identificar el dispositivo: nombres, LABEL, UUID, PARTUUID

Esta es la decisión de mayor apalancamiento de todo el tema.

| Identificador | Escrito en fstab como | ¿Sobrevive un reordenamiento? | ¿Sobrevive a `mkfs`? | ¿Sobrevive a clonar/`dd`? | Se define con | Notas |
|---|---|---|---|---|---|---|
| Nombre de kernel `/dev/sdb1` | `/dev/sdb1` | ❌ | ✔ (el nombre no está en el fs) | ✔ | — | **Nunca lo uses en fstab** en hosts multi-disco o en la nube |
| **UUID** del sistema de archivos | `UUID=…` | ✔ | ❌ (se regenera) | ❌ **colisiona** | `tune2fs -U`, `xfs_admin -U`, `mkfs` | La opción por defecto y correcta |
| **LABEL** del sistema de archivos | `LABEL=…` | ✔ | ❌ | ❌ **colisiona** | `e2label`, `xfs_admin -L`, `fatlabel` | Legible por humanos; debe ser única por host |
| **PARTUUID** (GPT) | `PARTUUID=…` | ✔ | ✔ | ❌ colisiona | `sgdisk -u`, `sfdisk --part-uuid` | Sobrevive al reformateo — adecuado para automatización que recrea sistemas de archivos |
| **PARTLABEL** (GPT) | `PARTLABEL=…` | ✔ | ✔ | ❌ colisiona | `sgdisk -c`, `sfdisk --part-label` | Lo mismo, legible por humanos |
| `/dev/disk/by-id/…` | ruta completa | ✔ | ✔ | ✔ (el serial es por dispositivo) | udev, a partir del serial del dispositivo | Lo mejor para "este disco físico", p. ej. ZFS/Ceph |
| `/dev/disk/by-path/…` | ruta completa | ✔ (estable por topología) | ✔ | ✔ | udev, a partir de la topología del bus | Estable por *slot*, no por disco |
| LVM `/dev/vg/lv` | ruta completa | ✔ | ✔ | ⚠ el UUID del VG colisiona | metadatos LVM | Estable; LVM lo resuelve |

> **La trampa del clon.** `dd`, `virt-clone` y las instantáneas de volumen copian el superbloque, y por lo tanto el UUID y el LABEL. Dos sistemas de archivos XFS con UUID idéntico en un host: el segundo `mount` falla directamente. Dos ext4: el segundo puede montarse, y `UUID=` en fstab se convierte en una moneda al aire. Siempre volvé a estampar un clon antes de conectarlo.

**Leer identificadores**

```
$ lsblk -f
NAME          FSTYPE      FSVER LABEL  UUID                                 FSAVAIL FSUSE% MOUNTPOINTS
nvme0n1                                                                                    
├─nvme0n1p1   vfat        FAT32 EFI    A1B2-C3D4                             478.4M     6% /boot/efi
├─nvme0n1p2   ext4        1.0   boot   6f4a2e91-7c33-4a0e-9c11-2b7a5f0d81ce  598.1M    30% /boot
└─nvme0n1p3   LVM2_member LVM2  001    K3jd9f-1QpZ-8Lmc-0oTb-Yh2V-wQ4s-Rz7Nn                
  ├─vg0-root  ext4        1.0   root   9c8b7a65-0d1e-4f22-8a90-3c5b7e1d4402   24.1G    31% /
  └─vg0-swap  swap        1     swap   1a2b3c4d-5e6f-4071-8293-a4b5c6d7e8f9                [SWAP]
nvme1n1       xfs               data   b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752  198.3G     1% /srv/data
```

```
$ sudo blkid /dev/nvme1n1
/dev/nvme1n1: LABEL="data" UUID="b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752" BLOCK_SIZE="512" TYPE="xfs"

$ sudo blkid -s UUID -o value /dev/nvme1n1
b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752

$ sudo blkid -L data
/dev/nvme1n1

$ sudo blkid -U b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752
/dev/nvme1n1
```

`blkid` lee la firma en disco (y una caché en `/run/blkid/blkid.tab`); `lsblk -f` lee la base de datos de udev. Cuando no coinciden, `blkid -p -o udev /dev/X` (sondeo de bajo nivel, salteando la caché) es el desempate.

```
$ ls -l /dev/disk/by-uuid/
total 0
lrwxrwxrwx 1 root root 13 Aug 26 09:14 1a2b3c4d-5e6f-4071-8293-a4b5c6d7e8f9 -> ../../dm-1
lrwxrwxrwx 1 root root 13 Aug 26 09:14 6f4a2e91-7c33-4a0e-9c11-2b7a5f0d81ce -> ../../nvme0n1p2
lrwxrwxrwx 1 root root 13 Aug 26 09:14 9c8b7a65-0d1e-4f22-8a90-3c5b7e1d4402 -> ../../dm-0
lrwxrwxrwx 1 root root 13 Aug 26 09:14 b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752 -> ../../nvme1n1
lrwxrwxrwx 1 root root 15 Aug 26 09:14 A1B2-C3D4 -> ../../nvme0n1p1
```

**Volver a estampar un sistema de archivos clonado**

```
# ext4 — filesystem must be unmounted and clean
$ sudo tune2fs -U random /dev/sdb1
tune2fs 1.47.0 (5-Feb-2023)
Setting the UUID on this filesystem could take some time.
Proceed anyway (or wait 5 seconds to proceed) ? (y,N) y
$ sudo e2label /dev/sdb1 data-replica

# XFS — must be unmounted; log must be clean (mount+umount once if it is not)
$ sudo xfs_admin -U generate -L data-replica /dev/sdb1
Clearing log and setting UUID
writing all SBs
new UUID = 4f2c1a90-8b7d-4e11-a2c6-90d5e3f81b44
```

---

## 4. Montaje manual: la superficie completa del comando

### 4.1 Formas básicas

```
$ sudo mount /dev/nvme1n1 /srv/data                      # explicit device + target
$ sudo mount -t xfs /dev/nvme1n1 /srv/data               # explicit type (skips probing)
$ sudo mount UUID=b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752 /srv/data
$ sudo mount LABEL=data /srv/data
$ sudo mount /srv/data                                   # target only → looks up /etc/fstab
$ sudo mount -a                                          # everything in fstab not already mounted
$ sudo mount -a -t xfs,ext4                              # restrict -a to types
$ sudo mount -a -O no_netdev                             # restrict -a by fstab option
```

Sin `-t`, `mount` llama a `libblkid` para sondear la firma en disco; `-t` saltea eso. `-t auto` es el valor por defecto explícito. `-t nfs4,cifs` en contexto de `-a` filtra en lugar de forzar.

### 4.2 Inspeccionar los montajes actuales

```
$ mount | column -t | head -6
sysfs      on  /sys              type  sysfs       (rw,nosuid,nodev,noexec,relatime)
proc       on  /proc             type  proc        (rw,nosuid,nodev,noexec,relatime)
devtmpfs   on  /dev              type  devtmpfs    (rw,nosuid,size=4096k,nr_inodes=2043177,mode=755)
tmpfs      on  /dev/shm          type  tmpfs       (rw,nosuid,nodev,inode64)
/dev/mapper/vg0-root  on  /      type  ext4        (rw,relatime,errors=remount-ro)
/dev/nvme1n1  on  /srv/data      type  xfs         (rw,noatime,nodev,nosuid,attr2,inode64,logbufs=8,logbsize=32k,noquota)
```

`mount` a secas imprime `/proc/self/mounts` — ruidoso. **`findmnt` es la herramienta correcta** y debería ser tu reflejo:

```
$ findmnt /srv/data
TARGET    SOURCE       FSTYPE OPTIONS
/srv/data /dev/nvme1n1 xfs    rw,noatime,nodev,nosuid,attr2,inode64,logbufs=8,logbsize=32k,noquota

$ findmnt -o TARGET,SOURCE,FSTYPE,VFS-OPTIONS,FS-OPTIONS /srv/data
TARGET    SOURCE       FSTYPE VFS-OPTIONS               FS-OPTIONS
/srv/data /dev/nvme1n1 xfs    rw,noatime,nodev,nosuid   rw,attr2,inode64,logbufs=8,logbsize=32k,noquota

$ findmnt --real --df
SOURCE               FSTYPE SIZE  USED AVAIL USE% TARGET
/dev/mapper/vg0-root ext4    40G 12.4G 25.6G  33% /
/dev/nvme0n1p2       ext4   974M  291M  598M  30% /boot
/dev/nvme0n1p1       vfat   511M   33M  478M   6% /boot/efi
/dev/nvme1n1         xfs    200G  1.7G  198G   1% /srv/data

$ findmnt --fstab                # what SHOULD be mounted
$ findmnt --mtab                 # what IS mounted (default)
$ findmnt -S UUID=b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752   # find by source
$ findmnt -t nfs4,nfs            # find by type
$ findmnt --poll --target /srv/data   # block and stream mount-table changes
```

`findmnt --poll` es excepcionalmente útil en respuesta a incidentes: imprime una línea de evento en el instante en que algo se monta, se desmonta o se vuelve a montar sobre tu objetivo.

### 4.3 El catálogo de opciones

`defaults` = `rw,suid,dev,exec,auto,nouser,async`.

| Opción | Efecto | Guía para producción |
|---|---|---|
| `rw` / `ro` | Montaje en lectura-escritura / solo lectura | `ro` para datos de referencia, `/boot` en builds endurecidos, y para aquietar antes de una instantánea |
| `suid` / `nosuid` | Respetar / ignorar los bits setuid y setgid | `nosuid` en todo sistema de archivos que acepte contenido no confiable: `/tmp`, `/var/tmp`, `/dev/shm`, `/home`, todo medio removible |
| `dev` / `nodev` | Respetar / ignorar archivos especiales de dispositivo | `nodev` en todas partes excepto `/dev`. Un nodo de dispositivo en un fs escribible por el usuario es una vía de escalada a root |
| `exec` / `noexec` | Permitir / bloquear la ejecución directa | `noexec` en `/tmp`, `/var/tmp`, `/dev/shm`. **No es una frontera de seguridad** — `ld.so /tmp/x` sigue funcionando — pero frena al 90% perezoso |
| `auto` / `noauto` | Incluido en / excluido de `mount -a` | `noauto` para medios removibles y montajes bajo demanda |
| `nouser` / `user` / `users` | Quién puede montar | `user`: cualquier usuario puede montar, **solo ese usuario puede desmontar**. `users`: cualquier usuario puede montar y cualquier usuario puede desmontar |
| `owner` / `group` | Un no-root puede montar si es dueño del *nodo de dispositivo* / está en su grupo | Se combina con reglas de udev para medios removibles |
| `async` / `sync` | Escrituras con buffer / sincrónicas | `sync` cuesta entre 10 y 100× el rendimiento. Usá `sync` solo en medios removibles que los usuarios arrancan de un tirón |
| `dirsync` | Actualizaciones de directorio sincrónicas | Término medio más barato que un `sync` completo |
| `atime` / `noatime` / `relatime` / `nodiratime` | Política de actualización del tiempo de acceso | Ver la tabla siguiente |
| `lazytime` | Marcas de tiempo mantenidas en memoria, volcadas junto a otra E/S o cada 24 h | Combinalo con `relatime` en cargas de trabajo con metadatos de escritura intensiva |
| `nofail` | El arranque continúa si el montaje falla | **Obligatorio en todo montaje no esencial de un host sin consola** |
| `_netdev` | El sistema de archivos necesita la red | Ordena después de `network-online.target`, dentro de `remote-fs.target` |
| `nosymfollow` | Los enlaces simbólicos de este montaje no se siguen (Linux 5.10+) | Endurecimiento para directorios de subida compartidos |
| `errors=continue\|remount-ro\|panic` | Comportamiento de ext2/3/4 ante un error | `remount-ro` es el valor sensato por defecto; `panic` para nodos en clúster que deben aislarse a sí mismos |
| `discard` / `nodiscard` | TRIM en línea | Preferí `nodiscard` + `fstrim.timer`; el discard en línea produce atascos en muchos SSD |
| `X-mount.mkdir[=mode]` | Crear el punto de montaje si falta (util-linux 2.35+) | Práctico en aprovisionamiento; `X-` = no se almacena en utab |
| `X-mount.owner=`, `X-mount.group=`, `X-mount.mode=` | Definir propiedad/modo del punto de montaje (2.39+) | |
| `x-systemd.*` | Directivas del generador de systemd (§6) | `x-` = se almacena en utab, legible por systemd |

**Compromisos de la política de tiempo de acceso**

| Opción | ¿Escribe al leer? | Conforme a POSIX | Rompe |
|---|---|---|---|
| `strictatime` | En cada lectura | ✔ | El rendimiento en cargas de lectura intensiva |
| `relatime` (por defecto en el kernel desde 2.6.30) | Solo si atime < mtime/ctime, o atime tiene más de 24 h | Aproximadamente | Nada en la práctica |
| `nodiratime` | Suprime solo el atime de directorios | Parcialmente | Nada |
| `noatime` | Nunca | ✘ | La detección de "correo nuevo" de `mutt`/`mbox`, algunas políticas de tmpwatch |

Para una base de datos o un almacén de imágenes de contenedor, `noatime` es correcto y medible. Para un servidor de propósito general, `relatime` ya está bien — el consejo de "`noatime` por rendimiento" es en gran medida anterior a `relatime`.

### 4.4 Volver a montar (remount)

```
$ sudo mount -o remount,ro /srv/data
$ sudo mount -o remount,rw /                       # classic emergency-shell recovery
$ sudo mount -o remount /srv/data                  # re-apply fstab options
```

Un remount **no** restablece a sus valores por defecto las opciones no especificadas; `mount` fusiona la línea de comandos con lo que encuentra en `/etc/fstab` y `/run/mount/utab`. Desde util-linux 2.32 podés controlar esa fusión explícitamente:

```
$ sudo mount -o remount --options-mode=ignore --options-source-force -o rw,noatime /srv/data
```

| `--options-mode` | Resultado |
|---|---|
| `ignore` | Usar solo la línea de comandos |
| `append` | Primero las opciones de fstab, la línea de comandos al final (gana) |
| `prepend` | Primero la línea de comandos, fstab al final (gana) |
| `replace` | La línea de comandos reemplaza a fstab (por defecto) |

**No lo des por sentado — verificá con `findmnt` después de cada remount.** Esta es la fuente número uno de "puse `ro` y sigue en `rw`".

### 4.5 Bind mounts, loop mounts, overlays

```
# Bind: attach an existing subtree at a second path (same superblock)
$ sudo mount --bind /srv/data/pg /var/lib/postgresql/16/main
$ sudo mount --rbind /srv/data /export/data          # recursive: carries nested mounts
$ sudo mount --move /mnt/staging /srv/data           # relocate a mount, no unmount

# Read-only bind. util-linux >= 2.27 does the required second remount for you:
$ sudo mount -o bind,ro /srv/reference /export/reference
# On older util-linux this is two steps and the first one is NOT read-only:
$ sudo mount --bind /srv/reference /export/reference
$ sudo mount -o remount,bind,ro /export/reference

# Loop: mount a file as if it were a block device
$ sudo mount -o loop,ro debian-12.5.0-amd64-netinst.iso /mnt/iso
$ sudo mount -t iso9660 -o ro,loop image.iso /mnt/iso
$ losetup -a
/dev/loop0: [0053]:1835013 (/root/debian-12.5.0-amd64-netinst.iso)

# Overlay: the container-image primitive, exposed directly
$ sudo mkdir -p /ovl/{lower,upper,work,merged}
$ sudo mount -t overlay overlay \
    -o lowerdir=/ovl/lower,upperdir=/ovl/upper,workdir=/ovl/work \
    /ovl/merged

# tmpfs: RAM-backed, sized, with explicit permissions
$ sudo mount -t tmpfs -o size=2G,mode=1777,nosuid,nodev,noexec tmpfs /tmp
```

### 4.6 Ejecuciones en seco

```
$ sudo mount --fake --verbose /srv/data
mount: /srv/data does not contain SELinux labels.
mount: /dev/nvme1n1 mounted on /srv/data.

$ sudo mount -a --fake --verbose
/                        : ignored
/boot                    : already mounted
/srv/data                : successfully mounted
```

`--fake` parsea todo y realiza el trabajo en espacio de usuario, pero saltea la llamada `mount(2)`. Detecta errores de sintaxis y puntos de montaje faltantes; **no** prueba que el sistema de archivos sea montable.

---

## 5. `/etc/fstab`: la anatomía completa

### 5.1 Semántica de los campos

```
<file system>   <mount point>   <type>   <options>   <dump>   <pass>
     1                2            3          4         5        6
```

| # | Campo | Valores | Notas |
|---|---|---|---|
| 1 | Origen | `UUID=`, `LABEL=`, `PARTUUID=`, `PARTLABEL=`, ruta de dispositivo, `server:/export`, `//server/share`, `tmpfs`, `overlay`, `none` | Los espacios en blanco deben escaparse como `\040` |
| 2 | Destino | Ruta absoluta, o `none` para swap/orígenes bind | Debe existir (o usar `X-mount.mkdir`) |
| 3 | Tipo | `ext4`, `xfs`, `btrfs`, `vfat`, `nfs4`, `cifs`, `tmpfs`, `swap`, `auto`, `none` (para bind) | `auto` sondea; cuesta un poco de tiempo de arranque |
| 4 | Opciones | Separadas por comas, **sin espacios** | `defaults` si necesitás un marcador de posición |
| 5 | `dump` | `0` o `1` | Consumido por `dump(8)`, que nadie ejecuta. Siempre `0` |
| 6 | `pass` (orden de fsck) | `0` = nunca chequear · `1` = chequear primero (solo la raíz) · `2` = chequear después de los `1`, en paralelo entre discos distintos | `0` para red, tmpfs, bind, btrfs (se autochequea) y swap |

### 5.2 Un `/etc/fstab` completo y de producción

```
# /etc/fstab — host: db-prod-03  ·  managed by Ansible (role: baseline/storage)
# Rebuild:  ansible-playbook site.yml --tags storage --limit db-prod-03
#
# <file system>                              <mount point>       <type>  <options>                                                                       <dump> <pass>

# --- Root and boot -----------------------------------------------------------
UUID=9c8b7a65-0d1e-4f22-8a90-3c5b7e1d4402    /                   ext4    rw,relatime,errors=remount-ro                                                    0      1
UUID=6f4a2e91-7c33-4a0e-9c11-2b7a5f0d81ce    /boot               ext4    rw,relatime,nodev,nosuid,noexec                                                  0      2
UUID=A1B2-C3D4                               /boot/efi           vfat    rw,relatime,nodev,nosuid,noexec,umask=0077,shortname=winnt,errors=remount-ro     0      2

# --- Swap --------------------------------------------------------------------
UUID=1a2b3c4d-5e6f-4071-8293-a4b5c6d7e8f9    none                swap    sw,pri=10                                                                        0      0

# --- Hardened scratch space (CIS 1.1.x) --------------------------------------
tmpfs                                        /tmp                tmpfs   rw,nosuid,nodev,noexec,relatime,size=4G,mode=1777                                 0      0
tmpfs                                        /dev/shm            tmpfs   rw,nosuid,nodev,noexec,relatime,size=1G                                          0      0
/tmp                                         /var/tmp            none    rw,nosuid,nodev,noexec,bind                                                      0      0

# --- Database data volume ----------------------------------------------------
# nofail + device-timeout: a detached EBS/Cinder volume must NOT block boot.
UUID=b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752    /srv/data           xfs     rw,noatime,nodev,nosuid,logbsize=256k,nofail,x-systemd.device-timeout=15s        0      2

# PostgreSQL expects its data at the packaged path; bind instead of relocating.
/srv/data/pgdata                             /var/lib/postgresql none    rw,bind,x-systemd.requires-mounts-for=/srv/data                                  0      0

# --- WAL archive on a separate spindle, read-mostly ---------------------------
PARTUUID=1f0d5c3b-2a44-4e77-9b81-6c0e2f4a7d99 /srv/wal-archive   xfs     rw,noatime,nodev,nosuid,noexec,nofail,x-systemd.device-timeout=15s               0      2

# --- Shared artifact store (NFS, lazily mounted on first access) --------------
nfs-01.internal:/exports/artifacts           /mnt/artifacts      nfs4    rw,noatime,nodev,nosuid,_netdev,noauto,x-systemd.automount,x-systemd.idle-timeout=600,x-systemd.mount-timeout=30,hard,proto=tcp,rsize=1048576,wsize=1048576  0  0

# --- Read-only reference dataset, mounted from an image file -----------------
/opt/images/geoip-2026-08.squashfs           /opt/geoip          squashfs ro,loop,nodev,nosuid,noexec,nofail                                              0      0

# --- Removable media: any console user may mount and unmount ------------------
LABEL=FIELD-BACKUP                           /media/field-backup auto    rw,users,noauto,nofail,nodev,nosuid,noexec,sync,uid=1000,gid=1000,umask=0007     0      0
```

Puntos que vale la pena interiorizar de ese archivo:

- `/var/tmp` es un **bind de `/tmp`** — tipo `none`, opción `bind`, pass `0`. Esa es la sintaxis de fstab para un bind mount.
- El bind de PostgreSQL lleva `x-systemd.requires-mounts-for=/srv/data`, porque si no systemd podría intentar el bind antes de que el volumen XFS esté arriba y hacer bind de un directorio vacío. Este es el clásico bug autoinfligido de pérdida de datos.
- Toda entrada removible y de red lleva `nofail`. Toda entrada respaldada por un dispositivo que no sea `/` lleva un `x-systemd.device-timeout`.
- La entrada NFS es `noauto,x-systemd.automount`: nada bloquea el arranque; el montaje ocurre en el primer acceso a `/mnt/artifacts` y se desarma tras 600 s de inactividad.
- `pass` es `2` para volúmenes de datos locales y `0` para todo lo respaldado por red, loop o bind.

### 5.3 Reglas de higiene de fstab

1. **Editá con un respaldo y validá antes de reiniciar.** `cp /etc/fstab /etc/fstab.$(date +%F-%H%M)`.
2. **Nunca dejes `/` sin `nofail`, y nunca le pongas `nofail` a `/`** — el fallo del sistema de archivos raíz debe detener el arranque.
3. **Después de editar, avisale a systemd:** `sudo systemctl daemon-reload`. El generador de fstab solo se ejecuta en el arranque y en cada recarga; `mount -a` por sí solo deja la vista de systemd desactualizada, y la próxima operación de `systemctl` puede desmontar lo que acabás de montar.
4. **`mount -a` es una prueba necesaria pero insuficiente.** Demuestra que las entradas se parsean y que los dispositivos están presentes *ahora*; no demuestra nada sobre el ordenamiento en el arranque ni sobre la disponibilidad del dispositivo en el arranque.

```
$ sudo cp -a /etc/fstab /etc/fstab.2026-08-26-0914
$ sudoedit /etc/fstab
$ sudo findmnt --verify --verbose
$ sudo mount -a
$ sudo systemctl daemon-reload
$ findmnt --fstab --evaluate
```

---

## 6. Unidades de montaje de systemd

### 6.1 El generador

`systemd-fstab-generator(8)` se ejecuta en el arranque temprano y en cada `daemon-reload`, y convierte cada línea de `/etc/fstab` en una unidad `.mount` transitoria (y, donde se solicite, `.automount`) bajo `/run/systemd/generator/`. **fstab no es "el camino heredado" — en un host con systemd es un front-end para las unidades de montaje.** Todo lo que escribas en fstab se convierte en una unidad; podés leer la unidad generada para ver exactamente qué entendió systemd.

Los nombres de unidad son la ruta de montaje con `/` reemplazado por `-`, escapada:

```
$ systemd-escape -p --suffix=mount /srv/data
srv-data.mount
$ systemd-escape -p --suffix=mount /var/lib/postgresql
var-lib-postgresql.mount
$ systemd-escape -u -p --suffix=mount srv-data.mount     # unescape
/srv/data
```

El montaje raíz tiene el nombre especial `-.mount`.

```
$ systemctl list-units --type=mount
UNIT                     LOAD   ACTIVE SUB     DESCRIPTION
-.mount                  loaded active mounted Root Mount
boot.mount               loaded active mounted /boot
boot-efi.mount           loaded active mounted /boot/efi
dev-shm.mount            loaded active mounted /dev/shm
srv-data.mount           loaded active mounted /srv/data
srv-wal\x2darchive.mount loaded active mounted /srv/wal-archive
tmp.mount                loaded active mounted /tmp
var-lib-postgresql.mount loaded active mounted /var/lib/postgresql

$ systemctl cat srv-data.mount
# /run/systemd/generator/srv-data.mount
# Automatically generated by systemd-fstab-generator

[Unit]
Documentation=man:fstab(5) man:systemd-fstab-generator(8)
SourcePath=/etc/fstab
Before=local-fs.target

[Mount]
Where=/srv/data
What=/dev/disk/by-uuid/b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752
Type=xfs
Options=rw,noatime,nodev,nosuid,logbsize=256k,nofail,x-systemd.device-timeout=15s
TimeoutSec=15s

$ systemctl show -p After -p Requires -p WantedBy srv-data.mount
After=systemd-journald.socket system.slice -.mount local-fs-pre.target blockdev@dev-disk-by\x2duuid...target
Requires=-.mount
WantedBy=local-fs.target
```

### 6.2 Opciones `x-systemd.*` (fstab → directivas de unidad)

| Opción | Efecto generado |
|---|---|
| `x-systemd.automount` | Emitir también una unidad `.automount` — montar en el primer acceso |
| `x-systemd.idle-timeout=600` | El automount desmonta tras 600 s de inactividad |
| `x-systemd.device-timeout=15s` | Cuánto esperar a que aparezca el *dispositivo* |
| `x-systemd.mount-timeout=30s` | Cuánto puede tardar la propia llamada a `mount(8)` |
| `x-systemd.requires=<unit>` | `Requires=` sobre una unidad arbitraria |
| `x-systemd.after=` / `x-systemd.before=` | Ordenamiento explícito |
| `x-systemd.requires-mounts-for=<path>` | Ordenar después de (y requerir) lo que provee `<path>` |
| `x-systemd.wanted-by=` / `x-systemd.required-by=` | Cambiar qué target lo trae |
| `x-systemd.makefs` | Ejecutar `mkfs` si el dispositivo no tiene sistema de archivos (**cercano a destructivo — solo para aprovisionamiento**) |
| `x-systemd.growfs` | Agrandar el sistema de archivos para llenar el dispositivo al montar |
| `x-systemd.rw-only` | No recurrir a un montaje de solo lectura ante un fallo |
| `x-systemd.device-bound=no` | No desmontar cuando el dispositivo de respaldo desaparece |
| `nofail` | Degradar de `Requires=` a `Wants=` y quitar la barrera de ordenamiento |
| `noauto` | No agregarlo al `Wants=` de ningún target |
| `_netdev` | Adjuntar a `remote-fs.target`, ordenar después de `network-online.target` |

### 6.3 Archivos de unidad nativos

Escribí unidades nativas cuando necesitás dependencias que fstab no puede expresar — un montaje que debe iniciar después de un servicio específico, o uno con semántica de `ExecStartPre` por delante.

**`/etc/systemd/system/srv-data.mount`**

```ini
[Unit]
Description=Primary data volume (XFS on nvme1n1)
Documentation=https://runbooks.internal/storage/srv-data
DefaultDependencies=no
Requires=blockdev@dev-disk-by\x2duuid-b7c9d2e4\x2d3f10\x2d4d5a\x2d9e88\x2d11ac33bd7752.target
After=blockdev@dev-disk-by\x2duuid-b7c9d2e4\x2d3f10\x2d4d5a\x2d9e88\x2d11ac33bd7752.target
After=local-fs-pre.target
Before=local-fs.target umount.target
Conflicts=umount.target

[Mount]
What=/dev/disk/by-uuid/b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752
Where=/srv/data
Type=xfs
Options=rw,noatime,nodev,nosuid,logbsize=256k
TimeoutSec=30s
DirectoryMode=0755
LazyUnmount=no
ForceUnmount=no

[Install]
WantedBy=local-fs.target
```

**`/etc/systemd/system/mnt-artifacts.automount`** (emparejada con un `.mount` del mismo nombre)

```ini
[Unit]
Description=Automount for the shared artifact store
Documentation=man:systemd.automount(5)
After=network-online.target
Wants=network-online.target

[Automount]
Where=/mnt/artifacts
DirectoryMode=0755
TimeoutIdleSec=600

[Install]
WantedBy=remote-fs.target
```

**`/etc/systemd/system/mnt-artifacts.mount`**

```ini
[Unit]
Description=Shared artifact store (NFSv4)
After=network-online.target
Wants=network-online.target

[Mount]
What=nfs-01.internal:/exports/artifacts
Where=/mnt/artifacts
Type=nfs4
Options=rw,noatime,nodev,nosuid,hard,proto=tcp,rsize=1048576,wsize=1048576
TimeoutSec=30s
```

**El nombre de archivo de la unidad debe coincidir con `Where=` después del escapado**, o systemd se niega a cargarla:

```
$ sudo systemd-analyze verify /etc/systemd/system/srv-data.mount
$ sudo systemctl daemon-reload
$ sudo systemctl enable --now srv-data.mount
Created symlink /etc/systemd/system/local-fs.target.wants/srv-data.mount → /etc/systemd/system/srv-data.mount.
$ systemctl status srv-data.mount
● srv-data.mount - Primary data volume (XFS on nvme1n1)
     Loaded: loaded (/etc/systemd/system/srv-data.mount; enabled; preset: disabled)
     Active: active (mounted) since Tue 2026-08-26 09:14:31 UTC; 4h 2min ago
      Where: /srv/data
       What: /dev/nvme1n1
      Tasks: 0 (limit: 38304)
     Memory: 132.0K
        CPU: 6ms
     CGroup: /system.slice/srv-data.mount
```

### 6.4 Hacer que un servicio dependa de un montaje

Nunca te apoyes solo en `After=srv-data.mount` dentro de un drop-in — usá `RequiresMountsFor=`, que resuelve la ruta hacia la unidad que la provee (generada por fstab o nativa):

**`/etc/systemd/system/postgresql@16-main.service.d/10-storage.conf`**

```ini
[Unit]
RequiresMountsFor=/var/lib/postgresql/16/main
```

Esa única línea convierte "la base de datos escribió en el sistema de archivos raíz porque el volumen llegó tarde" de un incidente a una dependencia de arranque.

### 6.5 Montajes transitorios

```
$ sudo systemd-mount --no-block /dev/sdc1 /mnt/inspect
$ sudo systemd-mount --list
$ sudo systemd-mount --automount=yes --timeout-idle-sec=300 /dev/sdc1 /mnt/inspect
$ sudo systemd-umount /mnt/inspect
```

`systemd-mount` crea una unidad transitoria en lugar de un montaje no gestionado, así que systemd lo desmontará limpiamente al apagar y no peleará con vos por él.

### 6.6 Elegir un mecanismo

| | `/etc/fstab` | Unidad `.mount` nativa | `.automount` | `autofs` | `udisks2` |
|---|---|---|---|---|---|
| Portable entre sistemas de init | ✔ | ✘ | ✘ | ✔ | ✔ |
| Montado en el arranque | ✔ | ✔ | al acceder | al acceder | al conectar/iniciar sesión |
| Ordenamiento rico de dependencias | vía `x-systemd.*` | ✔ completo | ✔ | ✘ | ✘ |
| Destinos con comodines / dirigidos por mapas | ✘ | ✘ | ✘ | ✔ (mapas `*`, `-hosts`) | ✘ |
| Sobrevive a un servidor NFS inestable en el arranque | con `noauto,x-systemd.automount` | con automount | ✔ | ✔ | N/A |
| Montajes de usuario sin privilegios | vía `user`/`users` | ✘ | ✘ | ✘ | ✔ (polkit) |
| Adecuado para | el 95% de los servidores | ordenamiento complejo | montajes de red poco usados | mapas grandes/dinámicos de home y shares | escritorios, laptops de campo |

---

## 7. Sistemas de archivos removibles y montables por el usuario

### 7.1 La vía de fstab: `user`, `users`, `owner`, `group`

| Opción | Quién puede montar | Quién puede desmontar | Implica |
|---|---|---|---|
| `user` | Cualquier usuario | **Solo el usuario que lo montó** | `noexec,nosuid,nodev` |
| `users` | Cualquier usuario | Cualquier usuario | `noexec,nosuid,nodev` |
| `owner` | El dueño del *nodo de dispositivo* | El mismo | `nosuid,nodev` |
| `group` | Los miembros del grupo del nodo de dispositivo | Los mismos | `nosuid,nodev` |

Las restricciones implícitas se aplican **primero**, así que el orden importa:

```
# noexec is in force — 'user' applied it and nothing overrode it
LABEL=USB   /media/usb  auto  rw,user,noauto  0 0

# exec is in force — it appears AFTER 'user' and wins
LABEL=USB   /media/usb  auto  rw,user,exec,noauto  0 0

# WRONG: 'user' re-applies its defaults after 'exec'
LABEL=USB   /media/usb  auto  rw,exec,user,noauto  0 0
```

Montar como usuario normal requiere que `mount` sea setuid root (lo es, en la mayoría de las distros) y una entrada coincidente en fstab — el kernel no consulta fstab, lo hace `mount(8)`:

```
$ id
uid=1000(sre) gid=1000(sre) groups=1000(sre),27(sudo),6(disk)

$ mount /media/field-backup
$ findmnt /media/field-backup
TARGET              SOURCE    FSTYPE OPTIONS
/media/field-backup /dev/sdc1 exfat  rw,nosuid,nodev,noexec,relatime,uid=1000,gid=1000,fmask=0007,dmask=0007,sync,user=sre

$ grep field-backup /run/mount/utab
SRC=/dev/sdc1 TARGET=/media/field-backup ROOT=/ OPTS=user=sre

$ umount /media/field-backup           # succeeds: user=sre matches
```

El campo `user=sre` en `/run/mount/utab` es precisamente cómo `umount` hace cumplir el "solo el usuario que montó puede desmontar". Notá también que FAT/exFAT/NTFS no tienen propiedad UNIX en disco, así que `uid=`, `gid=`, `umask=`/`fmask=`/`dmask=` son la manera de asignarla en el momento del montaje.

### 7.2 `/media` frente a `/mnt` (FHS)

| Ruta | Significado en el FHS |
|---|---|
| `/mnt` | Un único punto de montaje temporal para el **administrador del sistema** |
| `/media` | Directorio padre para puntos de montaje de **medios removibles**, un subdirectorio por dispositivo |
| `/run/media/$USER/<label>` | Donde `udisks2` realmente pone las cosas en escritorios modernos (por usuario, respaldado por tmpfs, desaparece al cerrar sesión) |

No montes datos de servicio de larga vida bajo ninguno de los dos. `/srv` (datos de servicio específicos del sitio) o una ruta propiedad de la aplicación es el hogar correcto.

### 7.3 La vía `udisks2` + polkit

Para usuarios interactivos, `udisks2` es la respuesta moderna: un demonio D-Bus privilegiado que monta a pedido bajo `/run/media/$USER/`, con la autorización decidida por polkit. Sin entrada en fstab, sin `mount` setuid.

```
$ udisksctl status
MODEL                     REVISION  SERIAL               DEVICE
--------------------------------------------------------------------------
SanDisk Ultra             1.00      4C530001120830108271 sdc

$ udisksctl mount --block-device /dev/sdc1
Mounted /dev/sdc1 at /run/media/sre/FIELD-BACKUP

$ findmnt /run/media/sre/FIELD-BACKUP
TARGET                        SOURCE    FSTYPE OPTIONS
/run/media/sre/FIELD-BACKUP   /dev/sdc1 exfat  rw,nosuid,nodev,relatime,uid=1000,gid=1000,...

$ udisksctl unmount --block-device /dev/sdc1
Unmounted /dev/sdc1.

$ udisksctl power-off --block-device /dev/sdc    # flush + safely detach the whole device
```

**Otorgar al grupo `storage` el derecho a montar dispositivos internos del sistema** — regla polkit completa, `/etc/polkit-1/rules.d/50-udisks-storage.rules`:

```javascript
/* Allow members of the 'storage' group to mount, unmount and eject
 * removable and system-internal block devices via udisks2 without a
 * password prompt. Deliberately does NOT grant filesystem-modify
 * (mkfs / partition table edits), which stays with the admin rules.
 *
 * Docs: https://www.freedesktop.org/software/polkit/docs/latest/polkit.8.html
 */
polkit.addRule(function (action, subject) {
    var allowed = [
        "org.freedesktop.udisks2.filesystem-mount",
        "org.freedesktop.udisks2.filesystem-mount-system",
        "org.freedesktop.udisks2.filesystem-unmount-others",
        "org.freedesktop.udisks2.eject-media",
        "org.freedesktop.udisks2.power-off-drive"
    ];

    if (allowed.indexOf(action.id) >= 0 && subject.isInGroup("storage")) {
        return polkit.Result.YES;
    }
});

polkit.addRule(function (action, subject) {
    /* Everything that reformats or repartitions still requires admin auth. */
    if (action.id.indexOf("org.freedesktop.udisks2.modify-device") === 0 ||
        action.id == "org.freedesktop.udisks2.filesystem-take-ownership") {
        return polkit.Result.AUTH_ADMIN_KEEP;
    }
});
```

La política por dispositivo vive en `/etc/udisks2/mount_options.conf`:

```ini
# /etc/udisks2/mount_options.conf
# Force hardening flags on every udisks2-managed mount.
# Docs: https://github.com/storaged-project/udisks/blob/master/doc/udisks2.8.xml

[defaults]
defaults=nosuid,nodev,noexec,relatime
allow=nosuid,nodev,noexec,relatime,noatime,sync,dirsync,uid=$UID,gid=$GID,umask,dmask,fmask,ro,rw

vfat_defaults=uid=$UID,gid=$GID,shortname=mixed,utf8=1,showexec,flush
exfat_defaults=uid=$UID,gid=$GID,iocharset=utf8,errors=remount-ro
ntfs_defaults=uid=$UID,gid=$GID,windows_names
iso9660_defaults=uid=$UID,gid=$GID,iocharset=utf8,mode=0400,dmode=0500
```

### 7.4 La vía `autofs`

Para montajes dirigidos por mapas (cientos de directorios home, shares NFS por usuario), `autofs` sigue siendo la herramienta correcta.

**`/etc/auto.master`**

```
# /etc/auto.master — autofs(5) master map
#
# Format: <mount-point> <map> [<options>]
# Docs: https://man7.org/linux/man-pages/man5/auto.master.5.html

/-          /etc/auto.direct        --timeout=120
/mnt/nfs    /etc/auto.nfs           --timeout=300 --ghost
/home/net   /etc/auto.home          --timeout=600 --ghost
/net        -hosts                  --timeout=60
+auto.master
```

**`/etc/auto.direct`** (mapa directo — destinos absolutos)

```
/opt/toolchain    -fstype=nfs4,ro,nodev,nosuid,soft,retrans=2   nfs-01.internal:/exports/toolchain
/opt/geoip        -fstype=squashfs,ro,loop,nodev,nosuid,noexec  :/opt/images/geoip-2026-08.squashfs
```

**`/etc/auto.nfs`** (mapa indirecto — claves relativas a `/mnt/nfs`)

```
artifacts   -fstype=nfs4,rw,noatime,nodev,nosuid,hard,proto=tcp   nfs-01.internal:/exports/artifacts
backups     -fstype=nfs4,ro,noatime,nodev,nosuid,noexec,hard      nfs-02.internal:/exports/backups
```

**`/etc/auto.home`** (mapa con comodín — `/home/net/alice` → `nfs-01:/exports/home/alice`)

```
*   -fstype=nfs4,rw,noatime,nodev,nosuid,hard,proto=tcp   nfs-01.internal:/exports/home/&
```

```
$ sudo systemctl enable --now autofs
$ sudo automount --dumpmaps
$ ls /home/net/alice          # triggers the mount
$ findmnt -t nfs4 /home/net/alice
TARGET          SOURCE                              FSTYPE OPTIONS
/home/net/alice nfs-01.internal:/exports/home/alice nfs4   rw,noatime,nodev,nosuid,hard,proto=tcp,...
```

---

## 8. Desmontar: el problema del montaje ocupado

### 8.1 Formas del comando

```
$ sudo umount /srv/data              # by mount point — preferred, unambiguous
$ sudo umount /dev/nvme1n1           # by device — ambiguous if bind-mounted
$ sudo umount -R /export             # recursive: unmount everything under it too
$ sudo umount -a -t nfs4,nfs         # all mounts of given types
$ sudo umount -a -O _netdev          # all mounts carrying an fstab option
$ sudo umount -v /srv/data           # verbose
```

Solo el punto de montaje es inequívoco. Un sistema de archivos con bind mount en tres rutas, desmontado por dispositivo, se desconecta de una sola — y `umount(8)` te lo va a decir.

### 8.2 Cuando está ocupado

```
$ sudo umount /srv/data
umount: /srv/data: target is busy.
```

Diagnosticá antes de escalar:

```
$ sudo fuser -vm /srv/data
                     USER        PID ACCESS COMMAND
/srv/data:           root     kernel mount /srv/data
                     postgres   1842 F..c. postgres
                     postgres   1907 F...m postgres
                     sre        4210 ..c.. bash
```

Flags de `ACCESS`: `c` = directorio de trabajo · `e` = ejecutable en ejecución · `f` = archivo abierto · `F` = archivo abierto **para escritura** · `r` = directorio raíz · `m` = archivo mapeado en memoria o biblioteca compartida.

```
$ sudo lsof +f -- /srv/data | head
COMMAND    PID     USER   FD   TYPE DEVICE SIZE/OFF     NODE NAME
postgres  1842 postgres  cwd    DIR  259,0     4096      128 /srv/data/pgdata
postgres  1842 postgres    7uW  REG  259,0 16777216      131 /srv/data/pgdata/pg_wal/00000001...
bash      4210      sre  cwd    DIR  259,0     4096      128 /srv/data

# Deleted-but-still-open files also pin a mount, and lsof is the only way to see them:
$ sudo lsof -n /srv/data | grep '(deleted)'
java     8877 app   14w   REG  259,0 2147483648  4099 /srv/data/logs/app.log (deleted)

# A mount can also be pinned by another mount namespace (a container):
$ sudo lsns -t mnt
        NS TYPE NPROCS   PID USER   COMMAND
4026531840 mnt     231     1 root   /sbin/init
4026532571 mnt       1  9912 root   /pause
$ sudo nsenter -t 9912 -m findmnt | grep srv-data
```

### 8.3 Escalera de escalado

| Paso | Comando | Efecto | Riesgo |
|---|---|---|---|
| 1 | `fuser -vm` / `lsof` | Identificar quién lo retiene | ninguno |
| 2 | Detener el servicio como corresponde | `systemctl stop postgresql@16-main` | ninguno — **esta es casi siempre la solución** |
| 3 | Salir de él con `cd` | Tu propia shell suele ser la culpable | ninguno |
| 4 | `sudo umount /srv/data` | Reintentar | ninguno |
| 5 | `sudo fuser -km /srv/data` | `SIGKILL` a todo el que lo retenga | Mata procesos con estado de aplicación sin volcar |
| 6 | `sudo mount -o remount,ro /srv/data` | Detener más escrituras; vuelca y te permite tomar una instantánea | La aplicación da error al escribir |
| 7 | `sudo umount -f /srv/data` | Forzar — **solo tiene sentido para NFS inalcanzable** | Descarta las RPC en vuelo |
| 8 | `sudo umount -l /srv/data` | Perezoso: desconectar del árbol ahora, liberar cuando se cierre la última referencia | **Ver abajo** |

**Por qué `umount -l` no es una solución.** El montaje desaparece de `/proc/self/mounts`, así que quien opera cree que se fue — pero el superbloque sigue vivo, el dispositivo sigue retenido, y los escritores siguen escribiendo dentro de un sistema de archivos que nadie puede ver ni chequear. Si después volvés a montar el mismo dispositivo en otro lado, o la capa de almacenamiento le entrega el LUN a otro nodo, obtenés montajes concurrentes de un mismo sistema de archivos: corrupción garantizada. Usá `-l` solo cuando estés desmontando algo que pensás abandonar por completo, y aun así, confirmá que el dispositivo quedó realmente liberado:

```
$ sudo umount -l /srv/data
$ findmnt /srv/data          # empty — looks clean
$ sudo lsof -n | grep 259,0  # NOT empty — writers survive
java   8877 app  14w  REG  259,0  2147483648  4099 /srv/data/logs/app.log
$ ls -l /sys/class/block/nvme1n1/holders/   # still held
$ sudo blockdev --flushbufs /dev/nvme1n1
```

### 8.4 Desconexión limpia y aquietamiento

```
# Guaranteed-durable ordering before removing a device
$ sudo sync -f /srv/data                 # flush this filesystem only
$ sudo umount /srv/data
$ echo $?
0
$ sudo blockdev --flushbufs /dev/nvme1n1

# Consistent snapshot WITHOUT unmounting: freeze the filesystem
$ sudo fsfreeze --freeze /srv/data
$ sudo lvcreate --snapshot --size 20G --name lv_data_snap /dev/vg_data/lv_data
  Logical volume "lv_data_snap" created.
$ sudo fsfreeze --unfreeze /srv/data

# Verify the unmount was clean (ext4)
$ sudo dumpe2fs -h /dev/vg0-root 2>/dev/null | grep -E 'Filesystem state|Mount count|Last checked'
Filesystem state:         clean
Mount count:              47
Last checked:             Tue Jun  3 11:02:14 2026
```

`fsfreeze` bloquea todas las escrituras y vuelca el journal, dando una instantánea consistente ante caídas *y* consistente a nivel de sistema de archivos. **Nunca dejes un sistema de archivos congelado** — todo escritor queda bloqueado en estado `D` hasta que descongeles, incluida tu propia shell si hacés `cd` dentro de él.

---

## 9. Manifiestos de infraestructura

### 9.1 cloud-init — particionar, formatear y montar un volumen de datos en el primer arranque

```yaml
#cloud-config
# /var/lib/cloud/seed/nocloud/user-data
# Docs: https://cloudinit.readthedocs.io/en/latest/reference/modules.html#mounts
#       https://cloudinit.readthedocs.io/en/latest/reference/modules.html#disk-setup

disk_setup:
  /dev/nvme1n1:
    table_type: gpt
    layout:
      - [100, 83]          # one partition, 100% of the device, type 83 (Linux)
    overwrite: false       # NEVER true on a volume that may already hold data

fs_setup:
  - label: data
    filesystem: xfs
    device: /dev/nvme1n1
    partition: 1
    overwrite: false
    extra_opts:
      - "-m"
      - "crc=1,finobt=1"
      - "-i"
      - "size=512"

# Applied to any 'mounts' entry that omits a field.
mount_default_fields: [None, None, "auto", "defaults,nofail", "0", "2"]

mounts:
  # [ source, mountpoint, type, options, dump, pass ]
  - ["LABEL=data", "/srv/data", "xfs",
     "rw,noatime,nodev,nosuid,logbsize=256k,nofail,x-systemd.device-timeout=15s,X-mount.mkdir=0755",
     "0", "2"]

  - ["/srv/data/pgdata", "/var/lib/postgresql", "none",
     "rw,bind,x-systemd.requires-mounts-for=/srv/data,X-mount.mkdir=0700",
     "0", "0"]

  - ["tmpfs", "/tmp", "tmpfs",
     "rw,nosuid,nodev,noexec,relatime,size=4G,mode=1777",
     "0", "0"]

  # Remove any legacy ephemeral entry the image shipped with.
  - ["ephemeral0", null]

  - ["nfs-01.internal:/exports/artifacts", "/mnt/artifacts", "nfs4",
     "rw,noatime,nodev,nosuid,_netdev,noauto,x-systemd.automount,x-systemd.idle-timeout=600,hard,proto=tcp",
     "0", "0"]

swap:
  filename: /swap.img
  size: 4294967296          # 4 GiB
  maxsize: 4294967296

runcmd:
  - [systemctl, daemon-reload]
  - [findmnt, --verify, --verbose]
  - [install, -d, -o, postgres, -g, postgres, -m, "0700", /srv/data/pgdata]
  - [systemctl, restart, local-fs.target]

final_message: "storage ready after $UPTIME seconds"
```

### 9.2 Ansible — gestión de montajes idempotente y verificada

```yaml
---
# roles/storage/tasks/main.yml
# Docs: https://docs.ansible.com/ansible/latest/collections/ansible/posix/mount_module.html

- name: Resolve the filesystem UUID of the data volume
  ansible.builtin.command:
    cmd: "blkid -s UUID -o value {{ storage_data_device }}"
  register: storage_data_uuid
  changed_when: false
  failed_when: storage_data_uuid.stdout | length != 36

- name: Ensure the mount point exists with the correct ownership
  ansible.builtin.file:
    path: "{{ storage_data_mountpoint }}"
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Ensure the data volume is present in fstab and mounted
  ansible.posix.mount:
    path: "{{ storage_data_mountpoint }}"
    src: "UUID={{ storage_data_uuid.stdout }}"
    fstype: xfs
    opts: >-
      rw,noatime,nodev,nosuid,logbsize=256k,nofail,
      x-systemd.device-timeout=15s
    dump: "0"
    passno: "2"
    state: mounted          # present=fstab only · mounted=fstab+mount · absent=unmount+remove
    boot: true
  notify: reload systemd

- name: Ensure the PostgreSQL bind mount depends on the data volume
  ansible.posix.mount:
    path: /var/lib/postgresql
    src: "{{ storage_data_mountpoint }}/pgdata"
    fstype: none
    opts: "rw,bind,x-systemd.requires-mounts-for={{ storage_data_mountpoint }}"
    dump: "0"
    passno: "0"
    state: mounted
  notify: reload systemd

- name: Harden the scratch filesystems (CIS 1.1.2 - 1.1.9)
  ansible.posix.mount:
    path: "{{ item.path }}"
    src: "{{ item.src }}"
    fstype: "{{ item.fstype }}"
    opts: "{{ item.opts }}"
    dump: "0"
    passno: "0"
    state: mounted
  loop:
    - { path: /tmp,     src: tmpfs, fstype: tmpfs, opts: "rw,nosuid,nodev,noexec,relatime,size=4G,mode=1777" }
    - { path: /dev/shm, src: tmpfs, fstype: tmpfs, opts: "rw,nosuid,nodev,noexec,relatime,size=1G" }
    - { path: /var/tmp, src: /tmp,  fstype: none,  opts: "rw,nosuid,nodev,noexec,bind" }
  notify: reload systemd

- name: Ensure the service will not start before its storage
  ansible.builtin.copy:
    dest: /etc/systemd/system/postgresql@16-main.service.d/10-storage.conf
    owner: root
    group: root
    mode: "0644"
    content: |
      # Managed by Ansible (role: storage)
      [Unit]
      RequiresMountsFor=/var/lib/postgresql
  notify: reload systemd

# --- Verification: assert the running state, do not trust the task result ----

- name: Read the live mount table
  ansible.builtin.command:
    cmd: "findmnt --json --target {{ storage_data_mountpoint }}"
  register: storage_findmnt
  changed_when: false

- name: Assert the data volume is mounted with the intended VFS flags
  ansible.builtin.assert:
    that:
      - _opts is search('noatime')
      - _opts is search('nodev')
      - _opts is search('nosuid')
      - _opts is not search('(^|,)ro(,|$)')
    fail_msg: "Effective options on {{ storage_data_mountpoint }} are '{{ _opts }}'"
    success_msg: "{{ storage_data_mountpoint }} mounted correctly"
  vars:
    _opts: "{{ (storage_findmnt.stdout | from_json).filesystems[0].options }}"

- name: Validate that fstab will not break the next boot
  ansible.builtin.command:
    cmd: findmnt --verify --verbose
  register: storage_fstab_verify
  changed_when: false
  failed_when: "'0 errors' not in storage_fstab_verify.stdout"
```

```yaml
---
# roles/storage/handlers/main.yml
- name: reload systemd
  ansible.builtin.systemd_service:
    daemon_reload: true
```

```yaml
---
# roles/storage/defaults/main.yml
storage_data_device: /dev/nvme1n1
storage_data_mountpoint: /srv/data
```

### 9.3 Kubernetes — dónde afloran las semánticas de montaje del host

Un plugin de nodo CSI tiene que crear montajes dentro de su contenedor que el kubelet (fuera del contenedor) pueda ver. Eso requiere `mountPropagation: Bidirectional`, que requiere que el `/` del host sea `rshared` — que es el mecanismo de subárboles compartidos de la §2.4.

```yaml
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: csi-node-driver
  namespace: kube-system
  labels:
    app.kubernetes.io/name: csi-node-driver
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: csi-node-driver
  template:
    metadata:
      labels:
        app.kubernetes.io/name: csi-node-driver
    spec:
      hostNetwork: true
      priorityClassName: system-node-critical
      tolerations:
        - operator: Exists
      containers:
        - name: node-driver
          image: registry.example.com/csi/node-driver:v1.12.0
          securityContext:
            privileged: true                 # required for mount(2) inside the container
            capabilities:
              add: ["SYS_ADMIN"]
            allowPrivilegeEscalation: true
          args:
            - "--endpoint=unix:///csi/csi.sock"
            - "--nodeid=$(NODE_ID)"
          env:
            - name: NODE_ID
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          volumeMounts:
            - name: plugin-dir
              mountPath: /csi
            - name: pods-mount-dir
              mountPath: /var/lib/kubelet/pods
              mountPropagation: Bidirectional   # mounts made here appear on the host
            - name: device-dir
              mountPath: /dev
            - name: host-sys
              mountPath: /sys
              readOnly: true
            - name: host-run-udev
              mountPath: /run/udev
              readOnly: true
      volumes:
        - name: plugin-dir
          hostPath:
            path: /var/lib/kubelet/plugins/csi.example.com
            type: DirectoryOrCreate
        - name: pods-mount-dir
          hostPath:
            path: /var/lib/kubelet/pods
            type: Directory
        - name: device-dir
          hostPath:
            path: /dev
            type: Directory
        - name: host-sys
          hostPath:
            path: /sys
            type: Directory
        - name: host-run-udev
          hostPath:
            path: /run/udev
            type: Directory
```

Prerrequisitos del lado del nodo, verificados con las mismas herramientas que todo lo demás:

```
$ findmnt -o TARGET,PROPAGATION -T /var/lib/kubelet
TARGET       PROPAGATION
/            shared

# If it prints 'private', bidirectional propagation silently does nothing:
$ sudo mount --make-rshared /
# Persist it:
$ cat /etc/systemd/system/make-rshared.service
[Unit]
Description=Ensure / is a shared mount for CSI mount propagation
DefaultDependencies=no
After=local-fs.target
Before=containerd.service kubelet.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/mount --make-rshared /

[Install]
WantedBy=multi-user.target

# containerd/docker must not re-privatise it:
$ systemctl show containerd -p MountFlags
MountFlags=
```

---

## 10. Verificación y diagnóstico de fallos

### 10.1 La lista de comprobación previa al reinicio

Ejecutá estos cinco comandos, en orden, cada vez que cambies `/etc/fstab`. Cuestan segundos y son la diferencia entre un reinicio y una caída.

```
$ sudo findmnt --verify --verbose
/
   [ ] target exists
   [ ] FS type is ext4
   [ ] source UUID=9c8b7a65-0d1e-4f22-8a90-3c5b7e1d4402 exists
/srv/data
   [ ] target exists
   [ ] FS type is xfs
   [ ] source UUID=b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752 exists
/mnt/artifacts
   [W] non-bind mount source nfs-01.internal:/exports/artifacts is a directory or file

0 parse errors, 0 errors, 1 warning

$ sudo mount -a --fake --verbose         # 2. does every entry parse and resolve?
$ sudo mount -a                          # 3. does every entry actually mount now?
$ sudo systemctl daemon-reload           # 4. regenerate the mount units
$ systemctl --failed --type=mount        # 5. did any unit fail?
0 loaded units listed.
```

Después confirmá que el estado *efectivo* coincide con el estado *deseado* — los dos difieren más seguido de lo que cualquiera espera:

```
$ findmnt --fstab --evaluate      # fstab with UUID/LABEL resolved to devices
TARGET              SOURCE                       FSTYPE  OPTIONS
/                   /dev/mapper/vg0-root         ext4    rw,relatime,errors=remount-ro
/boot               /dev/nvme0n1p2               ext4    rw,relatime,nodev,nosuid,noexec
/srv/data           /dev/nvme1n1                 xfs     rw,noatime,nodev,nosuid,...

$ diff <(findmnt --fstab -o TARGET,SOURCE -n --evaluate | sort) \
       <(findmnt --mtab  -o TARGET,SOURCE -n --real     | sort)
```

### 10.2 Síntoma → causa → comando

| Síntoma | Causa más probable | Diagnóstico | Solución |
|---|---|---|---|
| `wrong fs type, bad option, bad superblock` | `-t` incorrecto, módulo del kernel o programa auxiliar de espacio de usuario faltante, o un problema genuino de superbloque | `dmesg \| tail -20` · `blkid /dev/X` · `lsmod \| grep xfs` | Corregir el tipo; `modprobe`; instalar `nfs-common`/`cifs-utils`/`exfatprogs` |
| `Filesystem has duplicate UUID … can't mount` (XFS) | Volumen clonado | `sudo blkid -s UUID /dev/sd*` | `xfs_admin -U generate /dev/sdX1` con el fs desmontado |
| `special device UUID=… does not exist` | El sistema de archivos fue reformateado; el UUID cambió | `blkid` contra `grep UUID /etc/fstab` | Actualizar fstab a partir de la salida real de `blkid` |
| `mount point does not exist` | Directorio no creado | `ls -ld /srv/data` | `mkdir -p`, o agregar `X-mount.mkdir=0755` |
| `only root can do that` como usuario normal | Falta `user`/`users` en fstab, o la ruta está escrita distinto | `grep /media /etc/fstab` | Agregar `user`/`users`; la ruta debe coincidir exactamente |
| `umount: not mounted by you` | Montado por otro usuario con `user` | `grep <target> /run/mount/utab` | Usar `users` en lugar de `user`, o desmontar como ese usuario / root |
| `target is busy` | Archivos abiertos, directorio de trabajo, mmap, u otro namespace | `fuser -vm <t>` · `lsof <t>` · `lsns -t mnt` | Detener el servicio; último recurso §8.3 |
| El arranque cae a modo de emergencia | Entrada de fstab sin `nofail`, dispositivo ausente | `journalctl -b -u local-fs.target` · `systemctl --failed` | `mount -o remount,rw /` → corregir fstab → `systemctl daemon-reload` → `systemctl default` |
| El sistema de archivos está en solo lectura de forma inesperada | Se disparó `errors=remount-ro` por un error de E/S | `dmesg \| grep -iE 'ext4|I/O error|remount'` · `smartctl -a /dev/X` | **No lo remontes en rw sin más** — primero encontrá la falla de hardware |
| El disco está lleno pero `du` muestra poco | Un sistema de archivos está montado *encima* de los datos, o hay archivos borrados y abiertos | `du -sh` contra `df -h` · `lsof \| grep deleted` · desmontar y volver a chequear | Reiniciar al proceso que los retiene; corregir el montaje que ensombrece |
| Los datos escritos "desaparecen" tras un reinicio | El montaje falló silenciosamente; la aplicación escribió en el directorio subyacente | `sudo umount /srv/data && ls -la /srv/data` (debe estar vacío) | Agregar `RequiresMountsFor=` a la unidad de servicio |
| `mount -a` funciona, el arranque no | Problema de ordenamiento/dependencias, no de sintaxis | `systemd-analyze critical-chain local-fs.target` · `systemd-analyze plot > boot.svg` | Agregar `x-systemd.requires-mounts-for=` / `x-systemd.after=` |
| El montaje NFS se cuelga para siempre | Montaje `hard` + servidor inalcanzable (comportamiento correcto) | `findmnt -t nfs4` · `rpcinfo -p <server>` · `ss -tn state established '( dport = :2049 )'` | Restaurar el servidor; `umount -f -l` para abandonarlo; `noauto,x-systemd.automount` para evitar el impacto en el arranque |
| Ciclo de ordenamiento en el arranque | Dependencias circulares de unidades por `x-systemd.*` | `journalctl -b \| grep -i 'ordering cycle'` | Quitar el `x-systemd.after=` redundante |

### 10.3 Fallo resuelto #1 — la entrada de fstab que bloquea el arranque

```
# Emergency console after a reboot:
You are in emergency mode. After logging in, type "journalctl -xb" to view
system logs, "systemctl reboot" to reboot, or "exit" to continue bootup.
Give root password for maintenance (or press Control-D to continue):

# ---------------------------------------------------------------------------
root@db-prod-03:~# systemctl --failed
  UNIT           LOAD   ACTIVE SUB    DESCRIPTION
● srv-data.mount loaded failed failed /srv/data
1 loaded units listed.

root@db-prod-03:~# journalctl -b -u srv-data.mount --no-pager
Aug 26 09:12:04 db-prod-03 systemd[1]: Mounting /srv/data...
Aug 26 09:13:34 db-prod-03 systemd[1]: dev-disk-by\x2duuid-b7c9....device: Job timed out.
Aug 26 09:13:34 db-prod-03 systemd[1]: Timed out waiting for device /dev/disk/by-uuid/b7c9d2e4-...
Aug 26 09:13:34 db-prod-03 systemd[1]: Dependency failed for /srv/data.
Aug 26 09:13:34 db-prod-03 systemd[1]: srv-data.mount: Job srv-data.mount/start failed with result 'dependency'.
Aug 26 09:13:34 db-prod-03 systemd[1]: Dependency failed for Local File Systems.

root@db-prod-03:~# lsblk -f | grep -c nvme1n1
0                                         # the volume genuinely is not attached

root@db-prod-03:~# mount -o remount,rw /
root@db-prod-03:~# sed -i 's|\(/srv/data .*\)nofail,\?|\1|; s|\(/srv/data .*xfs *[^ ]*\)|\1,nofail,x-systemd.device-timeout=15s|' /etc/fstab
root@db-prod-03:~# grep /srv/data /etc/fstab
UUID=b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752  /srv/data  xfs  rw,noatime,nodev,nosuid,logbsize=256k,nofail,x-systemd.device-timeout=15s  0  2

root@db-prod-03:~# findmnt --verify
root@db-prod-03:~# systemctl daemon-reload
root@db-prod-03:~# systemctl default
```

**Lección:** `nofail` convierte `Requires=` en `Wants=` y saca la espera de 90 segundos por el dispositivo del camino crítico. Con `nofail`, ese arranque se completa, la base de datos se niega a iniciar (por `RequiresMountsFor=`), el monitoreo te avisa, y la máquina es accesible por SSH. Sin él, la máquina se perdió.

### 10.4 Fallo resuelto #2 — el punto de montaje ensombrecido

```
$ df -h /srv/data
Filesystem      Size  Used Avail Use% Mounted on
/dev/mapper/vg0-root   40G   39G  412M  99% /       # <-- NOT nvme1n1. The mount is missing.

$ findmnt /srv/data
$ echo $?
1                                                    # nothing mounted there

$ du -sh /srv/data
26G     /srv/data                                    # 26 GB written to the ROOT filesystem

$ systemctl status srv-data.mount --no-pager
● srv-data.mount - /srv/data
     Active: failed (Result: exit-code) since Tue 2026-08-26 09:14:02 UTC
$ journalctl -b -u srv-data.mount -n 5 --no-pager
Aug 26 09:14:02 db-prod-03 mount[912]: mount: /srv/data: wrong fs type, bad option, bad superblock on /dev/nvme1n1
Aug 26 09:14:02 db-prod-03 kernel: XFS (nvme1n1): Filesystem has duplicate UUID b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752 - can't mount
```

Recuperación, en el único orden seguro:

```
$ sudo systemctl stop postgresql@16-main
$ sudo mv /srv/data /srv/data.shadowed          # preserve what was written to root
$ sudo mkdir -p /srv/data
$ sudo xfs_admin -U generate /dev/nvme1n1
Clearing log and setting UUID
new UUID = 3d8e1f52-6b0a-4c27-8f13-72a94e6d05b1
$ sudo sed -i 's/b7c9d2e4-3f10-4d5a-9e88-11ac33bd7752/3d8e1f52-6b0a-4c27-8f13-72a94e6d05b1/' /etc/fstab
$ sudo systemctl daemon-reload && sudo mount -a
$ findmnt /srv/data
TARGET    SOURCE       FSTYPE OPTIONS
/srv/data /dev/nvme1n1 xfs    rw,noatime,nodev,nosuid,logbsize=256k
$ sudo rsync -aHAX --info=progress2 /srv/data.shadowed/ /srv/data/
$ sudo systemctl start postgresql@16-main
```

La solución permanente es `RequiresMountsFor=/var/lib/postgresql` en el drop-in del servicio (§6.4), de modo que un montaje fallido detenga el servicio en lugar de redirigirlo silenciosamente.

### 10.5 Verificación permanente que deberías automatizar

```
# Is anything mounted with weaker flags than fstab asks for?
$ findmnt --json --real | jq -r '.filesystems[] | "\(.target)\t\(.options)"'

# Any local filesystem that should be nodev/nosuid but is not:
$ findmnt -n -o TARGET,OPTIONS --real \
  | awk '$1 ~ "^/(tmp|home|var/tmp|dev/shm|media)" && ($2 !~ /nosuid/ || $2 !~ /nodev/) {print "WEAK: "$0}'

# Any filesystem that silently went read-only:
$ findmnt -n -o TARGET,OPTIONS --real | awk '$2 ~ /(^|,)ro(,|$)/ {print "READ-ONLY: "$0}'

# Will the next boot succeed?
$ sudo findmnt --verify --verbose | tail -1
0 parse errors, 0 errors, 0 warnings

# Boot-time storage critical path
$ systemd-analyze critical-chain local-fs.target --no-pager
local-fs.target @6.204s
└─srv-data.mount @5.918s +284ms
  └─systemd-fsck@dev-disk-by\x2duuid-b7c9....service @4.601s +1.310s
    └─dev-disk-by\x2duuid-b7c9....device @4.598s
```

Conectá el estado de salida de `findmnt --verify` a la gestión de configuración y el chequeo de `READ-ONLY` a tu agente de métricas. Un sistema de archivos que se remontó en solo lectura a las 03:00 debería generar una alerta, no descubrirse a las 09:00.

---

## 11. Referencia de comandos

| Tarea | Comando |
|---|---|
| Listar dispositivos de bloques con info de fs | `lsblk -f` · `lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS` |
| Leer la firma del fs | `blkid /dev/X` · `blkid -s UUID -o value /dev/X` |
| Encontrar el dispositivo por label/UUID | `blkid -L <label>` · `blkid -U <uuid>` |
| Montar desde fstab | `mount /path` · `mount -a` |
| Montar por identificador | `mount UUID=… /path` · `mount LABEL=… /path` |
| Ejecución en seco | `mount --fake -v /path` · `mount -a --fake -v` |
| Bind / move | `mount --bind src dst` · `mount --rbind` · `mount --move` |
| Cambiar opciones en caliente | `mount -o remount,<opts> /path` |
| Mostrar los montajes actuales | `findmnt` · `findmnt -t xfs` · `findmnt --df` · `findmnt --real` |
| Mostrar fstab, resuelto | `findmnt --fstab --evaluate` |
| Validar fstab | `findmnt --verify --verbose` |
| Observar cambios de montaje | `findmnt --poll --target /path` |
| Desmontar | `umount /path` · `umount -R` · `umount -a -t nfs4` |
| Encontrar quién lo retiene | `fuser -vm /path` · `lsof /path` · `lsns -t mnt` |
| Matar a quien lo retiene | `fuser -km /path` |
| Volcar | `sync -f /path` · `blockdev --flushbufs /dev/X` |
| Aquietar para una instantánea | `fsfreeze --freeze /path` … `fsfreeze --unfreeze /path` |
| Reetiquetar / cambiar UUID | `e2label` · `tune2fs -U` · `xfs_admin -L/-U` · `fatlabel` |
| Unidades de montaje de systemd | `systemctl list-units --type=mount` · `systemctl cat <u>.mount` · `systemd-escape -p --suffix=mount /p` |
| Montaje transitorio | `systemd-mount /dev/X /mnt/y` · `systemd-umount /mnt/y` |
| Demonio de montaje en espacio de usuario | `udisksctl status` · `udisksctl mount -b /dev/X` · `udisksctl power-off -b /dev/X` |
| Diagnóstico de almacenamiento en el arranque | `journalctl -b -u local-fs.target` · `systemd-analyze critical-chain local-fs.target` |

---

## 12. Referencias

**Objetivos del examen**
- LPI — Objetivos del examen 101-500 (LPIC-1 v5.0), Tema 104.3: https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — Panorama de la certificación LPIC-1: https://www.lpi.org/our-certifications/lpic-1-overview/

**util-linux (mount, umount, findmnt, blkid, lsblk, fstab)**
- `mount(8)`: https://man7.org/linux/man-pages/man8/mount.8.html
- `umount(8)`: https://man7.org/linux/man-pages/man8/umount.8.html
- `fstab(5)`: https://man7.org/linux/man-pages/man5/fstab.5.html
- `findmnt(8)`: https://man7.org/linux/man-pages/man8/findmnt.8.html
- `blkid(8)`: https://man7.org/linux/man-pages/man8/blkid.8.html
- `lsblk(8)`: https://man7.org/linux/man-pages/man8/lsblk.8.html
- `fsfreeze(8)`: https://man7.org/linux/man-pages/man8/fsfreeze.8.html
- `losetup(8)`: https://man7.org/linux/man-pages/man8/losetup.8.html
- util-linux upstream: https://github.com/util-linux/util-linux

**Kernel**
- `mount(2)`: https://man7.org/linux/man-pages/man2/mount.2.html
- `mount_namespaces(7)`: https://man7.org/linux/man-pages/man7/mount_namespaces.7.html
- Subárboles compartidos (propagación de montajes): https://docs.kernel.org/filesystems/sharedsubtree.html
- El sistema de archivos `/proc`, incl. la disposición de campos de `mountinfo`: https://docs.kernel.org/filesystems/proc.html
- Administración de ext4 y opciones de montaje: https://docs.kernel.org/admin-guide/ext4.html
- Administración de XFS: https://docs.kernel.org/admin-guide/xfs.html
- tmpfs: https://docs.kernel.org/filesystems/tmpfs.html
- overlayfs: https://docs.kernel.org/filesystems/overlayfs.html
- Panorama del VFS: https://docs.kernel.org/filesystems/vfs.html

**systemd**
- `systemd.mount(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.mount.html
- `systemd.automount(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.automount.html
- `systemd-fstab-generator(8)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-fstab-generator.html
- `systemd-mount(1)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-mount.html
- `systemd.unit(5)` — `RequiresMountsFor=`: https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html
- `systemd-escape(1)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-escape.html

**Herramientas de sistemas de archivos**
- `tune2fs(8)`: https://man7.org/linux/man-pages/man8/tune2fs.8.html
- `e2label(8)`: https://man7.org/linux/man-pages/man8/e2label.8.html
- `xfs_admin(8)`: https://man7.org/linux/man-pages/man8/xfs_admin.8.html
- `dumpe2fs(8)`: https://man7.org/linux/man-pages/man8/dumpe2fs.8.html

**Medios removibles y automontaje**
- Proyecto udisks2: https://github.com/storaged-project/udisks
- `udisksctl(1)`: https://storaged.org/doc/udisks2-api/latest/udisksctl.1.html
- Manual de referencia de polkit: https://www.freedesktop.org/software/polkit/docs/latest/polkit.8.html
- `auto.master(5)`: https://man7.org/linux/man-pages/man5/auto.master.5.html
- `autofs(5)`: https://man7.org/linux/man-pages/man5/autofs.5.html
- Filesystem Hierarchy Standard 3.0 (`/media`, `/mnt`, `/srv`): https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html

**Diagnóstico**
- `fuser(1)`: https://man7.org/linux/man-pages/man1/fuser.1.html
- `lsof(8)`: https://man7.org/linux/man-pages/man8/lsof.8.html
- `lsns(8)`: https://man7.org/linux/man-pages/man8/lsns.8.html
- `nsenter(1)`: https://man7.org/linux/man-pages/man1/nsenter.1.html

**Automatización de infraestructura**
- Módulo `mounts` de cloud-init: https://cloudinit.readthedocs.io/en/latest/reference/modules.html#mounts
- Módulo `disk_setup` de cloud-init: https://cloudinit.readthedocs.io/en/latest/reference/modules.html#disk-setup
- Ansible `ansible.posix.mount`: https://docs.ansible.com/ansible/latest/collections/ansible/posix/mount_module.html
- Kubernetes — propagación de montajes: https://kubernetes.io/docs/concepts/storage/volumes/#mount-propagation
- Despliegue de un plugin de nodo CSI en Kubernetes: https://kubernetes-csi.github.io/docs/deploying.html