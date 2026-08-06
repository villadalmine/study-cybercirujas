# LPIC-2 Exam 201-450: Topic 201.1 — Capacity Planning (Weight: 7)

---

## 1. Motivation and Production Architectural Problem

### 1.1 The Physics of Linux Kernel Resource Subsystems

Capacity planning in enterprise Linux environments requires understanding how the Linux kernel manages system hardware resources under load. Rather than viewing CPU, Memory, Disk I/O, and Network I/O as static isolated buckets, a Platform Architect must analyze resource consumption through the lens of kernel subsystem interactions and queueing dynamics.

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

#### CPU Scheduling Mechanics
The Completely Fair Scheduler (CFS) and the EEVDF (Earliest Eligible Virtual Deadline First) scheduler divide CPU time using virtual runtime (`vruntime`).
* When CPU demand exceeds available core execution cycles, task runqueues grow (`r` stat in `vmstat`).
* Context switching overhead increases (`cs`), causing CPU time to shift from user execution (`us`) to kernel overhead (`sy`).
* If tasks spend excessive time waiting in runqueues, latency degradation compounds non-linearly.

#### Memory and Page Cache Dynamics
The Linux Virtual Memory Manager (VMM) optimizes memory utilization by allocating unused RAM to the **Page Cache**, caching file read/write operations.
* **Active List vs. Inactive List:** The kernel manages pages via Least Recently Used (LRU) lists.
* **Direct Reclaim vs. Kswapd:** When free memory drops below the `vm.min_free_kbytes` watermark, the kernel daemon `kswapd` wakes asynchronously to reclaim inactive pages. If allocation speed exceeds `kswapd` throughput, foreground threads hit **Direct Reclaim**, experiencing sub-millisecond execution pauses while synchronously freeing or swapping memory.

#### Storage Block I/O Layer
Storage access flows through the VFS (Virtual File System) down to the block layer queues.
* Write requests are buffered in dirty page cache memory until `vm.dirty_background_ratio` triggers asynchronous background flush threads, or `vm.dirty_ratio` forces process-level synchronous block writes.
* High queue depths (`avgqu-sz` in `iostat`) lead to elevated wait times (`await`), causing threads waiting on block I/O completion to enter Uninterruptible Sleep state (`b` stat in `vmstat`, `D` state in `ps`).

#### Network Socket Buffer Mechanics
Network frames transition from the Network Interface Card (NIC) hardware ring buffer into kernel socket buffers (`rmem`/`wmem`).
* Application processing bottlenecks cause full socket receive buffers, triggering TCP Window Zero alerts and dropped packets at the transport layer.
* If kernel TCP listen queues (`somaxconn`) overflow, incoming `SYN` or `ACK` packets are silently discarded, driving up connection establishment latency.

---

### 1.2 Architectural Failure Modes Under Un-budgeted Capacity Load

When system capacity limits are breached without proactive isolation, systems encounter catastrophic state transitions:

1. **Cascading OOM Invocation & Thrashing:**
   When free memory is exhausted and inactive page cache cannot be evicted fast enough, the kernel invokes `out_of_memory()`. The OOM killer calculates `oom_score` based on badness heuristic rules and sends `SIGKILL` to target processes. If memory pressure remains high, continuous process termination results in service availability loss.

2. **Page Cache Churn & Direct Reclaim Latency Spikes:**
   Excessive file write workloads without memory limits force high rates of dirty page generation. The host hits `vm.dirty_ratio`, halting user threads to force dirty block flushes. Concurrently, memory allocations enter Direct Reclaim, driving execution latency up by orders of magnitude.

3. **Bufferbloat & Socket Exhaustion:**
   Unbounded socket queues cause bufferbloat—adding latency without improving throughput. When open socket counts exceed system `fs.file-max` or process `ulimit -n` boundaries, applications fail to allocate file descriptors (`EMFILE`/`ENFILE` errors), causing complete service failure.

---

### 1.3 Capacity Planning Mathematics

Platform Architects evaluate capacity using formal mathematical models to project resource scaling:

#### Little's Law
Calculates average concurrency within a system in steady state:

$$L = \lambda \times W$$

Where:
* $L$ = Average number of requests in the system (Concurrency)
* $\lambda$ = Arrival rate of requests (Throughput, req/sec)
* $W$ = Average time a request spends in the system (Latency / Service Time, seconds)

#### Universal Scalability Law (USL)
Models scalability limits including contention ($\sigma$) and crosstalk / synchronization overhead ($\kappa$):

$$X(N) = \frac{\lambda N}{1 + \sigma(N - 1) + \kappa N(N - 1)}$$

Where:
* $X(N)$ = Relative throughput at scale factor $N$
* $N$ = Number of hardware resources / CPU cores
* $\sigma$ = System contention parameter (serial queueing bottleneck)
* $\kappa$ = Coherence penalty parameter (inter-node data exchange overhead)

#### Linear Extrapolation for Resource Exhaustion
To estimate time-to-exhaustion $T_{exhaust}$ for disk capacity or memory usage given historic growth slope $m$ and baseline $c$:

$$Y(t) = m \cdot t + c \implies T_{exhaust} = \frac{Capacity_{Max} - c}{m}$$

---

## 2. Technical Comparison & Trade-off Tables

### 2.1 Metrics Collection Architectures

| Parameter / Feature | Pull-Based Architecture (e.g., Prometheus) | Push-Based Architecture (e.g., collectd, Telegraf, SNMP) | Historical File Logging (e.g., sysstat / sar) |
| :--- | :--- | :--- | :--- |
| **Data Ingestion Model** | Central collector polls target HTTP `/metrics` endpoints. | Agent on client actively transmits data to remote endpoint. | Local kernel interrupt cron appends binaries to local storage. |
| **Network Traffic Profile** | Controlled, deterministic polling intervals. | Uncontrolled spikes if metrics queue empties simultaneously across fleet. | Zero network overhead; strictly local file write operations (`/var/log/sysstat/`). |
| **Central Overhead** | High memory footprint for time-series index (TSDB). | Endpoint collector must handle bursty ingress concurrency. | Zero central collector overhead; decentralized storage. |
| **Target Availability Detection** | Native: Failed scrape immediately flags target `up == 0`. | Difficult: Requires silence alerts (dead man's switch logic). | N/A (Local file audit tool). |
| **Suitability for Capacity Planning** | Excellent for dynamic cloud-native service scaling trends. | Ideal for ephemeral batch jobs and edge environments. | Essential for deep bare-metal post-mortem node analysis. |

---

### 2.2 Control Groups: Cgroups v1 vs. Cgroups v2

| Feature / Subsystem | Cgroups v1 (Legacy) | Cgroups v2 (Unified Hierarchy) |
| :--- | :--- | :--- |
| **Hierarchy Model** | Multi-hierarchy: Independent controller trees (`/sys/fs/cgroup/cpu`, `/sys/fs/cgroup/memory`). | Single unified hierarchy tree (`/sys/fs/cgroup/`). |
| **Thread-level Control** | Supported across arbitrary controllers; prone to race conditions. | Process-oriented by default; strict sub-tree controller rule (`cgroup.procs`). |
| **Memory Control Metrics** | `memory.limit_in_bytes`, hard limit enforces immediate OOM invocation. | `memory.high` (throttles/reclaims gracefully), `memory.max` (hard limit). |
| **Out-Of-Memory Scope** | Per-container allocation failure; unpredictably targets child threads. | `memory.oom.group` enables killing all processes in cgroup atomically. |
| **I/O Control Integration** | I/O controller unaware of Page Cache; buffered writes bypass limits. | Full unified tracking: Buffered dirty writes mapped directly to origin cgroup. |

---

### 2.3 Metrics Resolution vs. Storage Overhead

| Resolution Profile | Scrape Interval | Retention Period | Storage per Metric Node / Month | Use Case |
| :--- | :--- | :--- | :--- | :--- |
| **Ultra High** | 1 second | 7 Days | ~150 GB | Micro-burst detection, real-time latency spike diagnosis. |
| **Production Standard**| 15 seconds | 90 Days | ~40 GB | Standard capacity planning, SLI/SLO trend tracking. |
| **Long-term Aggregated**| 5 minutes (downsampled)| 2 Years | ~5 GB | Multi-year infrastructure scaling & hardware procurement budgeting. |

---

## 3. Complete Configuration Files & Infrastructure Manifests

### 3.1 Advanced `/etc/collectd.conf` Configuration

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

### 3.2 Production `prometheus.yml` Scrape & Alert Rules Configuration

#### Scrape File (`/etc/prometheus/prometheus.yml`)
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

#### Alerting Rules (`/etc/prometheus/rules/capacity_alerts.yml`)
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

### 3.3 Systemd Slice Cgroups v2 Resource Control Manifest

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

### 3.4 Python Utility for Manual Procfs Capacity Extraction

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

## 4. Real CLI Commands and Expected Terminal Outputs

### 4.1 `vmstat`: Virtual Memory and Process Scheduling Diagnostics

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

#### Field Interpretation & Breakdown
* **`r` (Run Queue):** `5-8` runnable threads waiting for CPU time. Since `r` consistently exceeds the core count (e.g., 4 cores), the system experiences **CPU saturation**.
* **`b` (Uninterruptible Sleep):** `1-3` threads blocked waiting for I/O completion or kernel lock acquisition.
* **`si` / `so` (Swap-In / Swap-Out):** `si: 512`, `so: 1024` on interval 4 indicates **Active Swapping**. The kernel is paging out memory blocks to storage, introducing disk access latencies into application threads.
* **`cs` (Context Switches):** `11,200` switches/sec indicates significant thread scheduling churn.

---

### 4.2 `iostat`: Advanced Block I/O Saturation Profiling

```console
$ iostat -xz 1 3
Linux 6.1.0-18-amd64 (node-prod-app-01) 	08/06/2026 	_x86_64_	(8 CPU)

Device:            r/s     w/s     rMB/s     wMB/s   rrqm/s   wrqm/s  %rrqm  %wrqm r_await w_await aqu-sz rareq-sz wareq-sz  svctm  %util
nvme0n1         145.00  850.00     12.50    105.20     0.00    45.00   0.0%   5.0%    1.20   18.50   15.90    88.20   126.80   0.98  97.50
sda              25.00    5.00      0.50      0.10     0.00     0.00   0.0%   0.0%    0.80    2.10    0.02    20.48    20.48   0.67   2.00
```

#### Field Interpretation & Breakdown
* **`rMB/s` / `wMB/s`:** Throughput vectors (`12.50 MB/s` read, `105.20 MB/s` write).
* **`w_await` (Write Wait Time):** Average write latency is `18.50 ms`, significantly higher than the underlying NVMe baseline (<1 ms).
* **`aqu-sz` (Average Queue Size):** `15.90` outstanding requests queued in the block layer driver.
* **`%util` (Bandwidth Utilization):** `97.50%` indicates device saturation. The storage controller is saturated; additional I/O operations will incur linear queue delays.

---

### 4.3 `sar`: Historical System Activity Reporting Analysis

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

### 4.4 Network Socket & Kernel Memory Inspection via `ss` and Procfs

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

## 5. Verification and Diagnostics Guide

### 5.1 Systemic Performance Bottleneck Decision Tree

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

### 5.2 Step-by-Step Diagnostic & Remediation Workflows

#### Phase 1: CPU Saturation & Thermal/Frequency Throttling
1. Inspect runqueue vs core count using `vmstat 1` and `mpstat -P ALL 1`.
2. Determine if system calls consume excessive time using `pidstat -u 1`.
3. Verify if hardware frequency scaling throttling is active:
   ```console
   $ cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq
   ```
4. **Remediation:** Adjust cgroup CPU quotas via systemd slices or assign process core affinity using `taskset -c 0,2,4 <pid>`.

#### Phase 2: Page Cache Thrashing & Dirty Memory Sync Stalls
1. Check if processes enter Direct Reclaim by tracking memory metrics via `sar -B`:
   ```console
   $ sar -B 1 3
   08:10:01 AM  pgpgin/s pgpgout/s fault/s  majflt/s  pgscand/s pgscank/s steal/s %vmeff
   08:10:02 AM  1024.00  45120.00 8900.00    125.00   8540.00   120.00    0.00   1.40
   ```
   *High `majflt/s` (major page faults) and low `%vmeff` (<30% efficiency) indicate severe page scanning overhead.*

2. Adjust kernel virtual memory writeback thresholds via `/etc/sysctl.d/99-capacity.conf`:
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
3. Apply settings immediately:
   ```console
   $ sysctl --system
   ```

#### Phase 3: Storage Block Layer Queuing Bottlenecks
1. Identify target process generating dirty block writes using `iotop -oP`.
2. Inspect block device queue depth settings:
   ```console
   $ cat /sys/block/nvme0n1/queue/nr_requests
   1024
   $ cat /sys/block/nvme0n1/queue/scheduler
   [none] mq-deadline bfq
   ```
3. Switch I/O scheduler to `mq-deadline` for high-throughput database operations:
   ```console
   $ echo "mq-deadline" > /sys/block/nvme0n1/queue/scheduler
   ```

#### Phase 4: Network Socket Exhaustion & Connection Drops
1. Check if incoming connection bursts exceed the backlog parameter:
   ```console
   $ sysctl net.core.somaxconn
   net.core.somaxconn = 4096
   ```
2. Tune kernel networking parameters for high-concurrency workloads in `/etc/sysctl.d/99-network.conf`:
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
3. Apply changes and verify active network handle limits:
   ```console
   $ sysctl --system
   $ ulimit -n 65536
   ```

---

## 6. References

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