# Guided Exercises — Topic 1.1: Describe the NVIDIA Software Stack Used in an AI Environment

**Certification:** NCA-AIIO (NVIDIA-Certified Associate: AI Infrastructure and Operations)
**Exam weight of this topic:** 4.75%

**Primary reference:** NCA-AIIO Exam Study Guide — https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf

**Supporting official documentation:**
- CUDA Compatibility: https://docs.nvidia.com/deploy/cuda-compatibility/
- CUDA Toolkit Release Notes: https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/index.html
- NVIDIA Container Toolkit: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
- NVIDIA GPU Operator: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/getting-started.html
- NVIDIA DCGM User Guide: https://docs.nvidia.com/datacenter/dcgm/latest/user-guide/index.html
- NGC Catalog: https://catalog.ngc.nvidia.com/
- Frameworks Support Matrix: https://docs.nvidia.com/deeplearning/frameworks/support-matrix/index.html
- Triton Inference Server: https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/index.html
- TensorRT: https://docs.nvidia.com/deeplearning/tensorrt/
- NVIDIA AI Enterprise: https://docs.nvidia.com/ai-enterprise/
- NVIDIA NIM: https://docs.nvidia.com/nim/

---

## Before You Start

### Lab requirements

| Exercise | Needs a GPU? | Minimum environment |
|---|---|---|
| 1 — Mapping the stack | No | Pen and paper |
| 2 — Driver vs. CUDA Toolkit | Yes | Linux host with an NVIDIA GPU and driver |
| 3 — Container Toolkit | Yes | Docker or Podman + NVIDIA Container Toolkit |
| 4 — NGC framework containers | Yes | Same as 3, ~20 GB of free disk |
| 5 — Kubernetes and the GPU Operator | Yes | Kubernetes cluster with at least one GPU node |
| 6 — DCGM monitoring | Yes | Same as 5, or a host with DCGM installed |
| 7 — Inference: TensorRT, Triton, NIM | Yes | Same as 3 |
| 8 — Scenario classification | No | Pen and paper |

If you have no GPU, you can still do every exercise. Read each command and its **expected output**, then answer the questions from that output. The exam tests whether you can describe the stack and choose the right component. It does not test whether you can type the commands from memory.

> The output shown below is representative. Your driver versions, GPU models, UUIDs, and timestamps will differ. When the questions ask about a field, look at the field in your own output.

### Reference model: the layers

Keep this picture in mind for all the exercises. It is the mental model the exam expects:

```
┌──────────────────────────────────────────────────────────────────────┐
│  Applications / Microservices   NIM, NeMo, RAPIDS, Riva, Morpheus,...│
├──────────────────────────────────────────────────────────────────────┤
│  Frameworks & Serving           PyTorch, TensorFlow, JAX, Triton     │
│                                 Inference Server, TensorRT-LLM       │
├──────────────────────────────────────────────────────────────────────┤
│  CUDA-X Libraries               cuDNN, cuBLAS, NCCL, TensorRT,       │
│                                 cuFFT, cuSPARSE, DALI, ...           │
├──────────────────────────────────────────────────────────────────────┤
│  CUDA Toolkit / Runtime         nvcc, libcudart, CUDA APIs           │
├──────────────────────────────────────────────────────────────────────┤
│  Container & Orchestration      NVIDIA Container Toolkit,            │
│                                 GPU Operator, device plugin, DCGM    │
├──────────────────────────────────────────────────────────────────────┤
│  NVIDIA Driver                  kernel module + libcuda.so (driver   │
│                                 API) + NVML                          │
├──────────────────────────────────────────────────────────────────────┤
│  Hardware                       GPU, NVLink/NVSwitch, InfiniBand/    │
│                                 Ethernet NICs, DPUs                  │
└──────────────────────────────────────────────────────────────────────┘
   Distribution / support wrappers: NGC catalog (containers, models,
   Helm charts) and NVIDIA AI Enterprise (licensed, supported suite)
```

---

## Exercise 1 — Mapping the Stack (no GPU required)

### Steps

1. Copy the following list of components onto a sheet of paper or into a text file:

   `NVIDIA Driver`, `CUDA Toolkit`, `cuDNN`, `NCCL`, `TensorRT`, `Triton Inference Server`, `NVIDIA Container Toolkit`, `GPU Operator`, `DCGM`, `NGC`, `NVIDIA AI Enterprise`, `NIM`, `RAPIDS`, `NeMo`, `Base Command Manager`, `DOCA`, `Magnum IO / GPUDirect`

2. For each component, assign:
   - **Layer**: use the reference model above.
   - **Primary job**: one sentence.
   - **Phase**: *training*, *inference*, *data prep*, *operations/infra*, or *several*.

3. Draw arrows for the dependencies you know. For example: `cuDNN → CUDA runtime → driver`.

### Verification questions

**1.1** Which single component must exist on the **host** of every GPU workload, including containerized ones, and why can't it be packaged inside the container image?

**1.2** cuDNN and NCCL are both CUDA-X libraries. What problem does each one solve? Which one matters more as you go from 1 GPU to 64 GPUs?

**1.3** What is the difference between **NGC** and **NVIDIA AI Enterprise**? Is one a subset of the other?

**1.4** Put these in order from lowest to highest abstraction: `TensorRT`, `NIM`, `CUDA runtime`, `Triton Inference Server`.

**1.5** DOCA and Magnum IO are not "AI frameworks". Why does the NVIDIA AI stack include them?

---

## Exercise 2 — Driver vs. CUDA Toolkit: Reading the Version Contract

### Steps

1. On a GPU host, run `nvidia-smi`:

   ```bash
   nvidia-smi
   ```

   Representative output:

   ```
   +-----------------------------------------------------------------------------------------+
   | NVIDIA-SMI 550.90.07              Driver Version: 550.90.07      CUDA Version: 12.4     |
   |-----------------------------------------+------------------------+----------------------+
   | GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
   | Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
   |                                         |                        |               MIG M. |
   |=========================================+========================+======================|
   |   0  NVIDIA A100-SXM4-80GB          On  |   00000000:07:00.0 Off |                    0 |
   | N/A   32C    P0             62W /  400W |       1MiB /  81920MiB |      0%      Default |
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

2. Check whether a CUDA Toolkit is installed on the host:

   ```bash
   nvcc --version
   ```

   Representative output when the toolkit is installed:

   ```
   nvcc: NVIDIA (R) Cuda compiler driver
   Copyright (c) 2005-2024 NVIDIA Corporation
   Built on Thu_Mar_28_02:18:24_PDT_2024
   Cuda compilation tools, release 12.4, V12.4.131
   Build cuda_12.4.r12.4/compiler.34097967_0
   ```

   On a pure inference node or a Kubernetes worker, the more common result is:

   ```
   bash: nvcc: command not found
   ```

3. Look at the pieces the driver installs:

   ```bash
   cat /proc/driver/nvidia/version
   ls -l /usr/lib/x86_64-linux-gnu/libcuda.so* /usr/lib/x86_64-linux-gnu/libnvidia-ml.so* 2>/dev/null
   lsmod | grep -E '^nvidia'
   ```

   Representative output:

   ```
   NVRM version: NVIDIA UNIX x86_64 Kernel Module  550.90.07  Fri May 31 09:35:42 UTC 2024
   GCC version:  gcc version 12.3.0 (Ubuntu 12.3.0-1ubuntu1~22.04)
   lrwxrwxrwx 1 root root       12 Jun 10 10:02 /usr/lib/x86_64-linux-gnu/libcuda.so.1 -> libcuda.so.550.90.07
   -rw-r--r-- 1 root root 28712096 Jun 10 10:02 /usr/lib/x86_64-linux-gnu/libcuda.so.550.90.07
   lrwxrwxrwx 1 root root       24 Jun 10 10:02 /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 -> libnvidia-ml.so.550.90.07
   -rw-r--r-- 1 root root  2078360 Jun 10 10:02 /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.550.90.07
   nvidia_uvm           1789952  0
   nvidia_drm             90112  0
   nvidia_modeset       1314816  1 nvidia_drm
   nvidia              56836096  2 nvidia_uvm,nvidia_modeset
   ```

4. Get a machine-readable query, the format you would use in scripts and monitoring:

   ```bash
   nvidia-smi --query-gpu=name,driver_version,memory.total,compute_cap --format=csv
   ```

   ```
   name, driver_version, memory.total [MiB], compute_cap
   NVIDIA A100-SXM4-80GB, 550.90.07, 81920 MiB, 8.0
   ```

### Verification questions

**2.1** `nvidia-smi` reports `CUDA Version: 12.4`, but `nvcc` is "command not found". Is CUDA "installed" on this host? What exactly does the `12.4` in `nvidia-smi` mean?

**2.2** A developer's container ships the CUDA 12.6 runtime, and the host has driver 550 (`CUDA Version: 12.4`). According to the CUDA Compatibility documentation, under what conditions can this still work, and what is the risk?

**2.3** Which of the files from step 3 does `nvidia-smi` and DCGM use to read GPU telemetry? Which one does a CUDA application load to talk to the GPU?

**2.4** Why do you get a compute capability (`8.0`) separate from the driver version? Which software component cares about it?

---

## Exercise 3 — NVIDIA Container Toolkit: How a Container Sees the GPU

### Steps

1. Verify that the toolkit is installed and look at its CLI:

   ```bash
   nvidia-ctk --version
   ```

   ```
   NVIDIA Container Toolkit CLI version 1.16.1
   commit: a470818ba7d9166be282cd0039dd2fc9b0a34d73
   ```

2. Configure the Docker runtime. This is idempotent; it edits `/etc/docker/daemon.json`:

   ```bash
   sudo nvidia-ctk runtime configure --runtime=docker
   sudo systemctl restart docker
   cat /etc/docker/daemon.json
   ```

   ```json
   {
       "runtimes": {
           "nvidia": {
               "args": [],
               "path": "nvidia-container-runtime"
           }
       }
   }
   ```

3. Run a minimal CUDA container **without** asking for GPUs, then **with** them:

   ```bash
   docker run --rm nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
   ```

   ```
   docker: Error response from daemon: failed to create task for container: failed to create shim task: OCI runtime create failed: runc create failed: unable to start container process: exec: "nvidia-smi": executable file not found in $PATH: unknown.
   ```

   ```bash
   docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi -L
   ```

   ```
   GPU 0: NVIDIA A100-SXM4-80GB (UUID: GPU-3b1f6c2a-8e0d-4c3a-9f61-2d7e5b4a1c90)
   ```

4. Look at what the toolkit injected into the container:

   ```bash
   docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 \
     bash -c 'ls /dev/nvidia*; ldconfig -p | grep -E "libcuda.so|libnvidia-ml.so"'
   ```

   ```
   /dev/nvidia-modeset
   /dev/nvidia-uvm
   /dev/nvidia-uvm-tools
   /dev/nvidia0
   /dev/nvidiactl
   	libnvidia-ml.so.1 (libc6,x86-64) => /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1
   	libcuda.so.1 (libc6,x86-64) => /usr/lib/x86_64-linux-gnu/libcuda.so.1
   ```

5. Restrict a container to a single GPU, by index or UUID:

   ```bash
   docker run --rm --gpus '"device=0"' nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi -L
   ```

6. (Optional, Podman/CDI) Generate a Container Device Interface spec and list the devices:

   ```bash
   sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
   nvidia-ctk cdi list
   ```

   ```
   INFO[0000] Found 3 CDI devices
   nvidia.com/gpu=0
   nvidia.com/gpu=GPU-3b1f6c2a-8e0d-4c3a-9f61-2d7e5b4a1c90
   nvidia.com/gpu=all
   ```

### Verification questions

**3.1** In step 3, the image `nvidia/cuda:12.4.1-base-ubuntu22.04` does not contain `nvidia-smi`. Where did the binary come from when you passed `--gpus all`?

**3.2** From step 4, list the two categories of host resources the Container Toolkit injects. Why isn't `libcudart.so` (the CUDA runtime) on that list?

**3.3** What does CDI provide that the legacy `--gpus` hook doesn't, and which container engines benefit?

**3.4** A colleague says: "I'll bake the NVIDIA driver into our base image so we don't depend on the hosts." Explain why this breaks.

---

## Exercise 4 — NGC Framework Containers: The Stack, Pre-assembled

### Steps

1. Open https://catalog.ngc.nvidia.com/ and look up the **PyTorch** container. Note the tag format (`YY.MM-py3`). Then open the Frameworks Support Matrix (https://docs.nvidia.com/deeplearning/frameworks/support-matrix/index.html) and find the row for the `24.08` release.

2. Pull the container. Public NGC images do not require login; some entitled AI Enterprise content does:

   ```bash
   docker pull nvcr.io/nvidia/pytorch:24.08-py3
   ```

   If you need to authenticate for entitled content:

   ```bash
   docker login nvcr.io
   # Username: $oauthtoken
   # Password: <your NGC API key>
   ```

3. Ask the container which stack versions it ships:

   ```bash
   docker run --rm --gpus all --ipc=host nvcr.io/nvidia/pytorch:24.08-py3 python -c '
   import torch
   print("torch       ", torch.__version__)
   print("CUDA runtime", torch.version.cuda)
   print("cuDNN       ", torch.backends.cudnn.version())
   print("NCCL        ", torch.cuda.nccl.version())
   print("GPU visible ", torch.cuda.is_available(), torch.cuda.get_device_name(0))
   '
   ```

   Representative output (compare it with the support matrix row):

   ```
   torch        2.5.0a0+872d972e41.nv24.08
   CUDA runtime 12.6
   cuDNN        90300
   NCCL         (2, 22, 3)
   GPU visible  True NVIDIA A100-SXM4-80GB
   ```

4. Check the environment variables NVIDIA sets in its images:

   ```bash
   docker run --rm nvcr.io/nvidia/pytorch:24.08-py3 bash -c 'env | grep -E "^(CUDA_VERSION|CUDNN_VERSION|NCCL_VERSION|NVIDIA_PYTORCH_VERSION)="'
   ```

   ```
   CUDA_VERSION=12.6.0.022
   CUDNN_VERSION=9.3.0.75
   NCCL_VERSION=2.22.3
   NVIDIA_PYTORCH_VERSION=24.08
   ```

5. Compare this with the host from Exercise 2: driver 550 (`CUDA Version: 12.4`), but the container runtime is 12.6. Run step 3 on your host and look for a warning or an error.

### Verification questions

**4.1** The container reports CUDA runtime 12.6, cuDNN 9.3, and NCCL 2.22. Which of these come from the **image**, and which come from the **host**?

**4.2** Why does NVIDIA publish monthly framework containers instead of telling users to `pip install torch`? Name at least three benefits.

**4.3** Why does `--ipc=host` (or a large `--shm-size`) matter for PyTorch in containers, and which stack component uses shared memory heavily in multi-GPU jobs?

**4.4** In step 5, the 12.6 runtime runs on a 12.4-era driver. Which compatibility mechanism allows this for most workloads, and what kind of workload can still fail?

**4.5** Besides containers, what other artifact types does the NGC catalog host?

---

## Exercise 5 — Kubernetes: The GPU Operator Assembles the Stack on Every Node

### Steps

1. Label check: confirm that Kubernetes does not yet know about the GPU.

   ```bash
   kubectl describe node gpu-worker-01 | grep -A8 -E '^Capacity'
   ```

   ```
   Capacity:
     cpu:                64
     ephemeral-storage:  1844221592Ki
     hugepages-1Gi:      0
     hugepages-2Mi:      0
     memory:             1056596188Ki
     pods:               110
   ```

2. Install the GPU Operator with Helm. Set `driver.enabled=false` only if the driver is already installed on the host, as in Exercise 2:

   ```bash
   helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
   helm install --wait --generate-name \
     -n gpu-operator --create-namespace \
     nvidia/gpu-operator \
     --set driver.enabled=false
   ```

3. Look at the components the Operator deployed:

   ```bash
   kubectl get pods -n gpu-operator
   ```

   ```
   NAME                                                          READY   STATUS      RESTARTS   AGE
   gpu-feature-discovery-x7k2p                                   1/1     Running     0          3m
   gpu-operator-1730881234-node-feature-discovery-gc-5d8f7-wq   1/1     Running     0          4m
   gpu-operator-1730881234-node-feature-discovery-master-6c9b   1/1     Running     0          4m
   gpu-operator-1730881234-node-feature-discovery-worker-2fjtl  1/1     Running     0          4m
   gpu-operator-7f8b9c6d5-lmn4q                                  1/1     Running     0          4m
   nvidia-container-toolkit-daemonset-9hq4s                      1/1     Running     0          3m
   nvidia-cuda-validator-p8d2z                                   0/1     Completed   0          2m
   nvidia-dcgm-exporter-4vr8n                                    1/1     Running     0          3m
   nvidia-device-plugin-daemonset-k2c7w                          1/1     Running     0          3m
   nvidia-operator-validator-tz6rb                               1/1     Running     0          3m
   ```

4. Look at the `ClusterPolicy`, the single CR that declares the whole node stack:

   ```bash
   kubectl get clusterpolicies.nvidia.com
   kubectl get clusterpolicy cluster-policy -o jsonpath='{.status.state}{"\n"}'
   ```

   ```
   NAME             STATUS   AGE
   cluster-policy   ready    2024-11-06T10:15:22Z
   ready
   ```

5. Check what the node now advertises:

   ```bash
   kubectl describe node gpu-worker-01 | grep -E 'nvidia.com/gpu(:|\.product|\.count|\.memory)'
   ```

   ```
                       nvidia.com/gpu.count=1
                       nvidia.com/gpu.memory=81920
                       nvidia.com/gpu.product=NVIDIA-A100-SXM4-80GB
     nvidia.com/gpu:     1
     nvidia.com/gpu:     1
   ```

6. Schedule a workload that requests a GPU. Save this as `cuda-vectoradd.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: cuda-vectoradd
   spec:
     restartPolicy: OnFailure
     nodeSelector:
       nvidia.com/gpu.product: NVIDIA-A100-SXM4-80GB
     containers:
       - name: cuda-vectoradd
         image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0
         resources:
           limits:
             nvidia.com/gpu: 1
   ```

   ```bash
   kubectl apply -f cuda-vectoradd.yaml
   kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/cuda-vectoradd --timeout=120s
   kubectl logs cuda-vectoradd
   ```

   ```
   [Vector addition of 50000 elements]
   Copy input data from the host memory to the CUDA device
   CUDA kernel launch with 196 blocks of 256 threads
   Copy output data from the CUDA device to the host memory
   Test PASSED
   Done
   ```

7. Try to break it: change `nvidia.com/gpu: 1` to `nvidia.com/gpu: 2` on a 1-GPU node, apply it under a different name, and run `kubectl describe pod`. Look at the `Events` section:

   ```
   Warning  FailedScheduling  5s  default-scheduler  0/3 nodes are available: 1 Insufficient nvidia.com/gpu, 2 node(s) didn't match Pod's node affinity/selector. preemption: 0/3 nodes are available: 1 No preemption victims found for incoming pod, 2 Preemption is not helpful for scheduling.
   ```

### Verification questions

**5.1** Map each pod from step 3 to the piece of the stack it manages: driver, container runtime integration, resource advertisement, node labeling, monitoring, validation.

**5.2** Why is there no `nvidia-driver-daemonset` in step 3? In which scenario would you leave `driver.enabled=true`?

**5.3** Which component turns the physical GPU into the extended resource `nvidia.com/gpu: 1` that the scheduler counts? Which component created the `nvidia.com/gpu.product` label used in the `nodeSelector`?

**5.4** Can two pods each request `nvidia.com/gpu: 0.5`? If not, which NVIDIA technologies let several workloads share a GPU, and how does each appear to Kubernetes?

**5.5** What is the operational advantage of a single `ClusterPolicy` over installing each component by hand on each node?

---

## Exercise 6 — DCGM: Monitoring and Health at Data-Center Scale

### Steps

1. On a host with DCGM installed (or inside the `nvidia-dcgm-exporter` pod's node), discover GPUs:

   ```bash
   dcgmi discovery -l
   ```

   ```
   1 GPU found.
   +--------+----------------------------------------------------------------------+
   | GPU ID | Device Information                                                   |
   +--------+----------------------------------------------------------------------+
   | 0      | Name: NVIDIA A100-SXM4-80GB                                          |
   |        | PCI Bus ID: 00000000:07:00.0                                         |
   |        | Device UUID: GPU-3b1f6c2a-8e0d-4c3a-9f61-2d7e5b4a1c90                |
   +--------+----------------------------------------------------------------------+
   0 NvSwitches found.
   +-----------+
   | Switch ID |
   +-----------+
   +-----------+
   ```

2. Run a quick (level 1) active diagnostic:

   ```bash
   dcgmi diag -r 1
   ```

   ```
   Successfully ran diagnostic for group.
   +---------------------------+------------------------------------------------+
   | Diagnostic                | Result                                         |
   +===========================+================================================+
   |-----  Metadata  ----------+------------------------------------------------|
   | DCGM Version              | 3.3.7                                          |
   | Driver Version Detected   | 550.90.07                                      |
   | GPU Device IDs Detected   | 20b2                                           |
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
   ```

3. Watch live metrics. These field IDs are GPU utilization (203), framebuffer used (252), and power (155):

   ```bash
   dcgmi dmon -e 203,252,155 -c 5
   ```

   ```
   #Entity   GPUTL  FBUSD   POWER
   ID
   GPU 0     0      1       62.104
   GPU 0     0      1       61.987
   GPU 0     0      1       62.311
   GPU 0     0      1       62.050
   GPU 0     0      1       61.902
   ```

4. In Kubernetes, scrape the exporter deployed by the GPU Operator:

   ```bash
   kubectl -n gpu-operator port-forward svc/nvidia-dcgm-exporter 9400:9400 &
   curl -s localhost:9400/metrics | grep -E '^DCGM_FI_DEV_(GPU_UTIL|FB_USED|GPU_TEMP)'
   ```

   ```
   DCGM_FI_DEV_GPU_TEMP{gpu="0",UUID="GPU-3b1f6c2a-8e0d-4c3a-9f61-2d7e5b4a1c90",pci_bus_id="00000000:07:00.0",device="nvidia0",modelName="NVIDIA A100-SXM4-80GB",Hostname="gpu-worker-01"} 32
   DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-3b1f6c2a-8e0d-4c3a-9f61-2d7e5b4a1c90",pci_bus_id="00000000:07:00.0",device="nvidia0",modelName="NVIDIA A100-SXM4-80GB",Hostname="gpu-worker-01"} 0
   DCGM_FI_DEV_FB_USED{gpu="0",UUID="GPU-3b1f6c2a-8e0d-4c3a-9f61-2d7e5b4a1c90",pci_bus_id="00000000:07:00.0",device="nvidia0",modelName="NVIDIA A100-SXM4-80GB",Hostname="gpu-worker-01"} 1
   ```

5. Write an alert rule for a GPU that stays saturated. Save it as `gpu-alerts.yaml` (Prometheus Operator `PrometheusRule`):

   ```yaml
   apiVersion: monitoring.coreos.com/v1
   kind: PrometheusRule
   metadata:
     name: gpu-alerts
     namespace: gpu-operator
   spec:
     groups:
       - name: gpu.rules
         rules:
           - alert: GPUHighTemperature
             expr: |
               max by (Hostname, gpu) (DCGM_FI_DEV_GPU_TEMP) > 85
             for: 10m
             labels:
               severity: warning
             annotations:
               summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} above 85C for 10m"
           - alert: GPUFramebufferNearlyFull
             expr: |
               DCGM_FI_DEV_FB_USED
                 /
               (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE)
                 > 0.95
             for: 15m
             labels:
               severity: info
             annotations:
               summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} memory above 95%"
   ```

### Verification questions

**6.1** `nvidia-smi` and DCGM both read GPU telemetry. What does DCGM add that justifies running it in a cluster?

**6.2** What is the difference between `dcgmi diag -r 1` and `-r 3`, and when would you run the longer one?

**6.3** `DCGM_FI_DEV_GPU_UTIL` reports 100% for a training job. Does this mean the GPU's Tensor Cores are saturated? Which kind of DCGM metric gives a more accurate picture?

**6.4** In the `PrometheusRule`, why is the operator `/` on its own line indented at the same level as the other lines of the `expr: |` block?

---

## Exercise 7 — Inference: TensorRT, Triton Inference Server, and NIM

### Steps

1. **TensorRT: build an optimized engine.** Export any ONNX model (for example ResNet-50) to `model.onnx`, then compile it with `trtexec` from the TensorRT container:

   ```bash
   docker run --rm --gpus all -v "$PWD":/work -w /work nvcr.io/nvidia/tensorrt:24.08-py3 \
     trtexec --onnx=model.onnx --saveEngine=model.plan --fp16
   ```

   Representative ending of the output:

   ```
   [I] === Performance summary ===
   [I] Throughput: 2843.17 qps
   [I] Latency: min = 0.398 ms, max = 0.612 ms, mean = 0.415 ms, median = 0.411 ms, percentile(90%) = 0.424 ms, percentile(95%) = 0.431 ms, percentile(99%) = 0.469 ms
   [I] GPU Compute Time: min = 0.334 ms, max = 0.541 ms, mean = 0.348 ms, median = 0.345 ms, percentile(90%) = 0.356 ms, percentile(95%) = 0.362 ms, percentile(99%) = 0.398 ms
   &&&& PASSED TensorRT.trtexec [TensorRT v100300] # trtexec --onnx=model.onnx --saveEngine=model.plan --fp16
   ```

2. **Triton: build the model repository.** Triton expects this exact structure:

   ```bash
   mkdir -p model_repository/resnet50/1
   cp model.plan model_repository/resnet50/1/model.plan
   ```

   ```
   model_repository/
   └── resnet50/
       ├── config.pbtxt
       └── 1/
           └── model.plan
   ```

   Create `model_repository/resnet50/config.pbtxt` (protobuf text format, not YAML):

   ```
   name: "resnet50"
   platform: "tensorrt_plan"
   max_batch_size: 32
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
     max_queue_delay_microseconds: 100
   }
   instance_group [
     {
       count: 2
       kind: KIND_GPU
     }
   ]
   ```

   > The `input`/`output` names must match the tensor names in your ONNX export. Check them with `trtexec --onnx=model.onnx --verbose` or Netron.

3. **Start Triton:**

   ```bash
   docker run --rm --gpus all -p 8000:8000 -p 8001:8001 -p 8002:8002 \
     -v "$PWD/model_repository":/models \
     nvcr.io/nvidia/tritonserver:24.08-py3 \
     tritonserver --model-repository=/models
   ```

   Look for this in the log:

   ```
   +----------+---------+--------+
   | Model    | Version | Status |
   +----------+---------+--------+
   | resnet50 | 1       | READY  |
   +----------+---------+--------+
   ...
   I1106 10:42:11.218 1 grpc_server.cc:2463] Started GRPCInferenceService at 0.0.0.0:8001
   I1106 10:42:11.219 1 http_server.cc:4692] Started HTTPService at 0.0.0.0:8000
   I1106 10:42:11.262 1 http_server.cc:362] Started Metrics Service at 0.0.0.0:8002
   ```

4. **Probe Triton** from another terminal:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' localhost:8000/v2/health/ready
   curl -s localhost:8000/v2/models/resnet50 | python3 -m json.tool
   curl -s localhost:8002/metrics | grep -E '^nv_inference_request_success'
   ```

   ```
   200
   {
       "name": "resnet50",
       "versions": [
           "1"
       ],
       "platform": "tensorrt_plan",
       "inputs": [
           {
               "name": "input",
               "datatype": "FP32",
               "shape": [-1, 3, 224, 224]
           }
       ],
       "outputs": [
           {
               "name": "output",
               "datatype": "FP32",
               "shape": [-1, 1000]
           }
       ]
   }
   nv_inference_request_success{model="resnet50",version="1"} 0
   ```

5. **NIM (read-only or with an NGC API key):** look up an LLM NIM on https://build.nvidia.com/ or in the NGC catalog. The typical launch pattern is:

   ```bash
   export NGC_API_KEY=<your key>
   docker run --rm --gpus all --shm-size=16GB \
     -e NGC_API_KEY \
     -v "$HOME/.cache/nim":/opt/nim/.cache \
     -p 8000:8000 \
     nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
   ```

   Then query it with the OpenAI-compatible API:

   ```bash
   curl -s localhost:8000/v1/models
   curl -s localhost:8000/v1/chat/completions -H 'Content-Type: application/json' -d '{
     "model": "meta/llama-3.1-8b-instruct",
     "messages": [{"role": "user", "content": "In one sentence, what is NCCL?"}],
     "max_tokens": 64
   }'
   ```

### Verification questions

**7.1** What does TensorRT do to a model, and why is a `model.plan` built on an A100 not guaranteed to load on an L4 or an H100?

**7.2** In `config.pbtxt`, what do `dynamic_batching` and `instance_group.count: 2` buy you? What is the trade-off of increasing `max_queue_delay_microseconds`?

**7.3** Triton exposes ports 8000, 8001, and 8002. What does each one serve? Which one would a Kubernetes `readinessProbe` use?

**7.4** Triton can serve TensorRT, ONNX Runtime, PyTorch, and Python backends side by side. Why is "multi-framework" a key architectural property of an inference server in a mixed enterprise?

**7.5** How is a NIM different from "Triton + a model you exported yourself"? Which layers of the stack does a NIM already bundle?

---

## Exercise 8 — Scenario Classification (exam-style, no GPU required)

### Steps

For each scenario, name the **NVIDIA software component(s)** that solve it and justify your choice in one or two sentences.

1. A team needs to train a 70B-parameter model across 8 nodes × 8 GPUs. Gradient all-reduce is the bottleneck.
2. A data science team spends hours on pandas ETL over 200 GB of Parquet before every training run.
3. An enterprise wants a supported, licensed AI software suite with security patching, API stability guarantees, and NVIDIA enterprise support for production.
4. A platform team must provision, image, and manage the OS and software of a 32-node GPU cluster, including Slurm or Kubernetes.
5. An SRE needs to detect a GPU with growing ECC errors before it crashes a weeks-long training job.
6. A company wants to deploy an LLM chatbot in a week, on-prem, with an OpenAI-compatible API, without becoming experts in inference optimization.
7. A team wants to build, customize (fine-tune), and add guardrails to its own generative AI model.
8. Storage is slow: data loading from a parallel filesystem goes through the CPU's memory before reaching the GPU.
9. A network team wants to offload and accelerate networking, storage, and security functions on a BlueField DPU.
10. A developer gets `CUDA driver version is insufficient for CUDA runtime version` after pulling a new NGC container.

### Verification question

**8.1** For scenario 10, write the two remedies in order of preference for a production cluster, and explain why the "obvious" fix of downgrading the container isn't always the right one.

---

## Answers

<details>
<summary><strong>Exercise 1 — Mapping the stack</strong></summary>

| Component | Layer | Primary job | Phase |
|---|---|---|---|
| NVIDIA Driver | Driver | Kernel module + user-mode driver (`libcuda`) + NVML; the only path to the hardware | Several |
| CUDA Toolkit | CUDA | Compiler (`nvcc`), runtime (`libcudart`), headers, tools to build/run GPU code | Several |
| cuDNN | CUDA-X | Optimized primitives for deep neural networks (convolutions, attention, normalization) | Training + inference |
| NCCL | CUDA-X | Collective communication (all-reduce, all-gather, broadcast) across GPUs and nodes over NVLink/InfiniBand/Ethernet | Training (multi-GPU) |
| TensorRT | CUDA-X / inference SDK | Inference optimizer and runtime: layer fusion, precision calibration (FP16/INT8/FP8), kernel auto-tuning | Inference |
| Triton Inference Server | Serving | Multi-framework model server with dynamic batching, concurrent model execution, HTTP/gRPC, metrics | Inference |
| NVIDIA Container Toolkit | Container | Injects driver libraries and device nodes into containers | Ops/infra |
| GPU Operator | Orchestration | Automates driver, toolkit, device plugin, GFD, DCGM, and validation on Kubernetes nodes | Ops/infra |
| DCGM | Ops | Data-center GPU monitoring, health checks, diagnostics, policy | Ops/infra |
| NGC | Distribution | Catalog of GPU-optimized containers, pretrained models, Helm charts, resources | Several |
| NVIDIA AI Enterprise | Distribution/support | Licensed, supported end-to-end software suite (frameworks, NIM, Triton, RAPIDS, Operators...) with enterprise support | Several |
| NIM | Application/microservice | Prebuilt, optimized inference microservices with standard APIs | Inference |
| RAPIDS | CUDA-X / application | GPU-accelerated data science (cuDF, cuML, cuGraph) | Data prep / classical ML |
| NeMo | Framework | Build, customize, and deploy generative AI models (LLM, speech, multimodal), including guardrails | Training + customization |
| Base Command Manager | Ops | Cluster provisioning and management (OS images, workload managers, monitoring) | Ops/infra |
| DOCA | Hardware SDK | SDK/runtime for BlueField DPUs and ConnectX: networking, storage, security offloads | Ops/infra |
| Magnum IO / GPUDirect | IO | Data-center IO stack: GPUDirect RDMA and GPUDirect Storage, NCCL, etc. | Training + data loading |

Typical dependency chain: `PyTorch → cuDNN/cuBLAS/NCCL → CUDA runtime → libcuda (driver) → kernel module → GPU`.

**1.1** The **NVIDIA driver**, specifically its kernel module. Containers share the host kernel. A kernel module cannot be loaded from a container's userspace image, and the user-mode driver (`libcuda.so`) must exactly match the version of the loaded kernel module. That is why the Container Toolkit injects these libraries from the host at container start instead of the image shipping them.

**1.2** **cuDNN** accelerates the math of neural network layers *inside* a GPU. **NCCL** moves data *between* GPUs (gradients, activations) using topology-aware collective algorithms over NVLink, NVSwitch, PCIe, and InfiniBand/RoCE. As you scale from 1 to 64 GPUs, communication becomes the dominant cost, so NCCL (and the underlying fabric) matters more.

**1.3** **NGC** is the catalog/registry, the distribution channel where NVIDIA publishes containers, models, and Helm charts; much of it is free. **NVIDIA AI Enterprise** is a licensed product: a curated, supported, security-maintained subset of that software (production branches, long-term support branches, enterprise support), certified on specific systems and platforms. It is delivered *through* NGC. So, AI Enterprise content lives in NGC, but AI Enterprise adds support, lifecycle guarantees, and entitlement.

**1.4** `CUDA runtime` → `TensorRT` → `Triton Inference Server` → `NIM`. A NIM typically packages Triton and/or TensorRT-LLM with an optimized model and an API.

**1.5** AI at scale is limited by data movement as much as by compute. **Magnum IO** (GPUDirect RDMA, GPUDirect Storage, NCCL, and related technologies) removes CPU bounce buffers and bottlenecks between storage, network, and GPU memory. **DOCA** programs the DPUs that offload networking, storage, and security from host CPUs in AI data centers. Both are part of the infrastructure layer of the stack, which is exactly the domain of an "AI Infrastructure and Operations" certification.

</details>

<details>
<summary><strong>Exercise 2 — Driver vs. CUDA Toolkit</strong></summary>

**2.1** The **CUDA driver API** is installed (it ships with the driver as `libcuda.so`), but the **CUDA Toolkit** (`nvcc`, headers, development libraries) is not. The `CUDA Version: 12.4` in `nvidia-smi` is the **highest CUDA version this driver supports**. It does *not* mean a 12.4 toolkit is installed. This is normal and desirable on production nodes. Applications get their CUDA runtime from their container or virtual environment.

**2.2** CUDA's **minor version compatibility** allows applications built with a newer 12.x toolkit to run on an older driver within the same major release (12.x), as long as the driver meets the minimum for that major version. The risk: features that need newer driver support fail at runtime (for example, some APIs, or PTX JIT compilation of code produced by a newer toolkit). Alternatively, on supported data-center GPUs, the **CUDA forward compatibility package** (`cuda-compat`) provides a newer user-mode driver on top of an older kernel module. The clean fix is to upgrade the driver. See https://docs.nvidia.com/deploy/cuda-compatibility/.

**2.3** `nvidia-smi` and DCGM use **NVML** (`libnvidia-ml.so`). CUDA applications load **`libcuda.so`** (the user-mode driver), usually indirectly through the CUDA runtime (`libcudart`).

**2.4** Compute capability describes the **GPU architecture** (8.0 = Ampere A100, 9.0 = Hopper H100, 8.9 = Ada L4/L40S) and therefore which instructions and features exist (for example, FP8 Tensor Cores on 8.9/9.0). The driver version is independent of it. Compilers (`nvcc` generating SASS/PTX for specific architectures), libraries that choose kernels per architecture (cuDNN, cuBLAS), and **TensorRT**, whose engines are architecture-specific, all care about it.

</details>

<details>
<summary><strong>Exercise 3 — Container Toolkit</strong></summary>

**3.1** From the **host**. The NVIDIA Container Runtime hook (driven by the toolkit) bind-mounts the host's driver user-space binaries and libraries, including `nvidia-smi`, into the container at creation time. Without `--gpus`, nothing is injected, so the binary does not exist in the image.

**3.2** (a) **Device nodes**: `/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-uvm`, and so on. (b) **Driver user-mode libraries and utilities**: `libcuda.so`, `libnvidia-ml.so`, `nvidia-smi`, and others. `libcudart` is part of the CUDA **toolkit/runtime**, not the driver. It is the application's dependency and is shipped *in the image*, as the CUDA base/runtime images and NGC containers do. That separation lets each container choose its own CUDA runtime version on a shared host driver.

**3.3** **CDI** (Container Device Interface) is a vendor-neutral, declarative spec (a YAML/JSON file under `/etc/cdi/`) that describes what to inject for a named device such as `nvidia.com/gpu=0`. It removes the need for runtime-specific hooks. Podman, containerd, and CRI-O can consume it natively, and it makes GPU injection more consistent across engines and in Kubernetes.

**3.4** The user-mode driver libraries in the image must exactly match the kernel module version loaded on *each* host. Any host with a different driver version fails with mismatch errors (`Failed to initialize NVML: Driver/library version mismatch`). It also ties every image rebuild to driver upgrades and conflicts with the files the toolkit injects. The correct pattern: driver on the host (or managed by the GPU Operator's driver container), CUDA runtime and libraries in the image.

</details>

<details>
<summary><strong>Exercise 4 — NGC framework containers</strong></summary>

**4.1** CUDA runtime 12.6, cuDNN 9.3, and NCCL 2.22 all come from the **image**. The **host** contributes only the kernel module and the driver user-mode libraries (`libcuda`, NVML) injected by the Container Toolkit, plus the device nodes.

**4.2** Benefits of NGC framework containers:
- A **tested, version-matched** combination of framework + CUDA + cuDNN + NCCL + TensorRT + DALI and others, documented in the support matrix.
- **NVIDIA-specific optimizations and patches** not always in upstream wheels.
- **Monthly cadence** with release notes, plus security scanning.
- **Reproducibility and portability**: the same image runs on a workstation, DGX, cloud, or Kubernetes.
- With AI Enterprise, **production/long-term branches and support**.

**4.3** PyTorch `DataLoader` workers exchange tensors through shared memory (`/dev/shm`), and Docker's default is only 64 MB. Too little shared memory causes `bus error` or `DataLoader worker ... killed` errors. **NCCL** also uses shared memory for intra-node communication paths between processes on the same host.

**4.4** **CUDA minor version compatibility** (and, on data-center GPUs, the **forward compatibility package** included in NGC images, used automatically when needed and supported). Workloads that need **PTX JIT compilation** with a PTX newer than the driver supports, or that use APIs introduced in the newer minor release, can fail. The NGC containers' release notes state the minimum driver version. Following it is the recommended practice.

**4.5** Pretrained **models** (checkpoints), **Helm charts**, **resources** (scripts, sample code, Jupyter notebooks, recipes), and **NIM** microservices. SDKs and collections bundle related assets together.

</details>

<details>
<summary><strong>Exercise 5 — GPU Operator</strong></summary>

**5.1**
- `nvidia-driver-daemonset` (absent here): **driver**, containerized.
- `nvidia-container-toolkit-daemonset`: **container runtime integration**; configures containerd/CRI-O.
- `nvidia-device-plugin-daemonset`: **resource advertisement**; registers `nvidia.com/gpu` with the kubelet.
- `gpu-feature-discovery` + `node-feature-discovery-*`: **node labeling** (`nvidia.com/gpu.product`, memory, count, MIG profile, CUDA version...).
- `nvidia-dcgm-exporter`: **monitoring**; Prometheus metrics from DCGM.
- `nvidia-operator-validator` + `nvidia-cuda-validator`: **validation**; they confirm the driver, toolkit, and a CUDA workload run before the node is marked ready for GPU pods.
- `gpu-operator-*`: the **controller** that reconciles `ClusterPolicy`.

**5.2** The installation used `--set driver.enabled=false` because the driver was preinstalled on the host. Leave `driver.enabled=true` when nodes are generic or immutable images *without* NVIDIA drivers, so the Operator deploys a driver container per node. This is useful for fleet uniformity and for driver upgrades driven from Kubernetes.

**5.3** The **NVIDIA device plugin** advertises `nvidia.com/gpu`. **GPU Feature Discovery** (on top of Node Feature Discovery) creates the `nvidia.com/gpu.product` label.

**5.4** No. Extended resources are integers; fractions are rejected. Sharing options:
- **MIG** (Multi-Instance GPU, on A100/H100/and similar): hardware partitioning with isolated memory and compute. With the `mixed` strategy, partitions appear as their own resources (for example `nvidia.com/mig-1g.10gb`). With the `single` strategy, they appear as `nvidia.com/gpu`.
- **Time-slicing** (device plugin config): one GPU is advertised as N replicas of `nvidia.com/gpu`. It gives no memory or fault isolation.
- **MPS** (Multi-Process Service): concurrent kernels from multiple processes. It is also exposed through device plugin sharing config.
- **vGPU** in virtualized environments.

**5.5** Declarative, version-consistent, self-healing management of the **entire** node stack (driver, toolkit, plugin, monitoring, MIG manager, validation) from one CR, with Helm upgrades. New nodes join with the right stack automatically, configuration drift between nodes disappears, and it integrates with GitOps.

</details>

<details>
<summary><strong>Exercise 6 — DCGM</strong></summary>

**6.1** DCGM adds: a long-running host engine with low-overhead **continuous collection**; **GPU groups** and fleet-wide operations; **active diagnostics** (`dcgmi diag`); **health watches** and **policies** (for example, actions on XID or ECC events); **job statistics** per workload; profiling metrics (Tensor Core activity, SM occupancy, NVLink/PCIe throughput); and integrations (dcgm-exporter for Prometheus/Grafana, and the bindings used by cluster managers). `nvidia-smi` is an interactive point-in-time tool.

**6.2** Level 1 (`-r 1`) is a quick **deployment/software** check (seconds), suitable before scheduling jobs or in health checks. Level 3 (`-r 3`) adds long **stress tests** (memory, PCIe bandwidth, targeted power/stress, diagnostic kernels) and takes many minutes. Run it on node intake (burn-in), after hardware replacement, or when you suspect a faulty GPU. Never run it on a node serving production work.

**6.3** No. `GPU_UTIL` only reports the fraction of time *at least one kernel* was running. A memory-bound or poorly batched job can show 100% while using few SMs or Tensor Cores. Use DCGM **profiling metrics**: `DCGM_FI_PROF_SM_ACTIVE`, `DCGM_FI_PROF_SM_OCCUPANCY`, `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE`, `DCGM_FI_PROF_DRAM_ACTIVE`.

**6.4** In a YAML block scalar (`|`), the indentation of the first line sets the block's level. A line indented *less* ends the scalar, and a following line like `/` would then be parsed as YAML (and fail). Keeping every line at the same or greater indentation keeps the whole PromQL expression as one string.

</details>

<details>
<summary><strong>Exercise 7 — Inference</strong></summary>

**7.1** TensorRT parses the model (for example, from ONNX) and builds an **engine**. It fuses layers and tensors, chooses precisions (FP32/FP16/INT8/FP8, with calibration), auto-tunes kernels for the **specific GPU**, optimizes memory reuse, and supports dynamic shapes through optimization profiles. Because kernel selection and tuning target the exact architecture (and are tied to the TensorRT version), a plan built on an A100 (SM 8.0) is not portable to an L4 (SM 8.9) or an H100 (SM 9.0) unless you use hardware-compatibility build options. The standard practice is to build per target GPU type, or let NIM/Triton tooling select prebuilt engines per GPU.

**7.2** `dynamic_batching` lets Triton gather individual requests into server-side batches, increasing GPU throughput. `instance_group.count: 2` runs two copies of the model on the GPU, so independent requests run concurrently and overlap with data transfer. Increasing `max_queue_delay_microseconds` lets Triton wait longer to build larger batches: **more throughput, more tail latency**. Tune it against your latency SLO.

**7.3** **8000**: HTTP/REST (KServe v2 inference protocol, health, model metadata). **8001**: gRPC (same protocol, lower overhead). **8002**: Prometheus **metrics**. A `readinessProbe` uses `httpGet` on port 8000, path `/v2/health/ready`. A `livenessProbe` uses `/v2/health/live`.

**7.4** Enterprises have models from different teams and frameworks. A single server with multiple backends gives one **operational surface**: the same API, metrics, scaling, batching, and model management. It avoids running a separate serving stack per framework, and it allows **model ensembles/pipelines** that combine, for example, Python pre-processing with a TensorRT model.

**7.5** A NIM is a **prebuilt, supported microservice** that bundles: an optimized inference engine (TensorRT-LLM, vLLM, or Triton, depending on the model and GPU); the model weights or a mechanism to fetch them; **automatic selection of optimized profiles for the detected GPU**; an industry-standard API (OpenAI-compatible for LLMs); health and metrics endpoints; and enterprise support under AI Enterprise. With "Triton + your model", you are responsible for export, optimization, engine builds per GPU, configuration, API design, and patching.

</details>

<details>
<summary><strong>Exercise 8 — Scenario classification</strong></summary>

1. **NCCL** over NVLink/NVSwitch inside nodes and InfiniBand/RoCE with **GPUDirect RDMA** (Magnum IO) between nodes, in an NGC framework container (PyTorch DDP/FSDP, or NeMo/Megatron for large models). NCCL picks topology-aware algorithms. GPUDirect RDMA lets the NIC read GPU memory without going through the CPU.
2. **RAPIDS** (cuDF, which can be used with minimal or no code changes through `cudf.pandas`; Dask for multi-GPU; RAPIDS Accelerator for Apache Spark if the team uses Spark). It moves ETL to the GPU and avoids CPU bottlenecks.
3. **NVIDIA AI Enterprise**: licensed, supported, with production and long-term support branches, security patching, and certified platforms.
4. **NVIDIA Base Command Manager**: cluster provisioning, OS images, workload manager integration (Slurm, Kubernetes), monitoring.
5. **DCGM** (health watches, ECC/XID policies, diagnostics) exported through **dcgm-exporter** to Prometheus with alerts. Combine it with job scheduler integration to drain the node before it fails.
6. **NVIDIA NIM** for the LLM (optimized, OpenAI-compatible API), on-prem on Kubernetes (GPU Operator, NIM Operator/Helm), under **AI Enterprise** for support.
7. **NVIDIA NeMo** (framework for building and customizing models, fine-tuning such as LoRA/SFT, and NeMo Guardrails), then deployment as a NIM or on Triton.
8. **GPUDirect Storage** (part of **Magnum IO**), with supported filesystems/storage. It creates a direct DMA path between storage and GPU memory without the CPU bounce buffer.
9. **NVIDIA DOCA** on **BlueField DPUs**.
10. A **CUDA version compatibility** problem: the container's CUDA runtime requires a newer driver than the host has. See 8.1.

**8.1** In order of preference for production:
1. **Upgrade the host driver** to a version that meets the container's minimum (stated in the NGC container release notes and the support matrix), preferably with the GPU Operator through a controlled rolling upgrade, or with Base Command Manager images.
2. If the driver cannot be upgraded right away, **use a container release that matches the current driver**, or, on supported data-center GPUs, rely on the **CUDA forward compatibility package**.

Downgrading the container is not always right because the newer image may carry required **features, performance improvements, or security fixes**. Pinning old images to an old driver accumulates technical debt across the fleet. The sustainable fix is a driver lifecycle policy aligned with the framework release cadence, such as an AI Enterprise production branch.

</details>