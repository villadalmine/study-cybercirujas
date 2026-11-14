# Guided Exercises — Topic 1.6: Explain the Purpose and Use Case of Various NVIDIA Solutions

> **Exam weight:** 4.75% · **Certification:** NCA-AIIO (AI Infrastructure and Operations)
>
> These exercises take you through the NVIDIA stack from the silicon up: hardware and interconnects, system software, cluster orchestration, the inference toolchain (TensorRT → Triton → NIM), and the domain-specific frameworks. The hands-on blocks show you what each product actually *does*. The scenario blocks train the "which solution fits this problem?" reasoning that the exam tests.

---

## Lab prerequisites

| Track | What you need | Exercises |
|---|---|---|
| **A: Single GPU host** | Linux, NVIDIA GPU (Turing or newer; Ampere/Hopper for MIG), NVIDIA driver, Docker, NVIDIA Container Toolkit | 1, 2, 3, 4, 5, 6 |
| **B: Kubernetes** | Cluster with at least one GPU worker node, `kubectl`, `helm` ≥ 3 | 7, 8, 9 |
| **C: No GPU** | Paper and a browser | 1, 10 (plus all the questions) |

You need an **NGC API key** (https://ngc.nvidia.com → *Setup* → *Generate API Key*) for Exercises 3–6.

**Version alignment rule.** NGC containers released in the same month (`YY.MM`) share the same CUDA, cuDNN and TensorRT versions. TensorRT engines are **not portable** across TensorRT versions or GPU architectures, so every container in this lab must use the **same release tag**:

```bash
# Pick the latest monthly release listed at https://catalog.ngc.nvidia.com/orgs/nvidia/containers/tritonserver
export RELEASE=24.12
export NGC_API_KEY=<your-key>
```

---

## Exercise 1: Map the NVIDIA stack to its layers (paper)

### Steps

1. Draw five horizontal layers on paper, bottom to top:
   1. **Hardware & interconnect**
   2. **System software & libraries**
   3. **Infrastructure management & orchestration**
   4. **AI development & deployment platforms**
   5. **Domain-specific application frameworks**

2. Place each of the following products in **exactly one** layer:

   `DGX H100/B200` · `HGX` · `Grace Hopper Superchip` · `BlueField-3 DPU` · `ConnectX-7` · `Quantum InfiniBand` · `Spectrum-X Ethernet` · `NVLink / NVSwitch` · `CUDA` · `cuDNN` · `NCCL` · `DCGM` · `GPUDirect Storage (Magnum IO)` · `DOCA` · `GPU Operator` · `Network Operator` · `Base Command Manager` · `Run:ai` · `Fleet Command` · `NGC` · `NVIDIA AI Enterprise` · `TensorRT` · `TensorRT-LLM` · `Triton Inference Server` · `NIM` · `NeMo` · `RAPIDS` · `TAO Toolkit` · `Riva` · `DeepStream / Metropolis` · `Morpheus` · `Clara` · `Merlin` · `Omniverse`

3. Draw an arrow from **NVIDIA AI Enterprise** to every product it licenses and supports. Draw another from **NGC** to every product you can download from it as a container, Helm chart or model.

### Questions

- **Q1.1** Why is DOCA in a different layer from BlueField, when DOCA is useless without a BlueField?
- **Q1.2** NGC and NVIDIA AI Enterprise both "give you NVIDIA software". What is the operational difference between them?
- **Q1.3** TensorRT, Triton and NIM all relate to inference. Write one sentence for each that explains the *distinct* job it does.
- **Q1.4** Which two products in the list exist mainly to make **Kubernetes** treat GPUs and high-speed NICs as first-class resources?

---

## Exercise 2: Look at the hardware through the driver (Track A)

### Steps

1. Identify the GPUs, the driver and the maximum supported CUDA version:

   ```bash
   nvidia-smi
   ```

   Expected (abbreviated, values vary):

   ```
   +-----------------------------------------------------------------------------------------+
   | NVIDIA-SMI 560.35.03              Driver Version: 560.35.03      CUDA Version: 12.6     |
   |-----------------------------------------+------------------------+----------------------+
   | GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
   |   0  NVIDIA H100 80GB HBM3          On  |   00000000:18:00.0 Off |                    0 |
   ...
   ```

2. Inspect the interconnect topology between GPUs and NICs:

   ```bash
   nvidia-smi topo -m
   ```

   Illustrative output on an 8-GPU HGX/DGX node (truncated):

   ```
           GPU0    GPU1    GPU2    GPU3    NIC0    CPU Affinity    NUMA Affinity
   GPU0     X      NV18    NV18    NV18    PXB     0-55            0
   GPU1    NV18     X      NV18    NV18    PXB     0-55            0
   GPU2    NV18    NV18     X      NV18    SYS     0-55            0
   ...
   Legend:
     NV#  = Connection traversing a bonded set of # NVLinks
     PIX  = Connection traversing at most a single PCIe bridge
     PXB  = Connection traversing multiple PCIe bridges
     SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes
   ```

3. If your GPUs have NVLink, check link state and speed:

   ```bash
   nvidia-smi nvlink -s
   ```

4. (Optional, only if the GPUDirect Storage package is installed) Check whether the platform supports GDS:

   ```bash
   /usr/local/cuda/gds/tools/gdscheck -p
   ```

   Look for lines like `NVMe : Supported` and `GDS release version`.

### Questions

- **Q2.1** The header shows `CUDA Version: 12.6`. Does this mean CUDA 12.6 is installed on the host? What does it actually tell you?
- **Q2.2** In the topology matrix, GPU0↔GPU1 is `NV18` and GPU2↔NIC0 is `SYS`. Which pair will achieve higher all-reduce bandwidth, and why does NCCL care?
- **Q2.3** On a DGX H100, GPU-to-GPU traffic *inside* a node goes over NVLink/NVSwitch. What carries GPU-to-GPU traffic *between* nodes in a DGX SuperPOD, and which NVIDIA product families make it up?
- **Q2.4** What problem does GPUDirect Storage solve, and which part of the classic data path does it remove?

---

## Exercise 3: Consume the stack from NGC (Track A)

### Steps

1. Log in to the NGC registry. The username is literally `$oauthtoken`:

   ```bash
   echo "$NGC_API_KEY" | docker login nvcr.io -u '$oauthtoken' --password-stdin
   ```

   Expected: `Login Succeeded`

2. Start the NGC PyTorch container and print the versions of the CUDA-X libraries it bundles:

   ```bash
   docker run --rm --gpus all nvcr.io/nvidia/pytorch:${RELEASE}-py3 \
     python -c "import torch; print('torch', torch.__version__); print('cuda', torch.version.cuda); print('cudnn', torch.backends.cudnn.version()); print('nccl', torch.cuda.nccl.version()); print('gpu', torch.cuda.get_device_name(0))"
   ```

   Illustrative output:

   ```
   torch 2.6.0a0+df5bbc09d1.nv24.12
   cuda 12.6
   cudnn 90501
   nccl (2, 23, 4)
   gpu NVIDIA H100 80GB HBM3
   ```

3. Compare the result with the release notes for the same tag in the NGC Frameworks Support Matrix (https://docs.nvidia.com/deeplearning/frameworks/support-matrix/).

### Questions

- **Q3.1** The host driver reported CUDA 12.6 in Exercise 2. The container could ship a different CUDA toolkit. Which component inside the container talks to the host driver, and who injects the driver libraries into the container?
- **Q3.2** Give three reasons an enterprise team would standardize on NGC containers instead of `pip install torch` on bare metal.
- **Q3.3** What is NCCL used for, and in which training topology does it become critical?

---

## Exercise 4: Optimize a model with TensorRT (Track A)

### Steps

1. Create a working directory and export a ResNet-50 to ONNX with a **dynamic batch dimension**. Random weights are fine because you are measuring performance, not accuracy:

   ```bash
   mkdir -p ~/nvlab && cd ~/nvlab
   cat > export.py <<'EOF'
   import torch, torchvision
   model = torchvision.models.resnet50(weights=None).eval().cuda()
   dummy = torch.randn(1, 3, 224, 224, device="cuda")
   torch.onnx.export(
       model, dummy, "resnet50.onnx",
       input_names=["input"], output_names=["output"],
       dynamic_axes={"input": {0: "batch"}, "output": {0: "batch"}},
       opset_version=17,
   )
   print("exported resnet50.onnx")
   EOF
   docker run --rm --gpus all -v "$PWD":/work -w /work \
     nvcr.io/nvidia/pytorch:${RELEASE}-py3 python export.py
   ```

2. Build an **FP32** engine and benchmark it with `trtexec`. If `trtexec` is not on `PATH`, use `/usr/src/tensorrt/bin/trtexec`:

   ```bash
   docker run --rm --gpus all -v "$PWD":/work -w /work \
     nvcr.io/nvidia/tensorrt:${RELEASE}-py3 \
     trtexec --onnx=resnet50.onnx \
       --minShapes=input:1x3x224x224 --optShapes=input:8x3x224x224 --maxShapes=input:8x3x224x224 \
       --shapes=input:8x3x224x224 \
       --saveEngine=resnet50_fp32.plan
   ```

3. Build an **FP16** engine with the same shapes:

   ```bash
   docker run --rm --gpus all -v "$PWD":/work -w /work \
     nvcr.io/nvidia/tensorrt:${RELEASE}-py3 \
     trtexec --onnx=resnet50.onnx \
       --minShapes=input:1x3x224x224 --optShapes=input:8x3x224x224 --maxShapes=input:8x3x224x224 \
       --shapes=input:8x3x224x224 \
       --fp16 --saveEngine=resnet50_fp16.plan
   ```

4. Record the summary lines from each run. Illustrative output:

   ```
   [I] === Performance summary ===
   [I] Throughput: 1843.27 qps
   [I] Latency: min = 0.52 ms, max = 0.71 ms, mean = 0.54 ms, median = 0.54 ms, percentile(90%) = 0.55 ms, percentile(95%) = 0.56 ms, percentile(99%) = 0.60 ms
   ...
   &&&& PASSED TensorRT.trtexec [TensorRT v100700]
   ```

   Fill in this table. The `qps` value counts *batches* per second here, so multiply by 8 for images/s.

   | Precision | Throughput (qps) | Images/s | Median latency (ms) | Engine size (`ls -lh`) |
   |---|---|---|---|---|
   | FP32 | | | | |
   | FP16 | | | | |

### Questions

- **Q4.1** List at least four optimizations TensorRT performs while it builds the engine.
- **Q4.2** Why did FP16 speed things up so much on a Volta-or-newer GPU? What hardware unit does it exploit?
- **Q4.3** You build `resnet50_fp16.plan` on an H100 and copy it to an L4 server. What happens, and what is the correct practice?
- **Q4.4** INT8 or FP8 would be faster still. What extra step does INT8 normally need that FP16 does not?
- **Q4.5** For a large language model, would you use plain TensorRT or TensorRT-LLM? Name two LLM-specific features that justify the difference.

---

## Exercise 5: Serve the engine with Triton Inference Server (Track A)

### Steps

1. Build a model repository. Triton requires the layout `<repo>/<model>/<version>/<file>`, and a TensorRT engine must be named `model.plan`:

   ```bash
   mkdir -p model_repository/resnet50/1
   cp resnet50_fp16.plan model_repository/resnet50/1/model.plan
   ```

2. Write the model configuration. This file is protobuf text format, not YAML:

   ```bash
   cat > model_repository/resnet50/config.pbtxt <<'EOF'
   name: "resnet50"
   platform: "tensorrt_plan"
   max_batch_size: 8
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
       count: 1
       kind: KIND_GPU
     }
   ]
   EOF
   ```

3. Start Triton. Port 8000 serves HTTP/REST, 8001 serves gRPC and 8002 serves Prometheus metrics:

   ```bash
   docker run -d --name triton --gpus all \
     -p 8000:8000 -p 8001:8001 -p 8002:8002 \
     -v "$PWD/model_repository":/models \
     nvcr.io/nvidia/tritonserver:${RELEASE}-py3 \
     tritonserver --model-repository=/models
   docker logs -f triton   # wait for: Started HTTPService at 0.0.0.0:8000
   ```

   In the logs, look for the model table:

   ```
   +----------+---------+--------+
   | Model    | Version | Status |
   +----------+---------+--------+
   | resnet50 | 1       | READY  |
   +----------+---------+--------+
   ```

4. Probe readiness and the model metadata (KServe v2 protocol):

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' localhost:8000/v2/health/ready
   curl -s localhost:8000/v2/models/resnet50
   ```

   Expected: `200`, then:

   ```json
   {"name":"resnet50","versions":["1"],"platform":"tensorrt_plan","inputs":[{"name":"input","datatype":"FP32","shape":[-1,3,224,224]}],"outputs":[{"name":"output","datatype":"FP32","shape":[-1,1000]}]}
   ```

5. Load-test **without** dynamic batching. Each client sends batch size 1:

   ```bash
   docker run --rm --net=host nvcr.io/nvidia/tritonserver:${RELEASE}-py3-sdk \
     perf_analyzer -m resnet50 -b 1 --concurrency-range 1:16:4
   ```

   Illustrative output:

   ```
   Concurrency: 1, throughput: 610.2 infer/sec, latency 1630 usec
   Concurrency: 5, throughput: 1190.4 infer/sec, latency 4190 usec
   Concurrency: 9, throughput: 1215.8 infer/sec, latency 7390 usec
   Concurrency: 13, throughput: 1221.0 infer/sec, latency 10640 usec
   ```

6. Enable dynamic batching. Append this to `config.pbtxt`, then restart Triton and repeat step 5:

   ```bash
   cat >> model_repository/resnet50/config.pbtxt <<'EOF'
   dynamic_batching {
     preferred_batch_size: [ 4, 8 ]
     max_queue_delay_microseconds: 100
   }
   EOF
   docker restart triton
   ```

7. Look at the server-side metrics:

   ```bash
   curl -s localhost:8002/metrics | grep -E '^nv_inference_(request_success|exec_count|count)'
   ```

   Compare `nv_inference_count` (inferences) with `nv_inference_exec_count` (batched executions).

### Questions

- **Q5.1** In step 6, how did throughput change at concurrency ≥ 5, and what did it cost in latency? Explain the mechanism.
- **Q5.2** After step 6, `nv_inference_count` is much larger than `nv_inference_exec_count`. What does the ratio represent?
- **Q5.3** Triton served a TensorRT engine here. Name four other backends it supports, and explain why a multi-framework server matters in an enterprise.
- **Q5.4** Why did the lab insist that the TensorRT container and the Triton container use the same `${RELEASE}`?
- **Q5.5** How would you use `instance_group` to raise utilization on a GPU that sits at 40% under load?
- **Q5.6** Which Triton feature would you use to chain *preprocessing → model → postprocessing* on the server, without client round-trips?

---

## Exercise 6: Deploy an LLM in minutes with NVIDIA NIM (Track A, ≥ 24 GB GPU memory)

### Steps

1. List the optimized profiles that the NIM ships for **your** GPU:

   ```bash
   docker run --rm --gpus all -e NGC_API_KEY \
     nvcr.io/nim/meta/llama-3.1-8b-instruct:latest list-model-profiles
   ```

   Illustrative output (abbreviated):

   ```
   SYSTEM INFO
   - Free GPUs:
     -  [2330:10de] (0) NVIDIA H100 80GB HBM3 (H100 80GB) [current utilization: 0%]
   MODEL PROFILES
   - Compatible with system and runnable:
     - 3bb4e8fe... (tensorrt_llm-h100-fp8-tp1-throughput)
     - 8835c31... (tensorrt_llm-h100-bf16-tp1-latency)
     - 193649a... (vllm-bf16-tp1)
   ```

2. Run the NIM with a persistent model cache:

   ```bash
   export LOCAL_NIM_CACHE=~/.cache/nim
   mkdir -p "$LOCAL_NIM_CACHE"
   docker run -d --name nim-llm --gpus all --shm-size=16GB \
     -e NGC_API_KEY \
     -v "$LOCAL_NIM_CACHE:/opt/nim/.cache" \
     -u "$(id -u)" \
     -p 8000:8000 \
     nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
   docker logs -f nim-llm   # wait for: Uvicorn running on http://0.0.0.0:8000
   ```

   > If Triton from Exercise 5 is still running, stop it first (`docker rm -f triton`), because both use port 8000.

3. Query it with the **OpenAI-compatible** API:

   ```bash
   curl -s localhost:8000/v1/models
   curl -s localhost:8000/v1/chat/completions \
     -H "Content-Type: application/json" \
     -d '{"model": "meta/llama-3.1-8b-instruct", "messages": [{"role": "user", "content": "In one sentence, what does NVLink do?"}], "max_tokens": 64}'
   ```

   Illustrative response (truncated):

   ```
   {"id":"chat-1f2e...","object":"chat.completion","model":"meta/llama-3.1-8b-instruct","choices":[{"index":0,"message":{"role":"assistant","content":"NVLink is a high-bandwidth, low-latency interconnect that lets GPUs exchange data directly..."},"finish_reason":"stop"}],"usage":{"prompt_tokens":21,"completion_tokens":38,"total_tokens":59}}
   ```

4. Stop the container and start it again. Measure how long it takes to reach "ready" with a warm cache:

   ```bash
   docker rm -f nim-llm
   time (docker run -d --name nim-llm --gpus all --shm-size=16GB -e NGC_API_KEY \
     -v "$LOCAL_NIM_CACHE:/opt/nim/.cache" -u "$(id -u)" -p 8000:8000 \
     nvcr.io/nim/meta/llama-3.1-8b-instruct:latest >/dev/null; \
     until curl -sf localhost:8000/v1/health/ready >/dev/null; do sleep 2; done)
   ```

### Questions

- **Q6.1** The NIM chose a `tensorrt_llm-h100-fp8-tp1-throughput` profile without you building anything. Relate this to what you did by hand in Exercises 4 and 5.
- **Q6.2** Why does an OpenAI-compatible API matter to the application team adopting it?
- **Q6.3** What does `tp1` mean in the profile name, and what would `tp2` need from the hardware?
- **Q6.4** Under which product does NVIDIA offer production support for NIM?
- **Q6.5** The LLM blog in the sources lists use cases such as content generation, summarization, chatbots, code generation and translation. A team wants a chatbot grounded in their internal documents. Which NVIDIA framework would they use to *customize* or *guard* the model, and which pattern avoids retraining altogether?

---

## Exercise 7: Make Kubernetes GPU-aware with the GPU Operator (Track B)

### Steps

1. Install the GPU Operator from the NGC Helm repository:

   ```bash
   helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
   helm install --wait --generate-name \
     -n gpu-operator --create-namespace \
     nvidia/gpu-operator
   ```

   > If the nodes already have an NVIDIA driver installed (for example, a managed cloud node image), add `--set driver.enabled=false`.

2. Watch the components come up:

   ```bash
   kubectl get pods -n gpu-operator
   ```

   Illustrative output:

   ```
   NAME                                                READY   STATUS      RESTARTS   AGE
   gpu-feature-discovery-x7k2p                         1/1     Running     0          4m
   gpu-operator-6d8f9c7b5-jq2lm                        1/1     Running     0          5m
   gpu-operator-node-feature-discovery-master-...      1/1     Running     0          5m
   gpu-operator-node-feature-discovery-worker-...      1/1     Running     0          5m
   nvidia-container-toolkit-daemonset-4wq8n            1/1     Running     0          4m
   nvidia-cuda-validator-hn6tz                         0/1     Completed   0          3m
   nvidia-dcgm-exporter-t9r4c                          1/1     Running     0          4m
   nvidia-device-plugin-daemonset-k5vbd                1/1     Running     0          4m
   nvidia-driver-daemonset-zp8f2                       1/1     Running     0          5m
   nvidia-operator-validator-ld7xs                     1/1     Running     0          4m
   ```

3. Check what the node now advertises:

   ```bash
   NODE=<your-gpu-node>
   kubectl get node "$NODE" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
   kubectl get node "$NODE" --show-labels | tr ',' '\n' | grep -E 'nvidia.com/(gpu.product|gpu.memory|cuda.driver.major|gpu.count)'
   ```

   Illustrative output:

   ```
   1
   nvidia.com/cuda.driver.major=560
   nvidia.com/gpu.count=1
   nvidia.com/gpu.memory=81559
   nvidia.com/gpu.product=NVIDIA-H100-80GB-HBM3
   ```

4. Run a GPU workload. Save this as `cuda-vectoradd.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: cuda-vectoradd
   spec:
     restartPolicy: OnFailure
     containers:
       - name: cuda-vectoradd
         image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1-ubuntu20.04
         resources:
           limits:
             nvidia.com/gpu: 1
   ```

   ```bash
   kubectl apply -f cuda-vectoradd.yaml
   kubectl logs pod/cuda-vectoradd
   ```

   Expected:

   ```
   [Vector addition of 50000 elements]
   Copy input data from the host memory to the CUDA device
   CUDA kernel launch with 196 blocks of 256 threads
   Copy output data from the CUDA device to the host memory
   Test PASSED
   Done
   ```

### Questions

- **Q7.1** For each of these DaemonSets, state in one line what it does: driver, container-toolkit, device-plugin, gpu-feature-discovery, dcgm-exporter, operator-validator.
- **Q7.2** Without the GPU Operator, what would an operations team have to do manually on every GPU node, and why does that break down at 200 nodes?
- **Q7.3** How would you use the `nvidia.com/gpu.product` label in a Deployment, and why might you need it?
- **Q7.4** The GPU Operator handles GPUs. Which sibling operator handles ConnectX NICs, RDMA and SR-IOV for multi-node training on Kubernetes?
- **Q7.5** The device plugin advertises whole GPUs as an integer resource. What would happen if you requested `nvidia.com/gpu: 0.5`?

---

## Exercise 8: Observe GPUs with DCGM (Track B, optional Track A)

### Steps

1. Read the raw metrics from DCGM Exporter:

   ```bash
   kubectl -n gpu-operator port-forward svc/nvidia-dcgm-exporter 9400:9400 &
   curl -s localhost:9400/metrics | grep -E '^DCGM_FI_DEV_(GPU_UTIL|FB_USED|FB_FREE|GPU_TEMP|POWER_USAGE|XID_ERRORS)'
   ```

   Illustrative output:

   ```
   DCGM_FI_DEV_GPU_TEMP{gpu="0",UUID="GPU-5a1c...",device="nvidia0",modelName="NVIDIA H100 80GB HBM3",Hostname="gpu-node-1"} 34
   DCGM_FI_DEV_POWER_USAGE{gpu="0",...} 71.2
   DCGM_FI_DEV_GPU_UTIL{gpu="0",...} 0
   DCGM_FI_DEV_FB_FREE{gpu="0",...} 81004
   DCGM_FI_DEV_FB_USED{gpu="0",...} 555
   DCGM_FI_DEV_XID_ERRORS{gpu="0",...} 0
   ```

2. If you run the Prometheus Operator, create alerting rules. Save this as `gpu-alerts.yaml`:

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
             expr: DCGM_FI_DEV_GPU_TEMP > 85
             for: 5m
             labels:
               severity: warning
             annotations:
               summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} is above 85C"
           - alert: GPUFramebufferNearlyFull
             expr: |
               DCGM_FI_DEV_FB_USED
               / (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE) > 0.95
             for: 10m
             labels:
               severity: warning
             annotations:
               summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} framebuffer above 95%"
           - alert: GPUXidError
             expr: DCGM_FI_DEV_XID_ERRORS > 0
             for: 0m
             labels:
               severity: critical
             annotations:
               summary: "XID error {{ $value }} on GPU {{ $labels.gpu }} ({{ $labels.Hostname }})"
   ```

   ```bash
   kubectl apply -f gpu-alerts.yaml
   ```

3. (Track A, with the DCGM package on the host) Run a quick health diagnostic:

   ```bash
   dcgmi discovery -l
   dcgmi diag -r 1
   ```

   Illustrative output (abbreviated):

   ```
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
   ...
   ```

### Questions

- **Q8.1** `DCGM_FI_DEV_GPU_UTIL` reads 100% but training is still slow. Why can "utilization" mislead, and which DCGM profiling fields give a truer picture?
- **Q8.2** What is an XID error, and what is a reasonable first operational response to a non-zero `DCGM_FI_DEV_XID_ERRORS`?
- **Q8.3** What is the difference between `dcgmi diag -r 1` and `-r 3`, and when would you run the longer one?
- **Q8.4** `nvidia-smi` and DCGM both report GPU state. Why does a data center use DCGM rather than scraping `nvidia-smi`?

---

## Exercise 9: Share GPUs with MIG and time-slicing (Track B; MIG needs A100/A30/H100/H200/B200)

### Steps

1. **Time-slicing.** Save this as `time-slicing.yaml`:

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

   ```bash
   kubectl apply -f time-slicing.yaml
   kubectl patch clusterpolicies.nvidia.com/cluster-policy --type merge \
     -p '{"spec": {"devicePlugin": {"config": {"name": "time-slicing-config", "default": "any"}}}}'
   sleep 60
   kubectl get node "$NODE" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
   ```

   Expected: allocatable goes from `1` to `4` per physical GPU, and the label `nvidia.com/gpu.replicas=4` appears.

2. Revert time-slicing before you try MIG:

   ```bash
   kubectl patch clusterpolicies.nvidia.com/cluster-policy --type json \
     -p '[{"op": "remove", "path": "/spec/devicePlugin/config"}]'
   ```

3. **MIG** (MIG-capable GPU only). List the profiles from the host:

   ```bash
   nvidia-smi mig -lgip
   ```

   Illustrative output for an H100 80GB (abbreviated):

   ```
   | GPU instance profiles:                                                      |
   | GPU   Name             ID    Instances   Memory     P2P    SM    DEC   ENC  |
   |                              Free/Total   GiB              CE    JPEG  OFA  |
   |   0  MIG 1g.10gb       19     7/7        9.75       No     16     1     0   |
   |   0  MIG 2g.20gb       14     3/3        19.62      No     32     2     0   |
   |   0  MIG 3g.40gb        9     2/2        39.50      No     60     3     0   |
   |   0  MIG 7g.80gb        0     1/1        79.25      No     132    7     0   |
   ```

4. Let the GPU Operator's MIG Manager reconfigure the node. Use `single` strategy and `all-1g.10gb` on H100 80GB (use `all-1g.5gb` on A100 40GB):

   ```bash
   helm upgrade $(helm list -n gpu-operator -q) nvidia/gpu-operator -n gpu-operator \
     --reuse-values --set mig.strategy=single
   kubectl label node "$NODE" nvidia.com/mig.config=all-1g.10gb --overwrite
   kubectl get node "$NODE" -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}{"\n"}'
   kubectl get node "$NODE" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
   ```

   Expected: `success`, then `7`.

5. Revert:

   ```bash
   kubectl label node "$NODE" nvidia.com/mig.config=all-disabled --overwrite
   ```

### Questions

- **Q9.1** Both methods turned one GPU into several schedulable units. Compare them on memory isolation, fault isolation and QoS.
- **Q9.2** Which approach would you pick for (a) a dev cluster where data scientists run notebooks that mostly sit idle, and (b) a multi-tenant inference platform with latency SLAs?
- **Q9.3** What does NVIDIA vGPU add that neither MIG nor time-slicing provides on its own?
- **Q9.4** With `mig.strategy=mixed`, what resource names would a Pod request instead of `nvidia.com/gpu`?
- **Q9.5** Which NVIDIA product adds team quotas, fair-share scheduling and fractional GPU allocation *on top of* Kubernetes for many teams sharing one cluster?

---

## Exercise 10: Match the solution to the scenario (exam style, paper)

### Steps

1. For each scenario, write the **primary** NVIDIA solution and a one-line justification. More than one product may be involved, but name the one that *solves the stated problem*.

| # | Scenario |
|---|---|
| S1 | A retailer's ETL pipeline in pandas/Spark takes 6 hours to prepare features before every training run. |
| S2 | A bank wants to pretrain and then fine-tune a domain LLM, add guardrails, and evaluate it. |
| S3 | A call center needs real-time ASR and TTS in several languages, deployed on premises. |
| S4 | A city wants to analyze 2,000 camera streams for traffic incidents at the edge. |
| S5 | A telco needs to detect anomalous network behavior and leaked credentials in real time across petabytes of logs. |
| S6 | An e-commerce company wants GPU-accelerated recommender training and serving with large embedding tables. |
| S7 | A hospital imaging team needs medical imaging AI workflows and pretrained models. |
| S8 | A manufacturer wants a physically accurate digital twin of a factory to simulate robots. |
| S9 | A small team with no deep ML expertise wants to fine-tune a pretrained vision model for defect detection with little code. |
| S10 | 500 retail stores each have a small GPU server; IT must deploy and update AI apps remotely and securely. |
| S11 | A new 32-node GPU cluster must be provisioned (OS images, drivers, Slurm or Kubernetes, monitoring) from bare metal. |
| S12 | Training jobs on 64 GPUs spend 30% of each step waiting on reading data from the NFS share; CPUs are pegged copying buffers. |
| S13 | A cloud provider wants to offload network, storage and security processing from the host CPUs and isolate tenants at the infrastructure level. |
| S14 | A company builds an Ethernet-based AI fabric and wants InfiniBand-like performance for multi-tenant AI clouds. |
| S15 | Multi-node LLM pretraining requires the lowest latency, with in-network reductions between nodes. |
| S16 | An enterprise needs a supported, security-patched, certified AI software stack with an SLA for production. |
| S17 | Developers want to deploy a Llama model with an OpenAI-compatible endpoint in minutes, optimized for whatever GPU they have. |
| S18 | Several teams share a GPU cluster and complain that some hog GPUs while others queue; leadership wants quotas and fair share. |

2. For S12, use the storage-scaling blog in the sources to write **three** additional, non-GPUDirect mitigations.

### Questions

- **Q10.1** Which of the 18 scenarios would you also solve with **NVIDIA AI Enterprise** as the licensing/support vehicle, and why is AI Enterprise rarely the *direct* answer to a technical scenario?
- **Q10.2** S14 and S15 both concern the network fabric. State the deciding factor between Spectrum-X and Quantum InfiniBand.
- **Q10.3** For S2, which inference products would the bank use once the model is trained, and in which order did you meet them in this lab?

---

## Answers

<details>
<summary><strong>Exercise 1</strong></summary>

**Layer map (reference):**

| Layer | Products |
|---|---|
| Hardware & interconnect | DGX H100/B200, HGX, Grace Hopper, BlueField-3 DPU, ConnectX-7, Quantum InfiniBand, Spectrum-X Ethernet, NVLink/NVSwitch |
| System software & libraries | CUDA, cuDNN, NCCL, DCGM, GPUDirect Storage (Magnum IO), DOCA |
| Infra management & orchestration | GPU Operator, Network Operator, Base Command Manager, Run:ai, Fleet Command |
| AI development & deployment platforms | NGC, NVIDIA AI Enterprise, TensorRT, TensorRT-LLM, Triton, NIM, NeMo, RAPIDS, TAO |
| Domain frameworks | Riva, DeepStream/Metropolis, Morpheus, Clara, Merlin, Omniverse |

**Q1.1** BlueField is the hardware: a DPU with Arm cores, a ConnectX NIC and accelerators. DOCA is the **SDK/runtime** used to program and run services on it, in the same way CUDA is the software layer for the GPU. They sit in different layers because one is silicon and the other is the software that exposes it.

**Q1.2** **NGC** is the catalog/registry (containers, models, Helm charts, SDKs). Much of it is free to pull. **NVIDIA AI Enterprise** is the **commercial subscription**. It adds enterprise support, a validated/certified software stack, security patching (CVE remediation), long-term-support branches and API stability, and it entitles production use of products such as NIM. Many AI Enterprise components are *delivered through* NGC.

**Q1.3**
- **TensorRT** is the *compiler/optimizer and runtime* that turns a trained model into a GPU-specific, optimized engine.
- **Triton** is the *inference server* that hosts models from many frameworks behind HTTP/gRPC, with batching, concurrency, ensembles and metrics.
- **NIM** is a *prepackaged microservice* that bundles a specific model, its optimized engines (TensorRT-LLM/vLLM/Triton) and an industry-standard API into one container you can run in minutes.

**Q1.4** **GPU Operator** (GPUs) and **Network Operator** (ConnectX/BlueField NICs, RDMA, SR-IOV, GPUDirect RDMA).
</details>

<details>
<summary><strong>Exercise 2</strong></summary>

**Q2.1** No. It is the **highest CUDA version the installed driver supports**. The CUDA toolkit/runtime can be absent on the host and is usually shipped inside the container. The driver is backward compatible with older CUDA runtimes, and forward compatibility packages exist for some data center GPUs.

**Q2.2** GPU0↔GPU1 over `NV18`, which is 18 bonded NVLink lanes giving hundreds of GB/s. `SYS` crosses PCIe *and* the CPU socket interconnect, which is far slower and adds latency. NCCL reads this topology to build rings/trees for collectives (all-reduce, all-gather). Poor paths become the bottleneck for every gradient synchronization.

**Q2.3** The **compute fabric** of ConnectX NICs (one per GPU on DGX H100) connected by **NVIDIA Quantum InfiniBand** switches (or **Spectrum-X Ethernet** in Ethernet designs). It uses **GPUDirect RDMA** so NIC↔GPU memory transfers bypass the CPU. On GB200 NVL72 systems, NVLink Switch also extends NVLink across a rack.

**Q2.4** GDS creates a **direct DMA path between storage (local NVMe or remote NVMe-oF/parallel FS) and GPU memory**. It removes the **bounce buffer in CPU system memory** and the associated CPU copies. The results are higher bandwidth, lower latency and lower CPU load. GDS is part of the **Magnum IO** family.
</details>

<details>
<summary><strong>Exercise 3</strong></summary>

**Q3.1** The CUDA runtime/user-mode libraries in the container call into `libcuda.so`, the driver's user-mode component, which talks to the kernel driver. The **NVIDIA Container Toolkit** (`nvidia-container-runtime` / CDI) mounts the host's driver libraries and device nodes into the container at start, triggered by `--gpus all`.

**Q3.2** Any three of the following:
- NGC containers are **tested and tuned** together (framework + CUDA + cuDNN + NCCL + TensorRT).
- They are **updated monthly**, with published release notes and a support matrix.
- They give **reproducibility** across laptop, cluster and cloud.
- They include NVIDIA performance optimizations that are not always upstream.
- They are scanned for security, and some are covered by AI Enterprise support.
- They avoid driver/library "dependency hell" on bare metal.

**Q3.3** NCCL (NVIDIA Collective Communications Library) implements topology-aware multi-GPU/multi-node collectives (all-reduce, broadcast, all-gather, reduce-scatter) over NVLink, PCIe, InfiniBand and RoCE. It is critical in **data-parallel and model-parallel distributed training** (DDP, FSDP, Megatron), where gradients or shards must be synchronized every step.
</details>

<details>
<summary><strong>Exercise 4</strong></summary>

**Q4.1** Any four of the following:
- Layer and tensor **fusion** (for example conv+bias+ReLU).
- **Precision calibration/reduction** (FP16, BF16, INT8, FP8).
- **Kernel auto-tuning**, which selects the fastest kernels for the target GPU.
- Dynamic tensor **memory optimization/reuse**.
- Elimination of dead layers.
- **Multi-stream** execution.
- Optimization profiles for dynamic shapes.

**Q4.2** FP16 halves memory traffic and lets matrix math run on **Tensor Cores**, which deliver many times the FLOPS of FP32 CUDA cores. Convolutional networks like ResNet are dominated by GEMM/conv operations, so throughput typically rises by 2× or more.

**Q4.3** It fails to deserialize, or it is rejected, because engines are tied to the **GPU architecture/compute capability and the TensorRT version** (H100 is Hopper SM90 and L4 is Ada SM89). The correct practice is to keep the portable artifact (ONNX) and **build the engine on, or for, the target GPU**, ideally as part of the deployment pipeline. Hardware-compatibility build options exist but trade away some performance.

**Q4.4** **Calibration** with a representative dataset to compute activation ranges (post-training quantization), or quantization-aware training. Explicitly quantized ONNX with Q/DQ nodes is another path.

**Q4.5** **TensorRT-LLM.** It adds LLM-specific features such as:
- In-flight (continuous) batching
- Paged KV-cache
- Optimized attention kernels
- Tensor and pipeline parallelism across GPUs
- FP8/INT4 weight quantization
- Speculative decoding

Plain TensorRT does not handle autoregressive generation patterns efficiently.
</details>

<details>
<summary><strong>Exercise 5</strong></summary>

**Q5.1** Throughput rises significantly, often by close to 1.5–3× for this model, while latency at the same concurrency rises only slightly, by roughly up to `max_queue_delay_microseconds` plus the larger batch execution. Triton's scheduler **holds individual requests in a short queue and merges them into a larger batch**. Larger batches use the GPU's parallelism far better than many batch-1 executions.

**Q5.2** The **average batch size actually executed**, that is, inferences per GPU execution. A ratio near 1 means batching is not happening. A ratio close to `max_batch_size` means it is very effective.

**Q5.3** Any four of the following:
- PyTorch (LibTorch/TorchScript)
- ONNX Runtime
- TensorFlow
- OpenVINO
- Python backend
- vLLM
- TensorRT-LLM
- FIL (tree models: XGBoost/LightGBM)
- DALI

A single server gives the enterprise **one operational surface**: the same APIs, metrics, scaling and deployment process, regardless of which framework each data science team chose.

**Q5.4** Triton loads the `.plan` with its **bundled TensorRT runtime**. An engine serialized by a different TensorRT version fails to load. Matching NGC `YY.MM` tags guarantees matching versions.

**Q5.5** Increase `instance_group { count: 2 (or more) kind: KIND_GPU }` so that several copies of the model execute **concurrently** on the same GPU. This overlaps execution and data transfer and fills idle SMs. Re-measure with `perf_analyzer`, because more instances also use more GPU memory.

**Q5.6** **Ensemble models**, a DAG defined in `config.pbtxt`, or **Business Logic Scripting** in the Python backend for conditional logic or loops.
</details>

<details>
<summary><strong>Exercise 6</strong></summary>

**Q6.1** By hand, you exported to ONNX, built a TensorRT engine for your specific GPU and precision, wrote a Triton config and tuned batching. A NIM **ships prebuilt, pre-tuned engines** for many GPU/precision/parallelism combinations. At startup it detects the hardware, picks the best compatible profile and serves it through an optimized runtime. That collapses those days of work into one `docker run`.

**Q6.2** Applications written against the OpenAI API (SDKs, LangChain, LlamaIndex and others) can switch to a self-hosted NIM by changing only the **base URL and model name**. This avoids lock-in and code changes, and it keeps data on premises.

**Q6.3** **Tensor parallelism of degree 1**: the model runs on one GPU. `tp2` splits each layer's weights across **2 GPUs**, which needs enough GPUs on the node and ideally **NVLink** between them, because tensor parallelism exchanges activations in every layer.

**Q6.4** **NVIDIA AI Enterprise.** Production use of NIM is covered by an AI Enterprise license. Development access is available through the NVIDIA Developer Program.

**Q6.5** **NeMo** (NeMo framework for customization/fine-tuning, such as LoRA/PEFT; NeMo Guardrails for safety and topical rails; NeMo Retriever for embedding and reranking microservices). The pattern is **RAG (retrieval-augmented generation)**, which retrieves relevant document chunks at query time and adds them to the prompt, so no retraining is needed.
</details>

<details>
<summary><strong>Exercise 7</strong></summary>

**Q7.1**
- **driver**: installs/compiles the NVIDIA kernel driver in a container on each node.
- **container-toolkit**: configures containerd/CRI-O so containers can access GPUs.
- **device-plugin**: advertises `nvidia.com/gpu` to the kubelet and allocates devices to Pods.
- **gpu-feature-discovery**: labels nodes with GPU model, memory, count, MIG and CUDA capabilities.
- **dcgm-exporter**: exposes GPU telemetry in Prometheus format.
- **operator-validator**: runs validation workloads (including the CUDA validator) to confirm that the stack works before workloads are scheduled.

**Q7.2** The team would have to install and version-match the driver, container toolkit, runtime configuration, device plugin, monitoring agents and MIG configuration on every node, and redo all of it at every kernel or OS upgrade. At 200 nodes this causes **configuration drift**, slow and error-prone upgrades, and differences between nodes. The Operator makes the whole stack declarative (a ClusterPolicy) and handles lifecycle and upgrades automatically.

**Q7.3** Use it in `nodeSelector` or `nodeAffinity`, for example `nvidia.com/gpu.product: NVIDIA-H100-80GB-HBM3`. Typical reasons: pinning a workload to the GPU type its TensorRT engine was built for, ensuring enough memory for a large model, or steering cheap jobs to older GPUs.

**Q7.4** The **NVIDIA Network Operator**.

**Q7.5** The request is rejected. Extended resources must be integers, so fractional requests are invalid. Sharing requires time-slicing, MIG, vGPU or a scheduler layer such as Run:ai.
</details>

<details>
<summary><strong>Exercise 8</strong></summary>

**Q8.1** `GPU_UTIL` is the percentage of time **at least one kernel** was running. A single small kernel keeps it at 100% while most SMs and Tensor Cores sit idle. Better signals are the DCGM profiling fields: `DCGM_FI_PROF_SM_ACTIVE`, `DCGM_FI_PROF_SM_OCCUPANCY`, `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE`, `DCGM_FI_PROF_DRAM_ACTIVE`, and `DCGM_FI_PROF_PCIE_RX/TX_BYTES` / `DCGM_FI_PROF_NVLINK_RX/TX_BYTES`, which help find I/O and communication bottlenecks.

**Q8.2** An XID is an error event reported by the NVIDIA driver, such as a GPU fault, a memory/ECC issue, the GPU falling off the bus or an application-induced fault. First response:
1. Identify the XID code in the driver/kernel log (`dmesg`) and look it up in NVIDIA's XID catalog.
2. **Cordon/drain** the node if the code indicates a hardware problem.
3. Run `dcgmi diag`.
4. Reset the GPU or reboot.
5. Open an RMA if the error repeats.

**Q8.3** `-r 1` is a quick deployment/software check (seconds). `-r 2` adds short hardware tests. `-r 3` (and `-r 4`) run **longer stress tests** of PCIe, memory, SM and targeted power/stress, lasting minutes or more. Run the longer levels at node acceptance (burn-in), after hardware repairs, or when you suspect a flaky GPU. Do not run them while production jobs are on the node.

**Q8.4** DCGM is built for fleet operation. It offers low-overhead continuous collection, **profiling metrics** that `nvidia-smi` does not expose, health watches and policies, active diagnostics, job statistics, group management, and native integration with Prometheus (dcgm-exporter), Kubernetes and cluster managers.
</details>

<details>
<summary><strong>Exercise 9</strong></summary>

**Q9.1**

| | Time-slicing | MIG |
|---|---|---|
| Memory isolation | **None**: all replicas share the full framebuffer, so one Pod can exhaust it | **Hardware-partitioned** memory and cache per instance |
| Fault isolation | A fault can affect all sharers | Errors are contained to the instance |
| QoS / performance | Unpredictable; context switching between processes | **Dedicated SMs and memory bandwidth**, predictable latency |
| Hardware | Any supported GPU | A100, A30, H100, H200, B200 and later |
| Flexibility | Any replica count | Fixed profile shapes (up to 7 instances) |

**Q9.2** (a) **Time-slicing**: cheap oversubscription for bursty, idle-heavy, trusted workloads. (b) **MIG**: guaranteed resources and isolation between tenants protect latency SLAs.

**Q9.3** **Virtualization**: GPUs shared by or assigned to **virtual machines** under a hypervisor (VMware, KVM, OpenShift Virtualization), with live migration on supported platforms and per-VM licensing and management. vGPU can be combined with MIG (MIG-backed vGPU) for hardware isolation inside VMs.

**Q9.4** Profile-specific resources such as `nvidia.com/mig-1g.10gb`, `nvidia.com/mig-3g.40gb` and so on.

**Q9.5** **NVIDIA Run:ai.**
</details>

<details>
<summary><strong>Exercise 10</strong></summary>

**Step 1:**

| # | Solution | Why |
|---|---|---|
| S1 | **RAPIDS** (cuDF, cuML; RAPIDS Accelerator for Apache Spark) | GPU-accelerated dataframes/ETL with pandas- and Spark-compatible APIs |
| S2 | **NeMo** | End-to-end framework to build, customize, evaluate and guardrail generative AI models |
| S3 | **Riva** | GPU-accelerated speech AI (ASR, TTS, NMT) microservices |
| S4 | **Metropolis / DeepStream** | Vision AI framework and streaming-analytics SDK for multi-stream video at the edge |
| S5 | **Morpheus** | GPU-accelerated cybersecurity AI framework (anomaly detection, sensitive information detection) |
| S6 | **Merlin** | Recommender-system framework (NVTabular, HugeCTR, embedding handling) |
| S7 | **Clara** (Clara/MONAI for imaging) | Healthcare and life sciences AI platform |
| S8 | **Omniverse** (with Isaac Sim for robotics) | OpenUSD-based platform for physically based simulation and digital twins |
| S9 | **TAO Toolkit** | Low-code transfer learning on pretrained models |
| S10 | **Fleet Command** | Cloud-managed, secure deployment and lifecycle of AI apps across distributed edge sites |
| S11 | **Base Command Manager** | Cluster provisioning and management (images, workload managers, monitoring) |
| S12 | **GPUDirect Storage (Magnum IO)**, with a parallel filesystem | Direct storage→GPU DMA removes CPU bounce buffers |
| S13 | **BlueField DPU + DOCA** | Offload, accelerate and isolate networking, storage and security on the DPU |
| S14 | **Spectrum-X** | Ethernet platform (Spectrum-4 switches + BlueField-3 SuperNICs) optimized for AI, with adaptive routing and congestion control |
| S15 | **Quantum InfiniBand** (with SHARP in-network computing) | Lowest latency; SHARP offloads collective reductions into the switches |
| S16 | **NVIDIA AI Enterprise** | Supported, secure, certified production software suite |
| S17 | **NIM** | Prebuilt optimized inference microservice with an OpenAI-compatible API |
| S18 | **Run:ai** | GPU orchestration with quotas, fair-share and fractional GPUs |

**Step 2: storage mitigations** (from NVIDIA's storage-scaling guidance):
- Use **local NVMe as a cache** for the dataset, or a cache layer, so repeated epochs don't hit shared storage.
- Move to a **parallel/scale-out filesystem** designed for many concurrent readers instead of a single NFS head.
- Shape the I/O: **larger files/sharded formats** (fewer tiny files), more data loader workers, prefetching and asynchronous reads.
- Size the storage network to the GPU count (enough bandwidth per node), and stage checkpoints asynchronously so writes don't stall training.

**Q10.1** Practically any scenario that runs NVIDIA software in production: S2–S7, S9, S12 and S17, among others, and of course S16. AI Enterprise is the **commercial wrapper** (support, security, certification and entitlement). It does not perform a technical function itself, so when a scenario names a technical problem, the answer is the component that solves it.

**Q10.2** The deciding factor is the **operational/ecosystem requirement**:
- **Spectrum-X** suits organizations that standardize on **Ethernet** (multi-tenant AI clouds, existing Ethernet operations and tooling), while gaining AI-optimized performance.
- **Quantum InfiniBand** suits those that need the **absolute lowest latency and in-network computing (SHARP)** for the largest tightly coupled training jobs.

**Q10.3** Optimize with **TensorRT-LLM**, serve through **Triton** (which has a TensorRT-LLM backend) or, more simply, package and deploy as a **NIM**, with production support through **NVIDIA AI Enterprise**. In this lab you met them in the order TensorRT (Exercise 4) → Triton (Exercise 5) → NIM (Exercise 6), each one adding a layer of packaging on top of the previous one.
</details>

---

## Official sources

- NVIDIA NCA-AIIO exam study guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy, AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA TensorRT: https://developer.nvidia.com/tensorrt
- NVIDIA AI Inference (Triton, NIM, TensorRT-LLM): https://developer.nvidia.com/topics/ai/ai-inference
- Tips on Scaling Storage for AI Training and Inferencing: https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
- What Are Large Language Models Used For?: https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
- NVIDIA GPU Operator: Simplifying GPU Management in Kubernetes: https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes