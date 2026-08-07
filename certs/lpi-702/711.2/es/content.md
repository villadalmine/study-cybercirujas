# Guía de Estudio: LPI 702-100 (v1.0) – Tema 711.2: Software y Gestión de Paquetes BSD

**Certificación Objetivo:** LPI BSD Specialist (Examen 702-100, Versión 1.0)  
**Código del Tema:** 711.2 (BSD Software and Package Management)  
**Peso del Tema:** 6.67  
**Objetivo del Rol:** Principal Platform Architect / Senior Site Reliability Engineer (SRE)

---

## 1. Motivación Arquitectónica y Planteamiento del Problema en Producción

En entornos de producción empresariales, la gestión de software de terceros a través de flotas heterogéneas de BSD (FreeBSD, OpenBSD, NetBSD) requiere balancear dos paradigmas operacionales competidores: **Compilación basada en código fuente** (Ports framework, `pkgsrc`) y **Distribución de paquetes binarios precompilados** (`pkg`, `pkg_add`, `pkgin`).

### Problema de Producción 1: Personalización en Tiempo de Compilación vs. Velocidad de Despliegue
Los mirrors de distribución binaria estándar utilizan builds de paquetes base utilizando selectores (knobs) por defecto en tiempo de compilación. En cargas de trabajo de SRE de alto rendimiento, los binarios genéricos introducen riesgos de seguridad y sobrecarga operacional:
* **Bloat y Superficie de Ataque:** Las compilaciones por defecto a menudo incluyen módulos sin usar (por ejemplo, compilar X11, bindings de GUI o módulos heredados en routers edge headless o microservicios en contenedor).
* **Brechas de Optimización:** Los binarios genéricos pierden extensiones de instrucciones de CPU (`AVX512`, `AES-NI`) y asignadores de memoria personalizados (flags de `jemalloc`, `tcmalloc`) requeridos para servicios de ultra baja latencia.
* **Endurecimiento de Seguridad (Security Hardening):** El cumplimiento empresarial requiere deshabilitar características inseguras (por ejemplo, fallback de SSLv3/TLS1.0, cifrados débiles, manejadores de protocolos innecesarios) de forma global en todos los artefactos construidos.

*Solución Arquitectónica:* Implementar una granja de compilación centralizada y automatizada (por ejemplo, FreeBSD Poudriere o el sistema de bulk build de NetBSD pkgsrc) que convierta ports fuente personalizados en paquetes binarios firmados y fijados por versión para su distribución en toda la flota.

### Problema de Producción 2: Integridad de Paquetes, Deriva de ABI y Seguridad de la Cadena de Suministro
Las tuberías (pipelines) de despliegue de infraestructura moderna deben defenderse contra la manipulación no autorizada de paquetes, la rotura de ABI durante actualizaciones continuas (rolling upgrades) y la exposición a vulnerabilidades de software (CVEs).
* Los sistemas operativos con sistemas base desacoplados y paquetes de terceros (el diseño tradicional de BSD) pueden experimentar desajustes de versiones de librerías (`libssl.so.30` vs `libssl.so.32`) si los paquetes binarios se actualizan de forma asíncrona a través de los nodos.
* Los payloads comprometidos en mirrors de terceros presentan vectores directos de ejecución remota si no están firmados criptográficamente.

*Solución Arquitectónica:* Hacer cumplir la validación de firmas criptográficas (firmas de repositorio RSA/ED25519 en `pkg`, OpenBSD `signify`), mantener repositorios de paquetes locales inmutables y ejecutar escaneos automatizados de CVE (`pkg audit`, `pkg_admin audit`) durante las pipelines de despliegue.

---

## 2. Comparativas Técnicas Profundas y Análisis de Compensaciones (Trade-Offs)

### Tabla 2.1: Marcos de Trabajo para Gestión de Paquetes Binarios en BSD

| Dimensión Técnica | FreeBSD (`pkg` / Next Generation `pkgng`) | OpenBSD (`pkg_add`, `pkg_delete`, `pkg_info`) | NetBSD (`pkgin` sobre `pkg_install`) |
| :--- | :--- | :--- | :--- |
| **Motor de Base de Datos Local** | SQLite3 (`/var/db/pkg/local.sqlite`) | Árbol de metadatos basado en archivos (`/var/db/pkg/`) | Basado en archivos (`/var/db/pkg/`) + SQLite (`pkgin.db`) |
| **Almacenamiento Meta del Repo** | Tarball firmado que contiene `meta.conf`, `packagesite.yaml`, `digests` | Listas de texto en mirror HTTP/FTP vía `installurl` | Base de datos de repositorio comprimida `pkg_summary.gz` |
| **Modelo Criptográfico** | Firmas RSA/Ed25519, pares de claves OpenSSL / SSH | Verificación criptográfica con clave pública `signify(1)` | Verificación de digest GPG / SHA512 vía `pkg_admin` |
| **Mecanismo de Bloqueo** | Flags de bloqueo a nivel de base de datos (`pkg lock`) | Fijación manual de paquetes / congelamiento de versión | Reglas de exclusión en `pkgin.conf` |
| **Resolución de Dependencias** | Solucionador avanzado (motor solucionador basado en SAT) | Parser secuencial determinista (`pkg_add -u`) | Solucionador de grafo de dependencias utilizando caché local SQLite |
| **Guardarraíles de ABI** | Fuerza la coincidencia de versión del kernel/userland del SO (cadena `ABI`) | Fuerza la coincidencia precisa de la etiqueta de release del SO (`%M`) | Usa `PKGPATH` y verificaciones explícitas de versión de librerías |

### Tabla 2.2: Marcos de Compilación Basados en Código Fuente

| Característica / Arquitectura | FreeBSD Ports (`/usr/ports`) | OpenBSD Ports (`/usr/ports`) | NetBSD `pkgsrc` (`/usr/pkgsrc`) |
| :--- | :--- | :--- | :--- |
| **Archivo Principal de Build** | `Makefile` + `bsd.port.mk` | `Makefile` + `bsd.port.mk` | `Makefile` + `mk/bsd.pkg.mk` |
| **Archivo de Ajustes Globales** | `/etc/make.conf` | `/etc/mk.conf` | `/etc/mk.conf` |
| **Soporte Multiplataforma** | Centrado en FreeBSD (DragonFly BSD limitado) | Centrado en OpenBSD | Altamente Portable (NetBSD, macOS, Linux, SmartOS, Solaris) |
| **Configuración Interactiva** | `make config` (GUI basada en ncurses con Dialog) | Flags de entorno manuales `FLAVORS` y `MULTI_PACKAGES` | `make config` o `PKG_OPTIONS.pkgname` explícito en `mk.conf` |
| **Sistema de Build Aislado** | Poudriere (Usa `jail(8)` y snapshots de ZFS) | `dpb(1)` (Distributed Ports Builder con `chroot`) | `pbulk` (Parallel Bulk Build en `chroot`/sandbox) |

---

## 3. Manifiestos de Configuración en Producción y Configuraciones de Infraestructura

### 3.1 Configuración de Repositorio de Paquetes Enterprise en FreeBSD
Ubicación: `/usr/local/etc/pkg/repos/EnterpriseSRE.conf`

```yaml
# /usr/local/etc/pkg/repos/EnterpriseSRE.conf
# Enterprise FreeBSD Package Repository Specification
# Enforces TLS enforcement, cryptographic signature validation, and custom mirrors.

EnterpriseSRE: {
  url: "pkg+https://pkg-mirror.internal.netops.zone/freebsd/${ABI}/latest",
  mirror_type: "srv",
  signature_type: "pubkey",
  pubkey: "/usr/local/etc/ssl/certs/pkg-repository.pub",
  enabled: true,
  priority: 100,
  ip_version: 4
}

FreeBSD: {
  enabled: false
}
```

---

### 3.2 Sobrescrituras de Compilación de Ports a Nivel de Sistema en FreeBSD
Ubicación: `/etc/make.conf`

```make
# /etc/make.conf
# Production Build Environment Global Overrides

# Global compiler optimization and CPU architecture targeting
CFLAGS= -O2 -pipe -march=x86-64-v3 -fstack-protector-strong
CXXFLAGS= -O2 -pipe -march=x86-64-v3 -fstack-protector-strong

# Disable GUI/X11 bindings globally across all builds
WITHOUT_X11= yes
WITHOUT_GUI= yes

# Enforce modern SSL provider selection
DEFAULT_VERSIONS+= ssl=openssl python=3.11 perl5=5.36

# Port-specific default options overrides
www_nginx_SET= HTTP2 HTTP_GZIP_STATIC HTTP_REALIP MODULES VTS
www_nginx_UNSET= DEBUG HTTP_AUTOINDEX HTTP_DAV HTTP_SSI XSLT

security_openssl_UNSET= SSL3 TLS1 TLS1_1
```

---

### 3.3 Configuración de Granja de Compilación Aislada con FreeBSD Poudriere
Ubicación: `/usr/local/etc/poudriere.conf`

```ini
# /usr/local/etc/poudriere.conf
# Isolated Package Build Farm Architecture Settings

ZPOOL=tank
ZROOTFS=/poudriere
FREEBSD_HOST=https://ftp.freebsd.org
RESOLV_CONF=/etc/resolv.conf
BASEFS=/usr/local/poudriere
USE_PORTLINT=no
USE_TMPFS=yes
TMPFS_LIMIT=16
MAX_MEMORY=32
PARALLEL_JOBS=8
PREPARE_PARALLEL_JOBS=4
ALLOW_MAKE_JOBS=yes
NLISTJOBS=4

# Cryptographic Signatures for generated pkg repositories
PKG_REPO_SIGNING_KEY=/etc/ssl/keys/poudriere_pkg.key

# Path to custom make.conf passed to jails
DEFAULT_POUDRIERE_BUILD_MAKEFILE=/usr/local/etc/poudriere-make.conf

# Log formatting
HTML_TYPE="hosted"
```

---

### 3.4 Configuración de Mirror de Paquetes en Red para OpenBSD
Ubicación: `/etc/installurl`

```text
# /etc/installurl
# Production Mirror Endpoint for OpenBSD pkg_add(1) and syspatch(8)
https://cdn.openbsd.org/pub/OpenBSD
```

---

### 3.5 Manifiestos de Configuración de NetBSD Package Source (`pkgsrc`) y `pkgin`
Ubicación: `/etc/mk.conf` (Ajustes del Código Fuente de Ports en NetBSD)

```make
# /etc/mk.conf - NetBSD pkgsrc global configuration
.ifdef PKG_SYSCONFDIR
  ACCEPTABLE_LICENSES+= MIT bsdtar-license gnu-gpl-v2 gnu-gpl-v3
.endif

# Infrastructure Directories
PKG_DBDIR=           /var/db/pkg
LOCALBASE=            /usr/pkg
VARBASE=              /var
PKGINFODIR=           info
PKGMANDIR=            man

# Compiler & Hardening
CFLAGS+=              -O2 -fPIC -fstack-protector-all
PKGSRC_USE_SSP=       yes
PKGSRC_USE_FORTIFY=   strong
PKGSRC_USE_RELRO=     full

# Package-specific customization
PKG_OPTIONS.nginx=    http2 ssl pcre IPv6
PKG_OPTIONS.curl=     gssapi openssl -gnutls
```

Ubicación: `/usr/pkg/etc/pkgin/repositories.conf` (Configuración de Repo Binario `pkgin` para NetBSD)

```text
# /usr/pkg/etc/pkgin/repositories.conf
# Direct binary repository configuration for pkgin
https://cdn.netbsd.org/pub/pkgsrc/packages/NetBSD/amd64/10.0/All
```

---

### 3.6 Script de Shell Automatizado: Constructor de Repositorio de Paquetes Personalizado Firmado (FreeBSD)
Ubicación: `/usr/local/sbin/build-custom-repo.sh`

```bash
#!/bin/sh
# Production script: Packages compiled ports into a cryptographically signed repo
set -e

REPO_ROOT="/usr/local/www/packages"
PKG_KEY="/etc/ssl/keys/pkg_repo.key"
PKG_PUB="/usr/local/etc/ssl/certs/pkg-repository.pub"
STAGING_DIR="/tmp/pkg-stage"

mkdir -p "${REPO_ROOT}" "${STAGING_DIR}"

echo "[+] Creating Package Repository Metadata..."
# Generate repository metadata DB using RSA key for signing
pkg repo ${REPO_ROOT} ${PKG_KEY}

echo "[+] Verifying Repository Integrity..."
pkg repo-check ${REPO_ROOT}

echo "[+] Updating Repository Permissions..."
chmod -R 755 ${REPO_ROOT}
chown -R www:www ${REPO_ROOT}

echo "[SUCCESS] Package repository ready at ${REPO_ROOT}."
```

---

## 4. Flujos de Trabajo CLI Paso a Paso y Salidas de Terminal en Producción

### 4.1 Gestión Moderna de Paquetes Binarios en FreeBSD (`pkg`)

#### Comando: Búsqueda Remota de Paquetes e Inspección Detallada de Información
```shell
$ pkg search -F name -S description -e nginx
```
```text
nginx-1.26.1,2                 Robust, small and high performance http and reverse proxy server
```

```shell
$ pkg info --remote --full nginx
```
```text
name: "nginx"
version: "1.26.1,2"
origin: "www/nginx"
comment: "Robust, small and high performance http and reverse proxy server"
arch: "FreeBSD:14:amd64"
www: "https://nginx.org"
maintainer: "osa@FreeBSD.org"
prefix: "/usr/local"
licenselogic: "single"
licenses: ["BSD2CLAUSE"]
flatsize: 2.45MiB
pkgsize: 812KiB
desc: |
  NGINX is an HTTP and reverse proxy server, a mail proxy server, and a generic
  TCP/UDP proxy server.
deps:
  pcre2: 10.43
  libxml2: 2.11.7
  openssl: 3.0.13,1
```

#### Comando: Instalación de Paquetes con Verificaciones Estrictas de Dependencias
```shell
# pkg install -y www/nginx
```
```text
Updating EnterpriseSRE repository catalogue...
Fetching meta.conf: 100%    178 B   0.2kB/s    00:01    
Fetching packagesite.pkg: 100%  7.12MiB   3.55MiB/s    00:02    
Processing entries: 100%
EnterpriseSRE repository update completed. 34120 packages processed.
Checking integrity... done (0 conflicting)
The following 3 package(s) will be affected (of 0 checked):

New packages to be INSTALLED:
	libxml2: 2.11.7
	nginx: 1.26.1,2
	pcre2: 10.43

Number of packages to be installed: 3

The process will require 8 MiB more space.
2 MiB to be downloaded.
[1/3] Fetching libxml2-2.11.7.pkg: 100%  850 KiB 850.0kB/s    00:01
[2/3] Fetching pcre2-10.43.pkg: 100%  620 KiB 620.0kB/s    00:01
[3/3] Fetching nginx-1.26.1,2.pkg: 100%  812 KiB 812.0kB/s    00:01
Checking integrity... done (0 conflicting)
[1/3] Installing pcre2-10.43...
[1/3] Extracting pcre2-10.43: 100%
[2/3] Installing libxml2-2.11.7...
[2/3] Extracting libxml2-2.11.7: 100%
[3/3] Installing nginx-1.26.1,2...
===> Creating groups.
Creating group 'www' with gid '80'.
===> Creating users
Creating user 'www' with uid '80'.
[3/3] Extracting nginx-1.26.1,2: 100%
Message from nginx-1.26.1,2:

--
Recent version of NGINX introduces strict URI validation rules.
Ensure configuration compliance before restarting rc daemon.
```

#### Comando: Protección de Paquetes Críticos de Producción (Bloqueo / Locking)
Para prevenir actualizaciones accidentales o eliminación automatizada durante `pkg autoremove`:
```shell
# pkg lock nginx
```
```text
nginx-1.26.1,2: lock which package? [y/N]: y
Locking nginx-1.26.1,2
```

```shell
# pkg lock -l
```
```text
Currently locked packages:
nginx-1.26.1,2
```

#### Comando: Escaneo de Auditoría de Vulnerabilidades (`pkg audit`)
```shell
$ pkg audit -F
```
```text
Fetching vulndbx.tar.xz: 100%  512 KiB 512.0kB/s    00:01    
curl-8.7.1 is vulnerable:
  curl -- heap-based buffer overflow in HTTP/2 frame handling
  CVE: CVE-2024-2398
  WWW: https://vuxml.freebsd.org/freebsd/8f4c2c1a-0518-11ef-8b87-00155d006802.html

1 problem(s) in 1 installed package(s) found.
```

---

### 4.2 Flujo de Trabajo de Compilación Basado en Fuente de FreeBSD Ports

#### Comando: Obtención y Actualización del Árbol de Ports vía Git
```shell
# git clone --branch main https://git.freebsd.org/ports.git /usr/ports
```
```text
Cloning into '/usr/ports'...
remote: Enumerating objects: 5412901, done.
remote: Counting objects: 100% (5412901/5412901), done.
remote: Compressing objects: 100% (982011/982011), done.
remote: Total 5412901 (delta 3412091), reused 5409800 (delta 3409112)
Receiving objects: 100% (5412901/5412901), 1.18 GiB | 18.42 MiB/s, done.
Resolving deltas: 100% (3412091/3412091), done.
Updating files: 100% (154012/154012), done.
```

#### Comando: Configuración y Compilación de un Port
```shell
# cd /usr/ports/www/nginx
# make config
```
*(La interfaz de diálogo muestra las opciones guardadas en `/var/db/ports/www_nginx/options`)*

```shell
# make BATCH=yes install clean
```
```text
===>  License BSD2CLAUSE accepted by the user
===>  Found saved configuration for nginx-1.26.1,2
===>   nginx-1.26.1,2 depends on file: /usr/local/sbin/pkg - found
===> Fetching all distfiles required by nginx-1.26.1,2 for building
=> SHA256 Checksum OK for nginx-1.26.1.tar.gz.
===>  Extracting for nginx-1.26.1,2
=> SHA256 Checksum OK for nginx-1.26.1.tar.gz.
===>  Patching for nginx-1.26.1,2
===>   nginx-1.26.1,2 depends on shared library: libpcre2-8.so - found (/usr/local/lib/libpcre2-8.so)
===>  Configuring for nginx-1.26.1,2
configuring additional modules
configuring version 1.26.1
...
Configuration summary
  + using system PCRE2 library
  + OpenSSL library support is enabled
  + using system zlib library

===>  Building for nginx-1.26.1,2
cc -c -O2 -pipe -march=x86-64-v3 -fstack-protector-strong -I src/core \
	-I src/event -I src/os/unix -o objs/src/core/nginx.o src/core/nginx.c
cc -o objs/nginx objs/src/core/nginx.o ... -L/usr/local/lib -lpcre2-8 -lcrypto -lssl
===>  Installing for nginx-1.26.1,2
===>   Registering installation for nginx-1.26.1,2
Installing nginx-1.26.1,2...
===>  Cleaning for nginx-1.26.1,2
```

---

### 4.3 Gestión de Paquetes en OpenBSD (`pkg_add`, `pkg_info`, `pkg_delete`)

#### Comando: Instalación de Software vía `pkg_add` de OpenBSD
```shell
# export PKG_PATH=https://cdn.openbsd.org/pub/OpenBSD/7.5/packages/amd64/
# pkg_add -v rsync
```
```text
Update infrastructure refreshed to 7.5
rsync-3.3.0: pcre2-10.42p0: ok
rsync-3.3.0: ok
Read shared items: ok
```

#### Comando: Búsqueda de Paquetes vía Consulta a OpenBSD Ports (`sqlports`)
OpenBSD proporciona una base de datos SQLite estructurada (`sqlports`) para consultar metadatos de ports:
```shell
$ sqlite3 /usr/local/share/sqlports "SELECT FULLPKGPATH, COMMENT FROM PORTS WHERE PKGNAME LIKE 'curl%';"
```
```text
net/curl|curl open-source transfer tool using Internet protocols
net/curl,-main|curl open-source transfer tool using Internet protocols
net/curl,-psl|Public Suffix List support library for curl
```

#### Comando: Realizar Actualizaciones de Paquetes a Nivel de Sistema
```shell
# pkg_add -u -v
```
```text
Update infrastructure refreshed to 7.5
Running check-substitutions
Upgrading rsync-3.3.0 to rsync-3.3.1
rsync-3.3.0->rsync-3.3.1: ok
Read shared items: ok
```

---

### 4.4 Gestión de Paquetes Binarios en NetBSD (`pkgin` y `pkg_install`)

#### Comando: Inicialización y Actualización del Índice de la Base de Datos
```shell
# pkgin update
```
```text
reading repository descriptors ...
downloading pkg_summary.gz done
processing pkg_summary.gz done
database for https://cdn.netbsd.org/pub/pkgsrc/packages/NetBSD/amd64/10.0/All is up-to-date
```

#### Comando: Instalación de Paquetes con `pkgin`
```shell
# pkgin -y install htop
```
```text
calculating dependencies...done.

1 package to install:
  htop-3.3.0

0 to refresh, 0 to upgrade, 1 to install
0B to download, 412KiB to install

installing htop-3.3.0...
pkg_add: Package `htop-3.3.0' registered successfully
marking htop-3.3.0 as non auto-removable
```

#### Comando: Auditoría de Paquetes Instalados para Vulnerabilidades de Seguridad Conocidas (`pkg_admin`)
```shell
# pkg_admin fetch-pkg-vulnerabilities
```
```text
pkg_vulnerabilities size 245109 bytes received OK.
```

```shell
# pkg_admin audit
```
```text
Package python310-3.10.11 has a vulnerable-ge vulnerability, see https://nvd.nist.gov/vuln/detail/CVE-2023-24329
```

---

## 5. Guía de Verificación y Resolución de Problemas (Troubleshooting)

### Diagrama de Diagnóstico: Resolución de Roturas de Paquetes / Ports

```
               [Package Failure Encountered]
                             │
            Is it a Binary or Source Failure?
              ┌──────────────┴──────────────┐
           [Binary]                      [Source]
              │                             │
    Run Cryptographic Check       Inspect Build Log & Env
     `pkg check -s -a`            `make missing` / `pkg-config`
              │                             │
    Has Shared Lib Drifted?        Verify /etc/make.conf
     `pkg check -d -a`             Check CFLAGS / Options
              │                             │
    ┌─────────┴─────────┐         ┌─────────┴─────────┐
[Corrupted DB]    [Missing Lib] [Fetch Failed] [Lib Mismatch]
      │                 │              │              │
 Rebuild DB       Reinstall Dep   Update URL     Rebuild Ports
`pkg backup`      `pkg install -f` Check SHA256  in dependency
`pkg-static`                      Distfile        order
```

---

### Matriz de Fallos: Diagnóstico de Problemas en Producción y Remediación

| Síntoma / Mensaje de Error | Causa Raíz | Comando / Flujo de Remediación |
| :--- | :--- | :--- |
| `pkg: Signature mismatched` | Desajuste de clave pública local o el payload del repositorio mirror ha sido corrompido/manipulado. | 1. Verificar clave: `openssl rsa -in /etc/ssl/keys/pkg.key -pubout`<br>2. Forzar refresco del repositorio: `pkg update -f`<br>3. Verificar `/usr/local/etc/pkg/repos/*.conf` |
| `pkg: sqlite error: database disk image is malformed` | Reinicio forzado del host o fallo de E/S corrompió la base de datos local de SQLite (`local.sqlite`). | `# pkg-static backup -r /var/backups/pkg-backup-latest.sqlite`<br>O restaurar el esquema:<br>`# sqlite3 /var/db/pkg/local.sqlite ".recover" \| sqlite3 /var/db/pkg/local_fix.sqlite && mv local_fix.sqlite local.sqlite` |
| `Shared object "libssl.so.30" not found, required by "nginx"` | Se actualizó la versión mayor del SO base sin recompilar/actualizar paquetes de terceros. | `# pkg check -d -a`<br>O forzar la recompilación de todos los paquetes dependientes:<br>`# pkg upgrade -f` |
| `OpenBSD pkg_add: Can't find package for <pkg>` | `PKG_PATH` inválido, rama de release incorrecta o mirror desincronizado. | 1. Verificar `/etc/installurl`<br>2. Exportar ruta exacta: `export PKG_PATH=https://cdn.openbsd.org/pub/OpenBSD/$(uname -r)/packages/$(uname -m)/` |
| `NetBSD pkgin: pkg_summary.gz fetch failed` | Fallo de conectividad de red, certificados raíz TLS expirados o cadena de repo inválida. | 1. Verificar descarga HTTPS: `ftp https://cdn.netbsd.org/pub/pkgsrc/packages/NetBSD/amd64/10.0/All/pkg_summary.gz`<br>2. Actualizar `/usr/pkg/etc/pkgin/repositories.conf` |

---

### Escenarios Diagnósticos Paso a Paso

#### Escenario 1: Reparación de Dependencias de Librerías Compartidas Rotas en FreeBSD (`pkg check`)

*Problema:* Un parche del SO base de FreeBSD actualizó una librería núcleo, causando que los binarios de terceros fallen con errores del enlazador dinámico (`ld-elf.so.1: Shared object not found`).

1. **Escanear dependencias de librerías compartidas rotas en todos los paquetes instalados:**
```shell
# pkg check -d -a
```
```text
Checking all packages: 100%
nginx-1.26.1,2 is missing a required shared library: libssl.so.30
curl-8.7.1 is missing a required shared library: libssl.so.30
```

2. **Reinstalar de forma forzada los binarios afectados desde el repositorio enterprise configurado:**
```shell
# pkg install -f www/nginx ftp/curl
```
```text
Updating EnterpriseSRE repository catalogue...
EnterpriseSRE repository is up to date.
The following 2 package(s) will be reinstalled:
	nginx-1.26.1,2
	curl-8.7.1

Proceed with this action? [y/N]: y
[1/2] Reinstalling nginx-1.26.1,2...
[2/2] Reinstalling curl-8.7.1...
Re-checking shared library dependencies...
Checking all packages: 100%
[SUCCESS] No missing shared library dependencies detected.
```

---

#### Escenario 2: Recuperación de una Base de Datos de Paquetes Corrompida en FreeBSD

*Problema:* La base de datos de paquetes de SQLite se corrompió tras un kernel panic por falta de memoria (out-of-memory).

1. **Verificar el fallo usando el ejecutable estático independiente `pkg-static`:**
```shell
# pkg-static info
```
```text
pkg-static: sqlite error sqlite3_exec /usr/src/lib/libpkg/pkgdb.c:1240: database disk image is malformed
```

2. **Ejecutar la secuencia de recuperación mediante las herramientas de shell de `pkg-static`:**
```shell
# cd /var/db/pkg
# cp local.sqlite local.sqlite.bak
# pkg-static shell .dump | pkg-static shell "sqlite3 local_recovered.sqlite"
# mv local_recovered.sqlite local.sqlite
# pkg-static check -s -a
```
```text
Checking checksums: 100%
Database recovery verified. 142 packages registered cleanly.
```

---

## 6. Referencias y Documentación Oficial

* **LPI BSD Specialist Certification Overview:**  
  [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

* **FreeBSD Handbook – Installing Applications: Packages and Ports:**  
  [https://docs.freebsd.org/en/books/handbook/ports/](https://docs.freebsd.org/en/books/handbook/ports/)

* **FreeBSD `pkg(8)` Manual Page:**  
  [https://man.freebsd.org/cgi/man.cgi?query=pkg&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=pkg&sektion=8)

* **FreeBSD Poudriere Official Documentation:**  
  [https://wiki.freebsd.org/Poudriere](https://wiki.freebsd.org/Poudriere)

* **OpenBSD Package Management Guide (`pkg_add`):**  
  [https://www.openbsd.org/faq/faq15.html](https://www.openbsd.org/faq/faq15.html)

* **OpenBSD `pkg_add(1)` Manual Page:**  
  [https://man.openbsd.org/pkg_add.1](https://man.openbsd.org/pkg_add.1)

* **NetBSD `pkgsrc` Official Guide:**  
  [https://www.netbsd.org/docs/pkgsrc/](https://www.netbsd.org/docs/pkgsrc/)

* **NetBSD `pkgin` Package Manager Manual:**  
  [https://man.netbsd.org/pkgin.1](https://man.netbsd.org/pkgin.1)