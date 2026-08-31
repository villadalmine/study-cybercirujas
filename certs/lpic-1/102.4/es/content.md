# 102.4 — Uso de la gestión de paquetes Debian

**LPIC-1 · Examen 101-500 / 102-500 · Versión 5.0 · Peso del objetivo: 4.69**

---

## 1. El problema de producción: por qué la gestión de paquetes es un plano de control, no una comodidad

Un sistema de la familia Debian no es un sistema de archivos con programas copiados dentro. Es una **base de datos transaccional de estado declarado** (`/var/lib/dpkg/status`) más un **solucionador de restricciones** (APT) que calcula las transiciones entre estados. Cada archivo bajo `/usr` en un host correctamente gestionado tiene dueño, versión, suma de verificación y es atribuible a un artefacto firmado proveniente de un índice firmado. Esa propiedad es la que hace posibles las siguientes operaciones a escala de flota:

| Requisito de producción | Qué aporta el sistema de paquetes | Qué se rompe sin él |
|---|---|---|
| Builds reproducibles de imágenes doradas | Versiones fijadas + archivos snapshot + índices `Packages` | Deriva de imagen entre el build N y el N+1; "funciona en la AMI vieja" |
| Atestación de la cadena de suministro | Firma OpenPGP separada sobre `Release`, SHA256 sobre cada índice y cada `.deb` | Cualquier MITM o mirror comprometido inyecta código arbitrario a nivel root |
| Forense de incidentes | `dpkg -S`, `dpkg -V`, `/var/log/dpkg.log`, `/var/log/apt/history.log` | "¿De dónde salió `/usr/local/bin/agent`?" no tiene respuesta |
| Rollback seguro | Archivos versionados + `apt-get install pkg=version` + preservación de conffiles | Hacer rollback significa reimaginar la máquina |
| Respuesta a CVE dentro de un SLA | `debsecan`, `apt list --upgradable`, suite de seguridad separada de la suite principal | Planillas de inventario manuales |
| Builds inmutables / de contenedores | `--no-install-recommends`, `sources.list` determinista, `apt-mark showmanual` | Imágenes de 900 MB con un toolchain de compilación en producción |

El modo de falla arquitectónico que este objetivo existe para prevenir es el **estado no rastreado**. En el momento en que un operador ejecuta `curl … | tar -C /usr -xz`, el host abandona el modelo: sin propiedad de archivos, sin suma de verificación, sin ruta de actualización, sin ruta de eliminación, sin mapeo de CVE. Cada técnica de abajo existe para mantener los cambios dentro del modelo transaccional — o, cuando un artefacto de terceros es inevitable, para envolverlo en un `.deb` de modo que vuelva a entrar en el modelo.

### 1.1 El modelo de capas

```
┌──────────────────────────────────────────────────────────────────────┐
│  Layer 3 — Front ends / policy                                       │
│  apt (interactive), aptitude (own resolver + TUI),                   │
│  unattended-upgrades, synaptic, ansible/apt module, cloud-init       │
├──────────────────────────────────────────────────────────────────────┤
│  Layer 2 — APT: acquisition + dependency resolution                  │
│  apt-get, apt-cache, apt-mark, apt-file, apt-config                  │
│  Reads:  /etc/apt/sources.list{,.d}, /etc/apt/preferences{,.d},      │
│          /etc/apt/apt.conf{,.d}, /etc/apt/trusted.gpg.d, keyrings    │
│  Writes: /var/lib/apt/lists/, /var/cache/apt/archives/               │
│  Output: an ordered list of .deb files handed to dpkg                │
├──────────────────────────────────────────────────────────────────────┤
│  Layer 1 — dpkg: the local transaction engine                        │
│  dpkg, dpkg-deb, dpkg-query, dpkg-divert, dpkg-statoverride,         │
│  dpkg-trigger, dpkg-reconfigure (via debconf)                        │
│  State:  /var/lib/dpkg/status, /var/lib/dpkg/info/*                  │
├──────────────────────────────────────────────────────────────────────┤
│  Layer 0 — the .deb artifact  (an `ar` archive)                      │
└──────────────────────────────────────────────────────────────────────┘
```

**La consecuencia operativa más importante de este diagrama:** `dpkg` *no* tiene concepto de repositorio, *no* tiene acceso a la red y *no* tiene un solucionador de dependencias. Sólo verifica que las dependencias estén satisfechas y se niega en caso contrario. APT nunca toca el sistema de archivos bajo `/usr`; descarga y ordena. Casi todo incidente de "gestión de paquetes" es una atribución equivocada de un síntoma a la capa incorrecta.

---

## 2. Capa 0 — el artefacto `.deb`, diseccionado

Un `.deb` es un archivo `ar(1)` plano con exactamente tres miembros en un orden fijo.

```console
$ apt-get download nginx-light
Get:1 http://deb.debian.org/debian bookworm/main amd64 nginx-light amd64 1.22.1-9 [509 kB]
Fetched 509 kB in 0s (3,412 kB/s)

$ ar t nginx-light_1.22.1-9_amd64.deb
debian-binary
control.tar.xz
data.tar.xz

$ ar p nginx-light_1.22.1-9_amd64.deb debian-binary
2.0
```

| Miembro | Contenido | Propósito |
|---|---|---|
| `debian-binary` | La cadena literal `2.0\n` | Versión del formato; protege contra incompatibilidad futura |
| `control.tar.{gz,xz,zst}` | `control`, `md5sums`, `conffiles`, scripts del mantenedor, `triggers`, `templates`, `shlibs`, `symbols` | Metadatos + la lógica ejecutable que corre dpkg |
| `data.tar.{gz,xz,zst,bz2}` | La carga útil, con raíz en `/` | Los archivos que realmente se instalan |

Debian 12 usa `xz` para ambos tarballs; Ubuntu ≥ 21.10 usa `zstd` por defecto para `data.tar` (descompresión más rápida, marginalmente más grande). Un `.deb` comprimido con `zstd` **no es instalable por dpkg < 1.21.18**, lo que es una trampa real de portabilidad entre distribuciones al copiar artefactos entre un agente de build Ubuntu y un destino Debian.

### 2.1 Inspeccionar un artefacto sin instalarlo

```console
$ dpkg-deb -I nginx-light_1.22.1-9_amd64.deb
 new Debian package, version 2.0.
 size 508984 bytes: control archive=1868 bytes.
     996 bytes,    21 lines      control
    1183 bytes,    18 lines      md5sums
     167 bytes,     6 lines      conffiles
    1421 bytes,    47 lines   *  postinst             #!/bin/sh
     853 bytes,    28 lines   *  postrm               #!/bin/sh
     371 bytes,    15 lines   *  prerm                #!/bin/sh
 Package: nginx-light
 Source: nginx
 Version: 1.22.1-9
 Architecture: amd64
 Maintainer: Debian Nginx Maintainers <pkg-nginx-maintainers@alioth-lists.debian.net>
 Installed-Size: 1387
 Depends: nginx-common (= 1.22.1-9), libc6 (>= 2.34), libcrypt1 (>= 1:4.1.0), libpcre2-8-0 (>= 10.22), libssl3 (>= 3.0.0), zlib1g (>= 1:1.1.4)
 Recommends: nginx-doc
 Conflicts: nginx-core, nginx-extras, nginx-full
 Provides: httpd, httpd-cgi, nginx
 Replaces: nginx-core, nginx-extras, nginx-full
 Section: httpd
 Priority: optional
 Homepage: https://nginx.org
 Description: small, powerful, scalable web/proxy server
```

```console
$ dpkg-deb -c nginx-light_1.22.1-9_amd64.deb | head -12
drwxr-xr-x root/root         0 2023-06-11 20:14 ./
drwxr-xr-x root/root         0 2023-06-11 20:14 ./etc/
drwxr-xr-x root/root         0 2023-06-11 20:14 ./etc/nginx/
drwxr-xr-x root/root         0 2023-06-11 20:14 ./etc/nginx/modules-enabled/
drwxr-xr-x root/root         0 2023-06-11 20:14 ./usr/
drwxr-xr-x root/root         0 2023-06-11 20:14 ./usr/sbin/
-rwxr-xr-x root/root   1204584 2023-06-11 20:14 ./usr/sbin/nginx
drwxr-xr-x root/root         0 2023-06-11 20:14 ./usr/share/
drwxr-xr-x root/root         0 2023-06-11 20:14 ./usr/share/doc/
drwxr-xr-x root/root         0 2023-06-11 20:14 ./usr/share/doc/nginx-light/
drwxr-xr-x root/root         0 2023-06-11 20:14 ./usr/share/man/
drwxr-xr-x root/root         0 2023-06-11 20:14 ./usr/share/man/man8/
```

**Auditar un `.deb` de un proveedor antes de que toque un host** — extraer control y carga útil a un directorio temporal. Este es el paso de revisión obligatorio para cualquier paquete de terceros en un entorno regulado, porque `preinst`/`postinst` se ejecutan como root:

```console
$ mkdir -p /tmp/audit/{control,data}
$ dpkg-deb -e vendor-agent_4.2.0_amd64.deb /tmp/audit/control   # control files only
$ dpkg-deb -x vendor-agent_4.2.0_amd64.deb /tmp/audit/data      # payload, quiet
$ dpkg-deb -X vendor-agent_4.2.0_amd64.deb /tmp/audit/data      # payload, verbose listing

$ cat /tmp/audit/control/postinst
#!/bin/sh
set -e
case "$1" in
  configure)
    curl -sS https://updates.vendor.example/enroll | sh    # <-- reject this package
    ;;
esac
#DEBHELPER#
exit 0
```

| Flag | Significado | Nota |
|---|---|---|
| `dpkg-deb -I` / `--info` | Muestra `control` + lista los archivos de control | Nunca ejecuta nada |
| `dpkg-deb -f pkg.deb Depends` | Imprime un campo de control | Scriptable, exacto |
| `dpkg-deb -c` / `--contents` | Lista la carga útil con modos, dueños, tamaños | Igual que `tar tvf data.tar` |
| `dpkg-deb -e` / `--control` | Extrae los archivos de control a un directorio | Acá se leen los scripts del mantenedor |
| `dpkg-deb -x` / `--extract` | Extrae la carga útil (silencioso) | **No** ejecuta scripts, **no** registra en la BD de dpkg |
| `dpkg-deb -X` / `--vextract` | Extrae la carga útil, listando los archivos | |
| `dpkg-deb -b dir pkg.deb` | Construye un `.deb` desde un árbol | Base de `fpm`, `checkinstall` |

> `dpkg -I`, `dpkg -c`, `dpkg -e`, `dpkg -x` son alias que dpkg reenvía a `dpkg-deb`. En el examen cualquiera de las dos formas es válida.

### 2.2 Semántica de los campos de dependencia — la tabla de compromisos

Equivocarse acá es la causa raíz tanto de imágenes infladas como de actualizaciones rotas.

| Campo | Fuerza | ¿Lo aplica dpkg? | Significado en producción |
|---|---|---|---|
| `Depends` | Debe estar **configurado** antes de que este paquete se configure | Sí — se niega a configurar | Requisito duro de ejecución |
| `Pre-Depends` | Debe estar completamente instalado antes de que este paquete siquiera se **desempaquete** | Sí — se niega a desempaquetar | Necesario para `preinst`; fuerza una corrida extra de dpkg; se usa con moderación (p. ej. `init-system-helpers`) |
| `Recommends` | "Se encontrarían juntos salvo en instalaciones inusuales" | No | **APT lo instala por defecto.** Fuente principal de inflado de imágenes |
| `Suggests` | Mejora, pero no está relacionado | No | Nunca se instala automáticamente |
| `Enhances` | `Suggests` inverso, declarado por quien mejora | No | Usado por paquetes de plugins |
| `Breaks` | Este paquete rompe las versiones nombradas | Sí — el destino debe desconfigurarse/actualizarse | Forma moderna preferida; permite coinstalación tras la actualización |
| `Conflicts` | No puede desempaquetarse al mismo tiempo en absoluto | Sí — el destino debe eliminarse | Martillo más pesado; usar sólo para choques genuinos de archivos/espacio de nombres |
| `Replaces` | Puede sobrescribir archivos del paquete nombrado | Sí — permite la toma de control de archivos | Se combina con `Breaks`/`Conflicts` durante renombramientos de paquetes |
| `Provides` | Declara un nombre de paquete virtual | Sí — satisface `Depends` | `httpd`, `mail-transport-agent`, `awk` |

Relaciones de versión: `(<< v)` estrictamente anterior, `(<= v)`, `(= v)`, `(>= v)`, `(>> v)` estrictamente posterior. Las alternativas usan `|`: `Depends: nginx-core | nginx-light | nginx-full` — APT elige la **primera** alternativa satisfacible salvo que una ya esté instalada.

**Detalle decisivo para imágenes:** los `Recommends` se arrastran por defecto. Una línea convierte una imagen de 120 MB en una de 480 MB:

```console
$ apt-get install -y --no-install-recommends nginx-light
```

O globalmente, que es la elección correcta para una base de contenedor:

```console
$ cat /etc/apt/apt.conf.d/99no-recommends
APT::Install-Recommends "false";
APT::Install-Suggests "false";
APT::AutoRemove::RecommendsImportant "false";
APT::AutoRemove::SuggestsImportant "false";
```

### 2.3 Cadenas de versión y el algoritmo de comparación

Formato: `[epoch:]upstream_version[-debian_revision]`

```
1:9.2p1-2+deb12u3
│ │      │
│ │      └── Debian revision — packaging changes only
│ └───────── upstream version
└─────────── epoch (default 0, rarely displayed)
```

Reglas de comparación que producen sorpresas en el mundo real:

1. La época domina todo. `1:1.0` > `2.0`. Las épocas son la vía de escape cuando upstream *baja* su número de versión; nunca pueden eliminarse.
2. Las cadenas se dividen en tramos alternados de no-dígitos y dígitos; los tramos de dígitos se comparan numéricamente (`1.10` > `1.9`), los de no-dígitos por un orden ASCII modificado.
3. **`~` ordena antes que todo, incluida la cadena vacía.** Esto es lo que hace que `1.0~rc1 < 1.0` y `1.0~~a < 1.0~`. Es el mecanismo detrás del empaquetado de prelanzamientos y de los sufijos de versión de backports.
4. Las letras ordenan antes que los no-letras, así que `1.0a < 1.0+b`.

Nunca adivines — `dpkg` expone el algoritmo directamente, y funciona por código de salida, así que se compone en scripts:

```console
$ dpkg --compare-versions "1.0~rc1" lt "1.0" && echo "true"
true
$ dpkg --compare-versions "1.10" gt "1.9" && echo "true"
true
$ dpkg --compare-versions "2.0" gt "1:1.0" || echo "false — epoch wins"
false — epoch wins
$ dpkg --compare-versions "1.22.1-9" ge "1.22.1-9+deb12u1"; echo $?
1
```

Operadores: `lt le eq ne ge gt` (y las formas obsoletas `lt-nl`, `gt-nl`, `<`, `>`). Usá esto en health checks en lugar de comparación de cadenas del shell — una prueba `[ "$v" \> "1.9" ]` está mal para `1.10`.

---

## 3. Capa 1 — `dpkg`: el motor de transacciones local

### 3.1 La base de datos en disco

| Ruta | Contenido | Relevancia operativa |
|---|---|---|
| `/var/lib/dpkg/status` | El registro autoritativo: una estrofa RFC822 por paquete conocido, con `Status`, `Version`, `Conffiles` | **Respaldalo.** Corromperlo es la única falla de dpkg genuinamente difícil de recuperar |
| `/var/lib/dpkg/status-old` | Copia previa, rotada al escribir | Primer objetivo de recuperación |
| `/var/backups/dpkg.status.*` | Respaldos rotados diariamente (vía cron) | Segundo objetivo de recuperación |
| `/var/lib/dpkg/info/<pkg>.list` | Cada ruta que el paquete posee | Fuente de `dpkg -L` y `dpkg -S` |
| `/var/lib/dpkg/info/<pkg>.md5sums` | Sumas de verificación de los archivos entregados | Fuente de `dpkg -V` y `debsums` |
| `/var/lib/dpkg/info/<pkg>.conffiles` | Archivos bajo `/etc` bajo protección de conffile | Determina los prompts de actualización |
| `/var/lib/dpkg/info/<pkg>.{preinst,postinst,prerm,postrm,config,templates,triggers}` | Lógica del mantenedor | Leelos cuando una actualización se cuelga |
| `/var/lib/dpkg/available` | Índice legado de `dselect` | Alimenta la sanidad de `dpkg --set-selections`; mayormente vestigial |
| `/var/lib/dpkg/lock`, `lock-frontend` | Bloqueos consultivos | Fuente del error de APT más común |
| `/var/lib/dpkg/triggers/` | Triggers diferidos pendientes | Explica los estados `trig-pend` / `trig-aWait` |
| `/var/log/dpkg.log` | Rastro de auditoría por acción con marcas de tiempo | Forense: exactamente cuándo cambió una versión |

```console
$ grep -A2 '^Package: openssh-server$' /var/lib/dpkg/status | head -3
Package: openssh-server
Status: install ok installed
Priority: optional
```

El campo `Status` son tres tokens: **selección deseada**, **bandera de error**, **estado actual**.

### 3.2 Leer `dpkg -l` — la máquina de estados

```console
$ dpkg -l openssh-server nginx-light nonexistent-pkg
Desired=Unknown/Install/Remove/Purge/Hold
| Status=Not/Inst/Conf-files/Unpacked/halF-conf/Half-inst/trig-aWait/Trig-pend
|/ Err?=(none)/Reinst-required (Status,Err: uppercase=bad)
||/ Name            Version            Architecture Description
+++-===============-==================-============-=====================================
ii  nginx-light     1.22.1-9           amd64        small, powerful, scalable web/proxy server
ii  openssh-server  1:9.2p1-2+deb12u3  amd64        secure shell (SSH) server, for secure access
dpkg-query: no packages found matching nonexistent-pkg
```

| Columna 1 — Deseado | Significado |
|---|---|
| `u` | Desconocido — nunca se registró una selección |
| `i` | Instalar |
| `r` | Eliminar (conservar conffiles) |
| `p` | Purgar |
| `h` | **Hold** — dpkg se negará a actualizarlo |

| Columna 2 — Estado actual | Significado | ¿Sano? |
|---|---|---|
| `n` | No instalado | ✅ |
| `i` | Instalado y configurado | ✅ |
| `c` | Sólo quedan archivos de configuración (eliminado, no purgado) | ⚠️ estado residual |
| `U` | **Desempaquetado** — archivos presentes, `postinst` no ejecutado | ❌ |
| `F` | **Medio configurado** — `postinst` falló | ❌ |
| `H` | **Medio instalado** — desempaquetado abortado a mitad de camino | ❌ |
| `W` | En espera de trigger | transitorio |
| `t` | Trigger pendiente | transitorio |

| Columna 3 — Error | Significado |
|---|---|
| *(espacio)* | Sin error |
| `R` | **Reinst-required** — el paquete está tan roto que debe reinstalarse; `dpkg -r` se negará |

**La regla para el examen y para el runbook: mayúscula en las columnas 2 o 3 significa malo.** `iU`, `iF`, `iH`, `iR` indican todos una transacción interrumpida. La remediación está en §7.

Los dos estados que los operadores más suelen malinterpretar:

- `rc` — el paquete fue eliminado pero sus conffiles bajo `/etc` sobreviven. Todavía ocupa una estrofa en `status`. `apt purge` (o `dpkg -P`) lo limpia. Una flota con miles de entradas `rc` suele ser síntoma de haber usado `apt remove` donde se quería `apt purge`, y deja configuración obsoleta que una *reinstalación* recogerá silenciosamente meses después — una fuente extremadamente común de "el nodo nuevo se comporta distinto".
- `hi`/`hold` — puesto deliberadamente (`apt-mark hold`) o, peligrosamente, heredado de un blob de `dpkg --set-selections`. Un paquete crítico de seguridad retenido derrota silenciosamente a `unattended-upgrades`.

```console
$ dpkg -l | awk '$1 ~ /^rc/ {print $2}'
libxcb-shape0:amd64
python3-cryptography

$ dpkg -l | grep -Ev '^(ii|un) ' | grep -E '^[a-z]{2}'
rc  libxcb-shape0:amd64  1.15-1  amd64  X C Binding, shape extension
iU  vendor-agent         4.2.0   amd64  Vendor observability agent
```

### 3.3 La superficie de comandos de dpkg

```console
$ sudo dpkg -i ./vendor-agent_4.2.0_amd64.deb
Selecting previously unselected package vendor-agent.
(Reading database ... 41287 files and directories currently installed.)
Preparing to unpack vendor-agent_4.2.0_amd64.deb ...
Unpacking vendor-agent (4.2.0) ...
dpkg: dependency problems prevent configuration of vendor-agent:
 vendor-agent depends on libcurl4 (>= 7.68.0); however:
  Package libcurl4 is not installed.

dpkg: error processing package vendor-agent (--install):
 dependency problems - leaving unconfigured
Errors were encountered while processing:
 vendor-agent
```

Esa salida es el límite entre capas hecho visible: dpkg detectó la dependencia insatisfecha, se negó a configurar, y dejó el paquete en estado `iU`. No puede buscar `libcurl4` — no tiene idea de dónde vienen los paquetes. La solución es escalar a la capa 2:

```console
$ sudo apt-get -f install
Reading package lists... Done
Building dependency tree... Done
Correcting dependencies... Done
The following additional packages will be installed:
  libcurl4
The following NEW packages will be installed:
  libcurl4
0 upgraded, 1 newly installed, 0 to remove and 0 not upgraded.
1 not fully installed or removed.
Need to get 391 kB of archives.
After this operation, 1,032 kB of additional disk space will be used.
Do you want to continue? [Y/n] y
...
Setting up libcurl4:amd64 (7.88.1-10+deb12u5) ...
Setting up vendor-agent (4.2.0) ...
```

| Comando | Efecto | Advertencias |
|---|---|---|
| `dpkg -i pkg.deb` | Desempaqueta **y** configura | Sin resolución de dependencias; deja `iU` al fallar |
| `dpkg --unpack pkg.deb` | Sólo desempaqueta | Se usa para romper bloqueos de dependencias circulares |
| `dpkg --configure pkg` | Ejecuta `postinst` de un paquete desempaquetado | `--configure -a` = todos los pendientes |
| `dpkg -r pkg` | Elimina, conserva conffiles → estado `rc` | Se niega si otros dependen de él |
| `dpkg -P pkg` / `--purge` | Elimina incluyendo conffiles → estado `un`/ausente | El valor por defecto correcto para dar de baja |
| `dpkg -L pkg` | Lista los archivos que el paquete posee | Lee `.list`; sólo paquetes instalados |
| `dpkg -S /path/to/file` | Qué paquete instalado posee esta ruta | Sólo paquetes instalados — ver §5 |
| `dpkg -s pkg` | Muestra la estrofa de `status` | Incluye la línea `Status:`; `dpkg -p` muestra en cambio la estrofa *disponible* |
| `dpkg -l [glob]` | Listado tabular | El glob es estilo shell: `dpkg -l 'linux-image-*'` |
| `dpkg -C` / `--audit` | Informa paquetes en estado roto | Primer comando en cualquier triage |
| `dpkg -V pkg` | Verifica los archivos instalados contra `md5sums` | §6 |
| `dpkg --get-selections` / `--set-selections` | Vuelca/restaura estados deseados | §4.4 — reconstrucción masiva |
| `dpkg --add-architecture arch` | Habilita multi-arch | Requiere `apt update` después |
| `dpkg --print-architecture` | Arquitectura nativa | `amd64`, `arm64`, … |

```console
$ dpkg -L nginx-light | grep -E '^/usr/sbin|^/etc'
/etc/nginx
/etc/nginx/modules-enabled
/usr/sbin/nginx

$ dpkg -s nginx-light | head -8
Package: nginx-light
Status: install ok installed
Priority: optional
Section: httpd
Installed-Size: 1387
Maintainer: Debian Nginx Maintainers <pkg-nginx-maintainers@alioth-lists.debian.net>
Architecture: amd64
Version: 1.22.1-9

$ dpkg -S /usr/sbin/sshd
openssh-server: /usr/sbin/sshd

$ dpkg -S /usr/lib/x86_64-linux-gnu/libssl.so.3
libssl3:amd64: /usr/lib/x86_64-linux-gnu/libssl.so.3
```

`dpkg-query` es la interfaz scriptable y estable — preferila en automatización porque la salida de `dpkg -l` se trunca por columnas al ancho de la terminal:

```console
$ dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' openssh-server nginx-light
openssh-server	1:9.2p1-2+deb12u3	install ok installed
nginx-light	1.22.1-9	install ok installed

$ dpkg-query -W -f='${binary:Package} ${Installed-Size}\n' | sort -k2 -rn | head -5
linux-image-6.1.0-18-amd64 361447
libreoffice-core 267334
python3.11 12894
perl-base 7443
libc6:amd64 13165
```

> **Trampa de truncado:** `dpkg -l | grep foo` dentro de un job de CI con `COLUMNS` sin definir puede cortar silenciosamente la columna de versión. Usá siempre `dpkg-query -W -f=…` en scripts.

### 3.4 Conffiles: el único lugar donde dpkg negocia con vos

Cualquier archivo listado en `<pkg>.conffiles` recibe una suma de verificación al instalarse. En una actualización dpkg compara tres hashes: el entregado viejo, el entregado nuevo, y el que está en disco. Si el administrador lo modificó *y* el paquete entrega una versión nueva distinta, dpkg **pregunta**:

```console
Configuration file '/etc/ssh/sshd_config'
 ==> Modified (by you or by a script) since installation.
 ==> Package distributor has shipped an updated version.
   What would you like to do about it ?  Your options are:
    Y or I  : install the package maintainer's version
    N or O  : keep your currently-installed version
      D     : show the differences between the versions
      Z     : start a shell to examine the situation
 The default action is to keep your current version.
*** sshd_config (Y/I/N/O/D/Z) [default=N] ?
```

En automatización desatendida este prompt es un **cuelgue, no un error** — la causa más común de un `apt-get upgrade` trabado en CI o en `unattended-upgrades`. La política determinista debe declararse:

| Opción | Comportamiento | Cuándo usarla |
|---|---|---|
| `--force-confold` | Conserva el archivo en disco | La configuración la gestiona Ansible/Puppet — la fuente de verdad está en otro lado |
| `--force-confnew` | Toma el archivo del mantenedor | La configuración no está gestionada y querés los valores por defecto de upstream |
| `--force-confdef` | Toma la acción por defecto cuando *hay* una; si no, cae en `confold`/`confnew` | Combinala siempre con una de las dos anteriores |
| `--force-confmiss` | Restaura un conffile que el administrador borró | Camino de reparación |

```console
$ sudo DEBIAN_FRONTEND=noninteractive apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    upgrade
```

Definilo una vez, globalmente, en cada host gestionado:

```console
$ cat /etc/apt/apt.conf.d/99local-conffiles
Dpkg::Options {
   "--force-confdef";
   "--force-confold";
};
```

Después de una actualización aparecen archivos `.dpkg-dist` (versión del mantenedor, se conservó la tuya) y `.dpkg-old` (tu versión, se tomó la del mantenedor). Un barrido de deriva a nivel de flota:

```console
$ find /etc -name '*.dpkg-dist' -o -name '*.dpkg-old' -o -name '*.ucf-dist' | head
/etc/ssh/sshd_config.dpkg-dist
/etc/sysctl.conf.dpkg-old
```

### 3.5 `dpkg-reconfigure` y debconf

`debconf` es una base de datos separada (`/var/cache/debconf/config.dat`) que guarda las respuestas a las preguntas de los scripts del mantenedor. `dpkg-reconfigure` reproduce el script `config` de un paquete y vuelve a ejecutar `postinst` con esas respuestas.

```console
$ sudo dpkg-reconfigure -plow tzdata
Current default time zone: 'Europe/Madrid'
Local time is now:      Tue Aug 25 11:04:12 CEST 2026.
Universal Time is now:  Tue Aug 25 09:04:12 UTC 2026.

$ sudo dpkg-reconfigure -f noninteractive locales
Generating locales (this might take a while)...
  en_US.UTF-8... done
Generation complete.
```

| Flag | Significado |
|---|---|
| `-p, --priority=<low\|medium\|high\|critical>` | Muestra preguntas de esta prioridad o superior. `-plow` muestra *todo* |
| `-f, --frontend=<dialog\|readline\|noninteractive\|text>` | Qué interfaz usar |
| `-u, --unseen-only` | Sólo pregunta lo que nunca se respondió antes |
| `--force` | Reconfigura incluso un paquete en estado roto |

Inspeccionar y presembrar respuestas (paquete `debconf-utils`):

```console
$ sudo debconf-show tzdata
* tzdata/Areas: Europe
* tzdata/Zones/Europe: Madrid
  tzdata/Zones/Etc: UTC

$ sudo debconf-get-selections | grep ^postfix
postfix	postfix/main_mailer_type	select	Internet Site
postfix	postfix/mailname	string	mail.example.internal
```

La presiembra es como se instalan paquetes interactivos de forma no interactiva en una imagen dorada:

```console
$ cat postfix.preseed
postfix postfix/main_mailer_type select Internet Site
postfix postfix/mailname string mail.example.internal
postfix postfix/destinations string mail.example.internal, localhost.localdomain, localhost
postfix postfix/mynetworks string 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128 10.0.0.0/8

$ sudo debconf-set-selections < postfix.preseed
$ sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postfix
```

---

## 4. Capa 2 — APT: fuentes, política, resolución

### 4.1 Disposición del repositorio en el cable

Entender la disposición en disco de un archivo es lo que convierte "GPG error" y "404 Not Found" de misterios en arreglos de dos minutos.

```
http://deb.debian.org/debian/
├── dists/
│   └── bookworm/
│       ├── InRelease              ← index of indices, inline-signed (clearsigned)
│       ├── Release                ← same content, unsigned
│       ├── Release.gpg            ← detached signature over Release (legacy path)
│       ├── main/
│       │   ├── binary-amd64/
│       │   │   ├── Packages.gz    ← every package stanza for this component/arch
│       │   │   ├── Packages.xz
│       │   │   └── Release
│       │   ├── binary-arm64/…
│       │   ├── source/Sources.gz
│       │   └── Contents-amd64.gz  ← path → package map, consumed by apt-file
│       ├── contrib/…
│       └── non-free/…
└── pool/
    └── main/
        └── n/nginx/
            ├── nginx-light_1.22.1-9_amd64.deb
            └── nginx-common_1.22.1-9_all.deb
```

`InRelease` lleva sumas SHA256 de cada archivo `Packages`/`Sources`/`Contents`, y cada estrofa de `Packages` lleva el SHA256 del `.deb` en `pool/`. Verificar la firma OpenPGP de `InRelease` autentica por lo tanto transitivamente cada artefacto — una cadena de hashes enraizada en una sola clave. Por eso un repositorio sin firmar es un vector de compromiso equivalente a root y por eso `[trusted=yes]` nunca debe aparecer en producción.

`Release` también lleva `Date:` y `Valid-Until:`. Un índice pasado su `Valid-Until` es rechazado — la defensa contra un atacante que congela tu mirror para retener actualizaciones de seguridad. También es por eso que una imagen de contenedor de dos años falla en `apt-get update` (ver §7.4).

### 4.2 `sources.list`: ambas sintaxis

**Formato de una línea** (`/etc/apt/sources.list`, `/etc/apt/sources.list.d/*.list`):

```
deb [ options ] URI suite [component1] [component2] …
deb-src [ options ] URI suite [component …]
```

```console
$ cat /etc/apt/sources.list
deb     http://deb.debian.org/debian           bookworm            main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian           bookworm            main contrib non-free non-free-firmware
deb     http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb     http://deb.debian.org/debian           bookworm-updates    main contrib non-free non-free-firmware
```

| Token | Significado |
|---|---|
| `deb` | Paquetes binarios (`.deb`) |
| `deb-src` | Paquetes fuente — necesarios para `apt-get source` / `build-dep`, si no agregan costo de descarga de índices |
| URI | `http://`, `https://`, `ftp://`, `file:/`, `cdrom:`, `copy:`, `tor+http://`, `mirror+file:` |
| suite | `bookworm`, o un alias de *clase*: `stable`, `testing`, `unstable`, `oldstable`. **Nunca uses alias de clase en un servidor** — el host se dist-upgradea solo el día del lanzamiento |
| component | `main` (libre según DFSG), `contrib` (libre pero depende de non-free), `non-free`, `non-free-firmware` (separado en Debian 12) |
| `[ options ]` | `arch=amd64,arm64`, `signed-by=/path/to.gpg`, `trusted=yes` (nunca), `by-hash=yes`, `allow-insecure=yes` (nunca) |

**Formato deb822** (`/etc/apt/sources.list.d/*.sources`) — la forma moderna. Multilínea, amigable a comentarios, y puede llevar la clave de firma en línea, lo que elimina toda una clase de problemas de orden de arranque:

```console
$ cat /etc/apt/sources.list.d/debian.sources
Types: deb deb-src
URIs: http://deb.debian.org/debian
Suites: bookworm bookworm-updates
Components: main contrib non-free non-free-firmware
Architectures: amd64
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
Enabled: yes

Types: deb
URIs: http://security.debian.org/debian-security
Suites: bookworm-security
Components: main contrib non-free non-free-firmware
Architectures: amd64
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
Enabled: yes
```

| Aspecto | `.list` de una línea | `.sources` deb822 |
|---|---|---|
| Legibilidad / facilidad de diff | Una línea larga; el templating de gestión de configuración es frágil | Un campo por línea; diffs limpios |
| Múltiples suites por entrada | No — una línea cada una | Sí — `Suites:` acepta una lista |
| Clave en línea | No | Sí — `Signed-By:` puede contener un bloque ASCII armored |
| Deshabilitar una entrada | Comentar con `#` | `Enabled: no` |
| Soporte de herramientas | Universal | apt ≥ 1.1; por defecto en Debian 12 para fuentes nuevas, estándar en Debian 13 |
| Veredicto | Legado; conservar por compatibilidad | **Por defecto para automatización nueva** |

> Los archivos en `sources.list.d/` deben terminar en `.list` o `.sources`. Un archivo llamado `internal.list.bak` o `internal.repo` es **ignorado silenciosamente** — una causa recurrente de "mi repositorio desapareció después de la corrida de gestión de configuración".

### 4.3 Confianza en repositorios: keyrings, no `apt-key`

`apt-key` agregaba claves a un único keyring global, lo que significaba que **cualquier** clave en él podía firmar **cualquier** repositorio. Una clave comprometida de un proveedor tercero podía entonces firmar un `libc6` falso. `apt-key` está obsoleto (avisa ruidosamente en apt moderno y está siendo eliminado del archivo) — no lo uses, y sacalo de cualquier runbook que todavía lo mencione.

El patrón correcto acota una clave a un repositorio:

```console
# 1. Fetch the key and de-armor it into a binary keyring under /usr/share/keyrings
$ curl -fsSL https://download.example.com/gpg.key \
    | sudo gpg --dearmor -o /usr/share/keyrings/example-archive-keyring.gpg

# 2. Verify the fingerprint out-of-band BEFORE trusting it
$ gpg --no-default-keyring --keyring /usr/share/keyrings/example-archive-keyring.gpg \
      --list-keys --with-fingerprint
/usr/share/keyrings/example-archive-keyring.gpg
-----------------------------------------------
pub   rsa4096 2024-01-15 [SC]
      A1B2 C3D4 E5F6 0718 2939  4A5B 6C7D 8E9F A0B1 C2D3
uid           [ unknown] Example Platform Archive <archive@example.com>

# 3. Bind the key to exactly that repository
$ sudo tee /etc/apt/sources.list.d/example.sources >/dev/null <<'EOF'
Types: deb
URIs: https://download.example.com/debian
Suites: bookworm
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/example-archive-keyring.gpg
EOF

$ sudo apt-get update
Hit:1 http://deb.debian.org/debian bookworm InRelease
Get:2 https://download.example.com/debian bookworm InRelease [3,182 B]
Get:3 https://download.example.com/debian bookworm/main amd64 Packages [12.4 kB]
Fetched 15.6 kB in 1s (18.9 kB/s)
Reading package lists... Done
```

| Mecanismo | Alcance de la confianza | Veredicto |
|---|---|---|
| `apt-key add` → `/etc/apt/trusted.gpg` | Global — firma cualquier cosa | ❌ Obsoleto, eliminado |
| Depositar un `.gpg` en `/etc/apt/trusted.gpg.d/` | Global — firma cualquier cosa | ⚠️ Funciona, pero con el mismo defecto de exceso de confianza |
| `Signed-By:` → `/usr/share/keyrings/*.gpg` | Un repositorio | ✅ Correcto |
| `Signed-By:` con clave armored en línea en deb822 | Un repositorio, sin archivo extra | ✅ Correcto, el mejor para cloud-init |
| `[trusted=yes]` | Sin verificación alguna | ❌ Nunca en producción |

Auditar qué claves confía realmente un host:

```console
$ apt-key list 2>/dev/null | head -5
Warning: apt-key is deprecated. Manage keyring files in trusted.gpg.d instead (see apt-key(8)).
$ ls -l /etc/apt/trusted.gpg.d/ /usr/share/keyrings/
/etc/apt/trusted.gpg.d/:
total 16
-rw-r--r-- 1 root root 8138 Mar 12  2023 debian-archive-bookworm-automatic.asc
-rw-r--r-- 1 root root 2263 Mar 12  2023 debian-archive-bookworm-security-automatic.asc

/usr/share/keyrings/:
total 12
-rw-r--r-- 1 root root 4162 Mar 12  2023 debian-archive-keyring.gpg
-rw-r--r-- 1 root root 2795 Aug 20 09:11 example-archive-keyring.gpg
```

### 4.4 La superficie de comandos de apt

**Actualizar los índices** — esto no toca ningún paquete; refresca `/var/lib/apt/lists/`:

```console
$ sudo apt-get update
Hit:1 http://deb.debian.org/debian bookworm InRelease
Get:2 http://security.debian.org/debian-security bookworm-security InRelease [48.0 kB]
Get:3 http://deb.debian.org/debian bookworm-updates InRelease [55.4 kB]
Get:4 http://security.debian.org/debian-security bookworm-security/main amd64 Packages [186 kB]
Fetched 289 kB in 1s (243 kB/s)
Reading package lists... Done
```

`Hit` = sin cambios (validado por ETag/Last-Modified), `Get` = descargado, `Ign` = ignorado, `Err` = falló.

**Semántica de actualización — la distinción que se pregunta y que rompe producción:**

| Comando | ¿Instala paquetes nuevos? | ¿Elimina paquetes? | Uso |
|---|---|---|---|
| `apt-get upgrade` | **No** | **No** | El más conservador. Los paquetes retenidos simplemente se quedan atrás |
| `apt upgrade` | **Sí** | No | Comodidad interactiva |
| `apt-get dist-upgrade` | Sí | **Sí** | Actualizaciones de versión, transiciones de ABI del kernel |
| `apt full-upgrade` | Sí | **Sí** | Idéntico a `dist-upgrade` |

```console
$ sudo apt-get upgrade
Reading package lists... Done
Building dependency tree... Done
Reading state information... Done
Calculating upgrade... Done
The following packages have been kept back:
  linux-image-amd64
The following packages will be upgraded:
  openssl libssl3
2 upgraded, 0 newly installed, 0 to remove and 1 not upgraded.
Need to get 2,764 kB of archives.
After this operation, 0 B of additional disk space will be used.
```

"Kept back" acá significa que la actualización requeriría instalar un paquete *nuevo* (`linux-image-6.1.0-19-amd64`), lo que `apt-get upgrade` rechaza por diseño. Esto no es un bug; es la razón por la que las actualizaciones de kernel nunca llegan sólo con `apt-get upgrade`, y es una causa genuina y observada repetidamente de kernels sin parchear en hosts cuya automatización sólo ejecuta `upgrade`.

**Instalar, eliminar, purgar, y la bandera manual/auto:**

```console
$ sudo apt-get install nginx-light=1.22.1-9
$ sudo apt-get install -t bookworm-backports linux-image-amd64
$ sudo apt-get remove nginx-light      # leaves /etc/nginx → state rc
$ sudo apt-get purge nginx-light       # removes conffiles too
$ sudo apt-get autoremove --purge      # drop orphaned auto-installed deps + their conffiles
$ sudo apt autopurge                   # apt(8) shorthand for the above
```

APT registra *por qué* está presente cada paquete. `manual` = lo pediste vos; `auto` = fue arrastrado como dependencia y es elegible para `autoremove` una vez que nada lo necesita. Esta bandera es la base de la auditoría de imágenes mínimas:

```console
$ apt-mark showmanual | head
apt
bash
ca-certificates
libc6
linux-image-amd64
nginx-light
openssh-server
systemd

$ apt-mark showauto | wc -l
327
```

```console
$ sudo apt-mark hold openssh-server
openssh-server set on hold.
$ apt-mark showhold
openssh-server
$ sudo apt-mark unhold openssh-server
Canceled hold on openssh-server.
```

`apt-mark hold` escribe la retención en la selección de dpkg, así que `dpkg -l` muestra `hi` e incluso un `dpkg -i` crudo se niega. El equivalente nativo de dpkg, útil cuando apt no está disponible:

```console
$ echo "openssh-server hold" | sudo dpkg --set-selections
$ dpkg --get-selections | grep -v '^\S*\s*install$'
openssh-server					hold
libxcb-shape0:amd64				deinstall
```

**Clonado de flota** — reproducir el conjunto de paquetes de un host en una máquina nueva:

```console
# On the reference host
$ dpkg --get-selections '*' > selections.txt
$ apt-mark showauto > auto.txt

# On the new host
$ sudo dpkg --set-selections < selections.txt
$ sudo apt-get dselect-upgrade
$ sudo xargs apt-mark auto < auto.txt
```

**Higiene de caché y disco:**

```console
$ sudo apt-get clean          # empty /var/cache/apt/archives entirely
$ sudo apt-get autoclean      # drop only .debs no longer downloadable
$ du -sh /var/cache/apt/archives
412M	/var/cache/apt/archives
```

En un `Dockerfile`, `rm -rf /var/lib/apt/lists/*` en la *misma* capa `RUN` es obligatorio — un `RUN rm` separado deja los datos en la capa anterior y no ahorra nada.

**Operaciones de fuentes y dependencias de compilación** (requieren líneas `deb-src`):

```console
$ apt-get source nginx
Reading package lists... Done
NOTICE: 'nginx' packaging is maintained in the 'Git' version control system at:
https://salsa.debian.org/nginx-team/nginx.git
Need to get 1,608 kB of source archives.
Get:1 http://deb.debian.org/debian bookworm/main nginx 1.22.1-9 (dsc) [3,081 B]
Get:2 http://deb.debian.org/debian bookworm/main nginx 1.22.1-9 (tar) [1,338 kB]
Get:3 http://deb.debian.org/debian bookworm/main nginx 1.22.1-9 (diff) [267 kB]
dpkg-source: info: extracting nginx in nginx-1.22.1

$ sudo apt-get build-dep nginx
$ apt-get download nginx-light          # fetch the .deb without installing
$ apt-get --print-uris install nginx-light   # just print the URLs — for air-gapped mirroring
```

**`apt` vs `apt-get` vs `aptitude` — elegí deliberadamente:**

| Dimensión | `apt-get` / `apt-cache` | `apt` | `aptitude` |
|---|---|---|---|
| Garantía de estabilidad de la CLI | **Sí** — documentado como seguro para scripts | **No** — `apt` imprime `WARNING: apt does not have a stable CLI interface. Use with caution in scripts.` | Razonablemente estable |
| Barra de progreso / color / paginado | Mínimo | Sí | TUI + CLI |
| Solucionador de dependencias | Interno de APT (enchufable vía EDSP) | El mismo que `apt-get` | **El propio**, ofrece soluciones alternativas ordenadas de forma interactiva |
| `upgrade` instala paquetes nuevos | No | Sí | Sí |
| Autoelimina al actualizar | No | No (`full-upgrade` sí) | Sí, más agresivamente |
| Lenguaje de patrones de búsqueda | Regex básica | Regex básica | Patrones ricos (`~i`, `~M`, `~n`, `~D`) |
| "¿Por qué está instalado esto?" | Indirecto | Indirecto | `aptitude why` / `why-not` — el mejor de su clase |
| Instalado por defecto | Sí | Sí | No (`apt install aptitude`) |
| **Veredicto** | **Scripts, CI, gestión de configuración** | **Shells interactivos** | **Desenredar nudos de dependencias difíciles** |

```console
$ aptitude why libssl3
i   openssh-server Depends libssl3 (>= 3.0.0)

$ aptitude why-not nginx-full
i   nginx-light Conflicts nginx-full

$ aptitude search '~i~M~nlib' | head -3       # installed AND auto AND name matches 'lib'
i A libacl1                       - access control list - shared library
i A libaom3                       - AV1 Video Codec Library
i A libapparmor1                  - changehat AppArmor library
```

El solucionador alternativo de `aptitude` es genuinamente útil durante un nudo de dist-upgrade: donde `apt-get` informa un conjunto insatisfacible y se detiene, `aptitude` ofrece soluciones sucesivas y te permite rechazar acciones individuales. Esa es su única capacidad irreemplazable; todo lo demás lo sirve mejor `apt-get` en automatización.

### 4.5 Consultas: `apt-cache`, `apt`, y la política

```console
$ apt-cache policy nginx-light
nginx-light:
  Installed: 1.22.1-9
  Candidate: 1.22.1-9
  Version table:
 *** 1.22.1-9 500
        500 http://deb.debian.org/debian bookworm/main amd64 Packages
        100 /var/lib/dpkg/status
```

Cómo leerlo: `***` marca la versión instalada; el número de la izquierda es la *prioridad de pin* de esa versión; cada línea indentada es una fuente que la ofrece. `100 /var/lib/dpkg/status` es la pseudo-fuente que representa "ya instalado" — su prioridad por defecto de 100 es exactamente por qué una versión instalada nunca se degrada espontáneamente.

```console
$ apt-cache policy
Package files:
 100 /var/lib/dpkg/status
     release a=now
 500 http://security.debian.org/debian-security bookworm-security/main amd64 Packages
     release v=12,o=Debian,a=stable-security,n=bookworm-security,l=Debian-Security,c=main,b=amd64
     origin security.debian.org
 500 http://deb.debian.org/debian bookworm/main amd64 Packages
     release v=12.5,o=Debian,a=stable,n=bookworm,l=Debian,c=main,b=amd64
     origin deb.debian.org
Pinned packages:
```

Esos tokens `a=`, `o=`, `n=`, `l=`, `c=` son exactamente los selectores disponibles para las reglas de pinning en §4.6.

```console
$ apt-cache show nginx-light | head -6
Package: nginx-light
Version: 1.22.1-9
Installed-Size: 1387
Maintainer: Debian Nginx Maintainers <pkg-nginx-maintainers@alioth-lists.debian.net>
Architecture: amd64
Depends: nginx-common (= 1.22.1-9), libc6 (>= 2.34), libcrypt1 (>= 1:4.1.0)

$ apt-cache depends nginx-light
nginx-light
  Depends: nginx-common
  Depends: libc6
  Depends: libcrypt1
  Depends: libpcre2-8-0
  Depends: libssl3
  Depends: zlib1g
  Recommends: nginx-doc
  Conflicts: nginx-core
  Conflicts: nginx-extras
  Conflicts: nginx-full
  Replaces: nginx-core

$ apt-cache rdepends --installed libssl3 | head -8
libssl3
Reverse Depends:
  openssh-server
  openssh-client
  curl
  wget
  python3.11
  systemd

$ apt-cache madison openssl
    openssl | 3.0.11-1~deb12u2 | http://security.debian.org/debian-security bookworm-security/main amd64 Packages
    openssl |    3.0.9-1 | http://deb.debian.org/debian bookworm/main amd64 Packages
    openssl |    3.0.9-1 | http://deb.debian.org/debian bookworm/main Sources

$ apt-cache stats
Total package names: 63871 (1,277 k)
Total package structures: 63871 (3,576 k)
  Normal packages: 49417
  Pure virtual packages: 663
  Single virtual packages: 4991
  Mixed virtual packages: 480

$ apt-cache showpkg nginx-light | head -12
Package: nginx-light
Versions:
1.22.1-9 (/var/lib/apt/lists/deb.debian.org_debian_dists_bookworm_main_binary-amd64_Packages)
 Description Language:
                 File: /var/lib/apt/lists/deb.debian.org_debian_dists_bookworm_main_binary-amd64_Packages
                  MD5: 9b47c0f83e3a4e79b1c1f4a89e2d3b12

Reverse Depends:
  nginx,nginx-light
Dependencies:
1.22.1-9 - nginx-common (5 1.22.1-9) libc6 (2 2.34) libcrypt1 (2 1:4.1.0)
```

| Consulta | `apt-cache` (seguro para scripts) | `apt` (interactivo) |
|---|---|---|
| Metadatos completos | `apt-cache show pkg` | `apt show pkg` |
| Buscar nombres + descripciones | `apt-cache search regex` | `apt search regex` |
| Buscar sólo nombres | `apt-cache search --names-only regex` | `apt search --names-only regex` |
| Dependencias directas | `apt-cache depends pkg` | `apt depends pkg` |
| Dependencias inversas | `apt-cache rdepends pkg` | `apt rdepends pkg` |
| Qué versiones, desde dónde | `apt-cache policy pkg` | `apt policy pkg` |
| Matriz versión/suite | `apt-cache madison pkg` | — |
| Lista de instalados | `dpkg-query -W` | `apt list --installed` |
| Actualizaciones pendientes | — | `apt list --upgradable` |
| Estadísticas de caché | `apt-cache stats` | — |
| Dependencias insatisfacibles en la caché | `apt-cache unmet` | — |

```console
$ apt list --upgradable
Listing... Done
libssl3/bookworm-security 3.0.11-1~deb12u2 amd64 [upgradable from: 3.0.9-1]
openssl/bookworm-security 3.0.11-1~deb12u2 amd64 [upgradable from: 3.0.9-1]
```

### 4.6 Pinning: `/etc/apt/preferences.d/`

El pinning es la capa declarativa de política. Cada versión candidata recibe una prioridad; APT instala la más alta.

| Prioridad | Efecto |
|---|---|
| `P >= 1000` | Instala incluso si es una **degradación** |
| `990 ≤ P < 1000` | Instala incluso desde una release no objetivo, salvo que la versión instalada sea más nueva |
| `500 ≤ P < 990` | Instala salvo que exista una versión de la release objetivo, o la instalada sea más nueva |
| `100 ≤ P < 500` | Instala salvo que exista una versión de otra distribución, o la instalada sea más nueva |
| `0 < P < 100` | Instala sólo si el paquete no está instalado en absoluto |
| `P <= 0` | **Nunca instalar** esta versión |

Valores por defecto: 100 para la versión instalada, 500 para cualquier otra disponible, 1 para archivos marcados `NotAutomatic` (p. ej. `experimental`, `*-backports`), 100 para `NotAutomatic` + `ButAutomaticUpgrades` (p. ej. `*-updates`).

**Conjunto de preferencias completo y de nivel producción** — tres archivos separados, porque las entradas de `preferences.d` son más baratas de razonar que un monolito:

```console
$ cat /etc/apt/preferences.d/10-security-priority
# Security updates always win, even over a locally-pinned vendor archive.
Package: *
Pin: release o=Debian,a=stable-security
Pin-Priority: 990

$ cat /etc/apt/preferences.d/20-vendor-archive
# The vendor archive may ONLY provide its own packages. Without this,
# a compromised or careless vendor mirror could shadow libc6 or openssl.
Package: *
Pin: origin download.example.com
Pin-Priority: -1

Package: vendor-agent vendor-agent-plugins vendor-cli
Pin: origin download.example.com
Pin-Priority: 700

$ cat /etc/apt/preferences.d/30-backports-optin
# Backports stay opt-in via `apt-get -t bookworm-backports install`,
# EXCEPT the kernel metapackage, which we want tracking backports.
Package: *
Pin: release a=bookworm-backports
Pin-Priority: 100

Package: linux-image-amd64 linux-headers-amd64 firmware-linux-free
Pin: release a=bookworm-backports
Pin-Priority: 550
```

Selectores de pin: `a=` archivo/suite, `n=` nombre en clave, `v=` versión, `c=` componente, `o=` origen, `l=` etiqueta, `b=` arquitectura. `Pin: version 1.22.*` coincide por glob; `Pin: origin ""` coincide con archivos locales.

Verificá siempre un pin — un error de tipeo produce silencio, no un error:

```console
$ apt-cache policy vendor-agent
vendor-agent:
  Installed: 4.2.0
  Candidate: 4.3.1
  Version table:
     4.3.1 700
        700 https://download.example.com/debian bookworm/main amd64 Packages
 *** 4.2.0 100
        100 /var/lib/dpkg/status

$ apt-cache policy libssl3
libssl3:
  Installed: 3.0.11-1~deb12u2
  Candidate: 3.0.11-1~deb12u2
  Version table:
 *** 3.0.11-1~deb12u2 990
        990 http://security.debian.org/debian-security bookworm-security/main amd64 Packages
        100 /var/lib/dpkg/status
        500 http://deb.debian.org/debian bookworm/main amd64 Packages
     -1 3.0.9-2~vendor1 
        -1 https://download.example.com/debian bookworm/main amd64 Packages
```

Ese último bloque es el ataque de sombreado del proveedor neutralizado: el `libssl3` del proveedor está presente en el índice pero fijado a `-1` y nunca puede instalarse.

### 4.7 `apt.conf` — comportamiento en ejecución

```console
$ apt-config dump | grep -E '^(APT::Install-Recommends|Acquire::Retries|Dir::Cache)'
APT::Install-Recommends "0";
Acquire::Retries "3";
Dir::Cache "var/cache/apt/";
```

Una configuración completa y con criterio para hosts detrás de un enlace inestable y un proxy de caché:

```console
$ cat /etc/apt/apt.conf.d/00aptitude-platform
// Network resilience — a transient DNS blip must not fail a whole rollout.
Acquire::Retries "5";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
Acquire::ForceIPv4 "false";

// Route through the on-prem caching proxy; bypass it for the internal archive.
Acquire::http::Proxy "http://apt-cache.example.internal:3142";
Acquire::http::Proxy::apt.example.internal "DIRECT";

// Fetch indices by content hash: immune to a mirror rotating mid-download.
Acquire::By-Hash "yes";

// Non-interactive defaults.
APT::Get::Assume-Yes "false";       // leave explicit -y to the caller
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Dpkg::Use-Pty "false";              // clean, line-buffered logs in CI

// Keep the cache bounded on nodes with small root volumes.
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "7";
```

Logs escritos por APT, y qué responde cada uno:

| Archivo | Responde |
|---|---|
| `/var/log/apt/history.log` | *Qué* transacciones corrieron, cuándo, con qué línea de comandos, solicitadas por qué usuario |
| `/var/log/apt/term.log` | La salida completa de terminal de dpkg durante esas transacciones |
| `/var/log/dpkg.log` | Transiciones de estado por paquete con marcas de tiempo |
| `/var/log/unattended-upgrades/` | Decisiones y resultados de actualizaciones automáticas |

```console
$ tail -12 /var/log/apt/history.log
Start-Date: 2026-08-24  03:17:02
Commandline: /usr/bin/unattended-upgrade
Upgrade: libssl3:amd64 (3.0.9-1, 3.0.11-1~deb12u2), openssl:amd64 (3.0.9-1, 3.0.11-1~deb12u2)
End-Date: 2026-08-24  03:17:19

$ grep ' status installed openssh-server' /var/log/dpkg.log
2026-08-19 04:12:44 status installed openssh-server:amd64 1:9.2p1-2+deb12u3
```

---

## 5. Encontrar qué paquete posee — o poseería — un archivo

Esto es un tercio del objetivo y la habilidad más útil en respuesta a incidentes. Hay **dos preguntas diferentes** y necesitan dos herramientas diferentes.

| Pregunta | Herramienta | Requiere | Alcance |
|---|---|---|---|
| ¿Qué paquete **instalado** posee `/usr/sbin/sshd`? | `dpkg -S` | Nada | Sólo paquetes instalados; sólo archivos entregados en `data.tar` |
| ¿Qué paquete **proveería** `/usr/bin/dig`, instalado o no? | `apt-file search` | `apt-file` + `apt-file update` | Todo el archivo, vía `Contents-<arch>.gz` |

```console
$ dpkg -S /usr/sbin/sshd
openssh-server: /usr/sbin/sshd

$ dpkg -S /usr/bin/dig
dpkg-query: no path found matching pattern /usr/bin/dig

$ sudo apt-get install -y apt-file && sudo apt-file update
$ apt-file search /usr/bin/dig
dnsutils: /usr/bin/dig
bind9-dnsutils: /usr/bin/dig

$ sudo apt-get install -y bind9-dnsutils
$ dpkg -S /usr/bin/dig
bind9-dnsutils: /usr/bin/dig
```

`dpkg -S` acepta una subcadena/glob, no sólo una ruta exacta, lo que es a la vez conveniente y una fuente de ruido:

```console
$ dpkg -S nginx.conf
nginx-common: /etc/nginx/nginx.conf
nginx-common: /usr/share/nginx/conf/nginx.conf

$ dpkg -S '*/libssl.so.3'
libssl3:amd64: /usr/lib/x86_64-linux-gnu/libssl.so.3
```

**Los cuatro casos en que `dpkg -S` legítimamente no encuentra nada** — reconocer en cuál estás *es* el diagnóstico:

1. **El archivo no viene de un paquete en absoluto.** Alguien lo instaló a mano. Esto es estado no rastreado; debe empaquetarse o eliminarse.
2. **El archivo se creó en tiempo de ejecución**, por un script del mantenedor, una unidad systemd, o la propia aplicación. `/etc/ssh/ssh_host_ed25519_key` lo genera el `postinst` de `openssh-server`, así que no tiene dueño.
3. **La ruta es un symlink resuelto de otra manera.** Con usr-merge, `/bin/ls` y `/usr/bin/ls` refieren al mismo inodo pero el `.list` registra sólo uno. Usá `dpkg -S "$(readlink -f /bin/ls)"`.
4. **El paquete no está instalado.** Usá `apt-file`.

```console
$ dpkg -S /etc/ssh/ssh_host_ed25519_key
dpkg-query: no path found matching pattern /etc/ssh/ssh_host_ed25519_key
$ dpkg -S /bin/ls
dpkg-query: no path found matching pattern /bin/ls
$ dpkg -S "$(readlink -f /bin/ls)"
coreutils: /usr/bin/ls
```

**Encontrar el paquete detrás de una biblioteca compartida faltante** — el triage clásico de "error while loading shared libraries":

```console
$ ./vendor-binary
./vendor-binary: error while loading shared libraries: libpcre2-8.so.0: cannot open shared object file: No such file or directory

$ ldd ./vendor-binary | grep 'not found'
	libpcre2-8.so.0 => not found

$ apt-file search --regexp '/libpcre2-8\.so\.0$'
libpcre2-8-0: /usr/lib/x86_64-linux-gnu/libpcre2-8.so.0

$ sudo apt-get install -y libpcre2-8-0
$ ldd ./vendor-binary | grep pcre2
	libpcre2-8.so.0 => /usr/lib/x86_64-linux-gnu/libpcre2-8.so.0 (0x00007f3a9c1f2000)
```

**El barrido de auditoría completo** — enumerar cada ejecutable sin dueño en un host. Corré esto en cualquier máquina antes de declararla "bajo gestión de configuración":

```console
$ for f in $(find /usr/local/bin /usr/bin /usr/sbin -maxdepth 1 -type f -perm -u+x 2>/dev/null); do
    dpkg -S "$f" >/dev/null 2>&1 || echo "UNOWNED: $f"
  done
UNOWNED: /usr/local/bin/deploy.sh
UNOWNED: /usr/local/bin/kubectl
UNOWNED: /usr/bin/vendor-agent-shim
```

Otros modos de `apt-file`:

```console
$ apt-file list bind9-dnsutils | head -5
bind9-dnsutils: /usr/bin/delv
bind9-dnsutils: /usr/bin/dig
bind9-dnsutils: /usr/bin/mdig
bind9-dnsutils: /usr/bin/nslookup
bind9-dnsutils: /usr/bin/nsupdate

$ apt-file search --package-only ldconfig
libc-bin
```

---

## 6. Verificación de integridad

Tres capas de garantía, con costo y cobertura crecientes:

| Nivel | Herramienta | Qué prueba | Costo | Punto ciego |
|---|---|---|---|---|
| Transporte | Verificación OpenPGP de `apt-get update` | El índice (y por lo tanto el hash de cada `.deb`) vino del poseedor de la clave | Gratis | Clave de firma comprometida |
| Artefacto | SHA256 de `Packages` vs el `.deb` descargado | El archivo en disco es idéntico bit a bit a lo que publicó el archivo | Gratis, automático | Un artefacto que era malicioso desde upstream |
| Post-instalación | `dpkg -V` / `debsums` | Los archivos en disco siguen coincidiendo con las sumas MD5 entregadas | Segundos a minutos | Archivos sin suma registrada; conffiles (editados legítimamente) |

```console
$ dpkg -V openssh-server
??5?????? c /etc/ssh/sshd_config

$ dpkg -V coreutils
$ echo $?
0

$ sudo dpkg -V
??5?????? c /etc/ssh/sshd_config
??5?????? c /etc/sysctl.conf
missing     /usr/share/doc/vendor-agent/changelog.gz
??5??????   /usr/sbin/nginx
```

La máscara de 9 caracteres refleja el formato de RPM; dpkg actualmente sólo implementa la verificación MD5, así que en la práctica se lee la columna 3:

| Posición | Significado |
|---|---|
| 3 | `5` — la suma MD5 difiere |
| cualquiera | `?` — no verificado / no verificable |
| letra final | `c` — el archivo es un **conffile** (una diferencia acá es esperable y normal) |

La línea que debe disparar una investigación es `??5??????` **sin** una `c` — un binario o biblioteca modificado, es decir un archivo que sólo un intruso o una instalación fuera de banda pudo haber cambiado. `/usr/sbin/nginx` en la salida de arriba es exactamente ese caso.

`debsums` cubre más terreno, incluyendo detectar archivos *faltantes* y verificar contra archivos recién descargados:

```console
$ sudo apt-get install -y debsums

$ sudo debsums -c                       # print only files that FAILED
/usr/sbin/nginx
debsums: checksum mismatch nginx-light file /usr/sbin/nginx

$ sudo debsums -s                       # silent except errors — ideal for cron/monitoring
debsums: no md5sums for vendor-agent

$ sudo debsums -ca                      # include conffiles in the check
/etc/ssh/sshd_config
/usr/sbin/nginx

$ sudo debsums -l                       # packages that ship NO md5sums at all
vendor-agent
```

La salida de `debsums -l` es un hallazgo de seguridad por derecho propio: un paquete sin archivo `md5sums` nunca puede verificarse. Los `.deb` de terceros construidos con `fpm` caen frecuentemente acá. Exigí `md5sums` en tus criterios de aceptación de paquetes de proveedores.

**Restaurar un archivo manipulado a su estado empaquetado** — una reinstalación reescribe la carga útil sin tocar los conffiles modificados:

```console
$ sudo apt-get install --reinstall nginx-light
Reading package lists... Done
Building dependency tree... Done
0 upgraded, 0 newly installed, 1 reinstalled, 0 to remove and 0 not upgraded.
Need to get 509 kB of archives.
After this operation, 0 B of additional disk space will be used.
Get:1 http://deb.debian.org/debian bookworm/main amd64 nginx-light amd64 1.22.1-9 [509 kB]
Fetched 509 kB in 0s (2,884 kB/s)
(Reading database ... 41287 files and directories currently installed.)
Preparing to unpack .../nginx-light_1.22.1-9_amd64.deb ...
Unpacking nginx-light (1.22.1-9) over (1.22.1-9) ...
Setting up nginx-light (1.22.1-9) ...

$ dpkg -V nginx-light
$ echo $?
0
```

**Contrastar contra el propio archivo** — verificar que un `.deb` que te entregaron coincide con lo que publicó el archivo:

```console
$ apt-cache show nginx-light | grep -E '^(SHA256|Filename|Size)'
Filename: pool/main/n/nginx/nginx-light_1.22.1-9_amd64.deb
Size: 508984
SHA256: 4f8a2b91c73de5a0189f2c4b6e7d3a9c05f18b2e6d4a7c93f0b1e8d25a6c4739

$ sha256sum nginx-light_1.22.1-9_amd64.deb
4f8a2b91c73de5a0189f2c4b6e7d3a9c05f18b2e6d4a7c93f0b1e8d25a6c4739  nginx-light_1.22.1-9_amd64.deb
```

---

## 7. Diagnóstico de fallas: el runbook

### 7.1 Orden de triage

Ejecutá estos cuatro comandos, en este orden, antes de cambiar nada. Son todos de sólo lectura.

```console
$ sudo dpkg -C
$ sudo apt-get check
$ apt-cache policy
$ sudo lsof /var/lib/dpkg/lock-frontend 2>/dev/null
```

### 7.2 El bloqueo

```console
$ sudo apt-get install nginx
E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 3421 (unattended-upgr)
E: Unable to acquire the dpkg frontend lock (/var/lib/dpkg/lock-frontend), is another process using it?
```

| Archivo de bloqueo | Retenido por |
|---|---|
| `/var/lib/dpkg/lock-frontend` | Cualquier front end que sostenga una transacción *visible al usuario* (apt, aptitude, unattended-upgrades) |
| `/var/lib/dpkg/lock` | dpkg mismo, durante el desempaquetado/configuración real |
| `/var/lib/apt/lists/lock` | `apt-get update` |
| `/var/cache/apt/archives/lock` | Descargas de paquetes |

```console
$ sudo lsof /var/lib/dpkg/lock-frontend
COMMAND     PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
unattended 3421 root    4uW  REG  254,1        0  262 /var/lib/dpkg/lock-frontend

$ systemctl list-units --type=service --state=running | grep -Ei 'apt|unattended'
  apt-daily-upgrade.service   loaded active running   Daily apt upgrade and clean activities
```

**Esperá.** Borrar el bloqueo mientras dpkg está a mitad de una transacción produce una base de datos `status` genuinamente corrupta. Si tenés que serializar alrededor de él — el patrón correcto para CI y gestión de configuración:

```console
$ sudo systemd-run --property=After=apt-daily.service --wait --pipe \
    apt-get -y install nginx-light
```

O, en un script de aprovisionamiento:

```bash
#!/bin/bash
set -euo pipefail
for i in $(seq 1 60); do
  if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    break
  fi
  echo "waiting for dpkg frontend lock (${i}/60)"
  sleep 5
done
DEBIAN_FRONTEND=noninteractive apt-get -y install "$@"
```

En imágenes de nube la solución estándar es deshabilitar los timers por completo antes de aprovisionar:

```console
$ sudo systemctl disable --now apt-daily.timer apt-daily-upgrade.timer
```

### 7.3 Transacción interrumpida: `iU`, `iF`, `iH`

```console
$ sudo dpkg -C
The following packages are in a mess due to serious problems during
installation.  They must be reinstalled for them (and any packages
that depend on them) to function properly:
 vendor-agent   Vendor observability agent

The following packages are only half configured, probably due to problems
configuring them the first time.  The configuration should be retried using
dpkg --configure <package> or the configure menu option in dselect:
 nginx-core     nginx web/proxy server (standard version)
```

La escalera de escalamiento, de menos destructivo a más:

```console
# 1. Finish what was interrupted
$ sudo dpkg --configure -a

# 2. Let APT repair unmet dependencies
$ sudo apt-get -f install
$ sudo apt-get check

# 3. Force a clean re-unpack of the specific package
$ sudo apt-get install --reinstall vendor-agent

# 4. Package in state iR that dpkg refuses to remove
$ sudo dpkg --remove --force-remove-reinstreq vendor-agent

# 5. Failing postrm blocking removal — neutralise it, then purge
$ sudo ls -l /var/lib/dpkg/info/vendor-agent.*
$ sudo mv /var/lib/dpkg/info/vendor-agent.postrm /root/vendor-agent.postrm.bak
$ sudo dpkg --purge vendor-agent
```

El paso 5 es un último recurso genuino y *es* una desviación del modelo transaccional: le estás mintiendo a dpkg sobre que el paquete se limpió a sí mismo. Registralo en el ticket de cambio y verificá manualmente que los archivos, usuarios y unidades systemd del paquete hayan desaparecido.

**Opciones de forzado — la tabla de compromisos.** Cada una de estas compra progreso a cambio de una pérdida de garantía:

| Opción | Compra | Cuesta |
|---|---|---|
| `--force-confdef,confold,confnew` | Actualizaciones no interactivas | Una decisión de configuración tomada sin revisión |
| `--force-overwrite` | Instala pasando por encima de un conflicto de archivos | Dos paquetes reclaman ahora una ruta; eliminar cualquiera rompe al otro |
| `--force-depends` | Configura con dependencias insatisfechas | El paquete puede no ejecutarse en absoluto |
| `--force-remove-reinstreq` | Elimina un paquete en `iR` | Su limpieza `prerm`/`postrm` nunca corrió |
| `--force-remove-essential` | Elimina un paquete `Essential: yes` | Puede dejar el sistema no arrancable — efectivamente nunca es correcto |
| `--force-all` | Todo lo de arriba | No lo uses. Enumerá los forzados específicos que necesitás |

```console
$ dpkg --force-help | head -20
dpkg forcing options - control behaviour when problems found:
  warn but continue:  --force-<thing>,<thing>,...
  stop with error:    --refuse-<thing>,<thing>,... | --no-force-<thing>,...
 Forcing things:
  [!] all                    Set all force options
  [*] downgrade              Replace a package with a lower version
      configure-any          Configure any package which may help this one
      hold                   Process even when marked "hold"
      remove-reinstreq       Remove package which requires installation
  [!] remove-essential       Remove an essential package
      depends                Turn all dependency problems into warnings
      depends-version        Turn dependency version problems into warnings
      confnew                Always use the new config files, don't prompt
      confold                Always use the old config files, don't prompt
      confdef                Use the default option for new config files
```

### 7.4 Fallas de índice y firma

**`Release` expirado** — la falla arquetípica del contenedor obsoleto:

```console
$ sudo apt-get update
E: Release file for http://deb.debian.org/debian/dists/bookworm/InRelease is not valid yet (invalid for another 2d 4h 11min 6s). Updates for this repository will not be applied.
```

"Not valid **yet**" significa que el *reloj está mal*, no el archivo. Arreglá el reloj, nunca la verificación:

```console
$ timedatectl
               Local time: Sat 2026-08-22 09:14:03 UTC
           Universal time: Sat 2026-08-22 09:14:03 UTC
                System clock synchronized: no
              NTP service: inactive
$ sudo timedatectl set-ntp true && sleep 5 && timedatectl | grep synchronized
                System clock synchronized: yes
```

El mensaje opuesto — `Release file … is not valid anymore (invalid since …)` — significa que el *mirror* está obsoleto, o que estás corriendo una suite genuinamente archivada. Para una release archivada la respuesta correcta es `snapshot.debian.org` o `archive.debian.org`, no `Acquire::Check-Valid-Until "false"`.

**Clave faltante:**

```console
$ sudo apt-get update
Get:2 https://download.example.com/debian bookworm InRelease [3,182 B]
Err:2 https://download.example.com/debian bookworm InRelease
  The following signatures couldn't be verified because the public key is not available: NO_PUBKEY 648ACFD622F3D138
Reading package lists... Done
W: GPG error: https://download.example.com/debian bookworm InRelease: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY 648ACFD622F3D138
E: The repository 'https://download.example.com/debian bookworm InRelease' is not signed.
N: Updating from such a repository can't be done securely, and is therefore disabled by default.
```

Se arregla instalando la clave con `Signed-By` (§4.3) después de verificar la huella digital fuera de banda. **No** agregues `[trusted=yes]`.

**404 en el índice** — casi siempre una suite equivocada o un componente que no existe para esa suite:

```console
$ sudo apt-get update
Err:3 https://download.example.com/debian bookwrom Release
  404  Not Found [IP: 203.0.113.10 443]
E: The repository 'https://download.example.com/debian bookwrom Release' does not have a Release file.
```

Confirmá la disposición real del archivo antes de editar nada:

```console
$ curl -sSI https://download.example.com/debian/dists/bookworm/InRelease | head -1
HTTP/1.1 200 OK
$ curl -sS https://download.example.com/debian/dists/bookworm/Release | grep -E '^(Suite|Codename|Components|Architectures):'
Suite: stable
Codename: bookworm
Components: main
Architectures: amd64 arm64
```

**Hash sum mismatch** — una descarga truncada, un proxy de caché sirviendo un índice obsoleto, o un mirror rotando a mitad de sincronización:

```console
$ sudo apt-get update
E: Failed to fetch http://deb.debian.org/debian/dists/bookworm/main/binary-amd64/Packages.xz
   Hash Sum mismatch
   Hashes of expected file:
    - SHA256:9c2b4f...
   Hashes of received file:
    - SHA256:e7a013...

$ sudo rm -rf /var/lib/apt/lists/*
$ sudo apt-get update
```

Si se repite, el proxy es el sospechoso — poné `Acquire::By-Hash "yes"` y/o evitá el proxy para ese host.

### 7.5 Conjuntos de dependencias insatisfacibles

```console
$ sudo apt-get install vendor-agent
The following packages have unmet dependencies:
 vendor-agent : Depends: libssl1.1 (>= 1.1.0) but it is not installable
E: Unable to correct problems, you have held broken packages.
```

Dos causas raíz distintas, distinguidas por un solo comando:

```console
$ apt-cache policy libssl1.1
libssl1.1:
  Installed: (none)
  Candidate: (none)
  Version table:
```

Tabla de versiones vacía ⇒ el paquete **no existe en ninguna suite configurada**. `libssl1.1` era Debian 11; el `.deb` del proveedor se construyó para `bullseye` y simplemente es el artefacto equivocado para `bookworm`. La solución es un paquete correctamente construido, no forzar la instalación cruzando el límite de ABI.

Si en cambio existe un candidato pero está bloqueado por pinning:

```console
$ apt-cache policy libssl1.1
libssl1.1:
  Installed: (none)
  Candidate: (none)
  Version table:
     1.1.1w-0+deb11u1 -1
        -1 https://download.example.com/debian bookworm/main amd64 Packages
```

Candidato `(none)` con una entrada `-1` ⇒ tu propia regla de pinning lo está bloqueando (§4.6). Eso es la política funcionando según lo diseñado; cambiá la política conscientemente o rechazá el paquete.

Hacé que APT explique su razonamiento:

```console
$ sudo apt-get -s -o Debug::pkgProblemResolver=true install vendor-agent 2>&1 | head -20
$ aptitude why-not vendor-agent
Unable to find a reason to remove vendor-agent.
$ apt-get -s install vendor-agent          # -s = simulate, changes nothing
```

`apt-get -s` (`--simulate` / `--dry-run`) es el primer paso obligatorio para cualquier cambio en un host de producción. Imprime el plan exacto sin tocar el sistema de archivos.

### 7.6 Conflictos de archivos entre paquetes

```console
$ sudo apt-get install vendor-cli
Unpacking vendor-cli (2.1.0) ...
dpkg: error processing archive /var/cache/apt/archives/vendor-cli_2.1.0_amd64.deb (--unpack):
 trying to overwrite '/usr/bin/kubectl', which is also in package kubectl 1.29.4-1
Errors were encountered while processing:
 /var/cache/apt/archives/vendor-cli_2.1.0_amd64.deb
E: Sub-process /usr/bin/dpkg returned an error code (1)
```

El bug de empaquetado es que `vendor-cli` no declara `Conflicts`/`Replaces` para `kubectl`. Resoluciones correctas, en orden de preferencia:

1. Eliminar el paquete en conflicto: `sudo apt-get remove kubectl`.
2. Usar `dpkg-divert` para reubicar el archivo existente, preservando ambos paquetes:

```console
$ sudo dpkg-divert --add --rename --divert /usr/bin/kubectl.distrib /usr/bin/kubectl
Adding 'local diversion of /usr/bin/kubectl to /usr/bin/kubectl.distrib'
$ sudo apt-get install vendor-cli
$ dpkg-divert --list
local diversion of /usr/bin/kubectl to /usr/bin/kubectl.distrib
```

3. `--force-overwrite` — último recurso, y deja el sistema con dos paquetes reclamando una ruta:

```console
$ sudo apt-get -o Dpkg::Options::="--force-overwrite" install vendor-cli
```

### 7.7 Agotamiento de disco a mitad de transacción

```console
$ sudo apt-get -y dist-upgrade
dpkg: unrecoverable fatal error, aborting:
 unable to write to '/var/lib/dpkg/status': No space left on device
E: Sub-process /usr/bin/dpkg returned an error code (2)
```

Secuencia de recuperación — recuperar espacio, luego completar la transacción interrumpida:

```console
$ df -h /var /
Filesystem      Size  Used Avail Use% Mounted on
/dev/vda2        20G   20G     0 100% /

$ sudo apt-get clean                                    # /var/cache/apt/archives
$ sudo journalctl --vacuum-size=200M
Vacuuming done, freed 3.1G of archived journals.
$ dpkg -l 'linux-image-*' | awk '/^ii/ {print $2}'
linux-image-6.1.0-16-amd64
linux-image-6.1.0-17-amd64
linux-image-6.1.0-18-amd64
linux-image-amd64
$ sudo apt-get purge linux-image-6.1.0-16-amd64         # never the running one
$ uname -r
6.1.0-18-amd64

$ sudo dpkg --configure -a
$ sudo apt-get -f install
$ sudo dpkg -C && echo "clean"
clean
```

Si el propio `/var/lib/dpkg/status` quedó truncado:

```console
$ sudo cp -a /var/lib/dpkg/status /root/status.broken
$ sudo cp -a /var/lib/dpkg/status-old /var/lib/dpkg/status
$ ls -la /var/backups/dpkg.status*
-rw-r--r-- 1 root root 1893214 Aug 24 06:25 /var/backups/dpkg.status.0
-rw-r--r-- 1 root root  312884 Aug 17 06:25 /var/backups/dpkg.status.1.gz
$ sudo dpkg --audit
```

### 7.8 Tabla de decisión diagnóstica

| Síntoma | Capa | Primer comando | Causa probable |
|---|---|---|---|
| `Could not get lock` | 2 | `lsof /var/lib/dpkg/lock-frontend` | `apt-daily.timer` / otro operador |
| `dependency problems - leaving unconfigured` | 1 | `apt-get -f install` | Se usó `dpkg -i` sin resolver dependencias |
| El paquete muestra `iU`/`iF`/`iH` | 1 | `dpkg --configure -a` | Transacción interrumpida, `postinst` fallido |
| `NO_PUBKEY` / `is not signed` | 2 | `apt-cache policy` + revisar `Signed-By` | Clave del repositorio faltante/rotada |
| `not valid yet` | Host | `timedatectl` | Reloj del sistema equivocado |
| `not valid anymore` | 2 | `curl .../Release \| grep Date` | Mirror obsoleto o suite archivada |
| `404 … does not have a Release file` | 2 | `curl -I .../dists/<suite>/InRelease` | Error de tipeo en suite/componente, o suite retirada |
| `Hash Sum mismatch` | 2 | `rm -rf /var/lib/apt/lists/*` | Descarga truncada o proxy de caché obsoleto |
| `held broken packages` | 2 | `apt-cache policy <dep>` | Artefacto de release equivocada, o un pin |
| `trying to overwrite … also in package` | 1 | `dpkg -S <path>` | Falta `Conflicts`/`Replaces` en el empaquetado |
| `kept back` en la actualización | 2 | `apt-get -s dist-upgrade` | Se requiere una dependencia nueva; `upgrade` no agrega paquetes |
| La actualización se cuelga sin salida | 1 | `ps -ef \| grep -E 'dpkg\|debconf'` | Prompt de conffile o debconf esperando entrada |
| `dpkg -V` muestra `??5??????` sin `c` | 6 | `apt-get install --reinstall` | Manipulación o instalación fuera de banda |
| El archivo existe pero `dpkg -S` no encuentra nada | — | `apt-file search` | Estado no rastreado, o archivo generado en tiempo de ejecución |

---

## 8. Manifiestos de infraestructura

### 8.1 `cloud-init` — primer arranque determinista

```yaml
#cloud-config
# /var/lib/cloud/seed/nocloud/user-data
# Provisions APT before ANY package operation: sources, keys, pinning, policy.

apt:
  preserve_sources_list: false
  primary:
    - arches: [default]
      uri: http://deb.debian.org/debian
  security:
    - arches: [default]
      uri: http://security.debian.org/debian-security
  # Route all fetches through the on-prem cache to survive an upstream outage.
  http_proxy: http://apt-cache.example.internal:3142
  conf: |
    Acquire::Retries "5";
    Acquire::http::Timeout "30";
    Acquire::By-Hash "yes";
    APT::Install-Recommends "false";
    APT::Install-Suggests "false";
    Dpkg::Options {
       "--force-confdef";
       "--force-confold";
    };
  sources:
    example-internal.sources:
      source: |
        Types: deb
        URIs: https://apt.example.internal/debian
        Suites: bookworm
        Components: main platform
        Architectures: amd64
      # Inline key: no bootstrap ordering problem, no extra file to ship.
      key: |
        -----BEGIN PGP PUBLIC KEY BLOCK-----

        mQINBGXFqZ0BEADQ8k2Vw3nJ7yTt0oQ9L1x4mZ8bR2cH5vN6dK1jP0wE3sA7fY9u
        REPLACE_WITH_THE_REAL_ARMORED_PUBLIC_KEY_OF_YOUR_ARCHIVE
        =AbCd
        -----END PGP PUBLIC KEY BLOCK-----

write_files:
  - path: /etc/apt/preferences.d/10-security-priority
    owner: root:root
    permissions: '0644'
    content: |
      Package: *
      Pin: release o=Debian,a=stable-security
      Pin-Priority: 990

  - path: /etc/apt/preferences.d/20-internal-archive
    owner: root:root
    permissions: '0644'
    content: |
      # The internal archive may ONLY supply platform packages.
      Package: *
      Pin: origin apt.example.internal
      Pin-Priority: -1

      Package: platform-agent platform-cli platform-node-exporter
      Pin: origin apt.example.internal
      Pin-Priority: 700

  - path: /etc/apt/apt.conf.d/20auto-upgrades
    owner: root:root
    permissions: '0644'
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";
      APT::Periodic::AutocleanInterval "7";

  - path: /etc/apt/apt.conf.d/52unattended-upgrades-local
    owner: root:root
    permissions: '0644'
    content: |
      Unattended-Upgrade::Origins-Pattern {
              "origin=Debian,codename=${distro_codename},label=Debian-Security";
              "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
      };
      Unattended-Upgrade::Package-Blacklist {
              "^linux-image-";
              "^linux-headers-";
      };
      Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";
      Unattended-Upgrade::Automatic-Reboot "false";
      Unattended-Upgrade::MailReport "on-change";
      Unattended-Upgrade::Mail "platform-alerts@example.internal";
      Unattended-Upgrade::SyslogEnable "true";

package_update: true
package_upgrade: false

packages:
  - apt-file
  - ca-certificates
  - curl
  - debsums
  - gnupg
  - needrestart
  - unattended-upgrades
  - platform-agent

runcmd:
  # Provisioning must not race the daily timers.
  - [systemctl, disable, --now, apt-daily.timer, apt-daily-upgrade.timer]
  - [apt-file, update]
  # Prove the pinning actually took effect; fail the boot loudly if it did not.
  - |
    set -e
    if apt-cache policy libssl3 | grep -qE '^\s+700 https://apt\.example\.internal'; then
      echo "FATAL: internal archive is shadowing a base package" >&2
      exit 1
    fi
  - [systemctl, enable, --now, apt-daily.timer, apt-daily-upgrade.timer]

final_message: "APT control plane provisioned after $UPTIME seconds"
```

### 8.2 Ansible — convergiendo el estado de APT en una flota existente

```yaml
---
# playbooks/apt-baseline.yml
# Converges the APT control plane. Idempotent; safe to run on every schedule.
- name: Converge Debian package-management baseline
  hosts: debian_fleet
  become: true
  gather_facts: true

  vars:
    internal_archive_url: "https://apt.example.internal/debian"
    internal_archive_key_url: "https://apt.example.internal/keys/platform.asc"
    internal_archive_fingerprint: "A1B2C3D4E5F6071829394A5B6C7D8E9FA0B1C2D3"
    platform_packages:
      - platform-agent
      - platform-cli
      - platform-node-exporter
    held_packages:
      - openssh-server

  pre_tasks:
    - name: Fail fast on non-Debian hosts
      ansible.builtin.assert:
        that:
          - ansible_facts['os_family'] == 'Debian'
        fail_msg: "This playbook targets Debian-family hosts only."

  tasks:
    - name: Ensure prerequisite tooling is present
      ansible.builtin.apt:
        name:
          - apt-file
          - ca-certificates
          - debsums
          - gnupg
        state: present
        install_recommends: false
        update_cache: true
        cache_valid_time: 3600

    - name: Install the internal archive signing key into its own keyring
      ansible.builtin.get_url:
        url: "{{ internal_archive_key_url }}"
        dest: /etc/apt/keyrings/platform-archive.asc
        mode: "0644"
        owner: root
        group: root

    - name: Verify the key fingerprint before trusting it
      ansible.builtin.command:
        cmd: >-
          gpg --with-colons --import-options show-only --import
          /etc/apt/keyrings/platform-archive.asc
      register: key_show
      changed_when: false

    - name: Abort if the fingerprint does not match the expected value
      ansible.builtin.assert:
        that:
          - internal_archive_fingerprint in key_show.stdout
        fail_msg: >-
          Fingerprint mismatch on the internal archive key.
          Expected {{ internal_archive_fingerprint }}. Refusing to configure the repository.

    # ansible.builtin.deb822_repository requires ansible-core >= 2.15.
    - name: Configure the internal archive (deb822)
      ansible.builtin.deb822_repository:
        name: platform-internal
        types: [deb]
        uris: "{{ internal_archive_url }}"
        suites: "{{ ansible_facts['distribution_release'] }}"
        components: [main, platform]
        architectures: ["{{ ansible_facts['architecture'] | replace('x86_64', 'amd64') }}"]
        signed_by: /etc/apt/keyrings/platform-archive.asc
        enabled: true
        state: present
      notify: Refresh apt indices

    - name: Constrain the internal archive to platform packages only
      ansible.builtin.copy:
        dest: /etc/apt/preferences.d/20-internal-archive
        owner: root
        group: root
        mode: "0644"
        content: |
          # MANAGED BY ANSIBLE — manual edits will be reverted.
          Package: *
          Pin: origin apt.example.internal
          Pin-Priority: -1

          Package: {{ platform_packages | join(' ') }}
          Pin: origin apt.example.internal
          Pin-Priority: 700
      notify: Refresh apt indices

    - name: Enforce non-interactive conffile policy and no recommends
      ansible.builtin.copy:
        dest: /etc/apt/apt.conf.d/99platform
        owner: root
        group: root
        mode: "0644"
        content: |
          // MANAGED BY ANSIBLE
          APT::Install-Recommends "false";
          APT::Install-Suggests "false";
          Acquire::Retries "5";
          Dpkg::Options {
             "--force-confdef";
             "--force-confold";
          };
      notify: Refresh apt indices

    - name: Flush handlers so the cache is fresh before installing
      ansible.builtin.meta: flush_handlers

    - name: Install platform packages
      ansible.builtin.apt:
        name: "{{ platform_packages }}"
        state: present
        install_recommends: false

    - name: Apply security updates only
      ansible.builtin.apt:
        upgrade: safe          # maps to apt-get upgrade — never removes packages
        update_cache: true
        cache_valid_time: 3600
      register: apt_upgrade
      retries: 3
      delay: 30
      until: apt_upgrade is succeeded

    - name: Hold packages that must never move outside a change window
      ansible.builtin.dpkg_selections:
        name: "{{ item }}"
        selection: hold
      loop: "{{ held_packages }}"

    - name: Remove orphaned automatically-installed dependencies
      ansible.builtin.apt:
        autoremove: true
        purge: true

    - name: Detect files that no longer match their package checksums
      ansible.builtin.command:
        cmd: debsums -s
      register: debsums_result
      changed_when: false
      failed_when: false

    - name: Report integrity violations
      ansible.builtin.debug:
        msg: "INTEGRITY: {{ debsums_result.stderr_lines }}"
      when: debsums_result.stderr_lines | length > 0

    - name: Detect packages left in a broken dpkg state
      ansible.builtin.command:
        cmd: dpkg --audit
      register: dpkg_audit
      changed_when: false

    - name: Fail the run if any package is in a broken state
      ansible.builtin.assert:
        that:
          - dpkg_audit.stdout | trim | length == 0
        fail_msg: "Broken dpkg state on {{ inventory_hostname }}:\n{{ dpkg_audit.stdout }}"

  handlers:
    - name: Refresh apt indices
      ansible.builtin.apt:
        update_cache: true
```

### 8.3 Kubernetes — sincronización programada de mirror

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: apt-mirror
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: apt-mirror-data
  namespace: apt-mirror
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: fast-ssd
  resources:
    requests:
      storage: 400Gi
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: aptly-config
  namespace: apt-mirror
data:
  aptly.conf: |
    {
      "rootDir": "/srv/aptly",
      "downloadConcurrency": 8,
      "downloadSpeedLimit": 0,
      "downloadRetries": 3,
      "architectures": ["amd64", "arm64"],
      "dependencyFollowSuggests": false,
      "dependencyFollowRecommends": false,
      "dependencyFollowAllVariants": false,
      "dependencyFollowSource": false,
      "dependencyVerboseResolve": true,
      "gpgDisableSign": false,
      "gpgDisableVerify": false,
      "gpgProvider": "gpg",
      "skipLegacyPool": true,
      "ppaDistributorID": "debian",
      "FileSystemPublishEndpoints": {
        "internal": {
          "rootDir": "/srv/aptly/public",
          "linkMethod": "hardlink"
        }
      }
    }
  sync.sh: |
    #!/bin/bash
    # Mirror upstream Debian, snapshot it, and publish atomically.
    # A snapshot is immutable: rolling back a bad upstream push is a
    # switch back to the previous snapshot, not a re-download.
    set -euo pipefail

    SUITE="${SUITE:-bookworm}"
    STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
    export GNUPGHOME=/etc/aptly-gpg

    for M in "${SUITE}" "${SUITE}-security" "${SUITE}-updates"; do
      if ! aptly mirror show "${M}" >/dev/null 2>&1; then
        case "${M}" in
          *-security)
            aptly mirror create -architectures=amd64,arm64 \
              "${M}" http://security.debian.org/debian-security "${M}" main contrib ;;
          *)
            aptly mirror create -architectures=amd64,arm64 \
              "${M}" http://deb.debian.org/debian "${M}" main contrib ;;
        esac
      fi
      echo "==> updating mirror ${M}"
      aptly mirror update "${M}"
      aptly snapshot create "${M}-${STAMP}" from mirror "${M}"
    done

    aptly snapshot merge -latest "merged-${STAMP}" \
      "${SUITE}-${STAMP}" "${SUITE}-updates-${STAMP}" "${SUITE}-security-${STAMP}"

    if aptly publish list -raw | grep -q "^internal:. ${SUITE}\$"; then
      aptly publish switch -batch -passphrase-file=/etc/aptly-gpg/passphrase \
        "${SUITE}" "filesystem:internal:" "merged-${STAMP}"
    else
      aptly publish snapshot -batch -passphrase-file=/etc/aptly-gpg/passphrase \
        -distribution="${SUITE}" -component=main \
        "merged-${STAMP}" "filesystem:internal:"
    fi

    # Retain 14 snapshots for rollback; drop the rest and reclaim pool space.
    aptly snapshot list -raw | sort | head -n -14 | while read -r s; do
      aptly snapshot drop "${s}" || true
    done
    aptly db cleanup

    echo "==> published ${SUITE} from merged-${STAMP}"
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: apt-mirror-sync
  namespace: apt-mirror
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
      activeDeadlineSeconds: 21600
      template:
        spec:
          restartPolicy: Never
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            runAsGroup: 1000
            fsGroup: 1000
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: aptly
              image: registry.example.internal/platform/aptly:1.5.0
              command: ["/bin/bash", "/config/sync.sh"]
              env:
                - name: SUITE
                  value: bookworm
                - name: HOME
                  value: /srv/aptly
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              resources:
                requests:
                  cpu: "500m"
                  memory: "1Gi"
                limits:
                  cpu: "4"
                  memory: "4Gi"
              volumeMounts:
                - name: data
                  mountPath: /srv/aptly
                - name: config
                  mountPath: /config
                  readOnly: true
                - name: aptly-conf
                  mountPath: /srv/aptly/.aptly.conf
                  subPath: aptly.conf
                  readOnly: true
                - name: gpg
                  mountPath: /etc/aptly-gpg
                  readOnly: true
                - name: tmp
                  mountPath: /tmp
          volumes:
            - name: data
              persistentVolumeClaim:
                claimName: apt-mirror-data
            - name: config
              configMap:
                name: aptly-config
                defaultMode: 0555
            - name: aptly-conf
              configMap:
                name: aptly-config
            - name: gpg
              secret:
                secretName: aptly-signing-key
                defaultMode: 0400
            - name: tmp
              emptyDir: {}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: apt-mirror-web
  namespace: apt-mirror
spec:
  replicas: 2
  selector:
    matchLabels:
      app: apt-mirror-web
  template:
    metadata:
      labels:
        app: apt-mirror-web
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: nginx
          image: registry.example.internal/platform/nginx-autoindex:1.24
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet:
              path: /dists/bookworm/InRelease
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 15
            periodSeconds: 30
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests: {cpu: "100m", memory: "64Mi"}
            limits:   {cpu: "1",    memory: "256Mi"}
          volumeMounts:
            - name: data
              mountPath: /usr/share/nginx/html
              readOnly: true
            - name: cache
              mountPath: /var/cache/nginx
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: apt-mirror-data
        - name: cache
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: apt-mirror
  namespace: apt-mirror
spec:
  selector:
    app: apt-mirror-web
  ports:
    - name: http
      port: 80
      targetPort: http
```

La readiness probe sobre `/dists/bookworm/InRelease` es deliberada: una réplica cuyo PVC no se montó, o cuya publicación está a mitad de cambio, no debe recibir tráfico. Servir un índice escrito parcialmente a una flota es exactamente la tormenta de `Hash Sum mismatch` que estás tratando de prevenir.

### 8.4 `reprepro` — la alternativa liviana

```console
$ cat /srv/repo/conf/distributions
Origin: Example Platform
Label: example-platform
Codename: bookworm
Suite: stable
Version: 12
Architectures: amd64 arm64 source
Components: main platform
UDebComponents: main
Description: Internal package archive for platform services
SignWith: A1B2C3D4E5F6071829394A5B6C7D8E9FA0B1C2D3
Contents: . .gz .xz
Tracking: minimal
Log: bookworm.log

Origin: Example Platform
Label: example-platform
Codename: bookworm-staging
Suite: testing
Version: 12
Architectures: amd64 arm64 source
Components: main platform
Description: Staging archive — promoted to bookworm after soak
SignWith: A1B2C3D4E5F6071829394A5B6C7D8E9FA0B1C2D3
Contents: . .gz .xz
Tracking: minimal

$ cat /srv/repo/conf/options
verbose
basedir /srv/repo
outdir /srv/repo/public
ask-passphrase
```

```console
$ reprepro -b /srv/repo includedeb bookworm-staging platform-agent_5.1.0_amd64.deb
Exporting indices...
Successfully created 'dists/bookworm-staging/Release.gpg.new'
Successfully created 'dists/bookworm-staging/InRelease.new'

$ reprepro -b /srv/repo list bookworm-staging platform-agent
bookworm-staging|platform|amd64: platform-agent 5.1.0

# Promotion from staging to stable is a metadata copy — the pool file is shared.
$ reprepro -b /srv/repo copy bookworm bookworm-staging platform-agent
Exporting indices...

$ reprepro -b /srv/repo checkpool
Checking pool...

$ reprepro -b /srv/repo remove bookworm platform-agent=5.0.9
$ reprepro -b /srv/repo deleteunreferenced
```

| Propiedad | `reprepro` | `aptly` |
|---|---|---|
| Modelo | Una versión viva por distribución | Snapshots inmutables + puntos de publicación |
| Rollback | Volver a agregar el `.deb` viejo | `aptly publish switch` a un snapshot previo — segundos |
| Mirroring de upstream | Limitado (reglas de `update`) | De primera clase (`aptly mirror`) |
| Huella en disco | Mínima; un solo pool | Mayor; los snapshots comparten el pool pero los metadatos se multiplican |
| API | Ninguna | API REST |
| Mejor para | Archivo interno pequeño de tus propios paquetes | Mirror completo + promoción por etapas + rollback |

### 8.5 GitLab CI — construir, firmar, publicar y verificar un `.deb`

```yaml
# .gitlab-ci.yml
stages: [build, verify, publish, smoke]

variables:
  DEBIAN_FRONTEND: noninteractive
  DEB_BUILD_OPTIONS: "nocheck parallel=4"
  APT_PROXY: "http://apt-cache.example.internal:3142"

default:
  image: debian:bookworm-slim
  before_script:
    - echo "Acquire::http::Proxy \"${APT_PROXY}\";" > /etc/apt/apt.conf.d/01proxy
    - echo 'APT::Install-Recommends "false";' > /etc/apt/apt.conf.d/99no-recommends
    - echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/99retries
    - apt-get update

build:package:
  stage: build
  script:
    - apt-get install -y --no-install-recommends build-essential devscripts debhelper dpkg-dev lintian
    - apt-get build-dep -y .
    - dpkg-buildpackage -us -uc -b
    - mkdir -p artifacts && mv ../*.deb ../*.buildinfo ../*.changes artifacts/
    - ls -la artifacts/
  artifacts:
    paths: [artifacts/]
    expire_in: 30 days

verify:lintian:
  stage: verify
  needs: [build:package]
  script:
    - apt-get install -y --no-install-recommends lintian
    # Errors fail the pipeline; warnings are reported but tolerated.
    - lintian --fail-on error --display-info artifacts/*.changes

verify:metadata:
  stage: verify
  needs: [build:package]
  script:
    - apt-get install -y --no-install-recommends dpkg-dev
    - |
      set -euo pipefail
      DEB=$(ls artifacts/*.deb | head -1)
      echo "--- control ---"
      dpkg-deb -I "$DEB"
      echo "--- payload ---"
      dpkg-deb -c "$DEB"

      # Gate 1: a package with no md5sums can never be verified in the field.
      dpkg-deb -e "$DEB" /tmp/ctrl
      test -s /tmp/ctrl/md5sums || { echo "FATAL: package ships no md5sums"; exit 1; }

      # Gate 2: nothing may land outside the paths we own.
      if dpkg-deb -c "$DEB" | awk '{print $6}' \
           | grep -Ev '^\./(usr|etc|lib|var|opt/platform)(/|$)|^\./$'; then
        echo "FATAL: package writes outside permitted paths"; exit 1
      fi

      # Gate 3: maintainer scripts must not fetch code at install time.
      for s in preinst postinst prerm postrm; do
        [ -f "/tmp/ctrl/$s" ] || continue
        if grep -Eq '(curl|wget|nc)\s' "/tmp/ctrl/$s"; then
          echo "FATAL: $s performs network I/O"; exit 1
        fi
      done
      echo "all metadata gates passed"

publish:staging:
  stage: publish
  needs: [verify:lintian, verify:metadata]
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
  script:
    - apt-get install -y --no-install-recommends curl ca-certificates
    - |
      set -euo pipefail
      for f in artifacts/*.deb; do
        curl -fsS --retry 5 --retry-delay 5 \
             -u "ci:${APTLY_TOKEN}" \
             -X POST -F "file=@${f}" \
             "https://apt.example.internal/api/files/${CI_PIPELINE_ID}"
      done
      curl -fsS -u "ci:${APTLY_TOKEN}" \
           -X POST "https://apt.example.internal/api/repos/bookworm-staging/file/${CI_PIPELINE_ID}"
      curl -fsS -u "ci:${APTLY_TOKEN}" \
           -X PUT -H 'Content-Type: application/json' \
           -d '{"Snapshots":[{"Component":"platform","Name":"staging-'"${CI_PIPELINE_ID}"'"}]}' \
           "https://apt.example.internal/api/publish/filesystem:internal:/bookworm-staging"

smoke:install:
  stage: smoke
  needs: [publish:staging]
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
  script:
    - apt-get install -y --no-install-recommends ca-certificates curl gnupg
    - install -d -m 0755 /etc/apt/keyrings
    - curl -fsSL https://apt.example.internal/keys/platform.asc
        | gpg --dearmor -o /etc/apt/keyrings/platform-archive.gpg
    - |
      cat > /etc/apt/sources.list.d/platform-staging.sources <<'EOF'
      Types: deb
      URIs: https://apt.example.internal/debian
      Suites: bookworm-staging
      Components: platform
      Architectures: amd64
      Signed-By: /etc/apt/keyrings/platform-archive.gpg
      EOF
    - apt-get update
    # Prove the freshly published version is what APT actually selects.
    - apt-cache policy platform-agent
    - apt-get install -y platform-agent
    - dpkg -l platform-agent
    - dpkg -V platform-agent
    - dpkg --audit
    - test -z "$(dpkg --audit)"
```

### 8.6 Imágenes de contenedor — apt determinista en un `Dockerfile`

```dockerfile
# syntax=docker/dockerfile:1.7
FROM debian:bookworm-slim AS base

# Every apt setting that affects reproducibility, declared once.
RUN <<'EOF' bash
set -euxo pipefail
cat > /etc/apt/apt.conf.d/99docker <<'CONF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Retries "5";
Acquire::Languages "none";
Dpkg::Use-Pty "false";
CONF
EOF

# Pin to a snapshot so a rebuild six months from now produces the same layer.
# snapshot.debian.org serves the archive as it existed at a point in time.
ARG SNAPSHOT=20260801T000000Z
RUN <<'EOF' bash
set -euxo pipefail
cat > /etc/apt/sources.list.d/debian.sources <<CONF
Types: deb
URIs: https://snapshot.debian.org/archive/debian/${SNAPSHOT}
Suites: bookworm bookworm-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://snapshot.debian.org/archive/debian-security/${SNAPSHOT}
Suites: bookworm-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
CONF
rm -f /etc/apt/sources.list
echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99snapshot
EOF

# Cache mounts keep /var/cache/apt out of the image entirely.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked <<'EOF' bash
set -euxo pipefail
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3 \
    tini
EOF

FROM base AS runtime
COPY --chmod=0755 ./platform-agent /usr/bin/platform-agent

# Fail the build if any packaged file was modified after installation,
# and if any package is in a broken dpkg state.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked <<'EOF' bash
set -euxo pipefail
apt-get install -y --no-install-recommends debsums
debsums -s
test -z "$(dpkg --audit)"
apt-get purge -y debsums
apt-get autoremove -y --purge
EOF

USER 65534:65534
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/bin/platform-agent"]
```

Tres puntos que separan esto del habitual `RUN apt-get update && apt-get install`:

- **`Acquire::Check-Valid-Until "false"` se establece *sólo* para fuentes de snapshot.** Un snapshot es por definición un punto congelado en el tiempo, así que su `Valid-Until` siempre está en el pasado. Deshabilitar la verificación en cualquier otro lado reabre el ataque de congelamiento.
- **Montajes de caché, no `rm -rf`.** `--mount=type=cache` mantiene `/var/cache/apt` fuera de cada capa mientras sigue reutilizando descargas entre builds.
- **`debsums -s` y `dpkg --audit` son compuertas del build.** Un build que produce un estado de paquete roto nunca debería llegar a un registro.

### 8.7 `systemd` — actualizaciones de seguridad automáticas, acotadas y observables

```ini
# /etc/systemd/system/apt-security-upgrade.service
[Unit]
Description=Apply Debian security updates only
Documentation=man:unattended-upgrade(8)
After=network-online.target apt-daily.service
Wants=network-online.target
ConditionACPower=true

[Service]
Type=oneshot
Environment=DEBIAN_FRONTEND=noninteractive
# Never let a stuck conffile prompt hang a host indefinitely.
TimeoutStartSec=45min
Nice=19
IOSchedulingClass=idle
ExecStartPre=/usr/bin/apt-get update
ExecStart=/usr/bin/unattended-upgrade --verbose
ExecStartPost=/usr/bin/dpkg --audit
# needrestart reports services still running against deleted libraries.
ExecStartPost=/usr/sbin/needrestart -b -r l
SuccessExitStatus=0
```

```ini
# /etc/systemd/system/apt-security-upgrade.timer
[Unit]
Description=Nightly security-update window

[Timer]
OnCalendar=*-*-* 03:00:00
# Spread the fleet across a 45-minute window so the mirror is not stampeded.
RandomizedDelaySec=45min
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
```

```console
$ sudo systemctl enable --now apt-security-upgrade.timer
$ systemctl list-timers apt-security-upgrade.timer
NEXT                        LEFT     LAST                        PASSED UNIT                        ACTIVATES
Wed 2026-08-26 03:22:14 UTC 16h left Tue 2026-08-25 03:07:51 UTC 8h ago apt-security-upgrade.timer  apt-security-upgrade.service

$ sudo unattended-upgrade --dry-run --debug 2>&1 | tail -8
Checking: openssl (["<Origin component:'main' archive:'stable-security' origin:'Debian' label:'Debian-Security' site:'security.debian.org' isTrusted:True>"])
Checking: libssl3 (["<Origin component:'main' archive:'stable-security' origin:'Debian' label:'Debian-Security' site:'security.debian.org' isTrusted:True>"])
pkgs that look like they should be upgraded: libssl3 openssl
Packages blacklisted: ['^linux-image-', '^linux-headers-']
Option --dry-run given, *not* performing real actions
Packages that will be upgraded: libssl3 openssl
```

---

## 9. Multi-arch: una nota breve pero decisiva

```console
$ dpkg --print-architecture
amd64
$ dpkg --print-foreign-architectures
$ sudo dpkg --add-architecture arm64
$ sudo apt-get update
$ apt-get install -s libc6:arm64
```

`Multi-Arch:` en el archivo de control controla la coinstalabilidad:

| Valor | Significado |
|---|---|
| `same` | Coinstalable entre arquitecturas; todas las rutas entregadas deben estar calificadas por arquitectura (típico de bibliotecas) |
| `foreign` | Satisface dependencias desde cualquier arquitectura (herramientas independientes de arquitectura) |
| `allowed` | Los dependientes pueden pedir la copia nativa o una foránea vía `pkg:any` |
| *(ausente)* | Sólo arquitectura nativa |

La consecuencia visible en cada listado es el sufijo `:amd64`: `libssl3:amd64` y `libssl3:arm64` son entradas distintas en `dpkg -l`, y `dpkg -S`/`dpkg -L` aceptan el nombre calificado. En pipelines de compilación cruzada y emulación, olvidarse de `dpkg --add-architecture` antes de `apt-get update` es por qué `apt-get install libc6:arm64` informa "Unable to locate package" aunque el mirror lo tenga.

---

## 10. Lista de verificación y referencia de comandos

### 10.1 Health check — corrélo como sonda de monitoreo

```bash
#!/bin/bash
# /usr/local/sbin/apt-health-check
# Exit 0 = healthy. Non-zero = a specific, actionable condition.
set -uo pipefail
rc=0

# 1. No package in a broken dpkg state.
if [ -n "$(dpkg --audit)" ]; then
  echo "CRIT: broken dpkg state"; dpkg --audit; rc=2
fi

# 2. No package left in the 'iU/iF/iH/iR' family.
broken=$(dpkg-query -W -f='${Package} ${Status}\n' \
         | grep -Ev ' (install ok installed|deinstall ok config-files|unknown ok not-installed|install ok config-files)$' || true)
if [ -n "$broken" ]; then
  echo "WARN: unexpected package states:"; echo "$broken"; rc=$(( rc > 1 ? rc : 1 ))
fi

# 3. Indices refreshed within the last 48 h.
if [ -e /var/lib/apt/periodic/update-success-stamp ]; then
  age=$(( ($(date +%s) - $(stat -c %Y /var/lib/apt/periodic/update-success-stamp)) / 3600 ))
  [ "$age" -gt 48 ] && { echo "WARN: apt indices ${age}h old"; rc=$(( rc > 1 ? rc : 1 )); }
fi

# 4. No pending security upgrades.
sec=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null \
      | grep -c '^Inst.*Debian-Security' || true)
[ "$sec" -gt 0 ] && { echo "WARN: ${sec} pending security upgrades"; rc=$(( rc > 1 ? rc : 1 )); }

# 5. No unexpected holds (a hold silently defeats security automation).
holds=$(apt-mark showhold)
[ -n "$holds" ] && echo "INFO: held packages: $(echo "$holds" | tr '\n' ' ')"

# 6. Integrity: modified non-conffile files.
if command -v debsums >/dev/null; then
  mods=$(debsums -c 2>/dev/null | grep -v '^/etc/' || true)
  [ -n "$mods" ] && { echo "CRIT: modified packaged files:"; echo "$mods"; rc=2; }
fi

# 7. Every configured source is signed and reachable.
if ! apt-get update -o Debug::NoLocking=1 2>&1 | grep -qE '^(W|E):'; then
  :
else
  echo "WARN: apt-get update emitted warnings/errors"; rc=$(( rc > 1 ? rc : 1 ))
fi

# 8. Every executable in /usr/local/bin is untracked by design — enumerate it.
for f in /usr/local/bin/*; do
  [ -f "$f" ] || continue
  dpkg -S "$f" >/dev/null 2>&1 || echo "INFO: untracked binary $f"
done

exit "$rc"
```

```console
$ sudo /usr/local/sbin/apt-health-check; echo "exit=$?"
INFO: held packages: openssh-server
INFO: untracked binary /usr/local/bin/kubectl
exit=0
```

### 10.2 Referencia de comandos

| Tarea | Comando |
|---|---|
| Instalar un `.deb` local | `dpkg -i pkg.deb` y luego `apt-get -f install` |
| Instalar desde el archivo | `apt-get install pkg` |
| Instalar una versión específica | `apt-get install pkg=1.22.1-9` |
| Instalar desde una suite específica | `apt-get install -t bookworm-backports pkg` |
| Simular cualquier cambio | `apt-get -s <action>` |
| Eliminar, conservar configuración | `apt-get remove pkg` / `dpkg -r pkg` |
| Eliminar incluyendo configuración | `apt-get purge pkg` / `dpkg -P pkg` |
| Descartar dependencias huérfanas | `apt-get autoremove --purge` |
| Refrescar índices | `apt-get update` |
| Actualización conservadora | `apt-get upgrade` |
| Actualización completa (puede eliminar) | `apt-get dist-upgrade` |
| Listar instalados | `dpkg -l` / `dpkg-query -W -f=…` / `apt list --installed` |
| Listar actualizaciones pendientes | `apt list --upgradable` |
| Estrofa de estado del paquete | `dpkg -s pkg` |
| Archivos que posee un paquete | `dpkg -L pkg` |
| Dueño de un archivo instalado | `dpkg -S /path` |
| Dueño de cualquier archivo en el archivo | `apt-file search /path` |
| Metadatos de un paquete disponible | `apt-cache show pkg` |
| Metadatos de un archivo `.deb` | `dpkg-deb -I pkg.deb` |
| Contenido de un archivo `.deb` | `dpkg-deb -c pkg.deb` |
| Extraer un `.deb` sin instalar | `dpkg-deb -x pkg.deb dir/` |
| Extraer archivos de control | `dpkg-deb -e pkg.deb dir/` |
| Dependencias directas / inversas | `apt-cache depends pkg` / `apt-cache rdepends pkg` |
| ¿Por qué está instalado esto? | `aptitude why pkg` |
| Versión candidata y su fuente | `apt-cache policy pkg` |
| Matriz versión/suite | `apt-cache madison pkg` |
| Buscar por nombre/descripción | `apt-cache search regex` |
| Congelar / descongelar un paquete | `apt-mark hold pkg` / `apt-mark unhold pkg` |
| Listar retenidos | `apt-mark showhold` / `dpkg --get-selections \| grep hold` |
| Marcar manual / auto | `apt-mark manual pkg` / `apt-mark auto pkg` |
| Volcar / restaurar selecciones | `dpkg --get-selections` / `dpkg --set-selections` |
| Reconfigurar un paquete | `dpkg-reconfigure -plow pkg` |
| Presembrar respuestas | `debconf-set-selections < file` |
| Auditar estados rotos | `dpkg -C` / `dpkg --audit` |
| Terminar una instalación interrumpida | `dpkg --configure -a` |
| Reparar dependencias insatisfechas | `apt-get -f install` |
| Verificar consistencia de dependencias | `apt-get check` |
| Verificar integridad de archivos | `dpkg -V pkg` / `debsums -c` |
| Restaurar archivos empaquetados | `apt-get install --reinstall pkg` |
| Comparar versiones | `dpkg --compare-versions A op B` |
| Limpiar la caché de descargas | `apt-get clean` / `apt-get autoclean` |
| Configuración efectiva de APT | `apt-config dump` |
| Descargar un `.deb` sin instalar | `apt-get download pkg` |
| Obtener dependencias de compilación | `apt-get build-dep pkg` |
| Obtener el código fuente upstream | `apt-get source pkg` |
| Habilitar una arquitectura foránea | `dpkg --add-architecture arm64` |
| Reubicar un archivo que posee un paquete | `dpkg-divert --add --rename --divert /new /old` |

### 10.3 Referencia de archivos

| Ruta | Rol |
|---|---|
| `/etc/apt/sources.list` | Lista principal de repositorios, formato de una línea |
| `/etc/apt/sources.list.d/*.list` | Fuentes adicionales de una línea |
| `/etc/apt/sources.list.d/*.sources` | Fuentes adicionales deb822 |
| `/etc/apt/preferences`, `/etc/apt/preferences.d/*` | Política de pinning |
| `/etc/apt/apt.conf`, `/etc/apt/apt.conf.d/*` | Opciones de ejecución de APT y dpkg |
| `/etc/apt/auth.conf.d/*` | Credenciales por repositorio (modo `0600`) |
| `/etc/apt/trusted.gpg.d/*.{gpg,asc}` | Claves de archivo confiadas globalmente (patrón legado) |
| `/usr/share/keyrings/*.gpg`, `/etc/apt/keyrings/*` | Claves por repositorio referenciadas por `Signed-By` |
| `/var/lib/apt/lists/` | Índices `InRelease` / `Packages` descargados |
| `/var/cache/apt/archives/` | Archivos `.deb` descargados |
| `/var/cache/apt/{pkgcache,srcpkgcache}.bin` | Cachés binarias construidas por `apt-get update` |
| `/var/lib/dpkg/status` | **La** base de datos de paquetes instalados |
| `/var/lib/dpkg/info/<pkg>.*` | Listas de archivos, sumas de verificación y scripts del mantenedor por paquete |
| `/var/lib/dpkg/available` | Índice de disponibilidad de `dselect` |
| `/var/cache/debconf/config.dat` | Base de datos de respuestas de debconf |
| `/var/log/apt/history.log`, `term.log` | Historial de transacciones de APT y salida completa de terminal |
| `/var/log/dpkg.log` | Transiciones de estado por paquete |
| `/var/backups/dpkg.status.*` | Respaldos rotados de la base de datos de dpkg |

### 10.4 Ejercicios de práctica

Cada ejercicio tiene una única respuesta verificable producida por las herramientas de arriba. Hacelos en una VM o contenedor descartable.

1. Descargá `nginx-light` sin instalarlo, listá su carga útil, extraé su `postinst`, y confirmá a partir de los campos de control si arrastraría `nginx-doc` con la configuración por defecto de APT.
2. Instalá con `dpkg -i` un paquete cuyas dependencias estén ausentes. Registrá las banderas exactas de estado de `dpkg -l`. Reparalo con un solo comando y confirmá que las banderas vuelven a `ii`.
3. Modificá `/etc/ssh/sshd_config` y luego un archivo bajo `/usr/sbin/`. Ejecutá `dpkg -V openssh-server` y explicá por qué sólo uno de los dos produce una línea que deberías escalar.
4. Configurá un pin que haga que un repositorio agregado localmente pueda proveer exactamente un paquete y nada más. Probalo con `apt-cache policy` sobre ese paquete y sobre `libc6`.
5. Determiná qué paquete proveería `/usr/bin/tcpdump` en un host donde no está instalado — sin instalar nada más que `apt-file`.
6. Poné un paquete en hold, luego intentá `apt-get dist-upgrade` y `dpkg -i` de una versión más nueva. Registrá ambos mensajes de rechazo.
7. Dados `1:2.0~rc1-1` y `2.0-1`, predecí cuál es más nuevo, y luego verificalo con `dpkg --compare-versions`.
8. Reproducí un prompt de conffile durante una actualización, luego volvé a ejecutar la misma actualización de forma no interactiva con una política declarada para que se complete sin entrada.

---

## 11. Referencias

**Objetivos del examen**
- LPI — Exam 101-500 Objectives (v5.0), Topic 102.4: https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — LPIC-1 Certification Overview: https://www.lpi.org/our-certifications/lpic-1-overview/

**Documentación oficial de Debian**
- Debian Policy Manual — Control files and their fields (Ch. 5): https://www.debian.org/doc/debian-policy/ch-controlfields.html
- Debian Policy Manual — Declaring relationships between packages (Ch. 7): https://www.debian.org/doc/debian-policy/ch-relationships.html
- Debian Policy Manual — Configuration files / conffiles (§10.7): https://www.debian.org/doc/debian-policy/ch-files.html#configuration-files
- Debian Policy Manual — Version numbers and comparison (§5.6.12): https://www.debian.org/doc/debian-policy/ch-controlfields.html#version
- Debian Administrator's Handbook — Ch. 5, Packaging System: dpkg: https://debian-handbook.info/browse/stable/packaging-system.html
- Debian Administrator's Handbook — Ch. 6, Maintenance and Updates: The APT Tools: https://debian-handbook.info/browse/stable/sect.apt-get.html
- Debian Wiki — DebianRepository/Format: https://wiki.debian.org/DebianRepository/Format
- Debian Wiki — DebianRepository/UseThirdParty (keyring best practice): https://wiki.debian.org/DebianRepository/UseThirdParty
- Debian Wiki — SecureApt: https://wiki.debian.org/SecureApt
- Debian Wiki — Multiarch/HOWTO: https://wiki.debian.org/Multiarch/HOWTO
- Debian Wiki — AptConfiguration: https://wiki.debian.org/AptConfiguration
- Debian Wiki — UnattendedUpgrades: https://wiki.debian.org/UnattendedUpgrades
- Debian snapshot archive: https://snapshot.debian.org/
- Debian security information and advisories: https://www.debian.org/security/

**Páginas de manual (upstream, autoritativas)**
- `dpkg(1)`: https://manpages.debian.org/stable/dpkg/dpkg.1.en.html
- `dpkg-query(1)`: https://manpages.debian.org/stable/dpkg/dpkg-query.1.en.html
- `dpkg-deb(1)`: https://manpages.debian.org/stable/dpkg/dpkg-deb.1.en.html
- `deb(5)` — el formato de paquete binario: https://manpages.debian.org/stable/dpkg-dev/deb.5.en.html
- `deb-control(5)`: https://manpages.debian.org/stable/dpkg-dev/deb-control.5.en.html
- `dpkg-divert(1)`: https://manpages.debian.org/stable/dpkg/dpkg-divert.1.en.html
- `dpkg-reconfigure(8)`: https://manpages.debian.org/stable/debconf/dpkg-reconfigure.8.en.html
- `debconf-set-selections(1)`: https://manpages.debian.org/stable/debconf-utils/debconf-set-selections.1.en.html
- `apt(8)`: https://manpages.debian.org/stable/apt/apt.8.en.html
- `apt-get(8)`: https://manpages.debian.org/stable/apt/apt-get.8.en.html
- `apt-cache(8)`: https://manpages.debian.org/stable/apt/apt-cache.8.en.html
- `apt-mark(8)`: https://manpages.debian.org/stable/apt/apt-mark.8.en.html
- `sources.list(5)`: https://manpages.debian.org/stable/apt/sources.list.5.en.html
- `apt_preferences(5)` — pinning: https://manpages.debian.org/stable/apt/apt_preferences.5.en.html
- `apt.conf(5)`: https://manpages.debian.org/stable/apt/apt.conf.5.en.html
- `apt-secure(8)`: https://manpages.debian.org/stable/apt/apt-secure.8.en.html
- `apt-file(1)`: https://manpages.debian.org/stable/apt-file/apt-file.1.en.html
- `aptitude(8)`: https://manpages.debian.org/stable/aptitude/aptitude.8.en.html
- `debsums(1)`: https://manpages.debian.org/stable/debsums/debsums.1.en.html

**Herramientas relacionadas**
- APT source repository and release notes: https://salsa.debian.org/apt-team/apt
- aptly — repository management: https://www.aptly.info/doc/overview/
- reprepro documentation: https://salsa.debian.org/brlink/reprepro
- cloud-init — `apt` configuration module: https://cloudinit.readthedocs.io/en/latest/reference/modules.html#apt-configure
- Ansible — `ansible.builtin.apt` module: https://docs.ansible.com/ansible/latest/collections/ansible/builtin/apt_module.html
- Ansible — `ansible.builtin.deb822_repository` module: https://docs.ansible.com/ansible/latest/collections/ansible/builtin/deb822_repository_module.html
- Ubuntu Server documentation — Package management: https://documentation.ubuntu.com/server/howto/software/package-management/