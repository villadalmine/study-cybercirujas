# 103.3 — Realizar gestión básica de archivos

**LPIC-1 v5.0 · Examen 101-500 · Peso: 6.25**

**Archivos, términos y utilidades clave:** `cp`, `find`, `mkdir`, `mv`, `ls`, `rm`, `rmdir`, `touch`, `tar`, `cpio`, `dd`, `file`, `gzip`, `gunzip`, `bzip2`, `bunzip2`, `xz`, `unxz`, file globbing.

---

## 1. El problema de producción

Todo incidente que gestiones alguna vez tendrá una operación de gestión de archivos en algún punto de su radio de impacto. No porque los comandos sean difíciles, sino porque su *semántica* es contraintuitiva a escala:

- **Un `df` que reporta 100% lleno mientras `du` reporta 40% usado.** Nadie "se olvidó de borrar" nada. Un proceso mantiene abierto un descriptor de archivo hacia un log de 8 GiB ya desenlazado. `rm` nunca libera espacio; decrementa un contador de enlaces.
- **Un `mv` de un dataset de 400 GiB que tardó 3 horas y dejó un archivo a medio escribir cuando murió la sesión SSH.** `mv` es atómico *dentro* de un filesystem y una copia-y-borrado no atómica *entre* filesystems. Nada en el comando te dice cuál te tocó.
- **Un job nocturno de limpieza `find /var/log -mtime +7 -exec rm {} \;` que saturó la CPU del nodo con 40.000 pares `fork()`+`execve()`**, y que además omitió silenciosamente archivos con espacios en el nombre el día que alguien habilitó un log shipper mal configurado.
- **Un bucle `for f in *.log` que murió con `-bash: /bin/rm: Argument list too long`** en el único nodo que tenía 300.000 archivos rotados — exactamente el nodo que necesitabas recuperar.
- **Una imagen de contenedor cuyas capas tenían un SHA distinto en cada build**, porque `tar` incrustó `mtime`, UID/GID y orden de directorio del host de compilación.
- **Un `dd` leyendo desde una tubería que produjo silenciosamente una imagen de disco truncada**, porque `dd` acepta lecturas cortas salvo que le digas lo contrario.

Ninguno de estos casos es exótico. Todos son consecuencia directa del modelo de archivos POSIX y de los flags por defecto de coreutils, GNU findutils, GNU tar y GNU cpio. Este objetivo es donde dejás de tratar a `cp`/`mv`/`rm` como verbos y empezás a tratarlos como *llamadas al sistema con un envoltorio de CLI*.

El encuadre arquitectónico para el resto de este documento:

```
┌─────────────────────────────────────────────────────────────────────┐
│  Shell (bash)                                                        │
│   ├── brace expansion  {a,b}      ← NOT a glob, no filesystem access │
│   ├── pathname expansion * ? [ ]  ← reads directories, sorts result  │
│   └── builds argv[]               ← bounded by ARG_MAX / MAX_ARG_STRLEN
├─────────────────────────────────────────────────────────────────────┤
│  Userspace tool (cp, mv, rm, find, tar, cpio, dd)                   │
│   └── policy: recursion, attribute preservation, error handling      │
├─────────────────────────────────────────────────────────────────────┤
│  System calls                                                        │
│   openat(2) statx(2) getdents64(2) linkat(2) unlinkat(2)             │
│   renameat2(2) copy_file_range(2) ioctl(FICLONE) utimensat(2)        │
├─────────────────────────────────────────────────────────────────────┤
│  VFS → filesystem (ext4 / XFS / Btrfs / overlayfs / tmpfs / NFS)     │
│   inodes · directory entries · extents · CoW · journal               │
└─────────────────────────────────────────────────────────────────────┘
```

Cada compromiso de este objetivo vive en una de esas cuatro capas. Saber *de qué* capa proviene un comportamiento es la diferencia entre una solución y una superstición.

---

## 2. El sustrato: qué es realmente un "archivo"

Un archivo es un **inodo** — un registro de metadatos que contiene modo, UID, GID, marcas de tiempo, tamaño, contador de enlaces y punteros a bloques de datos. Un archivo **no** es su nombre. Un nombre es una **entrada de directorio**: una tupla (nombre → número de inodo) almacenada dentro de un directorio, que a su vez es un inodo.

```
$ stat -c 'name=%n inode=%i links=%h size=%s alloc=%b*%B mode=%A fs=%d' /etc/passwd
name=/etc/passwd inode=1310726 links=1 size=2938 alloc=8*512 mode=-rw-r--r-- fs=64768
```

Cuatro consecuencias que generan comportamiento real en producción:

| Hecho | Consecuencia |
|---|---|
| Los nombres apuntan a inodos, los inodos no apuntan a nombres | `rm` no puede "borrar un archivo"; elimina un nombre y decrementa `st_nlink`. Los datos se recuperan cuando `st_nlink == 0` **y** ningún proceso mantiene un fd abierto. |
| Los números de inodo son únicos **por filesystem**, no globalmente | `mv` a través de un límite de montaje no puede ser un rename; tiene que copiar. `find -xdev` existe por esta razón. |
| Las entradas de directorio están desordenadas en disco | `ls` ordena por vos; `readdir(2)`/`find` no. Los archivos reproducibles requieren `--sort=name` o `sort -z`. |
| Hay tres marcas de tiempo (cuatro con `birth`) y solo dos son establecibles | `atime`, `mtime` se establecen vía `utimensat(2)`; `ctime` lo fija el kernel ante *cualquier* cambio del inodo y no puede falsificarse con `touch`. |

```
$ stat /var/log/syslog
  File: /var/log/syslog
  Size: 1048576   	Blocks: 2048       IO Block: 4096   regular file
Device: 253,0	Inode: 262157      Links: 1
Access: (0640/-rw-r-----)  Uid: (  104/  syslog)   Gid: (   4/     adm)
Access: 2026-08-26 03:12:01.442918233 +0000
Modify: 2026-08-26 09:41:17.884213011 +0000
Change: 2026-08-26 09:41:17.884213011 +0000
 Birth: 2026-08-19 00:00:03.117884210 +0000
```

**Semántica de las marcas de tiempo — memorizá esta tabla, gobierna `find` y `tar`:**

| Marca | Establecida por | Modificada por | Falsificable | Relevancia para backups |
|---|---|---|---|---|
| `atime` | lectura de los datos del archivo | `read(2)`, `execve(2)` | sí (`touch -a`) | Poco fiable: `relatime` es la opción de montaje por defecto y solo se refresca si el `atime` anterior es previo a `mtime`/`ctime` o tiene más de 24 h. `noatime`/`lazytime` la suprimen aún más. |
| `mtime` | escritura de los **datos** del archivo | `write(2)`, `truncate(2)` | sí (`touch -m`) | Lo que usan `tar --newer-mtime` y `find -mtime`. Falsificable ⇒ no es un control de seguridad. |
| `ctime` | cambio del **inodo** | `chmod`, `chown`, `rename`, cambio del contador de enlaces, y toda escritura de datos | **no** | Lo que `tar -N/--after-date` también consulta, y la única marca que un atacante no puede retrasar con `touch`. |
| `btime` | creación del archivo | nada | no | Solo ext4/XFS/Btrfs; expuesta vía `statx(2)`, mostrada por `stat` como `Birth:`. No usable en `find`. |

```
$ touch -d '2001-01-01 00:00:00' /tmp/evidence
$ stat -c 'M=%y  C=%z' /tmp/evidence
M=2001-01-01 00:00:00.000000000 +0000  C=2026-08-26 09:44:52.113000000 +0000
```

El `mtime` dice 2001. El `ctime` dice que el archivo fue tocado hace 12 segundos. Por eso los barridos forenses usan `find -newerct`, nunca `-newermt`.

---

## 3. Listar e inspeccionar: `ls`, `stat`, `file`

### 3.1 `ls` no es un comando barato

`ls` ejecuta un bucle `getdents64(2)` más — para cualquier cosa que vaya más allá de los nombres pelados — un `statx(2)` **por entrada**. En un directorio con 500.000 entradas sobre almacenamiento en red, `ls -l` son medio millón de idas y vueltas.

| Invocación | Syscalls por entrada | Ordena | Usar cuando |
|---|---|---|---|
| `ls` | 0 extra (color/clasificación pueden añadir `statx`) | sí (nombre) | interactivo |
| `ls -l` | 1 `statx` + búsquedas de nombre para uid/gid | sí | necesitás metadatos |
| `ls -f` | 0 (implica `-aU`, desactiva el orden *y* el color) | **no** | directorios enormes, triage de emergencia |
| `ls -U` | 0 extra | no | enumeración en orden de directorio |
| `ls -1` | 0 extra | sí | tuberías (aún inseguro con nombres raros) |

```
$ time ls -l /var/spool/postfix/deferred | wc -l
412337

real	0m19.884s
user	0m2.113s
sys	0m6.402s

$ time ls -f /var/spool/postfix/deferred | wc -l
412339

real	0m0.712s
user	0m0.188s
sys	0m0.404s
```

Flags que importan operativamente:

```
$ ls -lai --time-style=full-iso --block-size=1 /srv/data
total 8589938688
 262145 drwxr-xr-x. 3 svc  svc         4096 2026-08-26 09:50:11.000000000 +0000 .
      2 drwxr-xr-x. 8 root root        4096 2026-08-01 10:00:00.000000000 +0000 ..
 262149 -rw-r-----. 2 svc  svc   4294967296 2026-08-26 09:12:44.000000000 +0000 shard-00.db
 262150 -rw-r-----. 1 svc  svc   4294967296 2026-08-26 09:12:44.000000000 +0000 shard-01.db
```

`shard-00.db` muestra un contador de enlaces `2` — un segundo nombre apunta a ese inodo en alguna parte. Borrar esta ruta libera **cero** bytes.

Otros flags de alto valor: `-h` (tamaños legibles), `-S` (ordenar por tamaño), `-t` (ordenar por mtime), `-r` (invertir), `-R` (recursivo), `-d` (el directorio en sí, no su contenido — esencial: `ls -ld /srv` vs `ls -l /srv`), `-i` (inodo), `--color=never` (obligatorio en scripts; los códigos de color son secuencias de escape ANSI dentro de tus datos).

> **Nunca parsees la salida de `ls` en un script.** Los nombres de archivo pueden contener espacios, saltos de línea, comillas y secuencias de escape ANSI. `ls` los mutila (`-b`, `-q`, `--quoting-style`) de forma inconsistente. Usá `find -print0` o un glob del shell.

### 3.2 `file` — tipado por contenido, no por extensión

`file(1)` clasifica leyendo magic bytes a través de `libmagic` contra la base de datos compilada `/usr/share/misc/magic.mgc`. Las extensiones le son irrelevantes.

```
$ file /bin/ls /etc/passwd /tmp/backup.tar.gz /dev/sda1 /proc/self/exe
/bin/ls:        ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV), dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2, BuildID[sha1]=897d..., for GNU/Linux 3.2.0, stripped
/etc/passwd:    ASCII text
/tmp/backup.tar.gz: gzip compressed data, from Unix, original size modulo 2^32 1075200
/dev/sda1:      block special (8/1)
/proc/self/exe: symbolic link to /usr/bin/file
```

| Flag | Efecto | Uso en producción |
|---|---|---|
| `-b`, `--brief` | omite el nombre de archivo | scripting |
| `-i`, `--mime` | `text/plain; charset=us-ascii` | negociación de contenido HTTP, validación de subidas |
| `--mime-type` | solo `text/plain` | tablas de despacho |
| `-s` | lee dispositivos de bloque/carácter en lugar de limitarse a llamarlos "special" | **identificar la tabla de particiones / filesystem de un disco crudo** |
| `-z` | mira *dentro* de archivos comprimidos | triage de archivos |
| `-L` | sigue enlaces simbólicos | |
| `-f LIST` | lee nombres de archivo desde un archivo | clasificación masiva |
| `-F SEP` | cambia el separador `: ` | salida parseable |

```
$ sudo file -s /dev/sda1 /dev/sda2
/dev/sda1: Linux rev 1.0 ext4 filesystem data, UUID=6f2a-... (needs journal recovery) (extents) (64bit) (large files) (huge files)
/dev/sda2: LVM2 PV (Linux Logical Volume Manager), UUID: 3kQ1..., size: 213674622976

$ file -z /var/cache/artifacts/app-2.4.1.tar.zst
/var/cache/artifacts/app-2.4.1.tar.zst: POSIX tar archive (GNU) (Zstandard compressed data, ...)
```

`(needs journal recovery)` en un dispositivo al que estabas por hacerle `dd` es un alto total: hacé la imagen en solo lectura, no lo montes en lectura-escritura.

---

## 4. `cp` — la ruta de copia no es una sola ruta

`cp` parece una sola operación. Por debajo, las coreutils GNU modernas (9.x) eligen entre **cuatro** estrategias de movimiento de datos, y la que te toque cambia el rendimiento en dos órdenes de magnitud.

```
        ┌── same fs, supports FICLONE (Btrfs/XFS-reflink/OCFS2) ──► reflink clone: O(1), no data copied
cp ─────┼── copy_file_range(2) available ─────────────────────────► in-kernel copy, no user-space bounce
        ├── source has holes and --sparse=auto ────────────────────► holes preserved via lseek(SEEK_HOLE)
        └── fallback ─────────────────────────────────────────────► read(2)/write(2) loop through a buffer
```

```
$ strace -f -e trace=copy_file_range,ioctl,read,write cp big.img copy.img 2>&1 | head -5
ioctl(4, BTRFS_IOC_CLONE or FICLONE, 3) = 0
close(3)                                = 0
close(4)                                = 0

$ time cp --reflink=always /srv/vm/base.qcow2 /srv/vm/clone.qcow2
real	0m0.011s

$ time cp --reflink=never /srv/vm/base.qcow2 /srv/vm/clone.qcow2
real	0m41.907s
```

Desde coreutils 9.0, `cp`, `mv` e `install` usan `copy_file_range(2)` donde esté disponible, lo que en filesystems con capacidad de reflink produce el clon implícitamente. `--reflink={always,auto,never}` da control explícito; `always` falla ruidosamente si el clonado es imposible — que es exactamente lo que querés en un pipeline de snapshots, para no caer silenciosamente en una copia completa de 40 segundos.

### 4.1 Preservación de atributos — la matriz de flags

| Flag | Preserva | Notas |
|---|---|---|
| *(ninguno)* | nada salvo los datos; el modo es `source mode & ~umask` para archivos nuevos | por defecto |
| `-p` | modo, propiedad (si está permitido), marcas de tiempo | abreviatura de `--preserve=mode,ownership,timestamps` |
| `--preserve=all` | lo anterior **+ contexto (SELinux) + enlaces + xattrs** | lo que necesita una migración |
| `-a`, `--archive` | `-dR --preserve=all` | recursivo, sin dereferenciar, todo |
| `-d` | copia los enlaces simbólicos como enlaces simbólicos; preserva los enlaces duros | `= --no-dereference --preserve=links` |
| `-L` | dereferencia **todos** los enlaces simbólicos (copia los destinos) | expande una granja de symlinks en datos reales |
| `-P` | nunca dereferencia | por defecto para `-R` en GNU cp |
| `-r` / `-R` | recursa en directorios | `-r` copia archivos especiales como archivos regulares en algunas implementaciones; GNU trata `-r` = `-R` |
| `-u` | copia solo si el origen es más nuevo o los tamaños difieren | sincronización burda; no considera el contenido |
| `-n` | nunca sobrescribe (con condición de carrera: stat-luego-open) | preferí `--update=none` en coreutils ≥ 9.3 |
| `-i` | interactivo | inútil en automatización; suele tener alias en el shell — usá `\cp` o `command cp` |
| `-l` | enlace duro en lugar de copiar | "copia" de costo cero dentro de un mismo filesystem |
| `-s` | enlace simbólico en lugar de copiar | requiere rutas absolutas salvo con `-r` |
| `--sparse=WHEN` | `auto` (por defecto) / `always` / `never` | `always` convierte secuencias de ceros en huecos aunque el origen fuera denso |
| `-x`, `--one-file-system` | no cruzar puntos de montaje | **obligatorio** al copiar `/` — si no, recursás dentro de `/proc`, `/sys`, `/dev` |
| `-t DIR` / `-T` | directorio destino explícito / tratar el destino como no-directorio | elimina la ambigüedad "¿quedó en `dst/src` o en `dst`?" |
| `-v` | verboso | |
| `-b`, `--backup=CONTROL` | respalda el destino antes de sobrescribir | `numbered`, `simple`, `existing` |

### 4.2 La ambigüedad de `-T` — una clase real de caída

```
$ ls /srv
config

$ cp -a build /srv/config          # /srv/config EXISTS as a directory
$ ls /srv/config
build                              # ← nested! you wanted the contents

$ rm -rf /srv/config/build
$ cp -aT build /srv/config         # -T: treat destination as a plain name
$ ls /srv/config
app.conf  tls/
```

Sin `-T`, la semántica del destino de `cp` depende de si el objetivo ya existe — lo que significa que tu script de despliegue se comporta distinto en la primera ejecución y en el redespliegue. Usá siempre `-T` (o `-t`) en automatización.

### 4.3 La trampa del glob `.*`

```
$ cp -a /old/app/. /new/app/        # correct: the "/." idiom copies contents INCLUDING dotfiles
$ cp -a /old/app/* /new/app/        # WRONG: silently omits .env, .git, .dockerignore
$ cp -a /old/app/.* /new/app/       # CATASTROPHIC: .* matches "." and ".." → tries to copy the PARENT
```

`cp -a src/. dst/` es la única forma que es a la vez completa y segura.

### 4.4 `cp` vs `rsync` vs tubería de `tar` vs `dd` — compromisos en copias masivas

| Dimensión | `cp -a` | `rsync -aHAX` | `tar -C src -cf - . \| tar -C dst -xf -` | `dd` |
|---|---|---|---|---|
| Reanudable | no (reinicia archivos completos) | **sí** (`--partial --append-verify`) | no | sí (`skip=`/`seek=`) |
| Transferencia diferencial | no | sí (checksum rodante) | no | no |
| Sobre la red | no (necesita un montaje) | **nativo** (SSH/demonio) | sí (vía `ssh`) | sí (vía `ssh`/`nc`) |
| Enlaces duros preservados | `-a` sí | `-H` sí | sí | n/a (nivel de bloque) |
| xattrs / ACLs / SELinux | `--preserve=all` | `-AX` + `--xattrs` | `--xattrs --acls --selinux` | n/a |
| Manejo de sparse | `--sparse=always` | `-S` | `--sparse` | `conv=sparse` |
| Clon reflink / CoW | **sí** | no | no | no |
| Progreso | no | `--info=progress2` | `pv` en la tubería | `status=progress` |
| Millones de archivos pequeños | bueno | lento (protocolo por archivo) | **el mejor** (flujo único) | n/a |
| Copia dispositivos crudos/no montados | no | no | no | **sí** |
| Reejecución idempotente | sobrescribe todo | solo deltas | sobrescribe todo | sobrescribe todo |

**Regla práctica:** mismo host + mismo filesystem → `cp -a` (reflinks). Mismo host + cantidad enorme de archivos → tubería de `tar`. A través de la red o reanudable → `rsync`. Dispositivo de bloque crudo / gestor de arranque / imagen forense → `dd`.

### 4.5 Durabilidad: que `cp` retorne **no** significa que los datos estén en disco

```
$ cp firmware.bin /mnt/usb/ && umount /mnt/usb   # umount flushes — safe
$ cp firmware.bin /mnt/usb/ && echo done         # data may still be in page cache
$ cp firmware.bin /mnt/usb/ && sync -f /mnt/usb/firmware.bin   # explicit, per-filesystem flush
```

`dd` tiene `conv=fsync` / `oflag=direct` para esto; `cp` no tiene nada equivalente — tenés que llamar a `sync(1)`.

---

## 5. `mv` — `rename(2)` y el precipicio EXDEV

`mv` intenta primero `renameat2(2)`. Dentro de un mismo filesystem eso es una **edición de entrada de directorio**: atómica, instantánea, independiente del tamaño, y no toca en absoluto los bloques de datos.

```
$ time mv /srv/data/shard-00.db /srv/data/archive/shard-00.db     # same fs
real	0m0.002s

$ time mv /srv/data/shard-00.db /mnt/nfs/archive/shard-00.db      # different fs → EXDEV
real	1m52.331s
```

Ante `EXDEV` (`Invalid cross-device link`), GNU `mv` degrada a *copiar y luego desenlazar*, y las garantías se derrumban:

| Propiedad | Mismo filesystem (`rename`) | Entre filesystems (copia + unlink) |
|---|---|---|
| Atómico | **sí** — los observadores ven el nombre viejo o el nuevo, nunca ambos, nunca ninguno | **no** — el destino parcial es visible |
| Duración | O(1) | O(tamaño) |
| Inodo preservado | sí (mismo número de inodo, enlaces duros intactos) | **no** — inodo nuevo, grupos de enlaces duros rotos |
| Seguridad ante interrupción | nada que limpiar | deja un destino truncado; el origen sigue presente |
| Necesita 2× espacio | no | **sí** |
| Cambio de `ctime` | sí (cambió el directorio padre) | el destino obtiene un `ctime` nuevo |

```
$ stat -c %i /srv/data/f ; mv /srv/data/f /srv/other/f ; stat -c %i /srv/other/f
262401
262401                     ← same inode: it was a rename

$ df --output=source /srv/data /mnt/nfs | tail -n +2
/dev/mapper/vg0-data
nfs01:/exports/archive     ← different sources ⇒ mv will be a copy
```

**El idioma de publicación atómica.** Como `rename(2)` es atómico *dentro* de un filesystem, así es como se publica configuración o artefactos sin exponer nunca un archivo parcial a un lector:

```
$ tmp=$(mktemp /etc/app/config.json.XXXXXX)   # same directory ⇒ same filesystem, guaranteed
$ render-config > "$tmp"
$ chmod 0644 "$tmp"
$ mv -f "$tmp" /etc/app/config.json           # atomic swap; readers see old or new, never half
```

Escribir el archivo temporal en `/tmp` y luego hacerle `mv` hacia `/etc` **rompe esta garantía** en cualquier sistema donde `/tmp` sea `tmpfs` o un montaje separado — obtenés una copia no atómica y una ventana en la que la configuración está truncada.

Flags:

| Flag | Significado |
|---|---|
| `-f` | fuerza la sobrescritura, sin preguntar (por defecto cuando no hay tty) |
| `-i` | pregunta antes de sobrescribir |
| `-n` | no sobrescribir. Con condición de carrera en coreutils antiguas (stat-luego-rename); coreutils ≥ 9.5 usa `renameat2(RENAME_NOREPLACE)` donde esté soportado |
| `-u` | mueve solo si el origen es más nuevo |
| `-t DIR` / `-T` | la misma desambiguación que en `cp` |
| `-b`, `--backup=CONTROL` | respalda el destino |
| `-v` | verboso |
| `--strip-trailing-slashes` | evita sorpresas con symlinks a directorios |

```
$ mv -bv --backup=numbered app.jar /opt/app/app.jar
renamed 'app.jar' -> '/opt/app/app.jar' (backup: '/opt/app/app.jar.~3~')
```

---

## 6. `rm`, `rmdir`, y por qué borrar no libera nada

`rm` llama a `unlinkat(2)`. Eso elimina una **entrada de directorio** y decrementa `st_nlink`. El inodo y sus bloques de datos se liberan solo cuando *tanto* el contador de enlaces llega a cero *como* el contador de referencias de archivos abiertos del kernel llega a cero.

Este es el incidente de "disco lleno" más común en producción.

```
# df -h /var
Filesystem                Size  Used Avail Use% Mounted on
/dev/mapper/vg0-var        50G   50G     0 100% /var

# du -sh /var
19G	/var                       ← 31 GiB unaccounted for

# lsof +L1
COMMAND     PID   USER   FD   TYPE DEVICE   SIZE/OFF NLINK    NODE NAME
java       2841 tomcat   57w   REG  253,2 31138512896     0  786451 /var/log/tomcat/catalina.out (deleted)
```

`NLINK 0` + `(deleted)` = el archivo está desenlazado pero anclado abierto. `du` no puede verlo (no hay nombre que recorrer). Recuperación, por orden de preferencia:

```
# ls -l /proc/2841/fd/57
l-wx------ 1 root root 64 Aug 26 10:02 /proc/2841/fd/57 -> '/var/log/tomcat/catalina.out (deleted)'

# truncate -s 0 /proc/2841/fd/57      # reclaim space WITHOUT restarting the process
# df -h --output=avail /var
Avail
  30G
```

`> /proc/PID/fd/N` también funciona, pero solo si tu shell puede abrir la ruta del fd para escritura. Reiniciar el proceso también funciona y es el instrumento contundente. Notá que por esto la rotación de logs debe usar `copytruncate` **o** señalar al demonio para que reabra (`logrotate` `postrotate` + `kill -USR1`); un `rm` pelado de un log vivo filtra el espacio hasta el reinicio.

### 6.1 Semántica de flags y salvaguardas de `rm`

| Flag | Significado | Peligro |
|---|---|---|
| `-r`, `-R` | recursivo | el que termina carreras |
| `-f` | ignora archivos inexistentes, nunca pregunta, **sale con 0 aunque no coincida nada** | enmascara fallos en scripts |
| `-i` | pregunta por archivo | `-I` pregunta una sola vez para >3 archivos o recursión — el término medio sensato |
| `-d` | elimina directorios vacíos | como `rmdir` pero componible |
| `-v` | verboso | usalo siempre en automatización destructiva |
| `--one-file-system` | se niega a recursar hacia otro montaje | **esencial** para `rm -rf` de un chroot o del rootfs de un contenedor |
| `--preserve-root` | se niega a operar sobre `/` (**por defecto**) | |
| `--no-preserve-root` | desactiva esa protección | no hay uso legítimo en automatización |

```
$ rm -rf /
rm: it is dangerous to operate recursively on '/'
rm: use --no-preserve-root to override this failsafe
```

`--preserve-root` protege `/` y nada más. `rm -rf /*`, `rm -rf /var` y `rm -rf "$UNSET_VAR/"` están todos desprotegidos.

### 6.2 Patrones de borrado defensivo

```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. ':?' aborts with an error if the variable is unset OR empty.
#    Without it, an unset TARGET makes this "rm -rf /*".
rm -rf -- "${TARGET:?TARGET must be set}"/*

# 2. Refuse to cross a mount boundary while wiping a container rootfs.
rm -rf --one-file-system -- "${ROOTFS:?}"

# 3. End-of-options guard: a file literally named "-rf" is not a flag.
rm -- "$file"        # or:  rm ./"$file"
```

```
$ touch -- -rf
$ rm -rf
rm: missing operand                    # the shell handed rm a flag, not a name
$ rm -- -rf
$ ls
```

### 6.3 `rmdir`

`rmdir` llama a `rmdir(2)` y falla ante un directorio no vacío. Ese fallo es una característica: es la única primitiva segura del tipo "eliminá esto si soy el último usuario".

```
$ rmdir /srv/cache
rmdir: failed to remove '/srv/cache': Directory not empty

$ rmdir -p /srv/a/b/c            # remove c, then b, then a — stopping at the first non-empty
$ rmdir --ignore-fail-on-non-empty /srv/shared/lock.d   # idempotent teardown, exit 0
```

### 6.4 Borrar un archivo cuyo nombre no podés escribir

```
$ ls -li
 262403 -rw-r--r-- 1 root root  0 Aug 26 10:11 'bad\nname'
$ find . -maxdepth 1 -inum 262403 -delete
```

`-inum` esquiva por completo el problema del entrecomillado. La misma técnica sirve para nombres con saltos de línea, retrocesos o secuencias de escape ANSI.

### 6.5 `shred` — y por qué normalmente no hace nada

`shred -u` sobrescribe y luego desenlaza. Solo tiene sentido en un filesystem que sobrescriba bloques en el lugar. Es **inefectivo** en: filesystems con journal en modo `data=journal`, cualquier filesystem copy-on-write (Btrfs, ZFS), cualquier SSD/NVMe (el wear levelling reubica las escrituras), RAID con paridad, filesystems de red y volúmenes con snapshots. Para esos, la respuesta es cifrado de disco completo + destrucción de la clave, no `shred`.

---

## 7. `mkdir` y `touch`

### 7.1 `mkdir`

```
$ umask
0022
$ mkdir plain && stat -c %a plain
755                            # 0777 & ~umask

$ mkdir -m 0700 secret && stat -c %a secret
700                            # -m bypasses umask for THIS directory

$ mkdir -pv /srv/a/b/c
mkdir: created directory '/srv/a'
mkdir: created directory '/srv/a/b'
mkdir: created directory '/srv/a/b/c'

$ mkdir -p /srv/a/b/c && echo "exit=$?"
exit=0                         # -p is idempotent: existing directories are not an error
```

**El detalle traicionero de `-p -m`:** `-m` se aplica solo al directorio *nombrado*. Los padres intermedios se crean con `u+wx` modificado por la umask — quedarán en `0755`, no en `0700`.

```
$ umask 022; mkdir -p -m 0700 /srv/vault/keys
$ stat -c '%a %n' /srv/vault /srv/vault/keys
755 /srv/vault                  ← world-traversable parent
700 /srv/vault/keys
```

Si toda la ruta debe ser privada, creala y después hacé `chmod` explícitamente, o creá cada nivel con su propio `mkdir -m`.

La expansión de llaves + `-p` es el constructor de árboles idiomático:

```
$ mkdir -p /srv/app/{bin,etc,var/{log,cache,run},share/doc}
$ find /srv/app -type d | sort
/srv/app
/srv/app/bin
/srv/app/etc
/srv/app/share
/srv/app/share/doc
/srv/app/var
/srv/app/var/cache
/srv/app/var/log
/srv/app/var/run
```

`mkdir -p` **no es atómico** entre niveles pero *sí* es seguro ante carreras en cada nivel (tolera `EEXIST`). `mkdir dir` sin `-p` **es** un test-and-set atómico — lo que lo convierte en una primitiva de bloqueo correcta, a diferencia de `[ -e lock ] || touch lock`:

```bash
if mkdir /var/run/job.lock 2>/dev/null; then
    trap 'rmdir /var/run/job.lock' EXIT
    do_work
else
    echo "another instance holds the lock" >&2; exit 1
fi
```

### 7.2 `touch`

`touch` hace dos cosas: crear archivos vacíos (`open(O_CREAT)`) y establecer marcas de tiempo (`utimensat(2)`).

| Flag | Efecto |
|---|---|
| *(ninguno)* | pone `atime` y `mtime` en ahora; crea si no existe |
| `-a` | solo `atime` |
| `-m` | solo `mtime` |
| `-c`, `--no-create` | nunca crea; solo marca archivos existentes |
| `-d STRING` | fecha desde una cadena de formato libre (`'2 hours ago'`, `'2026-08-26T09:00:00Z'`) |
| `-t [[CC]YY]MMDDhhmm[.ss]` | forma numérica POSIX |
| `-r REF` | copia las marcas de tiempo de un archivo de referencia |
| `-h` | marca el enlace simbólico en sí, no su destino |

```
$ touch -t 202608260900.00 marker
$ find /var/log -newer marker -type f       # everything written since 09:00
/var/log/syslog
/var/log/nginx/access.log

$ touch -r /etc/passwd /tmp/clone && stat -c '%y' /etc/passwd /tmp/clone
2026-08-14 11:02:19.000000000 +0000
2026-08-14 11:02:19.000000000 +0000
```

El truco del archivo de referencia es el clásico marcador de backup incremental, y es exactamente lo que consume `find -newer`.

---

## 8. File globbing — lo hace el shell, el comando nunca lo ve

**El hecho más importante de todo este objetivo:** `rm *.log` no le pasa `*.log` a `rm`. Bash expande el patrón leyendo el directorio, ordena las coincidencias y le entrega a `rm` un `argv[]` completamente materializado. Todas las propiedades siguientes se derivan de eso.

### 8.1 Comodines simples (expansión de rutas POSIX)

| Patrón | Coincide con | **No** coincide con |
|---|---|---|
| `*` | cualquier cadena, incluida la vacía | un `.` inicial; un `/` |
| `?` | exactamente un carácter | un `.` inicial; un `/` |
| `[abc]` | uno de `a`, `b`, `c` | |
| `[!abc]` / `[^abc]` | cualquier carácter **fuera** del conjunto | (`^` es una extensión de bash; `!` es POSIX) |
| `[a-z]` | un rango de **colación** — ¡depende del locale! | |
| `[[:digit:]]` | clase de caracteres POSIX — segura respecto al locale | |

```
$ ls
a.log  B.LOG  c.log  10.log  .hidden.log

$ echo *.log
10.log a.log c.log                # B.LOG excluded (case), .hidden.log excluded (leading dot)

$ echo [[:digit:]]*.log
10.log

$ LC_ALL=en_US.UTF-8 bash -c 'echo [a-c]*'    # en_US collation is case-insensitive-ish
a.log B.LOG c.log
$ LC_ALL=C bash -c 'echo [a-c]*'              # C collation is pure byte order
a.log c.log
```

> **Fijá siempre `LC_COLLATE=C` (o usá clases `[[:alpha:]]`) en scripts que usen rangos.** Un patrón `[a-z]` que se comporta de una manera en tu shell y de otra bajo `cron` (que tiene un entorno mínimo) es un bug de producción genuino y frecuente.

Para coincidir con un punto literal hay que escribirlo — `*` nunca coincide con un `.` inicial:

```
$ echo .*                # includes "." and ".." — the source of countless disasters
. .. .hidden.log
$ echo .[!.]* ..?*       # the safe "all dotfiles, no . or .." idiom
.hidden.log
```

### 8.2 Globbing avanzado (`shopt` de bash)

| Opción | Efecto | Activar |
|---|---|---|
| `extglob` | `?(p)` 0–1, `*(p)` 0+, `+(p)` 1+, `@(p)` exactamente uno, `!(p)` cualquier cosa excepto | `shopt -s extglob` |
| `globstar` | `**` cruza límites de directorio recursivamente; `**/` coincide solo con directorios | `shopt -s globstar` |
| `nullglob` | un patrón sin coincidencias se expande a **nada** en vez de a sí mismo | `shopt -s nullglob` |
| `failglob` | un patrón sin coincidencias es un **error duro** | `shopt -s failglob` |
| `dotglob` | `*` incluye dotfiles (pero nunca `.`/`..`) | `shopt -s dotglob` |
| `nocaseglob` | coincidencia sin distinguir mayúsculas | `shopt -s nocaseglob` |
| `GLOBIGNORE` | patrones separados por dos puntos a excluir; definirla también implica semántica `dotglob` para `.`/`..` | variable |

```
$ shopt -s extglob
$ ls
app.log  app.log.1  app.log.2.gz  app.log.3.gz  config.yaml

$ echo !(*.gz)                     # everything that is not gzipped
app.log app.log.1 config.yaml

$ echo app.log.+([0-9]).gz         # numbered, gzipped rotations only
app.log.2.gz app.log.3.gz

$ shopt -s globstar
$ echo **/*.yaml
config.yaml  k8s/base/deploy.yaml  k8s/overlays/prod/kustomization.yaml
```

**La trampa de `nullglob` que muerde a todo script de shell:**

```bash
# Default behaviour: an unmatched pattern is passed through LITERALLY.
$ cd /empty-dir
$ for f in *.log; do echo "processing $f"; done
processing *.log                   # ← there is no file named "*.log"

# rm then does something entirely different than you intended:
$ rm -f *.log                      # harmless here (-f), but "gzip *.log" errors,
                                   # and "cat *.log > merged" creates a file named "*.log"
$ shopt -s nullglob
$ for f in *.log; do echo "processing $f"; done
                                   # loop body never runs — correct
```

Activá `nullglob` para bucles y `failglob` para scripts que no deben continuar en silencio.

### 8.3 La expansión de llaves **no** es globbing

| | Llaves `{a,b}` | Glob `*?[]` |
|---|---|---|
| Orden en la expansión de bash | **primero** (antes de tilde, parámetros y rutas) | **anteúltimo** (antes de la eliminación de comillas) |
| Lee el filesystem | **no** | sí |
| Resultado sin coincidencias | igual se expande | depende de `nullglob`/`failglob` |
| Uso | *generar* nombres (crear, rangos) | *seleccionar* nombres existentes |

```
$ echo file{1..3}.txt              # generates, regardless of what exists
file1.txt file2.txt file3.txt
$ echo file{01..10..3}.txt         # zero-padded, stepped
file01.txt file04.txt file07.txt file10.txt
$ echo {a..e}
a b c d e
$ cp /etc/nginx/nginx.conf{,.bak}  # → cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
```

### 8.4 `ARG_MAX` — donde el globbing se rompe físicamente

Como el shell materializa el vector de argumentos completo, un glob que coincide con suficientes archivos excede el límite de `execve(2)` del kernel.

```
$ getconf ARG_MAX
2097152

$ xargs --show-limits < /dev/null
Your environment variables take up 2027 bytes
POSIX upper limit on argument length (this system): 2093077
POSIX smallest allowable upper limit on argument length (all systems): 4096
Maximum length of command we could actually use: 2091050
Size of command buffer we are actually using: 131072
Maximum parallelism (--max-procs must be no greater than): 2147483647

$ ls /var/log/app | wc -l
412337
$ rm /var/log/app/*.log
-bash: /usr/bin/rm: Argument list too long
```

Dos límites adicionales que la gente pasa por alto: `MAX_ARG_STRLEN` limita un **único** argumento a 128 KiB (32 páginas) independientemente de `ARG_MAX`, y el bloque de entorno cuenta contra el mismo presupuesto — un `env` gordo de un runner de CI reduce tu argv utilizable.

Cinco salidas, ordenadas:

| Enfoque | Maneja nombres raros | Costo de fork | Notas |
|---|---|---|---|
| `find DIR -maxdepth 1 -name '*.log' -delete` | **sí** | 1 proceso | El mejor. Sin `exec` alguno. |
| `find DIR -name '*.log' -print0 \| xargs -0 -r rm` | **sí** (`-print0`) | por lotes | `-r` omite la ejecución si la entrada está vacía |
| `find DIR -name '*.log' -exec rm {} +` | **sí** | por lotes | equivalente a `xargs`, sin tubería |
| `printf '%s\0' DIR/*.log \| xargs -0 rm` | sí | por lotes | igual construye el glob en la memoria del shell (sin límite de `execve`, pero sí de RAM) |
| bucle de shell `for f in DIR/*.log; do rm "$f"; done` | sí | 0 (`rm` externo, no builtin → 1 fork cada vez) | el glob está dentro del shell, así que no hay `E2BIG`, pero sí N forks |

```
$ find /var/log/app -maxdepth 1 -type f -name '*.log' -delete
$ echo $?
0
```

---

## 9. `find` — un motor de consultas para el árbol de archivos

`find` no es "un comando para buscar archivos". Es un evaluador de expresiones: recorre un árbol y evalúa una expresión booleana por nodo, donde algunos operandos tienen efectos secundarios (`-print`, `-delete`, `-exec`).

```
find [-H|-L|-P] [-D opts] [-Olevel] PATH... [EXPRESSION]
      ▲                                       ▲
      │                                       └── tests · actions · operators
      └── symlink policy
```

### 9.1 Política de enlaces simbólicos y control del recorrido

| Opción | Comportamiento |
|---|---|
| `-P` | **por defecto.** Nunca sigue enlaces simbólicos; `-type l` los ve |
| `-L` | Sigue enlaces simbólicos; `-type` informa el tipo del *destino*; los enlaces rotos se reportan como `l` |
| `-H` | Sigue únicamente los enlaces simbólicos nombrados en la línea de comandos |
| `-xdev` / `-mount` | No desciende a otros filesystems |
| `-maxdepth N` / `-mindepth N` | Acota la recursión (**deben preceder a otros tests** por eficiencia; GNU advierte si no) |
| `-depth` | Procesa el contenido de un directorio antes que el directorio mismo (post-orden) — implícito con `-delete` |
| `-prune` | No desciende al directorio actual (valor verdadero; combinar con `-o`) |

`-L` sobre un árbol que contiene un bucle de enlaces simbólicos es la forma de colgar un job de backup:

```
$ find -L /srv -type f | head -3
find: File system loop detected; '/srv/self/self' is part of the same file system loop as '/srv'.
```

### 9.2 Tests

| Test | Significado | Detalle traicionero |
|---|---|---|
| `-name PAT` / `-iname` | glob contra el **nombre base** | el patrón debe ir entrecomillado o el shell se lo come |
| `-path PAT` / `-ipath` | glob contra la **ruta completa**; `*` cruza `/` | |
| `-regex PAT` | regex contra la ruta completa; `-regextype posix-extended` | anclado en ambos extremos |
| `-type c` | `f` archivo, `d` directorio, `l` enlace simbólico, `b` bloque, `c` carácter, `p` fifo, `s` socket | GNU acepta una lista: `-type f,l` |
| `-size N[cwbkMG]` | la unidad por defecto son **bloques de 512 bytes**; `c`=bytes | **el tamaño se redondea HACIA ARRIBA** — ver abajo |
| `-empty` | archivo de longitud cero o directorio vacío | |
| `-user`/`-group`/`-uid`/`-gid` | propiedad | `-nouser`/`-nogroup` encuentra archivos huérfanos tras una migración de UID |
| `-perm MODE` | exacto | `-perm -MODE` = todos estos bits activos; `-perm /MODE` = cualquiera de estos bits |
| `-links N` | contador de enlaces duros | `-links +1` encuentra archivos con múltiples nombres |
| `-inum N` | número de inodo | la escotilla de escape para "nombre de archivo inentrecomillable" |
| `-mtime N` / `-atime` / `-ctime` | antigüedad en **períodos de 24 horas**, descartando la fracción | ver abajo |
| `-mmin N` / `-amin` / `-cmin` | antigüedad en minutos — usá estos | |
| `-newer F` / `-newerXY REF` | X,Y ∈ {a,B,c,m,t}: `-newermt '2026-08-01'`, `-newerct '2 hours ago'` | la herramienta precisa |
| `-fstype T` | `ext4`, `xfs`, `nfs`, `tmpfs` | se combina con `-xdev` |

**La trampa de redondeo de `-mtime`.** `find` calcula `(now - mtime) / 86400` y **trunca**. Entonces:

- `-mtime 0` → modificado en las últimas 24 h
- `-mtime 1` → entre 24 y 48 h atrás
- `-mtime +1` → **estrictamente más que 1** tras truncar ⇒ al menos **48 h** atrás, no 24
- `-mtime -1` → menos de 24 h atrás (igual que `-mtime 0`)

Un job de retención escrito como `-mtime +7` conserva 8 días, no 7. Usá `-mmin +10080` o `-newermt` cuando el límite importe.

**La trampa de redondeo de `-size`.** Los tamaños se redondean hacia arriba a la siguiente unidad completa *antes* de comparar.

```
$ truncate -s 500K half
$ find . -size -1M
.                        # the directory
                         # 'half' is NOT listed: 500K rounds UP to 1M, and 1M is not < 1M
$ find . -size -1025k -size +1c -type f
./half                   # use a smaller unit, or use -size -1048576c
```

`-size -1M` coincide únicamente con archivos **vacíos**. Expresá siempre los umbrales de tamaño en `c` (bytes) en automatización.

### 9.3 Operadores y precedencia — el bug de `-print`

Precedencia, de mayor a menor: `( )` → `!` / `-not` → `-a` / `-and` (**implícito**) → `-o` / `-or` → `,`.

```
$ find . -name '*.log' -o -name '*.txt' -print
./notes.txt
```

Solo se imprimieron los archivos `.txt`. `-a` liga más fuerte que `-o`, así que esto se parseó como
`-name '*.log' OR ( -name '*.txt' AND -print )`. Además, como no había ninguna acción unida a la rama izquierda, la regla del "`-print` por defecto" de `find` quedó suprimida por la presencia de un `-print` explícito. Forma correcta:

```
$ find . \( -name '*.log' -o -name '*.txt' \) -print
./app.log
./notes.txt
```

**El podado** — el idioma para excluir subárboles, y la razón por la que `-prune` siempre va seguido de `-o`:

```
$ find /srv \
    \( -path '/srv/*/node_modules' -o -path '/srv/*/.git' -o -fstype nfs \) -prune \
    -o -type f -name '*.jar' -print
/srv/app/lib/core-2.4.1.jar
/srv/app/lib/netty-4.1.99.jar
```

Leelo así: "si el nodo coincide con el conjunto de exclusión, podá (y detené) — **si no**, evaluá e imprimí".

### 9.4 Acciones, y el precipicio de rendimiento de `-exec`

| Acción | Procesos generados | Segura ante NUL | Considera el código de salida | Notas |
|---|---|---|---|---|
| `-print` | 0 | no (delimitado por saltos de línea) | — | acción por defecto |
| `-print0` | 0 | **sí** | — | combinar con `xargs -0` |
| `-printf FMT` | 0 | depende del FMT | — | el caballo de batalla de la salida estructurada |
| `-delete` | 0 | **sí** | sí | implica `-depth`; rechaza directorios no vacíos |
| `-exec cmd {} \;` | **uno por archivo** | sí | no detiene nada ante un fallo | O(N) forks |
| `-exec cmd {} +` | por lotes (como `xargs`) | sí | | O(N/lote) forks |
| `-execdir cmd {} \;` / `+` | como arriba, **cwd = directorio del archivo** | sí | | inmune a una clase de carreras con enlaces simbólicos |
| `-ok` / `-okdir` | confirmación interactiva | sí | | nunca en automatización |
| `-quit` | 0 | — | — | detiene tras la primera coincidencia (test de existencia barato) |
| `-ls` | 0 | no | — | salida estilo `ls -dils` |

```
$ time find /var/cache/app -type f -name '*.tmp' -exec rm {} \;
real	0m38.412s
user	0m2.918s
sys	0m21.774s                     # 41,000 fork+exec pairs

$ time find /var/cache/app -type f -name '*.tmp' -exec rm {} +
real	0m1.204s

$ time find /var/cache/app -type f -name '*.tmp' -delete
real	0m0.981s                    # zero exec: unlinkat(2) inline
```

`-exec ... +` solo funciona cuando `{}` es el **último** argumento. Si necesitás `{}` en el medio, necesitás `\;` (un fork por archivo) o `xargs -I{}`:

```
$ find . -name '*.conf' -exec cp {} /backup/ \;          # {} not last → forced \;
$ find . -name '*.conf' -exec cp -t /backup/ {} +        # -t moves the dir first → batching works
```

**El contrato delimitado por NUL.** Los nombres de archivo pueden contener cualquier byte salvo `/` y NUL. Eso hace que NUL sea el único delimitador seguro:

```
$ touch $'weird\nname.log'
$ find . -name '*.log' | xargs rm            # BROKEN: splits on the newline
rm: cannot remove './weird': No such file or directory
rm: cannot remove 'name.log': No such file or directory

$ find . -name '*.log' -print0 | xargs -0 -r rm     # correct
```

Flags de `xargs` que conviene conocer: `-0` (entrada con NUL), `-r`/`--no-run-if-empty` (no ejecutar el comando con entrada vacía — solo GNU, y la razón por la que `xargs rm` sobre un conjunto vacío en otro caso no borra nada pero *sí* ejecuta `rm` sin argumentos), `-n N` (argumentos por invocación), `-P N` (paralelo), `-I{}` (cadena de reemplazo, implica `-L1`).

### 9.5 `-printf` — convertir el filesystem en un conjunto de datos

| Especificador | Significado |
|---|---|
| `%p` ruta completa · `%f` nombre base · `%h` directorio · `%P` ruta menos el punto de partida |
| `%s` tamaño en bytes · `%k` tamaño en bloques KiB · `%b` bloques de 512 bytes |
| `%y` letra de tipo · `%i` inodo · `%n` contador de enlaces · `%d` profundidad |
| `%M` modo simbólico · `%m` modo octal · `%u`/`%U` usuario · `%g`/`%G` grupo |
| `%T@` mtime como epoch.nanosegundos · `%TY-%Tm-%Td` formateado · `%CT`/`%AT` para ctime/atime |
| `\0` NUL · `\n` salto de línea · `\t` tabulación |

One-liners de producción:

```
# The 10 largest files under /var, NUL-safe, sorted numerically
$ find /var -xdev -type f -printf '%s\t%p\n' | sort -rn | head -10
34359738368	/var/lib/postgresql/16/main/base/16384/1259
8589934592	/var/log/tomcat/catalina.out
...

# Disk usage by top-level directory, excluding other mounts
$ find /var -xdev -maxdepth 1 -mindepth 1 -type d -printf '%f\0' \
    | xargs -0 du -sh --one-file-system 2>/dev/null | sort -h
1.2M	run
44M	tmp
2.1G	cache
19G	lib

# Every SUID/SGID binary on the root filesystem (baseline for drift detection)
$ sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f \
    -printf '%m %u %g %p\n' | sort
4755 root root /usr/bin/chsh
4755 root root /usr/bin/gpasswd
4755 root root /usr/bin/newgrp
4755 root root /usr/bin/passwd
4755 root root /usr/bin/su
2755 root tty  /usr/bin/wall
...

# World-writable files and directories missing the sticky bit
$ sudo find / -xdev -type d -perm -0002 ! -perm -1000 -printf '%M %p\n'
drwxrwxrwx /srv/uploads

# Files orphaned by a UID migration
$ sudo find /home -xdev \( -nouser -o -nogroup \) -printf '%U:%G %p\n' | head

# Anything modified since the last known-good deploy marker
$ find /opt/app -newer /var/lib/deploy/last-good.stamp -type f -printf '%TY-%Tm-%Td %TH:%TM %p\n'
2026-08-26 09:41 /opt/app/conf/application.yaml

# Reproducible file list (directory order is NOT deterministic)
$ find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > MANIFEST
```

### 9.6 Job de retención, hecho correctamente

```bash
#!/usr/bin/env bash
# /usr/local/sbin/prune-logs — production log retention
set -euo pipefail

readonly ROOT=${1:?usage: prune-logs <dir> [days]}
readonly DAYS=${2:-14}

[[ -d $ROOT ]] || { echo "not a directory: $ROOT" >&2; exit 2; }

# -xdev            : never cross into another mount (e.g. an NFS share)
# -newermt         : exact boundary, no 24h truncation surprise
# ! -newermt       : negation gives "older than"
# -delete          : no fork storm; implies -depth so dirs empty before removal
find "$ROOT" -xdev -type f -name '*.log.*' \
     ! -newermt "-${DAYS} days" \
     -printf 'pruning %s bytes: %p\n' \
     -delete

# Second pass: reap directories that the first pass emptied.
find "$ROOT" -xdev -mindepth 1 -type d -empty -delete
```

---

## 10. Archivado: `tar`, `cpio`, `dd`

### 10.1 Elegir un archivador

| | `tar` | `cpio` | `dd` |
|---|---|---|---|
| Unidad de trabajo | archivos + metadatos | archivos + metadatos | **bloques crudos** |
| Entrada | argumentos de ruta, recursivo por sí mismo | **lista de nombres por stdin** | un flujo de bytes / dispositivo |
| Consciente del filesystem | sí | sí | **no** — copia espacio libre, datos borrados, todo |
| Preserva enlaces duros | sí | sí | n/a |
| Archivos sparse | `--sparse` | no | `conv=sparse` |
| Extracción de miembro con acceso aleatorio | recorrido lineal, pero soportado | recorrido lineal | n/a |
| Transmisible por tubería | sí | sí | sí |
| Uso canónico | backups, capas de contenedor, tarballs de código fuente | **initramfs**, cargas útiles RPM, selección dirigida por `find` | imágenes de disco, gestores de arranque, MBR, lecturas/escrituras precisas por offset |
| Maneja un filesystem que no puede montar | no | no | **sí** |

### 10.2 `tar`

**Modos de operación (se requiere exactamente uno):**

| Modo | Forma larga | Significado |
|---|---|---|
| `-c` | `--create` | crear |
| `-x` | `--extract` | extraer |
| `-t` | `--list` | listar |
| `-r` | `--append` | agregar a un archivo **sin comprimir** |
| `-u` | `--update` | agregar solo miembros más nuevos |
| `-A` | `--concatenate` | concatenar archivos |
| `-d` | `--diff` / `--compare` | comparar el archivo con el filesystem |
| `--delete` | | eliminar miembros (sin comprimir, no en cinta) |

**Modificadores esenciales:**

| Flag | Significado |
|---|---|
| `-f FILE` | archivo de destino; `-` significa stdin/stdout |
| `-v` | verboso (`-vv` para detalle estilo `ls -l`) |
| `-C DIR` | `chdir` antes del siguiente operando — **posicional**, y la forma correcta de controlar rutas |
| `-p`, `--preserve-permissions` | restaura los modos exactos (por defecto al extraer como root) |
| `--same-owner` / `--no-same-owner` | root usa same-owner por defecto; no-root usa no-same-owner |
| `--numeric-owner` | almacena/restaura UID/GID crudos, nunca nombres — obligatorio para restauraciones entre hosts |
| `-z` gzip · `-j` bzip2 · `-J` xz · `--zstd` · `--lzma` · `-Z` compress | compresión |
| `-a`, `--auto-compress` | elige el compresor según el sufijo del nombre de salida |
| `-I 'PROG'`, `--use-compress-program` | compresor arbitrario con flags: `-I 'zstd -19 -T0'` |
| `--exclude=PAT` / `--exclude-from=FILE` / `--exclude-vcs` | selección |
| `-T FILE`, `--files-from` | lee la lista de miembros desde un archivo; `--null` para delimitación por NUL |
| `--strip-components=N` | descarta N componentes iniciales de ruta al extraer |
| `--one-file-system` | se detiene en los límites de montaje |
| `--sparse` | detecta y almacena huecos eficientemente |
| `--xattrs --acls --selinux` | metadatos extendidos |
| `--listed-incremental=SNAR` | backups incrementales GNU |
| `--wildcards` / `--anchored` | semántica de glob para la selección de miembros |
| `-P`, `--absolute-names` | conserva la `/` inicial y `..` — **desactiva el recorte de seguridad** |

**El formato importa más de lo que la gente cree:**

| Formato (`--format=`) | Ruta máx. | Tamaño máx. de archivo | UID/GID máx. | mtime sub-segundo | xattrs | Portabilidad |
|---|---|---|---|---|---|---|
| `v7` | 99 | 8 GiB | 2097151 | no | no | antiguo |
| `ustar` (POSIX.1-1988) | 100 + prefijo de 155 | **8 GiB** | 2097151 | no | no | universal |
| `gnu` (**por defecto en GNU tar**) | ilimitada | ilimitado | ilimitado | no | no | GNU/bsdtar |
| `oldgnu` | ilimitada | ilimitado | ilimitado | no | no | heredado |
| `pax` / `posix` (POSIX.1-2001) | ilimitada | ilimitado | ilimitado | **sí** | **sí** | moderno, el default correcto |

```
$ tar --version | head -1
tar (GNU tar) 1.35
```

Un límite de 8 GiB en `ustar` no es teórico — un volcado de base de datos de 12 GiB hacia un archivo `ustar` falla, y algunas cadenas de herramientas viejas producen `ustar` por defecto. Usá `--format=pax` para cualquier cosa moderna.

**Seguridad de rutas.** GNU tar recorta la `/` inicial y rechaza componentes `..` al extraer, salvo que se pase `-P`:

```
$ tar -cf etc.tar /etc/nginx
tar: Removing leading `/' from member names
$ tar -tf etc.tar | head -2
etc/nginx/
etc/nginx/nginx.conf
```

Esto es un **control de seguridad** (la clase "Zip Slip" / tar-slip). Nunca extraigas un archivo no confiable con `-P`. Inspeccioná siempre primero:

```
$ tar -tvf untrusted.tar | awk '$NF ~ /^\/|\.\./ {print "UNSAFE:", $NF}'
```

**La regla posicional de `-C`** — la diferencia entre un archivo limpio y uno con `srv/app/` incrustado en cada ruta:

```
$ tar -czf app.tgz /srv/app                # members: srv/app/...
$ tar -czf app.tgz -C /srv app             # members: app/...
$ tar -czf app.tgz -C /srv/app .           # members: ./...   ← usually what you want
```

**Verificación y comparación:**

```
$ tar -tzvf backup.tgz | head -4
drwxr-xr-x svc/svc           0 2026-08-26 09:00 ./
-rw-r----- svc/svc     4194304 2026-08-26 09:00 ./data/shard-00.db
-rw-r--r-- root/root       412 2026-08-14 11:02 ./etc/app.conf
lrwxrwxrwx root/root         0 2026-08-01 10:00 ./bin/current -> ./bin/2.4.1

$ tar -df backup.tgz -C /srv/app          # compare archive against the live tree
./etc/app.conf: Mod time differs
./etc/app.conf: Size differs
$ echo $?
1
```

`tar -d` es la validación post-restauración más barata que tenés, y casi nadie la usa.

**Backups incrementales (GNU):**

```
# Level 0 — full. The .snar file records directory state and IS PART OF THE BACKUP.
$ sudo tar --create --file=/backup/l0.tar.zst --zstd \
      --listed-incremental=/backup/app.snar \
      --numeric-owner --xattrs --acls --selinux --one-file-system \
      -C /srv/app .
$ cp /backup/app.snar /backup/app.snar.l0     # snapshot the snapshot file!

# Level 1 — only what changed since the snar was last written.
$ sudo tar --create --file=/backup/l1.tar.zst --zstd \
      --listed-incremental=/backup/app.snar \
      --numeric-owner --xattrs --acls --selinux --one-file-system \
      -C /srv/app .

# Restore MUST replay levels in order, with -G/--incremental on extract.
$ sudo tar --extract --incremental --file=/backup/l0.tar.zst --zstd -C /restore
$ sudo tar --extract --incremental --file=/backup/l1.tar.zst --zstd -C /restore
```

Perder el `.snar` hace que el próximo "incremental" se convierta silenciosamente en un backup completo — o peor, que la restauración no borre los archivos que se eliminaron entre niveles. Versionalo junto a los archivos.

**Tarballs reproducibles** (bytes idénticos para contenido idéntico — el requisito para capas de contenedor cacheables y releases firmadas):

```bash
#!/usr/bin/env bash
set -euo pipefail
: "${SOURCE_DATE_EPOCH:?set to the commit timestamp}"

tar --create \
    --file=- \
    --format=pax \
    --sort=name \
    --mtime="@${SOURCE_DATE_EPOCH}" \
    --owner=0 --group=0 --numeric-owner \
    --pax-option='exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime' \
    --exclude-vcs \
    -C "${SRCDIR}" . \
  | gzip -9 -n > "${OUT}.tar.gz"      # -n: omit gzip's embedded name+mtime
```

Cada flag de ahí elimina una fuente de no determinismo: orden de directorio, marcas de tiempo, propiedad, nombres de cabeceras extendidas pax y la cabecera de gzip. Sacá cualquiera y tu SHA cambia entre builds.

### 10.3 `cpio`

`cpio` lee su lista de archivos desde **stdin**. Ese es todo su diseño y toda su ventaja: la lógica de selección es `find`, así que compone con todo lo del §9.

**Tres modos:**

| Modo | Flag | Lee | Escribe |
|---|---|---|---|
| copy-**out** | `-o` / `--create` | nombres de archivo por stdin | archivo por stdout |
| copy-**in** | `-i` / `--extract` | archivo por stdin | archivos en el cwd |
| copy-**pass** | `-p` / `--pass-through` | nombres de archivo por stdin | archivos bajo un directorio destino (sin archivo empaquetado) |

**Formatos (`-H`):**

| Formato | Ancho de inodo | Tamaño máx. | Notas |
|---|---|---|---|
| `bin` | 16 bits, dependiente del orden de bytes | 2 GiB | obsoleto, no portable |
| `odc` | carácter POSIX antiguo | 8 GiB | portable, antiguo |
| `newc` | hex de 8 bytes, inodo de 32 bits | **4 GiB por archivo** | **SVR4 — lo que el kernel Linux requiere para initramfs** |
| `crc` | `newc` + checksum | 4 GiB | apto para initramfs, con verificación de integridad |
| `tar` / `ustar` | — | — | cpio escribiendo tar |
| `hpbin` / `hpodc` | variantes de HP-UX | | |

**Flags clave:** `-d`/`--make-directories`, `-m`/`--preserve-modification-time`, `-v`, `-u`/`--unconditional` (sobrescribe aunque sea más nuevo), `-t`/`--list`, `--no-absolute-filenames` (**seguridad**), `-0`/`--null` (entrada delimitada por NUL — combinar con `find -print0`), `-F FILE` (archivo en vez de stdio), `-p -d -m -l` para la copia pass-through con enlaces duros.

```
# Create a NUL-safe archive of exactly the files find selected
$ find /srv/app -xdev -type f -newermt '-1 day' -print0 \
    | cpio --null --create --format=newc --verbose > /backup/delta.cpio
/srv/app/etc/app.conf
/srv/app/var/state.db
2048 blocks

# List
$ cpio -itv < /backup/delta.cpio
-rw-r--r--   1 svc      svc           412 Aug 26 09:41 srv/app/etc/app.conf
-rw-r-----   1 svc      svc       1048576 Aug 26 09:12 srv/app/var/state.db
2048 blocks

# Extract safely: make dirs, preserve mtimes, refuse absolute paths
$ mkdir -p /restore && cd /restore
$ cpio -idmv --no-absolute-filenames < /backup/delta.cpio
srv/app/etc/app.conf
srv/app/var/state.db
2048 blocks
```

**Construir un initramfs** — el caso de uso canónico de `newc`, y la razón por la que este formato está en el examen:

```
$ cd /tmp/initramfs-root
$ find . -print0 | cpio --null --create --format=newc --owner=root:root \
    | zstd -19 -T0 > /boot/initramfs-6.9.0.img
128512 blocks

$ file /boot/initramfs-6.9.0.img
/boot/initramfs-6.9.0.img: Zstandard compressed data (v0.8+), Dictionary ID: None

# Inspect an existing one
$ zstdcat /boot/initramfs-6.9.0.img | cpio -itv | head -5
drwxr-xr-x   1 root     root            0 Aug 20 08:00 .
drwxr-xr-x   1 root     root            0 Aug 20 08:00 bin
lrwxrwxrwx   1 root     root            7 Aug 20 08:00 bin/sh -> busybox
-rwxr-xr-x   1 root     root       824328 Aug 20 08:00 bin/busybox
-rwxr-xr-x   1 root     root         3128 Aug 20 08:00 init
```

El desempaquetador de initramfs del kernel solo entiende `newc`/`crc`. Entregale un `tar` y la máquina no arranca.

**Modo copy-pass** — una copia de árbol sin archivo intermedio que preserva enlaces duros, útil cuando `cp -a` no está disponible en un entorno de rescate:

```
$ cd /source && find . -depth -print0 | cpio -0 -pdmv /destination
```

### 10.4 `dd`

`dd` es un copiador a **nivel de bloque** con control explícito sobre offsets, tamaños de bloque y flags de E/S. No es más rápido que `cp`, no tiene conciencia del filesystem y destruirá alegremente una tabla de particiones. Su valor es la precisión.

**Operandos (atención: `=`, no `--`):**

| Operando | Significado |
|---|---|
| `if=FILE` / `of=FILE` | entrada/salida (por defecto stdin/stdout) |
| `bs=N` | tamaño de bloque tanto de lectura como de escritura |
| `ibs=N` / `obs=N` | tamaños de bloque de entrada/salida separados |
| `count=N` | copia N bloques de entrada (`iflag=count_bytes` para que N sea un conteo de bytes) |
| `skip=N` | omite N bloques de **entrada** antes de copiar |
| `seek=N` | omite N bloques de **salida** antes de escribir |
| `status=none\|noxfer\|progress` | `progress` imprime una tasa en vivo |
| `conv=...` | conversión de datos / comportamiento |
| `iflag=` / `oflag=` | flags de `open(2)` y de lectura/escritura por lado |

Sufijos: `c`=1, `w`=2, `b`=512, `K`/`KiB`=1024, `KB`=1000, `M`, `G`, `T`.

**Valores de `conv=` que importan:**

| Valor | Efecto |
|---|---|
| `notrunc` | **no** truncar el archivo de salida — obligatorio al parchear en el lugar |
| `noerror` | continúa tras un error de lectura (¡combinar con `sync`, o los offsets se desplazan!) |
| `sync` | rellena cada bloque de entrada hasta `ibs` con NULs — hace que `noerror` preserve los offsets |
| `sparse` | escribe huecos en lugar de bloques de NULs |
| `fsync` / `fdatasync` | vacía antes de salir — si no, `dd` retorna con los datos en la caché de páginas |
| `excl` / `nocreat` | falla si la salida existe / falla si no existe |
| `swab` | intercambia pares de bytes (endianness) |

**Valores de `iflag`/`oflag` que importan:**

| Valor | Efecto |
|---|---|
| `direct` | `O_DIRECT`, evita la caché de páginas — la única forma honesta de medir un disco |
| `dsync` / `sync` | escrituras síncronas de datos / datos+metadatos por bloque |
| `fullblock` | **acumula bloques completos en la lectura** — obligatorio para tuberías, sockets, `/dev/urandom` |
| `nocache` | descarta la caché de páginas del archivo después |
| `count_bytes` / `skip_bytes` / `seek_bytes` | interpreta el operando correspondiente como bytes |
| `nonblock` / `noatime` | `O_NONBLOCK` / `O_NOATIME` |

**El bug de la lectura corta — el comportamiento más peligroso de `dd`:**

```
$ dd if=/dev/urandom bs=1M count=100 | dd of=out.bin bs=1M
0+3200 records in                  ← "0 full blocks in, 3200 PARTIAL"
0+3200 records out
104857600 bytes (105 MB, 100 MiB) copied, 0.9 s, 116 MB/s
```

Acá dio por casualidad la cantidad correcta de bytes, pero con `count=` del lado que lee, las lecturas cortas de una tubería truncan silenciosamente:

```
$ cat 100mb.bin | dd of=trunc.bin bs=1M count=100
7+93 records in
7+93 records out
21299200 bytes (21 MB, 20 MiB) copied, 0.03 s      ← 20 MiB, not 100 MiB. Silent data loss.

$ cat 100mb.bin | dd of=ok.bin bs=1M count=100 iflag=fullblock
100+0 records in
100+0 records out
104857600 bytes (105 MB, 100 MiB) copied, 0.21 s, 499 MB/s
```

**Regla: todo `dd` cuya entrada no sea un archivo regular o un dispositivo de bloque debe usar `iflag=fullblock`.**

**Usos reales:**

```
# 1. Back up the MBR (446 bytes of boot code + 64-byte partition table + 2-byte signature)
$ sudo dd if=/dev/sda of=/backup/sda-mbr.bin bs=512 count=1
1+0 records in
1+0 records out
512 bytes copied, 0.000452 s, 1.1 MB/s

# 2. Restore ONLY the boot code, leaving the partition table untouched
$ sudo dd if=/backup/sda-mbr.bin of=/dev/sda bs=446 count=1 conv=notrunc

# 3. Forensic image with error tolerance and preserved offsets
$ sudo dd if=/dev/sdb of=/evidence/sdb.img bs=64K conv=noerror,sync status=progress
  244140544 bytes (244 MB, 233 MiB) copied, 3 s, 81.4 MB/s
dd: error reading '/dev/sdb': Input/output error
3726+1 records in
3727+0 records out
   ⚠ For real forensics use ddrescue: it retries, logs bad sectors and resumes.

# 4. Read 4 KiB from a precise byte offset (superblock inspection)
$ sudo dd if=/dev/sda1 bs=1 skip=1024 count=4096 status=none | hexdump -C | head -3
00000000  00 00 20 00 00 00 80 00  33 33 06 00 6e c5 26 00  |.. .....33..n.&.|
00000010  b1 44 1a 00 00 00 00 00  02 00 00 00 02 00 00 00  |.D..............|
00000020  00 80 00 00 00 80 00 00  00 20 00 00 5d 2b ce 68  |......... ..]+.h|

# 5. Honest sequential write benchmark (O_DIRECT bypasses the page cache)
$ sudo dd if=/dev/zero of=/srv/testfile bs=1M count=4096 oflag=direct
4096+0 records in
4096+0 records out
4294967296 bytes (4.3 GB, 4.0 GiB) copied, 7.88214 s, 545 MB/s
$ sudo rm /srv/testfile
   ⚠ Without oflag=direct you are benchmarking RAM. Without conv=fsync you are
     benchmarking the page cache and the number will be absurdly high.

# 6. Create a sparse 100 GiB file instantly (fallocate is better, but dd works)
$ dd if=/dev/zero of=sparse.img bs=1 count=0 seek=100G
$ ls -lh sparse.img && du -h sparse.img
-rw-r--r-- 1 root root 100G Aug 26 10:30 sparse.img
0	sparse.img

# 7. Live progress on a long-running dd already in flight
$ sudo kill -USR1 $(pgrep -x dd)
  17179869184 bytes (17 GB, 16 GiB) copied, 62 s, 277 MB/s
```

**Lista de verificación de seguridad de `dd` antes de cualquier `of=/dev/...`:**

```
$ lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,MODEL /dev/sdb
NAME   SIZE TYPE MOUNTPOINTS MODEL
sdb   14.9G disk             Ultra_Fit
└─sdb1 14.9G part /media/usb

$ findmnt -n /dev/sdb1 && echo "MOUNTED — unmount before writing"
$ sudo umount /dev/sdb1
$ sudo dd if=image.iso of=/dev/sdb bs=4M conv=fsync oflag=direct status=progress
```

Escribí en el **disco** (`/dev/sdb`) para una ISO híbrida, y en la **partición** (`/dev/sdb1`) para una imagen de filesystem. Equivocarse ahí destruye la tabla de particiones.

---

## 11. Compresión

Todos estos son compresores de **flujo**. `tar` se encarga del empaquetado; el compresor se encarga de los bytes. Esa separación es la razón por la que `.tar.gz` tiene dos sufijos y por la que no podés hacer búsqueda aleatoria dentro de un miembro de un `.tar.gz` sin descomprimir todo lo anterior.

### 11.1 Comparación de algoritmos

Medido sobre un `tar` de 1.0 GiB de un rootfs Debian, x86-64 de 8 núcleos. Tus números diferirán; las *proporciones* se mantienen.

| Herramienta | Algoritmo | Nivel | Salida | Comprimir | Descomprimir | RAM al descomprimir | Paralelo |
|---|---|---|---|---|---|---|---|
| `lz4` | LZ77 | `-1` | 447 MiB | 3 s | 1.1 s | ~1 MiB | `-T0` (mt) |
| `gzip` | DEFLATE (LZ77+Huffman, ventana de 32 KiB) | `-6` | 331 MiB | 24 s | 3.1 s | ~1 MiB | `pigz` |
| `zstd` | LZ77+FSE/Huffman | `-3` | 318 MiB | 6 s | 2.4 s | ~8 MiB | **`-T0` nativo** |
| `bzip2` | BWT + MTF + Huffman | `-9` | 289 MiB | 96 s | 32 s | ~8 MiB | `pbzip2` |
| `zstd` | " | `-19` | 246 MiB | 178 s | 2.6 s | ~9 MiB | `-T0` |
| `xz` | LZMA2 | `-6` (por defecto) | 231 MiB | 214 s | 12 s | **9 MiB** | `-T0` |
| `xz` | LZMA2 | `-9` | 224 MiB | 302 s | 14 s | **65 MiB** | `-T0` |

**La regla de decisión:**

- **Escribir una vez, leer muchas, distribución limitada por ancho de banda** (tarballs del kernel, paquetes de distribución) → `xz -9`. Lento de crear, pequeño, barato de leer.
- **Backups que esperás no tener que leer nunca pero que deberás leer *rápido* bajo presión** → `zstd -19`. Casi la proporción de `xz`, descompresión de clase `gzip`, 60× más rápido que `xz` para restaurar en agregado.
- **Interactivo / pipeline / rotación de logs** → `zstd -3` o `gzip -6`.
- **Tiempo real en el camino crítico** (flujo de red, volcado temporal) → `lz4`.
- **`bzip2`** → solo por compatibilidad con artefactos `.bz2` existentes. Está dominado en todos los ejes por `zstd` y `xz`.
- **La descompresión de `xz -9` necesita 65 MiB de RAM.** Eso es descalificante dentro de un initramfs con memoria limitada o un contenedor de 128 MiB. `xz --info-memory` te lo dice antes de que te comprometas.

```
$ xz --info-memory
Total amount of physical memory (RAM): 32768 MiB
Number of processor threads: 16
Memory usage limit for compression:    Disabled
Memory usage limit for decompression:  Disabled

$ xz -l firmware.tar.xz
Strms  Blocks   Compressed Uncompressed  Ratio  Check   Filename
    1       1    224.1 MiB   1024.0 MiB  0.219  CRC64   firmware.tar.xz
```

### 11.2 Interfaz común

Los cuatro comparten la misma UX central, que es lo que evalúa el examen:

| Comportamiento | `gzip` | `bzip2` | `xz` | `zstd` |
|---|---|---|---|---|
| Comprimir, **reemplazar** el original | `gzip f` | `bzip2 f` | `xz f` | `zstd --rm f` |
| Conservar el original | `gzip -k f` | `bzip2 -k f` | `xz -k f` | `zstd f` (conserva por defecto) |
| Descomprimir | `gunzip f.gz` / `gzip -d` | `bunzip2` / `bzip2 -d` | `unxz` / `xz -d` | `unzstd` / `zstd -d` |
| Volcar a stdout | `zcat` / `gzip -c` | `bzcat` / `bzip2 -c` | `xzcat` / `xz -c` | `zstdcat` |
| Probar integridad | `gzip -t` | `bzip2 -t` | `xz -t` | `zstd -t` |
| Mostrar proporción | `gzip -l` | *(ninguno)* | `xz -l` | `zstd -l` |
| Niveles | `-1`…`-9` | `-1`…`-9` (tamaño de bloque) | `-0`…`-9`, `-e` | `-1`…`-19`, `--ultra -22` |
| Grep dentro | `zgrep` | `bzgrep` | `xzgrep` | `zstdgrep` |
| Hilos | `pigz -p N` | `pbzip2 -p N` | `xz -T0` | `zstd -T0` |

> **El comportamiento por defecto es destructivo.** `gzip file` te deja con `file.gz` y sin `file`. `-k`/`--keep` es una memoria muscular que vale la pena construir.

```
$ ls -l app.log
-rw-r----- 1 svc svc 104857600 Aug 26 09:00 app.log
$ gzip -k -9 app.log
$ ls -l app.log*
-rw-r----- 1 svc svc 104857600 Aug 26 09:00 app.log
-rw-r----- 1 svc svc   4194304 Aug 26 09:00 app.log.gz     ← mtime is PRESERVED

$ gzip -l app.log.gz
         compressed        uncompressed  ratio uncompressed_name
            4194304           104857600  96.0% app.log

$ zcat app.log.gz | grep -c ERROR
1842
$ zgrep -c ERROR app.log.gz            # same thing, one process
1842
```

**`gzip -n` y la reproducibilidad.** La cabecera de gzip incrusta el nombre de archivo original y el mtime. Dos entradas idénticas byte a byte comprimidas con un segundo de diferencia producen archivos `.gz` distintos. `-n`/`--no-name` elimina ambos — requisito para cualquier artefacto firmado o indexado por caché.

```
$ gzip -c  data > a.gz; sleep 2; gzip -c  data > b.gz; cmp a.gz b.gz
a.gz b.gz differ: byte 5, line 1
$ gzip -nc data > a.gz; sleep 2; gzip -nc data > b.gz; cmp a.gz b.gz && echo identical
identical
```

**Comprimir un archivo ya comprimido lo agranda:**

```
$ ls -l image.jpg && gzip -9 -c image.jpg | wc -c
-rw-r--r-- 1 svc svc 2418176 Aug 26 09:00 image.jpg
2419331                                    ← +1155 bytes of overhead
```

**Semántica de concatenación** (una propiedad real en la que podés confiar): los flujos de `gzip`, `bzip2`, `xz` y `zstd` se concatenan. `cat a.gz b.gz > c.gz` se descomprime como `a` seguido de `b`.

**Recuperar un archivo dañado:**

```
$ bzip2 -t corrupt.tar.bz2
bzip2: corrupt.tar.bz2: data integrity (CRC) error in data

$ bzip2recover corrupt.tar.bz2      # splits into per-block files; salvage what survives
bzip2recover: splitting into blocks
   block 1 runs from 80 to 8394239
   block 2 runs from 8394240 to 16789119
...
$ bzip2 -dc rec0000*.bz2 > salvaged.tar
```

`gzip` no tiene equivalente — un flujo DEFLATE corrupto es irrecuperable más allá del daño. Eso solo ya es un argumento a favor de `zstd` (checksums por frame) o de `xz --check=sha256` en archivos de larga vida, y a favor de dividir los backups grandes en trozos verificables de forma independiente.

---

## 12. Infraestructura de producción

### 12.1 CronJob de Kubernetes: backup de PVC con `tar`, verificado

Cada flag de abajo es deliberado: `--numeric-owner` porque el host de restauración tiene otro `/etc/passwd`; `--one-file-system` para que no se arrastre un montaje de sidecar; verificación con `-t` porque un backup no verificado no es un backup; retención basada en `-mtime` con `-delete` para no hacer 10.000 forks dentro de un contenedor de 100m de CPU.

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: pvc-backup-script
  namespace: platform
data:
  backup.sh: |
    #!/usr/bin/env bash
    set -euo pipefail

    readonly SRC=/data
    readonly DST=/backup
    readonly STAMP="${BACKUP_STAMP:?injected by the CronJob}"
    readonly ARCHIVE="${DST}/app-${STAMP}.tar.zst"
    readonly RETENTION_DAYS="${RETENTION_DAYS:-14}"

    echo "==> source inventory"
    find "${SRC}" -xdev -type f -printf '%s\n' \
      | awk '{n++; b+=$1} END {printf "files=%d bytes=%d\n", n, b}'

    echo "==> creating ${ARCHIVE}"
    tar --create \
        --file="${ARCHIVE}.part" \
        --use-compress-program='zstd -12 -T0' \
        --format=pax \
        --sort=name \
        --one-file-system \
        --numeric-owner \
        --acls --xattrs --selinux \
        --sparse \
        --exclude='./lost+found' \
        --exclude='./*.tmp' \
        --warning=no-file-changed \
        --directory="${SRC}" .

    echo "==> verifying archive is readable end to end"
    tar --list --file="${ARCHIVE}.part" --use-compress-program='zstd -d -T0' >/dev/null

    echo "==> publishing atomically (same filesystem => rename(2))"
    mv --force -- "${ARCHIVE}.part" "${ARCHIVE}"
    sync -f "${ARCHIVE}"

    echo "==> checksum"
    ( cd "${DST}" && sha256sum "$(basename "${ARCHIVE}")" \
        > "$(basename "${ARCHIVE}").sha256" )

    echo "==> pruning archives older than ${RETENTION_DAYS} days"
    find "${DST}" -xdev -maxdepth 1 -type f \
         \( -name 'app-*.tar.zst' -o -name 'app-*.tar.zst.sha256' \) \
         ! -newermt "-${RETENTION_DAYS} days" \
         -printf 'pruning %10s bytes  %p\n' \
         -delete

    echo "==> orphaned .part files from crashed runs"
    find "${DST}" -xdev -maxdepth 1 -type f -name '*.part' -mmin +720 \
         -printf 'stale partial: %p\n' -delete

    echo "==> destination free space"
    df -h --output=source,size,used,avail,pcent "${DST}"
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: app-pvc-backup
  namespace: platform
spec:
  schedule: "17 2 * * *"
  timeZone: "Etc/UTC"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  startingDeadlineSeconds: 3600
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 10800
      template:
        metadata:
          labels:
            app.kubernetes.io/name: app-pvc-backup
            app.kubernetes.io/component: backup
        spec:
          restartPolicy: Never
          automountServiceAccountToken: false
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            runAsGroup: 1000
            fsGroup: 1000
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: tar
              image: debian:12-slim
              imagePullPolicy: IfNotPresent
              command: ["/bin/bash", "/scripts/backup.sh"]
              env:
                - name: RETENTION_DAYS
                  value: "14"
                - name: BACKUP_STAMP
                  valueFrom:
                    fieldRef:
                      fieldPath: metadata.name
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              resources:
                requests:
                  cpu: "500m"
                  memory: "256Mi"
                limits:
                  cpu: "2"
                  memory: "1Gi"
              volumeMounts:
                - name: data
                  mountPath: /data
                  readOnly: true
                - name: backup
                  mountPath: /backup
                - name: scripts
                  mountPath: /scripts
                  readOnly: true
                - name: tmp
                  mountPath: /tmp
          volumes:
            - name: data
              persistentVolumeClaim:
                claimName: app-data
                readOnly: true
            - name: backup
              persistentVolumeClaim:
                claimName: backup-target
            - name: scripts
              configMap:
                name: pvc-backup-script
                defaultMode: 0555
            - name: tmp
              emptyDir:
                sizeLimit: 128Mi
```

`--warning=no-file-changed` merece una nota: `tar` sale con **1** si un archivo cambia de tamaño mientras se lo lee, lo cual en un PVC vivo es rutinario y haría fallar el Job todas las noches. Suprimir la advertencia no hace que el backup sea consistente — para eso necesitás un snapshot de volumen. Este es el compromiso honesto: usá un `VolumeSnapshot` como PVC de origen si tu driver CSI lo soporta, y tratá este manifiesto como el plan alternativo.

### 12.2 Init container: extracción verificada de artefactos

El patrón acá es: descargar → **checksum antes de extraer** → inspeccionar en busca de path traversal → extraer con `--strip-components` → entregar a través de un `emptyDir`.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
  namespace: platform
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: app
  template:
    metadata:
      labels:
        app.kubernetes.io/name: app
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      initContainers:
        - name: fetch-and-verify
          image: debian:12-slim
          command:
            - /bin/bash
            - -euo
            - pipefail
            - -c
            - |
              cd /work
              curl -fsSL --retry 5 --retry-delay 2 \
                   -o app.tar.gz "${ARTIFACT_URL}"

              echo "${ARTIFACT_SHA256}  app.tar.gz" | sha256sum -c -

              # Refuse absolute paths and any ".." component before extracting.
              if tar -tzf app.tar.gz | grep -Eq '^/|(^|/)\.\.(/|$)'; then
                echo "FATAL: archive contains unsafe member paths" >&2
                tar -tzf app.tar.gz | grep -E '^/|(^|/)\.\.(/|$)' >&2
                exit 1
              fi

              tar --extract --gzip \
                  --file=app.tar.gz \
                  --directory=/app \
                  --strip-components=1 \
                  --no-same-owner \
                  --no-overwrite-dir

              rm -f app.tar.gz
              find /app -maxdepth 2 -printf '%M %8s %P\n' | head -40
          env:
            - name: ARTIFACT_URL
              value: "https://artifacts.internal/app/2.4.1/app-2.4.1.tar.gz"
            - name: ARTIFACT_SHA256
              valueFrom:
                secretKeyRef:
                  name: app-artifact-digest
                  key: sha256
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests: { cpu: "100m", memory: "128Mi" }
            limits:   { cpu: "1",    memory: "512Mi" }
          volumeMounts:
            - { name: app, mountPath: /app }
            - { name: work, mountPath: /work }
      containers:
        - name: app
          image: gcr.io/distroless/java21-debian12
          args: ["-jar", "/app/app.jar"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests: { cpu: "500m", memory: "512Mi" }
            limits:   { cpu: "2",    memory: "2Gi" }
          volumeMounts:
            - { name: app, mountPath: /app, readOnly: true }
      volumes:
        - name: app
          emptyDir: { sizeLimit: 2Gi }
        - name: work
          emptyDir: { sizeLimit: 2Gi }
```

### 12.3 A nivel de nodo: timer de `systemd` + `tmpfiles.d` para higiene de disco

Dos mecanismos, dos trabajos. `tmpfiles.d` es declarativo y cubre el caso común basado en antigüedad; el timer cubre cualquier cosa con lógica real.

```ini
# /etc/tmpfiles.d/app-cleanup.conf
#Type Path                        Mode UID   GID   Age  Argument
d     /var/cache/app              0750 svc   svc   7d   -
d     /var/lib/app/spool          0750 svc   svc   -    -
e     /var/lib/app/spool/incoming 0750 svc   svc   30d  -
D     /run/app                    0755 svc   svc   -    -
```

`d` = crear si no existe y luego limpiar entradas más antiguas que Age. `e` = limpiar solo si ya existe (nunca crear). `D` = crear y **purgar en el arranque**. Aplicar y probar en seco:

```
$ sudo systemd-tmpfiles --clean --dry-run /etc/tmpfiles.d/app-cleanup.conf
$ sudo systemd-tmpfiles --create --clean /etc/tmpfiles.d/app-cleanup.conf
```

```ini
# /etc/systemd/system/disk-hygiene.service
[Unit]
Description=Prune aged artefacts and report filesystem pressure
Documentation=man:find(1) man:tmpfiles.d(5)
ConditionPathIsMountPoint=/var

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
CPUQuota=25%
ExecStart=/usr/local/sbin/disk-hygiene
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
NoNewPrivileges=true
ReadWritePaths=/var/cache /var/log /var/tmp
```

```ini
# /etc/systemd/system/disk-hygiene.timer
[Unit]
Description=Nightly disk hygiene

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=1800
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
```

```bash
#!/usr/bin/env bash
# /usr/local/sbin/disk-hygiene  (0755, root:root)
set -euo pipefail
shopt -s nullglob

log() { printf '%s %s\n' "$(date -Is)" "$*"; }

# 1. Rotated logs older than 14 days, bounded to the /var filesystem.
log "pruning rotated logs"
find /var/log -xdev -type f \
     \( -name '*.gz' -o -name '*.xz' -o -name '*.[0-9]' -o -name '*.old' \) \
     ! -newermt '-14 days' \
     -printf 'prune %10s %p\n' -delete

# 2. Empty directories left behind, deepest first.
find /var/log -xdev -mindepth 1 -type d -empty -delete

# 3. Compress yesterday's uncompressed logs. -mtime +0 == older than 24h.
log "compressing"
find /var/log -xdev -type f -name '*.log.1' -mtime +0 -print0 \
  | xargs -0 -r -P 4 -n 16 zstd -19 --rm --quiet

# 4. Space held open by deleted files — report only; never kill blindly.
log "checking for unlinked-but-open files"
if command -v lsof >/dev/null; then
    lsof -nP +L1 2>/dev/null \
      | awk 'NR==1 || $8 > 1073741824 {print}' || true
fi

# 5. Report inode and block pressure on every local filesystem.
log "filesystem pressure"
df  -hl --output=target,size,used,avail,pcent -x tmpfs -x devtmpfs
df  -il --output=target,itotal,iused,iavail,ipcent -x tmpfs -x devtmpfs
```

```
$ sudo systemctl enable --now disk-hygiene.timer
Created symlink /etc/systemd/system/timers.target.wants/disk-hygiene.timer → /etc/systemd/system/disk-hygiene.timer.
$ systemctl list-timers disk-hygiene.timer
NEXT                        LEFT       LAST PASSED UNIT               ACTIVATES
Thu 2026-08-27 03:47:12 UTC 17h left   n/a  n/a    disk-hygiene.timer disk-hygiene.service
```

### 12.4 Capa de contenedor reproducible

```dockerfile
# syntax=docker/dockerfile:1.7
FROM debian:12-slim AS build
ARG SOURCE_DATE_EPOCH
WORKDIR /src
COPY . .
RUN set -eux; \
    make build; \
    install -D -m 0755 -o root -g root out/app /rootfs/usr/local/bin/app; \
    install -D -m 0644 -o root -g root conf/app.yaml /rootfs/etc/app/app.yaml; \
    # Deterministic layer: fixed order, fixed times, fixed ownership.
    tar --create \
        --file=/rootfs.tar \
        --format=pax \
        --sort=name \
        --mtime="@${SOURCE_DATE_EPOCH}" \
        --owner=0 --group=0 --numeric-owner \
        --pax-option='exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime' \
        -C /rootfs .

FROM gcr.io/distroless/base-debian12
COPY --from=build /rootfs.tar /tmp/rootfs.tar
# (In a real pipeline the tar is fed to buildkit as a layer, not extracted here.)
ENTRYPOINT ["/usr/local/bin/app"]
```

`install -D -m -o -g` en una sola llamada reemplaza a `mkdir -p && cp && chmod && chown` — menos estados, sin una ventana en la que el archivo exista con el modo equivocado.

---

## 13. Verificación y diagnóstico de fallos

### 13.1 La escalera diagnóstica para "el disco está lleno"

```
                    df reports 100%
                          │
        ┌─────────────────┼──────────────────┐
        ▼                 ▼                  ▼
   df -i shows       du ≈ df?            du ≪ df?
   IUse% = 100%       │                     │
        │             ▼                     ▼
   INODE              genuinely       unlinked-but-open files
   EXHAUSTION         full              OR a mount shadowed
        │                                by another mount
        ▼                                    │
  find / -xdev -type f | wc -l          lsof +L1  /  mount --bind
  find / -xdev -printf '%h\n' | sort | uniq -c | sort -rn | head
```

```
# Case A — inode exhaustion. Blocks are free, inodes are not.
$ df -h /var  && df -i /var
Filesystem            Size  Used Avail Use% Mounted on
/dev/mapper/vg0-var    50G   11G   37G  23% /var
Filesystem            Inodes  IUsed IFree IUse% Mounted on
/dev/mapper/vg0-var  3276800 3276800     0  100% /var

$ sudo find /var -xdev -printf '%h\n' | sort | uniq -c | sort -rn | head -3
2981442 /var/spool/postfix/maildrop
  41118 /var/lib/app/sessions
   9033 /var/cache/nginx
# ext4 inode counts are fixed at mkfs time and CANNOT be grown. XFS allocates
# dynamically. This is an mkfs-time architectural decision, discovered at 3am.

# Case B — shadowed mount. Data was written to the mountpoint BEFORE mounting.
$ df -h /srv/data
Filesystem            Size  Used Avail Use% Mounted on
/dev/mapper/vg0-data  500G   12G  488G   3% /srv/data
$ df -h /            # but / is full
$ sudo mkdir /mnt/root-view && sudo mount --bind / /mnt/root-view
$ sudo du -sh /mnt/root-view/srv/data
340G	/mnt/root-view/srv/data     ← 340 GiB hidden UNDER the mount
$ sudo umount /mnt/root-view
```

### 13.2 Error → causa → solución

| Mensaje | Capa | Causa | Solución |
|---|---|---|---|
| `Argument list too long` (E2BIG) | `execve` del kernel | el glob excedió `ARG_MAX` o el entorno es enorme | `find … -delete` / `-exec … +` / `xargs -0` |
| `Invalid cross-device link` (EXDEV) | `rename(2)` | origen y destino en filesystems distintos | esperable — `mv` cae a copia; usá `cp -a && rm` explícitamente si necesitás controlarlo |
| `Directory not empty` (ENOTEMPTY) | `rmdir(2)` | queda contenido, posiblemente dotfiles ocultos | `ls -A dir`; `rm -r` si es lo buscado |
| `Device or resource busy` (EBUSY) | `unlink`/`umount` | un proceso tiene ahí su cwd o mantiene un montaje | `lsof +D /path` / `fuser -vm /path` |
| `Text file busy` (ETXTBSY) | `open` para escritura | estás escribiendo un ejecutable en ejecución | reemplazalo vía `mv` (rename), no con `cp` |
| `Operation not permitted` en `chown` durante la extracción | `tar -x` | un no-root no puede cambiar la propiedad | `--no-same-owner` (por defecto para no-root) |
| `tar: Removing leading '/' from member names` | GNU tar | recorte de seguridad, informativo | usá `-C` y rutas relativas |
| `tar: ...: file changed as we read it` (salida 1) | GNU tar | un archivo vivo mutó durante la lectura | hacé un snapshot del volumen, o `--warning=no-file-changed` y aceptá la inconsistencia |
| `tar: Unexpected EOF in archive` | GNU tar | transferencia truncada, o un `.gz` canalizado sin `-z` | verificá el checksum; pasale `file` al archivo |
| `cpio: premature end of archive` | cpio | flujo truncado, o formato `-H` equivocado | pasale `file`; revisá el código de salida del escritor |
| `cpio: Malformed number` | cpio | desajuste de formato (`bin` leído como `newc`) | `-H` debe coincidir con el del escritor |
| `dd: failed to open '/dev/sdb': Permission denied` | kernel | no sos root, o el dispositivo está tomado en exclusiva | `sudo`; revisá `lsblk`/`findmnt` en busca de quién lo retiene |
| `dd` `N+M records in` con M ≫ 0 | `read(2)` | lecturas cortas desde una tubería | `iflag=fullblock` |
| `gzip: stdin: not in gzip format` | gzip | el archivo no es gzip (a menudo `xz` o tar plano) | pasale `file`, usá el flag correcto |
| `bzip2: data integrity (CRC) error` | bzip2 | corrupción | `bzip2recover`; volvé a descargarlo |
| `xz: Cannot allocate memory` | xz | el diccionario de descompresión excede el límite del cgroup | recomprimí con un preset menor; subí el límite de memoria |
| `No space left on device` con `df` mostrando espacio libre | VFS | agotamiento de inodos, o un archivo desenlazado pero abierto, o un `/tmp` lleno en otro montaje | `df -i`; `lsof +L1` |
| `find: warning: you have specified the -maxdepth option after a non-option argument` | findutils | orden | poné `-maxdepth` primero |
| `rm: cannot remove 'x': Read-only file system` | VFS | el filesystem se remontó `ro` tras un error | `dmesg -T \| grep -i 'remount\|I/O error'` — el disco se está muriendo |

### 13.3 Lista de verificación post-operación

```bash
# --- After any bulk copy: compare counts, bytes, and content ---
$ find /source -xdev -type f | wc -l ; find /dest -xdev -type f | wc -l
412337
412337

$ du -sb --one-file-system /source /dest
193491230720	/source
193491230720	/dest

# Content-level, order-independent, NUL-safe:
$ ( cd /source && find . -xdev -type f -print0 | LC_ALL=C sort -z \
      | xargs -0 sha256sum ) > /tmp/src.sums
$ ( cd /dest   && find . -xdev -type f -print0 | LC_ALL=C sort -z \
      | xargs -0 sha256sum ) > /tmp/dst.sums
$ diff /tmp/src.sums /tmp/dst.sums && echo "IDENTICAL"
IDENTICAL

# Metadata-level (modes, owners, times) — checksums do not cover these:
$ ( cd /source && find . -printf '%M %U %G %s %T@ %P\n' | LC_ALL=C sort ) > /tmp/src.meta
$ ( cd /dest   && find . -printf '%M %U %G %s %T@ %P\n' | LC_ALL=C sort ) > /tmp/dst.meta
$ diff /tmp/src.meta /tmp/dst.meta

# --- After any archive creation: prove it is readable and complete ---
$ tar -tzf backup.tgz >/dev/null && echo "archive traversable"
$ tar -tzf backup.tgz | wc -l
412340
$ tar -df backup.tgz -C /source && echo "archive matches live tree"

# --- After any dd to a device: verify the bytes actually landed ---
$ sudo dd if=image.iso of=/dev/sdb bs=4M conv=fsync status=progress
$ sync
$ sudo blockdev --flushbufs /dev/sdb        # drop the block-device cache
$ SIZE=$(stat -c %s image.iso)
$ sha256sum image.iso
9f2c...  image.iso
$ sudo dd if=/dev/sdb bs=4M count=$SIZE iflag=count_bytes status=none | sha256sum
9f2c...  -
# Reading back the whole device would include trailing garbage — hence count_bytes.

# --- Detect hard links you are about to break ---
$ find /source -xdev -type f -links +1 -printf '%i %n %p\n' | sort -n | head
262149 2 /source/data/shard-00.db
262149 2 /source/archive/shard-00.db

# --- Detect sparse files you are about to inflate ---
$ find /source -xdev -type f -printf '%s %b %p\n' \
    | awk '$1 > $2*512*1.5 {printf "SPARSE %s (apparent %d, allocated %d)\n", $3, $1, $2*512}'
SPARSE /source/vm/disk.img (apparent 107374182400, allocated 8589934592)
$ filefrag -v /source/vm/disk.img | head -5
Filesystem type is: ef53
File size of /source/vm/disk.img is 107374182400 (26214400 blocks of 4096 bytes)
 ext:     logical_offset:        physical_offset: length:   expected: flags:
   0:        0..   32767:   1179648..  1212415:  32768:
   1:   262144..  294911:   1212416..  1245183:  32768:    1212416:
```

### 13.4 La trampa del estado de salida en tuberías

```
$ tar -czf backup.tgz /srv | tee build.log
$ echo $?
0                        # ← this is TEE's exit status, not tar's

$ set -o pipefail
$ tar -czf backup.tgz /srv | tee build.log
$ echo $?
2                        # ← now the failure is visible

$ tar -czf backup.tgz /srv | tee build.log ; echo "${PIPESTATUS[@]}"
2 0                      # bash-specific, per-element statuses
```

Un script de backup que canaliza a través de `tee`, `gzip`, `logger` o `ssh` sin `set -o pipefail` reporta éxito ante todos los modos de fallo que existen. Así es como las organizaciones descubren, durante una restauración, que tienen tres años de tarballs vacíos.

---

## 14. Referencia de comandos para el examen

```
ls    -l -a -A -d -i -h -R -S -t -r -1 -F -U -f --color=never --time-style=

cp    -a -r/-R -p --preserve=all -d -L -P -u -n -i -f -v -l -s -x -t -T
      --reflink={auto,always,never}  --sparse={auto,always,never}  -b --backup=

mv    -f -i -n -u -v -b --backup= -t -T --strip-trailing-slashes

rm    -r/-R -f -i -I -d -v --one-file-system --preserve-root(default) --

rmdir -p -v --ignore-fail-on-non-empty

mkdir -p -m MODE -v -Z

touch -a -m -c -d STRING -t [[CC]YY]MMDDhhmm[.ss] -r REF -h

find  PATH [-P|-L|-H] -maxdepth -mindepth -depth -xdev -prune
      -name -iname -path -regex -type f,d,l,b,c,p,s
      -size N[cwbkMG] -empty -perm [-|/]MODE -links -inum
      -user -group -nouser -nogroup
      -mtime -atime -ctime -mmin -amin -cmin -newer -newerXY
      -print -print0 -printf FMT -delete -quit -ls
      -exec CMD {} \;   -exec CMD {} +   -execdir   -ok
      \( \) ! -a -o

tar   -c -x -t -r -u -A -d --delete
      -f -v -C -p --same-owner --numeric-owner
      -z -j -J --zstd -a -I 'PROG'
      --exclude= --exclude-from= -T/--files-from --null
      --strip-components=N --one-file-system --sparse
      --xattrs --acls --selinux --format={gnu,ustar,pax}
      --listed-incremental=SNAR --wildcards -P/--absolute-names

cpio  -o/--create  -i/--extract  -p/--pass-through
      -H {bin,odc,newc,crc,tar,ustar}
      -d -m -v -t -u -F FILE -0/--null --no-absolute-filenames

dd    if= of= bs= ibs= obs= count= skip= seek= status={none,noxfer,progress}
      conv=notrunc,noerror,sync,sparse,fsync,fdatasync,excl,nocreat,swab
      iflag=/oflag=direct,dsync,sync,fullblock,nocache,count_bytes,skip_bytes,seek_bytes

gzip  -k -d -c -1..-9 -t -l -n -r -v      | gunzip | zcat | zgrep | zless
bzip2 -k -d -c -1..-9 -t -v               | bunzip2 | bzcat | bzgrep | bzip2recover
xz    -k -d -c -0..-9 -e -t -l -T0        | unxz | xzcat | xzgrep | --info-memory
zstd  --rm -d -c -1..-19 --ultra -22 -T0  | unzstd | zstdcat | zstdgrep

file  -b -i --mime-type -s -z -L -f LIST -F SEP

globbing  *  ?  [abc]  [!abc]  [a-z]  [[:class:]]
bash      shopt -s extglob globstar nullglob failglob dotglob nocaseglob
          ?(p) *(p) +(p) @(p) !(p)   **   {a,b}  {1..10..2}
```

**Diez hechos que deciden preguntas del examen:**

1. `*` nunca coincide con un `.` inicial; `.*` coincide con `.` y `..`.
2. El globbing lo hace el **shell**, antes de que el comando se ejecute.
3. `rm` llama a `unlink(2)` — el espacio se libera solo cuando el contador de enlaces **y** el de fds abiertos son ambos cero.
4. `mv` dentro de un filesystem es un `rename(2)` atómico; entre filesystems es copia + borrado.
5. `find -mtime +1` significa **más de 48 horas**, no 24.
6. `find -size -1M` coincide únicamente con archivos **vacíos** (los tamaños se redondean hacia arriba).
7. `-exec {} \;` hace un fork por archivo; `-exec {} +` agrupa por lotes.
8. `tar -C` es **posicional** — se aplica a los operandos que le siguen.
9. `cpio` lee su lista de archivos desde **stdin** y necesita `-H newc` para initramfs.
10. `dd` sobre una tubería requiere `iflag=fullblock` o trunca silenciosamente.

---

## Referencias

**Objetivos de certificación**
- LPI Exam 101-500 Objectives (v5.0), Topic 103.3 — https://www.lpi.org/our-certifications/exam-101-objectives/
- LPIC-1 Certification Overview — https://www.lpi.org/our-certifications/lpic-1-overview/

**Estándares**
- IEEE Std 1003.1-2024 (POSIX.1), Shell & Utilities — https://pubs.opengroup.org/onlinepubs/9799919799/
- POSIX pathname expansion — https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_14
- POSIX `pax` format (`ustar` / extended headers) — https://pubs.opengroup.org/onlinepubs/9799919799/utilities/pax.html
- Filesystem Hierarchy Standard 3.0 — https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html

**Manuales de herramientas GNU**
- GNU Coreutils Manual (`ls`, `cp`, `mv`, `rm`, `rmdir`, `mkdir`, `touch`, `dd`, `install`, `truncate`, `sync`) — https://www.gnu.org/software/coreutils/manual/coreutils.html
- `dd` invocation — https://www.gnu.org/software/coreutils/manual/html_node/dd-invocation.html
- GNU Findutils Manual (`find`, `xargs`, `locate`) — https://www.gnu.org/software/findutils/manual/html_mono/find.html
- GNU Tar Manual — https://www.gnu.org/software/tar/manual/tar.html
- GNU Tar: incremental dumps — https://www.gnu.org/software/tar/manual/html_node/Incremental-Dumps.html
- GNU cpio Manual — https://www.gnu.org/software/cpio/manual/cpio.html
- GNU Gzip Manual — https://www.gnu.org/software/gzip/manual/gzip.html
- GNU Bash Reference Manual — Filename Expansion — https://www.gnu.org/software/bash/manual/html_node/Filename-Expansion.html
- GNU Bash Reference Manual — Brace Expansion — https://www.gnu.org/software/bash/manual/html_node/Brace-Expansion.html
- GNU Bash Reference Manual — `shopt` — https://www.gnu.org/software/bash/manual/html_node/The-Shopt-Builtin.html

**Documentación del kernel y de llamadas al sistema**
- `man7.org` — `unlink(2)` — https://man7.org/linux/man-pages/man2/unlink.2.html
- `man7.org` — `rename(2)` / `renameat2(2)` — https://man7.org/linux/man-pages/man2/rename.2.html
- `man7.org` — `copy_file_range(2)` — https://man7.org/linux/man-pages/man2/copy_file_range.2.html
- `man7.org` — `statx(2)` — https://man7.org/linux/man-pages/man2/statx.2.html
- `man7.org` — `utimensat(2)` — https://man7.org/linux/man-pages/man2/utimensat.2.html
- `man7.org` — `execve(2)` (`ARG_MAX`, `MAX_ARG_STRLEN`, `E2BIG`) — https://man7.org/linux/man-pages/man2/execve.2.html
- `man7.org` — `inode(7)` — https://man7.org/linux/man-pages/man7/inode.7.html
- `man7.org` — `glob(7)` — https://man7.org/linux/man-pages/man7/glob.7.html
- Linux kernel: initramfs buffer format (`newc`) — https://www.kernel.org/doc/html/latest/driver-api/early-userspace/buffer-format.html
- Linux kernel: filesystem mount options (`relatime`, `noatime`, `lazytime`) — https://www.kernel.org/doc/html/latest/filesystems/proc.html

**Compresión**
- XZ Utils — https://tukaani.org/xz/
- Zstandard manual — https://facebook.github.io/zstd/zstd_manual.html
- bzip2 documentation — https://sourceware.org/bzip2/manual/manual.html
- RFC 1952 — GZIP file format specification — https://www.rfc-editor.org/rfc/rfc1952
- RFC 1951 — DEFLATE compressed data format — https://www.rfc-editor.org/rfc/rfc1951

**Systemd y orquestación**
- `systemd-tmpfiles` / `tmpfiles.d(5)` — https://www.freedesktop.org/software/systemd/man/latest/tmpfiles.d.html
- `systemd.timer(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html
- Kubernetes — CronJob — https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
- Kubernetes — Init Containers — https://kubernetes.io/docs/concepts/workloads/pods/init-containers/
- Kubernetes — Volume Snapshots — https://kubernetes.io/docs/concepts/storage/volume-snapshots/

**Reproducibilidad y seguridad**
- Reproducible Builds — `SOURCE_DATE_EPOCH` — https://reproducible-builds.org/docs/source-date-epoch/
- Reproducible Builds — Archive metadata — https://reproducible-builds.org/docs/archives/
- CWE-22: Improper Limitation of a Pathname to a Restricted Directory (path traversal in archives) — https://cwe.mitre.org/data/definitions/22.html