# 1.3 Differentiate the Concepts of AI, Machine Learning, and Deep Learning

> **Exam weight:** 4.75%. NCA-AIIO tests whether you can place a workload correctly within the AI → ML → DL hierarchy and derive the infrastructure consequences from that placement: compute type, memory, storage, networking, and the software stack.

---

## 1. Motivation: Why an Infrastructure Operator Must Get This Right

Product teams use "AI" for everything: a fraud-detection rule engine, a gradient-boosted churn model, a 70B-parameter LLM chatbot. To a platform team these are three very different workloads. Each has its own resource profile, failure modes, and cost curve.

| Workload as described by product | What it actually is | What it needs from the platform |
|---|---|---|
| "AI-powered fraud alerts" | Rule-based / symbolic AI (if/then thresholds, decision tables) | A few CPU cores, low-latency KV store, no GPU |
| "ML churn prediction" | Classical ML (XGBoost, random forest, logistic regression on tabular data) | CPU nodes, or **optionally** a GPU via RAPIDS/XGBoost for large datasets |
| "Our AI assistant" | Deep learning (transformer LLM), generative AI | Multi-GPU nodes, high-bandwidth GPU memory, NVLink/InfiniBand, high-throughput storage, optimized inference runtime (TensorRT, Triton, NIM) |

Common production mistakes that come from confusing these categories:

- **Over-provisioning:** scheduling a scikit-learn logistic regression on an 8×H100 node. The GPUs sit idle at 0% utilization while blocking real DL jobs.
- **Under-provisioning:** treating LLM inference like "an ML model behind an API" and deploying it on CPU nodes. Latency goes from milliseconds to tens of seconds, or the model does not fit in memory at all.
- **Wrong storage design:** sizing storage for a 2 GB tabular CSV when the DL team will stream 40 TB of images per epoch and write 500 GB checkpoints every hour.
- **Wrong network design:** buying commodity 10 GbE for a cluster that will run multi-node data-parallel training, where gradient all-reduce traffic saturates the fabric.

The conceptual hierarchy below is the foundation for every sizing decision in the rest of the NCA-AIIO syllabus.

---

## 2. The Hierarchy: AI ⊃ ML ⊃ DL ⊃ Generative AI / LLMs

```
┌──────────────────────────────────────────────────────────────────────┐
│ ARTIFICIAL INTELLIGENCE                                              │
│ Any technique that lets machines mimic human cognitive behavior:     │
│ rule-based expert systems, search/planning, logic, knowledge graphs  │
│                                                                      │
│   ┌──────────────────────────────────────────────────────────────┐   │
│   │ MACHINE LEARNING                                             │   │
│   │ Systems that LEARN a function from data instead of being     │   │
│   │ explicitly programmed: linear/logistic regression, SVM,      │   │
│   │ decision trees, random forests, gradient boosting, k-means   │   │
│   │                                                              │   │
│   │   ┌──────────────────────────────────────────────────────┐   │   │
│   │   │ DEEP LEARNING                                        │   │   │
│   │   │ ML using multi-layer (deep) artificial neural        │   │   │
│   │   │ networks that learn their own feature representations│   │   │
│   │   │ CNNs, RNNs/LSTMs, Transformers                       │   │   │
│   │   │                                                      │   │   │
│   │   │   ┌──────────────────────────────────────────────┐   │   │   │
│   │   │   │ GENERATIVE AI / LLMs                         │   │   │   │
│   │   │   │ Deep models that generate new content        │   │   │   │
│   │   │   │ (text, images, code, audio): GPT-style LLMs, │   │   │   │
│   │   │   │ diffusion models                             │   │   │   │
│   │   │   └──────────────────────────────────────────────┘   │   │   │
│   │   └──────────────────────────────────────────────────────┘   │   │
│   └──────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
```

**Key rule for the exam:** every DL system is an ML system, and every ML system is an AI system. The reverse is not true. A chess engine using hand-written alpha-beta search is AI but not ML. A random forest is ML but not DL.

### 2.1 Artificial Intelligence (the umbrella)

AI is the broad field of building systems that perform tasks that normally require human intelligence: perception, reasoning, planning, language understanding, decision-making.

Historically, much AI was **symbolic** (Good Old-Fashioned AI). Humans encode knowledge explicitly as rules (`IF temperature > 90 AND pressure_drop THEN alert`), ontologies, or search heuristics. Properties:

- **Deterministic and explainable:** you can point to the rule that fired.
- **No training phase:** behavior is authored, not learned.
- **Brittle:** fails on inputs the rule authors did not anticipate, and scales poorly as the rule count grows.
- **Infrastructure:** ordinary CPU services. No accelerator is needed.

### 2.2 Machine Learning

ML is the subset of AI where the system **learns patterns from data**. In Arthur Samuel's classic framing, it gives computers "the ability to learn without being explicitly programmed." Instead of writing the decision function, you supply examples and an optimization algorithm fits model parameters that minimize a loss.

Learning paradigms:

| Paradigm | Training signal | Typical algorithms | Example |
|---|---|---|---|
| Supervised | Labeled pairs (x, y) | Linear/logistic regression, SVM, random forest, XGBoost | Predict churn from customer features |
| Unsupervised | Unlabeled x only | k-means, DBSCAN, PCA | Customer segmentation, anomaly detection |
| Semi/self-supervised | Labels derived from the data itself | Masked-token prediction | Pretraining language models (also DL) |
| Reinforcement | Reward from an environment | Q-learning, policy gradients | Robotics, resource scheduling |

The defining trait of **classical** (non-deep) ML is **manual feature engineering**. A data scientist decides which inputs matter, such as "days since last login" or "average basket value", and builds them by hand. The model learns weights over those human-designed features.

Infrastructure profile:

- Usually **tabular/structured data**, from megabytes to hundreds of gigabytes.
- Models are small: kilobytes to a few hundred megabytes.
- Training runs on CPUs in minutes to hours. GPUs **can** accelerate it significantly via NVIDIA RAPIDS (cuDF, cuML) or XGBoost with `device="cuda"`, especially for large datasets and hyperparameter sweeps. The GPU is an optimization here, not a requirement.
- Models are often more interpretable (feature importances, SHAP values, tree paths).

### 2.3 Deep Learning

DL is the subset of ML that uses **artificial neural networks with many layers**. Each layer applies a linear transformation (a matrix multiply), followed by a non-linear activation. Stacking layers lets the network learn **hierarchical representations directly from raw data**:

```
Raw pixels ──► edges ──► textures/corners ──► object parts ──► "cat"
 (input)     (layer 1)      (layers 2-3)       (layers 4-n)    (output)
```

This is the key differentiator from classical ML. **DL learns the features itself (representation learning)** instead of relying on hand-crafted features. It therefore excels on **unstructured data**: images, audio, video, free text.

The trade-offs:

- **Data-hungry:** performance keeps improving with more data, where classical ML tends to plateau.
- **Compute-hungry:** training means billions to trillions of floating-point multiply-accumulates per sample, repeated for millions of samples over many epochs.
- **Less interpretable:** millions or billions of parameters with no human-readable meaning.
- **Memory-hungry:** weights, gradients, optimizer state, and activations must all fit in accelerator memory.

### 2.4 Generative AI and Large Language Models

Generative AI is a class of DL models that produce new content rather than only classifying or predicting. LLMs are transformer-based deep networks trained with self-supervision on massive text corpora. They are then adapted through fine-tuning, alignment, or retrieval-augmented generation (RAG). NVIDIA describes their uses as including text generation, summarization, translation, code generation, chatbots, and content creation across industries.

For infrastructure, LLMs sit at the extreme end of the DL spectrum:

- Parameter counts from billions to hundreds of billions.
- Training demands thousands of GPUs, high-speed interconnect, and parallel file systems.
- Inference demands large GPU memory, KV-cache management, batching, and an optimized runtime (TensorRT-LLM, Triton, NIM).

---

## 3. Why Deep Learning Maps to GPUs: The Internal Mechanics

### 3.1 The workload is dense linear algebra

A fully connected layer computes:

```
Y = activation(X · W + b)

X: [batch, in_features]     e.g. [256, 4096]
W: [in_features, out_feat]  e.g. [4096, 4096]
FLOPs ≈ 2 × 256 × 4096 × 4096 ≈ 8.6 GFLOP for ONE layer, ONE forward pass
```

Convolutions and transformer attention also reduce to General Matrix Multiplications (**GEMM**). GEMM is massively parallel: every output element is an independent dot product. That is exactly the shape of work a GPU handles well:

| Property | CPU | GPU (data center class) |
|---|---|---|
| Core design | Tens of complex, latency-optimized cores | Thousands of simple, throughput-optimized cores |
| Specialized units | AVX-512 / AMX vector units | **Tensor Cores** (dedicated matrix-multiply-accumulate) |
| Memory bandwidth | ~100-500 GB/s (DDR5) | ~2-8 TB/s (HBM2e/HBM3/HBM3e) |
| Best for | Branchy logic, serial code, small models, rules | Dense parallel math, DL training and inference |

### 3.2 Training vs inference

Both phases exist for ML and DL, but their infrastructure profiles diverge sharply in DL:

| Dimension | Training | Inference |
|---|---|---|
| Goal | Learn parameters (forward pass, backward pass, optimizer step) | Apply fixed parameters to new inputs (forward pass only) |
| Compute | Very high, sustained for hours to months | Lower per request, but continuous and scaled by traffic |
| Memory per parameter | Weights + gradients + optimizer state (e.g. Adam: ~16 bytes/param in mixed precision) | Weights only (2 bytes FP16/BF16, 1 byte FP8/INT8) + KV cache for LLMs |
| Precision | FP32/TF32, BF16/FP16 mixed precision, FP8 on recent GPUs | FP16, FP8, INT8, INT4 via quantization (TensorRT) |
| Key metric | Time-to-train, throughput (samples/s), GPU utilization | Latency (p50/p99), throughput (requests/s, tokens/s), cost per inference |
| Scaling pattern | Scale-up (NVLink) + scale-out (InfiniBand/RoCE) for all-reduce | Horizontal replicas, dynamic batching, autoscaling |
| Storage pattern | High-throughput repeated reads of the dataset, large bursty checkpoint writes | Fast model loading at startup, little ongoing I/O |
| NVIDIA stack | PyTorch/NGC containers, NCCL, NeMo, DALI, Magnum IO GPUDirect Storage | TensorRT, TensorRT-LLM, Triton Inference Server, NIM |

### 3.3 Worked sizing example (memory)

Exam-style reasoning for a 7B-parameter model:

```
Inference, BF16 weights:   7e9 × 2 bytes  ≈ 14 GB   (+ KV cache, activations)
Inference, FP8/INT8:       7e9 × 1 byte   ≈  7 GB
Inference, INT4:           7e9 × 0.5 byte ≈ 3.5 GB

Training (mixed precision, Adam):
  BF16 weights            2 bytes
  BF16 gradients          2 bytes
  FP32 master weights     4 bytes
  FP32 Adam m and v       8 bytes
  ─────────────────────────────────
  ≈ 16 bytes/param × 7e9  ≈ 112 GB  (+ activations)
```

So a single 80 GB GPU can **serve** a 7B model comfortably. **Training** it requires sharding (ZeRO/FSDP, tensor parallelism) across several GPUs. A classical XGBoost model on the same platform might be 50 MB. That is a difference of more than three orders of magnitude (112 GB / 50 MB ≈ 2,240×), and it is why the hierarchy matters to operators.

---

## 4. Comparative Trade-off Tables

### 4.1 Rule-based AI vs classical ML vs deep learning

| Criterion | Rule-based AI | Classical ML | Deep Learning |
|---|---|---|---|
| How behavior is produced | Hand-authored rules/logic | Learned from data over **engineered features** | Learned from data, **features learned automatically** |
| Data required | None (expert knowledge) | Hundreds to millions of rows | Millions to billions of samples |
| Data type sweet spot | Well-defined business logic | Structured/tabular | Unstructured: images, audio, text, video |
| Feature engineering | N/A | Manual, domain-expert driven | Minimal; the network learns representations |
| Training compute | None | Low-moderate (CPU fine; GPU optional via RAPIDS) | Very high (GPUs effectively mandatory at scale) |
| Inference compute | Trivial | Low (CPU usually fine) | Moderate-high (GPU strongly preferred for latency/throughput) |
| Model size | Rule tables | KB-MB | MB-TB |
| Interpretability | High | Medium-high | Low (needs explainability tooling) |
| Accuracy on perception/language | Poor | Limited | State of the art |
| Failure mode | Unanticipated inputs | Poor features, data drift | Data drift, hallucination (GenAI), adversarial inputs |
| Examples | Expert systems, thresholds, chess search | Credit scoring, churn, demand forecasting | Image classification, speech recognition, LLMs, recommender embeddings |
| NVIDIA acceleration | None | RAPIDS cuDF/cuML, XGBoost GPU | CUDA, cuDNN, NCCL, TensorRT, Triton, NeMo, NIM |

### 4.2 Choosing an approach: decision flow

```
Is the logic fully known and stable, and must it be 100% auditable?
 ├─ Yes ──► Rule-based AI (CPU service)
 └─ No
     Is the data mostly structured/tabular, with moderate volume?
      ├─ Yes ──► Classical ML (CPU; add RAPIDS GPU if datasets/sweeps are large)
      └─ No (images, audio, text, video; or very large data; or SOTA accuracy needed)
          ──► Deep Learning (GPU training + optimized GPU inference)
              Need to generate content or work with natural language?
               └─ Yes ──► Generative AI / LLM (pretrained foundation model,
                          fine-tune or RAG, serve with TensorRT-LLM/Triton/NIM)
```

### 4.3 Infrastructure consequences by category

| Layer | Classical ML | Deep Learning (training) | Deep Learning (inference) |
|---|---|---|---|
| Compute | CPU nodes; optional single GPU | Multi-GPU nodes (e.g. 8 GPUs + NVLink/NVSwitch) | 1-N GPUs per replica, possibly MIG slices |
| Network | Standard Ethernet | InfiniBand or RoCE, GPUDirect RDMA for all-reduce | Standard front-end Ethernet; east-west only for multi-GPU sharded models |
| Storage | Data lake / object store, modest throughput | Parallel FS or high-perf NFS/object with caching; GPUDirect Storage; checkpoint bandwidth | Fast model repository; local NVMe cache to cut cold-start |
| Scheduler | Standard Kubernetes | Gang scheduling, topology awareness | HPA/KEDA autoscaling on queue depth or GPU utilization |
| Observability | CPU/mem, model metrics | DCGM metrics (SM utilization, memory, NVLink, XID errors) | Latency percentiles, Triton metrics, DCGM |

---

## 5. Production Manifests: The Same Cluster, Three Workload Classes

These manifests model a realistic Kubernetes platform. GPU nodes are managed by the **NVIDIA GPU Operator**, which installs the driver, container toolkit, device plugin, GPU Feature Discovery, and the DCGM exporter. GPU Feature Discovery labels GPU nodes with `nvidia.com/gpu.present=true`, and the device plugin advertises the `nvidia.com/gpu` extended resource.

### 5.1 Install the GPU Operator (prerequisite for DL workloads)

```bash
$ helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
"nvidia" has been added to your repositories
Hang tight while we grab the latest from your chart repositories...
...Successfully got an update from the "nvidia" chart repository
Update Complete. ⎈Happy Helming!⎈

$ helm install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator --create-namespace --wait
NAME: gpu-operator
LAST DEPLOYED: Wed Nov 11 10:14:22 2026
NAMESPACE: gpu-operator
STATUS: deployed
REVISION: 1
TEST SUITE: None

$ kubectl get pods -n gpu-operator
NAME                                                          READY   STATUS      RESTARTS   AGE
gpu-feature-discovery-7kq2p                                   1/1     Running     0          4m
gpu-operator-6d8b9c7f6d-x2mzl                                 1/1     Running     0          5m
gpu-operator-node-feature-discovery-gc-5b7d6c8f4-qk8lw        1/1     Running     0          5m
gpu-operator-node-feature-discovery-master-7c9d5f6b8-h4t9n    1/1     Running     0          5m
gpu-operator-node-feature-discovery-worker-9fxsd              1/1     Running     0          5m
nvidia-container-toolkit-daemonset-r8wq2                      1/1     Running     0          4m
nvidia-cuda-validator-l6z7m                                   0/1     Completed   0          3m
nvidia-dcgm-exporter-s5h2d                                    1/1     Running     0          4m
nvidia-device-plugin-daemonset-tz4kc                          1/1     Running     0          4m
nvidia-driver-daemonset-2b9jx                                 1/1     Running     0          5m
nvidia-operator-validator-wq7vn                               1/1     Running     0          4m
```

### 5.2 Namespace and shared resources

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ai-workloads
  labels:
    team: data-platform
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gpu-quota
  namespace: ai-workloads
spec:
  hard:
    requests.nvidia.com/gpu: "12"   # the 12 GPUs of gpu-pool-h1 (8) and gpu-pool-l1 (4)
    limits.cpu: "128"
    limits.memory: 1Ti
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: training-scripts
  namespace: ai-workloads
data:
  classical_ml.py: |
    import time
    from sklearn.datasets import make_classification
    from sklearn.ensemble import RandomForestClassifier
    from sklearn.model_selection import train_test_split
    from sklearn.metrics import accuracy_score

    # Tabular data with 20 engineered features (classical ML territory)
    X, y = make_classification(n_samples=200_000, n_features=20,
                               n_informative=12, random_state=42)
    X_tr, X_te, y_tr, y_te = train_test_split(X, y, test_size=0.2, random_state=42)

    t0 = time.time()
    clf = RandomForestClassifier(n_estimators=100, max_depth=16, n_jobs=-1)
    clf.fit(X_tr, y_tr)
    print(f"[classical-ml/cpu] fit_seconds={time.time() - t0:.1f}")
    print(f"[classical-ml/cpu] accuracy={accuracy_score(y_te, clf.predict(X_te)):.4f}")
    top = sorted(enumerate(clf.feature_importances_), key=lambda t: -t[1])[:3]
    print(f"[classical-ml/cpu] top_features={top}")

  classical_ml_gpu.py: |
    import time
    import cupy as cp
    from cuml.datasets import make_classification
    from cuml.ensemble import RandomForestClassifier
    from cuml.model_selection import train_test_split
    from cuml.metrics import accuracy_score

    # Same algorithm family, accelerated with RAPIDS cuML on the GPU
    X, y = make_classification(n_samples=200_000, n_features=20,
                               n_informative=12, random_state=42)
    X = X.astype(cp.float32)
    y = y.astype(cp.int32)
    X_tr, X_te, y_tr, y_te = train_test_split(X, y, test_size=0.2, random_state=42)

    t0 = time.time()
    clf = RandomForestClassifier(n_estimators=100, max_depth=16)
    clf.fit(X_tr, y_tr)
    print(f"[classical-ml/gpu] fit_seconds={time.time() - t0:.1f}")
    print(f"[classical-ml/gpu] accuracy={accuracy_score(y_te, clf.predict(X_te)):.4f}")

  deep_learning.py: |
    import os
    import time
    import torch
    import torch.nn as nn
    import torch.distributed as dist
    import torchvision

    # Deep learning: a ResNet-50 learns features directly from raw pixels
    dist.init_process_group(backend="nccl")
    local_rank = int(os.environ["LOCAL_RANK"])
    torch.cuda.set_device(local_rank)
    device = torch.device("cuda", local_rank)

    model = torchvision.models.resnet50(num_classes=1000).to(device)
    model = nn.parallel.DistributedDataParallel(model, device_ids=[local_rank])
    opt = torch.optim.SGD(model.parameters(), lr=0.1, momentum=0.9)
    loss_fn = nn.CrossEntropyLoss()

    batch = 128
    images = torch.randn(batch, 3, 224, 224, device=device)
    labels = torch.randint(0, 1000, (batch,), device=device)

    steps = 100
    for step in range(steps + 10):
        if step == 10:
            torch.cuda.synchronize()
            t0 = time.time()
        with torch.autocast(device_type="cuda", dtype=torch.bfloat16):
            loss = loss_fn(model(images), labels)
        opt.zero_grad(set_to_none=True)
        loss.backward()
        opt.step()
    torch.cuda.synchronize()
    elapsed = time.time() - t0
    world = dist.get_world_size()
    if dist.get_rank() == 0:
        ips = steps * batch * world / elapsed
        mem = torch.cuda.max_memory_allocated() / 2**30
        print(f"[deep-learning] world_size={world} images_per_sec={ips:.0f} "
              f"peak_mem_gib={mem:.1f} final_loss={loss.item():.3f}")
    dist.destroy_process_group()
```

### 5.3 Classical ML on CPU nodes (explicitly kept off GPU nodes)

The node affinity uses `DoesNotExist`, so this cheap workload never lands on, or blocks, expensive GPU capacity.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: churn-rf-cpu
  namespace: ai-workloads
  labels:
    workload-class: classical-ml
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        workload-class: classical-ml
    spec:
      restartPolicy: Never
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: nvidia.com/gpu.present
                    operator: DoesNotExist
      containers:
        - name: trainer
          image: python:3.12-slim
          command: ["sh", "-c"]
          args:
            - pip install --no-cache-dir --quiet scikit-learn==1.5.2 && python /scripts/classical_ml.py
          resources:
            requests:
              cpu: "8"
              memory: 8Gi
            limits:
              cpu: "8"
              memory: 8Gi
          volumeMounts:
            - name: scripts
              mountPath: /scripts
              readOnly: true
      volumes:
        - name: scripts
          configMap:
            name: training-scripts
```

### 5.4 Classical ML accelerated on one GPU (RAPIDS cuML)

This demonstrates an exam nuance: **GPUs are not exclusive to DL**. RAPIDS accelerates classical ML and data processing, but one GPU is usually enough.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: churn-rf-gpu
  namespace: ai-workloads
  labels:
    workload-class: classical-ml-accelerated
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        workload-class: classical-ml-accelerated
    spec:
      restartPolicy: Never
      nodeSelector:
        nvidia.com/gpu.present: "true"
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      containers:
        - name: trainer
          image: rapidsai/base:24.10-cuda12.5-py3.12
          command: ["python", "/scripts/classical_ml_gpu.py"]
          resources:
            requests:
              cpu: "4"
              memory: 16Gi
              nvidia.com/gpu: 1
            limits:
              cpu: "4"
              memory: 16Gi
              nvidia.com/gpu: 1
          volumeMounts:
            - name: scripts
              mountPath: /scripts
              readOnly: true
      volumes:
        - name: scripts
          configMap:
            name: training-scripts
```

### 5.5 Deep learning training on a multi-GPU node

Production details that only matter for DL:

- Multiple GPUs per pod.
- NCCL for gradient all-reduce.
- An enlarged `/dev/shm`, because PyTorch DataLoader workers and NCCL use shared memory, and the default 64 MiB causes `Bus error` crashes.
- A pinned NGC container, so the CUDA, cuDNN, and NCCL versions are validated together.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: resnet50-ddp
  namespace: ai-workloads
  labels:
    workload-class: deep-learning-training
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 7200
  template:
    metadata:
      labels:
        workload-class: deep-learning-training
    spec:
      restartPolicy: Never
      nodeSelector:
        nvidia.com/gpu.present: "true"
        nvidia.com/gpu.count: "8"
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      containers:
        - name: trainer
          image: nvcr.io/nvidia/pytorch:24.10-py3
          command: ["torchrun"]
          args:
            - --standalone
            - --nproc_per_node=8
            - /scripts/deep_learning.py
          env:
            - name: NCCL_DEBUG
              value: WARN
            - name: OMP_NUM_THREADS
              value: "8"
          resources:
            requests:
              cpu: "64"
              memory: 512Gi
              nvidia.com/gpu: 8
            limits:
              cpu: "64"
              memory: 512Gi
              nvidia.com/gpu: 8
          volumeMounts:
            - name: scripts
              mountPath: /scripts
              readOnly: true
            - name: dshm
              mountPath: /dev/shm
      volumes:
        - name: scripts
          configMap:
            name: training-scripts
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 64Gi
```

### 5.6 Deep learning inference: TensorRT engine served by Triton

Training produces a framework model (PyTorch). For production inference, it is typically exported to ONNX, compiled into a **TensorRT engine** with layer fusion, kernel auto-tuning, and FP16/FP8/INT8 precision, and then served by **Triton Inference Server**. Triton adds dynamic batching, concurrent model execution, and Prometheus metrics.

Build the engine. It must be built on the same GPU architecture and TensorRT version that will serve it:

```bash
$ docker run --rm --gpus all -v $PWD:/work -w /work nvcr.io/nvidia/tensorrt:24.10-py3 \
    trtexec --onnx=resnet50.onnx --saveEngine=model.plan --fp16 \
            --minShapes=input:1x3x224x224 --optShapes=input:16x3x224x224 \
            --maxShapes=input:64x3x224x224
...
[I] Engine built in 74.312 sec.
[I] === Performance summary ===
[I] Throughput: 4127.6 qps
[I] Latency: min = 0.581 ms, max = 0.902 ms, mean = 0.612 ms, median = 0.609 ms, percentile(99%) = 0.744 ms
...
&&&& PASSED TensorRT.trtexec [TensorRT v100500] # trtexec --onnx=resnet50.onnx ...
```

Triton model configuration (`config.pbtxt`, protobuf text format, **not** YAML), in the model repository layout `models/resnet50/config.pbtxt` and `models/resnet50/1/model.plan`:

```
name: "resnet50"
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

Kubernetes resources for serving:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: model-repository
  namespace: ai-workloads
spec:
  accessModes:
    - ReadOnlyMany
  storageClassName: nfs-fast
  resources:
    requests:
      storage: 200Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: triton-resnet50
  namespace: ai-workloads
  labels:
    app: triton-resnet50
    workload-class: deep-learning-inference
spec:
  replicas: 2
  selector:
    matchLabels:
      app: triton-resnet50
  template:
    metadata:
      labels:
        app: triton-resnet50
        workload-class: deep-learning-inference
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8002"
        prometheus.io/path: /metrics
    spec:
      nodeSelector:
        nvidia.com/gpu.present: "true"
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      containers:
        - name: triton
          image: nvcr.io/nvidia/tritonserver:24.10-py3
          command: ["tritonserver"]
          args:
            - --model-repository=/models
            - --strict-model-config=true
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
            initialDelaySeconds: 15
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /v2/health/live
              port: http
            initialDelaySeconds: 30
            periodSeconds: 10
          startupProbe:
            httpGet:
              path: /v2/health/ready
              port: http
            failureThreshold: 60
            periodSeconds: 5
          resources:
            requests:
              cpu: "4"
              memory: 16Gi
              nvidia.com/gpu: 1
            limits:
              cpu: "4"
              memory: 16Gi
              nvidia.com/gpu: 1
          volumeMounts:
            - name: models
              mountPath: /models
              readOnly: true
            - name: dshm
              mountPath: /dev/shm
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: model-repository
            readOnly: true
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 2Gi
---
apiVersion: v1
kind: Service
metadata:
  name: triton-resnet50
  namespace: ai-workloads
  labels:
    app: triton-resnet50
spec:
  selector:
    app: triton-resnet50
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

---

## 6. CLI Walkthrough: Observing the Difference

### 6.1 Inspect node capabilities

```bash
$ kubectl get nodes -L nvidia.com/gpu.present,nvidia.com/gpu.product,nvidia.com/gpu.count
NAME          STATUS   ROLES    AGE   VERSION   GPU.PRESENT   GPU.PRODUCT               GPU.COUNT
cpu-pool-a1   Ready    <none>   41d   v1.31.2
cpu-pool-a2   Ready    <none>   41d   v1.31.2
gpu-pool-h1   Ready    <none>   12d   v1.31.2   true          NVIDIA-H100-80GB-HBM3     8
gpu-pool-l1   Ready    <none>   12d   v1.31.2   true          NVIDIA-L40S               4

$ kubectl describe node gpu-pool-h1 | sed -n '/Allocatable:/,/System Info:/p'
Allocatable:
  cpu:                190
  ephemeral-storage:  3410259812Ki
  hugepages-1Gi:      0
  hugepages-2Mi:      0
  memory:             2040513812Ki
  nvidia.com/gpu:     8
  pods:               110
System Info:
```

### 6.2 Run all three workload classes

```bash
$ kubectl apply -f namespace-and-scripts.yaml -f churn-rf-cpu.yaml \
    -f churn-rf-gpu.yaml -f resnet50-ddp.yaml
namespace/ai-workloads created
resourcequota/gpu-quota created
configmap/training-scripts created
job.batch/churn-rf-cpu created
job.batch/churn-rf-gpu created
job.batch/resnet50-ddp created

$ kubectl get pods -n ai-workloads -o wide -L workload-class
NAME                 READY   STATUS    RESTARTS   AGE   IP            NODE          WORKLOAD-CLASS
churn-rf-cpu-x8m2k   1/1     Running   0          40s   10.42.1.17    cpu-pool-a1   classical-ml
churn-rf-gpu-7tq9d   1/1     Running   0          40s   10.42.5.22    gpu-pool-l1   classical-ml-accelerated
resnet50-ddp-mz4lp   1/1     Running   0          40s   10.42.4.31    gpu-pool-h1   deep-learning-training
```

### 6.3 Compare outputs

```bash
$ kubectl logs -n ai-workloads job/churn-rf-cpu
[classical-ml/cpu] fit_seconds=38.4
[classical-ml/cpu] accuracy=0.9512
[classical-ml/cpu] top_features=[(7, 0.1384), (2, 0.1127), (15, 0.0981)]

$ kubectl logs -n ai-workloads job/churn-rf-gpu
[classical-ml/gpu] fit_seconds=2.1
[classical-ml/gpu] accuracy=0.9497

$ kubectl logs -n ai-workloads job/resnet50-ddp
[deep-learning] world_size=8 images_per_sec=21840 peak_mem_gib=21.7 final_loss=6.874
```

Interpretation:

- **Classical ML on CPU** finishes in well under a minute and exposes **feature importances**, which aids interpretability.
- **The same algorithm on a GPU via RAPIDS** is roughly an order of magnitude faster. This is worth it for large data or hyperparameter sweeps, but the workload never needed eight GPUs.
- **Deep learning** uses all eight GPUs and roughly 22 GiB of HBM per GPU for a mid-sized CNN. A real ResNet-50 training run over ImageNet repeats this for ~90 epochs.

### 6.4 Inspect GPU utilization during DL training

```bash
$ kubectl exec -n ai-workloads resnet50-ddp-mz4lp -- nvidia-smi \
    --query-gpu=index,name,utilization.gpu,memory.used,memory.total,power.draw \
    --format=csv
index, name, utilization.gpu [%], memory.used [MiB], memory.total [MiB], power.draw [W]
0, NVIDIA H100 80GB HBM3, 98 %, 22431 MiB, 81559 MiB, 641.27 W
1, NVIDIA H100 80GB HBM3, 97 %, 22431 MiB, 81559 MiB, 633.80 W
2, NVIDIA H100 80GB HBM3, 98 %, 22431 MiB, 81559 MiB, 645.12 W
3, NVIDIA H100 80GB HBM3, 98 %, 22431 MiB, 81559 MiB, 638.44 W
4, NVIDIA H100 80GB HBM3, 97 %, 22431 MiB, 81559 MiB, 629.91 W
5, NVIDIA H100 80GB HBM3, 98 %, 22431 MiB, 81559 MiB, 642.06 W
6, NVIDIA H100 80GB HBM3, 98 %, 22431 MiB, 81559 MiB, 640.73 W
7, NVIDIA H100 80GB HBM3, 97 %, 22431 MiB, 81559 MiB, 636.58 W

$ kubectl exec -n ai-workloads resnet50-ddp-mz4lp -- nvidia-smi topo -m
        GPU0  GPU1  GPU2  GPU3  GPU4  GPU5  GPU6  GPU7  NIC0  CPU Affinity  NUMA Affinity
GPU0     X    NV18  NV18  NV18  NV18  NV18  NV18  NV18  PXB   0-47          0
GPU1    NV18   X    NV18  NV18  NV18  NV18  NV18  NV18  PXB   0-47          0
...
```

`NV18` means 18 NVLink connections between each GPU pair, through NVSwitch. Intra-node all-reduce traffic for DL training rides on NVLink, not PCIe. This is the kind of topology a classical ML job never uses.

### 6.5 Verify DL inference

```bash
$ kubectl apply -f triton.yaml
persistentvolumeclaim/model-repository created
deployment.apps/triton-resnet50 created
service/triton-resnet50 created

$ kubectl rollout status deployment/triton-resnet50 -n ai-workloads
deployment "triton-resnet50" successfully rolled out

$ kubectl port-forward -n ai-workloads svc/triton-resnet50 8000:8000 8002:8002 &
Forwarding from 127.0.0.1:8000 -> 8000
Forwarding from 127.0.0.1:8002 -> 8002

$ curl -s -o /dev/null -w "%{http_code}\n" localhost:8000/v2/health/ready
200

$ curl -s localhost:8000/v2/models/resnet50
{"name":"resnet50","versions":["1"],"platform":"tensorrt_plan","inputs":[{"name":"input","datatype":"FP32","shape":[-1,3,224,224]}],"outputs":[{"name":"output","datatype":"FP32","shape":[-1,1000]}]}

$ curl -s localhost:8002/metrics | grep -E '^nv_inference_(request_success|queue_duration_us|compute_infer_duration_us)'
nv_inference_request_success{model="resnet50",version="1"} 184220
nv_inference_queue_duration_us{model="resnet50",version="1"} 39114521
nv_inference_compute_infer_duration_us{model="resnet50",version="1"} 112403877
```

Load-test with Triton's `perf_analyzer` (shipped in the `-py3-sdk` image) to see the benefit of dynamic batching:

```bash
$ perf_analyzer -m resnet50 -u triton-resnet50.ai-workloads:8001 -i grpc \
    --concurrency-range 1:16:4 --shape input:3,224,224
*** Measurement Settings ***
  Batch size: 1
  Service Kind: Triton
  Using "time_windows" mode for stabilization
...
Inferences/Second vs. Client Average Batch Latency
Concurrency: 1, throughput: 912.4 infer/sec, latency 1094 usec
Concurrency: 5, throughput: 3611.8 infer/sec, latency 1383 usec
Concurrency: 9, throughput: 5207.3 infer/sec, latency 1727 usec
Concurrency: 13, throughput: 5890.6 infer/sec, latency 2205 usec
```

Throughput scales far faster than latency grows, because Triton coalesces requests into GPU-efficient batches.

---

## 7. Verification and Failure Diagnosis

### 7.1 Symptom → cause → check → fix

| Symptom | Likely cause | How to check | Fix |
|---|---|---|---|
| DL pod `Pending`, event `0/4 nodes are available: 4 Insufficient nvidia.com/gpu` | GPUs all allocated, or device plugin not running | `kubectl describe pod`; `kubectl get pods -n gpu-operator` | Free GPUs, fix the operator, or right-size the request |
| Job's pod never created; Job event `exceeded quota: gpu-quota, requested: requests.nvidia.com/gpu=…` | the namespace `ResourceQuota` is used up: quota is checked at admission, so the pod is rejected, not left `Pending` | `kubectl describe resourcequota -n ai-workloads`; `kubectl describe job <name>` | Wait for running GPU pods to finish, raise the quota, or right-size the request |
| Node shows `nvidia.com/gpu: 0` allocatable | Driver/toolkit not ready, or the validator failed | `kubectl logs -n gpu-operator -l app=nvidia-operator-validator`; `kubectl logs ds/nvidia-driver-daemonset -n gpu-operator` | Check kernel/driver compatibility, Secure Boot module signing, then restart the driver pod |
| `RuntimeError: CUDA out of memory` | DL training memory (weights + grads + optimizer + activations) exceeds HBM | `nvidia-smi` memory.used; `torch.cuda.max_memory_allocated()` | Lower the batch size, enable mixed precision/activation checkpointing, shard (FSDP/ZeRO), use larger-memory GPUs |
| `ERROR: Unexpected bus error encountered in worker` / `Bus error (core dumped)` | `/dev/shm` defaults to 64 MiB in containers | `kubectl exec ... -- df -h /dev/shm` | Mount `emptyDir` with `medium: Memory` at `/dev/shm` (see 5.5) |
| GPU utilization oscillating 20-40% during training | **Data starvation:** storage or CPU preprocessing cannot feed the GPUs | DCGM `DCGM_FI_DEV_GPU_UTIL` vs storage read throughput; CPU saturation in the pod | Faster storage tier, local NVMe cache, more DataLoader workers, NVIDIA DALI GPU decoding, GPUDirect Storage |
| Multi-GPU training hangs at start or `NCCL WARN` timeouts | NCCL cannot form rings/trees (topology, network, shm) | `NCCL_DEBUG=INFO` logs; `nvidia-smi topo -m`; RDMA device availability | Fix shm size, enable the correct NIC (`NCCL_SOCKET_IFNAME`, RDMA/GPUDirect), check IB/RoCE health |
| `classical-ml` pod sitting on a GPU node with 0% utilization | Missing affinity, so the scheduler placed a CPU workload on GPU capacity | `kubectl get pods -o wide -L workload-class` | Add `nvidia.com/gpu.present DoesNotExist` affinity; taint GPU nodes `nvidia.com/gpu=present:NoSchedule` |
| Triton pod never Ready; log shows `failed to load 'resnet50'` | TensorRT engine built for a different GPU architecture or TensorRT version, or a wrong `config.pbtxt` | `kubectl logs deploy/triton-resnet50`; `curl /v2/repository/index -X POST` | Rebuild the engine with the same TensorRT container version on the target GPU type; fix input/output names and dims |
| Inference p99 latency high at low GPU utilization | No batching, or a single model instance serializing requests | Triton metrics: queue vs compute duration | Enable `dynamic_batching`, increase `instance_group.count`, use FP16/INT8 TensorRT engines |
| Training step time jumps after a checkpoint | Checkpoint writes saturate storage and block the training loop | Storage write bandwidth around checkpoint intervals | Asynchronous/sharded checkpointing, higher-throughput tier, stagger writes |

### 7.2 Health-check sequence for a new GPU platform

```bash
# 1. Operator components healthy?
$ kubectl get pods -n gpu-operator --field-selector=status.phase!=Running,status.phase!=Succeeded
No resources found in gpu-operator namespace.

# 2. GPUs advertised to the scheduler?
$ kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu
NAME          GPU
cpu-pool-a1   <none>
cpu-pool-a2   <none>
gpu-pool-h1   8
gpu-pool-l1   4

# 3. A CUDA workload actually executes?
$ kubectl run cuda-smoke --rm -it --restart=Never \
    --image=nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0 \
    --overrides='{"spec":{"nodeSelector":{"nvidia.com/gpu.present":"true"},"tolerations":[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}],"containers":[{"name":"cuda-smoke","image":"nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0","resources":{"limits":{"nvidia.com/gpu":1}}}]}}'
[Vector addition of 50000 elements]
Copy input data from the host memory to the CUDA device
CUDA kernel launch with 196 blocks of 256 threads
Copy output data from the CUDA device to the host memory
Test PASSED
Done
pod "cuda-smoke" deleted

# 4. Telemetry flowing (needed to spot data starvation and errors)?
$ kubectl port-forward -n gpu-operator svc/nvidia-dcgm-exporter 9400:9400 &
$ curl -s localhost:9400/metrics | grep -E '^DCGM_FI_DEV_(GPU_UTIL|FB_USED|XID_ERRORS)' | head -3
DCGM_FI_DEV_GPU_UTIL{gpu="0",modelName="NVIDIA H100 80GB HBM3",Hostname="gpu-pool-h1"} 98
DCGM_FI_DEV_FB_USED{gpu="0",modelName="NVIDIA H100 80GB HBM3",Hostname="gpu-pool-h1"} 22431
DCGM_FI_DEV_XID_ERRORS{gpu="0",modelName="NVIDIA H100 80GB HBM3",Hostname="gpu-pool-h1"} 0
```

### 7.3 Diagnosing a misclassified workload

When a team requests GPUs, ask these questions before granting the capacity:

1. **Does it learn from data?** If not, it is rule-based AI and belongs on CPU.
2. **Is the model a neural network with many layers?** If not, it is classical ML: CPU first, and one GPU via RAPIDS only if data volume or sweep size justifies it.
3. **Is it training or inference?** Training needs multi-GPU, interconnect, and storage throughput. Inference needs latency SLOs, an optimized runtime (TensorRT/Triton/NIM), and autoscaling.
4. **What precision and model size?** Parameters × bytes per parameter tells you whether it fits on one GPU, a MIG slice, or needs sharding.

---

## 8. Exam-Focused Summary

- **AI** is the broadest term: any machine behavior that mimics human intelligence, including non-learning, rule-based systems.
- **ML** is a subset of AI: algorithms learn patterns from data rather than following explicit rules. Classical ML relies on **human-engineered features** and suits **structured data**.
- **DL** is a subset of ML: **multi-layer neural networks** that **learn features automatically** from raw, **unstructured data**. They need **large datasets** and **massive parallel compute**, which is why GPUs and Tensor Cores dominate.
- **Generative AI and LLMs** are a subset of DL: transformer models that generate content. They are the most demanding workloads for memory, compute, networking, and storage.
- **Training** is compute-intensive and runs as a batch workload that scales across GPUs and nodes. **Inference** is latency- and throughput-sensitive production serving, optimized with **TensorRT** and served with **Triton/NIM**.
- GPUs **also** accelerate classical ML and data science (RAPIDS), but DL is the workload that makes them essential.
- Typical exam distractors:
  - "All AI requires GPUs" is false.
  - "Deep learning requires manual feature engineering" is false.
  - "ML is broader than AI" is false.
  - "Inference has the same resource profile as training" is false.

---

## Referencias

- NVIDIA Certified Associate: AI Infrastructure and Operations (NCA-AIIO) exam study guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy, AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA Blog, "What's the Difference Between Artificial Intelligence, Machine Learning and Deep Learning?": https://blogs.nvidia.com/blog/whats-difference-artificial-intelligence-machine-learning-deep-learning-ai/
- NVIDIA Blog, "What Are Large Language Models Used For?": https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
- NVIDIA Developer, AI Inference: https://developer.nvidia.com/topics/ai/ai-inference
- NVIDIA TensorRT: https://developer.nvidia.com/tensorrt
- NVIDIA Developer Blog, "Tips on Scaling Storage for AI Training and Inferencing": https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
- NVIDIA Developer Blog, "NVIDIA GPU Operator: Simplifying GPU Management in Kubernetes": https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes
- NVIDIA GPU Operator documentation: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html
- NVIDIA Triton Inference Server user guide: https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/index.html
- NVIDIA TensorRT documentation: https://docs.nvidia.com/deeplearning/tensorrt/
- NVIDIA DCGM Exporter: https://docs.nvidia.com/datacenter/cloud-native/gpu-telemetry/latest/dcgm-exporter.html
- RAPIDS documentation (cuDF, cuML): https://docs.rapids.ai/
- NGC Catalog (PyTorch, Triton, TensorRT containers): https://catalog.ngc.nvidia.com/
- Kubernetes, Device Plugins: https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/
- Kubernetes, Schedule GPUs: https://kubernetes.io/docs/tasks/manage-gpus/scheduling-gpus/