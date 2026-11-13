# Guided Exercises — Topic 1.4: Factors Contributing to Recent Rapid Improvements and Adoption of AI

**Certification:** NVIDIA-Certified Associate: AI Infrastructure and Operations (NCA-AIIO)
**Exam weight:** 4.75%

## What these exercises cover

AI has not improved quickly because of one breakthrough. Several factors compound on each other:

| Factor | What changed | What it does for adoption |
|---|---|---|
| **Accelerated compute** | GPUs with thousands of cores and Tensor Cores | Training goes from years to days, and inference becomes affordable |
| **Reduced precision** | FP32 → FP16/BF16 → FP8 → FP4 | 2–8× less memory and more FLOPS per watt |
| **Algorithms** | The Transformer architecture (self-attention) | Training can be parallelized across a whole sequence, and quality grows with scale |
| **Data** | Web-scale text, images, code and enterprise data | Large foundation models become possible |
| **Software stack** | CUDA, cuDNN, NCCL, TensorRT, PyTorch, Triton/NIM | Developers do not write GPU kernels by hand |
| **Interconnect and storage** | NVLink/NVSwitch, InfiniBand/RoCE, parallel file systems | Training on thousands of GPUs becomes practical |
| **Cloud-native operations** | Kubernetes with the GPU Operator, MLOps | GPUs become a schedulable, self-service resource |
| **Pretrained and open models** | Foundation models, transfer learning, fine-tuning | Enterprises adapt an existing model instead of training one from scratch |

You will measure, calculate and inspect each of these factors yourself.

### Prerequisites

- Linux with Python 3.10+ and `numpy` (`pip install numpy`).
- **Optional:** a node with an NVIDIA GPU and PyTorch with CUDA (Exercises 1 and 5).
- **Optional:** a Kubernetes cluster with at least one GPU node, plus `kubectl` and `helm` (Exercise 6).
- If you have no GPU, run the CPU and calculation steps, and read the GPU steps with their expected outputs. The questions can be answered either way.

> Outputs marked *illustrative* depend on your hardware and versions. Your numbers will be different. What matters is the **ratio** between them.

---

## Exercise 1 — Parallel compute: CPU vs GPU matrix multiplication

Deep learning is mostly dense matrix multiplication (GEMM). Multiplying two `n × n` matrices costs about `2n³` floating-point operations. GPUs run thousands of these operations at the same time, which is the main reason for the speedup in AI.

### Steps

1. Create a work directory and a benchmark script:

```bash
mkdir -p ~/aiio-1.4 && cd ~/aiio-1.4
cat > gemm_bench.py <<'EOF'
import time
import numpy as np

def bench_numpy(n, dtype, reps=5):
    a = np.random.rand(n, n).astype(dtype)
    b = np.random.rand(n, n).astype(dtype)
    a @ b  # warm-up
    t0 = time.perf_counter()
    for _ in range(reps):
        a @ b
    dt = (time.perf_counter() - t0) / reps
    return 2 * n**3 / dt / 1e9

def bench_torch(n, dtype, reps=20):
    import torch
    a = torch.rand(n, n, device="cuda", dtype=dtype)
    b = torch.rand(n, n, device="cuda", dtype=dtype)
    a @ b
    torch.cuda.synchronize()
    t0 = time.perf_counter()
    for _ in range(reps):
        a @ b
    torch.cuda.synchronize()
    dt = (time.perf_counter() - t0) / reps
    return 2 * n**3 / dt / 1e9

n = 4096
print(f"Matrix size: {n}x{n}  ({2*n**3/1e9:.1f} GFLOP per multiply)")
print(f"CPU numpy FP32 : {bench_numpy(n, np.float32):10.1f} GFLOPS")
try:
    import torch
    if torch.cuda.is_available():
        print(f"GPU {torch.cuda.get_device_name(0)}")
        print(f"GPU torch FP32 : {bench_torch(n, torch.float32):10.1f} GFLOPS")
        print(f"GPU torch FP16 : {bench_torch(n, torch.float16):10.1f} GFLOPS")
    else:
        print("No CUDA device: GPU benchmark skipped")
except ImportError:
    print("PyTorch not installed: GPU benchmark skipped")
EOF
```

2. Run it:

```bash
python3 gemm_bench.py
```

Expected output (*illustrative*, server CPU plus an H100):

```
Matrix size: 4096x4096  (137.4 GFLOP per multiply)
CPU numpy FP32 :      910.4 GFLOPS
GPU NVIDIA H100 80GB HBM3
GPU torch FP32 :    48210.7 GFLOPS
GPU torch FP16 :   612884.3 GFLOPS
```

3. Change `n = 4096` to `n = 256` and run it again. Compare how big the GPU's advantage is at the small size and at the large size.

**Questions**

- **Q1.1** Why does the GPU's advantage grow with the matrix size? What does this tell you about why GPUs suit *large* models and *batched* workloads?
- **Q1.2** The FP16 result is many times higher than the FP32 result on the same GPU. Which hardware unit explains this?
- **Q1.3** Why does the script call `torch.cuda.synchronize()` before it reads the clock?

---

## Exercise 2 — Reduced precision and memory footprint

The size of a model in GPU memory is roughly *parameters × bytes per parameter*. Lower precision lets bigger models fit on fewer GPUs. It also raises the useful FLOPS and memory bandwidth per GPU.

### Steps

1. Create the calculator:

```bash
cat > footprint.py <<'EOF'
FORMATS = {"FP32": 4, "BF16/FP16": 2, "FP8": 1, "FP4": 0.5}
GPU_MEM_GB = 80  # e.g. H100 80GB

def weights_gb(params, bytes_per_param):
    return params * bytes_per_param / 1e9

for name, params in [("8B", 8e9), ("70B", 70e9), ("405B", 405e9)]:
    print(f"--- {name} model ---")
    for fmt, b in FORMATS.items():
        gb = weights_gb(params, b)
        gpus = -(-gb // GPU_MEM_GB)  # ceiling division
        print(f"  {fmt:10s} {gb:8.1f} GB weights  -> min {int(gpus)} x 80GB GPU (weights only)")

# KV cache for a Llama-3-70B-like architecture (GQA)
layers, kv_heads, head_dim, kv_bytes = 80, 8, 128, 2
per_token = 2 * layers * kv_heads * head_dim * kv_bytes
seqs, ctx = 32, 8192
total = per_token * seqs * ctx
print(f"\nKV cache per token : {per_token} bytes ({per_token/2**20:.3f} MiB)")
print(f"KV cache {seqs} seqs x {ctx} tokens: {total/1e9:.1f} GB")
EOF
python3 footprint.py
```

Expected output (deterministic):

```
--- 8B model ---
  FP32           32.0 GB weights  -> min 1 x 80GB GPU (weights only)
  BF16/FP16      16.0 GB weights  -> min 1 x 80GB GPU (weights only)
  FP8             8.0 GB weights  -> min 1 x 80GB GPU (weights only)
  FP4             4.0 GB weights  -> min 1 x 80GB GPU (weights only)
--- 70B model ---
  FP32          280.0 GB weights  -> min 4 x 80GB GPU (weights only)
  BF16/FP16     140.0 GB weights  -> min 2 x 80GB GPU (weights only)
  FP8            70.0 GB weights  -> min 1 x 80GB GPU (weights only)
  FP4            35.0 GB weights  -> min 1 x 80GB GPU (weights only)
--- 405B model ---
  FP32         1620.0 GB weights  -> min 21 x 80GB GPU (weights only)
  BF16/FP16     810.0 GB weights  -> min 11 x 80GB GPU (weights only)
  FP8           405.0 GB weights  -> min 6 x 80GB GPU (weights only)
  FP4           202.5 GB weights  -> min 3 x 80GB GPU (weights only)

KV cache per token : 327680 bytes (0.312 MiB)
KV cache 32 seqs x 8192 tokens: 85.9 GB
```

**Questions**

- **Q2.1** A 70B model in FP8 needs "min 1 × 80GB GPU". Why would that single GPU still be a poor choice to serve it in production?
- **Q2.2** The script models Grouped-Query Attention with 8 KV heads instead of the full 64 query heads. By how much does that reduce the KV cache? Why is this an *algorithmic* factor in adoption and not a hardware one?
- **Q2.3** Name the GPU generations that brought Tensor Core support for FP8 and for FP4. In general terms, what does each step mean for cost per inference?

---

## Exercise 3 — Scaling laws and compute: why the GPU generation matters

A common estimate for the compute needed to train a dense Transformer is **FLOPs ≈ 6 × N × D**, where `N` is the number of parameters and `D` is the number of training tokens. The Chinchilla result suggests a compute-optimal `D` of about 20 tokens per parameter. Scaling laws showed that loss falls *predictably* as compute grows. That predictability is why organizations were willing to invest in very large GPU clusters.

### Steps

1. Create the estimator:

```bash
cat > train_time.py <<'EOF'
GPUS = {  # dense Tensor Core peak, BF16/FP16, TFLOPS (datasheet values)
    "V100": 125,
    "A100": 312,
    "H100 SXM": 989,
}
MFU = 0.40          # model FLOPs utilization actually achieved
CLUSTER = 1024      # number of GPUs

def days(params, tokens, peak_tflops):
    flops = 6 * params * tokens
    eff = peak_tflops * 1e12 * MFU * CLUSTER
    return flops / eff / 86400, flops

for label, n, d in [("7B / 2T tokens", 7e9, 2e12),
                    ("70B / 1.4T tokens (Chinchilla)", 70e9, 1.4e12)]:
    print(f"--- {label} ---")
    for gpu, tf in GPUS.items():
        dd, flops = days(n, d, tf)
        print(f"  {gpu:9s} total {flops:.2e} FLOPs -> {dd:7.1f} days on {CLUSTER} GPUs")
EOF
python3 train_time.py
```

Expected output (deterministic):

```
--- 7B / 2T tokens ---
  V100      total 8.40e+22 FLOPs ->    19.0 days on 1024 GPUs
  A100      total 8.40e+22 FLOPs ->     7.6 days on 1024 GPUs
  H100 SXM  total 8.40e+22 FLOPs ->     2.4 days on 1024 GPUs
--- 70B / 1.4T tokens (Chinchilla) ---
  V100      total 5.88e+23 FLOPs ->   132.9 days on 1024 GPUs
  A100      total 5.88e+23 FLOPs ->    53.3 days on 1024 GPUs
  H100 SXM  total 5.88e+23 FLOPs ->    16.8 days on 1024 GPUs
```

2. Change `MFU = 0.40` to `MFU = 0.20` and run it again. Watch how the training time changes.

**Questions**

- **Q3.1** In the 70B case, the move from V100 to H100 turns roughly 4 months into roughly 2 weeks. Explain how this affects how often a team can iterate, and why it drives adoption.
- **Q3.2** Halving the MFU doubles the training time. Name three infrastructure factors *outside* the GPU chip that lower MFU on a 1,024-GPU cluster.
- **Q3.3** By the Chinchilla rule of thumb, how many tokens are compute-optimal for a 70B model? Why is data availability itself a factor in AI progress?

---

## Exercise 4 — The Transformer: why it fits GPUs

Recurrent networks (RNNs/LSTMs) process tokens one after another, because each step depends on the hidden state from the step before. Self-attention computes the relationship between all tokens with a few matrix multiplications. That is exactly the workload from Exercise 1.

### Steps

1. Compare the two approaches in NumPy:

```bash
cat > attention_vs_rnn.py <<'EOF'
import time
import numpy as np

rng = np.random.default_rng(0)
seq, d = 512, 256
x = rng.standard_normal((seq, d)).astype(np.float32)

# RNN: inherently sequential
W_h = rng.standard_normal((d, d)).astype(np.float32) * 0.01
W_x = rng.standard_normal((d, d)).astype(np.float32) * 0.01
t0 = time.perf_counter()
h = np.zeros(d, dtype=np.float32)
for t in range(seq):                 # step t needs h from step t-1
    h = np.tanh(h @ W_h + x[t] @ W_x)
rnn_t = time.perf_counter() - t0

# Self-attention: whole sequence at once
Wq, Wk, Wv = (rng.standard_normal((d, d)).astype(np.float32) * 0.01 for _ in range(3))
t0 = time.perf_counter()
Q, K, V = x @ Wq, x @ Wk, x @ Wv     # 3 GEMMs over all tokens
scores = Q @ K.T / np.sqrt(d)        # (seq x seq) GEMM
scores -= scores.max(axis=1, keepdims=True)
w = np.exp(scores)
w /= w.sum(axis=1, keepdims=True)
out = w @ V                          # GEMM
att_t = time.perf_counter() - t0

print(f"RNN       : {seq} dependent steps, {rnn_t*1e3:7.2f} ms")
print(f"Attention : 5 matrix multiplies,  {att_t*1e3:7.2f} ms, output {out.shape}")
print(f"Attention score matrix: {scores.shape} -> memory grows with seq^2")
EOF
python3 attention_vs_rnn.py
```

Expected output (*illustrative*):

```
RNN       : 512 dependent steps,    9.84 ms
Attention : 5 matrix multiplies,     3.12 ms, output (512, 256)
Attention score matrix: (512, 512) -> memory grows with seq^2
```

2. Change `seq` to `4096` and run it again. Watch the attention time and the size of the score matrix.

**Questions**

- **Q4.1** Attention does *more* arithmetic than the RNN, yet it scales better on a GPU. Why?
- **Q4.2** What does the `seq²` score matrix mean for long contexts? Name one optimized kernel that addresses it.
- **Q4.3** Which year and which paper introduced the Transformer? Name the three families of model it enabled (encoder-only, decoder-only, encoder-decoder) with one example of each.

---

## Exercise 5 — The software stack: from driver to optimized engine

Hardware alone did not cause the AI boom. A mature software stack lets a data scientist write `model.to("cuda")` and get optimized kernels without writing them. In this exercise you inspect that stack layer by layer.

### Steps

1. Inspect the driver and the GPU (on a GPU node):

```bash
nvidia-smi --query-gpu=name,driver_version,memory.total,compute_cap --format=csv
```

Expected output (*illustrative*):

```
name, driver_version, memory.total [MiB], compute_cap
NVIDIA H100 80GB HBM3, 560.35.03, 81559 MiB, 9.0
```

2. Inspect the CUDA and library versions that the framework uses:

```bash
python3 -c "import torch; print('torch', torch.__version__); print('CUDA', torch.version.cuda); print('cuDNN', torch.backends.cudnn.version()); print('NCCL', torch.cuda.nccl.version())"
```

Expected output (*illustrative*):

```
torch 2.5.1+cu124
CUDA 12.4
cuDNN 90100
NCCL (2, 21, 5)
```

3. Optimize a model with TensorRT. Export a small ONNX model, then build an engine with `trtexec`. You can run it inside the NGC TensorRT container, which already contains `trtexec`:

```bash
python3 - <<'EOF'
import torch, torchvision
m = torchvision.models.resnet50(weights=None).eval()
torch.onnx.export(m, torch.randn(1, 3, 224, 224), "resnet50.onnx",
                  input_names=["input"], output_names=["logits"], opset_version=17)
print("exported resnet50.onnx")
EOF

docker run --rm --gpus all -v "$PWD":/w -w /w nvcr.io/nvidia/tensorrt:24.10-py3 \
  trtexec --onnx=resnet50.onnx --saveEngine=resnet50_fp16.engine --fp16
```

Expected tail of the output (*illustrative*):

```
[I] === Performance summary ===
[I] Throughput: 2873.41 qps
[I] Latency: min = 0.33 ms, max = 0.52 ms, mean = 0.35 ms, median = 0.35 ms, percentile(99%) = 0.41 ms
...
&&&& PASSED TensorRT.trtexec [TensorRT v100500] # trtexec --onnx=resnet50.onnx --saveEngine=resnet50_fp16.engine --fp16
```

4. Build the engine again without `--fp16` (this gives FP32/TF32) and compare `Throughput`.

**Questions**

- **Q5.1** Place these components in order from hardware to application, and give the role of each: CUDA, the NVIDIA driver, cuDNN, PyTorch, TensorRT, NCCL.
- **Q5.2** Name three optimizations that TensorRT applies when it builds an engine.
- **Q5.3** A TensorRT engine is usually built *on the same GPU model* where it will run. Why?

---

## Exercise 6 — Cloud-native adoption: GPUs as a Kubernetes resource

Enterprises adopt AI faster when GPUs behave like any other resource in the platform they already run. The NVIDIA GPU Operator automates the driver, the container toolkit, the device plugin, node labelling and monitoring on Kubernetes nodes.

### Steps

1. Install the GPU Operator:

```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
helm install --wait --generate-name -n gpu-operator --create-namespace nvidia/gpu-operator
```

2. Check the components:

```bash
kubectl get pods -n gpu-operator
```

Expected output (*illustrative*, names shortened):

```
NAME                                                READY   STATUS      RESTARTS   AGE
gpu-feature-discovery-x7k2p                         1/1     Running     0          4m
gpu-operator-6f8c9d8b5-q2w9l                        1/1     Running     0          5m
nvidia-container-toolkit-daemonset-l9b4d            1/1     Running     0          4m
nvidia-cuda-validator-8m2tf                         0/1     Completed   0          2m
nvidia-dcgm-exporter-p4h7s                          1/1     Running     0          4m
nvidia-device-plugin-daemonset-v6c3n                1/1     Running     0          4m
nvidia-driver-daemonset-r5q8z                       1/1     Running     0          5m
nvidia-operator-validator-h2j6k                     1/1     Running     0          4m
gpu-operator-...-node-feature-discovery-worker-...  1/1     Running     0          5m
```

3. Check that the node now advertises GPUs:

```bash
kubectl get nodes -o custom-columns='NODE:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu,PRODUCT:.metadata.labels.nvidia\.com/gpu\.product'
```

Expected output (*illustrative*):

```
NODE          GPUS   PRODUCT
gpu-node-01   8      NVIDIA-H100-80GB-HBM3
```

4. Save this manifest as `cuda-vectoradd.yaml`. It requests one GPU:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cuda-vectoradd
spec:
  restartPolicy: OnFailure
  containers:
    - name: cuda-vectoradd
      image: "nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0"
      resources:
        limits:
          nvidia.com/gpu: 1
```

```bash
kubectl apply -f cuda-vectoradd.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/cuda-vectoradd --timeout=120s
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

5. Clean up:

```bash
kubectl delete pod cuda-vectoradd
```

**Questions**

- **Q6.1** Without the GPU Operator, which manual steps would an administrator have to perform on every GPU node? Which daemonset replaces each step?
- **Q6.2** Why does `nvidia.com/gpu` appear under `limits`, and why can it not be overcommitted like CPU?
- **Q6.3** Which component exports GPU metrics to Prometheus? Name two metrics you would alert on.

---

## Exercise 7 — Inference economics: why optimization drives adoption

Many organizations decide to adopt AI based on **cost per unit of work**, such as cost per million tokens. Optimizations like lower precision, in-flight batching and optimized kernels raise throughput on the same hardware. That lowers the unit cost directly.

### Steps

1. Model the cost (the prices are hypothetical):

```bash
cat > inference_cost.py <<'EOF'
GPU_HOUR_USD = 3.00          # hypothetical price per GPU-hour
DAILY_TOKENS = 1_000_000_000 # 1B generated tokens/day

scenarios = {
    "Baseline (BF16, static batching)": 2500,
    "Optimized (FP8 + in-flight batching)": 6250,
}
for name, tps in scenarios.items():
    tok_per_hour = tps * 3600
    usd_per_m = GPU_HOUR_USD / (tok_per_hour / 1e6)
    gpus = DAILY_TOKENS / (tps * 86400)
    print(f"{name}")
    print(f"  {tps} tok/s/GPU -> ${usd_per_m:.3f} per 1M tokens, "
          f"{gpus:.2f} GPUs, ${usd_per_m * DAILY_TOKENS / 1e6:,.0f}/day")
EOF
python3 inference_cost.py
```

Expected output (deterministic):

```
Baseline (BF16, static batching)
  2500 tok/s/GPU -> $0.333 per 1M tokens, 4.63 GPUs, $333/day
Optimized (FP8 + in-flight batching)
  6250 tok/s/GPU -> $0.133 per 1M tokens, 1.85 GPUs, $133/day
```

**Questions**

- **Q7.1** The optimization is pure software and runs on the same hardware. By how much does it lower the cost? Give one reason this matters more for inference than for training over the life of a model.
- **Q7.2** Raising batch size raises throughput. Which user-facing metric usually gets worse, and how do teams balance the two?
- **Q7.3** Name the NVIDIA offerings that package optimized inference so an enterprise does not have to tune it by hand.

---

## Exercise 8 — Data and storage: where the I/O bottleneck really is

Huge datasets made modern AI possible. However, storage requirements for large training jobs often depend more on **checkpointing** and on multimodal data than on reading tokenized text.

### Steps

1. Estimate the I/O:

```bash
cat > storage_io.py <<'EOF'
params = 7e9
gpus = 1024
eff_flops_per_gpu = 989e12 * 0.40          # H100, 40% MFU
tokens_per_s_gpu = eff_flops_per_gpu / (6 * params)
cluster_tps = tokens_per_s_gpu * gpus
bytes_per_token = 4                        # uint32 token ids
print(f"Tokens/s per GPU  : {tokens_per_s_gpu:,.0f}")
print(f"Text read rate    : {cluster_tps * bytes_per_token / 1e6:,.1f} MB/s for the whole cluster")

ckpt_bytes = params * 16                   # weights + grads + Adam states, mixed precision
for window in (600, 60):
    print(f"Checkpoint {ckpt_bytes/1e9:.0f} GB in {window:>3}s -> {ckpt_bytes/window/1e9:.2f} GB/s write")

imgs_per_s = 1024 * 3000                   # e.g. vision training
print(f"Vision: {imgs_per_s:,} img/s x 110 KB = {imgs_per_s*110e3/1e9:.0f} GB/s read")
EOF
python3 storage_io.py
```

Expected output (deterministic):

```
Tokens/s per GPU  : 9,419
Text read rate    : 38.6 MB/s for the whole cluster
Checkpoint 112 GB in 600s -> 0.19 GB/s write
Checkpoint 112 GB in  60s -> 1.87 GB/s write
Vision: 3,072,000 img/s x 110 KB = 338 GB/s read
```

**Questions**

- **Q8.1** Reading text tokens needs only about 39 MB/s. Why do training clusters still need high-performance shared storage?
- **Q8.2** Why does a short checkpoint window matter? Link it to GPU utilization and to the cost of failures at scale.
- **Q8.3** Name two techniques from NVIDIA's storage guidance that reduce pressure on the shared file system during training.

---

## Exercise 9 — Synthesis: an exam-style scenario

> A retail company tried to build a product-recommendation chatbot in 2018 with LSTMs on CPU servers. It gave up because training took weeks and answers were poor. In 2025 it ships a chatbot in six weeks. The chatbot uses an open 8B LLM, is fine-tuned on product data, is served with TensorRT-LLM in FP8 on a Kubernetes cluster with the GPU Operator, and runs at an acceptable cost per query.

### Steps

1. Build a table with one row for each factor in the introduction. In each row, write the concrete element of the 2025 project that matches the factor.
2. Pick the **two** factors you consider decisive for *this* company. Justify the choice in no more than three sentences.

**Questions**

- **Q9.1** Why did the company not need to train a model from scratch? Which factor does this show?
- **Q9.2** If GPU prices doubled tomorrow, which factor in the 2025 stack would soften the impact the most, and why?
- **Q9.3** For each answer, say whether it is primarily a factor of *improvement* (better models) or of *adoption* (easier or cheaper to use): GPU Operator, Transformer, FP8, NIM, scaling laws.

---

## Answers

<details>
<summary>Click to show the answers</summary>

### Exercise 1

- **Q1.1** The compute grows as `n³`, while the fixed costs (kernel launch, data movement, synchronization) stay roughly constant. Small matrices cannot keep thousands of GPU cores busy. Large ones saturate them. This is why GPUs shine with large models and batched requests, and why serving engines batch requests together.
- **Q1.2** **Tensor Cores.** They are specialized units for mixed-precision matrix multiply-accumulate. They give many times the throughput of the general CUDA cores for FP16/BF16 (and FP8/FP4 on newer generations).
- **Q1.3** CUDA kernel launches are **asynchronous**: the Python call returns before the GPU finishes. Without `synchronize()`, you would measure only the launch time and not the compute time.

### Exercise 2

- **Q2.1** Only about 10 GB would be left for the KV cache, activations and runtime overhead. The script shows the KV cache alone can reach about 86 GB for 32 concurrent sequences of 8K tokens. You would get very little concurrency or very short contexts. A production deployment uses more GPUs (tensor parallelism) or GPUs with more memory.
- **Q2.2** The KV cache is 64/8 = **8× smaller**. GQA is a change to the model architecture (an algorithm) that cuts memory per token. It lets the *same* hardware serve more users or longer contexts, which lowers the cost of inference.
- **Q2.3** FP8 arrived with **Hopper** (H100, Transformer Engine). FP4 arrived with **Blackwell** (B200/GB200). Each halving of precision roughly doubles the Tensor Core throughput and halves the memory and bandwidth per parameter. The result is more tokens per second per GPU and lower cost per inference, as long as accuracy holds through calibration and scaling.

### Exercise 3

- **Q3.1** Shorter training runs let a team test more architectures, data mixes and hyperparameters in the same calendar time. Faster iteration produces better models, and ROI arrives sooner. Both make investment and adoption easier to justify.
- **Q3.2** Possible answers: slow interconnect between nodes (InfiniBand or RoCE bandwidth and latency) for gradient all-reduce; a lack of NVLink/NVSwitch inside the node; storage stalls while loading data or writing checkpoints; stragglers and failures, with restarts from a checkpoint; a poor parallelism strategy, with pipeline bubbles; CPU or data-loader bottlenecks.
- **Q3.3** About **1.4 trillion** tokens (20 × 70B). Better models need more high-quality data. The availability of web-scale text, code and images, plus the tools to curate it, is what made it possible to grow models usefully.

### Exercise 4

- **Q4.1** The RNN has a **sequential dependency**: step *t* cannot start until step *t-1* finishes, so it cannot be parallelized across the sequence. Attention turns the whole sequence into a few large GEMMs. These are fully parallel and map directly to Tensor Cores. On a GPU, the parallel structure matters more than the total number of FLOPs.
- **Q4.2** The memory and compute of naive attention grow quadratically with context length. **FlashAttention** computes attention in tiles inside on-chip SRAM and never materializes the full `seq × seq` matrix. (Paged KV cache management, as in vLLM or TensorRT-LLM, addresses the memory used during serving.)
- **Q4.3** "Attention Is All You Need", Vaswani et al., **2017**. The families are: encoder-only (BERT), decoder-only (GPT, Llama), and encoder-decoder (T5).

### Exercise 5

- **Q5.1** From hardware upward:
  1. **NVIDIA driver** — exposes the GPU to the OS.
  2. **CUDA** — the programming model and runtime.
  3. **cuDNN** — optimized deep-learning primitives such as convolutions and attention.
  4. **NCCL** — multi-GPU and multi-node collectives such as all-reduce.
  5. **PyTorch** — the framework that calls these libraries.
  6. **TensorRT** — an inference optimizer and runtime that takes the trained model (often exported as ONNX) and produces an optimized engine.
- **Q5.2** Possible answers: layer and tensor fusion; precision calibration (FP16/FP8/INT8); kernel auto-tuning per GPU; dynamic tensor memory reuse; multi-stream execution.
- **Q5.3** During the build, TensorRT **picks the fastest kernels for the specific GPU architecture** (auto-tuning) and the TensorRT version. An engine is not portable across architectures, and is not guaranteed to be optimal on a different GPU.

### Exercise 6

- **Q6.1** Each manual step and the daemonset that replaces it:

  | Manual step | Replaced by |
  |---|---|
  | Install the kernel driver | `nvidia-driver-daemonset` |
  | Configure the container runtime | `nvidia-container-toolkit-daemonset` |
  | Deploy the device plugin to advertise `nvidia.com/gpu` | `nvidia-device-plugin-daemonset` |
  | Label nodes by GPU model and capabilities | `gpu-feature-discovery` (with NFD) |
  | Set up monitoring | `nvidia-dcgm-exporter` |
  | Validate the stack | `nvidia-operator-validator` |

  Doing this by hand on every node, and again on every upgrade, slows adoption.
- **Q6.2** Extended resources such as GPUs are **integer-only and cannot be overcommitted**. If you set a request, it must equal the limit, and the limit alone is enough. A whole GPU is assigned to the container. Sharing is done explicitly with MIG, time-slicing or MPS.
- **Q6.3** The **DCGM Exporter**. Possible metrics: `DCGM_FI_DEV_GPU_UTIL` (utilization), `DCGM_FI_DEV_FB_USED` (frame-buffer memory used), `DCGM_FI_DEV_GPU_TEMP` (temperature), `DCGM_FI_DEV_XID_ERRORS` (Xid errors), `DCGM_FI_DEV_POWER_USAGE` (power).

### Exercise 7

- **Q7.1** **2.5× cheaper** ($0.333 → $0.133 per 1M tokens), and from about 4.6 GPUs to about 1.9 GPUs. Training is a large one-time cost. Inference runs continuously and grows with users, so over the life of a model the total inference cost often exceeds the training cost.
- **Q7.2** **Latency**, such as time to first token or inter-token latency, gets worse. Teams set an SLO (for example, a P99 latency) and tune batching (in-flight or continuous batching, maximum batch size) to get the most throughput that still meets the SLO.
- **Q7.3** **NVIDIA NIM** (prepackaged inference microservices), **Triton Inference Server**, and **TensorRT-LLM**, all part of **NVIDIA AI Enterprise**.

### Exercise 8

- **Q8.1** Several reasons:
  - Checkpoint writes are large and bursty.
  - Multimodal data (images, video, audio) needs hundreds of GB/s.
  - Thousands of clients open and read files at the same time.
  - The first epoch, or data that cannot be cached, must be read from shared storage.
  - Model loading for inference (cold start) and the storage behind RAG also need fast shared storage.
- **Q8.2** While a checkpoint is being written, GPUs often sit idle or are slowed down. At the scale of thousands of GPUs, failures are frequent, so checkpoints must be taken often. A short window keeps GPU utilization (and MFU) high, and limits the work lost when a job has to restart.
- **Q8.3** Possible answers: cache the dataset on local NVMe in each node after the first read; GPUDirect Storage (a direct path from storage to GPU memory, without a bounce through the CPU); asynchronous or tiered checkpointing (write to local storage first, then drain to shared storage); a parallel file system that scales its bandwidth with more nodes; separate networks for storage and compute.

### Exercise 9

- **Q9.1** Thanks to **pretrained foundation models and transfer learning (fine-tuning)**, the company reused the general knowledge of an open 8B LLM and only adapted it to its product data. That costs orders of magnitude less compute and data than pretraining.
- **Q9.2** **Inference optimization** (FP8 with TensorRT-LLM and in-flight batching), together with the choice of a small 8B model. More tokens per GPU-hour means fewer GPUs for the same load, which offsets a higher price per GPU.
- **Q9.3**
  - **GPU Operator** — adoption (operational simplicity).
  - **Transformer** — improvement (better and more scalable models).
  - **FP8** — both: improvement (more compute for training) and adoption (cheaper inference).
  - **NIM** — adoption (packaged deployment).
  - **Scaling laws** — improvement (they predict better models), with an indirect effect on adoption because they justified the investment.

</details>

---

## Sources

- NVIDIA, *NCA-AIIO Exam Study Guide*: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy, *AI Infrastructure and Operations Fundamentals*: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA TensorRT: https://developer.nvidia.com/tensorrt
- NVIDIA AI Inference: https://developer.nvidia.com/topics/ai/ai-inference
- *Tips on Scaling Storage for AI Training and Inferencing*: https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
- *What Are Large Language Models Used For?*: https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
- *NVIDIA GPU Operator: Simplifying GPU Management in Kubernetes*: https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes
- Vaswani et al., *Attention Is All You Need* (2017): https://arxiv.org/abs/1706.03762
- Hoffmann et al., *Training Compute-Optimal Large Language Models* (Chinchilla, 2022): https://arxiv.org/abs/2203.15556