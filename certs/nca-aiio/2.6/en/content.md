# 2.6 Identify Facility Requirements

> **Exam weight: 4.0.** Expect scenario questions such as "a customer wants to deploy N DGX systems in an existing enterprise room. What must be validated first?" The answer almost always involves **power density per rack, cooling capacity and method, floor loading, and the cabling distances imposed by the network fabric**. The questions do not hinge on memorizing every spec. They test whether you recognize that AI infrastructure breaks the assumptions of a traditional data center.

---

## 1. Motivation: why AI breaks the traditional data center

A typical enterprise data center built between 2010 and 2020 was designed around:

- **5–10 kW per rack**, air-cooled, with a raised floor and CRAC/CRAH units pushing cold air.
- Racks filled to 42U with 1U/2U servers drawing 300–800 W each.
- Network traffic that is mostly north-south, with modest east-west bandwidth.
- Floor loading around 1,000–1,500 kg per rack.

A single NVIDIA DGX H100 draws **up to ~10.2 kW** in 8U. One system can consume the entire power budget of a legacy rack. A DGX B200 draws **~14.3 kW** in 10U. Rack-scale systems such as **GB200 NVL72** concentrate 72 Blackwell GPUs into a single NVLink domain. They are on the order of **120+ kW per rack** and are liquid-cooled by design. No amount of air handling can remove that heat from a 600 mm-wide footprint.

The architectural problem therefore runs in two directions:

1. **Facility constrains architecture.** If the room supports 15 kW/rack of air cooling, you can place exactly one DGX B200 per rack. That spreads the cluster horizontally, lengthens cable runs, and may force you from copper DACs to active optics. Optics add power, cost, and failure points.
2. **Architecture constrains facility.** If the workload needs a 72-GPU NVLink domain, the NVLink copper spine physically lives inside one rack. That forces the facility to deliver rack-level liquid cooling and very high power density. You cannot "spread it out."

The key takeaway: **facility requirements are a first-class design input, not an afterthought.** NVIDIA's DGX SuperPOD reference architectures specify racks, power, cooling, and cable layouts precisely because a deviation in any one of them invalidates the validated design.

---

## 2. The facility requirement dimensions

| Dimension | What you must validate | Typical failure if ignored |
|---|---|---|
| **Power capacity** | kW per rack, total IT load, feeds per rack, voltage/phase, breaker sizing | Breakers trip under training load; GPUs power-capped |
| **Power redundancy** | A/B feeds, PSU redundancy (N+N, N+1), UPS/generator coverage | Single feed loss takes down a node or a whole rack |
| **Cooling capacity** | kW of heat rejection per rack and per room, method (air/RDHx/DLC) | Thermal throttling, hot spots, hardware shutdown |
| **Environmental envelope** | Inlet temperature, humidity, dew point, air quality (particulates/gaseous contaminants) | Throttling, condensation in liquid loops, corrosion |
| **Space** | Rack U, rack depth (DGX systems are deep), aisle clearances, service access | Systems do not physically fit; doors don't close |
| **Structural** | Floor loading (static and rolling), raised-floor tile ratings, delivery path | Floor damage, unsafe installation, blocked delivery |
| **Network cabling** | Cable distances (DAC vs AOC vs transceivers), tray capacity, fiber count, bend radius | Fabric cannot be cabled as designed; signal integrity errors |
| **Management/OOB** | Separate management network, BMC access, console | No remote recovery during incidents |
| **Liquid infrastructure** (if DLC) | Facility water temperature, flow rate, CDUs, leak detection, water quality | Pump failures, leaks, insufficient heat rejection |

---

## 3. Power

### 3.1 Per-system power envelopes

Values are the maximum system power from the respective NVIDIA user guides and datasheets. Always confirm against the current documentation for the exact SKU.

| System | Form factor | Max system power | Weight (approx.) | Cooling |
|---|---|---|---|---|
| DGX A100 | 6U | ~6.5 kW | ~123 kg | Air |
| DGX H100 / H200 | 8U | ~10.2 kW | ~130 kg | Air |
| DGX B200 | 10U | ~14.3 kW | ~142 kg | Air |
| GB200 NVL72 (rack-scale) | Full rack | ~120+ kW per rack | Several tonnes per rack | Liquid (DLC) |

Several design details matter for facility planning:

- **DGX H100 power supplies.** The system ships with six hot-swappable power supplies (3.3 kW class) on **200–240 V AC** input. The PSUs are redundant: the system tolerates PSU loss without shutting down. Facility planning must still deliver the full system draw on **each side** of an A/B scheme if you want to survive a full feed loss.
- **GPU TDP versus system power.** An H100 SXM GPU is rated up to 700 W, so eight GPUs account for 5.6 kW. The remaining ~4.6 kW goes to CPUs, NVSwitch, NICs (ConnectX-7), DPUs, NVMe drives, memory, and **fans**. Fan power is non-trivial in air-cooled systems and grows as inlet temperature rises.
- **Training load is flat and sustained.** Unlike web workloads, a large training job drives every GPU near TDP for days. Oversubscribing power on the assumption of a "diversity factor" is dangerous for AI racks. Plan for nameplate.

### 3.2 The power chain

```
Utility ──► Switchgear ──► UPS (+ battery) ──► PDU / RPP ──► Rack PDU (A) ──► PSU 1,3,5
   │                                                    └──► Rack PDU (B) ──► PSU 2,4,6
   └──► Generator (ATS)
```

Each link has a capacity limit. A common mistake is to verify the rack PDU but forget that the upstream UPS or the room's distribution was sized for the old 8 kW/rack average.

### 3.3 Worked example: three-phase rack capacity

Three-phase apparent power:

```
S (kVA) = √3 × V_line-to-line × I / 1000
```

For a **415 V, 3-phase, 32 A** rack PDU:

```
S = 1.732 × 415 × 32 / 1000 ≈ 23.0 kVA
```

Apply the continuous-load derating. Many electrical codes, such as the NEC in North America, limit continuous load to 80% of the breaker rating; check your local code.

```
Usable ≈ 23.0 × 0.8 ≈ 18.4 kVA  (≈ 18 kW at PF ~0.98)
```

**Conclusion:** one 415 V/32 A three-phase feed supports exactly **one DGX B200** (14.3 kW), or one DGX H100 with headroom. With A/B redundancy, you need **two** such feeds, each able to carry the full load alone.

For **four DGX H100 per rack** (~41 kW), you need something like **415 V/63 A three-phase** per side:

```
1.732 × 415 × 63 / 1000 ≈ 45.3 kVA  →  × 0.8 ≈ 36.2 kVA
```

This is still **short** of 41 kW. You would need multiple PDUs per side, or 400 V/80 A+ circuits. This arithmetic is exactly why density decisions belong in facility planning.

### 3.4 Power redundancy trade-offs

| Scheme | Description | Pros | Cons |
|---|---|---|---|
| **N** (single feed) | One feed per rack | Cheapest | Any feed or PDU failure = outage |
| **N+1 PSU, single feed** | Redundant PSUs, one source | Survives PSU failure | Feed/PDU failure = outage |
| **2N (A/B feeds)** | Two independent feeds, each carries 100% | Survives full feed/UPS path loss | 2× distribution capacity, higher cost |
| **Distributed redundant (e.g., 3-to-make-2)** | Load spread across 3 UPS paths | Better utilization than 2N | Complex to design and operate |

For production AI clusters, a failure of one node can stall a synchronous training job across hundreds of GPUs, so **2N at the rack level** is the norm. Checkpoint frequency and job restart cost are part of the same reliability calculation.

---

## 4. Cooling

### 4.1 Physics: how much air does an air-cooled system need?

Approximate airflow required to remove a heat load (imperial rule of thumb):

```
CFM ≈ 3.16 × Watts / ΔT(°F)
```

For a DGX H100 at 10,200 W with a 20 °F (≈11 °C) inlet-to-exhaust rise:

```
CFM ≈ 3.16 × 10200 / 20 ≈ 1,612 CFM per system
```

Four systems per rack need **~6,400 CFM** delivered **to the front of a single rack**. Typical perforated raised-floor tiles deliver a few hundred to roughly 1,000 CFM each. This is why high-density air-cooled AI racks require:

- **Hot-aisle or cold-aisle containment.** Without it, exhaust recirculates and inlet temperatures climb.
- Blanking panels in every empty U.
- Sealed cable cutouts.
- Often **rear-door heat exchangers (RDHx)** or in-row cooling.

### 4.2 Cooling methods compared

| Method | Practical density per rack | How it works | Pros | Cons |
|---|---|---|---|---|
| **Room air (CRAC/CRAH, raised floor)** | ~5–15 kW | Cold air under floor, perforated tiles | Existing infrastructure, simple | Cannot handle modern DGX density beyond 1 system/rack |
| **Air + containment** | ~15–30 kW | Physically separate hot/cold aisles | Big efficiency gain, retrofit-friendly | Still airflow-limited |
| **In-row cooling** | ~20–40 kW | Coolers between racks, short air path | Targets hot spots | Uses rack positions |
| **Rear-door heat exchanger (RDHx)** | ~30–60+ kW (passive/active) | Water-cooled coil on rack rear door neutralizes exhaust | Servers stay air-cooled; room-neutral | Needs facility water to the rack |
| **Direct liquid cooling (DLC), cold plates** | 60–130+ kW | Coolant flows over GPU/CPU cold plates via CDU | Required for GB200 NVL72-class; high efficiency | Facility water loop, CDUs, leak detection, new ops skills |
| **Immersion** | 100+ kW | Servers submerged in dielectric fluid | Extreme density, no fans | Hardware must be qualified; maintenance complexity; not a standard DGX option |

**Exam heuristic:** air-cooled DGX (H100/B200) in a standard room means few systems per rack plus containment, often with RDHx. Rack-scale NVL72 means **liquid cooling is mandatory**.

### 4.3 Environmental envelope (ASHRAE)

ASHRAE TC 9.9 defines thermal classes for IT equipment. The DGX H100 user guide specifies an operating temperature of **5–30 °C**, which fits inside class A1/A2 allowable ranges.

| ASHRAE air class | Allowable inlet (dry bulb) | Typical use |
|---|---|---|
| Recommended (A1–A4) | 18–27 °C | Target for all classes |
| A1 | 15–32 °C | Enterprise, tightly controlled |
| A2 | 10–35 °C | Volume servers |
| A3 | 5–40 °C | Extended range |
| A4 | 5–45 °C | Extended range |

For liquid cooling, ASHRAE defines **W-classes** by facility water supply temperature, from W17 up through W45 and W+. A higher allowed water temperature lets the facility use more free cooling (dry coolers instead of chillers) and lowers PUE. Your CDU and IT vendor specify which class the equipment supports.

Two operational points to remember:

- **Running at the hot end of the allowable range is not free.** System fans spin faster, which increases system power and noise and reduces the margin before thermal throttling.
- **Humidity and dew point matter more with liquid cooling.** If the facility water supply temperature is below the room dew point, condensation forms on pipes and cold plates.

### 4.4 Efficiency metric: PUE

```
PUE = Total facility power / IT equipment power
```

For example, 1.5 MW total for 1.0 MW of IT load gives PUE = 1.5. Liquid cooling with warm-water heat rejection can push PUE toward ~1.1–1.2, because chillers and air handlers consume less. For AI facilities, PUE also determines how much of a fixed utility allocation is left for GPUs.

---

## 5. Space and structural requirements

### 5.1 Rack dimensions

DGX systems are **deep**. The DGX H100 is roughly 897 mm (35.3 in) long, before cables and bend radius. Plan for:

- **1,200 mm-deep racks** (often 600 mm or 800 mm wide; 800 mm helps with cable management at high port counts).
- Service clearance front and rear. Systems slide out for GPU tray, fan, and PSU replacement.
- Rack height and the delivery path. Check the doors, elevators, and loading dock for crated systems, and confirm the delivery path's floor rating.

### 5.2 Floor loading: worked example

A rack with **4× DGX H100**:

| Item | Weight |
|---|---|
| 4 × DGX H100 (~130 kg each) | ~520 kg |
| Empty rack (1,200 mm deep) | ~150 kg |
| Rack PDUs, cables, switches, blanking | ~80 kg |
| **Total** | **~750 kg** |

Footprint 0.6 m × 1.2 m = 0.72 m², so the distributed load is about **1,040 kg/m²**. That load is concentrated on four casters or leveling feet. Many raised-floor tiles and pedestals are rated below what a fully loaded AI rack imposes on a point load. Liquid-cooled rack-scale systems are significantly heavier still.

**Action:** obtain the structural rating of the floor (slab and raised floor). Consider load-spreading plates or slab-on-grade placement, and involve a structural engineer. This is a classic scenario question: "the room has power and cooling, what else?" The answer is floor loading.

---

## 6. Network and cabling as a facility requirement

The fabric topology in the NVIDIA reference architectures has direct physical consequences:

| Fabric element | Facility implication |
|---|---|
| **Compute fabric** (InfiniBand NDR/XDR or Spectrum-X Ethernet, rail-optimized) | Each DGX H100/B200 has 8 compute ports (one per GPU, via ConnectX-7 or equivalent). A 32-node scalable unit has 256 compute links to leaf switches. You need cable tray capacity, fiber counts, and short leaf placement. |
| **Copper DAC vs optics** | Passive copper at NDR speeds works only over a few meters. Longer runs need active cables or transceivers, which **consume power** (several watts to tens of watts per port) and generate heat at the switch. |
| **NVLink domain** | Within a DGX, NVLink/NVSwitch is internal. In GB200 NVL72, NVLink runs over a copper cable spine **inside the rack**. The domain size is fixed by rack physics, which is why the rack must hold 72 GPUs and therefore needs ~120 kW plus liquid cooling. |
| **Storage fabric** | Separate ports, often handled by BlueField DPUs, with their own leaf switches and cabling. |
| **In-band and OOB management** | Separate low-speed network for BMCs, PDUs, CDUs, and switches. Facility devices (smart PDUs, CDUs, leak sensors) must be reachable for monitoring. |

**BlueField DPU relevance.** NVIDIA positions BlueField DPUs to offload and isolate infrastructure functions (storage, networking, security) from the host CPU. From a facility perspective, the DPU is part of the system's power budget and adds cabling for the storage and in-band networks. It also enables isolated, secure management of multi-tenant infrastructure, which affects how the management network is laid out.

**Layout principle:** place switch racks to minimize cable length to the compute racks. This is why reference architectures define exact rack rows per scalable unit. Changing rack density changes cable lengths, which can force optics, which changes power. Everything is coupled.

---

## 7. Planning artifact: facility requirements specification

The following is a **planning document expressed as YAML**. It is not an NVIDIA file format. It is a practical way to keep facility requirements under version control and to let a script validate them (see §8.4).

```yaml
apiVersion: facility.planning/v1
kind: FacilityRequirements
metadata:
  name: ai-cluster-su1
  site: dc-east-hall-b
  owner: platform-infra
spec:
  deployment:
    systemModel: DGX-H100
    systemCount: 32
    systemsPerRack: 4
    computeRacks: 8
    networkRacks: 2
    managementRacks: 1
  perSystem:
    maxPowerKW: 10.2
    weightKg: 130.5
    rackUnits: 8
    depthMm: 897
    inletTempC:
      min: 5
      max: 30
    psu:
      count: 6
      inputVoltage: "200-240 VAC"
      redundancy: "N+N across A/B feeds"
  perRack:
    itLoadKW: 40.8
    overheadKW: 2.0
    designLoadKW: 42.8
    feeds:
      scheme: "2N"
      perSide:
        voltage: 415
        phases: 3
        breakerAmps: 80
        continuousDerating: 0.8
    cooling:
      method: "air-with-rdhx"
      containment: "hot-aisle"
      requiredAirflowCFM: 6500
      rdhxCapacityKW: 45
    structural:
      totalWeightKg: 750
      footprintM2: 0.72
      requiredFloorRatingKgPerM2: 1100
  room:
    totalItLoadKW: 380
    targetPUE: 1.3
    upsRuntimeMinutes: 10
    generatorBacked: true
    ashraeClass: "A2"
    humidity:
      minDewPointC: -9
      maxDewPointC: 15
      maxRelativeHumidityPercent: 60
  network:
    computeFabric: "InfiniBand NDR, rail-optimized"
    computeLinksPerSystem: 8
    maxPassiveCopperM: 3
    opticsBudgetWattsPerPort: 15
    oobNetwork: true
  monitoring:
    pduTelemetry: "SNMP/Redfish"
    bmcTelemetry: "Redfish"
    gpuTelemetry: "DCGM exporter"
    leakDetection: false
```

---

## 8. Verifying facility health from the infrastructure side

Facility problems surface as **GPU and system symptoms**: throttling, power capping, PSU alarms, fan overspeed. SREs should instrument these signals and correlate them with facility telemetry.

### 8.1 GPU-level checks with `nvidia-smi`

```
$ nvidia-smi --query-gpu=index,name,temperature.gpu,temperature.memory,power.draw,power.limit,clocks.sm,clocks.max.sm --format=csv
index, name, temperature.gpu, temperature.memory, power.draw [W], power.limit [W], clocks.current.sm [MHz], clocks.max.sm [MHz]
0, NVIDIA H100 80GB HBM3, 61, 70, 684.21 W, 700.00 W, 1980 MHz, 1980 MHz
1, NVIDIA H100 80GB HBM3, 63, 72, 691.55 W, 700.00 W, 1980 MHz, 1980 MHz
2, NVIDIA H100 80GB HBM3, 78, 89, 602.10 W, 700.00 W, 1665 MHz, 1980 MHz
3, NVIDIA H100 80GB HBM3, 62, 71, 688.03 W, 700.00 W, 1980 MHz, 1980 MHz
4, NVIDIA H100 80GB HBM3, 60, 69, 679.90 W, 700.00 W, 1980 MHz, 1980 MHz
5, NVIDIA H100 80GB HBM3, 62, 70, 686.47 W, 700.00 W, 1980 MHz, 1980 MHz
6, NVIDIA H100 80GB HBM3, 61, 70, 683.12 W, 700.00 W, 1980 MHz, 1980 MHz
7, NVIDIA H100 80GB HBM3, 63, 72, 690.88 W, 700.00 W, 1980 MHz, 1980 MHz
```

GPU 2 is hotter and running reduced clocks under the same load. Check why it is being slowed:

```
$ nvidia-smi -i 2 -q -d PERFORMANCE

==============NVSMI LOG==============

Attached GPUs                             : 8
GPU 00000000:3B:00.0
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

Interpretation:

- **SW Thermal Slowdown active** means the GPU is reducing clocks to stay within its thermal target. In an air-cooled system, the suspects are high inlet temperature, a failed or blocked fan, recirculation, or missing blanking panels.
- **HW Power Brake Slowdown** is asserted by an external signal, typically from the system when there is a power supply problem. Investigate PSUs and feeds.
- **SW Power Cap** means the GPU is at its configured power limit. Check whether someone lowered the limit with `nvidia-smi -pl`, often as a workaround for an under-provisioned rack.

### 8.2 DCGM diagnostics

```
$ dcgmi discovery -l
8 GPUs found.
+--------+----------------------------------------------------------------------+
| GPU ID | Device Information                                                   |
+--------+----------------------------------------------------------------------+
| 0      | Name: NVIDIA H100 80GB HBM3                                          |
|        | PCI Bus ID: 00000000:18:00.0                                         |
|        | Device UUID: GPU-6f2a0e4c-1b7d-4a1e-9c2f-0d8e3b7a5c11                |
+--------+----------------------------------------------------------------------+
...
```

Watch power, temperature, and violation counters live. Field IDs: 150 = GPU temp, 140 = memory temp, 155 = power usage, 240 = power violation, 241 = thermal violation.

```
$ dcgmi dmon -e 150,140,155,240,241 -d 1000
#Entity   GPUTMP  MMTMP  POWER    PVIOL    TVIOL
ID             C      C      W       us       us
GPU 0         61     70  684.21        0        0
GPU 1         63     72  691.55        0        0
GPU 2         78     89  602.10        0   912344
GPU 3         62     71  688.03        0        0
```

A thermal violation counter that keeps growing on GPU 2 confirms sustained thermal throttling.

### 8.3 Chassis level: BMC via IPMI and Redfish

```
$ sudo ipmitool dcmi power reading

    Instantaneous power reading:                  9874 Watts
    Minimum during sampling period:               2140 Watts
    Maximum during sampling period:              10112 Watts
    Average power reading over sample period:     9530 Watts
    IPMI timestamp:                           Sat Nov 14 10:22:31 2026
    Sampling period:                          00000005 Seconds.
    Power reading state is:                   activated
```

```
$ sudo ipmitool sdr type "Power Supply"
PSU0_Status      | 80h | ok  | 10.1 | Presence detected
PSU1_Status      | 81h | ok  | 10.2 | Presence detected
PSU2_Status      | 82h | ok  | 10.3 | Presence detected
PSU3_Status      | 83h | ok  | 10.4 | Presence detected, Power Supply AC lost
PSU4_Status      | 84h | ok  | 10.5 | Presence detected
PSU5_Status      | 85h | ok  | 10.6 | Presence detected
```

`AC lost` on a PSU usually means a tripped breaker, an unplugged cord, or a dead rack PDU outlet. The system keeps running on the remaining PSUs, but redundancy is gone. Treat it as a facility incident, not just a hardware ticket.

The sensor names and IDs above are representative. Exact labels vary by BMC firmware.

Redfish provides structured access. The chassis ID varies by platform; discover it first:

```
$ curl -sk -u admin:"$BMC_PASS" https://10.0.10.21/redfish/v1/Chassis | jq '.Members'
[
  {
    "@odata.id": "/redfish/v1/Chassis/DGX"
  }
]
```

```
$ curl -sk -u admin:"$BMC_PASS" https://10.0.10.21/redfish/v1/Chassis/DGX/Thermal \
    | jq '.Temperatures[] | select(.Name | test("Inlet")) | {Name, ReadingCelsius, UpperThresholdCritical}'
{
  "Name": "TEMP_INLET",
  "ReadingCelsius": 31,
  "UpperThresholdCritical": 35
}
```

An inlet of 31 °C exceeds the DGX H100 operating range of 5–30 °C. **This is a facility problem**: containment, CRAH capacity, or RDHx water supply. It is not a GPU defect. Newer Redfish schemas expose the same data under `ThermalSubsystem` and `PowerSubsystem`. Use whichever your BMC firmware implements.

### 8.4 Quick validator for the planning spec

The script below checks per-rack power against feed capacity, and floor loading against the required rating, from the YAML in §7. Run it from its own directory and pass the spec path as an argument.

```python
#!/usr/bin/env python3
import math
import sys

import yaml

spec = yaml.safe_load(open(sys.argv[1]))["spec"]
rack = spec["perRack"]
feed = rack["feeds"]["perSide"]

capacity_kva = math.sqrt(3) * feed["voltage"] * feed["breakerAmps"] / 1000
usable_kw = capacity_kva * feed["continuousDerating"]
load_kw = rack["designLoadKW"]

print(f"Per-side usable capacity: {usable_kw:.1f} kW, design load: {load_kw:.1f} kW")
if load_kw > usable_kw:
    print("FAIL: a single feed cannot carry the full rack load (2N violated)")
    sys.exit(1)

kg_per_m2 = rack["structural"]["totalWeightKg"] / rack["structural"]["footprintM2"]
print(f"Floor loading: {kg_per_m2:.0f} kg/m2 (required rating {rack['structural']['requiredFloorRatingKgPerM2']})")
if kg_per_m2 > rack["structural"]["requiredFloorRatingKgPerM2"]:
    print("FAIL: floor rating insufficient")
    sys.exit(1)
print("PASS")
```

```
$ python3 -I validate_facility.py ai-cluster-su1.yaml
Per-side usable capacity: 46.0 kW, design load: 42.8 kW
Floor loading: 1042 kg/m2 (required rating 1100)
PASS
```

---

## 9. Continuous monitoring in Kubernetes: DCGM exporter and alerting

Facility drift, such as a CRAH failure or a summer heat wave, shows up gradually. The following manifests configure the NVIDIA DCGM exporter to export the thermal and power fields, and define Prometheus Operator alerts for them.

### 9.1 DCGM exporter metrics configuration

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: dcgm-exporter-facility-metrics
  namespace: gpu-operator
data:
  facility-counters.csv: |
    # Format: DCGM field, Prometheus metric type, help message
    DCGM_FI_DEV_GPU_TEMP, gauge, GPU temperature (in C).
    DCGM_FI_DEV_MEMORY_TEMP, gauge, Memory temperature (in C).
    DCGM_FI_DEV_POWER_USAGE, gauge, Power draw (in W).
    DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION, counter, Total energy consumption since boot (in mJ).
    DCGM_FI_DEV_POWER_VIOLATION, counter, Throttling duration due to power constraints (in us).
    DCGM_FI_DEV_THERMAL_VIOLATION, counter, Throttling duration due to thermal constraints (in us).
    DCGM_FI_DEV_SM_CLOCK, gauge, SM clock frequency (in MHz).
    DCGM_FI_DEV_GPU_UTIL, gauge, GPU utilization (in %).
    DCGM_FI_DEV_XID_ERRORS, gauge, Value of the last XID error encountered.
```

Point the GPU Operator at it through the `ClusterPolicy`. This is an excerpt of the relevant section; the other fields of your existing ClusterPolicy remain unchanged.

```yaml
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: cluster-policy
spec:
  dcgmExporter:
    enabled: true
    config:
      name: dcgm-exporter-facility-metrics
    env:
      - name: DCGM_EXPORTER_COLLECTORS
        value: "/etc/dcgm-exporter/facility-counters.csv"
    serviceMonitor:
      enabled: true
      interval: 15s
```

### 9.2 Alert rules for facility-related symptoms

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gpu-facility-alerts
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: gpu-facility.rules
      interval: 30s
      rules:
        - record: node:gpu_power_watts:sum
          expr: sum by (Hostname) (DCGM_FI_DEV_POWER_USAGE)
        - alert: GPUThermalThrottlingSustained
          expr: |
            rate(DCGM_FI_DEV_THERMAL_VIOLATION[5m]) / 1e6 > 0.1
          for: 10m
          labels:
            severity: warning
            domain: facility
          annotations:
            summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} is thermally throttling"
            description: "Throttled more than 10% of the time for 10m. Check rack inlet temperature, containment and fans before replacing hardware."
        - alert: GPUPowerThrottlingSustained
          expr: |
            rate(DCGM_FI_DEV_POWER_VIOLATION[5m]) / 1e6 > 0.1
          for: 10m
          labels:
            severity: warning
            domain: facility
          annotations:
            summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} is power throttling"
            description: "Check configured power limits (nvidia-smi -pl), PSU status and rack feed capacity."
        - alert: GPUTemperatureHigh
          expr: |
            DCGM_FI_DEV_GPU_TEMP > 85
          for: 5m
          labels:
            severity: critical
            domain: facility
          annotations:
            summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} above 85C"
            description: "Sustained high GPU temperature indicates cooling insufficiency at node or rack level."
        - alert: GPUTemperatureOutlierInNode
          expr: |
            DCGM_FI_DEV_GPU_TEMP
              - on (Hostname) group_left
            avg by (Hostname) (DCGM_FI_DEV_GPU_TEMP)
              > 12
          for: 15m
          labels:
            severity: warning
            domain: facility
          annotations:
            summary: "GPU {{ $labels.gpu }} runs much hotter than its peers on {{ $labels.Hostname }}"
            description: "A single hot GPU suggests a local airflow problem (blocked path, failed fan) rather than a room-level issue."
        - alert: NodeGPUPowerNearRackBudget
          expr: |
            node:gpu_power_watts:sum > 5400
          for: 30m
          labels:
            severity: info
            domain: facility
          annotations:
            summary: "{{ $labels.Hostname }} GPU power above 5.4 kW for 30m"
            description: "Sustained near-TDP draw on all 8 GPUs. Validate that rack feeds have headroom for the full system envelope."
```

Apply and verify:

```
$ kubectl apply -f dcgm-exporter-facility-metrics.yaml -f gpu-facility-alerts.yaml
configmap/dcgm-exporter-facility-metrics created
prometheusrule.monitoring.coreos.com/gpu-facility-alerts created

$ kubectl -n gpu-operator get pods -l app=nvidia-dcgm-exporter
NAME                         READY   STATUS    RESTARTS   AGE
nvidia-dcgm-exporter-4kq8n   1/1     Running   0          3m
nvidia-dcgm-exporter-9wz2t   1/1     Running   0          3m

$ kubectl -n gpu-operator port-forward ds/nvidia-dcgm-exporter 9400:9400 &
$ curl -s localhost:9400/metrics | grep -E '^DCGM_FI_DEV_(GPU_TEMP|THERMAL_VIOLATION)' | head -4
DCGM_FI_DEV_GPU_TEMP{gpu="0",UUID="GPU-6f2a0e4c-...",device="nvidia0",modelName="NVIDIA H100 80GB HBM3",Hostname="dgx-su1-r03-n2"} 61
DCGM_FI_DEV_GPU_TEMP{gpu="1",UUID="GPU-91c3d2aa-...",device="nvidia1",modelName="NVIDIA H100 80GB HBM3",Hostname="dgx-su1-r03-n2"} 63
DCGM_FI_DEV_THERMAL_VIOLATION{gpu="0",UUID="GPU-6f2a0e4c-...",device="nvidia0",modelName="NVIDIA H100 80GB HBM3",Hostname="dgx-su1-r03-n2"} 0
DCGM_FI_DEV_THERMAL_VIOLATION{gpu="1",UUID="GPU-91c3d2aa-...",device="nvidia1",modelName="NVIDIA H100 80GB HBM3",Hostname="dgx-su1-r03-n2"} 0
```

**Correlation strategy:** if many nodes in the **same rack row** alert at once, suspect room or containment problems such as CRAH failure, a closed damper, or RDHx water supply. A single GPU alerting points to a node-local cause. Many nodes on **the same PDU** alerting on power points to an electrical cause.

---

## 10. Failure diagnosis guide

| Symptom | Likely facility cause | How to confirm | Remediation |
|---|---|---|---|
| All GPUs in a rack throttle in the afternoon | Inlet air too warm, insufficient cooling capacity | Redfish inlet temp > 30 °C; `SW Thermal Slowdown` active | Fix containment, add RDHx/in-row cooling, reduce rack density |
| One GPU much hotter than peers | Local airflow blockage, failed fan, missing blanking panel | `dcgmi dmon` per-GPU temp; BMC fan sensors | Replace fan, install blanking panels, clear cable obstruction |
| PSU `AC lost` alarm, system still running | Tripped breaker, failed PDU outlet, unplugged cord | `ipmitool sdr type "Power Supply"`; PDU outlet telemetry | Restore feed; audit A/B cord mapping |
| Rack breaker trips when a training job starts | Feed undersized for sustained full-load draw | PDU current log vs breaker rating × 0.8 | Re-provision circuits; temporarily cap power with `nvidia-smi -pl` (a workaround, not a fix) |
| Both PSUs on side A fail together and the system goes down | All PSUs cabled to one feed (A/B miswire) | Physical cord audit, PDU outlet mapping | Re-cable PSUs alternately to A and B |
| `HW Power Brake Slowdown` active | System-level power event (PSU failure or insufficient input) | `nvidia-smi -q -d PERFORMANCE`; BMC SEL log | Restore PSU redundancy; check input voltage |
| Condensation near liquid manifolds | Supply water temperature below room dew point | Room humidity sensors vs CDU supply temperature | Raise supply setpoint; control humidity |
| Intermittent link errors on fabric | Cable length beyond spec, bend radius violation, overheated transceivers | `ibdiagnet`, port symbol error counters, transceiver temperatures | Re-route cables, replace with active optics, improve switch rack cooling |
| Systems do not fit or doors won't close | Rack too shallow for DGX depth plus cables | Physical measurement | Use 1,200 mm-deep racks |
| Floor tiles deflect under racks | Point load exceeds raised-floor rating | Structural assessment | Load-spreading plates, reinforced pedestals, slab placement |

---

## 11. Exam-oriented summary

- **Density is the core issue.** One DGX H100 (~10.2 kW) or DGX B200 (~14.3 kW) can exceed a legacy rack's entire budget. Rack-scale GB200 NVL72 is ~120+ kW per rack.
- **Power:** validate kW per rack, **2N A/B feeds** with each side able to carry full load, three-phase circuit sizing with continuous-load derating, and the upstream UPS and distribution, not just the rack PDU.
- **Cooling:** air with containment for moderate density, **RDHx** for high-density air-cooled racks, **direct liquid cooling** for rack-scale NVLink systems. Respect the operating inlet range (DGX H100: 5–30 °C) and the ASHRAE recommended range of 18–27 °C.
- **Structural:** DGX systems are deep and heavy, so check rack depth (1,200 mm), floor loading, and the delivery path.
- **Network:** rail-optimized fabrics mean many cables per node. Copper reach is short, so leaf switch placement and optics power are part of facility design. The NVLink domain size in NVL72 is bound to the rack.
- **Operations:** facility problems appear as GPU throttling and PSU alarms. Instrument DCGM (thermal and power violation counters), BMC/Redfish (inlet temperature, PSU state), and PDU telemetry, and correlate them by rack and feed.
- **Follow the reference architecture.** DGX SuperPOD RAs specify rack layout, power, cooling, and cabling as a validated whole. Deviating from one dimension affects all the others.

---

## Referencias

- NVIDIA DGX H100 User Guide, Introduction and Component Descriptions: https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
- NVIDIA DGX SuperPOD Reference Architecture with DGX B200: https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
- NVIDIA NCA-AIIO exam guide (PDF): https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy, AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA NVLink and NVLink Switch: https://www.nvidia.com/en-us/data-center/nvlink/
- NVIDIA Technical Blog, Offloading and Isolating Data Center Workloads with BlueField DPU: https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
- NVIDIA Technical Blog, Accelerating IO in the Modern Data Center: Network IO: https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
- NVIDIA DCGM documentation (field identifiers, `dcgmi`): https://docs.nvidia.com/datacenter/dcgm/latest/
- NVIDIA DCGM Exporter: https://github.com/NVIDIA/dcgm-exporter
- NVIDIA System Management Interface (`nvidia-smi`): https://docs.nvidia.com/deploy/nvidia-smi/index.html
- DMTF Redfish specification: https://www.dmtf.org/standards/redfish
- ASHRAE TC 9.9, Data Center Thermal Guidelines: https://tc0909.ashraetcs.org/