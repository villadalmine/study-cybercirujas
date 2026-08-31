# LPIC-1 — 104.7 Encontrar archivos del sistema y ubicar archivos en la ubicación correcta

**Examen:** 101-500 · **Peso:** 3.12 · **Versión del temario:** 5.0

**Alcance del objetivo** — Comprender las ubicaciones correctas de los archivos según el FHS; encontrar archivos y comandos en un sistema Linux; conocer la ubicación y el propósito de archivos y directorios importantes según los define el FHS.

**Términos y utilidades del examen:** `find`, `locate`, `updatedb`, `whereis`, `which`, `type`, `/etc/updatedb.conf`

**Fuentes de referencia**

- LPI Exam 101 Objectives — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- Filesystem Hierarchy Standard 3.0 (Linux Foundation) — <https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html>
- Manual de GNU findutils — <https://www.gnu.org/software/findutils/manual/html_mono/find.html>
- `find(1)` — <https://man7.org/linux/man-pages/man1/find.1.html>
- `whereis(1)` — <https://man7.org/linux/man-pages/man1/whereis.1.html>
- `updatedb.conf(5)` — <https://man7.org/linux/man-pages/man5/updatedb.conf.5.html>
- Bash Reference Manual, Bourne Shell Builtins (`type`, `hash`) — <https://www.gnu.org/software/bash/manual/bash.html#Bash-Builtins>
- plocate — <https://plocate.sesse.net/>

---

## Entorno de laboratorio

Cualquier sistema Linux actual con GNU findutils y `sudo`. Las salidas que siguen fueron capturadas en **Debian 12 (bookworm)** con `plocate`; en **RHEL 8/9** la implementación de locate es `mlocate` y la ruta de la base de datos difiere — se señala donde importa. La salida byte a byte va a diferir en tu máquina; lo que tenés que reconocer es la *forma* de la salida.

Ejecutá cada paso vos mismo. Leer los comandos no es el ejercicio.

### Paso 0 — Construir el árbol de pruebas

```bash
export LAB="$HOME/lpic1-104.7"
rm -rf "$LAB"
mkdir -p "$LAB"/{app/{bin,etc,logs},data/{2024,2025,2026},junk,.cache}
cd "$LAB"

head -c 900     /dev/urandom > junk/small.bin
head -c 2097152 /dev/urandom > data/2026/report.bin
truncate -s 15M               data/2025/archive.bin      # sparse on purpose
: > junk/empty.log

printf '#!/bin/sh\necho hi\n' > app/bin/hello.sh && chmod 0755 app/bin/hello.sh
printf 'key=value\n'          > app/etc/hello.conf && chmod 0600 app/etc/hello.conf
printf 'secret\n'             > app/etc/token.conf && chmod 0666 app/etc/token.conf

: > 'app/logs/name with spaces.log'
: > $'app/logs/weird\tname.log'
: > .cache/hidden.tmp

ln -s ../bin/hello.sh app/etc/hello-link
ln -s /nonexistent    app/etc/broken-link

touch -d '2024-03-01 10:00' data/2024/old.txt
touch -d '2025-11-15 10:00' data/2025/mid.txt
touch                       data/2026/new.txt

find "$LAB" -printf '%y %10s %p\n' | sort -k3
```

Forma esperada:

```
d       4096 /home/you/lpic1-104.7
d       4096 /home/you/lpic1-104.7/.cache
f          0 /home/you/lpic1-104.7/.cache/hidden.tmp
d       4096 /home/you/lpic1-104.7/app
d       4096 /home/you/lpic1-104.7/app/bin
f         18 /home/you/lpic1-104.7/app/bin/hello.sh
d       4096 /home/you/lpic1-104.7/app/etc
l         14 /home/you/lpic1-104.7/app/etc/broken-link
l         15 /home/you/lpic1-104.7/app/etc/hello-link
f         10 /home/you/lpic1-104.7/app/etc/hello.conf
f          7 /home/you/lpic1-104.7/app/etc/token.conf
...
f   15728640 /home/you/lpic1-104.7/data/2025/archive.bin
```

---

## Bloque 1 — Leer el FHS desde un sistema en vivo

El FHS no es trivia para memorizar en abstracto; es un conjunto de *predicados* que podés verificar en una máquina en funcionamiento. Este bloque te hace verificarlos.

### Pasos

1. Mirá el nivel superior y fijate cuáles entradas son enlaces simbólicos:

   ```bash
   ls -ld /bin /sbin /lib /lib64 /usr/bin /usr/sbin /usr/lib 2>/dev/null
   ```

   En una distribución moderna con `/usr` fusionado (merged-`/usr`):

   ```
   lrwxrwxrwx  1 root root    7 Jul 10  2025 /bin -> usr/bin
   lrwxrwxrwx  1 root root    9 Jul 10  2025 /lib -> usr/lib
   lrwxrwxrwx  1 root root    9 Jul 10  2025 /lib64 -> usr/lib64
   lrwxrwxrwx  1 root root    8 Jul 10  2025 /sbin -> usr/sbin
   drwxr-xr-x  2 root root 61440 Aug 20 09:14 /usr/bin
   drwxr-xr-x  2 root root 20480 Aug 19 22:03 /usr/sbin
   ```

2. Resolvelos y confirmá la ubicación física:

   ```bash
   readlink -f /bin /sbin /lib
   ```

3. Verificá lo mismo para los dos directorios de runtime del FHS 3.0:

   ```bash
   ls -ld /run /var/run /var/lock
   findmnt -no TARGET,FSTYPE,OPTIONS /run
   ```

   ```
   drwxr-xr-x 34 root root      920 Aug 26 08:41 /run
   lrwxrwxrwx  1 root root        4 Jul 10  2025 /var/run -> /run
   lrwxrwxrwx  1 root root        9 Jul 10  2025 /var/lock -> /run/lock
   /run tmpfs rw,nosuid,nodev,noexec,relatime,size=1608268k,mode=755
   ```

4. Preguntale al kernel qué sistema de archivos respalda `/tmp` y `/var/tmp`:

   ```bash
   stat -f -c '%n: %T' /tmp /var/tmp /run /proc /sys
   ```

   ```
   /tmp: tmpfs
   /var/tmp: ext2/ext3
   /run: tmpfs
   /proc: proc
   /sys: sysfs
   ```

5. Enumerá qué vive realmente en `/var` y en `/usr/share` en tu sistema:

   ```bash
   ls -1 /var
   ls -1 /usr/share | head -20
   ```

6. Confirmá la regla del FHS de que `/etc` no contiene binarios — es decir, ningún archivo regular con algún bit de ejecución que además sea un programa ELF real:

   ```bash
   find /etc -maxdepth 1 -type f -perm /111 -exec file {} + 2>/dev/null | head
   ```

   Típicamente vas a ver scripts de shell (`/etc/rc.local`) pero ningún ejecutable compilado. Los scripts se toleran en la práctica; la prohibición del FHS es sobre *binarios*.

7. Mirá un paquete que siga la convención de `/opt`, si tenés alguno, y fijate en la división en tres partes:

   ```bash
   ls -d /opt/* /etc/opt/* /var/opt/* 2>/dev/null
   ```

8. Mostrá la diferencia entre una jerarquía gestionada por la distribución y la jerarquía local del administrador:

   ```bash
   ls -d /usr/local/*
   ```

   ```
   /usr/local/bin  /usr/local/etc  /usr/local/games  /usr/local/include
   /usr/local/lib  /usr/local/man  /usr/local/sbin   /usr/local/share  /usr/local/src
   ```

### Preguntas de comprensión — Bloque 1

- **Q1.1** — En un sistema con `/usr` fusionado, `/bin` es un enlace simbólico a `usr/bin` (relativo), no a `/usr/bin` (absoluto). ¿Por qué importa la forma relativa?
- **Q1.2** — El FHS 3.0 divide la jerarquía según dos ejes independientes. Nombralos, y ubicá `/usr`, `/var`, `/etc` y `/home` en ambos ejes.
- **Q1.3** — Un cron job escribe un archivo intermedio de 4 GB que debe sobrevivir a un reinicio pero no son datos de usuario. ¿`/tmp` o `/var/tmp`? Justificá desde el texto del FHS, no desde la costumbre.
- **Q1.4** — ¿Por qué `/run` es un tmpfs montado con `nosuid,nodev`, y a qué directorio de la era FHS 2.3 reemplazó?
- **Q1.5** — Compilás nginx desde el código fuente con `./configure --prefix=???`. Dá el prefijo correcto y decí dónde deben ir su configuración y sus logs. Después dá la respuesta correcta para el *otro* caso: un proveedor te entrega un tarball autocontenido `acme-crm` con sus propias bibliotecas.
- **Q1.6** — `/proc` y `/sys` no están en los capítulos 3 a 5 del FHS 3.0. ¿Dónde se especifican, y qué te dice eso sobre su portabilidad?
- **Q1.7** — ¿Cuál de `/usr/local/man` y `/usr/local/share/man` designa el FHS 3.0, y cuál es el estado del otro?

---

## Bloque 2 — Localizar *comandos*: `type`, `which`, `whereis`

Tres herramientas, tres preguntas distintas. Confundirlas es el error más común en este objetivo.

### Pasos

1. Preguntale al shell qué ejecutaría realmente:

   ```bash
   type ls
   type cd
   type if
   type -a echo
   ```

   ```
   ls is aliased to `ls --color=auto'
   cd is a shell builtin
   if is a shell keyword
   echo is a shell builtin
   echo is /usr/bin/echo
   ```

2. Obtené solo la clasificación, y después forzá una búsqueda que solo mire el PATH:

   ```bash
   type -t ls; type -t cd; type -t if; type -t echo
   type -P echo
   type -P ls
   ```

   ```
   alias
   builtin
   keyword
   builtin
   /usr/bin/echo
   /usr/bin/ls
   ```

3. Compará con `which` y con el builtin POSIX:

   ```bash
   which echo
   command -v echo
   command -v cd
   which cd; echo "exit=$?"
   ```

   ```
   /usr/bin/echo
   echo
   cd
   which: no cd in (/usr/local/bin:/usr/bin:/bin:...)
   exit=1
   ```

4. Observá la tabla hash del shell — la razón por la que `which` puede discrepar con la realidad:

   ```bash
   hash -r
   type ls >/dev/null; ls >/dev/null
   type ls
   hash
   ```

   ```
   ls is aliased to `ls --color=auto'
   hits	command
      1	/usr/bin/ls
   ```

5. Reproducí la trampa clásica del hash desactualizado:

   ```bash
   mkdir -p ~/bin && printf '#!/bin/sh\necho FIRST\n' > ~/bin/probe && chmod +x ~/bin/probe
   export PATH="$HOME/bin:$PATH"
   hash -r
   probe                       # -> FIRST
   printf '#!/bin/sh\necho SECOND\n' > /tmp/probe && chmod +x /tmp/probe
   export PATH="/tmp:$PATH"
   which probe                 # -> /tmp/probe
   probe                       # -> ?
   type probe
   hash -r; probe              # -> ?
   ```

6. Ahora hacé la pregunta de *empaquetado* en vez de la de *ejecución*:

   ```bash
   whereis passwd
   whereis -b passwd
   whereis -m passwd
   whereis -s passwd
   ```

   ```
   passwd: /usr/bin/passwd /etc/passwd /etc/passwd.org /usr/share/man/man1/passwd.1.gz /usr/share/man/man5/passwd.5.gz
   passwd: /usr/bin/passwd /etc/passwd /etc/passwd.org
   passwd: /usr/share/man/man1/passwd.1.gz /usr/share/man/man5/passwd.5.gz
   passwd:
   ```

7. Mostrá dónde busca `whereis`, y demostrá que no es solo `$PATH`:

   ```bash
   whereis -l | head -20
   whereis -u -m -B /usr/bin -f probe          # -B needs -f to terminate the dir list
   ```

8. Ejecutá las tres contra un comando que no existe y compará los códigos de salida:

   ```bash
   type nosuchcmd;  echo "type=$?"
   which nosuchcmd; echo "which=$?"
   whereis nosuchcmd; echo "whereis=$?"
   ```

   ```
   bash: type: nosuchcmd: not found
   type=1
   which=1
   nosuchcmd:
   whereis=0
   ```

### Preguntas de comprensión — Bloque 2

- **Q2.1** — Dá en una oración la pregunta que responde cada uno de `type`, `which`, `whereis`. ¿Cuál de los tres es un builtin del shell, y por qué eso lo hace autoritativo?
- **Q2.2** — En el paso 5, ¿qué imprimió el `probe` a secas inmediatamente después de anteponer `/tmp` al `PATH`, y por qué `which probe` discrepó con eso?
- **Q2.3** — `which cd` falla mientras que `command -v cd` tiene éxito. Explicá, y decí cuál debería usar un script portable.
- **Q2.4** — `whereis nosuchcmd` sale con 0. ¿Cuál es la consecuencia operativa para un script que prueba la disponibilidad de un comando con `whereis -b foo >/dev/null && ...`?
- **Q2.5** — El `which` de Debian vive en el paquete `debianutils` y está siendo deprecado. ¿Cuál es el reemplazo recomendado, y cuál es la única capacidad de `which -a` que tenés que reproducir de otra manera?
- **Q2.6** — Tu `PATH` contiene `/usr/local/bin` antes que `/usr/bin`. `type -a python3` lista ambos. ¿Cuál se ejecuta, y qué único comando te muestra la ruta resuelta sin ejecutarlo?
- **Q2.7** — ¿Por qué `whereis` devuelve `/etc/passwd` cuando se le pregunta por el *comando* `passwd`? ¿Es eso un bug?

---

## Bloque 3 — `find`: el motor de expresiones

`find` no es un comando de búsqueda con flags. Es un evaluador de expresiones: recorre un árbol y evalúa una expresión booleana contra cada nodo, con semántica de cortocircuito. Cada "flag" es un *test*, una *acción* (que también devuelve un booleano) o un *operador*. Una vez que internalizás eso, los comportamientos sorprendentes dejan de sorprender.

### Pasos

1. Establecé la anatomía. Estos tres son equivalentes:

   ```bash
   cd "$LAB"
   find . -name '*.conf'
   find . -name '*.conf' -print
   find . -a -name '*.conf' -a -print
   ```

   El operador implícito entre predicados es `-a` (AND); la acción implícita cuando no se da ninguna es `-print`.

2. Demostrá la evaluación con cortocircuito usando un efecto colateral:

   ```bash
   find . -type f -printf 'TEST %p\n' -a -name '*.bin' -printf 'MATCH %p\n' | head
   ```

   Notá que `-printf` devuelve verdadero, así que la evaluación continúa; `TEST` se imprime para cada archivo, `MATCH` solo para los `.bin`.

3. Filtrá por tipo. Ejecutá cada uno y contá:

   ```bash
   find . -type f | wc -l
   find . -type d | wc -l
   find . -type l -printf '%p -> %l\n'
   ```

   ```
   app/etc/broken-link -> /nonexistent
   app/etc/hello-link -> ../bin/hello.sh
   ```

4. Nombre vs ruta vs regex:

   ```bash
   find . -name 'hello*'
   find . -iname 'HELLO*'
   find . -path '*/app/etc/*'
   find . -regex '.*/data/20[0-9][0-9]/.*\.txt'
   ```

   Nota: `-name` matchea *solo el basename*, y sus metacaracteres de glob **no** se detienen en `/` — pero como solo llega a ver un basename, eso es irrelevante. `-path` matchea la ruta completa tal como se imprime, y su `*` **sí** cruza `/`.

5. Control de profundidad — y mirá la advertencia que emite GNU cuando equivocás el orden:

   ```bash
   find . -maxdepth 2 -type d
   find . -type d -maxdepth 2
   ```

   ```
   find: warning: you have specified the global option -maxdepth after the argument -type,
   but global options are not positional, i.e., -maxdepth affects tests specified before it
   as well as those specified after it.  Please specify global options before other arguments.
   ```

6. Tamaño — y la trampa del redondeo:

   ```bash
   find . -type f -size +1M -printf '%10s %p\n'
   find . -type f -size -1M -printf '%10s %p\n'
   find . -type f -size -1M -size +0 -printf '%10s %p\n'
   find . -type f -size +900c -size -2000c -printf '%10s %p\n'
   ```

   ```
     2097152 ./data/2026/report.bin
    15728640 ./data/2025/archive.bin
           0 ./junk/empty.log
           0 ./.cache/hidden.tmp
           0 ./app/logs/name with spaces.log
           0 ./app/logs/weird	name.log
   (third command prints nothing)
   (fourth command prints nothing)
   ```

7. Enfrentá la cuestión de los archivos dispersos (sparse):

   ```bash
   ls -l  data/2025/archive.bin
   du -h  data/2025/archive.bin
   find data/2025 -name archive.bin -printf 'st_size=%s  blocks512=%b  du_k=%k\n'
   ```

   ```
   -rw-r--r-- 1 you you 15728640 Aug 26 08:52 data/2025/archive.bin
   0	data/2025/archive.bin
   st_size=15728640  blocks512=0  du_k=0
   ```

8. Tests de tiempo. Las unidades de `-mtime` son períodos de 24 horas, truncados hacia cero:

   ```bash
   find data -type f -mtime +365  -printf '%TY-%Tm-%Td %p\n'
   find data -type f -mmin  -10   -printf '%TY-%Tm-%Td %TH:%TM %p\n'
   find data -type f -newermt '2025-01-01' ! -newermt '2026-01-01' -printf '%TF %p\n'
   find data -type f -newer data/2025/mid.txt -printf '%TF %p\n'
   ```

9. Permisos — los tres modos de coincidencia:

   ```bash
   find app -type f -perm 0644          # exactly 0644
   find app -type f -perm -0044         # r for group AND r for other, plus anything else
   find app -type f -perm /0022         # writable by group OR by other
   find app -type f -perm -0111         # executable by u AND g AND o
   ```

10. Combiná con paréntesis y negación — y prestá atención al quoting del shell:

    ```bash
    find . \( -name '*.conf' -o -name '*.log' \) -a -type f -printf '%M %p\n'
    find . -type f ! -name '*.bin' -printf '%p\n'
    ```

11. `-prune` — saltear subárboles. Leé este con atención:

    ```bash
    find . -name .cache -prune -o -type f -print
    find . -name .cache -prune -o -type f            # WRONG: what changed?
    ```

12. `-xdev` — quedarse en un solo sistema de archivos, la defensa estándar al escanear `/`:

    ```bash
    sudo find / -xdev -maxdepth 2 -name '*.conf' 2>/dev/null | wc -l
    sudo find /      -maxdepth 2 -name '*.conf' 2>/dev/null | wc -l
    ```

13. Acciones: `-exec` en ambas formas, y `-execdir`:

    ```bash
    find . -name '*.conf' -exec sha256sum {} \;      # one process per file
    find . -name '*.conf' -exec sha256sum {} +       # batched, argv-limited
    find . -name '*.conf' -execdir sha256sum {} \;   # runs with cwd = the file's directory
    ```

    Cronometrá la diferencia a escala:

    ```bash
    time find /usr/share/doc -type f -exec true {} \;
    time find /usr/share/doc -type f -exec true {} +
    ```

14. Nombres de archivo hostiles. Por esto existe `-print0`:

    ```bash
    find app/logs -type f | wc -l
    find app/logs -type f | xargs ls -l 2>&1 | tail -3          # breaks
    find app/logs -type f -print0 | xargs -0 ls -l              # correct
    find app/logs -type f -exec ls -l {} +                      # also correct, no pipe
    ```

15. Manejo de enlaces simbólicos — `-P` (por defecto), `-L`, `-H`:

    ```bash
    find app/etc -type l                  # implicit -P
    find -P app/etc -type l
    find -L app/etc -type l               # what appears here, and why?
    find -L app/etc -type f
    find -L app/etc -xtype l
    ```

16. One-liners de diagnóstico que vas a usar de verdad en producción:

    ```bash
    # setuid/setgid binaries outside package-managed trust boundaries
    sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%M %u:%g %p\n' 2>/dev/null

    # world-writable directories missing the sticky bit
    sudo find / -xdev -type d -perm -0002 ! -perm -1000 -print 2>/dev/null

    # files with no valid owner (left behind by a deleted user/UID)
    sudo find / -xdev \( -nouser -o -nogroup \) -printf '%U:%G %p\n' 2>/dev/null

    # top 10 space consumers
    sudo find /var -xdev -type f -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -10

    # config changed in the last 24 h — the "what did I break" query
    sudo find /etc -xdev -type f -mtime -1 -printf '%TF %TT %p\n' 2>/dev/null | sort

    # empty files and empty directories
    find "$LAB" -empty -printf '%y %p\n'

    # hardlink forensics
    find /usr/bin -type f -links +1 -printf '%i %n %p\n' | sort -n | head
    ```

17. Código de salida y terminación temprana:

    ```bash
    find "$LAB" -name nonexistent-name; echo "exit=$?"
    find /root -name '*' >/dev/null;     echo "exit=$?"     # as a normal user
    find /usr -name 'bash' -print -quit; echo "exit=$?"
    ```

### Preguntas de comprensión — Bloque 3

- **Q3.1** — En el paso 11, el segundo comando dejó afuera el `-print`. Describí exactamente qué cambió en la salida y explicalo en términos de la regla del `-print` implícito.
- **Q3.2** — `find . -type f -size -1M` imprimió solamente archivos de cero bytes. Explicá la regla de redondeo y reescribí el comando para que signifique "más chico que un mebibyte pero no vacío".
- **Q3.3** — `du` dice 0 y `ls -l` dice 15 MiB para `archive.bin`, y sin embargo `find -size +10M` lo matchea. ¿Qué campo de stat usa `find -size`, y cuál es el riesgo práctico cuando usás `find -size` para cazar consumidores de espacio en disco?
- **Q3.4** — Distinguí con precisión `-perm 0644`, `-perm -0644` y `-perm /0644`. ¿Qué pasó con `-perm +0644`?
- **Q3.5** — ¿Por qué `-mtime +7` **no** significa "más viejo que 7 días" en la forma en que la mayoría lo lee? Decí qué significa realmente, y dá la opción que hace que el límite caiga a medianoche en vez de "ahora menos N×24 h".
- **Q3.6** — Compará `-exec cmd {} \;` y `-exec cmd {} +` en: cantidad de procesos, límites de longitud de argumentos, propagación del código de salida, y si `{}` puede aparecer más de una vez.
- **Q3.7** — ¿Por qué se prefiere `-execdir` sobre `-exec` cuando el árbol puede ser escribible por un usuario no confiable?
- **Q3.8** — En el paso 15, `find -L app/etc -type l` imprimió `broken-link` y no `hello-link`. Explicá ambas mitades de ese resultado, y decí qué hace distinto `-xtype l`.
- **Q3.9** — `find /etc -name '*.conf' | xargs grep -l root` es un modismo ampliamente copiado. Dá dos formas independientes en las que puede fallar y las dos reescrituras seguras.
- **Q3.10** — ¿Cuál es el código de salida de `find` cuando produjo la salida correcta pero se le denegó el acceso a algún subdirectorio? ¿Qué implica eso para scripts con `set -e` y para `find ... 2>/dev/null`?
- **Q3.11** — Tenés que borrar de forma segura todos los `*.tmp` bajo `/srv` con más de 30 días. Escribí el comando usando `-delete`, y después indicá los dos efectos colaterales de comportamiento que tiene `-delete` y que `-exec rm {} +` no tiene.
- **Q3.12** — ¿Por qué la advertencia de `-maxdepth` del paso 5 lo llamó una opción *global* en vez de un test?

---

## Bloque 4 — `locate`, `updatedb`, `/etc/updatedb.conf`

`find` recorre el sistema de archivos ahora. `locate` consulta una base de datos construida antes. Todo lo que los distingue se deriva de esa única oración.

### Pasos

1. Identificá qué implementación tenés:

   ```bash
   locate --version | head -1
   readlink -f "$(command -v locate)"
   ls -l /usr/bin/locate /usr/bin/plocate /usr/bin/mlocate 2>/dev/null
   ```

   ```
   plocate 1.1.15
   /usr/bin/plocate
   lrwxrwxrwx 1 root root      7 Apr  8  2023 /usr/bin/locate -> plocate
   -rwxr-sr-x 1 root plocate 71K Apr  8  2023 /usr/bin/plocate
   ```

   Notá el `-rwxr-s---`/`-rwxr-sr-x`: el binario es **setgid**, no setuid.

2. Encontrá la base de datos e inspeccioná su propiedad:

   ```bash
   ls -l /var/lib/plocate/plocate.db 2>/dev/null || ls -l /var/lib/mlocate/mlocate.db
   stat -c '%n %s bytes, %U:%G, %A' /var/lib/plocate/plocate.db 2>/dev/null
   ```

   ```
   /var/lib/plocate/plocate.db 12582912 bytes, root:plocate, -rw-r-----
   ```

3. Leé el archivo de configuración:

   ```bash
   cat /etc/updatedb.conf
   ```

   ```
   PRUNE_BIND_MOUNTS="yes"
   PRUNENAMES=".git .bzr .hg .svn"
   PRUNEPATHS="/tmp /var/spool /media /var/lib/os-prober /var/lib/ceph /home/.ecryptfs /var/lib/schroot"
   PRUNEFS="NFS afs autofs binfmt_misc ceph cgroup cgroup2 cifs coda configfs curlftpfs debugfs devfs
   devpts devtmpfs ecryptfs ftpfs fuse.ceph fuse.glusterfs fuse.sshfs fusectl gfs gfs2 hugetlbfs
   iso9660 lustre mfs ncpfs nfs nfs4 nfsd proc ramfs rpc_pipefs securityfs selinuxfs smbfs sysfs
   tmpfs tracefs udf usbfs vboxsf"
   ```

4. Mirá cuándo y cómo se refresca:

   ```bash
   systemctl list-timers '*updatedb*' --all
   systemctl cat plocate-updatedb.timer 2>/dev/null || systemctl cat updatedb.timer
   ls -l /etc/cron.daily/*locate* 2>/dev/null
   ```

5. Consultá con la base de datos tal como está, y después observá la desactualización:

   ```bash
   locate -c hello.conf
   touch "$LAB/marker-$$.conf"
   locate "marker-$$"            ; echo "exit=$?"
   sudo updatedb
   locate "marker-$$"            ; echo "exit=$?"
   rm "$LAB/marker-$$.conf"
   locate "marker-$$"            ; echo "exit=$?"
   locate -e "marker-$$"         ; echo "exit=$?"
   ```

6. Semántica de patrones — los comodines implícitos:

   ```bash
   locate -c bash
   locate -c '*bash*'
   locate -c '/bin/bash'
   locate -b bash | head -5
   locate -b '\bash'                 # exact basename, the backslash disables implicit globbing
   ```

7. Plegado de mayúsculas, regex y límites:

   ```bash
   locate -i README | head -3
   locate --regex '/usr/share/man/man5/.*passwd.*' 
   locate -l 5 conf
   locate -0 conf | head -c 200 | xxd | head -3
   ```

8. Demostrá el filtro de privacidad. `locate` no debe filtrar rutas que quien lo invoca no puede ver:

   ```bash
   sudo install -d -m 0700 /root/private-dir
   sudo touch /root/private-dir/topsecret-marker.txt
   sudo updatedb
   locate topsecret-marker          ; echo "user exit=$?"
   sudo locate topsecret-marker     ; echo "root exit=$?"
   ```

   ```
   user exit=1
   /root/private-dir/topsecret-marker.txt
   root exit=0
   ```

9. Construí una base de datos **privada y sin privilegios** — la técnica que convierte a `locate` en un índice por proyecto:

   ```bash
   updatedb -l 0 -U "$LAB" -o "$LAB/../lab.db"
   locate -d "$LAB/../lab.db" -c conf
   locate -d "$LAB/../lab.db" '*.bin'
   ```

   ```
   2
   /home/you/lpic1-104.7/data/2025/archive.bin
   /home/you/lpic1-104.7/data/2026/report.bin
   /home/you/lpic1-104.7/junk/small.bin
   ```

10. Ejercitá las perillas de poda contra tu propio árbol:

    ```bash
    updatedb -l 0 -U "$LAB" -n '.cache' -o "$LAB/../lab-pruned.db"
    locate -d "$LAB/../lab-pruned.db" hidden.tmp   ; echo "exit=$?"

    updatedb -l 0 -U "$LAB" -e "$LAB/junk" -o "$LAB/../lab-nojunk.db"
    locate -d "$LAB/../lab-nojunk.db" small.bin    ; echo "exit=$?"
    ```

11. Compará el costo directamente:

    ```bash
    time locate -c '*.service'
    time sudo find / -xdev -name '*.service' 2>/dev/null | wc -l
    ```

### Preguntas de comprensión — Bloque 4

- **Q4.1** — Nombrá las cuatro directivas de `/etc/updatedb.conf` y decí con precisión qué excluye cada una. ¿Cuál toma *nombres de directorio* en vez de rutas, y acepta comodines?
- **Q4.2** — `tmpfs` y `nfs` están ambos en `PRUNEFS`, por razones opuestas. Dá la razón de cada uno.
- **Q4.3** — En el paso 5, `locate "marker-$$"` todavía devolvió la ruta después de que borraste el archivo. Explicá, dá la opción que suprime los aciertos obsoletos, y decí qué cuesta esa opción.
- **Q4.4** — `locate bash` y `locate '*bash*'` devolvieron el mismo conteo, pero `locate '/bin/bash'` no. Enunciá la regla de patrones que explica los tres casos.
- **Q4.5** — El binario `locate` es setgid, no setuid. Explicá el modelo de seguridad: qué grupo, qué posee ese grupo, y qué se rompería si la base de datos tuviera modo `0644`.
- **Q4.6** — ¿Qué cambia `updatedb --require-visibility 0` en la base de datos resultante, y por qué es la elección correcta para la base de datos privada del paso 9 pero la elección equivocada para `/var/lib/plocate/plocate.db`?
- **Q4.7** — Un usuario informa que un archivo que creó hace cinco minutos "no está en el sistema" porque `locate` no lo encuentra. Dá el diagnóstico en dos líneas y la herramienta correcta.
- **Q4.8** — En un servidor de archivos de 4 TB respaldado por NFS, `updatedb` tarda 40 minutos y satura el montaje. Dá dos cambios de configuración que lo arreglen e indicá el compromiso de cada uno.
- **Q4.9** — `find` versus `locate`: dá cuatro ejes de comparación (frescura, costo, predicados de metadatos, privilegio) e indicá, para cada uno, qué herramienta gana.

---

## Bloque 5 — Decisiones de ubicación: poner los archivos en la ubicación *correcta*

El título del objetivo tiene dos mitades. Este bloque es la segunda mitad.

### Pasos

1. Instalá un script construido localmente de la forma correcta según el FHS y verificá que sea alcanzable:

   ```bash
   sudo install -D -m 0755 "$LAB/app/bin/hello.sh" /usr/local/bin/hello
   type hello
   which hello
   whereis -b hello
   hello
   ```

2. Agregale una página de manual en el lugar correcto y confirmá que la jerarquía de man la levante:

   ```bash
   sudo install -d /usr/local/share/man/man1
   printf '.TH HELLO 1\n.SH NAME\nhello \\- print hi\n' \
     | sudo tee /usr/local/share/man/man1/hello.1 >/dev/null
   manpath
   man -w hello
   whereis -m hello
   ```

3. Ahora hacé lo mismo **mal**, y detectalo:

   ```bash
   sudo install -D -m 0755 "$LAB/app/bin/hello.sh" /usr/bin/hello-bad
   dpkg -S /usr/bin/hello-bad 2>&1 || rpm -qf /usr/bin/hello-bad 2>&1
   ```

   ```
   dpkg-query: no path found matching pattern /usr/bin/hello-bad
   ```

   Ese "no path found" es la firma de un archivo que el gestor de paquetes no posee — un archivo que una actualización de la distribución puede sobrescribir silenciosamente o que un escaneo de integridad va a marcar.

4. Barré todo el sistema buscando esa clase de error (familia Debian):

   ```bash
   sudo find /usr/bin /usr/sbin -xdev -type f -print0 \
     | xargs -0 -n 200 dpkg -S 2>&1 >/dev/null \
     | sed 's/^dpkg-query: no path found matching pattern //' | head
   ```

   Familia RPM:

   ```bash
   sudo find /usr/bin /usr/sbin -xdev -type f -exec rpm -qf --qf '' {} \; 2>&1 \
     | grep 'not owned' | head
   ```

5. Disponé un paquete de proveedor a la manera de `/opt` y demostrá la división en tres:

   ```bash
   sudo install -d /opt/acme-crm/{bin,lib} /etc/opt/acme-crm /var/opt/acme-crm/{log,spool}
   sudo install -m 0755 "$LAB/app/bin/hello.sh" /opt/acme-crm/bin/acme
   sudo install -m 0640 "$LAB/app/etc/hello.conf" /etc/opt/acme-crm/acme.conf
   find /opt/acme-crm /etc/opt/acme-crm /var/opt/acme-crm -printf '%y %M %p\n'
   ```

6. Ubicá datos de servicio y contrastalos con las alternativas:

   ```bash
   sudo install -d -m 0755 /srv/www/example.com
   echo ok | sudo tee /srv/www/example.com/index.html >/dev/null
   stat -c '%n %U:%G %A' /srv/www/example.com/index.html
   ```

7. Estado de runtime — la forma moderna, amigable con systemd:

   ```bash
   sudo install -d -m 0755 -o root -g root /run/acme
   findmnt -no FSTYPE /run
   printf 'd /run/acme 0755 root root -\n' | sudo tee /etc/tmpfiles.d/acme.conf >/dev/null
   sudo systemd-tmpfiles --create /etc/tmpfiles.d/acme.conf
   ls -ld /run/acme
   ```

8. Limpiá el laboratorio (hacelo — si no, estás dejando archivos propiedad de root):

   ```bash
   sudo rm -f  /usr/local/bin/hello /usr/bin/hello-bad \
               /usr/local/share/man/man1/hello.1 \
               /etc/tmpfiles.d/acme.conf
   sudo rm -rf /opt/acme-crm /etc/opt/acme-crm /var/opt/acme-crm \
               /srv/www/example.com /run/acme /root/private-dir
   rm -f "$LAB/../lab.db" "$LAB/../lab-pruned.db" "$LAB/../lab-nojunk.db"
   sudo updatedb
   hash -r
   ```

### Preguntas de comprensión — Bloque 5

- **Q5.1** — Para cada ítem, nombrá el único directorio correcto según el FHS y una oración de justificación: (a) un script de Python que escribiste solo para este host; (b) un sitio estático servido por nginx; (c) un directorio de datos de PostgreSQL; (d) un archivo PID; (e) una unidad de systemd provista por un paquete de la distro; (f) una unidad de systemd que escribiste vos; (g) una biblioteca compartida compilada localmente; (h) el tarball de código fuente desde el que la compilaste; (i) un certificado de CA para una PKI interna; (j) un volcado nocturno de base de datos de 200 MB que se conserva 7 días.
- **Q5.2** — En el paso 3, `dpkg -S` dijo "no path found". ¿Por qué eso es específicamente un *problema* para `/usr/bin/hello-bad` pero *esperado y correcto* para `/usr/local/bin/hello`?
- **Q5.3** — `/srv` versus `/var/www` versus `/opt/<vendor>/www`. ¿Cuál designa el FHS 3.0 para datos servidos por el sitio, y por qué Debian y RHEL igual ambos incluyen `/var/www`?
- **Q5.4** — Explicá el trío `/opt` ⇄ `/etc/opt` ⇄ `/var/opt`. ¿Por qué el FHS le prohíbe a un paquete escribir su configuración bajo `/opt/<pkg>/etc`?
- **Q5.5** — Pusiste un archivo de unidad en `/usr/local/lib/systemd/system/`. ¿Es correcto según el FHS? ¿Es *funcional*? Reconciliá las dos respuestas.
- **Q5.6** — ¿Por qué `install -D -m 0755` es preferible a `cp` + `chmod` en un script de aprovisionamiento? Nombrá dos propiedades que te da `install`.
- **Q5.7** — Después del paso 1, `type hello` funcionó de inmediato. Después del `rm` del paso 8, `hello` puede seguir "funcionando" hasta que ejecutes `hash -r`. ¿Qué mecanismo causa eso, y cuál de `type`/`which`/`whereis` te habría mostrado la verdad?
- **Q5.8** — Dado `/usr/local/share/man/man1/hello.1`, explicá cómo `man` lo encontró sin ninguna configuración. Nombrá el mecanismo y el archivo que lo gobierna.

---

## Bloque 6 — Integración: una corrida de diagnóstico

Un escenario, las cuatro herramientas.

### Pasos

1. Un despliegue entregó un binario llamado `report-gen` y "no se encuentra". Recorré la escalera:

   ```bash
   type -a report-gen        2>&1
   command -v report-gen     2>&1
   whereis -b report-gen
   locate -b '\report-gen'
   sudo find / -xdev -type f -name 'report-gen' -printf '%M %u:%g %10s %TF %p\n' 2>/dev/null
   echo "$PATH" | tr ':' '\n'
   ```

2. Escribí la decisión como un script y razoná sobre cada código de salida:

   ```bash
   cat > /tmp/whereisit.sh <<'EOF'
   #!/bin/bash
   set -u
   cmd=$1
   if p=$(command -v -- "$cmd"); then
     printf 'in PATH: %s\n' "$p"; exit 0
   fi
   if locate -b "\\$cmd" 2>/dev/null | grep -q .; then
     printf 'on disk (locate db, may be stale):\n'; locate -e -b "\\$cmd"; exit 0
   fi
   printf 'not in PATH and not in locate db; doing a live scan...\n' >&2
   find / -xdev -type f -name "$cmd" -print -quit 2>/dev/null | grep . \
     || { printf 'genuinely absent\n' >&2; exit 1; }
   EOF
   chmod +x /tmp/whereisit.sh
   /tmp/whereisit.sh bash
   /tmp/whereisit.sh report-gen
   ```

3. Auditá la ubicación de todo lo que una compilación local dejó caer en el último día:

   ```bash
   sudo find /usr/local -xdev -mtime -1 -printf '%y %M %TF %TT %p\n' 2>/dev/null | sort -k4
   ```

4. Confirmá que nada aterrizó fuera de las jerarquías locales sancionadas:

   ```bash
   sudo find / -xdev -mtime -1 -type f \
        \( -path '/usr/local/*' -o -path '/opt/*' -o -path '/etc/*' \) -prune -o \
        -type f -mtime -1 -newermt 'today 00:00' -print 2>/dev/null | head -20
   ```

### Preguntas de comprensión — Bloque 6

- **Q6.1** — En el paso 1, ordená las cinco búsquedas de la más barata a la más cara e indicá qué puede probar cada una que la anterior no.
- **Q6.2** — El script usa `locate -b "\\$cmd"`. Explicá ambas barras invertidas: una la consume el shell, la otra `locate`. ¿Qué matchearía en cambio `locate -b "$cmd"`?
- **Q6.3** — Se usa `find / -name X -print -quit` en vez de un `find / -name X` a secas. ¿Qué te compra `-quit`, y qué te cuesta en corrección?
- **Q6.4** — En el paso 4, la rama de `-prune` lista rutas *y después* el segundo `-type f -mtime -1` se repite. Explicá por qué la repetición es necesaria dada la semántica de `-o`.
- **Q6.5** — Dentro del script se usa `command -v` en vez de `which`. Dá las dos razones (una de portabilidad, una de corrección) que hacen que sea la decisión correcta en un script `#!/bin/bash`.

---

## Respuestas

<details>
<summary><b>Hacé clic para revelar todas las respuestas</b></summary>

### Bloque 1 — Leer el FHS desde un sistema en vivo

**A1.1** — Un enlace simbólico *relativo* (`/bin -> usr/bin`) resuelve correctamente sin importar dónde esté montado el sistema de archivos raíz. Durante la instalación, el rescate, un `chroot`, la construcción de imágenes de contenedor o `systemd-nspawn`, el árbol vive en `/mnt/sysroot` o similar; un `/bin -> /usr/bin` absoluto se escaparía del chroot y apuntaría al `/usr/bin` del *host*, lo cual es o bien incorrecto o bien un agujero de seguridad. Los enlaces relativos mantienen la jerarquía autocontenida y reubicable.

**A1.2** — Los dos ejes son **compartible vs. no compartible** y **estático vs. variable** (FHS 3.0 §2).

| | estático | variable |
|---|---|---|
| **compartible** | `/usr`, `/opt` | `/var/mail`, `/var/spool/news`, `/home` |
| **no compartible** | `/etc`, `/boot` | `/var/run`, `/var/lock` (ahora `/run`) |

`/usr` = compartible + estático (montable en solo lectura, exportable a muchos hosts). `/var` = variable, compartibilidad mixta. `/etc` = no compartible + estático (configuración específica del host). `/home` = compartible + variable.

**A1.3** — `/var/tmp`. FHS 3.0 §5.15: "*Programs may not assume that any files or directories in `/tmp` are preserved between invocations of the program*", mientras que la §5.15 sobre `/var/tmp` establece que los datos son "*more persistent than data in `/tmp`*" y "*must not be deleted when the system is booted*". Además, `/tmp` es un `tmpfs` en la mayoría de las distribuciones modernas, así que un archivo de 4 GB ahí consume RAM/swap, y `systemd-tmpfiles` lo limpia por antigüedad de forma agresiva (`/etc/tmpfiles.d`, típicamente 10 días para `/tmp`, 30 para `/var/tmp`).

**A1.4** — `/run` guarda datos volátiles de runtime que deben estar disponibles **antes de que `/var` esté montado** y deben descartarse en el arranque. Hacerlo un `tmpfs` garantiza ambas cosas: existe desde muy temprano en el traspaso del initramfs, y arranca vacío en cada boot sin necesidad de ningún script de limpieza. `nosuid,nodev` son endurecimiento: nada en `/run` debería ser jamás un binario setuid ni un nodo de dispositivo, así que se le indica al kernel que ignore esos bits directamente. Reemplazó a **`/var/run`** (y `/var/lock` → `/run/lock`), que el FHS 3.0 ahora exige que sean enlaces simbólicos a `/run` y `/run/lock`.

**A1.5** — Compilación desde fuente: `--prefix=/usr/local`. Binarios → `/usr/local/sbin/nginx`, configuración → `/usr/local/etc/nginx/`, datos variables (logs, caché, PID) → `/var/log/nginx` y `/var/cache/nginx` — `/usr/local` debe permanecer a salvo a través de las actualizaciones del software de la distribución, y debería poder montarse en solo lectura, así que nada que cambie en tiempo de ejecución pertenece ahí. Tarball del proveedor: `/opt/acme-crm/` para el árbol autocontenido, `/etc/opt/acme-crm/` para su configuración, `/var/opt/acme-crm/` para sus datos variables.

**A1.6** — En el **capítulo 6, el "Operating System Specific Annex"**, sección de Linux (§6.1.4 `/proc`, y la entrada correspondiente para `/sys`). Estar en el anexo en vez de en el capítulo obligatorio del sistema de archivos raíz significa que son **específicos de Linux**, no parte del núcleo portable que el FHS define para todos los sistemas tipo Unix — los BSD, por ejemplo, no proveen `/sys` y montan `/proc` opcionalmente o directamente no lo montan.

**A1.7** — El FHS 3.0 designa **`/usr/local/share/man`**, en correspondencia con `/usr/share/man`. `/usr/local/man` es una **ruta de compatibilidad heredada**: el FHS 2.3 la permitía, y la mayoría de las distribuciones todavía la incluyen como directorio o enlace simbólico para que las compilaciones viejas con `--prefix=/usr/local` sigan funcionando. Las instalaciones nuevas deberían usar `/usr/local/share/man`.

---

### Bloque 2 — Localizar comandos

**A2.1**
- `type` — *"¿Qué va a hacer este shell cuando escriba esta palabra?"* Cubre alias, palabras clave, funciones, builtins, rutas hasheadas y archivos del PATH, en el orden de resolución propio del shell.
- `which` — *"¿Qué archivo en `$PATH` coincide con este nombre?"* Nada más.
- `whereis` — *"¿Dónde están el binario, el código fuente y la página de manual de este programa, en las ubicaciones estándar del sistema?"*

`type` es un **builtin del shell**, así que ve el estado real del shell — la tabla de alias, la tabla de funciones, la lista de palabras clave, la tabla hash. `which` es un proceso externo; no puede ver nada de eso, solo el `$PATH` exportado.

**A2.2** — El `probe` a secas siguió imprimiendo **`FIRST`**. Bash cacheó la ruta completa `/home/you/bin/probe` en su tabla hash en la primera invocación, y un cambio posterior en `PATH` no invalida la caché para nombres ya hasheados. `which` es un proceso externo nuevo sin tabla hash, así que hizo un escaneo limpio de `PATH` de izquierda a derecha y reportó correctamente `/tmp/probe`. `type probe` habría mostrado `probe is hashed (/home/you/bin/probe)` — la pista delatora. `hash -r` limpia la tabla y el siguiente `probe` imprime `SECOND`.

**A2.3** — `cd` es un builtin del shell; no existe ningún archivo llamado `cd` en ninguna parte de `$PATH`, así que `which` — que solo busca archivos en `$PATH` — correctamente no encuentra nada y sale con 1. `command -v` es un builtin de shell POSIX que reporta cómo el shell resolvería la palabra, incluidos los builtins, así que imprime `cd`. Los scripts portables deberían usar **`command -v`**: está especificado por POSIX, no requiere ningún binario externo, y no varía entre las cuatro implementaciones incompatibles de `which` que hay dando vueltas (script de shell de debianutils, GNU which, BSD which, builtin de zsh).

**A2.4** — `whereis` sale con 0 haya encontrado algo o no — es una herramienta de reporte, no de prueba. Por lo tanto, el modismo `whereis -b foo >/dev/null && ...` **siempre toma la rama verdadera**, y el script sigue como si `foo` existiera. Lo correcto: `command -v foo >/dev/null 2>&1 || { echo "foo required" >&2; exit 1; }`.

**A2.5** — El reemplazo recomendado es **`command -v`** (POSIX) — tanto la página de manual de `which` de Debian como la entrada de NEWS de `debianutils` lo dicen. La única capacidad que no se traslada es `which -a`, que lista *todas* las coincidencias en `$PATH`. En bash, usá **`type -a <nombre>`**; de forma portable según POSIX, iterá `$PATH` vos mismo:

```sh
IFS=: ; for d in $PATH; do [ -x "$d/$1" ] && printf '%s\n' "$d/$1"; done
```

**A2.6** — Se ejecuta el que `type -a` lista **primero**, porque `type -a` imprime las coincidencias en el orden de resolución propio del shell — que para archivos del PATH es de izquierda a derecha a través de `$PATH`, o sea `/usr/local/bin/python3`. El único comando que muestra la ruta resuelta sin ejecutarlo es **`type -P python3`** (o `command -v python3`).

**A2.7** — No es un bug. `whereis` busca en una lista de directorios estándar compilada en el binario que incluye `/etc` — históricamente el lugar donde podía vivir el *binario* de un programa, y todavía el lugar donde a menudo viven sus archivos de datos. `whereis` matchea **solo por basename**, con un pequeño conjunto de sufijos reconocidos que se recortan; no tiene noción de "¿este archivo es ejecutable?" ni de "¿es este el mismo programa?". `whereis -b passwd` devuelve entonces tanto el ejecutable `/usr/bin/passwd` como la base de datos no relacionada `/etc/passwd`. Precisamente por esto `whereis` nunca debe usarse para probar si un comando existe.

---

### Bloque 3 — El motor de expresiones de `find`

**A3.1** — Al quitar el `-print`, el comando quedó como `find . -name .cache -prune -o -type f`. Como **no aparece ninguna acción en ninguna parte de la expresión**, `find` le agrega un `-print` implícito a la expresión *entera*, es decir, se comporta como `\( -name .cache -prune -o -type f \) -print`. El resultado: ahora se imprime también `./.cache` en sí (matcheó la rama izquierda, `-prune` devolvió verdadero), *y* todos los archivos regulares siguen imprimiéndose. En la forma correcta, el `-print` explícito se liga solamente a la rama derecha del `-o`, así que el directorio podado se saltea en silencio. La regla: **una acción explícita en cualquier parte de la expresión suprime el `-print` implícito**, y `-prune` devuelve *verdadero*, que es precisamente por lo que debe emparejarse con `-o`.

**A3.2** — `-size` **redondea hacia arriba** a la siguiente unidad entera. Cualquier archivo de 1 byte a 1 048 576 bytes redondea a `1M`, así que `-size -1M` (estrictamente menor que 1 unidad M) solo puede satisfacerse con `0` — archivos vacíos. Forma correcta:

```bash
find . -type f -size -1M ! -empty
# or, exactly:
find . -type f -size -1048576c -size +0c
```

Solo el sufijo `c` es exacto; `k`, `M`, `G`, `b` y `w` redondean todos hacia arriba.

**A3.3** — `find -size` usa **`st_size`** — el tamaño *aparente* — para cada unidad, incluidas las unidades de bloque. `du` reporta **`st_blocks`** — el almacenamiento realmente asignado. Para un archivo disperso estos divergen por completo. Riesgo práctico: `find -size +1G` va a reportar imágenes de disco de VM dispersas, archivos de log dispersos y archivos de base de datos preasignados como devoradores de espacio cuando ocupan casi nada, y a la inversa, no va a tener en cuenta la compresión del sistema de archivos (btrfs/ZFS) que hace que un archivo aparentemente grande sea físicamente chico. Cuando cazás consumo de disco real, usá `-printf '%k\t%p\n'` (que reporta bloques de 1 KiB desde `st_blocks`) o `du`, no `-size`.

**A3.4**
- `-perm 0644` — los bits de permiso son **exactamente** `rw-r--r--`; cada uno de los 12 bits de modo (incluidos setuid/setgid/sticky) debe coincidir.
- `-perm -0644` — **todos** los bits listados están puestos; otros también pueden estarlo. Matchea `0644`, `0755`, `0664`, `4644`.
- `-perm /0644` — **alguno** de los bits listados está puesto. Matchea casi todo lo legible o escribible por el dueño; `-perm /0000` no matchea nada (caso especial).

`-perm +0644` era la vieja grafía GNU de `/`. Se deprecó en findutils 4.2.21 y se **eliminó en 4.5.12**, porque `+` colisionaba con los modos simbólicos (`-perm +u+w`). El `find` moderno da error con esa forma.

**A3.5** — `-mtime n` compara contra **n períodos de 24 horas contados hacia atrás desde el momento en que `find` arranca**, y la aritmética **trunca la parte fraccionaria hacia cero**. Así que un archivo modificado hace 7,5 días da 7, que no satisface `+7` (estrictamente mayor que 7). Por lo tanto, `-mtime +7` significa "modificado hace **al menos 8 períodos completos de 24 horas**" — los archivos de entre 7 y 8 días de antigüedad caen en la grieta. La opción que ancla el límite a medianoche en vez de a "ahora" es **`-daystart`**, que debe aparecer *antes* de los tests de tiempo a los que afecta.

**A3.6**

| | `-exec cmd {} \;` | `-exec cmd {} +` |
|---|---|---|
| Procesos | uno por archivo coincidente | tan pocos como permita `ARG_MAX` |
| Límites de longitud de argumentos | nunca se alcanzan (un archivo por vez) | `find` divide las invocaciones automáticamente para mantenerse bajo el límite |
| Código de salida | `-exec` devuelve el éxito del comando por archivo, así que puede usarse como **test** (`-exec grep -q X {} \; -print`) | siempre devuelve verdadero; usable solo como acción terminal |
| Apariciones de `{}` | puede aparecer varias veces, en cualquier parte del argv | debe aparecer **exactamente una vez, inmediatamente antes del `+`** |

La brecha de rendimiento es grande: en un árbol de ~50 000 archivos, `\;` hace fork 50 000 veces, `+` hace fork un puñado de veces.

**A3.7** — `-exec` pasa la ruta completa y deja que el comando invocado la resuelva desde el directorio de trabajo original de `find`. Entre el momento en que `find` hace stat sobre un directorio y el momento en que el comando abre la ruta, un atacante que controle parte del árbol puede intercambiar un componente de directorio por un enlace simbólico — una carrera TOCTOU clásica que redirige la operación fuera del árbol previsto. `-execdir` hace `chdir()` al directorio contenedor y pasa la ruta como `./basename`, así que no se vuelve a recorrer ningún componente intermedio controlado por el atacante. También se niega a ejecutarse si `$PATH` contiene una entrada relativa.

**A3.8** — Con `-L`, `find` **desreferencia cada enlace simbólico antes de aplicar los tests**. `hello-link` apunta a un archivo regular, así que bajo `-L` se reporta como `-type f`, no como `-type l`. `broken-link` no puede desreferenciarse — el destino no existe — así que `find` recurre al `lstat()` del propio enlace y sigue dando `-type l`. De ahí que bajo `-L`, `-type l` signifique efectivamente "enlace simbólico roto". `-xtype l` invierte la política de desreferencia solo para ese test: bajo el `-P` por defecto reporta enlaces cuyo *destino* es un enlace, y bajo `-L` reporta los enlaces en sí — así que `-L ... -xtype l` te da todos los enlaces simbólicos sin importar si resuelven o no.

**A3.9** — Dos modos de falla:
1. **Nombres de archivo con espacios en blanco, comillas o saltos de línea.** `xargs` divide por espacios en blanco y respeta el quoting por defecto, así que `name with spaces.log` se convierte en tres argumentos y `"quoted"` se destroza.
2. **Entrada vacía.** Sin coincidencias, GNU `xargs` igual ejecuta `grep -l root` una vez sin operandos de archivo, así que `grep` lee de **stdin** y la tubería se cuelga (o, peor, consume la entrada del script).

Reescrituras seguras:

```bash
find /etc -name '*.conf' -print0 | xargs -0 -r grep -l root
find /etc -name '*.conf' -exec grep -l root {} +
```

(`-r`/`--no-run-if-empty` arregla la segunda falla; `-print0`/`-0` la primera. La forma `-exec ... +` no necesita ninguna de las dos.)

**A3.10** — Código de salida **1**. `find` devuelve 0 solo si *todo* salió bien; cualquier error — permiso denegado en un subdirectorio, un `-exec` roto, una ruta ilegible — deja el código en distinto de cero aun cuando la salida producida haya sido correcta y completa para la porción legible. Consecuencias: bajo `set -e` (o `set -o pipefail`) un `find /` dentro de un script aborta la corrida en el primer directorio ilegible, así que necesitás `|| true` o una ruta de partida acotada. Y `2>/dev/null` esconde los *mensajes* pero **no** cambia el *código de salida* — una fuente muy común de reportes de "el script se detuvo en silencio".

**A3.11**

```bash
sudo find /srv -xdev -type f -name '*.tmp' -mtime +30 -delete
```

Dos efectos colaterales de `-delete` que `-exec rm {} +` no tiene:
1. **`-delete` implica `-depth`.** El recorrido cambia a post-orden, así que los directorios se procesan después de su contenido. Esto rompe silenciosamente a `-prune`, que no tiene efecto bajo `-depth` — una expresión `-prune -o ... -delete` va a descender y borrar el árbol que querías proteger.
2. **`-delete` es una acción que devuelve un valor y se evalúa en el orden de la expresión.** Colocada demasiado temprano, borra antes de que corran los tests posteriores; y a diferencia de `rm`, usa `unlinkat()` relativo al descriptor de directorio abierto, lo que la hace resistente a carreras pero también significa que va a eliminar alegremente directorios vacíos cuando se combina con `-type d` — sin `-i`, sin confirmación y sin la protección de `-r`.

Siempre hacé una prueba en seco con `-print` primero, y después cambiá a `-delete`.

**A3.12** — Porque `-maxdepth` no evalúa el nodo actual ni devuelve un booleano; cambia el comportamiento del **recorrido en sí**, para toda la corrida, sin importar dónde aparezca en la expresión. `find` parsea la expresión de izquierda a derecha y la evalúa por nodo, pero las opciones globales (`-maxdepth`, `-mindepth`, `-depth`, `-daystart`, `-follow`, `-mount`/`-xdev`, `-regextype`, `-warn`) se extraen y se aplican a todo. Escribirlas después de un test genera código que *se lee* como si estuviera acotado cuando no lo está — de ahí la advertencia en vez de un error.

---

### Bloque 4 — `locate` / `updatedb`

**A4.1**
- **`PRUNEFS`** — *tipos* de sistema de archivos a saltear por completo (se comparan sin distinguir mayúsculas contra el fstype del montaje).
- **`PRUNEPATHS`** — *rutas* absolutas a saltear; la ruta en sí y todo lo que esté debajo.
- **`PRUNENAMES`** — **nombres de directorio** pelados a saltear en cualquier parte del árbol. Toma solo nombres, **no rutas ni comodines**; `.git` saltea todos los directorios `.git` del sistema.
- **`PRUNE_BIND_MOUNTS`** — `yes`/`no`; cuando es `yes`, saltea los bind mounts para que los mismos archivos no se indexen dos veces bajo dos rutas.

**A4.2** — `tmpfs` se poda porque su contenido es **volátil** — se desvanece al reiniciar, así que indexarlo produce una base de datos llena de rutas que no van a existir para cuando alguien las consulte. `nfs` se poda porque es **remoto**: recorrerlo arrastra la exportación entera por la red, machaca al servidor, e indexaría archivos que pertenecen al espacio de nombres de otro host (y que después cada cliente NFS re-indexaría redundantemente).

**A4.3** — `locate` lee una **base de datos instantánea**, no el sistema de archivos en vivo; la entrada sobrevive hasta el siguiente `updatedb`. **`locate -e` / `--existing`** suprime los aciertos cuyas rutas ya no existen. El costo es que `-e` debe hacer `stat()` sobre cada resultado candidato, lo que reintroduce E/S de sistema de archivos y errores de permisos — barato para un puñado de aciertos, lento para un patrón que matchea decenas de miles.

**A4.4** — La regla: **si el patrón no contiene ningún metacarácter de globbing (`*`, `?`, `[`), `locate` lo envuelve implícitamente como `*patrón*`.** Así que `bash` ≡ `*bash*` — mismo conteo. `/bin/bash` *tampoco* contiene metacaracteres, así que se convierte en `*/bin/bash*`, que matchea muchísimas menos rutas (solo las que tienen esa subcadena literal) que `*bash*`. A la inversa, en cuanto escribís cualquier metacarácter, **no ocurre ningún envolvimiento implícito** y el patrón debe matchear la ruta completa: `locate '*.conf'` funciona, `locate '.conf'` matchea `*.conf*` y también `myconfig`, y `locate 'bash*'` no matchea absolutamente nada porque ninguna ruta absoluta *empieza* con `bash`.

**A4.5** — El binario es **setgid `plocate`** (o `mlocate`). Ese grupo posee la base de datos, que tiene modo `0640 root:plocate` — legible por el grupo, escribible solo por root. Cuando ejecutás `locate`, el proceso gana el grupo `plocate`, abre la base de datos, y entonces — crucialmente — **filtra cada resultado candidato contra el UID/GID real de quien invoca**, verificando que ese usuario pueda hacer `stat()` sobre la ruta y atravesar cada directorio padre. Si la base de datos tuviera modo `0644`, cualquier usuario podría leerla directamente con `cat`/`strings` y saltear el filtro por completo, enumerando la disposición completa del sistema de archivos, incluidos `/root`, los directorios personales de otros usuarios y rutas que filtran secretos en sus nombres (`/home/alice/.ssh/id_ed25519_prod`). Setgid en vez de setuid porque el acceso de lectura a un único archivo propiedad del grupo es todo lo que hace falta — no se requieren privilegios de root, así que no se otorga ninguno.

**A4.6** — `--require-visibility 0` escribe una base de datos que **no almacena los metadatos de propiedad/permisos necesarios para el filtro de visibilidad**, y en consecuencia la marca como "no requiere filtrado" — `locate` va a devolver cada ruta almacenada a cualquiera que pueda leer el archivo. Para el paso 9 eso es correcto: la base de datos la construís y la poseés vos, sobre un árbol que ya es tuyo, y está guardada en una ruta que solo vos podés leer, así que el filtro sería puro sobrecosto. Para `/var/lib/plocate/plocate.db` sería una divulgación de información grave: esa base de datos indexa todo el sistema, incluidas rutas bajo los directorios personales de otros usuarios y `/root`, y sin el filtro cualquier usuario sin privilegios podría enumerarlas. Por eso la base de datos del sistema siempre se construye con `--require-visibility 1` (el valor por defecto) más permisos de archivo restrictivos.

**A4.7** — Diagnóstico: *"`locate` consulta una base de datos que se reconstruye con un temporizador — típicamente una vez por día — así que un archivo creado hace cinco minutos todavía no está en ella. El archivo no tiene nada malo."* Confirmalo con `systemctl list-timers '*updatedb*'` para ver la última corrida. Herramienta correcta: **`find`**, que recorre el sistema de archivos en vivo:

```bash
find /path/to/expected -name 'thefile' -mmin -10
```

O forzá un refresco con `sudo updatedb` si el usuario realmente necesita el índice actualizado.

**A4.8** — Dos arreglos:
1. **Agregar `nfs nfs4` a `PRUNEFS`** (están en la lista por defecto en la mayoría de las distribuciones — verificá si el archivo local la sobrescribe, o si el montaje reporta un fstype distinto como `fuse.sshfs`). Compromiso: `locate` ya no va a poder encontrar nada en el servidor de archivos; los usuarios tienen que usar `find` ahí.
2. **Agregar el punto de montaje específico a `PRUNEPATHS`**, por ejemplo `PRUNEPATHS="... /mnt/bulk"`. Compromiso: la misma pérdida de indexado, pero acotada a una sola ruta — otros montajes NFS siguen indexados. Una tercera opción es correr `updatedb -U /mnt/bulk -o /mnt/bulk/.plocate.db` **en el propio servidor de archivos** y que los clientes lo consulten con `locate -d`; el compromiso es el costo operativo de distribuir y gestionar permisos de una segunda base de datos.

**A4.9**

| Eje | `find` | `locate` |
|---|---|---|
| **Frescura** | en vivo, siempre actual | al momento del último `updatedb`; típicamente hasta 24 h de desactualización |
| **Costo** | O(tamaño del árbol); minutos sobre `/` | O(tamaño del conjunto de resultados); milisegundos |
| **Predicados de metadatos** | tamaño, mtime, permisos, dueño, tipo, inodo, enlaces — toda la superficie de `stat` | **solo nombre/ruta**; sin tests de tamaño, tiempo, modo ni dueño |
| **Privilegio** | necesita lectura+ejecución en cada directorio en el que desciende; produce errores de permisos como usuario normal | lee una única base de datos legible por el grupo; los resultados se filtran a lo que quien invoca podría ver de todos modos |

Regla práctica: **`locate` para encontrar *dónde* está algo por su nombre; `find` para encontrar *qué* archivos satisfacen una condición.**

---

### Bloque 5 — Decisiones de ubicación

**A5.1**

| | Ubicación correcta | Justificación |
|---|---|---|
| (a) script de Python local | `/usr/local/bin/` | Software instalado localmente; `/usr/local` está reservado para el administrador y el gestor de paquetes no lo toca. |
| (b) sitio estático de nginx | `/srv/www/example.com/` | FHS §3.17: `/srv` son "site-specific data which is served by this system". `/var/www` es la convención de la distribución, no la del FHS. |
| (c) directorio de datos de PostgreSQL | `/var/lib/postgresql/<ver>/` | `/var/lib` guarda información de estado que persiste entre reinicios y que el programa modifica mientras corre. |
| (d) archivo PID | `/run/<name>.pid` o `/run/<name>/<name>.pid` | Datos volátiles de runtime, descartados en el arranque; `/var/run` es un enlace simbólico de compatibilidad. |
| (e) unidad systemd de la distro | `/usr/lib/systemd/system/` (en Debian también `/lib/systemd/system` vía el enlace de merged-`/usr`) | Datos estáticos bajo `/usr`, propiedad del gestor de paquetes. |
| (f) tu unidad systemd | `/etc/systemd/system/` | Configuración específica del host; además es la de mayor precedencia, así que sobrescribe la unidad del proveedor. |
| (g) `.so` compilado localmente | `/usr/local/lib/` (más una entrada en `/etc/ld.so.conf.d/` + `ldconfig`) | Las bibliotecas del software local reflejan la jerarquía local. |
| (h) el tarball de fuentes | `/usr/local/src/` | FHS §4.10: `/usr/src` es para el código fuente del sistema; `/usr/local/src` es su contraparte local. |
| (i) certificado de CA interna | `/usr/local/share/ca-certificates/*.crt` (Debian) o `/etc/pki/ca-trust/source/anchors/` (RHEL), y después ejecutar `update-ca-certificates` / `update-ca-trust` | El ancla de confianza es configuración local que afecta al host; la herramienta regenera el bundle bajo `/etc/ssl/certs`, que nunca debés editar directamente. |
| (j) volcado nocturno de BD | `/var/backups/` o `/var/lib/<app>/backups/` | Datos variables, crecen con el tiempo, deben sobrevivir al reinicio; no `/tmp` (se limpia), no `/usr` (debería poder montarse en solo lectura). |

**A5.2** — Para `/usr/local/bin/hello` es lo esperado: el FHS §4.9 dice que `/usr/local` es "for use by the system administrator when installing software locally", y que "needs to be safe from being overwritten when the system software is updated" — el gestor de paquetes deliberadamente no posee nada ahí. Para `/usr/bin/hello-bad` es un problema por tres razones: (1) un paquete de la distribución podría después entregar un archivo en la misma ruta y la actualización sobrescribiría el tuyo sin aviso, o fallaría con un conflicto de archivos; (2) las herramientas de integridad (`debsums`, `rpm -Va`, AIDE, Tripwire) marcan los archivos sin dueño en directorios gestionados por paquetes como indicadores de intrusión; (3) ninguna desinstalación lo va a eliminar jamás, así que sobrevive como huérfano para siempre.

**A5.3** — El FHS 3.0 designa **`/srv`** (§3.17). `/var/www` es anterior a `/srv` — era la convención de facto antes de que el FHS 2.3 introdujera `/srv`, y todo el ecosistema de vhosts por defecto de Apache/nginx, el etiquetado SELinux `httpd_sys_content_t`, los perfiles de AppArmor y miles de tutoriales están construidos sobre él. Las distribuciones lo conservan porque romperlo rompería cada despliegue existente, y porque el FHS deliberadamente deja sin especificar la disposición interna de `/srv` ("no program should rely on a specific subdirectory structure"), así que no hay ninguna convención portable de `/srv` *a la cual* migrar. Ambos son defendibles en producción; sé consistente, y si usás `/srv` en RHEL acordate de establecer vos mismo el contexto de SELinux.

**A5.4** — `/opt/<pkg>` guarda los archivos **estáticos** de un paquete adicional: binarios, bibliotecas, datos de solo lectura. `/etc/opt/<pkg>` guarda su **configuración específica del host**. `/var/opt/<pkg>` guarda sus **datos variables**: logs, spool, cachés, bases de datos. La prohibición sobre `/opt/<pkg>/etc` existe porque `/opt` está clasificado como compartible+estático: debe poder montarse en **solo lectura** y exportarse a muchos hosts desde un servidor. La configuración es no compartible por definición (cada host difiere) y los datos variables deben ser escribibles, así que ambos tienen que vivir fuera de la exportación de solo lectura. El mismo razonamiento es lo que hace de `/usr/local/etc` una zona gris y por qué las compilaciones estrictas con el FHS mantienen la configuración local en `/etc` propiamente dicho.

**A5.5** — **Correcto según el FHS: sí**, en espíritu — `/usr/local/lib/<pkg>` es el lugar sancionado para los archivos independientes de arquitectura pero que no son de `share` del software local, y es paralelo a la ruta del proveedor `/usr/lib/systemd/system`. **Funcional: sí** — la ruta de búsqueda de unidades de systemd incluye explícitamente `/usr/local/lib/systemd/system`, con una precedencia entre la ruta del proveedor y `/etc/systemd/system`. La reconciliación: es el lugar correcto para una unidad que es parte de un *paquete instalado localmente* (instalado por `make install`, removible como unidad) pero el lugar equivocado para una unidad *específica del host* que escribiste a mano para esta única máquina — esa pertenece a `/etc/systemd/system`, que es a la vez el hogar del FHS para la configuración del host y el directorio de mayor precedencia de systemd. Verificá la lista en vivo con `systemd-analyze unit-paths` (o `systemctl show --property=UnitPath`).

**A5.6** — `install -D -m 0755 src dst`:
1. **Establece el modo atómicamente en el momento de creación.** `cp` seguido de `chmod` deja una ventana en la que el archivo existe con los permisos equivocados — para un binario setuid o un archivo de clave, esa ventana es explotable. `install` además ignora el umask, así que el resultado es determinista sin importar el entorno del shell que lo invoca.
2. **`-D` crea todos los directorios padre faltantes** del destino, así que un script de aprovisionamiento no necesita un `mkdir -p` aparte, y hay un modo de falla menos cuando el árbol de destino todavía no existe.

De yapa: `install` también acepta `-o`/`-g` en la misma invocación, escribe en un archivo temporal y renombra (así el destino nunca se ve escrito a medias), y se niega a sobrescribir un directorio con un archivo.

**A5.7** — La **tabla hash de comandos** de bash. Una vez que `hello` se ejecutó con éxito, bash cachea la ruta resuelta y la reutiliza sin consultar `$PATH` — y va a seguir haciéndolo hasta que el `execve()` cacheado realmente falle con `ENOENT`, momento en el cual bash reintenta una búsqueda completa en `PATH` (esta recuperación es específica de bash; otros shells reportan "command not found"). **`type hello`** habría mostrado la verdad — `hello is hashed (/usr/local/bin/hello)` — mientras que `which hello` y `whereis -b hello` hacen ambos búsquedas frescas en el sistema de archivos y reportarían correctamente que el archivo ya no está. Limpiala con `hash -r` (todas las entradas) o `hash -d hello` (una entrada).

**A5.8** — `man` construye su ruta de búsqueda a partir de **`manpath(1)`**, que la deriva de `/etc/manpath.config` (familia Debian) o `/etc/man_db.conf` / `/etc/man.conf` (familia RHEL). Esos archivos contienen entradas `MANPATH_MAP` que mapean cada elemento de `$PATH` a una jerarquía de manuales correspondiente — `MANPATH_MAP /usr/local/bin /usr/local/share/man` — más entradas `MANDATORY_MANPATH` que siempre se buscan. Como `/usr/local/bin` está en tu `$PATH`, `/usr/local/share/man` se agrega automáticamente a la ruta de manuales; `man -w hello` imprime el archivo que resolvió, y `manpath` imprime la ruta completa calculada. No hace falta ningún índice de `mandb` para que `man <nombre>` funcione — el índice solo acelera `man -k` / `apropos` y `whatis`.

---

### Bloque 6 — Integración

**A6.1** — De la más barata a la más cara:

1. **`type -a`** — gratis, en el proceso, sin más syscalls que la tabla hash y los stats de `$PATH`. Prueba: qué ejecutaría *este shell*, incluidos alias y funciones que las otras herramientas no pueden ver.
2. **`command -v`** — mismo costo, POSIX. Prueba la resolubilidad sin el detalle de la clasificación.
3. **`whereis -b`** — un proceso, hace stat sobre una lista chica de directorios fija en el binario. Prueba: si el binario está en una ubicación *estándar* que sin embargo queda fuera de tu `$PATH` (el clásico `/usr/sbin` que no está en el PATH de un usuario no root).
4. **`locate -b`** — un proceso, una lectura de base de datos indexada, milisegundos. Prueba: si el archivo existe **en alguna parte** del sistema al momento del último `updatedb` — la primera verificación con alcance a todo el sistema de archivos.
5. **`find / -xdev`** — recorrido completo del árbol, de segundos a minutos, necesita root para ser completo. Prueba: la verdad de campo ahora mismo, más cada predicado de metadatos (`%M %u:%g %s %TF`) que te dice *por qué* no está corriendo — modo equivocado, dueño equivocado, cero bytes, arquitectura equivocada.

Cada peldaño responde algo que el de abajo no puede; corrélos en orden y frená en el primero que resuelva la pregunta.

**A6.2** — El shell procesa primero la cadena entre comillas dobles y convierte `\\` en un único `\` literal, así que `locate` recibe el argumento `\report-gen`. `locate` entonces interpreta la barra invertida inicial como **"este patrón es literal — no apliques el envolvimiento implícito `*patrón*`"**, combinado con `-b` que da una coincidencia exacta de basename. Sin ella, `locate -b "$cmd"` recibiría `report-gen`, aplicaría globbing implícito para dar `*report-gen*`, y matchearía `report-gen.bak`, `old-report-gen`, `report-generator`, `report-gen.1.gz` — falsos positivos que harían que el script reporte éxito para un archivo que no es el comando.

**A6.3** — `-quit` hace que `find` **salga inmediatamente después de la primera coincidencia**, convirtiendo un recorrido completo del árbol en el peor caso en un retorno temprano. Sobre un `/` grande, esa es la diferencia entre segundos y minutos, y acá importa porque el script solo necesita una respuesta de existencia, no una enumeración. El costo: te enterás de que existe *un* archivo con ese nombre, pero no **cuántos** ni **cuál gana** — si el binario está instalado en tres lugares con versiones o modos distintos, `-quit` lo esconde, y el que da la casualidad de golpear primero depende del orden de recorrido de directorios, que no está ordenado ni es estable entre sistemas de archivos. Para un diagnóstico que deba distinguir duplicados, sacá el `-quit` y asumí el costo.

**A6.4** — `-o` es un OR con cortocircuito sobre una expresión evaluada por nodo, y `-prune` **devuelve verdadero**. Así que la rama izquierda `\( -path ... \) -prune` tiene éxito para los directorios excluidos, cortocircuita, y la rama derecha nunca corre para ellos — eso es la exclusión. Pero para cada nodo que *no* matchea la rama izquierda, el OR cae a la rama derecha, y esa rama debe **reformular los tests que realmente quiere**, porque nada de la rama izquierda se arrastra: `-o` compone dos expresiones completas independientes, no "continúa" la primera. Además, como la expresión ahora contiene una acción explícita (`-print`), el `-print` implícito queda suprimido en todos lados, así que la rama derecha debe proveer el suyo. De ahí `... -prune -o -type f -mtime -1 -print`.

**A6.5**
- **Portabilidad**: `command -v` está especificado por POSIX.1-2017 y es un builtin del shell, así que existe en todo shell conforme y no necesita ningún binario externo. `which` no está en POSIX; hay al menos cuatro implementaciones mutuamente incompatibles (el script `/bin/sh` de debianutils, GNU `which`, BSD `which`, el builtin de zsh) que difieren en código de salida, formato de salida y semántica de `-a`, y está completamente ausente en imágenes de contenedor mínimas y entornos de rescate sin busybox.
- **Corrección**: `command -v` resuelve de la misma forma en que el shell va a resolver realmente, así que reporta builtins, funciones y alias, y respeta el manejo de `$PATH` propio del shell. Un script que prueba con `which` y después invoca el nombre puede terminar con un programa distinto del que `which` reportó — el caso del hash desactualizado del Bloque 2, o una función de shell que ensombrece al binario del PATH. Probar e invocar a través del mismo mecanismo de resolución elimina esa clase de bug.

</details>