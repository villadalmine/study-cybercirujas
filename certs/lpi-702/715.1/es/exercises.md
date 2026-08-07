# LPI BSD Specialist (Examen 702-100) — Tema 715.1: Usar el Shell y Trabajar en la Línea de Comandos

**Versión del examen:** 1.0  
**Peso:** 3.33  
**Audiencia objetivo:** SREs, Arquitectos de Sistemas e Ingenieros de Plataforma que se preparan para la [Certificación LPI BSD Specialist](https://www.lpi.org/our-certifications/bsd-specialist-overview/).

---

## Análisis Técnico Profundo y Visión General de la Arquitectura

### 1. Arquitectura de Inicialización y Ciclo de Vida del Shell en BSD
En los sistemas operativos BSD (FreeBSD, OpenBSD, NetBSD), la interacción por línea de comandos se basa en dos familias principales de shells: shells compatibles con POSIX (como `/bin/sh`, derivado de Almquist Shell `ash`) y shells de estilo C (como `/bin/tcsh` o `/bin/csh`).

```
                    +----------------------------------+
                    |       User Authentication        |
                    |      (PAM / login / sshd)        |
                    +----------------------------------+
                                     |
                                     v
                    +----------------------------------+
                    |  Validate Shell in /etc/shells   |
                    |  Fetch Shell path from passwd    |
                    +----------------------------------+
                                     |
               +---------------------+---------------------+
               |                                           |
               v                                           v
    POSIX Shell (/bin/sh)                       C-Shell (/bin/tcsh)
  +-------------------------+                 +-------------------------+
  | 1. /etc/profile         |                 | 1. /etc/csh.cshrc       |
  | 2. ~/.profile           |                 | 2. /etc/csh.login       |
  | 3. ENV file (~/.shrc)   |                 | 3. ~/.tcshrc / ~/.cshrc |
  +-------------------------+                 | 4. ~/.login             |
                                              +-------------------------+
```

Cuando un usuario se autentica, el demonio de login (`login(1)`, `sshd(8)`) lee el login shell del usuario desde `/etc/passwd` (administrado de forma segura a través de `vipw(8)` o `chsh(1)`). El binario debe coincidir con una entrada dentro de `/etc/shells`.

#### Jerarquía de Inicio del Shell y Orden de Evaluación de Archivos:
- **POSIX Shell (`/bin/sh`)**:
  - **Login Shell**: Evalúa la configuración a nivel de sistema `/etc/profile`, luego `~/.profile` a nivel de usuario.
  - **Interactive Non-Login Shell**: Evalúa el archivo definido por la variable de entorno `$ENV` (típicamente `~/.shrc`).
- **C-Shell (`/bin/tcsh`)**:
  - **Login Shell**: Evalúa `/etc/csh.cshrc`, `/etc/csh.login`, `~/.tcshrc` (o `~/.cshrc`), y finalmente `~/.login`.
  - **Interactive Non-Login Shell**: Evalúa `/etc/csh.cshrc` y `~/.tcshrc` (omitiendo los archivos `.login`).

---

### 2. Mecánica de File Descriptors del Kernel y Redirección de Streams
En sistemas BSD, la I/O de los procesos está gobernada por la tabla de file descriptors (FD) del kernel. Cada proceso hereda descriptors estándar de su padre:
- `FD 0` (`stdin`) — Standard Input
- `FD 1` (`stdout`) — Standard Output
- `FD 2` (`stderr`) — Standard Error

La redirección altera estos punteros antes de la ejecución del proceso a través de las llamadas al sistema `dup2(2)` y `open(2)`.

```
       Process File Descriptor Table                Open File Table (Kernel)
      +------------------------------+             +-------------------------+
      | FD 0 (stdin)  -------------->|------------>| /dev/tty (Read)         |
      | FD 1 (stdout) -------------->|-----+       +-------------------------+
      | FD 2 (stderr) -------------->|---| |       | /tmp/app.log (Write)    |
      +------------------------------+   | +------>+-------------------------+
                                         +-------->| /tmp/err.log (Write)    |
                                                   +-------------------------+
```

#### Comparación de Sintaxis entre POSIX y C-Shell:

| Operación | POSIX `sh` / `bash` | `tcsh` / `csh` | Mecánica del Kernel |
| :--- | :--- | :--- | :--- |
| Redirigir `stdout` a un archivo | `cmd > file` | `cmd > file` | `open(file, O_WRONLY\|O_CREAT)` + `dup2(fd, 1)` |
| Añadir `stdout` a un archivo | `cmd >> file` | `cmd >> file` | `open(file, O_APPEND)` + `dup2(fd, 1)` |
| Redirigir `stderr` a un archivo | `cmd 2> file` | `(cmd > file) >& errfile` | `open(errfile)` + `dup2(fd, 2)` |
| Fusionar `stderr` en `stdout` | `cmd > file 2>&1` | `cmd >& file` | `dup2(1, 2)` apunta `stderr` al vnode de `stdout` |
| Pipe de `stdout` y `stderr` | `cmd 2>&1 \| tee log` | `cmd \|& tee log` | La llamada al sistema `pipe(2)` crea un vnode de pipe anónimo |

---

### 3. Job Control, Sesiones de Procesos y Manejo de Señales
El job control en BSD asocia las tareas en ejecución con una terminal de control (`tty`). El agrupamiento de procesos dicta la entrega de señales a través de los árboles de procesos.

- **Session Leader (SID)**: Creado al iniciar sesión. Gestiona los grupos de procesos en foreground/background.
- **Process Group ID (PGID)**: Agrupa procesos que se originan a partir de una sola tubería o comando.
- **Terminal Foreground Process Group (`tpgid`)**: Solo el grupo de procesos que coincide con `tpgid` recibe la entrada directa y las señales de la terminal (`SIGINT` `Ctrl+C`, `SIGTSTP` `Ctrl+Z`).

#### Señales Principales y Acciones del Sistema Operativo:
- `SIGHUP` (1): Cierre de terminal / Terminación de sesión. Se envía a los procesos en background cuando la terminal de control finaliza, a menos que sea capturada u omitida (`nohup`).
- `SIGINT` (2): Señal de interrupción enviada por el teclado `Ctrl+C`.
- `SIGKILL` (9): Terminación de proceso por el kernel, incapturable y no ignorable.
- `SIGTERM` (15): Solicitud de terminación estándar de software que permite una limpieza limpia (graceful).
- `SIGTSTP` (18/20): Señal de detención de terminal enviada por `Ctrl+Z`. Pausa la ejecución y mueve el proceso al estado background (`STOPPED`).

---

## Ejercicios Prácticos Guiados

### Bloque de Ejercicios 1: Inicialización del Shell, Alcance de Perfiles de Usuario y Cambio de Shell

#### Objetivo:
Analizar el registro del shell, cambiar de forma segura el shell de un usuario utilizando herramientas de BSD y configurar scripts de inicio distintos tanto para `/bin/sh` como para `/bin/tcsh`.

#### Pasos de Ejecución:

1. Inspeccionar los shells permitidos activos en el host BSD y verificar los detalles del shell del usuario actual:
```syslog
$ cat /etc/shells
/bin/sh
/bin/csh
/bin/tcsh
/usr/local/bin/bash

$ finger $USER
Login: sreadmin                         Name: SRE Admin
Directory: /home/sreadmin               Shell: /bin/sh
```

2. Probar el cambio de su login shell a `/bin/tcsh` utilizando `chsh`:
```syslog
$ chsh -s /bin/tcsh
chsh: user information updated
```

3. Crear definiciones de variables de entorno en las configuraciones de POSIX shell (`~/.profile` y `~/.shrc`) y C-shell (`~/.cshrc`):
```syslog
$ cat << 'EOF' >> ~/.profile
export CLUSTER_ENV="production-us-east"
export ENV="$HOME/.shrc"
EOF

$ cat << 'EOF' >> ~/.shrc
alias ll="ls -laF"
EOF

$ cat << 'EOF' >> ~/.cshrc
setenv CLUSTER_ENV "production-us-east"
alias ll "ls -laF"
EOF
```

4. Verificar la herencia del entorno del shell utilizando la herramienta de diagnóstico de procesos de FreeBSD `procstat`:
```syslog
$ sh -c 'echo $CLUSTER_ENV'
production-us-east

$ procstat -e $$ | grep CLUSTER_ENV
 1482 sh               CLUSTER_ENV      production-us-east
```

---

#### Preguntas de Verificación (Bloque 1)

1.1. ¿Por qué una ejecución interactiva no-login de `/bin/sh` no logra cargar las variables de entorno declaradas en `~/.profile`, y qué mecanismo de configuración exacto resuelve este comportamiento?

1.2. Si un usuario establece su shell a `/usr/local/bin/zsh` mediante `chsh`, pero `/usr/local/bin/zsh` se omite de `/etc/shells`, ¿qué mecanismo de seguridad se activa durante la autenticación de `sshd(8)` o `su(1)`, y cuál es el resultado?

1.3. Compare la sintaxis y la mecánica de ejecución al definir una variable de entorno y un alias entre `/bin/sh` y `/bin/tcsh`.

---

### Bloque de Ejercicios 2: Fontanería de File Descriptors, División de Streams e Inspección de Pipes

#### Objetivo:
Dominar la redirección de streams estándar, separar `stdout` de `stderr` e inspeccionar descriptors de procesos abiertos utilizando utilidades de BSD (`fstat` / `procstat`).

#### Pasos de Ejecución:

1. Crear un script `stream_app.sh` que escriba tanto a `stdout` como a `stderr`:
```syslog
$ cat << 'EOF' > stream_app.sh
#!/bin/sh
echo "[INFO] Processing payload chunk 1" >&1
echo "[ERROR] Failed to resolve DB host" >&2
echo "[INFO] Processing payload chunk 2" >&1
EOF
$ chmod +x stream_app.sh
```

2. Ejecutar el script en POSIX `sh`, enrutando `stdout` a un archivo mientras se mantiene `stderr` visible en la terminal:
```syslog
$ ./stream_app.sh > app_info.log
[ERROR] Failed to resolve DB host

$ cat app_info.log
[INFO] Processing payload chunk 1
[INFO] Processing payload chunk 2
```

3. Usar file descriptors personalizados (`exec 3>&1`) para enviar `stdout` a `app.log` mientras se redirige `stderr` a través de `tee` tanto a la terminal como a `error.log`:
```syslog
$ ( ./stream_app.sh 2>&1 1>&3 | tee error.log ) 3> app.log
[ERROR] Failed to resolve DB host

$ cat error.log
[ERROR] Failed to resolve DB host

$ cat app.log
[INFO] Processing payload chunk 1
[INFO] Processing payload chunk 2
```

4. Ejecutar una tubería de larga duración en background e inspeccionar sus file descriptors utilizando `fstat`:
```syslog
$ sleep 300 | tail -f /dev/null &
[1] 49122

$ fstat -p 49122
USER     CMD          PID   FD MOUNT      INUM MODE         SZ|DV R/W
sreadmin tail       49122 text /         31204 -rwxr-xr-x  28416  r
sreadmin tail       49122    0 pipe 0xfffffe004a11b220       0  r
sreadmin tail       49122    1 /usr      12045 -rw-r--r--       0  w
sreadmin tail       49122    2 /dev       1102 crw-rw-rw-    null rw
```

---

#### Preguntas de Verificación (Bloque 2)

2.1. En POSIX shell, explique por qué `cmd > logfile 2>&1` se comporta de manera diferente a `cmd 2>&1 > logfile`. Describa la secuencia de llamadas internas a `dup2(2)` para ambos casos.

2.2. ¿Cómo logra `tcsh` fusionar `stderr` en un pipe (`|&`), y cómo duplicaría `(cmd 2>&1 1>&3 | tee err.log) 3> out.log` dentro de `/bin/tcsh`?

2.3. Analice la salida de `fstat` del Paso 4. ¿Qué significa `FD 0 pipe 0xfffffe...` en la capa del subsistema del kernel de FreeBSD?

---

### Bloque de Ejercicios 3: Job Control, Envío de Señales, Traps y Desacoplamiento de Sesiones

#### Objetivo:
Manipular estados de job control (`CTRL+Z`, `bg`, `fg`), configurar el manejo de señales con `trap` en POSIX `sh` y gestionar la persistencia de procesos asincrónicos ante el cierre de sesión (`SIGHUP`).

#### Pasos de Ejecución:

1. Iniciar un proceso, suspenderlo, convertirlo en un trabajo en background y verificar los flags del proceso utilizando `ps`:
```syslog
$ ping -i 2 127.0.0.1
^Z
[1]+  Stopped                 ping -i 2 127.0.0.1

$ bg %1
[1]+ ping -i 2 127.0.0.1 &

$ ps -o pid,pgid,sid,tpgid,stat,command -p $(pgrep ping)
  PID  PGID   SID TPGID STAT COMMAND
50122 50122 49001 49001 S    ping -i 2 127.0.0.1
```

2. Construir una simulación de demonio SRE `worker.sh` que atrape señales para un apagado ordenado (graceful shutdown):
```syslog
$ cat << 'EOF' > worker.sh
#!/bin/sh
trap 'echo "Caught SIGHUP - reloading config..."; reload_config' 1
trap 'echo "Caught SIGTERM - shutting down gracefully"; exit 0' 15

reload_config() {
  echo "[CONFIG] Reloaded at $(date)" >> worker.log
}

echo "[INIT] Worker started with PID $$" >> worker.log
while true; do
  sleep 2
done
EOF
$ chmod +x worker.sh
$ ./worker.sh &
[1] 51204
```

3. Enviar señales utilizando `kill` y `pkill`, luego verificar el log de salida:
```syslog
$ kill -1 51204
$ kill -15 51204
[1]+  Done                    ./worker.sh

$ cat worker.log
[INIT] Worker started with PID 51204
Caught SIGHUP - reloading config...
[CONFIG] Reloaded at Thu Aug  6 21:00:10 UTC 2026
Caught SIGTERM - shutting down gracefully
```

4. Demostrar inmunidad de sesión utilizando `nohup` versus desacoplamiento de procesos:
```syslog
$ nohup sleep 600 > sleep.log 2>&1 &
[1] 52001
$ ps -o pid,ppid,pgid,sid,stat,command -p 52001
  PID  PPID  PGID   SID STAT COMMAND
52001 49001 52001 49001 I    sleep 600
```

---

#### Preguntas de Verificación (Bloque 3)

3.1. En la salida de `ps -o pid,pgid,sid,tpgid,stat,command`, ¿cuál es la relación entre `PGID` y `TPGID` para un proceso en foreground versus un proceso en background?

3.2. ¿Qué le sucede a un proceso hijo que se ejecuta dentro de `/bin/sh` cuando el shell padre recibe una señal `SIGHUP` si **no** se utilizó `nohup`? ¿Cómo altera `disown` (o el builtin `nohup` de `csh`) este comportamiento?

3.3. ¿Por qué es imposible manejar `SIGKILL` (señal 9) con el builtin `trap` del shell y qué riesgo operativo de SRE surge al usar `kill -9` de forma prematura en bases de datos o demonios con estado (stateful)?

---

### Bloque de Ejercicios 4: Orden de Resolución de Rutas de Comandos, Mecanismos de Historial y Manipulación del Entorno

#### Objetivo:
Dominar la jerarquía de resolución de entidades ejecutables en shells de BSD (`alias`, `builtin`, `function`, `$PATH`), configurar mecanismos de historial de comandos e inspeccionar builtins de manipulación del entorno.

#### Pasos de Ejecución:

1. Investigar la precedencia del tipo de comando utilizando `type`, `which` y `whereis`:
```syslog
$ alias ls="ls -G"
$ type ls
ls is an alias for ls -G

$ which ls
/bin/ls

$ whereis ls
ls: /bin/ls /usr/share/man/man1/ls.1.gz
```

2. Probar la prioridad de sobreescritura creando una función de shell y un alias con nombres idénticos:
```syslog
$ test_func() { echo "Function executed"; }
$ alias test_func="echo Alias executed"

$ test_func
Alias executed

$ \test_func
Function executed
```

3. Configurar variables de historial y probar los operadores de expansión:
```syslog
# POSIX / Bash environment settings
$ HISTSIZE=5000
$ HISTFILE="$HOME/.sh_history"

# Execute commands and utilize expansion
$ tail -n 20 /var/log/messages
$ !tail
tail -n 20 /var/log/messages
```

4. Comparar la configuración y eliminación de variables de entorno entre `sh` y `tcsh`:
```syslog
# POSIX sh
$ WORKER_NODES="node1 node2"
$ export WORKER_NODES
$ unset WORKER_NODES

# C-shell (tcsh)
> setenv WORKER_NODES "node1 node2"
> unsetenv WORKER_NODES
```

---

#### Preguntas de Verificación (Bloque 4)

4.1. Ordene las siguientes entidades de ejecución de **mayor prioridad a menor prioridad** durante la búsqueda de comandos en un POSIX shell: `Builtin`, `Executable Binary in $PATH`, `Alias`, `Function`.

4.2. ¿Cómo altera la mecánica de búsqueda de ejecución del shell anteponer una barra invertida (`\command`) o utilizar el builtin `command`?

4.3. En `tcsh`, ¿cuál es la diferencia funcional clave entre `set var = "value"` y `setenv VAR "value"` respecto a la herencia en subshells?

---

<details>
<summary><b>Respuestas y Explicaciones Detalladas</b></summary>

### Respuestas del Bloque de Ejercicios 1

**Respuesta 1.1:**  
En POSIX `/bin/sh`, `~/.profile` es analizado exclusivamente por **login shells** (iniciados con un guión inicial `-sh` o mediante `--login`). Los subshells interactivos no-login (tales como multiplexores de terminal o ejecuciones de scripts hijos) omiten `~/.profile`. Para poner a disposición alias y funciones en shells interactivos no-login, POSIX `sh` evalúa la ruta de archivo referenciada por la variable `$ENV`. Por lo tanto, exportar `export ENV="$HOME/.shrc"` dentro de `~/.profile` garantiza que los shells interactivos no-login subsiguientes ejecuten `~/.shrc`.

**Respuesta 1.2:**  
Durante la autenticación (`sshd`, `su`, `login`), las utilidades del sistema validan el shell asignado al usuario contra `/etc/shells` a través de la API `getusershell(3)`. Si `/usr/local/bin/zsh` falta en `/etc/shells`, las políticas de seguridad de autenticación rechazan la sesión o recurren a un shell restringido por defecto (`/bin/sh` o deniegan el acceso por completo). Esta salvaguarda evita la ejecución de binarios arbitrarios o shells personalizados no aprobados.

**Respuesta 1.3:**  
- **Variables de Entorno**:
  - `sh`: `export VAR="value"` o `VAR="value"; export VAR`. Escribe directamente en el arreglo de punteros `environ` heredado por los procesos hijos.
  - `tcsh`: `setenv VAR "value"`. Utiliza una sintaxis de comando builtin distinta sin el signo igual (`=`).
- **Aliases**:
  - `sh`: `alias key="command --flag"`. Utiliza la sintaxis `=`.
  - `tcsh`: `alias key "command --flag"`. Utiliza separación por espacios en blanco en lugar de `=`.

---

### Respuestas del Bloque de Ejercicios 2

**Respuesta 2.1:**  
Las redirecciones de shell se evalúan **de izquierda a derecha**:
- `cmd > logfile 2>&1`:
  1. `> logfile`: Abre `logfile` y usa `dup2(fd, 1)` para que `stdout` apunte a `logfile`.
  2. `2>&1`: Llama a `dup2(1, 2)`, duplicando el descriptor 1 (`logfile`) sobre el descriptor 2 (`stderr`). Tanto `stdout` como `stderr` fluyen hacia `logfile`.
- `cmd 2>&1 > logfile`:
  1. `2>&1`: Llama a `dup2(1, 2)`, duplicando el descriptor 1 (actualmente la terminal `/dev/tty`) sobre el descriptor 2. `stderr` ahora apunta a la salida de la terminal.
  2. `> logfile`: Llama a `dup2(fd, 1)`, moviendo `stdout` a `logfile`.
  - **Resultado**: `stdout` va a `logfile`, pero `stderr` continúa saliendo por la terminal.

**Respuesta 2.2:**  
En `/bin/tcsh`, la fusión del stream 2 en el stream 1 para el uso de pipes utiliza el operador `|&` (`cmd |& tee logfile`). Para redirigir `stdout` a `out.log` mientras se captura `stderr` por separado en `err.log` sin la manipulación de descriptores de POSIX, `tcsh` requiere aislamiento por subshell:
```tcsh
(cmd > out.log) >& err.log
```

**Respuesta 2.3:**  
La línea `FD 0 pipe 0xfffffe004a11b220` indica que el File Descriptor 0 (`stdin`) de `tail` ha sido convertido de un dispositivo de caracteres (`/dev/tty`) a un **BSD Kernel Pipe Vnode** a través de la llamada al sistema `pipe(2)`. La dirección hexadecimal `0xfffffe...` apunta al búfer de memoria del kernel asignado para la comunicación entre procesos entre `sleep` (`stdout`) y `tail` (`stdin`).

---

### Respuestas del Bloque de Ejercicios 3

**Respuesta 3.1:**  
- Para un **foreground process group**, el Process Group ID (`PGID`) coincide con el Foreground Process Group ID de la terminal de control (`TPGID`). Esto le otorga al grupo de procesos acceso de lectura exclusivo a `stdin` y le enruta directamente las señales de la terminal (`SIGINT`/`SIGTSTP`).
- Para un **background process group**, `PGID` **no** coincide con `TPGID` (`PGID != TPGID`). Si un proceso en background intenta leer de `stdin`, el kernel de BSD envía una señal `SIGTTIN`, suspendiendo el proceso hasta que sea llevado al foreground mediante `fg`.

**Respuesta 3.2:**  
Cuando un shell POSIX interactivo finaliza, el kernel envía un `SIGHUP` (Señal 1) a todos los trabajos en su grupo de procesos activo. Sin `nohup`, los procesos hijos finalizan al recibir `SIGHUP`. El wrapper `nohup` establece el manejador de `SIGHUP` a `SIG_IGN` (Ignore). El builtin `disown` elimina el trabajo objetivo de la tabla de trabajos del shell, evitando que el shell envíe `SIGHUP` a ese grupo de procesos al salir.

**Respuesta 3.3:**  
`SIGKILL` (señal 9) omite por completo las tablas de vectores de señales en el espacio de usuario; es procesado directamente por el planificador de procesos del kernel para revocar de forma inmutable los contextos de asignación y terminar la estructura del proceso. Como el proceso nunca ejecuta código en espacio de usuario al recibir `SIGKILL`, no puede capturar la señal ni realizar rutinas de limpieza (tales como vaciar búferes de I/O, eliminar archivos de bloqueo o cerrar sockets IPC activos), lo que lleva a la corrupción de datos en motores de bases de datos o estados de bloqueo inconsistentes.

---

### Respuestas del Bloque de Ejercicios 4

**Respuesta 4.1:**  
El orden de resolución en shells POSIX es:
1. **Alias**
2. **Keyword** (p. ej., `if`, `while`)
3. **Function**
4. **Builtin** (p. ej., `cd`, `echo`, `exec`)
5. **Executable Binary in `$PATH`** (p. ej., `/bin/ls`, `/usr/bin/grep`)

**Respuesta 4.2:**  
Anteponer una barra invertida (`\command`) o invocar `command nombre`:
- **Desactiva la expansión de alias**: Suprime por completo la búsqueda de alias, forzando al shell a buscar funciones, builtins o ejecutables en `$PATH`.
- **Builtin `command`**: Suprime tanto los **Aliases** como las **Shell Functions**, forzando que la búsqueda se resuelva estrictamente a builtins o binarios externos ubicados en `$PATH`. Esto evita bucles infinitos dentro de funciones wrapper personalizadas.

**Respuesta 4.3:**  
- `set var = "value"`: Instancia una **variable local de shell** dentro de `tcsh`. Reside estrictamente dentro de la tabla hash interna del shell y **no** se exporta a procesos hijos o subshells.
- `setenv VAR "value"`: Modifica el **arreglo de variables de entorno** (`environ`) de C-shell, asegurando que todos los procesos hijos, scripts y subshells creados a partir de esta sesión hereden `VAR`.

</details>