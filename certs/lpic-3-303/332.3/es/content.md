# LPIC-3 303 — Tema 332.3: Control de recursos

**Examen:** 303-300 (Security), versión 3.0.0 · **Peso del objetivo:** 5.0
**Perfil:** Principal Platform Architect / Senior SRE

---

## 1. Motivación: el agotamiento de recursos es un ataque a la disponibilidad

Las certificaciones de seguridad enseñan bien la confidencialidad y la integridad, y mal la disponibilidad. El control de recursos es la mitad de disponibilidad de la tríada CIA, y es la única de las tres que no se puede comprar con criptografía.

Considerá un patrón de falla en producción que todo SRE termina viviendo:

> Un único pool de PHP-FPM en un host compartido recibe una subida manipulada que dispara un backtracking catastrófico en una expresión regular. El RSS del worker trepa de 60 MB a 6 GB en once segundos. El OOM killer del kernel se despierta, puntúa cada tarea de la máquina por RSS ponderado con `oom_score_adj`, y mata… a `postgres`, porque la base de datos es el consumidor bien comportado más grande de la máquina. El atacante mandó una sola petición HTTP y tiró abajo la capa que importaba.

Eso no es un bug de seguridad de memoria. No se desbordó nada, no se inyectó nada. Es una **falla de contención**: se permitió que una carga de trabajo no confiable consumiera un recurso compartido, finito y gestionado por el kernel sin un techo, y la heurística de recuperación por defecto del kernel eligió a la víctima equivocada.

La misma forma se repite a lo largo de toda la superficie de ataque:

| Ataque / falla | Recurso agotado | Resultado por defecto del kernel | Control correcto |
|---|---|---|---|
| Fork bomb (`:(){ :\|:& };:`) | PIDs / task structs | Livelock de todo el host, `fork()` falla incluso para root | `pids.max` / `TasksMax=` |
| ReDoS, bomba de descompresión | Memoria anónima | OOM kill global de una víctima no relacionada | `memory.max` / `MemoryMax=` |
| Fuga de FD, slowloris | Descriptores de archivo | `EMFILE`; el bucle de `accept()` gira en vacío | `RLIMIT_NOFILE`, `LimitNOFILE=` |
| Escritor de logs desbocado | Ancho de banda de disco, inode/journal | Picos de latencia de fsync en todo el clúster | `io.max` / `IOWriteBandwidthMax=` |
| Cripto-minero en un servicio comprometido | CPU | Incumplimiento del SLO de latencia, sin caída | `cpu.max` / `CPUQuota=` |
| `mlock()` malicioso de una región enorme | RAM no swappeable | Colapso de la recuperación de memoria | `RLIMIT_MEMLOCK` |
| Core dump de un proceso que tiene claves TLS | Disco + **divulgación de secretos** | Clave privada en disco, legible por todos en `/var/lib/systemd/coredump` | `RLIMIT_CORE=0`, `CoredumpFilter=` |

La última fila es la que los candidatos olvidan: el control de recursos no es solo cuestión de disponibilidad. `RLIMIT_CORE` es un control de **confidencialidad**, porque un archivo core es un volcado literal de la memoria del proceso, incluidas claves de sesión y secretos descifrados.

### El requisito arquitectónico

Un host de producción debe satisfacer tres propiedades simultáneamente:

1. **Radio de impacto acotado** — ningún servicio, sesión o inquilino individual puede degradar a otro por debajo de su SLO, sin importar si la causa es un bug o un atacante.
2. **Degradación determinista** — cuando se alcanza un límite, la falla debe ocurrir *dentro* de la unidad infractora (throttling, `ENOMEM`, `EAGAIN`, OOM kill dirigido), nunca una heurística global que elige una víctima que vos no elegiste.
3. **Aplicación auditable** — el límite debe ser observable en tiempo de ejecución desde la propia contabilidad del kernel, no inferido desde archivos de configuración. La configuración que silenciosamente no se aplica es el modo de falla dominante en este tema.

Linux te da **tres planos de aplicación distintos** para satisfacer esto, y confundirlos es la mayor fuente individual de incidentes en producción y de errores en el examen.

---

## 2. Los tres planos de aplicación

```
                       ┌───────────────────────────────────────┐
   PLANE 3             │  systemd resource control             │  policy / API
   (management)        │  .slice  .scope  .service, drop-ins   │
                       └──────────────┬────────────────────────┘
                                      │ writes
                       ┌──────────────▼────────────────────────┐
   PLANE 2             │  cgroups v2 (unified hierarchy)       │  group accounting
   (kernel, group)     │  /sys/fs/cgroup/**                    │  + enforcement
                       └───────────────────────────────────────┘
                       ┌───────────────────────────────────────┐
   PLANE 1             │  POSIX rlimits (setrlimit(2))         │  per-process
   (kernel, process)   │  ulimit, prlimit, pam_limits.so       │  enforcement
                       └───────────────────────────────────────┘
```

| Dimensión | rlimits (Plano 1) | cgroups v2 (Plano 2) | systemd (Plano 3) |
|---|---|---|---|
| Unidad de aplicación | Un proceso (unos pocos son por UID) | Un grupo de procesos, jerárquicamente | Una unidad (service/scope/slice) |
| Se define con | `setrlimit(2)`, `ulimit`, `prlimit`, `pam_limits.so` | Escribiendo archivos en `/sys/fs/cgroup/**` | Directivas de unidad, `systemctl set-property`, D-Bus |
| Herencia | Copiados en `fork()`/`execve()`; los cambios **no** se propagan a los hijos en ejecución | En vivo: movés un PID al cgroup y queda sujeto de inmediato | En vivo, vía Plano 2 |
| ¿Se aplica retroactivamente? | **No** — un proceso en ejecución conserva sus límites salvo que uses `prlimit --pid` | **Sí** | **Sí** |
| Contabilidad agregada | No — 100 procesos × 1 GB de `RLIMIT_AS` = 100 GB | Sí — el total del grupo es el límite | Sí |
| Estilo de aplicación | Falla dura (`ENOMEM`, `EMFILE`, `EAGAIN`, `SIGXCPU`, `SIGXFSZ`) | Throttle, reclaim, contrapresión, **o** OOM kill dirigido | Igual que el Plano 2 |
| Ancho de banda de CPU / IO | Solo *tiempo* total de CPU (`RLIMIT_CPU`), sin tasa | Sí — tasa, peso, objetivos de latencia | Sí |
| Sobrevive al reinicio del demonio | Solo si se reaplica | El cgroup es recreado por systemd | Sí (archivo de unidad / drop-in) |
| Se aplica a servicios de systemd | **Solo** vía directivas `Limit*=` — **nunca** vía `limits.conf` | Sí | Sí |
| Se aplica a logins interactivos | Sí, vía `pam_limits.so` | Sí, vía `user-<UID>.slice` | Sí |
| Término de examen | `ulimit`, `limits.conf`, `pam_limits.so` | `/sys/fs/cgroup/` | `systemd-run`, `systemctl set-property`, `systemd-cgls`, `systemd-cgtop` |

**La regla que resuelve el 80 % de los incidentes reales:** `/etc/security/limits.conf` lo aplica un **módulo de sesión de PAM**. Un servicio de sistema de systemd no tiene sesión PAM. Por lo tanto `limits.conf` tiene efecto *cero* sobre `nginx.service`, `mysqld.service`, o cualquier otra cosa iniciada por PID 1. Para servicios usás `LimitNOFILE=`, `LimitNPROC=`, `LimitCORE=` en la unidad. Esto se examina, y es lo primero que hay que revisar cuando "subí nofile y sigue diciendo too many open files".

---

## 3. Plano 1 — Límites de recursos POSIX (rlimits)

### 3.1 Mecánica

Cada tarea tiene una `struct rlimit[RLIM_NLIMITS]` en su estructura de señales, y cada entrada es un par:

```c
struct rlimit {
    rlim_t rlim_cur;  /* soft limit — the value actually enforced      */
    rlim_t rlim_max;  /* hard limit — the ceiling on rlim_cur          */
};
```

Las reglas, exactamente:

- Un proceso sin privilegios puede **subir el límite soft hasta el límite hard**, y puede **bajar el límite hard de forma irreversible**.
- Subir un límite hard requiere `CAP_SYS_RESOURCE` (en el user namespace del proceso).
- Los límites se copian en `fork()` y se preservan a través de `execve()`. Por eso se **heredan del shell de login**, y por eso el built-in `ulimit` del shell es donde los humanos se topan con ellos.
- `prlimit(2)` (Linux ≥ 2.6.36) le permite a un proceso privilegiado cambiar los límites de un proceso **en ejecución** — la única forma de arreglar un demonio de larga vida sin reiniciarlo.
- `RLIMIT_NPROC` es **por UID real y a nivel de todo el sistema**, no por sesión y no por cgroup. Dos servicios que corren con el mismo usuario comparten el contador. Esto hace que `LimitNPROC=` sea casi inútil para aislar servicios; usá `TasksMax=` en su lugar.
- Root (`CAP_SYS_RESOURCE`) **evita** por completo las verificaciones de `RLIMIT_NPROC` y `RLIMIT_MEMLOCK`.

### 3.2 La tabla completa de límites

| `ulimit` | `RLIMIT_*` | Unidad | Aplicación al excederse | Relevancia de seguridad |
|---|---|---|---|---|
| `-c` | `CORE` | bloques de 512 B | Core dump truncado / suprimido | **Previene divulgación de memoria**; poné `0` para demonios que manejan secretos |
| `-d` | `DATA` | KiB | `brk()`/`mmap` del segmento de datos falla | Débil; los asignadores modernos usan `mmap` |
| `-e` | `NICE` | techo `20 - nice` | `setpriority()` devuelve `EACCES` | Frena el abuso por inversión de prioridad |
| `-f` | `FSIZE` | bloques de 512 B | `SIGXFSZ`, luego `EFBIG` | Acota el DoS por llenado de disco de un único escritor |
| `-i` | `SIGPENDING` | cantidad | `sigqueue()` devuelve `EAGAIN` | DoS por inundación de señales |
| `-l` | `MEMLOCK` | bytes | `mlock()`/`mlockall()` devuelve `ENOMEM` | DoS por memoria no swappeable; hay que subirlo para `gpg-agent`, DPDK, bases de datos |
| `-m` | `RSS` | KiB | **Sin efecto desde Linux 2.4.30** | Trampa — los candidatos lo configuran y no pasa nada |
| `-n` | `NOFILE` | cantidad | `open()`/`accept()`/`socket()` devuelven `EMFILE` | DoS por agotamiento de FD; también limita `select()` a 1024 fds |
| `-q` | `MSGQUEUE` | bytes | `mq_open()` devuelve `ENOMEM` | Fijación de memoria del kernel |
| `-r` | `RTPRIO` | prioridad | `sched_setscheduler()` devuelve `EPERM` | **Crítico**: una tarea `SCHED_FIFO` sin límite deja sin CPU a todo el sistema |
| `-s` | `STACK` | KiB | `SIGSEGV` al desbordar | Contención de caídas por recursión profunda |
| `-t` | `CPU` | segundos | `SIGXCPU` en el soft, `SIGKILL` en el hard | Acota bucles infinitos en trabajos batch |
| `-u` | `NPROC` | cantidad | `fork()` devuelve `EAGAIN` | Defensa contra fork bombs **por UID**, root exento |
| `-v` | `AS` | KiB | `mmap()`/`brk()` devuelven `ENOMEM` | Tope de memoria burdo — **rompe JVM/Go**, que reservan arenas virtuales enormes |
| `-x` | `LOCKS` | cantidad | `flock()` falla | Heredado, sin efecto sobre locks POSIX |
| `-T` | `RTTIME` | µs | `SIGXCPU` en una tarea RT que no cede | Watchdog de tiempo real |

> **Nota arquitectónica sobre `-v` (`RLIMIT_AS`).** Limita el *espacio de direcciones virtual*, no la memoria residente. El runtime de Go reserva cientos de GiB de arena virtual; la JVM reserva de entrada todo el heap más el metaspace. Poner `RLIMIT_AS` en "2 GB" en cualquiera de los dos produce una caída inmediata al arrancar que no se parece en nada a un límite de memoria. **Nunca uses `RLIMIT_AS` como tope de memoria en un runtime moderno — usá `MemoryMax=` (cgroup v2), que contabiliza páginas residentes.**

### 3.3 Leer y establecer límites

```
$ ulimit -a
real-time non-blocking time  (microseconds, -R) unlimited
core file size              (blocks, -c) 0
data seg size               (kbytes, -d) unlimited
scheduling priority                 (-e) 0
file size                   (blocks, -f) unlimited
pending signals                     (-i) 30465
max locked memory           (kbytes, -l) 8192
max memory size             (kbytes, -m) unlimited
open files                          (-n) 1024
pipe size                (512 bytes, -p) 8
POSIX message queues         (bytes, -q) 819200
real-time priority                  (-r) 0
stack size                  (kbytes, -s) 8192
cpu time                   (seconds, -t) unlimited
max user processes                  (-u) 30465
virtual memory              (kbytes, -v) unlimited
file locks                          (-x) unlimited
```

`-S` muestra/establece el límite soft (el valor por defecto al mostrar), `-H` el hard:

```
$ ulimit -Sn
1024
$ ulimit -Hn
524288
$ ulimit -n 65536      # raise soft up to hard — allowed, unprivileged
$ ulimit -Sn
65536
$ ulimit -Hn 4096      # lower the hard limit — allowed, IRREVERSIBLE
$ ulimit -Hn 8192
bash: ulimit: open files: cannot modify limit: Operation not permitted
```

La vista autoritativa por proceso — esto es lo que inspeccionás durante un incidente, nunca el archivo de configuración:

```
$ cat /proc/1421/limits
Limit                     Soft Limit           Hard Limit           Units
Max cpu time              unlimited            unlimited            seconds
Max file size             unlimited            unlimited            bytes
Max data size             unlimited            unlimited            bytes
Max stack size            8388608              unlimited            bytes
Max core file size        0                    unlimited            bytes
Max resident set          unlimited            unlimited            bytes
Max processes             30465                30465                processes
Max open files            1024                 524288               files
Max locked memory         8388608              8388608              bytes
Max address space         unlimited            unlimited            bytes
Max file locks            unlimited            unlimited            locks
Max pending signals       30465                30465                signals
Max msgqueue size         819200               819200               bytes
Max nice priority         0                    0
Max realtime priority     0                    0
Max realtime timeout      unlimited            unlimited            us
```

`prlimit(1)` de util-linux — consultar, cambiar en caliente, o lanzar con un límite:

```
$ prlimit --pid 1421 --nofile
RESOURCE DESCRIPTION                   SOFT   HARD UNITS
NOFILE   max number of open files      1024 524288 files

# Fix a running daemon without restarting it (requires CAP_SYS_RESOURCE)
$ sudo prlimit --pid 1421 --nofile=65536:524288
$ grep 'Max open files' /proc/1421/limits
Max open files            65536                524288               files

# Launch a command under an explicit limit
$ prlimit --nproc=64 --as=1073741824 -- /usr/local/bin/batch-import
```

Demostración en vivo de que los límites son reales, y de que soft y hard difieren:

```
$ ulimit -Sn 3
$ exec 9< /etc/hostname
bash: /etc/hostname: Too many open files
$ ulimit -Sn 1024
$ exec 9< /etc/hostname && echo ok
ok
$ exec 9<&-
```

`RLIMIT_CPU` produciendo la señal en dos etapas, exactamente como está especificado:

```
$ prlimit --cpu=2:4 -- bash -c 'trap "echo SIGXCPU received >&2" XCPU; while :; do :; done'
SIGXCPU received
Killed
$ echo $?
137
```

Límite soft a los 2 s → `SIGXCPU` (capturable, tu oportunidad de hacer checkpoint y salir). Límite hard a los 4 s → `SIGKILL` (`128 + 9 = 137`).

### 3.4 `pam_limits.so` y `/etc/security/limits.conf`

`pam_limits.so` es un módulo de **sesión**. Durante el establecimiento de la sesión PAM (después de la autenticación, antes de que se lance el shell) parsea `/etc/security/limits.conf` y `/etc/security/limits.d/*.conf` y llama a `setrlimit(2)` para las entradas coincidentes. Todo lo que esté aguas abajo de esa sesión los hereda.

**Formato del archivo:**

```
<domain>      <type>  <item>  <value>
```

| Campo | Valores aceptados |
|---|---|
| `domain` | nombre de usuario · `@groupname` · `*` (por defecto, **excluye a root**) · `%` o `%group` (solo `maxlogins`) · rango de UID `1000:2000` · `@1000:2000` (rango de GID) · `:1000` (0…1000) · `1000:` (1000…∞) |
| `type` | `soft` · `hard` · `-` (ambos a la vez) |
| `item` | `core fsize data stack cpu nproc as memlock nofile rss locks sigpending msgqueue nice rtprio rttime maxlogins maxsyslogins priority chroot` |
| `value` | entero · `-1` / `unlimited` / `infinity` (no válido para `nice`, `priority`, `nofile`) |

**Precedencia:** `pam_limits` ordena las coincidencias por especificidad — una entrada que nombra literalmente al **usuario** prevalece sobre una entrada `@group`, que prevalece sobre el valor por defecto `*` — con independencia del orden de las líneas. Entre entradas de igual especificidad gana la última parseada, y `limits.d/*.conf` se parsea después de `limits.conf`, en orden lexicográfico de nombre de archivo. Confirmalo en tu build con la opción `debug` de `pam_limits` (§7.4) en vez de confiar en la documentación.

Archivo de producción para un bastión compartido / host de aplicaciones multi-inquilino:

```conf
# /etc/security/limits.d/50-hardening.conf
#
# Baseline for every interactive and PAM-mediated session.
# Enforced ONLY through pam_limits.so — has NO effect on systemd services.
# Service limits live in unit files (see /etc/systemd/system/*.d/).

# --- 1. Confidentiality: never write process memory to disk -----------------
#     A core file of a TLS terminator or a gpg-agent is a key disclosure.
*               hard    core            0
root            hard    core            0

# --- 2. Availability: fork-bomb containment ---------------------------------
#     RLIMIT_NPROC is per-UID and system-wide; root is exempt by design.
*               soft    nproc           1024
*               hard    nproc           2048
@developers     soft    nproc           2048
@developers     hard    nproc           4096
@ci-runner      -       nproc           512

# --- 3. Availability: FD exhaustion ----------------------------------------
#     Soft stays modest so legacy select()-based code does not corrupt fd_set;
#     the hard limit lets a well-behaved process raise its own soft limit.
*               soft    nofile          4096
*               hard    nofile          65536
@developers     soft    nofile          16384
@developers     hard    nofile          262144

# --- 4. Availability: unswappable memory and real-time starvation ----------
*               hard    memlock         65536
*               hard    rtprio          0
@audio          hard    rtprio          95
@audio          hard    memlock         unlimited

# --- 5. Session count: bound concurrent logins per human -------------------
@contractors    -       maxlogins       2
*               -       maxsyslogins    50

# --- 6. Batch/untrusted accounts: bounded CPU and file size ----------------
@batch          soft    cpu             30
@batch          hard    cpu             60
@batch          hard    fsize           2097152          # 1 GiB in 512-B blocks
```

**El stack tiene que cargar el módulo de verdad.** En sistemas de la familia Red Hat:

```
$ grep -rn pam_limits /etc/pam.d/
/etc/pam.d/system-auth:26:session     required      pam_limits.so
/etc/pam.d/password-auth:24:session   required      pam_limits.so
/etc/pam.d/runuser:6:session          required      pam_limits.so
```

En sistemas de la familia Debian la cadena de includes es `/etc/pam.d/common-session`:

```
# /etc/pam.d/common-session
session [default=1]     pam_permit.so
session requisite       pam_deny.so
session required        pam_permit.so
session optional        pam_systemd.so
session required        pam_unix.so
session required        pam_limits.so
```

**Trampas que deciden preguntas de examen y caídas:**

| Síntoma | Causa |
|---|---|
| Los límites se aplican en el login por consola pero no por SSH | `sshd` compilado sin PAM, o `UsePAM no` en `sshd_config` |
| Los límites se aplican con `su -` pero no con `su` | Archivos PAM distintos (`/etc/pam.d/su-l` vs `/etc/pam.d/su`), o el shell sin login nunca releyó la sesión |
| Los límites se aplican a los usuarios pero no a root | `*` excluye explícitamente a root — tenés que escribir entradas `root` |
| El límite `nproc` "se filtra" entre dos servicios | `RLIMIT_NPROC` es por UID, contado a nivel de host, incluyendo hilos |
| `limits.conf` ignorado para `nginx` | Servicio de systemd — sin sesión PAM. Usá `LimitNOFILE=` |
| `nproc` en `limits.conf` silenciosamente sobrescrito | `/etc/security/limits.d/20-nproc.conf` trae un `*  soft  nproc  4096` en RHEL |
| Los trabajos de `cron` ignoran los límites | Solo si `pam_limits.so` falta en `/etc/pam.d/crond` |

### 3.5 rlimits para unidades de systemd

El mismo mecanismo del kernel, una superficie de configuración completamente distinta. Cada directiva `Limit*=` acepta o bien un valor (soft y hard a la vez) o bien `soft:hard`:

```ini
LimitNOFILE=65536:524288
LimitCORE=0
LimitNPROC=512
LimitMEMLOCK=infinity
```

Los valores por defecto vienen de `/etc/systemd/system.conf` (`DefaultLimitNOFILE=`, `DefaultLimitCORE=`, …). Desde systemd v240 el valor por defecto que se distribuye es `DefaultLimitNOFILE=1024:524288` — un límite **soft** deliberadamente bajo para que los programas basados en `select(2)` no puedan corromper su `fd_set`, con un límite **hard** alto para que los programas modernos puedan subir el suyo.

> **`LimitNOFILE=infinity` es un bug, no una configuración.** Se resuelve a `/proc/sys/fs/nr_open` (1 048 576 por defecto, hasta 2³⁰). Varios runtimes iteran `0..RLIMIT_NOFILE` para cerrar descriptores heredados al arrancar, convirtiendo el arranque en un bucle ocupado de varios segundos. Poné siempre un número concreto.

---

## 4. Plano 2 — Grupos de control

### 4.1 v1 versus v2

| Propiedad | cgroup v1 | cgroup v2 (unificado) |
|---|---|---|
| Jerarquías | Una **por controlador**; un proceso puede estar en lugares no relacionados en cada una | **Una** jerarquía para todos los controladores |
| Disposición de montaje | `tmpfs` en `/sys/fs/cgroup`, un fs `cgroup` por subdirectorio de controlador | Un único fs `cgroup2` en `/sys/fs/cgroup` |
| Detección | `stat -fc %T /sys/fs/cgroup/` → `tmpfs` | `stat -fc %T /sys/fs/cgroup/` → `cgroup2fs` |
| Habilitación de controladores | En el montaje, global | Por subárbol vía `cgroup.subtree_control` |
| Procesos en nodos internos | Permitido (atribución ambigua de recursos) | **Prohibido** (regla "no internal processes"), salvo en la raíz |
| Granularidad de hilos | Nativa (cualquier controlador) | Solo en subárboles *threaded* explícitos; `cpu`, `cpuset`, `perf_event` |
| Memoria + swap | `memory.limit_in_bytes` + `memsw` (necesita `swapaccount=1`) | `memory.max` y `memory.swap.max` — **separados e independientes** |
| Contrapresión de memoria | Ninguna — tenés el límite o el OOM killer | `memory.high` (throttle+reclaim) antes de `memory.max` (kill) |
| Pisos de protección | Ninguno | `memory.min` (duro), `memory.low` (best-effort) |
| Contabilidad de writeback / IO bufferizado | Rota — las escrituras bufferizadas se atribuyen a `kworker` | Correcta — los controladores memory e io cooperan |
| Métricas de presión (PSI) | No | `cpu.pressure`, `memory.pressure`, `io.pressure` por cgroup |
| Delegación a usuarios sin privilegios | Insegura | Segura y diseñada para eso (`nsdelegate`, `Delegate=`) |
| Freezer | `freezer.state` | `cgroup.freeze` |
| Kill masivo | No atómico | `cgroup.kill` (Linux ≥ 5.14) |
| Estado | Obsoleto; el kernel lo mantiene en modo mantenimiento | El valor por defecto en RHEL 9+, Fedora 31+, Debian 11+, Ubuntu 21.10+ |

**La propiedad de v2 que cambia la arquitectura:** contabilidad unificada de page cache, writeback bufferizado y memoria anónima. En v1, un contenedor que escribía 4 GB a través del page cache cargaba sus páginas sucias a los hilos de writeback del kernel, así que su límite `blkio` no hacía nada. En v2 esa escritura se carga al cgroup que la originó y se limita por su `io.max`. Cualquier aislamiento de IO multi-inquilino real requiere v2.

Determinar, y de ser necesario cambiar, el modo:

```
$ stat -fc %T /sys/fs/cgroup/
cgroup2fs

$ mount | grep cgroup
cgroup2 on /sys/fs/cgroup type cgroup2 (rw,nosuid,nodev,noexec,relatime,nsdelegate,memory_recursiveprot)

$ grep cgroup /proc/filesystems
nodev	cgroup
nodev	cgroup2
```

Si informa `tmpfs`, el host está en v1 (o híbrido). Forzar el modo unificado:

```
$ sudo grubby --update-kernel=ALL --args="systemd.unified_cgroup_hierarchy=1"
$ sudo reboot
```

Forzar el modo legacy v1 (solo para una carga heredada que no podés portar):

```
$ sudo grubby --update-kernel=ALL --args="systemd.unified_cgroup_hierarchy=0"
```

En hosts v1 que deban contabilizar swap, el controlador de memoria necesita ayuda en algunas distribuciones:

```
GRUB_CMDLINE_LINUX="cgroup_enable=memory swapaccount=1"
```

### 4.2 Anatomía de la jerarquía unificada

```
$ ls -1 /sys/fs/cgroup/
cgroup.controllers
cgroup.max.depth
cgroup.max.descendants
cgroup.pressure
cgroup.procs
cgroup.stat
cgroup.subtree_control
cgroup.threads
cpu.pressure
cpu.stat
cpuset.cpus.effective
cpuset.mems.effective
init.scope
io.cost.model
io.cost.qos
io.pressure
io.stat
machine.slice
memory.numa_stat
memory.pressure
memory.reclaim
memory.stat
misc.capacity
system.slice
user.slice

$ cat /sys/fs/cgroup/cgroup.controllers
cpuset cpu io memory hugetlb pids rdma misc

$ cat /sys/fs/cgroup/cgroup.subtree_control
cpuset cpu io memory pids
```

`cgroup.controllers` es lo que está *disponible* acá; `cgroup.subtree_control` es lo que está *habilitado para mis hijos*. Un controlador debe estar habilitado en cada ancestro antes de que una hoja pueda usarlo — esta es la regla de "habilitación de arriba hacia abajo", y olvidarla produce el clásico `echo: write error: No such file or directory`.

Dos reglas estructurales que el examen indaga:

1. **Nada de procesos internos.** Un cgroup que no es la raíz puede contener **o bien** procesos **o bien** controladores habilitados para sus hijos, nunca ambos. Por eso systemd pone cada servicio en su propia hoja y nunca en el slice mismo.
2. **Restricción de arriba hacia abajo, contabilidad de abajo hacia arriba.** Los límites se aplican a lo largo de todo el camino: el techo efectivo de una hoja es el mínimo entre sus ancestros. El uso se suma hacia arriba.

Los archivos de interfaz principales presentes en **todos** los cgroups:

| Archivo | Significado |
|---|---|
| `cgroup.procs` | L: PIDs en este cgroup. E: escribí **un** PID para migrarlo (mueve todo el grupo de hilos) |
| `cgroup.threads` | Lo mismo, por hilo; solo tiene sentido en subárboles threaded |
| `cgroup.type` | `domain`, `domain threaded`, `threaded`, `domain invalid` |
| `cgroup.controllers` | Controladores disponibles acá (definidos por el `subtree_control` del padre) |
| `cgroup.subtree_control` | Controladores habilitados para los hijos; se escribe `+cpu -io` |
| `cgroup.events` | `populated 0|1`, `frozen 0|1` — consultable con `inotify`/`poll(2)` |
| `cgroup.freeze` | Escribí `1` para el equivalente a SIGSTOP sobre todo el subárbol, atómicamente |
| `cgroup.kill` | Escribí `1` para hacer SIGKILL a todas las tareas del subárbol, atómicamente (≥ 5.14) |
| `cgroup.max.depth` / `cgroup.max.descendants` | **Anti-fork-bomb para los cgroups mismos** — acota un subárbol delegado |
| `cgroup.stat` | `nr_descendants`, `nr_dying_descendants` |
| `*.pressure` | Métricas de estancamiento PSI para este subárbol |

### 4.3 El controlador de memoria: cinco perillas, no una

Esta es la tabla más importante del tema.

| Archivo | systemd | Semántica | Al superarse |
|---|---|---|---|
| `memory.min` | `MemoryMin=` | **Piso de protección duro.** La memoria por debajo de esto nunca se reclama | El reclaim saltea el grupo; puede llevar al *padre* a OOM |
| `memory.low` | `MemoryLow=` | **Piso best-effort.** Se reclama solo cuando no queda nada desprotegido | El grupo se reclama último |
| `memory.high` | `MemoryHigh=` | **Techo de throttling.** Reclaim agresivo + estancamiento deliberado del asignador | El proceso se ralentiza; **nunca lo matan** |
| `memory.max` | `MemoryMax=` | **Techo duro** | Reclaim, y después el **OOM killer de cgroup** sobre las propias tareas del grupo |
| `memory.swap.max` | `MemorySwapMax=` | Techo de swap, independiente de `memory.max` | Las páginas anónimas ya no pueden pasar a swap |

**El patrón de producción es `MemoryHigh` *por debajo* de `MemoryMax`.** `MemoryHigh` convierte un precipicio en una rampa: la carga se estrangula, la latencia sube, tu alerta se dispara, y un humano interviene — en lugar de un `SIGKILL` en medio de una transacción. `MemoryMax` es la red de contención que garantiza la contención. Configurar solo `MemoryMax` significa que el primer síntoma que vas a ver es un proceso muerto.

```
$ cd /sys/fs/cgroup/system.slice/nginx.service
$ cat memory.current memory.high memory.max memory.swap.current
201326592
1610612736
2147483648
0

$ cat memory.events
low 0
high 0
max 0
oom 0
oom_kill 0
oom_group_kill 0
```

`memory.events` es el **archivo de evidencia**. Que `high` suba significa que estás estrangulando; que `max` suba significa que las asignaciones están fallando; que `oom_kill` suba significa que el grupo mató a uno de los suyos. Una revisión de configuración que nunca lee este archivo es una suposición, no una verificación.

```
$ head -12 memory.stat
anon 142606336
file 50331648
kernel 8388608
kernel_stack 1310720
pagetables 2097152
percpu 42112
sock 262144
vmalloc 0
shmem 0
file_mapped 27262976
file_dirty 176128
file_writeback 0
```

`memory.oom.group=1` (systemd: `OOMPolicy=kill`) hace que el OOM killer de cgroup mate **todas** las tareas del grupo atómicamente. Usalo siempre que un árbol de procesos parcialmente muerto sea peor que uno muerto del todo — que es casi todo demonio multi-proceso, porque un master sobreviviente con workers muertos es un servicio zombi que igual pasa un health check de TCP.

### 4.4 El controlador cpu: peso versus cuota

| Archivo | systemd | Tipo | Comportamiento con el host ocioso |
|---|---|---|---|
| `cpu.weight` (1–10000, por defecto 100) | `CPUWeight=` | **Cuota relativa** | Sin efecto — el grupo usa todo lo que quiera |
| `cpu.max` (`"$QUOTA $PERIOD"` µs) | `CPUQuota=`, `CPUQuotaPeriodSec=` | **Techo absoluto** | **Igual se estrangula** |
| `cpu.max.burst` | `CPUQuotaBurst=` | Crédito para cargas con ráfagas | Absorbe picos cortos sin estrangular |
| `cpuset.cpus` | `AllowedCPUs=` | **Fijación** | Afinidad dura, relevante para NUMA |
| `cpu.idle` | `CPUWeight=idle` (v252+) | `SCHED_IDLE` para todo el grupo | Corre solo en CPUs que de otro modo estarían ociosas |

```
$ cat /sys/fs/cgroup/system.slice/render.service/cpu.max
150000 100000
```

150 000 µs de tiempo de CPU por período de 100 000 µs = **1,5 CPUs**, equivalente a `CPUQuota=150%`.

**La trampa del throttling.** `cpu.max` se aplica por período. Un servicio Java de 16 hilos con `CPUQuota=200%` agota su presupuesto de 200 ms en 12,5 ms de tiempo de reloj cuando todos los hilos corren, y después queda congelado los 87,5 ms restantes del período. La utilización promedio se ve correcta; la latencia p99 queda destruida. La evidencia:

```
$ cat /sys/fs/cgroup/system.slice/api.service/cpu.stat
usage_usec 91827364
user_usec 74829183
system_usec 16998181
nr_periods 43210
nr_throttled 31889
throttled_usec 2874651000
nr_bursts 0
burst_usec 0
```

`nr_throttled / nr_periods = 73,8 %` de los períodos estrangulados, 2 874 s de estancamiento acumulado. **Cualquier crecimiento de `nr_throttled` en un servicio sensible a la latencia es un defecto de producción.** Los tres arreglos, en orden de preferencia: (1) reemplazar `CPUQuota=` por `CPUWeight=` y dejar que el planificador arbitre solo bajo contención real; (2) acortar `CPUQuotaPeriodSec=` a 10–20 ms para que los estancamientos sean más breves; (3) limitar el propio pool de hilos del runtime (`GOMAXPROCS`, `-XX:ActiveProcessorCount`) para que coincida con la cuota.

**Usá `CPUWeight=` para aislamiento, y `CPUQuota=` solo cuando estés vendiendo una capacidad fija** (facturación, SLA de inquilino, o un trabajo batch deliberadamente limitado).

### 4.5 El controlador io

```
$ lsblk -o NAME,MAJ:MIN,SIZE,TYPE
NAME        MAJ:MIN  SIZE TYPE
nvme0n1     259:0   931.5G disk
├─nvme0n1p1 259:1     600M part
├─nvme0n1p2 259:2       1G part
└─nvme0n1p3 259:3   929.9G part

$ echo "259:0 rbps=104857600 wbps=52428800 riops=2000 wiops=1000" \
    | sudo tee /sys/fs/cgroup/tenant.slice/io.max
259:0 rbps=104857600 wbps=52428800 riops=2000 wiops=1000

$ cat /sys/fs/cgroup/tenant.slice/io.stat
259:0 rbytes=8471347200 wbytes=2147483648 rios=41230 wios=18827 dbytes=0 dios=0
```

| Mecanismo | Archivo | Carácter |
|---|---|---|
| Tope duro de ancho de banda/IOPS | `io.max` | Absoluto, por dispositivo, desperdicia capacidad ociosa |
| Cuota proporcional | `io.weight` (1–10000) | Solo bajo contención; necesita `bfq` o `io.cost` |
| Objetivo de latencia | `io.latency` | Protege a un grupo estrangulando a *los otros* cuando su latencia se degrada |
| Modelo de costo | `io.cost.qos`, `io.cost.model` | Control proporcional calibrado al dispositivo (`iocost`) |

`io.max` requiere el **major:minor del dispositivo físico**, nunca una partición ni un nodo de device-mapper — estrangular `dm-0` mientras el sistema de archivos emite IO a `259:3` no hace absolutamente nada.

### 4.6 El controlador pids — el interruptor contra fork bombs

```
$ cat /sys/fs/cgroup/user.slice/user-1000.slice/pids.max
10813
$ cat /sys/fs/cgroup/user.slice/user-1000.slice/pids.current
94
$ cat /sys/fs/cgroup/user.slice/user-1000.slice/pids.events
max 0
```

A diferencia de `RLIMIT_NPROC`, `pids.max` es **por cgroup, jerárquico, cuenta hilos, y root no está exento**. Es la única defensa correcta contra fork bombs en un host moderno. `RLIMIT_NPROC` sigue siendo útil como respaldo por UID; no es un sustituto.

### 4.7 Laboratorio manual de cgroup v2 — sin systemd

Esto es el "entender y configurar cgroups" del objetivo en su forma más cruda.

```
# 1. Enable the controllers we need for our children.
$ sudo mkdir -p /sys/fs/cgroup/lab
$ echo "+cpu +memory +pids +io" | sudo tee /sys/fs/cgroup/cgroup.subtree_control
+cpu +memory +pids +io

# 2. The child inherits availability, and must in turn enable them for ITS children.
$ cat /sys/fs/cgroup/lab/cgroup.controllers
cpuset cpu io memory pids

# 3. Apply limits: 0.25 CPU, 64 MiB RAM hard / 48 MiB throttle, no swap, 20 tasks.
$ echo "25000 100000" | sudo tee /sys/fs/cgroup/lab/cpu.max
25000 100000
$ echo 50331648        | sudo tee /sys/fs/cgroup/lab/memory.high
50331648
$ echo 67108864        | sudo tee /sys/fs/cgroup/lab/memory.max
67108864
$ echo 0               | sudo tee /sys/fs/cgroup/lab/memory.swap.max
0
$ echo 20              | sudo tee /sys/fs/cgroup/lab/pids.max
20
$ echo 1               | sudo tee /sys/fs/cgroup/lab/memory.oom.group
1

# 4. Move the current shell in and verify the migration.
$ echo $$ | sudo tee /sys/fs/cgroup/lab/cgroup.procs
4711
$ cat /proc/self/cgroup
0::/lab
```

Verificá el techo de memoria con un asignador determinista:

```
$ python3 -c "b = bytearray(200*1024*1024); print(len(b))"
Killed
$ cat /sys/fs/cgroup/lab/memory.events
low 0
high 47
max 12
oom 1
oom_kill 1
oom_group_kill 1
```

`high 47` — el throttling se activó 47 veces primero. `max 12` — doce intentos de asignación chocaron contra el muro duro. `oom_kill 1` — se disparó el OOM killer **local del cgroup**. Fijate en lo que *no* pasó: ningún proceso ajeno del host fue tocado. Ese es todo el punto arquitectónico.

```
$ sudo dmesg -T | tail -6
[Mon Aug 24 11:42:07 2026] python3 invoked oom-killer: gfp_mask=0x140cca(GFP_HIGHUSER_MOVABLE|__GFP_COMP), order=0, oom_score_adj=0
[Mon Aug 24 11:42:07 2026] memory: usage 65536kB, limit 65536kB, failcnt 12
[Mon Aug 24 11:42:07 2026] swap: usage 0kB, limit 0kB, failcnt 0
[Mon Aug 24 11:42:07 2026] Memory cgroup stats for /lab: anon:64512KB file:512KB kernel:512KB
[Mon Aug 24 11:42:07 2026] Tasks state (memory values in pages):
[Mon Aug 24 11:42:07 2026] Memory cgroup out of memory: Killed process 4993 (python3) total-vm:271488kB, anon-rss:65024kB, file-rss:3584kB, shmem-rss:0kB, UID:0 pgtables:216kB oom_score_adj:0
```

Verificá el techo de CPU:

```
$ timeout 10 bash -c 'while :; do :; done' &
[1] 5102
$ sleep 5; grep -E 'nr_throttled|throttled_usec' /sys/fs/cgroup/lab/cpu.stat
nr_throttled 49
throttled_usec 3712004
$ top -b -n1 -p 5102 | tail -2
    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
   5102 root      20   0    9068   3712   3200 R  25.0   0.0   0:01.26 bash
```

Verificá el techo de PIDs — la fork bomb queda contenida, y el shell sobrevive:

```
$ bash -c ':(){ :|:& };:' &
[2] 5210
bash: fork: retry: Resource temporarily unavailable
bash: fork: retry: Resource temporarily unavailable
$ cat /sys/fs/cgroup/lab/pids.current /sys/fs/cgroup/lab/pids.events
20
max 1483

# Atomic cleanup — Linux >= 5.14
$ echo 1 | sudo tee /sys/fs/cgroup/lab/cgroup.kill
1
$ cat /sys/fs/cgroup/lab/pids.current
0
```

Desmontaje (un cgroup debe estar vacío; solo `rmdir`, nunca `rm -r`):

```
$ echo $$ | sudo tee /sys/fs/cgroup/cgroup.procs > /dev/null
$ sudo rmdir /sys/fs/cgroup/lab
```

> **Recuadro sobre lo heredado (`libcgroup`).** `cgcreate`, `cgset`, `cgexec`, `cgclassify`, `cgconfigparser` con `/etc/cgconfig.conf` y `/etc/cgrules.conf` eran el espacio de usuario de la era v1. En un host con systemd **entran en conflicto con PID 1**, que es dueño de la jerarquía y va a sobrescribir o borrar grupos que no creó. Reconocé las herramientas para el examen; en un host con systemd, gestioná los cgroups a través de systemd o de un subárbol correctamente marcado con `Delegate=`.

---

## 5. Plano 3 — Control de recursos de systemd

### 5.1 Slices, scopes, services

systemd es el único dueño legítimo de la jerarquía de cgroups en un host moderno — esta es la "regla del escritor único" de `systemd.io`. Expone tres tipos de unidad que se mapean directamente sobre directorios de cgroup:

| Tipo de unidad | Rol de cgroup | Creada por | Ejemplo |
|---|---|---|---|
| `.slice` | **Nodo interno.** No contiene procesos; lleva los límites del subárbol | Administrador / systemd | `system.slice`, `user-1000.slice`, `tenant.slice` |
| `.service` | **Hoja.** Procesos que el propio systemd forkeó | Archivo de unidad | `nginx.service` |
| `.scope` | **Hoja.** Procesos forkeados por *otro*, registrados con systemd | Registro D-Bus (`logind`, `machined`, `podman`) | `session-3.scope`, `libpod-<id>.scope` |

El árbol por defecto:

```
-.slice                        (root)
├── init.scope                 PID 1 itself
├── system.slice               all system services
├── user.slice
│   └── user-1000.slice
│       ├── user@1000.service  the per-user systemd manager
│       │   ├── app.slice
│       │   ├── session.slice
│       │   └── background.slice
│       └── session-3.scope    the actual login session
└── machine.slice              VMs and containers (machined, podman, nspawn)
```

`Slice=` en una unidad la ubica donde quieras; los nombres de slice codifican la jerarquía con `-`, así que `tenant-web-blue.slice` vive en `/tenant.slice/tenant-web.slice/tenant-web-blue.slice` y **cada slice intermedio debe existir** (systemd los auto-instancia desde plantillas de `-.slice`, pero conviene definirlos explícitamente para que lleven límites).

```
$ systemd-cgls
Control group /:
-.slice
├─user.slice
│ └─user-1000.slice
│   ├─user@1000.service …
│   │ ├─session.slice
│   │ │ ├─dbus-broker.service
│   │ │ │ ├─2461 /usr/bin/dbus-broker-launch --scope user
│   │ │ │ └─2464 dbus-broker --log 4 --controller 10 --machine-id …
│   │ │ └─pipewire.service
│   │ │   └─2455 /usr/bin/pipewire
│   │ └─init.scope
│   │   ├─2440 /usr/lib/systemd/systemd --user
│   │   └─2443 (sd-pam)
│   └─session-3.scope
│     ├─2437 "sshd-session: dalmine [priv]"
│     ├─2452 "sshd-session: dalmine@pts/0"
│     ├─2453 -bash
│     └─2712 systemd-cgls
├─init.scope
│ └─1 /usr/lib/systemd/systemd --switched-root --system --deserialize=48
└─system.slice
  ├─nginx.service
  │ ├─1421 "nginx: master process /usr/sbin/nginx"
  │ ├─1422 "nginx: worker process"
  │ └─1423 "nginx: worker process"
  ├─sshd.service
  │ └─1198 "sshd: /usr/sbin/sshd -D [listener] 0 of 10-100 startups"
  └─systemd-journald.service
    └─892 /usr/lib/systemd/systemd-journald
```

```
$ systemd-cgtop -n 2 --depth=2
Control Group                          Tasks   %CPU   Memory  Input/s Output/s
/                                        412   14.3     3.2G        -        -
system.slice                             201   11.8     2.1G        -        -
system.slice/postgresql.service           42    8.9     1.4G     1.2M   820.0K
user.slice                                88    2.1   712.4M        -        -
tenant.slice                              61    0.3   402.1M        -        -
machine.slice                             12    0.0    88.6M        -        -
```

`systemd-cgtop` informa `-` en una columna cuando la contabilidad correspondiente está apagada. `MemoryAccounting=` y `TasksAccounting=` son implícitos en cgroup v2 siempre que el controlador esté habilitado; `IOAccounting=` y `CPUAccounting=` pueden necesitar habilitarse. La contabilidad no es gratis — es barata, pero en un host con 200 servicios preferí `DefaultCPUAccounting=yes` deliberadamente antes que una proliferación por unidad.

### 5.2 Mapa directiva → archivo del kernel

Esta tabla *es* el tema. Memorizá las dos columnas de la izquierda.

| Directiva de systemd | Archivo de cgroup v2 | Notas |
|---|---|---|
| `CPUAccounting=` | (habilita `cpu`) | `cpu.stat` |
| `CPUWeight=`, `StartupCPUWeight=` | `cpu.weight` | 1–10000, por defecto 100; `idle` desde v252 |
| `CPUQuota=` | `cpu.max` (campo quota) | `200%` → `200000 100000` |
| `CPUQuotaPeriodSec=` | `cpu.max` (campo period) | Por defecto 100 ms |
| `AllowedCPUs=`, `StartupAllowedCPUs=` | `cpuset.cpus` | |
| `AllowedMemoryNodes=` | `cpuset.mems` | NUMA |
| `MemoryAccounting=` | (habilita `memory`) | |
| `MemoryMin=` | `memory.min` | Protección dura |
| `MemoryLow=` | `memory.low` | Protección best-effort |
| `MemoryHigh=` | `memory.high` | Throttle |
| `MemoryMax=` | `memory.max` | Tope duro → OOM de cgroup |
| `MemorySwapMax=` | `memory.swap.max` | |
| `MemoryZSwapMax=` | `memory.zswap.max` | v250+ |
| `TasksAccounting=` | (habilita `pids`) | |
| `TasksMax=` | `pids.max` | Absoluto o `N%` de `kernel.pid_max` |
| `IOAccounting=` | (habilita `io`) | `io.stat` |
| `IOWeight=`, `StartupIOWeight=` | `io.weight` | 1–10000 |
| `IODeviceWeight=` | `io.weight` por dispositivo | |
| `IOReadBandwidthMax=`, `IOWriteBandwidthMax=` | `io.max` `rbps=`/`wbps=` | Ruta o `maj:min` |
| `IOReadIOPSMax=`, `IOWriteIOPSMax=` | `io.max` `riops=`/`wiops=` | |
| `IODeviceLatencyTargetSec=` | `io.latency` | |
| `DeviceAllow=`, `DevicePolicy=` | programa eBPF de dispositivos de cgroup | v1: `devices.allow` |
| `Delegate=`, `DelegateSubgroup=` | propiedad de `cgroup.procs`, `cgroup.subtree_control` | |
| `OOMPolicy=kill` | `memory.oom.group=1` | |
| `ManagedOOMSwap=`, `ManagedOOMMemoryPressure=` | consumidos por `systemd-oomd` | Guiados por PSI |
| `Slice=` | directorio padre | |
| **`Limit*=`** | **ninguno — `setrlimit(2)`** | **Plano distinto. No confundir.** |

### 5.3 Aplicar límites: tres rutas

**Ruta 1 — `systemd-run`, para experimentos y trabajos puntuales.** Crea un scope o servicio transitorio; no persiste nada.

```
$ sudo systemd-run --unit=riskyjob --slice=untrusted.slice \
    -p MemoryMax=512M -p MemoryHigh=384M -p CPUQuota=25% \
    -p TasksMax=32 -p IOWriteBandwidthMax="/dev/nvme0n1 20M" \
    -p PrivateTmp=yes -p OOMPolicy=kill \
    /usr/local/bin/untrusted-importer /srv/incoming/batch.tar.zst
Running as unit: riskyjob.service; invocation ID: 8f2a1c9e4b7d43a08e21c3f5d6a9b0c1

$ systemctl status riskyjob.service
● riskyjob.service - /usr/local/bin/untrusted-importer /srv/incoming/batch.tar.zst
     Loaded: loaded (/run/systemd/transient/riskyjob.service; transient)
  Transient: yes
     Active: active (running) since Mon 2026-08-24 11:58:02 -03; 6s ago
   Main PID: 6142 (untrusted-impo)
      Tasks: 5 (limit: 32)
     Memory: 118.4M (high: 384.0M max: 512.0M available: 393.6M)
        CPU: 1.402s
     CGroup: /untrusted.slice/riskyjob.service
             └─6142 /usr/local/bin/untrusted-importer /srv/incoming/batch.tar.zst
```

Contención interactiva para un shell ad-hoc — una técnica de bastión genuinamente útil:

```
$ sudo systemd-run --pty --same-dir --wait --collect \
    --slice=untrusted.slice \
    -p MemoryMax=256M -p TasksMax=25 -p CPUQuota=20% \
    /bin/bash
Running as unit: run-u217.service
Press ^] three times within 1s to disconnect TTY.

# cat /proc/self/cgroup
0::/untrusted.slice/run-u217.service
# :(){ :|:& };:
bash: fork: retry: Resource temporarily unavailable
```

**Ruta 2 — `systemctl set-property`, para cambios en vivo.** Se aplica de inmediato *y* se persiste como drop-in.

```
$ sudo systemctl set-property nginx.service MemoryMax=2G MemoryHigh=1536M TasksMax=512
$ systemctl show nginx.service -p MemoryMax -p MemoryHigh -p TasksMax -p ControlGroup
ControlGroup=/system.slice/nginx.service
MemoryHigh=1610612736
MemoryMax=2147483648
TasksMax=512

$ cat /etc/systemd/system.control/nginx.service.d/50-MemoryMax.conf
# This is a drop-in unit file extension, created via "systemctl set-property"
# or an equivalent operation. Do not edit.
[Service]
MemoryMax=2147483648
```

`--runtime` escribe en `/run/systemd/system.control/` en su lugar y se evapora al reiniciar — la elección correcta durante un incidente, cuando querés un cambio que no sobreviva a la investigación:

```
$ sudo systemctl set-property --runtime postgresql.service IOWeight=200
```

**Ruta 3 — archivos drop-in, para gestión de configuración.** La única ruta que pertenece a Git.

```
$ sudo systemctl edit nginx.service
$ cat /etc/systemd/system/nginx.service.d/10-resources.conf
[Service]
MemoryHigh=1536M
MemoryMax=2G
$ sudo systemctl daemon-reload
```

`daemon-reload` reaplica las propiedades de cgroup a las unidades **en ejecución** sin reiniciarlas — uno de los pocos caminos de reconfiguración en vivo de Linux que realmente funciona.

### 5.4 Valores por defecto de todo el host

```ini
# /etc/systemd/system.conf.d/10-resource-defaults.conf
#
# Applies to every SYSTEM service unless the unit overrides it.
# Reboot required for Default* changes to reach already-running units.

[Manager]
# --- rlimit defaults (Plane 1) ---------------------------------------------
# Low soft limit protects select(2)-based code; high hard limit lets modern
# daemons raise their own. Never use "infinity".
DefaultLimitNOFILE=1024:524288
DefaultLimitNPROC=4096:8192
DefaultLimitMEMLOCK=64K
DefaultLimitCORE=0

# --- cgroup defaults (Plane 2/3) -------------------------------------------
# 15% of kernel.pid_max. Bounds any single service's fork storm.
DefaultTasksMax=15%

DefaultCPUAccounting=yes
DefaultMemoryAccounting=yes
DefaultIOAccounting=yes
DefaultTasksAccounting=yes

# Kill the whole cgroup rather than leaving a decapitated process tree that
# still answers TCP health checks.
DefaultOOMPolicy=kill
```

```
$ systemctl show --property=DefaultTasksMax --property=DefaultLimitNOFILE
DefaultTasksMax=4915
DefaultLimitNOFILE=1024
$ sysctl kernel.pid_max
kernel.pid_max = 32768
```

Para sesiones de usuario, el mecanismo moderno es un drop-in sobre la **plantilla** `user-.slice` (el viejo `UserTasksMax=` de `logind.conf` está obsoleto):

```ini
# /etc/systemd/system/user-.slice.d/50-limits.conf
[Slice]
TasksMax=4096
MemoryHigh=6G
MemoryMax=8G
CPUWeight=100
```

```
$ systemctl cat user-.slice | head -20
# /usr/lib/systemd/system/user-.slice
[Unit]
Description=User Slice of UID %j
Documentation=man:user@.service(5)
...
[Slice]
TasksMax=33%

# /etc/systemd/system/user-.slice.d/50-limits.conf
[Slice]
TasksMax=4096
MemoryHigh=6G
MemoryMax=8G
CPUWeight=100
```

### 5.5 `systemd-oomd` — OOM preventivo, guiado por presión

El OOM killer del kernel solo actúa cuando la asignación ya falló. Para entonces el host lleva decenas de segundos haciendo thrashing. `systemd-oomd` vigila el **PSI** (Pressure Stall Information) por cgroup y mata al peor infractor *antes* de que el kernel quede acorralado.

```ini
# /etc/systemd/oomd.conf.d/10-policy.conf
[OOM]
SwapUsedLimit=90%
DefaultMemoryPressureLimit=60%
DefaultMemoryPressureDurationSec=20s
```

```ini
# /etc/systemd/system/tenant.slice.d/20-oomd.conf
[Slice]
ManagedOOMSwap=kill
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=50%
ManagedOOMPreference=avoid
```

```
$ oomctl
Dry Run: no
Swap Used Limit: 90.00%
Default Memory Pressure Limit: 60.00%
Default Memory Pressure Duration: 20s
System Context:
	Swap: Used: 1.2G Total: 8.0G
Swap Monitored CGroups:
	Path: /
		Swap Usage: (see System Context)
Memory Pressure Monitored CGroups:
	Path: /tenant.slice
		Memory Pressure Limit: 50.00%
		Pressure: Avg10: 3.11 Avg60: 1.02 Avg300: 0.44 Total: 41s
		Current Memory Usage: 402.1M
		Memory Min: 0B
		Memory Low: 0B
		Swap Usage: 0B
```

```
$ cat /sys/fs/cgroup/tenant.slice/memory.pressure
some avg10=3.11 avg60=1.02 avg300=0.44 total=41022193
full avg10=0.87 avg60=0.31 avg300=0.09 total=12889341
```

`some` = al menos una tarea estancada por memoria; `full` = *todas* las tareas ejecutables estancadas — esa segunda línea es la que correlaciona con una caída visible para el usuario. PSI es el indicador adelantado correcto; `memory.current` es uno rezagado.

### 5.6 Delegación

Un gestor de cargas sin privilegios (Podman rootless, un agente de build, un systemd anidado) necesita crear sus propios sub-cgroups. `Delegate=` le entrega un subárbol y hace que systemd deje de gestionar dentro de él:

```ini
# /etc/systemd/system/buildkitd.service.d/20-delegate.conf
[Service]
Delegate=cpu cpuset io memory pids

# Bound the delegated subtree so a compromised agent cannot create cgroups forever
TasksMax=8192
MemoryMax=16G
CPUQuota=400%
```

```
$ ls -ld /sys/fs/cgroup/system.slice/buildkitd.service
drwxr-xr-x. 4 buildkit buildkit 0 Aug 24 12:10 /sys/fs/cgroup/system.slice/buildkitd.service
$ ls -l /sys/fs/cgroup/system.slice/buildkitd.service/cgroup.{procs,subtree_control,threads}
-rw-r--r--. 1 buildkit buildkit 0 Aug 24 12:10 .../cgroup.procs
-rw-r--r--. 1 buildkit buildkit 0 Aug 24 12:10 .../cgroup.subtree_control
-rw-r--r--. 1 buildkit buildkit 0 Aug 24 12:10 .../cgroup.threads
```

Exactamente tres archivos cambian de dueño — nunca los archivos de límites, así que el delegado **no puede subir su propio techo**. Combinado con la opción de montaje `nsdelegate` y con `cgroup.max.descendants` / `cgroup.max.depth`, esto es un límite de privilegio genuino. La delegación solo es segura en cgroup v2; el equivalente en v1 era un vector de escape conocido.

---

## 6. Construcción completa: un host de aplicaciones multi-inquilino endurecido

Modelo de amenaza: tres inquilinos comparten un host. El código de los inquilinos **no es confiable** — asumí que cualquier proceso de inquilino puede estar controlado por un atacante en cualquier momento. Requisito: ningún inquilino puede degradar a otro, y ningún inquilino puede degradar los servicios propios de la plataforma (SSH, journald, monitoreo).

### 6.1 Base de kernel y sysctl

```conf
# /etc/sysctl.d/60-resource-control.conf
#
# System-wide ceilings. These are the ultimate backstop: cgroup and rlimit
# percentages are computed against them, so they must be set FIRST.

# Global PID space. DefaultTasksMax=15% is derived from this value.
kernel.pid_max = 262144
kernel.threads-max = 262144

# Global file-descriptor ceiling and the per-process hard cap that
# LimitNOFILE=infinity resolves to.
fs.file-max = 2097152
fs.nr_open = 1048576

# inotify is a classic silent exhaustion vector (one watch per file, per user).
fs.inotify.max_user_instances = 512
fs.inotify.max_user_watches = 524288

# Confidentiality: never dump a setuid process's memory.
fs.suid_dumpable = 0

# Prefer the cgroup OOM killer's targeted kill over global panic.
vm.panic_on_oom = 0
vm.overcommit_memory = 0

# Make PSI meaningful: keep some reclaim headroom on a large-memory host.
vm.min_free_kbytes = 262144
```

```
$ sudo sysctl --system
* Applying /etc/sysctl.d/60-resource-control.conf ...
kernel.pid_max = 262144
kernel.threads-max = 262144
fs.file-max = 2097152
fs.nr_open = 1048576
fs.inotify.max_user_instances = 512
fs.inotify.max_user_watches = 524288
fs.suid_dumpable = 0
vm.panic_on_oom = 0
vm.overcommit_memory = 0
vm.min_free_kbytes = 262144
```

### 6.2 Protegé la plataforma antes de limitar a los inquilinos

Los pisos de protección importan más que los techos. Un host donde todos los inquilinos están limitados pero SSH no tiene reserva igual se vuelve inalcanzable bajo presión.

```ini
# /etc/systemd/system/system.slice.d/10-platform-protection.conf
#
# system.slice must always win against tenant.slice and user.slice.
[Slice]
CPUWeight=1000
IOWeight=1000
MemoryMin=2G
MemoryLow=4G
```

```ini
# /etc/systemd/system/sshd.service.d/10-lifeline.conf
#
# The administrative lifeline. If this dies, the incident becomes an outage.
[Service]
MemoryMin=128M
MemoryLow=256M
CPUWeight=2000
IOWeight=1000
OOMScoreAdjust=-900
ManagedOOMMemoryPressure=auto
ManagedOOMPreference=omit
TasksMax=512
LimitNOFILE=16384:65536
LimitCORE=0
```

```ini
# /etc/systemd/system/systemd-journald.service.d/10-protect.conf
[Service]
MemoryMin=64M
MemoryLow=192M
IOWeight=800
```

### 6.3 La jerarquía de slices de inquilinos

```ini
# /etc/systemd/system/tenant.slice
[Unit]
Description=Aggregate slice for all untrusted tenant workloads
Documentation=man:systemd.slice(5) man:systemd.resource-control(5)
Before=slices.target

[Slice]
# --- Aggregate ceiling: all tenants together never exceed this -------------
CPUAccounting=yes
MemoryAccounting=yes
IOAccounting=yes
TasksAccounting=yes

# Loses every contest against system.slice (weight 1000).
CPUWeight=100
IOWeight=100

# Hard aggregate cap. 24 GiB of a 64 GiB host.
MemoryHigh=20G
MemoryMax=24G
MemorySwapMax=2G

# Aggregate fork-bomb ceiling.
TasksMax=8192

# Pressure-driven pre-emptive kill, before the kernel is cornered.
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=50%
ManagedOOMSwap=kill
ManagedOOMPreference=avoid
```

```ini
# /etc/systemd/system/tenant-blue.slice
[Unit]
Description=Tenant BLUE - contracted 2 vCPU / 8 GiB
After=tenant.slice
Requires=tenant.slice

[Slice]
Slice=tenant.slice

# Absolute capacity ceiling: this is a billing boundary, so CPUQuota (not
# CPUWeight) is correct here despite the throttling cost. The tenant's
# runtime must be told to size its thread pool to 2 (GOMAXPROCS / -XX:ActiveProcessorCount)
# or p99 latency will suffer -- see cpu.stat nr_throttled.
CPUQuota=200%
CPUQuotaPeriodSec=20ms
CPUWeight=100

MemoryHigh=6G
MemoryMax=8G
MemorySwapMax=512M

TasksMax=1024

IOWeight=100
IOReadBandwidthMax=/dev/nvme0n1 200M
IOWriteBandwidthMax=/dev/nvme0n1 100M
IOReadIOPSMax=/dev/nvme0n1 8000
IOWriteIOPSMax=/dev/nvme0n1 4000
```

```ini
# /etc/systemd/system/tenant-green.slice
[Unit]
Description=Tenant GREEN - contracted 1 vCPU / 4 GiB
After=tenant.slice
Requires=tenant.slice

[Slice]
Slice=tenant.slice
CPUQuota=100%
CPUQuotaPeriodSec=20ms
CPUWeight=100
MemoryHigh=3G
MemoryMax=4G
MemorySwapMax=256M
TasksMax=512
IOWeight=100
IOReadBandwidthMax=/dev/nvme0n1 100M
IOWriteBandwidthMax=/dev/nvme0n1 50M
```

```ini
# /etc/systemd/system/tenant-batch.slice
[Unit]
Description=Best-effort batch work - yields to everything
After=tenant.slice
Requires=tenant.slice

[Slice]
Slice=tenant.slice

# SCHED_IDLE for the whole subtree: runs only on otherwise-idle CPUs.
# Requires systemd >= v252; on older systemd use CPUWeight=1.
CPUWeight=idle
IOWeight=1

MemoryHigh=2G
MemoryMax=4G
# No protection floor at all: first to be reclaimed, first to be killed.
MemoryLow=0
TasksMax=256
ManagedOOMMemoryPressure=kill
ManagedOOMPreference=avoid
```

### 6.4 Una unidad de servicio de inquilino — control de recursos más endurecimiento del proceso

```ini
# /etc/systemd/system/blue-api.service
[Unit]
Description=Tenant BLUE public API
Documentation=https://docs.kernel.org/admin-guide/cgroup-v2.html
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=tenant-blue
Group=tenant-blue
WorkingDirectory=/srv/tenants/blue
ExecStart=/srv/tenants/blue/bin/api --config /srv/tenants/blue/etc/api.yaml
Restart=on-failure
RestartSec=5s

# ===========================================================================
# PLANE 3/2 - cgroup resource control (aggregate, hierarchical, live)
# ===========================================================================
Slice=tenant-blue.slice

CPUAccounting=yes
MemoryAccounting=yes
IOAccounting=yes
TasksAccounting=yes

# Ramp before the cliff: MemoryHigh throttles and alerts, MemoryMax contains.
MemoryHigh=3G
MemoryMax=4G
MemorySwapMax=0

# Relative share INSIDE tenant-blue.slice; the slice's CPUQuota still applies.
CPUWeight=200
IOWeight=200

TasksMax=512

# Kill the whole process tree. A surviving master with dead workers still
# accepts TCP connections and silently blackholes traffic.
OOMPolicy=kill
OOMScoreAdjust=500

# ===========================================================================
# PLANE 1 - POSIX rlimits (per process, inherited, hard failure)
# ===========================================================================
LimitNOFILE=32768:65536
LimitNPROC=512
LimitCORE=0
LimitMEMLOCK=0
LimitRTPRIO=0
LimitFSIZE=10737418240

# ===========================================================================
# Process hardening that complements resource control (topic 332.1)
# ===========================================================================
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ReadWritePaths=/srv/tenants/blue/var
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@resources @privileged @mount

# Device access is enforced by an eBPF cgroup program on v2.
DevicePolicy=closed
DeviceAllow=/dev/null rw
DeviceAllow=/dev/urandom r

[Install]
WantedBy=multi-user.target
```

> `SystemCallFilter=~@resources` bloquea `setrlimit`, `setpriority`, `sched_setaffinity`, `mbind`, `migrate_pages` y compañía — impide que el servicio suba sus propios límites soft o se repinne a sí mismo. Complementa a los límites de cgroup en vez de duplicarlos: los cgroups acotan el *consumo*, seccomp acota la *reconfiguración*. `ProtectControlGroups=yes` remonta `/sys/fs/cgroup` como solo lectura dentro de la unidad, cerrando la vía de escritura directa.

### 6.5 Límites del lado de la sesión para el mismo host

```conf
# /etc/security/limits.d/60-tenant-sessions.conf
# Plane 1 backstop for interactive tenant logins. The cgroup limits above
# already bound aggregate usage; these bound a single runaway process and
# a single UID.

@tenant-blue    soft    nproc           256
@tenant-blue    hard    nproc           512
@tenant-blue    soft    nofile          8192
@tenant-blue    hard    nofile          32768
@tenant-blue    -       core            0
@tenant-blue    -       maxlogins       4
@tenant-blue    hard    memlock         0
@tenant-blue    hard    rtprio          0
@tenant-blue    hard    nice            0
```

```ini
# /etc/systemd/system/user-.slice.d/60-tenant-sessions.conf
# Plane 2/3: bound the login session itself, which limits.conf cannot do
# in aggregate.
[Slice]
CPUWeight=50
IOWeight=50
MemoryHigh=1G
MemoryMax=2G
TasksMax=512
```

### 6.6 Aplicar y confirmar

```
$ sudo systemctl daemon-reload
$ sudo systemctl restart systemd-oomd.service
$ sudo systemctl enable --now blue-api.service
Created symlink /etc/systemd/system/multi-user.target.wants/blue-api.service → /etc/systemd/system/blue-api.service.

$ systemctl status blue-api.service
● blue-api.service - Tenant BLUE public API
     Loaded: loaded (/etc/systemd/system/blue-api.service; enabled; preset: disabled)
     Active: active (running) since Mon 2026-08-24 12:31:44 -03; 12s ago
       Docs: https://docs.kernel.org/admin-guide/cgroup-v2.html
   Main PID: 7214 (api)
      Tasks: 27 (limit: 512)
     Memory: 412.8M (high: 3.0G max: 4.0G swap max: 0B available: 3.6G)
        CPU: 3.918s
     CGroup: /tenant.slice/tenant-blue.slice/blue-api.service
             └─7214 /srv/tenants/blue/bin/api --config /srv/tenants/blue/etc/api.yaml

$ systemd-cgls /tenant.slice
Control group /tenant.slice:
├─tenant-blue.slice
│ └─blue-api.service
│   └─7214 /srv/tenants/blue/bin/api --config /srv/tenants/blue/etc/api.yaml
├─tenant-green.slice
│ └─green-worker.service
│   └─7388 /srv/tenants/green/bin/worker
└─tenant-batch.slice
  └─nightly-etl.service
    └─7501 /usr/local/bin/etl --window 24h
```

---

## 7. Verificación y diagnóstico de fallas

**Doctrina: nunca verifiques un límite desde el archivo que lo declara.** Verificá desde el kernel — `/proc/<pid>/limits`, `/sys/fs/cgroup/**`, `systemctl show`. Configuración presente pero no aplicada es el caso normal, no la excepción.

### 7.1 La escalera de verificación

```bash
#!/usr/bin/env bash
# /usr/local/sbin/verify-resource-control
# Prove, from kernel state, that a unit's limits are actually in force.
set -euo pipefail

unit="${1:?usage: verify-resource-control <unit>}"

echo "=== 1. cgroup mode ==="
stat -fc '%T' /sys/fs/cgroup/     # expect: cgroup2fs

echo "=== 2. systemd's view of the properties ==="
systemctl show "$unit" \
  -p Slice -p ControlGroup -p MemoryMax -p MemoryHigh -p MemoryMin \
  -p CPUQuotaPerSecUSec -p CPUWeight -p TasksMax -p IOWeight \
  -p LimitNOFILESoft -p LimitNOFILE -p LimitCORE -p OOMPolicy

cg=$(systemctl show -P ControlGroup "$unit")
[ -n "$cg" ] || { echo "unit has no cgroup (not running?)"; exit 1; }
d="/sys/fs/cgroup${cg}"

echo "=== 3. the kernel's view (cgroup v2) ==="
for f in cpu.max cpu.weight memory.min memory.low memory.high memory.max \
         memory.swap.max memory.current pids.max pids.current io.max io.weight; do
    [ -e "$d/$f" ] && printf '%-18s %s\n' "$f" "$(cat "$d/$f" 2>/dev/null | tr '\n' ' ')"
done

echo "=== 4. breach evidence ==="
printf 'memory.events:\n'; cat "$d/memory.events" 2>/dev/null || true
printf 'pids.events:\n';   cat "$d/pids.events"   2>/dev/null || true
printf 'cpu.stat:\n';      grep -E 'nr_throttled|throttled_usec' "$d/cpu.stat" 2>/dev/null || true

echo "=== 5. pressure (leading indicator) ==="
for p in cpu.pressure memory.pressure io.pressure; do
    [ -e "$d/$p" ] && { printf '%s:\n' "$p"; cat "$d/$p"; }
done

echo "=== 6. rlimits actually in force on the main PID ==="
pid=$(systemctl show -P MainPID "$unit")
[ "$pid" != "0" ] && cat "/proc/$pid/limits"
```

```
$ sudo /usr/local/sbin/verify-resource-control blue-api.service
=== 1. cgroup mode ===
cgroup2fs
=== 2. systemd's view of the properties ===
Slice=tenant-blue.slice
ControlGroup=/tenant.slice/tenant-blue.slice/blue-api.service
MemoryMin=0
MemoryHigh=3221225472
MemoryMax=4294967296
CPUWeight=200
CPUQuotaPerSecUSec=infinity
TasksMax=512
IOWeight=200
LimitNOFILE=65536
LimitNOFILESoft=32768
LimitCORE=0
OOMPolicy=kill
=== 3. the kernel's view (cgroup v2) ===
cpu.max            max 20000
cpu.weight         200
memory.min         0
memory.low         0
memory.high        3221225472
memory.max         4294967296
memory.swap.max    0
memory.current     432799744
pids.max           512
pids.current       27
io.weight          default 200
=== 4. breach evidence ===
memory.events:
low 0
high 0
max 0
oom 0
oom_kill 0
oom_group_kill 0
pids.events:
max 0
cpu.stat:
nr_throttled 0
throttled_usec 0
=== 5. pressure (leading indicator) ===
cpu.pressure:
some avg10=0.00 avg60=0.02 avg300=0.01 total=1204881
full avg10=0.00 avg60=0.00 avg300=0.00 total=0
memory.pressure:
some avg10=0.00 avg60=0.00 avg300=0.00 total=0
full avg10=0.00 avg60=0.00 avg300=0.00 total=0
io.pressure:
some avg10=0.11 avg60=0.09 avg300=0.04 total=8842019
full avg10=0.03 avg60=0.02 avg300=0.01 total=2213004
=== 6. rlimits actually in force on the main PID ===
Limit                     Soft Limit           Hard Limit           Units
Max cpu time              unlimited            unlimited            seconds
Max file size             10737418240          10737418240          bytes
...
Max core file size        0                    0                    bytes
Max processes             512                  512                  processes
Max open files            32768                65536                files
Max locked memory         0                    0                    bytes
```

Fijate en la línea 3: `cpu.max` muestra `max 20000` en el **servicio**, porque la cuota vive en el slice padre. Leé siempre todo el camino de ancestros — el límite efectivo es el mínimo a lo largo de él:

```
$ for d in /sys/fs/cgroup /sys/fs/cgroup/tenant.slice \
           /sys/fs/cgroup/tenant.slice/tenant-blue.slice \
           /sys/fs/cgroup/tenant.slice/tenant-blue.slice/blue-api.service; do
    printf '%-70s cpu.max=%-16s memory.max=%s\n' "$d" \
      "$(cat $d/cpu.max 2>/dev/null | tr '\n' ' ')" "$(cat $d/memory.max 2>/dev/null)"
  done
/sys/fs/cgroup                                                         cpu.max=                 memory.max=
/sys/fs/cgroup/tenant.slice                                            cpu.max=max 100000       memory.max=25769803776
/sys/fs/cgroup/tenant.slice/tenant-blue.slice                          cpu.max=200000 20000     memory.max=8589934592
/sys/fs/cgroup/tenant.slice/tenant-blue.slice/blue-api.service         cpu.max=max 20000        memory.max=4294967296
```

### 7.2 Catálogo de fallas

| Síntoma | Causa probable | Comando de confirmación |
|---|---|---|
| `Too many open files` después de subir `limits.conf` | El servicio no tiene sesión PAM | `cat /proc/$(pidof x)/limits`; se arregla con `LimitNOFILE=` |
| `limits.conf` funciona en consola, no por SSH | `UsePAM no`, o falta `pam_limits.so` en el stack de `sshd` | `sshd -T \| grep usepam`; `grep pam_limits /etc/pam.d/sshd` |
| El límite `nproc` es menor que lo configurado | RHEL trae `/etc/security/limits.d/20-nproc.conf` | `grep -r nproc /etc/security/limits.d/` |
| Dos servicios con el mismo usuario chocan con `fork: EAGAIN` temprano | `RLIMIT_NPROC` es por UID a nivel de host | Cambiar a `TasksMax=` |
| `MemoryMax=` "ignorado" | El host está en cgroup v1 | `stat -fc %T /sys/fs/cgroup/` |
| `write error: No such file or directory` en un archivo de cgroup | Controlador ausente del `subtree_control` del padre | `cat ../cgroup.subtree_control` |
| `write error: Device or resource busy` en `subtree_control` | Hay procesos en un nodo interno ("no internal processes") | `cat cgroup.procs` |
| Un servicio limitado por CPU tiene el promedio correcto pero un p99 pésimo | Throttling de la cuota CFS | `grep nr_throttled cpu.stat` |
| El servicio fue matado pero `journalctl` no muestra OOM | `systemd-oomd` actuó por PSI, no el kernel | `journalctl -u systemd-oomd`; `oomctl` |
| Solo murieron algunos workers; el servicio es un zombi | `OOMPolicy` no es `kill` / `memory.oom.group=0` | `cat memory.oom.group`; poner `OOMPolicy=kill` |
| Los límites desaparecen tras reiniciar | Se usó `systemctl set-property --runtime` | `ls /run/systemd/system.control/` |
| JVM/Go se caen al arrancar bajo un tope de memoria | Se configuró `RLIMIT_AS` (`ulimit -v`) en vez de `MemoryMax=` | `grep 'Max address space' /proc/<pid>/limits` |
| El throttling de IO no tiene efecto | `io.max` escrito para una partición o `dm-*` en vez del dispositivo físico | `lsblk -o NAME,MAJ:MIN`; `cat io.stat` |
| Las escrituras bufferizadas escapan al tope de IO | cgroup v1 (writeback cargado a `kworker`) | Migrar a v2 |
| `systemd-cgtop` muestra `-` en una columna | Contabilidad deshabilitada para ese controlador | `systemctl show -p IOAccounting <unit>` |

### 7.3 Diagnóstico de los dos incidentes canónicos

**A: "el servicio se sigue muriendo y no hay nada en `dmesg`."**

```
$ systemctl status green-worker.service | head -8
● green-worker.service - Tenant GREEN worker
     Active: failed (Result: oom-kill) since Mon 2026-08-24 13:02:19 -03; 40s ago
    Process: 7388 ExecStart=/srv/tenants/green/bin/worker (code=killed, signal=KILL)

$ journalctl -u green-worker.service -n 5 --no-pager
Aug 24 13:02:19 host systemd[1]: green-worker.service: A process of this unit has been killed by the OOM killer.
Aug 24 13:02:19 host systemd[1]: green-worker.service: Main process exited, code=killed, status=9/KILL
Aug 24 13:02:19 host systemd[1]: green-worker.service: Failed with result 'oom-kill'.

$ cat /sys/fs/cgroup/tenant.slice/tenant-green.slice/memory.events
low 0
high 8421
max 193
oom 4
oom_kill 4
oom_group_kill 4
```

`high 8421` dice que la carga pasó mucho tiempo siendo estrangulada antes de morir — la fuga fue visible durante minutos. Esa es la alerta que te faltaba: **alertá sobre el aumento de `memory.events:high`, no sobre el OOM kill.**

Si `journalctl -k` no muestra absolutamente nada, el asesino fue de espacio de usuario:

```
$ journalctl -u systemd-oomd -n 3 --no-pager
Aug 24 13:02:19 host systemd-oomd[981]: Considered 3 cgroups for killing, top candidate was: /tenant.slice/tenant-green.slice
Aug 24 13:02:19 host systemd-oomd[981]: Memory pressure for /tenant.slice/tenant-green.slice is 61.42% > 50.00% for > 20s with reclaim activity
Aug 24 13:02:19 host systemd-oomd[981]: Killed /tenant.slice/tenant-green.slice due to memory pressure
```

**B: "el uso de CPU es solo del 45 % pero la latencia se duplicó."**

```
$ cat /sys/fs/cgroup/tenant.slice/tenant-blue.slice/cpu.stat
usage_usec 412887210
user_usec  361029844
system_usec 51857366
nr_periods 1204118
nr_throttled 812440
throttled_usec 91224881000

$ cat /sys/fs/cgroup/tenant.slice/tenant-blue.slice/cpu.pressure
some avg10=41.22 avg60=38.90 avg300=35.11 total=6188221004
full avg10=29.87 avg60=27.44 avg300=25.02 total=4011889231
```

67 % de los períodos estrangulados, y `full avg10=29.87` significa que durante ~30 % de los últimos 10 segundos **todas** las tareas del inquilino estuvieron estancadas esperando CPU. La utilización promedio es una mentira; PSI es la verdad. Remediación: acortar el período, o reemplazar la cuota por un peso.

```
$ sudo systemctl set-property --runtime tenant-blue.slice CPUQuotaPeriodSec=10ms
$ sleep 60; grep nr_throttled /sys/fs/cgroup/tenant.slice/tenant-blue.slice/cpu.stat
nr_throttled 812440
```

(El contador es acumulativo — compará deltas, nunca valores absolutos.)

### 7.4 Depurar el propio `pam_limits`

```
$ sudo cp /etc/pam.d/sshd{,.bak}
$ sudo sed -i 's/^\(session.*pam_limits.so\)/\1 debug/' /etc/pam.d/sshd
$ ssh tenant-blue@localhost true
$ sudo journalctl -t sshd -n 12 --no-pager | grep pam_limits
sshd[8112]: pam_limits(sshd:session): reading settings from '/etc/security/limits.conf'
sshd[8112]: pam_limits(sshd:session): reading settings from '/etc/security/limits.d/20-nproc.conf'
sshd[8112]: pam_limits(sshd:session): reading settings from '/etc/security/limits.d/60-tenant-sessions.conf'
sshd[8112]: pam_limits(sshd:session): checking limits for 'tenant-blue'
sshd[8112]: pam_limits(sshd:session): setting NPROC soft=256 hard=512
sshd[8112]: pam_limits(sshd:session): setting NOFILE soft=8192 hard=32768
sshd[8112]: pam_limits(sshd:session): setting CORE soft=0 hard=0
$ sudo mv /etc/pam.d/sshd.bak /etc/pam.d/sshd
```

Esta es la única forma de zanjar definitivamente las cuestiones de precedencia en tu build. Quitá `debug` cuando termines — la salida es verbosa y nombra cuentas.

### 7.5 Prueba de contención no destructiva

Antes de declarar endurecido un host, atacalo — desde adentro de la caja que los límites supuestamente protegen.

```
$ sudo systemd-run --pty --wait --collect --slice=tenant-batch.slice \
    -p MemoryMax=128M -p TasksMax=30 -p CPUQuota=10% -p OOMPolicy=kill /bin/bash
Running as unit: run-u311.service

# --- fork bomb: must be contained, host must stay responsive ---
# :(){ :|:& };:
bash: fork: retry: Resource temporarily unavailable
bash: fork: Resource temporarily unavailable

# --- memory bomb: must kill only this cgroup ---
# python3 -c "b=bytearray(400*1024*1024)"
Killed

# --- cpu bomb: must throttle to 10% ---
# (for i in $(seq 4); do while :; do :; done & done); sleep 5; kill %1 %2 %3 %4
```

Desde una segunda terminal, el host no se ve afectado:

```
$ uptime
 13:20:44 up 6 days,  2:11,  3 users,  load average: 4.02, 1.88, 0.94
$ systemd-cgtop -n 1 --depth=2 | head -6
Control Group                            Tasks   %CPU   Memory  Input/s Output/s
/                                          448   10.4     3.4G        -        -
tenant.slice                                92   10.1   612.7M        -        -
tenant.slice/tenant-batch.slice             30   10.0   128.0M        -        -
system.slice                               203    0.3     2.1G        -        -
```

El load average es 4,02 porque hay cuatro procesos girando que están ejecutables — pero en conjunto consumen el 10 % de una CPU, y `system.slice` está intacto. El load average mide *tareas ejecutables*, no capacidad consumida; bajo throttling de cgroups los dos se desacoplan por completo. Monitoreá PSI, no el load average.

---

## 8. Referencia rápida para el examen

| Tarea | Comando |
|---|---|
| Mostrar todos los límites actuales | `ulimit -a` |
| Mostrar/establecer soft vs hard | `ulimit -Sn` / `ulimit -Hn` / `ulimit -Hn 4096` |
| Límites de un proceso en ejecución | `cat /proc/<pid>/limits` · `prlimit --pid <pid>` |
| Cambiar el límite de un proceso en ejecución | `prlimit --pid <pid> --nofile=65536:524288` |
| Lanzar con un límite | `prlimit --nproc=64 -- cmd` |
| Configuración de límites de sesión | `/etc/security/limits.conf`, `/etc/security/limits.d/*.conf` |
| Módulo que los aplica | `session required pam_limits.so` |
| Detectar la versión de cgroup | `stat -fc %T /sys/fs/cgroup/` → `cgroup2fs` \| `tmpfs` |
| Mostrar el árbol de cgroups | `systemd-cgls` |
| Uso por cgroup en vivo | `systemd-cgtop` |
| Unidad transitoria con límites | `systemd-run -p MemoryMax=512M -p CPUQuota=25% --slice=x.slice cmd` |
| Shell interactivo contenido | `systemd-run --pty --wait --collect -p TasksMax=25 /bin/bash` |
| Cambiar los límites de una unidad en vivo | `systemctl set-property nginx.service MemoryMax=2G` |
| Cambiar sin persistir | `systemctl set-property --runtime …` |
| Leer las propiedades efectivas | `systemctl show <unit> -p MemoryMax -p TasksMax -p ControlGroup` |
| Valores por defecto de servicios para todo el host | `/etc/systemd/system.conf` (`DefaultLimitNOFILE=`, `DefaultTasksMax=`) |
| Cgroup de un proceso | `cat /proc/<pid>/cgroup` |
| Métricas de presión | `cat /sys/fs/cgroup/<path>/{cpu,memory,io}.pressure` |
| Estado de oomd | `oomctl` |

**Diez hechos que deciden preguntas:**

1. `limits.conf` es solo de PAM; **no** tiene efecto sobre los servicios de systemd.
2. `*` en `limits.conf` **no** coincide con root.
3. `ulimit -m` (`RLIMIT_RSS`) no hace nada en Linux moderno.
4. `RLIMIT_NPROC` es por **UID**, a nivel de host, cuenta hilos, root exento. `pids.max` es por cgroup, jerárquico, sin exenciones.
5. Bajar un límite hard es irreversible sin `CAP_SYS_RESOURCE`.
6. `CPUWeight=` es relativo y solo muerde bajo contención; `CPUQuota=` es absoluto y estrangula incluso en un host ocioso.
7. `MemoryHigh=` estrangula; `MemoryMax=` mata. Configurá ambos, con `High` por debajo de `Max`.
8. cgroup v2 prohíbe procesos en cgroups internos (no raíz).
9. Un controlador debe habilitarse de arriba hacia abajo vía el `cgroup.subtree_control` de cada ancestro.
10. `Limit*=` son rlimits; toda otra directiva de recursos es un cgroup. Planos distintos, semánticas distintas, modos de falla distintos.

---

## 9. Referencias

**Objetivos del examen**
- LPI — Exam 303 (Security) Objectives, version 3.0: https://www.lpi.org/our-certifications/exam-303-objectives/
- LPIC-3 Security overview: https://www.lpi.org/our-certifications/lpic-3-303-overview/

**Documentación del kernel**
- Control Group v2 (referencia autoritativa de la interfaz): https://docs.kernel.org/admin-guide/cgroup-v2.html
- Control Groups version 1: https://docs.kernel.org/admin-guide/cgroup-v1/index.html
- Controlador de memoria de cgroup v1: https://docs.kernel.org/admin-guide/cgroup-v1/memory.html
- PSI — Pressure Stall Information: https://docs.kernel.org/accounting/psi.html
- OOM killer / `oom_score_adj`: https://docs.kernel.org/filesystems/proc.html
- Sysctl del kernel (`fs.*`, `kernel.pid_max`): https://docs.kernel.org/admin-guide/sysctl/fs.html · https://docs.kernel.org/admin-guide/sysctl/kernel.html

**Páginas de manual — límites de recursos**
- `setrlimit(2)` / `getrlimit(2)` / `prlimit(2)`: https://man7.org/linux/man-pages/man2/setrlimit.2.html
- `prlimit(1)`: https://man7.org/linux/man-pages/man1/prlimit.1.html
- `ulimit(1p)` (POSIX): https://man7.org/linux/man-pages/man1/ulimit.1p.html
- `limits.conf(5)`: https://man7.org/linux/man-pages/man5/limits.conf.5.html
- `pam_limits(8)`: https://man7.org/linux/man-pages/man8/pam_limits.8.html
- `pam.conf(5)` / sintaxis del stack PAM: https://man7.org/linux/man-pages/man5/pam.conf.5.html
- `proc_pid_limits(5)`: https://man7.org/linux/man-pages/man5/proc_pid_limits.5.html

**Páginas de manual — cgroups**
- `cgroups(7)`: https://man7.org/linux/man-pages/man7/cgroups.7.html
- `cgroup_namespaces(7)`: https://man7.org/linux/man-pages/man7/cgroup_namespaces.7.html

**systemd**
- `systemd.resource-control(5)` — todas las directivas de §5.2: https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html
- `systemd.exec(5)` — `Limit*=`, `OOMScoreAdjust=`, `CoredumpFilter=`: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- `systemd.slice(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.slice.html
- `systemd.scope(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.scope.html
- `systemd.unit(5)` — precedencia de drop-ins: https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html
- `systemd-system.conf(5)` — configuraciones `Default*`: https://www.freedesktop.org/software/systemd/man/latest/systemd-system.conf.html
- `systemd-run(1)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html
- `systemctl(1)` — `set-property`: https://www.freedesktop.org/software/systemd/man/latest/systemctl.html
- `systemd-cgls(1)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-cgls.html
- `systemd-cgtop(1)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-cgtop.html
- `systemd-oomd.service(8)` y `oomctl(1)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-oomd.service.html
- `oomd.conf(5)`: https://www.freedesktop.org/software/systemd/man/latest/oomd.conf.html
- `logind.conf(5)`: https://www.freedesktop.org/software/systemd/man/latest/logind.conf.html
- Control Group APIs and Delegation (documento de diseño): https://systemd.io/CGROUP_DELEGATION/
- The New Control Group Interfaces (guía de migración upstream): https://systemd.io/CONTROL_GROUP_INTERFACE/

**Guías de distribuciones**
- Red Hat Enterprise Linux 9 — Managing, monitoring and updating the kernel: control groups: https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_monitoring_and_updating_the_kernel/setting-limits-for-applications_managing-monitoring-and-updating-the-kernel
- SUSE Linux Enterprise Server — System Analysis and Tuning Guide, cgroups: https://documentation.suse.com/sles/15-SP6/html/SLES-all/cha-tuning-cgroups.html
- Debian Wiki — systemd resource control: https://wiki.debian.org/systemd