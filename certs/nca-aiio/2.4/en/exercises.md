# Guided Exercises — Topic 2.4: On-Prem vs Cloud AI Infrastructure

**Exam:** NCA-AIIO · **Weight:** 4.0
**Goal:** Back each on-prem vs cloud trade-off with numbers, real hardware facts, and commands you can run. Do not rely on slogans like "cloud is flexible" or "on-prem is cheaper".

> **About the numbers.** Prices in these exercises (node CAPEX, $/GPU-hour, $/kWh, $/GB egress) are **illustrative**, chosen so the arithmetic is easy to follow. Vendor and cloud pricing changes often. Swap in current quotes before you use these models for a real decision. Hardware specifications come from the NVIDIA documentation linked in each exercise.

**Reference sources**
- DGX H100 component descriptions: https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
- DGX SuperPOD B200 reference architecture: https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
- NVLink / NVSwitch: https://www.nvidia.com/en-us/data-center/nvlink/
- BlueField DPU offload and isolation: https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
- Network I/O in the modern data center: https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
- NVIDIA AI Infrastructure and Operations Fundamentals course: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NCA-AIIO exam guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf

**Lab requirements**
- Exercises 1, 3, 4 and 6 need only Python 3 and a shell.
- Exercise 2 needs a GPU node, either an on-prem DGX/HGX system or a cloud instance with 8 GPUs. If you have neither, use the expected outputs shown.
- Exercise 5 needs a Kubernetes cluster with the NVIDIA GPU Operator, or `kubectl apply --dry-run=client` for syntax validation only.

---

## Exercise 1 — Build a TCO model and find the break-even utilization

The core financial difference is simple:
- **On-prem** is a fixed cost. You pay for capacity whether you use it or not.
- **Cloud on-demand** is a variable cost. You pay per GPU-hour consumed.

So the deciding variable is **sustained utilization**.

### Steps

1. Create a working directory:

   ```bash
   mkdir -p ~/aiio-2.4 && cd ~/aiio-2.4
   ```

2. Save the following as `tco.py`:

   ```python
   #!/usr/bin/env python3
   """Illustrative on-prem vs cloud TCO model for an 8-GPU-per-node AI cluster.

   All prices are ILLUSTRATIVE. Replace them with current quotes.
   """
   import argparse

   HOURS_PER_YEAR = 8760


   def onprem_annual_cost(nodes, capex_per_node, infra_overhead, years,
                          node_max_kw, avg_load, pue, usd_per_kwh,
                          ops_per_year, colo_per_year):
       capex_total = nodes * capex_per_node * (1 + infra_overhead)
       depreciation = capex_total / years
       it_kw = nodes * node_max_kw * avg_load
       facility_kw = it_kw * pue
       energy = facility_kw * HOURS_PER_YEAR * usd_per_kwh
       total = depreciation + energy + ops_per_year + colo_per_year
       return {
           "capex_total": capex_total,
           "depreciation": depreciation,
           "it_kw": it_kw,
           "facility_kw": facility_kw,
           "energy": energy,
           "ops": ops_per_year,
           "colo": colo_per_year,
           "total": total,
       }


   def main():
       p = argparse.ArgumentParser()
       p.add_argument("--nodes", type=int, default=4)
       p.add_argument("--gpus-per-node", type=int, default=8)
       p.add_argument("--capex-per-node", type=float, default=400_000)
       p.add_argument("--infra-overhead", type=float, default=0.20,
                      help="networking + storage as a fraction of node CAPEX")
       p.add_argument("--years", type=int, default=4)
       p.add_argument("--node-max-kw", type=float, default=10.2,
                      help="DGX H100 max system power")
       p.add_argument("--avg-load", type=float, default=0.70)
       p.add_argument("--pue", type=float, default=1.4)
       p.add_argument("--usd-per-kwh", type=float, default=0.12)
       p.add_argument("--ops", type=float, default=150_000)
       p.add_argument("--colo", type=float, default=60_000)
       p.add_argument("--cloud-ondemand", type=float, default=6.00,
                      help="USD per GPU-hour, on-demand")
       p.add_argument("--cloud-committed", type=float, default=3.50,
                      help="USD per GPU-hour, multi-year commitment (billed 24x7)")
       a = p.parse_args()

       r = onprem_annual_cost(a.nodes, a.capex_per_node, a.infra_overhead,
                              a.years, a.node_max_kw, a.avg_load, a.pue,
                              a.usd_per_kwh, a.ops, a.colo)
       gpus = a.nodes * a.gpus_per_node
       gpu_hours = gpus * HOURS_PER_YEAR
       onprem_per_gpu_hour = r["total"] / gpu_hours

       print(f"Cluster: {a.nodes} nodes x {a.gpus_per_node} GPUs = {gpus} GPUs")
       print(f"CAPEX total:            ${r['capex_total']:>12,.0f}")
       print(f"Depreciation / year:    ${r['depreciation']:>12,.0f}")
       print(f"IT load (kW):            {r['it_kw']:>12.2f}")
       print(f"Facility load (kW):      {r['facility_kw']:>12.2f}")
       print(f"Energy / year:          ${r['energy']:>12,.0f}")
       print(f"Ops + support / year:   ${r['ops']:>12,.0f}")
       print(f"Colocation / year:      ${r['colo']:>12,.0f}")
       print(f"On-prem total / year:   ${r['total']:>12,.0f}")
       print(f"On-prem $/GPU-hour @100%: {onprem_per_gpu_hour:.2f}")
       print()
       print("util  onprem$/used-GPUh  cloud-ondemand  cloud-committed$/used-GPUh")
       for util in (0.10, 0.25, 0.40, 0.50, 0.70, 0.90):
           print(f"{util:4.0%}  {onprem_per_gpu_hour / util:17.2f}"
                 f"  {a.cloud_ondemand:14.2f}  {a.cloud_committed / util:26.2f}")
       breakeven = onprem_per_gpu_hour / a.cloud_ondemand
       print()
       print(f"Break-even utilization vs on-demand: {breakeven:.1%}")


   if __name__ == "__main__":
       main()
   ```

3. Run it with the defaults:

   ```bash
   python3 tco.py
   ```

   Expected output:

   ```
   Cluster: 4 nodes x 8 GPUs = 32 GPUs
   CAPEX total:            $   1,920,000
   Depreciation / year:    $     480,000
   IT load (kW):                   28.56
   Facility load (kW):             39.98
   Energy / year:          $      42,030
   Ops + support / year:   $     150,000
   Colocation / year:      $      60,000
   On-prem total / year:   $     732,030
   On-prem $/GPU-hour @100%: 2.61

   util  onprem$/used-GPUh  cloud-ondemand  cloud-committed$/used-GPUh
   10%              26.11            6.00                       26.11... 
   ```

   The exact committed column depends on your inputs. Check these values: the on-prem cost per *used* GPU-hour at 40% utilization is about **6.53**, and the break-even line reads **43.5%**.

4. Run a sensitivity check with a 3-year depreciation (a faster GPU refresh cycle) and cheaper power:

   ```bash
   python3 tco.py --years 3 --usd-per-kwh 0.08
   ```

**Questions**

1.1. Why does the on-prem cost per *used* GPU-hour grow as utilization falls, while the on-demand cloud price stays flat?

1.2. At the default inputs, which option is cheaper for a team that keeps the cluster busy 70% of the time? Which is cheaper for a team that runs experiments about 25% of the time?

1.3. A committed-use (reserved) cloud contract is billed 24×7. Economically, which does it resemble more: on-demand cloud or on-prem? Why?

1.4. Name at least three costs this model **ignores** that would push the decision in either direction.

1.5. In step 4, depreciation dominated the result. What does that tell you about the risk of buying GPUs on-prem when a new GPU generation ships every 1–2 years?

---

## Exercise 2 — Inspect what you actually get: topology, interconnect, power

A cloud "8-GPU instance" and an on-prem DGX node can look identical on a spreadsheet. Topology, fabric, and power behaviour are where they diverge. This exercise has you inspect those directly.

DGX H100 facts (from the user guide component descriptions):
- 8× H100 SXM5 80 GB GPUs, connected by 4× NVSwitch chips with fourth-generation NVLink (900 GB/s per GPU).
- 8× single-port ConnectX-7 VPI adapters at 400 Gb/s for the compute fabric (InfiniBand/Ethernet).
- 2× dual-port ConnectX-7 adapters for storage and in-band management.
- 2× Intel Xeon Platinum 8480C CPUs, 2 TB system memory.
- ~10.2 kW maximum system power.

### Steps

1. Check the GPU-to-GPU and GPU-to-NIC topology:

   ```bash
   nvidia-smi topo -m
   ```

   Expected (excerpt, DGX H100 / HGX H100 8-GPU):

   ```
           GPU0  GPU1  GPU2  GPU3  GPU4  GPU5  GPU6  GPU7  NIC0  NIC1 ...
   GPU0     X    NV18  NV18  NV18  NV18  NV18  NV18  NV18  PXB   NODE ...
   GPU1    NV18   X    NV18  NV18  NV18  NV18  NV18  NV18  NODE  NODE ...
   ...
   Legend:
     X    = Self
     SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes
     NODE = Connection traversing PCIe as well as the interconnect between PCIe Host Bridges within a NUMA node
     PXB  = Connection traversing multiple PCIe bridges (without traversing the PCIe Host Bridge)
     NV#  = Connection traversing a bonded set of # NVLinks
   ```

2. Confirm NVLink link state:

   ```bash
   nvidia-smi nvlink --status -i 0
   ```

   Expected (excerpt):

   ```
   GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-...)
            Link 0: 26.562 GB/s
            Link 1: 26.562 GB/s
            ...
            Link 17: 26.562 GB/s
   ```

3. Check the RDMA-capable fabric adapters:

   ```bash
   ibstat | grep -E "CA '|State:|Rate:|Link layer"
   ```

   Expected (excerpt, InfiniBand compute fabric):

   ```
   CA 'mlx5_0'
           State: Active
           Rate: 400
           Link layer: InfiniBand
   ```

4. **Only if you are on a cloud instance**, identify the instance type and its fabric. For example, on AWS with IMDSv2:

   ```bash
   TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
     -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
   curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
     http://169.254.169.254/latest/meta-data/instance-type; echo
   fi_info -p efa -t FI_EP_RDM | head -5
   ```

   On Azure:

   ```bash
   curl -s -H Metadata:true \
     "http://169.254.169.254/metadata/instance/compute/vmSize?api-version=2021-02-01&format=text"; echo
   ```

5. Read the power limits:

   ```bash
   nvidia-smi -q -d POWER | grep -E "GPU 0000|Current Power Limit|Max Power Limit"
   ```

   Expected on H100 SXM5: a per-GPU max power limit of about **700 W**.

**Questions**

2.1. In the topology matrix, what does `NV18` mean, and why does it matter for tensor-parallel training compared with `SYS` or `NODE`?

2.2. Multiply the link count from step 2 by the per-link rate. How does the result relate to the "900 GB/s per GPU" NVLink figure? (Hint: unidirectional vs bidirectional.)

2.3. The DGX H100 dedicates 8 × 400 Gb/s NICs to the compute fabric. What is the aggregate per-node bandwidth in Gb/s and in GB/s? Why is there one NIC per GPU?

2.4. On a cloud instance you cannot run `ibstat` against the provider's spine switches. List two things about the fabric that on-prem operators control but cloud customers usually cannot see or tune.

2.5. Eight GPUs at 700 W each add up to 5.6 kW. Why is the DGX H100 maximum system power about 10.2 kW?

---

## Exercise 3 — Facility constraints: power density and cooling

On-prem advantages assume the building can host the hardware. Many enterprise racks were designed for roughly 8–15 kW. A single modern AI node can exceed that.

Data points:
- DGX H100: ~10.2 kW max per system.
- DGX B200: ~14.3 kW max per system, 8× B200 GPUs, fifth-generation NVLink (1.8 TB/s per GPU).
- DGX SuperPOD B200 is built from **Scalable Units (SU)** of 32 DGX B200 systems (see the SuperPOD B200 reference architecture).

### Steps

1. Save `density.py`:

   ```python
   #!/usr/bin/env python3
   import math

   SYSTEMS = {"DGX H100": 10.2, "DGX B200": 14.3}
   RACK_BUDGETS_KW = (12, 25, 40, 60)

   for name, kw in SYSTEMS.items():
       print(f"== {name} ({kw} kW max per system)")
       for budget in RACK_BUDGETS_KW:
           per_rack = math.floor(budget / kw)
           print(f"  rack budget {budget:>2} kW -> {per_rack} systems/rack")
       su_kw = 32 * kw
       print(f"  32-system SU IT load: {su_kw:.1f} kW "
             f"(facility @PUE 1.3: {su_kw * 1.3:.1f} kW)")
   ```

2. Run it:

   ```bash
   python3 density.py
   ```

   Expected output:

   ```
   == DGX H100 (10.2 kW max per system)
     rack budget 12 kW -> 1 systems/rack
     rack budget 25 kW -> 2 systems/rack
     rack budget 40 kW -> 3 systems/rack
     rack budget 60 kW -> 5 systems/rack
     32-system SU IT load: 326.4 kW (facility @PUE 1.3: 424.3 kW)
   == DGX B200 (14.3 kW max per system)
     rack budget 12 kW -> 0 systems/rack
     rack budget 25 kW -> 1 systems/rack
     rack budget 40 kW -> 2 systems/rack
     rack budget 60 kW -> 4 systems/rack
     32-system SU IT load: 457.6 kW (facility @PUE 1.3: 594.9 kW)
   ```

**Questions**

3.1. An enterprise data center has 12 kW racks. What happens when it tries to host a DGX B200? What are its options?

3.2. Why does lower rack density (fewer systems per rack) also hurt the **network**, not just floor space?

3.3. Name two ways a cloud provider or a GPU-specialized colocation facility hides this problem from the customer. What do you give up in exchange?

3.4. Liquid cooling is increasingly required for top-bin AI systems. Classify it as an on-prem *advantage*, *challenge*, or *consideration*, and justify your answer.

---

## Exercise 4 — Data gravity, egress, and sovereignty

Compute can move easily. Large datasets cannot. This exercise measures how much data location constrains the choice of platform.

### Steps

1. Save `gravity.py`:

   ```python
   #!/usr/bin/env python3
   DATASET_TB = 500
   EGRESS_USD_PER_GB = 0.05          # ILLUSTRATIVE
   LINKS_GBPS = (1, 10, 100, 400)
   EFFICIENCY = 0.8                  # realistic sustained throughput

   bytes_total = DATASET_TB * 1e12
   bits_total = bytes_total * 8
   gb_total = bytes_total / 1e9

   print(f"Dataset: {DATASET_TB} TB")
   print(f"One-time egress cost: ${gb_total * EGRESS_USD_PER_GB:,.0f}")
   for gbps in LINKS_GBPS:
       seconds = bits_total / (gbps * 1e9 * EFFICIENCY)
       print(f"  {gbps:>3} Gb/s link @ {EFFICIENCY:.0%}: "
             f"{seconds / 3600:8.1f} h ({seconds / 86400:6.1f} days)")
   ```

2. Run it:

   ```bash
   python3 gravity.py
   ```

   Expected output:

   ```
   Dataset: 500 TB
   One-time egress cost: $25,000
       1 Gb/s link @ 80%:   1388.9 h (  57.9 days)
      10 Gb/s link @ 80%:    138.9 h (   5.8 days)
     100 Gb/s link @ 80%:     13.9 h (   0.6 days)
     400 Gb/s link @ 80%:      3.5 h (   0.1 days)
   ```

3. Change `DATASET_TB` to `5000` (5 PB) and run it again.

**Questions**

4.1. Your training data lives on-prem in a 500 TB lake, and your WAN uplink is 10 Gb/s. A team proposes "burst to the cloud for one training run." What is the real lead time before the first epoch can start?

4.2. Why does egress cost act as a **lock-in** mechanism even when compute prices are competitive?

4.3. A hospital must keep patient imaging data inside the country and under its own physical control. Which deployment model does this push toward? Which hybrid pattern could still use cloud GPUs?

4.4. Inference serving often needs low latency to users or factory equipment. How does that change the on-prem vs cloud analysis compared with training?

---

## Exercise 5 — Hybrid: burst a Kubernetes job to a cloud node pool

Many organizations land on hybrid: a steady baseline on owned infrastructure, plus burst or experimentation capacity in the cloud. In Kubernetes, this is often expressed with node labels and taints.

### Steps

1. Assume the following node labels already exist. Inspect them in your cluster:

   ```bash
   kubectl get nodes -L infra.example.com/location,nvidia.com/gpu.product
   ```

   Expected (illustrative):

   ```
   NAME           STATUS  ROLES  AGE  VERSION  LOCATION  GPU.PRODUCT
   dgx-01         Ready   <none> 90d  v1.31.2  onprem    NVIDIA-H100-80GB-HBM3
   dgx-02         Ready   <none> 90d  v1.31.2  onprem    NVIDIA-H100-80GB-HBM3
   cloud-gpu-a1   Ready   <none> 2h   v1.31.2  cloud     NVIDIA-H100-80GB-HBM3
   ```

2. Save `burst-job.yaml`. It *prefers* on-prem and *tolerates* the cloud pool's taint:

   ```yaml
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: finetune-burst
     namespace: ml-team
   spec:
     backoffLimit: 2
     template:
       metadata:
         labels:
           app: finetune-burst
       spec:
         restartPolicy: Never
         affinity:
           nodeAffinity:
             preferredDuringSchedulingIgnoredDuringExecution:
               - weight: 100
                 preference:
                   matchExpressions:
                     - key: infra.example.com/location
                       operator: In
                       values:
                         - onprem
             requiredDuringSchedulingIgnoredDuringExecution:
               nodeSelectorTerms:
                 - matchExpressions:
                     - key: nvidia.com/gpu.product
                       operator: In
                       values:
                         - NVIDIA-H100-80GB-HBM3
         tolerations:
           - key: infra.example.com/cloud-burst
             operator: Exists
             effect: NoSchedule
         containers:
           - name: trainer
             image: nvcr.io/nvidia/pytorch:24.10-py3
             command:
               - python
               - -c
               - "import torch; print(torch.cuda.device_count())"
             resources:
               limits:
                 nvidia.com/gpu: 8
   ```

3. Validate it, then apply it:

   ```bash
   kubectl apply --dry-run=client -f burst-job.yaml
   kubectl apply -f burst-job.yaml
   kubectl get pod -n ml-team -l app=finetune-burst -o wide
   ```

4. Fill both on-prem nodes with other GPU work. Submit the job again with a new name, and see where it lands.

**Questions**

5.1. Why is the on-prem preference expressed as `preferred...` rather than `required...`?

5.2. What is the purpose of the taint on the cloud node pool, and why does only this Job carry the toleration?

5.3. The Job lands on `cloud-gpu-a1`, but it reads its training data from an on-prem NFS server. Using Exercise 4, what problem will you see, and how would you fix it?

5.4. Name two operational concerns that hybrid adds and that neither pure on-prem nor pure cloud has. Think about identity, observability, and drivers.

---

## Exercise 6 — Decision matrix for real scenarios

### Steps

1. Copy this table into a file named `decision.md`. Fill the *Recommended model* column with **On-prem**, **Cloud**, or **Hybrid**, and the *Deciding factor* column with one or two words.

   | # | Scenario | Recommended model | Deciding factor |
   |---|----------|-------------------|-----------------|
   | A | Startup, unpredictable demand, 6-month runway, no data center | | |
   | B | Bank training fraud models 24×7 on regulated data, existing 40 kW racks | | |
   | C | Research lab: steady fine-tuning load plus a quarterly 3-week pre-training run needing 4× capacity | | |
   | D | Team evaluating whether a new GPU architecture fits its models before buying | | |
   | E | Multi-tenant internal AI platform where tenants must be strongly isolated on shared on-prem servers | | |

2. For scenario E, read the BlueField DPU article. Write one sentence on how a DPU changes the isolation story on owned infrastructure:
   https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu

**Questions**

6.1. Which scenario is the clearest case for on-demand cloud? Answer in terms of the break-even utilization from Exercise 1.

6.2. Why is scenario C a textbook hybrid case?

6.3. For scenario E, what does running networking, storage, and security services on the DPU (instead of the host CPU) give the platform team?

6.4. Lead time is often cited as a cloud advantage. Explain it as a time-to-value argument rather than a cost argument.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**1.1.** On-prem cost is fixed: $732,030 per year in the model, no matter how many GPU-hours you consume. Dividing a fixed cost by fewer used hours raises the cost per used hour (2.61 / U). On-demand cloud bills only the hours consumed, so its price per used hour is constant.

**1.2.**
- At 70% utilization, on-prem costs 2.61 / 0.70 ≈ **$3.73** per used GPU-hour, versus $6.00 on-demand. **On-prem wins.**
- At 25% utilization, on-prem costs 2.61 / 0.25 ≈ **$10.45**, versus $6.00. **Cloud wins.**
- The break-even point is 2.61 / 6.00 ≈ **43.5%**.

**1.3.** It behaves like on-prem. You pay for capacity 24×7 whether you use it or not, so its effective cost is also price / U. You keep the cloud's operational advantages (no facility, no hardware lifecycle) but give up the elasticity.

**1.4.** Any three of the following:
- Hardware lead time and installation labour.
- Data center build-out: power and liquid-cooling retrofits.
- Network egress and data transfer.
- Staff skill and hiring.
- Software licensing (for example, NVIDIA AI Enterprise).
- Storage growth.
- Spare parts and failure downtime.
- Opportunity cost of capital.
- Residual and resale value.
- Cloud availability and quota limits for scarce GPUs.
- Discounts on either side.

**1.5.** Most on-prem cost is the hardware itself. If a new generation offers much better performance per watt and per dollar, owned hardware becomes relatively obsolete before it is fully depreciated. Shorter useful life raises the effective hourly cost. Cloud shifts this **technology-refresh risk** to the provider.

### Exercise 2

**2.1.** `NV18` means the two GPUs are connected through a bonded set of 18 NVLink links, here through NVSwitch, so every GPU pair gets full NVLink bandwidth. Tensor and pipeline parallelism exchange activations and gradients at every layer, so they need the highest-bandwidth, lowest-latency path. `NODE` and `SYS` paths go over PCIe and possibly the inter-CPU link, which is far slower and adds latency.

**2.2.** 18 links × ~26.6 GB/s ≈ 478 GB/s. `nvidia-smi` reports approximately **per-direction** rates, while 900 GB/s is the **total bidirectional** bandwidth (~450 GB/s each way). The figures are consistent within rounding. NVLink's GB/s is well above PCIe Gen5 x16, at roughly 64 GB/s per direction.

**2.3.** 8 × 400 Gb/s = **3,200 Gb/s = 3.2 Tb/s ≈ 400 GB/s** per node. Pairing one NIC with each GPU, on a nearby PCIe switch (the `PXB` entries), lets GPUDirect RDMA move data between a GPU and the network without crossing the CPU or the inter-socket link. It also avoids NIC contention during all-reduce operations across nodes.

**2.4.** Any two of the following:
- Fabric topology: rail-optimized design, oversubscription ratio.
- Switch and firmware versions.
- Adaptive routing and congestion-control settings.
- SHARP in-network reduction.
- Whether your nodes share leaf switches with other tenants.
- Placement and locality guarantees across nodes.
- Direct access to UFM or switch telemetry.

**2.5.** System power includes much more than the GPUs:
- 2 CPUs and 2 TB of DRAM.
- 4 NVSwitch chips.
- 10 ConnectX-7 adapters.
- NVMe storage.
- Fans.
- Power-supply conversion losses.

Facilities must plan for the **system maximum**, not the sum of GPU TDPs.

### Exercise 3

**3.1.** A DGX B200 at ~14.3 kW exceeds a 12 kW rack budget, so **zero** systems fit. The options are:
- Upgrade the rack's power and cooling, including rear-door or direct liquid cooling.
- Build or lease a high-density zone.
- Use a GPU-ready colocation facility.
- Consume the capacity from the cloud.

Power-capping the system is technically possible but wastes performance you paid for.

**3.2.** With fewer systems per rack, the cluster spreads over more racks. Cable runs between nodes and leaf and spine switches get longer, so you need more optical transceivers (cost, power, failure points) and possibly more switch tiers. InfiniBand and NVLink designs assume tight physical proximity.

**3.3.**
- Cloud providers and GPU-focused colocation facilities build purpose-designed high-density, liquid-cooled halls.
- They amortize those facilities across many customers.

In exchange you give up physical control, topology choice, and sometimes data residency guarantees, and you pay the provider's margin.

**3.4.** It is all three, depending on viewpoint, but on-prem it is primarily a **challenge/consideration**. It needs facility plumbing (CDUs, water loops), new skills, and maintenance procedures. It *becomes* an advantage once in place: higher density, better PUE, and support for the newest systems.

### Exercise 4

**4.1.** About **5.8 days** to move 500 TB at 80% of 10 Gb/s. That ignores verification and retries, and it assumes the link is not shared with production traffic. A 5 PB dataset would take ~58 days. At these sizes the realistic options are:
- Keep compute next to the data.
- Use a dedicated high-bandwidth interconnect such as Direct Connect or ExpressRoute.
- Use offline transfer appliances.

**4.2.** Moving data *into* a cloud is usually cheap or free. Moving it *out* is charged per GB and also takes a long time. Once petabytes of data live with one provider, switching providers or repatriating to on-prem has a large one-time cost and delay. That changes your negotiating position whatever the compute price.

**4.3.** It pushes toward **on-prem**, or a sovereign/in-country private cloud. Two hybrid patterns can still use cloud GPUs:
- Train in the cloud on **de-identified or synthetic** data, or on data that may leave.
- Use **federated learning**, where models travel to the data and only weights or gradients leave the premises.

**4.4.** Inference is latency-bound and often runs continuously, so it tends to sit close to users or devices: on-prem, edge, or a nearby cloud region. Its steady 24×7 load also favours owned or committed capacity, per Exercise 1. Training is throughput-bound and bursty, which is where elastic cloud capacity is most attractive.

### Exercise 5

**5.1.** `required` would forbid the cloud node pool and remove the burst capability. `preferred` with weight 100 tells the scheduler to use on-prem when it fits, which is cheaper because on-prem cost is already sunk, and to fall back to the cloud when on-prem is full. A separate `required` term still guarantees the correct GPU type.

**5.2.** The taint keeps arbitrary workloads off expensive, metered cloud nodes. Only workloads that explicitly opt in with the toleration may consume burst capacity. This is a cost-governance control.

**5.3.** All data reads cross the WAN. GPUs will stall on I/O, throughput collapses, and if data flows back out you may pay egress. Fixes:
- Stage the dataset to cloud object or parallel storage before the job starts, for example with an init container or pre-sync.
- Cache it near the cloud nodes.
- Route only data-light jobs, such as evaluation or small fine-tunes, to the cloud.

**5.4.** Any two of the following:
- Federated identity and RBAC across environments.
- Network connectivity and security between sites (VPN or interconnect).
- Unified monitoring and logging (DCGM metrics from both sides).
- Consistent GPU driver, CUDA, and container image versions.
- Cross-environment cost attribution.
- Data synchronization and consistency.
- Different failure domains and support channels.

### Exercise 6

**6.1.** Scenario **A** is the clearest cloud case. Utilization is unpredictable and probably below the ~43% break-even. The 6-month horizon is shorter than any depreciation period. There is no facility. It avoids capital expenditure entirely.

**Model table**

| # | Model | Deciding factor |
|---|-------|-----------------|
| A | Cloud | variable demand / no CAPEX |
| B | On-prem | regulated data + high utilization |
| C | Hybrid | steady baseline + burst |
| D | Cloud | try before buy |
| E | On-prem with DPUs | isolation on owned hardware |

**6.2.** The steady load runs at high utilization, which favours owned hardware. The quarterly peak is 4× capacity for about 3 weeks, roughly 6% of the year. Buying 4× hardware for that peak would leave about 75% of the fleet idle most of the time. Owning the baseline and renting the peak minimizes total cost.

**6.3.** The DPU (BlueField) runs infrastructure services in a separate trust domain from the host OS. Examples include virtual switching, encryption, firewalling, and storage virtualization. This gives:
- **Isolation.** A compromised tenant workload on the host cannot tamper with the network or security policy.
- **Freed host CPU cycles** for the AI workloads.
- **A cloud-like, provider-controlled infrastructure layer** on on-prem servers.

DPUs bring the isolation model of large clouds to owned infrastructure.

**6.4.** On-prem AI capacity can take months to deliver: procurement, hardware lead time, facility readiness, installation, burn-in, and validation. Cloud capacity, when quota and supply allow, can be provisioned in minutes to days. For a team whose competitive window is short, starting several months earlier can be worth more than the per-hour savings of owning. That is time-to-value, separate from TCO. Scarce GPU types may still need cloud reservations ahead of time, so cloud lead time is not always zero.

</details>