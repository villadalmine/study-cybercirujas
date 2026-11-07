# Guided Exercises — Topic 1.2: Compare and Contrast Training and Inference Architecture Requirements and Considerations

**Certification:** NCA-AIIO (NVIDIA-Certified Associate: AI Infrastructure and Operations)  
**Exam weight of this topic:** 4.75%  

**Primary reference:**  
- NCA-AIIO Exam Study Guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf

**Supporting official documentation:**  
- NVIDIA DGX SuperPOD with H100 Architecture Guide: https://docs.nvidia.com/
- NVIDIA Multi-Instance GPU (MIG) User Guide: https://docs.nvidia.com/datacenter/tesla/mig-user-guide/
- NVIDIA Triton Inference Server User Guide: https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/
- NVIDIA Collective Communications Library (NCCL) Documentation: https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/
- NVIDIA GPUDirect Storage (GDS) Overview: https://docs.nvidia.com/gpudirect-storage/overview-guide/index.html
- KEDA Prometheus Trigger Specification: https://keda.sh/docs/latest/scalers/prometheus/

---

## Before You Start

### Lab Requirements

| Exercise | Needs a Physical GPU? | Minimum Environment |
|---|---|---|
| 1 — Workload Characterization & Arithmetic Intensity | No | Scientific calculator or Python shell |
| 2 — Physical Interconnect & Topology Inspection | Recommended | Linux host with NVIDIA driver (`nvidia-smi topo -m`) |
| 3 — Slicing Inference Compute with MIG | Recommended | NVIDIA A100 or H100 (SXM or PCIe) with root access |
| 4 — Inter-Node Fabric & GPUDirect RDMA Verification | Recommended | Host with Mellanox/NVIDIA InfiniBand HCA (`infiniband-diags`) |
| 5 — Kubernetes Orchestration: Gang Training vs. Inference | No | Kubernetes cluster or valid manifest parser (`kubectl apply --dry-run=client`) |
| 6 — Inference Latency Profiling & Saturation Analysis | Recommended | Linux container host with `perf_analyzer` and Triton |
| 7 — Production SRE Troubleshooting & Diagnostic Runbook | Recommended | Linux host with NVIDIA driver and `nvidia-smi` |

> If you do not have direct access to multi-GPU or InfiniBand hardware, complete every step by analyzing the provided realistic CLI command outputs and production manifests. The exam validates your architectural comprehension, diagnostic reasoning, and operational decision-making.

---

## Exercise 1 — Workload Characterization: Compute-Bound GEMMs vs. Memory-Bandwidth-Bound KV Cache

Distributed model training and real-time autoregressive inference exhibit fundamentally opposing computational profiles on modern GPU architectures. Understanding these differences informs compute provisioning, memory sizing, and power budgeting.

### Steps

1. Review the memory footprint formulation for **Training** (Mixed-Precision BF16/FP32 using the Adam optimizer). For a model with $\Phi$ parameters:
   - **Model Parameters (BF16):** $2 \times \Phi$ bytes
   - **Gradients (BF16):** $2 \times \Phi$ bytes
   - **Adam Optimizer States (FP32 master weights, momentum, variance):** $4 + 4 + 4 = 12 \times \Phi$ bytes
   - **Total Static State:** $16 \times \Phi$ bytes (excluding dynamic activation tensors).

2. Review the memory footprint formulation for **Autoregressive Inference** (KV Cache). For context length $L$, batch size $B$, number of layers $n_{\text{layers}}$, number of key-value heads $n_{\text{kv\_heads}}$, and head dimension $d_{\text{head}}$:
   $$\text{KV Cache Size} = 2 \times 2 \times B \times L \times n_{\text{layers}} \times n_{\text{kv\_heads}} \times d_{\text{head}} \text{ bytes}$$
   *(The factor of 2 accounts for both Keys and Values, and another factor of 2 accounts for 16-bit precision FP16/BF16).*

3. Compare the arithmetic intensity (FLOPs per byte transferred from High Bandwidth Memory):
   - **Training GEMM Operations:** Forward and backward passes compute matrix multiplications where every weight loaded into the Tensor Cores is reused across hundreds or thousands of tokens in the batch. Arithmetic intensity is typically $>100\text{ FLOP/byte}$, placing the workload firmly in the **Compute-Bound** regime of the Roofline model.
   - **Inference Decode Phase:** For each newly generated token, the model reads the entire parameter tensor from HBM into the Streaming Multiprocessors (SMs) along with the accumulated KV cache. Arithmetic intensity collapses to $\approx 1\text{ FLOP/byte}$, placing token generation strictly in the **Memory-Bandwidth-Bound** regime.

### Verification Questions

**1.1** You need to pre-train a 70-billion-parameter ($70\text{B}$) foundation model using BF16 mixed-precision and the standard AdamW optimizer. What is the minimum static GPU memory required across your cluster *before* accounting for forward activations, temporary buffers, and communication scratchpads?

**1.2** During LLM inference serving, why does increasing the batch size improve overall token throughput (tokens per second per GPU), and what is the trade-off regarding Inter-Token Latency (ITL)?

**1.3** Why is Tensor Core theoretical peak compute (e.g., 989 TFLOPS on H100 FP16) rarely the bottleneck during the autoregressive decode phase of inference with a batch size of 1?

---

## Exercise 2 — Physical Interconnect & Topology Inspection (`nvidia-smi topo -m`)

High-performance distributed training requires dedicated, high-radix all-to-all GPU interconnects (NVLink/NVSwitch), whereas inference nodes often run cost-effective PCIe topologies or segmented sockets.

### Steps

1. On a high-performance training host (e.g., NVIDIA DGX H100), inspect the GPU-to-GPU and GPU-to-NIC topology matrix:

   ```bash
   nvidia-smi topo -m
   ```

   Representative output on an 8x H100 SXM5 system:

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
     NV18 = Connection traversing 18 4th-Gen NVLinks (via NVSwitch fabric: 900 GB/s bi-directional)
     NODE = Connection traversing PCIe root complex within a single NUMA domain
     SYS  = Connection traversing inter-socket interconnect (UPI/QPI link: ~32-64 GB/s)
   ```

2. Next, inspect the matrix on a dual-socket PCIe inference server hosting two NVIDIA L40S or PCIe H100 cards:

   ```bash
   nvidia-smi topo -m
   ```

   Representative output:

   ```
           GPU0    GPU1    mlx5_0  CPU Aff. NUMA Aff.
   GPU0     X      SYS     NODE    0-31     0
   GPU1    SYS      X      SYS     32-63    1
   mlx5_0  NODE    SYS      X

   Legend:
     X    = Self
     SYS  = Inter-socket connection traversing CPU host fabric (UPI bus)
     NODE = PCIe Host Bridge traverse
   ```

### Verification Questions

**2.1** In the DGX H100 SXM topology matrix, every GPU-to-GPU connection displays `NV18`. How does this impact intra-node Tensor Parallelism (TP) compared to the PCIe topology showing `SYS` between GPU0 and GPU1?

**2.2** In the PCIe inference topology, what severe architectural issue arises if a multi-GPU model spans GPU0 and GPU1, or if network packets arrive on `mlx5_0` for an inference worker bound to GPU1?

---

## Exercise 3 — Hardware Partitioning: Slicing Inference Compute with Multi-Instance GPU (MIG)

Distributed training requires exclusive, bare-metal hardware access to prevent resource contention. Inference workloads, by contrast, frequently suffer from underutilization when serving small or bursty models. Multi-Instance GPU (MIG) provides hardware-level quality-of-service (QoS) by partitioning compute cores, memory controllers, and crossbar paths.

### Steps

1. Verify whether MIG mode is enabled on GPU 0:

   ```bash
   nvidia-smi -i 0 --query-gpu=mig.mode.current --format=csv,noheader
   ```

   Expected output when disabled:
   ```
   Disabled
   ```

2. Enable MIG mode on GPU 0 (requires root privileges and no active GPU contexts):

   ```bash
   sudo nvidia-smi -i 0 -mig 1
   ```

   Expected output:
   ```
   Enabled MIG Mode for GPU 00000000:1B:00.0
   All done.
   ```

3. List the available GPU Instance Profiles for the device:

   ```bash
   sudo nvidia-smi mig -lgip
   ```

   Representative output on an 80 GB H100:

   ```
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
   ```

4. Create two isolated `3g.40gb` GPU Instances (Profile ID 9) and their corresponding Compute Instances (`-C` flag creates default compute instances):

   ```bash
   sudo nvidia-smi mig -cgi 9,9 -C
   ```

   Expected output:
   ```
   Successfully created GPU instance ID  1 on GPU  0 using profile 3g.40gb (ID  9)
   Successfully created compute instance ID  0 on GPU  0, GPU instance ID  1
   Successfully created GPU instance ID  2 on GPU  0 using profile 3g.40gb (ID  9)
   Successfully created compute instance ID  0 on GPU  0, GPU instance ID  2
   ```

5. Confirm the creation and isolation of the MIG devices:

   ```bash
   nvidia-smi
   ```

   Representative output:

   ```
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

### Verification Questions

**3.1** What is the fundamental difference between MIG (Multi-Instance GPU) and MPS (Multi-Process Service) regarding memory bandwidth isolation and fault containment?

**3.2** Can a distributed training job utilizing `torchrun` and NCCL span across multiple MIG slices on the same physical GPU? Why is this anti-pattern avoided in production?

**3.3** You have partitioned an 80 GB GPU into two `3g.40gb` slices. One slice is allocated 3 out of 7 SM slices and 40 GB HBM. How many total compute slices remain unallocated on that physical card?

---

## Exercise 4 — Inter-Node Network Fabric & GPUDirect RDMA Verification

Distributed training scalability depends on non-blocking, multi-rail InfiniBand or RoCEv2 fabrics capable of GPUDirect RDMA (bypassing host CPU memory). Inference serving primarily relies on standard Ethernet for client ingress.

### Steps

1. Inspect the physical link state, active rate, and firmware status of the Host Channel Adapters (HCAs):

   ```bash
   ibstat | grep -E "(CA '|State|Physical state|Link speed)"
   ```

   Representative output on an NDR 400 Gb/s InfiniBand training node:

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

2. Check whether the kernel peer-memory module required for GPUDirect RDMA (`nvidia-peermem`) is loaded:

   ```bash
   lsmod | grep nvidia_peermem
   ```

   Expected output:
   ```
   nvidia_peermem         16384  0
   ib_core               458752  14 rdma_cm,ib_ipoib,nvidia_peermem,mlx5_ib...
   nvidia              56623104  185 nvidia_modeset,nvidia_uvm,nvidia_peermem
   ```

   If the module is missing, load it and inspect `dmesg`:
   ```bash
   sudo modprobe nvidia-peermem
   dmesg | grep -i peermem | tail -n 2
   ```

   Representative output:
   ```
   [ 1240.512019] nvidia_peermem: loading out-of-tree module
   [ 1240.513410] nvidia-peermem: registered ib_register_peer_memory_client successfully
   ```

3. Execute the `all_reduce_perf` microbenchmark from `nccl-tests` across two 8-GPU nodes to verify inter-node communication bus bandwidth:

   ```bash
   mpirun -np 16 \
     -H node-01:8,node-02:8 \
     --bind-to numa \
     -x NCCL_DEBUG=INFO \
     -x NCCL_IB_DISABLE=0 \
     -x NCCL_NET_GDR_LEVEL=5 \
     /opt/nccl-tests/build/all_reduce_perf -b 512M -e 4G -f 2 -g 1
   ```

   Representative output:

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

### Verification Questions

**4.1** In the `all_reduce_perf` test, the average bus bandwidth achieves $\approx 342.7\text{ GB/s}$ across 8x 400 Gb/s NDR InfiniBand links. If `nvidia-peermem` were not loaded, what transport path would NCCL take, and what would happen to the bus bandwidth?

**4.2** Why do production inference clusters serving models across Kubernetes rarely require 8x 400 Gb/s rail-optimized InfiniBand fabrics per server?

---

## Exercise 5 — Kubernetes Orchestration: Gang-Scheduled Training vs. Elastic Inference Serving

Kubernetes resource managers treat training and inference workloads with fundamentally different scheduling semantics: all-or-nothing gang scheduling for training, versus request-metric autoscaling for stateless/elastic inference.

### Steps

1. Inspect the production Kubernetes manifest for a multi-rail distributed training worker node:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: nccl-multinode-training-worker
     namespace: ml-training
     labels:
       app.kubernetes.io/name: "distributed-trainer"
       app.kubernetes.io/component: "training-worker"
   spec:
     replicas: 2
     selector:
       matchLabels:
         app.kubernetes.io/name: "distributed-trainer"
     template:
       metadata:
         labels:
           app.kubernetes.io/name: "distributed-trainer"
           app.kubernetes.io/component: "training-worker"
       spec:
         hostNetwork: true
         hostIPC: true
         dnsPolicy: ClusterFirstWithHostNet
         affinity:
           nodeAffinity:
             requiredDuringSchedulingIgnoredDuringExecution:
               nodeSelectorTerms:
                 - matchExpressions:
                     - key: "nvidia.com/gpu.product"
                       operator: In
                       values:
                         - "NVIDIA-H100-80GB-HBM3"
                     - key: "topology.kubernetes.io/network-rail"
                       operator: In
                       values:
                         - "rail-1"
           podAntiAffinity:
             requiredDuringSchedulingIgnoredDuringExecution:
               - labelSelector:
                   matchExpressions:
                     - key: "app.kubernetes.io/name"
                       operator: In
                       values:
                         - "distributed-trainer"
                 topologyKey: "kubernetes.io/hostname"
         containers:
           - name: pytorch-cell
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
                 export NCCL_IB_CUDA_SUPPORT=1
                 export NCCL_IB_HCA=mlx5_0,mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7
                 export NCCL_IB_GID_INDEX=3
                 export NCCL_NET_GDR_LEVEL=5
                 
                 torchrun \
                   --nnodes=2 \
                   --nproc_per_node=8 \
                   --rdzv_id=pretrain_run_42 \
                   --rdzv_backend=c10d \
                   --rdzv_endpoint=training-coordinator.ml-training.svc.cluster.local:29500 \
                   /workspace/pretrain.py --config /configs/h100-parallel.yaml
             securityContext:
               capabilities:
                 add:
                   - IPC_LOCK
                   - SYS_PTRACE
               privileged: false
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

2. Inspect the production Kubernetes manifest for a Triton Inference Server deployment using MIG partitions and KEDA autoscaling based on queue duration:

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

3. Validate both manifests locally using `kubectl dry-run`:

   ```bash
   kubectl apply --dry-run=client -f training-worker.yaml
   kubectl apply --dry-run=client -f triton-inference.yaml
   ```

### Verification Questions

**5.1** In the training manifest, why are `hostNetwork: true` and `hostIPC: true` configured, and why is an in-memory `emptyDir` mounted to `/dev/shm` with a 256 GiB limit?

**5.2** In the training manifest, what is the purpose of the `topology.kubernetes.io/network-rail: rail-1` node affinity rule?

**5.3** The KEDA autoscaler uses the Prometheus metric `nv_inference_queue_duration_us` divided by `nv_inference_request_success` with a threshold of `20000`. Why is request queue duration a superior scaling metric for inference compared to standard CPU or GPU utilization?

---

## Exercise 6 — Inference Latency Profiling & Concurrency Cliff Analysis (`perf_analyzer`)

SREs managing inference services must identify the concurrency knee where queuing delay compromises latency Service Level Agreements (SLAs).

### Steps

1. Run `perf_analyzer` against the Triton Inference Server endpoint via gRPC across a concurrency range of 1 to 16:

   ```bash
   perf_analyzer -m ensemble_llm -u triton.ml-inference.svc.cluster.local:8001 \
     -i grpc \
     --concurrency-range 1:16:4 \
     --percentile=99 \
     --measurement-mode=time_windows \
     --measurement-interval=10000
   ```

   Representative output:

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

   Request concurrency: 13
     Client: 
       Request count: 5120 requests
       Throughput: 512.0 infer/sec
       p99 latency: 62100 usec
     Server: 
       Inference count: 5120
       Execution count: 640
       Successful request count: 5120
       Avg request latency: 45200 usec (overhead 22 usec + queue 36800 usec + compute input 45 usec + compute infer 8250 usec + compute output 83 usec)

   Inferences/Second vs. Client p99 Latency Summary:
   Concurrency 1:  125.0 infer/sec, p99 = 9.41 ms
   Concurrency 5:  310.2 infer/sec, p99 = 16.82 ms
   Concurrency 9:  489.0 infer/sec, p99 = 28.45 ms
   Concurrency 13: 512.0 infer/sec, p99 = 62.10 ms (SLA Breach: Target < 30 ms)
   ```

### Verification Questions

**6.1** Analyze the server latency breakdown between Concurrency 1 and Concurrency 13. Which specific component caused the P99 latency to surge from 9.41 ms to 62.10 ms?

**6.2** At Concurrency 9, 4,890 inferences were served with only 611 executions. What feature of Triton Inference Server enabled this behavior, and how does it benefit throughput?

---

## Exercise 7 — Production SRE Troubleshooting & Diagnostic Runbook

In production, platform engineers face distinct failure modes: a single degraded GPU can stall a 2,048-GPU training run, while NUMA misalignment can cause severe P99 latency spikes on inference hosts.

### Steps

1. **Diagnosing a Straggler Node in Distributed Training:**
   You observe that an 8,192-GPU pre-training run has seen its iteration step time slow down from 450 ms to 3,200 ms. Query clock throttling across the suspected node:

   ```bash
   nvidia-smi --query-gpu=index,temperature.gpu,clocks.current.graphics,clocks_event_reasons.active --format=csv
   ```

   Representative output:

   ```
   index, temperature.gpu, clocks.current.graphics [MHz], clocks_event_reasons.active
   0, 42, 1980 MHz, 0x0000000000000000
   1, 41, 1980 MHz, 0x0000000000000000
   2, 89, 1050 MHz, 0x0000000000000048
   3, 43, 1980 MHz, 0x0000000000000000
   ```

   *Bitmask analysis:* `0x000000000000000c` corresponds to `sw_thermal_slowdown` (bit 3) and `hw_thermal_slowdown` (bit 2).

2. **Inspecting Memory Health and ECC Failures:**

   ```bash
   nvidia-smi --query-gpu=index,ecc.errors.uncorrected.volatile.total,retired_pages.pending,retired_pages.double_bit.count --format=csv
   ```

   Representative output:

   ```
   index, ecc.errors.uncorrected.volatile.total, retired_pages.pending, retired_pages.double_bit.count
   0, 0, 0
   1, 0, 0
   2, 3, 1, 1
   3, 0, 0
   ```

3. **Cordoning and Draining the Faulty Node:**

   ```bash
   kubectl cordon node-dgx-h100-14
   kubectl drain node-dgx-h100-14 --ignore-daemonsets --delete-emptydir-data --force
   ```

4. **Detecting NUMA Misalignment on an Inference Node:**
   On an inference worker exhibiting unexplained 400 ms latency spikes, inspect the GPU's NUMA node:

   ```bash
   lspci -s 1b:00.0 -v | grep NUMA
   ```

   Representative output:
   ```
           Flags: bus master, fast devsel, latency 0, NUMA node 1
   ```

   Check the CPU affinity of the inference server worker processes:

   ```bash
   ps -eo pid,cmd,psr | grep tritonserver | head -n 3
   ```

   Representative output:
   ```
     41203 tritonserver --model-reposi   0
     41204 tritonserver --model-reposi   1
     41205 tritonserver --model-reposi   2
   ```

   *Diagnosis:* Cores 0, 1, and 2 reside on NUMA Node 0, while GPU `1b:00.0` is physically attached to NUMA Node 1. Every memory transfer and input tensor must traverse the CPU interconnect (UPI/QPI bus).

5. Correct the execution using `numactl`:

   ```bash
   numactl --cpunodebind=1 --membind=1 tritonserver --model-repository=/models
   ```

### Verification Questions

**7.1** In synchronous distributed data-parallel (DDP) training, why does a single throttled GPU on one node cause GPU utilization to drop across all healthy nodes in the cluster?

**7.2** What is the operational risk of running a multi-week training job on a node that reports `ecc.errors.retired.pending > 0`?

**7.3** How does NUMA misalignment between the host network interface card (NIC) and the GPU degrade inference throughput and latency?

---

## Solutions & Explanations

<details>
<summary>Click to view solutions and detailed technical explanations</summary>

### Exercise 1 Solutions

**1.1**  
- **Calculation:**  
  $$\text{Memory} = 16\text{ bytes/parameter} \times 70 \times 10^9\text{ parameters} = 1,120 \times 10^9\text{ bytes} \approx 1,120\text{ GB (1.12 TB)}$$  
- **Explanation:**  
  In mixed-precision training using AdamW, master weights take 4 bytes (FP32), first momentum states take 4 bytes (FP32), and second variance states take 4 bytes (FP32). Working weights and gradients in BF16 consume 2 bytes each. That totals $4 + 4 + 4 + 2 + 2 = 16\text{ bytes per parameter}$. A 70B model requires at least 1,120 GB of raw HBM solely to store optimizer states, gradients, and weights. Across 80 GB GPUs (e.g., A100 or H100), this requires a minimum of $\lceil 1120 / 80 \rceil = 14$ GPUs just to hold the model in memory using ZeRO-3 / FSDP partitioning, before allocating any memory for forward activations.

**1.2**  
- **Explanation:**  
  During the decode phase of LLM inference, model weights must be loaded from High Bandwidth Memory into SM registers for every single token generated. When the batch size is 1, those weights are used to compute predictions for only one token before being discarded, yielding an arithmetic intensity of $\approx 1\text{ FLOP/byte}$. Increasing the batch size allows the same loaded weight matrix to be reused across all tokens in the batch, amortizing the memory read cost and increasing aggregate token throughput.  
- **Trade-off:** Larger batch sizes increase the memory footprint of the KV cache and increase queuing and compute execution time per step, raising Inter-Token Latency (ITL) and Time-To-First-Token (TTFT) for individual users.

**1.3**  
- **Explanation:**  
  At a batch size of 1, the arithmetic intensity is far lower than the device's Roofline saturation threshold (which is typically $>150\text{ FLOP/byte}$ on H100). The execution units (Tensor Cores) spend the vast majority of clock cycles waiting for weights and KV cache tensors to arrive across the memory bus from HBM3. The bottleneck is HBM memory bandwidth (3.35 TB/s on H100 SXM5), not Tensor Core compute capability.

---

### Exercise 2 Solutions

**2.1**  
- **Explanation:**  
  `NV18` indicates 18 fourth-generation NVLink connections routing through high-radix NVSwitch ASICs, providing 900 GB/s bi-directional bandwidth directly between any two GPUs on the SXM baseboard without host CPU intervention. In Tensor Parallelism (TP), every forward and backward transformer layer requires an `AllReduce` across the TP group. At 900 GB/s, this collective communication completes in microseconds.  
  By contrast, on the PCIe topology showing `SYS`, communications between GPU0 and GPU1 must traverse PCIe Host Bridges and the inter-socket CPU UPI bus ($\approx 32\text{--}64\text{ GB/s}$). Attempting TP across this link saturates the UPI bus, stalls the Tensor Cores, and degrades performance.

**2.2**  
- **Explanation:**  
  If packets arrive on `mlx5_0` (attached to NUMA Node 0) for a model running on GPU1 (attached to NUMA Node 1), incoming DMA buffers must traverse the inter-socket UPI link. This cross-socket traversal introduces latency jitter, consumes CPU cache bandwidth, and can trigger PCI root complex replay buffers under heavy load.

---

### Exercise 3 Solutions

**3.1**  
- **Explanation:**  
  - **MIG (Multi-Instance GPU):** Divides the physical GPU at the silicon level into up to seven independent instances. Each instance gets dedicated SM clusters, dedicated memory controllers, isolated crossbar paths, and independent memory segments. An out-of-memory error, compute crash, or memory-saturating kernel in one MIG slice cannot affect adjacent slices. It provides true hardware QoS.  
  - **MPS (Multi-Process Service):** A software-level control plane that multiplexes multiple CUDA contexts onto a single shared GPU. While it reduces context switching overhead and improves SM occupancy, it does **not** provide memory bandwidth isolation, and a fatal hardware fault (such as an illegal memory access) triggered by one process terminates all client processes sharing that MPS server.

**3.2**  
- **Explanation:**  
  MIG completely disables NVLink and cross-instance peer-to-peer (P2P) memory access. Consequently, NCCL cannot use NVLink or direct P2P DMA between MIG instances on the same card; it must fall back to host shared memory or local sockets. Furthermore, distributed training requires maximum compute and memory capacity. Slicing a GPU into smaller partitions introduces communication bottlenecks and limits the batch size that can fit into local memory.

**3.3**  
- **Calculation:**  
  An 80 GB H100 has 7 compute slices and 8 memory slices (7 user-addressable). Each `3g.40gb` profile consumes 3 compute slices and 4 memory slices (half the memory).  
  - Compute slices allocated: $3 + 3 = 6$ slices out of 7.  
  - Unallocated compute slices: $7 - 6 = 1$ compute slice remaining (which can host a single `1g.10gb` slice, but no additional `2g` or `3g` slices).

---

### Exercise 4 Solutions

**4.1**  
- **Explanation:**  
  Without the `nvidia-peermem` kernel module, GPUDirect RDMA is disabled. NCCL cannot map InfiniBand HCA queue pairs directly to GPU virtual memory. Communication falls back to host system memory buffering: data in GPU HBM is copied over PCIe to host system RAM, passed through the Linux TCP/IP network stack (or user-space verbs bounce buffers), transmitted across the wire, copied to the destination host's RAM, and finally copied over PCIe into the destination GPU's memory. This double-copy overhead collapses the effective bus bandwidth from $\approx 343\text{ GB/s}$ down to less than $40\text{ GB/s}$, causing gradient synchronization to stall the training pipeline.

**4.2**  
- **Explanation:**  
  Inference workloads primarily operate on independent request-response streams. Scale-out is achieved by distributing requests across independent model replicas (**Scale-Across**) using standard Kubernetes load balancers over 25/100 GbE datacenter Ethernet. Inter-node GPU-to-GPU communication is only needed when a single model is too large to fit on a single node (requiring multi-node Pipeline or Tensor Parallelism). Even then, communication volume is limited to intermediate activation tensors, unlike training which requires continuous all-to-all gradient and optimizer state exchanges.

---

### Exercise 5 Solutions

**5.1**  
- **`hostNetwork: true`:** Bypasses Kubernetes CNI overlay networking (e.g., VXLAN/Geneve/Calico), allowing the container direct access to physical InfiniBand HCAs and RoCEv2 interfaces without MTU degradation or network packet translation overhead.  
- **`hostIPC: true` and `/dev/shm`:** PyTorch DataLoader multi-processing workers pass batched tensor references between the main training script and worker forks using POSIX shared memory. The default Linux container `/dev/shm` limit is 64 MB, which causes immediate `DataLoader worker exited unexpectedly (SIGBUS)` failures during distributed training. Setting an in-memory `emptyDir` backed by RAM prevents data loader starvation and deadlocks.

**5.2**  
- **Explanation:**  
  In a rail-optimized SuperPOD architecture, all GPUs at index $k$ (e.g., all GPU 0s across all DGX servers) connect to a specific independent InfiniBand switch rail. Scheduling a distributed training job across nodes attached to different rails or disparate spine fabrics introduces inter-switch oversubscription and latency jitter. The `topology.kubernetes.io/network-rail` affinity ensures that all worker pods for a given job are placed within the same physical network rail and leaf fabric.

**5.3**  
- **Explanation:**  
  GPU utilization is a poor indicator for inference scaling. An autoregressive inference engine serving a single request can show 95%+ GPU utilization while sitting comfortably within latency SLAs. Conversely, if requests arrive faster than the model can generate tokens, the server's internal request queue fills up. Tracking queue duration directly measures user-experienced queuing latency. When average queue duration approaches SLA thresholds (e.g., 20 ms), KEDA immediately adds replica pods before requests time out.

---

### Exercise 6 Solutions

**6.1**  
- **Analysis:**  
  Looking at the latency breakdown:  
  - Compute infer time increased slightly from 7,510 $\mu\text{s}$ to 8,250 $\mu\text{s}$ ($\approx 10\%$ increase due to larger batch execution).  
  - Queue time exploded from 240 $\mu\text{s}$ (at Concurrency 1) to 36,800 $\mu\text{s}$ (36.8 ms at Concurrency 13).  
  - Over 90% of the latency growth was caused by requests waiting in the Triton server scheduling queue while the GPU was busy processing earlier batches. This queuing delay caused the P99 latency SLA breach.

**6.2**  
- **Explanation:**  
  This behavior is enabled by Triton's **Dynamic Batching**. Instead of executing each incoming inference request individually, Triton's dynamic scheduler groups concurrent requests that arrive within a configurable delay window into a single combined batch. Serving 4,890 inferences across 611 executions yields an average batch size of $\approx 8$, which significantly improves GPU memory bandwidth efficiency and overall token throughput.

---

### Exercise 7 Solutions

**7.1**  
- **Explanation:**  
  In synchronous distributed data-parallel training (AllReduce), every GPU computes its local forward and backward passes independently, but all GPUs must synchronize gradients at the end of the step before updating optimizer states. The step completes only when the slowest participant finishes:  
  $$\text{Iteration Time} = \max_{i \in \text{GPUs}}(\text{Compute}_i) + \text{AllReduce}(\text{Gradients})$$  
  When GPU 2 throttles from 1,980 MHz to 1,050 MHz, its backward pass takes nearly twice as long. The other 8,191 GPUs complete their local computations quickly and enter a busy-wait state inside the NCCL `AllReduce` barrier, causing aggregate cluster GPU utilization to drop to single digits.

**7.2**  
- **Explanation:**  
  A pending retired page (`ecc.errors.retired.pending > 0`) indicates that the GPU's memory controller has detected a failing physical memory cell and scheduled that page for dynamic retirement upon the next driver reload or system reboot. If the training job accesses that degraded cell before retirement takes place, an uncorrectable double-bit ECC fault will trigger an XID error (e.g., XID 48 or XID 63), crashing the CUDA context. In a multi-node training run, this single crash aborts the entire job, wasting all compute cycles since the last checkpoint.

**7.3**  
- **Explanation:**  
  When an incoming request arrives on a NIC attached to NUMA Node 0, the packet payload is deposited into host memory on Node 0. If the inference server and GPU reside on NUMA Node 1, the data must be read across the inter-socket CPU interconnect (Intel UPI or AMD Infinity Fabric). This cross-socket traversal adds latency to every request, competes for host memory bandwidth with the CPU, and creates unpredictable latency spikes in Time-To-First-Token (TTFT) and P99 latency metrics.
</details>
