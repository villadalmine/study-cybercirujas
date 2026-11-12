# Guided Exercises — Topic 1.5: Explain the Key AI Use Cases and Industries

> **Exam:** NCA-AIIO · **Weight:** 4.75%
> **Goal:** Go beyond memorizing "industry X uses AI for Y." For each use case, work out what it requires from the infrastructure: workload phase, latency class, memory footprint, storage I/O pattern and NVIDIA software stack. The exam asks you to *explain* use cases. Infrastructure engineers explain them through the resources they consume.

**Official sources used throughout:**
- NCA-AIIO exam guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- AI Infrastructure and Operations Fundamentals course: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA AI Inference: https://developer.nvidia.com/topics/ai/ai-inference
- NVIDIA TensorRT: https://developer.nvidia.com/tensorrt
- What are LLMs used for: https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
- Scaling storage for AI training and inferencing: https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
- NVIDIA GPU Operator: https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes

**What you need:**

| Exercises | Requirements |
|---|---|
| 1–3, 6, 7 | Any Linux/macOS machine with Python 3.9+ and `pyyaml`. No GPU. |
| 4–5 | A Kubernetes cluster with at least one NVIDIA GPU node and the NVIDIA GPU Operator installed. If you have none, read the steps and the expected output, then answer the questions. |

```bash
mkdir -p ~/aiio-1.5 && cd ~/aiio-1.5
python3 -m pip install --user pyyaml
```

---

## Exercise 1 — Build an industry use-case catalog and classify it by workload profile

The same AI technique has very different infrastructure needs depending on where it runs. A vision model that inspects parts on a factory line has a hard real-time budget. The same architecture screening medical archives overnight is a throughput-bound batch job. In this exercise you encode that distinction as data.

**Step 1.** Create the catalog. Every value that contains `: ` is quoted so the file parses.

```bash
cat > ~/aiio-1.5/use_cases.yaml <<'EOF'
use_cases:
  - industry: Healthcare
    use_case: Medical imaging segmentation (CT/MRI)
    ai_type: perception
    phase: inference
    latency_class: interactive
    nvidia_stack: [Clara, MONAI, Holoscan]
  - industry: Life sciences
    use_case: Drug discovery, protein structure and molecule generation
    ai_type: generative
    phase: training+batch-inference
    latency_class: batch
    nvidia_stack: [BioNeMo]
  - industry: Financial services
    use_case: Real-time fraud detection on card transactions
    ai_type: predictive
    phase: inference
    latency_class: real-time
    nvidia_stack: [RAPIDS, Triton, Morpheus]
  - industry: Retail
    use_case: Product recommendation engine
    ai_type: predictive
    phase: training+inference
    latency_class: interactive
    nvidia_stack: [Merlin, Triton]
  - industry: Automotive
    use_case: "Autonomous driving perception (camera, radar, lidar)"
    ai_type: perception
    phase: training+edge-inference
    latency_class: real-time
    nvidia_stack: [DRIVE, Omniverse]
  - industry: Manufacturing
    use_case: Visual defect inspection on the production line
    ai_type: perception
    phase: edge-inference
    latency_class: real-time
    nvidia_stack: [Metropolis, TensorRT, DeepStream]
  - industry: Manufacturing
    use_case: Factory digital twin and robot simulation
    ai_type: simulation
    phase: training
    latency_class: batch
    nvidia_stack: [Omniverse, Isaac]
  - industry: Telecommunications
    use_case: Customer-service chatbot with RAG over internal docs
    ai_type: generative
    phase: inference
    latency_class: interactive
    nvidia_stack: [NeMo, NIM, Triton]
  - industry: Cybersecurity
    use_case: Anomaly detection on network telemetry
    ai_type: predictive
    phase: inference
    latency_class: real-time
    nvidia_stack: [Morpheus]
  - industry: Logistics
    use_case: Route optimization for delivery fleets
    ai_type: optimization
    phase: inference
    latency_class: interactive
    nvidia_stack: [cuOpt]
  - industry: Media and entertainment
    use_case: Speech recognition and subtitle translation
    ai_type: generative
    phase: inference
    latency_class: real-time
    nvidia_stack: [Riva]
  - industry: Public sector / smart cities
    use_case: Traffic video analytics
    ai_type: perception
    phase: edge-inference
    latency_class: real-time
    nvidia_stack: [Metropolis, DeepStream]
  - industry: Climate and energy
    use_case: Weather and climate forecasting
    ai_type: simulation
    phase: training+batch-inference
    latency_class: batch
    nvidia_stack: [Earth-2, Modulus]
EOF
```

**Step 2.** Write the classifier. It validates the file and groups use cases by latency class and by AI type.

```bash
cat > ~/aiio-1.5/classify.py <<'EOF'
import sys
from collections import defaultdict
import yaml

VALID_LATENCY = {"real-time", "interactive", "batch"}

with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)

by_latency = defaultdict(list)
by_type = defaultdict(int)
for uc in data["use_cases"]:
    lc = uc["latency_class"]
    if lc not in VALID_LATENCY:
        sys.exit(f"invalid latency_class {lc!r} in {uc['use_case']}")
    by_latency[lc].append(f"{uc['industry']}: {uc['use_case']}")
    by_type[uc["ai_type"]] += 1

for lc in ["real-time", "interactive", "batch"]:
    print(f"== {lc} ({len(by_latency[lc])}) ==")
    for item in by_latency[lc]:
        print(f"  - {item}")

print("\nai_type counts:")
for t, n in sorted(by_type.items()):
    print(f"  {t:<13}{n}")
EOF
python3 ~/aiio-1.5/classify.py ~/aiio-1.5/use_cases.yaml
```

Expected output:

```
== real-time (5) ==
  - Financial services: Real-time fraud detection on card transactions
  - Automotive: Autonomous driving perception (camera, radar, lidar)
  - Manufacturing: Visual defect inspection on the production line
  - Cybersecurity: Anomaly detection on network telemetry
  - Media and entertainment: Speech recognition and subtitle translation
  - Public sector / smart cities: Traffic video analytics
...
```

The real-time group has **6** entries, not 5. Count them and fix the header in your head. Better still, run the script and confirm that the header it prints (computed with `len()`) matches what you see. The full expected output is in the answers section.

**Step 3.** Break the YAML on purpose. Change `use_case: "Autonomous driving perception (camera, radar, lidar)"` to an unquoted value that contains a colon, for example `use_case: Perception: camera, radar, lidar`. Run the script again, then revert the change.

**Questions — Exercise 1**

1.1. Five of the six real-time use cases run in *inference*. Why does that make sense? What component would you place between the model and the application to meet a millisecond budget?
1.2. Autonomous driving appears as `training+edge-inference`. Where does each phase physically run, and why can't the inference phase run in a remote data center?
1.3. What error did Step 3 produce, and why does it matter when this catalog is used as input to automation?
1.4. The NVIDIA LLM blog lists generation, summarization, translation, classification, code generation and chatbots as LLM uses. Which catalog entries are LLM-based? Which are generative but *not* LLM-based?

---

## Exercise 2 — Size an LLM inference use case (weights + KV cache)

The most common enterprise use case on the exam is **generative AI / LLM inference** (chatbots, RAG, summarization). Its memory profile determines which GPU you need and how many. GPU memory holds two things:

- **Weights:** `parameters × bytes_per_parameter`. This is fixed per model and precision.
- **KV cache:** `2 (K and V) × layers × kv_heads × head_dim × bytes × tokens_in_flight`. It grows with context length × concurrent requests.

**Step 1.** Create the sizing script. It uses nominal parameter counts and the published architecture of Llama 3 8B and 70B (Grouped-Query Attention with 8 KV heads).

```bash
cat > ~/aiio-1.5/llm_sizing.py <<'EOF'
MODELS = {
    "llama3-8b":  {"params": 8e9,  "layers": 32, "kv_heads": 8, "head_dim": 128},
    "llama3-70b": {"params": 70e9, "layers": 80, "kv_heads": 8, "head_dim": 128},
}
PRECISION_BYTES = {"FP16": 2, "FP8": 1, "INT4": 0.5}

CONCURRENT_SEQS = 16
CONTEXT_TOKENS = 8192
KV_BYTES = 2  # KV cache kept in FP16

print(f"{'model':<12} {'precision':<10} {'weights_GB':>10}")
for name, m in MODELS.items():
    for p, b in PRECISION_BYTES.items():
        print(f"{name:<12} {p:<10} {m['params'] * b / 1e9:>10.1f}")

print(f"\nKV cache (FP16), {CONCURRENT_SEQS} seqs x {CONTEXT_TOKENS} tokens:")
for name, m in MODELS.items():
    per_token = 2 * m["layers"] * m["kv_heads"] * m["head_dim"] * KV_BYTES
    total = per_token * CONCURRENT_SEQS * CONTEXT_TOKENS
    print(f"{name:<12} per-token={per_token / 1024:.1f} KiB  total={total / 1e9:.1f} GB")
EOF
python3 ~/aiio-1.5/llm_sizing.py
```

Expected output:

```
model        precision  weights_GB
llama3-8b    FP16             16.0
llama3-8b    FP8               8.0
llama3-8b    INT4              4.0
llama3-70b   FP16            140.0
llama3-70b   FP8              70.0
llama3-70b   INT4             35.0

KV cache (FP16), 16 seqs x 8192 tokens:
llama3-8b    per-token=128.0 KiB  total=17.2 GB
llama3-70b   per-token=320.0 KiB  total=42.9 GB
```

**Step 2.** Fill in the table for three use cases, each targeting a single 80 GB GPU (for example H100 80GB). Leave roughly 10% headroom for activations and the CUDA context.

| Use case | Model / precision | Weights | KV cache | Total | Fits on 1 × 80 GB? |
|---|---|---|---|---|---|
| Internal HR chatbot | 8B / FP16 | ? | ? | ? | ? |
| Legal document summarization | 70B / FP8 | ? | ? | ? | ? |
| Code assistant | 70B / INT4 | ? | ? | ? | ? |

**Step 3.** Edit `CONCURRENT_SEQS = 4` and rerun.

**Questions — Exercise 2**

2.1. Complete the Step 2 table.
2.2. For the 70B / FP8 case, give three levers that make it fit or scale, and the trade-off each one has.
2.3. Why is the KV cache per token of the 70B model only 2.5× that of the 8B model, when the 70B model has ~8.75× the parameters?
2.4. TensorRT and TensorRT-LLM support FP8 and INT4 quantization. Which of the two memory components does weight quantization reduce, and which does it leave unchanged?

---

## Exercise 3 — Latency vs throughput: matching use cases to SLAs

NVIDIA's inference page frames production inference as a trade-off between **latency** (time per request) and **throughput** (requests or tokens per second) at a given cost. Industries sit at different points on that curve. You will quantify it with Little's Law: `concurrency = throughput × latency`.

**Step 1.** Compute by hand or in a Python REPL:

```bash
python3 - <<'EOF'
# Use case A: telecom chatbot
concurrent_users = 200
latency_s = 4.0          # end-to-end time per answer
print("A) required throughput:", concurrent_users / latency_s, "req/s")

# Use case B: virtual screening in drug discovery (batch)
molecules = 10_000_000
per_gpu_rate = 2_000     # molecules/s per GPU
gpus = 8
t = molecules / (per_gpu_rate * gpus)
print(f"B) wall time on {gpus} GPUs: {t:.0f} s = {t/60:.1f} min")

# Use case C: card fraud scoring
tps = 50_000             # transactions per second
p99_budget_ms = 10
print("C) requests in flight at budget:", tps * p99_budget_ms / 1000)
EOF
```

Expected output:

```
A) required throughput: 50.0 req/s
B) wall time on 8 GPUs: 625 s = 10.4 min
C) requests in flight at budget: 500.0
```

**Questions — Exercise 3**

3.1. For each of A, B and C, state whether you optimize primarily for latency or for throughput, and give one serving technique that fits.
3.2. Use case B takes 10.4 minutes on 8 GPUs. How long does it take on 1 GPU? Why is this use case a good candidate for a shared, scheduled cluster rather than dedicated GPUs?
3.3. In use case C, why would dynamic batching (for example in Triton Inference Server) help throughput yet need a carefully bounded queue delay?

---

## Exercise 4 — Confirm the GPU platform that serves these use cases (Kubernetes + GPU Operator)

Every use case above runs on GPUs that someone must expose to workloads. The GPU Operator automates the driver, the NVIDIA Container Toolkit, the device plugin, GPU Feature Discovery (GFD) and DCGM monitoring. Thanks to GFD you can choose the *right* GPU for a use case through node labels.

**Step 1.** Inspect the operator and the GPU labels.

```bash
kubectl get pods -n gpu-operator
kubectl get nodes -L nvidia.com/gpu.product,nvidia.com/gpu.memory,nvidia.com/gpu.count
```

Expected output (illustrative; values depend on your hardware):

```
NAME          STATUS   ROLES    AGE   VERSION   GPU.PRODUCT              GPU.MEMORY   GPU.COUNT
gpu-node-01   Ready    <none>   12d   v1.31.2   NVIDIA-H100-80GB-HBM3   81559        8
cpu-node-01   Ready    <none>   12d   v1.31.2
```

**Step 2.** Run a GPU smoke test pinned to the GPU model you sized in Exercise 2.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-smoke
  labels:
    use-case: llm-inference-sizing
spec:
  restartPolicy: Never
  nodeSelector:
    nvidia.com/gpu.product: NVIDIA-H100-80GB-HBM3
  containers:
    - name: cuda
      image: nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04
      command: ["nvidia-smi", "--query-gpu=name,memory.total,memory.used", "--format=csv"]
      resources:
        limits:
          nvidia.com/gpu: 1
```

Replace the `nodeSelector` value with the product label from Step 1 before applying.

```bash
kubectl apply -f gpu-smoke.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/gpu-smoke --timeout=120s
kubectl logs gpu-smoke
```

Expected output (illustrative):

```
name, memory.total [MiB], memory.used [MiB]
NVIDIA H100 80GB HBM3, 81559 MiB, 0 MiB
```

**Questions — Exercise 4**

4.1. Which GPU Operator component creates the `nvidia.com/gpu.product` label, and which one makes `nvidia.com/gpu: 1` schedulable?
4.2. In Exercise 2 the 70B / FP8 model needed more than 80 GB. Without changing the model, what would you change in this Pod spec, and what serving feature must the inference engine then use?
4.3. A retail customer runs a small recommendation model that uses 6 GB of GPU memory, alongside other small models. Which GPU feature exposed through the operator avoids dedicating a whole H100 to it?

---

## Exercise 5 — Optimize a manufacturing visual-inspection model with TensorRT

Visual defect inspection (manufacturing) and video analytics (smart cities) are perception use cases with real-time budgets. TensorRT compiles a trained model into an optimized engine (layer fusion, kernel auto-tuning, reduced precision). `trtexec` is the benchmarking CLI that ships in the TensorRT container. A ResNet-50 classifier stands in for the inspection model here.

**Step 1.** Create a Job that downloads an ONNX ResNet-50 and benchmarks it at batch 1 (latency profile) and batch 32 (throughput profile).

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: trt-defect-inspection
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: trtexec
          image: nvcr.io/nvidia/tensorrt:24.08-py3
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -euo pipefail
              python3 -c "import urllib.request; urllib.request.urlretrieve('https://github.com/onnx/models/raw/main/validated/vision/classification/resnet/model/resnet50-v1-12.onnx', '/tmp/resnet50.onnx')"
              ls -lh /tmp/resnet50.onnx
              echo "=== batch 1, FP16 ==="
              trtexec --onnx=/tmp/resnet50.onnx --fp16 --shapes=data:1x3x224x224 2>&1 | grep -E "Throughput|Latency: min"
              echo "=== batch 32, FP16 ==="
              trtexec --onnx=/tmp/resnet50.onnx --fp16 --shapes=data:32x3x224x224 2>&1 | grep -E "Throughput|Latency: min"
          resources:
            limits:
              nvidia.com/gpu: 1
```

```bash
kubectl apply -f trt-job.yaml
kubectl logs -f job/trt-defect-inspection
```

If the download is only a few hundred bytes, you received a Git LFS pointer instead of the model. Download the file from the onnx/models repository page and copy it in. If `trtexec` reports that the input `data` is static, remove the `--shapes` flags.

Expected output shape (the numbers are **illustrative** and vary widely by GPU):

```
-rw-r--r-- 1 root root 98M ... /tmp/resnet50.onnx
=== batch 1, FP16 ===
[I] Throughput: 2450.13 qps
[I] Latency: min = 0.39 ms, max = 0.61 ms, mean = 0.41 ms, median = 0.40 ms, percentile(90%) = 0.42 ms, percentile(95%) = 0.43 ms, percentile(99%) = 0.47 ms
=== batch 32, FP16 ===
[I] Throughput: 410.55 qps
[I] Latency: min = 2.38 ms, max = 2.71 ms, mean = 2.43 ms, median = 2.42 ms, percentile(90%) = 2.46 ms, percentile(95%) = 2.48 ms, percentile(99%) = 2.55 ms
```

**Step 2.** Record your own numbers and compute `images/s = qps × batch` for each run.

**Questions — Exercise 5**

5.1. In `trtexec`, a "query" is one batch. Using the illustrative numbers, how many images per second does each run process? Which configuration would you pick for a line camera that must reject a defective part within 5 ms of capture, and which for re-scanning a month of archived images?
5.2. Why do inspection and video-analytics systems usually run this engine at the **edge** (on Jetson or an industrial PC near the line) rather than in a central data center?
5.3. Building the engine took noticeable time before benchmarking started. What does that imply for production rollout? Should the engine be built at Pod start-up, or ahead of time?

---

## Exercise 6 — Storage profiles: training vs inference use cases

The NVIDIA storage blog stresses that training and inference stress storage differently. Training reads large datasets repeatedly (across epochs) and writes large checkpoints periodically. Inference mostly needs to load models quickly and, for RAG, to serve low-latency lookups from a vector store.

**Step 1.** Estimate the checkpoint cost of fine-tuning a 70B model with mixed precision and Adam. Assume ~14 bytes per parameter are saved: FP16 weights (2), FP32 master weights (4), and two FP32 Adam moments (4 + 4).

```bash
python3 - <<'EOF'
params = 70e9
ckpt_bytes = params * 14
print(f"checkpoint size: {ckpt_bytes/1e9:.0f} GB")
for gbps in (1, 10, 50):
    t = ckpt_bytes / (gbps * 1e9)
    print(f"write at {gbps:>2} GB/s: {t:7.1f} s  -> {100*t/3600:5.1f}% of each hour if synchronous & hourly")
EOF
```

Expected output:

```
checkpoint size: 980 GB
write at  1 GB/s:   980.0 s  -> 27.2% of each hour if synchronous & hourly
write at 10 GB/s:    98.0 s  ->   2.7% of each hour if synchronous & hourly
write at 50 GB/s:    19.6 s  ->   0.5% of each hour if synchronous & hourly
```

**Step 2.** Do the inference-side comparison yourself. An autoscaled chatbot cold-starts a replica that must load 70 GB of FP8 weights. Compute the load time from (a) object storage at 1 GB/s and (b) a local NVMe cache at 7 GB/s.

**Questions — Exercise 6**

6.1. What are the load times for Step 2 (a) and (b)? Which user-facing metric suffers in case (a)?
6.2. A healthcare imaging team trains on 400 TB of DICOM studies for 100 epochs. Is their dominant storage pattern sequential/large reads, small random reads, or large writes? What does NVIDIA recommend for keeping GPUs fed in that case?
6.3. Name two techniques that reduce the 27.2% checkpoint overhead without buying faster storage.

---

## Exercise 7 — Map industries to NVIDIA platforms

The exam expects you to recognize NVIDIA's domain-specific platforms and the industry each one serves.

**Step 1.** Match each platform (left) to the best-fitting use case (right). Write your answers as pairs, for example `1-c`.

| # | Platform | | Letter | Use case |
|---|---|---|---|---|
| 1 | Clara / MONAI | | a | Cybersecurity pipeline that inspects network traffic for threats |
| 2 | BioNeMo | | b | Large-scale recommender systems for e-commerce |
| 3 | DRIVE | | c | Medical imaging AI and medical devices |
| 4 | Isaac | | d | Speech AI: ASR, TTS, translation |
| 5 | Metropolis | | e | Building, customizing and serving LLMs |
| 6 | Omniverse | | f | Generative AI for drug discovery and biology |
| 7 | Morpheus | | g | Autonomous vehicle development, from data center to car |
| 8 | Merlin | | h | Robotics simulation, training and deployment |
| 9 | Riva | | i | Vision AI for cities, retail and factories |
| 10 | NeMo | | j | 3D simulation and industrial digital twins |
| 11 | cuOpt | | k | GPU-accelerated data science (pandas/scikit-learn-like APIs) |
| 12 | RAPIDS | | l | Route and logistics optimization |

**Step 2.** Check your answers against your `use_cases.yaml` from Exercise 1. Each platform should appear in the `nvidia_stack` of at least one entry, except BioNeMo, which appears only once.

**Questions — Exercise 7**

7.1. Give your 12 pairs.
7.2. A bank wants a chatbot that answers questions about its own policy documents without retraining a model. What is this pattern called, and which two NVIDIA components from the table and catalog would it use?
7.3. Why does NVIDIA offer *domain-specific* platforms instead of only generic CUDA libraries? Answer from the perspective of an infrastructure team.

---

## Answers

<details>
<summary>Click to expand the answers</summary>

### Exercise 1

Full expected output:

```
== real-time (6) ==
  - Financial services: Real-time fraud detection on card transactions
  - Automotive: Autonomous driving perception (camera, radar, lidar)
  - Manufacturing: Visual defect inspection on the production line
  - Cybersecurity: Anomaly detection on network telemetry
  - Media and entertainment: Speech recognition and subtitle translation
  - Public sector / smart cities: Traffic video analytics
== interactive (4) ==
  - Healthcare: Medical imaging segmentation (CT/MRI)
  - Retail: Product recommendation engine
  - Telecommunications: Customer-service chatbot with RAG over internal docs
  - Logistics: Route optimization for delivery fleets
== batch (3) ==
  - Life sciences: Drug discovery, protein structure and molecule generation
  - Manufacturing: Factory digital twin and robot simulation
  - Climate and energy: Weather and climate forecasting

ai_type counts:
  generative   3
  optimization 1
  perception   4
  predictive   3
  simulation   2
```

**1.1.** Real-time budgets apply to the moment a decision is made: approving a transaction, braking, rejecting a part. That moment is always inference. Training happens offline, beforehand. To meet millisecond budgets you put an optimized runtime in between: a TensorRT-compiled engine, served by an inference server such as Triton, with bounded dynamic batching and the model resident in GPU memory.

**1.2.** Training runs in the data center on large GPU clusters, using fleet-collected sensor data and simulation (Omniverse / DRIVE Sim). Inference runs in the vehicle on an embedded DRIVE computer. A round trip to a remote data center adds network latency and jitter, and depends on connectivity. A safety-critical perception loop cannot tolerate either.

**1.3.** PyYAML raises a `ScannerError` ("mapping values are not allowed here"), because an unquoted `: ` inside a value is read as a new mapping. If this catalog drives automation (CI checks, capacity planning, Helm values), one unquoted colon stops the whole pipeline. Quoting such values is mandatory.

**1.4.** The LLM-based entry is the telecom RAG chatbot (NeMo/NIM). Speech recognition and translation (Riva) is generative AI built on speech models; translation can be LLM-assisted, but Riva's ASR models are not LLMs. Drug discovery (BioNeMo) is generative but uses biology/chemistry foundation models (protein and molecule models), not text LLMs.

### Exercise 2

**2.1.**

| Use case | Model / precision | Weights | KV cache | Total | Fits on 1 × 80 GB? |
|---|---|---|---|---|---|
| HR chatbot | 8B / FP16 | 16.0 GB | 17.2 GB | ~33 GB | Yes, with room to spare. It would also fit on a 48 GB GPU such as the L40S. |
| Legal summarization | 70B / FP8 | 70.0 GB | 42.9 GB | ~113 GB | **No** |
| Code assistant | 70B / INT4 | 35.0 GB | 42.9 GB | ~78 GB | Technically, but with no headroom left (needs ~72 GB usable). Reduce concurrency or context. |

With `CONCURRENT_SEQS = 4` (Step 3) the KV cache drops to 4.3 GB (8B) and 10.7 GB (70B). The 70B / FP8 case becomes ~81 GB, still slightly over. The 70B / INT4 case becomes ~46 GB and fits comfortably.

**2.2.**
- **Tensor parallelism across 2 GPUs** (TP=2). Each GPU holds half the weights and half of the KV heads. Cost: a second GPU, plus a need for a fast interconnect (NVLink).
- **Lower concurrency or shorter max context.** Cost: less throughput per GPU, or truncated long documents. This hurts a summarization use case.
- **Quantize the KV cache to FP8.** This halves it to ~21.5 GB, for a total of ~92 GB, so it still needs further reduction. Cost: a possible small accuracy loss.

Moving the weights to INT4 also helps, at a quality cost that must be validated for legal text.

**2.3.** KV cache size depends on `layers × kv_heads × head_dim`, not on total parameters. Both models use GQA with 8 KV heads of dimension 128, so the only difference is layer count: 80 / 32 = 2.5×. Most of the extra parameters live in wider MLP and attention projection matrices, and these do not add per-token cache.

**2.4.** Weight quantization shrinks the **weights** component. The KV cache is unchanged unless you separately enable KV-cache quantization. This is why long-context, high-concurrency use cases can still run out of memory after weight quantization.

### Exercise 3

**3.1.**
- **A (chatbot):** primarily latency (time to first token and time per output token), at a throughput of 50 req/s. Technique: in-flight (continuous) batching with streaming responses, as in TensorRT-LLM / NIM.
- **B (virtual screening):** throughput. Nobody waits on a single molecule. Technique: large batch sizes and many GPUs running as a scheduled batch job.
- **C (fraud):** strict tail latency (p99 ≤ 10 ms) at very high request rates. Technique: small-batch, low-latency engines (TensorRT) and dynamic batching with a tight maximum queue delay, plus enough replicas to absorb the 500 in-flight requests.

**3.2.** 10,000,000 / 2,000 = 5,000 s ≈ 83 minutes on 1 GPU. The job is elastic and deadline-tolerant. A shared cluster with a batch scheduler can fill idle GPU capacity with it and preempt it for interactive work. Dedicated GPUs would sit idle between screening campaigns.

**3.3.** Batching amortizes kernel launches and weight reads across requests, which raises GPU utilization and transactions/s. Each request may wait in the queue for the batch to form, though, and that wait adds straight to latency. The maximum queue delay must stay well below the 10 ms p99 budget.

### Exercise 4

**4.1.** **GPU Feature Discovery** (with Node Feature Discovery) creates the `nvidia.com/gpu.*` labels. The **NVIDIA device plugin** advertises the `nvidia.com/gpu` extended resource to the kubelet so that the scheduler can allocate it. The operator also installs the driver and the Container Toolkit, which make the GPU usable inside the container.

**4.2.** Request `nvidia.com/gpu: 2` (or more) on a node whose GPUs are NVLink-connected. The engine must then run **tensor parallelism** (or pipeline parallelism), so that the model is sharded across the GPUs of the Pod.

**4.3.** **Multi-Instance GPU (MIG)**, configured through the operator's MIG manager. It splits an H100 into hardware-isolated instances (for example `1g.10gb`). Each instance has its own memory and compute slice, so several small models can share one GPU with performance isolation. Time-slicing is the alternative, but it gives no memory or fault isolation.

### Exercise 5

**5.1.** With the illustrative numbers:
- Batch 1: 2,450 qps × 1 = **~2,450 images/s**, at ~0.4 ms latency.
- Batch 32: 410.55 qps × 32 = **~13,138 images/s**, at ~2.4 ms per batch.

The line camera needs a 5 ms end-to-end decision that includes capture, preprocessing and actuation, and it sees one part at a time. Use **batch 1** (or a small batch matching the number of cameras). The archive rescan is pure throughput, so use **batch 32** or larger.

Your real numbers will differ. The pattern holds: larger batches raise total throughput and raise per-request latency.

**5.2.** Latency and determinism: there is no WAN round trip in the reject loop. Bandwidth: streaming raw high-resolution video from many cameras to a data center is expensive. Resilience: the line keeps running if the uplink fails. Data residency and privacy also matter, especially for smart-city video. The data center still trains and retrains the models.

**5.3.** Engine building runs auto-tuning and can take seconds to minutes. Building at Pod start inflates cold-start time and adds CPU/GPU load at scale-out. Build the engine ahead of time in CI, for each target GPU architecture and TensorRT version, store it as an artifact, and have serving Pods only load it. Engines are specific to GPU architecture and TensorRT version, so the build matrix has to match the fleet.

### Exercise 6

**6.1.** (a) 70 GB / 1 GB/s = **70 s**. (b) 70 / 7 = **10 s**. In case (a), scale-out reacts slowly. During a traffic spike, new replicas take more than a minute to become Ready. Queues grow, and **time to first token / p99 latency** degrades for users. Pre-pulling or caching weights on local NVMe, or keeping warm replicas, mitigates this.

**6.2.** Training on 400 TB for 100 epochs is a **read-heavy** pattern: the dataset is read in full on every epoch. For images, the reads are often many medium-sized files accessed in shuffled (random) order. The blog's guidance: use a parallel/high-throughput storage tier sized for aggregate read bandwidth across all GPU nodes, cache hot data close to the GPUs (local NVMe), and use efficient data loaders. GPUDirect Storage avoids CPU bounce buffers on the data path. The goal is for GPUs never to wait on I/O.

**6.3.** Any two of:
- **Asynchronous checkpointing:** snapshot to host memory or local NVMe, then flush to shared storage in the background while training continues.
- **Sharded/distributed checkpoints:** every rank writes its shard in parallel, which uses aggregate bandwidth.
- **Checkpointing less often**, chosen against the measured failure rate.
- **Saving only weights** for intermediate milestones, when exact resumption is not required.

### Exercise 7

**7.1.** `1-c, 2-f, 3-g, 4-h, 5-i, 6-j, 7-a, 8-b, 9-d, 10-e, 11-l, 12-k`

**7.2.** **Retrieval-Augmented Generation (RAG).** Documents are embedded and indexed. At query time, relevant passages are retrieved and added to the prompt, so the LLM answers from current private data without retraining. Components: **NeMo** (with its retriever/guardrail tooling) and **NIM** microservices for the LLM and embedding models, served on **Triton** / TensorRT-LLM.

**7.3.** Domain platforms package pretrained models, optimized pipelines and reference architectures for a vertical: imaging formats in Clara, sensor fusion in DRIVE, video decode in Metropolis/DeepStream. For an infrastructure team this means fewer bespoke stacks to build and validate, known-good container images (from NGC) with predictable resource profiles, and faster time to production. The trade-off is closer coupling to the NVIDIA software ecosystem. All of these platforms still run on the same foundation: GPUs exposed through the driver, the Container Toolkit and the GPU Operator.

</details>