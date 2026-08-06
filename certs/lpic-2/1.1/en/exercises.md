# LPIC-2 Exam 201-450: Topic 201.1 — Capacity Planning

**Target Certification:** LPIC-2 (Exams 201-450 & 202-450, Version 4.5)  
**Topic:** 201.1 Capacity Planning  
**Weight:** 7  
**Role:** Principal Platform Architect & Senior SRE Instructor  

---

## 1. Deep Technical Mechanics & Architecture

Capacity planning in enterprise Linux environments requires an architectural understanding of how the Linux kernel exposes hardware runtime state, how subsystem metrics are sampled, and how trends are extrapolated to prevent system degradation.

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
The Linux kernel does not store system performance counters in persistent storage. Instead, it exposes dynamic data structures via the `/proc` virtual filesystem (`procfs`). 
- **`/proc/stat`**: Exposes kernel-wide CPU tick counters since boot, categorized by mode (`user`, `nice`, `system`, `idle`, `iowait`, `irq`, `softirq`, `steal`, `guest`, `guest_nice`). Metrics are tracked in units of USER_HZ (typically 100 ticks per second / 10ms intervals).
- **`/proc/meminfo`**: Exposes kernel memory allocator counters, separating physical RAM into active/inactive pages, anonymous memory, page cache, slab allocations (`SReclaimable` vs `SUnreclaimable`), and swap utilization.
- **`/proc/diskstats`**: Contains block device counter arrays tracking read/write completions, merged requests, sectors read/written, and total milliseconds spent doing I/O.
- **`/proc/net/dev`**: Exposes network interface statistics (bytes, packets, errors, drops, fifo overruns, carrier collisions).
- **`/proc/loadavg`**: Exposes system load averages computed as an exponentially damped moving average over 1, 5, and 15-minute intervals. 

### 1.2 System Load Average Mechanics
The Linux load average metric counts processes in two kernel execution states:
1. `TASK_RUNNING` (`R`): Processes executing on CPU or queuing in the runqueue.
2. `TASK_UNINTERRUPTIBLE` (`D`): Processes blocked on non-interruptible kernel operations (predominantly synchronous disk or network I/O).

$$\text{Load} = \text{Tasks}_{R} + \text{Tasks}_{D}$$

> **Architecture Trade-Off:** High load averages do not strictly indicate CPU saturation. A system with $0\%$ CPU utilization can exhibit a load average of 50 if 50 threads are stuck in uninterruptible disk wait (`TASK_UNINTERRUPTIBLE`) due to a hung NFS mount or failing SAN array.

### 1.3 System Activity Data Collector Framework (`sysstat`)
The `sysstat` suite provides historical capacity monitoring via background data collection:
- `sadc` (System Activity Data Collector): High-performance binary sampling engine that queries kernel `/proc` counters and writes raw binary data structures to files located in `/var/log/sa/saDD` (where `DD` is the day of the month).
- `sa1`: Shell script wrapper invoking `sadc` for periodic background binary collection via `cron` or `systemd.timer`.
- `sa2`: Shell script wrapper invoking `sar` to generate human-readable daily text reports (`/var/log/sa/sarDD`).
- `sadf`: Utility for extracting `sadc` binary logs into structured data formats (CSV, JSON, XML, SVG) for automated baseline processing and trend forecasting.

---

## 2. Guided Production Exercises

### Exercise 1: Low-Level Kernel Counter Extraction via `/proc`

#### Objective
Extract raw kernel statistics directly from `procfs` to compute CPU utilization manually without relying on high-level wrappers.

#### Execution Steps

1. Read the first two CPU sampling snapshots from `/proc/stat` separated by a 1-second interval:
```bash
head -n 1 /proc/stat; sleep 1; head -n 1 /proc/stat
```

*Expected CLI Output:*
```text
cpu  124850 120 45210 8920140 12500 0 1420 0 0 0
cpu  124890 120 45230 8920210 12510 0 1422 0 0 0
```

2. Parse memory metrics from `/proc/meminfo` to evaluate available memory capacity vs page cache:
```bash
egrep "MemTotal|MemFree|MemAvailable|Buffers|^Cached|SwapTotal|SwapFree" /proc/meminfo
```

*Expected CLI Output:*
```text
MemTotal:       16378440 kB
MemFree:         2145892 kB
MemAvailable:   11842016 kB
Buffers:          342104 kB
Cached:          9845120 kB
SwapTotal:       4194300 kB
SwapFree:        4194300 kB
```

3. Query raw disk statistics for the primary block device (`sda` or `nvme0n1`):
```bash
grep -E "sda|nvme0n1 " /proc/diskstats
```

*Expected CLI Output:*
```text
   8       0 sda 45210 1204 3840120 18450 95410 4501 8940120 145020 0 45100 163470
```

#### Verification Questions (Exercise 1)

1. In `/proc/meminfo`, why is `MemAvailable` significantly larger than `MemFree`? Which memory regions are included in `MemAvailable` that are excluded from `MemFree`?
2. If `/proc/stat` fields are: `cpu user nice system idle iowait irq softirq steal guest guest_nice`, write the mathematical formula to compute the delta CPU Busy Percentage ($\% \text{CPU}_{\text{busy}}$) between snapshot $t_1$ and snapshot $t_2$.

---

### Exercise 2: CPU & Memory Bottleneck Analysis using `vmstat` and `free`

#### Objective
Analyze thread queue behavior, memory paging, swapping pressure, and CPU state distribution to diagnose hardware saturation points.

#### Execution Steps

1. Execute `vmstat` in delay-count mode (1-second sampling, 5 iterations):
```bash
vmstat -S M 1 5
```

*Expected CLI Output:*
```text
procs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
 3  1      0   2095    334   9614    0    0    12   140 1200 4500 65 25  5  5  0
 4  0      0   2091    334   9614    0    0     0     0 1350 4800 70 28  2  0  0
 2  2      0   2080    334   9614    0    0   450  1200 2100 8900 40 30  5 25  0
 5  0      0   2075    334   9614    0    0     0     0 1400 5100 75 25  0  0  0
 1  0      0   2070    334   9614    0    0     0     0 1100 4200 60 20 20  0  0
```

2. Execute `free` with human-readable formatting and wide output mode:
```bash
free -h -w
```

*Expected CLI Output:*
```text
               total        used        free      shared     buffers      cache   available
Mem:            15Gi       3.8Gi       2.0Gi       128Mi       334Mi       9.3Gi        11Gi
Swap:          4.0Gi          0B       4.0Gi
```

3. Display process queue status and thread counts using `pstree` and `top` in batch mode:
```bash
top -b -n 1 | head -n 5
```

*Expected CLI Output:*
```text
top - 08:15:02 up 45 days, 12:34,  2 users,  load average: 4.12, 3.85, 3.50
Tasks: 312 total,   3 running, 309 sleeping,   0 stopped,   0 zombie
%Cpu(s): 68.2 us, 24.1 sy,  0.0 ni,  2.5 id,  5.2 wa,  0.0 hi,  0.0 si,  0.0 st
MiB Mem :  15994.5 total,   2095.1 free,   3942.3 used,  10283.4 buff/cache
MiB MiB Swap:  4096.0 total,   4096.0 free,      0.0 used.  11564.4 avail Mem 
```

#### Verification Questions (Exercise 2)

1. On a system with 4 logical CPU cores running the `vmstat` workload shown in Step 1, line 4 (`r=5, b=0, us=75, sy=25, id=0, wa=0`), is the system CPU-bound, I/O-bound, or Memory-bound? Justify your diagnosis using specific metrics from columns `r`, `us`, `sy`, and `id`.
2. Differentiate between `si`/`so` (swap-in/swap-out) and `bi`/`bo` (block-in/block-out) in `vmstat`. Which set of metrics indicates severe memory exhaustion leading to active thrashing?

---

### Exercise 3: Storage Subsystem Performance & Bottleneck Diagnosis via `iostat`

#### Objective
Evaluate block device read/write throughput, request queue length, average wait times, and device utilization to detect storage bottlenecks.

#### Execution Steps

1. Run `iostat` displaying extended statistics (`-x`), megabytes per second (`-m`), suppressing idle devices (`-z`) at 1-second intervals for 4 reports:
```bash
iostat -xmz 1 4
```

*Expected CLI Output:*
```text
Linux 5.15.0-105-generic (node-prod-01) 	08/06/2026 	_x86_64_	(8 CPU)

Device            r/s     w/s     rMB/s     wMB/s   rrqm/s   wrqm/s  %rrqm  %wrqm r_await w_await aqu-sz  rareq-sz  wareq-sz  svctm  %util
sda             12.00  450.00      0.15     35.20     0.00    25.00   0.00   5.26    1.20   45.80   20.7    12.80     80.10   2.16  100.00
sdb              0.00    0.00      0.00      0.00     0.00     0.00   0.00   0.00    0.00    0.00    0.00    0.00      0.00   0.00    0.00

Device            r/s     w/s     rMB/s     wMB/s   rrqm/s   wrqm/s  %rrqm  %wrqm r_await w_await aqu-sz  rareq-sz  wareq-sz  svctm  %util
sda              5.00  510.00      0.06     42.10     0.00    30.00   0.00   5.56    0.80   52.40   26.8    12.00     84.50   1.96  100.00
```

2. Inspect `sar` disk activity history (`sar -d`) to correlate current metrics with past performance:
```bash
sar -d 1 2
```

*Expected CLI Output:*
```text
Linux 5.15.0-105-generic (node-prod-01) 	08/06/2026 	_x86_64_	(8 CPU)

08:15:10 AM       DEV       tps  rd_sec/s  wr_sec/s  avgrq-sz  avgqu-sz     await     svctm     %util
08:15:11 AM  dev8-0    462.00    300.00  72080.00    156.67     20.70     44.64      2.16    100.00
08:15:12 AM  dev8-0    515.00    120.00  86220.00    167.65     26.80     51.91      1.94    100.00
Average:     dev8-0    488.50    210.00  79150.00    162.46     23.75     48.47      2.05    100.00
```

#### Verification Questions (Exercise 3)

1. In the `iostat` output above, `sda` exhibits `%util = 100.00%`, `w_await = 52.40ms`, and `aqu-sz = 26.8`. Is `sda` experiencing storage saturation? What does the discrepancy between `r_await` (0.80ms) and `w_await` (52.40ms) reveal about the write workload?
2. Why is `%util` reaching $100\%$ an unreliable metric for determining true saturation on modern multi-queue NVMe storage devices or enterprise RAID arrays?

---

### Exercise 4: Network Socket Capacity & Interface Queue Saturation

#### Objective
Measure network interface throughput, detect packet drops/errors, and evaluate kernel socket allocation limits.

#### Execution Steps

1. Execute `sar` to monitor network interface traffic (`DEV`) at 1-second intervals:
```bash
sar -n DEV 1 3
```

*Expected CLI Output:*
```text
Linux 5.15.0-105-generic (node-prod-01) 	08/06/2026 	_x86_64_	(8 CPU)

08:20:01 AM     IFACE   rxpck/s   txpck/s    rxkB/s    txkB/s   rxcmp/s   txcmp/s  rxmcst/s   %ifutil
08:20:02 AM        lo     12.00     12.00      0.85      0.85      0.00      0.00      0.00      0.00
08:20:02 AM    eth0   85400.00  92100.00  118500.20 131200.50      0.00      0.00      0.00     94.50

08:20:02 AM     IFACE   rxpck/s   txpck/s    rxkB/s    txkB/s   rxcmp/s   txcmp/s  rxmcst/s   %ifutil
08:20:03 AM    eth0   88900.00  94500.00  124100.80 135800.10      0.00      0.00      0.00     97.80
```

2. Monitor interface packet drop statistics (`EDEV`):
```bash
sar -n EDEV 1 2
```

*Expected CLI Output:*
```text
Linux 5.15.0-105-generic (node-prod-01) 	08/06/2026 	_x86_64_	(8 CPU)

08:20:05 AM     IFACE   rxerr/s   txerr/s    coll/s  rxdrop/s  txdrop/s  txcarr/s  rxfram/s  rxfifo/s  txfifo/s
08:20:06 AM    eth0      0.00      0.00      0.00    420.00      0.00      0.00      0.00    420.00      0.00
```

3. Inspect global socket memory allocation and summary using `ss`:
```bash
ss -s
```

*Expected CLI Output:*
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

#### Verification Questions (Exercise 4)

1. In the `sar -n EDEV` output above, `eth0` shows `rxdrop/s = 420.00` and `rxfifo/s = 420.00`, while `rxerr/s = 0.00`. What kernel component or hardware ring buffer is failing, and what parameter needs tuning?
2. If `eth0` link speed is 1 Gbps (Full-Duplex), calculate the network capacity utilization percentage when `rxkB/s = 118500.20` and `txkB/s = 131200.50`.

---

### Exercise 5: Automated Baseline Extraction & Capacity Forecasting with `sar` and `sadf`

#### Objective
Process system activity data binary logs (`/var/log/sa/saDD`) to extract historical baselines, output CSV metrics, and extrapolate resource growth trends.

#### Execution Steps

1. Parse the historical binary file for day 05 (`/var/log/sa/sa05`) and dump CPU utilization data into CSV format using `sadf`:
```bash
sadf -d /var/log/sa/sa05 -- -u | head -n 6
```

*Expected CLI Output:*
```text
# node-prod-01;interval;timestamp;CPU;%user;%nice;%system;%iowait;%steal;%idle
node-prod-01;600;2026-08-05 00:00:01 UTC;-1;12.40;0.00;3.20;0.50;0.00;83.90
node-prod-01;600;2026-08-05 00:10:01 UTC;-1;14.10;0.00;3.50;0.40;0.00;82.00
node-prod-01;600;2026-08-05 00:20:01 UTC;-1;18.50;0.00;4.10;0.80;0.00;76.60
node-prod-01;600;2026-08-05 00:30:01 UTC;-1;25.80;0.00;5.20;1.20;0.00;67.80
```

2. Extract JSON structured metrics for memory and swap usage to feed into an automated capacity forecasting pipeline:
```bash
sadf -j /var/log/sa/sa05 -- -r | jq '.sysstat.hosts[0].statistics[0]'
```

*Expected CLI Output:*
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

3. Generate a daily text summary report using `sa2` manual invocation:
```bash
/usr/lib/sysstat/sa2 -A
ls -l /var/log/sa/sar06
```

*Expected CLI Output:*
```text
-rw-r--r-- 1 root root 245120 Aug  6 08:30 /var/log/sa/sar06
```

#### Verification Questions (Exercise 5)

1. What is the difference in role and output file format between `/usr/lib/sysstat/sa1` and `/usr/lib/sysstat/sa2`?
2. An SRE team observes that peak RAM consumption grows by 450 MB every week. Current node specifications: 32 GB RAM total, 6 GB reserved for OS/agents, peak application usage currently at 20 GB. How many weeks remain before the node exceeds safe operational capacity ($85\%$ of total physical RAM)?

---

## 3. Official References & Documentation
- **LPI LPIC-2 Detailed Objectives (Topic 201.1):** [https://www.lpi.org/our-certifications/lpic-2-overview/](https://www.lpi.org/our-certifications/lpic-2-overview/)
- **Linux Kernel Documentation — `/proc/stat` & `/proc/meminfo`:** [https://www.kernel.org/doc/html/latest/filesystems/proc.html](https://www.kernel.org/doc/html/latest/filesystems/proc.html)
- **Linux Kernel Documentation — Block Layer Diskstats:** [https://www.kernel.org/doc/html/latest/admin-guide/iostats.html](https://www.kernel.org/doc/html/latest/admin-guide/iostats.html)
- **Sysstat / `sar` Manual Pages:** [https://sysstat.github.io/](https://sysstat.github.io/)

---

## 4. Comprehensive Answer Key

<details>
<summary><strong>Click here to expand the Answer Key for Exercises 1–5</strong></summary>

### Exercise 1 Answers

1. **`MemAvailable` vs `MemFree` Mechanics:**
   - `MemFree` represents completely unallocated, untouched physical RAM pages.
   - `MemAvailable` is an estimate of how much memory is available for starting new applications without swapping. It includes `MemFree` PLUS reclaimable memory pools: the Page Cache (`Cached`), memory buffers (`Buffers`), and reclaimable kernel slab allocations (`SReclaimable`), minus minimum watermark thresholds (`wmark_low`) reserved by the kernel to prevent Out-Of-Memory (OOM) deadlocks.

2. **CPU Utilization Delta Calculation:**
   $$\text{TotalTicks} = \text{user} + \text{nice} + \text{system} + \text{idle} + \text{iowait} + \text{irq} + \text{softirq} + \text{steal}$$
   $$\Delta \text{TotalTicks} = \text{TotalTicks}(t_2) - \text{TotalTicks}(t_1)$$
   $$\Delta \text{IdleTicks} = (\text{idle}(t_2) + \text{iowait}(t_2)) - (\text{idle}(t_1) + \text{iowait}(t_1))$$
   $$\% \text{CPU}_{\text{busy}} = \left( 1 - \frac{\Delta \text{IdleTicks}}{\Delta \text{TotalTicks}} \right) \times 100$$
   *Using snapshot values:*
   - $t_1$: $\text{Total} = 124850 + 120 + 45210 + 8920140 + 12500 + 0 + 1420 + 0 = 9104240$
   - $t_2$: $\text{Total} = 124890 + 120 + 45230 + 8920210 + 12510 + 0 + 1422 + 0 = 9104602$
   - $\Delta \text{Total} = 362$ ticks.
   - $\Delta \text{Idle} = (8920210 + 12510) - (8920140 + 12500) = 70 + 10 = 80$ ticks.
   - $\% \text{CPU}_{\text{busy}} = \left(1 - \frac{80}{362}\right) \times 100 = 77.9\%$

---

### Exercise 2 Answers

1. **System Saturation Diagnosis:**
   - **Diagnosis:** The system is **CPU-bound**.
   - **Justification:**
     - The run queue (`r = 5`) exceeds the total number of logical CPU cores ($4$). This proves that runnable threads are actively queuing, waiting for CPU slice allocation.
     - Total CPU utilization is at $100\%$ ($us=75\% + sy=25\%$), with $id=0\%$ (idle) and $wa=0\%$ (iowait). 
     - Blocked processes state is $b=0$, ruling out disk/network I/O bottlenecks.

2. **`si`/`so` vs `bi`/`bo` Distinction:**
   - `bi`/`bo` (Block In / Block Out) measure normal file system I/O read/write operations to/from block devices in KB/s (e.g., database reads, log writes).
   - `si`/`so` (Swap In / Swap Out) measure physical RAM pages being moved to or from the swap partition on disk due to memory pressure.
   - **Impact:** Non-zero `si`/`so` indicates that the Anonymous memory demand exceeds physical RAM capacity. Active swapping causes microsecond-level memory access calls to drop to millisecond-level disk latency (active thrashing), crippling system responsiveness.

---

### Exercise 3 Answers

1. **Storage Bottleneck & Latency Discrepancy:**
   - **Saturation status:** Yes, `sda` is fully saturated. High disk queue depth (`aqu-sz = 26.8`) combined with high write wait times (`w_await = 52.40ms`) and $\%util = 100\%$ proves that the I/O subsystem cannot process incoming write operations fast enough.
   - **Latency Discrepancy (`r_await` 0.80ms vs `w_await` 52.40ms):** Reads are taking under 1ms because they are hitting storage controller hardware cache or solid-state buffers, or because read operations are prioritized by the I/O scheduler (`bfq`/`mq-deadline`). Writes are suffering from queue backing up (`aqu-sz`), indicating dirty page flushing overwhelmed the physical media write bandwidth ($35–42\text{ MB/s}$).

2. **NVMe / Array `%util` Limitations:**
   - The `%util` metric in `iostat` measures the percentage of wall-clock time during which *at least one* I/O request was in flight on the block device ($t_{\text{busy}} / t_{\text{total}}$).
   - Traditional spinning disks (HDDs) process requests sequentially (single queue depth = 1), so $100\%$ utilization strictly implies media saturation.
   - Modern NVMe devices and enterprise storage arrays support hardware multi-queueing (e.g., up to 64,000 parallel queues with 64,000 commands per queue). An NVMe drive handling 1 request continuously will report $\%util = 100\%$, even though it has the parallel processing capacity to handle thousands of concurrent I/O operations without increased latency.

---

### Exercise 4 Answers

1. **Network Queue Drop Analysis:**
   - **Failing Component:** The Network Interface Card (NIC) hardware Receive Ring Buffer (Rx Ring Buffer) or Kernel Socket Receive Queue (FIFO buffer) is overflowing.
   - **Tuning Action:** 
     1. Increase hardware ring buffer sizes using `ethtool -G eth0 rx <max_value>`.
     2. Increase maximum kernel socket receive buffer limits via `sysctl` (`net.core.rmem_max`, `net.core.netdev_max_backlog`).

2. **Network Bandwidth Capacity Calculation:**
   - Total throughput in KB/s: $118500.20 + 131200.50 = 249700.70 \text{ KB/s}$.
   - Convert to Megabits per second (Mbps):
     $$\text{Mbps} = \frac{249700.70 \text{ KB/s} \times 8 \text{ bits/byte}}{1000} = 1997.60 \text{ Mbps}$$
   - *Note on Full-Duplex:* 1 Gbps Full-Duplex link supports 1000 Mbps RX and 1000 Mbps TX independently (total theoretical capacity 2000 Mbps combined).
   - TX direction: $131200.50 \text{ KB/s} \times 8 / 1000 = 1049.6 \text{ Mbps}$, which exceeds the 1000 Mbps link capacity (indicating line-rate saturation, causing packet drops and queuing).
   - Interface utilization relative to 1 Gbps single-direction line rate: $\frac{1049.6}{1000} \times 100\% = 104.9\%$ (Saturated; frame overhead accounted for).

---

### Exercise 5 Answers

1. **`sa1` vs `sa2` Architecture:**
   - `sa1` is an internal binary collection wrapper script that calls `sadc` to append current system metrics to the binary log file `/var/log/sa/saDD`. It produces binary data unreadable by standard text utilities.
   - `sa2` is a report generation script that invokes `sar` to read the daily binary file `/var/log/sa/saDD` and generate a consolidated human-readable daily text summary saved to `/var/log/sa/sarDD`.

2. **Capacity Forecasting Calculation:**
   - Total Physical RAM = $32 \text{ GB}$.
   - Safe Maximum Capacity Threshold ($85\%$):
     $$\text{Max Safe Threshold} = 32 \text{ GB} \times 0.85 = 27.2 \text{ GB}$$
   - Current Peak Consumption = $20 \text{ GB}$.
   - Remaining Growth Headroom:
     $$\text{Headroom} = 27.2 \text{ GB} - 20.0 \text{ GB} = 7.2 \text{ GB} = 7372.8 \text{ MB}$$
   - Weekly Growth Rate = $450 \text{ MB/week}$.
   - Time to Saturation:
     $$\text{Weeks} = \frac{7372.8 \text{ MB}}{450 \text{ MB/week}} = 16.38 \text{ weeks}$$
   - **Result:** Exactly **16 weeks** remain before the system exceeds the $85\%$ safe operational ceiling, requiring hardware upgrades or workload re-balancing.

</details>