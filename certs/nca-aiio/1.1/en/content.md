# 1.1 — The NVIDIA Software Stack in an AI Environment

> **Exam weight:** 4.75% · **Domain:** Essential AI Knowledge
> **Goal:** Be able to name each layer of the NVIDIA software stack, explain what it does, where it runs (host, container, Kubernetes control plane), how the layers depend on each other, and what breaks when one layer is misaligned with another.

---

## 1. Motivation: why a "software stack" and not just "a GPU"

A GPU without software does nothing useful. Between a PyTorch training script and the silicon, there are about six layers. Each one has its own versioning, lifecycle and owner:

| Layer | Example artifact | Who typically owns it in production |
|---|---|---|
| Hardware + firmware | H100 SXM5, NVSwitch, BlueField-3 DPU, VBIOS | Datacenter / hardware team |
| Kernel-mode driver | `nvidia.ko`, `nvidia-uvm.ko`, `nvidia-peermem.ko` | Platform / OS team |
| User-mode driver + management | `libcuda.so`, `libnvidia-ml.so` (NVML), `nvidia-smi`, Fabric Manager | Platform team (comes with the driver) |
| Runtime + toolkit | CUDA Runtime (`libcudart`), `nvcc`, CUDA-X libraries (cuBLAS, cuDNN, NCCL, TensorRT) | Packaged *inside the container image* |
| Frameworks / SDKs | PyTorch, TensorFlow, JAX, NeMo, RAPIDS, TensorRT-LLM | ML engineers |
| Serving / microservices | Triton Inference Server (Dynamo-Triton), NVIDIA NIM, NVIDIA Dynamo | ML platform / SRE |
| Orchestration / ops | GPU Operator, Network Operator, DCGM, Base Command Manager, Run:ai, Fleet Command | Platform / SRE |

The core production problem is **version coupling across ownership boundaries**. Three common cases:

- The kernel driver lives on the host and is upgraded by the OS team.
- The CUDA runtime lives in the container image and is upgraded by the ML team.
- The device plugin that advertises GPUs to Kubernetes is upgraded by the platform team.

If those three drift apart, you get errors like `CUDA driver version is insufficient for CUDA runtime version`, pods stuck `Pending` on `nvidia.com/gpu`, or containers that start but see zero GPUs.

NVIDIA's answer has three parts:

1. **Containerization of everything above the kernel driver.** The NGC catalog provides containers with CUDA, cuDNN, NCCL and the framework already aligned.
2. **Operators that manage everything below the container.** The GPU Operator and Network Operator handle drivers, the container toolkit, device plugins and monitoring.
3. **A supported, versioned bundle.** NVIDIA AI Enterprise certifies a given combination of all of the above, with enterprise support and security patching.

---

## 2. The stack, layer by layer

### 2.1 Mental model

```
┌─────────────────────────────────────────────────────────────────────────┐
│  AI Applications / Workflows                                            │
│  NeMo (LLM build/customize), Riva (speech), Morpheus (cybersec),        │
│  Clara (healthcare), Merlin (recsys), Metropolis / DeepStream (vision)  │
├─────────────────────────────────────────────────────────────────────────┤
│  Inference serving: NVIDIA NIM · Triton Inference Server · Dynamo       │
│  Optimization: TensorRT · TensorRT-LLM · TAO (transfer learning)        │
├─────────────────────────────────────────────────────────────────────────┤
│  Frameworks: PyTorch · TensorFlow · JAX · RAPIDS (cuDF, cuML, cuGraph)  │
├─────────────────────────────────────────────────────────────────────────┤
│  CUDA-X libraries: cuBLAS · cuDNN · cuFFT · cuSPARSE · CUTLASS ·        │
│                    NCCL · DALI · cuOpt                                  │
│  Magnum IO: NCCL · GPUDirect RDMA · GPUDirect Storage · NVSHMEM · UCX   │
├─────────────────────────────────────────────────────────────────────────┤
│  CUDA Runtime + Toolkit (nvcc, libcudart)          ← lives in container │
├──────────────────────────── container boundary ─────────────────────────┤
│  NVIDIA Container Toolkit (nvidia-ctk, CDI)        ← bridges the two    │
├─────────────────────────────────────────────────────────────────────────┤
│  User-mode driver: libcuda.so, NVML, nvidia-smi    ← host, injected     │
│  Kernel-mode driver: nvidia.ko, nvidia-uvm, nvidia-peermem              │
│  Fabric Manager (NVSwitch systems) · DOCA / MOFED (DPU / NIC)           │
├─────────────────────────────────────────────────────────────────────────┤
│  Hardware: GPU (MIG-capable), NVLink/NVSwitch, ConnectX/BlueField       │
└─────────────────────────────────────────────────────────────────────────┘
   Cross-cutting management:
   GPU Operator · Network Operator · DCGM · Base Command Manager ·
   Run:ai · Fleet Command · vGPU · NGC catalog · NVIDIA AI Enterprise
```

### 2.2 Driver layer

| Component | Purpose | Production notes |
|---|---|---|
| `nvidia.ko` | Core kernel module; owns the device, memory management, scheduling | Must match the running kernel. DKMS or precompiled modules. Secure Boot needs signed modules. |
| `nvidia-uvm.ko` | Unified Virtual Memory (CUDA managed memory, page faulting between CPU and GPU) | Required by CUDA. If it is missing, CUDA init fails even though `nvidia-smi` works. |
| `nvidia-peermem.ko` | Lets RDMA NICs DMA directly into GPU memory (GPUDirect RDMA) | Needed for multi-node NCCL over InfiniBand/RoCE. Depends on MOFED/DOCA-OFED. |
| `libcuda.so` (user-mode driver) | The CUDA *Driver API*; versioned with the kernel driver | **Must** match the kernel module version exactly, so it is injected from the host, never shipped in the image. |
| NVML / `libnvidia-ml.so` | Management library: telemetry, ECC, clocks, MIG config | Used by `nvidia-smi`, DCGM, the device plugin and dcgm-exporter. |
| Fabric Manager | Configures NVSwitch fabrics on HGX/DGX systems | On NVSwitch systems, CUDA apps fail with `system not yet initialized` if the service is not running or its version differs from the driver. |
| Persistence daemon (`nvidia-persistenced`) | Keeps driver state loaded when no client is attached | Avoids multi-second init latency and state loss between jobs. |

**Driver branches:** NVIDIA publishes **Production Branches (PB)** and **Long-Term Support Branches (LTSB)** for datacenter use, plus New Feature Branches. NVIDIA AI Enterprise pins specific branches. In production, standardize on one branch per fleet.

### 2.3 CUDA compatibility model (frequently tested)

| Concept | Rule |
|---|---|
| **Backward compatibility** | A newer driver runs applications built with an older CUDA toolkit. A 550-series driver runs CUDA 11.8 apps. |
| **Minor version compatibility** (CUDA 11+) | An app built with CUDA 12.x runs on any driver that supports CUDA 12.0 or later (≥ the minimum driver for that major release). Features that need a newer driver will error at call time. |
| **Forward compatibility** | The `cuda-compat` package lets a *newer* CUDA user-mode stack run on an *older* datacenter kernel driver. Supported only on datacenter GPUs and specific branch pairs. |
| **`nvidia-smi` "CUDA Version"** | This is the **maximum** CUDA version the installed driver supports. It is *not* the toolkit installed in the container. |
| **`nvcc --version`** | The toolkit version (compiler). Usually present only in `-devel` images. |

The practical rule: **the host driver must be at least as new as the container's CUDA major/minor needs.** The container never carries the kernel driver.

### 2.4 NVIDIA Container Toolkit

The toolkit solves this problem: *the container has the CUDA runtime, the host has the driver, and they must meet at runtime.*

- `nvidia-container-toolkit` / `nvidia-ctk`: configures the runtime (containerd, CRI-O, Docker, Podman).
- `libnvidia-container`: mounts device nodes (`/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-uvm`) and host driver libraries (`libcuda.so`, `libnvidia-ml.so`) into the container.
- **CDI (Container Device Interface):** A CNCF-standard JSON/YAML spec describing which devices, mounts and hooks a container needs. This is the modern path, and newer GPU Operator releases enable it by default.
- `NVIDIA_VISIBLE_DEVICES` / `NVIDIA_DRIVER_CAPABILITIES`: environment variables that select GPUs and capabilities (`compute`, `utility`, `video`, `graphics`).

| Injection mode | How it works | Trade-off |
|---|---|---|
| Legacy runtime hook (`nvidia-container-runtime` as OCI prestart hook) | Runtime wrapper rewrites the OCI spec | Works everywhere. Opaque. Tied to the NVIDIA runtime class. |
| CDI | Runtime reads `/etc/cdi/*.yaml` or `/var/run/cdi/*.yaml` and applies device edits | Runtime-agnostic and declarative. Needs containerd ≥ 1.7 / CRI-O / Podman with CDI support. |

### 2.5 CUDA-X libraries and Magnum IO

| Library | Purpose | Where it matters |
|---|---|---|
| cuBLAS / cuBLASLt | Dense linear algebra (GEMM) | Every transformer layer is mostly GEMMs. |
| cuDNN | Deep learning primitives (conv, attention, normalization) | Framework backend for training and inference. |
| NCCL | Collective communication (all-reduce, all-gather, reduce-scatter) | Multi-GPU and multi-node training. Topology-aware over NVLink, PCIe, IB and RoCE. |
| TensorRT | Inference optimizer and runtime (layer fusion, precision calibration FP16/INT8/FP8, kernel auto-tuning) | Low-latency inference. |
| TensorRT-LLM | LLM-specific inference (in-flight batching, paged KV cache, tensor/pipeline parallel) | Backend for NIM LLMs and Triton. |
| DALI | GPU-accelerated data loading and augmentation | Stops the CPU input pipeline from starving the GPU. |
| RAPIDS (cuDF, cuML, cuGraph) | GPU dataframes and ML (pandas/scikit-learn-like APIs) | ETL and classical ML on GPU. Spark RAPIDS Accelerator. |
| GPUDirect RDMA | NIC ↔ GPU memory without staging in host RAM | Multi-node training bandwidth and latency. |
| GPUDirect Storage (GDS, `cuFile`) | NVMe/NFS/parallel FS ↔ GPU memory directly | Checkpoint and dataset I/O. |
| NVSHMEM, UCX | PGAS and unified communication frameworks | HPC and some MoE workloads. |

**Magnum IO** is NVIDIA's umbrella name for the IO stack: NCCL, GPUDirect RDMA, GPUDirect Storage, NVSHMEM, UCX and the related management tools.

### 2.6 Frameworks, SDKs and application frameworks

- **NeMo:** end-to-end framework for building, customizing (SFT, LoRA/PEFT, RLHF/DPO), evaluating and guard-railing generative AI models. Includes NeMo Curator (data), NeMo Customizer, NeMo Evaluator, NeMo Guardrails and NeMo Retriever.
- **TAO Toolkit:** low-code transfer learning for vision and other models. Train on your data from pretrained models, then export to TensorRT.
- **Domain application frameworks:** Riva (speech ASR/TTS), Morpheus (cybersecurity pipelines), Clara (healthcare/genomics), Merlin (recommenders), Metropolis/DeepStream (video analytics), Isaac (robotics), cuOpt (routing optimization).

### 2.7 Serving layer

| | Triton Inference Server (now branded **Dynamo-Triton**) | NVIDIA NIM | NVIDIA Dynamo |
|---|---|---|---|
| What it is | General-purpose, multi-framework inference server | Prebuilt, optimized microservice per model (container), with an industry-standard API | Distributed inference framework for large-scale LLM serving |
| Model source | You bring models in a model repository | NVIDIA packages the model plus an optimized engine | You bring models; it orchestrates engines (TensorRT-LLM, vLLM, SGLang) |
| Backends | TensorRT, TensorRT-LLM, PyTorch (LibTorch), ONNX Runtime, OpenVINO, Python, vLLM | Internally TensorRT-LLM / vLLM / Triton, selected per GPU profile | TensorRT-LLM, vLLM, SGLang |
| API | KServe v2 HTTP/gRPC | OpenAI-compatible (`/v1/chat/completions`) for LLMs, domain APIs for others | OpenAI-compatible frontend |
| Key features | Dynamic batching, concurrent model execution, ensembles, model analyzer | Auto-selects an optimized profile for the detected GPU. Enterprise-supported. | Disaggregated prefill/decode, KV-cache-aware routing, KV cache offload |
| Best fit | Heterogeneous model zoo, custom pipelines | Fast, supported deployment of popular foundation models | Multi-node LLM inference at datacenter scale |

### 2.8 Operations and management layer

| Component | Purpose |
|---|---|
| **NGC catalog** (`nvcr.io`) | Registry of GPU-optimized containers, pretrained models, Helm charts and resources. Containers are monthly-versioned (e.g. `pytorch:24.10-py3`) and scanned. |
| **NVIDIA GPU Operator** | Kubernetes operator that deploys and manages the driver, container toolkit, device plugin, GPU Feature Discovery, DCGM exporter, MIG Manager, validator and (optionally) vGPU, GDS and KubeVirt components. Driven by the `ClusterPolicy` CRD. |
| **NVIDIA Network Operator** | Equivalent for networking: DOCA-OFED/MOFED driver, RDMA shared device plugin, SR-IOV device plugin, Multus/secondary networks, `nvidia-peermem`. Driven by the `NicClusterPolicy` CRD. |
| **DCGM** (Data Center GPU Manager) | Health checks, diagnostics (`dcgmi diag`), policy, telemetry. **dcgm-exporter** exposes Prometheus metrics. |
| **MIG** (Multi-Instance GPU) | Hardware partitioning of A100/A30/H100/H200/B200-class GPUs into up to 7 isolated instances, each with dedicated SMs, L2 slices and memory. |
| **Time-slicing** | Software oversubscription: multiple processes share one GPU in time. No memory or fault isolation. |
| **MPS** (Multi-Process Service) | Concurrent kernels from multiple processes on one GPU. Better utilization than time-slicing, limited isolation. |
| **NVIDIA vGPU** | Hypervisor-level GPU virtualization (VMware, KVM, etc.) for VMs. Licensed. |
| **Base Command Manager (BCM)** | Cluster provisioning and management for bare metal: OS images, Slurm or Kubernetes deployment, monitoring. Used for DGX SuperPOD/BasePOD. |
| **Run:ai** | Kubernetes-native GPU orchestration: fair-share scheduling, quotas, fractional GPUs, job queueing. |
| **Fleet Command** | Cloud-managed deployment and management of AI at the edge. |
| **NVIDIA AI Enterprise** | The licensed, supported software suite. It bundles the infrastructure layer (drivers, GPU/Network Operator, vGPU, Base Command Manager essentials), frameworks, NIM and NeMo. Production branches with security patches and API stability. |
| **DOCA** | SDK and runtime for BlueField DPUs and ConnectX NICs. Offloads networking, storage and security from the host CPU. |

---

## 3. Technical comparisons and trade-offs

### 3.1 Driver delivery model

| Option | Pros | Cons | Use when |
|---|---|---|---|
| Host-installed driver (package / `.run` / DKMS) | Simple. Driver survives operator removal. Works for Slurm and Kubernetes alike. | Kernel upgrades can break DKMS builds. Fleet drift. Node reimage needed to change version. | Bare-metal HPC, mixed Slurm/K8s, BCM-managed clusters. |
| GPU Operator containerized driver (`driver.enabled=true`) | Version declared in Git (ClusterPolicy). Rolling upgrades via the upgrade controller. No packages on the host. | Requires a matching precompiled or compilable kernel. Pod restarts on node reboot add boot latency. Harder debugging. | Kubernetes-only fleets, immutable OSes, cloud nodes. |
| Precompiled driver containers | No on-node compilation. Fast and deterministic. | Only for supported kernel/OS combinations. | Ubuntu LTS fleets with standard kernels. |
| Cloud-provider pre-installed (GKE/AKS/EKS images) | Zero effort. | Version is controlled by the provider, and conflicts with operator-managed drivers. | Managed Kubernetes. Set `driver.enabled=false`. |

### 3.2 GPU sharing strategies

| Strategy | Isolation (memory / fault / QoS) | Granularity | Supported GPUs | Kubernetes resource | Typical use |
|---|---|---|---|---|---|
| Whole GPU | Full | 1 GPU | All | `nvidia.com/gpu` | Training, large LLM inference |
| MIG | **Hardware**: dedicated memory, SMs, L2. Fault isolated. | Fixed profiles (e.g. `1g.10gb`, `3g.40gb`) | A100, A30, H100, H200, B200 (Ampere+ datacenter) | `nvidia.com/mig-1g.10gb` (mixed) or `nvidia.com/gpu` (single) | Multi-tenant inference, notebooks, guaranteed QoS |
| Time-slicing | **None**: shared memory, one fault can affect all | N replicas per GPU (logical) | All CUDA GPUs | `nvidia.com/gpu` (oversubscribed) or `nvidia.com/gpu.shared` | Dev, bursty low-utilization workloads |
| MPS | Partial: limits on SM % and memory are possible, but faults propagate | Fractional by limits | Volta+ | `nvidia.com/gpu` with MPS sharing config | Many small inference processes |
| vGPU | Hypervisor-level, scheduler-based | Profiles per VM | Datacenter GPUs with license | VM device | VDI, VM-based multi-tenancy |

### 3.3 Inference serving choice

| Requirement | Recommended |
|---|---|
| Deploy Llama/Mistral/Nemotron fast with support and an OpenAI-compatible API | **NIM** |
| Mixed CV + tabular + NLP models, ensembles, custom pre/post-processing | **Triton** |
| Multi-node LLM serving with disaggregated prefill/decode and KV-aware routing | **Dynamo** |
| Maximum single-model latency on a known GPU | **TensorRT / TensorRT-LLM** engine, served by Triton or NIM |

### 3.4 Cluster management

| | Base Command Manager | Kubernetes + GPU Operator | Run:ai on Kubernetes | Slurm |
|---|---|---|---|---|
| Scope | Bare-metal provisioning + workload manager setup | Container orchestration | GPU-aware scheduling layer | HPC batch scheduler |
| Strength | Day-0 provisioning of DGX/SuperPOD | Ecosystem, microservices, inference | Quotas, fair-share, fractional GPU | Gang scheduling, MPI, topology-aware |
| Weakness | Not a scheduler itself | Default scheduler lacks gang/fair-share | Additional licensed layer | Weak for long-running services |

---

## 4. Complete manifests and configuration

### 4.1 GPU Operator Helm values (production baseline)

This configuration assumes containerized drivers, CDI, a single-strategy MIG layout, DCGM metrics scraped by Prometheus Operator, and the driver upgrade controller enabled.

```yaml
# values-gpu-operator.yaml
# helm install gpu-operator nvidia/gpu-operator -n gpu-operator -f values-gpu-operator.yaml
operator:
  defaultRuntime: containerd
  upgradeCRD: true

cdi:
  enabled: true
  default: true

nfd:
  enabled: true

driver:
  enabled: true
  version: "550.127.08"
  usePrecompiled: false
  rdma:
    enabled: true
    useHostMofed: false
  upgradePolicy:
    autoUpgrade: true
    maxParallelUpgrades: 1
    maxUnavailable: "25%"
    podDeletion:
      force: false
      timeoutSeconds: 300
      deleteEmptyDir: false
    drain:
      enable: true
      force: false
      timeoutSeconds: 600
      deleteEmptyDir: true

toolkit:
  enabled: true

devicePlugin:
  enabled: true
  config:
    name: time-slicing-config
    default: any

gfd:
  enabled: true

mig:
  strategy: single

migManager:
  enabled: true
  config:
    name: default-mig-parted-config
    default: all-disabled

dcgm:
  enabled: false

dcgmExporter:
  enabled: true
  serviceMonitor:
    enabled: true
    interval: 15s
    honorLabels: false
    additionalLabels:
      release: kube-prometheus-stack

gds:
  enabled: false

validator:
  plugin:
    env:
      - name: WITH_WORKLOAD
        value: "true"

nodeStatusExporter:
  enabled: true

daemonsets:
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  priorityClassName: system-node-critical
```

> `dcgm.enabled: false` means dcgm-exporter uses its embedded DCGM host engine instead of a standalone DCGM DaemonSet. Enable the standalone engine when other DCGM clients (for example `dcgmi` health checks from a sidecar) must share it.

### 4.2 Time-slicing configuration for the device plugin

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
  dev-only: |-
    version: v1
    flags:
      migStrategy: none
    sharing:
      timeSlicing:
        renameByDefault: true
        failRequestsGreaterThanOne: true
        resources:
          - name: nvidia.com/gpu
            replicas: 8
```

Select a per-node config by labeling the node (`nvidia.com/device-plugin.config=dev-only`). With `renameByDefault: true`, the resource is advertised as `nvidia.com/gpu.shared`, so workloads explicitly opt into non-isolated sharing.

### 4.3 MIG layout via MIG Manager (custom profile)

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
      all-1g.10gb:
        - devices: all
          mig-enabled: true
          mig-devices:
            "1g.10gb": 7
      inference-mixed:
        - devices: [0, 1, 2, 3]
          mig-enabled: true
          mig-devices:
            "3g.40gb": 2
        - devices: [4, 5, 6, 7]
          mig-enabled: false
```

Apply a layout to a node with the label `nvidia.com/mig.config=all-1g.10gb`. MIG Manager drains GPU clients, reconfigures and sets `nvidia.com/mig.config.state=success`. The `1g.10gb` and `3g.40gb` profile names are for H100 80GB. A100 40GB uses `1g.5gb`, `3g.20gb`, and so on.

### 4.4 GPU validation workload

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cuda-vectoradd
  namespace: default
spec:
  restartPolicy: OnFailure
  runtimeClassName: nvidia
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  containers:
    - name: cuda-vectoradd
      image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0
      resources:
        limits:
          nvidia.com/gpu: 1
```

> With CDI as the default (`cdi.default: true`), `runtimeClassName` is optional. Keep it explicit if your cluster still has nodes on the legacy runtime.

### 4.5 NGC pull secret and NIM deployment (LLM microservice)

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: nim
---
apiVersion: v1
kind: Secret
metadata:
  name: ngc-api
  namespace: nim
type: Opaque
stringData:
  NGC_API_KEY: "REPLACE_WITH_NGC_API_KEY"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nim-cache
  namespace: nim
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi
  storageClassName: fast-ssd
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llama-3-1-8b-instruct
  namespace: nim
  labels:
    app: llama-3-1-8b-instruct
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: llama-3-1-8b-instruct
  template:
    metadata:
      labels:
        app: llama-3-1-8b-instruct
    spec:
      imagePullSecrets:
        - name: ngc-registry
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      containers:
        - name: nim
          image: nvcr.io/nim/meta/llama-3.1-8b-instruct:1.3.3
          ports:
            - name: http
              containerPort: 8000
          env:
            - name: NGC_API_KEY
              valueFrom:
                secretKeyRef:
                  name: ngc-api
                  key: NGC_API_KEY
            - name: NIM_CACHE_PATH
              value: /opt/nim/.cache
          resources:
            limits:
              nvidia.com/gpu: 1
              memory: 32Gi
            requests:
              cpu: "4"
              memory: 16Gi
          volumeMounts:
            - name: cache
              mountPath: /opt/nim/.cache
            - name: dshm
              mountPath: /dev/shm
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
            periodSeconds: 30
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
  name: llama-3-1-8b-instruct
  namespace: nim
spec:
  selector:
    app: llama-3-1-8b-instruct
  ports:
    - name: http
      port: 8000
      targetPort: http
```

The `ngc-registry` pull secret is created with the CLI (§5.4). Never commit a real key. Use External Secrets or Sealed Secrets. The startup probe allows 30 minutes because the first start downloads model weights and may build an engine.

### 4.6 Triton Inference Server with a model repository

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: triton
  namespace: inference
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
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8002"
    spec:
      imagePullSecrets:
        - name: ngc-registry
      containers:
        - name: triton
          image: nvcr.io/nvidia/tritonserver:24.10-py3
          args:
            - tritonserver
            - --model-repository=s3://models-bucket/triton-repo
            - --model-control-mode=poll
            - --repository-poll-secs=60
            - --strict-model-config=false
            - --log-verbose=0
          ports:
            - name: http
              containerPort: 8000
            - name: grpc
              containerPort: 8001
            - name: metrics
              containerPort: 8002
          envFrom:
            - secretRef:
                name: s3-credentials
          resources:
            limits:
              nvidia.com/gpu: 1
              memory: 24Gi
            requests:
              cpu: "4"
              memory: 16Gi
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
            - name: dshm
              mountPath: /dev/shm
      volumes:
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 8Gi
```

The matching `config.pbtxt` for a TensorRT model with dynamic batching. This is protobuf text format, not YAML:

```
name: "resnet50_trt"
platform: "tensorrt_plan"
max_batch_size: 64
input [
  {
    name: "input"
    data_type: TYPE_FP16
    dims: [ 3, 224, 224 ]
  }
]
output [
  {
    name: "output"
    data_type: TYPE_FP16
    dims: [ 1000 ]
  }
]
dynamic_batching {
  preferred_batch_size: [ 16, 32, 64 ]
  max_queue_delay_microseconds: 2000
}
instance_group [
  {
    count: 2
    kind: KIND_GPU
  }
]
```

### 4.7 DCGM alerting rules (Prometheus Operator)

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
        - alert: GPUXidErrorCritical
          expr: |
            max by (Hostname, gpu, UUID) (DCGM_FI_DEV_XID_ERRORS)
              > 0
            and on (Hostname, gpu, UUID)
            max by (Hostname, gpu, UUID) (DCGM_FI_DEV_XID_ERRORS) == 79
              or
            max by (Hostname, gpu, UUID) (DCGM_FI_DEV_XID_ERRORS) == 48
          for: 0m
          labels:
            severity: critical
          annotations:
            summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} reported XID {{ $value }}"
            runbook: "Cordon node, run dcgmi diag -r 3, check row remapping, RMA if persistent"
        - alert: GPUHighTemperature
          expr: |
            DCGM_FI_DEV_GPU_TEMP > 85
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} at {{ $value }}C"
        - alert: GPURowRemapFailure
          expr: |
            DCGM_FI_DEV_ROW_REMAP_FAILURE > 0
          for: 0m
          labels:
            severity: critical
          annotations:
            summary: "Row remapping failed on GPU {{ $labels.gpu }} ({{ $labels.Hostname }}); schedule RMA"
        - alert: GPUAllocatedButIdle
          expr: |
            avg_over_time(DCGM_FI_PROF_GR_ENGINE_ACTIVE{exported_pod!=""}[30m])
              < 0.05
          for: 30m
          labels:
            severity: info
          annotations:
            summary: "Pod {{ $labels.exported_namespace }}/{{ $labels.exported_pod }} holds a GPU below 5% engine activity"
        - alert: GPUNVLinkErrors
          expr: |
            rate(DCGM_FI_DEV_NVLINK_CRC_FLIT_ERROR_COUNT_TOTAL[5m])
              > 0
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "NVLink CRC errors increasing on {{ $labels.Hostname }} GPU {{ $labels.gpu }}"
```

> `DCGM_FI_DEV_XID_ERRORS` holds the value of the **last** XID seen, not a counter. That is why the rule compares values. `DCGM_FI_PROF_*` profiling metrics are more reliable than `DCGM_FI_DEV_GPU_UTIL`: GPU_UTIL only reports whether *any* kernel was running during the sample window. Profiling metrics may not be available on every GPU, and some are unavailable while MIG is enabled.

### 4.8 NCCL-enabled multi-node job environment (Network Operator in place)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nccl-allreduce-worker-0
  namespace: training
  annotations:
    k8s.v1.cni.cncf.io/networks: rdma-net-ib0
spec:
  restartPolicy: Never
  containers:
    - name: nccl-tests
      image: nvcr.io/nvidia/pytorch:24.10-py3
      command:
        - /bin/bash
        - -c
        - "sleep infinity"
      env:
        - name: NCCL_DEBUG
          value: INFO
        - name: NCCL_DEBUG_SUBSYS
          value: "INIT,NET"
        - name: NCCL_IB_HCA
          value: "mlx5"
        - name: NCCL_SOCKET_IFNAME
          value: "eth0"
      securityContext:
        capabilities:
          add:
            - IPC_LOCK
      resources:
        limits:
          nvidia.com/gpu: 8
          rdma/rdma_shared_device_a: 1
          memory: 512Gi
        requests:
          cpu: "64"
      volumeMounts:
        - name: dshm
          mountPath: /dev/shm
  volumes:
    - name: dshm
      emptyDir:
        medium: Memory
        sizeLimit: 128Gi
```

---

## 5. CLI commands and expected output

> Outputs are representative of typical H100 systems. Exact versions, bus IDs and counters will differ on your hardware.

### 5.1 Host-level driver verification

```
$ nvidia-smi
Wed Nov  6 10:14:22 2026
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 550.127.08             Driver Version: 550.127.08     CUDA Version: 12.4     |
|-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
|                                         |                        |               MIG M. |
|=========================================+========================+======================|
|   0  NVIDIA H100 80GB HBM3          On  |   00000000:18:00.0 Off |                    0 |
| N/A   34C    P0             72W /  700W |       1MiB /  81559MiB |      0%      Default |
|                                         |                        |             Disabled |
+-----------------------------------------+------------------------+----------------------+
|   1  NVIDIA H100 80GB HBM3          On  |   00000000:2A:00.0 Off |                    0 |
| N/A   33C    P0             70W /  700W |       1MiB /  81559MiB |      0%      Default |
|                                         |                        |             Disabled |
+-----------------------------------------+------------------------+----------------------+

+-----------------------------------------------------------------------------------------+
| Processes:                                                                              |
|  GPU   GI   CI        PID   Type   Process name                              GPU Memory |
|        ID   ID                                                               Usage      |
|=========================================================================================|
|  No running processes found                                                             |
+-----------------------------------------------------------------------------------------+
```

Points to read:

- `CUDA Version: 12.4` is the **maximum** CUDA version this driver supports.
- `Persistence-M On` means the persistence daemon is active.
- `Volatile Uncorr. ECC` should be `0`.
- `MIG M.` shows whether MIG mode is enabled.

```
$ nvidia-smi topo -m
        GPU0    GPU1    GPU2    GPU3    NIC0    NIC1    CPU Affinity    NUMA Affinity
GPU0     X      NV18    NV18    NV18    PXB     SYS     0-55            0
GPU1    NV18     X      NV18    NV18    PXB     SYS     0-55            0
GPU2    NV18    NV18     X      NV18    SYS     PXB     56-111          1
GPU3    NV18    NV18    NV18     X      SYS     PXB     56-111          1

Legend:
  X    = Self
  SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes
  PXB  = Connection traversing multiple PCIe bridges (without traversing the PCIe Host Bridge)
  NV#  = Connection traversing a bonded set of # NVLinks
```

`NV18` means 18 bonded NVLink links (NVSwitch-attached H100 SXM). `PXB` between a GPU and a NIC means they share a PCIe switch, which is the ideal GPUDirect RDMA path. `SYS` means traffic crosses the CPU interconnect.

```
$ lsmod | grep -E '^nvidia'
nvidia_uvm           4911104  0
nvidia_peermem         16384  0
nvidia_drm            118784  0
nvidia_modeset       1355776  1 nvidia_drm
nvidia              54308864  3 nvidia_uvm,nvidia_peermem,nvidia_modeset

$ systemctl is-active nvidia-fabricmanager nvidia-persistenced
active
active
```

```
$ nvidia-smi -q -d ECC,ROW_REMAPPER | grep -A3 -E 'Remapped Rows|Aggregate'
    Remapped Rows
        Correctable Error                 : 0
        Uncorrectable Error               : 0
        Pending                           : No
        Remapping Failure Occurred        : No
```

### 5.2 Container runtime integration

```
$ sudo nvidia-ctk runtime configure --runtime=containerd
INFO[0000] Loading config from /etc/containerd/config.toml
INFO[0000] Wrote updated config to /etc/containerd/config.toml
INFO[0000] It is recommended that containerd daemon be restarted.

$ sudo systemctl restart containerd

$ sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
INFO[0000] Using driver version 550.127.08
INFO[0000] Selecting /dev/nvidia0 as /dev/nvidia0
INFO[0000] Selecting /dev/nvidiactl as /dev/nvidiactl
INFO[0000] Selecting /dev/nvidia-uvm as /dev/nvidia-uvm
...
INFO[0000] Generated CDI spec with version 0.5.0

$ nvidia-ctk cdi list
INFO[0000] Found 3 CDI devices
nvidia.com/gpu=0
nvidia.com/gpu=1
nvidia.com/gpu=all

$ podman run --rm --device nvidia.com/gpu=all nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi -L
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-3f1a2c9e-6d1b-4b7e-9a0f-2c1d5e7b8a90)
GPU 1: NVIDIA H100 80GB HBM3 (UUID: GPU-8b2e4d1f-0c3a-4e9d-b1a7-5f6c2d9e0a12)
```

Docker equivalent with the legacy hook:

```
$ docker run --rm --gpus '"device=0"' nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi -L
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-3f1a2c9e-6d1b-4b7e-9a0f-2c1d5e7b8a90)
```

### 5.3 GPU Operator installation and verification

```
$ helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
"nvidia" has been added to your repositories
...Successfully got an update from the "nvidia" chart repository

$ kubectl create namespace gpu-operator
$ kubectl label --overwrite ns gpu-operator pod-security.kubernetes.io/enforce=privileged
$ kubectl apply -f time-slicing-config.yaml

$ helm install gpu-operator nvidia/gpu-operator -n gpu-operator \
    --version v24.9.0 -f values-gpu-operator.yaml --wait
NAME: gpu-operator
LAST DEPLOYED: Wed Nov  6 10:30:11 2026
NAMESPACE: gpu-operator
STATUS: deployed
REVISION: 1

$ kubectl get pods -n gpu-operator
NAME                                                          READY   STATUS      RESTARTS   AGE
gpu-feature-discovery-7xk2p                                   2/2     Running     0          6m
gpu-operator-6d8f9c7b5-qtl8m                                  1/1     Running     0          7m
gpu-operator-node-feature-discovery-gc-5c9b8d6f4-vb2rn        1/1     Running     0          7m
gpu-operator-node-feature-discovery-master-7f6d9b8c5-h4kzs    1/1     Running     0          7m
gpu-operator-node-feature-discovery-worker-9mlqx              1/1     Running     0          7m
nvidia-container-toolkit-daemonset-l2r8w                      1/1     Running     0          6m
nvidia-cuda-validator-z6p4d                                   0/1     Completed   0          4m
nvidia-dcgm-exporter-4nq7t                                    1/1     Running     0          6m
nvidia-device-plugin-daemonset-f8v2c                          2/2     Running     0          6m
nvidia-driver-daemonset-550.127.08-ubuntu22.04-kx9tr          1/1     Running     0          7m
nvidia-mig-manager-w5d7j                                      1/1     Running     0          5m
nvidia-operator-validator-p2m6n                               1/1     Running     0          6m

$ kubectl get clusterpolicy cluster-policy -o jsonpath='{.status.state}{"\n"}'
ready
```

The startup order is: NFD labels the node → driver DaemonSet → container toolkit → validator (driver, toolkit, CUDA, plugin) → device plugin / GFD / dcgm-exporter / MIG Manager. Each component waits on the validator's files in `/run/nvidia/validations/`.

```
$ kubectl get node gpu-node-01 -o json | jq '.status.allocatable | with_entries(select(.key|startswith("nvidia")))'
{
  "nvidia.com/gpu": "32"
}

$ kubectl get node gpu-node-01 --show-labels | tr ',' '\n' | grep -E 'nvidia.com/(gpu.product|gpu.count|gpu.replicas|cuda.driver.major|mig.strategy|gpu.sharing-strategy)'
nvidia.com/cuda.driver.major=550
nvidia.com/gpu.count=8
nvidia.com/gpu.product=NVIDIA-H100-80GB-HBM3-SHARED
nvidia.com/gpu.replicas=4
nvidia.com/gpu.sharing-strategy=time-slicing
nvidia.com/mig.strategy=single
```

8 physical GPUs × 4 time-slicing replicas = 32 allocatable. GFD appends `-SHARED` to the product label so workloads can avoid shared nodes by selecting on the label.

```
$ kubectl apply -f cuda-vectoradd.yaml && kubectl logs -f pod/cuda-vectoradd
[Vector addition of 50000 elements]
Copy input data from the host memory to the CUDA device
CUDA kernel launch with 196 blocks of 256 threads
Copy output data from the CUDA device to the host memory
Test PASSED
Done
```

### 5.4 NGC and NIM

```
$ kubectl create secret docker-registry ngc-registry -n nim \
    --docker-server=nvcr.io \
    --docker-username='$oauthtoken' \
    --docker-password="${NGC_API_KEY}"
secret/ngc-registry created

$ ngc registry image list nvcr.io/nim/meta/* --format_type csv | head -3
Name,Repository,Latest Tag,Image Size,Updated Date,Permission,Signed Tag?,Access Type,Associated Products
Llama-3.1-8b-instruct,nim/meta/llama-3.1-8b-instruct,1.3.3,...

$ kubectl apply -f nim-llama.yaml
$ kubectl -n nim logs deploy/llama-3-1-8b-instruct | grep -iE 'profile|ready|Uvicorn'
INFO ... Detected 1 compatible profile(s).
INFO ... Selected profile: ... (tensorrt_llm-h100-fp8-tp1-throughput)
INFO ... Model llama-3.1-8b-instruct loaded and ready
INFO:     Uvicorn running on http://0.0.0.0:8000 (Press CTRL+C to quit)

$ kubectl -n nim port-forward svc/llama-3-1-8b-instruct 8000:8000 &

$ curl -s localhost:8000/v1/models | jq -r '.data[].id'
meta/llama-3.1-8b-instruct

$ curl -s localhost:8000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"What does NCCL do?"}],"max_tokens":64}' \
    | jq -r '.choices[0].message.content'
NCCL (NVIDIA Collective Communications Library) implements multi-GPU and multi-node
collective operations such as all-reduce, all-gather and broadcast, optimized for
NVLink, PCIe and InfiniBand topologies...
```

NIM picks its optimized profile at startup based on the detected GPU (here TensorRT-LLM FP8, tensor parallel 1, throughput-optimized). To inspect what is available before deploying:

```
$ docker run --rm --gpus all -e NGC_API_KEY nvcr.io/nim/meta/llama-3.1-8b-instruct:1.3.3 list-model-profiles
```

### 5.5 Triton

```
$ curl -s localhost:8000/v2/health/ready -o /dev/null -w '%{http_code}\n'
200

$ curl -s localhost:8000/v2/models/resnet50_trt | jq '{name, platform, versions}'
{
  "name": "resnet50_trt",
  "platform": "tensorrt_plan",
  "versions": [
    "1"
  ]
}

$ curl -s localhost:8002/metrics | grep -E '^nv_inference_(request_success|queue_duration_us)' | head -2
nv_inference_request_success{model="resnet50_trt",version="1"} 18234
nv_inference_queue_duration_us{model="resnet50_trt",version="1"} 4120933
```

### 5.6 DCGM diagnostics

```
$ dcgmi discovery -l
2 GPUs found.
+--------+----------------------------------------------------------------------+
| GPU ID | Device Information                                                   |
+--------+----------------------------------------------------------------------+
| 0      | Name: NVIDIA H100 80GB HBM3                                          |
|        | PCI Bus ID: 00000000:18:00.0                                         |
|        | Device UUID: GPU-3f1a2c9e-6d1b-4b7e-9a0f-2c1d5e7b8a90                |
+--------+----------------------------------------------------------------------+
| 1      | Name: NVIDIA H100 80GB HBM3                                          |
|        | PCI Bus ID: 00000000:2A:00.0                                         |
|        | Device UUID: GPU-8b2e4d1f-0c3a-4e9d-b1a7-5f6c2d9e0a12                |
+--------+----------------------------------------------------------------------+

$ dcgmi diag -r 2
Successfully ran diagnostic for group.
+---------------------------+------------------------------------------------+
| Diagnostic                | Result                                         |
+===========================+================================================+
|-----  Metadata  ----------+------------------------------------------------|
| DCGM Version              | 3.3.8                                          |
| Driver Version Detected   | 550.127.08                                     |
| GPU Device IDs Detected   | 2330,2330                                      |
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

The three diagnostic levels:

| Level | Duration | Purpose |
|---|---|---|
| `-r 1` | Seconds | Deployment and software checks. Run in CI or node readiness. |
| `-r 2` | ~2 minutes | Adds PCIe and memory tests. Run before admitting a node. |
| `-r 3` / `-r 4` | 15 minutes to 1+ hour | Stress, targeted power, memory bandwidth. Burn-in, post-RMA, suspected hardware fault. |

```
$ kubectl -n gpu-operator exec ds/nvidia-dcgm-exporter -- curl -s localhost:9400/metrics | grep -E '^DCGM_FI_DEV_(GPU_TEMP|XID_ERRORS)' | head -2
DCGM_FI_DEV_GPU_TEMP{gpu="0",UUID="GPU-3f1a2c9e-...",device="nvidia0",modelName="NVIDIA H100 80GB HBM3",Hostname="gpu-node-01"} 34
DCGM_FI_DEV_XID_ERRORS{gpu="0",UUID="GPU-3f1a2c9e-...",device="nvidia0",modelName="NVIDIA H100 80GB HBM3",Hostname="gpu-node-01"} 0
```

### 5.7 MIG by hand (outside the operator)

```
$ sudo nvidia-smi -i 0 -mig 1
Enabled MIG Mode for GPU 00000000:18:00.0
All done.

$ sudo nvidia-smi mig -lgip -i 0 | grep -E '1g.10gb|3g.40gb|7g.80gb'
|   0  MIG 1g.10gb       19     7/7        9.75       No     16     1     0   |
|   0  MIG 3g.40gb        9     2/2        39.25      No     60     3     0   |
|   0  MIG 7g.80gb        0     1/1        79.25      No     132    7     0   |

$ sudo nvidia-smi mig -i 0 -cgi 9,9 -C
Successfully created GPU instance ID  2 on GPU  0 using profile MIG 3g.40gb (ID  9)
Successfully created compute instance ID  0 on GPU  0 GPU instance ID  2 using profile MIG 3g.40gb (ID  2)
Successfully created GPU instance ID  1 on GPU  0 using profile MIG 3g.40gb (ID  9)
Successfully created compute instance ID  0 on GPU  0 GPU instance ID  1 using profile MIG 3g.40gb (ID  2)

$ nvidia-smi -L
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-3f1a2c9e-6d1b-4b7e-9a0f-2c1d5e7b8a90)
  MIG 3g.40gb     Device  0: (UUID: MIG-5a1c...)
  MIG 3g.40gb     Device  1: (UUID: MIG-9e2b...)
```

> When the GPU Operator's MIG Manager is enabled, do **not** configure MIG by hand. It will reconcile back to the labeled config.

### 5.8 NCCL validation

```
$ all_reduce_perf -b 8 -e 8G -f 2 -g 8
# nThread 1 nGpus 8 minBytes 8 maxBytes 8589934592 step: 2(factor) warmup iters: 5 iters: 20
...
#       size         count      type   redop    root     time   algbw   busbw #wrong
#        (B)    (elements)                               (us)  (GB/s)  (GB/s)
  8589934592    2147483648     float     sum      -1    44210  194.30  340.03      0
# Avg bus bandwidth    : 162.4
```

On an NVSwitch-connected 8×H100 node, large-message busbw in the hundreds of GB/s is expected. Single-digit or tens of GB/s means NCCL fell back to PCIe or sockets. Check `NCCL_DEBUG=INFO`, specifically the lines `NCCL INFO Channel ... via P2P/NVLS` and `NET/IB` versus `NET/Socket`.

---

## 6. Verification and failure diagnosis

### 6.1 Layered troubleshooting procedure

Work **bottom-up**. A failure at layer N always shows up as a confusing symptom at layer N+2.

```
1. Hardware visible?        lspci -nn | grep -i nvidia
2. Kernel driver loaded?    lsmod | grep nvidia ; dmesg -T | grep -iE 'NVRM|Xid'
3. NVML works?              nvidia-smi
4. Fabric (NVSwitch)?       systemctl status nvidia-fabricmanager ; nvidia-smi -q | grep -A2 Fabric
5. CUDA works on host?      /usr/local/cuda/extras/demo_suite/deviceQuery (or a cuda-sample container)
6. Runtime injection?       nvidia-ctk cdi list ; container nvidia-smi
7. K8s advertises GPU?      kubectl describe node | grep -A5 Allocatable
8. Operator healthy?        kubectl get pods -n gpu-operator ; clusterpolicy status
9. Workload correct?        image CUDA version vs driver ; resource request ; tolerations
10. Performance?            DCGM profiling metrics, nvidia-smi topo -m, NCCL tests
```

### 6.2 Symptom → cause → fix

| Symptom | Probable cause | Diagnosis | Fix |
|---|---|---|---|
| `NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver` | Kernel module not loaded: Secure Boot rejected an unsigned module, `nouveau` is bound, or the kernel was upgraded without a DKMS rebuild | `dmesg \| grep -i nvidia`, `lsmod \| grep nouveau`, `mokutil --sb-state` | Blacklist nouveau. Sign modules or use precompiled signed drivers. Rebuild DKMS / use the operator driver container for the running kernel. |
| `CUDA driver version is insufficient for CUDA runtime version` | Container CUDA runtime is newer than the host driver supports | Compare `nvidia-smi` "CUDA Version" with the image tag (e.g. `cuda:12.6`) | Upgrade the driver branch, use an older image, or use `cuda-compat` (datacenter forward compatibility). |
| `CUDA error: system not yet initialized` (cudaErrorSystemNotReady) on HGX/DGX | Fabric Manager is not running, or its version differs from the driver | `systemctl status nvidia-fabricmanager`, `journalctl -u nvidia-fabricmanager` | Install a Fabric Manager that exactly matches the driver version. With the GPU Operator, the driver container runs it. |
| Pod `Pending`: `0/5 nodes are available: 5 Insufficient nvidia.com/gpu` | Device plugin not running, GPUs all allocated, node tainted, or MIG strategy mismatch | `kubectl describe node`, `kubectl -n gpu-operator logs ds/nvidia-device-plugin-daemonset` | Fix the plugin. With `mig.strategy=mixed`, request `nvidia.com/mig-1g.10gb`, not `nvidia.com/gpu`. Add tolerations. |
| Operator pods stuck in `Init:0/1` | Validator is waiting on the driver (driver container failing to build or load) | `kubectl -n gpu-operator logs <driver-pod> -c nvidia-driver-ctr` | Missing kernel headers or unsupported kernel. Use precompiled drivers, pin the kernel, or pre-install the driver on the host (`driver.enabled=false`). |
| Driver pod in CrashLoop on nodes with a host driver already installed | Two drivers are competing | `lsmod` on the node shows modules loaded before the operator | Choose one: uninstall the host driver, or set `driver.enabled=false`. |
| `Failed to initialize NVML: Unknown Error` inside a running container after some time | With cgroup v2 + systemd cgroup driver, a `systemctl daemon-reload` removed device access rules from the container's cgroup (legacy runtime mode) | Container worked at start, fails later. Correlate with daemon-reload in the journal. | Move to CDI mode. Update the container toolkit. Avoid daemon-reload on GPU nodes. |
| `nvidia-smi` works, but CUDA apps fail with `no CUDA-capable device is detected` | `nvidia-uvm` not loaded, or `/dev/nvidia-uvm` not injected | `ls -l /dev/nvidia-uvm*` | `modprobe nvidia-uvm` / `nvidia-modprobe -u -c=0`. Regenerate the CDI spec. |
| XID 79 in `dmesg` ("GPU has fallen off the bus") | PCIe/power/thermal hardware fault | `dmesg -T \| grep Xid`, BMC/SEL logs | Cordon and drain. Reset or reboot. If it recurs, RMA. |
| XID 48 (double-bit ECC), XID 63/64 (row remap pending/failure), XID 94/95 (contained/uncontained ECC) | HBM memory errors | `nvidia-smi -q -d ROW_REMAPPER,ECC` | Reset the GPU to apply pending remaps. On remap failure or uncontained errors, RMA. |
| XID 13 / 31 | Application fault (illegal instruction, MMU page fault) | Usually affects one process only | Debug the application with `compute-sanitizer`. Usually not hardware. |
| XID 74 | NVLink error | `nvidia-smi nvlink -s`, `nvidia-smi nvlink -e` | Check cabling/NVSwitch. Run Fabric Manager diagnostics. |
| NCCL all-reduce far below expected bandwidth | Falling back to sockets/PCIe: `nvidia-peermem` not loaded, wrong `NCCL_IB_HCA`, ACS enabled on PCIe switches, GPU–NIC NUMA mismatch | `NCCL_DEBUG=INFO` output, `nvidia-smi topo -m`, `lspci -vvv \| grep ACSCtl` | Load `nvidia-peermem` (Network Operator with `rdma.enabled`). Disable ACS on bare metal. Set HCA mapping. |
| `NCCL WARN ... unhandled system error` / `Bus error` in multi-GPU container | `/dev/shm` too small (Docker default is 64MB) | `df -h /dev/shm` in the container | Mount a Memory `emptyDir` on `/dev/shm`, or `--shm-size` / `--ipc=host`. |
| NIM pod restarts during startup | Liveness probe kills the pod while weights download or the engine builds; or out of memory/disk | `kubectl logs --previous` | Use a startup probe with a long threshold. Use a persistent cache PVC. Check the GPU profile is compatible. |
| NIM `401 Unauthorized` / `ImagePullBackOff` | Wrong NGC key or username | `kubectl describe pod` events | Username must be the literal `$oauthtoken`. The key must have NIM / AI Enterprise entitlement. |
| Time-slicing pods OOM-kill each other's CUDA contexts | Time-slicing has no memory isolation | `nvidia-smi` shows multiple processes filling memory | Use MIG for isolation, or enforce per-framework memory caps. Rename the resource to `.shared` so tenants opt in. |
| MIG config label applied but state stays `pending` / `failed` | GPU clients (dcgm-exporter, other pods) still hold the device; a reboot is required on some GPUs/platforms | `kubectl get node -L nvidia.com/mig.config.state`, MIG Manager logs | Let MIG Manager drain. Check `WITH_REBOOT` settings. Make sure no host process holds the GPU. |

### 6.3 Operator upgrade safety checklist

1. Read the GPU Operator and driver release notes and support matrices (OS, kernel, Kubernetes, container runtime).
2. Upgrade the CRDs first. Helm does not upgrade CRDs, so set `operator.upgradeCRD: true` or apply them manually.
3. Change `driver.version` in Git. The upgrade controller cordons, drains (with the configured `maxUnavailable`) and replaces the driver pods node by node.
4. Watch the per-node upgrade state label: `kubectl get nodes -L nvidia.com/gpu-driver-upgrade-state`.
5. Gate node readiness on the validator plus `dcgmi diag -r 1`/`-r 2` before reopening the node to workloads.

---

## 7. Exam focus points

- **Which layer runs where.** The kernel driver is always on the host. The CUDA runtime and libraries are in the container. The Container Toolkit bridges them.
- **`nvidia-smi` "CUDA Version"** is the driver's maximum supported CUDA version, not the installed toolkit.
- **GPU Operator** automates driver, container toolkit, device plugin, GFD, DCGM exporter, MIG Manager and validation on Kubernetes. The **Network Operator** does the equivalent for RDMA networking.
- **NGC** is the registry and catalog (containers, models, Helm charts). **NVIDIA AI Enterprise** is the licensed, supported software suite. **NIM** is a prebuilt, optimized inference microservice. **Triton** is a general-purpose multi-framework inference server. **TensorRT** is the optimizer/runtime. **NeMo** is for building and customizing generative AI. **RAPIDS** is GPU data science.
- **NCCL** handles multi-GPU collectives. **GPUDirect RDMA/Storage** are part of **Magnum IO**.
- **DCGM** is for GPU health, diagnostics and telemetry in the datacenter (not `nvidia-smi` loops).
- **MIG** gives hardware isolation. **Time-slicing** gives oversubscription without isolation. **vGPU** is for VMs.
- **Base Command Manager** is cluster provisioning/management. **Fleet Command** is edge deployment. **Run:ai** is GPU-aware scheduling and orchestration.

---

## Referencias

- NVIDIA-Certified Associate: AI Infrastructure and Operations — Exam Study Guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA AI Enterprise documentation: https://docs.nvidia.com/ai-enterprise/index.html
- NVIDIA GPU Operator documentation: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html
- GPU Operator — Time-slicing GPUs in Kubernetes: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-sharing.html
- GPU Operator — MIG support: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-operator-mig.html
- NVIDIA Network Operator documentation: https://docs.nvidia.com/networking/display/kubernetes2410/index.html
- NVIDIA Container Toolkit documentation: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/index.html
- Container Device Interface (CDI) support: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/cdi-support.html
- CUDA Compatibility guide: https://docs.nvidia.com/deploy/cuda-compatibility/index.html
- NVIDIA Data Center Drivers and branches: https://docs.nvidia.com/datacenter/tesla/index.html
- NVIDIA Fabric Manager user guide: https://docs.nvidia.com/datacenter/tesla/fabric-manager-user-guide/index.html
- XID errors reference: https://docs.nvidia.com/deploy/xid-errors/index.html
- NVIDIA DCGM documentation: https://docs.nvidia.com/datacenter/dcgm/latest/index.html
- DCGM Exporter: https://github.com/NVIDIA/dcgm-exporter
- Multi-Instance GPU user guide: https://docs.nvidia.com/datacenter/tesla/mig-user-guide/index.html
- NVIDIA Multi-Process Service: https://docs.nvidia.com/deploy/mps/index.html
- NVIDIA vGPU software documentation: https://docs.nvidia.com/vgpu/index.html
- NGC Catalog: https://catalog.ngc.nvidia.com/
- NGC user guide: https://docs.nvidia.com/ngc/gpu-cloud/ngc-user-guide/index.html
- NVIDIA NIM for LLMs documentation: https://docs.nvidia.com/nim/large-language-models/latest/introduction.html
- Triton Inference Server documentation: https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/index.html
- NVIDIA Dynamo: https://docs.nvidia.com/dynamo/latest/index.html
- TensorRT documentation: https://docs.nvidia.com/deeplearning/tensorrt/latest/index.html
- TensorRT-LLM documentation: https://nvidia.github.io/TensorRT-LLM/
- NCCL documentation: https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/index.html
- NCCL tests: https://github.com/NVIDIA/nccl-tests
- Magnum IO: https://developer.nvidia.com/magnum-io
- GPUDirect Storage documentation: https://docs.nvidia.com/gpudirect-storage/index.html
- CUDA-X libraries: https://developer.nvidia.com/gpu-accelerated-libraries
- NVIDIA NeMo Framework documentation: https://docs.nvidia.com/nemo-framework/user-guide/latest/overview.html
- RAPIDS: https://docs.rapids.ai/
- NVIDIA Base Command Manager documentation: https://docs.nvidia.com/base-command-manager/index.html
- NVIDIA Run:ai documentation: https://run-ai-docs.nvidia.com/
- NVIDIA Fleet Command: https://docs.nvidia.com/fleet-command/index.html
- NVIDIA DOCA documentation: https://docs.nvidia.com/doca/sdk/index.html