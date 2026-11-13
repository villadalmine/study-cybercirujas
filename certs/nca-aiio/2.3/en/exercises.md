# Guided Exercises — Topic 2.3: Power and Cooling Requirements in an AI Data Center

**Certification:** NCA-AIIO · **Exam weight:** 4.0

**What this topic tests:** You should be able to reason about how much power an AI system draws, how that power turns into heat, how that heat gets removed, and how the facility delivers power and cooling redundantly. The exam stays at a high level: kW per system and per rack, PUE, air versus liquid cooling, redundancy, and telemetry. Production work needs the arithmetic underneath, and these exercises build it.

**Official references used throughout:**

- NVIDIA DGX H100 User Guide, component descriptions: https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
- NVIDIA DGX SuperPOD Reference Architecture (DGX B200): https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
- NVIDIA NVLink: https://www.nvidia.com/en-us/data-center/nvlink/
- BlueField DPU offload: https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
- Network I/O in the modern data center: https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
- NVIDIA AI Infrastructure and Operations Fundamentals course: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NCA-AIIO exam study guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf

**Lab requirements:**

- Exercises 1–4 and 6 need only a calculator or `python3`.
- Exercise 5 needs a node with an NVIDIA GPU and the driver installed. DCGM and a BMC with IPMI are optional. If you have no GPU, work from the sample outputs shown.

> **Spec values:** Vendor figures are quoted from the documents above. Always check them against the current datasheet for your exact SKU, because they change between hardware revisions.

---

## Exercise 1 — From GPU TDP to system power to rack density

**Background.** A DGX H100 contains:

- 8× H100 SXM5 GPUs, each with a configurable TDP of up to **700 W**.
- 2× Intel Xeon CPUs.
- 4× NVSwitch chips.
- 8× ConnectX-7 single-port NICs and 2× dual-port ConnectX-7 / BlueField-3.
- NVMe storage, fans, and **six power supplies**.

The DGX H100 User Guide lists the **maximum system power as ~10.2 kW**. The DGX B200 increases this to about **14.3 kW max**, and its GPUs run at up to ~1,000 W each.

**Steps**

1. Calculate the power the GPUs alone draw at full TDP:
   ```
   8 × 700 W = ? W
   ```
2. Calculate the share of the 10.2 kW system maximum that the GPUs represent.
3. Calculate the non-GPU power. List which components from the background account for it.
4. A traditional enterprise rack is typically provisioned for **8–15 kW**. Calculate how many DGX H100 systems fit in a 15 kW rack and in a 40 kW rack.
5. Repeat step 4 for DGX B200 at 14.3 kW.

**Questions**

- **1.1** Why do capacity planners use the **maximum** system power (10.2 kW) rather than the typical training draw?
- **1.2** Your colocation contract gives you 12 kW per rack. You must deploy 4× DGX H100. How many racks do you need? What happens to the floor space, and to the cable lengths between nodes?
- **1.3** The GPU share of system power is large but not 100%. Name two non-GPU components whose power grows when you add more network bandwidth per node.

---

## Exercise 2 — Power becomes heat: BTU/hr, tons, and airflow

**Background.** Almost every watt delivered to IT equipment leaves the equipment as heat. The facility must remove all of it. These are the conversions you need:

| Quantity | Conversion |
|---|---|
| Heat | `1 W = 3.412 BTU/hr` |
| Cooling capacity | `1 ton of refrigeration = 12,000 BTU/hr ≈ 3.517 kW` |
| Required airflow (sea level, sensible heat) | `CFM ≈ 3.16 × Watts / ΔT(°F)` |

In the airflow formula, ΔT is the temperature rise from server inlet to server exhaust.

**Steps**

1. Convert the maximum power of one DGX H100 (10,200 W) to BTU/hr.
2. Convert the result from step 1 to tons of cooling.
3. Assume a 20 °C (36 °F) rise from inlet to exhaust. Calculate the airflow that one DGX H100 needs at full power.
4. Run the same airflow calculation in Python. This lets you reuse it later:
   ```python
   watts = 10_200
   delta_t_c = 20
   delta_t_f = delta_t_c * 9 / 5
   cfm = 3.16 * watts / delta_t_f
   print(f"BTU/hr: {watts * 3.412:,.0f}")
   print(f"Tons:   {watts / 3517:.2f}")
   print(f"CFM:    {cfm:,.0f}")
   ```
   Expected output:
   ```
   BTU/hr: 34,802
   Tons:   2.90
   CFM:    895
   ```
5. Change `delta_t_c` to `10` and run the script again. Write down the new CFM value.

**Questions**

- **2.1** Halving the inlet-to-exhaust ΔT has what effect on required airflow? Why does poor hot-aisle/cold-aisle containment, which lets exhaust air recirculate, effectively reduce your usable ΔT?
- **2.2** ASHRAE's recommended envelope for server inlet air is roughly 18–27 °C. The DGX H100 is specified for an operating ambient of roughly 5–30 °C. Why does the "recommended" range matter more than the "allowable" range in a production AI hall?
- **2.3** A room has 50 tons of CRAH capacity. If only cooling is considered, how many DGX H100 systems can it support at max power? Why should you **not** plan to that number in practice?

---

## Exercise 3 — Why high-density racks go to liquid

**Background.** A rack-scale system such as GB200 NVL72 draws power on the order of **~120 kW per rack** and is designed for direct liquid cooling (DLC). The heat-transfer equation is the same for any fluid:

```
Q = ṁ × cp × ΔT
```

The two fluids compare as follows:

| Fluid | cp | Density |
|---|---|---|
| Air | ≈ 1.005 kJ/(kg·K) | ≈ 1.2 kg/m³ |
| Water | ≈ 4.186 kJ/(kg·K) | ≈ 1 kg/L |

**Steps**

1. Calculate the air mass flow needed to remove 120 kW with ΔT = 20 K. Then convert it to volumetric flow:
   ```python
   q_kw = 120
   air_mdot = q_kw / (1.005 * 20)          # kg/s
   air_m3s = air_mdot / 1.2                 # m^3/s
   print(f"Air: {air_mdot:.2f} kg/s = {air_m3s:.2f} m3/s = {air_m3s * 2118.88:,.0f} CFM")

   water_mdot = q_kw / (4.186 * 10)         # kg/s, ΔT = 10 K
   print(f"Water: {water_mdot:.2f} kg/s ≈ {water_mdot * 60:.0f} L/min")
   ```
   Expected output:
   ```
   Air: 5.97 kg/s = 4.98 m3/s = 10,541 CFM
   Water: 2.87 kg/s ≈ 172 L/min
   ```
2. Compare the two results. About 10,500 CFM of air must pass through a single 600 mm-wide rack. The same heat can be carried by a water flow that a pipe a few centimeters in diameter can handle.
3. Sketch the heat path for a DLC rack:
   ```
   GPU/CPU cold plates → rack manifold → CDU (Coolant Distribution Unit, liquid-to-liquid HX)
     → facility water loop → cooling tower / dry cooler / chiller → atmosphere
   ```
4. Label which loop is the **TCS** (Technology Cooling System, secondary) and which is the **FWS** (Facility Water System, primary).

**Questions**

- **3.1** Water's cp is about 4× that of air, and its density is about 830× higher. Which of those two properties explains most of the gap you computed?
- **3.2** In a DLC rack, not 100% of the heat goes into the liquid. Where does the remainder go? Name the cooling equipment that must still exist in the room.
- **3.3** What is a **rear-door heat exchanger (RDHx)**? Where does it sit between pure air cooling and direct-to-chip liquid cooling?
- **3.4** Why do operators prefer a CDU over running facility water directly into server cold plates? Consider water quality, pressure, and leak containment.

---

## Exercise 4 — Electrical delivery and redundancy (A/B feeds)

**Background.**

- Three-phase power is calculated as `P = √3 × V(line-to-line) × I × PF`.
- Single-phase power is calculated as `P = V × I × PF`.
- Breakers and PDUs are commonly derated to **80%** for continuous load. Use 80% here.
- In a **2N** design, every rack has an A feed and a B feed from independent UPS/utility paths. **Either side alone must carry the full rack load.**
- DGX systems use multiple PSUs split across both feeds for this reason. See the DGX H100 User Guide for the PSU count and redundancy scheme.

**Steps**

1. Calculate the capacity of a 3-phase 415 V / 32 A PDU with PF 0.95. Then calculate its usable capacity at 80% derate.
2. Calculate the capacity of a single-phase 230 V / 32 A PDU with PF 1.0. Apply the 80% derate.
3. A rack holds 2× DGX H100 at a maximum of 20.4 kW. In 2N, each side gets **one** PDU from step 1. Determine whether the design passes.
4. Change the design to two PDUs per side and repeat the check.
5. Draw the power path from utility to GPU and label each point of conversion loss:
   ```
   Utility → transformer → switchgear → UPS (AC→DC→AC) → PDU → server PSU (AC→DC) → VRMs → GPU
   ```

**Questions**

- **4.1** Why does 2N force you to size **each** side for 100% of the load and not 50%? What happens at the moment one side fails if you sized each side for 50%?
- **4.2** N+1 and 2N are both redundancy schemes. Which one survives a full UPS-path maintenance window without risk?
- **4.3** Every conversion stage in step 5 wastes some power as heat. In which metric (see Exercise 6) do those losses show up?

---

## Exercise 5 — Observing power and thermals on a real GPU node

> Needs an NVIDIA GPU node. Without one, read the sample outputs and answer the questions.

**Steps**

1. Run a per-GPU power and thermal snapshot:
   ```bash
   nvidia-smi --query-gpu=index,name,power.draw,power.limit,temperature.gpu,temperature.memory \
     --format=csv
   ```
   Sample output on an idle DGX H100 (abbreviated):
   ```
   index, name, power.draw [W], power.limit [W], temperature.gpu, temperature.memory
   0, NVIDIA H100 80GB HBM3, 71.42 W, 700.00 W, 31, 38
   1, NVIDIA H100 80GB HBM3, 69.87 W, 700.00 W, 30, 37
   ```
2. Show the detailed power section:
   ```bash
   nvidia-smi -q -d POWER -i 0
   ```
   Look for these fields:
   - `Current Power Limit`
   - `Default Power Limit`
   - `Min Power Limit`
   - `Max Power Limit`
3. Check the clock event (throttle) reasons. Run this while a workload is active:
   ```bash
   nvidia-smi -q -d PERFORMANCE -i 0
   ```
   Sample output (abbreviated):
   ```
   Clocks Event Reasons
       Idle                              : Not Active
       Applications Clocks Setting       : Not Active
       SW Power Cap                      : Active
       HW Slowdown                       : Not Active
           HW Thermal Slowdown           : Not Active
           HW Power Brake Slowdown       : Not Active
       Sync Boost                        : Not Active
       SW Thermal Slowdown               : Not Active
   ```
4. Optional: if DCGM is installed, stream these fields every second:
   - field `155`: power usage
   - field `150`: GPU temperature
   - field `140`: memory temperature

   ```bash
   dcgmi dmon -e 155,150,140 -d 1000
   ```
5. Optional, in a lab only: lower the power limit of GPU 0 and observe the effect. Run `nvidia-smi -q -d POWER -i 0` first to get the valid limit range, then:
   ```bash
   sudo nvidia-smi -i 0 -pl 500
   nvidia-smi --query-gpu=index,power.limit --format=csv
   ```
   Restore the original limit when you are done:
   ```bash
   sudo nvidia-smi -i 0 -pl 700
   ```
6. Optional: read whole-chassis power from the BMC:
   ```bash
   sudo ipmitool dcmi power reading
   ```
   Sample output:
   ```
       Instantaneous power reading:                  6480 Watts
       Minimum during sampling period:                 1890 Watts
       Maximum during sampling period:                 9870 Watts
       Average power reading over sample period:       6120 Watts
   ```

**Questions**

- **5.1** In step 3, `SW Power Cap: Active` is shown under load. What does that tell you? Is it a facility problem, a configuration choice, or both?
- **5.2** `HW Thermal Slowdown: Active` is a different signal from `SW Power Cap`. Which facility-side causes would you investigate first?
- **5.3** Why can the sum of `power.draw` for 8 GPUs never equal the BMC chassis reading?
- **5.4** Give one legitimate operational reason to lower `-pl` across a fleet. Give the trade-off as well.

---

## Exercise 6 — Facility efficiency (PUE) and a rack planner script

**Background.**

- **PUE** = Total facility energy ÷ IT equipment energy. The ideal value is 1.0.
- **DCiE** = 1 ÷ PUE, expressed as a percentage.

**Steps**

1. A hall draws 1.5 MW total, and its IT load is 1.2 MW.
   - Calculate PUE and DCiE.
   - Calculate how much power goes to non-IT overhead.
2. Create a rack plan file named `rack-plan.json`:
   ```json
   {
     "feed": {
       "volts_ll": 415,
       "amps": 32,
       "power_factor": 0.95,
       "continuous_derate": 0.8,
       "pdus_per_side": 2
     },
     "equipment": [
       {"name": "dgx-h100", "count": 2, "max_w": 10200},
       {"name": "leaf-switch", "count": 1, "max_w": 1700},
       {"name": "mgmt-switch", "count": 1, "max_w": 200}
     ]
   }
   ```
   The switch wattages are illustrative. Use the datasheet values for your models.
3. Create the planner script, `rack_planner.py`:
   ```python
   #!/usr/bin/env python3
   """Rack power and cooling planner (2N, three-phase)."""
   import json
   import math
   import sys

   BTU_PER_W = 3.412
   W_PER_TON = 3517.0


   def three_phase_w(volts_ll, amps, pf):
       return math.sqrt(3) * volts_ll * amps * pf


   def main(path):
       with open(path) as f:
           plan = json.load(f)

       feed = plan["feed"]
       per_pdu = three_phase_w(feed["volts_ll"], feed["amps"], feed["power_factor"])
       usable_w = per_pdu * feed["continuous_derate"] * feed["pdus_per_side"]
       print(f"Usable capacity per side (A or B): {usable_w / 1000:.1f} kW")

       total = 0.0
       for item in plan["equipment"]:
           load = item["max_w"] * item["count"]
           total += load
           print(f"  {item['name']:<14}{item['count']:>2} x {item['max_w']:>6} W = {load / 1000:6.1f} kW")

       print(f"Rack max load: {total / 1000:.1f} kW")
       print(f"Heat to remove: {total * BTU_PER_W:,.0f} BTU/hr = {total / W_PER_TON:.1f} tons")
       ok = total <= usable_w
       print(f"2N check (one side carries everything): {'OK' if ok else 'OVER BUDGET'}")
       sys.exit(0 if ok else 1)


   if __name__ == "__main__":
       main(sys.argv[1])
   ```
4. Run the script:
   ```bash
   python3 rack_planner.py rack-plan.json; echo "exit=$?"
   ```
   Expected output:
   ```
   Usable capacity per side (A or B): 35.0 kW
     dgx-h100       2 x  10200 W =   20.4 kW
     leaf-switch    1 x   1700 W =    1.7 kW
     mgmt-switch    1 x    200 W =    0.2 kW
   Rack max load: 22.3 kW
   Heat to remove: 76,088 BTU/hr = 6.3 tons
   2N check (one side carries everything): OK
   exit=0
   ```
5. Change the `dgx-h100` `count` to `4` and run the script again. Record the new rack load and the result of the 2N check.
6. Change the `dgx-h100` entry to `"max_w": 14300` (DGX B200) with `"count": 2`. Run the script again.

**Questions**

- **6.1** Moving from air to liquid cooling often lowers PUE. Which facility components consume less energy as a result?
- **6.2** PUE does not measure how efficiently the IT equipment does useful work. Give an example where PUE improves while energy per training job gets worse.
- **6.3** In step 5, what are your two options to make the rack pass? Which one also affects the cooling design?

---

## Exercise 7 — Work per watt: NVLink and DPU offload

**Background.**

- **NVLink and NVSwitch** give GPU-to-GPU bandwidth far beyond PCIe. Collective operations finish faster, and GPUs spend less time idling while still drawing power.
- **BlueField DPUs** offload networking, storage, and security data-path work (for example, OVS, encryption, and NVMe-oF) from host CPU cores to dedicated hardware on the DPU.

**Steps**

1. Job A runs on a cluster drawing 400 kW and takes 10 h. Calculate the energy it uses in MWh.
2. With a faster interconnect, the same job draws 440 kW, because the GPUs are better utilized, and takes 7 h. Calculate the energy.
3. Compare the two results, then fill in the sentence: *"Higher instantaneous power can mean ______ total energy if ______."*
4. A host spends 8 of its 64 CPU cores on packet processing and encryption. List which of those functions could move to a BlueField DPU. State what the freed cores could be used for, or whether the host could be specified with a smaller CPU.

**Questions**

- **7.1** Why does the exam (and NVIDIA's positioning) emphasize **energy per job** or **performance per watt** rather than peak watts?
- **7.2** DPU offload moves some power from the host CPU to the DPU. Under what condition is the net effect still a facility win?
- **7.3** Why does a high-bandwidth scale-up domain (NVLink within a rack) push rack power density *up*? What does that imply for cooling choice?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**Step results**

- Step 1: GPU power is 8 × 700 W = **5,600 W**.
- Step 2: 5.6 / 10.2 ≈ **55%** of system max.
- Step 3: About **4.6 kW** is non-GPU power. It goes to:
  - CPUs
  - NVSwitches
  - NICs/DPUs
  - memory and NVMe
  - fans, which are significant in an air-cooled chassis
  - PSU conversion losses
- Step 4: DGX H100 at 10.2 kW:
  - 15 kW rack → **1 system** (2 would need 20.4 kW).
  - 40 kW rack → **3 systems** (30.6 kW; 4 would need 40.8 kW).
- Step 5: DGX B200 at 14.3 kW:
  - 15 kW rack → **1 system**.
  - 40 kW rack → **2 systems** (28.6 kW; 3 would need 42.9 kW).

**Questions**

- **1.1** Breakers, PDUs, UPS, and cooling must survive the worst case. Training loads are synchronized across GPUs, so all nodes can peak at the same time. If you size for typical draw, you risk tripped breakers or thermal throttling exactly when the cluster is busiest.
- **1.2** 12 kW per rack allows one DGX H100 per rack, so you need **4 racks**. You use more floor space, leave racks mostly empty, and need longer cable runs. Longer runs matter for high-speed links: they may force optics instead of copper DACs, which adds cost and power.
- **1.3** NICs/DPUs (ConnectX-7 and BlueField-3) and their optical transceivers. On the switch side, network switches and their optics also grow with bandwidth.

### Exercise 2

**Step results**

- Step 1: **≈34,802 BTU/hr**.
- Step 2: **≈2.90 tons**.
- Step 3: **≈895 CFM**.
- Step 5: With a 10 °C (18 °F) rise, airflow is **≈1,791 CFM**.

**Questions**

- **2.1** Airflow is inversely proportional to ΔT, so halving ΔT **doubles** the required airflow. When hot exhaust recirculates into the cold aisle, server inlet temperature rises. Servers then either ramp their fans, which moves more air at a lower ΔT, or throttle. Containment preserves the designed ΔT.
- **2.2** The "allowable" range is what hardware tolerates. The "recommended" range is where reliability, fan power, and GPU clock behavior stay optimal. Running at the edge of allowable raises fan power and the risk of thermal slowdowns, and reliability suffers.
- **2.3** 50 tons × 3.517 kW ≈ 175.9 kW, which is **17 systems** at 10.2 kW. In practice you do not plan to that number because you need:
  - redundancy (N+1 CRAHs)
  - headroom for the other equipment in the room: switches, storage, and the lighting and electrical losses within the room
  - margin for uneven air distribution, because hot spots appear before average capacity runs out
  - margin for future growth

### Exercise 3

**Step results**

- Step 1: Air needs **≈10,541 CFM**. Water needs **≈172 L/min**.
- Step 4: The **TCS** is the secondary loop: cold plates → manifold → CDU. The **FWS** is the primary loop: CDU → facility plant → heat rejection.

**Questions**

- **3.1** Mostly **density**. Per unit of *mass*, water carries ~4× more heat than air. Per unit of *volume*, it carries ~3,500× more. Volumetric flow is what you must push through a rack, so density dominates.
- **3.2** Components not on cold plates still reject heat to air. These include PSUs, some NICs, memory, and storage. The room still needs air cooling (CRAH/CRAC units, in-row coolers, or RDHx) for that residual heat, and for adjacent air-cooled gear such as storage and management switches.
- **3.3** An RDHx is a coil mounted on the rack's rear door. Server exhaust air passes through it and is cooled by liquid before it re-enters the room. The servers remain air-cooled, but heat is captured at the rack. This makes it an intermediate step: it supports higher density than room air alone, without the server changes that direct-to-chip cooling requires.
- **3.4** A CDU isolates the server loop from the facility loop. This gives you:
  - **Water quality:** the server loop uses a clean, treated coolant, and cold-plate microchannels are easy to foul.
  - **Pressure:** the server loop runs at its own lower, controlled pressure.
  - **Temperature control:** the CDU regulates supply temperature and keeps it above the dew point to avoid condensation.
  - **Leak containment:** any leak is limited to a smaller loop volume.
  - **Monitoring:** flow and pressure are monitored per loop.

### Exercise 4

**Step results**

- Step 1: The PDU delivers 1.732 × 415 × 32 × 0.95 ≈ **21.85 kW**, or **≈17.5 kW usable** after the 80% derate.
- Step 2: 230 × 32 = **7.36 kW**, or **≈5.9 kW usable**.
- Step 3: With one PDU per side, 20.4 kW > 17.5 kW, so the design **fails**. When one side fails, the surviving side cannot carry the rack.
- Step 4: With two PDUs per side, the usable capacity is ≈35.0 kW ≥ 20.4 kW, so the design **passes**.
- Step 5: Conversion losses occur at:
  - the transformer
  - the UPS double conversion
  - the PSU (AC→DC)
  - the VRMs (DC→DC)

  Distribution cables also add I²R losses.

**Questions**

- **4.1** When one feed is lost, the full load instantly shifts to the surviving side. If each side was sized for only 50%, the surviving side is overloaded. Its breaker trips, and you lose the whole rack. A single fault becomes a total outage.
- **4.2** **2N.** In N+1 you can take one component out, but the shared path remains a single dependency. 2N gives you a completely independent second path, so one entire path can go down for maintenance.
- **4.3** In **PUE**. They count in total facility energy but not in IT energy (when IT energy is measured at the PDU output or the server input).

### Exercise 5

**Questions**

- **5.1** The GPU is hitting its configured power limit, and the firmware is lowering clocks to stay under it. This is expected at full load with the default limit. If the limit was lowered on purpose, for example because the facility power budget is capped, it is a deliberate configuration trade-off. In other words, it can be both: a facility constraint expressed as a configuration choice.
- **5.2** Investigate these first:
  - high inlet temperature (failed CRAH, broken containment, recirculation)
  - blocked or reversed airflow (missing blanking panels, cables obstructing exhaust)
  - fan failures
  - in DLC systems: low coolant flow, high supply temperature from the CDU/facility loop, or air in the loop
- **5.3** The chassis reading also includes:
  - CPUs and memory
  - NVSwitches
  - NICs/DPUs
  - storage
  - fans
  - **PSU conversion losses**

  The GPU readings cover only the GPU board.
- **5.4** Example: fitting more nodes into a fixed facility power budget, or riding through a cooling or power degradation event. Many workloads lose proportionally less performance than the power they save, so perf/W can improve. The trade-off is lower peak throughput and longer job time. It can also cause straggler effects in synchronous training, when some GPUs are capped differently from others.

### Exercise 6

**Step results**

- Step 1: PUE = 1.5 / 1.2 = **1.25**. DCiE = **80%**. Overhead = **300 kW**.
- Step 5: The rack load becomes 40.8 + 1.9 = **42.7 kW**, which is greater than 35.0 kW. The script prints **OVER BUDGET** and exits with code 1.
- Step 6: The rack load is 28.6 + 1.9 = **30.5 kW**, which is within 35.0 kW, so the check is **OK**. Heat is **≈104,067 BTU/hr ≈ 8.7 tons**.

**Questions**

- **6.1** These consume less:
  - chillers and compressors, because warmer facility water allows more free-cooling hours
  - CRAH/CRAC fan energy
  - server fan energy

  Strictly, server fans count as IT load. Reducing them lowers total energy, even though by itself it would raise the PUE ratio.
- **6.2** Example: you remove server fan power by moving to liquid cooling, but you also run a poorly optimized job at low GPU utilization for twice as long. PUE looks better, while energy per job is worse. PUE measures overhead, not useful work.
- **6.3** You have two options:
  - **Increase electrical capacity:** larger circuits or more PDUs per side.
  - **Reduce the load:** split the systems across racks, or apply power caps.

  Increasing capacity to around 43 kW per rack also pushes you beyond what conventional air cooling handles comfortably. You would likely need RDHx or liquid cooling. Splitting across racks keeps density low but costs floor space.

### Exercise 7

**Step results**

- Step 1: 400 kW × 10 h = **4.0 MWh**.
- Step 2: 440 kW × 7 h = **3.08 MWh**. That is ~23% less energy.
- Step 3: *"Higher instantaneous power can mean **lower** total energy if **the job finishes proportionally faster** (the runtime reduction outweighs the power increase)."*
- Step 4: These functions could move to a BlueField DPU:
  - virtual switching (OVS) and overlay networking
  - IPsec/TLS encryption
  - NVMe-oF storage initiators
  - firewalling and telemetry

  The freed cores can serve the application, such as data loading and preprocessing. Alternatively, the host can be specified with fewer cores or a smaller CPU.

**Questions**

- **7.1** Facilities are constrained by **power budget**, not by node count. What matters is how many useful results (tokens, training steps, inferences) you get per kWh, and per kW of provisioned capacity.
- **7.2** It is a win when the DPU performs the offloaded work with less energy than the CPU cores it replaces. Specialized hardware engines are typically far more efficient than general-purpose cores. It is also a win when the freed CPU capacity lets you consolidate onto fewer or smaller hosts.
- **7.3** To exploit NVLink, you must keep many GPUs physically close, inside one NVLink domain and one rack. Copper NVLink spans are short. Packing them together concentrates power, toward ~120 kW-class racks, beyond what air can remove. That is why rack-scale NVLink systems are designed for direct liquid cooling, with CDUs and facility water.

</details>