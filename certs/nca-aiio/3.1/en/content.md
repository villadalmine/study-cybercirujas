# 3.1 — AI Data Center Management and Monitoring Essentials

## 1. Motivation: why a GPU data center needs its own operations discipline

A conventional web fleet tolerates failure well. A stateless pod dies, the load balancer routes around it, and nobody notices. An AI training cluster has a different failure model:

- **Synchronous coupling.** A data-parallel or tensor-parallel job on 512 GPUs advances at the speed of its slowest rank. One GPU that throttles thermally, or one NVLink lane retraining, slows the whole job. If a single GPU hits a fatal Xid, every collective (NCCL `all_reduce`) hangs until a watchdog kills the job. The job then restarts from the last checkpoint, which can mean hours of lost compute.
- **Expensive idle capacity.** An 8-GPU HGX node costs hundreds of thousands of dollars. A GPU with 15% utilization is a finance problem as well as a performance problem. Monitoring here is a capacity-planning and chargeback input as much as an alerting input.
- **Failure modes the OS cannot see.** CPU-centric tools such as `top`, `node_exporter` and kubelet resource metrics know nothing about:
  - HBM ECC errors
  - row remapping
  - NVLink CRC errors
  - SM occupancy
  - Tensor Core activity
  - GPU throttle reasons
- **Facility-scale physics.** A DGX H100 draws about 10.2 kW. Rack density of 40–100+ kW makes power capping, inlet temperature and liquid-cooling telemetry first-class operational signals.

The architectural answer is a **layered management and monitoring stack**. Each layer has a distinct scope, transport and failure domain:

| Layer | Scope | Typical NVIDIA / ecosystem tooling | Transport | Works when the OS is down? |
|---|---|---|---|---|
| Out-of-band (OOB) hardware | Chassis, PSUs, fans, inlet temps, power on/off, firmware, remote console | BMC (IPMI, Redfish), NVIDIA BMC on DGX/IGX | Dedicated management NIC / VLAN | **Yes** |
| In-band device | GPU health, ECC, Xid, clocks, power, NVLink, MIG | NVML, `nvidia-smi`, DCGM (`nv-hostengine`, `dcgmi`) | PCIe / driver on the host | No |
| Cluster provisioning and config | OS images, node categories, firmware rollout, health checks | NVIDIA Base Command Manager (BCM), PXE, Ansible | Management network | Partially (PXE/BMC) |
| Orchestration and scheduling | Job placement, quotas, GPU sharing | Slurm, Kubernetes + NVIDIA GPU Operator, NVIDIA Run:ai | Cluster network | No |
| Observability and alerting | Time series, dashboards, SLOs, alerts | dcgm-exporter → Prometheus → Grafana / Alertmanager, BCM monitoring, Base Command Platform | HTTP scrape / push | No |

A frequent exam theme is choosing the right layer for a symptom:

- "Node unreachable, need to power-cycle it" → BMC.
- "Which GPU is throwing double-bit ECC errors?" → DCGM/NVML.
- "Why is the job pending?" → scheduler.
- "Is the cluster under-utilized?" → Prometheus/DCGM profiling metrics aggregated per project.

---

## 2. Out-of-band management: BMC, IPMI and Redfish

### 2.1 Architecture

The **Baseboard Management Controller (BMC)** is an independent SoC on the motherboard. It runs its own firmware, commonly OpenBMC-based on NVIDIA platforms. It is powered from standby power, so it is alive whenever the chassis has AC, even if the host is off, hung or has a corrupted OS.

NVIDIA documents the BMC on platforms such as IGX Orin and DGX as offering:

- remote power control
- sensor monitoring (temperature, voltage, fan, power)
- System Event Log (SEL)
- virtual media
- KVM / Serial-over-LAN
- firmware update
- both **IPMI** and **Redfish** interfaces

```
            ┌───────────────────────────── Server ─────────────────────────────┐
            │  Host CPU ── PCIe ── GPUs (NVML/DCGM in-band)                     │
            │     │                                                             │
            │  Host NIC(s) ───────────── data / storage / compute fabric        │
            │                                                                   │
            │  BMC SoC ── sensors (I2C/SMBus), PSUs, fans, GPU baseboard (HMC)  │
            │     │                                                             │
            │  Dedicated mgmt NIC ───── OOB management VLAN (isolated)          │
            └───────────────────────────────────────────────────────────────────┘
```

On HGX-based systems, a **HGX Management Controller (HMC)** on the GPU baseboard exposes GPU and NVSwitch telemetry to the BMC. That is why Redfish on a DGX can report per-GPU temperatures even with no driver loaded.

### 2.2 IPMI vs Redfish

| Aspect | IPMI 2.0 | Redfish (DMTF) |
|---|---|---|
| Data model | Binary, SDR/SEL records, OEM raw commands | RESTful JSON over HTTPS, schema-defined (OData) |
| Transport | RMCP+ over UDP 623 | HTTPS 443 |
| Security | Weak historically (cipher 0, RAKP hash leakage); must be isolated | TLS, sessions, role-based accounts; still isolate |
| Tooling | `ipmitool`, `freeipmi` | `curl`, Python `redfish` lib, Ansible `community.general.redfish_*` |
| Automation friendliness | Low (parsing text output) | High (JSON, idempotent PATCH/POST) |
| Firmware update | OEM-specific | `UpdateService` standardized |
| Recommendation | Legacy compatibility, quick sensor reads | Default for new automation |

### 2.3 Real commands

Power state and sensor data over IPMI:

```
$ ipmitool -I lanplus -H 10.10.0.21 -U admin -P 'S3cret!' chassis power status
Chassis Power is on

$ ipmitool -I lanplus -H 10.10.0.21 -U admin -P 'S3cret!' sdr type Temperature
Inlet_Temp       | 31h | ok  |  7.1 | 24 degrees C
CPU0_Temp        | 32h | ok  |  3.1 | 52 degrees C
GPU0_Temp        | 40h | ok  | 11.1 | 61 degrees C
GPU1_Temp        | 41h | ok  | 11.2 | 63 degrees C
PSU0_Temp        | 50h | ok  | 10.1 | 38 degrees C

$ ipmitool -I lanplus -H 10.10.0.21 -U admin -P 'S3cret!' sel elist | tail -3
 1a3 | 11/12/2026 | 03:14:07 | Power Supply PSU1_Status | Power Supply AC lost | Asserted
 1a4 | 11/12/2026 | 03:14:09 | Power Supply PSU1_Status | Power Supply AC lost | Deasserted
 1a5 | 11/12/2026 | 08:02:55 | Temperature GPU5_Temp | Upper Critical going high | Asserted

$ ipmitool -I lanplus -H 10.10.0.21 -U admin -P 'S3cret!' chassis power cycle
Chassis Power Control: Cycle
```

Serial-over-LAN, for watching a kernel panic or GRUB:

```
$ ipmitool -I lanplus -H 10.10.0.21 -U admin -P 'S3cret!' sol activate
[SOL Session operational.  Use ~? for help]
```

The same operations over Redfish:

```
$ curl -sk -u admin:'S3cret!' https://10.10.0.21/redfish/v1/Systems | jq '.Members'
[
  {
    "@odata.id": "/redfish/v1/Systems/DGX"
  }
]

$ curl -sk -u admin:'S3cret!' https://10.10.0.21/redfish/v1/Systems/DGX \
    | jq '{PowerState, Status, BiosVersion}'
{
  "PowerState": "On",
  "Status": {
    "Health": "OK",
    "State": "Enabled"
  },
  "BiosVersion": "1.4.2"
}

$ curl -sk -u admin:'S3cret!' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"ResetType": "ForceRestart"}' \
    https://10.10.0.21/redfish/v1/Systems/DGX/Actions/ComputerSystem.Reset
```

The resource path (`/Systems/DGX`, `/Systems/1`, `/Systems/System_0`) varies by vendor. Always discover it from the `Members` collection instead of hard-coding it.

A Redfish request body for a power-cap PATCH on a chassis that supports `PowerControl`:

```json
{
  "PowerControl": [
    {
      "PowerLimit": {
        "LimitInWatts": 9000,
        "LimitException": "LogEventOnly"
      }
    }
  ]
}
```

### 2.4 Production practices

- **Isolate the BMC network.** Put it on a dedicated VLAN/VRF, reachable only from bastions and the provisioning head node. Disable IPMI cipher suite 0. Rotate default credentials at first boot.
- **Forward SEL events.** Use Redfish `EventService` subscriptions or SNMP traps so that PSU loss, fan failure and thermal trips create tickets even when the host OS is dead.
- **Use the BMC for remediation, not continuous high-frequency telemetry.** BMCs are slow, low-power processors. Polling them every second from Prometheus can make them unresponsive. Use about 60 s intervals for BMC sensors and keep high-rate GPU telemetry in-band via DCGM.

---

## 3. In-band GPU telemetry: NVML, nvidia-smi and DCGM

### 3.1 The stack

```
  nvidia-smi ─┐                         ┌─ dcgmi (CLI)
              │                         ├─ dcgm-exporter (Prometheus)
              ▼                         ├─ Python/Go bindings, BCM, Slurm prolog/epilog
            NVML  ◄──────────  nv-hostengine (DCGM daemon)
              │                  - field watching / caching
              │                  - health watches, policies
              │                  - diagnostics (dcgmi diag)
              │                  - profiling metrics (DCP)
              ▼
        NVIDIA kernel driver ──► GPUs, NVSwitch
```

- **NVML** is the low-level C library behind `nvidia-smi`. It is synchronous and per-process, and it has no history.
- **DCGM** (Data Center GPU Manager) runs a daemon (`nv-hostengine`) on top of NVML. It adds:
  - **groups** of GPUs
  - **field watches** with a cache and history
  - **health monitoring** (background watches for PCIe, memory, NVLink, thermal, power, inforom)
  - **policies**, such as actions on DBE or PCIe replays
  - **active diagnostics** (`dcgmi diag`)
  - **job statistics** (`dcgmi stats`)
  - **profiling metrics** (`DCGM_FI_PROF_*`: SM active, tensor pipe active, DRAM active, NVLink/PCIe bytes) gathered through low-overhead hardware counters

| Need | `nvidia-smi` | DCGM |
|---|---|---|
| Ad-hoc check on one node | Ideal | Works |
| Continuous fleet telemetry | Poor (spawning processes, parsing text) | Designed for it |
| Profiling (SM/Tensor activity) | No | Yes (`DCGM_FI_PROF_*`) |
| Active stress/diagnostic tests | No | `dcgmi diag -r 1..4` |
| Health watches and policies | No | Yes |
| Per-job accounting | Limited | `dcgmi stats` with job IDs |
| Kubernetes / Prometheus integration | No | dcgm-exporter |

### 3.2 nvidia-smi essentials

```
$ nvidia-smi --query-gpu=index,name,pci.bus_id,temperature.gpu,power.draw,power.limit,utilization.gpu,memory.used,memory.total,clocks_throttle_reasons.active --format=csv
index, name, pci.bus_id, temperature.gpu, power.draw [W], power.limit [W], utilization.gpu [%], memory.used [MiB], memory.total [MiB], clocks_throttle_reasons.active
0, NVIDIA H100 80GB HBM3, 00000000:18:00.0, 58, 612.33 W, 700.00 W, 98 %, 71230 MiB, 81559 MiB, 0x0000000000000000
1, NVIDIA H100 80GB HBM3, 00000000:2A:00.0, 61, 640.10 W, 700.00 W, 99 %, 71230 MiB, 81559 MiB, 0x0000000000000000
2, NVIDIA H100 80GB HBM3, 00000000:3A:00.0, 84, 455.02 W, 700.00 W, 97 %, 71230 MiB, 81559 MiB, 0x0000000000000020
...
```

GPU 2 runs hotter, draws less power and reports throttle reason `0x20` (SW thermal slowdown). It is the straggler slowing the whole job.

Interconnect topology:

```
$ nvidia-smi topo -m
        GPU0  GPU1  GPU2  GPU3  GPU4  GPU5  GPU6  GPU7  NIC0  CPU Affinity  NUMA Affinity
GPU0     X    NV18  NV18  NV18  NV18  NV18  NV18  NV18  PXB   0-55          0
GPU1    NV18   X    NV18  NV18  NV18  NV18  NV18  NV18  PXB   0-55          0
...
Legend:
  X    = Self
  SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes
  NODE = Connection traversing PCIe as well as the interconnect between PCIe Host Bridges within a NUMA node
  PXB  = Connection traversing multiple PCIe bridges (without traversing the PCIe Host Bridge)
  PIX  = Connection traversing at most a single PCIe bridge
  NV#  = Connection traversing a bonded set of # NVLinks
```

ECC and row remapping:

```
$ nvidia-smi -q -d ECC,ROW_REMAPPER -i 3
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
            DRAM Correctable              : 340
            DRAM Uncorrectable            : 1
    Remapped Rows
        Correctable Error                 : 0
        Uncorrectable Error               : 1
        Pending                           : Yes
        Remapping Failure Occurred        : No
```

`Pending: Yes` means a row remap is queued and takes effect only after a **GPU reset or reboot**. Drain the node, reset it, and return it to service.

A rolling device monitor:

```
$ nvidia-smi dmon -s pucm -d 5
# gpu   pwr gtemp mtemp    sm   mem   enc   dec  mclk  pclk    fb  bar1
# Idx     W     C     C     %     %     %     %   MHz   MHz    MB    MB
    0   615    58    66    98    61     0     0  2619  1980 71230     5
    1   641    61    69    99    63     0     0  2619  1980 71230     5
```

### 3.3 DCGM in practice

Install and start the host engine:

```
$ sudo systemctl enable --now nvidia-dcgm
$ dcgmi discovery -l
8 GPUs found.
+--------+----------------------------------------------------------------------+
| GPU ID | Device Information                                                   |
+--------+----------------------------------------------------------------------+
| 0      | Name: NVIDIA H100 80GB HBM3                                          |
|        | PCI Bus ID: 00000000:18:00.0                                         |
|        | Device UUID: GPU-5f2a9c1e-...                                        |
+--------+----------------------------------------------------------------------+
...
4 NvSwitches found.
```

Groups and health watches:

```
$ dcgmi group -c trainers --default
Successfully created group "trainers" with a group ID of 2
Specified entity ID is valid but unknown: ...   (only if entities missing)

$ dcgmi health -g 2 -s a          # watch all subsystems: PCIe, memory, inforom, thermal, power, NVLink
Health monitor systems set successfully.

$ dcgmi health -g 2 -c
+---------------------------+----------------------------------------------------+
| Health Monitor Report                                                          |
+===========================+====================================================+
| Overall Health            | Warning                                            |
+---------------------------+----------------------------------------------------+
| GPU ID: 3                 | Warning                                            |
|                           | Memory system: Warning                             |
|                           |   A row remap is pending for GPU 3. Reset the GPU. |
+---------------------------+----------------------------------------------------+
```

Live field sampling uses `dmon` with field IDs. The common IDs are:

| ID | Field |
|---|---|
| 150 | GPU temperature |
| 155 | Power usage |
| 203 | GPU utilization |
| 252 | FB used |
| 1002 | SM active |
| 1004 | Tensor pipe active |

```
$ dcgmi dmon -e 150,155,203,252,1002,1004 -d 1000 -c 3
#Entity   TMPTR  POWER   GPUTL  FBUSD   SMACT  TENSO
ID            C      W       %    MiB
GPU 0        58  612.3      98  71230  0.912  0.583
GPU 1        61  640.1      99  71230  0.921  0.590
GPU 2        84  455.0      97  71230  0.701  0.402
```

GPU utilization (`203`) only says that *a kernel was running* during the sample. It reads 98% for a kernel that keeps one SM busy. `SMACT` (1002) and `TENSO` (1004) show real hardware engagement. Utilization and capacity decisions should use the profiling fields.

Active diagnostics come in four levels, with run time growing by level:

| Level | Duration (approx.) | What it does | Typical use |
|---|---|---|---|
| `-r 1` | Seconds | Software/deployment checks: driver, permissions, persistence, environment | Slurm prolog, pod init |
| `-r 2` | ~2 min | Adds PCIe/NVLink bandwidth, short memory test | Post-maintenance smoke test |
| `-r 3` | ~10–30 min | Adds targeted stress, power, memory bandwidth, diagnostic | Burn-in, after RMA, nightly on drained nodes |
| `-r 4` | Up to hours | Extended stress/pulse/memtest | Acceptance testing, intermittent failures |

```
$ dcgmi diag -r 2
Successfully ran diagnostic for group.
+---------------------------+------------------------------------------------+
| Diagnostic                | Result                                         |
+===========================+================================================+
|-----  Metadata  ----------+------------------------------------------------|
| DCGM Version              | 4.x                                            |
| Number of GPUs Detected   | 8                                              |
|-----  Deployment  --------+------------------------------------------------|
| Software                  | Pass                                           |
|-----  Integration  -------+------------------------------------------------|
| PCIe                      | Pass - All                                     |
|-----  Hardware  ----------+------------------------------------------------|
| GPU Memory                | Fail - GPU: 3                                  |
| Warning                   | GPU 3 has uncorrectable memory errors and row  |
|                           | remappings are pending.                        |
+---------------------------+------------------------------------------------+
```

Per-job statistics, as used by Slurm prolog/epilog scripts:

```
$ dcgmi stats -g 2 -e                # enable job stats watching
$ dcgmi stats -g 2 -s job-48211      # start (prolog)
$ dcgmi stats -x job-48211           # stop (epilog)
$ dcgmi stats -j job-48211 -v        # report: energy, avg/max util, ECC, Xid, throttling per GPU
```

### 3.4 The metrics that matter

| Category | DCGM field | Why it matters | Typical alert |
|---|---|---|---|
| Utilization | `DCGM_FI_DEV_GPU_UTIL` | Coarse "busy" indicator | Idle allocated GPUs (<5% for 30 min) |
| Real compute | `DCGM_FI_PROF_SM_ACTIVE`, `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE`, `DCGM_FI_PROF_GR_ENGINE_ACTIVE` | True efficiency, MFU proxy | Low tensor activity on training jobs → inefficient code or input-bound |
| Memory | `DCGM_FI_DEV_FB_USED`, `DCGM_FI_DEV_FB_FREE`, `DCGM_FI_PROF_DRAM_ACTIVE` | OOM risk, right-sizing (MIG candidates) | — |
| Thermal | `DCGM_FI_DEV_GPU_TEMP`, `DCGM_FI_DEV_MEMORY_TEMP` | Throttling, cooling failures | GPU > 85 °C, HBM > 95 °C (check the SKU's limits) |
| Power | `DCGM_FI_DEV_POWER_USAGE`, `DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION` | Rack budget, efficiency, chargeback | Sustained near cap with dropping clocks |
| Clocks / throttle | `DCGM_FI_DEV_SM_CLOCK`, `DCGM_FI_DEV_CLOCK_THROTTLE_REASONS` | Stragglers | Thermal/power slowdown bits set |
| Reliability | `DCGM_FI_DEV_XID_ERRORS` | Driver-reported fault codes | Any non-zero; critical for 48/63/64/74/79/94/95 |
| ECC | `DCGM_FI_DEV_ECC_SBE_VOL_TOTAL`, `DCGM_FI_DEV_ECC_DBE_VOL_TOTAL` | Memory integrity | DBE > 0 → drain |
| Row remap | `DCGM_FI_DEV_ROW_REMAP_PENDING`, `DCGM_FI_DEV_ROW_REMAP_FAILURE` | HBM self-repair state | Pending → reset; failure → RMA |
| Interconnect | `DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL`, `DCGM_FI_PROF_NVLINK_TX_BYTES`, `DCGM_FI_DEV_PCIE_REPLAY_COUNTER` | Collective performance, link health | Rising CRC/replay counters |

### 3.5 Xid errors: an operator's triage table

Xid messages appear in the kernel log (`dmesg`, `journalctl -k`) as `NVRM: Xid (PCI:0000:3a:00): 79, ...`. DCGM also surfaces them as `DCGM_FI_DEV_XID_ERRORS`.

| Xid | Meaning | Likely cause | Action |
|---|---|---|---|
| 13 | Graphics engine exception | Usually application bug (illegal address, out-of-bounds) | Investigate the app; hardware if it recurs across jobs |
| 31 | GPU memory page fault | Application illegal memory access | App/framework debugging |
| 43 | GPU stopped processing | Follows a user-app fault | Usually app; check prior Xids |
| 45 | Preemptive cleanup | Follows other errors / process killed | Context for other Xids |
| 48 | Double-bit ECC error | HBM fault | Drain, reset, check row remap |
| 63 | Row remapping / page retirement event recorded | ECC page retirement or row remap | Schedule reset to apply |
| 64 | Row remapping / page retirement failure | Out of spare rows | **RMA** candidate |
| 74 | NVLink error | Link/cable/NVSwitch | Check NVLink counters, reseat or replace, diag `-r 2+` |
| 79 | GPU has fallen off the bus | PCIe/power/thermal/hardware | Power cycle via BMC; RMA if repeated |
| 94 | Contained ECC error | Uncorrectable error isolated to the affected app | Affected app terminates; GPU continues; reset when convenient |
| 95 | Uncontained ECC error | Uncorrectable error affecting all apps on the GPU | Drain and reset immediately |
| 119 / 120 | GSP RPC timeout / GSP error | GPU System Processor firmware fault | Reset GPU; update driver/firmware |

```
$ sudo journalctl -k --since "1 hour ago" | grep -i xid
Nov 14 07:41:02 dgx-a07 kernel: NVRM: Xid (PCI:0000:3a:00): 79, pid='<unknown>', name=<unknown>, GPU has fallen off the bus.
```

---

## 4. Cluster provisioning and management: NVIDIA Base Command Manager

**NVIDIA Base Command Manager (BCM)**, the former Bright Cluster Manager, is the NVIDIA cluster management software used for DGX SuperPOD/BasePOD and generic GPU clusters. It provides:

- **Bare-metal provisioning.** PXE boot with software images, so a node is reinstalled to a known-good image instead of hand-patched.
- **Node categories.** Configuration (image, kernel parameters, roles, Slurm/Kubernetes membership) is inherited by group of nodes.
- **Workload manager integration.** Deploys and configures Slurm and/or Kubernetes, including GPU Operator setup.
- **Monitoring and health checks.** Metrics collection (including GPU metrics via DCGM), health checks that run before jobs and can set nodes offline, and BMC/IPMI/Redfish integration for power control.
- **Interfaces.** `cmsh` (shell), Base View (web GUI) and APIs.

NVIDIA **Base Command Platform** is the separate SaaS/hosted layer for AI workflow management: jobs, datasets and workspaces on DGX Cloud or SuperPOD. Do not confuse the two. **Manager** handles cluster infrastructure. **Platform** handles user-facing AI job and workflow management.

Representative `cmsh` interactions (BCM shell):

```
$ cmsh
[headnode]% device
[headnode->device]% list
Type             Hostname (key)   MAC                 Category      Ip              Network     Status
---------------- ---------------- ------------------- ------------- --------------- ----------- --------
HeadNode         headnode         FA:16:3E:11:22:33                 10.141.255.254  internalnet [   UP   ]
PhysicalNode     dgx-a01          B8:CE:F6:AA:00:01   dgx-h100      10.141.0.1      internalnet [   UP   ]
PhysicalNode     dgx-a07          B8:CE:F6:AA:00:07   dgx-h100      10.141.0.7      internalnet [  DOWN  ]
[headnode->device]% power status -n dgx-a07
ipmi0 .................... [   OFF  ] dgx-a07
[headnode->device]% power on -n dgx-a07
[headnode->device]% use dgx-a01
[headnode->device[dgx-a01]]% latesthealthdata
Health Check     Severity Value   Age (sec.)  Info
---------------- -------- ------- ----------- ------
gpuhealth        0        PASS    42
ssh2node         0        PASS    42
```

The exact output format varies by BCM version. The concepts that carry over are device modes, categories, power through BMC, and health data that can gate node availability.

---

## 5. Kubernetes: NVIDIA GPU Operator, dcgm-exporter and Prometheus

### 5.1 What the GPU Operator manages

Kubernetes does not know GPUs natively. The **NVIDIA GPU Operator** uses a `ClusterPolicy` to deploy, as DaemonSets on GPU nodes:

| Component | Role |
|---|---|
| NVIDIA driver (containerized) | Kernel modules without baking them into the host image |
| NVIDIA Container Toolkit | Runtime hook so containers see GPUs |
| Device Plugin | Advertises `nvidia.com/gpu` (or MIG resources) to kubelet |
| GPU Feature Discovery (GFD) | Node labels such as `nvidia.com/gpu.product`, `nvidia.com/mig.capable` |
| DCGM / dcgm-exporter | Telemetry on `:9400/metrics` |
| MIG Manager | Applies MIG geometry from the `nvidia.com/mig.config` node label |
| Validator | Verifies the stack per node |
| Node Feature Discovery (NFD) | Labels nodes with PCI vendor `10de` so the operator targets them |

Install with Helm values that enable monitoring and mixed MIG:

```yaml
# values-gpu-operator.yaml
driver:
  enabled: true
toolkit:
  enabled: true
devicePlugin:
  enabled: true
gfd:
  enabled: true
mig:
  strategy: mixed
migManager:
  enabled: true
  config:
    name: default-mig-parted-config
dcgm:
  enabled: true
dcgmExporter:
  enabled: true
  config:
    name: dcgm-custom-metrics
  serviceMonitor:
    enabled: true
    interval: 15s
    honorLabels: false
    additionalLabels:
      release: kube-prometheus-stack
validator:
  plugin:
    env:
      - name: WITH_WORKLOAD
        value: "false"
```

```
$ helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
$ kubectl create namespace gpu-operator
$ kubectl apply -n gpu-operator -f dcgm-custom-metrics.yaml
$ helm install gpu-operator nvidia/gpu-operator -n gpu-operator -f values-gpu-operator.yaml --wait
$ kubectl get pods -n gpu-operator
NAME                                                  READY   STATUS      RESTARTS   AGE
gpu-feature-discovery-7xk2p                           1/1     Running     0          4m
gpu-operator-6d9f8c7b5-q2lm8                          1/1     Running     0          5m
nvidia-container-toolkit-daemonset-f8h4n              1/1     Running     0          4m
nvidia-cuda-validator-z9c2d                           0/1     Completed   0          3m
nvidia-dcgm-exporter-p5w7t                            1/1     Running     0          4m
nvidia-dcgm-l8xqv                                     1/1     Running     0          4m
nvidia-device-plugin-daemonset-b6r4k                  1/1     Running     0          4m
nvidia-driver-daemonset-tkh2s                         1/1     Running     0          5m
nvidia-mig-manager-n3jd9                              1/1     Running     0          4m
nvidia-operator-validator-wq6fz                       1/1     Running     0          4m
```

### 5.2 Custom dcgm-exporter metric set

dcgm-exporter reads a CSV of `field, prometheus type, help`. Add the profiling and reliability fields that operations actually need:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: dcgm-custom-metrics
  namespace: gpu-operator
data:
  dcp-metrics-included.csv: |
    # Format: DCGM field, Prometheus metric type, help message
    DCGM_FI_DEV_SM_CLOCK, gauge, SM clock frequency (in MHz).
    DCGM_FI_DEV_MEM_CLOCK, gauge, Memory clock frequency (in MHz).
    DCGM_FI_DEV_GPU_TEMP, gauge, GPU temperature (in C).
    DCGM_FI_DEV_MEMORY_TEMP, gauge, Memory temperature (in C).
    DCGM_FI_DEV_POWER_USAGE, gauge, Power draw (in W).
    DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION, counter, Total energy consumption since boot (in mJ).
    DCGM_FI_DEV_GPU_UTIL, gauge, GPU utilization (in %).
    DCGM_FI_DEV_FB_FREE, gauge, Framebuffer memory free (in MiB).
    DCGM_FI_DEV_FB_USED, gauge, Framebuffer memory used (in MiB).
    DCGM_FI_DEV_XID_ERRORS, gauge, Value of the last XID error encountered.
    DCGM_FI_DEV_ECC_SBE_VOL_TOTAL, counter, Total number of single-bit volatile ECC errors.
    DCGM_FI_DEV_ECC_DBE_VOL_TOTAL, counter, Total number of double-bit volatile ECC errors.
    DCGM_FI_DEV_ROW_REMAP_PENDING, gauge, Whether a row remap is pending.
    DCGM_FI_DEV_ROW_REMAP_FAILURE, gauge, Whether remapping of rows has failed.
    DCGM_FI_DEV_PCIE_REPLAY_COUNTER, counter, Total number of PCIe retries.
    DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL, counter, Total number of NVLink bandwidth counters for all lanes.
    DCGM_FI_DEV_CLOCK_THROTTLE_REASONS, gauge, Current clock throttle reasons (bitmask).
    DCGM_FI_PROF_GR_ENGINE_ACTIVE, gauge, Ratio of time the graphics engine is active.
    DCGM_FI_PROF_SM_ACTIVE, gauge, Ratio of cycles an SM has at least one warp assigned.
    DCGM_FI_PROF_SM_OCCUPANCY, gauge, Ratio of resident warps to the theoretical maximum.
    DCGM_FI_PROF_PIPE_TENSOR_ACTIVE, gauge, Ratio of cycles the tensor (HMMA) pipe is active.
    DCGM_FI_PROF_DRAM_ACTIVE, gauge, Ratio of cycles the device memory interface is active.
    DCGM_FI_PROF_PCIE_TX_BYTES, counter, Bytes transmitted over PCIe.
    DCGM_FI_PROF_PCIE_RX_BYTES, counter, Bytes received over PCIe.
    DCGM_FI_PROF_NVLINK_TX_BYTES, counter, Bytes transmitted over NVLink.
    DCGM_FI_PROF_NVLINK_RX_BYTES, counter, Bytes received over NVLink.
```

dcgm-exporter attaches Kubernetes `pod`, `namespace` and `container` labels by querying the kubelet pod-resources API. That is what makes per-team chargeback and idle-GPU detection possible:

```
$ kubectl -n gpu-operator port-forward ds/nvidia-dcgm-exporter 9400:9400 &
$ curl -s localhost:9400/metrics | grep -E '^DCGM_FI_PROF_PIPE_TENSOR_ACTIVE' | head -2
DCGM_FI_PROF_PIPE_TENSOR_ACTIVE{gpu="0",UUID="GPU-5f2a9c1e-...",device="nvidia0",modelName="NVIDIA H100 80GB HBM3",Hostname="dgx-a01",container="trainer",namespace="team-nlp",pod="llm-pretrain-0"} 0.583
DCGM_FI_PROF_PIPE_TENSOR_ACTIVE{gpu="1",UUID="GPU-8c1d...",device="nvidia1",modelName="NVIDIA H100 80GB HBM3",Hostname="dgx-a01",container="trainer",namespace="team-nlp",pod="llm-pretrain-0"} 0.590
```

### 5.3 Scraping and alerting

If you are not using the operator's built-in ServiceMonitor, you can declare one explicitly:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: nvidia-dcgm-exporter
  namespace: gpu-operator
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: nvidia-dcgm-exporter
  namespaceSelector:
    matchNames:
      - gpu-operator
  endpoints:
    - port: gpu-metrics
      interval: 15s
      path: /metrics
      relabelings:
        - sourceLabels:
            - __meta_kubernetes_pod_node_name
          targetLabel: node
```

Alerting rules that map directly to the triage tables above:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gpu-fleet-health
  namespace: gpu-operator
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: gpu.reliability
      rules:
        - alert: GPUXidCritical
          expr: |
            DCGM_FI_DEV_XID_ERRORS > 0
            and on (Hostname, gpu)
            (
              DCGM_FI_DEV_XID_ERRORS == 48
              or DCGM_FI_DEV_XID_ERRORS == 64
              or DCGM_FI_DEV_XID_ERRORS == 74
              or DCGM_FI_DEV_XID_ERRORS == 79
              or DCGM_FI_DEV_XID_ERRORS == 95
            )
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "Critical Xid {{ $value }} on {{ $labels.Hostname }} GPU {{ $labels.gpu }}"
            runbook: "Cordon/drain node, check journalctl -k, run dcgmi diag -r 3 after reset."
        - alert: GPUDoubleBitECC
          expr: |
            increase(DCGM_FI_DEV_ECC_DBE_VOL_TOTAL[10m]) > 0
          labels:
            severity: critical
          annotations:
            summary: "Uncorrectable ECC on {{ $labels.Hostname }} GPU {{ $labels.gpu }}"
        - alert: GPURowRemapPending
          expr: |
            DCGM_FI_DEV_ROW_REMAP_PENDING > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Row remap pending on {{ $labels.Hostname }} GPU {{ $labels.gpu }}; schedule GPU reset."
        - alert: GPURowRemapFailure
          expr: |
            DCGM_FI_DEV_ROW_REMAP_FAILURE > 0
          labels:
            severity: critical
          annotations:
            summary: "Row remap failure on {{ $labels.Hostname }} GPU {{ $labels.gpu }}; open RMA."
    - name: gpu.performance
      rules:
        - alert: GPUThermalHot
          expr: |
            DCGM_FI_DEV_GPU_TEMP > 85
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} at {{ $value }}C"
        - alert: GPUStragglerInJob
          expr: |
            (
              avg by (namespace, pod) (DCGM_FI_PROF_SM_ACTIVE)
              -
              min by (namespace, pod) (DCGM_FI_PROF_SM_ACTIVE)
            )
            > 0.15
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} has a GPU lagging peers by >15% SM activity."
    - name: gpu.efficiency
      rules:
        - alert: GPUAllocatedButIdle
          expr: |
            avg_over_time(DCGM_FI_DEV_GPU_UTIL{pod!=""}[30m]) < 5
          for: 30m
          labels:
            severity: info
          annotations:
            summary: "{{ $labels.namespace }}/{{ $labels.pod }} holds GPU {{ $labels.gpu }} but is idle."
        - record: namespace:gpu_tensor_active:avg
          expr: |
            avg by (namespace) (DCGM_FI_PROF_PIPE_TENSOR_ACTIVE{namespace!=""})
        - record: namespace:gpu_energy_joules:rate5m
          expr: |
            sum by (namespace) (rate(DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION{namespace!=""}[5m])) / 1000
```

`DCGM_FI_DEV_XID_ERRORS` is a gauge holding the **last** Xid value, not a counter. Alert on specific values, and also correlate with the kernel log, because a later benign Xid can overwrite an earlier critical one.

### 5.4 Consuming GPUs: full-GPU and MIG workloads

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cuda-smoke-full-gpu
  namespace: team-nlp
spec:
  restartPolicy: Never
  nodeSelector:
    nvidia.com/gpu.product: NVIDIA-H100-80GB-HBM3
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  containers:
    - name: cuda
      image: nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04
      command:
        - nvidia-smi
        - "-L"
      resources:
        limits:
          nvidia.com/gpu: 1
```

---

## 6. GPU partitioning and utilization: MIG, time-slicing and Run:ai

### 6.1 Multi-Instance GPU (MIG)

MIG, available on A100, A30, H100, H200 and Blackwell data-center GPUs, splits one GPU into up to **seven** hardware-isolated instances. Each instance has dedicated:

- SMs
- L2 cache slices
- memory controllers and HBM capacity

The result is deterministic QoS and fault isolation. An Xid in one instance does not crash workloads in another.

| Sharing method | Isolation | Memory protection | QoS | Typical use |
|---|---|---|---|---|
| Full GPU | Complete | Yes | Full | Training, large inference |
| MIG | Hardware (SM, cache, memory bandwidth) | Yes | Guaranteed per slice | Multi-tenant inference, notebooks, CI |
| Time-slicing (device plugin) | None (context switching) | No | Best effort | Dev, bursty light workloads |
| MPS | Partial (shared context, limit SM %) | Limited | Configurable | Many small cooperating processes |
| Run:ai fractional GPU | Software-enforced memory limits + scheduling | Software | Policy-based | Maximizing utilization across teams |

H100 80GB profiles on a node with MIG enabled:

```
$ sudo nvidia-smi -i 0 -mig 1
Enabled MIG Mode for GPU 00000000:18:00.0
All done.

$ nvidia-smi mig -lgip -i 0
+-----------------------------------------------------------------------------+
| GPU instance profiles:                                                      |
| GPU   Name             ID    Instances   Memory     P2P    SM    DEC   ENC  |
|                              Free/Total   GiB              CE    JPEG  OFA  |
|=============================================================================|
|   0  MIG 1g.10gb       19     7/7        9.75       No     16     1     0   |
|   0  MIG 1g.20gb       15     4/4        19.62      No     26     1     0   |
|   0  MIG 2g.20gb       14     3/3        19.62      No     32     2     0   |
|   0  MIG 3g.40gb        9     2/2        39.50      No     60     3     0   |
|   0  MIG 4g.40gb        5     1/1        39.50      No     64     4     0   |
|   0  MIG 7g.80gb        0     1/1        79.25      No     132    7     0   |
+-----------------------------------------------------------------------------+

$ sudo nvidia-smi mig -i 0 -cgi 9,19,19,19 -C
Successfully created GPU instance ID  2 on GPU  0 using profile MIG 3g.40gb (ID  9)
Successfully created compute instance ID  0 on GPU  0 GPU instance ID  2 using profile MIG 3g.40gb (ID  2)
...
$ nvidia-smi -L
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-5f2a9c1e-...)
  MIG 3g.40gb     Device  0: (UUID: MIG-1b2c...)
  MIG 1g.10gb     Device  1: (UUID: MIG-3d4e...)
  MIG 1g.10gb     Device  2: (UUID: MIG-5f6a...)
  MIG 1g.10gb     Device  3: (UUID: MIG-7b8c...)
```

In Kubernetes you do not run those commands by hand. You label the node and the MIG Manager repartitions it, draining GPU pods first:

```
$ kubectl label node dgx-a03 nvidia.com/mig.config=all-1g.10gb --overwrite
$ kubectl get node dgx-a03 -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}'
success
$ kubectl describe node dgx-a03 | grep nvidia.com/mig
  nvidia.com/mig-1g.10gb:  56
```

With `mig.strategy: mixed`, each profile is a distinct extended resource:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: embedding-inference
  namespace: team-search
spec:
  replicas: 7
  selector:
    matchLabels:
      app: embedding-inference
  template:
    metadata:
      labels:
        app: embedding-inference
    spec:
      containers:
        - name: server
          image: nvcr.io/nvidia/tritonserver:24.08-py3
          args:
            - tritonserver
            - "--model-repository=/models"
          ports:
            - containerPort: 8000
              name: http
            - containerPort: 8002
              name: metrics
          resources:
            limits:
              nvidia.com/mig-1g.10gb: 1
              cpu: "4"
              memory: 16Gi
```

With `mig.strategy: single`, every GPU on the node uses the same profile, and pods keep requesting `nvidia.com/gpu: 1`. GFD labels expose the slice size. The trade-off is that `single` is simpler but inflexible, while `mixed` is flexible but needs profile-aware requests.

Monitoring under MIG: dcgm-exporter adds `GPU_I_PROFILE` and `GPU_I_ID` labels. Some device-level fields, such as power and temperature, remain per physical GPU. Profiling fields are reported per instance.

### 6.2 NVIDIA Run:ai: scheduling for utilization

Kubernetes' default scheduler places pods. It does not understand:

- team quotas over time
- gang scheduling of distributed jobs
- preemption of lower-priority work
- fractional GPUs

**NVIDIA Run:ai** adds a GPU-aware scheduler and control plane on Kubernetes:

- **Projects and departments with GPU quotas.** Guaranteed shares, with **over-quota** borrowing of idle GPUs that are reclaimed by preemption when the owner needs them.
- **Fair-share and priority.** Training jobs are preemptible. Inference and interactive workloads can be non-preemptible.
- **Gang scheduling.** All pods of a distributed job start together or none do, which avoids deadlocked partial allocations.
- **GPU fractions and dynamic fractions.** For example, 0.5 GPU or a memory amount per workload, so several small inference or notebook pods share a GPU. This complements MIG when hardware partitions are too rigid.
- **Utilization dashboards.** Per project/node allocation versus actual use, built on the same GPU telemetry.

NVIDIA has described combining Run:ai with **NIM** inference microservices. GPU fractions and dynamic scheduling let multiple NIM models share GPUs, which increases utilization and throughput without dedicating a whole GPU per model.

| Concern | Default kube-scheduler | Slurm | Run:ai on Kubernetes |
|---|---|---|---|
| Quotas over time / fair share | ResourceQuota only (static) | Fairshare, QOS, accounts | Project quotas + over-quota + fair share |
| Gang scheduling | No (needs add-ons) | Native | Native |
| Preemption across teams | PriorityClass, coarse | QOS preemption | Quota-aware reclaim |
| Fractional GPU | No (time-slicing/MIG only) | GRES/MIG/shard | Fractions + MIG |
| Cloud-native services (inference) | Native | Weak | Native |

### 6.3 Slurm: the HPC-style alternative

Many DGX SuperPODs run Slurm, often deployed by BCM. GPUs are **GRES** (generic resources):

```
# /etc/slurm/gres.conf
AutoDetect=nvml
NodeName=dgx-a[01-32] Name=gpu Type=h100 File=/dev/nvidia[0-7]
```

```
$ sinfo -o "%N %G %t"
NODELIST       GRES          STATE
dgx-a[01-06]   gpu:h100:8    alloc
dgx-a07        gpu:h100:8    drain
dgx-a[08-32]   gpu:h100:8    idle

$ scontrol show node dgx-a07 | grep -i reason
   Reason=dcgm diag -r 1 failed GPU3 row-remap pending [root@2026-11-14T07:45:12]

$ sbatch --nodes=4 --gres=gpu:h100:8 --ntasks-per-node=8 train.sbatch
Submitted batch job 48211
```

The standard pattern is to run a **prolog** with `dcgmi diag -r 1` and a health check, start `dcgmi stats`, and have an **epilog** collect stats and drain the node on failure. A bad GPU then never receives the next job.

---

## 7. Verification and failure diagnosis

### 7.1 Diagnostic decision flow

```
Symptom observed
│
├─ Node unreachable (SSH/ping dead)
│    └─ BMC: chassis power status → SEL → SOL console → power cycle
│        └─ After boot: journalctl -k | grep Xid ; dcgmi diag -r 2
│
├─ Job hung / NCCL timeout
│    ├─ journalctl -k | grep -i xid    (79? 74? 95?)
│    ├─ dcgmi health -c                (NVLink / PCIe / memory warnings)
│    ├─ nvidia-smi nvlink -s / -e      (link state, error counters)
│    └─ Drain node, reset GPU, dcgmi diag -r 3 before returning
│
├─ Job slow (no errors)
│    ├─ dcgmi dmon -e 150,155,1002,1004 → find straggler GPU
│    ├─ nvidia-smi -q -d PERFORMANCE   (throttle reasons: thermal/power)
│    ├─ BMC/Redfish inlet temp, fan, PSU → facility issue?
│    └─ nvidia-smi topo -m / NUMA affinity → bad placement?
│
├─ Kubernetes pod Pending with nvidia.com/gpu request
│    ├─ kubectl describe node → Allocatable nvidia.com/gpu = 0?
│    ├─ kubectl get pods -n gpu-operator → driver/device-plugin crashloop?
│    ├─ MIG strategy mismatch (requesting nvidia.com/gpu on a mixed-MIG node)
│    └─ Taints / nodeSelector / Run:ai quota exhausted
│
└─ Metrics missing in Grafana
     ├─ ServiceMonitor labels match Prometheus selector?
     ├─ curl :9400/metrics on the exporter pod
     └─ DCGM_FI_PROF_* absent → profiling unsupported on SKU, or another
        profiler (Nsight) holding the counters
```

### 7.2 Common Kubernetes failures

| Symptom | Diagnosis command | Root cause | Fix |
|---|---|---|---|
| `nvidia-driver-daemonset` CrashLoopBackOff | `kubectl logs -n gpu-operator ds/nvidia-driver-daemonset -c nvidia-driver-ctr` | Kernel headers mismatch, secure boot, preinstalled host driver | Use precompiled driver, or set `driver.enabled=false` if a host driver exists |
| Allocatable `nvidia.com/gpu: 0` | `kubectl describe node <n>` | Device plugin not running, or MIG mixed strategy | Check plugin logs; request MIG resource names |
| `mig.config.state=failed` | `kubectl logs -n gpu-operator ds/nvidia-mig-manager` | GPU processes still running, or invalid profile for the SKU | Drain GPU clients; use a profile from `nvidia-smi mig -lgip` |
| dcgm-exporter has no `pod` labels | Exporter logs | kubelet pod-resources socket not mounted | Default operator install mounts it; check custom deployments |
| Profiling metrics show 0/missing | `dcgmi profile -l` | SKU unsupported, or profiling locked by another tool | Supported SKU; stop competing profilers |

Example: a pod is stuck Pending.

```
$ kubectl describe pod llm-pretrain-0 -n team-nlp | tail -4
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  2m    default-scheduler  0/32 nodes are available: 31 Insufficient nvidia.com/gpu, 1 node(s) had untolerated taint {node.kubernetes.io/unschedulable: }.

$ kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu,MIG:.metadata.labels.nvidia\\.com/mig\\.strategy
NAME      GPU   MIG
dgx-a01   8     single
dgx-a03   0     mixed
...
```

### 7.3 Remediation runbook: a GPU with an uncorrectable ECC error

```
# 1. Stop new work
$ kubectl cordon dgx-a07 && kubectl drain dgx-a07 --ignore-daemonsets --delete-emptydir-data
#    (Slurm: scontrol update nodename=dgx-a07 state=drain reason="Xid 95 GPU3")

# 2. Confirm
$ ssh dgx-a07 'nvidia-smi -q -d ECC,ROW_REMAPPER -i 3 | grep -E "Uncorrectable|Pending|Failure"'

# 3. Reset the GPU (no processes may be using it), or reboot via BMC
$ ssh dgx-a07 'sudo nvidia-smi -r -i 3'
GPU 00000000:3A:00.0 was successfully reset.
#    If reset fails (fabric manager / NVSwitch systems often need a full node reset):
$ ipmitool -I lanplus -H dgx-a07-bmc -U admin -P '***' chassis power cycle

# 4. Validate
$ ssh dgx-a07 'dcgmi diag -r 3'

# 5. Decide
#    Pass and remap applied (Pending: No, Failure: No) → uncordon / resume
#    Remapping Failure Occurred: Yes, or repeated Xid 79 → RMA, keep drained
$ kubectl uncordon dgx-a07
```

---

## 8. Design trade-offs and exam-relevant summary

| Decision | Option A | Option B | Guidance |
|---|---|---|---|
| Hardware control | IPMI | Redfish | Redfish for automation; isolate both on an OOB network |
| GPU telemetry | `nvidia-smi` scripts | DCGM + dcgm-exporter | DCGM for fleets; `nvidia-smi` for ad-hoc checks |
| Utilization metric | `GPU_UTIL` | `PROF_SM_ACTIVE` / `PIPE_TENSOR_ACTIVE` | Profiling metrics for efficiency decisions |
| Health validation | Passive (health watches, Xid alerts) | Active (`dcgmi diag`) | Both: passive always on, `-r 1` per job, `-r 3` after maintenance |
| GPU sharing | MIG | Time-slicing / fractions | MIG for isolation/QoS; fractions for density with trusted tenants |
| Scheduler | Slurm | Kubernetes (+ Run:ai) | Slurm for batch HPC-style training; K8s + Run:ai for mixed training/inference and multi-tenant quota management |
| Cluster lifecycle | Hand-built nodes | BCM image-based provisioning | Image-based: reproducible, fast reprovisioning of failed nodes |

Key facts to remember:

1. **BMC equals out-of-band.** It works with the host OS down. It is reached over IPMI (UDP 623) or Redfish (HTTPS REST/JSON). It provides power control, sensors, SEL and remote console.
2. **DCGM equals in-band fleet GPU management.** It provides health watches, diagnostics levels 1–4, profiling metrics, job stats and policies. **dcgm-exporter** exposes it to Prometheus on port 9400.
3. **The GPU Operator** automates driver, toolkit, device plugin, GFD, DCGM, exporter and MIG Manager on Kubernetes.
4. **MIG** gives up to 7 hardware-isolated instances with dedicated memory and compute. It is configured in Kubernetes via the `nvidia.com/mig.config` label.
5. **Run:ai** adds quota, fair-share, preemption, gang scheduling and GPU fractions on Kubernetes to raise utilization.
6. **BCM** provisions and monitors clusters (Slurm/K8s). **Base Command Platform** is the hosted AI workflow layer.
7. **Critical signals** are Xid 48/63/64/74/79/94/95, DBE ECC, row remap pending/failure, thermal throttling, NVLink errors and idle-but-allocated GPUs.

---

## Referencias

- NVIDIA NCA-AIIO exam study guide (PDF): https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy — AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA IGX Orin BMC documentation: https://docs.nvidia.com/igx-orin/bmc/latest/introduction.html
- NVIDIA Base Command: https://www.nvidia.com/en-us/data-center/base-command/
- NVIDIA Base Command Manager documentation: https://docs.nvidia.com/base-command-manager/
- NVIDIA DCGM: https://developer.nvidia.com/dcgm
- DCGM User Guide (diagnostics, health, field IDs): https://docs.nvidia.com/datacenter/dcgm/latest/user-guide/index.html
- dcgm-exporter: https://github.com/NVIDIA/dcgm-exporter
- NVIDIA GPU Operator documentation: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html
- NVIDIA Xid errors reference: https://docs.nvidia.com/deploy/xid-errors/index.html
- NVIDIA GPU memory error management (ECC, row remapping): https://docs.nvidia.com/deploy/a100-gpu-mem-error-mgmt/index.html
- NVIDIA Multi-Instance GPU: https://www.nvidia.com/en-us/technologies/multi-instance-gpu/
- MIG User Guide: https://docs.nvidia.com/datacenter/tesla/mig-user-guide/index.html
- Maximizing GPU Utilization with NVIDIA Run:ai and NVIDIA NIM: https://developer.nvidia.com/blog/maximizing-gpu-utilization-with-nvidia-runai-and-nvidia-nim/
- Kubernetes documentation: https://kubernetes.io/docs/home/
- Kubernetes — Schedule GPUs: https://kubernetes.io/docs/tasks/manage-gpus/scheduling-gpus/
- DMTF Redfish specification: https://www.dmtf.org/standards/redfish
- Slurm GRES scheduling: https://slurm.schedmd.com/gres.html
- Prometheus Operator API (ServiceMonitor, PrometheusRule): https://prometheus-operator.dev/docs/api-reference/api/