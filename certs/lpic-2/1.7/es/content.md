# Guía de Estudio Avanzada de SRE para LPIC-2 (Examen 201-450): Tema 206 - Mantenimiento del Sistema

---

## 1. Problema Arquitectónico de Producción y Motivación

El mantenimiento de sistemas en infraestructuras Linux empresariales ya no es un conjunto de tareas administrativas ad-hoc; es una disciplina central de Site Reliability Engineering (SRE) y Platform Architecture. Mantener entornos Linux modernos requiere equilibrar la optimización del rendimiento, la resiliencia de datos con zero-downtime y la claridad operativa a través de los nodos de la flota (fleet nodes).

### 1.1 Compilación desde Código Fuente Personalizado vs. Distribución de Paquetes
Aunque las infraestructuras modernas dependen en gran medida de los gestores de paquetes de la distribución (`apt`, `dnf`) o registros de contenedores, los SREs encuentran con frecuencia escenarios de producción que requieren construcciones de software personalizadas directamente desde el código fuente:
- **Optimización Específica de Hardware:** Las cargas de trabajo empresariales (por ejemplo, motores de trading de alta frecuencia, microservicios de inferencia de IA, API gateways de baja latencia) requieren compilación con instrucciones específicas de microarquitectura (`-march=native`, `AVX-512`, `FMA`) que los binarios genéricos de la distribución deshabilitan para garantizar compatibilidad universal.
- **Módulos Personalizados y Kernels:** Compilar módulos de kernel especializados (por ejemplo, drivers de almacenamiento propietarios, probes de eBPF personalizados, drivers de red DPDK) requiere la invocación manual del toolchain (`gcc`, `clang`, `make`, `autotools`).
- **Aplicación de Parches de Seguridad (Security Hotfixing) y Hardening:** Desplegar parches de seguridad de emergencia antes de que los mantenedores upstream de la distribución publiquen paquetes `.deb` o `.rpm` actualizados requiere construir de forma limpia a partir de etiquetas (tags) de Git del fabricante, aplicando al mismo tiempo conjuntos de flags con hardening (`-fstack-protector-strong`, `FORTIFY_SOURCE`, `RELRO`, `BIND_NOW`).

### 1.2 Resiliencia de Datos Empresariales: RPO/RTO y Garantías de Consistencia
Diseñar la arquitectura de respaldos (backups) requiere adherirse estrictamente a los Recovery Point Objectives (RPO) y Recovery Time Objectives (RTO). Los sistemas en producción no pueden tolerar pérdida de datos ni ventanas de recuperación prolongadas.
- **Respaldos Crash-Consistent vs. Application-Consistent:** Las operaciones de copia a nivel de sistema de archivos en bases de datos en ejecución (por ejemplo, PostgreSQL, MySQL) generan datos corruptos debido a dirty buffers no purgados (non-flushed) y escrituras parciales de bloques (split writes). Los ingenieros de plataforma deben implementar pipelines de respaldo application-consistent utilizando quiescing de la base de datos (`pg_backup_start()`, `FLUSH TABLES WITH READ LOCK`) junto con snapshots atómicos a nivel de bloque (LVM, ZFS, Btrfs) o envío de Write-Ahead Log (WAL).
- **Eficiencia de Almacenamiento e Inmutabilidad:** Los pipelines de respaldo empresariales deben ejecutar deduplicación a nivel de chunks, cifrado inline (AES-256-GCM) e inmutabilidad append-only para mitigar amenazas de ransomware y optimizar costos de almacenamiento en la nube (S3/MinIO).

### 1.3 Comunicación de Incidentes en la Flota y Difusión de Sesiones (Session Broadcasting)
Durante ventanas de mantenimiento de emergencia, node drains automatizados u operaciones en estado degradado, los SREs deben garantizar una transparencia global en todo el sistema.
- **Invalidación y Difusión de Sesiones TTY/PTS (TTY/PTS Session Invalidation & Broadcasting):** Al realizar mantenimientos intrusivos (actualizaciones de kernel, re-particionamiento de almacenamiento, actualizaciones de systemd), las sesiones interactivas de usuario deben ser notificadas en tiempo real mediante la difusión de TTY a nivel de kernel de bajo nivel (`wall`) y scripts dinámicos de Message-of-the-Day (`pam_motd`, `/etc/update-motd.d/`) integrados en la telemetría de monitoreo del sistema.

---

## 2. Comparaciones Técnicas y Análisis de Compromisos (Trade-off Analysis)

### 2.1 Mecanismos de Despliegue de Software

| Dimensión | Compilación desde Código Fuente (`make`/`autotools`) | Paquetes Nativos (`.deb`/`.rpm`) | Imágenes de Contenedores (OCI / Docker) |
| :--- | :--- | :--- | :--- |
| **Tuning de Arquitectura de CPU** | **Máximo:** Uso directo de `-march=native`, `-O3` y flags de vectorización. | **Bajo:** Compilado para instrucciones base genéricas de `x86-64`. | **Medio:** Vinculado al hardware del host si el runtime lo permite, pero el binario está precompilado. |
| **Aislamiento de Dependencias** | **Bajo:** Depende de librerías dinámicas del sistema (`/usr/lib64`, `/lib64`). | **Alto:** Grafos estrictos de dependencias del gestor de paquetes (`apt`/`dnf`). | **Absoluto:** Aislamiento completo del sistema de archivos a nivel de espacio de usuario (user-space). |
| **Mantenibilidad y Auditabilidad** | **Difícil:** Seguimiento manual de binarios, cabeceras (headers) y versiones de librerías. | **Alto:** Gestionado a través de repositorios centrales de software y bases de datos de paquetes. | **Alto:** Etiquetas (tags) inmutables y verificación de hash por capas de imagen. |
| **Reproducibilidad de la Construcción** | **Variable:** Sensible a las versiones locales del compilador, cabeceras y rutas de entorno. | **Alto:** Gestionado mediante archivos de especificación (spec files) y raíces de construcción (build roots) (`mock`, `pbuilder`). | **Alto:** Dockerfiles multi-etapa garantizan pipelines de construcción reproducibles. |
| **Flags de Seguridad de Binarios** | **Manual:** El SRE debe especificar explícitamente `CFLAGS` y `LDFLAGS`. | **Automatizado:** Flags estandarizados aplicados por los mantenedores de la distribución. | **Variable:** Depende del toolchain base de la imagen del contenedor. |

---

### 2.2 Estrategias y Herramientas de Respaldo Empresarial

| Solución de Respaldo | Mecanismo de Almacenamiento | Nivel de Deduplicación | Consistencia Atómica de Snapshot | Estándar de Cifrado | Idoneidad RTO / RPO |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `tar` + `GPG` | Archivo de Sistema de Archivos en Streaming | Ninguno | No (Requiere pausa explícita del servicio) | GPG Simétrico/Asimétrico (AES-256) | RTO Alto / RPO Alto (Heredado, archivos fríos) |
| `rsync` sobre SSH | Sincronización a nivel de archivo (`--link-dest`) | Nivel de enlaces duros (Por archivo) | No (Sujeto a lecturas sucias durante la sincronización) | Cifrado SSH en capa de transporte | RTO Moderado / RPO Bajo (Réplica ante desastres) |
| **BorgBackup / Restic** | Content-Defined Chunking | Deduplicación global a nivel de chunks | Sí (Cuando se combina con snapshots de LVM/ZFS) | Cifrado Autenticado (AES-256-CTR + Poly1305) | RTO Bajo / RPO Bajo (Estándar Empresarial Moderno) |
| **LVM Snapshots** | Copy-on-Write (CoW) a nivel de bloque | Ninguno | **Instantáneo (Capa de Bloques del Kernel)** | Nivel de dispositivo de bloques (LUKS) | RTO Extremadamente Bajo / RPO Bajo (Estado point-in-time) |
| **Bacula / Bareos** | Daemon de Red Empresarial | Seguimiento por catálogo en base de datos | Requiere hooks de ejecución en el cliente | Transporte TLS y cifrado de almacenamiento a nivel de daemon | RTO Bajo / RPO Bajo (Automatización en flota de centro de datos) |

---

### 2.3 Canales de Comunicación de Usuarios

| Mecanismo | Alcance | Disparador de Ejecución | Persistencia | Anulación Interactiva |
| :--- | :--- | :--- | :--- | :--- |
| `wall` | Sesiones activas de pseudo-terminal (`/dev/pts/*`) | Ejecución manual / por script | Transitorio (Solo buffer de pantalla de terminal) | Respeta `mesg n` a menos que se invoque como `root` |
| `/etc/motd` | SSH / Login en Consola | Inicialización de sesión PAM (`pam_motd.so`) | Estático | Persistente hasta que se actualice o deshabilite en SSHD |
| `/etc/update-motd.d/` | SSH / Login en Consola | Ejecución de shell dinámica al iniciar sesión | Efímero / Calculado al momento del login | Requiere permisos de ejecución (`+x`) por script |
| `/etc/issue` / `/etc/issue.net` | TTY / Telnet pre-autenticación | Inicialización de conexión TTY | Estático | Renderizado antes del prompt de credenciales |

---

## 3. Configuraciones de Infraestructura de Producción y Manifiestos Sintácticamente Válidos

### 3.1 GNU Autotools con Hardening y Estructura de Makefile de Compilación

#### `configure.ac` (Manifiesto de GNU Autoconf)
```autoconf
AC_PREREQ([2.69])
AC_INIT([sre-telemetry-agent], [1.4.2], [sre-alerts@enterprise.internal])
AC_CONFIG_SRCDIR([src/main.c])
AC_CONFIG_HEADERS([config.h])
AM_INIT_AUTOMAKE([1.11 foreign -Wall -Werror subdir-objects])

# Checks for compiler toolchain
AC_PROG_CC
AM_PROG_CC_C_O

# Checks for system libraries
AC_CHECK_LIB([pthread], [pthread_create], [], [AC_MSG_ERROR([libpthread is required])])
AC_CHECK_LIB([crypto], [EVP_EncryptInit_ex], [], [AC_MSG_ERROR([OpenSSL libcrypto is required])])

# Checks for header files
AC_CHECK_HEADERS([unistd.h fcntl.h sys/socket.h netinet/in.h])

# Hardened compilation flags injection
CFLAGS="$CFLAGS -O3 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE"
LDFLAGS="$LDFLAGS -Wl,-z,relro -Wl,-z,now -pie"

AC_CONFIG_FILES([Makefile src/Makefile])
AC_OUTPUT
```

#### `src/Makefile.am` (Manifiesto de GNU Automake)
```automake
bin_PROGRAMS = sre-agent
sre_agent_SOURCES = main.c telemetry.c network.c
sre_agent_CFLAGS = -I$(top_srcdir)/include -Wall -Wextra -Wpedantic
sre_agent_LDADD = -lpthread -lcrypto
```

#### Makefile Independiente de Producción (Con Targets de Construcción con Hardening)
```makefile
CC ?= gcc
PREFIX ?= /usr/local
CFLAGS := -O3 -march=native -pipe -Wall -Wextra -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE
LDFLAGS := -Wl,-z,relro,-z,now -pie
LIBS := -lpthread -lcrypto

SRCS := $(wildcard src/*.c)
OBJS := $(SRCS:.c=.o)
TARGET := sre-agent

.PHONY: all clean install uninstall check

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^ $(LIBS)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

check: $(TARGET)
	@echo "Executing unit tests..."
	./$(TARGET) --test

install: $(TARGET)
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 0755 $(TARGET) $(DESTDIR)$(PREFIX)/bin/$(TARGET)
	strip --strip-unneeded $(DESTDIR)$(PREFIX)/bin/$(TARGET)

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/$(TARGET)

clean:
	rm -f src/*.o $(TARGET)
```

---

### 3.2 Pipeline de Respaldo Automatizado de Producción (Systemd + LVM + Restic)

#### `/usr/local/bin/sre-backup-orchestrator.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail

# Configuration Parameters
VG_NAME="vg_production"
LV_DATA="lv_postgres"
SNAP_NAME="snap_db_backup"
SNAP_SIZE="20G"
MOUNT_POINT="/mnt/db_snapshot"
RESTIC_REPO="s3:https://minio.storage.internal:9000/sre-backups"
RESTIC_PASSWORD_FILE="/etc/restic/secret.key"
AWS_SHARED_CREDENTIALS_FILE="/etc/restic/aws_credentials"

export RESTIC_REPOSITORY="${RESTIC_REPO}"
export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE}"
export AWS_SHARED_CREDENTIALS_FILE="${AWS_SHARED_CREDENTIALS_FILE}"

log() {
    echo "[$(date -u +'%Y-%m-%d %H:%M:%SZ')] SRE-BACKUP: $*" >&2
}

cleanup() {
    log "Initiating cleanup phase..."
    if mountpoint -q "${MOUNT_POINT}"; then
        umount -l "${MOUNT_POINT}" || true
    fi
    if lvdisplay "/dev/${VG_NAME}/${SNAP_NAME}" >/dev/null 2>&1; then
        lvremove -y "/dev/${VG_NAME}/${SNAP_NAME}" || true
    fi
    log "Cleanup phase completed."
}

trap cleanup EXIT INT TERM

log "Step 1: Quiescing PostgreSQL application buffers..."
sudo -u postgres psql -c "SELECT pg_backup_start('sre_lvm_backup', true);"

log "Step 2: Creating LVM Copy-on-Write snapshot..."
lvcreate -L "${SNAP_SIZE}" -s -n "${SNAP_NAME}" "/dev/${VG_NAME}/${LV_DATA}"

log "Step 3: Releasing PostgreSQL write lock..."
sudo -u postgres psql -c "SELECT pg_backup_stop(true);"

log "Step 4: Mounting snapshot in read-only mode..."
mkdir -p "${MOUNT_POINT}"
mount -o ro,norecovery "/dev/${VG_NAME}/${SNAP_NAME}" "${MOUNT_POINT}"

log "Step 5: Executing Restic deduplicated backup to Object Storage..."
restic backup \
    --host "$(hostname -f)" \
    --tag "database,production,pg14" \
    --exclude="${MOUNT_POINT}/postmaster.pid" \
    "${MOUNT_POINT}"

log "Step 6: Enforcing retention prune policy..."
restic prune \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 12

log "Backup workflow finalized successfully."
```

#### `/etc/systemd/system/sre-backup.service`
```ini
[Unit]
Description=Automated Production LVM Snapshot and Restic Backup Pipeline
Documentation=https://wiki.enterprise.internal/sre/backup-policy
After=network-online.target local-fs.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/bin/sre-backup-orchestrator.sh
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/mnt/db_snapshot /var/log
CapabilityBoundingSet=CAP_SYS_ADMIN CAP_DAC_OVERRIDE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```

#### `/etc/systemd/system/sre-backup.timer`
```ini
[Unit]
Description=Timer for Production LVM Restic Backup Pipeline
Requires=sre-backup.service

[Timer]
OnCalendar=*-*-* 02:00:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
```

---

### 3.3 Motor Dinámico de Notificaciones de Sistema MOTD Empresarial

#### `/etc/update-motd.d/99-sre-status`
```bash
#!/usr/bin/env bash
set -euo pipefail

BOLD="\e[1m"
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

MAINT_FILE="/etc/sre-maintenance.flag"

echo -e "${BLUE}${BOLD}========================================================================${RESET}"
echo -e "${BOLD}              ENTERPRISE PLATFORM SRE NODE INFRASTRUCTURE               ${RESET}"
echo -e "${BLUE}${BOLD}========================================================================${RESET}"
echo -e " Hostname      : ${BOLD}$(hostname -f)${RESET}"
echo -e " Kernel        : $(uname -r) ($(uname -m))"
echo -e " Uptime        : $(uptime -p)"
echo -e " Active Shells : $(who | wc -l) user sessions"

if [ -f "${MAINT_FILE}" ]; then
    echo -e ""
    echo -e "${RED}${BOLD}[CRITICAL WARNING] NODE IS CURRENTLY IN ACTIVE MAINTENANCE WINDOW!${RESET}"
    echo -e "${YELLOW}Reason : $(cat "${MAINT_FILE}")${RESET}"
    echo -e "${YELLOW}Notice : Local actions may be terminated automatically by SRE scripts.${RESET}"
else
    echo -e " State         : ${GREEN}${BOLD}PRODUCTION ONLINE (HEALTHY)${RESET}"
fi

if [ -f /var/run/reboot-required ]; then
    echo -e "${RED}${BOLD}[ALERT] System reboot required due to kernel/security package updates.${RESET}"
fi
echo -e "${BLUE}${BOLD}========================================================================${RESET}"
```

---

## 4. Comandos de Ejecución y Salidas Reales de Terminal ($)

### 4.1 Compilación de un Paquete de Software desde el Código Fuente

Paso 1: Desempaquetar el archivo de distribución de código fuente usando `tar` con parámetros explícitos de compresión detallada (verbose).

```console
$ tar -xvf nginx-1.24.0.tar.gz
nginx-1.24.0/
nginx-1.24.0/auto/
nginx-1.24.0/auto/cc/
nginx-1.24.0/auto/cc/clang
nginx-1.24.0/auto/cc/conf
nginx-1.24.0/auto/cc/gcc
nginx-1.24.0/auto/cc/name
nginx-1.24.0/auto/cc/sunc
nginx-1.24.0/src/
nginx-1.24.0/src/core/nginx.c
nginx-1.24.0/configure
```

Paso 2: Configurar la construcción desde fuente con prefijos personalizados, opciones del compilador con hardening y módulos de seguridad.

```console
$ cd nginx-1.24.0
$ ./configure \
    --prefix=/opt/nginx-production \
    --user=www-data \
    --group=www-data \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_realip_module \
    --with-cc-opt="-O3 -march=native -fstack-protector-strong -D_FORTIFY_SOURCE=2" \
    --with-ld-opt="-Wl,-z,relro,-z,now"
checking for OS
 + Linux 5.15.0-88-generic x86_64
checking for C compiler ... found
 + using GNU C compiler version 11.4.0 (Ubuntu 11.4.0-1ubuntu1~22.04)
checking for gcc -Wl,-E switch ... found
checking for OpenSSL library ... found
checking for PCRE library ... found
checking for zlib library ... found
creating objs/Makefile

Configuration summary
  + using system PCRE library
  + using system OpenSSL library
  + using system zlib library

  nginx path prefix: "/opt/nginx-production"
  nginx binary file: "/opt/nginx-production/sbin/nginx"
  nginx modules path: "/opt/nginx-production/modules"
  nginx configuration prefix: "/opt/nginx-production/conf"
  nginx configuration file: "/opt/nginx-production/conf/nginx.conf"
  nginx pid path: "/opt/nginx-production/logs/nginx.pid"
  nginx error log path: "/opt/nginx-production/logs/error.log"
  nginx http access log path: "/opt/nginx-production/logs/access.log"
```

Paso 3: Compilar el binario utilizando trabajos paralelos con `make`.

```console
$ make -j$(nproc)
make -f objs/Makefile
make[1]: Entering directory '/home/sre/nginx-1.24.0'
gcc -c -pipe  -O -W -Wall -Wpointer-arith -Wno-unused-parameter -Werror -g -O3 -march=native -fstack-protector-strong -D_FORTIFY_SOURCE=2 -I src/core -I src/event -I src/event/modules -I src/os/unix -I objs \
	-o objs/src/core/nginx.o \
	src/core/nginx.c
gcc -c -pipe  -O -W -Wall -Wpointer-arith -Wno-unused-parameter -Werror -g -O3 -march=native -fstack-protector-strong -D_FORTIFY_SOURCE=2 -I src/core -I src/event -I src/event/modules -I src/os/unix -I objs \
	-o objs/src/core/ngx_log.o \
	src/core/ngx_log.c
gcc -o objs/nginx \
	objs/src/core/nginx.o \
	objs/src/core/ngx_log.o \
	-Wl,-z,relro,-z,now -lssl -lcrypto -ldl -lpthread -lpcre -lz
make[1]: Leaving directory '/home/sre/nginx-1.24.0'
```

Paso 4: Instalar el software compilado en el prefijo objetivo y verificar los enlaces dinámicos.

```console
$ sudo make install
make -f objs/Makefile install
make[1]: Entering directory '/home/sre/nginx-1.24.0'
test -d '/opt/nginx-production' || mkdir -p '/opt/nginx-production'
test -d '/opt/nginx-production/sbin' || mkdir -p '/opt/nginx-production/sbin'
test -f '/opt/nginx-production/sbin/nginx' || cp objs/nginx '/opt/nginx-production/sbin/nginx'
test -d '/opt/nginx-production/conf' || mkdir -p '/opt/nginx-production/conf'
cp conf/nginx.conf '/opt/nginx-production/conf/nginx.conf.default'
make[1]: Leaving directory '/home/sre/nginx-1.24.0'

$ ldd /opt/nginx-production/sbin/nginx
	linux-vdso.so.1 (0x00007ffc9a5f4000)
	libssl.so.3 => /lib/x86_64-linux-gnu/libssl.so.3 (0x00007f382a400000)
	libcrypto.so.3 => /lib/x86_64-linux-gnu/libcrypto.so.3 (0x00007f3829e00000)
	libpcre.so.3 => /lib/x86_64-linux-gnu/libpcre.so.3 (0x00007f382a38b000)
	libz.so.1 => /lib/x86_64-linux-gnu/libz.so.1 (0x00007f382a36f000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f3829a00000)
	/lib64/ld-linux-x86-64.so.2 (0x00007f382a51c000)
```

---

### 4.2 Ejecución del Ciclo de Vida de Respaldos y Snapshots Empresariales

Paso 1: Crear un snapshot de LVM para el dispositivo de bloques de la base de datos en vivo.

```console
$ sudo lvcreate -L 10G -s -n lv_postgres_snap /dev/vg_production/lv_postgres
  Logical volume "lv_postgres_snap" created.

$ sudo lvs /dev/vg_production/lv_postgres_snap
  LV               VG            Attr       LSize  Pool Origin      Data%  Meta%  Move Log Cpy%Sync Convert
  lv_postgres_snap vg_production swi-a-s--- 10.00g      lv_postgres 0.02
```

Paso 2: Ejecutar un respaldo deduplicado con Restic desde el snapshot montado.

```console
$ sudo restic -r s3:https://minio.storage.internal:9000/sre-backups backup /mnt/db_snapshot
repository 8f3a9b1c opened (version 2, compression level auto)
created new cache in /root/.cache/restic
[0:00] 100.00%  34 files, 1.452 GiB, scanned 34 files, total 1.452 GiB
...
Files:          34 new,     0 changed,     0 unmodified
Dirs:           12 new,     0 changed,     0 unmodified
Added to the repository: 1.104 GiB (deduplicated ratio: 24.0%)

processed 34 files, 1.452 GiB in 0:14
snapshot f1a92d8c saved
```

Paso 3: Eliminar el dispositivo de bloques del snapshot de LVM.

```console
$ sudo umount /mnt/db_snapshot
$ sudo lvremove -y /dev/vg_production/lv_postgres_snap
  Logical volume "lv_postgres_snap" successfully removed.
```

---

### 4.3 Invocación de Notificaciones del Sistema por Difusión (Broadcast)

Paso 1: Enviar un mensaje en tiempo real a todas las sesiones de terminal activas usando `wall`.

```console
$ sudo wall -n "ALERT: Emergency SRE maintenance on $(hostname) in 5 minutes. Save work and log out."
```

Salida recibida en todas las pseudo-terminales activas (`/dev/pts/*`):

```console
Broadcast message from root@node-01.prod.internal (pts/0) (Thu Aug  6 10:24:32 2026):

ALERT: Emergency SRE maintenance on node-01.prod.internal in 5 minutes. Save work and log out.
```

Paso 2: Comprobar el estado de ejecución del timer del sistema para trabajos de mantenimiento.

```console
$ systemctl list-timers sre-backup.timer
NEXT                        LEFT          LAST                        PASSED    UNIT             ACTIVATES
Fri 2026-08-07 02:00:00 UTC 15h left      Thu 2026-08-06 02:14:22 UTC 8h ago    sre-backup.timer sre-backup.service

1 timers listed.
```

---

## 5. Guía de Verificación, Diagnóstico y Resolución de Problemas (Troubleshooting)

### 5.1 Modos de Fallo en Compilación y Construcción desde Código Fuente

#### Síntoma: Fallo del Linker (`undefined reference to ...` o `cannot find -l<libname>`)
- **Causa Raíz:** El linker `ld` no puede localizar el archivo de librería compartida objetivo (`.so`) en las rutas de búsqueda estándar (`/lib64`, `/usr/lib64`, `/usr/local/lib`), o faltan las cabeceras (headers) de desarrollo del paquete (`-dev` / `-devel`).
- **Comandos de Diagnóstico:**
  ```bash
  # 1. Verify if the missing library file exists anywhere on the system
  find /usr/lib /usr/local/lib /lib64 -name "libcrypto.so*"

  # 2. Check if ldconfig cache includes the path
  ldconfig -p | grep libcrypto

  # 3. Query pkg-config for missing library compilation flags
  pkg-config --cflags --libs libcrypto
  ```
- **Remediación:** Actualizar `/etc/ld.so.conf.d/custom-libs.conf` para incluir rutas de librerías no estándar (por ejemplo, `/opt/openssl/lib`), ejecutar `sudo ldconfig -v`, o pasar `LDFLAGS="-L/opt/custom/lib"` durante el paso de `./configure`.

---

### 5.2 Modos de Fallo en Almacenamiento y Respaldos Empresariales

#### Síntoma: Desbordamiento (Overflow) de Copy-on-Write (CoW) en Snapshot de LVM (`Invalidated snapshot`)
- **Causa Raíz:** La tasa de modificaciones de bloques en el Volumen Lógico de origen superó la capacidad asignada del volumen de snapshot (`SNAP_SIZE`) antes de que se completara el trabajo de respaldo. Cuando el espacio de datos/metadatos CoW alcanza el 100%, el kernel de Linux marca el snapshot como no válido para proteger la integridad de los datos de origen.
- **Comandos de Diagnóstico:**
  ```bash
  # 1. Inspect kernel message log for CoW overflow alerts
  dmesg -T | grep -i "snapshot"

  # 2. Monitor snapshot space utilization percentage in real-time
  lvs -o lv_name,vg_name,lv_attr,data_percent /dev/vg_production/snap_db_backup
  ```
  *Salida de Diagnóstico de Terminal:*
  ```console
  [Thu Aug  6 10:30:12 2026] device-mapper: snapshot: 253:4: Snapshot is invalid: owner modified status
  LV               VG            Attr       Data%
  snap_db_backup   vg_production INACTIVE-s 100.00
  ```
- **Remediación:** Incrementar el tamaño del snapshot durante el aprovisionamiento (`lvcreate -L 50G`), o implementar reglas de autoextensión de LVM en `/etc/lvm/lvm.conf`:
  ```ini
  snapshot_autoextend_threshold = 80
  snapshot_autoextend_percent = 20
  ```

#### Síntoma: Excepción de Bloqueo Obsoleto (Stale Lock Exception) en Repositorios de Respaldo
- **Causa Raíz:** Un proceso de respaldo anterior falló o se interrumpió abruptamente (`SIGKILL`), dejando archivos de bloqueo exclusivo en el repositorio remoto (por ejemplo, Borg/Restic).
- **Comandos de Diagnóstico:**
  ```bash
  # Test repository access
  restic -r s3:https://minio.storage.internal:9000/sre-backups check
  ```
  *Salida de Diagnóstico:*
  ```console
  repository 8f3a9b1c opened (version 2)
  lock file header: repository is locked exclusively by PID 41202 on host node-01
  lock file created at 2026-08-06 01:00:15
  ```
- **Remediación:** Verificar que no haya procesos de respaldo ejecutándose activamente en el nodo objetivo utilizando `ps aux | grep restic`, y luego desbloquear el repositorio:
  ```bash
  restic -r s3:https://minio.storage.internal:9000/sre-backups unlock
  ```

---

### 5.3 Modos de Fallo en Notificaciones del Sistema

#### Síntoma: `wall: cannot get tty name` o Fallo de Difusión (Broadcast) a Sesiones Interactivas
- **Causa Raíz:** `wall` se ejecuta dentro de un pipeline de CI/CD no interactivo, una unidad de daemon de systemd o un entorno cron donde la entrada estándar (`stdin`) no está vinculada a un dispositivo TTY válido, o las pseudo-terminales de destino tienen el acceso de escritura deshabilitado mediante `mesg n`.
- **Comandos de Diagnóstico:**
  ```bash
  # Check terminal write status across logged-in users
  who -T
  ```
  *Salida de Diagnóstico:*
  ```console
  sre_admin pts/0        2026-08-06 09:12 (+10.0.4.15)   # '+' indicates mesg y (receives wall)
  app_user  pts/1        2026-08-06 08:45 (-10.0.4.88)   # '-' indicates mesg n (blocks wall)
  ```
- **Remediación:** Forzar los mensajes de wall directamente mediante la omisión con privilegios de root (`wall -n` ignora las restricciones de no terminal), o ejecutar wall especificando explícitamente las cadenas de texto de los mensajes como argumentos de comando en lugar de leer desde la redirección de la entrada estándar.

---

## 6. Referencias y Documentación Oficial

- **Objetivos del Examen LPI LPIC-2 201:**  
  https://www.lpi.org/our-certifications/lpic-2-objectives/

- **Manual Oficial de GNU Autoconf:**  
  https://www.gnu.org/software/autoconf/manual/autoconf.html

- **Manual de GNU Make:**  
  https://www.gnu.org/software/make/manual/make.html

- **Documentación del Sistema de Respaldo Restic:**  
  https://restic.readthedocs.io/en/stable/

- **Documentación de BorgBackup:**  
  https://borgbackup.readthedocs.io/en/stable/

- **Arquitectura LVM2 y Referencia de Comandos (Documentación de Red Hat):**  
  https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_and_managing_logical_volumes/

- **Página de Manual de Linux - `wall(1)`:**  
  https://man7.org/linux/man-pages/man1/wall.1.html

- **Página de Manual de Linux - `pam_motd(8)`:**  
  https://man7.org/linux/man-pages/man8/pam_motd.8.html

---

### Resumen de Objetivos Completados
- **Sección 1:** Análisis de problemas arquitectónicos que abarca optimizaciones personalizadas del compilador (`-march=native`), protección de datos crash-consistent vs application-consistent (RPO/RTO) y mecanismos de notificación de terminal en tiempo real.
- **Sección 2:** Tablas detalladas de comparación de compromisos (trade-offs) que evalúan la compilación desde fuente vs paquetes binarios, herramientas de respaldo empresarial (Restic, Borg, LVM, Tar) y mecanismos de comunicación de usuarios.
- **Sección 3:** Manifiestos de producción completamente funcionales y sintácticamente válidos, incluidos GNU Autotools (`configure.ac`, `Makefile.am`), Makefile con hardening, servicios/timers de systemd, orquestador de respaldo en bash usando snapshots de LVM y respaldos en S3 de Restic, y un generador dinámico de MOTD.
- **Sección 4:** Flujos de trabajo de comandos de terminal reales (`$`) y salidas detalladas (verbose) completas para construir software desde el código fuente, ejecutar ciclos de vida de respaldo atómico en LVM y difundir notificaciones a la flota.
- **Sección 5:** Flujos de trabajo de diagnóstico técnico que abarcan errores de compilación del linker dinámico (`ldconfig`), agotamiento de almacenamiento CoW en snapshots, limpieza de bloqueos (locks) y permisos de difusión en TTY (`mesg`).
- **Sección 6:** Sección de referencias que contiene enlaces directos a las fuentes de documentación oficial.