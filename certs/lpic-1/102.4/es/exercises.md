# LPIC-1 · Tema 102.4 — Uso de la gestión de paquetes de Debian
## Ejercicios de laboratorio guiados

**Examen:** LPIC-1 101-500 (Tema 102) · **Peso:** 4.69
**Distribución de referencia:** Debian 12 *bookworm* (todas las salidas mostradas se tomaron en `amd64`). Todo aplica a Ubuntu/Devuan/Raspberry Pi OS con las diferencias señaladas.
**Utilidades clave ejercitadas:** `dpkg`, `dpkg-query`, `dpkg-deb`, `dpkg-reconfigure`, `apt`, `apt-get`, `apt-cache`, `apt-mark`, `apt-file`, `/etc/apt/sources.list`.

---

## Bloque 0 — Entorno de laboratorio descartable

Nunca ejecutes estos ejercicios en una máquina que te importe: varios pasos rompen deliberadamente la base de datos de dpkg y fuerzan la eliminación de paquetes cercanos a los esenciales.

1. Creá un contenedor descartable (Podman o Docker, cualquiera sirve):

```bash
podman run --rm -it --name lpic102-4 --hostname deb-lab debian:12 bash
```

2. Dentro del contenedor, instalá las herramientas que necesitan los ejercicios y registrá una línea base:

```bash
apt-get update
apt-get install -y --no-install-recommends \
    tree file less vim-tiny debsums apt-file apt-utils
```

3. Tomá una instantánea de referencia del conjunto de paquetes para poder compararla más adelante:

```bash
dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' \
    | sort > /root/baseline.tsv
wc -l /root/baseline.tsv
```

Forma esperada:

```
280 /root/baseline.tsv
```

4. Confirmá la arquitectura que la base de datos de dpkg considera nativa, y cualquier arquitectura foránea habilitada:

```bash
dpkg --print-architecture
dpkg --print-foreign-architectures
```

```
amd64
```

(El segundo comando no imprime nada en un sistema de una sola arquitectura: esa es la salida correcta, no un error.)

> **Preguntas — Bloque 0**
> 1. ¿Por qué `dpkg --print-foreign-architectures` produce una salida vacía en lugar de un error en una instalación nueva?
> 2. Se usó `apt-get install` con `--no-install-recommends`. ¿Cuál es la diferencia entre una relación `Depends`, una `Recommends` y una `Suggests`, y cuál de las tres instala APT por defecto?
> 3. Se usó `dpkg-query -W` en lugar de `dpkg -l`. Dá una razón concreta por la que un script en producción debería preferir el primero.

---

## Bloque 1 — La base de datos de dpkg y la codificación de estado/flag

`dpkg` mantiene su propia base de datos, totalmente independiente de APT, bajo `/var/lib/dpkg/`. APT es un cliente de esa base de datos, no un reemplazo.

1. Inspeccioná la disposición de la base de datos:

```bash
ls -la /var/lib/dpkg/
```

```
drwxr-xr-x 2 root root   4096 Aug 25 09:11 alternatives
-rw-r--r-- 1 root root      0 Aug 25 09:10 available
drwxr-xr-x 2 root root  36864 Aug 25 09:12 info
-rw-r----- 1 root root      0 Aug 25 09:12 lock
-rw-r----- 1 root root      0 Aug 25 09:12 lock-frontend
drwxr-xr-x 2 root root   4096 Aug 25 09:12 parts
-rw-r--r-- 1 root root 512348 Aug 25 09:12 status
-rw-r--r-- 1 root root 511902 Aug 25 09:11 status-old
drwxr-xr-x 2 root root   4096 Aug 25 09:12 triggers
drwxr-xr-x 2 root root   4096 Aug 25 09:12 updates
```

2. Mirá la stanza cruda de un solo paquete en `/var/lib/dpkg/status`: este es el registro autoritativo:

```bash
awk 'BEGIN{RS=""} /^Package: tree$/' /var/lib/dpkg/status
```

```
Package: tree
Status: install ok installed
Priority: optional
Section: utils
Installed-Size: 116
Maintainer: Guillem Jover <guillem@debian.org>
Architecture: amd64
Multi-Arch: foreign
Version: 2.1.0-1
Depends: libc6 (>= 2.34)
Description: displays an indented directory tree, in color
 Tree is a recursive directory listing command that produces a depth
 indented listing of files, which is colorized ala dircolors if the
 LS_COLORS environment variable is set and output is to tty.
Homepage: https://gitlab.com/OldManProgrammer/unix-tree
```

3. Leé la leyenda de cabecera que imprime `dpkg -l`, y después un registro individual:

```bash
dpkg -l tree
```

```
Desired=Unknown/Install/Remove/Purge/Hold
| Status=Not/Inst/Conf-files/Unpacked/halF-conf/Half-inst/trig-aWait/Trig-pend
|/ Err?=(none)/Reinst-required (Status,Err: uppercase=bad)
||/ Name           Version      Architecture Description
+++-==============-============-============-===============================
ii  tree           2.1.0-1      amd64        displays an indented directory tree, in color
```

4. Pedile a `dpkg` el estado parseado del mismo paquete, y su manifiesto de archivos:

```bash
dpkg -s tree | head -5
dpkg -L tree
```

```
Package: tree
Status: install ok installed
Priority: optional
Section: utils
Installed-Size: 116
```

```
/.
/usr
/usr/bin
/usr/bin/tree
/usr/share
/usr/share/doc
/usr/share/doc/tree
/usr/share/doc/tree/changelog.Debian.gz
/usr/share/doc/tree/copyright
/usr/share/man
/usr/share/man/man1
/usr/share/man/man1/tree.1.gz
```

5. Ahora producí un estado que vas a encontrar en el campo. Eliminá sin purgar, y volvé a inspeccionar:

```bash
apt-get remove -y tree
dpkg -l tree
ls /etc/apt/apt.conf.d/ >/dev/null; dpkg-query -f='${db:Status-Abbrev}\n' -W tree
```

```
rc  tree           2.1.0-1      amd64        displays an indented directory tree, in color
```

```
rc
```

6. Confirmá que los archivos se eliminaron pero el registro del paquete sobrevive, y después purgá:

```bash
ls /usr/bin/tree            # expect: No such file or directory
dpkg -L tree                # expect: the conffile list only, or an explicit note
apt-get purge -y tree
dpkg -l tree                # expect: dpkg-query: no packages found matching tree
```

> **Preguntas — Bloque 1**
> 1. Decodificá cada uno de estos estados de dos letras: `ii`, `rc`, `iU`, `iF`, `hi`, `pn`. ¿Cuáles de ellos indican un sistema *roto* que necesita intervención del operador?
> 2. `/var/lib/dpkg/available` tenía 0 bytes. ¿Qué comando lo llena, y por qué es efectivamente obsoleto en un sistema gestionado por APT?
> 3. Un paquete está en `rc`. ¿Qué queda exactamente en disco, y qué único comando lo limpia?
> 4. ¿Por qué `dpkg -L` sobre un paquete en `rc` no lista `/usr/bin/tree`?
> 5. `/var/lib/dpkg/status-old` existe. ¿Qué uso operativo tiene durante un incidente?

---

## Bloque 2 — Cadenas de formato de `dpkg-query` y propiedad de archivos

Este es el bloque que convierte a dpkg de una herramienta interactiva en algo que podés manejar desde un script o una corrida de gestión de configuración.

1. Construí un inventario legible por máquina ordenado por tamaño instalado: un primer paso estándar cuando se llena una partición `/`:

```bash
dpkg-query -W -f='${Installed-Size}\t${binary:Package}\t${Version}\n' \
    | sort -nr | head -10
```

```
28934	libc6:amd64	2.36-9+deb12u7
19122	perl-base	5.36.0-7+deb12u1
9781	dpkg	1.21.22
7288	libgcc-s1:amd64	12.2.0-14
6112	gcc-12-base:amd64	12.2.0-14
...
```

2. Extraé solo los paquetes que *no* están en el estado limpio `installed`: la consulta de salud más útil en un servidor heredado:

```bash
dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' \
    | grep -v '^ii ' || echo "all packages fully installed"
```

3. Preguntá qué paquete es dueño de una ruta dada. Notá que `dpkg -S` busca en las listas de archivos *instalados* en `/var/lib/dpkg/info/*.list`:

```bash
dpkg -S /usr/bin/dpkg
dpkg -S /etc/passwd
```

```
dpkg: /usr/bin/dpkg
base-passwd, passwd: /etc/passwd
```

4. Observá la trampa del `/usr` fusionado (merged-`/usr`). En bookworm `/bin` es un enlace simbólico a `usr/bin`, pero las listas de archivos registradas no están normalizadas, así que una ruta literal puede fallar:

```bash
ls -ld /bin
dpkg -S /bin/ls
dpkg -S "$(realpath "$(command -v ls)")"
```

```
lrwxrwxrwx 1 root root 7 Aug 14 12:00 /bin -> usr/bin
coreutils: /bin/ls
coreutils: /usr/bin/ls
```

(En Debian 13 *trixie* y posteriores, solo se registra la forma `/usr/bin/ls`. Resolvé siempre con `realpath` en scripts portables.)

5. Buscá un archivo que pertenezca a un paquete que **no** está instalado. `dpkg -S` no puede hacer esto: solo conoce paquetes instalados. Usá `apt-file`:

```bash
apt-file update
apt-file search bin/htpasswd
apt-file list apache2-utils | head -5
```

```
apache2-utils: /usr/bin/htpasswd
```

```
apache2-utils: /usr/bin/ab
apache2-utils: /usr/bin/checkgid
apache2-utils: /usr/bin/dbmmanage
apache2-utils: /usr/bin/htcacheclean
apache2-utils: /usr/bin/htdbm
```

6. Resolvé una dependencia de biblioteca compartida como lo harías cuando un binario no arranca:

```bash
apt-get install -y --no-install-recommends nginx-core >/dev/null 2>&1 || true
ldd "$(command -v tree)" 2>/dev/null || ldd /usr/bin/dpkg
dpkg -S /lib/x86_64-linux-gnu/libc.so.6 2>/dev/null \
    || dpkg -S "$(realpath /lib/x86_64-linux-gnu/libc.so.6)"
```

```
libc6:amd64: /usr/lib/x86_64-linux-gnu/libc.so.6
```

> **Preguntas — Bloque 2**
> 1. `dpkg -S /etc/passwd` devolvió dos paquetes. ¿Cómo es posible eso, y qué mecanismo de la Debian Policy lo hace legal?
> 2. ¿Cuál es la frontera funcional exacta entre `dpkg -S` y `apt-file search`? Nombrá la fuente de datos que lee cada uno.
> 3. Hizo falta `apt-file update` antes de buscar. ¿Qué archivos descarga, y dónde caen?
> 4. Escribí un one-liner que imprima cada paquete instalado cuyo nombre empiece con `libssl`, mostrando paquete, versión y arquitectura, sin usar `grep`.
> 5. ¿Por qué `${binary:Package}` puede diferir de `${Package}` en las cadenas de formato de `dpkg-query`?

---

## Bloque 3 — Anatomía de un archivo `.deb`

1. Descargá un paquete sin instalarlo, para tener un archivo que diseccionar:

```bash
cd /tmp
apt-get download tree
ls -l tree_*.deb
```

```
-rw-r--r-- 1 root root 51372 Aug 25 09:20 tree_2.1.0-1_amd64.deb
```

2. Comprobá que un `.deb` es un archivo `ar` con exactamente tres miembros:

```bash
file tree_2.1.0-1_amd64.deb
ar t tree_2.1.0-1_amd64.deb
```

```
tree_2.1.0-1_amd64.deb: Debian binary package (format 2.0), with control.tar.xz, data.tar.xz
```

```
debian-binary
control.tar.xz
data.tar.xz
```

3. Leé los metadatos de control y el listado del payload con las opciones de `dpkg-deb` (también alcanzables como `dpkg -I` / `dpkg -c`):

```bash
dpkg-deb --info tree_2.1.0-1_amd64.deb
dpkg-deb --contents tree_2.1.0-1_amd64.deb
```

```
 new Debian package, version 2.0.
 size 51372 bytes: control archive=1044 bytes.
     452 bytes,    12 lines      control
     249 bytes,     4 lines      md5sums
 Package: tree
 Version: 2.1.0-1
 Architecture: amd64
 Maintainer: Guillem Jover <guillem@debian.org>
 Installed-Size: 116
 Depends: libc6 (>= 2.34)
 Section: utils
 Priority: optional
 Multi-Arch: foreign
 Homepage: https://gitlab.com/OldManProgrammer/unix-tree
 Description: displays an indented directory tree, in color
```

```
drwxr-xr-x root/root         0 2023-01-15 20:11 ./
drwxr-xr-x root/root         0 2023-01-15 20:11 ./usr/
drwxr-xr-x root/root         0 2023-01-15 20:11 ./usr/bin/
-rwxr-xr-x root/root    103648 2023-01-15 20:11 ./usr/bin/tree
...
```

4. Extraé ambas mitades por separado: la técnica para recuperar un único archivo de un paquete sin instalarlo:

```bash
mkdir -p /tmp/deb/{ctrl,data}
dpkg-deb --control  tree_2.1.0-1_amd64.deb /tmp/deb/ctrl
dpkg-deb --extract  tree_2.1.0-1_amd64.deb /tmp/deb/data
ls /tmp/deb/ctrl
find /tmp/deb/data -type f
```

```
control  md5sums
```

```
/tmp/deb/data/usr/bin/tree
/tmp/deb/data/usr/share/man/man1/tree.1.gz
/tmp/deb/data/usr/share/doc/tree/copyright
/tmp/deb/data/usr/share/doc/tree/changelog.Debian.gz
```

5. Inspeccioná un paquete que trae scripts de mantenedor y conffiles, para poder ver el resto del archivo de control:

```bash
apt-get download openssh-server
dpkg-deb --control openssh-server_*.deb /tmp/deb/ssh-ctrl
ls -l /tmp/deb/ssh-ctrl
head -3 /tmp/deb/ssh-ctrl/conffiles
```

```
-rw-r--r-- 1 root root   612 Feb 20 10:02 conffiles
-rw-r--r-- 1 root root  2185 Feb 20 10:02 control
-rw-r--r-- 1 root root 12048 Feb 20 10:02 md5sums
-rwxr-xr-x 1 root root  6031 Feb 20 10:02 postinst
-rwxr-xr-x 1 root root  2144 Feb 20 10:02 postrm
-rwxr-xr-x 1 root root  1877 Feb 20 10:02 preinst
-rwxr-xr-x 1 root root  1103 Feb 20 10:02 prerm
-rw-r--r-- 1 root root   455 Feb 20 10:02 templates
```

```
/etc/default/ssh
/etc/init.d/ssh
/etc/pam.d/sshd
```

6. Compará versiones de paquetes como lo hace el propio `dpkg`: indispensable en automatización idempotente:

```bash
dpkg --compare-versions 1:2.1.0-1 gt 2.1.0-1 && echo "epoch wins"
dpkg --compare-versions 1.10 gt 1.9 && echo "1.10 > 1.9"
dpkg --compare-versions 2.1.0-1~bpo12+1 lt 2.1.0-1 && echo "backport sorts lower"
```

```
epoch wins
1.10 > 1.9
backport sorts lower
```

> **Preguntas — Bloque 3**
> 1. Nombrá los tres miembros `ar` de un `.deb` y decí qué contiene cada uno. ¿Cuál es el contenido completo de `debian-binary`?
> 2. `dpkg-deb --extract` frente a `dpkg --unpack`: ambos escriben el payload en el sistema de archivos. Dá dos cosas que hace `--unpack` y `--extract` no.
> 3. ¿Cuál es el propósito del archivo `conffiles` en el archivo de control, y cómo cambia el comportamiento de `dpkg` durante una actualización?
> 4. ¿En qué orden invoca `dpkg` a `preinst`, `postinst`, `prerm` y `postrm` durante la actualización de un paquete ya instalado?
> 5. ¿Por qué `2.1.0-1~bpo12+1` ordena *por debajo* de `2.1.0-1`? ¿Qué carácter lo provoca, y por qué es deliberado para los backports?

---

## Bloque 4 — Fuentes de APT: `sources.list`, deb822 y la caché de listas

1. Leé el formato clásico de una línea:

```bash
cat /etc/apt/sources.list
ls -l /etc/apt/sources.list.d/
```

```
deb http://deb.debian.org/debian bookworm main
deb http://deb.debian.org/debian bookworm-updates main
deb http://security.debian.org/debian-security bookworm-security main
```

2. Descomponé una línea campo por campo. Para `deb http://deb.debian.org/debian bookworm main contrib non-free-firmware`:

| Campo | Valor | Significado |
|---|---|---|
| tipo | `deb` | paquetes binarios (`deb-src` = paquetes fuente) |
| URI | `http://deb.debian.org/debian` | raíz del repositorio |
| suite | `bookworm` | suite o nombre en clave (también puede ser `stable`, o una ruta terminada en `/` para un repositorio plano) |
| componentes | `main contrib non-free-firmware` | áreas del archivo, basadas en la licencia |

3. Agregá una fuente en el formato moderno deb822, que es el único formato que expresa limpiamente claves de firma por fuente:

```bash
mkdir -p /etc/apt/keyrings
cat > /etc/apt/sources.list.d/debian-backports.sources <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: bookworm-backports
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
Enabled: yes
EOF
apt-get update
```

```
Get:1 http://deb.debian.org/debian bookworm-backports InRelease [59.4 kB]
Get:2 http://deb.debian.org/debian bookworm-backports/main amd64 Packages [289 kB]
...
Reading package lists... Done
```

4. Inspeccioná qué materializó realmente `apt-get update` en disco:

```bash
ls /var/lib/apt/lists/ | head
du -sh /var/lib/apt/lists/
```

```
deb.debian.org_debian_dists_bookworm-backports_InRelease
deb.debian.org_debian_dists_bookworm-backports_main_binary-amd64_Packages.lz4
deb.debian.org_debian_dists_bookworm_InRelease
deb.debian.org_debian_dists_bookworm_main_binary-amd64_Packages.lz4
lock
partial
security.debian.org_debian-security_dists_bookworm-security_InRelease
```

```
48M	/var/lib/apt/lists/
```

5. Verificá qué fuentes considera activas APT, y su estado de confianza:

```bash
apt-cache policy | head -20
```

```
Package files:
 100 /var/lib/dpkg/status
     release a=now
 100 http://deb.debian.org/debian bookworm-backports/main amd64 Packages
     release o=Debian Backports,a=bookworm-backports,n=bookworm-backports,l=Debian Backports,c=main,b=amd64
     origin deb.debian.org
 500 http://deb.debian.org/debian bookworm/main amd64 Packages
     release v=12.11,o=Debian,a=stable,n=bookworm,l=Debian,c=main,b=amd64
     origin deb.debian.org
```

6. Reproducí y después arreglá el clásico fallo de "repositorio sin firmar":

```bash
echo "deb http://deb.debian.org/debian sid main" > /etc/apt/sources.list.d/broken.list
apt-get update 2>&1 | tail -4
rm /etc/apt/sources.list.d/broken.list
apt-get update >/dev/null && echo "sources clean"
```

> **Preguntas — Bloque 4**
> 1. En `deb http://deb.debian.org/debian bookworm main contrib`, nombrá cada campo y decí qué pasa si se omite `main` por completo.
> 2. Los backports aparecieron con prioridad `100` en `apt-cache policy` mientras que `bookworm/main` tiene `500`. ¿Cuál es la consecuencia práctica, y qué comando instala un paquete *desde* backports de todos modos?
> 3. `apt-get update` falló con un repositorio sin firmar. ¿Qué archivo dentro de `dists/<suite>/` lleva la firma, y cuál es la diferencia entre `Release` + `Release.gpg` e `InRelease`?
> 4. ¿Por qué `Signed-By:` por fuente es estrictamente mejor que el obsoleto `apt-key add`?
> 5. Necesitás ejecutar `apt-get source nginx`. ¿Qué tenés que agregar primero a tu configuración de fuentes, y qué tres archivos descarga APT?
> 6. ¿Qué directorio limpiarías para forzar a APT a volver a descargar cada índice desde cero, y qué comando lo hace de forma segura?

---

## Bloque 5 — Consultar la caché: `apt-cache`, `apt show`, `apt policy`

1. Buscá en las descripciones de los paquetes, y después acotá solo a nombres:

```bash
apt-cache search 'directory tree' | head -5
apt-cache search --names-only '^tree$'
```

```
tree - displays an indented directory tree, in color
mtree-netbsd - Utility to map a directory hierarchy
...
```

```
tree - displays an indented directory tree, in color
```

2. Leé los metadatos completos de la versión candidata:

```bash
apt-cache show tree | head -12
apt show tree 2>/dev/null | head -12
```

```
Package: tree
Version: 2.1.0-1
Installed-Size: 116
Maintainer: Guillem Jover <guillem@debian.org>
Architecture: amd64
Depends: libc6 (>= 2.34)
Description-en: displays an indented directory tree, in color
Homepage: https://gitlab.com/OldManProgrammer/unix-tree
Section: utils
Priority: optional
Filename: pool/main/t/tree/tree_2.1.0-1_amd64.deb
Size: 51372
```

3. Compará la versión instalada, la versión candidata y todas las versiones disponibles:

```bash
apt-cache policy nginx-core
apt-cache madison nginx-core
```

```
nginx-core:
  Installed: (none)
  Candidate: 1.22.1-9+deb12u2
  Version table:
     1.24.0-2~bpo12+1 100
        100 http://deb.debian.org/debian bookworm-backports/main amd64 Packages
     1.22.1-9+deb12u2 500
        500 http://deb.debian.org/debian bookworm/main amd64 Packages
```

```
nginx-core | 1.24.0-2~bpo12+1 | http://deb.debian.org/debian bookworm-backports/main amd64 Packages
nginx-core | 1.22.1-9+deb12u2 | http://deb.debian.org/debian bookworm/main amd64 Packages
```

4. Recorré el grafo de dependencias en ambas direcciones:

```bash
apt-cache depends nginx-core
apt-cache rdepends --installed libc6 | head -10
```

```
nginx-core
  Depends: libc6
  Depends: libpcre2-8-0
  Depends: libssl3
  Depends: zlib1g
  Depends: nginx-common
  Conflicts: <nginx-extras>
    nginx-extras
  Replaces: <nginx-extras>
```

5. Usá `showpkg` cuando necesites las tablas crudas de proveedores/proveedores inversos: la vista que explica los paquetes virtuales:

```bash
apt-cache showpkg mail-transport-agent | head -20
```

```
Package: mail-transport-agent
Versions:

Reverse Depends:
  mailutils,mail-transport-agent
  logwatch,mail-transport-agent
  ...
Dependencies:
Provides:
Reverse Provides:
postfix 3.7.11-0+deb12u1
exim4-daemon-light 4.96-15+deb12u6
msmtp-mta 1.8.23-1
```

6. Verificá el tamaño de la caché y dónde vive:

```bash
apt-cache stats | head -8
ls -l /var/cache/apt/*.bin
```

```
Total package names: 118429 (2371 k)
Total package structures: 118429 (6634 k)
  Normal packages: 91302
  Pure virtual packages: 682
  Single virtual packages: 5344
  Mixed virtual packages: 1049
  Missing: 20052
Total distinct versions: 122870 (9829 k)
```

> **Preguntas — Bloque 5**
> 1. ¿Cuál de `apt`, `apt-get` y `apt-cache` está documentado como que *no* tiene una interfaz de CLI estable, y qué significa eso para un trabajo de `cron` o una tarea de Ansible?
> 2. `apt-cache policy` informó un `Candidate:` distinto de la versión más alta listada. Explicá el mecanismo que decide el candidato.
> 3. `mail-transport-agent` apareció sin `Versions:` pero con varios `Reverse Provides:`. ¿Qué clase de paquete es, y cómo satisface APT una dependencia sobre él?
> 4. ¿Cuál es la diferencia entre `apt-cache depends` y `apt-cache rdepends`, y por qué `--installed` es importante en el segundo?
> 5. `apt show` imprimió una advertencia en stderr en algunas versiones. ¿Cuál, y cuál es el equivalente seguro para scripting de `apt show <pkg>`?
> 6. El campo `Filename:` apuntaba a `pool/main/t/tree/...`. Reconstruí la URL de descarga completa a partir de la línea de `sources.list` del Bloque 4.

---

## Bloque 6 — Instalar, eliminar, purgar y la marca auto/manual

1. Simulá antes de actuar. `-s` (`--simulate`, `--dry-run`) nunca toca el sistema:

```bash
apt-get -s install nginx-core
```

```
NOTE: This is only a simulation!
      apt-get needs root privileges for real execution.
The following additional packages will be installed:
  libpcre2-8-0 libssl3 nginx-common
Suggested packages:
  fcgiwrap nginx-doc ssl-cert
The following NEW packages will be installed:
  libpcre2-8-0 libssl3 nginx-common nginx-core
0 upgraded, 4 newly installed, 0 to remove and 0 not upgraded
Inst libssl3 (3.0.17-1~deb12u2 Debian:12/stable [amd64])
Conf libssl3 (3.0.17-1~deb12u2 Debian:12/stable [amd64])
...
```

2. Instalá de verdad, y después inspeccioná cómo quedó marcado cada paquete:

```bash
apt-get install -y nginx-core
apt-mark showmanual | grep -E 'nginx|libssl' || true
apt-mark showauto  | grep -E 'nginx|libssl' || true
```

```
nginx-core
```

```
libssl3
nginx-common
libpcre2-8-0
```

3. Mirá cómo la marca auto hace su trabajo:

```bash
apt-get remove -y nginx-core
apt-get -s autoremove
```

```
The following packages will be REMOVED:
  libpcre2-8-0 libssl3 nginx-common
0 upgraded, 0 newly installed, 3 to remove and 0 not upgraded
```

4. Cambiá una marca a mano y observá el efecto: el arreglo estándar para "autoremove quiere borrar algo que todavía necesito":

```bash
apt-mark manual libssl3
apt-get -s autoremove | grep -A2 REMOVED
```

```
The following packages will be REMOVED:
  libpcre2-8-0 nginx-common
```

5. Distinguí `remove` de `purge` en un paquete con conffiles:

```bash
apt-get install -y --no-install-recommends openssh-server >/dev/null
ls /etc/ssh/sshd_config
apt-get remove -y openssh-server >/dev/null
ls -l /etc/ssh/sshd_config          # still present
dpkg -l openssh-server | tail -1
apt-get purge -y openssh-server >/dev/null
ls /etc/ssh/sshd_config             # now gone
```

```
rc  openssh-server 1:9.2p1-2+deb12u7 amd64  secure shell (SSH) server, ...
```

```
ls: cannot access '/etc/ssh/sshd_config': No such file or directory
```

6. Instalá un `.deb` local de dos maneras y notá la diferencia:

```bash
cd /tmp
apt-get download tree
dpkg -i tree_2.1.0-1_amd64.deb       # no dependency resolution
apt-get purge -y tree >/dev/null
apt-get install -y ./tree_2.1.0-1_amd64.deb   # resolves deps from the repos
```

7. Limpiá la caché de descargas:

```bash
du -sh /var/cache/apt/archives/
apt-get autoclean          # removes only packages no longer downloadable
apt-get clean              # removes everything
du -sh /var/cache/apt/archives/
```

> **Preguntas — Bloque 6**
> 1. Enunciá con precisión qué distingue a `apt-get remove` de `apt-get purge`, y qué estado de dpkg deja cada uno.
> 2. ¿Dónde se almacena la marca auto/manual? (Dá el archivo.) ¿Por qué es estado de APT y no de dpkg?
> 3. `apt-get autoremove` es peligroso en servidores heredados. Describí el modo de fallo exacto y los dos comandos que te permiten auditarlo antes de ejecutarlo.
> 4. `dpkg -i ./tree.deb` y `apt-get install ./tree.deb` instalaron ambos el mismo archivo. Nombrá dos comportamientos que difieren.
> 5. ¿Qué conserva `apt-get autoclean` que `apt-get clean` borra?
> 6. `apt-get install pkg=1.2.3-1` y `apt-get install pkg/bookworm-backports` son ambos válidos. Explicá qué fija cada uno, y qué les pasa a las dependencias en cada caso.

---

## Bloque 7 — `dpkg` de bajo nivel: estados unpacked y recuperación

Este bloque rompe deliberadamente el sistema. Ejecutalo solo en el contenedor descartable.

1. Forzá un fallo de dependencia instalando un paquete cuya dependencia está ausente:

```bash
cd /tmp
apt-get download nginx-core libpcre2-8-0 libssl3 nginx-common
dpkg -i nginx-core_*.deb
```

```
Selecting previously unselected package nginx-core.
(Reading database ... 8214 files and directories currently installed.)
Preparing to unpack nginx-core_1.22.1-9+deb12u2_amd64.deb ...
Unpacking nginx-core (1.22.1-9+deb12u2) ...
dpkg: dependency problems prevent configuration of nginx-core:
 nginx-core depends on libpcre2-8-0 (>= 10.22); however:
  Package libpcre2-8-0 is not installed.
 nginx-core depends on nginx-common (= 1.22.1-9+deb12u2); however:
  Package nginx-common is not installed.

dpkg: error processing package nginx-core (--install):
 dependency problems - leaving unconfigured
Errors were encountered while processing:
 nginx-core
```

2. Leé el estado resultante: esto es `iU`, "desired install / status unpacked":

```bash
dpkg -l nginx-core | tail -1
dpkg --audit
```

```
iU  nginx-core     1.22.1-9+deb12u2 amd64  nginx web/proxy server (standard version)
```

```
The following packages are only half configured, probably due to problems
configuring them the first time.  The configuration should be retried using
dpkg --configure <package> or the configure menu in dselect:
 nginx-core        nginx web/proxy server (standard version)
```

3. Reparalo con APT, que es la herramienta correcta para el trabajo:

```bash
apt-get --fix-broken install -y
dpkg -l nginx-core | tail -1
```

```
ii  nginx-core     1.22.1-9+deb12u2 amd64  nginx web/proxy server (standard version)
```

4. Ahora producí el otro medio estado a mano, usando `--unpack` sin `--configure`:

```bash
apt-get purge -y nginx-core nginx-common >/dev/null 2>&1
dpkg --unpack nginx-common_*.deb
dpkg -l nginx-common | tail -1
dpkg --configure nginx-common
dpkg -l nginx-common | tail -1
```

```
iU  nginx-common   1.22.1-9+deb12u2 all    small, powerful, scalable web/proxy server - common files
```

```
Setting up nginx-common (1.22.1-9+deb12u2) ...
ii  nginx-common   1.22.1-9+deb12u2 all    small, powerful, scalable web/proxy server - common files
```

5. Aprendé el comando general de recuperación usado tras una actualización interrumpida (corte de energía, kill por OOM durante `apt-get dist-upgrade`):

```bash
dpkg --configure -a
```

6. Leé los dos logs autoritativos. `dpkg.log` registra cada transición de estado; `apt/history.log` registra la intención del operador:

```bash
tail -8 /var/log/dpkg.log
grep -A4 'Start-Date' /var/log/apt/history.log | tail -12
```

```
2026-08-25 09:41:02 status half-installed nginx-core:amd64 1.22.1-9+deb12u2
2026-08-25 09:41:02 status unpacked nginx-core:amd64 1.22.1-9+deb12u2
2026-08-25 09:41:07 configure nginx-core:amd64 1.22.1-9+deb12u2 <none>
2026-08-25 09:41:07 status half-configured nginx-core:amd64 1.22.1-9+deb12u2
2026-08-25 09:41:07 status installed nginx-core:amd64 1.22.1-9+deb12u2
```

```
Start-Date: 2026-08-25  09:41:03
Commandline: apt-get --fix-broken install -y
Install: libpcre2-8-0:amd64 (10.42-1, automatic), nginx-common:amd64 (1.22.1-9+deb12u2, automatic)
End-Date: 2026-08-25  09:41:09
```

> **Preguntas — Bloque 7**
> 1. Explicá, en el vocabulario propio de dpkg, la diferencia entre *unpacked*, *half-configured* y *half-installed*.
> 2. `dpkg -i` falló por dependencias pero igual modificó el sistema de archivos. ¿Por qué eso es por diseño, y por qué no es un bug?
> 3. ¿Qué hace exactamente `dpkg --configure -a`, y cuándo es el primer comando correcto después de que un servidor vuelve de un apagado sucio a mitad de una actualización?
> 4. `apt-get --fix-broken install` tiene una forma abreviada. ¿Cuál es, y qué hace APT que `dpkg --configure -a` no puede?
> 5. Necesitás responder "quién instaló `nginx-core` en esta máquina, cuándo y con qué comando". ¿Qué archivo lo responde, y qué archivo responde "por qué transiciones de estado pasó el paquete"?
> 6. `dpkg --audit` no imprimió nada en un sistema sano. Nombrá dos condiciones distintas que *sí* informaría.

---

## Bloque 8 — Verificación de integridad

1. Verificá un paquete contra las sumas de comprobación registradas en el momento de la instalación:

```bash
dpkg -V coreutils && echo "coreutils intact"
```

```
coreutils intact
```

2. Alterá un conffile y volvé a verificar:

```bash
apt-get install -y --no-install-recommends nano >/dev/null
echo "set tabsize 2" >> /etc/nanorc
dpkg -V nano
```

```
??5?????? c /etc/nanorc
```

3. Alterá un archivo de *programa*: el caso que realmente importa para la respuesta a incidentes:

```bash
cp /usr/bin/tree /root/tree.orig 2>/dev/null || apt-get install -y tree >/dev/null
printf '\x00' >> /usr/bin/tree
dpkg -V tree
```

```
??5??????   /usr/bin/tree
```

4. Leé la base de datos cruda de sumas de comprobación que consulta `dpkg -V`:

```bash
head -3 /var/lib/dpkg/info/tree.md5sums
cat /var/lib/dpkg/info/nano.conffiles
```

```
9e9f6a...c31  usr/bin/tree
2c4d1b...af7  usr/share/man/man1/tree.1.gz
b7f0e2...19d  usr/share/doc/tree/copyright
```

```
/etc/nanorc
```

5. Corré un barrido de todo el sistema con `debsums`, que es la versión por lotes de la misma verificación:

```bash
debsums -c 2>/dev/null | head
debsums -ce            # changed conffiles only
```

```
/usr/bin/tree
```

```
/etc/nanorc
```

6. Restaurá el binario alterado como lo harías en producción:

```bash
apt-get install -y --reinstall tree >/dev/null
dpkg -V tree && echo "restored"
```

```
restored
```

> **Preguntas — Bloque 8**
> 1. Decodificá la cadena de verificación `??5?????? c /etc/nanorc`. ¿Qué significa el `5`, qué significa la `c` final, y por qué las otras posiciones son `?`?
> 2. `dpkg -V` compara contra `/var/lib/dpkg/info/<pkg>.md5sums`. Enunciá la limitación de seguridad que esto crea si el host ya está comprometido, y nombrá la herramienta correcta para una auditoría confiable.
> 3. ¿Por qué `dpkg -V` trata intencionalmente los conffiles modificados como algo esperado y no como corrupción?
> 4. ¿Cuál es la diferencia entre `debsums -c` y `debsums -ce`?
> 5. Un paquete no trae archivo `.md5sums`. ¿Qué informa `debsums`, y qué flag regenera las sumas de comprobación a partir del archivo?
> 6. `apt-get install --reinstall` restauró el binario pero dejó `/etc/nanorc` intacto. ¿Qué opción fuerza los conffiles de vuelta al valor por defecto del paquete en una corrida no interactiva?

---

## Bloque 9 — `debconf` y `dpkg-reconfigure`

1. Instalá un paquete que hace preguntas, de forma no interactiva:

```bash
DEBIAN_FRONTEND=noninteractive apt-get install -y tzdata locales >/dev/null
cat /etc/timezone
```

```
Etc/UTC
```

2. Inspeccioná las respuestas almacenadas actualmente en la base de datos de debconf:

```bash
apt-get install -y debconf-utils >/dev/null
debconf-show tzdata
debconf-show locales | head -5
```

```
* tzdata/Areas: Etc
* tzdata/Zones/Etc: UTC
  tzdata/Zones/Europe:
```

3. Volvé a hacer las preguntas con una prioridad elegida. `-plow` muestra todas las preguntas, incluidas las que normalmente se suprimen:

```bash
dpkg-reconfigure -plow tzdata
```

(Aparece un menú `whiptail`/`dialog`. Elegí `Europe` → `Madrid`.)

```
Current default time zone: 'Europe/Madrid'
Local time is now:      Tue Aug 25 11:52:31 CEST 2026.
Universal Time is now:  Tue Aug 25 09:52:31 UTC 2026.
```

4. Presembrá (preseed) una respuesta en lugar de responder interactivamente: el camino automatizable:

```bash
echo 'tzdata tzdata/Areas select America' | debconf-set-selections
echo 'tzdata tzdata/Zones/America select Argentina/Buenos_Aires' | debconf-set-selections
DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive tzdata
cat /etc/timezone
```

```
America/Argentina/Buenos_Aires
```

5. Exportá todas las respuestas almacenadas en el sistema, tal como capturarías la configuración de una imagen dorada:

```bash
debconf-get-selections | grep '^tzdata'
```

```
tzdata	tzdata/Areas	select	America
tzdata	tzdata/Zones/America	select	Argentina/Buenos_Aires
```

6. Confirmá que `dpkg-reconfigure` vuelve a ejecutar los scripts del mantenedor, no simplemente un archivo de ajustes:

```bash
dpkg-reconfigure -f noninteractive openssh-server 2>&1 | head -4
tail -3 /var/log/dpkg.log
```

> **Preguntas — Bloque 9**
> 1. ¿Qué ejecuta realmente `dpkg-reconfigure <pkg>`? Nombrá el o los scripts del archivo de control involucrados.
> 2. Nombrá las cuatro prioridades de debconf, de la más baja a la más alta. ¿Cuál es la predeterminada, y cuál es el efecto de `-plow`?
> 3. ¿Dónde persiste debconf las respuestas, y por qué esa base de datos está separada de `/var/lib/dpkg/status`?
> 4. Dá los dos mecanismos que hacen que la instalación de un paquete sea completamente no interactiva, y explicá por qué `DEBIAN_FRONTEND=noninteractive` por sí solo no siempre alcanza.
> 5. `dpkg-reconfigure` falla con "package is not installed". ¿En qué estado debe estar un paquete para que funcione, y calificaría `rc`?
> 6. ¿Por qué presembrar con `debconf-set-selections` es preferible a editar `/etc/timezone` directamente?

---

## Bloque 10 — Holds, selecciones y actualizaciones controladas

1. Fijá un paquete en su versión actual con el mecanismo de APT:

```bash
apt-mark hold nginx-core
apt-mark showhold
apt-get -s upgrade | head -6
```

```
nginx-core set on hold.
nginx-core
```

```
Calculating upgrade...
The following packages have been kept back:
  nginx-core
0 upgraded, 0 newly installed, 0 to remove and 1 not upgraded.
```

2. Observá el mismo hold desde el lado de dpkg: `apt-mark hold` escribe la selección de dpkg:

```bash
dpkg -l nginx-core | tail -1
dpkg --get-selections | grep nginx-core
```

```
hi  nginx-core     1.22.1-9+deb12u2 amd64  nginx web/proxy server (standard version)
```

```
nginx-core					hold
```

3. Establecé y quitá un hold usando solo `dpkg`:

```bash
echo "nginx-common hold" | dpkg --set-selections
dpkg --get-selections | grep -E 'nginx'
echo "nginx-common install" | dpkg --set-selections
apt-mark unhold nginx-core
apt-mark showhold || echo "(no holds)"
```

4. Respaldá y restaurá el conjunto completo de selecciones: el clásico procedimiento de reconstruir-esta-máquina:

```bash
dpkg --get-selections '*' > /root/selections.txt
wc -l /root/selections.txt
# On the target machine:
#   dpkg --set-selections < /root/selections.txt
#   apt-get dselect-upgrade
```

5. Entendé `upgrade` frente a `full-upgrade` simulando ambos:

```bash
apt-get -s upgrade      | tail -3
apt-get -s dist-upgrade | tail -3
```

```
0 upgraded, 0 newly installed, 0 to remove and 1 not upgraded.
```

```
1 upgraded, 2 newly installed, 1 to remove and 0 not upgraded.
```

6. Agregá un pin de versión con `apt_preferences`: más allá del objetivo literal, pero la respuesta correcta cuando un hold es demasiado tosco:

```bash
cat > /etc/apt/preferences.d/99-backports-nginx <<'EOF'
Package: nginx nginx-core nginx-common
Pin: release a=bookworm-backports
Pin-Priority: 600
EOF
apt-cache policy nginx-core | head -6
rm /etc/apt/preferences.d/99-backports-nginx
```

```
nginx-core:
  Installed: 1.22.1-9+deb12u2
  Candidate: 1.24.0-2~bpo12+1
  Version table:
     1.24.0-2~bpo12+1 600
        100 http://deb.debian.org/debian bookworm-backports/main amd64 Packages
```

> **Preguntas — Bloque 10**
> 1. `apt-mark hold` y `dpkg --set-selections ... hold` produjeron ambos `hi`. ¿Son el mismo mecanismo? ¿Dónde se registra realmente el hold?
> 2. `apt-get upgrade` informó un paquete "kept back" incluso sin ningún hold establecido. Dá las dos causas más comunes.
> 3. Explicá la diferencia entre `apt-get upgrade`, `apt-get dist-upgrade` y `apt full-upgrade`. ¿Cuál es seguro ejecutar desatendido en un host de producción, y por qué?
> 4. ¿Qué hace `apt-get dselect-upgrade` que `apt-get install $(cat list)` no hace?
> 5. Un hold impide las actualizaciones. ¿Impide la *eliminación*? Probalo y explicá.
> 6. La Pin-Priority `600` le ganó al `500` del archivo. Enunciá qué pasa con las prioridades `< 0`, `100`, `500`, `990` y `1001`.

---

## Bloque 11 — Locks, flags de force y saber cuándo parar

1. Reproducí el fallo de APT más común en un host ocupado:

```bash
# terminal 1
apt-get install -y --download-only nginx-core &
# terminal 2, immediately
apt-get install -y tree
```

```
E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 4412 (apt-get)
E: Unable to acquire the dpkg frontend lock (/var/lib/dpkg/lock-frontend), is another process using it?
```

2. Identificá al poseedor correctamente en lugar de borrar el archivo de lock:

```bash
apt-get install -y lsof >/dev/null
lsof /var/lib/dpkg/lock-frontend
ps -o pid,ppid,etime,cmd -p "$(lsof -t /var/lib/dpkg/lock-frontend)"
```

```
COMMAND  PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
apt-get 4412 root    4uW  REG   0,58        0  524 /var/lib/dpkg/lock-frontend
```

3. Aprendé los cuatro archivos de lock y qué protege cada uno:

| Lock | Recurso protegido |
|---|---|
| `/var/lib/dpkg/lock-frontend` | el derecho a ejecutar una *sesión* de gestión de paquetes |
| `/var/lib/dpkg/lock` | la base de datos de dpkg en sí |
| `/var/cache/apt/archives/lock` | la caché de descargas |
| `/var/lib/apt/lists/lock` | la caché de índices (`apt-get update`) |

4. Explorá la maquinaria de force: leela, no la memorices como hábito:

```bash
dpkg --force-help | head -20
```

```
dpkg forcing options - control behaviour when problems found:
  warn but continue:  --force-<thing>,<thing>,...
  stop with error:    --refuse-<thing>,<thing>,... | --no-force-<thing>,...
 Forcing things:
  [!] all                    Set all force options
  [*] downgrade              Replace a package with a lower version
      configure-any          Configure any package which may help this one
      hold                   Process packages even when marked "hold"
      not-root               Try to install things even if not root
      bad-path               PATH is missing important programs
  [!] overwrite              Overwrite a file from one package with another
  [!] depends                Turn all dependency problems into warnings
  [!] remove-essential       Remove an essential package
```

5. Demostrá un uso legítimo: resolver un conflicto de archivos introducido por un paquete de terceros defectuoso:

```bash
# The safe diagnostic first:
dpkg -i /tmp/conflicting.deb 2>&1 | grep 'trying to overwrite'
# Identify the true owner before deciding:
dpkg -S /usr/share/doc/example/README
# Only then, and only with a written reason:
# dpkg -i --force-overwrite /tmp/conflicting.deb
```

6. Demostrá el flag que casi nunca debería usarse, y observá la barrera de protección:

```bash
dpkg --purge coreutils
```

```
dpkg: error processing package coreutils (--purge):
 this is an essential package; it should not be removed
Errors were encountered while processing:
 coreutils
```

7. Verificá que el sistema volvió a la línea base:

```bash
dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' \
    | sort > /root/final.tsv
diff /root/baseline.tsv /root/final.tsv | head
dpkg --audit && echo "database clean"
apt-get check
```

```
Reading package lists... Done
Building dependency tree... Done
Reading state information... Done
```

> **Preguntas — Bloque 11**
> 1. ¿Por qué APT usa *dos* locks (`lock` y `lock-frontend`) en vez de uno? ¿Qué carrera previene el lock de frontend?
> 2. `rm /var/lib/dpkg/lock*` está muy difundido en internet. Describí el daño específico que puede causar y dá el procedimiento correcto en su lugar.
> 3. ¿Qué flags de force están marcados con `[!]` en `--force-help`, y qué significa ese marcador?
> 4. `dpkg --purge coreutils` fue rechazado. ¿Qué campo de control dispara ese rechazo, y qué flag de force lo anula? ¿En qué circunstancia se justifica alguna vez?
> 5. ¿Qué verifica `apt-get check`, y en qué se diferencia de `dpkg --audit`?
> 6. Tenés que instalar un paquete cuya dependencia está genuinamente satisfecha por una biblioteca compilada localmente que dpkg desconoce. Nombrá la solución *correcta* y explicá por qué `--force-depends` es la equivocada.

---

<details>
<summary><strong>Respuestas</strong> — hacé clic para expandir</summary>

### Bloque 0

1. Las arquitecturas foráneas son una característica multiarch opcional (opt-in). `dpkg --print-foreign-architectures` lista el contenido de `/var/lib/dpkg/arch`, que está vacío hasta que ejecutás `dpkg --add-architecture <arch>`. Una lista vacía es una respuesta válida, así que el comando sale con `0` y sin salida. (Agregar `i386` en un host `amd64` y ejecutar `apt-get update` es la razón habitual para poblarlo.)

2. De la Debian Policy §7.2:
   - **`Depends`** — el paquete no se *configurará* hasta que la dependencia esté configurada; `dpkg` se niega a completar la instalación sin ella. Requisito duro.
   - **`Recommends`** — una dependencia fuerte pero no absoluta; presente en "todas las instalaciones salvo las inusuales". **APT las instala por defecto** (`APT::Install-Recommends "true"`).
   - **`Suggests`** — puede enriquecer el paquete; APT nunca las instala automáticamente.
   `--no-install-recommends` deshabilita solo la del medio. `--install-suggests` habilita la última.

3. La salida de `dpkg -l` es una tabla de ancho fijo con una cabecera de leyenda de tres líneas, y las columnas se *truncan al ancho de la terminal* (`Description` se corta; los nombres de paquete largos se cortan cuando `COLUMNS` es chico). `dpkg-query -W -f='...'` emite exactamente los campos que pedís, separados por tabuladores, sin cabecera y sin truncamiento, así que el parseo es determinista. Esta es la diferencia entre un script que funciona y uno que se rompe silenciosamente en una terminal de 80 columnas.

### Bloque 1

1. Primera letra = **acción deseada**, segunda = **estado actual**, tercera (normalmente en blanco) = **flag de error**.
   - `ii` — deseado *install*, estado *installed*. Normal, sano.
   - `rc` — deseado *remove*, estado *config-files*. Binarios eliminados, conffiles conservados. No está roto, pero está desprolijo.
   - `iU` — deseado *install*, estado *unpacked*. **Roto**: los archivos están en disco pero `postinst` nunca corrió.
   - `iF` — deseado *install*, estado *half-configured*. **Roto**: `postinst` empezó y falló.
   - `hi` — deseado *hold*, estado *installed*. Sano, pero fijado contra actualizaciones.
   - `pn` — deseado *purge*, estado *not-installed*. Efectivamente ausente; nada que hacer.
   `iU` e `iF` (y cualquier cosa con una letra de estado en mayúscula, o una `R` en la columna de error) exigen intervención: `dpkg --configure -a` o `apt-get -f install`.

2. `/var/lib/dpkg/available` lo pueblan `dpkg --update-avail` / `dpkg --merge-avail`, alimentados históricamente por `dselect`. Respalda a `dpkg -p` / `dpkg --print-avail`. APT mantiene sus propias cachés binarias en `/var/cache/apt/*.bin` construidas desde `/var/lib/apt/lists/`, así que en un sistema gestionado por APT `available` nunca se escribe y se queda en 0 bytes. No uses `dpkg -p` para preguntar "qué versión está disponible": usá `apt-cache policy`.

3. Solo los **conffiles** (archivos listados en el archivo de control `conffiles` del paquete, esencialmente `/etc/...`) más la propia stanza de estado de dpkg. Todos los demás archivos del payload, y las entradas `.list`/`.md5sums` en `/var/lib/dpkg/info/`, ya no están. `apt-get purge <pkg>` (equivalentemente `dpkg --purge <pkg>`) lo limpia. Para barrer todos los paquetes en `rc` de una vez: `dpkg -l | awk '/^rc/ {print $2}' | xargs -r apt-get purge -y`.

4. Porque `/var/lib/dpkg/info/tree.list` se borra durante la eliminación. `dpkg -L` lee ese archivo. En un paquete en `rc`, solo sobrevive la lista de conffiles, así que `dpkg -L` informa o bien solo esas rutas o bien que el paquete no está instalado pero tiene conffiles.

5. `status-old` es la generación anterior de la base de datos, rotada en cada transacción. Si `/var/lib/dpkg/status` queda truncado o corrupto (escritura interrumpida, sistema de archivos lleno), `status-old` —junto con los fragmentos del journal en `/var/lib/dpkg/updates/`— es desde donde restaurás antes de ejecutar `dpkg --configure -a`.

### Bloque 2

1. Dos paquetes listan legítimamente la misma ruta cuando uno **`Replaces`** al otro para ese archivo, o cuando ambos lo traen y las reglas de conflicto de archivos de la Policy se manejan vía `Replaces`/`Conflicts`. `/etc/passwd` lo trae `base-passwd` y lo gestiona `passwd`; `dpkg -S` informa cada paquete cuyo `.list` contiene la ruta. Es una búsqueda a través de listas de archivos, no una afirmación de unicidad.

2. `dpkg -S` busca en `/var/lib/dpkg/info/*.list`: los manifiestos de archivos de los paquetes **instalados** únicamente, totalmente sin conexión. `apt-file search` busca en los índices `Contents-<arch>` descargados del repositorio, cubriendo **todos los paquetes del archivo, estén instalados o no**. Usá `dpkg -S` para "qué paquete instalado es dueño de este archivo en mi disco"; usá `apt-file` para "qué paquete tendría que instalar para obtener este archivo".

3. `apt-file update` (o `apt-get update` en apt moderno, que descarga los Contents cuando `apt-file` está instalado) descarga `dists/<suite>/<component>/Contents-<arch>.gz` para cada fuente configurada. Caen en `/var/lib/apt/lists/` junto a los índices `Packages`, como `*_Contents-amd64.lz4`.

4. ```bash
   dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' 'libssl*'
   ```
   `dpkg-query` acepta patrones glob estilo shell directamente; no hace falta `grep`. (Entrecomillá el patrón para que el shell no lo expanda contra el directorio actual.)

5. `${Package}` es el nombre pelado, del estilo del paquete fuente. `${binary:Package}` incluye el calificador de arquitectura cuando el paquete es **Multi-Arch: same** y hay una arquitectura foránea habilitada — por ejemplo `libc6:i386` frente a `libc6`. En un host multiarch, `${Package}` por sí solo puede producir filas duplicadas y ambiguas.

### Bloque 3

1. - `debian-binary` — un archivo de texto plano que contiene exactamente `2.0\n`, la versión del formato de paquete.
   - `control.tar.{gz,xz,zst}` — metadatos: `control`, y opcionalmente `md5sums`, `conffiles`, `templates`, `triggers`, y los scripts de mantenedor `preinst`/`postinst`/`prerm`/`postrm`.
   - `data.tar.{gz,xz,zst}` — el payload real del sistema de archivos, enraizado en `./`.
   Los miembros deben aparecer en ese orden; eso es lo que hace posible la instalación en streaming.

2. `dpkg --unpack` adicionalmente (a) ejecuta `preinst`, (b) registra el paquete en `/var/lib/dpkg/status` y escribe `/var/lib/dpkg/info/<pkg>.list` y `.md5sums`, (c) maneja el prompt de conffiles y las diversions, (d) elimina archivos de una versión previamente instalada. `dpkg-deb --extract` es una extracción pura de archivo sin efectos secundarios sobre la base de datos, que es exactamente por lo que es la forma segura de sacar un archivo de un paquete.

3. `conffiles` lista las rutas que dpkg debe tratar como **configuración editable por el usuario**. En una actualización, para cada ruta listada dpkg compara la suma de comprobación en disco, la del paquete viejo y la del nuevo: si nunca lo editaste, se reemplaza silenciosamente; si lo editaste *y* el paquete lo cambió, dpkg pregunta (`keep / replace / diff / shell`) en lugar de pisar tu cambio. Los archivos no listados como conffiles se sobrescriben incondicionalmente.

4. Para la actualización de un paquete instalado:
   `new-preinst upgrade` → *desempaquetar los archivos nuevos* → `old-postrm upgrade` → `new-postinst configure`.
   (Con precisión: corre primero `prerm upgrade` del paquete **viejo**, luego `preinst upgrade` del nuevo, luego el desempaquetado, luego `postrm upgrade` del viejo, y luego `postinst configure` del nuevo.)

5. La tilde `~` ordena **antes que todo, incluida la cadena vacía**, en el algoritmo de comparación de versiones de dpkg. Así que `2.1.0-1~bpo12+1 < 2.1.0-1`. Esto es deliberado: un backport debe ser reemplazado automáticamente cuando el usuario actualiza a la siguiente versión estable que trae el `2.1.0-1` real, sin intervención manual.

### Bloque 4

1. `deb` = tipo de archivo (binario; `deb-src` para fuentes). `http://deb.debian.org/debian` = URI raíz del repositorio. `bookworm` = suite/nombre en clave → el repositorio se lee desde `<URI>/dists/bookworm/`. `main contrib` = componentes. Si **no** se indica ningún componente, APT trata la entrada como un *repositorio plano*: el campo de suite debe entonces terminar en `/` y APT busca `Packages` directamente en `<URI>/<suite>/` en vez de bajo `dists/`. Omitir los componentes en una línea no plana hace que `apt-get update` falle.

2. La prioridad `100` significa "instalar solo si el paquete no está instalado en absoluto, y nunca como actualización automática", así que los backports nunca te actualizan silenciosamente. Para instalar desde backports explícitamente: `apt-get install -t bookworm-backports nginx-core` (o `apt-get install nginx-core/bookworm-backports`).

3. Dentro de `dists/<suite>/` el archivo es `Release` (el manifiesto de sumas de comprobación de cada índice) más `Release.gpg` (una firma OpenPGP **desprendida** sobre él). `InRelease` es el mismo manifiesto **firmado en línea** en un único archivo. Se prefiere `InRelease` porque es atómico: un mirror no puede servirte un `Release` nuevo con un `Release.gpg` obsoleto.

4. `apt-key add` instalaba una clave en un llavero de confianza *global*, lo que significa que esa clave podía luego autenticar **cualquier** repositorio configurado en el sistema: la clave de un proveedor de terceros podía firmar paquetes que dijeran ser `libc6` de Debian. `Signed-By:` acota una clave a exactamente una entrada de fuente, así que una clave de proveedor comprometida solo puede responder por la suite de ese proveedor. `apt-key` está obsoleto desde apt 2.2 y eliminado en Debian 12+.

5. Agregá una entrada `deb-src` equivalente (formato de una línea) o `Types: deb deb-src` (deb822), y después `apt-get update`. `apt-get source` descarga entonces tres archivos: el `.dsc` (archivo de control de fuente firmado), el `.orig.tar.*` (tarball upstream) y el `.debian.tar.*` (delta de empaquetado de Debian), y los desempaqueta, salvo que se pase `--download-only`.

6. `/var/lib/apt/lists/`. No hagas `rm -rf` sobre él: eso también elimina el `lock` y el directorio `partial/` que APT espera. El comando soportado es:
   ```bash
   apt-get clean          # optional: also clears /var/cache/apt/archives
   rm -rf /var/lib/apt/lists/*        # leaves the directory itself
   apt-get update
   ```
   Más limpio todavía: `apt-get update -o Acquire::Retries=3 --allow-releaseinfo-change` para el caso común de "la suite cambió".

### Bloque 5

1. **`apt`**. Su página de manual dice: *"The `apt` command is meant to be pleasant for end users and does not need to be backward compatible like `apt-get`."* Imprime `WARNING: apt does not have a stable CLI interface. Use with caution in scripts.` cuando stdout no es una terminal. En `cron`, Ansible, Dockerfiles y scripts de shell, usá `apt-get` / `apt-cache` / `apt-mark`, cuya salida y opciones son contractualmente estables.

2. El candidato es la versión con la **prioridad de pin más alta**, y entre prioridades iguales, la versión más alta. Las prioridades vienen de los valores por defecto de `apt_preferences` (500 para una release configurada que no es la de destino, 100 para fuentes NotAutomatic como backports y para la versión instalada, 990 para la release nombrada por `-t`/`APT::Default-Release`) más cualquier `Pin-Priority` explícita en `/etc/apt/preferences.d/`. Así, una versión numéricamente más alta con prioridad 100 pierde frente a una versión más baja con 500.

3. Un **paquete puramente virtual**: no existe ningún paquete real con ese nombre. Varios paquetes reales declaran `Provides: mail-transport-agent`. Un `Depends: mail-transport-agent` se satisface instalando cualquiera de los proveedores; si existe más de un proveedor y ninguno está instalado, APT no puede elegir e informa la ambigüedad, así que los paquetes normalmente usan `Depends: default-mta | mail-transport-agent` para dar una primera opción preferida.

4. `depends` camina *hacia adelante*: qué requiere este paquete. `rdepends` camina *hacia atrás*: qué requiere a este paquete. Sin `--installed`, `rdepends libc6` imprime decenas de miles de entradas de todo el archivo, la mayoría irrelevantes para tu host; `--installed` lo restringe a los paquetes realmente presentes, que es la respuesta que querés antes de eliminar algo.

5. `apt show` en apt 1.x–2.0 imprimía `WARNING: apt does not have a stable CLI interface...` en stderr, y además advertía cuando un paquete tenía múltiples registros. El equivalente seguro para scripting es `apt-cache show <pkg>` (todas las versiones) o `apt-cache policy <pkg>` (instalada vs candidata).

6. Raíz del repositorio + `Filename`:
   `http://deb.debian.org/debian` + `/pool/main/t/tree/tree_2.1.0-1_amd64.deb`
   → `http://deb.debian.org/debian/pool/main/t/tree/tree_2.1.0-1_amd64.deb`
   Notá que `Filename` es relativo a la **raíz del repositorio**, no a `dists/<suite>/`. El fragmento `t/tree` es el hashing estándar del pool: primera letra del nombre del paquete fuente (o `libX` para paquetes `lib*`).

### Bloque 6

1. `remove` borra los archivos del payload del paquete pero **conserva sus conffiles** y su stanza de estado, dejando el estado `rc`. `purge` borra el payload *y* los conffiles *y* ejecuta `postrm purge` (que es donde los paquetes descartan su estado en `/var/lib/<pkg>`, sus usuarios y sus respuestas de debconf), dejando el estado `pn` o ningún registro en absoluto.

2. `/var/lib/apt/extended_states`, en stanzas RFC-822:
   ```
   Package: libssl3
   Architecture: amd64
   Auto-Installed: 1
   ```
   Es estado de APT porque dpkg no tiene concepto del *porqué* de la presencia de un paquete: dpkg solo registra que está. "Instalado únicamente para satisfacer la dependencia de otro paquete" es un hecho a nivel del resolutor, así que APT es su dueño. Consecuencia: `dpkg -i` instala un paquete **sin** marca, y por defecto queda como manual.

3. Modo de fallo: un paquete que originalmente entró como dependencia, pero que ahora es genuinamente requerido por algo que APT no puede ver — una unidad de systemd que escribiste, un script, un binario compilado localmente que enlaza una biblioteca `-dev`, un módulo del kernel. Nada declara esa necesidad, así que APT lo elimina. Auditalo con:
   ```bash
   apt-get -s autoremove            # exact list, no changes made
   apt-mark showauto                # everything currently at risk
   ```
   Después `apt-mark manual <pkg>` para todo aquello de lo que realmente dependas, antes de ejecutar el comando real.

4. (a) `dpkg -i` no realiza **ninguna resolución de dependencias**: desempaqueta y luego se niega a configurar si faltan `Depends`, dejando `iU`. `apt-get install ./file.deb` lee los datos de control del archivo local, resuelve sus dependencias contra los repositorios configurados y las descarga.
   (b) `dpkg -i` deja el paquete marcado como **manual** sin entrada en `extended_states`; `apt-get install ./file.deb` registra la marca y marca como automáticas las dependencias arrastradas. `apt-get` además se niega si el archivo local rompería el sistema, mientras que `dpkg -i` procede y lo rompe.

5. `autoclean` borra solo los archivos `.deb` en `/var/cache/apt/archives/` que **ya no se pueden descargar** desde ninguna fuente configurada (versiones superadas). Conserva los `.deb` correspondientes a versiones que siguen en el archivo, de modo que una reinstalación siga siendo posible sin conexión. `clean` borra todos los `.deb` incondicionalmente.

6. - `apt-get install pkg=1.2.3-1` fija **esa versión exacta** de `pkg`. Las dependencias se resuelven normalmente contra las versiones candidatas, así que podés terminar con un paquete fijado a una versión vieja junto a dependencias nuevas, lo que puede ser insatisfacible.
   - `apt-get install pkg/bookworm-backports` selecciona la versión de `pkg` de esa **release**, equivalente a un pin de una sola vez con prioridad 990 solo para `pkg`. Sus dependencias siguen viniendo de la release por defecto salvo que uses `-t bookworm-backports`, que eleva la release de destino de toda la transacción y permite que las dependencias también vengan de backports.
   En ambos casos el paquete *no* queda en hold: el siguiente `dist-upgrade` puede moverlo.

### Bloque 7

1. - **unpacked** — el payload se escribió en disco y `preinst` corrió, pero `postinst configure` no. Los archivos del paquete existen; sus servicios no están configurados.
   - **half-configured** — `postinst configure` fue invocado y **falló** (salida distinta de cero). Más alarmante que *unpacked*, porque los efectos secundarios pueden estar parcialmente aplicados.
   - **half-installed** — la instalación/eliminación se interrumpió **durante** las propias operaciones sobre archivos. El sistema de archivos está en un estado indeterminado; este es el que puede requerir `--force-reinstreq` o una reinstalación.

2. dpkg es intencionalmente una herramienta de bajo nivel con una visión de un solo paquete: primero desempaqueta y después configura, porque un conjunto de paquetes interdependientes solo puede volverse consistente desempaquetándolos todos y configurándolos después (así es exactamente como `dpkg -i a.deb b.deb c.deb` resuelve una dependencia circular). Detenerse antes del desempaquetado haría imposibles las transacciones multipaquete. La *resolución de dependencias a lo largo del archivo* es tarea de APT, no de dpkg.

3. Intenta `postinst configure` para **todos** los paquetes que estén actualmente en estado *unpacked* o *half-configured*, en orden de dependencias. Es el primer comando correcto tras un `dist-upgrade` interrumpido porque los payloads ya están en disco —lo que falta es el paso de configuración— y no necesita acceso a la red, algo que importa cuando la interrupción misma rompió la red.

4. Forma abreviada: `apt-get -f install` (y en apt moderno, `apt --fix-broken install`). Más allá de `dpkg --configure -a`, APT puede **descargar e instalar las dependencias faltantes** desde los repositorios, y puede proponer eliminar paquetes para resolver un conjunto insatisfacible. `dpkg` solo puede trabajar con los archivos `.deb` que le entregues.

5. - **Quién/cuándo/con qué comando:** `/var/log/apt/history.log` (y `history.log.*.gz`), que registra `Start-Date`, `Commandline`, `Requested-By` (el usuario invocante vía sudo), las listas `Install`/`Upgrade`/`Remove`/`Purge`, y `End-Date`. `/var/log/apt/term.log` guarda la salida cruda de terminal de esas mismas transacciones.
   - **Transiciones de estado:** `/var/log/dpkg.log`, que registra cada cambio `status <state> <pkg>:<arch> <version>` incluyendo `half-installed`, `unpacked`, `half-configured`, `installed`, además de `configure`, `trigproc`, `remove`, `purge`, `upgrade` y las decisiones de `conffile`.

6. `dpkg --audit` informa paquetes que están (a) parcialmente instalados — *unpacked* o *half-configured*, es decir, `postinst` nunca completó, y (b) parcialmente eliminados / `half-installed`, es decir, la operación se interrumpió a mitad de las operaciones sobre archivos. También señala paquetes cuya *reinstalación es requerida* (`R` en la columna de error) y, con un argumento de paquete, archivos faltantes.

### Bloque 8

1. Las nueve posiciones replican la convención de `-V` de RPM; dpkg actualmente implementa solo la verificación de suma de comprobación, así que todo salvo la posición 3 es `?` ("no verificado"). Posición 3 = `5` significa que la **suma MD5 difiere** de la registrada en el momento de la instalación. La columna separada después de los flags es el tipo de archivo: `c` = conffile, en blanco = archivo ordinario. Así que: *"el contenido de este conffile ya no coincide con la versión empaquetada"*. `missing` aparece en lugar de la cadena de flags cuando el archivo está ausente por completo.

2. Los archivos `.md5sums` viven en el mismo sistema de archivos, escribibles por root. Un atacante que reemplazó `/usr/bin/sshd` también reescribirá `/var/lib/dpkg/info/openssh-server.md5sums`, y `dpkg -V` informará entonces que el sistema está limpio. Para una auditoría confiable hay que comparar contra una fuente de verdad **fuera del host**: volver a descargar el `.deb` del repositorio (cuyo índice `Packages` está firmado con GPG) y comparar, por ejemplo `debsums --generate=all` contra una descarga fresca, o usar un IDS independiente del host (AIDE, Tripwire) cuya base de datos se almacene fuera de la máquina. Y aun así, solo la cadena de firmas del repositorio es autoritativa.

3. Porque editar archivos bajo `/etc` es el flujo administrativo *previsto*, garantizado por la Debian Policy §10.7. Si un conffile modificado contara como corrupción, todos los servidores configurados del planeta fallarían la verificación. El marcador `c` existe precisamente para que las herramientas puedan filtrar esas líneas, que es para lo que sirve `debsums -c` (todos los archivos cambiados) frente a `debsums -ce` (solo conffiles cambiados).

4. `debsums -c` lista **todos** los archivos cuya suma de comprobación ya no coincide: binarios, bibliotecas, documentación y conffiles por igual. `debsums -ce` restringe el informe a **solo conffiles**, es decir, los cambios administrativos esperados. En respuesta a incidentes querés `debsums -c` y después restar el conjunto de `-ce`: lo que queda es inexplicado.

5. `debsums` informa que el paquete **no tiene sumas de comprobación disponibles** (con `-s` permanece silencioso; sin él, una línea por paquete faltante). `debsums --generate=missing` (o `-g missing`) regenera las sumas, pero debe descargar el `.deb` del archivo o leerlo desde `/var/cache/apt/archives/`: regenerar a partir de los archivos *instalados* sería circular y no probaría nada. `--generate=all` regenera para todos los paquetes.

6. ```bash
   apt-get install -y --reinstall \
       -o Dpkg::Options::="--force-confask,confnew" nano
   ```
   o, forzando de forma no interactiva el valor por defecto del paquete:
   ```bash
   apt-get install -y --reinstall \
       -o Dpkg::Options::="--force-confnew" -o Dpkg::Options::="--force-confdef" nano
   ```
   `--force-confnew` toma la versión del paquete, `--force-confold` conserva la tuya, `--force-confdef` deja que dpkg elija la acción por defecto cuando tiene una. La reinstalación sola nunca toca un conffile que el paquete no cambió, que es por lo que `/etc/nanorc` sobrevivió.

### Bloque 9

1. `dpkg-reconfigure` (a) desregistra las respuestas de debconf del paquete para que las preguntas vuelvan a estar "no vistas", (b) vuelve a ejecutar el script **`config`** del paquete (del archivo de control) para hacer las preguntas, y (c) vuelve a ejecutar **`postinst configure`** con las nuevas respuestas para que la configuración se aplique realmente. No es un editor de ajustes: reejecuta código real del mantenedor, que es por lo que puede reiniciar servicios.

2. De menor a mayor: **`low`, `medium`, `high`, `critical`**. El umbral por defecto es `high`, así que solo se muestran las preguntas `high` y `critical`. `-plow` baja el umbral a `low`, con lo que se presenta **cada** pregunta, incluidas las que el mantenedor consideró seguras de responder automáticamente. (`-pcritical` muestra casi nada.)

3. En la base de datos de debconf, por defecto `/var/cache/debconf/config.dat` (respuestas) y `/var/cache/debconf/templates.dat` (texto de las preguntas), con `/var/cache/debconf/passwords.dat` para respuestas de tipo contraseña, y el backend configurado en `/etc/debconf.conf`. Está separada de `/var/lib/dpkg/status` porque debconf es una capa de gestión de configuración independiente con su propio ciclo de vida: las respuestas deben sobrevivir a la eliminación del paquete, poder presembrarse *antes* de que el paquete exista, y compartirse entre paquetes.

4. (a) `DEBIAN_FRONTEND=noninteractive`, que selecciona un frontend que nunca pregunta y acepta todos los valores por defecto; (b) **presembrar** las respuestas con `debconf-set-selections` (o un archivo de preseed) antes de instalar, de modo que los valores por defecto sean los que vos querés.
   `DEBIAN_FRONTEND=noninteractive` por sí solo es insuficiente porque solo suprime el *preguntar*: obtenés los valores por defecto del mantenedor, no los tuyos. Tampoco cubre el prompt de conffiles **propio de dpkg**, que no es una pregunta de debconf; eso necesita `-o Dpkg::Options::="--force-confold"` (o `confnew`). Y un `postinst` mal escrito que llame a `read` directamente igual se va a colgar.

5. El paquete debe estar al menos **desempaquetado y configurado**: en la práctica `ii`. `rc` **no** califica: `dpkg-reconfigure` se niega con `Package <pkg> is not installed`, porque los scripts `config` y `postinst` se eliminaron junto con el payload. Primero hay que reinstalar.

6. Porque `dpkg-reconfigure`/el presembrado ejercen la lógica propia del paquete. Para `tzdata`, poner `/etc/timezone` a mano deja `/etc/localtime` apuntando a la zona vieja y deja obsoleta la respuesta registrada en debconf, así que la siguiente actualización de `tzdata`, que ejecuta `postinst configure` con la respuesta almacenada, revierte silenciosamente tu cambio. El presembrado establece el valor en la capa que es dueña de él, así que es idempotente y sobrevive a las actualizaciones. Además es el único enfoque que funciona en la construcción de una imagen sin TTY.

### Bloque 10

1. Son el **mismo mecanismo**. `apt-mark hold` establece la *selección* de dpkg en `hold` en `/var/lib/dpkg/status` (la línea `Status:` pasa a ser `hold ok installed`), que es exactamente lo que hace `echo "pkg hold" | dpkg --set-selections`. Por eso `apt-mark showhold` y `dpkg --get-selections | grep hold` coinciden, y por eso ambos producen `hi` en `dpkg -l`. (Nota: esto *no* es la marca auto/manual, que vive en `/var/lib/apt/extended_states` — un concepto completamente distinto.)

2. (a) La actualización requeriría **instalar un paquete nuevo o eliminar uno existente**: `apt-get upgrade` se niega a hacer cualquiera de las dos cosas, así que retiene el paquete. `apt-get dist-upgrade` sí lo hará. (b) **Actualizaciones por fases** (`Phased-Update-Percentage`, prominentes en Ubuntu): la máquina todavía no fue seleccionada para el despliegue. También es común: una dependencia insatisfacible desde una fuente fijada o de terceros.

3. - `apt-get upgrade` — actualiza solo los paquetes instalados. Nunca instala un paquete nuevo, nunca elimina uno. Conservador.
   - `apt-get dist-upgrade` — puede instalar paquetes nuevos y eliminar existentes para satisfacer dependencias cambiadas. Necesario para actualizaciones de release y para paquetes de transición.
   - `apt full-upgrade` — el nombre que le da el frontend `apt` a `dist-upgrade`. Comportamiento idéntico, CLI inestable.
   Para uso desatendido en producción, `apt-get upgrade` (o mejor, `unattended-upgrades` restringido a `-security`), porque nunca puede eliminar un paquete: un `dist-upgrade` que elimina tu MTA a las 03:00 sin operador presente es una caída de servicio.

4. `apt-get dselect-upgrade` lee las **selecciones** ya registradas en la base de datos de dpkg (`install` / `hold` / `deinstall` / `purge`) y hace que el sistema coincida con ellas, incluyendo *eliminar* los paquetes marcados `deinstall` y *purgar* los marcados `purge`. `apt-get install $(cat list)` solo agrega; no puede expresar eliminación, y marca todo como manual. El par `dpkg --get-selections '*' > f` / `dpkg --set-selections < f` + `apt-get dselect-upgrade` es el procedimiento clásico de replicación de un sistema completo.

5. Un hold **no** impide la eliminación. `apt-get remove nginx-core` sobre un paquete en hold procede normalmente (APT advierte en algunas versiones pero obedece), y `dpkg -r` lo elimina; solo el procesamiento *automático* de dpkg guiado por dependencias respeta el hold, que es lo que anula `--force-hold`. El hold protege contra la *actualización*, no contra un comando explícito del operador. Para bloquear la eliminación necesitás `apt_preferences` o, correctamente, un arreglo tipo `Essential` o gestión de configuración.

6. De `apt_preferences(5)`:
   - **`< 0`** — la versión nunca se instalará.
   - **`0–99`** — se instala solo si no hay ninguna versión del paquete instalada actualmente.
   - **`100`** — se instala solo si no hay ninguna versión instalada, *o* si es la versión actualmente instalada (esta es la prioridad por defecto de la versión instalada y de las fuentes `NotAutomatic` como backports).
   - **`101–499`** — se instala salvo que haya disponible una versión de una fuente de mayor prioridad; puede actualizar.
   - **`500`** — el valor por defecto para una fuente configurada normal; se instala salvo que haya una versión más nueva disponible en otro lado con prioridad igual o mayor.
   - **`990`** — el valor por defecto para la release de destino (`-t` / `APT::Default-Release`); se prefiere incluso por encima de una versión numéricamente más nueva en otro lado.
   - **`> 1000`** — la versión se instala **aunque eso implique degradar (downgrade)**. Esta es la única banda que permite un downgrade automático.

### Bloque 11

1. `/var/lib/dpkg/lock` protege una **única transacción de la base de datos de dpkg**. `/var/lib/dpkg/lock-frontend` protege la **sesión completa del frontend**, que abarca muchas invocaciones de dpkg más el resolutor, la fase de descarga y la interacción con debconf. Sin el lock de frontend, un segundo `apt-get` podría colarse entre dos de las llamadas a dpkg del primero, calcular un plan contra un estado de la base de datos que está por cambiar, y producir una transacción inconsistente. El lock de frontend también permite que un frontend retenga la sesión mientras el propio dpkg libera brevemente el lock de la base de datos durante los scripts del mantenedor.

2. Borrar el lock mientras otro proceso está a mitad de una transacción permite que un segundo dpkg corra concurrentemente contra `/var/lib/dpkg/status`. Dos escritores sobre la base de datos de estado producen un archivo corrupto o truncado, paquetes medio instalados y manifiestos `.list` perdidos: un estado que puede requerir restaurar desde `status-old` o reinstalar a mano. Procedimiento correcto:
   ```bash
   lsof /var/lib/dpkg/lock-frontend            # or: fuser -v /var/lib/dpkg/lock*
   ps -o pid,ppid,etime,stat,cmd -p <PID>      # is it running or stuck?
   # If it is a legitimate run (unattended-upgrades is the usual culprit): wait.
   # If it is genuinely dead:
   systemctl stop unattended-upgrades          # stop the source, not the symptom
   kill <PID>                                  # SIGTERM, let it clean up
   dpkg --configure -a                         # then repair
   apt-get -f install
   ```
   Solo si se confirma que el proceso ya no existe y el archivo de lock quedó obsoleto se vuelve defendible eliminarlo, y debe ir seguido de `dpkg --configure -a`.

3. `[!]` marca opciones que son **extremadamente peligrosas** y que no quedan habilitadas por el subconjunto "seguro" de `--force-all` del modo en que sí lo están las `[*]` (habilitadas por defecto). En `dpkg --force-help`, `[*]` = habilitada por defecto, `[!]` = peligrosa, producirá una advertencia ruidosa, y puede dejar el sistema en un estado que dpkg no puede reparar. `--force-depends`, `--force-overwrite`, `--force-remove-essential` y `--force-all` lo llevan.

4. El campo de control **`Essential: yes`** (Debian Policy §3.8): paquetes que deben estar funcionales en todo momento para que el sistema funcione; dpkg se niega a eliminarlos. `--force-remove-essential` lo anula. Los usos legítimos se limitan esencialmente a: reparar un paquete esencial roto dentro de un `chroot`/construcción de imagen de contenedor donde lo reinstalás inmediatamente, o un cross-grade deliberado bajo recuperación. En un sistema en marcha, es la forma de dejar una máquina inarrancable e inalcanzable con un solo comando. (Relacionado: `Protected: yes`, que protege la ruta de arranque, anulado por `--force-remove-protected`.)

5. `apt-get check` actualiza la caché de paquetes y luego verifica que el **árbol de dependencias sea consistente**: que los `Depends`, `Pre-Depends`, `Conflicts` y `Breaks` de cada paquete instalado estén satisfechos. Responde "¿es sólido el *grafo de dependencias*?". `dpkg --audit` responde otra pregunta: "¿hay algún paquete en un *estado parcial*?" — unpacked, half-configured, half-installed. Un sistema puede pasar `dpkg --audit` y fallar `apt-get check` (todos los paquetes completamente configurados pero una dependencia fue eliminada por la fuerza), y viceversa.

6. La solución correcta es hacer que la dependencia sea **declarable**: construir un `.deb` propio para la biblioteca local (`dpkg-deb --build`, `checkinstall` o `fpm`) para que se registre en la base de datos de dpkg y satisfaga el `Depends` legítimamente; o, cuando solo necesitás satisfacer la relación, construir un paquete ficticio con `equivs` (`equivs-control` / `equivs-build`) que declare `Provides:` con el nombre y la versión requeridos.
   `--force-depends` está mal porque convierte el error de dependencia en una advertencia **permanentemente en la base de datos**: el paquete se configura, pero dpkg ahora registra una dependencia insatisfecha. Cada `apt-get install`, `upgrade` y `dist-upgrade` posterior verá un árbol roto, `apt-get check` fallará, y el resolutor de APT puede proponer eliminaciones para "arreglarlo". No resolviste el problema: lo escondiste de la única herramienta que podría haberte avisado, y dejaste una trampa para el próximo operador.

</details>

---

## Fuentes oficiales

- LPI — Objetivos del Examen 101-500 (Tema 102.4): <https://www.lpi.org/our-certifications/exam-101-objectives/>
- Debian Policy Manual — Capítulo 3 (Paquetes binarios), 7 (Declaración de relaciones), 10.7 (Archivos de configuración): <https://www.debian.org/doc/debian-policy/>
- `dpkg(1)`: <https://manpages.debian.org/bookworm/dpkg/dpkg.1.en.html>
- `dpkg-query(1)`: <https://manpages.debian.org/bookworm/dpkg/dpkg-query.1.en.html>
- `dpkg-deb(1)`: <https://manpages.debian.org/bookworm/dpkg/dpkg-deb.1.en.html>
- `deb(5)` — formato de archivo: <https://manpages.debian.org/bookworm/dpkg-dev/deb.5.en.html>
- `apt(8)` / `apt-get(8)` / `apt-cache(8)` / `apt-mark(8)`: <https://manpages.debian.org/bookworm/apt/>
- `sources.list(5)`: <https://manpages.debian.org/bookworm/apt/sources.list.5.en.html>
- `apt_preferences(5)` — pinning: <https://manpages.debian.org/bookworm/apt/apt_preferences.5.en.html>
- `dpkg-reconfigure(8)` y `debconf(7)`: <https://manpages.debian.org/bookworm/debconf/dpkg-reconfigure.8.en.html>
- Formato de repositorios de Debian: <https://wiki.debian.org/DebianRepository/Format>
- `/usr` fusionado en Debian (DEP-17): <https://wiki.debian.org/UsrMerge>
- The Debian Administrator's Handbook — Capítulos 5 (Sistema de paquetes) y 6 (Mantenimiento y actualizaciones): <https://www.debian.org/doc/manuals/debian-handbook/>