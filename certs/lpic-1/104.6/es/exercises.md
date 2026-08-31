# LPIC-1 · 104.6 — Crear y modificar enlaces duros y simbólicos

**Examen:** 101-500 · **Peso del objetivo:** 3.12
**Ejercicios guiados.** Cada paso está pensado para ser ejecutado. Las respuestas están al final, en una sección plegable — escribí tu propia respuesta antes de abrirla.

---

## Antes de empezar

Necesitás una cuenta de usuario normal, un directorio home con permiso de escritura, GNU coreutils (cualquier distribución moderna) y `sudo` solamente para los Ejercicios 6 y 10. Nada de lo que sigue toca archivos del sistema de forma destructiva; la última sección limpia todo.

```bash
$ mkdir -p ~/lab-104.6 && cd ~/lab-104.6
$ pwd
/home/student/lab-104.6
```

Dos hechos enmarcan todo lo que viene después:

- Un **archivo** en un sistema de archivos POSIX es un **inodo**: metadatos (modo, propietario, timestamps, tamaño, contador de enlaces) más punteros a bloques de datos. El inodo **no tiene nombre**.
- Un **nombre** es una entrada de directorio: un par `(nombre → número de inodo)` almacenado *en un directorio*. "Borrar un archivo" es `unlink(2)` — eliminar un nombre. El inodo muere cuando su contador de enlaces llega a cero **y** ningún proceso lo mantiene abierto.

Todo lo referente a enlaces duros y simbólicos se desprende de esas dos oraciones.

---

## Ejercicio 1 — Inodos, nombres y contadores de enlaces

1. Creá un archivo de carga y miralo con el número de inodo visible:

```bash
$ printf 'release: 1.0\nchecksum: 8f14e45f\n' > payload.txt
$ ls -li
total 4
1442653 -rw-r--r-- 1 student student 32 Aug 26 09:14 payload.txt
```

2. Leé los metadatos completos del inodo:

```bash
$ stat payload.txt
  File: payload.txt
  Size: 32              Blocks: 8          IO Block: 4096   regular file
Device: fd00h/64768d    Inode: 1442653     Links: 1
Access: (0644/-rw-r--r--)  Uid: ( 1000/ student)   Gid: ( 1000/ student)
Access: 2026-08-26 09:14:02.118374915 -0300
Modify: 2026-08-26 09:14:02.118374915 -0300
Change: 2026-08-26 09:14:02.118374915 -0300
 Birth: 2026-08-26 09:14:02.118374915 -0300
```

3. Imprimí solo los campos que vas a seguir revisando durante este laboratorio:

```bash
$ stat -c '%i %h %s %n' payload.txt
1442653 1 32 payload.txt
```

`%i` = inodo, `%h` = contador de enlaces duros, `%s` = tamaño, `%n` = nombre.

4. Confirmá que la segunda columna de `ls -l` es ese contador de enlaces, y no otra cosa:

```bash
$ ls -l payload.txt | awk '{print $2}'
1
```

**Verificá tu comprensión**

- **P1.1** — ¿Dónde se almacena físicamente el nombre `payload.txt`: en el inodo, o en otro lado?
- **P1.2** — `stat` muestra `Modify` y `Change` por separado. ¿Cuál cambia si ejecutás `chmod 600 payload.txt`, y por qué importa esa distinción para los enlaces duros?
- **P1.3** — En `ls -l`, ¿qué es exactamente el número de la segunda columna para un archivo regular?

---

## Ejercicio 2 — Enlaces duros: un inodo, varios nombres

1. Creá un segundo nombre para el mismo inodo con `ln` (sin opciones = enlace duro):

```bash
$ ln payload.txt payload-hard.txt
$ ls -li
total 8
1442653 -rw-r--r-- 2 student student 32 Aug 26 09:14 payload-hard.txt
1442653 -rw-r--r-- 2 student student 32 Aug 26 09:14 payload.txt
```

El mismo número de inodo. El contador de enlaces pasó de `1 → 2`. `total 8` cuenta los bloques dos veces, pero los datos existen una sola vez — lo vas a medir en el Ejercicio 7.

2. Escribí a través de un nombre, leé a través del otro:

```bash
$ echo 'note: patched in place' >> payload.txt
$ cat payload-hard.txt
release: 1.0
checksum: 8f14e45f
note: patched in place
```

3. Cambiá los metadatos a través de un nombre:

```bash
$ chmod 640 payload-hard.txt
$ chown --from=student student payload.txt   # no-op, just proving the syntax works
$ ls -li
1442653 -rw-r----- 2 student student 55 Aug 26 09:16 payload-hard.txt
1442653 -rw-r----- 2 student student 55 Aug 26 09:16 payload.txt
```

Los permisos y la propiedad viven en el inodo, así que ambos nombres muestran `-rw-r-----`. No existe tal cosa como "los permisos de un enlace duro".

4. Renombrá el nombre *original* y comprobá que nada se rompe:

```bash
$ mv payload.txt payload-renamed.txt
$ ls -li
1442653 -rw-r----- 2 student student 55 Aug 26 09:16 payload-hard.txt
1442653 -rw-r----- 2 student student 55 Aug 26 09:16 payload-renamed.txt
$ cat payload-hard.txt | tail -1
note: patched in place
```

5. Encontrá todos los nombres que apuntan a ese inodo:

```bash
$ find ~ -samefile payload-hard.txt 2>/dev/null
/home/student/lab-104.6/payload-hard.txt
/home/student/lab-104.6/payload-renamed.txt

$ find ~ -inum 1442653 2>/dev/null
/home/student/lab-104.6/payload-hard.txt
/home/student/lab-104.6/payload-renamed.txt
```

**Verificá tu comprensión**

- **P2.1** — Después del paso 4, ¿cuál de los dos nombres es "el archivo original"?
- **P2.2** — ¿Por qué `chmod` a través de `payload-hard.txt` también cambió `payload-renamed.txt`?
- **P2.3** — Acá `find -inum 1442653` y `find -samefile X` devolvieron lo mismo. En una máquina con varios sistemas de archivos montados, ¿por qué `-samefile` es el más seguro de los dos?
- **P2.4** — Necesitás darle a un colega acceso de lectura a un dataset de 40 GB en tu directorio home sin copiarlo. ¿Es un enlace duro una técnica válida acá? ¿Qué tiene que cumplirse respecto de la ruta destino?

---

## Ejercicio 3 — Semántica del borrado: unlink, contador de enlaces y descriptores abiertos

1. Eliminá un nombre y mirá cómo baja el contador:

```bash
$ rm payload-renamed.txt
$ stat -c '%i %h %n' payload-hard.txt
1442653 1 payload-hard.txt
```

Los datos quedan intactos; solo desapareció una entrada de directorio.

2. Ahora el caso que confunde a todo SRE junior. Creá un archivo grande, mantenelo abierto con un descriptor de archivo, borralo y observá cómo el espacio *no* vuelve:

```bash
$ dd if=/dev/zero of=bigfile bs=1M count=64 status=none
$ df -h . | tail -1
/dev/vda2        40G   12G   26G  32% /home

$ exec 9< bigfile          # shell opens fd 9 on the inode
$ rm bigfile               # unlink: the NAME is gone
$ ls bigfile
ls: cannot access 'bigfile': No such file or directory

$ ls -l /proc/$$/fd/9
lr-x------ 1 student student 64 Aug 26 09:22 /proc/4187/fd/9 -> '/home/student/lab-104.6/bigfile (deleted)'
```

3. El inodo todavía existe — aún podés leerlo a través del descriptor:

```bash
$ head -c 8 /proc/$$/fd/9 | xxd
00000000: 0000 0000 0000 0000                      ........
```

4. Liberalo y los bloques quedan disponibles:

```bash
$ exec 9<&-
$ ls -l /proc/$$/fd/9
ls: cannot access '/proc/4187/fd/9': No such file or directory
```

5. En producción estos casos se encuentran con `lsof`:

```bash
$ sudo lsof +L1 2>/dev/null | head -3
COMMAND    PID USER   FD   TYPE DEVICE SIZE/OFF NLINK    NODE NAME
rsyslogd   912 root    7w   REG  253,2 21474836     0 1442701 /var/log/messages (deleted)
```

`NLINK 0` = borrado pero mantenido abierto.

6. Los directorios tienen su propia aritmética de contador de enlaces:

```bash
$ mkdir -p parent
$ stat -c '%h %n' parent
2 parent

$ mkdir parent/child-a parent/child-b
$ stat -c '%h %n' parent
4 parent
```

**Verificá tu comprensión**

- **P3.1** — `df` informa un `/var` lleno pero `du -sh /var` contabiliza mucho menos. Dá la causa más común y el comando exacto que lo demuestra.
- **P3.2** — Un directorio que acabás de crear tiene un contador de enlaces de 2. Nombrá ambos enlaces.
- **P3.3** — Después de crear dos subdirectorios el contador es 4. ¿De dónde salieron los enlaces 3 y 4?
- **P3.4** — ¿Por qué difiere la rotación de logs por `rm` del truncado sin reinicio? Concretamente: ¿por qué `> /var/log/messages` libera espacio de inmediato mientras que `rm /var/log/messages` no?

---

## Ejercicio 4 — Enlaces simbólicos: un archivo cuyo contenido es una ruta

1. Creá uno con `ln -s`:

```bash
$ ln -s payload-hard.txt payload-sym.txt
$ ls -li
total 8
1442653 -rw-r----- 1 student student 55 Aug 26 09:16 payload-hard.txt
1442667 lrwxrwxrwx 1 student student 16 Aug 26 09:26 payload-sym.txt -> payload-hard.txt
```

Tres cosas para notar: un **inodo distinto**, tipo de archivo `l`, y **tamaño 16** — exactamente `strlen("payload-hard.txt")`. El "contenido" del symlink *es* la cadena con la ruta destino.

2. Comprobá la afirmación sobre el tamaño:

```bash
$ ln -s /a/very/much/longer/path/that/does/not/exist demo-long
$ stat -c '%s %N' demo-long payload-sym.txt
41 'demo-long' -> '/a/very/much/longer/path/that/does/not/exist'
16 'payload-sym.txt' -> 'payload-hard.txt'
```

3. `stat` no sigue nada por defecto; `stat -L` desreferencia:

```bash
$ stat -c '%i %F %s' payload-sym.txt
1442667 symbolic link 16

$ stat -L -c '%i %F %s' payload-sym.txt
1442653 regular file 55
```

4. Leé el enlace y resolvelo por completo:

```bash
$ readlink payload-sym.txt
payload-hard.txt

$ readlink -f payload-sym.txt
/home/student/lab-104.6/payload-hard.txt

$ realpath payload-sym.txt
/home/student/lab-104.6/payload-hard.txt
```

`readlink -f` canoniza cada componente y tolera que falte el componente *final*; `readlink -e` exige que exista toda la ruta; `readlink -m` no exige nada:

```bash
$ readlink -f demo-long
/a/very/much/longer/path/that/does/not/exist
$ readlink -e demo-long; echo "exit=$?"
exit=1
```

5. El modo `lrwxrwxrwx` es cosmético en Linux — el acceso lo deciden los permisos del destino y los directorios que atravesás:

```bash
$ chmod 000 payload-sym.txt
chmod: changing permissions of 'payload-sym.txt': Operation not supported
```

6. La propiedad y los timestamps del enlace en sí necesitan `-h`:

```bash
$ touch -h payload-sym.txt          # touches the link, not the target
$ sudo chown -h root: payload-sym.txt   # would change the LINK's owner
$ sudo chown root: payload-sym.txt      # would change the TARGET's owner
```

(No ejecutes las dos líneas de `chown` a menos que sea tu intención; se muestran por el contraste.)

**Verificá tu comprensión**

- **P4.1** — ¿Por qué `ls -l` muestra tamaño 16 para un symlink cuyo destino es un archivo de 55 bytes?
- **P4.2** — Necesitás saber si `/etc/localtime` es en sí mismo un symlink, sin seguirlo. ¿Qué comando y qué flag?
- **P4.3** — `chmod 000` sobre el symlink falló. ¿Cuáles son las dos cosas que realmente controlan el acceso a través de un symlink?
- **P4.4** — Explicá la diferencia entre `readlink -f`, `readlink -e` y `readlink -m` en una oración cada una.
- **P4.5** — Un script de backup ejecuta `chown -R appuser: /srv/app`. `/srv/app/tmp` es un symlink a `/var/tmp`. ¿Cuál es el radio de daño, y qué flag lo habría contenido?

---

## Ejercicio 5 — Symlinks relativos vs absolutos, y qué sobrevive a un movimiento

1. Construí ambas variantes lado a lado:

```bash
$ mkdir -p tree/data tree/links
$ echo "payload v1" > tree/data/file.txt
$ ln -s ../data/file.txt          tree/links/rel.txt
$ ln -s "$PWD/tree/data/file.txt" tree/links/abs.txt
$ ls -l tree/links/
lrwxrwxrwx 1 student student 40 Aug 26 09:31 abs.txt -> /home/student/lab-104.6/tree/data/file.txt
lrwxrwxrwx 1 student student 17 Aug 26 09:31 rel.txt -> ../data/file.txt
```

2. Ambos resuelven hoy:

```bash
$ cat tree/links/rel.txt tree/links/abs.txt
payload v1
payload v1
```

3. Mové todo el árbol — el clásico escenario "cambiamos el punto de montaje":

```bash
$ mv tree tree-moved
$ cat tree-moved/links/rel.txt
payload v1
$ cat tree-moved/links/abs.txt
cat: tree-moved/links/abs.txt: No such file or directory
```

4. Ahora mové solo el *enlace*, que es el fallo opuesto:

```bash
$ mv tree-moved/links/rel.txt .
$ cat rel.txt
cat: rel.txt: No such file or directory
$ readlink rel.txt
../data/file.txt
$ mv rel.txt tree-moved/links/     # put it back
```

5. Dejá que `ln` calcule la ruta relativa por vos (`-r`, coreutils ≥ 8.16):

```bash
$ ln -sr tree-moved/data/file.txt tree-moved/links/auto.txt
$ readlink tree-moved/links/auto.txt
../data/file.txt
```

6. La trampa de `ln -sf` con directorios. Armá una disposición de releases:

```bash
$ mkdir -p releases/v1 releases/v2
$ echo v1 > releases/v1/VERSION
$ echo v2 > releases/v2/VERSION
$ cd releases
$ ln -s v1 current
$ readlink current
v1
```

Ahora intentá reapuntarlo de la manera obvia:

```bash
$ ln -sf v2 current
$ readlink current
v1
$ ls -l v1/
total 4
-rw-r--r-- 1 student student 3 Aug 26 09:33 VERSION
lrwxrwxrwx 1 student student 2 Aug 26 09:34 v2 -> v2
```

`ln` **siguió** `current` hacia adentro de `v1/` y creó un enlace *dentro* de él. Deshacelo y hacelo correctamente:

```bash
$ rm v1/v2
$ ln -sfn v2 current
$ readlink current
v2
$ cd ..
```

**Verificá tu comprensión**

- **P5.1** — Enunciá la regla sobre qué punto de referencia se usa para resolver un symlink relativo.
- **P5.2** — Para un symlink dentro de un paquete que se va a instalar bajo un `DESTDIR` arbitrario, ¿usás relativo o absoluto? ¿Por qué?
- **P5.3** — Explicá con precisión por qué `ln -sf v2 current` creó `v1/v2` en lugar de reapuntar `current`.
- **P5.4** — ¿Qué le indica `-n` (`--no-dereference`) a `ln`?
- **P5.5** — `ln -sfn` sigue sin ser atómico. Describí la ventana de inconsistencia y escribí un par de comandos que la cierre.

---

## Ejercicio 6 — Los límites: lo que un enlace duro no puede hacer

1. **Cruzar sistemas de archivos.** `/dev/shm` es un montaje `tmpfs` separado en prácticamente toda distribución:

```bash
$ findmnt -no TARGET,FSTYPE /dev/shm .
/dev/shm  tmpfs
/home     ext4

$ ln payload-hard.txt /dev/shm/attempt
ln: failed to create hard link '/dev/shm/attempt' => 'payload-hard.txt': Invalid cross-device link
```

`EXDEV`. Un número de inodo solo tiene sentido dentro de un sistema de archivos, así que una entrada de directorio nunca puede apuntar fuera del suyo.

2. Un symlink cruza sin problema, porque almacena una *ruta*, no un número de inodo:

```bash
$ ln -s "$PWD/payload-hard.txt" /dev/shm/attempt
$ cat /dev/shm/attempt | head -1
release: 1.0
$ rm /dev/shm/attempt
```

3. **Directorios.** Enlazar duro un directorio se rechaza:

```bash
$ ln parent parent-link
ln: parent: hard link not allowed for directory

$ sudo ln -d parent parent-link
ln: failed to create hard link 'parent-link' => 'parent': Operation not permitted
```

Incluso como root, el kernel de Linux devuelve `EPERM` desde `link(2)` sobre un directorio. Los symlinks a directorios sí son válidos y son la forma en que se hilvana toda la jerarquía del sistema de archivos.

4. **Bucles.** Los symlinks pueden apuntarse entre sí; el kernel se rinde después de 40 resoluciones:

```bash
$ ln -s loop-b loop-a
$ ln -s loop-a loop-b
$ cat loop-a
cat: loop-a: Too many levels of symbolic links
$ ls -l loop-a
lrwxrwxrwx 1 student student 6 Aug 26 09:38 loop-a -> loop-b
```

Fijate que `ls -l` sigue funcionando — nunca desreferencia.

5. **Enlaces rotos.** Nada impide crear un enlace a una ruta que no existe:

```bash
$ ln -s /srv/not-deployed-yet broken
$ ls -l broken
lrwxrwxrwx 1 student student 20 Aug 26 09:39 broken -> /srv/not-deployed-yet

$ cat broken
cat: broken: No such file or directory

$ [ -e broken ]; echo "exists=$?"
exists=1
$ [ -L broken ]; echo "is-a-symlink=$?"
is-a-symlink=0
```

6. Encontrá enlaces rotos en todo un árbol:

```bash
$ find . -xtype l
./broken
./loop-a
./loop-b
./demo-long
```

**Verificá tu comprensión**

- **P6.1** — ¿Por qué `EXDEV` es una limitación estructural y no una decisión de política que alguien podría relajar?
- **P6.2** — Dá dos problemas concretos que surgirían si se permitieran enlaces duros a directorios.
- **P6.3** — En un script de shell, ¿qué test distingue "esto es un symlink" de "esto resuelve a algo que existe"? Escribí la comprobación para un symlink *roto*.
- **P6.4** — ¿Cuál es la diferencia entre `find -type l` y `find -xtype l`?
- **P6.5** — Tu despliegue crea `/opt/app/current -> /opt/app/releases/2026-08-26` *antes* de desempaquetar el directorio del release. `ls -l` se ve correcto y el servicio no arranca. ¿Cuál es el comando de diagnóstico?

---

## Ejercicio 7 — Auditoría: uso de disco, inodos y encontrar enlaces a escala

1. Los enlaces duros se cuentan una sola vez por recorrido de `du`:

```bash
$ mkdir -p usage && cd usage
$ dd if=/dev/zero of=blob.bin bs=1M count=10 status=none
$ ln blob.bin blob-alias.bin
$ ls -l
total 20480
-rw-r--r-- 2 student student 10485760 Aug 26 09:42 blob-alias.bin
-rw-r--r-- 2 student student 10485760 Aug 26 09:42 blob.bin

$ du -sh .
10M     .
$ du -sh --count-links .
20M     .
```

`ls` suma por nombre y miente; `du` deduplica por `(dispositivo, inodo)` y dice la verdad sobre el consumo de disco.

2. Un symlink cuesta un inodo y, en ext4, normalmente cero bloques de datos:

```bash
$ ln -s blob.bin blob-sym.bin
$ du -sh --apparent-size blob-sym.bin
8       blob-sym.bin
$ du -sh blob.bin blob-sym.bin
10M     blob.bin
0       blob-sym.bin
```

ext4 almacena un destino de menos de 60 bytes en línea, dentro del área de punteros a bloques del inodo ("fast symlink"), así que no se asigna ningún bloque.

3. Los inodos son un recurso finito y agotable por separado:

```bash
$ df -i /home
Filesystem       Inodes   IUsed    IFree IUse% Mounted on
/dev/vda2       2621440  318204  2303236   13% /home
```

4. Las consultas de auditoría que deberías tener memorizadas:

```bash
# Regular files with more than one name (candidates for surprise shared edits)
$ find . -type f -links +1 -printf '%n %i %p\n'
2 1442712 ./blob-alias.bin
2 1442712 ./blob.bin

# Every symlink and where it points
$ find . -type l -printf '%p -> %l\n'
./blob-sym.bin -> blob.bin

# Only broken ones
$ find . -xtype l

# Every name of one specific inode, limited to one filesystem
$ find / -xdev -samefile ./blob.bin 2>/dev/null
```

5. Confirmá que el riesgo del inodo compartido es real:

```bash
$ cd ~/lab-104.6
```

**Verificá tu comprensión**

- **P7.1** — `ls -l` dice 20 MB, `du -sh` dice 10 MB. ¿Cuál es el número correcto para reportar a planificación de capacidad, y por qué existen los dos?
- **P7.2** — `du` deduplica los enlaces duros *dentro de una misma invocación*. ¿Qué pasa si ejecutás `du -sh dir-a` y `du -sh dir-b` por separado y el mismo inodo está enlazado en ambos?
- **P7.3** — `df -h` muestra 60% libre pero las escrituras fallan con `No space left on device`. ¿Qué revisás a continuación, y con qué comando?
- **P7.4** — Escribí un único comando `find` que liste todos los symlinks bajo `/etc` junto con su destino.
- **P7.5** — ¿Por qué `find / -samefile X` merece `-xdev` en un script de auditoría?

---

## Ejercicio 8 — Enlaces vs copias: `cp`, `tar`, `rsync` y editores in-place

1. Armá un árbol pequeño que contenga ambos tipos de enlace:

```bash
$ mkdir -p src && cd src
$ echo "config v1" > app.conf
$ ln app.conf app.conf.hard
$ ln -s app.conf app.conf.sym
$ ls -li
1442731 -rw-r--r-- 2 student student 10 Aug 26 09:48 app.conf
1442731 -rw-r--r-- 2 student student 10 Aug 26 09:48 app.conf.hard
1442745 lrwxrwxrwx 1 student student  8 Aug 26 09:48 app.conf.sym -> app.conf
$ cd ..
```

2. Un `cp -r` común **desreferencia** los symlinks y **rompe** los enlaces duros:

```bash
$ cp -r src dst-plain
$ ls -li dst-plain
1442760 -rw-r--r-- 1 student student 10 Aug 26 09:49 app.conf
1442761 -rw-r--r-- 1 student student 10 Aug 26 09:49 app.conf.hard
1442762 -rw-r--r-- 1 student student 10 Aug 26 09:49 app.conf.sym
```

Tres archivos regulares independientes. El symlink se convirtió en una copia de su destino.

3. `cp -a` (archive) preserva ambos:

```bash
$ cp -a src dst-archive
$ ls -li dst-archive
1442770 -rw-r--r-- 2 student student 10 Aug 26 09:48 app.conf
1442770 -rw-r--r-- 2 student student 10 Aug 26 09:48 app.conf.hard
1442771 lrwxrwxrwx 1 student student  8 Aug 26 09:48 app.conf.sym -> app.conf
```

`-a` = `-dR --preserve=all`, y `-d` = `--no-dereference --preserve=links`.

4. `cp -l` crea enlaces duros en lugar de copiar datos — la base de los backups por snapshot (`rsnapshot`, rotaciones con `cp -al`):

```bash
$ cp -al src snapshot-1
$ stat -c '%i %h %n' src/app.conf snapshot-1/app.conf
1442731 3 src/app.conf
1442731 3 snapshot-1/app.conf
```

Un "backup completo" que consumió cero bloques de datos adicionales. La trampa es la P8.4.

5. `tar` preserva ambos por defecto; `-h` colapsa los symlinks:

```bash
$ tar -cf archive.tar src
$ tar -tvf archive.tar
drwxr-xr-x student/student   0 2026-08-26 09:48 src/
-rw-r--r-- student/student  10 2026-08-26 09:48 src/app.conf
hrw-r--r-- student/student   0 2026-08-26 09:48 src/app.conf.hard link to src/app.conf
lrwxrwxrwx student/student   0 2026-08-26 09:48 src/app.conf.sym -> app.conf

$ tar -chf archive-deref.tar src
$ tar -tvf archive-deref.tar | grep sym
-rw-r--r-- student/student  10 2026-08-26 09:48 src/app.conf.sym
```

6. `rsync -a` implica `-l` (copiar symlinks como symlinks) pero **no** `-H` (preservar enlaces duros):

```bash
$ rsync -a src/ dst-rsync/
$ stat -c '%i %h %n' dst-rsync/app.conf dst-rsync/app.conf.hard
1442790 1 dst-rsync/app.conf
1442791 1 dst-rsync/app.conf.hard

$ rsync -aH --delete src/ dst-rsync/
$ stat -c '%i %h %n' dst-rsync/app.conf dst-rsync/app.conf.hard
1442795 2 dst-rsync/app.conf
1442795 2 dst-rsync/app.conf.hard
```

7. Editores in-place: `sed -i` **rompe** los enlaces duros, porque escribe un archivo temporal y hace `rename(2)` sobre el nombre:

```bash
$ cd src
$ stat -c '%i %h %n' app.conf app.conf.hard
1442731 3 app.conf
1442731 3 app.conf.hard

$ sed -i 's/v1/v2/' app.conf
$ stat -c '%i %h %n' app.conf app.conf.hard
1442801 1 app.conf
1442731 2 app.conf.hard
$ cat app.conf app.conf.hard
config v2
config v1
```

Los nombres divergieron. Notá que el snapshot en `snapshot-1/app.conf` todavía contiene `config v1` — que es precisamente por lo que funcionan los snapshots con `cp -al`.

8. `cp` sobre un nombre existente, en cambio, **escribe a través** (open + `O_TRUNC`) y conserva el inodo:

```bash
$ echo "config v3" > /tmp/new.conf
$ cp /tmp/new.conf app.conf.hard
$ stat -c '%i %h %n' app.conf.hard
1442731 2 app.conf.hard
$ cat app.conf.hard snapshot-out 2>/dev/null | head -1
config v3
$ cat ../snapshot-1/app.conf
config v3
```

El snapshot fue modificado silenciosamente. `cp --remove-destination` restaura la semántica de copiar-y-reemplazar.

9. Y sobre un symlink, `sed -i` reemplaza el enlace por un archivo regular salvo que se le indique lo contrario:

```bash
$ sed -i 's/v3/v4/' app.conf.sym
$ ls -l app.conf.sym
-rw-r--r-- 1 student student 10 Aug 26 09:55 app.conf.sym

$ cd .. && rm -rf src && mkdir src && cd src   # rebuild for the next line
$ echo "config v1" > app.conf && ln -s app.conf app.conf.sym
$ sed -i --follow-symlinks 's/v1/v2/' app.conf.sym
$ ls -l app.conf.sym && cat app.conf
lrwxrwxrwx 1 student student 8 Aug 26 09:56 app.conf.sym -> app.conf
config v2
$ cd ..
```

**Verificá tu comprensión**

- **P8.1** — Dos trabajos de backup: `cp -r /srv /backup` y `cp -a /srv /backup`. Nombrá tres diferencias en el resultado.
- **P8.2** — ¿Qué flag de `rsync` preserva los enlaces duros, y por qué está deliberadamente excluido de `-a`?
- **P8.3** — `tar -czf web.tar.gz /var/www` produjo un archivo mucho más grande que `du -sh /var/www`. ¿Qué flag había probablemente en la línea de comandos, y qué hizo?
- **P8.4** — Hay una rotación de snapshots con `cp -al` en funcionamiento. Un administrador ejecuta `cp new.conf /srv/app/app.conf`. Explicá qué le pasa al snapshot de ayer y qué debería haber ejecutado el administrador.
- **P8.5** — ¿Por qué `sed -i` rompe un enlace duro y `>>` no?
- **P8.6** — Tus sesiones de `vim` siguen rompiendo enlaces duros en archivos de `/etc/`. ¿Qué opción de `vim` controla esto, y con qué valor?

---

## Ejercicio 9 — Patrones de producción que vas a encontrar en un sistema real

1. **Cambio atómico de release.** Este es el patrón de symlink más común en las herramientas de despliegue:

```bash
$ cd ~/lab-104.6/releases
$ ls
current  v1  v2
$ mkdir v3 && echo v3 > v3/VERSION
```

La forma no atómica (`ln -sfn` = `unlink()` y luego `symlink()`) deja una ventana en la que `current` no existe:

```bash
$ ln -sfn v3 current
$ readlink current
v3
```

La forma atómica — crear un enlace temporal y luego hacerle `rename(2)` sobre el viejo en una sola operación del kernel:

```bash
$ ln -s v2 current.tmp
$ mv -T current.tmp current
$ readlink current
v2
```

`-T` (`--no-target-directory`) es obligatorio: sin él, `mv` seguiría `current` hacia adentro de `v2/` y depositaría el enlace ahí.

2. **Eliminar un symlink a un directorio.** La barra final importa más acá que en cualquier otro lugar de la shell:

```bash
$ ls current/
VERSION
$ rm current
$ ls
current.tmp  v1  v2  v3
$ ls v2/
VERSION
```

`rm` sobre el symlink eliminó *solo el enlace*; `v2/` quedó intacto. Y el `rm` de GNU rechaza directamente la forma con barra final:

```bash
$ ln -s v2 current
$ rm -r current/
rm: cannot remove 'current/': Not a directory
$ ls v2/
VERSION
```

3. **Versionado de bibliotecas compartidas.** Cada `.so` contra el que hayas enlazado alguna vez es una cadena de symlinks de dos saltos:

```bash
$ ls -l /usr/lib64/libz.so*        # paths vary by distribution
lrwxrwxrwx 1 root root     13 Jun  2 11:04 /usr/lib64/libz.so -> libz.so.1.3.1
lrwxrwxrwx 1 root root     13 Jun  2 11:04 /usr/lib64/libz.so.1 -> libz.so.1.3.1
-rwxr-xr-x 1 root root 121208 Jun  2 11:04 /usr/lib64/libz.so.1.3.1
```

- `libz.so.1.3.1` — el archivo real, el *realname*.
- `libz.so.1` — el **SONAME**, lo que el enlazador dinámico registra en cada binario y resuelve en tiempo de ejecución. Creado por `ldconfig`.
- `libz.so` — el *linker name*, usado solo por `ld` en tiempo de compilación, distribuido en el paquete `-devel`.

Reproducí el patrón localmente:

```bash
$ cd ~/lab-104.6 && mkdir -p libdemo && cd libdemo
$ : > libdemo.so.1.2.3
$ ln -s libdemo.so.1.2.3 libdemo.so.1
$ ln -s libdemo.so.1     libdemo.so
$ ls -l
lrwxrwxrwx 1 student student  11 Aug 26 10:02 libdemo.so -> libdemo.so.1
lrwxrwxrwx 1 student student  15 Aug 26 10:02 libdemo.so.1 -> libdemo.so.1.2.3
-rw-r--r-- 1 student student   0 Aug 26 10:02 libdemo.so.1.2.3
$ cd ..
```

4. **`/etc/localtime`** — un symlink hacia la base de datos tzdata:

```bash
$ ls -l /etc/localtime
lrwxrwxrwx 1 root root 52 Jun  2 11:03 /etc/localtime -> ../usr/share/zoneinfo/America/Argentina/Buenos_Aires
$ readlink -f /etc/localtime
/usr/share/zoneinfo/America/Argentina/Buenos_Aires
```

Notá que es **relativo** (`../usr/...`), y eso es deliberado: sigue funcionando dentro de un chroot o de una imagen de contenedor construida con una raíz distinta.

5. **`systemctl enable` es gestión de symlinks.** No hay base de datos:

```bash
$ ls -l /etc/systemd/system/multi-user.target.wants/ | head -4
total 0
lrwxrwxrwx 1 root root 36 Jun  2 11:10 sshd.service -> /usr/lib/systemd/system/sshd.service
lrwxrwxrwx 1 root root 41 Jun  2 11:10 chronyd.service -> /usr/lib/systemd/system/chronyd.service

$ systemctl is-enabled sshd
enabled
```

`disable` borra el symlink. `mask` reemplaza la ruta de la unidad por un symlink a `/dev/null`:

```bash
$ systemctl is-enabled systemd-networkd 2>/dev/null; ls -l /etc/systemd/system/tmp.mount 2>/dev/null
lrwxrwxrwx 1 root root 9 Jun  2 11:11 /etc/systemd/system/tmp.mount -> /dev/null
```

6. **`/etc/alternatives`** — una cadena de symlinks de dos niveles para que varios paquetes puedan proveer `editor`, `java`, `python`:

```bash
$ ls -l /usr/bin/editor /etc/alternatives/editor 2>/dev/null
lrwxrwxrwx 1 root root 24 Jun  2 11:06 /etc/alternatives/editor -> /usr/bin/vim.basic
lrwxrwxrwx 1 root root 22 Jun  2 11:06 /usr/bin/editor -> /etc/alternatives/editor
```

7. **`/proc/<pid>/exe` y `/proc/<pid>/cwd`** son symlinks sintetizados por el kernel — útiles para análisis forense:

```bash
$ ls -l /proc/self/exe
lrwxrwxrwx 1 student student 0 Aug 26 10:05 /proc/4187/exe -> /usr/bin/ls
$ readlink /proc/self/cwd
/home/student/lab-104.6
```

**Verificá tu comprensión**

- **P9.1** — ¿Por qué `mv -T newlink current` es atómico y `ln -sfn` no lo es, y qué ve una petición que llega durante la ventana de `ln -sfn`?
- **P9.2** — ¿Por qué es obligatorio `-T` en ese `mv`?
- **P9.3** — De `libz.so`, `libz.so.1`, `libz.so.1.3.1` — ¿cuál resuelve un binario *en ejecución*, cuál usa el *compilador*, y qué programa crea el enlace intermedio?
- **P9.4** — `/etc/localtime` es un symlink relativo. Dá la razón operativa.
- **P9.5** — Un colega informa: "`systemctl disable` no funcionó, el servicio sigue arrancando en el boot". ¿Qué dos directorios inspeccionás, y qué estás buscando?
- **P9.6** — ¿Qué hace enmascarar (mask) una unidad a nivel del sistema de archivos, y por qué es más fuerte que deshabilitarla?

---

## Ejercicio 10 — Endurecimiento del kernel: protected symlinks y protected hardlinks

`/tmp` es escribible por todos y tiene el sticky bit, lo que históricamente habilitó escaladas de privilegios basadas en symlinks y hardlinks: un atacante pre-crea `/tmp/somefile` como symlink a `/etc/shadow`, y un demonio root que escribe en esa ruta predecible lo sobrescribe.

1. Revisá los dos sysctls (por defecto `1` en esencialmente toda distribución moderna):

```bash
$ sysctl fs.protected_symlinks fs.protected_hardlinks
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
```

2. `fs.protected_hardlinks=1` prohíbe crear un enlace duro a un archivo del que no sos propietario ni tenés acceso de lectura+escritura. Comprobalo:

```bash
$ sudo sh -c 'echo secret > /tmp/rootfile && chmod 600 /tmp/rootfile'
$ ls -l /tmp/rootfile
-rw------- 1 root root 7 Aug 26 10:10 /tmp/rootfile

$ ln /tmp/rootfile /tmp/mine
ln: failed to create hard link '/tmp/mine' => '/tmp/rootfile': Operation not permitted
```

Sin la protección esto tendría éxito: el contador de enlaces subiría, y borrar `/tmp/rootfile` *no* liberaría el inodo, dejándole al atacante un manejador permanente sobre el contenido.

3. Un symlink, en cambio, siempre se puede crear — crear uno no otorga ningún acceso:

```bash
$ ln -s /tmp/rootfile /tmp/mysym
$ cat /tmp/mysym
cat: /tmp/mysym: Permission denied
```

4. `fs.protected_symlinks=1` restringe *seguir* un symlink en un directorio escribible por todos con sticky bit cuando el propietario del symlink difiere tanto del propietario del directorio como del proceso que lo sigue. Revisá el sticky bit:

```bash
$ ls -ld /tmp
drwxrwxrwt 1 root root 4096 Aug 26 10:10 /tmp
```

La `t` es lo que activa la regla.

5. Limpieza:

```bash
$ sudo rm -f /tmp/rootfile /tmp/mysym
```

6. Las aplicaciones se defienden con `O_NOFOLLOW` / `openat2(RESOLVE_NO_SYMLINKS)`. Desde la shell, la higiene equivalente es canonizar antes de actuar:

```bash
$ target=$(readlink -e /path/from/config) || { echo "refusing: does not resolve" >&2; exit 1; }
$ case "$target" in /srv/app/*) : ;; *) echo "refusing: escapes /srv/app" >&2; exit 1 ;; esac
```

**Verificá tu comprensión**

- **P10.1** — ¿Por qué es necesario `fs.protected_hardlinks`, dado que un enlace duro no cambia los permisos del archivo?
- **P10.2** — ¿Qué propiedad debe tener el directorio para que `fs.protected_symlinks` aplique?
- **P10.3** — ¿Por qué *cualquiera* puede crear un symlink a `/etc/shadow` sin que eso sea una vulnerabilidad en sí misma?
- **P10.4** — Un script de backup corre como root y hace `cat "$userpath" > /backup/out`. Esbozá el ataque que puede montar un usuario con un symlink, y una mitigación.

---

## Limpieza

```bash
$ cd ~ && rm -rf ~/lab-104.6
$ rm -f /dev/shm/attempt
```

---

## Referencia de comandos para este objetivo

| Tarea | Comando |
|---|---|
| Enlace duro | `ln TARGET LINKNAME` |
| Enlace simbólico | `ln -s TARGET LINKNAME` |
| Symlink relativo, calculado | `ln -sr TARGET LINKNAME` |
| Reapuntar un symlink a directorio existente | `ln -sfn NEWTARGET LINKNAME` |
| Reapuntar de forma atómica | `ln -s NEW L.tmp && mv -T L.tmp L` |
| Enlace duro al symlink en sí | `ln -P SYMLINK NEWNAME` |
| Mostrar inodo + contador de enlaces | `ls -li` / `stat -c '%i %h %n' F` |
| Seguir el enlace en `stat` | `stat -L F` |
| Leer el destino de un symlink | `readlink F` |
| Canonizar | `readlink -f` / `-e` / `-m`, `realpath F` |
| Todos los nombres de un inodo | `find DIR -xdev -samefile F` |
| Todos los symlinks + destinos | `find DIR -type l -printf '%p -> %l\n'` |
| Symlinks rotos | `find DIR -xtype l` |
| Archivos regulares con múltiples enlaces | `find DIR -type f -links +1` |
| Uso real de disco | `du -sh DIR` (vs `--count-links`) |
| Agotamiento de inodos | `df -i` |
| Eliminar un nombre | `rm F` o `unlink F` |
| Copiar preservando enlaces | `cp -a`, `cp -d`, `rsync -aH` |
| Copiar como enlaces duros (snapshot) | `cp -al SRC DST` |
| Cambiar el propietario del enlace en sí | `chown -h`, `touch -h` |

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**R1.1** — En el **directorio padre**, no en el inodo. Un directorio es una tabla de entradas `(nombre, número de inodo)`. El inodo guarda modo, propietario, timestamps, tamaño, contador de enlaces y punteros a bloques, pero nunca un nombre. Justamente por eso un inodo puede tener muchos nombres y por eso un archivo puede renombrarse sin tocar sus datos.

**R1.2** — `chmod` actualiza **`Change` (ctime)** únicamente, porque modifica metadatos del inodo, no el contenido del archivo. `Modify` (mtime) registra cambios de datos. Para los enlaces duros esto importa porque *ambos timestamps viven en el inodo*: tocar el archivo a través de cualquier nombre actualiza el mtime visto a través de todos los nombres. No hay timestamp por nombre.

**R1.3** — El **contador de enlaces duros**: la cantidad de entradas de directorio en todo el sistema de archivos que referencian a este inodo. `1` significa exactamente un nombre. Borrar nombres lo decrementa; el inodo se libera al llegar a `0` (y solo cuando ningún proceso lo mantiene abierto).

### Ejercicio 2

**R2.1** — Ninguno. El concepto no existe. Después de `ln`, las dos entradas de directorio son pares — idénticas en todo sentido, indistinguibles a nivel del sistema de archivos. No hay un "original" ni "el enlace"; hay un inodo con dos nombres. Esta es la diferencia más importante respecto de un symlink, donde la asimetría es real y permanente.

**R2.2** — Porque los permisos se almacenan en el inodo, y ambos nombres referencian el mismo inodo. `chmod` opera sobre el inodo alcanzado por la ruta que hayas nombrado. No hay modo por nombre.

**R2.3** — Los números de inodo son únicos **solo dentro de un sistema de archivos**. `find / -inum 1442653` va a coincidir con inodos no relacionados en cada otro sistema de archivos montado que reutilice ese número. `-samefile` compara el par `(st_dev, st_ino)`, que es la identidad realmente única de un archivo. Usá `-samefile`, y agregá `-xdev` cuando conozcas el sistema de archivos del destino.

**R2.4** — Solo si el destino está en el **mismo sistema de archivos** (confirmalo con `findmnt`), y solo si los permisos de los directorios en la ruta del colega le permiten atravesar hasta el nuevo nombre. Notá dos consecuencias: (a) la copia de tu colega tiene el mismo inodo, así que sus permisos y propiedad son los tuyos y no pueden divergir; (b) si después hacés `rm` de tu nombre, el de él mantiene vivos los 40 GB — el espacio no se recupera. Para compartir entre usuarios, un symlink más un directorio legible por el grupo suele ser la mejor herramienta; un enlace duro es adecuado para deduplicación *dentro* de un mismo dominio administrativo (snapshots, almacenes de paquetes).

### Ejercicio 3

**R3.1** — Archivos borrados pero abiertos: un proceso (típicamente un logger o una aplicación cuyo log fue rotado con `rm` o `mv` sin un `SIGHUP`/reapertura) todavía mantiene un descriptor sobre un inodo desenlazado. `du` recorre nombres y no puede verlo; `df` informa bloques asignados y sí lo ve. Comprobalo con:

```bash
sudo lsof +L1
```

Un `NLINK` de `0` en esa salida es la prueba definitiva. Se arregla haciendo que el proceso reabra (`systemctl reload`, `kill -HUP`, o reiniciar) — no borrando más archivos.

**R3.2** — `parent` en su propio directorio padre, y `parent/.` — la entrada que todo directorio contiene y que apunta a sí mismo.

**R3.3** — De `parent/child-a/..` y `parent/child-b/..`. La entrada `..` de cada subdirectorio es un enlace duro adicional a su padre. De ahí la fórmula: **contador de enlaces de un directorio = 2 + cantidad de subdirectorios inmediatos**, que es una forma rápida de contar subdirectorios sin listarlos (`stat -c %h dir`) — y una razón por la que `find` puede saltear el `stat` de entradas en algunas optimizaciones.

**R3.4** — `> file` **trunca** el inodo existente: mantiene el mismo inodo y los mismos descriptores abiertos válidos, y libera los bloques de datos de inmediato. `rm file` solo desenlaza el nombre; el escritor todavía mantiene el inodo abierto y sigue añadiendo a un archivo inalcanzable. Precisamente por esto `logrotate` usa `copytruncate` cuando no puede señalizar al demonio, y por eso la secuencia correcta de rotación es `mv` + señal de reapertura (el demonio reabre por *nombre*, liberando el inodo viejo).

### Ejercicio 4

**R4.1** — Porque el "contenido del archivo" del symlink *es* la cadena con la ruta destino. `ls -l` informa el tamaño del symlink en sí, que es `strlen(destino)` sin el NUL terminador. `stat -L` informaría los 55 bytes del destino.

**R4.2** — `ls -l /etc/localtime`, o más precisamente `stat /etc/localtime` (que **no** desreferencia por defecto), o en modo script `test -L /etc/localtime`. `stat -L` y `readlink -f` lo seguirían, que es lo opuesto a lo que pediste.

**R4.3** — (1) Los **permisos del archivo destino**, y (2) el permiso de **ejecución/búsqueda en cada directorio** atravesado al resolver la ruta destino. Los bits de modo `lrwxrwxrwx` del inodo del symlink son ignorados por completo por Linux; por eso `chmod` devuelve `EOPNOTSUPP` sobre un symlink. (Algunos otros Unix sí respetan los permisos de los symlinks — no construyas lógica portable sobre eso.)

**R4.4** —
- `readlink -f` — canoniza cada componente, siguiendo todos los symlinks; el **último** componente puede no existir.
- `readlink -e` — igual, pero **todos** los componentes deben existir; si no, sale con código distinto de cero. Usalo en scripts cuando requieras que el archivo esté ahí.
- `readlink -m` — igual, pero **ningún** componente necesita existir; nunca falla por ausencia. Usalo cuando calculás una ruta que estás por crear.

**R4.5** — Sin `-h`, `chown -R` sigue el symlink y recursivamente le cambia el propietario a **`/var/tmp` y todo lo que contiene** a `appuser` — una rotura a nivel de sistema que afecta a todo servicio que use `/var/tmp`. `chown -R -h` (o mejor, `chown -R --no-dereference`) cambia la propiedad del symlink en sí y nunca lo atraviesa. El `chown -R` de GNU ofrece además `-P` (por defecto: no atravesar symlinks), `-H` y `-L`; el valor seguro por defecto es `-P`/`-h`.

### Ejercicio 5

**R5.1** — Un symlink relativo se resuelve **respecto del directorio que contiene el symlink**, no respecto del directorio de trabajo actual del proceso ni de la ubicación del destino. Así que `tree/links/rel.txt -> ../data/file.txt` significa "`tree/links/../data/file.txt`", es decir `tree/data/file.txt`, sin importar a dónde hayas hecho `cd` antes de leerlo.

**R5.2** — **Relativo.** Un symlink absoluto graba el prefijo de tiempo de compilación y apunta fuera de la raíz de staging, así que se rompe en un árbol de staging con `DESTDIR`, en una imagen de contenedor, en un chroot y en cualquier instalación relocalizada. Un enlace relativo dentro del paquete se mantiene internamente consistente donde sea que se monte el árbol. Por eso `/etc/localtime` y la mayoría de los enlaces provistos por las distribuciones son relativos. Los enlaces absolutos son correctos cuando el destino realmente es una ubicación fija y global del sistema que debe seguirse sin importar dónde viva el enlace.

**R5.3** — `ln` desreferencia el nombre del enlace por defecto. `current` era un symlink existente a un directorio, así que `ln` lo resolvió a `v1/` y aplicó la regla estándar "`ln TARGET DIRECTORY`": crear un enlace dentro de ese directorio con el nombre base del destino. Resultado: `v1/v2 -> v2`. `-f` solo forzó sobrescribir un `v1/v2` preexistente; nunca tocó `current`.

**R5.4** — `-n` / `--no-dereference` le indica a `ln` que trate el nombre del enlace como un archivo común aunque sea un symlink a un directorio — de modo que `-f` reemplace *el symlink en sí* en lugar de seguirlo. En la práctica, escribí siempre `ln -sfn` para symlinks a directorios; el hábito no cuesta nada con destinos que no son directorios.

**R5.5** — `ln -sfn` está implementado como `unlink("current")` seguido de `symlink("v2", "current")`. Entre esas dos llamadas al sistema el nombre **no existe**: cualquier proceso que resuelva `/opt/app/current/...` en esa ventana obtiene `ENOENT`. Bajo carga eso es una ráfaga de errores 500. Cerrala con un único `rename(2)` atómico:

```bash
ln -s v3 current.tmp && mv -T current.tmp current
```

`rename(2)` reemplaza la entrada de destino de forma atómica — los lectores ven o el enlace viejo o el nuevo, nunca nada.

### Ejercicio 6

**R6.1** — Una entrada de directorio almacena un **número de inodo**, y los números de inodo tienen espacio de nombres por sistema de archivos — el inodo 1442653 en `/home` y el inodo 1442653 en `/var` son archivos sin relación. Por lo tanto una entrada de directorio no tiene forma de *expresar* "el archivo de ese otro sistema de archivos"; no hay campo para un identificador de dispositivo. No es una política, es la ausencia de un valor representable. Un symlink esquiva esto almacenando una cadena de ruta, que el kernel vuelve a resolver desde la raíz del espacio de nombres en cada acceso — cruzando montajes libremente.

**R6.2** — Dos cualesquiera de:
- **Ciclos irrompibles.** `ln /a /a/b` produciría un grafo de directorios con un bucle sin ningún punto de entrada con contador de enlaces 1, de modo que un `unlink` con recolección nunca podría reclamarlo y `fsck` no podría decidir qué está huérfano. El árbol se convierte en un grafo cíclico general.
- **`..` se vuelve ambiguo.** Un directorio tiene exactamente una entrada `..`; con dos padres, la resolución de rutas hacia arriba queda indefinida.
- **El recorrido nunca termina.** `find`, `du`, `tar` y toda herramienta recursiva quedarían en bucle infinito o necesitarían detección de ciclos, ya que dependen de que el árbol sea acíclico.

**R6.3** — `[ -L path ]` es verdadero para un symlink independientemente de si resuelve. `[ -e path ]` sigue el enlace y es verdadero solo si el destino existe. Un symlink roto es entonces:

```bash
if [ -L "$p" ] && [ ! -e "$p" ]; then echo "broken symlink: $p"; fi
```

**R6.4** — `-type l` coincide con **todos** los symlinks. `-xtype l` comprueba el tipo del archivo al que el enlace *apunta*; si el enlace está roto no hay nada que comprobar, así que `find` recae en reportar el enlace mismo como tipo `l`. Efecto neto sobre los symlinks: `-xtype l` coincide exactamente con los **rotos** (y con las cadenas de symlinks que terminan en otro symlink). Ese es el modismo para encontrar enlaces colgantes.

**R6.5** — `readlink -e /opt/app/current` — sale con código distinto de cero y no imprime nada cuando falta cualquier componente de la ruta resuelta, a diferencia de `readlink -f`, que imprime alegremente una ruta a un directorio inexistente. `ls -l` es inútil acá porque nunca desreferencia. `ls -L /opt/app/current` o `stat -L` también lo expondrían (`No such file or directory`). Barrido más amplio: `find /opt -xtype l`.

### Ejercicio 7

**R7.1** — Reportá **los 10 MB de `du`**: ese es el número de bloques realmente asignados en el dispositivo, que es lo que llena el sistema de archivos. `ls -l` informa el `st_size` de cada inodo por nombre; como ambos nombres comparten un inodo, cuenta doble. Ambos existen porque responden preguntas distintas — "cuán grande es este archivo" (`ls`) versus "cuánto almacenamiento consume este árbol" (`du`).

**R7.2** — Cada invocación arranca con un conjunto de vistos vacío, así que el inodo se cuenta **una vez en cada ejecución** — 10 MB + 10 MB = 20 MB reportados para 10 MB de almacenamiento real. Para obtener la cifra verdadera, pasá ambos directorios a una sola invocación: `du -sh --total dir-a dir-b`, o `du -shc dir-a dir-b`. Esta es una fuente habitual de confusión en rotaciones de backup con enlaces duros, donde el `du` por snapshot suma enormemente más que el tamaño real del pool.

**R7.3** — **Agotamiento de inodos.** `df -h` mide bloques de datos; `df -i` mide inodos, que en ext2/3/4 se asignan en el momento del `mkfs` y son un pool separado y fijo:

```bash
df -i /path
```

`IUse% 100%` con bloques libres es la firma. Causa típica: millones de archivos diminutos (spools de correo, archivos de sesión, directorios de caché). ext4 no puede hacer crecer la tabla de inodos después del hecho — o borrás archivos o reformateás con `mkfs.ext4 -i` / `-N`. XFS y Btrfs asignan inodos dinámicamente y no tienen este modo de falla.

**R7.4** —

```bash
find /etc -type l -printf '%p -> %l\n'
```

`%l` es el especificador de formato de `find` para "objeto de un enlace simbólico". Agregá `-xtype l` para acotarlo a los rotos — un chequeo de salud de `/etc` genuinamente útil después de eliminar un paquete.

**R7.5** — Sin `-xdev`, `find /` desciende a cada sistema de archivos montado: montajes de red (NFS/CIFS, que pueden colgarse o ser enormes), `/proc` y `/sys` (sintéticos, con semántica de inodos sin sentido), bind mounts (que informan el *mismo* dispositivo e inodo, produciendo coincidencias duplicadas para un solo archivo) y montajes overlay de contenedores. `-xdev` confina la búsqueda al sistema de archivos en el que empezaste — que además es el único que podría contener un enlace duro a tu destino.

### Ejercicio 8

**R8.1** — Tres cualesquiera de:
- `cp -r` **desreferencia los symlinks**, reemplazando cada uno por una copia completa de su destino — inflando el tamaño y posiblemente copiando datos de fuera del árbol origen. `cp -a` los preserva como symlinks (vía `-d`).
- `cp -r` **rompe los enlaces duros**: dos nombres que comparten un inodo se convierten en dos archivos independientes, duplicando el almacenamiento. `cp -a` preserva el compartido (`--preserve=links`).
- `cp -r` **no preserva** propiedad, permisos, timestamps, ACLs, xattrs ni contexto SELinux. `cp -a` implica `--preserve=all`.
- Con un bucle de symlinks o un symlink que apunta hacia arriba en el árbol, `cp -r` puede recursar patológicamente o fallar; `cp -a` simplemente copia el enlace.

Para backups, `cp -a` (o `rsync -aHAX`) es la única elección defendible.

**R8.2** — `-H` / `--hard-links`. Está excluido de `-a` porque preservar enlaces duros requiere que rsync construya en memoria un mapa de todos los inodos con múltiples enlaces de la transferencia, lo que cuesta memoria y CPU significativos en árboles grandes, y porque el caso común (la mayoría de los archivos tienen un enlace) no gana nada. `-a` es `-rlptgoD`: recursivo, links (symlinks), permisos, tiempos, grupo, propietario, dispositivos/especiales — pero no `-H`, ni `-A` (ACLs), ni `-X` (xattrs). La invocación de backup de fidelidad completa es `rsync -aHAX --numeric-ids`.

**R8.3** — `-h` (`--dereference`). Reemplazó cada symlink por una copia del archivo al que apuntaba. En un web root lleno de symlinks hacia un directorio de assets compartido — o, peor, un symlink a `/` o a un montaje grande — esto multiplica el tamaño del archivo comprimido o lo vuelve ilimitado. Quitá `-h`; `tar` preserva symlinks y enlaces duros (como entradas `hrw-...` "link to") por defecto.

**R8.4** — `cp` abre el destino con `O_TRUNC` y escribe en el **inodo existente**, que es el mismo inodo al que enlaza el snapshot. El snapshot de ayer, por lo tanto, ahora contiene el contenido de hoy — el backup está corrompido silenciosamente, y el propósito entero de la rotación queda anulado. El administrador debería haber usado:

```bash
cp --remove-destination new.conf /srv/app/app.conf
```

que primero desenlaza el nombre destino, bajando el contador de enlaces y dejando intacto el inodo del snapshot, y luego crea un archivo nuevo. `install -m`, `mv` y cualquier editor basado en rename (`sed -i`, `vim` con `backupcopy` por defecto) también son seguros por la misma razón. Esta asimetría — `cp` escribe a través, `mv`/`sed -i` reemplazan — es el riesgo operativo número uno de los backups por snapshot con enlaces duros.

**R8.5** — `sed -i` no edita in situ pese al nombre: escribe el resultado en un archivo temporal del mismo directorio y luego le hace `rename(2)` sobre el nombre destino. `rename` reemplaza la *entrada de directorio*, así que ese nombre pasa a apuntar a un inodo nuevo mientras todos los demás nombres siguen apuntando al viejo — el enlace queda roto y los contenidos divergen. `>>` (y `>`) llaman a `open(2)` sobre la ruta existente y escriben en el **mismo inodo**, así que todos los nombres observan el cambio y el contador de enlaces no se altera.

**R8.6** — `backupcopy`. Poné `:set backupcopy=yes` (o agregá `set backupcopy=yes` a tu `vimrc`), lo que hace que `vim` copie el original al archivo de backup y luego **escriba en el inodo original**, preservando enlaces duros, propiedad, ACLs y contexto SELinux. El valor por defecto `auto` prefiere la estrategia de rename, más rápida, que rompe los enlaces. `vim` ya fuerza el comportamiento `yes` en algunos casos (por ejemplo, cuando el archivo tiene múltiples enlaces y `backupcopy=auto` lo detecta), pero no confíes en la heurística con archivos bajo `/etc`.

### Ejercicio 9

**R9.1** — `mv -T` en el mismo sistema de archivos es una única llamada `rename(2)`, que el kernel realiza de forma atómica respecto de otras resoluciones de ruta: cualquier proceso que resuelva `current` observa o bien la entrada vieja completa o bien la nueva completa. `ln -sfn` son dos llamadas al sistema — `unlink("current")` y luego `symlink("v2","current")` — y una petición que llegue entre ellas resuelve `current` a nada y obtiene **`ENOENT`** (un 404/500 del servidor web, o un `open` fallido en la aplicación). Con unos pocos miles de peticiones por segundo esa ventana no es teórica.

**R9.2** — `-T` / `--no-target-directory` obliga a `mv` a tratar `current` como el nombre de destino literal. Sin él, `mv` ve que `current` es un symlink a un directorio, lo sigue y mueve `current.tmp` *dentro* de `v2/`, produciendo `v2/current.tmp` y dejando `current` todavía apuntando al release viejo — un no-op silencioso que parece un despliegue exitoso.

**R9.3** —
- Un **binario en ejecución** resuelve `libz.so.1` — el **SONAME**, que `ld` registró en la entrada `DT_NEEDED` del ejecutable en tiempo de compilación y que `ld.so` busca en tiempo de exec. El enlace de versión mayor es el contrato de compatibilidad de ABI.
- El **compilador/enlazador** en tiempo de compilación usa `libz.so`, el *linker name* sin versión, resuelto a partir de `-lz`. Existe solo en paquetes `-devel`/`-dev`.
- **`ldconfig`** crea y mantiene el enlace `libz.so.1 -> libz.so.1.3.1` (y el índice `/etc/ld.so.cache`) leyendo el SONAME embebido de cada biblioteca. Por eso `ldconfig` debe ejecutarse después de instalar una biblioteca en un directorio de `/etc/ld.so.conf.d/`.

**R9.4** — Para que resuelva correctamente respecto de la raíz bajo la que se encuentre. `../usr/share/zoneinfo/...` desde `/etc/` significa "`/usr/share/zoneinfo/...` *de esta raíz*". Dentro de un chroot, una imagen de contenedor, un sistema de archivos de rescate montado en `/mnt/sysroot` o un despliegue basado en imágenes/OSTree, un `/usr/share/zoneinfo/...` absoluto resolvería silenciosamente a la tzdata del **host** (o a nada). La forma relativa mantiene el enlace internamente consistente con el árbol en el que se distribuye.

**R9.5** — Revisá:
1. `/etc/systemd/system/*.target.wants/` — `systemctl disable` elimina symlinks acá, pero solo los creados por `enable` a partir de la sección `[Install]` de la unidad. Un symlink hecho a mano, o uno bajo un target distinto del que nombra `[Install]`, queda ahí.
2. `/etc/systemd/system/` en sí y `/run/systemd/system/` — un **drop-in override** o una copia completa de la unidad puede agregar `WantedBy`/`Requires`, y el `Wants=`/`Requires=` de otra unidad puede arrastrar el servicio independientemente de su propia habilitación.

Chequeo autoritativo: `systemctl list-unit-files <name>`, `systemctl show -p WantedBy -p RequiredBy <name>` y `systemctl list-dependencies --reverse <name>`. Si nunca debe arrancar, hacele `systemctl mask`.

**R9.6** — Enmascarar crea un symlink desde el nombre de la unidad en `/etc/systemd/system/` (mayor precedencia que `/usr/lib/systemd/system/`) hacia **`/dev/null`**. systemd trata a una unidad cuya ruta resuelve a `/dev/null` como inexistente e imposible de cargar. Es más fuerte que `disable` porque `disable` solo elimina los symlinks de `.wants/` que causan la activación *automática* en el boot — la unidad todavía puede iniciarse manualmente o ser arrastrada como dependencia de otra unidad. Una unidad enmascarada no puede iniciarse en absoluto: `systemctl start` sobre ella falla con `Unit is masked`.

### Ejercicio 10

**R10.1** — Porque un enlace duro es una **referencia permanente e irrevocable al inodo** que sobrevive al `rm` del propietario. Dos ataques concretos que habilita:
1. **Retención de contenido.** Un atacante hace un enlace duro a un archivo que está por ser rotado, borrado o al que se le van a endurecer los permisos (un archivo temporal que contiene brevemente un token, una clave que se está regenerando). Borrar el original no libera el inodo; el atacante conserva la instantánea para siempre, y los cambios de permisos posteriores sobre el *inodo* no eliminan su enlace existente.
2. **Escrituras de diputado confundido.** Un proceso setuid o root que escribe en una ruta elegida por el atacante dentro de un directorio compartido, o que "de forma segura" hace `chown`/`chmod` a un archivo que cree haber creado, puede ser dirigido a un enlace hacia un inodo sensible — incluyendo variantes de bypass de cuota y TOCTOU. `fs.protected_hardlinks=1` exige que quien enlaza sea propietario del inodo origen o tenga acceso de lectura **y** escritura sobre él, lo que elimina toda la clase.

**R10.2** — El directorio debe ser **escribible por todos y sticky** (`drwxrwxrwt`, modo `1777`) — la forma clásica de `/tmp`, `/var/tmp`, `/dev/shm`. La restricción entonces bloquea *seguir* un symlink en ese directorio cuando el propietario del symlink no es ni el UID del proceso que lo sigue ni el propietario del directorio. Fuera de los directorios sticky escribibles por todos la protección no aplica, porque ahí los permisos del directorio ya establecen quién pudo haber plantado el enlace.

**R10.3** — Crear un symlink almacena una **cadena de ruta** y no otorga derecho alguno; el kernel hace cumplir el `0640 root:shadow` de `/etc/shadow` en cada `open()` a través de él, exactamente igual que lo haría con la ruta directa. `cat /tmp/mysym` devuelve `Permission denied` para un usuario sin privilegios. La vulnerabilidad solo se materializa cuando un proceso **privilegiado** sigue el enlace del atacante y hace con el destino algo que no habría hecho directamente sobre `/etc/shadow` — escribir, truncar, `chown`, `chmod`. El enlace es la carnada; el privilegio pertenece al proceso víctima.

**R10.4** — **Ataque:** el usuario hace que `$userpath` sea un symlink a `/etc/shadow` (o a `/root/.ssh/id_ed25519`). El script root lo sigue y copia el contenido a `/backup/out`, que el usuario después puede leer — o, en el sentido de escritura (`cat something > "$userpath"`), el proceso root trunca y sobrescribe un archivo de sistema arbitrario. `fs.protected_symlinks` **no** te salva acá: solo cubre directorios sticky escribibles por todos, y el directorio home del propio usuario no es uno.

**Mitigaciones**, la mejor primero:
- No ejecutar el recorrido como root. Bajar al propietario del archivo (`setpriv --reuid`, `runuser -u`) para que apliquen las propias comprobaciones de permisos del kernel.
- Negarse a seguir: `open(..., O_NOFOLLOW)` en código; en shell, verificar con `[ -L "$p" ] && exit 1`, o canonizar con `readlink -e` y afirmar que el resultado queda dentro del prefijo permitido (como en el paso 6 del ejercicio).
- Para trabajo sobre árboles completos, usar herramientas que no desreferencien por defecto: `tar` sin `-h`, `cp -P`/`-a`, `rsync -l`, `find -P` (el valor por defecto), `chown -h`.
- Bajo un kernel moderno, `openat2(2)` con `RESOLVE_NO_SYMLINKS`/`RESOLVE_BENEATH` impone la contención en el kernel en lugar de en una carrera de comprobar-y-luego-usar.

</details>

---

## Fuentes

- LPI — Objetivos del examen 101 (LPIC-1 v5.0), objetivo 104.6: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- Manual de GNU Coreutils — invocación de `ln`: <https://www.gnu.org/software/coreutils/manual/html_node/ln-invocation.html>
- Manual de GNU Coreutils — invocación de `cp`: <https://www.gnu.org/software/coreutils/manual/html_node/cp-invocation.html>
- Manual de GNU Coreutils — invocación de `readlink`: <https://www.gnu.org/software/coreutils/manual/html_node/readlink-invocation.html>
- Manual de GNU Findutils — tests y acciones (`-samefile`, `-xtype`, `-links`, `-printf`): <https://www.gnu.org/software/findutils/manual/html_mono/find.html>
- `symlink(7)` — manejo de enlaces simbólicos: <https://man7.org/linux/man-pages/man7/symlink.7.html>
- `link(2)` — `EXDEV`, `EPERM` en directorios: <https://man7.org/linux/man-pages/man2/link.2.html>
- `rename(2)` — garantías de atomicidad: <https://man7.org/linux/man-pages/man2/rename.2.html>
- `open(2)` — `O_NOFOLLOW`, `O_TRUNC`: <https://man7.org/linux/man-pages/man2/open.2.html>
- `openat2(2)` — `RESOLVE_NO_SYMLINKS`, `RESOLVE_BENEATH`: <https://man7.org/linux/man-pages/man2/openat2.2.html>
- Documentación del kernel Linux — `fs.protected_symlinks` y `fs.protected_hardlinks`: <https://docs.kernel.org/admin-guide/sysctl/fs.html>
- Documentación del kernel Linux — formato en disco de ext4 (fast symlinks, `EXT4_LINK_MAX`): <https://docs.kernel.org/filesystems/ext4/index.html>
- `systemd.unit(5)` — ruta de carga de archivos de unidad, enmascaramiento, symlinks de `[Install]`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html>
- `ldconfig(8)` y `ld.so(8)` — resolución de SONAME y cadenas de enlaces de bibliotecas: <https://man7.org/linux/man-pages/man8/ldconfig.8.html>
- `rsync(1)` — semántica de `-a`, `-H`, `-l`: <https://download.samba.org/pub/rsync/rsync.1>
- Manual de GNU Tar — `--dereference` y manejo de enlaces duros: <https://www.gnu.org/software/tar/manual/html_node/dereference.html>