# LPI-702 (Examen 702-100) Tema 713.7: Administrar sesiones de usuario

**Peso del examen:** 1.67  
**Certificación objetivo:** LPI BSD Specialist (Examen 702-100, Versión 1.0)  
**Dominio principal:** Tema 713 — Administración básica del sistema BSD  

---

## 1. Análisis arquitectónico profundo y mecánica interna

### 1.1 Arquitectura de la base de datos de sesiones de usuario en BSD: `utmp`, `utmpx` y cumplimiento de POSIX

En sistemas BSD Unix (FreeBSD, OpenBSD, NetBSD), el estado de la sesión de usuario se rastrea a través de bases de datos binarias de contabilidad (accounting databases). Comprender la distinción entre las estructuras de formato BSD `utmp` heredadas y las implementaciones modernas `utmpx` compatibles con POSIX es vital para la administración de sistemas empresariales, la auditoría de seguridad y el análisis forense.

```
+-----------------------------------------------------------------------------------+
|                                 USER LOGIN SESSION                                |
|        (sshd daemon / getty / login process allocates TTY / PTS pair)            |
+-----------------------------------------------------------------------------------+
                                          |
                                          v
                         +---------------------------------+
                         |   POSIX utmpx Library (getutx*) |
                         +---------------------------------+
                                          |
             +----------------------------+----------------------------+
             |                            |                            |
             v                            v                            v
  +--------------------+        +-------------------+        +--------------------+
  | /var/run/utx.active|        |  /var/log/utx.log |        |/var/log/utx.lastlogin|
  |  (Active Sessions) |        | (Login/Logout Log)|        | (Last Login Info)  |
  +--------------------+        +-------------------+        +--------------------+
             |                            |                            |
             v                            v                            v
  Parsed by: `w`, `who`          Parsed by: `last`, `ac`      Parsed by: `pam_lastlog`
```

#### Comparación de componentes de la base de datos:

| Área funcional | Estándar moderno en FreeBSD (`utmpx`) | Estándar heredado/actual en OpenBSD | Descripción y propósito |
| :--- | :--- | :--- | :--- |
| **Active Session Store** | `/var/run/utx.active` | `/var/run/utmp` | Mantiene el estado actual de las sesiones de inicio de sesión interactivas, tareas en segundo plano y pseudoterminales. |
| **Historical Login Log** | `/var/log/utx.log` | `/var/log/wtmp` | Registro de auditoría de solo anexar (append-only) que rastrea inicios de sesión, cierres de sesión, eventos de reinicio y apagados del sistema. |
| **Last Login Log** | `/var/log/utx.lastlogin` | `/var/log/lastlog` | Arreglo de tamaño fijo indexado por ID de usuario (UID) que almacena la marca de tiempo y el origen de la sesión más reciente. |

#### Representación estructural de datos en C (`struct utmpx`)
En sistemas FreeBSD (`<utmpx.h>`), los registros de sesión se ajustan a la siguiente estructura estándar de POSIX:

```c
struct utmpx {
    short           ut_type;        /* Type of entry (e.g., USER_PROCESS, BOOT_TIME, DEAD_PROCESS) */
    struct timeval  ut_tv;          /* Time entry was made */
    char            ut_id[8];       /* Record identifier (e.g., tty name suffix or inittab ID) */
    pid_t           ut_pid;         /* Process ID of the session process leader */
    char            ut_user[32];    /* User login name */
    char            ut_line[16];    /* Device name (tty, pts/0, etc.) */
    char            ut_host[128];   /* Remote host name / IPv4 / IPv6 string */
    char            ut_spare[64];   /* Reserved space for future extension */
};
```

#### Tipos de entrada (Constantes `ut_type`):
*   `EMPTY` (`0`): Slot de base de datos inactivo o limpio.
*   `BOOT_TIME` (`2`): Marca de tiempo del inicio del sistema registrada por `init` o scripts de arranque del kernel.
*   `OLD_TIME` / `NEW_TIME` (`3`/`4`): Registrado cuando el reloj del sistema se ajusta manualmente o mediante NTP.
*   `USER_PROCESS` (`7`): Sesión de usuario interactiva activa establecida por `login`, `sshd` o `tmux`.
*   `DEAD_PROCESS` (`8`): Registro de sesión terminada que permanece hasta ser reclamado.

---

### 1.2 Jerarquía de procesos, Session IDs y asignación de terminales

Cuando un usuario se conecta a un host BSD a través de SSH o la consola, el sistema operativo establece un entorno de proceso controlado vinculado a una terminal de control (`tty` o `pts`).

```
 +------------------+
 |    sshd (root)   |  <-- Master Daemon listening on Port 22
 +------------------+
          |
          | forks & drops privileges
          v
 +------------------+
 |  sshd: alice [net|  <-- Session Process (Privilege Separated)
 +------------------+
          |
          | calls setsid() & opens pseudo-terminal slave (/dev/pts/0)
          v
 +------------------+
 |  -tcsh (alice)   |  <-- Login Shell (Session Leader, PID == SID == PGID)
 +------------------+
          |
          | forks foreground job
          v
 +------------------+
 |    top (alice)   |  <-- Foreground Process Group Leader
 +------------------+
```

1.  **Líder de sesión y llamada a `setsid()`:**  
    El proceso demonio invoca `setsid(2)`, creando un nuevo Session ID (`SID`) igual al Process ID (`PID`) de la shell, creando un nuevo Process Group ID (`PGID`) y desvinculándose de cualquier terminal de control.
2.  **Multiplexación de pseudoterminales (`/dev/ptmx` y `/dev/pts/*`):**  
    La terminal esclava asignada (`/dev/pts/X`) se convierte en la terminal de control para la shell de inicio de sesión. Los descriptores estándar (0: `stdin`, 1: `stdout`, 2: `stderr`) hacen referencia a esta interfaz de dispositivo de caracteres gestionada por el `devfs` de FreeBSD.
3.  **Mecanismo de cálculo de tiempo de inactividad (Idle Time):**  
    Utilidades como `w(1)` calculan el tiempo de inactividad del usuario ejecutando `stat(2)` en el nodo del archivo del dispositivo de caracteres asociado con la línea del usuario (por ejemplo, `/dev/pts/0`). El tiempo transcurrido desde el `st_atime` del archivo (última hora de acceso) o `st_mtime` (última hora de modificación) determina la duración de inactividad reportada.

---

### 1.3 Compromisos en producción y consideraciones de seguridad

```
+-----------------------------------------------------------------------------------+
|                        SECURITY & AUDIT TRAIL ARCHITECTURE                        |
+-----------------------------------------------------------------------------------+
|                                                                                   |
|  1. LOG TAMPERING & INTEGRITY RISKS:                                              |
|     - Binary utx logs lack native cryptographic signature checks.                 |
|     - Attackers with root/write permissions on /var/log/utx.log can truncate or   |
|       modify login timestamps to hide footprint.                                  |
|     - Mitigation: Forward session events via syslogd to remote append-only SIEM.   |
|                                                                                   |
|  2. PRIVACY VS ACCESSIBILITY:                                                     |
|     - /var/run/utx.active is world-readable by default (0644).                    |
|     - Any user can inspect active user accounts, source IP addresses, and commands. |
|     - Hardening: Set security.bsd.see_other_uids=0 to obscure unprivileged users.   |
|                                                                                   |
|  3. PERFORMANCE & LOG ROTATION:                                                   |
|     - Unbounded growth of /var/log/utx.log degrades `last` performance.           |
|     - Maintenance: Configure rotation policies in /etc/newsyslog.conf.            |
+-----------------------------------------------------------------------------------+
```

---

## 2. Artefactos de configuración y manifiestos de producción

### 2.1 `/etc/login.conf` — Manifiesto de capacidades de inicio de sesión y límites de recursos

El archivo `/etc/login.conf` gestiona las clases de inicio de sesión de usuario, estableciendo límites en los entornos de ejecución, sesiones concurrentes, uso de memoria y archivos abiertos. Después de editarlo, compile la base de datos binaria con `cap_mkdb /etc/login.conf`.

```ini
# /etc/login.conf - Production Class Specification for SRE Engineers
# Syntax: fieldname=value: or fieldname#number: or fieldname:

default:\
	:passwd_format=sha512:\
	:copyright=/etc/COPYRIGHT:\
	:welcome=/etc/motd:\
	:setenv=MAIL=/var/mail/$,BLOCKSIZE=K:\
	:path=/sbin /bin /usr/sbin /usr/bin /usr/local/sbin /usr/local/bin:\
	:nologin=/usr/sbin/nologin:\
	:cputime=unlimited:\
	:datasize=unlimited:\
	:stacksize=unlimited:\
	:memorylocked=64M:\
	:memoryuse=unlimited:\
	:filesize=unlimited:\
	:coredumpsize=0:\
	:openfiles=1024:\
	:maxproc=512:\
	:sbsize=unlimited:\
	:vmemorysize=unlimited:\
	:priority=0:\
	:ignorequota=off:\
	:umask=022:

# Restricted SRE Operator Class with session limits
sre_operator:\
	:tc=default:\
	:maxproc=256:\
	:openfiles=4096:\
	:maxlogins=3:\
	:requirehome=on:\
	:priority=0:\
	:umask=027:\
	:lang=en_US.UTF-8:
```

---

### 2.2 `/etc/pam.d/sshd` — Flujo de sesión del Pluggable Authentication Module (PAM)

Esta configuración rige cómo se registran, autentican e inicializan las sesiones de usuario al iniciar sesión mediante SSH en sistemas FreeBSD.

```ini
# /etc/pam.d/sshd - Production Session & Authentication Policy
# PAM module enforcement ordering for SSH user sessions

# Authentication Phase
auth        sufficient    pam_opie.so                no_warn auth_as_client
auth        requisite     pam_opieaccess.so          no_warn allow_local
auth        required      pam_unix.so                no_warn try_first_pass

# Account Management Phase
account     required      pam_nologin.so
account     required      pam_login_access.so
account     required      pam_unix.so

# Session Management Phase
session     required      pam_permit.so
session     required      pam_lastlog.so             no_fail

# Password Management Phase
password    required      pam_unix.so                no_warn shadow try_first_pass
```

---

### 2.3 `/etc/newsyslog.conf` — Reglas de rotación de logs para el seguimiento de sesiones de usuario

Los archivos de registro de sesión como `/var/log/utx.log` crecen con el tiempo y deben rotarse sistemáticamente para evitar el agotamiento del almacenamiento mientras se mantiene la preparación para auditorías.

```text
# /etc/newsyslog.conf snippet for Session Accounting Logs
# logfilename          [owner:group]    mode count size when  flags [/pid_file] [sig_num]
/var/log/utx.log                        644  12    1024 *     B
/var/log/utx.lastlogin                  644  5     *    @T00  B
/var/account/acct                       600  10    5000 *     BZ
```

---

## 3. Ejercicios prácticos guiados y diagnósticos

### Lab 1: Inspección de sesiones activas y asignación de terminales (`who`, `w`, `sockstat`, `fstat`)

En este laboratorio, auditará las sesiones de usuario activas, inspeccionará los detalles de los procesos de sesión, mapeará descriptores de sockets a sesiones de terminal y rastreará la ejecución de procesos.

#### Comandos ejecutables:

```bash
# Step 1: Query the active system users using `who` with detailed headings
who -a -H

# Step 2: Analyze active user processes, system load, and idle times using `w`
w -v

# Step 3: Identify active SSH user sessions and their associated network sockets
sockstat -4 -6 -c -p 22

# Step 4: Map open pseudo-terminals (/dev/pts/*) to running process PIDs using `fstat`
fstat /dev/pts/0
```

#### Salidas de comandos reales:

```console
$ who -a -H
NAME     LINE         TIME           IDLE          PID COMMENT
boottime .            Aug  6 12:00      .            1
alice    pts/0        Aug  6 14:22  00:02        45120 (192.168.1.105)
bob      pts/1        Aug  6 15:10      .        48201 (192.168.1.110)

$ w
 3:30PM  up  3:30, 2 users, load averages: 0.12, 0.08, 0.04
USER     TTY      FROM              LOGIN@  IDLE WHAT
alice    pts/0    192.168.1.105    2:22PM     2 top -a
bob      pts/1    192.168.1.110    3:10PM     - vim /etc/nginx/nginx.conf

$ sockstat -4 -6 -c -p 22
USER     COMMAND    PID   FD PROTO LOCAL ADDRESS         FOREIGN ADDRESS
root     sshd       1204  4  tcp4  10.0.0.15:22          *:*
alice    sshd       45118 5  tcp4  10.0.0.15:22          192.168.1.105:54210
bob      sshd       48199 5  tcp4  10.0.0.15:22          192.168.1.110:59134

$ fstat /dev/pts/0
USER     CMD          PID FD MOUNT      INUM MODE         SZ|DV R/W
alice    tcsh       45120  0 /dev         97 crw--w----  pts/0 rw
alice    tcsh       45120  1 /dev         97 crw--w----  pts/0 rw
alice    tcsh       45120  2 /dev         97 crw--w----  pts/0 rw
alice    top        45230  0 /dev         97 crw--w----  pts/0 rw
```

#### Preguntas de comprensión — Lab 1

1. En la salida de `w`, el usuario `alice` muestra un tiempo de IDLE de `2` minutos mientras ejecuta `top -a`. ¿Cómo determina `w` que `alice` ha estado inactiva durante 2 minutos a pesar de que `top` actualiza activamente la pantalla de la terminal?
2. Si `sockstat` muestra una conexión SSH para el usuario `bob` (PID `48199`), pero `who` no muestra ninguna sesión correspondiente en ningún dispositivo `pts`, ¿qué disparidad de estado en la base de datos del sistema ha ocurrido y qué fallo de proceso causa esto?

---

### Lab 2: Auditoría del historial de inicio de sesión y contabilidad de sesiones de usuario (`last`, `lastcomm`, `ac`)

En este laboratorio, extraerá registros históricos de inicio de sesión, rastreará la ejecución de comandos pasados mediante contabilidad de procesos (process accounting) y agregará el total de horas de conexión de los usuarios.

#### Comandos ejecutables:

```bash
# Step 1: Query the historical login database (/var/log/utx.log) for user `alice`
last -n 5 alice

# Step 2: Determine reboot history and system shutdowns logged in session database
last -n 5 reboot shutdown

# Step 3: Enable process accounting on the accounting storage device
accton /var/account/acct

# Step 4: Display command execution history for user `bob` using `lastcomm`
lastcomm --user bob

# Step 5: Calculate cumulative connect time per user in hours using `ac`
ac -p
```

#### Salidas de comandos reales:

```console
$ last -n 5 alice
alice    pts/0    192.168.1.105    Thu Aug  6 14:22   still logged in
alice    pts/2    192.168.1.105    Wed Aug  5 09:12 - 17:45  (08:32)
alice    pts/0    192.168.1.105    Tue Aug  4 10:00 - 12:30  (02:30)

utx.log begins Tue Aug  4 10:00:00 UTC 2026

$ last -n 5 reboot shutdown
reboot   ~                         Thu Aug  6 12:00
shutdown ~                         Thu Aug  6 11:58
reboot   ~                         Mon Aug  3 08:00

utx.log begins Mon Aug  3 08:00:00 UTC 2026

$ lastcomm --user bob
command           user     tty            cpu time start time
vim               bob      pts/1      0.04 secs Thu Aug  6 15:10
grep              bob      pts/1      0.01 secs Thu Aug  6 15:08
cat               bob      pts/1      0.00 secs Thu Aug  6 15:05

$ ac -p
	alice                               11.03
	bob                                  0.33
	total       11.36
```

#### Preguntas de comprensión — Lab 2

1. Si un administrador del sistema ejecuta `last -f /var/log/utx.log.0`, ¿qué escenario operativo específico requiere pasar la flag `-f` y cómo analiza `last` los registros binarios de forma diferente a los archivos de texto plano como `/var/log/messages`?
2. ¿Cómo calcula `ac -p` el total de horas de conexión? Si el usuario `alice` abre tres conexiones SSH simultáneas durante 1 hora cada una, ¿cuántas horas en total agregará `ac -p` al recuento contable de `alice`?

---

### Lab 3: Diagnóstico binario de bajo nivel e inspección de sesiones (Análisis de la estructura `utx`)

En este laboratorio, realizará una inspección binaria del archivo `/var/run/utx.active` para verificar la integridad estructural e identificar entradas de inicio de sesión obsoletas.

#### Comandos ejecutables:

```bash
# Step 1: Verify system log file path and permissions for active utx database
ls -la /var/run/utx.active /var/log/utx.log

# Step 2: Use `hexdump` to inspect raw binary bytes of the first record in `/var/run/utx.active`
hexdump -C -n 300 /var/run/utx.active

# Step 3: Search for ASCII strings inside the binary session record file to extract remote hosts
strings /var/run/utx.active | grep -E 'pts/|[0-9]{1,3}\.[0-9]{1,3}'
```

#### Salidas de comandos reales:

```console
$ ls -la /var/run/utx.active /var/log/utx.log
-rw-r--r--  1 root  wheel   600 Aug  6 15:10 /var/run/utx.active
-rw-r--r--  1 root  wheel  4200 Aug  6 15:10 /var/log/utx.log

$ hexdump -C -n 300 /var/run/utx.active
00000000  07 00 00 00 86 32 55 68  00 00 00 00 70 74 73 2f  |.....2Uh....pts/|
00000010  30 00 00 00 00 00 00 00  00 00 00 00 61 6c 69 63  |0...........alic|
00000020  65 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |e...............|
00000030  00 00 00 00 00 00 00 00  00 00 00 00 31 39 32 2e  |............192.|
00000040  31 36 38 2e 31 2e 31 30  35 00 00 00 00 00 00 00  |168.1.105.......|

$ strings /var/run/utx.active | grep -E 'pts/|[0-9]{1,3}\.[0-9]{1,3}'
pts/0
alice
192.168.1.105
pts/1
bob
192.168.1.110
```

#### Preguntas de comprensión — Lab 3

1. En el volcado hexadecimal de `/var/run/utx.active`, los primeros cuatro bytes son `07 00 00 00`. ¿Qué campo de `struct utmpx` representa este valor y qué significa el valor numérico `7` (`USER_PROCESS`) para las herramientas de seguimiento de inicio de sesión?
2. Si una conexión SSH se interrumpe abruptamente debido a una caída de red (omitiendo el intercambio de paquetes TCP FIN/RST), ¿por qué `hexdump` o `who` podrían continuar reportando al usuario en `/var/run/utx.active`? ¿Qué parámetro de configuración del demonio SSH mitiga esta fuga de estado de sesión?

---

### Lab 4: Mensajería entre sesiones y terminación forzada de sesiones (`mesg`, `write`, `wall`, `pkill`)

En este laboratorio, gestionará los permisos de mensajes de sesión, ejecutará mensajería dirigida a usuarios, transmitirá alertas del sistema y terminará sesiones de usuario que no responden.

#### Comandos ejecutables:

```bash
# Step 1: Check terminal write permission state using `mesg`
mesg

# Step 2: Disable incoming terminal messages on current session
mesg n

# Step 3: Broadcast an administrative message to all active user sessions
wall "SYSTEM MAINTENANCE ALERT: Server rebooting in 15 minutes. Save your work."

# Step 4: Locate process tree and session PID for user `bob` using `pgrep`
pgrep -l -u bob -s $(pgrep -f "sshd: bob")

# Step 5: Forcefully terminate all session processes belonging to user `bob`
pkill -9 -u bob
```

#### Salidas de comandos reales:

```console
$ mesg
is y

$ mesg n

$ mesg
is n

$ wall "SYSTEM MAINTENANCE ALERT: Server rebooting in 15 minutes. Save your work."
Broadcast Message from root@bsd-node-01 on pts/0 (Thu Aug  6 15:35:00 2026)...
SYSTEM MAINTENANCE ALERT: Server rebooting in 15 minutes. Save your work.

$ pgrep -l -u bob
48199 sshd
48201 tcsh
48255 vim

$ pkill -9 -u bob
```

#### Preguntas de comprensión — Lab 4

1. ¿Cómo restringe técnicamente el comando `mesg n` que otros usuarios que no sean root escriban en una terminal a través de `write(1)` o `wall(1)`? ¿Qué modificación subyacente de permisos del sistema de archivos ocurre en `/dev/pts/X`?
2. ¿Cuál es la distinción operativa entre ejecutar `pkill -9 -u bob` frente a la terminación dirigida de un grupo de procesos mediante `kill -TERM -- -PGID`? ¿Por qué matar solo al líder de sesión de la shell de inicio de sesión (`-PID`) es generalmente más seguro en entornos de producción?

---

## 4. Referencias oficiales y enlaces a la documentación

*   **Descripción general de la certificación LPI BSD Specialist:**  
    [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
*   **Manual de funciones de la biblioteca FreeBSD `utmpx(3)`:**  
    [https://man.freebsd.org/cgi/man.cgi?query=utmpx&sektion=3](https://man.freebsd.org/cgi/man.cgi?query=utmpx&sektion=3)
*   **Manual del comando FreeBSD `w(1)`:**  
    [https://man.freebsd.org/cgi/man.cgi?query=w&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=w&sektion=1)
*   **Manual de auditoría del sistema FreeBSD `last(1)`:**  
    [https://man.freebsd.org/cgi/man.cgi?query=last&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=last&sektion=1)
*   **Manual de contabilidad del tiempo de conexión FreeBSD `ac(8)`:**  
    [https://man.freebsd.org/cgi/man.cgi?query=ac&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=ac&sektion=8)
*   **Manual de contabilidad de usuario OpenBSD `who(1)`:**  
    [https://man.openbsd.org/who.1](https://man.openbsd.org/who.1)

---

## 5. Respuestas de verificación y explicaciones técnicas

<details>
<summary><strong>Haga clic aquí para expandir las soluciones de los Labs 1 al 4</strong></summary>

### Soluciones del Lab 1

1.  **Mecánica del tiempo de inactividad en `w(1)`:**  
    El comando `w` determina el tiempo de inactividad del usuario inspeccionando la marca de tiempo de acceso al archivo (`st_atime`) del dispositivo de caracteres correspondiente a la terminal de control del usuario (por ejemplo, `/dev/pts/0`). Aunque `top` escribe continuamente datos en stdout, actualizando el tiempo de modificación del dispositivo (`st_mtime`), *no* lee entradas desde stdin (`st_atime`). Dado que `alice` no ha escrito en el teclado durante 2 minutos, `st_atime` permanece sin cambios y `w` reporta correctamente un tiempo de IDLE de 2 minutos.
2.  **Disparidades en la base de datos de sesiones:**  
    Este estado ocurre cuando un proceso demonio SSH (`sshd`) autentica una conexión y crea un proceso hijo (fork de proceso trabajador), pero no logra registrar una entrada en `/var/run/utx.active` a través de `pututxline(3)`. Esto sucede si una configuración de sesión PAM a la que le falta `pam_lastlog.so` o `pam_permit.so` se aborta prematuramente, si `sshd` está configurado con `UseLogin yes` de forma incorrecta, o si se solicita un subsistema SSH no interactivo personalizado (por ejemplo, una sesión exclusiva de SFTP o de reenvío de puertos sin asignación de TTY).

---

### Soluciones del Lab 2

1.  **Lectura de archivos de contabilidad alternativos con `last -f`:**  
    La flag `-f` indica a `last` que analice un archivo de registro histórico específico (como archivos rotados/archivados como `/var/log/utx.log.0` o `/var/log/wtmp.1.gz`) en lugar del predeterminado `/var/log/utx.log`. `last` no puede leer archivos de log en ASCII plano (como `/var/log/messages`); espera una secuencia de estructuras binarias en C de tamaño fijo (`struct utmpx` o `struct utmp`). Lee el archivo registro por registro, decodificando la marca de tiempo binaria, la línea de terminal, el tipo de proceso y los campos de nombre de usuario.
2.  **Cálculo de contabilidad de conexión en `ac -p`:**  
    `ac` escanea los pares de registros de inicio de sesión (`USER_PROCESS`) y cierre de sesión (`DEAD_PROCESS`) en `/var/log/utx.log`. El tiempo de conexión se calcula como `(logout_timestamp - login_timestamp)`. Si el usuario `alice` abre tres sesiones SSH interactivas simultáneas que permanecen activas durante 1 hora de reloj cada una, `ac -p` agrega la duración de las tres sesiones de línea discretas, reportando un total acumulado de **3.00 horas de conexión**.

---

### Soluciones del Lab 3

1.  **Decodificación hexadecimal de `ut_type`:**  
    Los primeros 4 bytes (`07 00 00 00` en formato de entero de 32 bits little-endian) representan el campo `ut_type` de `struct utmpx`. El valor entero `7` corresponde a la constante `USER_PROCESS`. Esto indica a las herramientas de seguimiento del sistema (`who`, `w`, `getutxent`) que el registro representa una sesión activa y autenticada de un humano o servicio que ocupa una terminal, en lugar de un evento de inicio del sistema (`BOOT_TIME` = 2) o un proceso terminado (`DEAD_PROCESS` = 8).
2.  **Fuga de sesión TCP y mitigación de SSH Keep-Alive:**  
    Cuando una conexión de red de un cliente cae abruptamente sin enviar una trama TCP `FIN` o `RST`, el kernel del servidor remoto conserva el socket en estado establecido (established state). En consecuencia, el árbol de procesos de la sesión se mantiene vivo y ninguna rutina de limpieza (`endutxent()`) escribe un registro `DEAD_PROCESS` en `/var/run/utx.active`. Para evitar fugas de sesión, configure `/etc/ssh/sshd_config` con:
    ```ini
    ClientAliveInterval 300
    ClientAliveCountMax 3
    ```
    Esto le indica a `sshd` que envíe paquetes de prueba (null probe) cifrados cada 300 segundos. Si el cliente no responde durante 3 veces consecutivas, `sshd` termina el árbol de procesos y limpia el registro de sesión activa en `utx.active`.

---

### Soluciones del Lab 4

1.  **Mecanismo de bajo nivel de `mesg n`:**  
    Ejecutar `mesg n` altera los bits de modo de permiso de archivo del dispositivo de caracteres asociado con la terminal de control actual del usuario (por ejemplo, `/dev/pts/0`). Las asignaciones de terminal estándar establecen el modo `0620` (`crw--w----`), permitiendo que los procesos cuyo propietario sea el grupo `tty` escriban la salida en el dispositivo. `mesg n` quita los permisos de escritura del grupo, cambiando el modo del archivo a `0600` (`crw-------`). Como resultado, los intentos por parte de `write` o `wall` (que se ejecutan con credenciales no privilegiadas distintas de root) de abrir `/dev/pts/0` para escritura fallan con `EACCES` (Permiso denegado).
2.  **Estrategias de terminación de procesos:**  
    Ejecutar `pkill -9 -u bob` envía una señal `SIGKILL` no capturable a cada proceso propiedad del usuario `bob`. Esto termina los procesos inmediatamente, pero evita que las shells de inicio de sesión ejecuten manejadores de limpieza (como guardar archivos de historial de la shell `.bash_history` / `.history`, cerrar bloqueos de bases de datos o ejecutar rutinas de reinicio de terminal).  
    Apuntar al líder de sesión con `kill -TERM -- -PGID` o terminar el PID de la shell de inicio de sesión permite que el proceso de la shell maneje `SIGTERM`, transmita de forma limpia `SIGHUP` a los grupos de procesos hijos, ejecute scripts de cierre de sesión (`.logout`), actualice la base de datos `utmpx` a través de APIs de POSIX y cierre limpiamente los dispositivos de pseudoterminal.

</details>