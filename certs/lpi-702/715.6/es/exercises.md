# LPI BSD Specialist (Examen 702-100) | Tema 715.6: Personalizar o escribir scripts simples

## Resumen ejecutivo y visión general de la arquitectura

En los sistemas operativos BSD (FreeBSD, OpenBSD, NetBSD), los scripts de shell sirven como el pegamento de automatización fundamental para la inicialización del sistema (subrutinas `rc.d`), hooks de gestión de paquetes (scripts de `pkg`), ejecución de cron y tareas de administración de SRE. 

Comprender el **Tema 715.6: Personalizar o escribir scripts simples** requiere un entendimiento preciso de la mecánica de ejecución de shell, la interpretación del shebang a nivel de kernel, las reglas de expansión de parámetros, el manejo de señales y las compensaciones entre shells interactivos (`csh`/`tcsh`) y shells de scripting del sistema (`/bin/sh`).

```
+-------------------------------------------------------------------------------+
|                             Kernel space (execve)                             |
+-------------------------------------------------------------------------------+
                                      | Reads magic bytes: #! /bin/sh
                                      v
+-------------------------------------------------------------------------------+
| /bin/sh Interpreter (Almquist / Korn derivative)                              |
| - Fast startup, minimal memory footprint                                      |
| - POSIX IEEE 1003.2 strict compliance                                          |
| - Standard for system initialization & rc.d sub-routines                      |
+-------------------------------------------------------------------------------+
       |                                      |                               
       v (Positional Parameters)              v (Special Parameters)          
  $1, $2, $@, $*                         $?, $$, $!, $#, $-                   
```

### 1. Mecánica del shebang del kernel (`execve(2)`)
Cuando un script se ejecuta a través de `./script.sh` o mediante `execve(2)`:
1. El kernel inspecciona los primeros dos bytes del archivo. Si coinciden con el número mágico `0x23 0x21` (`#!`), el kernel analiza el resto de la línea como una directiva de intérprete.
2. El kernel invoca la ruta del binario especificada después de `#!` (por ejemplo, `/bin/sh`) y pasa la ruta del archivo de script como argumento a ese intérprete.
3. Si el bit de permiso de ejecución (`+x`) no está configurado en el archivo de script, `execve(2)` falla con `EACCES` (Permiso denegado) antes de que se pueda lanzar el intérprete.

### 2. Arquitectura de shell y compensaciones: `/bin/sh` vs. `csh`/`tcsh` vs. `bash`

| Característica | BSD POSIX Shell (`/bin/sh`) | C Shell (`csh` / `tcsh`) | GNU Bourne-Again Shell (`bash`) |
| :--- | :--- | :--- | :--- |
| **Caso de uso principal** | Scripts del sistema base, servicios `rc.d`, tareas de cron. | Shell interactivo del usuario root (predeterminado histórico). | Shell interactivo de usuario (instalado a través de ports/paquetes). |
| **Portabilidad** | Alta (estándar POSIX en BSD y Linux). | Baja (sintaxis de control no estándar, errores únicos). | Media (requiere paquete de dependencia de terceros). |
| **Huella de recursos** | Extremadamente ligero (~cientos de KB). | Moderado (~1 MB). | Pesado (~2-5 MB + bibliotecas externas). |
| **Sintaxis de flujo de control** | `if ... then ... fi`, `case ... esac` | `if (...) then ... endif` | Extensiones POSIX (`[[ ]]`, arrays, etc.) |
| **Motor de redirección** | Control limpio de descriptores de archivo stdin/stdout/stderr. | Redirección tosca (por ejemplo, falta de tuberías sencillas de stderr). | Redirecciones avanzadas de descriptores de archivo. |

> [!IMPORTANT]
> **Estándar de producción**: Los scripts del sistema en entornos BSD **deben** apuntar a `/bin/sh`. Depender de `/usr/local/bin/bash` crea una dependencia innecesaria de ports de terceros (`/usr/local`), lo que puede romperse durante la recuperación de desastres del sistema base o en modos de reparación de emergencia monousuario.

---

## Ejercicios guiados

### Ejercicio 1: Mecánica de ejecución de shebang, permisos de archivos y compensaciones en la selección de shell

#### Objetivo
Comprender cómo el kernel BSD analiza los bytes mágicos de un script (`#!`), aplicar bits de ejecución del sistema de archivos, observar las diferencias entre ejecutar scripts bajo `/bin/sh` frente a `/bin/csh`, y verificar las limitaciones de la flag de montaje `noexec`.

#### Paso 1: Crear un script de sistema POSIX `/bin/sh` básico
Ejecute el siguiente comando para generar un script de diagnóstico del sistema base en `/tmp/sys_info.sh`:

```bash
cat << 'EOF' > /tmp/sys_info.sh
#!/bin/sh
# System Diagnostic Script for BSD Specialist 702-100

OS_NAME=$(uname -s)
OS_REL=$(uname -r)

echo "Operating System: ${OS_NAME}"
echo "Kernel Release:   ${OS_REL}"
EOF
```

#### Paso 2: Probar los permisos de ejecución e inspeccionar los atributos del archivo
Ejecute `ls -l` e intente la ejecución directa antes de configurar los bits de ejecución:

```bash
ls -l /tmp/sys_info.sh
/tmp/sys_info.sh
```

**Salida esperada:**
```text
-rw-r--r--  1 root  wheel  165 Aug  7 04:10 /tmp/sys_info.sh
-sh: /tmp/sys_info.sh: Permission denied
```

#### Paso 3: Otorgar permisos de ejecución y verificar los bytes mágicos del binario
Use `chmod` para agregar privilegios de ejecución, inspeccione el tipo de archivo con `file(1)` y ejecute el script:

```bash
chmod 755 /tmp/sys_info.sh
file /tmp/sys_info.sh
/tmp/sys_info.sh
```

**Salida esperada:**
```text
/tmp/sys_info.sh: POSIX shell script text executable
Operating System: FreeBSD
Kernel Release:   14.0-RELEASE
```

#### Paso 4: Comparar el fallo de sintaxis de `/bin/sh` bajo `csh`
Intente ejecutar el script de shell POSIX explícitamente usando `/bin/csh` para observar la incompatibilidad de sintaxis:

```bash
/bin/csh /tmp/sys_info.sh
```

**Salida esperada:**
```text
OS_NAME=FreeBSD: Command not found.
OS_REL=14.0-RELEASE: Command not found.
OS_NAME: Undefined variable.
```

---

#### Preguntas de verificación (Bloque 1)

1. **¿Por qué `/bin/csh` no pudo ejecutar `/tmp/sys_info.sh` a pesar de que la línea shebang `#!/bin/sh` estaba especificada en la línea 1?**
   - A) La línea shebang fue ignorada porque no se ejecutó `chmod 755` antes de la ejecución de `csh`.
   - B) Pasar un archivo de script como argumento directo a un comando intérprete (por ejemplo, `/bin/csh script.sh`) omite la evaluación shebang de `execve(2)` del kernel y fuerza al binario especificado (`csh`) a analizar el archivo directamente.
   - C) `csh` convierte automáticamente la sintaxis POSIX a menos que la extensión del archivo de script sea `.posix`.
   - D) Los kernels BSD solo analizan shebangs si el script reside dentro de `/usr/bin`.

2. **Si `/tmp` está montado con la opción `noexec` en `/etc/fstab`, ¿qué sucede cuando un usuario ejecuta `/tmp/sys_info.sh` directamente en comparación con ejecutar `sh /tmp/sys_info.sh`?**
   - A) Ambos comandos fallan con `Permission denied`.
   - B) La ejecución directa (`/tmp/sys_info.sh`) falla a nivel de kernel con `Permission denied`, pero `sh /tmp/sys_info.sh` tiene éxito porque `/bin/sh` (ubicado en una partición ejecutable) lee `/tmp/sys_info.sh` como un archivo de datos estándar.
   - C) Ambos comandos tienen éxito porque `root` omite las flags de sistema de archivos `noexec`.
   - D) La ejecución directa tiene éxito, pero `sh /tmp/sys_info.sh` falla debido a las comprobaciones de integridad binaria.

---

### Ejercicio 2: Parámetros posicionales, parámetros especiales y mecánica de análisis de argumentos

#### Objetivo
Dominar el manejo de parámetros posicionales (`$1`, `$2`, `$@`, `$*`), desplazamiento de parámetros (`shift`), seguimiento de recuento (`$#`), identificación de procesos (`$$`), seguimiento de subshell en segundo plano (`$!`) y estados de salida (`$?`).

#### Paso 1: Crear un script auditor de parámetros de producción
Escriba el siguiente script en `/tmp/param_auditor.sh`:

```bash
cat << 'EOF' > /tmp/param_auditor.sh
#!/bin/sh
# Audit and process incoming positional parameters

echo "Script Name (\$0):         $0"
echo "Total Parameters (\$#):    $#"
echo "Process ID (\$process):     $$"

echo "\n--- Processing Parameters with \$@ ---"
count=1
for param in "$@"; do
    echo "Param ${count}: ${param}"
    count=$((count + 1))
done

echo "\n--- Demonstrating \$* vs \$@ Difference ---"
echo "Quoted \$*: '$*'"
echo "Quoted \$@: '$@'"

echo "\n--- Shift Operation ---"
if [ $# -ge 2 ]; then
    echo "First parameter before shift: $1"
    shift
    echo "First parameter after shift:  $1"
    echo "Remaining parameters (\$#):    $#"
fi

# Launch background task to demonstrate $!
sleep 2 &
BG_PID=$!
echo "\nBackground process launched with PID (\$!): ${BG_PID}"

wait ${BG_PID}
echo "Background Process Exit Status (\$?): $?"
EOF

chmod +x /tmp/param_auditor.sh
```

#### Paso 2: Ejecutar el script con argumentos diversos
Ejecute el script auditor de parámetros pasando múltiples argumentos, incluidas cadenas entrecomilladas que contengan espacios:

```bash
/tmp/param_auditor.sh "adm service" pkg-update --force
```

**Salida esperada:**
```text
Script Name ($0):         /tmp/param_auditor.sh
Total Parameters ($#):    3
Process ID ($process):     48192

--- Processing Parameters with $@ ---
Param 1: adm service
Param 2: pkg-update
Param 3: --force

--- Demonstrating $* vs $@ Difference ---
Quoted $*: 'adm service pkg-update --force'
Quoted $@: 'adm service pkg-update --force'

--- Shift Operation ---
First parameter before shift: adm service
First parameter after shift:  pkg-update
Remaining parameters ($#):    2

Background process launched with PID ($!): 48195
Background Process Exit Status ($?): 0
```

---

#### Preguntas de verificación (Bloque 2)

3. **¿Cuál es la diferencia crítica entre `"$@"` y `"$*"` al iterar sobre parámetros posicionales de un script que contienen espacios (por ejemplo, `"adm service" "pkg-update"`)?**
   - A) `"$@"` se expande a palabras separadas (`"adm service"` `"pkg-update"`), preservando los límites de parámetros originales, mientras que `"$*"` concatena todos los parámetros en una sola cadena separada por el primer carácter de `IFS` (`"adm service pkg-update"`).
   - B) `"$*"` preserva los límites de los parámetros, mientras que `"$@"` divide las cadenas en los espacios.
   - C) `"$@"` solo incluye argumentos numéricos, mientras que `"$*"` incluye argumentos alfanuméricos.
   - D) No hay diferencia funcional en BSD POSIX `/bin/sh`.

4. **En un script de mantenimiento de producción BSD, ¿cuál es el valor de `$?` inmediatamente después de que falla un comando y cómo puede un arquitecto garantizar que el script detenga la ejecución ante cualquier error no controlado?**
   - A) `$?` contiene `0`; ejecute `set -u` para detener la ejecución ante errores.
   - B) `$?` contiene un entero no nulo (1-255) que representa el código de salida del comando; incluya `set -e` en el encabezado del script para indicar a `/bin/sh` que salga inmediatamente si cualquier comando simple devuelve un estado de salida no nulo.
   - C) `$?` contiene el PID del proceso fallido; use `trap 'exit'` para detener la ejecución.
   - D) `$?` contiene la cadena `"ERROR"`; use `set -o pipefail` únicamente.

---

### Ejercicio 3: Flujo de control avanzado, manejo de señales y diagnóstico de scripts de producción

#### Objetivo
Implementar un manejo limpio de señales (`trap`), redirección de error estándar (`>&2`), verificación estricta de errores (`set -eu`), validación condicional robusta mediante `test`/`[ ]`, verificación de sintaxis (`sh -n`) y rastreo de ejecución (`sh -x`).

#### Paso 1: Crear un script de limpieza de sistema resiliente
Escriba un script de producción en `/tmp/bsd_cleaner.sh` que limpie archivos de registro temporales, atrape señales de terminación, maneje entradas no válidas de forma elegante y dirija los errores a la salida de error estándar:

```bash
cat << 'EOF' > /tmp/bsd_cleaner.sh
#!/bin/sh
# Robust BSD Temp Log Cleaner
set -eu

LOCKFILE="/tmp/bsd_cleaner.lock"

# Cleanup function invoked on signals or exit
cleanup() {
    exit_code=$?
    echo "[DEBUG] Running cleanup trap (Exit Code: ${exit_code})..."
    rm -f "${LOCKFILE}"
}

# Trap signals INT (Ctrl+C), TERM (kill), and EXIT
trap cleanup INT TERM EXIT

# Ensure single instance execution
if [ -e "${LOCKFILE}" ]; then
    echo "ERROR: Lockfile ${LOCKFILE} exists. Script already running." >&2
    exit 1
fi
touch "${LOCKFILE}"

# Validate parameter input
TARGET_DIR="${1:-}"

if [ -z "${TARGET_DIR}" ]; then
    echo "Usage: $0 <target_directory>" >&2
    exit 2
fi

if [ ! -d "${TARGET_DIR}" ]; then
    echo "ERROR: Target directory '${TARGET_DIR}' does not exist." >&2
    exit 3
fi

echo "Cleaning stale files in ${TARGET_DIR}..."
# Perform safe listing instead of aggressive deletion for demonstration
find "${TARGET_DIR}" -name "*.tmp" -type f -mtime +7 -exec echo "Would remove: {}" \;

echo "Operation completed successfully."
EOF

chmod 755 /tmp/bsd_cleaner.sh
```

#### Paso 2: Validar la sintaxis sin ejecutar el script
Ejecute `/bin/sh` con la flag `-n` (no-exec / comprobación de sintaxis) para verificar la validez de la sintaxis del script:

```bash
/bin/sh -n /tmp/bsd_cleaner.sh
echo "Syntax check return code: $?"
```

**Salida esperada:**
```text
Syntax check return code: 0
```

#### Paso 3: Probar la validación de parámetros y la redirección de error estándar
Ejecute el script sin parámetros y redirija stdout a `/dev/null` manteniendo visible stderr:

```bash
/tmp/bsd_cleaner.sh > /dev/null
echo "Exit status: $?"
```

**Salida esperada:**
```text
Usage: /tmp/bsd_cleaner.sh <target_directory>
[DEBUG] Running cleanup trap (Exit Code: 2)...
Exit status: 2
```

#### Paso 4: Ejecutar el rastreo paso a paso con `sh -x`
Ejecute el script contra un directorio de destino válido (`/tmp`) con el rastreo de ejecución habilitado (flag `-x`):

```bash
/bin/sh -x /tmp/bsd_cleaner.sh /tmp
```

**Salida esperada:**
```text
+ set -eu
+ LOCKFILE=/tmp/bsd_cleaner.lock
+ trap cleanup INT TERM EXIT
+ [ -e /tmp/bsd_cleaner.lock ]
+ touch /tmp/bsd_cleaner.lock
+ TARGET_DIR=/tmp
+ [ -z /tmp ]
+ [ ! -d /tmp ]
+ echo Cleaning stale files in /tmp...
Cleaning stale files in /tmp...
+ find /tmp -name *.tmp -type f -mtime +7 -exec echo Would remove: {} ;
+ echo Operation completed successfully.
Operation completed successfully.
+ cleanup
+ exit_code=0
+ echo [DEBUG] Running cleanup trap (Exit Code: 0)...
[DEBUG] Running cleanup trap (Exit Code: 0)...
+ rm -f /tmp/bsd_cleaner.lock
```

---

#### Preguntas de verificación (Bloque 3)

5. **En el Ejercicio 3, ¿por qué se usó `echo "Usage: ..." >&2` en lugar del `echo "Usage: ..."` estándar?**
   - A) `>&2` redirige stdout a stderr, lo que garantiza que los mensajes de diagnóstico y error se separen de los datos de salida estándar, permitiendo que los llamadores en pipeline procesen la salida válida sin corrupción de logs.
   - B) `>&2` fuerza a que el mensaje se escriba en la instalación de registro del sistema (`/var/log/messages`).
   - C) `>&2` escala los privilegios de ejecución del proceso a root.
   - D) `>&2` adjunta texto al descriptor 2 sin agregar un salto de línea al final.

6. **¿Cuál es el efecto de configurar `set -eu` al comienzo de un script `/bin/sh` de BSD?**
   - A) `-e` indica al shell que salga inmediatamente si cualquier comando devuelve un estado de salida no nulo; `-u` trata las variables no configuradas como un error y sale inmediatamente durante la expansión.
   - B) `-e` habilita el rastreo de ejecución; `-u` deshabilita los manejadores de señales de usuario.
   - C) `-e` ejecuta todos los comandos en subshells en segundo plano; `-u` eleva la prioridad de ejecución.
   - D) `-e` previene la sobreescritura de variables; `-u` fuerza el procesamiento de caracteres unicode.

---

## Soluciones y explicaciones de diagnóstico

<details>
<summary>Haga clic para ver las respuestas de comprensión y las explicaciones detalladas</summary>

### Pregunta 1
**Respuesta correcta:** **B**
* **Justificación técnica:** Cuando ejecuta `/bin/csh /tmp/sys_info.sh`, el sistema lanza el ejecutable `csh` directamente y pasa `/tmp/sys_info.sh` como argumento. La llamada al sistema `execve(2)` del kernel **no** es responsable de leer la línea shebang en este escenario porque el binario que se está ejecutando es `/bin/csh`. `csh` lee los comandos dentro de `/tmp/sys_info.sh` línea por línea. Debido a que `csh` utiliza una sintaxis inspirada en C (`set variable = value`) en lugar de la sintaxis Bourne POSIX (`VARIABLE=value`), las asignaciones de variables como `OS_NAME=$(uname -s)` dan como resultado errores de sintaxis (`Command not found`). La evaluación del shebang (`#!/bin/sh`) ocurre **únicamente** cuando el archivo se ejecuta directamente (por ejemplo, `./sys_info.sh`), activando el activador de imágenes `execve(2)` del kernel.

### Pregunta 2
**Respuesta correcta:** **B**
* **Justificación técnica:** La opción de montaje `noexec` impide que el kernel ejecute binarios o scripts directamente a través de `execve(2)`. La ejecución directa (`/tmp/sys_info.sh`) hace que `execve(2)` devuelva `EACCES` (`Permission denied`). Sin embargo, ejecutar `sh /tmp/sys_info.sh` ejecuta el binario de shell `/bin/sh` (que reside en `/bin`, un sistema de archivos ejecutable). `/bin/sh` abre `/tmp/sys_info.sh` mediante `open(2)` como un archivo de datos de texto plano, lee su contenido y evalúa los comandos.

### Pregunta 3
**Respuesta correcta:** **A**
* **Justificación técnica:** Bajo POSIX `/bin/sh`:
  - `"$@"` se expande a cadenas independientes entre comillas dobles: `"$1"` `"$2"` `"$3"` ... preservando los límites de los argumentos que contienen espacios.
  - `"$*"` se expande a una sola cadena entre comillas dobles: `"$1c$2c$3"` (donde `c` es el primer carácter de la variable `IFS`, cuyo valor predeterminado es el espacio).
  Si los parámetros son `"adm service"` y `"pkg-update"`, `"$@"` produce 2 argumentos (`"adm service"`, `"pkg-update"`), mientras que `"$*"` produce 1 argumento concatenado (`"adm service pkg-update"`).

### Pregunta 4
**Respuesta correcta:** **B**
* **Justificación técnica:** En los shells de Unix, `$?` almacena el estado de salida del comando ejecutado más recientemente en primer plano. Un estado de salida de `0` indica éxito, mientras que cualquier valor no nulo (`1-255`) denota un fallo o estado de error. Incluir `set -e` (o `set -o errexit`) garantiza que `/bin/sh` finalice inmediatamente si un comando simple falla, evitando estados de fallo en cascada en sistemas de producción.

### Pregunta 5
**Respuesta correcta:** **A**
* **Justificación técnica:** El descriptor de archivo `1` representa la salida estándar (`stdout`), y el descriptor de archivo `2` representa el error estándar (`stderr`). En entornos de producción, los scripts a menudo se conectan mediante tuberías a utilidades posteriores (por ejemplo, `script.sh | grep data`). Al redirigir los mensajes de error y uso a stderr a través de `>&2`, los mensajes de error permanecen visibles en la terminal/registros del usuario sin contaminar los flujos de datos de stdout.

### Pregunta 6
**Respuesta correcta:** **A**
* **Justificación técnica:** La combinación de `set -e` (`errexit`) y `set -u` (`nounset`) constituye la base de la programación defensiva de shell POSIX:
  - `-e`: Termina la ejecución del script inmediatamente si cualquier comando devuelve un estado de salida no nulo (a menos que forme parte de una prueba condicional como `if` o `||`).
  - `-u`: Activa un error y aborta la ejecución si se hace referencia a una variable no inicializada o no vinculada (lo que evita errores catastróficos como `rm -rf /${UNSET_VAR}`).

</details>

---

## Documentación de referencia oficial y especificaciones

1. **Linux Professional Institute BSD Specialist Certification Overview**
   - URL: https://www.lpi.org/our-certifications/bsd-specialist-overview/
2. **FreeBSD Manual Pages: `sh(1)` — Built-in Command and Script Interpreter**
   - URL: https://man.freebsd.org/cgi/man.cgi?query=sh&sektion=1
3. **OpenBSD Manual Pages: `csh(1)` — C Shell Interpreter**
   - URL: https://man.openbsd.org/csh.1
4. **IEEE Std 1003.1 POSIX Shell Specification (`Shell & Utilities`)**
   - URL: https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html