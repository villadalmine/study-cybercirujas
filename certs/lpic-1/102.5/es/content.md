# 102.5 — Uso de la gestión de paquetes RPM y YUM

**LPIC-1 · Examen 102-500 · Objetivo 102.5 · Peso 4.69**

**Áreas de conocimiento clave:** instalar, reinstalar, actualizar y eliminar paquetes usando `rpm`, `yum`/`dnf` y `zypper`; obtener información de paquetes (versión, estado, dependencias, integridad, firmas); determinar qué archivos provee un paquete y qué paquete es dueño de un archivo dado.

**Términos y utilidades:** `rpm`, `rpm2cpio`, `/etc/yum.conf`, `/etc/yum.repos.d/`, `yum`, `zypper`

---

## 1. El problema de producción: el estado de los paquetes es el estado de la flota

Un sistema Linux no es "un kernel más algunos archivos". Es una **base de datos transaccional de artefactos instalados**, y cada propiedad operativa que te importa en producción se deriva de esa base de datos:

| Pregunta de producción | Se responde desde | Falla si la DB miente |
|---|---|---|
| ¿Está parcheado el CVE-2024-XXXX en los 4.000 nodos? | la versión del NEVRA afectado en el `rpmdb` | El informe de compliance dice "parcheado", el exploit dice lo contrario |
| ¿Por qué cambió `/etc/nginx/nginx.conf` a las 03:14? | historial de transacciones del paquete + `rpm -V` | La búsqueda de la causa raíz lleva horas en lugar de un comando |
| ¿Puedo revertir la actualización de anoche? | `dnf history` / registro de transacciones de `zypper` | Reconstruís el host desde cero |
| ¿Este binario lo provee el proveedor o fue copiado a mano? | `rpm -qf` + verificación de firma | Binario sin atribución = cadena de suministro no auditable |
| ¿Esta imagen de contenedor se construirá de forma reproducible? | metadatos de repo fijados + NEVRA | La imagen deriva silenciosamente entre builds |

El modo de falla arquitectónico que RPM/DNF existe para prevenir es la **deriva de configuración sin procedencia**. Un host donde alguien corrió `make install`, copió un binario sobre `/usr/local/bin`, o editó una configuración in situ es un host sobre el que no podés razonar, no podés parchear con confianza y no podés reproducir. Cada archivo que *no* es propiedad de un paquete es un archivo sin versión, sin checksum, sin firma y sin dueño.

El modelo de tres capas que tenés que internalizar:

```
┌─────────────────────────────────────────────────────────────────┐
│ Layer 3 — DEPOT / GOVERNANCE                                    │
│   Pulp · Katello/Satellite · Artifactory · Nexus · plain mirror │
│   content views, lifecycle envs, signing, retention             │
└───────────────────────────┬─────────────────────────────────────┘
                            │ HTTP(S) + repomd.xml + detached GPG
┌───────────────────────────▼─────────────────────────────────────┐
│ Layer 2 — DEPENDENCY RESOLVER (dnf / yum / zypper)              │
│   repo discovery, metadata cache, SAT solving, ordering,        │
│   download, GPG key trust, history/undo                         │
│   libsolv + librepo + hawkey   |   libzypp + libsolv            │
└───────────────────────────┬─────────────────────────────────────┘
                            │ ordered list of .rpm files
┌───────────────────────────▼─────────────────────────────────────┐
│ Layer 1 — TRANSACTION ENGINE (librpm / rpm)                     │
│   header parse, signature verify, dep check, file conflict      │
│   check, tsort, %pre → unpack → %post → rpmdb commit            │
│   /var/lib/rpm (sqlite | ndb | bdb_ro)                          │
└─────────────────────────────────────────────────────────────────┘
```

**`rpm` nunca habla con la red y nunca resuelve dependencias. `dnf`/`zypper` nunca instalan un archivo.** Toda decisión de diagnóstico empieza por decidir qué capa se rompió.

---

## 2. Capa 1 — Internals de RPM

### 2.1 El formato `.rpm` en disco

Un paquete RPM son cuatro regiones concatenadas:

```
  offset 0
┌──────────────────────────────────────────────┐
│ LEAD (96 bytes, legacy, ignored since rpm 4) │  magic ed ab ee db
├──────────────────────────────────────────────┤
│ SIGNATURE HEADER  (8-byte aligned)           │  RSA/SHA256 sigs, payload digests
├──────────────────────────────────────────────┤
│ HEADER            (tag → value store)        │  NEVRA, Requires, Provides,
│                                              │  FILENAMES, FILEDIGESTS,
│                                              │  scriptlets, changelog
├──────────────────────────────────────────────┤
│ PAYLOAD  (cpio archive, compressed)          │  gzip | xz | zstd
└──────────────────────────────────────────────┘
```

Verificalo vos mismo:

```
$ hexdump -C -n 16 nginx-1.20.1-14.el9_2.1.x86_64.rpm
00000000  ed ab ee db 03 00 00 00  00 01 6e 67 69 6e 78 2d  |..........nginx-|
00000010

$ rpm -qp --qf '%{PAYLOADFORMAT} / %{PAYLOADCOMPRESSOR} / %{ARCHIVESIZE}\n' \
      nginx-1.20.1-14.el9_2.1.x86_64.rpm
cpio / zstd / 0
```

La consecuencia crítica: **el header es autodescriptivo e independiente del payload**. Por eso `dnf` puede construir un grafo de dependencias completo para 40.000 paquetes descargando solo `primary.xml.gz` — una proyección de los headers — sin traer jamás el cuerpo de un paquete.

| Compresor | Ratio típico | Velocidad de descompresión | Dónde se usa |
|---|---|---|---|
| `gzip` | referencia | rápida | era EL5–EL6, máxima compatibilidad |
| `xz` | ~30 % más chico que gzip | lenta (mono-hilo por defecto) | EL7/EL8, openSUSE |
| `zstd` | ≈ tamaño de xz, 3–5× más rápido de descomprimir | muy rápida | Fedora 31+, EL9+, SUSE 15.5+ |

Para una flota de 4.000 nodos, la migración a zstd no es cosmética: el tiempo real de instalación está dominado por la descompresión del payload, no por la descarga.

### 2.2 NEVRA y el algoritmo de comparación de versiones

La identidad de todo paquete es **`Name-[Epoch:]Version-Release.Arch`**.

```
$ rpm -q --qf '%{NAME} | %{EPOCH} | %{VERSION} | %{RELEASE} | %{ARCH}\n' nginx
nginx | 1 | 1.20.1 | 14.el9_2.1 | x86_64

$ rpm -q --qf '%{NEVRA}\n' nginx
nginx-1:1.20.1-14.el9_2.1.x86_64
```

`rpmvercmp` divide Version y Release en segmentos alfabéticos y numéricos alternados y compara segmento por segmento. Las reglas que muerden en producción:

| Regla | Ejemplo | Resultado |
|---|---|---|
| Los segmentos numéricos se comparan numéricamente, se quitan los ceros a la izquierda | `1.010` vs `1.9` | `1.010` es más nuevo (10 > 9) |
| Los dígitos superan a las letras | `1.0` vs `1.0a` | `1.0a` es más nuevo |
| Más segmentos superan a menos | `1.0` vs `1.0.1` | `1.0.1` es más nuevo |
| `~` ordena **antes** que todo, incluso que vacío | `2.0~rc1` vs `2.0` | `2.0` es más nuevo |
| `^` ordena **después** de la versión base | `2.0^git20260101` vs `2.0` | el snapshot es más nuevo |
| **Epoch domina de forma absoluta** | `1:1.0-1` vs `0:9.9-1` | `1:1.0-1` es más nuevo |

```
$ rpmdev-vercmp 1:1.0-1 0:9.9-1
1:1.0-1 > 0:9.9-1
$ echo $?
11

$ rpm --eval '%{lua: print(rpm.vercmp("2.0~rc1", "2.0"))}'
-1

$ zypper vcmp 2.0^git20260101 2.0
2.0^git20260101 is newer than 2.0
```

**Trampa arquitectónica:** el epoch es un trinquete de una sola dirección. Una vez que un proveedor publica `Epoch: 1`, ningún build futuro con `Epoch: 0` — por más alta que sea su versión — será visto jamás como una actualización. Bajar de versión más allá de un salto de epoch requiere un `dnf downgrade` explícito o `rpm -Uvh --oldpackage`. Nunca introduzcas un epoch en un paquete interno para "ganar" un conflicto; estás hipotecando permanentemente cada rebase futuro.

### 2.3 El rpmdb

```
$ rpm --eval '%{_dbpath}'
/usr/lib/sysimage/rpm

$ ls -l /var/lib/rpm
lrwxrwxrwx. 1 root root 25 Aug 12 09:14 /var/lib/rpm -> ../../usr/lib/sysimage/rpm

$ rpm --eval '%{_db_backend}'
sqlite

$ ls -lh /usr/lib/sysimage/rpm/
total 142M
-rw-r--r--. 1 root root  142M Aug 24 11:02 rpmdb.sqlite
-rw-r--r--. 1 root root   32K Aug 24 11:02 rpmdb.sqlite-shm
-rw-r--r--. 1 root root  4.0M Aug 24 11:02 rpmdb.sqlite-wal
```

| Backend | Distros | Concurrencia | Comportamiento ante corrupción | Veredicto |
|---|---|---|---|---|
| `bdb` (Berkeley DB) | EL7, EL8 (solo lectura en EL9) | locks de entorno, archivos `__db.00*` | Frecuente tras un reset duro / OOM kill; necesita `--rebuilddb` | Legacy, evitar |
| `ndb` | openSUSE / SLE 15+ | un solo escritor, mmap | Robusto, se autorrepara ante truncamiento | Bueno |
| `sqlite` | Fedora 33+, EL9+ | WAL, commit atómico | Efectivamente transaccional | **Por defecto, el mejor** |

La migración importa operativamente: en EL7/EL8 un `yum` matado por OOM durante una transacción dejaba rutinariamente un archivo `Packages` corrupto. Sobre sqlite/WAL, la transacción o commitea o no — que es exactamente la propiedad que querés cuando un nodo pierde la energía a mitad de un parcheo.

### 2.4 Semántica de dependencias

Las dependencias de RPM son **basadas en capacidades, no en paquetes**. Un paquete requiere una *cadena de capacidad*; cualquier paquete que la `Provides` satisface el requerimiento.

```
$ rpm -q --requires nginx | head -12
/bin/sh
config(nginx) = 1:1.20.1-14.el9_2.1
libc.so.6(GLIBC_2.34)(64bit)
libcrypto.so.3()(64bit)
libcrypto.so.3(OPENSSL_3.0.0)(64bit)
libpcre2-8.so.0()(64bit)
libssl.so.3()(64bit)
libz.so.1()(64bit)
nginx-filesystem = 1:1.20.1-14.el9_2.1
rtld(GNU_HASH)
system-logos-httpd
systemd

$ rpm -q --provides nginx | head -6
config(nginx) = 1:1.20.1-14.el9_2.1
nginx = 1:1.20.1-14.el9_2.1
nginx(x86-64) = 1:1.20.1-14.el9_2.1
webserver
```

Fijate en `libcrypto.so.3(OPENSSL_3.0.0)(64bit)` — dependencias de soname *y de versión de símbolo* autogeneradas en tiempo de build por `/usr/lib/rpm/find-requires`. Por esto un downgrade de OpenSSL 3 → OpenSSL 1.1 basado en RPM es rechazado por el solver en lugar de producir un host lleno de binarios que no arrancan.

| Tipo de dependencia | Significado | Comportamiento del solver |
|---|---|---|
| `Requires` | dura, debe satisfacerse | la transacción falla sin ella |
| `Requires(pre)` / `Requires(post)` | restricción de orden para scriptlets | afecta el tsort, no solo la presencia |
| `Recommends` | débil, se instala por defecto | se respeta salvo `install_weak_deps=False` |
| `Suggests` | débil, no se instala automáticamente | solo la muestra la UI |
| `Supplements` | recommends inverso ("traeme si X está presente") | instala este paquete cuando X está |
| `Enhances` | suggests inverso | informativo |
| `Conflicts` | no pueden coexistir | transacción rechazada |
| `Obsoletes` | este paquete reemplaza a aquel | dispara reemplazo automático al actualizar |
| Deps ricas/booleanas | `Requires: (foo if bar)`, `(a or b)` | RPM 4.13+, necesita un resolver consciente de libsolv |

`Obsoletes` es el tag más peligroso en producción. `Obsoletes: legacy-agent < 2.0` en un repo de terceros va a eliminar silenciosamente tu agente de monitoreo durante un `dnf upgrade` de rutina. Auditalo:

```
$ dnf repoquery --qf '%{name}-%{evr}: %{obsoletes}' --obsoletes --repo=vendor-tools
```

### 2.5 Scriptlets y orden de la transacción

```
$ rpm -q --scripts nginx
preinstall scriptlet (using /bin/sh):
/usr/bin/getent group nginx >/dev/null || /usr/sbin/groupadd -r nginx
/usr/bin/getent passwd nginx >/dev/null || \
    /usr/sbin/useradd -r -d /var/lib/nginx -g nginx \
    -s /sbin/nologin -c "Nginx web server" nginx
exit 0
postinstall scriptlet (using /bin/sh):
if [ $1 -eq 1 ] ; then
        systemctl preset nginx.service &>/dev/null || :
fi
preuninstall scriptlet (using /bin/sh):
if [ $1 -eq 0 ] ; then
        systemctl --no-reload disable --now nginx.service &>/dev/null || :
fi
postuninstall scriptlet (using /bin/sh):
systemctl daemon-reload &>/dev/null || :
if [ $1 -ge 1 ] ; then
        systemctl try-restart nginx.service &>/dev/null || :
fi
```

El argumento `$1` es la **cantidad de instancias de este paquete que van a existir después de la operación** — el hecho peor entendido del empaquetado RPM:

| Operación | `%pre` `$1` | `%post` `$1` | `%preun` `$1` | `%postun` `$1` |
|---|---|---|---|---|
| Primera instalación | 1 | 1 | — | — |
| Actualización | 2 | 2 | 1 (paquete viejo) | 1 (paquete viejo) |
| Borrado | — | — | 0 | 0 |

Por lo tanto `if [ $1 -eq 1 ]` significa "solo instalación nueva" e `if [ $1 -eq 0 ]` significa "eliminación final, no una actualización". Equivocarse acá es la razón por la que un paquete deshabilita su propio servicio en cada actualización.

Orden dentro de una transacción: RPM construye un grafo dirigido a partir de `Requires(pre|post)` y lo ordena topológicamente. `%posttrans` corre después de que *todos* los paquetes de la transacción están instalados — el lugar correcto para regenerar cachés (`ldconfig`, cachés de fuentes, cachés de iconos GTK). Los file triggers extienden esto a todo el sistema:

```
$ rpm -q --filetriggers glibc
transfiletriggerin scriptlet (using <lua>) -- /lib, /lib64, /usr/lib, /usr/lib64
posix.exec("/sbin/ldconfig")
```

Un `ldconfig` por transacción en vez de uno por paquete — la razón por la que las transacciones en EL8+ son dramáticamente más rápidas que en EL7.

---

## 3. `rpm` — la superficie operativa completa de comandos

### 3.1 Modo de consulta (`-q`)

```
$ rpm -qa | wc -l
487

$ rpm -qa --last | head -5
kernel-5.14.0-427.28.1.el9_4.x86_64        Sun 24 Aug 2026 11:02:41 AM UTC
nginx-1:1.20.1-14.el9_2.1.x86_64           Sun 24 Aug 2026 11:02:38 AM UTC
nginx-core-1:1.20.1-14.el9_2.1.x86_64      Sun 24 Aug 2026 11:02:37 AM UTC
nginx-filesystem-1:1.20.1-14.el9_2.1.noarch Sun 24 Aug 2026 11:02:36 AM UTC
openssl-1:3.0.7-27.el9.x86_64              Fri 12 Aug 2026 09:14:02 PM UTC

$ rpm -qi bash
Name        : bash
Version     : 5.1.8
Release     : 9.el9
Architecture: x86_64
Install Date: Mon 12 Aug 2026 09:14:22 PM UTC
Group       : Unspecified
Size        : 7807488
License     : GPLv3+
Signature   : RSA/SHA256, Wed 24 Jan 2026 03:12:11 PM UTC, Key ID 199e2f91fd431d51
Source RPM  : bash-5.1.8-9.el9.src.rpm
Build Date  : Wed 24 Jan 2026 02:51:03 PM UTC
Build Host  : x86-64-01.build.eng.rdu2.redhat.com
Packager    : Red Hat, Inc. <http://bugzilla.redhat.com/bugzilla>
Vendor      : Red Hat, Inc.
URL         : https://www.gnu.org/software/bash
Summary     : The GNU Bourne Again shell
Description :
The GNU Bourne Again shell (Bash) is a shell or command language
interpreter that is compatible with the Bourne shell (sh).
```

| Selector | Significado |
|---|---|
| `-q <pkg>` | consulta un paquete instalado por nombre |
| `-qa` | todos los paquetes instalados |
| `-qp <file.rpm>` | consulta un archivo `.rpm` **no instalado** |
| `-qf <path>` | qué paquete es dueño de este archivo |
| `-q --whatprovides <cap>` | qué paquete instalado provee una capacidad |
| `-q --whatrequires <cap>` | qué paquetes instalados requieren una capacidad |
| `-qg <group>` | por el tag legacy de grupo |

| Flag de info | Salida |
|---|---|
| `-i` | header completo de metadatos |
| `-l` | lista de archivos |
| `-c` | solo archivos de configuración |
| `-d` | solo archivos de documentación |
| `--dump` | ruta, tamaño, mtime, digest, modo, dueño, grupo, isconfig, isdoc, rdev, symlink |
| `--requires` / `-R` | dependencias |
| `--provides` | capacidades |
| `--conflicts`, `--obsoletes`, `--recommends`, `--suggests` | clases de dependencia restantes |
| `--scripts`, `--triggers`, `--filetriggers` | código fuente de los scriptlets |
| `--changelog` | changelog (contiene referencias a CVE — oro para auditoría) |
| `--queryformat` / `--qf` | formateo arbitrario de tags |

Las dos búsquedas inversas que exige el objetivo:

```
# Which package owns this file?
$ rpm -qf /usr/sbin/nginx
nginx-core-1:1.20.1-14.el9_2.1.x86_64

$ rpm -qf $(readlink -f $(which python3))
python3-3.9.18-3.el9_4.1.x86_64

# What files does this package provide?
$ rpm -ql nginx-filesystem
/etc/nginx
/etc/nginx/conf.d
/etc/nginx/default.d
/usr/share/nginx
/usr/share/nginx/html
/var/log/nginx

$ rpm -qc nginx
/etc/logrotate.d/nginx
/etc/nginx/fastcgi.conf
/etc/nginx/fastcgi_params
/etc/nginx/mime.types
/etc/nginx/nginx.conf
/etc/nginx/scgi_params
/etc/nginx/uwsgi_params

# Same, for a package that is NOT installed:
$ rpm -qlp ./acme-metrics-agent-2.4.0-1.el9.x86_64.rpm
/etc/acme/metrics-agent.yaml
/usr/bin/acme-metrics-agent
/usr/lib/systemd/system/acme-metrics-agent.service
/usr/lib/sysusers.d/acme-metrics-agent.conf
/usr/share/doc/acme-metrics-agent/README.md
/usr/share/licenses/acme-metrics-agent/LICENSE
/var/log/acme
```

`--queryformat` convierte al rpmdb en un motor de reportes. Así producís inventario de flota sin ningún agente:

```
$ rpm -qa --qf '%{NAME}\t%{EVR}\t%{ARCH}\t%{VENDOR}\t%{INSTALLTIME:date}\n' \
    | sort > /var/tmp/inventory-$(hostname -s).tsv

# Find every package NOT signed by a key you trust
$ rpm -qa --qf '%{NAME}-%{EVR} %{SIGPGP:pgpsig}\n' | grep -v 'Key ID 199e2f91fd431d51'
acme-metrics-agent-2.4.0-1.el9 (none)
gpg-pubkey-fd431d51-4ae0493b (none)

# Iterate over array tags with [ ]
$ rpm -q --qf '[%{FILENAMES} %{FILEMODES:perms} %{FILEUSERNAME}\n]' nginx-filesystem
/etc/nginx drwxr-xr-x root
/etc/nginx/conf.d drwxr-xr-x root
/etc/nginx/default.d drwxr-xr-x root
/usr/share/nginx drwxr-xr-x root
/usr/share/nginx/html drwxr-xr-x root
/var/log/nginx drwxr-xr-x root
```

### 3.2 Modo de verificación (`-V`)

`rpm -V` compara cada archivo en disco contra el digest, modo, dueño, grupo, tamaño, mtime y capabilities registrados en el rpmdb. Es la verificación de integridad de host más barata disponible y no requiere herramientas adicionales.

```
$ rpm -V nginx
S.5....T.  c /etc/nginx/nginx.conf

$ rpm -V openssh-server
.M.......    /etc/ssh/sshd_config
missing     /usr/share/man/man5/sshd_config.5.gz

$ rpm -Va --nomtime --nordev 2>/dev/null | grep -v '^\.\{9\}' | head
S.5....T.  c /etc/nginx/nginx.conf
.M.......    /etc/ssh/sshd_config
..5......    /usr/bin/curl        <-- INVESTIGATE IMMEDIATELY
missing   d /usr/share/man/man5/sshd_config.5.gz
```

La cadena de resultado de nueve caracteres, en orden:

| Pos | Char | Significado |
|---|---|---|
| 1 | `S` | Difiere el tamaño (**S**ize) |
| 2 | `M` | Difiere el modo (**M**ode: permisos/tipo) |
| 3 | `5` | Difiere el digest (MD5/SHA256) — **cambió el contenido del archivo** |
| 4 | `D` | No coincide el major/minor del dispositivo (**D**evice) |
| 5 | `L` | No coincide el destino del enlace simbólico (**L**ink) |
| 6 | `U` | Difiere el dueño (**U**ser) |
| 7 | `G` | Difiere el grupo (**G**roup) |
| 8 | `T` | Difiere el m**T**ime |
| 9 | `P` | Difieren las ca**P**abilities |

`.` = la prueba pasó, `?` = la prueba no se pudo realizar (archivo ilegible). La cadena literal `missing` reemplaza a las nueve posiciones cuando el archivo no está.

El marcador de atributo que sigue a la cadena de resultado clasifica el archivo: `c` config, `d` documentación, `g` ghost (con dueño pero no distribuido, p. ej. archivos de log), `l` licencia, `r` readme.

**Regla de triage operativo:**

| Resultado | Interpretación | Acción |
|---|---|---|
| `S.5....T.  c /etc/...` | Config editada por un admin o por gestión de configuración | Esperado; reconciliar con Ansible/Puppet |
| `.M.......  /etc/...` | Cambiaron los permisos | Sospechoso salvo que lo haya hecho la línea base de hardening |
| `..5......  /usr/bin/...` | **Cambió el contenido de un binario distribuido** | Tratar como compromiso hasta demostrar lo contrario |
| `missing  d ...` | Docs eliminadas (`--excludedocs`, imagen base de contenedor) | Benigno |
| `missing    /usr/lib64/...` | Librería borrada | Algo va a fallar al arrancar |
| `.......T.` solo | Solo mtime, a menudo por una restauración | Poca señal, `--nomtime` para suprimirlo |

Reparar la deriva de metadatos (rpm 4.16+):

```
$ rpm --setperms nginx        # restore modes only
$ rpm --setugids nginx        # restore owner/group only
$ rpm --restore nginx         # restore modes, ownership and capabilities
$ rpm -V nginx
S.5....T.  c /etc/nginx/nginx.conf     # content of a config is never "restored"
```

Para restaurar el **contenido**, reinstalá el payload — ver §5.

### 3.3 Instalar / actualizar / borrar

```
$ sudo rpm -ivh ./acme-metrics-agent-2.4.0-1.el9.x86_64.rpm
Verifying...                          ################################# [100%]
Preparing...                          ################################# [100%]
Updating / installing...
   1:acme-metrics-agent-2.4.0-1.el9   ################################# [100%]

$ sudo rpm -Uvh ./acme-metrics-agent-2.5.0-1.el9.x86_64.rpm
Verifying...                          ################################# [100%]
Preparing...                          ################################# [100%]
Updating / installing...
   1:acme-metrics-agent-2.5.0-1.el9   ################################# [ 50%]
Cleaning up / removing...
   2:acme-metrics-agent-2.4.0-1.el9   ################################# [100%]
```

| Modo | Comportamiento si no está instalado | Comportamiento si hay una versión anterior instalada |
|---|---|---|
| `-i` / `--install` | instala | **falla** con "already installed" (salvo install-only) |
| `-U` / `--upgrade` | instala | actualiza, elimina la vieja |
| `-F` / `--freshen` | **no hace nada** | actualiza |
| `-e` / `--erase` | falla | elimina (sin resolución de dependencias) |

`-F` es el verbo correcto para "parcheá lo que está presente, no instales nada nuevo" — el clásico bucle de actualización masiva contra un directorio de RPMs.

**Paquetes install-only.** Los kernels están marcados como `installonlypkg(kernel)` y deben usar `-i`, nunca `-U`; actualizar eliminaría el kernel en ejecución y te dejaría sin rollback. `dnf` maneja esto automáticamente vía `installonly_limit`.

```
$ rpm -q --qf '[%{PROVIDES}\n]' kernel-5.14.0-427.28.1.el9_4 | grep installonly
installonlypkg(kernel)

$ rpm -q kernel
kernel-5.14.0-427.13.1.el9_4.x86_64
kernel-5.14.0-427.28.1.el9_4.x86_64
```

Flags a los que vas a recurrir, y lo que realmente te cuestan:

| Flag | Efecto | Riesgo |
|---|---|---|
| `--test` | simulacro: solo verificaciones de firma, dependencias y conflictos de archivos | ninguno — **usalo siempre en ventanas de cambio** |
| `-vv` | depuración a nivel de protocolo | ninguno |
| `--nodeps` | omite la verificación de dependencias | **rompe el invariante que la DB existe para garantizar** |
| `--force` | `--replacepkgs --replacefiles --oldpackage` | tosco; enmascara conflictos reales |
| `--replacepkgs` | reinstala el mismo NEVRA | seguro, la herramienta correcta para "restaurar el payload" |
| `--replacefiles` | sobrescribe archivos que son de otro paquete | deja dos paquetes reclamando un archivo |
| `--oldpackage` | permite downgrade vía `-U` | está bien, deliberadamente |
| `--justdb` | actualiza el rpmdb sin tocar el filesystem | solo para reparación de imagen/DB; en otro caso garantiza deriva |
| `--noscripts` / `--notriggers` | omite los scriptlets | no se van a crear usuarios ni servicios |
| `--excludedocs` | descarta los archivos `%doc` | estándar en imágenes de contenedor |
| `--root /mnt` | opera sobre una raíz alternativa | chroot/rescate/construcción de imágenes |
| `--dbpath <dir>` | ubicación alternativa del rpmdb | forense contra una DB copiada |
| `--nodigest` / `--nosignature` | omite las verificaciones de integridad | **nunca en producción** |

```
# Always rehearse:
$ sudo rpm -Uvh --test ./acme-metrics-agent-2.5.0-1.el9.x86_64.rpm
Verifying...                          ################################# [100%]
Preparing...                          ################################# [100%]

# A real conflict, caught by --test:
$ sudo rpm -ivh --test ./rogue-tools-1.0-1.el9.x86_64.rpm
Verifying...                          ################################# [100%]
Preparing...                          ################################# [100%]
	file /usr/bin/curl from install of rogue-tools-1.0-1.el9.x86_64 conflicts
	with file from package curl-7.76.1-29.el9_4.x86_64

# Rescue / offline forensics against another root:
$ sudo rpm -qa --root=/mnt/sysroot | wc -l
412
$ sudo rpm -Va --root=/mnt/sysroot --nomtime | grep -v '^\.\{9\}'
```

### 3.4 Integridad y firmas

Las firmas de RPM son la última línea de la cadena de suministro. Existen tres verificaciones distintas y no son intercambiables:

| Verificación | Comando | Prueba |
|---|---|---|
| Digest del payload/header | `rpm -K --nosignature` | el archivo no fue truncado ni corrompido en tránsito |
| Firma GPG del header + payload | `rpm -K` / `rpm --checksig` | el paquete fue construido y firmado por quien posee la clave |
| Confianza en la clave | `rpm -qa gpg-pubkey*` | esa clave está en *tu* almacén de confianza |

```
$ sudo rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release

$ rpm -qa gpg-pubkey\* --qf '%{NAME}-%{VERSION}-%{RELEASE}\t%{SUMMARY}\n'
gpg-pubkey-fd431d51-4ae0493b	gpg(Red Hat, Inc. (release key 2) <security@redhat.com>)
gpg-pubkey-5a6340b3-6229229e	gpg(Red Hat, Inc. (auxiliary key 3) <security@redhat.com>)
gpg-pubkey-9b1d2a17-64b1a1c2	gpg(ACME Platform Signing Key <platform@acme.internal>)

$ rpm -qi gpg-pubkey-9b1d2a17-64b1a1c2 | head -12
Name        : gpg-pubkey
Version     : 9b1d2a17
Release     : 64b1a1c2
Architecture: (none)
Install Date: Wed 20 Aug 2026 04:41:09 PM UTC
Group       : Public Keys
Size        : 0
License     : pubkey
Signature   : (none)
Source RPM  : (none)
Summary     : gpg(ACME Platform Signing Key <platform@acme.internal>)

$ rpm -K nginx-1.20.1-14.el9_2.1.x86_64.rpm
nginx-1.20.1-14.el9_2.1.x86_64.rpm: digests signatures OK

$ rpm -Kv nginx-1.20.1-14.el9_2.1.x86_64.rpm
nginx-1.20.1-14.el9_2.1.x86_64.rpm:
    Header V4 RSA/SHA256 Signature, key ID 199e2f91: OK
    Header SHA256 digest: OK
    Header SHA1 digest: OK
    Payload SHA256 digest: OK
    V4 RSA/SHA256 Signature, key ID 199e2f91: OK

# Unknown key:
$ rpm -Kv ./acme-metrics-agent-2.5.0-1.el9.x86_64.rpm
./acme-metrics-agent-2.5.0-1.el9.x86_64.rpm:
    Header V4 RSA/SHA256 Signature, key ID 9b1d2a17: NOKEY
    Header SHA256 digest: OK
    Payload SHA256 digest: OK
    V4 RSA/SHA256 Signature, key ID 9b1d2a17: NOKEY
./acme-metrics-agent-2.5.0-1.el9.x86_64.rpm: digests SIGNATURES NOT OK

# Not signed at all:
$ rpm -Kv ./scratch-build-0.1-1.el9.x86_64.rpm
./scratch-build-0.1-1.el9.x86_64.rpm:
    Header SHA256 digest: OK
    Payload SHA256 digest: OK
./scratch-build-0.1-1.el9.x86_64.rpm: digests OK
```

Leé la línea de resumen con precisión: `digests signatures OK` (ambas), `digests OK` (**sin firmar**), `digests SIGNATURES NOT OK` (firmado, clave no confiable o firma inválida). Un gate de CI que hace grep de `OK` deja pasar paquetes sin firmar. Hacé grep de la cadena exacta `digests signatures OK`.

En EL9+ esto lo impone librpm mismo:

```
$ rpm --eval '%{_pkgverify_level}'
all
```

Firmar tus propios paquetes:

```
$ cat >> ~/.rpmmacros <<'EOF'
%_gpg_name ACME Platform Signing Key <platform@acme.internal>
%_gpg_digest_algo sha256
%_source_payload w19.zstdio
%_binary_payload w19.zstdio
EOF

$ rpmsign --addsign ./acme-metrics-agent-2.5.0-1.el9.x86_64.rpm
Enter passphrase:
Pass phrase is good.
./acme-metrics-agent-2.5.0-1.el9.x86_64.rpm:

$ rpmsign --delsign ./old-package.rpm     # strip before re-signing with a rotated key
```

### 3.5 `rpm2cpio` — leer un paquete sin instalarlo

`rpm2cpio` quita el lead, el signature header y el header, descomprime el payload y escribe un flujo cpio crudo a stdout. Es la única forma sancionada de extraer contenido de un paquete sin tocar el rpmdb.

```
$ rpm2cpio nginx-core-1.20.1-14.el9_2.1.x86_64.rpm | cpio -idmv
./usr/sbin/nginx
./usr/share/man/man3/nginx.3pm.gz
./usr/share/man/man8/nginx.8.gz
1846 blocks

$ rpm2cpio nginx-core-1.20.1-14.el9_2.1.x86_64.rpm | cpio -t | head
./usr/sbin/nginx
./usr/share/man/man3/nginx.3pm.gz
./usr/share/man/man8/nginx.8.gz

# Extract exactly one file (leading ./ matters):
$ rpm2cpio openssh-server-8.7p1-38.el9.x86_64.rpm \
    | cpio -idmv './etc/ssh/sshd_config'
./etc/ssh/sshd_config
2 blocks

# Read a config from a package without extracting anything:
$ rpm2cpio httpd-2.4.53-11.el9_2.5.x86_64.rpm \
    | cpio --to-stdout -i './etc/httpd/conf/httpd.conf' | head -5
#
# This is the main Apache HTTP server configuration file.
# It contains the configuration directives that give the server its instructions.
```

Flags de `cpio`: `-i` extraer, `-d` crear directorios, `-m` preservar mtimes, `-v` verboso, `-t` solo listar, `--to-stdout` enviar un miembro por stdout.

La alternativa moderna, `rpm2archive`, emite un flujo tar y preserva cosas que cpio no puede (archivos grandes, atributos extendidos):

```
$ rpm2archive -n nginx-core-1.20.1-14.el9_2.1.x86_64.rpm > nginx-core.tar
$ tar tvf nginx-core.tar | head -3
-rwxr-xr-x root/root   1352144 2026-01-24 14:51 ./usr/sbin/nginx
-rw-r--r-- root/root      1319 2026-01-24 14:51 ./usr/share/man/man3/nginx.3pm.gz
-rw-r--r-- root/root      7392 2026-01-24 14:51 ./usr/share/man/man8/nginx.8.gz

# Pipe straight into a container filesystem, no temp file:
$ rpm2archive - < nginx-core-*.rpm | tar -xzC ./rootfs
```

| Herramienta | Salida | Preserva xattrs / caps | Archivos > 4 GB | Disponibilidad |
|---|---|---|---|---|
| `rpm2cpio` | cpio a stdout | no | no (límite del `newc` de cpio) | universal, **exigida por el examen** |
| `rpm2archive` | `.tgz` (o stdout con `-n -`) | sí | sí | rpm 4.14+ |

**Patrón de recuperación** — restaurar un único archivo del proveedor borrado sin una reinstalación completa:

```
$ ls -l /usr/bin/curl
ls: cannot access '/usr/bin/curl': No such file or directory

$ rpm -qf /usr/bin/curl
curl-7.76.1-29.el9_4.x86_64

$ dnf download curl
$ rpm2cpio curl-7.76.1-29.el9_4.x86_64.rpm \
    | sudo cpio -idmv -D / './usr/bin/curl'
./usr/bin/curl
1204 blocks

$ rpm -V curl
$ echo $?
0
```

---

## 4. Capa 2 — YUM / DNF

### 4.1 Qué es `yum` en un sistema moderno

```
$ ls -l /usr/bin/yum
lrwxrwxrwx. 1 root root 5 Aug 12 09:13 /usr/bin/yum -> dnf-3

$ ls -l /etc/yum.conf
lrwxrwxrwx. 1 root root 12 Aug 12 09:13 /etc/yum.conf -> dnf/dnf.conf

$ yum --version
4.14.0
  Installed: dnf-0:4.14.0-9.el9.noarch at Mon 12 Aug 2026 09:13:41 PM UTC
  Built    : Red Hat, Inc. <http://bugzilla.redhat.com/bugzilla> at ...
```

`yum` es un symlink de compatibilidad hacia DNF en toda distribución RPM actual (`dnf-3` en EL8/EL9 y Fedora ≤ 40, `dnf5` en Fedora 41+). `/etc/yum.conf` es un symlink a `/etc/dnf/dnf.conf`, y `/etc/yum.repos.d/` sigue siendo el directorio real y canónico de repositorios — DNF no lo movió. La terminología del objetivo de LPI es, por lo tanto, todavía exactamente correcta en un sistema de 2026.

| | yum 3 (EL6/EL7) | dnf 4 (EL8/EL9, Fedora ≤ 40) | dnf5 (Fedora 41+) |
|---|---|---|---|
| Lenguaje | Python 2 | Python 3 + libdnf (C++) | C++ con una capa fina de Python |
| Resolver | depsolver ad-hoc en Python | **libsolv** (SAT) | libsolv |
| Metadatos | `yum.repos.d` + caché propia | librepo, deltas zchunk | librepo, zchunk |
| Estabilidad de la API | ninguna | `libdnf` | `libdnf5` |
| Descargas paralelas | no | `max_parallel_downloads` (≤ 20) | sí, por defecto más alto |
| `history undo` | parcial | transaccional completo | completo |
| Modularidad | no | sí (AppStream) | obsoleta |
| Comportamiento ante lo irresoluble | elige algo | **falla por defecto** (`best=True`) | falla |

El pasaje de un depsolver heurístico a un solver SAT es el cambio más consecuente. yum 3 producía alegremente una transacción parcialmente satisfactoria; libsolv o demuestra que existe una solución o reporta la cláusula insatisfacible exacta. Por eso los mensajes de error de EL8+ nombran al proveedor conflictivo específico en lugar de "nothing to do".

### 4.2 Metadatos de repositorio

```
$ curl -s https://mirror.acme.internal/rocky/9/BaseOS/x86_64/os/repodata/repomd.xml | head -32
<?xml version="1.0" encoding="UTF-8"?>
<repomd xmlns="http://linux.duke.edu/metadata/repo"
        xmlns:rpm="http://linux.duke.edu/metadata/rpm">
  <revision>1755993601</revision>
  <data type="primary">
    <checksum type="sha256">7b1e...c4a9</checksum>
    <open-checksum type="sha256">21fd...9e70</open-checksum>
    <location href="repodata/7b1e...c4a9-primary.xml.gz"/>
    <timestamp>1755993601</timestamp>
    <size>2841923</size>
    <open-size>28419230</open-size>
  </data>
  <data type="filelists">
    <checksum type="sha256">9a02...b311</checksum>
    <location href="repodata/9a02...b311-filelists.xml.gz"/>
    <size>18402911</size>
  </data>
  <data type="other">
    ...
  </data>
  <data type="updateinfo">
    <checksum type="sha256">c73d...1f88</checksum>
    <location href="repodata/c73d...1f88-updateinfo.xml.gz"/>
  </data>
</repomd>
```

| Archivo de metadatos | Contiene | Se descarga cuando |
|---|---|---|
| `repomd.xml` | índice + checksums de todo lo de abajo; la raíz de confianza **firmada** (`repomd.xml.asc`) | siempre |
| `primary.xml.gz` | NEVRA, dependencias, summary, ubicación, tamaño | siempre |
| `filelists.xml.gz` | cada ruta de archivo de cada paquete | bajo demanda (`dnf provides`, dependencias basadas en archivos) |
| `other.xml.gz` | changelogs | bajo demanda (`dnf changelog`) |
| `updateinfo.xml.gz` | errata: IDs de advisory, severidad, mapeo de CVE | para `dnf updateinfo` / `--security` |
| `modules.yaml.gz` | streams de módulos AppStream | si el repo es modular |
| `comps.xml` | grupos / entornos | `dnf group` |

**Trampa de producción:** `filelists` es enorme y se trae de forma perezosa. En dnf5 y en algunas imágenes mínimas no se trae en absoluto salvo que se configure, así que `dnf provides /usr/bin/foo` no devuelve nada para paquetes que no están instalados. Forzalo:

```
$ dnf --setopt=optional_metadata_types=filelists provides /usr/bin/htpasswd
```

`updateinfo` es lo que hace auditable el parcheo de seguridad — y es exactamente lo que un mirror ingenuo hecho con `createrepo_c` descarta silenciosamente. Si tu mirror interno no tiene `updateinfo.xml`, entonces `dnf update --security` en cada host de tu flota es un no-op que reporta éxito.

### 4.3 `/etc/dnf/dnf.conf` (`/etc/yum.conf`) — configuración de producción anotada

```ini
# /etc/dnf/dnf.conf  (== /etc/yum.conf via symlink)
# Fleet baseline — managed by Ansible, do not edit by hand.

[main]
# --- integrity -------------------------------------------------------------
gpgcheck=1                     # verify package signatures (never disable)
localpkg_gpgcheck=1            # also verify local .rpm files passed on the CLI
repo_gpgcheck=1                # verify repomd.xml.asc — signs the METADATA,
                               # closing the "valid old package, replayed" hole

# --- determinism -----------------------------------------------------------
best=1                         # fail loudly rather than install an older version
obsoletes=1                    # honour Obsoletes: on upgrade
install_weak_deps=0            # servers: do not pull Recommends: (smaller
                               # attack surface, reproducible image size)
skip_if_unavailable=0          # a dead mirror must FAIL the run, not silently
                               # produce an under-patched host
clean_requirements_on_remove=1 # remove orphaned deps with their parent

# --- kernels ---------------------------------------------------------------
installonly_limit=3            # keep N kernels: current + 2 rollback targets
protect_running_kernel=1       # never let a transaction remove the running kernel

# --- performance -----------------------------------------------------------
max_parallel_downloads=10      # hard max is 20
fastestmirror=0                # deterministic mirror order beats micro-optimising;
                               # set to 1 only on roaming laptops
keepcache=0                    # do not retain .rpm bodies (disk on 4k nodes)
metadata_expire=6h             # how long cached metadata is considered fresh
timeout=30
retries=5
minrate=10k                    # abort a stalled mirror instead of hanging forever
throttle=0

# --- safety nets -----------------------------------------------------------
exclude=kernel* kmod-*         # kernels move only in a dedicated change window;
                               # override per-run with --disableexcludes=main
protected_packages=dnf,systemd,glibc,kernel-core,sudo,openssh-server
tsflags=nodocs                 # container images / minimal servers

# --- observability ---------------------------------------------------------
logdir=/var/log
history_record=1
debuglevel=2
errorlevel=2
assumeyes=0                    # NEVER globally; use -y per invocation

# --- proxy (egress-restricted estates) -------------------------------------
#proxy=http://proxy.acme.internal:3128
#proxy_auth_method=none
#sslverify=1
#sslcacert=/etc/pki/ca-trust/source/anchors/acme-root.pem
```

| Opción | Por defecto | Por qué el valor de producción difiere |
|---|---|---|
| `skip_if_unavailable` | `False` (EL8+) | Dejalo en `0`. `1` convierte un mirror roto en una corrida *exitosa* que no instaló nada — la causa más común de hosts "parcheados" que no lo están. |
| `install_weak_deps` | `True` | `0` en servidores: `Recommends:` arrastra herramientas que nadie auditó. Cuesta algo de comodidad en workstations. |
| `best` | `True` (EL8+) | Dejalo en `1`. `0` baja silenciosamente a lo que sea resoluble, produciendo una flota con versiones heterogéneas. |
| `keepcache` | `False` | `0` en nodos; `1` en hosts de build donde re-descargar es el cuello de botella. |
| `metadata_expire` | `48h` (por defecto del repo) | `6h` para repos internos en una LAN rápida; `-1`/`never` para un content view **fijado**, que es como conseguís builds de imagen reproducibles. |
| `installonly_limit` | `3` | Por debajo de 2 perdés el rollback de kernel. Por encima de 4 agotás `/boot` con el particionado por defecto. |
| `tsflags=nodocs` | sin definir | Ahorra 100–300 MB por imagen; rompe `man` en el host — nunca en un bastión. |

### 4.4 `/etc/yum.repos.d/*.repo` — definición completa de repositorio

```ini
# /etc/yum.repos.d/acme-platform.repo
# ACME internal platform repositories. Managed by Ansible; local edits are reverted.
#
# Variables expanded by dnf:
#   $releasever  -> 9        (from system-release provides, or /etc/dnf/vars/releasever)
#   $basearch    -> x86_64
#   $arch        -> x86_64
#   $infra       -> stock
#   custom vars  -> any file in /etc/dnf/vars/<name>, content is the value
#                   here: /etc/dnf/vars/acmeenv contains "prod" or "stage"

[acme-platform-baseos]
name=ACME Platform - BaseOS $releasever - $basearch ($acmeenv)
baseurl=https://depot.acme.internal/pulp/content/$acmeenv/rocky/$releasever/BaseOS/$basearch/os/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-ACME-Platform
       file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
priority=10
metadata_expire=6h
skip_if_unavailable=0
sslverify=1
sslcacert=/etc/pki/ca-trust/source/anchors/acme-root.pem
sslclientcert=/etc/pki/entitlement/node.pem
sslclientkey=/etc/pki/entitlement/node-key.pem
countme=0
timeout=30
retries=5
minrate=10k

[acme-platform-appstream]
name=ACME Platform - AppStream $releasever - $basearch ($acmeenv)
baseurl=https://depot.acme.internal/pulp/content/$acmeenv/rocky/$releasever/AppStream/$basearch/os/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-ACME-Platform
       file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
priority=10
metadata_expire=6h
skip_if_unavailable=0

# Internally built packages. Higher priority (lower number) so an internal
# rebuild of an upstream package always wins the solve.
[acme-internal]
name=ACME Internal Packages - $basearch
baseurl=https://depot.acme.internal/pulp/content/$acmeenv/acme-internal/$releasever/$basearch/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-ACME-Platform
priority=5
metadata_expire=1h
skip_if_unavailable=0

# Source RPMs — disabled by default, enabled on demand for `dnf download --source`
# and for reproducing a vendor build during incident analysis.
[acme-platform-source]
name=ACME Platform - Sources $releasever
baseurl=https://depot.acme.internal/pulp/content/$acmeenv/rocky/$releasever/BaseOS/source/tree/
enabled=0
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9

# Third-party vendor repo, tightly fenced: it may ONLY provide its own packages.
# Without `includepkgs`, a vendor Obsoletes: line can replace a system package.
[vendor-observability]
name=Vendor Observability Agent
baseurl=https://depot.acme.internal/pulp/content/$acmeenv/vendor-observability/$releasever/$basearch/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-VENDOR-OBS
priority=20
includepkgs=vendor-agent vendor-agent-plugins-* 
exclude=glibc* openssl* systemd*
skip_if_unavailable=1
```

| Clave del `.repo` | Propósito | Nota de producción |
|---|---|---|
| `[id]` | id del repo usado por `--repo`, `--enablerepo` | mantenelo estable; aparece en cada línea de log |
| `name` | etiqueta humana | incluí entorno + arquitectura; es lo que lee el operador |
| `baseurl` | lista explícita de URLs (separadas por espacio/salto de línea para failover) | **preferilo por sobre `mirrorlist`** por determinismo |
| `metalink`/`mirrorlist` | lista dinámica de mirrors | no reproducible; inadecuado para builds fijados |
| `enabled` | 0/1 | mantené los repos riesgosos en 0, habilitalos por comando |
| `gpgcheck` | verifica las firmas de **paquete** | siempre 1 |
| `repo_gpgcheck` | verifica los **metadatos** (`repomd.xml.asc`) | cierra el agujero de replay de metadatos; requiere que el depot firme los metadatos |
| `gpgkey` | URI(s) de clave, `file://` o `https://` | distribuí las claves vía un paquete, no las traigas por HTTP plano |
| `priority` | gana el número más bajo (requiere la semántica de `dnf-plugin-priorities`, integrada en libdnf) | interno < distro < proveedor |
| `includepkgs` / `exclude` | listas de permitidos/denegados por repo | la valla correcta para repos de terceros |
| `module_hotfixes` | permite que un repo no modular anule un stream de módulo | requerido por muchos repos de proveedores en EL8 |
| `cost` | desempate cuando la prioridad es igual (por defecto 1000) | preferí los mirrors locales |
| `countme` | envía un contador anónimo semanal | poné `0` en entornos restringidos |
| `skip_if_unavailable` | tolera que este repo esté caído | `1` solo para repos genuinamente opcionales |

Gestionar repos desde la CLI en lugar de editando archivos:

```
$ sudo dnf config-manager --add-repo https://depot.acme.internal/acme-internal.repo
Adding repo from: https://depot.acme.internal/acme-internal.repo

$ sudo dnf config-manager --set-disabled vendor-observability
$ sudo dnf config-manager --set-enabled acme-platform-source

$ dnf repolist
repo id                       repo name
acme-internal                 ACME Internal Packages - x86_64
acme-platform-appstream       ACME Platform - AppStream 9 - x86_64 (prod)
acme-platform-baseos          ACME Platform - BaseOS 9 - x86_64 (prod)
vendor-observability          Vendor Observability Agent

$ dnf repolist --all
repo id                       repo name                                 status
acme-internal                 ACME Internal Packages - x86_64           enabled: 47
acme-platform-appstream       ACME Platform - AppStream 9 - x86_64      enabled: 5,412
acme-platform-baseos          ACME Platform - BaseOS 9 - x86_64         enabled: 1,807
acme-platform-source          ACME Platform - Sources 9                 disabled
vendor-observability          Vendor Observability Agent               enabled: 12

$ dnf repoinfo acme-internal
Repo-id            : acme-internal
Repo-name          : ACME Internal Packages - x86_64
Repo-status        : enabled
Repo-revision      : 1755993601
Repo-updated       : Sun 24 Aug 2026 09:20:01 AM UTC
Repo-pkgs          : 47
Repo-available-pkgs: 47
Repo-size          : 312 M
Repo-baseurl       : https://depot.acme.internal/pulp/content/prod/acme-internal/9/x86_64/
Repo-expire        : 3,600 second(s) (last: Sun 24 Aug 2026 10:58:12 AM UTC)
Repo-filename      : /etc/yum.repos.d/acme-platform.repo
```

### 4.5 Instalar, actualizar, eliminar, reinstalar

```
$ sudo dnf install nginx
Last metadata expiration check: 0:03:12 ago on Sun 24 Aug 2026 10:58:12 AM UTC.
Dependencies resolved.
================================================================================
 Package              Arch    Version                  Repository          Size
================================================================================
Installing:
 nginx                x86_64  1:1.20.1-14.el9_2.1      acme-platform-app…  36 k
Installing dependencies:
 nginx-core           x86_64  1:1.20.1-14.el9_2.1      acme-platform-app… 566 k
 nginx-filesystem     noarch  1:1.20.1-14.el9_2.1      acme-platform-app…  10 k
 rocky-logos-httpd    noarch  90.15-2.el9              acme-platform-bas…  25 k

Transaction Summary
================================================================================
Install  4 Packages

Total download size: 637 k
Installed size: 1.9 M
Is this ok [y/N]: y
Downloading Packages:
(1/4): nginx-filesystem-1.20.1-14.el9_2.1.noa…  92 kB/s |  10 kB     00:00
(2/4): nginx-1.20.1-14.el9_2.1.x86_64.rpm      312 kB/s |  36 kB     00:00
(3/4): rocky-logos-httpd-90.15-2.el9.noarch.…  198 kB/s |  25 kB     00:00
(4/4): nginx-core-1.20.1-14.el9_2.1.x86_64.r… 4.1 MB/s | 566 kB     00:00
--------------------------------------------------------------------------------
Total                                          1.2 MB/s | 637 kB     00:00
Running transaction check
Transaction check succeeded.
Running transaction test
Transaction test succeeded.
Running transaction
  Preparing        :                                                        1/1
  Installing       : nginx-filesystem-1:1.20.1-14.el9_2.1.noarch            1/4
  Installing       : rocky-logos-httpd-90.15-2.el9.noarch                   2/4
  Installing       : nginx-core-1:1.20.1-14.el9_2.1.x86_64                  3/4
  Installing       : nginx-1:1.20.1-14.el9_2.1.x86_64                       4/4
  Running scriptlet: nginx-1:1.20.1-14.el9_2.1.x86_64                       4/4
  Verifying        : nginx-1:1.20.1-14.el9_2.1.x86_64                       1/4
  Verifying        : nginx-core-1:1.20.1-14.el9_2.1.x86_64                  2/4
  Verifying        : nginx-filesystem-1:1.20.1-14.el9_2.1.noarch            3/4
  Verifying        : rocky-logos-httpd-90.15-2.el9.noarch                   4/4

Installed:
  nginx-1:1.20.1-14.el9_2.1.x86_64      nginx-core-1:1.20.1-14.el9_2.1.x86_64
  nginx-filesystem-1:1.20.1-14.el9_2.1.noarch  rocky-logos-httpd-90.15-2.el9.noarch

Complete!
```

Leé las cuatro fases: **transaction check** (cierre de dependencias), **transaction test** (simulacro contra el filesystem real — conflictos de archivos, espacio en disco), **transaction** (escrituras reales) y **verify** (relectura del rpmdb). Una falla en "transaction test" no cambió nada en disco; una falla dentro de "Running transaction" deja un estado parcialmente aplicado que `dnf history` puede deshacer.

La superficie completa de verbos:

| Verbo | Semántica |
|---|---|
| `install <pkg\|NEVRA\|file.rpm\|@group>` | instala; en EL8+ también actualiza si ya está presente |
| `reinstall <pkg>` | vuelve a colocar el mismo NEVRA — repara archivos borrados/modificados |
| `upgrade [pkg]` | actualiza los paquetes nombrados, o todo |
| `upgrade-minimal` | solo hasta la versión que corrige el advisory más reciente |
| `downgrade <pkg>` | pasa a la versión anterior disponible |
| `distro-sync` | fuerza a cada paquete a *exactamente* lo que ofrecen los repos, para arriba o para abajo |
| `remove` / `erase` | elimina + dependencias huérfanas (`clean_requirements_on_remove`) |
| `autoremove` | elimina todos los paquetes que ya no requiere un paquete instalado por el usuario |
| `swap <old> <new>` | reemplazo atómico de paquetes en conflicto |
| `mark install\|remove\|group` | reescribe la marca "instalado por el usuario vs dependencia" |
| `module enable\|disable\|reset\|install` | streams de módulos AppStream (EL8/EL9) |
| `check` | consistencia del rpmdb (dependencias, duplicados, obsoletes) |
| `history` | list/info/undo/redo/rollback/userinstalled |
| `needs-restarting` | qué procesos en ejecución usan librerías borradas/actualizadas |

```
# Repair a tampered binary — the correct alternative to rpm2cpio surgery:
$ sudo dnf reinstall curl
...
Reinstalled:
  curl-7.76.1-29.el9_4.x86_64
Complete!

# Version-explicit install (idempotent, reproducible):
$ sudo dnf install -y nginx-1:1.20.1-14.el9_2.1

# Security-only patching:
$ sudo dnf updateinfo list --security
RLSA-2026:5544 Important/Sec. openssl-1:3.0.7-27.el9_4.x86_64
RLSA-2026:5601 Moderate/Sec.  curl-7.76.1-31.el9_4.x86_64

$ sudo dnf upgrade --security --bugfix -y

$ sudo dnf upgrade --advisory=RLSA-2026:5544 -y
$ sudo dnf upgrade --cve=CVE-2026-2511 -y

# What must be restarted after a library upgrade:
$ sudo dnf needs-restarting -r
Core libraries or services have been updated since boot-up:
  * openssl

Reboot is required to fully utilize these updates.
More information: https://access.redhat.com/solutions/27943

$ sudo dnf needs-restarting -s
systemd-journald.service
sshd.service
nginx.service
```

### 4.6 Consultas: `dnf repoquery` y `dnf provides`

`rpm -q` solo ve lo que está instalado. `dnf repoquery` consulta los metadatos de repositorio — instalado o no — y es la herramienta para análisis de impacto.

```
# Which package provides a file that is NOT installed yet?
$ dnf provides /usr/bin/htpasswd
Last metadata expiration check: 0:12:41 ago on Sun 24 Aug 2026 10:58:12 AM UTC.
httpd-tools-2.4.53-11.el9_2.5.x86_64 : Tools for use with the Apache HTTP Server
Repo        : acme-platform-appstream
Matched from:
Filename    : /usr/bin/htpasswd

# Glob works, and is the form you want when the path is uncertain:
$ dnf provides '*/kubectl'
kubernetes-client-1.29.4-1.el9.x86_64 : Kubernetes client tools
Repo        : acme-internal
Matched from:
Filename    : /usr/bin/kubectl

# Blast radius: what breaks if I remove openssl-libs?
$ dnf repoquery --installed --whatrequires 'libcrypto.so.3()(64bit)' | head
curl-7.76.1-29.el9_4.x86_64
openssh-8.7p1-38.el9.x86_64
openssh-clients-8.7p1-38.el9.x86_64
openssh-server-8.7p1-38.el9.x86_64
python3-cryptography-36.0.1-4.el9.x86_64
systemd-252-32.el9_4.7.x86_64

# Full dependency tree with resolved providers:
$ dnf repoquery --requires --resolve nginx
nginx-core-1:1.20.1-14.el9_2.1.x86_64
nginx-filesystem-1:1.20.1-14.el9_2.1.noarch
openssl-libs-1:3.0.7-27.el9_4.x86_64
pcre2-10.40-5.el9.x86_64
rocky-logos-httpd-90.15-2.el9.noarch
systemd-252-32.el9_4.7.x86_64
zlib-1.2.11-40.el9.x86_64

# Recursive closure — what a fresh install really pulls in:
$ dnf repoquery --requires --resolve --recursive nginx | wc -l
94

# Files a non-installed package would deliver:
$ dnf repoquery -l httpd-tools
/usr/bin/ab
/usr/bin/htcacheclean
/usr/bin/htdbm
/usr/bin/htdigest
/usr/bin/htpasswd
/usr/share/man/man1/ab.1.gz
...

# Every version available across repos:
$ dnf repoquery --showduplicates openssl
openssl-1:3.0.1-43.el9.x86_64          acme-platform-baseos
openssl-1:3.0.7-24.el9.x86_64          acme-platform-baseos
openssl-1:3.0.7-27.el9.x86_64          acme-platform-baseos
openssl-1:3.0.7-27.el9_4.x86_64        acme-platform-baseos

# Orphans and duplicates — the fleet hygiene pair:
$ dnf repoquery --unneeded
$ dnf repoquery --duplicates
$ dnf repoquery --extras           # installed but in NO repo => unaccounted for
acme-metrics-agent-2.4.0-1.el9.x86_64
custom-hotfix-glibc-2.34-83.el9.x86_64

# Exact download URL, for air-gapped staging:
$ dnf repoquery --location nginx
https://depot.acme.internal/pulp/content/prod/rocky/9/AppStream/x86_64/os/Packages/n/nginx-1.20.1-14.el9_2.1.x86_64.rpm

# Custom formatting for inventory pipelines:
$ dnf repoquery --qf '%{name},%{evr},%{arch},%{reponame},%{size}' --installed \
    | sort > /var/tmp/pkg-inventory.csv
```

`dnf repoquery --extras` es el comando de auditoría más valioso en un host de larga vida: lista los paquetes instalados desde un repo que ya no los ofrece — repos de proveedores dados de baja, RPMs instalados a mano, y todo lo que un respondedor de incidentes dejó caer durante una caída y nunca eliminó.

### 4.7 `dnf history` — el libro mayor de transacciones

```
$ sudo dnf history
ID     | Command line                | Date and time    | Action(s)      | Altered
-------------------------------------------------------------------------------
    14 | upgrade --security -y       | 2026-08-24 11:41 | Upgrade        |    7
    13 | install nginx               | 2026-08-24 11:02 | Install        |    4
    12 | remove httpd                | 2026-08-24 10:55 | Removed        |    9
    11 | install httpd               | 2026-08-22 16:20 | Install        |    9
     1 | -y install @core            | 2026-08-12 09:13 | Install        |  412

$ sudo dnf history info 13
Transaction ID : 13
Begin time     : Sun 24 Aug 2026 11:02:35 AM UTC
Begin rpmdb    : 483:1e0d3a9f5c2b7d81e4a0b9c8d7e6f5a4b3c2d1e0
End time       : Sun 24 Aug 2026 11:02:41 AM UTC (6 seconds)
End rpmdb      : 487:9f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c
User           : Ops Engineer <opseng>
Return-Code    : Success
Releasever     : 9
Command Line   : install nginx
Comment        : CHG-2026-08-1187 web tier rollout
Packages Altered:
    Install nginx-1:1.20.1-14.el9_2.1.x86_64            @acme-platform-appstream
    Install nginx-core-1:1.20.1-14.el9_2.1.x86_64       @acme-platform-appstream
    Install nginx-filesystem-1:1.20.1-14.el9_2.1.noarch @acme-platform-appstream
    Install rocky-logos-httpd-90.15-2.el9.noarch        @acme-platform-baseos

# Roll a bad transaction back:
$ sudo dnf history undo 14
Dependencies resolved.
================================================================================
 Package        Arch     Version                Repository               Size
================================================================================
Downgrading:
 openssl        x86_64   1:3.0.7-27.el9         acme-platform-baseos    1.2 M
 openssl-libs   x86_64   1:3.0.7-27.el9         acme-platform-baseos    2.1 M
...
Transaction Summary
================================================================================
Downgrade  7 Packages
Is which ok [y/N]:

# Return to the exact state after transaction 12 (replays 13, 14 in reverse):
$ sudo dnf history rollback 12

# Which packages did a human explicitly ask for?  (vs pulled as dependencies)
$ sudo dnf history userinstalled | head
acme-metrics-agent
bash
dnf
nginx
openssh-server
systemd

# Tie every transaction to a change ticket:
$ sudo dnf install -y --comment "CHG-2026-08-1187 web tier rollout" nginx
```

**Límites de `undo` — conocelos antes de depender de él:** revierte el *estado de los paquetes*, no los efectos secundarios. Los datos escritos por scriptlets `%post`, las migraciones de esquema de base de datos que corre un servicio en su primer arranque, y los archivos de configuración reescritos in situ no se revierten. Los archivos `%config(noreplace)` que quedaron como `.rpmnew` siguen siendo `.rpmnew`. Para cualquier cosa con efectos secundarios con estado, el plan de rollback es un snapshot (LVM/Btrfs/`snapper`) o un nodo reconstruido — no `dnf history undo`.

### 4.8 Modularidad (AppStream de EL8/EL9)

```
$ dnf module list nodejs
Name     Stream  Profiles                        Summary
nodejs   18      common [d], development, minimal, s2i   Javascript runtime
nodejs   20 [e]  common [d] [i], development, minimal, s2i  Javascript runtime
nodejs   22      common [d], development, minimal, s2i   Javascript runtime

Hint: [d]efault, [e]nabled, [x]disabled, [i]nstalled

$ sudo dnf module enable nodejs:20 -y
$ sudo dnf module install nodejs:20/common -y
$ sudo dnf module reset nodejs          # clear the stream choice before switching
```

Un stream de módulo es una **restricción global pegajosa** sobre todo el sistema, no una elección por paquete. Habilitar `nodejs:20` impide que los paquetes de `nodejs:22` sean resolubles hasta que hagas `reset`. Un repo de terceros que distribuya un `nodejs` no modular será filtrado por completo salvo que ese repo declare `module_hotfixes=1`. Este es el origen del clásico reporte en EL8: "el paquete está en el repo, `dnf repolist` lo muestra, pero `dnf install` dice No match".

---

## 5. `zypper` — el resolver de SUSE

El mismo `librpm` en la capa 1, el mismo solver SAT `libsolv`, una capa 2 distinta (`libzypp`) y una filosofía de actualización materialmente diferente.

```
$ zypper --version
zypper 1.14.68

$ zypper lr -uEP
Repository priorities in ascending order:
 (98) repo-oss, repo-non-oss   (90) acme-internal   (99) repo-update

# | Alias          | Name                    | Enabled | GPG Check | Refresh | Priority | URI
--+----------------+-------------------------+---------+-----------+---------+----------+----------------------------------------------
1 | acme-internal  | ACME Internal Packages  | Yes     | ( p) Yes  | Yes     |    90    | https://depot.acme.internal/suse/15.6/x86_64/
2 | repo-oss       | Main Repository         | Yes     | (r ) Yes  | Yes     |    98    | http://download.opensuse.org/distribution/leap/15.6/repo/oss/
3 | repo-update    | Main Update Repository  | Yes     | (r ) Yes  | Yes     |    99    | http://download.opensuse.org/update/leap/15.6/oss/
```

La columna GPG Check se lee `(r )` = firma de metadatos del repo verificada, `( p)` = firmas de paquete verificadas, `(rp)` = ambas. **En zypper, gana el número de prioridad más bajo** — la inversa de nada, lo mismo que dnf, pero el valor por defecto es 99 y los admins rutinariamente se equivocan de dirección.

```
# Repository management
$ sudo zypper ar -f -p 90 -n "ACME Internal" \
      https://depot.acme.internal/suse/15.6/x86_64/ acme-internal
$ sudo zypper mr -p 95 acme-internal        # modify priority
$ sudo zypper mr --disable repo-non-oss
$ sudo zypper rr repo-debug                 # remove repo
$ sudo zypper ref                           # refresh metadata
$ sudo zypper ref -f acme-internal          # force full refresh, ignore cache
$ sudo zypper clean -a                      # purge metadata + package cache

# Search and inspect
$ zypper se -s nginx
Loading repository data...
Reading installed packages...

S | Name          | Type    | Version         | Arch   | Repository
--+---------------+---------+-----------------+--------+-------------
i+| nginx         | package | 1.21.6-150600.1 | x86_64 | repo-oss
  | nginx-source  | package | 1.21.6-150600.1 | x86_64 | repo-oss

$ zypper if nginx
Information for package nginx:
------------------------------
Repository     : repo-oss
Name           : nginx
Version        : 1.21.6-150600.1.5
Arch           : x86_64
Vendor         : openSUSE
Installed Size : 1.2 MiB
Installed      : Yes
Status         : up-to-date
Source package : nginx-1.21.6-150600.1.5.src
Summary        : A HTTP server and IMAP/POP3 proxy server
Description    :
    nginx [engine x] is a HTTP server and IMAP/POP3 proxy server ...

# The two file-ownership answers the objective asks for:
$ zypper se --provides --match-exact /usr/sbin/nginx
$ zypper wp /usr/bin/htpasswd
Loading repository data...
Reading installed packages...

S | Name           | Type    | Version              | Arch   | Repository
--+----------------+---------+----------------------+--------+-----------
  | apache2-utils  | package | 2.4.58-150600.3.3    | x86_64 | repo-oss

# Install / remove / update
$ sudo zypper -n in nginx                   # -n == --non-interactive
$ sudo zypper in --oldpackage nginx-1.21.6-150600.1.4
$ sudo zypper rm --clean-deps nginx
$ sudo zypper in -f nginx                   # force reinstall of the same version
$ sudo zypper source-install nginx          # fetch the SRPM + build deps
```

### 5.1 `up` vs `dup` vs `patch` — la distinción que define la operación de SUSE

| Comando | Alcance | Cambio de proveedor | Eliminación de paquetes | Uso correcto |
|---|---|---|---|---|
| `zypper up` | actualiza los paquetes instalados a la versión más nueva **en los mismos repos** | no permitido | nunca elimina | parcheo de rutina dentro de un service pack |
| `zypper patch` | aplica solo los paquetes nombrados por los metadatos de **patch (errata)** | no permitido | nunca | parcheo de seguridad impulsado por compliance |
| `zypper dup` (`dist-upgrade`) | hace que el sistema coincida **exactamente** con los repos habilitados | permitido (`--allow-vendor-change`) | **sí, va a eliminar** | migración de service pack, Tumbleweed rolling |

```
$ sudo zypper lp                              # list-patches
Repository        | Name              | Category | Severity  | Interactive | Status
------------------+-------------------+----------+-----------+-------------+-------
repo-update       | openSUSE-2026-891 | security | important | ---         | needed
repo-update       | openSUSE-2026-902 | security | critical  | reboot      | needed

$ sudo zypper patch --category security --severity critical -y

$ sudo zypper lp --cve
Issue | No.            | Patch            | Category | Severity | Status
------+----------------+------------------+----------+----------+-------
cve   | CVE-2026-2511  | openSUSE-2026-891| security | important| needed

$ sudo zypper patch --cve=CVE-2026-2511

# Running dup by accident is how a Leap host becomes a Tumbleweed host.
$ sudo zypper --non-interactive dup --no-allow-vendor-change
```

`zypper dup` en un sistema con un repo extra de terceros va a *bajar de versión o eliminar* paquetes del proveedor para que el sistema coincida. En Tumbleweed es el único comando de actualización correcto; en Leap/SLE es una operación de migración de service pack. Nunca pongas `zypper dup` en un cron job de un host SLE empresarial.

### 5.2 Capacidades exclusivas de zypper que vale la pena robar conceptualmente

```
# Which running processes use deleted files (post-upgrade restart list)?
$ sudo zypper ps -s
The following running processes use deleted files:

PID   | PPID | UID | User    | Command       | Service
------+------+-----+---------+---------------+----------
1247  | 1    | 0   | root    | nginx         | nginx
1382  | 1    | 0   | root    | sshd          | sshd

You may wish to restart these processes.

# Is my installed stack still within its supported lifecycle?
$ sudo zypper lifecycle
Product end of support
Codestream: openSUSE Leap 15               2026-12-31
    Product: openSUSE Leap 15.6            2026-12-31

Package end of support if different from product:
nodejs18: Now, installed 18.20.4, update available 20.15.1

# Version locks (equivalent of dnf versionlock)
$ sudo zypper al nginx
$ zypper ll
# | Name  | Type    | Repository | Comment
--+-------+---------+------------+--------
1 | nginx | package | (any)      |
$ sudo zypper rl nginx

# Version comparison, exposed as a first-class command:
$ zypper vcmp 1.21.6-150600.1.5 1.21.6-150600.1.4
1.21.6-150600.1.5 is newer than 1.21.6-150600.1.4

# Solver debugging — force a specific resolution branch:
$ sudo zypper in --force-resolution --solver-focus Update nginx
$ sudo zypper in --dry-run --details nginx
```

### 5.3 Tabla de traducción de comandos entre herramientas

| Tarea | `rpm` | `dnf` / `yum` | `zypper` |
|---|---|---|---|
| Instalar desde repo | — | `dnf install foo` | `zypper in foo` |
| Instalar un archivo local | `rpm -ivh f.rpm` | `dnf install ./f.rpm` | `zypper in ./f.rpm` |
| Actualizar un paquete | `rpm -Uvh f.rpm` | `dnf upgrade foo` | `zypper up foo` |
| Actualizar todo | — | `dnf upgrade` | `zypper up` |
| Actualización de distribución | — | `dnf distro-sync` | `zypper dup` |
| Parche solo de seguridad | — | `dnf upgrade --security` | `zypper patch --category security` |
| Reinstalar | `rpm -ivh --replacepkgs` | `dnf reinstall foo` | `zypper in -f foo` |
| Bajar de versión | `rpm -Uvh --oldpackage` | `dnf downgrade foo` | `zypper in --oldpackage foo-1.2` |
| Eliminar | `rpm -e foo` | `dnf remove foo` | `zypper rm foo` |
| Eliminar + huérfanos | — | `dnf remove foo` (por defecto) | `zypper rm --clean-deps foo` |
| Listar instalados | `rpm -qa` | `dnf list --installed` | `zypper se -i` |
| Info del paquete | `rpm -qi foo` | `dnf info foo` | `zypper info foo` |
| Archivos de un pkg instalado | `rpm -ql foo` | `dnf repoquery -l foo` | `rpm -ql foo` |
| Archivos de un archivo `.rpm` | `rpm -qlp f.rpm` | — | — |
| Dueño de un archivo | `rpm -qf /path` | `dnf provides /path` | `zypper se --provides /path` |
| Proveedor de un archivo (no instalado) | — | `dnf provides '*/bin/foo'` | `zypper wp /bin/foo` |
| Dependencias | `rpm -qR foo` | `dnf repoquery --requires --resolve foo` | `zypper info --requires foo` |
| Dependencias inversas | `rpm -q --whatrequires cap` | `dnf repoquery --whatrequires cap` | `zypper se --requires cap` |
| Verificar archivos | `rpm -V foo` | `dnf reinstall foo` (reparar) | `rpm -V foo` |
| Verificar integridad de dependencias | `rpm -Va --nofiles` | `dnf check` | `zypper verify` |
| Verificar firma | `rpm -K f.rpm` | `dnf install` (gpgcheck) | `zypper in` (gpgcheck) |
| Importar clave | `rpm --import KEY` | `rpm --import KEY` | `rpm --import KEY` |
| Listar repos | — | `dnf repolist -v` | `zypper lr -u` |
| Refrescar metadatos | — | `dnf makecache` | `zypper ref` |
| Limpiar caché | — | `dnf clean all` | `zypper clean -a` |
| Historial | `rpm -qa --last` | `dnf history` | `/var/log/zypp/history` |
| Rollback | — | `dnf history undo N` | `snapper rollback` |
| Extraer sin instalar | `rpm2cpio f.rpm \| cpio -idmv` | — | — |

---

## 6. Manifiestos de producción completos

### 6.1 Archivo spec de RPM — un paquete de servicio moderno, completamente válido

```spec
# acme-metrics-agent.spec
# Builds with: rpmbuild -ba acme-metrics-agent.spec
# Lints  with: rpmlint acme-metrics-agent.spec

Name:           acme-metrics-agent
Version:        2.5.0
Release:        1%{?dist}
Summary:        ACME fleet metrics collection agent

License:        Apache-2.0
URL:            https://git.acme.internal/platform/metrics-agent
Source0:        %{url}/-/archive/v%{version}/metrics-agent-v%{version}.tar.gz
Source1:        %{name}.service
Source2:        %{name}.sysusers
Source3:        %{name}.yaml
Source4:        %{name}.logrotate

BuildRequires:  golang >= 1.21
BuildRequires:  systemd-rpm-macros
BuildRequires:  systemd-devel
BuildRequires:  make
BuildRequires:  git-core

# Auto-generated soname deps cover the shared libraries; these are the
# capabilities the auto-generator cannot see.
Requires:       systemd
Requires(pre):  shadow-utils
Recommends:     logrotate
# Boolean dependency (rpm >= 4.13): only pull the SELinux policy on a system
# that actually enforces SELinux.
Requires:       (%{name}-selinux if selinux-policy-targeted)
# This package supersedes the retired collector. Bounded, so a future rebuild
# of legacy-collector 3.x is not silently eaten.
Obsoletes:      legacy-collector < 3.0
Provides:       fleet-metrics-collector = %{version}-%{release}

%description
acme-metrics-agent collects host, container and systemd unit metrics and
exposes them on a local Prometheus scrape endpoint. It runs as an unprivileged
system user under a hardened systemd unit with a read-only root filesystem and
a restricted system call filter.

Configuration lives in %{_sysconfdir}/acme/metrics-agent.yaml and is marked
%%config(noreplace): local edits survive upgrades, and the packaged version is
written alongside as .rpmnew when it changes.

%package selinux
Summary:        SELinux policy module for %{name}
BuildArch:      noarch
Requires:       selinux-policy-targeted
Requires(post): policycoreutils
BuildRequires:  selinux-policy-devel

%description selinux
SELinux policy module confining %{name} to its own domain.

%prep
%autosetup -n metrics-agent-v%{version}

%build
export CGO_ENABLED=1
export GOFLAGS="-trimpath -mod=vendor"
go build \
    -ldflags "-X main.version=%{version}-%{release} -linkmode=external" \
    -o %{name} ./cmd/agent

%install
install -Dpm 0755 %{name}                %{buildroot}%{_bindir}/%{name}
install -Dpm 0644 %{SOURCE1}             %{buildroot}%{_unitdir}/%{name}.service
install -Dpm 0644 %{SOURCE2}             %{buildroot}%{_sysusersdir}/%{name}.conf
install -Dpm 0640 %{SOURCE3}             %{buildroot}%{_sysconfdir}/acme/metrics-agent.yaml
install -Dpm 0644 %{SOURCE4}             %{buildroot}%{_sysconfdir}/logrotate.d/%{name}

install -dm 0750 %{buildroot}%{_localstatedir}/log/acme
install -dm 0750 %{buildroot}%{_sharedstatedir}/acme-metrics-agent

# %ghost: the file is OWNED by the package (so `rpm -qf` answers, and removal
# cleans it up) but is NOT shipped in the payload — it is created at runtime.
touch %{buildroot}%{_localstatedir}/log/acme/agent.log

%check
go test ./... -count=1

%pre
# Fallback for systems without systemd-sysusers; on modern systems the
# sysusers.d file is processed by %sysusers_create_compat below.
getent group acme-metrics >/dev/null || groupadd -r acme-metrics
getent passwd acme-metrics >/dev/null || \
    useradd -r -g acme-metrics -d %{_sharedstatedir}/acme-metrics-agent \
            -s /sbin/nologin -c "ACME metrics agent" acme-metrics
exit 0

%post
%sysusers_create_compat %{SOURCE2}
%systemd_post %{name}.service

%preun
%systemd_preun %{name}.service

%postun
# Restart the running daemon on upgrade ($1 >= 1); do nothing on final erase.
%systemd_postun_with_restart %{name}.service

%posttrans
# Runs once, after every package in the transaction is installed.
if [ -x %{_bindir}/systemctl ]; then
    %{_bindir}/systemctl daemon-reload >/dev/null 2>&1 || :
fi

%post selinux
semodule -n -i %{_datadir}/selinux/packages/%{name}/%{name}.pp.bz2
if selinuxenabled; then
    load_policy
    restorecon -R %{_bindir}/%{name} %{_localstatedir}/log/acme || :
fi

%files
%license LICENSE
%doc README.md docs/OPERATIONS.md
%{_bindir}/%{name}
%{_unitdir}/%{name}.service
%{_sysusersdir}/%{name}.conf
%dir %attr(0750,root,acme-metrics) %{_sysconfdir}/acme
%config(noreplace) %attr(0640,root,acme-metrics) %{_sysconfdir}/acme/metrics-agent.yaml
%config(noreplace) %{_sysconfdir}/logrotate.d/%{name}
%dir %attr(0750,acme-metrics,acme-metrics) %{_localstatedir}/log/acme
%dir %attr(0750,acme-metrics,acme-metrics) %{_sharedstatedir}/acme-metrics-agent
%ghost %attr(0640,acme-metrics,acme-metrics) %{_localstatedir}/log/acme/agent.log

%files selinux
%{_datadir}/selinux/packages/%{name}/%{name}.pp.bz2

%changelog
* Sun Aug 24 2026 ACME Platform <platform@acme.internal> - 2.5.0-1
- Rebase to upstream 2.5.0
- Fix CVE-2026-2511: unauthenticated read of the local scrape endpoint
- Add %%ghost ownership for /var/log/acme/agent.log so removal cleans up

* Wed Aug 12 2026 ACME Platform <platform@acme.internal> - 2.4.0-1
- Initial packaging, replaces legacy-collector
```

`%config` vs `%config(noreplace)` decide qué pasa con un archivo editado por el admin durante una actualización:

| Marcado | Archivo sin modificar en disco | Archivo modificado en disco |
|---|---|---|
| `%config` | reemplazado silenciosamente | el viejo se guarda como `.rpmsave`, **se instala el nuevo archivo** |
| `%config(noreplace)` | reemplazado silenciosamente | **se conserva tu archivo**, el nuevo se escribe como `.rpmnew` |
| sin marcar | reemplazado silenciosamente | **reemplazado silenciosamente — tus ediciones se perdieron** |

Usá siempre `%config(noreplace)` para cualquier cosa que un operador toque, y auditá siempre los remanentes:

```
$ find /etc -name '*.rpmnew' -o -name '*.rpmsave' -o -name '*.rpmorig' 2>/dev/null
/etc/ssh/sshd_config.rpmnew
/etc/nginx/nginx.conf.rpmnew

$ sudo dnf install -y rpmconf && sudo rpmconf -a
```

### 6.2 Ansible — política de repositorios y parcheo para toda la flota

```yaml
---
# roles/rpm_baseline/tasks/main.yml
# Applies the ACME package-management baseline to every EL9 node.
# Idempotent, check-mode safe, and fails loudly on an unreachable depot.

- name: Assert supported platform
  ansible.builtin.assert:
    that:
      - ansible_facts['os_family'] == 'RedHat'
      - ansible_facts['distribution_major_version'] is version('9', '>=')
    fail_msg: "rpm_baseline supports EL9+ only; found {{ ansible_facts['distribution'] }} {{ ansible_facts['distribution_version'] }}"

- name: Install GPG public keys before any repository is defined
  ansible.builtin.copy:
    src: "{{ item }}"
    dest: "/etc/pki/rpm-gpg/{{ item }}"
    owner: root
    group: root
    mode: "0644"
  loop:
    - RPM-GPG-KEY-ACME-Platform
    - RPM-GPG-KEY-Rocky-9
    - RPM-GPG-KEY-VENDOR-OBS
  tags: [rpm, keys]

- name: Import GPG keys into the rpm trust store
  ansible.builtin.rpm_key:
    key: "/etc/pki/rpm-gpg/{{ item }}"
    state: present
  loop:
    - RPM-GPG-KEY-ACME-Platform
    - RPM-GPG-KEY-Rocky-9
    - RPM-GPG-KEY-VENDOR-OBS
  tags: [rpm, keys]

- name: Define the dnf environment variable used in repo URLs
  ansible.builtin.copy:
    content: "{{ acme_env }}\n"
    dest: /etc/dnf/vars/acmeenv
    owner: root
    group: root
    mode: "0644"
  tags: [rpm, repos]

- name: Remove any repository not declared in this role
  ansible.builtin.file:
    path: "/etc/yum.repos.d/{{ item }}"
    state: absent
  loop: "{{ discovered_repo_files.files | map(attribute='path') | map('basename') | reject('in', acme_managed_repo_files) | list }}"
  vars:
    acme_managed_repo_files:
      - acme-platform.repo
  tags: [rpm, repos]

- name: Deploy the managed repository definition
  ansible.builtin.template:
    src: acme-platform.repo.j2
    dest: /etc/yum.repos.d/acme-platform.repo
    owner: root
    group: root
    mode: "0644"
    validate: "/usr/bin/python3 -c \"import configparser,sys; configparser.ConfigParser().read('%s')\""
  notify: Rebuild dnf metadata cache
  tags: [rpm, repos]

- name: Deploy the dnf main configuration
  ansible.builtin.template:
    src: dnf.conf.j2
    dest: /etc/dnf/dnf.conf
    owner: root
    group: root
    mode: "0644"
    backup: true
  tags: [rpm, config]

- name: Verify every configured repository is actually reachable
  ansible.builtin.command:
    cmd: dnf --refresh repolist --assumeno
  register: repolist_check
  changed_when: false
  failed_when: repolist_check.rc != 0
  check_mode: false
  tags: [rpm, verify]

- name: Install the baseline package set
  ansible.builtin.dnf:
    name: "{{ acme_baseline_packages }}"
    state: present
    disable_gpg_check: false
    install_weak_deps: false
  register: baseline_install
  retries: 3
  delay: 15
  until: baseline_install is succeeded
  tags: [rpm, packages]

- name: Pin packages that must not move outside a change window
  ansible.builtin.dnf:
    name: python3-dnf-plugin-versionlock
    state: present
  tags: [rpm, versionlock]

- name: Apply version locks
  ansible.builtin.command:
    cmd: "dnf versionlock add {{ item }}"
  loop: "{{ acme_versionlocked_packages }}"
  register: vlock
  changed_when: "'Adding versionlock on' in vlock.stdout"
  tags: [rpm, versionlock]

- name: Apply security errata only
  ansible.builtin.dnf:
    name: "*"
    state: latest
    security: true
    bugfix: false
    exclude: "{{ acme_patch_exclusions }}"
  register: security_patch
  when: acme_apply_security_patches | bool
  tags: [rpm, patch]

- name: Determine whether a reboot is required
  ansible.builtin.command:
    cmd: dnf needs-restarting -r
  register: needs_reboot
  changed_when: false
  failed_when: needs_reboot.rc not in [0, 1]
  tags: [rpm, patch]

- name: Report packages installed from no known repository
  ansible.builtin.command:
    cmd: dnf repoquery --extras --qf '%{name}-%{evr}.%{arch}'
  register: extras
  changed_when: false
  tags: [rpm, audit]

- name: Fail the audit if unaccounted packages exist on a production node
  ansible.builtin.fail:
    msg: |
      Unaccounted packages present (installed but in no enabled repository):
      {{ extras.stdout_lines | join('\n') }}
  when:
    - acme_env == 'prod'
    - extras.stdout_lines | length > 0
    - extras.stdout_lines | reject('match', acme_extras_allowlist_regex) | list | length > 0
  tags: [rpm, audit]

- name: Run a full package verification and surface content-level drift
  ansible.builtin.shell:
    cmd: |
      set -o pipefail
      rpm -Va --nomtime --nordev 2>/dev/null | grep -E '^..5' || true
    executable: /bin/bash
  register: rpm_verify
  changed_when: false
  tags: [rpm, audit]

- name: Emit a drift warning for modified package content
  ansible.builtin.debug:
    msg: "PACKAGE CONTENT DRIFT on {{ inventory_hostname }}:\n{{ rpm_verify.stdout }}"
  when: rpm_verify.stdout | length > 0
  tags: [rpm, audit]
```

```yaml
---
# roles/rpm_baseline/defaults/main.yml
acme_env: prod
acme_apply_security_patches: true

acme_baseline_packages:
  - dnf-plugins-core
  - dnf-utils
  - createrepo_c
  - rpm-sign
  - yum-utils
  - acme-metrics-agent

# Kernels and the container runtime move only in a dedicated window.
acme_versionlocked_packages:
  - kernel-core-5.14.0-427.28.1.el9_4
  - containerd.io-1.7.18-3.1.el9

acme_patch_exclusions:
  - kernel*
  - kmod-*
  - containerd.io

# Packages legitimately installed outside the repos (build artefacts staged
# by CI). Anything else failing --extras is an incident.
acme_extras_allowlist_regex: '^(acme-ci-scratch|gpg-pubkey)'
```

```yaml
---
# roles/rpm_baseline/handlers/main.yml
- name: Rebuild dnf metadata cache
  ansible.builtin.command:
    cmd: dnf clean metadata && dnf makecache --refresh
  changed_when: true
```

### 6.3 `dnf-automatic` — parcheo de seguridad desatendido

```ini
# /etc/dnf/automatic.conf
# Enabled with: systemctl enable --now dnf-automatic.timer
#
# Three unit variants ship; only ONE may be enabled:
#   dnf-automatic-notifyonly.timer  -> download_updates=no,  apply_updates=no
#   dnf-automatic-download.timer    -> download_updates=yes, apply_updates=no
#   dnf-automatic-install.timer     -> download_updates=yes, apply_updates=yes
# dnf-automatic.timer honours the settings in THIS file.

[commands]
upgrade_type = security       # security | default
random_sleep = 900            # jitter, so 4,000 nodes do not hit the depot at once
network_online_timeout = 300
download_updates = yes
apply_updates = yes           # 'no' on stateful tiers: download only, apply in a window
reboot = when-needed          # never | when-changed | when-needed
reboot_command = "shutdown -r +5 'Rebooting after applying package updates'"

[emitters]
emit_via = motd, stdio        # stdio -> captured by journald -> shipped to Loki
system_name = None

[email]
email_from = dnf-automatic@acme.internal
email_to = platform-oncall@acme.internal
email_host = smtp.acme.internal

[base]
debuglevel = 1
assumeyes = True
```

```
$ sudo systemctl enable --now dnf-automatic.timer
Created symlink /etc/systemd/system/timers.target.wants/dnf-automatic.timer → /usr/lib/systemd/system/dnf-automatic.timer.

$ systemctl list-timers dnf-automatic.timer
NEXT                         LEFT     LAST                         PASSED  UNIT                ACTIVATES
Mon 2026-08-25 06:00:00 UTC  18h left Sun 2026-08-24 06:00:00 UTC  5h ago  dnf-automatic.timer dnf-automatic.service

$ journalctl -u dnf-automatic.service -n 20 --no-pager
Aug 24 06:14:52 web-01 dnf-automatic[2841]: Updates applied on 'web-01.acme.internal':
Aug 24 06:14:52 web-01 dnf-automatic[2841]:  openssl-1:3.0.7-27.el9_4.x86_64
Aug 24 06:14:52 web-01 dnf-automatic[2841]:  openssl-libs-1:3.0.7-27.el9_4.x86_64
```

| Estrategia | Radio de impacto | Rollback | Dónde usarla |
|---|---|---|---|
| `dnf-automatic` con `apply_updates=yes` | un nodo por vez, sin coordinación | `dnf history undo` | capas web/worker sin estado |
| `dnf-automatic` solo descarga + aplicación en ventana | controlado | `dnf history undo` | bases de datos, servicios con estado |
| Push por gestión de configuración (Ansible/Puppet) | orquestado, con canarios | volver a correr con NEVRA fijado | la mayoría de las flotas empresariales |
| Reconstrucción de imagen (bootc / rpm-ostree) | nulo en tiempo de ejecución | reiniciar en el deployment anterior | flotas inmutables / de borde |

La opción basada en imágenes merece la atención del arquitecto: `rpm-ostree`/`bootc` mueve la transacción desde el host en ejecución al pipeline de build. El nodo nunca corre un solver; baja una imagen precompuesta y firmada y cambia atómicamente a ella, con el deployment anterior retenido para `rpm-ostree rollback`. Cambiás flexibilidad in situ por la garantía de que cada nodo de una capa es idéntico byte a byte — la propiedad que `rpm -Va` fue inventado para aproximar.

### 6.4 Build de imagen de contenedor — reproducible y mínima

```dockerfile
# Containerfile
# Build: podman build --pull=always -t registry.acme.internal/platform/metrics-agent:2.5.0 .
#
# Reproducibility rules enforced here:
#   1. Pin the base image by DIGEST, never by tag.
#   2. Pin every package to a full NEVRA.
#   3. Point at a frozen content view, not a rolling mirror.
#   4. Verify signatures inside the build; do not disable gpgcheck.

FROM registry.access.redhat.com/ubi9/ubi-minimal@sha256:c3d3f8a3a5c9d3b2e1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d8 AS build

ARG ACME_CONTENT_VIEW=2026-08-24
ARG AGENT_NEVRA=acme-metrics-agent-2.5.0-1.el9.x86_64

COPY acme-platform.repo /etc/yum.repos.d/acme-platform.repo
COPY RPM-GPG-KEY-ACME-Platform /etc/pki/rpm-gpg/RPM-GPG-KEY-ACME-Platform

RUN set -eux; \
    rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-ACME-Platform; \
    sed -i "s/@@CONTENT_VIEW@@/${ACME_CONTENT_VIEW}/g" /etc/yum.repos.d/acme-platform.repo; \
    microdnf install -y \
        --setopt=install_weak_deps=0 \
        --setopt=tsflags=nodocs \
        --setopt=gpgcheck=1 \
        --setopt=best=1 \
        --setopt=skip_if_unavailable=0 \
        --setopt=metadata_expire=never \
        --nodocs \
        "${AGENT_NEVRA}" \
        ca-certificates; \
    microdnf clean all; \
    rm -rf /var/cache/dnf /var/cache/yum /var/lib/dnf/history*; \
    # Prove what was installed and freeze it into the image as a manifest.
    rpm -qa --qf '%{NEVRA}\t%{SIGPGP:pgpsig}\n' | sort > /usr/share/acme-image-manifest.tsv; \
    # Fail the build if ANY installed package is unsigned.
    if rpm -qa --qf '%{NAME} %{SIGPGP:pgpsig}\n' | grep -v '^gpg-pubkey ' | grep -q '(none)'; then \
        echo "FATAL: unsigned package present in image" >&2; exit 1; \
    fi

FROM registry.access.redhat.com/ubi9/ubi-micro@sha256:9a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9

COPY --from=build /usr/bin/acme-metrics-agent            /usr/bin/acme-metrics-agent
COPY --from=build /etc/acme/metrics-agent.yaml           /etc/acme/metrics-agent.yaml
COPY --from=build /usr/share/acme-image-manifest.tsv     /usr/share/acme-image-manifest.tsv
COPY --from=build /etc/pki/ca-trust/extracted            /etc/pki/ca-trust/extracted

USER 65534:65534
EXPOSE 9100
ENTRYPOINT ["/usr/bin/acme-metrics-agent"]
CMD ["--config", "/etc/acme/metrics-agent.yaml"]
```

### 6.5 Pipeline de CI — construir, firmar, verificar, publicar

```yaml
# .gitlab-ci.yml
# Builds an RPM, signs it with the platform key, verifies the signature is
# actually trusted, publishes to Pulp, and regenerates repository metadata.

stages: [build, sign, verify, publish]

variables:
  RPM_TOPDIR: "$CI_PROJECT_DIR/rpmbuild"
  GPG_KEY_NAME: "ACME Platform Signing Key <platform@acme.internal>"
  DEPOT_URL: "https://depot.acme.internal"

.el9: &el9
  image: registry.acme.internal/ci/rpmbuild-el9:latest
  tags: [linux, x86_64]

build:rpm:
  <<: *el9
  stage: build
  script:
    - set -euo pipefail
    - mkdir -p "$RPM_TOPDIR"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
    - cp packaging/*.spec "$RPM_TOPDIR/SPECS/"
    - cp packaging/sources/* "$RPM_TOPDIR/SOURCES/"
    - spectool -g -R --define "_topdir $RPM_TOPDIR" "$RPM_TOPDIR/SPECS/acme-metrics-agent.spec"
    # Install BuildRequires from the spec, resolved by dnf — never hand-maintained.
    - dnf builddep -y "$RPM_TOPDIR/SPECS/acme-metrics-agent.spec"
    - rpmlint "$RPM_TOPDIR/SPECS/acme-metrics-agent.spec"
    - rpmbuild --define "_topdir $RPM_TOPDIR"
               --define "dist .el9"
               -ba "$RPM_TOPDIR/SPECS/acme-metrics-agent.spec"
    - find "$RPM_TOPDIR/RPMS" "$RPM_TOPDIR/SRPMS" -name '*.rpm' -print
  artifacts:
    paths: ["rpmbuild/RPMS/", "rpmbuild/SRPMS/"]
    expire_in: 7 days

sign:rpm:
  <<: *el9
  stage: sign
  needs: ["build:rpm"]
  script:
    - set -euo pipefail
    - echo "$GPG_PRIVATE_KEY" | gpg --batch --import
    - |
      cat > "$HOME/.rpmmacros" <<EOF
      %_gpg_name ${GPG_KEY_NAME}
      %_gpg_digest_algo sha256
      %__gpg_sign_cmd %{__gpg} gpg --batch --pinentry-mode loopback \\
          --passphrase-file /run/secrets/gpg-pass --no-armor \\
          --no-secmem-warning -u "%{_gpg_name}" -sbo %{__signature_filename} %{__plaintext_filename}
      EOF
    - find rpmbuild/RPMS rpmbuild/SRPMS -name '*.rpm' -exec rpmsign --addsign {} +
  artifacts:
    paths: ["rpmbuild/RPMS/", "rpmbuild/SRPMS/"]

verify:signature:
  <<: *el9
  stage: verify
  needs: ["sign:rpm"]
  script:
    - set -euo pipefail
    - rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-ACME-Platform
    - |
      fail=0
      while IFS= read -r pkg; do
        out="$(rpm -K "$pkg")"
        echo "$out"
        # Match the exact success string. "digests OK" alone means UNSIGNED.
        case "$out" in
          *": digests signatures OK") : ;;
          *) echo "FATAL: $pkg is not correctly signed" >&2; fail=1 ;;
        esac
      done < <(find rpmbuild/RPMS -name '*.rpm')
      exit "$fail"
    # Structural sanity: the payload must contain the files the spec promised.
    - rpm -qlp rpmbuild/RPMS/x86_64/acme-metrics-agent-*.rpm | grep -qx /usr/bin/acme-metrics-agent
    - rpm -qp --requires rpmbuild/RPMS/x86_64/acme-metrics-agent-*.rpm
    - rpm -qp --scripts  rpmbuild/RPMS/x86_64/acme-metrics-agent-*.rpm

publish:pulp:
  <<: *el9
  stage: publish
  needs: ["verify:signature"]
  rules:
    - if: '$CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/'
  script:
    - set -euo pipefail
    - |
      for pkg in $(find rpmbuild/RPMS -name '*.rpm'); do
        pulp rpm content upload --file "$pkg" --repository acme-internal
      done
    - pulp rpm repository version --repository acme-internal list --limit 1
    - pulp rpm publication create --repository acme-internal
    - pulp rpm distribution update --name acme-internal-prod \
        --publication "$(pulp rpm publication list --limit 1 --field pulp_href -o json | jq -r '.[0].pulp_href')"
    # Independent post-publish check from a client's point of view.
    - dnf --disablerepo='*' --enablerepo=acme-internal --refresh \
        repoquery --qf '%{nevra}' acme-metrics-agent
```

### 6.6 Levantar un repositorio local a mano

```
$ sudo mkdir -p /srv/repo/acme-internal/9/x86_64/Packages
$ sudo cp *.rpm /srv/repo/acme-internal/9/x86_64/Packages/

$ sudo createrepo_c --update --database --workers 4 \
      --checksum sha256 /srv/repo/acme-internal/9/x86_64/
Directory walk started
Directory walk done - 47 packages
Temporary output repo path: /srv/repo/acme-internal/9/x86_64/.repodata/
Preparing sqlite DBs
Pool started (with 4 workers)
Pool finished

# Attach errata metadata — WITHOUT this, `dnf upgrade --security` is a no-op.
$ sudo modifyrepo_c updateinfo.xml /srv/repo/acme-internal/9/x86_64/repodata/

# Sign the metadata root, so repo_gpgcheck=1 clients can verify it.
$ sudo gpg --detach-sign --armor \
      --local-user "ACME Platform Signing Key" \
      /srv/repo/acme-internal/9/x86_64/repodata/repomd.xml

$ ls /srv/repo/acme-internal/9/x86_64/repodata/repomd.xml*
repomd.xml  repomd.xml.asc

# Mirror an upstream repo for an air-gapped estate, metadata included:
$ sudo dnf reposync --repoid=acme-platform-baseos \
      --download-metadata --newest-only --delete \
      --downloadcomps --remote-time \
      -p /srv/mirror/rocky/9/

# Client-side smoke test before rolling to the fleet:
$ dnf --disablerepo='*' --enablerepo=acme-internal --refresh repolist -v
```

| Backend de repositorio | Firma de metadatos | Promoción por ciclo de vida | Retención/GC | Costo operativo |
|---|---|---|---|---|
| `createrepo_c` + nginx | `gpg --detach-sign` manual | rsync entre directorios | manual | el más bajo; sirve hasta ~50 nodos |
| Pulp 3 | integrada | versiones de repositorio + distribuciones | limpieza automática de huérfanos | medio; guiado por API, el punto justo |
| Katello / Satellite | integrada | content views + entornos de ciclo de vida | integrada | alto; suma registro de hosts y reporte de errata |
| Artifactory / Nexus | integrada | promoción de repos | basada en políticas | alto; se justifica si ya lo corrés para otros formatos |

La propiedad que importa más que cualquier funcionalidad: **¿podés rematerializar el conjunto exacto de paquetes de hace seis meses?** Un mirror simple de `createrepo_c` con `--delete` no puede. Las versiones de repositorio de Pulp y los content views de Katello sí, y eso es lo que hace reproducible un build desde un tag viejo.

### 6.7 Kickstart — selección de paquetes en tiempo de aprovisionamiento

```
# ks-el9-minimal.cfg  (excerpt)
url --url="https://depot.acme.internal/pulp/content/prod/rocky/9/BaseOS/x86_64/os/"

repo --name="appstream" \
     --baseurl="https://depot.acme.internal/pulp/content/prod/rocky/9/AppStream/x86_64/os/" \
     --install
repo --name="acme-internal" \
     --baseurl="https://depot.acme.internal/pulp/content/prod/acme-internal/9/x86_64/" \
     --install --cost=500

%packages --exclude-weakdeps --ignoremissing=no
@^minimal-environment
@core
chrony
dnf-plugins-core
openssh-server
sudo
acme-metrics-agent
-plymouth
-iwl*-firmware
-cockpit*
%end

%post --log=/root/ks-post.log
set -euxo pipefail

# Trust the platform key on first boot, before anything else runs.
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-ACME-Platform

# Prove the build produced what was asked for; halt provisioning if not.
rpm -q acme-metrics-agent chrony openssh-server
rpm -qa --qf '%{NEVRA}\n' | sort > /root/provisioned-manifest.txt

# No unsigned packages may exist on a freshly provisioned node.
if rpm -qa --qf '%{NAME} %{SIGPGP:pgpsig}\n' | grep -v '^gpg-pubkey ' | grep -q '(none)'; then
    echo "FATAL: unsigned package on a fresh install" >&2
    exit 1
fi

systemctl enable dnf-automatic.timer
%end
```

---

## 7. Verificación y diagnóstico de fallas

### 7.1 La escalera de verificación permanente

Corré estas en orden; cada peldaño es barato y cada uno responde una pregunta distinta.

```
# 1. Is the rpmdb itself consistent?
$ sudo rpmdb --verifydb
$ echo $?
0

# 2. Are there unresolved dependencies, duplicates or broken obsoletes?
$ sudo dnf check
No problems found.

# 3. Is any file drifted from what its package shipped?  (content only)
$ sudo rpm -Va --nomtime --nordev 2>/dev/null | grep -E '^..5' 
..5......  c /etc/nginx/nginx.conf

# 4. Are all repositories reachable and fresh?
$ sudo dnf --refresh repolist
$ echo $?
0

# 5. Is every installed package signed by a trusted key?
$ rpm -qa --qf '%{NAME}-%{EVR} %{SIGPGP:pgpsig}\n' | grep -v gpg-pubkey | grep '(none)'

# 6. Is anything installed that no repository can account for?
$ dnf repoquery --extras

# 7. Are there stale kernels / orphans consuming /boot and disk?
$ dnf repoquery --unneeded
$ rpm -q kernel | wc -l

# 8. Are there unmerged config files from past upgrades?
$ find /etc -name '*.rpmnew' -o -name '*.rpmsave' 2>/dev/null

# 9. Do any running processes still map deleted libraries?
$ sudo dnf needs-restarting -s
```

Envuelto en una única auditoría que sale con código distinto de cero ante cualquier hallazgo:

```bash
#!/usr/bin/env bash
# /usr/local/sbin/pkg-audit — exits 0 only if every check is clean.
set -uo pipefail
rc=0
note() { printf '[%s] %s\n' "$1" "$2"; [ "$1" = FAIL ] && rc=1; return 0; }

rpmdb --verifydb                     >/dev/null 2>&1 \
  && note OK   "rpmdb consistent"    || note FAIL "rpmdb inconsistent — see 7.4"

dnf check                            >/dev/null 2>&1 \
  && note OK   "dependency closure"  || note FAIL "dnf check reported problems"

drift=$(rpm -Va --nomtime --nordev 2>/dev/null | grep -E '^..5[^ ]*[^c]' || true)
[ -z "$drift" ] \
  && note OK   "no non-config content drift" \
  || note FAIL "content drift:"$'\n'"$drift"

unsigned=$(rpm -qa --qf '%{NAME}-%{EVR} %{SIGPGP:pgpsig}\n' \
             | grep -v '^gpg-pubkey' | grep '(none)' || true)
[ -z "$unsigned" ] \
  && note OK   "all packages signed" \
  || note FAIL "unsigned packages:"$'\n'"$unsigned"

extras=$(dnf -q repoquery --extras 2>/dev/null || true)
[ -z "$extras" ] \
  && note OK   "no unaccounted packages" \
  || note WARN "installed but in no repo:"$'\n'"$extras"

pending=$(find /etc \( -name '*.rpmnew' -o -name '*.rpmsave' \) 2>/dev/null || true)
[ -z "$pending" ] \
  && note OK   "no unmerged configs" \
  || note WARN "unmerged config files:"$'\n'"$pending"

exit "$rc"
```

```
$ sudo /usr/local/sbin/pkg-audit
[OK]   rpmdb consistent
[OK]   dependency closure
[OK]   no non-config content drift
[FAIL] unsigned packages:
acme-metrics-agent-2.5.0-1.el9 (none)
[WARN] installed but in no repo:
custom-hotfix-glibc-2.34-83.el9.x86_64
[OK]   no unmerged configs
$ echo $?
1
```

### 7.2 Manual de fallas

| Síntoma (textual) | Causa raíz | Diagnóstico | Solución |
|---|---|---|---|
| `Error: GPG check FAILED` | clave no importada, o clave equivocada | `rpm -qa gpg-pubkey*`; `rpm -Kv pkg.rpm` | `rpm --import /etc/pki/rpm-gpg/KEY`; nunca `--nogpgcheck` |
| `Public key for X.rpm is not installed` (NOKEY) | el `gpgkey=` del repo es inalcanzable o falta | `curl -I <gpgkey URL>` | corregir `gpgkey=`, o distribuir las claves vía un paquete |
| `repomd.xml GPG signature verification error` | `repo_gpgcheck=1` pero el depot no firma los metadatos | `curl -sI .../repodata/repomd.xml.asc` | firmar los metadatos en el depot, o quitar `repo_gpgcheck` solo para ese repo |
| `Status code: 404 for .../repodata/repomd.xml` | `$releasever`/`$basearch` equivocado, o el repo se movió | `dnf repolist -v`; `dnf --setopt=... repolist` | corregir `baseurl`; `dnf clean metadata` |
| `Cannot download repomd.xml: Cannot download repodata... All mirrors were tried` | caché rancia después de un cambio de mirror | `ls /var/cache/dnf` | `dnf clean all && dnf makecache` |
| `nothing provides libfoo.so.5()(64bit) needed by bar` | falta un repo, o arquitectura/release equivocada | `dnf repoquery --whatprovides 'libfoo.so.5()(64bit)'` | habilitar el repo correcto; nunca `--nodeps` |
| `package X conflicts with Y` | dos repos distribuyen la misma capacidad | `dnf repoquery --qf '%{name} %{reponame}' --whatprovides <cap>` | cercar el repo de terceros con `includepkgs`/`priority` |
| `Problem: cannot install both A and B` (libsolv) | conflicto genuino | leé la lista numerada de cláusulas de libsolv — nombra los paquetes exactos | `dnf install --allowerasing` solo después de entender el intercambio |
| `file /usr/bin/foo conflicts between attempted installs` | dos paquetes son dueños de una ruta | `rpm -qf`; `dnf repoquery --whatprovides /usr/bin/foo` | corregir el empaquetado; `--replacefiles` es el último recurso |
| `error: rpmdb: BDB0113 Thread ... failed` / `cannot open Packages` | corrupción del rpmdb BDB (EL7/EL8) | `rpmdb --verifydb` | ver §7.4 |
| `Transaction test error: installing package X needs Y MB on the /usr filesystem` | disco lleno | `df -h /usr /var /boot` | liberar espacio; `dnf clean packages`; `dnf remove --oldinstallonly` |
| `Depsolve Error occurred: ... but none of the providers can be installed` | stream de módulo fijado en otra versión | `dnf module list <name>` | `dnf module reset <name>`, y volver a resolver |
| `No match for argument: <pkg>` aunque `dnf repolist` muestre el repo | `includepkgs`/`exclude` lo están filtrando, o no se trajo `filelists` | `dnf repoquery --disableexcludes=all <pkg>` | ajustar el filtro del repo |
| `scriptlet failed, exit status 1` | error en el scriptlet `%post` | `rpm -q --scripts <pkg>`; `journalctl -t <pkg>` | el paquete **queda** registrado como instalado pero a medio configurar — corregir, luego `dnf reinstall` |
| El servicio muere tras la actualización, la config parece correcta | la config fue reemplazada o se ignoró un `.rpmnew` | `find /etc -name '*.rpmnew'`; `rpm -Vc <pkg>` | `rpmconf -a`, mergear, reiniciar |
| `dnf history undo` dice `Transaction history is incomplete` | los paquetes ya no están en ningún repo | `dnf repoquery --showduplicates <pkg>` | restaurar desde un content view anterior del depot |

### 7.3 Leer un error de resolución de dependencias de libsolv

```
$ sudo dnf install acme-metrics-agent-2.5.0
Last metadata expiration check: 0:01:04 ago on Sun 24 Aug 2026 12:11:03 PM UTC.
Error:
 Problem: package acme-metrics-agent-2.5.0-1.el9.x86_64 from acme-internal
          requires libsystemd.so.0(LIBSYSTEMD_252)(64bit), but none of the
          providers can be installed
  - cannot install both systemd-libs-252-32.el9_4.7.x86_64 from acme-platform-baseos
    and systemd-libs-250-12.el9_0.3.x86_64 from @System
  - problem with installed package systemd-libs-250-12.el9_0.3.x86_64
  - package systemd-libs-250-12.el9_0.3.x86_64 from @System is filtered out
    by exclude filtering
(try to add '--skip-broken' to skip uninstallable packages or '--nobest'
 to use not only best candidate packages)
```

Leelo de abajo hacia arriba: la causa terminal está en la **última** línea. Acá `systemd*` está en la lista `exclude=` de `/etc/dnf/dnf.conf`, así que la actualización requerida de `systemd-libs` no puede seleccionarse. La solución no es `--skip-broken` (instala nada silenciosamente) ni `--nobest` (instala silenciosamente un agente más viejo) — es levantar la exclusión para esta transacción, deliberadamente:

```
$ sudo dnf --disableexcludes=main install acme-metrics-agent-2.5.0
```

`--skip-broken` y `--nobest` son los dos flags con más probabilidad de convertir una falla ruidosa en un host subparcheado y silencioso. Tratá a ambos como herramientas solo para incidentes, y nunca los pongas en automatización.

### 7.4 Recuperación de corrupción del rpmdb

```
$ rpm -qa
error: rpmdb: BDB0113 Thread/process 4213/140234 failed: BDB1507 Thread died in Berkeley DB library
error: db5 error(-30973) from dbenv->failchk: BDB0087 DB_RUNRECOVERY: Fatal error, run database recovery
error: cannot open Packages index using db5 - (-30973)
error: cannot open Packages database in /var/lib/rpm

# 1. Back up FIRST. Always. The rpmdb is not reconstructible from anything else.
$ sudo cp -a /var/lib/rpm /var/lib/rpm.bak-$(date +%F-%H%M)

# 2. On a BDB backend, stale environment locks alone can cause this.
$ sudo rm -f /var/lib/rpm/__db.00*
$ rpm -qa | wc -l
487                                   # if this works, you are done

# 3. Otherwise rebuild the indexes from the Packages file.
$ sudo rpm --rebuilddb -vv
D: opening  db environment /var/lib/rpm cdb:mpool
D: opening  db index       /var/lib/rpm/Packages create mode=0x42
...

$ sudo rpmdb --verifydb && rpm -qa | wc -l
487

# 4. Migrate to sqlite so this class of failure cannot recur (EL9+ / Fedora):
$ sudo rpmdb --rebuilddb --define '_db_backend sqlite'
$ rpm --eval '%{_db_backend}'
sqlite

# 5. If Packages itself is destroyed, the DB is unrecoverable in place.
#    Rebuild the host, or reconstruct from an inventory snapshot:
$ sudo rpm --root=/mnt/rescue -qa > /dev/null      # verify the rescue copy first
```

**Nunca** corras `--rebuilddb` sin un backup, y nunca lo corras concurrentemente con una transacción de `dnf`. Tomá el inventario de toda la flota (`rpm -qa --qf ...` hacia almacenamiento de objetos, a diario) *antes* de necesitarlo — es el único artefacto que hace que un rpmdb destruido sea recuperable de otra forma que no sea una reconstrucción.

### 7.5 Diagnosticar "quién cambió este archivo, y cuándo"

```
$ rpm -qf /etc/ssh/sshd_config
openssh-server-8.7p1-38.el9.x86_64

$ rpm -V openssh-server
S.5....T.  c /etc/ssh/sshd_config

$ rpm -q --qf '[%{FILENAMES} %{FILEDIGESTS} %{FILESIZES} %{FILEMTIMES:date}\n]' \
      openssh-server | grep sshd_config
/etc/ssh/sshd_config 3f5c2a...9b71 4416 Wed 24 Jan 2026 02:51:03 PM UTC

$ sha256sum /etc/ssh/sshd_config
8e1d4b...02af  /etc/ssh/sshd_config          # differs => content changed

$ stat -c '%y %U %G %a' /etc/ssh/sshd_config
2026-08-24 03:14:22.481920144 +0000 root root 600

# Recover the packaged original without touching the running config:
$ dnf download openssh-server
$ rpm2cpio openssh-server-8.7p1-38.el9.x86_64.rpm \
    | cpio --to-stdout -i './etc/ssh/sshd_config' > /tmp/sshd_config.pristine
$ diff -u /tmp/sshd_config.pristine /etc/ssh/sshd_config
--- /tmp/sshd_config.pristine    2026-08-24 12:20:11.000000000 +0000
+++ /etc/ssh/sshd_config         2026-08-24 03:14:22.481920144 +0000
@@ -37,7 +37,7 @@
-PermitRootLogin prohibit-password
+PermitRootLogin yes

# Cross-reference with the transaction ledger and the audit log:
$ sudo dnf history list openssh-server
ID     | Command line              | Date and time    | Action(s)  | Altered
--------------------------------------------------------------------------
    14 | upgrade --security -y     | 2026-08-24 11:41 | Upgrade    |    7
$ sudo ausearch -f /etc/ssh/sshd_config -ts 08/24/2026 03:00:00 | tail -20
```

La transacción de las 11:41 es *posterior* al mtime de las 03:14 del archivo — así que el cambio no lo hizo un paquete. Esa única comparación de orden es la diferencia entre "actualización de rutina" y "modificación inexplicada de una configuración de autenticación a las 3 de la mañana".

### 7.6 Limpieza y capacidad

```
# Cache
$ du -sh /var/cache/dnf
1.4G	/var/cache/dnf
$ sudo dnf clean packages       # bodies only, keep metadata
$ sudo dnf clean metadata       # force a metadata refresh on next run
$ sudo dnf clean all            # everything
$ sudo dnf makecache --refresh

# Old kernels — /boot exhaustion is the classic 3 AM page
$ df -h /boot
Filesystem      Size  Used Avail Use% Mounted on
/dev/vda1      1014M  942M   73M  93% /boot
$ rpm -q kernel
kernel-5.14.0-427.13.1.el9_4.x86_64
kernel-5.14.0-427.20.1.el9_4.x86_64
kernel-5.14.0-427.28.1.el9_4.x86_64
kernel-5.14.0-284.30.1.el9_2.x86_64
$ sudo dnf remove --oldinstallonly --setopt installonly_limit=2 -y
$ uname -r                       # confirm the RUNNING kernel survived
5.14.0-427.28.1.el9_4.x86_64

# Orphans
$ sudo dnf autoremove
$ dnf repoquery --unneeded

# Duplicates left by an interrupted transaction
$ dnf repoquery --duplicates
openssl-1:3.0.7-24.el9.x86_64
openssl-1:3.0.7-27.el9_4.x86_64
$ sudo dnf remove --duplicates
```

`sudo dnf remove --oldinstallonly` es seguro porque `protect_running_kernel=1` impide eliminar el kernel arrancado. Verificá con `uname -r` de todos modos — un nodo que arranca en un kernel eliminado es una visita al datacenter.

### 7.7 Transferencia a entornos aislados (air-gapped)

```
# On a connected staging host — resolve the full closure, not just the leaf:
$ dnf download --resolve --alldeps --destdir /srv/staging/nginx-bundle nginx
$ ls /srv/staging/nginx-bundle | head
nginx-1.20.1-14.el9_2.1.x86_64.rpm
nginx-core-1.20.1-14.el9_2.1.x86_64.rpm
nginx-filesystem-1.20.1-14.el9_2.1.noarch.rpm
openssl-libs-3.0.7-27.el9_4.x86_64.rpm
pcre2-10.40-5.el9.x86_64.rpm

$ createrepo_c /srv/staging/nginx-bundle
$ tar czf nginx-bundle.tar.gz -C /srv/staging nginx-bundle
$ sha256sum nginx-bundle.tar.gz > nginx-bundle.tar.gz.sha256

# On the air-gapped host:
$ sha256sum -c nginx-bundle.tar.gz.sha256
nginx-bundle.tar.gz: OK
$ sudo tar xzf nginx-bundle.tar.gz -C /srv/
$ sudo dnf --disablerepo='*' \
           --repofrompath=bundle,file:///srv/nginx-bundle \
           --setopt=bundle.gpgcheck=1 \
           --setopt=bundle.gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9 \
           install nginx
```

---

## 8. Resumen orientado al examen

**Los ocho comandos que tenés que poder escribir sin dudar:**

```
rpm -qa                       # everything installed
rpm -qi <pkg>                 # metadata: version, status, signature
rpm -ql <pkg>                 # what files does this package provide
rpm -qlp <file.rpm>           # ...for a package that is NOT installed
rpm -qf /path/to/file         # which package owns this file
rpm -V <pkg>                  # integrity: has anything changed on disk
rpm -K <file.rpm>             # signature and digest verification
rpm2cpio <file.rpm> | cpio -idmv   # extract without installing
```

**Los cuatro hechos que más se pasan por alto:**

1. `rpm -qp` / `-qlp` consultan un **archivo**; sin `-p` consultás la **base de datos instalada**. Usar el equivocado es el error de examen más común.
2. `rpm -i` rechaza un paquete ya instalado, `rpm -U` actualiza o instala, `rpm -F` actualiza **solo si ya está instalado**.
3. `rpm -e` **no** resuelve dependencias y se va a negar a romperlas; `dnf remove` y `zypper rm` sí resuelven.
4. En la salida de `rpm -K`, `digests OK` significa que el paquete está **sin firmar**; solo `digests signatures OK` significa firmado y confiable.

**Los tres archivos:** `/etc/yum.conf` (→ `/etc/dnf/dnf.conf`) es la política global del resolver; `/etc/yum.repos.d/*.repo` es una sección INI por repositorio; `/var/lib/rpm` (a menudo enlazado a `/usr/lib/sysimage/rpm`) es la base de datos de paquetes — respaldala, nunca la edites.

**La tríada de zypper:** `zypper up` (actualiza dentro de los repos, nunca elimina), `zypper patch` (solo errata), `zypper dup` (hace que el sistema coincida exactamente con los repos — **puede eliminar paquetes**).

---

## 9. Referencias

**LPI**
- LPIC-1 Exam 102 objectives (v5.0), Topic 102.5 — https://www.lpi.org/our-certifications/exam-102-objectives/
- LPIC-1 Exam 101 objectives (v5.0) — https://www.lpi.org/our-certifications/exam-101-objectives/
- LPIC-1 certification overview — https://www.lpi.org/our-certifications/lpic-1-overview/

**RPM**
- RPM project documentation — https://rpm.org/documentation.html
- RPM Packaging Guide (Fedora) — https://rpm-packaging-guide.github.io/
- `rpm(8)` manual — https://man7.org/linux/man-pages/man8/rpm.8.html
- `rpm2cpio(8)` manual — https://man7.org/linux/man-pages/man8/rpm2cpio.8.html
- RPM package file format (v3) — https://rpm-software-management.github.io/rpm/manual/format.html
- RPM tags reference — https://rpm-software-management.github.io/rpm/manual/tags.html
- RPM dependencies and boolean/rich dependencies — https://rpm-software-management.github.io/rpm/manual/dependencies.html
- RPM scriptlet ordering and triggers — https://rpm-software-management.github.io/rpm/manual/triggers.html
- RPM signatures and package verification — https://rpm-software-management.github.io/rpm/manual/signatures_digests.html
- RPM database backends and configuration — https://rpm-software-management.github.io/rpm/manual/dbconfig.html
- Fedora Packaging Guidelines (scriptlets, `%config`, systemd macros) — https://docs.fedoraproject.org/en-US/packaging-guidelines/

**DNF / YUM**
- DNF documentation (dnf 4) — https://dnf.readthedocs.io/en/latest/
- `dnf.conf(5)` — main and repository options — https://dnf.readthedocs.io/en/latest/conf_ref.html
- DNF command reference — https://dnf.readthedocs.io/en/latest/command_ref.html
- DNF core plugins (`config-manager`, `versionlock`, `needs-restarting`, `reposync`, `download`) — https://dnf-plugins-core.readthedocs.io/en/latest/
- DNF5 documentation — https://dnf5.readthedocs.io/en/latest/
- `dnf-automatic` — https://dnf.readthedocs.io/en/latest/automatic.html
- libsolv (SAT dependency solver) — https://github.com/openSUSE/libsolv
- `createrepo_c` — https://github.com/rpm-software-management/createrepo_c
- Red Hat Enterprise Linux 9 — Managing software with the DNF tool — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_software_with_the_dnf_tool/index
- Red Hat Enterprise Linux 9 — Installing and managing software using DNF (AppStream, modules) — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_software_with_the_dnf_tool/managing-versions-of-appstream-content_managing-software-with-the-dnf-tool
- Rocky Linux documentation — https://docs.rockylinux.org/guides/package_management/
- Fedora — DNF system upgrade — https://docs.fedoraproject.org/en-US/quick-docs/dnf-system-upgrade/

**Zypper / SUSE**
- openSUSE — Zypper usage reference — https://en.opensuse.org/SDB:Zypper_usage
- SUSE Linux Enterprise Server 15 — Managing software with command line tools — https://documentation.suse.com/sles/15-SP6/html/SLES-all/cha-sw-cl.html
- `zypper(8)` manual — https://en.opensuse.org/SDB:Zypper_manual
- libzypp — https://github.com/openSUSE/libzypp
- openSUSE — Package signing and GPG keys — https://en.opensuse.org/openSUSE:Package_signing_keys

**Supply chain and repository management**
- Pulp 3 RPM plugin — https://docs.pulpproject.org/pulp_rpm/
- Red Hat Satellite content management — https://docs.redhat.com/en/documentation/red_hat_satellite/
- Red Hat product security — errata and CVE data — https://access.redhat.com/security/data/
- openSUSE / SUSE security advisories — https://www.suse.com/support/update/
- bootc — image-based RPM systems — https://containers.github.io/bootc/
- rpm-ostree — https://coreos.github.io/rpm-ostree/