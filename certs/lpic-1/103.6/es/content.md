# 103.6 — Modificar las prioridades de ejecución de los procesos

**LPIC-1 · Examen 101-500 · Versión 5.0 · Peso: 3.12**

---

## 1. Motivación: el problema arquitectónico

Operás una flota de nodos bare-metal de 40 núcleos que sirven una API gRPC crítica en latencia. A las 02:00 arranca un indexador nocturno en los mismos nodos. La latencia p99 pasa de 12 ms a 480 ms. El runbook de guardia dice: *"ejecutá el indexador con `nice -n 19`."* Alguien lo hace. **No cambia nada.**

Esta es la falla más común de todo el tema, y no es un bug: son tres capas del planificador de Linux interactuando:

```
                  ┌─────────────────────────────────────┐
   cgroup v2      │  /sys/fs/cgroup/system.slice        │  cpu.weight = 100
   (cpu ctrl)     │    ├── api.service      cpu.weight  │  = 10000
                  │    └── indexer.service  cpu.weight  │  = 1
                  └─────────────────────────────────────┘
                                  │  proportional split happens HERE first
                                  ▼
                  ┌─────────────────────────────────────┐
   autogroup      │  /proc/<pid>/autogroup (per setsid) │  nice applies to the GROUP
                  └─────────────────────────────────────┘
                                  │
                                  ▼
                  ┌─────────────────────────────────────┐
   task nice      │  se.load.weight from nice(-20..19)  │  applies only among SIBLINGS
                  └─────────────────────────────────────┘
```

Un valor de `nice` **no** es una afirmación global sobre la importancia de un proceso. Es un *peso relativo a las demás tareas ejecutables dentro de la misma entidad de planificación*. Si el indexador vive en su propio cgroup, su valor de `nice` compite solamente contra sí mismo. Si vive en su propio autogroup (su propia sesión `setsid` — que es lo que recibe todo servicio de `systemd` y todo login SSH), pasa exactamente lo mismo.

El modelo mental de nivel producción con el que tenés que salir de esta sección:

| Pregunta | Instrumento correcto |
|---|---|
| "Que este proceso ceda ante *sus hermanos*." | `nice` / `renice` |
| "Que este *servicio* ceda ante otro servicio." | `cpu.weight` de cgroup v2 (`CPUWeight=` de systemd) |
| "Limitar esta carga a N núcleos sin importar la capacidad ociosa." | `cpu.max` de cgroup v2 (`CPUQuota=` de systemd) |
| "Esta tarea debe ejecutarse dentro de una latencia acotada, siempre." | `SCHED_FIFO`/`SCHED_RR`/`SCHED_DEADLINE` vía `chrt` |
| "Esta tarea debería correr solo cuando la CPU está ociosa." | `SCHED_IDLE` (`chrt -i`) o `cpu.idle` de cgroup |
| "Este trabajo por lotes está destruyendo la latencia de mi disco." | `ionice` **solo con BFQ**, si no `io.latency`/`io.max` de cgroup |
| "¿Qué pod se mata / se planifica primero?" | `PriorityClass` de Kubernetes + `oom_score_adj` — **no** nice |

El examen evalúa `nice`, `renice`, `ps` y `top`. La producción evalúa si sabés que esas cuatro herramientas atacan únicamente la capa inferior del diagrama de arriba.

---

## 2. La recta numérica de las prioridades

Linux expone al menos cuatro escalas numéricas distintas para "prioridad", tres de ellas invertidas entre sí. Tener esto claro es el tema entero.

### 2.1 Las escalas

| Escala | Rango | Dirección | Dónde la ves |
|---|---|---|---|
| **valor nice** (de cara al usuario) | `-20` … `19` | menor = **más** CPU | `nice`, `renice`, columna `NI`, campo 19 de `/proc/<pid>/stat` |
| **nice del kernel** (interno) | `0` … `39` | menor = más CPU | campo 18 de `/proc/<pid>/stat`, `PR` de `top` |
| **`prio` del kernel** | `0` … `139` | menor = más CPU | `/proc/<pid>/sched` (`prio`), `100 + 20 + nice` para tareas normales |
| **prioridad estática RT** | `1` … `99` | **mayor = más CPU** | `chrt`, columna `RTPRIO` |
| **`PRI` de `ps`** | depende del build | ver la advertencia más abajo | `ps -l` |

Las conversiones para una tarea `SCHED_OTHER`:

```
nice          = -20   -10     0     5    10    19
kernel nice   =   0    10    20    25    30    39     (= 20 + nice)   → top's PR
kernel prio   = 100   110   120   125   130   139     (= 120 + nice)  → /proc/<pid>/sched
ps -l PRI     =  60    70    80    85    90    99     (= 80 + nice)
```

Para una tarea de tiempo real, el campo 18 de `/proc/<pid>/stat` pasa a ser `-1 - rt_priority` (así que `rtprio 50` → `-51`), que es la razón por la cual `top` muestra `PR` como `-51` para ella.

> **⚠️ Nunca escribas scripts contra `PRI`.** `procps-ng` incluye **seis** representaciones históricas de la columna de prioridad (`pri`, `opri`, `pri_foo`, `pri_bar`, `pri_baz`, `priority`), elegidas según qué flag de formato usaste. `ps -l` y `ps -o pri` pueden imprimir legítimamente números distintos para el mismo proceso en la misma máquina. Los únicos campos con semántica estable y documentada son **`ni`**, **`cls`** y **`rtprio`**. Toda automatización que escribas debe usar esos.

### 2.2 Qué te compra realmente un valor de nice

`nice` no es un porcentaje ni la duración de una rodaja. Es un índice dentro de la tabla de pesos del kernel (`kernel/sched/core.c`, `sched_prio_to_weight[]`). Cada nivel de nice vale **≈1,25×**:

| nice | peso | nice | peso | nice | peso | nice | peso |
|---:|---:|---:|---:|---:|---:|---:|---:|
| -20 | 88761 | -10 | 9548 | 0 | **1024** | 10 | 110 |
| -19 | 71755 | -9 | 7620 | 1 | 820 | 11 | 87 |
| -18 | 56483 | -8 | 6100 | 2 | 655 | 12 | 70 |
| -17 | 46273 | -7 | 4904 | 3 | 526 | 13 | 56 |
| -16 | 36291 | -6 | 3906 | 4 | 423 | 14 | 45 |
| -15 | 29154 | -5 | 3121 | 5 | 335 | 15 | 36 |
| -14 | 23254 | -4 | 2501 | 6 | 272 | 16 | 29 |
| -13 | 18705 | -3 | 1991 | 7 | 215 | 17 | 23 |
| -12 | 14949 | -2 | 1586 | 8 | 172 | 18 | 18 |
| -11 | 11916 | -1 | 1277 | 9 | 137 | 19 | **15** |

Cuota de CPU para un conjunto de tareas *continuamente ejecutables* en la misma runqueue:

```
share(i) = weight(i) / Σ weight(j)
```

Dos tareas ligadas a CPU fijadas a un solo núcleo:

| nice Tarea A | nice Tarea B | Cuota A | Cuota B | Relación |
|---:|---:|---:|---:|---:|
| 0 | 0 | 50,0 % | 50,0 % | 1,0× |
| 0 | 5 | 75,3 % | 24,7 % | 3,1× |
| 0 | 10 | 90,3 % | 9,7 % | 9,3× |
| 0 | 19 | 98,6 % | 1,4 % | 68,3× |
| -5 | 5 | 90,3 % | 9,7 % | 9,3× |
| -20 | 19 | 99,98 % | 0,02 % | 5917× |

Dos consecuencias que importan en producción:

1. **`nice 19` no es `SCHED_IDLE`.** Una tarea con nice 19 sigue obteniendo ~1,4 % de una CPU ocupada y — lo crítico — sigue siendo *elegible* para expropiar y para retener locks. `SCHED_IDLE` tiene peso 3 y se planifica solo cuando no hay nada más ejecutable.
2. **Solo importa la relación.** `nice 0` vs `nice 5` y `nice -5` vs `nice 0`... esperá — `nice -5` (3121) vs `nice 5` (335) es 9,3×, idéntico a `nice 0` vs `nice 10`. Desplazar ambos la misma cantidad no hace nada. Los equipos que "renicean todo a -5" no lograron nada salvo quemar `CAP_SYS_NICE`.

### 2.3 CFS, EEVDF y adónde fue a parar nice

Desde **Linux 6.6** la clase de planificación por defecto es **EEVDF** (Earliest Eligible Virtual Deadline First), que reemplaza el ordenamiento clásico de CFS por vruntime. La tabla nice → peso no cambió, pero ahora nice influye sobre dos cosas en lugar de una:

| Propiedad | CFS (< 6.6) | EEVDF (≥ 6.6) |
|---|---|---|
| Cuota proporcional | `weight / Σweight` vía escalado de vruntime | mismos pesos, seguidos como *lag* |
| Latencia / expropiación | indirecta; `sched_min_granularity_ns` | deadline virtual `vd = ve + slice/weight` — más peso ⇒ deadline más temprano ⇒ mejor latencia de despertar |
| Sugerencia de latencia por tarea | ninguna | `sched_attr.sched_runtime` vía `sched_setattr(2)` |

Conclusión práctica: en ≥ 6.6, un valor de nice negativo mejora la *latencia de despertar* además de la cuota de throughput, lo que lo vuelve una herramienta un poco mejor para demonios interactivos de lo que era antes. Sigue **sin** cruzar los límites de cgroup ni de autogroup.

---

## 3. `nice` y `renice`: mecánica y trampas

### 3.1 `nice(1)` — se fija en el momento del exec

```
nice [-n ADJUSTMENT] [COMMAND [ARG]...]
```

Semánticas clave, todas las cuales aparecen en el examen y todas las cuales muerden en producción:

| Comportamiento | Detalle |
|---|---|
| Ajuste por defecto | **10**, no 0. `nice make -j64` a secas corre con nice 10. |
| `-n` es un **ajuste**, no un absoluto | Se suma al valor de nice actual del invocante. `nice -n 5 nice -n 5 cmd` → nice **10**. |
| Sintaxis obsoleta | `nice -5 cmd` significa ajuste **+5**, no −5. Para ir a negativo *tenés* que escribir `nice -n -5 cmd`. |
| Sin argumentos | Imprime el valor de nice actual del shell y sale. |
| Recorte (clamping) | Los resultados fuera de `[-20, 19]` se recortan silenciosamente, no se rechazan. |
| La falla **no es fatal** | Si se deniega el ajuste, GNU `nice` imprime una advertencia **y ejecuta el comando igual**. |
| Herencia | El valor de nice sobrevive a `fork(2)` y se preserva a través de `execve(2)`. |

```console
$ nice
0

$ nice -n 12 nice
12

$ nice -n 5 nice -n 5 nice
10

$ nice -5 nice          # obsolete syntax: this is +5, NOT -5
5

$ nice -n -5 sleep 1
nice: cannot set niceness: Permission denied
$ echo $?
0
```

Ese estado de salida `0` es la trampa. Un script de despliegue que hace:

```bash
nice -n -5 /usr/local/bin/latency-sensitive-daemon &
```

ejecuta el demonio con nice 0 para siempre, sale limpio y pasa CI. **Verificá siempre después de fijarlo, nunca confíes en el estado de salida de `nice`.**

### 3.2 `renice(1)` — cambiar un proceso en ejecución

```
renice [-n] PRIORITY [-p PID...] [-g PGID...] [-u USER...]
```

| Comportamiento | Detalle |
|---|---|
| El valor es **absoluto** en util-linux | `renice -n 5 -p 1234` fija el nice **a** 5, no le suma 5. Esto es lo opuesto a `nice(1)` y al `renice` histórico de BSD/POSIX. |
| Objetivos | `-p` PID (por defecto), `-g` grupo de procesos, `-u` usuario/UID. |
| Usuarios sin privilegios | Solo pueden **subir** el valor de nice (volverlo menos favorable), y solo para procesos propios — trinquete de una sola dirección. |
| Por hilo | En Linux `setpriority(2)` es un atributo **por hilo** a pesar de POSIX. `renice -p <PID>` cambia solamente el hilo cuyo TID es igual al PID — es decir, el hilo principal. |

El comportamiento por hilo es la segunda gran sorpresa de producción. Una JVM o un binario de Go con 200 hilos de SO queda esencialmente inalterado por `renice -p`:

```console
$ ps -o pid,ni,comm -p 4412
    PID  NI COMMAND
   4412   0 indexer

$ sudo renice -n 19 -p 4412
4412 (process ID) old priority 0, new priority 19

$ ps -L -o pid,tid,ni,comm -p 4412 | head -6
    PID     TID  NI COMMAND
   4412    4412  19 indexer
   4412    4413   0 indexer
   4412    4414   0 indexer
   4412    4415   0 indexer
   4412    4416   0 indexer
```

Se renició un hilo. Los otros 199 siguen corriendo con nice 0. El conjuro correcto:

```console
$ for t in /proc/4412/task/*; do sudo renice -n 19 -p "${t##*/}" >/dev/null; done
$ ps -L -o tid,ni -p 4412 | awk 'NR>1 {c[$2]++} END {for (n in c) print "nice="n, c[n]" threads"}'
nice=19 200 threads
```

O, mucho mejor, poné la carga de trabajo en un cgroup y dejá de perseguir hilos (§6).

### 3.3 Quién puede ir a negativo: `RLIMIT_NICE` y `CAP_SYS_NICE`

Bajar un valor de nice por debajo del actual requiere una de dos cosas:

* **`CAP_SYS_NICE`** (root, o una capability de archivo, o `AmbientCapabilities=`/`CapabilityBoundingSet=` en una unit), **o**
* margen en **`RLIMIT_NICE`**.

`RLIMIT_NICE` se almacena invertido. El piso al que puede llegar un proceso es:

```
nice_floor = 20 - RLIMIT_NICE
```

El `RLIMIT_NICE` por defecto es `0`, lo que da un piso de nice 20 — es decir, recortado al valor actual, sin ninguna posibilidad de bajarlo.

```console
$ ulimit -e
0

$ prlimit --pid $$ --nice
RESOURCE DESCRIPTION                     SOFT HARD UNITS
NICE     max nice prio allowed to raise     0    0
```

Otorgale a un grupo la capacidad de llegar a nice −10 (el patrón clásico de audio de baja latencia / motor de trading) vía límites de PAM:

```ini
# /etc/security/limits.d/20-lowlatency.conf
# Format: <domain> <type> <item> <value>
# RLIMIT_NICE is inverted: value 30 => floor of nice (20 - 30) = -10
@lowlat   soft   nice        30
@lowlat   hard   nice        30
# Companion RT budget, capped so a runaway FIFO task cannot wedge the box.
@lowlat   soft   rtprio      50
@lowlat   hard   rtprio      50
@lowlat   -      memlock     unlimited
```

```console
$ sudo -u alice -i ulimit -e
30
$ sudo -u alice nice -n -10 nice
-10
```

> `pam_limits` no se aplica a los servicios de systemd. Para las units, usá `LimitNICE=` / `LimitRTPRIO=` en el archivo de la unit — ver §7.

### 3.4 Leer el estado actual

```console
$ ps -eo pid,ni,cls,rtprio,pri,psr,comm --sort=ni | head -8
    PID  NI CLS RTPRIO PRI PSR COMMAND
   1189 -10  TS      -  90   6 pipewire
    987  -5  TS      -  85   2 sshd
      1   0  TS      -  80   0 systemd
   4412  19  TS      -  99  11 indexer
   2201   - FF      50   9   3 irq/24-nvme0
   2318   - RR      10  49   1 xdp-poller
   3390   - IDL      -  79   8 backup-rsync
```

| `CLS` | Política | Constante |
|---|---|---|
| `TS` | `SCHED_OTHER` (tiempo compartido) | 0 |
| `FF` | `SCHED_FIFO` | 1 |
| `RR` | `SCHED_RR` | 2 |
| `B` | `SCHED_BATCH` | 3 |
| `IDL` | `SCHED_IDLE` | 5 |
| `DLN` | `SCHED_DEADLINE` | 6 |

En `top`, presioná **`f`** para agregar campos y después ordená. Las columnas relevantes son `PR` (nice del kernel, o `-1-rtprio` para RT), `NI` (nice de cara al usuario) y `S`. Reniciar interactivamente es **`r`**; cambiar el campo de orden es **`x`**/**`<`**/**`>`**.

```console
$ top -b -n 1 -o %CPU | head -12
top - 02:14:31 up 41 days,  3:07,  2 users,  load average: 39.12, 38.44, 31.09
Tasks: 612 total,   3 running, 609 sleeping,   0 stopped,   0 zombie
%Cpu(s): 94.1 us,  4.2 sy,  0.0 ni,  1.1 id,  0.0 wa,  0.4 hi,  0.2 si,  0.0 st
MiB Mem :  128721.4 total,   9812.2 free,  71204.8 used,  47704.4 buff/cache

    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
   4412 indexer   39  19   8.1g   2.4g  18244 R  1580   1.9   3:11.42 indexer
   2210 api       20   0  12.4g   6.1g  31002 S   412   4.8 918:02.11 api-server
   2201 root     -51   -   0.0m   0.0m      0 S   3.1   0.0  41:19.07 irq/24-nvme0
```

Leé esa tercera línea con atención: **`0.0 ni`**. El campo `ni` del resumen `%Cpu(s)` es la fracción de CPU gastada en tareas de usuario *con nice positivo*. Marca `0.0` mientras un proceso con nice 19 quema 1580 % de CPU — porque el balde de contabilidad `ni` de `top` solo cuenta tareas con nice > 0 **tal como se muestrean en los límites de tick**, y sobre todo porque en esta corrida el indexador está en su propio cgroup, así que… no. La razón real acá es el autogroup, y ese es exactamente el bug de §1. Probémoslo.

---

## 4. Por qué tu `nice` no hizo nada: los autogroups

El **autogrouping** (`CONFIG_SCHED_AUTOGROUP`, activado por defecto en toda distribución mainstream) coloca automáticamente cada tarea creada por `setsid(2)` — cada sesión SSH, cada terminal, cada servicio de `systemd` — en su propio grupo de planificación. El planificador entonces reparte la CPU **primero entre autogroups**, y solo después aplica los valores de nice por tarea *dentro* de cada grupo.

```console
$ cat /proc/sys/kernel/sched_autogroup_enabled
1

$ cat /proc/self/autogroup
/autogroup-431 nice 0
```

La demostración. Dos consumidores de CPU idénticos, fijados al mismo núcleo para que la aritmética sea visible:

```console
$ taskset -c 7 sh -c 'while :; do :; done' &
[1] 8801
$ taskset -c 7 nice -n 19 sh -c 'while :; do :; done' &
[2] 8802

$ pidstat -p 8801,8802 2 1
Linux 6.11.0-19-generic (node-07)   08/26/26   _x86_64_   (40 CPU)

02:19:44      UID       PID    %usr %system  %guest   %wait    %CPU   CPU  Command
02:19:46     1000      8801   98.51    0.00    0.00    1.49   98.51     7  sh
02:19:46     1000      8802    1.49    0.00    0.00   98.02    1.49     7  sh
```

Eso funcionó — 98,5 / 1,5, exactamente la relación 1024:15 que predice la tabla de pesos. Funcionó porque **ambos consumidores están en la misma sesión de shell y, por lo tanto, en el mismo autogroup**.

Ahora ejecutá el consumidor de baja prioridad desde una *segunda* sesión SSH (un `setsid` distinto):

```console
# session A
$ taskset -c 7 sh -c 'while :; do :; done' &
[1] 8901

# session B
$ taskset -c 7 nice -n 19 sh -c 'while :; do :; done' &
[1] 8902

# session A
$ pidstat -p 8901,8902 2 1
02:23:10     1000      8901   50.25    0.00    0.00   49.75   50.25     7  sh
02:23:10     1000      8902   49.75    0.00    0.00   50.25   49.75     7  sh
```

**50/50.** La tarea con nice 19 es el único miembro de su autogroup, así que obtiene el 100 % de la cuota de su grupo, y los dos grupos tienen igual peso. Este es exactamente el incidente de producción de §1.

Dos arreglos correctos:

```console
# (a) Nice the whole autogroup — value written to /proc/<pid>/autogroup
$ echo 19 | sudo tee /proc/8902/autogroup
19
$ cat /proc/8902/autogroup
/autogroup-512 nice 19

$ pidstat -p 8901,8902 2 1
02:25:02     1000      8901   98.51    0.00    0.00    1.49   98.51     7  sh
02:25:02     1000      8902    1.49    0.00    0.00   98.51    1.49     7  sh
```

```console
# (b) Disable autogrouping node-wide (do this only if you manage CPU via cgroups)
$ echo 'kernel.sched_autogroup_enabled = 0' | sudo tee /etc/sysctl.d/90-sched.conf
kernel.sched_autogroup_enabled = 0
$ sudo sysctl --system | grep autogroup
kernel.sched_autogroup_enabled = 0
```

> **Regla diagnóstica:** antes de concluir "nice no funciona", revisá siempre `cat /proc/<pid>/autogroup` tanto para la víctima *como* para el ofensor. Si los nombres de grupo difieren, los valores de nice no se están comparando entre sí.

---

## 5. Políticas de planificación: `chrt`

`nice` existe únicamente dentro de `SCHED_OTHER`. Para cargas de trabajo con un contrato de latencia, la perilla es la política misma.

### 5.1 Comparación de políticas

| Política | Flag de `chrt` | Prio estática | ¿Expropia a `OTHER`? | Semántica | Uso en producción |
|---|---|---|---|---|---|
| `SCHED_OTHER` | `-o` | 0 (nice −20..19) | — | cuota proporcional EEVDF/CFS | todo, por defecto |
| `SCHED_BATCH` | `-b` | 0 (nice aplica) | no | como `OTHER` pero se asume no interactiva; se suprime la expropiación por despertar, rodajas efectivas más largas | compiladores, codificadores, ETL — mejor throughput, peor latencia |
| `SCHED_IDLE` | `-i` | 0 (nice se ignora) | no | peso 3; corre solo cuando no hay nada más ejecutable | `updatedb`, backups, scrubbers |
| `SCHED_RR` | `-r` | 1–99 | **sí** | round-robin dentro de un nivel de prioridad, quantum = `sched_rr_timeslice_ms` | pollers de paquetes, audio, control de movimiento |
| `SCHED_FIFO` | `-f` | 1–99 | **sí** | corre hasta que se bloquea o cede — sin quantum | hilos de IRQ, bucles de RT duro |
| `SCHED_DEADLINE` | `-d` | n/c (EDF) | **sí, por encima de FIFO** | CBS: (runtime, deadline, period) con control de admisión | bucles periódicos de sensado/control |

Orden: `DEADLINE` > `FIFO`/`RR` (por prio estática, gana la más alta) > `OTHER`/`BATCH` > `IDLE`.

### 5.2 Uso

```console
$ chrt -m
SCHED_OTHER min/max priority        : 0/0
SCHED_FIFO min/max priority         : 1/99
SCHED_RR min/max priority           : 1/99
SCHED_BATCH min/max priority        : 0/0
SCHED_IDLE min/max priority         : 0/0
SCHED_DEADLINE min/max priority     : 0/0

$ chrt -p 2210
pid 2210's current scheduling policy: SCHED_OTHER
pid 2210's current scheduling priority: 0

$ sudo chrt -f -p 50 2318
$ chrt -p 2318
pid 2318's current scheduling policy: SCHED_FIFO
pid 2318's current scheduling priority: 50

# Launch directly under a policy
$ sudo chrt -r 20 /usr/local/bin/xdp-poller --iface eth0
$ chrt -i 0 nice ionice -c3 /usr/bin/updatedb
0

# SCHED_DEADLINE: 2 ms of runtime every 10 ms period
$ sudo chrt -d --sched-runtime 2000000 --sched-deadline 10000000 \
             --sched-period 10000000 0 ./control-loop
$ chrt -p $(pgrep control-loop)
pid 9134's current scheduling policy: SCHED_DEADLINE
pid 9134's current scheduling priority: 0
pid 9134's current runtime/deadline/period parameters: 2000000/10000000/10000000
```

`SCHED_DEADLINE` realiza **control de admisión**: el kernel rechaza la llamada si el ancho de banda total `Σ(runtime/period)` excediera lo permitido. Esto es una característica — es la única política de Linux que no puede sobresuscribirse.

```console
$ sudo chrt -d --sched-runtime 900000000 --sched-deadline 1000000000 \
             --sched-period 1000000000 0 ./greedy
chrt: failed to set pid 0's policy: Device or resource busy
```

### 5.3 La red de seguridad de RT — y cómo no sacarla

Un bucle ocupado `SCHED_FIFO` sin límite con prioridad 99 en una VM de una sola CPU va a trabar la máquina: nada más, incluido tu demonio SSH, va a poder correr jamás. Linux trae un limitador:

```console
$ sysctl kernel.sched_rt_period_us kernel.sched_rt_runtime_us
kernel.sched_rt_period_us = 1000000
kernel.sched_rt_runtime_us = 950000
```

Las clases RT obtienen a lo sumo 950 ms de cada 1 s (95 %), dejando 5 % para `SCHED_OTHER`. Esto es lo que te salva.

| Ajuste | Efecto | Veredicto |
|---|---|---|
| `sched_rt_runtime_us = 950000` | techo RT de 95 % (por defecto) | ✅ dejalo |
| `sched_rt_runtime_us = 990000` | techo de 99 % | ⚠️ solo con un watchdog y acceso a consola fuera de banda |
| `sched_rt_runtime_us = -1` | limitación **desactivada** | ❌ un bug = nodo irrecuperable, sin SSH, sin kubelet |

Si tenés que desactivarla (equipos de RT duro con `isolcpus` + `nohz_full`), también tenés que aislar las CPU de RT y conservar un núcleo de mantenimiento:

```
# /etc/default/grub  → GRUB_CMDLINE_LINUX_DEFAULT
isolcpus=nohz,domain,managed_irq,8-15 nohz_full=8-15 rcu_nocbs=8-15 irqaffinity=0-7
```

### 5.4 Inversión de prioridad — el modo de falla que vuelve a RT peor que nada

Una tarea `SCHED_FIFO` con prio 80 se bloquea en un mutex retenido por una tarea con nice 0. Un consumidor de CPU con nice 0 ahora impide que corra el poseedor del lock, lo que impide que la tarea RT llegue a correr alguna vez. La tarea RT se convirtió, en los hechos, en lo de *menor* prioridad de la máquina.

Linux ofrece **herencia de prioridad** solamente a través de futexes PI (`pthread_mutexattr_setprotocol(..., PTHREAD_PRIO_INHERIT)`), a los que la aplicación debe adherirse explícitamente. No hay arreglo automático a nivel de kernel.

**Regla arquitectónica:** nunca promuevas un proceso a una política de tiempo real salvo que sepas que cada lock que toma es o bien PI, o bien no disputado por tareas no RT. Promover un demonio cualquiera a `SCHED_FIFO` "porque es importante" es la manera de convertir un pico de latencia intermitente en un cuelgue duro.

---

## 6. Prioridades de E/S y cgroup v2

### 6.1 `ionice(1)`

La prioridad de CPU y la de E/S son independientes. Un `rsync` con nice 19 sigue emitiendo las mismas peticiones de bloque con la misma profundidad.

| Clase | `-c` | Niveles de prioridad | Semántica |
|---|---|---|---|
| none | 0 | — | no fijada explícitamente; el kernel deriva best-effort a partir del nice |
| realtime | 1 | 0–7 (0 = la más alta) | se sirve primero; puede matar de hambre a todo lo demás. Requiere `CAP_SYS_NICE` |
| best-effort | 2 | 0–7 | clase por defecto |
| idle | 3 | n/c | se sirve solo cuando no hay ninguna otra E/S pendiente |

El valor por defecto derivado es:

```
best_effort_prio = (nice + 20) / 5      →  nice 0 ⇒ 4,  nice 19 ⇒ 7,  nice -20 ⇒ 0
```

```console
$ ionice -p 1
none: prio 4

$ ionice
none: prio 4

$ sudo ionice -c 3 -p 4412
$ ionice -p 4412
idle

$ ionice -c 2 -n 7 -p 4412
$ ionice -p 4412
best-effort: prio 7

$ ionice -c 3 -t nice -n 19 rsync -aHAX /data/ /backup/data/
```

`-t` le dice a `ionice` que ignore la falla y ejecute el comando igual — el mismo riesgo de falla silenciosa que `nice`.

> **⚠️ La trampa más grande de `ionice`:** la clase y la prioridad son respetadas **únicamente por el planificador de E/S BFQ**. `mq-deadline`, `kyber` y `none` las ignoran por completo. Desde la eliminación de CFQ en Linux 5.0, la mayoría de las distribuciones ponen los dispositivos NVMe en `none` por defecto — donde `ionice` es un **no-op**.

```console
$ cat /sys/block/nvme0n1/queue/scheduler
[none] mq-deadline kyber bfq

$ cat /sys/block/sda/queue/scheduler
mq-deadline kyber [bfq] none
```

En el `nvme0n1` de arriba, cada comando `ionice` que escribas no hace nada. Verificá antes de depender de él. Para cambiarlo (y entendiendo que estás cambiando IOPS crudos por equidad):

```ini
# /etc/udev/rules.d/60-ioscheduler.rules
# Rotational devices → BFQ (fairness, honours ionice)
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
# NVMe → none (lowest overhead); use cgroup io.latency for isolation instead of ionice
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
```

### 6.2 cgroup v2 — la capa que realmente aguanta en producción

```console
$ mount | grep cgroup2
cgroup2 on /sys/fs/cgroup type cgroup2 (rw,nosuid,nodev,noexec,relatime,nsdelegate,memory_recursive_prot)

$ cat /sys/fs/cgroup/cgroup.controllers
cpuset cpu io memory hugetlb pids rdma misc
```

| Archivo de interfaz | Rango / formato | Significado |
|---|---|---|
| `cpu.weight` | 1–10000, por defecto **100** | cuota proporcional entre hermanos — el análogo de nice a nivel cgroup |
| `cpu.weight.nice` | −20…19, por defecto 0 | la misma perilla expresada en la escala de nice (capa de traducción) |
| `cpu.max` | `"MAX PERIOD"`, ej. `200000 100000` | tope **duro** de ancho de banda: 2 CPU |
| `cpu.idle` | 0 / 1 | 1 ⇒ toda tarea del cgroup se planifica como `SCHED_IDLE` |
| `cpu.pressure` | PSI | porcentajes de estancamiento `some`/`full` — la señal real de inanición |
| `cpu.stat` | contadores | `nr_throttled`, `throttled_usec` |
| `io.weight` | 1–10000 | cuota proporcional de E/S de BFQ |
| `io.latency` | `MAJ:MIN target=USEC` | SLO de latencia; limita a los *otros* cgroups para proteger a este |
| `io.max` | `MAJ:MIN rbps=… wiops=…` | tope duro de E/S |

```console
$ cd /sys/fs/cgroup/system.slice
$ cat indexer.service/cpu.weight api.service/cpu.weight
100
100

$ echo 1    | sudo tee indexer.service/cpu.weight
1
$ echo 10000 | sudo tee api.service/cpu.weight
10000

$ cat indexer.service/cpu.stat
usage_usec 918234112
user_usec 902118440
system_usec 16115672
nr_periods 0
nr_throttled 0
throttled_usec 0
```

`cpu.weight` le gana a `nice` para aislar servicio contra servicio por una razón decisiva: es **jerárquico e indiferente a los hilos**. Cada hilo actual y futuro del servicio lo hereda, sin ningún bucle `for t in /proc/*/task/*` y sin sorpresas de autogroup.

**Tabla de compromisos — elegí el instrumento correcto:**

| Instrumento | Alcance | ¿Conserva trabajo? | ¿Sobrevive a hilos nuevos? | ¿Cruza cgroups? | ¿Garantía dura? |
|---|---|---|---|---|---|
| `nice`/`renice` | un **hilo** | sí | ❌ no | ❌ no | no |
| nice de autogroup | una sesión | sí | sí | ❌ no | no |
| `cpu.weight` | subárbol de cgroup | sí | ✅ sí | ✅ sí | no (solo cuota) |
| `cpu.max` | subárbol de cgroup | **no** (desperdicia CPU ociosa) | ✅ sí | ✅ sí | ✅ techo |
| `cpuset.cpus` | subárbol de cgroup | no | ✅ sí | ✅ sí | ✅ partición |
| `SCHED_IDLE` / `cpu.idle` | hilo / cgroup | sí | hilo: ❌ / cgroup: ✅ | ✅ sí | ✅ piso de 0 |
| `SCHED_FIFO/RR` | hilo | sí | ❌ no | ✅ sí (global) | ✅ pero peligroso |
| `SCHED_DEADLINE` | hilo | no | ❌ no | ✅ sí | ✅ con control de admisión |

> **`cpu.max` vs `cpu.weight`:** una cuota no es gratis. `cpu.max` limita incluso cuando la máquina está 90 % ociosa, y la limitación de ancho de banda de CFS es una fuente documentada de picos de latencia p99 para runtimes multihilo (todos los hilos queman la cuota en los primeros milisegundos del período, y después la aplicación entera duerme el resto). Preferí `cpu.weight` para aislamiento y reservá `cpu.max` para fronteras de tenencia/facturación donde la previsibilidad le gana al throughput.

---

## 7. Manifiestos de infraestructura

### 7.1 Unit de systemd — la API de baja latencia

```ini
# /etc/systemd/system/api.service
[Unit]
Description=Latency-critical gRPC API
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/api-server --config /etc/api/config.yaml
Restart=on-failure
RestartSec=2s

# ---- CPU priority: the per-task layer -------------------------------------
# Nice= is applied via setpriority(2) on the main process before exec and is
# inherited by every child and thread it creates thereafter.
Nice=-5
# LimitNICE is RLIMIT_NICE, expressed by systemd on the NICE scale (not inverted).
LimitNICE=-10

# ---- CPU priority: the cgroup layer (this is the one that actually holds) --
CPUAccounting=yes
CPUWeight=10000
# Extra weight during boot/startup only, released once the unit is "started".
StartupCPUWeight=10000
# NO CPUQuota= here on purpose: this workload must be able to burst.

# ---- I/O ------------------------------------------------------------------
IOAccounting=yes
IOWeight=1000
# Protect this service's read latency; the kernel throttles *other* cgroups
# when this one exceeds the target. Requires the io controller + BFQ or blk-iolatency.
IODeviceLatencyTargetSec=/dev/nvme0n1 2ms

# ---- Memory ---------------------------------------------------------------
MemoryAccounting=yes
MemoryLow=8G
OOMScoreAdjust=-500

# ---- Hardening ------------------------------------------------------------
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
# CAP_SYS_NICE is required only if the process lowers its OWN threads' nice
# at runtime; Nice=/LimitNICE= above are applied by systemd (PID 1), which
# already has the capability, so most services do NOT need this.
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/indexer.service
[Unit]
Description=Nightly corpus indexer (background, must never disturb api.service)
After=api.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/indexer --corpus /data/corpus

# ---- CPU ------------------------------------------------------------------
Nice=19
# The decisive setting: 1/10000th of api.service's share at every contention point.
CPUAccounting=yes
CPUWeight=1
# Also cap it, so an indexer bug cannot consume a whole node even when idle
# capacity exists and cache pollution would still hurt the API.
CPUQuota=400%
# Keep it off the API's cores entirely on this NUMA-partitioned node.
AllocationCPUs=
CPUAffinity=20-39

# ---- Scheduling policy ----------------------------------------------------
CPUSchedulingPolicy=batch
# (Use CPUSchedulingPolicy=idle for a truly best-effort job. For RT units:
#  CPUSchedulingPolicy=rr + CPUSchedulingPriority=1..99 + LimitRTPRIO=.)

# ---- I/O ------------------------------------------------------------------
IOAccounting=yes
IOSchedulingClass=idle
IOWeight=1
IOReadBandwidthMax=/dev/nvme0n1 200M
IOWriteBandwidthMax=/dev/nvme0n1 100M

[Install]
WantedBy=multi-user.target
```

Aplicar y verificar:

```console
$ sudo systemctl daemon-reload && sudo systemctl restart api.service indexer.service

$ systemctl show api.service -p Nice -p CPUWeight -p CPUSchedulingPolicy -p LimitNICE
Nice=-5
CPUWeight=10000
CPUSchedulingPolicy=0
LimitNICE=30

$ systemd-cgls /system.slice/indexer.service
Control group /system.slice/indexer.service:
└─ 9455 /usr/local/bin/indexer --corpus /data/corpus

$ systemd-cgtop -1 --order=cpu | head -6
Control Group                    Tasks   %CPU   Memory  Input/s Output/s
/                                  1204 3891.2    71.2G    12.1M    88.4M
/system.slice/api.service           212 3402.7     6.1G     1.2M     4.0M
/system.slice/indexer.service        48  398.9     2.4G    10.4M    81.2M
/system.slice/kubelet.service        61   41.2   812.0M        -    1.1M
```

Ad-hoc, sin escribir una unit — la manera correcta de ejecutar un trabajo pesado puntual en un nodo de producción:

```console
$ systemd-run --scope --unit=oneoff-reindex \
    -p CPUWeight=1 -p CPUQuota=200% -p Nice=19 \
    -p IOWeight=1 -p IOSchedulingClass=idle \
    /usr/local/bin/reindex --all
Running scope as unit: oneoff-reindex.scope

# Retune it live, without restarting
$ sudo systemctl set-property --runtime oneoff-reindex.scope CPUQuota=50%
```

### 7.2 Kubernetes: qué mapea a qué

**No hay campo `nice` en una spec de Pod.** Entender qué *sí* expone Kubernetes — y qué no — es la diferencia entre una estrategia de aislamiento que funciona y un culto de la carga.

| Concepto de Kubernetes | Mecanismo del kernel | ¿Afecta el tiempo de CPU? |
|---|---|---|
| `resources.requests.cpu` | **`cpu.weight`** de cgroup | ✅ **sí** — esta es la verdadera perilla de prioridad |
| `resources.limits.cpu` | **`cpu.max`** de cgroup (quota/period) | ✅ tope duro, provoca throttling |
| Clase QoS (Guaranteed/Burstable/BestEffort) | `oom_score_adj` + orden de desalojo | ❌ no (solo memoria/desalojo) |
| `PriorityClass` / `priority` | admisión y expropiación del planificador | ❌ no (qué nodo, no qué ciclo) |
| `spec.containers[].securityContext.capabilities` `SYS_NICE` | permite `setpriority`/`sched_setscheduler` dentro del contenedor | habilita a la app a reniciarse a sí misma |

La conversión `requests.cpu` → `cpu.weight` que realiza el kubelet:

```
shares  = max(2, millicores * 1024 / 1000)                  # cgroup v1 units
weight  = 1 + ((shares - 2) * 9999) / (262144 - 2)          # v1 → v2 translation
```

| `requests.cpu` | shares | `cpu.weight` |
|---|---:|---:|
| `100m` | 102 | 4 |
| `500m` | 512 | 20 |
| `1` | 1024 | **39** |
| `4` | 4096 | 157 |
| `16` | 16384 | 626 |

Manifiesto completo — la misma división api/indexer, expresada en Kubernetes:

```yaml
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: latency-critical
value: 1000000
globalDefault: false
preemptionPolicy: PreemptLowerPriority
description: >-
  Scheduling/eviction priority only. This does NOT give the pod more CPU time;
  CPU time comes from resources.requests.cpu, which the kubelet translates
  into cgroup v2 cpu.weight.
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: background-batch
value: 100
globalDefault: false
preemptionPolicy: Never
description: Never preempts anything; first to be evicted under node pressure.
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-server
  namespace: prod
  labels:
    app.kubernetes.io/name: api-server
spec:
  replicas: 6
  selector:
    matchLabels:
      app.kubernetes.io/name: api-server
  template:
    metadata:
      labels:
        app.kubernetes.io/name: api-server
    spec:
      priorityClassName: latency-critical
      # Guaranteed QoS: requests == limits for every container and every resource.
      # On a node with the static CPUManager policy this also grants exclusive
      # pinned cores, which removes scheduler contention entirely.
      containers:
        - name: api
          image: registry.internal/api-server:1.24.3
          command: ["/usr/local/bin/api-server"]
          args: ["--config=/etc/api/config.yaml"]
          ports:
            - name: grpc
              containerPort: 8443
              protocol: TCP
          resources:
            requests:
              cpu: "4"           # -> cpu.weight 157
              memory: "8Gi"
            limits:
              cpu: "4"           # requests == limits -> Guaranteed
              memory: "8Gi"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            capabilities:
              drop: ["ALL"]
              # SYS_NICE lets the runtime pin/prioritise its own worker threads.
              # Grant ONLY if the application actually calls sched_setaffinity(2)
              # or setpriority(2) with a negative adjustment.
              add: ["SYS_NICE"]
          readinessProbe:
            grpc:
              port: 8443
            initialDelaySeconds: 5
            periodSeconds: 5
          volumeMounts:
            - name: config
              mountPath: /etc/api
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: api-config
      tolerations:
        - key: workload
          operator: Equal
          value: latency-critical
          effect: NoSchedule
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: corpus-indexer
  namespace: prod
spec:
  schedule: "0 2 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          restartPolicy: Never
          priorityClassName: background-batch
          containers:
            - name: indexer
              image: registry.internal/indexer:0.9.1
              command: ["/usr/local/bin/indexer"]
              args: ["--corpus=/data/corpus"]
              resources:
                requests:
                  cpu: "100m"    # -> cpu.weight 4  (39x less than the API's 157)
                  memory: "2Gi"
                limits:
                  cpu: "8"       # may burst into idle capacity...
                  memory: "4Gi"  # ...but yields instantly when the API needs CPU
              securityContext:
                allowPrivilegeEscalation: false
                runAsNonRoot: true
                runAsUser: 10002
                capabilities:
                  drop: ["ALL"]
              volumeMounts:
                - name: corpus
                  mountPath: /data/corpus
          volumes:
            - name: corpus
              persistentVolumeClaim:
                claimName: corpus-pvc
```

Fijate en la asimetría deliberada del CronJob: `requests.cpu: 100m` con `limits.cpu: 8`. Request bajo = `cpu.weight` bajo = cede bajo contención. Límite alto = `cpu.max` alto = usa la capacidad ociosa cuando la API está tranquila. Este es el **patrón batch que conserva trabajo**, y es estrictamente mejor que un `nice 19` dentro del contenedor, que además el contenedor no podría fijar sin `SYS_NICE`.

Verificá que el kubelet realmente haya producido lo que esperás:

```console
$ POD=$(kubectl -n prod get pod -l app.kubernetes.io/name=api-server -o jsonpath='{.items[0].metadata.name}')
$ NODE=$(kubectl -n prod get pod "$POD" -o jsonpath='{.spec.nodeName}')
$ UID_=$(kubectl -n prod get pod "$POD" -o jsonpath='{.metadata.uid}' | tr '-' '_')

$ ssh "$NODE" "cat /sys/fs/cgroup/kubepods.slice/kubepods-pod${UID_}.slice/cpu.weight"
157

$ ssh "$NODE" "cat /sys/fs/cgroup/kubepods.slice/kubepods-pod${UID_}.slice/cpu.max"
400000 100000

$ ssh "$NODE" "cat /sys/fs/cgroup/kubepods.slice/kubepods-besteffort.slice/cpu.weight"
1
```

---

## 8. Verificación y diagnóstico de fallas

### 8.1 La escalera de verificación

Nunca afirmes que un cambio de prioridad tuvo éxito — releélo. En orden creciente de rigor:

```console
# Rung 1: was the value accepted?
$ ps -o pid,tid,ni,cls,rtprio,comm -L -p 4412 | head -4
    PID     TID  NI CLS RTPRIO COMMAND
   4412    4412  19  TS      - indexer
   4412    4413  19  TS      - indexer
   4412    4414  19  TS      - indexer

$ chrt -p 4412
pid 4412's current scheduling policy: SCHED_OTHER
pid 4412's current scheduling priority: 0

$ ionice -p 4412
idle

# Rung 2: is the scheduler using the weight you think it is?
$ grep -E 'se.load.weight|policy|prio|nr_involuntary' /proc/4412/sched
se.load.weight                               :                15360
policy                                       :                    0
prio                                         :                  139
nr_involuntary_switches                      :               412809
```

> `se.load.weight` está **escalado por 2^10 en kernels de 64 bits**. `15360 = 15 × 1024` = nice 19. Una tarea con nice 0 muestra `1048576`. Si ves `1048576` después de reniciar "con éxito" a 19, reniciaste el hilo equivocado.

```console
# Rung 3: is it actually being starved / is it actually starving someone?
# /proc/<pid>/schedstat = <time_on_cpu_ns> <runqueue_wait_ns> <timeslices>
$ cat /proc/4412/schedstat
918234112000 41209884773991 412809
$ cat /proc/2210/schedstat
3441290551000 2118440221 918442
```

El indexador esperó **41 209 s** en la runqueue para obtener 918 s de CPU (4400 % de espera/ejecución). La API esperó 2,1 s para 3441 s de CPU (0,06 %). Esa es una configuración *correcta*, probada cuantitativamente. Invertí esos números y tenés tu incidente.

```console
# Rung 4: pressure stall information — the SLO-level signal
$ cat /sys/fs/cgroup/system.slice/api.service/cpu.pressure
some avg10=0.11 avg60=0.09 avg300=0.14 total=88412991
full avg10=0.00 avg60=0.00 avg300=0.00 total=0

$ cat /sys/fs/cgroup/system.slice/indexer.service/cpu.pressure
some avg10=94.22 avg60=91.87 avg300=88.03 total=8811240991
full avg10=91.02 avg60=88.44 avg300=84.19 total=8402118440
```

El `some avg10` de la API es 0,11 % — no está esperando. El indexador está estancado el 94 % del tiempo. Exactamente el resultado buscado. **El PSI de la carga protegida es la métrica sobre la que alertar**, no la utilización de CPU.

```console
# Rung 5: quota throttling (only meaningful when cpu.max is set)
$ cat /sys/fs/cgroup/system.slice/indexer.service/cpu.stat
usage_usec 918234112
nr_periods 88124
nr_throttled 71209
throttled_usec 412098844
```

`nr_throttled / nr_periods = 80,8 %` — esta carga está limitada por cuota, no por peso. Si esto fuera la API, esa relación sería tu bug de latencia p99, y el arreglo es subir `limits.cpu` (o quitarlo), **no** tocar nice.

### 8.2 Laboratorio reproducible

```bash
#!/usr/bin/env bash
# nice-lab.sh — prove the weight table on a single core. Run as a normal user.
set -euo pipefail

CPU=${CPU:-$(( $(nproc) - 1 ))}     # last CPU; keep the others free
DURATION=${DURATION:-6}

hog() {  # $1 = nice value
    taskset -c "$CPU" nice -n "$1" \
        setsid --wait sh -c 'while :; do :; done' &
    echo $!
}

run_case() {
    local a=$1 b=$2 same_session=$3
    echo "=== nice $a vs nice $b  (same autogroup: $same_session) ==="
    if [[ $same_session == yes ]]; then
        taskset -c "$CPU" nice -n "$a" sh -c 'while :; do :; done' & local pa=$!
        taskset -c "$CPU" nice -n "$b" sh -c 'while :; do :; done' & local pb=$!
    else
        local pa pb; pa=$(hog "$a"); pb=$(hog "$b")
    fi
    sleep 1
    pidstat -p "$pa","$pb" "$DURATION" 1 | tail -n +4
    kill -- -"$pa" "$pa" 2>/dev/null || true
    kill -- -"$pb" "$pb" 2>/dev/null || true
    wait 2>/dev/null || true
    echo
}

run_case 0  0  yes     # expect 50 / 50
run_case 0  5  yes     # expect 75 / 25
run_case 0 19  yes     # expect 98.6 / 1.4
run_case 0 19  no      # expect 50 / 50  <-- the autogroup effect
```

```console
$ ./nice-lab.sh
=== nice 0 vs nice 0  (same autogroup: yes) ===
02:41:12     1000     11201   50.17    0.00    0.00   49.83   50.17    39  sh
02:41:12     1000     11202   49.83    0.00    0.00   50.17   49.83    39  sh

=== nice 0 vs nice 5  (same autogroup: yes) ===
02:41:20     1000     11244   75.33    0.00    0.00   24.67   75.33    39  sh
02:41:20     1000     11245   24.67    0.00    0.00   75.33   24.67    39  sh

=== nice 0 vs nice 19  (same autogroup: yes) ===
02:41:28     1000     11288   98.50    0.00    0.00    1.50   98.50    39  sh
02:41:28     1000     11289    1.50    0.00    0.00   98.50    1.50    39  sh

=== nice 0 vs nice 19  (same autogroup: no) ===
02:41:36     1000     11333   50.00    0.00    0.00   50.00   50.00    39  sh
02:41:36     1000     11334   50.00    0.00    0.00   50.00   50.00    39  sh
```

Tres predicciones confirmadas, y una demostración deliberada de la trampa. `taskset -c` no es decoración: en una máquina de 40 núcleos, dos consumidores nunca compiten, y el experimento entero muestra silenciosamente 100/100.

### 8.3 Catálogo de fallas

| Síntoma | Causa raíz | Confirmar con | Arreglo |
|---|---|---|---|
| `nice -n 19` no tiene efecto | el ofensor y la víctima están en **autogroups** distintos | `cat /proc/<pid>/autogroup` para ambos | escribir el valor de nice en `/proc/<pid>/autogroup`, o fijar `kernel.sched_autogroup_enabled=0`, o pasar a cgroups |
| `nice -n 19` no tiene efecto | el ofensor y la víctima están en **cgroups** distintos | `cat /proc/<pid>/cgroup` para ambos | fijar `cpu.weight` / `CPUWeight=` en los cgroups |
| `nice -n 19` no tiene efecto | hay CPU de sobra; nada está compitiendo | `vmstat 1` → columna `r` ≤ `nproc` | nada que arreglar — la contención está en otro lado (E/S, ancho de banda de memoria, locks) |
| `renice` "tuvo éxito" pero el proceso sigue acaparando | el nice de Linux es **por hilo**; solo cambió el hilo principal | `ps -L -o tid,ni -p <pid>` | iterar sobre `/proc/<pid>/task/*`, o usar un cgroup |
| `nice: cannot set niceness: Permission denied`, salida 0 | ajuste negativo sin `CAP_SYS_NICE`/`RLIMIT_NICE` | `ulimit -e`, `prlimit --pid $$ --nice` | `limits.conf` con `nice 30`, o `LimitNICE=`/`Nice=` en la unit |
| `renice: failed to set priority for 4412 (process ID): Operation not permitted` | no sos el dueño, o intentás bajar sin privilegios | `ps -o user -p <pid>`; `id` | ejecutar como root, o apuntar con `-u`/`-g` a tus propios procesos |
| El nice del servicio se reinicia tras cada restart | alguien usó `renice` en vez de editar la unit | `systemctl show <u> -p Nice` | fijar `Nice=` en la unit; `renice` nunca es persistente |
| Un backup con nice 19 igual hunde la latencia de disco | `ionice` es un no-op en `none`/`mq-deadline`/`kyber` | `cat /sys/block/<dev>/queue/scheduler` | cambiar a `bfq`, o usar `io.latency`/`io.max` (`IOReadBandwidthMax=`) |
| La máquina entera no responde, sin SSH | `SCHED_FIFO` descontrolado con la limitación de RT desactivada | consola serie/IPMI; `sysctl kernel.sched_rt_runtime_us` | restaurar `950000`; nunca desplegar `-1` sin `isolcpus` |
| Una tarea RT pierde deadlines mientras una tarea con nice 0 gira | **inversión de prioridad** en un mutex no PI | `cat /proc/<tid>/wchan`, `perf sched latency` | futexes PI en la app, o abandonar RT y usar `cpu.weight` |
| `chrt -d` → `Device or resource busy` | el control de admisión de `SCHED_DEADLINE` rechazó el ancho de banda | `sysctl kernel.sched_rt_runtime_us`; sumar el ancho de banda DL existente | reducir `--sched-runtime` o aumentar el período |
| Picos de latencia exactamente en los límites de período | **limitación de ancho de banda** de CFS por `cpu.max` / `limits.cpu` | `cpu.stat` → `nr_throttled`, `throttled_usec` | subir o quitar el límite de CPU; preferir `cpu.weight` para aislar |
| `top` muestra `%Cpu(s) ... 0.0 ni` mientras un trabajo reniciado corre a full | ese balde cuenta solo el tiempo de **usuario** con nice positivo en el muestreo por tick; el tiempo de kernel reniciado y el atribuido a cgroups van a otro lado | comparar con `pidstat` / `cpuacct` | confiar en la contabilidad por tarea/por cgroup, no en la línea de resumen |

### 8.4 One-liners de diagnóstico

```bash
# Every non-default nice value on the box, with its cgroup
ps -eLo tid,ni,cls,rtprio,comm --no-headers \
  | awk '$2 != 0 && $2 != "-" {print}' \
  | while read -r tid ni cls rt cmd; do
      printf '%-8s ni=%-4s cls=%-4s rt=%-4s %-20s %s\n' \
        "$tid" "$ni" "$cls" "$rt" "$cmd" "$(cut -d: -f3 /proc/$tid/cgroup 2>/dev/null | head -1)"
    done

# Every real-time thread — audit this after any incident
ps -eLo pid,tid,cls,rtprio,pri,comm | awk '$3 ~ /FF|RR|DLN/'

# Top 10 threads by runqueue wait time (starvation ranking)
for t in /proc/[0-9]*/task/[0-9]*; do
  [ -r "$t/schedstat" ] || continue
  read -r run wait n < "$t/schedstat"
  printf '%s %s %s\n' "$wait" "${t##*/}" "$(cat "$t/comm" 2>/dev/null)"
done | sort -rn | head -10

# cgroups sorted by CPU pressure
grep -H '^some' /sys/fs/cgroup/**/cpu.pressure 2>/dev/null \
  | sed 's#/sys/fs/cgroup/##; s#/cpu.pressure:some avg10=# #' \
  | sort -k2 -rn | head -10
```

### 8.5 Reglas de operación no negociables

1. **Nunca hagas `renice` a un proceso para arreglar un servicio.** Sobrevive hasta el próximo reinicio y nada más. Editá la unit o el cgroup.
2. **Nunca concedas `SCHED_FIFO`/`SCHED_RR` sin un techo de `RTPRIO`** (`LimitRTPRIO=`, `limits.conf`) y sin dejar habilitada la limitación de RT.
3. **Nunca desactives la limitación de RT en un nodo al que no podés llegar por IPMI/serie.**
4. **Nunca asumas que `ionice` funciona.** Revisá `/sys/block/*/queue/scheduler` primero, siempre.
5. **`nice` es una sugerencia sobre la importancia relativa entre hermanos; los `cgroups` son la capa de cumplimiento.** Usá lo primero para comodidad interactiva, lo segundo para cualquier cosa con un SLO.
6. **Probá el cambio con `schedstat` o `cpu.pressure`, no con la ausencia de quejas.**

---

## 9. Referencia de comandos

| Tarea | Comando |
|---|---|
| Mostrar el nice actual del shell | `nice` |
| Ejecutar con nice +10 (por defecto) | `nice COMMAND` |
| Ejecutar con nice +19 | `nice -n 19 COMMAND` |
| Ejecutar con nice −5 (requiere privilegios) | `sudo nice -n -5 COMMAND` |
| Fijar un proceso en ejecución a nice 5 | `renice -n 5 -p PID` |
| Reniciar todos los procesos de un usuario | `sudo renice -n 10 -u alice` |
| Reniciar un grupo de procesos | `sudo renice -n 10 -g PGID` |
| Reniciar cada hilo de un proceso | `for t in /proc/PID/task/*; do sudo renice -n 19 -p "${t##*/}"; done` |
| Mostrar nice/clase/rtprio | `ps -eLo pid,tid,ni,cls,rtprio,comm` |
| Vista interactiva + renice | `top` → `r`, después el PID, después el valor |
| Consultar la política de planificación | `chrt -p PID` |
| Fijar `SCHED_FIFO` prio 50 | `sudo chrt -f -p 50 PID` |
| Fijar `SCHED_IDLE` | `sudo chrt -i -p 0 PID` |
| Mostrar los rangos de prioridad válidos | `chrt -m` |
| Consultar la prioridad de E/S | `ionice -p PID` |
| E/S de clase idle | `sudo ionice -c 3 -p PID` |
| Lanzamiento combinado en segundo plano | `chrt -i 0 nice -n 19 ionice -c 3 CMD` |
| RLIMIT_NICE de un proceso | `prlimit --pid PID --nice` |
| Autogroup de un proceso | `cat /proc/PID/autogroup` |
| Peso del cgroup | `cat /sys/fs/cgroup/<path>/cpu.weight` |
| Vista de CPU por cgroup en vivo | `systemd-cgtop` |
| Trabajo ad-hoc restringido | `systemd-run --scope -p CPUWeight=1 -p Nice=19 CMD` |
| Reajustar una unit en vivo | `systemctl set-property --runtime UNIT CPUWeight=50` |

**Datos críticos para el examen:** el nice por defecto es **0**; el rango va de **−20 (el más favorable)** a **19 (el menos favorable)**; solo un proceso privilegiado puede **bajar** un valor de nice; `nice` sin `-n` aplica **+10**; `nice -n` es un **incremento** mientras que `renice -n` de util-linux es **absoluto**; `nice -5` significa **+5**.

---

## 10. Referencias

**Objetivos oficiales de LPI**
- LPIC-1 Exam 101-500 Objectives (Topic 103.6) — https://www.lpi.org/our-certifications/exam-101-objectives/
- LPIC-1 Certification Overview — https://www.lpi.org/our-certifications/lpic-1-overview/

**Páginas de manual de Linux (upstream, Michael Kerrisk / proyecto kernel.org)**
- `nice(1)` — https://man7.org/linux/man-pages/man1/nice.1.html
- `renice(1)` — https://man7.org/linux/man-pages/man1/renice.1.html
- `nice(2)` — https://man7.org/linux/man-pages/man2/nice.2.html
- `getpriority(2)` / `setpriority(2)` — https://man7.org/linux/man-pages/man2/setpriority.2.html
- `sched(7)` — panorama de las API de planificación, políticas, autogroups y limitación de RT — https://man7.org/linux/man-pages/man7/sched.7.html
- `sched_setscheduler(2)` — https://man7.org/linux/man-pages/man2/sched_setscheduler.2.html
- `sched_setattr(2)` — `SCHED_DEADLINE` y sugerencias de latencia por tarea — https://man7.org/linux/man-pages/man2/sched_setattr.2.html
- `chrt(1)` — https://man7.org/linux/man-pages/man1/chrt.1.html
- `ionice(1)` — https://man7.org/linux/man-pages/man1/ionice.1.html
- `ioprio_set(2)` / `ioprio_get(2)` — https://man7.org/linux/man-pages/man2/ioprio_set.2.html
- `getrlimit(2)` — `RLIMIT_NICE`, `RLIMIT_RTPRIO`, `RLIMIT_RTTIME` — https://man7.org/linux/man-pages/man2/getrlimit.2.html
- `capabilities(7)` — `CAP_SYS_NICE` — https://man7.org/linux/man-pages/man7/capabilities.7.html
- `proc(5)` / `proc_pid_stat(5)` — campos 18 (priority) y 19 (nice) — https://man7.org/linux/man-pages/man5/proc.5.html
- `ps(1)` — https://man7.org/linux/man-pages/man1/ps.1.html
- `top(1)` — https://man7.org/linux/man-pages/man1/top.1.html
- `taskset(1)` — https://man7.org/linux/man-pages/man1/taskset.1.html
- `limits.conf(5)` — https://man7.org/linux/man-pages/man5/limits.conf.5.html
- `cgroups(7)` — https://man7.org/linux/man-pages/man7/cgroups.7.html

**Documentación del kernel de Linux (kernel.org)**
- Diseño del planificador CFS — https://docs.kernel.org/scheduler/sched-design-CFS.html
- Planificador EEVDF — https://docs.kernel.org/scheduler/sched-eevdf.html
- Planificación de grupos de tiempo real y limitación de RT — https://docs.kernel.org/scheduler/sched-rt-group.html
- `SCHED_DEADLINE` — https://docs.kernel.org/scheduler/sched-deadline.html
- Estadísticas del planificador (`/proc/<pid>/schedstat`) — https://docs.kernel.org/scheduler/sched-stats.html
- Control Group v2 — `cpu.weight`, `cpu.max`, `cpu.idle`, `io.latency` — https://docs.kernel.org/admin-guide/cgroup-v2.html
- Pressure Stall Information (PSI) — https://docs.kernel.org/accounting/psi.html
- Planificador de E/S BFQ — https://docs.kernel.org/block/bfq-iosched.html
- Referencia de sysctl del kernel (`kernel.sched_*`) — https://docs.kernel.org/admin-guide/sysctl/kernel.html

**GNU coreutils**
- Invocación de `nice` — https://www.gnu.org/software/coreutils/manual/html_node/nice-invocation.html

**systemd (freedesktop.org)**
- `systemd.exec(5)` — `Nice=`, `CPUSchedulingPolicy=`, `CPUSchedulingPriority=`, `IOSchedulingClass=`, `LimitNICE=` — https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- `systemd.resource-control(5)` — `CPUWeight=`, `CPUQuota=`, `IOWeight=`, `IODeviceLatencyTargetSec=` — https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html
- `systemd-run(1)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html
- `systemd-cgtop(1)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-cgtop.html

**Kubernetes**
- Resource Management for Pods and Containers — https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Pod Quality of Service Classes — https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- Pod Priority and Preemption — https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/
- Control CPU Management Policies on the Node — https://kubernetes.io/docs/tasks/administer-cluster/cpu-management-policies/