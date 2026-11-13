# 1.4 — Factors Contributing to the Recent Rapid Improvement and Adoption of AI

> **Exam weight: 4.75%.** This is a conceptual objective. The NCA-AIIO exam does not ask you to tune a cluster. It does expect you to name the forces behind the AI boom and explain how they reinforce each other. Questions are usually framed as "which factor enabled X" or "why did Y become practical". The hands-on sections below make those factors concrete, so you can recognize each one in a real production stack.

---

## 1. Motivation: why "why now?" is an infrastructure question

Neural networks are not new. Backpropagation was popularized in 1986, and convolutional networks were reading handwritten cheques in the 1990s. Then, for roughly two decades, AI stayed a niche field. After 2012 it suddenly went mainstream, and after November 2022 (ChatGPT) it became a board-level priority across most industries.

The algorithm did not suddenly become right. Several independent constraints were relaxed at about the same time:

| Constraint before ~2012 | What relaxed it | Effect |
|---|---|---|
| Compute: training a deep network on CPUs took weeks or months | GPU **accelerated computing** (massively parallel, high memory bandwidth) and later **Tensor Cores** | Iteration time dropped from months to days, then to hours |
| Data: labeled datasets were small | Internet-scale data, ImageNet (~1.2M labeled training images for ILSVRC), and later self-supervised pre-training on unlabeled text and images | Models could learn general representations |
| Algorithms: deep nets were hard to train | ReLU, dropout, batch norm, residual connections, Adam, and the **Transformer** (2017) | Depth and scale became trainable, and Transformers parallelize well on GPUs |
| Software: every lab wrote its own kernels | CUDA, cuDNN, NCCL, PyTorch/TensorFlow/JAX, TensorRT, Triton | A researcher writes Python, and the stack produces near-peak hardware utilization |
| Scale-out: one machine was the limit | NVLink/NVSwitch, InfiniBand/RoCE with RDMA, GPUDirect | Thousands of GPUs train one model |
| Access: you had to own a supercomputer | Cloud GPU instances, Kubernetes with the GPU Operator, NGC containers, managed AI services | Any team can rent or schedule GPUs on demand |
| Reuse: every model trained from scratch | Pretrained **foundation models**, open weights, model hubs, fine-tuning (LoRA), RAG | Adoption cost shifted from training to inference and customization |

The 2012 inflection point was **AlexNet**. It won ILSVRC 2012 by a wide margin and was trained on **two consumer NVIDIA GTX 580 GPUs**. This one event combined three of the factors: a large labeled dataset (ImageNet), GPU compute (CUDA), and algorithmic tricks (ReLU, dropout). The lesson for an architect is that **AI progress is gated by whichever of these constraints is currently the bottleneck**. The same reasoning applies inside your own cluster today.

The SRE takeaway: these "historical" factors are the same layers you run in production. If one of them is weak in your environment, your AI platform under-performs. Examples include starved storage, a missing driver, a slow interconnect, or a model served without an optimized runtime.

---

## 2. The factors in depth

### 2.1 Accelerated computing: the GPU as the engine

**Why GPUs fit.** Neural network training and inference are dominated by dense linear algebra, mainly matrix multiplications (GEMMs) and convolutions. These operations are:

- **Massively data-parallel.** The same operation runs over millions of elements.
- **Throughput-bound, not latency-bound.** Total work matters more than how fast any single scalar is computed.
- **Bandwidth-hungry.** Weights and activations must stream from memory constantly.

A CPU spends its transistor budget on a few complex cores, large caches, branch prediction, and out-of-order execution. That design optimizes single-thread latency. A GPU spends it on thousands of simpler cores grouped into Streaming Multiprocessors (SMs), plus very high-bandwidth memory (HBM on data center parts). That design optimizes aggregate throughput.

**Architectural milestones the exam may reference:**

| Generation | Notable AI-relevant introduction |
|---|---|
| Pascal (P100, 2016) | NVLink (first generation), HBM2, FP16 compute |
| Volta (V100, 2017) | **Tensor Cores**: dedicated matrix-multiply-accumulate units for mixed precision |
| Ampere (A100, 2020) | TF32, BF16, structured sparsity, **MIG** (Multi-Instance GPU) |
| Hopper (H100, 2022) | **Transformer Engine** with **FP8**, 4th-gen NVLink, NVLink Switch |
| Blackwell (2024) | 2nd-gen Transformer Engine, **FP4**, 5th-gen NVLink, rack-scale NVL72 systems |

**Reduced precision is a hidden multiplier.** Each step from FP32 → FP16/BF16 → FP8 → FP4 roughly doubles math throughput per unit of silicon and halves the memory and bandwidth needed per parameter. Models tolerate this because of mixed-precision techniques:

- loss scaling
- higher-precision master weights or accumulators
- calibration and quantization-aware methods

Much of the "AI got faster" story comes from this co-design of hardware formats and numerical techniques, not only from more transistors.

| Dimension | CPU | GPU | Trade-off note |
|---|---|---|---|
| Core design | Few, complex, latency-optimized | Thousands, simple, throughput-optimized | GPUs lose on branchy, serial code |
| Memory bandwidth | Tens to low hundreds of GB/s per socket | TB/s with HBM | Bandwidth often limits LLM inference more than FLOPS |
| Matrix math | SIMD/AVX, some AMX | Tensor Cores, mixed precision | Most of the speedup requires reduced precision |
| Programming | General-purpose | CUDA plus libraries | Software maturity is the moat (see 2.4) |
| Best fit | Preprocessing, orchestration, control plane | Training, batched inference | Real pipelines need both: CPU starvation idles GPUs |

### 2.2 Data: from scarce labels to self-supervision

- **Volume.** Digitization, the web, mobile devices, sensors, and logs produce data at a scale that did not exist before.
- **Curated benchmarks.** ImageNet showed that a large labeled dataset plus a shared benchmark accelerates a whole field.
- **Self-supervised pre-training.** LLMs learn by predicting the next token on unlabeled text. This removes the human-labeling bottleneck, so the usable dataset becomes "most of the public text available", measured in trillions of tokens.
- **Synthetic data.** Simulation (for example, robotics and autonomous vehicles in Omniverse-style simulators) and model-generated data supplement real data where it is scarce or sensitive.

**Infrastructure consequence:** data pipelines and **storage** become first-class. A GPU waiting on I/O is expensive idle silicon. NVIDIA's storage guidance for AI recommends:

- profiling the I/O pattern (many small random reads for training, large sequential writes for checkpoints)
- using caching tiers and parallel or distributed filesystems
- using **GPUDirect Storage** so data moves between NVMe or network storage and GPU memory without bouncing through a CPU bounce buffer

### 2.3 Algorithms: the Transformer and scaling laws

- **Enabling tricks (2010s):** ReLU activations, dropout, batch/layer normalization, residual connections (ResNet, 2015), and adaptive optimizers (Adam). Together these made very deep networks trainable.
- **The Transformer (Vaswani et al., 2017, "Attention Is All You Need")** replaced recurrence with self-attention. RNNs process tokens sequentially, which is hostile to GPUs. Attention over a sequence is expressed as large matrix multiplications, so it **parallelizes extremely well on GPUs**. That made it feasible to train on far more data. The Transformer now underpins LLMs, vision transformers, speech models, and multimodal models.
- **Scaling laws.** Kaplan et al. (2020) and Hoffmann et al. ("Chinchilla", 2022) showed empirically that loss falls predictably as a power law of model size, data, and compute. Chinchilla's result is that, for a fixed compute budget, parameters and training tokens should be scaled together, at roughly 20 tokens per parameter. This turned AI progress into a **capital-planning problem**: more compute gives predictably better models. That is why investment in GPU infrastructure exploded.
- **Efficiency innovations** keep stretching the hardware:
  - FlashAttention (IO-aware attention kernels)
  - Mixture-of-Experts (only a fraction of parameters is active per token)
  - quantization
  - speculative decoding
  - KV-cache management (paged attention)

### 2.4 The software stack: full-stack acceleration

Hardware alone does not explain adoption. The CUDA ecosystem (since 2006) means a data scientist writing `model.cuda()` in PyTorch gets near-hardware performance with no kernel engineering.

```
┌──────────────────────────────────────────────────────────────┐
│ Applications / AI services (chatbots, copilots, RAG, vision) │
├──────────────────────────────────────────────────────────────┤
│ Frameworks & SDKs: PyTorch, TensorFlow, JAX, NeMo, RAPIDS    │
│ Serving: Triton Inference Server, TensorRT-LLM, NIM          │
├──────────────────────────────────────────────────────────────┤
│ Libraries: cuDNN, cuBLAS, NCCL, TensorRT, DALI, cuDF         │
├──────────────────────────────────────────────────────────────┤
│ CUDA runtime + driver                                        │
├──────────────────────────────────────────────────────────────┤
│ GPU / NVLink / NIC (InfiniBand, Ethernet RoCE) / DPU         │
└──────────────────────────────────────────────────────────────┘
```

| Component | Role in the AI boom |
|---|---|
| **CUDA** | General-purpose GPU programming model; the foundation of everything above it |
| **cuDNN / cuBLAS** | Tuned primitives (convolution, attention, GEMM) that frameworks call |
| **NCCL** | Collective communication (all-reduce, all-gather) across GPUs and nodes; makes distributed training practical |
| **Frameworks** (PyTorch, TF, JAX) | Hide the hardware; autograd; distributed APIs |
| **TensorRT** | Inference optimizer and runtime: layer and tensor fusion, kernel auto-tuning, FP16/INT8/FP8 quantization, building an optimized engine for a specific GPU |
| **TensorRT-LLM** | LLM-specific inference optimizations (in-flight batching, paged KV cache, quantization) |
| **Triton Inference Server** | Multi-framework model serving with dynamic batching, concurrent model execution, metrics |
| **NGC / NIM** | Prebuilt, tested containers and microservices, which shorten time-to-production |

### 2.5 Interconnect and scale-out

Modern models exceed one GPU's memory and one node's compute. Training runs are split three ways, and each split generates heavy GPU-to-GPU traffic:

- **data parallelism**
- **tensor/model parallelism**
- **pipeline parallelism**

| Fabric | Scope | Purpose | Trade-off |
|---|---|---|---|
| PCIe | Inside a node | GPU ↔ CPU/NIC/NVMe | General-purpose, much lower bandwidth than NVLink |
| **NVLink / NVSwitch** | Inside a node or rack (NVL72) | GPU ↔ GPU, very high bandwidth | Proprietary, limited physical domain |
| **InfiniBand** (Quantum) | Across nodes | RDMA, low latency, in-network reduction (SHARP) | Separate fabric, specialized operations |
| **Ethernet with RoCE** (Spectrum-X) | Across nodes | RDMA over Ethernet, familiar operations | Needs lossless/congestion tuning to match IB |
| **GPUDirect RDMA** | NIC ↔ GPU | Bypasses host memory | Requires compatible NIC, driver, and topology |

Without these fabrics, adding GPUs gives diminishing returns, because communication dominates. Scale-out networking is a direct cause of the jump from million-parameter to trillion-parameter models.

### 2.6 Cloud, Kubernetes, and operational maturity

- **Cloud elasticity** turned capex into opex. A startup can rent hundreds of GPUs for a week.
- **Containers and Kubernetes** gave AI workloads the same deployment model as the rest of the business.
- The **NVIDIA GPU Operator** automates the components a GPU node needs, so GPU nodes can be managed like any other node:
  - driver
  - container toolkit
  - device plugin
  - GPU Feature Discovery
  - DCGM exporter
  - MIG manager
- **MLOps** tooling (experiment tracking, model registries, CI/CD for models, Kubeflow, KServe) made models repeatable and auditable.
- **GPU sharing** (MIG, time-slicing) raised utilization for smaller inference and dev workloads, which improved the economics.

### 2.7 Pretrained models, open ecosystems, and falling inference cost

- **Foundation models** are trained once and adapted many times. Common adaptation paths:
  - prompt engineering
  - **RAG** (retrieval-augmented generation)
  - fine-tuning or parameter-efficient methods (LoRA)
- **Open weights and model hubs** let enterprises start from a strong baseline rather than training from scratch.
- **Inference optimization** (TensorRT/TensorRT-LLM, quantization, batching) cut the cost per token. Inference is where adoption scales: it runs continuously, for every user, while training is periodic.
- **Natural-language interfaces** (LLMs) collapsed the skill barrier. Users interact without writing code, which drove the fastest consumer-adoption curve in software history after ChatGPT's launch in November 2022.

### 2.8 The flywheel

The factors reinforce one another:

```
 better hardware ──► larger models trainable ──► better capability
       ▲                                                │
       │                                                ▼
 investment / R&D ◄── revenue & adoption ◄── useful products
       ▲                                                │
       └──── more data & feedback ◄─────────────────────┘
```

On the exam, "rapid improvement" usually means this combination: **accelerated compute + big data + better algorithms + a mature full software stack + scale-out infrastructure + cloud/MLOps accessibility**. Answers that cite only one factor are usually incomplete.

---

## 3. Seeing the factors in a production cluster

The following lab maps the abstract factors onto a Kubernetes GPU cluster:

| Lab step | Factor it demonstrates |
|---|---|
| GPU Operator | Operational maturity |
| GPU pod | Accelerated computing |
| TensorRT engine | Software stack |
| Triton | Inference adoption |
| DCGM alerts | SRE observability |

### 3.1 Install the GPU Operator (operational accessibility)

```
$ helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
"nvidia" has been added to your repositories
$ helm repo update
Hang tight while we grab the latest from your chart repositories...
...Successfully got an update from the "nvidia" chart repository
Update Complete. ⎈Happy Helming!⎈
```

Pin the chart version in production. Check the GPU Operator release notes for the version that supports your OS and kernel.

```yaml
# gpu-operator-values.yaml
driver:
  enabled: true
toolkit:
  enabled: true
devicePlugin:
  enabled: true
dcgmExporter:
  enabled: true
  serviceMonitor:
    enabled: true
gfd:
  enabled: true
migManager:
  enabled: true
nodeStatusExporter:
  enabled: true
operator:
  defaultRuntime: containerd
```

```
$ helm install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator --create-namespace \
    --values gpu-operator-values.yaml --wait
NAME: gpu-operator
LAST DEPLOYED: Wed Nov 11 10:14:02 2026
NAMESPACE: gpu-operator
STATUS: deployed
REVISION: 1
```

```
$ kubectl get pods -n gpu-operator
NAME                                                   READY   STATUS      RESTARTS   AGE
gpu-feature-discovery-x7k2p                            1/1     Running     0          4m
gpu-operator-6d9c8b7f5c-q2lzm                          1/1     Running     0          5m
gpu-operator-node-feature-discovery-master-5b8f-hk4    1/1     Running     0          5m
gpu-operator-node-feature-discovery-worker-mx9tq       1/1     Running     0          5m
nvidia-container-toolkit-daemonset-7rjzf               1/1     Running     0          4m
nvidia-cuda-validator-l2m8d                            0/1     Completed   0          3m
nvidia-dcgm-exporter-9pq4w                             1/1     Running     0          4m
nvidia-device-plugin-daemonset-bt6vn                   1/1     Running     0          4m
nvidia-driver-daemonset-sx5kd                          1/1     Running     0          5m
nvidia-operator-validator-wq7zr                        1/1     Running     0          4m
```

GPU Feature Discovery labels the node, so the scheduler and you can see the accelerator's capabilities:

```
$ kubectl get node gpu-node-01 -o json | jq '.metadata.labels | with_entries(select(.key | startswith("nvidia.com/gpu")))'
{
  "nvidia.com/gpu.count": "8",
  "nvidia.com/gpu.family": "hopper",
  "nvidia.com/gpu.memory": "81559",
  "nvidia.com/gpu.product": "NVIDIA-H100-80GB-HBM3",
  "nvidia.com/gpu.present": "true"
}

$ kubectl describe node gpu-node-01 | grep -A1 -E "^(Capacity|Allocatable):" ; kubectl get node gpu-node-01 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
8
```

### 3.2 Inspect the hardware factors on the node

```
$ nvidia-smi
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 570.xx.xx              Driver Version: 570.xx.xx      CUDA Version: 12.8     |
|-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
|=========================================+========================+======================|
|   0  NVIDIA H100 80GB HBM3          On  |   00000000:18:00.0 Off |                    0 |
| N/A   34C    P0             72W /  700W |       1MiB /  81559MiB |      0%      Default |
...
```

The interconnect topology shows why NVLink matters (`NV18` = 18 NVLink links between the pair):

```
$ nvidia-smi topo -m
        GPU0    GPU1    GPU2    GPU3    NIC0    CPU Affinity    NUMA Affinity
GPU0     X      NV18    NV18    NV18    PXB     0-55            0
GPU1    NV18     X      NV18    NV18    PXB     0-55            0
GPU2    NV18    NV18     X      NV18    SYS     56-111          1
GPU3    NV18    NV18    NV18     X      SYS     56-111          1
NIC0    PXB     PXB     SYS     SYS      X

Legend:
  X    = Self
  SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes
  PXB  = Connection traversing multiple PCIe bridges
  NV#  = Connection traversing a bonded set of # NVLinks
```

```
$ nvidia-smi nvlink -s -i 0
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-...)
         Link 0: 26.562 GB/s
         Link 1: 26.562 GB/s
         ...
```

### 3.3 Software-stack factor: TensorRT optimization

This step takes an exported ONNX model and builds an optimized engine. Here is a Job that runs `trtexec` from the NGC TensorRT container:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: trt-build-resnet50
  namespace: ai-inference
spec:
  backoffLimit: 1
  template:
    metadata:
      labels:
        app: trt-build
    spec:
      restartPolicy: Never
      containers:
        - name: trtexec
          image: nvcr.io/nvidia/tensorrt:25.01-py3
          command: ["/bin/bash", "-c"]
          args:
            - >-
              trtexec --onnx=/models/onnx/resnet50.onnx
              --saveEngine=/models/repo/resnet50_trt/1/model.plan
              --fp16 --minShapes=input:1x3x224x224
              --optShapes=input:16x3x224x224
              --maxShapes=input:32x3x224x224
          resources:
            limits:
              nvidia.com/gpu: 1
          volumeMounts:
            - name: models
              mountPath: /models
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: model-repo
```

The relevant parts of the log:

```
$ kubectl logs -n ai-inference job/trt-build-resnet50 | grep -E "Throughput|Latency|PASSED"
[I] Throughput: 4873.21 qps
[I] Latency: min = 3.12 ms, max = 3.61 ms, mean = 3.24 ms, median = 3.23 ms, percentile(99%) = 3.48 ms
&&&& PASSED TensorRT.trtexec [TensorRT v100700] # trtexec --onnx=/models/onnx/resnet50.onnx ...
```

The numbers are illustrative; measure on your own GPU. The point is the method. Compare the same model in native framework FP32, then as a TensorRT FP16 engine, then INT8/FP8. The throughput gap is the "software factor" in numbers. A `.plan` engine is specific to the GPU architecture and TensorRT version, so rebuild it when either changes.

### 3.4 Adoption factor: serving with Triton

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: triton
  namespace: ai-inference
  labels:
    app: triton
spec:
  replicas: 1
  selector:
    matchLabels:
      app: triton
  template:
    metadata:
      labels:
        app: triton
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8002"
    spec:
      nodeSelector:
        nvidia.com/gpu.present: "true"
      containers:
        - name: tritonserver
          image: nvcr.io/nvidia/tritonserver:25.01-py3
          args:
            - tritonserver
            - --model-repository=/models/repo
            - --strict-model-config=false
            - --log-verbose=0
          ports:
            - name: http
              containerPort: 8000
            - name: grpc
              containerPort: 8001
            - name: metrics
              containerPort: 8002
          readinessProbe:
            httpGet:
              path: /v2/health/ready
              port: http
            initialDelaySeconds: 20
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /v2/health/live
              port: http
            initialDelaySeconds: 30
            periodSeconds: 15
          resources:
            requests:
              cpu: "4"
              memory: 16Gi
            limits:
              nvidia.com/gpu: 1
              memory: 32Gi
          volumeMounts:
            - name: models
              mountPath: /models
            - name: dshm
              mountPath: /dev/shm
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: model-repo
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 4Gi
---
apiVersion: v1
kind: Service
metadata:
  name: triton
  namespace: ai-inference
spec:
  selector:
    app: triton
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

Model configuration with dynamic batching. This file is protobuf text format, not YAML, so it gets no label:

```
# /models/repo/resnet50_trt/config.pbtxt
name: "resnet50_trt"
platform: "tensorrt_plan"
max_batch_size: 32
dynamic_batching {
  preferred_batch_size: [ 8, 16, 32 ]
  max_queue_delay_microseconds: 200
}
instance_group [
  {
    count: 2
    kind: KIND_GPU
  }
]
```

```
$ kubectl port-forward -n ai-inference svc/triton 8000:8000 8002:8002 &
$ curl -s -o /dev/null -w "%{http_code}\n" localhost:8000/v2/health/ready
200
$ curl -s localhost:8000/v2/models/resnet50_trt | jq '{name, platform, versions}'
{
  "name": "resnet50_trt",
  "platform": "tensorrt_plan",
  "versions": [
    "1"
  ]
}
```

Load-test with `perf_analyzer` (from the Triton SDK container) to watch dynamic batching raise throughput:

```
$ perf_analyzer -m resnet50_trt -u localhost:8001 -i grpc --concurrency-range 1:8:2 --shape input:3,224,224
Inferences/Second vs. Client Average Batch Latency
Concurrency: 1, throughput: 610.4 infer/sec, latency 1636 usec
Concurrency: 3, throughput: 1702.9 infer/sec, latency 1760 usec
Concurrency: 5, throughput: 2641.1 infer/sec, latency 1891 usec
Concurrency: 7, throughput: 3388.6 infer/sec, latency 2063 usec
```

Throughput rises far faster than latency as concurrency grows. That is batching amortizing per-request overhead, and it is a core reason inference became economically viable at scale.

### 3.5 Utilization economics: GPU time-slicing

For dev and light inference workloads, one physical GPU can be advertised as multiple schedulable resources:

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
$ kubectl get node gpu-node-01 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
32
$ kubectl get node gpu-node-01 -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.replicas}{"\n"}'
4
```

| Sharing method | Isolation | Use case | Trade-off |
|---|---|---|---|
| Whole GPU | Full | Training, large-model inference | Low utilization for small jobs |
| **MIG** (Ampere and later, data center GPUs) | Hardware: dedicated SMs, memory, cache slices | Multi-tenant inference with QoS | Fixed partition profiles, reconfiguration drains the GPU |
| **Time-slicing** | None (shared memory, context switching) | Dev, notebooks, bursty light inference | No memory or fault isolation, noisy neighbors |
| MPS | Partial (concurrent kernels) | Cooperative processes from one tenant | Limited fault isolation |

### 3.6 Observability: catch the bottleneck factor

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gpu-efficiency
  namespace: gpu-operator
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: gpu.efficiency
      rules:
        - alert: GPUAllocatedButIdle
          expr: |
            avg by (Hostname, gpu, exported_pod) (
              avg_over_time(DCGM_FI_DEV_GPU_UTIL[30m])
            ) < 10
            and on (Hostname, gpu)
            avg by (Hostname, gpu) (DCGM_FI_DEV_FB_USED) > 1024
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} allocated but under 10% utilized"
            description: "Likely input pipeline, storage or CPU bottleneck in pod {{ $labels.exported_pod }}."
        - alert: GPUXidError
          expr: |
            max by (Hostname, gpu) (DCGM_FI_DEV_XID_ERRORS) > 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "XID error {{ $value }} on GPU {{ $labels.gpu }} ({{ $labels.Hostname }})"
            description: "Check dmesg on the node and the NVIDIA XID error catalogue."
        - alert: GPUMemoryNearlyFull
          expr: |
            DCGM_FI_DEV_FB_USED
              /
            (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE) > 0.95
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "GPU framebuffer above 95% on {{ $labels.Hostname }} GPU {{ $labels.gpu }}"
```

```
$ kubectl port-forward -n gpu-operator svc/nvidia-dcgm-exporter 9400:9400 &
$ curl -s localhost:9400/metrics | grep -E "^DCGM_FI_DEV_(GPU_UTIL|FB_USED|POWER_USAGE)" | head -3
DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-3f2a...",Hostname="gpu-node-01",modelName="NVIDIA H100 80GB HBM3"} 87
DCGM_FI_DEV_FB_USED{gpu="0",UUID="GPU-3f2a...",Hostname="gpu-node-01",modelName="NVIDIA H100 80GB HBM3"} 41230
DCGM_FI_DEV_POWER_USAGE{gpu="0",UUID="GPU-3f2a...",Hostname="gpu-node-01",modelName="NVIDIA H100 80GB HBM3"} 512.4
```

Label names (`exported_pod`, `Hostname`) depend on your DCGM exporter and Prometheus relabeling config. Check them with the `curl` above before you rely on the alert.

---

## 4. Verification and failure diagnosis

Each historical factor has a production failure mode. When an AI platform is slow, ask which factor is the current bottleneck.

| Symptom | Factor at fault | Likely cause | Verification |
|---|---|---|---|
| Node shows `nvidia.com/gpu: 0` allocatable | Operational stack | Driver or device-plugin pod failing; Secure Boot blocking an unsigned kernel module; kernel headers missing | `kubectl get pods -n gpu-operator`; `kubectl logs -n gpu-operator ds/nvidia-driver-daemonset`; `mokutil --sb-state` on the node |
| Pod `Pending`, `Insufficient nvidia.com/gpu` | Capacity / sharing | All GPUs allocated; MIG profile mismatch | `kubectl describe pod <p>`; `kubectl describe node \| grep -A8 Allocated` |
| `CUDA driver version is insufficient for CUDA runtime version` | Software stack | Container CUDA is newer than the host driver supports | `nvidia-smi` (top-right "CUDA Version" = max supported); pick an older NGC image or upgrade the driver |
| GPU util low (<30%) during training | Data / storage | Dataloader, decode, or filesystem can't feed the GPU | `nvidia-smi dmon -s u`; `iostat -x 5` on storage; raise `num_workers`, use DALI, add caching tier, or GPUDirect Storage |
| Multi-node training scales poorly | Interconnect | NCCL falling back to TCP sockets; RDMA not in use; topology not NUMA-aligned | Run with `NCCL_DEBUG=INFO`, look for `NET/IB` vs `NET/Socket`; `ibstat`; `nvidia-smi topo -m` |
| Training stalls periodically | Storage | Synchronous checkpoint writes saturating storage | Correlate stalls with checkpoint intervals; use async/sharded checkpointing, faster write tier |
| Inference latency high, GPU underused | Software / serving | No batching, running FP32 framework model instead of an optimized engine | `perf_analyzer`; enable `dynamic_batching`; convert with TensorRT / TensorRT-LLM |
| TensorRT engine fails to load after upgrade | Software stack | `.plan` built for a different TRT version or GPU architecture | Triton logs show deserialization error; rebuild the engine in the Job from 3.3 |
| Xid errors, GPU falls off bus | Hardware | Thermal, power, PCIe, or memory (ECC) fault | `dmesg -T \| grep -i xid`; `nvidia-smi -q -d ECC,TEMPERATURE,POWER`; `dcgmi diag -r 2` |
| OOM on GPU with LLM | Algorithm / precision | Model plus KV cache too big for HBM | `nvidia-smi --query-gpu=memory.used,memory.total --format=csv`; quantize (FP8/INT4), tensor parallelism, paged KV cache |

Useful node-level commands:

```
$ dmesg -T | grep -i xid
[Wed Nov 11 09:58:12 2026] NVRM: Xid (PCI:0000:18:00): 79, pid=..., GPU has fallen off the bus.

$ dcgmi diag -r 2
Successfully ran diagnostic for group.
+---------------------------+------------------------------------------------+
| Diagnostic                | Result                                         |
+===========================+================================================+
|-----  Deployment  --------+------------------------------------------------|
| Denylist                  | Pass                                           |
| NVML Library              | Pass                                           |
| CUDA Main Library         | Pass                                           |
| Permissions and OS Blocks | Pass                                           |
| Persistence Mode          | Pass                                           |
| Environment Variables     | Pass                                           |
| Page Retirement/Row Remap | Pass                                           |
| Graphics Processes        | Pass                                           |
+-----  Integration  -------+------------------------------------------------+
| PCIe                      | Pass - All                                     |
+-----  Hardware  ----------+------------------------------------------------+
| GPU Memory                | Pass - All                                     |
+---------------------------+------------------------------------------------+

$ nvidia-smi dmon -s um -c 5
# gpu    sm   mem   enc   dec    fb  bar1
# Idx     %     %     %     %    MB    MB
    0    12     4     0     0 41230     8
    0    95    61     0     0 41230     8
    0    10     3     0     0 41230     8
    0    97    63     0     0 41230     8
    0    11     4     0     0 41230     8
```

The `dmon` pattern above, where SM utilization alternates between about 10% and about 95%, is the classic signature of an **input-pipeline-bound** job. The GPU finishes each batch and then waits for the next. The fix is in the data and storage factor, not in buying more GPUs.

Checking which transport NCCL picked:

```
$ kubectl logs train-worker-0 | grep -E "NCCL INFO (NET|Using network)"
NCCL INFO NET/IB : Using [0]mlx5_0:1/IB [1]mlx5_1:1/IB ; OOB eth0:10.0.3.14<0>
NCCL INFO Using network IB
```

If you see `NET/Socket` here on a cluster that has InfiniBand or RoCE, RDMA is not being used. Check the RDMA device plugin or network operator, the pod's `rdma/*` resource requests, and that `/dev/infiniband` is available inside the container.

---

## 5. Exam-focused summary

- **No single cause.** Rapid AI progress results from the **convergence** of:
  - accelerated computing (GPUs, Tensor Cores, reduced precision)
  - massive data
  - algorithmic breakthroughs (deep learning tricks, the Transformer, scaling laws)
  - a mature full software stack (CUDA, cuDNN, NCCL, frameworks, TensorRT, Triton)
  - high-speed interconnect (NVLink, InfiniBand/RoCE)
  - cloud and Kubernetes accessibility
  - pretrained foundation models
- **GPUs fit AI** because neural nets are massively parallel matrix math and need high memory bandwidth.
- **AlexNet (2012)** marks the deep-learning inflection: ImageNet data plus GPU training.
- **The Transformer (2017)** enabled LLMs because attention is parallelizable on GPUs, unlike sequential RNNs.
- **Generative AI adoption** accelerated with natural-language interfaces (ChatGPT, Nov 2022), pretrained models, and cheaper inference.
- **Inference is where adoption scales.** Optimized runtimes (TensorRT, TensorRT-LLM), batching (Triton), and quantization lower cost per query.
- **Operational tooling** (GPU Operator, NGC containers, MIG and time-slicing, DCGM) made GPU infrastructure manageable by ordinary platform teams.
- **Storage and data pipelines** are now first-class: idle GPUs waiting on I/O waste the most expensive resource in the data center.

---

## Referencias

- NVIDIA, *AI Infrastructure and Operations Fundamentals* (course): https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA, NCA-AIIO exam study guide (PDF): https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA TensorRT: https://developer.nvidia.com/tensorrt
- NVIDIA AI Inference: https://developer.nvidia.com/topics/ai/ai-inference
- NVIDIA Technical Blog, *Tips on Scaling Storage for AI Training and Inferencing*: https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
- NVIDIA Blog, *What Are Large Language Models Used For?*: https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
- NVIDIA Technical Blog, *NVIDIA GPU Operator: Simplifying GPU Management in Kubernetes*: https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes
- NVIDIA GPU Operator documentation (time-slicing, MIG, ClusterPolicy): https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html
- NVIDIA Triton Inference Server documentation: https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/index.html
- NVIDIA DCGM documentation: https://docs.nvidia.com/datacenter/dcgm/latest/index.html
- NVIDIA NCCL documentation: https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/index.html
- Vaswani et al., *Attention Is All You Need* (2017): https://arxiv.org/abs/1706.03762
- Krizhevsky, Sutskever, Hinton, *ImageNet Classification with Deep Convolutional Neural Networks* (2012): https://papers.nips.cc/paper/2012/hash/c399862d3b9d6b76c8436e924a68c45b-Abstract.html
- Kaplan et al., *Scaling Laws for Neural Language Models* (2020): https://arxiv.org/abs/2001.08361
- Hoffmann et al., *Training Compute-Optimal Large Language Models* (2022): https://arxiv.org/abs/2203.15556