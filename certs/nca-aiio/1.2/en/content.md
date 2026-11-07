# 1.2 — Compare and Contrast Training and Inference Architecture Requirements and Considerations

> **Exam weight:** 4.75% · **Domain:** Essential AI Knowledge  
> **Target Audience:** Principal Platform Architects, AI Infrastructure Engineers, and Senior SREs  
> **Goal:** Master the architectural, computational, networking, storage, and orchestration dichotomies between AI distributed training and high-throughput/low-latency inference systems in production enterprise environments.

---

## 1. Production Architectural Motivation & Problem Statement

Designing infrastructure for modern Artificial Intelligence workloads requires navigating two diametrically opposed computational regimes: **Model Training** (including pre-training and fine-tuning) and **Model Inference** (serving and generation). Treating both workloads identically on a monolithic compute fabric results in catastrophic CAPEX waste, stranded GPU capacity, SLA violations, or training job collapse.

```
┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                   THE WORKLOAD DIVERGENCE                                       │
├─────────────────────────────────────────────────────────────────────────────────────────────────┤
│ DISTRIBUTED TRAINING CLUSTER (Scale-Out Throughput Fabric)                                      │
│                                                                                                 │
│  ┌────────────────────────┐  All-to-All Gradients (NCCL)  ┌────────────────────────┐            │
│  │  DGX H100 / B200 #1    │◄─────────────────────────────►│  DGX H100 / B200 #N    │            │
│  │  8x SXM GPUs           │   Dedicated Rail-Optimized    │  8x SXM GPUs           │            │
│  │  NVSwitch: 3.2 TB/s bi │   Quantum-2 IB / RoCEv2       │  NVSwitch: 3.2 TB/s bi │            │
│  └───────────┬────────────┘   (400G/800G per GPU)         └───────────┬────────────┘            │
│              │                                                        │                         │
│              ▼ GPUDirect Storage (GDS)                                ▼ GPUDirect Storage (GDS) │
│       ┌──────────────────────────────────────────────────────────────────────┐                  │
│       │ Parallel File System (Lustre / Weka / GPFS) - >2 TB/s Read / Writes  │                  │
│       └──────────────────────────────────────────────────────────────────────┘                  │
│   • Profile: Compute-bound GEMMs, synchronized gang execution, days-to-months runs              │
│   • Metric: Sustained Model Flops Utilization (MFU), Linear Scaling Efficiency                  │
├─────────────────────────────────────────────────────────────────────────────────────────────────┤
│ REAL-TIME INFERENCE CLUSTER (Scale-Across Service Fabric)                                       │
│                                                                                                 │
│            Ingress / Global API Gateway (Envoy / Cilium / Istio)                                │
│                                      │                                                          │
│              ┌───────────────────────┴───────────────────────┐                                  │
│              ▼ (Dynamic Request Routing & Token Streaming)   ▼                                  │
│  ┌───────────────────────────────┐               ┌───────────────────────────────┐              │
│  │ Worker Node (PCIe / L40S)     │               │ Worker Node (MIG Slices)      │              │
│  │ ┌───────────────────────────┐ │               │ ┌──────────────┬────────────┐ │              │
│  │ │ Triton / vLLM (TP=1)      │ │               │ │ Pod: 3g.40gb │Pod: 1g.20gb│ │              │
│  │ └───────────────────────────┘ │               │ └──────────────┴────────────┘ │              │
│  └───────────────────────────────┘               └───────────────────────────────┘              │
│   • Profile: Memory-bandwidth bound (Autoregressive KV Cache), asynchronous, ms-scale           │
│   • Metric: P99 Latency, TTFT (Time-To-First-Token), ITL (Inter-Token Latency), Token/s/$       │
└─────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### 1.1 The Operational Pitfalls of Workload Conflation

1. **Deploying Inference on Training-Class Hardware (Over-Provisioning Failure):**
   Deploying small-to-medium parameter inference models (e.g., 7B–14B LLMs, computer vision, embeddings) on dedicated 8-GPU SXM systems interconnected with 3.2 TB/s NVSwitch and 8x 400 Gb/s InfiniBand HCAs wastes non-recoverable capital. Inference requests arrive asynchronously; if the architecture cannot partition GPUs (via MIG or MPS) or if the interconnect remains 95% idle, operational costs explode while delivering sub-optimal ROI.

2. **Executing Distributed Training on Inference-Class Topology (Topology Collapse):**
   Training distributed Large Language Models across standard cloud nodes equipped with PCIe-bus GPUs and standard top-of-rack 25 GbE or 100 GbE shared networking triggers severe gradient synchronization stalls. In distributed Data Parallel (DDP) or Megatron-style Tensor/Pipeline/Sequence parallel training, the backward pass execution time becomes completely dominated by the inter-node `AllReduce` communication phase:
   $$\text{Step Time} = \max(\text{Compute}_{\text{backward}}, \text{Communication}_{\text{NCCL}}) + \text{Optimizer Step}$$
   On standard non-blocking fabrics without rail-optimization or GPUDirect RDMA, communication overhead dwarfs compute time, collapsing GPU utilization (MFU) from 50%+ down to single digits (<8%).

3. **Memory Profile Duality (Capacity & Compute vs. Memory Bandwidth):**
   - **Training:** Dominated by General Matrix Multiplications (GEMMs). The state encompasses weights, gradients, optimizer states (e.g., Adam states taking 16 bytes per parameter in FP32/BF16 mixed precision), and forward activations. Training is primarily **Compute-Bound** and **Capacity-Bound**.
   - **Inference (specifically Autoregressive LLM generation):** Decomposed into two phases:
     - *Prefill Phase:* Parallel compute across the entire prompt context. Compute-bound.
     - *Decode Phase:* Sequential, token-by-token generation. For each token generated, the model reads the entire set of weights from High Bandwidth Memory (HBM) into the streaming multiprocessors (SMs) along with the Key-Value (KV) cache. The decode phase has an arithmetic intensity of $\approx 1 \text{ FLOP} / \text{Byte}$, making it strictly **Memory-Bandwidth Bound**.

---

## 2. Technical Comparisons & Architectural Trade-Offs

The following matrix contrasts the architectural pillars across both domains:

| Architectural Vector | Distributed Training Architecture | Real-Time / Streaming Inference Architecture |
| :--- | :--- | :--- |
| **Primary Design Objective** | Maximizing throughput: Samples/sec, aggregate Model TFLOPS, minimizing epoch wall-clock time. | Minimizing latency & maximizing concurrency: Time-to-First-Token (TTFT), Inter-Token Latency (ITL), P99 end-to-end SLA. |
| **Job Lifecycle & Predictability** | Long-running batch execution (days to months). Monolithic state. Static resource reservation. | Ephemeral, stateless request-response or persistent duplex streaming sessions (gRPC/HTTP2). Highly elastic and diurnal. |
| **Numeric Precision Formats** | Mixed precision: FP32 (master weights, optimizer updates), BF16/FP16 (activations/gradients), FP8 (Transformer Engine). | Quantized low precision: FP8, INT8, INT4 (AWQ, GPTQ), SmoothQuant. Focus is on weight compression to fit within local HBM. |
| **System Form Factor** | SXM5 / OAM baseboards. Direct board-level liquid or high-airflow chassis (e.g., DGX H100, HGX H200, DGX GB200 NVL72). | PCIe add-in cards (L4, L40S, H100 NVL, A10G) or partitioned SXM units. Density and rack footprint optimized. |
| **Intra-Node Interconnect** | Ultra-high-bandwidth all-to-all NVLink (900 GB/s on H100, 1.8 TB/s on Blackwell) backed by dedicated NVSwitch chips. | PCIe Gen5 x16 (64 GB/s per direction, 128 GB/s bi-directional) or direct point-to-point NVLink bridge between dual GPU pairs (H100 NVL). |
| **Inter-Node Fabric** | Rail-optimized, non-blocking InfiniBand (Quantum-2 400 Gb/s / Quantum-X800) or lossless RoCEv2 (PFC + ECN). 1:1 GPU-to-HCA ratio. | Standard leaf-spine Datacenter Ethernet (25/100 GbE) for northbound ingress. Dedicated RoCE only if running multi-node Tensor Parallelism. |
| **Storage Subsystem & I/O** | High-concurrency parallel file system (Lustre, Weka, GPFS). GPUDirect Storage (GDS). Huge burst write I/O for checkpoints. | Local high-speed NVMe (PCIe Gen4/5) for model weight staging/caching; container image registries; lightweight S3/Blob backing. |
| **Hardware Partitioning** | None. Exclusive bare-metal GPU access. Full physical device allocation. | Multi-Instance GPU (MIG) for strict hardware QoS isolation, or Multi-Process Service (MPS) for memory and kernel interleaving. |
| **Kubernetes Controller** | Batch Gang Schedulers: `kueue.x-k8s.io`, Volcano `Job`, or Kubeflow `PyTorchJob`. All-or-nothing scheduling semantics. | Core `apps/v1` `Deployment`, `Rollout` (Argo), backed by KEDA (Kubernetes Event-driven Autoscaling) via Prometheus metrics. |
| **Resilience & Failure Recovery** | Catastrophic failure domain: If 1 GPU dies in an 8,192-GPU job, the entire job halts and resumes from the last valid checkpoint. | Isolated failure domain: Individual pod termination simply removes an endpoint from the Service / Ingress load-balancer pool. |

---

## 3. Production-Grade Manifests & Infrastructure Specs

### 3.1 Distributed Training: Kubeflow PyTorchJob with Multi-Rail RDMA and Gang Scheduling

In a production Kubernetes cluster managed by the NVIDIA GPU Operator and Network Operator, a multi-node distributed training workload must **never** be deployed as a standard Kubernetes `apps/v1 Deployment`. Deployments enforce independent pod lifecycle management without all-or-nothing gang scheduling; if cluster GPU capacity is partially constrained, a Deployment will schedule only a subset of workers, deadlocking the PyTorch collective while holding GPU quota indefinitely.

Production distributed training uses batch controllers such as the Kubeflow Training Operator (`kubeflow.org/v1 PyTorchJob`), JobSet, or Volcano, integrated with **Kueue** for gang scheduling (`kueue.x-k8s.io/queue-name`):

- **All-or-Nothing Gang Scheduling:** Guarantees that either all $N$ workers schedule simultaneously or none do, avoiding quota deadlocks.
- **Multi-Rail RDMA Binding:** Binds each GPU to its dedicated Mellanox ConnectX-7 HCA (`rdma/hca_shared_devices` or SR-IOV device plugins) with GPUDirect RDMA.
- **Shared Memory Injection:** Mounts high-speed RAM-backed `/dev/shm` to prevent PyTorch DataLoader multi-processing deadlocks.
- **Rail-Aligned Node Affinity:** Guarantees co-location across identical InfiniBand spine-leaf rail switches.

```yaml
apiVersion: kubeflow.org/v1
kind: PyTorchJob
metadata:
  name: nccl-multinode-training
  namespace: ml-training
  labels:
    kueue.x-k8s.io/queue-name: "training-queue"
spec:
  pytorchReplicaSpecs:
    Master:
      replicas: 1
      restartPolicy: OnFailure
      template:
        metadata:
          labels:
            app.kubernetes.io/name: "distributed-trainer"
            app.kubernetes.io/component: "master"
        spec:
          hostNetwork: true
          hostIPC: true
          dnsPolicy: ClusterFirstWithHostNet
          containers:
            - name: pytorch
              image: "nvcr.io/nvidia/pytorch:24.07-py3"
              imagePullPolicy: IfNotPresent
              command:
                - "/bin/bash"
                - "-c"
                - |
                  export OMP_NUM_THREADS=8
                  export NCCL_DEBUG=INFO
                  export NCCL_DEBUG_SUBSYS=INIT,ENV,COLL
                  export NCCL_IB_DISABLE=0
                  export NCCL_IB_HCA=mlx5_0,mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7
                  export NCCL_IB_GID_INDEX=3
                  export NCCL_IB_TC=106
                  export NCCL_IB_SL=0
                  export NCCL_NET_GDR_LEVEL=5
                  
                  python3 -m torch.distributed.run \
                    --nproc_per_node=8 \
                    /workspace/pretrain.py --config /configs/h100-parallel.yaml
              volumeMounts:
                - name: dshm
                  mountPath: "/dev/shm"
                - name: persistent-dataset-gds
                  mountPath: "/dataset"
                - name: checkpoints-storage
                  mountPath: "/checkpoints"
              resources:
                requests:
                  nvidia.com/gpu: "8"
                  rdma/hca_shared_devices: "8"
                  cpu: "112"
                  memory: "850Gi"
                limits:
                  nvidia.com/gpu: "8"
                  rdma/hca_shared_devices: "8"
                  cpu: "112"
                  memory: "850Gi"
          volumes:
            - name: dshm
              emptyDir:
                medium: Memory
                sizeLimit: "256Gi"
            - name: persistent-dataset-gds
              persistentVolumeClaim:
                claimName: "weka-fs-dataset-pvc"
            - name: checkpoints-storage
              persistentVolumeClaim:
                claimName: "weka-fs-checkpoints-pvc"
    Worker:
      replicas: 1
      restartPolicy: OnFailure
      template:
        metadata:
          labels:
            app.kubernetes.io/name: "distributed-trainer"
            app.kubernetes.io/component: "worker"
        spec:
          hostNetwork: true
          hostIPC: true
          dnsPolicy: ClusterFirstWithHostNet
          containers:
            - name: pytorch
              image: "nvcr.io/nvidia/pytorch:24.07-py3"
              imagePullPolicy: IfNotPresent
              command:
                - "/bin/bash"
                - "-c"
                - |
                  export OMP_NUM_THREADS=8
                  export NCCL_DEBUG=INFO
                  export NCCL_DEBUG_SUBSYS=INIT,ENV,COLL
                  export NCCL_IB_DISABLE=0
                  export NCCL_IB_HCA=mlx5_0,mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7
                  export NCCL_IB_GID_INDEX=3
                  export NCCL_IB_TC=106
                  export NCCL_IB_SL=0
                  export NCCL_NET_GDR_LEVEL=5
                  
                  python3 -m torch.distributed.run \
                    --nproc_per_node=8 \
                    /workspace/pretrain.py --config /configs/h100-parallel.yaml
              volumeMounts:
                - name: dshm
                  mountPath: "/dev/shm"
                - name: persistent-dataset-gds
                  mountPath: "/dataset"
                - name: checkpoints-storage
                  mountPath: "/checkpoints"
              resources:
                requests:
                  nvidia.com/gpu: "8"
                  rdma/hca_shared_devices: "8"
                  cpu: "112"
                  memory: "850Gi"
                limits:
                  nvidia.com/gpu: "8"
                  rdma/hca_shared_devices: "8"
                  cpu: "112"
                  memory: "850Gi"
          volumes:
            - name: dshm
              emptyDir:
                medium: Memory
                sizeLimit: "256Gi"
            - name: persistent-dataset-gds
              persistentVolumeClaim:
                claimName: "weka-fs-dataset-pvc"
            - name: checkpoints-storage
              persistentVolumeClaim:
                claimName: "weka-fs-checkpoints-pvc"
```

---

### 3.2 Real-Time Inference: Triton Inference Server with Multi-Instance GPU (MIG) Partitioning & KEDA Autoscaler

Inference requires microservice isolation, sub-second liveness/readiness reporting, and request-metric-driven autoscaling.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: triton-mig-inference
  namespace: ml-inference
  labels:
    app.kubernetes.io/name: "triton-server"
    app.kubernetes.io/component: "inference"
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: "triton-server"
  template:
    metadata:
      labels:
        app.kubernetes.io/name: "triton-server"
        app.kubernetes.io/component: "inference"
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8002"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: triton-server
          image: "nvcr.io/nvidia/tritonserver:24.07-py3"
          imagePullPolicy: IfNotPresent
          args:
            - "tritonserver"
            - "--model-repository=/models"
            - "--model-control-mode=poll"
            - "--repository-poll-secs=30"
            - "--strict-model-config=true"
            - "--log-verbose=0"
          ports:
            - containerPort: 8000
              name: "http"
            - containerPort: 8001
              name: "grpc"
            - containerPort: 8002
              name: "metrics"
          livenessProbe:
            httpGet:
              path: "/v2/health/live"
              port: 8000
            initialDelaySeconds: 15
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: "/v2/health/ready"
              port: 8000
            initialDelaySeconds: 30
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 2
          resources:
            requests:
              nvidia.com/mig-3g.40gb: "1"
              cpu: "8"
              memory: "32Gi"
            limits:
              nvidia.com/mig-3g.40gb: "1"
              cpu: "8"
              memory: "32Gi"
          volumeMounts:
            - name: model-repository-volume
              mountPath: "/models"
              readOnly: true
      volumes:
        - name: model-repository-volume
          persistentVolumeClaim:
            claimName: "model-cache-nvme-pvc"
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: triton-inference-autoscaler
  namespace: ml-inference
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: triton-mig-inference
  minReplicaCount: 2
  maxReplicaCount: 16
  cooldownPeriod: 300
  pollingInterval: 15
  triggers:
    - type: prometheus
      metadata:
        serverAddress: "http://prometheus-k8s.monitoring.svc.cluster.local:9090"
        metricName: "nv_inference_queue_duration_us"
        query: |
          sum(rate(nv_inference_queue_duration_us{namespace="ml-inference"}[1m]))
          /
          sum(rate(nv_inference_request_success{namespace="ml-inference"}[1m]))
        threshold: "20000"
```

---

## 4. CLI Inspection, Hardware Topology & Real Terminal Outputs

Operating production AI clusters requires platform engineers to validate underlying physical layouts, verify NUMA and PCIe mapping, and partition hardware slices.

### 4.1 Topology Validation: SXM Training Fabric vs. PCIe Inference Host

Training requires full NVLink mesh topology without crossing the host PCIe root complex:

```bash
$ nvidia-smi topo -m
```

```
        GPU0    GPU1    GPU2    GPU3    GPU4    GPU5    GPU6    GPU7    mlx5_0  NIC0    CPU Aff. NUMA Aff.
GPU0     X      NV18    NV18    NV18    NV18    NV18    NV18    NV18    NODE    SYS     0-55     0
GPU1    NV18     X      NV18    NV18    NV18    NV18    NV18    NV18    NODE    SYS     0-55     0
GPU2    NV18    NV18     X      NV18    NV18    NV18    NV18    NV18    NODE    SYS     0-55     0
GPU3    NV18    NV18    NV18     X      NV18    NV18    NV18    NV18    NODE    SYS     0-55     0
GPU4    NV18    NV18    NV18    NV18     X      NV18    NV18    NV18    SYS     NODE    56-111   1
GPU5    NV18    NV18    NV18    NV18    NV18     X      NV18    NV18    SYS     NODE    56-111   1
GPU6    NV18    NV18    NV18    NV18    NV18    NV18     X      NV18    SYS     NODE    56-111   1
GPU7    NV18    NV18    NV18    NV18    NV18    NV18    NV18     X      SYS     NODE    56-111   1
mlx5_0  NODE    NODE    NODE    NODE    SYS     SYS     SYS     SYS      X      SYS
NIC0    SYS     SYS     SYS     SYS     NODE    NODE    NODE    NODE    SYS      X

Legend:
  X    = Self
  NV18 = Connection traversing 18 NVLinks (NVSwitch connected)
  NODE = Connection traversing PCIe as well as the interconnect between PCIe Host Bridges within a NUMA node
  SYS  = Connection traversing PCIe as well as the interconnect between NUMA nodes (e.g., UPI/QPI)
```

In contrast, inspecting an inference server equipped with dual PCIe GPUs shows the bandwidth ceiling imposed by the PCIe switch and CPU sockets:

```bash
$ nvidia-smi topo -m
```

```
        GPU0    GPU1    mlx5_0  CPU Aff. NUMA Aff.
GPU0     X      SYS     NODE    0-31     0
GPU1    SYS      X      SYS     32-63    1
mlx5_0  NODE    SYS      X

Legend:
  X    = Self
  SYS  = Connection traversing inter-socket CPU interconnect (UPI link: ~32 GB/s bottleneck)
  NODE = Connection traversing local PCIe Gen5 root complex
```

---

### 4.2 Slicing Inference Workloads with Multi-Instance GPU (MIG)

For inference, a single 80 GB H100 can be partitioned into physically isolated compute and memory instances. Each partition possesses dedicated crossbar paths, memory controllers, and SM clusters.

```bash
$ sudo nvidia-smi -i 0 -mig 1
Enabled MIG Mode for GPU 00000000:1B:00.0
All done.

$ sudo nvidia-smi mig -lgip
+-----------------------------------------------------------------------------+
| GPU instances profiles:                                                     |
| GPU   GI ID   Profile ID   Profile Name                   Instances         |
|                                                           Free/Total        |
|=============================================================================|
|   0       0           19   MIG 1g.10gb                            7/7       |
|   0       1           14   MIG 2g.20gb                            3/3       |
|   0       2            9   MIG 3g.40gb                            2/2       |
|   0       3            5   MIG 4g.40gb                            1/1       |
|   0       4            0   MIG 7g.80gb                            1/1       |
+-----------------------------------------------------------------------------+

$ sudo nvidia-smi mig -cgi 9,9 -C
Successfully created GPU instance ID  1 on GPU  0 using profile 3g.40gb (ID  9)
Successfully created compute instance ID  0 on GPU  0, GPU instance ID  1
Successfully created GPU instance ID  2 on GPU  0 using profile 3g.40gb (ID  9)
Successfully created compute instance ID  0 on GPU  0, GPU instance ID  2

$ nvidia-smi
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 550.90.07              Driver Version: 550.90.07      CUDA Version: 12.4     |
|-----------------------------------+------------------------+----------------------------+
| GPU  Name        Persistence-M    | Bus-Id          Disp.A | Volatile Uncorr. ECC       |
| Fan  Temp  Perf          Pwr:Usage/Cap | Memory-Usage           | GPU-Util  Compute M.       |
|                                   |                        |               MIG M.       |
|===================================+========================+============================|
|   0  NVIDIA H100 80GB HBM3   On   | 00000000:1B:00.0   Off |                    0       |
| N/A   38C    P0             85W / 700W |    140MiB / 81559MiB   |     0%        Default      |
|                                   |                        |                  Enabled   |
+-----------------------------------+------------------------+----------------------------+
| MIG devices:                                                                            |
+------------------+----------------------+-----------+-----------------------------------+
| GPU  GI  CI  MIG |         Memory-Usage |        GPU|                   Shared Proc     |
|      ID  ID  Dev |                      |    Util.  |                     Active        |
|==================+======================+===========+===================================|
|   0   1   0    0 |         70MiB / 40192MiB |      0%   |                         No        |
|   0   2   0    1 |         70MiB / 40192MiB |      0%   |                         No        |
+------------------+----------------------+-----------+-----------------------------------+
```

---

### 4.3 Training Interconnect Verification: InfiniBand Interface and NCCL Bandwidth

Verifying the InfiniBand physical state and link rate on a training node:

```bash
$ ibstat | grep -E "(CA '|State|Link speed)"
```

```
CA 'mlx5_0'
        State: Active
        Physical state: LinkUp
        Link speed: 400 Gbps - NDR
CA 'mlx5_1'
        State: Active
        Physical state: LinkUp
        Link speed: 400 Gbps - NDR
CA 'mlx5_2'
        State: Active
        Physical state: LinkUp
        Link speed: 400 Gbps - NDR
CA 'mlx5_3'
        State: Active
        Physical state: LinkUp
        Link speed: 400 Gbps - NDR
```

Benchmarking inter-node all-reduce bus bandwidth using `nccl-tests` to ensure the communication fabric does not choke training throughput:

```bash
$ mpirun -np 16 \
  -H node-01:8,node-02:8 \
  --bind-to numa \
  -x NCCL_DEBUG=WARN \
  -x NCCL_IB_DISABLE=0 \
  -x NCCL_NET_GDR_LEVEL=5 \
  /opt/nccl-tests/build/all_reduce_perf -b 512M -e 4G -f 2 -g 1
```

```
#                                           out-of-place                       
#       size         count      type   op    time  algbw  busbw #wrong
#        (B)    (elements)                  (us) (GB/s) (GB/s)
  536870912     134217728     float  sum  1510.4 355.45 333.23      0
 1073741824     268435456     float  sum  2952.1 363.72 341.00      0
 2147483648     536870912     float  sum  5798.2 370.37 347.22      0
 4294967296    1073741824     float  sum 11520.8 372.80 349.50      0
# Out of bounds values : 0 OK
# Avg bus bandwidth    : 342.737 GB/s
```

*Architectural insight:* An average bus bandwidth of $\approx 343\text{ GB/s}$ over an 8-channel 400 Gb/s NDR fabric demonstrates effective GPUDirect RDMA. If the rate drops below $50\text{ GB/s}$, the training cluster has dropped out of RDMA into kernel TCP emulation.

---

### 4.4 Inference Benchmark: Profiling P99 Latency and Saturation

Profiling a deployed inference endpoint using `perf_analyzer` to capture latency distribution and concurrency cliffs:

```bash
$ perf_analyzer -m ensemble_llm -u triton.ml-inference.svc.cluster.local:8001 \
  -i grpc \
  --concurrency-range 1:16:4 \
  --percentile=99 \
  --measurement-mode=time_windows \
  --measurement-interval=10000
```

```
Successfully read data for 1 stream/sequences
Request concurrency: 1
  Client: 
    Request count: 1250 requests
    Throughput: 125.0 infer/sec
    p99 latency: 9410 usec
  Server: 
    Inference count: 1250
    Execution count: 1250
    Successful request count: 1250
    Avg request latency: 7812 usec (overhead 12 usec + queue 240 usec + compute input 15 usec + compute infer 7510 usec + compute output 35 usec)

Request concurrency: 9
  Client: 
    Request count: 4890 requests
    Throughput: 489.0 infer/sec
    p99 latency: 28450 usec
  Server: 
    Inference count: 4890
    Execution count: 611
    Successful request count: 4890
    Avg request latency: 17890 usec (overhead 18 usec + queue 9820 usec + compute input 42 usec + compute infer 7940 usec + compute output 70 usec)

Inferences/Second vs. Client p99 Latency
Concurrency 1: 125.0 infer/sec, p99 = 9.41 ms
Concurrency 5: 310.2 infer/sec, p99 = 16.82 ms
Concurrency 9: 489.0 infer/sec, p99 = 28.45 ms (Queue saturation begins)
Concurrency 13: 512.4 infer/sec, p99 = 62.10 ms (Latency SLA breach: >50ms)
```

---

## 5. Verification, Failure Modes & SRE Diagnostic Runbook

```
                                 FAILURE TRIAGE MATRIX
                                           │
             ┌─────────────────────────────┴─────────────────────────────┐
             ▼                                                           ▼
     TRAINING ANOMALY                                            INFERENCE ANOMALY
             │                                                           │
   ┌─────────┴─────────┐                                       ┌─────────┴─────────┐
   ▼                   ▼                                       ▼                   ▼
Straggler Node     NCCL Drop to TCP                       P99 Latency Spike   MIG Slicing Error
(Thermal / ECC)   (GDR disabled/RoCE)                    (KV-Cache / NUMA)   (CDI / Operator)
```

### 5.1 Case Study: The "Straggler Node" in Distributed Training

- **Symptom:** The global cluster step time suddenly drops from 400ms to 2800ms across 256 nodes. `nvidia-smi` shows 7 nodes sitting at 100% GPU utilization while 249 nodes show 5% GPU utilization.
- **Root Cause:** In synchronous SGD (Data Parallelism), an `AllReduce` operation requires every single participant to deposit its gradient tensor before any node can advance. A single degraded GPU, running at a lower core clock due to thermal throttling or uncorrectable PCIe/NVLink retries, stalls the entire 2,048-GPU collective.
- **Diagnosis & Remediation:**

```bash
# Step 1: Detect thermal or power throttling across all GPUs in the node
$ nvidia-smi --query-gpu=index,temperature.gpu,clocks.current.graphics,clocks_event_reasons.active --format=csv

index, temperature.gpu, clocks.current.graphics [MHz], clocks_event_reasons.active
0, 42, 1980 MHz, 0x0000000000000000
1, 41, 1980 MHz, 0x0000000000000000
2, 88, 1020 MHz, 0x0000000000000048  <-- THERMAL / HW SLOWDOWN DETECTED (0x40 HW Thermal + 0x08 HW Slowdown)
3, 43, 1980 MHz, 0x0000000000000000

# Step 2: Check for uncorrectable ECC errors in memory
$ nvidia-smi --query-gpu=index,ecc.errors.uncorrected.volatile.total --format=csv

index, ecc.errors.uncorrected.volatile.total
0, 0
1, 0
2, 4  <-- HARDWARE PAGE RETIREMENT FAILURE
3, 0

# Step 3: Evict node from Kubernetes cluster
$ kubectl cordon node-dgx-h100-34
$ kubectl drain node-dgx-h100-34 --ignore-daemonsets --delete-emptydir-data --force
```

---

### 5.2 Case Study: NCCL Silently Falling Back to Host Memory and TCP

- **Symptom:** Multi-node distributed training runs without explicit crashes, but scaling efficiency drops by 85%. Model step time increases linearly with node count.
- **Root Cause:** The `nvidia-peermem` kernel module is not loaded or has failed initialization due to a driver/MOFED mismatch. Without `nvidia-peermem`, GPUDirect RDMA is disabled, forcing GPU memory to be copied to system RAM, traversed through the host network stack via TCP sockets, and copied back into remote GPU memory.
- **Diagnosis & Remediation:**

```bash
# Step 1: Verify nvidia-peermem module presence
$ lsmod | grep nvidia_peermem
# If empty, GPUDirect RDMA between GPU and InfiniBand is completely dead!

# Step 2: Load module dynamically and check dmesg for symbol binding
$ sudo modprobe nvidia-peermem
$ dmesg | grep -i peermem
[ 4210.124512] nvidia_peermem: loading out-of-tree module
[ 4210.125901] nvidia_peermem: registered client nvidia-peermem with ib_peer_mem

# Step 3: Verify NCCL debug logs in the training pod
$ kubectl logs pod/nccl-multinode-training-master-0 | grep -E "(NET/IB|GDR)"
# Expected Output (GPUDirect RDMA active):
# [0] NCCL INFO NET/IB : Using [0]mlx5_0:1/IB [1]mlx5_1:1/IB ; OOB ib0:10.240.0.10<0>
# [0] NCCL INFO NET/IB : GPU Direct RDMA Enabled for HCA [0]mlx5_0:1
# Bad Output (Disabled / kernel module missing):
# [0] NCCL INFO NET/IB : GPU Direct RDMA Disabled for HCA 0 'mlx5_0' (no module)
```

---

### 5.3 Case Study: Tail Latency Spikes in Inference Under Concurrent Streaming

- **Symptom:** P50 inference latency is within the 15ms target, but P99 latency spikes above 800ms. Clients experience timeouts during token streaming.
- **Root Cause:**
  1. **KV Cache Fragmentation:** Under dynamic, variable-length prompt input, standard memory allocators fragment HBM, causing out-of-memory exceptions or expensive memory compaction pauses.
  2. **NUMA Inter-Socket Thrashing:** The inference server process is pinned to CPU Socket 0, but the GPU and incoming 100 GbE network card are physically attached to the PCIe root complex of CPU Socket 1. Every incoming packet and host-to-device memory copy must traverse the high-latency UPI/QPI inter-socket bus.
- **Diagnosis & Remediation:**

```bash
# Step 1: Detect NUMA socket affinity mismatch
$ lspci -s 1b:00.0 -v | grep NUMA
        Flags: bus master, fast devsel, latency 0, NUMA node 1

# Step 2: Check where the inference process threads are running
$ ps -eo pid,cmd,psr | grep tritonserver
  41203 tritonserver --model-reposi   0  <-- RUNNING ON CORE 0 (NUMA NODE 0)
  41204 tritonserver --model-reposi   1  <-- RUNNING ON CORE 1 (NUMA NODE 0)

# Step 3: Pin the workload correctly via numactl or Kubernetes CPU Manager
$ numactl --cpunodebind=1 --membind=1 tritonserver --model-repository=/models
```

---

## 6. SRE Operational Verification Commands

The following runbook table contains critical CLI utilities required to validate whether a host is provisioned correctly for Training vs. Inference:

| Operational Check | Command Line | Pass Criteria | Architectural Implication |
| :--- | :--- | :--- | :--- |
| **Fabric Manager Service** | `systemctl status nvidia-fabricmanager` | `Active: active (running)` | Mandatory on NVSwitch (SXM) architectures. If dead, training fails instantly with CUDA initialization errors. |
| **GPUDirect Storage (GDS)** | `/usr/local/cuda/gds/tools/gdscheck -p` | `NVFS driver status: Available` | Confirms direct DMA between NVMe parallel storage and GPU memory, bypassing CPU cache during dataset loading. |
| **PCIe Link Speed & Width** | `nvidia-smi --query-gpu=gpu_name,pcie.link.gen.current,pcie.link.width.current --format=csv` | `Gen 5, 16x` | Prevents fallback to Gen 3 or 8x lanes due to seated socket dust or motherboard bus degradation. |
| **ECC Page Retirement Count** | `nvidia-smi --query-gpu=retired_pages.pending,retired_pages.double_bit.count --format=csv` | `0, 0` | If pending retirements > 0, host must be rebooted or drained. Degraded memory triggers mid-epoch training panics. |
| **Persistence Mode** | `nvidia-smi -pm 1` | `Enabled` | Prevents driver teardown and multi-second CUDA context reload latency between inference requests. |

---

## 7. References

- NVIDIA AI Infrastructure Reference Architecture:  
  https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA DGX SuperPOD with H100 Systems Architecture Guide:  
  https://docs.nvidia.com/
- NVIDIA Multi-Instance GPU (MIG) User Guide:  
  https://docs.nvidia.com/datacenter/tesla/mig-user-guide/
- NVIDIA Triton Inference Server Architecture & Optimization Documentation:  
  https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/
- NVIDIA Collective Communications Library (NCCL) Architecture Guide:  
  https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/
- Kubernetes Resource Management for Pods and Workload Scheduling:  
  https://kubernetes.io/docs/concepts/scheduling-eviction/
- KEDA (Kubernetes Event-driven Autoscaling) Prometheus Trigger Specification:  
  https://keda.sh/docs/latest/scalers/prometheus/
