# Guided Exercises — Topic 3.3: Monitoring GPUs: Key Measures and Criteria

> **Exam:** NCA-AIIO · **Domain weight:** 5.5%
> **Official references used for these exercises:**
> - NVIDIA DCGM: https://developer.nvidia.com/dcgm
> - NVIDIA Multi-Instance GPU: https://www.nvidia.com/en-us/technologies/multi-instance-gpu/
> - NVIDIA Base Command: https://www.nvidia.com/en-us/data-center/base-command/
> - NVIDIA IGX Orin BMC: https://docs.nvidia.com/igx-orin/bmc/latest/introduction.html
> - Kubernetes documentation: https://kubernetes.io/docs/home/
> - Maximizing GPU utilization with Run:ai and NIM: https://developer.nvidia.com/blog/maximizing-gpu-utilization-with-nvidia-runai-and-nvidia-nim/
> - NVIDIA AI Infrastructure and Operations Fundamentals course: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
> - NCA-AIIO exam study guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf

---

## How to use these exercises

Each exercise runs on real hardware, but you can do all of them **without a GPU**. Every step includes a sample output. If you have no hardware, read the sample output and answer the questions from it. If you do have a GPU, compare your own output with the sample.

| Environment | What you can run |
|---|---|
| Linux host with NVIDIA driver | Exercises 1, 3, 4, 5 (`nvidia-smi`) |
| Host with DCGM installed (`datacenter-gpu-manager` package, `nv-hostengine` running) | Exercises 2, 6, 8 |
| Kubernetes cluster with NVIDIA GPU Operator + kube-prometheus-stack | Exercise 7 |
| Server with a BMC that exposes Redfish | Exercise 9 |
| Nothing at all | All of them, using the sample outputs |

Sample outputs are **illustrative**. They come from data-center GPUs of the A100/H100 class. Exact values, field availability and formatting depend on the GPU model, the driver version and the DCGM version.

The topic covers measures in five families. Keep this mental model in mind throughout:

```
┌──────────────────────────────────────────────────────────────────────┐
│ 1. Utilization & efficiency  → is the GPU doing useful work?         │
│ 2. Thermal / power / clocks  → is it running at the speed it should? │
│ 3. Memory health             → ECC, row remapping, Xid errors        │
│ 4. Interconnect              → NVLink, PCIe bandwidth and errors     │
│ 5. Platform / out-of-band    → BMC, fans, PSUs, node-level health    │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Exercise 1 — Inventory and baseline with `nvidia-smi`

**Goal:** collect the in-band baseline for each GPU, and learn which `nvidia-smi` query fields map to which monitoring family.

### Step 1.1 — Inventory

Run:

```bash
nvidia-smi -L
nvidia-smi --query-gpu=index,name,uuid,pci.bus_id,driver_version,vbios_version,serial --format=csv
```

Sample output:

```
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-5a1c8e0f-3b2d-4c7e-9f11-0a2b3c4d5e6f)
GPU 1: NVIDIA H100 80GB HBM3 (UUID: GPU-7d2e9f10-4c3e-5d8f-a022-1b3c4d5e6f70)

index, name, uuid, pci.bus_id, driver_version, vbios_version, serial
0, NVIDIA H100 80GB HBM3, GPU-5a1c8e0f-3b2d-4c7e-9f11-0a2b3c4d5e6f, 00000000:18:00.0, 550.90.07, 96.00.89.00.01, 1650923000123
1, NVIDIA H100 80GB HBM3, GPU-7d2e9f10-4c3e-5d8f-a022-1b3c4d5e6f70, 00000000:2A:00.0, 550.90.07, 96.00.89.00.01, 1650923000456
```

**Questions:**

1. **Q1.1a** Your alerting labels GPUs by their `index`, and a technician needs to swap a failed GPU. Why is `index` the wrong identifier for the RMA ticket? Which field or fields would you use instead?
2. **Q1.1b** Why does `pci.bus_id` matter when you later read kernel logs (`dmesg`)?

### Step 1.2 — Instantaneous health snapshot

```bash
nvidia-smi --query-gpu=index,temperature.gpu,temperature.memory,power.draw,power.limit,utilization.gpu,utilization.memory,memory.used,memory.total,clocks.sm,clocks.max.sm,pstate --format=csv
```

Sample output:

```
index, temperature.gpu, temperature.memory, power.draw [W], power.limit [W], utilization.gpu [%], utilization.memory [%], memory.used [MiB], memory.total [MiB], clocks.current.sm [MHz], clocks.max.sm [MHz], pstate
0, 71, 80, 612.45 W, 700.00 W, 100 %, 38 %, 78211 MiB, 81559 MiB, 1755 MHz, 1980 MHz, P0
1, 34, 39, 71.12 W, 700.00 W, 0 %, 0 %, 4 MiB, 81559 MiB, 345 MHz, 1980 MHz, P0
```

**Questions:**

3. **Q1.2a** Look at GPU 0. Its `utilization.gpu` is 100% but `clocks.current.sm` is below `clocks.max.sm`. Name two possible explanations.
4. **Q1.2b** GPU 0 uses 78,211 MiB of its 81,559 MiB. Is that a problem in itself? Why do frameworks such as PyTorch make `memory.used` a poor signal of actual memory pressure?
5. **Q1.2c** Classify each queried field into one of the five families in the mental model above.

### Step 1.3 — Continuous sampling with `dmon`

```bash
nvidia-smi dmon -s pucvmet -d 1 -c 5
```

Sample output:

```
# gpu    pwr  gtemp  mtemp     sm    mem    enc    dec    jpg    ofa   mclk   pclk  pviol  tviol     fb   bar1  ccpm  sbecc  dbecc    pci  rxpci  txpci
# Idx      W      C      C      %      %      %      %      %      %    MHz    MHz      %   bool     MB     MB    MB   errs   errs   errs   MB/s   MB/s
    0    615     71     80    100     39      0      0      0      0   2619   1755     12      0  78211     12     0      0      0      0   1840    210
    0    618     72     80    100     38      0      0      0      0   2619   1740     15      0  78211     12     0      0      0      0   1855    212
```

**Questions:**

6. **Q1.3a** What do the `pviol` and `tviol` columns represent? What does `pviol = 12–15 %` tell you about GPU 0?
7. **Q1.3b** Why is one-shot `nvidia-smi` unsuitable as a fleet monitoring solution, even when you wrap it in cron?

---

## Exercise 2 — Utilization is not efficiency: DCGM profiling metrics

**Goal:** see why `utilization.gpu` (DCGM field 203) is a coarse metric. Learn to use the DCGM profiling fields (`DCGM_FI_PROF_*`) to judge how efficiently the GPU is really being used.

### Step 2.1 — Verify DCGM and discover GPUs

```bash
systemctl status nvidia-dcgm --no-pager   # or: nv-hostengine running as a process
dcgmi discovery -l
```

Sample output:

```
2 GPUs found.
+--------+----------------------------------------------------------------------+
| GPU ID | Device Information                                                   |
+--------+----------------------------------------------------------------------+
| 0      | Name: NVIDIA H100 80GB HBM3                                          |
|        | PCI Bus ID: 00000000:18:00.0                                         |
|        | Device UUID: GPU-5a1c8e0f-3b2d-4c7e-9f11-0a2b3c4d5e6f                |
+--------+----------------------------------------------------------------------+
| 1      | Name: NVIDIA H100 80GB HBM3                                          |
|        | PCI Bus ID: 00000000:2A:00.0                                         |
|        | Device UUID: GPU-7d2e9f10-4c3e-5d8f-a022-1b3c4d5e6f70                |
+--------+----------------------------------------------------------------------+
```

**Question:**

8. **Q2.1a** DCGM has a host engine (`nv-hostengine`) and clients (`dcgmi`, `dcgm-exporter`). Why does this architecture scale better than every tool polling NVML on its own?

### Step 2.2 — Compare coarse utilization with profiling metrics

Watch these fields while a workload runs:

| Field ID | Name | Meaning |
|---|---|---|
| 203 | `DCGM_FI_DEV_GPU_UTIL` | % of time at least one kernel was running |
| 1001 | `DCGM_FI_PROF_GR_ENGINE_ACTIVE` | Fraction of time the graphics/compute engine was active |
| 1002 | `DCGM_FI_PROF_SM_ACTIVE` | Fraction of time at least one warp was resident on an SM, averaged over all SMs |
| 1003 | `DCGM_FI_PROF_SM_OCCUPANCY` | Resident warps relative to the theoretical maximum |
| 1004 | `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE` | Fraction of cycles the Tensor Core pipe was active |
| 1005 | `DCGM_FI_PROF_DRAM_ACTIVE` | Fraction of cycles the memory interface was busy |

```bash
dcgmi dmon -i 0 -e 203,1001,1002,1003,1004,1005 -d 1000 -c 5
```

Sample output for **workload A** (a small-batch inference service):

```
#Entity   GPUTL  GRACT  SMACT  SMOCC  TENSO  DRAMA
ID
GPU 0       100  0.981  0.214  0.061  0.032  0.118
GPU 0       100  0.979  0.209  0.058  0.030  0.121
GPU 0       100  0.983  0.218  0.063  0.034  0.117
```

Sample output for **workload B** (large-batch LLM training with mixed precision):

```
#Entity   GPUTL  GRACT  SMACT  SMOCC  TENSO  DRAMA
ID
GPU 0       100  0.996  0.932  0.412  0.611  0.574
GPU 0       100  0.995  0.928  0.405  0.598  0.581
GPU 0       100  0.997  0.935  0.418  0.620  0.566
```

**Questions:**

9. **Q2.2a** Both workloads report `GPUTL = 100`. Explain in mechanical terms how a GPU can be at "100% utilization" while about 80% of its SMs sit idle (workload A).
10. **Q2.2b** For workload A, propose two changes at the application or platform level that would raise `SMACT` and `TENSO`.
11. **Q2.2c** Workload B shows `TENSO ≈ 0.6` and `DRAMA ≈ 0.57`. Is it more likely to be compute-bound or memory-bound? What would you check next?
12. **Q2.2d** A manager wants one KPI for "GPU efficiency" across the cluster. Which of the fields above would you recommend, and why not `DCGM_FI_DEV_GPU_UTIL`?

### Step 2.3 — Profiling multiplexing limits

Run:

```bash
dcgmi profile -l -i 0
```

**Question:**

13. **Q2.3a** Some profiling metrics cannot be collected at the same time on some GPU architectures, so DCGM multiplexes them. What practical effect does multiplexing have on your dashboards? Why does it matter if two tools (for example, `dcgm-exporter` and Nsight) both try to profile the same GPU?

---

## Exercise 3 — Thermal, power and clock events (throttling)

**Goal:** learn to spot when a GPU runs below its expected performance, and identify the cause from the clock-event (throttle) reasons.

### Step 3.1 — Read the performance section

```bash
nvidia-smi -q -d PERFORMANCE -i 0
```

Sample output (newer drivers print "Clocks Event Reasons"; older drivers print "Clocks Throttle Reasons"):

```
==============NVSMI LOG==============

Attached GPUs                             : 2
GPU 00000000:18:00.0
    Performance State                     : P0
    Clocks Event Reasons
        Idle                              : Not Active
        Applications Clocks Setting       : Not Active
        SW Power Cap                      : Active
        HW Slowdown                       : Not Active
            HW Thermal Slowdown           : Not Active
            HW Power Brake Slowdown       : Not Active
        Sync Boost                        : Not Active
        SW Thermal Slowdown               : Not Active
        Display Clock Setting             : Not Active
```

**Questions:**

14. **Q3.1a** What does `SW Power Cap: Active` mean? Is it a hardware fault?
15. **Q3.1b** Rank these reasons from "normal operation" to "investigate the hardware/facility now": `SW Power Cap`, `HW Thermal Slowdown`, `HW Power Brake Slowdown`, `Idle`, `SW Thermal Slowdown`.

### Step 3.2 — Decode the bitmask

DCGM field 112 (`DCGM_FI_DEV_CLOCK_THROTTLE_REASONS`, renamed to `DCGM_FI_DEV_CLOCKS_EVENT_REASONS` in newer releases) and the `nvidia-smi` field `clocks_event_reasons.active` both expose a bitmask:

| Bit (hex) | Decimal | Reason |
|---|---|---|
| `0x1` | 1 | GPU idle |
| `0x2` | 2 | Applications clocks setting |
| `0x4` | 4 | SW power cap |
| `0x8` | 8 | HW slowdown |
| `0x10` | 16 | Sync boost |
| `0x20` | 32 | SW thermal slowdown |
| `0x40` | 64 | HW thermal slowdown |
| `0x80` | 128 | HW power brake slowdown |
| `0x100` | 256 | Display clock setting |

```bash
nvidia-smi --query-gpu=index,clocks_event_reasons.active,temperature.gpu,power.draw --format=csv
```

Sample output:

```
index, clocks_event_reasons.active, temperature.gpu, power.draw [W]
0, 0x0000000000000004, 71, 699.12 W
1, 0x0000000000000068, 92, 410.55 W
2, 0x0000000000000001, 33, 68.40 W
3, 0x0000000000000088, 58, 205.10 W
```

**Questions:**

16. **Q3.2a** Decode each GPU's bitmask and say what you would do about each one.
17. **Q3.2b** GPU 3 is cool (58 °C) and draws little power, yet its clocks are reduced. What is the most likely source of the signal, and which team or system do you involve?
18. **Q3.2c** PromQL has no bitwise AND operator. Write an expression that returns 1 when the HW thermal slowdown bit (`0x40`) is set in a gauge named `DCGM_FI_DEV_CLOCK_THROTTLE_REASONS`.

### Step 3.3 — Power limits and energy

```bash
nvidia-smi -q -d POWER -i 0
dcgmi dmon -i 0 -e 155,156,160 -d 2000 -c 3
```

Sample DCGM output (155 = power usage in W, 156 = total energy consumption in mJ since driver load, 160 = enforced power management limit in W):

```
#Entity   POWER       TOTEC      PMLMT
ID
GPU 0     699.21  91234567890   700.00
GPU 0     698.87  91235966010   700.00
GPU 0     699.40  91237364810   700.00
```

**Questions:**

19. **Q3.3a** Using the energy counter, compute the average power over the second 2-second interval. Why is a counter better for energy accounting (chargeback, PUE studies) than averaging sampled instantaneous power?
20. **Q3.3b** An administrator lowers the power limit to 500 W with `nvidia-smi -pl 500` to stay within rack power. What do you expect to happen to `SW Power Cap`, to SM clocks and to job duration? Is energy-per-job necessarily worse?

---

## Exercise 4 — Memory health: ECC, row remapping and Xid errors

**Goal:** read the GPU memory error counters, understand the difference between correctable and uncorrectable errors, and connect them to Xid events and to "drain the node" decisions.

### Step 4.1 — ECC counters

```bash
nvidia-smi -q -d ECC -i 0
```

Sample output (trimmed):

```
    ECC Mode
        Current                           : Enabled
        Pending                           : Enabled
    ECC Errors
        Volatile
            SRAM Correctable              : 0
            SRAM Uncorrectable Parity     : 0
            SRAM Uncorrectable SEC-DED    : 0
            DRAM Correctable              : 142
            DRAM Uncorrectable            : 0
        Aggregate
            SRAM Correctable              : 0
            SRAM Uncorrectable Parity     : 0
            SRAM Uncorrectable SEC-DED    : 0
            DRAM Correctable              : 1893
            DRAM Uncorrectable            : 2
```

**Questions:**

21. **Q4.1a** What is the difference between **Volatile** and **Aggregate** counters? Which one do you use for a rate-based alert, and which one for lifetime trending?
22. **Q4.1b** A correctable (single-bit, SBE) error was fixed by ECC. Why monitor it at all?
23. **Q4.1c** The aggregate counter shows `DRAM Uncorrectable: 2`. What happened to the workloads that were running when those errors occurred?

### Step 4.2 — Row remapping (Ampere and later)

```bash
nvidia-smi -q -d ROW_REMAPPER -i 0
```

Sample output:

```
    Remapped Rows
        Correctable Error                 : 3
        Uncorrectable Error               : 2
        Pending                           : Yes
        Remapping Failure Occurred        : No
        Bank Remap Availability Histogram
            Max                           : 638 bank(s)
            High                          : 2 bank(s)
            Partial                       : 0 bank(s)
            Low                           : 0 bank(s)
            None                          : 0 bank(s)
```

The matching DCGM fields are `DCGM_FI_DEV_CORRECTABLE_REMAPPED_ROWS`, `DCGM_FI_DEV_UNCORRECTABLE_REMAPPED_ROWS` and `DCGM_FI_DEV_ROW_REMAP_FAILURE`. Pre-Ampere GPUs (Volta and earlier) use page retirement instead: `DCGM_FI_DEV_RETIRED_SBE`, `DCGM_FI_DEV_RETIRED_DBE` and `DCGM_FI_DEV_RETIRED_PENDING`.

**Questions:**

24. **Q4.2a** `Pending: Yes`. What operational action is required for the remap to take effect? What should the scheduler do with this GPU in the meantime?
25. **Q4.2b** `Remapping Failure Occurred: Yes` would change the decision completely. Why?
26. **Q4.2c** What is the advantage of row remapping over the older page retirement mechanism?

### Step 4.3 — Xid errors in the kernel log

```bash
sudo dmesg -T | grep -i xid
# or
sudo journalctl -k --since "24 hours ago" | grep -i "NVRM: Xid"
```

Sample output:

```
[Fri Nov 13 02:14:07 2026] NVRM: Xid (PCI:0000:18:00): 63, pid='<unknown>', name=<unknown>, Row Remapper: New row (0x00000000001a2b3c) marked for remapping, reset gpu to activate.
[Fri Nov 13 02:14:07 2026] NVRM: Xid (PCI:0000:18:00): 94, pid=48211, name=python3, Contained: CE User Channel (0x9). RST: No, D-RST: No
[Fri Nov 13 09:40:51 2026] NVRM: Xid (PCI:0000:2a:00): 13, pid=50117, name=python3, Graphics Exception: ESR 0x404600=0x80000002
[Fri Nov 13 11:02:33 2026] NVRM: Xid (PCI:0000:3b:00): 79, pid='<unknown>', name=<unknown>, GPU has fallen off the bus.
```

**Questions:**

27. **Q4.3a** Classify each Xid as **likely application/software**, **memory hardware**, or **severe hardware/platform**. Give the action for each.
28. **Q4.3b** Xid 94 is "contained" and Xid 95 is "uncontained". What is the operational difference?
29. **Q4.3c** In `dcgm-exporter`, `DCGM_FI_DEV_XID_ERRORS` holds the **value of the last Xid**, not a count. What mistake does that cause if someone writes `rate(DCGM_FI_DEV_XID_ERRORS[5m]) > 0`?

---

## Exercise 5 — Interconnect: topology, NVLink and PCIe

**Goal:** check that GPUs talk to each other and to the host over the expected paths, at the expected bandwidth, without link errors.

### Step 5.1 — Topology

```bash
nvidia-smi topo -m
```

Sample output (trimmed, 4 GPUs and 2 NICs):

```
        GPU0    GPU1    GPU2    GPU3    NIC0    NIC1    CPU Affinity    NUMA Affinity
GPU0     X      NV18    NV18    NV18    PIX     SYS     0-55            0
GPU1    NV18     X      NV18    NV18    PIX     SYS     0-55            0
GPU2    NV18    NV18     X      NV18    SYS     PIX     56-111          1
GPU3    NV18    NV18    NV18     X      SYS     PIX     56-111          1
NIC0    PIX     PIX     SYS     SYS      X      SYS
NIC1    SYS     SYS     PIX     PIX     SYS      X

Legend:
  X    = Self
  SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes
  NODE = Connection traversing PCIe as well as the interconnect between PCIe Host Bridges within a NUMA node
  PHB  = Connection traversing PCIe as well as a PCIe Host Bridge (typically the CPU)
  PXB  = Connection traversing multiple PCIe bridges (without traversing the PCIe Host Bridge)
  PIX  = Connection traversing at most a single PCIe bridge
  NV#  = Connection traversing a bonded set of # NVLinks
```

**Questions:**

30. **Q5.1a** A distributed job on this node pins its GPU0 rank to CPU cores 60–70 and sends RDMA traffic through NIC1. What performance problem do you expect, and why?
31. **Q5.1b** After a maintenance window, the matrix shows `SYS` between GPU0 and GPU1 instead of `NV18`. What does that indicate?

### Step 5.2 — NVLink state and errors

```bash
nvidia-smi nvlink -s -i 0
nvidia-smi nvlink -e -i 0
```

Sample output (trimmed):

```
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-5a1c8e0f-...)
     Link 0: 26.562 GB/s
     Link 1: 26.562 GB/s
     Link 2: <inactive>
     ...
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-5a1c8e0f-...)
     Link 0: Replay Errors: 0
     Link 0: Recovery Errors: 0
     Link 0: CRC Errors: 0
     Link 2: Replay Errors: 1204
     Link 2: Recovery Errors: 37
     Link 2: CRC Errors: 9811
```

**Questions:**

32. **Q5.2a** Link 2 is inactive and has a history of CRC and recovery errors. What is the likely impact on NCCL all-reduce performance? What Xid would you expect in the logs?
33. **Q5.2b** Which DCGM health watch system covers this, and which DCGM field gives aggregate NVLink throughput for dashboards?

### Step 5.3 — PCIe link and replays

```bash
nvidia-smi --query-gpu=index,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max --format=csv
dcgmi dmon -i 0 -e 202,1009,1010 -d 1000 -c 3
```

Sample output:

```
index, pcie.link.gen.current, pcie.link.gen.max, pcie.link.width.current, pcie.link.width.max
0, 5, 5, 16, 16
1, 5, 5, 8, 16

#Entity   PCIRP        PCITX        PCIRX
ID
GPU 0         0    1932145664    220147712
GPU 0         0    1940881408    221356032
GPU 0         0    1928443904    219820544
```

**Questions:**

34. **Q5.3a** GPU 1 negotiated x8 instead of x16 while under load. List two likely physical causes. Why might this show up in a data-loading-heavy job but not in an NVLink-heavy one?
35. **Q5.3b** Note that `pcie.link.gen.current` can legitimately drop when the GPU is idle. Why must you check the link generation **under load** before you conclude anything?
36. **Q5.3c** Field 202 (`DCGM_FI_DEV_PCIE_REPLAY_COUNTER`) is a cumulative counter. Write a PromQL alert expression for "more than 100 replays in 10 minutes".

---

## Exercise 6 — DCGM health watches, active diagnostics and job statistics

**Goal:** go from passive metrics to DCGM's built-in health logic. Use passive watches for continuous checking, active diagnostics for validation, and job statistics for per-job accounting.

### Step 6.1 — Create a group and enable health watches

```bash
dcgmi group -c training-nodes -a 0,1
dcgmi group -l
dcgmi health -g 1 -s pmint     # p=PCIe, m=memory, i=InfoROM, n=NVLink, t=thermal & power
dcgmi health -g 1 -f           # show which watches are set
```

Sample output:

```
Successfully created group "training-nodes" with a group ID of 1
Health monitor systems report successfully set.

+---------------------------+------------------------------------------------+
| Health Monitor Report                                                      |
+===========================+================================================+
| Group 1                   |                                                |
| +-- PCIe                  | On                                             |
| +-- NVLINK                | On                                             |
| +-- Memory                | On                                             |
| +-- SM                    | Off                                            |
| +-- InfoROM               | On                                             |
| +-- Thermal               | On                                             |
| +-- Power                 | On                                             |
| +-- Driver                | Off                                            |
+---------------------------+------------------------------------------------+
```

### Step 6.2 — Check health

```bash
dcgmi health -g 1 -c
```

Sample output:

```
+---------------------------+------------------------------------------------+
| Health Monitor Report                                                      |
+===========================+================================================+
| Overall Health            | Warning                                        |
| GPU                       |                                                |
| -> 1                      | Warning                                        |
|    -> Errors              |                                                |
|       -> Memory system    | Warning                                        |
|                           | GPU 1 has a pending row remap; reset the GPU   |
|                           | to activate it.                                |
+---------------------------+------------------------------------------------+
```

**Questions:**

37. **Q6.2a** What is the difference between a health watch (`dcgmi health`) and simply alerting on raw fields in Prometheus? When would you rely on each?
38. **Q6.2b** How would a Kubernetes or Slurm integration typically act on `Warning` versus `Failure`?

### Step 6.3 — Active diagnostics

```bash
dcgmi diag -r 1     # quick: deployment/software checks, seconds
dcgmi diag -r 2     # medium: adds short hardware tests, about 1–2 min
dcgmi diag -r 3     # long: adds stress/bandwidth tests, about 10–30 min
```

Sample output (`-r 3`, trimmed):

```
+---------------------------+------------------------------------------------+
| Diagnostic                | Result                                         |
+===========================+================================================+
|-----  Metadata  ----------+------------------------------------------------|
| DCGM Version              | 3.3.x                                          |
| Number of GPUs Detected   | 2                                              |
|-----  Deployment  --------+------------------------------------------------|
| Denylist                  | Pass                                           |
| NVML Library              | Pass                                           |
| CUDA Main Library         | Pass                                           |
| Permissions and OS Blocks | Pass                                           |
| Persistence Mode          | Pass                                           |
| Environment Variables     | Pass                                           |
| Page Retirement/Row Remap | Fail - GPU: 1                                  |
| Graphics Processes        | Pass                                           |
| Inforom                   | Pass                                           |
+-----  Integration  -------+------------------------------------------------+
| PCIe                      | Pass - All                                     |
+-----  Hardware  ----------+------------------------------------------------+
| GPU Memory                | Pass - GPU: 0                                  |
|                           | Skip - GPU: 1                                  |
| Diagnostic                | Pass - All                                     |
+-----  Stress  ------------+------------------------------------------------+
| Targeted Stress           | Pass - All                                     |
| Targeted Power            | Pass - All                                     |
| Memory Bandwidth          | Pass - All                                     |
+---------------------------+------------------------------------------------+
```

**Questions:**

39. **Q6.3a** When is it appropriate to run `-r 3`, and when is it inappropriate? Consider running workloads, duration and power draw.
40. **Q6.3b** Propose a policy for when each diagnostic level runs during a node's lifecycle: provisioning, between jobs, after an alert, after an RMA.

### Step 6.4 — Per-job statistics

```bash
dcgmi stats -g 1 -e                 # enable stats collection on group 1
dcgmi stats -g 1 -s job-4711        # start recording for a job
# ... job runs ...
dcgmi stats -x job-4711             # stop recording
dcgmi stats -j job-4711 -v          # verbose report
```

Sample output (trimmed):

```
Successfully retrieved statistics for job: job-4711.
+------------------------------------------------------------------------------+
| GPU ID: 0                                                                    |
+====================================+=========================================+
|-----  Execution Stats  ------------+-----------------------------------------|
| Start Time                         | Fri Nov 13 14:00:02 2026                |
| End Time                           | Fri Nov 13 17:12:45 2026                |
| Total Execution Time (sec)         | 11563.12                                |
|-----  Performance Stats  ----------+-----------------------------------------|
| Energy Consumed (Joules)           | 7395210                                 |
| Power Usage (Watts)                | Avg: 639.5, Max: 701.2, Min: 88.0       |
| SM Clock (MHz)                     | Avg: 1702, Max: 1980, Min: 345          |
| Memory Utilization (%)             | Avg: 41, Max: 72, Min: 0                |
| Max GPU Memory Used (bytes)        | 81134076313                             |
|-----  Event Stats  ----------------+-----------------------------------------|
| Single Bit ECC Errors              | 0                                       |
| Double Bit ECC Errors              | 0                                       |
| PCIe Replay Warnings               | 0                                       |
| Critical XID Errors                | 0                                       |
|-----  Slowdown Stats  -------------+-----------------------------------------|
| Due to - Power (%)                 | 18.2                                    |
|        - Thermal (%)               | 0                                       |
|        - Reliability (%)           | 0                                       |
|        - Board Limit (%)           | 0                                       |
|        - Low Utilization (%)       | 0                                       |
|        - Sync Boost (%)            | 0                                       |
+------------------------------------+-----------------------------------------+
```

**Questions:**

41. **Q6.4a** Convert the energy consumed to kWh. A colleague says the job "was healthy and efficient". Which line in the report qualifies that claim?
42. **Q6.4b** Why is per-job accounting important in a shared AI platform such as one managed by NVIDIA Base Command or Run:ai?

---

## Exercise 7 — Kubernetes: `dcgm-exporter`, Prometheus and pod attribution

**Goal:** turn node-level GPU telemetry into cluster-level, pod-attributed observability with alerts.

### Step 7.1 — Locate the exporter

With the NVIDIA GPU Operator, `dcgm-exporter` runs as a DaemonSet on every GPU node.

```bash
kubectl get ds -n gpu-operator
kubectl -n gpu-operator get pods -l app=nvidia-dcgm-exporter -o wide
kubectl -n gpu-operator port-forward svc/nvidia-dcgm-exporter 9400:9400 &
curl -s localhost:9400/metrics | grep -E '^DCGM_FI_(DEV_GPU_UTIL|PROF_GR_ENGINE_ACTIVE)' | head -4
```

Sample output:

```
NAME                          DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR                                    AGE
nvidia-dcgm-exporter          3         3         3       3            3           nvidia.com/gpu.deploy.dcgm-exporter=true         41d
nvidia-device-plugin-daemonset 3        3         3       3            3           nvidia.com/gpu.deploy.device-plugin=true         41d

DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-5a1c8e0f-...",pci_bus_id="00000000:18:00.0",device="nvidia0",modelName="NVIDIA H100 80GB HBM3",Hostname="gpu-node-01",container="trainer",namespace="ml-team-a",pod="llm-pretrain-0"} 100
DCGM_FI_DEV_GPU_UTIL{gpu="1",UUID="GPU-7d2e9f10-...",pci_bus_id="00000000:2A:00.0",device="nvidia1",modelName="NVIDIA H100 80GB HBM3",Hostname="gpu-node-01"} 0
DCGM_FI_PROF_GR_ENGINE_ACTIVE{gpu="0",UUID="GPU-5a1c8e0f-...",pci_bus_id="00000000:18:00.0",device="nvidia0",modelName="NVIDIA H100 80GB HBM3",Hostname="gpu-node-01",container="trainer",namespace="ml-team-a",pod="llm-pretrain-0"} 0.996
DCGM_FI_PROF_GR_ENGINE_ACTIVE{gpu="1",UUID="GPU-7d2e9f10-...",pci_bus_id="00000000:2A:00.0",device="nvidia1",modelName="NVIDIA H100 80GB HBM3",Hostname="gpu-node-01"} 0
```

**Questions:**

43. **Q7.1a** GPU 0 carries `pod`, `namespace` and `container` labels and GPU 1 does not. How does `dcgm-exporter` learn which pod owns a GPU? What does the absence of those labels on GPU 1 mean?
44. **Q7.1b** In some Prometheus setups the labels appear as `exported_pod` and `exported_namespace`. Why? Which `ServiceMonitor` setting changes that behaviour?

### Step 7.2 — Add a custom metric (throttle reasons)

The default metrics CSV does not include every field. Create a ConfigMap with a custom list, then point the GPU Operator at it.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: dcgm-custom-metrics
  namespace: gpu-operator
data:
  dcgm-metrics.csv: |
    # Format: DCGM field, Prometheus metric type, help message
    DCGM_FI_DEV_GPU_TEMP, gauge, GPU temperature (C).
    DCGM_FI_DEV_MEMORY_TEMP, gauge, Memory temperature (C).
    DCGM_FI_DEV_POWER_USAGE, gauge, Power draw (W).
    DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION, counter, Total energy since boot (mJ).
    DCGM_FI_DEV_SM_CLOCK, gauge, SM clock frequency (MHz).
    DCGM_FI_DEV_CLOCK_THROTTLE_REASONS, gauge, Clock throttle reasons bitmask.
    DCGM_FI_DEV_FB_USED, gauge, Framebuffer memory used (MiB).
    DCGM_FI_DEV_FB_FREE, gauge, Framebuffer memory free (MiB).
    DCGM_FI_DEV_XID_ERRORS, gauge, Value of the last XID error encountered.
    DCGM_FI_DEV_PCIE_REPLAY_COUNTER, counter, Total number of PCIe retries.
    DCGM_FI_DEV_CORRECTABLE_REMAPPED_ROWS, counter, Rows remapped for correctable errors.
    DCGM_FI_DEV_UNCORRECTABLE_REMAPPED_ROWS, counter, Rows remapped for uncorrectable errors.
    DCGM_FI_DEV_ROW_REMAP_FAILURE, gauge, Whether remapping of rows has failed.
    DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL, counter, Total NVLink bandwidth counter.
    DCGM_FI_PROF_GR_ENGINE_ACTIVE, gauge, Ratio of time the graphics engine is active.
    DCGM_FI_PROF_SM_ACTIVE, gauge, Ratio of cycles an SM has at least one warp assigned.
    DCGM_FI_PROF_PIPE_TENSOR_ACTIVE, gauge, Ratio of cycles the tensor pipe is active.
    DCGM_FI_PROF_DRAM_ACTIVE, gauge, Ratio of cycles the memory interface is active.
```

```bash
kubectl apply -f dcgm-custom-metrics.yaml
kubectl patch clusterpolicies.nvidia.com/cluster-policy --type merge -p \
  '{"spec":{"dcgmExporter":{"config":{"name":"dcgm-custom-metrics"},"env":[{"name":"DCGM_EXPORTER_COLLECTORS","value":"/etc/dcgm-exporter/dcgm-metrics.csv"}]}}}'
kubectl -n gpu-operator rollout status ds/nvidia-dcgm-exporter
```

**Questions:**

45. **Q7.2a** Why should you not export *every* available DCGM field at a 1-second interval across a 2,000-GPU cluster? Name two costs.
46. **Q7.2b** Why is `DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION` declared as a `counter` while `DCGM_FI_DEV_POWER_USAGE` is a `gauge`? Which PromQL function do you use on each?

### Step 7.3 — Alerting and recording rules

Apply this `PrometheusRule`. The `release` label must match your kube-prometheus-stack rule selector.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gpu-monitoring
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: gpu.recording
      interval: 30s
      rules:
        - record: namespace:gpu_gr_engine_active:avg
          expr: |
            avg by (namespace) (
              DCGM_FI_PROF_GR_ENGINE_ACTIVE{namespace!=""}
            )
        - record: cluster:gpu_allocated_idle:count
          expr: |
            count(
              avg_over_time(DCGM_FI_PROF_GR_ENGINE_ACTIVE{pod!=""}[30m]) < 0.05
            )
    - name: gpu.health
      rules:
        - alert: GPUFellOffBus
          expr: DCGM_FI_DEV_XID_ERRORS == 79
          for: 0m
          labels:
            severity: critical
          annotations:
            summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} reported Xid 79 (fallen off the bus)"
            runbook: "Cordon and drain the node, collect nvidia-bug-report.sh, power-cycle via BMC."
        - alert: GPURowRemapFailure
          expr: DCGM_FI_DEV_ROW_REMAP_FAILURE > 0
          for: 0m
          labels:
            severity: critical
          annotations:
            summary: "Row remap failure on GPU {{ $labels.gpu }} ({{ $labels.UUID }})"
        - alert: GPUUncorrectableRemappedRowsIncreased
          expr: increase(DCGM_FI_DEV_UNCORRECTABLE_REMAPPED_ROWS[1h]) > 0
          for: 0m
          labels:
            severity: warning
          annotations:
            summary: "New uncorrectable remapped row on GPU {{ $labels.gpu }}; GPU reset required"
        - alert: GPUHardwareThermalSlowdown
          expr: |
            floor(DCGM_FI_DEV_CLOCK_THROTTLE_REASONS / 64) % 2 == 1
          for: 2m
          labels:
            severity: warning
          annotations:
            summary: "HW thermal slowdown on GPU {{ $labels.gpu }} at {{ $labels.Hostname }}"
        - alert: GPUPCIeReplaysHigh
          expr: increase(DCGM_FI_DEV_PCIE_REPLAY_COUNTER[10m]) > 100
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "PCIe replays rising on GPU {{ $labels.gpu }}; check riser, slot and link width"
        - alert: GPUAllocatedButIdle
          expr: |
            avg_over_time(DCGM_FI_PROF_GR_ENGINE_ACTIVE{pod!=""}[1h]) < 0.05
          for: 1h
          labels:
            severity: info
          annotations:
            summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} holds a GPU but used under 5% of it for 2h"
        - alert: DCGMExporterMissing
          expr: |
            absent_over_time(DCGM_FI_DEV_GPU_TEMP[5m])
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "No GPU telemetry received for 5 minutes: dcgm-exporter or Prometheus scrape is broken"
```

```bash
kubectl apply -f gpu-monitoring-rules.yaml
kubectl -n monitoring get prometheusrules gpu-monitoring
```

**Questions:**

47. **Q7.3a** Why does `GPUFellOffBus` use `for: 0m` while `GPUHardwareThermalSlowdown` uses `for: 2m`?
48. **Q7.3b** `GPUAllocatedButIdle` has severity `info` and no page. What business problem does it address? Which NVIDIA platforms named in the references address the same problem through scheduling (fractional GPUs, quotas, preemption)?
49. **Q7.3c** Why is `DCGMExporterMissing` essential? What failure mode would otherwise leave every other rule silent?
50. **Q7.3d** Walk through how `floor(x / 64) % 2 == 1` tests bit `0x40` using the values `0x68` (104) and `0x88` (136).

---

## Exercise 8 — Monitoring MIG instances

**Goal:** understand how GPU telemetry changes when a GPU is partitioned with Multi-Instance GPU (MIG).

### Step 8.1 — Inspect MIG layout

```bash
nvidia-smi -i 0 -q | grep -A2 "MIG Mode"
nvidia-smi mig -lgi -i 0
nvidia-smi -L
```

Sample output:

```
    MIG Mode
        Current                           : Enabled
        Pending                           : Enabled

+----------------------------------------------------+
| GPU instances:                                     |
| GPU   Name          Profile  Instance   Placement  |
|                       ID       ID       Start:Size |
|====================================================|
|   0  MIG 3g.40gb       9        1          0:4     |
|   0  MIG 2g.20gb      14        3          4:2     |
|   0  MIG 1g.10gb      19        9          6:1     |
|   0  MIG 1g.10gb      19       10          7:1     |
+----------------------------------------------------+

GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-5a1c8e0f-...)
  MIG 3g.40gb     Device  0: (UUID: MIG-1f2e3d4c-...)
  MIG 2g.20gb     Device  1: (UUID: MIG-2a3b4c5d-...)
  MIG 1g.10gb     Device  2: (UUID: MIG-3c4d5e6f-...)
  MIG 1g.10gb     Device  3: (UUID: MIG-4d5e6f70-...)
```

### Step 8.2 — Telemetry per instance

```bash
dcgmi discovery -c
dcgmi dmon -e 203,1001,1002,252 -d 1000 -c 2
```

Sample output (trimmed; `GPU-I` = GPU instance entity):

```
#Entity      GPUTL   GRACT   SMACT   FBUSD
ID
GPU 0          N/A   0.612   0.540   61440
GPU-I 1        N/A   0.940   0.902   38912
GPU-I 3        N/A   0.721   0.633   18432
GPU-I 9        N/A   0.018   0.010    4096
GPU-I 10       N/A   0.000   0.000       0
```

`dcgm-exporter` adds `GPU_I_ID` and `GPU_I_PROFILE` labels to per-instance series, for example `GPU_I_PROFILE="1g.10gb"`.

**Questions:**

51. **Q8.2a** Why is `DCGM_FI_DEV_GPU_UTIL` reported as N/A in MIG mode? Which metric replaces it?
52. **Q8.2b** Which metrics remain **device-level** only, even with MIG enabled? Think temperature, power, ECC and Xid. What does that mean when you want to attribute a power spike to one tenant?
53. **Q8.2c** GPU-I 10 is completely idle and GPU-I 9 is nearly idle. What capacity-planning conclusion might you draw? What reconfiguration would you consider, and what does changing a MIG layout require operationally?
54. **Q8.2d** Explain why MIG provides better isolation for monitoring and QoS than time-slicing several pods onto one GPU.

---

## Exercise 9 — Out-of-band monitoring via the BMC (Redfish)

**Goal:** complement in-band telemetry (driver, DCGM) with out-of-band telemetry from the baseboard management controller.

### Step 9.1 — Query chassis thermal and power

Redfish resource paths vary by vendor and platform. Discover them from the service root first.

```bash
BMC=10.0.10.21
curl -sk -u admin:"$BMC_PASS" https://$BMC/redfish/v1/ | jq '.Chassis, .Systems, .Managers'
curl -sk -u admin:"$BMC_PASS" https://$BMC/redfish/v1/Chassis | jq '.Members'
curl -sk -u admin:"$BMC_PASS" https://$BMC/redfish/v1/Chassis/1/Thermal | jq '.Temperatures[] | {Name, ReadingCelsius, UpperThresholdCritical, Status}'
```

Sample output (no labelled `json` block here: several objects follow one another):

```
{
  "Name": "GPU0 Temp",
  "ReadingCelsius": 72,
  "UpperThresholdCritical": 90,
  "Status": { "State": "Enabled", "Health": "OK" }
}
{
  "Name": "Inlet Temp",
  "ReadingCelsius": 34,
  "UpperThresholdCritical": 42,
  "Status": { "State": "Enabled", "Health": "Warning" }
}
{
  "Name": "PSU1 Temp",
  "ReadingCelsius": 51,
  "UpperThresholdCritical": 85,
  "Status": { "State": "Enabled", "Health": "OK" }
}
```

**Questions:**

55. **Q9.1a** The inlet temperature is in `Warning`, and several GPUs on this node show `SW Thermal Slowdown`. Is the root cause the GPU, the server, or the facility? What signal would confirm it?
56. **Q9.1b** A GPU raises Xid 79 and the OS hangs, so `dcgm-exporter` stops reporting. Which telemetry and actions are still available, and why?
57. **Q9.1c** Name two signals that **only** the BMC can give you, which DCGM cannot.

---

## Exercise 10 — Synthesis: triage scenario

**Scenario.** A 16-GPU training job across 2 nodes, using NCCL over NVLink plus InfiniBand, has slowed down by 35% since yesterday. No job has failed. Your dashboards show:

| Signal | node-a GPUs 0–7 | node-b GPUs 0–6 | node-b GPU 7 |
|---|---|---|---|
| `DCGM_FI_PROF_GR_ENGINE_ACTIVE` | 0.62 | 0.61 | 0.97 |
| `DCGM_FI_PROF_SM_ACTIVE` | 0.55 | 0.54 | 0.93 |
| `DCGM_FI_DEV_SM_CLOCK` (MHz) | 1980 | 1980 | 1410 |
| `DCGM_FI_DEV_GPU_TEMP` (°C) | 66 | 67 | 88 |
| `DCGM_FI_DEV_POWER_USAGE` (W) | 520 | 515 | 455 |
| Throttle reasons | `0x0` | `0x0` | `0x60` |
| `DCGM_FI_DEV_XID_ERRORS` | 0 | 0 | 0 |
| BMC fan "FAN4" (behind GPU7) | — | — | `Critical`, 0 RPM |

**Steps:**

1. Decode the throttle bitmask for node-b GPU 7.
2. Explain why **one** slow GPU makes the other 15 *appear* under-utilized.
3. Write the order of actions you would take, from immediate mitigation to root-cause fix.
4. Name the alert from Exercise 7 that should have fired, and propose one additional alert that would have caught this earlier.

**Questions:**

58. **Q10a** Answer steps 1–4.
59. **Q10b** Why would looking only at `DCGM_FI_DEV_GPU_UTIL` have made this incident harder to diagnose?

---

<details>
<summary><strong>Answers — click to expand</strong></summary>

### Exercise 1

**Q1.1a** `index` is an enumeration order. It can change after a reboot, after a driver change, when `CUDA_VISIBLE_DEVICES` is set, or when a GPU disappears from the bus. Use immutable identifiers: **serial** (what the vendor uses for RMA), **UUID** (what DCGM and Kubernetes use), plus **PCI bus ID** and host name to locate the physical slot.

**Q1.1b** Kernel messages, including Xid errors, identify the GPU by PCI address (`NVRM: Xid (PCI:0000:18:00)`), not by index. You need the bus ID to correlate a log line with a GPU, a pod and a physical slot.

**Q1.2a** (1) A **power cap**: at 612 W against a 700 W limit with a high transient load, the GPU boosts within the power budget, so clocks float below max. (2) **Thermal management**: memory is at 80 °C and the GPU is warming. It can also be normal **GPU Boost** behaviour, where max SM clock is an opportunistic ceiling and not a guaranteed sustained clock. You confirm which one by reading the clock-event reasons (Exercise 3).

**Q1.2b** Not by itself. PyTorch's caching allocator, and frameworks such as JAX/XLA that pre-allocate most memory by default, reserve memory and keep it. `memory.used` shows *reserved* memory, not memory being actively used. True pressure shows up as OOM errors, allocator retries, or framework-level metrics (`torch.cuda.memory_allocated()` versus `memory_reserved()`). It is still useful for capacity questions: "can a second process fit on this GPU?"

**Q1.2c** Utilization & efficiency: `utilization.gpu`, `utilization.memory`, `memory.used`, `memory.total`. Thermal/power/clocks: `temperature.gpu`, `temperature.memory`, `power.draw`, `power.limit`, `clocks.sm`, `clocks.max.sm`, `pstate`. Memory health, interconnect and platform: not covered by this query.

**Q1.3a** `pviol` is the percentage of the sample interval during which the GPU was held back by **power** limits. `tviol` reports whether it was held back by **thermal** limits. A `pviol` of 12–15% means GPU 0 spends that share of time power-capped. That is not a fault, but the job is losing some throughput to the power budget.

**Q1.3b** It has no central storage or history, no correlation with jobs or pods, no alerting, coarse sampling, and its own polling overhead. Several independent pollers cause redundant NVML calls. It also misses transient events between cron runs. Fleet monitoring needs a persistent agent (DCGM host engine) and a time-series pipeline (`dcgm-exporter` → Prometheus → Alertmanager/Grafana) or Base Command–style platform telemetry.

### Exercise 2

**Q2.1a** `nv-hostengine` owns the NVML/driver interaction. It samples each field once at a configured frequency, caches it, and runs health watches and policies. Many clients read from that cache, so you avoid duplicated polling, inconsistent sampling and contention for profiling counters. It also exposes a remote API, so central tools can query many nodes.

**Q2.2a** `GPU_UTIL` is "the percentage of the sample period during which **one or more kernels** were executing". A single small kernel occupying a few SMs counts as 100%. With small batches the kernels launch too few thread blocks to fill an H100's 132 SMs, so `SMACT ≈ 0.21` reveals that about 80% of SM time is empty. `SMOCC ≈ 0.06` adds that the active SMs hold few warps.

**Q2.2b** Examples: increase batch size or enable dynamic/in-flight batching (for instance, a NIM or Triton inference server batches requests). Use an optimized engine with fused kernels (TensorRT-LLM) and lower precision so Tensor Cores are used. Pack several small services onto one GPU with MIG or fractional GPU scheduling (Run:ai) instead of giving each its own full GPU.

**Q2.2c** Both are substantial and neither is saturated. The job is reasonably balanced, perhaps leaning compute-bound with some memory stalls. Next, profile kernels with Nsight Systems/Compute. Check `DCGM_FI_PROF_NVLINK_TX_BYTES` and the PCIe bytes fields for communication or input-pipeline stalls. Compare `GR_ENGINE_ACTIVE` with `SM_ACTIVE` gaps, which indicate time spent outside SM work, such as copies or sync.

**Q2.2d** `DCGM_FI_PROF_SM_ACTIVE` is the best general "how much of the GPU is used" indicator. For AI specifically, add `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE`. `GR_ENGINE_ACTIVE` is a good, MIG-compatible "busy" indicator. `GPU_UTIL` saturates at 100% from trivial work, so it overstates efficiency and cannot rank workloads.

**Q2.3a** With multiplexing, each metric is sampled during only part of the interval. Values are extrapolated and can be noisy at short intervals, so use longer windows (for example, ≥ 1 s scrape and `avg_over_time`). The hardware performance counters are a shared, exclusive resource. If Nsight or another profiler takes them, DCGM profiling metrics may stop, return errors, or show gaps. The usual practice is to pause DCGM profiling (`dcgmi profile --pause`) while developers profile.

### Exercise 3

**Q3.1a** The driver is lowering clocks to keep board power within the configured power limit. It is a normal control loop, not a fault. It becomes an issue only if it is persistent and unexpected, for example when an administrator set a low limit, or when it causes measurable loss of throughput.

**Q3.1b** Normal → investigate: `Idle` → `SW Power Cap` → `SW Thermal Slowdown` (software keeping temperature under target, often a cooling-margin issue) → `HW Thermal Slowdown` (hardware protection at a critical temperature) and `HW Power Brake Slowdown` (external signal, typically PSU/system power trouble). The last two are hardware or facility issues to investigate now.

**Q3.2a**
- GPU 0, `0x4`: SW power cap. Normal at 699 W ≈ limit. Act only if you need the throughput and the facility allows a higher limit.
- GPU 1, `0x68` = `0x40 + 0x20 + 0x8`: HW thermal slowdown, SW thermal slowdown and HW slowdown. At 92 °C this is overheating. Drain the GPU, check fans, airflow, inlet temperature and blanking panels, and compare with other GPUs on the same node.
- GPU 2, `0x1`: idle. Nothing to do.
- GPU 3, `0x88` = `0x80 + 0x8`: HW power brake slowdown and HW slowdown. This is an external power-brake signal.

**Q3.2b** HW power brake is asserted by the **system or platform**, typically when a PSU fails, a PSU is missing redundancy, or there is a power-supply event. It does not come from the GPU's own temperature or power. Involve the server vendor and data-center/facilities team, and check BMC PSU status and event logs (Exercise 9).

**Q3.2c** `floor(DCGM_FI_DEV_CLOCK_THROTTLE_REASONS / 64) % 2 == 1`. Integer-divide by 2⁶ to shift bit 6 into position 0, then take modulo 2. Add `bool` (`... % 2 == bool 1`) if you want a 0/1 result instead of a filter.

**Q3.3a** ΔE = 91,235,966,010 − 91,234,567,890 = 1,398,120 mJ = 1,398.12 J over 2 s, giving **≈ 699.06 W**. A counter integrates every power change between samples. Averaging sampled gauges misses spikes and dips, and Prometheus can lose samples, whereas `increase()` on a counter does not lose energy between scrapes.

**Q3.3b** `SW Power Cap` becomes active more often. SM clocks drop and become more variable, and step time and job duration increase. Energy per job is **not necessarily** worse. GPUs are often more energy-efficient at lower clocks because power rises super-linearly with frequency and voltage, so a power-capped run can use less total energy despite taking longer. Measure it with the energy counter.

### Exercise 4

**Q4.1a** Volatile counters reset at driver reload or GPU reset. Aggregate counters persist across reboots (stored in InfoROM). Use volatile (or the rate of aggregate) for "errors are happening now". Use aggregate for lifetime health trends and RMA evidence.

**Q4.1b** A rising SBE rate is an early indicator of degrading memory cells. It also feeds row remapping. On many GPUs a high SBE rate generates Xid 92. Trending it lets you schedule replacement before uncorrectable errors occur.

**Q4.1c** An uncorrectable (DBE) error means data was corrupted and could not be fixed. The affected workload is killed by the driver or has its context terminated. On recent GPUs, if the error is "contained", only the processes using that memory are terminated. The GPU then needs a row remap (and reset) to stop reusing the bad row.

**Q4.2a** Reset the GPU (`nvidia-smi -r` with no processes running) or reboot the node, so the remap is applied. Until then, the scheduler should **cordon or drain** the GPU or node, so no new jobs run on memory that already has a known-bad row.

**Q4.2b** It means the GPU ran out of spare rows in the affected bank, so the bad memory cannot be isolated. The GPU cannot be trusted and must be **removed from service and RMA'd**. A reset does not fix it.

**Q4.2c** Row remapping replaces a faulty DRAM row with a spare row **in hardware**, so the full memory capacity is kept and it is transparent to software. Page retirement removed pages from the allocatable pool (reducing capacity) and relied on the driver blacklisting them. Row remapping also reports bank availability so you can see how much sparing headroom is left.

**Q4.3a**
- **Xid 63** (row remap recorded, pending): memory hardware. Drain and reset to activate the remap, and trend the counts.
- **Xid 94** (contained ECC error): memory hardware, with only the affected process killed. The GPU can continue after a reset and remap. Monitor for recurrence.
- **Xid 13** (graphics engine exception): usually application/software, such as an illegal memory access or a kernel bug. Check the app and CUDA errors. Escalate only if it repeats across different apps or GPUs.
- **Xid 79** (fallen off the bus): severe hardware/platform issue (PCIe, power, thermal, board). Drain the node, collect `nvidia-bug-report.sh`, power-cycle through the BMC, inspect the slot, riser and PSU. RMA if it repeats.

**Q4.3b** Contained (94): the error was isolated to the affected contexts, which are terminated, and other workloads on the GPU keep running. Uncontained (95): the corruption could not be isolated, so all work on the GPU must stop and the GPU must be reset. In MIG or multi-tenant settings, 95 affects every tenant.

**Q4.3c** The gauge just holds the last Xid number. `rate()` assumes a monotonic counter: it treats a drop (for example, the value reset to 0 after a restart) as a counter reset and computes nonsense, and it shows zero rate while the same Xid code stays constant. Repeated identical Xids can also go unnoticed. Alert on specific values (`== 79`) or `changes(DCGM_FI_DEV_XID_ERRORS[10m]) > 0`, and use log-based alerting (dmesg/journal shipped to Loki or Elasticsearch) for full Xid history.

### Exercise 5

**Q5.1a** GPU0 has NUMA affinity 0 (cores 0–55) and is `PIX` to NIC0. Pinning to cores 60–70 (NUMA 1) and using NIC1 (`SYS` to GPU0) forces host memory traffic and GPUDirect RDMA traffic across the inter-socket link. Expect higher latency, lower bandwidth, possibly no GPUDirect RDMA path, and slower NCCL inter-node collectives. Fix it with correct CPU/NIC affinity (for example, the topology manager in Kubernetes, or `NCCL_IB_HCA` tuning).

**Q5.1b** The NVLink connection between those GPUs is down: a link failure, an NVSwitch/fabric manager problem, or a seating issue after maintenance. Traffic falls back to PCIe/SMP. Check `nvidia-smi nvlink -s`, the fabric manager service (`nvidia-fabricmanager`) on NVSwitch systems, and the Xid logs.

**Q5.2a** NCCL may route around the missing link or fall back to slower paths, which lowers all-reduce bus bandwidth. On ring/tree algorithms the slowest link limits the whole collective, so all GPUs slow down. High CRC, replay and recovery counts indicate a marginal link. Expect **Xid 74** (NVLink error).

**Q5.2b** The **NVLink** health watch (`n` in `dcgmi health -s`). For dashboards, use `DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL`, or the profiling fields `DCGM_FI_PROF_NVLINK_TX_BYTES` / `RX_BYTES` (1011/1012). Per-link error counters are also available as DCGM NVLink error fields.

**Q5.3a** A poorly seated card, a damaged or incompatible riser or cable, a dirty connector, BIOS lane bifurcation settings, or a faulty slot. A data-loading job moves data host → GPU over PCIe, so halving the lanes halves that bandwidth. An NVLink-bound job moves most data GPU ↔ GPU over NVLink and barely notices.

**Q5.3b** PCIe active-state power management lowers the link generation (and sometimes the width) when idle to save power. A Gen 1 reading on an idle GPU is normal. Only a degraded link **under load** means a problem.

**Q5.3c** `increase(DCGM_FI_DEV_PCIE_REPLAY_COUNTER[10m]) > 100`.

### Exercise 6

**Q6.2a** Health watches encode NVIDIA's knowledge of which conditions matter: thresholds, combinations, pending remaps, InfoROM corruption. They also return a pass/warn/fail verdict that schedulers can act on. Prometheus rules give you flexible, fleet-wide, historical and custom logic, plus correlation with workloads. Use health watches for **node admission and automated remediation**. Use Prometheus for **trending, capacity planning, SLOs and alert routing**. They complement each other.

**Q6.2b** `Warning`: stop scheduling new work (cordon, or put the Slurm node in drain), let current jobs finish, then remediate (for example, reset for a pending remap). `Failure`: drain immediately or set the node down, possibly evict jobs, open a hardware ticket. In Kubernetes this is commonly done with node conditions or taints set by a health-check agent, or by the GPU Operator's health components plus a remediation controller.

**Q6.3a** Level 3 stresses the GPU at full power and memory bandwidth for tens of minutes, and it needs exclusive access. It suits **burn-in at provisioning, post-RMA acceptance, and root-cause analysis on a drained node**. It is inappropriate on nodes running production jobs, which it would disrupt, and as a frequent between-job check, where it wastes capacity and power.

**Q6.3b** Example policy: provisioning or after RMA → `-r 3` (or `-r 4` where available). Before each job (prolog) → `-r 1`, which is fast. Periodically or between long jobs → `-r 2`. After a health warning or Xid → drain, then `-r 3` before returning the node to service.

**Q6.4a** 7,395,210 J ÷ 3,600,000 ≈ **2.05 kWh**. No error events means *healthy*, but `Due to - Power (%) 18.2` shows the job spent about 18% of its time power-capped, so it was not running at full potential performance. Memory utilization averaged 41%. Whether that counts as "efficient" depends on SM/Tensor activity, which this report does not show.

**Q6.4b** Many teams share expensive GPUs. Per-job energy, utilization and error data enable chargeback and showback, fair-share quotas, and spotting wasteful jobs (allocated but idle). They also tie a hardware event to the exact job affected, for reruns and user communication, and support capacity planning. Platforms like Base Command and Run:ai expose this per-job and per-project view.

### Exercise 7

**Q7.1a** `dcgm-exporter` queries the kubelet **pod-resources API** (a gRPC socket under `/var/lib/kubelet/pod-resources/`). That API maps device IDs allocated by the NVIDIA device plugin to pods and containers. GPU 1 has no labels because no pod currently holds it: the GPU is unallocated. Combined with its 0 values, it is idle capacity.

**Q7.1b** The exporter's own `pod` and `namespace` labels collide with the target labels that Prometheus attaches (the exporter pod's own name and namespace). With `honorLabels: false` (the default), Prometheus renames the scraped labels to `exported_*`. Set `honorLabels: true` on the `ServiceMonitor` endpoint (or relabel), so the workload pod labels win.

**Q7.2a** (1) **Prometheus cardinality and storage**: series × samples per second multiply with every field across thousands of GPUs, increasing memory, disk and query latency. (2) **Node overhead**: more NVML/DCGM sampling work, profiling counter contention or multiplexing, and network traffic. Export what you alert or report on, at the interval the decisions need (typically 10–30 s for most fields).

**Q7.2b** Energy is a monotonically increasing total, so it is a counter: use `increase()` or `rate()` (`rate()` of an energy counter in mJ gives average mW). Power is an instantaneous reading that goes up and down, so it is a gauge: use `avg_over_time()`, `max_over_time()` or `quantile_over_time()`.

**Q7.3a** Xid 79 is a definitive, severe, non-transient event: the GPU is gone, so waiting adds nothing. Thermal slowdown can be momentary during load spikes. Requiring 2 minutes filters noise and pages only on sustained conditions.

**Q7.3b** Idle allocated GPUs: an interactive notebook or stuck job holds a whole GPU that nobody else can use. That is wasted capital and a longer queue for other teams. **NVIDIA Run:ai** (fractional GPU allocation, quotas, over-quota and preemption, idle-job reclaiming), **Multi-Instance GPU** (hardware partitioning so small workloads do not monopolize a whole GPU), and **Base Command** (orchestrated, accounted job scheduling) address this through scheduling and partitioning.

**Q7.3c** If the exporter crashes, the node loses its GPU, or the scrape fails, every metric disappears. Rules such as `DCGM_FI_DEV_XID_ERRORS == 79` then evaluate to an empty result, which means *no alert*. The worst failures look like silence. The `absent_over_time` rule (or an `up{job="dcgm-exporter"} == 0` rule) turns missing telemetry into an alert.

**Q7.3d** 104 / 64 = 1.625, `floor` gives 1, 1 % 2 = **1**: bit `0x40` is set (0x68 includes HW thermal). 136 / 64 = 2.125, `floor` gives 2, 2 % 2 = **0**: bit `0x40` is not set (0x88 = 0x80 + 0x08, a power brake, not thermal).

### Exercise 8

**Q8.2a** `GPU_UTIL` is a device-wide engine-busy measure. It cannot be broken down per instance, and on a partitioned GPU it would not mean much. Use `DCGM_FI_PROF_GR_ENGINE_ACTIVE` (plus `SM_ACTIVE` and the other profiling fields), which DCGM reports per GPU instance.

**Q8.2b** Temperature, power draw, clocks and clock-event reasons, ECC and row remapping, Xid, PCIe and NVLink counters stay at device level. They describe the shared physical GPU. You cannot directly attribute a power spike to one tenant. You can only infer it by correlating per-instance activity (`GR_ENGINE_ACTIVE`, `DRAM_ACTIVE`) with the device power. A device-level fault (Xid 79, uncontained ECC) affects **all** instances.

**Q8.2c** The 1g slices are over-provisioned for current demand. Consider merging them into a larger profile for the workload that is saturating its 3g instance (0.94 active), or changing the layout to match the observed demand mix. Changing MIG geometry requires the affected instances to be free: drain the workloads, destroy and create the GPU/compute instances. On Kubernetes, use the GPU Operator's MIG manager with a new `nvidia.com/mig.config` label. Plan it as a maintenance operation.

**Q8.2d** MIG gives each instance dedicated SMs, L2 cache slices, memory controllers and framebuffer, with hardware fault isolation. Per-instance metrics therefore reflect only that tenant, and one tenant cannot starve another's memory bandwidth. With time-slicing, all pods share the whole GPU in turns: no memory isolation, no per-pod hardware metrics (metrics are device-wide), noisy-neighbour effects, and no fault isolation.

### Exercise 9

**Q9.1a** Most likely the **facility or rack**: high inlet air temperature (a hot aisle problem, CRAC/CRAH failure, recirculation, missing blanking panels). It affects several GPUs, which points away from a single bad GPU. To confirm, compare inlet temperatures of neighbouring servers in the same rack and row, check the DC cooling dashboards, and check BMC fan speeds (fans at max confirm the system is fighting heat).

**Q9.1b** The BMC runs independently of the host OS and driver on its own controller and network. Still available: BMC sensor readings (temperatures, power, fans, PSUs), the System Event Log (SEL), serial-over-LAN console, and remote power control (power-cycle the node). This is the standard remediation path for "fallen off the bus" with a hung host.

**Q9.1c** Any two of: fan speeds and fan failures; PSU status, redundancy and input power; chassis inlet/outlet air temperature; System Event Log hardware events (for example, PCIe AER errors logged by firmware); remote power state and control; telemetry while the host OS is down or before it boots.

### Exercise 10

**Q10a**
1. `0x60` = `0x40 + 0x20`: **HW thermal slowdown + SW thermal slowdown**. Node-b GPU 7 is overheating, at 88 °C with its clock reduced to 1410 MHz.
2. Data-parallel training synchronizes every step (all-reduce). Each step lasts as long as the **slowest** rank. GPU 7 computes slower, so it stays busy (0.97 active) while the other 15 finish early and wait in NCCL collectives. That shows up as low `SM_ACTIVE` (~0.55) and lower power. The "under-utilization" is a symptom of waiting, not the cause.
3. Order of actions:
   - (a) Mitigate: cordon node-b and checkpoint the job. Restart on a healthy set of GPUs, or exclude GPU 7 if the job tolerates 15 ranks or a spare is available.
   - (b) Confirm with the BMC: FAN4 is at 0 RPM, Critical. Check the SEL for the fan failure time and correlate it with when the slowdown began.
   - (c) Replace FAN4 through a facilities or vendor ticket.
   - (d) Validate: `dcgmi diag -r 3` on node-b, confirm throttle reasons return to `0x0` and temperature is normal under load.
   - (e) Uncordon and return the node to service.
   - (f) Post-incident: add BMC telemetry (fans) to the alerting pipeline.
4. `GPUHardwareThermalSlowdown` should have fired. Additional alerts: a **fan failure alert from BMC/Redfish telemetry** (for example, a Redfish exporter, alerting on fan `Health != OK` or RPM == 0), which fires before the GPU heats up. Or a **cluster-level straggler alert**: one GPU's `DCGM_FI_DEV_SM_CLOCK` well below the median of its peers in the same job, such as `DCGM_FI_DEV_SM_CLOCK < 0.85 * on() group_left() quantile(0.5, DCGM_FI_DEV_SM_CLOCK)`, scoped per job or namespace.

**Q10b** `GPU_UTIL` would likely read close to 100% on all 16 GPUs: each one runs NCCL kernels while waiting and compute kernels otherwise. The straggler would look identical to the healthy GPUs. The diagnosis depends on **clocks + throttle reasons + temperature** (thermal family) and on **SM_ACTIVE** asymmetry (efficiency family), cross-checked with **BMC** data (platform family). That cross-family correlation is the core skill this topic tests.

</details>