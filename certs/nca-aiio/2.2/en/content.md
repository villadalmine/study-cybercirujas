# 2.2 Scale a GPU Infrastructure for Different Use Cases

> **Exam weight:** 4.0 · **Certification:** NVIDIA-Certified Associate: AI Infrastructure and Operations (NCA-AIIO)

---

## 1. Motivation: the production problem

"Add more GPUs" is a sizing statement, not an architecture. Every AI workload has a **dominant bottleneck**, and scaling only works when you scale the resource that is actually saturated:

| Workload | Dominant bottleneck | What "scaling" really means |
|---|---|---|
| LLM pre-training (10B–1T+ params) | GPU-to-GPU bandwidth during collectives (all-reduce, all-gather, reduce-scatter), HBM capacity | Grow the **NVLink domain** (scale-up), then add nodes on a **non-blocking RDMA fabric** (scale-out) |
| Fine-tuning (LoRA / full) | HBM capacity, sometimes a single node is enough | Fit the model in one NVLink domain; scale out only for throughput |
| Online inference (chat, RAG) | HBM capacity for weights + KV cache, latency SLOs | **Horizontal replicas** behind a load balancer; tensor parallelism inside a node only when the model does not fit one GPU |
| Batch inference / embeddings | Throughput per dollar | Many small, independent replicas; GPU partitioning (MIG) |
| HPC simulation (MPI) | Interconnect latency, FP64 | Low-latency InfiniBand, MPI + GPUDirect RDMA |
| Data analytics (RAPIDS, Spark) | Storage and PCIe I/O | GPUDirect Storage, fast parallel file system |
| Dev / notebooks / CI | Utilization (GPUs sit idle) | **Scale down**: MIG, time-slicing, vGPU |

The core architectural insight from NVIDIA's DGX and SuperPOD reference designs is that **a modern AI data center is a single computer whose bus is the network**. A training job on 1,024 GPUs is only as fast as its slowest link. A GPU waiting on an all-reduce is a GPU that costs the same per hour and produces nothing.

Four constraints recur at every scale:

1. **Compute/memory**: how many FLOPS and how much HBM per GPU, per node, per NVLink domain.
2. **Interconnect**: NVLink (intra-domain) and InfiniBand/Ethernet RDMA (inter-node).
3. **Storage I/O**: dataset reads and checkpoint writes, ideally bypassing the CPU (GPUDirect Storage).
4. **Facility**: power per rack, cooling (air vs liquid), floor space, cabling.

---

## 2. The two scaling axes: scale-up vs scale-out

### 2.1 Definitions

- **Scale-up**: make one "logical GPU" bigger by connecting GPUs over **NVLink/NVSwitch**, a memory-semantic fabric with load/store access to peer HBM. Bandwidth is an order of magnitude above any NIC.
- **Scale-out**: connect many scale-up domains over a **network fabric** (InfiniBand NDR/XDR or Spectrum-X Ethernet with RoCE), using **GPUDirect RDMA** so NICs read and write GPU memory directly.

### 2.2 Bandwidth hierarchy (why placement matters)

| Path | Typical bandwidth per GPU | Relative |
|---|---|---|
| HBM3 (H100 SXM) | ~3.35 TB/s | 1× (reference) |
| NVLink 4 (H100, 18 links) | 900 GB/s bidirectional | ~1/4 of HBM |
| NVLink 5 (B200) | 1.8 TB/s bidirectional | 2× NVLink 4 |
| PCIe Gen5 x16 | ~128 GB/s bidirectional | ~1/7 of NVLink 4 |
| NDR InfiniBand (1 × ConnectX-7 per GPU) | 400 Gb/s ≈ 50 GB/s per direction | ~1/9 of NVLink 4 per direction |

**Consequence:** parallelism strategies are mapped onto this hierarchy.

| Parallelism | Communication pattern | Volume | Where to place it |
|---|---|---|---|
| Tensor parallelism (TP) | All-reduce per layer, every micro-batch | Very high, latency-sensitive | **Inside the NVLink domain** (TP ≤ 8 on DGX H100/B200, larger on GB200 NVL72) |
| Pipeline parallelism (PP) | Point-to-point activations between stages | Moderate | Across nodes is acceptable |
| Data parallelism (DP / FSDP / ZeRO) | All-reduce/reduce-scatter of gradients once per step | High but overlappable with compute | Across nodes, on the RDMA fabric |
| Expert parallelism (MoE) | All-to-all | High, bursty | NVLink domain preferred; needs non-blocking fabric otherwise |

### 2.3 Scale-up vs scale-out trade-offs

| Dimension | Scale-up (NVLink/NVSwitch) | Scale-out (IB / Spectrum-X RDMA) |
|---|---|---|
| Bandwidth | 900 GB/s (H100) to 1.8 TB/s (B200) per GPU | 400–800 Gb/s per GPU NIC |
| Latency | Sub-microsecond, memory semantics | Low microseconds, RDMA verbs |
| Max size | 8 GPUs (DGX H100/B200 HGX baseboard); 72 GPUs (GB200 NVL72); larger with NVLink Switch systems | Thousands to hundreds of thousands of GPUs |
| Cost driver | Integrated in the system; rack-scale designs need liquid cooling | Switches, optics, cables (often 10–20 % of cluster cost) |
| Failure domain | Whole node/rack | Single link/switch; fabric can route around |
| Best for | TP, MoE all-to-all, large single-model inference | DP, PP, multi-tenant clusters |

---

## 3. Building blocks

### 3.1 DGX H100 node (the canonical "scale-up unit")

Key components, per the DGX H100 User Guide:

| Component | DGX H100 | Why it matters for scaling |
|---|---|---|
| GPUs | 8 × H100 SXM5, 80 GB HBM3 each (640 GB total) | Unit of scale-up |
| GPU interconnect | 4 × third-generation NVSwitch, 18 NVLink 4 links per GPU, 900 GB/s per GPU | Full all-to-all bandwidth inside the node |
| CPUs | 2 × Intel Xeon Platinum 8480C (56 cores each) | Data loading, preprocessing, NCCL proxy threads |
| System memory | 2 TB | Host staging, page cache |
| Compute fabric | 8 × single-port ConnectX-7 (exposed through 4 OSFP ports), up to 400 Gb/s IB/Ethernet each | **1 NIC per GPU** → rail-optimized fabric |
| Storage / in-band fabric | 2 × dual-port ConnectX-7 (QSFP112) | Separate from compute traffic |
| OS storage | 2 × 1.92 TB NVMe M.2 (RAID-1) | |
| Data cache | 8 × 3.84 TB NVMe U.2 | Local dataset cache, reduces shared-storage load |
| Max power | ~10.2 kW | Drives rack density |
| OOB management | BMC (1 GbE RJ45) | Redfish/IPMI, separate OOB network |

### 3.2 DGX B200

| Component | DGX B200 |
|---|---|
| GPUs | 8 × B200, 1,440 GB HBM3e total |
| GPU interconnect | NVLink 5 via 2 × NVSwitch, 1.8 TB/s per GPU |
| Performance (vendor figures) | ~72 PFLOPS FP8 training, ~144 PFLOPS FP4 inference |
| CPUs | 2 × Intel Xeon Platinum 8570 |
| Compute fabric | 8 × single-port ConnectX-7, 400 Gb/s (4 OSFP) |
| Storage / in-band | 2 × dual-port **BlueField-3 DPU** |
| Max power | ~14.3 kW |

### 3.3 Rack-scale: GB200 NVL72

When TP or MoE needs more than 8 GPUs, the NVLink domain itself grows: 36 Grace CPUs + 72 Blackwell GPUs in one rack, all-to-all over NVLink 5 switch trays (~130 TB/s aggregate NVLink bandwidth). It behaves as one large GPU for trillion-parameter inference and training. The trade-off is facility: **liquid cooling is mandatory** and rack power is in the ~120+ kW class, versus ~40 kW for a rack of four air-cooled DGX H100.

### 3.4 NVLink and NVSwitch mechanics

- Each GPU has N NVLink ports. Without NVSwitch, GPUs connect point-to-point and bandwidth between a pair depends on how many links they share.
- With **NVSwitch**, every GPU connects to every switch, so any pair gets the **full** per-GPU bandwidth simultaneously (non-blocking).
- NVSwitch 3 and later supports **NVLink SHARP**: reductions (sum for all-reduce) computed *in the switch*, halving the data each GPU must send.
- NCCL detects the topology automatically and picks ring, tree or NVLS (NVLink SHARP) algorithms.

### 3.5 Magnum IO: the I/O subsystem

NVIDIA groups the data center I/O stack under **Magnum IO**, with four pillars:

| Pillar | Components | Purpose |
|---|---|---|
| Network IO | GPUDirect RDMA, NCCL, NVSHMEM, UCX, HPC-X | GPU memory ↔ NIC without CPU/host bounce buffers |
| Storage IO | GPUDirect Storage (GDS, `cuFile`) | NVMe/NVMe-oF/parallel FS ↔ GPU memory directly |
| In-network compute | SHARP (InfiniBand), NVLink SHARP | Offload collectives to switches |
| IO management | UFM, NetQ, DCGM telemetry | Fabric monitoring, congestion and fault management |

**GPUDirect RDMA** removes two copies (GPU → host RAM → NIC) and frees CPU cycles. It requires the GPU and NIC under the **same PCIe switch** for best performance, which is exactly why DGX pairs one ConnectX-7 with each GPU behind a shared PCIe switch.

### 3.6 BlueField DPU: offload and isolation

A **BlueField DPU** is a NIC with an Arm SoC, hardware accelerators and its own OS (managed via DOCA). In scaled infrastructures it addresses three problems:

| Problem at scale | DPU offload | Benefit |
|---|---|---|
| Host CPU cycles burned on virtual switching, overlay encapsulation (VXLAN/Geneve), firewalling | OVS/OVN data path in DPU hardware (ASAP²) | Host cores go back to the AI workload |
| Storage virtualization | NVMe-oF initiator, NVMe emulation (SNAP), encryption at line rate | Bare-metal-like storage for tenants |
| Multi-tenant trust | Control plane runs on the DPU, a **separate trust domain** from the host | A compromised host/tenant cannot reconfigure network policy or reach other tenants |

Rule of thumb:

- **ConnectX SuperNIC / ConnectX-7** on the GPU **compute (east-west)** fabric: lowest latency, highest bandwidth, minimal processing.
- **BlueField-3 DPU** on **north-south / storage / tenant** traffic: infrastructure services, isolation, zero-trust.

---

## 4. Scale-out fabric design

### 4.1 InfiniBand vs Ethernet for AI

| Criterion | InfiniBand (Quantum-2 NDR / Quantum-X800 XDR) | Spectrum-X Ethernet (Spectrum-4 + BlueField-3 SuperNIC) | Commodity Ethernet / TCP |
|---|---|---|---|
| Transport | Native RDMA, credit-based lossless | RoCEv2 with adaptive routing and congestion control | TCP sockets |
| Congestion handling | Link-level flow control, adaptive routing | Adaptive routing + telemetry-based CC, packet reordering in SuperNIC | ECN/PFC tuning, ECMP hash collisions |
| In-network compute | SHARPv3 | Not equivalent | None |
| Management | Subnet Manager (UFM / OpenSM) | Standard Ethernet tooling, NetQ | Standard |
| Multi-tenancy | P_Keys | VRF/VXLAN, BlueField isolation | VLAN/VXLAN |
| Typical use | Largest training clusters, HPC, DGX SuperPOD | AI clouds needing Ethernet operations model | Inference, dev, small clusters |
| Risk | Separate skill set | Requires end-to-end NVIDIA stack for the advertised gains | NCCL falls back to sockets: training scales poorly |

### 4.2 Rail-optimized topology

In a DGX SuperPOD, **GPU *i* of every node connects to leaf switch(es) of rail *i***. Eight GPUs → eight rails.

```
            Spine layer (Quantum-2 QM9700, 64 × NDR ports)
        ┌────────┬────────┬────────┬─ ... ─┬────────┐
        │        │        │        │       │        │
  Leaf: Rail0   Rail1    Rail2    Rail3   ...     Rail7
        │ │ │    │ │ │    ...
Node 1: G0 ─┘    G1       G2 ...                    G7
Node 2: G0 ──┘   G1 ...
Node N: G0 ───┘
```

Why rails:

- NCCL's ring/tree algorithms pair *same-index* GPUs across nodes. With rails, that traffic crosses **one leaf hop**, never the spine.
- Intra-node traffic between different GPU indices goes over NVLink (PXN, "PCI × NVLink", lets a GPU send through a peer GPU's NIC on the right rail).
- Failure of one leaf degrades one rail, not whole nodes.

### 4.3 Fat-tree sizing math

For switches with *k* ports in a **non-blocking** fat tree:

| Tiers | Max endpoints | k = 64 (QM9700 NDR) |
|---|---|---|
| 2-tier (leaf/spine) | k²/2 | 2,048 GPU ports |
| 3-tier (leaf/spine/core) | k³/4 | 65,536 GPU ports |

Non-blocking means each leaf uses half its ports down (to GPUs) and half up (to spines). Oversubscribing (e.g., 2:1) is tolerable for inference clusters but harms training collectives at scale.

### 4.4 DGX SuperPOD (B200) reference architecture

The SuperPOD RA for DGX B200 standardizes:

| Element | Design |
|---|---|
| Scalable Unit (SU) | 32 DGX B200 nodes (256 GPUs), the repeatable building block |
| Compute fabric | InfiniBand NDR 400 Gb/s, rail-optimized, full fat tree, one port per GPU |
| Storage fabric | Separate fabric, connected through the BlueField-3 ports, to certified high-performance storage |
| In-band management | Ethernet: Kubernetes/Slurm control, user access, image pulls |
| Out-of-band management | Ethernet to BMCs, PDUs, switch management ports |
| Control plane | Head/management nodes running NVIDIA Base Command Manager, Slurm and/or Kubernetes, UFM |
| Software | DGX OS, NVIDIA AI Enterprise, NCCL, DCGM, UFM |

**Four independent networks** is the key exam fact: compute, storage, in-band, OOB. Mixing storage and compute traffic on the same fabric is the most common self-inflicted performance problem in DIY clusters.

---

## 5. Sizing per use case

### 5.1 Training memory budget

Mixed-precision training with Adam keeps roughly **16 bytes per parameter** before activations:

| State | Bytes/param |
|---|---|
| BF16 weights | 2 |
| BF16 gradients | 2 |
| FP32 master weights | 4 |
| Adam first moment (m), FP32 | 4 |
| Adam second moment (v), FP32 | 4 |
| **Total** | **16** |

Example, 70B parameters: 70 × 10⁹ × 16 B ≈ **1.12 TB** of state, plus activations. One DGX H100 has 640 GB of HBM, so even with full sharding (FSDP / ZeRO-3) you need **at least 2 nodes**, and realistically 4+ to leave room for activations and keep step time reasonable. This is the arithmetic that forces scale-out.

### 5.2 Inference memory budget

Weights: params × bytes per param (FP16/BF16 = 2, FP8 = 1, FP4 ≈ 0.5).

KV cache per token:

```
kv_bytes_per_token = 2 (K and V) × n_layers × n_kv_heads × head_dim × bytes_per_element
```

Example, a 70B model with 80 layers, 8 KV heads (GQA), head_dim 128, FP16:

```
2 × 80 × 8 × 128 × 2 B = 327,680 B ≈ 320 KiB per token
```

- Weights in BF16: ~140 GB → does not fit one 80 GB H100 → **TP=2 minimum** (TP=4 typical for KV headroom), inside NVLink.
- 32 concurrent sequences × 8,192 tokens × 320 KiB ≈ 80 GiB of KV cache on top.
- In FP8 the weights drop to ~70 GB: TP=2 becomes comfortable and throughput per GPU roughly doubles.

Then scale **horizontally**: N independent TP groups behind a load balancer, autoscaled on queue depth.

### 5.3 Checkpoint bandwidth

1.12 TB of state written every 30 minutes, with a target stall of ≤ 60 s:

```
1.12 TB / 60 s ≈ 18.7 GB/s sustained aggregate write
```

That number sizes the storage fabric and the parallel file system, independently of GPU count. Asynchronous checkpointing (write to local NVMe, then drain) relaxes it.

### 5.4 Use case → architecture decision matrix

| Use case | GPU class | Node choice | Partitioning | Fabric | Storage | Orchestrator |
|---|---|---|---|---|---|---|
| Foundation-model pre-training | H100/H200/B200/GB200 | DGX / HGX 8-GPU or NVL72 | None (whole GPUs) | IB NDR/XDR or Spectrum-X, rail-optimized, non-blocking | Parallel FS + GDS, local NVMe cache | Slurm (Base Command Manager) or Kubernetes + Kueue/Volcano |
| Fine-tuning | H100/L40S | 1–4 nodes | None or 3g/4g MIG for small LoRA | IB or RoCE | Shared NFS/parallel FS | Kubernetes Jobs, PyTorchJob |
| Online LLM inference | H100/H200/B200/L40S | 8-GPU or PCIe servers | MIG for small models; TP inside node for large | Ethernet for clients, RDMA only for disaggregated serving | Model cache on local NVMe | Kubernetes + Triton/NIM/vLLM + HPA |
| Batch / embedding inference | L4/L40S/A100 MIG | Dense PCIe servers | MIG 1g/2g | Ethernet | Object store | Kubernetes Jobs |
| HPC | H100/GH200 (FP64) | HGX | None | InfiniBand, low latency | Parallel FS | Slurm + MPI |
| Data science / notebooks | Any | Shared | Time-slicing or MIG | Ethernet | NFS | Kubernetes / JupyterHub |
| VDI / visualization | L40S/A16 | PCIe servers | vGPU | Ethernet | VDI storage | Hypervisor + NVIDIA vGPU |
| Edge | Jetson / IGX / L4 | Edge appliances | Usually none | WAN | Local | Fleet management (K3s etc.) |

---

## 6. Scaling *down*: GPU sharing technologies

Most enterprise clusters waste more money on idle GPUs than on slow ones. Sharing lets one physical GPU serve many small workloads.

| Feature | MIG | Time-slicing | MPS | vGPU |
|---|---|---|---|---|
| Isolation | **Hardware**: dedicated SMs, L2 slices, memory controllers, HBM | None: shared memory, context switches | Logical; shared address space faults can affect peers | Hypervisor-level, VM per slice |
| Memory isolation | Yes, fixed per profile | No (one pod can OOM others) | Limit per client configurable, not hard isolation | Yes (framebuffer per profile) |
| QoS / predictable latency | Yes | No | Partial (SM % limit) | Scheduler-dependent |
| Granularity | Up to 7 instances (A100/H100/B200) | Any replica count | Up to 48 clients (Volta+) | Profiles per GPU model |
| Reconfiguration | Requires GPU idle; sometimes reboot/reset | Config change only | Daemon restart | VM reconfig |
| Supported GPUs | A100, A30, H100, H200, B200, … | All | All modern | vGPU-licensed GPUs |
| Best use case | Multi-tenant inference, guaranteed QoS | Dev/notebooks, bursty, trusted users | Many small cooperative processes (one job, many ranks) | VDI, VMs, regulated tenants |
| Licensing | Included | Included | Included | NVIDIA vGPU / AI Enterprise license |

**H100 80 GB MIG profiles:**

| Profile | Instances per GPU | Memory | Approx. SMs |
|---|---|---|---|
| 1g.10gb | 7 | ~10 GB | 16 |
| 1g.20gb | 4 | ~20 GB | 16 |
| 2g.20gb | 3 | ~20 GB | 32 |
| 3g.40gb | 2 | ~40 GB | 60 |
| 4g.40gb | 1 | ~40 GB | 64 |
| 7g.80gb | 1 | 80 GB | 132 |

---

## 7. Implementation on Kubernetes

### 7.1 Install the GPU Operator

The GPU Operator deploys the driver (or uses the pre-installed one on DGX OS), container toolkit, device plugin, GPU Feature Discovery, DCGM exporter and the MIG manager.

```
$ helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
"nvidia" has been added to your repositories

$ helm repo update
...Successfully got an update from the "nvidia" chart repository
Update Complete. ⎈Happy Helming!⎈

$ helm install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator --create-namespace \
    --version v25.3.0 \
    --set driver.enabled=false \
    --set mig.strategy=mixed
NAME: gpu-operator
LAST DEPLOYED: Thu Nov 12 10:14:02 2026
NAMESPACE: gpu-operator
STATUS: deployed
REVISION: 1
```

Pin the chart version you validated; `driver.enabled=false` is correct on DGX OS, where the driver is part of the OS image.

```
$ kubectl -n gpu-operator get pods
NAME                                                READY   STATUS      RESTARTS   AGE
gpu-feature-discovery-7xk2p                         1/1     Running     0          3m
gpu-operator-6d8f9c7b5-q9wlz                        1/1     Running     0          4m
nvidia-container-toolkit-daemonset-h4tq8            1/1     Running     0          3m
nvidia-cuda-validator-p2m7d                         0/1     Completed   0          2m
nvidia-dcgm-exporter-9bvc4                          1/1     Running     0          3m
nvidia-device-plugin-daemonset-zr5n6                1/1     Running     0          3m
nvidia-mig-manager-l6t8w                            1/1     Running     0          3m
nvidia-operator-validator-wq2vb                     1/1     Running     0          3m
```

```
$ kubectl get node dgx-h100-01 -o jsonpath='{.status.allocatable}' | jq
{
  "cpu": "224",
  "ephemeral-storage": "1798500000000",
  "hugepages-1Gi": "0",
  "hugepages-2Mi": "0",
  "memory": "2113309904Ki",
  "nvidia.com/gpu": "8",
  "pods": "110"
}
```

### 7.2 Scale down: time-slicing for dev nodes

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
  namespace: gpu-operator
data:
  dev-4x: |-
    version: v1
    flags:
      migStrategy: none
    sharing:
      timeSlicing:
        renameByDefault: false
        failRequestsGreaterThanOne: true
        resources:
          - name: nvidia.com/gpu
            replicas: 4
```

Apply it and point the device plugin at it, then select the config per node with a label:

```
$ kubectl apply -f time-slicing-config.yaml
configmap/time-slicing-config created

$ kubectl patch clusterpolicies.nvidia.com/cluster-policy --type merge \
    -p '{"spec":{"devicePlugin":{"config":{"name":"time-slicing-config"}}}}'
clusterpolicy.nvidia.com/cluster-policy patched

$ kubectl label node l40s-dev-03 nvidia.com/device-plugin.config=dev-4x
node/l40s-dev-03 labeled

$ kubectl get node l40s-dev-03 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
16

$ kubectl get node l40s-dev-03 --show-labels | tr ',' '\n' | grep -E 'gpu.replicas|gpu.sharing'
nvidia.com/gpu.replicas=4
nvidia.com/gpu.sharing-strategy=time-slicing
```

4 physical L40S × 4 replicas = 16 schedulable `nvidia.com/gpu`. `failRequestsGreaterThanOne: true` rejects pods requesting more than one replica, because 2 time-sliced replicas do **not** mean 2× compute.

### 7.3 Scale down with isolation: MIG layouts

A custom MIG layout that dedicates half the node to small inference models and keeps two full GPUs for a fine-tuning job:

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
      inference-mixed:
        - devices: [0, 1, 2, 3]
          mig-enabled: true
          mig-devices:
            "1g.10gb": 7
        - devices: [4, 5]
          mig-enabled: true
          mig-devices:
            "3g.40gb": 2
        - devices: [6, 7]
          mig-enabled: false
```

```
$ kubectl apply -f custom-mig-config.yaml
configmap/custom-mig-config created

$ kubectl patch clusterpolicies.nvidia.com/cluster-policy --type merge \
    -p '{"spec":{"migManager":{"config":{"name":"custom-mig-config"}}}}'
clusterpolicy.nvidia.com/cluster-policy patched

$ kubectl label node dgx-h100-02 nvidia.com/mig.config=inference-mixed --overwrite
node/dgx-h100-02 labeled

$ kubectl get node dgx-h100-02 -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}{"\n"}'
pending

$ kubectl get node dgx-h100-02 -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}{"\n"}'
success

$ kubectl get node dgx-h100-02 -o json | jq '.status.allocatable | with_entries(select(.key|startswith("nvidia.com")))'
{
  "nvidia.com/gpu": "2",
  "nvidia.com/mig-1g.10gb": "28",
  "nvidia.com/mig-3g.40gb": "4"
}
```

The MIG manager drains GPU clients on the node, so schedule layout changes like maintenance windows.

A pod consuming one slice (requires `mig.strategy=mixed`):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: embeddings-worker
  namespace: inference
spec:
  restartPolicy: Never
  containers:
    - name: cuda
      image: nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04
      command: ["nvidia-smi", "-L"]
      resources:
        limits:
          nvidia.com/mig-1g.10gb: 1
```

```
$ kubectl -n inference logs embeddings-worker
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-5b1f6c3e-2a7d-4c0e-9f13-8d2b7e64a1c9)
  MIG 1g.10gb     Device  0: (UUID: MIG-0c3d9a2e-71f5-5b8a-a4c1-3e6f0b2d9a47)
```

### 7.4 Scale out horizontally: inference with autoscaling

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llm-inference
  namespace: inference
spec:
  replicas: 2
  selector:
    matchLabels:
      app: llm-inference
  template:
    metadata:
      labels:
        app: llm-inference
    spec:
      nodeSelector:
        nvidia.com/gpu.product: NVIDIA-H100-80GB-HBM3
      containers:
        - name: vllm
          image: vllm/vllm-openai:v0.6.3
          args:
            - "--model"
            - "meta-llama/Llama-3.1-8B-Instruct"
            - "--gpu-memory-utilization"
            - "0.90"
            - "--max-model-len"
            - "8192"
          ports:
            - name: http
              containerPort: 8000
          env:
            - name: HUGGING_FACE_HUB_TOKEN
              valueFrom:
                secretKeyRef:
                  name: hf-token
                  key: token
          resources:
            limits:
              nvidia.com/gpu: 1
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 60
            periodSeconds: 10
          volumeMounts:
            - name: dshm
              mountPath: /dev/shm
      volumes:
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 16Gi
```

Expose a GPU metric from DCGM exporter to the HPA through prometheus-adapter (values fragment for the `prometheus-community/prometheus-adapter` chart):

```yaml
rules:
  default: false
  custom:
    - seriesQuery: 'DCGM_FI_DEV_GPU_UTIL{exported_namespace!="",exported_pod!=""}'
      resources:
        overrides:
          exported_namespace:
            resource: namespace
          exported_pod:
            resource: pod
      name:
        matches: "DCGM_FI_DEV_GPU_UTIL"
        as: "gpu_utilization"
      metricsQuery: 'avg by (<<.GroupBy>>) (DCGM_FI_DEV_GPU_UTIL{<<.LabelMatchers>>})'
```

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: llm-inference
  namespace: inference
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: llm-inference
  minReplicas: 2
  maxReplicas: 8
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Pods
          value: 2
          periodSeconds: 120
    scaleDown:
      stabilizationWindowSeconds: 600
      policies:
        - type: Pods
          value: 1
          periodSeconds: 300
  metrics:
    - type: Pods
      pods:
        metric:
          name: gpu_utilization
        target:
          type: AverageValue
          averageValue: "70"
```

**Architect's note:** GPU utilization is a weak signal for LLM serving. `DCGM_FI_DEV_GPU_UTIL` reports the fraction of time *any* kernel ran, so a decode-bound server can show 100 % while having spare capacity, or show low utilization while requests queue on KV-cache exhaustion. Prefer server metrics such as `vllm:num_requests_waiting` or KV-cache usage, exposed through the same adapter mechanism. Also note that new replicas take minutes (image pull + model load), hence the conservative `behavior` block and a slow scale-down.

### 7.5 Scale out for training: multi-node PyTorchJob over RDMA

Prerequisites: GPU Operator, NVIDIA Network Operator (MOFED/DOCA driver + RDMA shared device plugin), Kubeflow Training Operator. The RDMA resource name depends on your `NicClusterPolicy`.

```yaml
apiVersion: kubeflow.org/v1
kind: PyTorchJob
metadata:
  name: llama-70b-pretrain
  namespace: training
spec:
  runPolicy:
    cleanPodPolicy: Running
  pytorchReplicaSpecs:
    Master:
      replicas: 1
      restartPolicy: OnFailure
      template:
        spec:
          hostNetwork: true
          dnsPolicy: ClusterFirstWithHostNet
          containers:
            - name: pytorch
              image: nvcr.io/nvidia/pytorch:24.10-py3
              command: ["bash", "-c"]
              args:
                - >-
                  torchrun
                  --nnodes=4
                  --nproc-per-node=8
                  --node-rank=${RANK}
                  --master-addr=${MASTER_ADDR}
                  --master-port=${MASTER_PORT}
                  /workspace/train.py --tp 8 --pp 1 --fsdp
              env:
                - name: NCCL_DEBUG
                  value: "INFO"
                - name: NCCL_IB_HCA
                  value: "mlx5_0,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_9,mlx5_10,mlx5_11"
                - name: NCCL_SOCKET_IFNAME
                  value: "bond0"
                - name: NCCL_IB_GID_INDEX
                  value: "3"
              securityContext:
                capabilities:
                  add: ["IPC_LOCK"]
              resources:
                limits:
                  nvidia.com/gpu: 8
                  nvidia.com/rdma_shared_device_a: 1
              volumeMounts:
                - name: dshm
                  mountPath: /dev/shm
                - name: datasets
                  mountPath: /data
          volumes:
            - name: dshm
              emptyDir:
                medium: Memory
                sizeLimit: 64Gi
            - name: datasets
              persistentVolumeClaim:
                claimName: pretrain-datasets
    Worker:
      replicas: 3
      restartPolicy: OnFailure
      template:
        spec:
          hostNetwork: true
          dnsPolicy: ClusterFirstWithHostNet
          containers:
            - name: pytorch
              image: nvcr.io/nvidia/pytorch:24.10-py3
              command: ["bash", "-c"]
              args:
                - >-
                  torchrun
                  --nnodes=4
                  --nproc-per-node=8
                  --node-rank=${RANK}
                  --master-addr=${MASTER_ADDR}
                  --master-port=${MASTER_PORT}
                  /workspace/train.py --tp 8 --pp 1 --fsdp
              env:
                - name: NCCL_DEBUG
                  value: "INFO"
                - name: NCCL_IB_HCA
                  value: "mlx5_0,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_9,mlx5_10,mlx5_11"
                - name: NCCL_SOCKET_IFNAME
                  value: "bond0"
                - name: NCCL_IB_GID_INDEX
                  value: "3"
              securityContext:
                capabilities:
                  add: ["IPC_LOCK"]
              resources:
                limits:
                  nvidia.com/gpu: 8
                  nvidia.com/rdma_shared_device_a: 1
              volumeMounts:
                - name: dshm
                  mountPath: /dev/shm
                - name: datasets
                  mountPath: /data
          volumes:
            - name: dshm
              emptyDir:
                medium: Memory
                sizeLimit: 64Gi
            - name: datasets
              persistentVolumeClaim:
                claimName: pretrain-datasets
```

Design notes:

- `--tp 8` keeps tensor parallelism **inside** the NVLink domain; FSDP shards across nodes over InfiniBand.
- `NCCL_IB_HCA` lists only the **compute** NICs. The list above is the DGX H100 compute-port mapping; confirm yours with `ibdev2netdev` and `nvidia-smi topo -m`. If storage NICs are included, NCCL may route collectives over the wrong fabric.
- `NCCL_IB_GID_INDEX` only matters on RoCE; on native InfiniBand it is ignored.
- `IPC_LOCK` allows pinning (registering) memory for RDMA.
- Gang scheduling (Kueue, Volcano, or Run:ai) prevents 3 of 4 pods holding 24 GPUs while the 4th waits: partial allocation is pure waste.

### 7.6 The same job on Slurm (DGX SuperPOD default)

```bash
#!/bin/bash
#SBATCH --job-name=llama-70b-pretrain
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=8
#SBATCH --gpus-per-node=8
#SBATCH --exclusive
#SBATCH --time=48:00:00
#SBATCH --output=%x-%j.out

export NCCL_DEBUG=INFO
export NCCL_IB_HCA=mlx5_0,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_9,mlx5_10,mlx5_11

srun --mpi=pmix \
     --container-image=nvcr.io#nvidia/pytorch:24.10-py3 \
     --container-mounts=/lustre/datasets:/data \
     python /workspace/train.py --tp 8 --pp 1 --fsdp
```

`--container-image` comes from the Pyxis/Enroot plugins shipped with Base Command Manager. Slurm's topology-aware scheduling (`topology.conf`) places a job on nodes under the same leaf group, which matters as much as GPU count.

### 7.7 Kubernetes vs Slurm for scale

| Criterion | Slurm | Kubernetes |
|---|---|---|
| Gang scheduling | Native | Add-on (Kueue, Volcano, Run:ai) |
| Topology-aware placement | `topology.conf`, mature | Emerging (topology labels, Kueue TAS) |
| Long batch training | Excellent | Good with operators |
| Online inference, autoscaling | Poor fit | Native (Deployments, HPA, Services) |
| Multi-tenancy & self-service | Accounts, QoS, fairshare | Namespaces, quotas, RBAC |
| Typical SuperPOD role | Training partition | Inference and services partition |

Many production platforms run **both**: Slurm for training, Kubernetes for inference and MLOps, managed by Base Command Manager on the same hardware pool.

---

## 8. Verification: proving each layer scales

Verify bottom-up. Never debug a slow 256-GPU job before validating one node.

### 8.1 Node-level topology

```
$ nvidia-smi topo -m
        GPU0    GPU1    GPU2    GPU3    GPU4    GPU5    GPU6    GPU7    NIC0    NIC1    CPU Affinity    NUMA Affinity
GPU0     X      NV18    NV18    NV18    NV18    NV18    NV18    NV18    PIX     SYS     0-55,112-167    0
GPU1    NV18     X      NV18    NV18    NV18    NV18    NV18    NV18    SYS     SYS     0-55,112-167    0
GPU2    NV18    NV18     X      NV18    NV18    NV18    NV18    NV18    SYS     SYS     0-55,112-167    0
GPU3    NV18    NV18    NV18     X      NV18    NV18    NV18    NV18    SYS     SYS     0-55,112-167    0
GPU4    NV18    NV18    NV18    NV18     X      NV18    NV18    NV18    SYS     PIX     56-111,168-223  1
GPU5    NV18    NV18    NV18    NV18    NV18     X      NV18    NV18    SYS     SYS     56-111,168-223  1
GPU6    NV18    NV18    NV18    NV18    NV18    NV18     X      NV18    SYS     SYS     56-111,168-223  1
GPU7    NV18    NV18    NV18    NV18    NV18    NV18    NV18     X      SYS     SYS     56-111,168-223  1
NIC0    PIX     SYS     SYS     SYS     SYS     SYS     SYS     SYS      X      SYS
NIC1    SYS     SYS     SYS     SYS     PIX     SYS     SYS     SYS     SYS      X

Legend:
  X    = Self
  SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes
  NODE = Connection traversing PCIe as well as the interconnect between PCIe Host Bridges within a NUMA node
  PHB  = Connection traversing PCIe as well as a PCIe Host Bridge (typically the CPU)
  PXB  = Connection traversing multiple PCIe bridges (without traversing the PCIe Host Bridge)
  PIX  = Connection traversing at most a single PCIe bridge
  NV#  = Connection traversing a bonded set of # NVLinks
```

(Output trimmed to two NICs.) What to check:

- **`NV18`** between every GPU pair: all 18 NVLink 4 links active through NVSwitch. Anything lower (or `SYS` between GPUs) means a failed link or NVSwitch.
- **`PIX`** between each GPU and its rail NIC: GPUDirect RDMA path through a single PCIe switch.
- CPU/NUMA affinity: pin data loaders to the GPU's NUMA node.

```
$ nvidia-smi nvlink -s -i 0
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-5b1f6c3e-2a7d-4c0e-9f13-8d2b7e64a1c9)
         Link 0: 26.562 GB/s
         Link 1: 26.562 GB/s
         Link 2: 26.562 GB/s
         ...
         Link 17: 26.562 GB/s
```

A link reporting `<inactive>` is a hardware ticket, not a tuning problem.

### 8.2 GPU health with DCGM

```
$ dcgmi discovery -l
8 GPUs found.
+--------+----------------------------------------------------------------------+
| GPU ID | Device Information                                                   |
+--------+----------------------------------------------------------------------+
| 0      | Name: NVIDIA H100 80GB HBM3                                          |
|        | PCI Bus ID: 00000000:18:00.0                                         |
|        | Device UUID: GPU-5b1f6c3e-2a7d-4c0e-9f13-8d2b7e64a1c9                |
...
4 NvSwitches found.
```

```
$ dcgmi diag -r 2
Successfully ran diagnostic for group.
+---------------------------+------------------------------------------------+
| Diagnostic                | Result                                         |
+===========================+================================================+
|-----  Metadata  ----------+------------------------------------------------|
| DCGM Version              | 3.3.9                                          |
| Driver Version Detected   | 550.127.05                                     |
| GPU Device IDs Detected   | 2330,2330,2330,2330,2330,2330,2330,2330        |
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
+---------------------------+------------------------------------------------+
```

Levels: `-r 1` quick (seconds, safe in production), `-r 2` medium (minutes), `-r 3`/`-r 4` long stress tests (run during burn-in or after RMA, never on a node serving traffic).

### 8.3 Fabric health

```
$ ibstat mlx5_0
CA 'mlx5_0'
        CA type: MT4129
        Number of ports: 1
        Firmware version: 28.39.1002
        Hardware version: 0
        Node GUID: 0xa088c20300b4e1f2
        System image GUID: 0xa088c20300b4e1f2
        Port 1:
                State: Active
                Physical state: LinkUp
                Rate: 400
                Base lid: 112
                LMC: 0
                SM lid: 1
                Capability mask: 0xa651e848
                Port GUID: 0xa088c20300b4e1f2
                Link layer: InfiniBand
```

`MT4129` is ConnectX-7; `Rate: 400` is NDR. A port at `Rate: 200` or `Physical state: Polling` is a degraded cable/optic or a port that never trained.

```
$ ibdev2netdev
mlx5_0 port 1 ==> ibp24s0 (Up)
mlx5_1 port 1 ==> enp41s0f0np0 (Up)
mlx5_2 port 1 ==> enp41s0f1np1 (Up)
mlx5_3 port 1 ==> ibp64s0 (Up)
...
```

Point-to-point RDMA bandwidth between two nodes, rail 0 to rail 0, GPU memory to GPU memory:

```
server$ ib_write_bw -d mlx5_0 --use_cuda=0 -s 1048576 --report_gbits
client$ ib_write_bw -d mlx5_0 --use_cuda=0 -s 1048576 --report_gbits dgx-h100-01
---------------------------------------------------------------------------------------
                    RDMA_Write BW Test
 Dual-port       : OFF          Device         : mlx5_0
 Number of qps   : 1            Transport type : IB
 Connection type : RC           Using SRQ      : OFF
 TX depth        : 128
 CQ Moderation   : 100
 Mtu             : 4096[B]
 Link type       : IB
 Max inline data : 0[B]
---------------------------------------------------------------------------------------
 #bytes     #iterations    BW peak[Gb/sec]    BW average[Gb/sec]   MsgRate[Mpps]
 1048576    5000             392.41             392.18               0.046753
---------------------------------------------------------------------------------------
```

~392 Gb/s on a 400 Gb/s link with `--use_cuda` proves GPUDirect RDMA works end to end. A healthy host-memory result with a poor CUDA result points at missing `nvidia-peermem` or a PCIe ACS problem.

```
$ lsmod | grep -E 'nvidia_peermem|nv_peer_mem'
nvidia_peermem         16384  0
```

### 8.4 Collective performance with nccl-tests

Single node (validates NVLink/NVSwitch):

```
$ ./build/all_reduce_perf -b 8 -e 8G -f 2 -g 8
# nThread 1 nGpus 8 minBytes 8 maxBytes 8589934592 step: 2(factor) warmup iters: 5 iters: 20
#
#                                                              out-of-place                       in-place
#       size         count      type   redop    root     time   algbw   busbw #wrong     time   algbw   busbw #wrong
#        (B)    (elements)                               (us)  (GB/s)  (GB/s)            (us)  (GB/s)  (GB/s)
...
  1073741824     268435456     float     sum      -1   4520.1  237.55  415.71      0   4511.8  237.98  416.47      0
  4294967296    1073741824     float     sum      -1    17402  246.81  431.92      0    17389  246.99  432.24      0
  8589934592    2147483648     float     sum      -1    34611  248.18  434.32      0    34598  248.28  434.48      0
# Out of bounds values : 0 OK
# Avg bus bandwidth    : 162.381
```

Multi-node (validates the fabric), 4 nodes × 8 GPUs:

```
$ mpirun -np 32 -N 8 --hostfile hosts \
    -x NCCL_DEBUG=INFO -x NCCL_IB_HCA=mlx5_0,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_9,mlx5_10,mlx5_11 \
    ./build/all_reduce_perf -b 8 -e 8G -f 2 -g 1
...
dgx-h100-01:2211:2290 [0] NCCL INFO Channel 00/0 : 0[0] -> 8[0] [send] via NET/IB/0/GDRDMA
...
  8589934592    2147483648     float     sum      -1    90145   95.29  184.62      0    90088   95.35  184.74      0
# Out of bounds values : 0 OK
# Avg bus bandwidth    : 71.204
```

How to read it:

- **busbw** (bus bandwidth) is normalized to be comparable across GPU counts; compare it against the link speed of the slowest tier crossed. For an all-reduce, `busbw = algbw × 2(n−1)/n`.
- `Avg bus bandwidth` averages *all* sizes, including tiny latency-bound ones. Judge by the large-message rows.
- **`via NET/IB/…/GDRDMA`** in the NCCL log confirms InfiniBand + GPUDirect RDMA. **`via NET/Socket`** means NCCL fell back to TCP: the job will "work" and scale terribly.
- Reproduce the same test at 2, 4, 8, 16 … nodes. A sudden drop at one size identifies the tier (leaf → spine) or the specific node/rail.

The figures above are illustrative; record your own cluster's baseline at acceptance and alert on regressions.

### 8.5 MIG state

```
$ nvidia-smi mig -lgip -i 0
+-----------------------------------------------------------------------------+
| GPU instance profiles:                                                      |
| GPU   Name             ID    Instances   Memory     P2P    SM    DEC   ENC  |
|                              Free/Total   GiB              CE    JPEG  OFA  |
|=============================================================================|
|   0  MIG 1g.10gb       19     0/7        9.75       No     16     1     0   |
|                                                             1     1     0   |
+-----------------------------------------------------------------------------+
|   0  MIG 3g.40gb        9     0/2        39.25      No     60     3     0   |
|                                                             3     3     0   |
+-----------------------------------------------------------------------------+
|   0  MIG 7g.80gb        0     0/1        79.25      No     132    7     0   |
|                                                             8     7     1   |
+-----------------------------------------------------------------------------+
```

(Trimmed.) `Free/Total 0/7` on GPU 0 confirms all seven 1g slices are allocated. Manual configuration outside Kubernetes:

```
$ sudo nvidia-smi -i 4 -mig 1
Enabled MIG Mode for GPU 00000000:9A:00.0
All done.

$ sudo nvidia-smi mig -i 4 -cgi 9,9 -C
Successfully created GPU instance ID  1 on GPU  4 using profile MIG 3g.40gb (ID  9)
Successfully created compute instance ID  0 on GPU  4 GPU instance ID  1 using profile MIG 3g.40gb (ID  2)
Successfully created GPU instance ID  2 on GPU  4 using profile MIG 3g.40gb (ID  9)
Successfully created compute instance ID  0 on GPU  4 GPU instance ID  2 using profile MIG 3g.40gb (ID  2)
```

On a GPU Operator node, let the MIG manager own this. Manual changes get overwritten and confuse the device plugin.

---

## 9. Failure diagnosis

### 9.1 Symptom → cause → check

| Symptom | Likely cause | How to confirm | Fix |
|---|---|---|---|
| Training throughput does not increase from 2 to 4 nodes | NCCL on TCP (`NET/Socket`) | `NCCL_DEBUG=INFO` log | Install/enable `nvidia-peermem`, fix `NCCL_IB_HCA`, give the pod RDMA devices + `IPC_LOCK` |
| One job is slow on some node sets, fine on others | Degraded link/rail or bad optic | `ibstat` rate, `ibdiagnet`, UFM port counters (symbol errors, link-downed) | Replace optic/cable; drain the node until fixed |
| Multi-node busbw roughly half of expected | Oversubscription, cross-rail traffic, storage on compute fabric | nccl-tests across node pairs; check `NCCL_IB_HCA` | Rail-correct NIC mapping, separate storage fabric |
| `nvidia-smi topo -m` shows fewer than `NV18` | Failed NVLink/NVSwitch | `nvidia-smi nvlink -s`, `nvidia-smi nvlink -e` (errors), Xid 74 | Hardware service; cordon the node |
| GPUDirect RDMA slow, host-memory RDMA fast | PCIe ACS forcing P2P through root complex, IOMMU settings | `lspci -vvv` ACS flags, `ib_write_bw --use_cuda` | Disable ACS on PCIe switches (bare metal), validated BIOS settings |
| Pods stuck `Pending` requesting `nvidia.com/mig-1g.10gb` | Wrong MIG strategy (`single` exposes `nvidia.com/gpu`), MIG layout not applied | Node allocatable; `nvidia.com/mig.config.state` label | Use `mixed`, fix label, check mig-manager logs |
| `mig.config.state=failed` | GPU processes still running, or reset required | `kubectl -n gpu-operator logs ds/nvidia-mig-manager` | Drain GPU workloads, retry; some platforms need a reboot |
| Random OOM on time-sliced GPU | No memory isolation between replicas | `nvidia-smi` per-process memory | Move to MIG, or cap per-process memory in the framework |
| Clocks drop under sustained load | Thermal or power capping | `nvidia-smi -q -d PERFORMANCE` (Clocks Event Reasons) | Fix airflow/liquid loop, check PDU/power cap policy |
| Job dies with Xid 79 | GPU fell off the bus | `dmesg`, `journalctl -k` | Cordon, collect `nvidia-bug-report.sh`, RMA |
| Xid 48 / 94 / 95 | ECC errors (double-bit, contained/uncontained) | `nvidia-smi -q -d ECC,ROW_REMAPPER` | Row remap pending → reset GPU; repeated → RMA |
| HPA scales but latency stays high | Wrong signal (GPU util) or slow cold start | Request queue metrics, pod startup time | Scale on queue depth/KV-cache usage, pre-pull images, local model cache |
| Checkpoints stall training | Storage fabric undersized | Write throughput vs required (section 5.3) | Async checkpointing, local NVMe tier, GDS, more storage bandwidth |

### 9.2 Useful forensic commands

```
$ nvidia-smi -q -d PERFORMANCE -i 3
==============NVSMI LOG==============
Attached GPUs                             : 8
GPU 00000000:5D:00.0
    Performance State                     : P0
    Clocks Event Reasons
        Idle                              : Not Active
        Applications Clocks Setting       : Not Active
        SW Power Cap                      : Not Active
        HW Slowdown                       : Active
            HW Thermal Slowdown           : Active
            HW Power Brake Slowdown       : Not Active
        Sync Boost                        : Not Active
        SW Thermal Slowdown               : Not Active
        Display Clock Setting             : Not Active
```

`HW Thermal Slowdown: Active` on one GPU under the same load as its peers is a cooling problem (blocked airflow, failed fan, liquid loop issue). The whole job runs at the speed of that GPU because collectives are synchronous: **one slow GPU slows the whole job**.

```
$ sudo dmesg -T | grep -i xid
[Thu Nov 12 03:41:17 2026] NVRM: Xid (PCI:0000:5d:00): 74, pid=48812, name=python, NVLink: fatal error detected on link 6
```

```
$ dcgmi health -g 0 -c
Health Monitor Report
+----------------------------------------------------------------------------+
| Overall Health: Warning                                                    |
+============================================================================+
| GPU ID: 3                                                                  |
| Warning: NVLink    | Detected 12 NvLink CRC Data errors on GPU 3's NVLink  |
|                    | (should be 0).                                        |
+----------------------------------------------------------------------------+
```

### 9.3 Operational practices at scale

- **Burn-in before production**: `dcgmi diag -r 4` per node, then nccl-tests across every node pair in a leaf, then at full scale. Keep the results as the baseline.
- **Fail fast, drain automatically**: NodeProblemDetector or a health-check DaemonSet consuming DCGM health, taint/cordon bad nodes. At 1,000+ GPUs, something is always broken.
- **Checkpoint frequency** tuned to the cluster's mean time between interruptions: larger clusters fail more often in absolute terms.
- **Topology-aware scheduling**: keep jobs inside a scalable unit / leaf group whenever possible.
- **Capacity planning by facility**: power and cooling usually cap growth before budget does.

---

## 10. Exam focus summary

- **Scale-up = NVLink/NVSwitch** inside a node or rack (H100: 900 GB/s per GPU; B200: 1.8 TB/s). **Scale-out = InfiniBand or Spectrum-X Ethernet** with GPUDirect RDMA between nodes.
- Put **tensor parallelism inside NVLink**, data/pipeline parallelism across the network.
- DGX H100: 8 × H100, 640 GB HBM3, 4 NVSwitch, 8 × ConnectX-7 400 Gb/s for compute (1 NIC per GPU) + 2 dual-port NICs for storage/in-band, ~10.2 kW.
- DGX SuperPOD: **Scalable Units of 32 nodes**, rail-optimized non-blocking fat tree, **four separate networks** (compute, storage, in-band, OOB), Base Command Manager, UFM.
- **BlueField DPU** offloads networking, storage and security from the host and isolates the infrastructure control plane in its own trust domain; **ConnectX/SuperNIC** for the GPU compute fabric.
- **Magnum IO**: GPUDirect RDMA, GPUDirect Storage, SHARP in-network computing, NCCL, UFM.
- Scale **down** with **MIG** (hardware isolation, up to 7 slices), **time-slicing** (no isolation), **MPS**, **vGPU** (VMs, licensed).
- Training scales on bandwidth; inference scales horizontally on replicas and memory (weights + KV cache).
- Validate bottom-up: `nvidia-smi topo -m` → DCGM diag → `ibstat`/`ib_write_bw` → nccl-tests at increasing scale.

---

## Referencias

- NVIDIA Certified Associate: AI Infrastructure and Operations, exam study guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy, AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA Technical Blog, Offloading and Isolating Data Center Workloads with BlueField DPU: https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
- NVIDIA DGX SuperPOD Reference Architecture with DGX B200: https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
- NVIDIA DGX H100 User Guide, component descriptions: https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
- NVIDIA NVLink and NVSwitch: https://www.nvidia.com/en-us/data-center/nvlink/
- NVIDIA Technical Blog, Accelerating IO in the Modern Data Center: Network IO: https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
- NVIDIA GPU Operator documentation (time-slicing, MIG): https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html
- NVIDIA Multi-Instance GPU User Guide: https://docs.nvidia.com/datacenter/tesla/mig-user-guide/index.html
- NVIDIA DCGM documentation: https://docs.nvidia.com/datacenter/dcgm/latest/index.html
- NCCL tests: https://github.com/NVIDIA/nccl-tests
- NVIDIA Network Operator documentation: https://docs.nvidia.com/networking/display/kubernetes/latest/index.html
- Kubeflow Training Operator, PyTorchJob: https://www.kubeflow.org/docs/components/trainer/legacy-v1/user-guides/pytorch/