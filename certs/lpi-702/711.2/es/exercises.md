# LPI 702: Certificación BSD Specialist — Guía Práctica de Laboratorio
## Tema 711.2: Gestión de Software y Paquetes en BSD
**Versión del examen:** 702-100 (v1.0) | **Ponderación del examen:** 6.67  
**Referencia oficial:** [Visión general de LPI BSD Specialist](https://www.lpi.org/our-certifications/bsd-specialist-overview/) | [FreeBSD Handbook: Paquetes y Ports](https://docs.freebsd.org/en/books/handbook/ports/) | [Guía de NetBSD pkgsrc](https://www.netbsd.org/docs/pkgsrc/) | [Gestión de Paquetes en OpenBSD](https://www.openbsd.org/faq/faq15.html)

---

## Arquitectura y Plano de Mecánica Interna

Los sistemas operativos BSD modernos mantienen un desacoplamiento estricto entre el kernel/userland del sistema operativo base (gestionado mediante `freebsd-update`, `syspatch` o árboles de código fuente) y las aplicaciones de software de terceros. La gestión de software de terceros en FreeBSD, OpenBSD y NetBSD se basa en dos paradigmas distintos: paquetes binarios precompilados y frameworks de ports basados en código fuente.

```
+-----------------------------------------------------------------------------------+
|                            BSD THIRD-PARTY SOFTWARE LAYER                         |
+-----------------------------------------------------------------------------------+
|                                                                                   |
|   +-------------------------------+       +-----------------------------------+   |
|   |   Binary Package Paradigm     |       |     Source / Ports Paradigm       |   |
|   +-------------------------------+       +-----------------------------------+   |
|   |  - FreeBSD: pkg (libpkg/sqlite)|      |  - FreeBSD: Ports (/usr/ports)    |   |
|   |  - OpenBSD: pkg_add (OpenBSD) |       |  - OpenBSD: Ports Framework       |   |
|   |  - NetBSD:  pkgin / pkg_add   |       |  - NetBSD:  pkgsrc (/usr/pkgsrc)  |   |
|   +---------------+---------------+       +-----------------+-----------------+   |
|                   |                                         |                     |
|                   v                                         v                     |
|   +-------------------------------+       +-----------------------------------+   |
|   | Automated Repositories &      |       | Cleanroom Build Engines           |   |
|   | Cryptographic Verification    |       | (Poudriere / dpb / pbulk)         |   |
|   +-------------------------------+       +-----------------------------------+   |
+-----------------------------------------------------------------------------------+
```

### Matriz Comparativa de Arquitectura

| Característica / Mecanismo del SO | FreeBSD (`pkg`) | OpenBSD (`pkg_add`) | NetBSD / Multi-SO (`pkgsrc` y `pkgin`) |
| :--- | :--- | :--- | :--- |
| **Herramienta Binaria Principal** | `pkg` | `pkg_add`, `pkg_delete`, `pkg_info` | `pkgin`, `pkg_add`, `pkg_admin` |
| **Metadatos de Backend** | BD SQLite (`/var/db/pkg/local.sqlite`) | Especificaciones basadas en archivos (`/var/db/pkg/`) | Especificaciones basadas en archivos (`/var/db/pkg/`) |
| **Motor de Código Fuente** | FreeBSD Ports Collection | Infraestructura de Ports de OpenBSD | `pkgsrc` (Motor Makefile portable) |
| **Herramienta de Build Cleanroom** | `ports-mgmt/poudriere` | `dpb` (Distributed Ports Builder) | `pkgtools/pbulk` o `pkgtools/pkg_comp` |
| **Auditoría de Vulnerabilidades** | `pkg audit` (Feed VuXML) | Errata / `pkg_info -q -U` | `pkg_admin audit` (pkg-vulnerabilities) |
| **Flavors Personalizados** | PORT_OPTIONS / Flavors | `FLAVOR` / `SUBPACKAGE` | Options Framework (`PKG_OPTIONS`) |

---

## Ejercicios de Laboratorio y Comprobaciones de Comprensión

---

### Ejercicio 1: Gestión de Paquetes Binarios en FreeBSD (`pkg`), Espejo de Repositorios y Auditoría de Seguridad

#### Escenario
Como SRE Senior, debés configurar una flota de servidores empresariales FreeBSD para obtener paquetes desde un mirror de repositorio interno firmado criptográficamente en lugar del CDN público de FreeBSD. También debés implementar la auditoría automatizada de vulnerabilidades utilizando la base de datos VuXML y gestionar de forma segura los bloqueos (locks) de paquetes en dependencias críticas de producción.

#### Paso 1.1: Inspeccionar la Configuración de Repositorios Existente y los Metadatos SQLite Locales
Examiná la configuración activa del repositorio y el esquema de la base de datos local de paquetes.

```bash
# Display active package repository configuration
pkg -vv | grep -A 15 "Repositories:"
```

*Salida esperada:*
```text
Repositories:
  FreeBSD: { 
    url             : "pkg+http://pkg.FreeBSD.org/FreeBSD:14:amd64/quarterly",
    enabled         : yes,
    priority        : 0,
    mirror_type     : "SRV",
    signature_type  : "FINGERPRINTS",
    fingerprints    : "/usr/share/keys/pkg"
  }
```

```bash
# Query detailed package database status and count installed packages
pkg info -a | wc -l
pkg stats
```

*Salida esperada:*
```text
Local package database:
	Installed packages: 142
	Disk space occupied: 2.1 GiB

Remote package database(s):
	Number of repositories: 1
	Packages available: 34120
```

#### Paso 1.2: Sobrescribir el Repositorio Predeterminado con una Configuración de Infraestructura Personalizada
Creá un archivo de sobrescritura de repositorio empresarial en `/usr/local/etc/pkg/repos/CompanyRepo.conf` para deshabilitar la descarga pública predeterminada y enrutar las solicitudes a un mirror interno con TLS y fijación explícita de huellas digitales (fingerprint pinning).

```bash
# Create the override directory
mkdir -p /usr/local/etc/pkg/repos/

# Write the production repository override manifest
cat <<'EOF' > /usr/local/etc/pkg/repos/CompanyRepo.conf
FreeBSD: { enabled: false }

CompanyRepo: {
  url: "pkg+https://pkg-mirror.internal.net/FreeBSD:14:amd64/latest",
  mirror_type: "HTTP",
  signature_type: "PUBKEY",
  pubkey: "/etc/ssl/pkg-mirror.pub",
  enabled: true,
  priority: 100
}
EOF
```

```bash
# Test database updates against the new configuration endpoint
pkg update -f
```

#### Paso 1.3: Ciclo de Vida de Paquetes, Rastro de Dependencias y Bloqueos
Instalá el servidor web `nginx`, bloquéalo (lock) para evitar actualizaciones accidentales durante las tareas de mantenimiento de rutina e inspeccioná sus dependencias inversas.

```bash
# Install nginx using binary package manager
pkg install -y www/nginx

# Lock nginx to prevent automated upgrades by batch SRE maintenance jobs
pkg lock www/nginx
```

*Salida esperada:*
```text
www/nginx-1.26.1,1: locking package... Done
```

```bash
# Verify locked packages in the system
pkg lock -l
```

*Salida esperada:*
```text
Currently locked packages:
www/nginx-1.26.1,1
```

```bash
# Trace shared library dependencies and required packages for nginx
pkg info -d www/nginx
pkg info -B www/nginx
```

*Salida esperada:*
```text
www/nginx-1.26.1,1:
Depends on     :
	pcre2-10.43
	indexinfo-0.3.1
	libxml2-2.11.8

www/nginx-1.26.1,1:
Shared Libraries Required:
	libpcre2-8.so.0
	libssl.so.30
	libcrypto.so.30
	libz.so.6
```

#### Paso 1.4: Ejecutar Auditoría de Vulnerabilidades a través de VuXML
Descargá las últimas definiciones de vulnerabilidades de VuXML y auditá todos los paquetes instalados.

```bash
# Fetch latest vulnerability database and run full audit
pkg audit -F
```

*Salida esperada:*
```text
Fetching vuln.xml.xz: 100%    512 KiB 1.2MiB/s    00:00    
0 problem(s) in 143 installed package(s) found.
```

---

#### Preguntas de Verificación — Ejercicio 1

1. **Pregunta 1:** ¿Por qué se considera un antipatrón de SRE modificar `/etc/pkg/FreeBSD.conf` directamente al configurar repositorios personalizados y qué mecanismo utiliza `pkg` para fusionar los manifiestos de repositorios?
2. **Pregunta 2:** Si `pkg audit -F` marca una vulnerabilidad crítica en `openssl` en un host FreeBSD de producción, pero `pkg upgrade` reporta "No packages available to upgrade", ¿cuáles son las dos causas raíz más comunes en un entorno empresarial que utiliza ramas `quarterly` frente a `latest`?
3. **Pregunta 3:** ¿Qué flag de línea de comandos permite a un administrador ejecutar `pkg autoremove` en modo simulación (dry-run) para inspeccionar dependencias dinámicas no referenciadas sin modificar el estado del sistema?

---

### Ejercicio 2: Framework de FreeBSD Ports, Compilaciones Cleanroom (`poudriere`) y `/etc/make.conf`

#### Escenario
Ciertos microservicios de producción requieren flags personalizados en tiempo de compilación (por ejemplo, habilitar HTTP/2, soporte SSL ALPN, deshabilitar módulos no deseados en Nginx) que no están presentes en los paquetes binarios estándar. Debés configurar la infraestructura del árbol de FreeBSD Ports, definir flags de build centralizados mediante `/etc/make.conf` y configurar un entorno de compilación cleanroom con Poudriere.

#### Paso 2.1: Obtener y Extraer el Árbol de FreeBSD Ports
Inicializá el árbol oficial de ports de FreeBSD usando `git` o `portsnap`.

```bash
# Clone the latest ports tree into /usr/ports via Git
git clone --depth 1 https://git.FreeBSD.org/ports.git /usr/ports
```

```bash
# Verify ports tree structure
ls -ld /usr/ports/Mk /usr/ports/www/nginx
```

#### Paso 2.2: Configurar Opciones Centralizadas de Ports mediante `/etc/make.conf`
Configurá `/etc/make.conf` para aplicar flags de compilador a nivel de sistema (`CFLAGS`), variantes de software predeterminadas (por ejemplo, Python 3.11, OpenSSL desde ports) y opciones personalizadas de ports.

```bash
# Write production build rules to /etc/make.conf
cat <<'EOF' > /etc/make.conf
# Optimization and CPU tuning
CFLAGS+= -O2 -pipe -fstack-protector-strong

# Force default language/runtime versions across all built ports
DEFAULT_VERSIONS+= python=3.11 ssl=openssl

# Global port knobs: Disable X11 GUI bindings, enable HTTP2
WITHOUT_X11=yes
www_nginx_SET= HTTP2 HTTP_PORTAL TLS SSL
www_nginx_UNSET= DEBUG XSLT DOCS
EOF
```

#### Paso 2.3: Configurar y Compilar un Port Manualmente
Navegá al directorio del port, inspeccioná las opciones, configurá los knobs mediante un diálogo de interfaz gráfica de texto (TUI) y ejecutá el pipeline de compilación.

```bash
cd /usr/ports/www/nginx

# Non-interactively check configured options based on make.conf
make showconfig
```

*Salida esperada:*
```text
===> The following configuration options for nginx-1.26.1,1 are currently set:
     DSD=off: Dynamic Seamless Diagnostic
     HTTP=on: Enable HTTP module
     HTTP2=on: Enable HTTP/2 protocol support
     HTTP_PORTAL=on: Internal portal extension
     SSL=on: Enable SSL module support
====> Options available for the group MODULES
     DEBUG=off: Build with debugging support
     XSLT=off: Enable XSLT module
```

```bash
# Run clean building, packaging, and installation pipeline
make clean
make BATCH=yes stage
make BATCH=yes install clean
```

#### Paso 2.4: Configurar el Entorno de Compilación Masiva Cleanroom con Poudriere
En operaciones SRE de producción, está prohibido compilar software directamente en sistemas de producción. Debés configurar `poudriere` para compilar paquetes en un entorno `jail` aislado utilizando snapshots de ZFS.

```bash
# Install poudriere
pkg install -y ports-mgmt/poudriere

# Create poudriere main configuration file
cat <<'EOF' > /usr/local/etc/poudriere.conf
ZPOOL=zroot
NO_ZFS=no
FREEBSD_HOST=https://download.FreeBSD.org
RESOLV_CONF=/etc/resolv.conf
BASEFS=/usr/local/poudriere
USE_PORTLINT=no
USE_TMPFS=yes
DISTFILES_CACHE=/usr/ports/distfiles
CHECK_CHANGED_DATA=yes
CHECK_CHANGED_DEPS=yes
EOF
```

```bash
# Initialize a Poudriere Jail for FreeBSD 14.1-RELEASE amd64
poudriere jail -c -j 141rel -v 14.1-RELEASE

# Create a ports tree inside Poudriere
poudriere ports -c -p enterprise_ports

# Verify Poudriere isolated environment status
poudriere jail -l
```

*Salida esperada:*
```text
JAILNAME VERSION      ARCH  METHOD TIMESTAMP           PATH
141rel   14.1-RELEASE amd64 http   2026-08-06 18:30:00 /usr/local/poudriere/jails/141rel
```

---

#### Preguntas de Verificación — Ejercicio 2

1. **Pregunta 1:** ¿Cuál es la principal ventaja operativa de usar `poudriere` en lugar de ejecutar `make install clean` directamente dentro de `/usr/ports` en un host de producción?
2. **Pregunta 2:** En `/etc/make.conf`, ¿cuál es la diferencia exacta de sintaxis entre definir una opción global (por ejemplo, `WITHOUT_X11=yes`) frente a definir una opción específica de un port para `net/haproxy` para habilitar soporte LUA?
3. **Pregunta 3:** ¿Qué características del sistema de archivos ZFS aprovecha `poudriere` durante las compilaciones masivas de paquetes para garantizar el aislamiento de la compilación y un desmontaje rápido entre ejecuciones de trabajos?

---

### Ejercicio 3: Ecosistema de Paquetes de OpenBSD (`pkg_add`, `PKG_PATH`, `/etc/installurl` y Flavors)

#### Escenario
OpenBSD utiliza un sistema de gestión de paquetes declarativo y reforzado en seguridad, integrado con las primitivas de seguridad del sistema (`pledge(2)` y `unveil(2)`). Debés configurar la resolución de mirrors mediante `/etc/installurl`, gestionar la instalación de paquetes con flavors y subpaquetes explícitos y realizar actualizaciones automatizadas y seguras a nivel de todo el sistema.

#### Paso 3.1: Configurar la Resolución de Mirrors mediante `/etc/installurl`
Configurá la URL del repositorio a nivel de todo el sistema para `pkg_add` y `syspatch`.

```bash
# Inspect or set the OpenBSD mirror URL
cat /etc/installurl
```

*Si falta o necesita modificación, configurá un mirror oficial CDN:*
```bash
echo "https://cdn.openbsd.org/pub/OpenBSD" > /etc/installurl
```

#### Paso 3.2: Inspeccionar Flavors de Paquetes e Instalar Paquetes Multivariante
Los paquetes de OpenBSD a menudo admiten opciones `FLAVOR` (por ejemplo, no_x11, lite, hardened) y opciones `SUBPACKAGE` compiladas desde un solo árbol de ports.

```bash
# Search for Available PostgreSQL Server packages and examine Flavors
pkg_info -Q postgresql
```

*Salida esperada:*
```text
postgresql-client-16.3
postgresql-docs-16.3
postgresql-server-16.3
```

```bash
# Search specifically for packages matching flavors (e.g., Python or Nginx flavors)
pkg_info -Q nginx
```

*Salida esperada:*
```text
nginx-1.26.1-main
nginx-1.26.1-no_eval
nginx-1.26.1-passthrough
```

```bash
# Install nginx explicitly selecting the main flavor in verbose mode
pkg_add -vv nginx--main
```

*Fragmento de la salida esperada:*
```text
Update targets select nginx-1.26.1-main
Installing nginx-1.26.1-main...
...
Extracted 2841920 bytes in 0.4 seconds
```

#### Paso 3.3: Gestionar Paquetes Instalados, Consultar Archivos y Auditar el Sistema
Realizá consultas sobre los metadatos de los paquetes, inspeccioná los manifiestos de archivos registrados en `/var/db/pkg` y comprobá si hay paquetes instalados que requieran actualizaciones.

```bash
# List all installed packages concisely
pkg_info -q
```

```bash
# Inspect all files installed by the nginx package
pkg_info -L nginx-1.26.1-main
```

*Salida esperada:*
```text
Files installed by nginx-1.26.1-main:
/usr/local/sbin/nginx
/usr/local/man/man8/nginx.8
/etc/nginx/nginx.conf.sample
/usr/local/share/doc/nginx/README
```

```bash
# Perform a dry-run check of all packages against the active remote repository mirror
pkg_add -u -n
```

---

#### Preguntas de Verificación — Ejercicio 3

1. **Pregunta 1:** En OpenBSD, ¿cómo diferencia `pkg_add` entre la instalación de dos flavors distintos del mismo paquete (por ejemplo, bindings de `lua` frente a compilación `no_x11`) y cuál es la sintaxis requerida en la línea de comandos?
2. **Pregunta 2:** ¿Qué variable de entorno puede sobrescribir `/etc/installurl` durante una sola invocación de `pkg_add` en los scripts de automatización de OpenBSD?
3. **Pregunta 3:** ¿Cómo garantiza la arquitectura de OpenBSD que los paquetes binarios creados por terceros no puedan modificar binarios del sistema operativo base arbitrarios durante la extracción?

---

### Ejercicio 4: NetBSD y el Motor Multiplataforma `pkgsrc` (`pkgin`, `pkg_admin` y `bmake`)

#### Escenario
`pkgsrc` es el framework nativo de gestión de paquetes de NetBSD, altamente portable entre SmartOS, macOS, Linux y FreeBSD. Debés configurar el gestor de paquetes binarios `pkgin`, realizar la validación de integridad de la base de datos mediante `pkg_admin` y compilar un paquete desde el código fuente utilizando `bmake`.

#### Paso 4.1: Configurar Mirrors de Repositorios e Inicializar `pkgin`
Configurá `/usr/pkg/etc/pkgin/repositories.conf` para obtener binarios precompilados para NetBSD.

```bash
# Display repository configuration for pkgin
cat /usr/pkg/etc/pkgin/repositories.conf
```

*Salida esperada:*
```text
# NetBSD 10.0 x86_64 binary packages URL
https://cdn.NetBSD.org/pub/pkgsrc/packages/NetBSD/amd64/10.0/All
```

```bash
# Update local pkgin database cache
pkgin update
```

#### Paso 4.2: Operaciones de Paquetes Binarios con `pkgin` y `pkg_add` de Bajo Nivel
Buscá, instalá y consultá paquetes de software utilizando comandos tanto de alto nivel (`pkgin`) como de bajo nivel (`pkg_info`/`pkg_admin`).

```bash
# Search for curl in the binary repository
pkgin search curl
```

*Salida esperada:*
```text
curl-8.7.1           Client that downloads or uploads files using URL syntax
```

```bash
# Install curl via pkgin
pkgin -y install curl
```

```bash
# Verify low-level registration in /var/db/pkg using pkg_info
pkg_info -e curl
```

*Salida esperada:*
```text
curl-8.7.1
```

#### Paso 4.3: Auditoría de Vulnerabilidades de Paquetes con `pkg_admin`
Descargá la lista de vulnerabilidades de seguridad y realizá una auditoría en todos los paquetes instalados.

```bash
# Download official vulnerabilities database file
pkg_admin fetch-pkg-vulnerabilities

# Audit all installed packages against the security database
pkg_admin audit
```

*Salida esperada:*
```text
Package curl-8.7.1 has a low severity vulnerability: CVE-2024-XXXX (see http://curl.se/docs/adv_...)
```

#### Paso 4.4: Compilación desde Fuente mediante `pkgsrc` y `/usr/pkg/etc/mk.conf`
Configurá los knobs globales de compilación de `pkgsrc` en `mk.conf` y compilá un paquete utilizando `bmake` de NetBSD.

```bash
# Inspect / Create /usr/pkg/etc/mk.conf
cat <<'EOF' > /usr/pkg/etc/mk.conf
SPKGSRC_COMPILER= gcc
PKG_DBDIR= /var/db/pkg
LOCALBASE= /usr/pkg
VARBASE= /usr/pkg/var
ACCEPTABLE_LICENSES+= gnu-gpl-v3 MIT BSD
PKG_OPTIONS.curl= inet6 gnutls -openssl
EOF
```

```bash
# Navigate to a port directory in pkgsrc and execute bmake
cd /usr/pkgsrc/net/curl
bmake show-options
```

```bash
# Clean, compile, and package via bmake
bmake package
```

---

#### Preguntas de Verificación — Ejercicio 4

1. **Pregunta 1:** ¿Cuál es la relación entre `pkgin` y `pkg_add`/`pkg_info` en NetBSD, y qué herramienta mantiene el estado del árbol de dependencias del repositorio binario?
2. **Pregunta 2:** En `pkgsrc`, ¿qué archivo de configuración cumple el propósito funcional equivalente a `/etc/make.conf` de FreeBSD y dónde se encuentra por defecto?
3. **Pregunta 3:** ¿Qué comando se debe ejecutar en NetBSD/pkgsrc para reparar o reconstruir la base de datos de índice de dependencias de paquetes si los metadatos de `/var/db/pkg` se corrompen?

---

### Ejercicio 5: Solución de Problemas Avanzada de SRE: Auditoría de Dependencias, Reparación de Base de Datos y Resolución de Conflictos

#### Escenario
Un servidor de base de datos de producción con FreeBSD sufrió un corte de energía inesperado durante la ejecución en lote de `pkg upgrade`. La base de datos local SQLite (`/var/db/pkg/local.sqlite`) está desincronizada con los binarios reales del sistema de archivos, faltan bibliotecas dinámicas (`.so`) para aplicaciones críticas y varios archivos de paquetes fallaron la validación de checksum. Debés diagnosticar y reparar el estado del sistema.

#### Paso 5.1: Diagnosticar la Falta de Dependencias de Bibliotecas Compartidas (Ruptura de ABI)
Ejecutá una verificación a nivel de todo el sistema para detectar bibliotecas compartidas faltantes en todos los paquetes binarios instalados.

```bash
# Scan binary ELF headers against installed library paths
pkg check -d -a
```

*Salida esperada:*
```text
Checking all packages: 100%
(www/nginx) /usr/local/sbin/nginx - Required library libpcre2-8.so.0 not found!
```

```bash
# Verify shared library dependencies of the specific broken binary using ldd
ldd /usr/local/sbin/nginx
```

*Salida esperada:*
```text
/usr/local/sbin/nginx:
	libpcre2-8.so.0 => not found (0x0)
	libssl.so.30 => /usr/lib/libssl.so.30 (0x3b2a9e00000)
	libcrypto.so.30 => /usr/lib/libcrypto.so.30 (0x3b2aa200000)
	libc.so.7 => /lib/libc.so.7 (0x3b2aa800000)
```

#### Paso 5.2: Detectar Corrupción de Archivos y Archivos Faltantes mediante Auditoría de Checksum
Auditá los checksums de los archivos en disco frente a los hashes SHA-256 almacenados en SQLite.

```bash
# Run file integrity and checksum audit across all packages
pkg check -s -a
```

*Salida esperada:*
```text
Checking checksums: 100%
pkg: /usr/local/etc/nginx/mime.types checksum mismatch
pkg: /usr/local/libexec/nginx/ngx_http_geoip_module.so is missing
```

#### Paso 5.3: Reparar Metadatos de la Base de Datos y Forzar la Reinstalación de Paquetes
Corregí las dependencias faltantes, recalculá los metadatos de la base de datos y forzá la reinstalación de los paquetes corrompidos.

```bash
# Recalculate package metadata dependencies in local SQLite DB
pkg check -R
```

```bash
# Force reinstall the affected broken package and its missing libraries without touching configuration files
pkg install -f -y devel/pcre2 www/nginx
```

```bash
# Confirm shared library resolution is completely restored
ldd /usr/local/sbin/nginx
```

*Salida esperada:*
```text
/usr/local/sbin/nginx:
	libpcre2-8.so.0 => /usr/local/lib/libpcre2-8.so.0 (0x3b2a9900000)
	libssl.so.30 => /usr/lib/libssl.so.30 (0x3b2a9e00000)
	libcrypto.so.30 => /usr/lib/libcrypto.so.30 (0x3b2aa200000)
	libc.so.7 => /lib/libc.so.7 (0x3b2aa800000)
```

---

#### Preguntas de Verificación — Ejercicio 5

1. **Pregunta 1:** ¿Qué hace `pkg check -B` en FreeBSD y en qué se diferencia de `pkg check -s`?
2. **Pregunta 2:** Si `/var/db/pkg/local.sqlite` se corrompe por completo o queda en cero durante un apagado no limpio, ¿cómo puede un SRE reconstruir la lista de paquetes instalados si los snapshots de ZFS no están disponibles?
3. **Pregunta 3:** En OpenBSD, si `pkg_add` falla debido a versiones en conflicto de bibliotecas compartidas (`libfoo.so.1.0` vs `libfoo.so.2.0`) durante una actualización del SO en vivo, ¿qué flag fuerza el reemplazo del paquete mientras registra las dependencias rotas para su corrección posterior inmediata?

---

## Soluciones y Explicaciones Detalladas

<details>
<summary>Haz clic para desplegar respuestas y explicaciones técnicas</summary>

### Respuestas del Ejercicio 1

1. **Respuesta 1:** Modificar `/etc/pkg/FreeBSD.conf` directamente es un antipatrón de SRE porque `/etc/pkg/` es administrado por el sistema operativo base y se puede sobrescribir durante `freebsd-update` o actualizaciones del SO. `pkg` utiliza un esquema de directorios modular `/usr/local/etc/pkg/repos/` donde los archivos `.conf` se analizan en orden alfabético. Los archivos ubicados en `/usr/local/etc/pkg/repos/` sobrescriben las configuraciones de `/etc/pkg/FreeBSD.conf` según los nombres de repositorio coincidentes (por ejemplo, `FreeBSD: { enabled: false }`) y las directivas de prioridad (`priority`) del repositorio.
2. **Respuesta 2:** Primero, el host podría estar configurado para seguir la rama `quarterly` (que recibe backports de seguridad cada 3 meses) mientras que la corrección de la vulnerabilidad se aplicó en `latest` y aún no se ha adaptado a `quarterly`. En segundo lugar, el paquete podría estar bloqueado (`pkg lock`), lo que impide que `pkg upgrade` evalúe o modifique el paquete hasta que se desbloquee explícitamente con `pkg unlock`.
3. **Respuesta 3:** El comando es `pkg autoremove -n` (o `--dry-run`). El flag `-n` simula la acción sin eliminar ningún paquete del disco ni remover entradas de `/var/db/pkg/local.sqlite`.

---

### Respuestas del Ejercicio 2

1. **Respuesta 1:** `poudriere` ejecuta compilaciones en entornos `jail` limpios y aislados respaldados por ZFS que no contienen dependencias no declaradas. Compilar directamente en los ports del sistema host (`/usr/ports`) arriesga la contaminación por bibliotecas instaladas en el host, estados de compilación no reproducibles y posibles tiempos de inactividad si los fallos de compilación alteran archivos de configuración del sistema a mitad del proceso.
2. **Respuesta 2:** Las opciones globales se aplican a todo el sistema utilizando variables predefinidas (por ejemplo, `WITHOUT_X11=yes`). Las opciones específicas de un port utilizan la categoría y el nombre del port con el formato `categoria_nombreport_SET` o `categoria_nombreport_UNSET` (por ejemplo, `net_haproxy_SET= LUA` o `www_nginx_SET= HTTP2`).
3. **Respuesta 3:** `poudriere` aprovecha las funcionalidades de ZFS clone (`zfs clone`), snapshot (`zfs snapshot`) y la rápida restauración (rollback). Antes de iniciar un trabajo de compilación, clona instantáneamente un dataset ZFS base de la jail limpia. Una vez que finaliza la compilación, destruye el clon del espacio de trabajo de compilación sin dejar artefactos de compilación residuales ni alterar la jail base prístina.

---

### Respuestas del Ejercicio 3

1. **Respuesta 1:** Los nombres de los paquetes de OpenBSD siguen la convención `nombre-version-flavor`. Cuando existen múltiples flavors, `pkg_add` requiere añadir `--flavor` o seleccionar la cadena explícita. Por ejemplo, `pkg_add nginx--main` instala el flavor `main` de Nginx, mientras que `pkg_add nginx--no_eval` instala el flavor con evaluación deshabilitada. El doble guión (`--`) actúa como un separador que indica las características especificadas del flavor.
2. **Respuesta 2:** La variable de entorno `PKG_PATH` sobrescribe `/etc/installurl`. Por ejemplo: `export PKG_PATH="https://mirror.openbsd.br/pub/OpenBSD/7.5/packages/amd64/"`.
3. **Respuesta 3:** `pkg_add` de OpenBSD se ejecuta bajo restricciones estrictas de llamadas al sistema `pledge(2)` y utiliza `unveil(2)` para restringir el acceso al sistema de archivos exclusivamente a rutas permitidas (tales como `/var/db/pkg`, `/usr/local` y rutas de extracción temporales en `/tmp`). No puede escribir en rutas principales del sistema como `/sbin`, `/usr/libexec` o `/usr/bin`.

---

### Respuestas del Ejercicio 4

1. **Respuesta 1:** `pkgin` es un gestor de paquetes de alto nivel (similar a `apt` o `dnf`) que realiza la resolución de dependencias, descargas HTTP/HTTPS y la gestión de metadatos de repositorios. La ejecución de bajo nivel de la extracción de binarios, el registro y el seguimiento de archivos se delega a `pkg_add`, `pkg_delete` y `pkg_info`. `pkgin` mantiene una caché de SQLite de los árboles de paquetes remotos ubicada en `/usr/pkg/var/db/pkgin/pkgin.db`.
2. **Respuesta 2:** En `pkgsrc`, las opciones globales de compilación y las variables de configuración se declaran en `mk.conf`. En sistemas NetBSD que usan `pkgsrc` estándar, este archivo se encuentra en `/usr/pkg/etc/mk.conf` (o `/etc/mk.conf`).
3. **Respuesta 3:** El comando es `pkg_admin rebuild`. Este comando analiza todos los archivos de metadatos de paquetes almacenados en `/var/db/pkg/` y regenera el índice binario rápido de la base de datos (`/var/db/pkg/pkgdb.byfile.db`).

---

### Respuestas del Ejercicio 5

1. **Respuesta 1:** `pkg check -B` recalcula y verifica todas las dependencias de bibliotecas compartidas (requisitos de enlazado dinámico `ABI`) para todos los ejecutables ELF instalados frente a las bibliotecas registradas en la base de datos. `pkg check -s` verifica la integridad de los archivos en el sistema de archivos calculando los hashes SHA-256 de los archivos instalados en disco y comparándolos con los registros de `/var/db/pkg/local.sqlite`.
2. **Respuesta 2:** Si la BD SQLite no está o es irrecuperable, un SRE puede inspeccionar `/var/db/pkg/` (si existen respaldos en texto), analizar binarios restantes en `/usr/local/` usando `pkg-static` o reconstruir la lista escaneando binarios ELF con `scanelf`/`objdump` para identificar las aplicaciones instaladas, y luego volver a alimentar la base de datos de paquetes mediante `pkg register` o `pkg install -fy`.
3. **Respuesta 3:** El flag `-D update` o `-F update` (o `pkg_add -r -F replace`) fuerza a `pkg_add` a reemplazar paquetes a pesar de conflictos de dependencias o discordancias de versiones de bibliotecas compartidas, lo que permite al administrador actualizar los binarios antes de resolver manualmente las dependencias rotas.

</details>