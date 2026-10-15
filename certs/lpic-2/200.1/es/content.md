# LPIC-2 — Tema 200.1: Medir y diagnosticar el uso de recursos

**Examen:** 201-450 · **Versión de los objetivos:** 4.5.0 · **Peso LPI:** 6 (de 120 entre los exámenes 201 y 202; 5,0 en el temario de este sitio, que escala LPIC-2 a 100)
**Áreas de conocimiento clave:** medir CPU, memoria, I/O de disco e I/O de red; medir el throughput de firewalling y routing; mapear el uso de ancho de banda de los clientes; correlacionar síntomas del sistema con problemas probables; estimar throughput e identificar cuellos de botella.
**Archivos, términos y utilidades (lista parcial de LPI, textual):** `iostat`, `iotop`, `vmstat`, `netstat`, `ss`, `iptraf`, `pstree`, `ps`, `w`, `lsof`, `top`, `htop`, `uptime`, `sar`, swap, processes blocked on I/O, blocks in, blocks out.
Este material usa además herramientas que no están en esa lista (`mpstat`, `pidstat`, `ip`, `nstat`, PSI, cgroup v2); sirven en la práctica, pero el objetivo del examen es la lista de arriba.

> La salida de ejemplo de este documento es **ilustrativa**: se escribió para que sea coherente, no se capturó de un host, y los nombres de host, las fechas y las versiones de kernel que aparecen son inventados. **Los conjuntos de columnas difieren entre versiones de las herramientas** — el reporte extendido de `iostat` cambió sus campos en sysstat 11.5.7 (`avgqu-sz` pasó a ser `aqu-sz`) y eliminó `svctm` en 12.1.2, y `vmstat` muestra el tiempo de guest (`gu`) en su salida por defecto desde procps-ng 4.0.4 (`CHANGES` de sysstat, `NEWS` de procps-ng, ambos en las Referencias). Leé siempre el encabezado que imprime tu host, nunca el encabezado que recordás.

---

## 1. El problema arquitectónico: la utilización no es lo que te importa

Todo incidente de producción que empieza con "el servidor está lento" es una queja de **latencia**. Todo dashboard que se mira primero reporta **utilización**. Esas dos magnitudes están relacionadas por una curva que es casi plana y después casi vertical, y por eso la utilización es un proxy tan traicionero.

Para un único centro de servicio con llegadas aleatorias, el tiempo de residencia de un request es:

```
R = S / (1 - ρ)
```

donde `S` es el tiempo de servicio de un request y `ρ` es la utilización. La consecuencia práctica:

| Utilización ρ | Multiplicador de latencia `1/(1-ρ)` | Lo que percibe una persona |
|---|---|---|
| 0.50 | 2.0× | "normal" |
| 0.70 | 3.3× | "normal" |
| 0.80 | 5.0× | el p99 empieza a deshilacharse |
| 0.90 | 10× | tickets de "lentitud intermitente" |
| 0.95 | 20× | paginación, sin causa evidente en los gráficos de CPU |
| 0.98 | 50× | "el servidor está caído" (no lo está) |

Un gráfico de CPU clavado en 90 % y uno clavado en 50 % son del mismo color verde en la mayoría de los dashboards y difieren por un factor de tres en demora de encolamiento. Peor todavía, un dispositivo puede estar al **100 % de utilización y no ser el cuello de botella** (un disco NVMe que reporta `%util 100` puede estar sirviendo el 2 % de sus IOPS posibles), y un dispositivo puede estar al **40 % de utilización y ser absolutamente el cuello de botella** (un proceso single-threaded fijado a un core en una máquina de 16 cores topea en el 6,25 % de CPU a nivel de sistema).

Por eso el trabajo serio de medición separa tres magnitudes distintas por recurso — el **método USE**:

| Magnitud | Definición | Dónde la expone Linux | Modo de falla si solo seguís esto |
|---|---|---|---|
| **Utilización** | fracción del tiempo en que el recurso estuvo ocupado | `/proc/stat`, `/proc/diskstats`, `/proc/net/dev` | Oculta la saturación en dispositivos encolados; oculta el desbalance por core |
| **Saturación** | trabajo que tuvo que esperar porque el recurso estaba ocupado | `/proc/loadavg`, `aqu-sz`, `/proc/pressure/*`, `Recv-Q`, `cpu.stat` throttling | Ninguno — esta es la magnitud que correlaciona con el dolor del usuario |
| **Errores** | trabajo que se descartó o falló | `ip -s link`, `ethtool -S`, `nstat`, `dmesg`, `memory.events` | Los descartes silenciosos parecen "la red está bien, la app tiene bugs" |

**El segundo problema arquitectónico es el registro.** Las herramientas interactivas (`top`, `iostat 1`, `iotop`) solo pueden responder "qué está pasando ahora". Los incidentes se reportan en tiempo pasado. Un host sin un muestreador persistente tiene, para cada evento pasado, exactamente cero datos — y la frase más caras de operaciones es "esperemos a que vuelva a pasar". `sysstat` (`sadc` recolectando en `/var/log/sa/saDD`, `sar` leyéndolo de vuelta, `sadf` exportándolo) es la caja negra que convierte un post-mortem de especulación en aritmética. La sección 9 lo despliega como corresponde.

**El tercer problema es la contención/confinamiento.** En cualquier host que corra contenedores o control de recursos de systemd, los números a nivel de host ya no son los números que experimenta la carga de trabajo. Un proceso puede estar parado al 100 % de *su* asignación de CPU mientras el host reporta 30 % idle, porque el límite se aplica en `cpu.max` dentro de un cgroup y el throttling solo se ve en `cpu.stat`. Las métricas del host son necesarias e insuficientes; la sección 3.6 y la sección 4.5 cubren las vistas de cgroup v2.

---

## 2. De dónde salen realmente los números

Toda herramienta de este objetivo es un formateador sobre una de cinco interfaces del kernel. Saber cuál usa una herramienta te dice su costo, su resolución y sus modos de falla.

| Interfaz | Forma | Consumidores | Costo / resolución | Límites duros |
|---|---|---|---|---|
| `/proc/<file>` | ASCII, regenerado en cada lectura | `vmstat`, `top`, `free`, `mpstat`, `iostat`, `sar`, `netstat` | barato para archivos de tamaño fijo; **O(n) para archivos por objeto** | los contadores son monotónicos de 32/64 bits; sin historia; `/proc/net/tcp` re-renderiza cada socket como texto en cada lectura |
| `netlink` (`sock_diag`, `rtnetlink`) | binario, filtrable en el kernel | `ss`, `ip`, `nstat`, `tc` | el filtrado ocurre del lado del kernel, así que el costo escala con la *respuesta*, no con la tabla | necesita `CONFIG_INET_DIAG`; la semántica difiere por familia |
| `taskstats` / delay accounting | binario netlink por tarea | `iotop`, `pidstat -d` | I/O y demoras por tarea, exactos | necesita `CONFIG_TASK_DELAY_ACCT` **y** `kernel.task_delayacct=1` (apagado por defecto desde 5.14) |
| `perf_events` | ring buffer, muestreo + PMU | `perf`, flame graphs | contadores de hardware, resolución de ns | `kernel.perf_event_paranoid`; los contadores están virtualizados o son erróneos en muchas VMs |
| eBPF / tracepoints | agregación dentro del kernel | `biolatency`, `biosnoop`, `execsnoop`, `tcplife` | histogramas sin pérdida por muestreo, bajo overhead | kernel ≥ 4.9, realistamente ≥ 5.4, `CAP_BPF`, hay que instalar el tooling |

Dos consecuencias que deberías poder enunciar en un examen y defender en una revisión de arquitectura:

1. **`ss` no es simplemente "el `netstat` nuevo"** — es un camino de datos distinto. `netstat` parsea `/proc/net/tcp`, `/proc/net/tcp6`, `/proc/net/udp`, … como texto, y después (para `-p`) recorre `/proc/*/fd/*` para mapear inodos a procesos. En un host con muchos sockets esto se vuelve el comando más caro de la máquina.

```
$ ss -s | head -2
Total: 118427
TCP:   117981 (estab 116204, closed 1431, orphaned 0, timewait 1402)

$ time ss -tan > /dev/null
real    0m0.214s
user    0m0.061s
sys     0m0.151s

$ time netstat -tan > /dev/null
real    0m7.842s
user    0m1.903s
sys     0m5.914s

$ time netstat -tanp > /dev/null
real    1m12.418s
user    0m9.332s
sys     1m2.590s
```

   En un reverse proxy cargado, `netstat -tanp` es un incidente autoinfligido. Usá `ss`; guardate `netstat` para las preguntas de examen y para leer runbooks antiguos.

2. **Semántica de los contadores**: casi todo en `/proc` es un contador monotónico desde el boot, no una tasa. `vmstat 5`, `iostat 5`, `sar` y los exporters calculan los deltas por ti. La **primera línea de la salida de `vmstat`, `iostat`, `mpstat`, `sar` es el promedio desde el boot** y hay que descartarla — este único error invalida más reportes de capacidad que cualquier otro.

---

## 3. CPU

### 3.1 El modelo de contabilización

`/proc/stat` acumula, por CPU y en total, los ticks pasados en cada estado. La unidad interna del kernel es `USER_HZ` (100 Hz en x86_64, es decir un jiffy = 10 ms), independientemente del tick real del scheduler:

```
$ head -4 /proc/stat
cpu  48123944 11204 9983012 1472339108 2104771 0 492013 1831904 0 0
cpu0 3011901 702 624312 92013441 131604 0 61204 114702 0 0
cpu1 2998412 688 619884 92110223 129911 0 30112 113884 0 0
cpu2 3004118 711 621044 92071004 130442 0 29884 114011 0 0

$ getconf CLK_TCK
100
```

Orden de los campos, que es también el orden de las columnas en `mpstat`:

| # | Campo | Significado | Peso diagnóstico |
|---|---|---|---|
| 1 | `user` | espacio de usuario, nice ≤ 0 | el trabajo por el que estás pagando |
| 2 | `nice` | espacio de usuario, nice > 0 | trabajo batch/de fondo |
| 3 | `system` | kernel en nombre de una tarea (syscalls) | alto ⇒ tormenta de syscalls, contención de locks, I/O con muchas copias |
| 4 | `idle` | idle, sin I/O pendiente | — |
| 5 | `iowait` | **idle con al menos un I/O pendiente en esta CPU** | una pista sobre los discos, no una medida de ellos |
| 6 | `irq` | atención de interrupciones de hardware | alto ⇒ problema de afinidad de IRQ de NIC/almacenamiento |
| 7 | `softirq` | trabajo de interrupción diferido (`NET_RX`, `NET_TX`, `BLOCK`, `TIMER`, `RCU`) | **el techo habitual del throughput en paquetes por segundo** |
| 8 | `steal` | ejecutable pero el hipervisor corrió a otro | la única métrica honesta de "vecino ruidoso" |
| 9 | `guest` | ejecutando una vCPU de guest (vista del host) | hosts KVM |
| 10 | `guest_nice` | guest con nice > 0 | hosts KVM |

**`%iowait` es el número peor interpretado de Linux.** Es un estado de *CPU*, no un estado de disco. Solo se acumula cuando la CPU no tenía otra cosa que ejecutar. Por lo tanto:

- Un arreglo de discos completamente saturado con una CPU ocupada reporta `%iowait ≈ 0`.
- Un `dd` single-threaded en un host idle de 16 CPUs reporta `%iowait ≈ 6 %` aunque ese proceso esté 100 % bloqueado.
- `%iowait` subiendo mientras el throughput *cae* es la señal real (el sistema espera más y consigue menos).

Medí los discos con `iostat`/`biolatency`; usá `%iowait` solo como indicador.

### 3.2 Load average — qué cuenta en Linux

```
$ cat /proc/loadavg
7.41 6.88 5.02 4/1283 884219
```

Campos: promedios móviles exponenciales de 1/5/15 minutos, tareas `running/total`, último PID. Las constantes de decaimiento del EWMA son `exp(-5/60)`, `exp(-5/300)`, `exp(-5/900)`, actualizadas cada 5 segundos.

La parte específica de Linux — y una trampa clásica de examen — es **qué entra en el promedio**:

| Familia de SO | Contado en el load average |
|---|---|
| UNIX clásico (Solaris, BSD antiguo) | solo tareas en `R` (running + ejecutables) — una métrica pura de demanda de CPU |
| **Linux** | tareas en `R` **y** `D` (sleep ininterrumpible: block I/O, algunas esperas de NFS, ciertos locks) |

Así que en Linux un load average de 40 en un host de 16 CPUs puede significar "la demanda de CPU es 2,5× la capacidad" **o** "16 CPUs idle y 40 procesos bloqueados en un montaje NFS muerto". El load average por sí solo nunca puede distinguirlos. La desambiguación es un comando:

```
$ vmstat 5 3
procs -----------memory---------- ---swap-- -----io---- -system-- -------cpu-------
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st gu
 2  0  73216 1284992 912384 19884416    0    0   184   412 2104  4881  7  3 89  1  0  0
 1 38  73216 1261504 912512 19901824    0    0 182304  118 9842 14207  4  6 49 41  0  0
 0 41  73216 1258880 912512 19906048    0    0 196112   96 10114 14998  3  7 48 42  0  0
```

`r` es la cola de ejecución (demanda de CPU), `b` es lo bloqueado en I/O. Acá `r` es ~1 sobre 16 CPUs y `b` es ~40: este host **no tiene ningún problema de CPU**, y un load average cerca de 40. Derivá esto a la sección 5.

### 3.3 `uptime` y `w`

```
$ uptime
 11:02:17 up 94 days,  3:12,  3 users,  load average: 7.41, 6.88, 5.02

$ uptime -p
up 3 months, 4 days, 3 hours, 12 minutes

$ uptime -s
2026-07-13 07:50:04

$ w
 11:02:21 up 94 days,  3:12,  3 users,  load average: 7.41, 6.88, 5.02
USER     TTY      FROM              LOGIN@   IDLE   JCPU   PCPU WHAT
root     pts/0    10.20.0.14        10:58    0.00s  0.09s  0.00s w
deploy   pts/1    10.20.0.31        09:12    1:44m  0.21s  0.21s -bash
deploy   pts/2    10.20.0.31        10:41    2:03   4:51   4:48  python3 reindex.py
```

- `JCPU` — CPU consumida por **todos** los procesos asociados a esa TTY (incluidos los ya terminados); `PCPU` — CPU del proceso listado en `WHAT`. En `pts/2`, `JCPU ≈ PCPU`, así que el `reindex.py` interactivo es toda la historia.
- `w -h` quita el encabezado (scriptable), `w -s` es la forma corta, `w <user>` filtra.
- **`w` lee `/var/run/utmp`**, así que solo ve sesiones de *login*. Un proceso descontrolado iniciado por cron, por una unit de systemd, por un contenedor, o por `ssh host 'cmd'` sin PTY es invisible para `w`. `w` responde "quién está logueado y qué está corriendo", nunca "qué está consumiendo esta máquina".

### 3.4 `mpstat` — distribución por CPU, y por qué los agregados mienten

```
$ mpstat -P ALL 5 1
Linux 6.8.0-45-generic (lb01)   10/15/2026      _x86_64_        (16 CPU)

11:05:31     CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle
11:05:36     all   11.42    0.00    6.18    0.21    0.44    5.91    0.00    0.00    0.00   75.84
11:05:36       0    4.21    0.00    3.02    0.00    3.81   81.96    0.00    0.00    0.00    7.00
11:05:36       1   12.04    0.00    6.42    0.20    0.00    1.01    0.00    0.00    0.00   80.33
11:05:36       2   11.88    0.00    6.11    0.41    0.00    0.82    0.00    0.00    0.00   80.78
11:05:36       3   12.31    0.00    6.52    0.20    0.00    0.61    0.00    0.00    0.00   80.36
11:05:36       4   11.64    0.00    6.08    0.00    0.20    0.81    0.00    0.00    0.00   81.27
[... CPUs 5-15 similar ...]

Average:     all   11.42    0.00    6.18    0.21    0.44    5.91    0.00    0.00    0.00   75.84
```

El agregado dice **75 % idle**; la CPU 0 está al **93 % ocupada, con 82 % en softirq**. Esta es la firma canónica de NIC de cola única / RSS ausente / afinidad de IRQ mal configurada, y limita la tasa de paquetes de la máquina *independientemente de los otros 15 cores*. Los gráficos de CPU agregados no pueden mostrarlo. `mpstat -P ALL` es el primer comando después de `vmstat` ante cualquier queja de throughput.

Confirmá la distribución de interrupciones:

```
$ grep -E 'CPU0|eth0|NET_RX' /proc/interrupts /proc/softirqs | head -6
/proc/interrupts:            CPU0       CPU1       CPU2       CPU3
/proc/interrupts: 142:  884210934          0          0          0  IR-PCI-MSI-0000:3b:00.0   eth0-TxRx-0
/proc/softirqs:  NET_RX: 1204881093      40112      38994      39210

$ mpstat -I SCPU 5 1 | head -8
Linux 6.8.0-45-generic (lb01)   10/15/2026      _x86_64_        (16 CPU)

11:06:02     CPU     HI/s  TIMER/s   NET_TX/s   NET_RX/s   BLOCK/s  IRQ_POLL/s  TASKLET/s  SCHED/s  HRTIMER/s   RCU/s
11:06:07     all     0.00   1884.21      42.11   48112.44     88.21        0.00       1.22  1204.11       0.00  2104.88
11:06:07       0     0.00     118.44     40.88   48088.12      0.00        0.00       0.00     84.21       0.00     94.12
```

Realidad de cola única: los 48 k `NET_RX`/s caen todos en la CPU 0. Los arreglos son `ethtool -L` (más colas combinadas), repartir la afinidad de IRQ, o RPS/RFS — ver sección 7.4.

Otros modos útiles de `mpstat`: `mpstat -I ALL` (tasas de IRQ de hardware + soft), `mpstat -N ALL` (por nodo NUMA), `mpstat -u -P 0-3`.

### 3.5 `top`, `ps`, `pstree`, `pidstat` — atribuir CPU a un proceso

`top` en modo batch es la forma scriptable, y la que hay que poner en un script de captura de incidentes:

```
$ top -b -n 1 -o %CPU -w 512 | head -16
top - 11:08:44 up 94 days,  3:18,  3 users,  load average: 7.41, 6.88, 5.02
Tasks: 1283 total,   3 running, 1280 sleeping,   0 stopped,   0 zombie
%Cpu(s): 11.4 us,  6.2 sy,  0.0 ni, 75.8 id,  0.2 wa,  0.4 hi,  5.9 si,  0.0 st
MiB Mem :  64264.4 total,   1254.9 free,  41988.2 used,  21021.3 buff/cache
MiB Swap:   8192.0 total,   7120.0 free,   1072.0 used.  17284.1 avail Mem

    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
 884102 app       20   0 8412004 3.9g   24104 S 398.7   6.2  18:44.21 java -Xmx8g -jar api.jar
 112044 postgres  20   0 4812332 2.1g  1.9g   D  12.4   3.3 884:12.09 postgres: autovacuum worker
  88412 node_exp  20   0  812044  44104  18204 S   2.1   0.1  94:12.84 node_exporter
      9 root      20   0       0      0      0 I   1.8   0.0 412:09.11 [rcu_preempt]
```

Teclas interactivas esenciales (relevantes para el examen y realmente útiles):

| Tecla | Efecto |
|---|---|
| `1` | alterna entre líneas agregadas y por CPU (`mpstat -P ALL` desde dentro de `top`) |
| `H` | muestra **threads** en lugar de procesos — obligatorio para JVMs, nginx, bases de datos |
| `c` | línea de comando completa en lugar del nombre comm |
| `V` | vista de bosque/jerarquía |
| `f` | selector de campos (agregar `WCHAN`, `nMaj`, `P` = última CPU usada, `SWAP`) |
| `o` | filtro, p. ej. `%CPU>10` |
| `x` / `y` | resalta la columna de ordenamiento / las tareas en ejecución |
| `W` | escribe `~/.config/procps/toprc` para que el layout sobreviva |
| `-b -n N -d S` | modo batch, N iteraciones, retardo de S segundos |

> `%CPU` > 100 es correcto y esperable: `top` reporta el porcentaje de **un** core, así que 398.7 significa ~4 cores. Con `H`, el `%CPU` de cada thread es ≤ 100 y suman la cifra del proceso.

`ps` es la contraparte sin estado y scriptable. Construí la salida que necesitás en lugar de memorizar `aux`:

```
$ ps -eo pid,ppid,user,stat,psr,pcpu,pmem,rss,vsz,wchan:22,etimes,args --sort=-pcpu | head -8
    PID    PPID USER     STAT PSR %CPU %MEM     RSS     VSZ WCHAN                  ELAPSED COMMAND
 884102  884001 app      Sl     6 398.7  6.2 4089104 8412004 futex_wait_queue          1124 java -Xmx8g -jar api.jar
 112044   88102 postgres D      3 12.4  3.3 2201344 4812332 wait_on_page_bit         884012 postgres: autovacuum worker
 112088   88102 postgres D      9  9.8  3.1 2104992 4812332 wait_on_page_bit         883914 postgres: autovacuum worker
  88412       1 node_exp Ssl    1  2.1  0.1   44104  812044 ep_poll                 8121044 /usr/bin/node_exporter
 991204       1 root     Zs    -  0.0  0.0       0       0 do_exit                      88 [backup.sh] <defunct>
```

Decodificación de `STAT` — la primera letra es el estado, el resto son modificadores:

| Código | Significado | Lectura operativa |
|---|---|---|
| `R` | en ejecución o ejecutable | cuenta para el load y para `r` en `vmstat` |
| `S` | sleep interrumpible | espera idle normal (red, timers) |
| `D` | **sleep ininterrumpible** | bloqueado en el kernel; cuenta para el load; no se puede matar; leé `WCHAN` |
| `I` | thread de kernel idle | excluido del load (desde 4.2) — por eso `[kworker]` ya no infla el load |
| `Z` | zombie | terminó, el padre no lo reapeó; cuesta un slot de PID, nada más; arreglá el padre |
| `T` / `t` | detenido / detenido por el debugger | `SIGSTOP`, o un job suspendido en una shell |
| `<` | alta prioridad (nice negativo) | |
| `N` | baja prioridad | |
| `s` | líder de sesión | |
| `l` | multi-threaded | |
| `+` | grupo de procesos en primer plano | |
| `L` | páginas bloqueadas en memoria (`mlock`) | no swapeable — leer junto con la sección 4 |

Para una investigación de estado `D`, `WCHAN` más el stack del kernel es todo el diagnóstico:

```
$ cat /proc/112044/wchan; echo
wait_on_page_bit

$ sudo cat /proc/112044/stack
[<0>] folio_wait_bit_common+0x124/0x330
[<0>] filemap_read_folio+0x9d/0xd0
[<0>] filemap_get_pages+0x5f1/0x6a0
[<0>] filemap_read+0xd1/0x340
[<0>] blkdev_read_iter+0x6d/0x150
[<0>] vfs_read+0x29f/0x350

$ cat /proc/112044/syscall
0 0x2b 0x7f9c08a04000 0x20000 0x0 0x0 0x0 0x7ffd8c0f21a8 0x7f9c0a1d4b32
```

La syscall 0 en x86_64 es `read(2)`: el proceso está dentro de una lectura a dispositivo de bloques. Si toda la máquina está en `D` y necesitás el panorama completo de una sola vez:

```
$ echo w | sudo tee /proc/sysrq-trigger
$ sudo dmesg -T | tail -20
```

`pstree` da la ascendencia que `ps` aplana — indispensable cuando el quemador de CPU es un nieto de algo que sí reconocés:

```
$ pstree -aps 884102
systemd,1 --system --deserialize=44
  └─containerd-shim,884001 -namespace moby -id 9f2c...
      └─java,884102 -Xmx8g -jar api.jar
          ├─{java},884110
          ├─{java},884111
          └─{GC Thread#0},884118

$ pstree -Tp postgres | head -5
postgres(88102)─┬─postgres(88104)
                ├─postgres(88105)
                ├─postgres(112044)
                └─postgres(112088)
```

Flags que vale conocer: `-a` (argumentos), `-p` (PIDs), `-s` (mostrar los padres del objetivo), `-T` (ocultar threads), `-t` (nombres de threads), `-n` (ordenar por PID), `-u` (mostrar transiciones de uid), `-S` (mostrar transiciones de namespace — revela los límites de los contenedores).

`pidstat` es el equivalente por proceso de `vmstat`/`iostat`, y es la herramienta que responde "qué proceso, promediado sobre un intervalo" en lugar de la foto instantánea de `top`:

```
$ pidstat -u -t -p 884102 5 2
Linux 6.8.0-45-generic (lb01)   10/15/2026      _x86_64_        (16 CPU)

11:12:04      UID      TGID       TID    %usr %system  %guest   %wait    %CPU   CPU  Command
11:12:09     1001    884102         -   312.4    86.3    0.00    41.2   398.7     6  java
11:12:09     1001         -    884110    98.2    12.1    0.00    38.4   110.3     6  |__java
11:12:09     1001         -    884118    84.1     2.2    0.00     0.8    86.3    11  |__GC Thread#0

$ pidstat -w -p 884102 5 1
11:12:20      UID       PID   cswch/s nvcswch/s  Command
11:12:25     1001    884102    412.80   8841.60  java
```

Dos números para internalizar:

- **`%wait`** (no `%iowait`) es el tiempo que la tarea estuvo **ejecutable pero no planificada** — latencia directa de cola de ejecución por proceso. 41 % significa que la aplicación pierde casi la mitad de su tiempo de reloj por contención de CPU, algo que ningún gráfico de utilización te va a decir.
- **`nvcswch/s`** (cambios de contexto involuntarios) en 8 841/s significa que la tarea está siendo desalojada constantemente — la confirmación a nivel de scheduler de la misma contención.

La verdad de base por proceso para eso es `schedstat`, campos = `[cpu_time_ns] [runqueue_wait_ns] [timeslices]`:

```
$ cat /proc/884102/schedstat
184221904112 98412004881 1204881
```

Razón `98.4e9 / 184.2e9 ≈ 0.53` — a lo largo de su vida esta tarea esperó por una CPU ~0,53 ns por cada ns de ejecución. Esa es una prueba dura, acumulativa y sin dashboards de escasez de CPU.

### 3.6 Pressure Stall Information: la saturación como métrica de primera clase

Los kernels ≥ 4.20 exportan, por recurso, la porción de tiempo de reloj durante la cual hubo trabajo detenido:

```
$ cat /proc/pressure/cpu
some avg10=18.44 avg60=14.21 avg300=9.07 total=18472930184

$ cat /proc/pressure/io
some avg10=41.07 avg60=38.84 avg300=31.22 total=99184772093
full avg10=29.88 avg60=27.14 avg300=22.04 total=71204881003

$ cat /proc/pressure/memory
some avg10=0.00 avg60=0.00 avg300=0.04 total=1204881
full avg10=0.00 avg60=0.00 avg300=0.01 total=402114
```

- `some` — al menos una tarea estuvo detenida por este recurso.
- `full` — **todas** las tareas no idle estuvieron detenidas, es decir, la máquina no hizo ningún trabajo útil. `io full = 29.88` significa que ~30 % de los últimos 10 segundos fueron pura detención total por I/O.
- `cpu` no tiene un `full` significativo a escala de sistema (una CPU detenida implica que corrió otra tarea).

Por qué importa arquitectónicamente: PSI está normalizado `0–100`, es por intervalo y directamente comparable entre recursos. "Presión de CPU 18 %, presión de I/O 41 %" es una lista ordenada de cuellos de botella en dos líneas, algo que ni la utilización ni el load average pueden producir. También está disponible por cgroup (`/sys/fs/cgroup/<slice>/cpu.pressure`), lo que lo convierte en la entrada correcta para SLOs en hosts de contenedores.

### 3.7 Confinamiento: cuando el host está idle y la app está throttleada

```
$ cat /sys/fs/cgroup/system.slice/api.service/cpu.max
200000 100000

$ cat /sys/fs/cgroup/system.slice/api.service/cpu.stat
usage_usec 18844120049
user_usec 14021884110
system_usec 4822235939
nr_periods 884120
nr_throttled 412884
throttled_usec 2048812044
nr_bursts 0
burst_usec 0
```

`cpu.max = 200000 100000` es una cuota de 2 CPUs sobre un período de 100 ms. `nr_throttled / nr_periods = 412884/884120 = 46,7 %`: en casi la mitad de todas las ventanas de 100 ms este servicio quedó detenido en seco antes de que terminara la ventana — la latencia p99 va a estar dominada por hasta ~100 ms de pura detención por throttling. El host, mientras tanto, reporta 75 % idle. **Cualquier investigación de CPU en un host de contenedores que no lea `cpu.stat` está incompleta.**

### 3.8 Compromisos de las herramientas de CPU

| Herramienta | Granularidad | Intervalo | Costo | Mejor para | Punto ciego |
|---|---|---|---|---|---|
| `uptime` / `/proc/loadavg` | todo el sistema | EWMA 1/5/15 min | ~0 | "¿esto es nuevo?", dirección de la tendencia | no puede separar R de D |
| `w` | por sesión de login | instantáneo | ~0 | atribución a usuarios interactivos | solo sesiones de `utmp` |
| `vmstat` | todo el sistema | ≥ 1 s | ~0 | primer comando; división `r` vs `b` | sin por CPU, sin por proceso |
| `mpstat -P ALL` | por CPU / por IRQ | ≥ 1 s | ~0 | desbalance, softirq, steal | sin por proceso |
| `top` / `htop` | por proceso/thread | ≥ 1 s | bajo (alto con muchas tareas) | triage en vivo, orden interactivo | el muestreo pierde tareas de vida corta |
| `ps` | por proceso | foto | ~0 | capturas con scripts, `STAT`/`WCHAN` | sin tasas, el `%CPU` instantáneo es el promedio de toda la vida |
| `pidstat -t` | por tarea | ≥ 1 s | bajo | `%wait`, cambios de contexto, por thread | necesita un intervalo para ser significativo |
| `sar -u -q -P ALL` | sistema + por CPU | histórico | ~0 | **el pasado**, planificación de capacidad | resolución = intervalo de recolección |
| `/proc/pressure/*` | sistema + cgroup | 10/60/300 s | ~0 | ordenar la saturación entre recursos | kernel ≥ 4.20; sin por proceso |
| `perf top` / `perf record` | instrucción/función | muestreado | 1–5 % | *qué código* quema CPU | necesita símbolos; la PMU suele faltar en VMs |
| `exec`/`cpudist` (eBPF) | por evento | por evento | bajo | procesos de vida corta, histogramas de cola de ejecución | requisitos de kernel + tooling |

---

## 4. Memoria

### 4.1 `/proc/meminfo`: la única contabilidad completa

```
$ grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapCached|Active|Inactive|Dirty|Writeback|AnonPages|Mapped|Shmem|KReclaimable|Slab|SReclaimable|SUnreclaim|PageTables|CommitLimit|Committed_AS|SwapTotal|SwapFree|AnonHugePages|HugePages_Total)' /proc/meminfo
MemTotal:       65806848 kB
MemFree:         1284992 kB
MemAvailable:   17699040 kB
Buffers:          912384 kB
Cached:         19884416 kB
SwapCached:        44112 kB
Active:         38412004 kB
Inactive:       18204112 kB
Dirty:           1204884 kB
Writeback:        204112 kB
AnonPages:      41021884 kB
Mapped:          2104884 kB
Shmem:           2204112 kB
KReclaimable:    1884012 kB
Slab:            2412884 kB
SReclaimable:    1884012 kB
SUnreclaim:       528872 kB
PageTables:       184112 kB
SwapTotal:       8388608 kB
SwapFree:        7291904 kB
CommitLimit:    41291904 kB
Committed_AS:   58412004 kB
AnonHugePages:   8388608 kB
HugePages_Total:       0
```

`free` es un formateador sobre este archivo, y `-w` es el flag que lo hace honesto al separar `buff/cache`:

```
$ free -w -h
               total        used        free      shared     buffers       cache   available
Mem:            62Gi        40Gi       1.2Gi       2.1Gi       891Mi        18Gi        16Gi
Swap:          8.0Gi       1.0Gi       6.9Gi
```

Las tres reglas que resuelven el 90 % de las falsas alarmas de "nos quedamos sin memoria":

1. **Que `free` esté cerca de cero es el estado estable correcto.** La RAM sin usar es RAM desperdiciada; el kernel la llena con page cache. El número que importa es **`available`** (`MemAvailable`), la estimación propia del kernel de lo que una nueva asignación podría obtener sin swapear, que tiene en cuenta el page cache recuperable, el slab `SReclaimable` y las marcas de agua que debe mantener. Nunca calcules "free + buffers + cache" a mano; `MemAvailable` ya lo hace correctamente y de forma conservadora.
2. **`Committed_AS` > `CommitLimit` (58,4 G vs 41,3 G acá) no es un error** bajo el `vm.overcommit_memory=0` por defecto. Significa que los procesos *prometieron* asignaciones que exceden el límite contable, lo cual es normal para cualquier cosa que reserve arenas virtuales grandes (JVM, runtime de Go, forks de Redis). Se vuelve fatal solo con `vm.overcommit_memory=2`, donde las asignaciones más allá de `CommitLimit` fallan directamente.
3. **El swap *usado* no es un problema; el *tráfico* de swap sí.** `si`/`so` en `vmstat`, o `pswpin/s`/`pswpout/s` en `sar -W`, son el síntoma. 1 GiB de páginas anónimas olvidadas hace mucho estacionadas en disco no cuesta nada.

### 4.2 Memoria por proceso: VSZ, RSS, PSS, USS

| Métrica | Definición | Dónde | Uso correcto |
|---|---|---|---|
| `VSZ` / `VmSize` | espacio total de direcciones virtuales mapeado | `ps`, `/proc/PID/status` | esencialmente sin sentido para capacidad; incluye reservas sin respaldo, mapeos de archivos, páginas de guarda |
| `RSS` / `VmRSS` | páginas residentes en RAM, **contadas completas para cada compartidor** | `ps`, `top` | presión por proceso, pero **suma más que la RAM física** |
| `PSS` | páginas residentes con las compartidas divididas por la cantidad de compartidores | `/proc/PID/smaps_rollup` | la única métrica cuya suma entre procesos tiene sentido |
| `USS` (`Private_*`) | páginas mapeadas solo por este proceso | `smaps_rollup` | lo que realmente recuperarías matándolo |
| `WSS` | páginas tocadas en una ventana de tiempo | `/proc/PID/clear_refs` + `Referenced` | dimensionar límites (en vez de dimensionar para el RSS de pico) |

```
$ sudo cat /proc/884102/smaps_rollup
55a1c0000000-7ffd8c0f4000 ---p 00000000 00:00 0                          [rollup]
Rss:             4089104 kB
Pss:             3884112 kB
Pss_Dirty:       3802044 kB
Shared_Clean:     204992 kB
Shared_Dirty:       1024 kB
Private_Clean:     82044 kB
Private_Dirty:   3801020 kB
Referenced:      3912884 kB
Anonymous:       3802044 kB
LazyFree:              0 kB
AnonHugePages:   2097152 kB
Swap:              44112 kB
SwapPss:           44112 kB
Locked:                0 kB
```

Matar este proceso libera ~3,88 GiB (`Pss`), no 4,09 GiB (`Rss`). En un host con 300 workers de nginx, sumar RSS ingenuamente sobreestima el uso en decenas de gigabytes porque cada worker cuenta el mismo binario compartido, las mismas bibliotecas compartidas y las mismas páginas de caché compartidas.

### 4.3 Reclaim, paginación y la firma del thrashing

```
$ sar -B 1 3
Linux 6.8.0-45-generic (db03)   10/15/2026      _x86_64_        (16 CPU)

11:20:01  pgpgin/s pgpgout/s   fault/s  majflt/s  pgfree/s pgscank/s pgscand/s pgsteal/s    %vmeff
11:20:02 184112.00    412.00  88412.00   4812.00 198412.00 412884.00  88412.00 198412.00     39.58
11:20:03 191204.00    388.00  91204.00   5102.00 201884.00 441204.00  91884.00 204112.00     38.29
11:20:04 188412.00    404.00  89884.00   4984.00 199104.00 428112.00  90112.00 201884.00     38.85
Average: 187909.33    401.33  89833.33   4966.00 199800.00 427400.00  90136.00 201469.33     38.90
```

Campo por campo, y qué prueba cada uno:

| Campo | Significado | Lectura de umbral |
|---|---|---|
| `pgpgin/s`, `pgpgout/s` | KiB/s paginados dentro/fuera desde dispositivos de bloque | incluye I/O de archivos normal; no es específico de swap |
| `fault/s` | todos los page faults | los faults menores son baratos y normales |
| **`majflt/s`** | faults que requieren una lectura de disco | **el tipo caro**; miles/s sostenidos = el working set no entra |
| `pgscank/s` | páginas escaneadas por `kswapd` (reclaim en segundo plano) | el reclaim en segundo plano es sano |
| **`pgscand/s`** | páginas escaneadas **directamente** por la tarea que asigna | **reclaim directo = la aplicación está haciendo el trabajo de memoria del kernel de forma sincrónica, dentro de su propio presupuesto de latencia** |
| `pgsteal/s` | páginas efectivamente recuperadas | |
| **`%vmeff`** | `pgsteal / (pgscank + pgscand)` | ~100 % = reclaim fácil; **< 30–40 % = el kernel escanea tres páginas para liberar una** — thrashing |

`%vmeff` en 39 % con `pgscand` en 90 k/s es inequívoco: este host está gastando su CPU buscando memoria para liberar. Agregá el tráfico de swap para completar el cuadro:

```
$ sar -W 1 2
11:21:14  pswpin/s pswpout/s
11:21:15   1204.00    884.00
11:21:16   1312.00    912.00
Average:   1258.00    898.00

$ sar -r -h 1 1
11:21:30    kbmemfree   kbavail  kbmemused  %memused kbbuffers  kbcached  kbcommit   %commit  kbactive   kbinact   kbdirty
11:21:31       1.2G      1.9G      59.8G     93.2%    284.0M      1.1G     55.8G    135.1%     57.1G      1.4G    104.0M
```

El page cache colapsó de 18 GiB a 1,1 GiB, `kbavail` cayó a 1,9 GiB, el swap fluye en ambas direcciones a ~1 200 páginas/s: un evento de agotamiento de memoria en curso, minutos antes de que actúe el OOM killer.

### 4.4 El OOM killer, leído correctamente

```
$ sudo dmesg -T | grep -A 3 'Out of memory'
[Wed Oct 14 03:41:12 2026] api.jar invoked oom-killer: gfp_mask=0x140cca(GFP_HIGHUSER_MOVABLE|__GFP_COMP), order=0, oom_score_adj=0
[Wed Oct 14 03:41:12 2026] Tasks state (memory values in pages):
[Wed Oct 14 03:41:12 2026] [  pid  ]   uid  tgid total_vm      rss pgtables_bytes swapents oom_score_adj name
[Wed Oct 14 03:41:12 2026] [ 884102]  1001 884102  2103001  1022276      8421376    11028             0 java

$ sudo dmesg -T | grep 'Killed process'
[Wed Oct 14 03:41:12 2026] Out of memory: Killed process 112044 (postgres) total-vm:4812332kB, anon-rss:2201344kB, file-rss:0kB, shmem-rss:1948160kB, UID:108 pgtables:4812kB oom_score_adj:0
```

La distinción crítica, y un error de diagnóstico frecuente en producción: **el proceso que invocó al OOM killer casi nunca es el proceso que muere.** `java` fue el que asignaba y chocó contra la pared; `postgres` fue seleccionado como víctima porque tenía el `oom_score` más alto. Leer solo la línea "Killed process" produce la causa raíz equivocada y la remediación equivocada.

```
$ cat /proc/884102/oom_score
742
$ cat /proc/884102/oom_score_adj
0
```

`oom_score_adj` va de `-1000` (nunca matar) a `+1000` (matar primero) y sesga en unidades de 1/1000 de la memoria total. Protegé el control plane, sacrificá el job batch:

```
$ echo -800 | sudo tee /proc/$(pidof sshd | cut -d' ' -f1)/oom_score_adj
-800
```

y persistilo en la unit, no en un script (la sección 9.4 usa `OOMScoreAdjust=`).

### 4.5 cgroup v2: el límite de memoria que la aplicación realmente tiene

```
$ cat /sys/fs/cgroup/system.slice/api.service/memory.max
8589934592
$ cat /sys/fs/cgroup/system.slice/api.service/memory.high
7516192768
$ cat /sys/fs/cgroup/system.slice/api.service/memory.current
8314208256
$ cat /sys/fs/cgroup/system.slice/api.service/memory.events
low 0
high 48112
max 1204
oom 2
oom_kill 2
$ cat /sys/fs/cgroup/system.slice/api.service/memory.stat | head -12
anon 7204118528
file 904112128
kernel 204881920
kernel_stack 12582912
pagetables 88412928
slab 102891520
sock 4194304
shmem 201326592
file_mapped 104857600
file_dirty 8388608
file_writeback 2097152
anon_thp 2147483648
```

`high 48112` significa que el cgroup cruzó `memory.high` 48 112 veces, cada ocurrencia aplicando **throttling por reclaim** a la carga de trabajo — un evento de latencia sin ninguna firma a nivel de host. `oom_kill 2` significa que hubo dos OOM kills locales sin ninguna presión de memoria global. En un host de contenedores, `memory.events` y `memory.pressure` son las métricas de memoria; `free` es color de fondo.

### 4.6 Memoria de kernel y slab

```
$ sudo slabtop -o -s c | head -10
 Active / Total Objects (% used)    : 8841204 / 9104882 (97.1%)
 Active / Total Slabs (% used)      : 204112 / 204112 (100.0%)
 Active / Total Caches (% used)     : 142 / 198 (71.7%)
 Active / Total Size (% used)       : 1884.21M / 1912.44M (98.5%)
 Minimum / Average / Maximum Object : 0.01K / 0.21K / 16.00K

  OBJS ACTIVE  USE OBJ SIZE  SLABS OBJ/SLAB CACHE SIZE NAME
4128412 4021884  97%    0.19K  98296       42    786368K dentry
1204884 1188412  98%    0.57K  43031       28    688496K radix_tree_node
 884112  881204  99%    0.10K  22669       39     90676K buffer_head
 412884  402112  97%    1.06K  13763       30    440416K nf_conntrack
```

`dentry` con 786 MiB más `nf_conntrack` con 440 MiB es memoria de kernel que `free` reporta como `used` y que ningún proceso posee. 412 k entradas de conntrack también se vinculan directamente con la sección 7.2.

### 4.7 Compromisos de las herramientas de memoria

| Herramienta | Alcance | Consciente del sharing | Histórico | Mejor para |
|---|---|---|---|---|
| `free -w` | sistema | n/a | no | chequeo de cordura `available` vs `free` |
| `vmstat` (`si`/`so`) | sistema | n/a | no | detectar *tráfico* de swap |
| `sar -r -R -B -W -S` | sistema | n/a | **sí** | post-mortem de un evento de memoria |
| `top` / `ps` (`RSS`) | proceso | **no** (cuenta doble) | no | ranking rápido de culpables |
| `smaps_rollup` (`PSS`/`USS`) | proceso | sí | no | atribución real, dimensionamiento |
| `slabtop` | cachés de kernel | n/a | no | crecimiento del lado del kernel (dentry, conntrack, inode) |
| `memory.events` / `memory.pressure` | cgroup | sí | no (contadores) | el límite que la carga realmente alcanzó |
| `memleak`, `oomkill` (eBPF) | por asignación | sí | no | atribución de leaks a los sitios de llamada |

---

## 5. I/O de disco

### 5.1 `iostat -x`: todas las columnas, y las dos que son trampas

```
$ iostat -xz 5 2
Linux 6.8.0-45-generic (db03)   10/15/2026      _x86_64_        (16 CPU)

avg-cpu:  %user   %nice %system %iowait  %steal   %idle
           7.12    0.00    3.48   41.07    0.00   48.33

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util
nvme0n1       14882.40 186030.00     0.00   0.00    1.84    12.50  412.80  52838.40    12.20   2.87    0.91   128.00    0.00     0.00     0.00   0.00    0.00     0.00   88.20    0.42   27.78   99.80
sdb             184.20  23577.60     2.40   1.29   48.72   128.00   42.60   5452.80     8.20  16.14   91.44   128.00    0.00     0.00     0.00   0.00    0.00     0.00   12.40   84.10   13.86   98.40
```

| Columna | Definición | Interpretación |
|---|---|---|
| `r/s`, `w/s`, `d/s`, `f/s` | lecturas, escrituras, discards y flushes completados por segundo | IOPS; `f/s` es tráfico de barreras fsync/FUA — las bases de datos viven ahí |
| `rkB/s`, `wkB/s` | throughput | comparar contra el techo secuencial del dispositivo |
| `rrqm/s`, `wrqm/s`, `%rrqm`, `%wrqm` | requests fusionados por el scheduler | % de merge alto ⇒ acceso secuencial; ~0 % ⇒ aleatorio |
| **`r_await`, `w_await`** | tiempo medio por request **incluyendo el tiempo en cola** | la latencia que ve la capa del filesystem |
| `rareq-sz`, `wareq-sz` | tamaño medio de request en KiB | 4–16 KiB aleatorio vs 128 KiB+ secuencial |
| **`aqu-sz`** | longitud media de cola = `throughput × await` (ley de Little) | **la métrica de saturación** |
| `%util` | porción de tiempo con ≥ 1 request en vuelo | **no es una métrica de saturación en ningún dispositivo encolado** |

Las dos trampas, dichas con precisión:

- **`%util` es `1 - fracción_de_tiempo_idle`, no "porcentaje de capacidad".** Cuenta el tiempo durante el cual *al menos un* request estuvo pendiente. Un dispositivo NVMe con 64 colas de hardware × 1024 entradas puede estar en `%util 100` mientras sirve el 5 % de los IOPS de los que es capaz. En la captura de arriba, `nvme0n1` con `%util 99.8`, `aqu-sz 27.8` y `r_await 1.84 ms` está **ocupado y sano**. `sdb` con `%util 98.4`, `aqu-sz 13.9` y `w_await 91.4 ms` está **muriendo**. El mismo `%util`, conclusiones opuestas. El discriminador es `await`.
- **`svctm` ya no existe** (eliminado en sysstat 12.x) porque se calculaba como `%util/throughput` y se volvió sin sentido para dispositivos concurrentes. Si un runbook menciona `svctm`, el runbook es anterior a tu kernel.

Verificá la concurrencia con la ley de Little vos mismo: `aqu-sz ≈ (r/s + w/s) × await` → `(14882.4 + 412.8) × 0.00180 s ≈ 27.5`, que coincide con el `27.78` reportado. Si la aritmética no cierra, estás leyendo dos intervalos distintos.

Variantes útiles: `iostat -xz 5` (`-z` oculta dispositivos idle), `iostat -xm` (MiB), `iostat -p ALL` (por partición), `iostat -xdt 5` (con timestamp, sin el bloque de CPU), `iostat -y 5` (omite el primer reporte desde el boot — el flag correcto para scripts).

### 5.2 `iotop`: atribuir I/O a procesos

```
$ sudo iotop -oPa -d 5 -n 2 -b
Total DISK READ:       182.44 M/s | Total DISK WRITE:        51.60 M/s
Current DISK READ:     179.12 M/s | Current DISK WRITE:      48.84 M/s
    PID  PRIO  USER     DISK READ  DISK WRITE  SWAPIN      IO    COMMAND
 112044  be/4 postgres    721.04 M     12.44 M  0.00 %  91.24 % postgres: autovacuum worker
 112088  be/4 postgres    688.12 M      8.84 M  0.00 %  88.41 % postgres: autovacuum worker
  88102  be/4 postgres     12.44 M    188.12 M  0.00 %  14.02 % postgres: walwriter
 884102  be/4 app           1.02 M      4.12 M  0.00 %   2.11 % java -Xmx8g -jar api.jar
```

Flags: `-o` solo procesos que hacen I/O, `-P` procesos y no threads, `-a` totales acumulados desde el inicio, `-b` batch, `-d` retardo, `-n` iteraciones, `-k` kilobytes.

`iotop` depende del **delay accounting**, que está compilado pero deshabilitado por defecto desde el kernel 5.14. La falla no es sutil:

```
$ sudo iotop -oPa
CONFIG_TASK_DELAY_ACCT not enabled in kernel, cannot determine SWAPIN and IO%

$ sysctl kernel.task_delayacct
kernel.task_delayacct = 0
$ sudo sysctl -w kernel.task_delayacct=1
kernel.task_delayacct = 1
```

Persistilo (sección 9.2) o todo incidente de disco empieza con una herramienta que no puede responder. Notá también que `iotop` atribuye I/O de la **capa de bloques**: las escrituras aparecen contra el thread de flusher o de journal cuando el proceso que ensució ya volvió hace rato de `write(2)`. Para atribución de escrituras, `pidstat -d` más la contabilidad de páginas sucias de la sección 5.4 es más veraz.

```
$ pidstat -d 5 1
11:30:04      UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command
11:30:09      108    112044 147812.80   2548.40      0.00    8412  postgres
11:30:09      108     88102   2504.80  38412.00      0.00     884  postgres
11:30:09     1001    884102    208.40    844.80     12.40      42  java
```

`kB_ccwr/s` son escrituras canceladas por truncado; `iodelay` son ticks de reloj que la tarea pasó bloqueada en I/O — un `%iowait` por proceso que sí significa algo.

### 5.3 Vistas históricas y por dispositivo

```
$ sar -d -p 600 -f /var/log/sa/sa14 | grep -E 'DEV|nvme0n1' | head -6
00:00:01       DEV       tps     rkB/s     wkB/s     dkB/s   areq-sz    aqu-sz     await     %util
00:10:01  nvme0n1    412.44   1884.21  18412.04      0.00     49.21      0.42      1.02      8.41
03:20:01  nvme0n1  15295.20 186030.00  52838.40      0.00     15.62     27.78      1.84     99.80
03:30:01  nvme0n1  15104.80 184112.40  51204.80      0.00     15.58     28.12      1.86     99.80
04:00:01  nvme0n1    488.12   2104.44  19884.12      0.00     45.02      0.48      1.04      9.12

$ sar -b -f /var/log/sa/sa14 | head -5
00:00:01          tps      rtps      wtps      dtps   bread/s   bwrtn/s   bdscd/s
00:10:01       412.44    102.44    310.00      0.00   3768.42  36824.08      0.00
03:20:01     15295.20  14882.40    412.80      0.00 372060.00 105676.80      0.00
```

`-p` imprime nombres de dispositivo persistentes/legibles en lugar de `dev259-0`. `-f` lee un día archivado. Esta es la capacidad que te permite responder "qué pasó a las 03:25 de anoche" — la razón entera de que exista la sección 9.

### 5.4 Writeback, el acantilado de páginas sucias y el agotamiento a nivel de filesystem

Un incidente muy común de "el disco se congeló por 20 segundos" no es el disco en absoluto:

```
$ grep -E 'Dirty|Writeback' /proc/meminfo
Dirty:           1204884 kB
Writeback:        204112 kB

$ sysctl vm.dirty_background_ratio vm.dirty_ratio vm.dirty_expire_centisecs vm.dirty_writeback_centisecs
vm.dirty_background_ratio = 10
vm.dirty_ratio = 20
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 500
```

En `dirty_background_ratio` el kernel empieza a escribir de forma asincrónica. En `dirty_ratio` **todo proceso que escribe queda bloqueado sincrónicamente** hasta que el backlog se drena. En un host de 64 GiB, `dirty_ratio=20` permite ~12,8 GiB de páginas sucias; volcar eso a un dispositivo que hace 150 MiB/s lleva ~85 segundos de detención de la aplicación. En hosts con mucha memoria, usá las variantes `*_bytes` en lugar de los ratios:

```
$ sudo sysctl -w vm.dirty_background_bytes=268435456 vm.dirty_bytes=1073741824
vm.dirty_background_bytes = 268435456
vm.dirty_bytes = 1073741824
```

Dos fallas de agotamiento de espacio que `df -h` no puede mostrar:

```
$ df -h /var
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p3  196G   88G  101G  47% /var

$ df -i /var
Filesystem        Inodes   IUsed    IFree IUse% Mounted on
/dev/nvme0n1p3  13107200 13104881     2319  100% /var
```

47 % de los bytes, 100 % de los inodos — las escrituras fallan con `ENOSPC` y el gráfico de espacio se ve bien. Millones de archivos chicos (cachés de sesión, logs por request, maildirs) hacen esto.

```
$ df -h /var/log
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p4   48G   47G   84M 100% /var/log

$ du -sh /var/log
2.1G    /var/log

$ sudo lsof +L1 | head -5
COMMAND     PID    USER   FD   TYPE DEVICE  SIZE/OFF NLINK     NODE NAME
rsyslogd  88412  syslog    7w   REG  259,4 44104885248     0  1204881 /var/log/app/huge.log (deleted)
java     884102     app  142w   REG  259,4   982441984     0  1204912 /var/log/app/gc.log.1 (deleted)
```

`du` dice 2,1 GiB, `df` dice 47 GiB: 45 GiB están retenidos por **archivos borrados que todavía tienen descriptores abiertos** (`NLINK 0`). El espacio vuelve solo cuando quien lo retiene cierra el fd o se reinicia — un logrotate sin `copytruncate` o sin señalizar al daemon es la causa clásica. `lsof +L1` (link count < 1) es el comando que lo encuentra; `fuser -vm /var/log` lista quién está sobre el filesystem en general.

### 5.5 Medir el dispositivo, no las suposiciones: `fio`

`iostat` te dice qué está haciendo la carga de trabajo. Para conocer el techo al que te estás acercando hay que medir el dispositivo directamente, con un archivo de job bajo control de versiones en lugar de una línea de comandos ad hoc. Formato INI:

```ini
; /etc/fio/baseline-nvme.fio
; Device characterisation baseline. Run on an idle host, against a RAW DEVICE or
; a preallocated file; never against production data (writes are destructive).
[global]
ioengine=libaio
direct=1
filename=/dev/nvme0n1
runtime=60
time_based=1
ramp_time=10
group_reporting=1
randrepeat=0
norandommap=1
percentile_list=50.0:90.0:99.0:99.9:99.99
log_avg_msec=1000
write_lat_log=/var/tmp/fio-baseline
write_bw_log=/var/tmp/fio-baseline
write_iops_log=/var/tmp/fio-baseline

[lat-floor-randread-qd1]
description=Latency floor: one outstanding 4k read. No queueing, pure device+path latency.
rw=randread
bs=4k
iodepth=1
numjobs=1
stonewall

[iops-ceiling-randread-qd128]
description=IOPS ceiling: 4k random reads, deep queue, 4 workers.
rw=randread
bs=4k
iodepth=128
numjobs=4
stonewall

[bw-ceiling-seqread]
description=Sequential read bandwidth ceiling.
rw=read
bs=1m
iodepth=32
numjobs=1
stonewall

[sync-write-cost-qd1]
description=Journal/WAL cost: 4k synchronous writes with FUA, the database write path.
rw=write
bs=4k
iodepth=1
numjobs=1
sync=1
fdatasync=1
stonewall

[mixed-70r30w]
description=Representative OLTP mix.
rw=randrw
rwmixread=70
bs=8k
iodepth=32
numjobs=4
stonewall
```

```
$ sudo fio /etc/fio/baseline-nvme.fio --section=lat-floor-randread-qd1
lat-floor-randread-qd1: (groupid=0, jobs=1): err= 0: pid=991204: Thu Oct 15 11:38:04 2026
  read: IOPS=12.8k, BW=49.9MiB/s (52.3MB/s)(2995MiB/60001msec)
    clat (usec): min=58, max=1884, avg=76.82, stdev=12.44
     lat percentiles (usec):
     |  50.0000th=[   76], 90.0000th=[   88], 99.0000th=[  104],
     | 99.9000th=[  142], 99.9900th=[  412]
  cpu          : usr=2.14%, sys=8.88%, ctx=768412, majf=0, minf=12
  IO depths    : 1=100.0%, 2=0.0%, 4=0.0%, 8=0.0%
```

De ese único número derivás el modelo de capacidad: un piso de 77 µs a QD1 significa que una carga single-threaded y sincrónica no puede exceder ~13 000 IOPS **por más rápido que sea el dispositivo**, porque está limitada por latencia, no por ancho de banda. El arreglo es concurrencia en la aplicación, no un disco más rápido — una conclusión que ningún gráfico de utilización va a producir jamás.

### 5.6 Debajo de `iostat`: distribuciones de latencia

Los promedios esconden la cola que causa incidentes. Los histogramas no:

```
$ sudo biolatency-bpfcc -D 10 1
Tracing block device I/O... Hit Ctrl-C to end.

disk = nvme0n1
     usec               : count     distribution
        32 -> 63        : 88412    |****************************************|
        64 -> 127       : 41204    |******************                      |
       128 -> 255       : 8841     |****                                    |
       256 -> 511       : 1204     |                                        |
       512 -> 1023      : 412      |                                        |

disk = sdb
     usec               : count     distribution
      2048 -> 4095      : 184      |****                                    |
      4096 -> 8191      : 412      |**********                              |
      8192 -> 16383     : 884      |*********************                   |
     16384 -> 32767     : 1684     |****************************************|
     32768 -> 65535     : 1204     |****************************            |
     65536 -> 131071    : 884      |*********************                   |
    131072 -> 262143    : 412      |**********                              |
```

`sdb` es bimodal alrededor de 16–65 ms con una cola más allá de 131 ms — un perfil consistente con un disco que falla, una reconstrucción de RAID degradada, o una LUN con thin provisioning bajo contención remota. El `await` medio de 91 ms no describía nada de esa forma.

También son útiles: `biosnoop-bpfcc` (traza por I/O con PID y latencia), `blktrace -d /dev/sdb -o - | blkparse -i -` (traza completa de eventos de la capa de bloques), y los tunables por cola que deberías revisar antes de culpar al hardware:

```
$ cat /sys/block/nvme0n1/queue/scheduler
[none] mq-deadline kyber bfq
$ cat /sys/block/sdb/queue/scheduler
[mq-deadline] kyber bfq none
$ grep . /sys/block/sdb/queue/{nr_requests,read_ahead_kb,rotational,nomerges,wbt_lat_usec,max_sectors_kb}
/sys/block/sdb/queue/nr_requests:64
/sys/block/sdb/queue/read_ahead_kb:128
/sys/block/sdb/queue/rotational:1
/sys/block/sdb/queue/nomerges:0
/sys/block/sdb/queue/wbt_lat_usec:75000
/sys/block/sdb/queue/max_sectors_kb:512
```

### 5.7 Compromisos de las herramientas de disco

| Herramienta | Capa | Atribución | Distribución | Overhead | Mejor para |
|---|---|---|---|---|---|
| `iostat -xz` | dispositivo de bloques | ninguna | solo media | ~0 | primera mirada; `await` + `aqu-sz` |
| `sar -d -p` / `sar -b` | dispositivo de bloques | ninguna | solo media | ~0 | histórico, tendencias de capacidad |
| `iotop` | dispositivo de bloques | por tarea | ninguna | bajo | "quién está leyendo el disco ahora mismo" |
| `pidstat -d` | tarea | por tarea | ninguna | bajo | I/O por proceso con scripts + `iodelay` |
| `biolatency` | dispositivo de bloques | opcional | **histograma** | bajo | latencia de cola, bimodalidad |
| `biosnoop` | dispositivo de bloques | por I/O + PID | por evento | medio | outliers raros, correlación |
| `blktrace`/`blkparse` | capa de bloques completa | por I/O | por evento | **alto** | forense de merge/cola/scheduler |
| `fio` | bloques o FS | sintético | percentiles | destructivo | **techos y pisos** |
| `df -h` / `df -i` / `du` / `lsof +L1` | filesystem | por archivo/fd | n/a | ~0 | agotamiento de espacio e inodos |

---

## 6. I/O de red

### 6.1 Contadores de interfaz y errores

```
$ ip -s -h link show eth0
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 9000 qdisc fq_codel state UP mode DEFAULT group default qlen 1000
    link/ether 3c:ec:ef:11:22:33 brd ff:ff:ff:ff:ff:ff
    RX:    bytes  packets errors dropped  missed   mcast
       188.4G    412.8M      0   84.1k    12.4k    1.2k
    TX:    bytes  packets errors dropped carrier collsns
        91.2G    204.1M      0       0       0       0
```

| Contador | Significado | Causa típica |
|---|---|---|
| RX `errors` | frames malformados (CRC, frame, longitud) | cable, SFP, duplex mismatch, ópticas malas |
| RX `dropped` | recibidos pero descartados por el **kernel** | sin espacio en el buffer de socket, sin lugar en el qdisc, VLAN/protocolo no manejado |
| RX `missed` / `overrun` | la **NIC** no tenía descriptor | ring buffer demasiado chico, presupuesto de softirq agotado, CPU 0 saturada |
| TX `dropped` | descartados al transmitir | cola del qdisc llena, `txqueuelen` demasiado chico |
| TX `carrier` | transiciones de carrier a nivel de enlace | enlace inestable, renegociación de autoneg |

La distinción importa: RX `missed` es un problema de **hardware/ring** (la sección 7.4 lo arregla con `ethtool -G` y repartiendo colas), mientras que RX `dropped` con `missed` en cero es un problema de **buffer de socket** (la aplicación no lee lo suficientemente rápido, o `net.core.rmem_max` es demasiado chico).

Los contadores a nivel de driver son más específicos que los genéricos:

```
$ ethtool -S eth0 | grep -E 'drop|miss|err|no_buf|fifo|discard' | grep -v ': 0$'
     rx_missed_errors: 12412
     rx_no_buffer_count: 8841
     rx_fifo_errors: 12412
     rx_queue_0_drops: 84112

$ ethtool -g eth0
Ring parameters for eth0:
Pre-set maximums:
RX:             4096
RX Mini:        n/a
RX Jumbo:       n/a
TX:             4096
Current hardware settings:
RX:             512
TX:             512

$ ethtool -l eth0
Channel parameters for eth0:
Pre-set maximums:
RX:             0
TX:             0
Other:          1
Combined:       16
Current hardware settings:
Combined:       1
```

Ring de RX en 512 de 4096 posibles, y **una** cola combinada de 16 disponibles: la causa raíz tanto del desbalance de softirq de la sección 3.4 como de los `rx_missed_errors` de acá.

### 6.2 `ss` — la verdad a nivel de socket

```
$ ss -ltn
State      Recv-Q     Send-Q            Local Address:Port        Peer Address:Port
LISTEN     0          4096                    0.0.0.0:443              0.0.0.0:*
LISTEN     129        128                     0.0.0.0:8080             0.0.0.0:*
LISTEN     0          4096                  127.0.0.1:5432              0.0.0.0:*
```

**Para sockets `LISTEN` las dos columnas de cola cambian de significado por completo**, y esto es a la vez un favorito de examen y un diagnóstico real de producción:

| Columna | En `LISTEN` | En `ESTAB` |
|---|---|---|
| `Recv-Q` | conexiones **completadas y esperando que se les haga `accept()`** | bytes recibidos, no leídos todavía por la aplicación |
| `Send-Q` | el **tamaño de la cola de accept** (backlog efectivo) | bytes enviados, no ACKeados todavía por el par |

`:8080` con `Recv-Q 129` contra `Send-Q 128` es una **cola de accept que se desborda**: la aplicación no llama a `accept()` lo suficientemente rápido, y el kernel está descartando conexiones nuevas. Los clientes ven timeouts o resets de conexión mientras CPU, memoria y disco se ven todos bien. La prueba está en los contadores, no en el medidor:

```
$ nstat -az | grep -E 'TcpExtListenOverflows|TcpExtListenDrops|TcpExtSyncookies'
TcpExtSyncookiesSent            0                  0.0
TcpExtSyncookiesRecv            0                  0.0
TcpExtListenOverflows           184412             0.0
TcpExtListenDrops               184412             0.0

$ nstat -n && sleep 10 && nstat | grep -E 'Overflow|Drop|Retrans'
#kernel
TcpExtListenOverflows           1204               0.0
TcpExtListenDrops               1204               0.0
TcpExtTCPSynRetrans             84                 0.0
```

120 desbordes por segundo, ahora mismo. `nstat` sin `-a` imprime **deltas desde la última corrida** (el estado está en `/tmp/.nstat.u<uid>`), que es lo que querés durante un incidente; `nstat -n` resetea la línea base. Esto es estrictamente mejor que `netstat -s` para los mismos datos:

```
$ netstat -s | grep -A 2 -E 'listen|segments retransmit'
    184412 times the listen queue of a socket overflowed
    184412 SYNs to LISTEN sockets dropped
    1204881 segments retransmitted
```

El backlog es el mínimo entre lo que pidió la aplicación y el tope del sistema:

```
$ sysctl net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_abort_on_overflow
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 1024
net.ipv4.tcp_abort_on_overflow = 0
```

`somaxconn` es 4096 pero el backlog de este socket es 128 — por lo tanto la aplicación pasó `listen(fd, 128)`. Subir `somaxconn` no cambia nada acá; el arreglo está en la configuración de la aplicación (nginx `backlog=`, gunicorn `--backlog`, Java `SO_BACKLOG`).

Internals de TCP por conexión, que es donde se responden las preguntas de throughput:

```
$ ss -tiepm 'dst 203.0.113.44'
ESTAB  0  4194304  10.20.0.90:443  203.0.113.44:51234
         users:(("nginx",pid=88412,fd=142)) timer:(on,208ms,0) uid:33 ino:1204881 sk:4f2c <->
         skmem:(r0,rb6291456,t0,tb4194304,f4096,w4198400,o0,bl0,d12)
         bbr wscale:7,7 rto:312 rtt:84.112/2.441 mss:1448 pmtu:9000 rcvmss:536 advmss:8948
         cwnd:142 ssthresh:98 bytes_sent:1884120448 bytes_retrans:18841204 bytes_acked:1865279244
         segs_out:1301204 segs_in:412884 data_segs_out:1300118
         bbr:(bw:628.4Mbps,mrtt:81.204,pacing_gain:1.25,cwnd_gain:2) send 19.6Mbps lastsnd:4
         pacing_rate 785.5Mbps delivery_rate 612.1Mbps busy:184112ms rwnd_limited:84112ms(45.7%)
         retrans:0/1284 dsack_dups:84 reordering:12 rcv_rtt:88.4 rcv_space:14480 minrtt:81.204
```

Lo que prueba este único bloque:

- `rtt:84.112` con `mss:1448` y `cwnd:142` → en vuelo ≈ `142 × 1448 = 205 KiB`; sobre un RTT de 84 ms eso es ~19,6 Mbit/s, exactamente la cifra `send 19.6Mbps`.
- **`rwnd_limited:84112ms(45.7%)`** — durante el 45,7 % del tiempo ocupado de la conexión la ventana del *receptor* fue el límite. El emisor no es el problema, la red no es el problema, y ninguna cantidad de ancho de banda extra va a ayudar. Este es el campo más valioso de la salida de `ss` y no tiene equivalente en ninguna parte de `netstat`.
- `bytes_retrans / bytes_sent = 1 %` — suficiente para mantener a CUBIC/BBR fuera de su régimen óptimo.
- `skmem:(rb6291456,tb4194304)` — los tamaños reales de los buffers de socket, es decir, si el autotuning llegó al máximo configurado.

Formas cotidianas de `ss` que vale tener en la memoria muscular:

```
$ ss -s
Total: 118427
TCP:   117981 (estab 116204, closed 1431, orphaned 0, timewait 1402)

Transport Total     IP        IPv6
RAW       1         0         1
UDP       14        10        4
TCP       116550    114204    2346
INET      116565    114214    2351
FRAG      0         0         0

$ ss -tan state time-wait | wc -l
1402

$ ss -tn state established '( dport = :5432 or sport = :5432 )' | head -3
Recv-Q Send-Q      Local Address:Port       Peer Address:Port
0      0            10.20.0.90:48122         10.20.0.31:5432
0      0            10.20.0.90:48124         10.20.0.31:5432

$ ss -uap 'sport = :53'
State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
UNCONN 212992 0            0.0.0.0:53        0.0.0.0:*     users:(("unbound",pid=1204,fd=4))

$ ss -K 'dst 198.51.100.7'
```

`Recv-Q 212992` en un socket UDP es un **buffer de recepción lleno** — se están descartando datagramas en este momento; cruzalo con `nstat -az | grep UdpRcvbufErrors`. `ss -K` destruye los sockets que coinciden (necesita `CONFIG_INET_DIAG_DESTROY` y root) — una herramienta real de remediación, no solo un visor.

### 6.3 `netstat` vs `ss` vs `nstat` vs `ip`

| Tarea | Legado | Moderno | Por qué el moderno |
|---|---|---|---|
| listar sockets | `netstat -tulpn` | `ss -tulpn` | netlink, filtrado del lado del kernel, órdenes de magnitud más rápido |
| resumen de sockets | `netstat -s` | `nstat` / `nstat -az` | deltas por defecto, legible por máquina, una línea por contador |
| tabla de routing | `netstat -rn` | `ip route show` / `ip -4 route get 8.8.8.8` | policy routing, múltiples tablas, `get` muestra la decisión real |
| estadísticas de interfaz | `netstat -i` | `ip -s link` / `ethtool -S` | detalle a nivel de driver, taxonomía de errores |
| ARP/vecinos | `arp -an` | `ip neigh show` | incluye NDP de IPv6, estados (`REACHABLE`, `STALE`, `FAILED`) |
| multicast | `netstat -g` | `ip maddr show` | interfaz consistente |
| masquerade/conntrack | `netstat -M` | `conntrack -L` | era de nftables/nf_conntrack |

```
$ ip -4 route get 203.0.113.44
203.0.113.44 via 10.20.0.1 dev eth0 src 10.20.0.90 uid 0
    cache

$ ip -s -s link show eth0 | tail -6
    TX: bytes  packets errors dropped carrier collsns
    91234567890 204112884      0       0       0       0
    TX errors: aborted  fifo   window heartbeat transns
               0        0      0      0         4
```

`ip -s -s` (dos veces) imprime el desglose extendido de errores, incluido `transns` — transiciones de enlace, es decir, inestabilidad.

### 6.4 Datos históricos de red con `sar`

```
$ sar -n DEV --iface=eth0 600 -f /var/log/sa/sa14 | head -6
00:00:01     IFACE   rxpck/s   txpck/s    rxkB/s    txkB/s   rxcmp/s   txcmp/s  rxmcst/s   %ifutil
00:10:01      eth0  48112.44  41204.80  58412.04  44112.80      0.00      0.00      0.42     18.44
03:20:01      eth0 884112.40 112044.80 128412.44  12884.04      0.00      0.00      0.44     41.02
03:30:01      eth0 891204.80 118412.40 129884.12  13204.44      0.00      0.00      0.48     41.44

$ sar -n EDEV --iface=eth0 600 -f /var/log/sa/sa14 | head -4
00:00:01     IFACE   rxerr/s   txerr/s    coll/s  rxdrop/s  txdrop/s  txcarr/s  rxfram/s  rxfifo/s  txfifo/s
03:20:01      eth0      0.00      0.00      0.00    412.44      0.00      0.00      0.00    188.40      0.00

$ sar -n TCP,ETCP,SOCK 600 -f /var/log/sa/sa14 | head -8
00:00:01    totsck    tcpsck    udpsck    rawsck   ip-frag    tcp-tw
03:20:01    118427    116550        14         1         0      1402

00:00:01  active/s passive/s    iseg/s    oseg/s
03:20:01   1204.44  18412.80 412884.40 388112.44

00:00:01  atmptf/s  estres/s retrans/s isegerr/s   orsts/s
03:20:01    184.40     12.44   1204.88      0.42   1884.12
```

La observación decisiva: a las 03:20 la tasa de paquetes salta a **884 k paquetes/s** mientras el ancho de banda apenas llega a 128 MB/s y `%ifutil` a 41 %. Tamaño medio de paquete ≈ 145 bytes. Este host está **limitado por tasa de paquetes, no por ancho de banda** — y `rxfifo/s 188` más `rxdrop/s 412` confirman que el ring de la NIC y el camino de softirq se rindieron mucho antes que el enlace. Comprar más ancho de banda no cambiaría nada; `ethtool -L`/`-G` y repartir colas sí.

Conjunto de palabras clave de `sar -n`: `DEV`, `EDEV`, `NFS`, `NFSD`, `SOCK`, `IP`, `EIP`, `ICMP`, `EICMP`, `TCP`, `ETCP`, `UDP`, `SOCK6`, `IP6`, `EIP6`, `ICMP6`, `EICMP6`, `UDP6`, `FC`, `SOFT`, `ALL`.

### 6.5 Compromisos de las herramientas de red

| Herramienta | Resolución | Por conexión | Por proceso | Histórico | Costo |
|---|---|---|---|---|---|
| `ip -s link` | interfaz, acumulativo | no | no | no | ~0 |
| `ethtool -S` | cola del driver | no | no | no | ~0 |
| `sar -n DEV/EDEV/TCP` | intervalo | no | no | **sí** | ~0 |
| `ss -tiepm` | socket, instantáneo | **sí, en profundidad** | sí | no | bajo |
| `nstat` | contadores del stack, delta | no | no | no | ~0 |
| `netstat -s` | contadores del stack, acumulativo | no | no | no | bajo |
| `iftop` | par de hosts, en vivo | agregado | no | no | captura promiscua |
| `iptraf-ng` | conexión + interfaz | sí | no | logfile | limitado por la captura |
| `nload` / `bmon` | interfaz, gráfico en vivo | no | no | no | ~0 |
| NetFlow/IPFIX (`nfdump`, Akvorado) | registros de flujo | sí | no | **sí, largo plazo** | CPU del exporter + almacenamiento |
| `tcplife`, `tcpretrans` (eBPF) | por vida de conexión | sí | **sí** | no | bajo |
| `tcpdump`/`tshark` | por paquete | sí | no | pcap | **alto** — puede descartar paquetes por sí mismo |

---

## 7. Throughput de firewalling y routing

Esta es el área menos practicada del objetivo y la que produce los incidentes más confusos, porque un camino de firewall saturado no se ve como un recurso saturado: se ve como *la red está perdiendo paquetes*.

### 7.1 El límite real son paquetes por segundo, no bits por segundo

Cada decisión de firewall y de routing es por paquete. La capacidad del enlace se cotiza en bits por segundo. La conversión es donde mueren los planes de capacidad.

Frame Ethernet = payload + 14 B de encabezado + 4 B de FCS (64 B como mínimo). En el cable cada frame cuesta además 8 B de preámbulo/SFD + 12 B de inter-frame gap, así que bytes en el cable = frame + 20. Las filas son tamaños de frame, con el payload que llevan:

| Frame (payload) | Bytes en el cable | 1 GbE | 10 GbE | 25 GbE |
|---|---|---|---|---|
| 64 B (46 B, frame mínimo) | 84 | 1.488 Mpps | 14.88 Mpps | 37.2 Mpps |
| 128 B (110 B) | 148 | 844 kpps | 8.45 Mpps | 21.1 Mpps |
| 512 B (494 B) | 532 | 234 kpps | 2.35 Mpps | 5.87 Mpps |
| 1518 B (1500 B, MTU estándar) | 1538 | 81.3 kpps | 812.7 kpps | 2.03 Mpps |
| 9018 B (9000 B, jumbo) | 9038 | 13.8 kpps | 138.3 kpps | 345.8 kpps |

Cuántos paquetes por segundo puede pasar un core por conntrack y un ruleset depende de la CPU, la NIC, el driver y el ruleset; no hay un número para memorizar, hay que medirlo en la máquina, como se muestra justo abajo. Lo que importa de la tabla es la proporción:

- Un enlace de 10 GbE con frames de tamaño completo (1500 B de payload) necesita ~813 kpps.
- El mismo enlace con frames de tamaño mínimo (DNS, VoIP, SYN flood, telemetría) necesita 14,88 Mpps, dieciocho veces la tasa de paquetes con la misma tasa de bits; un firewall por software de cola única llega a su límite de paquetes mucho antes de que el enlace se llene. Vas a ver 8 % de `%ifutil` y descartes masivos simultáneamente.

Medí la tasa real de paquetes, nunca la infieras del ancho de banda:

```
$ sar -n DEV --iface=eth0 1 3
11:48:01     IFACE   rxpck/s   txpck/s    rxkB/s    txkB/s   rxcmp/s   txcmp/s  rxmcst/s   %ifutil
11:48:02      eth0 884112.40 112044.80 128412.44  12884.04      0.00      0.00      0.44     41.02
```

### 7.2 Connection tracking: la tabla que se llena en silencio

```
$ sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max net.netfilter.nf_conntrack_buckets
net.netfilter.nf_conntrack_count = 412884
net.netfilter.nf_conntrack_max = 425984
net.netfilter.nf_conntrack_buckets = 106496

$ sudo dmesg -T | grep -i conntrack | tail -3
[Wed Oct 14 03:24:51 2026] nf_conntrack: nf_conntrack: table full, dropping packet
[Wed Oct 14 03:24:51 2026] nf_conntrack: nf_conntrack: table full, dropping packet
[Wed Oct 14 03:24:52 2026] nf_conntrack: nf_conntrack: table full, dropping packet

$ sudo conntrack -S | head -4
cpu=0   found=1204881 invalid=4112 insert=0 insert_failed=184412 drop=184412 early_drop=0 error=0 search_restart=88412 clash_resolve=1204 chaintoolong=0
cpu=1   found=1188412 invalid=3984 insert=0 insert_failed=182044 drop=182044 early_drop=0 error=0 search_restart=87112 clash_resolve=1188 chaintoolong=0

$ sudo conntrack -L -p tcp --state TIME_WAIT 2>/dev/null | wc -l
388412
```

97 % llena, 184 k `insert_failed` por CPU, y 388 k de las 412 k entradas son `TIME_WAIT`. La tabla está llena de cadáveres. Dos arreglos ortogonales:

```
$ sysctl net.netfilter.nf_conntrack_tcp_timeout_time_wait net.netfilter.nf_conntrack_tcp_timeout_established
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 120
net.netfilter.nf_conntrack_tcp_timeout_established = 432000

$ sudo sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
$ sudo sysctl -w net.netfilter.nf_conntrack_max=1048576
net.netfilter.nf_conntrack_max = 1048576
$ echo 262144 | sudo tee /sys/module/nf_conntrack/parameters/hashsize
262144
```

Notá que `nf_conntrack_tcp_timeout_established = 432000` (5 días) es el valor por defecto y casi siempre está mal para un borde ocupado: fija una entrada por cinco días después del último paquete. Aritmética de dimensionamiento: cada entrada son ~320 B de slab `SUnreclaim` (ver sección 4.6), así que 1 048 576 entradas ≈ 320 MiB de memoria de kernel no recuperable. **Subir `nf_conntrack_max` sin presupuestar esa memoria convierte un incidente de descarte de paquetes en un incidente de OOM.** Mantené `hashsize ≈ max/4` o el hash degenera en recorridos de listas enlazadas (`search_restart`, `chaintoolong`).

La respuesta estructuralmente mejor para caminos sin estado y de alta tasa es no trackear en absoluto:

```
table inet raw {
    chain prerouting {
        type filter hook prerouting priority raw; policy accept;
        ip daddr 10.20.0.90 tcp dport 443 notrack
        ip protocol udp udp dport 53 notrack
    }
}
```

### 7.3 Costo de evaluación del ruleset: cadenas vs sets

Un paquete recorre cada regla hasta que coincide. Con `iptables`, una cadena de 5 000 reglas son 5 000 comparaciones por paquete; a 1 Mpps eso es 5 × 10⁹ comparaciones por segundo. Los sets y maps de `nftables` son búsquedas hash/por intervalo — O(1) u O(log n) — y este es el factor más grande de throughput de firewall después de conntrack.

| Enfoque | Costo de búsqueda | 50 k prefijos bloqueados | Costo de actualización | Veredicto |
|---|---|---|---|---|
| cadena lineal de `iptables` | O(n) | inusable (~50 k comparaciones/paquete) | recarga completa del ruleset | nunca |
| set hash de `ipset` | O(1) | bien | add/del atómico por entrada | bueno con iptables legacy |
| set nombrado de `nftables` | O(1) / O(log n) para intervalos | bien | atómico, transaccional | **preferido** |
| verdict map de `nftables` | O(1) + jump | bien | atómico | mejor para política por tenant |
| flowtable de `nftables` | **evita el stack** después del primer paquete | n/a | n/a | mejor para throughput de forwarding ruteado |

```
$ sudo nft list ruleset | head -30
table inet filter {
    set blocklist_v4 {
        type ipv4_addr
        flags interval
        counter
        elements = { 198.51.100.0/24, 203.0.113.128/25 }
    }

    counter dropped_blocklist {
        packets 1884112 bytes 128412884
    }

    chain input {
        type filter hook input priority filter; policy drop;
        ct state established,related accept
        iif "lo" accept
        ip saddr @blocklist_v4 counter name dropped_blocklist drop
        tcp dport { 22, 443 } ct state new limit rate 2000/second burst 500 packets accept
        ip protocol icmp icmp type echo-request limit rate 10/second accept
        counter
    }
}

$ sudo nft list counter inet filter dropped_blocklist
table inet filter {
    counter dropped_blocklist {
        packets 1884112 bytes 128412884
    }
}
```

Medí dónde se va el tiempo — `perf` nombra la función, que es la única respuesta no especulativa:

```
$ sudo perf top -e cycles:k --sort symbol -d 5 | head -12
Samples: 1M of event 'cycles:k', 4000 Hz, Event count (approx.): 184112884412
Overhead  Symbol
  18.44%  [k] nft_do_chain
  12.08%  [k] __nf_conntrack_find_get
   9.12%  [k] nf_conntrack_tuple_taken
   7.84%  [k] fib_table_lookup
   6.41%  [k] napi_poll
   5.12%  [k] dev_queue_xmit
   4.88%  [k] __memcpy
   3.42%  [k] nft_lookup_eval
```

31 % de los ciclos de kernel en `nft_do_chain` + búsqueda de conntrack es la afirmación cuantitativa "el firewall es el cuello de botella".

### 7.4 Softirq, rings y el camino de recepción

```
$ sysctl net.core.netdev_budget net.core.netdev_budget_usecs net.core.netdev_max_backlog
net.core.netdev_budget = 300
net.core.netdev_budget_usecs = 8000
net.core.netdev_max_backlog = 1000

$ awk 'NR==1 || /^ *[0-9]+:/ {print}' /proc/net/softnet_stat | head -4
00f2a1b4 00001e44 0000012c 00000000 00000000 00000000 00000000 00000000 00000000 00000412 00000000
000841aa 00000000 00000004 00000000 00000000 00000000 00000000 00000000 00000000 00000012 00000000
```

Las columnas 1–3 de `/proc/net/softnet_stat` son `processed`, **`dropped`** (backlog lleno) y **`time_squeeze`** (NAPI se quedó sin presupuesto antes de drenar el ring) por CPU. Una columna 2 distinta de cero significa que `netdev_max_backlog` es demasiado chico; una columna 3 distinta de cero significa que `netdev_budget` es demasiado chico o que esa CPU está sobrecargada. Ambas aparecen como `rx_missed_errors` en la NIC y como "la red está descartando paquetes" en el ticket.

Remediación, en orden de efectividad:

```
$ sudo ethtool -L eth0 combined 16
$ sudo ethtool -G eth0 rx 4096 tx 4096
$ sudo sysctl -w net.core.netdev_budget=1200 net.core.netdev_max_backlog=16384
net.core.netdev_budget = 1200
net.core.netdev_max_backlog = 16384

$ for q in /sys/class/net/eth0/queues/rx-*; do echo ffff | sudo tee $q/rps_cpus > /dev/null; done
$ sudo sysctl -w net.core.rps_sock_flow_entries=32768
net.core.rps_sock_flow_entries = 32768
$ for q in /sys/class/net/eth0/queues/rx-*; do echo 2048 | sudo tee $q/rps_flow_cnt > /dev/null; done

$ ethtool -c eth0 | grep -E 'rx-usecs|rx-frames|Adaptive'
Adaptive RX: on  TX: on
rx-usecs: 8
rx-frames: 0
```

Multi-cola (`-L`) reparte las interrupciones entre cores en hardware y es estrictamente mejor que RPS; RPS es el fallback por software para NICs de cola única y virtio.

### 7.5 Disciplina de cola — el lado de egreso

```
$ tc -s qdisc show dev eth0
qdisc fq_codel 8001: root refcnt 9 limit 10240p flows 1024 quantum 9000 target 5ms interval 100ms memory_limit 32Mb ecn drop_batch 64
 Sent 91234567890 bytes 204112884 pkt (dropped 18412, overlimits 0 requeues 1204)
 backlog 1842960b 204p requeues 1204
  maxpacket 9000 drop_overlimit 0 new_flow_count 884112 ecn_mark 41204
  new_flows_len 2 old_flows_len 14
```

`backlog 204p` con `dropped 18412` y `ecn_mark 41204` dice que la cola de egreso está activamente congestionada — se están marcando y descartando paquetes *en este host*, antes de que lleguen siquiera a la red. Un backlog permanente es latencia de encolamiento agregada a todos los flujos. `tc -s class show dev eth0` más `tc -s filter show dev eth0` extienden esto a configuraciones con shaping y por clase.

---

## 8. Mapear el uso de ancho de banda por cliente

"Qué cliente está consumiendo el ancho de banda" requiere una herramienta que agregue por par de direcciones, algo que ninguna de las herramientas de sistema de las secciones 3–6 hace.

### 8.1 `iptraf-ng`

`iptraf-ng` (el fork mantenido de `iptraf`, y el binario presente en las distribuciones actuales) es un front end curses con cinco modos relevantes. También es scriptable en modo background, que es la forma en que corresponde que esté en un runbook:

```
$ sudo iptraf-ng -i eth0 -B -L /var/log/iptraf-ng/eth0-detail.log -t 15
$ sudo iptraf-ng -s eth0 -B -L /var/log/iptraf-ng/eth0-ports.log -t 15
$ sudo iptraf-ng -z eth0 -B -L /var/log/iptraf-ng/eth0-pktsize.log -t 15
$ sudo iptraf-ng -l eth0 -B -L /var/log/iptraf-ng/eth0-lan.log -t 15
```

| Flag | Modo | Responde |
|---|---|---|
| `-i <iface>` / `-i all` | monitor de tráfico IP | tasas por conexión TCP y por datagrama, con flags y tamaños de ventana |
| `-d <iface>` | estadísticas detalladas de interfaz | tasas totales/entrantes/salientes, por protocolo, utilización de la interfaz |
| `-s <iface>` | monitor de servicios TCP/UDP | tasas de bytes y paquetes **por puerto** |
| `-z <iface>` | distribución de tamaño de paquete | si estás limitado por ancho de banda o por paquetes |
| `-l <iface>` / `-l all` | monitor de estaciones LAN | tasas **por dirección MAC** — la vista por cliente |
| `-B` | background (demonizar) | captura desatendida |
| `-L <file>` | archivo de log | persistencia |
| `-t <min>` | correr N minutos y salir | captura acotada |

Una captura del monitor de estaciones LAN:

```
$ sudo tail -14 /var/log/iptraf-ng/eth0-lan.log

*** LAN station monitor started Thu Oct 15 11:58:04 2026

 Ethernet address        Total   Total    Incoming  Incoming   Outgoing  Outgoing
                       Packets   Bytes     Packets    Bytes      Packets   Bytes
 3c:ec:ef:11:22:33    18841204 24118412884  8841204 2118412884  10000000 22000000000
 b8:27:eb:04:12:88     8412004  9884112044  4112044 1204881204   4299960  8679230840
 00:16:3e:44:12:04      412884   188412004   204881   88412004     208003   99999999

*** LAN station monitor stopped Thu Oct 15 12:13:04 2026
```

Limitaciones importantes a declarar antes de que alguien construya un sistema de facturación sobre esto: `iptraf-ng` lee de un socket `AF_PACKET` crudo, así que (a) solo ve el tráfico que llega a **esta** interfaz — en una red conmutada eso es el tráfico de este host más broadcast/multicast, salvo que el puerto del switch esté haciendo mirroring; (b) el monitor de estaciones LAN indexa por **dirección MAC**, que más allá del segmento local es simplemente el router; (c) a tasas de paquetes altas el propio socket de captura descarta, así que sus totales son una cota inferior. Validá contra los contadores de la interfaz:

```
$ cat /proc/net/softnet_stat | awk '{s+=strtonum("0x"$2)} END {print "backlog drops:", s}'
backlog drops: 1042
```

### 8.2 Vista en vivo por par y contabilidad durable

```
$ sudo iftop -i eth0 -n -N -P -t -s 10 2>/dev/null | head -14
interface: eth0
IP address is: 10.20.0.90
MAC address is: 3c:ec:ef:11:22:33
Listening on eth0
   # Host name (port/service)         last 2s   last 10s   last 40s cumulative
--------------------------------------------------------------------------------
   1 10.20.0.90:443                =>    412Mb      388Mb      402Mb      1.96GB
     203.0.113.44:51234            <=   18.4Mb     17.2Mb     18.1Mb      88.4MB
   2 10.20.0.90:443                =>    188Mb      184Mb      186Mb       908MB
     198.51.100.12:44122           <=   8.41Mb     8.12Mb     8.22Mb      40.1MB
--------------------------------------------------------------------------------
Total send rate:                        882Mb       871Mb       884Mb
Total receive rate:                    44.1Mb      42.8Mb      43.4Mb
```

Para una contabilidad que deba ser exacta, barata y permanente, no captures paquetes — usá contadores de kernel, que se mantienen en el camino de forwarding sin costo extra:

```
table inet accounting {
    map client_bytes_v4 {
        type ipv4_addr : counter
        elements = {
            10.20.10.11 : counter packets 0 bytes 0,
            10.20.10.12 : counter packets 0 bytes 0,
            10.20.10.13 : counter packets 0 bytes 0
        }
    }

    chain forward_accounting {
        type filter hook forward priority filter - 10; policy accept;
        counter name ip saddr map @client_bytes_v4
        counter name ip daddr map @client_bytes_v4
    }
}
```

```
$ sudo nft -j list map inet accounting client_bytes_v4 | jq -r '
    .nftables[] | select(.map) | .map.elem[] |
    "\(.[0]) \(.[1].counter.bytes) \(.[1].counter.packets)"'
10.20.10.11 128412884412 188412004
10.20.10.12 41204881204 88412004
10.20.10.13 8841204884 12044881
```

| Método | Exactitud | Costo a 1 Mpps | Retención | Identifica |
|---|---|---|---|---|
| `iptraf-ng` / `iftop` (AF_PACKET) | cota inferior; descarta bajo carga | alto (copia completa a espacio de usuario) | logfile | par IP, MAC, puerto |
| contadores/maps de `nftables` | **exacto** | despreciable | hasta el flush; raspar a una TSDB | lo que uses como clave |
| filtros `tc` con `action police`/contadores | exacto | despreciable | hasta la recarga | clase, flujo |
| contabilidad con `conntrack -L -o extended` | por flujo, exacto | bajo (necesita `nf_conntrack_acct=1`) | vida del flujo | 5-tupla completa |
| exportación NetFlow/IPFIX/sFlow | muestreado (sFlow) o por flujo | bajo–medio | **meses, fuera de la máquina** | flujo, AS, interfaz |
| eBPF por cgroup/por socket | exacto, por proceso | bajo | según diseño | **proceso y contenedor** |

```
$ sysctl net.netfilter.nf_conntrack_acct
net.netfilter.nf_conntrack_acct = 0
$ sudo sysctl -w net.netfilter.nf_conntrack_acct=1
net.netfilter.nf_conntrack_acct = 1
$ sudo conntrack -L -o extended 2>/dev/null | head -2
ipv4     2 tcp      6 431998 ESTABLISHED src=10.20.10.11 dst=10.20.0.90 sport=48122 dport=443 packets=184112 bytes=224118412 src=10.20.0.90 dst=10.20.10.11 sport=443 dport=48122 packets=88412 bytes=1204881204 [ASSURED] mark=0 use=1
```

---

## 9. Infraestructura: desplegar el sustrato de medición

Todo lo de arriba es inútil durante un incidente si no estaba instalado y recolectando de antes. Esta sección es el despliegue completo e idempotente.

### 9.1 Arquitectura de `sysstat`

| Componente | Rol |
|---|---|
| `sadc` | el recolector — lee `/proc` y `/sys`, agrega un registro binario |
| `/var/log/sa/sa<DD>` | archivo de datos binario diario (uno por día del mes, rotado por sobrescritura) |
| `/var/log/sa/sar<DD>` | resumen **de texto** diario producido por `sa2` |
| `sa1` | wrapper que invoca `sadc` una vez (disparado por cron o `sysstat-collect.timer`) |
| `sa2` | reporte diario + mantenimiento (`sysstat-summary.timer`) |
| `sar` | lee un archivo de datos (por defecto: el de hoy) y lo formatea |
| `sadf` | exporta un archivo de datos a CSV / XML / JSON / SVG para otras herramientas |

El intervalo de recolección es el límite duro de todo lo que vas a poder ver alguna vez. El valor por defecto de 10 minutos es una decisión a tomar deliberadamente:

| Intervalo | Bytes/día (aprox., con `-S ALL` completo) | Evento visible más corto | Apropiado para |
|---|---|---|---|
| 10 min (por defecto) | ~1,5 MB | ~20 min | solo tendencias de capacidad |
| 2 min | ~7 MB | ~4 min | valor por defecto general de producción |
| 1 min | ~14 MB | ~2 min | servicios sensibles a la latencia |
| 10 s | ~85 MB | ~20 s | depurar un incidente conocido y reproducible (temporal) |

Un promedio de 10 minutos no puede representar una detención de 90 segundos; va a mostrar un bache del 15 %. **Un minuto es el valor por defecto defendible en producción** — el costo es ~14 MB/día contra la alternativa de no tener ningún dato.

### 9.2 Playbook de Ansible — completo

```yaml
---
# site-observability.yml
# Deploys the resource-measurement substrate on every Linux host:
#   - sysstat (sadc/sar) as a 1-minute flight recorder with 28 days of history
#   - the full interactive toolchain (iostat, iotop, ss, iptraf-ng, fio, ethtool)
#   - the sysctl settings those tools require in order to report anything
#   - node_exporter with the PSI, cgroup and per-process collectors enabled
# Idempotent: safe to re-run; nothing is restarted unless its input changed.
- name: Resource measurement substrate
  hosts: linux_fleet
  become: true
  gather_facts: true

  vars:
    sysstat_history_days: 28
    sysstat_compress_after_days: 7
    # Quoted: a bare *:00/1 would be parsed by YAML as an alias node.
    sysstat_collect_calendar: "*:00/1"
    sysstat_summary_calendar: "00:07:00"
    node_exporter_version: "1.8.2"
    node_exporter_user: node_exp
    node_exporter_listen: "127.0.0.1:9100"
    node_exporter_textfile_dir: /var/lib/node_exporter/textfile_collector
    measurement_packages:
      - sysstat
      - procps
      - iotop
      - iproute2
      - lsof
      - iptraf-ng
      - fio
      - ethtool
      - numactl
      - psmisc
      - conntrack
      - nftables
    measurement_sysctls:
      # iotop and pidstat -d report nothing at all without delay accounting.
      - key: kernel.task_delayacct
        value: "1"
      # Let unprivileged tooling read perf events for its own processes.
      - key: kernel.perf_event_paranoid
        value: "1"
      # Keep writeback backlog bounded in time rather than as a share of RAM:
      # on a large-memory host, dirty_ratio=20 permits multi-second write stalls.
      - key: vm.dirty_background_bytes
        value: "268435456"
      - key: vm.dirty_bytes
        value: "1073741824"
      # Receive-path headroom; without it, bursts show up as rx_missed_errors.
      - key: net.core.netdev_max_backlog
        value: "16384"
      - key: net.core.netdev_budget
        value: "1200"
      # Byte accounting per conntrack entry, for client bandwidth attribution.
      - key: net.netfilter.nf_conntrack_acct
        value: "1"

  handlers:
    - name: Reload systemd
      ansible.builtin.systemd_service:
        daemon_reload: true

    - name: Restart node_exporter
      ansible.builtin.systemd_service:
        name: node_exporter
        state: restarted

  tasks:
    - name: Install the measurement toolchain
      ansible.builtin.package:
        name: "{{ measurement_packages }}"
        state: present

    - name: Install eBPF tooling where the kernel supports it
      ansible.builtin.package:
        name: "{{ (ansible_os_family == 'Debian') | ternary('bpfcc-tools', 'bcc-tools') }}"
        state: present
      when: ansible_kernel is version('5.4', '>=')
      failed_when: false

    - name: Apply measurement sysctls
      ansible.posix.sysctl:
        name: "{{ item.key }}"
        value: "{{ item.value }}"
        sysctl_file: /etc/sysctl.d/90-measurement.conf
        sysctl_set: true
        reload: true
        state: present
      loop: "{{ measurement_sysctls }}"
      loop_control:
        label: "{{ item.key }}={{ item.value }}"

    - name: Configure sysstat collection
      ansible.builtin.copy:
        dest: "{{ (ansible_os_family == 'Debian') | ternary('/etc/sysstat/sysstat', '/etc/sysconfig/sysstat') }}"
        owner: root
        group: root
        mode: "0644"
        content: |
          # Managed by Ansible. Do not edit by hand.
          # Days of history to keep. Values > 28 switch sadc to YYYYMMDD filenames.
          HISTORY={{ sysstat_history_days }}
          # Compress datafiles older than this many days.
          COMPRESSAFTER={{ sysstat_compress_after_days }}
          # Collect every statistic group sadc knows about. Without these flags,
          # sar -d (DISK) and sar -x (per-device detail) have no data to read,
          # and that only becomes apparent during the incident you needed them for.
          SADC_OPTIONS="-S DISK,XDISK,SNMP,IPV6,POWER,XALL"
          # Keep uncompressed datafiles reasonable; 28 * ~14 MB at 1-minute sampling.
          ZIP="xz"
      notify: Reload systemd

    - name: Let Debian's cron helper collect (debian-sa1 exits unless ENABLED="true")
      ansible.builtin.lineinfile:
        path: /etc/default/sysstat
        regexp: '^ENABLED='
        line: 'ENABLED="true"'
      when: ansible_os_family == 'Debian'

    - name: Enable sysstat data collection
      ansible.builtin.service:
        name: sysstat
        enabled: true
        state: started

    - name: Ensure the timer override directory exists
      ansible.builtin.file:
        path: /etc/systemd/system/sysstat-collect.timer.d
        state: directory
        owner: root
        group: root
        mode: "0755"
      when: ansible_service_mgr == 'systemd'

    - name: Override the collection interval (systemd-timer distributions)
      ansible.builtin.copy:
        dest: /etc/systemd/system/sysstat-collect.timer.d/override.conf
        owner: root
        group: root
        mode: "0644"
        content: |
          [Unit]
          Description=Collect system activity every minute

          [Timer]
          OnCalendar=
          OnCalendar={{ sysstat_collect_calendar }}
          AccuracySec=1s
          Persistent=false
      when: ansible_service_mgr == 'systemd'
      notify: Reload systemd

    - name: Enable sysstat timers
      ansible.builtin.systemd_service:
        name: "{{ item }}"
        enabled: true
        state: started
        daemon_reload: true
      loop:
        - sysstat-collect.timer
        - sysstat-summary.timer
      when: ansible_service_mgr == 'systemd'
      failed_when: false

    - name: Fall back to cron where no sysstat timers exist
      ansible.builtin.cron:
        name: "{{ item.name }}"
        minute: "{{ item.minute }}"
        hour: "{{ item.hour | default('*') }}"
        user: root
        job: "{{ item.job }}"
        cron_file: sysstat
      loop:
        - name: sysstat-collect
          minute: "*/1"
          job: "command -v debian-sa1 > /dev/null && debian-sa1 1 1 || /usr/lib64/sa/sa1 1 1"
        - name: sysstat-summary
          minute: "7"
          hour: "0"
          job: "command -v debian-sa2 > /dev/null && debian-sa2 -A || /usr/lib64/sa/sa2 -A"
      when: ansible_service_mgr != 'systemd'

    - name: Create the node_exporter system user
      ansible.builtin.user:
        name: "{{ node_exporter_user }}"
        system: true
        shell: /usr/sbin/nologin
        home: /var/lib/node_exporter
        create_home: true

    - name: Create the textfile collector directory
      ansible.builtin.file:
        path: "{{ node_exporter_textfile_dir }}"
        state: directory
        owner: "{{ node_exporter_user }}"
        group: "{{ node_exporter_user }}"
        mode: "0755"

    - name: Install node_exporter
      ansible.builtin.unarchive:
        src: "https://github.com/prometheus/node_exporter/releases/download/v{{ node_exporter_version }}/node_exporter-{{ node_exporter_version }}.linux-amd64.tar.gz"
        dest: /usr/local/bin
        remote_src: true
        extra_opts:
          - --strip-components=1
          - --wildcards
          - "*/node_exporter"
        owner: root
        group: root
        mode: "0755"
        creates: /usr/local/bin/node_exporter
      notify: Restart node_exporter

    - name: Install the node_exporter unit
      ansible.builtin.copy:
        dest: /etc/systemd/system/node_exporter.service
        owner: root
        group: root
        mode: "0644"
        content: |
          [Unit]
          Description=Prometheus node exporter
          Documentation=https://github.com/prometheus/node_exporter
          After=network-online.target
          Wants=network-online.target

          [Service]
          Type=simple
          User={{ node_exporter_user }}
          Group={{ node_exporter_user }}
          ExecStart=/usr/local/bin/node_exporter \
            --web.listen-address={{ node_exporter_listen }} \
            --collector.textfile.directory={{ node_exporter_textfile_dir }} \
            --collector.pressure \
            --collector.cpu.info \
            --collector.diskstats \
            --collector.netdev.enable-detailed-tx-metrics \
            --collector.netdev.enable-detailed-rx-metrics \
            --collector.netstat.fields=^(.*_(InErrors|InCsumErrors|RetransSegs|OutRsts|ListenOverflows|ListenDrops|RcvbufErrors|SndbufErrors|NoPorts)|Tcp_(ActiveOpens|PassiveOpens|CurrEstab|InSegs|OutSegs))$ \
            --collector.vmstat.fields=^(oom_kill|pgpg|pswp|pg.*fault|pgscan|pgsteal).* \
            --collector.processes \
            --collector.cgroups \
            --collector.systemd \
            --no-collector.wifi \
            --no-collector.nfsd
          ExecReload=/bin/kill -HUP $MAINPID
          Restart=on-failure
          RestartSec=5s
          NoNewPrivileges=true
          ProtectHome=yes
          ProtectSystem=strict
          ProtectKernelTunables=true
          ProtectControlGroups=false
          PrivateTmp=true
          # The exporter must stay alive precisely when memory is scarce.
          OOMScoreAdjust=-500
          MemoryMax=256M
          CPUQuota=20%

          [Install]
          WantedBy=multi-user.target
      notify:
        - Reload systemd
        - Restart node_exporter

    - name: Enable node_exporter
      ansible.builtin.systemd_service:
        name: node_exporter
        enabled: true
        state: started
        daemon_reload: true

    - name: Verify that sysstat is actually producing data
      ansible.builtin.command:
        cmd: sar -u 1 1
      register: sar_check
      changed_when: false
      failed_when: "'Average' not in sar_check.stdout"

    - name: Report the measurement substrate state
      ansible.builtin.debug:
        msg: >-
          sysstat collecting at {{ sysstat_collect_calendar }},
          {{ sysstat_history_days }} days retained,
          delay accounting = {{ lookup('ansible.builtin.file', '/proc/sys/kernel/task_delayacct') }},
          node_exporter on {{ node_exporter_listen }}
```

### 9.3 Reglas de Prometheus — saturación primero, completas

```yaml
---
# /etc/prometheus/rules/resource-saturation.yml
# Alerts on SATURATION (work that had to wait) and ERRORS (work that was lost),
# not on utilisation. A host at 95% CPU with no queue is doing its job; a host
# at 40% CPU with a run queue is failing its users.
groups:
  - name: resource-saturation-recording
    interval: 30s
    rules:
      # Average disk queue depth, i.e. iostat's aqu-sz: the derivative of the
      # millisecond-weighted I/O time is, by definition, the mean queue length.
      - record: instance_device:disk_queue_depth:rate5m
        expr: rate(node_disk_io_time_weighted_seconds_total[5m])

      # iostat's r_await and w_await, in seconds.
      - record: instance_device:disk_read_await_seconds:rate5m
        expr: |
          rate(node_disk_read_time_seconds_total[5m])
          /
          clamp_min(rate(node_disk_reads_completed_total[5m]), 1)

      - record: instance_device:disk_write_await_seconds:rate5m
        expr: |
          rate(node_disk_write_time_seconds_total[5m])
          /
          clamp_min(rate(node_disk_writes_completed_total[5m]), 1)

      # Run-queue pressure per CPU: load average normalised by core count.
      - record: instance:cpu_load_per_core:ratio
        expr: |
          node_load1
          /
          count by (instance) (node_cpu_seconds_total{mode="idle"})

      # Mean packet size, which decides whether the ceiling is bits or packets.
      - record: instance_device:net_mean_rx_packet_bytes:rate5m
        expr: |
          rate(node_network_receive_bytes_total[5m])
          /
          clamp_min(rate(node_network_receive_packets_total[5m]), 1)
```

El grupo de alertas vive en su propio archivo, construido sobre las reglas de recording de arriba:

```yaml
---
# /etc/prometheus/rules/resource-saturation-alerts.yml
groups:
  - name: resource-saturation-alerts
    interval: 30s
    rules:
      - alert: CPUSaturation
        expr: rate(node_pressure_cpu_waiting_seconds_total[5m]) > 0.20
        for: 10m
        labels:
          severity: warning
          resource: cpu
        annotations:
          summary: "CPU pressure above 20% on {{ $labels.instance }}"
          description: >-
            Runnable tasks spent more than 20% of wall time waiting for a CPU.
            Utilisation may still look healthy. Triage with:
            mpstat -P ALL 5, pidstat -u -t 5, cat /proc/pressure/cpu
          runbook_url: "https://runbooks.example.net/cpu-saturation"

      - alert: CPUStealTime
        expr: |
          sum by (instance) (rate(node_cpu_seconds_total{mode="steal"}[5m]))
          /
          count by (instance) (node_cpu_seconds_total{mode="idle"})
          > 0.05
        for: 15m
        labels:
          severity: warning
          resource: cpu
        annotations:
          summary: "Hypervisor steal time above 5% on {{ $labels.instance }}"
          description: "This guest is runnable but not being scheduled by the host. The fix is capacity on the hypervisor, not on the guest."

      - alert: CPUThrottledByCgroup
        expr: |
          rate(container_cpu_cfs_throttled_periods_total[5m])
          /
          clamp_min(rate(container_cpu_cfs_periods_total[5m]), 1)
          > 0.25
        for: 10m
        labels:
          severity: warning
          resource: cpu
        annotations:
          summary: "More than 25% of CFS periods throttled for {{ $labels.name }}"
          description: "The workload is hitting its cpu.max quota. Host CPU graphs will show idle capacity; read cpu.stat in the cgroup."

      - alert: MemoryPressureStall
        expr: rate(node_pressure_memory_stalled_seconds_total[5m]) > 0.05
        for: 5m
        labels:
          severity: critical
          resource: memory
        annotations:
          summary: "Full memory stall above 5% on {{ $labels.instance }}"
          description: >-
            All non-idle tasks were stalled on memory reclaim. Verify with
            sar -B 1 (watch %vmeff and pgscand/s) and sar -W 1.

      - alert: MemoryReclaimInefficient
        expr: |
          rate(node_vmstat_pgsteal_direct[5m])
          /
          clamp_min(rate(node_vmstat_pgscan_direct[5m]), 1)
          < 0.40
        for: 10m
        labels:
          severity: warning
          resource: memory
        annotations:
          summary: "Reclaim efficiency below 40% on {{ $labels.instance }}"
          description: "The kernel scans more than two pages per page freed, inside the allocating task. This is thrashing, and it precedes the OOM killer."

      - alert: MemoryAvailableLow
        expr: node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.10
        for: 10m
        labels:
          severity: warning
          resource: memory
        annotations:
          summary: "MemAvailable below 10% on {{ $labels.instance }}"
          description: "Judged on MemAvailable, not MemFree: low MemFree alone is the normal, healthy state of a Linux host."

      - alert: InodeExhaustion
        expr: |
          node_filesystem_files_free{fstype!~"tmpfs|overlay|squashfs"}
          /
          clamp_min(node_filesystem_files{fstype!~"tmpfs|overlay|squashfs"}, 1)
          < 0.10
        for: 10m
        labels:
          severity: critical
          resource: disk
        annotations:
          summary: "Inodes below 10% on {{ $labels.instance }}:{{ $labels.mountpoint }}"
          description: "Writes will fail with ENOSPC while df -h still shows free space. Confirm with df -i."

      - alert: DiskLatencyHigh
        expr: instance_device:disk_write_await_seconds:rate5m > 0.050
        for: 10m
        labels:
          severity: warning
          resource: disk
        annotations:
          summary: "Write await above 50ms on {{ $labels.instance }}:{{ $labels.device }}"
          description: >-
            Latency, not %util, is the saturation signal for a queued device.
            Get the distribution with biolatency-bpfcc -D 10 1 before replacing hardware.

      - alert: IOPressureStall
        expr: rate(node_pressure_io_stalled_seconds_total[5m]) > 0.20
        for: 10m
        labels:
          severity: warning
          resource: disk
        annotations:
          summary: "Full I/O stall above 20% on {{ $labels.instance }}"
          description: "The host did no useful work for a fifth of the interval because every task was blocked on I/O."

      - alert: TCPAcceptQueueOverflow
        expr: rate(node_netstat_TcpExt_ListenOverflows[5m]) > 1
        for: 5m
        labels:
          severity: critical
          resource: network
        annotations:
          summary: "TCP accept queue overflowing on {{ $labels.instance }}"
          description: >-
            Completed connections are being dropped because the application is not
            calling accept() fast enough. Confirm with: ss -ltn (compare Recv-Q
            against Send-Q on LISTEN rows). Raising somaxconn does not help if the
            application passed a small backlog to listen(2).

      - alert: NICReceiveDrops
        expr: |
          rate(node_network_receive_drop_total[5m])
          +
          rate(node_network_receive_fifo_total[5m])
          > 1
        for: 10m
        labels:
          severity: warning
          resource: network
        annotations:
          summary: "Receive drops on {{ $labels.instance }}:{{ $labels.device }}"
          description: >-
            Separate ring exhaustion from socket-buffer exhaustion:
            fifo/missed means the NIC had no descriptor (ethtool -G, ethtool -L),
            plain drop means the kernel or the application could not keep up.

      - alert: PacketRateBound
        expr: |
          rate(node_network_receive_packets_total[5m]) > 500000
          and
          instance_device:net_mean_rx_packet_bytes:rate5m < 300
        for: 10m
        labels:
          severity: warning
          resource: network
        annotations:
          summary: "Small-packet flood on {{ $labels.instance }}:{{ $labels.device }}"
          description: "Over 500 kpps at under 300 bytes mean size: the ceiling here is packets per second in the softirq path, not link bandwidth. Interface utilisation will look low."

      - alert: ConntrackTableNearFull
        expr: node_nf_conntrack_entries / node_nf_conntrack_entries_limit > 0.80
        for: 5m
        labels:
          severity: critical
          resource: network
        annotations:
          summary: "Connection tracking table above 80% on {{ $labels.instance }}"
          description: >-
            At 100% the kernel drops packets and logs "nf_conntrack: table full".
            Inspect the composition first (conntrack -L | awk), because the usual
            cause is a 5-day established timeout or a TIME_WAIT pile, not real load.
            Raising nf_conntrack_max costs ~320 bytes of unreclaimable kernel
            memory per entry.
```

### 9.4 Un slice de systemd apto para medición

```ini
# /etc/systemd/system/batch.slice
# Confine batch work so that it can never starve the control plane, and so that
# its own saturation is measurable per-cgroup instead of being averaged into the
# host figures.
[Unit]
Description=Batch and reporting workloads
Before=slices.target

[Slice]
# Relative weight under contention; no hard quota, so idle capacity is usable.
CPUWeight=20
# Reclaim throttling starts here; the hard wall is 4 G.
MemoryHigh=3G
MemoryMax=4G
MemorySwapMax=1G
# Proportional I/O weight; prevents a backup job from adding queue depth to the
# database's device.
IOWeight=20
TasksMax=4096
# Sacrifice this slice first if the host runs out of memory.
OOMScoreAdjust=500
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=60%
```

```
$ systemd-run --slice=batch.slice --unit=nightly-report \
    --property=CPUQuota=200% --property=IOReadBandwidthMax="/dev/nvme0n1 200M" \
    /usr/local/bin/nightly-report.sh
Running as unit: nightly-report.service

$ systemd-cgtop -1 --order=cpu -n 2 -b
Control Group                      Tasks   %CPU   Memory  Input/s Output/s
/                                   1283  412.4    40.1G   182.4M    51.6M
system.slice                         884  388.1    38.2G   180.1M    48.4M
system.slice/postgresql.service      142  198.4    22.1G   178.2M    44.1M
system.slice/api.service              88  188.4    12.4G     1.0M     4.1M
batch.slice                           12   18.4     2.1G     1.2M     3.2M
batch.slice/nightly-report.service     4   18.4     2.1G     1.2M     3.2M
```

`systemd-cgtop` es el `top` por servicio, y en un host con systemd suele ser la ruta más rápida desde "la máquina está ocupada" hasta "esta unit está ocupada". `systemd-cgls` muestra el mismo árbol de forma estructural.

### 9.5 Exportación legible por máquina con `sadf`

```
$ sadf -j -- -u -q -f /var/log/sa/sa14 | python3 -c 'import json,sys; json.load(sys.stdin); print("valid")'
valid
```

Un documento `sadf -j` completo (un intervalo, recortado a dos grupos de estadísticas mediante los argumentos después de `--`, no editando — editar el JSON lo haría inválido):

```json
{
  "sysstat": {
    "hosts": [
      {
        "nodename": "db03.prod.example.net",
        "sysname": "Linux",
        "release": "6.8.0-45-generic",
        "machine": "x86_64",
        "number-of-cpus": 16,
        "file-date": "2026-10-14",
        "file-utc-offset": 0,
        "statistics": [
          {
            "timestamp": {
              "date": "2026-10-14",
              "time": "03:25:01",
              "utc": 0,
              "interval": 60
            },
            "cpu-load": [
              {
                "cpu": "all",
                "user": 7.12,
                "nice": 0.00,
                "system": 3.48,
                "iowait": 41.07,
                "steal": 0.00,
                "idle": 48.33
              }
            ],
            "queue": {
              "runq-sz": 3,
              "plist-sz": 1283,
              "ldavg-1": 18.42,
              "ldavg-5": 14.77,
              "ldavg-15": 9.31,
              "blocked": 41
            }
          }
        ]
      }
    ]
  }
}
```

Otras formas de exportación, todas operativamente útiles:

```
$ sadf -d -- -d -p -f /var/log/sa/sa14 | head -3
# hostname;interval;timestamp;DEV;tps;rkB/s;wkB/s;dkB/s;areq-sz;aqu-sz;await;%util
db03.prod.example.net;60;2026-10-14 00:01:01 UTC;nvme0n1;412.44;1884.21;18412.04;0.00;49.21;0.42;1.02;8.41
db03.prod.example.net;60;2026-10-14 00:02:01 UTC;nvme0n1;408.12;1902.44;18204.80;0.00;49.44;0.41;1.01;8.22

$ sadf -g -T -- -u -r -n DEV -f /var/log/sa/sa14 > /tmp/sa14.svg
$ sadf -x -- -A -f /var/log/sa/sa14 | head -4
<?xml version="1.0" encoding="ISO-8859-1"?>
<!DOCTYPE sysstat PUBLIC "DTD v3.11 sysstat //DTD Sysstat 3.11//EN" "http://pagesperso-orange.fr/sebastien.godard/sysstat-3.11.dtd">
<sysstat xmlns="http://pagesperso-orange.fr/sebastien.godard/sysstat"
```

`sadf -g` produce un SVG autocontenido de todo el día sin Grafana, sin Prometheus y sin acceso a red — el artefacto más útil para adjuntar a un reporte de incidente en un host aislado.

---

## 10. Estimar el throughput e identificar el cuello de botella

### 10.1 El techo de cada recurso

| Recurso | Fórmula del techo | Medí los términos con | Primer síntoma de saturación |
|---|---|---|---|
| CPU (paralela) | `cores × 1.0` | `mpstat -P ALL` | `r` > cores en `vmstat`; `%wait` en `pidstat` |
| CPU (un thread) | `1 core` | `pidstat -t`, `top -H` | un core al 100 %, la máquina al `100/ncores` % |
| Softirq / camino de paquetes | ~1–3 Mpps por core | `mpstat -I SCPU`, `softnet_stat` | `time_squeeze`, `rx_missed_errors` |
| Capacidad de memoria | `MemTotal - kernel - min_free` | `MemAvailable`, `memory.current` | `majflt/s`, `%vmeff` cayendo |
| Ancho de banda de memoria | plataforma (`mbw`, `perf stat`) | `perf stat -e cache-misses` | caída de IPC sin cambio en la carga |
| IOPS de disco | IOPS del dispositivo a la profundidad de cola que usás | job de techo de `fio` | `await` subiendo mientras los IOPS quedan planos |
| Ancho de banda de disco | MB/s del dispositivo | job secuencial de `fio` | `rareq-sz` grande, `await` subiendo |
| Tasa de escrituras sincrónicas | `1 / fdatasync_latency` | job `sync-write-cost` de `fio` | la latencia de commit = la latencia de toda la transacción |
| Ancho de banda del enlace | tasa de línea × (payload / frame en el cable) | `sar -n DEV` (`rxkB/s`) | `%ifutil`, `backlog` del qdisc |
| Tasa de paquetes del enlace | tasa de línea / bits del frame en el cable | `sar -n DEV` (`rxpck/s`) | descartes con `%ifutil` bajo |
| Un solo flujo TCP | `min(cwnd, rwnd) / RTT` | `ss -ti` | `rwnd_limited`, `sndbuf_limited` |
| Conntrack | entradas de `nf_conntrack_max` | `conntrack -S` | `insert_failed`, "table full" en `dmesg` |
| Tasa de accept | backlog de `listen()` de la aplicación | `ss -ltn`, `nstat` | `ListenOverflows` |
| Descriptores de archivo | `ulimit -n`, `fs.file-max` | `lsof \| wc -l`, `/proc/sys/fs/file-nr` | `EMFILE`, "too many open files" |

### 10.2 Ejemplo trabajado: por qué un host de 25 GbE mueve 600 Mbit/s

```
$ ss -ti 'dst 198.51.100.200' | tail -4
         cubic wscale:7,7 rto:284 rtt:80.112/0.884 mss:1448 pmtu:9000 rcvmss:1448 advmss:8948
         cwnd:1448 bytes_sent:4194304000 bytes_acked:4194303000 segs_out:2896000 segs_in:1448000
         send 209.4Mbps lastsnd:4 pacing_rate 251.3Mbps delivery_rate 208.1Mbps
         sndbuf_limited:184112ms(88.4%) busy:208112ms rcv_space:14480 minrtt:80.004

$ sysctl net.ipv4.tcp_wmem net.ipv4.tcp_rmem net.core.wmem_max net.ipv4.tcp_congestion_control
net.ipv4.tcp_wmem = 4096        16384   4194304
net.ipv4.tcp_rmem = 4096        131072  6291456
net.core.wmem_max = 212992
net.ipv4.tcp_congestion_control = cubic
```

La aritmética:

- Producto ancho de banda–retardo para 25 Gbit/s con 80 ms de RTT: `25e9 × 0.080 / 8 = 250 MB`. Para llenar el pipe con un solo flujo necesitás una ventana de 250 MB.
- El máximo del buffer de envío es `tcp_wmem[2] = 4 MiB`. Ventana usable ≈ 4 MiB (menos el overhead).
- Throughput máximo de un solo flujo: `4 MiB / 0.080 s ≈ 419 Mbit/s`. Los 209 Mbit/s observados son todavía más bajos porque aproximadamente la mitad del buffer la consume la contabilidad de datos sin ACK.
- `sndbuf_limited:88.4%` es el kernel diciéndote precisamente esto, en un solo campo.

Así que esto es un **bug de sysctl, no un problema de red**, y el costo de diagnosticarlo mal es una orden de compra de capacidad. Notá también que `net.core.wmem_max = 212992` es el valor por defecto y no sobrescribe `tcp_wmem` para el autotuning de TCP — pero *sí* limita a cualquier aplicación que llame a `setsockopt(SO_SNDBUF)`, donde reduce a la mitad el pedido efectivo. Hay que subir ambos:

```
$ sudo sysctl -w net.ipv4.tcp_wmem="4096 65536 268435456"
net.ipv4.tcp_wmem = 4096 65536 268435456
$ sudo sysctl -w net.ipv4.tcp_rmem="4096 131072 268435456"
net.ipv4.tcp_rmem = 4096 131072 268435456
$ sudo sysctl -w net.core.wmem_max=268435456 net.core.rmem_max=268435456
net.core.wmem_max = 268435456
net.core.rmem_max = 268435456
$ sudo sysctl -w net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_congestion_control = bbr
```

Para un camino largo, gordo y con pérdidas, la cota de Mathis es el chequeo de cordura antes de comprar nada: `BW ≈ MSS / (RTT × √p)`. Con `MSS=1448`, `RTT=0.080 s`, pérdida `p=0.001`: `1448 / (0.080 × 0.0316) ≈ 573 kB/s ≈ 4.6 Mbit/s` por flujo con control de congestión clásico basado en pérdida. En un camino con 0,1 % de pérdida, **ningún ajuste de ventana lleva a un único flujo CUBIC más allá de unos pocos megabits por segundo** — las respuestas son BBR, flujos paralelos, o arreglar la pérdida.

Verificá con los instrumentos estándar, en ambas direcciones y con paralelismo:

```
$ iperf3 -c 198.51.100.200 -t 30 -P 8 -i 10 --get-server-output | tail -6
[SUM]   0.00-30.00  sec  68.4 GBytes  19.6 Gbits/sec  1204            sender
[SUM]   0.00-30.04  sec  68.3 GBytes  19.5 Gbits/sec                  receiver

$ iperf3 -c 198.51.100.200 -u -b 10G -l 64 -t 10 | tail -3
[  5]   0.00-10.00  sec  1.02 GBytes   876 Mbits/sec  0.000 ms  0/17104882 (0%)  sender
[  5]   0.00-10.04  sec   712 MBytes   595 Mbits/sec  0.041 ms  5204112/17104882 (30%)  receiver
```

Ocho streams paralelos alcanzan 19,6 Gbit/s — el camino está bien y el límite de un solo flujo era local. El test UDP de 64 bytes muestra después el *otro* techo: 30 % de pérdida a ~1,7 Mpps ofrecidos. Esa es la pared de tasa de paquetes de la sección 7.1, medida.

### 10.3 La ley de Little como localizador de cuellos de botella

`concurrencia = throughput × latencia`. Aplicada por capa, te dice qué capa retiene los requests:

```
Observed: 2,000 req/s at 250 ms p50  →  in-flight requests = 2000 × 0.25 = 500
Application worker pool                                     = 64
```

500 en vuelo contra 64 workers significa que 436 requests están encolados **antes** de la aplicación — en la cola de accept, en el balanceador de carga, o en el kernel. Ninguna cantidad de profiling de la aplicación los va a encontrar; `ss -ltn` sí, en una línea. A la inversa, si el pool fuera 512 y la base de datos mostrara `aqu-sz 480`, los requests están encolados en la capa de almacenamiento y el arreglo está aguas abajo.

---

## 11. Matriz de correlación síntoma → causa probable

Esta es el área de "emparejar / correlacionar síntomas del sistema con problemas probables" del objetivo, y la tabla es el entregable.

| Síntoma observado | Causas más probables | Comando de confirmación | Evidencia decisiva |
|---|---|---|---|
| Load alto, `%idle` alto, `b` alto en `vmstat` | almacenamiento o NFS bloqueando | `vmstat 5`, `ps -eo stat,wchan,args \| grep '^D'` | procesos en `D` con `WCHAN` de bloques/NFS |
| Load alto, `r` ≫ cores, `%usr` alto | escasez genuina de CPU | `mpstat -P ALL`, `pidstat -u -t` | cola de ejecución > cores, `%wait` por tarea |
| Load alto, un core al 100 %, la máquina casi idle | camino caliente single-threaded, o una sola cola de NIC | `mpstat -P ALL`, `top -H` | una CPU ocupada; `%soft` si es red |
| CPU ocupada pero throughput cayendo | contención de locks, throttling de cgroup, thrashing de memoria | `pidstat -w`, `cpu.stat`, `sar -B` | `nvcswch/s` alto; `nr_throttled`; `%vmeff` < 40 % |
| `%steal` > 5 % | sobresuscripción del hipervisor | `mpstat -P ALL`, `sar -u` | `%steal` sostenido; nada en el guest lo arregla |
| `%iowait` alto **y** throughput alto | trabajo normal limitado por I/O | `iostat -xz 5` | `await` dentro de la especificación del dispositivo |
| `%iowait` alto **y** throughput bajo | degradación del dispositivo, almacenamiento remoto, inanición de cola | `biolatency`, `iostat -xz` | histograma de latencia bimodal / con cola larga |
| `%util` 100 % en NVMe, `await` ~1 ms | **no es un problema** | `iostat -xz`, línea base de `fio` | `await` ≈ piso medido del dispositivo |
| `%util` 100 %, `await` ≫ 20 ms, `aqu-sz` alto | saturación real del disco | `iostat -xz`, `iotop -oPa` | `await` subiendo con la carga ofrecida |
| Memoria libre cerca de cero | comportamiento **normal** del page cache | `free -w`, `MemAvailable` | `available` todavía grande |
| `majflt/s` alto, `%vmeff` bajo, `pgscand/s` alto | el working set excede la RAM | `sar -B`, `sar -r` | reclaim directo con eficiencia pobre |
| Swap usado pero `si`/`so` ≈ 0 | **normal** — páginas anónimas frías | `vmstat 5`, `sar -W` | sin tráfico de swap |
| `si`/`so` sostenidos, picos de latencia | thrashing | `sar -W`, `/proc/pressure/memory` | presión de memoria `full` > 0 |
| Proceso muerto, sin error de la aplicación | OOM killer, u OOM de cgroup | `dmesg -T`, `memory.events` | "Killed process"; `oom_kill` > 0 |
| Congelamientos de escritura de 20 segundos | acantilado de writeback de páginas sucias | `grep Dirty /proc/meminfo`, `sysctl vm.dirty_ratio` | `Dirty` cerca de `dirty_ratio × MemTotal` |
| `ENOSPC` con espacio libre en `df -h` | agotamiento de inodos | `df -i` | `IUse% 100` |
| `df` y `du` difieren en gigabytes | archivos borrados todavía abiertos | `lsof +L1` | entradas con `NLINK 0` |
| Timeouts de conexión, host por lo demás idle | desborde de la cola de accept | `ss -ltn`, `nstat` | `Recv-Q` > `Send-Q` en LISTEN; `ListenOverflows` |
| Resets intermitentes bajo carga | agotamiento de puertos efímeros o de conntrack | `ss -s`, `conntrack -S`, `sysctl net.ipv4.ip_local_port_range` | montaña de `TIME_WAIT`; `insert_failed` |
| Pérdida de paquetes con `%ifutil` bajo | limitado por tasa de paquetes, ring demasiado chico, cola única | `sar -n DEV/EDEV`, `ethtool -S/-l/-g`, `softnet_stat` | tamaño medio de paquete chico; `rx_missed`, `time_squeeze` |
| RX `dropped` con `missed` en cero | buffers de socket / lector lento | `ss -tm`, `nstat` (`RcvbufErrors`) | `Recv-Q` grande en el socket |
| Un flujo lento, los otros bien | ventana del receptor, o topes de buffer | `ss -ti` | porcentajes de `rwnd_limited` / `sndbuf_limited` |
| El throughput colapsa por encima de N Mbit/s | pérdida + CC basado en pérdida en un pipe gordo | `ss -ti`, `nstat` (`TCPSynRetrans`, `RetransSegs`) | retransmisiones > 0,1 %; la cota de Mathis coincide |
| El host de firewall descarta paquetes, la CPU "está bien" | costo de `nft_do_chain` / búsqueda de conntrack | `perf top -e cycles:k`, `conntrack -S` | ciclos de kernel en funciones de netfilter |
| Todo lento después de un deploy, métricas normales | límites de cgroup en la unit nueva | `systemd-cgtop`, `cpu.stat`, `memory.events` | períodos throttleados / eventos `high` |

---

## 12. Guía de verificación y diagnóstico de fallas

### 12.1 Verificá el sustrato de medición antes de necesitarlo

```
$ sar -u 1 1
Linux 6.8.0-45-generic (db03)   10/15/2026      _x86_64_        (16 CPU)
12:21:04        CPU     %user     %nice   %system   %iowait    %steal     %idle
12:21:05        all      7.12      0.00      3.48      0.21      0.00     89.19
Average:        all      7.12      0.00      3.48      0.21      0.00     89.19

$ sar -d -p 1 1 | head -3
12:21:10          DEV       tps     rkB/s     wkB/s     dkB/s   areq-sz    aqu-sz     await     %util
12:21:11      nvme0n1    412.00   1884.00  18412.00      0.00     49.26      0.42      1.02      8.40

$ sudo systemctl list-timers 'sysstat*' --no-pager
NEXT                        LEFT       LAST                        PASSED     UNIT                   ACTIVATES
Thu 2026-10-15 12:22:00 CEST 41s       Thu 2026-10-15 12:21:00 CEST 19s ago    sysstat-collect.timer  sysstat-collect.service
Fri 2026-10-16 00:07:00 CEST 11h 46min Thu 2026-10-15 00:07:00 CEST 12h ago    sysstat-summary.timer  sysstat-summary.service

$ ls -la /var/log/sa/ | tail -4
-rw-r--r-- 1 root root 14204881 Oct 13 23:59 sa13
-rw-r--r-- 1 root root 14118412 Oct 14 23:59 sa14
-rw-r--r-- 1 root root  7204112 Oct 15 12:21 sa15
-rw-r--r-- 1 root root  2104884 Oct 14 00:07 sar14

$ sysctl kernel.task_delayacct
kernel.task_delayacct = 1

$ grep . /proc/pressure/* 
/proc/pressure/cpu:some avg10=1.42 avg60=2.11 avg300=1.88 total=18472930184
/proc/pressure/io:some avg10=0.84 avg60=1.02 avg300=0.91 total=99184772093
/proc/pressure/io:full avg10=0.41 avg60=0.48 avg300=0.44 total=71204881003
/proc/pressure/memory:some avg10=0.00 avg60=0.00 avg300=0.00 total=1204881
/proc/pressure/memory:full avg10=0.00 avg60=0.00 avg300=0.00 total=402114
```

Modos de falla del propio sustrato, cada uno de los cuales produce silenciosamente una investigación vacía:

| Chequeo | Falla | Causa | Arreglo |
|---|---|---|---|
| `sar -u 1 1` | `Cannot open /var/log/sa/sa15: No such file` | la recolección nunca se habilitó | habilitar el servicio `sysstat` y el timer de recolección |
| `sar -d` | `Requested activities not available in file` | a `SADC_OPTIONS` le falta `-S DISK` | setear `SADC_OPTIONS`, después esperar datos nuevos (los archivos viejos no se pueden arreglar) |
| `sar -f sa01` | el archivo es de este mes o más viejo de lo esperado | con `HISTORY` ≤ 28 los nombres `saDD` se reutilizan cada mes | setear `HISTORY` > 28 para nombres `YYYYMMDD`, o archivar fuera de la máquina |
| `iotop` | `CONFIG_TASK_DELAY_ACCT not enabled` | `kernel.task_delayacct=0` | sysctl, persistido |
| `ss -tiepm` | sin detalles de `skmem`/`bbr` | no sos root | correr con `sudo` |
| `/proc/pressure/*` | ausente | kernel < 4.20 o `psi=0` | bootear con `psi=1` |
| `perf top` | `Permission denied` | `perf_event_paranoid=3` | bajar a 1 (o 2) |

### 12.2 El script de captura de incidentes

La primera víctima de un incidente son los datos, porque el síntoma termina antes de que alguien se loguee. Capturá todo de una vez, a disco, en una sola pasada acotada:

```bash
#!/usr/bin/env bash
# /usr/local/sbin/resource-snapshot — capture every resource view in parallel.
# Bounded (exits after DURATION), writes one file per view, never pipes through tee.
set -euo pipefail

DURATION="${1:-60}"
OUT="/var/tmp/snapshot-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"

{
    uname -a
    uptime
    date -u
} > "$OUT/00-context.txt"

# Point-in-time state.
ps -eo pid,ppid,user,stat,psr,pcpu,pmem,rss,vsz,wchan:22,etimes,args --sort=-pcpu \
    > "$OUT/01-ps.txt"
pstree -aps > "$OUT/02-pstree.txt"
ss -tanipemo > "$OUT/03-ss-sockets.txt"
ss -ltn > "$OUT/04-ss-listen.txt"
ss -s > "$OUT/05-ss-summary.txt"
ip -s -s link > "$OUT/06-ip-link.txt"
nstat -az > "$OUT/07-nstat.txt"
df -h > "$OUT/08-df.txt"
df -i > "$OUT/09-df-inode.txt"
free -w > "$OUT/10-free.txt"
cat /proc/meminfo > "$OUT/11-meminfo.txt"
cat /proc/interrupts > "$OUT/12-interrupts.txt"
cat /proc/net/softnet_stat > "$OUT/13-softnet.txt"
grep . /proc/pressure/* > "$OUT/14-pressure.txt" 2>/dev/null || true
tc -s qdisc show > "$OUT/15-qdisc.txt"
dmesg -T | tail -500 > "$OUT/16-dmesg.txt"
systemd-cgtop -1 --order=cpu -n 1 -b > "$OUT/17-cgtop.txt" 2>/dev/null || true
conntrack -S > "$OUT/18-conntrack-stats.txt" 2>/dev/null || true
lsof +L1 > "$OUT/19-deleted-open-files.txt" 2>/dev/null || true
for f in /sys/fs/cgroup/*/cpu.stat /sys/fs/cgroup/*/*/cpu.stat; do
    [ -r "$f" ] && { echo "== $f"; cat "$f"; }
done > "$OUT/20-cgroup-cpu-stat.txt" 2>/dev/null || true

# Interval samplers, all started together so the timelines align.
vmstat 1 "$DURATION"                         > "$OUT/30-vmstat.txt"  2>&1 &
mpstat -P ALL 1 "$DURATION"                  > "$OUT/31-mpstat.txt"  2>&1 &
mpstat -I SCPU 1 "$DURATION"                 > "$OUT/32-softirq.txt" 2>&1 &
iostat -xzt 1 "$DURATION"                    > "$OUT/33-iostat.txt"  2>&1 &
pidstat -urdw -t 1 "$DURATION"               > "$OUT/34-pidstat.txt" 2>&1 &
sar -n DEV,EDEV,TCP,ETCP,SOCK 1 "$DURATION"  > "$OUT/35-sar-net.txt" 2>&1 &
sar -B 1 "$DURATION"                         > "$OUT/36-sar-paging.txt" 2>&1 &
top -b -H -n "$DURATION" -d 1 -w 512         > "$OUT/37-top.txt"     2>&1 &
iotop -oPab -d 1 -n "$DURATION"              > "$OUT/38-iotop.txt"   2>&1 &

wait
tar -caf "$OUT.tar.zst" -C "$(dirname "$OUT")" "$(basename "$OUT")"
printf 'snapshot: %s.tar.zst\n' "$OUT"
```

Dos propiedades deliberadas: **nada se pipea a través de `tee`** (en un pipeline el estado de salida es el del último comando, así que un sampler que falla reporta éxito), y cada sampler está acotado por `-n`/cuenta para que el script no pueda sobrevivir al incidente.

### 12.3 El orden de triage

Un orden fijo le gana a la intuición, porque la intuición se ancla al último incidente.

```
$ uptime                                    # 1. Is this new? Which direction?
$ vmstat 5 3                                # 2. r vs b: CPU demand or blocked?
$ grep . /proc/pressure/*                   # 3. Rank saturation across resources
$ mpstat -P ALL 5 2                         # 4. Imbalance? softirq? steal?
$ iostat -xz 5 2                            # 5. await, not %util
$ free -w -h && sar -B 1 3                  # 6. MemAvailable, %vmeff, majflt/s
$ ss -ltn && nstat                          # 7. Accept queues and stack errors
$ ip -s link && cat /proc/net/softnet_stat  # 8. Drops: ring or socket?
$ systemd-cgtop -1 --order=cpu -n 1 -b      # 9. Which unit, and is it throttled?
$ pidstat -urdw -t 5 2                      # 10. Attribute to a task
```

Los pasos 1–3 llevan quince segundos y eliminan tres de los cuatro recursos. Todo lo que viene después es confirmación, no búsqueda.

### 12.4 Tres diagnósticos completos

**(a) "La API está lenta", 16 CPUs, host 75 % idle.**

```
$ uptime
 13:02:11 up 12 days,  4:18,  1 user,  load average: 2.14, 2.08, 1.94
$ vmstat 5 2 | tail -1
 2  0  73216 1284992 912384 19884416    0    0   184   412 2104  4881  11  6 82  1  0  0
$ cat /proc/pressure/cpu
some avg10=0.84 avg60=0.91 avg300=0.88 total=18472930184
$ ss -ltn | grep 8080
LISTEN     412        128                     0.0.0.0:8080             0.0.0.0:*
$ nstat -n; sleep 10; nstat | grep -i listen
TcpExtListenOverflows           1842               0.0
TcpExtListenDrops               1842               0.0
```

Sin presión de CPU, sin presión de memoria, sin presión de disco — y 184 conexiones descartadas por segundo en la cola de accept. La máquina está idle porque está **rechazando trabajo**, no porque lo esté haciendo. Arreglo: el backlog de `listen()` de la aplicación (128), más la concurrencia de workers. `somaxconn` ya está en 4096 y no es la restricción.

**(b) "Las escrituras de la base de datos se cuelgan cada unos minutos."**

```
$ grep -E 'Dirty|Writeback:' /proc/meminfo
Dirty:          11204884 kB
Writeback:       1204112 kB
$ sysctl vm.dirty_ratio vm.dirty_background_ratio
vm.dirty_ratio = 20
vm.dirty_background_ratio = 10
$ iostat -xz 5 1 | grep -E 'Device|sdb'
Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util
sdb              12.40    198.40     0.00   0.00    4.12    16.00  1204.80 154214.40   188.40  13.52 1884.12   128.00    0.00     0.00     0.00   0.00    0.00     0.00  412.40 2104.88  241.84  100.00
$ cat /proc/pressure/io
some avg10=88.41 avg60=71.04 avg300=52.11 total=99184772093
full avg10=74.12 avg60=61.44 avg300=44.08 total=71204881003
```

`Dirty` es 11,2 GB, `dirty_ratio=20` sobre 64 GB permite ~12,8 GB — el host está en el borde del acantilado, todos los escritores están bloqueados sincrónicamente, `w_await` es 1,88 s, `f_await` (fsync) es 2,1 s, y la presión `io full` es 74 %. El dispositivo no está roto; el kernel acumuló un backlog imposible de volcar. Arreglo: `vm.dirty_bytes`/`vm.dirty_background_bytes` como en la sección 5.4, dimensionados para que el backlog se drene dentro del presupuesto de latencia (`dirty_bytes ≈ MBps_del_dispositivo × segundos_de_detención_aceptables`).

**(c) "Pérdida de paquetes hacia el firewall de borde, utilización de la interfaz 11 %."**

```
$ sar -n DEV --iface=eth0 1 2
13:14:02     IFACE   rxpck/s   txpck/s    rxkB/s    txkB/s   rxcmp/s   txcmp/s  rxmcst/s   %ifutil
13:14:03      eth0 1484112.40 188412.80 141204.44  18412.04      0.00      0.00      0.44     11.29
13:14:04      eth0 1492044.80 191204.40 142112.80  18884.44      0.00      0.00      0.48     11.36

$ sar -n EDEV --iface=eth0 1 1
13:14:08     IFACE   rxerr/s   txerr/s    coll/s  rxdrop/s  txdrop/s  txcarr/s  rxfram/s  rxfifo/s  txfifo/s
13:14:09      eth0      0.00      0.00      0.00  18412.44      0.00      0.00      0.00  84112.80      0.00

$ mpstat -P ALL 1 1 | awk 'NR<4 || $4+$8 > 60'
Linux 6.8.0-45-generic (fw01)   10/15/2026      _x86_64_        (16 CPU)

13:14:12     CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle
13:14:13       0    1.02    0.00    4.12    0.00    8.41   86.45    0.00    0.00    0.00    0.00
13:14:13       1    0.82    0.00    3.88    0.00    0.00    0.00    0.00    0.00    0.00   95.30

$ awk '{print NR-1, strtonum("0x"$2), strtonum("0x"$3)}' /proc/net/softnet_stat | head -3
0 1884112 412884
1 0 0
2 0 0

$ ethtool -l eth0 | tail -2
Current hardware settings:
Combined:       1

$ sudo conntrack -S | awk -F'[= ]' '{s+=$12} END {print "insert_failed total:", s}'
insert_failed total: 1842044
```

El tamaño medio de paquete es `141204 kB / 1484112 pkt ≈ 97 bytes`. A 1,48 Mpps el enlace está utilizado al 11 % en bits y **efectivamente al 100 % en paquetes** para un camino de recepción de cola única: la CPU 0 está al 86 % de softirq con cero idle, `softnet_stat` muestra 412 884 descartes de backlog y 1,88 M procesados solo en la CPU 0, y `rxfifo/s` de 84 k confirma que la NIC se quedó sin descriptores. Conntrack agrega 1,84 M de inserciones fallidas encima.

La remediación está ordenada por efecto, y nada de eso involucra ancho de banda:

```
$ sudo ethtool -L eth0 combined 16
$ sudo ethtool -G eth0 rx 4096 tx 4096
$ sudo sysctl -w net.core.netdev_budget=1200 net.core.netdev_max_backlog=16384
net.core.netdev_budget = 1200
net.core.netdev_max_backlog = 16384
$ sudo sysctl -w net.netfilter.nf_conntrack_max=1048576
net.netfilter.nf_conntrack_max = 1048576
$ echo 262144 | sudo tee /sys/module/nf_conntrack/parameters/hashsize
262144
```

Volvé a medir, y exigí que los contadores estén planos en lugar de simplemente más chicos:

```
$ sar -n EDEV --iface=eth0 1 1
13:28:41     IFACE   rxerr/s   txerr/s    coll/s  rxdrop/s  txdrop/s  txcarr/s  rxfram/s  rxfifo/s  txfifo/s
13:28:42      eth0      0.00      0.00      0.00      0.00      0.00      0.00      0.00      0.00      0.00

$ mpstat -P ALL 1 1 | tail -4
13:28:46      13    0.82    0.00    3.12    0.00    0.41   28.44    0.00    0.00    0.00   67.21
13:28:46      14    0.88    0.00    3.08    0.00    0.41   27.88    0.00    0.00    0.00   67.75
13:28:46      15    0.84    0.00    3.21    0.00    0.38   28.12    0.00    0.00    0.00   67.45
Average:     all    0.86    0.00    3.14    0.00    0.40   28.04    0.00    0.00    0.00   67.56
```

La carga de softirq ahora está repartida entre los 16 cores a ~28 % cada uno, con cero descartes — los mismos 1,48 Mpps, sobre el mismo enlace utilizado al 11 %.

### 12.5 Checklist de verificación post-remediación

Todo cambio de arriba debe verificarse contra el contador que suponía arreglar, no contra la queja.

| Cambio | Verificar con | Condición de aprobación |
|---|---|---|
| backlog de `listen()` aumentado | `ss -ltn`; `nstat \| grep Listen` | `Recv-Q` ≪ `Send-Q`; delta de `ListenOverflows` = 0 |
| `vm.dirty_bytes` reducido | `grep Dirty /proc/meminfo`; `iostat -xz 5` | `Dirty` ≪ `dirty_bytes`; `f_await` dentro de la especificación del dispositivo |
| `nf_conntrack_max` aumentado | `conntrack -S`; `slabtop -o -s c` | delta de `insert_failed` = 0; slab de `nf_conntrack` dentro del presupuesto |
| `ethtool -L/-G` | `ethtool -S`; `mpstat -P ALL`; `softnet_stat` | delta de `rx_missed_errors` = 0; softirq repartido; columnas 2–3 planas |
| `tcp_wmem`/`tcp_rmem` aumentados | `ss -ti` | `sndbuf_limited`/`rwnd_limited` ≈ 0 % |
| límites de cgroup ajustados | `cpu.stat`; `memory.events` | delta de `nr_throttled` = 0; delta de `high`/`oom_kill` = 0 |
| tunables de scheduler/cola | re-corrida de la línea base de `fio` | el piso/techo medido se movió en la dirección esperada |
| persistencia de cualquier sysctl | `sysctl -p /etc/sysctl.d/90-measurement.conf`; prueba de reboot | el valor sobrevive al reboot |

Dos reglas que evitan falsos reportes de "arreglado":

1. **Comparás deltas, nunca contadores acumulativos.** `nstat -n` para resetear, esperás, `nstat` otra vez. Un `ListenOverflows` acumulativo de 184 412 se queda en 184 412 para siempre después del arreglo.
2. **Volvé a establecer la línea base de la caja negra.** Después del cambio, confirmá que `sar` muestra el nuevo régimen durante la hora siguiente; un arreglo verificado solo en una ventana de 10 segundos no fue verificado.

---

## 13. Notas orientadas al examen para 200.1

Las trampas que se repiten, enunciadas como las respuestas que son:

- **La primera línea de `vmstat`/`iostat`/`mpstat`/`sar` es el promedio desde el boot.** Usá `iostat -y` o descartala; nunca la cites como el valor actual.
- **El load average de Linux incluye el estado `D`.** No es una métrica de demanda de CPU. Las columnas `r` y `b` de `vmstat` lo separan.
- **`%iowait` es un estado de CPU**, acumulado solo cuando la CPU está idle con I/O pendiente. Puede ser 0 en un arreglo saturado y 6 % en un host idle con un proceso bloqueado.
- **Para sockets `LISTEN`, `Recv-Q` son accepts pendientes y `Send-Q` es el tamaño del backlog.** Para `ESTAB` son bytes no leídos y no reconocidos.
- **El `available` de `free`, no el `free`,** es la memoria que podés usar. Un `free` bajo es el estado normal.
- **El swap *usado* es inofensivo; el *tráfico* de swap (`si`/`so`, `pswpin/s`, `pswpout/s`) es el síntoma.**
- **`%util` es tiempo con un request en vuelo**, no capacidad; `await` y `aqu-sz` son las señales de saturación. `svctm` ya no existe.
- **`iotop` necesita `kernel.task_delayacct=1`** en kernels ≥ 5.14.
- **`sar -d` necesita `SADC_OPTIONS="-S DISK"`** en el momento de la recolección; no se pueden agregar actividades retroactivamente a un archivo de datos existente.
- **`sadc` escribe binario; `sar` lo lee; `sadf` lo exporta** (`-j` JSON, `-d` CSV, `-x` XML, `-g` SVG). `sa1` y `sa2` son los wrappers de cron/timer.
- **`sar -f /var/log/sa/saDD`** lee un día pasado; con `HISTORY ≤ 28` esos nombres de archivo se reutilizan cada mes.
- **`w` lee `utmp`** y por lo tanto solo ve sesiones de login.
- **`pstree -aps <pid>`** muestra la ascendencia *y* los argumentos *y* los PIDs — la combinación que identifica qué padre lanzó un proceso descontrolado.
- **`ss` usa netlink, `netstat` parsea `/proc`.** `netstat -p` además recorre `/proc/*/fd`, que es por lo que es patológicamente lento en hosts ocupados.
- **`nstat` imprime deltas por defecto**; `netstat -s` imprime totales acumulativos.
- **Modos de `iptraf-ng`:** `-i` tráfico IP, `-d` interfaz detallada, `-s` servicio por puerto, `-z` tamaños de paquete, `-l` estaciones LAN por MAC; `-B -L file -t minutos` para captura desatendida.
- **Los techos de throughput son paquetes por segundo tan a menudo como bits por segundo.** 10 GbE son 14,88 Mpps a 64 B y 812,7 kpps a 1500 B.
- **El throughput de un solo flujo TCP es `ventana / RTT`.** El `rwnd_limited` y el `sndbuf_limited` de `ss -ti` nombran directamente el lado limitante.
- **"nf_conntrack: table full, dropping packet" en `dmesg`** es un evento de capacidad de firewall, y cada entrada cuesta ~320 B de slab de kernel no recuperable.
- **El proceso que invoca al OOM killer no es, por lo general, el proceso que mata.** Leé las dos líneas de `dmesg`.

Un conjunto mínimo de comandos que deberías poder producir de memoria, en orden:

```
$ uptime; w
$ vmstat 5 3
$ mpstat -P ALL 5 2
$ iostat -xz 5 2
$ free -w -h
$ sar -u -q -r -B -W -d -p -n DEV,EDEV,TCP,ETCP 1 3
$ ps -eo pid,stat,pcpu,pmem,rss,wchan:20,args --sort=-pcpu | head
$ pstree -aps 1 | head
$ pidstat -urdw -t 5 2
$ sudo iotop -oPab -d 5 -n 2
$ ss -s; ss -ltn; ss -tiepm
$ nstat -n; sleep 10; nstat
$ ip -s -s link show eth0
$ sudo iptraf-ng -d eth0 -B -L /var/log/iptraf-ng/eth0.log -t 5
```

---

## 14. Referencias

**Oficial de LPI**

- Objetivos del examen 201-450 (incluye 200.1, peso 6): https://www.lpi.org/our-certifications/exam-201-objectives/
- Objetivos del examen 202-450: https://www.lpi.org/our-certifications/exam-202-objectives/
- Vista general de la certificación LPIC-2: https://www.lpi.org/our-certifications/lpic-2-overview/

**Documentación del kernel (`docs.kernel.org`)**

- Filesystem `proc(5)`, incluyendo `/proc/stat`, `/proc/meminfo`, `/proc/diskstats`, `/proc/loadavg`: https://docs.kernel.org/filesystems/proc.html
- Pressure Stall Information: https://docs.kernel.org/accounting/psi.html
- Delay accounting (requerido por `iotop`, `pidstat -d`): https://docs.kernel.org/accounting/delay-accounting.html
- Interfaz taskstats: https://docs.kernel.org/accounting/taskstats.html
- Control Group v2 (`cpu.max`, `cpu.stat`, `memory.max`, `memory.events`, `io.stat`): https://docs.kernel.org/admin-guide/cgroup-v2.html
- Referencia de sysctl de VM (`overcommit_memory`, `dirty_ratio`, `swappiness`, `min_free_kbytes`): https://docs.kernel.org/admin-guide/sysctl/vm.html
- Referencia de sysctl del kernel (`task_delayacct`, `perf_event_paranoid`): https://docs.kernel.org/admin-guide/sysctl/kernel.html
- Referencia de sysctl de networking (`tcp_rmem`, `tcp_wmem`, `somaxconn`, `netdev_budget`): https://docs.kernel.org/admin-guide/sysctl/net.html
- Notas de implementación y tuning de TCP: https://docs.kernel.org/networking/ip-sysctl.html
- Escalado en el stack de networking de Linux (RSS, RPS, RFS, XPS): https://docs.kernel.org/networking/scaling.html
- Estadísticas de la capa de bloques (`/sys/block/*/stat`, tunables de cola): https://docs.kernel.org/block/stat.html
- Atributos sysfs de la cola de bloques (`/sys/block/<disk>/queue/*`, ABI estable): https://www.kernel.org/doc/Documentation/ABI/stable/sysfs-block
- Encolamiento de I/O de bloques multi-cola (blk-mq): https://docs.kernel.org/block/blk-mq.html
- OOM killer y `oom_score_adj`: https://docs.kernel.org/admin-guide/mm/concepts.html
- Transparent Hugepages: https://docs.kernel.org/admin-guide/mm/transhuge.html

**Proyectos de herramientas y páginas de manual**

- Proyecto y documentación de `sysstat` (`sar`, `sadc`, `sadf`, `iostat`, `mpstat`, `pidstat`): https://github.com/sysstat/sysstat
- Sitio del proyecto `sysstat` (releases, features, FAQ): https://sysstat.github.io/
- `procps-ng` (`ps`, `top`, `vmstat`, `free`, `pstree`, `slabtop`): https://gitlab.com/procps-ng/procps
- `CHANGES` de `sysstat` (campos de iostat en 11.5.7, `svctm` eliminado en 12.1.2): https://github.com/sysstat/sysstat/blob/master/CHANGES
- `NEWS` de `procps-ng` (tiempo de guest de `vmstat` en la salida por defecto, 4.0.4): https://gitlab.com/procps-ng/procps/-/blob/master/NEWS
- `iproute2` (`ip`, `ss`, `nstat`, `tc`): https://wiki.linuxfoundation.org/networking/iproute2
- `ss(8)`: https://man7.org/linux/man-pages/man8/ss.8.html
- `ip(8)`: https://man7.org/linux/man-pages/man8/ip.8.html
- `tc(8)`: https://man7.org/linux/man-pages/man8/tc.8.html
- `iostat(1)`: https://man7.org/linux/man-pages/man1/iostat.1.html
- `mpstat(1)`: https://man7.org/linux/man-pages/man1/mpstat.1.html
- `pidstat(1)`: https://man7.org/linux/man-pages/man1/pidstat.1.html
- `sar(1)`: https://man7.org/linux/man-pages/man1/sar.1.html
- `sadf(1)`: https://man7.org/linux/man-pages/man1/sadf.1.html
- `vmstat(8)`: https://man7.org/linux/man-pages/man8/vmstat.8.html
- `top(1)`: https://man7.org/linux/man-pages/man1/top.1.html
- `ps(1)`: https://man7.org/linux/man-pages/man1/ps.1.html
- `pstree(1)`: https://man7.org/linux/man-pages/man1/pstree.1.html
- `uptime(1)`: https://man7.org/linux/man-pages/man1/uptime.1.html
- `w(1)`: https://man7.org/linux/man-pages/man1/w.1.html
- `lsof(8)`: https://man7.org/linux/man-pages/man8/lsof.8.html
- `netstat(8)`: https://man7.org/linux/man-pages/man8/netstat.8.html
- Proyecto `iotop`: https://github.com/Tomas-M/iotop
- Proyecto `iptraf-ng`: https://github.com/iptraf-ng/iptraf-ng
- `ethtool`: https://man7.org/linux/man-pages/man8/ethtool.8.html
- Documentación de `fio`: https://fio.readthedocs.io/en/latest/fio_doc.html
- Documentación de `iperf3`: https://software.es.net/iperf/
- Herramientas `bcc` (`biolatency`, `biosnoop`, `tcplife`, `tcpretrans`): https://github.com/iovisor/bcc
- `bpftrace`: https://github.com/bpftrace/bpftrace
- Wiki de `perf`: https://perfwiki.github.io/main/
- Wiki de `nftables` (counters, sets, maps, flowtables, `notrack`): https://wiki.nftables.org/wiki-nftables/index.php/Main_Page
- `conntrack-tools`: https://conntrack-tools.netfilter.org/manual.html
- Proyecto netfilter: https://www.netfilter.org/documentation/

**Control de recursos y medición en systemd**

- `systemd.resource-control(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html
- `systemd-cgtop(1)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-cgtop.html
- `systemd.slice(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.slice.html
- `systemd.timer(5)` (para el override de `sysstat-collect.timer`): https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html

**Stack de monitoreo usado en los manifiestos**

- `node_exporter` de Prometheus (lista de collectors, collector de PSI): https://github.com/prometheus/node_exporter
- Reglas de recording y alerting de Prometheus: https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/ y https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Módulo `ansible.posix.sysctl` de Ansible: https://docs.ansible.com/ansible/latest/collections/ansible/posix/sysctl_module.html
- Módulo `ansible.builtin.systemd_service` de Ansible: https://docs.ansible.com/ansible/latest/collections/ansible/builtin/systemd_service_module.html