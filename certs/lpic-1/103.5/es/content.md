# 103.5 — Crear, monitorear y matar procesos

**Certificación:** LPIC-1 (Exámenes 101-500 / 102-500, versión 5.0)
**Peso del tema:** 6.25
**Perfil:** Principal Platform Architect / Senior SRE
**Prerrequisitos:** 103.1 (shell y línea de comandos), 103.2 (filtros de texto), 103.4 (streams, pipes, redirecciones)
**Tema adyacente:** 103.6 (`nice`, `renice`, prioridades de planificación) — deliberadamente fuera de alcance acá

---

## 1. Motivación: el problema arquitectónico

Todo postmortem de incidente que vayas a escribir sobre una plataforma Linux se reduce, tarde o temprano, a uno de cuatro hechos a nivel de proceso:

1. **Un proceso que tendría que haber muerto no murió.** Se entregó un `SIGTERM`, la aplicación nunca instaló un handler, el orquestador esperó a que venciera el período de gracia, y `SIGKILL` truncó una escritura en vuelo. La base de datos ahora perdió los últimos 3 segundos de un segmento de WAL.
2. **Un proceso que tendría que haber vivido no vivió.** Se cayó una sesión SSH, se colgó la terminal, el kernel entregó `SIGHUP` al grupo de procesos en primer plano, y una migración de datos de 6 horas murió en la hora 5. Nadie usó `nohup`, `setsid`, `tmux` ni — la respuesta correcta — una unidad de `systemd`.
3. **Un proceso está vivo pero sin rendir cuentas.** El PID 1 en un contenedor es una shell que nunca hace reap de sus hijos, así que `ps` muestra 40.000 zombis y el pod llega al límite del cgroup `pids`. Los hilos nuevos fallan con `EAGAIN` y el readiness probe empieza a oscilar.
4. **Un proceso no está ni vivo ni muerto.** Está en estado `D` — sueño ininterrumpible sobre un montaje NFS colgado o una cola NVMe estancada — y `kill -9` no hace absolutamente nada, porque no queda código de espacio de usuario al que interrumpir.

La idea que unifica todo esto es la siguiente: **en Linux, "kill" es un nombre equivocado.** `kill(2)` no termina nada. Entrega una señal — una notificación asincrónica — y el *proceso receptor* decide qué pasa después, salvo que la señal sea una de las dos que el kernel se niega a dejar que intercepte (`SIGKILL`, `SIGSTOP`). La gestión del ciclo de vida de procesos es, por lo tanto, un **contrato** entre tres partes:

```
  supervisor  ──signal──▶  process  ──exit status──▶  supervisor
  (systemd,        │           │                          │
   kubelet,        │           └── handler? default?      │
   shell)          │               ignored? blocked?      │
                   └───────── grace period timer ─────────┘
                                     │
                              expiry ▼
                              SIGKILL (non-negotiable)
```

Un SRE que solo entiende "`kill -9` hace que pare" va a construir sistemas que pierden datos durante la operación normal. Este tema es donde ese hábito se corrige.

### Lo que está en juego en producción, concretamente

| Falla | Causa raíz en la capa de procesos | Radio de impacto |
|---|---|---|
| Escrituras truncadas durante un rolling deploy | La app ignora `SIGTERM`; k8s escala a `SIGKILL` a los 30 s | Corrupción de datos, silenciosa |
| 502 durante 30 s en cada deploy | La app sale ante `SIGTERM` *antes* de que el endpoint se saque del Service | Errores visibles para el usuario, en cada release |
| El contenedor llena la tabla de PIDs | Una shell como PID 1 no hace `wait()` sobre sus hijos → zombis | El pod queda no planificable; agotamiento de PIDs del nodo |
| La migración muere a las 05:00 | El job corrió en una login shell; el hangup de la terminal entregó `SIGHUP` | Horas de retrabajo, ventana de mantenimiento perdida |
| El nodo "se cuelga" pero la CPU está ociosa | Tareas atascadas en estado `D` sobre almacenamiento muerto; load average = 300 | Nodo entero indepurable con las herramientas normales |
| `kill -9` sobre un cliente NFS trabado no hace nada | El estado `D` no es interrumpible; la señal se encola y nunca se entrega | Requiere remediación en la capa de almacenamiento o reboot |

---

## 2. Mecánica de procesos: qué mantiene realmente el kernel

### 2.1 Creación — `fork()` / `execve()` / `wait()`

Linux no tiene una primitiva de "crear un programa nuevo". Tiene:

- **`fork(2)`** (en la práctica `clone(2)`) — duplica el proceso llamador. Espacio de direcciones copy-on-write, tabla de descriptores de archivo duplicada, mismas credenciales. Devuelve `0` en el hijo y el PID del hijo en el padre.
- **`execve(2)`** — reemplaza la imagen del proceso actual por un programa nuevo. **El PID no cambia.** Los FDs abiertos sobreviven salvo que estén marcados con `FD_CLOEXEC`. Los *handlers* de señales se resetean a su valor por defecto; las *disposiciones* de señal fijadas en `SIG_IGN` se preservan (así es exactamente como funciona `nohup`).
- **`_exit(2)`** — termina, dejando un estado de salida en la estructura de tarea del kernel.
- **`wait(2)` / `waitpid(2)`** — el padre recolecta ese estado. Hasta que lo hace, el hijo es un **zombi** (`Z`): sin memoria, sin código, apenas un PID y 8 bits de estado de salida retenidos para el padre.

```
  parent                     child
    │
    ├── fork() ──────────────▶ (copy of parent)
    │                            │
    │                            ├── execve("/usr/bin/foo")
    │                            │       (same PID, new image)
    │                            │
    │                            └── _exit(0)  ──▶ becomes Z (zombie)
    │                                                  │
    └── waitpid() ◀──── exit status ───────────────────┘
                        (zombie reaped, PID freed)
```

**Consecuencia arquitectónica:** un zombi no es una fuga de memoria, es una fuga de *slots del namespace de PIDs*. Tanto `/proc/sys/kernel/pid_max` (por defecto 4194304 en kernels modernos, 32768 históricamente) como el `pids.max` del cgroup son finitos. Un proceso que hace fork y nunca hace wait los va a agotar.

**Manejo de huérfanos:** si un padre sale antes que sus hijos, los hijos son re-emparentados — históricamente al PID 1, desde Linux 3.4 al ancestro más cercano marcado como **child subreaper** (`prctl(PR_SET_CHILD_SUBREAPER)`), que es lo que usan `systemd --user` y los runtimes de contenedores. El reaper debe llamar a `wait()`. Esta es la única razón por la que existen `tini` y `dumb-init`.

### 2.2 Estados de proceso según los reportan `ps` / `top`

| Código | Estado del kernel | ¿Matable? | Causa típica |
|---|---|---|---|
| `R` | Ejecutándose o ejecutable (en una run queue) | Sí | Consumiendo CPU activamente o esperando un turno |
| `S` | Sueño interrumpible | Sí | Esperando un socket, un timer o un `poll()`; el estado ocioso normal |
| `D` | Sueño **ininterrumpible** | **No** | E/S bloqueante: NFS muerto, dispositivo de bloques estancado, algunos `ioctl` |
| `Z` | Zombi / defunct | **No — ya está muerto** | El padre no hizo `wait()` |
| `T` | Detenido por una señal de control de trabajos | Sí (después de `SIGCONT`) | `SIGSTOP`, `SIGTSTP`, `SIGTTIN`, `SIGTTOU` |
| `t` | Detenido por un depurador durante el trace | Sí | Attach de `ptrace` (`gdb`, `strace`) |
| `I` | Hilo de kernel ocioso (Linux ≥ 4.14) | N/A | Worker del kernel sin nada que hacer |
| `X` | Muerto | N/A | Transitorio; nunca debería observarse |

Flags modificadores que agrega `ps`:

| Flag | Significado |
|---|---|
| `<` | Prioridad alta (nice negativo) |
| `N` | Prioridad baja (nice positivo) |
| `L` | Tiene páginas bloqueadas en memoria (tiempo real / mlock) |
| `s` | **Líder de sesión** |
| `l` | Multihilo (usa `clone`) |
| `+` | En el **grupo de procesos en primer plano** de su terminal de control |

El flag `+` es el que importa para el control de trabajos: exactamente un grupo de procesos por terminal puede leer de ella, y ese es el grupo en primer plano.

### 2.3 Sesiones, grupos de procesos y terminales de control

Esta jerarquía es el sustrato de todo lo que viene en la sección 3.

```
  SESSION (SID = PID of session leader, e.g. the login shell)
   │  controlling terminal: /dev/pts/3
   │
   ├── PROCESS GROUP 4210 (foreground, has terminal read access)  ← "+"
   │     ├── PID 4210  tar
   │     └── PID 4211  gzip           (a pipeline is ONE process group)
   │
   ├── PROCESS GROUP 4198 (background, running)
   │     └── PID 4198  rsync
   │
   └── PROCESS GROUP 4185 (background, stopped)
         └── PID 4185  vim
```

Inspeccionalo directamente:

```
$ ps -eo pid,ppid,pgid,sid,tty,stat,comm --sort=sid | grep -E 'pts/3|PID'
    PID    PPID    PGID     SID TT       STAT COMMAND
   4102    4099    4102    4102 pts/3    Ss   bash
   4185    4102    4185    4102 pts/3    T    vim
   4198    4102    4198    4102 pts/3    S    rsync
   4210    4102    4210    4102 pts/3    S+   tar
   4211    4102    4210    4102 pts/3    S+   gzip
```

Leé eso con atención: `tar` y `gzip` comparten `PGID 4210` porque son un solo pipeline; `bash` tiene `SID == PID == PGID` y el flag `s` porque es el líder de sesión; solo el PGID 4210 lleva `+`.

**Por qué importa:** `kill -TERM -4210` (notá el menos) le manda la señal a *todo el grupo de procesos*. Las señales generadas por la terminal — `Ctrl-C`, `Ctrl-Z`, `Ctrl-\` — las entrega el driver de la terminal a todo el grupo de procesos en primer plano, que es la razón por la que `Ctrl-C` sobre un pipeline mata todas sus etapas.

---

## 3. Control de trabajos: `&`, `jobs`, `fg`, `bg`

El control de trabajos es una **funcionalidad de la shell**, no del kernel. El kernel provee grupos de procesos y `tcsetpgrp(3)`; `bash` construye la abstracción de cara al usuario sobre eso.

### 3.1 Las primitivas

```
$ sleep 300 &
[1] 5821

$ tar -czf /backup/srv.tar.gz /srv &
[2] 5834

$ jobs
[1]-  Running                 sleep 300 &
[2]+  Running                 tar -czf /backup/srv.tar.gz /srv &

$ jobs -l
[1]- 5821 Running                 sleep 300 &
[2]+ 5834 Running                 tar -czf /backup/srv.tar.gz /srv &

$ jobs -p
5821
5834
```

`+` marca el **trabajo actual** (sobre el que actúan `fg` / `bg` sin argumentos, también `%%` o `%+`); `-` marca el **trabajo anterior** (`%-`).

Suspender un trabajo en primer plano y reanudarlo en segundo plano:

```
$ ping -i 5 10.0.0.1
PING 10.0.0.1 (10.0.0.1) 56(84) bytes of data.
64 bytes from 10.0.0.1: icmp_seq=1 ttl=64 time=0.412 ms
64 bytes from 10.0.0.1: icmp_seq=2 ttl=64 time=0.398 ms
^Z
[3]+  Stopped                 ping -i 5 10.0.0.1

$ bg %3
[3]+ ping -i 5 10.0.0.1 &

$ jobs
[1]   Running                 sleep 300 &
[2]-  Running                 tar -czf /backup/srv.tar.gz /srv &
[3]+  Running                 ping -i 5 10.0.0.1 &

$ fg %2
tar -czf /backup/srv.tar.gz /srv
```

Lo que hizo `Ctrl-Z` en realidad: el driver de la terminal envió `SIGTSTP` (20) al grupo de procesos en primer plano. Lo que hizo `bg`: envió `SIGCONT` (18) a ese grupo *sin* llamar a `tcsetpgrp()`, así que el grupo corre pero ya no es el grupo en primer plano. Lo que hizo `fg`: llamó a `tcsetpgrp()` para devolverle la terminal, y después envió `SIGCONT`.

### 3.2 Especificaciones de trabajo

| Especificación | Selecciona |
|---|---|
| `%1` | El trabajo número 1 |
| `%%` o `%+` | El trabajo actual |
| `%-` | El trabajo anterior |
| `%tar` | El trabajo cuyo comando **empieza con** `tar` |
| `%?backup` | El trabajo cuyo comando **contiene** `backup` |

Funcionan con los builtins de la shell `fg`, `bg`, `wait`, `disown` y — esto es importante — con el builtin `kill`:

```
$ kill -TERM %2
$ jobs
[2]+  Terminated              tar -czf /backup/srv.tar.gz /srv
```

`/bin/kill` **no** entiende `%2`; solo el builtin.

### 3.3 La trampa de la escritura en segundo plano

Un trabajo en segundo plano puede escribir libremente en la terminal, pero si *lee* de la terminal recibe `SIGTTIN` y se detiene. Si está activo `stty tostop`, escribir también lo detiene con `SIGTTOU`.

```
$ cat > /tmp/notes.txt &
[1] 6102

$ jobs
[1]+  Stopped (tty input)     cat > /tmp/notes.txt

$ ps -o pid,stat,comm -p 6102
    PID STAT COMMAND
   6102 T    cat
```

**Lectura del SRE:** cualquier trabajo en segundo plano que misteriosamente entra en `T` y nunca avanza casi siempre está bloqueado en `SIGTTIN` — quiere stdin. En automatización, redirigí siempre: `cmd < /dev/null &`.

### 3.4 `wait` — la pieza faltante en la orquestación con shell

```bash
#!/usr/bin/env bash
set -euo pipefail

# Fan out three independent backups, then reconcile.
pids=()

for host in db-01 db-02 db-03; do
    pg_dumpall -h "$host" -f "/backup/${host}.sql" < /dev/null &
    pids+=("$!")          # $! = PID of the most recent background job
done

failed=0
for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
        printf 'backup pid %s failed with status %d\n' "$pid" "$?" >&2
        failed=1
    fi
done

exit "$failed"
```

`$!` y `wait` son la forma en que un script de shell se convierte en un supervisor. Sin `wait`, el script sale, los hijos quedan huérfanos y re-emparentados, y tu estado de salida es una mentira.

---

## 4. Señales: la referencia completa

### 4.1 La tabla estándar de señales (Linux, x86-64 / ARM / la mayoría de las arquitecturas)

| # | Nombre | Acción por defecto | ¿Capturable? | Significado típico |
|---|---|---|---|---|
| 1 | `SIGHUP` | Terminar | Sí | Hangup de la terminal; **por convención: recargar configuración** |
| 2 | `SIGINT` | Terminar | Sí | `Ctrl-C` — interrupción interactiva |
| 3 | `SIGQUIT` | Terminar + **core dump** | Sí | `Ctrl-\` — también vuelca stacks de Java/Go |
| 4 | `SIGILL` | Terminar + core | Sí | Instrucción ilegal |
| 5 | `SIGTRAP` | Terminar + core | Sí | Breakpoint (depuradores) |
| 6 | `SIGABRT` | Terminar + core | Sí | `abort(3)`, aserción fallida |
| 7 | `SIGBUS` | Terminar + core | Sí | Alineación de acceso a memoria incorrecta / `mmap` truncado |
| 8 | `SIGFPE` | Terminar + core | Sí | Error aritmético (división entera por cero) |
| **9** | **`SIGKILL`** | **Terminar** | **NO** | Muerte incondicional por parte del kernel |
| 10 | `SIGUSR1` | Terminar | Sí | Definida por la aplicación (nginx: reabrir logs) |
| 11 | `SIGSEGV` | Terminar + core | Sí | Referencia de memoria inválida |
| 12 | `SIGUSR2` | Terminar | Sí | Definida por la aplicación (nginx: actualizar binario) |
| 13 | `SIGPIPE` | Terminar | Sí | Escritura en un pipe sin lector |
| 14 | `SIGALRM` | Terminar | Sí | Venció el timer de `alarm(2)` |
| **15** | **`SIGTERM`** | **Terminar** | **Sí** | **Apagado cortés — el valor por defecto de `kill`** |
| 16 | `SIGSTKFLT` | Terminar | Sí | Falla de stack del coprocesador (sin uso) |
| 17 | `SIGCHLD` | **Ignorar** | Sí | Un hijo se detuvo o terminó |
| 18 | `SIGCONT` | Continuar | Sí | Reanudar un proceso detenido |
| **19** | **`SIGSTOP`** | **Detener** | **NO** | Suspensión incondicional |
| 20 | `SIGTSTP` | Detener | Sí | `Ctrl-Z` — parada desde la terminal |
| 21 | `SIGTTIN` | Detener | Sí | Proceso en segundo plano leyó de la terminal |
| 22 | `SIGTTOU` | Detener | Sí | Proceso en segundo plano escribió en la terminal (`stty tostop`) |
| 23 | `SIGURG` | Ignorar | Sí | Datos fuera de banda en un socket |
| 24 | `SIGXCPU` | Terminar + core | Sí | Límite de tiempo de CPU excedido (`RLIMIT_CPU`) |
| 25 | `SIGXFSZ` | Terminar + core | Sí | Límite de tamaño de archivo excedido (`RLIMIT_FSIZE`) |
| 26 | `SIGVTALRM` | Terminar | Sí | Venció el timer virtual |
| 27 | `SIGPROF` | Terminar | Sí | Venció el timer de profiling |
| 28 | `SIGWINCH` | Ignorar | Sí | Se redimensionó la ventana de la terminal |
| 29 | `SIGIO`/`SIGPOLL` | Terminar | Sí | E/S asincrónica lista |
| 30 | `SIGPWR` | Terminar | Sí | Falla de energía (demonios de UPS) |
| 31 | `SIGSYS` | Terminar + core | Sí | Llamada al sistema inválida (**violaciones de seccomp**) |
| 34–64 | `SIGRTMIN`..`SIGRTMAX` | Terminar | Sí | Señales de tiempo real; se encolan, no se fusionan |

```
$ kill -l
 1) SIGHUP       2) SIGINT       3) SIGQUIT      4) SIGILL       5) SIGTRAP
 6) SIGABRT      7) SIGBUS       8) SIGFPE       9) SIGKILL     10) SIGUSR1
11) SIGSEGV     12) SIGUSR2     13) SIGPIPE     14) SIGALRM     15) SIGTERM
16) SIGSTKFLT   17) SIGCHLD     18) SIGCONT     19) SIGSTOP     20) SIGTSTP
21) SIGTTIN     22) SIGTTOU     23) SIGURG      24) SIGXCPU     25) SIGXFSZ
26) SIGVTALRM   27) SIGPROF     28) SIGWINCH    29) SIGIO       30) SIGPWR
31) SIGSYS      34) SIGRTMIN    35) SIGRTMIN+1  36) SIGRTMIN+2  37) SIGRTMIN+3
...
63) SIGRTMAX-1  64) SIGRTMAX

$ kill -l 15
TERM

$ kill -l TERM
15
```

> **Advertencia de portabilidad que aparece en los exámenes y en herramientas multiplataforma reales:** los *números* de señal del 1 al 15, excluyendo los específicos de la arquitectura, son estables, pero `SIGUSR1`/`SIGUSR2` son **10/12 en x86-64, ARM y la mayoría de los ports de Linux, 16/17 en MIPS, y 30/31 en Alpha/SPARC**. Nunca hardcodees números en scripts portables — usá nombres. `kill -HUP`, `kill -s HUP` y `kill -1` son equivalentes solo en x86-64.

### 4.2 Bloqueadas, ignoradas, pendientes — leyendo las máscaras

```
$ grep -E '^Sig|^Name|^State' /proc/1/status
Name:   systemd
State:  S (sleeping)
SigQ:   0/62481
SigPnd: 0000000000000000
SigBlk: 7be3c0fe28014a03
SigIgn: 0000000000001000
SigCgt: 00000001800004ec
```

Decodificá con `bc` o, más prácticamente:

```
$ awk '/^SigCgt/ {print $2}' /proc/1/status | \
    xargs -I{} python3 -c "
import sys
m=int('{}',16)
names={1:'HUP',2:'INT',3:'QUIT',6:'ABRT',10:'USR1',12:'USR2',13:'PIPE',15:'TERM',17:'CHLD',
       18:'CONT',28:'WINCH',29:'IO',30:'PWR',31:'SYS'}
print('caught:', [names.get(i,i) for i in range(1,65) if m>>(i-1)&1])"
caught: ['HUP', 'INT', 'ABRT', 'USR1', 'USR2', 'CHLD', 'PWR', 'SYS']
```

| Campo | Significado | Uso diagnóstico |
|---|---|---|
| `SigPnd` | Pendientes para **este hilo** | Distinto de cero + estado `D` ⇒ señal encolada pero no entregable |
| `ShdPnd` | Pendientes para todo el **grupo de hilos** | Lo mismo, a nivel de proceso |
| `SigBlk` | Actualmente **bloqueadas** (`sigprocmask`) | Explica el "mandé TERM y no pasó nada" |
| `SigIgn` | Fijadas en `SIG_IGN` | `0x…1000` = bit 13 = `SIGPIPE` ignorada (muy común) |
| `SigCgt` | Tiene un **handler** instalado | **Si `SIGTERM` (bit 15) está en 0, la app no tiene apagado ordenado** |

Esta única verificación — "¿aparece el bit 15 en `SigCgt`?" — es la forma más rápida de probar que una aplicación va a perder datos en un reinicio rolling, *antes* del incidente.

### 4.3 `kill` — las tres formas

```
$ kill 5821                     # implicit SIGTERM
$ kill -9 5821                  # by number  (SIGKILL)
$ kill -KILL 5821               # by short name
$ kill -s SIGKILL 5821          # POSIX form, portable
$ kill -TERM -4210              # NEGATIVE pid = entire process GROUP 4210
$ kill -TERM -1                 # every process the caller may signal (DANGEROUS)
$ kill -0 5821 && echo alive    # send NOTHING: pure existence/permission probe
```

`kill -0` es la sonda de vitalidad idiomática en supervisores de shell — hace la verificación de permisos y de existencia, pero no entrega ninguna señal:

```
$ kill -0 1 && echo "PID 1 exists and I may signal it"
-bash: kill: (1) - Operation not permitted
$ echo $?
1
```

`EPERM` (permiso denegado) significa que el proceso **existe**; `ESRCH` (no existe tal proceso) significa que no. Los scripts robustos distinguen los dos casos:

```bash
is_running() {
    kill -0 "$1" 2>/dev/null && return 0
    [[ -d /proc/$1 ]] && return 0      # exists but we lack permission
    return 1
}
```

### 4.4 La escalera de escalado — la única secuencia de kill correcta

```bash
#!/usr/bin/env bash
# terminate <pid> [grace_seconds]
# Escalates TERM -> (grace) -> KILL, reporting which rung was needed.
set -euo pipefail

terminate() {
    local pid=$1 grace=${2:-30} waited=0

    kill -0 "$pid" 2>/dev/null || { echo "pid $pid: not running"; return 0; }

    echo "pid $pid: sending SIGTERM"
    kill -TERM "$pid"

    while kill -0 "$pid" 2>/dev/null; do
        if (( waited >= grace )); then
            echo "pid $pid: grace period of ${grace}s expired, sending SIGKILL" >&2
            kill -KILL "$pid"
            sleep 1
            kill -0 "$pid" 2>/dev/null && {
                echo "pid $pid: SURVIVED SIGKILL - process is in D state" >&2
                cat "/proc/$pid/stack" 2>/dev/null || true
                return 1
            }
            return 2      # non-zero: the app has a shutdown bug worth a ticket
        fi
        sleep 1
        (( waited++ ))
    done

    echo "pid $pid: exited cleanly after ${waited}s"
    return 0
}

terminate "$@"
```

```
$ ./terminate 7431 10
pid 7431: sending SIGTERM
pid 7431: exited cleanly after 3s

$ ./terminate 7502 5
pid 7502: sending SIGTERM
pid 7502: grace period of 5s expired, sending SIGKILL
$ echo $?
2
```

**El código de salida 2 es una señal para el equipo de plataforma, no para el operador.** Hacele seguimiento. Toda aplicación que necesita `SIGKILL` es un futuro incidente de pérdida de datos.

### 4.5 Semántica de señales por convención (memorizá esto)

| Señal | Convención en demonios | Ejemplo |
|---|---|---|
| `SIGHUP` | **Recargar configuración sin reiniciar** | `kill -HUP $(cat /run/nginx.pid)`, `sshd`, `rsyslogd` |
| `SIGUSR1` | Reabrir archivos de log (rotación) | nginx, HAProxy |
| `SIGUSR2` | Actualización del binario / lanzar un master nuevo | actualización sin downtime de nginx |
| `SIGQUIT` | Apagado **ordenado**, drenar conexiones | nginx (¡invertido respecto de `SIGTERM` = apagado rápido!) |
| `SIGTERM` | Apagado ordenado | Casi todo lo demás |
| `SIGWINCH` | Apagado ordenado de workers | nginx |

> **La inversión de nginx es una trampa clásica de producción.** Para nginx, `SIGTERM`/`SIGINT` significan *apagado rápido* (descartar las peticiones en vuelo) y `SIGQUIT` significa *apagado ordenado*. Como Kubernetes y systemd mandan `SIGTERM` por defecto, un pod de nginx sin configurar descarta conexiones en cada deploy. La solución es `STOPSIGNAL SIGQUIT` en el Dockerfile o `KillSignal=SIGQUIT` en la unidad — ambos se muestran en la sección 7.

---

## 5. Sobrevivir al logout: `nohup`, `setsid`, `disown`, `screen`, `tmux`

### 5.1 Qué mata realmente tu trabajo al desloguearte

Dos mecanismos independientes, que se confunden con frecuencia:

1. **El kernel.** Cuando la terminal de control se cuelga (se cae la conexión SSH, se cierra el `pty`), el kernel manda `SIGHUP` al **proceso de control** (el líder de sesión). También manda `SIGHUP` + `SIGCONT` a cualquier **grupo de procesos huérfano** que contenga miembros detenidos.
2. **La shell.** Al salir, `bash` manda `SIGHUP` a todos sus trabajos *solo si* está activada la opción `huponexit` — que está **desactivada por defecto**.

```
$ shopt huponexit
huponexit       off
```

Así que un `exit` limpio de un bash interactivo normalmente *no* mata los trabajos en segundo plano; una sesión SSH *caída* sí, porque se involucra el kernel.

### 5.2 Los cuatro mecanismos, comparados

| Mecanismo | Qué cambia | Sobrevive al hangup | Sobrevive a la salida de la shell | Reconectable | Captura de salida |
|---|---|---|---|---|---|
| `cmd &` | Nada — misma sesión, PG en segundo plano | ❌ | ⚠️ solo si `huponexit` está off | ❌ | Terminal (se pierde) |
| `disown -h %1` | Marca el trabajo: la shell no manda `SIGHUP` | ⚠️ el kernel igual puede mandar HUP | ✅ | ❌ | Terminal (se pierde) |
| `nohup cmd &` | Fija la disposición de `SIGHUP` en `SIG_IGN`; redirige stdout a `nohup.out` | ✅ | ✅ | ❌ | `nohup.out` |
| `setsid cmd` | **Sesión nueva, sin terminal de control** | ✅ (no hay tty que colgar) | ✅ | ❌ | Adonde se redirija |
| `screen` / `tmux` | Corre dentro de un demonio desacoplado con su propio pty | ✅ | ✅ | ✅ | Buffer de scrollback |
| **`systemd-run` / unidad** | Proceso propiedad del PID 1, cgroup propio, logging propio | ✅ | ✅ | ✅ (`journalctl`) | **journald** |

### 5.3 `nohup` en la práctica

```
$ nohup ./import-catalog.sh &
[1] 8123
nohup: ignoring input and appending output to 'nohup.out'

$ cat /proc/8123/status | grep SigIgn
SigIgn: 0000000000000001
```

Bit 1 activado = `SIGHUP` ignorada. Eso es literalmente todo lo que hace `nohup`, más la redirección. Notá que `nohup` **no** se desacopla de la sesión, así que `ps` sigue mostrando el SID original.

La redirección explícita es mejor práctica que dejar que escriba `nohup.out` en `$PWD`:

```
$ nohup ./import-catalog.sh > /var/log/import.log 2>&1 < /dev/null &
[1] 8140

$ ps -o pid,ppid,pgid,sid,tty,stat,cmd -p 8140
    PID    PPID    PGID     SID TT       STAT CMD
   8140    4102    8140    4102 pts/3    S    /bin/bash ./import-catalog.sh
```

Sigue en `pts/3`, sigue con SID 4102 — sigue conectado, apenas sordo a `SIGHUP`.

### 5.4 `setsid` — desacople real

```
$ setsid ./import-catalog.sh > /var/log/import.log 2>&1 < /dev/null

$ pgrep -af import-catalog
8199 /bin/bash ./import-catalog.sh

$ ps -o pid,ppid,pgid,sid,tty,stat,cmd -p 8199
    PID    PPID    PGID     SID TT       STAT CMD
   8199       1    8199    8199 ?        Ss   /bin/bash ./import-catalog.sh
```

`TT` es `?` (sin terminal de control), `PPID` es 1 (re-emparentado), `SID == PID` (nuevo líder de sesión), `STAT` muestra `s`. **Esto es un demonio genuino.** No hay terminal que colgar, así que `SIGHUP` nunca llega.

### 5.5 `disown`

```
$ long-running-job &
[1] 8250

$ disown -h %1        # keep in job table, but do not send SIGHUP
$ jobs
[1]+  Running                 long-running-job &

$ disown %1           # remove from job table entirely
$ jobs
$ 
```

| Forma | Efecto |
|---|---|
| `disown %1` | Saca el trabajo 1 de la tabla de trabajos de la shell |
| `disown -h %1` | Mantiene el trabajo listado pero lo marca como "no mandar `SIGHUP`" |
| `disown -a` | Todos los trabajos |
| `disown -r` | Solo los trabajos en ejecución |

`disown` es un `nohup` **retroactivo**: usalo cuando te olvidaste. No puede re-emparentar ni crear una sesión nueva, así que una caída dura de SSH todavía puede tumbar el trabajo si es el proceso de control.

### 5.6 `screen`

```
$ screen -S migration
# ... inside the screen session ...
$ ./migrate-schema.sh
# detach with Ctrl-a d
[detached from 9014.migration]

$ screen -ls
There is a screen on:
        9014.migration  (08/26/2026 09:14:22 AM)        (Detached)
1 Socket in /run/screen/S-sre.

$ screen -r migration
```

| Tecla / comando | Acción |
|---|---|
| `screen -S <name>` | Iniciar una sesión con nombre |
| `Ctrl-a d` | Desacoplar |
| `screen -ls` | Listar sesiones |
| `screen -r <name>` | Reconectar |
| `screen -d -r <name>` | Desacoplar en el otro lado y conectar acá (robar) |
| `screen -x <name>` | **Multiconexión** — dos operadores comparten una terminal |
| `Ctrl-a c` | Ventana nueva |
| `Ctrl-a "` | Lista de ventanas |
| `Ctrl-a A` | Renombrar la ventana |
| `Ctrl-a [` | Modo copia/scrollback |

### 5.7 `tmux`

```
$ tmux new -s migration
# detach with Ctrl-b d
[detached (from session migration)]

$ tmux ls
migration: 1 windows (created Wed Aug 26 09:20:11 2026) [190x48]

$ tmux attach -t migration

$ tmux new-session -d -s batch 'pg_restore -d prod /backup/prod.dump'
$ tmux ls
batch: 1 windows (created Wed Aug 26 09:22:03 2026)
migration: 1 windows (created Wed Aug 26 09:20:11 2026)
```

| `screen` | `tmux` | Acción |
|---|---|---|
| `Ctrl-a d` | `Ctrl-b d` | Desacoplar |
| `screen -ls` | `tmux ls` | Listar sesiones |
| `screen -r` | `tmux attach -t` | Reconectar |
| `Ctrl-a c` | `Ctrl-b c` | Ventana nueva |
| `Ctrl-a S` / `Ctrl-a |` | `Ctrl-b "` / `Ctrl-b %` | Dividir panel |
| `screen -x` | `tmux attach` (compartido por defecto) | Multiconexión |
| `screen -S x -X quit` | `tmux kill-session -t x` | Destruir |

**Nota arquitectónica:** `screen` y `tmux` son herramientas de *operador*, no de *producción*. Una sesión de `tmux` es invisible para el gestor de servicios, no produce logs estructurados, no tiene política de reinicio, ni límites de recursos, y muere con el nodo. Usalos para acompañar una migración puntual; nunca para correr un servicio.

### 5.8 La respuesta de producción: `systemd-run`

```
$ systemd-run --unit=catalog-import \
    --description="One-shot catalog import" \
    --property=Type=oneshot \
    --property=TimeoutStopSec=300 \
    --collect \
    /usr/local/bin/import-catalog.sh
Running as unit: catalog-import.service

$ systemctl status catalog-import.service
● catalog-import.service - One-shot catalog import
     Loaded: loaded (/run/systemd/transient/catalog-import.service; transient)
  Transient: yes
     Active: active (running) since Wed 2026-08-26 09:31:04 UTC; 12s ago
   Main PID: 9302 (import-catalog.)
      Tasks: 3 (limit: 18942)
     Memory: 41.2M
        CPU: 8.114s
     CGroup: /system.slice/catalog-import.service
             ├─9302 /bin/bash /usr/local/bin/import-catalog.sh
             ├─9318 psql -h db-01 -f /srv/catalog/schema.sql
             └─9319 tee /var/log/catalog-import.log

$ journalctl -u catalog-import.service -f
```

Esto sobrevive al logout, tiene política ante reboot, tiene un cgroup, tiene logs estructurados, tiene un timeout de parada y puede matarse como unidad con `systemctl kill`. Compará:

| Propiedad | `nohup &` | `tmux` | `systemd-run` |
|---|---|---|---|
| Sobrevive al logout | ✅ | ✅ | ✅ |
| Sobrevive al reboot del nodo (reinicio) | ❌ | ❌ | ✅ (con `Restart=`) |
| Logs estructurados y consultables | ❌ | ❌ | ✅ journald |
| Límites de recursos (cgroup) | ❌ | ❌ | ✅ |
| Mata todo el árbol de procesos | ❌ | ⚠️ | ✅ `KillMode=control-group` |
| Estado de salida registrado | ❌ | ❌ | ✅ |
| TTY interactivo reconectable | ❌ | ✅ | ⚠️ (`--pty`) |

---

## 6. Monitoreo: `ps`, `top`, `free`, `uptime`, `watch`, `pgrep`

### 6.1 `ps` — tres sintaxis incompatibles en un solo binario

`ps` en Linux (procps-ng) acepta opciones **UNIX** (`-e`), opciones **BSD** (`aux`, sin guion) y opciones **largas GNU** (`--sort`). Mezclarlas cambia el significado de las letras.

| Invocación | Estilo | Significado |
|---|---|---|
| `ps -e` | UNIX | Todos los procesos |
| `ps -ef` | UNIX | Todos los procesos, formato completo |
| `ps aux` | BSD | Todos los procesos con tty + todos los usuarios + procesos sin tty |
| `ps -aux` | **Ambiguo** | Estilo UNIX: procesos del usuario `x`… procps avisa y hace fallback |
| `ps axjf` | BSD | Formato de control de trabajos, en árbol |
| `ps -eLf` | UNIX | Todos los **hilos** (`L`) |
| `ps -eo …` | UNIX | Columnas de salida personalizadas |

```
$ ps aux | head -6
USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root           1  0.0  0.1 168720 13104 ?        Ss   Aug20   0:31 /sbin/init
root           2  0.0  0.0      0     0 ?        S    Aug20   0:00 [kthreadd]
root          15  0.0  0.0      0     0 ?        I<   Aug20   0:00 [rcu_gp]
postgres    1842  1.2  8.4 2418516 686340 ?      Ss   Aug20  84:11 /usr/lib/postgresql/16/bin/postgres
www-data    2311  0.3  0.6 142208 52104 ?        S    Aug20  12:44 nginx: worker process
```

```
$ ps -ef | head -6
UID          PID    PPID  C STIME TTY          TIME CMD
root           1       0  0 Aug20 ?        00:00:31 /sbin/init
root           2       0  0 Aug20 ?        00:00:00 [kthreadd]
postgres    1842    1839  1 Aug20 ?        01:24:11 /usr/lib/postgresql/16/bin/postgres
www-data    2311    2309  0 Aug20 ?        00:12:44 nginx: worker process
```

| Columna de `ps aux` | Columna de `ps -ef` | Interpretación |
|---|---|---|
| `%CPU` | `C` | `aux` = promedio de toda la vida del proceso; `-ef` = factor entero de utilización del planificador |
| `VSZ` | — | Tamaño virtual (KiB) — incluye mapeos sin respaldo; **no** es memoria usada |
| `RSS` | — | Conjunto residente (KiB) — páginas físicas, **cuenta dos veces las páginas compartidas** |
| `STAT` | — | Estado + flags (sección 2.2) |
| `START`/`STIME` | | Hora o fecha de inicio |
| `TIME` | `TIME` | Tiempo de CPU acumulado |

> **Ni `VSZ` ni `RSS` son "memoria usada".** `RSS` cuenta las bibliotecas compartidas una vez por proceso; sumar `RSS` sobre una flota de workers forkeados sobrecuenta por gigabytes. Usá `PSS` de `/proc/<pid>/smaps_rollup` (o `smem`) para una cifra proporcional. Este malentendido genera la mayoría de los tickets de "por qué mi nodo se queda sin memoria si `ps` dice que hay 4 GB libres".

**La salida personalizada es donde `ps` se convierte en una herramienta de SRE:**

```
$ ps -eo pid,ppid,user,pcpu,pmem,rss,nlwp,stat,wchan:20,etimes,cmd --sort=-pcpu | head -8
    PID    PPID USER     %CPU %MEM   RSS NLWP STAT WCHAN                ETIMES CMD
   4471    1842 postgres 94.3  3.1 254112    1 R    -                     18422 postgres: prod app 10.0.2.14(51422) SELECT
   2311    2309 www-data 12.6  0.6  52104   17 S    ep_poll               518711 nginx: worker process
   9012       1 root      4.1  1.2  98440    9 S    futex_wait_queue_me     3204 /usr/bin/containerd
   1842    1839 postgres  1.2  8.4 686340    1 S    epoll_wait            518744 /usr/lib/postgresql/16/bin/postgres
```

| Columna | Por qué la pide un SRE |
|---|---|
| `nlwp` | Cantidad de hilos — la creación descontrolada de hilos aparece acá primero |
| `wchan` | **Función del kernel en la que está durmiendo la tarea** — la mejor pista de estado `D` |
| `etimes` | Segundos transcurridos (ordenable por máquina, a diferencia de `etime`) |
| `pmem` / `rss` | Atribución de presión de memoria |
| `stat` | Estado + flag `+` de primer plano |
| `cgroup` | Qué unidad / contenedor es su dueño |

Ordenamiento y selección:

```
$ ps -eo pid,user,rss,cmd --sort=-rss | head -5          # top memory consumers
$ ps -eo pid,etimes,cmd --sort=-etimes | head -5         # oldest processes
$ ps -u postgres -o pid,stat,cmd                          # by user
$ ps -C nginx -o pid,ppid,stat,cmd                        # by command name
$ ps -p 1842 -o pid,cgroup --no-headers                   # which cgroup owns it
1842 0::/system.slice/postgresql@16-main.service
```

El árbol de procesos:

```
$ ps axjf | head -20
   PPID     PID    PGID     SID TTY       TPGID STAT   UID   TIME COMMAND
      0       1       1       1 ?            -1 Ss       0   0:31 /sbin/init
      1     892     892     892 ?            -1 Ss       0   0:04 /usr/sbin/sshd -D
    892    4098    4098    4098 ?            -1 Ss       0   0:00  \_ sshd: sre [priv]
   4098    4101    4098    4098 ?            -1 S     1000   0:00      \_ sshd: sre@pts/3
   4101    4102    4102    4102 pts/3      4210 Ss    1000   0:00          \_ -bash
   4102    4210    4210    4102 pts/3      4210 S+    1000   0:02              \_ tar -czf /backup/srv.tar.gz /srv
   4210    4211    4210    4102 pts/3      4210 S+    1000   0:11              \_ gzip
```

`TPGID` es el grupo de procesos en primer plano de la terminal — 4210 acá, coincidiendo con el flag `+`. Alternativa: `pstree -p 4102`.

Hilos:

```
$ ps -eLo pid,tid,nlwp,pcpu,stat,comm -p 2311
    PID     TID NLWP %CPU STAT COMMAND
   2311    2311   17  0.4 Sl   nginx
   2311    2315   17  0.1 Sl   nginx
   2311    2316   17  0.1 Sl   nginx
...
```

`PID == TID` para el líder del grupo de hilos; el resto son LWPs que comparten el espacio de direcciones.

### 6.2 `top` — la base interactiva

```
$ top
top - 09:47:31 up 6 days,  2:14,  3 users,  load average: 4.82, 3.91, 2.44
Tasks: 428 total,   3 running, 424 sleeping,   0 stopped,   1 zombie
%Cpu(s): 38.4 us, 11.2 sy,  0.0 ni, 41.1 id,  8.9 wa,  0.0 hi,  0.4 si,  0.0 st
MiB Mem :   7960.4 total,    412.8 free,   5104.2 used,   2443.4 buff/cache
MiB Swap:   2048.0 total,   1621.3 free,    426.7 used.   2381.9 avail Mem

    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
   4471 postgres  20   0 2418516 254112  18104 R  94.3   3.1  18:22.14 postgres
   2311 www-data  20   0  142208  52104   9880 S  12.6   0.6  12:44.02 nginx
   9012 root      20   0 1874320  98440  42116 S   4.1   1.2   3:12.88 containerd
      1 root      20   0  168720  13104   8420 S   0.0   0.1   0:31.02 systemd
```

**La línea de CPU, campo por campo — acá empieza el diagnóstico:**

| Campo | Nombre | Significado | Qué indican los valores altos |
|---|---|---|---|
| `us` | user | Espacio de usuario, prioridad normal | Trabajo de CPU de la aplicación |
| `sy` | system | Kernel actuando en nombre de los procesos | Tormenta de syscalls, cambios de contexto, contención de locks |
| `ni` | nice | Espacio de usuario, nice positivo | Trabajos batch (ver 103.6) |
| `id` | idle | Ocioso | — |
| `wa` | **iowait** | Ocioso *mientras* hay E/S pendiente | **El almacenamiento es el cuello de botella** |
| `hi` | IRQ de hardware | Atención de interrupciones de hardware | Presión de interrupciones de NIC/almacenamiento |
| `si` | IRQ de software | Softirq (pila de red) | Cuello de botella en el procesamiento de paquetes |
| `st` | **steal** | La vCPU quería correr, el hipervisor le dio el turno a otro | **Vecino ruidoso / host sobresuscrito** |

> `st` > 5% sostenido en una VM de nube es un problema de infraestructura, no de la aplicación. `wa` alto con `id` bajo significa que la CPU está genuinamente saturada *y* además hay dependencia de E/S. `wa` alto con `us`+`sy` cerca de cero significa que es solo almacenamiento.

**Teclas interactivas que vale la pena memorizar:**

| Tecla | Efecto |
|---|---|
| `h` / `?` | Ayuda |
| `1` | Alternar el desglose por núcleo de CPU |
| `H` | Alternar la vista de **hilos** |
| `M` | Ordenar por memoria (`%MEM`) |
| `P` | Ordenar por CPU (`%CPU`) — por defecto |
| `T` | Ordenar por TIME acumulado |
| `N` | Ordenar por PID |
| `u` | Filtrar por usuario |
| `o` | Expresión de filtrado (ej. `%CPU>10`) |
| `c` | Alternar la línea de comandos completa |
| `V` | Vista de bosque (árbol) |
| `k` | **Mandar una señal a un PID** (pide el PID y después la señal) |
| `r` | **renice** de un PID |
| `e` / `E` | Ciclar unidades de memoria (tarea / resumen) |
| `d` o `s` | Cambiar el retardo de refresco |
| `W` | Escribir la configuración actual en `~/.config/procps/toprc` |
| `q` | Salir |

**Modo batch — cómo entra `top` en la automatización:**

```
$ top -b -n 1 -o %CPU | head -12
$ top -b -n 3 -d 5 -p 4471 | grep -E '^ *4471'
   4471 postgres  20   0 2418516 254112  18104 R  94.3   3.1  18:22.14 postgres
   4471 postgres  20   0 2418516 256880  18104 R  97.1   3.1  18:27.02 postgres
   4471 postgres  20   0 2419540 258104  18104 R  91.8   3.2  18:31.61 postgres
```

| Flag | Significado |
|---|---|
| `-b` | Modo batch — sin curses, seguro para pipes y cron |
| `-n <N>` | Salir después de N iteraciones |
| `-d <sec>` | Retardo entre iteraciones |
| `-p <pid>` | Monitorear PIDs específicos (separados por comas, hasta 20) |
| `-u <user>` | Filtrar por usuario efectivo |
| `-H` | Arrancar en modo hilos |
| `-o <field>` | Campo de ordenamiento |
| `-w 512` | Salida ancha (evita líneas de comando truncadas) |

### 6.3 `ps` vs `top` vs las alternativas

| Herramienta | Modelo | Costo | Mejor para | Limitación |
|---|---|---|---|---|
| `ps` | **Instantánea** | Un solo recorrido de `/proc` | Scripting, inventario puntual, columnas personalizadas | Sin tasas; `%CPU` es un promedio de toda la vida |
| `top` | **Muestreado, repetitivo** | Redibujo curses + recorrido de `/proc` por intervalo | Triage interactivo, "qué está caliente ahora" | Pesado en bucles cerrados; solo por intervalo |
| `htop` | Muestreado, UI más rica | Similar a `top` | Vista de árbol, mouse, barras por núcleo, envío fácil de señales | No viene instalado por defecto; no está en los objetivos de LPIC-1 |
| `pidstat` (sysstat) | **Deltas por intervalo** | Bajo | *Tasas* de CPU/E/S/memoria por proceso a lo largo del tiempo | Paquete aparte |
| `pgrep`/`pidof` | Instantánea, solo PIDs | Mínimo | Scriptear una búsqueda | Sin datos de recursos |
| `/proc/<pid>/*` | Estado crudo del kernel | Mínimo | Cualquier cosa que las herramientas no expongan | Requiere parseo manual |
| `watch` | Re-ejecuta cualquier comando | El costo de ese comando | Convertir una herramienta de instantánea en un monitor | Re-ejecución ingenua; sin historial |

```
$ pidstat -p 4471 -u -r -d 2 3
Linux 6.8.0-45-generic (node-01)  08/26/2026  _x86_64_  (8 CPU)

09:52:10 AM   UID       PID    %usr %system  %guest   %wait    %CPU   CPU  Command
09:52:12 AM   114      4471   71.50   22.50    0.00    1.00   94.00     3  postgres
09:52:14 AM   114      4471   74.00   23.00    0.00    0.50   97.00     3  postgres
09:52:16 AM   114      4471   69.50   22.00    0.00    2.00   91.50     3  postgres
Average:      114      4471   71.67   22.50    0.00    1.17   94.17     -  postgres
```

`%wait` (latencia de run queue) es un dato que `top` no te da.

### 6.4 `free` — y por qué "memoria libre" es la métrica equivocada

```
$ free -h
               total        used        free      shared  buff/cache   available
Mem:            7.8Gi       5.0Gi       402Mi       184Mi       2.4Gi       2.3Gi
Swap:           2.0Gi       416Mi       1.6Gi

$ free -m -w
               total        used        free      shared     buffers       cache   available
Mem:            7960        5104         402         184         212        2231        2381
Swap:           2048         416        1621
```

| Columna | Definición | Significado operativo |
|---|---|---|
| `total` | `MemTotal` | RAM física visible para el kernel |
| `used` | `total - free - buffers - cache` | Genuinamente asignada a procesos |
| `free` | `MemFree` | **RAM sin usar — un valor bajo es normal y saludable** |
| `shared` | `Shmem` (tmpfs, memoria compartida) | El uso de `/dev/shm` y tmpfs cuenta acá |
| `buffers` | Caché de metadatos de dispositivos de bloques | Reclamable |
| `cache` | Caché de páginas + slab reclamable | Reclamable |
| `available` | **Estimación del kernel de memoria asignable sin hacer swap** | **El número sobre el que alertar** |

> **Que `free` esté cerca de cero es el estado estacionario correcto.** Linux usa toda la RAM sobrante como caché de páginas y la reclama a demanda. Alertá sobre `available`, nunca sobre `free`. `available` lo calcula el kernel (`MemAvailable` en `/proc/meminfo`, desde Linux 3.14) y tiene en cuenta la fracción de la caché que *no* es realmente reclamable.

Flags útiles:

| Flag | Efecto |
|---|---|
| `-h` | Legible por humanos, autoescalado |
| `-b` / `-k` / `-m` / `-g` | Bytes / KiB / MiB / GiB |
| `-w` | Ancho: separa `buffers` y `cache` |
| `-t` | Agrega una línea de total (RAM + swap) |
| `-s <sec>` | Repetir cada N segundos |
| `-c <count>` | Con `-s`, detenerse después de N iteraciones |
| `-l` | Mostrar estadísticas de low/high memory |

```
$ free -h -s 2 -c 3
               total        used        free      shared  buff/cache   available
Mem:            7.8Gi       5.0Gi       402Mi       184Mi       2.4Gi       2.3Gi
Swap:           2.0Gi       416Mi       1.6Gi

               total        used        free      shared  buff/cache   available
Mem:            7.8Gi       5.2Gi       288Mi       184Mi       2.3Gi       2.1Gi
Swap:           2.0Gi       418Mi       1.6Gi
...
```

La fuente autoritativa, que `free` apenas formatea:

```
$ head -5 /proc/meminfo
MemTotal:        8151464 kB
MemFree:          412032 kB
MemAvailable:    2438848 kB
Buffers:          217088 kB
Cached:          2284544 kB
```

### 6.5 `uptime` y el load average — el número peor interpretado de Linux

```
$ uptime
 09:47:31 up 6 days,  2:14,  3 users,  load average: 4.82, 3.91, 2.44

$ uptime -p
up 6 days, 2 hours, 14 minutes

$ uptime -s
2026-08-20 07:33:12

$ cat /proc/loadavg
4.82 3.91 2.44 3/428 9482
```

Campos de `/proc/loadavg`: promedios de 1, 5 y 15 minutos; tareas `running/total`; último PID asignado.

**La distinción crítica:** en la mayoría de los UNIX, el load average cuenta las tareas *ejecutables*. **En Linux cuenta las ejecutables (`R`) más las ininterrumpibles (`D`).** Es, por lo tanto, una medida de *demanda sobre el sistema*, no de utilización de CPU.

| Observación | Interpretación |
|---|---|
| Load 4.0 en 8 núcleos, `%Cpu id` = 50% | Saludable: la mitad de la capacidad de CPU en uso |
| Load 40 en 8 núcleos, `%Cpu id` = 95%, `wa` = 0 | **Tareas atascadas en estado `D`.** El almacenamiento o NFS está colgado, no la CPU |
| Load 16 en 8 núcleos, `id` = 0%, `us` = 90% | Saturación genuina de CPU; sobresuscripción 2× |
| 1 min ≫ 15 min | La carga está *subiendo* — incidente en curso |
| 1 min ≪ 15 min | La carga está *bajando* — recuperándose |

Confirmá cuál de los dos casos es contando los estados directamente:

```
$ ps -eo stat --no-headers | cut -c1 | sort | uniq -c | sort -rn
    398 S
     18 I
      6 R
      4 D
      1 Z
```

Cuatro tareas en `D` con load 4.82 y CPUs ociosas es un incidente de almacenamiento, punto.

> El sucesor moderno es **Pressure Stall Information** (Linux ≥ 4.20), que separa los tres recursos en vez de mezclarlos:
> ```
> $ cat /proc/pressure/io
> some avg10=41.22 avg60=38.90 avg300=22.14 total=884215309
> full avg10=29.10 avg60=27.44 avg300=15.02 total=612093118
> ```
> `some` = al menos una tarea estancada; `full` = *todas* las tareas estancadas. No es un objetivo de LPIC-1, pero es sobre lo que realmente deberías estar alertando en producción.

### 6.6 `watch` — convertir cualquier instantánea en un monitor

```
$ watch -n 2 'ps -eo pid,stat,pcpu,rss,comm --sort=-pcpu | head -10'
Every 2.0s: ps -eo pid,stat,pcpu,rss,comm --sort=-pcpu | head -10   node-01: Wed Aug 26 09:58:02 2026

    PID STAT %CPU   RSS COMMAND
   4471 R    94.3 254112 postgres
   2311 S    12.6  52104 nginx
   9012 S     4.1  98440 containerd
```

| Flag | Efecto |
|---|---|
| `-n <sec>` | Intervalo (por defecto 2.0; se permiten fracciones) |
| `-d` | **Resaltar diferencias** entre iteraciones |
| `-d=cumulative` | Resaltar todo lo que *alguna vez* cambió |
| `-t` | Suprimir el encabezado |
| `-g` | **Salir cuando la salida cambia** — convierte `watch` en un disparador |
| `-e` | Salir si el comando devuelve estado distinto de cero |
| `-b` | Beep ante estado distinto de cero |
| `-c` | Interpretar color ANSI |
| `-x` | Pasar el comando a `exec` en vez de a `sh -c` |

Dos patrones de alto valor:

```
# Watch a drain complete, highlighting changes
$ watch -d -n 1 'ss -tan state established "( sport = :443 )" | wc -l'

# Block until a condition flips, then continue the runbook
$ watch -g -n 5 'pgrep -c -f pg_basebackup' ; echo "basebackup finished"
```

**El entrecomillado es el bug clásico de `watch`.** `watch ps aux | grep nginx` canaliza la salida de `watch` hacia `grep` — no observa el pipeline. Entrecomillá siempre: `watch 'ps aux | grep nginx'`.

### 6.7 `pgrep`, `pkill`, `killall`, `pidof`

```
$ pgrep nginx
2309
2311
2312

$ pgrep -a nginx                       # -a / --list-full: show full command line
2309 nginx: master process /usr/sbin/nginx -g daemon on; master_process on;
2311 nginx: worker process
2312 nginx: worker process

$ pgrep -u www-data -l
2311 nginx
2312 nginx

$ pgrep -f 'postgres: prod app'        # -f matches the FULL command line
4471

$ pgrep -x ssh                         # -x: exact match on the process NAME
$ pgrep -x sshd
892

$ pgrep -c nginx                       # count only
3

$ pgrep -P 2309                         # children of PID 2309
2311
2312

$ pgrep -n nginx                        # newest matching
2312
$ pgrep -o nginx                        # oldest matching
2309
```

| Opción | Significado en `pgrep` / `pkill` |
|---|---|
| `-f` | Coincidir contra la **línea de comandos completa**, no solo `comm` |
| `-x` | Exigir una coincidencia **exacta** (sin subcadenas) |
| `-u <user>` | UID efectivo |
| `-U <user>` | UID real |
| `-P <ppid>` | PID del padre |
| `-g <pgid>` / `-s <sid>` | Grupo de procesos / sesión |
| `-t <tty>` | Terminal de control |
| `-n` / `-o` | Solo la coincidencia más nueva / más vieja |
| `-a` | Listar la línea de comandos completa (solo `pgrep`) |
| `-c` | Contar coincidencias (solo `pgrep`) |
| `-l` | Listar el nombre (solo `pgrep`) |
| `--ns <pid>` | Coincidir solo con procesos en los **mismos namespaces** que `<pid>` |
| `-e` | Mostrar a qué se le mandó la señal (solo `pkill`) |
| `-<SIG>` / `--signal <SIG>` | Señal a enviar (solo `pkill`) |

```
$ pkill -HUP -x nginx
$ pkill -e -TERM -u deploy -f 'stale-worker'
stale-worker killed (pid 8811)
stale-worker killed (pid 8812)

$ pkill -9 -f 'java.*batch-import'
```

**`killall` (psmisc) — reglas de coincidencia distintas:**

```
$ killall nginx                        # exact name match, ALL matching processes
$ killall -s HUP nginx
$ killall -v -TERM postgres
Killed postgres(1842) with signal 15

$ killall -r 'python3\.(9|10)'         # -r: regex on the name
$ killall -u deploy                     # all processes of a user
$ killall -o 2h stale-worker            # OLDER than 2 hours
$ killall -y 10m runaway                # YOUNGER than 10 minutes
$ killall -i firefox                    # interactive confirm
Kill firefox(3312) ? (y/N) 
$ killall -w nginx                      # WAIT until they actually die
```

### 6.8 `kill` vs `pkill` vs `killall` — cómo elegir correctamente

| Aspecto | `kill` | `pkill` | `killall` |
|---|---|---|---|
| Paquete | builtin de la shell + coreutils/util-linux | procps-ng | psmisc |
| Selector | PID / PGID / especificación de trabajo | Patrón (nombre o `-f` sobre la cmdline) | **Nombre exacto** (o regex con `-r`) |
| Señal por defecto | `SIGTERM` | `SIGTERM` | `SIGTERM` |
| Coincidencia por subcadena | N/A | **Sí por defecto** (peligroso) | No (exacta) |
| Coincidencia sobre cmdline completa | N/A | `-f` | ❌ no soportado |
| Especificaciones de trabajo (`%1`) | ✅ (solo el builtin) | ❌ | ❌ |
| Grupos de procesos (`-PID`) | ✅ | vía `-g` | ❌ |
| Conciencia de namespaces | N/A | `--ns` | ❌ |
| Esperar la salida | ❌ | ❌ | `-w` |
| Filtros por antigüedad | ❌ | ❌ | `-o` / `-y` |
| **Riesgo de portabilidad** | — | — | **En Solaris, `killall` mata TODOS los procesos** |

> **Dos reglas de producción.**
> 1. `pkill` coincide por **subcadenas** por defecto. `pkill redis` también va a coincidir con `redis-sentinel`, `redis-exporter` y tu `vim redis.conf`. **Hacé siempre una prueba en seco con `pgrep -a` primero**, y preferí `-x` o un patrón `-f` bien anclado.
> 2. `pkill -f` coincide contra la línea de comandos *completa* — **incluyendo los propios argumentos del proceso `pkill` en algunas shells**, y cualquier `grep`/editor que tenga esa cadena. Anclá el patrón: `pkill -f '^/usr/bin/java .*batch-import'`.

El idioma seguro:

```
$ pgrep -a -f 'batch-import'            # 1. INSPECT
8811 /usr/bin/java -Xmx2g -jar /opt/app/batch-import.jar --shard=3
8812 /usr/bin/java -Xmx2g -jar /opt/app/batch-import.jar --shard=4

$ pgrep -c -f 'batch-import'            # 2. COUNT — does it match what you expect?
2

$ pkill -e -TERM -f 'batch-import'      # 3. ACT, with -e to log what was hit
java killed (pid 8811)
java killed (pid 8812)
```

---

## 7. Infraestructura de producción: manifiestos completos

### 7.1 Unidad de systemd — ciclo de vida correcto para un servicio con apagado ordenado

`/etc/systemd/system/catalog-api.service`

```ini
[Unit]
Description=Catalog API (HTTP, graceful shutdown)
Documentation=https://internal.example.com/runbooks/catalog-api
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=notify
NotifyAccess=main
User=catalog
Group=catalog
WorkingDirectory=/opt/catalog-api
ExecStart=/opt/catalog-api/bin/catalog-api --config /etc/catalog-api/config.yaml

# --- Reload without restart: SIGHUP convention -------------------------------
ExecReload=/bin/kill -HUP $MAINPID

# --- Signal / kill policy ----------------------------------------------------
# KillSignal    : first signal sent on stop. SIGTERM is the default; nginx wants SIGQUIT.
# RestartKillSignal : signal used when stopping as part of a restart.
# KillMode      : control-group  -> signal EVERY process in the unit's cgroup (default, correct)
#                 mixed          -> KillSignal to main PID only, SIGKILL to the rest on timeout
#                 process        -> signal ONLY the main PID (leaks children)
#                 none           -> signal nothing (almost always a bug)
# SendSIGHUP    : additionally send SIGHUP after KillSignal (for tty-attached children)
# SendSIGKILL   : escalate to SIGKILL after TimeoutStopSec. Set to no ONLY if you accept hangs.
# TimeoutStopSec: grace period before SIGKILL. MUST exceed the app's worst-case drain time.
# FinalKillSignal: signal used for the final escalation (default SIGKILL).
KillSignal=SIGTERM
KillMode=control-group
SendSIGHUP=no
SendSIGKILL=yes
TimeoutStartSec=30s
TimeoutStopSec=90s
FinalKillSignal=SIGKILL

# --- Restart policy ----------------------------------------------------------
Restart=on-failure
RestartSec=5s
StartLimitIntervalSec=300
StartLimitBurst=5

# --- Resource containment (cgroup v2) ----------------------------------------
# TasksMax caps the pids controller: a fork bomb or a zombie leak is contained
# to this unit instead of exhausting the node's PID space.
TasksMax=512
MemoryMax=2G
MemoryHigh=1800M
CPUQuota=200%
LimitNOFILE=65536
LimitCORE=0
OOMPolicy=stop

# --- Hardening ---------------------------------------------------------------
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/catalog-api /var/log/catalog-api
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

# --- Logging -----------------------------------------------------------------
StandardOutput=journal
StandardError=journal
SyslogIdentifier=catalog-api

[Install]
WantedBy=multi-user.target
```

Operala:

```
$ sudo systemctl daemon-reload
$ sudo systemctl enable --now catalog-api.service

$ systemctl show catalog-api -p KillMode -p KillSignal -p TimeoutStopUSec -p TasksMax
KillMode=control-group
KillSignal=15
TimeoutStopUSec=1min 30s
TasksMax=512

$ systemctl reload catalog-api          # ExecReload -> SIGHUP, no restart
$ systemctl kill --signal=SIGUSR1 catalog-api        # arbitrary signal to the cgroup
$ systemctl kill --kill-whom=main --signal=SIGQUIT catalog-api

$ systemd-cgls -u catalog-api.service
Unit catalog-api.service (/system.slice/catalog-api.service):
├─10241 /opt/catalog-api/bin/catalog-api --config /etc/catalog-api/config.yaml
├─10248 /opt/catalog-api/bin/catalog-worker --queue=default
└─10249 /opt/catalog-api/bin/catalog-worker --queue=priority

$ systemd-cgtop -1
Control Group                     Tasks   %CPU   Memory  Input/s Output/s
/                                   428   62.4     5.1G        -        -
/system.slice                       211   48.1     3.9G        -        -
/system.slice/postgresql@16-main…    38   31.2     1.8G     412K     8.1M
/system.slice/catalog-api.service     3    9.8   412.1M        -        -
```

**Compromisos de `KillMode` — el campo que causa la mayoría de los incidentes de procesos huérfanos:**

| `KillMode` | Señales enviadas a | ¿Deja hijos huérfanos? | Usar cuando |
|---|---|---|---|
| `control-group` (por defecto) | Todos los procesos del cgroup | ❌ No | **Casi siempre lo correcto** |
| `mixed` | `KillSignal` → PID principal; `SIGKILL` → todo el cgroup al vencer el timeout | ❌ No | El proceso principal debe coordinar el apagado de sus propios hijos |
| `process` | Solo el PID principal | ✅ **Sí** | El proceso principal hace reap de su propio árbol de forma demostrable; raro |
| `none` | Nada | ✅ Sí | Shims de contenedores que gestionan su propio ciclo de vida; peligroso |

### 7.2 Kubernetes: PID 1, terminación ordenada y depuración de procesos

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: catalog
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: catalog-api-config
  namespace: catalog
data:
  config.yaml: |
    server:
      listen: "0.0.0.0:8080"
      # Must be shorter than terminationGracePeriodSeconds minus the preStop sleep,
      # or SIGKILL will arrive mid-drain.
      shutdown_timeout: "25s"
    database:
      host: "postgresql.data.svc.cluster.local"
      port: 5432
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog-api
  namespace: catalog
  labels:
    app.kubernetes.io/name: catalog-api
    app.kubernetes.io/component: api
spec:
  replicas: 3
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: catalog-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: catalog-api
        app.kubernetes.io/component: api
    spec:
      # ---------------------------------------------------------------------
      # TERMINATION BUDGET (this is the whole point of the manifest)
      #
      #   t=0    kubelet removes the pod from Service endpoints (async!)
      #          AND runs the preStop hook
      #   t=0    preStop sleeps 10s  -> lets in-flight LB reprogramming settle,
      #                                 preventing the 502s of an eager exit
      #   t=10s  kubelet sends SIGTERM to PID 1 of each container
      #          app has shutdown_timeout=25s to drain
      #   t=45s  terminationGracePeriodSeconds expires -> SIGKILL
      #
      # Invariant: preStop_sleep + app_shutdown_timeout < terminationGracePeriodSeconds
      #            10 + 25 = 35 < 45   OK
      # ---------------------------------------------------------------------
      terminationGracePeriodSeconds: 45

      # Share the PID namespace between containers in the pod so that a debug
      # container can `ps`, `strace` and signal the application's processes.
      # NOTE: with shareProcessNamespace, the PAUSE container becomes PID 1 and
      # reaps zombies for the whole pod; the app is no longer PID 1.
      shareProcessNamespace: true

      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault

      containers:
        - name: catalog-api
          image: registry.example.com/catalog-api:1.14.2
          imagePullPolicy: IfNotPresent

          # The image's ENTRYPOINT is ["/sbin/tini","--","/opt/catalog-api/bin/catalog-api"].
          # tini as PID 1 does two things the application cannot:
          #   1. installs default handlers so SIGTERM is not silently discarded
          #      (PID 1 ignores signals that have no explicit handler);
          #   2. calls wait() on re-parented orphans, so zombies cannot accumulate.
          # The Kubernetes-native equivalent to a custom init is simply making sure
          # the app itself is PID 1 AND handles signals - tini is for when it is not.
          args:
            - "--config=/etc/catalog-api/config.yaml"

          ports:
            - name: http
              containerPort: 8080
              protocol: TCP

          lifecycle:
            preStop:
              exec:
                # Do NOT exit immediately on SIGTERM. Endpoint removal and
                # SIGTERM delivery are concurrent, not ordered.
                command: ["/bin/sh", "-c", "sleep 10"]

          startupProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 2
            failureThreshold: 30
          readinessProbe:
            httpGet: { path: /readyz, port: http }
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 2
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3

          resources:
            requests: { cpu: "250m", memory: "256Mi" }
            limits:   { cpu: "1",    memory: "512Mi" }

          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]

          volumeMounts:
            - name: config
              mountPath: /etc/catalog-api
              readOnly: true
            - name: tmp
              mountPath: /tmp

      volumes:
        - name: config
          configMap:
            name: catalog-api-config
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
---
# nginx inverts the signal convention: SIGTERM = fast (lossy) shutdown,
# SIGQUIT = graceful drain. Kubernetes always sends SIGTERM, so the image
# MUST declare STOPSIGNAL SIGQUIT for the container runtime to translate it.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: edge-proxy
  namespace: catalog
spec:
  replicas: 2
  selector:
    matchLabels: { app.kubernetes.io/name: edge-proxy }
  template:
    metadata:
      labels: { app.kubernetes.io/name: edge-proxy }
    spec:
      terminationGracePeriodSeconds: 60
      containers:
        - name: nginx
          # Dockerfile of this image ends with:  STOPSIGNAL SIGQUIT
          image: registry.example.com/edge-proxy:1.27.1
          ports:
            - { name: http, containerPort: 8080 }
          lifecycle:
            preStop:
              exec:
                command:
                  - /bin/sh
                  - -c
                  - "sleep 5 && /usr/sbin/nginx -s quit"
---
# Cap PIDs per namespace: a zombie leak or fork bomb in one workload must not
# exhaust the node's PID table for every other pod scheduled there.
apiVersion: v1
kind: ResourceQuota
metadata:
  name: catalog-pids
  namespace: catalog
spec:
  hard:
    pods: "40"
    count/deployments.apps: "10"
---
# PodDisruptionBudget: guarantees the graceful-termination path is never
# short-circuited by draining every replica at once.
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: catalog-api
  namespace: catalog
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: catalog-api
```

Configuración correspondiente del kubelet (contención de PIDs por nodo):

```yaml
# /var/lib/kubelet/config.yaml  (excerpt)
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
# Hard cap on PIDs any single pod may create. Without this, one runaway
# container can exhaust /proc/sys/kernel/pid_max for the entire node.
podPidsLimit: 4096
evictionHard:
  memory.available: "200Mi"
  pid.available: "10%"
evictionSoft:
  pid.available: "15%"
evictionSoftGracePeriod:
  pid.available: "1m"
systemReserved:
  cpu: "500m"
  memory: "1Gi"
  pid: "1000"
```

Observando el ciclo de vida en un clúster real:

```
$ kubectl -n catalog get pods -o wide
NAME                           READY   STATUS    RESTARTS   AGE   IP           NODE
catalog-api-7d4c9b8f6-2xk4m    1/1     Running   0          14m   10.244.2.7   node-02
catalog-api-7d4c9b8f6-9pnrt    1/1     Running   0          14m   10.244.1.9   node-01
catalog-api-7d4c9b8f6-lkq8c    1/1     Running   0          14m   10.244.3.4   node-03

$ kubectl -n catalog exec catalog-api-7d4c9b8f6-2xk4m -- ps -eo pid,ppid,stat,comm
    PID   PPID STAT COMMAND
      1      0 Ss   pause
      7      0 Ss   tini
     14      7 Sl   catalog-api

$ kubectl -n catalog exec catalog-api-7d4c9b8f6-2xk4m -- \
    grep -E 'SigCgt|SigIgn' /proc/14/status
SigIgn: 0000000000001000
SigCgt: 0000000180004a03

# Bit 15 (SIGTERM) is set in SigCgt -> the app WILL drain gracefully.

$ kubectl -n catalog delete pod catalog-api-7d4c9b8f6-2xk4m
pod "catalog-api-7d4c9b8f6-2xk4m" deleted

$ kubectl -n catalog get events --field-selector involvedObject.name=catalog-api-7d4c9b8f6-2xk4m
LAST SEEN   TYPE     REASON      OBJECT                              MESSAGE
0s          Normal   Killing     pod/catalog-api-7d4c9b8f6-2xk4m     Stopping container catalog-api
```

Contenedor efímero de depuración — el reemplazo moderno de hacer `kubectl exec` dentro de una imagen distroless:

```
$ kubectl -n catalog debug -it catalog-api-7d4c9b8f6-9pnrt \
    --image=registry.example.com/netshoot:0.13 \
    --target=catalog-api \
    --profile=general \
    -- bash
Defaulting debug container name to debugger-4qz7x.

root@catalog-api-7d4c9b8f6-9pnrt:/# ps -eo pid,ppid,stat,wchan:20,comm
    PID   PPID STAT WCHAN                COMMAND
      1      0 Ss   ep_poll              pause
      7      0 Ss   do_wait              tini
     14      7 Sl   futex_wait_queue_me  catalog-api
     29      0 Ss   do_wait              bash

root@catalog-api-7d4c9b8f6-9pnrt:/# kill -QUIT 14      # dump Go/Java stacks
root@catalog-api-7d4c9b8f6-9pnrt:/# cat /proc/14/status | grep -E 'Threads|SigBlk'
Threads:        24
SigBlk: 0000000000000000
```

### 7.3 Una implementación de referencia del manejo de señales

El lado de la aplicación en el contrato, en Python — esto es lo que significa concretamente "maneja `SIGTERM`":

```python
#!/usr/bin/env python3
"""Reference graceful-shutdown skeleton.

Demonstrates the three obligations of a well-behaved production process:
  1. install handlers for SIGTERM and SIGINT and drain instead of exiting;
  2. reload configuration on SIGHUP without dropping connections;
  3. reap children so no zombie can accumulate.
"""
import os
import signal
import sys
import threading
import time

_shutdown = threading.Event()
_reload = threading.Event()


def _on_terminate(signum: int, _frame) -> None:
    """SIGTERM/SIGINT: start draining. Never call sys.exit() from a handler."""
    print(f"received {signal.Signals(signum).name}: draining", flush=True)
    _shutdown.set()


def _on_reload(_signum: int, _frame) -> None:
    """SIGHUP: reload config in the main loop, not in the handler."""
    _reload.set()


def _reap_children(_signum: int, _frame) -> None:
    """SIGCHLD: reap every exited child. WNOHANG loops because signals coalesce."""
    while True:
        try:
            pid, status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if pid == 0:
            return
        print(f"reaped child {pid} status={status}", flush=True)


def main() -> int:
    signal.signal(signal.SIGTERM, _on_terminate)
    signal.signal(signal.SIGINT, _on_terminate)
    signal.signal(signal.SIGHUP, _on_reload)
    signal.signal(signal.SIGCHLD, _reap_children)
    # Ignoring SIGPIPE turns broken-pipe writes into EPIPE errors we can handle,
    # instead of silent process death.
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)

    print(f"started pid={os.getpid()} ppid={os.getppid()}", flush=True)

    while not _shutdown.is_set():
        if _reload.is_set():
            _reload.clear()
            print("configuration reloaded", flush=True)
        time.sleep(0.5)

    # Drain phase: bounded, and shorter than the supervisor's grace period.
    deadline = time.monotonic() + 25.0
    while time.monotonic() < deadline:
        print("draining in-flight work...", flush=True)
        time.sleep(1.0)
        break  # replace with a real in-flight counter

    print("shutdown complete", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

```
$ ./gracefuld.py &
[1] 11402
started pid=11402 ppid=4102

$ kill -HUP 11402
configuration reloaded

$ grep SigCgt /proc/11402/status
SigCgt: 0000000000014203

$ kill -TERM 11402
received SIGTERM: draining
draining in-flight work...
shutdown complete
[1]+  Done                    ./gracefuld.py
```

### 7.4 Ansible: verificación de higiene de procesos en toda la flota

`playbooks/verify-process-hygiene.yml`

```yaml
---
- name: Verify process hygiene across the fleet
  hosts: linux_fleet
  gather_facts: true
  become: true
  vars:
    zombie_threshold: 20
    load_per_core_threshold: 2.0
    critical_units:
      - catalog-api.service
      - postgresql@16-main.service
      - nginx.service

  tasks:
    - name: Count zombie processes
      ansible.builtin.shell:
        cmd: "ps -eo stat --no-headers | grep -c '^Z' || true"
      changed_when: false
      register: zombie_count

    - name: Count uninterruptible (D state) processes
      ansible.builtin.shell:
        cmd: "ps -eo stat --no-headers | grep -c '^D' || true"
      changed_when: false
      register: dstate_count

    - name: Read the load average
      ansible.builtin.slurp:
        src: /proc/loadavg
      register: loadavg_raw

    - name: Compute load per core
      ansible.builtin.set_fact:
        load_1m: "{{ (loadavg_raw.content | b64decode).split()[0] | float }}"
        load_per_core: >-
          {{ ((loadavg_raw.content | b64decode).split()[0] | float)
             / (ansible_processor_vcpus | int) }}

    - name: Fail when zombies exceed the threshold
      ansible.builtin.assert:
        that:
          - (zombie_count.stdout | int) < zombie_threshold
        fail_msg: >-
          {{ inventory_hostname }} has {{ zombie_count.stdout }} zombies
          (threshold {{ zombie_threshold }}). A parent process is not calling wait().
        success_msg: "zombies: {{ zombie_count.stdout }} - OK"

    - name: Warn when tasks are stuck in uninterruptible sleep
      ansible.builtin.debug:
        msg: >-
          WARNING {{ inventory_hostname }}: {{ dstate_count.stdout }} tasks in D state,
          load {{ load_1m }} over {{ ansible_processor_vcpus }} vCPU.
          Load is inflated by blocked I/O, not CPU demand. Investigate storage.
      when: (dstate_count.stdout | int) > 0

    - name: Assert every critical unit is active
      ansible.builtin.systemd_service:
        name: "{{ item }}"
        state: started
        enabled: true
      loop: "{{ critical_units }}"
      register: unit_state

    - name: Verify each critical unit escalates to SIGKILL and caps its task count
      ansible.builtin.shell:
        cmd: "systemctl show {{ item }} -p SendSIGKILL -p TasksMax -p KillMode --value"
      changed_when: false
      register: kill_policy
      loop: "{{ critical_units }}"

    - name: Report kill policy
      ansible.builtin.debug:
        msg: "{{ item.item }} -> {{ item.stdout_lines | join(' / ') }}"
      loop: "{{ kill_policy.results }}"
      loop_control:
        label: "{{ item.item }}"

    - name: Reload (not restart) configuration on the API tier
      ansible.builtin.systemd_service:
        name: catalog-api.service
        state: reloaded
      when: "'api_tier' in group_names"
```

```
$ ansible-playbook -i inventory/prod playbooks/verify-process-hygiene.yml --limit node-01

PLAY [Verify process hygiene across the fleet] *********************************

TASK [Count zombie processes] **************************************************
ok: [node-01]

TASK [Fail when zombies exceed the threshold] **********************************
ok: [node-01] => {
    "changed": false,
    "msg": "zombies: 1 - OK"
}

TASK [Warn when tasks are stuck in uninterruptible sleep] **********************
ok: [node-01] => {
    "msg": "WARNING node-01: 4 tasks in D state, load 4.82 over 8 vCPU. Load is inflated by blocked I/O, not CPU demand. Investigate storage."
}

TASK [Report kill policy] ******************************************************
ok: [node-01] => (item=catalog-api.service) => {
    "msg": "catalog-api.service -> yes / 512 / control-group"
}

PLAY RECAP *********************************************************************
node-01   : ok=9  changed=1  unreachable=0  failed=0  skipped=0
```

---

## 8. Verificación y diagnóstico de fallas

### 8.1 Árbol de decisión para triage

```
Symptom: "the process will not die"
   │
   ├── ps -o stat= -p PID  →  Z   ──▶ It is ALREADY dead. Kill/signal the PARENT.
   │                                   ps -o ppid= -p PID ; kill -CHLD <ppid>
   │                                   If the parent will not reap, kill the parent;
   │                                   the zombie re-parents to init and is reaped.
   │
   ├── ps -o stat= -p PID  →  D   ──▶ Uninterruptible. SIGKILL CANNOT reach it.
   │                                   cat /proc/PID/wchan ; cat /proc/PID/stack
   │                                   Fix the I/O layer (NFS, iSCSI, dm device).
   │
   ├── ps -o stat= -p PID  →  T   ──▶ Stopped. kill -CONT PID first.
   │
   ├── grep SigBlk /proc/PID/status  → bit 15 set ──▶ SIGTERM is BLOCKED.
   │                                                   Use SIGKILL, then file a bug.
   │
   ├── grep SigCgt /proc/PID/status  → bit 15 CLEAR ──▶ No SIGTERM handler.
   │                                                     Default action is terminate;
   │                                                     if it survives, it is PID 1
   │                                                     in a namespace (see below).
   │
   └── PID == 1 in a container ──▶ PID 1 IGNORES signals with no installed handler.
                                    The kernel special-cases init. Add tini/dumb-init,
                                    or install a handler in the application.

Symptom: "load average is 40 but the CPUs are idle"
   │
   └── ps -eo stat= | grep -c '^D'   ──▶ non-zero: Linux load counts D state.
       cat /proc/pressure/io               This is a STORAGE incident.
       for p in $(pgrep -f ''); do cat /proc/$p/wchan; echo; done | sort | uniq -c

Symptom: "cannot fork / Resource temporarily unavailable"
   │
   ├── ps -eo stat= | grep -c '^Z'          ──▶ zombie leak (parent not wait()ing)
   ├── cat /sys/fs/cgroup/<slice>/pids.current  vs  pids.max
   ├── ulimit -u  /  systemctl show <unit> -p TasksMax
   └── cat /proc/sys/kernel/pid_max ; ps -e --no-headers | wc -l
```

### 8.2 Diagnóstico de zombis, de punta a punta

```
$ ps -eo stat --no-headers | grep -c '^Z'
1247

$ ps -eo pid,ppid,stat,comm | awk '$3 ~ /^Z/ {print}' | head -5
  14203  14198 Z    worker
  14204  14198 Z    worker
  14205  14198 Z    worker
  14206  14198 Z    worker
  14207  14198 Z    worker

$ ps -eo pid,ppid,stat,comm | awk '$3 ~ /^Z/ {print $2}' | sort | uniq -c | sort -rn
   1247 14198

# One parent is responsible for all of them.
$ ps -o pid,ppid,stat,cmd -p 14198
    PID    PPID STAT CMD
  14198       1 Ssl  /usr/bin/python3 /opt/dispatcher/dispatch.py

$ grep -E '^SigCgt|^Threads' /proc/14198/status
Threads:        4
SigCgt: 0000000000010002

# Bit 17 (SIGCHLD) is CLEAR and the code never calls wait(): confirmed leak.

$ cat /proc/14198/wchan; echo
ep_poll

# Immediate mitigation: nudge the parent, then restart it.
$ kill -CHLD 14198
$ ps -eo stat --no-headers | grep -c '^Z'
1247                                  # unchanged - the parent has no handler

$ sudo systemctl restart dispatcher.service
$ ps -eo stat --no-headers | grep -c '^Z'
0

# Zombies re-parented to systemd (PID 1), which reaped them immediately.
```

**Solución permanente:** instalar un handler de `SIGCHLD` que itere sobre `waitpid(-1, WNOHANG)` (sección 7.3), o correr el proceso bajo un init que haga reap (`tini`), o — en systemd — dejar `KillMode=control-group` para que todo el árbol se limpie al detener.

### 8.3 Estado `D` — probar que es la capa de almacenamiento

```
$ ps -eo pid,stat,wchan:32,comm --no-headers | awk '$2 ~ /^D/'
   8841 D    nfs_wait_bit_killable            rsync
   8842 D    nfs_wait_bit_killable            rsync
   9103 D    io_schedule                      postgres
   9111 D    wait_on_page_bit                 kworker/u16:3

$ sudo cat /proc/8841/stack
[<0>] nfs_wait_bit_killable+0x2e/0x90 [nfs]
[<0>] __wait_on_bit+0x5c/0xb0
[<0>] out_of_line_wait_on_bit+0x8e/0xb0
[<0>] nfs_wait_client_init_complete+0x64/0xa0 [nfs]
[<0>] nfs4_discover_server_trunking+0x8c/0x2c0 [nfsv4]

$ kill -9 8841
$ ps -o pid,stat -p 8841
    PID STAT
   8841 D

# SIGKILL delivered, process still in D. Confirms: no user-space code is running
# to receive it. The signal is queued in SigPnd until the kernel returns.

$ grep -E 'SigPnd|ShdPnd' /proc/8841/status
SigPnd: 0000000000000100
ShdPnd: 0000000000000100

# Bit 9 = SIGKILL, pending and undeliverable.

$ mount | grep nfs
nfs-01:/exports/data on /mnt/data type nfs4 (rw,relatime,vers=4.2,hard,proto=tcp,timeo=600,...)

$ ping -c 2 -W 2 nfs-01
PING nfs-01 (10.0.4.11) 56(84) bytes of data.
--- nfs-01 ping statistics ---
2 packets transmitted, 0 received, 100% packet loss, time 1023ms
```

**Conclusión y camino de remediación.** El servidor NFS es inalcanzable y el montaje usa semántica `hard`, así que el cliente reintenta para siempre en una espera ininterrumpible. Nada en la capa de procesos puede arreglar esto. Opciones, en orden: (a) restaurar el servidor; (b) `umount -f -l /mnt/data` (force perezoso) para liberar la referencia del namespace; (c) remontar con `soft,intr` aceptando semántica de error de E/S; (d) reiniciar. `kill -9` no está entre ellas.

### 8.4 La trampa de señales del PID 1 en contenedores

```
$ docker run -d --name shell-init alpine:3.20 sh -c 'while true; do sleep 5; done'
9c1f2a4b8e73

$ docker exec shell-init ps -eo pid,ppid,stat,comm
PID   PPID  STAT COMMAND
    1     0 S    sh
   14     1 S    sleep
   15     0 R    ps

$ time docker stop shell-init
shell-init
real    0m10.412s        # <-- ten seconds: the full default grace period

$ docker inspect shell-init --format '{{.State.ExitCode}}'
137                      # 128 + 9 = SIGKILL. It was NOT a graceful stop.
```

**Por qué.** El kernel le da al PID 1 una propiedad especial: las señales cuya acción por defecto es *terminar* se **descartan silenciosamente** salvo que el proceso haya instalado un handler explícito. `sh` no instala ningún handler de `SIGTERM`, así que el `SIGTERM` de `docker stop` se esfumó y solo el `SIGKILL` a los 10 segundos lo terminó. `exit 137` es la huella dactilar.

Versión correcta:

```
$ docker run -d --name tini-init --init alpine:3.20 sh -c 'while true; do sleep 5; done'
4d8e11c92fa6

$ docker exec tini-init ps -eo pid,ppid,stat,comm
PID   PPID  STAT COMMAND
    1     0 S    docker-init
    7     1 S    sh
   13     7 S    sleep

$ time docker stop tini-init
tini-init
real    0m0.318s

$ docker inspect tini-init --format '{{.State.ExitCode}}'
143                      # 128 + 15 = SIGTERM. Graceful.
```

| Código de salida | Significado | Interpretación |
|---|---|---|
| `0` | Salida limpia | Éxito |
| `1`–`125` | Estado de salida de la aplicación | Lo decidió la aplicación |
| `126` | No ejecutable | Problema de permisos o de formato |
| `127` | Comando no encontrado | `PATH` o binario faltante |
| `128 + N` | **Terminado por la señal N** | `130` = SIGINT, `137` = **SIGKILL**, `139` = SIGSEGV, `143` = SIGTERM |

> **`137` en un `kubectl describe pod` de Kubernetes es el hallazgo de ciclo de vida más común de todos.** Significa o bien (a) que venció el período de gracia y el kubelet escaló, o bien (b) que actuó el OOM killer del cgroup. Distinguilos: `reason: OOMKilled` en el estado del contenedor significa memoria; la ausencia de `OOMKilled` con `reason: Error` significa el período de gracia.

```
$ kubectl -n catalog describe pod catalog-api-7d4c9b8f6-lkq8c | sed -n '/Last State/,/Ready/p'
    Last State:     Terminated
      Reason:       Error
      Exit Code:    137
      Started:      Wed, 26 Aug 2026 09:12:04 +0000
      Finished:     Wed, 26 Aug 2026 09:41:49 +0000
    Ready:          True
```

### 8.5 Checklist de verificación

Corré esto antes de declarar cualquier servicio listo para producción:

```bash
#!/usr/bin/env bash
# verify-process-contract.sh <pid|unit>
# Proves - not assumes - that a process honours the lifecycle contract.
set -euo pipefail

pid=${1:?usage: verify-process-contract.sh <pid>}

bit_set() { local mask=$1 bit=$2; (( 0x$mask >> (bit - 1) & 1 )); }

sigcgt=$(awk '/^SigCgt/ {print $2}' "/proc/$pid/status")
sigblk=$(awk '/^SigBlk/ {print $2}' "/proc/$pid/status")
sigign=$(awk '/^SigIgn/ {print $2}' "/proc/$pid/status")

printf '=== process contract for PID %s (%s) ===\n' \
    "$pid" "$(tr -d '\0' < "/proc/$pid/comm")"

printf 'state          : %s\n'  "$(awk '/^State/ {print $2, $3}' /proc/$pid/status)"
printf 'threads        : %s\n'  "$(awk '/^Threads/ {print $2}' /proc/$pid/status)"
printf 'ppid           : %s\n'  "$(awk '/^PPid/ {print $2}' /proc/$pid/status)"
printf 'cgroup         : %s\n'  "$(cut -d: -f3 /proc/$pid/cgroup | tail -1)"
printf 'wchan          : %s\n'  "$(cat /proc/$pid/wchan 2>/dev/null || echo '-')"

bit_set "$sigcgt" 15 && echo 'SIGTERM handler: YES  - graceful shutdown possible' \
                     || echo 'SIGTERM handler: NO   - *** default terminate; verify no in-flight state ***'
bit_set "$sigcgt" 1  && echo 'SIGHUP  handler: YES  - config reload supported' \
                     || echo 'SIGHUP  handler: no   - reload requires restart'
bit_set "$sigcgt" 17 && echo 'SIGCHLD handler: YES  - reaps children' \
                     || echo 'SIGCHLD handler: no   - zombie risk if it forks'
bit_set "$sigblk" 15 && echo 'SIGTERM blocked: *** YES - SIGTERM WILL BE IGNORED ***' \
                     || echo 'SIGTERM blocked: no'
bit_set "$sigign" 13 && echo 'SIGPIPE ignored: yes  - handles EPIPE in userspace' \
                     || echo 'SIGPIPE ignored: no   - broken pipe will kill it'

if [[ $pid -eq 1 ]]; then
    echo 'NOTE: PID 1 - signals without an explicit handler are DISCARDED by the kernel.'
fi
```

```
$ sudo ./verify-process-contract.sh 10241
=== process contract for PID 10241 (catalog-api) ===
state          : S (sleeping)
threads        : 18
ppid           : 1
cgroup         : /system.slice/catalog-api.service
wchan          : futex_wait_queue_me
SIGTERM handler: YES  - graceful shutdown possible
SIGHUP  handler: YES  - config reload supported
SIGCHLD handler: no   - zombie risk if it forks
SIGTERM blocked: no
SIGPIPE ignored: yes  - handles EPIPE in userspace
```

### 8.6 Referencia rápida: síntoma → comando

| Síntoma | Primer comando | Qué prueba |
|---|---|---|
| "No se muere" | `ps -o pid,stat,wchan:24,comm -p PID` | La distinción `Z`/`D`/`T` |
| "Murió en silencio al desloguearme" | `grep SigIgn /proc/PID/status`; `ps -o tty,sid` | Disposición de `SIGHUP` + sesión |
| "La carga está alta, la CPU ociosa" | `ps -eo stat= \| grep -c '^D'` | Carga inflada por E/S bloqueada |
| "Sin memoria pero `free` muestra GB" | `free -w -h`; `MemAvailable` de `/proc/meminfo` | `free` ≠ `available` |
| "No puede hacer fork" | `cat /sys/fs/cgroup/.../pids.{current,max}`; `ulimit -u` | Se alcanzó el límite de PIDs/tareas |
| "El trabajo se detuvo solo" | `jobs -l`; `ps -o stat` → `T` | `SIGTTIN` — quiere stdin |
| "El deploy causa 502" | `grep SigCgt`; revisar `preStop` + período de gracia | Sin handler o carrera con la eliminación del endpoint |
| "Código de salida 137" | `kubectl describe pod` → ¿`OOMKilled`? | OOM vs. `SIGKILL` por período de gracia |
| "El proceso usa 100% de CPU" | `top -H -p PID`, después `strace -c -p TID` | Qué hilo, qué syscall |
| "¿Qué unidad es dueña de este PID?" | `ps -o cgroup= -p PID`; `systemctl status PID` | Mapeo cgroup → unidad |

```
$ systemctl status 10248
● catalog-api.service - Catalog API (HTTP, graceful shutdown)
     Loaded: loaded (/etc/systemd/system/catalog-api.service; enabled)
     Active: active (running) since Wed 2026-08-26 08:41:12 UTC; 1h 12min ago
   Main PID: 10241 (catalog-api)
      Tasks: 3 (limit: 512)
     CGroup: /system.slice/catalog-api.service
             ├─10241 /opt/catalog-api/bin/catalog-api --config /etc/catalog-api/config.yaml
             ├─10248 /opt/catalog-api/bin/catalog-worker --queue=default
             └─10249 /opt/catalog-api/bin/catalog-worker --queue=priority
```

---

## 9. Resumen orientado al examen

### 9.1 Matriz de comandos para el objetivo 103.5

| Utilidad | Propósito principal | Invocación imprescindible |
|---|---|---|
| `&` | Ejecutar en segundo plano | `cmd &` → imprime `[job] PID` |
| `jobs` | Listar los trabajos de la shell | `jobs -l` (con PIDs), `jobs -p` |
| `fg` | Traer a primer plano | `fg %1`, `fg` (trabajo actual) |
| `bg` | Reanudar en segundo plano un trabajo detenido | `bg %1` |
| `kill` | Enviar una señal | `kill -9 PID`, `kill -s TERM PID`, `kill %1`, `kill -l` |
| `nohup` | Ignorar `SIGHUP` | `nohup cmd > out 2>&1 &` |
| `ps` | Instantánea de procesos | `ps aux`, `ps -ef`, `ps -eo …`, `ps axjf`, `--sort=-pcpu` |
| `top` | Monitor de procesos en vivo | `top -b -n1`, teclas `M P k r H 1 c` |
| `free` | Resumen de memoria | `free -h`, `free -m -w`, mirar `available` |
| `uptime` | Load average | `uptime`, `/proc/loadavg` |
| `pgrep` | Buscar PIDs por patrón | `pgrep -af name`, `pgrep -u user -x name` |
| `pkill` | Señalizar por patrón | `pkill -HUP -x nginx`, `pkill -f pattern` |
| `killall` | Señalizar por nombre exacto | `killall -s HUP nginx`, `killall -w`, `killall -o 2h` |
| `watch` | Repetir un comando | `watch -n1 -d 'cmd'` (¡entrecomillá el pipeline!) |
| `screen` | Sesión desacoplable | `screen -S n`, `Ctrl-a d`, `screen -ls`, `screen -r n` |
| `tmux` | Sesión desacoplable | `tmux new -s n`, `Ctrl-b d`, `tmux ls`, `tmux attach -t n` |

### 9.2 Trampas que cuestan puntos y caídas

1. **`kill` no mata.** Envía una señal. Por defecto es `SIGTERM` (15), no `SIGKILL` (9).
2. **`SIGKILL` (9) y `SIGSTOP` (19) no pueden capturarse, bloquearse ni ignorarse** — por nada, nunca.
3. **Un proceso en estado `D` ignora `SIGKILL`** porque no hay contexto de usuario al que entregársela. Esto no contradice la regla 2 — la señal queda *pendiente*, no *ignorada*.
4. **A un zombi no se lo puede matar.** Ya está muerto. Señalizá o reiniciá al padre.
5. **`kill -TERM -4210`** (negativo) apunta al *grupo* de procesos; **`kill -TERM 4210`** apunta a un solo PID.
6. **`nohup` no desacopla.** Solo pone `SIGHUP` en ignorada y redirige stdout. `setsid` desacopla.
7. **`bash` no manda `SIGHUP` al salir por defecto** (`shopt huponexit` está off). Una conexión *caída* es un mecanismo distinto — el kernel cuelga el tty.
8. **`free` bajo es saludable; `available` bajo es la alerta.**
9. **El load average de Linux incluye el estado `D`.** Carga alta con CPUs ociosas significa E/S bloqueada.
10. **`ps -aux` no es `ps aux`.** El guion la vuelve sintaxis UNIX y `x` pasa a ser un nombre de usuario.
11. **`pkill` coincide por subcadenas por defecto.** `pgrep -a` primero, siempre.
12. **`killall` en Solaris mata todos los procesos.** En Linux (psmisc) coincide por nombre. No arrastres el hábito entre plataformas.
13. **`watch cmd | grep x` no observa nada útil.** Entrecomillá todo el pipeline.
14. **El PID 1 descarta las señales para las que no tiene handler.** Por eso los contenedores necesitan `tini` o una aplicación que maneje `SIGTERM`.
15. **El código de salida `128 + N` significa terminado por la señal N.** `137` = `SIGKILL`, `143` = `SIGTERM`.
16. **`SIGUSR1`/`SIGUSR2` son 10/12 en x86-64, no universalmente.** Usá nombres.
17. **nginx invierte la convención:** `SIGQUIT` es ordenado, `SIGTERM` es rápido/con pérdida.

---

## 10. Referencias

**Objetivos de certificación**
- LPI — Objetivos del Examen 101-500 (v5.0), Tema 103.5 *Create, monitor and kill processes*: https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — Panorama de la certificación LPIC-1: https://www.lpi.org/our-certifications/lpic-1-overview/

**Interfaces del kernel y llamadas al sistema (proyecto `man-pages`)**
- `signal(7)` — números de señal, acciones por defecto, capturabilidad: https://man7.org/linux/man-pages/man7/signal.7.html
- `kill(1)` — el comando: https://man7.org/linux/man-pages/man1/kill.1.html
- `kill(2)` — la llamada al sistema, incluida la semántica del PID negativo: https://man7.org/linux/man-pages/man2/kill.2.html
- `fork(2)`: https://man7.org/linux/man-pages/man2/fork.2.html
- `execve(2)` — disposición de señales a través de `exec`: https://man7.org/linux/man-pages/man2/execve.2.html
- `wait(2)` / `waitpid(2)` — reaping de zombis: https://man7.org/linux/man-pages/man2/wait.2.html
- `credentials(7)` — grupos de procesos, sesiones, terminal de control: https://man7.org/linux/man-pages/man7/credentials.7.html
- `setsid(2)`: https://man7.org/linux/man-pages/man2/setsid.2.html
- `setsid(1)`: https://man7.org/linux/man-pages/man1/setsid.1.html
- `proc(5)` — `/proc/[pid]/status`, `stat`, `wchan`, `/proc/loadavg`, `/proc/meminfo`: https://man7.org/linux/man-pages/man5/proc.5.html
- `prctl(2)` — `PR_SET_CHILD_SUBREAPER`: https://man7.org/linux/man-pages/man2/prctl.2.html
- `cgroups(7)` — el controlador `pids`: https://man7.org/linux/man-pages/man7/cgroups.7.html
- `nohup(1)`: https://man7.org/linux/man-pages/man1/nohup.1.html

**procps-ng (`ps`, `top`, `free`, `uptime`, `pgrep`, `pkill`, `watch`)**
- Sitio del proyecto: https://gitlab.com/procps-ng/procps
- `ps(1)`: https://man7.org/linux/man-pages/man1/ps.1.html
- `top(1)`: https://man7.org/linux/man-pages/man1/top.1.html
- `free(1)`: https://man7.org/linux/man-pages/man1/free.1.html
- `uptime(1)`: https://man7.org/linux/man-pages/man1/uptime.1.html
- `pgrep(1)` / `pkill(1)`: https://man7.org/linux/man-pages/man1/pgrep.1.html
- `watch(1)`: https://man7.org/linux/man-pages/man1/watch.1.html

**psmisc (`killall`, `pstree`, `fuser`)**
- Sitio del proyecto: https://gitlab.com/psmisc/psmisc
- `killall(1)`: https://man7.org/linux/man-pages/man1/killall.1.html
- `pstree(1)`: https://man7.org/linux/man-pages/man1/pstree.1.html

**Control de trabajos de la shell**
- GNU Bash Reference Manual — Job Control: https://www.gnu.org/software/bash/manual/bash.html#Job-Control
- GNU Bash Reference Manual — Job Control Builtins (`bg`, `fg`, `jobs`, `kill`, `wait`, `disown`): https://www.gnu.org/software/bash/manual/bash.html#Job-Control-Builtins
- POSIX.1-2024 — Shell and Utilities, `kill`: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/kill.html

**Multiplexores de terminal**
- Manual de GNU Screen: https://www.gnu.org/software/screen/manual/screen.html
- Proyecto y manual de tmux: https://github.com/tmux/tmux/wiki

**systemd**
- `systemd.kill(5)` — `KillMode`, `KillSignal`, `SendSIGKILL`, `FinalKillSignal`: https://www.freedesktop.org/software/systemd/man/latest/systemd.kill.html
- `systemd.service(5)` — `Type`, `ExecReload`, `TimeoutStopSec`, `Restart`: https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html
- `systemd.resource-control(5)` — `TasksMax`, `MemoryMax`, `CPUQuota`: https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html
- `systemd-run(1)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html
- `systemd-cgls(1)` / `systemd-cgtop(1)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-cgls.html

**Contenedores y orquestación**
- Kubernetes — Pod Lifecycle, terminación y períodos de gracia: https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination
- Kubernetes — Container Lifecycle Hooks (`preStop`): https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/
- Kubernetes — Share Process Namespace Between Containers in a Pod: https://kubernetes.io/docs/tasks/configure-pod-container/share-process-namespace/
- Kubernetes — Debug Running Pods (contenedores efímeros): https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubernetes — Process ID Limits and Reservations: https://kubernetes.io/docs/concepts/policy/pid-limiting/
- Docker — `docker stop` y `STOPSIGNAL`: https://docs.docker.com/reference/cli/docker/container/stop/
- tini — un init diminuto pero válido para contenedores: https://github.com/krallin/tini

**Convenciones de señales en aplicaciones**
- nginx — Controlling nginx (tabla de señales, `SIGQUIT` ordenado vs `SIGTERM` rápido): https://nginx.org/en/docs/control.html

**Observabilidad complementaria**
- Documentación del kernel de Linux — Pressure Stall Information: https://docs.kernel.org/accounting/psi.html
- sysstat (`pidstat`, `sar`): https://github.com/sysstat/sysstat