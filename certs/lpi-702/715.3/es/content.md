# Guía de estudio de LPI BSD Specialist (Examen 702-100)
## Tema 715.3: Crear, monitorear y finalizar procesos

---

### 1. Motivación en producción y problema arquitectónico

En entornos POSIX empresariales—específicamente FreeBSD, OpenBSD y NetBSD—la gestión de procesos constituye el núcleo de la ingeniería de confiabilidad de plataformas (Platform Reliability Engineering). Al operar servicios de red de alto rendimiento, bases de datos o microservicios, un SRE o Platform Architect debe comprender los subsistemas de gestión de procesos del kernel BSD. El no monitorear y controlar los estados de los procesos, la asignación de memoria, las prioridades de ejecución y los mecanismos de finalización conduce a la degradación del sistema, fallas en cascada y la falta total de respuesta del nodo.

```
                  +-----------------------------------+
                  |             fork()                |
                  +-----------------------------------+
                                    |
                                    v
+------------------+      +-------------------+      +-------------------+
|   Zombie (Z)     |      |    Runnable (R)   | <--> |   Sleeping (S/I)  |
| (Awaiting wait() |      | (On CPU Run Queue)|      | (Interruptible)   |
+------------------+      +-------------------+      +-------------------+
          ^                         |                          |
          | exit()                  v                          v
          +-----------------+-----------------+      +-------------------+
                            |  Stopped (T)    |      | Uninterruptible   |
                            | (SIGSTOP/SIGTSTP|      |    Sleep (D)      |
                            +-----------------+      | (Disk/IO Wait)    |
                                                     +-------------------+
```

#### Desafíos arquitectónicos clave en infraestructura BSD en producción

1. **Uninterruptible Disk I/O Sleep (Estado `D`) e inflación del Load Average**:
   El load average del proceso en monitores de sistemas BSD mide el número promedio de procesos en la run queue (`R`) más los procesos esperando en uninterruptible disk/network I/O sleep (`D`). Una aplicación bloqueada en recursos NFS bloqueados, hardware de almacenamiento que no responde o bloqueos de vdev en ZFS entra en estado `D`. Debido a que la ejecución de procesos en estado `D` no puede manejar señales del kernel (incluyendo `SIGKILL` / `kill -9`), las estrategias tradicionales de finalización de procesos fallan. Esto resulta en el acaparamiento de procesos y el eventual agotamiento del pool de hilos del SO.

2. **Acumulación de procesos Zombie y recolección (reaping) de procesos huérfanos**:
   Cuando un proceso hijo finaliza su ejecución a través de `exit()`, pasa al estado `Z` (Zombie). Su bloque de control de proceso (PCB) y la entrada en la tabla de procesos permanecen asignados hasta que el proceso padre consume su estado de finalización a través de `wait()` o `waitpid()`. Si un proceso padre sufre un deadlock o ignora los manejadores de señales del hijo (`SIGCHLD`), los zombies se acumulan. Si el padre muere, el proceso PID 1 (`init` o lanzador de servicios del sistema) hereda al hijo huérfano y lo recolecta (reaps). Los zombies no recolectados consumen slots de procesos en la tabla de procesos del kernel (`kern.maxproc`).

3. **Agotamiento del límite de la tabla de procesos del kernel y PID**:
   El kernel BSD mantiene una tabla de procesos interna limitada por el nodo sysctl `kern.maxproc` (y el límite por usuario `kern.maxprocperuid`). Si una aplicación sin restricciones crea hilos o subprocesos sin límites, agota la tabla de procesos del kernel. Una vez alcanzado, las llamadas a utilidades del sistema como `fork()` fallan globalmente con `EAGAIN` ("Resource temporarily unavailable"), lo que impide que los ingenieros establezcan sesiones SSH para diagnosticar el host.

4. **Contención de recursos e inanición (starvation) de CPU**:
   Los procesos en segundo plano no gestionados que se ejecutan con la prioridad de planificación predeterminada (valor nice `0`) pueden privar de recursos a daemons críticos del sistema (`sshd`, `ntpd`, `syslogd`). Los planificadores BSD (SCHED_ULE en FreeBSD, SCHED_4BSD) requieren ajuste mediante prioridades POSIX (`nice`/`renice`) y prioridades en tiempo real específicas de BSD (`rtprio`/`idprio`) o límites de recursos (`rctl`/`login.conf`) para garantizar los SLI de latencia en cargas de trabajo críticas.

---

### 2. Comparativas técnicas y tablas de balance (Trade-offs)

#### Tabla 2.1: Herramientas de inspección y monitoreo de procesos

| Herramienta | Alcance y motor de acceso | Sobrecarga del sistema | Caso de uso principal en producción | Balance y limitaciones |
| :--- | :--- | :--- | :--- | :--- |
| **`ps`** | Captura instantánea (snapshot) de la tabla de procesos vía kernel `kvm` / `sysctl` | Baja (Ejecución única) | Auditoría en scripts, pipelines CI/CD, inspección del árbol de procesos (`ps -axjf`). | Captura estática; sin seguimiento de métricas en tiempo real; las opciones de formato varían entre FreeBSD/OpenBSD/NetBSD. |
| **`top`** | Visualización interactiva en terminal vía `sysctl` / `kvm` en userland | Moderada (Sondeo periódico del kernel) | Depuración interactiva de picos de CPU/memoria y clasificación de procesos. | Consume TTY de terminal; sobrecarga continua cuando se ejecuta en intervalos de actualización altos (<1s). |
| **`systat`** | Visualizador de subsistemas del kernel BSD (interfaz `sysctl`) | Moderada | Rendimiento integral del sistema (swap, netstat, vmstat, iostat). | Nativo de BSD (difiere de Linux); curva de aprendizaje empinada para atajos de teclado. |
| **`procstat`** | Inspector profundo de la estructura de procesos del kernel BSD | Baja | Rastreo de descriptores de archivo abiertos, máscaras de señales, mapas VM y estado de hilos del kernel. | Específico de FreeBSD; parsing de salida complejo; requiere privilegios elevados de root. |
| **`fstat` / `sockstat`** | Mapeador de sockets de red y descriptores de archivo abiertos | Baja a Moderada | Identificación de procesos vinculados a puertos específicos (`sockstat`) o archivos abiertos (`fstat`). | Salida grande en sistemas con más de 100k sockets abiertos; requiere filtrado. |

---

#### Tabla 2.2: Mecanismos de entrega de señales

| Herramienta / Comando | Criterios de coincidencia objetivo | Nivel de seguridad | Escenario objetivo | Riesgo arquitectónico |
| :--- | :--- | :--- | :--- | :--- |
| **`kill`** | ID de proceso exacto (PID) o ID de grupo de procesos (PGID) | **Alto** | Cierre dirigido de procesos (`kill -15 PID`). | Un error humano al escribir los PIDs puede finalizar daemons críticos del sistema no deseados. |
| **`pkill`** | Coincidencia de Regex en el nombre del comando, UID, GID, TTY o jail | **Medio** | Finalización masiva de procesos que coinciden con nombres de procesos o contextos de usuario específicos. | Las coincidencias de regex demasiado permisivas pueden finalizar accidentalmente procesos no deseados. |
| **`killall`** | Coincidencia exacta con el nombre del proceso | **Bajo a Medio** | Finalización de todas las instancias de un daemon (ej. `killall nginx`). | **Advertencia de sintaxis**: En Solaris/SysV `killall` mata *todos* los procesos. En BSD/Linux mata por nombre. |
| **`procstat -k`** | Inspección directa de la pila/señal del kernel y señalización | **Alto** | Diagnósticos avanzados del estado de procesos a nivel de kernel y verificación de señales. | Específico de FreeBSD; requiere conocimiento exhaustivo de las señales del kernel. |

---

#### Tabla 2.3: Prioridades de planificación y motores de control de ejecución

| Nivel de ejecución | Utilidad / Interfaz | Rango de prioridad | Carga de trabajo objetivo | Propiedades de comportamiento |
| :--- | :--- | :--- | :--- | :--- |
| **Normal / Dinámico** | `nice` / `renice` | `-20` (Más alta) a `20` (Más baja) | Trabajos en segundo plano estándar, procesamiento por lotes, tareas de compilación. | Sujeto al decaimiento del planificador del kernel; los usuarios no root solo pueden bajar la prioridad (incrementar nice). |
| **Tiempo real (RTPRIO)** | `rtprio` (FreeBSD) | `0` (Más alta) a `31` (Más baja) | Audio de latencia fija, hardware de control, coincidencia de operaciones bursátiles de alta frecuencia. | Se antepone (preempts) a todos los procesos de tiempo compartido estándar; su abuso bloqueará las run queues del kernel. |
| **Inactivo (IDPRIO)** | `idprio` (FreeBSD) | `0` (Más alta) a `31` (Más baja) | Trabajos de depuración (scrubbing), compresores de logs, indexadores de disco. | El proceso se ejecuta *únicamente* cuando las run queues de la CPU del sistema están completamente vacías. |
| **Reglas de recursos (RCTL)** | `rctl` (FreeBSD) | Límites de métricas declarativos (`maxproc`, `pctcpu`, `vmemoryuse`) | Jails multi-tenant, servicios en contenedores, límites de usuario. | Aplica limitación estricta dinámica (throttling) o emisión automática de señales al violar el umbral. |

---

### 3. Manifiestos completos y configuraciones de infraestructura

#### Manifiesto 3.1: `/etc/login.conf` — Manifiesto de control de recursos y límites empresariales

Este archivo define los límites de recursos para los entornos de ejecución de procesos por clase de inicio de sesión en sistemas BSD. Compile los cambios utilizando `cap_mkdb /etc/login.conf`.

```ini
# /etc/login.conf - Production Server Capability Database
# Syntactically valid configuration for FreeBSD/OpenBSD process limit management

default:\
	:passwd_format=sha512:\
	:copyright=/etc/COPYRIGHT:\
	:welcome=/etc/motd:\
	:setenv=MAIL=/var/mail/$USER,PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin:\
	:path=/sbin /bin /usr/sbin /usr/bin /usr/local/sbin /usr/local/bin:\
	:nologin=/usr/sbin/nologin:\
	:cputime=unlimited:\
	:datasize=unlimited:\
	:stacksize=64M:\
	:memorylocked=64M:\
	:memoryuse=unlimited:\
	:filesize=unlimited:\
	:coredumpsize=0:\
	:openfiles=10240:\
	:maxproc=512:\
	:sbsize=unlimited:\
	:vmemoryuse=unlimited:\
	:swapuse=unlimited:\
	:pseudoterminals=unlimited:\
	:priority=0:\
	:umask=022:

# Restricted Class for Production Web Services (e.g. www / nginx / application execution context)
www_daemon:\
	:ignorenologin:\
	:datasize-cur=4G:\
	:datasize-max=8G:\
	:openfiles-cur=65536:\
	:openfiles-max=131072:\
	:maxproc-cur=2048:\
	:maxproc-max=4096:\
	:memoryuse-cur=8G:\
	:memoryuse-max=16G:\
	:coredumpsize=0:\
	:priority=2:\
	:tc=default:

# Production Database Class (High I/O, High Open Files, Real-time execution priority)
database_daemon:\
	:ignorenologin:\
	:openfiles-cur=262144:\
	:openfiles-max=524288:\
	:maxproc-cur=8192:\
	:maxproc-max=16384:\
	:memorylocked=unlimited:\
	:coredumpsize=unlimited:\
	:priority=-2:\
	:tc=default:
```

---

#### Manifiesto 3.2: `/etc/sysctl.conf` — Ajuste del subsistema de procesos del kernel

Archivo de ajuste sysctl de producción para evitar la inanición de la tabla de procesos del kernel, el agotamiento de PID y ajustar los parámetros de planificación.

```ini
# /etc/sysctl.conf - FreeBSD/BSD Kernel Process Subsystem Production Tuning

# Increase maximum total process limit across the entire system
kern.maxproc=32768

# Increase maximum process limit allowed per user ID (prevents PID exhaustion DOS)
kern.maxprocperuid=16384

# Maximum open file descriptors system-wide
kern.maxfiles=204800

# Maximum open files per process ID
kern.maxfilesperproc=102400

# Disable core dumps for setuid processes (Security hardening)
kern.sugid_coredump=0

# FreeBSD SCHED_ULE Quantum tuning (Microseconds allocated to running thread before preempting)
# Tuning quantum length for low-latency network applications (Default: 100000)
kern.sched.quantum=50000

# Enable BSD Resource Limits engine (RCTL)
kern.racct.enable=1

# Virtual Memory Swap and Paging threshold controls
vm.swap_enabled=1
```

---

#### Manifiesto 3.3: `/etc/rc.d/sre_app` — Script completo de servicio BSD para producción

Un script de supervisión de procesos y creación de daemons para FreeBSD totalmente compatible con `rc.subr(8)`, que demuestra el uso adecuado de `daemon(8)`, seguimiento de archivos PID, manejo de señales y especificación del contexto de ejecución.

```sh
#!/bin/sh
#
# PROVIDE: sre_app
# REQUIRE: LOGIN DAEMON NETWORKING
# KEYWORD: shutdown
#
# Add the following lines to /etc/rc.conf to enable sre_app:
# sre_app_enable="YES"
# sre_app_flags="--config=/etc/sre_app.conf"
#

. /etc/rc.subr

name="sre_app"
rcvar="sre_app_enable"

load_rc_config ${name}

: ${sre_app_enable:="NO"}
: ${sre_app_user:="www"}
: ${sre_app_group:="www"}
: ${sre_app_login_class:="www_daemon"}
: ${sre_app_pidfile:="/var/run/${name}.pid"}
: ${sre_app_binary:="/usr/local/bin/sre_app_bin"}

pidfile="${sre_app_pidfile}"
command="/usr/sbin/daemon"
command_args="-f -p ${pidfile} -t ${name} -u ${sre_app_user} ${sre_app_binary} ${sre_app_flags}"

stop_cmd="sre_app_stop"
status_cmd="sre_app_status"
reload_cmd="sre_app_reload"

extra_commands="reload"

sre_app_stop()
{
    if [ -f "${pidfile}" ]; then
        local _pid
        _pid=$(cat "${pidfile}")
        echo "Stopping ${name} (PID: ${_pid})..."
        kill -SIGTERM "${_pid}"
        
        # Wait up to 10 seconds for graceful termination
        local _i=0
        while [ ${_i} -lt 10 ]; do
            if ! kill -0 "${_pid}" 2>/dev/null; then
                echo "${name} stopped successfully."
                rm -f "${pidfile}"
                return 0
            fi
            sleep 1
            _i=$(( _i + 1 ))
        done
        
        echo "Graceful shutdown failed. Sending SIGKILL to PID ${_pid}..."
        kill -SIGKILL "${_pid}" 2>/dev/null
        rm -f "${pidfile}"
    else
        echo "${name} is not running (PID file missing)."
    fi
}

sre_app_status()
{
    if [ -f "${pidfile}" ]; then
        local _pid
        _pid=$(cat "${pidfile}")
        if kill -0 "${_pid}" 2>/dev/null; then
            echo "${name} is running as PID ${_pid}."
            /usr/bin/procstat -c "${_pid}"
        else
            echo "${name} is dead but PID file exists."
            return 1
        fi
    else
        echo "${name} is not running."
        return 3
    fi
}

sre_app_reload()
{
    if [ -f "${pidfile}" ]; then
        local _pid
        _pid=$(cat "${pidfile}")
        echo "Reloading ${name} configuration (SIGHUP to PID ${_pid})..."
        kill -SIGHUP "${_pid}"
    else
        echo "${name} is not running."
        return 1
    fi
}

run_rc_command "$1"
```

---

### 4. Comandos CLI reales y salidas de terminal

#### Comando 4.1: Inspección de carga del sistema y carga de trabajo (`uptime`, `w`)

Inspecciona el tiempo de actividad del sistema (uptime), las sesiones activas y los promedios de carga (load average) del sistema a 1, 5 y 15 minutos.

```syslog
$ uptime
 9:15PM  up 42 days, 11:04,  3 users,  load averages: 1.45, 0.98, 0.72

$ w
 9:15PM  up 42 days, 11:04,  3 users,  load averages: 1.45, 0.98, 0.72
USER       TTY      FROM                      LOGIN@  IDLE WHAT
root       pts/0    192.168.1.50             8:45PM     0 w
opsadmin   pts/1    192.168.1.51             9:00PM    12 top -u -s 2
deploy     pts/2    192.168.1.60             9:10PM     - python3 batch_processor.py
```

*Análisis arquitectónico*: El load average representa el número promedio de hilos en la run queue (`R`) más los hilos en espera ininterrumpida de disco (`D`). Un load average de 1.45 en un host mononúcleo implica un retraso (backlog) del 45% en la espera de CPU/IO.

---

#### Comando 4.2: Memoria virtual y actividad de paginación (`vmstat`)

Monitorea las estadísticas de memoria virtual, tasas de fallos de página (page faults), transferencias de disco y transiciones de estado de la CPU en intervalos de 1 segundo.

```syslog
$ vmstat 1 5
 procs      memory      page                    disks     faults         cpu
 r b w     avm    fre   flt  re  pi  po  fr  sr da0 da1   in   sy   cs us sy id
 2 0 0   12.4G   4.1G   120   0   0   0 150   0   0   0  450 1200 3400 12  4 84
 1 0 0   12.4G   4.1G    45   0   0   0   0   0  12   0  410  890 2900  8  2 90
 4 1 0   13.1G   3.4G  4500  12 120   0 200   0  89   0 1250 8400 9200 45 25 30
 3 0 0   13.2G   3.3G  1200   0  45   0   0   0 145   0  980 4300 6100 35 15 50
 1 0 0   12.5G   4.0G   100   0   0   0   0   0  10   0  420  910 3000  9  3 88
```

*Métricas clave para la inspección de SRE*:
- `r`: Procesos en la run queue de la CPU.
- `b`: Procesos bloqueados en espera ininterrumpida de I/O (estado `D`).
- `pi`/`po`: Páginas paginadas hacia dentro / paginadas hacia fuera (paged in / paged out) del espacio de swap. Un `po` alto indica presión de memoria.
- `cs`: Cambios de contexto (context switches) por segundo. Un `cs` excesivo (>50k/s) señala contención de bloqueos o thrashing de CPU.

---

#### Comando 4.3: Utilización del espacio de swap (`pstat` / `swapctl`)

Inspección detallada de los dispositivos físicos de swap en BSD.

```syslog
$ pstat -s
Device          1K-blocks     Used    Avail Capacity
/dev/da0p3        8388608   524288  7864320     6%

$ swapctl -l
Device      512-blocks     Used    Avail Capacity Priority
/dev/da0p3    16777216  1048576 15728640     6%      0
```

---

#### Comando 4.4: Árbol de procesos y auditoría de estado en BSD (`ps`)

Inspecciona el árbol de ejecución de procesos, el consumo de recursos, las cuentas de usuario y los flags de estado en BSD.

```syslog
$ ps -ax -o pid,ppid,user,pri,nice,stat,vsz,rss,comm
  PID  PPID USER     PRI NICE STAT      VSZ    RSS COMM
    0     0 root     187    0 DLs       0k    16k kernel
    1     0 root      19    0 SLs    1048k   812k /sbin/init
  450     1 root      20    0 Ss     2450k  1420k /usr/sbin/syslogd
  890     1 root      20    0 Ss     4120k  2890k /usr/sbin/sshd
 1245   890 root      20    0 S      6780k  4100k sshd: opsadmin [priv]
 1248  1245 opsadmin  20    0 S      6780k  4150k sshd: opsadmin@pts/1
 1249  1248 opsadmin  20    0 Is+    2340k  1890k -tcsh (tcsh)
 4510     1 www       22    2 S      152M   45M /usr/local/bin/python3
 4511  4510 www       35   10 SN      98M   22M /usr/local/bin/python3
 9812  1249 opsadmin  59    0 R+     3100k  1540k ps
```

*Glosario de códigos de estado de procesos en BSD*:
- **Estados primarios**: `R` (Ejecutable/Ejecutándose - Runnable/Running), `S` (Durmiendo <20s - Sleeping), `I` (Inactivo >20s - Idle), `D` (Espera de disco ininterrumpida - Uninterruptible Disk Wait), `Z` (Zombie), `T` (Detenido - Stopped).
- **Modificadores**: `+` (Grupo de procesos en primer plano), `s` (Líder de sesión), `N` (Nivel nice > 0, prioridad reducida), `<` (Alta prioridad, nice < 0), `W` (Intercambiado a swap - Swapped out), `L` (Esperando bloqueo del kernel - Waiting on kernel lock).

---

#### Comando 4.5: Monitoreo de procesos en tiempo real (`top`)

Ejecuta `top` de forma interactiva en modo batch no interactivo ordenado por consumo de CPU.

```syslog
$ top -b -s 1 -o cpu -n 5
last pid:  9823;  load averages:  1.12,  0.85,  0.65  up 42+11:06:12  21:20:00
48 processes:  1 running, 47 sleeping
CPU:  8.5% user,  0.0% nice,  4.2% system,  1.2% interrupt, 86.1% idle
Mem: 2145M Active, 1420M Inact, 890M Wired, 4120M Free
ARC: 4500M Total, 1200M MFU, 2800M MRU, 16M Anon, 85M Header, 400M Metadata
Swap: 8192M Total, 512M Used, 7680M Free, 6% Inuse

  PID USERNAME    THR PRI NICE   SIZE    RES STATE    TIME    WCPU COMMAND
 4510 www           8  22    2   152M    45M uwait   12:45  18.40% python3
 1249 opsadmin      1  20    0  2340k  1890k pause    0:01   0.10% tcsh
  450 root          1  20    0  2450k  1420k select   0:45   0.00% syslogd
```

---

#### Comando 4.6: Filtrado de procesos y entrega de señales (`pgrep`, `pkill`, `kill`)

Busca PIDs por patrón exacto, filtra por usuario y ejecuta la entrega de señales.

```syslog
# Find PIDs of all python3 processes owned by user 'www'
$ pgrep -l -u www python3
4510 python3
4511 python3

# Send SIGHUP (Signal 1 - Configuration Reload) to all nginx processes
$ pkill -HUP -x nginx

# Graceful termination request (SIGTERM - 15) to specific process group
$ kill -15 -4510

# Forceful uncatchable termination (SIGKILL - 9)
$ kill -9 4510
```

---

#### Comando 4.7: Control de trabajos y ejecución de procesos en segundo plano

Demostración de la semántica del control de trabajos POSIX dentro de la shell.

```syslog
# Execute long running process in background using '&'
$ tar -czf /backup/app_data.tar.gz /var/www/data &
[1] 10452

# View active shell job table
$ jobs -l
[1] + 10452 Running              tar -czf /backup/app_data.tar.gz /var/www/data &

# Suspend a running foreground process using SIGTSTP (Ctrl + Z)
$ openssl speed rsa
^Z
[2]+  Stopped                 openssl speed rsa

# Resume job [2] in background
$ bg %2
[2]+ openssl speed rsa &

# Bring job [1] back to foreground
$ fg %1
tar -czf /backup/app_data.tar.gz /var/www/data

# Decouple process from SIGHUP on terminal closure using nohup
$ nohup python3 /usr/local/bin/sync_service.py > /var/log/sync.log 2>&1 &
[1] 10580
```

---

#### Comando 4.8: Ajuste de prioridades de procesos (`nice`, `renice`, `rtprio`)

Manipulación de las prioridades de planificación de CPU para procesos en ejecución.

```syslog
# Launch a CPU-intensive process with low priority (High nice value = 15)
$ nice -n 15 tar -czf /tmp/logs.tar.gz /var/log/

# Dynamically alter nice priority of running PID 4511 to 5
$ renice 5 -p 4511
4511 (process ID) old priority 10, new priority 5

# FreeBSD: Set real-time priority (RTPRIO) to 10 for latency-sensitive application (Requires root)
# rtprio <priority> <pid>
$ sudo rtprio 10 -p 4510

# Query current real-time / idle priority of process
$ rtprio 4510
pid 4510 real-time priority 10

# Set process to Idle Priority (Executes ONLY when system has 0 active threads in run queue)
$ sudo idprio 20 -p 4511
```

---

#### Comando 4.9: Rastreo de sockets y descriptores de archivos (`sockstat`, `fstat`, `procstat`)

Identificación de asignaciones de recursos de procesos.

```syslog
# Inspect IPv4/IPv6 listening sockets and associated PIDs/Commands
$ sockstat -4 -6 -l
USER     COMMAND    PID   FD PROTO LOCAL ADDRESS         FOREIGN ADDRESS
www      nginx      3410  6  tcp4  *:80                  *:*
www      nginx      3410  7  tcp4  *:443                 *:*
root     sshd       890   4  tcp4  *:22                  *:*
root     sshd       890   5  tcp6  *:22                  *:*

# List open files for a specific process ID using fstat
$ fstat -p 3410
USER     CMD          PID FD MOUNT      INUM MODE         SZ|DV R/W
www      nginx       3410 text /usr        4512 -rwxr-xr-x  1.2M  r
www      nginx       3410 wd   /          2 -rwxr-xr-x   512  r
www      nginx       3410    0 /          4 crw-rw-rw-  null rw
www      nginx       3410    6 internet 589122393 UDP *:53

# Query detailed BSD process binary memory mapping and signal masks
$ procstat -b 3410
  PID COMM             OSREL PATH
 3410 nginx         1302000 /usr/local/sbin/nginx

$ procstat -s 3410
  PID COMM             SIGS CAUGHT           IGNORE           HOLD
 3410 nginx            HUP  1000000000000000 0000000008000000 0000000000000000
```

---

### 5. Guía de verificación y diagnóstico de fallas

```
                         [Production Alert Triggers]
                                      |
                                      v
                        Is System Responding to SSH?
                       /                            \
                     (Yes)                          (No)
                      /                                \
          Check Load Avg (uptime, w)             PID Exhaustion / Console Lockup
             /                   \               Execute hard power cycle or NMI
       (High Load)           (Normal Load)       Kernel Panic Debug via Serial
          /                         \
  Check vmstat (r vs b)        Check Memory Leaks (top/ps)
     /              \
 (r > cores)      (b > 0)
   /                  \
CPU Starvation     I/O Wait (D State)
Use renice/rctl    Inspect Storage/ZFS Locks
```

#### Manual de incidentes 1: Proceso ineliminable en espera de disco ininterrumpida (Estado `D`)

* **Síntoma**: El proceso ignora `kill -9 <PID>`. El load average se incrementa constantemente. Las llamadas al sistema hacia el almacenamiento subyacente se bloquean indefinidamente.
* **Análisis de causa raíz**:
  El proceso está bloqueado en una espera de I/O a nivel de kernel (ej., esperando respuesta de NFS, bloque de disco con fallas o canal con deadlock en ZFS). Los procesos en estado `D` ignoran las señales POSIX porque la entrega de señales ocurre al retornar del espacio del kernel al espacio de usuario.
* **Protocolo de diagnóstico**:
  1. Identificar el canal de espera del hilo del kernel (WCHAN):
     ```syslog
     $ ps -ao pid,stat,wchan,comm | grep ' D '
     ```
  2. Inspeccionar el rastreo de la pila (backtrace) del kernel para el proceso bloqueado usando `procstat -k`:
     ```syslog
     $ sudo procstat -k 4510
       PID    TID COMM             TDNAME           KSTACK
      4510 100892 python3          -                mi_switch sleepq_wait nfs_request nfs_bioread vnode_pager_getpages
     ```
  3. *Resolución*: Si el canal de espera (`WCHAN`) está bloqueado en un montaje NFS (`nfs_bioread`), desmonte el recurso compartido NFS obsoleto de forma forzada usando `umount -f /mnt/stale_share`. Si el almacenamiento de hardware está colgado, libere el bloqueo del controlador de ruta de almacenamiento. Nunca intente un reinicio forzado sin identificar antes el WCHAN, ya que esto podría causar la corrupción del sistema de archivos.

---

#### Manual de incidentes 2: Acumulación de procesos Zombie (Estado `Z`)

* **Síntoma**: `ps aux` reporta múltiples procesos en estado `Z`. La capacidad total de PIDs del sistema (`kern.maxproc`) se llena con el tiempo.
* **Análisis de causa raíz**:
  El código de la aplicación ejecuta `fork()` seguido del cierre del hijo sin llamar a `waitpid()` en el bucle del hilo padre.
* **Protocolo de diagnóstico**:
  1. Localizar todos los zombies e identificar sus PIDs padre (`PPID`):
     ```syslog
     $ ps -ax -o pid,ppid,stat,user,comm | grep ' Z '
     ```
     *Salida de muestra*:
     ```syslog
     9120  4510 Z    www      <defunct>
     9121  4510 Z    www      <defunct>
     ```
  2. Inspeccionar el estado del PID padre (PPID 4510):
     ```syslog
     $ procstat -s 4510
     ```
  3. *Resolución*:
     - Enviar una señal al proceso padre para que maneje `SIGCHLD`: `kill -SIGCHLD 4510`.
     - Si el proceso padre está en deadlock o no cumple el estándar, finalizar el proceso padre: `kill -15 4510`.
     - Una vez que el PID padre 4510 finaliza, los zombies huérfanos son reasignados al PID 1 (`init`), el cual los recolecta (reaps) automáticamente de la tabla de procesos del kernel.

---

#### Manual de incidentes 3: Pánico por agotamiento de PID (`EAGAIN` en Fork)

* **Síntoma**: La terminal devuelve `fork: Resource temporarily unavailable` al ejecutar comandos o iniciar sesión a través de SSH.
* **Análisis de causa raíz**:
  El número de procesos activos ha alcanzado el límite de `kern.maxprocperuid` para un usuario o el límite global del sistema `kern.maxproc`.
* **Protocolo de diagnóstico**:
  1. Verificar el recuento de procesos del sistema por UID usando `ps`:
     ```syslog
     $ ps -A -o user | sort | uniq -c | sort -nr
     ```
  2. Consultar los límites actuales de procesos del kernel mediante sysctl:
     ```syslog
     $ sysctl kern.maxproc kern.maxprocperuid kern.openfiles
     ```
  3. *Mitigación inmediata*:
     - Si se inició sesión en una shell de root preexistente, ejecutar `pkill` por usuario o por nombre de binario:
       ```syslog
       $ pkill -u runaway_user -9
       ```
     - Elevar dinámicamente los límites del kernel mediante sysctl (solución temporal hasta el reinicio):
       ```syslog
       $ sudo sysctl kern.maxproc=65536
       $ sudo sysctl kern.maxprocperuid=32768
       ```

---

#### Manual de incidentes 4: Inanición (Starvation) de CPU e inversión de prioridad

* **Síntoma**: Los tiempos de respuesta de los servicios web superan los umbrales de SLA; alta utilización de CPU por usuario (`us`) en un solo núcleo mientras que los daemons multihilo sufren retrasos.
* **Análisis de causa raíz**:
  Las tareas en segundo plano de baja prioridad consumen cuotas de ejecución o bloquean mutexes compartidos requeridos por servicios web interactivos de alta prioridad.
* **Protocolo de diagnóstico**:
  1. Identificar los procesos con mayor consumo de CPU:
     ```syslog
     $ top -b -o cpu -n 10
     ```
  2. Inspeccionar la clase de planificación y los valores nice:
     ```syslog
     $ ps -o pid,user,nice,pri,stat,comm -p <PID>
     ```
  3. *Resolución*:
     - Degradar la prioridad del proceso deshonesto (rogue) en segundo plano inmediatamente:
       ```syslog
       $ renice +15 -p <PID>
       ```
     - Aplicar reglas de recursos de FreeBSD (`rctl`) para limitar el porcentaje de CPU en el contexto de ejecución objetivo:
       ```syslog
       $ sudo rctl -a user:runaway_user:pcpu:deny=50
       ```

---

### 6. Referencias

* **Linux Professional Institute (LPI) BSD Specialist Overview**:
  https://www.lpi.org/our-certifications/bsd-specialist-overview/
* **LPI Wiki — BSD Specialist Objectives V1.0 (Topic 715.3)**:
  https://wiki.lpi.org/wiki/BSD_Specialist_Objectives_V1.0
* **FreeBSD Manual Pages — `ps(1)`**:
  https://man.freebsd.org/cgi/man.cgi?query=ps
* **FreeBSD Manual Pages — `top(1)`**:
  https://man.freebsd.org/cgi/man.cgi?query=top
* **FreeBSD Manual Pages — `procstat(1)`**:
  https://man.freebsd.org/cgi/man.cgi?query=procstat
* **FreeBSD Manual Pages — `daemon(8)`**:
  https://man.freebsd.org/cgi/man.cgi?query=daemon
* **FreeBSD Manual Pages — `login.conf(5)`**:
  https://man.freebsd.org/cgi/man.cgi?query=login.conf
* **FreeBSD Architecture Handbook — Process Management**:
  https://docs.freebsd.org/en/books/arch-handbook/
* **OpenBSD Manual Pages — `kill(1)` & `pkill(1)`**:
  https://man.openbsd.org/kill.1
* **NetBSD Manual Pages — `sysctl(8)` & Process Tuning**:
  https://man.netbsd.org/sysctl.8