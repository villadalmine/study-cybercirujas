# 1.7 — Software Components of the AI Development and Deployment Life Cycle

> **Exam weight:** 4.75% · **Exam:** NVIDIA-Certified Associate: AI Infrastructure and Operations (NCA-AIIO)

---

## 1. Motivation: why the software stack is an infrastructure problem

A GPU cluster without the right software stack is expensive idle silicon. In production, most AI incidents are not caused by hardware. They come from **mismatches between software layers**:

- A driver that does not support the CUDA version baked into a container.
- A training framework built against a different cuDNN.
- An inference server that loads a TensorRT engine compiled for another GPU architecture.
- A Kubernetes node that has GPUs but no device plugin advertising them.

The architectural problem is this: the AI life cycle spans **several personas** (data engineers, data scientists, ML engineers, platform/SRE), **several runtimes** (notebooks, batch training, online inference), and **several schedulers** (Slurm, Kubernetes). Each stage has different resource profiles:

| Stage | Dominant resource | Typical bottleneck | Failure mode SRE sees |
|---|---|---|---|
| Data preparation | CPU/GPU + storage throughput | I/O, ETL on CPU | GPUs starved, low `GPU_UTIL` during training |
| Training / fine-tuning | Multi-GPU, multi-node compute + interconnect | NCCL collectives, checkpoint I/O | Hangs in all-reduce, OOM, Xid errors |
| Optimization | Single GPU, short jobs | Calibration data, precision loss | Accuracy regression after FP8/INT8 |
| Inference / serving | GPU memory, latency | KV cache, batching, cold start | p99 latency spikes, OOM on long prompts |
| Monitoring / retraining | Telemetry pipeline | Missing metrics | Silent model drift, undetected GPU degradation |

NVIDIA solves this with a **layered, containerized software stack**. Every layer is versioned and validated together. Distribution goes through the **NGC catalog** and, for enterprise support, **NVIDIA AI Enterprise**.

---

## 2. The layered stack: a mental model

```
┌──────────────────────────────────────────────────────────────────────┐
│ Applications / Workflows: LLM chatbots, RAG, vision, recommender     │
├──────────────────────────────────────────────────────────────────────┤
│ Inference & Serving:  NVIDIA NIM │ Triton Inference Server │ Dynamo  │
│ Optimization:         TensorRT │ TensorRT-LLM │ Model Optimizer       │
├──────────────────────────────────────────────────────────────────────┤
│ Training & Customization: NeMo │ PyTorch │ TensorFlow │ JAX           │
│ Data Science / ETL:       RAPIDS (cuDF, cuML) │ DALI │ Spark-RAPIDS  │
├──────────────────────────────────────────────────────────────────────┤
│ CUDA-X libraries: cuDNN │ cuBLAS │ NCCL │ cuFFT │ GPUDirect Storage  │
├──────────────────────────────────────────────────────────────────────┤
│ CUDA Toolkit / CUDA runtime                                          │
├──────────────────────────────────────────────────────────────────────┤
│ Container runtime: NVIDIA Container Toolkit (containerd/CRI-O/Docker)│
├──────────────────────────────────────────────────────────────────────┤
│ Orchestration: Kubernetes + GPU Operator / Network Operator │ Slurm  │
│ Cluster mgmt:  Base Command Manager │ Run:ai (GPU scheduling)        │
├──────────────────────────────────────────────────────────────────────┤
│ NVIDIA Driver (kernel module) │ Fabric Manager │ DCGM │ MIG          │
├──────────────────────────────────────────────────────────────────────┤
│ Hardware: GPUs │ NVLink/NVSwitch │ InfiniBand/Ethernet │ DPUs        │
└──────────────────────────────────────────────────────────────────────┘
```

**Key principle for the exam:** the **driver lives on the host**. Everything from the CUDA runtime upward lives **inside the container**. The NVIDIA Container Toolkit bridges the two: at container start it injects the host driver libraries and device nodes into the container. That separation lets you run a PyTorch container built for CUDA 12.x on any host whose driver is new enough. CUDA forward/minor-version compatibility rules apply.

---

## 3. Component-by-component, mapped to the life cycle

### 3.1 Data preparation and ingestion

| Component | What it does | Why it matters in production |
|---|---|---|
| **RAPIDS** (cuDF, cuML, cuGraph) | GPU-accelerated DataFrames and ML, pandas/scikit-learn-like APIs | Moves ETL from CPU to GPU; orders-of-magnitude faster feature engineering |
| **RAPIDS Accelerator for Apache Spark** | Plugin that runs Spark SQL/DataFrame ops on GPUs | Reuses existing Spark pipelines without rewrite |
| **DALI** (Data Loading Library) | GPU-accelerated decode/augment pipeline for images, video, audio | Removes the CPU data-loader bottleneck that starves GPUs |
| **GPUDirect Storage (GDS)** | Direct DMA path between storage (NVMe, NVMe-oF, parallel FS) and GPU memory | Bypasses the CPU bounce buffer; lowers latency and CPU utilization |
| **NeMo Curator** | Scalable data curation for LLM pretraining (dedup, filtering, PII) | Data quality is the main driver of LLM quality |

The NVIDIA storage guidance makes the operational point explicit. Training reads large datasets repeatedly. Checkpoints write large bursts. Inference needs fast model loading. Storage must be sized for **throughput and parallelism**, not just capacity. The usual pattern is a tiered design:

- A shared parallel/network filesystem.
- Local NVMe caching on each node.
- A GDS-capable path where supported.

### 3.2 Model development and training

| Component | Role |
|---|---|
| **PyTorch / TensorFlow / JAX (NGC containers)** | Frameworks, delivered as monthly NGC containers (`nvcr.io/nvidia/pytorch:YY.MM-py3`) validated with matching CUDA, cuDNN, NCCL |
| **NVIDIA NeMo Framework** | End-to-end framework for building, customizing (SFT, PEFT/LoRA, RLHF/DPO), and scaling generative AI / LLMs; uses Megatron-Core for tensor/pipeline/data parallelism |
| **cuDNN** | Primitives for deep neural networks (convolutions, attention, normalization) |
| **cuBLAS** | GPU BLAS — matrix multiply is the heart of training |
| **NCCL** | Collective communications (all-reduce, all-gather) across GPUs and nodes over NVLink, InfiniBand, RoCE |
| **Transformer Engine** | FP8 mixed-precision training on Hopper/Blackwell |
| **Jupyter / NGC notebooks** | Interactive development, often on smaller GPU slices (MIG) |

**Why NGC containers instead of `pip install`?** NGC containers are built, tested, and performance-tuned monthly. They pin a known-good combination of framework + CUDA + cuDNN + NCCL. This removes the most common source of "works on my laptop" breakage. It also makes training reproducible across workstation, on-prem DGX, and cloud.

### 3.3 Optimization (between training and deployment)

| Component | Role |
|---|---|
| **TensorRT** | SDK for high-performance inference: graph optimization, layer/tensor fusion, kernel auto-tuning, precision calibration (FP16, INT8, FP8, FP4 on supported GPUs). Produces a serialized **engine/plan** specific to GPU architecture and TensorRT version |
| **TensorRT-LLM** | Open-source library for LLM inference: in-flight batching, paged KV cache, quantization, tensor/pipeline parallelism, speculative decoding |
| **TensorRT Model Optimizer** | Quantization (PTQ/QAT), pruning, distillation, sparsity to compress models before deployment |
| **ONNX** | Interchange format commonly used to hand a trained model to TensorRT |

**Critical trade-off:** a TensorRT engine is **not portable**. An engine built on an A100 (Ampere, SM 8.0) will not run on an H100 (Hopper, SM 9.0), and it is tied to the TensorRT version that built it. Production pipelines therefore build engines **per GPU SKU**, ideally in CI or at deploy time.

### 3.4 Inference and serving

| Component | What it is | Best fit |
|---|---|---|
| **Triton Inference Server** | Open-source inference server: multiple backends (TensorRT, TensorRT-LLM, PyTorch, ONNX Runtime, OpenVINO, Python, FIL), dynamic batching, concurrent model execution, ensembles, HTTP/gRPC, Prometheus metrics | Multi-framework, multi-model fleets; custom pipelines |
| **NVIDIA NIM** | Prebuilt, optimized inference **microservices**. Container = model + optimized engine (e.g. TensorRT-LLM) + industry-standard API (OpenAI-compatible for LLMs). Automatically selects an optimized profile for the detected GPU | Fastest path to production for foundation models; enterprise support via AI Enterprise |
| **NVIDIA Dynamo** | Open-source distributed inference framework for large-scale generative AI: disaggregated prefill/decode, KV-cache-aware routing, multi-node serving | Very large LLM/reasoning deployments across many GPUs/nodes |
| **NeMo Retriever / NeMo Guardrails** | Microservices for RAG (embedding, reranking) and safety rails | Enterprise RAG and governed LLM apps |

### 3.5 Orchestration, scheduling, and cluster management

| Component | Role |
|---|---|
| **NVIDIA GPU Operator** | Kubernetes operator that automates all GPU node software as containers: driver, Container Toolkit, device plugin, GPU Feature Discovery, DCGM/DCGM Exporter, MIG Manager, validator |
| **NVIDIA Network Operator** | Same idea for networking: MOFED/DOCA drivers, RDMA shared device plugin, SR-IOV, GPUDirect RDMA |
| **Kubernetes device plugin** | Advertises `nvidia.com/gpu` as an extended resource to the kubelet |
| **Slurm** | HPC batch scheduler; dominant for large multi-node training (often with Pyxis/Enroot for containers) |
| **NVIDIA Run:ai** | GPU orchestration/scheduling on Kubernetes: quotas, fair share, fractional GPUs, preemption |
| **NVIDIA Base Command Manager** | Cluster provisioning and management for DGX/HPC/K8s clusters (node imaging, monitoring, Slurm/K8s deployment) |
| **Kubeflow / MLflow** | MLOps: pipelines, distributed training operators, experiment tracking, model registry |

### 3.6 Monitoring and operations

| Component | Role |
|---|---|
| **nvidia-smi** | Per-node CLI for GPU state, processes, MIG, clocks, ECC |
| **DCGM** (Data Center GPU Manager) | Health checks, diagnostics (`dcgmi diag`), policy, telemetry at fleet scale |
| **DCGM Exporter** | Exposes DCGM metrics in Prometheus format (`DCGM_FI_*`) |
| **Triton/NIM metrics** | Request latency, queue time, batch size, throughput, KV-cache usage |

### 3.7 The enterprise wrapper: NVIDIA AI Enterprise

**NVIDIA AI Enterprise** is the licensed, supported software suite. It bundles:

- The frameworks, NIM, Triton, TensorRT, RAPIDS, and NeMo.
- Infrastructure software: GPU Operator, Network Operator, vGPU drivers.
- Production branches with long-term support, security patching (CVE scanning), and certification on mainstream hypervisors, Kubernetes distributions, and clouds.

On the exam, "enterprise support, security, and stability for the AI software stack" points to **NVIDIA AI Enterprise**. "Where do I pull optimized containers and models?" points to **NGC**.

---

## 4. Technical comparisons and trade-offs

### 4.1 Serving options

| Criterion | Framework-native (e.g. TorchServe / raw PyTorch) | Triton Inference Server | NVIDIA NIM | NVIDIA Dynamo |
|---|---|---|---|---|
| Time to production | Medium | Medium (you write `config.pbtxt`, build engines) | **Lowest** (pull & run) | High (distributed design) |
| Performance | Baseline | High (TensorRT backend, dynamic batching) | High (pre-optimized engine per GPU) | **Highest at scale** (disaggregation, KV routing) |
| Model flexibility | One framework | **Any** supported backend, ensembles | Catalog models + supported custom/LoRA | LLM-focused, multiple engines |
| API | Custom | KServe v2 protocol (HTTP/gRPC) | Industry-standard (OpenAI-compatible for LLMs) | OpenAI-compatible frontend |
| Ops burden | High | Medium | Low | Medium–High |
| Typical use | Prototypes | Mixed CV/NLP/tabular fleets | Enterprise GenAI, fast adoption | Multi-node LLM serving, reasoning models |

### 4.2 Precision trade-offs (TensorRT / Model Optimizer)

| Precision | Memory vs FP32 | Throughput | Accuracy risk | Requirement |
|---|---|---|---|---|
| FP32 | 1x | Baseline | None | Any GPU |
| FP16 / BF16 | 0.5x | ~2x+ (Tensor Cores) | Very low | Volta+ (BF16: Ampere+) |
| INT8 | 0.25x | High | Needs calibration (PTQ) or QAT | Calibration dataset |
| FP8 | 0.25x | High | Low with Transformer Engine / scaling | Hopper/Ada/Blackwell |
| FP4 (NVFP4) | 0.125x | Highest | Requires careful quantization | Blackwell |

### 4.3 Scheduler choice for training

| Criterion | Slurm | Kubernetes (+ GPU Operator, Kubeflow, Run:ai) |
|---|---|---|
| Gang scheduling of multi-node jobs | Native | Needs add-ons (Kueue, Volcano, Run:ai, Kubeflow Training Operator) |
| Topology awareness (IB, NVLink) | Mature | Improving (topology-aware scheduling via add-ons) |
| Serving workloads | Poor fit | **Native** (Deployments, autoscaling, Services) |
| Container story | Pyxis/Enroot, Apptainer | Native |
| Typical persona | HPC/research teams | Platform/SRE teams running mixed train + serve |

### 4.4 Host-installed drivers vs GPU Operator

| Aspect | Driver baked into the OS image | GPU Operator (containerized driver) |
|---|---|---|
| Day-0 provisioning | Image build per driver version | Helm install; driver deployed as DaemonSet |
| Upgrades | Reimage / config management | Rolling upgrade controlled by operator (`upgradePolicy`) |
| Immutable OS (e.g. RHCOS, Talos) | Hard | Designed for it (or use pre-installed driver with `driver.enabled=false`) |
| Drift between nodes | Common | Declarative via `ClusterPolicy` |
| Debuggability | Familiar | Requires knowing the operator's pods and ordering |

---

## 5. End-to-end reference implementation on Kubernetes

The path below goes from bare GPU nodes to a monitored inference endpoint.

### 5.1 Install the GPU Operator

```
$ helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
"nvidia" has been added to your repositories

$ helm repo update
Hang tight while we grab the latest from your chart repositories...
...Successfully got an update from the "nvidia" chart repository
Update Complete. ⎈Happy Helming!⎈

$ kubectl create namespace gpu-operator
namespace/gpu-operator created

$ kubectl label --overwrite ns gpu-operator pod-security.kubernetes.io/enforce=privileged
namespace/gpu-operator labeled
```

The values file below makes the important production choices explicit:

```yaml
# gpu-operator-values.yaml
operator:
  defaultRuntime: containerd
driver:
  enabled: true
  upgradePolicy:
    autoUpgrade: true
    maxParallelUpgrades: 1
    maxUnavailable: "25%"
    drain:
      enable: true
      force: false
      timeoutSeconds: 300
      deleteEmptyDir: true
toolkit:
  enabled: true
devicePlugin:
  enabled: true
  config:
    name: time-slicing-config
    default: any
dcgm:
  enabled: true
dcgmExporter:
  enabled: true
  serviceMonitor:
    enabled: true
    interval: 15s
gfd:
  enabled: true
migManager:
  enabled: true
  config:
    name: default-mig-parted-config
mig:
  strategy: single
nfd:
  enabled: true
validator:
  plugin:
    env:
      - name: WITH_WORKLOAD
        value: "true"
```

Time-slicing config referenced by the device plugin. Use it only for dev/notebook nodes, because time-slicing gives **no memory isolation**:

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

$ helm install gpu-operator nvidia/gpu-operator \
    -n gpu-operator \
    -f gpu-operator-values.yaml \
    --wait
NAME: gpu-operator
LAST DEPLOYED: Thu Nov 12 10:14:02 2026
NAMESPACE: gpu-operator
STATUS: deployed
REVISION: 1
```

Expected steady state. The ordering is what matters: driver → toolkit → device plugin → validators.

```
$ kubectl get pods -n gpu-operator
NAME                                                          READY   STATUS      RESTARTS   AGE
gpu-feature-discovery-7xk2p                                   1/1     Running     0          6m
gpu-operator-6b8c9d7f5-q2wlz                                  1/1     Running     0          7m
gpu-operator-node-feature-discovery-gc-5d8f6c7b9-tm4cx        1/1     Running     0          7m
gpu-operator-node-feature-discovery-master-7c9f7d8b6-hz7rd    1/1     Running     0          7m
gpu-operator-node-feature-discovery-worker-9qk5m              1/1     Running     0          7m
nvidia-container-toolkit-daemonset-l8v2n                      1/1     Running     0          6m
nvidia-cuda-validator-x7d4f                                   0/1     Completed   0          4m
nvidia-dcgm-exporter-c5hnm                                    1/1     Running     0          6m
nvidia-dcgm-z2b8r                                             1/1     Running     0          6m
nvidia-device-plugin-daemonset-tq6wj                          1/1     Running     0          6m
nvidia-driver-daemonset-6p8vj                                 1/1     Running     0          7m
nvidia-mig-manager-48sjd                                      1/1     Running     0          5m
nvidia-operator-validator-kn2xr                               1/1     Running     0          6m
```

```
$ kubectl get node gpu-node-01 -o jsonpath='{.status.allocatable}' | jq
{
  "cpu": "127500m",
  "ephemeral-storage": "1729724637044",
  "memory": "2112342360Ki",
  "nvidia.com/gpu": "8",
  "pods": "110"
}

$ kubectl get node gpu-node-01 --show-labels | tr ',' '\n' | grep nvidia.com/gpu
nvidia.com/gpu.count=8
nvidia.com/gpu.family=hopper
nvidia.com/gpu.memory=81559
nvidia.com/gpu.present=true
nvidia.com/gpu.product=NVIDIA-H100-80GB-HBM3
nvidia.com/gpu.replicas=1
```

`nvidia.com/gpu.*` labels come from **GPU Feature Discovery**. They let you pin workloads to a GPU family. This is essential because TensorRT engines are architecture-specific.

### 5.2 NGC registry credentials

```
$ export NGC_API_KEY='<your-ngc-api-key>'

$ kubectl create namespace ai-platform
namespace/ai-platform created

$ kubectl -n ai-platform create secret docker-registry ngc-registry \
    --docker-server=nvcr.io \
    --docker-username='$oauthtoken' \
    --docker-password="${NGC_API_KEY}"
secret/ngc-registry created

$ kubectl -n ai-platform create secret generic ngc-api \
    --from-literal=NGC_API_KEY="${NGC_API_KEY}"
secret/ngc-api created
```

The username is literally the string `$oauthtoken`, not a variable.

### 5.3 Shared storage for datasets, checkpoints, and model repository

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ai-shared
  namespace: ai-platform
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: parallel-fs
  resources:
    requests:
      storage: 10Ti
```

### 5.4 Distributed training with an NGC PyTorch container (Kubeflow Training Operator)

```yaml
apiVersion: kubeflow.org/v1
kind: PyTorchJob
metadata:
  name: resnet50-ddp
  namespace: ai-platform
spec:
  runPolicy:
    cleanPodPolicy: None
    backoffLimit: 2
  pytorchReplicaSpecs:
    Master:
      replicas: 1
      restartPolicy: OnFailure
      template:
        spec:
          imagePullSecrets:
            - name: ngc-registry
          nodeSelector:
            nvidia.com/gpu.family: hopper
          containers:
            - name: pytorch
              image: nvcr.io/nvidia/pytorch:24.08-py3
              command:
                - torchrun
              args:
                - "--nproc_per_node=8"
                - /workspace/train/train_ddp.py
                - "--data=/data/imagenet"
                - "--checkpoint-dir=/data/checkpoints/resnet50"
                - "--amp"
                - "--dali"
              env:
                - name: NCCL_DEBUG
                  value: WARN
                - name: NCCL_IB_DISABLE
                  value: "0"
              resources:
                limits:
                  nvidia.com/gpu: 8
                  memory: 512Gi
                  cpu: "64"
              volumeMounts:
                - name: shared
                  mountPath: /data
                - name: dshm
                  mountPath: /dev/shm
          volumes:
            - name: shared
              persistentVolumeClaim:
                claimName: ai-shared
            - name: dshm
              emptyDir:
                medium: Memory
                sizeLimit: 64Gi
    Worker:
      replicas: 1
      restartPolicy: OnFailure
      template:
        spec:
          imagePullSecrets:
            - name: ngc-registry
          nodeSelector:
            nvidia.com/gpu.family: hopper
          containers:
            - name: pytorch
              image: nvcr.io/nvidia/pytorch:24.08-py3
              command:
                - torchrun
              args:
                - "--nproc_per_node=8"
                - /workspace/train/train_ddp.py
                - "--data=/data/imagenet"
                - "--checkpoint-dir=/data/checkpoints/resnet50"
                - "--amp"
                - "--dali"
              env:
                - name: NCCL_DEBUG
                  value: WARN
                - name: NCCL_IB_DISABLE
                  value: "0"
              resources:
                limits:
                  nvidia.com/gpu: 8
                  memory: 512Gi
                  cpu: "64"
              volumeMounts:
                - name: shared
                  mountPath: /data
                - name: dshm
                  mountPath: /dev/shm
          volumes:
            - name: shared
              persistentVolumeClaim:
                claimName: ai-shared
            - name: dshm
              emptyDir:
                medium: Memory
                sizeLimit: 64Gi
```

Production notes:

- **`/dev/shm` as a memory-backed `emptyDir`** is mandatory. The default 64 MiB container shm makes PyTorch DataLoader and NCCL fail with bus errors.
- **`NCCL_DEBUG=INFO`** is the first thing to enable when a multi-node job hangs at the first all-reduce. It prints the selected transport (NVLink, `NET/IB`, or `NET/Socket`). Falling back to `Socket` over plain TCP is a common silent performance killer.
- **Checkpoint frequently** to shared storage. Node failure (Xid 79, "GPU has fallen off the bus") is a matter of *when* at scale.

```
$ kubectl -n ai-platform get pytorchjob resnet50-ddp
NAME           STATE     AGE
resnet50-ddp   Running   3m

$ kubectl -n ai-platform logs resnet50-ddp-master-0 | grep -E "NCCL INFO (Using|Channel 00)" | head -3
resnet50-ddp-master-0:52:52 [0] NCCL INFO Using network IB
resnet50-ddp-master-0:52:52 [0] NCCL INFO Channel 00/32 :    0   1   2   3   4   5   6   7   8   9  10  11  12  13  14  15
resnet50-ddp-master-0:52:52 [0] NCCL INFO Channel 00/0 : 0[0] -> 1[1] via P2P/NVL
```

(That output appears with `NCCL_DEBUG=INFO`.)

### 5.5 Optimize: ONNX → TensorRT engine

Run this in the **same GPU architecture and TensorRT version** that Triton will use. Matching the NGC release (`24.08`) of the TensorRT container and the Triton container guarantees the latter.

```
$ docker run --rm --gpus all -v /data:/data nvcr.io/nvidia/tensorrt:24.08-py3 \
    trtexec --onnx=/data/models/resnet50.onnx \
            --saveEngine=/data/models/resnet50.plan \
            --fp16 \
            --minShapes=input:1x3x224x224 \
            --optShapes=input:16x3x224x224 \
            --maxShapes=input:64x3x224x224
...
[I] === Performance summary ===
[I] Throughput: 4127.63 qps
[I] Latency: min = 3.71 ms, max = 4.42 ms, mean = 3.86 ms, median = 3.85 ms, percentile(90%) = 3.93 ms, percentile(95%) = 3.97 ms, percentile(99%) = 4.11 ms
...
&&&& PASSED TensorRT.trtexec [TensorRT v100300] # trtexec --onnx=/data/models/resnet50.onnx --saveEngine=/data/models/resnet50.plan --fp16 ...
```

Throughput and latency values are illustrative and depend on GPU and model. The line to check is `&&&& PASSED`.

### 5.6 Serve with Triton Inference Server

Model repository layout on the shared volume:

```
/data/model_repository/
└── resnet50_trt/
    ├── config.pbtxt
    └── 1/
        └── model.plan
```

`config.pbtxt` (protobuf text format):

```
name: "resnet50_trt"
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
dynamic_batching {
  preferred_batch_size: [ 16, 32 ]
  max_queue_delay_microseconds: 500
}
instance_group [
  {
    count: 2
    kind: KIND_GPU
  }
]
```

Deployment and Service:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: triton
  namespace: ai-platform
  labels:
    app: triton
spec:
  replicas: 2
  selector:
    matchLabels:
      app: triton
  template:
    metadata:
      labels:
        app: triton
    spec:
      imagePullSecrets:
        - name: ngc-registry
      nodeSelector:
        nvidia.com/gpu.family: hopper
      containers:
        - name: tritonserver
          image: nvcr.io/nvidia/tritonserver:24.08-py3
          command:
            - tritonserver
          args:
            - "--model-repository=/data/model_repository"
            - "--strict-model-config=false"
            - "--log-verbose=0"
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
            initialDelaySeconds: 15
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /v2/health/live
              port: http
            initialDelaySeconds: 30
            periodSeconds: 15
          resources:
            limits:
              nvidia.com/gpu: 1
              memory: 32Gi
              cpu: "8"
          volumeMounts:
            - name: shared
              mountPath: /data
              readOnly: true
            - name: dshm
              mountPath: /dev/shm
      volumes:
        - name: shared
          persistentVolumeClaim:
            claimName: ai-shared
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 4Gi
---
apiVersion: v1
kind: Service
metadata:
  name: triton
  namespace: ai-platform
  labels:
    app: triton
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

```
$ kubectl -n ai-platform logs deploy/triton | grep -A4 "Model "
+--------------+---------+--------+
| Model        | Version | Status |
+--------------+---------+--------+
| resnet50_trt | 1       | READY  |
+--------------+---------+--------+

$ kubectl -n ai-platform port-forward svc/triton 8000:8000 8002:8002 &
$ curl -s -o /dev/null -w "%{http_code}\n" localhost:8000/v2/health/ready
200

$ curl -s localhost:8000/v2/models/resnet50_trt | jq '.platform, .versions'
"tensorrt_plan"
[
  "1"
]
```

Load-test with `perf_analyzer`. It ships in the `-py3-sdk` image.

```
$ docker run --rm --net=host nvcr.io/nvidia/tritonserver:24.08-py3-sdk \
    perf_analyzer -m resnet50_trt -u localhost:8001 -i grpc \
    --concurrency-range 1:8:2 --shape input:3,224,224
...
Inferences/Second vs. Client Average Batch Latency
Concurrency: 1, throughput: 512.4 infer/sec, latency 1950 usec
Concurrency: 3, throughput: 1398.7 infer/sec, latency 2143 usec
Concurrency: 5, throughput: 2104.9 infer/sec, latency 2374 usec
Concurrency: 7, throughput: 2617.3 infer/sec, latency 2672 usec
```

The numbers are illustrative. The shape of the curve is the insight. Throughput rises with concurrency because **dynamic batching** groups requests, while latency rises slowly. When latency starts growing faster than throughput, you have found the saturation point. Use it to set HPA targets.

### 5.7 Serve an LLM with NVIDIA NIM

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nim-cache
  namespace: ai-platform
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: parallel-fs
  resources:
    requests:
      storage: 200Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nim-llama
  namespace: ai-platform
  labels:
    app: nim-llama
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nim-llama
  template:
    metadata:
      labels:
        app: nim-llama
    spec:
      imagePullSecrets:
        - name: ngc-registry
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
        - name: nim
          image: nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
          env:
            - name: NGC_API_KEY
              valueFrom:
                secretKeyRef:
                  name: ngc-api
                  key: NGC_API_KEY
            - name: NIM_CACHE_PATH
              value: /opt/nim/.cache
          ports:
            - name: http
              containerPort: 8000
          startupProbe:
            httpGet:
              path: /v1/health/ready
              port: http
            periodSeconds: 10
            failureThreshold: 180
          readinessProbe:
            httpGet:
              path: /v1/health/ready
              port: http
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /v1/health/live
              port: http
            periodSeconds: 15
          resources:
            limits:
              nvidia.com/gpu: 1
          volumeMounts:
            - name: cache
              mountPath: /opt/nim/.cache
            - name: dshm
              mountPath: /dev/shm
      volumes:
        - name: cache
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
  name: nim-llama
  namespace: ai-platform
spec:
  selector:
    app: nim-llama
  ports:
    - name: http
      port: 8000
      targetPort: http
```

In production, pin a specific NIM version tag instead of `latest`.

Why the long `startupProbe`? On first start, NIM downloads weights and the optimized engine profile for the detected GPU into `NIM_CACHE_PATH`. That can take many minutes. A persistent cache makes subsequent pod starts fast, which matters for autoscaling and cold-start SLOs.

```
$ kubectl -n ai-platform logs deploy/nim-llama | grep -iE "profile|Uvicorn"
INFO ... Selected profile: <profile-id> (tensorrt_llm-h100-bf16-tp1-throughput)
INFO ... Uvicorn running on http://0.0.0.0:8000 (Press CTRL+C to quit)

$ kubectl -n ai-platform port-forward svc/nim-llama 8080:8000 &
$ curl -s localhost:8080/v1/models | jq -r '.data[].id'
meta/llama-3.1-8b-instruct

$ curl -s localhost:8080/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"What does the GPU Operator install?"}],"max_tokens":64}' \
    | jq -r '.choices[0].message.content'
The NVIDIA GPU Operator installs and manages the NVIDIA driver, container toolkit, device plugin, ...
```

The profile line format varies by NIM version. Use `list-model-profiles` inside the container to see which profiles are compatible with your GPU.

### 5.8 Monitoring: DCGM Exporter + Prometheus

A ServiceMonitor for Triton. DCGM Exporter's ServiceMonitor is created by the operator via `dcgmExporter.serviceMonitor.enabled`.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: triton
  namespace: ai-platform
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: triton
  endpoints:
    - port: metrics
      interval: 15s
      path: /metrics
```

Alerting rules covering hardware, utilization, and serving:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: ai-platform-gpu
  namespace: ai-platform
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: gpu-health
      rules:
        - alert: GPUXidErrors
          expr: |
            DCGM_FI_DEV_XID_ERRORS > 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} reported Xid {{ $value }}"
        - alert: GPUTemperatureHigh
          expr: |
            DCGM_FI_DEV_GPU_TEMP > 85
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} above 85C"
        - alert: GPUStarvedDuringTraining
          expr: |
            avg by (Hostname) (DCGM_FI_DEV_GPU_UTIL{namespace="ai-platform"}) < 40
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Low GPU utilization on {{ $labels.Hostname }}: check data pipeline / storage throughput"
        - alert: GPUFramebufferNearlyFull
          expr: |
            DCGM_FI_DEV_FB_USED
              /
            (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE) > 0.95
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "GPU {{ $labels.gpu }} memory above 95%"
    - name: inference-slo
      rules:
        - alert: TritonQueueTimeHigh
          expr: |
            rate(nv_inference_queue_duration_us[5m])
              /
            clamp_min(rate(nv_inference_request_success[5m]), 1) > 50000
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Triton average queue time above 50ms for {{ $labels.model }}: scale out or tune batching"
```

```
$ kubectl -n gpu-operator port-forward svc/nvidia-dcgm-exporter 9400:9400 &
$ curl -s localhost:9400/metrics | grep -E "^DCGM_FI_DEV_(GPU_UTIL|FB_USED|GPU_TEMP)" | head -3
DCGM_FI_DEV_GPU_TEMP{gpu="0",UUID="GPU-8f1c...",device="nvidia0",modelName="NVIDIA H100 80GB HBM3",Hostname="gpu-node-01",container="tritonserver",namespace="ai-platform",pod="triton-5f8d6c9b7-2xk4p"} 54
DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-8f1c...",device="nvidia0",modelName="NVIDIA H100 80GB HBM3",Hostname="gpu-node-01",container="tritonserver",namespace="ai-platform",pod="triton-5f8d6c9b7-2xk4p"} 87
DCGM_FI_DEV_FB_USED{gpu="0",UUID="GPU-8f1c...",device="nvidia0",modelName="NVIDIA H100 80GB HBM3",Hostname="gpu-node-01",container="tritonserver",namespace="ai-platform",pod="triton-5f8d6c9b7-2xk4p"} 21734
```

The `pod`/`namespace` labels are what make DCGM Exporter useful on Kubernetes: they attribute GPU telemetry to workloads.

---

## 6. Verification and failure diagnosis

### 6.1 Bottom-up verification sequence

Always diagnose **from the bottom of the stack upward**. A failure in a lower layer surfaces as a confusing error in a higher one.

```
# 1. Driver: is the kernel module loaded and talking to the GPUs?
$ kubectl -n gpu-operator exec ds/nvidia-driver-daemonset -- nvidia-smi
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 550.90.07              Driver Version: 550.90.07      CUDA Version: 12.4     |
|-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
|=========================================+========================+======================|
|   0  NVIDIA H100 80GB HBM3          On  |   00000000:18:00.0 Off |                    0 |
| N/A   34C    P0             71W /  700W |       0MiB /  81559MiB |      0%      Default |
...

# 2. Container toolkit: can an arbitrary container see the GPU?
$ kubectl run cuda-smoke --rm -it --restart=Never \
    --image=nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04 \
    --overrides='{"spec":{"containers":[{"name":"cuda-smoke","image":"nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04","command":["nvidia-smi","-L"],"resources":{"limits":{"nvidia.com/gpu":"1"}}}]}}'
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-8f1c...)
pod "cuda-smoke" deleted

# 3. Device plugin: is the resource advertised?
$ kubectl describe node gpu-node-01 | grep -A2 "nvidia.com/gpu"
  nvidia.com/gpu:     8
  ...

# 4. Health/diagnostics via DCGM (level 1 = quick, 3 = long)
$ kubectl -n gpu-operator exec ds/nvidia-dcgm -- dcgmi diag -r 1
+---------------------------+------------------------------------------------+
| Diagnostic                | Result                                         |
+===========================+================================================+
|-----  Metadata  ----------+------------------------------------------------|
| DCGM Version              | 3.3.x                                          |
| Driver Version Detected   | 550.90.07                                      |
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
+---------------------------+------------------------------------------------+

# 5. Kernel-level hardware errors
$ kubectl debug node/gpu-node-01 -it --image=busybox -- chroot /host dmesg -T | grep -i xid
[Thu Nov 12 09:41:17 2026] NVRM: Xid (PCI:0000:18:00): 79, pid=..., GPU has fallen off the bus.
```

Notes:
- The `CUDA Version` shown by `nvidia-smi` is the **maximum CUDA version the driver supports**, not what is installed in containers.
- If the `nvidia-dcgm` DaemonSet is disabled in your setup, DCGM runs embedded in the exporter. Use `nvidia-smi` and DCGM Exporter metrics instead.

### 6.2 Symptom → cause → fix

| Symptom | Layer | Likely cause | Diagnostic | Fix |
|---|---|---|---|---|
| Pod `Pending`: `Insufficient nvidia.com/gpu` | Scheduling | Device plugin not running, GPUs already allocated, or validator not finished | `kubectl describe node`, `kubectl -n gpu-operator get pods` | Wait for/repair device plugin; check other pods' requests; check taints |
| `nvidia-driver-daemonset` in `CrashLoopBackOff` | Driver | Kernel headers unavailable, Secure Boot unsigned module, preinstalled host driver conflicting | `kubectl logs -n gpu-operator ds/nvidia-driver-daemonset -c nvidia-driver-ctr` | Use precompiled driver / matching kernel; or set `driver.enabled=false` if host driver is preinstalled |
| `CUDA driver version is insufficient for CUDA runtime version` | Driver ↔ container | Container CUDA newer than host driver supports | `nvidia-smi` (max CUDA) vs image CUDA | Upgrade driver or use an older NGC container release (check NGC support matrix) |
| Triton model `UNAVAILABLE`: engine deserialization error | Optimization ↔ serving | TensorRT engine built with different TRT version or GPU architecture | Triton logs at `--log-verbose=1` | Rebuild engine with the TensorRT version of the Triton release, on the target GPU |
| Training hangs at first step on multi-node | Communication | NCCL can't reach peers, wrong interface, IB not exposed | `NCCL_DEBUG=INFO` logs, check `NET/Socket` vs `NET/IB` | Set `NCCL_SOCKET_IFNAME`, deploy Network Operator / RDMA device plugin, fix firewall |
| `Bus error` / DataLoader worker killed | Container config | `/dev/shm` too small | `df -h /dev/shm` in pod | Mount memory-backed `emptyDir` at `/dev/shm` |
| GPU util low (<40%) during training | Data pipeline / storage | CPU decoding, slow shared FS, small files | DCGM `GPU_UTIL`, node CPU, storage throughput | DALI, RAPIDS, local NVMe cache, GDS, larger shards (WebDataset/TFRecord) |
| NIM pod restarts during first start | Serving | Liveness kills pod while downloading weights | `kubectl describe pod` (probe failures) | Add `startupProbe` with long threshold; persistent `NIM_CACHE_PATH` |
| NIM: no compatible profile | Serving | GPU not supported by any optimized profile for that model | `list-model-profiles` in container | Use a supported GPU, or fall back to a generic (e.g. vLLM-based) profile where offered |
| `CUDA out of memory` at inference with long prompts | Serving | KV cache growth, batch size too large | `DCGM_FI_DEV_FB_USED`, server logs | Limit max sequence length/batch, quantize (FP8/INT4), use larger GPU or tensor parallelism |
| `DCGM_FI_DEV_XID_ERRORS` with Xid 48/63/64/79/94/95 | Hardware | ECC errors, row remap, GPU fell off bus | `dmesg`, `nvidia-smi -q -d ECC`, `dcgmi diag -r 3` | Drain node (`kubectl drain`), reset/RMA per NVIDIA guidance |
| MIG resources not appearing | Partitioning | MIG Manager config label not set or GPU in use | `kubectl get node -L nvidia.com/mig.config,nvidia.com/mig.config.state` | Label node `nvidia.com/mig.config=all-1g.10gb`, ensure no GPU workloads during reconfig |

### 6.3 MIG reconfiguration check

```
$ kubectl label node gpu-node-02 nvidia.com/mig.config=all-1g.10gb --overwrite
node/gpu-node-02 labeled

$ kubectl get node gpu-node-02 -L nvidia.com/mig.config.state
NAME          STATUS   ROLES    AGE   VERSION   MIG.CONFIG.STATE
gpu-node-02   Ready    <none>   41d   v1.31.2   pending

$ kubectl get node gpu-node-02 -L nvidia.com/mig.config.state
NAME          STATUS   ROLES    AGE   VERSION   MIG.CONFIG.STATE
gpu-node-02   Ready    <none>   41d   v1.31.2   success

$ kubectl get node gpu-node-02 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
56
```

With `mig.strategy: single` and 8 GPUs × 7 `1g.10gb` slices, the node advertises 56 `nvidia.com/gpu`. This is the right pattern for many small inference/notebook workloads that need **hardware-isolated** memory and compute. Time-slicing does not give that isolation.

---

## 7. Exam-oriented summary

| If the question is about… | The answer is usually… |
|---|---|
| Distribution of optimized, validated AI containers/models | **NGC catalog** |
| Supported, secure, enterprise-grade AI software suite | **NVIDIA AI Enterprise** |
| GPU-accelerated data science / ETL | **RAPIDS** (cuDF, cuML), **RAPIDS Accelerator for Spark** |
| GPU-accelerated data loading/augmentation for training | **DALI** |
| Direct storage-to-GPU data path | **GPUDirect Storage** (Magnum IO) |
| Building/customizing LLMs and generative AI | **NeMo** |
| Multi-GPU/multi-node communication | **NCCL** |
| Optimizing a trained model for inference (fusion, quantization) | **TensorRT** / **TensorRT-LLM** / **Model Optimizer** |
| Serving many models from many frameworks with dynamic batching | **Triton Inference Server** |
| Prebuilt, optimized, API-standard inference microservice | **NVIDIA NIM** |
| Large-scale distributed/disaggregated LLM inference | **NVIDIA Dynamo** |
| Automating driver, toolkit, device plugin, monitoring on Kubernetes | **GPU Operator** |
| Automating RDMA/high-speed networking on Kubernetes | **Network Operator** |
| GPU health, diagnostics, and telemetry | **DCGM** / **DCGM Exporter** |
| Exposing GPUs to containers | **NVIDIA Container Toolkit** |
| Cluster provisioning/management | **Base Command Manager** |
| GPU-aware scheduling, quotas, fractional GPUs on K8s | **Run:ai** |

Life cycle in one line: **Data prep** (RAPIDS, DALI, GDS) → **Train/customize** (PyTorch/NeMo + CUDA-X + NCCL, in NGC containers, on Slurm or K8s) → **Optimize** (TensorRT/TensorRT-LLM/Model Optimizer) → **Deploy** (Triton, NIM, Dynamo on K8s with GPU Operator) → **Monitor** (DCGM, Prometheus) → feed drift and feedback back into data prep and retraining.

---

## Referencias

- NVIDIA NCA-AIIO Exam Study Guide (official): https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy — AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA TensorRT: https://developer.nvidia.com/tensorrt
- NVIDIA AI Inference (Triton, NIM, TensorRT-LLM, Dynamo): https://developer.nvidia.com/topics/ai/ai-inference
- Tips on Scaling Storage for AI Training and Inferencing: https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
- What Are Large Language Models Used For?: https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
- NVIDIA GPU Operator: Simplifying GPU Management in Kubernetes: https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes
- NVIDIA GPU Operator documentation: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html
- NVIDIA Container Toolkit: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/index.html
- Triton Inference Server documentation: https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/index.html
- NVIDIA NIM for LLMs documentation: https://docs.nvidia.com/nim/large-language-models/latest/introduction.html
- NVIDIA DCGM documentation: https://docs.nvidia.com/datacenter/dcgm/latest/index.html
- DCGM Exporter: https://github.com/NVIDIA/dcgm-exporter
- NGC Catalog: https://catalog.ngc.nvidia.com/
- NVIDIA AI Enterprise: https://www.nvidia.com/en-us/data-center/products/ai-enterprise/
- NVIDIA NeMo Framework: https://docs.nvidia.com/nemo-framework/user-guide/latest/overview.html
- RAPIDS: https://rapids.ai/
- NVIDIA DALI: https://docs.nvidia.com/deeplearning/dali/user-guide/docs/index.html
- NVIDIA GPUDirect Storage: https://docs.nvidia.com/gpudirect-storage/index.html
- NCCL documentation: https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/index.html
- TensorRT-LLM: https://github.com/NVIDIA/TensorRT-LLM
- NVIDIA Dynamo: https://github.com/ai-dynamo/dynamo
- Kubeflow Training Operator (PyTorchJob): https://www.kubeflow.org/docs/components/trainer/