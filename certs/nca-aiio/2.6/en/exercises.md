# Guided Exercises — Topic 2.6: Identify Facility Requirements (NCA-AIIO)

These exercises take you from reading telemetry on a single GPU system to sizing a rack and a Scalable Unit (SU). You will check every facility dimension the exam expects: **power, redundancy, cooling, airflow, floor loading, space, cabling, and efficiency (PUE)**.

> **Hardware assumptions.** The nameplate values used below come from the NVIDIA DGX H100 User Guide and the DGX SuperPOD reference architectures listed in [Sources](#sources).
> - DGX H100: about **10.2 kW max**, **8U**, about **130.45 kg**.
> - H100 SXM GPU: **700 W** TDP.
>
> Always confirm current figures in the site-preparation section of the official guide before you sign off a real design. Revisions change them.

---

## Exercise 1 — Read power and thermal telemetry from a GPU system

**Goal:** see why the system's nameplate power is much higher than the sum of its GPU TDPs.

**1.** On a DGX or any NVIDIA GPU server, query per-GPU power and temperature:

```bash
nvidia-smi --query-gpu=index,name,power.draw,power.limit,temperature.gpu --format=csv
```

Expected output on an idle DGX H100. Your values will vary.

```
index, name, power.draw [W], power.limit [W], temperature.gpu
0, NVIDIA H100 80GB HBM3, 71.84 W, 700.00 W, 30
1, NVIDIA H100 80GB HBM3, 69.12 W, 700.00 W, 29
...
7, NVIDIA H100 80GB HBM3, 72.40 W, 700.00 W, 31
```

**2.** Read whole-system power from the BMC over DCMI:

```bash
sudo ipmitool dcmi power reading
```

```
    Instantaneous power reading:                  2810 Watts
    Minimum during sampling period:               2650 Watts
    Maximum during sampling period:               3120 Watts
    Average power reading over sample period:     2790 Watts
    IPMI timestamp:                               Sat Nov 14 10:21:07 2026
    Sampling period:                              00000005 Seconds.
    Power reading state is:                       activated
```

**3.** Watch both while a workload runs (for example a multi-GPU training job or `dcgmi diag -r 3`):

```bash
watch -n 2 "nvidia-smi --query-gpu=index,power.draw,temperature.gpu --format=csv,noheader; sudo ipmitool dcmi power reading | grep Instantaneous"
```

**Questions**

- **Q1.1** Eight GPUs at 700 W add up to 5.6 kW, but the DGX H100 system maximum is about 10.2 kW. Which components account for the roughly 4.6 kW difference?
- **Q1.2** Should facility power be sized on the idle reading from step 2, the average under load, or the nameplate maximum? Why?
- **Q1.3** The GPU power limit can be lowered with `nvidia-smi -pl`. Is that a valid way to fit a cluster into a power-constrained facility? What is the trade-off?

---

## Exercise 2 — Build a rack-level facility calculator

**Goal:** turn nameplate values into the four numbers a facilities team asks for:
- kW per rack
- breaker size
- cooling capacity
- floor loading

**1.** Create a working directory and the site description:

```bash
mkdir -p ~/facility-lab && cd ~/facility-lab
```

Save this as `site.json`:

```json
{
  "rack": {
    "systems_per_rack": 4,
    "system_max_kw": 10.2,
    "system_weight_kg": 130.45,
    "overhead_kw": 1.0,
    "overhead_weight_kg": 200,
    "footprint_m2": 0.72
  },
  "power": {
    "voltage_ll": 415,
    "breaker_a": 63,
    "pf": 0.95,
    "derate": 0.8
  },
  "cooling": {
    "delta_t_f": 36
  },
  "floor": {
    "rated_kg_m2": 1200
  }
}
```

Field notes:
- `overhead_kw` and `overhead_weight_kg` cover the empty rack, PDUs, a management switch and cable mass.
- `footprint_m2` assumes a 600 × 1200 mm rack.
- `derate` is the 80 % continuous-load rule used by most electrical codes.

**2.** Save the calculator as `rackcheck.py`. It uses the standard library only.

```python
#!/usr/bin/env python3
"""Rack-level facility check for an AI cluster (stdlib only)."""
import json
import math
import sys

STD_BREAKERS = [16, 20, 32, 40, 50, 63, 80, 100, 125]


def main(path):
    with open(path) as fh:
        s = json.load(fh)
    r, p, c, f = s["rack"], s["power"], s["cooling"], s["floor"]

    it_kw = r["systems_per_rack"] * r["system_max_kw"] + r["overhead_kw"]

    # Three-phase usable real power per feed: sqrt(3) * V_LL * I * PF * derate
    per_amp_w = math.sqrt(3) * p["voltage_ll"] * p["pf"] * p["derate"]
    feed_kw = per_amp_w * p["breaker_a"] / 1000
    need_a = it_kw * 1000 / per_amp_w
    next_a = next((b for b in STD_BREAKERS if b >= need_a), None)

    btu = it_kw * 3412.14            # 1 kW = 3412.14 BTU/hr
    tons = btu / 12000               # 1 ton of cooling = 12,000 BTU/hr
    cfm = 3.16 * it_kw * 1000 / c["delta_t_f"]

    mass = r["systems_per_rack"] * r["system_weight_kg"] + r["overhead_weight_kg"]
    load = mass / r["footprint_m2"]

    print(f"Rack IT load      : {it_kw:.2f} kW")
    print(f"Usable per feed   : {feed_kw:.2f} kW (breaker {p['breaker_a']} A)")
    print(f"Breaker needed    : {need_a:.2f} A -> next standard size {next_a} A")
    print(f"Heat rejection    : {btu:,.0f} BTU/hr ({tons:.2f} tons)")
    print(f"Airflow @ dT {c['delta_t_f']} F: {cfm:,.0f} CFM")
    print(f"Rack mass         : {mass:.1f} kg -> {load:.1f} kg/m2")

    checks = [
        ("power per feed (A/B, each feed carries 100%)", feed_kw >= it_kw),
        ("floor loading", load <= f["rated_kg_m2"]),
    ]
    for name, ok in checks:
        print(f"[{'PASS' if ok else 'FAIL'}] {name}")
    return 0 if all(ok for _, ok in checks) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "site.json"))
```

**3.** Run it:

```bash
python3 rackcheck.py site.json; echo "exit=$?"
```

Expected output:

```
Rack IT load      : 41.80 kW
Usable per feed   : 34.42 kW (breaker 63 A)
Breaker needed    : 76.52 A -> next standard size 80 A
Heat rejection    : 142,627 BTU/hr (11.89 tons)
Airflow @ dT 36 F: 3,669 CFM
Rack mass         : 721.8 kg -> 1002.5 kg/m2
[FAIL] power per feed (A/B, each feed carries 100%)
[PASS] floor loading
exit=1
```

**Questions**

- **Q2.1** Why does the check require *each* feed to carry the whole rack load, instead of splitting 41.8 kW across feeds A and B?
- **Q2.2** Typical legacy enterprise racks were provisioned for 5–15 kW. How many DGX H100 systems fit in a 15 kW rack? What does that do to floor-space utilization?
- **Q2.3** The `derate` factor is 0.8. What happens to the required breaker size if you mistakenly set it to 1.0, and why is that dangerous?

---

## Exercise 3 — Fix the electrical design

**1.** Change `"breaker_a": 63` to `"breaker_a": 80` in `site.json` and rerun:

```bash
sed -i 's/"breaker_a": 63/"breaker_a": 80/' site.json
python3 rackcheck.py site.json; echo "exit=$?"
```

Expected output:

```
Rack IT load      : 41.80 kW
Usable per feed   : 43.70 kW (breaker 80 A)
Breaker needed    : 76.52 A -> next standard size 80 A
Heat rejection    : 142,627 BTU/hr (11.89 tons)
Airflow @ dT 36 F: 3,669 CFM
Rack mass         : 721.8 kg -> 1002.5 kg/m2
[PASS] power per feed (A/B, each feed carries 100%)
[PASS] floor loading
exit=0
```

**2.** Look at how the DGX power supplies relate to the rack feeds. The DGX H100 has multiple hot-swappable 3.3 kW PSUs (see the component descriptions in the user guide). The usual cabling practice:
- half the PSUs go to the PDU on feed A;
- the other half go to the PDU on feed B.

**Questions**

- **Q3.1** With 80 A per feed, how much headroom remains per feed (kW and %)? Is that enough to add a fifth DGX H100 to the rack?
- **Q3.2** Explain the difference between **N+1** and **2N** power redundancy. Which one does "A/B feeds, each carrying 100 % of the load" implement?
- **Q3.3** Why must the UPS and generator be sized for the *nameplate maximum*, even though most training jobs average less? Think about synchronized all-reduce phases across thousands of GPUs.

---

## Exercise 4 — Cooling: where air stops working

**1.** Compute the airflow one DGX H100 needs. Use the sensible-heat airflow formula `CFM = 3.16 × W / ΔT(°F)` at two inlet-to-exhaust temperature rises:

```bash
python3 -c "
for dt in (36, 25):
    print(f'dT {dt} F -> {3.16*10200/dt:,.0f} CFM per DGX H100')
"
```

```
dT 36 F -> 895 CFM per DGX H100
dT 25 F -> 1,289 CFM per DGX H100
```

**2.** Copy `site.json` to model a liquid-cooled rack-scale system in the GB200 NVL72 class. That is a single rack of roughly **120 kW**.

```bash
cp site.json nvl72.json
python3 - <<'EOF'
import json
s = json.load(open("nvl72.json"))
s["rack"].update(systems_per_rack=1, system_max_kw=119.0, overhead_kw=1.0,
                 system_weight_kg=1300, overhead_weight_kg=0)
s["power"]["breaker_a"] = 125
json.dump(s, open("nvl72.json", "w"), indent=2)
EOF
python3 rackcheck.py nvl72.json; echo "exit=$?"
```

The rack mass here is only a placeholder chosen to exercise the floor check. Use the vendor's figure for a real design.

Expected output:

```
Rack IT load      : 120.00 kW
Usable per feed   : 68.29 kW (breaker 125 A)
Breaker needed    : 219.66 A -> next standard size None A
Heat rejection    : 409,457 BTU/hr (34.12 tons)
Airflow @ dT 36 F: 10,533 CFM
Rack mass         : 1300.0 kg -> 1805.6 kg/m2
[FAIL] power per feed (A/B, each feed carries 100%)
[FAIL] floor loading
exit=1
```

**Questions**

- **Q4.1** At 36 °F ΔT, the 120 kW rack would need about 10,500 CFM through one rack. Why is that impractical with air, and what cooling approaches replace it?
- **Q4.2** The calculator reports `next standard size None`. What does that tell you about how power is delivered to racks at this density?
- **Q4.3** The floor check fails at about 1,806 kg/m². List two facility-side remedies.
- **Q4.4** What is a **rear-door heat exchanger (RDHx)**? Where does it sit between pure air cooling and direct liquid cooling (DLC)?

---

## Exercise 5 — Environmental envelope and hot/cold aisles

**1.** Check the operating environment section of the DGX H100 User Guide (Introduction → specifications). Note the following:
- the operating inlet temperature range (about **5–30 °C / 41–86 °F**);
- the humidity range;
- the airflow direction (front-to-back).

**2.** Draw a plan for two rows of four racks each, facing each other. Mark:
- the **cold aisle** (rack fronts / inlets);
- the **hot aisle** (rack rears / exhaust);
- the containment (doors and roof on one aisle).

**3.** Measure inlet temperature from the GPU node itself:

```bash
sudo ipmitool sdr type Temperature | grep -i -E "inlet|ambient"
```

```
Inlet_Temp       | 32h | ok  |  7.1 | 23 degrees C
```

Sensor names vary by platform. Look for "Inlet" or "Ambient".

**Questions**

- **Q5.1** Why is the *inlet* temperature the number the facility must guarantee, rather than the room's average temperature?
- **Q5.2** What happens to airflow and fan power when hot exhaust recirculates into the cold aisle? How does containment prevent it?
- **Q5.3** Why do blanking panels in empty U positions matter more in a 40 kW rack than in a 5 kW rack?

---

## Exercise 6 — Scale to a Scalable Unit (SU): space, power, cabling

The DGX SuperPOD reference architecture builds the cluster from **SUs of 32 DGX systems**, typically **4 per rack**. In the H100 design, each DGX connects to the compute fabric through **eight 400 Gb/s ConnectX-7 ports**. These are exposed through four twin-port OSFP cages and arranged as a **rail-optimized** network.

**1.** Compute SU-level numbers:

```bash
python3 - <<'EOF'
nodes, per_rack, kw, rails = 32, 4, 10.2, 8
racks = nodes // per_rack
it = nodes * kw
links = nodes * rails
leaf_ports = 64                     # NDR 400G ports per leaf switch (QM9700 class)
leaves = rails                      # rail-optimized: leaf i = rail i
print(f"Compute racks      : {racks}")
print(f"DGX IT power       : {it:.1f} kW")
print(f"Node->leaf links   : {links} x 400G")
print(f"Per leaf down/up   : {links//leaves} down / {leaf_ports - links//leaves} up")
print(f"Leaf->spine links  : {leaves*(leaf_ports - links//leaves)} x 400G")
EOF
```

```
Compute racks      : 8
DGX IT power       : 326.4 kW
Node->leaf links   : 256 x 400G
Per leaf down/up   : 32 down / 32 up
Leaf->spine links  : 256 x 400G
```

**2.** Add the parts the DGX-only number leaves out:
- network racks (leaf, spine, storage and management switches);
- storage appliances;
- management/control-plane servers (head nodes, UFM).

Each of these has its own kW, cooling and floor-space demand.

**3.** Find where the DGX H100 User Guide lists the other network interfaces besides the compute fabric:
- the dual-port ConnectX-7 / BlueField-3 adapters for storage and in-band traffic;
- the BMC port and the out-of-band management port.

**Questions**

- **Q6.1** Why does a 1:1 down/up split on each leaf matter for distributed training? What would oversubscription cause?
- **Q6.2** 256 node-side and 256 spine-side 400G links per SU have a direct physical impact. Name two facility requirements this creates, beyond power.
- **Q6.3** Why do copper DAC cables limit where switches can be placed? Why do longer runs use active optical cables or transceivers over fiber, and what does that add to the power budget?
- **Q6.4** A BlueField DPU offloads networking, storage and security functions from the host CPU. From a facility perspective, why does isolating those functions on the DPU still count as part of the node's power envelope?

---

## Exercise 7 — Facility efficiency: PUE

**PUE (Power Usage Effectiveness)** is total facility power divided by IT equipment power.

**1.** Compute PUE and annual overhead energy for a site with 1,200 kW of IT load and 1,560 kW total:

```bash
python3 - <<'EOF'
it, total = 1200, 1560
pue = total / it
print(f"PUE                : {pue:.2f}")
print(f"Overhead           : {total-it} kW")
for target in (1.15,):
    new_total = it * target
    saved = total - new_total
    print(f"At PUE {target}       : {new_total:.0f} kW total, saves {saved:.0f} kW "
          f"= {saved*8760:,.0f} kWh/year")
EOF
```

```
PUE                : 1.30
Overhead           : 360 kW
At PUE 1.15       : 1380 kW total, saves 180 kW = 1,576,800 kWh/year
```

**Questions**

- **Q7.1** Which facility subsystems make up the 360 kW overhead?
- **Q7.2** Why does moving from air to direct liquid cooling usually lower PUE?
- **Q7.3** Can a PUE of 1.0 be achieved? What would it mean?

---

## Exercise 8 — Write a site-readiness checklist

**1.** Turn everything above into a checklist you can hand to a facilities team. Save it as `site-readiness.yaml`:

```yaml
site: "dc1-hall-b"
target: "1x SU, 32x DGX H100"
power:
  rack_it_kw: 41.8
  feeds_per_rack: 2
  redundancy: "2N (A/B), each feed rated for 100% of rack load"
  feed: "3-phase 415 V, 80 A, 80% continuous derate"
  ups_sized_for: "nameplate maximum"
  generator_backed: true
cooling:
  method: "air, hot-aisle containment"
  heat_per_rack_btu_hr: 142627
  heat_per_rack_tons: 11.89
  inlet_temp_c: "5-30 (target lower end for headroom)"
  blanking_panels: required
space:
  compute_racks: 8
  rack_footprint_mm: "600x1200"
  rack_height_u: 48
  extra_racks: ["network", "storage", "management"]
floor:
  rack_mass_kg: 721.8
  point_load_kg_m2: 1002.5
  rated_kg_m2: 1200
cabling:
  compute_fabric_links: 256
  spine_links: 256
  media: ["DAC in-rack", "AOC/transceivers + fiber between rows"]
  overhead_trays: true
management:
  oob_network: true
  bmc_per_node: true
```

**2.** Validate that it parses. This guards against the YAML mistakes that break automation:

```bash
python3 -c "import yaml,sys; d=yaml.safe_load(open('site-readiness.yaml')); print('OK', len(d), 'top-level keys')"
```

```
OK 9 top-level keys
```

If PyYAML is missing, install it with `pip install pyyaml`.

**Questions**

- **Q8.1** Why are `redundancy` and `inlet_temp_c` quoted strings in this file?
- **Q8.2** Which checklist item is most often forgotten when a team plans only around the DGX nameplate power?
- **Q8.3** This checklist covers power, cooling, space, floor and cabling. Name one more facility requirement category that must appear before go-live.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1
- **Q1.1** The rest of the 10.2 kW goes to:
  - two host CPUs;
  - 2 TB of system memory;
  - four NVSwitch chips and the NVLink fabric;
  - eight ConnectX-7 NICs plus the storage/in-band adapters (ConnectX-7 or BlueField-3);
  - NVMe drives;
  - a large fan array;
  - PSU conversion losses.
- **Q1.2** Size on the **nameplate maximum**. The idle and average readings say nothing about worst-case draw, and breakers, UPS and cooling must survive the peak. Measured averages are useful for energy budgeting and PUE. They are not for capacity.
- **Q1.3** Yes. Power capping is a legitimate tool, and the facility can then provision to the capped value. The trade-off is lower per-GPU throughput and longer job times, so you pay in time-to-train. The cap must also be enforced reliably across the fleet, for example through DCGM or fleet policy.

### Exercise 2
- **Q2.1** In a 2N A/B design, either feed can fail: a UPS, a PDU, a breaker, or maintenance. When one feed is lost, the remaining feed must carry 100 % of the rack. If you sized each feed at 50 %, a single-feed failure would trip the surviving breaker and drop the whole rack.
- **Q2.2** Only **one** DGX H100 fits in 15 kW, since 10.2 kW plus overhead is under 15 and two would exceed it. Most of each rack's 42–48U then sits empty. The cluster spreads across many more racks, which lengthens cable runs past DAC reach and wastes floor space.
- **Q2.3** The required current drops from about 76.5 A to about 61.2 A, so you would pick a 63 A breaker. That breaker would then run at roughly 97 % of its rating continuously. Codes forbid this because it overheats conductors and causes nuisance trips or fire risk.

### Exercise 3
- **Q3.1** Headroom is 43.70 − 41.80 = **1.90 kW**, about **4.3 %**. A fifth DGX needs 10.2 kW, so it does not fit. Adding one would also exceed the 1,200 kg/m² floor rating once the mass is included.
- **Q3.2** **N+1** means the capacity needed (N) plus one spare component, such as one extra PSU or UPS module. **2N** means two fully independent paths, each able to carry the whole load. A/B feeds where each carries 100 % is **2N** at the distribution level.
- **Q3.3** Synchronous training makes thousands of GPUs move between compute and communication phases *together*. The result is large, fast, correlated power swings across the whole cluster. The UPS and generator must absorb the peak and the step changes. Sizing to the average would overload them, or cause generator transfer failures, exactly when all GPUs spike at once.

### Exercise 4
- **Q4.1** About 10,500 CFM through a 600 mm rack needs extreme air velocity. That brings fan power, noise and pressure-drop problems, and the room's CRAH units cannot deliver that much air to one spot. Practical air cooling tops out in the tens of kW per rack. Beyond that, the options are:
  - **direct liquid cooling** with cold plates on GPUs and CPUs, fed by a coolant distribution unit (CDU) and facility water loops;
  - **rear-door heat exchangers** as a bridge;
  - immersion, in some designs.
- **Q4.2** No standard single breaker in the list can deliver 120 kW per feed at 415 V. Racks at this density use several high-amperage whips per rack, busway (overhead power distribution), or higher-voltage distribution. In practice the power design is engineered per rack and is not a single commodity circuit.
- **Q4.3** Any two of:
  - a structurally reinforced slab, or a slab floor instead of a raised floor;
  - load-spreading plates or pedestals;
  - spacing heavy racks apart, though this limits density;
  - verifying the ratings with a structural engineer, covering static, rolling and point loads along the delivery path, elevator and ramps too.
- **Q4.4** An RDHx is a water-cooled coil that replaces the rack's rear door. Hot exhaust passes through it and is cooled before it re-enters the room. It sits between the two extremes. Servers stay air-cooled and unmodified, but the heat leaves the room through water. This allows higher per-rack density than room air alone, without the plumbing to each chip that DLC requires.

### Exercise 5
- **Q5.1** Each server's fans pull from the air directly in front of it. A cool room average can hide local hot spots at the top of a rack or at the end of a row. If inlet temperature exceeds the spec, the system throttles or alarms no matter what the average is.
- **Q5.2** Recirculation raises inlet temperature. Fans then spin up, wasting power, and GPUs may throttle. The cooling plant also runs colder to compensate, which hurts PUE. Containment physically separates hot and cold air so that exhaust can only return to the cooling units.
- **Q5.3** At 40 kW the exhaust is far hotter and the airflow far larger. Any open U position becomes a short-circuit path, and hot air recirculating through it affects every server in the rack. At 5 kW the effect is small.

### Exercise 6
- **Q6.1** Collective operations such as all-reduce run at the speed of the slowest link. With 32 down and 32 up at equal speed, every GPU can use full bandwidth across the fabric at the same time. Oversubscription would create congestion during collectives, which raises step time and wastes expensive GPU hours.
- **Q6.2** Any two of:
  - overhead cable trays or ladder racks with enough fill capacity and correct bend radius;
  - structured fiber pathways and patch panels between rows;
  - row and rack placement that respects maximum cable lengths;
  - labeling and documentation;
  - weight capacity of the trays;
  - not blocking airflow with cable bundles.
- **Q6.3** DAC copper reaches only a few meters at 400G, so the switch must sit in the same or an adjacent rack. Longer runs need AOCs or optical transceivers over fiber. Each optical module draws several watts. Across hundreds of ports this adds kilowatts to the network racks, plus the matching cooling.
- **Q6.4** The DPU is installed in the node and draws power from the node's PSUs. It is counted within the system's nameplate figure. Offloading moves work *off* the host CPU and isolates it on the DPU. It does not remove that power from the rack. The facility still sizes for the full system.

### Exercise 7
- **Q7.1** The overhead is made up of:
  - cooling: chillers, CRAH/CRAC units, pumps, cooling towers and CDU pumps;
  - UPS and transformer losses;
  - power distribution losses;
  - lighting;
  - security and building management systems.
- **Q7.2** Liquid moves heat far more efficiently than air. Fan energy and CRAH air handling drop. Warmer facility water can be used, which allows more free cooling and less chiller run time. Together these cut cooling overhead, which is the largest PUE contributor.
- **Q7.3** No. 1.0 is only a theoretical limit. It would mean every watt entering the facility reaches IT equipment, with zero cooling or distribution losses. Real sites always have some overhead.

### Exercise 8
- **Q8.1** Both values contain characters that YAML would otherwise misread:
  - `redundancy` contains `(A/B), ...` and commas, and descriptive text with punctuation is safer quoted.
  - `inlet_temp_c` begins with `5-30`, which a parser could mistake for a number or a date-like scalar.

  Quoting makes them unambiguous strings. Values containing `: ` must always be quoted.
- **Q8.2** The non-compute racks: network spines, storage appliances and management servers. These need power, cooling, floor space and cabling of their own. The fiber/optics power and the cable tray capacity are often missed too.
- **Q8.3** Examples:
  - physical security and access control;
  - fire detection and suppression suitable for the hall;
  - delivery path (dock, door heights, elevator capacity for about 130 kg systems on pallets);
  - monitoring with DCIM/BMS integration;
  - grounding and bonding;
  - seismic bracing where required.

</details>

---

## Sources

- NVIDIA DGX H100 User Guide — Introduction and component descriptions: https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
- NVIDIA DGX SuperPOD Reference Architecture (DGX B200): https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
- NVIDIA NVLink and NVLink Switch: https://www.nvidia.com/en-us/data-center/nvlink/
- Offloading and Isolating Data Center Workloads with BlueField DPU: https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
- Accelerating IO in the Modern Data Center — Network IO: https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
- NVIDIA AI Infrastructure and Operations Fundamentals (course): https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NCA-AIIO exam guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf