# Guided Exercises — Topic 1.3: Differentiate the concepts of AI, machine learning, and deep learning

**Certification:** NVIDIA-Certified Associate: AI Infrastructure and Operations (NCA-AIIO)
**Exam weight of this topic:** 4.75%

## What you will build

In these exercises you solve related problems three ways, so you can see where the boundaries between the three concepts sit:

| Layer | What you implement | Who designs the decision logic |
|---|---|---|
| **AI** (the umbrella) | A rule-based spam filter | A human writes explicit rules |
| **Machine Learning** (a subset of AI) | A logistic-regression digit classifier, first on hand-engineered features and then on raw pixels | The algorithm learns weights; a human usually designs the features |
| **Deep Learning** (a subset of ML) | A small convolutional neural network (CNN) on the same digits | The network learns both the features and the decision boundary, layer by layer |

You then connect the concepts to infrastructure: why deep learning drives GPU demand, how training differs from inference, how TensorRT optimizes a trained model, and how Kubernetes schedules GPU workloads through the NVIDIA GPU Operator.

## Prerequisites

- Linux or macOS with Python 3.10 or later.
- **Optional:** an NVIDIA GPU with a working driver. Every step runs on CPU. GPU-only steps are marked **[GPU]**.
- **Optional:** a Kubernetes cluster with the NVIDIA GPU Operator, for Step 8.

---

## Step 1 — Prepare the lab environment

1. Create an isolated working directory and virtual environment:

   ```bash
   mkdir -p ~/aiio-1.3 && cd ~/aiio-1.3
   python3 -m venv .venv
   source .venv/bin/activate
   python -m pip install --upgrade pip
   ```

2. Install the libraries. `scikit-learn` covers classical ML, `torch` covers deep learning, and `onnx`/`onnxscript` are needed later for model export:

   ```bash
   pip install numpy scikit-learn torch onnx onnxscript
   ```

3. Verify the installation and check whether PyTorch can see a GPU:

   ```bash
   python -c "import sklearn, torch; print('sklearn', sklearn.__version__); print('torch', torch.__version__); print('CUDA available:', torch.cuda.is_available())"
   ```

   Expected output (versions will differ):

   ```
   sklearn 1.5.2
   torch 2.5.1+cu124
   CUDA available: True
   ```

   On a machine without an NVIDIA GPU the last line reads `CUDA available: False`. This is fine.

4. **[GPU]** Inspect the GPU from the driver's point of view:

   ```bash
   nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
   ```

   Example output:

   ```
   name, memory.total [MiB], driver_version
   NVIDIA A100-SXM4-80GB, 81920 MiB, 550.90.07
   ```

**Comprehension questions — Step 1**

- **Q1.1** You installed two different libraries, `scikit-learn` and `torch`. Based on the table at the top, which concept layer does each one primarily serve?
- **Q1.2** `torch.cuda.is_available()` returned `False` but the rest of the lab still works. What does this tell you about the relationship between deep learning and GPUs: is it a functional requirement or a performance requirement?

---

## Step 2 — AI without learning: a rule-based system

Artificial Intelligence is the broad field of making machines perform tasks that normally require human intelligence. Early AI, often called symbolic AI or expert systems, encoded human knowledge as explicit rules. No data is used to learn anything.

1. Create `rules_ai.py`:

   ```python
   # rules_ai.py: a rule-based (symbolic) "AI" spam filter. No learning involved.

   RULES = [
       # (description, predicate, weight)
       ("mentions 'free money'", lambda m: "free money" in m.lower(), 3),
       ("mentions 'winner'", lambda m: "winner" in m.lower(), 2),
       ("contains 'click here'", lambda m: "click here" in m.lower(), 2),
       ("more than 3 exclamation marks", lambda m: m.count("!") > 3, 1),
       ("mostly uppercase", lambda m: sum(c.isupper() for c in m) > 0.5 * max(1, sum(c.isalpha() for c in m)), 1),
   ]

   THRESHOLD = 3


   def score(message: str) -> tuple[int, list[str]]:
       fired = [desc for desc, pred, _ in RULES if pred(message)]
       total = sum(w for desc, pred, w in RULES if pred(message))
       return total, fired


   def classify(message: str) -> str:
       total, _ = score(message)
       return "SPAM" if total >= THRESHOLD else "HAM"


   if __name__ == "__main__":
       messages = [
           "Congratulations WINNER!!!! Click here to claim your FREE MONEY",
           "Hi team, the GPU cluster maintenance window moves to Friday.",
           "You are a winner, click here now",
           "Get fr33 m0ney today, totally legit",
       ]
       for msg in messages:
           total, fired = score(msg)
           print(f"{classify(msg):4} score={total} rules={fired}\n      {msg!r}")
   ```

2. Run it:

   ```bash
   python rules_ai.py
   ```

   Expected output:

   ```
   SPAM score=8 rules=["mentions 'free money'", "mentions 'winner'", "contains 'click here'", 'more than 3 exclamation marks']
         'Congratulations WINNER!!!! Click here to claim your FREE MONEY'
   HAM  score=0 rules=[]
         'Hi team, the GPU cluster maintenance window moves to Friday.'
   SPAM score=4 rules=["mentions 'winner'", "contains 'click here'"]
         'You are a winner, click here now'
   HAM  score=0 rules=[]
         'Get fr33 m0ney today, totally legit'
   ```

3. Look at the last message. It is obviously spam, but the system classified it as `HAM`.

**Comprehension questions — Step 2**

- **Q2.1** Is this program AI? Is it machine learning? Justify both answers using the definitions.
- **Q2.2** To catch `fr33 m0ney` you must add a new rule by hand. What does this reveal about how rule-based systems scale as the problem space grows?
- **Q2.3** Name one advantage that this rule-based system has over the ML and DL models you will build next. Think about explainability and compute cost.

---

## Step 3 — Machine learning: learning weights from data

Machine Learning is a subset of AI in which a system improves at a task by learning patterns from data instead of following explicitly programmed rules. In classical ML, a human typically decides **which features** the model sees (feature engineering), and the algorithm learns **how to weigh them**.

You will use the scikit-learn `digits` dataset: 1,797 grayscale images of handwritten digits, each 8×8 pixels (64 values from 0 to 16).

1. Create `classic_ml.py`:

   ```python
   # classic_ml.py: classical ML with hand-engineered features vs raw pixels.
   import time

   import numpy as np
   from sklearn.datasets import load_digits
   from sklearn.linear_model import LogisticRegression
   from sklearn.model_selection import train_test_split
   from sklearn.pipeline import make_pipeline
   from sklearn.preprocessing import StandardScaler

   X, y = load_digits(return_X_y=True)
   print("dataset shape (samples, features):", X.shape)

   X_tr, X_te, y_tr, y_te = train_test_split(
       X, y, test_size=0.25, random_state=42, stratify=y
   )


   def engineer(X: np.ndarray) -> np.ndarray:
       """Human-designed features: ink per row and ink per column (16 numbers)."""
       imgs = X.reshape(-1, 8, 8)
       row_sums = imgs.sum(axis=2)
       col_sums = imgs.sum(axis=1)
       return np.hstack([row_sums, col_sums])


   # A) Classical ML on hand-engineered features
   clf_feat = make_pipeline(StandardScaler(), LogisticRegression(max_iter=2000))
   t0 = time.perf_counter()
   clf_feat.fit(engineer(X_tr), y_tr)
   t_feat = time.perf_counter() - t0
   acc_feat = clf_feat.score(engineer(X_te), y_te)

   # B) Classical ML on raw pixels
   clf_raw = make_pipeline(StandardScaler(), LogisticRegression(max_iter=2000))
   t0 = time.perf_counter()
   clf_raw.fit(X_tr, y_tr)
   t_raw = time.perf_counter() - t0
   acc_raw = clf_raw.score(X_te, y_te)

   lr = clf_raw[-1]
   n_params = lr.coef_.size + lr.intercept_.size

   print(f"[A] engineered features (16): accuracy={acc_feat:.3f} train_time={t_feat:.2f}s")
   print(f"[B] raw pixels (64):          accuracy={acc_raw:.3f} train_time={t_raw:.2f}s")
   print("learned parameters in [B]:", n_params, "->", lr.coef_.shape, "weights +", lr.intercept_.shape, "biases")
   ```

2. Run it:

   ```bash
   python classic_ml.py
   ```

   Expected output (accuracy and timings vary slightly by library version and CPU):

   ```
   dataset shape (samples, features): (1797, 64)
   [A] engineered features (16): accuracy=0.880 train_time=0.05s
   [B] raw pixels (64):          accuracy=0.971 train_time=0.08s
   learned parameters in [B]: 650 -> (10, 64) weights + (10,) biases
   ```

   You should see that the engineered-feature model scores noticeably below the raw-pixel model. With these settings the gap is usually around 0.85–0.90 versus around 0.96–0.98.

**Comprehension questions — Step 3**

- **Q3.1** Compare this program with `rules_ai.py`. Which part did a human write in each case, and which part was derived from data?
- **Q3.2** Model [A] performed worse than [B]. What does this tell you about the risk of feature engineering, which is the defining human step in classical ML?
- **Q3.3** Explain where the number 650 comes from. Why is this model still considered "shallow"?
- **Q3.4** Training took a fraction of a second on a CPU. Would a GPU help much here? Why or why not?

---

## Step 4 — Deep learning: learning the features too

Deep Learning is a subset of ML that uses multi-layer (deep) artificial neural networks. The defining difference is **representation learning**. Earlier layers learn low-level features such as edges and strokes, and later layers combine them into higher-level concepts. This replaces most manual feature engineering. The cost is more parameters, more data, and far more compute. That compute consists overwhelmingly of matrix multiplications, which GPUs parallelize well.

1. Create `deep_learning.py`:

   ```python
   # deep_learning.py: a small CNN that learns its own features from raw pixels.
   import time

   import torch
   import torch.nn as nn
   from sklearn.datasets import load_digits
   from sklearn.model_selection import train_test_split
   from torch.utils.data import DataLoader, TensorDataset

   torch.manual_seed(42)
   device = "cuda" if torch.cuda.is_available() else "cpu"
   print("device:", device)

   X, y = load_digits(return_X_y=True)
   X = X.reshape(-1, 1, 8, 8) / 16.0  # (N, channels, H, W), scaled to [0, 1]
   X_tr, X_te, y_tr, y_te = train_test_split(
       X, y, test_size=0.25, random_state=42, stratify=y
   )

   to_t = lambda a, dt: torch.tensor(a, dtype=dt)
   train_dl = DataLoader(
       TensorDataset(to_t(X_tr, torch.float32), to_t(y_tr, torch.long)),
       batch_size=64, shuffle=True,
   )
   X_te_t = to_t(X_te, torch.float32).to(device)
   y_te_t = to_t(y_te, torch.long).to(device)


   class DigitsCNN(nn.Module):
       def __init__(self):
           super().__init__()
           self.features = nn.Sequential(          # learned feature extractor
               nn.Conv2d(1, 16, kernel_size=3, padding=1), nn.ReLU(), nn.MaxPool2d(2),   # 8x8 -> 4x4
               nn.Conv2d(16, 32, kernel_size=3, padding=1), nn.ReLU(), nn.MaxPool2d(2),  # 4x4 -> 2x2
           )
           self.classifier = nn.Sequential(        # learned decision layers
               nn.Flatten(),
               nn.Linear(32 * 2 * 2, 64), nn.ReLU(),
               nn.Linear(64, 10),
           )

       def forward(self, x):
           return self.classifier(self.features(x))


   model = DigitsCNN().to(device)
   for name, p in model.named_parameters():
       print(f"  {name:24} {str(tuple(p.shape)):18} {p.numel():>6}")
   print("total trainable parameters:", sum(p.numel() for p in model.parameters()))

   opt = torch.optim.Adam(model.parameters(), lr=1e-3)
   loss_fn = nn.CrossEntropyLoss()

   t0 = time.perf_counter()
   for epoch in range(1, 31):
       model.train()
       for xb, yb in train_dl:
           xb, yb = xb.to(device), yb.to(device)
           opt.zero_grad()
           loss = loss_fn(model(xb), yb)   # forward pass
           loss.backward()                 # backward pass (gradients)
           opt.step()                      # weight update
       if epoch % 10 == 0:
           model.eval()
           with torch.inference_mode():
               acc = (model(X_te_t).argmax(1) == y_te_t).float().mean().item()
           print(f"epoch {epoch:2d} loss={loss.item():.4f} test_acc={acc:.3f}")
   print(f"training time: {time.perf_counter() - t0:.1f}s")

   torch.save(model.state_dict(), "digits_cnn.pt")
   print("saved weights to digits_cnn.pt")
   ```

2. Run it:

   ```bash
   python deep_learning.py
   ```

   Expected output (loss, accuracy, and time vary by hardware and version):

   ```
   device: cpu
     features.0.weight        (16, 1, 3, 3)         144
     features.0.bias          (16,)                  16
     features.3.weight        (32, 16, 3, 3)       4608
     features.3.bias          (32,)                  32
     classifier.1.weight      (64, 128)            8192
     classifier.1.bias        (64,)                  64
     classifier.3.weight      (10, 64)              640
     classifier.3.bias        (10,)                  10
   total trainable parameters: 13706
   epoch 10 loss=0.1213 test_acc=0.967
   epoch 20 loss=0.0315 test_acc=0.978
   epoch 30 loss=0.0102 test_acc=0.982
   training time: 6.4s
   ```

**Comprehension questions — Step 4**

- **Q4.1** No `engineer()` function exists in this script, yet the CNN matches or beats the logistic regression. Which part of the network replaces manual feature engineering?
- **Q4.2** The CNN has 13,706 parameters versus 650 for logistic regression, about 21 times more, for a task this small. Extrapolate: what happens to compute and memory needs when models reach billions of parameters, as large language models do?
- **Q4.3** Name the three operations inside the training loop that run for every mini-batch. Which of them exists only during training?
- **Q4.4** Is this CNN also "machine learning"? Is it also "AI"? Draw the relationship of the three terms as a diagram in words.

---

## Step 5 — Why deep learning drives GPU infrastructure

The workload in Step 4 is too small to show the GPU's advantage. Here you measure the operation that dominates deep learning: dense matrix multiplication (GEMM).

1. Create `gemm_bench.py`:

   ```python
   # gemm_bench.py: measure matrix-multiply throughput on CPU and (if present) GPU.
   import time

   import torch


   def bench(device: str, n: int, dtype: torch.dtype, iters: int = 10) -> float:
       a = torch.randn(n, n, device=device, dtype=dtype)
       b = torch.randn(n, n, device=device, dtype=dtype)
       for _ in range(2):          # warm-up (kernel selection, caches)
           a @ b
       if device == "cuda":
           torch.cuda.synchronize()  # GPU calls are asynchronous: wait before timing
       t0 = time.perf_counter()
       for _ in range(iters):
           a @ b
       if device == "cuda":
           torch.cuda.synchronize()
       elapsed = time.perf_counter() - t0
       flops = 2 * n**3 * iters
       return flops / elapsed / 1e12   # TFLOPS


   n = 4096
   print(f"CPU  fp32 {n}x{n}: {bench('cpu', n, torch.float32, iters=3):8.2f} TFLOPS")
   if torch.cuda.is_available():
       print(f"GPU  fp32 {n}x{n}: {bench('cuda', n, torch.float32):8.2f} TFLOPS")
       print(f"GPU  fp16 {n}x{n}: {bench('cuda', n, torch.float16):8.2f} TFLOPS")
   ```

2. Run it:

   ```bash
   python gemm_bench.py
   ```

   Example output on a server with a data-center GPU. Your numbers will differ, often by an order of magnitude depending on hardware:

   ```
   CPU  fp32 4096x4096:     1.10 TFLOPS
   GPU  fp32 4096x4096:    17.80 TFLOPS
   GPU  fp16 4096x4096:   210.40 TFLOPS
   ```

3. **[GPU]** While the benchmark runs, open a second terminal and watch utilization:

   ```bash
   nvidia-smi --query-gpu=utilization.gpu,memory.used,power.draw --format=csv -l 1
   ```

**Comprehension questions — Step 5**

- **Q5.1** Why does the script call `torch.cuda.synchronize()` before reading the timer? What would the measurement show without it?
- **Q5.2** FP16 is much faster than FP32 on the GPU. Which specialized hardware units in NVIDIA GPUs are responsible, and why does this matter more for deep learning than for the rule-based system in Step 2?
- **Q5.3** In one sentence for a non-technical stakeholder: why did the rise of deep learning, rather than AI in general, create demand for GPU-accelerated data centers?

---

## Step 6 — Training vs. inference

Training builds the model: forward pass, backward pass, and weight updates, repeated over large datasets. Inference uses the trained model to make predictions on new data: forward pass only. These two phases have very different infrastructure profiles. Training needs throughput, memory for activations and gradients, and fast storage to feed data. Inference needs low latency, high throughput per watt, and scaling to concurrent users.

1. Create `inference.py`:

   ```python
   # inference.py: load trained weights and serve predictions (forward pass only).
   import time

   import torch
   from sklearn.datasets import load_digits

   from deep_learning import DigitsCNN  # noqa: E402  (re-uses the class definition)

   device = "cuda" if torch.cuda.is_available() else "cpu"
   model = DigitsCNN().to(device)
   model.load_state_dict(torch.load("digits_cnn.pt", map_location=device))
   model.eval()

   X, y = load_digits(return_X_y=True)
   X = torch.tensor(X.reshape(-1, 1, 8, 8) / 16.0, dtype=torch.float32, device=device)

   with torch.inference_mode():   # no autograd graph, no gradient memory
       for batch in (1, 64, 1024):
           xb = X[:batch]
           model(xb)                  # warm-up
           if device == "cuda":
               torch.cuda.synchronize()
           t0 = time.perf_counter()
           for _ in range(100):
               preds = model(xb).argmax(1)
           if device == "cuda":
               torch.cuda.synchronize()
           dt = (time.perf_counter() - t0) / 100
           print(f"batch={batch:5d} latency={dt*1e3:7.3f} ms  throughput={batch/dt:10.0f} img/s")

       print("first 10 predictions:", preds[:10].tolist())
       print("first 10 labels:     ", y[:10].tolist())

       dummy = torch.randn(1, 1, 8, 8, device=device)
       torch.onnx.export(model, dummy, "digits_cnn.onnx",
                         input_names=["image"], output_names=["logits"])
   print("exported digits_cnn.onnx")
   ```

   > Importing `deep_learning` re-runs its training code, because that script has no `if __name__ == "__main__":` guard. That is acceptable for this lab. In real projects, keep model definitions in their own module.

2. Run it:

   ```bash
   python inference.py
   ```

   Expected output, after the training log from the import. Numbers are illustrative:

   ```
   batch=    1 latency=  0.210 ms  throughput=      4762 img/s
   batch=   64 latency=  0.320 ms  throughput=    200000 img/s
   batch= 1024 latency=  1.900 ms  throughput=    538947 img/s
   first 10 predictions: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
   first 10 labels:      [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
   exported digits_cnn.onnx
   ```

3. **[GPU]** Optimize the exported model with NVIDIA TensorRT, the SDK for high-performance deep learning inference. Run it from an NGC container, choosing a current tag from the NGC catalog:

   ```bash
   docker run --rm --gpus all -v "$PWD":/work \
     nvcr.io/nvidia/tensorrt:24.08-py3 \
     trtexec --onnx=/work/digits_cnn.onnx \
             --saveEngine=/work/digits_cnn.plan \
             --fp16
   ```

   Near the end of the log, look for the performance summary lines, for example:

   ```
   [I] Latency: min = 0.0213 ms, max = 0.0451 ms, mean = 0.0236 ms, median = 0.0232 ms
   [I] Throughput: 39871.2 qps
   &&&& PASSED TensorRT.trtexec [TensorRT v100300] # trtexec --onnx=/work/digits_cnn.onnx ...
   ```

**Comprehension questions — Step 6**

- **Q6.1** What does `torch.inference_mode()` turn off, and why does that reduce memory use compared with training?
- **Q6.2** Latency per call grew with batch size, yet throughput rose sharply. Which metric matters most for an interactive chatbot, and which matters most for overnight batch scoring of millions of records?
- **Q6.3** TensorRT optimizes a model that was already trained. Does it apply to rule-based AI (Step 2), classical ML (Step 3), or deep learning (Step 4)? Why?
- **Q6.4** The `.plan` engine is built for a specific GPU and TensorRT version. What operational consequence does this have when you upgrade the GPU fleet?

---

## Step 7 — Classify real-world scenarios

Use only the definitions. For each scenario, write down the **most specific** correct label (AI only, ML but not DL, or DL), plus a one-line justification.

| # | Scenario |
|---|---|
| a | A firewall that blocks traffic matching a list of hand-written signatures |
| b | A random-forest model that predicts server disk failure from SMART counters chosen by an SRE |
| c | A large language model (LLM) that summarizes incident tickets |
| d | A chess engine that uses minimax search with a hand-tuned evaluation function |
| e | A transformer-based model that transcribes data-center technician voice notes |
| f | A linear regression that forecasts next month's GPU-hour demand from past usage |
| g | An object-detection CNN that counts people in a server room from CCTV video |
| h | A thermostat that turns cooling on above 27 °C |

**Comprehension questions — Step 7**

- **Q7.1** Which scenarios are **AI but not ML**?
- **Q7.2** Which are **ML but not DL**?
- **Q7.3** Which are **DL**? What architectural feature do they all share?
- **Q7.4** Scenario (h) is debatable. Argue whether a single-threshold thermostat should count as AI at all.

---

## Step 8 — Map the concepts to Kubernetes GPU infrastructure (optional cluster)

Deep learning workloads in production run on clusters, and Kubernetes needs a way to expose GPUs as schedulable resources. The NVIDIA GPU Operator automates the components required: the driver, NVIDIA Container Toolkit, Kubernetes device plugin, GPU Feature Discovery, and DCGM-based monitoring. After it runs, nodes advertise the extended resource `nvidia.com/gpu`.

1. Check which nodes expose GPUs:

   ```bash
   kubectl get nodes -o custom-columns='NAME:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu'
   ```

   Example output:

   ```
   NAME          GPUS
   cpu-node-01   <none>
   gpu-node-01   8
   gpu-node-02   8
   ```

2. Inspect the GPU Operator components. The namespace may differ in your install:

   ```bash
   kubectl get pods -n gpu-operator
   ```

   Example output, abridged:

   ```
   NAME                                       READY   STATUS      RESTARTS   AGE
   gpu-feature-discovery-7xk2p                1/1     Running     0          3d
   gpu-operator-6c8b7f9d8-q2vfn               1/1     Running     0          3d
   nvidia-container-toolkit-daemonset-4hz8m   1/1     Running     0          3d
   nvidia-cuda-validator-l9t6w                0/1     Completed   0          3d
   nvidia-dcgm-exporter-pq7c2                 1/1     Running     0          3d
   nvidia-device-plugin-daemonset-v8r5s       1/1     Running     0          3d
   nvidia-driver-daemonset-2bm4x              1/1     Running     0          3d
   ```

3. Create `gpu-smoke-test.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: gpu-smoke-test
     labels:
       app.kubernetes.io/name: gpu-smoke-test
       workload-class: deep-learning
   spec:
     restartPolicy: Never
     containers:
       - name: cuda
         image: nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04
         command: ["nvidia-smi", "-L"]
         resources:
           limits:
             nvidia.com/gpu: 1
   ```

4. Apply it and read the logs:

   ```bash
   kubectl apply -f gpu-smoke-test.yaml
   kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/gpu-smoke-test --timeout=120s
   kubectl logs gpu-smoke-test
   ```

   Expected output:

   ```
   pod/gpu-smoke-test created
   pod/gpu-smoke-test condition met
   GPU 0: NVIDIA A100-SXM4-80GB (UUID: GPU-3f1c9a2e-8d4b-4c71-b0e2-5a6d9e1f7c30)
   ```

5. Clean up:

   ```bash
   kubectl delete pod gpu-smoke-test
   ```

**Comprehension questions — Step 8**

- **Q8.1** You would not request `nvidia.com/gpu` for the rule-based filter in Step 2. Would you request it for the classical ML model in Step 3? For the CNN training job? For a production LLM inference service? Justify each.
- **Q8.2** Why is `nvidia.com/gpu` set under `limits`, and what happens to the Pod if no node has a free GPU?
- **Q8.3** Which GPU Operator component makes `nvidia.com/gpu` appear in the node's allocatable resources, and which component would you use to feed GPU utilization metrics into Prometheus?

---

## Summary table to keep for the exam

| Dimension | AI (broad field) | Machine Learning | Deep Learning |
|---|---|---|---|
| Relationship | Umbrella term | Subset of AI | Subset of ML |
| How behavior is obtained | Rules, search, logic, or learning | Learned from data | Learned from data with multi-layer neural networks |
| Feature engineering | N/A for rule-based systems | Usually manual | Learned automatically (representation learning) |
| Typical data volume | None to small | Small to medium | Large to massive |
| Typical compute | CPU | Mostly CPU, sometimes GPU | GPU/accelerators, often multi-node |
| Explainability | High | Medium | Lower; needs dedicated tooling |
| Examples | Expert systems, rule engines, search-based game AI | Linear/logistic regression, decision trees, random forests, SVM, gradient boosting | CNNs, RNNs, transformers, LLMs, diffusion models |

---

## Answers

<details>
<summary>Click to expand the answers</summary>

### Step 1

- **A1.1** `scikit-learn` serves **classical machine learning**: linear models, trees, SVMs, and clustering. `torch` serves **deep learning**: neural networks, autograd, and GPU tensors. Neither library is needed for the rule-based AI in Step 2, which uses plain Python.
- **A1.2** The GPU is a **performance** requirement, not a functional one. Neural networks are mathematics and run on any processor. GPUs make the massive parallel matrix arithmetic of deep learning fast enough to be practical at scale.

### Step 2

- **A2.1** It is **AI**, in the classical, symbolic sense: it automates a judgment a human would otherwise make. It is **not ML**, because nothing is learned from data. Every rule, weight, and threshold was written by a human, and the behavior never changes unless a human edits the code.
- **A2.2** Rule-based systems scale poorly. Every new variant (misspellings, other languages, new scam patterns) needs a new hand-written rule, and rules start to interact and conflict. Maintenance cost grows with the problem space. This limitation motivated machine learning.
- **A2.3** Any one of these: it is fully **explainable**, since you can see exactly which rules fired; it is **deterministic**; it needs **no training data**; and it has negligible compute cost, with no GPU required.

### Step 3

- **A3.1** In `rules_ai.py` a human wrote both the features (the predicates) and the decision weights and threshold. In `classic_ml.py` a human chose the features (row and column sums in [A], or raw pixels in [B]) and the model family. The **weights and biases were learned from labeled data** by optimization.
- **A3.2** The quality of a classical ML model is limited by the features a human gives it. Row and column sums discard spatial information. For example, 6 and 9 can have similar ink profiles. Poor feature design caps accuracy, whatever the algorithm.
- **A3.3** Logistic regression for 10 classes learns one weight per feature per class (64 × 10 = 640) plus one bias per class (10), for 650 parameters. It is "shallow" because it maps inputs to outputs with a **single linear transformation** and no stacked hidden layers that build intermediate representations.
- **A3.4** Not meaningfully. The workload is tiny: 1,347 training samples and 650 parameters. GPU kernel-launch and data-transfer overhead would outweigh any speedup. GPUs pay off when the arithmetic is large and highly parallel.

### Step 4

- **A4.1** The **convolutional layers (`self.features`)** do. Their 3×3 filters are learned during training and become detectors for strokes, edges, and curves. The second convolution combines those into higher-level patterns. This is representation learning, the hallmark of deep learning.
- **A4.2** Compute (FLOPs per token or image), memory (weights, activations, gradients, and optimizer state), and data requirements grow by many orders of magnitude. Billion-parameter models need GPU memory far beyond one device, multi-GPU or multi-node training with high-bandwidth interconnects, fast storage to keep GPUs fed, and optimized inference stacks. This is the reason NVIDIA AI infrastructure exists.
- **A4.3** The forward pass (`model(xb)` and the loss), the **backward pass** (`loss.backward()`, computing gradients), and the **weight update** (`opt.step()`). The backward pass and weight update exist only during training. Inference performs only the forward pass.
- **A4.4** Yes to both. Think of three nested circles: **AI ⊃ ML ⊃ DL**. Every deep learning model is a machine learning model, and every machine learning model is an AI technique. The reverse is not true.

### Step 5

- **A5.1** CUDA kernel launches are **asynchronous**: the Python call returns as soon as the work is queued. Without `synchronize()` the timer would measure only queueing time, which reports impossibly high TFLOPS.
- **A5.2** **Tensor Cores** are specialized matrix-multiply-accumulate units that run reduced and mixed precision (FP16, BF16, FP8, INT8) much faster than general FP32 CUDA cores. Deep learning is dominated by dense matrix math and tolerates reduced precision well. A rule-based system performs string comparisons and branching, which gain nothing from matrix hardware.
- **A5.3** Deep learning reaches its accuracy by running enormous amounts of identical, parallel arithmetic on large datasets, and GPUs perform that kind of work orders of magnitude faster and more efficiently than CPUs, whereas rule-based AI and most classical ML never needed that scale of computation.

### Step 6

- **A6.1** It disables autograd: no computation graph is recorded, and no intermediate activations are kept for a backward pass. It also skips version-counter tracking. Without stored activations or gradients, memory use and overhead drop compared with training.
- **A6.2** An interactive chatbot cares most about **latency**, meaning time to first token and per-token latency for each user. Overnight batch scoring cares most about **throughput**: total items per second and cost per item. Inference platforms tune batch size, precision, and concurrency to balance the two.
- **A6.3** TensorRT targets **deep learning**: trained neural networks, typically imported from ONNX or through framework integrations. It applies layer and tensor fusion, precision calibration (FP16, INT8, FP8), and kernel auto-tuning for the target GPU. Rule-based code has no network graph to optimize, and classical ML models are usually served with other tools.
- **A6.4** You must **rebuild the engines** for the new GPU architecture and TensorRT version, and validate them again. CI/CD for inference should treat engine builds as a per-platform artifact rather than a portable file.

### Step 7

| # | Label | Justification |
|---|---|---|
| a | AI only (rule-based) | Hand-written signatures; nothing learned |
| b | ML, not DL | Random forest learns from data; features chosen by a human; not a neural network |
| c | DL | LLMs are transformer neural networks with billions of parameters |
| d | AI only | Search plus a hand-tuned evaluation; classic symbolic or search AI |
| e | DL | Transformer speech models are deep neural networks |
| f | ML, not DL | Linear regression is learned from data but is a shallow model |
| g | DL | CNN-based object detection |
| h | Borderline; at most AI only | Single fixed rule; see A7.4 |

- **A7.1** a, d, and arguably h.
- **A7.2** b, f.
- **A7.3** c, e, g. They all use **multi-layer artificial neural networks** that learn hierarchical representations directly from raw data (text, audio, or pixels).
- **A7.4** For "not AI": a single threshold is a control system with no reasoning, knowledge representation, search, or learning. Calling it AI stretches the term until it means nothing. For "AI": under the broadest definition, any automated decision-making agent qualifies. For the exam, the safe view is that it is **at most rule-based AI**, and it is definitely **not ML or DL**.

### Step 8

- **A8.1** Classical ML (Step 3): usually **no**. It trains in milliseconds on CPU, and a GPU would sit idle and waste a scarce resource. GPU-accelerated libraries such as RAPIDS cuML can help on very large tabular datasets. CNN training: **yes** once data and model size grow, since a GPU accelerates the forward and backward passes. Production LLM inference: **yes, essentially always**. The model weights alone may need tens to hundreds of GB of GPU memory, and latency targets require GPU throughput, often across several GPUs.
- **A8.2** Extended resources such as `nvidia.com/gpu` must be specified in `limits`. If `requests` is set, it must equal `limits`, and GPUs cannot be overcommitted or fractionally requested through this resource by default; MIG or time-slicing are separate configurations. If no node has a free GPU, the Pod stays **`Pending`** with a `FailedScheduling` event that reports `Insufficient nvidia.com/gpu`.
- **A8.3** The **NVIDIA Kubernetes device plugin** (`nvidia-device-plugin-daemonset`) registers `nvidia.com/gpu` with the kubelet. GPU metrics for Prometheus come from **DCGM Exporter** (`nvidia-dcgm-exporter`).

</details>

---

## Official references

- NVIDIA, *NCA-AIIO Exam Study Guide*: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy, *AI Infrastructure and Operations Fundamentals*: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA TensorRT: https://developer.nvidia.com/tensorrt
- NVIDIA, *AI Inference*: https://developer.nvidia.com/topics/ai/ai-inference
- NVIDIA Technical Blog, *Tips on Scaling Storage for AI Training and Inferencing*: https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
- NVIDIA Blog, *What Are Large Language Models Used For?*: https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
- NVIDIA Technical Blog, *NVIDIA GPU Operator: Simplifying GPU Management in Kubernetes*: https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes