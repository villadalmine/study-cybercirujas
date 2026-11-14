# Guided Exercises — Topic 3.1: AI Data Center Management and Monitoring Essentials

**Exam:** NCA-AIIO · **Domain weight:** 5.5%

These exercises follow how an AI data center is actually operated. You start at the hardware layer, with out-of-band management through the BMC (IPMI and Redfish). You then move up through in-band GPU telemetry (`nvidia-smi`, DCGM), failure triage (XID errors), resource partitioning (MIG), and Kubernetes-native monitoring (GPU Operator, `dcgm-exporter`, Prometheus). You finish with cluster-level management (Base Command Manager, Slurm, Run:ai).

> **Two tracks**
> - **Track A (GPU hardware available):** run every command against a real NVIDIA data center GPU node (A100/H100/L40S or similar) with a recent R535+ driver.
> - **Track B (no GPU):** Exercises 1 (with the Redfish mockup) and 7 run fully on a laptop with Docker. Exercises 4 and 8 need a GPU node or a BCM/Slurm head node for their first step. For Exercises 2, 3, 5 and 6, work from the provided expected outputs and answer the questions. That is exactly the skill the exam tests: **reading** telemetry and **choosing** the right tool.

**Official references used throughout**
- NVIDIA DCGM: https://developer.nvidia.com/dcgm
- NVIDIA MIG: https://www.nvidia.com/en-us/technologies/multi-instance-gpu/
- NVIDIA BMC (IGX Orin) introduction: https://docs.nvidia.com/igx-orin/bmc/latest/introduction.html
- NVIDIA Base Command: https://www.nvidia.com/en-us/data-center/base-command/
- Run:ai + NIM GPU utilization: https://developer.nvidia.com/blog/maximizing-gpu-utilization-with-nvidia-runai-and-nvidia-nim/
- Kubernetes documentation: https://kubernetes.io/docs/home/
- NVIDIA AI Infrastructure and Operations Fundamentals course: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NCA-AIIO exam study guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf

---

## Exercise 1 — Out-of-Band Management: the BMC, IPMI and Redfish

**Context.** Every server in an AI data center (a DGX, an HGX-based OEM node, an IGX system) has a **Baseboard Management Controller (BMC)**. The BMC is an independent microcontroller with its own network port, its own power domain and its own firmware. It keeps working when the host OS is hung, powered off or not installed yet. It exposes two protocol families:

- **IPMI**: the legacy binary protocol, accessed with `ipmitool` over RMCP+ (`lanplus`). It is simple, widely supported, and weak on security and data modeling.
- **Redfish**: the DMTF standard. It is a RESTful HTTPS API with JSON payloads and a navigable resource tree (`/redfish/v1/...`), and it is the modern replacement. NVIDIA's BMC documentation describes Redfish and IPMI as the BMC's management interfaces, alongside a web UI and serial-over-LAN.

### Steps

1. Start a Redfish mockup locally. This is the DMTF reference mockup server, and it emulates a rackmount server:

   ```bash
   docker run --rm -d --name redfish -p 8000:8000 dmtf/redfish-mockup-server:latest
   curl -s http://localhost:8000/redfish/v1/ | jq '{RedfishVersion, Systems, Chassis, Managers}'
   ```

   Expected output (shape):

   ```
   {
     "RedfishVersion": "1.x.x",
     "Systems":  { "@odata.id": "/redfish/v1/Systems" },
     "Chassis":  { "@odata.id": "/redfish/v1/Chassis" },
     "Managers": { "@odata.id": "/redfish/v1/Managers" }
   }
   ```

2. Navigate the tree **by following links**. Never hard-code resource IDs, because they differ between vendors:

   ```bash
   SYS=$(curl -s http://localhost:8000/redfish/v1/Systems | jq -r '.Members[0]."@odata.id"')
   curl -s "http://localhost:8000${SYS}" | jq '{Id, Model, PowerState, Status, ProcessorSummary, MemorySummary}'
   ```

   Expected output (abridged):

   ```
   {
     "Id": "437XR1138R2",
     "PowerState": "On",
     "Status": { "State": "Enabled", "Health": "OK", "HealthRollup": "OK" },
     ...
   }
   ```

3. Read thermal and power data from the chassis:

   ```bash
   CH=$(curl -s http://localhost:8000/redfish/v1/Chassis | jq -r '.Members[0]."@odata.id"')
   curl -s "http://localhost:8000${CH}" | jq '{Thermal, Power, ThermalSubsystem, PowerSubsystem}'
   curl -s "http://localhost:8000${CH}/Thermal" | jq '.Temperatures[] | {Name, ReadingCelsius, UpperThresholdCritical}'
   ```

4. Study, **but do not run against production**, the Redfish request that power-cycles a node gracefully. The body is a single JSON document:

   ```json
   {
     "ResetType": "GracefulRestart"
   }
   ```

   ```bash
   curl -k -u admin:'<password>' -X POST \
     -H 'Content-Type: application/json' \
     -d '{"ResetType":"GracefulRestart"}' \
     https://<bmc-ip>/redfish/v1/Systems/<id>/Actions/ComputerSystem.Reset
   ```

5. Compare with the IPMI equivalents (Track A only, against a real BMC):

   ```bash
   ipmitool -I lanplus -H <bmc-ip> -U admin -P '<password>' chassis power status
   ipmitool -I lanplus -H <bmc-ip> -U admin -P '<password>' sdr type temperature
   ipmitool -I lanplus -H <bmc-ip> -U admin -P '<password>' sel elist | tail -5
   ```

   Expected output (abridged):

   ```
   Chassis Power is on
   Inlet Temp       | 30h | ok  |  7.1 | 24 degrees C
   GPU0 Temp        | 41h | ok  | 41.1 | 52 degrees C
      1 | 11/02/2026 | 03:14:07 | Power Supply PSU1 | Power Supply AC lost | Asserted
   ```

6. Clean up: `docker stop redfish`.

### Questions

- **1.1** The OS on `dgx-07` is kernel-panicked and SSH is dead. Which interface do you use to see what happened and to recover the node, and why does it still work?
- **1.2** Why does step 2 discover the System ID through `.Members[0]` instead of using `/redfish/v1/Systems/1`?
- **1.3** Name two concrete reasons a platform team standardizes on Redfish rather than IPMI for fleet automation.
- **1.4** The `sel elist` output shows `Power Supply AC lost | Asserted`. Is this a GPU problem? Which team or system should own the follow-up?
- **1.5** Newer Redfish schemas introduce `ThermalSubsystem` and `PowerSubsystem`. Why should your tooling check for both the old (`Thermal`/`Power`) and the new properties?

---

## Exercise 2 — In-Band GPU Telemetry with `nvidia-smi`

**Context.** `nvidia-smi` ships with the driver and talks to the GPU through **NVML**. It is the first tool you reach for on a single node. It is **not** a fleet monitoring system: it has no history, no aggregation and no alerting.

### Steps

1. Get the inventory and confirm the node sees every GPU:

   ```bash
   nvidia-smi -L
   ```

   ```
   GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-5f1c0e2a-...)
   GPU 1: NVIDIA H100 80GB HBM3 (UUID: GPU-a83d9b71-...)
   ...
   GPU 7: NVIDIA H100 80GB HBM3 (UUID: GPU-0c4e66d2-...)
   ```

2. Run a machine-readable query. This is the format scripts and node-exporter textfile collectors use:

   ```bash
   nvidia-smi --query-gpu=index,name,persistence_mode,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit,ecc.errors.uncorrected.volatile.total \
     --format=csv,noheader
   ```

   ```
   0, NVIDIA H100 80GB HBM3, Enabled, 98 %, 71234 MiB, 81559 MiB, 67, 642.18 W, 700.00 W, 0
   1, NVIDIA H100 80GB HBM3, Enabled, 97 %, 71230 MiB, 81559 MiB, 69, 655.40 W, 700.00 W, 0
   2, NVIDIA H100 80GB HBM3, Enabled, 0 %, 0 MiB, 81559 MiB, 33, 71.02 W, 700.00 W, 0
   3, NVIDIA H100 80GB HBM3, Enabled, 99 %, 71240 MiB, 81559 MiB, 88, 699.87 W, 700.00 W, 2
   ```

3. Check why clocks are being reduced. Drivers before R535 call these "Clocks Throttle Reasons"; newer drivers call them "Clocks Event Reasons":

   ```bash
   nvidia-smi -i 3 -q -d PERFORMANCE
   ```

   ```
   Performance State                     : P0
   Clocks Event Reasons
       Idle                              : Not Active
       Applications Clocks Setting       : Not Active
       SW Power Cap                      : Active
       HW Slowdown                       : Not Active
       HW Thermal Slowdown               : Not Active
       SW Thermal Slowdown               : Active
   ```

4. Stream live metrics for 10 samples:

   ```bash
   nvidia-smi dmon -i 3 -s pucm -c 10
   ```

   ```
   # gpu    pwr  gtemp  mtemp     sm    mem    enc    dec  mclk  pclk    fb  bar1
   # Idx      W      C      C      %      %      %      %   MHz   MHz    MB    MB
       3    699     88     79     99     61      0      0  2619  1590 71240     5
   ```

5. Check row remapping, the HBM memory repair mechanism on A100 and newer:

   ```bash
   nvidia-smi -i 3 -q -d ROW_REMAPPER
   ```

   ```
   Remapped Rows
       Correctable Error                 : 0
       Uncorrectable Error               : 2
       Pending                           : Yes
       Remapping Failure Occurred        : No
   ```

### Questions

- **2.1** In the step 2 output, list each GPU that needs attention and say why.
- **2.2** GPU 3 reports `SW Power Cap: Active` and `SW Thermal Slowdown: Active` while drawing 699.87 W of a 700 W limit at 88 °C. What is happening to its performance, and what are the likely root causes at the facility level?
- **2.3** Row remapping shows `Pending: Yes`. What does this mean, and what action is required before the repair takes effect?
- **2.4** Why is persistence mode (`Enabled`) the standard on Linux compute nodes?
- **2.5** `utilization.gpu` reads 98% on GPU 0. Does that prove the GPU's compute capacity is being used efficiently? (You will verify your answer in Exercise 3.)

---

## Exercise 3 — NVIDIA DCGM: Health, Diagnostics and Profiling Metrics

**Context.** **DCGM (Data Center GPU Manager)** is NVIDIA's fleet-grade toolkit. A host engine (`nv-hostengine`) keeps watches running continuously. DCGM adds **groups**, **health monitoring**, **active diagnostics** (`dcgmi diag`), **policies**, and **profiling metrics** (SM activity, tensor core activity, DRAM bandwidth) that `nvidia-smi` does not expose. `dcgm-exporter`, used in Exercise 6, is built on DCGM.

### Steps

1. Confirm the host engine is running and discover entities:

   ```bash
   sudo systemctl status nvidia-dcgm --no-pager | head -3
   dcgmi discovery -l
   ```

   ```
   8 GPUs found.
   +--------+----------------------------------------------------------------------+
   | GPU ID | Device Information                                                   |
   +--------+----------------------------------------------------------------------+
   | 0      | Name: NVIDIA H100 80GB HBM3                                          |
   |        | PCI Bus ID: 00000000:1B:00.0                                         |
   ...
   ```

2. Create a group, enable all health watches, and check health:

   ```bash
   dcgmi group -c training-gpus -a 0,1,2,3
   dcgmi health -g 2 -s a
   dcgmi health -g 2 -c
   ```

   ```
   Successfully created group "training-gpus" with a group ID of 2
   Health monitor systems set successfully.
   +---------------------------+----------------------------------------------------+
   | Health Monitor Report                                                          |
   +===========================+====================================================+
   | Overall Health            | Warning                                            |
   | GPU 3                     | Warning                                            |
   |   Memory                  | Warning: Pending page retirements/row remaps ...   |
   +---------------------------+----------------------------------------------------+
   ```

3. Run diagnostics at increasing levels. Level 1 runs in seconds. Level 3 takes tens of minutes and stresses the GPUs, so **drain the node first**:

   ```bash
   dcgmi diag -r 1
   dcgmi diag -r 3 -i 3
   ```

   ```
   +---------------------------+------------------------------------------------+
   | Diagnostic                | Result                                         |
   +===========================+================================================+
   |-----  Deployment  --------+------------------------------------------------|
   | Denylist                  | Pass                                           |
   | NVML Library              | Pass                                           |
   | CUDA Main Library         | Pass                                           |
   | Persistence Mode          | Pass                                           |
   | Environment Variables     | Pass                                           |
   | Page Retirement/Row Remap | Fail - GPU 3                                   |
   ...
   ```

4. Stream specific **field IDs**. 150 = GPU temperature, 155 = power usage, 203 = GPU utilization, 1002 = SM active, 1004 = tensor pipe active, 1005 = DRAM active:

   ```bash
   dcgmi dmon -i 0 -e 150,155,203,1002,1004,1005 -c 5
   ```

   ```
   #Entity   TMPTR   POWER   GPUTL   SMACT   TENSO   DRAMA
   ID            C       W       %
   GPU 0        67  642.18      98   0.312   0.048   0.871
   GPU 0        67  640.02      98   0.309   0.051   0.874
   ```

   Column labels vary slightly between DCGM versions. `dcgmi dmon -l` lists all available field IDs.

### Questions

- **3.1** Return to Question 2.5. With `GPUTL = 98` but `SMACT ≈ 0.31`, `TENSO ≈ 0.05` and `DRAMA ≈ 0.87`, what is the GPU actually doing? What category of bottleneck is this, and what kind of optimization would you suggest to the ML team?
- **3.2** Why must the node be drained before `dcgmi diag -r 3`, while `dcgmi health -c` is safe on a busy node?
- **3.3** What is the difference between `dcgmi health` (passive) and `dcgmi diag` (active)? When in a node's life cycle would you run each?
- **3.4** Give two capabilities DCGM provides that `nvidia-smi` does not.

---

## Exercise 4 — XID Error Triage

**Context.** When the NVIDIA kernel driver detects a GPU fault, it logs an **XID** event to the kernel ring buffer. XIDs are the single most important GPU failure signal. DCGM exposes the last one seen as the `DCGM_FI_DEV_XID_ERRORS` field, and `dcgm-exporter` publishes it as a metric.

### Steps

1. On a GPU node (Track A), search the kernel log:

   ```bash
   sudo dmesg -T | grep -i 'NVRM: Xid'
   sudo journalctl -k --since "24 hours ago" | grep -i xid
   ```

2. Triage the following log excerpt, collected from four different nodes (all tracks):

   ```
   [Tue Nov 11 02:13:44 2026] NVRM: Xid (PCI:0000:1b:00): 13, pid=48812, name=python3, Graphics Exception: ESR 0x404600=0x80000002
   [Tue Nov 11 03:40:02 2026] NVRM: Xid (PCI:0000:3b:00): 79, pid='<unknown>', name=<unknown>, GPU has fallen off the bus.
   [Tue Nov 11 05:01:17 2026] NVRM: Xid (PCI:0000:9a:00): 63, pid='<unknown>', name=<unknown>, Row Remapper: New row (0x0000000000a1b2c3) marked for remapping, reset gpu to activate.
   [Tue Nov 11 06:22:51 2026] NVRM: Xid (PCI:0000:c3:00): 74, pid='<unknown>', name=<unknown>, NVLink: fatal error detected on link 5
   ```

3. Map each PCI bus ID to a GPU index on the affected node:

   ```bash
   nvidia-smi --query-gpu=index,pci.bus_id,serial --format=csv
   ```

4. Fill in this triage table for each line: *XID · component · probable cause · user code or hardware? · action*.

### Questions

- **4.1** Classify each of the four XIDs: is it most likely an application issue, a recoverable hardware event, or a hardware/platform failure that needs a node drain and an RMA or field-service ticket?
- **4.2** For XID 79, why should you correlate with the BMC SEL and Redfish logs (Exercise 1) before replacing the GPU?
- **4.3** For XID 63, what is the minimum disruptive action that activates the remap, and which XID would indicate the repair itself failed?
- **4.4** Why does step 3 also query `serial`?

---

## Exercise 5 — Partitioning with Multi-Instance GPU (MIG)

**Context.** **MIG** (A100, H100, H200, B200 and other supported GPUs) splits one physical GPU into up to **seven** hardware-isolated instances. Each instance gets its own SMs, L2 cache slice, memory controllers and HBM capacity. Isolation covers faults and QoS, not just scheduling. This differs from time-slicing, which shares the whole GPU with no memory or fault isolation, and from MPS, which runs concurrent kernels in a shared context.

### Steps (Track A: H100 80GB; Track B: read the outputs)

1. Enable MIG mode on GPU 0. This requires that no processes are using the GPU, and on some platforms a GPU reset:

   ```bash
   sudo nvidia-smi -i 0 -mig 1
   ```

   ```
   Enabled MIG Mode for GPU 00000000:1B:00.0
   All done.
   ```

2. List the GPU instance profiles:

   ```bash
   nvidia-smi mig -i 0 -lgip
   ```

   ```
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
   ```

3. Create a mixed layout: one instance for fine-tuning, one for an inference service, and two small instances for notebooks. `-C` also creates the default compute instance inside each GPU instance:

   ```bash
   sudo nvidia-smi mig -i 0 -cgi 3g.40gb,2g.20gb,1g.10gb,1g.10gb -C
   nvidia-smi -L
   ```

   ```
   GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-5f1c0e2a-...)
     MIG 3g.40gb     Device  0: (UUID: MIG-1a2b...)
     MIG 2g.20gb     Device  1: (UUID: MIG-3c4d...)
     MIG 1g.10gb     Device  2: (UUID: MIG-5e6f...)
     MIG 1g.10gb     Device  3: (UUID: MIG-7a8b...)
   ```

4. Inspect and then tear down. Compute instances must be destroyed before GPU instances:

   ```bash
   nvidia-smi mig -i 0 -lgi
   sudo nvidia-smi mig -i 0 -dci
   sudo nvidia-smi mig -i 0 -dgi
   sudo nvidia-smi -i 0 -mig 0
   ```

### Questions

- **5.1** Why does the profile name `3g.40gb` encode two numbers? What do `3g` and `40gb` each represent?
- **5.2** After step 3, could you create one more `1g.10gb` instance? Explain using compute slices and memory slices.
- **5.3** A team runs a latency-sensitive inference service next to a noisy batch job on the same GPU. Compare MIG and time-slicing for this case.
- **5.4** In the step 2 table, which profile has `Instances 1/1` that consumes the entire GPU? Why would anyone enable MIG only to use that profile?
- **5.5** Which DCGM/`dcgm-exporter` dimension must a monitoring dashboard add once MIG is enabled, so that per-tenant metrics stay meaningful?

---

## Exercise 6 — Kubernetes: GPU Operator, `dcgm-exporter` and PromQL

**Context.** In Kubernetes, the **NVIDIA GPU Operator** automates the GPU software stack as DaemonSets: the driver, the container toolkit, the device plugin, GPU Feature Discovery (GFD), the MIG manager, the DCGM exporter and validators. The device plugin advertises the extended resource `nvidia.com/gpu` to the kubelet ([Kubernetes device plugins](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/)). `dcgm-exporter` serves Prometheus metrics on port **9400** and labels them with the pod and namespace that own each GPU.

### Steps (Track A: a cluster with GPU nodes)

1. Install the operator with the ServiceMonitor enabled for the exporter. This assumes the Prometheus Operator CRDs, from kube-prometheus-stack, are already present:

   ```bash
   helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
   helm install --wait gpu-operator nvidia/gpu-operator \
     -n gpu-operator --create-namespace \
     --set dcgmExporter.serviceMonitor.enabled=true \
     --set mig.strategy=mixed
   kubectl get pods -n gpu-operator
   ```

   ```
   NAME                                           READY   STATUS      RESTARTS   AGE
   gpu-feature-discovery-x7k2p                    1/1     Running     0          4m
   gpu-operator-6d8f9c7b8-q2lwz                   1/1     Running     0          5m
   nvidia-container-toolkit-daemonset-9z8kd       1/1     Running     0          4m
   nvidia-cuda-validator-hp4m2                    0/1     Completed   0          2m
   nvidia-dcgm-exporter-ldm5v                     1/1     Running     0          4m
   nvidia-device-plugin-daemonset-tw7s4           1/1     Running     0          4m
   nvidia-driver-daemonset-5vkqj                  1/1     Running     0          5m
   nvidia-mig-manager-2rjfn                       1/1     Running     0          3m
   nvidia-operator-validator-8hqxc                1/1     Running     0          4m
   ```

2. Confirm the node advertises GPUs and GFD labels:

   ```bash
   kubectl get node dgx-01 -o json | jq '.status.allocatable | with_entries(select(.key | startswith("nvidia.com")))'
   kubectl get node dgx-01 --show-labels | tr ',' '\n' | grep -E 'nvidia.com/(gpu.product|gpu.count|mig)'
   ```

   ```
   {
     "nvidia.com/gpu": "8"
   }
   nvidia.com/gpu.count=8
   nvidia.com/gpu.product=NVIDIA-H100-80GB-HBM3
   nvidia.com/mig.capable=true
   ```

3. Run a GPU workload. Save the manifest as `cuda-vectoradd.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: cuda-vectoradd
     namespace: default
   spec:
     restartPolicy: OnFailure
     containers:
       - name: vectoradd
         image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0
         resources:
           limits:
             nvidia.com/gpu: 1
   ```

   ```bash
   kubectl apply -f cuda-vectoradd.yaml
   kubectl logs cuda-vectoradd
   ```

   ```
   [Vector addition of 50000 elements]
   Copy input data from the host memory to the CUDA device
   CUDA kernel launch with 196 blocks of 256 threads
   Copy output data from the CUDA device to the host memory
   Test PASSED
   Done
   ```

4. Scrape the exporter directly:

   ```bash
   kubectl -n gpu-operator port-forward ds/nvidia-dcgm-exporter 9400:9400 &
   curl -s localhost:9400/metrics | grep -E '^DCGM_FI_DEV_(GPU_UTIL|GPU_TEMP|XID_ERRORS)' | head -4
   ```

   ```
   DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-5f1c0e2a-...",pci_bus_id="00000000:1B:00.0",device="nvidia0",modelName="NVIDIA H100 80GB HBM3",Hostname="dgx-01",container="trainer",namespace="research",pod="llm-ft-0"} 98
   DCGM_FI_DEV_GPU_TEMP{gpu="0",UUID="GPU-5f1c0e2a-...",...} 67
   DCGM_FI_DEV_XID_ERRORS{gpu="3",UUID="GPU-...",...} 0
   ```

5. Run these PromQL queries in Prometheus or Grafana:

   ```
   # Cluster-wide average GPU utilization
   avg(DCGM_FI_DEV_GPU_UTIL)

   # Hottest GPU per node
   max by (Hostname) (DCGM_FI_DEV_GPU_TEMP)

   # GPU power per namespace (chargeback / showback)
   sum by (namespace) (DCGM_FI_DEV_POWER_USAGE{namespace!=""})

   # Allocated GPUs whose SMs are mostly idle over 1h
   avg_over_time(DCGM_FI_PROF_SM_ACTIVE{pod!=""}[1h]) < 0.1
   ```

### Questions

- **6.1** Which operator component makes `nvidia.com/gpu: 8` appear in `allocatable`, and which one creates the `nvidia.com/gpu.product` label?
- **6.2** Why does a pod specify `nvidia.com/gpu` under `limits`, and can it request `0.5` of a GPU this way?
- **6.3** With `mig.strategy=mixed` and the layout from Exercise 5, what resource name would a pod request to get one `1g.10gb` slice?
- **6.4** How does `dcgm-exporter` know which pod owns a GPU, and why does that matter for FinOps?
- **6.5** Depending on your Prometheus scrape config (`honorLabels`), the `pod` label may appear as `exported_pod`. Why does this happen?

---

## Exercise 7 — GPU Alerting as Code, Unit-Tested with `promtool` (runs anywhere)

**Context.** Dashboards don't wake anyone up; alerts do. Alert rules are code, so they get unit tests. This exercise runs without a GPU, because `promtool` replays synthetic time series.

### Steps

1. Create a working directory and save the following as `gpu-alerts.yaml`:

   ```yaml
   groups:
     - name: gpu-health
       rules:
         - alert: GPUXidErrorDetected
           expr: DCGM_FI_DEV_XID_ERRORS > 0
           labels:
             severity: critical
           annotations:
             summary: "XID {{ $value }} on GPU {{ $labels.gpu }} ({{ $labels.Hostname }})"
         - alert: GPUHighTemperature
           expr: DCGM_FI_DEV_GPU_TEMP > 85
           for: 5m
           labels:
             severity: warning
           annotations:
             summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} at {{ $value }}C"
         - alert: GPUAllocatedButIdle
           expr: |
             avg_over_time(DCGM_FI_DEV_GPU_UTIL{pod!=""}[30m]) < 5
           for: 30m
           labels:
             severity: info
           annotations:
             summary: "GPU {{ $labels.gpu }} held by {{ $labels.namespace }}/{{ $labels.pod }} is idle"
   ```

2. Save the unit test as `gpu-alerts-test.yaml`:

   ```yaml
   rule_files:
     - gpu-alerts.yaml
   evaluation_interval: 1m
   tests:
     - interval: 1m
       input_series:
         - series: 'DCGM_FI_DEV_GPU_TEMP{gpu="0",Hostname="dgx-01"}'
           values: '80 82 86 87 88 89 90 91 92 93'
         - series: 'DCGM_FI_DEV_XID_ERRORS{gpu="3",Hostname="dgx-01"}'
           values: '0 0 79 79 79'
         - series: 'DCGM_FI_DEV_GPU_UTIL{gpu="1",Hostname="dgx-02",namespace="research",pod="train-7f9"}'
           values: '2+0x60'
       alert_rule_test:
         - eval_time: 5m
           alertname: GPUHighTemperature
           exp_alerts: []
         - eval_time: 9m
           alertname: GPUHighTemperature
           exp_alerts:
             - exp_labels:
                 severity: warning
                 gpu: "0"
                 Hostname: dgx-01
               exp_annotations:
                 summary: "GPU 0 on dgx-01 at 93C"
         - eval_time: 3m
           alertname: GPUXidErrorDetected
           exp_alerts:
             - exp_labels:
                 severity: critical
                 gpu: "3"
                 Hostname: dgx-01
               exp_annotations:
                 summary: "XID 79 on GPU 3 (dgx-01)"
         - eval_time: 45m
           alertname: GPUAllocatedButIdle
           exp_alerts:
             - exp_labels:
                 severity: info
                 gpu: "1"
                 Hostname: dgx-02
                 namespace: research
                 pod: train-7f9
               exp_annotations:
                 summary: "GPU 1 held by research/train-7f9 is idle"
   ```

3. Lint and test using the official Prometheus image:

   ```bash
   docker run --rm -v "$PWD":/w -w /w --entrypoint promtool prom/prometheus:v3.5.0 check rules gpu-alerts.yaml
   docker run --rm -v "$PWD":/w -w /w --entrypoint promtool prom/prometheus:v3.5.0 test rules gpu-alerts-test.yaml
   ```

   ```
   Checking gpu-alerts.yaml
     SUCCESS: 3 rules found

   Unit Testing: gpu-alerts-test.yaml
     SUCCESS
   ```

4. Break it on purpose. Change `for: 5m` to `for: 10m` in `GPUHighTemperature`, rerun the test, and read the failure diff. Then revert the change.

### Questions

- **7.1** The temperature crosses 85 °C at minute 2. Why is the expected alert list empty at minute 5 but populated at minute 9? At what exact minute does it start firing?
- **7.2** Why does `GPUXidErrorDetected` have no `for:` clause, while temperature does?
- **7.3** `DCGM_FI_DEV_XID_ERRORS` holds the *value of the last XID*, not a count. What does the summary annotation therefore display, and why is that useful for routing the alert?
- **7.4** Why does `GPUAllocatedButIdle` filter on `pod!=""`, and which DCGM field would make it a more accurate idleness signal (see Exercise 3)?
- **7.5** In step 4, which assertion fails, and why?

---

## Exercise 8 — Cluster-Level Management: Base Command Manager, Slurm and Run:ai

**Context.** Per-node tools don't scale to a thousand GPUs. **NVIDIA Base Command Manager (BCM)** provisions and manages the cluster: it handles node images, the software stack, health checks, monitoring and workload manager integration. On top of BCM you run a scheduler. **Slurm** is the classic choice for HPC-style training. **Kubernetes with Run:ai** adds GPU-aware quotas, fair share, over-quota borrowing and **fractional GPUs**, which raise utilization for mixed inference and NIM workloads.

### Steps (scenario-based; commands shown for BCM- and Slurm-managed clusters)

1. From the BCM head node, list nodes and their state:

   ```bash
   cmsh -c "device; list"
   cmsh -c "device; status"
   ```

   ```
   dgx-01 ................ [   UP   ]
   dgx-02 ................ [   UP   ]
   dgx-03 ................ [  DOWN  ] (health check failed: gpuhealth)
   ```

2. Inspect the latest monitoring samples for the failed node. The command name can vary slightly between BCM versions; check `help` inside `device` mode:

   ```bash
   cmsh -c "device; use dgx-03; latesthealthdata"
   ```

3. Check how Slurm sees the same nodes and their GPU GRES:

   ```bash
   sinfo -N -o "%N %G %T %E"
   scontrol show node dgx-03 | grep -E "State|Gres|AllocTRES|Reason"
   ```

   ```
   NODELIST GRES      STATE    REASON
   dgx-01   gpu:h100:8 mixed   none
   dgx-02   gpu:h100:8 allocated none
   dgx-03   gpu:h100:8 drained  XID79_gpu3
      State=DRAINED ...
      Gres=gpu:h100:8
      Reason=XID79_gpu3 [root@2026-11-11T03:42:10]
   ```

4. Drain and resume procedure in Slurm:

   ```bash
   sudo scontrol update NodeName=dgx-03 State=DRAIN Reason="XID79_gpu3"
   # ... after field service + dcgmi diag -r 3 passes ...
   sudo scontrol update NodeName=dgx-03 State=RESUME
   ```

5. Review a Run:ai utilization scenario. A Kubernetes AI cluster has 64 H100 GPUs. The dashboard shows 100% **allocation** but only 22% average `DCGM_FI_PROF_SM_ACTIVE`. Most workloads are small LLM inference endpoints (NIM) and Jupyter notebooks, each holding a full GPU.

### Questions

- **8.1** Order the escalation for the XID 79 on `dgx-03` across the layers: DCGM/dmesg detection → scheduler → BCM → BMC/Redfish → vendor. Who drains the node, and why must that happen *before* hardware work?
- **8.2** Why should a node pass `dcgmi diag -r 3` before `State=RESUME`?
- **8.3** In the Run:ai scenario, explain the gap between 100% allocation and 22% SM activity. Name two Run:ai or NVIDIA mechanisms that close it, and say where MIG fits in.
- **8.4** What is the role of BCM compared with Slurm or Kubernetes? Which one decides *where a job runs*, and which one decides *what software is on the node*?
- **8.5** Build a monitoring stack checklist that layers Exercises 1–7 for a production AI data center: what is collected at each layer, and by which tool?

---

## Answers

<details>
<summary><strong>Exercise 1 — BMC, IPMI, Redfish</strong></summary>

**1.1** Use the **BMC**, through Redfish, IPMI, the web UI or serial-over-LAN. It is a separate controller with its own NIC, firmware and standby power, so it does not depend on the host OS. You can read the SEL and the serial console output of the panic, check sensors, and power-cycle the host through `ComputerSystem.Reset` or `ipmitool chassis power cycle`.

**1.2** Redfish IDs are vendor-defined. Examples include `1`, `System.Embedded.1`, `Self` and a serial number like `437XR1138R2`. The spec guarantees the *collection* and its `Members` links, not the IDs. Hypermedia navigation makes the automation portable across OEMs.

**1.3** Any two of the following:
- HTTPS/TLS with modern authentication and sessions, where IPMI has a weak RMCP+ cipher history.
- A standard JSON schema that is self-describing and versioned.
- RESTful operations that integrate with any HTTP tooling.
- Much richer models: firmware update, storage, accelerators, event subscriptions.
- DMTF-standardized OEM interoperability.

**1.4** No, this is a **power delivery event** (loss of AC input on PSU1). It belongs to facilities and data center operations: PDU, circuit and PSU checks. It matters for GPUs indirectly. With redundant PSUs the node keeps running, but losing redundancy on a 10 kW node can force power capping or a shutdown under load.

**1.5** Implementations are mid-transition. Older BMC firmware exposes only `Thermal`/`Power`, newer firmware exposes `ThermalSubsystem`/`PowerSubsystem` (the older ones are deprecated), and many expose both. Tooling that reads only one breaks on part of the fleet.

</details>

<details>
<summary><strong>Exercise 2 — nvidia-smi</strong></summary>

**2.1**
- **GPU 2**: 0% utilization, 0 MiB used, idle power. Either it is unallocated, or a job requested it and isn't using it. Check the scheduler.
- **GPU 3**: 88 °C, pinned at its 700 W power limit, and **2 uncorrected volatile ECC errors**. This is a hardware health concern that needs DCGM health checks and possibly a drain.
- GPUs 0 and 1 are healthy and busy.

**2.2** The GPU is **throttling**: clocks drop below their maximum, so throughput falls and step time rises. In synchronous distributed training, one slow GPU slows the whole job. Likely causes are insufficient cooling (blocked airflow, high inlet temperature, CRAH or liquid-loop issues, a failed fan), an exceeded rack power budget, or a misconfigured power limit. Correlate with BMC inlet and exhaust temperatures from Exercise 1.

**2.3** An uncorrectable HBM error was found, and the row is **marked for remapping but not yet applied**. The remap is applied only after a **GPU reset or node reboot**. Until then the GPU remains at risk. Drain, reset, then verify `Pending: No`.

**2.4** Persistence mode keeps the driver loaded and the GPU initialized even when no client holds it open. This removes multi-second initialization latency at every job start and keeps GPU state consistent between jobs. The `nvidia-persistenced` daemon is the recommended mechanism.

**2.5** No. `utilization.gpu` is the percentage of time **at least one kernel was running** during the sample window. A single tiny kernel occupying a few SMs reads as 100%. You need profiling metrics such as SM activity, tensor activity and DRAM activity (Exercise 3).

</details>

<details>
<summary><strong>Exercise 3 — DCGM</strong></summary>

**3.1** Kernels run continuously, so `GPUTL` is high. But only about 31% of SM cycles are active, tensor cores are almost unused (about 5%), and DRAM bandwidth is about 87% saturated. The workload is **memory-bandwidth bound** and does not exploit tensor cores. Suggestions:
- Use mixed precision (BF16/FP8) so tensor cores engage.
- Use larger batch sizes.
- Use kernel fusion and fused attention kernels to cut memory traffic.
- Check data layout.

**3.2** Level 3 runs **stress and burn-in tests**: memory bandwidth, targeted power and SM stress. It needs exclusive GPU access, would crash or corrupt production jobs, and its results would be skewed by other load. `dcgmi health -c` only **reads** watch data that the host engine has already collected in the background.

**3.3** **Health** runs continuously and passively: it watches PCIe, memory/ECC, NVLink, thermal, power and the driver, with no impact on workloads. Use it at all times, feeding alerts. **Diag** is an on-demand active test. Run it at node acceptance or burn-in, after hardware repair or RMA, after driver or firmware upgrades, before returning a drained node to service, and as a periodic preventive check.

**3.4** Any two of the following:
- Profiling metrics (`SM_ACTIVE`, tensor pipe, DRAM, NVLink and PCIe throughput).
- GPU groups and policies with automatic actions.
- Active diagnostics (`dcgmi diag`).
- A continuous host engine with history and watches.
- Job statistics accounting.
- The Prometheus integration through `dcgm-exporter`.
- APIs for fleet integration.

</details>

<details>
<summary><strong>Exercise 4 — XID triage</strong></summary>

**4.1**

| XID | Component | Probable cause | Class | Action |
|---|---|---|---|---|
| **13** | Graphics engine exception | Out-of-bounds access or illegal instruction in user CUDA code, or a framework bug | Usually **application** | Inform the job owner. If it recurs on one GPU across different jobs, suspect hardware and run diagnostics |
| **79** | PCIe link lost ("fallen off the bus") | Hardware, PCIe/riser, power or thermal event | **Hardware/platform** | Drain, collect `nvidia-bug-report.sh`, check BMC logs, likely field service or RMA |
| **63** | Row remapper (HBM) | An ECC error triggered a row remap that is pending | **Recoverable hardware event** | Drain, reset the GPU or reboot to apply, verify. Repeated events lead to RMA |
| **74** | NVLink | Fatal NVLink error on link 5 | **Hardware/platform** (could be the GPU, NVSwitch or baseboard) | Drain, run `dcgmi diag`, check NVLink counters, escalate to the vendor |

**4.2** XID 79 is often a **symptom** of a platform event: PSU or power loss, an overheating board, or a PCIe switch or riser fault. The BMC SEL and Redfish logs record what happened on the board around that timestamp. Replacing a healthy GPU when the real fault is a PSU or riser wastes an RMA and leaves the problem in place.

**4.3** **Reset the GPU** (`nvidia-smi -r -i <id>`, with the GPU idle) or reboot the node. **XID 64** indicates that the row remapping itself failed. That GPU needs an RMA.

**4.4** The bus ID locates the GPU *within* the node, but the **serial number** is what the vendor or RMA process requires. It also lets you track one physical board across reseats, slot changes and node moves.

</details>

<details>
<summary><strong>Exercise 5 — MIG</strong></summary>

**5.1** `3g` is the number of **compute (GPC) slices**, 3 of the 7. `40gb` is the instance's **memory capacity**, which corresponds to 4 of the 8 memory slices on H100 80GB. Compute and memory are allocated in separate slice units, so the name encodes both.

**5.2** **No.** The layout uses 3 + 2 + 1 + 1 = **7/7 compute slices**. Memory is also full: 4 + 2 + 1 + 1 = **8/8 memory slices**. There is no capacity left.

**5.3** **MIG** gives hardware isolation. The inference service has dedicated SMs, L2 cache, memory bandwidth and memory capacity, which yields predictable latency and fault containment: the batch job crashing or using all its memory cannot affect the service. **Time-slicing** context-switches the whole GPU, with no memory isolation and no QoS guarantee. The noisy job causes latency jitter and could exhaust shared memory. MIG is the correct choice here.

**5.4** `7g.80gb` (ID 0). A full-size MIG instance keeps a uniform, MIG-enabled configuration across the fleet. Operators can then switch layouts through MIG Manager without toggling MIG mode, which can require a reset. The instance still gives the security and isolation semantics of a MIG device.

**5.5** The **GPU instance** dimension: `GPU_I_ID` and `GPU_I_PROFILE` labels in `dcgm-exporter`, plus the MIG UUID. Without it, metrics from several tenants on one physical GPU collapse into a single `gpu="0"` series. Note that some device-level fields, such as power and temperature, are physical-GPU-wide and cannot be split per instance.

</details>

<details>
<summary><strong>Exercise 6 — Kubernetes</strong></summary>

**6.1** The **NVIDIA device plugin** registers with the kubelet and advertises `nvidia.com/gpu`. **GPU Feature Discovery (GFD)**, working with Node Feature Discovery, creates the `nvidia.com/gpu.*` labels.

**6.2** Extended resources such as `nvidia.com/gpu` are **integer-only and non-overcommittable**. If you set them in `limits`, Kubernetes defaults the request to the same value. You may set both, but they must be equal. `0.5` is **not allowed**. Fractional sharing needs MIG (separate resource names), time-slicing configured in the device plugin (which advertises replicas), or a scheduler layer like Run:ai with fractional GPUs.

**6.3** `nvidia.com/mig-1g.10gb: 1`. The **mixed** strategy exposes one resource name per MIG profile. The **single** strategy exposes all slices as `nvidia.com/gpu` and requires every GPU on the node to use the same profile.

**6.4** It queries the **kubelet Pod Resources API** (a gRPC socket) to map allocated device IDs to pod, namespace and container, then attaches those as labels. This enables **showback and chargeback** (GPU-hours and energy per namespace or team), idle-allocation detection and quota decisions.

**6.5** The exporter emits its own `pod` and `namespace` labels, which describe the workload *using* the GPU. Prometheus also attaches target labels with the same names, which describe the *exporter pod* it scraped. With `honorLabels: false`, Prometheus keeps its target labels and renames the conflicting scraped ones to `exported_pod` and `exported_namespace`. Set `honorLabels: true` on the ServiceMonitor, or write queries against `exported_*`.

</details>

<details>
<summary><strong>Exercise 7 — Alerting with promtool</strong></summary>

**7.1** At minute 2 the condition becomes true and the alert goes **pending**. `promtool` `exp_alerts` only lists **firing** alerts, so at minute 5 (pending for 3 minutes) the list is empty. The alert fires once the condition has held for `for: 5m`, which is at **minute 7**. At minute 9 it is firing with `$value` = 93.

**7.2** An XID is a discrete, already-confirmed fault event. Waiting adds detection latency, and the value may change or reset. Temperature is a continuous signal with transient spikes, so `for:` suppresses flapping on short peaks and alerts only on sustained overheating.

**7.3** It displays the XID **code**, for example "XID 79". The code determines severity and routing: 13 goes to the application owner, while 79, 74 and 48 page on-call infrastructure and open a hardware ticket. Alertmanager routes or an inhibition layer can key on that value through a recording rule or a relabel.

**7.4** `pod!=""` restricts the alert to GPUs **allocated** to a Kubernetes workload. An unallocated idle GPU is a capacity-planning matter, not an action for a pod owner. **`DCGM_FI_PROF_SM_ACTIVE`** (or `DCGM_FI_PROF_GR_ENGINE_ACTIVE`) is more accurate than `GPU_UTIL`. It measures the real fraction of SM activity and catches the case of "100% util but mostly idle SMs".

**7.5** The assertion at `eval_time: 9m` for `GPUHighTemperature` fails. The alert became active at minute 2, so with `for: 10m` it would fire only at minute 12. At minute 9 it is still pending, so `promtool` reports an expected firing alert that was not found.

</details>

<details>
<summary><strong>Exercise 8 — BCM, Slurm, Run:ai</strong></summary>

**8.1**
1. DCGM health, `dcgm-exporter` or `dmesg` detects XID 79, and an alert fires.
2. The **scheduler** drains the node (Slurm `State=DRAIN`, or Kubernetes `kubectl cordon` plus `drain`). Automation can do this through BCM health checks or a DCGM policy. Draining stops new work landing on the node and lets running jobs checkpoint or finish.
3. **BCM** marks the node DOWN, collects logs and later reprovisions it.
4. The **BMC/Redfish** layer supplies the SEL, sensor history and power control for remote recovery.
5. The **vendor** receives an RMA or field-service ticket with the GPU serial number and the bug report.

Draining first prevents job failures on bad hardware and avoids pulling a GPU out from under running workloads.

**8.2** The repair has to be proven under load. Level 3 stress-tests memory, compute, PCIe and NVLink and catches reseat errors, a bad replacement part or a lingering platform fault. Returning an unverified node risks crashing large distributed jobs: one bad GPU fails an entire multi-node training run.

**8.3** Allocation counts GPUs **reserved**; SM activity measures GPUs **working**. Small inference endpoints and idle notebooks reserve a full GPU but use a fraction of it. Mechanisms that close the gap:
- **Run:ai fractional GPUs and GPU memory sharing**, which put several small workloads on one GPU.
- **Quotas with over-quota borrowing and fair share**, so idle guaranteed capacity is lent out and reclaimed when needed.
- Consolidating NIM endpoints onto right-sized resources.
- Idle-workload policies and notebook timeouts.

**MIG** delivers hardware-isolated fractions for workloads that need guaranteed QoS or isolation. Software fractions give finer-grained, more flexible packing with weaker isolation.

**8.4** **BCM** is the cluster management and provisioning layer. It handles the OS images, the driver and CUDA stack, configuration, node health checks and monitoring, and it **decides what software is on the node**. **Slurm or Kubernetes (with Run:ai)** are workload managers or schedulers that **decide where a job runs**, based on GRES and resources, quotas and priorities. BCM deploys and integrates these schedulers.

**8.5**

| Layer | What to collect | Tool |
|---|---|---|
| Facility / board | Inlet and exhaust temperatures, fans, PSUs, power draw, SEL events, firmware versions | BMC through **Redfish** (preferred) or IPMI, plus a Redfish exporter |
| GPU device | Utilization, memory, temperature, power, clocks and throttle reasons, ECC, row remap, XID | **DCGM** (health watches) and `nvidia-smi` for ad-hoc checks |
| GPU efficiency | SM activity, tensor activity, DRAM activity, NVLink and PCIe throughput | **DCGM profiling metrics** |
| Validation | Burn-in, post-repair and pre-resume checks | **`dcgmi diag`** levels 1–4 |
| Kubernetes | Per-pod GPU metrics, allocation, MIG instance labels | **GPU Operator** + **`dcgm-exporter`** → Prometheus → Grafana |
| Alerting | XID, thermal, ECC and idle rules, unit-tested | Prometheus rules + `promtool` + Alertmanager |
| Cluster | Node state, provisioning, health checks, job placement, quotas | **Base Command Manager**, **Slurm**, **Run:ai** |

</details>