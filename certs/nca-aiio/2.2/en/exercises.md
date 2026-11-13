# Guided Exercises — Topic 2.2: Scale a GPU Infrastructure for Different Use Cases

**Certification:** NVIDIA-Certified Associate: AI Infrastructure and Operations (NCA-AIIO)
**Exam weight:** 4.0

These exercises build the main skill this objective tests. Given a workload (training, fine-tuning, inference or multi-tenant platform), you decide **how** to scale it:

- **Scale up:** more and faster GPUs inside one NVLink domain.
- **Scale out:** more nodes over an InfiniBand/Ethernet fabric.
- **Partition:** MIG.
- **Offload:** BlueField DPU.

You also check the decision against the hardware you would actually deploy.

Most steps fall into one of two kinds:

- **Calculation and design steps.** You need only pen, paper or a Python shell.
- **Observation steps.** These use real CLI tools (`nvidia-smi`, `ibstat`, NCCL tests, `kubectl`). Representative output is shown for each, so you can do the exercise without a DGX in front of you. If you do have access to a GPU node, run the commands and compare.

> **Official references used throughout**
> - DGX H100 component descriptions: https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
> - DGX SuperPOD Reference Architecture (DGX B200): https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
> - NVLink and NVLink Switch: https://www.nvidia.com/en-us/data-center/nvlink/
> - BlueField DPU offload and isolation: https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
> - Network I/O in the modern data center: https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
> - NCA-AIIO exam blueprint: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
> - AI Infrastructure and Operations Fundamentals course: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727

---

## Exercise 0 — The mental model: three axes of scaling

Before any arithmetic, fix the vocabulary. Every scaling decision in this topic moves along one or more of these axes:

| Axis | Mechanism | Typical bandwidth per GPU | Latency domain | When it is the right lever |
|---|---|---|---|---|
| **Scale up** | NVLink + NVSwitch inside a node (DGX H100/B200) or a rack (GB200 NVL72) | NVLink 4: 900 GB/s bidirectional · NVLink 5: 1.8 TB/s bidirectional | Sub-microsecond, memory-semantic | Tensor parallelism, large-model inference, anything that exchanges activations every layer |
| **Scale out** | InfiniBand NDR / Spectrum-X Ethernet, one 400 Gb/s NIC per GPU, rail-optimized fat tree | 400 Gb/s = 50 GB/s per direction | A few microseconds, RDMA | Data parallelism, pipeline parallelism, adding throughput replicas |
| **Partition / offload** | MIG (split one GPU) · BlueField DPU (move infrastructure work off the host CPU) | n/a | n/a | Many small inference jobs, multi-tenancy, isolation, freeing host CPU cycles |

### Steps

1. Copy the table into your notes. Then compute the ratio between per-GPU NVLink 4 bandwidth **per direction** and per-GPU scale-out bandwidth **per direction**:
   - NVLink 4: 900 GB/s bidirectional → 450 GB/s per direction.
   - ConnectX-7 at 400 Gb/s → 400 / 8 = 50 GB/s per direction.
2. Repeat the calculation for NVLink 5 (1.8 TB/s bidirectional) against the same 400 Gb/s NIC.
3. Write down one workload you know (for example "a chatbot serving a 7B model" or "pre-training a 70B model") and say which axis you would reach for first.

**Questions**

- **Q0.1** What is the NVLink 4 to NIC bandwidth ratio per GPU? And for NVLink 5?
- **Q0.2** Given that ratio, which parallelism strategy should stay inside the NVLink domain, and which can go across the network? Why?
- **Q0.3** Why is "add more nodes" the wrong first answer for a latency-sensitive inference service whose model fits on one GPU?

---

## Exercise 1 — Reading the building block: DGX H100 vs DGX B200

You cannot scale what you cannot describe. The exam expects you to know what a single node contributes.

### Steps

1. Open the DGX H100 component descriptions (link above) and fill in the **DGX H100** column below. Then use the DGX B200 / SuperPOD B200 documentation to fill in the **DGX B200** column.

   | Component | DGX H100 | DGX B200 |
   |---|---|---|
   | GPUs | ? | ? |
   | Total GPU memory | ? | ? |
   | NVSwitch chips (generation) | ? | ? |
   | NVLink bandwidth per GPU | ? | ? |
   | Compute-fabric NICs | ? | ? |
   | Storage / in-band NICs or DPUs | ? | ? |
   | Approx. max system power | ? | ? |

2. Compare your answers with this reference fill-in. The vendor datasheet is authoritative if a revision differs.

   | Component | DGX H100 | DGX B200 |
   |---|---|---|
   | GPUs | 8× H100 SXM5 | 8× B200 |
   | Total GPU memory | 640 GB HBM3 (8 × 80 GB) | 1,440 GB HBM3e |
   | NVSwitch chips | 4× NVSwitch (NVLink 4 generation) | 2× NVSwitch (NVLink 5 generation) |
   | NVLink bandwidth per GPU | 900 GB/s bidirectional (18 links) | 1.8 TB/s bidirectional |
   | Compute-fabric NICs | 8× ConnectX-7 single-port, 400 Gb/s (InfiniBand or Ethernet), in 4× OSFP ports | 8× ConnectX-7 single-port, 400 Gb/s |
   | Storage / in-band | 2× dual-port ConnectX-7 | 2× BlueField-3 DPU |
   | Approx. max power | ~10.2 kW | ~14.3 kW |

3. Compute the **aggregate compute-fabric bandwidth** of one node (8 NICs × 400 Gb/s) in Tb/s and in GB/s per direction.

**Questions**

- **Q1.1** What is the aggregate scale-out bandwidth of one DGX H100 node? Why does the design give each GPU its own NIC instead of sharing a few fat NICs?
- **Q1.2** The DGX B200 more than doubles GPU memory per node. Name one use case where that alone changes the scaling decision, so the job no longer needs to scale out.
- **Q1.3** What changes on the storage/in-band side between DGX H100 and DGX B200, and which section of this topic does that link to?

---

## Exercise 2 — Observing scale-up topology on a node

### Steps

1. On a GPU node, print the interconnect matrix:

   ```bash
   nvidia-smi topo -m
   ```

   Representative output on a DGX H100 (trimmed to GPU and four NIC columns):

   ```
           GPU0  GPU1  GPU2  GPU3  GPU4  GPU5  GPU6  GPU7  NIC0  NIC1  NIC2  NIC3  CPU Affinity  NUMA Affinity
   GPU0     X    NV18  NV18  NV18  NV18  NV18  NV18  NV18  PXB   SYS   SYS   SYS   0-55,112-167  0
   GPU1    NV18   X    NV18  NV18  NV18  NV18  NV18  NV18  SYS   PXB   SYS   SYS   0-55,112-167  0
   GPU2    NV18  NV18   X    NV18  NV18  NV18  NV18  NV18  SYS   SYS   PXB   SYS   0-55,112-167  0
   GPU3    NV18  NV18  NV18   X    NV18  NV18  NV18  NV18  SYS   SYS   SYS   PXB   0-55,112-167  0
   GPU4    NV18  NV18  NV18  NV18   X    NV18  NV18  NV18  SYS   SYS   SYS   SYS   56-111,168-223 1
   ...

   Legend:
     X    = Self
     SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes
     NODE = Connection traversing PCIe as well as the interconnect between PCIe Host Bridges within a NUMA node
     PHB  = Connection traversing PCIe as well as a PCIe Host Bridge (typically the CPU)
     PXB  = Connection traversing multiple PCIe bridges (without traversing the PCIe Host Bridge)
     PIX  = Connection traversing at most a single PCIe bridge
     NV#  = Connection traversing a bonded set of # NVLinks
   ```

2. Check the per-link NVLink state of one GPU:

   ```bash
   nvidia-smi nvlink -s -i 0
   ```

   Representative output:

   ```
   GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-xxxxxxxx-....)
        Link 0: 26.562 GB/s
        Link 1: 26.562 GB/s
        ...
        Link 17: 26.562 GB/s
   ```

3. Check the NVLink error counters. Errors here are an early signal of a degrading link, and they often show up before a job slows down:

   ```bash
   nvidia-smi nvlink -e -i 0
   ```

4. Note the NIC each GPU reaches through `PXB`. That GPU-to-NIC pairing is the physical basis of the **rail** concept in Exercise 4.

**Questions**

- **Q2.1** What does `NV18` between every pair of GPUs tell you about the role of NVSwitch, compared with a direct point-to-point NVLink mesh?
- **Q2.2** Multiply 18 links by the per-link figure. How does the result relate to the 900 GB/s datasheet number?
- **Q2.3** GPU0 sees NIC0 as `PXB` but NIC1 as `SYS`. If a job pins GPU0's traffic to NIC1, what happens to the data path and to throughput?
- **Q2.4** Why does `CPU Affinity` matter when you launch data-loader processes for a multi-GPU training job?

---

## Exercise 3 — Sizing memory: does the model fit, and on what?

Scaling starts with memory, not FLOPs. Use these working rules of thumb (approximations for planning):

- **Inference weights:** bytes = parameters × bytes per parameter (FP16/BF16 = 2, FP8 = 1, FP4 = 0.5). Add headroom for the KV cache and activations. Plan roughly 20–40% extra, and more for long contexts or high concurrency.
- **Full training with Adam, mixed precision:** about 16 bytes per parameter (FP16 weights + FP16 gradients + FP32 master weights + two FP32 Adam moments), **before** activations.

### Steps

1. Fill in this table with Python or by hand:

   ```python
   GB = 1e9
   for name, params in [("8B", 8e9), ("70B", 70e9), ("405B", 405e9)]:
       inf_fp16 = params * 2 / GB
       inf_fp8  = params * 1 / GB
       train    = params * 16 / GB
       print(f"{name:>5}  infer-FP16={inf_fp16:8.0f} GB  infer-FP8={inf_fp8:8.0f} GB  train-Adam={train:9.0f} GB")
   ```

   Expected output:

   ```
      8B  infer-FP16=      16 GB  infer-FP8=       8 GB  train-Adam=      128 GB
     70B  infer-FP16=     140 GB  infer-FP8=      70 GB  train-Adam=     1120 GB
    405B  infer-FP16=     810 GB  infer-FP8=     405 GB  train-Adam=     6480 GB
   ```

2. For each row, decide the **smallest** sensible footprint on (a) DGX H100 (80 GB/GPU, 640 GB/node) and (b) DGX B200 (≈180 GB/GPU, 1,440 GB/node). Use these options:
   - a MIG slice
   - 1 GPU
   - N GPUs in one node (tensor parallel over NVLink)
   - multiple nodes

3. For the 70B training case, explain why "fits in 1,440 GB" on a DGX B200 is still not a comfortable single-node plan.

**Questions**

- **Q3.1** Where does 8B FP16 inference land on an H100? Would you give it a whole GPU or a MIG slice? What decides?
- **Q3.2** 70B FP16 inference needs ~140 GB of weights. What is the minimum H100 count, and why do operators usually choose TP=4 rather than TP=2?
- **Q3.3** 405B FP8 inference (~405 GB weights): one DGX H100 node or two? One DGX B200? Justify with the KV cache.
- **Q3.4** Pre-training any of these models on trillions of tokens: why is the answer "multiple nodes" even when memory fits?

---

## Exercise 4 — Designing the scale-out fabric: a rail-optimized Scalable Unit

The DGX SuperPOD reference architecture builds clusters out of **Scalable Units (SU)** of 32 DGX systems. Each SU has a **rail-optimized**, non-blocking (1:1) compute fabric on NDR 400 Gb/s InfiniBand, built from Quantum-2 QM9700 switches with 64 × 400 Gb/s ports each.

*Rail-optimized* means: GPU *i* / NIC *i* of every node in the SU connects to the same leaf switch, *rail i*. So a cluster with 8 GPUs per node has 8 rails.

### Steps

1. **Leaf layer, one SU.**
   - Count the NIC ports one rail must connect: 32 nodes × 1 NIC per rail.
   - A non-blocking leaf splits its 64 ports half down and half up. How many downlinks and uplinks per leaf?
   - How many leaf switches does one SU need?
2. **Spine layer, 4 SUs.**
   - Total uplinks = SUs × leaves per SU × uplinks per leaf.
   - Spines needed = total uplinks / 64 ports per spine.
3. **Cable count, 4 SUs.** Count node-to-leaf cables plus leaf-to-spine cables.
4. Draw it: 8 vertical rails per SU, every leaf connected to every spine.
5. Compare your numbers with the switch and cable bill of materials in the SuperPOD RA (link above). The RA is authoritative. It also reserves ports for UFM (the InfiniBand fabric manager) and management nodes, which slightly changes the node count in some reference designs.

**Questions**

- **Q4.1** Give your leaf, spine and node-cable counts for 1 SU and for 4 SUs.
- **Q4.2** Why does rail optimization help collective operations such as all-reduce? Hint: think about where NCCL's per-rail traffic goes, and how many switch hops it takes.
- **Q4.3** Why is the compute fabric designed **non-blocking** (1:1), while inference-only clusters are often built with oversubscription?
- **Q4.4** Name the four networks of a DGX SuperPOD, and say which one carries the gradient all-reduce.

---

## Exercise 5 — Verifying the fabric before you trust it

A cluster that is "up" can still be scaled out on a degraded fabric: one link at reduced width or speed can slow down every collective. Validate the fabric before you hand it over to users.

### Steps

1. On a node, list the InfiniBand HCAs and their state:

   ```bash
   ibstat
   ```

   Representative output (one of the eight compute NICs):

   ```
   CA 'mlx5_0'
           CA type: MT4129
           Number of ports: 1
           Firmware version: 28.39.1002
           Port 1:
                   State: Active
                   Physical state: LinkUp
                   Rate: 400
                   Base lid: 117
                   SM lid: 1
                   Link layer: InfiniBand
   ```

2. Run a quick scripted check for any port that is not at full rate:

   ```bash
   ibstat | awk '/^CA /{ca=$2} /Rate:/{if ($2 != 400) print ca, "rate", $2}'
   ```

   Empty output means all ports report 400 Gb/s.

3. Run a two-node NCCL all-reduce test from the `nccl-tests` project (https://github.com/NVIDIA/nccl-tests):

   ```bash
   mpirun -np 16 -H node01:8,node02:8 \
     -x NCCL_DEBUG=INFO \
     ./build/all_reduce_perf -b 8 -e 8G -f 2 -g 1
   ```

   Representative tail of the output (the numbers vary with NCCL version, topology and SHARP):

   ```
   #       size         count      type   redop    root     time   algbw   busbw  #wrong
         4294967296    1073741824  float     sum      -1  23950.1  179.33  336.25       0
         8589934592    2147483648  float     sum      -1  47612.4  180.42  338.28       0
   # Avg bus bandwidth    : 98.71
   ```

4. Check the relationship NCCL uses for ring all-reduce:

   `busbw = algbw × 2(n − 1) / n`, where *n* is the number of ranks.

   Verify it with the 8 GB row: 180.42 × 2 × 15 / 16 = ?

5. Run the same test inside a single node (`-np 8 -H node01:8`) and compare the large-message `busbw`.

**Questions**

- **Q5.1** One NIC reports `Rate: 200`. What is the effect on a 128-node training job, and why is the effect so large for one port?
- **Q5.2** Why is `busbw` the right number to compare with hardware link speed, rather than `algbw`?
- **Q5.3** Intra-node `busbw` is clearly higher than two-node `busbw`. Using Exercise 0, explain the expected ceiling for each case.
- **Q5.4** Why is the "Avg bus bandwidth" line much lower than the large-message rows, and why should you not use it as the acceptance criterion?

---

## Exercise 6 — Scaling in the other direction: partitioning with MIG for inference

Not every use case needs *more* GPU. A fleet that serves many small models usually needs *more, smaller, isolated GPUs*. Multi-Instance GPU (MIG) splits an H100 into up to 7 instances, each with its own SMs, L2 slice and memory controllers.

H100 80 GB MIG profiles:

| Profile | Max instances per GPU | Memory each |
|---|---|---|
| `1g.10gb` | 7 | 10 GB |
| `1g.20gb` | 4 | 20 GB |
| `2g.20gb` | 3 | 20 GB |
| `3g.40gb` | 2 | 40 GB |
| `4g.40gb` | 1 | 40 GB |
| `7g.80gb` | 1 | 80 GB |

### Steps

1. Enable MIG on GPU 0. This needs root, and the GPU must be idle; some platforms also need a GPU reset.

   ```bash
   sudo nvidia-smi -i 0 -mig 1
   ```

2. List the profiles the GPU offers:

   ```bash
   nvidia-smi mig -lgip -i 0
   ```

3. Create three `2g.20gb` instances with their compute instances (`-C`):

   ```bash
   sudo nvidia-smi mig -i 0 -cgi 2g.20gb,2g.20gb,2g.20gb -C
   nvidia-smi -L
   ```

   Representative output:

   ```
   GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-5e1f...)
     MIG 2g.20gb     Device  0: (UUID: MIG-7a2c...)
     MIG 2g.20gb     Device  1: (UUID: MIG-91bd...)
     MIG 2g.20gb     Device  2: (UUID: MIG-c03e...)
   ```

4. In Kubernetes, with the NVIDIA GPU Operator running under the `mixed` MIG strategy, each profile shows up as its own extended resource. Request one slice for an inference pod:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: small-llm-inference
     labels:
       app: small-llm-inference
   spec:
     restartPolicy: Always
     containers:
       - name: server
         image: nvcr.io/nvidia/tritonserver:24.08-py3
         args:
           - "tritonserver"
           - "--model-repository=/models"
         ports:
           - containerPort: 8000
             name: http
         resources:
           limits:
             nvidia.com/mig-2g.20gb: 1
         volumeMounts:
           - name: models
             mountPath: /models
     volumes:
       - name: models
         persistentVolumeClaim:
           claimName: model-repo
   ```

5. Check what the node advertises:

   ```bash
   kubectl describe node gpu-node-01 | grep -A8 "Allocatable"
   ```

   Representative output:

   ```
   Allocatable:
     cpu:                     224
     memory:                  2063412Mi
     nvidia.com/gpu:          7
     nvidia.com/mig-2g.20gb:  3
     pods:                    110
   ```

**Questions**

- **Q6.1** The 8B FP8 model from Exercise 3 (~8 GB of weights) has to serve 20 independent tenants. Compare one tenant per full H100 with MIG `2g.20gb` or `1g.10gb`. What do you gain, and what are the risks?
- **Q6.2** Why does MIG give stronger isolation than time-slicing or simply running several processes on one GPU?
- **Q6.3** Why would you **not** enable MIG on GPUs that run a multi-node training job?
- **Q6.4** The node shows `nvidia.com/gpu: 7` plus `nvidia.com/mig-2g.20gb: 3`. Explain the arithmetic.

---

## Exercise 7 — Scaling the infrastructure, not just the GPUs: BlueField DPU offload

When you scale to many tenants and nodes, the host CPU picks up infrastructure work:

- virtual switching (OVS)
- encryption (IPsec/TLS)
- storage virtualization (NVMe-oF initiators)
- firewalling and telemetry

That work competes with data loading and inference pre- and post-processing. The BlueField DPU (Arm cores + ConnectX + accelerators, programmed through DOCA) moves those services onto the NIC. It also puts them in a separate trust domain that the host OS cannot tamper with.

### Steps

1. Read the BlueField offload and isolation article (link above). For each service below, mark whether it runs on the host or on the DPU in a DPU-based design:
   - OVS data path
   - Tenant firewall / micro-segmentation
   - NVMe-oF storage initiator (presented to the host as a local NVMe device)
   - The AI framework (PyTorch / Triton)
   - Telemetry collection
2. Estimate the reclaimed CPU. Assume software OVS + IPsec at 200 Gb/s takes about 12 cores per node on a 112-core host:
   - What percentage of cores do you reclaim?
   - Across a 32-node SU, how many cores is that?
3. Read the network I/O article (link above). Draw the data path of a GPU receiving training data:
   - **(a)** classic path: NIC → system memory → CPU copy → GPU
   - **(b)** GPUDirect RDMA path: NIC → GPU memory over PCIe
4. Link this to Exercise 1: the DGX B200 places 2 × BlueField-3 on the storage/in-band side.

**Questions**

- **Q7.1** Give two reasons, other than performance, why a multi-tenant inference cloud places security policy enforcement on the DPU.
- **Q7.2** How many cores do you reclaim in step 2, as a percentage and across the SU?
- **Q7.3** What do GPUDirect RDMA and GPUDirect Storage remove from the data path, and which bottleneck appears when you scale out without them?

---

## Exercise 8 — Capstone: choose the architecture for four use cases

Physical constraints apply to every design: power, cooling and rack space. Use about 10.2 kW per DGX H100 and about 14.3 kW per DGX B200 for the compute nodes. Treat these as maximum figures and check facility planning against the datasheets.

### Steps

1. **Power for one SU.** Compute the compute-node power for 32 × DGX B200. Then compute how many 40 kW racks that needs, assuming the facility allows **at most 2 systems per 40 kW rack**.
2. For each scenario, write down:
   - the scaling axis (or axes)
   - node type
   - fabric
   - partitioning
   - one risk

   | # | Scenario |
   |---|---|
   | A | Pre-train a 70B-parameter LLM on 10T tokens within a quarter |
   | B | Fine-tune (LoRA) an 8B model weekly on a 50 GB proprietary dataset |
   | C | Serve a 70B model to an interactive chatbot with a p95 latency SLO, with traffic peaking 5× during business hours |
   | D | Internal platform for 40 data-science teams running notebooks and small experiments |

3. For scenario C, answer this: when traffic grows, do you scale up (bigger TP) or out (more replicas)?

**Questions**

- **Q8.1** What is the power of one 32-node DGX B200 SU, and how many racks does it need under the stated constraint?
- **Q8.2** Give your design for scenario A.
- **Q8.3** Give your design for scenario B.
- **Q8.4** Give your design for scenario C, including the scale-up vs scale-out answer.
- **Q8.5** Give your design for scenario D.

---

## Answers

<details>
<summary>Click to expand the answers</summary>

### Exercise 0

- **Q0.1** NVLink 4: 450 GB/s ÷ 50 GB/s = **9×**. NVLink 5: 900 GB/s ÷ 50 GB/s = **18×** per direction.
- **Q0.2** **Tensor parallelism** exchanges activations at every layer, many times per step, and is very sensitive to bandwidth and latency. It stays inside the NVLink domain. **Data parallelism** (one gradient all-reduce per step, which can overlap with backward compute) and **pipeline parallelism** (point-to-point activations between stages) tolerate the ~10× slower fabric, so they go across nodes.
- **Q0.3** If the model fits on one GPU, a single request never needs to cross the network. Adding nodes increases throughput (more replicas), but it does nothing for per-request latency. Splitting the model across nodes would actually *add* network hops to every token. For latency you scale up: a faster GPU, lower precision such as FP8, a better batching or serving engine. You scale out only to absorb more concurrent load.

### Exercise 1

- **Q1.1** 8 × 400 Gb/s = **3.2 Tb/s**, which is 400 GB/s per direction. One NIC per GPU, placed on the same PCIe switch, gives every GPU a short GPUDirect RDMA path that does not cross the CPU or the inter-socket link. It also maps one to one onto fabric rails, so per-GPU collective traffic never competes for a shared NIC.
- **Q1.2** For example, 405B FP8 inference (~405 GB of weights plus KV cache) fits comfortably in one DGX B200 (1,440 GB), with tensor parallelism over NVLink. On DGX H100 (640 GB) it is tight, and long contexts or high concurrency push you to two nodes. Two nodes means pipeline parallelism over the network, plus multi-node serving complexity.
- **Q1.3** On DGX H100 the storage/in-band side uses dual-port ConnectX-7 NICs. On DGX B200 it uses BlueField-3 DPUs, which can offload and isolate storage, networking and security services (Exercise 7).

### Exercise 2

- **Q2.1** `NV18` to *every* peer means all-to-all, full-bandwidth connectivity: each GPU's 18 links go to the NVSwitch chips, not to one neighbor. In a point-to-point mesh, the links would be divided among peers, so any one pair would get only a fraction of the bandwidth. NVSwitch makes the 8 GPUs behave as one uniform NVLink domain.
- **Q2.2** 18 × 26.562 GB/s ≈ **478 GB/s** in this per-direction raw link-rate report. The datasheet's 900 GB/s is the *bidirectional* figure (~450 GB/s each way, after encoding and protocol overhead). The CLI number and the marketing number count different things. Always ask: per direction or bidirectional?
- **Q2.3** The traffic leaves GPU0's PCIe switch, goes up through the CPU root complex, crosses the inter-socket link (`SYS`) and comes back down to NIC1. That adds latency, consumes inter-socket bandwidth, and can stop GPUDirect RDMA from running at full speed. NCCL normally picks the topology-local NIC by itself. Misconfigured `NCCL_IB_HCA` settings or container device mappings can break that.
- **Q2.4** Data-loader processes that run on the far NUMA node read and copy across the inter-socket link before reaching the GPU. Pinning loaders to the GPU's local NUMA node (`numactl`, or the launcher's binding options) keeps host-to-device copies local, which keeps the GPU fed.

### Exercise 3

- **Q3.1** About 16 GB of weights plus KV cache. That is far below 80 GB, so a whole H100 is mostly idle memory. A `2g.20gb` MIG slice is tight, `3g.40gb` is comfortable, and FP8 (~8 GB) fits `1g.10gb`/`1g.20gb` for low concurrency. The deciding factors are KV cache size (context length × concurrency) and the throughput and latency each tenant needs, because MIG also divides compute.
- **Q3.2** In theory 2 × 80 GB = 160 GB holds 140 GB of weights, but that leaves almost nothing for KV cache, activations and CUDA context. **TP=4** (320 GB) leaves room for a large KV cache, which means bigger batches and longer contexts. It also reduces per-token latency, because each GPU does a quarter of the matmul work. NVLink makes the extra all-reduces cheap.
- **Q3.3** DGX H100 (640 GB): the weights fit with ~235 GB of headroom spread over 8 GPUs. That works for modest contexts and concurrency. Heavy long-context traffic exhausts the KV budget, which pushes you to two nodes or to FP4/quantized KV. DGX B200 (1,440 GB): fits in one node with about 1 TB of headroom. That is the simpler and lower-latency design.
- **Q3.4** Training time is set by total FLOPs (≈ 6 × parameters × tokens). For 70B × 10T tokens that is about 4.2 × 10²⁴ FLOPs. Even at petaflops per GPU that takes thousands of GPU-months, so you scale out with data parallelism to reach a calendar-time target, whatever the memory footprint.

### Exercise 4

- **Q4.1**
  - **Leaf layer, 1 SU:** each rail connects 32 NIC ports. A 64-port leaf split 32 down / 32 up serves exactly one rail of one SU. 8 rails → **8 leaves per SU**, and **256** node-to-leaf cables.
  - **Spine layer, 4 SUs:** uplinks = 4 × 8 × 32 = **1,024**. 1,024 / 64 = **16 spines**. Leaves = 32.
  - **Cables, 4 SUs:** node cables = 4 × 256 = 1,024, plus leaf-to-spine = 1,024, for about **2,048** compute-fabric links. Node-side ports often use twin-port OSFP transceivers and splitter cables, so the physical cable count can differ. Check the RA's BOM.
- **Q4.2** NCCL runs collectives per rail: GPU *i* on every node talks to GPU *i* on the others through NIC *i*. With rail optimization, all of that traffic within an SU goes through **one** leaf (1 switch hop), never through the spines. Across SUs it takes 3 hops and stays on predictable paths. Fewer hops means lower latency and less ECMP/adaptive-routing contention. Intra-node data movement between rails happens over NVLink, which is much faster.
- **Q4.3** In synchronous training, every rank waits for the slowest all-reduce. Any oversubscription becomes congestion that directly stretches step time for the whole job. Inference replicas are mostly independent, request/response and north-south. Their per-request traffic is small, and a busy link affects only some requests. So oversubscription is a reasonable cost trade-off there.
- **Q4.4** (1) **Compute fabric** (InfiniBand NDR, rail-optimized), which carries the all-reduce. (2) **Storage fabric**. (3) **In-band management** (Ethernet: cluster services, job scheduling, user access). (4) **Out-of-band management** (BMC/IPMI/Redfish).

### Exercise 5

- **Q5.1** That NIC's rail runs at half speed. Ring and tree all-reduce move at the pace of the slowest link, so the **whole** 128-node collective (1,024 GPUs) slows toward that rate. Every synchronous step is gated by it, which can cost a large fraction of throughput on the entire job. Find and fix degraded links before the job starts: reseat or replace the transceiver or cable, check with `mlxlink`, and use UFM/fabric health reports.
- **Q5.2** `algbw` = bytes / time, as the application sees it. `busbw` scales that by the amount of data each link actually carries for the collective (2(n−1)/n for all-reduce). The result can be compared directly with link speed and stays roughly constant as rank count changes. That is why `busbw` is the hardware utilization metric.
- **Q5.3** Step 4 check: 180.42 × 30 / 16 = **338.3 GB/s**, which matches the `busbw` column.
  - **Intra-node:** limited by NVLink/NVSwitch, ~450 GB/s per direction per GPU on H100. Measured values approach that, and are higher with NVLink SHARP (NVLS) offload.
  - **Two nodes:** limited by the 8 × 50 GB/s = 400 GB/s per-direction scale-out bandwidth, minus protocol overhead. ~340 GB/s is a healthy fraction of that ceiling.
- **Q5.4** The average includes tiny messages (8 bytes and up), which are latency-bound and reach only a few GB/s. Acceptance criteria should use the large-message plateau, compared with a known-good reference for the same topology and NCCL version.

### Exercise 6

- **Q6.1** One tenant per full H100 needs 20 GPUs (3 nodes), mostly idle. With `2g.20gb` you get 3 tenants per GPU → 7 GPUs. With `1g.10gb` you get 7 per GPU → 3 GPUs, if FP8 plus a small KV cache fits in 10 GB. You gain about a 3–7× reduction in hardware, with hardware-isolated memory and compute per tenant. The risks:
  - Each slice has only a fraction of the SMs and bandwidth, so latency per request rises and burst headroom is fixed.
  - A KV cache that grows with context length can overflow a small slice.
  - Repartitioning needs the GPU to be idle.
- **Q6.2** MIG partitions at the hardware level: dedicated SMs, L2 cache slices, memory controllers and DRAM ranges, and separate error containment. One tenant cannot use up another's memory bandwidth or crash the others. Time-slicing shares all of these over time, so tenants affect each other's latency and there is no memory isolation.
- **Q6.3** Large training wants the full GPU's compute, memory and NVLink bandwidth. MIG instances do not support peer-to-peer NVLink between instances, so they cannot take part in the scale-up domain that tensor parallelism and fast intra-node collectives need. MIG is a tool for many small jobs, not for one huge job.
- **Q6.4** The node has 8 GPUs. GPU 0 is partitioned into three `2g.20gb` instances, which are advertised as `nvidia.com/mig-2g.20gb: 3`. The 7 non-MIG GPUs remain whole `nvidia.com/gpu` resources. That is how the `mixed` strategy exposes each profile separately.

### Exercise 7

- **Q7.1** (1) **Isolation and trust:** policy runs on a separate processor, outside the host OS. A compromised tenant workload or host kernel cannot switch off the firewall or the encryption. (2) **Consistency and operations:** the provider manages the DPU image and policy independently of tenant host images, which also allows bare-metal tenancy with provider-enforced controls. Other valid answers include line-rate encryption and telemetry without any changes on the tenant side.
- **Q7.2** 12 / 112 ≈ **10.7%** of host cores per node. Across a 32-node SU, **384 cores** return to data loading, pre-processing and serving. Host placement: only the AI framework stays on the host. OVS, the firewall, the NVMe-oF initiator and telemetry move to the DPU.
- **Q7.3** They remove the CPU bounce buffer and the extra copy through system memory. Data goes NIC ↔ GPU memory (GPUDirect RDMA) or storage ↔ GPU memory (GPUDirect Storage) directly over PCIe. Without them, scaling out makes the CPU and system memory bandwidth the bottleneck: more nodes and NICs feed more traffic through host memory copies, CPU utilization climbs, and the GPUs wait for data.

### Exercise 8

- **Q8.1** 32 × 14.3 kW ≈ **458 kW** for compute nodes alone. Switches, storage, management and cooling overhead come on top. At 2 systems per 40 kW rack (2 × 14.3 = 28.6 kW): **16 racks**. Facility power and cooling, not floor space, are often what limits the scaling plan.
- **Q8.2** Scenario A:
  - **Axes:** scale up plus scale out.
  - **Nodes:** multiple SUs of DGX B200 or H100, 3D parallelism (TP inside the node over NVLink, PP and DP across nodes).
  - **Fabric:** non-blocking rail-optimized InfiniBand NDR (or Spectrum-X), plus a high-throughput storage fabric for checkpoints.
  - **Partitioning:** no MIG.
  - **Risks:** a single degraded link slows the whole job (Exercise 5). Checkpointing frequency and storage bandwidth set how much work a node failure costs.
- **Q8.3** Scenario B:
  - **Axis:** scale up only.
  - **Nodes:** LoRA on 8B fits on 1–2 GPUs, so one node (or part of one) is enough. No cross-node fabric is needed. Schedule it as a periodic job on a shared cluster.
  - **Storage:** local NVMe caching of the 50 GB dataset, or GPUDirect Storage.
  - **Partitioning:** whole GPUs for the job.
  - **Risk:** over-provisioning, that is, reserving a SuperPOD slice for a job that needs a couple of GPUs.
- **Q8.4** Scenario C:
  - **Replica shape:** each replica uses scale up, with TP=4–8 inside one node over NVLink (FP8 on H100, or a smaller TP on B200). That sets the per-token latency.
  - **Growth:** traffic growth is handled with **scale out**: more replicas behind a load balancer, with autoscaling (for example Kubernetes HPA/KEDA on queue depth or GPU utilization) to follow the 5× daily peak.
  - **Fabric:** east-west inference traffic is light, so an oversubscribed Ethernet fabric is acceptable.
  - **Risks:** cold-start time to load 140 GB of weights when scaling out, which you mitigate with warm pools and fast model storage. Also KV cache exhaustion at peak.
  - **Rule:** raise TP only to meet latency, add replicas to meet throughput.
- **Q8.5** Scenario D:
  - **Axis:** partition and offload.
  - **Nodes:** H100 nodes in a Kubernetes cluster with the GPU Operator and MIG (`mixed` strategy, small profiles for notebooks), plus quotas per team namespace.
  - **Offload:** BlueField DPUs for tenant network isolation and storage virtualization.
  - **Partitioning:** keep some whole GPUs for teams that occasionally need full-GPU experiments.
  - **Risks:** MIG layout fragmentation (repartitioning needs idle GPUs) and noisy-neighbor storage I/O.

</details>