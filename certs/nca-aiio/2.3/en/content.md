# 2.3 Power and Cooling Requirements in the AI Data Center

## 1. Motivation: why AI breaks the traditional data center envelope

For about twenty years, enterprise data centers were designed around **5–15 kW per rack**. Raised floors, perimeter CRAC/CRAH units and single-phase PDUs were enough because a rack of 1U/2U CPU servers rarely exceeded that budget.

Accelerated computing changes the physics:

| System (NVIDIA reference) | Form factor | Approx. max system power | Cooling |
|---|---|---|---|
| DGX H100 (8× H100 SXM5, 700 W TDP each) | 8U | ~10.2 kW | Air |
| DGX B200 (8× B200, ~1000 W each) | 10U | ~14.3 kW | Air |
| GB200 NVL72 (72 Blackwell GPUs + 36 Grace CPUs, one NVLink domain) | 1 rack | on the order of ~120 kW per rack | Liquid (direct-to-chip) |

A single DGX H100 draws about as much as an entire legacy rack. Four of them in one rack produce ~40 kW of heat. A GB200 NVL72 rack is roughly **10×** a traditional rack. The architectural problems that follow are:

1. **Power delivery.** Single-phase 208 V/30 A circuits cannot feed these loads. You need high-amperage three-phase feeds, high-capacity PDUs, and redundancy designed at the facility level.
2. **Heat rejection.** Essentially every watt delivered becomes heat. Air has low heat capacity, so above roughly 40–50 kW/rack, moving enough air becomes impractical (fan power, noise, bypass/recirculation). Liquid cooling takes over.
3. **Floor loading and space.** A DGX H100 weighs ~130 kg. Dense racks stress floor load ratings. Power, rather than physical space, usually becomes the limiting factor, which leaves "stranded" rack units.
4. **Operational coupling.** GPU throttling caused by thermal or power events looks like a *performance* bug ("my training job got 20% slower"). The SRE has to correlate facility telemetry (inlet temperature, PDU load) with GPU telemetry (clock event reasons).

The NCA-AIIO exam tests these concepts at a high level: what drives power and cooling requirements, the vocabulary (PUE, TDP, N+1, CDU, hot/cold aisle), and the trade-offs between cooling approaches.

---

## 2. Core concepts and formulas

### 2.1 Power vocabulary

| Term | Meaning | Why it matters |
|---|---|---|
| **TDP (Thermal Design Power)** | Sustained power, and therefore heat, a component is designed to dissipate (H100 SXM5: 700 W) | Base input for both power and cooling budgets |
| **Nameplate / max system power** | Worst-case draw of the whole system (GPUs + CPUs + NICs + fans + PSU losses) | Use it for circuit sizing. Never size from "typical" draw |
| **kW vs kVA** | kW = real power. kVA = apparent power. kW = kVA × Power Factor (PF) | UPS and generators are rated in kVA. Modern PSUs have PF ≈ 0.95–0.99 |
| **Three-phase power** | P = √3 × V(line-to-line) × I × PF | Standard for high-density racks |
| **Continuous-load derating** | In North America (NEC), continuous loads are limited to 80% of breaker rating | A 60 A breaker gives 48 A usable |
| **PDU (rack Power Distribution Unit)** | Basic, metered, monitored (per-outlet metering), switched (remote on/off) | Metered/switched PDUs feed telemetry into DCIM |
| **UPS** | Uninterruptible Power Supply. Bridges utility loss until generators start | Sized in kVA, with runtime in minutes |
| **PSU redundancy** | e.g. DGX H100 has 6 PSUs. It tolerates PSU and feed failures as long as enough PSUs stay powered | Requires two independent feeds (A/B) wired correctly |

### 2.2 Redundancy models

| Model | Definition | Tolerates | Cost / efficiency | Typical use |
|---|---|---|---|---|
| **N** | Exactly the capacity required | No failure | Cheapest | Labs, non-critical |
| **N+1** | One extra component (UPS module, CRAH, pump) | Single component failure | Moderate | Common for cooling plants, pumps |
| **2N** | Two fully independent paths (A and B feeds, each able to carry 100%) | Loss of a whole path | Most expensive. Each path runs ≤50% loaded | Tier III/IV critical facilities |
| **2N+1 / N+N** | Variations combining both | Path + component failure | Highest | Hyperscale / finance |

> **Trade-off:** In 2N, each feed must carry the *full* rack load alone. A 40 kW rack on 2N needs two 40 kW-capable feeds, even though in normal operation each carries ~20 kW. This is a classic source of "the circuit tripped during maintenance" incidents: someone sized each feed for the shared load and not for the failover load.

### 2.3 Cooling vocabulary and conversions

| Quantity | Conversion |
|---|---|
| Heat from IT load | ≈ 100% of electrical input becomes heat |
| BTU/hr | 1 W = 3.412 BTU/hr |
| Ton of refrigeration | 1 ton = 12,000 BTU/hr ≈ 3.517 kW |
| Airflow required (imperial) | CFM ≈ 3.16 × Watts / ΔT(°F) |
| Airflow required (metric) | m³/h ≈ 3.0 × Watts / ΔT(°C) (approx., sea level) |

**Worked example: one DGX H100 at 10.2 kW**

- Heat: 10,200 W × 3.412 ≈ **34,800 BTU/hr ≈ 2.9 tons** of cooling
- Airflow with a 20 °F (~11 °C) inlet→exhaust ΔT: 3.16 × 10,200 / 20 ≈ **1,610 CFM**

Four of them in one rack need ~6,400 CFM through a single 600 mm-wide rack face. This is why air cooling hits a practical wall.

### 2.4 Facility efficiency metrics

**PUE (Power Usage Effectiveness)**, defined by The Green Grid:

```
PUE = Total Facility Power / IT Equipment Power
```

- PUE 1.0 is the theoretical ideal: all power goes to IT.
- Legacy enterprise facilities sit around 1.6–2.0. Modern hyperscale/liquid-cooled facilities reach about 1.1–1.2.
- **DCiE** = 1 / PUE × 100% (a PUE of 1.25 gives a DCiE of 80%).

Example: a 1 MW IT load at PUE 1.5 means 1.5 MW drawn from the utility. 500 kW goes to cooling, power conversion losses and lighting. Moving to PUE 1.15 saves 350 kW continuously, which is ~3 GWh/year.

> **Caveat (exam-relevant):** PUE measures *facility overhead*, not *computational efficiency*. Server fans count as "IT load", so heavy air cooling inside servers can make PUE look better while total energy rises. Liquid cooling often reduces server fan power *and* facility cooling power at the same time.

Related metrics: **WUE** (Water Usage Effectiveness, L/kWh) and **CUE** (Carbon Usage Effectiveness). Evaporative cooling improves PUE but worsens WUE, a real trade-off in water-stressed regions.

### 2.5 Thermal envelopes (ASHRAE TC 9.9)

| Envelope | Inlet air temperature |
|---|---|
| ASHRAE **recommended** (classes A1–A4) | 18–27 °C (64.4–80.6 °F) |
| A1 allowable | 15–32 °C |
| A2 allowable | 10–35 °C |

For liquid cooling, ASHRAE defines facility water classes (W17, W27, W32, W40, W45, W+). The number is the maximum facility supply water temperature in °C. "Warm-water" cooling (W32 and above) makes it possible to use **free cooling** (dry coolers, no chillers) for much of the year, which drastically lowers PUE.

---

## 3. Power delivery architecture

```
 Utility (MV, e.g. 11–33 kV)
        │
   [Transformer] ──► LV (e.g. 400/415 V 3φ EU, 480 V 3φ US)
        │
  [Switchgear / ATS] ◄── [Generator] (N+1)
        │
     [UPS]  (double conversion, often 2N: UPS-A / UPS-B)
        │
     [PDU / RPP]  (floor-level, steps 480→208 V in US)
        │
  ┌─────┴─────┐
 Feed A     Feed B          ← two independent paths
  │           │
 [rPDU-A]   [rPDU-B]        ← rack PDUs, 3φ, metered/switched
  │ │ │       │ │ │
  PSU1..3    PSU4..6        ← DGX PSUs split across feeds
```

### 3.1 Rack circuit sizing

| Circuit | Raw capacity | Usable at 80% (NEC continuous) | Fits |
|---|---|---|---|
| 208 V 1φ 30 A | 6.2 kVA | ~5.0 kW | Legacy servers only |
| 208 V 3φ 30 A | 10.8 kVA | ~8.6 kW | Not even one DGX H100 |
| 208 V 3φ 60 A | 21.6 kVA | ~17.3 kW | 1 DGX B200 or 1 DGX H100 (with headroom) |
| 415 V 3φ 32 A (EU, IEC 60309) | ~23 kVA | ~18.4 kW (local rules apply) | 1 DGX H100 (2 × 10.2 kW = 20.4 kW does not fit) |
| 415 V 3φ 63 A | ~45 kVA | ~36.2 kW | 3 DGX H100 per feed (4 = 40.8 kW does not fit) |

Calculation for 208 V 3φ 60 A: √3 × 208 × 48 A ≈ 17,290 W.

> **Design rule:** size per-feed capacity for the *full* rack load at max system power (the 2N failover case), not for the average measured draw.

### 3.2 Why higher voltage helps

For the same power, higher voltage means lower current. That gives thinner conductors, lower I²R losses and fewer conversion stages. This is why AI facilities push toward 415 V three-phase distribution to the rack, and why very high-density designs (such as liquid-cooled rack-scale systems) use **busbar-based power shelves** inside the rack instead of individual PSU cords.

### 3.3 Power capping as a capacity tool

When the facility cannot deliver nameplate power to every rack, operators have three options:

1. **Derate racks:** fewer systems per rack, which strands space.
2. **Oversubscribe with telemetry:** rely on the fact that not all nodes peak at once. This is risky for synchronous training, which *does* peak together.
3. **Cap GPU power** (`nvidia-smi -pl`, DCGM power policies). This trades a modest throughput reduction for a predictable envelope. GPUs are often more energy-efficient (perf/W) below max TDP, so a cap of ~80% can cost much less than 20% of performance on many workloads. Always benchmark your own workload.

---

## 4. Cooling architectures: comparison and trade-offs

| Approach | Practical rack density | Mechanism | Pros | Cons |
|---|---|---|---|---|
| **Perimeter CRAC/CRAH, raised floor, open aisles** | ≤ ~10 kW | Chilled air pushed under floor, through perforated tiles | Simple, well understood | Hot/cold air mixing, poor efficiency, can't handle AI |
| **Hot-aisle or cold-aisle containment** | ~15–30 kW | Physical barriers prevent air mixing | Big efficiency gain, low cost retrofit | Still air-limited |
| **In-row cooling** | ~20–40 kW | Cooling units between racks, short air path | Close-coupled, scalable per row | Takes rack positions, chilled water into the row |
| **Rear-door heat exchanger (RDHx)** | ~30–60+ kW (active doors) | Water-cooled coil on rack rear door neutralizes exhaust | Retrofit-friendly, keeps air-cooled servers | Water at the rack. Passive doors limited by server fan pressure |
| **Direct-to-chip liquid cooling (DLC)** | 100+ kW (e.g. GB200 NVL72) | Cold plates on GPUs/CPUs. Coolant loop via a CDU | Removes most heat at the source. Enables warm-water/free cooling | Facility plumbing, CDUs, leak detection, new ops skills. Residual heat still needs air |
| **Immersion (single/two-phase)** | 100+ kW | Servers submerged in dielectric fluid | Very high density, near-silent | Hardware compatibility, serviceability, fluid handling |

### 4.1 Direct liquid cooling internals

```
 Facility Water System (FWS)            Technology Cooling System (TCS)
 (cooling tower / dry cooler / chiller)  (closed secondary loop to the rack)
        │                                         │
        └──────►  [ CDU: heat exchanger + pumps ] ◄┘
                    - isolates facility water from IT loop
                    - controls flow, pressure, supply temp
                    - filtration, leak detection, N+1 pumps
                              │
                    Rack manifolds ──► cold plates (GPU/CPU)
```

Key specifications an architect must collect from the vendor and facility:

- **Heat capture ratio:** the fraction of heat going to liquid vs. air. DLC rarely captures 100%. Memory, NICs and PSUs still reject heat to air, so you still need some air handling.
- **Supply temperature and flow rate** (L/min per rack), plus allowable ΔT.
- **CDU type:** in-rack, in-row, or facility-scale. Liquid-to-liquid vs. liquid-to-air (liquid-to-air CDUs let you deploy DLC without facility water, at limited capacity).
- **Redundancy:** N+1 pumps, dual power to the CDU. A CDU failure is a whole-rack thermal event within minutes.
- **Water quality:** chemistry, filtration (micron rating), wetted materials compatibility.

### 4.2 Air cooling done right (for DGX H100/B200 class)

- Strict **hot-aisle/cold-aisle** orientation. DGX systems pull front-to-back.
- **Blanking panels** in every empty U. Missing panels cause hot-air recirculation to GPU inlets.
- Seal cable cutouts. Containment that is breached is no containment.
- Measure **inlet** temperature at the top, middle and bottom of the rack. The top of the rack is usually the hottest because of recirculation over the rack.

---

## 5. How data center design choices reduce power (connection to the reference sources)

- **NVLink / NVSwitch:** moving data GPU-to-GPU over NVLink is far more energy-efficient per bit than going over PCIe and the network. Rack-scale NVLink domains such as GB200 NVL72 concentrate compute, and that concentration is precisely what forces liquid cooling.
- **BlueField DPUs:** offloading networking, storage and security processing from host CPUs to the DPU frees CPU cycles and can reduce the number of servers, and the power, needed for infrastructure tasks. DPUs also isolate the infrastructure control plane from tenant workloads.
- **GPUDirect / accelerated I/O:** bypassing CPU bounce buffers reduces data movement, latency and wasted power.
- **Consolidation:** one accelerated system replaces many CPU nodes. Total facility power per unit of work drops even though per-rack density rises. *Density goes up; total energy per job goes down.* Keep both statements in mind for the exam.

---

## 6. Telemetry and automation manifests

Power and cooling are only manageable if they are observable. Below is a complete Kubernetes-side stack: DCGM Exporter with custom metrics, alerting rules for thermal and power events, and an optional fleet-wide GPU power cap.

### 6.1 DCGM Exporter custom metrics ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: dcgm-exporter-power-thermal-metrics
  namespace: gpu-operator
  labels:
    app.kubernetes.io/name: dcgm-exporter
data:
  dcgm-metrics.csv: |
    # Format: DCGM field, Prometheus metric type, help text
    DCGM_FI_DEV_SM_CLOCK, gauge, SM clock frequency (in MHz).
    DCGM_FI_DEV_MEM_CLOCK, gauge, Memory clock frequency (in MHz).
    DCGM_FI_DEV_GPU_TEMP, gauge, GPU temperature (in C).
    DCGM_FI_DEV_MEMORY_TEMP, gauge, Memory temperature (in C).
    DCGM_FI_DEV_POWER_USAGE, gauge, Power draw (in W).
    DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION, counter, Total energy consumption since boot (in mJ).
    DCGM_FI_DEV_CLOCKS_EVENT_REASONS, gauge, Bitmask of reasons clocks are reduced.
    DCGM_FI_DEV_GPU_UTIL, gauge, GPU utilization (in %).
    DCGM_FI_DEV_XID_ERRORS, gauge, Value of the last XID error encountered.
```

> Older DCGM releases expose the throttle bitmask as `DCGM_FI_DEV_CLOCK_THROTTLE_REASONS`. Check `dcgmi dmon -l` on your version.

When deploying through the NVIDIA GPU Operator, point it at this ConfigMap:

```yaml
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: cluster-policy
spec:
  dcgmExporter:
    enabled: true
    config:
      name: dcgm-exporter-power-thermal-metrics
    env:
      - name: DCGM_EXPORTER_COLLECTORS
        value: "/etc/dcgm-exporter/dcgm-metrics.csv"
    serviceMonitor:
      enabled: true
      interval: 15s
```

### 6.2 PrometheusRule: thermal, power and throttling alerts

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gpu-power-thermal-alerts
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: gpu-thermal
      interval: 30s
      rules:
        - alert: GPUTemperatureHigh
          expr: DCGM_FI_DEV_GPU_TEMP > 85
          for: 5m
          labels:
            severity: warning
            domain: facility-cooling
          annotations:
            summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} above 85C"
            description: "Sustained high GPU temperature. Check rack inlet temperature, blanking panels, fan status and CDU flow."
        - alert: GPUMemoryTemperatureHigh
          expr: DCGM_FI_DEV_MEMORY_TEMP > 90
          for: 5m
          labels:
            severity: warning
            domain: facility-cooling
          annotations:
            summary: "HBM temperature high on {{ $labels.Hostname }} GPU {{ $labels.gpu }}"
            description: "HBM thermal headroom is low; expect memory throttling."
        - alert: GPUThermalSlowdown
          expr: |
            (
              floor(DCGM_FI_DEV_CLOCKS_EVENT_REASONS / 32) % 2 == 1
            )
            or
            (
              floor(DCGM_FI_DEV_CLOCKS_EVENT_REASONS / 64) % 2 == 1
            )
          for: 2m
          labels:
            severity: critical
            domain: facility-cooling
          annotations:
            summary: "Thermal slowdown active on {{ $labels.Hostname }} GPU {{ $labels.gpu }}"
            description: "SW (0x20) or HW (0x40) thermal slowdown. Performance is degraded; correlate with rack inlet sensors."
    - name: gpu-power
      interval: 30s
      rules:
        - alert: GPUPowerBrakeSlowdown
          expr: |
            floor(DCGM_FI_DEV_CLOCKS_EVENT_REASONS / 128) % 2 == 1
          for: 1m
          labels:
            severity: critical
            domain: facility-power
          annotations:
            summary: "HW power brake on {{ $labels.Hostname }}"
            description: "Power brake (0x80) is asserted by the system, typically due to PSU loss or insufficient power delivery. Check PSU and feed status in the BMC."
        - alert: NodeGPUPowerNearBudget
          expr: |
            sum by (Hostname) (DCGM_FI_DEV_POWER_USAGE)
              / on() group_left()
            scalar(vector(5600))
              > 0.95
          for: 10m
          labels:
            severity: warning
            domain: facility-power
          annotations:
            summary: "GPU power on {{ $labels.Hostname }} above 95% of 5.6 kW budget"
            description: "Aggregate GPU draw (8 x 700 W = 5.6 kW) near budget; validate rack PDU headroom for 2N failover."
        - record: cluster:gpu_power_watts:sum
          expr: sum(DCGM_FI_DEV_POWER_USAGE)
        - record: cluster:gpu_energy_kwh:rate1h
          expr: |
            sum(rate(DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION[1h])) * 3600 / 1000 / 3600 / 1000
```

Bitmask decoding used above (`floor(x / 2^n) % 2`): `0x04` SW power cap, `0x08` HW slowdown, `0x20` SW thermal slowdown, `0x40` HW thermal slowdown, `0x80` HW power brake slowdown.

### 6.3 Fleet-wide GPU power cap DaemonSet

Use this when facility capacity is below nameplate. It is privileged by necessity, because changing the power limit requires root on the device.

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: gpu-power-cap
  namespace: gpu-operator
  labels:
    app: gpu-power-cap
spec:
  selector:
    matchLabels:
      app: gpu-power-cap
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app: gpu-power-cap
    spec:
      nodeSelector:
        nvidia.com/gpu.present: "true"
        facility.example.com/power-capped: "true"
      runtimeClassName: nvidia
      priorityClassName: system-node-critical
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      containers:
        - name: power-cap
          image: nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04
          imagePullPolicy: IfNotPresent
          env:
            - name: NVIDIA_VISIBLE_DEVICES
              value: "all"
            - name: GPU_POWER_LIMIT_WATTS
              value: "560"
          securityContext:
            privileged: true
          command:
            - /bin/bash
            - -c
            - |
              set -euo pipefail
              nvidia-smi -pm 1
              nvidia-smi -pl "${GPU_POWER_LIMIT_WATTS}"
              nvidia-smi --query-gpu=index,power.limit --format=csv
              trap 'nvidia-smi -pl $(nvidia-smi --query-gpu=power.default_limit --format=csv,noheader,nounits | head -n1 | cut -d. -f1); exit 0' TERM
              while true; do sleep 3600 & wait $!; done
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              cpu: 50m
              memory: 64Mi
```

> Notes: `nvidia-smi -pl` does **not** persist across reboots or driver reloads, which is why a DaemonSet (or a systemd unit on bare metal) reapplies it. The cap must sit within `power.min_limit`–`power.max_limit`. The `trap` restores the default limit when the pod is removed.

### 6.4 Bare-metal equivalent: systemd unit

```ini
# /etc/systemd/system/gpu-power-cap.service
[Unit]
Description=Apply facility GPU power cap
After=nvidia-persistenced.service
Requires=nvidia-persistenced.service

[Service]
Type=oneshot
ExecStart=/usr/bin/nvidia-smi -pl 560
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

### 6.5 Rack capacity plan as code (Ansible inventory vars)

```yaml
# group_vars/rack_a12.yml
rack:
  id: A12
  cooling: air-hot-aisle-containment
  max_cooling_kw: 45
  feeds:
    - name: A
      voltage_ll: 415
      phases: 3
      breaker_amps: 63
      derate_factor: 0.8
    - name: B
      voltage_ll: 415
      phases: 3
      breaker_amps: 63
      derate_factor: 0.8
  redundancy: "2N"
systems:
  - hostname: dgx-a12-01
    model: dgx-h100
    max_power_kw: 10.2
  - hostname: dgx-a12-02
    model: dgx-h100
    max_power_kw: 10.2
  - hostname: dgx-a12-03
    model: dgx-h100
    max_power_kw: 10.2
  - hostname: dgx-a12-04
    model: dgx-h100
    max_power_kw: 10.2
network_and_mgmt_kw: 1.5
```

Validation check: total = 4 × 10.2 + 1.5 = **42.3 kW**. Per-feed capacity = √3 × 415 × 63 × 0.8 ≈ **36.2 kW**, which is **less than 42.3 kW**. Under 2N, a single feed cannot carry the rack during maintenance on the other feed. The design fails. Options: cap GPUs, move to 3 systems per rack, or increase the feed size. This is exactly the kind of check that should run in CI before hardware is racked.

---

## 7. CLI: measuring power and thermals

### 7.1 GPU power readings

```
$ nvidia-smi -q -d POWER -i 0

==============NVSMI LOG==============

Timestamp                                 : Fri Nov 13 10:42:17 2026
Driver Version                            : 550.54.15
CUDA Version                              : 12.4

Attached GPUs                             : 8
GPU 00000000:18:00.0
    GPU Power Readings
        Power Draw                        : 689.42 W
        Current Power Limit               : 700.00 W
        Requested Power Limit             : 700.00 W
        Default Power Limit               : 700.00 W
        Min Power Limit                   : 200.00 W
        Max Power Limit                   : 700.00 W
    Power Samples
        Duration                          : 2.38 sec
        Number of Samples                 : 119
        Max                               : 699.87 W
        Min                               : 652.11 W
        Avg                               : 684.90 W
```

### 7.2 Compact per-GPU view with throttle reasons

```
$ nvidia-smi --query-gpu=index,power.draw,power.limit,temperature.gpu,temperature.memory,clocks.sm,clocks_event_reasons.active --format=csv
index, power.draw [W], power.limit [W], temperature.gpu, temperature.memory, clocks.sm [MHz], clocks_event_reasons.active
0, 688.21 W, 700.00 W, 71, 78, 1980 MHz, 0x0000000000000000
1, 692.03 W, 700.00 W, 73, 80, 1980 MHz, 0x0000000000000000
2, 699.55 W, 700.00 W, 74, 81, 1755 MHz, 0x0000000000000004
3, 690.17 W, 700.00 W, 72, 79, 1980 MHz, 0x0000000000000000
4, 541.90 W, 700.00 W, 87, 92, 1410 MHz, 0x0000000000000020
5, 695.48 W, 700.00 W, 74, 80, 1980 MHz, 0x0000000000000000
6, 689.77 W, 700.00 W, 72, 79, 1980 MHz, 0x0000000000000000
7, 693.12 W, 700.00 W, 73, 80, 1980 MHz, 0x0000000000000000
```

Reading it:

- GPU 2 shows `0x4` (SW power cap). It is pinned at its 700 W limit and clocks back slightly. This is normal at full load.
- GPU 4 shows `0x20` (SW thermal slowdown), 87 °C, and draws *less* power at lower clocks. This is a **cooling problem**, typically a blocked inlet, a failed fan, a missing blanking panel, or the GPU sitting in a hot spot. In synchronous distributed training, this one GPU slows the entire job.

### 7.3 Detailed throttle decoding

```
$ nvidia-smi -q -d PERFORMANCE -i 4

GPU 00000000:9A:00.0
    Performance State                     : P0
    Clocks Event Reasons
        Idle                              : Not Active
        Applications Clocks Setting       : Not Active
        SW Power Cap                      : Not Active
        HW Slowdown                       : Not Active
            HW Thermal Slowdown           : Not Active
            HW Power Brake Slowdown       : Not Active
        Sync Boost                        : Not Active
        SW Thermal Slowdown               : Active
        Display Clock Setting             : Not Active
```

### 7.4 DCGM live monitoring

Field IDs: 155 = power usage, 150 = GPU temp, 140 = memory temp, 156 = total energy.

```
$ dcgmi dmon -e 155,150,140 -d 1000 -c 3
#Entity   POWER                 TMPTR    MMTMP
ID        W                     C        C
GPU 0     688.412               71       78
GPU 1     691.870               73       80
GPU 2     699.102               74       81
GPU 3     690.355               72       79
GPU 4     540.226               87       92
GPU 5     694.981               74       80
GPU 6     689.540               72       79
GPU 7     692.774               73       80
...
```

### 7.5 System-level power via BMC (IPMI DCMI)

```
$ sudo ipmitool dcmi power reading

    Instantaneous power reading:                  9412 Watts
    Minimum during sampling period:               1180 Watts
    Maximum during sampling period:              10050 Watts
    Average power reading over sample period:     8870 Watts
    IPMI timestamp:                           Fri Nov 13 10:43:02 2026
    Sampling period:                          00000001 Seconds.
    Power reading state is:                   activated
```

```
$ sudo ipmitool sdr type "Power Supply"
PSU0_Status      | 60h | ok  | 10.0 | Presence detected
PSU1_Status      | 61h | ok  | 10.1 | Presence detected
PSU2_Status      | 62h | ok  | 10.2 | Presence detected
PSU3_Status      | 63h | ok  | 10.3 | Presence detected, Power Supply AC lost
PSU4_Status      | 64h | ok  | 10.4 | Presence detected
PSU5_Status      | 65h | ok  | 10.5 | Presence detected
```

Here PSU3 lost AC. You need to determine whether one whole feed is down (check all PSUs wired to feed B) or only a single cord/outlet failed.

Sensor names and IDs vary by platform and BMC firmware. Use `ipmitool sdr elist` to enumerate them.

### 7.6 Redfish (out-of-band, scriptable)

```
$ curl -sk -u admin:"$BMC_PASS" https://dgx-a12-01-bmc/redfish/v1/Chassis/ | jq -r '.Members[]."@odata.id"'
/redfish/v1/Chassis/DGX
/redfish/v1/Chassis/HGX_Chassis_0
...

$ curl -sk -u admin:"$BMC_PASS" https://dgx-a12-01-bmc/redfish/v1/Chassis/DGX/PowerSubsystem/PowerSupplies | jq '.Members | length'
6
```

> Chassis IDs differ per platform and firmware. Enumerate first; don't hardcode them. Newer Redfish schemas use `PowerSubsystem` and `ThermalSubsystem`. The older `Power` and `Thermal` resources are deprecated but still common.

### 7.7 Quick capacity math from the shell

```
$ python3 -c "import math; v=415; a=63; d=0.8; print(f'{math.sqrt(3)*v*a*d/1000:.1f} kW usable per feed')"
36.2 kW usable per feed

$ python3 -c "w=42300; print(f'{w*3.412:,.0f} BTU/hr = {w*3.412/12000:.1f} tons')"
144,328 BTU/hr = 12.0 tons
```

---

## 8. Verification and fault diagnosis guide

### 8.1 Commissioning checklist (before production)

1. **Feed mapping:** verify that PSUs 0–2 are on feed A and PSUs 3–5 on feed B (or follow the vendor's documented split). Pull one feed under full load (burn-in) and confirm the system keeps running *without* power brake (`0x80`).
2. **Full-load burn-in:** run DCGM diagnostics (`dcgmi diag -r 3`) or a sustained HPL/NCCL workload across the whole rack simultaneously. Confirm no thermal events and PDU load below breaker derate.
3. **Inlet temperature survey:** measure inlet at the top, middle and bottom of each rack while under load. Keep it within ASHRAE recommended (18–27 °C).
4. **Liquid systems:** CDU flow and pressure within spec, leak detection tested, N+1 pump failover tested under load.
5. **Baseline telemetry:** record per-GPU temperature at full load. Later deviations of a few °C on a single GPU are your earliest cooling-fault signal.

### 8.2 Symptom-to-cause table

| Symptom | Telemetry signature | Likely cause | Action |
|---|---|---|---|
| Training job slower, one node slower than others | One GPU with `0x20`/`0x40`, higher temp | Local airflow issue: fan failure, blocked inlet, missing blanking panel, recirculation | Check fan sensors (`ipmitool sdr type Fan`), physical inspection, inlet temp |
| Whole rack/row throttles at the same time | Many GPUs `0x20`, inlet temps rising | Facility cooling: CRAH failure, chilled-water issue, containment breached, CDU fault | Escalate to facilities. Consider workload migration or power caps |
| All GPUs in a node suddenly drop clocks hard | `0x80` HW power brake | PSU failure or loss of a feed. System asserts power brake to stay under remaining PSU capacity | `ipmitool sdr type "Power Supply"`, check PDU/breaker, restore feed |
| GPUs consistently at `0x4` under load | Power draw = power limit | Normal, or a cap was deliberately set lower than default | Verify `power.limit` vs `power.default_limit`. Expected if capping |
| Breaker trips during maintenance on the other feed | PDU log: overcurrent on surviving feed | 2N sized for shared, not failover load | Re-plan capacity (section 6.5), cap power, rebalance |
| Node reboots/crashes under peak load | BMC SEL: PSU/power events, XID errors | Insufficient PSU capacity, failing PSU, transient overload | `ipmitool sel elist`, replace PSU, check firmware |
| HBM temperature high, GPU core OK | `DCGM_FI_DEV_MEMORY_TEMP` elevated | Memory-heavy workload plus marginal cooling | Improve airflow/coolant flow. Validate against vendor limits |
| Liquid-cooled rack: rising temps on all GPUs | Coolant supply temp rising / flow dropping | CDU pump fault, filter clogging, facility water issue | Check CDU telemetry and alarms. Failover pump. Reduce load |

### 8.3 Diagnostic sequence (thermal throttling incident)

```
$ nvidia-smi --query-gpu=index,temperature.gpu,clocks_event_reasons.active --format=csv,noheader
$ sudo ipmitool sdr type Temperature | grep -i -E "inlet|ambient"
$ sudo ipmitool sdr type Fan
$ sudo ipmitool sel elist | tail -n 20
$ dcgmi health -c
```

Decision logic:

1. **Single GPU hot, inlet normal:** this is a node/server problem (fan, heatsink contact, airflow inside the chassis). Open a hardware ticket.
2. **Whole node hot, inlet hot:** this is a rack/aisle problem (containment, blanking panels, neighboring exhaust). Do a physical inspection.
3. **Many racks hot:** this is a facility problem. Escalate. Apply temporary power caps to reduce the heat load while it is fixed.

---

## 9. Exam-focused summary

- **AI drives density:** DGX H100 ~10.2 kW, DGX B200 ~14.3 kW, GB200 NVL72 ~120 kW/rack. Legacy design is 5–15 kW/rack.
- **Power is usually the binding constraint**, not space. Plan for nameplate/max system power and for the 2N failover case.
- **Three-phase, higher-voltage distribution** is standard for AI racks. Use P = √3 × V × I × PF.
- **Redundancy:** N, N+1 (spare component), 2N (fully independent A/B paths).
- **PUE** = total facility power / IT power. Lower is better, 1.0 is ideal. Liquid and free cooling push it toward ~1.1.
- **Cooling progression:** CRAC/CRAH → containment → in-row → rear-door HX → direct-to-chip (with CDU) → immersion.
- **Above ~40–50 kW/rack**, air becomes impractical and liquid cooling is required.
- **ASHRAE recommended inlet:** 18–27 °C.
- **Conversions:** 1 W = 3.412 BTU/hr, 1 ton = 12,000 BTU/hr ≈ 3.517 kW.
- **Operational signal:** GPU clock event reasons (power cap, thermal slowdown, power brake) connect facility issues to workload performance. Monitor them with DCGM.
- **Efficiency levers:** NVLink (efficient data movement), BlueField DPU (infrastructure offload), consolidation onto accelerated systems, and GPU power capping.

---

## Referencias

- NVIDIA AI Infrastructure and Operations, exam study guide (PDF): https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy, AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA DGX SuperPOD Reference Architecture, DGX B200: https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
- NVIDIA DGX H100 User Guide, Component Descriptions: https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
- NVIDIA NVLink and NVLink Switch: https://www.nvidia.com/en-us/data-center/nvlink/
- NVIDIA Technical Blog, Offloading and Isolating Data Center Workloads with BlueField DPU: https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
- NVIDIA Technical Blog, Accelerating IO in the Modern Data Center: Network IO: https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
- NVIDIA DCGM Documentation (field IDs, `dcgmi`): https://docs.nvidia.com/datacenter/dcgm/latest/index.html
- NVIDIA DCGM Exporter: https://github.com/NVIDIA/dcgm-exporter
- NVIDIA System Management Interface (`nvidia-smi`): https://docs.nvidia.com/deploy/nvidia-smi/index.html
- The Green Grid, PUE: A Comprehensive Examination of the Metric: https://www.thegreengrid.org/en/resources/library-and-tools/20-PUE%3A-A-Comprehensive-Examination-of-the-Metric
- ASHRAE TC 9.9, Data Center Power Equipment Thermal Guidelines and Best Practices: https://www.ashrae.org/technical-resources/bookstore/datacom-series
- DMTF Redfish specification: https://www.dmtf.org/standards/redfish