# LPIC-2 · Topic 200.1 — Medir y diagnosticar el uso de recursos
## Ejercicios guiados (peso LPI 6 · examen 201-450, versión de los objetivos 4.5.0)

> **Lo que este tema realmente te exige.** No "nombrar una herramienta", sino: dada una máquina que está *lenta*, decidir **cuál de los cuatro recursos** (CPU, memoria, I/O de disco, I/O de red) está saturado, **probarlo con un número**, **atribuirlo a un proceso o a un cliente** y **estimar si ese número está cerca del techo del hardware**. Todos los ejercicios de abajo terminan en un número que podés defender.
>
> La lista parcial de archivos, términos y utilidades de LPI para este objetivo es, textual: `iostat`, `iotop`, `vmstat`, `netstat`, `ss`, `iptraf`, `pstree`, `ps`, `w`, `lsof`, `top`, `htop`, `uptime`, `sar`, swap, processes blocked on I/O, blocks in, blocks out. Confirmá la lista actual en la página oficial de objetivos — LPI la revisa: <https://www.lpi.org/our-certifications/exam-201-objectives/>. Los ejercicios agregan los equivalentes modernos que se espera que un ingeniero de producción use (`mpstat`, `pidstat`, `nstat`, `nft`, PSI, cgroup v2), porque en un incidente real te van a juzgar por el diagnóstico, no por la antigüedad de la herramienta.

### Requisitos del laboratorio

- Una **VM o host de contenedores descartable** con `sudo`. Varios pasos cargan la máquina a propósito, escriben sysctls e instalan reglas de firewall. No hagas esto en nada que te importe.
- Kernel 5.x/6.x, `systemd`, cgroup v2 (`stat -fc %T /sys/fs/cgroup` → `cgroup2fs`).
- Paquetes: `sysstat procps iproute2 util-linux lsof psmisc stress-ng fio iperf3 nftables conntrack iotop iftop nethogs iptraf-ng jq bc gawk ethtool`.
- Dos terminales lado a lado (una genera carga, la otra mide). Una tercera ayuda.

### Cómo usarlo

Ejecutá los pasos numerados en orden dentro de un laboratorio. Después de cada bloque respondé las preguntas de **Checkpoint** *antes* de seguir leyendo — las respuestas están en la sección colapsable del final. Los números de las salidas de ejemplo vienen de una máquina de laboratorio particular; los tuyos van a diferir, las *relaciones* entre ellos no.

---

## Lab 0 — Línea base, y el método

Medir sin línea base produce opiniones. Este lab son cinco minutos de trabajo que hacen interpretable todo el resto.

1. Instalá el toolchain y confirmá el tick del reloj, la unidad en la que está denominado cada contador de `/proc` de este tema:

```bash
sudo apt-get install -y sysstat procps iproute2 util-linux lsof psmisc \
  stress-ng fio iperf3 nftables conntrack iotop iftop nethogs iptraf-ng jq bc gawk ethtool
getconf CLK_TCK
nproc
```

```
100
8
```

2. Tomá una foto de línea base en un archivo contra el que puedas comparar después. Fijate que a cada herramienta se le piden *dos* muestras, así la segunda es una medición de intervalo y no un promedio desde el arranque:

```bash
ts=$(date +%Y%m%dT%H%M%S); out=~/baseline-$ts.txt
{
  echo "=== uptime ==="      ; uptime
  echo "=== w ==="           ; w
  echo "=== vmstat 1 2 ===" ; vmstat 1 2
  echo "=== mpstat 1 2 ===" ; mpstat -P ALL 1 2
  echo "=== free -w ==="     ; free -w
  echo "=== iostat -x 1 2 ===" ; iostat -xz 1 2
  echo "=== sar -n DEV 1 2 ===" ; sar -n DEV 1 2
  echo "=== ss -s ==="       ; ss -s
  echo "=== psi ==="         ; grep . /proc/pressure/*
} | tee "$out" >/dev/null
echo "$out"
```

3. Mirá las dos fuentes del load average y quién está logueado:

```bash
cat /proc/loadavg
uptime
w
```

```
0.52 0.61 0.58 2/412 31844
 12:03:58 up 4 days,  2:11,  2 users,  load average: 0.52, 0.61, 0.58
USER     TTY      FROM             LOGIN@   IDLE   JCPU   PCPU WHAT
root     pts/0    10.0.0.5         11:58    0.00s  0.03s  0.00s w
deploy   pts/1    10.0.0.9         09:12   2:41m  1:12   1:12  ./report.sh
```

4. Identificá la forma del árbol de procesos que estás por perturbar:

```bash
pstree -ap | head -20
ps -eo pid,ppid,stat,pcpu,pmem,rss,wchan:16,comm --sort=-pcpu | head -10
```

**Checkpoint — Q1–Q3**

- **Q1.** `/proc/loadavg` muestra `0.52 0.61 0.58 2/412 31844`. ¿Qué son exactamente los últimos dos campos, y qué cuentan los primeros tres específicamente en Linux (la respuesta difiere del UNIX clásico)?
- **Q2.** `w` muestra `JCPU 1:12` y `PCPU 1:12` para `deploy`. ¿Cuál es la diferencia entre esas dos columnas, y por qué `IDLE 2:41m` no es evidencia de que el usuario no esté consumiendo nada?
- **Q3.** ¿Por qué el paso 2 le pide a cada herramienta **dos** muestras con un intervalo de un segundo en vez de una?

---

## Lab 1 — CPU: de la aritmética de `/proc/stat` al thread culpable

### 1A — Calculá la utilización a mano, después verificá una herramienta contra eso

1. Leé la línea agregada de CPU y las líneas por CPU:

```bash
grep -E '^cpu' /proc/stat | head -3
```

```
cpu  4812344 11204 1398221 884213996 412884 0 88412 0 0 0
cpu0 601122 1402 174883 110512441 51214 0 12044 0 0 0
cpu1 598412 1388 173994 110538112 50882 0 11388 0 0 0
```

Los diez campos que siguen a la etiqueta son, en orden: `user nice system idle iowait irq softirq steal guest guest_nice`, cada uno en unidades de `1/CLK_TCK` segundos.

2. Escribí la calculadora. Leé el comentario sobre qué campos se suman — esa elección es toda la lección:

```bash
cat > ~/cpu-util.sh <<'EOF'
#!/bin/bash
# cpu-util.sh [interval] -- CPU utilisation from two /proc/stat samples.
# total = fields 2..9 (user..steal) ONLY: guest/guest_nice are already
# included inside user/nice by the kernel, so adding them double-counts.
snap() { awk '/^cpu /{ idle=$5+$6; total=0; for (i=2;i<=9;i++) total+=$i;
                       print idle, total }' /proc/stat; }
iv=${1:-1}
read -r i1 t1 < <(snap); sleep "$iv"; read -r i2 t2 < <(snap)
awk -v i1="$i1" -v t1="$t1" -v i2="$i2" -v t2="$t2" -v iv="$iv" 'BEGIN{
  dt=t2-t1; di=i2-i1;
  printf "interval=%ss  ticks=%d  busy=%.2f%%  idle+iowait=%.2f%%\n",
         iv, dt, 100*(dt-di)/dt, 100*di/dt }'
EOF
chmod +x ~/cpu-util.sh
~/cpu-util.sh 5
```

```
interval=5s  ticks=4000  busy=7.35%  idle+iowait=92.65%
```

3. Verificá la contabilidad de ticks: con `CLK_TCK=100` y 8 CPUs, un intervalo de 5 segundos debe dar ≈ `5 × 100 × 8 = 4000` ticks sumando todos los campos. Confirmá que los `ticks` impresos coinciden.

4. Ahora cargá exactamente una CPU y compará tu script con `mpstat`:

```bash
# terminal 1
stress-ng --cpu 1 --cpu-method matrixprod --timeout 60s
```

```bash
# terminal 2
~/cpu-util.sh 5
mpstat -P ALL 1 3
```

```
12:14:11     CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle
12:14:12     all   12.52    0.00    0.38    0.00    0.00    0.12    0.00    0.00    0.00   86.98
12:14:12       0   99.01    0.00    0.99    0.00    0.00    0.00    0.00    0.00    0.00    0.00
12:14:12       1    0.00    0.00    1.01    0.00    0.00    0.00    0.00    0.00    0.00   98.99
```

**Checkpoint — Q4–Q7**

- **Q4.** Una CPU está clavada al 100% pero `all` marca `%usr 12.52`. Calculá 100/8 y explicá por qué la línea agregada es el número más peligroso de una máquina multicore.
- **Q5.** Convertí el campo `user` de la primera salida de `/proc/stat` (`4812344`) a segundos, y después a CPU-horas. ¿Qué comando te dio el factor de conversión?
- **Q6.** ¿Por qué el script suma sólo los campos 2–9? ¿Qué estaría mal específicamente en el resultado, en un host KVM corriendo guests, si sumaras los diez?
- **Q7.** Un colega calcula la utilización como `100 - %idle`. ¿En qué tipo de carga eso sobreestima la demanda de CPU, y qué campo es el responsable?

### 1B — `%iowait`, `%steal` y los dos tipos de "no está corriendo"

1. Generá espera de I/O pura sin trabajo de CPU, y observá:

```bash
# terminal 1 -- synchronous reads straight from the device, no page cache
sudo dd if=/dev/sda of=/dev/null bs=4k count=200000 iflag=direct
```

```bash
# terminal 2
mpstat -P ALL 1 5
vmstat 1 5
```

```
procs -----------memory---------- ---swap-- -----io---- -system-- -------cpu-------
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st gu
 0  1      0 241664  85320 5120228    0    0 38124     0 1844 3122  1  3 71 25  0  0
 0  1      0 241664  85320 5120228    0    0 39012     0 1902 3188  1  3 70 26  0  0
```

2. Fijate en la columna `b` (procesos bloqueados en I/O no interrumpible) y en que `wa` está alto mientras `us`+`sy` se mantienen cerca de cero.

3. Compará la cola de ejecución con el load average bajo carga de *CPU* versus bajo carga de *I/O*:

```bash
stress-ng --cpu 4 --timeout 30s &
sleep 20; cat /proc/loadavg; vmstat 1 3 | tail -2; wait
```

4. Encontrá los procesos en sueño no interrumpible y en qué están bloqueados:

```bash
ps -eo pid,stat,wchan:24,comm | awk 'NR==1 || $2 ~ /^D/'
sudo cat /proc/$(pgrep -n dd)/stack 2>/dev/null | head
```

```
    PID STAT WCHAN                    COMMAND
  31902 D+   blk_mq_get_tag           dd
```

5. En una máquina virtual, revisá el tiempo robado — el hipervisor corriendo a otro en tu vCPU:

```bash
mpstat -P ALL 1 3 | awk '{print $2, $NF, $(NF-3)}' | head
grep -c . /proc/pressure/cpu && cat /proc/pressure/cpu
```

### 1C — Pressure Stall Information: saturación, no utilización

1. Leé los archivos de PSI. Los valores son porcentajes de tiempo de reloj sobre ventanas decayentes de 10/60/300 segundos; `total` es microsegundos acumulados:

```bash
grep . /proc/pressure/*
```

```
/proc/pressure/cpu:some avg10=0.00 avg60=0.12 avg300=0.08 total=18412334
/proc/pressure/io:some avg10=0.00 avg60=0.04 avg300=0.02 total=9122841
/proc/pressure/io:full avg10=0.00 avg60=0.01 avg300=0.01 total=4011223
/proc/pressure/memory:some avg10=0.00 avg60=0.00 avg300=0.00 total=0
/proc/pressure/memory:full avg10=0.00 avg60=0.00 avg300=0.00 total=0
```

2. Sobresuscribí las CPUs 4× y mirá cómo `cpu some` trepa mientras `%idle` queda en cero tanto en el caso sano como en el sobrecargado:

```bash
stress-ng --cpu $(( $(nproc) * 4 )) --timeout 30s &
for i in $(seq 6); do sleep 5; echo -n "$(date +%T) "; cat /proc/pressure/cpu | head -1; done
wait
```

```
12:22:04 some avg10=71.44 avg60=22.18 avg300=4.91 total=41223884
12:22:09 some avg10=88.02 avg60=36.44 avg300=8.12 total=45812990
```

3. Atribuilo. `top -H` y `pidstat -t` trabajan con granularidad de thread, que la vista por proceso por defecto de `ps` esconde:

```bash
pidstat -u -t 1 3 | head -20
top -b -H -n 1 -o %CPU | head -15
```

**Checkpoint — Q8–Q13**

- **Q8.** `vmstat` muestra `r 0`, `b 1`, `wa 25`, `us 1`. ¿Es la CPU el cuello de botella? ¿Cuál *es* el cuello de botella, y qué única columna de `vmstat` es la pista más fuerte sobre qué dispositivo mirar después?
- **Q9.** Con `stress-ng --cpu 4` el load average converge cerca de 4.00. Con la corrida de `dd iflag=direct`, el load average también sube aunque la CPU está idle. Explicá mecánicamente por qué, y nombrá el estado de proceso involucrado.
- **Q10.** `WCHAN` dice `blk_mq_get_tag`. ¿En qué capa está bloqueado el proceso, y qué te dice eso sobre la profundidad de cola de ese dispositivo?
- **Q11.** `%steal` está en 18% sostenido en una instancia de nube. ¿Qué tres remediaciones tenés disponibles como administrador del *guest*, y cuál no (y por qué)?
- **Q12.** Explicá la diferencia entre `cpu some` y el (inexistente) `cpu full`. ¿Por qué el kernel publica `full` para `io` y `memory` pero no para `cpu`?
- **Q13.** La utilización es 100% en dos incidentes distintos; en uno, PSI `cpu some avg10` es 2%, en el otro es 85%. ¿Cuál es sano, y qué palabra distingue las dos condiciones?

---

## Lab 2 — Memoria: free, available, cached, y quién posee realmente una página

### 2A — Reconciliá `free` con `/proc/meminfo` exactamente

1. Capturá ambos en el mismo momento:

```bash
free -w; echo; grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapCached|Dirty|Writeback|AnonPages|Mapped|Shmem|Slab|SReclaimable|SUnreclaim|SwapTotal|SwapFree|CommitLimit|Committed_AS):' /proc/meminfo
```

```
               total        used        free      shared     buffers       cache   available
Mem:        16037324     2142056      241664      412332       85320    13568284    13093116
Swap:        4194300       12288     4182012

MemTotal:       16037324 kB
MemFree:          241664 kB
MemAvailable:   13093116 kB
Buffers:           85320 kB
Cached:         13211952 kB
SwapCached:         4096 kB
Dirty:            412664 kB
Writeback:          8192 kB
AnonPages:       1944312 kB
Mapped:           612480 kB
Shmem:            412332 kB
Slab:             498132 kB
SReclaimable:     356332 kB
SUnreclaim:       141800 kB
SwapTotal:        4194300 kB
SwapFree:         4182012 kB
CommitLimit:    12212960 kB
Committed_AS:    6421884 kB
```

2. Derivá vos mismo las columnas de `free`, con `bc`:

```bash
awk '/^(MemTotal|MemFree|Buffers|Cached|SReclaimable|Shmem):/{gsub(":","");m[$1]=$2}
     END{ cache=m["Cached"]+m["SReclaimable"];
          used=m["MemTotal"]-m["MemFree"]-m["Buffers"]-cache;
          printf "derived cache  = %d kB\nderived used   = %d kB\nderived shared = %d kB\n",
                 cache, used, m["Shmem"] }' /proc/meminfo
```

```
derived cache  = 13568284 kB
derived used   = 2142056 kB
derived shared = 412332 kB
```

3. Compará `free + buffers + cache` contra `MemAvailable` y cuantificá la diferencia:

```bash
awk '/^(MemFree|Buffers|Cached|SReclaimable|MemAvailable|Shmem):/{gsub(":","");m[$1]=$2}
     END{ naive=m["MemFree"]+m["Buffers"]+m["Cached"]+m["SReclaimable"];
          printf "naive free-ish = %d kB\nMemAvailable   = %d kB\ngap            = %d kB (Shmem=%d)\n",
                 naive, m["MemAvailable"], naive-m["MemAvailable"], m["Shmem"] }' /proc/meminfo
```

```
naive free-ish = 13895268 kB
MemAvailable   = 13093116 kB
gap            = 802152 kB (Shmem=412332)
```

**Checkpoint — Q14–Q17**

- **Q14.** Escribí la identidad que satisface `free -w`, e indicá qué campo de `/proc/meminfo` pliega `free` dentro de su columna `cache` además de `Cached`. ¿Por qué se incluye ese campo?
- **Q15.** `MemAvailable` está 802 MB *por debajo* de `free + buffers + cache`. Nombrá dos categorías distintas de memoria que se cuentan en `Cached` o en las listas LRU pero no pueden entregarse a una asignación nueva.
- **Q16.** `Dirty` es 412 MB. ¿Qué le pasa a `MemAvailable` si ese número es en cambio 6 GB, y qué síntoma de latencia predice un `Dirty` grande?
- **Q17.** `CommitLimit` es 12.2 GB mientras `MemTotal` es 15.3 GB. ¿Qué par de sysctls produjo ese número, y qué significa operativamente `Committed_AS 6.4 GB` — es memoria en uso?

### 2B — La page cache no es una fuga

1. Observá cómo se llena la cache y el hecho de que es memoria libre disfrazada:

```bash
free -w | awk 'NR==2'
dd if=/dev/zero of=/var/tmp/cachefill bs=1M count=2048 oflag=sync status=none
free -w | awk 'NR==2'
grep -E '^(Dirty|Writeback):' /proc/meminfo
```

2. Leé el archivo de vuelta para poblar la cache, después probá que es reclamable sin matar nada:

```bash
cat /var/tmp/cachefill > /dev/null
free -w | awk 'NR==2'
sync; sudo sh -c 'echo 1 > /proc/sys/vm/drop_caches'   # lab only, never in production
free -w | awk 'NR==2'
```

3. Medí el efecto de la cache, que es la única razón por la que existe:

```bash
sync; sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
time cat /var/tmp/cachefill > /dev/null     # cold
time cat /var/tmp/cachefill > /dev/null     # warm
```

```
real	0m8.412s     # cold
real	0m0.372s     # warm
```

### 2C — Memoria por proceso: RSS miente, PSS no

1. Compará las tres vistas de la huella de un proceso:

```bash
pid=$(pgrep -n -f sshd || pgrep -n bash)
ps -o pid,vsz,rss,comm -p "$pid"
sudo pmap -x "$pid" | tail -3
sudo cat /proc/"$pid"/smaps_rollup
```

```
    PID    VSZ   RSS COMMAND
   1844  17204  9612 sshd

total kB           17204    9612    1120

Rss:                9612 kB
Pss:                3284 kB
Shared_Clean:       6912 kB
Shared_Dirty:          0 kB
Private_Clean:       416 kB
Private_Dirty:      2284 kB
Swap:                  0 kB
```

2. Sumá el RSS de todos los procesos y compará con la memoria usada físicamente — la suma la va a exceder:

```bash
ps -eo rss= | awk '{s+=$1} END{printf "sum(RSS) = %d kB\n", s}'
awk '/^(MemTotal|MemFree|Buffers|Cached|SReclaimable):/{gsub(":","");m[$1]=$2}
     END{printf "used     = %d kB\n", m["MemTotal"]-m["MemFree"]-m["Buffers"]-m["Cached"]-m["SReclaimable"]}' /proc/meminfo
```

3. Ordená por PSS en cambio, que sí es aditivo:

```bash
for p in $(ps -eo pid=); do
  v=$(sudo awk '/^Pss:/{print $2}' /proc/$p/smaps_rollup 2>/dev/null) || continue
  [ -n "$v" ] && echo "$v $p $(cat /proc/$p/comm 2>/dev/null)"
done | sort -nr | head -8
```

4. Averiguá qué tiene abierto un proceso, lo que frecuentemente explica tanto su RSS como su I/O:

```bash
sudo lsof -p "$pid" | head
sudo lsof +L1 | head        # deleted files still held open: invisible disk usage
sudo fuser -vm /var/tmp 2>&1 | head
```

**Checkpoint — Q18–Q21**

- **Q18.** `sum(RSS)` sobre todos los procesos es más grande que la memoria realmente usada. Dá el mecanismo, y nombrá el campo de `smaps_rollup` que arregla la aritmética.
- **Q19.** Para `sshd`: `VSZ 17204`, `RSS 9612`, `Pss 3284`. Explicá cada uno, y decí sobre cuál alertarías en una flota de 500 procesos de workers forkeados.
- **Q20.** Después de `echo 1 > drop_caches` la columna `cache` baja pero `free` sube un poco menos que la caída. ¿Dónde fue la diferencia? ¿Y qué suelta `echo 3` que `echo 1` no?
- **Q21.** `lsof +L1` reporta un archivo de 40 GB con link count 0. ¿Qué herramienta reportó el espacio como usado, cuál lo reportó como libre, y cuál es el arreglo que *no* implica un reboot?

### 2D — Swap, thrashing, y dos OOM kills diferentes

1. Distinguí "hay swap usado" de "el sistema está swappeando":

```bash
free -w | awk 'NR==3'
vmstat 1 5 | awk 'NR<3 || 1'
cat /proc/vmstat | grep -E '^(pswpin|pswpout|pgmajfault|pgfault)'
cat /proc/sys/vm/swappiness
```

2. Forzá tráfico de swap real y mirá cómo `si`/`so` se vuelven distintos de cero (esto va a poner la máquina brevemente desagradable — es el punto):

```bash
stress-ng --vm 2 --vm-bytes 80% --vm-keep --timeout 45s &
vmstat 1 10
wait
```

```
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st gu
 3  2 1884412  98124   4120  212884 48124 71220  912  2104 8412 24188  8 31  9 52  0  0
```

3. Ahora limitá una carga con cgroup v2 en cambio, y leé los contadores propios del cgroup — así se ven en realidad los incidentes de memoria en contenedores:

```bash
sudo systemd-run --unit=memlab --scope -p MemoryMax=256M -p MemorySwapMax=0 \
  stress-ng --vm 1 --vm-bytes 1G --vm-keep --timeout 30s
```

```bash
# in another terminal, while it runs
cg=/sys/fs/cgroup/system.slice/memlab.scope
grep . $cg/memory.current $cg/memory.max $cg/memory.events $cg/memory.pressure
grep -E '^(pgmajfault|pgscan|pgsteal)' $cg/memory.stat
```

```
/sys/fs/cgroup/system.slice/memlab.scope/memory.current:268435456
/sys/fs/cgroup/system.slice/memlab.scope/memory.max:268435456
/sys/fs/cgroup/system.slice/memlab.scope/memory.events:low 0
/sys/fs/cgroup/system.slice/memlab.scope/memory.events:high 0
/sys/fs/cgroup/system.slice/memlab.scope/memory.events:max 184122
/sys/fs/cgroup/system.slice/memlab.scope/memory.events:oom 3
/sys/fs/cgroup/system.slice/memlab.scope/memory.events:oom_kill 1
/sys/fs/cgroup/system.slice/memlab.scope/memory.pressure:some avg10=94.12 avg60=41.08 avg300=8.44 total=28412991
```

4. Leé el registro del kill:

```bash
sudo dmesg -T | grep -iE 'oom|killed process' | tail -5
journalctl -k --since '-5 min' | grep -i oom | tail -5
```

```
[Wed Oct 15 12:41:02 2026] stress-ng-vm invoked oom-killer: gfp_mask=0xcc0(GFP_KERNEL), order=0, oom_score_adj=0
[Wed Oct 15 12:41:02 2026] memory: usage 262144kB, limit 262144kB, failcnt 184122
[Wed Oct 15 12:41:02 2026] Memory cgroup out of memory: Killed process 32114 (stress-ng-vm) total-vm:1061320kB, anon-rss:252884kB, file-rss:1280kB
```

**Checkpoint — Q22–Q25**

- **Q22.** `swpd` es 1.8 GB pero `si` y `so` vienen en `0` desde hace una hora. ¿Hay un problema de memoria? ¿Qué dos contadores, y qué línea de PSI, deciden la cuestión?
- **Q23.** Distinguí un fallo menor de un fallo mayor, y decí qué contador de `/proc/vmstat` sigue a cada uno. ¿Cuál es el que cuesta milisegundos?
- **Q24.** La línea de `dmesg` dice **"Memory cgroup out of memory"**, y `MemAvailable` en el host era 13 GB en ese momento. Explicá cómo ambas cosas son verdaderas, y qué número tenés que mirar para dimensionar el arreglo.
- **Q25.** `memory.events` muestra `max 184122` y `oom_kill 1`. ¿Cuál es la diferencia operativa entre esos dos contadores, y cuál indica un límite demasiado bajo pero que todavía *funciona*?

---

## Lab 3 — I/O de disco: `/proc/diskstats`, la ley de Little, y quién está escribiendo

### 3A — Decodificá `/proc/diskstats` y reconstruí `iostat`

1. Encontrá tu dispositivo y leé sus contadores crudos:

```bash
lsblk -d -o NAME,ROTA,SIZE,MODEL
dev=$(lsblk -dno NAME | head -1); echo "dev=$dev"
awk -v d="$dev" '$3==d' /proc/diskstats
```

```
NAME    ROTA   SIZE MODEL
nvme0n1    0 476.9G SAMSUNG MZVLB512HBJQ

 259       0 nvme0n1 2841223 118412 284122334 412884 1884112 221884 198412008 884122 0 1124882 1988004 0 0 0 0 11244 28412
```

Los campos después del nombre del dispositivo: 1 lecturas completadas · 2 lecturas fusionadas · 3 **sectores** leídos · 4 ms leyendo · 5 escrituras completadas · 6 escrituras fusionadas · 7 **sectores** escritos · 8 ms escribiendo · 9 I/Os en vuelo · 10 ms haciendo I/Os · 11 ms ponderados haciendo I/Os · (12–15 discards, 16–17 flushes en kernels más nuevos).

2. Construí tu propio `iostat`:

```bash
cat > ~/disk-delta.sh <<'EOF'
#!/bin/bash
# disk-delta.sh <device> [interval] -- rebuild iostat -x from /proc/diskstats.
# diskstats sectors are ALWAYS 512 B, regardless of the device's logical block size.
dev=${1:?usage: disk-delta.sh <device> [interval]}; iv=${2:-5}
snap() { awk -v d="$dev" '$3==d {print $4, $6, $7, $8, $10, $11, $13, $14}' /proc/diskstats; }
read -r r1 sr1 tr1 w1 sw1 tw1 t1 wt1 < <(snap); sleep "$iv"
read -r r2 sr2 tr2 w2 sw2 tw2 t2 wt2 < <(snap)
awk -v iv="$iv" -v r=$((r2-r1)) -v sr=$((sr2-sr1)) -v tr=$((tr2-tr1)) \
    -v w=$((w2-w1)) -v sw=$((sw2-sw1)) -v tw=$((tw2-tw1)) \
    -v t=$((t2-t1)) -v wt=$((wt2-wt1)) 'BEGIN{
  printf "r/s=%.1f  rkB/s=%.1f  r_await=%.2fms\n", r/iv, sr*512/1024/iv, (r?tr/r:0);
  printf "w/s=%.1f  wkB/s=%.1f  w_await=%.2fms\n", w/iv, sw*512/1024/iv, (w?tw/w:0);
  printf "aqu-sz=%.2f  %%util=%.1f\n", wt/(iv*1000), 100*t/(iv*1000);
  printf "little's law check: (r/s+w/s)*await/1000 = %.2f\n",
         ((r+w)/iv) * ((r+w) ? (tr+tw)/(r+w) : 0) / 1000 }'
EOF
chmod +x ~/disk-delta.sh
```

3. Aplicá una carga conocida y controlada y corré las dos herramientas contra ella:

```bash
# terminal 1 -- 4 KiB random reads, O_DIRECT, queue depth 32
fio --name=rr --filename=/var/tmp/fio.dat --size=2G --rw=randread --bs=4k \
    --ioengine=libaio --iodepth=32 --direct=1 --time_based --runtime=60 \
    --group_reporting
```

```bash
# terminal 2
~/disk-delta.sh "$dev" 5
iostat -xz 5 2
```

```
Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   w_await  aqu-sz  %util
nvme0n1       8123.00  32492.00     0.00   0.00    3.84     4.00    0.00      0.00      0.00   31.19   99.80
```

```
r/s=8121.4  rkB/s=32485.6  r_await=3.84ms
w/s=0.0  wkB/s=0.0  w_await=0.00ms
aqu-sz=31.19  %util=99.8
little's law check: (r/s+w/s)*await/1000 = 31.19
```

**Checkpoint — Q26–Q30**

- **Q26.** Verificá la ley de Little con los números de arriba: calculá `(r/s) × r_await / 1000` y compará con `aqu-sz`. Enunciá la ley en palabras, y decí qué es físicamente `aqu-sz`.
- **Q27.** `%util` es 99.8% en un dispositivo NVMe que está entregando 8 100 IOPS a 3.84 ms. El mismo dispositivo da 400 000 IOPS en benchmark. Explicá con precisión qué mide `%util` y por qué es casi inútil como señal de saturación en dispositivos multi-queue — y qué columna lo reemplaza.
- **Q28.** `rareq-sz` es exactamente `4.00` y `rrqm/s` es `0.00`. ¿Qué te dicen esos dos juntos sobre la carga, y qué habría significado un `rrqm/s` de 800/s?
- **Q29.** Tu `disk-delta.sh` multiplica los sectores por 512 incluso en un disco 4 Kn con un tamaño de bloque lógico de 4096 bytes. ¿Por qué eso es correcto?
- **Q30.** Los `iostat` viejos imprimían `svctm` y `avgqu-sz`; el sysstat actual imprime `aqu-sz` y ningún `svctm`. ¿Por qué se sacó `svctm`, y qué error alentaba?

### 3B — La page cache cambia la respuesta

1. Corré la misma cantidad de trabajo dos veces, con y sin `O_DIRECT`, y mirá dónde van los bytes:

```bash
fio --name=sw --filename=/var/tmp/fio2.dat --size=1G --rw=write --bs=1M \
    --ioengine=psync --direct=1 --end_fsync=1 --group_reporting | grep -E 'WRITE|IOPS'
grep -E '^(Dirty|Writeback):' /proc/meminfo

fio --name=sw --filename=/var/tmp/fio3.dat --size=1G --rw=write --bs=1M \
    --ioengine=psync --direct=0 --group_reporting | grep -E 'WRITE|IOPS'
grep -E '^(Dirty|Writeback):' /proc/meminfo
```

2. Mirá a los umbrales de writeback hacer su trabajo:

```bash
sysctl vm.dirty_ratio vm.dirty_background_ratio vm.dirty_expire_centisecs vm.dirty_writeback_centisecs
( dd if=/dev/zero of=/var/tmp/big bs=1M count=4096 conv=notrunc status=none & \
  for i in $(seq 12); do grep -E '^(Dirty|Writeback|NFS_Unstable):' /proc/meminfo | tr '\n' ' '; echo; sleep 1; done )
time sync
```

```
vm.dirty_ratio = 20
vm.dirty_background_ratio = 10
Dirty: 412664 kB Writeback: 0 kB
Dirty: 1284112 kB Writeback: 118412 kB
Dirty: 1601248 kB Writeback: 412884 kB
...
real	0m6.214s
```

### 3C — Atribuí el I/O a un proceso

1. I/O de bloques por proceso, de tres maneras:

```bash
sudo iotop -b -o -n 3 -d 2 | head -20
pidstat -d 2 3
sudo cat /proc/$(pgrep -n fio)/io
```

```
Total DISK READ:        31.72 M/s | Total DISK WRITE:         0.00 B/s
    TID  PRIO  USER     DISK READ  DISK WRITE  COMMAND
  33114 be/4 root       31.72 M/s    0.00 B/s fio --name=rr ...
```

```
rchar: 2142338560
wchar: 0
syscr: 522543
syscw: 0
read_bytes: 2141847552
write_bytes: 0
cancelled_write_bytes: 0
```

2. Encontrá qué archivos se están golpeando:

```bash
sudo lsof -p $(pgrep -n fio)
sudo lsof /var/tmp
sudo fuser -vm /var/tmp
```

**Checkpoint — Q31–Q34**

- **Q31.** En `/proc/<pid>/io`, `rchar` es 2 142 338 560 y `read_bytes` es 2 141 847 552. Definí ambos. ¿Bajo qué carga `rchar` sería enorme y `read_bytes` cero?
- **Q32.** `cancelled_write_bytes` es distinto de cero para un proceso. ¿Qué pasó?
- **Q33.** `iotop` corrido como usuario normal imprime un error sobre soporte faltante del kernel. ¿Qué opción de configuración del kernel y qué privilegio requiere, y cuál de las tres herramientas del paso 1 no necesita ninguno de los dos?
- **Q34.** Un trabajo nocturno hace que toda la máquina se cuelgue 4 segundos cada 30 segundos, y `iostat` muestra picos de `w_await` de 2 000 ms con `wkB/s` cerca de cero en el medio. ¿Qué dos sysctls examinarías primero, y cuál es el mecanismo?

---

## Lab 4 — I/O de red: contadores, estado por conexión, y el techo

### 4A — Contadores de interfaz, a mano y con herramienta

1. Leé `/proc/net/dev` y construí la herramienta de delta:

```bash
IF=$(ip -o -4 route show default | awk '{print $5; exit}'); echo "IF=$IF"
sed 's/:/ /' /proc/net/dev | awk 'NR<3 || $1=="'"$IF"'"'
```

```
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
 ens18 884122334 1284112    0   12    0     0          0    88412 412884221  984112    0    0    0     0       0          0
```

```bash
cat > ~/net-delta.sh <<'EOF'
#!/bin/bash
# net-delta.sh <iface> [interval]
i=${1:?usage: net-delta.sh <iface> [interval]}; iv=${2:-5}
snap() { sed 's/:/ /' /proc/net/dev | awk -v i="$i" '$1==i {print $2, $3, $5, $10, $11, $13}'; }
read -r rb1 rp1 rd1 tb1 tp1 td1 < <(snap); sleep "$iv"
read -r rb2 rp2 rd2 tb2 tp2 td2 < <(snap)
awk -v iv="$iv" -v rb=$((rb2-rb1)) -v rp=$((rp2-rp1)) -v rd=$((rd2-rd1)) \
    -v tb=$((tb2-tb1)) -v tp=$((tp2-tp1)) -v td=$((td2-td1)) 'BEGIN{
  printf "rx %.2f Mbit/s  %.0f pps  avg %.0f B/pkt  drops %d\n", rb*8/1e6/iv, rp/iv, (rp?rb/rp:0), rd;
  printf "tx %.2f Mbit/s  %.0f pps  avg %.0f B/pkt  drops %d\n", tb*8/1e6/iv, tp/iv, (tp?tb/tp:0), td }'
EOF
chmod +x ~/net-delta.sh
```

2. Cruzá contra las herramientas del objetivo y sus reemplazos modernos:

```bash
sar -n DEV 1 3 | grep -E "IFACE|$IF"
netstat -i        # legacy; note the columns
ip -s link show "$IF"
~/net-delta.sh "$IF" 5
```

```
12:51:02        IFACE   rxpck/s   txpck/s    rxkB/s    txkB/s   rxcmp/s   txcmp/s  rxmcst/s   %ifutil
12:51:03        ens18   8412.00  12884.00   1021.44  11884.12      0.00      0.00      2.00      9.74
```

3. Resumen a nivel socket y la traducción `netstat` → `ss`:

```bash
ss -s
ss -tuln
ss -tanp state established | head
netstat -s | grep -iE 'segments retransmit|listen|overflow' 
nstat -az | grep -E 'TcpRetransSegs|TcpOutSegs|TcpInSegs|ListenOverflows|ListenDrops|TCPBacklogDrop'
```

```
Total: 412
TCP:   188 (estab 64, closed 98, orphaned 0, timewait 96)
```

### 4B — El techo de una conexión: `ss -ti` y el producto ancho de banda–retardo

1. Arrancá un servidor y una transferencia de 10 segundos:

```bash
# terminal 1
iperf3 -s -1
```

```bash
# terminal 2
iperf3 -c 127.0.0.1 -t 10          # loopback first, to see the no-bottleneck case
```

2. Mientras una transferencia *real* corre a través de una red, inspeccioná las entrañas de la conexión:

```bash
ss -tim dst 10.10.2.2
```

```
ESTAB 0 1196480 10.10.1.2:52244 10.10.2.2:5201
	 cubic wscale:7,7 rto:244 rtt:40.12/0.18 mss:1448 pmtu:1500 advmss:1448
	 cwnd:112 ssthresh:84 bytes_sent:412334592 bytes_acked:411138113
	 segs_out:284812 segs_in:12044 send 32.4Mbps pacing_rate 38.9Mbps
	 delivery_rate 31.8Mbps busy:10012ms retrans:0/18 rcv_space:14480 minrtt:40.02
```

3. Hacé la aritmética que `send 32.4Mbps` está escondiendo:

```bash
# throughput of one TCP flow  ~=  cwnd * mss / rtt
echo "scale=2; 112 * 1448 * 8 / (40.12/1000) / 1000000" | bc
# bandwidth-delay product needed to fill a 1 Gbit/s path at this RTT
echo "scale=2; 1000000000 * (40.12/1000) / 8 / 1024 / 1024" | bc
```

```
32.34
4.78
```

4. Revisá los límites de autotuning del kernel y el estado del window scaling:

```bash
sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.core.rmem_max net.core.wmem_max \
       net.ipv4.tcp_window_scaling net.ipv4.tcp_moderate_rcvbuf
```

5. Separá un límite por flujo de un límite del camino:

```bash
iperf3 -c 10.10.2.2 -t 10          # single stream
iperf3 -c 10.10.2.2 -t 10 -P 8     # eight streams
iperf3 -c 10.10.2.2 -t 10 -R       # reverse direction
iperf3 -c 10.10.2.2 -u -b 900M -t 10   # UDP: offered vs delivered rate, and loss
```

**Checkpoint — Q35–Q39**

- **Q35.** Calculá el BDP para un camino de 1 Gbit/s a 40 ms de RTT (el paso 3 lo hizo en MiB). Después calculá el throughput máximo de una conexión TCP cuyo par anunció una ventana de 64 KiB **sin** window scaling, al mismo RTT. ¿Qué sysctl hace la diferencia, y qué campo de `ss -ti` revela que el scaling está en efecto?
- **Q36.** `retrans:0/18` — explicá los dos números. Después explicá por qué `TcpRetransSegs` de `nstat` puede subir mientras `ss` muestra `retrans:0/0` para cada conexión actual.
- **Q37.** Un solo stream da 32 Mbit/s; ocho streams paralelos dan 240 Mbit/s en el mismo camino. ¿Qué acabás de probar, y qué *no* probaste? ¿Qué medición agregarías?
- **Q38.** `/proc/net/dev` reporta un promedio de 24 000 bytes por paquete recibido en una interfaz con MTU 1500 y sin jumbo frames configurados. ¿Qué feature es responsable, y qué le hace a cualquier presupuesto de paquetes por segundo que calcules a partir de estos contadores? ¿Qué comando de `ethtool` lo confirma?
- **Q39.** `rx drop` está incrementando pero `rx errs` está en cero. ¿Cuál es la diferencia entre esos dos contadores, y dónde mirarías después (nombrá el archivo y un sysctl)?

---

## Lab 5 — Firewalling y throughput de ruteo

Este lab construye una topología real de router de tres nodos dentro de network namespaces, así podés forwardear paquetes, contarlos y saturar el camino de forwarding sin hardware extra.

### 5A — Construí el router

1. Creá la topología `cli (10.10.1.2) ── [rtr] ── srv (10.10.2.2)`:

```bash
sudo ip netns add cli; sudo ip netns add srv; sudo ip netns add rtr
sudo ip link add vc type veth peer name vc-r
sudo ip link add vs type veth peer name vs-r
sudo ip link set vc  netns cli
sudo ip link set vc-r netns rtr
sudo ip link set vs  netns srv
sudo ip link set vs-r netns rtr

sudo ip -n cli addr add 10.10.1.2/24 dev vc
sudo ip -n rtr addr add 10.10.1.1/24 dev vc-r
sudo ip -n srv addr add 10.10.2.2/24 dev vs
sudo ip -n rtr addr add 10.10.2.1/24 dev vs-r

for ns in cli srv rtr; do sudo ip -n $ns link set lo up; done
sudo ip -n cli link set vc up;   sudo ip -n srv link set vs up
sudo ip -n rtr link set vc-r up; sudo ip -n rtr link set vs-r up

sudo ip -n cli route add default via 10.10.1.1
sudo ip -n srv route add default via 10.10.2.1
sudo ip netns exec rtr sysctl -w net.ipv4.ip_forward=1
```

2. Verificá el forwarding antes de medirlo:

```bash
sudo ip netns exec cli ping -c 2 10.10.2.2
sudo ip netns exec rtr ip -s link show vc-r
sudo ip netns exec rtr sysctl net.ipv4.ip_forward
```

3. Hacé que los conteos de paquetes sean significativos apagando los offloads que `veth` habilita por defecto:

```bash
for d in vc-r vs-r; do sudo ip netns exec rtr ethtool -K $d tso off gso off gro off 2>/dev/null; done
sudo ip netns exec cli ethtool -K vc tso off gso off gro off 2>/dev/null
sudo ip netns exec srv ethtool -K vs tso off gso off gro off 2>/dev/null
```

4. Establecé la línea base del throughput de forwarding y el costo de CPU de forwardearlo:

```bash
# terminal 1
sudo ip netns exec srv iperf3 -s -1
```

```bash
# terminal 2
sudo ip netns exec cli iperf3 -c 10.10.2.2 -t 10
```

```bash
# terminal 3 -- where does the time go?
mpstat -P ALL 1 10 | awk 'NR<4 || $3=="all"'
sudo ip netns exec rtr nstat -az | grep -E 'IpForwDatagrams|IpInReceives|IpOutRequests'
```

5. Introducí un cuello de botella conocido y un RTT conocido, después confirmá la cola que se forma:

```bash
sudo ip netns exec rtr tc qdisc add dev vs-r root netem rate 100mbit delay 20ms limit 10000
sudo ip netns exec rtr tc qdisc add dev vc-r root netem rate 100mbit delay 20ms limit 10000
sudo ip netns exec cli ping -c 3 10.10.2.2 | tail -2
sudo ip netns exec srv iperf3 -s -1 &
sudo ip netns exec cli iperf3 -c 10.10.2.2 -t 10
sudo ip netns exec rtr tc -s qdisc show dev vs-r
```

```
rtt min/avg/max/mdev = 40.112/40.284/40.512/0.171 ms
[ ID] Interval           Transfer     Bitrate         Retr
[  5]   0.00-10.00  sec   113 MBytes  94.8 Mbits/sec   12   sender

qdisc netem 8001: root refcnt 2 limit 10000 delay 20ms rate 100Mbit
 Sent 118412334 bytes 81792 pkt (dropped 12, overlimits 0 requeues 0)
 backlog 262144b 181p requeues 0
```

**Checkpoint — Q40–Q42**

- **Q40.** `netem delay 20ms` se aplicó a **ambas** interfaces del router, y `ping` reporta un RTT de 40 ms. Derivalo: ¿cuántas veces atraviesa un par echo request/reply de ICMP un qdisc de egreso de `netem`, y qué RTT habría producido un retardo de un solo lado de 20 ms?
- **Q41.** El qdisc `netem` muestra `backlog 181p` y `dropped 12`. Combiná eso con el `Retr 12` de `iperf3` y explicá la cadena causal completa, nombrando el recurso que está saturado.
- **Q42.** Forwardeando a 94.8 Mbit/s, `mpstat` muestra `%soft` de 8% y `%sys` de 3%. ¿En qué contexto del kernel corre el forwarding, qué proceso verías en `top` si se quedara sin presupuesto, y por qué el tráfico forwardeado no aparece como tiempo de CPU de ningún proceso de usuario?

### 5B — El costo de un ruleset de firewall

1. Medí la tasa de forwarding del ruleset vacío en paquetes por segundo, usando paquetes chicos para que el límite sea la CPU y no el ancho de banda:

```bash
sudo ip netns exec rtr tc qdisc del dev vs-r root 2>/dev/null
sudo ip netns exec rtr tc qdisc del dev vc-r root 2>/dev/null
sudo ip netns exec srv iperf3 -s -1 &
sudo ip netns exec cli iperf3 -c 10.10.2.2 -u -b 0 -l 64 -t 10 | tail -4
sudo ip netns exec rtr nstat -az | grep IpForwDatagrams
```

2. Instalá un ruleset **lineal** deliberadamente patológico y repetí:

```bash
sudo ip netns exec rtr nft -f - <<'EOF'
table inet linear {
    chain forward {
        type filter hook forward priority filter; policy accept;
    }
}
EOF
for i in $(seq 1 2000); do
  o=$(( i / 256 )); h=$(( i % 256 ))
  echo "add rule inet linear forward ip saddr 198.51.$o.$h drop"
done | sudo ip netns exec rtr nft -f -
sudo ip netns exec rtr nft list ruleset | grep -c 'ip saddr'
sudo ip netns exec srv iperf3 -s -1 &
sudo ip netns exec cli iperf3 -c 10.10.2.2 -u -b 0 -l 64 -t 10 | tail -4
mpstat -P ALL 1 5 | awk '$3=="all"'
```

3. Reemplazá las 2 000 reglas por **una** regla más un set que contenga las mismas 2 000 direcciones, y medí de nuevo:

```bash
sudo ip netns exec rtr nft flush table inet linear
sudo ip netns exec rtr nft -f - <<'EOF'
table inet linear {
    set blocked {
        type ipv4_addr
        flags interval
    }
    chain forward {
        type filter hook forward priority filter; policy accept;
        ip saddr @blocked drop
    }
}
EOF
for i in $(seq 1 2000); do o=$(( i / 256 )); h=$(( i % 256 )); echo -n "198.51.$o.$h, "; done \
  | sed 's/, $//' > /tmp/blocked.txt
sudo ip netns exec rtr nft add element inet linear blocked "{ $(cat /tmp/blocked.txt) }"
sudo ip netns exec srv iperf3 -s -1 &
sudo ip netns exec cli iperf3 -c 10.10.2.2 -u -b 0 -l 64 -t 10 | tail -4
```

4. Si `perf` está disponible, mirá a dónde van realmente los ciclos:

```bash
sudo perf top -e cycles --sort symbol -d 5 2>/dev/null | head -12   # look for nft_do_chain
```

**Checkpoint — Q43–Q44**

- **Q43.** Pps de forwarding con 0 reglas, con 2 000 reglas lineales, y con 1 regla + un set de 2 000 elementos. Describí el ordenamiento esperado y dá el costo asintótico de cada uno (por paquete). ¿Qué estructura de datos respalda un set de `nftables`, y qué cambia `flags interval` sobre eso?
- **Q44.** ¿Qué única columna de `mpstat` es la medición que prueba que el firewall, y no el enlace, es el cuello de botella? ¿Y por qué UDP con `-l 64` es el test correcto en vez de TCP con el payload por defecto?

### 5C — Connection tracking: el recurso que nadie dimensiona

1. Mirá el estado actual de la tabla:

```bash
sudo modprobe nf_conntrack 2>/dev/null
sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max \
       net.netfilter.nf_conntrack_buckets net.netfilter.nf_conntrack_tcp_timeout_established
sudo conntrack -S | head -4
sudo conntrack -C
```

```
net.netfilter.nf_conntrack_count = 1842
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_buckets = 65536
net.netfilter.nf_conntrack_tcp_timeout_established = 432000
cpu=0 found=0 invalid=1244 insert=0 insert_failed=0 drop=0 early_drop=0 error=0 search_restart=118
```

2. Hacé la tabla chica dentro del namespace del lab, forzala a llenarse, y observá el modo de falla:

```bash
sudo ip netns exec rtr sysctl -w net.netfilter.nf_conntrack_max=512
sudo ip netns exec rtr nft -f - <<'EOF'
table inet ct {
    chain forward {
        type filter hook forward priority filter; policy accept;
        ct state new counter
    }
}
EOF
sudo ip netns exec srv iperf3 -s &
sudo ip netns exec cli iperf3 -c 10.10.2.2 -P 64 -t 10 2>&1 | tail -5
sudo ip netns exec rtr sh -c 'cat /proc/sys/net/netfilter/nf_conntrack_count; conntrack -S | awk -F: "/drop|insert_failed/" ' 2>/dev/null
sudo dmesg -T | grep -i conntrack | tail -3
```

```
nf_conntrack: nf_conntrack: table full, dropping packet
```

3. Restaurá un límite sano y notá el costo de memoria de la alternativa:

```bash
sudo ip netns exec rtr sysctl -w net.netfilter.nf_conntrack_max=262144
```

**Checkpoint — Q45–Q46**

- **Q45.** Un router descarta una *pequeña fracción* de las conexiones nuevas en el pico mientras las conexiones existentes están bien, la CPU está al 30% y los enlaces al 40%. ¿Qué único par de números leés primero, y cuál es la aritmética que te dice si lo que hay que cambiar es el timeout `nf_conntrack_established` o `nf_conntrack_max`?
- **Q46.** `conntrack -S` muestra `insert_failed` subiendo pero `drop` se mantiene en 0. ¿Cuál es la diferencia, y qué patrón de tráfico produce `insert_failed` sin que la tabla esté llena?

### 5D — Presupuesto de softirq y descartes de recepción

1. Decodificá `/proc/net/softnet_stat`, que está en hexadecimal y no tiene encabezado:

```bash
awk '{ printf "cpu%-3d processed=%-10d dropped=%-8d time_squeeze=%-8d backlog_len=%s\n",
       NR-1, strtonum("0x"$1), strtonum("0x"$2), strtonum("0x"$3), ($0 ~ /./ ? strtonum("0x"$12) : 0) }' \
    /proc/net/softnet_stat
sysctl net.core.netdev_budget net.core.netdev_budget_usecs net.core.netdev_max_backlog
grep -E 'NET_RX|NET_TX' /proc/softirqs | cut -c1-100
```

```
cpu0   processed=128412     dropped=0        time_squeeze=412      backlog_len=0
cpu1   processed=98412      dropped=0        time_squeeze=18       backlog_len=0
net.core.netdev_budget = 300
net.core.netdev_budget_usecs = 2000
net.core.netdev_max_backlog = 1000
```

2. Correlacioná con el tiempo de softirq por CPU mientras corre el test de pps de 5B:

```bash
mpstat -P ALL 1 5 | awk 'NR<4 || $4!="%usr"' | grep -vE '^$'
pidof ksoftirqd/0 >/dev/null && top -b -n 1 -o %CPU | grep ksoftirqd | head -4
```

**Checkpoint — Q47**

- **Q47.** `dropped` es 0 pero `time_squeeze` es 412 y sube sólo en cpu0, mientras `%soft` en cpu0 es 70% y ~1% en el resto. Interpretá cada una de las tres señales, decí qué cuenta literalmente `time_squeeze`, y nombrá los dos mecanismos que distribuirían el trabajo entre CPUs.

---

## Lab 6 — Mapear el uso de ancho de banda por cliente

El objetivo dice "map client bandwidth usage" — qué cliente, no sólo cuánto. Cuatro herramientas responden cuatro preguntas distintas; este lab hace concreta la diferencia.

1. Instalá contadores nombrados por cliente en el router, en ambas direcciones:

```bash
sudo ip netns exec rtr nft -f - <<'EOF'
table inet acct {
    chain acct_fwd {
        type filter hook forward priority filter; policy accept;
    }
}
EOF

for ip in 10.10.1.2 10.10.2.2; do
  k="${ip//./_}"
  sudo ip netns exec rtr nft add counter inet acct "out_$k"
  sudo ip netns exec rtr nft add counter inet acct "in_$k"
  sudo ip netns exec rtr nft add rule inet acct acct_fwd ip saddr "$ip" counter name "out_$k"
  sudo ip netns exec rtr nft add rule inet acct acct_fwd ip daddr "$ip" counter name "in_$k"
done

sudo ip netns exec rtr nft list counters table inet acct
```

```
table inet acct {
	counter out_10_10_1_2 {
		packets 81792 bytes 118412334
	}
	counter in_10_10_1_2 {
		packets 12044 bytes 884122
	}
	...
}
```

2. Convertí los contadores en un reporte de ancho de banda:

```bash
cat > ~/client-bw.sh <<'EOF'
#!/bin/bash
# client-bw.sh [interval] -- per-client bandwidth from nft named counters.
iv=${1:-5}
snap() { ip netns exec rtr nft -j list counters table inet acct |
         jq -r '.nftables[] | select(.counter) | "\(.counter.name) \(.counter.bytes)"'; }
a=$(snap); sleep "$iv"; b=$(snap)
join <(sort <<<"$a") <(sort <<<"$b") |
awk -v iv="$iv" '{ printf "%-18s %10.2f Mbit/s\n", $1, ($3-$2)*8/1e6/iv }' | sort -k2 -nr
EOF
chmod +x ~/client-bw.sh
sudo ip netns exec srv iperf3 -s -1 &
sudo ip netns exec cli iperf3 -c 10.10.2.2 -t 20 >/dev/null &
sudo ~/client-bw.sh 5
```

```
out_10_10_1_2          943.12 Mbit/s
in_10_10_2_2           943.12 Mbit/s
in_10_10_1_2             1.88 Mbit/s
out_10_10_2_2            1.88 Mbit/s
```

3. Compará con la variante atómica de leer-y-poner-en-cero, que necesita una sola muestra por intervalo:

```bash
sudo ip netns exec rtr nft reset counters table inet acct >/dev/null
sleep 5
sudo ip netns exec rtr nft reset counters table inet acct | grep -A2 counter | head -12
```

4. Ahora las otras tres herramientas, cada una respondiendo una pregunta distinta:

```bash
# which peers, live, on one interface (press q to quit)
sudo iftop -n -N -i "$IF"

# which LOCAL PROCESS -- the only tool here that maps bytes to a PID
sudo nethogs "$IF"

# per-interface / per-protocol / per-port breakdown, with a logfile
sudo iptraf-ng -i "$IF"

# which interface, historically, with no live terminal
sar -n DEV -f /var/log/sysstat/sa$(date +%d) | grep -E "IFACE|$IF" | head
```

**Checkpoint — Q48–Q51**

- **Q48.** El reporte muestra `out_10_10_1_2` y `in_10_10_2_2` con conteos de bytes idénticos. ¿Es doble conteo? Explicá en términos de cuántas reglas matchea cada paquete forwardeado, y cómo reestructurarías el ruleset para facturar cada paquete una sola vez por cliente.
- **Q49.** `nft reset counters` versus dos muestras separadas cinco segundos: ¿cuál es correcta con dos pollers concurrentes, y qué exactamente sale mal con la otra?
- **Q50.** Tu router hace SNAT en `postrouting` y DNAT en `prerouting`. Para un paquete de un cliente de la LAN hacia Internet, ¿qué dirección ve un contador en el hook **forward** como `saddr`, y cuál como `daddr`? Derivalo del orden de traversal de hooks, y enunciá la consecuencia para la contabilidad por cliente.
- **Q51.** Asociá cada pregunta con exactamente una herramienta, y decí por qué las otras no pueden responderla: (a) "¿cuál de nuestros 40 clientes usó más tráfico anoche a las 03:00?"; (b) "¿qué proceso en este host está subiendo 200 Mbit/s ahora mismo?"; (c) "¿con qué IP remota está hablando más mi gateway, en este segundo?"; (d) "¿qué puerto TCP está llevando el volumen?"

---

## Lab 7 — Datos históricos: `sar` es la única herramienta que funciona después del hecho

Todas las herramientas hasta acá necesitan que estés logueado *mientras* pasa el problema. `sysstat` quita esa restricción — y el examen espera que sepas cómo se habilita, dónde escribe, y qué granularidad pierde.

1. Habilitá la recolección e inspeccioná el mecanismo:

```bash
# Debian/Ubuntu
sudo sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat 2>/dev/null
cat /etc/default/sysstat 2>/dev/null
# RHEL-family
cat /etc/sysconfig/sysstat 2>/dev/null
```

```ini
# /etc/default/sysstat
ENABLED="true"
```

```ini
# /etc/sysconfig/sysstat
HISTORY=28
COMPRESSAFTER=31
SADC_OPTIONS="-S DISK"
```

2. Averiguá *cómo* se toman las muestras en tu distribución — cron o timers de systemd, ambos llamando a los mismos dos helpers:

```bash
systemctl status sysstat sysstat-collect.timer sysstat-summary.timer --no-pager 2>/dev/null | head -20
systemctl list-timers 'sysstat*' --no-pager 2>/dev/null
ls -l /etc/cron.d/sysstat /usr/lib/sysstat/sa1 /usr/lib/sysstat/sa2 2>/dev/null
cat /etc/cron.d/sysstat 2>/dev/null
```

3. Forzá una muestra ahora y confirmá los archivos de datos:

```bash
sudo /usr/lib/sysstat/sa1 1 1 || sudo /usr/lib64/sa/sa1 1 1
ls -l /var/log/sysstat/ 2>/dev/null || ls -l /var/log/sa/
```

4. Leé el histórico, que es la habilidad real:

```bash
f=$(ls -t /var/log/sysstat/sa[0-9]* /var/log/sa/sa[0-9]* 2>/dev/null | head -1); echo "$f"
sar -u -f "$f" | head
sar -q -f "$f" | head -5                   # load average + run queue
sar -r -f "$f" | head -5                   # memory
sar -W -f "$f" | head -5                   # swapping
sar -b -f "$f" | head -5                   # aggregate I/O
sar -d -p -f "$f" | head -8                # per-device, pretty names
sar -n DEV -f "$f" | head -5
sar -u -s 09:00:00 -e 10:30:00 -f "$f"     # bound the window to the incident
```

```
12:00:01        CPU     %user     %nice   %system   %iowait    %steal     %idle
12:10:01        all      4.12      0.00      1.84     21.44      0.00     72.60
12:20:01        all      3.98      0.00      1.72     24.18      0.00     70.12
Average:        all      4.05      0.00      1.78     22.81      0.00     71.36
```

5. Exportá para una planilla o una base de series temporales:

```bash
sadf -d -- -u "$f" | head -4          # semicolon-delimited, one row per sample
sadf -j -- -u -n DEV "$f" | head -20  # JSON, for ingestion
```

6. Correlacioná dos subsistemas sobre los mismos timestamps — la jugada diagnóstica de verdad:

```bash
join -j 1 \
  <(sar -u -f "$f" | awk '$2=="all"{print $1, $5}') \
  <(sar -d -p -f "$f" | awk '$2=="nvme0n1"{print $1, $8}') \
  | awk 'BEGIN{print "time %iowait await"} {print}' | head -10
```

**Checkpoint — Q52–Q54**

- **Q52.** La recolección corre cada 10 minutos por defecto. Un freno de 45 segundos a las 03:14 disparó la guardia del servicio. ¿Qué va a mostrar `sar` para el intervalo de 03:10, y cuál es el único cambio de configuración que hace visibles esos eventos — con qué costo?
- **Q53.** `sar -u` y `sar -d` tienen ambos una noción de "ocupado" tipo `%util`. Dados `%iowait 22.8` y `await 94 ms` en los mismos timestamps, ¿cuál es la causa y cuál el síntoma? ¿Y qué tercer flag de `sar` confirmaría que no hay componente de memoria?
- **Q54.** Necesitás los datos de ayer pero `/var/log/sysstat` sólo tiene `sa15`. Explicá el esquema de nombres, el rol de `sa1` versus `sa2`, qué controla `HISTORY`, y qué archivo leerías para una fecha de hace 20 días.

---

## Lab 8 — Capstone: triage sólo a partir de los síntomas

### 8A — Asociá síntomas con causas

Para cada conjunto de síntomas, nombrá el recurso saturado, el **único** comando que lo confirma, y la acción siguiente.

| # | Conjunto de síntomas |
|---|---|
| A | `load average: 24.0`, `vmstat`: `r 1 b 23 us 2 sy 3 wa 71`, `free`: 11 GB disponibles |
| B | `load average: 8.1` en 8 CPUs, `vmstat`: `r 9 b 0 us 92 sy 4 wa 0`, PSI `cpu some avg10=61` |
| C | `vmstat`: `si 42000 so 61000 wa 48`, `free`: available 180 MB, `swpd` creciendo, `dmesg` callado |
| D | El p99 de la API saltó de 20 ms a 900 ms; CPU 20%, `await` de disco 1 ms, `nstat` `TcpRetransSegs` subió 400×, `ss -ti` muestra `cwnd:2 ssthresh:2` |
| E | El backup nocturno baja a la mitad de velocidad; `iostat`: `%util 100`, `aqu-sz 1.1`, `r_await 11 ms`, `rkB/s 92000`, el dispositivo es un disco SATA de 7 200 rpm |
| F | Las conexiones nuevas dan timeout en el pico; las establecidas están bien; CPU 30%, enlace 40%, `dmesg`: `table full, dropping packet` |
| G | `top` muestra 100% en un solo core; la aplicación es single-threaded; `%soft` es 0 |
| H | `free` muestra 240 MB libres de 16 GB, `cache` 13 GB, `si/so` en 0, PSI memory `some` es 0.00 |

**Checkpoint — Q55.** Producí la tabla: para cada uno de A–H dá recurso, comando que lo confirma, y acción.

### 8B — Estimá el techo antes de culpar a nada

Resolvé esto con `bc`; la aritmética es la habilidad relevante para el examen.

1. Un backup tiene que mover **500 GB** dentro de una ventana de **6 horas**.

```bash
echo "scale=2; 500*8*1000 / (6*3600)" | bc        # Mbit/s required
echo "scale=2; 500*1000 / (6*3600)" | bc          # MB/s required
```

2. La fuente es un disco SATA de 7 200 rpm. Asumí ~80 IOPS aleatorios y ~160 MB/s secuenciales.

```bash
echo "scale=2; 80 * 4 / 1024" | bc                # MB/s if the workload is 4 KiB random
```

3. El enlace es de 1 Gbit/s con 40 ms de RTT; la pérdida de paquetes es 0.01%. Aplicá la cota de Mathis para un único flujo tipo Reno, con MSS = 1448 B:

```bash
echo "scale=2; 1.22 * 1448 * 8 / ( (40/1000) * sqrt(0.0001) ) / 1000000" | bc -l
```

**Checkpoint — Q56–Q58**

- **Q56.** Enunciá el throughput requerido en Mbit/s y MB/s, y si un enlace de 1 Gbit/s puede soportarlo.
- **Q57.** Compará los MB/s requeridos contra los números aleatorio y secuencial del disco. ¿Bajo qué patrón de acceso entra el trabajo, y qué implica eso para cómo configurás la herramienta de backup?
- **Q58.** Calculá la cota de Mathis con 0.01% de pérdida. Un solo stream TCP no puede llenar el enlace — dá dos remedios distintos (uno en los hosts, uno en el trabajo) y decí qué campo de `ss -ti` mirarías para confirmar el arreglo.

---

## Apéndice A — Mapa herramienta → métrica (memorizá las columnas, no las herramientas)

| Recurso | Fuente cruda del kernel | Herramienta de intervalo | Por proceso | Señal de saturación |
|---|---|---|---|---|
| CPU | `/proc/stat`, `/proc/loadavg` | `mpstat -P ALL 1`, `vmstat 1` | `pidstat -u -t`, `top -H`, `ps -eo pcpu` | `r` en `vmstat`, `/proc/pressure/cpu` |
| Memoria | `/proc/meminfo`, `/proc/vmstat` | `vmstat 1`, `sar -r -W` | `pmap -X`, `smaps_rollup` (PSS) | `si`/`so`, `pgmajfault`, `/proc/pressure/memory` |
| Disco | `/proc/diskstats` | `iostat -xz 1`, `sar -d -p` | `iotop -o`, `pidstat -d`, `/proc/<pid>/io` | `aqu-sz`, `await`, `/proc/pressure/io` |
| Red | `/proc/net/dev`, `/proc/net/snmp` | `sar -n DEV`, `nstat`, `ip -s link` | `nethogs`, `ss -tanp` | backlog/drops de `tc -s qdisc`, `TcpRetransSegs`, `rx drop` |
| Firewall / ruteo | `nft list counters`, `nf_conntrack_count` | `nstat IpForwDatagrams`, `conntrack -S` | contadores `nft` por cliente | `%soft`, `time_squeeze`, `insert_failed` |
| Conexiones | `/proc/net/tcp` | `ss -s`, `ss -ti` | `ss -tanp`, `lsof -i` | `ListenOverflows`, `cwnd`/`retrans` |

## Apéndice B — Fórmulas que vale saber de memoria

- **CPU %busy** = `1 − Δ(idle + iowait) / Δ(user+nice+system+idle+iowait+irq+softirq+steal)`
- **Ley de Little** → `aqu-sz = IOPS × await(s)`; concurrencia = throughput × latencia
- **Throughput del dispositivo** a partir de diskstats = `Δsectors × 512 / Δt` (los sectores son siempre de 512 B)
- **BDP** = `bandwidth × RTT` → la ventana que un único flujo necesita para llenar un camino
- **Tasa TCP de un solo flujo** ≈ `cwnd × MSS / RTT`
- **Cota de Mathis** ≈ `(MSS / RTT) × (1.22 / √loss)`
- **Techo sin window scaling** = `65535 B / RTT`

---

## Limpieza

```bash
# load generators
pkill -f stress-ng; pkill -f fio; pkill -f iperf3
# lab files
rm -f /var/tmp/fio.dat /var/tmp/fio2.dat /var/tmp/fio3.dat /var/tmp/big /var/tmp/cachefill /tmp/blocked.txt
# firewall tables (inside the namespace, and any created on the host)
sudo ip netns exec rtr nft delete table inet acct 2>/dev/null
sudo ip netns exec rtr nft delete table inet linear 2>/dev/null
sudo ip netns exec rtr nft delete table inet ct 2>/dev/null
# namespaces (deleting them removes the veth pairs and qdiscs)
for ns in cli srv rtr; do sudo ip netns del $ns 2>/dev/null; done
ip netns list
# sysctls touched on the host (none persisted; verify)
sysctl net.ipv4.ip_forward net.netfilter.nf_conntrack_max 2>/dev/null
```

---

<details>
<summary><strong>Respuestas — Q1 a Q58 (abrir sólo después de intentar los checkpoints)</strong></summary>

### Lab 0

**Q1.** Los campos cuarto y quinto son las entidades de scheduling del kernel `runnable/total` (`2/412` = 2 ejecutables en este momento, 412 existentes) y el PID del proceso creado más recientemente (`31844`). Los primeros tres son promedios móviles amortiguados exponencialmente a 1, 5 y 15 minutos de la cantidad de tareas en estado **R (ejecutable) *más* D (sueño no interrumpible)**. La inclusión del estado D es la parte específica de Linux: el UNIX clásico cuenta sólo las tareas ejecutables, así que en Linux un load average de 24 puede ocurrir con la CPU completamente idle si 24 tareas están bloqueadas en disco o en NFS. El load average es por lo tanto un indicador de *demanda* sobre CPU **y** I/O, nunca una cifra de utilización de CPU — y por eso no hay que normalizar nada por `nproc` hasta haber revisado las columnas `r` y `b` de `vmstat`.

**Q2.** `JCPU` es el tiempo de CPU usado por todos los procesos asociados a esa tty, incluidos los ya terminados; `PCPU` es el tiempo de CPU del proceso que se muestra actualmente en `WHAT`. `IDLE` es sólo tiempo idle de la *terminal* — inactividad de teclado. Un trabajo en segundo plano desacoplado, un loop con `nohup`, o un `./report.sh` de larga duración siguen quemando recursos mientras `IDLE` trepa. `w` te informa sobre sesiones, no sobre carga; usalo para encontrar a un humano al que preguntarle, no para encontrar un culpable.

**Q3.** Casi todas las herramientas de este tema leen contadores acumulados de `/proc`. Con una sola muestra la herramienta sólo puede dividir el contador por el uptime, así que la **primera línea de `vmstat`, `iostat`, `sar`, `mpstat` y `pidstat` es un promedio desde el arranque** y va a reportar alegremente 2% de utilización en una máquina que estuvo clavada diez minutos. Pedir dos muestras hace que la segunda línea sea una medición real de intervalo. El corolario para scripts: siempre descartá la primera muestra.

### Lab 1

**Q4.** `100 / 8 = 12.5`, que es exactamente el `%usr 12.52` de la línea `all`. La línea agregada promedia sobre todas las CPUs, así que un único thread completamente saturado es indistinguible de una carga leve y repartida de manera uniforme. En un host de 64 cores un core clavado marca 1.6%. Corré siempre `mpstat -P ALL`, y recordá que la misma trampa aplica a la línea de resumen de `top` hasta que apretás `1`.

**Q5.** `4812344` ticks ÷ 100 ticks/s = `48123.44` segundos de CPU = **13.37 CPU-horas** pasadas en modo usuario desde el arranque, sumando todas las CPUs. El divisor vino de `getconf CLK_TCK`, que reporta el USER_HZ en el que está denominada la interfaz `/proc` (convencionalmente 100, independientemente del `CONFIG_HZ` interno del kernel).

**Q6.** El kernel contabiliza el tiempo de guest *dentro* de `user`, y `guest_nice` dentro de `nice`. Agregar los campos 10 y 11 al total cuenta ese tiempo dos veces, inflando el denominador y por lo tanto **subestimando** el porcentaje de ocupación. En un host KVM donde la mayor parte del trabajo es ejecución de guests el error es grande — un hipervisor completamente cargado podría leerse como ~50% ocupado. `top` y `mpstat` manejan esto restando guest de user antes de mostrar `%usr` junto a `%guest`.

**Q7.** En cualquier carga limitada por I/O. `100 − %idle` incluye `%iowait`, que es tiempo en el que la CPU estaba **idle con al menos una tarea bloqueada en I/O** — la CPU estuvo disponible todo el tiempo. La corrida de `dd iflag=direct` muestra `wa 25` con `us 1 sy 3`: `100 − %idle` afirmaría 29% de demanda de CPU cuando la cifra real es 4%.

**Q8.** No, la CPU no es el cuello de botella: `r 0` significa que nada está esperando por una CPU y `us+sy` es 4%. El cuello de botella es el **I/O de disco**: `b 1` es una tarea en sueño no interrumpible y `wa 25` es una de ocho CPUs idleando mientras esa tarea espera. La pista más fuerte sobre *qué* dispositivo es el par `bi`/`bo` (bloques entrando/saliendo por segundo, en KiB/s en procps-ng) — un `bi` grande con `bo` en cero te apunta a un dispositivo con carga pesada de lectura, que después identificás con `iostat -xz 1`.

**Q9.** Tanto las tareas R como las D cuentan para el load average. Con `stress-ng --cpu 4`, cuatro tareas están permanentemente ejecutables → la carga converge a 4. Con `dd iflag=direct`, la tarea `dd` pasa su vida en **estado D** esperando completions de la capa de bloques, y D cuenta idénticamente. Así que el load average sube en los dos casos significando dos cosas completamente distintas. Por eso "load average por encima de la cantidad de cores" no es una alerta que valga tener por sí sola.

**Q10.** `blk_mq_get_tag` está en la **capa de bloques multi-queue**: la tarea está esperando un *tag* libre, es decir un slot en la cola de hardware del dispositivo. Eso significa que la profundidad de cola del dispositivo está completamente ocupada — la request no pudo ni siquiera ser enviada todavía. Es una señal de saturación un nivel más profunda que `await`: no "el dispositivo tarda en responder" sino "no hay dónde poner la próxima request". Comparalo con `nr_requests` en `/sys/block/<dev>/queue/`.

**Q11.** `%steal` es tiempo en el que tu vCPU estaba ejecutable pero el hipervisor planificó a otro. Como guest podés: (1) mover la instancia a otro host o a un tipo de instancia dedicado/no burstable; (2) reducir tu propia cantidad de vCPUs para que al scheduler le resulte más fácil ubicarte, o fijar el trabajo sensible a la latencia; (3) escalar al proveedor con la medición. Lo que **no** podés hacer es arreglarlo con ningún tuning del lado del guest — ningún sysctl, política de scheduler ni valor de nice recupera tiempo robado, porque esos ciclos nunca fueron tuyos. (En una instancia *burstable*, revisá también el agotamiento de créditos de CPU, que se presenta igual.)

**Q12.** `some` es la fracción de tiempo de reloj en la que **al menos una** tarea no-idle estuvo frenada en el recurso; `full` es la fracción en la que **todas** las tareas no-idle estuvieron frenadas, es decir en la que no era posible trabajo productivo alguno. El kernel no publica `cpu full` porque una tarea frenada esperando CPU implica que *otra* tarea está corriendo en esa CPU — por construcción el sistema nunca está completamente frenado en CPU, así que la métrica siempre sería cero.

**Q13.** El que tiene `cpu some avg10=2%` está sano: 100% de utilización sin encolamiento es una máquina *bien usada*, que es lo que querés de un nodo de batch. El que está en 85% está en problemas. La palabra que los distingue es **saturación** — trabajo encolado más allá de la capacidad del recurso de atenderlo. La utilización tiene un techo de 100% y deja de transmitir información ahí; la saturación (PSI, cola de ejecución, `aqu-sz`) sigue subiendo y es lo que correlaciona con la latencia.

### Lab 2

**Q14.** `total = used + free + buffers + cache`, con `used` *definido* como el residuo: `used = MemTotal − MemFree − Buffers − (Cached + SReclaimable)`. Además de `Cached`, `free` pliega **`SReclaimable`** — la parte reclamable del allocator de slab (caches de dentry e inode). Pertenece a la cache porque el kernel puede encogerla bajo presión, así que contarla como `used` haría que un sistema normal pareciera falto de memoria. Notá que `Cached` en `/proc/meminfo` ya incluye `Shmem`, razón por la cual `free` reporta `shared` por separado.

**Q15.** (1) Las **páginas de `Shmem` / tmpfs** (412 MB acá) viven en `Cached` pero no pueden descartarse — no tienen otro respaldo que el swap, y el contenido de `/dev/shm` es dato vivo. (2) Los **low watermarks** que el kernel mantiene por zona, más la porción de la LRU de archivos que el kernel asume en uso activo: `MemAvailable` deliberadamente se niega a prometer la última tajada de la page cache porque reclamarla toda provocaría thrashing. (También valen: las páginas dirty, que deben escribirse antes de ser reclamadas, y las páginas con `mlock`.) `MemAvailable` es una *estimación conservadora de la memoria asignable sin swappear*, y es el número sobre el que alertar — `MemFree` es ruido.

**Q16.** `MemAvailable` baja, porque las páginas dirty no son reclamables de inmediato: el kernel tiene que escribirlas primero. El síntoma de latencia son **frenadas en la asignación y en `sync`/`fsync`** — un conjunto dirty de 6 GB significa que cualquier proceso que dispare el throttling de writeback, o cualquier `fsync`, espera a que gigabytes lleguen al disco. Ese es el clásico reporte de "la máquina se congeló ocho segundos", y se tunea con `vm.dirty_background_bytes` / `vm.dirty_bytes` (preferí las formas `_bytes` sobre las `_ratio` en hosts con mucha memoria).

**Q17.** `vm.overcommit_memory` y `vm.overcommit_ratio` (el límite mostrado aplica cuando `overcommit_memory=2`, modo estricto: `CommitLimit = swap + MemTotal × overcommit_ratio/100`). `Committed_AS` es el total de espacio de direcciones que el kernel *prometió* a todos los procesos — la suma de lo que podrían tocar, no de lo que tocaron. Rutinariamente es varias veces el RSS y **no** es memoria en uso; sólo importa porque en modo estricto una asignación que empujaría `Committed_AS` más allá de `CommitLimit` falla con `ENOMEM` en el momento del `malloc`/`mmap` en vez de más tarde vía el OOM killer.

**Q18.** Las páginas compartidas — sobre todo el texto (código) compartido de libc y de cualquier otra biblioteca compartida, más las páginas copy-on-write de los `fork` y los segmentos de memoria compartida — se cuentan **completas** en el RSS de cada proceso que las mapea. Sumar RSS por lo tanto cuenta una página física N veces. El campo que lo arregla es **`Pss`** (Proportional Set Size) en `smaps_rollup`: cada página compartida se divide por la cantidad de mapeadores, así que el PSS *sí* es aditivo entre procesos y suma aproximadamente la huella real anónima+mapeada.

**Q19.** `VSZ` es el espacio de direcciones virtual total mapeado, incluidas reservas nunca tocadas, mapeos de archivos y páginas de guarda — casi nunca es un número interesante. `RSS` son las páginas físicas residentes atribuidas a este proceso, con las compartidas incluidas completas. `Pss` es el RSS con las páginas compartidas divididas entre los mapeadores. Para 500 workers forkeados alertás sobre **PSS** (o mejor, sobre el `memory.current` del cgroup para todo el servicio): la suma de los RSS reportaría varias veces la memoria física de la máquina y generaría una falsa alarma en cada deploy.

**Q20.** `drop_caches` con `1` libera la page cache limpia, pero la columna `cache` de `free` también incluye `SReclaimable`, que `echo 1` no toca — y cualquier página **dirty** no puede descartarse hasta ser escrita, razón por la cual `sync` va antes. `echo 3` suelta la page cache **y** el slab reclamable (dentries e inodes). Ambos son sólo auxiliares de depuración: en producción la única consecuencia es que cada lectura posterior va al disco, como midió el paso 3 (8.4 s versus 0.37 s).

**Q21.** `df` reportó el espacio como **usado** (los bloques siguen asignados al inode); `du` lo reportó como ausente, porque la entrada de directorio ya no está y `du` recorre el namespace. El archivo persiste hasta que se cierra el último descriptor. El arreglo sin reiniciar: identificá al que lo retiene con `lsof +L1` o `lsof -nP | grep deleted`, y después o reiniciás/señalizás ese proceso (seguido un escritor de logs después de un `rm` en vez de un `copytruncate` de logrotate), o truncás el archivo a través de su descriptor en procfs — `: > /proc/<pid>/fd/<n>` — lo que libera los bloques de inmediato con el proceso todavía corriendo.

**Q22.** No hay ningún problema de memoria demostrado. `swpd` es un *stock*: páginas que fueron swappeadas en algún momento, posiblemente días atrás durante un trabajo batch, y nunca volvieron a necesitarse. Los *flujos* deciden la cuestión: `si` y `so` en `vmstat` (de `pswpin`/`pswpout` en `/proc/vmstat`), más **`/proc/pressure/memory`** — específicamente `some`/`full` por encima de unos pocos por ciento. `si` **y** `so` sostenidos y distintos de cero juntos es thrashing; `so` solo es apenas el kernel haciendo lugar; ambos en cero con un `swpd` grande es un sistema sano que alguna vez estuvo ocupado.

**Q23.** Un fallo **menor** se resuelve sin I/O de disco: la página ya está en memoria (hit de page cache, copy-on-write, relleno con ceros de una página anónima nueva) y sólo hay que actualizar la tabla de páginas — sub-microsegundo. Un fallo **mayor** requiere leer de un almacenamiento de respaldo (archivo o swap) — cientos de microsegundos en NVMe, milisegundos en fierro giratorio. `/proc/vmstat` los sigue como `pgfault` (todos los fallos) y **`pgmajfault`** (los caros); por proceso, `ps -o min_flt,maj_flt`. `pgmajfault` es el contador que se convierte en latencia visible para el usuario.

**Q24.** El cgroup alcanzó **su propio** `memory.max` de 256 MB mientras el host tenía 13 GB disponibles, así que el kernel corrió el OOM killer *con alcance a ese cgroup*. Nada estaba mal con el host; el límite estaba mal, o la carga lo estaba. El número para dimensionar el arreglo es el del propio cgroup: `memory.peak` si está disponible, o si no la marca máxima de `memory.current` más el desglose de `memory.stat` (anon versus file) — el `MemAvailable` del host es irrelevante para un OOM de cgroup, que es el diagnóstico errado más común en operaciones de contenedores.

**Q25.** `max` cuenta cuántas veces una asignación fue **rechazada y se forzó reclamo** porque el cgroup estaba en su límite — el límite funcionando como fue diseñado, a un costo en latencia y en CPU de reclamo. `oom_kill` cuenta procesos efectivamente matados. Un `max` alto con `oom_kill 0` es la firma de un límite **demasiado bajo pero todavía funcional**: la carga entra sólo porque el kernel está desalojando continuamente su page cache, así que el throughput sufre (visible como `pgscan`/`pgsteal` en `memory.stat` y como `memory.pressure` bien por encima de cero) mientras nada se cae. Ése es exactamente el estado que hay que atrapar antes de que se vuelva un `oom_kill`.

### Lab 3

**Q26.** `8123 × 3.84 / 1000 = 31.19`, igual al `aqu-sz` reportado. Ley de Little: **la cantidad promedio de requests en el sistema es igual a la tasa de arribo por el tiempo promedio que cada request pasa en el sistema.** `aqu-sz` es por lo tanto la cantidad promedio de requests de I/O en vuelo *más* encoladas — la concurrencia del dispositivo. Como no tiene techo superior, es la métrica honesta de saturación, y la identidad te da una verificación de consistencia gratis sobre cualquier dato de I/O que te pasen.

**Q27.** `%util` se calcula a partir del campo 10 de `/proc/diskstats` — milisegundos durante los cuales la cola no estuvo vacía — dividido por el intervalo. Responde "¿qué fracción del tiempo hubo al menos una request pendiente?". Para un disco rotacional de una sola cola eso era un proxy razonable de saturación, porque una request a la vez *era* la capacidad del dispositivo. Un dispositivo NVMe atiende decenas a miles de requests concurrentemente, así que un flujo perezoso de requests mantiene `%util` en 100% usando una fracción del hardware. El reemplazo es **`aqu-sz`** (la concurrencia lograda) comparado contra la profundidad de cola útil del dispositivo, más `await` contra su piso de tiempo de servicio.

**Q28.** `rareq-sz 4.00` KiB con `rrqm/s 0.00` dice que cada request llegó al dispositivo exactamente del tamaño que pidió la aplicación, **sin fusión**: los offsets no eran adyacentes, es decir que la carga es genuinamente aleatoria — lo que coincide con `--rw=randread --bs=4k`. Un `rrqm/s` de 800/s habría significado que la capa de bloques estaba coalesciendo requests adyacentes en otras más grandes, la firma de un patrón de acceso *secuencial* (o de un readahead funcionando), y habría elevado `rareq-sz` bien por encima del tamaño de bloque de la aplicación.

**Q29.** Porque `/proc/diskstats` y la capa de bloques genérica del kernel expresan los tamaños de request en **sectores de 512 bytes por definición**, como unidad fija de la interfaz — no en el tamaño de bloque lógico o físico del dispositivo. Un disco 4 Kn reporta una request de 8 sectores para un bloque de 4 KiB. `iostat` hace la misma multiplicación. (La geometría propia del dispositivo está en `/sys/block/<dev>/queue/logical_block_size` y `physical_block_size`, que importan para el alineamiento, no para esta aritmética.)

**Q30.** `svctm` pretendía ser el *tiempo de servicio* del dispositivo excluyendo el encolamiento, pero se derivaba de un modelo que asumía silenciosamente una request en vuelo a la vez. En cualquier dispositivo concurrente el número no significa nada, y sysstat 12 lo sacó en vez de seguir publicándolo. El error que alentaba: concluir "el dispositivo es rápido, `svctm` es 0.2 ms" mientras las aplicaciones esperaban 90 ms, porque el retardo de encolamiento — donde realmente se iba el tiempo — era invisible. Usá `await` (total, incluyendo el tiempo en cola) y `aqu-sz` para ver cuánto de `await` es encolamiento: `tiempo en cola ≈ await × (1 − 1/aqu-sz)` para un servidor único saturado, o simplemente compará `await` contra el tiempo de servicio de mejor caso, tipo `minrtt`, de una corrida con poca profundidad.

**Q31.** `rchar` cuenta los bytes transferidos por las **syscalls de la familia read**, satisfechos desde donde sea — page cache incluida. `read_bytes` cuenta los bytes efectivamente **traídos desde la capa de bloques**. `rchar` enorme con `read_bytes` en cero es la firma de una carga cuyos datos están enteramente en la page cache (una base de datos caliente, lecturas repetidas de los mismos archivos, o lecturas de `tmpfs`/pipes/sockets). Ese par es la forma más barata de decidir si un proceso es un problema de I/O o un caso de éxito de aciertos de cache.

**Q32.** El proceso escribió páginas en la page cache (contadas en `wchar`, y provisionalmente en la contabilidad de writeback) y después **borró o truncó** el archivo antes de que el writeback las volcara, así que el kernel canceló I/O que ya había atribuido. `cancelled_write_bytes` registra ese crédito. Los valores distintos de cero son típicos del churn de archivos temporales — compiladores, volcados de sort, staging de uploads — y significan que el volumen aparente de escritura del proceso sobreestima lo que llegó al disco.

**Q33.** `iotop` necesita **`CONFIG_TASK_DELAY_ACCT`** (más `CONFIG_TASKSTATS`, `CONFIG_TASK_IO_ACCOUNTING`, y el sysctl en runtime `kernel.task_delayacct` en kernels modernos) y requiere **root / `CAP_NET_ADMIN`** para abrir el socket netlink de taskstats. `pidstat -d` tiene la misma dependencia de taskstats. El único que no necesita ninguno de los dos es leer **`/proc/<pid>/io`** directamente — cualquier usuario puede leerlo para sus propios procesos, y root para todos, sin ninguna opción de kernel más allá de `CONFIG_TASK_IO_ACCOUNTING`.

**Q34.** **`vm.dirty_background_ratio`/`vm.dirty_background_bytes`** y **`vm.dirty_ratio`/`vm.dirty_bytes`** (con `vm.dirty_expire_centisecs` como tercero). El mecanismo: el trabajo escribe en la page cache sin `fsync`, así que nada llega al disco y `wkB/s` se mantiene cerca de cero mientras `Dirty` trepa. Cuando `Dirty` cruza el umbral de background, arrancan los threads de flush `kworker`; cuando cruza `dirty_ratio`, **todo proceso que escribe es frenado sincrónicamente** hasta que el backlog se drena. El resultado es exactamente el diente de sierra observado: largos períodos tranquilos, y después `w_await` de varios segundos mientras se vuelcan gigabytes de golpe. El arreglo son umbrales más bajos (expresados en `_bytes`, para que no escalen con la RAM), de modo que el writeback sea continuo en vez de a ráfagas.

### Lab 4

**Q35.** BDP = `1 Gbit/s × 0.040 s = 5 000 000 bytes ≈ 4.77 MiB` — un único flujo necesita alrededor de 5 MB en vuelo para llenar ese camino. Sin window scaling la ventana de recepción está limitada al campo de 16 bits del header TCP, 65 535 B, lo que da `65535 / 0.040 = 1.638 MB/s ≈ 13.1 Mbit/s` — 1.3% del enlace, sin importar cuán rápido sea el hardware. El sysctl es **`net.ipv4.tcp_window_scaling`** (activo por defecto; la opción de window scale del RFC 7323 se negocia en el SYN, así que un middlebox que la quita reproduce los años 90). `ss -ti` muestra **`wscale:7,7`** — los factores de escala de envío y recepción; su ausencia significa que no hay scaling.

**Q36.** `retrans:0/18` es `actual/total`: cero segmentos esperando retransmisión *ahora mismo*, y 18 retransmitidos en la vida de la conexión. La razón por la que `nstat` puede mostrar `TcpRetransSegs` subiendo con todas las conexiones vivas limpias es que `nstat` reporta un **contador a nivel de sistema que incluye conexiones ya cerradas** — una tormenta de retransmisiones en conexiones de vida corta no deja rastro en `ss`, que sólo muestra sockets que todavía existen. Usá `nstat` para detectar que hay un problema, `ss -ti` en sockets de vida larga para caracterizarlo, y `TcpExtTCPLostRetransmit` para encontrar retransmisiones que se perdieron ellas mismas.

**Q37.** Probaste que **el límite por flujo, no el camino, era la restricción** — el camino lleva al menos 240 Mbit/s, así que el stream único estaba limitado por su propia ventana, el RTT, o la respuesta de congestión guiada por pérdidas (Mathis), no por la capacidad. **No** probaste cuál es el techo real del camino (ocho streams también pueden quedar cortos), ni que la aplicación pueda usar streams paralelos. Agregá un test UDP a una tasa ofrecida conocida (`iperf3 -u -b <rate>`) para medir capacidad y pérdida independientemente del control de congestión de TCP, y revisá `delivery_rate` y `retrans` de `ss -ti` en el stream único para ver si lo que ataba era la ventana o la pérdida.

**Q38.** **GRO** (Generic Receive Offload), o LRO en hardware — la NIC/driver coalesce segmentos consecutivos en un skb grande antes de que se incrementen los contadores de `/proc/net/dev`, así que el kernel cuenta un "paquete" de 24 000 bytes donde 16 frames cruzaron el cable. Cualquier presupuesto de pps calculado desde estos contadores queda por lo tanto subestimado hasta por el factor de coalescencia, lo que importa precisamente cuando estás dimensionando un presupuesto de interrupciones o de softirq. Confirmalo con `ethtool -k <iface>` (buscá `generic-receive-offload: on`, `large-receive-offload`) y notá el gemelo del lado de transmisión, TSO/GSO, que hace lo mismo con los conteos de `tx`.

**Q39.** `errs` cuenta frames que el hardware o el driver rechazaron como mal formados — fallos de CRC, errores de longitud, overruns de FIFO en algunos drivers: una señal de **capa física o de cableado**. `drop` cuenta frames que el host recibió intactos y después **descartó por falta de recursos o porque nada los quería** — una señal del lado del software. Después mirá **`/proc/net/softnet_stat`** (la columna `dropped`, que significa que se desbordó la cola de backlog por CPU) y tuneá **`net.core.netdev_max_backlog`**; revisá también `ethtool -S <iface>` por descartes del ring buffer y `ethtool -g` por el tamaño del ring. (Notá que `drop` también se incrementa inofensivamente por frames de protocolos que nadie está escuchando, así que un conteo lento y estable en una LAN ruidosa no es un defecto.)

### Lab 5

**Q40.** Un viaje de ida y vuelta es: request `cli → rtr → srv`, que atraviesa el qdisc de egreso de `vs-r` una vez (+20 ms); respuesta `srv → rtr → cli`, que atraviesa el qdisc de egreso de `vc-r` una vez (+20 ms). Dos traversals de qdisc por viaje redondo → RTT de 40 ms. `netem` retarda **sólo en egreso**, así que un retardo de un solo lado de 20 ms da un RTT de 20 ms. Éste es el error estándar en la emulación de WAN casera: configurar "20 ms en cada dirección" y después medir 40 ms, o configurar un solo lado y preguntarse por qué el RTT es la mitad de lo pretendido.

**Q41.** La carga ofrecida (el emisor acelerando) excedió la tasa modelada de 100 Mbit/s → los paquetes se acumularon en la cola de `netem` (`backlog 181p`) → la cola alcanzó su `limit` y descartó 12 paquetes por la cola → el emisor TCP detectó la pérdida y los retransmitió (`Retr 12`) mientras reducía a la mitad su ventana de congestión, estabilizándose en 94.8 Mbit/s, apenas por debajo de la tasa modelada. El recurso saturado es el **ancho de banda de egreso de `vs-r`**, y el backlog de la cola es la prueba — ésta es la demostración canónica de que los descartes en un shaper no son un error sino el mecanismo por el cual TCP descubre la capacidad. (Un backlog creciente *sin* descartes sería en cambio bufferbloat: inflación de latencia en lugar de pérdida.)

**Q42.** El forwarding corre en **contexto de softirq** (`NET_RX_SOFTIRQ`), cargado a `%soft`, no a ningún proceso. Si el presupuesto por invocación se agota repetidamente el kernel difiere el trabajo restante al thread de kernel **`ksoftirqd/<n>`** por CPU, que *sí* es visible en `top` y cuya aparición con CPU alta es el signo clásico de un problema de tasa de paquetes. El tráfico forwardeado nunca entra en la contabilidad de un proceso de usuario porque nunca se copia a un socket: el paquete se recibe, se rutea y se transmite enteramente dentro del stack de red del kernel, que es también la razón por la cual `nethogs` no puede decirte nada sobre el tráfico de tránsito de un router.

**Q43.** Ordenamiento esperado: 0 reglas lo más rápido, el basado en set a continuación (muy cerca), 2 000 reglas lineales por lejos lo más lento. Costo por paquete: cadena vacía ≈ O(1); 2 000 reglas discretas = **O(n)** — cada paquete se evalúa contra hasta 2 000 reglas secuencialmente antes del veredicto de accept; una regla más un set = **O(1)** para un set de match exacto. Los sets de `nftables` están respaldados por una **tabla hash** para matches exactos; **`flags interval`** cambia el backend a una estructura de datos distinta (un árbol rojo-negro, o `nft_set_pipapo` para concatenaciones) que soporta rangos y prefijos en **O(log n)** en lugar de O(1) — todavía muchísimo mejor que lineal, y la razón de ser de los sets de `nft` / `ipset`. Ésta es también la respuesta estructural a "por qué `iptables` con miles de reglas es lento": su recorrido lineal `ipt_do_table`.

**Q44.** **`%soft`** (por CPU, de `mpstat -P ALL`). La evaluación de reglas ocurre en contexto de softirq, así que un cuello de botella de ruleset aparece como `%soft` saturando una o más CPUs mientras la utilización del enlace se queda bien por debajo de la capacidad — y `perf top` va a nombrar `nft_do_chain` o `ipt_do_table` directamente. UDP con `-l 64` es el test correcto porque el costo de un firewall es **por paquete, no por byte**: con payloads de 64 bytes maximizás los pps para un bitrate dado y el recorrido de reglas por paquete domina. TCP con tamaños por defecto mezclaría control de congestión, offloads (la coalescencia de TSO/GSO esconde los pps) y clocking de ACKs, confundiendo la medición.

**Q45.** Leé primero **`nf_conntrack_count` contra `nf_conntrack_max`**. La aritmética es otra vez la ley de Little: `entradas requeridas ≈ conexiones nuevas/s × vida promedio de la entrada`. Si tu pico son 2 000 conn nuevas/s y las entradas viven el `nf_conntrack_tcp_timeout_established` por defecto de 432 000 s (5 días), el requerimiento en estado estacionario es absurdo — el arreglo es el **timeout** (y `tcp_timeout_time_wait`, `udp_timeout`), porque estás reteniendo estado de conexiones que terminaron hace mucho. Si la vida de las conexiones es genuinamente larga y legítima, el arreglo es **`nf_conntrack_max`** (subido junto con `nf_conntrack_buckets` para mantener cortas las cadenas del hash — aproximadamente `max = buckets × 4` — a un costo de ~300 bytes de memoria de kernel por entrada). La firma diagnóstica es precisa: conexiones *nuevas* fallando mientras las *establecidas* no se ven afectadas, con la CPU y el ancho de banda ociosos.

**Q46.** `drop` cuenta paquetes descartados porque la tabla estaba llena o no se pudo asignar una entrada. **`insert_failed`** cuenta intentos de insertar una entrada nueva que colisionó con una entrada existente idéntica en su tupla — en la práctica casi siempre **colisiones de puerto de origen del NAT**: muchas conexiones desde el mismo origen siendo SNAT'eadas a una sola dirección, donde el kernel no pudo encontrar una tupla `(saddr, sport, daddr, dport)` libre. Lo produce una tasa alta de conexiones desde detrás de una única dirección NAT con un rango de puertos chico, no una tabla llena. Remedios: un pool de SNAT más grande (`nft ... snat to 198.51.100.1-198.51.100.8`), randomización de puertos estilo `--random-fully`, o diseños sin `fullcone` — ninguno de los cuales involucra `nf_conntrack_max`.

**Q47.** (1) `dropped 0` significa que el backlog de entrada por CPU no se desbordó — no se perdieron paquetes en esa etapa, así que `netdev_max_backlog` es adecuado. (2) **`time_squeeze`** cuenta cuántas veces el loop de polling de NAPI se quedó sin su **presupuesto** (`net.core.netdev_budget`, 300 paquetes, o `netdev_budget_usecs`, 2000 µs) con trabajo todavía pendiente, y tuvo que diferir a `ksoftirqd` — es decir, la CPU no pudo drenar el ring en una sola pasada. (3) `%soft 70%` en cpu0 sola con ~1% en el resto significa que **todo el procesamiento de recepción está cayendo en una sola CPU**: una única cola de hardware, o una única IRQ, fijada ahí. Los dos mecanismos para distribuirlo: **RSS** (Receive Side Scaling — múltiples colas de hardware, cada una con su propia IRQ, repartidas vía `/proc/irq/*/smp_affinity`, idealmente gestionadas por `irqbalance` o fijación explícita) y, donde la NIC no puede hacerlo, **RPS** (Receive Packet Steering, redistribución por software vía `/sys/class/net/<if>/queues/rx-*/rps_cpus`), opcionalmente con RFS para localidad de flujo. Subir `netdev_budget` sólo hace que la única CPU trabaje más duro; no agrega capacidad.

### Lab 6

**Q48.** Es doble conteo desde el punto de vista del *enlace* pero no desde el punto de vista de la *facturación*, y tenés que elegir deliberadamente. Cada paquete forwardeado atraviesa `acct_fwd` una vez y, porque la policy de la cadena es `accept` y nada la termina, matchea **tanto** la regla de `ip saddr` para su origen **como** la de `ip daddr` para su destino — así que un paquete incrementa dos contadores. Para el tráfico `cli → srv`, `out_10_10_1_2` y `in_10_10_2_2` son literalmente los mismos bytes vistos como "enviados por el cliente" y "recibidos por el servidor", que es por qué son idénticos. Para facturar cada paquete una sola vez por cliente, o (a) contá sólo la dirección que facturás (p. ej. sólo `saddr` para la subida y sólo `daddr` para la bajada, y después sumá por cliente sabiendo que cada paquete contribuye a exactamente uno de los dos medidores de sus clientes), o (b) restringí el matching a la subred que te pertenece: `ip saddr 10.10.1.0/24 counter name ...` para que el tránsito entre dos direcciones ajenas nunca se cuente dos veces. Declará siempre qué convención usa tu dashboard.

**Q49.** **`nft reset counters` es correcto sólo si existe exactamente un poller.** Leer-y-poner-en-cero es atómico respecto del camino del paquete, así que no se pierden bytes entre la lectura y el reset, y una sola muestra por intervalo alcanza — ésa es su ventaja sobre muestrear dos veces. Pero es **destructivo**: con dos pollers (tu script y un exporter de Prometheus), cada uno pone en cero los contadores que el otro necesita, y ambos reportan aproximadamente la mitad del tráfico real. El delta de dos muestras es no destructivo y por lo tanto seguro para cualquier cantidad de lectores concurrentes; su debilidad es que puede perderse un wrap del contador o un `nft flush`/reload entre muestras, lo que aparece como un delta negativo — chequeá eso en el script en vez de imprimir un ancho de banda negativo.

**Q50.** El orden de hooks de Netfilter para un paquete forwardeado es: `prerouting` (donde se aplica **DNAT**) → decisión de ruteo → **`forward`** → `postrouting` (donde se aplica **SNAT**). Así que un contador en `forward` ve el **`saddr` original, pre-SNAT** (la dirección privada del cliente de la LAN — exactamente lo que querés para contabilidad por cliente) y el **`daddr` ya traducido por DNAT**. Consecuencias: la contabilidad de *subida* por cliente en `forward` funciona naturalmente y factura al cliente interno real; la contabilidad de *bajada* por cliente también funciona, porque el `daddr` del paquete de respuesta fue traducido de vuelta por conntrack en `prerouting` antes de llegar a `forward`. Pero cualquier regla que matchee la dirección **pública** de un servicio con DNAT tiene que vivir en `prerouting` (antes de la traducción) o usar `ct original` para recuperar la tupla pre-NAT — matchear la dirección pública en `forward` nunca va a pegar.

**Q51.** (a) **`sar -n DEV` / `sadf`** — la única herramienta con histórico; nada más puede responder una pregunta sobre las 03:00 después del hecho (la granularidad por cliente requiere que hayas estado recolectando contadores `nft` por cliente en una serie temporal, que es la forma de producción de este lab). (b) **`nethogs`** — la única de las cuatro que mapea bytes a un **PID**, porque asocia inodes de socket con procesos; los contadores de `nft` e `iftop` ven direcciones, no procesos. (c) **`iftop`** — top-talkers por par de peers, en vivo y ordenados, en una interfaz; construido exactamente para esto, y la única que te da la respuesta en dos segundos sin configuración. (d) **`iptraf-ng`** — sus desgloses estadísticos son por protocolo y por puerto, lo que ni `iftop` (peers) ni `nethogs` (procesos) proveen. (Una quinta respuesta que vale saber: `ss -tanp` más `nstat` para estado por socket y por protocolo, y `tcpdump`/`nfdump`/NetFlow cuando necesitás registros durables por flujo.)

### Lab 7

**Q54.** Los archivos son `saDD`, donde `DD` es el **día del mes**, en `/var/log/sysstat/` (familia Debian) o `/var/log/sa/` (familia RHEL) — así que el conjunto rota mensualmente y `sa15` es el día 15 del mes actual. **`sa1`** es el recolector: invoca a `sadc` para agregar una muestra binaria al archivo `saDD` de hoy, y es lo que una entrada de cron o `sysstat-collect.timer` ejecuta cada 10 minutos. **`sa2`** es el resumidor: corre una vez cerca del fin del día, escribe el reporte diario legible por humanos `sarDD`, y hace la limpieza de retención. **`HISTORY`** (en `/etc/sysconfig/sysstat`, o `/etc/sysstat/sysstat` en Debian) es la cantidad de **días** que se conservan; cuando excede 28, `sadc` pasa a nombres `saYYYYMMDD` para que los días no colisionen entre meses. Para una fecha de hace 20 días entonces leés o `sa<DD>` de esa fecha — si `HISTORY` es lo bastante grande como para que no haya sido sobrescrito — o `saYYYYMMDD`; revisá `COMPRESSAFTER`, ya que los archivos más viejos pueden estar en `.xz`/`.gz` y necesitar `sar -f` sobre la copia descomprimida.

**Q52.** El intervalo de 03:10 va a mostrar el freno de 45 segundos **promediado sobre 600 segundos** — más o menos 7.5% del efecto — que para la mayoría de las métricas es indistinguible del ruido. `sar` va a reportar un punto de datos nada notable y vas a concluir erróneamente "no estaba pasando nada". El cambio es acortar el intervalo de recolección (editar el `OnCalendar` del `sysstat-collect.timer`, o el `*/10` en `/etc/cron.d/sysstat`, a 1 minuto). El costo es ~10× el espacio de disco y ~10× los despertares de `sadc`, y además sigue sin poder atrapar picos sub-intervalo — que es el argumento estructural a favor de un agente de series temporales de verdad con resolución de 10–15 s junto a `sar`, y de leer los contadores `total` de PSI, que son acumulativos y por lo tanto no pierden nada con el promediado.

**Q53.** `await 94 ms` es la **causa**; `%iowait 22.8` es el **síntoma**. La causalidad corre dispositivo → tarea → CPU: las requests se encolan en el dispositivo, las tareas se bloquean en estado D, las CPUs quedan idle con tareas bloqueadas y el kernel anota ese tiempo idle como `%iowait`. Tunear cualquier cosa del lado de la CPU no cambia nada. El tercer flag es **`sar -B`** (estadísticas de paginación: `majflt/s`, `pgscank/s`, `pgsteal/s`, `%vmeff`) — o `sar -r`/`sar -W`: si los fallos mayores y el escaneo están planos, el I/O es impulsado por la aplicación y no un efecto secundario del reclamo de memoria trayendo cosas de vuelta por paginación, que es un arreglo completamente distinto.

### Lab 8

**Q55.**

| # | Recurso | Comando que lo confirma | Acción |
|---|---|---|---|
| A | **I/O de disco** (23 tareas en estado D; CPU idle, memoria bien) | `iostat -xz 1` → mirar `await`, `aqu-sz`; después `iotop -o` | Identificar el dispositivo y el proceso; reducir la concurrencia o mover la carga. El load average de 24 acá *no* es una señal de CPU. |
| B | **CPU** (saturación genuina: `r 9` en 8 CPUs, `us 92`, PSI 61%) | `mpstat -P ALL 1` + `pidstat -u -t 1` | Encontrar el thread, perfilarlo (`perf top`), agregar cores o limitar la carga. |
| C | **Memoria** (thrashing: `si` *y* `so` ambos grandes, available 180 MB) | `vmstat 1` con `/proc/pressure/memory`; después ranking por PSS | Reducir el working set o agregar RAM. El `wa` alto es una *consecuencia* del I/O de swap — no persigas el disco. |
| D | **Red** (pérdida colapsando la ventana de congestión a 2 segmentos) | `nstat -az \| grep -i retrans` + `ss -ti` en un socket vivo | Encontrar el salto con pérdida (`mtr`), revisar si hay un shaper/cola saturado o un enlace defectuoso; los buffers no son el problema con `cwnd:2`. |
| E | **I/O de disco, y está en su techo** — `aqu-sz 1.1` y `await 11 ms` en un disco de 7 200 rpm es una request a la vez a latencia de seek | `iostat -xz 1`; comparar `rkB/s` y `r_await` contra la clase de dispositivo | Nada está mal configurado: el hardware es el límite. Cambiá el hardware, el patrón de acceso, o la ventana. El `%util 100` acá es honesto, a diferencia de en NVMe. |
| F | **Tabla de connection tracking** | `sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max`; `conntrack -S` | Bajá primero los timeouts de established/time-wait; subí `nf_conntrack_max` junto con `nf_conntrack_buckets` si la demanda es real. |
| G | **CPU, un solo core, limitado por la aplicación** | `mpstat -P ALL 1` (una CPU al 100%), `top -H` para confirmar un solo thread | Nada que tunear en el host: más cores no van a ayudar a un loop caliente single-threaded. Paralelizar, shardear, o conseguir un core más rápido. `%soft 0` descarta una causa de procesamiento de paquetes. |
| H | **Nada — éste es un sistema sano** | `free -w` más `/proc/pressure/memory` (0.00) y `vmstat` (`si/so` 0) | Ninguna acción. 240 MB "libres" con 13 GB de page cache y presión cero es una máquina correctamente usada; `MemAvailable`, no `MemFree`, es el número que importa. |

**Q56.** `500 × 8 × 1000 / 21600 = 185.19 Mbit/s`, equivalentemente `500 × 1000 / 21600 = 23.15 MB/s` sostenidos durante las seis horas completas, **sin** margen para overhead de protocolo, contención, ni el hecho de que los trabajos reales no van perfectamente acompasados. Un enlace de 1 Gbit/s lo lleva con amplio margen — el enlace no es la restricción, lo cual ya es la conclusión útil: dirige la atención al disco y a la aplicación.

**Q57.** Requeridos 23.15 MB/s versus `80 × 4 / 1024 = 0.31 MB/s` aleatorios y ~160 MB/s secuenciales. El trabajo entra **sólo si el patrón de acceso es secuencial** — necesita 14% de la capacidad secuencial pero **74×** la capacidad aleatoria. Implicancia: configurá el backup para lecturas secuenciales grandes — tamaños de bloque grandes, pocos streams concurrentes (el paralelismo en un disco rotacional convierte lo secuencial en aleatorio y destruye el margen), readahead habilitado, y evitá el overhead por archivo en millones de archivos chicos streameando hacia un archivo contenedor. Verificalo en ejecución con `iostat -xz`: `rareq-sz` debería ser grande y `rrqm/s` distinto de cero. Si no lo es, podés ver el patrón salir mal antes de perder la ventana.

**Q58.** `1.22 × 1448 × 8 / (0.040 × 0.01) / 1e6 = 35.3 Mbit/s` — un solo flujo TCP tipo Reno no puede exceder ~35 Mbit/s a 40 ms de RTT y 0.01% de pérdida, que es el 19% de los 185 Mbit/s que el trabajo necesita, en un enlace con diez veces la capacidad cruda. Por esto "el enlace es de 1 Gbit/s, así que la transferencia debería ser rápida" está equivocado tan seguido. Dos remedios: **en los hosts** — subir los techos del autotuning (`net.ipv4.tcp_rmem`/`tcp_wmem` y `net.core.rmem_max`/`wmem_max`) para que la ventana pueda alcanzar el BDP de 5 MB, y cambiar el control de congestión a un algoritmo tolerante a pérdidas (`net.ipv4.tcp_congestion_control = bbr`), que no está gobernado por la relación de √loss de Mathis; **en el trabajo** — usar streams paralelos (fan-out de `rsync`, `rclone --transfers`, upload multi-stream a objetos), ya que N flujos multiplican la tasa alcanzable mientras cada uno sigue individualmente limitado por su ventana. Mirá **`delivery_rate`** en `ss -ti` (junto con `cwnd` y `retrans`) para confirmar: un `cwnd` creciente que se sostiene sin precipicio de retransmisiones es el arreglo funcionando. Y arreglá la pérdida si podés — 0.01% no es "casi cero" para una tubería larga y gorda, es el término dominante.

</details>

---

## Fuentes

- LPI, *Exam 201-450 Objectives* (LPIC-2, versión 4.5.0), objetivo 200.1 — <https://www.lpi.org/our-certifications/exam-201-objectives/>
- Documentación del kernel Linux, *The /proc Filesystem* — <https://www.kernel.org/doc/html/latest/filesystems/proc.html>
- Documentación del kernel Linux, *I/O statistics fields* (`/proc/diskstats`) — <https://www.kernel.org/doc/html/latest/admin-guide/iostats.html>
- Documentación del kernel Linux, *PSI – Pressure Stall Information* — <https://www.kernel.org/doc/html/latest/accounting/psi.html>
- Documentación del kernel Linux, *Control Group v2* (controlador de memoria, `memory.events`, `memory.stat`) — <https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html>
- Documentación del kernel Linux, *Documentation for /proc/sys/vm* (`dirty_ratio`, `swappiness`, `overcommit_memory`) — <https://www.kernel.org/doc/html/latest/admin-guide/sysctl/vm.html>
- Documentación del kernel Linux, *Documentation for /proc/sys/net* (`netdev_budget`, `netdev_max_backlog`) — <https://www.kernel.org/doc/html/latest/admin-guide/sysctl/net.html>
- Documentación del kernel Linux, *SNMP counter* (contadores TCP/IP detrás de `nstat` y `netstat -s`) — <https://www.kernel.org/doc/html/latest/networking/snmp_counter.html>
- Documentación del kernel Linux, *Connection tracking sysctl* — <https://www.kernel.org/doc/html/latest/networking/nf_conntrack-sysctl.html>
- Documentación del kernel Linux, *Scaling in the Linux Networking Stack* (RSS, RPS, RFS) — <https://www.kernel.org/doc/html/latest/networking/scaling.html>
- Proyecto sysstat (`sar`, `iostat`, `mpstat`, `pidstat`, `sadf`, `sa1`/`sa2`) — <https://sysstat.github.io/>
- Proyecto Linux man-pages: `proc(5)` <https://man7.org/linux/man-pages/man5/proc.5.html> · `vmstat(8)` <https://man7.org/linux/man-pages/man8/vmstat.8.html> · `iostat(1)` <https://man7.org/linux/man-pages/man1/iostat.1.html> · `sar(1)` <https://man7.org/linux/man-pages/man1/sar.1.html> · `ss(8)` <https://man7.org/linux/man-pages/man8/ss.8.html> · `lsof(8)` <https://man7.org/linux/man-pages/man8/lsof.8.html> · `tc-netem(8)` <https://man7.org/linux/man-pages/man8/tc-netem.8.html> · `ip-netns(8)` <https://man7.org/linux/man-pages/man8/ip-netns.8.html>
- Wiki de nftables, *Counters* y *Sets* — <https://wiki.nftables.org/wiki-nftables/index.php/Counters> · <https://wiki.nftables.org/wiki-nftables/index.php/Sets>
- Documentación de iperf3 (ESnet) — <https://software.es.net/iperf/>
- Documentación de fio — <https://fio.readthedocs.io/en/latest/fio_doc.html>
- M. Mathis et al., *The Macroscopic Behavior of the TCP Congestion Avoidance Algorithm*, ACM SIGCOMM CCR 27(3), 1997 — <https://dl.acm.org/doi/10.1145/263932.264023>