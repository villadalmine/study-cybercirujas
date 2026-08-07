# LPI BSD Specialist (Examen 702-100) — Tema 715.3: Create, Monitor and Kill Processes

**Peso:** 5  
**Certificación Objetivo:** LPI BSD Specialist (Examen 702-100, Versión 1.0)  
**Material de Referencia:** [LPI BSD Specialist Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/) | [FreeBSD Manual Pages (Section 1 & 8)](https://man.freebsd.org/)

---

## 1. Fundamentos Arquitectónicos y Teóricos

### 1.1 El Ciclo de Vida de los Procesos en BSD y la Mecánica del Kernel
En los sistemas operativos BSD (como FreeBSD, OpenBSD y NetBSD), un proceso se representa internamente mediante `struct proc` y se gestiona a través de las interfaces del subsistema del kernel (`sysctl kern.proc`). La creación y gestión de procesos se basan en varias llamadas al sistema (syscalls) y conceptos fundamentales:

*   **Creación de Procesos (`fork(2)`, `vfork(2)`, `rfork(2)`, `execve(2)`):**
    *   `fork(2)` duplica el proceso que realiza la llamada, creando una copia exacta del proceso hijo a través de tablas de páginas Copy-On-Write (COW).
    *   `vfork(2)` crea un proceso hijo mientras toma prestado el espacio de memoria del padre y suspende al padre hasta que se llama a `execve` o `_exit` (evitando la sobrecarga de copiar tablas de páginas).
    *   `rfork(2)` (específico de BSD) permite un compartido granular de tablas de descriptores de archivos, espacio de memoria virtual y manejadores de señales entre hilos/procesos padre e hijo.
    *   `execve(2)` reemplaza la imagen de memoria del proceso con una nueva imagen binaria ejecutable.
*   **Finalización y Cosecha de Procesos ("Reaping") (`exit(2)`, `wait4(2)`):**
    *   Cuando un proceso finaliza a través de `_exit(2)`, sus recursos del kernel (descriptores de archivos, mapas de memoria) son reclamados, pero su entrada `struct proc` persiste en estado **Zombie** (estado `Z` en `ps`) hasta que su padre ejecuta `wait4(2)` para recolectar su estado de salida.
    *   Si un proceso padre finaliza antes que su hijo, el hijo es adoptado por `init` (PID 1), el cual recolecta automáticamente los zombies huérfanos.
*   **Grupos de Procesos, Sesiones y TTYs:**
    *   Un **Process Group** es una colección de procesos asociados con un Process Group ID (`PGID`), creado mediante `setpgid(2)`. Las señales enviadas a un PID negativo (ej., `kill -9 -PGID`) impactan a cada proceso del grupo.
    *   Una **Session** (`SID`) es una colección de grupos de procesos gestionados por un Session Leader (creado mediante `setsid(2)`), típicamente vinculado a una Controlling Terminal (`tty`). Los daemons llaman a `setsid(2)` para desvincularse de su terminal de control.

```
       +-------------------------------------------------------------------+
       |                       Parent Process (PID P)                      |
       +-------------------------------------------------------------------+
                                         |
                                  fork() / rfork()
                                         v
       +-------------------------------------------------------------------+
       |                       Child Process (PID C)                       |
       |  - Shares or copies address space / file descriptors              |
       |  - Belongs to Process Group (PGID) and Session (SID)              |
       +-------------------------------------------------------------------+
                    |                                  |
               execve(bin)                         exit(code)
                    v                                  v
       +-------------------------+        +--------------------------------+
       |   New Executable Image  |        |    Zombie State (Z in ps)      |
       +-------------------------+        |  Struct proc retained until    |
                                          |  Parent calls wait4(code)      |
                                          +--------------------------------+
```

### 1.2 Captura de Señales y Mecánica de Entrega del Kernel
Las señales son notificaciones asíncronas entregadas por el kernel de FreeBSD a un hilo de proceso.
*   **Señales no capturables:** `SIGKILL` (señal 9) y `SIGSTOP` (señal 19) no pueden ser capturadas, ignoradas ni bloqueadas por una aplicación en el espacio de usuario (user-space). El kernel finaliza o suspende de inmediato el target thread frame.
*   **Señales principales capturables:** `SIGHUP` (1), `SIGINT` (2), `SIGQUIT` (3), `SIGTERM` (15), `SIGUSR1` (30), `SIGUSR2` (31), `SIGALRM` (14), `SIGCHLD` (20), `SIGCONT` (18).
*   **Enmascaramiento de Señales en FreeBSD:** Los hilos utilizan `sigprocmask(2)` para bloquear señales temporalmente. Las señales bloqueadas permanecen en estado pendiente en la cola de señales del kernel hasta que son desbloqueadas.

### 1.3 Subsistemas de Monitoreo de Procesos en FreeBSD
A diferencia de los entornos Linux que dependen en gran medida de pseudo-archivos de sistemas como `/proc`, FreeBSD moderno gestiona la introspección de procesos principalmente a través de interfaces MIB del kernel `sysctl(3)` de alto rendimiento (`kern.proc.*`) y suites de utilidades nativas (`procstat(1)`, `ps(1)`, `top(1)`).
*   **`procstat(1)`:** Consulta directamente las estructuras del kernel para inspeccionar los descriptores de archivos del proceso (`-f`), mapas de memoria virtual (`-v`), stacks del kernel de hilos (`-k`), disposiciones de señales (`-i`), variables de entorno (`-e`) y credenciales de seguridad (`-c`).
*   **FreeBSD `killall(1)` vs. Linux/Solaris `killall(1)`:** En FreeBSD, `killall` coincide con los procesos por el nombre de la imagen ejecutable. *(Distinción crucial para SRE: En sistemas System V / Solaris, `killall` finaliza todos los procesos activos del sistema. FreeBSD `killall` opera de forma segura por el nombre del proceso objetivo).*

---

## 2. Ejercicios Prácticos Guiados de Producción

### Ejercicio 1: Control de Trabajos, Demonización y Aislamiento de Procesos en Subshell

#### Escenario
Como Ingeniero de Sistemas, necesitas ejecutar procesos en segundo plano (background), controlar los estados de suspensión/reanudación de trabajos (job control), inspeccionar contextos de ejecución de subshell y verificar el aislamiento de grupos de procesos al desvincular cargas de trabajo.

#### Pasos de Ejecución

1. Iniciar un proceso inofensivo en segundo plano de larga duración utilizando la sintaxis de control de trabajos:
```bash
sleep 3600 &
```
*Salida Esperada:*
```text
[1] 84920
```

2. Lanzar un proceso en primer plano (foreground), suspenderlo mediante señales de terminal y ver el estado de la cola de trabajos:
```bash
tail -f /var/log/messages
```
*(Presionar `CTRL+Z` mientras se ejecuta)*

*Salida Esperada:*
```text
^Z
[2]+  Stopped                 tail -f /var/log/messages
```

3. Mostrar los trabajos activos gestionados por la sesión de shell actual:
```bash
jobs -l
```
*Salida Esperada:*
```text
[1]- 84920 Running                 sleep 3600 &
[2]+ 84921 Stopped                 tail -f /var/log/messages
```

4. Reanudar el trabajo `[2]` en segundo plano, luego inspeccionar los atributos del proceso utilizando `ps`:
```bash
bg %2
ps -o pid,pgid,sid,tpgid,stat,command -p 84921
```
*Salida Esperada:*
```text
[2]+ tail -f /var/log/messages &
  PID  PGID   SID TPGID STAT COMMAND
84921 84921 84800 84800 I    tail -f /var/log/messages
```

5. Engendrar (spawn) un proceso aislado y desvinculado en segundo plano dentro de un subshell para prevenir la propagación de `SIGHUP` cuando la shell de control finalice:
```bash
(nohup sleep 7200 > /tmp/nohup_sleep.log 2>&1 &)
ps -auxww | grep "sleep 7200"
```
*Salida Esperada:*
```text
root     85104  0.0  0.1  12840  2420  -  I    21:15    0:00.00 sleep 7200
root     85106  0.0  0.1  12980  2510  0  S+   21:15    0:00.00 grep sleep 7200
```
*(Nota: El proceso `85104` muestra `-` en la columna TTY, lo que demuestra que se desvinculó de la terminal de control).*

#### Preguntas de Verificación — Ejercicio 1
1. **P1.1:** ¿Qué indica un valor de `-` en la columna `TTY` de `ps -aux` con respecto a la arquitectura del proceso?
2. **P1.2:** Si la shell de control recibe un `SIGHUP`, ¿por qué el proceso `85104` generado mediante `(nohup ... &)` permanece activo mientras que el trabajo `[1]` (`sleep 3600 &`) es finalizado?

---

### Ejercicio 2: Inspección Profunda de Procesos con `ps`, `top` y `procstat`

#### Escenario
Un daemon crítico de producción presenta un alto uso de CPU e hilos bloqueados. Debes diagnosticar los canales de espera del kernel de los hilos (`wchan`), diseño de memoria, descriptores de archivos abiertos y asociación con Jail.

#### Pasos de Ejecución

1. Crear un proceso de prueba ligero que realice operaciones periódicas de disco y bucles:
```bash
sh -c 'while true; do date >> /tmp/test_loop.log; sleep 2; done' &
```
*Salida Esperada:*
```text
[1] 85430
```

2. Ejecutar un formateo avanzado de FreeBSD `ps` para mostrar el Jail ID (`jid`), Prioridad (`pri`), Nivel de Nice (`ni`), Estado del Proceso (`stat`), Canal de Espera (`wchan`) y Comando:
```bash
ps -o pid,jid,user,pri,ni,stat,wchan,command -p 85430
```
*Salida Esperada:*
```text
  PID JID USER   PRI NI STAT WCHAN  COMMAND
85430   0 root    24  0 S    nwait  sh -c while true; do date >> /tmp/test_loop.log; sleep 2; done
```

3. Consultar la pila del kernel del hilo del proceso (thread kernel stack) utilizando `procstat`:
```bash
procstat -k 85430
```
*Salida Esperada:*
```text
  PID    TID COMM             TDNAME           KSTACK                       
85430 100412 sh               -                mi_switch sleepq_catch_signals sleepq_wait_sig kern_clock_nanosleep sys_nanosleep amd64_syscall
```

4. Inspeccionar todos los descriptores de archivos abiertos retenidos por el proceso objetivo:
```bash
procstat -f 85430
```
*Salida Esperada:*
```text
  PID COMM               FD ATTR ATFLAGS PD FDNAME
85430 sh text r--- v---  - /bin/sh
85430 sh cdwd r--- v---  - /root
85430 sh root r--- v---  - /
85430 sh    0 r--v r---  - /dev/null
85430 sh    1 r--v w---  - /dev/null
85430 sh    2 r--v w---  - /dev/null
85430 sh    3 r--v -w-a  - /tmp/test_loop.log
```

5. Monitorear la carga interactiva del sistema y ordenar los procesos por la huella de memoria residente en modo batch utilizando FreeBSD `top`:
```bash
top -b -o res -s 1 -n 5
```
*Salida Esperada:*
```text
last pid: 85450;  load averages:  0.08,  0.03,  0.01    up 0+04:12:30  21:20:00
42 processes:  1 running, 41 sleeping
CPU:  0.0% user,  0.0% nice,  0.2% system,  0.0% interrupt, 99.8% idle
Mem: Real 45M/380M act/tot, Shared 12M, Free 3400M

  PID USERNAME    THR PRI NICE   SIZE    RES STATE    TIME    CPU COMMAND
  848 postgres      1  20    0   140M    32M sleep   0:02   0.00% postgres
  712 root          1  20    0    45M    12M select  0:01   0.00% sshd
  891 syslogd       1  20    0  12.5M  3450K select  0:00   0.00% syslogd
85430 root          1  20    0  12.8M  2680K nwait   0:00   0.00% sh
```

#### Preguntas de Verificación — Ejercicio 2
1. **P2.1:** En la salida de `procstat -k`, ¿qué detalle operativo proporciona el kernel backtrace a un SRE?
2. **P2.2:** ¿Qué representa la letra de estado `S` en la columna `STAT` de `ps`, y en qué se diferencia del estado `D`?

---

### Ejercicio 3: Finalización de Procesos de Precisión, Captura de Señales y Grupos de Procesos

#### Escenario
Un clúster de procesos worker con mal comportamiento debe ser apagado de forma limpia (gracefully), capturado o finalizado de forma forzada utilizando herramientas de gestión de señales (`kill`, `pkill`, `killall`).

#### Pasos de Ejecución

1. Crear un script de shell POSIX que intercepte (`trap`) las señales de finalización para realizar una limpieza antes de salir:
```bash
cat << 'EOF' > /tmp/traptest.sh
#!/bin/sh
trap 'echo "[$(date)] Caught SIGTERM! Cleaning up..."; rm -f /tmp/lockfile.lock; exit 0' TERM
trap 'echo "[$(date)] Caught SIGHUP! Reloading config..."' HUP

touch /tmp/lockfile.lock
echo "Process PID $$ started. Lockfile created."

while true; do
    sleep 1
done
EOF
chmod +x /tmp/traptest.sh
/tmp/traptest.sh > /tmp/trap.log 2>&1 &
```
*Salida Esperada:*
```text
[1] 85810
```

2. Inspeccionar la tabla de disposición de señales para el proceso en ejecución utilizando `procstat`:
```bash
procstat -i 85810
```
*Salida Esperada:*
```text
  PID COMM             SIG SIGNAME          DELIVERY
85810 traptest.sh        1 HUP              catch   
85810 traptest.sh       15 TERM             catch   
```

3. Enviar una señal no destructiva `SIGHUP` para recargar la configuración apuntando al nombre del proceso:
```bash
pkill -HUP -f traptest.sh
cat /tmp/trap.log
```
*Salida Esperada:*
```text
Process PID 85810 started. Lockfile created.
[Thu Aug  6 21:25:01 EDT 2026] Caught SIGHUP! Reloading config...
```

4. Emitir un `SIGTERM` limpio utilizando `kill`:
```bash
kill -TERM 85810
cat /tmp/trap.log
ls -l /tmp/lockfile.lock
```
*Salida Esperada:*
```text
Process PID 85810 started. Lockfile created.
[Thu Aug  6 21:25:01 EDT 2026] Caught SIGHUP! Reloading config...
[Thu Aug  6 21:25:10 EDT 2026] Caught SIGTERM! Cleaning up...
ls: /tmp/lockfile.lock: No such file or directory
```

5. Generar tres procesos worker idénticos en segundo plano y emitir un comando `killall` detallado (verbose):
```bash
sleep 4000 & sleep 4000 & sleep 4000 &
killall -v -TERM sleep
```
*Salida Esperada:*
```text
kill -TERM 86012
kill -TERM 86013
kill -TERM 86014
```

#### Preguntas de Verificación — Ejercicio 3
1. **P3.1:** Si un proceso se encuentra atrapado en estado `D` (Uninterruptible Disk I/O Wait), ¿qué sucede si emites `kill -9 <PID>`?
2. **P3.2:** ¿Cuál es el riesgo técnico al ejecutar `killall sleep` en Solaris frente a FreeBSD?

---

### Ejercicio 4: Planificación en Tiempo Real, Prioridades y Límites de Recursos RACCT/RCTL

#### Escenario
Debes ajustar las prioridades de ejecución de procesos (`nice`, `renice`), asignar planificación de hilos en tiempo real (`rtprio`) y aplicar reglas modernas de control de recursos de FreeBSD (`rctl`) para prevenir ataques de agotamiento de recursos.

#### Pasos de Ejecución

1. Lanzar una carga de trabajo de cálculo con alto uso de CPU a una prioridad más baja (valor nice más alto):
```bash
nice -n 15 sha256 /dev/zero &
```
*Salida Esperada:*
```text
[1] 86320
```

2. Verificar el nivel de nice y la puntuación de prioridad mediante `ps`:
```bash
ps -o pid,user,pri,ni,stat,command -p 86320
```
*Salida Esperada:*
```text
  PID USER   PRI NI STAT COMMAND
86320 root    35 15 R+   sha256 /dev/zero
```

3. Alterar la prioridad de un proceso en ejecución dinámicamente usando `renice`:
```bash
renice -n 5 -p 86320
ps -o pid,pri,ni,command -p 86320
```
*Salida Esperada:*
```text
86320 (process ID) old priority 15, new priority 5
  PID PRI NI COMMAND
86320  25  5 sha256 /dev/zero
```

4. Asignar prioridad absoluta de tiempo real (Real-Time) usando FreeBSD `rtprio(1)` (habilita la planificación fija de tiempo real por encima de los hilos de tiempo compartido normales):
```bash
rtprio 10 -p 86320
rtprio 86320
```
*Salida Esperada:*
```text
pid 86320 real time priority 10
```

5. Finalizar el proceso de prueba limitado por CPU:
```bash
kill -9 86320
```

6. Inspeccionar las reglas activas de Límite de Recursos de FreeBSD utilizando `rctl(8)`:
```bash
rctl
```
*Salida Esperada:*
```text
# (If no rules are currently set, returns empty output)
```

7. Aplicar una regla temporal RACCT/RCTL para limitar el uso máximo de memoria para el usuario `nobody` a 100 Megabytes, activando un SIGKILL cuando se sobrepase:
```bash
rctl -a user:nobody:vmemoryuse:deny=100M
rctl user:nobody
```
*Salida Esperada:*
```text
user:nobody:vmemoryuse:deny=104857600
```

8. Eliminar (flush) la regla:
```bash
rctl -r user:nobody:vmemoryuse:deny=100M
```

#### Preguntas de Verificación — Ejercicio 4
1. **P4.1:** ¿Cuál es el rango válido de valores de `nice` en FreeBSD y cómo influye `nice` en la planificación de hilos en comparación con `rtprio`?
2. **P4.2:** ¿Qué característica del sistema debe habilitarse en el kernel de FreeBSD para usar `rctl(8)`?

---

## 3. Soluciones Integrales y Justificación Técnica

<details>
<summary>Haz clic para desplegar las soluciones oficiales y las explicaciones técnicas detalladas</summary>

### Soluciones del Ejercicio 1

*   **Respuesta a P1.1:** Un `-` en la columna `TTY` indica que el proceso **no tiene terminal de control**.
    *   *Justificación Técnica:* Durante la demonización (daemonization), un proceso invoca `setsid(2)`. Esto crea una nueva sesión, establece al proceso como líder de la sesión, lo desvincula del grupo de procesos padre y libera explícitamente la terminal de control (`/dev/tty*`). Esto garantiza que el proceso sea inmune a eventos de cierre de terminal o señales de colgado de consola (`SIGHUP`).
*   **Respuesta a P1.2:** La construcción de subshell `(nohup ... &)` desvincula los manejadores de señales y reasigna stdin/stdout. `nohup(1)` establece explícitamente la acción para `SIGHUP` en `SIG_IGN` (Ignorar). Cuando la shell padre finaliza y envía `SIGHUP` a todos los trabajos en su grupo de sesión, `sleep 7200` ignora la señal y continúa ejecutándose bajo la adopción del PID 1.

---

### Soluciones del Ejercicio 2

*   **Respuesta a P2.1:** `procstat -k` muestra la **pila de ejecución del hilo en el kernel (backtrace)** para cada hilo del proceso objetivo.
    *   *Justificación Técnica:* En la salida (`mi_switch sleepq_catch_signals sleepq_wait_sig kern_clock_nanosleep sys_nanosleep amd64_syscall`), el backtrace revela que el hilo se está ejecutando actualmente dentro de la cola de suspensión del kernel (`sleepq`), esperando una interrupción de reloj de temporizador (`nanosleep`). Esto le indica exactamente a un SRE por qué está bloqueado un proceso (ej., esperando bloqueos mutex, I/O de disco, selección de socket de red o temporizadores de suspensión) sin requerir un depurador como `gdb`.
*   **Respuesta a P2.2:** 
    *   El estado **`S`** representa **Interruptible Sleep**: El proceso está durmiendo, esperando un evento (como la finalización de I/O, un temporizador o entrada por terminal), pero se despertará de inmediato para procesar las señales entrantes del sistema.
    *   El estado **`D`** representa **Uninterruptible Disk/Kernel Sleep**: El proceso está esperando I/O de hardware de bajo nivel o bloqueos críticos de páginas del kernel. Mientras esté en estado `D`, el proceso **no** se despertará para procesar señales, incluyendo `SIGKILL`.

---

### Soluciones del Ejercicio 3

*   **Respuesta a P3.1:** El proceso **no** se finalizará de inmediato.
    *   *Justificación Técnica:* `kill -9` envía un `SIGKILL` no capturable a la máscara de señales pendientes del proceso en el espacio del kernel. Sin embargo, un hilo en estado `D` (Uninterruptible Sleep) está ejecutando rutinas críticas a nivel de kernel donde despertar prematuramente podría corromper la memoria del kernel o las estructuras de datos del sistema de archivos. El kernel pospone el procesamiento de la señal hasta que el hilo del controlador termine la operación de bloqueo y salga del estado `D`.
*   **Respuesta a P3.2:** 
    *   En **FreeBSD**, `killall` finaliza de forma segura los procesos que coincidan con la **cadena del nombre** especificada (ej., `killall sleep` finaliza los procesos que ejecutan la imagen binaria `sleep`).
    *   En **Solaris / System V UNIX**, `killall` finaliza **TODOS los procesos activos en el sistema** (utilizado durante el apagado del sistema). Ejecutar `killall` en Solaris sin argumentos o cualificadores de procesos derribará de inmediato el sistema operativo.

---

### Soluciones del Ejercicio 4

*   **Respuesta a P4.1:** 
    *   El rango de `nice` en FreeBSD abarca desde **`-20`** (mayor prioridad de ejecución) hasta **`+20`** (menor prioridad de ejecución), siendo **`0`** el valor por defecto. Los usuarios que no son root solo pueden aumentar los valores de nice (menor prioridad).
    *   Mientras que `nice` altera las prioridades dinámicas dentro del planificador estándar de tiempo compartido SCHED_ULE / SCHED_4BSD, **`rtprio`** asigna una **Prioridad en Tiempo Real** fija. Un hilo al que se le asigna prioridad en tiempo real a través de `rtprio` se antepone (pre-empts) a los hilos estándar de tiempo compartido sin importar sus valores de nice.
*   **Respuesta a P4.2:** El kernel de FreeBSD debe tener compilados o cargados como módulo del kernel la **Contabilidad de Recursos (`RACCT`)** y los **Límites de Recursos (`RCTL`)** (`kern.racct.enable=1` configurado en `/boot/loader.conf`).

</details>

---

## 4. Resumen de Referencia de Comandos Clave para el Examen

| Herramienta / Comando | Ejemplo de Sintaxis Objetivo en FreeBSD | Función de SRE en Producción |
| :--- | :--- | :--- |
| `ps` | `ps -auxww -O jid,pri,ni,wchan` | Introspeccionar procesos, sesiones de terminal, canales de espera e IDs de jail. |
| `top` | `top -b -o res -s 1` | Monitoreo del sistema en tiempo real, ordenamiento de recursos de CPU/Memoria en modo batch no interactivo. |
| `procstat` | `procstat -k <PID>` / `procstat -f <PID>` | Inspección detallada del kernel de BSD (backtrace de la pila de hilos del kernel, descriptores de archivos abiertos). |
| `pkill` | `pkill -HUP -f "nginx"` | Entrega de señales apuntando a patrones de coincidencia en la línea de comandos del proceso. |
| `killall` | `killall -v -TERM process_name` | Finalizar todos los procesos que coincidan exactamente con el nombre del ejecutable binario. |
| `nice` / `renice` | `nice -n 10 <cmd>` / `renice +5 <PID>` | Modificar la prioridad de planificación de procesos estándar dentro de colas dinámicas de tiempo compartido. |
| `rtprio` | `rtprio 15 -p <PID>` | Consultar o establecer prioridades fijas de planificación de hilos en tiempo real en FreeBSD. |
| `rctl` | `rctl -a user:www:vmemoryuse:deny=500M` | Establecer límites de recursos de kernel de grano fino utilizando reglas RACCT/RCTL de FreeBSD. |