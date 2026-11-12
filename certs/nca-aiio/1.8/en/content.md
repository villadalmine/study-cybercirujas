# Topic 1.8 — Compare and Contrast GPU and CPU Architectures

**Certification:** NVIDIA-Certified Associate: AI Infrastructure and Operations (NCA-AIIO)
**Exam weight:** 4.75%
**Domain:** Essential AI Knowledge

---

## 1. Motivation: The Architectural Problem in Production

Every AI platform team runs into the same incident sooner or later. A training job lands on a node with eight GPUs, each costing tens of thousands of dollars. `nvidia-smi` shows GPU utilization oscillating between 0% and 35%. Meanwhile `top` shows 32 Python DataLoader workers saturating every CPU core. The GPUs are starved. The CPU, the component nobody budgeted attention for, has become the bottleneck of a multi-million-dollar cluster.

The reverse also happens. A team "saves money" by serving a 7B-parameter LLM on a 128-core CPU server, and token latency is ten times worse than the SLO. The model was never compute-bound on the CPU. It was **memory-bandwidth-bound**, and DDR5 has a fraction of the bandwidth of HBM.

Both failures come from not understanding one design fact: **CPUs and GPUs are optimized for opposite things.**

| Design goal | CPU | GPU |
|---|---|---|
| Primary optimization | **Latency** of a single thread | **Throughput** of many threads |
| Strategy to hide memory latency | Large caches, prefetchers, out-of-order execution, branch prediction | Massive multithreading: switch to another ready warp |
| Transistor budget spent on | Control logic and cache | Arithmetic units (ALUs, Tensor Cores) |
| Ideal workload | Branchy, serial, irregular, OS/control-plane code | Regular, data-parallel, arithmetic-dense (matrix math) |

NVIDIA presents the modern AI data center as **three processors working together**: the **CPU** (general-purpose control and serial work), the **GPU** (accelerated parallel compute), and the **DPU** (BlueField, which offloads networking, storage, and security infrastructure). An AI infrastructure operator has to know which pillar owns which part of the workload, and how to keep the expensive one, the GPU, fed.

---

## 2. CPU Architecture: Built for Latency

### 2.1 Internal Mechanics

A modern server CPU core, such as Intel Xeon (Sapphire/Emerald/Granite Rapids), AMD EPYC (Genoa/Turin), or NVIDIA Grace (Arm Neoverse V2), is a very complex machine whose job is to finish **one instruction stream as fast as possible**:

- **Deep, wide out-of-order (OoO) pipeline.** The core fetches and decodes several instructions per cycle, renames registers, and executes instructions as soon as their operands are ready, not in program order. A reorder buffer with hundreds of entries keeps the speculative state.
- **Branch prediction.** Sophisticated predictors guess the outcome of `if` statements and loops so the pipeline never stalls. A misprediction flushes the pipeline, costing roughly 15–20 cycles.
- **Large multi-level caches.** Per-core L1 (~32–64 KB) and L2 (1–2 MB), plus a shared L3/LLC of tens to hundreds of MB. Caches exist to make memory *look* fast for one thread.
- **SIMD vector units.** AVX-512 / AMX on x86, SVE2 on Arm. These give data parallelism *within* a core, typically 16 FP32 lanes per instruction. Intel AMX adds small tile-matrix units, which helps CPU inference but is still far below GPU Tensor Core throughput.
- **SMT (Hyper-Threading).** 2 hardware threads per core, so there is little ability to hide latency by switching threads.
- **Memory subsystem.** DDR5 with 8–12 channels per socket. Aggregate bandwidth is in the hundreds of GB/s per socket, with **large capacity** (TBs per node).
- **NUMA.** In multi-socket servers each socket owns its local memory and PCIe lanes. Crossing sockets (UPI / Infinity Fabric) adds latency and consumes inter-socket bandwidth.

### 2.2 What the CPU Does in an AI Platform

The CPU is not obsolete in AI infrastructure. It is essential for:

- Running the OS, kubelet, container runtime, drivers, and the CUDA runtime that **launches kernels onto the GPU**.
- **Data ingestion and preprocessing**: JPEG decode, tokenization, augmentation, shuffling, reading from storage. This is unless it is offloaded to GPU (NVIDIA DALI) or to a DPU.
- Orchestrating distributed training: the Python control loop, NCCL bootstrapping, checkpoint serialization.
- Inference request handling: HTTP/gRPC parsing, batching logic, pre/post-processing in Triton Inference Server.
- Classical ML and small models where launch overhead dominates.

---

## 3. GPU Architecture: Built for Throughput

### 3.1 The Streaming Multiprocessor (SM)

An NVIDIA GPU is an array of **Streaming Multiprocessors (SMs)**. Using the Hopper H100 SXM5 as a reference (per NVIDIA's Hopper architecture documentation):

| Component | H100 SXM5 (approx.) |
|---|---|
| SMs | 132 |
| FP32 CUDA cores per SM | 128 → 16,896 total |
| Tensor Cores | 4 per SM (4th gen) → 528 total |
| Register file per SM | 256 KB |
| L1 / shared memory per SM | 256 KB (configurable split) |
| L2 cache | 50 MB |
| Max resident threads per SM | 2,048 (64 warps) |
| Memory | 80 GB HBM3, ~3.35 TB/s |
| NVLink (4th gen) | 900 GB/s bidirectional per GPU |
| TDP | up to 700 W |

Compare the register file: **256 KB per SM** versus a few KB of architectural registers per CPU core. The GPU keeps the state of thousands of threads resident on-chip at once. That is the key to its latency-hiding strategy.

### 3.2 SIMT, Warps, and Latency Hiding

- Threads are grouped into **warps of 32 threads** that execute the same instruction on different data. NVIDIA calls this **SIMT** (Single Instruction, Multiple Threads).
- Threads are organized as **grid → thread blocks → warps → threads**. A block is scheduled onto one SM and shares that SM's shared memory.
- When a warp issues a load to HBM (hundreds of cycles of latency), the **warp scheduler simply switches to another ready warp** in a single cycle. The GPU does not try to make memory fast. It keeps so much work in flight that the latency stops mattering. This is called **occupancy**.
- **Divergence penalty.** If threads in a warp take different branches, the paths are serialized. Branchy code wastes GPU lanes, while the CPU handles it with branch prediction.

### 3.3 Tensor Cores and Reduced Precision

CUDA cores perform scalar FMA operations. **Tensor Cores** perform a whole small matrix multiply-accumulate (`D = A×B + C`) per instruction. Deep learning is dominated by GEMMs (General Matrix Multiplies) and convolutions, so Tensor Cores deliver most of the AI throughput.

Each generation adds lower-precision formats. Lower precision gives more operations per cycle and per byte moved:

| Format | Introduced on Tensor Cores | Typical use |
|---|---|---|
| FP64 | Ampere (A100) | HPC simulation |
| TF32 | Ampere | FP32-like training with no code changes |
| FP16 / BF16 | Volta / Ampere | Mixed-precision training, inference |
| INT8 | Turing | Quantized inference |
| FP8 (E4M3/E5M2) | Hopper (Transformer Engine) | LLM training and inference |
| FP4 / FP6 | Blackwell (2nd-gen Transformer Engine) | Low-precision LLM inference |

The **Transformer Engine** (Hopper and later) dynamically picks FP8 or 16-bit precision per layer to preserve accuracy. **TensorRT** / **TensorRT-LLM** compile models into optimized engines that exploit these precisions, fuse kernels, and maximize Tensor Core utilization for inference.

### 3.4 High-Bandwidth Memory (HBM)

HBM stacks DRAM dies vertically next to the GPU die on a silicon interposer, which gives a very wide bus:

| Memory | Typical bandwidth per device/socket | Capacity per device/socket |
|---|---|---|
| DDR5 (server CPU socket, 8–12 channels) | ~300–600 GB/s | 512 GB – several TB |
| LPDDR5X (Grace CPU) | up to ~500 GB/s | up to 480 GB |
| HBM3 (H100 SXM) | ~3.35 TB/s | 80 GB |
| HBM3e (H200) | ~4.8 TB/s | 141 GB |
| HBM3e (B200) | ~8 TB/s | 192 GB |

**Trade-off:** HBM gives roughly 10× the bandwidth, but much less capacity per device and a much higher cost per GB. This is why large models need multiple GPUs (tensor/pipeline parallelism), and why CPU memory is used for offload (optimizer states, KV-cache spill).

### 3.5 Interconnects: Scale-Up vs. Scale-Out

| Link | Bandwidth (approx.) | Role |
|---|---|---|
| PCIe Gen5 x16 | ~64 GB/s per direction | CPU↔GPU, GPU↔NIC (host path) |
| NVLink 4 (Hopper) | 900 GB/s per GPU | GPU↔GPU within a node / NVLink domain |
| NVLink 5 (Blackwell) | 1.8 TB/s per GPU | GPU↔GPU, NVL72 rack-scale domain |
| NVLink-C2C (Grace Hopper / Grace Blackwell) | 900 GB/s | Coherent CPU↔GPU |
| InfiniBand NDR / Spectrum-X Ethernet | 400 Gb/s per port | Node↔node (scale-out), GPUDirect RDMA |

**NVSwitch** builds a non-blocking all-to-all NVLink fabric, so every GPU in an HGX/DGX node talks to every other GPU at full NVLink speed. **GPUDirect RDMA** lets a NIC read and write GPU memory directly, which bypasses CPU memory. **GPUDirect Storage** does the same for NVMe and storage traffic. Both remove the CPU from the data path. This is one concrete way the architecture compensates for the CPU being the slower pillar.

---

## 4. Head-to-Head Comparison

### 4.1 Architectural Trade-offs

| Dimension | CPU | GPU | Operational consequence |
|---|---|---|---|
| Core count | Tens to ~200 complex cores | Thousands of simple lanes + hundreds of Tensor Cores | GPU wins only if the work can be split into thousands of independent pieces |
| Per-thread performance | Very high (4+ GHz boost, OoO) | Low (~1.5–2 GHz, in-order per warp) | Serial code on a GPU is slower than on a CPU |
| Control logic | Dominant share of die area | Minimal | GPUs are poor at branchy or irregular code |
| Latency hiding | Caches + speculation | Thread-level parallelism (warp switching) | GPUs need large batch sizes for efficiency |
| Memory bandwidth | Hundreds of GB/s | Several TB/s | Memory-bound AI workloads (LLM decode) scale with HBM |
| Memory capacity | TBs | 80–192 GB per GPU | Large models are sharded across GPUs |
| Precision support | FP64/FP32 strong; BF16/INT8 via AMX/VNNI | FP64 down to FP4 with Tensor Cores | Quantization multiplies GPU throughput |
| Programming model | Standard threads, any language | CUDA kernels, libraries (cuBLAS, cuDNN, NCCL, TensorRT) | GPUs depend on the software stack and the driver/CUDA version matrix |
| Power per device | ~250–500 W per socket | 300–1,000+ W per GPU | Rack power density and liquid cooling become design constraints |
| Perf/Watt on AI math | Low | Very high | GPU clusters cost more upfront but less per training run |
| Virtualization/sharing | Mature (cgroups, VMs) | MIG, time-slicing, MPS, vGPU | GPU sharing needs explicit configuration |

### 4.2 CPU vs. GPU vs. DPU

| | CPU | GPU | DPU (BlueField) |
|---|---|---|---|
| Purpose | General-purpose compute, control plane | Accelerated parallel compute | Data-center infrastructure offload |
| AI role | Orchestration, preprocessing, serving logic | Training, inference math | Networking (RDMA, OVS), storage (NVMe-oF), security (isolation, crypto) |
| Frees up | — | CPU from math | CPU from infrastructure tasks |

### 4.3 Workload Placement Guide

| Workload | Best fit | Why |
|---|---|---|
| Training a transformer | GPU (multi-node, NVLink + InfiniBand) | Arithmetic-dense GEMMs, collective communication |
| LLM inference, decode phase | GPU with high HBM bandwidth | Memory-bound: each token reads all weights |
| LLM inference, prefill phase | GPU Tensor Cores | Compute-bound GEMMs over the whole prompt |
| Tokenization, JSON parsing, request routing | CPU | Serial, branchy, string-heavy |
| Image decode/augment at high throughput | CPU, or GPU via DALI | CPU by default; offload to GPU when CPU-bound |
| Gradient-boosted trees, small tabular data | CPU (or GPU via RAPIDS cuML/XGBoost at large scale) | Small data does not amortize GPU overhead |
| ETL on terabytes of tabular data | GPU via RAPIDS / Spark RAPIDS | Columnar operations parallelize well |
| Kubernetes control plane, databases | CPU | No data-parallel math |

---

## 5. Quantitative Reasoning: Compute-Bound vs. Memory-Bound

The **roofline model** decides which architecture property matters. **Arithmetic intensity** = FLOPs performed / bytes moved from memory.

```
ridge point = peak FLOP/s / memory bandwidth (B/s)

H100 SXM, dense BF16 Tensor Core:  ~989 TFLOP/s / 3.35 TB/s  ≈ 295 FLOP/byte
```

- Arithmetic intensity **below** the ridge point → **memory-bound**. Performance scales with bandwidth.
- Arithmetic intensity **above** the ridge point → **compute-bound**. Performance scales with FLOPs.

**Worked example: LLM decode at batch size 1.** A 7B-parameter model in BF16 occupies ~14 GB. Generating one token reads essentially every weight once, at ~2 FLOPs per parameter, which is ~1 FLOP/byte. That is deeply memory-bound.

```
Upper bound tokens/s ≈ memory bandwidth / model bytes

H100 (3.35 TB/s):       3,350 GB/s / 14 GB ≈ 239 tokens/s
CPU socket (~300 GB/s):   300 GB/s / 14 GB ≈  21 tokens/s
```

The order-of-magnitude gap comes from **memory bandwidth, not core count**. Batching many requests raises arithmetic intensity, because weights are read once per batch. This is why inference servers (Triton, TensorRT-LLM, NIM) use in-flight/continuous batching to move toward the compute-bound regime.

**Amdahl's Law applies to the whole pipeline.** If 10% of each training step is serial CPU work (data loading, Python overhead), the maximum speedup from infinitely fast GPUs is 10×. Accelerating the GPU part alone eventually hits the CPU wall. That is exactly the incident described in Section 1.

---

## 6. Hybrid Architectures: Closing the CPU–GPU Gap

- **Discrete PCIe topology (classic x86 + GPU).** The CPU and GPU have separate memories. Data is copied over PCIe (~64 GB/s per direction on Gen5), which is far slower than HBM. Pinned (page-locked) host memory and asynchronous copies (`cudaMemcpyAsync`, CUDA streams) overlap transfer and compute.
- **HGX/DGX systems.** 8 GPUs on an NVSwitch baseboard, dual x86 CPUs, and a 1:1 GPU-to-NIC ratio for GPUDirect RDMA. The CPU-to-GPU affinity follows the PCIe topology: GPUs 0–3 hang off socket 0 and GPUs 4–7 off socket 1.
- **Grace Hopper (GH200) / Grace Blackwell (GB200).** An NVIDIA Grace Arm CPU (72 Neoverse V2 cores, LPDDR5X) connected to the GPU over **NVLink-C2C at 900 GB/s**, with cache-coherent unified memory. The GPU can access CPU memory at roughly 7× PCIe Gen5 bandwidth. This makes large CPU memory a practical extension for KV caches, embeddings, and large models. The GB200 NVL72 joins 36 Grace CPUs and 72 Blackwell GPUs in one NVLink domain.

---

## 7. Kubernetes: Exposing Both Architectures Correctly

On Kubernetes, CPUs are a native resource: cgroups, `cpu` requests and limits, and the CPU Manager handle them. GPUs are an **extended resource** (`nvidia.com/gpu`) advertised by the **NVIDIA device plugin**. The **NVIDIA GPU Operator** automates the whole GPU software stack as Kubernetes components: driver, NVIDIA Container Toolkit, device plugin, GPU Feature Discovery (GFD), DCGM exporter, MIG manager, and validator.

### 7.1 Install the GPU Operator

```
$ helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
"nvidia" has been added to your repositories
...Successfully got an update from the "nvidia" chart repository

$ helm install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator --create-namespace --wait
NAME: gpu-operator
NAMESPACE: gpu-operator
STATUS: deployed
REVISION: 1

$ kubectl get pods -n gpu-operator
NAME                                                          READY   STATUS      RESTARTS   AGE
gpu-feature-discovery-7xk2p                                   1/1     Running     0          4m
gpu-operator-6d8b4c9f7-q9lwz                                  1/1     Running     0          5m
gpu-operator-node-feature-discovery-gc-5b7f9c8d6-hv2mn        1/1     Running     0          5m
gpu-operator-node-feature-discovery-master-7c9d8f5b4-x2kfp    1/1     Running     0          5m
gpu-operator-node-feature-discovery-worker-j8m4t              1/1     Running     0          5m
nvidia-container-toolkit-daemonset-4mzrw                      1/1     Running     0          4m
nvidia-cuda-validator-p7v2c                                   0/1     Completed   0          2m
nvidia-dcgm-exporter-vt9qk                                    1/1     Running     0          4m
nvidia-device-plugin-daemonset-lw7sx                          1/1     Running     0          4m
nvidia-driver-daemonset-8rn5d                                 1/1     Running     0          5m
nvidia-operator-validator-kq4jd                               1/1     Running     0          4m
```

Check how the node now advertises **both** architectures:

```
$ kubectl describe node gpu-node-01 | sed -n '/Capacity:/,/Allocatable:/p'
Capacity:
  cpu:                224
  ephemeral-storage:  1843069856Ki
  hugepages-1Gi:      0
  hugepages-2Mi:      0
  memory:             2113362764Ki
  nvidia.com/gpu:     8
  pods:               110
Allocatable:

$ kubectl get node gpu-node-01 -o json | jq '.metadata.labels | with_entries(select(.key | startswith("nvidia.com/gpu")))'
{
  "nvidia.com/gpu.compute.major": "9",
  "nvidia.com/gpu.compute.minor": "0",
  "nvidia.com/gpu.count": "8",
  "nvidia.com/gpu.family": "hopper",
  "nvidia.com/gpu.machine": "DGXH100",
  "nvidia.com/gpu.memory": "81559",
  "nvidia.com/gpu.present": "true",
  "nvidia.com/gpu.product": "NVIDIA-H100-80GB-HBM3",
  "nvidia.com/gpu.replicas": "1"
}
```

### 7.2 Kubelet: NUMA-Aware CPU and GPU Alignment

By default, a pod requesting 1 GPU and 16 CPUs can get a GPU on socket 1 and CPUs on socket 0. Every host-to-device copy then crosses the inter-socket link. The **Topology Manager** aligns the CPU Manager, Memory Manager, and device plugin hints to the same NUMA node.

`/var/lib/kubelet/config.yaml` (relevant fields, complete and valid):

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
cpuManagerPolicy: static
cpuManagerPolicyOptions:
  full-pcpus-only: "true"
cpuManagerReconcilePeriod: 10s
memoryManagerPolicy: Static
topologyManagerPolicy: best-effort
topologyManagerScope: pod
reservedSystemCPUs: "0,1,112,113"
kubeReserved:
  memory: 1Gi
systemReserved:
  memory: 1Gi
evictionHard:
  memory.available: 100Mi
reservedMemory:
  - numaNode: 0
    limits:
      memory: 2148Mi
```

Notes:
- `static` CPU Manager gives **exclusive cores** only to Guaranteed-QoS pods with integer CPU requests.
- `full-pcpus-only` allocates whole physical cores (both SMT siblings). This avoids noisy-neighbor effects on the data-loading threads.
- With `memoryManagerPolicy: Static`, the sum of `reservedMemory` must equal `kubeReserved` + `systemReserved` + `evictionHard` memory (1024 + 1024 + 100 = 2148 Mi).
- `topologyManagerPolicy` trade-off: `single-numa-node` gives the strictest alignment but **rejects pods that cannot fit in one NUMA node**. On a DGX H100, GPUs 0–3 are on NUMA 0 and GPUs 4–7 on NUMA 1. Under `single-numa-node`, an 8-GPU pod fails admission with `TopologyAffinityError`. Use `best-effort` or `restricted` on nodes that run full-node training jobs. Reserve `single-numa-node` for nodes dedicated to ≤4-GPU inference pods.

Changing `cpuManagerPolicy` requires draining the node, deleting `/var/lib/kubelet/cpu_manager_state`, and restarting kubelet. Do the same for `memory_manager_state` when changing the memory manager policy.

### 7.3 A CPU-vs-GPU Benchmark Job

This Job runs the same GEMM on the CPU and on the GPU. It makes the throughput gap measurable on your own hardware.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: arch-lab
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: gemm-bench
  namespace: arch-lab
data:
  bench.py: |
    import os
    import time
    import torch

    def bench(device, n, dtype, iters):
        a = torch.randn(n, n, device=device, dtype=dtype)
        b = torch.randn(n, n, device=device, dtype=dtype)
        torch.matmul(a, b)
        if device == "cuda":
            torch.cuda.synchronize()
        t0 = time.perf_counter()
        for _ in range(iters):
            torch.matmul(a, b)
        if device == "cuda":
            torch.cuda.synchronize()
        dt = (time.perf_counter() - t0) / iters
        tflops = 2 * n ** 3 / dt / 1e12
        print(f"{device:5s} {str(dtype):15s} n={n} {dt * 1000:9.2f} ms/iter {tflops:9.2f} TFLOP/s", flush=True)

    torch.set_num_threads(int(os.environ.get("CPU_THREADS", "16")))
    print(f"torch {torch.__version__}, CPU threads: {torch.get_num_threads()}", flush=True)
    print(f"GPU: {torch.cuda.get_device_name(0)}", flush=True)

    bench("cpu", 8192, torch.float32, 3)
    bench("cpu", 8192, torch.bfloat16, 3)

    torch.backends.cuda.matmul.allow_tf32 = False
    bench("cuda", 8192, torch.float32, 50)
    torch.backends.cuda.matmul.allow_tf32 = True
    bench("cuda", 8192, torch.float32, 50)
    bench("cuda", 8192, torch.bfloat16, 50)
    bench("cuda", 8192, torch.float16, 50)
---
apiVersion: batch/v1
kind: Job
metadata:
  name: gemm-cpu-vs-gpu
  namespace: arch-lab
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app: gemm-bench
    spec:
      restartPolicy: Never
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: nvidia.com/gpu.family
                    operator: In
                    values:
                      - hopper
                      - blackwell
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      containers:
        - name: bench
          image: nvcr.io/nvidia/pytorch:24.08-py3
          command:
            - python
            - /bench/bench.py
          env:
            - name: CPU_THREADS
              value: "16"
            - name: OMP_NUM_THREADS
              value: "16"
          resources:
            requests:
              cpu: "16"
              memory: 64Gi
              nvidia.com/gpu: 1
            limits:
              cpu: "16"
              memory: 64Gi
              nvidia.com/gpu: 1
          volumeMounts:
            - name: bench
              mountPath: /bench
              readOnly: true
            - name: dshm
              mountPath: /dev/shm
      volumes:
        - name: bench
          configMap:
            name: gemm-bench
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 8Gi
```

Key design points:
- `requests == limits` with integer CPU → **Guaranteed QoS** → exclusive, NUMA-aligned cores under the static CPU Manager.
- `nvidia.com/gpu` is set in `limits`. Extended resources cannot be overcommitted, and a request, if given, must equal the limit.
- `/dev/shm` as a memory-backed `emptyDir`. PyTorch DataLoader workers exchange tensors through shared memory, and the 64 MB container default causes `Bus error` crashes.

```
$ kubectl apply -f gemm-bench.yaml
namespace/arch-lab created
configmap/gemm-bench created
job.batch/gemm-cpu-vs-gpu created

$ kubectl -n arch-lab wait --for=condition=complete job/gemm-cpu-vs-gpu --timeout=15m
job.batch/gemm-cpu-vs-gpu condition met

$ kubectl -n arch-lab logs job/gemm-cpu-vs-gpu
torch 2.5.0a0+872d972e41.nv24.08, CPU threads: 16
GPU: NVIDIA H100 80GB HBM3
cpu   torch.float32   n=8192    812.44 ms/iter      1.35 TFLOP/s
cpu   torch.bfloat16  n=8192    402.17 ms/iter      2.73 TFLOP/s
cuda  torch.float32   n=8192     22.91 ms/iter     48.00 TFLOP/s
cuda  torch.float32   n=8192      3.12 ms/iter    352.40 TFLOP/s
cuda  torch.bfloat16  n=8192      1.64 ms/iter    670.42 TFLOP/s
cuda  torch.float16   n=8192      1.61 ms/iter    682.91 TFLOP/s
```

The numbers are illustrative. Your hardware, clocks, and library versions will differ. The **ratios** are the lesson:
- FP32 on CUDA cores is ~35× the 16-core CPU.
- Enabling TF32 routes the same FP32 code onto Tensor Cores for another ~7×.
- BF16 Tensor Cores reach ~500× the CPU FP32 baseline.
- Most of the GPU advantage on AI math comes from **Tensor Cores plus reduced precision**, not just "more cores."

### 7.4 GPU Sharing: A Concept With No CPU Equivalent

CPUs are shared at fine granularity by the kernel scheduler and cgroups. GPUs need explicit mechanisms:

| Mechanism | Isolation | Granularity | Use case |
|---|---|---|---|
| Whole GPU | Full | 1 GPU | Training, large inference |
| MIG (A100/H100/H200/B200) | Hardware: dedicated SMs, L2 slices, HBM partition | Up to 7 instances | Multi-tenant inference with QoS guarantees |
| Time-slicing | None (shared memory, context switching) | N replicas | Dev/test, bursty, low-utilization workloads |
| MPS | Partial (concurrent kernels, limited fault isolation) | Percent of SMs | Many small cooperative inference processes |
| vGPU | Hypervisor-level | Profiles | VM-based virtualization |

Time-slicing configuration for the GPU Operator's device plugin:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
  namespace: gpu-operator
data:
  any: |-
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

```
$ kubectl apply -f time-slicing-config.yaml
configmap/time-slicing-config created

$ kubectl patch clusterpolicies.nvidia.com/cluster-policy -n gpu-operator --type merge \
    -p '{"spec": {"devicePlugin": {"config": {"name": "time-slicing-config", "default": "any"}}}}'
clusterpolicy.nvidia.com/cluster-policy patched

$ kubectl get node gpu-node-01 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}{.metadata.labels.nvidia\.com/gpu\.replicas}{"\n"}'
32
4
```

MIG with the single strategy, using the MIG manager label:

```
$ kubectl label node gpu-node-01 nvidia.com/mig.config=all-1g.10gb --overwrite
node/gpu-node-01 labeled

$ kubectl get node gpu-node-01 -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}{"\n"}'
success
```

---

## 8. Host-Level CLI: Reading the Architecture

### 8.1 CPU Side

```
$ lscpu | grep -E 'Model name|Socket|Core\(s\)|Thread|NUMA|L3|Flags' | cut -c1-120
Model name:                      Intel(R) Xeon(R) Platinum 8480C
Thread(s) per core:              2
Core(s) per socket:              56
Socket(s):                       2
L3 cache:                        210 MiB (2 instances)
NUMA node(s):                    2
NUMA node0 CPU(s):               0-55,112-167
NUMA node1 CPU(s):               56-111,168-223
Flags:                           fpu vme de pse ... avx512f avx512_bf16 amx_bf16 amx_tile amx_int8 ...

$ numactl --hardware
available: 2 nodes (0-1)
node 0 cpus: 0 1 2 ... 55 112 113 ... 167
node 0 size: 1031629 MB
node 0 free: 987412 MB
node 1 cpus: 56 57 ... 111 168 ... 223
node 1 size: 1032142 MB
node 1 free: 990236 MB
node distances:
node   0   1
  0:  10  21
  1:  21  10
```

Distance 21 vs. 10 means remote memory access costs about 2.1× local. That penalty is why NUMA alignment matters.

### 8.2 GPU Side

```
$ nvidia-smi --query-gpu=index,name,memory.total,clocks.max.sm,power.limit,pcie.link.gen.max,pcie.link.width.max --format=csv
index, name, memory.total [MiB], clocks.max.sm [MHz], power.limit [W], pcie.link.gen.max, pcie.link.width.max
0, NVIDIA H100 80GB HBM3, 81559 MiB, 1980 MHz, 700.00 W, 5, 16
1, NVIDIA H100 80GB HBM3, 81559 MiB, 1980 MHz, 700.00 W, 5, 16
...
7, NVIDIA H100 80GB HBM3, 81559 MiB, 1980 MHz, 700.00 W, 5, 16
```

`deviceQuery` from the CUDA samples shows the SM/warp structure:

```
$ ./deviceQuery | grep -E 'Device 0|Multiprocessors|Warp size|threads per multiprocessor|threads per block|Memory Bus|L2 Cache'
Device 0: "NVIDIA H100 80GB HBM3"
  (132) Multiprocessors, (128) CUDA Cores/MP:    16896 CUDA Cores
  Memory Bus Width:                              5120-bit
  L2 Cache Size:                                 52428800 bytes
  Maximum number of threads per multiprocessor:  2048
  Maximum number of threads per block:           1024
  Warp size:                                     32
```

Compare the **5120-bit** HBM bus with a 64-bit DDR5 channel. Bus width is where the bandwidth comes from.

### 8.3 Topology: The CPU–GPU–NIC Map

```
$ nvidia-smi topo -m
        GPU0  GPU1  GPU2  GPU3  GPU4  GPU5  GPU6  GPU7  NIC0  NIC1  CPU Affinity     NUMA Affinity  GPU NUMA ID
GPU0     X    NV18  NV18  NV18  NV18  NV18  NV18  NV18  PIX   SYS   0-55,112-167     0              N/A
GPU1    NV18   X    NV18  NV18  NV18  NV18  NV18  NV18  SYS   SYS   0-55,112-167     0              N/A
GPU2    NV18  NV18   X    NV18  NV18  NV18  NV18  NV18  SYS   SYS   0-55,112-167     0              N/A
GPU3    NV18  NV18  NV18   X    NV18  NV18  NV18  NV18  SYS   SYS   0-55,112-167     0              N/A
GPU4    NV18  NV18  NV18  NV18   X    NV18  NV18  NV18  SYS   PIX   56-111,168-223   1              N/A
GPU5    NV18  NV18  NV18  NV18  NV18   X    NV18  NV18  SYS   SYS   56-111,168-223   1              N/A
GPU6    NV18  NV18  NV18  NV18  NV18  NV18   X    NV18  SYS   SYS   56-111,168-223   1              N/A
GPU7    NV18  NV18  NV18  NV18  NV18  NV18  NV18   X    SYS   SYS   56-111,168-223   1              N/A
NIC0    PIX   SYS   SYS   SYS   SYS   SYS   SYS   SYS    X    SYS
NIC1    SYS   SYS   SYS   SYS   PIX   SYS   SYS   SYS   SYS    X

Legend:
  X    = Self
  SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes (e.g., QPI/UPI)
  NODE = Connection traversing PCIe as well as the interconnect between PCIe Host Bridges within a NUMA node
  PHB  = Connection traversing PCIe as well as a PCIe Host Bridge (typically the CPU)
  PXB  = Connection traversing multiple PCIe bridges (without traversing the PCIe Host Bridge)
  PIX  = Connection traversing at most a single PCIe bridge
  NV#  = Connection traversing a bonded set of # NVLinks
```

How to read it:
- `NV18`: 18 bonded NVLink 4 links between every GPU pair (via NVSwitch), so GPU↔GPU traffic never touches the CPU.
- `PIX` between GPU and NIC: they share a PCIe switch, which is the ideal path for GPUDirect RDMA.
- `SYS`: traffic crosses the CPU sockets, the slowest path. NCCL avoids it when it can.
- `CPU Affinity` tells you which cores to pin a GPU's feeding process to.

---

## 9. Verification and Failure Diagnosis

### 9.1 Symptom: Low GPU Utilization, High CPU (CPU-Bound Input Pipeline)

```
$ nvidia-smi dmon -s u -c 5
# gpu    sm   mem   enc   dec   jpg   ofa
# Idx     %     %     %     %     %     %
    0    31    12     0     0     0     0
    0     0     0     0     0     0     0
    0    28    10     0     0     0     0
    0     0     0     0     0     0     0
    0    35    13     0     0     0     0

$ top -b -n1 -o %CPU | head -12
    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
 418223 trainer   20   0   38.1g   9.2g   1.1g R  99.7   0.4  12:03.11 pt_data_worker
 418224 trainer   20   0   38.1g   9.1g   1.1g R  99.7   0.4  12:02.87 pt_data_worker
 ...
```

The saw-tooth pattern (busy, idle, busy) means the GPU finishes each batch and then waits for the CPU.

**Fixes, in order of effort:**
1. Increase `num_workers`, and enable `pin_memory=True` and `prefetch_factor` in the DataLoader. Give the pod enough Guaranteed CPUs and a large `/dev/shm`.
2. Move decode/augmentation to the GPU (NVIDIA DALI, nvJPEG). Move ETL to the GPU (RAPIDS).
3. Preprocess offline into efficient formats (WebDataset, TFRecord, Parquet) so the training loop only reads.
4. Check storage throughput. If the CPU is in `iowait`, the storage tier, not the CPU, is the bottleneck. GPUDirect Storage removes the CPU bounce buffer.

Rule of thumb: plan **several CPU cores per GPU** for vision training. NVIDIA reference systems ship roughly 14 physical cores per GPU (112 cores / 8 GPUs on DGX H100).

### 9.2 Symptom: Slow Host↔Device Transfers (PCIe Downtraining or NUMA Mismatch)

```
$ nvidia-smi -q -i 3 -d PCI | grep -A3 -E 'Link Width|PCIe Generation'
        PCIe Generation
            Max                       : 5
            Current                   : 3
            Device Current            : 3
        Link Width
            Max                       : 16x
            Current                   : 8x
```

A Gen3 x8 link under load delivers about a quarter of Gen5 x16 bandwidth. Idle GPUs legitimately drop to lower PCIe gen to save power, so **check under load**. A persistent downtrain under load points to a reseat, riser, or firmware problem. Corroborate with `lspci -vv -s <bus_id> | grep LnkSta`, and escalate as a hardware issue.

For NUMA problems, check which CPUs the process actually runs on against the GPU's `CPU Affinity` from `nvidia-smi topo -m`:

```
$ taskset -cp $(pgrep -f train.py | head -1)
pid 418201's current affinity list: 56-71
```

If the process uses GPU0 (NUMA 0, CPUs 0–55), it is on the wrong socket. In Kubernetes, verify that the CPU Manager and Topology Manager are active:

```
$ sudo cat /var/lib/kubelet/cpu_manager_state | jq .
{
  "policyName": "static",
  "defaultCpuSet": "2-55,57-111,114-167,169-223",
  "entries": {
    "7f3c1e2a-...": {
      "bench": "0,1,56,112,113,168"
    }
  },
  "checksum": 1834201147
}
```

### 9.3 Symptom: Pod Rejected With `TopologyAffinityError`

```
$ kubectl -n arch-lab get pods
NAME                    READY   STATUS                   RESTARTS   AGE
train-8gpu-6m2xk        0/1     TopologyAffinityError    0          8s

$ kubectl -n arch-lab describe pod train-8gpu-6m2xk | tail -3
  Warning  TopologyAffinityError  8s    kubelet  Resources cannot be allocated with Topology locality
```

The cause is `topologyManagerPolicy: single-numa-node` with a request that spans both sockets: 8 GPUs, or more CPUs than one NUMA node has. Either reduce the request, or schedule the pod onto nodes using `best-effort`/`restricted`.

### 9.4 Symptom: GPU Throughput Drops Over Time (Thermal/Power Throttling)

```
$ nvidia-smi -q -i 0 -d PERFORMANCE
==============NVSMI LOG==============
Attached GPUs                             : 8
GPU 00000000:1B:00.0
    Performance State                     : P0
    Clocks Event Reasons
        Idle                              : Not Active
        Applications Clocks Setting       : Not Active
        SW Power Cap                      : Active
        HW Slowdown                       : Not Active
            HW Thermal Slowdown           : Not Active
            HW Power Brake Slowdown       : Not Active
        Sync Boost                        : Not Active
        SW Thermal Slowdown               : Not Active
        Display Clock Setting             : Not Active

$ nvidia-smi --query-gpu=index,temperature.gpu,temperature.memory,power.draw,clocks.sm --format=csv
index, temperature.gpu, temperature.memory, power.draw [W], clocks.sm [MHz]
0, 71, 82, 699.14 W, 1650 MHz
```

`SW Power Cap: Active` at ~700 W is **normal** under a heavy GEMM load: the GPU is using its full power budget. `HW Thermal Slowdown` or `HW Power Brake Slowdown` is **not** normal. It points to cooling, airflow, or PSU/rack power problems. GPU racks often exceed 40 kW and frequently require liquid cooling, which is a facility-level difference from CPU-only racks.

### 9.5 Symptom: GPU Errors and Disappearing Devices (XID Events)

```
$ sudo dmesg -T | grep -i xid
[Wed Nov 12 09:41:07 2026] NVRM: Xid (PCI:0000:9a:00): 79, pid=418223, GPU has fallen off the bus.
```

| XID | Meaning | Typical action |
|---|---|---|
| 13 / 31 / 43 | Application fault (illegal access, MMU fault, stopped kernel) | Usually a software bug: check the job |
| 48 | Double-bit ECC error | Drain the node, reset the GPU, RMA if it repeats |
| 63 / 64 | Row-remapping event / failure | Check `nvidia-smi -q -d ROW_REMAPPER`; reset to apply |
| 74 | NVLink error | Check `nvidia-smi nvlink -s`, reseat, fabric manager |
| 79 | GPU fell off the bus | Hardware/PCIe/power: drain and investigate |
| 94 / 95 | Contained / uncontained ECC error | 94: restart the affected app; 95: reset the GPU |

Run active diagnostics with DCGM:

```
$ dcgmi diag -r 2
Successfully ran diagnostic for group.
+---------------------------+------------------------------------------------+
| Diagnostic                | Result                                         |
+===========================+================================================+
|-----  Metadata  ----------+------------------------------------------------|
| DCGM Version              | 3.3.7                                          |
| Driver Version Detected   | 550.90.07                                      |
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

In Kubernetes, the GPU Operator's **DCGM exporter** publishes these signals as Prometheus metrics, for example `DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_PROF_SM_ACTIVE`, `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE`, `DCGM_FI_DEV_XID_ERRORS`, and `DCGM_FI_PROF_PCIE_RX_BYTES`. An alert that pairs low `DCGM_FI_PROF_SM_ACTIVE` with high node CPU usage catches the CPU-bound pipeline from Section 9.1 automatically:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gpu-starvation
  namespace: gpu-operator
spec:
  groups:
    - name: gpu-cpu-balance
      rules:
        - alert: GPUStarvedByCPU
          expr: |
            avg by (Hostname) (DCGM_FI_PROF_SM_ACTIVE) < 0.4
            and on (Hostname)
            label_replace(
              1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])),
              "Hostname", "$1", "instance", "([^:]+).*"
            ) > 0.9
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "GPUs on {{ $labels.Hostname }} are idle while CPUs are saturated"
            description: "SM activity below 40% with CPU above 90% for 15m. Likely a CPU-bound input pipeline: review DataLoader workers, consider DALI or GPU preprocessing."
```

The `label_replace` joins the DCGM `Hostname` label to the node-exporter `instance` label. Adapt the regex if your `instance` values are FQDNs or IPs rather than node names.

### 9.6 Quick Triage Checklist

| Check | Command | Healthy |
|---|---|---|
| Driver and GPUs visible | `nvidia-smi -L` | All expected GPUs listed |
| Kubernetes sees GPUs | `kubectl get node -o jsonpath='{..allocatable.nvidia\.com/gpu}'` | Matches physical count (or × replicas) |
| Operator healthy | `kubectl get pods -n gpu-operator` | All Running/Completed |
| Topology | `nvidia-smi topo -m` | NV# between GPUs, PIX/PXB to NICs |
| PCIe under load | `nvidia-smi -q -d PCI` | Gen5 x16 (or platform max) |
| Clocks/throttling | `nvidia-smi -q -d PERFORMANCE` | No HW slowdown |
| Health | `dcgmi diag -r 2` | All Pass |
| CPU pinning | `cat /var/lib/kubelet/cpu_manager_state` | `static`, pod entries present |
| Feeding balance | `nvidia-smi dmon -s u` + `top` | Steady high SM%, CPU not pegged |

---

## 10. Exam-Oriented Summary

- **CPU = latency-optimized**: few powerful cores, OoO execution, branch prediction, big caches, high-capacity DDR memory. It runs serial, branchy, control-plane, OS, and preprocessing work.
- **GPU = throughput-optimized**: thousands of simple cores organized in SMs, 32-thread warps (SIMT), latency hidden by massive multithreading, Tensor Cores for matrix math, HBM for very high bandwidth. It runs parallel, arithmetic-dense AI training and inference.
- **They are complementary**, not competitors. The CPU orchestrates and feeds, and the GPU computes. The **DPU** is the third pillar and offloads networking, storage, and security.
- **Tensor Cores + reduced precision** (TF32, BF16, FP8, FP4) give most of the GPU's AI speedup. TensorRT and the Transformer Engine exploit them.
- **LLM inference decode is memory-bandwidth-bound**, so HBM bandwidth predicts tokens/s better than FLOPS.
- **Interconnects matter**: PCIe for host↔device, NVLink/NVSwitch for GPU↔GPU, NVLink-C2C for coherent CPU↔GPU (Grace Hopper), InfiniBand/Ethernet with GPUDirect RDMA across nodes.
- **On Kubernetes**, CPUs are native resources and GPUs are extended resources (`nvidia.com/gpu`) managed by the GPU Operator. Alignment needs CPU Manager + Topology Manager. Sharing needs MIG, time-slicing, or MPS.
- The **classic production failure** is GPU starvation from an under-provisioned CPU/data pipeline (Amdahl's Law).

### Practice Questions

1. *Why does a GPU tolerate high memory latency better than a CPU?*
   It keeps many warps resident and switches to a ready warp in one cycle (thread-level parallelism). A CPU relies on caches and speculation for a single thread.
2. *An LLM serving cluster shows high latency per token at batch size 1, but low SM utilization. Which hardware property limits it?*
   Memory bandwidth (HBM). Decode is memory-bound. Batching raises arithmetic intensity.
3. *Which workload should stay on the CPU: JSON request parsing, FP8 GEMM, or all-reduce of gradients?*
   JSON request parsing.
4. *What feature lets a NIC write directly into GPU memory, bypassing host memory?*
   GPUDirect RDMA.
5. *Which GPU-sharing mechanism provides hardware isolation of SMs and memory?*
   MIG.

---

## References

- NVIDIA AI Infrastructure and Operations (NCA-AIIO) exam study guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy, AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA TensorRT: https://developer.nvidia.com/tensorrt
- NVIDIA AI Inference: https://developer.nvidia.com/topics/ai/ai-inference
- Tips on Scaling Storage for AI Training and Inferencing: https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
- What Are Large Language Models Used For?: https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
- NVIDIA GPU Operator: Simplifying GPU Management in Kubernetes: https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes
- NVIDIA Hopper Architecture In-Depth: https://developer.nvidia.com/blog/nvidia-hopper-architecture-in-depth/
- CUDA C++ Programming Guide (hardware implementation, SIMT): https://docs.nvidia.com/cuda/cuda-c-programming-guide/
- NVIDIA GPU Operator documentation (time-slicing, MIG): https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/
- NVIDIA DCGM documentation: https://docs.nvidia.com/datacenter/dcgm/latest/
- NVIDIA XID errors reference: https://docs.nvidia.com/deploy/xid-errors/
- Kubernetes Topology Manager: https://kubernetes.io/docs/tasks/administer-cluster/topology-manager/
- Kubernetes CPU Management Policies: https://kubernetes.io/docs/tasks/administer-cluster/cpu-management-policies/
- Kubernetes Device Plugins: https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/