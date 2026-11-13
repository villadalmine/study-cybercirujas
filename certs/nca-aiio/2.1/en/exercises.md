# Guided Exercises — Topic 2.1: Identify Hardware Requirements for Specific AI Training Use Cases

> **Exam:** NCA-AIIO · **Topic weight:** 4.0
> **Goal:** Translate an AI training use case (model size, dataset type, scale, tenancy) into concrete hardware requirements: GPU memory, GPU count, intra-node interconnect (NVLink/NVSwitch), scale-out fabric (InfiniBand/Ethernet, ConnectX), storage throughput, DPU offload, and power and cooling.

**Prerequisites**

- Any Linux or macOS machine with Python 3.8+ for the sizing exercises (Exercises 1, 2, 4, 6, 7, 8).
- Optional: access to an NVIDIA GPU node (DGX or HGX class) for the inspection exercises (3 and 5). If you don't have one, use the reference outputs shown. They match what a DGX H100 reports.

**Reference sources**

- NVIDIA DGX H100 User Guide, component descriptions: https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
- NVIDIA DGX SuperPOD Reference Architecture (DGX B200): https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
- NVLink and NVSwitch: https://www.nvidia.com/en-us/data-center/nvlink/
- Accelerating IO in the Modern Data Center: Network IO (Magnum IO, GPUDirect RDMA): https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
- Offloading and Isolating Data Center Workloads with BlueField DPU: https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
- NCA-AIIO exam guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy, AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727

---

## Exercise 1 — Size GPU memory for a training job

Hardware selection starts with one question: **does the training state fit in GPU memory, and on how many GPUs?** Training memory is much larger than the model's weight file. With mixed precision (BF16 compute) and the Adam optimizer, every parameter needs:

| Component | Bytes/param |
|---|---|
| BF16 working weights | 2 |
| BF16 gradients | 2 |
| FP32 master weights | 4 |
| FP32 Adam first and second moments (m, v) | 8 |
| **Total model states** | **16** |

**Activations** come on top of that. They scale with sequence length, micro-batch size, hidden size and layer count. Per transformer layer, in 16-bit precision with no parallelism, activations take approximately `s·b·h·(34 + 5·a·s/h)` bytes (Korthikanti et al., *Reducing Activation Recomputation in Large Transformer Models*, 2022), where:

- `s` = sequence length
- `b` = micro-batch size
- `h` = hidden size
- `a` = number of attention heads

Two techniques shrink this:

- **Fused/flash attention** avoids storing the `a·s²` attention score matrix, leaving about `34·s·b·h`.
- **Full activation recomputation** keeps only each layer's input (`2·s·b·h`) and recomputes the rest during the backward pass. You pay for it with roughly 30% more compute.

### Steps

1. Create a working directory and the estimator script:

```bash
mkdir -p ~/aiio-2.1 && cd ~/aiio-2.1
cat > mem_estimate.py <<'EOF'
#!/usr/bin/env python3
"""Rough per-GPU memory estimate for mixed-precision transformer training with Adam."""
import argparse

GB = 1e9


def estimate(params_b, layers, hidden, heads, seq, micro_batch, act_mode):
    p = params_b * 1e9
    states = {
        "weights (bf16)": 2 * p,
        "gradients (bf16)": 2 * p,
        "master weights (fp32)": 4 * p,
        "adam m+v (fp32)": 8 * p,
    }
    sbh = seq * micro_batch * hidden
    if act_mode == "none":
        per_layer = sbh * (34 + 5 * heads * seq / hidden)
    elif act_mode == "flash":
        per_layer = sbh * 34
    else:  # full activation recomputation
        per_layer = sbh * 2
    return states, layers * per_layer


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--params-b", type=float, required=True, help="parameters, in billions")
    ap.add_argument("--layers", type=int, required=True)
    ap.add_argument("--hidden", type=int, required=True)
    ap.add_argument("--heads", type=int, required=True)
    ap.add_argument("--seq", type=int, default=4096)
    ap.add_argument("--micro-batch", type=int, default=1)
    ap.add_argument("--shard", type=int, default=1,
                    help="GPUs sharing the model states (ZeRO-3 / FSDP)")
    ap.add_argument("--act", choices=["none", "flash", "recompute"], default="flash")
    ap.add_argument("--gpu-gb", type=float, default=80.0, help="HBM per GPU, GB")
    a = ap.parse_args()

    states, act = estimate(a.params_b, a.layers, a.hidden, a.heads,
                           a.seq, a.micro_batch, a.act)
    total_states = sum(states.values())
    per_gpu = total_states / a.shard + act

    for name, value in states.items():
        print(f"{name:<24}{value / GB:>10.1f} GB")
    print(f"{'model states total':<24}{total_states / GB:>10.1f} GB")
    print(f"{'states per GPU (/' + str(a.shard) + ')':<24}{total_states / a.shard / GB:>10.1f} GB")
    print(f"{'activations (' + a.act + ')':<24}{act / GB:>10.1f} GB")
    print(f"{'per-GPU estimate':<24}{per_gpu / GB:>10.1f} GB")
    budget = a.gpu_gb * 0.9
    verdict = "FITS" if per_gpu / GB <= budget else "DOES NOT FIT"
    print(f"{verdict} in {a.gpu_gb:.0f} GB GPU (budget {budget:.0f} GB after ~10% reserve)")


if __name__ == "__main__":
    main()
EOF
chmod +x mem_estimate.py
```

2. Estimate a **7B-class model** (32 layers, hidden 4096, 32 heads, sequence length 4096) trained on a **single 80 GB GPU** with flash attention:

```bash
./mem_estimate.py --params-b 7 --layers 32 --hidden 4096 --heads 32
```

Expected output:

```
weights (bf16)                14.0 GB
gradients (bf16)              14.0 GB
master weights (fp32)         28.0 GB
adam m+v (fp32)               56.0 GB
model states total           112.0 GB
states per GPU (/1)          112.0 GB
activations (flash)           18.3 GB
per-GPU estimate             130.3 GB
DOES NOT FIT in 80 GB GPU (budget 72 GB after ~10% reserve)
```

**Questions**

- **1.1** The 7B model's BF16 weights are only 14 GB. Why does training need about 9× that amount before activations?
- **1.2** Which single component dominates model-state memory, and why?

3. Run the same model **without** flash attention:

```bash
./mem_estimate.py --params-b 7 --layers 32 --hidden 4096 --heads 32 --act none
```

Expected output (last lines):

```
activations (none)           104.2 GB
per-GPU estimate             216.2 GB
DOES NOT FIT in 80 GB GPU (budget 72 GB after ~10% reserve)
```

**Questions**

- **1.3** Activations grew from 18.3 GB to 104.2 GB. Which term of the formula causes this, and how does it scale if you double the sequence length?

4. Shard the model states across the **8 GPUs of one DGX H100** (ZeRO-3 / FSDP):

```bash
./mem_estimate.py --params-b 7 --layers 32 --hidden 4096 --heads 32 --shard 8
```

Expected output (last lines):

```
states per GPU (/8)           14.0 GB
activations (flash)           18.3 GB
per-GPU estimate              32.3 GB
FITS in 80 GB GPU (budget 72 GB after ~10% reserve)
```

**Questions**

- **1.4** Sharding divided model states by 8 but left activations unchanged. Why doesn't data-parallel sharding reduce activation memory? Name one parallelism technique that does.
- **1.5** Sharded training exchanges parameters and gradients between GPUs on every step. Which hardware component of the DGX H100 makes this cheap inside the node?

5. Now a **70B-class model** (80 layers, hidden 8192, 64 heads) on one DGX H100 (8 × 80 GB) with full recomputation:

```bash
./mem_estimate.py --params-b 70 --layers 80 --hidden 8192 --heads 64 --shard 8 --act recompute
```

Expected output:

```
weights (bf16)               140.0 GB
gradients (bf16)             140.0 GB
master weights (fp32)        280.0 GB
adam m+v (fp32)              560.0 GB
model states total          1120.0 GB
states per GPU (/8)          140.0 GB
activations (recompute)        5.4 GB
per-GPU estimate             145.4 GB
DOES NOT FIT in 80 GB GPU (budget 72 GB after ~10% reserve)
```

6. Repeat for a DGX B200 node. Its 1,440 GB of total HBM3e gives 180 GB per GPU:

```bash
./mem_estimate.py --params-b 70 --layers 80 --hidden 8192 --heads 64 --shard 8 --act recompute --gpu-gb 180
```

Expected last line:

```
FITS in 180 GB GPU (budget 162 GB after ~10% reserve)
```

7. Find the minimum number of **H100 80 GB** GPUs for the 70B job. Try `--shard 16`, `--shard 24` and `--shard 32`.

**Questions**

- **1.6** What is the smallest number of whole DGX H100 nodes (8 GPUs each) on which the 70B full fine-tune fits under this model? Show the per-GPU estimate.
- **1.7** The same job fits on one DGX B200 but needs several DGX H100 nodes. Which *additional* hardware requirement appears as soon as a job spans more than one node?
- **1.8** List three real-world memory consumers this estimator ignores.

---

## Exercise 2 — Map use cases to a hardware tier

Classifying a use case before you calculate anything saves time. Use these three tiers:

| Tier | Typical hardware | Key interconnect |
|---|---|---|
| **T1: single GPU / partitioned GPU** | 1 GPU, or a MIG slice | PCIe |
| **T2: single node, multi-GPU** | DGX/HGX with 8 GPUs | NVLink + NVSwitch |
| **T3: multi-node cluster** | DGX SuperPOD scalable units | NVLink inside the node + InfiniBand/RoCE between nodes, one NIC per GPU |

### Steps

1. For each use case, write down the tier and the single dominant hardware constraint (memory, interconnect, storage I/O, or compute time):

| # | Use case |
|---|---|
| a | LoRA fine-tune of a 7B model on 50k support tickets; base weights frozen in BF16 |
| b | Full fine-tune of a 7B model at sequence length 4096 (Exercise 1, step 4) |
| c | Pretraining a 70B LLM on 2 trillion tokens |
| d | Training a ResNet-50 image classifier on 30 million JPEG images |
| e | Five data-science teams sharing a cluster to run small experiments and notebooks |
| f | Training a recommender with multi-terabyte embedding tables |

**Questions**

- **2.1** Why is (a) feasible on a single 80 GB GPU while (b) is not?
- **2.2** For (d), the model fits easily on one GPU. What hardware constraint actually limits throughput, and which components address it?
- **2.3** For (e), which GPU feature lets one physical H100 serve several users with hardware isolation, and what is the maximum number of instances per H100?
- **2.4** For (f), why are embedding-heavy recommenders often bound by memory capacity and all-to-all network traffic rather than FLOPs?

---

## Exercise 3 — Inspect intra-node topology (NVLink / NVSwitch)

According to the DGX H100 User Guide, the system has **8 × H100 SXM5 80 GB GPUs** (640 GB total HBM3) interconnected by **4 × NVSwitch chips** using fourth-generation NVLink. Each GPU has 18 NVLink links, for **900 GB/s of bidirectional GPU-to-GPU bandwidth**, which is about 7× PCIe Gen5. The DGX B200 moves to fifth-generation NVLink at **1.8 TB/s per GPU** (see https://www.nvidia.com/en-us/data-center/nvlink/).

### Steps

1. List the GPUs, their memory and their power limit:

```bash
nvidia-smi --query-gpu=index,name,memory.total,power.limit --format=csv
```

Reference output (DGX H100):

```
index, name, memory.total [MiB], power.limit [W]
0, NVIDIA H100 80GB HBM3, 81559 MiB, 700.00 W
1, NVIDIA H100 80GB HBM3, 81559 MiB, 700.00 W
...
7, NVIDIA H100 80GB HBM3, 81559 MiB, 700.00 W
```

2. Show the topology matrix:

```bash
nvidia-smi topo -m
```

Reference output (DGX H100, abridged):

```
        GPU0  GPU1  GPU2  GPU3  GPU4  GPU5  GPU6  GPU7  NIC0  ...  CPU Affinity     NUMA Affinity
GPU0     X    NV18  NV18  NV18  NV18  NV18  NV18  NV18  PXB   ...  0-55,112-167     0
GPU1    NV18   X    NV18  NV18  NV18  NV18  NV18  NV18  SYS   ...  0-55,112-167     0
...
GPU4    NV18  NV18  NV18  NV18   X    NV18  NV18  NV18  SYS   ...  56-111,168-223   1
...
Legend:
  X    = Self
  SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes
  PXB  = Connection traversing multiple PCIe bridges (without traversing the PCIe Host Bridge)
  NV#  = Connection traversing a bonded set of # NVLinks
```

3. Check per-link NVLink status and speed for GPU 0:

```bash
nvidia-smi nvlink -s -i 0
```

Reference output (abridged):

```
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
         Link 0: 26.562 GB/s
         Link 1: 26.562 GB/s
         ...
         Link 17: 26.562 GB/s
```

**Questions**

- **3.1** Every GPU pair shows `NV18`. What does that tell you about the topology, and why does it matter for collective operations compared with an older point-to-point NVLink mesh?
- **3.2** `NIC0` shows `PXB` for GPU0 and `SYS` for GPU1. Which GPU should send its traffic through NIC0, and what happens to bandwidth and latency if the wrong mapping is used?
- **3.3** Why does `CPU Affinity` matter for the data-loader processes that feed each GPU?
- **3.4** You see `PHB` or `SYS` between GPUs instead of `NV#` on a server you are evaluating for case (b) of Exercise 2. What does that imply for sharded training?

---

## Exercise 4 — Interconnect budget: how long does gradient sync take?

A ring all-reduce of `S` bytes over `N` GPUs sends about `2·(N−1)/N·S` bytes per GPU. Ideal time is that volume divided by the slowest link's unidirectional bandwidth. Real collectives (NCCL) add latency and protocol overhead, so treat these results as a lower bound.

### Steps

1. Create the calculator:

```bash
cat > allreduce.py <<'EOF'
#!/usr/bin/env python3
"""Idealized ring all-reduce time: 2*(N-1)/N * S / B."""
import sys

grad_gb = float(sys.argv[1])          # gradient size in GB
links = {
    "NVLink4 intra-node (~450 GB/s/dir)": 450.0,
    "400 Gb/s NDR IB, 1 NIC per GPU (50 GB/s)": 50.0,
    "100 GbE shared (12.5 GB/s)": 12.5,
    "25 GbE shared (3.125 GB/s)": 3.125,
}
for n in (8, 32):
    vol = 2 * (n - 1) / n * grad_gb
    print(f"N={n} GPUs, volume per GPU = {vol:.3f} GB")
    for name, bw in links.items():
        if n > 8 and name.startswith("NVLink4"):
            continue
        print(f"  {name:<44}{vol / bw * 1000:>9.1f} ms")
EOF
chmod +x allreduce.py
```

2. Run it for a 7B model's BF16 gradients (14 GB):

```bash
./allreduce.py 14
```

Expected output:

```
N=8 GPUs, volume per GPU = 24.500 GB
  NVLink4 intra-node (~450 GB/s/dir)               54.4 ms
  400 Gb/s NDR IB, 1 NIC per GPU (50 GB/s)        490.0 ms
  100 GbE shared (12.5 GB/s)                     1960.0 ms
  25 GbE shared (3.125 GB/s)                     7840.0 ms
N=32 GPUs, volume per GPU = 27.125 GB
  400 Gb/s NDR IB, 1 NIC per GPU (50 GB/s)        542.5 ms
  100 GbE shared (12.5 GB/s)                     2170.0 ms
  25 GbE shared (3.125 GB/s)                     8680.0 ms
```

**Questions**

- **4.1** Assume the compute portion of one training step takes 1.5 s and communication can overlap with backward computation. Which of the inter-node options keep the GPUs busy, and which make the job network-bound?
- **4.2** The per-GPU volume barely changes from N=8 to N=32. What does this property of ring all-reduce imply for scaling out, and what *does* grow with N?
- **4.3** A DGX H100 has eight single-port 400 Gb/s ConnectX-7 adapters for the compute fabric (exposed through four OSFP ports). Why one NIC per GPU, and what is a "rail-optimized" fabric?
- **4.4** Why is GPUDirect RDMA essential at these speeds? Describe the data path with it and without it.

---

## Exercise 5 — Verify the scale-out network path

The DGX H100 User Guide describes two separate network roles. The **compute (cluster) fabric** uses 8 × single-port ConnectX-7 at up to 400 Gb/s InfiniBand or Ethernet. The **storage and in-band management** network uses 2 × dual-port ConnectX-7. DGX B200 systems use BlueField-3 DPUs for the storage/in-band role. The SuperPOD reference architecture keeps the compute, storage, in-band and out-of-band networks physically separate.

### Steps

1. List the InfiniBand adapters and their link state:

```bash
ibstat | grep -E "CA '|CA type|State|Rate|Link layer"
```

Reference output (one compute-fabric port shown):

```
CA 'mlx5_0'
        CA type: MT4129
                State: Active
                Physical state: LinkUp
                Rate: 400
                Link layer: InfiniBand
```

2. Confirm that GPUDirect RDMA support is loaded:

```bash
lsmod | grep nvidia_peermem
```

Reference output:

```
nvidia_peermem         16384  0
```

3. Check which NICs NCCL will use (no GPUs are consumed; this only prints the environment you would export):

```bash
env | grep -E '^NCCL_(IB_HCA|SOCKET_IFNAME)' || echo "NCCL will auto-detect HCAs"
```

**Questions**

- **5.1** `CA type: MT4129` and `Rate: 400` identify the adapter generation and speed. What fabric generation is a 400 Gb/s InfiniBand link?
- **5.2** If `nvidia_peermem` is missing, NCCL still works. What changes in the data path and in performance?
- **5.3** Why should storage traffic (checkpoints, dataset reads) not share the compute fabric's rails in a SuperPOD design?
- **5.4** Name two infrastructure functions a BlueField DPU can offload from the host CPU, and explain why this matters for a multi-tenant training cluster (use case (e) of Exercise 2).

---

## Exercise 6 — Storage requirements: data ingest and checkpoints

Storage requirements come from two very different patterns:

- **Steady read throughput** to feed the GPUs (dataset streaming).
- **Bursty write throughput** for checkpoints. Training stalls while it waits, unless checkpointing is asynchronous.

### Steps

1. Compute the dataset read rate for an LLM and for a vision job:

```bash
python3 - <<'EOF'
llm_tokens_per_s = 1_000_000          # cluster-wide training throughput
bytes_per_token = 2                    # pre-tokenized uint16
print(f"LLM ingest:    {llm_tokens_per_s * bytes_per_token / 1e6:8.1f} MB/s")

images_per_s = 20_000                  # cluster-wide, e.g. 64 GPUs
avg_jpeg_kb = 150
print(f"Vision ingest: {images_per_s * avg_jpeg_kb / 1e6:8.1f} GB/s")
EOF
```

Expected output:

```
LLM ingest:        2.0 MB/s
Vision ingest:     3.0 GB/s
```

2. Compute checkpoint size and write time for the 70B job. A restartable checkpoint needs at least FP32 master weights plus Adam moments (12 bytes/param):

```bash
python3 - <<'EOF'
params = 70e9
ckpt_gb = params * 12 / 1e9
for bw in (1, 10, 50, 100):            # aggregate write GB/s
    t = ckpt_gb / bw
    print(f"{ckpt_gb:.0f} GB at {bw:>3} GB/s -> {t:7.1f} s ({t / 3600 * 100:5.2f}% of an hour)")
EOF
```

Expected output:

```
840 GB at   1 GB/s ->   840.0 s (23.33% of an hour)
840 GB at  10 GB/s ->    84.0 s ( 2.33% of an hour)
840 GB at  50 GB/s ->    16.8 s ( 0.47% of an hour)
840 GB at 100 GB/s ->     8.4 s ( 0.23% of an hour)
```

3. If you have a GDS-enabled node, check GPUDirect Storage support:

```bash
/usr/local/cuda/gds/tools/gdscheck -p
```

Reference output (abridged):

```
 GDS release version: 1.x.x.x
 ...
 ============
 ENVIRONMENT:
 ============
 =====================
 DRIVER CONFIGURATION:
 =====================
 NVMe               : Supported
 NVMeOF             : Supported
 ...
 WekaFS             : Supported
 ...
```

**Questions**

- **6.1** LLM pretraining reads only about 2 MB/s, yet SuperPOD designs specify high-performance parallel storage. Which workload pattern justifies that investment?
- **6.2** Hourly checkpoints against a 1 GB/s NAS cost about 23% of training time. Give two remedies, one hardware and one software.
- **6.3** The vision job needs about 3 GB/s of JPEGs *and* CPU or GPU decode. Which two DGX H100 components help keep this data local and fast? Hint: look at the internal storage and at what decodes images.
- **6.4** What does GPUDirect Storage remove from the read path?

---

## Exercise 7 — Power, cooling and rack density

The DGX H100 User Guide lists a maximum system power of about **10.2 kW** (six 3.3 kW PSUs). DGX B200 is rated at about **14.3 kW** maximum; verify this against the DGX B200 / SuperPOD B200 documentation for your configuration. The SuperPOD reference architecture builds clusters from **scalable units (SUs) of 32 DGX nodes**.

### Steps

1. Calculate rack and scalable-unit power:

```bash
python3 - <<'EOF'
import math
systems = {"DGX H100": 10.2, "DGX B200": 14.3}   # kW max per system
rack_budgets = (20, 40)                           # kW per rack the facility can deliver/cool
su_nodes = 32
for name, kw in systems.items():
    print(f"{name}: one SU of {su_nodes} nodes = {su_nodes * kw:.1f} kW (compute nodes only)")
    for budget in rack_budgets:
        per_rack = math.floor(budget / kw)
        racks = math.ceil(su_nodes / per_rack) if per_rack else float("inf")
        print(f"  {budget} kW racks: {per_rack} systems/rack -> {racks} racks per SU")
EOF
```

Expected output:

```
DGX H100: one SU of 32 nodes = 326.4 kW (compute nodes only)
  20 kW racks: 1 systems/rack -> 32 racks per SU
  40 kW racks: 3 systems/rack -> 11 racks per SU
DGX B200: one SU of 32 nodes = 457.6 kW (compute nodes only)
  20 kW racks: 1 systems/rack -> 32 racks per SU
  40 kW racks: 2 systems/rack -> 16 racks per SU
```

**Questions**

- **7.1** A customer's colocation provides 15 kW per rack, air-cooled. What does that mean for deploying DGX H100 or B200, and what are the options?
- **7.2** The 326.4 kW figure leaves out several loads. Name three more components whose power and cooling must be budgeted for the SU.
- **7.3** Spreading GPUs across more racks lowers per-rack power. What trade-off does that create for the network?

---

## Exercise 8 — Capstone: write the hardware requirement

Use the training compute rule of thumb **FLOPs ≈ 6 · N · D** (N = parameters, D = training tokens). Assume an H100 SXM delivers about 989 TFLOPS of dense BF16 and that a well-tuned job reaches about 40% model FLOPs utilization (MFU).

### Steps

1. Estimate GPU-hours and wall-clock time for pretraining 70B on 2T tokens:

```bash
python3 - <<'EOF'
N, D = 70e9, 2e12
flops = 6 * N * D
per_gpu = 989e12 * 0.40
gpu_hours = flops / per_gpu / 3600
print(f"Total FLOPs: {flops:.2e}")
print(f"GPU-hours:   {gpu_hours:,.0f}")
for gpus in (256, 1024, 2048):
    h = gpu_hours / gpus
    print(f"{gpus:>5} GPUs ({gpus // 8:>3} DGX H100): {h:7.0f} h = {h / 24:5.1f} days")
EOF
```

Expected output:

```
Total FLOPs: 8.40e+23
GPU-hours:   589,822
  256 GPUs ( 32 DGX H100):    2304 h =  96.0 days
 1024 GPUs (128 DGX H100):     576 h =  24.0 days
 2048 GPUs (256 DGX H100):     288 h =  12.0 days
```

2. Fill in this requirements table for the three scenarios below:

| Requirement | Scenario A | Scenario B | Scenario C |
|---|---|---|---|
| GPU model and count | | | |
| Intra-node interconnect | | | |
| Compute fabric | | | |
| Storage | | | |
| DPU / isolation | | | |
| Power per rack (est.) | | | |

- **Scenario A:** A bank wants a full fine-tune of a 7B model on 2 GB of internal documents, retrained weekly, on-prem.
- **Scenario B:** A research lab wants to pretrain a 70B model on 2T tokens in under a month.
- **Scenario C:** A hospital network trains vision models on 30M medical images in a shared cluster with strict tenant isolation between departments.

**Questions**

- **8.1** How many DGX H100 systems, and how many scalable units, does Scenario B need to finish in under a month?
- **8.2** Why would a 25 GbE network or PCIe-only GPUs disqualify a design for Scenario B, even if the total GPU count were right?
- **8.3** For Scenario A, is InfiniBand scale-out justified? Explain.
- **8.4** For Scenario C, which requirement drives you toward BlueField DPUs, and which drives you toward high-throughput storage with GPUDirect Storage?

---

## Answers

<details>
<summary>Exercise 1 — GPU memory</summary>

**1.1** Training stores more than the weights. It also keeps BF16 gradients (2 B/param), an FP32 master copy (4 B/param) and two FP32 Adam moments (8 B/param), for 16 B/param in total versus 2 B/param for the weights alone. That is 8× the weights before activations; activations push it to about 9×.

**1.2** The Adam optimizer moments (m and v) at 8 B/param, which is 56 GB of the 112 GB. They are kept in FP32 for numerical stability.

**1.3** The `5·a·s/h` term, the attention score and softmax matrices of size `a·s²` per layer. Total activation memory goes `s·(34 + 5·a·s/h)`, so the attention part grows **quadratically** with sequence length: doubling `s` roughly quadruples that term. Flash attention removes it by recomputing attention tiles in on-chip SRAM instead of storing them.

**1.4** Each data-parallel rank processes its own micro-batch and must keep its own activations. ZeRO-3/FSDP shards only parameters, gradients and optimizer states. **Tensor parallelism** combined with **sequence parallelism** splits activations across GPUs. Pipeline parallelism also reduces activations per GPU (fewer layers per GPU), as does activation recomputation.

**1.5** NVLink4 links into the NVSwitch fabric: 4 NVSwitch chips give every GPU 900 GB/s bidirectional all-to-all bandwidth, so the all-gather and reduce-scatter traffic of sharded training stays inside the node at high speed.

**1.6** Three DGX H100 nodes (24 GPUs): 1120/24 = 46.7 GB + 5.4 GB ≈ **52.1 GB**, which fits the 72 GB budget. Sixteen GPUs give 70.0 + 5.4 = 75.4 GB, which does not fit. The arithmetic minimum is 1120/(72 − 5.4) ≈ 17 GPUs, which rounds up to 3 nodes. In practice teams often pick 4 nodes (32 GPUs, 40.4 GB per GPU) for power-of-two parallelism layouts and headroom.

**1.7** A **high-bandwidth, low-latency scale-out fabric**: InfiniBand NDR or RoCE Ethernet at 400 Gb/s per GPU through ConnectX-7, with GPUDirect RDMA. Without it, inter-node sharding traffic dominates step time.

**1.8** Any three of: CUDA context and library workspaces (cuBLAS, NCCL buffers), memory fragmentation in the PyTorch caching allocator, temporary buffers for all-gather and reduce-scatter in FSDP, logits and loss buffers (vocabulary × sequence × batch, large for big vocabularies), and optimizer step temporaries.

</details>

<details>
<summary>Exercise 2 — Use cases to tiers</summary>

| # | Tier | Dominant constraint |
|---|---|---|
| a | T1 | GPU memory (fits): 14 GB of frozen weights plus small adapters, optimizer states only for the adapters |
| b | T2 | GPU memory → needs sharding across NVLink-connected GPUs |
| c | T3 | Compute time and inter-node interconnect (plus checkpoint storage) |
| d | T1–T2 | Storage I/O and data loading/decoding |
| e | T1 (MIG) | Isolation and sharing, not raw performance |
| f | T2–T3 | Memory capacity and all-to-all network bandwidth |

**2.1** LoRA freezes the base weights. There are no gradients or Adam states for the 7B base parameters, only for a few million adapter parameters. Memory is about 14 GB of weights plus activations, well under 80 GB. A full fine-tune needs 16 B/param, or 112 GB of states.

**2.2** Input pipeline throughput: storage read bandwidth, JPEG decode capacity and data transfer to the GPU. Relevant components are local NVMe cache (DGX H100: 8 × 3.84 TB U.2 NVMe), a high-throughput parallel file system on a dedicated storage network, GPU-accelerated decode (NVJPG engines / DALI) to relieve the CPUs, and GPUDirect Storage.

**2.3** **Multi-Instance GPU (MIG)**: up to **7** isolated instances per H100, each with dedicated SMs, L2 cache slices and memory.

**2.4** Embedding lookups are sparse memory reads with very little arithmetic per byte. The tables must be sharded across many GPUs' HBM (capacity), and each step exchanges looked-up embeddings between all GPUs (all-to-all), so NVLink/NVSwitch and the scale-out fabric become the bottleneck rather than Tensor Core FLOPs.

</details>

<details>
<summary>Exercise 3 — Intra-node topology</summary>

**3.1** Every GPU reaches every other GPU over a bonded set of 18 NVLinks through the NVSwitch fabric. Bandwidth is uniform, non-blocking and all-to-all at the full 900 GB/s. In a point-to-point mesh (pre-NVSwitch designs), some pairs had fewer links or needed multiple hops, so collectives were limited by the weakest path and topology-aware ring construction mattered more.

**3.2** GPU0 (PXB: it sits under the same PCIe switch tree as NIC0). With a wrong mapping (SYS), traffic crosses the CPU root complex and the inter-socket link, which adds latency, cuts bandwidth and can break GPUDirect RDMA efficiency. NCCL normally picks the closest NIC per GPU, which is the basis of rail alignment.

**3.3** Data-loader threads should run on the cores of the NUMA node the GPU is attached to. Then host memory buffers are NUMA-local and host-to-device copies avoid the inter-socket link. Wrong pinning lowers throughput and increases jitter.

**3.4** GPUs talk over PCIe through the CPU, at roughly an order of magnitude lower bandwidth than NVLink. All-gather and reduce-scatter on every step would make sharded training of the 7B model communication-bound. That server is a poor fit for case (b); choose an NVLink/NVSwitch (SXM/HGX/DGX) system.

</details>

<details>
<summary>Exercise 4 — Interconnect budget</summary>

**4.1** 400 Gb/s per GPU (about 0.5 s) fits inside the 1.5 s compute window and can be overlapped with the backward pass, so GPUs stay busy. Shared 100 GbE (about 2 s) already exceeds the compute time, and 25 GbE (about 8 s) is dramatically network-bound: the GPUs would idle most of the time.

**4.2** Per-GPU traffic approaches `2·S` regardless of N, so bandwidth-wise ring all-reduce scales well. What grows with N is **latency**: 2·(N−1) sequential steps. That is why NCCL uses tree and hierarchical algorithms and why low-latency fabrics such as InfiniBand (plus in-network reduction like SHARP) matter at large scale.

**4.3** One NIC per GPU gives each GPU its own 400 Gb/s path, for 3.2 Tb/s per node, with no NIC contention and short PCIe paths (GPU and NIC under the same PCIe switch). In a **rail-optimized** fabric, NIC *i* of every node connects to the same leaf switch ("rail *i*"). Traffic between same-index GPUs on different nodes crosses only one switch hop, which minimizes latency and congestion for collectives.

**4.4** With GPUDirect RDMA the NIC reads and writes GPU memory directly over PCIe, giving a GPU → NIC → network → NIC → GPU path. Without it, data is staged GPU → host memory (bounce buffer) → NIC, which adds copies, consumes CPU and memory bandwidth, and adds latency. At 400 Gb/s per GPU the host staging path cannot keep up (Magnum IO network IO blog).

</details>

<details>
<summary>Exercise 5 — Scale-out network</summary>

**5.1** MT4129 is a ConnectX-7 device. A 400 Gb/s InfiniBand link is **NDR** (HDR is 200 Gb/s, XDR is 800 Gb/s).

**5.2** NCCL falls back to staging through host memory (or uses a slower path). Every transfer then involves extra copies and CPU and memory bandwidth, so effective inter-node bandwidth drops and latency rises. Large-scale training slows down noticeably.

**5.3** Checkpoint bursts and dataset reads would compete with latency-sensitive collectives, causing congestion and step-time jitter that slows the whole synchronous job. Separate fabrics (compute, storage, in-band management, out-of-band management) isolate performance and failure domains, which is the SuperPOD design principle.

**5.4** Any two of: virtual switching / OVS and overlay networking, storage virtualization (NVMe-oF initiator emulation), encryption (IPsec/TLS), firewalling and microsegmentation, and telemetry. In multi-tenant clusters this (1) gives host CPU cycles back to the workloads and (2) puts the infrastructure control and security plane on a separate processor in its own trust domain, so a compromised tenant host cannot tamper with network or storage policy (BlueField offload and isolation blog).

</details>

<details>
<summary>Exercise 6 — Storage</summary>

**6.1** **Checkpointing**: writing about 840 GB to over 1 TB in bursts, frequently, across hundreds of nodes, plus fast restore after failures. Multimodal and vision datasets also need high read throughput.

**6.2** Hardware: a parallel file system or flash storage with tens of GB/s aggregate write bandwidth on a dedicated storage fabric, or local NVMe as a staging tier. Software: asynchronous or distributed checkpointing (each rank writes its own shard in parallel and training resumes while the data drains), less frequent full checkpoints, or saving only what's required.

**6.3** The internal **NVMe data cache** (8 × 3.84 TB U.2 on DGX H100) to stage and cache datasets locally, and the GPU's **hardware JPEG decoders (NVJPG)** used via DALI to offload decode from the CPUs. The two dual-port ConnectX-7 storage NICs give the fast path to external storage.

**6.4** The CPU bounce buffer in system memory. Data moves via DMA directly from NVMe or a remote storage NIC into GPU memory, which cuts latency and CPU load and raises throughput.

</details>

<details>
<summary>Exercise 7 — Power and cooling</summary>

**7.1** A 15 kW air-cooled rack fits only **one** DGX H100 (10.2 kW) or one DGX B200 (about 14.3 kW, with almost no margin). Options: deploy one system per rack and accept the floor space and longer cables, upgrade facility power and cooling (high-density racks, rear-door heat exchangers or liquid cooling), use a colocation built for AI densities, or consume capacity from a cloud or DGX Cloud provider.

**7.2** Any three of: InfiniBand/Ethernet leaf and spine switches (compute and storage fabrics), the storage system, management and head nodes, UFM and management servers, out-of-band management switches, and cooling overhead (PUE) and PDU losses.

**7.3** Longer distances between nodes need more optical (rather than copper DAC) cables and possibly more switch hops. That raises cost, power, latency and failure points, and can complicate the rail-optimized layout.

</details>

<details>
<summary>Exercise 8 — Capstone</summary>

Reference requirements table:

| Requirement | A: 7B weekly full FT | B: 70B pretrain in under a month | C: Multi-tenant vision |
|---|---|---|---|
| GPU model and count | 1 × DGX H100 (8 × 80 GB) or 1 × DGX B200 | ≥ 128 × DGX H100 (1,024 GPUs) or equivalent B200 | Several DGX nodes; MIG for small experiments |
| Intra-node interconnect | NVLink4 + NVSwitch (900 GB/s per GPU) | NVLink/NVSwitch | NVLink/NVSwitch |
| Compute fabric | Not required (single node) | NDR 400 Gb/s IB, 8 NICs per node, rail-optimized, GPUDirect RDMA | IB or RoCE 400 Gb/s if multi-node jobs |
| Storage | Modest NAS plus local NVMe | Parallel FS, tens of GB/s write for checkpoints, separate storage fabric | High-read-throughput parallel FS plus local NVMe cache, GDS, GPU decode |
| DPU / isolation | Optional | Optional | BlueField DPUs for tenant isolation, encryption and storage offload |
| Power per rack (est.) | About 10–14 kW for one node | 3 × DGX H100 per 40 kW rack, about 43 racks for compute alone | Depends on node count; same per-system figures |

**8.1** About **128 DGX H100 systems (1,024 GPUs)**: roughly 24 days, under a month. That is **4 scalable units** of 32 nodes. 256 GPUs (one SU) would take about 96 days. Add margin for failures, restarts and lower-than-40% MFU, so 5 SUs is a safer plan.

**8.2** Exercise 4 shows that 25 GbE makes gradient synchronization take several times longer than the compute step, so GPUs would idle and MFU would collapse. PCIe-only GPUs lack NVLink/NVSwitch bandwidth for intra-node tensor parallelism and sharding. Both turn a 24-day job into many months, and the requirement is the time-to-train, not just the GPU count.

**8.3** No. The job fits on one 8-GPU node with ZeRO-3/FSDP (32.3 GB per GPU, Exercise 1 step 4). All heavy communication stays on NVLink. A weekly run of a 7B model on 2 GB of text takes hours, not weeks, so an InfiniBand fabric adds cost without benefit. A standard Ethernet network for data and management is enough.

**8.4** **Strict tenant isolation** (departments, regulated patient data) drives BlueField DPUs. They enforce network policy, encryption and storage access in a separate trust domain, offloaded from the host. **30M images with high ingest rates (GB/s) and decode load** drive high-throughput parallel storage with GPUDirect Storage, local NVMe caching and GPU decode, so the GPUs aren't starved.

</details>