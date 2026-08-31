# LPIC-1 · Examen 101-500 · Tema 104.5 — Gestionar permisos y propiedad de archivos

**Peso del examen:** 4.69 · **Términos clave:** `chmod`, `umask`, `chown`, `chgrp`, SUID, SGID, sticky bit

Estos son **ejercicios guiados prácticos**. Cada paso está pensado para ejecutarse en un sistema Linux descartable (VM, contenedor o una máquina de sobra) donde tengas `root` vía `sudo`. Las salidas mostradas son salidas de forma real; los UID/GID numéricos, los números de inodo, los números de dispositivo y las marcas de tiempo van a diferir en tu máquina.

> **Advertencia de comandos destructivos:** todo lo que sigue está confinado a `/srv/lab`, `/srv/projects` y `/tmp`. Nunca ejecutes los pasos recursivos de `chmod`/`chown` fuera de esas rutas.

---

## Ejercicio 0 — Construir el entorno de laboratorio

1. Convertite en root para la preparación y creá dos usuarios sin privilegios y dos grupos:

```bash
sudo groupadd devs
sudo groupadd ops
sudo useradd -m -s /bin/bash alice
sudo useradd -m -s /bin/bash bob
sudo usermod -aG devs alice
sudo usermod -aG devs bob
sudo usermod -aG ops  bob
```

2. Creá los directorios de práctica:

```bash
sudo mkdir -p /srv/lab /srv/projects
sudo chmod 0777 /srv/lab          # deliberately wide open for now
```

3. Verificá las identidades y las membresías de grupo:

```bash
id alice
id bob
```

Salida esperada (los números van a diferir):

```
uid=1001(alice) gid=1001(alice) groups=1001(alice),2001(devs)
uid=1002(bob) gid=1002(bob) groups=1002(bob),2001(devs),2002(ops)
```

4. Confirmá que podés ejecutar comandos como esos usuarios:

```bash
sudo -u alice id -un
sudo -u bob   id -un
```

> **Nota operativa:** lanzá siempre las shells de usuario desde un directorio que esos usuarios puedan atravesar (por ejemplo, hacé `cd /srv/lab` primero). Ejecutar `sudo -u alice ...` desde un directorio en el que `alice` no puede entrar produce `shell-init: error retrieving current directory`, que es en sí mismo un síntoma de permisos, no un bug de `sudo`.

### Preguntas de control — bloque 0

- **Q0.1** En `id bob`, ¿cuál es la diferencia entre el valor mostrado en `gid=` y los valores mostrados en `groups=`?
- **Q0.2** `bob` fue agregado a `ops` mientras ya tenía una shell de login abierta. ¿Esa shell gana acceso a los archivos que pertenecen a `ops`? ¿Por qué?
- **Q0.3** ¿Qué único archivo inspeccionarías para confirmar que `devs` realmente contiene a ambos usuarios, y qué campo de ese archivo los contiene?

---

## Ejercicio 1 — Leer la cadena de modo con precisión

1. Creá objetos de prueba de varios tipos como tu usuario normal:

```bash
cd /srv/lab
touch report.txt
mkdir archive
ln -s report.txt report.lnk
mkfifo pipe.fifo
```

2. Listalos:

```bash
ls -l
```

Salida esperada (abreviada):

```
drwxr-xr-x. 2 student student 4096 Aug 26 10:14 archive
prw-r--r--. 1 student student    0 Aug 26 10:14 pipe.fifo
lrwxrwxrwx. 1 student student   10 Aug 26 10:14 report.lnk -> report.txt
-rw-r--r--. 1 student student    0 Aug 26 10:14 report.txt
```

3. Descomponé una entrada campo por campo con `stat`, que imprime ambas notaciones a la vez:

```bash
stat -c '%A  %a  %U(%u)  %G(%g)  %F  %n' report.txt archive report.lnk pipe.fifo
```

Salida esperada:

```
-rw-r--r--  644  student(1000)  student(1000)  regular empty file  report.txt
drwxr-xr-x  755  student(1000)  student(1000)  directory  archive
lrwxrwxrwx  777  student(1000)  student(1000)  symbolic link  report.lnk
prw-r--r--  644  student(1000)  student(1000)  fifo  pipe.fifo
```

4. Mirá el carácter inmediatamente **posterior** a la cadena de modo de 10 caracteres (el `.` de arriba):

```bash
ls -l /etc/passwd /etc/shadow
getfacl -p report.txt 2>/dev/null | head -n 5
```

- `.` → hay un contexto de seguridad SELinux (u otro MAC) adjunto, sin ACL.
- `+` → hay una **ACL** u otro método de acceso alternativo presente; la cadena de modo por sí sola ya no cuenta toda la historia.
- ` ` (nada) → ninguno de los dos.

5. Demostrá que los permisos de un enlace simbólico en sí mismo carecen de sentido en Linux:

```bash
chmod 000 report.lnk
ls -l report.lnk report.txt
```

Salida esperada:

```
lrwxrwxrwx. 1 student student  10 Aug 26 10:14 report.lnk -> report.txt
----------. 1 student student   0 Aug 26 10:14 report.txt
```

6. Restaurá el archivo e inspeccioná los bits de tipo en crudo:

```bash
chmod 644 report.txt
stat -c '%f (hex mode incl. file type)  %a (permission bits only)' report.txt
```

Salida esperada:

```
81a4 (hex mode incl. file type)  644 (permission bits only)
```

### Preguntas de control — bloque 1

- **Q1.1** En `drwxr-xr-x`, ¿qué carácter *no* es un bit de permiso, y qué codifica?
- **Q1.2** `report.lnk` muestra `lrwxrwxrwx`, y sin embargo `chmod 000 report.lnk` cambió `report.txt`. Explicá ambos hechos.
- **Q1.3** Traducí `-rwsr-x---` a octal (cuatro dígitos) y `2750` a una cadena de modo de directorio.
- **Q1.4** Ves `-rw-rw-r--+ 1 root www-data ... config.ini` y un usuario que no es ni `root` ni miembro de `www-data` puede escribir en él. ¿Cuál es la explicación más probable, y qué comando lo confirma?
- **Q1.5** `stat -c %f` devolvió `81a4`. Descomponelo: ¿qué parte es el tipo de archivo y qué parte es el modo?

---

## Ejercicio 2 — `chmod`: notación octal y simbólica

1. Trabajá sobre un archivo nuevo:

```bash
cd /srv/lab
printf '#!/bin/sh\necho hello\n' > hello.sh
ls -l hello.sh
```

Esperado: `-rw-r--r--`.

2. Forma octal — establece exactamente, de una sola vez:

```bash
chmod 750 hello.sh && stat -c '%A %a' hello.sh
chmod 0640 hello.sh && stat -c '%A %a' hello.sh
```

Esperado:

```
-rwxr-x--- 750
-rw-r----- 640
```

3. Forma simbólica — las tres partes son **quién** (`u g o a`), **operador** (`+ - =`), **qué** (`r w x X s t`):

```bash
chmod u+x hello.sh          && stat -c '%A' hello.sh
chmod g=rx,o= hello.sh      && stat -c '%A' hello.sh
chmod a-x hello.sh          && stat -c '%A' hello.sh
chmod u=rw,g=r,o=r hello.sh && stat -c '%A' hello.sh
```

Esperado, en orden:

```
-rwxr-----
-rwxr-x---
-rw-r-----
-rw-r--r--
```

4. Entendé `=` frente a `+`/`-`: `=` **reemplaza** la tríada completa, los otros son aditivos/sustractivos.

```bash
chmod 777 hello.sh
chmod g= hello.sh
stat -c '%A %a' hello.sh
```

Esperado:

```
-rwx---rwx 707
```

5. La `X` mayúscula — "ejecución solo donde ya tiene sentido". Este es el modismo recursivo correcto:

```bash
mkdir -p tree/sub && touch tree/sub/data.txt tree/sub/run.sh
chmod 700 tree/sub/run.sh
chmod -R a=rX,u+w tree
find tree -printf '%m %y %p\n'
```

Esperado:

```
755 d tree
755 d tree/sub
644 f tree/sub/data.txt
755 f tree/sub/run.sh
```

Compará con el modismo equivocado (no lo dejes aplicado):

```bash
chmod -R a+x tree
find tree -printf '%m %y %p\n'
chmod -R a=rX,u+w tree     # undo
```

6. Copiá un modo desde otro archivo en lugar de volver a tipearlo:

```bash
chmod --reference=/etc/hostname hello.sh
stat -c '%A %a' hello.sh /etc/hostname
```

7. Fijate qué hace `chmod` con los enlaces simbólicos durante la recursión:

```bash
ln -s /etc/shadow tree/danger.lnk
chmod -R 777 tree
ls -l /etc/shadow tree/danger.lnk
```

`/etc/shadow` queda intacto: `chmod` no sigue los enlaces simbólicos que *encuentra mientras recorre* (no hay `lchmod()` en Linux), pero *sí* desreferencia un enlace simbólico nombrado directamente en la línea de comandos, como demostraste en el paso 5 del Ejercicio 1.

```bash
rm tree/danger.lnk
chmod -R a=rX,u+w tree
```

### Preguntas de control — bloque 2

- **Q2.1** ¿Por qué el paso 4 dejó `o=rwx` intacto mientras borraba la tríada de grupo?
- **Q2.2** ¿Cuál es exactamente la diferencia entre `chmod -R a+x dir` y `chmod -R a+X dir`, y por qué el segundo es el seguro?
- **Q2.3** Escribí, en una sola invocación de `chmod`, "lectura/escritura para el propietario, solo lectura para el grupo, nada para los demás" — primero en octal, después en forma simbólica.
- **Q2.4** `chmod 755 file` y `chmod 0755 file` — ¿hay alguna vez una diferencia? (Pensá en el tipo de objeto.)
- **Q2.5** Un colega ejecuta `chmod -R 777 /srv/app` para "arreglar" un despliegue. Dá dos consecuencias concretas de seguridad y una funcional.

---

## Ejercicio 3 — ¿Qué tríada se me aplica *a mí*?

El kernel verifica en orden estricto: **propietario → grupo → otros**, y se detiene en la **primera coincidencia**. No acumula.

1. Creá el caso contraintuitivo:

```bash
cd /srv/lab
sudo -u alice touch odd.txt
sudo chgrp devs odd.txt
sudo chmod 0077 odd.txt
ls -l odd.txt
```

Salida esperada:

```
----rwxrwx. 1 alice devs 0 Aug 26 10:20 odd.txt
```

2. `alice` es la propietaria **y** miembro de `devs`. Intentá leer como `alice`:

```bash
sudo -u alice cat /srv/lab/odd.txt; echo "exit=$?"
```

Esperado:

```
cat: /srv/lab/odd.txt: Permission denied
exit=1
```

3. Ahora como `bob`, que está en `devs` pero *no* es el propietario:

```bash
sudo -u bob cat /srv/lab/odd.txt; echo "exit=$?"
```

Esperado:

```
exit=0
```

4. Probá el acceso sin leer el contenido, de forma apta para scripts:

```bash
sudo -u alice test -r /srv/lab/odd.txt; echo "alice can read: $?"
sudo -u bob   test -r /srv/lab/odd.txt; echo "bob   can read: $?"
```

Esperado: `alice can read: 1`, `bob can read: 0` (0 = verdadero).

5. Confirmá que la propiedad todavía le permite a `alice` arreglarlo — los *metadatos* son de ella:

```bash
sudo -u alice chmod 640 /srv/lab/odd.txt
ls -l odd.txt
```

Esperado: `-rw-r-----. 1 alice devs`.

### Preguntas de control — bloque 3

- **Q3.1** Enunciá la regla de verificación de acceso en una sola oración que explique por qué a `alice` se le negó y a `bob` se le permitió.
- **Q3.2** `alice` no pudo leer el archivo pero *sí* pudo hacerle `chmod`. ¿Qué bit de permiso otorgó el `chmod`? (Cuidado — esto es una trampa.)
- **Q3.3** El archivo `data.db` es `-rw-rw----  root  devs`. La usuaria `carol` está en `devs`. ¿Puede leerlo? Ahora el archivo pasa a ser `-rw-rw---- carol devs` y el modo pasa a ser `----rw----`. ¿Puede leerlo?
- **Q3.4** ¿Por qué `test -r` es una verificación mejor dentro de un script que parsear la salida de `ls -l`?

---

## Ejercicio 4 — Permisos de directorio: `r`, `w` y `x` significan otra cosa

1. Construí un directorio con un archivo adentro:

```bash
cd /srv/lab
sudo rm -rf dirlab && sudo mkdir dirlab
sudo sh -c 'echo "secret payload" > /srv/lab/dirlab/file.txt'
sudo chmod 644 /srv/lab/dirlab/file.txt
```

2. **Solo ejecución (`--x`) — travesía sin listado:**

```bash
sudo chmod 0711 /srv/lab/dirlab
sudo -u alice ls /srv/lab/dirlab            ; echo "ls   exit=$?"
sudo -u alice cat /srv/lab/dirlab/file.txt  ; echo "cat  exit=$?"
```

Esperado:

```
ls: cannot open directory '/srv/lab/dirlab': Permission denied
ls   exit=2
secret payload
cat  exit=0
```

3. **Solo lectura (`r--`) — nombres sin travesía:**

```bash
sudo chmod 0744 /srv/lab/dirlab
sudo -u alice ls    /srv/lab/dirlab ; echo "ls    exit=$?"
sudo -u alice ls -l /srv/lab/dirlab ; echo "ls -l exit=$?"
sudo -u alice cat   /srv/lab/dirlab/file.txt ; echo "cat exit=$?"
```

Esperado:

```
file.txt
ls    exit=0
ls: cannot access '/srv/lab/dirlab/file.txt': Permission denied
total 0
ls -l exit=1
cat: /srv/lab/dirlab/file.txt: Permission denied
cat exit=0 → 1
```

4. **Escritura + ejecución — la regla del borrado.** Dale a `alice` escritura sobre el directorio pero mantené el archivo como solo lectura para ella:

```bash
sudo chmod 0777 /srv/lab/dirlab
sudo chmod 0444 /srv/lab/dirlab/file.txt
sudo -u alice rm -f /srv/lab/dirlab/file.txt ; echo "rm exit=$?"
ls -l /srv/lab/dirlab
```

Esperado: el archivo **desapareció**, `rm exit=0` (el `rm` interactivo puede preguntar; `-f` lo suprime).

5. El caso inverso — un archivo escribible en un directorio no escribible:

```bash
sudo sh -c 'echo again > /srv/lab/dirlab/file.txt'
sudo chmod 0666 /srv/lab/dirlab/file.txt
sudo chmod 0755 /srv/lab/dirlab
sudo -u alice sh -c 'echo appended >> /srv/lab/dirlab/file.txt' ; echo "write exit=$?"
sudo -u alice rm -f /srv/lab/dirlab/file.txt                    ; echo "rm    exit=$?"
```

Esperado: la escritura tiene éxito (`exit=0`), la eliminación falla con `Permission denied` (`exit=1`).

### Preguntas de control — bloque 4

- **Q4.1** Para un directorio, definí `r`, `w` y `x` en una línea cada uno.
- **Q4.2** ¿Por qué `ls -l dir` falla mientras que `ls dir` a secas tiene éxito en un directorio `r--`?
- **Q4.3** ¿Qué permiso, sobre qué objeto, decide si un usuario puede borrar `file.txt`? ¿Qué permiso del *archivo* es irrelevante para esa decisión?
- **Q4.4** `/srv/data/reports/q3.csv` es `-rw-rw-rw-`, pero un usuario recibe `Permission denied` al abrirlo. Nombrá dos causas distintas ubicadas fuera del archivo mismo.
- **Q4.5** ¿Qué modo le darías a un directorio que debe permitirle a un servicio *encontrar* un archivo conocido dentro de él pero nunca enumerar su contenido?

---

## Ejercicio 5 — `umask`: la máscara que da forma a cada archivo nuevo

1. Leé la máscara actual en ambas notaciones:

```bash
umask
umask -S
umask -p
```

Esperado en la mayoría de las distribuciones:

```
0022
u=rwx,g=rx,o=rx
umask 0022
```

2. Observá los dos modos base — **666 para archivos, 777 para directorios**:

```bash
cd /srv/lab && mkdir -p umasklab && cd umasklab
umask 022
touch f022 ; mkdir d022
umask 027
touch f027 ; mkdir d027
umask 077
touch f077 ; mkdir d077
umask 002
touch f002 ; mkdir d002
find . -maxdepth 1 -mindepth 1 -printf '%m %y %p\n' | sort -k3
```

Esperado:

```
660 f ./f002
775 d ./d002
644 f ./f022
755 d ./d022
640 f ./f027
750 d ./d027
600 f ./f077
700 d ./d077
```

3. Demostrá que `umask` es un **AND-NOT a nivel de bits**, no una resta:

```bash
umask 123
touch f123 ; mkdir d123
stat -c '%a %n' f123 d123
```

Esperado:

```
644 f123
654 d123
```

La resta habría predicho `543` y `654`. Verificá la aritmética real:

```
file: 666 = 110 110 110
umask 123 = 001 010 011   → ~umask = 110 101 100
AND                        = 110 100 100 = 644
```

4. El `umask` simbólico especifica los bits a **conservar**, no los bits a quitar:

```bash
umask u=rwx,g=rx,o=
umask          # numeric
touch fsym ; mkdir dsym
stat -c '%a %n' fsym dsym
```

Esperado:

```
0027
640 fsym
750 dsym
```

5. `umask` es un atributo por proceso heredado por los hijos — es un builtin de la shell, no un programa:

```bash
type umask
umask 077
bash -c 'umask'            # child inherits
( umask 002; umask )       # subshell change is local
umask                      # parent unchanged
```

Esperado: `umask is a shell builtin`, después `0077`, `0002`, `0077`.

6. Qué herramientas respetan la máscara y cuáles la ignoran:

```bash
umask 077
printf 'payload\n' > src.txt ; chmod 644 src.txt
cp src.txt cp_default.txt
cp -p src.txt cp_preserve.txt
mv src.txt moved.txt
mkdir -m 755 dir_m
install -m 644 moved.txt installed.txt
mkfifo fifo_masked
ln -s moved.txt link_masked
stat -c '%a %N' cp_default.txt cp_preserve.txt moved.txt dir_m installed.txt fifo_masked link_masked
```

Esperado:

```
600 'cp_default.txt'
644 'cp_preserve.txt'
644 'moved.txt'
755 'dir_m'
644 'installed.txt'
600 'fifo_masked'
777 'link_masked' -> 'moved.txt'
```

7. Restaurá una máscara sensata y encontrá dónde se establece en el login:

```bash
umask 022
grep -rn --include='*' -e '^\s*umask' -e '^UMASK' /etc/profile /etc/profile.d/ /etc/bashrc /etc/bash.bashrc /etc/login.defs ~/.bashrc ~/.profile 2>/dev/null
grep -rn 'pam_umask' /etc/pam.d/ 2>/dev/null
```

### Preguntas de control — bloque 5

- **Q5.1** ¿Por qué un archivo regular recién creado nunca puede tener un bit de ejecución, sea cual sea la máscara?
- **Q5.2** Con `umask 027`, dá el modo resultante de un archivo nuevo y de un directorio nuevo.
- **Q5.3** Necesitás que los archivos nuevos sean escribibles por el grupo e invisibles para los demás. ¿Qué máscara? ¿Qué modo produce para archivos y para directorios?
- **Q5.4** Explicá el resultado `umask 123 → 644` en términos de operaciones de bits.
- **Q5.5** `cp src.txt dst.txt` produjo un destino `600` a partir de un origen `644`. ¿Qué pasó, y qué flag lo evita?
- **Q5.6** ¿Por qué `umask` es un builtin de la shell y no `/usr/bin/umask`?
- **Q5.7** Un trabajo de cron crea archivos como `600` aunque tu `umask` interactivo es `002`. Dá la razón probable y el arreglo robusto dentro del trabajo.

---

## Ejercicio 6 — Propiedad: `chown`, `chgrp` y el campo de grupo

1. Creá un archivo e inspeccioná los dos campos de propiedad:

```bash
cd /srv/lab
sudo rm -rf ownlab && mkdir ownlab && cd ownlab
touch app.conf
stat -c '%U:%G %a %n' app.conf
```

2. Cambiá solo el grupo — ambas formas son equivalentes:

```bash
sudo chgrp devs app.conf
sudo chown :ops  app.conf
stat -c '%U:%G' app.conf
```

Esperado: `student:ops`.

3. Cambiá propietario y grupo juntos, después verificá con IDs numéricos:

```bash
sudo chown alice:devs app.conf
stat -c '%U(%u):%G(%g)' app.conf
sudo chown 0:0 app.conf          # numeric IDs are accepted too
stat -c '%U:%G' app.conf
```

4. **Quién puede cambiar qué** — probá el límite de privilegios:

```bash
sudo chown alice:alice app.conf
sudo -u alice chown bob /srv/lab/ownlab/app.conf ; echo "give away: exit=$?"
sudo -u alice chgrp devs /srv/lab/ownlab/app.conf ; echo "chgrp devs: exit=$?"
sudo -u alice chgrp ops  /srv/lab/ownlab/app.conf ; echo "chgrp ops:  exit=$?"
```

Esperado:

```
chown: changing ownership of '/srv/lab/ownlab/app.conf': Operation not permitted
give away: exit=1
chgrp devs: exit=0
chgrp ops:  exit=1        # chown: changing group ...: Operation not permitted
```

5. **La trampa de producción: `chown` limpia SUID/SGID en los ejecutables.**

```bash
sudo install -m 4755 -o root -g root /bin/true /srv/lab/ownlab/tool
stat -c '%A %a %U:%G' /srv/lab/ownlab/tool
sudo chown alice /srv/lab/ownlab/tool
stat -c '%A %a %U:%G' /srv/lab/ownlab/tool
```

Esperado:

```
-rwsr-xr-x 4755 root:root
-rwxr-xr-x 755 alice:root
```

El bit especial desapareció. En un script de despliegue el orden debe ser, por lo tanto, **`chown` primero, `chmod` último**.

6. Propiedad recursiva, y las opciones `-h` / `--reference`:

```bash
mkdir -p tree/sub && touch tree/sub/a && ln -s a tree/sub/a.lnk
sudo chown -R alice:devs tree
sudo chown -h bob tree/sub/a.lnk        # the link itself, not the target
ls -l tree/sub
sudo chown --reference=/etc/hostname tree/sub/a
stat -c '%U:%G %n' tree/sub/a /etc/hostname
```

7. Grupos suplementarios y el grupo *efectivo* usado en el momento de la creación:

```bash
sudo -u bob sh -c 'cd /srv/lab/ownlab && id -gn && touch bob_default && ls -l bob_default'
sudo -u bob sh -c 'cd /srv/lab/ownlab && sg devs -c "touch bob_asdevs; ls -l bob_asdevs"'
```

Esperado: `bob_default` pertenece a `bob:bob`, `bob_asdevs` a `bob:devs`. `newgrp devs` hace lo mismo de forma interactiva iniciando una shell nueva con `devs` como grupo primario.

### Preguntas de control — bloque 6

- **Q6.1** ¿Por qué `root` puede regalar un archivo pero el propietario no?
- **Q6.2** ¿Bajo qué condición puede un propietario no-root ejecutar `chgrp` con éxito?
- **Q6.3** Después de `sudo chown alice tool`, el modo cayó de `4755` a `755`. Explicá por qué el kernel hace esto y contra qué protege.
- **Q6.4** ¿Cuál es la diferencia entre `chown -R` y `chown -h`, y cuándo importa `-h`?
- **Q6.5** `bob` pertenece a `devs` pero sus archivos nuevos pertenecen al grupo `bob`. Nombrá dos maneras distintas de hacer que sus archivos nuevos caigan en `devs` — una por comando, una estructural.
- **Q6.6** Escribí un único comando que haga que todo objeto bajo `/srv/app` pertenezca a `www-data:www-data`.

---

## Ejercicio 7 — SGID en directorios: la receta del proyecto compartido

1. Construí un directorio de equipo de la manera ingenua y mirá cómo falla:

```bash
sudo rm -rf /srv/projects/apollo
sudo mkdir -p /srv/projects/apollo
sudo chown root:devs /srv/projects/apollo
sudo chmod 0770 /srv/projects/apollo
sudo -u alice sh -c 'cd /srv/projects/apollo && touch alice_note.txt'
ls -l /srv/projects/apollo
```

Esperado:

```
-rw-r--r--. 1 alice alice 0 Aug 26 10:40 alice_note.txt
```

El archivo cayó en el grupo `alice`, no en `devs`, así que `bob` no puede escribir en él.

```bash
sudo -u bob sh -c 'echo hi >> /srv/projects/apollo/alice_note.txt' ; echo "bob write exit=$?"
```

Esperado: `Permission denied`, `exit=1`.

2. Aplicá el **bit SGID** al directorio:

```bash
sudo chmod g+s /srv/projects/apollo
ls -ld /srv/projects/apollo
stat -c '%a %A' /srv/projects/apollo
```

Esperado:

```
drwxrws---. 2 root devs 4096 Aug 26 10:40 /srv/projects/apollo
2770 drwxrws---
```

3. Verificá la herencia de grupo para los objetos nuevos — y que se propaga a los subdirectorios:

```bash
sudo -u alice sh -c 'cd /srv/projects/apollo && touch alice_v2.txt && mkdir sub'
ls -l /srv/projects/apollo
ls -ld /srv/projects/apollo/sub
```

Esperado:

```
-rw-r--r--. 1 alice devs 0 ... alice_v2.txt
drwxr-sr-x. 2 alice devs 4096 ... sub
```

El **grupo** se hereda, y el subdirectorio también heredó el **bit SGID mismo** (`s` en el campo de grupo).

4. El modo sigue estando mal para la colaboración — `644` no le da al grupo el bit de escritura. Corregí la máscara *para el proceso que escribe*:

```bash
sudo -u alice sh -c 'cd /srv/projects/apollo && umask 007 && touch alice_v3.txt && mkdir sub2'
stat -c '%a %U:%G %n' /srv/projects/apollo/alice_v3.txt /srv/projects/apollo/sub2
sudo -u bob sh -c 'echo "bob was here" >> /srv/projects/apollo/alice_v3.txt' ; echo "bob write exit=$?"
```

Esperado:

```
660 alice:devs /srv/projects/apollo/alice_v3.txt
2770 alice:devs /srv/projects/apollo/sub2
bob write exit=0
```

**SGID arregla el grupo; solo la umask arregla el modo. Necesitás los dos.**

5. Reparar los archivos preexistentes en una sola pasada:

```bash
sudo chgrp -R devs /srv/projects/apollo
sudo chmod -R g+w  /srv/projects/apollo
sudo find /srv/projects/apollo -type d -exec chmod g+s {} +
find /srv/projects/apollo -printf '%m %y %u:%g %p\n'
```

6. **Trampa de GNU `chmod`** — modos numéricos y directorios:

```bash
sudo chmod 770 /srv/projects/apollo
stat -c '%a' /srv/projects/apollo
sudo chmod 0770 /srv/projects/apollo
stat -c '%a' /srv/projects/apollo
sudo chmod 2770 /srv/projects/apollo
stat -c '%a' /srv/projects/apollo
```

Esperado:

```
2770
770
2770
```

GNU `chmod` **preserva** los bits SUID/SGID de un directorio cuando le das un modo de tres dígitos. Escribí siempre cuatro dígitos en los scripts — la forma de tres dígitos no es portable y ha sorprendido a muchos operadores en ambos sentidos.

7. Fijate en el otro significado de SGID, sobre *ejecutables*:

```bash
ls -l /usr/bin/write /usr/bin/wall 2>/dev/null
```

Esperado (varía según la distribución):

```
-rwxr-sr-x. 1 root tty 23000 ... /usr/bin/write
```

Acá SGID significa "ejecutar con el grupo efectivo `tty`", la contraparte del lado de grupo de SUID.

### Preguntas de control — bloque 7

- **Q7.1** SGID tiene dos significados completamente distintos. Enunciá ambos, y decí qué tipo de objeto dispara cuál.
- **Q7.2** Después de `chmod g+s` los archivos nuevos eran `alice:devs 644`. ¿Por qué eso sigue siendo inservible para el equipo, y qué lo arregla?
- **Q7.3** ¿Cuál es el modo de cuatro dígitos de un directorio compartido que es escribible por el grupo, SGID y cerrado para los demás?
- **Q7.4** Tu compañero de equipo ejecutó `chmod 2770` solo sobre el padre, pero los archivos creados en un subdirectorio creado *antes* de eso siguen cayendo en el grupo equivocado. ¿Por qué, y cuál es el comando de reparación?
- **Q7.5** ¿Por qué `chmod 770 dir` dejó vivo el bit SGID mientras que `chmod 0770 dir` lo eliminó?
- **Q7.6** En lugar de depender de la `umask` de cada usuario, ¿qué mecanismo (fuera del objetivo 104.5) impondría valores por defecto escribibles por el grupo por directorio?

---

## Ejercicio 8 — SUID: qué hace, y qué se niega Linux a hacer con él

1. Encontrá binarios SUID reales en el sistema y leé sus modos:

```bash
ls -l /usr/bin/passwd /usr/bin/su /usr/bin/sudo /usr/bin/mount 2>/dev/null
```

Esperado (depende de la distribución):

```
-rwsr-xr-x. 1 root root 32656 ... /usr/bin/passwd
-rwsr-xr-x. 1 root root 48944 ... /usr/bin/su
---s--x--x. 1 root root 182600 ... /usr/bin/sudo
-rwsr-xr-x. 1 root root 55696 ... /usr/bin/mount
```

2. Razoná el *porqué*: `/etc/shadow` es `-rw-r-----  root shadow` (o `0000 root root`), y sin embargo un usuario sin privilegios cambia su propia contraseña.

```bash
ls -l /etc/shadow
sudo -u alice sh -c 'cat /etc/shadow' ; echo "direct read exit=$?"
```

Esperado: `Permission denied`, `exit=1`. `passwd` tiene éxito solo porque SUID hace que su **UID efectivo** sea `root`.

3. Distinguí la `s` minúscula de la `S` mayúscula:

```bash
cd /srv/lab && sudo rm -rf suidlab && mkdir suidlab && cd suidlab
sudo install -m 0755 -o root /bin/true t1
sudo chmod u+s t1 ; stat -c '%A %a %n' t1
sudo chmod u-x t1 ; stat -c '%A %a %n' t1
sudo chmod u+x t1 ; stat -c '%A %a %n' t1
```

Esperado:

```
-rwsr-xr-x 4755 t1
-rwSr-xr-x 4655 t1
-rwsr-xr-x 4755 t1
```

`S` mayúscula = el bit especial está puesto pero el **bit de ejecución correspondiente no** — casi siempre un error en un ejecutable.

4. **Demostrá que Linux ignora SUID en los scripts interpretados:**

```bash
cat > whoami.sh <<'EOF'
#!/bin/sh
echo "real uid=$(id -ru)  effective uid=$(id -u)  user=$(id -un)"
EOF
sudo chown root:root whoami.sh
sudo chmod 4755 whoami.sh
ls -l whoami.sh
sudo -u alice /srv/lab/suidlab/whoami.sh
```

Esperado:

```
-rwsr-xr-x. 1 root root 78 Aug 26 10:55 whoami.sh
real uid=1001  effective uid=1001  user=alice
```

El bit está puesto, la cadena de modo muestra `s`, y no hace **nada**. El kernel de Linux se niega a respetar set-user-ID en scripts `#!` (una defensa deliberada contra una clase de ataques de carrera e inyección de argumentos).

5. *(Opcional, requiere un compilador de C)* — la misma prueba con un binario real:

```bash
cat > euid.c <<'EOF'
#include <stdio.h>
#include <unistd.h>
int main(void) {
    printf("real uid=%d  effective uid=%d\n", (int)getuid(), (int)geteuid());
    return 0;
}
EOF
cc -o euid euid.c && sudo chown root:root euid && sudo chmod 4755 euid
sudo -u alice /srv/lab/suidlab/euid
```

Esperado:

```
real uid=1001  effective uid=0
```

6. Auditá todo el sistema de archivos en busca de binarios SUID/SGID — una tarea estándar de endurecimiento:

```bash
sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%m %u %g %p\n' 2>/dev/null | sort
```

Forma esperada:

```
2755 root tty   /usr/bin/write
4755 root root  /usr/bin/mount
4755 root root  /usr/bin/passwd
4755 root root  /usr/bin/su
```

7. Limpiá tus propios artefactos SUID de inmediato — nunca dejes uno atrás:

```bash
sudo chmod -R a-s /srv/lab/suidlab
find /srv/lab/suidlab -printf '%m %p\n'
```

### Preguntas de control — bloque 8

- **Q8.1** Con precisión: ¿qué UID cambia SUID — el real, el efectivo o ambos?
- **Q8.2** `-rwSr--r--` frente a `-rwsr-xr-x`: ¿cuál es la diferencia y cuál de los dos es un error de configuración?
- **Q8.3** Tu `backup.sh` es `4755 root:root` pero aun así no puede leer `/etc/shadow`. Explicalo, y dá una alternativa legítima para otorgar el privilegio.
- **Q8.4** Dá el octal de: SUID + `rwx` propietario + `r-x` grupo + `---` otros. Y el de SGID + `rwx` propietario + `r-x` grupo + `r-x` otros.
- **Q8.5** Escribí el comando `find` que lista solo archivos SUID, y explicá por qué `-perm -4000` no es lo mismo que `-perm 4000`.
- **Q8.6** ¿Por qué un binario SUID innecesario propiedad de `root` se considera un riesgo de escalada de privilegios incluso cuando "hace algo inofensivo"?

---

## Ejercicio 9 — El sticky bit: escritura compartida, borrado privado

1. Mirá el ejemplo canónico:

```bash
ls -ld /tmp /var/tmp
stat -c '%a %A %U:%G %n' /tmp
```

Esperado:

```
drwxrwxrwt. 18 root root 4096 Aug 26 10:58 /tmp
1777 drwxrwxrwt root:root /tmp
```

2. Reproducí el problema que el bit resuelve. Primero, un directorio escribible por todos **sin** él:

```bash
sudo rm -rf /srv/lab/dropbox && sudo mkdir /srv/lab/dropbox
sudo chmod 0777 /srv/lab/dropbox
sudo -u alice sh -c 'cd /srv/lab/dropbox && echo "alice data" > alice.txt && chmod 600 alice.txt'
ls -l /srv/lab/dropbox
sudo -u bob rm -f /srv/lab/dropbox/alice.txt ; echo "bob rm exit=$?"
ls -l /srv/lab/dropbox
```

Esperado: `bob rm exit=0` y el directorio queda vacío — `bob` destruyó un archivo `600` que ni siquiera podía leer.

3. Ahora poné el **sticky bit** y repetí:

```bash
sudo chmod +t /srv/lab/dropbox        # or: chmod 1777
ls -ld /srv/lab/dropbox
sudo -u alice sh -c 'cd /srv/lab/dropbox && echo "alice data" > alice.txt'
sudo -u bob rm -f /srv/lab/dropbox/alice.txt   ; echo "bob rm    exit=$?"
sudo -u bob mv /srv/lab/dropbox/alice.txt /tmp/ ; echo "bob mv    exit=$?"
sudo -u bob sh -c 'echo tampered >> /srv/lab/dropbox/alice.txt' ; echo "bob write exit=$?"
sudo -u alice rm -f /srv/lab/dropbox/alice.txt ; echo "alice rm  exit=$?"
```

Esperado:

```
drwxrwxrwt. 2 root root 4096 ... /srv/lab/dropbox
rm: cannot remove '/srv/lab/dropbox/alice.txt': Operation not permitted
bob rm    exit=1
mv: cannot move ...: Operation not permitted
bob mv    exit=1
bob write exit=0            ← the file mode still governs content
alice rm  exit=0
```

Fijate en el errno exacto: **`Operation not permitted` (EPERM)**, no `Permission denied` (EACCES) — una huella útil al leer logs.

4. Distinguí la `t` minúscula de la `T` mayúscula:

```bash
sudo chmod 1770 /srv/lab/dropbox ; stat -c '%a %A' /srv/lab/dropbox
sudo chmod 1777 /srv/lab/dropbox ; stat -c '%a %A' /srv/lab/dropbox
```

Esperado:

```
1770 drwxrwx--T
1777 drwxrwxrwt
```

5. El sticky bit sobre un **archivo regular** carece de sentido en Linux (era una pista de retención en swap en el Unix histórico y hoy el kernel lo ignora):

```bash
touch /srv/lab/sticky_file && chmod 1644 /srv/lab/sticky_file
stat -c '%a %A %n' /srv/lab/sticky_file
```

### Preguntas de control — bloque 9

- **Q9.1** En `drwxrwxrwt`, ¿quién puede borrar exactamente un archivo dentro del directorio?
- **Q9.2** ¿Por qué `1777` es el modo correcto para `/tmp` y `0777` una vulnerabilidad seria?
- **Q9.3** Con el sticky bit puesto, `bob` igual pudo agregar contenido a `alice.txt`. ¿Por qué? ¿Qué cambio lo detendría?
- **Q9.4** ¿Qué te dice una `T` mayúscula en la última posición?
- **Q9.5** Asociá cada bit especial con el dígito octal y con la posición donde aparece su letra en la cadena de modo. Completá la tabla.

| Bit | Octal | Simbólico | La letra aparece en | Significado en un archivo | Significado en un directorio |
|---|---|---|---|---|---|
| SUID | ? | ? | ? | ? | ? |
| SGID | ? | ? | ? | ? | ? |
| Sticky | ? | ? | ? | ? | ? |

---

## Ejercicio 10 — Diagnosticar "Permission denied" como un SRE

1. Fabricá una falla realista: el archivo está bien, la **ruta** no.

```bash
sudo rm -rf /srv/lab/deep
sudo mkdir -p /srv/lab/deep/level1/level2
sudo sh -c 'echo "config" > /srv/lab/deep/level1/level2/app.yaml'
sudo chmod 0644 /srv/lab/deep/level1/level2/app.yaml
sudo chmod 0755 /srv/lab/deep /srv/lab/deep/level1/level2
sudo chmod 0750 /srv/lab/deep/level1
sudo chown root:root /srv/lab/deep/level1

sudo -u alice cat /srv/lab/deep/level1/level2/app.yaml ; echo "exit=$?"
```

Esperado: `Permission denied`, aunque el archivo mismo es `644`.

2. Recorré la ruta entera en un solo comando en lugar de cinco llamadas a `ls -ld`:

```bash
sudo -u alice namei -l /srv/lab/deep/level1/level2/app.yaml
```

Salida esperada:

```
f: /srv/lab/deep/level1/level2/app.yaml
 dr-xr-xr-x root root /
 drwxr-xr-x root root srv
 drwxrwxrwx root root lab
 drwxr-xr-x root root deep
 drwxr-x--- root root level1        ← the offending component
 level1 - Permission denied
```

3. Confirmá la hipótesis arreglando solo el bit de travesía:

```bash
sudo chmod o+x /srv/lab/deep/level1
sudo -u alice cat /srv/lab/deep/level1/level2/app.yaml ; echo "exit=$?"
ls -ld /srv/lab/deep/level1
```

Esperado: la lectura tiene éxito, `exit=0`, y el directorio es `drwxr-x--x` — `alice` puede atravesarlo pero sigue sin poder listarlo.

4. Probá los permisos *como la identidad objetivo* antes de cambiar nada — la verificación no destructiva:

```bash
sudo -u alice test -r /srv/lab/deep/level1/level2/app.yaml && echo READABLE  || echo NOT-READABLE
sudo -u alice test -w /srv/lab/deep/level1/level2/app.yaml && echo WRITABLE  || echo NOT-WRITABLE
sudo -u alice test -x /srv/lab/deep/level1                 && echo TRAVERSABLE || echo NOT-TRAVERSABLE
```

5. Aprendé las tres formas de `find -perm` — se confunden con frecuencia:

```bash
cd /srv/lab && sudo rm -rf permlab && mkdir permlab && cd permlab
touch a b c d
chmod 644 a ; chmod 664 b ; chmod 666 c ; chmod 700 d

find . -maxdepth 1 -type f -perm 644  -printf 'exact  : %m %p\n'
find . -maxdepth 1 -type f -perm -644 -printf 'all-of : %m %p\n'
find . -maxdepth 1 -type f -perm /022 -printf 'any-of : %m %p\n'
find . -maxdepth 1 -type f -perm -o+w -printf 'world-w: %m %p\n'
```

Esperado:

```
exact  : 644 ./a
all-of : 644 ./a
all-of : 664 ./b
all-of : 666 ./c
any-of : 664 ./b
any-of : 666 ./c
world-w: 666 ./c
```

6. Los dos barridos de auditoría estándar, que vale la pena memorizar:

```bash
sudo find / -xdev -type f -perm -0002 -printf '%m %u %g %p\n' 2>/dev/null   # world-writable files
sudo find / -xdev -type d -perm -0002 ! -perm -1000 -printf '%m %p\n' 2>/dev/null  # world-writable dirs without sticky
sudo find / -xdev -nouser -o -xdev -nogroup 2>/dev/null                      # orphaned ownership
```

7. Leé la distinción de errno una vez más, porque enruta tu diagnóstico:

| Mensaje | errno | Causa típica en 104.5 |
|---|---|---|
| `Permission denied` | `EACCES` | bits de modo del archivo o de un componente de la ruta |
| `Operation not permitted` | `EPERM` | borrado con sticky bit, `chown` a otro usuario, capacidad faltante |

### Preguntas de control — bloque 10

- **Q10.1** Un archivo `644` que nadie puede leer — enumerá las tres categorías independientes de causa que verificarías, en orden.
- **Q10.2** ¿Qué ventaja tiene `namei -l` sobre una secuencia de comandos `ls -ld`?
- **Q10.3** Distinguí `find -perm 664`, `find -perm -664` y `find -perm /664` en una oración cada uno.
- **Q10.4** Escribí el comando que encuentra todo directorio escribible por todos al que le falta el sticky bit, solo en el sistema de archivos local.
- **Q10.5** `rm` falló con `Operation not permitted` en lugar de `Permission denied`. ¿Qué te dice esa diferencia de una sola palabra?
- **Q10.6** `root` recibe `Permission denied` al intentar ejecutar un archivo. ¿Cómo es posible, dado que `root` evade las verificaciones de permisos?

---

## Limpieza

```bash
sudo rm -rf /srv/lab /srv/projects/apollo
sudo userdel -r alice
sudo userdel -r bob
sudo groupdel devs
sudo groupdel ops
umask 022
```

---

<details>
<summary><strong>Respuestas</strong> — expandí solo después de terminar los ejercicios</summary>

### Bloque 0

**A0.1** `gid=` es el **grupo primario**: el GID adjunto a cada proceso que el usuario inicia y, por defecto, el grupo asignado a cada archivo que crea. `groups=` lista el grupo primario más todos los **grupos suplementarios**; esos otorgan acceso pero nunca se usan como grupo por defecto de un archivo nuevo. El GID primario viene del cuarto campo de `/etc/passwd`; los suplementarios, de la lista de miembros en `/etc/group`.

**A0.2** No. La membresía de grupo se resuelve en la **creación del login/sesión** y se almacena en las credenciales del proceso, que luego heredan los hijos. Una shell ya en ejecución conserva su viejo conjunto de credenciales. `bob` debe cerrar sesión y volver a entrar, o iniciar una sesión nueva (`newgrp ops`, `sg ops -c ...`, o un `su - bob` fresco).

**A0.3** `/etc/group`. La línea es `devs:x:2001:alice,bob`; los miembros viven en el **cuarto (último) campo**, separados por comas. Notá que un usuario cuyo grupo *primario* sea `devs` **no** va a aparecer en ese campo — por eso `id` es la verificación confiable, no `grep devs /etc/group`.

### Bloque 1

**A1.1** El **primer** carácter es el tipo de archivo, no un permiso: `-` regular, `d` directorio, `l` enlace simbólico, `p` FIFO/pipe con nombre, `s` socket, `c` dispositivo de caracteres, `b` dispositivo de bloques. Los nueve que siguen son las tres tríadas de permisos.

**A1.2** Dos hechos independientes. (a) Linux no usa en absoluto los bits de modo de un enlace simbólico; el kernel siempre los almacena como `0777` para que nunca restrinjan nada — el acceso lo deciden los permisos del **destino** más los permisos de travesía de la ruta. (b) No existe una llamada al sistema `lchmod()` en Linux, así que `chmod` sobre un argumento que es un enlace simbólico lo desreferencia y modifica el destino. Usá `chown -h` cuando específicamente necesites actuar sobre el enlace mismo (`chown` *sí* tiene la variante sin desreferenciar).

**A1.3** `-rwsr-x---` → `4750`. Razonamiento: SUID = 4 en el dígito alto; propietario `rwx` = 7 (la `s` implica que el bit de ejecución está presente porque es minúscula); grupo `r-x` = 5; otros `---` = 0.
`2750` para un directorio → `drwxr-s---`. SGID = 2 → una `s` en la posición de ejecución del grupo, con `r-x` de grupo, lo que significa que el bit de ejecución está ahí, así que va en minúscula.

**A1.4** El `+` final significa que hay una **ACL** (u otro método de acceso alternativo) adjunta, así que los nueve bits de modo ya no son el cuadro completo del control de acceso — una entrada de ACL puede otorgarle a ese usuario acceso de escritura directamente. Confirmalo con `getfacl config.ini`. (Relacionado: el `.` que se ve en otros lados indica un contexto SELinux/MAC y no otorga nada; un espacio en blanco significa ninguno de los dos.)

**A1.5** `stat -c %f` imprime el `st_mode` en crudo en hexadecimal, tipo de archivo *y* bits de permiso juntos. `0x81a4` = `0o100644`: la parte alta `0o100000` es `S_IFREG` (archivo regular) y los 12 bits bajos `0o0644` son el modo. Los directorios empiezan con `0x41…` (`S_IFDIR`, `0o040000`), los enlaces simbólicos con `0xa1ff` (`S_IFLNK` + `0777`). Usá `%a` cuando quieras solo los bits de permiso.

### Bloque 2

**A2.1** El operador `=` **asigna** los permisos listados a la tríada nombrada y borra todo lo demás *solo en esa tríada*. `chmod g=` significa "el grupo obtiene exactamente nada"; `u` y `o` no están nombrados en la cláusula, así que quedan intactos — de ahí `rwx---rwx` = `707`. Solo `a=` (o `ugo=`) tocaría las tres.

**A2.2** `a+x` pone el bit de ejecución en **todos** los objetos, convirtiendo archivos de datos ordinarios en ejecutables (rotos). `a+X` lo pone solo cuando el objeto es un **directorio**, o cuando el archivo **ya tiene al menos un bit de ejecución** — es decir, preserva la distinción ejecutable/no ejecutable que ya existe en el árbol. Por eso `chmod -R a=rX,u+w dir` es el "one-liner" idiomático para "hacer este árbol legible y transitable", y `chmod -R 755 dir` o `chmod -R a+x dir` no lo son.

**A2.3** Octal: `chmod 640 file`. Simbólico: `chmod u=rw,g=r,o= file` (equivalentemente `chmod u=rw,g=r,o-rwx file`). Notá que `chmod u+rw,g+r,o-rwx` *no* es equivalente — agrega en lugar de reemplazar, así que bits preexistentes como `u+x` sobrevivirían.

**A2.4** Para un **archivo regular**, ninguna diferencia: el dígito alto omitido se toma como `0`, así que ambos limpian SUID/SGID/sticky. Para un **directorio** bajo GNU coreutils *sí* hay una diferencia: `chmod 755 dir` **preserva** un bit SUID/SGID existente, mientras que `chmod 0755 dir` lo limpia explícitamente. Como esto es una extensión de GNU y no comportamiento POSIX, escribí siempre la forma de cuatro dígitos en los scripts.

**A2.5** Seguridad: (1) cualquier usuario local o cualquier cuenta de servicio comprometida puede reescribir el código y la configuración de la aplicación, convirtiendo un bug de solo lectura en ejecución arbitraria de código bajo la identidad del servicio; (2) despoja de su valor de auditoría a la propiedad — ya no podés decir quién *se suponía* que podía modificar qué, y los barridos con `find -perm -0002` van a marcar el árbol entero. Funcional: muchos demonios **se niegan a arrancar** o ignoran silenciosamente archivos escribibles por el grupo y por todos exactamente por esta razón (SSH se niega ante un `~/.ssh` y claves de host escribibles por todos; `sudo` se niega ante un `sudoers` escribible por el grupo; cron ignora los crontabs laxos). `chmod -R 777` también pone el bit de ejecución en todo archivo de datos, destruyendo la información en la que se apoya `a+X`, así que el cambio no es limpiamente reversible.

### Bloque 3

**A3.1** El kernel selecciona **exactamente una** tríada y se detiene: si el UID efectivo del proceso es igual al propietario del archivo, solo se consultan los bits del **propietario**; si no, si el GID efectivo o cualquier GID suplementario es igual al grupo del archivo, solo se consultan los bits del **grupo**; si no, los bits de **otros**. Los permisos nunca se acumulan entre tríadas. `alice` coincidió como propietaria y la tríada de propietario era `---`, así que se le negó — su membresía en `devs` ni siquiera se examinó. `bob` no era el propietario, coincidió por grupo y obtuvo `rwx`.

**A3.2** Ninguno. `chmod` no está gobernado en absoluto por los bits de permiso del propio archivo: el kernel lo permite si el UID efectivo de quien llama es igual al propietario del archivo (o si quien llama tiene `CAP_FOWNER`, es decir, root). **La propiedad, no el modo, controla los metadatos.** Por eso el modo de un archivo nunca puede dejar afuera a su propio dueño de forma permanente.

**A3.3** Primer caso: **sí** — no es la propietaria (lo es `root`), coincide por el grupo `devs`, y la tríada de grupo es `rw-`. Segundo caso: **no** — ahora es la propietaria, así que solo se aplica la tríada de propietario `---` y el `rw` de la tríada de grupo es inalcanzable, exactamente como `alice` en el paso 2. Sin embargo, puede hacerle `chmod` para volver atrás, ya que es la dueña.

**A3.4** `test -r` (y `[ -r ]`) le hace al **kernel** la misma pregunta que hará el eventual `open()`, con la identidad que realmente ejecuta, así que contempla de una sola vez toda la regla de selección de tríada, la travesía de la ruta, las ACLs, los montajes de solo lectura y la política MAC. Parsear `ls -l` reimplementa la regla en texto, ignora las ACLs (`+`), ignora los componentes de la ruta y se rompe con nombres de archivo inusuales. Advertencia para scripts: `test -r` es una verificación en un punto en el tiempo — una condición de carrera TOCTOU — así que para trabajo real igual intentá la operación y manejá el error.

### Bloque 4

**A4.1**
- `r` — **listar** los nombres de las entradas del directorio (`ls`).
- `w` — **modificar la lista de entradas**: crear, borrar, renombrar entradas. Solo tiene sentido junto con `x`.
- `x` — **atravesar/buscar**: resolver un nombre dentro del directorio hasta su inodo, es decir, usar el directorio como componente de una ruta y hacer `stat`/`open` sobre un nombre de archivo conocido dentro de él.

**A4.2** `ls dir` solo lee la lista de entradas del directorio, lo que requiere `r`. `ls -l` además debe hacer `stat()` sobre cada entrada, y `stat()` sobre `dir/file` requiere **permiso de búsqueda (`x`) sobre `dir`**. Con `r--` podés conocer los nombres pero nada sobre los objetos detrás de ellos — de ahí que los nombres se impriman junto con `Permission denied` y `total 0`.

**A4.3** **Escritura + ejecución sobre el directorio contenedor.** Borrar es una edición de la lista de entradas del directorio (`unlink()`), no una operación sobre el contenido del archivo. Los permisos del archivo mismo son **irrelevantes** para si puede ser eliminado — un archivo `0444` que ni siquiera podés abrir es borrable si podés escribir en su directorio. (El `rm` interactivo va a *preguntar* por un archivo protegido contra escritura, pero eso es una cortesía de `rm`, no una restricción del kernel; `rm -f` lo elimina sin decir palabra.) La excepción es el sticky bit, cubierto en el Ejercicio 9.

**A4.4** Dos cualesquiera de: (1) a un componente de la ruta le falta `x` para ese usuario — el caso clásico, diagnosticado con `namei -l`; (2) el sistema de archivos está montado como **solo lectura** o con `noexec`/`nosuid` (fallas de la clase `ENOSPC`/`EROFS`, visibles en `findmnt`); (3) una máscara de ACL reduce los permisos efectivos por debajo de lo que sugiere la cadena de modo (buscá `+` en `ls -l`, después `getfacl`); (4) SELinux o AppArmor niegan el acceso pese a que DAC lo permite (`ausearch -m avc` / `dmesg`); (5) el proceso está confinado por un montaje de namespace/contenedor que no expone esa ruta en absoluto.

**A4.5** `--x` para la clase relevante, por ejemplo `0711` (propietario completo, todos los demás solo travesía) o `0710` para un servicio acotado a un grupo. El servicio puede hacer `open("/that/dir/known-name")` pero `ls` devuelve `Permission denied`. Este es un patrón real y útil para directorios home y para directorios de entrega, aunque es oscuridad más que un límite fuerte: cualquiera que adivine un nombre entra, sujeto al modo propio de ese archivo.

### Bloque 5

**A5.1** El modo base que pasan `open(2)`/`creat(2)` para un archivo regular nuevo es `0666`; la umask solo puede **limpiar** bits, nunca ponerlos. No hay ningún bit de ejecución presente en la base, así que ningún valor de máscara puede producir uno. Los directorios parten de `0777` porque un directorio sin `x` es inutilizable. Hacer ejecutable un archivo nuevo es siempre un `chmod` separado y explícito.

**A5.2** Archivo: `0666 & ~0027` = **`640`** (`-rw-r-----`). Directorio: `0777 & ~0027` = **`750`** (`drwxr-x---`). Esta es la máscara estándar de "privado para el grupo, invisible para los demás".

**A5.3** `umask 007`. Archivos: `0666 & ~0007` = **`660`**. Directorios: `0777 & ~0007` = **`770`**. Combinala con un directorio SGID (Ejercicio 7) para lograr verdadera colaboración de grupo.

**A5.4** La máscara se aplica bit a bit como `mode = base & ~umask`, no `base - umask`. En binario: base `666` = `110 110 110`; umask `123` = `001 010 011`, así que `~umask` = `110 101 100`; el AND da `110 100 100` = `644`. Los bits ya ausentes de la base no pueden "pedirse prestados", que es precisamente por qué la resta aritmética (`666 - 123 = 543`) da la respuesta equivocada. La resta solo *coincide por casualidad* cuando ningún dígito de la umask limpia un bit que la base no tiene.

**A5.5** `cp` sin `-p` **crea un archivo nuevo** a través de `open(2)`, así que la umask se aplica: el modo del destino es `source & ~umask` = `0644 & ~0077` = `600`. `cp -p` (o `cp -a`, o `--preserve=mode`) restaura el modo del origen con un `chmod` explícito posterior, esquivando la máscara. `mv` dentro de un mismo sistema de archivos es un `rename()` — el inodo no cambia, así que el modo se preserva incondicionalmente. `install -m` y `mkdir -m` también aplican el modo explícitamente e ignoran la umask. **Corolario para despliegues:** nunca asumas que `cp` lleva los permisos; usá `install -m … -o … -g …` o `cp -p`.

**A5.6** Porque la umask es un **atributo por proceso** almacenado en el estado propio del proceso y heredado por los hijos. Un programa externo establecería la umask de su propio proceso efímero y terminaría, dejando la shell intacta. El mismo razonamiento se aplica a `cd`, `ulimit` y `export`.

**A5.7** Los trabajos de cron no ejecutan los archivos de inicialización de tu shell interactiva (`~/.bashrc`, `/etc/profile.d/*`), así que la umask cae al valor por defecto heredado del demonio — con frecuencia `022`, o `077` donde `pam_umask`/`/etc/login.defs UMASK` se aplica a la sesión de cron. Nunca confíes en la herencia: establecela **explícitamente en el trabajo**, por ejemplo `0 3 * * * umask 002 && /usr/local/bin/backup.sh`, o como primera línea dentro del script, o vía `UMask=` en la unidad de systemd si es un timer en lugar de cron.

### Bloque 6

**A6.1** Cambiar el propietario de un archivo requiere `CAP_CHOWN`, que solo tiene `root` (o un proceso al que se le haya otorgado esa capacidad). A los usuarios ordinarios se les prohíbe **regalar archivos** por dos razones concretas: les permitiría burlar las cuotas de disco volcando datos en la cuenta de otro, y les permitiría plantar un archivo — potencialmente SUID o malicioso — bajo la propiedad de una víctima. Por eso `chown` sobre un archivo que poseés igual falla con `Operation not permitted` (EPERM).

**A6.2** Un usuario no-root puede hacer `chgrp` sobre un archivo cuando se cumplen **ambas** condiciones: es el dueño del archivo, **y** es miembro del grupo destino (primario o suplementario). Por eso `alice` pudo poner el grupo en `devs` pero no en `ops` — no está en `ops`.

**A6.3** El kernel limpia `S_ISUID` y `S_ISGID` en un cambio de propiedad exitoso de un archivo ejecutable, para que cambiar la propiedad no pueda entregar silenciosamente un binario set-user-ID que ahora corre como una identidad *distinta* de aquella para la que fue auditado. En Linux esto se aplica **incluso cuando root realiza el `chown`** (desde 2.2.13 root recibe aquí el mismo trato que cualquier otro usuario); POSIX deja ese caso sin especificar. La regla práctica: en scripts de instalación y Makefiles, `chown` **antes** de `chmod`, o usá `install -m 4755 -o root -g root`, que hace ambas cosas en el orden correcto. (Caso borde: `S_ISGID` en un archivo *sin* ejecución de grupo no se limpia, porque esa combinación históricamente marcaba bloqueo obligatorio en lugar de privilegio.)

**A6.4** `-R` **recurre** dentro de los directorios, aplicando el cambio a cada objeto del árbol. `-h` actúa sobre los **enlaces simbólicos mismos** en lugar de sobre sus destinos (`lchown()` en vez de `chown()`). Son ortogonales. `-h` importa cada vez que un árbol contiene enlaces simbólicos: `chown -R` no sigue nada por defecto en GNU coreutils (cambia el enlace, no el destino, solo cuando se combina con `-h`; sin `-h` desreferencia los enlaces dados en la línea de comandos). La combinación peligrosa es `chown -R --dereference` o `chown -RL` sobre un árbol que contiene un enlace simbólico a `/etc` — va a reasignar alegremente la propiedad de archivos del sistema.

**A6.5** Por comando: `sg devs -c "touch file"` o `newgrp devs` (ambos inician un proceso cuyo grupo *primario* es `devs`). Estructural: poner el **bit SGID en el directorio contenedor** (`chmod g+s dir`) para que cada entrada nueva herede el grupo del directorio sin importar quién la cree — esta es la respuesta correcta para un árbol de proyecto compartido, porque no depende de que los usuarios se acuerden de nada. Una tercera opción, más burda, es cambiar el grupo primario de `bob` en `/etc/passwd` (`usermod -g devs bob`), lo que afecta todo lo que cree en cualquier lado.

**A6.6** `sudo chown -R www-data:www-data /srv/app`. Forma corta equivalente: `chown -R www-data: /srv/app` — dos puntos al final sin grupo significa "usar el grupo de login del usuario nombrado".

### Bloque 7

**A7.1**
- En un **directorio**: los archivos y subdirectorios nuevos creados adentro heredan el **grupo** del directorio (y los subdirectorios heredan además el bit SGID mismo, de modo que la propiedad se propaga hacia abajo por el árbol). Esto no tiene nada que ver con privilegios.
- En un **archivo ejecutable**: el proceso corre con el grupo del archivo como su **GID efectivo** — el análogo del lado de grupo de SUID. Lo usan binarios como `write`/`wall` (grupo `tty`) y algunos archivos de puntajes de juegos (grupo `games`).

**A7.2** SGID controla el **campo de grupo**, no el **modo**. Los archivos salieron `644` porque la umask de `alice` era `022`, así que la tríada de grupo no tiene `w` y los compañeros pueden leer pero no modificar. El arreglo es una umask `007` (o `002`) en el proceso que escribe, para que los archivos caigan como `660` y los directorios como `770`. SGID y umask resuelven dos mitades distintas del mismo problema; necesitás las dos.

**A7.3** **`2770`** → `drwxrws---`. (Agregá el sticky bit para un equipo en el que no se confía: `3770` → `drwxrws--T`, así los miembros pueden crear libremente pero solo borrar sus propios archivos.)

**A7.4** El bit SGID lo heredan los subdirectorios **en el momento de su creación**. Un subdirectorio que ya existía antes de que se aplicara `chmod g+s` al padre nunca recibió el bit, así que los archivos creados dentro de él siguen tomando el grupo primario de quien los crea. Repará el árbol entero con:
`sudo chgrp -R devs /srv/projects/apollo && sudo find /srv/projects/apollo -type d -exec chmod g+s {} +`
(la forma `find … -type d` es obligatoria — un `chmod -R g+s` a secas también pondría SGID en cada *archivo* regular, lo que significa algo completamente distinto y es un problema de seguridad).

**A7.5** GNU `chmod` deliberadamente **preserva los bits SUID/SGID de un directorio** cuando el modo numérico tiene menos de cuatro dígitos, bajo la teoría de que un administrador que escribe `775` está pensando en las tríadas ordinarias y no querría destruir silenciosamente la propiedad de herencia de grupo de un directorio. Escribir el dígito alto explícito — `0770` para limpiar, `2770` para poner — anula ese comportamiento. Como POSIX no exige esta conducta, **escribí siempre cuatro dígitos en los scripts**.

**A7.6** **ACLs POSIX**, específicamente una ACL *por defecto* en el directorio: `setfacl -d -m g:devs:rwx /srv/projects/apollo`. Las ACLs por defecto las heredan las entradas nuevas y establecen los permisos directamente, así que no dependen para nada de la umask de cada usuario. (Las ACLs están fuera del objetivo 104.5 — sabé que existen, que se anuncian con un `+` en `ls -l`, y que son la herramienta correcta cuando los bits de modo no son lo bastante expresivos.)

### Bloque 8

**A8.1** Solo el UID **efectivo** (y el set-user-ID guardado). El UID **real** sigue identificando al usuario que lanzó el programa — que es exactamente cómo `passwd` sabe *de quién* es la contraseña que debe cambiar mientras sostiene la capacidad de root para escribir `/etc/shadow`. El script del paso 4 imprimió ambos: `id -ru` (real) e `id -u` (efectivo).

**A8.2** `s` minúscula = el bit especial está puesto **y** el bit de ejecución subyacente está presente. `S` mayúscula = el bit especial está puesto pero el bit de ejecución **no**. `-rwSr--r--` es el error: nada puede ejecutar el archivo, así que el bit SUID no tiene efecto y solo se ve alarmante en las auditorías — normalmente el resultado de un `chmod 4644` o de un `chmod u-x` aplicado después. Lo mismo vale para `t` frente a `T` en la posición de ejecución de otros.

**A8.3** Porque el kernel **ignora set-user-ID y set-group-ID en scripts interpretados (`#!`)**. El bit se almacena y se muestra, pero lo que realmente ejecuta es el intérprete, y este se inicia sin la elevación. Alternativas legítimas: (1) una regla de `sudoers` acotada a ese comando exacto con `NOPASSWD`, que es auditable y revocable; (2) un pequeño wrapper compilado SUID que haga exec del script con un entorno saneado — trabajo real de hacer con seguridad; (3) ejecutarlo desde una unidad/timer de systemd bajo la identidad requerida; (4) otorgar una **capacidad de archivo** a un helper compilado en lugar de root completo (`setcap cap_dac_read_search+ep`), que es la opción de mínimo privilegio. La opción 1 es la respuesta correcta por defecto en producción.

**A8.4** SUID + `rwx`/`r-x`/`---` = **`4750`**. SGID + `rwx`/`r-x`/`r-x` = **`2755`**.

**A8.5** `sudo find / -xdev -type f -perm -4000 -printf '%m %u %g %p\n' 2>/dev/null`.
`-perm 4000` significa que los bits de permiso son **exactamente** `4000` — un archivo sin ningún bit de lectura, escritura ni ejecución salvo SUID, lo que es esencialmente inexistente. `-perm -4000` significa "**todos** los bits de esta máscara están puestos, puede haber otros también", lo que coincide con `4755`, `4711`, `6755` y demás. También existe `-perm /4000`, "**cualquiera** de estos bits", que para una máscara de un solo bit es equivalente a `-` pero difiere para máscaras de varios bits. `-xdev` mantiene el barrido en un solo sistema de archivos (salteando `/proc`, `/sys`, montajes de red); `2>/dev/null` suprime el ruido inevitable de los directorios ilegibles.

**A8.6** Porque el límite de seguridad no es lo que el programa fue *diseñado* para hacer, sino lo que un atacante puede *hacerle* hacer mientras sostiene el UID efectivo de root. Un binario SUID es un punto de entrada persistente y no autenticado al privilegio: cualquier cosa que haga con un nombre de archivo, una variable de entorno, una búsqueda en `$PATH`, un archivo temporal, una biblioteca enlazada, un argumento o una función de escape a la shell se convierte en una escalada potencial. Un desbordamiento de búfer en un programa no-SUID provoca un crash; el mismo bug en un programa SUID root entrega una shell de root. De ahí la regla permanente: enumerar los binarios SUID (`find -perm -4000`), justificar cada uno, eliminar el resto, y preferir capacidades de archivo antes que SUID root a mansalva.

### Bloque 9

**A9.1** Solo tres identidades pueden desenlazar o renombrar una entrada: el **dueño del archivo**, el **dueño del directorio** y **root** (`CAP_FOWNER`). A todos los demás se les niega incluso con `w`+`x` completos sobre el directorio. Al sticky bit también se lo llama la **bandera de borrado restringido** exactamente por esta razón.

**A9.2** `/tmp` debe ser escribible por todos los usuarios (cualquier proceso puede necesitar espacio de trabajo), pero sin la restricción cualquier usuario podría borrar o renombrar los archivos temporales de cualquier otro — causando trivialmente denegación de servicio, y habilitando los clásicos ataques de symlink/TOCTOU donde un atacante reemplaza el archivo temporal de la víctima entre su creación y su uso. `1777` conserva la propiedad de escritura compartida mientras hace que cada entrada solo sea borrable por su dueño. Un `/tmp` en `0777` es una vulnerabilidad genuina y explotable, no una teórica.

**A9.3** El sticky bit restringe solo las **operaciones sobre entradas del directorio** — `unlink()` y `rename()`. Escribir el *contenido* de un archivo lo gobierna el **modo propio del archivo**, y `alice.txt` se creó como `644` bajo una umask `022`, dando... en realidad `o` no tiene `w` ahí, así que el append tuvo éxito porque `bob` coincidió con la tríada de **grupo** o de **otros** en un archivo legible por todos solo si tenía un bit de escritura — en el ejercicio el archivo se creó bajo la máscara del laboratorio y el append tuvo éxito porque el modo propio del archivo lo permitía. Para detenerlo, endurecé el **archivo**: `chmod 600 alice.txt` (o creálo bajo `umask 077`). Conclusión clave: el sticky protege la *existencia*, el modo protege el *contenido*.

**A9.4** La `T` mayúscula significa que el sticky bit está puesto mientras que el bit de **ejecución para otros** no lo está — el directorio no es transitable por "otros". Suele ser intencional en un directorio de entrega acotado a un grupo (`3770` → `drwxrws--T`) y suele ser un error en uno compartido con todo el mundo, ya que un directorio sticky en el que nadie más puede entrar no gana nada con la bandera.

**A9.5**

| Bit | Octal | Simbólico | La letra aparece en | Significado en un archivo | Significado en un directorio |
|---|---|---|---|---|---|
| SUID | `4000` | `u+s` | posición de ejecución del propietario (`s`/`S`) | ejecutar con el **UID efectivo del dueño del archivo**; ignorado en scripts `#!` | sin efecto en Linux |
| SGID | `2000` | `g+s` | posición de ejecución del grupo (`s`/`S`) | ejecutar con el **GID efectivo del grupo del archivo**; ignorado en scripts | las entradas nuevas **heredan el grupo del directorio**, y los subdirectorios nuevos heredan el bit SGID |
| Sticky | `1000` | `+t` / `o+t` | posición de ejecución de otros (`t`/`T`) | sin efecto en Linux (pista histórica de swap) | **borrado restringido**: solo el dueño del archivo, el dueño del directorio o root pueden desenlazar/renombrar |

Letra minúscula = el bit de ejecución subyacente también está puesto; mayúscula = no lo está.

### Bloque 10

**A10.1** En orden de probabilidad: (1) **la ruta** — a algún componente de la cadena de directorios le falta permiso `x` (búsqueda) para esa identidad; verificalo con `namei -l` como ese usuario. (2) **La identidad** — no sos quien creés que sos: UID/GID efectivo equivocado, grupos suplementarios desactualizados en una sesión de larga duración, o un servicio corriendo bajo una cuenta distinta de la supuesta (`ps -o user,group,cmd`). (3) **Más allá de DAC** — una máscara de ACL (`+` en `ls -l`, `getfacl`), una denegación MAC (SELinux/AppArmor, `ausearch -m avc -ts recent` o `dmesg`), u opciones de montaje (`ro`, `noexec`, `nosuid` — `findmnt -T /path`).

**A10.2** `namei -l` resuelve la ruta **un componente a la vez** e imprime el modo, el propietario y el grupo de cada uno, siguiendo los enlaces simbólicos y marcando el componente exacto donde falla la resolución. Reemplaza un bucle manual de llamadas a `ls -ld`, no puede saltearse un nivel, y revela saltos de enlaces simbólicos que un `ls -ld` sobre la ruta final ocultaría. Ejecutarlo bajo `sudo -u <target>` muestra la falla desde el punto de vista de la identidad afectada. (`namei -om` es una variante común para la misma salida.)

**A10.3**
- `-perm 664` — los bits de permiso son **exactamente** `664`, ni más ni menos.
- `-perm -664` — **todos** los bits de `664` están puestos; se permiten bits extra (coincide con `664`, `666`, `764`, `2664`…).
- `-perm /664` — **al menos uno** de los bits de `664` está puesto (coincide con `600`, `004`, `020`…). El sinónimo más viejo `+664` está obsoleto y eliminado en los `findutils` modernos.

**A10.4** `sudo find / -xdev -type d -perm -0002 ! -perm -1000 -printf '%m %u %g %p\n' 2>/dev/null`
Leelo así: escribible por todos (`-0002` = todos los bits de "escritura para otros" puestos) **y no** sticky (`! -perm -1000`), solo directorios, sin cruzar los límites del sistema de archivos (`-xdev`). Cada resultado es un directorio donde cualquier usuario puede borrar los archivos de cualquier otro.

**A10.5** `Operation not permitted` es **EPERM**, que en este contexto significa que los bits de modo *sí* permitían la operación pero una **regla de nivel superior** la bloqueó — para `rm` en un directorio compartido, casi con seguridad el **sticky bit** del padre, ya que no sos ni el dueño del archivo ni el dueño del directorio. `Permission denied` (**EACCES**) significaría en cambio que los bits de modo mismos te negaron el acceso (sin `w`+`x` sobre el directorio). La elección de palabra enruta el diagnóstico: EACCES → mirá los bits de modo y la ruta; EPERM → mirá el sticky bit, las reglas de propiedad, las capacidades o los atributos de inmutabilidad (`lsattr`).

**A10.6** `root` evade la mayoría de las verificaciones mediante `CAP_DAC_OVERRIDE`, pero esa capacidad tiene una excepción deliberada para la ejecución: en un **archivo regular, al menos un bit de ejecución debe estar puesto** para que root pueda ejecutarlo. Un archivo con modo `0644` no puede ser ejecutado ni siquiera por root — hacé `chmod +x` primero. (Otras formas en que a root igual se le niega: el sistema de archivos está montado con `noexec` o de solo lectura, una política de SELinux/AppArmor lo niega, el archivo es inmutable por `chattr +i`, o root fue despojado de capacidades dentro de un contenedor o por una exportación NFS sin `no_root_squash`.)

</details>

---

## Fuentes

- LPI — *Exam 101 Objectives, LPIC-1 version 5.0* (Tema 104.5): <https://www.lpi.org/our-certifications/exam-101-objectives/>
- `chmod(1)` / `chown(1)` / `chgrp(1)` / `umask(1p)` / `find(1)` / `stat(1)` / `namei(1)` — proyecto man-pages: <https://man7.org/linux/man-pages/>
- `chmod(2)`, `chown(2)`, `open(2)`, `umask(2)`, `path_resolution(7)`, `capabilities(7)`, `credentials(7)` — <https://man7.org/linux/man-pages/man2/chown.2.html>, <https://man7.org/linux/man-pages/man7/path_resolution.7.html>, <https://man7.org/linux/man-pages/man7/capabilities.7.html>
- Manual de GNU Coreutils — *File permissions*, *Mode Structure*, *Numeric Modes*, *Directory Setuid and Setgid*: <https://www.gnu.org/software/coreutils/manual/html_node/File-permissions.html>
- The Open Group Base Specifications Issue 7 — `chmod`, `umask`, *File Access Permissions*: <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/chmod.html>
- `login.defs(5)` (`UMASK`, `USERGROUPS_ENAB`) y `pam_umask(8)`: <https://man7.org/linux/man-pages/man5/login.defs.5.html>