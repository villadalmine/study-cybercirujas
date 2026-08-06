# LPIC-2 Exam 201-450: Topic 201.1 — Capacity Planning

**Certificación objetivo:** LPIC-2 (Exámenes 201-450 y 202-450, Versión 4.5)  
**Tema:** 201.1 Capacity Planning  
**Peso:** 7  
**Rol:** Principal Platform Architect & Senior SRE Instructor  

---

## 1. Deep Technical Mechanics & Architecture

Capacity planning en entornos Linux enterprise requiere una comprensión arquitectónica de cómo el kernel de Linux expone el estado de ejecución del hardware, cómo se muestrean las métricas de los subsistemas y cómo se extrapolan las tendencias para prevenir la degradación del sistema.

```
+-------------------------------------------------------------------------------+
|                                USER SPACE                                     |
|  +--------------+   +--------------+   +--------------+   +----------------+  |
|  |    vmstat    |   |    iostat    |   |  sar / sadc  |   |     ss / top   |  |
|  +-------+------+   +-------+------+   +-------+------+   +-------+--------+  |
+----------|------------------|------------------|------------------|-----------+
|          |                  |                  |                  |           |
|  +-------v------------------v------------------v------------------v--------+  |
|  |                       /proc Pseudo-Filesystem                           |  |
|  |  /proc/stat   /proc/meminfo   /proc/diskstats   /proc/net/dev   loadavg |  |
|  +-------+------------------+------------------+------------------+--------+  |
|          |                  |                  |                  |           |
+----------|------------------|------------------|------------------|-----------+
|          v                  v                  v                  v           |
|   [ CPU Scheduler ]  [ Memory Manager ]  [ Block I/O Layer ]  [ TCP/IP Stack ] |
|                               KERNEL SPACE                                    |
+-------------------------------------------------------------------------------+
```

### 1.1 The `/proc` Virtual Filesystem Architecture
El kernel de Linux no almacena los contadores de rendimiento del sistema en almacenamiento persistente. En su lugar, expone estructuras de datos dinámicas a través del sistema de archivos virtual `/proc` (`procfs`). 
- **`/proc/stat`**: Expone contadores de ticks de CPU a nivel de kernel desde el arranque, categorizados por modo (`user`, `nice`, `system`, `idle`, `iowait`, `irq`, `softirq`, `steal`, `guest`, `guest_nice`). Las métricas se rastrean en unidades de USER_HZ (típicamente 100 ticks por segundo / intervalos de 10ms).
- **`/proc/meminfo`**: Expone contadores del asignador de memoria del kernel, separando la RAM física en páginas activas/inactivas, memory anónima (anonymous memory), page cache, asignaciones de slab (`SReclaimable` vs `SUnreclaimable`), y utilización de swap.
- **`/proc/diskstats`**: Contiene arrays de contadores de dispositivos de bloque que rastrean lecturas/escrituras completadas, solicitudes fusionadas (merged requests), sectores leídos/escritos y el total de milisegundos dedicados a I/O.
- **`/proc/net/dev`**: Expone estadísticas de interfaces de red (bytes, paquetes, errores, drops, desbordamientos de fifo, colisiones de carrier).
- **`/proc/loadavg`**: Expone promedios de carga del sistema (system load averages) calculados como una media móvil amortiguada exponencialmente sobre intervalos de 1, 5 y 15 minutos. 

### 1.2 System Load Average Mechanics
La métrica de load average en Linux cuenta procesos en dos estados de ejecución del kernel:
1. `TASK_RUNNING` (`R`): Procesos ejecutándose en la CPU o en cola en el runqueue.
2. `TASK_UNINTERRUPTIBLE` (`D`): Procesos bloqueados en operaciones no interrumpibles del kernel (predominantemente I/O síncrono de disco o red).

$$\text{Load} = \text{Tasks}_{R} + \text{Tasks}_{D}$$

> **Trade-Off de Arquitectura:** Un load average alto no indica strictly saturación de CPU. Un sistema con $0\%$ de utilización de CPU puede exhibir un load average de 50 si 50 hilos están atrapados en espera no interrumpible de disco (`TASK_UNINTERRUPTIBLE`) debido a un montaje NFS colgado o una cabina SAN fallida.

### 1.3 System Activity Data Collector Framework (`sysstat`)
La suite `sysstat` proporciona monitoreo histórico de capacidad a través de la recolección de datos en segundo plano:
- `sadc` (System Activity Data Collector): Motor de muestreo binario de alto rendimiento que consulta los contadores `/proc` del kernel y escribe estructuras de datos binarias crudas en archivos ubicados en `/var/log/sa/saDD` (donde `DD` es el día del mes).
- `sa1`: Shell script wrapper que invoca `sadc` para la recolección binaria periódica en segundo plano a través de `cron` o `systemd.timer`.
- `sa2`: Shell script wrapper que invoca `sar` para generar reportes de texto diarios legibles por humanos (`/var/log/sa/sarDD`).
- `sadf`: Utilidad para extraer logs binarios de `sadc` a formatos de datos estructurados (CSV, JSON, XML, SVG) para el procesamiento automatizado de baselines y pronósticos de tendencias (trend forecasting).

---

## 2. Guided Production Exercises

### Exercise 1: Low-Level Kernel Counter Extraction via `/proc`

#### Objetivo
Extraer estadísticas crudas del kernel directamente desde `procfs` para calcular manualmente la utilización de la CPU sin depender de wrappers de alto nivel.

#### Pasos de ejecución

1. Leer las dos primeras capturas de muestreo de CPU desde `/proc/stat` separadas por un intervalo de 1 segundo:
```bash
head -n 1 /proc/stat; sleep 1; head -n 1 /proc/stat
```

*Salida CLI esperada:*
```text
cpu  124850 120 45210 8920140 12500 0 1420 0 0 0
cpu  124890 120 45230 8920210 12510 0 1422 0 0 0
```

2. Analizar las métricas de memoria desde `/proc/meminfo` para evaluar la capacidad de memoria disponible vs page cache:
```bash
egrep "MemTotal|MemFree|MemAvailable|Buffers|^Cached|SwapTotal|SwapFree" /proc/meminfo
```

*Salida CLI esperada:*
```text
MemTotal:       16378440 kB
MemFree:         2145892 kB
MemAvailable:   11842016 kB
Buffers:          342104 kB
Cached:          9845120 kB
SwapTotal:       4194300 kB
SwapFree:        4194300 kB
```

3. Consultar las estadísticas crudas de disco para el dispositivo de bloque primario (`sda` o `nvme0n1`):
```bash
grep -E "sda|nvme0n1 " /proc/diskstats
```

*Salida CLI esperada:*
```text
   8       0 sda 45210 1204 3840120 18450 95410 4501 8940120 145020 0 45100 163470
```

#### Preguntas de verificación (Ejercicio 1)

1. En `/proc/meminfo`, ¿por qué `MemAvailable` es significativamente mayor que `MemFree`? ¿Qué regiones de memoria están incluidas en `MemAvailable` que están excluidas de `MemFree`?
2. Si los campos de `/proc/stat` son: `cpu user nice system idle iowait irq softirq steal guest guest_nice`, escriba la fórmula matemática para calcular el porcentaje delta de CPU Ocupada ($\% \text{CPU}_{\text{busy}}$) entre la captura $t_1$ y la captura $t_2$.

---

### Exercise 2: CPU & Memory Bottleneck Analysis using `vmstat` and `free`

#### Objetivo
Analizar el comportamiento de la cola de hilos, el paginado de memoria, la presión de swapping y la distribución de estados de CPU para diagnosticar puntos de saturación de hardware.

#### Pasos de ejecución

1. Ejecutar `vmstat` en modo delay-count (muestreo de 1 segundo, 5 iteraciones):
```bash
vmstat -S M 1 5
```

*Salida CLI esperada:*
```text
procs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
 3  1      0   2095    334   9614    0    0    12   140 1200 4500 65 25  5  5  0
 4  0      0   2091    334   9614    0    0     0     0 1350 4800 70 28  2  0  0
 2  2      0   2080    334   9614    0    0   450  1200 2100 8900 40 30  5 25  0
 5  0      0   2075    334   9614    0    0     0     0 1400 5100 75 25  0  0  0
 1  0      0   2070    334   9614    0    0     0     0 1100 4200 60 20 20  0  0
```

2. Ejecutar `free` con formato legible por humanos y modo de salida extendido (wide output):
```bash
free -h -w
```

*Salida CLI esperada:*
```text
               total        used        free      shared     buffers      cache   available
Mem:            15Gi       3.8Gi       2.0Gi       128Mi       334Mi       9.3Gi        11Gi
Swap:          4.0Gi          0B       4.0Gi
```

3. Mostrar el estado de la cola de procesos y el conteo de hilos usando `pstree` y `top` en modo batch:
```bash
top -b -n 1 | head -n 5
```

*Salida CLI esperada:*
```text
top - 08:15:02 up 45 days, 12:34,  2 users,  load average: 4.12, 3.85, 3.50
Tasks: 312 total,   3 running, 309 sleeping,   0 stopped,   0 zombie
%Cpu(s): 68.2 us, 24.1 sy,  0.0 ni,  2.5 id,  5.2 wa,  0.0 hi,  0.0 si,  0.0 st
MiB Mem :  15994.5 total,   2095.1 free,   3942.3 used,  10283.4 buff/cache
MiB MiB Swap:  4096.0 total,   4096.0 free,      0.0 used.  11564.4 avail Mem 
```

#### Preguntas de verificación (Ejercicio 2)

1. En un sistema con 4 núcleos de CPU lógicos ejecutando la carga de trabajo de `vmstat` mostrada en el Paso 1, línea 4 (`r=5, b=0, us=75, sy=25, id=0, wa=0`), ¿el sistema está limitado por CPU (CPU-bound), limitado por I/O (I/O-bound) o limitado por Memoria (Memory-bound)? Justifique su diagnóstico utilizando métricas específicas de las columnas `r`, `us`, `sy` e `id`.
2. Diferencie entre `si`/`so` (swap-in/swap-out) y `bi`/`bo` (block-in/block-out) en `vmstat`. ¿Qué conjunto de métricas indica una agotamiento severo de memoria que conduce a un thrashing activo?

---

### Exercise 3: Storage Subsystem Performance & Bottleneck Diagnosis via `iostat`

#### Objetivo
Evaluar el rendimiento de lectura/escritura de dispositivos de bloque, la longitud de la cola de solicitudes, los tiempos de espera promedio y la utilización del dispositivo para detectar cuellos de botella de almacenamiento.

#### Pasos de ejecución

1. Ejecutar `iostat` mostrando estadísticas extendidas (`-x`), megabytes por segundo (`-m`), suprimiendo dispositivos inactivosa (`-z`) a intervalos de 1 segundo durante 4 reportes:
```bash
iostat -xmz 1 4
```

*Salida CLI esperada:*
```text
Linux 5.15.0-105-generic (node-prod-01) 	08/06/2026 	_x86_64_	(8 CPU)

Device            r/s     w/s     rMB/s     wMB/s   rrqm/s   wrqm/s  %rrqm  %wrqm r_await w_await aqu-sz  rareq-sz  wareq-sz  svctm  %util
sda             12.00  450.00      0.15     35.20     0.00    25.00   0.00   5.26    1.20   45.80   20.7    12.80     80.10   2.16  100.00
sdb              0.00    0.00      0.00      0.00     0.00     0.00   0.00   0.00    0.00    0.00    0.00    0.00      0.00   0.00    0.00

Device            r/s     w/s     rMB/s     wMB/s   rrqm/s   wrqm/s  %rrqm  %wrqm r_await w_await aqu-sz  rareq-sz  wareq-sz  svctm  %util
sda              5.00  510.00      0.06     42.10     0.00    30.00   0.00   5.56    0.80   52.40   26.8    12.00     84.50   1.96  100.00
```

2. Inspeccionar el historial de actividad de disco en `sar` (`sar -d`) para correlacionar las métricas actuales con el rendimiento pasado:
```bash
sar -d 1 2
```

*Salida CLI esperada:*
```text
Linux 5.15.0-105-generic (node-prod-01) 	08/06/2026 	_x86_64_	(8 CPU)

08:15:10 AM       DEV       tps  rd_sec/s  wr_sec/s  avgrq-sz  avgqu-sz     await     svctm     %util
08:15:11 AM  dev8-0    462.00    300.00  72080.00    156.67     20.70     44.64      2.16    100.00
08:15:12 AM  dev8-0    515.00    120.00  86220.00    167.65     26.80     51.91      1.94    100.00
Average:     dev8-0    488.50    210.00  79150.00    162.46     23.75     48.47      2.05    100.00
```

#### Preguntas de verificación (Ejercicio 3)

1. En la salida de `iostat` anterior, `sda` exhibe `%util = 100.00%`, `w_await = 52.40ms` y `aqu-sz = 26.8`. ¿Está `sda` experimentando saturación de almacenamiento? ¿Qué revela la discrepancia entre `r_await` (0.80ms) y `w_await` (52.40ms) sobre la carga de trabajo de escritura?
2. ¿Por qué el hecho de que `%util` alcance el $100\%$ es una métrica poco confiable para determinar la saturación real en dispositivos de almacenamiento NVMe multi-cola modernos o arrays RAID enterprise?

---

### Exercise 4: Network Socket Capacity & Interface Queue Saturation

#### Objetivo
Medir el rendimiento de la interfaz de red, detectar caídas/errores de paquetes y evaluar los límites de asignación de sockets del kernel.

#### Pasos de ejecución

1. Ejecutar `sar` para monitorear el tráfico de la interfaz de red (`DEV`) a intervalos de 1 segundo:
```bash
sar -n DEV 1 3
```

*Salida CLI esperada:*
```text
Linux 5.15.0-105-generic (node-prod-01) 	08/06/2026 	_x86_64_	(8 CPU)

08:20:01 AM     IFACE   rxpck/s   txpck/s    rxkB/s    txkB/s   rxcmp/s   txcmp/s  rxmcst/s   %ifutil
08:20:02 AM        lo     12.00     12.00      0.85      0.85      0.00      0.00      0.00      0.00
08:20:02 AM    eth0   85400.00  92100.00  118500.20 131200.50      0.00      0.00      0.00     94.50

08:20:02 AM     IFACE   rxpck/s   txpck/s    rxkB/s    txkB/s   rxcmp/s   txcmp/s  rxmcst/s   %ifutil
08:20:03 AM    eth0   88900.00  94500.00  124100.80 135800.10      0.00      0.00      0.00     97.80
```

2. Monitorear las estadísticas de descarte de paquetes de la interfaz (`EDEV`):
```bash
sar -n EDEV 1 2
```

*Salida CLI esperada:*
```text
Linux 5.15.0-105-generic (node-prod-01) 	08/06/2026 	_x86_64_	(8 CPU)

08:20:05 AM     IFACE   rxerr/s   txerr/s    coll/s  rxdrop/s  txdrop/s  txcarr/s  rxfram/s  rxfifo/s  txfifo/s
08:20:06 AM    eth0      0.00      0.00      0.00    420.00      0.00      0.00      0.00    420.00      0.00
```

3. Inspeccionar el resumen y la asignación global de memoria de sockets utilizando `ss`:
```bash
ss -s
```

*Salida CLI esperada:*
```text
Total: 1450
TCP:   3210 (estab 2850, closed 120, orphaned 40, timewait 200)

Transport Total     IP        IPv6
RAW	      1         1         0
UDP	      8         5         3
TCP	      3090      3080      10
INET	  3099      3086      13
FRAG	  0         0         0
```

#### Preguntas de verificación (Ejercicio 4)

1. En la salida de `sar -n EDEV` anterior, `eth0` muestra `rxdrop/s = 420.00` y `rxfifo/s = 420.00`, mientras que `rxerr/s = 0.00`. ¿Qué componente del kernel o ring buffer de hardware está fallando y qué parámetro requiere ajuste (tuning)?
2. Si la velocidad del enlace de `eth0` es de 1 Gbps (Full-Duplex), calcule el porcentaje de utilización de capacidad de red cuando `rxkB/s = 118500.20` y `txkB/s = 131200.50`.

---

### Exercise 5: Automated Baseline Extraction & Capacity Forecasting with `sar` and `sadf`

#### Objetivo
Procesar logs binarios de datos de actividad del sistema (`/var/log/sa/saDD`) para extraer baselines históricos, exportar métricas en CSV y extrapolar tendencias de crecimiento de recursos.

#### Pasos de ejecución

1. Analizar el archivo binario histórico del día 05 (`/var/log/sa/sa05`) y volcar los datos de utilización de CPU en formato CSV utilizando `sadf`:
```bash
sadf -d /var/log/sa/sa05 -- -u | head -n 6
```

*Salida CLI esperada:*
```text
# node-prod-01;interval;timestamp;CPU;%user;%nice;%system;%iowait;%steal;%idle
node-prod-01;600;2026-08-05 00:00:01 UTC;-1;12.40;0.00;3.20;0.50;0.00;83.90
node-prod-01;600;2026-08-05 00:10:01 UTC;-1;14.10;0.00;3.50;0.40;0.00;82.00
node-prod-01;600;2026-08-05 00:20:01 UTC;-1;18.50;0.00;4.10;0.80;0.00;76.60
node-prod-01;600;2026-08-05 00:30:01 UTC;-1;25.80;0.00;5.20;1.20;0.00;67.80
```

2. Extraer métricas estructuradas en JSON para el uso de memoria y swap para alimentarlas en un pipeline automatizado de pronóstico de capacidad (capacity forecasting):
```bash
sadf -j /var/log/sa/sa05 -- -r | jq '.sysstat.hosts[0].statistics[0]'
```

*Salida CLI esperada:*
```json
{
  "timestamp": {
    "date": "2026-08-05",
    "time": "00:00:01",
    "utc": 1
  },
  "memory": {
    "memfree": 2145892,
    "avail": 11842016,
    "bufutil": 342104,
    "camem": 9845120,
    "kbswpfree": 4194300,
    "kbswpused": 0
  }
}
```

3. Generar un reporte diario consolidado en formato de texto mediante la invocación manual de `sa2`:
```bash
/usr/lib/sysstat/sa2 -A
ls -l /var/log/sa/sar06
```

*Salida CLI esperada:*
```text
-rw-r--r-- 1 root root 245120 Aug  6 08:30 /var/log/sa/sar06
```

#### Preguntas de verificación (Ejercicio 5)

1. ¿Cuál es la diferencia en rol y formato de archivo de salida entre `/usr/lib/sysstat/sa1` y `/usr/lib/sysstat/sa2`?
2. Un equipo SRE observa que el consumo pico de RAM crece 450 MB cada semana. Especificaciones actuales del nodo: 32 GB de RAM total, 6 GB reservados para SO/agentes, consumo pico actual de aplicaciones en 20 GB. ¿Cuántas semanas quedan antes de que el nodo supere la capacidad operativa segura ($85\%$ de la RAM física total)?

---

## 3. Official References & Documentation
- **LPI LPIC-2 Detailed Objectives (Topic 201.1):** [https://www.lpi.org/our-certifications/lpic-2-overview/](https://www.lpi.org/our-certifications/lpic-2-overview/)
- **Linux Kernel Documentation — `/proc/stat` & `/proc/meminfo`:** [https://www.kernel.org/doc/html/latest/filesystems/proc.html](https://www.kernel.org/doc/html/latest/filesystems/proc.html)
- **Linux Kernel Documentation — Block Layer Diskstats:** [https://www.kernel.org/doc/html/latest/admin-guide/iostats.html](https://www.kernel.org/doc/html/latest/admin-guide/iostats.html)
- **Sysstat / `sar` Manual Pages:** [https://sysstat.github.io/](https://sysstat.github.io/)

---

## 4. Comprehensive Answer Key

<details>
<summary><strong>Haz clic aquí para desplegar el Solucionario de los Ejercicios 1–5</strong></summary>

### Exercise 1 Answers

1. **Mecánica de `MemAvailable` vs `MemFree`:**
   - `MemFree` representa páginas de RAM física totalmente no asignadas e intactas.
   - `MemAvailable` es una estimación de cuánta memoria está disponible para iniciar nuevas aplicaciones sin recurrir a swap. Incluye `MemFree` MÁS los pools de memoria recuperables: el Page Cache (`Cached`), los buffers de memoria (`Buffers`) y las asignaciones recuperables de slab del kernel (`SReclaimable`), menos los umbrales de marcas de agua mínimas (`wmark_low`) reservadas por el kernel para prevenir deadlocks por Out-Of-Memory (OOM).

2. **Cálculo del Delta de Utilización de CPU:**
   $$\text{TotalTicks} = \text{user} + \text{nice} + \text{system} + \text{idle} + \text{iowait} + \text{irq} + \text{softirq} + \text{steal}$$
   $$\Delta \text{TotalTicks} = \text{TotalTicks}(t_2) - \text{TotalTicks}(t_1)$$
   $$\Delta \text{IdleTicks} = (\text{idle}(t_2) + \text{iowait}(t_2)) - (\text{idle}(t_1) + \text{iowait}(t_1))$$
   $$\% \text{CPU}_{\text{busy}} = \left( 1 - \frac{\Delta \text{IdleTicks}}{\Delta \text{TotalTicks}} \right) \times 100$$
   *Utilizando los valores de las capturas:*
   - $t_1$: $\text{Total} = 124850 + 120 + 45210 + 8920140 + 12500 + 0 + 1420 + 0 = 9104240$
   - $t_2$: $\text{Total} = 124890 + 120 + 45230 + 8920210 + 12510 + 0 + 1422 + 0 = 9104602$
   - $\Delta \text{Total} = 362$ ticks.
   - $\Delta \text{Idle} = (8920210 + 12510) - (8920140 + 12500) = 70 + 10 = 80$ ticks.
   - $\% \text{CPU}_{\text{busy}} = \left(1 - \frac{80}{362}\right) \times 100 = 77.9\%$

---

### Exercise 2 Answers

1. **Diagnóstico de Saturación del Sistema:**
   - **Diagnóstico:** El sistema está limitado por CPU (**CPU-bound**).
   - **Justificación:**
     - La cola de ejecución (`r = 5`) excede el número total de núcleos de CPU lógicos ($4$). Esto demuestra que los hilos ejecutables están haciendo cola de manera activa, esperando la asignación de su slice de CPU.
     - La utilización total de la CPU está en el $100\%$ ($us=75\% + sy=25\%$), con $id=0\%$ (idle) y $wa=0\%$ (iowait). 
     - El estado de procesos bloqueados es $b=0$, descartando cuellos de botella de I/O de disco o red.

2. **Diferencia entre `si`/`so` y `bi`/`bo`:**
   - `bi`/`bo` (Block In / Block Out) miden operaciones normales de lectura/escritura de I/O del sistema de archivos desde/hacia dispositivos de bloque en KB/s (por ejemplo, lecturas de base de datos, escrituras de logs).
   - `si`/`so` (Swap In / Swap Out) miden páginas de RAM física que se mueven desde o hacia la partición swap en disco debido a la presión de memoria.
   - **Impacto:** Un valor no nulo en `si`/`so` indica que la demanda de memoria anónima (Anonymous memory) excede la capacidad de la RAM física. El swapping activo provoca que las llamadas de acceso a memoria a nivel de microsegundos caigan a latencias de disco a nivel de milisegundos (thrashing activo), degradando gravemente la capacidad de respuesta del sistema.

---

### Exercise 3 Answers

1. **Cuello de Botella de Almacenamiento y Discrepancia de Latencia:**
   - **Estado de saturación:** Sí, `sda` está completamente saturado. Una alta profundidad de cola de disco (`aqu-sz = 26.8`) combinada con altos tiempos de espera de escritura (`w_await = 52.40ms`) y `%util = 100%` demuestra que el subsistema de I/O no puede procesar las operaciones de escritura entrantes lo suficientemente rápido.
   - **Discrepancia de Latencia (`r_await` 0.80ms vs `w_await` 52.40ms):** Las lecturas toman menos de 1ms porque están golpeando el cache del controlador de almacenamiento de hardware o buffers de estado sólido, o porque el I/O scheduler (`bfq`/`mq-deadline`) prioriza las operaciones de lectura. Las escrituras sufren el respaldo en la cola (`aqu-sz`), indicando que el vaciado de páginas sucias (dirty page flushing) abrumó el ancho de banda de escritura del medio físico ($35–42\text{ MB/s}$).

2. **Limitaciones de `%util` en NVMe / Arrays:**
   - La métrica `%util` en `iostat` mide el porcentaje de tiempo de reloj (wall-clock time) durante el cual *al menos una* solicitud de I/O estuvo en vuelo en el dispositivo de bloque ($t_{\text{busy}} / t_{\text{total}}$).
   - Los discos giratorios tradicionales (HDDs) procesan solicitudes secuencialmente (profundidad de cola única = 1), por lo que $100\%$ de utilización implica estrictamente la saturación del medio.
   - Los dispositivos NVMe modernos y las cabinas de almacenamiento enterprise admiten colas múltiples por hardware (por ejemplo, hasta 64.000 colas paralelas con 64.000 comandos por cola). Un disco NVMe procesando 1 solicitud continuamente reportará `%util = 100%`, aunque tenga la capacidad de procesamiento paralelo para manejar miles de operaciones de I/O concurrentes sin incrementar la latencia.

---

### Exercise 4 Answers

1. **Análisis de Caída de Colas de Red (Network Queue Drop Analysis):**
   - **Componente Fallido:** El Receive Ring Buffer (Rx Ring Buffer) de hardware de la tarjeta de red (NIC) o la cola de recepción de sockets del kernel (Kernel Socket Receive Queue / buffer FIFO) se está desbordando.
   - **Acción de Tuning:** 
     1. Incrementar los tamaños de los ring buffers de hardware usando `ethtool -G eth0 rx <max_value>`.
     2. Incrementar los límites máximos del buffer de recepción de sockets del kernel vía `sysctl` (`net.core.rmem_max`, `net.core.netdev_max_backlog`).

2. **Cálculo de la Capacidad de Ancho de Banda de Red:**
   - Rendimiento total en KB/s: $118500.20 + 131200.50 = 249700.70 \text{ KB/s}$.
   - Convertir a Megabits por segundo (Mbps):
     $$\text{Mbps} = \frac{249700.70 \text{ KB/s} \times 8 \text{ bits/byte}}{1000} = 1997.60 \text{ Mbps}$$
   - *Nota sobre Full-Duplex:* En un enlace 1 Gbps Full-Duplex se soporta 1000 Mbps RX y 1000 Mbps TX de manera independiente (capacidad teórica combinada de 2000 Mbps).
   - Dirección TX: $131200.50 \text{ KB/s} \times 8 / 1000 = 1049.6 \text{ Mbps}$, lo cual supera la capacidad del enlace de 1000 Mbps (indicando saturación a tasa de línea, lo que causa descarte de paquetes y colas).
   - Utilización de la interfaz en relación con la tasa de línea unidireccional de 1 Gbps: $\frac{1049.6}{1000} \times 100\% = 104.9\%$ (Saturada; contabilizando el overhead de tramas).

---

### Exercise 5 Answers

1. **Arquitectura `sa1` vs `sa2`:**
   - `sa1` es un script wrapper interno de recolección binaria que llama a `sadc` para adjuntar las métricas actuales del sistema al archivo de log binario `/var/log/sa/saDD`. Produce datos binarios ilegibles por utilidades de texto estándar.
   - `sa2` es un script de generación de reportes que invoca a `sar` para leer el archivo binario diario `/var/log/sa/saDD` y generar un resumen diario consolidado de texto legible por humanos guardado en `/var/log/sa/sarDD`.

2. **Cálculo de Pronóstico de Capacidad:**
   - RAM física total = $32 \text{ GB}$.
   - Umbral máximo seguro de capacidad ($85\%$):
     $$\text{Umbral Máximo Seguro} = 32 \text{ GB} \times 0.85 = 27.2 \text{ GB}$$
   - Consumo pico actual = $20 \text{ GB}$.
   - Margen de crecimiento restante (Headroom):
     $$\text{Margen (Headroom)} = 27.2 \text{ GB} - 20.0 \text{ GB} = 7.2 \text{ GB} = 7372.8 \text{ MB}$$
   - Tasa de crecimiento semanal = $450 \text{ MB/semana}$.
   - Tiempo hasta la saturación:
     $$\text{Semanas} = \frac{7372.8 \text{ MB}}{450 \text{ MB/semana}} = 16.38 \text{ semanas}$$
   - **Resultado:** Quedan exactamente **16 semanas** antes de que el sistema supere el techo operativo seguro del $85\%$, requiriendo mejoras de hardware o reequilibrio de cargas de trabajo.

</details>