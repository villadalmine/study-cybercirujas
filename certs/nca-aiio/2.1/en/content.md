# 2.1 Identify Hardware Requirements for Specific AI Training Task Use Cases

## 1. Motivation: why hardware selection is an architecture decision

In AI training, hardware choices do not degrade gracefully. If a web service is undersized, it gets slower. If a training cluster is undersized in the wrong dimension, three things can happen:

- **It does not run at all.** The model, gradients and optimizer state do not fit in aggregate GPU memory, so you get `CUDA out of memory` on step 0.
- **It runs at a fraction of its potential.** GPUs sit idle waiting on all-reduce over an undersized fabric, or waiting on a data loader starved by storage or CPU. Model FLOPs Utilization (MFU) drops from about 40–50% to 10–15%, so a 3-week run becomes a 3-month run.
- **It runs and then dies repeatedly.** Thermal or power throttling, flapping InfiniBand links, ECC errors or NVLink faults kill a synchronous job that spans 1,000 GPUs. Because every rank waits on the slowest one, a single bad component stops the whole job.

The NCA-AIIO exam expects you to map a **use case** (pre-training a foundation model, fine-tuning, small-scale experimentation, distributed multi-node training) to a **hardware profile**. That profile has seven parts:

1. GPU type and count
2. GPU memory
3. Intra-node interconnect (NVLink/NVSwitch)
4. Inter-node fabric (InfiniBand / Spectrum-X Ethernet, ConnectX, rail-optimized topology)
5. Storage and I/O path (GPUDirect Storage, NVMe, parallel file systems)
6. Infrastructure offload (BlueField DPU)
7. Facility constraints (power, cooling, rack density)

The mental model to keep throughout: **a training job is a pipeline of four rate-limited resources: compute, memory capacity/bandwidth, communication and I/O.** Hardware sizing means finding the binding constraint for a given workload and buying past it.

---

## 2. Characterizing the workload first

Before picking hardware, quantify four numbers for the workload.

### 2.1 Memory footprint (does it fit?)

For mixed-precision training with Adam, the standard per-parameter accounting is:

| Component | Precision | Bytes/param |
|---|---|---|
| Model weights (working copy) | BF16/FP16 | 2 |
| Gradients | BF16/FP16 | 2 |
| Master weights | FP32 | 4 |
| Adam first moment (m) | FP32 | 4 |
| Adam second moment (v) | FP32 | 4 |
| **Total (excluding activations)** | | **~16** |

Activations come on top. They scale with `batch × sequence length × hidden size × layers` and are reduced with activation checkpointing, which trades about 30% extra compute for memory.

| Model size | Weights+grads+optimizer (16 B/param) | Minimum H100 80GB GPUs (state only, fully sharded) | Realistic with activations/headroom |
|---|---|---|---|
| 1B | 16 GB | 1 | 1 |
| 7B | 112 GB | 2 | 8 (one node) |
| 13B | 208 GB | 3 | 8–16 |
| 70B | 1.12 TB | 14 | 64+ (8+ nodes) |
| 405B | 6.5 TB | 81 | 512–1,024+ |

Key consequences:

- **Full fine-tuning** of a 7B model does not fit on a single 80 GB GPU with plain data parallelism. It needs sharding (ZeRO-3 / FSDP) across the 8 GPUs of one node, and NVLink/NVSwitch makes that sharding cheap.
- **Parameter-efficient fine-tuning** (LoRA/QLoRA) freezes the base weights and only trains small adapters. A 7B QLoRA job (4-bit base weights at about 3.5 GB) fits on a single GPU, and even a MIG slice can work for small experiments.
- **Pre-training 70B+** is by definition a multi-node problem. The inter-node fabric becomes a first-class requirement, not an option.

### 2.2 Compute budget (how long?)

The standard approximation for dense transformer training is:

```
Training FLOPs ≈ 6 × N (parameters) × D (tokens)
```

Worked example: a 70B model trained on 2T tokens.

```
FLOPs      = 6 × 70e9 × 2e12           = 8.4e23
H100 BF16  = 989 TFLOPS dense (SXM)
Effective  = 989e12 × 0.40 MFU         ≈ 3.96e14 FLOP/s per GPU
GPU-secs   = 8.4e23 / 3.96e14          ≈ 2.12e9 s
GPU-hours  ≈ 589,000
On 1,024 H100 GPUs                     ≈ 575 h ≈ 24 days
```

That calculation is the business case for an AI factory. Two levers change the result:

- Moving to **B200** (higher dense BF16 throughput, FP8 via the second-generation Transformer Engine) cuts the GPU count or wall time substantially.
- Raising MFU is mostly a network and I/O problem, not a GPU problem.

### 2.3 Communication volume (how chatty?)

With data parallelism, every step all-reduces the full gradient. A ring all-reduce moves about `2 × (n−1)/n × S` bytes per GPU. For a 7B model with BF16 gradients:

```
S          = 7e9 × 2 B = 14 GB per step
Per GPU    ≈ 2 × 14 GB = ~28 GB transferred per step
```

How long that takes depends on the link:

- **Inside a DGX H100**, NVLink 4 gives each GPU 900 GB/s bidirectional bandwidth, so this costs tens of milliseconds.
- **Across nodes over PCIe-attached 100 GbE**, it would take seconds per step, and the GPUs would idle most of the time.

Tensor parallelism is far chattier. It exchanges activations several times **per layer**. That is why tensor parallelism is kept inside the NVLink domain (8 GPUs on HGX/DGX, 72 GPUs on GB200 NVL72), while pipeline and data parallelism span the InfiniBand fabric.

### 2.4 I/O profile (can we feed it and save it?)

- **Data ingest.** Tokenized text is small and sequential. Vision and video datasets are large and random-read heavy, and decoding them is CPU-intensive. NVIDIA DALI can move decode to the GPU.
- **Checkpointing.** Weights plus optimizer state are about 14 B/param, so a 70B checkpoint is about 1 TB.
  - At 10 GB/s aggregate write that is about 100 s of stall per checkpoint.
  - At 100 GB/s it is about 10 s.
  - At large scale you checkpoint often because the mean time between failures (MTBF) of a 1,000-GPU job is measured in hours to days. Checkpoint bandwidth therefore directly sets goodput.

---

## 3. GPU selection

### 3.1 Data center GPU comparison (training-relevant specs)

| GPU | Form factor | Memory | Mem BW | NVLink BW / GPU | Dense BF16 | FP8 | TDP | Typical training use |
|---|---|---|---|---|---|---|---|---|
| A100 80GB | SXM4 | 80 GB HBM2e | ~2.0 TB/s | 600 GB/s (NVLink 3) | 312 TFLOPS | n/a | 400 W | Legacy fleets, mid-size training |
| H100 | SXM5 | 80 GB HBM3 | 3.35 TB/s | 900 GB/s (NVLink 4) | ~989 TFLOPS | ~1,979 TFLOPS | up to 700 W | Mainstream LLM training |
| H100 | PCIe | 80 GB HBM2e | ~2.0 TB/s | NVLink bridge (pairs only) | lower (reduced clocks/TDP) | lower | 300–350 W | Fine-tuning, inference, enterprise servers |
| H200 | SXM5 | 141 GB HBM3e | 4.8 TB/s | 900 GB/s (NVLink 4) | ~989 TFLOPS | ~1,979 TFLOPS | up to 700 W | Memory-bound training, long context |
| B200 | SXM (HGX/DGX B200) | ~180 GB HBM3e | ~8 TB/s | 1.8 TB/s (NVLink 5) | ~2.25 PFLOPS | ~4.5 PFLOPS | ~1,000 W | Frontier training, FP8/FP4 |
| GB200 | Superchip (NVL72 rack) | ~186 GB HBM3e per GPU | ~8 TB/s | 1.8 TB/s (NVLink 5, 72-GPU domain) | similar to B200 | similar | liquid-cooled | Trillion-parameter training/inference |

> Numbers are rounded from NVIDIA datasheets. Sparse figures are 2× the dense values. Always quote **dense** numbers when sizing training. The exam focuses on relative positioning (which GPU and why), not the decimals.

### 3.2 Decision factors

| Use case | Binding constraint | Recommended profile | Why |
|---|---|---|---|
| Foundation model pre-training (10B–1T+) | Compute + inter-GPU communication | DGX/HGX B200 or H100/H200 SXM, DGX SuperPOD, NDR/XDR InfiniBand, rail-optimized | Needs the NVLink domain for tensor parallelism and a non-blocking fabric for data/pipeline parallelism |
| Long-context or large-batch training | HBM capacity and bandwidth | H200 / B200 | 141–180+ GB per GPU reduces sharding and recomputation |
| Full fine-tuning 7B–70B | Memory (optimizer state) | 1–8 nodes of HGX H100/H200 | FSDP/ZeRO-3 inside NVSwitch is cheap; small multi-node jobs tolerate fewer rails |
| LoRA/QLoRA fine-tuning | Memory (base weights only) | Single H100/L40S/PCIe GPU, or a MIG slice for small models | Optimizer state is tiny; no fabric needed |
| Experimentation / notebooks / CI for ML code | Cost, sharing | MIG partitions (e.g. `1g.10gb`, `3g.40gb`) or vGPU | Hardware isolation lets many users share one GPU |
| Computer vision training on large image/video sets | Data pipeline (decode, I/O) | SXM GPUs plus strong CPU and storage, DALI, GPUDirect Storage | GPU math is rarely the bottleneck; decode and reads are |
| Trillion-parameter MoE models | All-to-all communication | GB200 NVL72 | Expert parallelism wants a 72-GPU NVLink domain (~130 TB/s aggregate) |

### 3.3 SXM vs PCIe: the trade-off that shows up in every exam

| Aspect | SXM (HGX/DGX) | PCIe |
|---|---|---|
| GPU-to-GPU path | NVLink + NVSwitch, all-to-all, 900 GB/s–1.8 TB/s per GPU | PCIe Gen5 x16 (~64 GB/s per direction); optional 2-GPU NVLink bridge |
| Power envelope | 700–1,000 W per GPU, full clocks | 300–350 W, lower clocks |
| Multi-GPU scaling | Near-linear for tensor parallelism inside the node | Poor for tensor parallelism; fine for independent jobs |
| Cooling | High-airflow chassis or liquid | Standard server airflow |
| Cost / flexibility | Higher, fixed 4/8-GPU baseboard | Lower, fits mainstream servers |
| Best for | Distributed training | Inference, fine-tuning, mixed enterprise workloads |

---

## 4. The reference node: DGX H100 and DGX B200

Understanding what goes into a DGX tells you what a "balanced" training node is. Every component is sized so that it is not the bottleneck for the GPUs.

### 4.1 DGX H100 component breakdown

| Component | Specification | Role in training |
|---|---|---|
| GPUs | 8× H100 SXM5, 80 GB HBM3 each (640 GB total) | Compute |
| GPU interconnect | 4× third-generation NVSwitch; 18 NVLink 4 links per GPU, 900 GB/s per GPU | All-to-all intra-node, TP/FSDP |
| CPUs | 2× Intel Xeon Platinum 8480C, 56 cores each (112 cores) | Data loading, preprocessing, launching kernels |
| System memory | 2 TB DDR5 | Data loader buffers, pinned memory, CPU offload |
| Compute fabric | 8× single-port ConnectX-7 (exposed via 4 OSFP ports), up to 400 Gb/s InfiniBand/Ethernet each | One NIC per GPU, the "rails" |
| Storage / in-band network | 2× dual-port ConnectX-7 | Storage fabric and in-band management |
| Out-of-band | BMC with 1 GbE | Remote power, sensors, firmware |
| OS storage | 2× 1.92 TB NVMe M.2 (RAID 1) | OS |
| Internal data cache | 8× 3.84 TB NVMe U.2 (~30 TB) | Local dataset cache / scratch |
| Power | ~10.2 kW max | Facility planning |
| Peak performance | ~32 PFLOPS FP8 | |

### 4.2 DGX B200 differences

| Component | DGX B200 |
|---|---|
| GPUs | 8× B200, ~1,440 GB HBM3e total |
| NVLink | Fifth generation, 1.8 TB/s per GPU, 14.4 TB/s aggregate, 2 NVSwitch chips |
| Performance | ~72 PFLOPS FP8 training, ~144 PFLOPS FP4 inference |
| CPUs | 2× Intel Xeon Platinum 8570 (112 cores total) |
| System memory | 2 TB, configurable to 4 TB |
| Compute fabric | 4 OSFP ports serving 8× single-port ConnectX-7 VPI (400 Gb/s InfiniBand/Ethernet) |
| Storage/in-band | 2× dual-port BlueField-3 DPUs |
| Power | ~14.3 kW max |

The architectural pattern to remember: **one 400 Gb/s NIC per GPU**. Each GPU has a PCIe switch path to "its" NIC, so GPUDirect RDMA moves data GPU→NIC→wire without touching CPU memory. Remove that 1:1 ratio and inter-node all-reduce bandwidth per GPU drops proportionally.

### 4.3 Balanced-node heuristics for non-DGX (HGX OEM) builds

| Resource | Heuristic for training nodes |
|---|---|
| CPU cores | ≥ 8–14 physical cores per GPU (data loader workers, NCCL proxy threads) |
| System RAM | ≥ 2× total GPU memory (pinned buffers, page cache, CPU offload) |
| Compute NICs | 1× 400 Gb/s (NDR/Spectrum-X) per GPU, on the same PCIe switch as the GPU |
| Storage NICs | Separate 2×200–400 Gb/s for the storage fabric |
| Local NVMe | Enough to cache the hot dataset shard plus checkpoint staging |
| PCIe | Gen5, with ACS/IOMMU configured so peer-to-peer (P2P) is not forced through the root complex |

---

## 5. Interconnect: NVLink, NVSwitch and the scale-out fabric

### 5.1 Two networks, two jobs

```
                   ┌─────────────────────── Node (DGX/HGX) ───────────────────────┐
                   │  GPU0 GPU1 GPU2 GPU3 GPU4 GPU5 GPU6 GPU7                      │
 Scale-up domain → │    \___|____|____|____|____|____|___/   NVSwitch (all-to-all) │
                   │    |    |    |    |    |    |    |    |  PCIe Gen5 switches   │
                   │  NIC0 NIC1 NIC2 NIC3 NIC4 NIC5 NIC6 NIC7  ConnectX-7 400G     │
                   └────│────│────│────│────│────│────│────│───────────────────────┘
 Scale-out fabric →  rail0 rail1 rail2 ... rail7   (each rail = its own leaf switch)
```

| Dimension | NVLink/NVSwitch (scale-up) | InfiniBand / Spectrum-X (scale-out) |
|---|---|---|
| Scope | Inside a node (8 GPUs) or a rack (NVL72) | Across nodes, thousands of GPUs |
| Bandwidth per GPU | 900 GB/s (NVLink 4), 1.8 TB/s (NVLink 5) | 400 Gb/s = 50 GB/s per NIC (NDR), 800 Gb/s (XDR) |
| Latency | Sub-microsecond, memory-semantic | Microseconds, RDMA |
| Parallelism carried | Tensor parallel, expert parallel, FSDP shards | Data parallel, pipeline parallel |
| Special features | NVLink SHARP (NVLS) in-switch reductions | SHARP in-network reductions (Quantum switches), adaptive routing, congestion control |

Note the units: NVLink bandwidth is quoted in **GB/s (bytes)**, network bandwidth in **Gb/s (bits)**. 900 GB/s versus 50 GB/s is an 18× gap, and that gap is exactly why tensor parallelism stays inside the NVLink domain.

### 5.2 Rail-optimized topology (DGX SuperPOD)

In the DGX SuperPOD reference architecture:

- The compute fabric is **rail-optimized**. NIC *i* of every node in a Scalable Unit (SU) connects to the same leaf switch, the "rail *i*" leaf.
- NCCL's ring and tree algorithms keep most traffic on a single rail, so it goes through one switch hop.
- Spine switches connect the rails and the SUs in a full fat-tree that is non-blocking.

The B200 SuperPOD reference architecture builds on **Scalable Units of 32 DGX B200 systems (256 GPUs)**, using NDR 400 Gb/s Quantum-2 InfiniBand for compute. It runs separate fabrics for:

- Compute (east-west, GPU-to-GPU)
- Storage (high-performance parallel file system)
- In-band management (Kubernetes/Slurm control, user access)
- Out-of-band management (BMCs, switch management)

Why separate fabrics: checkpoint bursts and dataset reads must not cause congestion on the latency-sensitive collective traffic of the compute fabric.

### 5.3 InfiniBand vs Ethernet for AI

| Aspect | InfiniBand (Quantum-2/X800) | Spectrum-X Ethernet | Generic Ethernet (RoCE, no tuning) |
|---|---|---|---|
| Transport | Native RDMA, credit-based lossless | RoCEv2 with adaptive routing, congestion control via SuperNIC + Spectrum-4 | RoCEv2 requiring PFC/ECN tuning |
| In-network compute | SHARP v3 | n/a (NCCL-level optimizations) | n/a |
| Tail latency under load | Lowest, most predictable | Close to InfiniBand for AI flows | Unpredictable (ECMP hash collisions on elephant flows) |
| Operational familiarity | Separate subnet manager (UFM/OpenSM) | Ethernet tooling, multi-tenant cloud friendly | Familiar but poor AI performance |
| Typical choice | Dedicated training clusters (SuperPOD) | AI clouds, multi-tenant Ethernet shops | Small clusters, inference, storage |

---

## 6. I/O path: GPUDirect, storage and the DPU

### 6.1 GPUDirect family

| Technology | What it removes | Training impact |
|---|---|---|
| GPUDirect P2P | Copy through host memory between GPUs in a node | Fallback path when NVLink is absent (PCIe) |
| GPUDirect RDMA | Bounce buffer in CPU memory for NIC↔GPU | NCCL inter-node collectives at line rate, low CPU usage |
| GPUDirect Storage (GDS) | Bounce buffer for NVMe/NVMe-oF/parallel FS↔GPU | Faster data loading and checkpointing, freed CPU |

Without GDS, a read goes `storage → NIC → CPU DRAM (bounce) → PCIe → GPU`. With GDS, the DMA engine moves it `storage → NIC/NVMe → GPU` directly. That cuts latency, raises bandwidth and frees CPU cycles for the data loader.

### 6.2 Storage tiers for training

| Tier | Example | Purpose | Sizing driver |
|---|---|---|---|
| GPU HBM | 80–180 GB/GPU | Working set | Model/optimizer/activations |
| Host RAM | 2 TB/node | Page cache, pinned buffers, CPU offload | Data loader prefetch |
| Local NVMe | ~30 TB/node (DGX H100) | Dataset cache, checkpoint staging | Hot dataset shard per node |
| Shared high-performance file system | Certified SuperPOD storage partners (parallel FS / NVMe-oF) | Datasets, checkpoints shared across all nodes | Aggregate read GB/s per GPU, checkpoint write bursts |
| Object / capacity storage | S3-compatible | Raw data lake, archival checkpoints | Capacity, cost |

### 6.3 BlueField DPU: offloading the infrastructure tax

A BlueField-3 DPU combines a 400 Gb/s ConnectX network engine, Arm cores and hardware accelerators. On a training node it offloads and isolates infrastructure work from the host CPUs:

- **Networking:** OVS/virtual switching, overlay encapsulation (VXLAN/Geneve), telemetry. Matters for multi-tenant AI clouds.
- **Storage:** NVMe-oF initiator emulation (SNAP), so the host sees local NVMe while data comes from the network; storage encryption/compression.
- **Security:** a separate trust domain. The infrastructure control plane runs on the DPU, isolated from the tenant's host OS, and enforces firewall/microsegmentation policy (Zero Trust) at line rate.

Why it matters for sizing: in a multi-tenant cluster, running OVS, storage initiators and security agents on the host x86 cores steals cycles from the data loader. Offloading them to the DPU gives cores back to the workload and isolates the tenant from the infrastructure. That is why DGX B200 ships with BlueField-3 on the storage/in-band path.

---

## 7. Power, cooling and facility

| System | Approximate max power | Cooling | Rack implication |
|---|---|---|---|
| DGX H100 | ~10.2 kW | Air | Typically 2–4 systems per rack, depending on facility kW/rack |
| DGX B200 | ~14.3 kW | Air | Often 2–4 per rack; high-density rack design required |
| GB200 NVL72 | ~120 kW per rack | Direct liquid cooling | Liquid cooling infrastructure mandatory |

Engineering consequences:

- **Power drives cluster topology.** If your data center provides 15 kW per rack, a 32-node SU spans many racks, and cable lengths push you from copper DACs to optics.
- **Thermal headroom is performance.** GPUs under thermal or power capping lower their clocks. In a synchronous job, one throttled GPU slows every rank.
- **Redundant PSUs (N+N or N+1)** are standard. Losing a PSU feed without redundancy power-caps or stops the node.

---

## 8. Kubernetes implementation: expressing hardware requirements

In a Kubernetes-based AI platform, the hardware profile has to be **discoverable, schedulable and verifiable**. NVIDIA's GPU Operator and Network Operator are the standard building blocks.

### 8.1 GPU Operator Helm values (training cluster)

```yaml
# values-gpu-operator.yaml
# Install: helm install gpu-operator nvidia/gpu-operator -n gpu-operator --create-namespace -f values-gpu-operator.yaml
nfd:
  enabled: true
driver:
  enabled: true
  rdma:
    enabled: true
    useHostMofed: false
toolkit:
  enabled: true
devicePlugin:
  enabled: true
gfd:
  enabled: true
dcgm:
  enabled: true
dcgmExporter:
  enabled: true
  serviceMonitor:
    enabled: true
mig:
  strategy: mixed
migManager:
  enabled: true
  config:
    name: custom-mig-config
    default: all-disabled
gds:
  enabled: true
validator:
  plugin:
    env:
      - name: WITH_WORKLOAD
        value: "true"
```

What each piece does:

- `driver.rdma.enabled: true` loads `nvidia-peermem`, which GPUDirect RDMA requires.
- `gds.enabled: true` deploys the `nvidia-fs` kernel module for GPUDirect Storage.
- `gfd` (GPU Feature Discovery) labels each node with GPU model, memory, MIG capability and CUDA versions. The scheduler uses those labels to match workloads to hardware.

### 8.2 MIG profiles for the experimentation tier

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: custom-mig-config
  namespace: gpu-operator
data:
  config.yaml: |
    version: v1
    mig-configs:
      all-disabled:
        - devices: all
          mig-enabled: false
      dev-and-train:
        - devices: [0, 1, 2, 3, 4, 5]
          mig-enabled: false
        - devices: [6]
          mig-enabled: true
          mig-devices:
            "1g.10gb": 7
        - devices: [7]
          mig-enabled: true
          mig-devices:
            "3g.40gb": 2
```

Apply a profile to a node:

```
$ kubectl label node dgx-h100-07 nvidia.com/mig.config=dev-and-train --overwrite
node/dgx-h100-07 labeled
$ kubectl get node dgx-h100-07 -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}'
success
```

Production rule: **do not use MIG on nodes that run multi-node training.**

- A MIG instance has no NVLink peer access to other GPUs.
- Large-scale training needs full GPUs, full NVLink and the 1:1 GPU-to-NIC mapping.

Keep MIG on a dedicated "dev" node pool.

### 8.3 Network Operator: exposing RDMA to pods

```yaml
apiVersion: mellanox.com/v1alpha1
kind: NicClusterPolicy
metadata:
  name: nic-cluster-policy
spec:
  ofedDriver:
    image: doca-driver
    repository: nvcr.io/nvidia/mellanox
    version: "24.10-0.7.0.0-0"
    upgradePolicy:
      autoUpgrade: true
      maxParallelUpgrades: 1
      drain:
        enable: true
        force: true
        timeoutSeconds: 300
  rdmaSharedDevicePlugin:
    image: k8s-rdma-shared-dev-plugin
    repository: ghcr.io/mellanox
    version: "v1.5.2"
    config: |
      {
        "configList": [
          {
            "resourceName": "rdma_shared_device_ib",
            "rdmaHcaMax": 63,
            "selectors": {
              "vendors": ["15b3"],
              "linkTypes": ["infiniband"]
            }
          }
        ]
      }
```

> Pin `version` to the release validated for your Network Operator version. The values above are illustrative.

### 8.4 Multi-node training job pinned to the right hardware

```yaml
apiVersion: kubeflow.org/v1
kind: PyTorchJob
metadata:
  name: llm-70b-pretrain
  namespace: training
spec:
  runPolicy:
    cleanPodPolicy: None
    backoffLimit: 3
  pytorchReplicaSpecs:
    Master:
      replicas: 1
      restartPolicy: OnFailure
      template:
        metadata:
          labels:
            app: llm-70b-pretrain
        spec:
          affinity:
            nodeAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                nodeSelectorTerms:
                  - matchExpressions:
                      - key: nvidia.com/gpu.product
                        operator: In
                        values:
                          - NVIDIA-H100-80GB-HBM3
                      - key: nvidia.com/gpu.count
                        operator: In
                        values:
                          - "8"
                      - key: nvidia.com/mig.capable
                        operator: In
                        values:
                          - "true"
                      - key: nvidia.com/mig.config
                        operator: NotIn
                        values:
                          - dev-and-train
          tolerations:
            - key: nvidia.com/gpu
              operator: Exists
              effect: NoSchedule
          containers:
            - name: pytorch
              image: nvcr.io/nvidia/pytorch:24.10-py3
              command:
                - torchrun
              args:
                - "--nproc_per_node=8"
                - "--nnodes=16"
                - "--rdzv_backend=c10d"
                - "--rdzv_endpoint=llm-70b-pretrain-master-0:29500"
                - "/workspace/train.py"
                - "--model-size=70b"
                - "--tensor-parallel=8"
                - "--pipeline-parallel=4"
                - "--checkpoint-dir=/checkpoints"
              env:
                - name: NCCL_IB_HCA
                  value: "mlx5_0,mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7"
                - name: NCCL_SOCKET_IFNAME
                  value: eth0
                - name: NCCL_DEBUG
                  value: INFO
                - name: NCCL_NVLS_ENABLE
                  value: "1"
              resources:
                requests:
                  cpu: "96"
                  memory: 1600Gi
                  nvidia.com/gpu: 8
                  rdma/rdma_shared_device_ib: 1
                limits:
                  cpu: "96"
                  memory: 1600Gi
                  nvidia.com/gpu: 8
                  rdma/rdma_shared_device_ib: 1
              securityContext:
                capabilities:
                  add:
                    - IPC_LOCK
              volumeMounts:
                - name: dshm
                  mountPath: /dev/shm
                - name: checkpoints
                  mountPath: /checkpoints
                - name: datasets
                  mountPath: /data
                  readOnly: true
          volumes:
            - name: dshm
              emptyDir:
                medium: Memory
                sizeLimit: 256Gi
            - name: checkpoints
              persistentVolumeClaim:
                claimName: ckpt-pfs
            - name: datasets
              persistentVolumeClaim:
                claimName: datasets-pfs
    Worker:
      replicas: 15
      restartPolicy: OnFailure
      template:
        metadata:
          labels:
            app: llm-70b-pretrain
        spec:
          affinity:
            nodeAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                nodeSelectorTerms:
                  - matchExpressions:
                      - key: nvidia.com/gpu.product
                        operator: In
                        values:
                          - NVIDIA-H100-80GB-HBM3
                      - key: nvidia.com/gpu.count
                        operator: In
                        values:
                          - "8"
                      - key: nvidia.com/mig.config
                        operator: NotIn
                        values:
                          - dev-and-train
          tolerations:
            - key: nvidia.com/gpu
              operator: Exists
              effect: NoSchedule
          containers:
            - name: pytorch
              image: nvcr.io/nvidia/pytorch:24.10-py3
              command:
                - torchrun
              args:
                - "--nproc_per_node=8"
                - "--nnodes=16"
                - "--rdzv_backend=c10d"
                - "--rdzv_endpoint=llm-70b-pretrain-master-0:29500"
                - "/workspace/train.py"
                - "--model-size=70b"
                - "--tensor-parallel=8"
                - "--pipeline-parallel=4"
                - "--checkpoint-dir=/checkpoints"
              env:
                - name: NCCL_IB_HCA
                  value: "mlx5_0,mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7"
                - name: NCCL_SOCKET_IFNAME
                  value: eth0
                - name: NCCL_DEBUG
                  value: INFO
                - name: NCCL_NVLS_ENABLE
                  value: "1"
              resources:
                requests:
                  cpu: "96"
                  memory: 1600Gi
                  nvidia.com/gpu: 8
                  rdma/rdma_shared_device_ib: 1
                limits:
                  cpu: "96"
                  memory: 1600Gi
                  nvidia.com/gpu: 8
                  rdma/rdma_shared_device_ib: 1
              securityContext:
                capabilities:
                  add:
                    - IPC_LOCK
              volumeMounts:
                - name: dshm
                  mountPath: /dev/shm
                - name: checkpoints
                  mountPath: /checkpoints
                - name: datasets
                  mountPath: /data
                  readOnly: true
          volumes:
            - name: dshm
              emptyDir:
                medium: Memory
                sizeLimit: 256Gi
            - name: checkpoints
              persistentVolumeClaim:
                claimName: ckpt-pfs
            - name: datasets
              persistentVolumeClaim:
                claimName: datasets-pfs
```

Design choices encoded in the job:

- **`nvidia.com/gpu: 8` per pod, a whole node per rank group.** Tensor parallelism of 8 stays inside the NVSwitch domain.
- **16 nodes × 8 GPUs = 128 H100s**, giving 10.2 TB of HBM. That holds the 70B model's ~1.12 TB of state plus activations and pipeline buffers.
- **`IPC_LOCK`** lets NCCL and the RDMA stack pin (register) memory.
- **`rdma_shared_device_ib`** exposes `/dev/infiniband` so NCCL can use GPUDirect RDMA.
- **`/dev/shm` as a memory-backed `emptyDir`.** PyTorch DataLoader workers and NCCL use shared memory, and Docker's 64 MB default breaks them.
- **Gang scheduling** (Kueue, Volcano or the scheduler-plugins coscheduling plugin) should be added in production. A 16-pod job that starts 15 pods holds 120 GPUs idle.

---

## 9. CLI verification: proving the hardware matches the requirement

### 9.1 GPU inventory and memory

```
$ nvidia-smi --query-gpu=index,name,memory.total,pcie.link.gen.current,pcie.link.width.current,power.limit --format=csv
index, name, memory.total [MiB], pcie.link.gen.current, pcie.link.width.current, power.limit [W]
0, NVIDIA H100 80GB HBM3, 81559 MiB, 5, 16, 700.00 W
1, NVIDIA H100 80GB HBM3, 81559 MiB, 5, 16, 700.00 W
2, NVIDIA H100 80GB HBM3, 81559 MiB, 5, 16, 700.00 W
3, NVIDIA H100 80GB HBM3, 81559 MiB, 5, 16, 700.00 W
4, NVIDIA H100 80GB HBM3, 81559 MiB, 5, 16, 700.00 W
5, NVIDIA H100 80GB HBM3, 81559 MiB, 5, 16, 700.00 W
6, NVIDIA H100 80GB HBM3, 81559 MiB, 5, 16, 700.00 W
7, NVIDIA H100 80GB HBM3, 81559 MiB, 5, 16, 700.00 W
```

At idle, `pcie.link.gen.current` may show a lower generation because of power saving. Check under load, or compare against `pcie.link.gen.max`.

### 9.2 Topology: NVLink and GPU↔NIC affinity

```
$ nvidia-smi topo -m
        GPU0  GPU1  GPU2  GPU3  GPU4  GPU5  GPU6  GPU7  NIC0  NIC1  NIC2  NIC3  NIC4  NIC5  NIC6  NIC7  CPU Affinity  NUMA Affinity
GPU0     X    NV18  NV18  NV18  NV18  NV18  NV18  NV18  PXB   SYS   SYS   SYS   SYS   SYS   SYS   SYS   0-55,112-167  0
GPU1    NV18   X    NV18  NV18  NV18  NV18  NV18  NV18  SYS   PXB   SYS   SYS   SYS   SYS   SYS   SYS   0-55,112-167  0
GPU2    NV18  NV18   X    NV18  NV18  NV18  NV18  NV18  SYS   SYS   PXB   SYS   SYS   SYS   SYS   SYS   0-55,112-167  0
GPU3    NV18  NV18  NV18   X    NV18  NV18  NV18  NV18  SYS   SYS   SYS   PXB   SYS   SYS   SYS   SYS   0-55,112-167  0
GPU4    NV18  NV18  NV18  NV18   X    NV18  NV18  NV18  SYS   SYS   SYS   SYS   PXB   SYS   SYS   SYS   56-111,168-223 1
GPU5    NV18  NV18  NV18  NV18  NV18   X    NV18  NV18  SYS   SYS   SYS   SYS   SYS   PXB   SYS   SYS   56-111,168-223 1
GPU6    NV18  NV18  NV18  NV18  NV18  NV18   X    NV18  SYS   SYS   SYS   SYS   SYS   SYS   PXB   SYS   56-111,168-223 1
GPU7    NV18  NV18  NV18  NV18  NV18  NV18  NV18   X    SYS   SYS   SYS   SYS   SYS   SYS   SYS   PXB   56-111,168-223 1

Legend:
  X    = Self
  SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes
  PXB  = Connection traversing multiple PCIe bridges (without traversing the PCIe Host Bridge)
  NV#  = Connection traversing a bonded set of # NVLinks
```

How to read it:

- **`NV18`** means every GPU pair connects through 18 bonded NVLink 4 links via NVSwitch. That is the 900 GB/s figure.
- Each GPU has exactly one NIC at **`PXB`**, behind the same PCIe switch. That is the 1:1 rail mapping.
- **`SYS` between a GPU and its "own" NIC** on a custom build means GPUDirect RDMA traffic crosses the CPU socket interconnect. Expect reduced bandwidth.

### 9.3 NVLink health and Fabric Manager

```
$ nvidia-smi nvlink -s -i 0
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-3f1c...)
         Link 0: 26.562 GB/s
         Link 1: 26.562 GB/s
         ...
         Link 17: 26.562 GB/s

$ systemctl is-active nvidia-fabricmanager
active

$ nvidia-smi -q | grep -A2 -i "fabric"
    Fabric
        State                             : Completed
        Status                            : Success
```

On NVSwitch-based systems (HGX/DGX), **Fabric Manager must be running and its version must match the driver.** Otherwise CUDA initialization fails with error 802, "system not yet initialized". When the GPU Operator runs the driver containerized, Fabric Manager runs inside the driver pod.

### 9.4 InfiniBand port state

```
$ ibstat mlx5_0
CA 'mlx5_0'
        CA type: MT4129
        Number of ports: 1
        Firmware version: 28.42.1000
        Hardware version: 0
        Node GUID: 0xa088c20300f1e2d4
        System image GUID: 0xa088c20300f1e2d4
        Port 1:
                State: Active
                Physical state: LinkUp
                Rate: 400
                Base lid: 112
                LMC: 0
                SM lid: 1
                Capability mask: 0xa751e848
                Port GUID: 0xa088c20300f1e2d4
                Link layer: InfiniBand

$ for d in mlx5_{0..7}; do printf "%s " $d; ibstat $d | awk '/State:|Rate:/{printf "%s ", $0} END{print ""}'; done
mlx5_0         State: Active                 Rate: 400
mlx5_1         State: Active                 Rate: 400
...
mlx5_5         State: Active                 Rate: 200
mlx5_6         State: Active                 Rate: 400
mlx5_7         State: Active                 Rate: 400
```

`mlx5_5` at `Rate: 200` is a degraded link, typically a bad cable or transceiver, or a port that negotiated fewer lanes. NCCL treats all rails as equal, so that rail caps the whole collective.

### 9.5 Collective bandwidth validation (nccl-tests)

Intra-node baseline:

```
$ ./build/all_reduce_perf -b 1G -e 8G -f 2 -g 8
#       size         count      type   redop    root     time   algbw   busbw  #wrong
#        (B)    (elements)                               (us)  (GB/s)  (GB/s)
  1073741824     268435456     float     sum      -1   4580.1  234.43  410.26      0
  2147483648     536870912     float     sum      -1   8790.6  244.29  427.51      0
  4294967296    1073741824     float     sum      -1  17140.2  250.58  438.51      0
  8589934592    2147483648     float     sum      -1  33901.7  253.37  443.40      0
# Avg bus bandwidth    : 429.92
```

Multi-node run, 16 nodes × 8 GPUs (launched via `mpirun`/Slurm/MPI Operator):

```
$ mpirun -np 128 -N 8 --bind-to numa -x NCCL_IB_HCA=mlx5_0,mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7 ./build/all_reduce_perf -b 8G -e 8G -g 1
#       size         count      type   redop    root     time   algbw   busbw  #wrong
  8589934592    2147483648     float     sum      -1  48210.4  178.17  352.94      0
# Avg bus bandwidth    : 352.94
```

These outputs are representative. Exact numbers depend on driver, NCCL version, NVLS/SHARP enablement and topology. The method is what matters:

- Establish a per-node baseline and a per-SU baseline at acceptance time.
- Re-run after every maintenance window.
- A node whose `busbw` sits significantly below its peers is the one to drain.

For inter-node runs on 8×400G, `busbw` should approach the aggregate NIC bandwidth (8 × 50 GB/s = 400 GB/s raw) minus protocol overhead.

### 9.6 DCGM diagnostics (acceptance and pre-job health)

```
$ dcgmi diag -r 3
Successfully ran diagnostic for group.
+---------------------------+------------------------------------------------+
| Diagnostic                | Result                                         |
+===========================+================================================+
|-----  Metadata  ----------+------------------------------------------------|
| DCGM Version              | 3.3.x                                          |
| Number of GPUs Detected   | 8                                              |
|-----  Deployment  --------+------------------------------------------------|
| Denylist                  | Pass                                           |
| NVML Library              | Pass                                           |
| CUDA Main Library         | Pass                                           |
| Permissions and OS Blocks | Pass                                           |
| Persistence Mode          | Pass                                           |
| Environment Variables     | Pass                                           |
| Page Retirement/Row Remap | Pass                                           |
| Graphics Processes        | Pass                                           |
| Inforom                   | Pass                                           |
+-----  Integration  -------+------------------------------------------------+
| PCIe                      | Pass - All                                     |
+-----  Hardware  ----------+------------------------------------------------+
| GPU Memory                | Pass - All                                     |
+-----  Stress  ------------+------------------------------------------------+
| Targeted Stress           | Pass - All                                     |
| Targeted Power            | Pass - All                                     |
| Memory Bandwidth          | Pass - All                                     |
+---------------------------+------------------------------------------------+
```

Diagnostic levels:

- **`-r 1`**: quick sanity check, seconds. Good for a pre-job hook.
- **`-r 3`**: includes stress tests, minutes. Good for node admission.
- **`-r 4`**: extended, about an hour. Good for burn-in or RMA validation.

### 9.7 Throttling and power

```
$ nvidia-smi -q -d PERFORMANCE -i 3
    Clocks Event Reasons
        Idle                              : Not Active
        Applications Clocks Setting       : Not Active
        SW Power Cap                      : Active
        HW Slowdown                       : Not Active
            HW Thermal Slowdown           : Not Active
            HW Power Brake Slowdown       : Not Active
        Sync Boost                        : Not Active
        SW Thermal Slowdown               : Not Active

$ nvidia-smi --query-gpu=index,power.draw,power.limit,temperature.gpu,clocks.sm --format=csv
index, power.draw [W], power.limit [W], temperature.gpu, clocks.sm [MHz]
3, 699.12 W, 700.00 W, 71, 1755 MHz
```

`SW Power Cap: Active` while drawing the full limit is normal under heavy load. Two other patterns point to facility problems:

- **`HW Slowdown` / `HW Power Brake Slowdown`**: PSU or power delivery problem.
- **`HW Thermal Slowdown`**: airflow or cooling problem.

### 9.8 GPUDirect Storage check

```
$ /usr/local/cuda/gds/tools/gdscheck -p
 GDS release version: 1.11.x
 nvidia_fs version:  2.22 libcufile version: 2.12
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
 ==============
 PLATFORM INFO:
 ==============
 IOMMU: disabled
 Platform verification succeeded
```

### 9.9 Kubernetes-level verification

```
$ kubectl get node dgx-h100-07 -o json | jq '.status.allocatable | with_entries(select(.key|test("nvidia|rdma")))'
{
  "nvidia.com/gpu": "8",
  "rdma/rdma_shared_device_ib": "63"
}

$ kubectl get node dgx-h100-07 --show-labels | tr ',' '\n' | grep -E 'gpu.product|gpu.memory|gpu.count|mig.capable'
nvidia.com/gpu.count=8
nvidia.com/gpu.memory=81559
nvidia.com/gpu.product=NVIDIA-H100-80GB-HBM3
nvidia.com/mig.capable=true

$ kubectl -n gpu-operator get pods
NAME                                                READY   STATUS      RESTARTS   AGE
gpu-feature-discovery-x7k2p                         1/1     Running     0          3d
gpu-operator-6d8b9c7f5-q9kzr                        1/1     Running     0          3d
nvidia-container-toolkit-daemonset-5n8w4            1/1     Running     0          3d
nvidia-cuda-validator-hv2tl                         0/1     Completed   0          3d
nvidia-dcgm-exporter-m4c8x                          1/1     Running     0          3d
nvidia-device-plugin-daemonset-t2pl9                1/1     Running     0          3d
nvidia-driver-daemonset-9qv7d                       1/1     Running     0          3d
nvidia-mig-manager-cjz6r                            1/1     Running     0          3d
nvidia-operator-validator-rx2bd                     1/1     Running     0          3d
```

---

## 10. Failure diagnosis guide

| Symptom | Likely root cause | How to confirm | Fix |
|---|---|---|---|
| `CUDA out of memory` at step 0 | Hardware memory undersized for the method (plain DDP on 70B) | Per-param math (16 B/param + activations) | FSDP/ZeRO-3, activation checkpointing, more GPUs, H200/B200 |
| `cudaErrorSystemNotReady` / error 802 on HGX | Fabric Manager not running or version mismatch with driver | `systemctl status nvidia-fabricmanager`, `nvidia-smi -q` fabric state | Align FM version with driver; restart driver pod/service |
| Low MFU, GPUs at 30–60% util with sawtooth pattern | Data loader starvation (CPU or storage) | `DCGM_FI_PROF_GR_ENGINE_ACTIVE` dips, high `iowait`, low storage throughput | More loader workers/cores, local NVMe cache, GDS, DALI |
| Multi-node all-reduce far below baseline | Degraded IB rail, NCCL falling back to TCP, missing GPUDirect RDMA | `NCCL_DEBUG=INFO` shows `NET/Socket` instead of `NET/IB`; `ibstat` rates; `lsmod \| grep nvidia_peermem` | Fix cable/optic, enable `driver.rdma`, give pod `IPC_LOCK` + RDMA resource |
| Intra-node P2P slow on PCIe builds | ACS enabled on PCIe switches forcing traffic to root complex | `lspci -vvv \| grep ACSCtl`; `p2pBandwidthLatencyTest` | Disable ACS in BIOS where supported (bare metal), or validate platform config |
| GPU shows PCIe x8 / Gen3 under load | Seating, riser, or BIOS issue | `nvidia-smi -q -d PCI` link width/gen; `lspci -vv` `LnkSta` | Reseat, BIOS update, RMA |
| Job dies; `dmesg` shows `Xid 79` | GPU fell off the bus (power/thermal/hardware) | `dmesg \| grep -i xid` | Drain node, `dcgmi diag -r 3`, check PSU/thermals, RMA |
| `Xid 48` / `Xid 94` / `Xid 95` | Uncorrectable ECC (DBE), contained or uncontained | `nvidia-smi -q -d ECC`, row remap state | Uncontained: reset GPU/reboot node; pending row remap needs GPU reset |
| `Xid 74` | NVLink error | `nvidia-smi nvlink -e`, Fabric Manager logs | Reset node; persistent: hardware service |
| Clocks low, `HW Power Brake Slowdown: Active` | Facility power event or PSU failure | `nvidia-smi -q -d PERFORMANCE`, BMC/Redfish PSU logs | Restore PSU redundancy, check PDU feed |
| Pod `Pending` with `Insufficient nvidia.com/gpu` but GPUs idle | MIG profile applied to a node intended for full-GPU training | `nvidia.com/mig.config` label, `nvidia-smi -L` showing MIG devices | Set `mig.config=all-disabled`, separate node pools |
| Checkpoints take minutes, step-time spikes | Storage fabric undersized, or checkpoint traffic sharing the compute fabric | Write throughput during checkpoint; per-port counters | Separate storage fabric, async/sharded checkpointing, faster PFS tier |

A pragmatic triage order for "training is slow":

1. **Single-GPU compute**: `dcgmi diag`, clocks, throttle reasons.
2. **Intra-node**: `nvidia-smi topo -m`, Fabric Manager, single-node `all_reduce_perf`.
3. **Inter-node**: `ibstat` on every rail, multi-node `all_reduce_perf`, `NCCL_DEBUG=INFO` transport selection.
4. **I/O**: data loader time per step, storage throughput, `gdscheck`.
5. **Facility**: power events, inlet temperatures, PSU redundancy.

---

## 11. Sizing worksheet (put it together)

A quick estimator for the first-order numbers in sections 2.1 and 2.2:

```python
#!/usr/bin/env python3
# first-order training hardware sizing (dense transformer, mixed precision Adam)
import math

params      = 70e9      # N
tokens      = 2e12      # D
gpu_mem_gb  = 80        # H100 80GB
gpu_bf16    = 989e12    # dense BF16 FLOP/s
mfu         = 0.40
gpus        = 1024
bytes_per_p = 16        # weights+grads+master+adam m/v

state_tb    = params * bytes_per_p / 1e12
min_gpus    = math.ceil(params * bytes_per_p / (gpu_mem_gb * 1e9 * 0.6))  # keep 40% for activations
flops       = 6 * params * tokens
days        = flops / (gpu_bf16 * mfu * gpus) / 86400
ckpt_tb     = params * 14 / 1e12

print(f"model+optimizer state : {state_tb:.2f} TB")
print(f"min GPUs (memory)     : {min_gpus}")
print(f"training compute      : {flops:.2e} FLOPs")
print(f"wall time on {gpus} GPUs : {days:.1f} days")
print(f"checkpoint size       : {ckpt_tb:.2f} TB")
```

```
$ python3 -I sizing.py
model+optimizer state : 1.12 TB
min GPUs (memory)     : 24
training compute      : 8.40e+23 FLOPs
wall time on 1024 GPUs : 24.0 days
checkpoint size       : 0.98 TB
```

Summary mapping for the exam:

| Use case | GPU | Node | Intra-node | Scale-out | Storage | Other |
|---|---|---|---|---|---|---|
| LLM pre-training (frontier) | B200 / GB200 | DGX B200 / GB200 NVL72 | NVLink 5 | InfiniBand NDR/XDR, rail-optimized, SuperPOD SUs | Parallel FS + GDS, separate storage fabric | Liquid cooling (NVL72), high power density |
| LLM pre-training (mainstream) | H100 / H200 SXM | DGX/HGX H100/H200 | NVLink 4 + NVSwitch | 8× 400 Gb/s per node | Parallel FS, local NVMe cache | ~10 kW/node |
| Full fine-tuning (≤70B) | H100/H200 SXM | 1–8 HGX nodes | NVLink required | Moderate (fewer nodes) | Shared FS | FSDP/ZeRO |
| PEFT / LoRA | H100 PCIe, L40S, A100 | Mainstream servers | Not required | Standard Ethernet | NFS/object | MIG for small models |
| Dev/experimentation | Any MIG-capable GPU | Shared node pool | n/a | n/a | n/a | MIG / time-slicing, quotas |
| Multi-tenant AI cloud | Any | Any | Per workload | Spectrum-X Ethernet | Disaggregated NVMe-oF | BlueField-3 DPU for isolation and offload |

---

## 12. Exam-oriented key points

- **Training is memory-bound first, communication-bound second, compute-bound third** in most real deployments. Size HBM for model plus optimizer state, then size the fabric, then the FLOPs.
- **Mixed-precision Adam costs about 16 bytes per parameter** before activations.
- **NVLink/NVSwitch provides scale-up** (900 GB/s per GPU on H100, 1.8 TB/s on Blackwell). **InfiniBand/Spectrum-X provides scale-out** (400 Gb/s per NIC, one NIC per GPU).
- **SXM beats PCIe for distributed training** because of NVLink. PCIe fits inference and fine-tuning.
- **GPUDirect RDMA and GPUDirect Storage** remove CPU bounce buffers. BlueField DPUs offload and isolate networking, storage and security from the host.
- **DGX SuperPOD** uses Scalable Units with rail-optimized fat-tree compute fabrics, plus separate storage, in-band and out-of-band networks.
- **MIG** is for sharing GPUs among small workloads, not for large-scale training.
- **Power and cooling** (about 10–14 kW per DGX node, about 120 kW per liquid-cooled NVL72 rack) are hard requirements, not afterthoughts.

---

## Referencias

- NVIDIA DGX B200 datasheet: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy, AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- Offloading and Isolating Data Center Workloads with BlueField DPU: https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
- NVIDIA DGX SuperPOD Reference Architecture, DGX B200: https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
- NVIDIA DGX H100 User Guide, Component Descriptions: https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
- NVIDIA NVLink and NVSwitch: https://www.nvidia.com/en-us/data-center/nvlink/
- Accelerating IO in the Modern Data Center, Network IO: https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
- NVIDIA GPU Operator documentation: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html
- NVIDIA Network Operator documentation: https://docs.nvidia.com/networking/display/kubernetes/latest/index.html
- NVIDIA Multi-Instance GPU User Guide: https://docs.nvidia.com/datacenter/tesla/mig-user-guide/
- NVIDIA DCGM documentation: https://docs.nvidia.com/datacenter/dcgm/latest/user-guide/index.html
- NVIDIA GPUDirect Storage documentation: https://docs.nvidia.com/gpudirect-storage/index.html
- NCCL tests: https://github.com/NVIDIA/nccl-tests
- NVIDIA XID errors: https://docs.nvidia.com/deploy/xid-errors/index.html