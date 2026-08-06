# Examen LPIC-2 201-450: Tema 201.1 — Planificación de Capacidad (Peso: 7)

---

## 1. Motivación y Problema Arquitectónico de Producción

### 1.1 La Física de los Subsystems de Recursos del Kernel de Linux

La planificación de capacidad en entornos Linux empresariales requiere comprender cómo el kernel de Linux gestiona los recursos de hardware del sistema bajo carga. En lugar de ver CPU, Memory, Disk I/O y Network I/O como contenedores aislados y estáticos, un Platform Architect debe analizar el consumo de recursos a través del prisma de las interacciones de los subsystems del kernel y la dinámica de colas.

```
                         +-----------------------------------+
                         |         Application Layer         |
                         +-----------------------------------+
                                   |                 |
                   Syscalls (read/write/mmap)   Socket Syscalls (send/recv)
                                   |                 |
                                   v                 v
+------------------------------------+   +------------------------------------+
|         Page Cache Subsystem       |   |       Network Stack Subsystem      |
|  - Inode & Dentry Cache            |   |  - Socket Receive/Send Buffers     |
|  - Writeback Threads (flusher)     |   |  - SYN Backlog & Accept Queue      |
+------------------------------------+   +------------------------------------+
                   |                                 |
                   v                                 v
+------------------------------------+   +------------------------------------+
|          Block I/O Layer           |   |       Network Device Driver        |
|  - I/O Schedulers (mq-deadline/bfq)|   |  - Ring Buffers (RX/TX)            |
|  - Request Queues & Bio Structs    |   |  - NAPI & SoftIRQ Processing       |
+------------------------------------+   +------------------------------------+
                   |                                 |
                   v                                 v
+------------------------------------+   +------------------------------------+
|        Storage Hardware (NVMe)     |   |       Network Hardware (NIC)       |
+------------------------------------+   +------------------------------------+
```

#### Mecánica de Scheduling de CPU
El Completely Fair Scheduler (CFS) y el scheduler EEVDF (Earliest Eligible Virtual Deadline First) dividen el tiempo de CPU utilizando el runtime virtual (`vruntime`).
* Cuando la demanda de CPU supera los ciclos de ejecución de los cores disponibles, las runqueues de tareas crecen (estadística `r` en `vmstat`).
* El overhead de context switching aumenta (`cs`), haciendo que el tiempo de CPU se desplace de la ejecución de usuario (`us`) al overhead del kernel (`sy`).
* Si las tareas pasan un tiempo excesivo esperando en las runqueues, la degradación de latencia se compone de forma no lineal.

#### Dinámica de Memoria y Page Cache
El Virtual Memory Manager (VMM) de Linux optimiza la utilización de la memoria asignando RAM no utilizada al **Page Cache**, realizando caching de las operaciones de lectura/escritura de archivos.
* **Active List vs. Inactive List:** El kernel gestiona páginas a través de listas de Least Recently Used (LRU).
* **Direct Reclaim vs. Kswapd:** Cuando la memoria libre cae por debajo de la marca de agua `vm.min_free_kbytes`, el daemon del kernel `kswapd` se despierta de forma asíncrona para liberar páginas inactivas. Si la velocidad de asignación supera el throughput de `kswapd`, los threads en primer plano entran en **Direct Reclaim**, experimentando pausas de ejecución de submilisegundos mientras liberan o intercambian (swap) memoria de forma síncrona.

#### Capa de Storage Block I/O
El acceso al almacenamiento fluye a través del VFS (Virtual File System) hacia las colas de la capa de bloques (block layer).
* Las solicitudes de escritura se almacenan en búfer en la memoria del dirty page cache hasta que `vm.dirty_background_ratio` dispara threads de flush asíncronos en segundo plano, o `vm.dirty_ratio` fuerza escrituras síncronas de bloques a nivel de proceso.
* Las profundidades de cola elevadas (`avgqu-sz` en `iostat`) conducen a tiempos de espera elevados (`await`), provocando que los threads que esperan la finalización de I/O de bloques entren en estado Uninterruptible Sleep (estadística `b` en `vmstat`, estado `D` en `ps`).

#### Mecánica de Socket Buffers de Red
Los tramas de red (frames) pasan del ring buffer de hardware de la Network Interface Card (NIC) a los socket buffers del kernel (`rmem`/`wmem`).
* Los cuellos de botella en el procesamiento de aplicaciones causan el llenado de los socket receive buffers, desencadenando alertas de TCP Window Zero y paquetes descartados (dropped packets) en la capa de transporte.
* Si las colas de TCP listen del kernel (`somaxconn`) se desbordan, los paquetes `SYN` o `ACK` entrantes se descartan silenciosamente, aumentando la latencia de establecimiento de conexión.

---

### 1.2 Modos de Falla Arquitectónicos Bajo Carga de Capacidad No Presupuestada

Cuando se superan los límites de capacidad del sistema sin un aislamiento proactivo, los sistemas experimentan transiciones de estado catastróficas:

1. **Invocación de OOM en Cascadas y Thrashing:**
   Cuando se agota la memoria libre y el page cache inactivo no se puede desalojar lo suficientemente rápido, el kernel invoca `out_of_memory()`. El OOM killer calcula el `oom_score` basándose en reglas heurísticas de badness y envía `SIGKILL` a los procesos objetivo. Si la presión de memoria se mantiene alta, la terminación continua de procesos resulta en una pérdida de disponibilidad del servicio.

2. **Page Cache Churn y Picos de Latencia por Direct Reclaim:**
   Las cargas de trabajo excesivas de escritura de archivos sin límites de memoria fuerzan altas tasas de generación de dirty pages. El host alcanza `vm.dirty_ratio`, deteniendo los threads de usuario para forzar el flush de bloques sucios. Concurrentemente, las asignaciones de memoria entran en Direct Reclaim, aumentando la latencia de ejecución por órdenes de magnitud.

3. **Bufferbloat y Agotamiento de Sockets:**
   Las colas de socket sin límites provocan bufferbloat, lo que añade latencia sin mejorar el throughput. Cuando los conteos de sockets abiertos superan los límites del sistema `fs.file-max` o del proceso `ulimit -n`, las aplicaciones no logran asignar file descriptors (errores `EMFILE`/`ENFILE`), causando una falla completa del servicio.

---

### 1.3 Matemáticas de Planificación de Capacidad

Los Platform Architects evalúan la capacidad utilizando modelos matemáticos formales para proyectar el escalado de recursos:

#### Ley de Little
Calcula la concurrencia promedio dentro de un sistema en estado estable:

$$L = \lambda \times W$$

Donde:
* $L$ = Número promedio de solicitudes en el sistema (Concurrencia)
* $\lambda$ = Tasa de llegada de solicitudes (Throughput, req/seg)
* $W$ = Tiempo promedio que pasa una solicitud en el sistema (Latencia / Tiempo de Servicio, segundos)

#### Ley de Escalabilidad Universal (USL)
Modela los límites de escalabilidad incluyendo contención ($\sigma$) y overhead de diafonía / sincronización ($\kappa$):

$$X(N) = \frac{\lambda N}{1 + \sigma(N - 1) + \kappa N(N - 1)}$$

Donde:
* $X(N)$ = Throughput relativo en el factor de escala $N$
* $N$ = Número de recursos de hardware / CPU cores
* $\sigma$ = Parámetro de contención del sistema (cuello de botella de encolado serial)
* $\kappa$ = Parámetro de penalización de coherencia (overhead de intercambio de datos inter-nodo)

#### Extrapolación Lineal para Agotamiento de Recursos
Para estimar el tiempo de agotamiento $T_{exhaust}$ para la capacidad de disco o uso de memoria dada la pendiente de crecimiento histórico $m$ y la línea base $c$:

$$Y(t) = m \cdot t + c \implies T_{exhaust} = \frac{Capacity_{Max} - c}{m}$$

---

## 2. Tablas de Comparación Técnica y Trade-offs

### 2.1 Arquitecturas de Recolección de Métricas

| Parámetro / Característica | Arquitectura Basada en Pull (ej., Prometheus) | Arquitectura Basada en Push (ej., collectd, Telegraf, SNMP) | Registro Histórico en Archivos (ej., sysstat / sar) |
| :--- | :--- | :--- | :--- |
| **Modelo de Ingesta de Datos** | El colector central realiza polling a los endpoints HTTP `/metrics` del objetivo. | El agente en el cliente transmite activamente datos al endpoint remoto. | El cron de interrupción del kernel local añade binarios al almacenamiento local. |
| **Perfil de Tráfico de Red** | Intervalos de polling controlados y deterministas. | Picos no controlados si la cola de métricas se vacía simultáneamente en toda la flota. | Cero overhead de red; estrictamente operaciones de escritura de archivos locales (`/var/log/sysstat/`). |
| **Overhead Central** | Huella de memoria alta para el índice de series temporales (TSDB). | El colector del endpoint debe manejar concurrencia de ingreso a ráfagas (bursty). | Cero overhead de colector central; almacenamiento descentralizado. |
| **Detección de Disponibilidad del Objetivo** | Nativo: Un scrape fallido marca inmediatamente al objetivo como `up == 0`. | Difícil: Requiere alertas por silencio (lógica de dead man's switch). | N/A (Herramienta local de auditoría de archivos). |
| **Idoneidad para Planificación de Capacidad** | Excelente para tendencias de escalado dinámico de servicios cloud-native. | Ideal para trabajos ephemeral en lotes (batch jobs) y entornos edge. | Esencial para análisis post-mortem profundo de nodos bare-metal. |

---

### 2.2 Control Groups: Cgroups v1 vs. Cgroups v2

| Característica / Subsystem | Cgroups v1 (Legacy) | Cgroups v2 (Jerarquía Unificada) |
| :--- | :--- | :--- |
| **Modelo de Jerarquía** | Multi-jerarquía: Árboles controladores independientes (`/sys/fs/cgroup/cpu`, `/sys/fs/cgroup/memory`). | Árbol de jerarquía unificada único (`/sys/fs/cgroup/`). |
| **Control a Nivel de Thread** | Soportado en controladores arbitrarios; propenso a race conditions. | Orientado a procesos por defecto; regla estricta de controlador sub-árbol (`cgroup.procs`). |
| **Métricas de Control de Memoria** | `memory.limit_in_bytes`, el límite estricto (hard limit) fuerza la invocación inmediata de OOM. | `memory.high` (limita/libera gradualmente), `memory.max` (límite estricto). |
| **Alcance de Out-Of-Memory** | Falla de asignación por contenedor; afecta impredeciblemente a threads hijos. | `memory.oom.group` permite matar todos los procesos en el cgroup de forma atómica. |
| **Integración de Control de I/O** | El controlador de I/O no detecta el Page Cache; las escrituras en búfer ignoran los límites. | Seguimiento unificado completo: Las escrituras sucias en búfer se mapean directamente al cgroup de origen. |

---

### 2.3 Resolución de Métricas vs. Overhead de Almacenamiento

| Perfil de Resolución | Intervalo de Scrape | Período de Retención | Almacenamiento por Nodo de Métrica / Mes | Caso de Uso |
| :--- | :--- | :--- | :--- | :--- |
| **Ultra Alta** | 1 segundo | 7 Días | ~150 GB | Detección de micro-bursts, diagnóstico de picos de latencia en tiempo real. |
| **Estándar de Producción**| 15 segundos | 90 Días | ~40 GB | Planificación de capacidad estándar, seguimiento de tendencias de SLI/SLO. |
| **Agregado a Largo Plazo**| 5 minutos (downsampled)| 2 Años | ~5 GB | Escalado de infraestructura a varios años y presupuestación de adquisición de hardware. |

---

## 3. Archivos de Configuración Completos y Manifests de Infraestructura

### 3.1 Configuración Avanzada de `/etc/collectd.conf`

```c
# /etc/collectd.conf - Syntactically complete Production Metrics Collection Configuration
Hostname "node-prod-app-01.internal.net"
FQDNLookup true
BaseDir "/var/lib/collectd"
PIDFile "/var/run/collectd.pid"
PluginDir "/usr/lib/x86_64-linux-gnu/collectd"
TypesDB "/usr/share/collectd/types.db"

Interval 10
Timeout 2
ReadThreads 5
WriteThreads 5

LoadPlugin logfile
<Plugin logfile>
    LogLevel "info"
    File "/var/log/collectd.log"
    Timestamp true
    PrintSeverity true
</Plugin>

LoadPlugin cpu
LoadPlugin memory
LoadPlugin df
LoadPlugin disk
LoadPlugin interface
LoadPlugin load
LoadPlugin processes
LoadPlugin swap
LoadPlugin network

<Plugin cpu>
    ReportByCpu true
    ReportByState true
    ValuesPercentage true
</Plugin>

<Plugin memory>
    ValuesAbsolute true
    ValuesPercentage true
</Plugin>

<Plugin df>
    Device "/dev/mapper/vg0-root"
    Device "/dev/nvme0n1p2"
    MountPoint "/"
    MountPoint "/var/log"
    FSType "ext4"
    FSType "xfs"
    IgnoreSelected false
    ReportBytes true
    ValuesPercentage true
</Plugin>

<Plugin disk>
    Disk "/^nvme[0-9]n[0-9]$/"
    Disk "/^sd[a-z]$/"
    IgnoreSelected false
</Plugin>

<Plugin interface>
    Interface "eth0"
    Interface "bond0"
    IgnoreSelected false
</Plugin>

<Plugin processes>
    Process "java"
    Process "nginx"
    Process "mysqld"
</Plugin>

<Plugin network>
    <Server "10.100.50.25" "25826">
        SecurityLevel "Encrypt"
        Username "collectd_agent"
        Password "Secr3tClusterPassw0rd!"
    </Server>
    BufferSize 1452
    Forward false
</Plugin>
```

---

### 3.2 Configuración de Reglas de Alerting y Scrape de `prometheus.yml` para Producción

#### Archivo de Scrape (`/etc/prometheus/prometheus.yml`)
```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  scrape_timeout: 10s

rule_files:
  - "/etc/prometheus/rules/capacity_alerts.yml"

scrape_configs:
  - job_name: "node_exporter"
    static_configs:
      - targets:
          - "10.100.50.11:9100"
          - "10.100.50.12:9100"
          - "10.100.50.13:9100"
    relabel_configs:
      - source_labels: [__address__]
        regex: "(.*):9100"
        target_label: "instance"
        replacement: "${1}"

  - job_name: "cadvisor"
    static_configs:
      - targets:
          - "10.100.50.11:8080"
          - "10.100.50.12:8080"
```

#### Reglas de Alerting (`/etc/prometheus/rules/capacity_alerts.yml`)
```yaml
groups:
  - name: InfrastructureCapacityAlerts
    rules:
      - alert: DiskCapacityExhaustionPrediction
        expr: (predict_linear(node_filesystem_free_bytes{fstype!=""}[4h], 86400 * 7) < 0)
        for: 15m
        labels:
          severity: critical
          team: platform-sre
        annotations:
          summary: "Disk space predicted to run out within 7 days on {{ $labels.instance }}"
          description: "Filesystem {{ $labels.mountpoint }} on {{ $labels.instance }} will reach 100% capacity based on 4-hour trend."

      - alert: HighCPURunqueueSaturation
        expr: (node_load1 / count by(instance)(node_cpu_seconds_total{mode="idle"})) > 2.0
        for: 10m
        labels:
          severity: warning
          team: platform-sre
        annotations:
          summary: "CPU runqueue length severely saturated on {{ $labels.instance }}"
          description: "1-minute load average per CPU core is {{ $value }}, indicating high thread queuing."

      - alert: MemoryAvailableExhaustion
        expr: (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 < 10.0
        for: 5m
        labels:
          severity: critical
          team: platform-sre
        annotations:
          summary: "Node {{ $labels.instance }} low available memory (<10%)"
          description: "Available memory has dropped to {{ $value }}%, direct reclaim risk imminent."
```

---

### 3.3 Manifest de Control de Recursos para Cgroups v2 en Systemd Slice

`/etc/systemd/system/production.slice`
```ini
[Unit]
Description=Production Workloads Cgroup v2 Isolation Slice
Before=slices.target

[Slice]
# Resource Control under Cgroups v2 Unified Hierarchy
CPUAccounting=true
MemoryAccounting=true
IOAccounting=true
TasksAccounting=true

# CPU Allocation: Relative weight (1-10000, default 100) and Hard Limit
CPUWeight=500
CPUQuota=400%

# Memory Constraints: Soft throttle at 12GB, Hard OOM at 16GB
MemoryHigh=12884901888
MemoryMax=17179869184
MemorySwapMax=0

# I/O Bandwidth Constraints for storage device major:minor 259:0 (/dev/nvme0n1)
IOReadBandwidthMax=/dev/nvme0n1 500M
IOWriteBandwidthMax=/dev/nvme0n1 250M

# Task limits to prevent PID exhaustion attacks
TasksMax=4096
```

---

### 3.4 Utilidad Python para Extracción Manual de Capacidad desde Procfs

```python
#!/usr/bin/env python3
"""
procfs_capacity_collector.py
Direct parsing of /proc/stat, /proc/meminfo, and /proc/diskstats
without external dependencies for high-efficiency monitoring.
"""

import time
import sys

def read_meminfo():
    mem = {}
    with open('/proc/meminfo', 'r') as f:
        for line in f:
            parts = line.split(':')
            if len(parts) == 2:
                key = parts[0].strip()
                val = int(parts[1].split()[0]) # Value in kB
                mem[key] = val
    
    total = mem.get('MemTotal', 1)
    available = mem.get('MemAvailable', 0)
    used = total - available
    pct_used = (used / total) * 100.0
    return total, used, available, pct_used

def read_cpu_jiffies():
    with open('/proc/stat', 'r') as f:
        line = f.readline()
    fields = [float(x) for x in line.split()[1:]]
    idle_time = fields[3] + fields[4] # idle + iowait
    total_time = sum(fields)
    return total_time, idle_time

def main():
    print(f"{'TIMESTAMP':<20} | {'CPU USE %':<10} | {'MEM TOTAL(MB)':<13} | {'MEM AVAIL(MB)':<13} | {'MEM USE %':<10}")
    print("-" * 75)
    
    t1_tot, t1_idl = read_cpu_jiffies()
    
    try:
        while True:
            time.sleep(2)
            t2_tot, t2_idl = read_cpu_jiffies()
            
            tot_diff = t2_tot - t1_tot
            idl_diff = t2_idl - t1_idl
            
            cpu_pct = ((tot_diff - idl_diff) / tot_diff) * 100.0 if tot_diff > 0 else 0.0
            
            mem_tot, mem_used, mem_avail, mem_pct = read_meminfo()
            ts = time.strftime("%Y-%m-%d %H:%M:%S")
            
            print(f"{ts:<20} | {cpu_pct:<10.2f} | {mem_tot/1024:<13.1f} | {mem_avail/1024:<13.1f} | {mem_pct:<10.2f}")
            
            t1_tot, t1_idl = t2_tot, t2_idl
    except KeyboardInterrupt:
        sys.exit(0)

if __name__ == '__main__':
    main()
```

---

## 4. Comandos Reales de CLI y Salidas Esperadas de la Terminal

### 4.1 `vmstat`: Diagnóstico de Memoria Virtual y Scheduling de Procesos

```console
$ vmstat 1 5
procs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
 5  1  65536 245120  12456 452100    0    0   120   850 4500 8900 68 22  5  5  0
 7  2  65536 210140  12456 448100    0    0     0  2400 5100 9800 72 25  0  3  0
 4  0  65536 195200  12456 445200    0    0     0  1800 4800 9200 70 24  2  4  0
 8  3  65536 150400  12456 441000  512 1024  2048  4096 6200 1120 75 23  0  2  0
 6  1  65536 142100  12456 439800    0    0     0  1200 4600 8700 65 21 10  4  0
```

#### Interpretación y Desglose de Campos
* **`r` (Run Queue):** `5-8` threads en estado ejecutable (runnable) esperando tiempo de CPU. Dado que `r` supera consistentemente el número de cores (ej. 4 cores), el sistema experimenta **CPU saturation**.
* **`b` (Uninterruptible Sleep):** `1-3` threads bloqueados esperando la finalización de I/O o la adquisición de un lock del kernel.
* **`si` / `so` (Swap-In / Swap-Out):** `si: 512`, `so: 1024` en el intervalo 4 indica **Active Swapping**. El kernel está enviando bloques de memoria a almacenamiento (paging out), introduciendo latencias de acceso al disco en los threads de la aplicación.
* **`cs` (Context Switches):** `11,200` switches/seg indica una agitación (churn) significativa en el scheduling de threads.

---

### 4.2 `iostat`: Perfilado Avanzado de Saturación de Block I/O

```console
$ iostat -xz 1 3
Linux 6.1.0-18-amd64 (node-prod-app-01) 	08/06/2026 	_x86_64_	(8 CPU)

Device:            r/s     w/s     rMB/s     wMB/s   rrqm/s   wrqm/s  %rrqm  %wrqm r_await w_await aqu-sz rareq-sz wareq-sz  svctm  %util
nvme0n1         145.00  850.00     12.50    105.20     0.00    45.00   0.0%   5.0%    1.20   18.50   15.90    88.20   126.80   0.98  97.50
sda              25.00    5.00      0.50      0.10     0.00     0.00   0.0%   0.0%    0.80    2.10    0.02    20.48    20.48   0.67   2.00
```

#### Interpretación y Desglose de Campos
* **`rMB/s` / `wMB/s`:** Vectores de throughput (`12.50 MB/s` de lectura, `105.20 MB/s` de escritura).
* **`w_await` (Write Wait Time):** La latencia promedio de escritura es de `18.50 ms`, significativamente más alta que la línea base del NVMe subyacente (<1 ms).
* **`aqu-sz` (Average Queue Size):** `15.90` solicitudes pendientes encoladas en el driver de la capa de bloques.
* **`%util` (Bandwidth Utilization):** `97.50%` indica saturación del dispositivo. El controlador de almacenamiento está saturado; las operaciones de I/O adicionales incurrirán en demoras de cola lineales.

---

### 4.3 `sar`: Análisis de Informes Históricos de Actividad del Sistema

```console
# Query CPU utilization history for day 05 of current month
$ sar -u -f /var/log/sysstat/sa05 | head -n 12
Linux 6.1.0-18-amd64 (node-prod-app-01) 	08/05/2026 	_x86_64_	(8 CPU)

12:00:01 AM     CPU     %user     %nice   %system   %iowait    %steal     %idle
12:15:01 AM     all     24.50      0.00      8.10      1.20      0.00     66.20
12:30:01 AM     all     58.20      0.00     18.40      4.50      0.00     18.90
12:45:01 AM     all     82.10      0.00     15.80      1.90      0.00      0.20
01:00:01 AM     all     85.00      0.00     14.80      0.10      0.00      0.10

# Export sar data directly to JSON format via sadf for capacity analysis scripts
$ sadf -j /var/log/sysstat/sa05 -- -u | jq '.sysstat.hosts[0].statistics[0].cpu-load'
[
  {
    "cpu": "all",
    "user": 24.5,
    "nice": 0,
    "system": 8.1,
    "iowait": 1.2,
    "steal": 0,
    "idle": 66.2
  }
]
```

---

### 4.4 Inspección de Socket de Red y Memoria del Kernel a través de `ss` y Procfs

```console
$ ss -tulpn state listening
Netid  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process                                                                     
tcp    0      128          0.0.0.0:80         0.0.0.0:*     users:(("nginx",pid=1245,fd=6),("nginx",pid=1244,fd=6))
tcp    0      512        127.0.0.1:3306       0.0.0.0:*     users:(("mysqld",pid=3112,fd=18))

# Check kernel listen queue overflow counters
$ netstat -s | grep -E "listen|SYNs"
    4512 times the listen queue of a socket overflowed
    4512 SYNs dropped due to full socket queue

# Query TCP memory limits (pages: min, pressure, max)
$ cat /proc/sys/net/ipv4/tcp_mem
185781	247711	371562

# Query global file handle allocation status (allocated, free, max)
$ cat /proc/sys/fs/file-nr
12480	0	1048576
```

---

## 5. Guía de Verificación y Diagnóstico

### 5.1 Árbol de Decisión para Cuellos de Botella de Rendimiento Sistémico

```
                      [ System Performance Degradation ]
                                      |
                         +------------+------------+
                         | Inspect Load & vmstat   |
                         +------------+------------+
                                      |
           +--------------------------+--------------------------+
           |                          |                          |
    High 'r' Queue             High 'b' State            Low CPU, High Latency
     (r > Cores)                (Uninterruptible)         Memory Reclaim Spikes
           |                          |                          |
           v                          v                          v
   [ CPU Saturation ]         [ Block I/O Saturation ]    [ Memory Thrashing ]
   - Inspect top/pidstat      - Run iostat -xz 1          - Check vmstat si/so
   - Check cgroup CPU quota   - Check %util, await        - Inspect sar -r
   - Tune process affinity    - Tune scheduler (bfq/mq)   - Adjust swappiness
```

---

### 5.2 Flujos de Trabajo de Diagnóstico y Remediación Paso a Paso

#### Fase 1: Saturación de CPU y Throttling Térmico/Frecuencia
1. Inspeccionar la runqueue vs el conteo de cores usando `vmstat 1` y `mpstat -P ALL 1`.
2. Determinar si las llamadas al sistema (syscalls) consumen tiempo excesivo usando `pidstat -u 1`.
3. Verificar si el throttling de escalado de frecuencia de hardware está activo:
   ```console
   $ cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq
   ```
4. **Remediación:** Ajustar las cuotas de CPU del cgroup a través de slices de systemd o asignar afinidad de core al proceso usando `taskset -c 0,2,4 <pid>`.

#### Fase 2: Thrashing de Page Cache y Bloqueos de Sincronización de Dirty Memory
1. Comprobar si los procesos entran en Direct Reclaim realizando un seguimiento de las métricas de memoria mediante `sar -B`:
   ```console
   $ sar -B 1 3
   08:10:01 AM  pgpgin/s pgpgout/s fault/s  majflt/s  pgscand/s pgscank/s steal/s %vmeff
   08:10:02 AM  1024.00  45120.00 8900.00    125.00   8540.00   120.00    0.00   1.40
   ```
   *Un `majflt/s` alto (major page faults) y un `%vmeff` bajo (<30% de eficiencia) indican un elevado overhead de escaneo de páginas.*

2. Ajustar los umbrales de writeback de memoria virtual del kernel a través de `/etc/sysctl.d/99-capacity.conf`:
   ```ini
   # Start background writeback flusher earlier at 5% dirty memory
   vm.dirty_background_ratio = 5

   # Throttle process synchronous write locks at 15% dirty memory
   vm.dirty_ratio = 15

   # Increase VFS cache re-claim pressure to preserve active anonymous memory
   vm.vfs_cache_pressure = 150

   # Prevent swap activity under moderate memory load
   vm.swappiness = 10
   ```
3. Aplicar la configuración inmediatamente:
   ```console
   $ sysctl --system
   ```

#### Fase 3: Cuellos de Botella de Encolado en la Capa de Bloques de Almacenamiento
1. Identificar el proceso objetivo que genera escrituras de bloques sucios (dirty block writes) usando `iotop -oP`.
2. Inspeccionar la configuración de profundidad de cola del dispositivo de bloques:
   ```console
   $ cat /sys/block/nvme0n1/queue/nr_requests
   1024
   $ cat /sys/block/nvme0n1/queue/scheduler
   [none] mq-deadline bfq
   ```
3. Cambiar el scheduler de I/O a `mq-deadline` para operaciones de base de datos de alto throughput:
   ```console
   $ echo "mq-deadline" > /sys/block/nvme0n1/queue/scheduler
   ```

#### Fase 4: Agotamiento de Network Sockets y Caídas de Conexión
1. Comprobar si las ráfagas de conexiones entrantes superan el parámetro backlog:
   ```console
   $ sysctl net.core.somaxconn
   net.core.somaxconn = 4096
   ```
2. Ajustar los parámetros de red del kernel para cargas de trabajo de alta concurrencia en `/etc/sysctl.d/99-network.conf`:
   ```ini
   # Increase socket listen backlog ceiling
   net.core.somaxconn = 65535

   # Expand maximum file descriptor limit system-wide
   fs.file-max = 2097152

   # Enable fast recycling of sockets in TIME_WAIT state for outgoing connections
   net.ipv4.tcp_tw_reuse = 1

   # Expand TCP socket read/write memory limits (min default max in bytes)
   net.ipv4.tcp_rmem = 4096 87380 16777216
   net.ipv4.tcp_wmem = 4096 65536 16777216
   ```
3. Aplicar los cambios y verificar los límites activos de handles de red:
   ```console
   $ sysctl --system
   $ ulimit -n 65536
   ```

---

## 6. Referencias

* **LPI LPIC-2 Exam 201-450 Objectives:**  
  https://www.lpi.org/our-certifications/lpic-2-overview/

* **Linux Kernel Documentation — Proc File System Specification (`proc.rst`):**  
  https://www.kernel.org/doc/html/latest/filesystems/proc.html

* **Linux Kernel Control Groups v2 Documentation (`cgroup-v2.rst`):**  
  https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html

* **Linux Kernel Virtual Memory Sysctl Documentation (`vm.rst`):**  
  https://www.kernel.org/doc/html/latest/admin-guide/sysctl/vm.html

* **Prometheus Official Documentation — Alerting Rules & Functions:**  
  https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/

* **Sysstat (sar/iostat/sadf) Official Repository & Documentation:**  
  https://github.com/sysstat/sysstat