# Guía de estudio para la certificación LPI 702-100: BSD Specialist
## Tema 715.6: Personalizar o escribir scripts simples (Peso: 3.34)

---

### 1. Motivación y problema arquitectónico en producción

En infraestructuras empresariales BSD de misión crítica (FreeBSD, OpenBSD y NetBSD), la confiabilidad sistémica depende en gran medida de un scripting administrativo de bajo consumo de recursos, determinista y libre de dependencias. A diferencia de los entornos de ejecución de aplicaciones de alto nivel (como Python, Node.js o Go) o shells no estándar (como Bash o Zsh), se garantiza que el POSIX Bourne shell nativo (`/bin/sh`) existe dentro de la imagen mínima del sistema base. 

#### Contexto arquitectónico en producción
1. **Restricciones de arranque y recuperación:** Durante la inicialización temprana del sistema (`/etc/rc`), el modo de recuperación de usuario único (single-user recovery mode) o escenarios de recuperación ante desastres en los que los montajes `/usr` o `/usr/local` no están disponibles o están dañados, los entornos de ejecución que no forman parte del sistema base, como `/usr/local/bin/bash` o `/usr/local/bin/python3`, no se pueden ejecutar. Las tareas operativas —tales como comprobaciones del sistema de archivos, enlace de interfaces de red, arranque de contenedores jail/vmm y conmutaciones por error (failovers) de servicios— deben ejecutarse de forma nativa utilizando `/bin/sh`.
2. **Huella de recursos en entornos masivamente paralelos:** En hosts de virtualización densos que ejecutan cientos de instancias aisladas de FreeBSD Jails u OpenBSD VMM, generar entornos de ejecución de shell pesados para simples bucles de watchdog o rotaciones periódicas de registros (logs) introduce un consumo excesivo de memoria (memory bloat) y sobrecarga por conmutación de contexto de la CPU. El binario base `/bin/sh` (típicamente con un resident set size < 300 KB) se ejecuta con una latencia cercana a cero.
3. **El peligro de los "Bashisms" y el scripting en C-Shell:** Históricamente, los shells interactivos de usuario predeterminados en los sistemas BSD estaban configurados en C-Shell (`/bin/csh` o `/bin/tcsh`). El uso de `csh` para automatización no interactiva introduce fallos arquitectónicos graves: sintaxis inconsistente de redirección de descriptores de archivos (por ejemplo, falta de separación limpia `2>&1`), falta de capacidad de captura de señales (`trap`) y evaluación no estándar de variables en subshells. De manera similar, confiar en características de GNU Bash (como `[[ ... ]]`, arreglos `${arr[@]}` o reemplazos de cadenas no POSIX) rompe la portabilidad entre FreeBSD, OpenBSD y NetBSD.

#### Objetivo operativo
Como Principal Platform Architect, debe establecer estándares de producción donde todo el código de integración (glue code) de la infraestructura, los lanzadores de demonios del sistema, los scripts de control de servicios de `/etc/rc.d` y las tareas de cron de `/etc/periodic` se escriban estrictamente en POSIX `/bin/sh` portable y robusto, utilizando paradigmas de ejecución defensiva (`set -eu`), captura de señales, control de archivos de bloqueo (lock file), códigos de salida estándar (`sysexits.h`) e integración estructurada con syslog.

---

### 2. Comparaciones técnicas con tablas de caracterización y compromisos (Trade-off Tables)

#### Tabla 2.1: Runtimes de scripting para automatización del sistema en entornos BSD

| Característica / Métrica | POSIX `/bin/sh` (Base) | C-Shell `/bin/csh` / `/bin/tcsh` | GNU Bash `/usr/local/bin/bash` | Python 3 `/usr/local/bin/python3` |
| :--- | :--- | :--- | :--- | :--- |
| **Disponibilidad en el sistema base** | Garantizado (Sistema de archivos raíz `/bin`) | Garantizado (Sistema de archivos raíz `/bin`) | Requiere Ports/Packages (`/usr/local`) | Requiere Ports/Packages (`/usr/local`) |
| **Ejecución en modo monousuario (Single-User Mode)** | Nativo y sin restricciones | Nativo y sin restricciones | Falla si `/usr/local` no está montado | Falla si `/usr/local` no está montado |
| **Huella de memoria (RSS)** | ~200 KB - 500 KB | ~800 KB - 1.5 MB | ~3 MB - 6 MB | ~15 MB - 30 MB |
| **Cumplimiento de POSIX** | Estricto (IEEE Std 1003.1) | No cumple (sintaxis similar a C) | Conjunto de extensiones (POSIX + extensiones GNU) | N/A |
| **Manejo de errores y trampas (Traps)** | `trap` en `EXIT`, `INT`, `TERM` | Manejo de señales deficiente / limitado | Avanzado (`ERR` traps, `pipefail`) | Manejo nativo de excepciones |
| **Sintaxis de redirección de E/S** | Estándar (`>file 2>&1`, `exec 3>&1`) | Tosco (`>& file`, sin tubería limpia para stderr) | Estándar + Avanzado (`&>`, `<()`) | APIs enriquecidas de streams |
| **Caso de uso principal** | Scripts RC del sistema, mantenimiento periódico, código de integración base | Valor predeterminado heredado para prompt interactivo de root | Herramientas complejas de automatización por CLI | Procesamiento pesado de datos, clientes API |

#### Tabla 2.2: Modos de ejecución de scripts y herencia de contexto

| Modo de invocación | Sintaxis del comando | ID de proceso (`$$`) | Mutaciones de variables de entorno | Sobrecarga de subshell |
| :--- | :--- | :--- | :--- | :--- |
| **Ejecución directa (Shebang)** | `./script.sh` | Nuevo PID hijo | Aislado al proceso hijo | Genera un nuevo proceso `/bin/sh` |
| **Intérprete explícito** | `sh script.sh` | Nuevo PID hijo | Aislado al proceso hijo | Genera un nuevo proceso `/bin/sh` |
| **Ejecución mediante Source (Punto)** | `. ./script.sh` | Mismo PID del shell | Modifica el entorno del proceso padre actual | Sin sobrecarga de proceso (en línea) |
| **Generación en segundo plano** | `./script.sh &` | Nuevo PID hijo | Aislado al proceso hijo | Genera un proceso hijo independiente (detached) |

#### Tabla 2.3: Bashisms no portables frente a equivalentes portables en POSIX `/bin/sh`

| Construcción | No portable (Sintaxis Bash / GNU) | POSIX portable (Estándar BSD `/bin/sh`) | Justificación técnica |
| :--- | :--- | :--- | :--- |
| **Línea Shebang** | `#!/bin/bash` o `#!/usr/bin/env bash` | `#!/bin/sh` | Se garantiza la presencia de `/bin/sh` en el directorio raíz del sistema. |
| **Prueba condicional** | `if [[ $var == "val" ]]; then` | `if [ "$var" = "val" ]; then` | `[[` es una palabra clave de Bash; el `[` simple es una utilidad estándar de POSIX. |
| **Igualdad de cadenas** | `[ "$a" == "$b" ]` | `[ "$a" = "$b" ]` | El operador `==` dentro de `[` es una extensión de GNU. |
| **Salida con Echo** | `echo -e "Line1\nLine2"` | `printf '%s\n' "Line1" "Line2"` | Los flags de `echo` difieren entre BSD y System V/GNU. `printf` es determinista. |
| **Manipulación de cadenas**| `${var:0:4}` | `printf '%s' "$var" \| cut -c1-4` | La extracción de subcadenas en parámetros (parameter slicing) no es estándar en el `sh` base de POSIX. |
| **Variables locales** | `local var="value"` | `var="value"` (o `local var` en extensiones POSIX soportadas) | `local` se implementa ampliamente en el `sh` de BSD, pero POSIX estricto utiliza subshells `( ... )`. |
| **Datos en arreglos** | `arr=("a" "b"); echo ${arr[0]}` | `set -- "a" "b"; echo "$1"` | Los arreglos (arrays) no existen en POSIX `sh`. Utilice parámetros posicionales `$1, $2, ...` |

---

### 3. Scripts de shell de producción y manifiestos de infraestructura

#### 3.1 Utilidad de respaldo de base de datos y archivo de registros en producción
Ruta del archivo: `/usr/local/sbin/bsd-app-backup.sh`  
Permisos: `0755` (`root:wheel`)

```sh
#!/bin/sh
# ==============================================================================
# Script Name: bsd-app-backup.sh
# Architecture: Enterprise POSIX /bin/sh Infrastructure Automation Script
# Compatibility: FreeBSD, OpenBSD, NetBSD
# Description: Performs atomic system log and database backups with strict error
#              handling, file locking, syslog telemetry, and signal cleanup.
# ==============================================================================

# Enforce strict standard execution mode:
# -e: Exit immediately if a command exits with a non-zero status.
# -u: Treat unset variables as an error when expanding.
set -eu

# Define Standard Sysexits Exit Codes (BSD sysexits.h)
EX_OK=0
EX_USAGE=64
EX_SOFTWARE=70
EX_CANTCREAT=73
EX_TEMPFAIL=75

# Global Defaults
PROGRAM_NAME="$(basename "$0")"
LOCK_FILE="/var/run/${PROGRAM_NAME}.lock"
TMP_DIR=""
VERBOSE=0
BACKUP_DIR="/var/backups/app_data"
RETENTION_DAYS=7

# Logging helper function utilizing system logger(1)
log_message() {
    _priority="$1"
    _message="$2"
    logger -t "${PROGRAM_NAME}" -p "daemon.${_priority}" "${_message}"
    if [ "${VERBOSE}" -eq 1 ]; then
        printf '[%s] [%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "${_priority}" "${_message}" >&2
    fi
}

# Usage documentation
usage() {
    cat << EOF
Usage: ${PROGRAM_NAME} [-c config] [-d target_dir] [-v] [-h]

Options:
  -c CONFIG_FILE   Path to custom configuration file.
  -d TARGET_DIR    Directory where backups will be stored (Default: ${BACKUP_DIR}).
  -v               Enable verbose execution logging.
  -h               Display this help text and exit.

Exit Codes:
  0 (EX_OK)        Operation completed successfully.
  64 (EX_USAGE)    Invalid command-line flags or arguments passed.
  70 (EX_SOFTWARE) Internal execution or runtime error encountered.
  73 (EX_CANTCREAT) Output directory creation failed.
EOF
}

# Signal Handler and Cleanup Trap Function
cleanup() {
    # Save exit status of the process that triggered trap
    _exit_code=$?
    
    # Disable signals to prevent recursive traps during teardown
    trap - INT TERM EXIT

    log_message "info" "Performing cleanup teardown tasks..."

    # Remove temporary directory safely
    if [ -n "${TMP_DIR:-}" ] && [ -d "${TMP_DIR}" ]; then
        rm -rf "${TMP_DIR}"
        log_message "debug" "Removed temporary directory: ${TMP_DIR}"
    fi

    # Release lockfile if owned by this script PID
    if [ -f "${LOCK_FILE}" ]; then
        _lock_pid="$(cat "${LOCK_FILE}" 2>/dev/null || true)"
        if [ "${_lock_pid}" = "$$" ]; then
            rm -f "${LOCK_FILE}"
            log_message "debug" "Released lockfile: ${LOCK_FILE}"
        fi
    fi

    log_message "info" "Process finished with exit code ${_exit_code}."
    exit "${_exit_code}"
}

# Register traps for graceful interrupt/termination handling
trap cleanup INT TERM EXIT

# Atomic Lock Acquisition using BSD lockf(1) logic pattern
acquire_lock() {
    if [ -f "${LOCK_FILE}" ]; then
        _existing_pid="$(cat "${LOCK_FILE}" 2>/dev/null || true)"
        if [ -n "${_existing_pid}" ] && kill -0 "${_existing_pid}" 2>/dev/null; then
            log_message "err" "Another instance is running under PID ${_existing_pid}. Aborting."
            exit ${EX_TEMPFAIL}
        else
            log_message "warning" "Stale lockfile detected for PID ${_existing_pid}. Overwriting."
        fi
    fi
    printf '%s\n' "$$" > "${LOCK_FILE}"
}

# Parse Command Line Options using POSIX getopts
CONFIG_FILE=""

while getopts "c:d:vh" opt; do
    case "${opt}" in
        c)
            CONFIG_FILE="${OPTARG}"
            ;;
        d)
            BACKUP_DIR="${OPTARG}"
            ;;
        v)
            VERBOSE=1
            ;;
        h)
            usage
            exit ${EX_OK}
            ;;
        *)
            usage
            exit ${EX_USAGE}
            ;;
    esac
done

shift $((OPTIND - 1))

# Load external configuration if defined
if [ -n "${CONFIG_FILE}" ]; then
    if [ -r "${CONFIG_FILE}" ]; then
        # Source external parameters in-line
        . "${CONFIG_FILE}"
        log_message "info" "Loaded configuration file: ${CONFIG_FILE}"
    else
        log_message "err" "Cannot read configuration file: ${CONFIG_FILE}"
        exit ${EX_SOFTWARE}
    fi
fi

# Acquire operational lock
acquire_lock

log_message "info" "Starting production backup execution..."

# Create necessary backup directories
if [ ! -d "${BACKUP_DIR}" ]; then
    log_message "info" "Creating backup directory: ${BACKUP_DIR}"
    mkdir -p "${BACKUP_DIR}" || {
        log_message "err" "Failed to create directory ${BACKUP_DIR}"
        exit ${EX_CANTCREAT}
    }
fi

# Create a secure temporary directory using mktemp(1)
TMP_DIR="$(mktemp -d /tmp/${PROGRAM_NAME}.XXXXXX)"
log_message "debug" "Created temp directory: ${TMP_DIR}"

# Perform payload backup compilation
TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
ARCHIVE_NAME="app_backup_${TIMESTAMP}.tar.gz"
TARGET_ARCHIVE="${BACKUP_DIR}/${ARCHIVE_NAME}"

# Example payload target: /etc and /var/log
log_message "info" "Archiving system configuration state..."
tar -czf "${TMP_DIR}/${ARCHIVE_NAME}" -C / etc var/log >/dev/null 2>&1

# Atomic move from temporary staging directory to final target location
mv "${TMP_DIR}/${ARCHIVE_NAME}" "${TARGET_ARCHIVE}"
chmod 0600 "${TARGET_ARCHIVE}"

log_message "info" "Successfully created backup: ${TARGET_ARCHIVE}"

# Enforce Retention Policy: purge archives older than RETENTION_DAYS
log_message "info" "Applying retention policy: purging files older than ${RETENTION_DAYS} days..."
find "${BACKUP_DIR}" -type f -name "app_backup_*.tar.gz" -mtime +"${RETENTION_DAYS}" -exec rm -f {} +

log_message "info" "Backup workflow finalized successfully."

exit ${EX_OK}
```

---

#### 3.2 Integración de script RC para demonio de FreeBSD en producción
Ruta del archivo: `/usr/local/etc/rc.d/syswatchd`  
Permisos: `0755` (`root:wheel`)

```sh
#!/bin/sh
# ==============================================================================
# PROVIDE: syswatchd
# REQUIRE: LOGIN DAEMON NETWORKING
# KEYWORD: shutdown
# ==============================================================================

. /etc/rc.subr

name="syswatchd"
rcvar="syswatchd_enable"

# Execution configuration parameters
command="/usr/local/sbin/bsd-app-backup.sh"
command_args="-v -d /var/backups/syswatchd > /var/log/syswatchd.log 2>&1 &"
pidfile="/var/run/${name}.pid"

# Define mandatory default options
load_rc_config "${name}"
: ${syswatchd_enable:="NO"}
: ${syswatchd_flags:=""}

# Custom pre-start verification check
syswatchd_precmd() {
    if [ ! -x "${command}" ]; then
        err 1 "Binary executable ${command} does not exist or lacks execute permissions."
    fi
}

start_precmd="syswatchd_precmd"

run_rc_command "$1"
```

---

#### 3.3 Tarea de mantenimiento periódico de FreeBSD en producción
Ruta del archivo: `/usr/local/etc/periodic/daily/999.app-healthcheck`  
Permisos: `0755` (`root:wheel`)

```sh
#!/bin/sh
# ==============================================================================
# Daily periodic health monitoring integration for FreeBSD periodic(8)
# ==============================================================================

if [ -r /etc/defaults/periodic.conf ]; then
    . /etc/defaults/periodic.conf
    source_periodic_confs
fi

# Define local configuration variable default
: ${daily_app_healthcheck_enable:="NO"}

rc=0

case "${daily_app_healthcheck_enable}" in
    [Yy][Ee][Ss])
        echo ""
        echo "Running Daily Application Health & Backup Verification:"
        
        if /usr/local/sbin/bsd-app-backup.sh -v; then
            echo " Daily backup completed cleanly."
            rc=0
        else
            echo " Daily backup encountered operational errors!"
            rc=3
        fi
        ;;
    *)
        rc=0
        ;;
esac

exit ${rc}
```

---

### 4. Comandos reales de CLI y salidas de terminal ($)

#### 4.1 Configuración de permisos del script y verificación de sintaxis POSIX
Verifique la sintaxis del script sin ejecutar el código utilizando el flag `-n` (no-exec) y rastree la ejecución utilizando `-x`.

```syslog
$ sudo chmod 0755 /usr/local/sbin/bsd-app-backup.sh
$ sudo chown root:wheel /usr/local/sbin/bsd-app-backup.sh

$ sh -n /usr/local/sbin/bsd-app-backup.sh
$ echo $?
0

$ /usr/local/sbin/bsd-app-backup.sh -h
Usage: bsd-app-backup.sh [-c config] [-d target_dir] [-v] [-h]

Options:
  -c CONFIG_FILE   Path to custom configuration file.
  -d TARGET_DIR    Directory where backups will be stored (Default: /var/backups/app_data).
  -v               Enable verbose execution logging.
  -h               Display this help text and exit.

Exit Codes:
  0 (EX_OK)        Operation completed successfully.
  64 (EX_USAGE)    Invalid command-line flags or arguments passed.
  70 (EX_SOFTWARE) Internal execution or runtime error encountered.
  73 (EX_CANTCREAT) Output directory creation failed.

$ echo $?
0
```

#### 4.2 Ejecución del script con salida detailed (verbose) y verificación de syslog

```syslog
$ sudo /usr/local/sbin/bsd-app-backup.sh -v -d /var/backups/test_run
[2026-08-07 04:15:01] [info] Starting production backup execution...
[2026-08-07 04:15:01] [info] Creating backup directory: /var/backups/test_run
[2026-08-07 04:15:01] [debug] Created temp directory: /tmp/bsd-app-backup.sh.X891a2
[2026-08-07 04:15:01] [info] Archiving system configuration state...
[2026-08-07 04:15:02] [info] Successfully created backup: /var/backups/test_run/app_backup_20260807_041501.tar.gz
[2026-08-07 04:15:02] [info] Applying retention policy: purging files older than 7 days...
[2026-08-07 04:15:02] [info] Backup workflow finalized successfully.
[2026-08-07 04:15:02] [info] Performing cleanup teardown tasks...
[2026-08-07 04:15:02] [debug] Removed temporary directory: /tmp/bsd-app-backup.sh.X891a2
[2026-08-07 04:15:02] [debug] Released lockfile: /var/run/bsd-app-backup.sh.lock
[2026-08-07 04:15:02] [info] Process finished with exit code 0.

$ sudo tail -n 6 /var/log/messages
Aug  7 04:15:01 bsd-node01 bsd-app-backup.sh[48210]: Starting production backup execution...
Aug  7 04:15:01 bsd-node01 bsd-app-backup.sh[48210]: Creating backup directory: /var/backups/test_run
Aug  7 04:15:01 bsd-node01 bsd-app-backup.sh[48210]: Archiving system configuration state...
Aug  7 04:15:02 bsd-node01 bsd-app-backup.sh[48210]: Successfully created backup: /var/backups/test_run/app_backup_20260807_041501.tar.gz
Aug  7 04:15:02 bsd-node01 bsd-app-backup.sh[48210]: Backup workflow finalized successfully.
Aug  7 04:15:02 bsd-node01 bsd-app-backup.sh[48210]: Process finished with exit code 0.
```

#### 4.3 Pruebas de prevención de concurrencia mediante archivo de bloqueo (Lock File)

```syslog
$ sudo touch /var/run/bsd-app-backup.sh.lock
$ sudo sh -c 'echo "99999" > /var/run/bsd-app-backup.sh.lock'

# Spawn parallel execution while simulated PID is active:
$ sudo /usr/local/sbin/bsd-app-backup.sh -v
[2026-08-07 04:18:10] [err] Another instance is running under PID 99999. Aborting.
[2026-08-07 04:18:10] [info] Performing cleanup teardown tasks...
[2026-08-07 04:18:10] [info] Process finished with exit code 75.

$ echo $?
75
```

#### 4.4 Gestión de la integración del servicio RC de FreeBSD

```syslog
$ sudo sysrc syswatchd_enable="YES"
syswatchd_enable: NO -> YES

$ sudo service syswatchd status
syswatchd is not running.

$ sudo service syswatchd start
Starting syswatchd.

$ sudo service syswatchd status
syswatchd is running as pid 51022.
```

---

### 5. Guía de verificación y diagnóstico de fallos

```
                      +----------------------------------+
                      | Script Execution Failure Detected|
                      +----------------------------------+
                                       |
                                       v
                     +-----------------------------------+
                     | Run Syntax Check: sh -n script.sh |
                     +-----------------------------------+
                                       |
                     +-----------------+-----------------+
                     |                                   |
             [ Syntax Error ]                     [ Syntax OK ]
                     |                                   |
                     v                                   v
    +----------------------------------+ +----------------------------------+
    | Check Shebang & Line Endings     | | Trace Execution: sh -vx script.sh|
    | (Remove CR '\r' DOS line breaks) | +----------------------------------+
    +----------------------------------+                 |
                                                         v
                                       +----------------------------------+
                                       | Identify Failure Mode Category   |
                                       +----------------------------------+
                                         /               |              \
                                        /                |               \
                                       v                 v                v
                       +------------------+    +-------------------+   +--------------------+
                       | Variable Expansion|    | Subshell Scope    |   | Non-Zero Exit Code |
                       | Failure (set -u) |    | Pipe Mutation     |   | Unhandled Error    |
                       +------------------+    +-------------------+   +--------------------+
                               |                         |                        |
                               v                         v                        v
                       +------------------+    +-------------------+   +--------------------+
                       | Audit Parameter  |    | Replace Pipes with|   | Add Guard Clauses  |
                       | Initialization & |    | Process Substitution| | or Explicit Error  |
                       | Default Values   |    | or Here-Documents |   | Handling Traps     |
                       | "${VAR:-default}"|    +-------------------+   +--------------------+
                       +------------------+
```

#### Matriz de problemas comunes en scripting de shell para BSD y estrategias de remediación

| Síntoma de fallo / Salida de registro (Log) | Análisis de causa raíz | Estrategia de remediación |
| :--- | :--- | :--- |
| `sh: [[: not found` o `sh: syntax error: unexpected "("` | El script contiene Bashisms (palabras clave `[[` o definiciones de función `func()`) ejecutados bajo `/bin/sh`. | Reemplace `[[ ... ]]` con construcciones de prueba POSIX `[ ... ]`. Defina funciones estrictamente como `fname() { ... }` sin la palabra clave `function`. |
| `parameter not set` (El script termina inesperadamente) | `set -u` está activo y se hizo referencia directa a una variable opcional o no inicializada. | Utilice los valores predeterminados de expansión de parámetros POSIX: `${VARIABLE:-default_value}` o `${VARIABLE:-}` para variables opcionales. |
| Las variables modificadas dentro de `while read line; do ... done < file` se pierden después de que el bucle finaliza. | En POSIX `sh`, redirigir la salida de un comando mediante tubería (pipe) hacia un bucle (`cat file \| while read line`) ejecuta el bucle dentro de un fork/subshell. | Redirija la entrada a la construcción del bucle directamente desde un archivo o redirección: `while read line; do ... ... done < "${FILE}"`. |
| `echo -e` imprime `-e` de forma literal en stdout. | La utilidad `echo` nativa de BSD no implementa el flag `-e` (es una extensión de GNU/Bash). | Estandarice el formato de salida utilizando `printf '%s\n' "string"` en lugar de `echo`. |
| Los procesos bloqueados entran en interbloqueo (deadlock) tras el reinicio del sistema. | El archivo de bloqueo (lockfile) `/var/run/script.lock` persistió tras caídas del sistema sin verificación de PID obsoleto. | Valide la existencia del proceso utilizando `kill -0 "${PID}" 2>/dev/null` antes de rechazar la ejecución, o utilice la utilidad atómica `lockf(1)`. |
| El script falla silenciosamente durante el arranque temprano o ejecuciones de `cron`. | Se asume erróneamente que la variable `PATH` contiene `/usr/local/bin` o `/usr/local/sbin`. | Defina explícitamente `PATH` en el encabezado del script: `PATH="/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin"`. |

---

### 6. Referencias

* **Visión general de la certificación LPI BSD Specialist:**  
  [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

* **Guía de arquitectura y scripting de shell en FreeBSD (`sh(1)`):**  
  [https://man.freebsd.org/cgi/man.cgi?query=sh&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=sh&sektion=1)

* **Framework de control de servicios RC Subr en FreeBSD (`rc.subr(8)`):**  
  [https://man.freebsd.org/cgi/man.cgi?query=rc.subr&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=rc.subr&sektion=8)

* **Páginas del manual de OpenBSD - Especificaciones del shell POSIX (`sh(1)`):**  
  [https://man.openbsd.org/sh.1](https://man.openbsd.org/sh.1)

* **IEEE Std 1003.1-2017 (Especificación de Shell y Utilidades POSIX):**  
  [https://pubs.opengroup.org/onlinepubs/9699919799/utilities/sh.html](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/sh.html)

* **Especificación del encabezado estándar Sysexits en BSD (`sysexits(3)`):**  
  [https://man.freebsd.org/cgi/man.cgi?query=sysexits&sektion=3](https://man.freebsd.org/cgi/man.cgi?query=sysexits&sektion=3)