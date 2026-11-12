# 1.6 — Purpose and Use Case of NVIDIA Solutions

> **Exam weight:** 4.75 (NCA-AIIO, version unknown)
> **Profile:** Platform Architect / SRE. The goal is to map each NVIDIA product to the production problem it solves, the stack layer it lives in, and the signals that tell you it is or is not working.

---

## 1. Motivation: the production problem

A GPU on its own is a PCIe device that consumes power. Turning a rack of GPUs into a working AI service raises several separate engineering problems, and each one maps to a different NVIDIA product:

| Production problem | What breaks without a solution | NVIDIA answer |
|---|---|---|
| The silicon must be programmable | No way to run kernels on the GPU | **CUDA** toolkit and driver |
| Deep learning primitives must be fast | Each framework hand-writes convolutions and attention | **cuDNN**, **cuBLAS**, CUTLASS |
| Multi-GPU and multi-node training must communicate | All-reduce becomes the bottleneck and scaling flattens | **NCCL**, **NVLink/NVSwitch**, **InfiniBand Quantum**, **Spectrum-X** |
| Data must reach the GPU fast enough | GPUs sit idle waiting on storage and CPU bounce buffers | **Magnum IO**, **GPUDirect RDMA**, **GPUDirect Storage** |
| Kubernetes must see and manage GPUs | Drivers drift, device plugin is missing, no metrics | **GPU Operator**, **Network Operator**, **DCGM** |
| Clusters must be provisioned and operated | Bare-metal fleets snowflake, no job scheduling | **Base Command Manager**, **Run:ai**, **Slurm** integration |
| Edge fleets must be managed remotely | Thousands of sites with no central control | **Fleet Command** |
| Trained models must serve at low latency and high throughput | FP32 eager-mode inference wastes most of the GPU | **TensorRT**, **TensorRT-LLM**, **Triton / Dynamo-Triton**, **Dynamo** |
| Teams need production-grade generative AI without building the serving stack | Months of integration work per model | **NIM** microservices |
| Models must be built, customized, and guarded | Ad hoc training scripts, no data curation, no guardrails | **NeMo** (Curator, Customizer, Guardrails, Retriever) |
| ETL and classic ML are CPU-bound | Pandas and scikit-learn take hours | **RAPIDS** (cuDF, cuML, cuGraph) |
| The enterprise needs support, security patching, and certification | Unsupported open-source with CVE exposure | **NVIDIA AI Enterprise** |
| Software must be distributed in a trusted, curated form | Each team builds its own CUDA images | **NGC** catalog (`nvcr.io`) |
| Domain problems need ready-made pipelines | Every hospital, retailer, or SOC starts from zero | **Clara, Riva, Morpheus, Metropolis, Isaac, Merlin, Omniverse, Holoscan** |

The exam tests recognition: given a scenario, pick the product. The production skill underneath is knowing which layer is failing when something goes wrong.

---

## 2. The NVIDIA stack: a layered mental model

```
┌───────────────────────────────────────────────────────────────────────┐
│ APPLICATION / DOMAIN SDKs                                             │
│ Clara (health) · Riva (speech) · Morpheus (cyber) · Metropolis (video)│
│ Isaac (robotics) · Merlin (recsys) · Omniverse (3D/digital twin)      │
│ Holoscan (sensor/edge streaming) · Maxine (video/audio effects)       │
├───────────────────────────────────────────────────────────────────────┤
│ AI FRAMEWORKS & MICROSERVICES                                         │
│ NeMo (build/customize/guard LLMs) · NIM (prebuilt inference services) │
│ Triton / Dynamo-Triton (serving) · Dynamo (distributed LLM serving)   │
│ TensorRT · TensorRT-LLM (inference optimization) · RAPIDS (data sci)  │
├───────────────────────────────────────────────────────────────────────┤
│ NVIDIA AI ENTERPRISE (licensed, supported software suite)             │
│ distributed through NGC (containers, models, Helm charts)             │
├───────────────────────────────────────────────────────────────────────┤
│ ACCELERATION LIBRARIES (CUDA-X)                                       │
│ CUDA · cuDNN · cuBLAS · NCCL · cuFFT · Magnum IO · DALI               │
├───────────────────────────────────────────────────────────────────────┤
│ INFRASTRUCTURE MANAGEMENT & ORCHESTRATION                             │
│ GPU Operator · Network Operator · DCGM · Base Command Manager          │
│ Run:ai · Fleet Command · Kubernetes / Slurm                           │
├───────────────────────────────────────────────────────────────────────┤
│ NETWORKING & DATA MOVEMENT                                            │
│ NVLink/NVSwitch (scale-up) · Quantum InfiniBand · Spectrum-X Ethernet │
│ ConnectX SuperNIC · BlueField DPU (DOCA) · GPUDirect RDMA/Storage     │
├───────────────────────────────────────────────────────────────────────┤
│ COMPUTE PLATFORMS                                                     │
│ DGX (turnkey systems) · DGX BasePOD / SuperPOD (reference clusters)   │
│ HGX (OEM baseboard) · MGX (modular reference) · DGX Cloud (as-a-svc)  │
│ Jetson / IGX (edge) · data center GPUs (H100, H200, B200, L40S, L4…)  │
└───────────────────────────────────────────────────────────────────────┘
```

**Rule of thumb for scenario questions:** find the verb in the question first.

- *Train / customize / curate / guard* → NeMo
- *Optimize a model for inference* → TensorRT or TensorRT-LLM
- *Serve many models from many frameworks* → Triton
- *Deploy an LLM quickly with an OpenAI-compatible API* → NIM
- *Manage GPUs in Kubernetes* → GPU Operator
- *Monitor GPU health* → DCGM
- *Provision a bare-metal cluster* → Base Command Manager
- *Schedule and share GPUs fairly across teams* → Run:ai
- *Manage edge sites* → Fleet Command
- *Offload networking, storage, or security from the CPU* → BlueField DPU
- *Accelerate dataframes and classic ML* → RAPIDS

---

## 3. Compute platforms

### 3.1 DGX, HGX, MGX, DGX Cloud

| Product | What it is | Who integrates it | Use when | Trade-off |
|---|---|---|---|---|
| **DGX** (e.g., DGX H100/H200/B200) | Turnkey NVIDIA system: 8 GPUs, NVSwitch, ConnectX NICs, DGX OS, support | NVIDIA | You want a validated, supported, known-good node with predictable performance | Higher cost, less hardware flexibility |
| **DGX BasePOD** | Reference architecture: DGX nodes, networking, storage partners, Base Command Manager | NVIDIA and partners | Enterprise cluster from tens of nodes upward | Requires certified storage and network design |
| **DGX SuperPOD** | Scalable-unit reference architecture for very large training clusters (InfiniBand or Spectrum-X fabric) | NVIDIA | Foundation-model training at hundreds or thousands of GPUs | Highest capex, strict facility needs (power, cooling, often liquid) |
| **HGX** | GPU baseboard (GPUs and NVSwitch) sold to OEMs (Dell, HPE, Supermicro, Lenovo…) | OEM | You want an OEM server with the same GPU complex as DGX | Support split between OEM and NVIDIA; validation is on you |
| **MGX** | Modular server reference design (CPU, GPU, DPU combinations, including Grace) | OEM | Heterogeneous or custom form factors, many SKUs from one design | More design variety to validate |
| **DGX Cloud** | DGX infrastructure as a managed service on partner clouds, with NVIDIA software and expertise | NVIDIA and CSP | Burst or start without capex; consistent NVIDIA environment | Opex, data gravity, dependence on provider capacity |
| **Jetson / IGX** | Edge and embedded modules; IGX is industrial and medical grade with functional safety | NVIDIA and OEMs | Robots, cameras, medical devices, factory edge | Limited power and memory compared with data center GPUs |

### 3.2 GPU selection by workload

| GPU class | Typical use case | Why |
|---|---|---|
| H100 / H200 / B200 (SXM, NVLink) | Large-scale training, large LLM inference | HBM bandwidth, NVLink scale-up, Transformer Engine (FP8; FP4 on Blackwell) |
| L40S | Mixed inference, graphics, Omniverse, fine-tuning small models | Strong FP8 inference plus RT cores for rendering |
| L4 | High-density, power-efficient inference, video AI | Low TDP, video encode/decode engines |
| Grace Hopper / Grace Blackwell | Memory-bound workloads where the CPU-GPU link limits performance | NVLink-C2C coherent memory between CPU and GPU |

---

## 4. Networking and data movement

### 4.1 Scale-up versus scale-out

| Technology | Scope | Purpose | Diagnostic signal |
|---|---|---|---|
| **NVLink / NVSwitch** | Inside a node (or NVL72 rack domain) | GPU-to-GPU bandwidth far beyond PCIe for tensor parallelism and all-reduce | `nvidia-smi topo -m` shows `NV#` between GPUs |
| **Quantum InfiniBand** | Between nodes | Lossless, low-latency RDMA fabric; SHARP in-network reduction for collectives | `ibstat` shows `State: Active`, rate 400/800 Gb/s |
| **Spectrum-X Ethernet** | Between nodes | Ethernet tuned for AI: adaptive routing and congestion control (Spectrum-4 switches plus BlueField-3 SuperNICs) | RoCE counters, switch telemetry |
| **ConnectX SuperNIC** | Node NIC | High-bandwidth RDMA endpoint for GPU east-west traffic | `ibdev2netdev`, `mlxlink` |
| **BlueField DPU** | Node NIC with Arm cores | Offloads and isolates networking, storage, and security from the host CPU; programmed with DOCA | DPU runs its own OS; host sees offloaded functions |

**Why this matters in production:** in distributed training each step ends with a gradient all-reduce. If inter-GPU bandwidth is low, adding GPUs adds communication time and scaling efficiency collapses. NCCL automatically picks the fastest path (NVLink, then PCIe, then the network over GPUDirect RDMA). It can only use paths that are physically present and correctly configured.

### 4.2 Magnum IO and GPUDirect

**Magnum IO** is the umbrella name for NVIDIA's I/O acceleration stack (NCCL, GPUDirect RDMA, GPUDirect Storage, NVSHMEM, UCX integration).

- **GPUDirect RDMA**: the NIC reads and writes GPU memory directly over PCIe, bypassing host memory copies. This is required for efficient multi-node NCCL.
- **GPUDirect Storage (GDS)**: DMA from NVMe or NVMe-oF/parallel file systems straight into GPU memory, bypassing the CPU bounce buffer. It reduces CPU load and increases I/O throughput for data loading and checkpointing.

From NVIDIA's storage guidance for AI training and inference, the main practices are:

- Size storage bandwidth for the read pattern of training (many epochs over the dataset) and for checkpoint bursts (large sequential writes from every rank at once).
- Use tiering: local NVMe cache, then a parallel or shared file system, then object storage for the data lake.
- Inference usually stresses model-load latency at scale-out, with many replicas pulling multi-GB weights at the same time. Caching weights near the nodes matters.

```
$ nvidia-smi topo -m
        GPU0  GPU1  GPU2  GPU3  GPU4  GPU5  GPU6  GPU7  NIC0  NIC1  CPU Affinity  NUMA Affinity
GPU0     X    NV18  NV18  NV18  NV18  NV18  NV18  NV18  PXB   SYS   0-55          0
GPU1    NV18   X    NV18  NV18  NV18  NV18  NV18  NV18  PXB   SYS   0-55          0
GPU2    NV18  NV18   X    NV18  NV18  NV18  NV18  NV18  SYS   SYS   0-55          0
GPU3    NV18  NV18  NV18   X    NV18  NV18  NV18  NV18  SYS   SYS   0-55          0
GPU4    NV18  NV18  NV18  NV18   X    NV18  NV18  NV18  SYS   PXB   56-111        1
GPU5    NV18  NV18  NV18  NV18  NV18   X    NV18  NV18  SYS   PXB   56-111        1
GPU6    NV18  NV18  NV18  NV18  NV18  NV18   X    NV18  SYS   SYS   56-111        1
GPU7    NV18  NV18  NV18  NV18  NV18  NV18  NV18   X    SYS   SYS   56-111        1

Legend:
  X    = Self
  SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes
  PXB  = Connection traversing multiple PCIe bridges (without traversing the PCIe Host Bridge)
  NV#  = Connection traversing a bonded set of # NVLinks
```

Read it this way: `NV18` means 18 bonded NVLinks between every pair of GPUs, a full NVSwitch mesh. If you see `SYS` or `PHB` between GPUs on an HGX/DGX node, the NVSwitch fabric is not working. The usual fix is to start the **Fabric Manager** service (`nvidia-fabricmanager`). Without it, CUDA apps on NVSwitch systems fail to initialize.

---

## 5. Acceleration libraries (CUDA-X)

| Library | Purpose | Who uses it directly |
|---|---|---|
| **CUDA** (driver and toolkit) | Programming model, compiler (`nvcc`), runtime | Framework and kernel developers; everyone indirectly |
| **cuDNN** | Optimized primitives for deep neural networks (conv, attention, normalization) | PyTorch, TensorFlow, and JAX call it under the hood |
| **cuBLAS / cuBLASLt** | Dense linear algebra (GEMM) | Frameworks, TensorRT |
| **NCCL** | Collective communications (all-reduce, all-gather, broadcast) across GPUs and nodes | PyTorch DDP/FSDP, Megatron, NeMo |
| **DALI** | GPU-accelerated data loading and augmentation | Vision training pipelines with CPU-bound preprocessing |
| **RAPIDS** | GPU dataframes and ML (cuDF, cuML, cuGraph, cuVS for vector search) | Data engineers and data scientists |

**Driver/CUDA compatibility:** the driver is backward compatible with older CUDA runtimes. A container built for CUDA 12.x needs a host driver that supports 12.x. This is why NGC containers state a minimum driver version, and why the GPU Operator manages the driver as a versioned, containerized component.

### RAPIDS in one example

RAPIDS changes the ETL step, not the model. The `cudf.pandas` accelerator mode runs unchanged pandas code on the GPU and falls back to the CPU for unsupported operations:

```
$ python -m cudf.pandas etl_job.py
```

**Use case:** feature engineering on hundreds of millions of rows, where the GPU training job would otherwise wait on a CPU pandas pipeline. **Not a fit:** small data that fits in the CPU cache, or heavy row-wise Python UDFs.

---

## 6. Inference stack: TensorRT, TensorRT-LLM, Triton, Dynamo, NIM

This is the most heavily tested area of the topic because the products overlap.

### 6.1 TensorRT: an optimizing compiler, not a server

TensorRT takes a trained network (usually ONNX) and produces a serialized **engine** (`.plan`) optimized for one specific GPU architecture and one TensorRT version. Internally it:

1. **Parses** the graph and removes dead or no-op layers.
2. **Fuses layers and tensors**, for example Conv, BiasAdd, and ReLU into one kernel. This cuts kernel launches and memory round-trips.
3. **Lowers precision**: FP32 to FP16, BF16, FP8, or INT8 (with calibration or quantization-aware training), and FP4 on Blackwell. This raises Tensor Core throughput and reduces memory traffic.
4. **Auto-tunes kernels**: it times candidate kernels (tactics) on the actual GPU and keeps the fastest.
5. **Plans memory**: it reuses activation buffers across layers.

The consequence for operations is that **an engine is not portable**. An engine built on an L4 will not deserialize on an H100, and an engine from TensorRT 10.x will not load in a different major or minor version. Build engines in CI on the target GPU type, or let NIM select a prebuilt profile.

```
$ trtexec --onnx=resnet50.onnx --saveEngine=resnet50_fp16.plan --fp16 \
    --minShapes=input:1x3x224x224 --optShapes=input:32x3x224x224 --maxShapes=input:64x3x224x224
&&&& RUNNING TensorRT.trtexec [TensorRT v100x00] # trtexec --onnx=resnet50.onnx ...
[I] [TRT] ----------------------------------------------------------------
[I] [TRT] Input filename:   resnet50.onnx
[I] [TRT] ONNX IR version:  0.0.8
[I] [TRT] ----------------------------------------------------------------
[I] [TRT] Detected 1 inputs and 1 output network tensors.
[I] Engine built in 74.3 sec.
[I] === Performance summary ===
[I] Throughput: 4126.7 qps
[I] Latency: min = 7.41 ms, max = 8.12 ms, mean = 7.66 ms, median = 7.64 ms, percentile(99%) = 7.98 ms
[I] GPU Compute Time: min = 7.32 ms, max = 8.01 ms, mean = 7.55 ms, median = 7.53 ms, percentile(99%) = 7.86 ms
&&&& PASSED TensorRT.trtexec [TensorRT v100x00] # trtexec --onnx=resnet50.onnx ...
```

(Representative output. Absolute numbers depend on GPU, batch size, and version.)

### 6.2 TensorRT-LLM: LLM-specific optimizations

Generic graph compilation is not enough for LLMs, because autoregressive decoding is memory-bandwidth bound and requests have different lengths. TensorRT-LLM adds:

- **In-flight (continuous) batching**: new requests join the batch at each token step instead of waiting for the whole batch to finish.
- **Paged KV cache**: KV cache is allocated in blocks, as in virtual memory paging, which reduces fragmentation and raises concurrency.
- **Quantization**: FP8, INT8/INT4 weight-only, AWQ, and FP4 on Blackwell.
- **Tensor and pipeline parallelism**: shards a model across GPUs (via NVLink) and nodes.
- **Speculative decoding** and optimized attention kernels.

### 6.3 Triton Inference Server (Dynamo-Triton)

Triton is an **open-source, multi-framework inference server**. In 2025 NVIDIA brought it under the Dynamo platform as *NVIDIA Dynamo-Triton*; the server, APIs, and model repository concept are unchanged. Use it when you serve **many models from many frameworks** behind one standard API (KServe v2 protocol over HTTP/gRPC).

| Capability | Production effect |
|---|---|
| Backends: TensorRT, TensorRT-LLM, ONNX Runtime, PyTorch (LibTorch), TensorFlow, OpenVINO, Python, vLLM, FIL (tree models) | One serving platform regardless of training framework |
| **Dynamic batching** | Combines individual requests server-side into batches, trading a bounded queue delay for throughput |
| **Concurrent model execution** | Multiple instances of one or more models on the same GPU (`instance_group`) |
| **Ensembles / BLS** | Pre-processing, model, and post-processing pipeline inside the server, with no extra network hops |
| **Model repository** | Local path, PVC, S3, GCS, or Azure; supports hot load and unload (`--model-control-mode`) |
| **Metrics on :8002** | Prometheus metrics for queue time, compute time, request counts, and GPU utilization |

Model repository layout:

```
model_repository/
└── resnet50/
    ├── config.pbtxt
    └── 1/
        └── model.plan
```

`config.pbtxt` (protobuf text format, not YAML):

```
name: "resnet50"
platform: "tensorrt_plan"
max_batch_size: 64
input [
  {
    name: "input"
    data_type: TYPE_FP32
    dims: [ 3, 224, 224 ]
  }
]
output [
  {
    name: "output"
    data_type: TYPE_FP32
    dims: [ 1000 ]
  }
]
instance_group [
  {
    count: 2
    kind: KIND_GPU
  }
]
dynamic_batching {
  preferred_batch_size: [ 16, 32 ]
  max_queue_delay_microseconds: 2000
}
```

### 6.4 NVIDIA Dynamo

**Dynamo** is NVIDIA's open-source framework for **distributed, datacenter-scale LLM inference**, announced in 2025. It targets problems that a single server process cannot solve:

- **Disaggregated serving**: runs prefill (compute-bound) and decode (memory-bandwidth-bound) on separate GPU pools that are sized independently.
- **KV-cache-aware routing**: sends a request to the worker that already holds a matching prefix in its KV cache.
- **KV cache offloading** to cheaper memory and storage tiers.
- **Pluggable engines**: TensorRT-LLM, vLLM, SGLang.

Use it for large multi-node LLM fleets where GPU efficiency at scale is the main cost driver.

### 6.5 NIM: NVIDIA Inference Microservices

**NIM** packages a model, an optimized inference engine (TensorRT-LLM, or vLLM/SGLang depending on the NIM), runtime dependencies, and an **industry-standard API** (OpenAI-compatible for LLMs) into one container from `nvcr.io/nim/...`. At startup it detects the GPU and selects the matching optimized **profile**: precision, tensor-parallel degree, and engine.

- **Purpose:** time-to-production. You go from zero to a supported, optimized endpoint in minutes instead of building a TensorRT-LLM engine and a Triton configuration yourself.
- **Licensing:** production use falls under **NVIDIA AI Enterprise**; NVIDIA Developer Program members can use NIM for development and testing.
- **Families:** LLM NIMs, embedding and reranking NIMs (NeMo Retriever, used for RAG), vision, speech (Riva), biology (BioNeMo), and others.

### 6.6 Inference product comparison

| | TensorRT | TensorRT-LLM | Triton (Dynamo-Triton) | Dynamo | NIM |
|---|---|---|---|---|---|
| **Category** | Compiler and runtime SDK | LLM optimization library and runtime | Inference server | Distributed LLM serving framework | Packaged microservice |
| **Input** | ONNX or framework graph | LLM checkpoint | Model repository (any backend) | Engines (TRT-LLM, vLLM, SGLang) | Nothing; model is included |
| **Output** | `.plan` engine | Optimized LLM engine and runtime | HTTP/gRPC endpoints, metrics | Fleet-level serving, routing, disaggregation | OpenAI-compatible endpoint |
| **Best for** | Lowest latency for one model on known hardware | Maximum LLM tokens/s per GPU | Multi-model, multi-framework platforms | Very large multi-node LLM deployments | Fast, supported GenAI deployment |
| **Effort** | High (build per GPU and version) | High | Medium | High | Low |
| **Flexibility** | Total | High | High | High | Limited to the catalog (or "LLM-agnostic" NIM for supported architectures) |
| **Support** | Open SDK; supported under AI Enterprise | Open source; supported under AI Enterprise | Open source; supported under AI Enterprise | Open source | AI Enterprise |

They compose rather than compete. A NIM contains TensorRT-LLM engines. Triton can serve TensorRT-LLM engines. Dynamo orchestrates engines at fleet scale.

---

## 7. NeMo: building and customizing generative AI

NVIDIA describes LLMs as having use cases across content generation, summarization, translation, code generation, search and RAG, conversational agents, and domain-specific assistants in healthcare, finance, and retail. **NeMo** is the framework and microservice set used to **build, customize, evaluate, and guard** those models:

| Component | Purpose |
|---|---|
| **NeMo Framework** | Training and fine-tuning at scale (Megatron-based parallelism: tensor, pipeline, sequence, expert); pretraining, SFT, PEFT/LoRA, RLHF/DPO |
| **NeMo Curator** | GPU-accelerated data curation: dedup, quality filtering, PII removal |
| **NeMo Customizer** | Microservice for fine-tuning (e.g., LoRA) through an API |
| **NeMo Evaluator** | Benchmarks and LLM-as-judge evaluation |
| **NeMo Guardrails** | Programmable rails for topic control, jailbreak and safety checks, fact-checking against retrieved context |
| **NeMo Retriever** | Embedding, reranking, and extraction NIMs for RAG pipelines |

The typical lifecycle is: curate (Curator), train or customize (Framework or Customizer), evaluate (Evaluator), optimize (TensorRT-LLM), deploy (NIM), protect (Guardrails), ground (Retriever).

---

## 8. Platform software: AI Enterprise and NGC

### 8.1 NVIDIA AI Enterprise

This is an **end-to-end, licensed software platform** that includes NIM, NeMo, Triton, TensorRT, RAPIDS, the GPU and Network Operators, and more. You pay for:

- **Enterprise support** with SLAs.
- **Security**: CVE scanning, patching, and signed containers.
- **API stability through branches**: Feature Branches (latest), Production Branches (about 9 months of stability), and Long-Term Support Branches (multi-year, for regulated environments).
- **Certification** on NVIDIA-Certified Systems, major hypervisors (vGPU), Kubernetes distributions, and clouds.

Exam signal: *"enterprise needs supported, secure, production-ready AI software"* → **NVIDIA AI Enterprise**.

### 8.2 NGC

**NGC** is NVIDIA's hub for GPU-optimized software: containers (`nvcr.io`), pretrained models, Helm charts, and resources. Containers are tested against specific CUDA/driver combinations and published monthly (`YY.MM` tags, e.g., `tritonserver:24.12-py3`).

Authentication against `nvcr.io` uses the literal username `$oauthtoken` and an NGC API key as the password:

```
$ export NGC_API_KEY=nvapi-xxxxxxxxxxxxxxxxxxxx
$ echo "$NGC_API_KEY" | docker login nvcr.io --username '$oauthtoken' --password-stdin
Login Succeeded
```

---

## 9. Infrastructure management and orchestration

### 9.1 NVIDIA GPU Operator

**Problem:** every Kubernetes GPU node needs a matching driver, the NVIDIA Container Toolkit, the device plugin, feature labels, monitoring, and optionally MIG configuration. Managing that by hand across a fleet causes drift and upgrade outages.

**Solution:** the GPU Operator (Operator Framework, `ClusterPolicy` CRD) deploys and lifecycle-manages all of those as containers:

| Component | Role |
|---|---|
| `nvidia-driver-daemonset` | Containerized kernel driver (can be disabled when the host driver is pre-installed) |
| `nvidia-container-toolkit-daemonset` | Configures containerd or CRI-O to inject GPUs into containers |
| `nvidia-device-plugin-daemonset` | Advertises `nvidia.com/gpu` (or MIG resources) to the kubelet |
| `gpu-feature-discovery` | Labels nodes (`nvidia.com/gpu.product`, `gpu.memory`, `cuda.driver.major`…) |
| `nvidia-dcgm-exporter` | Prometheus metrics from DCGM |
| `nvidia-mig-manager` | Applies MIG geometry from the `nvidia.com/mig.config` node label |
| `nvidia-operator-validator` | Validates driver, toolkit, CUDA, and plugin end to end |
| Node Feature Discovery | Detects NVIDIA PCI devices so the operator targets the right nodes |

The **Network Operator** does the same for the networking side: MOFED/DOCA drivers, RDMA shared device plugin, SR-IOV, and Multus. Combined with the GPU Operator it enables GPUDirect RDMA inside Kubernetes.

**Helm values for a production install** (`gpu-operator-values.yaml`):

```yaml
operator:
  defaultRuntime: containerd
driver:
  enabled: true
  rdma:
    enabled: false
  upgradePolicy:
    autoUpgrade: true
    maxParallelUpgrades: 1
    maxUnavailable: "25%"
    drain:
      enable: true
      force: false
      timeoutSeconds: 300
toolkit:
  enabled: true
devicePlugin:
  enabled: true
  config:
    name: time-slicing-config
    default: any
dcgmExporter:
  enabled: true
  serviceMonitor:
    enabled: true
    interval: 15s
gfd:
  enabled: true
mig:
  strategy: single
migManager:
  enabled: true
nfd:
  enabled: true
validator:
  plugin:
    env:
      - name: WITH_WORKLOAD
        value: "true"
```

```
$ helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
"nvidia" has been added to your repositories
...Successfully got an update from the "nvidia" chart repository
Update Complete. ⎈Happy Helming!⎈

$ helm install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator --create-namespace \
    --version "${GPU_OPERATOR_VERSION}" \
    -f gpu-operator-values.yaml --wait
NAME: gpu-operator
NAMESPACE: gpu-operator
STATUS: deployed
REVISION: 1
```

Pin `GPU_OPERATOR_VERSION` to a release listed in the GPU Operator release notes and its platform support matrix (kernel, OS, Kubernetes version, GPU).

```
$ kubectl get pods -n gpu-operator
NAME                                                          READY   STATUS      RESTARTS   AGE
gpu-feature-discovery-7xkqp                                   1/1     Running     0          6m
gpu-operator-6d8f9c7b5-hl2rm                                  1/1     Running     0          7m
gpu-operator-node-feature-discovery-gc-5f7d8c6b9-qv4tn        1/1     Running     0          7m
gpu-operator-node-feature-discovery-master-7c9f6d5b8-k2zrx    1/1     Running     0          7m
gpu-operator-node-feature-discovery-worker-9mbvd              1/1     Running     0          7m
nvidia-container-toolkit-daemonset-jw8tt                      1/1     Running     0          6m
nvidia-cuda-validator-p6v9c                                   0/1     Completed   0          4m
nvidia-dcgm-exporter-8lq2n                                    1/1     Running     0          6m
nvidia-device-plugin-daemonset-r5hcz                          1/1     Running     0          6m
nvidia-driver-daemonset-tz7fw                                 1/1     Running     0          7m
nvidia-mig-manager-cx4wd                                      1/1     Running     0          5m
nvidia-operator-validator-wqm4s                               1/1     Running     0          6m
```

The startup order is driver, then toolkit, then device plugin. Each depends on the previous one, and the validator gates the chain. When something is stuck, look at the **first** non-Running component in that order.

### 9.2 GPU sharing: MIG versus time-slicing versus vGPU versus MPS

| Mechanism | Isolation | Granularity | Use case | Trade-off |
|---|---|---|---|---|
| **MIG** (Multi-Instance GPU; A100, H100, H200, B200…) | **Hardware**: dedicated SMs, L2 slices, memory controllers, fault isolation | Fixed profiles (e.g., up to 7 instances) | Multi-tenant inference with QoS guarantees | Fixed geometry; reconfiguration requires the GPU to be idle |
| **Time-slicing** (device plugin) | **None**: shared memory, no fault isolation | Any number of replicas | Dev/test, notebooks, bursty low-utilization workloads | Noisy neighbors; one OOM can affect all; no memory limits |
| **vGPU** (AI Enterprise on hypervisors) | Hypervisor-level; time-sliced or MIG-backed | Profiles per VM | VMware/VDI or VM-based enterprises | Needs vGPU licensing and a supported hypervisor |
| **MPS** (Multi-Process Service) | Partial (per-client compute limits), shared fault domain | Per-process | Many small CUDA processes from cooperating tenants | A crash can affect all clients |

MIG profiles on an H100 80GB:

| Profile | Instances per GPU | Memory each |
|---|---|---|
| `1g.10gb` | 7 | 10 GB |
| `1g.20gb` | 4 | 20 GB |
| `2g.20gb` | 3 | 20 GB |
| `3g.40gb` | 2 | 40 GB |
| `4g.40gb` | 1 | 40 GB |
| `7g.80gb` | 1 | 80 GB |

**Time-slicing configuration** (referenced from the Helm values above):

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

**Applying MIG** with the MIG Manager is declarative, through a node label:

```
$ kubectl label node gpu-node-01 nvidia.com/mig.config=all-1g.10gb --overwrite
node/gpu-node-01 labeled

$ kubectl get node gpu-node-01 -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}'
success

$ kubectl describe node gpu-node-01 | grep -E 'nvidia.com/(gpu|mig)'
  nvidia.com/gpu:     56
  nvidia.com/gpu:     56
```

With `mig.strategy: single`, every MIG instance is advertised as `nvidia.com/gpu` (8 GPUs × 7 = 56). With `mixed`, they appear as `nvidia.com/mig-1g.10gb` and similar resource names.

### 9.3 DCGM: Data Center GPU Manager

DCGM is the **health, telemetry, policy, and diagnostics** layer for data center GPUs. It runs as `nv-hostengine` and is exposed through `dcgmi`, APIs, and `dcgm-exporter` for Prometheus.

```
$ dcgmi discovery -l
8 GPUs found.
+--------+----------------------------------------------------------------------+
| GPU ID | Device Information                                                   |
+--------+----------------------------------------------------------------------+
| 0      | Name: NVIDIA H100 80GB HBM3                                          |
|        | PCI Bus ID: 00000000:18:00.0                                         |
|        | Device UUID: GPU-3b1f6f2a-1c2d-4e5f-8a9b-0c1d2e3f4a5b                |
+--------+----------------------------------------------------------------------+
...

$ dcgmi diag -r 2
Successfully ran diagnostic for group.
+---------------------------+------------------------------------------------+
| Diagnostic                | Result                                         |
+===========================+================================================+
|-----  Metadata  ----------+------------------------------------------------|
| DCGM Version              | 4.x.x                                          |
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
+---------------------------+------------------------------------------------+
```

Diagnostic levels: `-r 1` takes seconds (deployment sanity), `-r 2` takes about 2 minutes (adds PCIe and memory), `-r 3` takes tens of minutes (adds stress, targeted power, and burn-in). Run `-r 3` (or level 4 on newer DCGM) at node acceptance and after hardware replacement, never on a node that is serving production traffic.

### 9.4 Base Command Manager, Run:ai, Fleet Command

| Product | Layer | Purpose | Use when |
|---|---|---|---|
| **Base Command Manager** (formerly Bright Cluster Manager) | Bare-metal cluster management | Provisioning (PXE images), node categories, monitoring, health checks, Slurm or Kubernetes deployment, workload accounting | You operate on-prem DGX/HGX clusters (BasePOD/SuperPOD) |
| **Run:ai** | Kubernetes AI workload orchestration | GPU-aware scheduler: quotas, over-quota borrowing, fair share, preemption, fractional GPUs, gang scheduling, utilization dashboards | Many teams compete for a shared GPU pool and utilization is low |
| **Fleet Command** | Edge management (SaaS control plane) | Zero-touch provisioning, remote deployment and updates of AI apps, secure remote access across many edge sites | Retail stores, factories, hospitals: many small sites without IT staff |
| **Slurm** (not NVIDIA, commonly integrated) | HPC batch scheduler | Gang-scheduled multi-node training jobs | Classic HPC-style training clusters |

How they combine: Base Command Manager builds the cluster, Kubernetes runs on it with the GPU and Network Operators, Run:ai schedules on top, and DCGM watches everything. Fleet Command is the equivalent stack for edge sites.

---

## 10. Domain SDKs and application frameworks

| SDK | Domain | Typical use case | Exam keyword |
|---|---|---|---|
| **Clara** (incl. MONAI, Parabricks, BioNeMo) | Healthcare and life sciences | Medical imaging AI, genomics acceleration, drug discovery | "radiology", "genomics", "protein" |
| **Riva** | Speech AI | ASR, TTS, neural machine translation, real-time and customizable | "speech recognition", "voice assistant", "transcription" |
| **Morpheus** | Cybersecurity | GPU-accelerated pipelines for anomaly detection, phishing, sensitive-data detection, high-volume telemetry | "detect threats in real time", "SOC" |
| **Metropolis** (incl. DeepStream) | Vision AI / smart spaces | Multi-camera video analytics: traffic, retail, factory inspection | "video analytics", "smart city", "cameras" |
| **Isaac** (Sim, ROS, Lab) | Robotics | Simulation, perception, and manipulation for AMRs and arms | "robot", "AMR", "sim-to-real" |
| **Merlin** | Recommender systems | Large-embedding recommenders, feature engineering, and serving | "recommendations", "personalization" |
| **Omniverse** | 3D simulation and digital twins (OpenUSD) | Factory and warehouse digital twins, synthetic data, collaborative 3D | "digital twin", "USD", "synthetic data" |
| **Holoscan** | Sensor streaming / edge AI | Low-latency medical devices and sensor pipelines (on IGX) | "medical device", "real-time sensor" |
| **Maxine** | Video and audio effects | Noise removal, eye contact, super-resolution for conferencing | "video conferencing quality" |
| **cuOpt** | Optimization | Vehicle routing and logistics | "route optimization" |

---

## 11. End-to-end production manifests

### 11.1 Smoke test: does the cluster actually give GPUs to pods?

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cuda-vectoradd
  namespace: default
spec:
  restartPolicy: OnFailure
  containers:
    - name: cuda-vectoradd
      image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1-ubuntu20.04
      resources:
        limits:
          nvidia.com/gpu: 1
```

```
$ kubectl apply -f cuda-vectoradd.yaml
pod/cuda-vectoradd created

$ kubectl logs cuda-vectoradd
[Vector addition of 50000 elements]
Copy input data from the host memory to the CUDA device
CUDA kernel launch with 196 blocks of 256 threads
Copy output data from the CUDA device to the host memory
Test PASSED
Done
```

### 11.2 NIM LLM deployment on Kubernetes

Create the pull secret and the API key secret first:

```
$ kubectl create namespace nim
namespace/nim created

$ kubectl -n nim create secret docker-registry ngc-secret \
    --docker-server=nvcr.io \
    --docker-username='$oauthtoken' \
    --docker-password="$NGC_API_KEY"
secret/ngc-secret created

$ kubectl -n nim create secret generic ngc-api \
    --from-literal=NGC_API_KEY="$NGC_API_KEY"
secret/ngc-api created
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nim-cache
  namespace: nim
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: fast-nvme
  resources:
    requests:
      storage: 100Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llama31-8b-nim
  namespace: nim
  labels:
    app.kubernetes.io/name: llama31-8b-nim
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: llama31-8b-nim
  template:
    metadata:
      labels:
        app.kubernetes.io/name: llama31-8b-nim
    spec:
      imagePullSecrets:
        - name: ngc-secret
      nodeSelector:
        nvidia.com/gpu.product: NVIDIA-H100-80GB-HBM3
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
        - name: nim
          # Pin an explicit tag from the NGC catalog in production; latest is shown for brevity.
          image: nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
          imagePullPolicy: IfNotPresent
          env:
            - name: NGC_API_KEY
              valueFrom:
                secretKeyRef:
                  name: ngc-api
                  key: NGC_API_KEY
            - name: NIM_CACHE_PATH
              value: /opt/nim/.cache
          ports:
            - name: http-openai
              containerPort: 8000
              protocol: TCP
          resources:
            requests:
              cpu: "8"
              memory: 32Gi
              nvidia.com/gpu: 1
            limits:
              memory: 64Gi
              nvidia.com/gpu: 1
          startupProbe:
            httpGet:
              path: /v1/health/ready
              port: http-openai
            periodSeconds: 10
            failureThreshold: 180
          readinessProbe:
            httpGet:
              path: /v1/health/ready
              port: http-openai
            periodSeconds: 10
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /v1/health/live
              port: http-openai
            periodSeconds: 15
            failureThreshold: 3
          volumeMounts:
            - name: nim-cache
              mountPath: /opt/nim/.cache
            - name: dshm
              mountPath: /dev/shm
      volumes:
        - name: nim-cache
          persistentVolumeClaim:
            claimName: nim-cache
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 16Gi
---
apiVersion: v1
kind: Service
metadata:
  name: llama31-8b-nim
  namespace: nim
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: llama31-8b-nim
  ports:
    - name: http-openai
      port: 8000
      targetPort: http-openai
      protocol: TCP
```

Design notes:

- **`startupProbe` with a 30-minute budget** (180 × 10 s): the first start downloads weights. Without it, the liveness probe kills the pod mid-download and you get a restart loop.
- **PVC cache**: later restarts skip the multi-GB download. For many replicas, use `ReadWriteMany` or the NIM Operator's cache CRDs.
- **`/dev/shm` in memory**: multi-GPU (tensor-parallel) profiles use shared memory for NCCL. The default 64 MiB container shm causes failures.
- **`Recreate` strategy**: with one GPU per node, a rolling update would need a second free GPU.
- For fleet operation, the **NIM Operator** provides `NIMCache` and `NIMService` CRDs that automate the cache and the deployment.

Verification:

```
$ kubectl -n nim get pods
NAME                              READY   STATUS    RESTARTS   AGE
llama31-8b-nim-7b9d6c5f4d-xk2vq   1/1     Running   0          9m

$ kubectl -n nim logs deploy/llama31-8b-nim | grep -iE 'profile|ready|Uvicorn'
INFO ... Selected profile: tensorrt_llm-h100-fp8-tp1-throughput
INFO ... Model llama-3.1-8b-instruct loaded
INFO ... Uvicorn running on http://0.0.0.0:8000 (Press CTRL+C to quit)

$ kubectl -n nim port-forward svc/llama31-8b-nim 8000:8000 &
Forwarding from 127.0.0.1:8000 -> 8000

$ curl -s localhost:8000/v1/models
{"object":"list","data":[{"id":"meta/llama-3.1-8b-instruct","object":"model","created":1762934400,"owned_by":"system","root":"meta/llama-3.1-8b-instruct","parent":null,"max_model_len":131072}]}

$ curl -s localhost:8000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"What does MIG do in one sentence?"}],"max_tokens":64}'
{"id":"chat-5f1c...","object":"chat.completion","created":1762934460,"model":"meta/llama-3.1-8b-instruct","choices":[{"index":0,"message":{"role":"assistant","content":"MIG partitions a single GPU into isolated instances, each with dedicated compute, cache, and memory."},"finish_reason":"stop"}],"usage":{"prompt_tokens":19,"completion_tokens":21,"total_tokens":40}}
```

The profile name tells you the backend, GPU, precision, and parallelism. To see which profiles are compatible before deploying:

```
$ docker run --rm --gpus all -e NGC_API_KEY \
    nvcr.io/nim/meta/llama-3.1-8b-instruct:latest list-model-profiles
SYSTEM INFO
- Free GPUs:
  -  [2330:10de] (0) NVIDIA H100 80GB HBM3 (H100 80GB) [current utilization: 0%]
MODEL PROFILES
- Compatible with system and runnable:
  - <profile-id> (tensorrt_llm-h100-fp8-tp1-throughput)
  - <profile-id> (tensorrt_llm-h100-bf16-tp1-throughput)
  - <profile-id> (vllm-bf16-tp1)
- Incompatible with system:
  - <profile-id> (tensorrt_llm-h100-fp8-tp2-latency)
  ...
```

Force a profile with the `NIM_MODEL_PROFILE` environment variable when automatic selection is not what you want.

### 11.3 Triton Inference Server deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: triton
  namespace: inference
  labels:
    app.kubernetes.io/name: triton
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: triton
  template:
    metadata:
      labels:
        app.kubernetes.io/name: triton
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8002"
    spec:
      imagePullSecrets:
        - name: ngc-secret
      containers:
        - name: triton
          image: nvcr.io/nvidia/tritonserver:24.12-py3
          command:
            - tritonserver
          args:
            - --model-repository=/models
            - --model-control-mode=poll
            - --repository-poll-secs=30
            - --strict-readiness=true
            - --log-verbose=0
          ports:
            - name: http
              containerPort: 8000
            - name: grpc
              containerPort: 8001
            - name: metrics
              containerPort: 8002
          resources:
            requests:
              cpu: "4"
              memory: 16Gi
              nvidia.com/gpu: 1
            limits:
              memory: 32Gi
              nvidia.com/gpu: 1
          startupProbe:
            httpGet:
              path: /v2/health/ready
              port: http
            periodSeconds: 10
            failureThreshold: 60
          readinessProbe:
            httpGet:
              path: /v2/health/ready
              port: http
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /v2/health/live
              port: http
            periodSeconds: 15
          volumeMounts:
            - name: model-repo
              mountPath: /models
              readOnly: true
            - name: dshm
              mountPath: /dev/shm
      volumes:
        - name: model-repo
          persistentVolumeClaim:
            claimName: triton-model-repo
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 4Gi
---
apiVersion: v1
kind: Service
metadata:
  name: triton
  namespace: inference
spec:
  selector:
    app.kubernetes.io/name: triton
  ports:
    - name: http
      port: 8000
      targetPort: http
    - name: grpc
      port: 8001
      targetPort: grpc
    - name: metrics
      port: 8002
      targetPort: metrics
```

The `.plan` files in the repository must have been built for the GPU type of the nodes this Deployment lands on. Pin the nodes with a `nodeSelector` on `nvidia.com/gpu.product` when the cluster mixes GPU generations.

```
$ curl -s localhost:8000/v2/models/resnet50/ready -o /dev/null -w '%{http_code}\n'
200

$ curl -s localhost:8002/metrics | grep -E '^nv_inference_(request_success|queue_duration_us|compute_infer_duration_us)'
nv_inference_request_success{model="resnet50",version="1"} 184223
nv_inference_queue_duration_us{model="resnet50",version="1"} 92311842
nv_inference_compute_infer_duration_us{model="resnet50",version="1"} 1380225511

$ perf_analyzer -m resnet50 -u localhost:8001 -i grpc --concurrency-range 1:16:4
*** Measurement Settings ***
  Batch size: 1
  Service Kind: TRITON
  Using "time_windows" mode for stabilization
  Measurement window: 5000 msec
  Latency limit: 0 msec
  Concurrency limit: 16 concurrent requests
...
Inferences/Second vs. Client Average Batch Latency
Concurrency: 1, throughput: 612.4 infer/sec, latency 1630 usec
Concurrency: 5, throughput: 2718.9 infer/sec, latency 1836 usec
Concurrency: 9, throughput: 3870.2 infer/sec, latency 2322 usec
Concurrency: 13, throughput: 4011.6 infer/sec, latency 3238 usec
```

How to read this: when throughput flattens while latency keeps rising, you have hit GPU saturation. Divide `queue_duration_us` by the request count to get mean queue time. If it grows, raise `instance_group.count`, tune dynamic batching, or add replicas.

### 11.4 GPU alerting from DCGM metrics

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gpu-health
  namespace: gpu-operator
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: gpu.health
      rules:
        - alert: GPUXidErrorDetected
          expr: DCGM_FI_DEV_XID_ERRORS > 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} reported XID {{ $value }}"
            runbook: "Check dmesg for NVRM Xid lines and run dcgmi diag -r 2 after draining the node"
        - alert: GPUFramebufferNearlyFull
          expr: |
            DCGM_FI_DEV_FB_USED
              /
            (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE)
              > 0.95
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} framebuffer above 95 percent"
        - alert: GPUAllocatedButIdle
          expr: |
            avg_over_time(DCGM_FI_PROF_GR_ENGINE_ACTIVE[30m]) < 0.05
              and on (Hostname, gpu)
            DCGM_FI_DEV_FB_USED > 1024
          for: 30m
          labels:
            severity: info
          annotations:
            summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} holds memory but is nearly idle"
        - alert: GPUHighTemperature
          expr: DCGM_FI_DEV_GPU_TEMP > 85
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} temperature {{ $value }} C"
```

`DCGM_FI_DEV_XID_ERRORS` holds the **value of the last XID** reported, not a counter. `GPUAllocatedButIdle` is the FinOps alert: it is the signal that justifies MIG, time-slicing, or Run:ai fractional GPUs.

---

## 12. Verification and failure diagnosis

### 12.1 Bottom-up verification sequence

```
$ nvidia-smi
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 570.xx.xx              Driver Version: 570.xx.xx      CUDA Version: 12.8     |
|-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
|                                         |                        |               MIG M. |
|=========================================+========================+======================|
|   0  NVIDIA H100 80GB HBM3          On  |   00000000:18:00.0 Off |                    0 |
| N/A   34C    P0            118W /  700W |   61234MiB /  81559MiB |     87%      Default |
|                                         |                        |             Disabled |
+-----------------------------------------+------------------------+----------------------+
...
+-----------------------------------------------------------------------------------------+
| Processes:                                                                              |
|  GPU   GI   CI              PID   Type   Process name                        GPU Memory |
|        ID   ID                                                               Usage      |
|=========================================================================================|
|    0   N/A  N/A           48213      C   /opt/nim/llm/.venv/bin/python3        61210MiB |
+-----------------------------------------------------------------------------------------+
```

`CUDA Version` in the header is the **maximum CUDA version the driver supports**, not the installed toolkit. Volatile Uncorr. ECC should be `0`. `Persistence-M On` avoids driver re-initialization latency.

Full checklist, layer by layer:

| # | Layer | Command | Healthy result |
|---|---|---|---|
| 1 | Hardware and driver | `nvidia-smi` | All GPUs listed, ECC 0, expected driver |
| 2 | NVSwitch fabric | `systemctl status nvidia-fabricmanager`, `nvidia-smi topo -m` | Active; `NV#` between GPUs |
| 3 | Network fabric | `ibstat`, `ibdev2netdev` | Ports `Active`, `LinkUp`, expected rate |
| 4 | Health | `dcgmi diag -r 2` | All `Pass` |
| 5 | K8s operator | `kubectl get pods -n gpu-operator` | All Running or Completed |
| 6 | K8s resources | `kubectl describe node <n> \| grep nvidia.com/gpu` | Capacity and Allocatable > 0 |
| 7 | Workload path | `cuda-vectoradd` pod | `Test PASSED` |
| 8 | Collective comms | `all_reduce_perf` (nccl-tests) | Bus bandwidth close to fabric spec |
| 9 | Serving | `/v1/health/ready` (NIM), `/v2/health/ready` (Triton) | HTTP 200 |
| 10 | Telemetry | `curl :9400/metrics` (dcgm-exporter) | `DCGM_FI_*` series present |

```
$ ./build/all_reduce_perf -b 8 -e 8G -f 2 -g 8
#                                                              out-of-place                       in-place
#       size         count      type   redop    root     time   algbw   busbw #wrong     time   algbw   busbw #wrong
#        (B)    (elements)                               (us)  (GB/s)  (GB/s)            (us)  (GB/s)  (GB/s)
  8589934592    2147483648     float     sum      -1    37210  230.85  403.99      0    37198  230.92  404.11      0
# Avg bus bandwidth    : 3xx.xx
```

(Representative output for an 8-GPU NVSwitch node. Compare `busbw` at large message sizes against the published value for your platform. A much lower result points to topology, Fabric Manager, or PCIe/ACS settings.)

### 12.2 Symptom → cause → fix

| Symptom | Likely cause | Check | Fix |
|---|---|---|---|
| `nvidia-driver-daemonset` in `CrashLoopBackOff` | Driver already installed on the host, missing kernel headers, Secure Boot blocking unsigned modules, or unsupported kernel | `kubectl logs -n gpu-operator ds/nvidia-driver-daemonset -c nvidia-driver-ctr` | Set `driver.enabled=false` when using the host driver; use a supported kernel; use signed or precompiled drivers |
| Pods `Pending`: `Insufficient nvidia.com/gpu` | Device plugin not running, all GPUs allocated, or MIG strategy mismatch | `kubectl describe node`; device plugin logs | Fix the plugin; match the resource name (`nvidia.com/gpu` vs `nvidia.com/mig-*`); add capacity |
| `mig.config.state=failed` | GPU processes still running during reconfiguration, or a profile not valid for this GPU | `kubectl logs -n gpu-operator ds/nvidia-mig-manager` | Drain GPU workloads; use a profile from the GPU's MIG profile list |
| CUDA app fails on HGX/DGX with `system not yet initialized` | Fabric Manager not running or its version does not match the driver | `systemctl status nvidia-fabricmanager` | Install a Fabric Manager that matches the driver version and start it |
| `ImagePullBackOff` from `nvcr.io` with `401` | Wrong secret: username is not literally `$oauthtoken`, or the key is expired | `kubectl describe pod` events | Recreate the secret with `'$oauthtoken'` in single quotes and a valid key |
| NIM restart loop during the first start | Liveness probe kills the pod during model download | Logs show download progress, then the container restarts | Add a `startupProbe` with a long budget; persist the cache |
| NIM: no compatible profile, or a slow vLLM fallback | GPU not supported for an optimized profile, or not enough GPUs/memory for TP | `list-model-profiles` | Use a supported GPU, request more GPUs, or set `NIM_MODEL_PROFILE` |
| TensorRT: `Serialization assertion ... failed` or engine deserialization error | Engine built on a different GPU architecture or TensorRT version | Compare build and runtime GPU and TRT version | Rebuild the engine on target hardware; pin image versions |
| Triton: model `UNAVAILABLE` | Error in `config.pbtxt`, wrong dims or name, missing version dir, backend mismatch | `curl :8000/v2/repository/index -X POST`; startup logs | Fix the config; make sure the layout is `<model>/<version>/model.*` |
| Low GPU utilization during training | Data-loader bottleneck (CPU, storage) or communication bound | `DCGM_FI_PROF_GR_ENGINE_ACTIVE`, CPU usage, I/O wait | DALI, RAPIDS, GPUDirect Storage, more loader workers, local NVMe cache |
| Multi-node training scales poorly | NCCL uses TCP sockets instead of IB/RoCE, or GPUDirect RDMA is unavailable | `NCCL_DEBUG=INFO` logs (`NET/IB` vs `NET/Socket`) | Network Operator, RDMA device plugin, correct `NCCL_IB_HCA`, peer memory module |
| XID 79 | GPU fell off the bus (power, thermal, PCIe) | `dmesg \| grep -i xid` | Drain the node; check power and cooling; RMA if it recurs |
| XID 48 / 94 / 95 | ECC errors (DBE, contained, or uncontained) | `nvidia-smi -q -d ECC,ROW_REMAPPER` | 94: restart the affected app; 95 or repeated 48: reset the GPU or drain and RMA |
| XID 13 / 31 / 43 | Usually application faults (illegal memory access, MMU fault) | App logs, `compute-sanitizer` | Fix the application; not normally hardware |

```
$ sudo dmesg -T | grep -i xid
[Wed Nov 12 09:14:27 2026] NVRM: Xid (PCI:0000:9a:00): 79, pid='<unknown>', name=<unknown>, GPU has fallen off the bus.
```

### 12.3 Scenario-to-solution quick map (exam drill)

| Scenario | Answer |
|---|---|
| Deploy a supported LLM endpoint fast, with an OpenAI-compatible API | **NIM** |
| Serve TensorFlow, PyTorch, and ONNX models behind one API with dynamic batching | **Triton** |
| Maximize inference throughput of one CNN on a given GPU | **TensorRT** |
| Maximize LLM tokens/s with in-flight batching and a paged KV cache | **TensorRT-LLM** |
| Disaggregated prefill/decode across a large LLM fleet | **Dynamo** |
| Fine-tune an LLM on company data and add safety rails | **NeMo** (Customizer + Guardrails) |
| Build a RAG pipeline with embedding and reranking | **NeMo Retriever** NIMs |
| Speed up pandas ETL without rewriting code | **RAPIDS** (`cudf.pandas`) |
| Automate driver, toolkit, and device plugin on Kubernetes GPU nodes | **GPU Operator** |
| Enable RDMA / GPUDirect in Kubernetes | **Network Operator** |
| Monitor GPU health and run diagnostics | **DCGM** (+ dcgm-exporter) |
| Provision and manage an on-prem DGX cluster | **Base Command Manager** |
| Share a GPU pool across teams with quotas and fair share | **Run:ai** |
| Manage AI apps across hundreds of retail stores | **Fleet Command** |
| Hardware-isolated GPU partitions for multi-tenant inference | **MIG** |
| GPUs inside VMware VMs | **vGPU** (AI Enterprise) |
| Offload network, storage, and security processing and isolate the infrastructure | **BlueField DPU** (DOCA) |
| Lossless low-latency fabric for large-scale training | **Quantum InfiniBand** |
| AI-optimized Ethernet fabric | **Spectrum-X** |
| Load data from storage directly into GPU memory | **GPUDirect Storage** |
| Supported, secure, certified enterprise AI software | **NVIDIA AI Enterprise** |
| Download optimized containers, models, and Helm charts | **NGC** |
| Turnkey AI supercomputer reference design | **DGX SuperPOD** |
| AI infrastructure without capex | **DGX Cloud** |
| Speech recognition and TTS | **Riva** |
| Medical imaging and genomics | **Clara** (MONAI, Parabricks) |
| Real-time cyber threat detection | **Morpheus** |
| Multi-camera video analytics | **Metropolis / DeepStream** |
| Robot simulation and perception | **Isaac** |
| Recommender systems | **Merlin** |
| Industrial digital twin on OpenUSD | **Omniverse** |

---

## 13. Key takeaways

1. **Know the layer.** Most "which product" questions are answered by identifying the layer: hardware, network, management, libraries, frameworks, or applications.
2. **Inference products compose.** TensorRT optimizes, TensorRT-LLM specializes for LLMs, Triton serves, Dynamo distributes, and NIM packages it all with support.
3. **The GPU Operator turns GPU nodes into managed cattle.** Its dependency chain (driver, toolkit, plugin, validator) is the first place to look when GPUs disappear from Kubernetes.
4. **DCGM is the source of truth for GPU health.** XID codes separate application bugs (13, 31, 43) from hardware failures (48, 79, 95).
5. **Sharing is a trade-off.** MIG gives isolation, time-slicing gives density without isolation, vGPU covers VMs, and Run:ai adds policy on top.
6. **AI Enterprise is the commercial wrapper.** It provides support, security, and branch stability for the open components, and it is the license that covers NIM in production.

---

## Referencias

- NVIDIA AI Infrastructure and Operations (NCA-AIIO) exam study guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy — AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA TensorRT: https://developer.nvidia.com/tensorrt
- NVIDIA AI Inference platform: https://developer.nvidia.com/topics/ai/ai-inference
- Tips on Scaling Storage for AI Training and Inferencing: https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
- What Are Large Language Models Used For?: https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
- NVIDIA GPU Operator: Simplifying GPU Management in Kubernetes: https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes
- NVIDIA GPU Operator documentation: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html
- GPU Operator — GPU time-slicing: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-sharing.html
- GPU Operator — MIG support: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-operator-mig.html
- NVIDIA Network Operator: https://docs.nvidia.com/networking/display/kubernetes2410/index.html
- NVIDIA Multi-Instance GPU User Guide: https://docs.nvidia.com/datacenter/tesla/mig-user-guide/
- NVIDIA DCGM documentation: https://docs.nvidia.com/datacenter/dcgm/latest/index.html
- DCGM Exporter: https://github.com/NVIDIA/dcgm-exporter
- NVIDIA XID errors: https://docs.nvidia.com/deploy/xid-errors/index.html
- NVIDIA Fabric Manager User Guide: https://docs.nvidia.com/datacenter/tesla/fabric-manager-user-guide/index.html
- NVIDIA NIM for LLMs documentation: https://docs.nvidia.com/nim/large-language-models/latest/introduction.html
- NVIDIA NIM Operator: https://docs.nvidia.com/nim-operator/latest/index.html
- NVIDIA Triton Inference Server documentation: https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/index.html
- NVIDIA Dynamo: https://developer.nvidia.com/dynamo
- TensorRT-LLM: https://github.com/NVIDIA/TensorRT-LLM
- NVIDIA NeMo: https://developer.nvidia.com/nemo-framework
- NeMo Guardrails: https://docs.nvidia.com/nemo/guardrails/latest/index.html
- NVIDIA AI Enterprise: https://docs.nvidia.com/ai-enterprise/index.html
- NGC catalog: https://catalog.ngc.nvidia.com/
- RAPIDS: https://rapids.ai/
- NCCL: https://developer.nvidia.com/nccl
- nccl-tests: https://github.com/NVIDIA/nccl-tests
- Magnum IO: https://developer.nvidia.com/magnum-io
- GPUDirect Storage: https://docs.nvidia.com/gpudirect-storage/index.html
- NVIDIA Base Command Manager: https://docs.nvidia.com/base-command-manager/index.html
- NVIDIA Run:ai documentation: https://run-ai-docs.nvidia.com/
- NVIDIA Fleet Command: https://docs.nvidia.com/fleet-command/index.html
- NVIDIA DGX SuperPOD reference architecture: https://docs.nvidia.com/dgx-superpod/index.html
- NVIDIA BlueField DPU / DOCA: https://docs.nvidia.com/doca/sdk/index.html
- NVIDIA Spectrum-X: https://www.nvidia.com/en-us/networking/spectrumx/
- NVIDIA Quantum InfiniBand: https://www.nvidia.com/en-us/networking/products/infiniband/
- NVIDIA Clara: https://developer.nvidia.com/clara
- NVIDIA Riva: https://developer.nvidia.com/riva
- NVIDIA Morpheus: https://developer.nvidia.com/morpheus-cybersecurity
- NVIDIA Metropolis: https://developer.nvidia.com/metropolis
- NVIDIA Isaac: https://developer.nvidia.com/isaac
- NVIDIA Merlin: https://developer.nvidia.com/merlin
- NVIDIA Omniverse: https://developer.nvidia.com/omniverse