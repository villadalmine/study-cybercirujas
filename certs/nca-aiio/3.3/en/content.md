# 3.3 Monitoring GPUs: Key Measures and Criteria

> **Exam focus (NCA-AIIO, weight 5.5):** know *which* GPU metrics matter, *what each one actually measures*, *which tool exposes it* (nvidia-smi, DCGM, DCGM Exporter, BMC, Base Command Manager), and *how to turn it into an operational decision* (healthy, throttled, degraded, failed, or wasted).

---

## 1. Motivation: why GPU monitoring is its own discipline

In a CPU fleet, "node up + CPU% + memory%" covers most operational questions. In an AI cluster that breaks down for four reasons:

1. **Cost density.** A single 8-GPU HGX node costs as much as a rack of CPU servers. An allocated-but-idle GPU is the most expensive idle resource in the datacenter. Utilization is a **financial** metric, not just a performance one.
2. **Silent degradation.** A GPU can be "up", visible to the driver and schedulable, and still be thermally throttled to half its clock, retiring HBM rows, or replaying PCIe packets. A distributed training job runs at the speed of its **slowest** rank, so one degraded GPU slows down 1,024 others.
3. **The headline metric lies.** `nvidia-smi` "GPU-Util" reports the fraction of time *at least one kernel* was running. A kernel that keeps a single SM busy out of 132 reports 100%. You need DCGM profiling metrics (SM activity, SM occupancy, Tensor Core activity, DRAM activity) to know how much of the chip is actually doing work.
4. **Failures are hardware-specific.** XID events, ECC errors, row remapping, NVLink CRC errors, and "GPU fallen off the bus" have no CPU equivalent. They need GPU-aware collection and a node-drain workflow.

The architectural answer NVIDIA promotes is layered:

```
┌──────────────────────────────────────────────────────────────────────┐
│ Decision layer   Grafana dashboards · Alertmanager · Run:ai / BCM UI │
├──────────────────────────────────────────────────────────────────────┤
│ Storage/query    Prometheus (TSDB, PromQL, recording/alert rules)    │
├──────────────────────────────────────────────────────────────────────┤
│ Export           DCGM Exporter (:9400/metrics, K8s pod attribution)  │
├──────────────────────────────────────────────────────────────────────┤
│ Telemetry engine DCGM (nv-hostengine): fields, health, diag, policy  │
├──────────────────────────────────────────────────────────────────────┤
│ Driver           NVIDIA kernel driver + NVML (nvidia-smi uses NVML)  │
├──────────────────────────────────────────────────────────────────────┤
│ Hardware         GPU, HBM, NVLink/NVSwitch, PCIe · BMC (out-of-band) │
└──────────────────────────────────────────────────────────────────────┘
```

The BMC sits beside this stack: it reports temperatures, power, and fans over IPMI/Redfish **even when the OS or the driver is dead**, which is exactly when in-band tools go blind.

---

## 2. The key measures

### 2.1 Metric families at a glance

| Family | What it answers | Primary metrics | Typical decision |
|---|---|---|---|
| **Utilization** | Is the GPU doing useful work? How much of it? | GPU util, `GR_ENGINE_ACTIVE`, `SM_ACTIVE`, `SM_OCCUPANCY`, `PIPE_TENSOR_ACTIVE` | Right-size, bin-pack, use MIG/fractional GPUs, reclaim idle allocations |
| **Memory** | Will the job OOM? Is it memory-bandwidth-bound? | FB used/free, `DRAM_ACTIVE`, mem copy util | Batch size, model sharding, MIG profile choice |
| **Thermal** | Is the GPU running hot enough to slow down? | GPU temp, memory (HBM) temp, slowdown/shutdown thresholds | Airflow/cooling ticket, rack placement |
| **Power** | Is it power-capped? What does it cost? | Power draw, power limit, total energy | Power-capping policy, capacity planning, chargeback |
| **Clocks & throttling** | Is it running at the clocks I paid for, and if not, why? | SM clock, memory clock, clock event (throttle) reasons | Distinguish thermal vs power vs idle throttling |
| **Reliability / errors** | Is the hardware healthy? | XID, ECC SBE/DBE, retired pages, remapped rows, PCIe replay, NVLink CRC/replay | Drain node, reset GPU, RMA |
| **Interconnect** | Is communication the bottleneck? | NVLink TX/RX, PCIe TX/RX bytes | Topology-aware scheduling, NCCL tuning |
| **Health status** | One-word verdict per GPU | `dcgmi health`, `dcgmi diag` | Gate scheduling, pre-job validation |

### 2.2 Utilization: the measure most often misread

| Metric (DCGM field) | ID | Meaning | Range | Pitfall |
|---|---|---|---|---|
| `DCGM_FI_DEV_GPU_UTIL` | 203 | % of sample period during which ≥1 kernel was executing (same as nvidia-smi GPU-Util) | 0–100 | Coarse: 1 busy SM = 100%. Not supported on MIG instances |
| `DCGM_FI_PROF_GR_ENGINE_ACTIVE` | 1001 | Fraction of time the graphics/compute engine was active | 0.0–1.0 | Fine-grained replacement for GPU_UTIL; works per MIG instance |
| `DCGM_FI_PROF_SM_ACTIVE` | 1002 | Fraction of time ≥1 warp was resident on an SM, **averaged across all SMs** | 0.0–1.0 | Shows how much of the chip is busy. 0.8+ is good for training |
| `DCGM_FI_PROF_SM_OCCUPANCY` | 1003 | Resident warps / max warps per SM, averaged | 0.0–1.0 | Low occupancy is not always bad (register-heavy kernels) |
| `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE` | 1004 | Fraction of cycles the Tensor Core pipe was active | 0.0–1.0 | The real "am I using the AI hardware?" metric for matmul-heavy work |
| `DCGM_FI_PROF_PIPE_FP64_ACTIVE` / `FP32` / `FP16` | 1006 / 1007 / 1008 | Activity of each floating-point pipe | 0.0–1.0 | Shows whether you are on the precision you expect |
| `DCGM_FI_DEV_ENC_UTIL` / `DEC_UTIL` | 206 / 207 | NVENC/NVDEC engine utilization | 0–100 | Relevant for video and vision pipelines |

**Mental model for the exam:**

```
GPU_UTIL = 100%   →  "a kernel was running"            (time-based, coarse)
SM_ACTIVE = 0.95  →  "95% of SMs had work"             (space-based)
TENSOR_ACTIVE=0.6 →  "Tensor Cores busy 60% of cycles" (what the hardware is for)
```

A data-loader-starved training job typically shows `GPU_UTIL` swinging between 0 and 100 with low average `SM_ACTIVE`. An inference server at batch size 1 shows `GPU_UTIL` near 100 with `SM_ACTIVE` around 0.2 and low `TENSOR_ACTIVE`. That is the textbook case for **MIG or fractional GPU** sharing, which NVIDIA Run:ai and MIG exist to solve.

### 2.3 Memory

| Metric | ID | Meaning | Use |
|---|---|---|---|
| `DCGM_FI_DEV_FB_USED` | 252 | Framebuffer (HBM/GDDR) used, MiB | OOM risk, packing decisions |
| `DCGM_FI_DEV_FB_FREE` | 251 | Framebuffer free, MiB | Headroom |
| `DCGM_FI_DEV_MEM_COPY_UTIL` | 204 | % of time the memory controller was busy (nvidia-smi "Memory-Util") | Coarse bandwidth indicator |
| `DCGM_FI_PROF_DRAM_ACTIVE` | 1005 | Fraction of cycles the device memory interface was sending or receiving | Memory-bound detection. High DRAM + low Tensor means a bandwidth-bound kernel |

> **Trade-off:** high FB used is **not** a problem by itself. Frameworks such as PyTorch's caching allocator and inference engines that pre-allocate KV cache reserve most of the memory up front. Alert on *OOM events and allocation failures*, not on "memory > 90%". Use FB used for **capacity and packing**, and `DRAM_ACTIVE` for **performance**.

### 2.4 Thermal

| Metric | ID | Meaning |
|---|---|---|
| `DCGM_FI_DEV_GPU_TEMP` | 150 | GPU die temperature, °C |
| `DCGM_FI_DEV_MEMORY_TEMP` | 140 | HBM temperature, °C (critical on HBM parts, which often throttle on memory temperature first) |
| `DCGM_FI_DEV_SLOWDOWN_TEMP` | 158 | Threshold at which the hardware starts reducing clocks |
| `DCGM_FI_DEV_SHUTDOWN_TEMP` | 159 | Threshold at which the GPU shuts down to protect itself |

Thresholds are **per SKU**. Never hard-code a single number for a heterogeneous fleet. Read them from the device:

```
$ nvidia-smi -q -d TEMPERATURE -i 0

==============NVSMI LOG==============

Timestamp                                 : Sat Nov 14 10:21:07 2026
Driver Version                            : 550.90.07
CUDA Version                              : 12.4

Attached GPUs                             : 8
GPU 00000000:18:00.0
    Temperature
        GPU Current Temp                  : 63 C
        GPU T.Limit Temp                  : 24 C
        GPU Shutdown T.Limit Temp         : -8 C
        GPU Slowdown T.Limit Temp         : -2 C
        GPU Max Operating T.Limit Temp    : 0 C
        GPU Target Temperature            : N/A
        Memory Current Temp               : 71 C
        Memory Max Operating T.Limit Temp : 0 C
```

On recent data-center parts, nvidia-smi reports **T.Limit** values: degrees of headroom *relative to* the limit. "T.Limit Temp: 24 C" means 24 °C below the max operating limit, and "Slowdown T.Limit: -2 C" means slowdown starts 2 °C past it. Older parts and drivers show absolute values ("GPU Slowdown Temp: 90 C"). Know both representations.

### 2.5 Power and energy

| Metric | ID | Meaning |
|---|---|---|
| `DCGM_FI_DEV_POWER_USAGE` | 155 | Instantaneous board power draw, W |
| `DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION` | 156 | Cumulative energy since driver load, mJ (counter, so use `rate()`/`increase()`) |
| `DCGM_FI_DEV_POWER_MGMT_LIMIT` | 160 | Current enforced power limit, W |

What to watch:

* **Draw/limit ratio.** A GPU sitting at its power limit with `SW_POWER_CAP` set in the clock-event reasons is power-throttled. That can be expected (dense compute) or a symptom (a power limit lowered by policy or mistake).
* **Energy for chargeback and sustainability.** Run `increase(DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION[1h]) / 3.6e9` to get kWh per GPU per hour.
* **Rack/facility level.** The BMC and PDUs report node and rack power. GPU power plus CPU, NICs, and fans is what the facility budget sees.

### 2.6 Clocks and clock-event (throttle) reasons

| Metric | ID | Meaning |
|---|---|---|
| `DCGM_FI_DEV_SM_CLOCK` | 100 | Current SM clock, MHz |
| `DCGM_FI_DEV_MEM_CLOCK` | 101 | Current memory clock, MHz |
| `DCGM_FI_DEV_CLOCK_THROTTLE_REASONS` | 112 | Bitmask of active reasons clocks are below max (renamed `DCGM_FI_DEV_CLOCKS_EVENT_REASONS` in recent DCGM; nvidia-smi now says `clocks_event_reasons`) |

Bitmask decoding (NVML `nvmlClocksEventReasons`):

| Bit | Hex | Reason | Interpretation |
|---|---|---|---|
| 0 | `0x1` | GpuIdle | Normal: nothing to do |
| 1 | `0x2` | ApplicationsClocksSetting | Clocks pinned by admin (`nvidia-smi -ac`) |
| 2 | `0x4` | SwPowerCap | Power draw hit the software power limit. Common under heavy load |
| 3 | `0x8` | HwSlowdown | **Hardware** slowdown (thermal or power-brake signal). Investigate |
| 4 | `0x10` | SyncBoost | Clocks aligned across GPUs in a sync-boost group |
| 5 | `0x20` | SwThermalSlowdown | Driver reducing clocks because temperature is near the limit |
| 6 | `0x40` | HwThermalSlowdown | **Hardware thermal** protection engaged. Cooling problem |
| 7 | `0x80` | HwPowerBrakeSlowdown | External power-brake signal (PSU or system power event) |
| 8 | `0x100` | DisplayClockSetting | Display-clock related (rare in data center) |

Rule of thumb: `GpuIdle` and `SwPowerCap` are usually **expected**. `HwSlowdown`, `HwThermalSlowdown`, and `HwPowerBrakeSlowdown` are **facility or hardware problems** and should page someone.

### 2.7 Reliability: XID, ECC, page retirement, row remapping, PCIe, NVLink

**XID events** are error reports the NVIDIA driver writes to the kernel log (`NVRM: Xid ...`). DCGM exposes the last one as `DCGM_FI_DEV_XID_ERRORS` (ID 230).

| XID | Meaning | Usual owner | Action |
|---|---|---|---|
| 13 | Graphics engine exception | Usually the application (illegal instruction or address) | Check app; repeat across nodes means a software bug |
| 31 | GPU memory page fault | Usually the application (illegal memory access) | Debug app; if isolated to one GPU, run diag |
| 43 | GPU stopped processing | App or driver | Often follows 13/31; recover by restarting the job |
| 45 | Preemptive cleanup | Follows a fault or process kill | Informational on its own |
| 48 | Double-bit ECC error | **Hardware** | Drain, reset GPU, run `dcgmi diag -r 3` |
| 63 | ECC page retirement / row remapping event recorded | Hardware (handled) | Reset GPU to apply the remap; trend it |
| 64 | ECC page retirement / row remap **failure** | **Hardware** | Drain, RMA candidate |
| 74 | NVLink error | Hardware / interconnect | Check `nvidia-smi nvlink -e`; reseat or RMA |
| 79 | GPU has fallen off the bus | **Hardware / PCIe / power** | Drain; node reboot; check BMC SEL; RMA if it repeats |
| 92 | High single-bit ECC error rate | Hardware (trending) | Schedule maintenance |
| 94 | Contained ECC error | Hardware; only the affected app was killed | Restart the app; GPU reset recommended |
| 95 | Uncontained ECC error | **Hardware**; all GPU apps affected | Drain, reset; RMA if it repeats |
| 119 / 120 | GSP (GPU System Processor) RPC timeout / error | Driver / firmware | Reset GPU; update driver/firmware |

**ECC and memory repair:**

| Metric | ID | Meaning |
|---|---|---|
| `DCGM_FI_DEV_ECC_SBE_VOL_TOTAL` | 310 | Single-bit (corrected) errors since last driver load |
| `DCGM_FI_DEV_ECC_DBE_VOL_TOTAL` | 311 | Double-bit (uncorrectable) errors since last driver load |
| `DCGM_FI_DEV_RETIRED_SBE` / `RETIRED_DBE` / `RETIRED_PENDING` | 390 / 391 / 392 | Page retirement (pre-Ampere, e.g. V100) |
| `DCGM_FI_DEV_CORRECTABLE_REMAPPED_ROWS` / `UNCORRECTABLE_REMAPPED_ROWS` / `ROW_REMAP_FAILURE` | 394 / 393 / 395 | Row remapping (Ampere and later, e.g. A100/H100) |

* **SBE**: corrected by ECC. A rising *rate* is a leading indicator.
* **DBE / uncorrectable**: data was lost and the process was killed. Act immediately.
* **Row remapping (A100+)** replaces a bad HBM row with a spare. It takes effect **after a GPU reset**. A "pending" remap means the GPU needs a reset. A **remap failure** means spares are exhausted, which makes the GPU an RMA candidate.

**Interconnect integrity:**

| Metric | ID | Meaning |
|---|---|---|
| `DCGM_FI_DEV_PCIE_REPLAY_COUNTER` | 202 | PCIe link-level retransmissions. A steadily increasing value points to signal-integrity problems (riser, slot, cable) |
| `DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL` | 449 | Total NVLink bandwidth counter |
| `DCGM_FI_PROF_NVLINK_TX_BYTES` / `RX_BYTES` | 1011 / 1012 | NVLink throughput (profiling) |
| `DCGM_FI_PROF_PCIE_TX_BYTES` / `RX_BYTES` | 1009 / 1010 | PCIe throughput (profiling) |

---

## 3. Tooling comparison

### 3.1 Which tool for which job

| Tool | Scope | Strengths | Limitations | When to use |
|---|---|---|---|---|
| **nvidia-smi** (NVML CLI) | One node, interactive | Always present with the driver, zero setup, good for ad-hoc checks | No history, no aggregation, coarse utilization, polling cost if scripted | Triage on a node, quick validation, inside a container |
| **DCGM** (`nv-hostengine` + `dcgmi`) | One node, daemon | Profiling metrics (SM/Tensor/DRAM), health watches, active diagnostics (`diag`), policies, per-job stats, MIG-aware | Needs the service running; profiling metrics require privileges | Health gating, burn-in, job accounting, the source for exporters |
| **DCGM Exporter** | Cluster (K8s) | Prometheus format, **pod/namespace/container labels** via kubelet pod-resources, configurable CSV of fields | Only as good as the CSV you configure; cardinality grows with GPUs × labels | Standard Kubernetes GPU observability (deployed by the GPU Operator) |
| **Prometheus + Grafana** | Cluster / fleet | History, PromQL, alerting, dashboards (Grafana dashboard 12239 for DCGM Exporter) | You own retention, HA, and scaling | Trends, SLOs, alerts, chargeback |
| **BMC** (IPMI / Redfish) | Node hardware, **out-of-band** | Works when the OS or driver is down: temps, fans, PSU, power, SEL event log, remote power cycle | Coarse GPU visibility, no workload metrics | Post-mortem of "node died", hardware events, facility power |
| **NVIDIA Base Command Manager** | Cluster management | Provisioning, built-in health checks, monitoring and metrics collection, job-to-GPU correlation across Slurm/K8s | Platform adoption | Managed DGX/HGX clusters, a single pane for infra teams |
| **NVIDIA Run:ai** | Workload / scheduler | GPU allocation vs utilization per project and team, fractional GPUs, quotas, idle-GPU reclamation | Scheduler-level view, not a hardware-error tool | Raising utilization, multi-tenant fairness |

### 3.2 In-band vs out-of-band

| Aspect | In-band (NVML/DCGM) | Out-of-band (BMC) |
|---|---|---|
| Path | OS → driver → GPU | Dedicated management controller and network |
| Survives OS/driver crash | No | **Yes** |
| Granularity | Per-GPU, per-MIG, per-process | Per-node / per-sensor |
| Metrics | Utilization, memory, ECC, XID, clocks, profiling | Inlet/exhaust temp, fans, PSU, node power, SEL |
| Typical use | Performance and health | Hardware events, recovery, facility |

### 3.3 Polling interval and cost

| Interval | Use | Cost |
|---|---|---|
| 1 s | Short-lived debugging (`dcgmi dmon -d 1000`) | High overhead and TSDB volume; don't keep it on in production |
| 10–30 s | Production Prometheus scrape (DCGM Exporter default collection interval is 30 s; many clusters use 15 s) | Balanced |
| 1–5 min | Capacity and chargeback rollups (recording rules) | Low |

Profiling metrics (`DCGM_FI_PROF_*`) are multiplexed hardware counters. Collecting many of them at once can force multiplexing or conflict with tools such as Nsight Compute running on the same GPU. Keep the profiling set small in production.

---

## 4. Hands-on: nvidia-smi

### 4.1 Overview

```
$ nvidia-smi
Sat Nov 14 10:24:51 2026
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 550.90.07              Driver Version: 550.90.07      CUDA Version: 12.4     |
|-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
|                                         |                        |               MIG M. |
|=========================================+========================+======================|
|   0  NVIDIA H100 80GB HBM3          On  |   00000000:18:00.0 Off |                    0 |
| N/A   63C    P0            612W /  700W |   71234MiB /  81559MiB |     99%      Default |
|                                         |                        |             Disabled |
+-----------------------------------------+------------------------+----------------------+
|   1  NVIDIA H100 80GB HBM3          On  |   00000000:2A:00.0 Off |                    0 |
| N/A   41C    P0            118W /  700W |   71230MiB /  81559MiB |      4%      Default |
|                                         |                        |             Disabled |
+-----------------------------------------+------------------------+----------------------+

+-----------------------------------------------------------------------------------------+
| Processes:                                                                              |
|  GPU   GI   CI        PID   Type   Process name                              GPU Memory |
|        ID   ID                                                               Usage      |
|=========================================================================================|
|    0   N/A  N/A    184211      C   python                                      71220MiB |
|    1   N/A  N/A    184212      C   python                                      71216MiB |
+-----------------------------------------------------------------------------------------+
```

Reading it as an SRE: GPU 1 holds the same memory as GPU 0 but runs at 4% utilization and 118 W. In a data-parallel job that pattern means rank 1 is **waiting**, either on a collective or on input, or it is itself the slow straggler being waited on elsewhere. Check its clocks and event reasons next.

### 4.2 Scriptable queries

```
$ nvidia-smi --query-gpu=index,name,utilization.gpu,utilization.memory,memory.used,memory.total,temperature.gpu,temperature.memory,power.draw,power.limit,clocks.sm,clocks.max.sm,clocks_event_reasons.active --format=csv
index, name, utilization.gpu [%], utilization.memory [%], memory.used [MiB], memory.total [MiB], temperature.gpu, temperature.memory, power.draw [W], power.limit [W], clocks.current.sm [MHz], clocks.max.sm [MHz], clocks_event_reasons.active
0, NVIDIA H100 80GB HBM3, 99 %, 61 %, 71234 MiB, 81559 MiB, 63, 71, 612.40 W, 700.00 W, 1980 MHz, 1980 MHz, 0x0000000000000000
1, NVIDIA H100 80GB HBM3, 4 %, 1 %, 71230 MiB, 81559 MiB, 41, 44, 118.02 W, 700.00 W, 1410 MHz, 1980 MHz, 0x0000000000000001
```

`0x...01` on GPU 1 = `GpuIdle`: the GPU is idle, not broken. The problem is upstream (input pipeline, collective wait, scheduler).

On older drivers the field is `clocks_throttle_reasons.active`. Run `nvidia-smi --help-query-gpu` to list the names your driver supports.

### 4.3 Rolling device monitoring

```
$ nvidia-smi dmon -s pucvmet -d 5 -c 3
# gpu    pwr  gtemp  mtemp     sm    mem    enc    dec    jpg    ofa   mclk   pclk  pviol  tviol     fb   bar1   ccpm  sbecc  dbecc    pci  rxpci  txpci
# Idx      W      C      C      %      %      %      %      %      %    MHz    MHz      %   bool     MB     MB     MB   errs   errs   errs   MB/s   MB/s
    0    611     63     71     99     61      0      0      0      0   2619   1980      0      0  71234      5      0      0      0      0    412    388
    1    117     41     44      4      1      0      0      0      0   2619   1410      0      0  71230      5      0      0      0      0     12      9
    0    615     64     71     99     62      0      0      0      0   2619   1980      0      0  71234      5      0      0      0      0    409    391
```

`-s` selects groups: `p` power/temp, `u` utilization, `c` clocks, `v` power/thermal violations (`pviol`, `tviol`), `m` memory, `e` ECC/PCIe errors, `t` PCIe throughput.

### 4.4 Errors, row remapping, and topology

```
$ nvidia-smi -q -d ECC,ROW_REMAPPER -i 3

GPU 00000000:9A:00.0
    ECC Mode
        Current                           : Enabled
        Pending                           : Enabled
    ECC Errors
        Volatile
            SRAM Correctable              : 0
            SRAM Uncorrectable            : 0
            DRAM Correctable              : 12
            DRAM Uncorrectable            : 1
        Aggregate
            SRAM Correctable              : 0
            SRAM Uncorrectable            : 0
            DRAM Correctable              : 57
            DRAM Uncorrectable            : 1
    Remapped Rows
        Correctable Error                 : 0
        Uncorrectable Error               : 1
        Pending                           : Yes
        Remapping Failure Occurred        : No
        Bank Remap Availability Histogram
            Max                           : 639 bank(s)
            High                          : 1 bank(s)
            Partial                       : 0 bank(s)
            Low                           : 0 bank(s)
            None                          : 0 bank(s)
```

Verdict: an uncorrectable DRAM error occurred, a row remap is **pending**, and no failure has occurred yet. Drain the node, reset the GPU so the remap takes effect, then validate with `dcgmi diag -r 3`.

```
$ nvidia-smi topo -m
        GPU0    GPU1    GPU2    GPU3    GPU4    GPU5    GPU6    GPU7    NIC0    CPU Affinity    NUMA Affinity
GPU0     X      NV18    NV18    NV18    NV18    NV18    NV18    NV18    PIX     0-55            0
GPU1    NV18     X      NV18    NV18    NV18    NV18    NV18    NV18    PXB     0-55            0
...
```

`NV18` = 18 NVLink links between the pair (through NVSwitch on HGX H100). If a pair shows `SYS` or `PHB` instead, NVLink is down and traffic falls back to PCIe/CPU.

```
$ nvidia-smi nvlink -e -i 0
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-5f1c2e1a-8b0d-4c71-9a7e-2d3c4b5a6f70)
         Link 0: Replay Errors: 0
         Link 0: Recovery Errors: 0
         Link 0: CRC Errors: 0
         Link 1: Replay Errors: 0
         Link 1: Recovery Errors: 0
         Link 1: CRC Errors: 0
...
```

### 4.5 XID in the kernel log

```
$ sudo dmesg -T | grep -i xid
[Sat Nov 14 03:12:44 2026] NVRM: Xid (PCI:0000:9a:00): 48, pid=201877, name=python, An uncorrectable double bit error (DBE) has been detected on GPU in the framebuffer at partition 6, subpartition 0.
[Sat Nov 14 03:12:44 2026] NVRM: Xid (PCI:0000:9a:00): 63, pid=201877, name=python, Row Remapper: New row (0x0000000000012f40) was marked for remapping, reset gpu to activate.
```

### 4.6 MIG instances

```
$ nvidia-smi mig -lgi
+---------------------------------------------------------+
| GPU instances:                                          |
| GPU   Name               Profile  Instance   Placement  |
|                            ID       ID       Start:Size |
|=========================================================|
|   0  MIG 3g.40gb            9        1          0:4     |
|   0  MIG 2g.20gb           14        5          4:2     |
|   0  MIG 1g.10gb           19       13          6:1     |
+---------------------------------------------------------+
```

With MIG enabled, the per-GPU `utilization.gpu` field reads `N/A`. Per-instance activity comes from DCGM profiling fields, tagged with GPU instance IDs (see §5.5).

---

## 5. Hands-on: DCGM

### 5.1 Discovery and groups

```
$ systemctl status nvidia-dcgm --no-pager | head -3
● nvidia-dcgm.service - NVIDIA DCGM service
     Loaded: loaded (/usr/lib/systemd/system/nvidia-dcgm.service; enabled; preset: disabled)
     Active: active (running) since Fri 2026-11-13 08:02:11 UTC; 1 day 2h ago

$ dcgmi discovery -l
8 GPUs found.
+--------+----------------------------------------------------------------------+
| GPU ID | Device Information                                                   |
+--------+----------------------------------------------------------------------+
| 0      | Name: NVIDIA H100 80GB HBM3                                          |
|        | PCI Bus ID: 00000000:18:00.0                                         |
|        | Device UUID: GPU-5f1c2e1a-8b0d-4c71-9a7e-2d3c4b5a6f70                |
+--------+----------------------------------------------------------------------+
...
4 NvSwitches found.
...

$ dcgmi group -c trainers -a 0,1,2,3,4,5,6,7
Successfully created group "trainers" with a group ID of 2
Add to group operation successful.
```

### 5.2 Live field monitoring with dmon

```
$ dcgmi dmon -g 2 -e 203,1002,1004,1005,252,150,155 -d 5000 -c 3
#Entity   GPUTL  SMACT  TENSO  DRAMA  FBUSD  TMPTR  POWER
ID
GPU 0     99     0.912  0.587  0.443  71234  63     612.401
GPU 1     4      0.031  0.002  0.004  71230  41     118.022
GPU 2     99     0.905  0.581  0.440  71228  62     608.115
...
```

The two columns side by side make the point of §2.2: GPU 0 has `GPUTL` 99 *and* `SMACT` 0.91, so it is genuinely busy. A GPU showing `GPUTL` 99 with `SMACT` 0.15 would be "busy" but mostly empty.

To list field IDs and names on your DCGM version:

```
$ dcgmi dmon -l | grep -E "PROF_SM_ACTIVE|GPU_UTIL|FB_USED"
gpu_utilization              GPUTL   203
fb_used                      FBUSD   252
sm_active                    SMACT   1002
```

### 5.3 Passive health watches

```
$ dcgmi health -g 2 -s a
Health monitor systems set successfully.

$ dcgmi health -g 2 -c
+---------------------------+----------------------------------------------------------+
| Health Monitor Report                                                                |
+===========================+==========================================================+
| Overall Health            | Failure                                                  |
| GPU ID: 3                 | Failure                                                  |
|                           | Memory system: Failure                                   |
|                           |   A volatile double-bit ECC error was detected on GPU 3. |
|                           |   Drain the GPU and reset it or reboot the node.         |
+---------------------------+----------------------------------------------------------+
```

`-s` selects subsystems: `p` PCIe, `m` memory, `i` inforom, `t` thermal and power, `n` NVLink, `d` driver, `x` NVSwitch, or `a` for all. Health watches are **passive**: they evaluate telemetry already being collected and add no load.

### 5.4 Active diagnostics

| Level | Command | Duration (order of magnitude) | Covers | When |
|---|---|---|---|---|
| 1 | `dcgmi diag -r 1` | Seconds | Software/deployment checks (driver, permissions, persistence, environment) | Pre-job sanity check, node admission |
| 2 | `dcgmi diag -r 2` | ~1–2 min | + quick PCIe/memory/hardware tests | After a reboot or driver update |
| 3 | `dcgmi diag -r 3` | Tens of minutes | + targeted stress, memory bandwidth, diagnostic, NVLink/PCIe bandwidth | After an XID or ECC event, before returning a node to service |
| 4 | `dcgmi diag -r 4` | Hours | + extended memtest and longer stress | Burn-in, acceptance, RMA evidence |

```
$ dcgmi diag -r 3 -i 3
Successfully ran diagnostic for group.
+---------------------------+------------------------------------------------+
| Diagnostic                | Result                                         |
+===========================+================================================+
|-----  Metadata  ----------+------------------------------------------------|
| DCGM Version              | 3.3.9                                          |
| Driver Version Detected   | 550.90.07                                      |
| GPU Device IDs Detected   | 2330                                           |
|-----  Deployment  --------+------------------------------------------------|
| Denylist                  | Pass                                           |
| NVML Library              | Pass                                           |
| CUDA Main Library         | Pass                                           |
| Permissions and OS Blocks | Pass                                           |
| Persistence Mode          | Pass                                           |
| Environment Variables     | Pass                                           |
| Page Retirement/Row Remap | Fail - GPU 3                                   |
|   Warning                 | GPU 3 has uncorrectable memory errors and row  |
|                           | remappings are pending. Reset the GPU.         |
|-----  Integration  -------+------------------------------------------------|
| PCIe                      | Skip - All                                     |
|-----  Hardware  ----------+------------------------------------------------|
| GPU Memory                | Skip - All                                     |
+---------------------------+------------------------------------------------+
```

Active diagnostics **load the GPU heavily**. Never run levels 2–4 on a GPU that is serving production work. Drain first.

Diagnostics can also run as a Kubernetes Job or through Base Command Manager health checks, so that a node is cordoned automatically when a check fails.

### 5.5 Per-job statistics (accounting)

```
$ dcgmi stats -g 2 -e
Successfully started process watches.

$ dcgmi stats -g 2 -s llama-ft-20261114
Successfully started recording stats for llama-ft-20261114.

$ dcgmi stats -x llama-ft-20261114
Successfully stopped recording stats for llama-ft-20261114.

$ dcgmi stats -j llama-ft-20261114
+------------------------------------------------------------------------------+
| Summary                                                                      |
+====================================+=========================================+
|-----  Execution Stats  ------------+-----------------------------------------|
| Start Time                         | Sat Nov 14 06:00:02 2026                |
| End Time                           | Sat Nov 14 10:00:05 2026                |
| Total Execution Time (sec)         | 14403.11                                |
| No. of Processes                   | 8                                       |
|-----  Performance Stats  ----------+-----------------------------------------|
| Energy Consumed (Joules)           | 33912844                                |
| Power Usage (Watts)                | Avg: 588.3, Max: 699.1, Min: 97.4       |
| Max GPU Memory Used (bytes)        | 76684705792                             |
| SM Clock (MHz)                     | Avg: 1941, Max: 1980, Min: 1410         |
| Memory Clock (MHz)                 | Avg: 2619, Max: 2619, Min: 2619         |
| SM Utilization (%)                 | Avg: 93, Max: 100, Min: 0               |
| Memory Utilization (%)             | Avg: 58, Max: 71, Min: 0                |
| PCIe Rx Bandwidth (megabytes)      | Avg: N/A, Max: N/A, Min: N/A            |
| PCIe Tx Bandwidth (megabytes)      | Avg: N/A, Max: N/A, Min: N/A            |
|-----  Event Stats  ----------------+-----------------------------------------|
| Single Bit ECC Errors              | 0                                       |
| Double Bit ECC Errors              | 0                                       |
| PCIe Replay Warnings               | 0                                       |
| Critical XID Errors                | 0                                       |
|-----  Slowdown Stats  -------------+-----------------------------------------|
| Due to - Power (%)                 | 3.1                                     |
|        - Thermal (%)               | 0                                       |
|        - Reliability (%)           | 0                                       |
|        - Board Limit (%)           | 0                                       |
|        - Low Utilization (%)       | 0                                       |
|        - Sync Boost (%)            | 0                                       |
+------------------------------------+-----------------------------------------+
```

Slurm prolog/epilog scripts commonly wrap `dcgmi stats -s` and `-x` so that every job gets an energy and health report.

### 5.6 Policies (automated reactions)

```
$ dcgmi policy -g 2 --set 0,0 -e -p -x
Policy successfully set.

$ dcgmi policy -g 2 --get
Policy information
+---------------------------+------------------------------------------------+
| Policy Information                                                         |
| trainers                                                                   |
+===========================+================================================+
| Violation conditions      | Double-bit ECC errors                          |
|                           | PCI errors and replays                         |
|                           | XID errors                                     |
| Isolation mode            | Manual                                         |
| Action on violation       | None                                           |
| Validation after action   | None                                           |
+---------------------------+------------------------------------------------+
```

`--set action,validation`: action `0` = none, `1` = GPU reset. Validation `0` = none, `1`–`3` = run diag at the matching level after the action. In Kubernetes, the safer pattern is usually *alert, cordon, drain, then reset* driven by automation, rather than an in-place GPU reset under running pods.

---

## 6. Kubernetes: DCGM Exporter, Prometheus, alerting

### 6.1 Architecture

```
 ┌────────────── GPU node ──────────────────────────────────────────────┐
 │  kubelet ── /var/lib/kubelet/pod-resources (gRPC: which pod has      │
 │                                          which GPU / MIG device)     │
 │      ▲                                                               │
 │      │ pod/namespace/container labels                                │
 │  dcgm-exporter (DaemonSet) ── embedded DCGM or nv-hostengine ── NVML │
 │      │ :9400/metrics                                                 │
 └──────┼───────────────────────────────────────────────────────────────┘
        ▼
  Prometheus (ServiceMonitor) ──► recording rules ──► Grafana / Alertmanager
                                                  └─► Run:ai / BCM / KEDA / HPA
```

The **NVIDIA GPU Operator** deploys the driver, container toolkit, device plugin, GPU Feature Discovery, MIG Manager, and DCGM Exporter as DaemonSets. Monitoring therefore comes "for free" once the operator is installed, and you customize which fields are exported.

### 6.2 Custom metric set (ConfigMap)

DCGM Exporter reads a CSV: `field_name, prometheus_type, help`. This set covers every family from §2 while keeping profiling counters to five.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: dcgm-exporter-metrics
  namespace: gpu-operator
data:
  dcgm-metrics.csv: |
    # Format: DCGM field, Prometheus metric type, help message
    # Clocks
    DCGM_FI_DEV_SM_CLOCK, gauge, SM clock frequency (in MHz).
    DCGM_FI_DEV_MEM_CLOCK, gauge, Memory clock frequency (in MHz).
    DCGM_FI_DEV_CLOCK_THROTTLE_REASONS, gauge, Bitmask of active clock event reasons.
    # Temperature
    DCGM_FI_DEV_GPU_TEMP, gauge, GPU temperature (in C).
    DCGM_FI_DEV_MEMORY_TEMP, gauge, Memory temperature (in C).
    # Power and energy
    DCGM_FI_DEV_POWER_USAGE, gauge, Power draw (in W).
    DCGM_FI_DEV_POWER_MGMT_LIMIT, gauge, Current power limit (in W).
    DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION, counter, Total energy consumption since boot (in mJ).
    # Utilization (coarse)
    DCGM_FI_DEV_GPU_UTIL, gauge, GPU utilization (in %).
    DCGM_FI_DEV_MEM_COPY_UTIL, gauge, Memory utilization (in %).
    DCGM_FI_DEV_ENC_UTIL, gauge, Encoder utilization (in %).
    DCGM_FI_DEV_DEC_UTIL, gauge, Decoder utilization (in %).
    # Framebuffer
    DCGM_FI_DEV_FB_FREE, gauge, Framebuffer memory free (in MiB).
    DCGM_FI_DEV_FB_USED, gauge, Framebuffer memory used (in MiB).
    # Errors and reliability
    DCGM_FI_DEV_XID_ERRORS, gauge, Value of the last XID error encountered.
    DCGM_FI_DEV_PCIE_REPLAY_COUNTER, counter, Total number of PCIe retries.
    DCGM_FI_DEV_ECC_SBE_VOL_TOTAL, counter, Total number of single-bit volatile ECC errors.
    DCGM_FI_DEV_ECC_DBE_VOL_TOTAL, counter, Total number of double-bit volatile ECC errors.
    DCGM_FI_DEV_UNCORRECTABLE_REMAPPED_ROWS, counter, Number of remapped rows for uncorrectable errors.
    DCGM_FI_DEV_CORRECTABLE_REMAPPED_ROWS, counter, Number of remapped rows for correctable errors.
    DCGM_FI_DEV_ROW_REMAP_FAILURE, gauge, Whether remapping of rows has failed.
    DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL, counter, Total number of NVLink bandwidth counters for all lanes.
    # Profiling (DCP) - keep this set small
    DCGM_FI_PROF_GR_ENGINE_ACTIVE, gauge, Ratio of time the graphics engine is active.
    DCGM_FI_PROF_SM_ACTIVE, gauge, Ratio of cycles an SM has at least one warp assigned.
    DCGM_FI_PROF_PIPE_TENSOR_ACTIVE, gauge, Ratio of cycles the tensor pipe is active.
    DCGM_FI_PROF_DRAM_ACTIVE, gauge, Ratio of cycles the device memory interface is active.
    DCGM_FI_PROF_NVLINK_TX_BYTES, gauge, Rate of data transmitted over NVLink (bytes per second).
```

### 6.3 GPU Operator Helm values

```yaml
# values-gpu-operator.yaml
operator:
  defaultRuntime: containerd
driver:
  enabled: true
toolkit:
  enabled: true
devicePlugin:
  enabled: true
mig:
  strategy: mixed
migManager:
  enabled: true
dcgm:
  enabled: false
dcgmExporter:
  enabled: true
  config:
    name: dcgm-exporter-metrics
  env:
    - name: DCGM_EXPORTER_COLLECTORS
      value: /etc/dcgm-exporter/dcgm-metrics.csv
    - name: DCGM_EXPORTER_INTERVAL
      value: "15000"
  serviceMonitor:
    enabled: true
    interval: 15s
    honorLabels: true    # keep the workload pod/namespace labels dcgm-exporter attaches
    additionalLabels:
      release: kube-prometheus-stack
```

```
$ kubectl create namespace gpu-operator
namespace/gpu-operator created

$ kubectl apply -f dcgm-exporter-metrics.yaml
configmap/dcgm-exporter-metrics created

$ helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
"nvidia" has been added to your repositories
...Successfully got an update from the "nvidia" chart repository
Update Complete. ⎈Happy Helming!⎈

$ helm upgrade --install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator \
    --values values-gpu-operator.yaml \
    --wait
Release "gpu-operator" does not exist. Installing it now.
NAME: gpu-operator
LAST DEPLOYED: Sat Nov 14 10:41:22 2026
NAMESPACE: gpu-operator
STATUS: deployed
REVISION: 1
```

Setting `dcgm.enabled: false` makes the exporter use its **embedded** DCGM engine. Set it to `true` to run a standalone `nv-hostengine` DaemonSet that other tools (such as `dcgmi` from a debug pod) can share.

### 6.4 Standalone DaemonSet (clusters without the GPU Operator)

Use this when the driver and toolkit are managed by the OS image, for example on a DGX OS or BCM-provisioned node. Pin the image tag to the current release listed in NGC.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: gpu-monitoring
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dcgm-exporter
  namespace: gpu-monitoring
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: dcgm-exporter
  namespace: gpu-monitoring
  labels:
    app.kubernetes.io/name: dcgm-exporter
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: dcgm-exporter
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app.kubernetes.io/name: dcgm-exporter
    spec:
      serviceAccountName: dcgm-exporter
      runtimeClassName: nvidia
      priorityClassName: system-node-critical
      nodeSelector:
        nvidia.com/gpu.present: "true"
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      containers:
        - name: dcgm-exporter
          image: nvcr.io/nvidia/k8s/dcgm-exporter:3.3.9-3.6.1-ubuntu22.04
          imagePullPolicy: IfNotPresent
          args:
            - "-f"
            - "/etc/dcgm-exporter/dcgm-metrics.csv"
          env:
            - name: DCGM_EXPORTER_LISTEN
              value: ":9400"
            - name: DCGM_EXPORTER_KUBERNETES
              value: "true"
            - name: DCGM_EXPORTER_INTERVAL
              value: "15000"
            - name: NVIDIA_VISIBLE_DEVICES
              value: all
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          ports:
            - name: metrics
              containerPort: 9400
              protocol: TCP
          securityContext:
            runAsNonRoot: false
            runAsUser: 0
            capabilities:
              add:
                - SYS_ADMIN
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          readinessProbe:
            httpGet:
              path: /health
              port: 9400
            initialDelaySeconds: 30
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 9400
            initialDelaySeconds: 45
            periodSeconds: 20
          volumeMounts:
            - name: pod-gpu-resources
              mountPath: /var/lib/kubelet/pod-resources
              readOnly: true
            - name: metrics-config
              mountPath: /etc/dcgm-exporter/dcgm-metrics.csv
              subPath: dcgm-metrics.csv
              readOnly: true
      volumes:
        - name: pod-gpu-resources
          hostPath:
            path: /var/lib/kubelet/pod-resources
            type: Directory
        - name: metrics-config
          configMap:
            name: dcgm-exporter-metrics
---
apiVersion: v1
kind: Service
metadata:
  name: dcgm-exporter
  namespace: gpu-monitoring
  labels:
    app.kubernetes.io/name: dcgm-exporter
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: dcgm-exporter
  ports:
    - name: metrics
      port: 9400
      targetPort: metrics
      protocol: TCP
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: dcgm-exporter
  namespace: gpu-monitoring
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: dcgm-exporter
  namespaceSelector:
    matchNames:
      - gpu-monitoring
  endpoints:
    - port: metrics
      interval: 15s
      honorLabels: true
      scrapeTimeout: 10s
      relabelings:
        - sourceLabels:
            - __meta_kubernetes_pod_node_name
          targetLabel: node
          action: replace
```

The `dcgm-exporter-metrics` ConfigMap from §6.2 must exist in `gpu-monitoring` too (change its `namespace`). `SYS_ADMIN` is required for the `DCGM_FI_PROF_*` profiling fields. Without it those series are silently missing.

### 6.5 Verifying the exporter

```
$ kubectl -n gpu-operator get pods -l app=nvidia-dcgm-exporter -o wide
NAME                         READY   STATUS    RESTARTS   AGE   IP            NODE
nvidia-dcgm-exporter-7xk2p   1/1     Running   0          12m   10.42.3.17    gpu-node-01
nvidia-dcgm-exporter-q9m4d   1/1     Running   0          12m   10.42.4.22    gpu-node-02

$ kubectl -n gpu-operator port-forward ds/nvidia-dcgm-exporter 9400:9400 &
Forwarding from 127.0.0.1:9400 -> 9400

$ curl -s localhost:9400/metrics | grep -E "^DCGM_FI_(DEV_GPU_UTIL|PROF_SM_ACTIVE)" | head -4
DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-5f1c2e1a-8b0d-4c71-9a7e-2d3c4b5a6f70",pci_bus_id="00000000:18:00.0",device="nvidia0",modelName="NVIDIA H100 80GB HBM3",Hostname="gpu-node-01",DCGM_FI_DRIVER_VERSION="550.90.07",container="trainer",namespace="ml-research",pod="llama-ft-worker-0"} 99
DCGM_FI_DEV_GPU_UTIL{gpu="1",UUID="GPU-0c9d8e7f-6a5b-4c3d-2e1f-0a9b8c7d6e5f",pci_bus_id="00000000:2A:00.0",device="nvidia1",modelName="NVIDIA H100 80GB HBM3",Hostname="gpu-node-01",DCGM_FI_DRIVER_VERSION="550.90.07",container="trainer",namespace="ml-research",pod="llama-ft-worker-0"} 4
DCGM_FI_PROF_SM_ACTIVE{gpu="0",UUID="GPU-5f1c2e1a-8b0d-4c71-9a7e-2d3c4b5a6f70",pci_bus_id="00000000:18:00.0",device="nvidia0",modelName="NVIDIA H100 80GB HBM3",Hostname="gpu-node-01",DCGM_FI_DRIVER_VERSION="550.90.07",container="trainer",namespace="ml-research",pod="llama-ft-worker-0"} 0.912
DCGM_FI_PROF_SM_ACTIVE{gpu="1",UUID="GPU-0c9d8e7f-6a5b-4c3d-2e1f-0a9b8c7d6e5f",pci_bus_id="00000000:2A:00.0",device="nvidia1",modelName="NVIDIA H100 80GB HBM3",Hostname="gpu-node-01",DCGM_FI_DRIVER_VERSION="550.90.07",container="trainer",namespace="ml-research",pod="llama-ft-worker-0"} 0.031
```

On a MIG-enabled GPU the series additionally carry `GPU_I_PROFILE="3g.40gb"` and `GPU_I_ID="1"`, and the pod label maps to the pod that owns that MIG device.

### 6.6 Recording and alerting rules

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gpu-monitoring-rules
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: gpu.recording
      interval: 1m
      rules:
        - record: namespace:gpu_sm_active:avg5m
          expr: |
            avg by (namespace) (
              avg_over_time(DCGM_FI_PROF_SM_ACTIVE{namespace!=""}[5m])
            )
        - record: namespace:gpu_tensor_active:avg5m
          expr: |
            avg by (namespace) (
              avg_over_time(DCGM_FI_PROF_PIPE_TENSOR_ACTIVE{namespace!=""}[5m])
            )
        - record: namespace:gpu_allocated:count
          expr: |
            count by (namespace) (DCGM_FI_DEV_FB_USED{namespace!=""})
        - record: node:gpu_energy_kwh:increase1h
          expr: |
            sum by (Hostname) (
              increase(DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION[1h])
            ) / 3.6e9
        - record: gpu:fb_used_ratio
          expr: |
            DCGM_FI_DEV_FB_USED
              /
            (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE)

    - name: gpu.reliability
      rules:
        - alert: GPUDoubleBitECCError
          expr: |
            increase(DCGM_FI_DEV_ECC_DBE_VOL_TOTAL[10m]) > 0
          for: 0m
          labels:
            severity: critical
            action: drain
          annotations:
            summary: "Uncorrectable ECC error on GPU {{ $labels.gpu }} of {{ $labels.Hostname }}"
            description: "Double-bit ECC errors increased on GPU {{ $labels.UUID }}. Cordon and drain the node, reset the GPU, then run dcgmi diag -r 3."
        - alert: GPURowRemapFailure
          expr: |
            DCGM_FI_DEV_ROW_REMAP_FAILURE > 0
          for: 0m
          labels:
            severity: critical
            action: rma
          annotations:
            summary: "Row remapping failed on GPU {{ $labels.gpu }} of {{ $labels.Hostname }}"
            description: "Spare HBM rows are exhausted on GPU {{ $labels.UUID }}. Remove the GPU from service and open an RMA."
        - alert: GPUXidCritical
          expr: |
            DCGM_FI_DEV_XID_ERRORS == 48
            or DCGM_FI_DEV_XID_ERRORS == 64
            or DCGM_FI_DEV_XID_ERRORS == 74
            or DCGM_FI_DEV_XID_ERRORS == 79
            or DCGM_FI_DEV_XID_ERRORS == 95
          for: 0m
          labels:
            severity: critical
            action: drain
          annotations:
            summary: "Hardware-class XID {{ $value }} on {{ $labels.Hostname }} GPU {{ $labels.gpu }}"
            description: "XID {{ $value }} indicates a hardware or interconnect fault. Check dmesg, the BMC event log and dcgmi health -c."
        - alert: GPUXidApplication
          expr: |
            DCGM_FI_DEV_XID_ERRORS == 13
            or DCGM_FI_DEV_XID_ERRORS == 31
            or DCGM_FI_DEV_XID_ERRORS == 43
          for: 0m
          labels:
            severity: warning
          annotations:
            summary: "Application-class XID {{ $value }} on {{ $labels.Hostname }} GPU {{ $labels.gpu }}"
            description: "Usually a workload bug in pod {{ $labels.namespace }}/{{ $labels.pod }}. Escalate to hardware if it repeats on the same GPU with different workloads."
        - alert: GPUPCIeReplaysIncreasing
          expr: |
            increase(DCGM_FI_DEV_PCIE_REPLAY_COUNTER[15m]) > 100
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "PCIe replays rising on {{ $labels.Hostname }} GPU {{ $labels.gpu }}"
            description: "Sustained PCIe link retransmissions suggest a signal-integrity problem (riser, slot, retimer). Schedule maintenance."
        - alert: GPUSingleBitECCRateHigh
          expr: |
            increase(DCGM_FI_DEV_ECC_SBE_VOL_TOTAL[1h]) > 1000
          for: 0m
          labels:
            severity: warning
          annotations:
            summary: "High corrected ECC rate on {{ $labels.Hostname }} GPU {{ $labels.gpu }}"
            description: "Corrected errors are a leading indicator of HBM degradation. Trend it and plan a maintenance window."

    - name: gpu.thermal-power
      rules:
        - alert: GPUHardwareThrottling
          expr: |
            (floor(DCGM_FI_DEV_CLOCK_THROTTLE_REASONS / 8) % 2 == 1)
            or
            (floor(DCGM_FI_DEV_CLOCK_THROTTLE_REASONS / 64) % 2 == 1)
            or
            (floor(DCGM_FI_DEV_CLOCK_THROTTLE_REASONS / 128) % 2 == 1)
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Hardware clock slowdown on {{ $labels.Hostname }} GPU {{ $labels.gpu }}"
            description: "HwSlowdown, HwThermalSlowdown or HwPowerBrakeSlowdown has been active for 5 minutes (bitmask {{ $value }}). Check cooling, inlet temperature and PSU on the BMC."
        - alert: GPUTemperatureHigh
          expr: |
            DCGM_FI_DEV_GPU_TEMP > 85
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "GPU temperature {{ $value }}C on {{ $labels.Hostname }} GPU {{ $labels.gpu }}"
            description: "Sustained high die temperature. Compare with the SKU slowdown threshold from nvidia-smi -q -d TEMPERATURE."
        - alert: GPUMemoryTemperatureHigh
          expr: |
            DCGM_FI_DEV_MEMORY_TEMP > 90
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "HBM temperature {{ $value }}C on {{ $labels.Hostname }} GPU {{ $labels.gpu }}"
            description: "HBM parts often throttle on memory temperature before die temperature."

    - name: gpu.efficiency
      rules:
        - alert: GPUAllocatedButIdle
          expr: |
            avg_over_time(DCGM_FI_PROF_GR_ENGINE_ACTIVE{pod!=""}[1h]) < 0.05
          for: 30m
          labels:
            severity: info
            team: platform
          annotations:
            summary: "Idle GPU allocated to {{ $labels.namespace }}/{{ $labels.pod }}"
            description: "Graphics engine active below 5% for over an hour while allocated. Candidate for reclamation, MIG or fractional GPU sharing."
        - alert: GPUExporterDown
          expr: |
            up{job=~".*dcgm-exporter.*"} == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "DCGM Exporter target down ({{ $labels.instance }})"
            description: "GPU telemetry is blind on this node. Check the exporter pod, the driver and nv-hostengine."
```

Design notes:

* **Bitmask decoding in PromQL.** PromQL has no bitwise operators. `floor(x / 2^n) % 2 == 1` tests bit *n*. If your exporter version emits `DCGM_FI_DEV_CLOCKS_EVENT_REASONS`, rename the metric in the rule.
* **`DCGM_FI_DEV_XID_ERRORS` is a "last value" gauge.** It does not reset by itself. Pair alerts with a runbook that confirms with `dmesg`, and consider `changes(DCGM_FI_DEV_XID_ERRORS[10m]) > 0` to detect new events.
* **Temperature thresholds** (85/90 °C here) are illustrative. Per-SKU rules, keyed on `modelName`, are more correct in heterogeneous fleets.
* **`GPUExporterDown` is mandatory.** Absence of GPU errors is meaningless if collection is broken.

### 6.7 Useful PromQL for dashboards

```promql
# Fleet "real" utilization vs the headline number
avg(DCGM_FI_PROF_SM_ACTIVE)            # space-based busy fraction
avg(DCGM_FI_DEV_GPU_UTIL) / 100        # time-based (optimistic)

# Allocation efficiency per namespace: allocated GPUs vs effective GPUs
namespace:gpu_allocated:count
namespace:gpu_sm_active:avg5m * namespace:gpu_allocated:count

# Stragglers: GPUs in the same pod far below their siblings
DCGM_FI_PROF_SM_ACTIVE
  < on (pod) group_left
  (avg by (pod) (DCGM_FI_PROF_SM_ACTIVE) * 0.5)

# Power headroom per GPU
DCGM_FI_DEV_POWER_MGMT_LIMIT - DCGM_FI_DEV_POWER_USAGE

# Memory-bound kernels: high DRAM, low Tensor
DCGM_FI_PROF_DRAM_ACTIVE > 0.6 and DCGM_FI_PROF_PIPE_TENSOR_ACTIVE < 0.2
```

---

## 7. MIG and shared GPUs: what changes in monitoring

| Aspect | Full GPU | MIG instance | Time-slicing / fractional (Run:ai) |
|---|---|---|---|
| Isolation | Whole device | Hardware partition (SMs, L2, memory controllers, HBM slice) | Software, shared memory space |
| `DCGM_FI_DEV_GPU_UTIL` | Valid | **Not supported** | Device-level only (aggregate of all sharers) |
| `DCGM_FI_PROF_*` | Per GPU | **Per GPU instance** (`GPU_I_ID`) | Per GPU (cannot split by tenant) |
| FB used | Per GPU | Per instance | Per GPU; per-process via nvidia-smi |
| Pod attribution | One pod per GPU | One pod per MIG device | Many pods per GPU; exporter attribution is ambiguous |
| Fault blast radius | One workload | Faults contained per instance in most cases; some XIDs affect the whole GPU | All sharers |
| Monitoring takeaway | Simple | Use profiling metrics with the MIG labels | Rely on scheduler-level accounting (Run:ai) for per-tenant views |

```
$ dcgmi discovery -c
+-------------------+--------------------------------------------------------------------+
| Instance Hierarchy                                                                     |
+===================+====================================================================+
| GPU 0             | GPU GPU-5f1c2e1a-8b0d-4c71-9a7e-2d3c4b5a6f70 (EntityID: 0)         |
| -> I 0/1          | GPU Instance (EntityID: 0)                                         |
|    -> CI 0/1/0    | Compute Instance (EntityID: 0)                                     |
| -> I 0/5          | GPU Instance (EntityID: 1)                                         |
|    -> CI 0/5/0    | Compute Instance (EntityID: 1)                                     |
| -> I 0/13         | GPU Instance (EntityID: 2)                                         |
|    -> CI 0/13/0   | Compute Instance (EntityID: 2)                                     |
+-------------------+--------------------------------------------------------------------+

$ dcgmi dmon -e 1001,1002 -i i:0,i:1,i:2 -c 2
#Entity   GRACT  SMACT
ID
GPU-I 0   0.982  0.871
GPU-I 1   0.044  0.020
GPU-I 2   0.611  0.402
GPU-I 0   0.979  0.866
GPU-I 1   0.041  0.019
GPU-I 2   0.608  0.398
```

The pattern NVIDIA highlights in its Run:ai and NIM material follows directly from these numbers. Once telemetry shows a pod using a fraction of a GPU, the platform responds by packing that work into smaller slices (MIG profiles or fractional allocations) and reclaiming idle allocations. That turns *monitoring* into *utilization improvement*.

---

## 8. Out-of-band monitoring: BMC, Redfish, IPMI

When a node stops answering SSH, kubelet goes `NotReady`, and DCGM Exporter disappears, the BMC is the only witness left.

```
$ ipmitool -I lanplus -H 10.10.0.21 -U admin -P "$BMC_PASS" sdr type Temperature
Inlet Temp       | 04h | ok  |  7.1 | 24 degrees C
Exhaust Temp     | 05h | ok  |  7.1 | 47 degrees C
GPU0 Temp        | 30h | ok  | 11.0 | 64 degrees C
GPU1 Temp        | 31h | ok  | 11.1 | 41 degrees C
...

$ ipmitool -I lanplus -H 10.10.0.21 -U admin -P "$BMC_PASS" sel list last 3
  a1 | 11/14/2026 | 03:12:43 | Processor GPU3 | Uncorrectable ECC | Asserted
  a2 | 11/14/2026 | 03:13:02 | Power Supply PSU2 | Power Supply AC lost | Asserted
  a3 | 11/14/2026 | 03:13:09 | Power Supply PSU2 | Power Supply AC lost | Deasserted

$ curl -sk -u admin:"$BMC_PASS" https://10.10.0.21/redfish/v1/Chassis/1/Power | jq '.PowerControl[0].PowerConsumedWatts'
6874
```

Sensor names and Redfish resource paths vary by platform vendor (DGX, HGX OEMs, IGX). Discover them from `/redfish/v1/Chassis` rather than assuming them. The IGX Orin BMC documentation describes the same model for edge platforms: an independent controller that provides sensor monitoring, event logs, and remote power control over Redfish and IPMI.

Production pattern: scrape BMCs with a Redfish or IPMI exporter into the same Prometheus, and correlate with DCGM on `Hostname`. "XID 79 at 03:13:05" plus "PSU2 AC lost at 03:13:02" is a power event, not a bad GPU.

---

## 9. Verification and fault-diagnosis guide

### 9.1 Pipeline verification checklist

| Step | Command | Expected |
|---|---|---|
| Driver sees GPUs | `nvidia-smi -L` | One line per GPU with UUID |
| Persistence on | `nvidia-smi -q \| grep -i "Persistence Mode"` | `Enabled` (avoids init latency and odd readings on idle GPUs) |
| DCGM running | `dcgmi discovery -l` | GPUs (and NVSwitches) listed |
| Profiling works | `dcgmi dmon -e 1002 -c 1` | Numeric values, not `N/A` |
| Exporter pods up | `kubectl -n gpu-operator get ds nvidia-dcgm-exporter` | DESIRED = READY = number of GPU nodes |
| Pod attribution | `curl -s :9400/metrics \| grep 'pod="'` | Non-empty `pod` and `namespace` on allocated GPUs |
| Prometheus target | `up{job=~".*dcgm.*"}` | `1` for every GPU node |
| Alert rules loaded | Prometheus UI → Rules | `gpu.*` groups present, no evaluation errors |

### 9.2 Symptom-driven diagnosis

| Symptom | Metrics to check | Likely cause | Action |
|---|---|---|---|
| Training slower than baseline, nothing "red" | `SM_CLOCK` vs max, event-reason bitmask, `POWER_USAGE` vs limit | Thermal or power throttling on one or more GPUs | Decode the bitmask: `0x4` power cap means expected or a lowered limit; `0x40` HW thermal means a cooling or airflow ticket |
| One rank of a distributed job much slower | `SM_ACTIVE` per GPU in the pod, `PCIE_REPLAY_COUNTER`, NVLink errors | Straggler GPU (throttled, degraded link) | Straggler query (§6.7); `nvidia-smi nvlink -e`; drain the node |
| GPU-Util 100% but throughput poor | `SM_ACTIVE`, `TENSOR_ACTIVE`, `DRAM_ACTIVE` | Small kernels, low batch size, memory-bound | Increase batch size, enable mixed precision, consider MIG for the service |
| GPU-Util oscillating 0↔100 | `GPU_UTIL` at 1 s, CPU/IO of the pod, `PCIE_RX_BYTES` | Input pipeline starvation | More data-loader workers, faster storage, prefetching |
| Pod killed, `CUDA error: uncorrectable ECC error` | `ECC_DBE_VOL_TOTAL`, `dmesg` XID 48/94/95, remapped rows | HBM uncorrectable error | Cordon, drain, reset GPU, `dcgmi diag -r 3`; RMA on remap failure |
| GPU missing from `nvidia-smi` | `dmesg` XID 79, BMC SEL, `lspci \| grep -i nvidia` | Fell off the bus (PCIe, power, thermal) | Check the BMC for power/thermal events; reboot; RMA if it repeats |
| Node `NotReady`, no GPU metrics at all | BMC sensors and SEL | OS hang, power event, kernel panic | Use the out-of-band console; power cycle via BMC; correlate the timeline |
| Profiling metrics `N/A` or absent | Exporter logs, capabilities | Missing `SYS_ADMIN`, another profiler holding counters, unsupported GPU | Add the capability; stop Nsight sessions; check the DCGM support matrix |
| `pod` label empty on exporter series | Exporter env, mounted pod-resources | Pod-resources socket not mounted, or `DCGM_EXPORTER_KUBERNETES` unset | Mount `/var/lib/kubelet/pod-resources`; set the env var |
| Rising PCIe replays, no crashes yet | `PCIE_REPLAY_COUNTER` rate | Marginal link (riser, retimer, slot) | Maintenance window; reseat; check link width/gen with `nvidia-smi -q -d PCIE` |
| Allocated GPUs idle for hours | `GR_ENGINE_ACTIVE` per pod | Notebooks left open, stuck jobs, over-requesting | Idle-reclamation policy, quotas, fractional GPUs (Run:ai) |

### 9.3 Node remediation runbook (hardware-class event)

```
$ kubectl cordon gpu-node-07
node/gpu-node-07 cordoned

$ kubectl drain gpu-node-07 --ignore-daemonsets --delete-emptydir-data --timeout=15m
node/gpu-node-07 already cordoned
evicting pod ml-research/llama-ft-worker-3
pod/llama-ft-worker-3 evicted
node/gpu-node-07 drained

$ ssh gpu-node-07 'sudo nvidia-smi -r -i 3'
GPU 00000000:9A:00.0 was successfully reset.
All done.

$ ssh gpu-node-07 'nvidia-smi -q -d ROW_REMAPPER -i 3 | grep -E "Pending|Failure"'
        Pending                           : No
        Remapping Failure Occurred        : No

$ ssh gpu-node-07 'dcgmi diag -r 3 -i 3 | grep -E "Fail|Pass" | sort | uniq -c'
     14 | Pass
      0 | Fail

$ kubectl uncordon gpu-node-07
node/gpu-node-07 uncordoned
```

A GPU reset (`nvidia-smi -r`) requires that no process is using the GPU. With the GPU Operator, that may also mean stopping operator components that hold the device; rebooting the node is the simpler path. If the diag fails or a remap failure is reported, keep the node cordoned and open an RMA with the `dcgmi diag -r 3` (or `-r 4`) output and the `nvidia-bug-report.sh` log.

---

## 10. Exam-oriented summary

* **Five core measures:** utilization, memory, temperature, power, and errors. Add clocks/throttle reasons and interconnect for completeness.
* **GPU-Util ≠ efficiency.** It is time-based ("a kernel was running"). Use `SM_ACTIVE`, `SM_OCCUPANCY`, and `TENSOR_ACTIVE` (DCGM profiling) to judge how much of the GPU is really working.
* **DCGM** is NVIDIA's data-center telemetry and management engine: metrics, **health watches** (passive), **diagnostics** (active, levels 1–4), **job stats**, and **policies**. **DCGM Exporter** publishes those metrics to Prometheus with Kubernetes pod labels and is deployed by the **GPU Operator**.
* **nvidia-smi** is for interactive, per-node checks. **Prometheus/Grafana** provide history and alerts.
* **ECC:** SBE is corrected (trend it). DBE/uncorrectable means data loss (act now). **Row remapping** on A100+ needs a GPU reset to apply; a **remap failure** points to RMA.
* **XID:** 13/31/43 are usually the application. 48, 63/64, 74, 79, 94/95 are hardware, memory, or interconnect.
* **Throttle reasons:** idle and SW power cap are usually normal. **HW slowdown / HW thermal / power brake** are infrastructure problems.
* **MIG:** use profiling metrics per GPU instance. Device-level `GPU_UTIL` is not available for MIG instances.
* **BMC (IPMI/Redfish)** is out-of-band: hardware sensors and event logs when the OS or driver is down.
* **Base Command Manager** and **Run:ai** turn telemetry into cluster operations: health checks and node management (BCM), and allocation efficiency and fractional GPUs (Run:ai).

---

## Referencias

- NVIDIA AI Infrastructure and Operations (NCA-AIIO) exam guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy, AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA Data Center GPU Manager (DCGM): https://developer.nvidia.com/dcgm
- DCGM User Guide (field IDs, health, diagnostics, policies): https://docs.nvidia.com/datacenter/dcgm/latest/user-guide/index.html
- DCGM Exporter: https://github.com/NVIDIA/dcgm-exporter
- NVIDIA GPU Operator, GPU telemetry: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html
- NVIDIA XID Errors reference: https://docs.nvidia.com/deploy/xid-errors/index.html
- NVIDIA GPU Memory Error Management (ECC, row remapping): https://docs.nvidia.com/deploy/a100-gpu-mem-error-mgmt/index.html
- NVML API, clock event reasons: https://docs.nvidia.com/deploy/nvml-api/group__nvmlClocksEventReasons.html
- nvidia-smi documentation: https://docs.nvidia.com/deploy/nvidia-smi/index.html
- NVIDIA Multi-Instance GPU: https://www.nvidia.com/en-us/technologies/multi-instance-gpu/
- MIG User Guide: https://docs.nvidia.com/datacenter/tesla/mig-user-guide/index.html
- NVIDIA IGX Orin BMC introduction: https://docs.nvidia.com/igx-orin/bmc/latest/introduction.html
- NVIDIA Base Command: https://www.nvidia.com/en-us/data-center/base-command/
- Maximizing GPU Utilization with NVIDIA Run:ai and NVIDIA NIM: https://developer.nvidia.com/blog/maximizing-gpu-utilization-with-nvidia-runai-and-nvidia-nim/
- Kubernetes documentation: https://kubernetes.io/docs/home/
- Kubernetes device plugins and pod-resources API: https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/
- Prometheus Operator, PrometheusRule and ServiceMonitor: https://prometheus-operator.dev/docs/api-reference/api/
- Grafana dashboard 12239, NVIDIA DCGM Exporter: https://grafana.com/grafana/dashboards/12239