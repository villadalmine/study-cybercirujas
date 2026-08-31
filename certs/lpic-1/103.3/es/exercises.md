# 103.3 — Realizar la gestión básica de archivos
## Ejercicios guiados (LPIC-1, examen 101-500, v5.0 — peso 6.25)

**Entorno asumido:** un sistema Linux con GNU coreutils ≥ 8.30, GNU findutils, GNU tar ≥ 1.30, GNU cpio y `bash` 5.x. Donde el comportamiento de BSD/busybox difiere de forma relevante, se señala. Todo el trabajo ocurre dentro de un árbol de laboratorio desechable: no se toca nada fuera de `~/lpic1-lab`, con dos excepciones marcadas explícitamente como solo lectura (`/etc/hostname`) o temporales (`/tmp`, `/dev/shm`).

> **Regla de seguridad para todo este módulo:** cada `rm -rf` y cada `dd of=` de estos ejercicios apunta a una ruta dentro de tu directorio de laboratorio. Leé cada comando antes de pulsar Enter. Un `dd` que escribe en un nodo `/dev/sd*` o `/dev/nvme*` destruye un disco; no hay deshacer ni confirmación.

---

## Ejercicio 0 — Preparación del laboratorio

```bash
mkdir -p ~/lpic1-lab/103.3
cd ~/lpic1-lab/103.3
export LAB="$PWD"
echo "$LAB"
```

Verificá que estás en el lugar correcto antes de continuar; cada ejercicio posterior empieza con `cd "$LAB"`.

---

## Ejercicio 1 — Crear un árbol y leer lo que el sistema de archivos realmente almacena

`ls`, `mkdir`, `touch`, `stat`, enlaces duros frente a enlaces simbólicos.

### Pasos

1. Construí el esqueleto de directorios en un solo comando:

   ```bash
   cd "$LAB"
   mkdir -p project/{src,doc,build/obj,logs}
   ```

2. Inspeccioná lo que se creó:

   ```console
   $ find project -type d | sort
   project
   project/build
   project/build/obj
   project/doc
   project/logs
   project/src
   ```

3. Creá archivos regulares vacíos, otra vez con expansión de llaves:

   ```bash
   touch project/src/{main,util,parser}.c
   touch project/doc/{README.md,design.txt}
   ```

4. Creá tres archivos binarios de tamaños conocidos y distintos:

   ```bash
   for i in 1 2 3; do
     head -c $((i * 1024)) /dev/urandom > "project/build/obj/mod$i.o"
   done
   ls -l project/build/obj
   ```

   ```console
   -rw-r--r--. 1 user user 1024 Aug 26 10:14 mod1.o
   -rw-r--r--. 1 user user 2048 Aug 26 10:14 mod2.o
   -rw-r--r--. 1 user user 3072 Aug 26 10:14 mod3.o
   ```

5. Leé los metadatos completos de un archivo:

   ```console
   $ stat project/src/main.c
     File: project/src/main.c
     Size: 0            Blocks: 0          IO Block: 4096   regular empty file
   Device: 0,42   Inode: 1179651     Links: 1
   Access: (0644/-rw-r--r--)  Uid: ( 1000/    user)   Gid: ( 1000/    user)
   Access: 2026-08-26 10:14:02.113254190 -0300
   Modify: 2026-08-26 10:14:02.113254190 -0300
   Change: 2026-08-26 10:14:02.113254190 -0300
    Birth: 2026-08-26 10:14:02.113254190 -0300
   ```

6. Creá un **enlace duro** y un **enlace simbólico** al mismo archivo, y compará:

   ```bash
   ln    project/src/main.c project/src/main.c.hard
   ln -s ../src/main.c      project/doc/main.c.sym
   ```

   ```console
   $ ls -li project/src/
   total 0
   1179651 -rw-r--r--. 2 user user 0 Aug 26 10:14 main.c
   1179651 -rw-r--r--. 2 user user 0 Aug 26 10:14 main.c.hard
   1179654 -rw-r--r--. 1 user user 0 Aug 26 10:14 parser.c
   1179653 -rw-r--r--. 1 user user 0 Aug 26 10:14 util.c

   $ ls -l project/doc/
   total 4
   -rw-r--r--. 1 user user  0 Aug 26 10:14 README.md
   -rw-r--r--. 1 user user  0 Aug 26 10:14 design.txt
   lrwxrwxrwx. 1 user user 13 Aug 26 10:16 main.c.sym -> ../src/main.c
   ```

7. Manipulá las marcas de tiempo deliberadamente — esto importa para `find` más adelante:

   ```bash
   touch -d '2020-01-01 09:00:00' project/src/main.c
   touch -d '10 days ago'  project/logs/old.log      # -d creates the file too
   touch -d '2 days ago'   project/logs/recent.log
   touch -d '30 min ago'   project/logs/fresh.log
   touch -c project/logs/does-not-exist.log          # -c: do NOT create
   ls -l project/logs
   ```

8. Compará las tres marcas de tiempo de `main.c` después del cambio:

   ```console
   $ stat -c 'atime=%x%nmtime=%y%nctime=%z' project/src/main.c
   atime=2020-01-01 09:00:00.000000000 -0300
   mtime=2020-01-01 09:00:00.000000000 -0300
   ctime=2026-08-26 10:18:41.552091223 -0300
   ```

9. Listá por tamaño y por fecha de modificación:

   ```bash
   ls -lhS project/build/obj      # -S: largest first
   ls -lt  project/logs           # -t: newest first
   ls -ltu project/logs           # -u with -l: show/sort by ACCESS time
   ls -d   project/*/             # -d: the directories themselves, not contents
   ```

### Preguntas — bloque 1

- **Q1.1** En el paso 6, ¿cuál de `main.c.hard` y `main.c.sym` comparte inodo con `main.c`? ¿Qué número de `ls -li` lo demuestra, y qué cuenta la *tercera* columna de `ls -l`?
- **Q1.2** `ls -l` informa tamaño `13` para `main.c.sym` mientras que `main.c` tiene tamaño `0`. ¿De dónde sale el 13?
- **Q1.3** `stat` informa `Size: 0` **y** `Blocks: 0` para `main.c`, pero `IO Block: 4096`. Explicá los tres valores.
- **Q1.4** En el paso 8, `touch -d` fijó atime y mtime en 2020, pero ctime muestra *ahora* y no se puede fijar en 2020 con ninguna opción de `touch`. ¿Por qué?
- **Q1.5** ¿`project/{src,doc,build/obj,logs}` en el paso 1 es una expansión de glob (comodines)? ¿Qué pasaría si `project/src` ya existiera y ejecutaras el mismo `mkdir -p` otra vez?
- **Q1.6** ¿Qué devuelve `ls -d project/*/` que no devuelve `ls project`, y para qué sirve la barra final?

---

## Ejercicio 2 — `cp`: recursión, semántica del destino y metadatos

### Pasos

1. Copiá un solo archivo, de forma verbosa:

   ```console
   $ cd "$LAB"
   $ cp -v project/doc/README.md /tmp/
   'project/doc/README.md' -> '/tmp/README.md'
   ```

2. Intentá copiar un directorio **sin** recursión:

   ```console
   $ cp project/src /tmp/src-copy
   cp: -r not specified; omitting directory 'project/src'
   $ echo $?
   1
   ```

3. Ahora copialo recursivamente a un destino que **no existe**:

   ```console
   $ cp -r project/src /tmp/src-copy
   $ ls /tmp/src-copy
   main.c  main.c.hard  parser.c  util.c
   ```

4. Ejecutá **exactamente el mismo comando una segunda vez** y mirá con atención:

   ```console
   $ cp -r project/src /tmp/src-copy
   $ find /tmp/src-copy -maxdepth 2 | sort
   /tmp/src-copy
   /tmp/src-copy/main.c
   /tmp/src-copy/main.c.hard
   /tmp/src-copy/parser.c
   /tmp/src-copy/src
   /tmp/src-copy/src/main.c
   /tmp/src-copy/src/main.c.hard
   /tmp/src-copy/src/parser.c
   /tmp/src-copy/src/util.c
   /tmp/src-copy/util.c
   ```

5. Copiá **solo el contenido** dentro de un directorio existente — el modismo `/.`:

   ```bash
   rm -rf /tmp/src-copy
   mkdir  /tmp/src-copy
   cp -r project/src/. /tmp/src-copy/
   find /tmp/src-copy -maxdepth 1 | sort
   ```

6. Compará `cp` simple con `cp -p` sobre el archivo fechado en 2020:

   ```console
   $ cp    project/src/main.c /tmp/plain.c
   $ cp -p project/src/main.c /tmp/preserved.c
   $ stat -c '%n  mtime=%y  mode=%a' /tmp/plain.c /tmp/preserved.c
   /tmp/plain.c  mtime=2026-08-26 10:31:07.884...  mode=644
   /tmp/preserved.c  mtime=2020-01-01 09:00:00.000...  mode=644
   ```

7. Copiá el árbol completo en modo archivo y comprobá cómo sobrevivieron los enlaces:

   ```console
   $ cp -a project /tmp/project-a
   $ ls -l /tmp/project-a/doc/main.c.sym
   lrwxrwxrwx. 1 user user 13 Aug 26 10:16 /tmp/project-a/doc/main.c.sym -> ../src/main.c

   $ ls -li /tmp/project-a/src/main.c /tmp/project-a/src/main.c.hard
   2231455 -rw-r--r--. 2 user user 0 Jan  1  2020 /tmp/project-a/src/main.c
   2231455 -rw-r--r--. 2 user user 0 Jan  1  2020 /tmp/project-a/src/main.c.hard
   ```

8. Ahora desreferenciá en su lugar:

   ```console
   $ cp -rL project /tmp/project-L
   $ ls -l /tmp/project-L/doc/main.c.sym
   -rw-r--r--. 1 user user 0 Jan  1  2020 /tmp/project-L/doc/main.c.sym

   $ ls -li /tmp/project-L/src/main.c /tmp/project-L/src/main.c.hard
   2231701 -rw-r--r--. 1 user user 0 ... /tmp/project-L/src/main.c
   2231702 -rw-r--r--. 1 user user 0 ... /tmp/project-L/src/main.c.hard
   ```

9. Probá `-u` (update) y `-n` (no-clobber):

   ```console
   $ echo "v2" > project/doc/README.md
   $ cp -u -v project/doc/README.md /tmp/
   'project/doc/README.md' -> '/tmp/README.md'
   $ cp -u -v project/doc/README.md /tmp/          # nothing to do now
   $ cp -n -v project/doc/README.md /tmp/
   $ cat /tmp/README.md
   v2
   ```

10. Comportamiento interactivo y de respaldo:

    ```console
    $ echo "v3" > project/doc/README.md
    $ cp -i project/doc/README.md /tmp/
    cp: overwrite '/tmp/README.md'? n
    $ cp --backup=numbered project/doc/README.md /tmp/
    $ ls /tmp/README.md*
    /tmp/README.md  /tmp/README.md.~1~
    ```

> **Nota de producción.** En Btrfs y XFS, `cp --reflink=auto` crea un clon copy-on-write: la copia es instantánea y no consume espacio adicional hasta que uno de los dos se modifica. No entra en el examen, pero en una máquina Fedora/RHEL con Btrfs es el valor por defecto correcto para copiar imágenes grandes.

### Preguntas — bloque 2

- **Q2.1** Los pasos 3 y 4 ejecutaron el comando *idéntico* y produjeron resultados distintos. Enunciá la regla que aplica `cp` a su último argumento.
- **Q2.2** Se supone que `cp` es seguro de repetir. ¿El paso 4 fue idempotente? ¿Cómo se escribe una copia recursiva que *sí* lo sea?
- **Q2.3** ¿A qué equivale exactamente `-a`, y cuál de sus componentes es responsable de que el enlace simbólico sobreviva como enlace simbólico en el paso 7?
- **Q2.4** En el paso 7 el enlace duro se preservó como enlace duro (mismo inodo, contador de enlaces 2). En el paso 8 se convirtió en dos archivos independientes. ¿Qué opción lo provocó, y cuál es la consecuencia en espacio de disco para un árbol grande?
- **Q2.5** `cp -p` preservó modo, propiedad y marcas de tiempo. Si ejecutás `cp -p` como usuario normal sobre un archivo cuyo dueño es `root`, ¿qué parte de `-p` falla, y qué hace `cp` al respecto?
- **Q2.6** Distinguí `cp -u`, `cp -n` y `cp -i`. ¿Cuál tiene en cuenta el *contenido* y cuáles dos se basan puramente en existencia o marca de tiempo?

---

## Ejercicio 3 — `mv`, `rm`, `rmdir` y nombres de archivo que se resisten

### Pasos

1. Renombrá dentro del mismo sistema de archivos y observá el inodo:

   ```console
   $ cd "$LAB"
   $ ls -i project/doc/design.txt
   1179656 project/doc/design.txt
   $ mv project/doc/design.txt project/doc/architecture.txt
   $ ls -i project/doc/architecture.txt
   1179656 project/doc/architecture.txt
   ```

2. Demostrá que `/dev/shm` es otro sistema de archivos y luego mové a través de él:

   ```console
   $ stat -c '%n is on device %d' . /dev/shm
   . is on device 42
   /dev/shm is on device 24

   $ cp project/build/obj/mod3.o .
   $ ls -i mod3.o
   1179660 mod3.o
   $ mv mod3.o /dev/shm/
   $ ls -i /dev/shm/mod3.o
   17 /dev/shm/mod3.o
   $ rm /dev/shm/mod3.o
   ```

3. Mové un directorio sobre un nombre de directorio existente:

   ```console
   $ mkdir -p /tmp/dest
   $ cp -a project/logs /tmp/logs-a
   $ mv /tmp/logs-a /tmp/dest
   $ ls /tmp/dest
   logs-a
   ```

4. Controles de sobreescritura segura:

   ```bash
   cp project/doc/README.md /tmp/target.md
   echo "newer" > /tmp/source.md
   mv -n -v /tmp/source.md /tmp/target.md     # refuses, source stays
   mv -b -v /tmp/source.md /tmp/target.md     # keeps /tmp/target.md~
   ls /tmp/target.md*
   ```

5. `rmdir` solo elimina directorios **vacíos**:

   ```console
   $ rmdir project
   rmdir: failed to remove 'project': Directory not empty

   $ mkdir -p /tmp/a/b/c
   $ rmdir -p /tmp/a/b/c
   $ ls -d /tmp/a
   ls: cannot access '/tmp/a': No such file or directory
   ```

6. Ahora los nombres de archivo hostiles. Creálos en un directorio aislado:

   ```bash
   mkdir -p /tmp/nasty && cd /tmp/nasty
   touch -- -i
   touch -- --help
   touch 'two words'
   touch $'line\nbreak'
   touch '*'
   ls -b
   ```

   ```console
   $ ls -b
   --help  -i  line\nbreak  two\ words  *
   ```

7. Mirá qué pasa cuando el shell le entrega `-i` a `rm` como opción:

   ```console
   $ rm *
   rm: remove regular empty file '*'? 
   ```

   Respondé `n` y pulsá Enter. El archivo llamado literalmente `-i` fue expandido por el glob, quedó primero al ordenarse, y `rm` lo interpretó como la opción *interactive*.

8. Eliminalos correctamente, de dos maneras:

   ```bash
   rm -- -i --help
   rm ./'*'
   rm 'two words'
   find . -maxdepth 1 -type f -print0 | xargs -0 rm -v --
   cd "$LAB"; rmdir /tmp/nasty
   ```

9. Borrado recursivo, y la barrera de protección que tenés que interiorizar:

   ```bash
   cp -a project /tmp/project-doomed
   rm -rf /tmp/project-doomed
   ls -d /tmp/project-doomed 2>&1
   ```

   Ahora leé — **no ejecutes** — el destructor clásico:

   ```bash
   # NEVER: if $DIR is unset or empty this becomes  rm -rf /
   rm -rf $DIR/
   # Correct form in any script:
   set -u
   rm -rf -- "${DIR:?DIR must be set}"/
   ```

### Preguntas — bloque 3

- **Q3.1** En el paso 1 el inodo no cambió; en el paso 2 sí. ¿Qué llamada al sistema usó cada `mv`, y qué implica eso sobre la *duración* y la atomicidad de la operación?
- **Q3.2** Tras un `mv` entre sistemas de archivos, ¿cuál de atime/mtime/ctime cambia con seguridad, y cuál conserva `mv` deliberadamente?
- **Q3.3** Un archivo de 40 GB se mueve con `mv` de `/home` a `/var` en particiones separadas y el proceso se mata a mitad de camino. ¿En qué estado quedan el origen y el destino?
- **Q3.4** En el paso 7, `rm` preguntó aunque nunca escribiste `-i`. Explicá la cadena exacta de eventos y dá las dos soluciones independientes.
- **Q3.5** ¿Por qué existe `rmdir` si `rm -r` puede borrar directorios? Nombrá una situación en la que `rmdir` sea la herramienta *más segura*.
- **Q3.6** ¿Por qué la tubería del paso 8 usa `-print0` y `xargs -0` en lugar de `find . -type f | xargs rm`?
- **Q3.7** En el fragmento de protección, ¿contra qué protegen `set -u` y `${DIR:?...}` respectivamente, y por qué sigue haciendo falta `--`?

---

## Ejercicio 4 — Globbing de archivos: simple y avanzado

El globbing lo realiza el **shell**, no el comando. Todo lo de este ejercicio es comportamiento de bash.

### Pasos

1. Construí un conjunto controlado de nombres de archivo:

   ```bash
   mkdir -p "$LAB/glob" && cd "$LAB/glob"
   touch file{1..12}.txt data.csv notes.TXT .hidden .config
   touch report-2023.log report-2024.log report-2025.log
   touch archive.tar.gz archive.tar.bz2 archive.tar.xz
   mkdir -p sub/deep && touch sub/a.c sub/deep/b.c
   ls -a
   ```

2. `*` — cualquier cadena, incluida la vacía, pero **no** un punto inicial:

   ```console
   $ echo *.txt
   file1.txt file10.txt file11.txt file12.txt file2.txt file3.txt file4.txt file5.txt file6.txt file7.txt file8.txt file9.txt
   $ echo *
   archive.tar.bz2 archive.tar.gz archive.tar.xz data.csv file1.txt ... notes.TXT report-2023.log report-2024.log report-2025.log sub
   ```

3. `?` — exactamente un carácter:

   ```console
   $ echo file?.txt
   file1.txt file2.txt file3.txt file4.txt file5.txt file6.txt file7.txt file8.txt file9.txt
   $ echo file??.txt
   file10.txt file11.txt file12.txt
   ```

4. Expresiones entre corchetes — conjunto, rango y negación:

   ```console
   $ echo file[1-3].txt
   file1.txt file2.txt file3.txt
   $ echo file[!1-3].txt
   file4.txt file5.txt file6.txt file7.txt file8.txt file9.txt
   $ echo report-20[23][45].log
   report-2024.log report-2025.log
   ```

5. Clases de caracteres POSIX — seguras respecto al locale, a diferencia de los rangos crudos:

   ```console
   $ echo *[[:upper:]]*
   notes.TXT
   $ echo [[:digit:]]*        # no filename starts with a digit
   [[:digit:]]*
   ```

6. Archivos ocultos: `*` nunca los encuentra. Tres formas de alcanzarlos:

   ```console
   $ echo .*
   . .. .config .hidden
   $ echo .[!.]*
   .config .hidden
   $ shopt -s dotglob; echo *; shopt -u dotglob
   .config .hidden archive.tar.bz2 archive.tar.gz ...
   ```

7. Globs sin coincidencias: por defecto, con `nullglob` y con `failglob`:

   ```console
   $ echo *.nomatch
   *.nomatch
   $ shopt -s nullglob; echo "[$(echo *.nomatch)]"; shopt -u nullglob
   []
   $ shopt -s failglob; echo *.nomatch; shopt -u failglob
   bash: no match: *.nomatch
   ```

8. La expansión de llaves **no** es globbing — ocurre antes y no necesita archivos:

   ```console
   $ echo {a,b,c}.iso
   a.iso b.iso c.iso
   $ echo file{1..3}.txt
   file1.txt file2.txt file3.txt
   $ echo archive.tar.{gz,bz2,xz}
   archive.tar.gz archive.tar.bz2 archive.tar.xz
   ```

   Fijate en el *orden* de esa última línea: las llaves conservan el orden que escribiste, los globs vienen ordenados.

9. Globs extendidos (`extglob`) — las "especificaciones avanzadas de comodines" del objetivo:

   ```console
   $ shopt -s extglob
   $ echo !(file*|sub)
   archive.tar.bz2 archive.tar.gz archive.tar.xz data.csv notes.TXT report-2023.log report-2024.log report-2025.log
   $ echo report-@(2024|2025).log
   report-2024.log report-2025.log
   $ echo archive.tar.?(gz|xz)
   archive.tar.gz archive.tar.xz
   $ echo file+([0-9]).txt
   file1.txt file10.txt file11.txt file12.txt file2.txt ... file9.txt
   $ shopt -u extglob
   ```

10. `globstar` para coincidencias recursivas:

    ```console
    $ shopt -s globstar
    $ echo **/*.c
    sub/a.c sub/deep/b.c
    $ shopt -u globstar
    $ echo **/*.c
    sub/a.c
    ```

11. Comillas — la diferencia entre el globbing del shell y la coincidencia de patrones del lado del programa:

    ```console
    $ find . -name *.txt
    find: paths must precede expression: 'file10.txt'
    find: possible expression starting point: '-name'

    $ find . -name '*.txt' | wc -l
    12
    ```

### Preguntas — bloque 4

- **Q4.1** ¿Qué proceso expande `*.txt` — `ls` o el shell? ¿Qué recibe realmente `ls` en su `argv`?
- **Q4.2** ¿Por qué `echo file?.txt` devuelve nueve nombres mientras que `echo file*.txt` devuelve doce?
- **Q4.3** Dá el glob para "todo archivo cuyo nombre termina en `.log` y cuyo cuarto carácter contando desde el final es un dígito distinto de 3", usando `[!...]`.
- **Q4.4** ¿Por qué `[a-z]` es un riesgo en un script que puede ejecutarse bajo un locale distinto de C, y qué lo reemplaza?
- **Q4.5** `echo .*` imprimió `.` y `..`. ¿Por qué `rm -rf .*` es un comando catastrófico, y cuál es el modismo seguro?
- **Q4.6** ¿Por qué `echo *.nomatch` imprimió el patrón mismo en lugar de nada? Nombrá las dos opciones de `shopt` que cambian esto y describí la diferencia entre ellas.
- **Q4.7** `touch file{1..12}.txt` funcionó en un directorio vacío, pero `touch file*.txt` en un directorio vacío crea un archivo llamado literalmente `file*.txt`. Explicá ambos comportamientos en términos del orden de expansión.
- **Q4.8** En el paso 11, el `find . -name *.txt` sin comillas falló. Explicá el fallo con precisión, y explicá por qué habría *tenido éxito silenciosamente con el resultado equivocado* si hubiera existido exactamente un archivo `.txt`.

---

## Ejercicio 5 — `find`: localizar archivos y actuar sobre ellos

### Pasos

1. Volvé al árbol del proyecto y agregá material con tamaños y edades conocidos:

   ```bash
   cd "$LAB"
   head -c 500      /dev/urandom > project/logs/tiny.bin
   head -c 5000     /dev/urandom > project/logs/small.bin
   head -c 2000000  /dev/urandom > project/logs/big.bin
   touch -d '10 days ago' project/logs/old.log
   touch -d '2 days ago'  project/logs/recent.log
   touch -d '30 min ago'  project/logs/fresh.log
   touch project/build/obj/tmp1.tmp project/build/obj/tmp2.tmp
   chmod 600 project/doc/architecture.txt
   chmod 755 project/src/main.c
   ```

2. Pruebas de tipo y de nombre:

   ```console
   $ find project -type f -name '*.c'
   project/src/parser.c
   project/src/util.c
   project/src/main.c
   project/src/main.c.hard

   $ find project -type d
   project
   project/src
   project/doc
   project/build
   project/build/obj
   project/logs

   $ find project -type l
   project/doc/main.c.sym

   $ find project -iname '*.TXT'
   project/doc/architecture.txt
   ```

3. Control de profundidad — `-maxdepth` / `-mindepth` deben ir **antes** de las pruebas:

   ```console
   $ find project -maxdepth 1 -type f
   $ find project -mindepth 2 -maxdepth 2 -type f | sort
   project/build/obj ...
   $ find project -type f -maxdepth 1
   find: warning: you have specified the global option -maxdepth after the argument -type, but global options are not positional...
   ```

4. Pruebas de tamaño — y la trampa del redondeo:

   ```console
   $ find project/logs -type f -size +4k
   project/logs/small.bin
   project/logs/big.bin

   $ find project/logs -type f -size +1M
   project/logs/big.bin

   $ find project/logs -type f -size -1M
   project/logs/old.log
   project/logs/recent.log
   project/logs/fresh.log

   $ find project/logs -type f -size -1000000c
   project/logs/tiny.bin
   project/logs/small.bin
   project/logs/old.log
   project/logs/recent.log
   project/logs/fresh.log

   $ find project -type f -empty | head -3
   ```

5. Pruebas de tiempo:

   ```console
   $ find project/logs -type f -name '*.log' -mtime +7
   project/logs/old.log

   $ find project/logs -type f -name '*.log' -mtime -3
   project/logs/recent.log
   project/logs/fresh.log

   $ find project/logs -type f -mmin -60
   project/logs/fresh.log
   project/logs/tiny.bin
   project/logs/small.bin
   project/logs/big.bin

   $ find project -type f -newer project/logs/recent.log -name '*.log'
   project/logs/fresh.log
   ```

6. Pruebas de permisos — los tres modos de `-perm`:

   ```console
   $ find project -type f -perm 600
   project/doc/architecture.txt

   $ find project -type f -perm -u+x
   project/src/main.c
   project/src/main.c.hard

   $ find project -type f -perm /o+w
   $ find project -type f ! -perm -o+r | head
   project/doc/architecture.txt
   ```

7. Propiedad y composición booleana:

   ```console
   $ find project -type f -user "$USER" -group "$(id -gn)" | wc -l
   $ find project -type f \( -name '*.tmp' -o -name '*.o' \) -printf '%s\t%p\n'
   1024	project/build/obj/mod1.o
   2048	project/build/obj/mod2.o
   3072	project/build/obj/mod3.o
   0	project/build/obj/tmp1.tmp
   0	project/build/obj/tmp2.tmp
   ```

8. `-exec` en ambas formas — contá las invocaciones:

   ```console
   $ find project -name '*.c' -exec sh -c 'echo "call with $# arg(s)"' _ {} \;
   call with 1 arg(s)
   call with 1 arg(s)
   call with 1 arg(s)
   call with 1 arg(s)

   $ find project -name '*.c' -exec sh -c 'echo "call with $# arg(s)"' _ {} +
   call with 4 arg(s)
   ```

9. `-exec` frente a `xargs`, de forma segura:

   ```bash
   find project -type f -name '*.o' -exec cp -v {} /tmp/ \;
   find project -type f -name '*.o' -print0 | xargs -0 -r cp -v -t /tmp/
   find project -type f -name '*.o' -print0 | xargs -0 -r -n1 -P4 sha256sum
   ```

10. Podar un subárbol — fijate en que `-prune` es una *acción* que devuelve verdadero:

    ```console
    $ find project -path project/build -prune -o -type f -print | sort
    project/doc/README.md
    project/doc/architecture.txt
    project/logs/big.bin
    ...
    project/src/util.c
    ```

    Compará con la versión ingenua y equivocada:

    ```console
    $ find project -path project/build -prune -o -type f | sort
    project/build
    project/doc/README.md
    ...
    ```

11. Borrado — y su peligro de ordenamiento:

    ```console
    $ find project -type f -name '*.tmp' -print
    project/build/obj/tmp1.tmp
    project/build/obj/tmp2.tmp
    $ find project -type f -name '*.tmp' -delete
    $ find project -type f -name '*.tmp' | wc -l
    0
    ```

    Leé, **no ejecutes**:

    ```bash
    # -delete comes FIRST: find evaluates left to right, so this deletes
    # everything it can before -name is ever consulted.
    find project -delete -name '*.tmp'
    ```

12. Enlaces simbólicos rotos y coincidencia por expresiones regulares:

    ```console
    $ ln -s /nonexistent/path project/doc/dangling.sym
    $ find project -xtype l
    project/doc/dangling.sym
    $ find project -regextype posix-extended -regex '.*/(mod[0-9]+\.o|.*\.c)$' | sort
    ```

### Preguntas — bloque 5

- **Q5.1** `-size -1M` coincidió solo con los archivos `.log` vacíos y omitió uno de 500 bytes y otro de 5000 bytes, mientras que `-size -1000000c` sí los encontró. Explicá la regla de redondeo que produce esto.
- **Q5.2** Traducí `-mtime +7` y `-mtime -3` a enunciados precisos sobre el tiempo transcurrido. ¿A dónde va la parte fraccionaria de un día?
- **Q5.3** Distinguí `-perm 600`, `-perm -600` y `-perm /600` con un archivo de ejemplo para cada uno.
- **Q5.4** En el paso 8, `\;` produjo cuatro creaciones de proceso y `+` produjo una. ¿Cuándo es `\;` *obligatorio* aunque `+` sea más rápido?
- **Q5.5** ¿Por qué hay que escapar o entrecomillar `{}` y `;` en `-exec ... \;`?
- **Q5.6** Reescribí `find project -name '*.o' | xargs rm` de modo que sea correcto para nombres de archivo con espacios *y* que no ejecute `rm` en absoluto cuando no haya coincidencias.
- **Q5.7** En el paso 10, ¿por qué hace falta `-o -type f -print` en vez de solo `-o -type f`? ¿Qué acción implícita añade `find`, y por qué `-prune` la suprime?
- **Q5.8** `-delete` implica `-depth`. ¿Por qué es necesaria esa implicación, y por qué hace que combinar `-prune` y `-delete` sea inseguro?
- **Q5.9** ¿Por qué `-maxdepth` produjo un aviso en el paso 3 pero igual funcionó? ¿Cuál es el riesgo de confiar en eso?

---

## Ejercicio 6 — `tar`: archivar con y sin compresión

### Pasos

1. Creá un archivo sin comprimir e inspeccionalo:

   ```console
   $ cd "$LAB"
   $ tar -cvf project.tar project
   project/
   project/src/
   project/src/main.c
   ...
   $ ls -l project.tar
   -rw-r--r--. 1 user user 2078720 Aug 26 11:02 project.tar

   $ tar -tvf project.tar | head -5
   drwxr-xr-x user/user         0 2026-08-26 11:01 project/
   drwxr-xr-x user/user         0 2026-08-26 10:16 project/src/
   -rwxr-xr-x user/user         0 2020-01-01 09:00 project/src/main.c
   -rw-r--r-- user/user         0 2026-08-26 10:14 project/src/parser.c
   lrwxrwxrwx user/user         0 2026-08-26 10:16 project/doc/main.c.sym -> ../src/main.c
   ```

2. Las rutas absolutas se recortan — observá el aviso:

   ```console
   $ tar -cvf /tmp/host.tar /etc/hostname
   tar: Removing leading `/' from member names
   /etc/hostname
   $ tar -tf /tmp/host.tar
   etc/hostname
   ```

3. Compará los tres compresores sobre la misma entrada:

   ```console
   $ tar -czf project.tar.gz  project
   $ tar -cjf project.tar.bz2 project
   $ tar -cJf project.tar.xz  project
   $ ls -l project.tar*
   -rw-r--r--. 1 user user 2078720 Aug 26 11:02 project.tar
   -rw-r--r--. 1 user user 2016... Aug 26 11:03 project.tar.bz2
   -rw-r--r--. 1 user user 2013... Aug 26 11:03 project.tar.gz
   -rw-r--r--. 1 user user 2010... Aug 26 11:04 project.tar.xz
   ```

   (La carga útil aquí es salida de `/dev/urandom`, que es incompresible — ese es justamente el punto de la pregunta de más abajo. Repetilo con un árbol con mucho texto para ver ratios reales.)

4. Autodetección al leer; `-a` para elegir el compresor a partir del sufijo al escribir:

   ```bash
   tar -tf project.tar.xz | head -3          # no -J needed
   tar -caf project2.tar.gz project          # -a: infer gzip from the name
   file project2.tar.gz
   ```

5. Extraé en un directorio elegido y quitá un componente inicial de la ruta:

   ```console
   $ mkdir -p /tmp/restore1 /tmp/restore2
   $ tar -xf project.tar.gz -C /tmp/restore1
   $ ls /tmp/restore1
   project

   $ tar -xf project.tar.gz -C /tmp/restore2 --strip-components=1
   $ ls /tmp/restore2
   build  doc  logs  src
   ```

6. Extraé un **único miembro**:

   ```console
   $ tar -xvf project.tar.gz -C /tmp project/doc/README.md
   project/doc/README.md
   $ cat /tmp/project/doc/README.md
   v3
   ```

7. Coincidencia de patrones sobre nombres de miembros — sé siempre explícito:

   ```console
   $ tar -tvf project.tar --wildcards 'project/src/*.c'
   -rwxr-xr-x user/user  0 2020-01-01 09:00 project/src/main.c
   -rw-r--r-- user/user  0 2026-08-26 10:14 project/src/parser.c
   -rw-r--r-- user/user  0 2026-08-26 10:14 project/src/util.c
   ```

8. Exclusiones — poné las **antes** de las rutas a las que afectan:

   ```console
   $ tar -czf project-clean.tar.gz --exclude='*.o' --exclude='logs' project
   $ tar -tf project-clean.tar.gz | grep -cE '\.o$|logs'
   0
   ```

9. Construí un archivo a partir de un resultado de `find`, con seguridad NUL:

   ```bash
   find project -type f -name '*.c' -print0 \
     | tar --null --no-recursion -T - -czf sources.tar.gz
   tar -tf sources.tar.gz
   ```

10. Verificá un archivo contra el árbol vivo:

    ```console
    $ tar -df project.tar
    $ echo "changed" >> project/doc/README.md
    $ tar -df project.tar
    project/doc/README.md: Mod time differs
    project/doc/README.md: Size differs
    $ echo $?
    1
    ```

11. Añadir y actualizar — solo en archivos **sin comprimir**:

    ```console
    $ echo "note" > extra.txt
    $ tar -rvf project.tar extra.txt
    extra.txt
    $ tar -rvf project.tar.gz extra.txt
    tar: Cannot update compressed archives
    tar: Error is not recoverable: exiting now
    ```

12. Permisos al extraer, como usuario no root:

    ```console
    $ umask
    0022
    $ chmod 777 project/logs/fresh.log
    $ tar -cf perm.tar project/logs/fresh.log
    $ mkdir -p /tmp/pt && tar -xf perm.tar -C /tmp/pt
    $ stat -c %a /tmp/pt/project/logs/fresh.log
    755
    $ rm -rf /tmp/pt && mkdir -p /tmp/pt
    $ tar -xpf perm.tar -C /tmp/pt
    $ stat -c %a /tmp/pt/project/logs/fresh.log
    777
    ```

### Preguntas — bloque 6

- **Q6.1** `tar -czf` y `tar -zcf` funcionan, pero `tar -cfz project.tar.gz project` no. ¿Por qué? ¿Qué tiene de especial `-f`?
- **Q6.2** ¿Por qué `tar` recorta la `/` inicial, y cuál es el escenario de seguridad que lo motivó? ¿Qué opción desactiva ese recorte, y por qué nunca deberías usarla con un archivo no confiable?
- **Q6.3** Los tres archivos comprimidos del paso 3 tenían casi el mismo tamaño. ¿Qué propiedad de la entrada lo explica, y qué esperarías para un árbol de código fuente y logs? Ordená gzip/bzip2/xz por ratio, velocidad de compresión y velocidad de descompresión.
- **Q6.4** Tenés `app-1.4.2/` dentro de `app.tar.gz` pero querés su contenido directamente en `/opt/app`. Escribí el comando `tar` único.
- **Q6.5** ¿Por qué `-r` falla en `project.tar.gz` pero funciona en `project.tar`? ¿Cuál es la diferencia estructural entre ambos archivos?
- **Q6.6** En el paso 12, extraer sin `-p` dio modo `755` en lugar de `777`. ¿Qué aplicó la máscara, y en qué difiere el comportamiento por defecto cuando extrae `root`?
- **Q6.7** En el paso 9, ¿por qué hacen falta `--null` **y** `--no-recursion`?
- **Q6.8** Con solo `project.tar.gz`, listá todos los miembros mayores de 1 MB sin extraer nada.

---

## Ejercicio 7 — `cpio`

`cpio` lee su lista de archivos de **stdin** y escribe el archivo en **stdout**. Ese es todo el diseño, y todo lo demás se deriva de ahí.

### Pasos

1. Modo copy-out (`-o`) — crear un archivo:

   ```console
   $ cd "$LAB"
   $ find project -depth -print | cpio -o -H newc > project.cpio
   4063 blocks
   $ ls -l project.cpio
   -rw-r--r--. 1 user user 2080256 Aug 26 11:20 project.cpio
   $ file project.cpio
   project.cpio: ASCII cpio archive (SVR4 with no CRC)
   ```

2. Listá el contenido (`-t`), de forma verbosa:

   ```console
   $ cpio -itv < project.cpio | head -5
   -rwxr-xr-x   2 user     user            0 Jan  1  2020 project/src/main.c
   -rw-r--r--   1 user     user            0 Aug 26 10:14 project/src/parser.c
   -rw-r--r--   1 user     user            0 Aug 26 10:14 project/src/util.c
   drwxr-xr-x   2 user     user            0 Aug 26 10:16 project/src
   lrwxrwxrwx   1 user     user           13 Aug 26 10:16 project/doc/main.c.sym -> ../src/main.c
   ```

3. Modo copy-in (`-i`) — extraé, **sin** `-d` la primera vez, para ver el fallo:

   ```console
   $ mkdir -p /tmp/cpio-nod && cd /tmp/cpio-nod
   $ cpio -i < "$LAB/project.cpio"
   cpio: project/src/main.c: Cannot open: No such file or directory
   cpio: project/src/parser.c: Cannot open: No such file or directory
   ...
   4063 blocks
   ```

4. Extraé correctamente:

   ```console
   $ mkdir -p /tmp/cpio-x && cd /tmp/cpio-x
   $ cpio -idmv < "$LAB/project.cpio" 2>&1 | tail -3
   project/logs
   project
   4063 blocks
   $ find . -type f | wc -l
   ```

5. Extraé de forma selectiva, con un patrón:

   ```console
   $ mkdir -p /tmp/cpio-sel && cd /tmp/cpio-sel
   $ cpio -idmv 'project/src/*' < "$LAB/project.cpio"
   project/src/main.c
   project/src/parser.c
   project/src/util.c
   project/src/main.c.hard
   4063 blocks
   ```

6. Comportamiento ante sobreescritura — `cpio -i` se niega a reemplazar un archivo **más nuevo** salvo que se lo indiques:

   ```console
   $ cd /tmp/cpio-x
   $ touch project/src/util.c
   $ cpio -idm < "$LAB/project.cpio" 2>&1 | grep util
   cpio: project/src/util.c not created: newer or same age version exists
   $ cpio -idmu < "$LAB/project.cpio" >/dev/null 2>&1
   $ stat -c %y project/src/util.c
   ```

7. Modo pass-through (`-p`) — copiar un árbol sin crear nunca un archivo:

   ```console
   $ cd "$LAB"
   $ mkdir -p /tmp/passthru
   $ find project -depth -print0 | cpio --null -pdmv /tmp/passthru 2>&1 | tail -2
   /tmp/passthru/project
   4063 blocks
   $ diff -r project /tmp/passthru/project && echo IDENTICAL
   IDENTICAL
   ```

8. Formatos — `newc` es el que importa en Linux moderno:

   ```bash
   find project -depth -print | cpio -o -H crc  > project-crc.cpio
   find project -depth -print | cpio -o -H odc  > project-odc.cpio
   file project-crc.cpio project-odc.cpio
   ```

9. Contexto del mundo real — un `initramfs` **es** un archivo cpio `newc` comprimido:

   ```console
   $ mkdir -p /tmp/initrd-x && cd /tmp/initrd-x
   $ ls -l /boot/initramfs-$(uname -r).img
   $ file /boot/initramfs-$(uname -r).img
   /boot/initramfs-6.15.4-200.fc44.x86_64.img: ASCII cpio archive (SVR4 with no CRC)
   ```

   El segmento inicial es un early-cpio sin comprimir (microcódigo de CPU); la imagen raíz comprimida viene después. En Fedora/RHEL, `lsinitrd` lee ambos por vos:

   ```bash
   lsinitrd /boot/initramfs-$(uname -r).img | head -20
   ```

10. Limpieza:

    ```bash
    cd "$LAB"; rm -rf /tmp/cpio-nod /tmp/cpio-x /tmp/cpio-sel /tmp/passthru /tmp/initrd-x
    ```

### Preguntas — bloque 7

- **Q7.1** Nombrá los tres modos de operación de `cpio` y la opción que selecciona cada uno. ¿Cuáles dos implican un flujo de archivo, y cuál no?
- **Q7.2** El paso 3 falló con "Cannot open: No such file or directory" para *archivos regulares*. ¿Qué faltaba en realidad, y qué opción lo arregla?
- **Q7.3** ¿Por qué el `find` del paso 1 usa `-depth`? ¿Qué se rompe al restaurar si lo omitís?
- **Q7.4** `cpio` imprimió `4063 blocks`. ¿Cuál es el tamaño de bloque, en qué flujo se escribió ese mensaje, y por qué importa eso para `cpio -o > archive`?
- **Q7.5** En el paso 6, `cpio` omitió un archivo en silencio. Compará este comportamiento por defecto con el de extracción de `tar`, y nombrá la opción de `cpio` que restaura el comportamiento estilo tar.
- **Q7.6** Escribí el equivalente con `tar` de `find project -depth -print0 | cpio --null -pdmv /tmp/passthru`, usando una tubería `tar | tar`.
- **Q7.7** ¿Por qué es importante `--no-absolute-filenames` al extraer un archivo cpio que no creaste vos?
- **Q7.8** Dá una razón concreta por la que `cpio` sigue usándose en Linux en 2026 pese a que `tar` es más ergonómico.

---

## Ejercicio 8 — `dd`: copia a nivel de bloque

> **Peligro.** `dd` no tiene confirmación ni deshacer. Cada `of=` de este ejercicio es un archivo regular dentro de tu directorio de laboratorio. Nunca escribas aquí un nodo de dispositivo.

### Pasos

1. Creá una imagen de 8 MiB de ceros:

   ```console
   $ cd "$LAB"
   $ dd if=/dev/zero of=disk.img bs=1M count=8 status=progress
   8+0 records in
   8+0 records out
   8388608 bytes (8.4 MB, 8.0 MiB) copied, 0.00612 s, 1.4 GB/s
   ```

2. Leé la línea de "records" con atención, luego creá un archivo **disperso** (sparse) y compará tamaño aparente y tamaño asignado:

   ```console
   $ dd if=/dev/zero of=sparse.img bs=1 count=0 seek=100M
   0+0 records in
   0+0 records out
   0 bytes copied, 0.000108 s, 0.0 kB/s

   $ ls -l sparse.img
   -rw-r--r--. 1 user user 104857600 Aug 26 11:40 sparse.img
   $ du -h sparse.img
   0	sparse.img
   $ du -h --apparent-size sparse.img
   100M	sparse.img
   ```

3. Parcheá bytes **en el sitio** — `seek` + `conv=notrunc`:

   ```console
   $ printf 'LPIC' | dd of=disk.img bs=1 seek=512 conv=notrunc
   4+0 records in
   4+0 records out
   4 bytes copied, 8.4e-05 s, 47.6 kB/s

   $ ls -l disk.img
   -rw-r--r--. 1 user user 8388608 Aug 26 11:42 disk.img
   ```

4. Ahora repetilo **sin** `conv=notrunc` sobre una copia, y mirá cómo se destruye el archivo:

   ```console
   $ cp disk.img disk2.img
   $ printf 'LPIC' | dd of=disk2.img bs=1 seek=512
   4+0 records in
   4+0 records out
   4 bytes copied, 9.1e-05 s, 44.0 kB/s
   $ ls -l disk2.img
   -rw-r--r--. 1 user user 516 Aug 26 11:43 disk2.img
   ```

5. Leé de vuelta la región parcheada — `skip` es la contraparte de *entrada* de `seek`:

   ```console
   $ dd if=disk.img bs=1 skip=512 count=4 status=none
   LPIC
   $ xxd -s 512 -l 16 disk.img
   00000200: 4c50 4943 0000 0000 0000 0000 0000 0000  LPIC............
   ```

6. Tomá una copia de seguridad estilo "sector de arranque" de 512 bytes y restaurala:

   ```bash
   dd if=disk.img of=sector0.bin bs=512 count=1
   ls -l sector0.bin
   dd if=sector0.bin of=disk.img bs=512 count=1 conv=notrunc
   ```

7. `count` cuenta **llamadas a read()**, no bytes — la trampa de la tubería:

   ```console
   $ head -c 10000 /dev/urandom | dd of=part.bin bs=4096 count=2
   0+2 records in
   0+2 records out
   10000 bytes (10 kB, 9.8 KiB) copied, 0.00021 s, 47.6 MB/s
   ```

   Tu línea exacta de `records in` variará entre ejecuciones. Ahora la forma determinista:

   ```console
   $ head -c 10000 /dev/urandom | dd of=part.bin bs=4096 count=2 iflag=fullblock
   2+0 records in
   2+0 records out
   8192 bytes (8.2 kB, 8.0 KiB) copied, 0.00019 s, 43.1 MB/s
   ```

8. Tolerancia a errores para medios que fallan (simulada aquí — limitate a leer la semántica):

   ```bash
   # On a dying disk: keep going past read errors, and pad each failed
   # block with NULs so every subsequent byte keeps its correct offset.
   # dd if=/dev/sdX of=rescue.img bs=4096 conv=noerror,sync status=progress
   ```

9. Borrado y verificación (solo sobre la imagen del laboratorio):

   ```console
   $ dd if=/dev/zero of=disk.img bs=1M count=8 conv=notrunc status=none
   $ sha256sum disk.img
   0dea6e9dc6bbfa7d... disk.img
   $ dd if=/dev/zero bs=1M count=8 status=none | sha256sum
   0dea6e9dc6bbfa7d... -
   ```

10. Comparación de rendimiento — `bs` es la mayor palanca de rendimiento:

    ```console
    $ dd if=/dev/zero of=perf.img bs=512  count=20000 status=none; sync
    $ dd if=/dev/zero of=perf.img bs=1M   count=10    status=none; sync
    ```

    Repetí cada uno con `status=progress` (quitando `status=none`) y compará las tasas informadas.

11. Limpieza:

    ```bash
    rm -f disk.img disk2.img sparse.img part.bin sector0.bin perf.img
    ```

### Preguntas — bloque 8

- **Q8.1** Descifrá `8+0 records in`. ¿Qué significaría `0+2`, y qué significaría `12+1`?
- **Q8.2** En el paso 4, un archivo de 8 MiB pasó a tener 516 bytes. Explicá exactamente qué hizo `dd` y por qué `conv=notrunc` lo evita.
- **Q8.3** Distinguí `skip=` de `seek=`. ¿A qué lado se aplica cada uno, y en qué unidad se cuentan?
- **Q8.4** `ls -l` dijo 100 MB y `du` dijo 0 para `sparse.img`. ¿Qué se almacena en el disco, y qué pasa si hacés `tar -cf` de ese archivo y lo extraés en otro sitio?
- **Q8.5** ¿Por qué se combina `conv=sync` con `conv=noerror` al rescatar un disco que falla? ¿Qué le pasaría a una imagen de sistema de archivos si usaras `noerror` solo?
- **Q8.6** ¿Por qué `bs=4096 count=2` copió 10000 bytes desde una tubería? Dá la opción que lo hace determinista y explicá el mecanismo.
- **Q8.7** Escribí el comando para respaldar el primer sector de `/dev/sda` en `~/mbr.bin`, y enunciá con precisión qué estructuras viven en esos 512 bytes en un disco particionado con MBR.
- **Q8.8** `dd if=/dev/zero of=/dev/sda bs=1M count=1` y `dd if=/dev/zero of=/dev/sda1 bs=1M count=1` — describí el daño distinto que causa cada uno.

---

## Ejercicio 9 — Herramientas de compresión e identificación de archivos

### Pasos

1. Creá un archivo compresible (texto repetitivo, a diferencia de `/dev/urandom`):

   ```bash
   cd "$LAB"
   for i in $(seq 1 20000); do
     echo "2026-08-26 10:00:00 INFO  request id=$i status=200 path=/api/v1/health"
   done > access.log
   ls -l access.log
   ```

2. `gzip` reemplaza el original por defecto — `-k` lo conserva:

   ```console
   $ cp access.log t.log && gzip t.log && ls t.log*
   t.log.gz
   $ gzip -k access.log && ls -l access.log access.log.gz
   -rw-r--r--. 1 user user 1477790 Aug 26 12:01 access.log
   -rw-r--r--. 1 user user   85403 Aug 26 12:02 access.log.gz
   ```

3. Compará los tres compresores en nivel por defecto y máximo:

   ```bash
   for tool in gzip bzip2 xz; do
     cp access.log "c-$tool"
     /usr/bin/time -f "$tool  %e s" $tool -9 "c-$tool"
   done
   ls -l c-*
   ```

   ```console
   -rw-r--r--. 1 user user  70841 Aug 26 12:05 c-bzip2.bz2
   -rw-r--r--. 1 user user  84925 Aug 26 12:05 c-gzip.gz
   -rw-r--r--. 1 user user  13996 Aug 26 12:05 c-xz.xz
   ```

4. Inspeccioná un miembro gzip sin descomprimirlo:

   ```console
   $ gzip -l access.log.gz
            compressed        uncompressed  ratio uncompressed_name
                 85403             1477790  94.2% access.log
   ```

5. Leé contenido comprimido sin descomprimirlo en disco:

   ```bash
   zcat  access.log.gz | head -2
   zgrep 'id=17777' access.log.gz
   xzcat c-xz.xz | wc -l
   bzcat c-bzip2.bz2 | tail -1
   zless access.log.gz     # q to quit
   ```

6. Descomprimí, con tres formas equivalentes cada una:

   ```bash
   gunzip  -k access.log.gz   ;  gzip  -dk access.log.gz
   bunzip2 -k c-bzip2.bz2     ;  bzip2 -dk c-bzip2.bz2
   unxz    -k c-xz.xz         ;  xz    -dk c-xz.xz
   ```

7. Identificá archivos por **contenido**, no por nombre — para eso está `file`:

   ```console
   $ file access.log access.log.gz c-bzip2.bz2 c-xz.xz project.tar project.tar.gz project.cpio project/src
   access.log:      ASCII text
   access.log.gz:   gzip compressed data, was "access.log", last modified: ..., from Unix, original size modulo 2^32 1477790
   c-bzip2.bz2:     bzip2 compressed data, block size = 900k
   c-xz.xz:         XZ compressed data, checksum CRC64
   project.tar:     POSIX tar archive (GNU)
   project.tar.gz:  gzip compressed data, from Unix, original size modulo 2^32 2078720
   project.cpio:    ASCII cpio archive (SVR4 with no CRC)
   project/src:     directory
   ```

8. Demostrá que la extensión es irrelevante:

   ```console
   $ cp access.log.gz misleading.txt
   $ file misleading.txt
   misleading.txt: gzip compressed data, was "access.log", ...
   $ file -b --mime-type misleading.txt
   application/gzip
   ```

9. `file` y los enlaces simbólicos:

   ```console
   $ file project/doc/main.c.sym
   project/doc/main.c.sym: symbolic link to ../src/main.c
   $ file -L project/doc/main.c.sym
   project/doc/main.c.sym: empty
   $ file project/doc/dangling.sym
   project/doc/dangling.sym: broken symbolic link to /nonexistent/path
   ```

10. Integridad, que es el objetivo de todo esto:

    ```console
    $ sha256sum access.log project.tar.gz > SHA256SUMS
    $ sha256sum -c SHA256SUMS
    access.log: OK
    project.tar.gz: OK
    $ printf '\0' >> project.tar.gz
    $ sha256sum -c SHA256SUMS
    access.log: OK
    project.tar.gz: FAILED
    sha256sum: WARNING: 1 computed checksum did NOT match
    $ echo $?
    1
    ```

### Preguntas — bloque 9

- **Q9.1** ¿Por qué `gzip access.log` no deja ningún `access.log` detrás, mientras que `gzip -c access.log > access.log.gz` sí? ¿Cuál es más seguro en un script y por qué?
- **Q9.2** `gzip`, `bzip2` y `xz` comprimen un *único flujo*. ¿Qué implica eso para `.tar.gz` frente a un archivo `.zip`, en términos de extraer un solo miembro?
- **Q9.3** Ordená gzip/bzip2/xz por ratio de compresión, coste de CPU al comprimir y coste de CPU al descomprimir, y enunciá la regla operativa que se deriva (cuál para una rotación nocturna de logs, cuál para un tarball de distribución de una versión).
- **Q9.4** `gzip -l` informó "uncompressed 1477790". ¿Cuál es la limitación documentada de ese número para archivos muy grandes, y qué sugiere al respecto la salida de `file`?
- **Q9.5** Nombrá los equivalentes de `zcat` para bzip2 y xz, y explicá por qué existe `zgrep` en lugar de usar simplemente `gunzip -c | grep`.
- **Q9.6** En el paso 9, `file` dijo `symbolic link to ...` y `file -L` dijo `empty`. Explicá ambas respuestas.
- **Q9.7** `file` identificó correctamente un flujo gzip llamado `misleading.txt`. ¿Qué mecanismo usa, y dónde vive su base de datos?
- **Q9.8** Tras añadir un único byte NUL, `sha256sum -c` falló pero `tar -tzf project.tar.gz` puede seguir listando los miembros. Explicalo, y decí qué comprobación pondrías en un script de verificación de copias de seguridad.

---

## Ejercicio 10 — Cierre: una copia de seguridad nocturna fallida

Un trabajo de cron produjo un archivo nocturno. Restauralo, verificalo y limpiá — usando solo las herramientas de este objetivo.

### Pasos

1. Construí el escenario:

   ```bash
   cd "$LAB"
   mkdir -p nightly && cd nightly
   mkdir -p app/{bin,conf,data,cache,logs}
   printf '#!/bin/sh\necho running\n' > app/bin/run.sh && chmod 750 app/bin/run.sh
   printf 'listen=0.0.0.0:8080\nworkers=4\n' > app/conf/app.conf && chmod 640 app/conf/app.conf
   head -c 300000 /dev/urandom > app/data/store.db
   head -c 900000 /dev/urandom > app/cache/blob1.cache
   head -c 900000 /dev/urandom > app/cache/blob2.cache
   for i in 1 2 3 4 5; do echo "line $i" > "app/logs/app-$i.log"; done
   touch -d '40 days ago' app/logs/app-1.log app/logs/app-2.log
   ln -s ../conf/app.conf app/bin/app.conf
   cd "$LAB/nightly"
   ```

2. **Tarea A** — producí `backup.tar.gz` de `app/` que excluya el directorio `cache/` y todo archivo `*.cache`, preserve el enlace simbólico como enlace simbólico y no contenga `/` inicial. Después demostrá que las exclusiones funcionaron.

   ```bash
   tar -czf backup.tar.gz --exclude='cache' --exclude='*.cache' app
   tar -tvf backup.tar.gz
   tar -tf backup.tar.gz | grep -c cache        # expect 0
   ```

3. **Tarea B** — registrá un manifiesto de sumas de verificación del archivo y de cada archivo que debería contener:

   ```bash
   sha256sum backup.tar.gz > backup.sha256
   find app -type f ! -path '*/cache/*' ! -name '*.cache' -print0 \
     | sort -z | xargs -0 sha256sum > files.sha256
   wc -l files.sha256
   ```

4. **Tarea C** — restaurá en una ubicación limpia y compará con el original:

   ```bash
   mkdir -p /tmp/verify
   sha256sum -c backup.sha256
   tar -xpzf backup.tar.gz -C /tmp/verify
   diff -r --no-dereference app /tmp/verify/app
   ```

   El `diff` informará el directorio `cache` como presente solo en el lado izquierdo. Eso es lo esperado — todo lo demás debe ser idéntico.

5. **Tarea D** — verificá que los modos sobrevivieron al viaje de ida y vuelta:

   ```console
   $ stat -c '%a %n' app/bin/run.sh app/conf/app.conf
   750 app/bin/run.sh
   640 app/conf/app.conf
   $ stat -c '%a %n' /tmp/verify/app/bin/run.sh /tmp/verify/app/conf/app.conf
   750 /tmp/verify/app/bin/run.sh
   640 /tmp/verify/app/conf/app.conf
   ```

6. **Tarea E** — rotá: comprimí todo log de más de 30 días, borrá la caché y dejá el resto intacto. Una pasada para cada cosa, segura ante NUL:

   ```bash
   find app/logs -type f -name '*.log' -mtime +30 -print0 | xargs -0 -r gzip -v
   find app -type f -name '*.cache' -delete
   find app -type d -empty -print
   ls -l app/logs
   ```

7. **Tarea F** — el archivo se corrompe en tránsito. Detectalo antes de perder tiempo con la extracción:

   ```console
   $ cp backup.tar.gz shipped.tar.gz
   $ dd if=/dev/urandom of=shipped.tar.gz bs=1 seek=500 count=32 conv=notrunc status=none
   $ gzip -t shipped.tar.gz
   gzip: shipped.tar.gz: invalid compressed data--crc error
   $ echo $?
   1
   $ sha256sum -c backup.sha256 2>/dev/null; echo "manifest exit=$?"
   ```

8. Limpieza de todo el laboratorio:

   ```bash
   cd ~
   rm -rf "$LAB" /tmp/verify /tmp/restore1 /tmp/restore2 /tmp/dest \
          /tmp/project-a /tmp/project-L /tmp/src-copy /tmp/project \
          /tmp/README.md* /tmp/plain.c /tmp/preserved.c /tmp/target.md* \
          /tmp/host.tar /tmp/mod*.o
   ```

### Preguntas — bloque 10

- **Q10.1** En la Tarea A, ¿por qué se dan **ambos** `--exclude='cache'` y `--exclude='*.cache'`? ¿Habría bastado con cualquiera de los dos aquí?
- **Q10.2** La Tarea C usó `diff -r --no-dereference`. ¿Qué habría hecho un `diff -r` simple con `app/bin/app.conf`, y por qué ocultaría una regresión real?
- **Q10.3** El primer comando de la Tarea E usa `xargs -0 -r`. Explicá qué evita `-r` una noche en la que ningún log supera los 30 días.
- **Q10.4** `gzip -t` detectó la corrupción en la Tarea F. ¿Qué comprueba exactamente, y por qué vale la pena conservar además un manifiesto `sha256sum`?
- **Q10.5** La rotación de la Tarea E ejecutó `gzip` sobre `app-1.log`, produciendo `app-1.log.gz`. Si el mismo trabajo de cron se ejecuta otra vez a la noche siguiente, ¿qué pasa, y cómo hacés la rotación idempotente?
- **Q10.6** Reescribí la Tarea A usando `cpio` en lugar de `tar`, manteniendo las mismas exclusiones. ¿Cuál de los dos es más fácil de expresar, y por qué?

---

<details>
<summary><strong>Respuestas — clic para expandir</strong></summary>

### Bloque 1 — metadatos, enlaces, marcas de tiempo

**A1.1** `main.c.hard` comparte el inodo. `ls -li` imprime el número de inodo en la primera columna: `main.c` y `main.c.hard` muestran ambos `1179651`, mientras que `main.c.sym` tiene su propio inodo. La tercera columna de `ls -l` es el **contador de enlaces** (`st_nlink`) — el número de entradas de directorio que apuntan a ese inodo. Vale `2` para ambos nombres enlazados duro. Un enlace duro no es una copia ni un puntero: ambos nombres son referencias iguales y de primera clase a un mismo inodo, y los datos se liberan solo cuando el contador de enlaces llega a 0 *y* ningún proceso mantiene el archivo abierto. Los enlaces simbólicos no incrementan el contador de enlaces del destino, razón por la cual borrar `main.c` dejaría `main.c.sym` colgando pero `main.c.hard` perfectamente intacto. (Los directorios muestran siempre al menos 2: su propio nombre más su entrada `.`, más uno por cada `..` de un subdirectorio.)

**A1.2** El "tamaño" de un enlace simbólico es la longitud en bytes de la **cadena de la ruta destino** que almacena. `../src/main.c` tiene 13 caracteres, así que el tamaño es 13. No dice nada sobre el archivo destino. En la mayoría de los sistemas de archivos Linux, los destinos suficientemente cortos se guardan en línea dentro del propio inodo ("fast symlinks"), por lo que `stat` también suele informar `Blocks: 0` para ellos.

**A1.3**
- `Size: 0` — la longitud lógica del archivo en bytes (`st_size`). `touch` crea un archivo sin contenido.
- `Blocks: 0` — el número de unidades de **512 bytes** realmente asignadas (`st_blocks`). Un archivo vacío necesita un inodo pero ningún bloque de datos, así que cero. Este campo es el que informa `du`, y es la razón por la que `du` y `ls -l` no coinciden en archivos dispersos ni en archivos con tail-packing o compresión.
- `IO Block: 4096` — el tamaño de transferencia de E/S preferido por el sistema de archivos (`st_blksize`), una pista para que las aplicaciones elijan el tamaño de búfer. No es la unidad de asignación ni una propiedad de este archivo.

**A1.4** ctime es la **hora de cambio del inodo**, y la mantiene el kernel, no el espacio de usuario. Cualquier modificación de los metadatos del inodo — modo, propietario, contador de enlaces, e *incluso el acto de fijar atime/mtime* — actualiza ctime a la hora actual. Deliberadamente no hay ninguna API para retrodatarlo, precisamente para que pueda servir como evidencia de manipulación: un intruso puede falsificar mtime con `touch -d`, pero no ctime. (La única forma de alterarlo es cambiar el reloj del sistema o escribir en el dispositivo crudo.) Notá que `Birth:` (hora de creación, `statx`) es una cuarta marca de tiempo, disponible en ext4/XFS/Btrfs y tampoco modificable.

**A1.5** No — es **expansión de llaves**, un mecanismo del shell distinto y anterior. La expansión de llaves es puramente textual: no mira el sistema de archivos ni requiere que los nombres existan, que es exactamente por qué funciona para `mkdir`. El globbing (`*`, `?`, `[...]`) coincide con nombres *existentes*. Ejecutar el mismo `mkdir -p` otra vez es un no-op exitoso: `-p` suprime el error "File exists" para los componentes existentes y crea solo lo que falta, además de crear los padres intermedios. Esa combinación es lo que hace de `mkdir -p` la forma idempotente usada en scripts.

**A1.6** `ls project` lista el *contenido* de `project`. `ls -d project/*/` lista las **entradas de directorio en sí** sin descender en ellas; `-d` es lo que impide que `ls` expanda un argumento de directorio en su contenido. La `/` final del glob restringe la coincidencia a directorios (y a enlaces simbólicos que resuelven a directorios), porque un patrón terminado en `/` solo coincide con nombres a los que puede seguir una barra.

---

### Bloque 2 — `cp`

**A2.1** La regla: **si el último argumento es un directorio existente, `cp` copia los orígenes *dentro* de él, conservando sus nombres base. En caso contrario, el último argumento es el nombre nuevo de la copia.** En el paso 3 `/tmp/src-copy` no existía, así que se convirtió en una copia de `src`. En el paso 4 sí existía, así que `src` se copió *dentro* como `/tmp/src-copy/src`. Este es el error más habitual con `cp -r`, y también explica por qué `cp file1 file2 file3 dest` exige que `dest` sea un directorio.

**A2.2** No, el paso 4 no fue idempotente — la segunda ejecución cambió el resultado. Dos formulaciones idempotentes:
- `cp -aT project/src /tmp/src-copy` — `-T`/`--no-target-directory` fuerza a tratar el destino como un nombre, nunca como un contenedor, de modo que el comando significa lo mismo exista o no el destino.
- `mkdir -p /tmp/src-copy && cp -a project/src/. /tmp/src-copy/` — copiar el *contenido*.

`rsync -a project/src/ /tmp/src-copy/` es la respuesta de producción por la misma razón (notá que en `rsync`, a diferencia de `cp`, es la barra final del *origen* la que selecciona solo el contenido).

**A2.3** `cp -a` es exactamente `cp -dR --preserve=all`, donde `-d` es a su vez `--no-dereference --preserve=links`. Desglosado:
- `-R` — descender recursivamente en los directorios.
- `--no-dereference` — copiar un enlace simbólico **como enlace simbólico** en lugar de copiar aquello a lo que apunta. Esto es lo que preservó `main.c.sym`.
- `--preserve=links` — reproducir como enlaces duros los enlaces duros entre archivos copiados.
- `--preserve=all` — modo, propiedad, marcas de tiempo, más contexto, enlaces y xattrs donde estén soportados.

**A2.4** Lo provocó `-L` (`--dereference`): sigue todo enlace simbólico y copia el *contenido del destino* al nombre del enlace, y además implica que los nombres enlazados duro se copian de forma independiente en vez de volver a enlazarse. Para un árbol grande el coste en espacio es real — un árbol de origen con un archivo de 2 GB enlazado duro bajo cuatro nombres ocupa 2 GB en el origen y 8 GB después de `cp -rL`, y cada enlace simbólico a un directorio grande se materializa como una copia completa. Usá `-a` para copias de seguridad y `-L` solo cuando querés deliberadamente una instantánea autocontenida y sin enlaces.

**A2.5** Falla `--preserve=ownership`: solo un proceso con `CAP_CHOWN` (en la práctica, root) puede ceder un archivo a otro usuario. `cp -p` imprime un diagnóstico como `cp: failed to preserve ownership for '/tmp/x': Operation not permitted` y termina con estado distinto de cero, **pero no borra la copia** — los datos y, donde esté permitido, el modo y las marcas de tiempo siguen ahí. Por eso restaurar un árbol `/etc` propiedad de root como usuario sin privilegios produce un árbol completo pero con propiedad incorrecta, y por eso la extracción con `tar` como no root usa por defecto `--no-same-owner`.

**A2.6**
- `cp -i` — **interactivo**: pregunta antes de cada sobreescritura. Basado en existencia, requiere una persona.
- `cp -n` — **no-clobber**: omite en silencio si el destino existe. Basado en existencia, apto para scripts. (Notá que `-n` e `-i` son mutuamente excluyentes; gana el último de la línea de comandos.)
- `cp -u` — **update**: copia solo si el origen es más nuevo que el destino, o si el destino no existe. Basado en **marca de tiempo**.

Ninguno de los tres tiene en cuenta el contenido: `cp -u` omitirá un archivo cuyo contenido difiere pero cuya mtime es anterior o igual, y copiará un archivo idéntico byte a byte cuya mtime es simplemente más nueva. La copia consciente del contenido es `rsync -c` (suma de verificación) o una tubería basada en `sha256sum`. Los coreutils modernos también ofrecen `cp --update=<policy>` para un control más fino.

---

### Bloque 3 — `mv`, `rm`, nombres hostiles

**A3.1** El paso 1 usó `rename(2)`: una única operación de metadatos dentro de un mismo sistema de archivos que solo reescribe entradas de directorio. El inodo queda intacto, así que es **instantánea sin importar el tamaño del archivo y atómica** — en ningún instante un observador concurrente ve el archivo ausente o a medias. El paso 2 no pudo usar `rename(2)` (falla con `EXDEV`, "Invalid cross-device link"), así que `mv` recurrió a copiar y luego desenlazar: leer cada byte hacia un inodo nuevo del sistema de archivos destino, y después borrar el origen. Eso lleva un tiempo proporcional al tamaño y **no es atómico**.

**A3.2** **ctime** cambia obligatoriamente — se creó un inodo nuevo, así que su hora de cambio es el momento de la creación. `mv` conserva deliberadamente **mtime** (y atime, modo y propiedad cuando está permitido), porque la intención misma de `mv` es que el archivo sea "el mismo archivo en un lugar nuevo". Esta es una diferencia genuina respecto de `cp` sin `-p`. También es por eso que una mtime intacta tras un movimiento entre sistemas de archivos no prueba que no hubo copia; solo el número de inodo y ctime te lo dicen.

**A3.3** El archivo de origen en `/home` sigue presente e intacto — `mv` desenlaza el origen solo después de que la copia termina con éxito. El destino en `/var` es un **archivo parcial y truncado** con lo que se haya escrito antes de la muerte del proceso. No se perdió nada, pero el destino está corrupto en silencio y la misma comprobación de tamaño que hace un script ingenuo (`test -f`) va a pasar. El patrón seguro para movimientos grandes entre sistemas de archivos es copiar → verificar (suma de verificación o `cmp`) → borrar el origen, o `rsync --remove-source-files`, que hace exactamente eso.

**A3.4** La cadena: el shell expandió `*`, la expansión viene ordenada, y en la colación tipo C/POSIX un `-` inicial se ordena antes que las letras, así que el archivo llamado `-i` quedó **primero** en la lista de argumentos de `rm`. `rm` interpreta los argumentos que empiezan con guion como opciones, así que vio `-i` como la opción interactiva y no como un nombre de archivo. Las dos soluciones independientes:
- **`--`** — el marcador POSIX de fin de opciones: `rm -- *`. Todo lo que va después de `--` es un nombre de archivo, aunque empiece con guion.
- **Un prefijo de ruta** — `rm ./*` o `rm ./-i`. `./-i` ya no empieza con `-`, así que el análisis de opciones nunca se dispara.

Vale la pena tener ambos como reflejo; `--` es el que también protege frente a un archivo llamado `--help` o `-rf`.

**A3.5** `rmdir` falla ruidosamente (`Directory not empty`) en lugar de destruir datos, así que codifica la *afirmación* "este directorio ya debería estar vacío". Eso lo convierte en la herramienta más segura cuando la vacuidad forma parte del contrato — por ejemplo, un script de limpieza que elimina un directorio de cola solo tras confirmar que todos los trabajos se drenaron, o eliminar un punto de montaje que creés desmontado. `rm -rf mountpoint` sobre un directorio que *creías* desmontado borra el contenido del sistema de archivos montado; `rmdir mountpoint` no puede. Además usa la llamada al sistema dedicada `rmdir(2)` en vez de un recorrido recursivo.

**A3.6** Porque la interfaz por defecto de `find`/`xargs` se delimita con espacios en blanco y saltos de línea, que son caracteres legales en un nombre de archivo. `find . -type f | xargs rm` convertiría `two words` en dos argumentos (`two` y `words`) y partiría `line\nbreak` en dos líneas, borrando o fallando sobre los nombres equivocados — y un nombre con un carácter de comilla puede hacer que `xargs` desbarate todavía más las cosas. `-print0` emite registros terminados en NUL y `xargs -0` los lee; NUL (`\0`) y `/` son los dos únicos bytes que no pueden aparecer en un nombre de archivo, así que NUL es el único delimitador sin ambigüedad. La forma equivalente con una sola herramienta es `find . -type f -delete` o `find . -type f -exec rm {} +`, que nunca serializan los nombres.

**A3.7**
- `set -u` hace que el shell aborte con un error cuando se referencia una variable **no definida**, de modo que `rm -rf $DIR/` se vuelve un error fatal en lugar de `rm -rf /`.
- `${DIR:?DIR must be set}` además cubre el caso que `set -u` no atrapa: una variable definida pero **vacía** (`DIR=""`). La forma `:?` da error si está sin definir *o* nula, y te deja aportar el mensaje.
- `--` sigue haciendo falta porque `$DIR` podría expandirse legítimamente a un valor que empiece con `-` (un directorio llamado literalmente `-tmp`, o un valor inyectado desde un argumento), que `rm` interpretaría como opciones.

Las comillas de `"${DIR:?...}"` son la cuarta protección: sin comillas, un valor con espacios se convierte en varias rutas.

---

### Bloque 4 — globbing

**A4.1** Lo expande el **shell**, antes de que `ls` se ejecute. `ls` recibe un vector de argumentos ya expandido: `argv = ["ls", "data.csv", "file1.txt", ...]`. `ls` nunca ve el carácter `*`. Este es el hecho más importante sobre el globbing en Unix, y explica tres cosas a la vez: por qué el globbing funciona igual para todos los comandos, por qué `find . -name *.txt` se rompe, y por qué un comando que necesita hacer su *propia* coincidencia de patrones (`find`, `tar`, `grep`) exige que entrecomillés el patrón para que el shell le pase los caracteres literales.

**A4.2** `?` coincide con **exactamente un** carácter, así que `file?.txt` coincide con `file1.txt` … `file9.txt` — nueve nombres. `file10.txt` tiene dos caracteres entre `file` y `.txt`, así que necesita `file??.txt`. `*` coincide con una cadena de **cero o más** caracteres, así que `file*.txt` coincide con los doce (y también coincidiría con un hipotético `file.txt`).

**A4.3** `*[!3][0-9][0-9][0-9].log` está mal en cuanto a posiciones; contando desde el final, `.log` son 4 caracteres, así que "cuarto desde el final" significa el último carácter antes de `.log`. El patrón es:

```
*[!3].log
```

Para el conjunto `report-YYYY.log` del ejercicio, eso da `report-2024.log` y `report-2025.log`. El punto general: `[!...]` (POSIX; bash también acepta `[^...]`) niega el conjunto, y sigue coincidiendo con **exactamente un** carácter — un corchete negado no es un operador "no esta cadena".

**A4.4** Los **rangos** entre corchetes se interpretan usando el orden de colación del locale actual (`LC_COLLATE`), no ASCII. En muchos locales la colación intercala mayúsculas y minúsculas, así que `[a-z]` puede coincidir también con `B` hasta `Z`, y `[A-Z]` puede coincidir con minúsculas. Un script que filtra nombres de archivo con `[a-z]` se comporta, por tanto, de forma distinta en un escritorio `en_US.UTF-8` y en un entorno de cron con `LANG=C`. El reemplazo portable es la clase de caracteres POSIX, que es consciente del locale en el sentido correcto: `[[:lower:]]`, `[[:upper:]]`, `[[:digit:]]`, `[[:alpha:]]`, `[[:alnum:]]`, `[[:space:]]`, `[[:punct:]]`. La otra solución es fijar `LC_ALL=C` para el script.

**A4.5** `.*` coincide con `.` (el directorio actual) y con `..` (**el directorio padre**). Por lo tanto `rm -rf .*` intenta descender en `..` y borrar *el árbol entero del directorio padre* — una forma clásica de perder un directorio personal mientras se "limpian dotfiles". (El `rm` de GNU trata como caso especial los argumentos literales `.` y `..` y los rechaza, pero esto no es portable y no te salva en toda construcción.) El modismo seguro para "entradas ocultas excepto `.` y `..`" es:

```bash
rm -rf .[!.]* ..?*
```
o, mejor, `shopt -s dotglob` más un `*` simple, o `find . -maxdepth 1 -name '.*' ! -name '.' ! -name '..' -exec rm -rf {} +`.

**A4.6** Porque el comportamiento por defecto de bash es dejar **sin expandir** un patrón que no coincide con nada, pasándole los caracteres literales al comando. Por eso `ls *.nomatch` informa `cannot access '*.nomatch'` — `ls` realmente recibió esa cadena. Las dos opciones:
- `shopt -s nullglob` — un patrón sin coincidencias se expande a **nada** (cero palabras). Cómodo para `for f in *.log`, peligroso para comandos que cambian de significado con menos argumentos (`cp *.bak dest/` se convierte en `cp dest/`).
- `shopt -s failglob` — un patrón sin coincidencias es un **error**: el comando no se ejecuta en absoluto. Es la opción más estricta y normalmente la mejor para seguridad interactiva.

**A4.7** Orden de expansión. Bash realiza la **expansión de llaves primero**, de forma puramente textual y sin consultar el sistema de archivos, así que `file{1..12}.txt` se convierte en doce palabras sin importar qué exista — que es exactamente lo que `touch` necesita. **La expansión de rutas (globbing) ocurre mucho después** y solo coincide con nombres existentes; en un directorio vacío `file*.txt` no coincide con nada, y con el comportamiento por defecto (`nullglob` desactivado) se pasa literalmente, así que `touch` crea obedientemente un archivo cuyo nombre contiene un asterisco. Orden completo: llaves → tilde → parámetros/variables → sustitución de comandos → aritmética → división en palabras → **expansión de rutas** → eliminación de comillas.

**A4.8** Sin comillas, el shell expandió `*.txt` **antes** de que `find` se ejecutara, así que `find` recibió `find . -name file1.txt file10.txt file11.txt ... file9.txt`. La gramática de `find` es `find [rutas...] [expresión]`; después de la prueba `-name file1.txt` se encontró con otra palabra suelta, `file10.txt`, en posición de expresión y la rechazó — de ahí `paths must precede expression`. Si hubiera existido exactamente un archivo `.txt`, la expansión habría producido un comando único y sintácticamente válido: `find . -name file1.txt`, que se ejecuta sin problemas y encuentra solo ese archivo, dentro del árbol del directorio actual — **el resultado equivocado, con estado de salida 0 y sin ningún aviso**. El modo de fallo es peor que el error: es silencioso y depende del estado del directorio en el que casualmente estés parado. Entrecomillá siempre los patrones destinados al *programa*: `find . -name '*.txt'`.

---

### Bloque 5 — `find`

**A5.1** Con un sufijo de unidad, el `find` de GNU divide el tamaño del archivo por la unidad y **redondea hacia arriba** a la unidad entera siguiente. Un archivo de 500 bytes es `ceil(500 / 1048576) = 1` en unidades de `M`. `-size -1M` significa "estrictamente menos de 1 unidad", es decir 0 unidades, lo que solo satisfacen los archivos vacíos (0 bytes). De ahí que solo coincidieran los `.log` vacíos. `-size -1000000c` cuenta en bytes crudos (`c`), donde no hay redondeo, así que los archivos de 500 y 5000 bytes sí coinciden. Las reglas a memorizar:
- sufijos: `c` = bytes, `w` = 2 bytes, `b` = **bloques de 512 bytes (el valor por defecto cuando no se da sufijo)**, `k` = KiB, `M` = MiB, `G` = GiB;
- `+n` = más de n unidades, `-n` = menos de n unidades, `n` = exactamente n unidades — todo *después* de redondear hacia arriba;
- si te importan umbrales exactos en bytes, usá siempre `c`.

**A5.2** `find` calcula la edad del archivo en periodos completos de 24 horas y **trunca** la parte fraccionaria.
- `-mtime +7` → `edad_en_días > 7` tras truncar, así que el archivo se modificó **hace al menos 8×24 h**. Un archivo modificado hace 7 días y 20 horas tiene edad truncada 7 y **no** coincide — por eso "borrar copias de seguridad de más de una semana" escrito como `-mtime +7` en realidad las conserva ocho días.
- `-mtime -3` → edad truncada `< 3`, es decir, modificado dentro de las últimas **3×24 h**.
- `-mtime 0` → edad truncada exactamente 0, es decir, dentro de las últimas 24 horas.

La parte fraccionaria se descarta, lo que sesga `+n` hacia conservar archivos y `-n` hacia seleccionarlos. Usá `-mmin` para granularidad de minutos, o `-newermt '7 days ago'` para una comparación de marca de tiempo exacta sin truncamiento alguno.

**A5.3** Los tres reciben el mismo argumento de modo pero lo combinan de forma distinta:
- **`-perm 600`** — coincidencia *exacta*. Solo `rw-------`. Un archivo con modo 644 o 601 no coincide.
- **`-perm -600`** — *todos estos bits están puestos*, los demás son irrelevantes. Coincide con 600, 640, 644, 660, 777 — cualquier cosa con lectura **y** escritura del propietario. Esta es la forma para "¿es escribible por su propietario?".
- **`-perm /600`** — *cualquiera de estos bits está puesto*. Coincide con 400, 200, 644, ¿040? (no — 040 no tiene ni lectura ni escritura del propietario, así que no coincide), es decir, cualquier cosa con lectura **o** escritura del propietario. Esta es la forma del barrido de seguridad clásico `find / -type f -perm /o+w`, "escribible por todos de cualquier manera".

(`-perm +600` era la vieja grafía GNU de `/`; se eliminó en findutils 4.5.12 y hoy da error.) Las formas simbólicas funcionan en todos los lugares donde funciona una numérica: `-perm -u+x`, `-perm /o+w`.

**A5.4** `\;` termina el comando después de **un** nombre de archivo, así que `find` hace fork y exec del comando una vez por coincidencia. `+` agrupa tantos nombres como quepan dentro de `ARG_MAX` en una única invocación, exactamente como `xargs`. `+` es muchísimo más rápido en árboles grandes (un `exec` en lugar de 100 000).

`\;` es **obligatorio** cuando:
- el comando toma exactamente un argumento de archivo, o `{}` no es el último argumento — por ejemplo `-exec mv {} /backup/ \;` (con `+`, `{}` debe ser el argumento final, así que esa forma es inválida; usá `-exec mv -t /backup/ {} +` en su lugar);
- `{}` debe aparecer más de una vez o ir embebido en una cadena más grande — `-exec sh -c 'cp "$1" "$1.bak"' _ {} \;`;
- necesitás semántica de estado de salida por archivo — con `+`, el estado de salida de `find` refleja el lote, y un archivo que falla es más difícil de atribuir;
- el comando no es idempotente sobre múltiples argumentos, por ejemplo `diff {} ref \;`.

**A5.5** Ambos son metacaracteres del shell que deben llegar literalmente a `find`. `;` es el **separador de comandos** del shell — sin escapar, el shell terminaría ahí el comando `find` e intentaría ejecutar lo que sigue como un comando nuevo, y `find` se quejaría con `-exec: no terminating ";" or "+"`. `{}` solo es especial en algunos contextos (la expansión de llaves necesita una coma o `..`, así que un `{}` suelto normalmente sobrevive), pero entrecomillarlo como `'{}'` es una costumbre inofensiva y portable a shells que sí lo tratan como especial. Grafías aceptables: `\;`, `';'`, `";"`.

**A5.6**
```bash
find project -name '*.o' -print0 | xargs -0 -r rm --
```
- `-print0` / `-0` — delimitadores NUL, así que espacios, saltos de línea y comillas en los nombres son seguros.
- `-r` (`--no-run-if-empty`, una extensión GNU) — no ejecutar `rm` en absoluto cuando la entrada esté vacía. Sin él, `xargs` ejecuta `rm --` una vez sin operandos; el `rm` de GNU lo trata como error (`missing operand`), lo que convierte una noche tranquila sin trabajo en un trabajo de cron que falla.
- `--` — protege frente a un nombre de archivo coincidente que empiece con `-`.

Los equivalentes nativos de la herramienta, que evitan la tubería por completo, son `find project -name '*.o' -delete` o `find project -name '*.o' -exec rm -- {} +`.

**A5.7** `find` añade un `-print` implícito **solo cuando la expresión no contiene ninguna acción propia**. `-prune` *es* una acción (como lo son `-print`, `-delete`, `-exec`, `-quit`), así que su presencia suprime el `-print` implícito para toda la expresión — por eso la versión ingenua no imprimió nada útil y, peor, imprimió el propio `project/build`: sin un `-print` explícito en la rama derecha, la única salida vino del comportamiento por defecto del propio `-prune` dentro de la expresión tal como se evaluó. Escribir `-o -type f -print` restaura una acción explícita en la rama que realmente querés.

La mecánica de `-prune`: siempre devuelve **verdadero** y le dice a `find` "no desciendas en este directorio". El modismo es por tanto `find RUTA <coincidencia-a-omitir> -prune -o <expresión-real> -print`, que se lee como "o bien es lo que hay que omitir (podalo, y cortocircuitá el `-o`) **o** evaluá la expresión real". Notá que `-prune` no tiene efecto bajo `-depth` (y por lo tanto ninguno con `-delete`), porque `-depth` visita el contenido antes que el directorio.

**A5.8** `-delete` implica `-depth` porque un directorio no se puede eliminar hasta que esté vacío: el recorrido debe visitar y borrar **primero el contenido** del directorio y después el directorio. Eso es exactamente lo que proporciona `-depth` (recorrido en post-orden).

La consecuencia para `-prune`: `-prune` funciona diciéndole al recorrido descendente que no descienda — pero bajo `-depth` el descenso ya ocurrió para cuando se evalúa el directorio, así que `-prune` es silenciosamente un no-op. El `find` de GNU rechaza directamente la combinación (`find: -delete action is incompatible with -prune`) en versiones recientes; versiones antiguas la aceptaban y **borraban el subárbol que querías proteger**. Para excluir un subárbol de un `find` que borra, usá en su lugar una prueba negativa: `find project ! -path 'project/build/*' -name '*.tmp' -delete`.

**A5.9** `-maxdepth`, `-mindepth`, `-depth`, `-follow` y `-xdev` son **opciones globales**: afectan a todo el recorrido sin importar dónde aparezcan, pero `find` analiza la línea de comandos de izquierda a derecha y evalúa las *pruebas* en orden. Escribir una opción global después de una prueba crea un desajuste entre cómo se lee y cómo se comporta, así que el `find` de GNU emite un aviso mientras la aplica igualmente de forma global.

El riesgo es que se lee como una condición y no lo es. `find . -name '*.log' -maxdepth 1` parece decir "de los archivos `.log`, solo los de profundidad 1", pero el recorrido ya estaba limitado a profundidad 1 antes de que se ejecutara ninguna prueba — el mismo resultado aquí, un resultado distinto en expresiones con `-o` o `-prune`, donde quien lee predecirá mal el desenlace. Peor todavía, el aviso va a stderr y desaparece en un trabajo de cron. Poné siempre las opciones globales inmediatamente después de las rutas: `find . -maxdepth 1 -name '*.log'`.

---

### Bloque 6 — `tar`

**A6.1** El `tar` histórico acepta un **grupo de opciones agrupadas como primer argumento, con o sin guion inicial** (`tar czf`, `tar -czf`, `tar -z -c -f`). Dentro del grupo, el orden es libre — *excepto* que `-f` consume el **argumento siguiente** como nombre del archivo. En `-cfz`, la letra después de `f` es `z`, así que `f` toma `z`… no: `f` toma la siguiente *palabra de la línea de comandos*, que es `project.tar.gz` — pero el grupo `-cfz` ya consumió `z` como una posición de opción agrupada, así que `tar` lee el nombre del archivo como la palabra que sigue al grupo y luego asigna mal el resto. En la práctica obtenés `tar: z: Cannot stat: No such file or directory` o un archivo nombrado con el operando equivocado. La regla: **`-f` debe ser la última letra del grupo**, porque su argumento va detrás.

**A6.2** `tar` recorta la `/` inicial para que un archivo sea **reubicable**: al extraerlo escribe en el directorio actual (o en el destino de `-C`) en lugar de arrasar las rutas absolutas desde las que se creó. El escenario de seguridad que lo motiva es un archivo que contiene `/etc/shadow` o `/root/.ssh/authorized_keys`: sin el recorte, un `tar -xf untrusted.tar` ingenuo ejecutado como root sobreescribiría archivos vivos del sistema en cualquier punto del disco. (La misma clase de ataque usa componentes `../../..`; el tar de GNU moderno también los rechaza por defecto y avisa.)

`-P` / `--absolute-names` desactiva el recorte. Nunca lo uses con un archivo que no creaste vos, exactamente por la razón anterior. Usalo solo cuando necesitás deliberadamente una restauración absoluta, e incluso entonces preferí `tar -xf archive.tar -C /` sobre un archivo relativo.

**A6.3** La carga útil era salida de `/dev/urandom` — los datos aleatorios criptográficos tienen entropía máxima y son **incompresibles por construcción**. Ningún compresor de propósito general puede reducirlos; los tres produjeron aproximadamente el tamaño de la entrada más la sobrecarga del contenedor. (Si alguna vez un compresor pareciera reducir datos aleatorios de forma significativa, eso indicaría que la fuente no era aleatoria.)

Para un árbol realista de código fuente, configuración y logs, el comportamiento esperado:

| | ratio | velocidad de compresión | velocidad de descompresión | uso típico |
|---|---|---|---|---|
| `gzip` (`-z`, `.gz`) | el más bajo | la más rápida | la más rápida | rotación de logs, HTTP al vuelo, cualquier cosa limitada por CPU o transmitida en flujo |
| `bzip2` (`-j`, `.bz2`) | intermedio | lenta | lenta | en gran medida superado; todavía se ve en archivos antiguos de distribuciones |
| `xz` (`-J`, `.xz`) | el más alto | **la más lenta**, ávida de memoria | rápida | tarballs de versiones, fuentes de kernel/distribuciones — comprimir una vez, descargar muchas |

La regla operativa se deriva de la asimetría: **comprimir una vez / descomprimir muchas → xz; comprimir muchas / leer rara vez → gzip.** (`zstd`, `tar --zstd`, ocupa hoy el punto medio práctico: velocidad cercana a gzip con ratios cercanos a xz, y es el valor por defecto en varias distribuciones — no está en el objetivo de LPIC-1, pero es la respuesta correcta en producción.)

**A6.4**
```bash
tar -xzf app.tar.gz -C /opt/app --strip-components=1
```
`--strip-components=1` elimina el primer elemento de la ruta (`app-1.4.2/`) de cada nombre de miembro al extraer, y `-C` fija el directorio de trabajo antes de que empiece la extracción. `/opt/app` ya debe existir. Este es el conjuro estándar para desempaquetar tarballs de versiones upstream, que casi siempre envuelven su contenido en un único directorio con la versión.

**A6.5** `.tar` es una **concatenación de registros de cabecera de 512 bytes + datos**, terminada en dos bloques de NUL. Añadir significa posicionarse en el marcador de fin de archivo y escribir ahí registros nuevos — una operación local y barata. `.tar.gz` es ese mismo flujo tar pasado por un **único flujo comprimido**; no hay un "fin de miembros" direccionable dentro, y el estado del compresor depende de todo lo anterior, así que el tar de GNU no puede añadir sin descomprimir y recomprimir el archivo entero. Se niega en vez de hacerlo en silencio: `tar: Cannot update compressed archives`.

La solución alternativa es explícita: `gunzip project.tar.gz && tar -rf project.tar extra.txt && gzip project.tar`. Los formatos con índice por miembro y directorio central — `zip`, `7z`, `dar` — no tienen esta restricción, que es la diferencia práctica entre "archivar y luego comprimir" (tar) y "comprimir cada miembro" (zip).

**A6.6** Lo aplicó la **umask**. Cuando extrae un usuario no root, el tar de GNU calcula el modo final como el modo archivado enmascarado por la umask actual, así que `777 & ~022 = 755`. `-p` / `--preserve-permissions` (también `--same-permissions`) le indica a tar que ignore la umask y fije exactamente el modo archivado.

Los valores por defecto dependen del rol:
- **root**: `-p` es el **comportamiento por defecto** al extraer, igual que `--same-owner`. Restaurar un árbol de sistema como root reproduce modos y propiedad exactamente, que es lo que querés para `/etc`.
- **no root**: se aplica la umask salvo que uses `-p`, y `--no-same-owner` es el valor por defecto (los archivos pasan a ser propiedad del usuario que extrae), porque de todos modos un usuario normal no puede hacer `chown` a favor de otra persona.

Para cualquier restauración que deba ser fiel, usá `sudo tar -xpf ... --same-owner` y verificá con `stat -c '%a %U:%G'`.

**A6.7**
- `--null` le dice a tar que la lista de nombres de `-T -` está **separada por NUL**, en correspondencia con `find -print0`. Sin él, tar divide por saltos de línea y estropea cualquier nombre que contenga uno — y, poco útilmente, el formato `-T` separado por líneas de tar también trata de forma especial los espacios iniciales/finales y las comillas, así que hasta espacios corrientes pueden romperlo. `--null` además desactiva ese procesamiento de comillas.
- `--no-recursion` hace falta porque `find` **ya** enumeró cada archivo. Librado a sí mismo, tar tomaría cada directorio de la lista y volvería a descender en él, reañadiendo archivos que `find` excluyó deliberadamente — anulando el filtro en silencio. El par `--null --no-recursion -T -` es el modismo canónico de "que find decida el conjunto de archivos".

(El orden importa un poco: `--no-recursion` es posicional en el tar de GNU y afecta a los nombres leídos después, así que dejalo antes de `-T`.)

**A6.8**
```bash
tar -tvzf project.tar.gz | awk '$3 > 1048576 {print $3, $6}'
```
`tar -tv` imprime un listado al estilo `ls -l` en el que el campo 3 es el tamaño en bytes y el último campo es el nombre del miembro (campo 6 con el formato de fecha por defecto; usá `--quoting-style=literal` y revisá tu locale, o más seguro, `tar --list --verbose --full-time`). Lo clave para el examen es que **`-t` lee el archivo sin escribir nada en el sistema de archivos** — podés inspeccionar nombres, tamaños, modos, propietarios y destinos de enlaces de un archivo no confiable antes de decidir extraerlo, que es lo primero que deberías hacer con cualquier archivo de procedencia externa.

---

### Bloque 7 — `cpio`

**A7.1**
- **`-o` / `--create`** — *copy-out*: lee una lista de nombres de archivo en **stdin** y escribe un archivo en **stdout**.
- **`-i` / `--extract`** — *copy-in*: lee un archivo desde **stdin** y lo extrae (o lo lista, con `-t`).
- **`-p` / `--pass-through`** — *pass-through*: lee una lista de nombres de archivo en stdin y los copia directamente al directorio de destino dado como único argumento. **Nunca se crea un archivo** — es un `cp -a` gobernado por `find`, que es precisamente por lo que resulta útil para copias de árboles con criterios de selección complejos.

**A7.2** Faltaban los **directorios**. `cpio -i` por defecto no crea los directorios que preceden; intenta abrir `project/src/main.c` para escritura, `project/src` no existe, y `open(2)` devuelve `ENOENT` — informado como "Cannot open: No such file or directory" contra el nombre del *archivo*, que es por lo que el mensaje resulta engañoso. **`-d` / `--make-directories`** lo arregla. El modismo completo de extracción es `cpio -idmv`: `-i` extraer, `-d` crear directorios, `-m` preservar mtime, `-v` verboso. Memorizalo como una unidad; es la respuesta a casi cualquier pregunta de extracción con cpio.

**A7.3** `-depth` hace que `find` emita cada directorio **después** de su contenido (post-orden). Al restaurar, cpio crea entonces los archivos primero y fija los permisos y marcas de tiempo del propio directorio al final. Sin eso, cpio escribe un directorio con, digamos, modo `0555` o `0500`, y luego no puede crear archivos dentro — e incluso cuando puede, escribir los archivos después actualiza la mtime del directorio, así que las marcas de tiempo de los directorios restaurados quedan mal. Con directorios de solo lectura en el árbol de origen, omitir `-depth` produce directamente una restauración fallida. El mismo razonamiento aplica a `cpio -p`.

**A7.4** El tamaño de bloque es de **512 bytes**, y el mensaje se escribe en **stderr**. Esa separación es esencial: el archivo en sí va a **stdout**, así que `find ... | cpio -o > project.cpio` deja solo bytes del archivo en el fichero mientras la línea de progreso "N blocks" sigue llegando a tu terminal. Si cpio la escribiera en stdout, todos los archivos estarían corruptos. El corolario para scripting: `2>/dev/null` silencia el contador sin tocar el archivo, y nunca debés fusionar stderr en stdout (`2>&1`) en una tubería de copy-out de cpio.

**A7.5** `cpio -i` **se niega a sobreescribir un archivo más nuevo o de la misma edad que la versión archivada**, imprimiendo `not created: newer or same age version exists`, y lo hace **sin estado de salida distinto de cero para ese archivo** — una omisión silenciosa. `tar -x`, en cambio, **sobreescribe incondicionalmente** por defecto (sus equivalentes opcionales son `--keep-newer-files` y `--keep-old-files`).

`-u` / `--unconditional` restaura el comportamiento tipo tar: sobreescribir sin importar la edad. La lección operativa es que una restauración basada en cpio sobre un árbol parcialmente vivo puede dejar en silencio archivos más nuevos y equivocados en su sitio — restaurá siempre en un directorio vacío, o pasá `-u` deliberadamente.

**A7.6**
```bash
mkdir -p /tmp/passthru
tar -cf - project | tar -xpf - -C /tmp/passthru
```
El primer `tar` escribe el archivo en stdout (`-f -`), el segundo lo lee de stdin y lo extrae bajo `-C`. Añadí `--numeric-owner` y ejecutá como root para una copia fiel de un árbol de sistema, y `-S` para mantener dispersos los archivos dispersos. Esta tubería `tar | tar` es la forma clásica de copiar un árbol a través de una frontera que `cp` maneja mal — incluso por red: `tar -cf - dir | ssh host 'tar -xpf - -C /dest'`.

**A7.7** Porque en modo copy-in el cpio de GNU respetará un **nombre de miembro absoluto** dentro del archivo y escribirá en esa ruta absoluta, fuera de tu directorio actual. Un archivo confeccionado con miembros llamados `/etc/cron.d/backdoor` o `/root/.ssh/authorized_keys`, extraído como root, escribe exactamente ahí. `--no-absolute-filenames` obliga a que todo miembro se cree en forma relativa al directorio actual, que es el comportamiento por defecto de `tar` y debería ser el tuyo. Combinalo con `cpio -t` para inspeccionar la lista de miembros *antes* de extraer nada, y preferí extraer en un directorio desechable.

**A7.8** El `initramfs`. La imagen de espacio de usuario temprano del kernel de Linux es un **archivo cpio en formato `newc`** (opcionalmente comprimido, y a menudo precedido de un segmento early-cpio sin comprimir que lleva el microcódigo de CPU), porque el kernel contiene un desempaquetador cpio mínimo integrado y el formato de cpio es lo bastante simple para decodificarse sin dependencias. Así que todo sistema Linux arranca a través de un archivo cpio, y cualquiera que depure un fallo de arranque — un controlador de almacenamiento ausente, un módulo `dracut` roto, un `/etc/crypttab` equivocado — desempaqueta y reempaqueta uno. `lsinitrd` (Fedora/RHEL) y `lsinitramfs` (Debian/Ubuntu) son envoltorios sobre exactamente esto. Las cargas útiles de los RPM también son archivos cpio.

---

### Bloque 8 — `dd`

**A8.1** El formato es `COMPLETOS+PARCIALES records in` / `COMPLETOS+PARCIALES records out`, donde "record" significa un `read()`/`write()` de `bs` bytes.
- `8+0` — ocho bloques **completos**, cero parciales. Limpio.
- `0+2` — cero bloques completos y **dos parciales**: dos llamadas a `read()` que devolvieron menos de `bs` bytes cada una. Es normal al leer de una tubería, un tty o un socket, donde un único `read()` no está obligado a llenar el búfer.
- `12+1` — doce bloques completos más uno final corto, la firma habitual de un archivo cuyo tamaño no es múltiplo de `bs`.

La línea de `records out` importa igual: si `in` y `out` no coinciden, o si `out` muestra escrituras parciales a un dispositivo, se perdieron datos o hubo escrituras cortas.

**A8.2** Sin `conv=notrunc`, `dd` abre el archivo de salida con `O_TRUNC`, así que el archivo queda **truncado a longitud cero en el momento de abrirlo**. Después `seek=512` avanza 512 bytes — escribiendo dentro de un agujero — y escribe 4 bytes, dejando un archivo de exactamente 516 bytes cuyos primeros 512 bytes son un tramo disperso de NUL. Los 8 MiB de contenido original desaparecieron.

`conv=notrunc` omite `O_TRUNC`, así que el archivo existente se abre en el sitio y solo se modifican los 4 bytes en el desplazamiento 512; la longitud sigue siendo 8388608. **Cualquier parche en el sitio de un archivo o imagen existente requiere `conv=notrunc`.** (Escribir en un dispositivo de bloques no se ve afectado — los dispositivos no se pueden truncar —, que es por lo que es fácil olvidar esta opción hasta que destruye una imagen de disco.)

**A8.3**
- **`skip=N`** se aplica a la **entrada** (`if=`): omitir N bloques antes de empezar a leer.
- **`seek=N`** se aplica a la **salida** (`of=`): omitir N bloques antes de empezar a escribir.

Ambos se cuentan en **bloques del tamaño de `bs`**, no en bytes — una fuente constante de errores por factor. Si `ibs` y `obs` se fijan por separado, `skip` usa `ibs` y `seek` usa `obs`. El `dd` de GNU también acepta `iseek=`/`oseek=` como alias más claros, y `skip=512B` (sufijo `B` en mayúscula) para forzar un conteo en bytes independientemente de `bs`. Mnemotecnia: hacés **seek** hacia donde vas a **escribir**.

**A8.4** Solo se almacenan las **regiones distintas de cero y los metadatos del archivo**; los 100 MB de ceros son un **agujero** — un rango del archivo para el cual el sistema de archivos no asignó bloque alguno y que se lee como NUL. `ls -l` muestra `st_size` (la longitud lógica, 100 MB); `du` muestra `st_blocks × 512` (los bytes asignados, 0).

`tar -cf` sin `-S` **lee el archivo normalmente**, obtiene 100 MB de NUL y almacena 100 MB de NUL — el archivo se hincha y el archivo extraído queda totalmente asignado, ya no disperso. `tar -S` / `--sparse` detecta los agujeros y los registra, restaurando la dispersión al extraer. Lo mismo aplica a `cp` (`--sparse=always|auto|never`, `auto` por defecto, que detecta tramos largos de NUL) y a `rsync -S`. Por eso copiar ingenuamente imágenes de disco de máquinas virtuales y archivos respaldados por swap multiplica tu factura de almacenamiento.

**A8.5** Resuelven dos mitades de un mismo problema:
- `conv=noerror` — no abortar ante un error de lectura; registrarlo y continuar con el bloque siguiente. Sin él, `dd` se detiene en seco en el primer sector defectuoso y no rescatás nada más allá.
- `conv=sync` — **rellenar con NUL cada bloque de entrada corto o fallido hasta `bs`** antes de escribirlo.

Con `noerror` solo, una lectura fallida de 4096 bytes no aporta **nada** a la salida, así que cada byte posterior al sector defectuoso queda desplazado 4096 bytes antes de su desplazamiento verdadero. Para una imagen de sistema de archivos eso es catastrófico: superbloques, tablas de inodos y punteros de extensiones viven todos en desplazamientos fijos, y un único bloque defectuoso sin relleno desalinea todo el resto, convirtiendo una imagen recuperable con un agujero en una imposible de montar. `sync` conserva los desplazamientos, así que solo perdés los sectores ilegibles — el resto del sistema de archivos sigue interpretándose.

En producción, `ddrescue` (GNU) es la herramienta correcta: mapea las regiones defectuosas, las reintenta con tamaños de bloque decrecientes y mantiene un registro reanudable. `dd conv=noerror,sync` es la respuesta cuando `ddrescue` no está instalado, y es la respuesta en el examen.

**A8.6** `count=2` limita `dd` a **dos llamadas a `read()`**, no a dos porciones de datos del tamaño de `bs`. Al leer de una **tubería**, un único `read()` devuelve lo que haya en ese momento en el búfer de la tubería — a menudo menos de 4096 bytes, y el kernel no tiene ninguna obligación de llenar el búfer. Dos lecturas cortas devolvieron 10000 bytes en total, de ahí `0+2 records in` y 10000 bytes copiados. En otra ejecución los tiempos cambian y el conteo de bytes también.

`iflag=fullblock` hace que `dd` siga llamando a `read()` hasta acumular los `bs` bytes completos (o hasta EOF), de modo que `count` vuelve a significar "esta cantidad de bloques completos". **Cualquier `dd` que lea de una tubería, un socket, un tty o `/dev/urandom` con un `count=` que deba ser exacto necesita `iflag=fullblock`.** Su ausencia es la causa más común de salida de `dd` silenciosamente truncada en scripts.

**A8.7**
```bash
sudo dd if=/dev/sda of=~/mbr.bin bs=512 count=1
```
Esos 512 bytes de un disco particionado con MBR contienen, en orden:
- bytes **0–445** — el código de arranque (cargador de arranque de etapa 1, por ejemplo el `boot.img` de GRUB);
- bytes **440–443** — la firma de disco de 32 bits (número de serie de unidad de NT), usada por algunos sistemas para identificar el disco;
- bytes **446–509** — la **tabla de particiones**: cuatro entradas de partición primaria de 16 bytes;
- bytes **510–511** — la firma de arranque `0x55AA`.

Restaurar solo la tabla de particiones sin el código de arranque es `bs=1 skip=446 count=64 seek=446 conv=notrunc`. En un disco **GPT** este sector es en cambio un *MBR protector*, y la tabla de particiones real es la cabecera GPT en el LBA 1 más el arreglo de entradas en los LBA 2–33 (con una copia de respaldo al final del disco) — así que `bs=512 count=34` es la captura equivalente para GPT, y `sgdisk --backup` es la herramienta correcta.

**A8.8**
- `of=/dev/sda bs=1M count=1` — pone a cero el **primer megabyte de todo el disco**: el MBR/MBR protector, la tabla de particiones, la cabecera primaria GPT y su arreglo de entradas, y el comienzo de la primera partición. El sistema pierde todo conocimiento de cómo está dividido el disco; todas las particiones quedan inaccesibles a la vez, y el cargador de arranque desaparece. Recuperable en principio (GPT guarda un respaldo al final del disco; `testdisk` puede reconstruir un MBR a partir de firmas de sistemas de archivos), pero la máquina no arrancará y nada se montará.
- `of=/dev/sda1 bs=1M count=1` — pone a cero el **primer megabyte de una partición**: el superbloque de ese sistema de archivos y, en ext4, los descriptores de grupo primarios y parte de la tabla de inodos. La tabla de particiones queda intacta, así que las demás particiones están bien y el disco sigue enumerándose. `ext4` mantiene superbloques de respaldo (`mke2fs -n` lista sus desplazamientos; `fsck -b 32768` usa uno), así que esto suele ser reparable; XFS también mantiene superbloques secundarios. LUKS es la excepción — poner a cero una cabecera LUKS sin un `luksHeaderBackup` destruye las ranuras de clave y los datos son criptográficamente irrecuperables.

Ambos son catastróficos. El hábito que los previene: ejecutá `lsblk -f` y leé la salida *en voz alta* antes de cualquier `dd of=/dev/...`, y preferí poner `of=` al final de la línea para verlo justo en el momento de confirmar.

---

### Bloque 9 — compresión y `file`

**A9.1** `gzip ARCHIVO` está definido para **reemplazar** su entrada: escribe `ARCHIVO.gz` y desenlaza `ARCHIVO` al terminar con éxito. `gzip -c` escribe en **stdout** y deja la entrada intacta (igual que `gzip -k`, `--keep`).

`-c` (o `-k`) es más seguro en un script por dos razones. Primero, si el sistema de archivos de destino se llena a mitad de la escritura, `gzip -c > out.gz` deja un `out.gz` truncado **y un original intacto**, mientras que un `gzip` simple puede dejarte, en algunos caminos de fallo, sin archivo utilizable ni fuente. Segundo, `gzip -c` compone: puede alimentar una tubería, una sesión `ssh` o una suma de verificación sin tocar el disco. El patrón seguro para rotación es `gzip -c f > f.gz.tmp && mv f.gz.tmp f.gz && rm f`, que es atómico en el renombrado.

**A9.2** `gzip`/`bzip2`/`xz` comprimen **un flujo continuo de bytes** y no tienen noción de miembros, nombres ni índice. `.tar.gz` es por tanto "sólido": para extraer un miembro, el descompresor debe inflar el flujo desde el principio hasta el desplazamiento de ese miembro. No hay acceso aleatorio, y no hay un directorio central que liste lo que hay dentro — `tar -tzf` sobre un archivo de 50 GB realmente lee y descomprime 50 GB.

`.zip` comprime **cada miembro de forma independiente** y guarda un directorio central al final del archivo con los desplazamientos por miembro, así que extraer un archivo de entre 100 000 es O(1) búsquedas. El compromiso es el ratio: la compresión sólida encuentra redundancia *entre* archivos (cien archivos `.c` similares comprimen mucho mejor juntos), que es por lo que `.tar.xz` gana a `.zip` en un árbol de fuentes y por lo que `.zip` gana en acceso aleatorio. Formatos como `7z` y `dar` ofrecen ambas cosas comprimiendo en bloques con un índice.

**A9.3** Mirá la tabla de **A6.3**. La regla operativa: **rotación nocturna de logs → gzip** (los logs se escriben y comprimen constantemente y se leen rara vez; la CPU del host de producción es el recurso escaso, y la directiva `compress` de `logrotate` usa gzip por defecto). **Un tarball de distribución de una versión → xz** (comprimido una vez en una máquina de compilación donde la CPU es gratis, descargado y descomprimido miles de veces; cada punto porcentual de ratio es ancho de banda ahorrado). bzip2 ya no tiene nicho — es más lento que xz al descomprimir *y* comprime peor.

**A9.4** El formato gzip almacena el tamaño descomprimido en un campo final de 4 bytes, así que solo es válido **módulo 2³²** — para cualquier entrada de 4 GiB o más, `gzip -l` informa `tamaño mod 4294967296`, que sencillamente es incorrecto y sin aviso. La propia salida de `file` lo declara explícitamente: *"original size modulo 2^32"*. La respuesta fiable para un miembro grande es descomprimir y contar sin escribir: `gzip -dc big.gz | wc -c`. (`xz --robot --list` informa tamaños verdaderos porque el contenedor xz los registra correctamente.)

**A9.5** `bzcat` para bzip2 y `xzcat` para xz (también `bzip2 -dc` y `xz -dc`; `zstdcat` para zstd). Notá que `zcat` en sistemas GNU también maneja `.Z` (compress) y, en muchas compilaciones, otros formatos — pero no confíes en él para `.bz2`/`.xz`.

`zgrep` existe por ergonomía y corrección, no por capacidad. Acepta y reenvía **el conjunto completo de opciones de grep y múltiples argumentos de nombre de archivo** y —lo crucial— antepone a las coincidencias el **nombre de archivo** correcto cuando se le dan varios archivos, cosa que `gunzip -c *.gz | grep patrón` no puede hacer porque la tubería ya fusionó los flujos y perdió las fronteras. También maneja de forma transparente una mezcla de entradas comprimidas y sin comprimir, así que `zgrep 'ERROR' /var/log/messages*` funciona sobre un conjunto de rotación donde algunos archivos son `.gz` y el actual no. La misma familia aporta `zdiff`, `zless`, `zmore`, `zcmp`.

**A9.6** `file` por defecto **no sigue** los enlaces simbólicos: llama a `lstat(2)`, ve un enlace e informa el enlace en sí junto con la ruta de su destino — que es la respuesta útil cuando estás auditando un árbol para saber qué es un enlace y a dónde apunta. `file -L` (`--dereference`) sigue el enlace e identifica **aquello a lo que apunta**; el destino `main.c` es un archivo de cero bytes, y `file` clasifica un archivo regular vacío como `empty`. `file` también detecta e informa de forma especial los enlaces **rotos**, ya que seguirlos es imposible — eso convierte a `file` en un complemento rápido de `find -xtype l`.

**A9.7** `file` lee el comienzo (y a veces otros desplazamientos) del archivo y compara los bytes con una base de datos de **números mágicos** — firmas como `1f 8b` para gzip, `42 5a 68` (`BZh`) para bzip2, `fd 37 7a 58 5a 00` para xz, `7f 45 4c 46` (`\x7fELF`) para binarios ELF, y `ustar` en el desplazamiento 257 para tar POSIX. Solo si ninguna firma coincide recurre a heurísticas (análisis del conjunto de caracteres para "ASCII text", adivinación de idioma) y a un veredicto final de "data".

La base de datos vive en `/usr/share/misc/magic.mgc` (un binario compilado; la ruta varía: `/usr/share/file/magic.mgc` en algunas distribuciones), compilado desde reglas fuente en `/usr/share/misc/magic/` o `/etc/magic`; los usuarios pueden extenderla con `~/.magic` o `file -m`. La consecuencia que vale la pena interiorizar: en Unix la **extensión es una convención para humanos**, no tiene autoridad alguna y nada la comprueba en el kernel. `file` es la herramienta que responde la pregunta real, y `file -b --mime-type` es su forma apta para scripts.

**A9.8** `sha256sum -c` compara un resumen criptográfico de **todo el flujo de bytes**, así que un solo bit alterado o un byte añadido en cualquier parte cambia el resumen y falla. `tar -tzf` puede seguir funcionando porque el NUL añadido cayó **después** del final lógico del flujo gzip: el propio CRC32 de gzip cubre el miembro comprimido, y tar se detiene en el marcador de fin de archivo, así que ambos pueden alcanzar un punto de parada válido e ignorar la basura final. La corrupción *dentro* del flujo sí se habría detectado — `gzip -t` sí detectó el daño en medio del flujo en el Ejercicio 10 —, pero la corrupción en una región que ninguna de las dos herramientas lee es invisible para ellas.

En un script de verificación de copias de seguridad, usá **ambos, de barato a caro**:
1. `sha256sum -c manifiesto` — autoritativo sobre el archivo tal como se entregó, detecta cualquier desviación de bits, incluidos truncamiento y basura final;
2. `gzip -t` / `xz -t` — valida el CRC propio del flujo comprimido sin extraer;
3. `tar -tf` — demuestra que la estructura del archivo se interpreta y te deja contar miembros;
4. periódicamente, una **restauración de prueba real** en un directorio desechable seguida de `diff -r` o de una comparación de sumas de verificación por archivo.

Solo el paso 4 demuestra que la copia de seguridad se puede restaurar. Una copia de seguridad que nunca se restauró es una hipótesis, no una copia de seguridad.

---

### Bloque 10 — cierre

**A10.1** Cubren dos cosas distintas. `--exclude='cache'` coincide con el **directorio** `app/cache` por su nombre base y poda todo el subárbol — nada por debajo se llega siquiera a considerar. `--exclude='*.cache'` coincide con **archivos por sufijo** vivan donde vivan, incluido un `app/data/session.cache` extraviado fuera del directorio de caché.

Para este árbol concreto, `--exclude='cache'` solo habría bastado, ya que todos los archivos `*.cache` viven casualmente dentro. Mantener ambos hace que la regla exprese la *intención* ("nada de datos de caché, estén donde estén") en lugar del diseño actual, de modo que sigue siendo correcta cuando alguien deje más adelante un archivo de caché en otro sitio. Notá que los patrones de `--exclude` del tar de GNU se comparan contra el nombre del miembro y usan comodines por defecto, que `*` **sí** cruza `/` en los patrones de exclusión salvo que uses `--no-wildcards-match-slash`, y que las exclusiones deben aparecer **antes** de los operandos de archivo a los que aplican.

**A10.2** Un `diff -r` simple **sigue los enlaces simbólicos** y compara el contenido de sus destinos. `app/bin/app.conf` → `../conf/app.conf` se compararía como una copia del archivo de configuración, y saldría igual — incluso si la restauración lo hubiera materializado como un **archivo regular** en lugar de un enlace. Eso oculta una regresión real: un árbol restaurado donde los enlaces simbólicos se volvieron copias de archivos se rompe en cuanto alguien edita `conf/app.conf` y espera que `bin/app.conf` lo siga, y además duplica en silencio el tamaño de árboles con muchos enlaces.

`--no-dereference` hace que `diff` compare los enlaces en sí — informando `Symbolic links ... and ... differ` cuando un lado es un enlace y el otro no. Para verificación de archivos, la comprobación más fuerte es `tar -df backup.tar.gz` (compara el archivo contra el árbol vivo, incluidos tipo, modo, propietario y mtime) o un inventario `find -printf '%y %m %s %p\n'` comparado entre ambos árboles.

**A10.3** `-r` (`--no-run-if-empty`) impide que `xargs` ejecute el comando **una vez sin argumentos de archivo** cuando su entrada está vacía. En una noche en la que ningún log supera los 30 días, `find` no emite nada; sin `-r`, `xargs` igual ejecuta `gzip -v` con cero operandos, y `gzip` sin operandos **lee de stdin y escribe datos comprimidos en stdout** — lo que, en un trabajo de cron, significa que gzip se bloquea sobre un stdin vacío o emite basura binaria en el correo de salida del trabajo, y el estado de salida del trabajo pasa a ser distinto de cero. Con `-r`, `xargs` sale con 0 sin haber hecho nada, que es el comportamiento correcto para una rotación que no tiene nada que rotar.

(`-r` es una extensión GNU; el `xargs` de POSIX no tiene equivalente, lo que es una razón más para preferir `find -exec ... +`, que nunca ejecuta el comando con una lista de archivos vacía.)

**A10.4** `gzip -t` (`--test`) descomprime el flujo **sin escribir ninguna salida** y verifica los campos de integridad propios del formato: la firma mágica de la cabecera, la estructura del flujo DEFLATE, y el **CRC-32** y la longitud finales de los datos descomprimidos. Cualquier corrupción dentro del flujo comprimido produce `invalid compressed data--crc error` y estado de salida 1. Es barato — no escribe disco — y es la forma más rápida de rechazar un archivo defectuoso antes de gastar tiempo en extraerlo.

El manifiesto sha256 sigue valiendo la pena porque `gzip -t` valida solo **lo que el flujo gzip afirma sobre sí mismo**. No puede detectar: bytes añadidos después de que el flujo termina; una sustitución completa del archivo por otro archivo internamente válido; ni una manipulación deliberada, ya que un atacante que modifica el contenido simplemente recalcula el CRC-32 (una suma de verificación no criptográfica de 32 bits, trivial de falsificar). Un SHA-256 registrado en el momento de la creación y guardado por separado responde una pregunta distinta — "¿es este exactamente el archivo que hice?" — que es la pregunta que importa tanto para integridad como para procedencia.

**A10.5** La segunda ejecución encuentra `app-1.log.gz`, no `app-1.log`, así que la prueba `-name '*.log'` ya no coincide con él y queda intacto — esa parte está bien. El fallo aparece si la aplicación crea un **nuevo** `app-1.log` que más tarde supera los 30 días: `gzip` encuentra entonces que `app-1.log.gz` ya existe y se niega, preguntando `gzip: app-1.log.gz already exists; do you wish to overwrite (y or n)?`. En un trabajo de cron sin tty, `gzip` ve EOF en stdin, declina y sale con estado distinto de cero — el log nunca se comprime y el trabajo informa fallo todas las noches a partir de entonces.

Formas idempotentes:
- añadir un sufijo único: `find app/logs -name '*.log' -mtime +30 -exec sh -c 'gzip -c "$1" > "$1.$(date +%F).gz" && rm "$1"' _ {} \;`
- o dejar que `gzip` sobreescriba deliberadamente: `gzip -f`, aceptando que se pierde el archivo anterior;
- o, en producción, **no implementar la rotación a mano** — `logrotate` con `compress`, `delaycompress`, `dateext` y `rotate N` se ocupa del nombrado, la retención y la señal de reapertura al proceso que escribe, cosa que una tubería `find | gzip` no hace (comprimir un log que un demonio todavía tiene abierto no libera espacio hasta que el demonio lo reabre).

**A10.6**
```bash
cd "$LAB/nightly"
find app -depth -path 'app/cache' -prune -o ! -name '*.cache' -print0 \
  | cpio --null -o -H newc | gzip -c > backup.cpio.gz
```
**`tar` es claramente más fácil.** Las diferencias que importan:
- `tar` toma las exclusiones como opciones propias (`--exclude`), aplicadas durante su propia recursión; `cpio` no tiene ningún mecanismo de exclusión y hay que alimentarlo con una lista prefiltrada, así que toda la lógica de selección se traslada a una expresión de `find` con `-prune`/`-o`/`-print0`.
- `tar` comprime en línea con una sola opción (`-z`); `cpio` no comprime y necesita una tubería explícita, lo que además implica recordar `gunzip -c backup.cpio.gz | cpio -idmv` en el camino de vuelta.
- `tar` maneja internamente el orden `-depth`; con `cpio` hay que recordarlo.

La ventaja compensatoria — y la razón por la que `cpio` sigue existiendo — es exactamente ese desacoplamiento: como la lista de archivos es externa, **cualquier** selección que `find` pueda expresar (o cualquier otro programa que emita nombres de archivo, incluida una consulta a una base de datos) gobierna el archivo, sin que el archivador tenga que crecer una opción nueva. Eso, más la simplicidad del formato, es por lo que el initramfs del kernel es cpio y no tar.

</details>

---

## Trampas habituales del examen para 103.3

| Trampa | Modelo correcto |
|---|---|
| `cp -r src dst` se comporta distinto según exista o no `dst` | Un último argumento que sea un directorio existente ⇒ copia *dentro* de él. Usá `-T` o `src/.` para un comportamiento determinista |
| `-size -1M` "significa menos de 1 MB" | Los tamaños se redondean **hacia arriba** a la unidad; `-1M` solo coincide con archivos vacíos. Usá `c` para bytes exactos |
| `-mtime +7` "significa más viejo que una semana" | La edad se trunca a días enteros; `+7` significa **≥ 8 días** |
| `-maxdepth` colocado después de las pruebas | Las opciones globales no son posicionales — poné las justo después de las rutas |
| `-delete` combinado con `-prune` | `-delete` implica `-depth`, lo que convierte `-prune` en un no-op; usá `! -path ...` |
| `tar -cfz archive.tar.gz dir` | `-f` consume la palabra siguiente — debe ser la **última** letra del grupo |
| `tar -r` sobre un `.tar.gz` | Añadir solo funciona en un tar sin comprimir; un archivo comprimido es un único flujo sólido |
| La extracción como usuario normal da modo 755 en lugar de 777 | La umask se aplica salvo que uses `-p`; root recibe `-p` y `--same-owner` por defecto |
| `cpio -i` "no extrae nada" | Falta `-d`. El modismo es `cpio -idmv` |
| `cpio -i` omite un archivo en silencio | Por defecto conserva el archivo existente más nuevo; `-u` sobreescribe incondicionalmente |
| `dd seek=` sobre un archivo existente lo vacía | Sin `conv=notrunc`, la salida se abre con `O_TRUNC` |
| `dd count=` copia menos bytes de los esperados desde una tubería | `count` cuenta llamadas a `read()`; añadí `iflag=fullblock` |
| `find . -name *.txt` | Entrecomillá los patrones destinados al programa: `'*.txt'`. El shell expande primero los globs sin comillas |
| `rm *` pregunta de forma inesperada | Un archivo llamado `-i` se expandió dentro de la lista de argumentos. Usá `rm -- *` o `rm ./*` |
| `rm -rf .*` "elimina los archivos ocultos" | `.*` coincide con `..`; usá `.[!.]*` o `shopt -s dotglob` |
| `*` "coincide con todo" | Nunca coincide con un punto inicial, y no es una expresión regular — `.` es literal |

---

## Fuentes

- LPI — *Exam 101 Objectives (LPIC-1, version 5.0)*, objetivo 103.3: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- GNU Coreutils Manual — `cp`, `mv`, `rm`, `rmdir`, `mkdir`, `touch`, `ls`, `dd`, `sha256sum`: <https://www.gnu.org/software/coreutils/manual/coreutils.html>
- GNU Findutils Manual — `find`, `xargs`: <https://www.gnu.org/software/findutils/manual/html_mono/find.html>
- GNU Tar Manual: <https://www.gnu.org/software/tar/manual/tar.html>
- GNU Cpio Manual: <https://www.gnu.org/software/cpio/manual/cpio.html>
- GNU Gzip Manual: <https://www.gnu.org/software/gzip/manual/gzip.html>
- GNU Bash Reference Manual — *Filename Expansion* y *Pattern Matching*: <https://www.gnu.org/software/bash/manual/bash.html#Filename-Expansion>
- XZ Utils (página oficial del proyecto y documentación): <https://tukaani.org/xz/>
- bzip2 (página oficial del proyecto): <https://sourceware.org/bzip2/>
- El comando `file` y libmagic (proyecto oficial): <https://www.darwinsys.com/file/>
- Proyecto Linux man-pages — `stat(2)`, `rename(2)`, `symlink(7)`, `open(2)`: <https://www.kernel.org/doc/man-pages/>
- The Open Group Base Specifications Issue 8 — `cp`, `mv`, `rm`, `find`, `pax`, y *Pattern Matching Notation*: <https://pubs.opengroup.org/onlinepubs/9799919799/>