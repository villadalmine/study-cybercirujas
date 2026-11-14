# Guided Exercises — Topic 1.7: Software Components of the AI Development and Deployment Life Cycle

**Certification:** NVIDIA-Certified Associate: AI Infrastructure and Operations (NCA-AIIO)
**Objective weight:** 4.75%

These exercises follow one small model through the NVIDIA software stack:

**data prep → training framework → exchange format → optimization → serving → orchestration → monitoring**

You will see each component's job and observe where one hands off to the next. Several steps run on a laptop without a GPU, so you can still reason about what a GPU adds.

## Lab tracks

| Track | Requirements | Exercises |
|---|---|---|
| **A — CPU only** | Docker, Python 3.10+, `curl`, ~25 GB of free disk for NGC images | 1, 3 (partially), 4, 5, 7, 10 |
| **B — GPU host** | Track A plus an NVIDIA GPU, NVIDIA driver, and the NVIDIA Container Toolkit | 1–7, 9, 10 |
| **C — Kubernetes** | A cluster with at least one GPU worker node, `kubectl`, `helm`, `jq` | 8 |

NGC container tags follow the `YY.MM` release scheme, for example `24.08`. Choose **one** current release from the NGC catalog (https://catalog.ngc.nvidia.com) and use it everywhere:

```bash
export NGC_TAG=24.08          # replace with a current release; keep it identical across images
mkdir -p ~/lab-1.7 && cd ~/lab-1.7
```

All NGC images in one release share the same CUDA / cuDNN / TensorRT versions. Mixing tags is the most common way to break Exercise 6.

**Official references used throughout:**
- NVIDIA AI Infrastructure and Operations study guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- AI Infrastructure & Operations Fundamentals course: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- TensorRT: https://developer.nvidia.com/tensorrt
- AI inference overview: https://developer.nvidia.com/topics/ai/ai-inference
- Scaling storage for AI: https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
- LLM use cases: https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
- GPU Operator: https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes
- Triton Inference Server user guide: https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/
- GPU Operator documentation: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/
- NVIDIA NIM documentation: https://docs.nvidia.com/nim/

---

## Exercise 1 — Map the stack onto the life cycle (paper exercise, all tracks)

The exam expects you to place a named component in the right life-cycle phase. You also need to tell apart components that look alike, such as TensorRT vs. Triton or Triton vs. NIM.

**Step 1.1** Copy this table into a file `~/lab-1.7/lifecycle.md`. For each component, fill in the **phase** and a **one-line role**. Use these phases:

- **P1** Data preparation and curation
- **P2** Model development, training, and fine-tuning
- **P3** Model optimization
- **P4** Inference serving and deployment
- **P5** Infrastructure orchestration and scheduling
- **P6** Monitoring and management
- **X** Cross-cutting: distribution, licensing, or support

| # | Component | Phase | Role (one line) |
|---|---|---|---|
| 1 | RAPIDS (cuDF, cuML) | | |
| 2 | NVIDIA DALI | | |
| 3 | NeMo Curator | | |
| 4 | PyTorch / TensorFlow / JAX | | |
| 5 | CUDA, cuDNN, cuBLAS | | |
| 6 | NCCL | | |
| 7 | NVIDIA NeMo framework | | |
| 8 | NVIDIA TAO Toolkit | | |
| 9 | TensorRT | | |
| 10 | TensorRT-LLM | | |
| 11 | Triton Inference Server | | |
| 12 | NVIDIA NIM | | |
| 13 | NVIDIA GPU Operator | | |
| 14 | NVIDIA Network Operator | | |
| 15 | Slurm | | |
| 16 | Run:ai | | |
| 17 | Base Command Manager | | |
| 18 | DCGM / DCGM Exporter | | |
| 19 | NGC Catalog | | |
| 20 | NVIDIA AI Enterprise | | |
| 21 | NVIDIA Container Toolkit | | |

**Step 1.2** Draw the handoffs as an arrow chain. Label each arrow with the **artifact** that passes between the two components, for example a "Parquet dataset" or a "checkpoint".

**Questions**

1.1. TensorRT and Triton both show up in "inference" diagrams. In one sentence each, what does each do, and can you use one without the other?

1.2. NIM packages several components from your table into one container. Which ones, and what does NIM add on top?

1.3. Which two components in the table matter mainly when **one job spans many GPUs or many nodes**? Why do they matter at that scale?

1.4. A colleague says: "NVIDIA AI Enterprise is a framework, like PyTorch." What is wrong with that statement?

---

## Exercise 2 — Inspect the GPU host software layers (Track B)

The bottom of the stack is the kernel driver. Above it sits the container runtime integration, and the CUDA user-space libraries come last. On a production node the user-space libraries usually live inside the container, not on the host.

**Step 2.1** Query the driver:

```bash
nvidia-smi
```

Expected output (header, values will differ):

```
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 550.90.07              Driver Version: 550.90.07      CUDA Version: 12.4     |
|-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
|=========================================+========================+======================|
|   0  NVIDIA L4                      On  |   00000000:00:03.0 Off |                    0 |
| N/A   38C    P8             16W /   72W |       1MiB /  23034MiB |      0%      Default |
+-----------------------------------------+------------------------+----------------------+
```

**Step 2.2** Check whether a CUDA toolkit is installed on the host:

```bash
nvcc --version || echo "no CUDA toolkit on host"
```

**Step 2.3** Check the container integration layer:

```bash
nvidia-ctk --version
docker info 2>/dev/null | grep -i -A2 runtimes
```

**Step 2.4** Run `nvidia-smi` from a plain Ubuntu image that contains no NVIDIA software:

```bash
docker run --rm --gpus all ubuntu:22.04 nvidia-smi -L
```

Expected output:

```
GPU 0: NVIDIA L4 (UUID: GPU-3f0c...)
```

**Questions**

2.1. `nvidia-smi` printed `CUDA Version: 12.4`, but `nvcc` may not exist on the host. What does the "CUDA Version" field actually mean?

2.2. In Step 2.4, the `ubuntu:22.04` image contains no `nvidia-smi` binary and no driver libraries. How did the command work?

2.3. Why is it common practice to keep the host minimal (driver plus Container Toolkit only) and ship CUDA, cuDNN, and frameworks inside containers?

2.4. A container built with CUDA 12.6 fails on this host with `CUDA driver version is insufficient for CUDA runtime version`. Which layer must change, and in which direction?

---

## Exercise 3 — NGC framework containers as the training environment (Track A partial, Track B full)

NGC framework containers are monthly-validated bundles. Each one contains a framework, CUDA, cuDNN, NCCL, and other libraries tuned to work together. They are the default starting point for P2.

**Step 3.1** Pull the PyTorch container. It is large; expect several GB.

```bash
docker pull nvcr.io/nvidia/pytorch:${NGC_TAG}-py3
```

**Step 3.2** Print the library versions bundled in the image:

```bash
docker run --rm --gpus all --ipc=host \
  --ulimit memlock=-1 --ulimit stack=67108864 \
  nvcr.io/nvidia/pytorch:${NGC_TAG}-py3 \
  python -c "import torch; \
print('torch', torch.__version__); \
print('cuda', torch.version.cuda); \
print('cudnn', torch.backends.cudnn.version()); \
print('nccl', torch.cuda.nccl.version() if torch.cuda.is_available() else 'n/a'); \
print('gpus', torch.cuda.device_count())"
```

On Track A, remove `--gpus all`. Expected output on Track B (values illustrative):

```
torch 2.5.0a0+872d972e41.nv24.08
cuda 12.6
cudnn 90300
nccl (2, 22, 3)
gpus 1
```

**Step 3.3** Run a tiny training step on the GPU to confirm the full path, from framework to cuDNN/cuBLAS to driver:

```bash
docker run --rm --gpus all --ipc=host nvcr.io/nvidia/pytorch:${NGC_TAG}-py3 python - <<'EOF'
import torch, torch.nn as nn
dev = "cuda" if torch.cuda.is_available() else "cpu"
model = nn.Sequential(nn.Linear(4, 16), nn.ReLU(), nn.Linear(16, 2)).to(dev)
opt = torch.optim.SGD(model.parameters(), lr=0.1)
x, y = torch.randn(256, 4, device=dev), torch.randn(256, 2, device=dev)
for step in range(3):
    loss = nn.functional.mse_loss(model(x), y)
    opt.zero_grad(); loss.backward(); opt.step()
    print(f"step={step} device={dev} loss={loss.item():.4f}")
EOF
```

Expected output (loss values vary):

```
step=0 device=cuda loss=1.0832
step=1 device=cuda loss=1.0410
step=2 device=cuda loss=1.0057
```

**Questions**

3.1. The torch version string ends in `.nv24.08`. What does that tell you, and where would you look up the exact CUDA / cuDNN / NCCL versions before upgrading?

3.2. Why do the NGC docs recommend `--ipc=host` (or a large `--shm-size`) for PyTorch containers?

3.3. NCCL showed up in the version list even though the training script never calls it. When does NCCL become critical, and which hardware paths does it exploit?

3.4. Suppose the team has to fine-tune an LLM rather than a small MLP. Which NVIDIA framework from Exercise 1 would they reach for instead of raw PyTorch, and what does it provide?

---

## Exercise 4 — Produce a portable model artifact (Tracks A and B)

The handoff from training (P2) to optimization and serving (P3/P4) is usually a framework-neutral artifact such as **ONNX**. Here you build a tiny ONNX model directly. It computes `OUTPUT0 = INPUT0 · W + B`, so every later result can be checked by hand.

**Step 4.1** Create an isolated Python environment:

```bash
cd ~/lab-1.7
python3 -m venv .venv && . .venv/bin/activate
pip install --quiet numpy onnx onnxruntime
```

**Step 4.2** Create `make_model.py`:

```python
import numpy as np
import onnx
from onnx import helper, TensorProto, numpy_helper

# Weights: 4 inputs -> 2 outputs
W = numpy_helper.from_array(
    np.array([[1, 0],
              [0, 1],
              [1, 1],
              [2, -1]], dtype=np.float32), name="W")
B = numpy_helper.from_array(np.array([0.5, -0.5], dtype=np.float32), name="B")

# "batch" is a symbolic (dynamic) dimension
X = helper.make_tensor_value_info("INPUT0", TensorProto.FLOAT, ["batch", 4])
Y = helper.make_tensor_value_info("OUTPUT0", TensorProto.FLOAT, ["batch", 2])

matmul = helper.make_node("MatMul", ["INPUT0", "W"], ["XW"])
add = helper.make_node("Add", ["XW", "B"], ["OUTPUT0"])

graph = helper.make_graph([matmul, add], "tiny_linear", [X], [Y], initializer=[W, B])
model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 13)])
model.ir_version = 8          # conservative IR version for older runtimes
onnx.checker.check_model(model)
onnx.save(model, "model.onnx")
print("saved model.onnx")
```

```bash
python make_model.py
```

**Step 4.3** Validate the model locally with ONNX Runtime before handing it to any server:

```bash
python - <<'EOF'
import numpy as np, onnxruntime as ort
s = ort.InferenceSession("model.onnx", providers=["CPUExecutionProvider"])
x = np.array([[1, 2, 3, 4], [0, 0, 0, 1]], dtype=np.float32)
print(s.get_inputs()[0].name, s.get_inputs()[0].shape)
print(s.run(None, {"INPUT0": x})[0])
EOF
```

Expected output:

```
INPUT0 ['batch', 4]
[[12.5  0.5]
 [ 2.5 -1.5]]
```

**Questions**

4.1. Verify the first output row `[12.5, 0.5]` by hand.

4.2. Why does the model declare the first dimension as `"batch"` instead of a fixed `1`? What would break in Exercise 5 if it were fixed?

4.3. What is the benefit of exporting to ONNX instead of serving the native PyTorch checkpoint, and what is a risk of the conversion?

---

## Exercise 5 — Serve the model with Triton Inference Server (Tracks A and B)

Triton is a multi-framework inference server. It loads models from a **model repository** and exposes HTTP/REST and gRPC endpoints using the KServe v2 protocol, plus Prometheus metrics. It also adds scheduling features such as dynamic batching and concurrent model instances.

**Step 5.1** Build the model repository layout:

```bash
cd ~/lab-1.7
mkdir -p model_repository/tiny_linear/1
cp model.onnx model_repository/tiny_linear/1/model.onnx
```

Resulting tree:

```
model_repository/
└── tiny_linear/
    ├── config.pbtxt
    └── 1/
        └── model.onnx
```

**Step 5.2** Create `model_repository/tiny_linear/config.pbtxt`. This is protobuf text format, not YAML:

```
name: "tiny_linear"
backend: "onnxruntime"
max_batch_size: 8
input [
  {
    name: "INPUT0"
    data_type: TYPE_FP32
    dims: [ 4 ]
  }
]
output [
  {
    name: "OUTPUT0"
    data_type: TYPE_FP32
    dims: [ 2 ]
  }
]
instance_group [
  {
    count: 1
    kind: KIND_CPU
  }
]
dynamic_batching {
  max_queue_delay_microseconds: 2000
}
```

**Step 5.3** Start Triton. On Track B you may add `--gpus all`. The instance group still pins this model to CPU.

```bash
docker run -d --name triton --rm \
  -p 8000:8000 -p 8001:8001 -p 8002:8002 \
  -v "$PWD/model_repository:/models" \
  nvcr.io/nvidia/tritonserver:${NGC_TAG}-py3 \
  tritonserver --model-repository=/models

sleep 15; docker logs triton 2>&1 | grep -A5 "Model  "
```

Expected log fragment:

```
+-------------+---------+--------+
| Model       | Version | Status |
+-------------+---------+--------+
| tiny_linear | 1       | READY  |
+-------------+---------+--------+
```

**Step 5.4** Check health and model metadata:

```bash
curl -s -o /dev/null -w "%{http_code}\n" localhost:8000/v2/health/ready
curl -s localhost:8000/v2/models/tiny_linear | python3 -m json.tool
```

Expected output:

```
200
{
    "name": "tiny_linear",
    "versions": [
        "1"
    ],
    "platform": "onnxruntime_onnx",
    "inputs": [
        {
            "name": "INPUT0",
            "datatype": "FP32",
            "shape": [
                -1,
                4
            ]
        }
    ],
    "outputs": [
        {
            "name": "OUTPUT0",
            "datatype": "FP32",
            "shape": [
                -1,
                2
            ]
        }
    ]
}
```

**Step 5.5** Send an inference request using the KServe v2 protocol:

```bash
curl -s -X POST localhost:8000/v2/models/tiny_linear/infer \
  -H 'Content-Type: application/json' \
  -d '{"inputs":[{"name":"INPUT0","shape":[2,4],"datatype":"FP32","data":[1,2,3,4,0,0,0,1]}]}'
echo
```

Expected output:

```
{"model_name":"tiny_linear","model_version":"1","outputs":[{"name":"OUTPUT0","datatype":"FP32","shape":[2,2],"data":[12.5,0.5,2.5,-1.5]}]}
```

**Step 5.6** Read the Prometheus metrics endpoint:

```bash
curl -s localhost:8002/metrics | grep -E '^nv_inference_(request_success|count|exec_count)'
```

Expected output:

```
nv_inference_request_success{model="tiny_linear",version="1"} 1
nv_inference_count{model="tiny_linear",version="1"} 2
nv_inference_exec_count{model="tiny_linear",version="1"} 1
```

**Questions**

5.1. What does each of the three ports (8000, 8001, 8002) serve?

5.2. With `max_batch_size: 8`, why do the `dims` in `config.pbtxt` say `[ 4 ]` while the metadata reports `[-1, 4]`?

5.3. After Step 5.5, `nv_inference_count` is 2 but `nv_inference_request_success` is 1. Explain the difference.

5.4. What is the purpose of the `1/` directory? How would you roll out a new model version with zero downtime?

5.5. What would you change in `config.pbtxt` to run two copies of this model on GPU 0?

---

## Exercise 6 — Optimize with TensorRT (Track B)

TensorRT is an SDK that compiles a trained network into an **engine** optimized for one specific GPU. It does this through layer and tensor fusion, kernel auto-tuning, precision calibration (FP16/INT8/FP8), and memory planning. Triton then serves that engine through its TensorRT backend.

**Step 6.1** Build an FP16 engine with `trtexec`. Use the **same `NGC_TAG`** as the Triton image so the TensorRT versions match.

```bash
cd ~/lab-1.7
docker run --rm --gpus all -v "$PWD:/work" -w /work \
  nvcr.io/nvidia/tensorrt:${NGC_TAG}-py3 \
  trtexec --onnx=model.onnx --saveEngine=model.plan --fp16 \
          --minShapes=INPUT0:1x4 --optShapes=INPUT0:4x4 --maxShapes=INPUT0:8x4
```

Expected tail of the output (numbers illustrative):

```
[I] === Performance summary ===
[I] Throughput: 41235.6 qps
[I] Latency: min = 0.0141 ms, max = 0.0712 ms, mean = 0.0182 ms, median = 0.0175 ms
...
&&&& PASSED TensorRT.trtexec [TensorRT v100300] # trtexec --onnx=model.onnx --saveEngine=model.plan --fp16 ...
```

**Step 6.2** Add the engine as a second model in the repository:

```bash
mkdir -p model_repository/tiny_linear_trt/1
cp model.plan model_repository/tiny_linear_trt/1/model.plan
```

Create `model_repository/tiny_linear_trt/config.pbtxt`:

```
name: "tiny_linear_trt"
platform: "tensorrt_plan"
max_batch_size: 8
input [
  {
    name: "INPUT0"
    data_type: TYPE_FP32
    dims: [ 4 ]
  }
]
output [
  {
    name: "OUTPUT0"
    data_type: TYPE_FP32
    dims: [ 2 ]
  }
]
instance_group [
  {
    count: 1
    kind: KIND_GPU
    gpus: [ 0 ]
  }
]
dynamic_batching { }
```

**Step 6.3** Restart Triton with GPU access and test the engine:

```bash
docker stop triton
docker run -d --name triton --rm --gpus all \
  -p 8000:8000 -p 8001:8001 -p 8002:8002 \
  -v "$PWD/model_repository:/models" \
  nvcr.io/nvidia/tritonserver:${NGC_TAG}-py3 \
  tritonserver --model-repository=/models
sleep 20
curl -s -X POST localhost:8000/v2/models/tiny_linear_trt/infer \
  -H 'Content-Type: application/json' \
  -d '{"inputs":[{"name":"INPUT0","shape":[1,4],"datatype":"FP32","data":[1,2,3,4]}]}'
echo
```

Expected output. FP16 math may introduce tiny differences on real models; this one is exact.

```
{"model_name":"tiny_linear_trt","model_version":"1","outputs":[{"name":"OUTPUT0","datatype":"FP32","shape":[1,2],"data":[12.5,0.5]}]}
```

**Questions**

6.1. You copy `model.plan` to a server with a different GPU architecture, or to a Triton image built on a different TensorRT version. What happens, and what is the correct practice?

6.2. Why did `trtexec` need `--minShapes/--optShapes/--maxShapes`? How do they relate to `max_batch_size: 8`?

6.3. The engine was built with `--fp16`, yet the Triton config still declares `TYPE_FP32` I/O. Is that a contradiction?

6.4. INT8 usually needs something FP16 does not. What is it, and why?

6.5. For LLMs, which NVIDIA library extends TensorRT? Name two LLM-specific optimizations it adds.

---

## Exercise 7 — Measure serving performance with `perf_analyzer` (Tracks A and B)

`perf_analyzer` ships in the Triton **SDK** image. It generates load and reports throughput and latency. This is how you validate a serving configuration before production.

**Step 7.1** Sweep concurrency against the ONNX/CPU model. Use `--net=host` so the client reaches `localhost:8000`.

```bash
docker run --rm --net=host nvcr.io/nvidia/tritonserver:${NGC_TAG}-py3-sdk \
  perf_analyzer -m tiny_linear -u localhost:8000 --concurrency-range 1:8:1
```

Expected summary (numbers illustrative):

```
Inferences/Second vs. Client Average Batch Latency
Concurrency: 1, throughput: 2850.4 infer/sec, latency 349 usec
Concurrency: 2, throughput: 4105.7 infer/sec, latency 486 usec
...
Concurrency: 8, throughput: 6920.1 infer/sec, latency 1155 usec
```

**Step 7.2** Check whether dynamic batching actually happened:

```bash
curl -s localhost:8002/metrics | grep -E '^nv_inference_(count|exec_count)\{model="tiny_linear"'
```

Expected output (counts illustrative; the ratio is what matters):

```
nv_inference_count{model="tiny_linear",version="1"} 412880
nv_inference_exec_count{model="tiny_linear",version="1"} 98311
```

**Step 7.3** (Track B) Repeat Step 7.1 with `-m tiny_linear_trt` and compare.

**Questions**

7.1. Compute the average batch size the server executed in Step 7.2. What does a value above 1 prove?

7.2. Throughput grows with concurrency while latency also grows. What trade-off does `max_queue_delay_microseconds` control?

7.3. On this toy model the TensorRT engine may barely beat ONNX Runtime, or even lose. Why? What kind of model shows the large TensorRT gains?

---

## Exercise 8 — Orchestrate GPUs in Kubernetes with the GPU Operator (Track C)

On Kubernetes, the GPU Operator automates the per-node software that Exercise 2 installed by hand. It manages the driver, Container Toolkit, device plugin, GPU Feature Discovery, DCGM Exporter, MIG Manager, and validators, and it is configured through a single `ClusterPolicy` custom resource.

**Step 8.1** Install the operator. If the nodes already have a driver installed, add `--set driver.enabled=false`.

```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
helm install --wait --generate-name \
  -n gpu-operator --create-namespace \
  nvidia/gpu-operator
```

**Step 8.2** Watch the components converge:

```bash
kubectl get pods -n gpu-operator
```

Expected output (names abbreviated, pod hashes omitted):

```
NAME                                            READY   STATUS      RESTARTS   AGE
gpu-feature-discovery-xxxxx                     1/1     Running     0          4m
gpu-operator-xxxxxxxxxx-xxxxx                   1/1     Running     0          5m
gpu-operator-...-node-feature-discovery-gc-...  1/1     Running     0          5m
gpu-operator-...-node-feature-discovery-master  1/1     Running     0          5m
gpu-operator-...-node-feature-discovery-worker  1/1     Running     0          5m
nvidia-container-toolkit-daemonset-xxxxx        1/1     Running     0          4m
nvidia-cuda-validator-xxxxx                     0/1     Completed   0          2m
nvidia-dcgm-exporter-xxxxx                      1/1     Running     0          4m
nvidia-device-plugin-daemonset-xxxxx            1/1     Running     0          4m
nvidia-driver-daemonset-xxxxx                   1/1     Running     0          5m
nvidia-operator-validator-xxxxx                 1/1     Running     0          4m
```

**Step 8.3** Confirm the node now advertises GPUs as an extended resource, along with labels from GPU Feature Discovery:

```bash
kubectl get nodes -o json | jq -r '.items[] | "\(.metadata.name)\t\(.status.allocatable["nvidia.com/gpu"] // "0")"'
kubectl get nodes -L nvidia.com/gpu.product,nvidia.com/gpu.count
```

Expected output (illustrative):

```
gpu-worker-1	1
NAME           STATUS   ROLES    AGE   VERSION   GPU.PRODUCT   GPU.COUNT
gpu-worker-1   Ready    <none>   20d   v1.30.4   NVIDIA-L4     1
```

**Step 8.4** Schedule a GPU workload. Save as `cuda-vectoradd.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cuda-vectoradd
spec:
  restartPolicy: OnFailure
  containers:
    - name: cuda-vectoradd
      image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0
      resources:
        limits:
          nvidia.com/gpu: 1
```

```bash
kubectl apply -f cuda-vectoradd.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/cuda-vectoradd --timeout=180s
kubectl logs cuda-vectoradd
```

Expected output:

```
[Vector addition of 50000 elements]
Copy input data from the host memory to the CUDA device
CUDA kernel launch with 196 blocks of 256 threads
Copy output data from the CUDA device to the host memory
Test PASSED
Done
```

**Step 8.5** Read GPU telemetry from DCGM Exporter:

```bash
kubectl -n gpu-operator port-forward svc/nvidia-dcgm-exporter 9400:9400 &
sleep 2
curl -s localhost:9400/metrics | grep -E '^DCGM_FI_DEV_(GPU_UTIL|FB_USED|GPU_TEMP|POWER_USAGE)' | head
kill %1
```

Expected output (labels trimmed):

```
DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-3f0c...",modelName="NVIDIA L4",Hostname="gpu-worker-1"} 0
DCGM_FI_DEV_FB_USED{gpu="0",UUID="GPU-3f0c...",modelName="NVIDIA L4",Hostname="gpu-worker-1"} 0
DCGM_FI_DEV_GPU_TEMP{gpu="0",UUID="GPU-3f0c...",modelName="NVIDIA L4",Hostname="gpu-worker-1"} 37
DCGM_FI_DEV_POWER_USAGE{gpu="0",UUID="GPU-3f0c...",modelName="NVIDIA L4",Hostname="gpu-worker-1"} 16.2
```

**Step 8.6** Inspect the single source of configuration:

```bash
kubectl get clusterpolicy -o jsonpath='{.items[0].status.state}{"\n"}'
kubectl get clusterpolicy -o yaml | grep -E '^\s+(driver|toolkit|devicePlugin|dcgmExporter|migManager|gfd):' -A1 | head -30
```

Expected first line: `ready`.

**Questions**

8.1. Map each pod from Step 8.2 to its job. Which one makes `nvidia.com/gpu` appear in `allocatable`?

8.2. Why is `nvidia.com/gpu` specified under `limits`? Can a pod request half a GPU this way? What mechanisms provide GPU sharing?

8.3. Without the GPU Operator, what would an admin have to do on every new GPU node? Why does that become a problem at fleet scale?

8.4. DCGM Exporter reports device-level metrics, while Triton reports `nv_inference_*`. Why do you need both in a production dashboard?

8.5. When would you choose Slurm, or Base Command Manager with Slurm, instead of Kubernetes for the training phase? Where does Run:ai fit?

---

## Exercise 9 — Deploy an LLM as an NVIDIA NIM microservice (Track B, optional)

NIM packages a model, an optimized inference engine (for LLMs, typically TensorRT-LLM, with other runtimes as fallback), and a serving layer into one container. It exposes an industry-standard API; for LLMs, that API is OpenAI-compatible. You need an NGC API key and a GPU with enough memory for the chosen model.

**Step 9.1** Stop Triton (port 8000 is reused), then log in to NGC:

```bash
docker stop triton
export NGC_API_KEY="<your-ngc-api-key>"
echo "$NGC_API_KEY" | docker login nvcr.io --username '$oauthtoken' --password-stdin
```

**Step 9.2** Run the NIM container:

```bash
mkdir -p ~/.cache/nim
docker run -d --name nim --rm --gpus all --shm-size=16GB \
  -e NGC_API_KEY \
  -v ~/.cache/nim:/opt/nim/.cache \
  -p 8000:8000 \
  nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
docker logs -f nim      # wait until the server reports it is listening, then Ctrl+C
```

**Step 9.3** Query it with the OpenAI-compatible API:

```bash
curl -s localhost:8000/v1/models | python3 -m json.tool | grep '"id"'
curl -s localhost:8000/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "meta/llama-3.1-8b-instruct",
  "messages": [{"role": "user", "content": "In one sentence, what does TensorRT do?"}],
  "max_tokens": 64
}' | python3 -m json.tool | grep -A2 '"content"'
```

Expected output (generated text will vary):

```
        "id": "meta/llama-3.1-8b-instruct",
            "content": "TensorRT is an NVIDIA SDK that optimizes trained neural networks for high-performance, low-latency inference on NVIDIA GPUs.",
            "role": "assistant"
```

**Questions**

9.1. On first start, NIM spends time before serving. What is it doing? Why is the `~/.cache/nim` volume important?

9.2. Compare Exercise 5 (Triton plus a model you built) with Exercise 9 (NIM). What did you have to do yourself in each case?

9.3. The LLM blog lists use cases such as chat assistants, code generation, summarization, and search/RAG. For a RAG application, which other software components join the life cycle beyond the LLM NIM?

---

## Exercise 10 — Exam-style scenarios (all tracks)

Answer each scenario with the **component(s)** and a **one-sentence justification**.

10.1. Data scientists spend 70% of each epoch waiting on CPU-bound pandas ETL and JPEG decoding. GPUs sit at 30% utilization.

10.2. A multi-node training job scales poorly beyond 4 nodes. The storage team reports that the shared filesystem saturates whenever all ranks write checkpoints at the same moment.

10.3. A team must serve a TensorFlow model, a PyTorch model, and an XGBoost model from one endpoint, with per-model metrics and batching.

10.4. An enterprise wants supported, security-patched, production-certified versions of the NVIDIA AI software stack with long-term branches.

10.5. A computer-vision team wants to fine-tune a pretrained detection model on their own images with minimal code.

10.6. Operations needs to alert when a GPU shows rising XID errors or ECC errors before jobs fail.

10.7. A latency SLA for an LLM chatbot is being missed. The model currently runs in eager PyTorch.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

Completed table:

| # | Component | Phase | Role |
|---|---|---|---|
| 1 | RAPIDS | P1 (also classic ML in P2) | GPU-accelerated dataframes (cuDF), ML (cuML), graph analytics; pandas/scikit-learn-like APIs |
| 2 | DALI | P1 / P2 | GPU-accelerated data loading and augmentation pipeline that feeds training and inference |
| 3 | NeMo Curator | P1 | GPU-accelerated curation of large text/multimodal datasets for LLMs (dedup, filtering, PII removal) |
| 4 | PyTorch / TF / JAX | P2 | Deep learning frameworks used to define and train models |
| 5 | CUDA, cuDNN, cuBLAS | P2–P4 (foundation) | Programming model and GPU-accelerated primitive libraries that frameworks call |
| 6 | NCCL | P2 | Multi-GPU/multi-node collectives (all-reduce, all-gather) over NVLink, PCIe, InfiniBand/RoCE |
| 7 | NeMo framework | P2 | End-to-end framework to build, pretrain, customize and align generative AI/LLMs |
| 8 | TAO Toolkit | P2 | Low-code transfer learning / fine-tuning of pretrained models (mostly vision) |
| 9 | TensorRT | P3 | Compiles trained models into optimized inference engines (fusion, precision, kernel auto-tuning) |
| 10 | TensorRT-LLM | P3 / P4 | TensorRT-based library for LLM inference (in-flight batching, paged KV cache, quantization, tensor parallelism) |
| 11 | Triton | P4 | Multi-framework inference server: model repository, HTTP/gRPC, dynamic batching, metrics |
| 12 | NIM | P4 | Prebuilt, optimized inference microservices per model with standard APIs |
| 13 | GPU Operator | P5 | Automates the GPU node software stack on Kubernetes |
| 14 | Network Operator | P5 | Automates networking components (RDMA, SR-IOV, GPUDirect RDMA drivers) on Kubernetes |
| 15 | Slurm | P5 | HPC batch scheduler, common for large multi-node training |
| 16 | Run:ai | P5 | GPU orchestration/scheduling layer on Kubernetes: quotas, fractional GPUs, fair-share, pooling |
| 17 | Base Command Manager | P5 / P6 | Cluster provisioning and management for AI clusters (deploys Kubernetes and/or Slurm, monitors nodes) |
| 18 | DCGM / Exporter | P6 | GPU health, diagnostics, telemetry; exporter exposes it to Prometheus |
| 19 | NGC Catalog | X | Registry of GPU-optimized containers, pretrained models, Helm charts, SDKs |
| 20 | NVIDIA AI Enterprise | X | Licensed, supported, security-maintained software suite (frameworks, Triton, TensorRT, NIM, operators) |
| 21 | Container Toolkit | P5 (foundation) | Lets container runtimes (Docker, containerd, CRI-O) expose GPUs and driver libraries to containers |

Example handoff chain:
raw data → **(cleaned Parquet / tokenized shards)** → framework training → **(checkpoint)** → export → **(ONNX)** → TensorRT → **(engine `.plan`)** → Triton/NIM → **(HTTP/gRPC endpoint)** → clients. DCGM and Triton metrics feed Prometheus across the whole chain.

**1.1** TensorRT is an *optimizer/compiler and runtime* that produces a fast engine for a specific GPU. Triton is a *serving system* that exposes models over the network and manages batching, versions, and instances. They are independent. Triton can serve ONNX, PyTorch, or Python models without TensorRT, and a TensorRT engine can be embedded directly in a C++/Python application without Triton. In production they are often combined, as in Exercise 6.

**1.2** An LLM NIM typically bundles an optimized engine (TensorRT-LLM, with other runtimes as alternatives), a serving layer (Triton or an equivalent server), and the model weights or pointers to them, on top of CUDA libraries. On top of that, NIM adds:
- automatic selection of an optimized profile for the detected GPU,
- an industry-standard API (OpenAI-compatible for LLMs),
- health/metrics endpoints,
- enterprise packaging and support through NVIDIA AI Enterprise.

**1.3** NCCL and the Network Operator (with the underlying InfiniBand/RoCE fabric). Data-parallel and model-parallel training synchronize gradients or activations every step. NCCL picks the fastest topology-aware path (NVLink within a node, GPUDirect RDMA across nodes), and the Network Operator makes those RDMA paths available to pods. Poor collectives cause GPUs to wait on communication.

**1.4** NVIDIA AI Enterprise is not a framework. It is a **software suite and license/support offering**: a curated, tested, security-patched set of frameworks, SDKs, and operators (including NIM, Triton, TensorRT, and the GPU Operator), with enterprise support and long-term production branches.

### Exercise 2

**2.1** It is the **highest CUDA runtime version that this driver supports**. It does not mean a CUDA toolkit is installed. The driver is backward compatible with older CUDA runtimes.

**2.2** The NVIDIA Container Toolkit hooks into the runtime. When `--gpus` is used, it injects the GPU device nodes (`/dev/nvidia*`), the driver user-space libraries (`libcuda.so`, `libnvidia-ml.so`), and utilities such as `nvidia-smi` into the container at start time.

**2.3** The driver must match the kernel and is shared, so it belongs on the host. The CUDA toolkit, cuDNN, and frameworks change much faster, and different workloads need different versions. Containers let many version combinations coexist on one host. They are also reproducible across dev and prod, and upgrading a workload never risks the host.

**2.4** The **host driver** must be upgraded to a version that supports CUDA 12.6. Alternatively, use a container built against an older CUDA, or on supported datacenter GPUs use the CUDA forward-compatibility package. The driver must be at least as new as the CUDA runtime requires.

### Exercise 3

**3.1** It is an NVIDIA-built PyTorch from the `24.08` NGC release, with NVIDIA patches and validation. The exact component versions are in the **NGC framework container release notes / support matrix** for that release.

**3.2** PyTorch `DataLoader` workers share tensors through shared memory (`/dev/shm`). Docker's default 64 MB `/dev/shm` is too small and causes worker crashes ("bus error") or slowdowns. NCCL can also use shared memory for intra-node communication.

**3.3** NCCL becomes critical as soon as training uses more than one GPU, for example with DDP or FSDP (all-reduce of gradients) or with tensor/pipeline parallelism. It uses NVLink/NVSwitch within a node, PCIe as a fallback, and InfiniBand or RoCE with GPUDirect RDMA across nodes.

**3.4** The **NVIDIA NeMo framework**. It provides recipes and parallelism strategies (tensor/pipeline/sequence parallelism through Megatron Core), PEFT methods such as LoRA, SFT and alignment (e.g., RLHF/DPO), checkpoint conversion, and export paths toward TensorRT-LLM and NIM. NeMo Curator covers the data side.

### Exercise 4

**4.1** `[1,2,3,4] · W`:
- column 1: 1·1 + 2·0 + 3·1 + 4·2 = 12
- column 2: 1·0 + 2·1 + 3·1 + 4·(−1) = 1

Adding B = [0.5, −0.5] gives **[12.5, 0.5]**.

**4.2** A dynamic batch dimension lets one model execute 1 to N requests at once. Triton's `max_batch_size: 8` and dynamic batching require the model to accept a variable leading dimension. If it were fixed at `1`, Triton would fail to load the model (configuration mismatch) or could not batch, and multi-row requests like Step 5.5 would be rejected.

**4.3** Benefits: the artifact is framework-neutral, is a standard input to TensorRT and ONNX Runtime, and decouples training dependencies from serving. Risks: unsupported or custom operators, numerical differences, and dynamic control flow that does not export cleanly. Always validate outputs against the original model, as Step 4.3 does.

### Exercise 5

**5.1**
- 8000: HTTP/REST (KServe v2 inference protocol, health, metadata).
- 8001: gRPC (same protocol, lower overhead).
- 8002: Prometheus metrics.

**5.2** When `max_batch_size > 0`, the batch dimension is implicit, and `dims` describes the shape of **one** item. Triton prepends a variable batch dimension, reported as `-1`.

**5.3** `request_success` counts **requests** (one HTTP call). `nv_inference_count` counts **inferences**, i.e., batch items. The single request carried 2 rows (`shape [2,4]`). `exec_count` = 1 means it ran as one model execution.

**5.4** Each numeric subdirectory is a **model version**. You add `2/model.onnx`. Depending on the `version_policy` (default: latest) and the repository control mode (polling, or explicit load through the model-control API), Triton loads version 2 and then unloads 1. In-flight requests finish on the old version, so clients see no downtime.

**5.5** Use:
```
instance_group [ { count: 2 kind: KIND_GPU gpus: [ 0 ] } ]
```
Start Triton with `--gpus all`. For this ONNX model, inference then uses the CUDA execution provider of ONNX Runtime.

### Exercise 6

**6.1** Loading fails, typically with an error about engine serialization or version/compatibility mismatch, or performance is undefined. TensorRT engines are tied to the **TensorRT version** and, by default, to the **GPU architecture / compute capability**, because kernels are auto-tuned for that hardware. Keep ONNX as the portable artifact and build the engine per target platform, in the CI/CD or deploy pipeline, using the same TensorRT version as the serving image.

**6.2** The ONNX input has a dynamic dimension. TensorRT needs an **optimization profile**: the minimum and maximum shapes it must support, plus the shape to tune kernels for. The max batch of 8 must be ≥ Triton's `max_batch_size: 8`, or Triton will reject or fail requests above the profile.

**6.3** No. `--fp16` allows TensorRT to run **internal layers** in FP16 where profitable. The engine's input/output bindings stay FP32 unless you change the I/O formats explicitly, so the Triton config correctly declares FP32.

**6.4** **Calibration data**, or a model already quantized with Q/DQ nodes (quantization-aware training or the Model Optimizer). INT8 has a narrow dynamic range, so TensorRT must learn per-tensor scale factors from representative data to avoid accuracy loss. FP16's range is wide enough for direct conversion.

**6.5** **TensorRT-LLM**. Examples of what it adds:
- in-flight (continuous) batching,
- paged KV cache,
- FP8/INT4 weight quantization,
- tensor and pipeline parallelism across GPUs,
- speculative decoding,
- optimized attention kernels.

### Exercise 7

**7.1** 412880 / 98311 ≈ **4.2 inferences per execution**. A value above 1 proves the dynamic batcher combined independent client requests into larger batches, which raises throughput.

**7.2** It is the maximum time a request may wait in the queue for others to form a larger batch. Larger values give bigger batches and higher throughput, at the cost of added latency. Smaller values do the reverse. Tune it against the latency SLA using `perf_analyzer`.

**7.3** The model is a single 4×2 MatMul, so runtime is dominated by HTTP, serialization, and the GPU launch/copy overhead, not by compute. Moving data to the GPU can even cost more than the math. TensorRT's gains show up on compute-heavy networks: CNNs, transformers, and LLMs, with many fusible layers and large tensors, especially when lower precision activates Tensor Cores.

### Exercise 8

**8.1**
- **driver-daemonset**: installs the kernel driver in a container.
- **container-toolkit-daemonset**: configures containerd/CRI-O for GPUs.
- **device-plugin-daemonset**: **registers `nvidia.com/gpu` with the kubelet**, which makes it appear in `allocatable`.
- **gpu-feature-discovery**: adds labels such as product, memory, and MIG capability.
- **node-feature-discovery**: generic hardware labels that the operator uses to find GPU nodes.
- **dcgm-exporter**: Prometheus GPU metrics.
- **cuda-validator / operator-validator**: verify the stack end to end.
- **gpu-operator**: the controller that reconciles the `ClusterPolicy`.
- **mig-manager**, when enabled: applies MIG partitions.

**8.2** Extended resources are integers and cannot be overcommitted, so the request must equal the limit; specifying the limit is sufficient. You cannot request `0.5`. Sharing mechanisms:
- **MIG** (hardware partitions with isolation on supported GPUs),
- **time-slicing** (configured in the device plugin; no memory isolation),
- **MPS**,
- higher-level schedulers such as **Run:ai** that offer fractional GPUs.

**8.3** On each node: install a driver matching the kernel, install and configure the Container Toolkit, deploy the device plugin, set up DCGM monitoring, configure MIG, and repeat after every kernel/OS update. At scale this causes configuration drift, slow node onboarding, and fragile upgrades. The operator turns it into a declarative, reconciled `ClusterPolicy`.

**8.4** They answer different questions. DCGM covers **infrastructure health and saturation**: utilization, memory, temperature, power, XID/ECC errors, throttling. Triton covers **service behavior**: request rate, queue time, compute time, batch efficiency, failures per model. For example, low GPU utilization with high queue time points to a serving-config problem, while high temperature plus throttling points to a hardware or cooling problem.

**8.5** Slurm suits large, long-running, tightly coupled multi-node training on HPC-style clusters. Its strengths are gang scheduling, topology awareness, exclusive node allocation, and a familiar `sbatch`/`srun` workflow. Base Command Manager provisions and manages such clusters and can deploy Slurm, Kubernetes, or both. Kubernetes is stronger for services, inference, and mixed workloads. **Run:ai** sits on top of Kubernetes to bring HPC-like scheduling: quotas, fair-share, gang scheduling, GPU pooling, and fractional GPUs.

### Exercise 9

**9.1** It detects the GPU, selects a matching optimized profile (engine), downloads model weights/engines from NGC, and starts the server. The cache volume keeps those artifacts so restarts are fast and don't re-download tens of GB. The same idea applies to the shared model stores described in the NVIDIA storage-scaling guidance.

**9.2** **Triton (Ex. 5/6):** you produced the artifact, wrote `config.pbtxt`, chose the backend and precision, built the TensorRT engine, managed version compatibility, and defined the API inputs/outputs. **NIM (Ex. 9):** you supplied a key and a GPU. Model, engine selection, server configuration, and an OpenAI-compatible API come prebuilt. The trade-off is flexibility vs. time-to-production; NIM is limited to the published models and profiles plus its customization options.

**9.3** Additional components:
- An **embedding model** (e.g., an embedding NIM) to vectorize documents and queries.
- A **vector database** (e.g., Milvus, which can use GPU-accelerated cuVS indexes).
- Optionally a **reranking** model.
- An ingestion/curation pipeline (NeMo Curator or RAPIDS for preprocessing).
- **Guardrails** (NeMo Guardrails).
- Orchestration on Kubernetes with the GPU Operator.
- Monitoring with DCGM plus application metrics.

### Exercise 10

**10.1** **RAPIDS cuDF** for ETL and **DALI** for GPU-accelerated image decoding and augmentation. Both move the CPU-bound preprocessing onto the GPU, so the GPUs stop starving.

**10.2** The storage tier is the bottleneck. Following NVIDIA's storage-scaling guidance:
- use a parallel/high-throughput filesystem or tiered storage sized for checkpoint bursts,
- use asynchronous or distributed (sharded) checkpointing,
- use local NVMe as a staging tier,
- use **GPUDirect Storage** (via `cuFile`) to cut CPU bounce buffers.

Also verify that **NCCL** runs over RDMA with the Network Operator, so communication is not the hidden limit.

**10.3** **Triton Inference Server**, using its multiple backends: TensorFlow, PyTorch/LibTorch, and the FIL backend for tree models like XGBoost. One server provides per-model versions, dynamic batching, and Prometheus metrics.

**10.4** **NVIDIA AI Enterprise**, which offers production branches, long-term support branches, security patching, and NVIDIA enterprise support.

**10.5** **NVIDIA TAO Toolkit**, a low-code transfer-learning workflow on pretrained models, with export toward TensorRT/Triton/DeepStream.

**10.6** **DCGM** (health watches, diagnostics `dcgmi diag`, XID/ECC fields) exported through **DCGM Exporter** to Prometheus/Alertmanager. In Kubernetes this is deployed by the GPU Operator; outside Kubernetes, use DCGM directly or through Base Command Manager monitoring.

**10.7** Optimize the model with **TensorRT-LLM**: in-flight batching, paged KV cache, FP8/INT4 quantization, and tensor parallelism. Serve it through **Triton** with the TensorRT-LLM backend, or deploy the equivalent prebuilt **NIM**. Validate the result with load testing (`perf_analyzer`/GenAI-Perf) against time-to-first-token and inter-token latency targets.

</details>