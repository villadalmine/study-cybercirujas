# LPI BSD Specialist (702-100) — Tema 713.7: Manage User Sessions

**Objetivo del Examen**: 702-100 (Versión 1.0)  
**Peso del Tema**: 1.67  
**Nivel del Rol**: Senior SRE / Principal Platform Architect  

---

## 1. Architectural Motivation & Production Context

En infraestructuras FreeBSD y BSD multitenant de alta concurrencia, la gestión de sesiones de usuario va más allá de simplemente ver quién ha iniciado sesión en una shell. Es un límite operacional crítico para el **aislamiento de recursos**, la **auditoría de seguridad**, el **control de terminales** y la **gobernanza del ciclo de vida de procesos**.

```
                           +-----------------------------------------------+
                           |            BSD Kernel Space                   |
                           +-----------------------------------------------+
                                  |                     |            |
                      tty / pts device             setsid(2)      revoke(2)
                                  |                     |            |
                                  v                     v            v
+------------------+     +------------------+     +--------------------------+
|  SSH / Console   | --> | Login Shell (PGRP| --> | Child Processes / Daemons|
| Daemon (sshd/pty)|     |  Leader / Session|     | (tmux, background jobs)  |
+------------------+     |      Leader)     |     +--------------------------+
                         +------------------+
                                  |
                                  v
                      +------------------------+
                      | Accounting Engine      |
                      | (/var/run/utx.active,  |
                      |  /var/log/utx.log)     |
                      +------------------------+
```

### Desafíos Arquitectónicos Clave en Producción

1. **Sesiones Huérfanas y Fugas de Recursos**: Cuando una conexión SSH se interrumpe de forma abrupta (por ejemplo, por una partición de red), la capa de transporte se rompe. Si `SIGHUP` es ignorado o capturado por subshells/multiplexores de terminal (`tmux`, `screen`, `nohup`), el árbol de procesos desacoplado de la terminal de control (`ctty`) permanece activo indefinidamente. Esto produce fugas de descriptores de archivo (FDs), memoria, sockets y slots de procesos de login (`maxproc`).
2. **Brechas de Seguridad por Invalidación de Terminal**: Finalizar una login shell (`kill -9 <PID>`) deja el dispositivo pseudo-terminal subyacente (`/dev/pts/X`) abierto si los procesos hijos retienen descriptores de archivo apuntando a `/dev/tty`. Los procesos subsiguientes asignados a ese slot `pts` podrían sufrir fugas de descriptores de archivo o inspección no autorizada (sniffing) de entrada/salida.
3. **Corrupción de Session Accounting**: En sistemas BSD, el seguimiento de sesiones de usuario se basa en el subsistema `utmpx(3)`. Si los procesos fallan (crash) o son finalizados por la fuerza (`SIGKILL`) sin activar las rutas de código de limpieza estándar (`exit(3)`), las entradas de sesión obsoletas permanecen en `/var/run/utx.active`. Esto corrompe las consultas de auditoría (`w(1)`, `who(1)`), lo que provoca que las herramientas de monitoreo de seguridad informen erróneamente la ocupación del sistema.
4. **Inanición de Recursos Multitenant**: La asignación irrestricta de sesiones permite que usuarios individuales consuman los procesos disponibles (`maxproc`), archivos abiertos (`openfiles`) y espacio de swap, degradando las cargas de trabajo vecinas en bastion hosts compartidos o runners de CI/CD.

---

## 2. Technical Comparison & Trade-off Analysis

### 2.1 Session Termination Mechanisms

| Mecanismo | Desencadenante / Comando | Acción del Kernel/SO | Trade-offs y Riesgo en Producción | Caso de Uso Principal |
| :--- | :--- | :--- | :--- | :--- |
| **Finalización del Session Leader** | `pkill -HUP -t pts/1` or `kill -1 <Session_PID>` | Envía `SIGHUP` al Session Leader. Las shells estándar propagan `SIGHUP` al Process Group (`PGRP`). | **Finalización Suave (Soft)**: Los procesos que capturen e ignoren `SIGHUP` (`nohup`, `tmux`) sobrevivirán. Cierre de aplicación más limpio. | Cierre de sesión ordenado y solicitudes de recarga de configuración. |
| **Barrido del Árbol del Process Group** | `pkill -TERM -u <user>` / `pkill -9 -u <user>` | Entrega la señal (`SIGTERM`/`SIGKILL`) directamente a todos los PIDs pertenecientes al UID del usuario. | **Agresivo**: Termina trabajos en segundo plano del usuario (ej. compilaciones activas de larga duración). `SIGKILL` previene los handlers de limpieza y corrompe `utmpx`. | Eliminar usuarios que no responden o detener scripts maliciosos. |
| **Revocación de Dispositivo Terminal** | `revoke /dev/pts/1` or `fbtab(5)` invocation | Invoca la syscall `revoke(2)`. Invalida todos los descriptores de archivo abiertos que acceden al archivo tty especificado. | **Desconexión Forzada (Hard)**: Destruye la capacidad de I/O instantáneamente. Las llamadas de lectura/escritura futuras retornan `-1 (EBADF)`. Los procesos hijos mueren en la siguiente I/O. | Sanitización de dispositivos tty físicos/virtuales al cerrar sesión para evitar escuchas no autorizadas (eavesdropping). |
| **Aplicación de PAM / Login Class** | `/etc/login.conf` (`idletime`, `maxproc`) | Aplica límites de recursos mediante `setrlimit(2)` durante la inicialización de la sesión (`login_cap`). | **Preventivo**: Requiere compilación de base de datos binaria (`cap_mkdb`). No puede finalizar de forma reactiva sesiones rebeldes que ya estén ejecutándose. | Establecer límites máximos de recursos predeterminados por clase de login. |

### 2.2 BSD Session Accounting Architecture (`utmpx`)

| Almacén de Datos / Interfaz | Ruta de Archivo / API | Propósito y Mecánica | Resiliencia y Mantenimiento |
| :--- | :--- | :--- | :--- |
| **Base de Datos de Sesiones Activas** | `/var/run/utx.active` | Almacena registros binarios de los usuarios actualmente conectados (leído por `w(1)`, `who(1)`). | **Efímero (Transient)**: Se borra al arrancar el sistema. Susceptible a entradas fantasma si los procesos de sesión mueren mediante `SIGKILL`. | Monitoreo de sesiones en tiempo real y verificaciones de ocupación actual. |
| **Registro de Auditoría Histórica de Login** | `/var/log/utx.log` | Registro histórico de tipo append-only de logins, cierres de sesión, reinicios y apagados (leído por `last(1)`). | **Persistente**: Requiere rotación de logs (`newsyslog.conf`) para evitar llenar el disco. | Cumplimiento normativo (compliance), auditoría forense y patrones de acceso históricos. |
| **Almacén de Último Login** | `/var/log/utx.lastlogin` | Rastrea la marca de tiempo de login más reciente por UID de usuario (leído por `pam_lastlog(8)`). | **Tamaño Fijo**: Indexado por UID. Alta durabilidad. | Notificaciones de seguridad al usuario al iniciar sesión ("Last login: ..."). |
| **Herramienta de Gestión de Accounting** | `/usr/bin/utx` | Utilidad de CLI para insertar, remover (`utx rm`) o sanitizar manualmente registros muertos en `utx.active`. | **Manual/Automatizado por Scripts**: Recupera la consistencia del estado sin requerir un reinicio del sistema. | Scripts de limpieza automatizados de SRE y reparación operacional. |

---

## 3. Complete Production Configuration Files & Automation

### 3.1 Hardened `/etc/login.conf` (Login Class Capabilities)

```ini
# /etc/login.conf - Production Session Control Configuration
# Recompile after modification: cap_mkdb /etc/login.conf

default:\
	:passwd_format=sha512:\
	:copyright=/etc/COPYRIGHT:\
	:welcome=/etc/motd:\
	:setenv=MAIL=/var/mail/$,BLOCKSIZE=K:\
	:path=/sbin /bin /usr/sbin /usr/bin /usr/local/sbin /usr/local/bin ~/bin:\
	:nologin=/var/run/nologin:\
	:cputime=unlimited:\
	:datasize=unlimited:\
	:stacksize=unlimited:\
	:memorylocked=64M:\
	:memoryuse=unlimited:\
	:filesize=unlimited:\
	:coredumpsize=0:\
	:openfiles=1024:\
	:maxproc=128:\
	:sbsize=unlimited:\
	:vmemorysize=unlimited:\
	:priority=0:\
	:ignorequota=off:\
	:umask=022:\
	:idletime=60m:

# Restricted class for temporary SRE contractors and junior developers
untrusted:\
	:tc=default:\
	:openfiles=256:\
	:maxproc=64:\
	:memoryuse=2048M:\
	:idletime=15m:\
	:welcome=/etc/motd.untrusted:\
	:requirehome:

# High-capacity login class for automated platform CI/CD pipelines
automation:\
	:tc=default:\
	:openfiles=8192:\
	:maxproc=1024:\
	:memoryuse=16384M:\
	:idletime=unlimited:\
	:coredumpsize=unlimited:
```

*Para aplicar los cambios de `/etc/login.conf` a la base de datos:*
```bash
$ sudo cap_mkdb /etc/login.conf
```

---

### 3.2 Secure `/etc/ssh/sshd_config` Session Rules

```ini
# /etc/ssh/sshd_config - Session Lifecycle Limits

# Global session constraints
MaxSessions 4
ClientAliveInterval 300
ClientAliveCountMax 2
TCPKeepAlive no

# Enforce strict session control for untrusted group
Match Group untrusted
    AllowTcpForwarding no
    X11Forwarding no
    MaxSessions 2
    ClientAliveInterval 120
    ClientAliveCountMax 1
```

---

### 3.3 Production SRE Session Reaper & Sanitizer Script

`/usr/local/sbin/sre_session_reaper.sh`

```bash
#!/bin/sh
# ==============================================================================
# SRE Automated Session Reaper & UTMPX Sanitizer for FreeBSD Systems
# ==============================================================================
set -eu

LOG_FILE="/var/log/session_reaper.log"
IDLE_THRESHOLD_SEC=7200 # 2 Hours in seconds

log_msg() {
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [SESSION-REAPER] $1" | tee -a "$LOG_FILE"
}

log_msg "Starting session health sweep..."

# 1. Broadcast maintenance notification to stale sessions
wall << 'EOF'
[SYSTEM NOTICE] Automated SRE policy enforcement: Idle sessions exceeding policy limits are subject to immediate termination.
EOF

# 2. Identify orphaned processes detached from terminals with high runtime
ps -ax -o user,pid,tty,state,command | awk '$3 == "??" && $4 ~ /I|S/ {print $1, $2, $5}' | while read -r USER PID CMD; do
    if [ "$USER" != "root" ] && [ "$USER" != "_daemon" ]; then
        log_msg "Terminating orphaned non-tty process: User=$USER PID=$PID Cmd=$CMD"
        kill -TERM "$PID" 2>/dev/null || kill -9 "$PID" 2>/dev/null || true
    fi
done

# 3. Clean up ghost entries in utx database where process no longer exists
utx list | while read -r LINE; do
    # Extract line pattern: ID | User | TTY | Host | Time
    ID=$(echo "$LINE" | awk '{print $1}')
    TYPE=$(echo "$LINE" | awk '{print $2}')
    
    if [ "$TYPE" = "USER_PROCESS" ]; then
        TTY=$(echo "$LINE" | awk '{print $4}')
        PID=$(echo "$LINE" | awk '{print $5}')
        
        if [ -n "$PID" ] && ! kill -0 "$PID" 2>/dev/null; then
            log_msg "Purging stale utx.active entry: ID=$ID TTY=$TTY DeadPID=$PID"
            utx rm "$ID" || true
        fi
    fi
done

log_msg "Session health sweep completed successfully."
exit 0
```

*Establecer permisos:*
```bash
$ sudo chmod 700 /usr/local/sbin/sre_session_reaper.sh
```

---

## 4. Real CLI Commands & Terminal Outputs

### 4.1 Inspecting Active User Sessions (`w` and `who`)

```bash
$ w
 8:42PM up 14 days,  3:21, 3 users, load averages: 0.12, 0.08, 0.05
USER     TTY      FROM              LOGIN@  IDLE WHAT
sre_admin pts/0    192.168.10.45    8:10PM     - w
dev_user pts/1    192.168.10.88    7:45PM 35:12 python3 long_running_script.py
bad_actor pts/2   10.0.0.15        6:15PM  2:14 -bash
```

```bash
$ who -a -H
NAME     LINE         TIME           IDLE          PID COMMENT             EXIT
         system boot  Aug  2 17:21
sre_admin pts/0       Aug  6 20:10     .         14205 (192.168.10.45)
dev_user pts/1       Aug  6 19:45   00:35        18902 (192.168.10.88)
bad_actor pts/2       Aug  6 18:15   02:14        22104 (10.0.0.15)
```

---

### 4.2 Detailed Process Tree & Session Ownership Inspection

```bash
$ ps -o user,pid,pgid,sid,tty,state,command -u dev_user
USER     PID  PGID   SID TTY      STAT COMMAND
dev_user 18902 18902 18902 pts/1    Is   -bash (bash)
dev_user 19105 19105 18902 pts/1    I+   python3 long_running_script.py
```

```bash
$ fstat -u dev_user
USER     CMD          PID FD MOUNT      INUM MODE         SZ|DV R/W
dev_user python3    19105 text /usr     104922 -rwxr-xr-x  2.4M  r
dev_user python3    19105    0 /dev       128 crw--w----  pts/1 rw
dev_user python3    19105    1 /dev       128 crw--w----  pts/1 rw
dev_user python3    19105    2 /dev       128 crw--w----  pts/1 rw
```

---

### 4.3 Querying Historical Sessions (`last`)

```bash
$ last -n 5 -h 192.168.10.88
dev_user pts/1        192.168.10.88    Thu Aug  6 19:45   still logged in
dev_user pts/0        192.168.10.88    Wed Aug  5 10:12 - 12:44  (02:31)
dev_user pts/2        192.168.10.88    Mon Aug  3 09:00 - 17:05  (08:05)

utx.log begins Mon Aug  3 00:00:00 UTC 2026
```

---

### 4.4 Managing `utmpx` Database State (`utx`)

```bash
$ utx list
BOOT_TIME  - -                     Thu Aug  2 17:21:00 2026
USER_PROC  sre_admin pts/0 14205   Thu Aug  6 20:10:15 2026
USER_PROC  dev_user  pts/1 18902   Thu Aug  6 19:45:02 2026
USER_PROC  bad_actor pts/2 22104   Thu Aug  6 18:15:33 2026
```

```bash
$ sudo utx rm pts/2
utx: record pts/2 removed from /var/run/utx.active
```

---

### 4.5 Terminating Sessions and Revoking Terminal Devices

```bash
$ sudo pkill -HUP -t pts/2
```

*Si los procesos capturan `SIGHUP` y se rehúsan a finalizar:*

```bash
$ sudo pkill -KILL -u bad_actor
```

*Invalidar los descriptores de archivo del dispositivo para forzar una desconexión limpia:*

```bash
$ sudo revoke /dev/pts/2
```

---

## 5. Verification & Fault Diagnostics Guide

```
                        +------------------------------------+
                        | Incident: Stale / Rogue Session   |
                        +------------------------------------+
                                          |
                                          v
                    Run `w` / `who -a` / `ps -o tty,pid,user`
                                          |
                     +--------------------+--------------------+
                     |                                         |
            Process is alive                        Process is dead (Ghost)
                     |                                         |
                     v                                         v
        Check CTTY: `fstat -p <PID>`                  Run `utx list`
                     |                                         |
       +-------------+-------------+                           v
       |                           |                  Remove via `utx rm <id>`
TTY Attached              Orphaned (TTY ??)                    |
       |                           |                           v
       v                           v                     Verify `w` output
  `pkill -HUP -t`          `pkill -KILL -g <PGRP>`           is clean
       |                           |
       v                           v
Check if process dies      Check FD leak (`fstat`)
       |                           |
[If persistent]                   v
`revoke /dev/pts/X`        `revoke /dev/pts/X`
```

### 5.1 Step-by-Step Diagnostic Scenarios

#### Escenario A: Proceso Rebelde Capturando Señales al Desconectar la Terminal
* **Síntoma**: El usuario `bad_actor` cerró sesión, pero la utilización de CPU permanece alta y `fstat` muestra procesos adjuntos a `/dev/pts/2`.
* **Procedimiento de Diagnóstico**:
  1. Inspeccionar el estado del proceso y la disposición de señales:
     ```bash
     $ ps -o pid,ppid,pgid,jobc,state,tty,command -u bad_actor
     ```
  2. Verificar los descriptores de archivo activos que apuntan a la terminal:
     ```bash
     $ fstat -p 22104
     ```
  3. Intentar la finalización gradual (graceful) del process group:
     ```bash
     $ sudo kill -TERM -22104
     ```
  4. Si el proceso permanece, invocar la revocación de descriptores de archivo a nivel de hardware:
     ```bash
     $ sudo revoke /dev/pts/2
     ```
  5. Emitir la limpieza forzada definitiva del proceso:
     ```bash
     $ sudo pkill -9 -u bad_actor
     ```

---

#### Escenario B: Base de Datos `utmpx` Corrupta (Sesiones Fantasma en `w(1)`)
* **Síntoma**: `w(1)` muestra al usuario `dev_user` activo en `pts/1`, pero `ps -p <PID>` revela que el proceso ya no existe.
* **Causa Raíz**: El proceso session leader sufrió un fallo (crash) no controlado o recibió `SIGKILL`, omitiendo las rutinas normales de salida de accounting (`pututxline(3)`).
* **Procedimiento de Diagnóstico y Remediación**:
  1. Confirmar que el PID listado en `utmpx` está muerto:
     ```bash
     $ utx list | grep pts/1
     USER_PROC dev_user pts/1 18902 Thu Aug 6 19:45:02 2026
     $ ps -p 18902
     PID TT STAT TIME COMMAND
     # (No output returned - PID is dead)
     ```
  2. Purgar de forma segura la entrada fantasma sin reiniciar daemons del sistema:
     ```bash
     $ sudo utx rm pts/1
     ```
  3. Validar que la salida de `w(1)` ahora refleje el estado real del kernel:
     ```bash
     $ w
     ```

---

#### Escenario C: Límite de Login Class Alcanzado (Agotamiento de `maxproc`)
* **Síntoma**: El usuario recibe `fork: Resource temporarily unavailable` al abrir una nueva sesión.
* **Procedimiento de Diagnóstico**:
  1. Inspeccionar el recuento de procesos activos del usuario objetivo:
     ```bash
     $ ps -u dev_user | wc -l
     ```
  2. Verificar el límite de login class del usuario en `/etc/login.conf`:
     ```bash
     $ login.conf -v
     $ grep -A 10 "untrusted:" /etc/login.conf
     ```
  3. Comprobar los valores actuales de capacidad aplicados a la sesión de usuario mediante `limits(1)`:
     ```bash
     $ limits -U dev_user
     Resource limits for class untrusted:
       cputime          infinity
       datasize         infinity
       stacksize        infinity
       memorylocked     64 MB
       memoryuse        2048 MB
       filesize         infinity
       coredumpsize     0 B
       openfiles        256
       maxproc          64
     ```
  4. Ajustar los límites en `/etc/login.conf` si es necesario, recompilar con `cap_mkdb /etc/login.conf` o finalizar procesos descontrolados (runaway processes).

---

## 6. Referencias

* **LPI BSD Specialist Certification Overview**:  
  https://www.lpi.org/our-certifications/bsd-specialist-overview/
* **FreeBSD Manual Pages — `w(1)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=w&sektion=1
* **FreeBSD Manual Pages — `login.conf(5)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=login.conf&sektion=5
* **FreeBSD Manual Pages — `utx(8)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=utx&sektion=8
* **FreeBSD Manual Pages — `revoke(2)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=revoke&sektion=2
* **FreeBSD Manual Pages — `ps(1)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=ps&sektion=1
* **FreeBSD Architecture Handbook — User Architecture & Login Capabilities**:  
  https://docs.freebsd.org/en/books/handbook/users/