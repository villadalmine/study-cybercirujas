# Guía de Estudio LPI-702 (Examen 702-100): Tema 713.4 – Registro del Sistema (System Logging)

---

## 1. Motivación Arquitectónica de Producción y Planteamiento del Problema

En entornos de producción empresariales, el registro del sistema (system logging) constituye la base operativa para la observabilidad, la auditoría de seguridad y el análisis forense en los ecosistemas BSD (FreeBSD, OpenBSD y NetBSD). Los registros del sistema capturan transiciones de estado, fallos del kernel, violaciones de seguridad y actividades de los demonios (daemons).

```
+-----------------------------------------------------------------------------------+
|                                   KERNEL SPACE                                    |
|                                                                                   |
|  [ Kernel Subsystems / Drivers ] ---> Log Ring Buffer (sysctl kern.msgbuf)        |
|                                             |                                     |
|                                             v                                     |
|                                         /dev/klog                                 |
+---------------------------------------------|-------------------------------------+
                                              |
+---------------------------------------------v-------------------------------------+
|                                    USER SPACE                                     |
|                                                                                   |
|  [ System Daemons ] ---> /dev/log <--- syslogd (Daemon)                           |
|  [ User Processes ]  (UNIX Domain Socket)   |                                     |
|                                             +---> Local Disk (/var/log/*)         |
|                                             +---> Console (/dev/console)          |
|                                             +---> Named Pipe (|/usr/local/bin/...) |
|                                             +---> Remote Syslog Server (@remote)  |
|                                                                                   |
|  [ Cron / Interval Daemon ] ---> newsyslog (Log Rotation Engine)                  |
|                                        |                                          |
|                                        +---> Rotate, Compress (.gz/.bz2/.xz),      |
|                                              & Signal Daemon (SIGHUP / SIGUSR1)   |
+-----------------------------------------------------------------------------------+
```

### Desafío Arquitectónico: Registro en Kernel-Space vs. User-Space
El sistema operativo divide el registro en dos espacios de ejecución principales:
1. **Registro en Kernel-Space (`/dev/klog`)**: El kernel escribe la inicialización del hardware, los diagnósticos de los controladores (drivers) y los eventos de panic en un ring buffer en memoria (accesible a través de `sysctl kern.msgbuf` o `dmesg`). Dado que la asignación de memoria del kernel no puede bloquearse durante panics de alta gravedad o contextos de interrupción, este buffer es de tamaño fijo. Si el daemon de registro en user-space no puede consumir las entradas lo suficientemente rápido desde `/dev/klog`, los mensajes antiguos se sobrescriben.
2. **Registro en User-Space (`/dev/log` y `syslogd`)**: Los daemons de user-space (por ejemplo, `sshd`, `unbound`, `pf`, `dhcpd`) emiten registros a través del socket de datagramas de dominio UNIX estándar `/dev/log`. El daemon `syslogd` escucha en `/dev/log` y `/dev/klog`, analiza la metadata de facility/severity, aplica las reglas de selector desde `/etc/syslog.conf` y envía la salida a destinos del sistema de archivos, consolas virtuales, endpoints remotos de syslog o pipelines de trabajadores.

### Compromisos de Ingeniería y Riesgos de Producción
- **I/O Sincrónico vs. Asincrónico**: Las escrituras directas en archivos en `syslogd` pueden realizar operaciones `fsync()` o bloquearse bajo una saturación severa de I/O de disco. Para evitar bloqueos en cascada del sistema, los SREs de producción deben desacoplar el registro local crítico de la entrega de transmisiones remotas.
- **Condiciones de Carrera en la Rotación de Registros**: Rotar archivos de registro mientras los procesos escriben activamente en descriptores de archivos abiertos genera datos huérfanos o escrituras no enlazadas (unlinked). El daemon `newsyslog` resuelve esto ejecutando cambios de archivo atómicos y enviando señales a los procesos de destino (por ejemplo, a través de `SIGHUP`) para que vuelvan a abrir los descriptores de archivos.
- **Seguridad e Integridad**: Los archivos de registro sin restricciones corren el riesgo de escalación de privilegios y manipulación de registros. En los sistemas BSD, se debe aplicar una estricta propiedad de archivos (`root:wheel`), modos (`0600` / `0640`) y flags de seguridad (`file flags` como `nodump` o `append-only`) durante la rotación.

---

## 2. Tablas de Comparación Técnica y Compromisos (Trade-offs)

### 2.1 Arquitecturas de Daemons: `syslogd` Nativo de BSD vs. Recolectores Avanzados de Terceros

| Característica / Métrica | `syslogd` Nativo de BSD | `rsyslog` | `syslog-ng` |
| :--- | :--- | :--- | :--- |
| **Footprint y Memoria** | Extremadamente mínimo (~2-5 MB RSS) | Medio (~15-40 MB RSS) | Medio-Alto (~30-80 MB RSS) |
| **Complejidad de Configuración** | Baja (sintaxis basada en posición `/etc/syslog.conf`) | Alta (RainerScript + formato Legacy) | Media-Alta (sintaxis de bloques estructurados) |
| **Protocolos de Transporte** | Socket local, UDP (`514`), TCP (extensiones de FreeBSD) | UDP, TCP, RELP, TLS/SSL, Kafka, HTTP | UDP, TCP, TLS/SSL, Elasticsearch, Kafka |
| **Estrategia de Buffering** | Solo cola de socket en memoria | Cola asistida por disco y en memoria | Opciones de buffer en memoria y disco |
| **Capacidades de Parsing** | RFC 3164 (BSD Syslog), etiquetas de programa BSD | RFC 3164, RFC 5424, parsing de JSON | RFC 3164, RFC 5424, Key-Value, JSON |
| **Idoneidad en Producción** | Registro del sistema base, hosts mínimos, hipervisores | Agregadores complejos de Linux/BSD empresariales | Nodos de parsing de registros complejos multitenant |

### 2.2 Motores de Rotación de Registros: `newsyslog` de BSD vs. `logrotate` de Linux

| Métrica Dimensional | `newsyslog` de BSD | `logrotate` de Linux |
| :--- | :--- | :--- |
| **Disparador de Ejecución** | Ejecución periódica por `cron` (normalmente cada hora) o ejecutado como daemon (`-D`) | Ejecución periódica por `cron` (diaria/semanal/mensual) o timer de systemd |
| **Arquitectura de Configuración** | Archivo único (`/etc/newsyslog.conf`) + directorio de inclusión (`/etc/newsyslog.conf.d/`) | Configuración central (`/etc/logrotate.conf`) + inclusiones (`/etc/logrotate.d/`) |
| **Disparadores de Tamaño y Tiempo** | Soporte doble: Basado en tamaño (KB), disparadores exactos de tiempo ISO 8601, u horas de intervalo | Schedules basados en tamaño, diarios/semanales/mensuales |
| **Soporte de Compresión** | Nativo `gzip` (`Z`), `bzip2` (`J`), `xz` (`X`), `zstd` (`Y`) mediante flags | Invocación de binarios externos (`gzip`, `bzip2`, `xz`) |
| **Gestión de PID** | Enrutamiento directo de señales por entrada de archivo (`/var/run/daemon.pid`) | Bloques de scripts `postrotate`/`prerotate` o `kill -HUP` |
| **Manejo Atómico** | Soporte nativo para recreación de sockets/pipes y flags de creación de registros | `create`, `copytruncate`, `delaycompress` nativos |

### 2.3 Compromisos del Algoritmo de Compresión para Registros Rotados

| Algoritmo | Flag en `newsyslog.conf` | Sobrecarga de CPU (Compresión) | Velocidad de Descompresión | Ratio de Compresión | Caso de Uso Principal en Producción |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`gzip`** | `Z` | Baja | Muy Alta | Estándar (~4:1) | Rotación heredada (legacy) estándar por defecto |
| **`bzip2`** | `J` | Alta | Moderada | Alta (~6:1) | Almacenamiento de archivos fríos con espacio de disco limitado |
| **`xz`** | `X` | Muy Alta | Alta | Muy Alta (~8:1) | Retención de cumplimiento regulatorio a largo plazo |
| **`zstd`** | `Y` (FreeBSD 13+) | Baja-Moderada | Extremadamente Alta | Alta (~6.5:1) | Agregadores de registros SRE modernos de alto rendimiento |

---

## 3. Manifiestos de Configuración para Producción

### 3.1 Manifiesto BSD `/etc/syslog.conf` en Producción
Esta configuración configura las facilities de registro, aísla eventos de seguridad, transmite registros operativos a archivos dedicados, reenvía errores a un agregador remoto de registros SRE mediante UDP/TCP y escribe alertas urgentes del kernel directamente en las terminales administrativas activas.

```syntax
# /etc/syslog.conf - Production FreeBSD/OpenBSD System Logging Configuration
# Selector Syntax: facility.level destination

# ------------------------------------------------------------------------------
# 1. EMERGENCY & CRITICAL KERNEL ALERTS
# ------------------------------------------------------------------------------
# Write all emergency messages (system unusable) to all logged-in operators
*.emerg                                         *

# Send critical kernel and hardware messages to system console and emergency log
kern.crit                                       /dev/console
kern.crit                                       /var/log/kernel_crit.log

# ------------------------------------------------------------------------------
# 2. SECURITY & AUTHENTICATION AUDITING
# ------------------------------------------------------------------------------
# Log all authentication events (auth, authpriv) with restricted permissions
auth,authpriv.info                              /var/log/auth.log
auth.notice                                     root

# ------------------------------------------------------------------------------
# 3. DAEMON & INFRASTRUCTURE SERVICES
# ------------------------------------------------------------------------------
# Capture general daemon activity (excluding debug logs for noise reduction)
daemon.info;daemon.!debug                        /var/log/daemon.log

# Mail subsystem logging
mail.info                                       /var/log/maillog

# Cron subsystem logging
cron.info                                       /var/log/cron

# ------------------------------------------------------------------------------
# 4. SYSTEM MESSAGES & CATCH-ALL
# ------------------------------------------------------------------------------
# General system messages catch-all rule
*.notice;auth.none;authpriv.none;mail.none;cron.none    /var/log/messages

# Debug logs isolated for non-production diagnostic tracing
*.debug;auth.none;authpriv.none                  /var/log/debug.log

# ------------------------------------------------------------------------------
# 5. PROGRAM-SPECIFIC FILTERING (BSD Extension Syntax)
# ------------------------------------------------------------------------------
# Isolate OpenSSH Server Logs
!sshd
*.*                                             /var/log/sshd.log
!*

# Isolate NGINX Web Server Logs (using Local Facility local0)
!nginx
local0.info                                     /var/log/nginx_access.log
local0.err                                      /var/log/nginx_error.log
!*

# ------------------------------------------------------------------------------
# 6. REMOTE CENTRALIZED LOG FORWARDING
# ------------------------------------------------------------------------------
# Forward all critical and error logs to central SRE aggregator via UDP
*.err;authpriv.info                             @syslog-relay.internal.net:514
```

### 3.2 BSD `/etc/newsyslog.conf` en Producción y Manifiesto de Módulo Incluido
Los parámetros de rotación de registros se definen utilizando `newsyslog.conf`. El esquema consta de 9 campos obligatorios/opcionales:
`logfilename` | `owner:group` | `mode` | `count` | `size` | `when` | `flags` | `[/pid_file]` | `[sig_num]`

A continuación se muestra la configuración maestra de producción (`/etc/newsyslog.conf`) y un archivo de extensión específico para la aplicación (`/etc/newsyslog.conf.d/app-services.conf`).

#### Configuración Central: `/etc/newsyslog.conf`

```syntax
# /etc/newsyslog.conf - Core BSD System Log Rotation Policy
# configuration file for newsyslog
#
# logfilename          owner:group    mode count size when  flags [/pid_file]          [sig_num]
/var/log/auth.log      root:wheel     600  12    1000 *     JC    /var/run/syslog.pid     1
/var/log/cron          root:wheel     600  10    1000 *     JC    /var/run/syslog.pid     1
/var/log/daemon.log    root:wheel     640  7     2048 *     Z     /var/run/syslog.pid     1
/var/log/debug.log     root:wheel     600  7     1024 *     ZC    /var/run/syslog.pid     1
/var/log/kernel_crit.log root:wheel   600  14    *    $D0   Z     /var/run/syslog.pid     1
/var/log/maillog       root:wheel     640  7     1000 *     ZC    /var/run/syslog.pid     1
/var/log/messages      root:wheel     644  5     1024 *     ZCNU  /var/run/syslog.pid     1
/var/log/sshd.log      root:wheel     600  14    5000 *     JC    /var/run/sshd.pid       1

# Include supplemental configuration directory
<include> /etc/newsyslog.conf.d/*.conf
```

#### Configuración de Microservicios: `/etc/newsyslog.conf.d/app-services.conf`

```syntax
# /etc/newsyslog.conf.d/app-services.conf - Production Application Rotation Rules
#
# logfilename               owner:group      mode count size  when flags [/pid_file]               [sig_num]
/var/log/nginx_access.log   www:www          644  24    10000 *    Z     /var/run/nginx.pid           30
/var/log/nginx_error.log    www:www          644  14    2048  *    ZC    /var/run/nginx.pid           30
/var/log/pg_cluster.log     postgres:wheel   600  30    *     $W6D0 X    /var/run/postgresql/pid.file 1
```

#### Explicación de Campos y Glosario de Flags para `newsyslog.conf`:
- **`mode`**: Permisos octales de archivo para los archivos de registro creados (por ejemplo, `600` restringe el acceso al propietario; `644` permite lectura global).
- **`count`**: Número de archivos de registro históricos retenidos antes de su eliminación.
- **`size`**: Tamaño máximo del archivo en kilobytes (KB) antes de activar la rotación (por ejemplo, `1000` = ~1 MB). Establezca en `*` si la rotación se basa puramente en el tiempo.
- **`when`**: Disparador de rotación basado en tiempo.
  - `*`: Rotación basada únicamente en el tamaño.
  - `$D0`: Rotar diariamente a medianoche.
  - `$W6D0`: Rotar semanalmente el sábado (Día 6) a medianoche.
  - Formatos `ISO 8601` (por ejemplo, `20260806T200000`).
- **`flags`**:
  - **`B`**: Tratar el archivo como binario; no escribir el encabezado indicador ASCII rotacional de `newsyslog`.
  - **`C`**: Crear el archivo de registro si no existe.
  - **`J`**: Comprimir los archivos de registro rotados usando `bzip2` (`.bz2`).
  - **`Z`**: Comprimir los archivos de registro rotados usando `gzip` (`.gz`).
  - **`X`**: Comprimir los archivos de registro rotados usando `xz` (`.xz`).
  - **`Y`**: Comprimir los archivos de registro rotados usando `zstd` (`.zst`).
  - **`N`**: No se requiere ninguna señal al daemon tras la rotación.
  - **`U`**: El campo `pid_file` especifica la ruta a un socket de dominio UNIX en lugar de un archivo que contiene un PID numérico.
- **`pid_file`**: Ruta al archivo PID del daemon de destino (por defecto es `/var/run/syslog.pid`).
- **`sig_num`**: Número de señal a transmitir al daemon tras la rotación (por defecto es `1` = `SIGHUP`; `30` = `SIGUSR1`).

---

### 3.3 Sintaxis de Inicialización del Sistema (`/etc/rc.conf` para FreeBSD)

```sh
# /etc/rc.conf - Syslogd and Newsyslog Daemon Flags
syslogd_enable="YES"
# -s: Secure mode (do not listen on UDP 514 socket for incoming remote messages)
# -c: Disable compression of repeated consecutive lines (log integrity)
# -b 127.0.0.1: Bind socket specifically to loopback interface if networking is needed
syslogd_flags="-s -c"

# Run newsyslog in daemon mode checking intervals every 60 minutes
newsyslog_enable="YES"
newsyslog_flags="-i 60"
```

---

## 4. Comandos CLI Reales y Salidas de Terminal

### 4.1 Extracción de Registros del Ring Buffer del Kernel mediante `dmesg` y `sysctl`

```console
$ dmesg | head -n 15
FreeBSD 14.0-RELEASE-p6 GENERIC amd64
FreeBSD clang version 16.0.6 (https://github.com/llvm/llvm-project.git llvmorg-16.0.6-0-g7c207378d37e)
VT(vga): resolution 640x480
CPU: AMD EPYC 7763 64-Core Processor (2445.38-MHz K8-class CPU)
  Origin="AuthenticAMD"  Id=0xa00f11  Family=0x19  Model=0x1  Stepping=1
real memory  = 8589934592 (8192 MB)
avail memory = 8245719040 (7863 MB)
Event timer "LAPIC" quality 600
ACPI APIC Table: <BOCHS  BXPCAPIC>
random: entropy device external interface
kbd0 at kbdmux0
smbios0: <System BIOS> at iomem 0xf0000-0xfffff
vtnet0: <Ethernet> rva 0x1000 on virtio_pci0
vtnet0: Ethernet address: 52:54:00:12:34:56
001.000000 [GIANT-LOCKED] init: flags 0x1

$ sysctl kern.msgbuf
kern.msgbuf: <13>1 2026-08-06T20:15:32.104218-04:00 bsd-prod-node01 kernel - - - vtnet0: link state changed to UP
<13>1 2026-08-06T20:15:33.401290-04:00 bsd-prod-node01 kernel - - - ZFS storage pool 'zroot' feature@async_destroy is enabled
<11>1 2026-08-06T20:22:11.001923-04:00 bsd-prod-node01 kernel - - - pf: Bad IP option (20) from 192.168.1.100 to 10.0.0.1
```

### 4.2 Generación de Mensajes de Registro de Prueba mediante `logger`

```console
$ logger -p local0.err -t NGINX_TEST "CRITICAL: Upstream database connection timed out on 10.0.0.50:5432"

$ tail -n 2 /var/log/nginx_error.log
Aug  6 20:30:12 bsd-prod-node01 NGINX_TEST[45102]: CRITICAL: Upstream database connection timed out on 10.0.0.50:5432
```

### 4.3 Inspección de Archivos de Registro Activos y Comprimidos

#### Transmisión de Registros en Tiempo Real (`tail -f`)

```console
$ tail -n 5 -f /var/log/auth.log
Aug  6 20:32:01 bsd-prod-node01 sshd[88102]: Server listening on 0.0.0.0 port 22.
Aug  6 20:32:01 bsd-prod-node01 sshd[88102]: Server listening on :: port 22.
Aug  6 20:33:15 bsd-prod-node01 sshd[88204]: Accepted publickey for admin from 192.168.1.250 port 52104 ssh2: RSA SHA256:d8a9f...
Aug  6 20:33:15 bsd-prod-node01 sudo[88209]:    admin : TTY=pts/0 ; PWD=/home/admin ; USER=root ; COMMAND=/usr/bin/su -
Aug  6 20:35:40 bsd-prod-node01 sshd[88310]: Failed password for invalid user hacker from 203.0.113.45 port 41122 ssh2
```

#### Búsqueda en Registros Comprimidos (`zgrep`, `zless`, `bzcat`)

```console
$ ls -l /var/log/messages*
-rw-r--r--  1 root  wheel  1048820 Aug  6 20:00 /var/log/messages
-rw-r--r--  1 root  wheel   124512 Aug  5 23:59 /var/log/messages.0.gz
-rw-r--r--  1 root  wheel   118940 Aug  4 23:59 /var/log/messages.1.gz
-rw-r--r--  1 root  wheel    98412 Aug  3 23:59 /var/log/messages.2.bz2

$ zgrep -i "OOM" /var/log/messages.0.gz /var/log/messages.1.gz
/var/log/messages.0.gz:Aug  5 14:12:01 bsd-prod-node01 kernel: pid 41203 (java), jid 0, was killed: out of swap space
/var/log/messages.1.gz:Aug  4 09:45:22 bsd-prod-node01 kernel: pid 11029 (redis-server), jid 0, was killed: out of swap space

$ bzcat /var/log/messages.2.bz2 | grep "panic" | head -n 3
Aug  3 11:20:05 bsd-prod-node01 kernel: Fatal trap 12: page fault while in kernel mode
Aug  3 11:20:05 bsd-prod-node01 kernel: cpuid = 2; apic id = 02
Aug  3 11:20:05 bsd-prod-node01 kernel: panic: vm_fault_lookup: fault on no-fault-zone address
```

### 4.4 Simulación de Prueba en Seco (Dry-Run) de Rotación de Registros mediante `newsyslog`

```console
$ newsyslog -n -v -f /etc/newsyslog.conf
Processing /etc/newsyslog.conf
Processing /etc/newsyslog.conf.d/app-services.conf
/var/log/auth.log <12J>: size (KB): 450 [1000] count: 12 --> skipped
/var/log/cron <10J>: size (KB): 120 [1000] count: 10 --> skipped
/var/log/daemon.log <7Z>: size (KB): 2150 [2048] count: 7 --> ROTATING
Signal daemon: /var/run/syslog.pid with signal 1
Trim log file /var/log/daemon.log to /var/log/daemon.log.0
Compress /var/log/daemon.log.0 to /var/log/daemon.log.0.gz with gzip
/var/log/nginx_access.log <24Z>: size (KB): 12400 [10000] count: 24 --> ROTATING
Signal daemon: /var/run/nginx.pid with signal 30
Trim log file /var/log/nginx_access.log to /var/log/nginx_access.log.0
Compress /var/log/nginx_access.log.0 to /var/log/nginx_access.log.0.gz with gzip
```

### 4.5 Auditoría de Sockets de Escucha Activos y Handlers de Archivos

```console
$ sockstat -46 -l -p 514
USER     COMMAND    PID   FD PROTO  LOCAL ADDRESS         FOREIGN ADDRESS      
root     syslogd    1045  4  udp4   *:514                 *:*
root     syslogd    1045  5  udp6   *:514                 *:*

$ fstat /dev/log
USER     CMD          PID FD MOUNT      INUM MODE         RDEV R/W
root     syslogd     1045  3 /var       4510 crw-rw-rw-   log  r+
www      nginx      42105  4 /var       4510 crw-rw-rw-   log   w
postgres postgres   18902  3 /var       4510 crw-rw-rw-   log   w
```

---

## 5. Guía de Verificación y Diagnóstico de Fallos

```
                         [ TROUBLESHOOTING LOGGING FAILURES ]
                                          |
                        Is syslogd process running?
                                          |
                     +--------------------+--------------------+
                     | NO                                      | YES
                     v                                         v
         Check /var/log/messages or            Are logs writing to /var/log/?
         run: service syslogd start                            |
                     |                       +-----------------+-----------------+
                     v                       | NO                                | YES
         Inspect syntax errors in            v                                   v
         /etc/syslog.conf via:       Are socket permissions          Are rotated files
         syslogd -d -n               /dev/log set to 0666?           expanding infinitely?
                                             |                                   |
                                 +-----------+-----------+           +-----------+-----------+
                                 | NO                    | YES       | YES                   | NO
                                 v                       v           v                       v
                         Fix file modes via:     Check disk space   Verify newsyslog.conf   System logging
                         chmod 666 /dev/log      & mounts via:      syntax via:             functioning
                                                 df -h /var/log     newsyslog -n -v         normally.
```

### 5.1 Flujos de Trabajo Diagnósticos Paso a Paso

#### Escenario A: Caída de Mensajes de Registro Bajo Alta Carga del Sistema
1. **Síntoma**: Los registros de aplicación faltan durante los picos de tráfico; `syslogd` descarta entradas emitidas a `/dev/log`.
2. **Causa Raíz**: El tamaño del buffer del socket predeterminado para `/dev/log` está saturado, o el buffer de registros del kernel se desborda (wraps over).
3. **Comandos de Diagnóstico**:
   ```console
   # Check kernel socket buffer overflow counters
   $ netstat -s -p datagram | grep "buffer overflow"
           4120 datagram socket buffer overflows

   # Inspect syslogd process status and socket bindings
   $ fstat -p $(cat /var/run/syslog.pid)
   ```
4. **Remediación**: Incrementar la profundidad del buffer de socket en `/etc/rc.conf` o ajustar `kern.ipc.maxsockbuf`:
   ```console
   $ sysctl kern.ipc.maxsockbuf=2097152
   ```

#### Escenario B: `newsyslog` Rota Archivos, pero la Aplicación Continúa Escribiendo en el Archivo Antiguo Desvinculado (`.0`)
1. **Síntoma**: El espacio en disco no se recupera después de la rotación, y los nuevos archivos de registro (`/var/log/app.log`) permanecen en 0 bytes mientras que `/var/log/app.log.0` crece.
2. **Causa Raíz**: `newsyslog` no pudo enviar la señal correcta al proceso de destino, o el proceso no captura `SIGHUP` para cerrar y volver a abrir los handlers de archivos.
3. **Comandos de Diagnóstico**:
   ```console
   # Check deleted/unlinked open file descriptorsheld by processes
   $ fstat | grep " /var" | grep "deleted"
   www      nginx      42105  5 /var     102404 crw-r--r--  -  rw

   # Test manual signal delivery to application PID
   $ kill -HUP $(cat /var/run/nginx.pid)
   ```
4. **Remediación**: Actualizar `/etc/newsyslog.conf` con la ruta explícita al archivo PID y el número de señal preciso (por ejemplo, `30` para `SIGUSR1` en NGINX).

#### Escenario C: Depuración de Errores de Parsing en `syslogd`
1. **Síntoma**: Las reglas definidas en `/etc/syslog.conf` no enrutan los registros a los archivos de destino designados.
2. **Causa Raíz**: Errores de sintaxis (por ejemplo, uso de espacios en lugar de tabuladores en el syslogd de BSD heredado, especificadores de facility no válidos o bloques de programa sin cerrar `!prog`).
3. **Comandos de Diagnóstico**:
   ```console
   # Stop the running syslogd service
   $ service syslogd stop

   # Launch syslogd in foreground debug mode
   $ syslogd -d -n
   cfline("*.notice;auth.none /var/log/messages", f)
   cfline("auth.info /var/log/auth.log", f)
   logmsg: pri 56, flags 0, from bsd-node, msg Aug 6 20:40:00 test: hello world
   Logging to /var/log/messages
   ```

---

## 6. Referencias

- **Páginas de Manual Oficiales de FreeBSD**:
  - `syslogd(8)`: Especificación y flags del daemon de registro del sistema.  
    URL: https://man.freebsd.org/cgi/man.cgi?query=syslogd&sektion=8
  - `syslog.conf(5)`: Formato y reglas para la configuración de registros del sistema.  
    URL: https://man.freebsd.org/cgi/man.cgi?query=syslog.conf&sektion=5
  - `newsyslog(8)`: Operación del motor de rotación de archivos de registro.  
    URL: https://man.freebsd.org/cgi/man.cgi?query=newsyslog&sektion=8
  - `newsyslog.conf(5)`: Formato de archivo de rotación de registros y especificación de flags.  
    URL: https://man.freebsd.org/cgi/man.cgi?query=newsyslog.conf&sektion=5
  - `logger(1)`: Interfaz de comandos del usuario para el socket de registros del sistema.  
    URL: https://man.freebsd.org/cgi/man.cgi?query=logger&sektion=1
- **Páginas de Manual Oficiales de OpenBSD**:
  - `syslogd(8)`: Documentación del daemon syslog de OpenBSD.  
    URL: https://man.openbsd.org/syslogd.8
  - `newsyslog(8)`: Documentación de la utilidad de rotación de registros de OpenBSD.  
    URL: https://man.openbsd.org/newsyslog.8
- **Resumen de la Certificación LPI BSD Specialist**:
  - Página oficial de la certificación LPI BSD Specialist (Examen 702-100).  
    URL: https://www.lpi.org/our-certifications/bsd-specialist-overview/